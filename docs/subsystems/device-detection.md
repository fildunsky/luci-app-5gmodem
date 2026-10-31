# Device detection, port binding and modem identity

This subsystem finds cellular modems on the USB and PCI/MHI buses, decides what
is and is not a modem, binds usb-serial drivers to compositions the kernel does
not know, repairs broken USB configurations, and keeps a stable identity for
every modem (USB path, IMEI, sysfs serial, netdev MAC) so that per-modem config
sections, interfaces and caches follow the hardware. The shared helper library
`root/usr/share/5gmodem/lib.sh` also hosts many cross-subsystem helpers (AT/QMI
access gates, uci snapshots, SMS storage, routes); their rationale is collected
at the end of this document.

Files: `lib.sh`, `listmodems.sh`, `notmodem.sh`, `usbports.sh`,
`usbmode-fix.sh` (all in `root/usr/share/5gmodem/`), hotplug handlers in
`root/etc/hotplug.d/{usb,usbmisc,tty}/`, init scripts in `root/etc/init.d/`.

## Shared helpers: one implementation each

`lib.sh` is sourced, never executed. It exists because two operations had been
copy-pasted and had diverged: the section name from a USB path (22 copies in 12
files) and the section lookup by interface name (nine regex variants:
`m_[^.]*` vs `m_[A-Za-z0-9_]*`, optional vs mandatory quotes, with or without
`head -1`). Strict variants silently missed sections that lenient ones found.

- `secname`: uci section names allow only `[A-Za-z0-9_]`, USB paths contain
  `.` and `-`. Pure shell substitution (no `sed` spawn, ~4 ms saved per call)
  plus a one-entry memo, because one metrics poll asks for the same path ~10
  times.
- `sec_for_iface`: quotes around the value are optional; uci versions differ in
  `uci show` output and the strict regex silently failed.
- `snap_key`: formula copied byte-for-byte from `5gmodem.sh`, including
  `printf '%s\n'`, so the newline also goes through `tr` and produces a
  trailing underscore: `5gmodem_metrics_1_1_3_.json`. Do not change it, the
  existing snapshot files are named that way (a "logical" key once made the
  cache warm-up look for a file that never existed).
- `uptime_s`: `read` from `/proc/uptime` instead of `cut`; that was 21 spawns
  per metrics poll.

## Modem identity

A modem is identified primarily by its USB topology path (stable across
reboots, unique even for identical VID:PID). Path alone cannot tell two
different modems in the same socket apart, so IMEI, sysfs serial and netdev MAC
are layered on top.

### Sysfs serial (`serial_valid`, `serial_of`, `stub_serial_*`)

IMEI needs an AT read; until it is read, two identical modems are
indistinguishable (two Thales MV31-W 05c6:90d5 once showed the same number in
both profiles). The USB serial is available immediately from sysfs, but cannot
be a key. Measured values:

| VID:PID | serial | verdict |
|---|---|---|
| 05c6:90d5 | d383e5d6 / 1afc7c2d | two MV31-W distinguishable |
| 05c6:9025 | c7f2a76c / 72f642f6 | two T99W175 distinguishable |
| 05c6:90d6 | 2e6172c9 | same for the whole batch (three different IMEIs) |
| 05c6:9063 | 81e6896d | unique |
| 0489:e0b5 | 0123456789ABCDEF | batch stub |
| 413c:81d7 | 0123456789ABCDEF | batch stub |
| 0e8d:7127 | empty | FM350 has none |

A stub is worse than no serial: it would merge two modems into one. Hence the
filter: known stubs, too short, one repeated character (`000000`,
`FFFFFFFF`), and a runtime check: if two devices on the bus report the same
serial right now, it is a batch serial.

Batch serials are remembered forever (`stub_serial_add`, stored in uci). Two
devices are rarely visible at the same moment (one plugged later, one
re-enumerating); on 2026-08-01 two Compal modules (VOS_5G and SG500M2-X) both
reported `2e6172c9`, the number got stamped while the neighbour was off the
bus, `sec_by_serial` treated them as one device and `migrate_profile` moved a
foreign profile with IMEI and interface. When a serial becomes known as a
stub, stamps already written to sections are wiped too.

### Interface ownership (`iface_owned_by`, `stamp_iface_owner`, `iface_hw_mac`)

`network.<if>.modem_path` could not distinguish two modems used alternately in
the same socket (issue #2: every swap recreated the interface). IMEI is the
primary ownership key; `modem_path` is still written for diagnostics and as a
fallback for old configs and modems without readable IMEI.

- IMEI stamp present and our IMEI known: IMEI decides. Mismatch, or our IMEI
  unknown, means foreign: the interface may belong to a modem pushed out of
  this socket that will come back.
- Some sticks change IMEI on every reconnect (Huawei E3372 with an IMEI
  randomizer, 2026-08-24: `modem`, `modem2`, `modem3`, `modem4` accumulated on
  one `eth2` in zone wan). Second anchor: the netdev MAC (`modem_mac`). Same MAC
  with a new IMEI means same hardware, the IMEI stamp is updated.
- Empty or all-zero MAC is never an anchor: raw-ip netdevs (qmi_wwan, checked
  on EP06-E) have no address, a ZTE stick reports `00:00:00:00:00:00`. Any two
  such modems would look identical.
- IMEI match is not always unique: two refurbished MV31-W with a cloned IMEI.
  If the path stamp points to another device that is on the bus now, the path
  decides.
- No stamp at all: interface from an old version, treated as ours (migration
  stamps it).

### Custom name (`alias_for_path`)

The alias lives in the slot section (`alias` + `alias_imei`) but belongs to the
hardware: first search all sections for an alias bound to the current IMEI (the
name follows a modem moved to another socket); fall back to the slot alias only
if it is not bound to a different IMEI (2026-08-08: an EP06-E in the former
SIM7100E socket kept being called SIM7100E). Unbound aliases stay with the
slot, deliberately, for batches with identical or unreadable IMEIs.
`listmodems.sh` applies the same rule and ignores IMEI binding entirely when
two present modems share an IMEI.

### Path-keyed caches outlive the modem (`purge_path_caches`)

Almost everything is cached by USB path (metrics snapshot, AT statics, SIM
slots, bands, QMI extras), and the socket stays the same when the modem is
replaced. 2026-08-01: a SIM7100E in a former eSIM modem socket showed two SIMs
and an eSIM from `/tmp/5gmodem/slots_1-1.3`. Everything for the path is purged
on modem swap (`swap_cleanup`) and on composition change. Two key formats are
live and both must be purged: `snap_key` gives `1_1_3_`, the statics cache key
from `tty_usbpath` gives `1_1_3` (`5gmodem_static_1_1_3.imsi` is not matched by
the first glob).

### Device still on the bus (`usb_path_present`)

The modem list is a snapshot; some devices live on the bus for one second. A
module recovering from a firmware crash comes up in an emergency composition
(Rolling RW350-GL: `cdc_acm ttyACM0` on another bus number) and immediately
reboots. On 2026-09-03 such a ghost got profile `m_1_1` and a `mkiface` call
("no control device ... modem path='1-1'"). Before creating anything new for a
path, re-check the bus (one `stat`). PCI/MHI modules are listed under their PCI
path, for which a USB check always failed and autosetup skipped them.

### `tty_usbpath`

Empty input returns failure immediately. Without that, `basename ""` collapsed
the path to `/sys/class/tty/` and the parser returned the literal `tty`: the
IMEI stamp gate compared `tty` with the modem path and never stamped, and the
statics cache key became `tty` for every modem without an AT port, mixing data
of different modems in one file.

## Listing modems (`listmodems.sh`)

Output: JSON array, one entry per USB device that owns serial/control ports:
`{path, vidpid, product, tty[], wdm[], net[], model, operator, alias, ...}`.

### Performance

Called 6 times per page load (4 from `netpri.sh`, plus modemtabs, simslot,
bands, modemswitch); at 0.19 s per call it was 48% of the page backend
(measured on WH3000 via `/proc/uptime`; busybox `date` does not support `%N`
and silently prints zeros). Fixes:

- output cache in `/tmp`, invalidated by the USB hotplug hook
  (`71-5gmodem-resolve` and `--refresh`), plus an 8 s TTL safety net;
- one pass over the ports instead of O(n^2) (`owner_node` used to be called
  again per port inside the per-modem loop, ~100 `readlink` for 11 ports);
- no `eval`-based pseudo arrays (banned as a class by the audit): a flat list of
  `index type path` records read back with a `read` loop;
- `esc` runs `sed` only when there is something to escape;
- IMEI->alias map and present-IMEI list built once per run;
- cache written atomically through a per-process tmp file (a shared
  `$CACHE.tmp` with parallel writers produced interleaved JSON).

### Not every device with ports is a modem

Only the first port of a device is checked with `usb_is_modem`; rejected nodes
are remembered so a CH341 (two ports) or FT2232 (four) is not re-read per port.

### PCI/MHI modems

M.2 modules with USB cut (Quectel RM520N-GLAP 17cb:0308, Foxconn
T99W175/DW5930e 105b:e0b0, Foxconn T99W373/MV32-W 105b:e0d9) appear as PCI
devices under `mhi-pci-generic` with class `wwan` ports: `/dev/wwan<N>at<M>`
(AT) and `/dev/wwan<N>mbim<M>` (data). `owner_node` climbs to a node with
`idVendor`, which PCI parents lack, so these modems were missing entirely (no
tab, no vidpid, bands page "Unsupported"). The PCI walk stops if it meets a USB
node on the way: a USB cdc_mbim modem also has a wwan port, and a blind climb
would end at the xHCI controller. The `wwan0` node itself has no `/dev` entry
and is skipped. The AT port is listed under `tty`, other channels under the
control list. VID:PID comes from `vendor`/`device` with the `0x` prefix
stripped, formatted like USB (`17cb:0308`) because `bands.sh` looks up
`modemband/17cb0308`. PCI nodes have no `product`; the name comes from the
VID:PID until AT+CGMM fills the section.

### Port-less modems (HiLink)

Devices that run their own IP stack and look like a plain NIC (cdc_ether/NCM),
e.g. Huawei E3372h after mode switch (three interfaces, no serial). Only for
known cellular vendors (12d1 Huawei, 19d2 ZTE, 1bbb Alcatel, 2001 D-Link, 0421
Nokia, 1546 u-blox, 2020 Olicard, 05c6 Qualcomm) and only without tty/wdm.
05c6 was added for Compal RXM-G1 factory firmware (05c6:9063), which exposes
only `cdc_ether -> usb0`. "No ports" alone is not HiLink: a stick whose VID:PID
is not yet in `new_id` looks the same. The descriptor tells them apart: sticks
have class `ff` interfaces, HiLink has only `02`/`0a` (CDC Ethernet) and `08`
(leftover storage). Checked: E3372h `02,0a,08`; FM350 `02,0a,ff,ff`. `net[]` in
the output lets the UI tell HiLink apart and hide AT features.

### USB tethering phones

Detected by RNDIS (`ef/04/01`, older firmware `e0/01/03`), not by "network
without ports", which also matches ordinary USB Ethernet adapters. Previously a
phone only showed up if a section already existed; a fresh phone in a socket
previously used by another vendor's modem left `active_modem` pointing nowhere
and the poller calling resolve forever (2026-09-16, Xiaomi 17 in the socket of a
Quectel EC21). ECM/NCM tethering is deliberately not detected: indistinguishable
from an adapter, and a false positive costs more than a miss.

Phones that lost their ACM port after a composition change (2026-08-03, Samsung
S21) are still shown when our own section exists for the path and the vendor
matches (not the full VID:PID: 04e8:6860/6862/6864 is the same phone). A
different vendor in the socket is a device swap, handled by `identity.sh`.

### Model shown in the list

Order of trust:

1. `model` from the section (AT+CGMM, written by the poller). USB `product` is
   often useless ("Android" on Quectel EC21, "SimTech, Incorporated" on SIMCom).
   AT is never sent from `listmodems.sh`.
2. Cleaned with `at_strip_ok` ("Quectel OK RM520N-GL OK").
3. Rejected if it names another vendor than the section VID (`_model_vendor_ok`;
   "Compal RXM-G1" stuck in the FM350 section after a swap made FM350 a second
   "Compal").
4. Rejected if `model_vp` (VID:PID the name was read from, written by resolve,
   the poller and hilink) differs from the hardware. Needed for vendors unknown
   to `_vendor_by_vid` (2026-08-03: a Samsung phone in a SIM7100E socket showed
   as "SIMCOM SIM7100E"). Empty stamp is not judged (pre-stamp sections).
5. Fallback to `product`, normalised by `model_alias`: Compal `VOS_5G`/`RXMG1`
   become "Compal RXM-G1" directly (unique for Compal, T99W175 on 90d5/1e2d:00b7
   has a different string); long Dell strings lose the chipset tail
   ("DW5821e-eSIM Snapdragon X20 LTE"); the generic SDX55 string "Generic Mobile
   Broadband Adapter" (T99W175, DW5930e, MV31-W, Compal prototype) becomes a
   short family name until CGMM is read.

Operator for the tab icon: first `/tmp/5gmodem/op_<iface>` from the main poller
(it decodes UCS2, uses mccmnc.dat and replaces the host network with the MVNO
brand), then `/tmp/5gmodem/netpri_op_<iface>`. The hilink branch of `5gmodem.sh` writes
`op_<iface>` from the web API `operator_name` too, so HiLink modems get the tab icon from
the first poll; netpri's own web-API probe never falls back to the model name. Reversing the order would show
"Tele2 RU" where the card says "T-Mobile".

## Model name helpers (`lib.sh`)

### `_model_sane`

The AT port is shared by the poller, `simslot.sh` and `esim.sh`; on a collision
one command's answer lands in another's read, and a saved collision becomes
permanent. Seen as model names: echo `AT+SIMTYPE?` ("SimCom AT+SIMTYPE?"),
space-form echo from L850 with ATE1 (`AT  4`, `AT+GTDUALSIM?`), foreign answers
(`Telit #BND: 0,18,A7E0BB0F38DF,42`, `Telit +CSQ: 23,4`), and garbage from a
Samsung phone PACM port (`~x~AT`, 2026-08-03). Accepted: no command echo, no
`?`/`=`/`"`, no `#xxx:`/`+xxx:` answer form, only letters, digits, space and
`. _ + / ( ) -`, at least one letter.

### `_vendor_by_vid`, `_model_vendor_ok`

A plausible but foreign name: a Huawei (12d1) section got "Fibocom FM350-GL"
read via another modem's port. Judged only when the VID has an unambiguous
vendor and the string names a different known vendor. 05c6 is never judged
(many vendors). Bare models ("RM520N-GL", "E3372") are never judged.

- `1e2d:00b7` returns no vendor on purpose: it is not Cinterion but the
  debug/QMI composition of Qualcomm SDX55 (Foxconn T99W175, Compal RXM-G1,
  Dell DW5930e, Thales MV31-W) borrowing the Cinterion VID. Returning
  "cinterion" would reject our "Compal RXM-G1" name and leave raw SG500M2-X.
- Thales is a synonym of Cinterion (ex-Gemalto): MV31-W answers "Thales
  MV31-W"; without the synonym the model was rejected on every poll and never
  reached the section (2026-08-06, MV31-W under umbim).
- compal/foxconn/thales/dell are our synthesised friendly names (profile
  `modem/usb/05c690d6`: `MODEL="Compal RXM-G1"`); under 05c6 they survive, but
  leaked into another vendor's section they are rejected.

### `model_alias`, `model_refine`, `at_strip_ok`, `digits_of`

- `model_alias` strips the AT terminator first, since every reader and writer of
  the name goes through it. SIMCom reports `SIMCOM_SIM7100E` or
  `SIMCOM SIM7100E`; normalised to "SIMCom SIM7100E" (official spelling). Dell
  names are trimmed to model + eSIM flag. One model can appear as `VOS_5G`
  (USB), `SG500M2-X` (MM hardware revision) and `RXMG1...` (firmware): all are
  Compal RXM-G1; the rule used to live only in `listmodems.sh`, so a model
  written from mmcli stayed raw ("VOS_5G" for 05c6:9063).
- `model_refine` appends the variant suffix from the USB descriptor only when
  the descriptor continues the last word of the AT name with `-`/`_` + letters
  and digits: "Quectel EP06" + `EP06-E`, `SIM7600E` + `SIM7600E-H`. Anything
  else (chipset, generic string) is left alone.
- `at_strip_ok`: some firmware returns the whole answer as one line with CR
  separators (`AT+CGMI\rQuectel\rOK\r`), so the per-line strip in the sms_tool
  wrapper misses `OK` and `xargs` glues it into the value ("Quectel OK
  RM520N-GL OK", firmware "RM520NGLAAR01A06M4G OK", 2026-09-06). Removed as a
  separate word anywhere; `strip_ok_var` runs `sed` only when the value contains
  `OK`.
- `digits_of`: profiles cut `cut -c 8-` (IMEI) / `cut -c 9-` (IMSI) assuming a
  command echo; EP06 answers without echo and the cut ate the start of the
  number ("97818657" instead of the IMEI). Take the first digit run of the
  expected length instead; `AT+GSN` contains no long numbers.

## Not-a-modem detection (`notmodem.sh`)

Any USB-UART bridge creates a `ttyUSB` and used to get a tab, AT probing and a
place in the internet priority list (2026-09-01: WCH CH340 1a86:7523).

Built-in bridge list (pure converters, never cellular):
`1a86:7522 1a86:7523` CH340/CH341, `1a86:55d3` CH9102/CH343 (WCH);
`0403:6001 6010 6011 6014 6015` FTDI; `10c4:ea60 ea70 ea71` CP210x;
`067b:2303 23a3 23c3` PL2303.

Two uci knobs in `5gmodem.@5gmodem[0]`, space-separated VID:PID lists:
`ignore_vidpid` (hide a device) and `modem_vidpid` (force a device back into
modems, e.g. a dev board whose cellular module is reachable only through such a
bridge). Both are read once per process (`_nm_cfg`), because `is_not_modem`
runs per device and `listmodems.sh` six times per page load.
`is_not_modem_builtin` (no knobs) tells the settings page which knob a checkbox
must write.

### `usb_is_modem`: decide by device properties

A blacklist only treats symptoms. The device is a modem if any of:

1. interface driver is option/qcserial/sierra/usb_wwan or
   qmi_wwan/cdc_mbim/cdc_ncm/cdc_ether/rndis_host (bridges use
   ch341/ftdi_sio/cp210x/pl2303);
2. interface class MBIM `02:0e`, CDC ECM `02:06`, NCM `02:0d`;
3. cellular vendor (needed for a raw modem without a bound driver). 05c6 and
   0e8d are broad but cover half of supported modems. Not listed: Dell 413c, HP
   03f0, Intel 8087, Foxconn 0489, TP-Link 2357 (keyboards, printers, BT, Wi-Fi
   share them); their modems are caught by 1-2 (DW5821e and L850 MBIM, HP
   lt4120 qmi_wwan);
4. our section for the device has IMEI or model (it already answered as a
   modem; protects an unknown working modem). Checked last so the settings page
   shows the real reason when there is one.

Manual answer (`modem_vidpid`/`ignore_vidpid`) beats everything. The reason is
returned as a short code (`vendor|driver|mbim|ecm|ncm|profile|forced|bridge|
ignored|none|absent`) plus detail; the page builds the sentence (three UI
languages, script output cannot be translated).

Interfaces are searched among the children of the node (`$node/*:*`), not
siblings: in `/sys/bus/usb/devices` device and interfaces are flat siblings,
but `listmodems.sh` passes a `readlink -f` path in `/sys/devices` where
interfaces are children. The sibling pattern found nothing there; a Dell
DW5821e 413c:81d7 worked but the modem list was empty and the Network page
re-rendered forever (2026-09-04).

### `nm_scan` (settings page)

Separate command, not a `listmodems.sh` mode (that script is hot). Lists
devices with ports plus whatever `listmodems.sh` already treats as a modem,
with `skip`, `builtin`, `known` (profile `modem/usb/<vidpid>` exists), `auto`
(would be a modem without knobs), `why`, `detail`, `absent` (config entry
without hardware, shown so the checkbox is not lost on save). Ports of
usb-serial live one level deeper (`<iface>/ttyUSB0/tty/ttyUSB0`) than cdc_acm
and cdc-wdm (`<iface>/tty/ttyACM0`). Knobs must be read before `_ns_auto`
temporarily clears them; otherwise `_nm_cfg` ran inside the clearing and
restored emptiness for the rest of the scan. `setblack` writes and commits both
knobs immediately instead of going through LuCI's staged apply, so the tab
disappears together with the checkbox; it also drops the modem list caches.

## USB port binding (`usbports.sh`)

The only place where a USB composition is mapped to a usb-serial driver.
Earlier `20-compal-t99w175` bound 05c6:90d6 to option1 and
`70-5gmodem-sms-modems` to generic; both ran, `new_id` of both drivers held
`05c6 90d6`, generic won and all three ports (ttyUSB7/8/9) returned I/O errors.
The script chooses the driver; whether to touch the device at all stays with
the handlers (90d5 is shared by Foxconn T99W175 and the Compal prototype,
distinguished by descriptor).

### Driver table (`driver_for`, `newid_for`, `data_iface_for`)

- option1: 05c6:9025 (T99W175 in QMI mode, exposes no ports by itself and has a
  different port layout than 90d5); Android sticks MDM9600/9610 in modem-only
  mode (05c6:9091); HP lt4120 / Foxconn T77W595 QMI composition (generic binds
  and four ttyUSB appear, but all answer "No response from modem" to ATI;
  with option AT lives on If#2, checked 2026-09-08).
- generic: everything else, including Compal RXM-G1 (90d5, 90d6) and T99W175
  on 90d5. Ports may be reduced but they exist.
- `new_id` accepts at most three fields (`vid pid class`). The five-field form
  with subclass/protocol is rejected (rc=1, checked 2026-08-18); the first
  version wrote `ff 00 00`, the error went to `/dev/null` and the user lost all
  ports while the log said "bound ... via option1". Write errors are now
  logged.
- Data channel interface numbers for compositions where it is also class `ff`:
  05c6:9025 If#4 (same as the kernel table in `drivers/net/usb/qmi_wwan.c`:
  `{QMI_QUIRK_SET_DTR(0x05c6, 0x9025, 4)}`), 05c6:9091 If#2 (rmnet), HP lt4120
  If#1. Issue #16 (BPI-R4 Lite, 2026-09-06): after a re-enumeration generic with
  the dynamic id took all five `ff` interfaces including the channel: five
  ttyUSB, no cdc-wdm, interface `NO_DEVICE`.

### Rescue of the data channel and ADB (`_rescue_rmnet`, `_release_adb`)

- usb-serial has no `remove_id`; a dynamic id lives in the driver until reboot.
  On a generic reprobe the greedy usb-serial is as good a candidate as the
  native driver, so the interface could go straight back. The channel
  interface is therefore bound by address to the native driver; only if that
  fails is `drivers_probe` used.
- The interface `driver` link points to the usb driver, which for `option.ko`
  is named `option`; `option1` is the usb_serial_driver name, visible only on
  the usb-serial bus. Without matching `option` the branch never fired and the
  channel and ADB stayed with option (VOS 5G / SG500M2-X, kernel of 25.12,
  2026-09-13).
- A three-field `new_id` (class `ff`) also grabs the ADB interface: on Cudy
  TR3000 it became ttyUSB2, AT probes fed adbd garbage and host adb was blocked.
  Only the exact triple `ff/42/01` is released (subclass 42 alone also matches
  fastboot `ff/42/03`), and nothing is reprobed (ADB has no kernel driver, adb
  uses usbfs). Unbinding loses the port until reboot, so no guessing.
- Rescue runs before the "ports already exist" early exit: after
  re-enumeration ports exist but the channel may belong to usb-serial; this is
  the only pass that repairs an already broken device.

### `bind_ports` rules

- Live data channel (cdc-wdm or netdev present): `usbserial_generic` is greedy
  and after a USB reset can win the channel interface (T99W175 05c6:9025:
  "generic converter now attached to ttyUSB4", cdc-wdm gone, `NO_DEVICE`).
  But refusing to bind left MBIM Compal 90d5/90d6 without any tty after each
  re-enumeration. So binding proceeds and is followed by surgery: every non-`ff`
  interface owned by usb-serial is unbound and handed back to its native
  driver via `drivers_probe`.
- Ports already present: do nothing. `new_id` may be written repeatedly, but
  not to different drivers. Users who bind ports themselves
  (`echo "05c6 9025" > .../generic/new_id` in rc.local) broke when we started
  adding the same id to option1 ("works on 1.5.0, not on newer").
- Preferred driver missing (lite images ship only `kmod-usb-serial`, not
  `kmod-usb-serial-option`): fall back to generic instead of exiting, otherwise
  someone else binds the ports and we get the two-`new_id` race again.
- Log once per device per boot (hotplug calls per interface and per tty).

### Coldplug (`usbports.sh coldplug`, `init.d/5gmodem-usbports`)

`new_id` does not survive reboot, and procd never delivers `add` for devices
present before boot (its netlink listener starts after early USB enumeration).
Compositions missing from the kernel table (05c6:9025 option1, 05c6:90d5/90d6
generic) had no ttyUSB after reboot, only IP via qmi_wwan. 1e2d ids are in the
static table, which is why only 05c6 was affected. The init script scans the
bus at boot, in the background with retries (the modem and the option driver
may appear seconds later). Before the first pass it runs `usbmode-fix.sh`
(usbmode has its own boot scan and sets config 0, but `71-5gmodem-resolve`
does not run at boot; HP lt4120 was left without interfaces after every reboot)
and `noatports.sh` (service ports that reboot the modem on AT).
`55-5gmodem-usbports` re-runs the same on USB add for 05c6/03f0 and a few
other ids, because on some boards the init script runs before
`usb-serial-option` is loaded (Compal 90d6 had no working ports).

Coldplug also calls the fastboot rescue for devices that were already stuck in
the bootloader at boot (DW5821e, 2026-09-17); the handler itself limits
candidates and attempts.

### USB configuration (`pick_config`)

The kernel picks the first configuration, which is not always usable; the value
does not survive reboot, so it is set at every boot, only for known pairs.

- Compal RXM-G1 factory firmware 05c6:9063 (`VOS_5G`): 1 CDC ECM (default), 2
  RNDIS, 3 CDC MBIM. In ECM the firmware re-enumerates every ~1.5 s (115 times
  in a row in one log). Writing `3` stops it (checked 2026-07-29).
  `20-compal-t99w175` handles 9063 the same way and stops there: no ports to
  bind, MM not needed.
- HP lt4120 / Foxconn T77W595 03f0:9d1d: 1 QMI + four serial ports (wanted), 2
  CDC ECM (default; DHCP internet but no control channel), 3 CDC MBIM. Forum
  advice is to force MBIM under ModemManager via `usb-mode.json`, but config 1
  is fully supported by uqmi and the AT profile `modem/usb/03f09d1d`.

## Harmful usb_modeswitch rules (`usbmode-fix.sh`)

`/etc/usb-mode.json` has entries like
`"413c:81d7": { "*": { "msg": [ ], "config": 0 } }`. Config 0 means
"unconfigured": the kernel unbinds drivers (`cdc_mbim wwan0: unregister`) while
usbmode holds an interface through usbfs ("interface 1 claimed by usbfs while
'usbmode' sets config #0"), so cdc_mbim cannot rebind. usbmode runs on every
hotplug event, so the breakage repeats.

- Static list (verified): 413c:81d7 Dell DW5821e / Foxconn T77W968 (2026-07-28);
  413c:81e0 DW5821e-eSIM (2026-07-29); 03f0:9d1d HP lt4120 (2026-09-08: "usbmode
  sets config #0" four times, cdc_ether gone, no interfaces left; it has no
  storage mode and all three configs work). The static list is needed because
  an already broken modem has no tty/cdc-wdm and is invisible to the dynamic
  scan.
- Dynamic scan: about thirty entries have `config: 0` (HP, Huawei, Dell), and
  for devices arriving as storage that reset is the normal way to wake modem
  mode. So a rule (config 0 with empty `msg`) is removed only for devices that
  already expose modem interfaces.
- The edit is accepted only if the file stays valid non-empty JSON; a backup is
  kept; idempotent. Called from postinst, hotplug (`71-5gmodem-resolve`) and
  boot, since a usb-modeswitch upgrade restores the entry.
- `_reprobe`: removing the rule does not revive a modem already set to config 0
  (2026-08-26, Cudy TR3000, DW5821e 413c:81e0: register 06:45:55, config #0
  06:46:15, rule removed 06:46:20, then nine minutes without cdc-wdm). Rewriting
  `bConfigurationValue` makes the kernel reconfigure and rebind, like a
  replug. Done only when there is no cdc-wdm and no netdev. An empty
  configuration value is the breakage itself: after config 0 there are no
  interface directories at all, so the first version that looked for an MBIM
  interface never fixed the case it was written for. If configured but without
  a channel, require class `02/0e` or `ff`, so AT-only modems are not touched.
  The working configuration is remembered while healthy (DW5821e: 2 of 2;
  Compal RXM-G1 has one; three-config modules may use the middle one); without
  a memory the last one is used. At most once per 5 minutes.
- Repair is independent of rule removal: the first version reprobed only when
  the rule was removed in the same run, so victims of an earlier run stayed
  down.
- Positional parameters are not reused with `set --` in the mask loop; that
  turned `$1` (VID:PID) into a path in log lines.

## Hotplug handlers

### `usb/20-compal-t99w175`

- Driver from `usbports.sh` (see above).
- Waiting for ModemManager only makes sense if some interface uses
  `proto=modemmanager`; on umbim/qmi setups a 180 s mmcli loop ended with "did
  not report a modem" (ZBT + MV31-W, 2026-08-18, MM disabled). The script is
  sourced by hotplug-call, so it branches instead of `exit` (exit would abort
  the other handlers of the event).
- Never `/etc/init.d/modemmanager restart` here: restart starts a second MM
  that cannot acquire `org.freedesktop.ModemManager1` from the still running
  first one and dies, while the old one is stopped; MM was gone ~95 s until
  procd respawn, the modem appeared at 2:10 after power on. A running MM picks
  up the new ports through its own hotplug.
- At boot netifd starts before MM; the proto fails with "couldn't get bus",
  declares "Device not managed by ModemManager" and gives up permanently.
  Therefore wait until MM sees the modem and `ifup` the interfaces. MM needs
  ~30 s on cold boot; 60 s was too short.

### `usb/55-5gmodem-usbports`

See coldplug. 03f0 (HP lt4120) needs the configuration change too, done by the
same coldplug.

### `usb/62-5gmodem-fastboot-rescue`

Some modules end up in fastboot involuntarily: on Huasifei WH3000 Pro (M.2)
pin 67 is tied to ground and DW5821e 413c:81d6 enters the bootloader on every
router boot (2026-08-23). We only leave fastboot (`fastboot reboot`), never
enter it. EDL 05c6:9008 is never touched (no fastboot protocol, often kept on
purpose for flashing).

Guards: only a fastboot composition (single `ff/42/03` interface without driver,
or known bootloader ids); not if a fastboot/edl process is running (someone is
flashing); at most once per 60 s and 3 attempts per address per boot; switch
`5gmodem.@5gmodem[0].fastboot_rescue='0'`. 413c:81e6 was removed from the id
list: it is the working MBIM composition of DW5829e (81e4 its eSIM variant),
and a healthy modem got `fastboot reboot` on every hotplug.

An attempt that has nothing to run on (no `fastboot` binary and no
usb-serial-generic yet) does not count. The throttle only applies when a mark
already exists: the old check `now - last >= 60` with no mark (`last=0`) muted
every hotplug in the first minute of uptime. procd does not run hotplug.d before
init, so the first chance is `5gmodem-usbports` (`usbports.sh coldplug`, S50,
every 5 s for 30 s, uptime 21-51 s), and all six retries were dropped. The modem
stayed in fastboot until someone replugged it (user report, 3.9.2, 2026-10-28;
confirmed by a cold-boot trace). Only a cold power-on enters fastboot there: a
soft reboot or a `modem_power` GPIO cycle does not. After `reboot` the modem
returns as 81d7 in about 40 s.

Path 1: a user-supplied `fastboot` binary (not in OpenWrt feeds). Path 2,
without the binary: a fastboot command is a bare ASCII string in one bulk OUT
transfer (U-Boot `doc/android/fastboot-protocol`, Android `fastboot/README`).
Bind generic to the bootloader's single `ff` interface via `new_id` and write
`reboot` to the tty; the OKAY reply is not read. The dynamic id is safe: the
bootloader PID always differs from the working composition. Runs in the
background, hotplug handlers must return fast.

### `usb/70-5gmodem-sms-modems`

Auto-configures ports for Compal RXM-G1 (05c6:90d6, custom firmware "Tri
Cascade Inc. VOS_5G", revision contains RXMG1), the 90d5 prototype (only when
the descriptor says VOS_5G/Tri Cascade, otherwise it is a Foxconn T99W175),
05c6:9025 and 1e2d:00b7. Fills only empty options.

- hotplug `$PRODUCT` has no leading zeros (`5c6/90d6/0`, `1e2d/b7/0`); the
  manual (no `$ACTION`) path synthesises the same format with `printf %x`
  when run from uci-defaults at install, so a connected modem gets ports
  without a reboot (9025 included for that reason).
- The firmware supports the full SMS set and +CUSD (AT$QCCLAC dump), but MM
  over MBIM captures messaging, so SMS and USSD use the mmcli path
  (`sms_via_mm`/`ussd_via_mm`).
- Order: mmcli flags and the WMS route fix do not need the AT port and run first
  and unconditionally; on first boot the AT probe used to fail (MM probing the
  ports, slow boot) and an early exit left the flags unset. The config section
  may not exist yet on first boot; it is created.
- WMS routes: factory routes store incoming SMS in NV where MBIM/MM cannot read
  them (message stuck "receiving" or lost). Classes 1-3 and none are routed to
  the SIM (uim), set on every appearance. The cdc-wdm node is searched under
  this device's `$DEVPATH`, not the first `/dev/cdc-wdm*`: with two modems the
  neighbour could own cdc-wdm0 and get its routes changed (audit 2026-09-12).
- AT port probing: up to 8 attempts over ~40 s; the DIAG port stays silent
  (5 s sms_tool timeout), the AT port answers OK. The detached subshell also
  detaches stdin.

### `usb/71-5gmodem-resolve`

ttyUSB/cdc-wdm numbers shift on plug/unplug/reboot and a pinned ttyUSB goes
stale ("Bad file descriptor"). On every USB event (and coldplug) the AT ports of
all modems and the active interface device are re-resolved from the USB path.
The `listmodems.sh` cache is dropped immediately, before any sleep.

Lock is non-blocking (`flock -n`; busybox flock has no `-w`), so an event during
running work used to be lost (issue #2: E3372 rebooted from debug back into
HiLink during a ~34 s autosetup, the event was dropped and the modem stayed in
HiLink without AT ports). Each event sets `resolve.pending` before trying the
lock; the holder clears it at the start of each iteration and repeats if it
reappears. The handler also runs `usbmode-fix.sh`, autosetup (which itself
checks that no working interface exists) and port repair for the SMS/USSD/AT
tabs.

### `usbmisc/25-modemmanager-usbmisc`

The modemmanager package only ships reporters for tty, net and wwan. On kernel
6.x the cdc-wdm node is in `/sys/class/usbmisc`, and the stock
`usbmisc/00_wwan.sh` only notifies netifd protos. MM then builds the modem as
AT-only (ttyUSB primary, wwanN ignored, no bearer): typical for SDX55 (T99W175,
MV31-W, DW5930e) in MBIM. With our late `new_id` bind the MM startup sysfs
scan is already over, so hotplug is the only way to tell MM. The real
subsystem `usbmisc` is passed: `mm_report_event` calls
`mmcli --report-kernel-event=...` without a sysfs path and MM looks up
`/sys/class/<subsystem>/<name>`; claiming `wwan` sent it to a non-existent
`/sys/class/wwan/cdc-wdm0`. With `usbmisc` the modem is rebuilt with "primary
port: cdc-wdm0 (mbim)". If MM is not running, mmcli is not called (it waits for
the bus and left timeouts per USB event, 2026-09-17), but the event is still
written to the cache that a starting MM reads. MM inhibit of our modems still
protects ports driven by our protos.

### `usbmisc/10-5gmodem-wwan`

Protos with `no_device=1` (our `qmiraw` included) call
`proto_set_available <iface> 0` when `/dev/cdc-wdm*` disappears; only hotplug
sets it back, and the stock `00_wwan.sh` knows only `wwan|mbim|qmi|ncm`. After
re-enumeration, channel rescue or module reboot the interface stayed down until
manual ifup (issue #16, T99W175 05c6:9025 on BPI-R4 Lite: `available: false`,
`NO_DEVICE` for 24 minutes). The handler marks availability for this package's
protos only (duplicating `00_wwan.sh` would race) and does not call `ifup`
(netifd does it). Sections without `device`, or with a USB-path device, accept
any node: cdc-wdmN changes after re-enumeration and qmiraw resolves the path at
dial time.

### `tty/05-5gmodem-noat`, `tty/26-5gmodem-mmreserve`

- `05`: service ports that reboot the modem on any AT (`noatports.sh`) are
  unbound as soon as the node appears, before any port probe runs.
- `26`: withdraw the dedicated AT port of a fragile modem (DW5821e) from MM.
  `25-modemmanager-tty` already reported it; MM waits ~2 s before probing, and a
  `remove` in that window drops the port from the queue. `mm_report_event` also
  removes it from the event cache so an MM restart does not bring it back.
  Which port and when is decided by `mm_tty_reserved` (`quirks.sh`): only
  modems in `mm_at_fragile` under proto modemmanager where MM previously found
  two AT ports.

## Init scripts

- `5gmodem-usbports`: see coldplug.
- `5gmodem-btnleds`: restores LEDs of hardware button toggles at boot to the
  actual service state (`buttons.sh syncleds`); only the press handler set them
  before. Must start after `/etc/init.d/led` (START=96, would overwrite
  brightness) and after the services (ssclash START=21). No stop: LEDs reflect
  the service, not this script.
- `5gmodem-sms-notify`: procd stops the service; there must be no manual
  killer. The old loop grepped `ps` for "5gmodem-sms-notify", but the service
  runs as `/bin/sh /usr/share/5gmodem/sms_led.sh`, so the only match was the
  init script itself and `kill -9` killed rc.common in the middle of
  `stop_service` (instance stayed in procd, `sms_led.sh` kept running).
  rc.common calls `procd_kill` after `stop_service`, and restart is stop+start
  (`restart_service` was dead code). Audit 2026-09-12.
- `5gmodem-leds`: signal level LEDs from the metrics snapshot
  (`signal-leds.sh`). Enabled unless explicitly disabled (empty = default on
  devices with LEDs). The loop lives in the script, not in `sh -c 'while
  true'`, so procd supervises the real process. LEDs are switched off on stop,
  otherwise they show a stale level.
- `5gmodem-antenna`: antenna mode for Notion R281 / Yota C300-1 (`antenna.sh`),
  no-op on other boards.
- `5gmodem-mm-inhibit`: keeps ModemManager off kernel-proto modems where udev
  ignore rules do not work (libudev-zero), see `mm-inhibit.sh`.
- `5gmodem-sessionwatch`: the network may recreate the data session with a new
  address without netifd noticing, see `sessionwatch.sh`.

## Other `lib.sh` helpers

These live in `lib.sh` but belong to other subsystems; rationale kept here.

### Text encoding from the modem (`utf8_fix`)

sms_tool returns U+00A0, U+00AB, U+00BB as single latin1 bytes. Telegram
rejects the whole request ("strings must be encoded in UTF-8"), the inbox shows
replacement glyphs. Bytes that do not form valid UTF-8 are treated as latin1;
valid sequences are untouched (idempotent). No iconv on OpenWrt by default, so
busybox awk works on bytes. sms_tool 2025.08.x also emits `ÿffffHH` (U+00FF +
literal `ffff` + latin1 hex), and in `-j` JSON output the same marker appears
JSON-escaped; both are converted back (the JSON variant to `\u00HH`, keeping
valid JSON). The awk program carries its own inline comments.

### Foreign uncommitted uci changes (`note_foreign_uci`)

uci deltas live in shared `/tmp/.uci`, and `uci commit network` commits
everything, including LuCI "Save" without "Apply", scripts that died between
set and commit, or manual `uci set`. Our netpri and mkiface commits could
detonate them (2026-07-30: "no ping to the router, internet works", the symptom
of a changed `lan.ipaddr`). Foreign changes cannot be reverted (may be real
user work), so they are logged before our commit.

### uci snapshots (`uci5g_snapshot`, `uci5g_get`, `uci_sec_snap`, `ucinet_*`)

`netpri.sh list` took 690 ms and ~145 processes per call (70 of them uci),
every 5 s while the page is open. Snapshots are explicit opt-in for short-lived
readers; writers must not use them (stale after `uci set`). Measured cost on
25.12.5 aarch64:

| operation | time |
|---|---|
| `uci -q get` | 2.8-3.0 ms |
| `${x#*"pat"}` on full dump | 4.8 ms |
| `${x##*"pat"}` on full dump | 2.8 ms |
| presence check with one `case` | 0.2 ms |
| cut from one-section snapshot (289 bytes) | 0.8 ms |

busybox expands `${x#*pattern}` by trying prefixes, so cost grows with string
length; for point reads a full snapshot does not beat `uci get` (the first
health.sh version got 30 ms slower). Rule: full snapshot only where it replaces
pipelines (`uci show | sed | head`); one-section snapshot for many reads of one
section (health.sh); plain `uci get` for a few scattered keys. Newline is the
separator because a uci value cannot contain one. No `eval` of config into
shell variables (executing user data). `_uci_snap_get` cuts with `#` (first
match): the key is unique in `uci show`, and a later measurement (2026-08-06,
5 KB config, ~120 lookups per `netpri list`) found `##` slower (~5 ms vs ~2 ms)
because the greedy form scans the whole dump; the 3 KB table above showed the
opposite, so re-measure before changing it.

### Background AT switch (`bg_at_off`)

`no_at=1` in the modem section disables background AT (metrics, SMS watcher,
bot, SMS commands, drain); user actions still work. Quectel RM551E-GL firmware
hangs the data session more often with AT polling (no hangs for a day without
AT, one every 1-3.5 h with it; issue #28).

### Raising an interface from watchdogs (`iface_up`)

`/sbin/ifup` in 25.12 runs `ubus call network reload` before down/up. Measured
harmless at rest (neighbours kept uptime, even a committed change of another
section did not drop it), but `iface_up` does not reload config, so foreign
pending network edits are not applied with a watchdog restart. Not for callers
that just changed the interface section (netifd would bring up the old version
from memory). It writes a recovery marker read by the fibocom proto: on a
normal ifup the proto reuses the active session (instant switch), on recovery
it must not (session may be dead while the modem thinks it is active). A pause
between down and up is mandatory and the result is checked: netifd processes
down asynchronously and loses an up that arrives too early, leaving the
interface down with `autostart=false`, which both watchdogs then skip as
"intentionally down" (2026-08-05, Quectel EP06: down for an hour). One retry is
enough.

### Operator names (`operator_clean`, `opname_pretty`, `opname_brand`)

- The network (and the HiLink web API) reports the host operator (T-Mobile RU
  shows as Tele2). The real brand is in the IMSI MCC-MNC; hand-checked
  `opname:<mcc-mnc>:<brand>` lines in `apn.list` are applied in both the AT and
  HiLink paths. 3-digit MNC is tried before 2-digit.
- `operator_clean` drops a trailing ` RUS`/` Rus` ("MegaFon RUS" -> "MegaFon"),
  keeping case and a lone "RUS".
- `opname_pretty`: the name from the modem wins over `mccmnc.dat`, cleaned the
  same way as the main poller; the netpri probe used to show "Megafon" from the
  database while the card showed "MegaFon", which flickered when an inactive
  modem became active. The database is only a fallback for empty or numeric
  names. MVNO names that do not match the database are left alone.
  `mccmnc.dat` is CRLF, `tr -d '\r'` is required.

### Signal level (`sig_percent`)

+CSQ is RSSI over the whole band (neighbours, traffic, noise) and says nothing
about LTE/NR quality (2026-08-25: RSSI -63 dBm, "74 %", with RSRP -109, RSRQ
-19, SINR 0.0 and 1 Mbit/s). Five buckets over four thresholds as in Android
`CellSignalStrength.getLevel` (AOSP LTE defaults), percent = bucket*20 + share
inside the bucket, matching the icon scale. Combined by the worst metric, not
the mean. Technology from the mode label; NSA uses LTE thresholds because RSRP
comes from the LTE anchor. SINR exactly 0 with RSRQ >= -14 is treated as "not
measured" (some firmware sends 0.0 instead of a dash); a real zero SINR comes
with bad RSRQ.

### AT port sharing with dialers (`at_dialer_busy`, `dial_port_for_path`, `drop_dial_port`)

Third-party protos xmm/atc dial via gcom directly on the AT port and know
nothing about `at_lock`; any read at that moment steals answers (2026-08-09,
L850 redialing every ~20 s: diagnostics got answers shifted by one command).
We yield the port. Their data tty (M-RAW_IP) must never be probed: the session
flaps and some firmware deregisters and re-enumerates. 2026-09-06 (L860-GL,
xmm, ttyACM0 dial, ttyACM2 metrics): SMS, USSD, AT console, netpri, esim and
simslot all used the dial port. Decided from the live interface config, not
`data_at_port` in the section (stale after switching to qmi/mbim). A single-tty
composition keeps its port (dial and polling share it by design, `at_lock`
exists for that).

A section `at_port` saved before the interface existed can still point at the
dial port (2026-10-30, L860 #52: `at_port=ttyACM2` = xmm `device`, while polling
used ttyACM0, so `simslot.sh` inside the poll was refused by `at_lock` every
round). `modemswitch.sh resolve` replaces such a pin when `at_for_path` finds
another port, and `quiet_at_port` does not return it.

### ModemManager ownership (`mm_owns_path`)

By fact (modem listed by MM), not by interface proto, which can disagree with
reality. Our modems are hidden from MM by `mm-inhibit.sh`, so no false
positives. Needed where AT/channel must not be touched under MM: on
DW5821e/T77W968 our AT batch next to MM dropped the data session on every tab
open (issue #13). mmcli is D-Bus: cached for a minute, logged only on verdict
change.

### QMI channel gate (`qmi_channel_free`, `qmicli_p`)

- `qmicli -p` starts qmi-proxy, which holds `/dev/cdc-wdm`. netifd's uqmi
  (proto qmi/qmiraw) and umbim (mbim) talk to the device directly; a second
  owner confuses answers ("Waiting for network registration", "Failed to parse
  message data", NETDEV WATCHDOG resets; after reboot no connection until the
  package was removed). 2026-08-17, ZBT-Z8102AX + MV31-W on umbim: opening the
  page killed the internet. Under MM no restriction (shared proxy).
- The gate uses the target modem's interface (`QMI_TARGET_PATH`), not the
  active one: an addressed poll of a neighbour tab saw "free" via the wrong
  interface (audit 2026-09-12).
- Owned means up: judging only by proto blocked all background QMI reads on
  proto=qmi even when the interface was down (EP06, 2026-08-05: SIM slot list
  empty). An interface that is coming up right now counts as busy (reading then
  broke the dial with "Unknown error" in a loop).
- Single entry point for background readers (six scripts used to call qmicli
  separately and one missed gate defeated it). Fail-closed: if the gate cannot
  be evaluated, do not read. On-demand actions (`mkiface.sh`, `qmi-recover.sh`,
  `mm-inhibit.sh`) bypass it.
- QMI over MBIM needs `--device-open-mbim` on cdc_mbim devices (driver taken
  from sysfs); without it every request timed out (2026-08-04, MV31-W on
  WH3000 Pro: no SIM slots, no eUICC).
- Time limit: qmicli hangs forever on a wedged channel and holds it (a leftover
  `--nas-get-tx-rx-info=lte` blocked slots, eSIM and everything else). Only our
  call is killed; via the proxy the client ID belongs to the proxy, so no CID
  leak. Polling instead of bare `wait`: qmicli in D-state is unkillable.
- A stale proxy after re-enumeration times out on every request while direct
  access works (2026-08-04: SIM slot buttons missing). Direct access only when
  nobody owns the channel (MM off, interface down). A dead proxy is remembered
  for 120 s (on MV31-W at WH3000 it is permanently dead; each cold read wasted
  20 s), only when direct fallback is possible. Proxy wait is 6 s when a
  fallback exists, 20 s otherwise.
- With proto=qmi the proxy is skipped entirely: a proxy left alive makes uqmi
  dials fail with "Request timed out" (EP06, 2026-08-05, cured by
  `killall qmi-proxy`).
- One qmicli per device at a time (metrics collection and SIM slot reads used
  to starve each other on MBIM). Queue wait up to 15 s, then proceed anyway;
  busybox has no fractional sleep. The lock fd is closed in all background
  children (otherwise the timeout watcher kept the lock 20 s, like the procd
  flock case). Answer files use `mktemp`, not `$$` (same in a `( ... ) &`
  subshell; audit 2026-09-12).

### Input validation (`is_num`, `is_numlist`, `is_devpath`, `is_atcmd`, `json_esc`)

Page values go into AT commands and device names. For AT, injection is a
carriage return: `1<CR>AT+CPIN=...` becomes two commands. Only admins can reach
it (ACL equals root), so it is not escalation, but a class of accidental
commands. Whitelist checks before first use. `is_numlist` rejects empty
(reset uses the word `default`). `is_devpath` forbids `..`. `is_atcmd`:

- only CR and LF are dangerous (the command is a separate argv to sms_tool, no
  shell); `tr` instead of `case` because parentheses and `;` clash with case
  syntax;
- vendor prefixes are legitimate: `^` (Huawei, Foxconn, Compal, Thales:
  `AT^SLBAND`, `AT^CUSTOMER`, `AT^switch_slot`, `AT^TEMP`), `$` (Telit GNSS
  `AT$GPSACP`), `!` (Sierra `AT!BAND`), `%` (u-blox), `&` (`AT&F`, `AT&W`); the
  console used to reject them (2026-08-04, Foxconn T99W175); `;` for chains,
  parentheses for test commands; `-` last in the `tr` set;
- LF is checked separately with a literal pattern: `$(...)` strips trailing
  newlines, so a lone LF left after `tr` became an empty string and passed
  (`AT<LF>AT+CPIN=1234` went through, found 2026-08-04).

`json_esc`: registry and saved profiles were built with `printf`; a quote or
backslash in a USB `product` or APN broke the whole JSON and every jsonfilter
reader got nothing (audit 2026-09-12). Control characters are dropped too (CR
breaks strict parsers).

### Wait step (`sleep_tick_init`)

Fractional `sleep` is missing in some busybox builds (GL9869: "invalid number"
for `sleep 0.1`), which would turn wait loops into busy loops. Probe with
`sleep 0.0`; otherwise the step is one second and limits are scaled by
`_TICKS_PER_SEC`.

### AT query entry point (`at_query`)

AT access was written 50+ times in 17 files. Problems: some callers skip
`at_lock` (mkiface, qmi-recover, iscompal, mm-inhibit, collect) and a parallel
reader steals the answer (reproduced: sms_tool "No response from modem", answer
in someone else's `cat`); sms_tool has no timeout (~35 s on a silent port);
every caller parses differently. `at_query` takes the queue, bounds time,
strips CR. It unlocks only if it took the lock (`at_lock` is reentrant,
`_AT_LOCK_HELD`). If the queue is not obtained it returns 2 and does not touch
the port (rule from netpri: losing one update is cheaper than corrupting
another). Return codes: 0 answer, 1 not allowed, 2 port busy. The killer
subshell closes inherited fds, including fd 8 (flock on the port): otherwise
it held the port until its sleep ended (poll #1 1.8 s, #2-3 6.7 s each).
Polling instead of bare `wait` (sms_tool in D-state on T99W175 05c6:9025,
2026-08-17, rpcd 30 s, XHR errors).

### SMS commands bookkeeping (`sms_cmd_key`, `sms_cmd_done_file`, `sms_card_id`)

The done list is shared by `smscmd.sh` (writes) and `smsbridge.sh` (deletes
messages only after execution), so key format and path live in one place. The
key includes the text (two messages from one sender in one minute are
different commands). Stored on flash next to "seen", so a reboot does not
re-execute. Keyed by SIM ICCID (from the metrics snapshot, no modem access),
not by modem: a SIM brings months of its own messages, and after switching
eSIM -> physical SIM a modem returned 50 messages back to January
(2026-09-02). An unknown card is a first meeting: its messages are marked done
silently. Falls back to the modem path when the ICCID is unknown.

### SMS storage (`sms_cpms_state`, `sms_apply_cpms`, `set_sms_storage`)

`sms_tool -s` sends `AT+CPMS="XX"` which sets only mem1 (read/delete). Where new
messages are stored is mem3; nobody set it (FM350: "SMS only arrive with SIM
storage selected"). Test form cannot be trusted: FM350 answers `AT+CPMS=?` with
`("SM"), ("SM"), ("SM")` yet accepts `AT+CPMS="ME","ME","ME"` and then reports
`"ME",0,50,...` (50 slots vs 10, 2026-08-31). So: try the full form, on refusal
mem1 only (the command applies atomically), and read the result back from
`AT+CPMS?`, because `sms_tool at` does not print the final OK (EP06-E,
2026-08-31). FM350 puts spaces after commas, Quectel does not. Storage choice:
larger capacity wins (ME usually 50-100 vs ~10 on SIM); a manual choice
(`storage_touched`) is kept but still applied; if the modem cannot receive into
the chosen storage, the setting follows the fact. The short `-s` query is used
once here on purpose (it resets mem2/mem3 to SM on FM350, immediately fixed by
the full form) and must not be used in periodic polls (see `smsbridge.sh`).
CPMS often does not survive a modem reset, so it is called from modem switch,
both pages and the first SMS read after boot.

### Downloads through the local proxy (`net_proxy_port`, `net_fetch`)

Router-originated traffic is dead under operator whitelists while LAN clients
work through clash/mihomo (tproxy only catches forwarded traffic). Ladder from
tgnotify: direct, then the HTTP port from the clash config, then the mihomo
runtime (`/configs`, open the port with PATCH; listens on 127.0.0.1 only). Used
for the app updater and the APN database. `curl -x` handles CONNECT for https;
without curl, wget with proxy env vars. tgnotify still has its own copy.

### Default routes (`route_add_default`, `is_p2p_dev`, `extra_uplink_nets`)

- Default route metric is unique per table, not per device: adding `default dev
  A metric 130` while B holds 130 fails with "RTNETLINK answers: File exists"
  (2026-08-25). The caller had already deleted the old route, leaving the link
  without a default (green in the list, no internet). On conflict the next free
  metric is used (uplinks are spaced by 10) and the shift is logged.
- "File exists" can also mean our own identical route (previous run or
  netifd); the full identity (family, table, device, metric, gateway form) is
  compared, the gateway as a fixed string (IPv6 has `:` and dots). Before,
  each watchdog tick added up to nine identical defaults and hundreds of
  "metric N is taken" lines (VOS 5G / SG500M2-X, 2026-09-13). On-link means a
  line without `via`.
- A gateway that is not on-link (/32 on Wi-Fi client or cellular) gets a host
  route first, as netifd does.
- `is_p2p_dev`: `IFF_POINTOPOINT` (0x10) in sysfs; a gatewayless default is
  correct on cellular raw-ip and a black hole on 802.3.
- `extra_uplink_nets`: uplinks outside zone wan (single-port routers keep
  internet on a DHCP client in zone lan, e.g. Odroid C2). Identified by a
  default route; tunnels (tun/wg/zt) are excluded.

### Service state (`svc_running`)

`status` of a non-procd init script is not defined in rc.common; it falls back
to `help` and exits 0, so "running" is always reported (2026-08-26: a button
toggling passwall2 stopped it and never started it again). For procd services
without instances `status` says "active with no instances" with code 0
(`ubus call service list '{"name":"nikki"}'` -> `{"nikki":{}}`, 2026-09-09).
Order: ubus (instance with `"running": true`); a hand-written
`status()`/`status_service()`; for procd without own status ubus is final; for
the rest the `/etc/rc.d` enable symlink (the toggle pairs enable/disable with
start/stop).

## `usb/21-5gmodem-tdtech`

Binds PCUI and other vendor ports of TD Tech 3466:3301 on hotplug through `usbports.sh bind`. See [others.md](../modems/others.md#td-tech-mt5700m-cn-34663301-balong-5000).
