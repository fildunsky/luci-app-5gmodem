# ASR / Marvell Mi-Fi: Duster web API

Battery Mi-Fi routers on the Marvell PXA1802 (ASR) baseband with the stock "Duster" web UI. On USB they show up as `1286:4e31` "Marvell Mobile Composite Device Bus": RNDIS on interfaces 0-1 and three vendor interfaces (2 and 6 diagnostic, 4 AT). The interface numbering is odd (no interface 3, interface 6 above the count); the kernel warns about it, nothing breaks. The device runs its own NAT on 192.168.100.1 and dials the carrier by itself, so on the router it is a HiLink-class modem: `dhcp` on the RNDIS card, metrics over the web API. Download mode is `2ecc:3001` "WUKONG".

## Do not open the AT port

`1286:4e31` is in `HILINK_IDS`, and `noat_iface` blocks all its interfaces: when `option` (or a `new_id` left from a manual test) binds them, the tty hotplug unbinds the driver again. Opening interface 4 through `option` failed with `tcsetattr: I/O error`, the device dropped off the bus, and on an IPQ40xx router the xHCI controller of that port died (`HC died; cleaning up`) until it was rebound (`echo xhci-hcd.N.auto > /sys/bus/platform/drivers/xhci-hcd/unbind`, then `bind`). On the stock firmware of this family the AT port only answers after the web debug mode is enabled, which needs a reboot of the device.

## Login

1. `GET /login.cgi` answers `WWW-Authenticate: Digest realm="Highwmg", nonce="<N>", qop="auth"`. The nonce changes on every request.
2. `HA1 = md5(user:Highwmg:password)`. Login: `GET /login.cgi?Action=Digest&username=..&realm=Highwmg&nonce=N&response=R&qop=auth&cnonce=C&temp=asr`, where `R = md5(HA1:N:00000001:C:auth:md5("GET:/cgi/protected.cgi"))`. The request also carries an `Authorization: Digest` header for `uri="/cgi/xml_action.cgi"` with `nc=00000001`. The body is empty on failure and non-empty (`first login`, `200 OK`) on success. No cookie on this firmware.
3. Every later request carries `Authorization: Digest ... uri="/cgi/xml_action.cgi"` with the same nonce, `HA2 = md5("<METHOD>:/cgi/xml_action.cgi")`, a fresh cnonce and `nc` counting up from 2. A refused request answers `<login_status>UNAUTHORIZED</login_status>` (or `KICKOFF` when another browser took the session); `_asr_call` then logs in again once.

Two factory users exist: `admin/admin` and `sysadmin/sysadmin` (more rights); some siblings ship `admin/zimifi`. With no `web_user`/`web_pass` in the section `_asr_login` tries `sysadmin`, then `admin/admin`, then `admin/zimifi`, and remembers which one worked in `asrsid_<addr>.who` (mode 600). A password set on the Modem page is used as is.

Older builds (operator-branded PXA1826 routers) use the fixed nonce `1000`, `temp=marvell`, `HA2` over `/cgi/xml_action.cgi` for the login too, and a `CGISID` cookie. `_asr_login` tries the `asr` variant first, then the `marvell` one. A failed login is not retried for 15 minutes (`asrsid_<addr>.fail`).

## Data

`GET /xml_action.cgi?method=get&module=duster&file=status1` returns one XML document with everything the card needs:

| Field | Meaning |
|---|---|
| `sysinfo/hardware_version`, `model_name`, `version_num` | model (`MF809_D`, `LV01`), firmware |
| `wan/sys_mode` | 17 LTE, 5 WCDMA, 3 GSM |
| `cellular/rssi` | LTE: RSRP index, dBm = value - 140; 2G/3G: CSQ, dBm = value * 2 - 113 (as the web UI computes it) |
| `wan/Battery_charging` | LTE band number (the web UI shows it as "Band", despite the name) |
| `wan/Battery_voltage` | battery charge, percent |
| `wan/Battery_charge` | 0 not charging, 1 charging, 2 full |
| `wan/Battery_connect` | 0 no battery |
| `wan/wan_conn_status` | `connected` |
| `network_name`, `IMEI`, `ICCID`, `MSISDN`, `pdp_context_list/Item/ipv4`, `curconntime` | operator, identifiers, carrier address, session time |

Builds without `status1` (Yota-branded LV01, some ZMI) answer `file=json_status` with JSON (`rsrp` as an index, `sinr`, `cell_id`, `status`, `con_duration`, `reg_network_name`); `asr_json_metrics` reads it. Not checked on hardware.

`file=Engineer_parameter` (cell id, PCI, RSRQ, SINR) stays empty on the MF809_D build even with `Engineering_mode=1` in `file=wan` and after a reboot; the app does not read it. Raw answers are kept in `/tmp/5gmodem/asrraw_<addr>_<file>` for diagnostics.

## Bands

A separate JSON API, `/api/band/*`, used by the "Band setting" page:

| Request | Meaning |
|---|---|
| `GET getType` | `2` = manual list, empty or `1` = automatic |
| `GET getSetting` | comma-separated LTE bands of the manual list (empty in automatic mode) |
| `POST updateType {"band":"1"|"2"}` | automatic / manual |
| `POST updateSetting {"band":"3,7,20"}` | manual list; the web UI sends `"250"` together with automatic mode |

The supported bands are the checkboxes of `html/internet/band_setting.html` (`id="bandN"`), read once a day into `asrbands_<addr>`. On MF809_D: 1 3 5 7 8 20 28 38 39 40 41 66. `hl_getbands`, `hl_setbands`, `hl_supbands` dispatch to `asr_*` for `1286:4e31`; selecting every band switches back to automatic. Network mode (`NW_mode` in `file=wan`) is not managed: `getmode` reports Auto, `setmode` is refused.

The reboot is `GET file=reset`, the same as the "Reboot" page. `hilink.sh asr get|set|api <file> [body] <path>` is a diagnostic entry for raw calls.

## SMS

All SMS calls are `POST file=message` with `<RGW><message>...</message></RGW>`; the answer to the POST already carries the list. Text and sender are UTF-16 hex (`UniEncode`/`UniDecode` in the web UI).

| Action | `message_flag` | Other fields |
|---|---|---|
| inbox / sent / SIM | `GET_RCV_SMS_LOCAL` / `GET_SENT_SMS_LOCAL` / `GET_SIM_SMS` | `get_message/page_number`; answer: `message_list/Item` (`index` like `LRCV1`, `from`, `subject`, `received` = `yy,m,d,h,m,s,tz`, `status` 0 = unread), `total_number` = pages |
| send | `SEND_SMS`, `sms_cmd` 4 | `send_save_message/contacts` (comma list), `content` (hex), `encode_type` `GSM7_default`/`UNICODE`, `sms_time` (`yy,m,d,h,m,s,%2B3`) |
| delete | `DELETE_SMS`, `sms_cmd` 6 | `get_message/tags` (12 inbox, 2 sent), `mem_store` 1, `set_message/delete_message_id` = `LRCV1,LRCV2,` |
| mark read | `SET_MSG_READ`, `sms_cmd` 7 | `set_message/read_message_id` |

The firmware renders an alphanumeric sender (TON 5) as if it were BCD digits: every semi-octet becomes `'0' + value`, so `RSCHS` (the Russian emergency broadcaster) arrives as `;2=9>01935`. `alnum()` in `asr_sms_list` takes the nibbles of such a string (only `0x30`-`0x3F`, at least one above `9`), unpacks them as GSM 7-bit at each bit offset and keeps the single offset that yields only letters, digits and spaces. Ordinary numbers (`+7...`, short codes) are left alone.

Send and delete are asynchronous: `GET file=message` returns `flag/sms_cmd_status_result`, 3 = done. `asr_sms_*` print the same JSON as the ZTE and Tenda backends (through `_zte_sms_parse`). Our numeric index is the digits of the device index, plus 100000 for the sent box; `asrsms_<addr>` maps it back to `LRCV1` and the box for delete and mark-read. An empty answer to a POST is normal here and must not trigger a new login: the query result lives in the session.
