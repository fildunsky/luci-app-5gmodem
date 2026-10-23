# Modem network interfaces

`mkiface.sh` creates or rebuilds the netifd interface of one modem, picks its
protocol, puts it in the `wan` firewall zone, records it in the modem section
and brings it up. `msw/iface.sh` keeps existing interfaces healthy on every
`resolve` (re-pointing devices, fixing protos, detecting orphans). The netifd
handler `qmiraw` and the LuCI protocol pages `protocol/fibocom.js` and
`protocol/qmiraw.js` live alongside, as do the iface/net hotplug hooks. For
modem identity and autosetup see [autosetup.md](autosetup.md); the `fibocom`
proto itself is documented with the Fibocom modems.

## mkiface.sh arguments

`mkiface.sh [name] [proto] [apn] [pdp] [mm_exclude]`

- `proto`: `auto` (default) or any installed handler (`mbim`, `qmi`, `qmiraw`,
  `ncm`, `xmm`, `atc`, `fibocom`, `wwan`, `3g`, `modemmanager`, ...); the UI only
  offers installed ones.
- `apn`: a string applies it; `-` means "explicitly no APN" (option removed, the
  network default is used); empty means "not passed, keep the old APN". The
  distinction exists because `${APNARG:-${OLDAPN:-internet}}` made it
  impossible to clear an APN.
- `pdp`: `ipv4 | ipv4v6`; empty keeps the current value.
- `mm_exclude`: explicit 0/1 from the create form; otherwise a per-proto
  default. A box unticked by the user must not be overwritten by the default.
- `MODEM_PATH`: target a modem other than the active one (autosetup). Then the
  global `@5gmodem[0]` keys are neither written nor used as fallbacks: they
  describe the active modem. Reading the global `at_port` for an inactive modem
  used to give atc/xmm the neighbour's port as `device`, i.e. dialing another
  modem; `_mk_atport` takes the port from the registry (validated against this
  modem's ports) and falls back to the globals only for the active modem.
- `MKIFACE_AUTOFALLBACK=1`: the proto is forced by automation (mm-inhibit
  fallback, `fix_iface_proto`) and must not be stored as `iface_proto`. A stored
  forced proto is read by the `auto` branch as an explicit choice, after which
  neither driver detection nor vendor exceptions apply: a DW5821e-eSIM sat on
  `iface_proto=qmi` over a `cdc_mbim` node (uqmi "Request timed out", SIM illegal,
  forever pending).

## Ownership stamps

`stamp_iface` writes `network.<if>.modem_path` (stable USB path) and
`network.<if>.modem_imei`. The modem -> interface link used to be one-way
(`m_<path>.network`); when the section vanished (Forget, modem swap), the
interface stayed on an unstable node such as `/dev/cdc-wdm0` and the next modem
in that port silently inherited it (a Telit LM960 replacing a SIM7600 dialed
with `internet.beeline.ru` while holding a T-Mobile SIM). The IMEI is the
primary key because two modems in one port share the path; the logic is shared
in `lib.sh` (`iface_owned_by`). Unstamped interfaces are treated as ours (older
versions), and a migration backfills stamps.

## Naming

The name is the one remembered for this modem, default `modem`, bumped to
`modem2`, `modem3`, ... when taken. Taken means held by another section
(`USED`, joined with `tr '\n' ' '` so the `" $USED "` word match works for every
name; without it two modems got the same `modem`) or an existing interface
pinned to other hardware by `modem_imei` (interfaces of displaced modems are
kept for their return; a Compal once took `modem2` reserved for an E3372).

Before creating a new interface, an existing interface on the same netdev of the
same modem is reused (E3372 with an IMEI randomiser produced modem..modem4 on one
eth2; the MAC anchor is the real fix, this is a safety net).

## Proto choice

1. No cdc-wdm control node -> AT-dialed RNDIS/ECM path (FM350-GL 0e8d:7127 and
   similar: data on a usbnet `eth*`, PDP dialed by AT; MM fails with
   `UnexpectedDataValue`). Default `fibocom` (does not touch SMS, self-healing);
   `atc`/`xmm` only on explicit choice, since atc takes over SMS and holds an AT
   port open. Exception: Intel XMM (vendor 8087, L850/L860 in NCM) is
   auto-routed to the XMM path because it needs `arp off` on the NCM link (no ARP
   answers, so address but no traffic) and XDNS instead of `CGCONTRDP`. Since
   2.4.10 that logic is built into `fibocom`; an installed `xmm-modem` package is
   still respected.
   - Before deciding "no cdc-wdm", sysfs is re-checked: the registry may lag the
     hotplug by a fraction of a second, and a Compal in 1e2d:00b7 (QMI) got
     `proto=fibocom` on wwan0.
   - For atc/xmm `device` is the AT dial port, not the netdev (xmm does
     `basename $device` and looks it up in `/sys/class/tty`; a netdev there gives
     "AT port not valid!" / "Device path not found!"). The dial port is chosen in
     two passes like `detect.sh` (first a port that answers `AT+CGMM` with a
     model, then any answering port): on FM350 ttyUSB0 answers bare `AT` but is
     not the modem port (ttyUSB1/3 are). For xmm the port is validated with
     `gcom probeport.gcom`, the same tool xmm.sh uses: sms_tool and xmm disagree
     on L850 ttyACM2. The dial port is stored as `data_at_port` and kept separate
     from the metrics port.
   - atc/xmm read option `pdp` with values `IP/IPV6/IPV4V6`; `IPV4` is rewritten
     to `IP` because xmm.sh silently maps unknown values to IP.
   - PDP type, roaming flag and metric are carried across recreation.
2. Saved user choice (`iface_proto` in the section) wins over detection. A proto
   change from the UI re-enumerates the modem, and hotplug autosetup used to
   recreate the interface with `auto`, reverting e.g. a Compal from
   modemmanager back to mbim with MM disabled.
3. `auto` maps the control node driver: `cdc_mbim` -> `mbim`, `qmi_wwan` ->
   `qmi`. Driver detection beats mmcli, which misclassifies many MBIM modems
   (Compal RXM-G1) and never builds qmi over MBIM. Vendor exceptions:
   - Compal RXM-G1 in a QMI composition -> `modemmanager`: no AT band-lock
     commands, and libqmi CLI cannot write band TLVs, so bands and mode are only
     controllable via mmcli. Only with `qmi_wwan`; in MBIM MM builds a broken
     modem. `is_compal` gets the path explicitly (a global bus grep let a
     neighbouring Compal turn a T99W175 into modemmanager). For vendor 05c6 the
     decision uses the model from `AT+CGMM`, because 05c6:9091 is also used by
     Android sticks (VOS 5G / SG500M2-X: uqmi "Failed to connect to service",
     hung processes). Compal identified this way also gets
     `force_connection=1`: its first attempt after boot often fails on removing
     the old bearer and netifd would not retry.
   - 413c:81d7, 413c:81e0, 0489:e0b5 (DW5821e / T77W968, eSIM variants) ->
     `modemmanager`: umbim fails ("Failed to attach to network", treats PIN2 as
     blocker -> PIN_FAILED, "Subscriber init failed"), quectel-CM gives IP with
     RX=0; MM works on the same SIM (confirmed by five independent setups).
   - 05c6:9025 (SDX55: T99W175, Compal debug) and 03f0:9d1d (HP lt4120, Foxconn
     T77W595) -> `modemmanager`: a single cdc-wdm channel. On a kernel proto
     netifd owns it, our QMI requests are forbidden (`qmi_channel_free`), bands
     cannot be set (libqmi reads only), SINR and neighbours are missing; reading
     anyway broke the session ("Failed to parse message data", interface stuck
     pending). Under MM the channel is shared through qmi-proxy.
   - 05c6:90d5 (MV31-W / T99W175 in MBIM) -> `modemmanager` unless it is the
     Compal prototype sharing this id.
   - SimCom 1e0e:* on QMI -> `qmiraw` (no DHCP in 802.3: connected, RX=0).
   - Telit FN990 1bc7:1070/1077/1080 -> `qmiraw` (radio on before SIM checks).
   - Other QMI modems -> `qmiraw` only if the modem is natively raw-ip; stock qmi
     in raw-ip gets the address by DHCP, which is unreliable (Telit LM960:
     address, no traffic). The data format is asked with `uqmi -t 4000
     --wda-get-data-format` first and `qmicli -p` second, the latter only through
     `timeout` if that applet exists: busybox builds without `timeout` made the
     whole substitution empty and EC21 stayed on qmi although netifd printed
     "Device does not support 802.3 mode".

## Device fields by proto family

- `modemmanager`: `device` is the USB device sysfs path (walk up from the
  cdc-wdm node to the node with `idVendor`); PDP option is `iptype`; auth option
  is `allowedauth`. For `iptype=ipv4v6`, `init_epsbearer=default` is set unless a
  custom policy exists: without it the stock `modemmanager.sh` clears the
  initial EPS bearer, the modem attaches IPv4-only and the IPv6 half fails with
  `ip-version-mismatch` (Compal / SG500M2-X on MegaFon).
- `qmi`, `qmiraw`, `mbim`, `ncm`: `device` is the cdc-wdm node and `devpath` the
  stable sysfs path of the control interface (`ctrl_devpath`, e.g.
  `.../1-1.2/1-1.2:1.4`). `/dev/cdc-wdmN` numbers change on re-enumeration; with
  only `device`, qmi.sh resolved the neighbour's wwan, the DHCP child sat on it
  and released its lease (two 05c6:9025 on one router). The system protos
  resolve the node from `devpath` on every setup.
- serial protos: AT port, `auth=none`; further options are left to
  Network > Interfaces.
- No device found: the reason is logged; if the USB path is no longer present,
  the log says so (a crashed module flashing a recovery composition for a
  second).

## Preserved across recreation

APN, `pdptype`, `allow_roaming` (roaming data silently stopped working after a
SIM switch), `metric` (set by Internet priority; new interfaces get
`_def_metric`, one step below the priority base, so they never take the default
route; qmi/mbim/MM used to get metric 0 and beat everything), `dns` (the
"Fallback DNS" toggle, `setopt dnsfb`, stored directly in
`network.<if>.dns`), `force_connection`, `init_epsbearer`, PAP/CHAP auth
(MVNOs such as Ekomobile).

Default PDP type for new interfaces is IPv4: on IPv4V6 many modems register but
the context gets no address (EC21 verified), IPv4 gets an IP immediately. The
earlier IPv4V6 default came from one operator-specific case (Tele2 / FM350).

## Firewall zone (`_fw_zone_add`)

The `wan` zone network list has two legal forms: `list network 'wan'` /
`list network 'wan6'`, or `option network 'wan wan6'`. `uci add_list` on the
option form treats the string as one element, so the zone contained a
non-existent network "wan wan6" plus the modem: real wan left the zone, NAT was
gone, the router itself still had internet but LAN did not. `uci get` returns
both forms the same way, so the form is detected from `uci show` (list elements
are individually quoted). Quotes are stripped before splitting, which also
splits a previously glued element back. A clean zone is not rebuilt: delete +
rebuild leaves a "zone without networks" window in the shared `/tmp/.uci`
staging that another process's commit can publish. A dirty list (duplicates,
glued element) is rebuilt completely, deduplicating every network, not only the
added one (a test router had `modem` 24 times).

## Kernel proto preparation (`kernel_proto_prepare`)

Observed on EC21: MM and uqmi both claimed the cdc-wdm, the QMI stack wedged,
uqmi hung forever ignoring its own `-t` and held the node, every next request
returned "Request timed out" / "No data link!", netifd looped. AT still answered
(`CPIN: READY`); only QMI was dead, and `AT+CFUN=1,1` revived it. Before `ifup`
on a kernel proto (in the background, it may take ~2 min):

1. Synchronous `mm-inhibit` pass for this modem. A ModemManager restart was used
   here before and dropped the connections of all other MM modems (SIGTERM ->
   bearer finished).
2. Kill hung `uqmi` processes on this node.
3. qmi only: `qmi_alive` asks `uqmi -t 3000 --uim-get-sim-state` (the same tool
   netifd uses; its own timeout ends the request and releases the client ID, so
   `run_bounded` never has to kill it). Without uqmi it falls back to `qmicli
   --uim-get-card-status`. `--get-pin-status` returns "Not supported" on a
   healthy EC21, so it is not a health signal. If dead, reset via `AT+CFUN=1,1`
   on the modem's AT port (`at_query`, which also takes the port queue) and wait
   for re-enumeration and QMI. Why not `qmicli`: a directly connected QMI client
   killed with -9 leaks its client ID, and a full pool (`ClientIdsExhausted`)
   stops MM from initialising the modem; with `-p` a qmi-proxy would keep
   holding the channel that uqmi from netifd needs next.

`run_bounded` keeps its own loop counter: sharing `_n` with the calling loop
made `kernel_proto_prepare` spin forever.

## ModemManager handling

- `apply_mm_state` (`msw/iface.sh`): MM must run if any interface uses
  `modemmanager`. Autostart follows the config; start/stop of the daemon goes
  through `mmneed.sh`, which also looks at the bus, so an interface of an absent
  modem no longer keeps MM running (it used to start MM and `mmneed` stopped it
  on the next step, on every hotplug). Creating an mbim/qmi/atc interface used
  to disable MM blindly and take other MM modems down.
- `mkiface` does not restart a running MM (it dropped a neighbouring Compal when
  a SIM7100E was plugged). The one exception: MM is running, sees no modem at all
  and this interface needs it (missed udev events with libudev-zero), so there is
  nobody to disconnect.
- `mm_restart_safe`: never `/etc/init.d/modemmanager restart`. procd starts the
  new process before the old one releases `org.freedesktop.ModemManager1` on
  D-Bus; the new one fails "could not acquire the service name" and MM is gone
  for 1-2 min. Stop, wait for the process to exit, start.
- `mm_exclude` per modem: 1 for kernel protos (MM grabs the control channel and
  the interface gets no IP), 0 for `modemmanager`; the form's explicit value
  wins for kernel protos. Switching to `modemmanager` also kills the running
  `mmcli --inhibit-device` holder (the modem blinked in and out of MM), then
  `mm-inhibit.sh once` applies immediately instead of waiting for the 15 s pass.
- For `modemmanager`, `ifup` waits until MM actually sees the modem; right after
  an MM (re)start the proto finds nothing, netifd logs "Device not managed by
  ModemManager", downs the interface and does not retry.
- For xmm/atc, `ifup` waits for `CEREG/CGREG` 1 or 5 (up to 90 s, nudging
  `AT+COPS=0` if deregistered): dialing an unregistered modem "succeeds" without
  an address, then netifd loops and the next attempt cannot open the port ("AT
  port not answer!"); seen on L860-GL-16.
- All long waits run in a background subshell with fds detached: `mkiface` is
  called through rpcd (`fs.exec`), which waits for EOF and fails with an XHR
  error after 30 s.

## netifd reload after recreate

The interface section is deleted, rewritten and committed, but netifd's
in-memory copy is the old one; `ifup` alone acts on it. On a DW5821e netifd kept
an old `proto none` interface and answered every ifup with "Cannot set device
name: /sys/... longer than max size 15". Hence `ubus call network reload` right
after the commit (it brings up autostart interfaces; the later ifup is harmless).

Unknown protocol handlers: netifd scans handlers only at start. A freshly
created interface on our shell protos (`fibocom`, `qmiraw`, judged by `$PROTO`)
or on a standard proto whose package was installed after boot is "Unsupported
protocol type" until the network restarts. `mkiface` forces the registration
there, because the user is configuring the modem right now; the package postinst
deliberately does not (it once took a remote router offline).

## SMS routing and WMS routes

`modemmanager` -> `sms_via_mm=1`; any other proto -> AT path. WMS route
redirection to the SIM is applied only to Compal (`is_compal`): its factory
default stores incoming SMS in NV where nothing can read them. Applied to every
qmi/mbim modem it moved healthy modems' inbox to a 20-30 message SIM store that
stops delivery when full. The same gate exists in the
`70-5gmodem-sms-modems` USB hotplug.

The fibocom branch leaves MM running (another modem may need it) but sets
`mm_exclude` and runs inhibition, since udev rules do not work on OpenWrt.

`foreign_iface` is cleared as soon as an interface is created for this modem,
and sections are created complete (path, vidpid, product) so a profile recreated
after `delprofile` is not nameless.

## Keeping interfaces healthy (`msw/iface.sh`)

- `ensure_iface`: all variables are `local`. It is called in a loop over every
  present modem, and globals `SEC/P/IF` once leaked so that
  `@5gmodem[0].network` was set to the last modem's interface. Skips interfaces
  owned by other hardware. If the section points at another modem's interface
  (bad IMEI migration on a four-modem router), only the link in our section is
  fixed: our stamped interface is looked up, otherwise the field is cleared for
  `mkiface`. Missing `modem_imei` stamps are backfilled.
  - atc and xmm dial over the AT port, never over cdc-wdm. xmm used to share the
    mbim/qmi line and got `/dev/cdc-wdm0` on modems that have one (L850 in
    2cb7:0007), breaking a working interface on every modem return or switch.
  - A live dial port is not re-pinned while it exists, belongs to this modem and
    differs from the metrics port. The choice depended on the current metrics
    port, which changes with the active modem, so events on another device (a
    phone changing composition) flipped FM350's dial port and caused
    commit + reload of a working modem. For xmm, liveness is decided by gcom
    (ttyACM2 on L850 exists but is unusable).
  - Two-pass port choice (model, then any `AT`) as in `detect.sh`.
  - For wdm protos, `devpath` is set/refreshed.
  - `pending` interfaces are left alone unless the device changed: a second ifup
    over a running dial restarts it (netifd dials at boot, resolve arrives later).
- `follow_iface_device`: an adopted interface follows its modem to a new port or
  controller (2-1 -> 1-1). modemmanager.sh finds the modem by `device` (USB sysfs
  path) and qmi/mbim by `devpath`; with the old absolute path netifd logged
  "couldn't find modem" every 90 s (VOS 5G / SG500M2-X). Rewritten only when the
  new value is alive and belongs to this path; atc/xmm/fibocom are handled by
  `ensure_iface`.
- `fix_iface_proto`: align a kernel proto with the cdc-wdm driver. A Compal
  (`cdc_mbim`) adopted a Telit's `proto=qmi`: uqmi hung on MBIM for minutes. Only
  impossible pairs are fixed; other protos are user choices. The poisoned
  `iface_proto` is removed from the section so auto-detection decides. Specials:
  `qmi` + `qmi_wwan` is "healthy" by driver but dead for Compal RXM-G1 (uqmi
  cannot open services, `mm_exclude=1` hides it from MM), so it is rebuilt under
  the same name; vendor 05c6 is only the cheap gate, the decision is by model
  (05c6:9091 is shared with Android sticks). DW5821e/T77W968 (413c:81d7, 81e0,
  0489:e0b5) and MV31-W 05c6:90d5 are rebuilt as `modemmanager` via `mkiface`
  with `MKIFACE_AUTOFALLBACK=1` (different device, `iptype`, `allowedauth`,
  `mm_exclude` and MM autostart), because umbim either fails or gives an address
  without traffic there.
- `orphan_iface_for`: an interface on this modem's device not created for it and
  claimed by no section. This is a swap `swap_cleanup` misses (modem moved from
  1-1.3.3 to 1-1.3 is a "new modem", while the old interface sits on the same
  `/dev/cdc-wdm0` and dials with the previous operator's APN). Only marked
  (`foreign_iface`), never edited. IPv6 twins (`wwan` + `wwan6` on one device,
  seen on Cudy LT300) are not orphans.
- `iface_for_path`: find an existing interface by actual device (netdev, control
  node, or `l3_device` when no device is configured) so a vendor- or
  user-created interface (`wwan` on usb0 on LT300) is adopted instead of a second
  one fighting for the default route.
- `drop_stale_ifaces`: deletes our own older interfaces of this modem (path
  stamp matches, not the current one), never unstamped ones and never those
  pinned to another IMEI (displaced modems' interfaces wait for them).

## qmiraw

Fork of the stock `qmi.sh` for modems whose 802.3/DHCP path yields an address
without traffic (SimCom SIM7100E, Telit LM960, natively raw-ip QMI modems):
`--set-data-format raw-ip` and `--wda-set-data-format raw-ip`, static addressing
from `--get-current-settings`. Differences from upstream:

- Radio on before SIM checks. A modem can enumerate with the radio off
  (`AT+CFUN=0`); UIM then reports `illegal` for a good card and the illegal
  branch power-cycles it in a loop (Telit FN990A28: "SIM in illegal state -
  Power-cycling SIM", fixed manually by `AT+CFUN=1`). Upstream sets online only
  after the SIM checks, which is too late. `--get-device-operating-mode`, and if
  not `online` (empty "not supported" included) set it online.
- Wait up to 30 s for `pin1_status` other than `not_initialized`, or for
  "Not supported"/"Invalid QMI command" from both PIN and UIM queries.
- Empty `card_application_state` is not `illegal`: the UIM is just not ready
  early in the dial. Upstream power-cycled it, causing the same loop (also
  tracked upstream in openwrt/openwrt#24868 on ZTE MF287 and BroadMobi BM806C).
  Three cases: no answer -> wait within the timeout, then `SIM_NOT_INITIALIZED`
  without power-cycling; explicit `illegal` -> power-cycle as before; anything
  else -> ready. The existing error name is reused to avoid new translations.
- `--network-register` only if not already registered or searching.
- On IPv6 failure the already started IPv4 handle is stopped.
- `peerdns=0` is honoured for both families.
- Teardown skips missing paths and stops at the first match.
- Upstream notes kept in spirit: the first `--get-pin-status` uses `-t 3000`
  because uqmi can hang; PLMN selection must happen after `--network-register`;
  a network scan after a RAT change avoids relying on the registration timeout;
  `pdh` must be numeric on success; RFC 7278 `extendprefix` is set for IPv6.

The device lookup accepts `usbmisc` paths (`.../1-2:1.4/usbmisc/cdc-wdm0`, where
`1.4` is configuration and interface; checking `/*/usbmisc` also lets the user
give the USB port) and `wwan` paths (`.../wwan/wwan0/wwan0qmi0`, also under
`mhi0`).

## LuCI protocol pages

`protocol/fibocom.js` and `protocol/qmiraw.js` register the shell protos with
LuCI; without them Network > Interfaces shows the interface as "unsupported"
and it flickers out of the list. `fibocom.js` declares `usbpath`, `device`,
`atport` and `metric` in the advanced tab because they are managed by
`mkiface.sh`: undeclared options would be dropped when the interface is saved
from LuCI. It also registers the proto's error codes (`NO_NETDEV`,
`NETDEV_MISSING`, `NOT_REGISTERED`, `REGISTRATION_DENIED`, ...).

## Hotplug hooks

- `hotplug.d/net/30-5gmodem-netdev`: re-raise a `fibocom` interface when its
  netdev appears. FM350-class modems register eth2 ~20 s after netifd starts;
  the early setup returns `NETDEV_MISSING` with `proto_block_restart`, and with
  `no_device=1` netifd neither tracks the device nor lets `ubus ... up` clear the
  block, so only `ifup` (after `proto_set_available 1`) helps. In net hotplug
  `$INTERFACE` is the netdev name, not the uci interface. Matching is by
  `device`, by netdevs under `usbpath`/`modem_path`, or by `l3_device`. A modem
  that rebooted itself (FM350/RW350 leave the bus through the MT65xx preloader
  and return after ~20 s) removes eth2 while netifd still thinks the interface
  is up; a `netdev-gone` marker set on `remove` makes the next `add` reconnect
  (otherwise only the health watchdog recovered it, after a minute). Saved bands
  are applied by `fibocom.sh` itself before dialing; a separate hook lost the
  race against netifd's own restart. Apple devices (vendor 05ac, or an
  interface with `modem_tether='iphone'` on remove) re-trigger
  `71-5gmodem-resolve`.
- `hotplug.d/iface/30-5gmodem-ttl`: TTL rules are an nft include bound to the
  modem's l3 device. Late netdevs (FM350 RNDIS/xmm) appear after the firewall's
  first load, so on cold boot the rule missed the interface (third-party TTL
  tools hooking `iptables -o eth2` before eth2 existed broke the path). On
  `ifup` of `@5gmodem[0].network`, if any TTL value is set, `ttl.sh apply`
  rebuilds the include and reloads fw4.
- `hotplug.d/iface/31-5gmodem-bands`: some modems reset the band mask at every
  reboot (FM350: the `GTACT` RAT survives, bands do not). On `ifup`, unless
  `save_bands=0`, `bands.sh restorebands` runs for the modem whose section has
  `network=$INTERFACE`, targeted with `BANDS_ACTIVE_MODEM`. It only touches the
  modem when saved and current differ, so NV-keeping modems get no extra CFUN.
  One attempt per interface per boot (marker in `/tmp` holding the USB `devnum`;
  a new devnum means the modem re-enumerated and allows another attempt),
  avoiding a restore -> CFUN -> reconnect -> ifup loop.
- `hotplug.d/iface/60-5gmodem-health`: an extra health round on uplink up/down
  (`health.sh event`), otherwise the verdict waited for the 30 s sessionwatch
  cycle and a modem that came up looked missing for a minute.
- `hotplug.d/iface/70-5gmodem-svcrestart`: tunnels and bypass tools (passwall2,
  ssclash, nikki, podkop, zapret, ...) start at `START=99`, check connectivity
  once and start "into the void" because the modem dials tens of seconds later;
  their own health loops can take 10 min. On `ifup` of any uplink (wan zone plus
  `extra_uplink_nets`, the same set as Internet priority) the services flagged
  `restart_on_uplink` in their `svcwidget` are restarted once traffic flows.
  Service names are validated before being used in `/etc/init.d/<name>`. The
  probe pings 77.88.8.8 and 1.1.1.1 (each is blocked in some regions) first with
  `-I <dev>`, then via the normal route: `-I` only sets the source and a modem
  that is not the primary uplink never passed a device-bound probe (the first
  version never restarted anything). Waits up to 90 s. A 120 s per-service quiet
  window is measured on `/proc/uptime`, not wall time: routers without RTC jump
  years forward when NTP syncs, which disabled the window, and a clock going
  back blocked restarts forever. The first uplink of a boot is never suppressed.
- All hooks run their work in a background subshell with fds detached, so
  hotplug does not wait for dialing, CFUN cycles, fw4 reloads or restarts.
