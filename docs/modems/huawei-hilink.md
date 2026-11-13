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

Requests use a `SesInfo` + `TokInfo` pair from `/api/webserver/SesTokInfo`, sent as `Cookie:` and `__RequestVerificationToken:`. Token refresh sends the existing cookie to preserve an authenticated session. POSTs refresh the token before the exchange and retain rotated SessionID/token response headers. Reads reuse the cached pair for up to one minute and refresh it on a session error or an empty response.

On POST error `100003` (login required), the backend logs in once with the modem section's `web_user`/`web_pass` (defaults `admin`/`admin`) and retries the request. `/api/user/state-login` selects Base64 (`password_type=3`, also the legacy default when the field is absent) or Base64 of the SHA-256 hex digest of `username + Base64(SHA256(password).hexdigest()) + token` (`password_type=4`). This covers the legacy E5573 WebUIs; newer SCRAM login is not implemented. `base64` is required, plus `sha256sum` for type 4; missing tools produce an explicit error.

Failed logins are cached for 15 minutes to avoid exhausting the modem's login attempts. Saving the web password clears this backoff. POST exchanges have a per-modem/address lock so overlapping SMS polls cannot both log in or consume each other's tokens. Session/token errors `125001/125002/125003` get one refresh and retry; ambiguous transport failures are not retried automatically.

The local 4PDA dump `687148/posts.jsonl`, post #5078 (lidd, 2018-08-22), contains a working MR150-3/E5573Bs-320 SMS reader using type 3, login cookies and the token returned by login. Its firmware is 21.200.15.01.209 / WebUI 17.100.11.05.209_MRE5; it does not establish the login type of every 21.200.07.00.00 installation.

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

Field report, 2026-11-07: E5573Bs-320 now reports
SoftwareVersion `21.329.01.00.00`, WebUIVersion `17.100.15.02.44`, and
`password_type=4`. The SMS request in an already authenticated browser returned
a valid response with Count=3 and indices 40005/40004/40003 (RSCHS/MTC senders,
SaveType=4, SmsType=2). Content includes blank lines and hexadecimal numeric
entities such as `&#x2F;` for `/`. The parser now decodes decimal and hexadecimal
XML character references, including UTF-8, exactly once. The supplied response
format is covered by an offline regression test.

This confirms SMS API availability in the browser session, not successful router
authentication or resolution of the original app symptom. The HTTP status was
not included in the reply. The user's firmware/WebUI source links are
[firmware](https://4pda.to/forum/index.php?showtopic=687148&view=findpost&p=98900131)
and [WebUI](https://4pda.to/forum/index.php?showtopic=678549&view=findpost&p=56372827);
their contents were unavailable during this check. These observations describe
the updated firmware, not the earlier installation.

- `sms_list` prints the `sms_tool -j` format (`{"msg":[...]}`), so the pages parse AT and HTTP SMS the same way. The firmware joins multipart messages itself, so `part/total` is 1/1. BoxType 1 is the inbox, 2 the outbox.
- Records are emitted on `</Message>`, not on `<Smstat>`. `Smstat` comes first in the block, and emitting on it produced an empty first record and shifted the rest by one.
- XML is split at tag boundaries before parsing, so compact single-line and formatted responses both work. `Content` can be multiline; XML entities are decoded after collection.
- API errors and empty/truncated response envelopes return `{"error":"..."}` rather than `{"msg":[]}`. The inbox page treats this as a read failure and retains already displayed messages.
- Offline regression checks: `python3 luci-app-5gmodem/tools/hilink-tests/test_huawei.py` (requires BusyBox).
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


## Legacy address-based fallback (removed)

The older `modem/hilink/huawei_hilink.sh` collector was removed; see [web-API sticks](web-api-sticks.md#dispatch). Huawei sticks are polled only by `hilink.sh`.

Huawei POST serialization uses an automatically released flock rather than a directory lock, so killing an exporter or RPC process cannot leave POSTs permanently busy. GET token/session refresh concurrency is a separate concern and is not changed by this lock.

Session files, POST locks and failed-login backoff are keyed by both the modem path and its private address. Two Huawei devices commonly expose the same `192.168.8.1`; keying by address alone mixed their session cookies and let one failed login delay the other device. Existing address-only cache files are ignored and sessions are refreshed normally.

## E5573 debug SMS routing (2026-11-09)

Paired 3.9.25 field reports show E5573Bs-320 firmware 21.329.01.00.00 with a responding HTTP API in both `12d1:14db` normal and `12d1:1566` debug compositions. The application incorrectly treated the appearance of an AT metrics port as a reason to use AT SMS. SMS now stays on the Huawei API, independently of the AT metrics port; the USSD panel offers a separate per-modem serial-port override. The reports establish the routing defect but do not contain the failed raw SMS exchange or confirm the new implementation on the router.
