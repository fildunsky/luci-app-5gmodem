# Web-API sticks: `hilink.sh` architecture

Some USB modems run their own IP stack and give the router a plain network card: Huawei HiLink, ZTE/Tenda goform sticks, Yota, Alcatel, some D-Link, Android Mi-Fi devices. They have no AT port and no cdc-wdm, so `sms_tool` and the normal AT poll do not work with them. They do have an HTTP API with the same data: signal, operator, network mode, traffic and SMS. `root/usr/share/5gmodem/hilink.sh` is the second metrics backend next to the AT path. It prints JSON with **the same keys as `5gmodem.sh`**, so the pages do not need to know which kind of modem they show. The backend is identified by the `"backend":"hilink"` field and not by the model name. The model name appears on tabs, buttons and profile cards, where a class marker would be noise.

Vendor details: [huawei-hilink.md](huawei-hilink.md), [zte-tenda.md](zte-tenda.md), [mediatek-mifi.md](mediatek-mifi.md), [asr-duster.md](asr-duster.md). Netgear and Yota are covered below.

## Dispatch

`metrics_json` chooses the backend by `_api_vid` (the `vidpid` of the modem section, or `19d2:web` when the section has `hl_api=zte`):

| VID:PID | Backend | Transport |
|---|---|---|
| 19d2:0565 | `yota_metrics_json`, then `zte_metrics_json` | Yota `GET /status` (key=value), ZTE goform |
| 19d2:* (and `hl_api=zte`, for example MediaTek 0e8d:2004) | `tenda_metrics_json`, then `zte_metrics_json` | Tenda `goform/getModules`, ZTE goform |
| 15a9:*, 1076:8002 | `yota_metrics_json` | `GET /status` |
| 0846:68e1 | `netgear_metrics_json` | AT over TCP, port 5510 |
| 1286:4e31 | `asr_metrics_json` | ASR Duster `xml_action.cgi`, HTTP Digest |
| everything else (12d1 Huawei, 1bbb Alcatel, ...) | Huawei XML | `/api/...` with SesTokInfo |

`probe` returns `{"hilink":1,"addr":...,"classify":...}`. It tries Netgear `ATI` on 5510 for 0846:68e1, then Huawei `/api/device/basic_information` (`<classify>`), then ZTE `modem_main_state`, then Yota `/status`.

The legacy scripts `modem/hilink/huawei_hilink.sh`, `alcatel_hilink.sh` and `zte.sh` are older 3ginfo-lite style collectors. They take the modem IP and print `+CSQ`-like lines from `/api/...`, `/goform/getWanInfo` and so on.

## Web login defaults

`_web_user` and `_web_pass` read `web_user` / `web_pass` from the modem section and fall back to `admin` / `admin`, the factory pair of nearly every web-API stick and Mi-Fi. Every backend that logs in (ZTE goform, Tenda, ASR Duster) takes its credentials from these two helpers. The password field on the Modem page shows `admin` as a placeholder; an empty field means the default.

## Fix the modem path once

`_hl_path` resolves the empty argument to `active_modem` **once per call chain**. A web-API poll takes tens of seconds (5 requests with 6 s timeouts, plus the session), and the active modem can change in the meantime (user, internet watchdog). In one field case a poll started on a Huawei stick and finished after the switch to a Foxconn T99W175, so the E3276 model and IMEI were written into the Foxconn section. Every top-level function calls `_hl_path` once and passes the result down.

## Modem address and source address

- `_addr_for`: the modem is the default gateway on its own network card (`netdev` from the uci section, or `listmodems.sh` if it is not stored yet). The address is not hard-coded as 192.168.8.1, because firmwares differ (an E3372h used 192.168.43.1) and users change it. Without a default route (metric or policy routing), the code assumes `.1` in the card's subnet.
- `_srcip_for`: requests are bound (`curl --interface <ip>`) to **our** address in the modem's subnet. Some firmwares also put the real WAN address on the card (for example `100.81.31.131` and `192.168.43.2` on the same `eth3`). The kernel then picks the wrong source, the modem ignores the request, and the API goes silent.

## Output rules

- An empty or refused answer prints **nothing** and returns non-zero. `5gmodem.sh` then keeps the previous snapshot. A blank JSON would be cached over a good snapshot and show dashes.
- `jsafe` strips control characters and escapes `\` and `"`. One bad byte breaks the parsing of the whole response on the page, and it looks like "no data".
- `_xesc` escapes user text (`&`, `<`, `>`) for XML request bodies. Without it, an SMS with `&` gave an invalid document and an error code. The send failed every time.
- Values from `mccmnc.dat` need `tr -d '\r'`, because the file is CRLF. `\r` inside JSON passes `jsonfilter` but breaks `JSON.parse` in the browser, and both pages stayed empty.
- The operator name comes from our `mccmnc.dat` when MCC/MNC is known, so it is spelled the same as on the AT path (firmwares send "MegaFon RUS", "MTS RUS"). After that, `opname_brand` (from `lib.sh`, via `apn.list` and the IMSI) replaces the host operator with the MVNO brand, for example 250-62 is T-Mobile under Tele2. HiLink gives no SPN.
- `signal` goes through `sig_percent` (from `lib.sh`): the RSRP/RSRQ/SINR triad comes before RSSI and firmware "bars". RSSI measures the whole channel with interference and overstates at the cell edge. Bars are coarse (20% steps) and vendor-specific. RSSI is a fallback (3GPP scale: -113 dBm = 0%, -51 dBm = 100%).
- `csq` is derived from RSSI by 3GPP 27.007: 0 = -113 dBm, 2 dB steps, 31 = -51 dBm.
- `"hl_modes":"1"` tells the modem card that the backend manages bands (ZTE goform, ASR). Without it the card hides the frequency block for every HiLink modem except Huawei and those with a debug AT mode.
- Traffic is not taken from the modem. When a backend answer has no `rx`, the hilink branch of `5gmodem.sh` adds `rx`/`tx` from the router's own counters on the interface's `l3_device` (and `iface` when missing), the same way the AT path does. A new backend gets the traffic row for free.
- `conn_time` uses the main path's format (`"0d, 00:02:59"` plus `conn_time_sec`). Traffic goes through `_human` in ifconfig units (MiB/GiB), so the two modem classes look the same.
- `cport` is the web-API address and `protocol` is `HiLink (web API)`, so the "Modem info" block has values.
- Model and IMEI are written into the uci section only when they differ. For HiLink modems nothing else stores them, so without this the section kept the previous modem's data on the same USB path (a Huawei showed an FM350 name and IMEI). The write happens only when the section is a HiLink one (`kind`). If the path points to a regular modem, the values still go to the JSON but are not written to the config.

## Sessions and caches (`/tmp/5gmodem`)

| File | Purpose |
|---|---|
| `hilink_<addr>` | Huawei `SesInfo<TAB>TokInfo`, reused for reads while younger than 1 minute |
| `ztestok_<addr>`, `.fail` | ZTE `stok` cookie (5 min); failed login backoff (15 min) |
| `ztepath_<addr>` | detected goform path pair (30 min) |
| `ztejar_<addr>` | cookie jar for the `JSESSIONID`-style login (MediaTek Mi-Fi) |
| `tendaapi_<addr>`, `tendaauth_<addr>`, `.fail` | Tenda API detection (10 min), `password` cookie, login backoff (15 min) |
| `zteapi_<addr>` | marks that the "API did not answer" log line was already written this boot |
| `mtkadb_<addr>`, `mtkcell_<addr>`, `mtktemps_<addr>` | ADB enable throttle (10 min), AT cell cache (8 s), temperatures (1 min) |

Login failures are backed off for 15 minutes so that the stick does not lock its web login. The web password is `5gmodem.m_<path>.web_pass` (user `web_user`), with `admin` as the default.

## Yota (15a9:*, 1076:8002, 19d2:0565)

`GET http://<addr>/status` returns `key=value` lines: `DeviceName`, `FirmwareVersion`, `State`, `InterfaceType`, `3GPP.IMEI/IMSI/MSISDN/RSRP/RSRQ/SINR/RSSI/MCC/MNC/CI/LAC/RoamingStatus/SPN`. `3GPP.CI` is hex, and eNB = CI >> 8. `State` may be localised (`Подключено`). Registration is 5 when `RoamingStatus=1`.

## Netgear (0846:68e1)

These Netgear Aircard/Nighthawk sticks expose AT over TCP on `<addr>:5510`. `_ng_at` sends `ATE0` plus the command through `nc` with a 6 s timeout. `AT!GSTATUS?` (Sierra format, see the Sierra doc of the Qualcomm family) is parsed for System mode, Mode, and per-carrier `PCC:` / `SCCn:` blocks (band, bw, Rx chan, RSSI, RSRP, RSRQ, RSSNR, Tx power, Cell ID, PCI, TAC). Model, revision and IMEI come from `ATI`. `cport` is shown as `<addr>:5510`.

## USB composition switch (`hilink.sh mode debug|normal`)

Some HiLink modems can expose serial AT ports (called "debug mode" in their web UI). After the switch the modem becomes a normal AT modem with TAC, band, EARFCN, USSD and an AT console. On an E3372: 12d1:14dc -> 12d1:1566, six ports in about 10 s. This is never done automatically, because it changes the modem's behaviour and can disable its web UI. Huawei uses `POST /api/device/mode <mode>1</mode>`. ZTE/Tenda use `goformId=SET_DEVICE_MODE&debug_enable=1` followed by a reboot (Tenda `deviceAction`, otherwise `REBOOT_DEVICE`).
