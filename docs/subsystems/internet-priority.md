# Internet priority, failover and the widget row

`netpri.sh` (backend) and `view/modem5g/netpri.js` (frontend) implement the "Internet priority" block on the Network page and the status page. The backend lists every uplink of the firewall `wan` zone (plus the extra uplinks from `lib.sh: extra_uplink_nets`, e.g. LAN-DHCP on single-port routers), labels it (modem model + operator, Wi-Fi SSID, WAN), and makes one ordering of them live by rewriting route metrics. The frontend draws one card per uplink in priority order, lets the user click ("make first") or drag cards to reorder, and shows a right-hand group of widgets (ping cards, service cards, web-panel cards for SSClash/nikki, speed test). Failover is plain kernel routing: metrics are unique ranks, and when the first uplink loses its default route the next metric wins.

Verbs: `list`, `status`, `set <iface>`, `order <if1> <if2> ...`, `worder <key> ...`, `refresh`, `op <iface> [fresh]`, `adoptzone <iface>`, `ping <host>`, `svcstatus <svc>`, `svcall <svcs> <kinds>`.

## Metrics and live re-ranking

- Metric base is `_metric_base`: 100 by default (100, 110, 120 ...), so tunnels (WireGuard, ZeroTier, ...) keep the whole 1-99 range below the uplinks (issue #12). The "mwan3 compatibility" option returns the old base 10 (10, 20, 30 ...), the mwan3 convention. Step 10 leaves room to insert a link without renumbering. Old header comments that mention metric 1 are stale.
- `set` puts the chosen interface first and keeps the rest in current order; `order` takes the full order from a drag. Both write uci metrics (so netifd reapplies them on the next event: redial, hotplug) and then re-install routes live with `ip route`, without `network reload`. A reload would redial modems and drop PDP sessions; changing a default route metric is a pure routing-table operation.
- Routes are re-installed even when uci did not change: the health watchdog (`health.sh`) moves traffic with a penalty metric without touching uci, so uci can match while the live table does not. An early exit made a click look ignored until the next watchdog round.
- Unique metrics are required: two defaults with the same metric collide in the kernel (`RTNETLINK: File exists`), which is why a naive "change metric in place" did not work.
- Arguments are validated against `wan_nets`. Without it `set lan` would reach `_add_default_route` and the on-link branch would add `default dev br-lan scope link`, sending all internet traffic back into the LAN.
- Picking an uplink manually (set/order) clears the watchdog's "demoted to the end" mark (`failback=demote`).

### Add first, then delete (`_rerank_default_route`)

- Between `del` and `add` the router has no default route; a call interrupted exactly there leaves it offline until the next netifd event. So the new route is added first and the old one removed after.
- If the wanted metric is held by a neighbouring managed uplink, `_free_metric` releases it, but never removes the last default route of a table. If the metric stays taken, the first pass takes any free metric and a second pass finishes the job once our own route exists.
- Success is checked by inspecting the table, not by exit code: `add` on an existing route answers "File exists" and that is success.
- `ip route del default dev X` removes exactly one route per call. With several defaults on one device (different metrics, `via` and on-link forms) the leftovers accumulated with every switch (six default routes instead of two were observed). `_del_default_family` deletes them one by one from the actual list.

### Gateway lookup (`_add_default_route`)

- The gateway comes from netifd, not the live table: a non-primary interface may have no default route at the moment.
- Interfaces with their own routing table (`ip4table`/`ip6table`) get their default in that table; editing `main` did nothing (issue #12). `_route_tables` returns main plus the interface's (and its IPv6 sibling's) tables; the value can be a name from `rt_tables` or a number.
- qmi/mbim protocols put the IPv4 address and gateway on a dynamic child `<name>_4` (proto dhcp) on the same device; the parent's route list is empty. The child is consulted too. Without it an on-link default was installed, which on 802.3 framing (ECM/NCM, some MBIM) means "the whole internet is directly reachable": the device ARPs every address and traffic dies.
- No gateway and the device is not point-to-point: no route is invented. A cabled WAN that got a /16 address without a router option (WH3000 Pro, 25.08.2026) used to get `default dev eth1 scope link`, which looks like success but is a black hole.
- `0.0.0.0`/`::` gateway means a real on-link route (cellular point-to-point) and needs `scope link`. For a /32 address (Wi-Fi client, cellular) the gateway is not on-link, so a host route to the gateway is added first, as netifd does.
- The IPv6 default usually lives on a sibling network (`wan6`, `<name>_6`) on the same device. The delete phase removes both families from the device, so the IPv6 gateway is also looked up on siblings; otherwise every priority switch killed the IPv6 default until the next netifd event.
- One default per device (`_add_once`): the IPv6 sibling shares `l3_device`, and adding a route per network piled up entries (5 routes after one click, 7 after six).

### Source-specific IPv6 defaults

`default from <prefix>` routes (one per delegated prefix, installed by netifd) are excluded everywhere (`_default_metrics`, `_del_default_family`, `_free_metric`). Add/del by dev+metric is not the inverse operation and loses the `from` selector; such routes were being rebuilt as plain defaults (VOS 5G / SG500M2-X, 13.09.2026). They also must not count as "the last default in the table", or the guard would remove the last plain default. Known limitation: IPv6 priority of source-specific routes is not re-ranked.

### Non-default routes (`_rerank_iface_routes`)

netifd applies the interface metric to subnet routes as well (`10.31.67.0/24 dev X proto static metric N`). Only re-ranking the default left subnets on the old metric until an interface restart, which changes path selection with overlapping subnets or policy routing (issue #12). They are moved add-then-delete, so a failed add never loses local connectivity. Routes without a `metric` field (`<gw> dev X scope link`) are not ours and are left alone.

## Which uplink carries traffic (`live_dev`, `_iface_by_dev`, `status`)

- uci order and reality differ while the watchdog has moved traffic with a penalty metric, so the active uplink is the device of the default route with the lowest live metric. A route without a `metric` field is metric 0, the most preferred; take the minimum over all lines, not the first line.
- `list` (field `live`) and `status` share the same function, so two parts of one panel cannot show different active uplinks.
- Device to interface uses the same `_IFMAP`. The parent name is returned even when the address sits on the `<name>_4` child; the child (suffix cut) is only a fallback.
- `status` is a cheap read-only verb for theme widgets/status pages/third-party apps: routing table, interface dump and the watchdog section only, no loop over interfaces. Because it never writes, it can be granted to a read-only ACL group. No default route gives an empty field, not an error. It also returns the metric base so readers can interpret metrics.

## `list` performance

`list` is polled by the page, and every field used to cost processes. Measured before optimisation: 690 ms and about 145 subprocesses per call (70 uci, 34 sed, 19 jsonfilter, 11 ifstatus), later 0.58 s and 69 subprocesses. The current shape:

- `ifdump_snapshot`: one `ubus call network.interface dump` per call instead of `ifstatus | jsonfilter` per field (byte-identical answers were checked against ifstatus).
- `ifmap_build`: one awk pass over the pretty-printed dump builds `iface|up|l3_device|ipv4`. The name opens a record, first values win, the `"inactive"` block (it holds previous addresses) stops collection, and a `want4` flag keeps IPv4 addresses apart from IPv6/routes. `_ifmap_get` matches from line start only (a prepended newline), otherwise `wan` would match the tail of `wwan`. The map is authoritative for absent interfaces too: a missing `<name>_4` child is normal and returns empty instead of falling back to jsonfilter.
- `ucimap_build`: `_NETMAP` (`iface|proto|device|disabled|metric`) and `_M5MAP` (`m_* section|network|path|parked|kind`) from the uci snapshots; a lookup in a 300-byte map is far cheaper than scanning a 3-5 KB dump (about 80 ms per interface before).
- `ms_map_build`: interface -> modem section map. The previous memoisation never worked: `modem_section` is called from `$(...)`, and an assignment in a subshell dies with it (same trap the registry had). `_if_scan` must likewise be filled from the main shell, at the top of the loop body.
- `lm_snapshot`: `listmodems.sh` once per call instead of three times.
- `json_esc` only forks `sed` when there is a quote or backslash to escape (practically never).
- Wireless config snapshot (`_np_wlsnap`) is taken once and only on demand.
- Poll cadence in netpri.js is 15 s, not 5 s: at 5 s the list consumed more than a tenth of router CPU, almost always for an unchanged answer. Every user action (set, drag, adoptzone) re-reads the list itself, so the poll only serves passive changes (a modem gaining/losing an IP). The modem card has its own fresher poll.

## What `list` shows and hides

- Sorted by name with natural order, like LuCI's Interfaces page; `uniq` because the firewall zone can accumulate duplicates (see `mkiface.sh`).
- IPv6 siblings are hidden. A sibling is identified by protocol (`dhcpv6`, `6in4`, `6to4`, `6rd`) or a device reference to the parent (`@wan`), not by a trailing `6`: our sixth modem interface is `modem6` and vanished from the list when `modem` also existed (seen with a Quectel EC21 replacing a Telit). Our dynamic children are named `<name>_6`.
- Absent modems are hidden: the interface stays in config and zone (the modem may return) but cannot carry traffic. A modem interface is hidden only if none of its modem sections is present; a stale section from a previous modem on the same port must not hide the live one. A section without a path is a parked profile (`modemswitch.sh: park_profile`) and counts as absent (modem4 of a Compal kept showing after an E3372 came back). Legacy single-modem config without a path: shown as before.
- An interface with an address is never hidden, but its type is downgraded to `other` after the hide decision. Case 03.08.2026: a phone in USB tethering first exposed an AT port, got a modem section, then switched to pure tethering; the section kept owning the interface and the working uplink disappeared. Downgrading in `iface_type` itself would stop hiding truly removed modems, and without the downgrade `model_for` would label the phone with another modem's name ("Fibocom FM350-GL").
- Interfaces whose explicitly named device does not exist are hidden (also `/dev/cdc-wdmN` or sysfs-path devices that no longer exist), which covers orphans whose modem profile was deleted ("modem4" on eth3 after a Huawei was removed). Empty device fields and MM sysfs paths are not judged by name.
- Modems and Wi-Fi without an IP stay visible (re-dialing after a switch must not make the card vanish). A cabled WAN without an address is hidden: there is no "re-dialing" phase for a cable.
- Wi-Fi STA orphans outside the `wan` zone (17.08.2026: LuCI's "Join network" wizard only assigns a zone if the user picks it) are appended with `nozone`; clicking the card calls `adoptzone`, which is gated: the interface exists, a `wifi-iface` with `mode=sta` is bound to it, and it is not in the zone yet. Tunnels and bridges are never pulled in.
- A comma is printed only after a previous element; with an empty main list the orphan produced `[,{...}]`, JSON.parse failed and the panel froze on the cached list (audit 12.09.2026).
- The last element carries the watchdog event and the failover switch state, so the page needs no extra poll.

### Uplink type (`iface_type`)

Modem detection comes before the Wi-Fi guess because a modem's `l3_device` can be `wwanN`. Wi-Fi is decided from the wireless config (same rule as `health.sh: is_wifi_iface`), not by the presence of a device: when the station drops the device disappears, the type became `other`, and the "Heal Wi-Fi" option vanished from the modal exactly when it was needed. A wired uplink with a different name (single-port LAN-DHCP, renamed wan) gets the wired card; only an interface actually named `wan` is labelled "WAN", others keep their real name.

### Model name (`model_for`)

Order: user-defined name (resolved by `listmodems`, bound to IMEI) > model from the main poll's `AT+CGMM` in the modem section > normalised `model` from `listmodems` (same as the modem tabs) > USB descriptor with VID:PID table > brand by VID.

- Descriptors lie: SimCom says "SimTech, Incorporated", Quectel EC21 says "Android", Compal "VOS_5G"; `1e0e:9001` is shared by SIM7100/7600/8200.
- The section model is dropped if it belongs to a previous modem on the same USB path (the poll writes `model` only for the active modem; "Compal RXM-G1" stuck in an FM350 section) or fails the hardware stamp check also used in `listmodems` (03.08.2026: during an active-modem flip-flop CGMM was read through another port and "Fibocom FM350-GL" was written into a phone's section).
- Without the `listmodems` model the same modem was "T99W175" in the tab and "Generic Mobile Broadband Adapter" here (`05c6:9025`, 30.07).
- VID `05c6` (Qualcomm) is not mapped to Compal: it is shared by Compal RXM-G1, Foxconn T99W175, Dell and Thales. Compal is detected by `VOS_5G`/`RXMG1`.
- The three `listmodems` fields are read with one jsonfilter call (fixed key order, empty values keep order).

## Operator name

- `operator_cached` is cache-only and instant; `list` uses it, `refresh` fills it in the background, cache lifetime 30 minutes. It must not touch the network: a HiLink HTTP request here used to delay opening the Network page by seconds.
- The main poll's name (`/tmp/5gmodem/op_<iface>`, written by `5gmodem.sh`) has priority over our own probe cache: only the main poll decodes UCS2, `mccmnc.dat` and MVNO (Tele2 network 25020 -> "T-Mobile" brand). The probe knows only the network name and used to show "Tele2" where the main card showed "T-Mobile". The probe cache is the fallback because the main poll only writes the active modem.
- HiLink modems: name from the modem API (`operator_probe`, background); the interface address is the modem's LAN (192.168.43.2), so `list` shows the operator-assigned address from the API instead.
- ModemManager modems: name from `mmcli` (AT+COPS conflicts with MM, and is often empty on MBIM/QMI). The MM index must be the one of this modem's path, not the active modem: a bare `mmindex` showed the neighbour's operator for a SIM-less T99W175 for 30 minutes (two-modem setup, 30.07). Unknown path means no query, since an empty argument means "active". No name from MM: stop, do not fall through to AT probing; MM owns the ports, and AT+COPS into its GPS/service tty (DW5821e in low-power while MM tried to enable it) cannot help and can hurt.
- AT path: saved `at_port` first, then the current ttys from `listmodems` by stable USB path (ttyUSB numbering is unstable). The dial port is never probed (`lib.sh: drop_dial_port`): on xmm/atc the same tty carries data, and the periodic `AT+COPS=3,0` dropped the session (L860-GL, 06.09.2026). If the section has no AT port, the global one written by `detect.sh` is used; otherwise candidates started from the first tty, which on Android sticks is a mute DIAG port and each probe waited 5 s under the lock (Cudy TR3000, 18.08.2026).
- `_npri_at` uses `lib.sh: at_query` with 5 s timeout and only 3 s queue wait. Exit code 2 means "port busy": losing one name update is cheap, jumping the queue corrupted another reader's answer.
- `AT+COPS=3,0` then `AT+COPS?`; doubled long names are collapsed ("T-Mobile T-Mobile"). The numeric format is always queried too, because the canonical spelling comes from `mccmnc.dat` via `opname_pretty` ("MegaFon RUS" -> "Megafon"); the same normalisation is applied to `mmcli` names. `mccmnc.dat` has CRLF endings, so `tr -d '\r'` is needed.
- `refresh` is throttled to once a minute.
- `op <iface> fresh` (APN autofill in the interface form) bypasses only our own cache; for the active modem it asks the main poll to re-read (`cached`, not `json`, to reuse a fresh snapshot from the page or 5gtop and avoid the port contention that tripled poll time). Writing the main poll's file from here would put the wrong operator on a non-active interface.

## Background refresh and rpcd

`( netpri.sh refresh & ) >/dev/null 2>&1 </dev/null &` redirects the subshell, not the inner command. With `( cmd >/dev/null 2>&1 & ) &` the subshell kept the inherited stdout, rpcd waited for EOF until the probe finished, and the Network page hung for 11 s on open.

## Health watchdog fields in `list`

- Health comes from the watchdog state file and the uci snapshot, without subprocesses. No file or monitoring off: no field, no dot.
- A link whose device is gone stays listed (it must survive re-enumeration during healing) and is hidden after a grace period: long while healing is in progress (a module reload ladder takes minutes), two minutes otherwise.
- The ladder type is reported by the backend because steps differ (`health.sh`): modem: ifup, `AT+CFUN=1,1`, USB power; Wi-Fi: reconnect, station REASSOCIATE, radio rebuild, network reload; HiLink: second step via its API. The card used to print "AT+CFUN=1,1" for a Wi-Fi failure.
- The failover switch state is included so the page can warn when the first-priority link has no internet and the watchdog is not allowed to move traffic (case: a Wi-Fi uplink attached to an AP without internet held all traffic over four working modems).

## Service cards (`svcstatus`, `svcall`)

- Running state is parsed like `lib.sh: svc_running`: a non-procd init script prints help and exits 0 for `status`, so passwall2 always looked "running".
- Version is shown for every service (package name usually equals the init script name). It is cached, but the cache is valid only while it is newer than the package database: a boot-lifetime cache showed ZeroTier 1.16.0 after an upgrade to 1.16.2 (06.08.2026).
- ZeroTier shows the router's address in the ZT network, taken from the `zt*` interface rather than `zerotier-cli` (needs the authtoken, slower); first address only.
- `svcall` returns all service and web-panel branch states in one call instead of N parallel `exec_direct` spawns every 5 s. Branches: `go`/`legacy` -> `ssclash.sh`, `nikki` -> `nikki.sh`, all sharing the same verb contract.
- Services that have their own web-panel card are excluded from the generic list (derived from the branch map, not by name), otherwise they were polled twice and coloured by two handlers. The `ip` field must be passed through for ZeroTier.

### svcall empty list

`fs.exec_direct` joins arguments with spaces and an empty argument disappears. On a router without generic services the call became `svcall go`, the ssclash branch arrived as service "go" and the SSClash dot was red with a live service. Empty lists are therefore sent as `-`, and the backend skips `-`.

## Web-panel cards

Three independent branches, each with its own card, state, cache and poll (several can coexist: 5.x is often installed over 4.7, nikki next to either):

| svcwidget | branch | project | script | panel path |
| --- | --- | --- | --- | --- |
| `ssclash` | `go` | SSClash-Go 5.x | `ssclash.sh` | `/` (port 9091) |
| `clash` | `legacy` | luci-app-ssclash 4.7.x | `ssclash.sh` | `/ui/` via core external-ui |
| `nikki` | `nikki` | OpenWrt-nikki / mihomo | `nikki.sh` | `/ui/` or `/ui/<name>/` |

- Identifiers `_ssc`, `ssClashBtn`, class `netpri-ssclash`, the localStorage key and the go/legacy `wkey` are historical (from when both branches were SSClash). `wkey` is stored in `widget_order`; renaming it breaks saved card order. `PANEL_BRAND` maps a branch to name, icon and script.
- The card is shown whenever the user configured the service; detect only fills port/version/state, and its failure does not hide the card.
- nikki dashboards (zashboard, metacubexd) need the API parameters in the URL, otherwise they show a connection form; the link uses the same set as `luci-app-nikki` (`tools/nikki.js: openDashboard`). The API secret is never written to localStorage; every cache write goes through one helper.
- The nikki icon is an own drawing (monochrome for `currentColor`, project logos have their own licences).
- `worder` maps panel keys back to section values: section `service='ssclash'` is card `s:ssclash-go`, `service='clash'` is `s:ssclash` (`sscKindForSvc`). nikki needs no exception.
- Service cards without a web admin are informational only; clicking must not start/stop anything. Zapret Manager's admin is ttyd on 7681.

## Ping cards and Telegram (`ping`)

- One ICMP packet, 2 s timeout, over the default route.
- Clash fake-IP results (198.18.0.0/15) are measured with an HTTPS request through the normal route (that is, through clash), like a client browser; ICMP to a fake IP measures the tunnel or clash's local responder.
- ICMP silence gets a second opinion over HTTPS, because operators and services filter ICMP while the site works. Without curl: `wget --spider` and coarse timing from `/proc/uptime`.
- The router's own traffic bypasses clash (tproxy only intercepts LAN forwarding), so blocked services look dead from the router while clients reach them. The HTTP/mixed port of clash is used when present; the tproxy port is not an HTTP proxy. In fully transparent configs only tproxy exists (05.08.2026), so `_clash_ping` asks clash itself via its delay API on up to four proxy groups from `/proxies` (service groups skipped; group names are URL-encoded for spaces, non-ASCII names like flag emoji are skipped). The API secret is sent as a Bearer header, otherwise it answers 401. `/generate_204` is tried first, then `/`. The host is saved before `set --` builds the auth header, because `set --` overwrites the positional parameters.
- Telegram is never pinged: ICMP to its servers does not pass, and in RU the domain is spoofed by operator resolvers. The probe resolves `api.telegram.org`, checks the address against Telegram's official `cidr.txt`, then connects to 443 with the correct SNI (any HTTP answer is success; the root returns 404). DNS failure: fall back to 149.154.167.220 (api.telegram.org). A non-matching address returns `why=dns`, shown as spoofing, not "no connection". A fake-IP answer goes straight to the tunnel probe. No direct path (RU operators close direct 443; 03.08.2026: honest DNS, direct `000`, via mixed-port `302`): mixed-port, then `_clash_ping`.
- `cidr.txt` ships in the package; a fresh copy goes to `/etc/5gmodem` (not `/usr/share`, which the package manager overwrites). It is refreshed in the background after a successful probe, at most every 30 days, and only accepted if every line is a network, there are at least five, and none is shorter than /8 (a captive page or `0.0.0.0/0` would turn spoof detection into a sieve).
- busybox awk has no bitwise AND; `_tg_cidr_has` compares `int(ip / 2^(32-N))`. IPv6 lines are skipped.
- netpri.js: the host is escaped before use in a CSS selector; a quote or space threw synchronously after `_pingBusy` was set, leaving the card "measuring" forever and aborting init of the other widgets (audit 12.09.2026).

## Frontend (`netpri.js`)

- Widget visibility flags default to on (hidden only on explicit `'0'`); the rank background (`netpri_rank`: off/number/icon) defaults to off. Cards come only from `pingwidget`/`svcwidget` sections; defaults (YouTube, SSClash) are seeded by `uci-defaults/seed_widgets.sh`.
- Cards are sorted by metric (left = priority 1); equal metric prefers the one with an IP. Failing/gone links go to the end while being healed. The active card is the one with `live:1` from the backend, not uci order.
- Gone interfaces render as a dashed slot with skeleton bars over invisible real content (keeps size). Healing cards show step and attempt count, interface name, red dot, seconds since attempt start with a unit, and the step command labelled by the backend ladder type.
- The external IP (from `extip.js`) is shown only on the active card, or on a modem card when the per-interface channel for that modem is known (see `speedtest-extip.md`).
- Last non-empty list is kept in localStorage for an instant warm render. localStorage is keyed by origin, not router: different boards behind 192.168.x.1 showed a foreign uplink forever, so the cache is cleared after two consecutive empty answers (a single `[]` is legitimate during an `active_modem` reload). The block is never removed on an empty answer.
- `mount()` returns its container synchronously; the view inserts it later. The poller unregisters only after the block was in the DOM and then left it (earlier it removed itself on the first tick and left an empty div). The flag is reset with the poller so the next instance can register. Ping, service and other pollers are kept in a registry and removed with the block (they kept running until document reload).
- Subscriber lists (extip) are unsubscribed in pairs; each re-created block used to add a redraw callback on detached nodes.
- Theme detection uses the computed text colour of the cards, not `prefers-color-scheme` (LuCI theme is independent of the OS theme; light bootstrap on a dark OS got dark values, 03.09.2026). The class is re-checked on `<html>`/`<body>` class/attribute changes, `<link>` swaps and the system setting, because the next full redraw is 15 s away (04.09.2026). The class is set after insertion; before that `getComputedStyle` is meaningless.
- The rank number is sized from canvas `TextMetrics` and then centred by measuring the actual gaps, repeated on `fonts.ready`; fixed CSS values were right only for one theme's font.
- The health modal reuses `healthform.js` (issue #12: with the widget disabled there was nowhere to configure monitoring). The LuCI modal is a singleton inside `#modal_overlay` and is located there, because not every `ui.showModal` accepts extra classes. Its width is copied from the priority panel and set with `setProperty(..., 'important')`, because themes (proton2025: 90%/800px) use `!important`.

## Drag-to-arrange row

- Pointer events, not HTML5 drag: themes set `-webkit-user-drag: none` on buttons and there is no HTML5 drag on touch.
- Two families in one row: uplinks (`data-iface`) and right widgets (`data-wkey`). Dragging stays inside the dragged card's family; insertion is before a family member or right after the last one, never at the row end.
- Uplinks write metrics via `order`; widgets write a key list via `worder` (`p:<host>`, `s:<service>`, `speed`) into one uci option. `worder` also reorders the contents of the anonymous `pingwidget`/`svcwidget` sections over existing slots so the settings page shows the same order (section IDs stay stable); values are compared literally (`case`, not `grep`, because hosts contain dots). Unknown keys self-clean on the next drag; cards not in the saved order go to the end.
- FLIP animation in 2D; the "before" map is keyed by element, not by `data-iface` (widgets have none, all shared the key `null` and jumped). Hit testing subtracts the transform from `getBoundingClientRect`, otherwise neighbours oscillated.
- `netpri-rightstart` (`margin-left:auto`) is recomputed after every move and on drop, including the placeholder slot, otherwise widgets "stuck" to the uplinks.
- The family is captured before teardown (teardown clears `_npDrag`). The post-drop click is suppressed once for both families (a dragged widget used to start a speed test or open a panel, and the flag then ate the next uplink click). Listeners are on `document` so a lost pointer capture cannot leave a stuck drag; a stuck drag is recovered on the next pointerdown.
- Poll pauses while dragging and while `order` is applied (a tick reading `list` mid-write redrew the old order); a safety timeout clears `_npApplying` if the call hangs or redraw throws (audit 12.09.2026). Redraws from the external-IP tick are also blocked during drag.
- The in-memory widget order is updated at once and the uci.js cache is reset, because the write goes through `fs.exec` and the next tick would otherwise rebuild the old order (07.08.2026).
- A click is "make first": the new order is the clicked card followed by the rest, applied via `order`, with optimistic highlighting.

## Speed-test card

See `speedtest-extip.md`.
