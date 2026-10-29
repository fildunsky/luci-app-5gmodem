# Modem identity, autosetup and the active modem

`modemswitch.sh` is the multi-modem controller. It sources the topic libraries
in `msw/` (`identity.sh`, `iface.sh`, `hilink.sh`, `setup.sh`, `apn.sh`) into
one shell before dispatching a verb, so cross-calls between them work as if it
were one file (the split was a pure move, bodies unchanged). A modem is keyed by
its stable USB topology path (`1-1.3`), which survives reboots and separates two
identical VID:PID modems. Per-modem state lives in `config modem 'm_<path>'`
sections of `/etc/config/5gmodem`; one modem is "active" and the app reads
metrics, SMS and USSD from its ports and interface. Interface creation is in
`mkiface.sh` (see [interfaces.md](interfaces.md)); upgrade migrations are in
[migrations.md](migrations.md).

## Verbs

| Verb | Purpose |
|---|---|
| `active` | print the active USB path |
| `switch <path>` | make a modem active: pick its AT port, point `@5gmodem[0]` at it, pre-warm caches |
| `save <path>` | snapshot the current AT port into the modem section |
| `resolve` | re-resolve ports and devices of every present modem (boot coldplug and every USB hotplug) |
| `autosetup [targets]` | plug-and-play: set up present modems that have no working interface |
| `autoapn <iface> [_ imsi]` | pick and apply an APN if needed |
| `apnfor` | report which APN would be picked, without changing anything |
| `profiles` | JSON list of every modem section ever seen (read only) |
| `delprofile` | delete a section and its interface |
| `forget` | delete sections of modems not on the bus (explicit user action) |
| `cleanup [apply]` | list / remove orphan interfaces and expired parks |
| `dedupe-ifaces` | remove duplicate interfaces on one netdev |
| `mkhilink` | create a DHCP interface for a portless modem (HiLink or phone) |
| `setalias`, `smsopt`, `ackswap`, `hidenumberhint`, `ussdsupport`, `mmindex`, `wdm`, `wdmdrv`, `xmm`, `webpass` | small helpers used by the UI |

`smsopt`, `ackswap` and `hidenumberhint` write and commit uci on the router on
purpose: a `uci.set`/`uci.save` from the browser lands in the LuCI session
staging and raises the "unsaved changes" banner although the user configured
nothing. `smsopt` validates both key names and values, because the verb is
reachable from the web and a value ends up as `sms_tool -d`.

## Registry record memo (`_reg_rec`)

Ports, descriptor and vidpid come from one registry record per modem instead of
three `listmodems` parses; the registry also checks the saved `at_port` against
the modem's own port list. The memo invalidates itself on the `listmodems`
stamp, not at process end: `try_at_debug` and `setup_one_modem` wait for ports
to appear in a loop, and a per-process memo would answer "no ports" forever.
Two slots are kept because `switch` alternates between the old and new modem.

## AT probing

- `at_probe`: `sms_tool` has no timeout and blocks ~35 s on a silent DIAG port,
  so it runs in the background and is killed after ~4 s. A child stuck in D-state
  (tty driver hang, seen on T99W175 05c6:9025 with mute ports) cannot be reaped;
  it is abandoned instead of `wait`ed, otherwise rpcd hits its 30 s timeout and
  the page shows an XHR error.
- Background children close fds 7/8/9 (`7>&- 8>&- 9>&-`): the caller may hold
  `at_lock` (fd 8), the hotplug lock (fd 9) or the uci transaction lock (fd 7);
  flock lives on the open file description and an inheriting child would keep
  the lock after its owner exits.
- `at_for_path` tries the registry's saved (already validated) `at_port` first,
  then probes the rest; with up to seven ports at 4 s each a cold scan costs
  ~30 s. It excludes the dial port of xmm/atc interfaces
  (`dial_port_for_path` in `lib.sh`): those protos keep data (M-RAW_IP) on their
  tty and an AT probe there drops the session. On L850/L860 the metrics port
  becomes ttyACM2. The skip result is memoised per process because `resolve`
  calls `at_for_path` up to six times for the same path.
- `modem_imei` uses, in order: the IMEI already in the section, the HiLink web
  API, one `AT+CGSN` on a freshly refreshed port list (cached lists are 8 s old,
  and after re-enumeration a stale tty belongs to another modem). The read is
  done under `at_lock`, otherwise it collides with the metrics poll and gets the
  answer to someone else's command. A negative cache keyed by time and the port
  list avoids paying the full probe on every hotplug event for modems without a
  responding AT port; new ports retry immediately.

## Modem identity (`msw/identity.sh`)

Section names are derived from the USB path, so the path is a slot, not an
identity. Identity is the IMEI (primary) plus the sysfs `serial` (available
instantly, no AT needed; batch placeholder serials are rejected in `lib.sh`).

### Swap detection (`swap_cleanup`)

Run per present modem on `resolve`. The section remembers `vidpid`; if a
different device is on the same path, everything learned about the old modem is
wrong. Temporary absence is not a swap: modems routinely disappear for a minute
on `AT+CFUN=1,1` (including our own after adding an eSIM profile), so cleanup
happens only on a proven vidpid change.

- Same vendor, different PID on the same path = composition change of the same
  modem (E3372 12d1:14dc <-> 1566 <-> 1442, usb-modeswitch, CUSTOMER change).
  Hardware properties (`kind`, `netdev`, `at_debug`, `network`) are kept; only
  composition ids, `at_port` and path caches (`purge_path_caches`) are reset.
  IMEI cannot decide here: transitional compositions answer neither AT nor the
  web API. Before this rule an E3372 mode switch erased its HiLink flag and it
  grabbed a neighbour's AT port.
- Real swap: path caches are purged (slots, bands, static IMEI, metrics snapshot
  of the old modem), the profile is parked (below), and the old modem's
  interface is set `auto=0` and brought down, because its device node now
  belongs to another modem and netifd would loop on a stale device (FM350 -> L850
  in the same port: xmm looping "AT port not valid! / Device path not found!"
  every 5 s). The interface is no longer deleted: it is pinned to the hardware
  by `modem_imei` and comes back when that modem returns to any port. Only old
  interfaces without an IMEI stamp get `modem_stale=1` ("recreate, do not
  adopt"), since two modems in one port are indistinguishable there.
- Cleared keys include `imei` and `serial` (left behind they make
  `sec_by_serial` find the wrong section and veto legitimate migrations),
  `ussd_3g` (an EC21 inherited "go to 3G for USSD" from a Telit), `heal`
  (permission to power-cycle is per device), `mm_exclude`, `apn_plmn`/`apn_imsi`,
  `band_full`, `save_band*` (an R11e-LTE got "1 3 7 8 38" from the previous
  modem and lost B20), `model_vp`. Then `apply_ussd_quirk` re-runs for the
  active modem, because the global `sms.ussd_3g` is otherwise only updated by
  `switch`.

### Parking (`park_profile`, `prune_parks`)

Two different modems used alternately in one port share a section, so without
parking each swap lost APN, band lock and choices (issue #2: E3372 and T99W175).
Before wiping, user keys are moved to `m_park_<imei>` (or `m_park_s<serial>` when
only the serial is known: compositions without a tty, e.g. 05c6:9025 in QMI,
never get an IMEI written).

- Park under `imei_prev`, not `imei`: the poller can rewrite `imei` with the new
  modem's number before the vidpid check runs.
- `path` is never parked: sections without `path` are invisible to every `m_*`
  loop, so a park never shows up as a phantom modem.
- `network` is parked deliberately: `mkiface` computes taken names from
  sections, and an unparked name was handed to the new modem on top of the kept
  interface (Compal took `modem2` reserved for an E3372).
- `prune_parks` runs only after the park is complete, since it commits; an
  interrupted half-written park lost its `network` key.
- Parks carry `parked_at` and expire after 30 days (`park_ttl_days`, 0 = never);
  parks without a timestamp are stamped first instead of deleted.

### Migration (`ensure_section`, `migrate_profile`)

When the same hardware appears on a new path, user keys move from the old
section (or a park) to the new one and the old section is deleted. Derived data
(model, `at_port`, vidpid, netdev) is not copied, it is re-read.

- New sections are created only for devices present on the bus; a crashed module
  flashing a recovery composition for a second otherwise left a phantom profile.
  `path` is always backfilled, because path-less writers (`setopt atdebug` before
  `resolve`) produced invisible sections.
- Serial migration happens first and immediately after plug-in, before any AT
  read. If another section with the same serial has its device present, the
  serial is a batch number: it is blacklisted permanently and removed from both
  sections (VOS 5G and SG500M2-X shipped with the same serial).
- IMEI migration falls back to the IMEI already stored by the poller when the
  live read fails (the AT port may be choked by a twin interface).
- Same path, same vidpid, different IMEI = another unit of the same family
  (Fibocom L850 and L860-GL-16 are both 8087:095a): only derived data (model,
  port pins, path caches) is cleared.
- Guards against a misread IMEI: if both serials are valid and differ, never
  migrate; if the device on the old path is present right now, never migrate
  (two live modems cannot share an IMEI). Before this guard a four-modem router
  lost its Compal section and an MV31-W inherited its IMEI, model and interface.
- `migrate_profile` does not take `network` if the receiver already has an
  interface stamped with its own IMEI, does not move `mm_exclude` across
  different protocols (a stale `mm_exclude=1` from a 1e2d:00b7 section hid a
  modemmanager modem from MM for good), and does move the custom alias and the
  manual AT flags (`mm_at_if`/`mm_at_vp`): an RW350-GL on a board that
  re-enumerates 4-1 -> 3-1 every boot lost its name. A leftover twin interface of
  the same IMEI with a stale `/dev/tty*` is deleted, otherwise it kept dialing
  the same modem through a second port.
- `resolve` additionally merges duplicate sections by stored IMEI (one present,
  one absent) for cases where migration could not read the IMEI in time.

### Per-modem quirk flags

`apply_ussd_quirk` sets the app-wide `ussd_raw` (`sms_tool -R`) and `ussd_3g`
from the active modem: manual per-modem value first, then `quirks.sh`. For
`ussd_raw` an unknown modem is left alone; for `ussd_3g` an unknown modem gets
an explicit 0, otherwise it inherits the previous modem's value (a Telit's 1
stayed on for an FM350).

## switch

- Only a real modem can become active. `switch` writes `active_modem` and
  `preferred_modem`, and `preferred_modem` pulls activity back on every
  `resolve`; a phone in tethering mode made active and unplugged pinned the page
  to an empty card. The check refuses only on a non-empty modem list, because an
  empty list is usually a failed or mid-reenumeration enumeration.
- `save_to` uses `secname` only; calling `ensure_section` for the modem being
  left cost 640 of 1260 ms of a tab switch.
- Invariant: `active_modem`, `at_port`/`device`, `network` and `iface_proto` in
  `@5gmodem[0]` describe the same modem. When the new modem has no port or
  interface yet, the keys are cleared rather than left from the previous modem:
  an empty value means "none", a stale one made every consumer read the
  neighbour (operator of one modem shown for both, neighbour's IP on the card,
  "Fibocom (AT-dial)" shown for a Compal). `detect.sh` resolves the port from
  `device` first, so both `device` and `at_port` are pinned.
- A modem without an AT port (HiLink) clears `readport/sendport/ussdport/atport`,
  otherwise the SMS page showed the previous modem's messages.
- Metrics snapshots are per modem, so switching does not invalidate them.
- Pre-warm: slot and band caches of the new modem are filled in the background
  (`setsid`, so it survives the rpcd/ssh session; one at a time, killed by
  process group, pid written by the parent, marker `5gmodem_prewarm` checked in
  `/proc/<pid>/cmdline` before killing). Metrics and operator are not pre-warmed.

## resolve

Runs on boot and every USB hotplug, always in the background, serialised by the
uci transaction lock on fd 7 (`/tmp/5gmodem/ucitx.lock`): it writes sections for
up to ~12 s while `detect.sh`/`switch` commit the same `/tmp/.uci` staging, and
a half-built state used to get committed. Other writers skip their turn while
the lock is held. The lock is not passed to the background `cleanup apply`.

Per present modem:

1. `swap_cleanup`, then the serial stamp (strictly after cleanup, which removes
   the previous unit's serial).
2. AT port: keep the pinned port if it still belongs to this path and answers
   (measured: probing took 4.4 s per event, the pin check hundredths). Ports
   appear several seconds after hotplug-add (FM350 creates 7), so the probe
   waits with a bound. If no port answers, the saved one is kept only if it
   still exists and belongs to this modem; otherwise it is cleared (after a
   late plug-in the old number belonged to the neighbour: 0% signal, no uptime).
3. Model for inactive modems is read once with `AT+CGMM` (the poller only reads
   the active one; a SIM7600E stayed nameless). CR/LF are converted to newlines
   because some firmware separates lines with CR only. The value passes
   `_model_sane` and `model_alias`, and `model_vp` stamps the vidpid it was read
   from (a Samsung phone in the SIM7100E's port was shown as SIM7100E). Before
   that, one `AT+CGSN` detects a different unit with the same vidpid.
4. Node collision: an interface of an absent modem whose absolute `/dev/tty*`
   now belongs to a live modem is set `auto=0` with a marker (not deleted;
   absence is often transient) and woken again when its modem returns.
5. Wake-up: interfaces put to sleep by `swap_cleanup` get `auto` removed when
   their modem is back, and their `devpath` is refreshed (the cdc-wdm number may
   have moved to another modem while asleep). Sleeping every absent modem's
   interface was tried and reverted: modems leave the bus normally during
   CFUN=1,1, composition changes and driver rebinds, and a freshly created
   Compal interface fell asleep during its own re-enumeration.

Active modem selection: `preferred_modem` wins when present. A preferred entry
that is not in the modem list at all (phone) is dropped. If the active modem is
gone, the replacement is the modem with a working interface, not the first in
the list: FM350 has a regular re-enumeration flap, and during that second a
freshly plugged unconfigured modem took activity and the global SMS ports.

Then: SMS/USSD/AT ports are set to the metrics port and immediately separated
again by `ensureports.sh` (sms_tool opens the port per call, and a read that
hits the metrics poll returns nothing: USSD on MeigLink answered "No response
from modem"). Connection recovery: `apply_mm_state`; park interfaces of absent
modems whose `/dev/cdc-wdmN` was taken by a present modem (down and device
cleared, otherwise netifd brings them up on the other modem's wwan and the DHCP
child releases its lease); `ensure_iface` for every present modem; FCC unlock
for DW5821e/T77W968 on qmi/mbim in the background (MM sends it itself from
`fcc-unlock.d`; without it the module reset USB every five minutes); mark
foreign interfaces (`orphan_iface_for`). `@5gmodem[0].network` follows the
active modem; if it has no section, a single `modemmanager` interface is kept
(MM modems often have no section, and clearing it broke `_via_mm` SMS/USSD).
Finally `cleanup apply` runs in the background.

## autosetup (`msw/setup.sh: setup_one_modem`)

Plug-in to internet without visiting tabs; disabled by
`5gmodem.@5gmodem[0].auto_setup=0`. Targets are all present modems without a
working interface (a global "any modem online" guard used to skip the second
modem forever, and a `break` configured only one of two modems at install time).
HiLink modems without AT ports are targets even with an interface (debug mode is
lost on every reconnect), and so are phones whose interface is not dhcp on their
own netdev.

- A device that vanished since enumeration is skipped (`usb_path_present`).
- Activity is not taken: a new modem becomes active only if there is no active
  modem or it left the bus; the global `at_port` is written only for the active
  modem.
- `want_proto` (set by the `xmm` verb) is a one-shot marker: after
  `AT+GTUSBMODE=0` the modem re-enumerates and autosetup must set `xmm` instead
  of the driver-derived `fibocom`.
- Adoption before creation: find the interface by IMEI first (kept for this
  hardware after a swap, or the modem moved ports), then by USB path for old
  configs, then reject it if `iface_owned_by` says it is pinned to other hardware
  or `modem_stale=1`. On adoption `auto=0` is removed and the path stamp is moved
  to the current port. `iface_proto` is synchronised only if a choice already
  exists and only for kernel protos; writing it unconditionally turned automatic
  fallbacks into "user choice" and froze 413c:81e0 / 05c6:90d5 on qmi.
- After adoption a plain `ifup` is used; a global `network reload` only when
  proto/device/devpath changed or netifd does not know the section, because
  reload restarts every interface whose uci differs from the loaded state
  (plugging a Telit restarted a working FM350 for 6 s).
- `autoapn` is run for adopted interfaces too (one inherited "tt" from a
  previous SIM for good otherwise).
- New interfaces: `MODEM_PATH="$P" mkiface.sh "" auto`. `mkiface` picks the
  name (pinned to the section, bumped only if another modem holds it) and the
  proto from the control node driver. Afterwards `drop_stale_ifaces` removes
  older interfaces of the same modem, and `autoapn` runs in the background with
  fds detached (it may wait a minute).
- For xmm the metrics port must differ from the dial port (ttyACM0 carries data,
  L850/L860 metrics go to ttyACM2).

## HiLink and phones (`msw/hilink.sh`)

- `is_hilink`: explicit ids (`HILINK_IDS`: 12d1:14dc, 12d1:14db, 1bbb:0196,
  19d2:0581, 19d2:0536; 1f01 is the CD-ROM mode before usb_modeswitch and has no network)
  plus a structural rule for listed vendors: a netdev with no AT port and no
  cdc-wdm. A "has a netdev" heuristic was wrong: qmi_wwan creates wwan0, and
  Telit LM960 (1bc7:1040) was declared HiLink and became unconfigurable. Notes:
  12d1:14db (E8372 / MTS 8211F) was missing from the list and got
  `proto=fibocom` on eth2; 05c6:90b4 Android sticks in RNDIS are routers with NAT
  at 192.168.100.1, while their "modem only" mode exposes cdc-wdm under the same
  vid:pid and must go the QMI way; ZTE 19d2:* sticks in RNDIS have NAT at
  192.168.0.1 and goform metrics, and their debug composition has AT ports.
- `is_tether`: RNDIS function and no control ports, no vendor list. Same setup
  as HiLink, different `kind`, because a phone has no web API to poll.
- `setup_hilink` (no mkiface: nothing to dial): reuses an interface kept for the
  IMEI, names it `modem`, `modem2`, ...; strips leftover `apn/pdptype/usbpath/
  auth/...` from an earlier wrong proto; sets `metric=20` only if none is set (an
  E3372 at metric 0 fought WAN for the default route); stamps `modem_path` and
  `modem_imei` itself (without stamps a stick accumulated modem, modem4, modem5);
  adds the interface to the wan zone (otherwise no NAT). It calls `ifup` only if
  the config changed or the interface is not up on the same device: sticks
  enumerate three times on power-up, and an unconditional ifup released the
  lease and restarted wireless twice a minute (ZTE 19d2:1405).
- Order for HiLink in `setup_one_modem`: bring up DHCP first, then `try_at_debug`.
  The web API at 192.168.43.1 is reachable only when eth3 has an address in its
  subnet (curl binds to it); calling debug first failed silently on a fresh plug
  (issue #2). The AT port is pinned whenever the modem is in debug, not only
  after switching it now, otherwise `5gmodem.sh` saw `kind=hilink` without
  `at_port` and polled the web API.
- `try_at_debug`: debug mode exposes six serial ports while keeping the netdev
  and traffic (verified on E3372) and gives TAC, band, EARFCN and USSD; it does
  not survive a modem reboot, so it is re-applied on every appearance, gated by
  per-modem `at_debug` (default on). It waits up to 30-40 s for the web server
  (probe returns `hilink:1`), retries the switch three times, then waits for a
  tty by sysfs glob (`_ad_hastty`: ttyUSB directly under the interface, ttyACM
  under `tty/`) instead of rebuilding `listmodems` in a loop, which invalidated
  the shared cache twenty times. After success: one `listmodems --refresh` and
  `hilink.sh connect`, because data does not come back by itself.
- A device that already has ttys is not switched again. For ZTE the switch is
  `SET_DEVICE_MODE` plus `REBOOT_DEVICE`, so every hotplug rebooted a modem
  already in debug. Olax MT80 (ZXIC, 19d2:0548 CD-ROM, 0558 normal, 0536 debug)
  looped this way, and the WAN xHCI of ZTE MF286D died on each disconnect. The
  0536 vendor ports (1.2-1.4) need `option1` new_id with class `ff`, like 0581;
  AT is on the first two, 1.5 is ADB.

## APN selection

Code: `msw/apn.sh` and the `autoapn` verb.

`apn_pick` order: our overrides in `apn.list` by PLMN from the SIM (hand-checked
Russian MVNOs, e.g. T-Mobile -> `tt`), then the world database `providers.tsv`
by IMSI/ICCID with specificity scoring (format and scoring from apn-autoconfig,
data GNOME MBPI + AOSP, 1459 operators), then `apn.list` by operator name and
network PLMN. An MVNO's registered PLMN belongs to the host network (T-Mobile is
seen as 250-20 Tele2, its IMSI says 250-62), so the SIM code goes first.

- `_tolower` uses sed: busybox `tr` works on bytes and mangles two-byte UTF-8
  Cyrillic, so no Cyrillic pattern in `apn.list` could ever match.
- `apn_db_lookup`: a downloaded `/etc/5gmodem/providers.tsv` (survives app
  upgrades) wins over the packaged one; IMSI/ICCID masks use `x` as wildcard;
  44011 (Rakuten) is excluded from docomo `mopera.*` APNs that won on ties; the
  score is printed as fixed-width inverted numbers so plain busybox `sort` works.
- `autoapn` never touches a working manual choice (`apn_mode` manual) and leaves
  the APN empty in roaming (registration 5): the guest network's APN is wrong
  and travel profiles get settings from the operator.
- It polls the interface's owner modem (`POLL_MODEM`), not the active one (a
  returning Telit got the active Compal's "tt").
- An IMSI passed by the caller (the SIM-change trigger in `5gmodem.sh`) skips
  waiting for an address and the modem query; a hot SIM swap previously burned
  a minute. Without it the IMSI is polled fresh with an adaptive step (the old
  cached snapshot had no IMSI on first setup: SIM7600E on T-Mobile got
  "internet" and no IP). An address no longer means "APN is fine": operators
  accept any APN, and a Beeline SIM kept "tt" for years.
- Fallback to ModemManager for IMSI and PLMN when there is no AT port (Compal
  05c6:9063 exposes only cdc-wdm and wwan). MM's PLMN is split into MCC and MNC;
  "-" placeholders from metrics are normalised to empty; an IMSI already taken
  from MM is not overwritten by the snapshot.
- A missing operator is not a reason to give up when the IMSI is known (FM350
  with `mm_exclude` never got an APN and the trigger looped).
- Giving up writes `/tmp/5gmodem/autoapn_<sec>.gaveup`; the trigger then waits
  30 min instead of 1 min (it looped every 2.5 min for days). Success stamps
  `apn_imsi`/`apn_plmn` in the section; an empty PLMN on the fast path does not
  overwrite the stored one.
- Before re-dialing, wait for registration: via MM (`modem.generic.state`, 1 s
  step, 30 s cap; the hot-swap "SIM hot swap setup" takes 10-15 s) or via
  `AT+CEREG?` for fibocom/atc/xmm (2 s step, 30 s cap). Without it the interface
  was raised 3 s after ifdown into a booting modem and took three failed rounds
  of the proto's 30 s back-off.
- PDP type auto-selection was removed: default is IPv4 (see `set_pdp_opt`).

## profiles, delprofile, forget, cleanup, dedupe

- `profiles` reads one `uci show` dump for the whole verb and one section
  snapshot per card (`uci_sec_snap`), lists sections by header (`=modem`, not by
  `path`), skips `m_park_*`, backfills `path` from the section name
  (`m_1_1_3` -> `1-1.3`), and flags interfaces shared by several sections.
- `delprofile` deletes the section and its interface (an orphan Telit interface
  fought a Compal for `/dev/cdc-wdm0`) unless another section uses the same
  interface. If the deleted modem is still on the bus it stays active, otherwise
  another present modem is chosen; clearing `active_modem` made the next
  `mkiface` write into a junk section `m_`.
- `forget` uses `listmodems --refresh` (a cached list could mark a present modem
  absent and its settings would be erased), does nothing on an empty list, never
  touches the active modem or a modem whose interface is up, and leaves
  interface removal to `cleanup apply`.
- `cleanup`: garbage is an interface with our stamp (`modem_path`/`modem_imei`)
  that no section, live or parked, claims. Not garbage: parked interfaces,
  unstamped interfaces, interfaces that are up or have an address (`||`, not
  `&&`: an IPv6-only or raw-ip interface without IPv4 was deleted on every
  resolve). Parks older than `park_ttl_days` (default 30, 0 = never) are removed
  together with their interface if it is ours and down.
- `dedupe-ifaces`: an IMEI-randomising stick (E3372 family) looked like a new
  modem on every reconnect and collected modem..modem4 on one eth2. The real fix
  is the MAC anchor in `lib.sh`; this verb removes leftovers: same device and
  usb path as the main interface, referenced by no section. The old "does not
  carry the default route" check never let anything go (duplicates share
  `l3_device` with the main interface); the safety check is that the main
  interface is up.

## xmm verb

Switches the active Fibocom L850/L860 (Intel XMM) to NCM: `AT+GTUSBMODE=0` and
`AT+CFUN=15`, then ~40 s re-enumeration to 8087:095a, then the xmm proto (MBIM
has no band control, XMM has `XACT`). `want_proto=xmm` is set beforehand in the
section (survives re-enumeration; autosetup runs under procd and is not killed by
SIGHUP). The port drops with "I/O error" on reboot; no answer is awaited.
Firmware 18600/18601 (L860) removed `AT+GTUSBMODE` (ERROR); the working path is
`at@nvm:cal_usbmode.num=0` followed by `at@store_nvm(cal_usbmode)`, without
which the mode resets on reboot.

## ussdsupport

Answers from data only, never touching the port: no AT port -> unsupported;
`quirks.sh` database; registration "SMS only" in the CS domain (CREG/CGREG 6 or
7, read from `registration_cs` of the snapshot, since `registration` masks it
with the data status) - seen on MeigLink SLM770A-R where `AT+CUSD=?` returns
`(0-2)` but requests stay silent; and current RAT LTE/5G, where CSFB takes ~30 s
and ends with `+CUSD: 4` (Telit LM960 on MegaFon), while the same code in 3G
(`AT+WS46=22`) answers in seconds.

## mmindex / wdm

Both take an optional USB path. Without it they answered for the active modem,
and callers working on another modem got the wrong index or node: `netpri.sh`
cached a neighbour's operator for 30 min, and the metrics poll wrote another
modem's QMI extras into sticky `/tmp/5gmodem/qmi_<key>` files.

## setalias

The alias is stored in the path section next to the IMEI it was set with, so it
follows the hardware; with an unreadable or batch IMEI it stays with the slot.
Length is capped (UTF-8 aware via awk under `LC_ALL=C`), and the `listmodems`
cache is dropped so the tab shows the new name.
