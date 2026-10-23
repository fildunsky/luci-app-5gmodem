# ZTE and Tenda: goform web API and AT profiles

ZTE sticks and Mi-Fi devices (MF79 family, MF8xx, Tenda MF6) without AT ports are handled by `hilink.sh` through the ZTE goform API or the Tenda `getModules` API (shared code: [web-api-sticks.md](web-api-sticks.md)). ZTE routers and modules with AT ports (MF286 family, MF28D/MF290, MF821, P685M) use AT profiles with the ZTE `+ZRSSI`/`+ZCELLINFO`/`+ZCAINFO` set. MediaTek Mi-Fi devices that speak goform are described in [mediatek-mifi.md](mediatek-mifi.md). The ASR-based Notion/C300 with ZTE-like firmware is in [others-b.md](others-b.md#asr-pxa1826-notion-r281--c300-1-12864e28).

## Supported USB IDs

| USB ID | Model | Profile / backend | Metric sources |
|---|---|---|---|
| 19d2:* without AT (MF79U/MF79N, ...) | ZTE goform stick | `hilink.sh` `zte_metrics_json` | `goform_get_cmd_process?multi_data=1&cmd=...` |
| 19d2:* with the Tenda API (Tenda MF6) | Tenda Mi-Fi | `hilink.sh` `tenda_metrics_json` | `goform/getModules?modules=deviceInfo,connectStatus,batteryInfo,networkConfig` |
| 19d2:1485 | MF286D, MF289F | `modem/usb/19d21485` | `at+zrssi;+zcellinfo?;+zcainfo?`, `ati`, `AT+GMR` |
| 19d2:1489 | MF286R (ASR) | `modem/usb/19d21489` | `at+zrssi;+zcellinfo?;+zcainfo?`, `AT*MRD_IMEI?`, `AT*ICCID?` |
| 19d2:1432 | MF286, MF286A | `modem/usb/19d21432` | `at+zrssi;+zcellinfo?;+zcainfo?` |
| 19d2:1275 | P685M, ZM8630A | `modem/usb/19d21275` | `at+zrssi;+zcellinfo?;+zcainfo?` |
| 19d2:0189 | MF28D, MF290 | `modem/usb/19d20189` | `at+zrssi?;+zcellinfo?` |
| 19d2:0167 | MF821 | `modem/usb/19d20167` (sources `15081001`) | `at+zcellinfo?` |

## ZTE goform API

- Read: `GET /goform/goform_get_cmd_process?isTest=false&multi_data=1&cmd=a,b,c`. Write: `POST /goform/goform_set_cmd_process` with `isTest=false&goformId=...`. Two headers are required, `Referer: http://<addr>/index.html` and `X-Requested-With: XMLHttpRequest`. Without them the firmware answers `{"result":"failure"}` (as seen on MF79U).
- Some firmwares use `reqproc/proc_get` / `reqproc/proc_post` instead. `_zte_paths` probes both for `modem_main_state` and caches the working pair for 30 minutes.
- **Login matters for reads**: without a session the firmware fills only public fields (modem state, network type, operator, signal bars). RSRP/RSRQ/SNR, cell, IMSI, ICCID and the WAN address come back as **empty strings**, not missing (seen on MF79N, firmware `BD_XBKZMF79N`). So "empty levels with a live connection" means "not logged in". `zte_metrics_json` then logs in once and asks again.
- Login: `goformId=LOGIN&password=<base64(pass)>`, and the session is the `stok` cookie (cached 5 min). The password is `web_pass` from the modem section, default `admin`. A failed login backs off for 15 minutes, so the stick does not lock the web login.
- Writes (connect, reboot, network mode) go through `_zte_post_auth`. It tries without a session, and on refusal logs in with a cookie jar and retries. An **empty** answer selects the "login\npassword" login format used by MediaTek Mi-Fi (see [mediatek-mifi.md](mediatek-mifi.md)). Write failures are harmless: connect/disconnect are best effort.
- The first "API did not answer" is logged once per boot (`/tmp/5gmodem/zteapi_<addr>`). Before this, an API refusal looked like "no metrics", with no trace in the log.
- **Model from the firmware string**: vendor builds do not start with `MF`, for example `BD_XBKZMF79NV1.0.0B02`. The code extracts `MF<digits><letters>` from anywhere in the string and strips a trailing `V` (the version follows right after it), so the result is `MF79N` and not `MF79NV`. `hardware_version` is the fallback.
- Bars (`signalbar`) are a coarse 20% scale, so `sig_percent` over RSRP/RSRQ/SINR wins when those are present. A `lte_rssi` equal to RSRP is a fake RSSI and is dropped (on MediaTek it is `"<RSRP> dBm NN asu"`).
- Registration: `ppp_status=ppp_connected`. Roaming (5) when `rmcc` differs from `hmcc`.
- Network mode: `net_select` is read, `SET_BEARER_PREFERENCE&BearerPreference=<mode>%0A<priority>` is written (`NETWORK_auto`, `Only_GSM`, `Only_WCDMA`, `Only_LTE`; priority from `net_priority`, default `LTE_preferred`).
- Debug mode: `SET_DEVICE_MODE&debug_enable=1|0`, then a reboot.

### ZTE SMS (goform)

ZTE has no `/api/sms/*`. The messages are behind goform (`sms_data_total&page=0&data_per_page=100&mem_store=<1 modem|0 SIM>&tags=10`). The differences from Huawei:

1. **Text and number are UCS2 hex** (UTF-16BE). For example `041F04400438043204350442` is the Russian word for "hello". The router has no iconv. `_zte_sms_parse` emits JSON `\uXXXX` escapes directly, because a UCS2 code unit is exactly what follows `\u`. This avoids byte tables and any dependence on the awk locale (busybox awk is C/bytes, desktop awk is not; this tripped before). Emoji surrogate pairs pass as two `\u` escapes, and `JSON.parse`/`jsonfilter` join them. Short Latin text may come as plain text and is passed through.
2. **Numbers are decoded more carefully**: `9000` is both valid hex and a real short number. A number is treated as UCS2 only if every code unit starts with `00`.
3. **Box by `tag`**: 0/1 inbox (read/unread), 2/3 outbox (sent/unsent), 4 draft. The whole list is requested and then split.
4. **Date** is `yy,mm,dd,hh,mm,ss,+tz` in the modem's local time. Send uses `yy;mm;dd;hh;mm;ss;+<quarter hours>` (`_zte_smstime`).

- If the modem memory is empty, the SIM store is read. Firmwares disagree on which store is primary.
- **Messages are not marked read** on display. goform has `SET_MSG_READ`, but marking ahead of time would suppress the Telegram bridge, which only forwards new messages (the same rule as the AT path). Only the user marks a message read.
- `zte_sms_count` returns the Huawei XML shape (`<LocalInbox>`), so `smsbridge.sh` parses one format.
- Send: `SEND_SMS&Number=...&MessageBody=<UCS2 hex>&encode_type=UNICODE`. `_zte_ucs2hex` uses the same UTF-8 parser as `smspdu.sh`.

## Tenda Mi-Fi API

Tenda Mi-Fi devices (for example MF6, ZTE VID) use another API on the same `19d2:*` IDs. `tenda_metrics_json` goes first. If the device is not Tenda (`_tenda_on` caches the detection for 10 min), the ZTE path runs.

- Read: `GET /goform/getModules?modules=<list>`. Write: `POST /goform/setModules?modules=<name>` with a JSON body. `errCode` 0 means OK, 1000 means login required.
- Login: `POST /login/Auth {"userName":"admin","password":"<md5(pass)>"}`, and the session is the `password=` cookie. Without a stored `web_pass` the card shows `web_auth: fail` and asks for the password (key button on the Network page).
- Metrics from `deviceInfo` (mobileNetwork, RSRP, SINR, RSSI, signalStrength, networkFrequencyBand, IMEI/IMSI/ICCID, softwareVersion, profileName, wanIp, productName), `connectStatus.status`, `batteryInfo` (battery, isCharge), and `networkConfig.networkInfo.connectTime`.
- SMS: `smsList` is converted to the ZTE message shape (`_tenda_sms_conv`) and parsed by `_zte_sms_parse`. Send is `sendSms` (UCS2 hex, `UNICODE` or `GSM7_default`), mark read is `viewSms`, delete is `delSmsList`. Reboot is `deviceAction {"action":"0"}`.

## ZTE AT profiles

- `case` instead of `[[ == *...* ]]` (busybox ash expands `[[ ]]` patterns against files in the current directory, see [huawei-hilink.md](huawei-hilink.md#at-profiles-12d11506--155e--156c)).
- MF286R (19d2:1489, ASR chipset) needs the vendor identification commands `AT*MRD_IMEI?` and `AT*ICCID?`. The `MF286RA` firmware variant is detected from `AT+GMR`.
