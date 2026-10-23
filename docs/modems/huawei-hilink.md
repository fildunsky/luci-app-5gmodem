# Huawei: HiLink web API and AT-mode sticks

Huawei E3372/E3272/E3276 sticks come in two kinds. A HiLink composition (for example 12d1:14db / 12d1:14dc) has only a network card and is handled by `hilink.sh` through the Huawei XML API (shared architecture: [web-api-sticks.md](web-api-sticks.md)). A "stick" or debug composition has serial AT ports and uses an AT metrics profile. See also `docs/E3372-NDIS-MODE.md`.

## Supported USB IDs

| USB ID | Mode | Profile / backend | Metric sources |
|---|---|---|---|
| 12d1:14db, 12d1:14dc and other HiLink PIDs | HiLink (web API) | `hilink.sh` (Huawei XML) | `/api/device/information`, `/api/monitoring/status`, `/api/device/signal`, `/api/net/current-plmn`, `/api/monitoring/traffic-statistics` |
| 12d1:1506 | stick (NCM/QMI) | `modem/usb/12d11506` | `at^chiptemp?;^hcsq?;^iccid?`, `at^hfreqinfo?`, `ati`, `AT+GSN`, `AT+CIMI` |
| 12d1:1566 | E3372 debug mode (after `hilink.sh mode debug`) | `modem/usb/12d11566` (sources `12d11506`) | same as 12d1:1506 |
| 12d1:155e | stick | `modem/usb/12d1155e` | same set as 12d1:1506 |
| 12d1:156c | stick | `modem/usb/12d1156c` | `at^chiptemp?;^hcsq?`, `AT^HFREQINFO?`, `AT^ICCID?` |

## HiLink XML API

### Session

Every request needs a `SesInfo` + `TokInfo` pair from `/api/webserver/SesTokInfo`, sent as `Cookie:` and `__RequestVerificationToken:`. For writes the token is single-use, so `api_post` always fetches a new pair. Reads reuse the cached pair and refresh it on the first error, not on a timer: one extra request is cheaper than guessing the token lifetime.

`api_get` retries once on `125001/125002/125003`, and also on an **empty** body. Some firmwares answer a stale session with an empty body instead of 125003. Before this, the empty answer went up as is, every field was blank, and `5gmodem.sh` cached the blank over a good snapshot.

### XML parsing (`xval`)

- Endpoints format XML differently. `monitoring/status` has one tag per line, `dialup/connection` puts all tags on one line. `xval` first adds a newline before every tag. The old line-based parser returned empty on single-line XML, so data roaming read as "off" while it was on.
- The newline is a **literal** newline in the sed replacement. busybox sed does not expand `\n` in the replacement, and all fields came out empty.
- `tr -d '\r'` is required, because the firmware sends CRLF and the `$` anchor did not match.

### Fields and quirks

- The API gives only the model (`E3372`). The vendor is added from the section's VID (12d1 Huawei, 1bbb Alcatel).
- The phone number is `Msisdn`. It goes into `phone`, the same key that the AT path fills from `AT+CNUM`.
- Signal bars are in `SignalStrength` or `SignalIcon`, depending on firmware. On E3372h 22.300.09 the first is empty.
- **Roaming state vs setting**: in `monitoring/status`, `RoamingStatus` is the **setting** ("roaming allowed"), and the actual state is `cellroam`. Reading `RoamingStatus` showed the roaming icon on the home network. The setting is published separately (`allow_roaming`) for the data-roaming toggle.
- `cell_id` is **decimal**: 93540375 < 2^28 fits a 28-bit LTE ECI, while as hex it would be about twice the maximum. eNB = ECI >> 8, sector = ECI & 0xFF.
- `ConnectionStatus` 901 means connected. `CurrentNetworkType` codes are decoded by `nettype_name`, and unknown codes are shown as numbers.

### Data roaming (`getroaming`/`setroaming`)

The setting is `RoamAutoConnectEnable` in `/api/dialup/connection`, the same toggle as in the stick's web UI. The firmware itself decides whether to dial in roaming. It accepts only the **full** field set: posting just `RoamAutoConnectEnable` resets the rest (MTU becomes 0, auto-dial turns off). So `hl_setroaming` reads the current fields and rewrites one.

### SMS

- `sms_list` prints the `sms_tool -j` format (`{"msg":[...]}`), so the pages parse AT and HTTP SMS the same way. The firmware joins multipart messages itself, so `part/total` is 1/1. BoxType 1 is the inbox, 2 the outbox.
- Records are emitted on `</Message>`, not on `<Smstat>`. `Smstat` comes first in the block, and emitting on it produced an empty first record and shifted the rest by one.
- `Content` can be multiline, so it is collected up to the closing tag.
- The length in `send-sms` is counted on the original text, not on the XML-escaped one.

### USSD

USSD works through the API (`/api/global/module-switch` has `ussd_enabled=1` on a tested E3372h). `hl_ussd` releases any open session (`/api/ussd/release`), sends the code, and polls `/api/ussd/get` for up to 30 s. `111019` means "still processing" and is not an error. On MegaFon no answer came within 30 s, which is a normal outcome. The multiline answer is joined, and the session is released after it. Without the release, the next request fails with "session busy".

### Bands and network mode (`/api/net/net-mode`)

- `LTEBand` is a hex bit mask with bit 0 = B1. Checked live: `800C5` = B1, B3, B7, B8, B20 (1+4+64+128+524288). "All" values are left as "no restriction" and are not expanded into a list.
- `NetworkBand` holds 2G/3G bits that are **not** sequential, and some of them are above bit 32. The values were verified on an E3372 (`net-mode-list` combo mask `2000000400380` = B1|B8|GSM900|GSM1800, and `NetworkBand=400000` moved the modem to 3G 2100):

  | Band | Bit (hex) |
  |---|---|
  | WCDMA B1 2100 | 400000 (verified) |
  | WCDMA B2 1900 | 800000 |
  | WCDMA B5 850 | 4000000 |
  | WCDMA B8 900 | 2000000000000 (bit 49, verified; not 0x2000000 as in common tables) |
  | GSM 900 | 300 (verified) |
  | GSM 1800 | 80 (verified) |
  | GSM 850 | 80000 |
  | GSM 1900 | 200000 |

- In Auto the firmware reports `NetworkBand=3FFFFFFF` (all low 30 bits), which does not include extended bits such as B8. `_hl_nb_all` treats it as "all supported bands", so the UI shows all boxes ticked. A real restriction never produces 3FFFFFFF.
- When the UI sets 3G bands, the 2G bits are kept and the other way round. With "no restriction", all supported bits of the other RAT are kept. `LTEBand` and `NetworkMode` are not touched. The modem accepts only bits from its `net-mode-list`.
- `NetworkMode`: 00 auto, 01 2G only, 02 3G only, 03 4G only. Changing mode or bands through the API does not drop debug mode, unlike `AT^SYSCFGEX`. `hl_setmode` keeps the current band fields.

## AT profiles (12d1:1506 / 155e / 156c)

- `^HCSQ:"LTE",<rssi>,<rsrp>,<sinr>,<rsrq>`: RSSI = v-121, RSRP = v-141, SINR = -20.2 + v/5, RSRQ = -20 + v/2. `^HCSQ:"WCDMA",<rssi>,<rscp>,<ecio>`: Ec/Io = -32.5 + v/2. RSSI (field 3) was not parsed before, so the card showed a dash.
- `^HFREQINFO` frequencies are used in `$((...))` only when they are numeric. An empty field gave "arithmetic syntax error", which aborts the whole sourced profile, and the card stayed empty (not registered, busy port, firmware without `^HFREQINFO`).
- `case` is used instead of `[[ == *...* ]]`. In busybox ash the pattern inside `[[ ]]` is glob-expanded against the current directory, which gave "unknown operand" and a branch that never ran.
- `^CHIPTEMP`: 65535 means no sensor, values above 100 are tenths of a degree, and the maximum is taken.
- Model capitalisation changes only the first word (vendor). `tolower()` on the rest turned "E3372" into "e3372".
- The protocol comes from the active modem's own sysfs ID. `12d1156c` used to have the string `Vendor=12d1 ProdID=1506` copied from another profile, so its protocol was never detected.
