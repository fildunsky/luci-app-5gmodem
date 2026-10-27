# ASR / Marvell Mi-Fi: Duster web API

Battery Mi-Fi routers on the Marvell PXA1802 (ASR) baseband with the stock "Duster" web UI. On USB they show up as `1286:4e31` "Marvell Mobile Composite Device Bus": RNDIS on interfaces 0-1 and three vendor interfaces (2 and 6 diagnostic, 4 AT). The interface numbering is odd (no interface 3, interface 6 above the count); the kernel warns about it, nothing breaks. The device runs its own NAT on 192.168.100.1 and dials the carrier by itself, so on the router it is a HiLink-class modem: `dhcp` on the RNDIS card, metrics over the web API. Download mode is `2ecc:3001` "WUKONG".

## Do not open the AT port

`1286:4e31` is in `HILINK_IDS`, and `noat_iface` blocks all its interfaces: when `option` (or a `new_id` left from a manual test) binds them, the tty hotplug unbinds the driver again. Opening interface 4 through `option` failed with `tcsetattr: I/O error`, the device dropped off the bus, and on an IPQ40xx router the xHCI controller of that port died (`HC died; cleaning up`) until it was rebound (`echo xhci-hcd.N.auto > /sys/bus/platform/drivers/xhci-hcd/unbind`, then `bind`). On the stock firmware of this family the AT port only answers after the web debug mode is enabled, which needs a reboot of the device.

## Login

1. `GET /login.cgi` answers `WWW-Authenticate: Digest realm="Highwmg", nonce="<N>", qop="auth"`. The nonce changes on every request.
2. `HA1 = md5(user:Highwmg:password)`. Login: `GET /login.cgi?Action=Digest&username=..&realm=Highwmg&nonce=N&response=R&qop=auth&cnonce=C&temp=asr`, where `R = md5(HA1:N:00000001:C:auth:md5("GET:/cgi/protected.cgi"))`. The request also carries an `Authorization: Digest` header for `uri="/cgi/xml_action.cgi"` with `nc=00000001`. The body is empty on failure and non-empty (`first login`, `200 OK`) on success. No cookie on this firmware.
3. Every later request carries `Authorization: Digest ... uri="/cgi/xml_action.cgi"` with the same nonce, `HA2 = md5("<METHOD>:/cgi/xml_action.cgi")`, a fresh cnonce and `nc` counting up from 2. A refused request answers `<login_status>UNAUTHORIZED</login_status>` (or `KICKOFF` when another browser took the session); `_asr_call` then logs in again once.

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

`file=Engineer_parameter` (cell id, PCI, RSRQ, SINR) is empty unless engineering mode is on in `file=wan` (`Engineering_mode`); the app does not switch it on. Raw answers are kept in `/tmp/5gmodem/asrraw_<addr>_<file>` for diagnostics.
