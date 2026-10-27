# MediaTek MT6735 Android Mi-Fi (ZTE-style goform)

Some pocket Mi-Fi devices are small Android phones without a screen. They run a goform web UI that copies ZTE's, on an Android/MediaTek base, and give the router RNDIS. `hilink.sh` reads them through the ZTE goform path (`hl_api=zte`). The missing radio metrics come from the MediaTek modem over ADB, through the `rild-atci` unix socket. The shared web-API architecture is in [web-api-sticks.md](web-api-sticks.md), and the goform details are in [zte-tenda.md](zte-tenda.md).

## Supported USB IDs

| USB ID | State | Backend | Metric sources |
|---|---|---|---|
| 0e8d:2004 | RNDIS + mass storage (normal) | `hilink.sh` (`hl_api=zte`), `zte_metrics_json` + `mtk_cell`/`mtk_temps` | goform, plus `AT+ECSQ`, `AT+ECELL`, `AT+CSQ`, `AT+EPBSE?` over ADB; `/sys/class/thermal` |
| 0e8d:2008 | MTP, before boot completes (also Preloader) | same | same |

The section is `kind=hilink`, `hl_api=zte`. VID 0e8d is treated as Fibocom only for 0e8d:712x, and the ZTE brand only for 19d2.

## Hardware and firmware

- Android 6.0, MT6735 (armv7l, kernel 3.18, 32-bit userland `armeabi-v7a`). Modem firmware `MOLY.LR9.W1444.MD.LWTG.MP.V81.6.P36` (2024-04-10). Web server i-jetty, site `ROOT.war`, config `kfi/kf110`.
- The same platform is used by TianJie CPE903/905/906, KuWfi CPF9xx and AnyData R200 (4pda topic 984941).

## goform on this firmware

- All reads work without login (`goform_get_cmd_process`, `Referer` header).
- **Login**: `goformId=LOGIN&password=<base64("admin\nadmin")>`. The value is the user name, a newline and the password, base64-encoded together. The answer is `{"result":"0"}` and the session is the `JSESSIONID` cookie. `base64("admin")` alone gives an empty `{}`. Any SET without login answers 302 to `/#login` with an empty body. `_zte_post_auth` uses that empty body to switch to this format (`_zte_login_jar ... 1`, user from `web_user`, default `admin`).
- **Network mode**: `SET_BEARER_PREFERENCE&BearerPreference=<mode>\n<priority>`. Modes: `NETWORK_auto`, `Only_GSM`, `Only_WCDMA`, `Only_LTE`. Priority: `LTE_preferred` or `WCDMA_GSM_preferred`. Without the part after `\n` the server returns HTTP 500 (ArrayIndexOutOfBounds in `NetworkConfigUtil.java:682`). The current value is in `net_select`. Switching back and forth does not drop the connection.
- Available fields: `realtime_time`, `realtime_rx_bytes`, `realtime_tx_bytes`, `monthly_*`, `battery_vol_percent`, `battery_charging`, `lte_rsrp`, `signalbar`, `network_type`, `network_provider`, `msisdn`, `sim_imsi`, `imei`, `hardware_version`.
- `lte_rssi` is fake: `"<RSRP> dBm  NN asu"`. It is dropped when it equals RSRP.
- Not available even after login: RSRQ, SINR, cell_id, band. `band_list` contains only `Default`, so `SET_BAND` is useless. Without ADB/AT, the JSON carries `"na":"csq rssi sinr rsrq pband"`, and the page hides those rows.
- `SET_LTEMODE_SELECT lteModeSelect=td|fdd` switches TDD/FDD. An empty value was once written by mistake without effect on the link.

## ADB

- **Enable**: after login (`JSESSIONID`), `GET /adbWifiDebugForm.do?adb=1` answers "adb wifi debug enabled!". ADB listens on port 5555 until reboot. `propertiesForm.do?prop=persist.sys.connect.adb.wifi&val=1&action=set` should make it persistent (not tested).
- Access is root at once (`uid=0`, `ro.adb.secure=0`, no key confirmation). Anyone on the device's Wi-Fi gets root without a password.
- `dumpsys` is removed. busybox, awk and od are missing. toybox and toolbox are present.
- `_mtk_adb_on` uses an existing connection, or tries `adb connect`. Only if the connection is refused does it enable ADB through the web UI: at most once every 10 minutes (`mtkadb_<addr>`), never when `5gmodem.<section>.hl_adb=0`, and never when an adb process that we did not start is already talking to this device (`_adb_foreign` checks `_5GM_ADB=1` in `/proc/<pid>/environ`). Each adb call has a hard timeout (`_adb_to`), because adb can hang indefinitely.

## AT access over `rild-atci`

- `/dev/radio/pttycmd*`, `ptty2cmd*` and `atci1/2` are owned by `mtkrild`, which takes the replies, so a writer sees only `OK`. `/dev/ttyC0` is owned by `gsm0710muxd`. `ttyC1`-`ttyC3` are free but do not answer AT.
- **Never `kill -STOP mtkrild`**. pty writes then block, SIGCONT does not help, adbd goes offline and goform hangs, and only a reboot of the device recovers it.
- The working path is the unix socket `/dev/socket/rild-atci`, the same one the stock `atcid` uses: send `AT...\r`, read until `OK`/`ERROR`. The link is not affected. toybox `nc` has no unix sockets, so a small static client is needed.
- The client is the optional package `5gmodem-mtk-at` (`5gmodem-mtk-at/src/usock.c`, built by CI for armv7 and installed as `/usr/share/5gmodem/mtk/usock-armv7`). `_mtk_usock` pushes it to `/data/local/tmp/5gm-usock` when the size differs. `mtk_at` runs `5gm-usock /dev/socket/rild-atci '<cmd>' 3000` for each command in a single `adb shell`. Without the package the page shows `needpkg`.

### Modem answers (MTK)

| Command | Example | Meaning |
|---|---|---|
| `AT+ECSQ` | `+ECSQ: 15,49,1,1,1,-50,-366,7,2` | field 6 RSRQ in quarter-dB (-12.5 dB), 7 RSRP quarter-dBm (-91.5), 8 AcT, 9 SINR quarter-dB (0.5 dB); divide by 4, 32767 = n/a |
| `AT+CESQ` | `99,99,255,255,14,50` | 3GPP: RSRQ = -20 + 14*0.5, RSRP = -140 + 50 |
| `AT+CSQ` | `12,99` | RSSI = 2*12-113 |
| `AT+ECELL` | `2,7,"03A09623","300C",250,2,50,50,15,-364,-50,...` | count, AcT, CI (hex), TAC (hex), MCC, MNC, PCI, ...; one record per cell, serving first. **No EARFCN.** `0FFFFFFF`/`FFFF` are placeholders |
| `AT+CEREG?` | `2,1,"300C","03A09623",7` | `AT+CEREG=2` holds until reboot |
| `AT+COPS?` | `0,2,"25002",7` | |
| `AT+EPBSE?` | `154,155,524501,480` | masks GSM, UMTS, LTE FDD (bit 0 = B1), LTE TDD (bit 0 = B33). 524501 = 0x800D5 = B1,3,5,7,8,20; 480 = 0x1E0 = B38-41 |
| `AT+ERAT?` | `7,0,6,0` | rat 6 = 2G/3G/4G, prefer 0 |
| `AT+ETHERMAL?` | `3, 48, -34, -1, 32767, 18` | 48 matches `mtktspa` |
| `AT+EINFO?` | `1338` | engineering URC mask (URCs go to rild) |

- `+CME ERROR: 100` for EMMCHLCK, ECAINFO, ELTEINFO, EDRXCFG, EMDT, ERRCSTATE, EDMFAPP, EMTHC, EPCO. `AT+CGCONTRDP=1` gives plain `ERROR`.
- The current band cannot be read over AT, because no command returns EARFCN. A workaround is to leave one band in the mask and compare the cell (CI/PCI) with the original.

### Bands (`mtkbands` / `mtksetbands`)

- `AT+EPBSE=<gsm>,<umts>,<lte_fdd>,<lte_tdd>` applies at once without a reboot. `0` for TDD is accepted. Factory value: `154,155,524501,480`. Tested: "B3 only" kept the same cell, "B20 only" lost the network, "B7 only" moved to another cell with internet.
- The supported set is accumulated with OR into `5gmodem.<section>.mtk_bandcap`, because `EPBSE?` reports only the current mask. The 2G/3G part is kept as is, and "default" restores `mtk_bandcap`. The selection is masked with the capability, and an empty result is refused.
- Not yet known: whether the mask survives a reboot (if not, it would have to be restored on connect like `restorebands`), and what the 2G/3G masks (154/155) mean.

### Cell metrics

`mtk_cell` runs `AT+ECSQ AT+ECELL AT+CSQ` and caches the result for 8 s (the last good reply is used for up to 10 min). It fills RSRQ, RSRP, SINR, RSSI, CI (with eNB = CI >> 8), TAC, PCI (< 504) and MCC/MNC if goform left them empty.

## Temperatures

`mtk_temps` reads `/sys/class/thermal/thermal_zone*/{type,temp}` (milli-°C) over ADB. Mapping: `mtktspa` PA, `mtktscpu` CPU, `mtktswmt` Wi-Fi, `mtktspmic` PMIC, `mtktsbattery` battery, `mtktsAP` board (`mtktsbtsmdpa` and `mtkts1-3` are ignored). Cached for 1 minute, with the last value kept for up to 10 minutes. It is published as `temps` (`pa=.. cpu=..`), and the page renders six sensor badges.
