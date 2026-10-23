# Diagnostics: developer report, Modem page, AT console, 5gtop, telemetry, statistics

This subsystem covers everything that observes the router and the modem without driving them:
`collect.sh` builds the developer report (a plain-text dump plus a set of "verdict" sections that
explain the dump in words), `view/modem5g/5gdebug.js` is the Modem page (profile cards, modem
settings, report button), `view/modem5g/sendat.js` is the AT console, `/usr/bin/5gtop` is the
terminal version of the Network page, `telemetry.sh` exports a flat JSON for external consumers
(MQTT, Home Assistant, LCD screens), and `stats.sh` keeps the history series for the Statistics tab.
`/usr/libexec/rpcd/5gmodem_sms_forward` is a small rpcd plugin and carries no design notes.

The common rule for all of them: they read what the poller already collected (metrics snapshot,
watchdog state files, uci, sysfs) and add as few new port accesses as possible.

## collect.sh: developer report

### Background collection

`collect.sh start` returns immediately and runs `report` in a background subshell; the UI polls
`collect.sh status` (`{"state":"running|done|idle","progress":"N/9 key"}`). `collect.sh run` prints
the report synchronously (useful over SSH: `/usr/share/5gmodem/collect.sh run > /tmp/diag.txt`,
which works when LuCI itself is dead). Output goes to `/tmp/5gmodem/diag.txt`.

- A full collection takes tens of seconds to minutes (one AT command on a silent port costs ~6 s),
  while rpcd kills a call at 30 s. A synchronous call would show "XHR error" while the work goes on.
- The redirection `>/dev/null 2>&1 </dev/null` must be on the subshell itself, not on commands
  inside it; otherwise the subshell keeps rpcd's pipes open and the call still waits for EOF (same
  pattern as `reboot_modem.sh`, `simslot.sh`).
- `sleep 1` before returning from `start`: rpcd sometimes loses the reply of a call that exits
  instantly while it has a freshly spawned background child (the browser gets an XHR error every
  other time). The short sleep makes it reliable.
- `$LOCK` holds the PID; a second `start` while one runs returns `running` instead of starting a
  second collection (there is only one AT port).
- `tr -d '\000'`: `/proc/device-tree/model` and `dmesg` contain NUL bytes that turn the report into a
  "binary file" for grep and viewers.
- The progress file holds a step number and a Latin key (`5/9 sim`), not a phrase. The frontend
  translates the key; earlier the backend sent ready Russian text that showed up in the English UI.
  The step counter matters because the eSIM step alone runs over a minute. `STEP_TOTAL` must match
  the number of `collect` calls; the frontend gives up after 180 polls x 2 s (6 minutes).
- `_proto_names` renames `mbimp` to `MBIM+MM` everywhere except in uci `key=value` lines.

### The report must not break anything

Diagnostics is the tool people use to ask for help, so it must be read-only:

- `ESIM_READONLY=1` is exported; scripts that can take over a channel (`esim.sh`) answer "busy" in
  this mode instead of grabbing it.
- QMI reads (`qmi_format_verdict`, "QMI extras") run only when `qmi_channel_free` says the channel is
  free, and without `-p`. The proxy flag spawned a `qmi-proxy` that outlived the report; the next
  `sessionwatch` round killed it as an orphan and did `ifup`. On a card in "illegal" state that ifup
  restarted the qmi.sh loop and reset the interface error the health ladder relies on, so the report
  itself broke the dial (Telit FN990A28 on WH3000 Pro, 2026-09-04). With a ModemManager-owned
  channel and no shared proxy the read is skipped entirely (opening it directly drops the session).
- The eUICC port sweep never touches the dial port of xmm/atc (that tty carries data; CCHC/CCHO on
  it drops the session - seen on L860-GL, 2026-09-06). The inline logic mirrors
  `lib.sh: drop_dial_port`, because the block runs as a separate `sh -c` without the library.
- The eUICC sweep skips Sierra (`1199:*`) completely: on EM9190 a CCHO probe wedged the SIM
  subsystem (subscriber timeout) until the card was physically re-seated, not even a power cycle
  helped (2026-08-18). Sierra exposes the eUICC over QMI/MBIM, not AT.
- The sweep is pointless while a physical SIM slot is active: the modem has one channel to the card,
  ISD-R is unreachable and CCHO is silent on every port. The report says so instead of implying "no
  eUICC" (FM350 with a soldered eUICC, 2026-08-30).
- The three expensive eSIM steps (60+90+60 s, about a third of the budget) are skipped when there is
  no path to the chip: no lpac, AT transport with no tty at all, or a live ModemManager connection
  (reading the eUICC takes the channel from MM and drops the link). A user with two T99W175 once
  decided the report had hung exactly here.
- When the netifd dialer (gcom, proto xmm/atc) is working on the polling port (`at_dialer_busy`),
  AT polling is skipped: gcom does not use our queue, answers get stolen in both directions and
  arrive shifted by one command, which produced false verdicts (phantom cell lock on L850,
  2026-08-09). The fact itself is reported: the interface is in a redial loop.

### Timeouts: run, cap, at

- busybox has no `timeout`. A construct like `timeout N cmd || echo hangs` prints "hangs" on every
  system. `run` (with a header) and `cap` (without one, for several probes inside a verdict) use the
  "background + kill -9" pair. Without a bound, `sms_tool` on a busy/silent port hangs ~35 s and
  `mmcli` on a half-dead MM hangs forever; a broken modem must not stop the whole collection.
- `at` goes through `at_query`, which takes `at_lock`. Without the queue the report competed with
  the metrics poller and answers shifted between commands: in a live report (T99W175, issue #8) the
  answer to `ATI` appeared under `AT+CGDCONT?` and `AT+CGMM` under `AT+CEREG?`. A shifted report is
  worse than none. `run 12` stays as an outer safety net around `at_query ... 8`.
- MM modem indices come from `mmcli -L`, never a guessed `-m 0`: the index changes on every MM
  restart and `-m 0` on a dead bus hangs until the timeout.
- `mm-inhibit.sh` has no `status` command; an unknown argument falls into its `*)` branch, which is
  the daemon loop (`while :; sleep 15`). The report reads pid files and uci flags directly instead.

### Session draft ($SESS)

Sections that interpret what was already collected (the `+CME ERROR` decoder, the CFUN fallback in
`radio_verdict`, `fcclock_verdict`) read `$SESS`, a copy every `run` appends to. They used to read
`$OUT`, which is still being written in `start` mode and not written at all in `run` mode, so they
analysed a week-old report (audit 2026-09-12). `+CME ERROR` codes are decoded via `cme.sh: cme_text`.

### Summary block (_sum_verdict)

The report used to start with a package list; people could not tell what was wrong and forwarded
the whole dump. The top now has router, firmware, package version, modem, operator, interface and
one verdict. Rule: only cheap already-available sources (uci, ubus, sysfs, watchdog state files),
no AT command and no port access. Order of checks: no modem on the bus (or a modem-like USB device
with a vendor interface and no driver), no data channel (more important than "no address": advice
about APN is wrong when the protocol has nothing to attach to - issue #16), interface `pending` (it
waits up to 20 s and says the report caught a dial in progress), protocol handler not installed
(`proto_pkg` maps proto to package), no address, no default route, watchdog says down, DNS broken.

### Secrets

uci dumps mask `token|secret|pass|psk` and `*_key`/`*.key`; the network dump drops passwords, PSKs,
PIN/PUK. The report still contains IMEI/IMSI/ICCID/EID and says so at the top.

## collect.sh: verdict sections

Each verdict explains one failure class that looked like "the modem does not work" in real reports.

### Uplink: who holds the internet (uplink_verdict)

- Lists wan-zone uplinks by metric, then the live default route. The watchdog penalises metrics in
  the kernel table without touching uci, so config order and live order differ by design.
- Address and device of qmi/dhcp modems often live on the dynamic child `<iface>_4` while the parent
  is empty; both are queried (same as `health.sh: iface_dev`).
- jsonfilter needs bracket syntax for hyphenated keys: `@["ipv4-address"]`; dotted notation silently
  returns nothing.
- "Has an address" is not "can carry traffic": a link without a gateway (DHCP gave no router option)
  looked healthy and people wondered why priority would not switch to it (WH3000 Pro, 2026-08-25).
- The probe pings with `-I <dev>` (SO_BINDTODEVICE). A plain ping from the router takes any route
  and hid the failure: in one case a Wi-Fi STA uplink at metric 10 attached to an AP without
  internet and held the default over four working modems for seven minutes.
- With NSA (`access-technologies.value[2] = 5gnr`) a broken NR leg gives exactly "address but no
  packets"; the verdict suggests 4G mode or disabling NR bands.

### Modem's own subnet 192.168.225.0/24 (modem_subnet_verdict)

Quectel RM520N and relatives keep an internal bridge `192.168.225.1/24`. An interface address from
there means passthrough/bridge is off and the router sits behind the modem's NAT: "some sites open,
some do not", broken inbound. Diagnosis used to go into DNS/MTU/TTL. A LAN on 192.168.225.x collides.

### DNS (dns_verdict)

- DNS-rebind protection drops answers with private addresses. When it hits `dns.msftncsi.com` /
  `msftconnecttest.com`, every Windows client shows "No internet access" permanently while sites
  work; for Android it is `connectivitycheck.gstatic.com`. Several "no internet" reports had a fully
  online router. The cure is `rebind_domain` exceptions.
- dnsmasq changed its rebind log format in OpenWrt 25.12.5; the strict `s/.*detected: *//` stopped
  matching and three reports printed the warning without names. Names are now extracted with a loose
  pattern, falling back to raw log lines.
- Multi-modem routers: `resolv.conf.auto` lists resolvers of all carriers. A query to a foreign
  resolver leaves through another uplink's default and is dropped: resolving works every other time.
  netifd writes `# Interface <name>` above each group, which is how ownership is attributed.
- Servers from the interface `dns` option ("Fallback DNS") that do not answer are flagged: under a
  carrier whitelist 8.8.8.8/1.1.1.1 are blocked and dnsmasq keeps using them; 77.88.8.8/77.88.8.1
  are suggested.

### QMI frame format (qmi_format_verdict)

`connected`, address, route, but no traffic: qmi_wwan expects raw-ip and the firmware sends 802.3 (or
the reverse); RX is silently dropped, TX grows, RX stays 0. SIM7100E (2026-08-01): `raw_ip=Y` with
modem `802-3`; `AT+CFUN=1,1` brought raw_ip back to N, matching the firmware. `option dhcp 0` does
not help. The mismatch verdict is printed only when the interface is up: raw_ip defaults to N and
netifd sets Y while dialling, so on a never-connected modem "N vs raw-ip" is just unset (it misled
the FN990A28 case, where the real cause was a SIM in illegal state). For cdc_mbim nodes qmicli
needs `--device-open-mbim`.

### TTL override (ttl_verdict)

Checks live nft tables, not config: `inet modem5g_ttl` and, with flow offloading on,
`netdev modem5g_ttl_dev` (offloaded flows bypass inet hooks and keep the original TTL). Zero hits
with the override on is evidence too. Typical symptom when missing: carrier tethering block (strict
on Yota) looks like "session and address, no traffic".

### APN vs. database (apn_verdict)

Wrong APN is the most common "registered but no IP". Auto-selection does not overwrite an APN once
it ran for this SIM (`apn_imsi` stamp), so a typo survives forever (APN `tt` instead of `m.tinkoff`,
2026-08-05). The verdict compares the interface APN with `providers.tsv` for the PLMN.

### wan zone and NAT (fw_zone_verdict)

The router itself is online but the LAN is not. Older versions broke the zone: `uci add_list` did not
split `option network 'wan wan6'` and created one list item `'wan wan6'`, so the real wan was not in
the zone and NAT did not apply. The uci-defaults script unglues it. Modem interfaces missing from the
zone are listed.

### Admin page access (webstack_verdict, policyrouting_verdict)

Two reports had the same symptom ("internet works, LuCI does not answer": multi-modem + mwan3 after
reboot; router after the setup wizard), and by the time the report was taken the state was gone.

- LuCI login answers HTTP 403; `403 + html` is normal, a failure is a timeout, empty answer or 500.
- busybox wget does not save the body of an error response (rc=8, 0 bytes with a live LuCI), so the
  check uses the exit code and duration: rc 0 = 200, rc 8 = the 403 login page = LuCI alive.
- Stock policy rules are three (0 local, 32766 main, 32767 default). Extra rules mean policy routing;
  the router's replies may go to an uplink table with no route back to the LAN. Orphan `lookup 25x`
  rules of a removed mwan3 stay active until reboot.
- `lan` in the wan zone (input REJECT) cuts the admin page off.
- Uncommitted uci changes are printed as "landmines": deltas in `/tmp/.uci` get applied by someone
  else's commit hours later (a stuck `lan.ipaddr` looked like "the router broke by itself").

### netifd crashes (netifd_crash_verdict)

Core dumps in /tmp mean netifd crashed; each crash restarts all networking. Known trigger on 25.12
(netifd 2026-02-26, fixed upstream 2026-07): taking down an interface whose address lives on a
dynamic child `<iface>_4/_6` (qmi, mbim) frees the child while still in use. mbimp no longer uses
such children.

### USB power and stability (usb_flap_verdict)

- Symptom: the modem is detected, SIM reads, MM even reports connected, then the device leaves the
  bus. The same DW5821e worked for hours on a SuperSpeed adapter and dropped 10 s after connect on a
  high-speed one (peak current while transmitting). 480 Mbit/s = USB 2.0 (500 mA), 5000/10000 =
  USB 3.x (900 mA).
- dmesg vs logread: whichever has more `USB disconnect` lines is used (logread may have rotated).
- Neighbouring devices are counted too: a Compal on 2-1.3 re-enumerated every 1.5 s (80+/min) while
  the active Fibocom was fine; the report only showed "no modem".
- Switching out of mass-storage mode is not a power problem: each switch is a disconnect plus new
  enumeration (ZTE 19d2:1405, 2026-09-08). Sign: interface 0 enumerated as USB mass storage.
- MediaTek modems (FM350, RW350, 0e8d:7127) pass through "MT65xx Preloader" (0e8d:2000) on every
  power-up: one disconnect per start (RW350-GL on Radxa Cubie A5E, 2026-09-17). Preloader within the
  first 120 s of kernel uptime is a normal start; later it means the module rebooted itself
  (power sag, overheating or firmware crash), unless our healing reset it at that time.
- Drop timeline: if `poll of <port> is stuck` precedes most drops (within 120 s), suspect the metric
  AT commands (RW350-GL, 2026-09-03: two drops 16 s and 22 s after a stalled poll). Drops within
  30 s after `healing <iface>: rebooting the module|power-cycling` are our own watchdog.
- Non-enumerating device (`device descriptor read ... error -62/-71`, `not accepting address`,
  `unable to enumerate`, often a fall to full-speed/OHCI) is physical: power at start, cable without
  data lines, dead module (Cudy TR1200, 2026-08-19).
- A dead xHCI controller is checked first and is not a power problem: FM350 in RNDIS on BPI-R4 Lite
  (2026-07-30) - `rndis_host: NETDEV WATCHDOG: transmit queue 0 timed out`, then
  `xHCI host not responding to stop endpoint command`, `Host halt failed, -110`, `HC died`, and all
  bus devices vanished at once until reboot, with no -71/over-current traces. A brownout drops one
  device and leaves -71. On boards with one controller for all ports (BPI-R4) changing the port does
  not help. The old verdict recommended a power supply here.
- Snapdragon X20 (T77W968/DW5821e, 413c:81d7/81e0, 0489:e0b4/e0b5): drops on CA add/remove on
  second-hand modules are often caused by edited carrier files (NV 00028874, removed carrier policy).

### Unconfigured USB device (usb_unconfigured_verdict)

Two FM350 and two Sierra EM7565 on one xhci-mtk (2026-08-02): lsusb shows four, the app three, and
which one is missing depends on enumeration order. Kernel: `Not enough host controller resources for
new device state`, `can't set config #1, error -12` (Configure Endpoint returned RESOURCE_ERROR: the
controller ran out of endpoints). Without a configuration there are no interfaces, no drivers, no
/dev nodes, so `listmodems.sh` sees nothing. The section reads `bConfigurationValue` from sysfs and
prints interface counts per device. FM350 with RNDIS costs 10 interfaces (7 serial), MBIM costs 2;
different hubs or buses of one controller do not split the budget; FM350 compositions 40 and 41 are
equally hungry. If our `mm_recover_missing` rebind touched the device (`*.rebindfail` /
`mmrebind_*` markers), the likely trace is `config #1 error -71` after unbind/bind; only a full
power-off cures it, and the QMI protocol avoids future rebinds.

### usb_modeswitch config reset (usbmode_verdict)

`/etc/usb-mode.json` has `config: 0` entries for modems that already arrive in a working composition
(DW5821e/T77W968). The kernel unbinds the data driver (`usbmode ... sets config #0`, then
`cdc_mbim ... unregister`) and the modem keeps only AT ports (Cudy TR3000, 2026-08-26). The app
removes such rules (`usbmode-fix.sh`). Lost data channel alone is not proof of this: in issue #16
(T99W175 on BPI-R4 Lite) the channel was stolen by usb-serial and the old verdict blamed
usb_modeswitch. The network interface must be searched in sysfs, not in the `net[]` field of the
modem list (only HiLink sticks and phones fill it) - an RNDIS RW350-GL (eth2 on rndis_host) was
declared broken (2026-09-03).

### Fastboot / bootloader (fastboot_verdict)

DW5821e in the M.2 slot of Huasifei WH3000 Pro starts in fastboot after every reboot: pin 67 is tied
to ground on the board. Known bootloader IDs: 413c:81e1 (DW5821e, working 81e0), 05c6:9008 (EDL,
never touched), 1199:9070. 413c:81e6 is not a bootloader but a working DW5829e (81e4 is its eSIM
variant). Unknown bootloaders are detected by a single driverless vendor interface with subclass 42
protocol 03. Detection uses sysfs, not lsusb: usbutils is usually absent and the error was swallowed
(WH3000 Pro + DW5821e-eSIM, 2026-08-18). Since 2.4.27 the app sends the fastboot "continue" over
usb-serial itself (`fastboot_rescue`, at most once a minute, 3 attempts).

### Radio power, W_DISABLE#, FCC lock (power_state_verdict, radio_verdict, fcclock_verdict)

- Radio off (CFUN=0/4) defeats every protocol (mbim/qmi time out, MM stays disabled); in raw AT
  output it is one easy-to-miss line (DW5821e "stuck at connecting" with radio off).
- MM `power-state: low` makes netifd loop on `couldn't enable the modem: Invalid transition`
  (DW5821e on Radxa ROCK 5T). That is a consequence, not the cause.
- Hardware radio switch: the firmware reports `hardware radio switch is OFF` to MM (visible only with
  `--log-level=INFO`). Writes all fail (MBIM OperationNotAllowed, QMI FwWriteFailed, MM Invalid
  transition) while reads look fine (CFUN=1, operating mode online). Same ROCK 5T case: a USB hub
  shared the 500 mA EHCI port, the modem peaks over 1 A, and the adapter pulled W_DISABLE#.
- Foxconn/Thales T99W373/MV32-W can be asked directly: `AT+RFPIN_STATUS?` (or `AT^RFPIN_STATUS?`)
  answers `RF HW key is pull up` (radio allowed) or `pull down` (pin held). Works without MM.
- No AT port (05c6:9025 family in QMI/MBIM composition has no tty at all): `radio_verdict` takes
  power-state, state and state-failed-reason from MM instead of saying "nothing to check with"
  (two T99W175, 2026-07-30).
- CFUN=0 is often a leftover of an aborted dial (the protocol turns the radio off on teardown).
- CFUN=5 is factory test mode: Quectel `AT+QRFTESTMODE?` = 1; Foxconn/Dell `AT+FTM?` ->
  `Device is in: 1, FTM`. T77W968/DW5821e: `at^nv=2497,1,"01"` then `AT+CFUN=1,1` (alternative
  `AT^qtuner_enable=0`); the Dell firmware updater on a PC re-arms FTM. Late eSIM batches often need
  a QPST NV/EFS restore.
- CFUN=7 on Quectel: firmware does not match EFS/QCN (cross-revision flash) or PA failure; restore a
  QCN of the matching version. Foxconn T99W373/MV32-W often arrives so; only T99W373_Recovery (full
  restore over ADB) cures it.
- FCC lock under MM: power-state low, stuck in enabling/disabled, netifd loops on Invalid transition.
  MM ships unlock scripts disabled (`/usr/share/ModemManager/fcc-unlock.available.d`, active ones
  are symlinks in `/etc/ModemManager/fcc-unlock.d`). DW5821e (413c:81d7) on ROCK 5T was "dead" for a
  month for want of two symlinks. Stock script `105b` only looks for an MBIM port and sends nothing
  in QMI composition, so for 413c:81d7/81e0/81e4/81e6/81d8 and 0489:e0b4/e0b5 the package's own
  `/usr/share/5gmodem/fcc-unlock.sh` is used (linked by uci-defaults `46-5gmodem-fcc-unlock.sh`).
  That family's lock is not readable over AT; it is lifted by QMI "Foxconn set FCC authentication".
- Fibocom FCC lock: `AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?`. Mode 1 = unlock once,
  mode 2 = every power-on; state 0 = locked. Symptoms: `AT+CFUN=1` -> `+CME ERROR: 0`/phone failure.
  Unlock: `AT+GTFCCLOCKGEN` challenge, code = first 8 hex digits of SHA256 over
  `<challenge as 8 hex digits>` + vendor hash (Lenovo: `3df8c719`) written in decimal,
  `AT+GTFCCLOCKVER=<code>`; permanent removal `AT+GTFCCLOCKMODE=0` + replug. Reference: ModemManager
  `data/dispatcher-fcc-unlock/14c3`. Seen on Lenovo FM350-GL. The app deliberately does not do this.

### Why the modem does not connect (mm_fail_verdict, at_conn_verdict)

- MM's `state-failed-reason` is one line inside a 200-line `mmcli -K` dump per modem and decides the
  case (`sim-missing` = card/tray, not the app). Two T99W175: the second failed on sim-missing while
  the analysis went into compositions and power. All modems are covered, not only the active one.
- `esim-without-profiles`: an active empty eSIM slot makes MM fail the modem and never register;
  looks like an endless network search while a physical SIM sits in the other slot (MV31-W on
  WH3000 Pro, 2026-08-07).
- `connected` in MM but interface down with `DISCONNECT_FAILED`: MM keeps a dead bearer and refuses
  new connects ("Operation not allowed while modem is connected"); only `mmcli -m N --reset` clears it.
- Without MM, or with a modem not under MM (fibocom, atc, xmm), the cause is derived from AT and
  queried again (the network state changes during the MM section). A lite build without MM used to
  print "not applicable" while `+CEREG stat 2, +CGATT 0, +CSQ 5` showed disconnected antennas
  (WH3000 Pro, 2026-08-02).
- `+CEREG` parsing allows spaces after commas: Altair ALT3800 (NTLM-500) answers
  `+CEREG: 2, 1, 3339, 08671C0C, 7` (2026-09-10).
- Signal from `+CSQ` only: 99 = unknown, otherwise dBm = -113 + 2*rssi. On FM350 CSQ is the honest
  one (RSRP is under-reported). Antennas are mentioned only when not registered.
- SIM in "illegal": the qmi protocol power-cycles the slot every ~8 s, so a card needing 1-2 minutes
  to initialise never comes up; only a module reboot plus waiting clears it. Checked only while there
  is no address and `+CGATT` is not 1 (an old log line would otherwise flag a working modem); both
  the interface error and the log are checked because the protocol clears the error when it gives up.
- Registered and attached with an address, but the watchdog says down: the dial is fine, packets
  are lost further on (FM350 on MegaFon, 2026-09-08: only carrier DNS passed). The section must not
  contradict the top verdict.
- `+COPS: 2` = deregistered by command; the modem will not search until `AT+COPS=0`. Left by aborted
  xmm/gcom dial loops that send COPS=2 (L850 on MTS, 2026-08-09).
- Registered but `+CGATT: 0`: APN or PDP type; some modules refuse a plain IPV4 context.

### Control channel conflicts (proxy_verdict, mbim_verdict)

- Two interfaces dialling the same modem (e.g. firmware `wwan1` on umbim plus ours on MM) connect and
  disconnect each other every 20-40 s (T99W175 + Verizon, 2026-09-16). Matching is by devpath/device/
  modem_path and by the device's own `/dev` nodes.
- OpenWrt's stock mbim uses umbim directly without a proxy; a foreign mbim-proxy/qmi-proxy on the
  same cdc-wdm takes the device: "mbim message timeout / Failed to read modem caps".
- mbim on a cdc-wdm created by qmi_wwan: umbim sends MBIM frames to a QMI channel and times out
  forever (T99W175 in 05c6:9025 on Netcore N60 Pro, 2026-08-17).
- `PIN_FAILED`: umbim fails setup when the modem reports PIN2 required (pintype 3, service code for
  FDN/limits, irrelevant for data) and calls `proto_block_restart`.
- `Failed to attach to network` / mbim timeout: on DW5821e/T77W968 umbim cannot bring up the PDP
  context; ModemManager works with the same modem and SIM.

### Mass storage and missing data channel (stick_verdict, usbcomp_verdict)

- Sticks in mass-storage mode have no tty/cdc-wdm/net. A modem in the middle of a USB reset also has
  no nodes for a moment (T99W175 was called "stuck mass storage"), so a device present in
  `listmodems.sh` is skipped.
- Output is printed line by line (`printf '%s\n' "$var"`), never unquoted: word splitting put the
  path and vid:pid on different lines (audit 2026-09-12).
- AT ports present, no cdc-wdm and no net device. Two causes:
  1. Composition without a data channel. Quectel `AT+QCFG="usbnet"`: 0 (NDIS/QMI) and 2 (MBIM)
     carry a channel, 1 (ECM) and 3 (RNDIS) do not; nothing changes, not even the port list, until
     `AT+CFUN=1,1` or a power cycle. SimCom `AT+CUSBPIDSWITCH?` must be 9001
     (`AT+CUSBPIDSWITCH=9001,1,1`). Other vendors: check `AT+CLAC`.
  2. Greedy usb-serial: the data interface is vendor class `ff` like the ports, and a dynamic
     `new_id` hands it to usb-serial after a re-enumeration (issue #16, T99W175 05c6:9025 on
     BPI-R4 Lite: cdc-wdm0 up at 08:30:51, after re-enumeration at 08:31:38 all five ff interfaces
     went to usbserial_generic). Distinguished via `usbports.sh dataif <vid> <pid>`; the interface
     name is matched by mask because the configuration number is not always 1 (Compal uses 3).
     usb-serial has no `remove_id`; the app rescues the interface (`usbports.sh rescue`).
- ECM/RNDIS modules have a net device without cdc-wdm (profile 2c7c:6005); that is normal.
- AT port binding (05c6:9025/90d5/90d6 need manual `new_id`): the same composition written into
  `new_id` of two different drivers makes the kernel hand out interfaces at random and every ttyUSB
  answers with I/O errors (measured on Compal), so the app leaves an existing binding alone.

### Other verdicts and sections

- Ports: with xmm/atc the dial goes over the AT tty for the whole session, so the metrics and SMS
  ports must differ from it; `resolve` excludes the dial port and rewrites a pinned one, which looks
  like "my port setting keeps coming back" (L860-GL, 2026-09-06).
- Device blacklist (`ignore_vidpid`): a blacklisted modem looks like "the modem is gone"; one user
  sent two reports without noticing (2026-09-04).
- Sierra image/PRI (`AT!IMPREF?`): preferred vs current mismatch (`fw version mismatch`,
  `carrier name mismatch`) puts the modem into low power silently. EM9190 (August 2026): an
  interrupted update switched preferred but never flashed the image; `AT!IMPREF="ATT"` revived it.
  EM7345 (1199:a001) is an Intel XMM7160 with a Sierra label: all `!` commands answer ERROR, so the
  verdict is driven by the answer, not by the vendor ID.
- Quectel full build (`AT+QGMR?`, answered with or without the `+QGMR:` prefix):
  RM520NGLAAR01A06M4G_01.001.01.001 is clean; the R03 branch and 200/201/30x versions carry a
  Russia/Iran block in the binary: LIMSRV, endless search with good signal.
- HiLink sticks have no tty/cdc-wdm; the report queries their web API with the poller's code
  (ZTE 19d2:1405, 2026-09-08). Empty `rsrp`/`csq` on ZTE means no web login (`web_pass`, default
  `admin`); without a session only public fields are filled.
- Temperature >= 110 C is a false reading; Foxconn T99W640 has a firmware fault where it thinks it
  overheats and drops registration every ~20 s.
- qmicli built against a different libqmi fails with `Error relocating`: every QMI read fails until
  qmi-utils and libqmi come from the same feed.
- eSIM transport: SM-DP+ downloads need HTTPS (ca-bundle, correct time, lpac HTTP backend) while the
  profile list is pure APDU. The APDU bridge needs GNU wget (`--method`, `--body-file`, `-S`);
  busybox wget printed its help as the "transport failed" reason (FM350, 2026-08-06), so busybox falls
  back to curl, but curl with mbedTLS cannot verify some GSMA CI chains. The eUICC port floats
  between re-enumerations (FM350 ttyUSB1/ttyUSB3), hence the CCHO sweep over every tty.
- IPv6 ping uses a literal (`2a02:6b8::feed:0ff`, the v6 pair of 77.88.8.8): DNS is often filtered
  too, and `ipv6-internet.yandex.net` does not resolve.
- Modem interfaces section lists section-referenced and all modem interfaces plus `_4/_6` children:
  a section may point to a foreign interface while its own is orphaned, and without children "up with
  address" cannot be told from "up, no DHCP lease".
- Antenna ports: RSRP around -140 means an unconnected pigtail.
- Band management path: Thales MV31-W and a Compal prototype share 05c6:90d5 with different control
  paths, hence `bands.sh mgmtinfo`.

## Modem page (5gdebug.js)

- Modem info is filled after render from the cached snapshot (`5gmodem.sh cached`), not a full
  `json` poll (8 s on LT300 during which the page did not render). `Device not found` shows a
  "no modem" note; `busy` is transient and ignored.
- APN hint by operator is fetched in the background (`modemswitch.sh apnfor`, same code as
  auto-setup, SIM code first). The page used to have its own APN table (`apnForOperator`) that only
  knew operator names; for an MVNO the name comes from the host network, so it showed the host's APN.
- Profile cards (sections `5gmodem.m_*`) are shown on top because invisible stale profiles caused
  real failures: a removed Telit's section kept claiming an interface name and a Compal picked up
  its proto=qmi on MBIM hardware. Deleting a profile also deletes its interface; an orphan interface
  once fought another modem for `/dev/cdc-wdm0`.
- Cards are reloaded after interface re-creation; the block renders once and is not polled.
- Power shortage (powercheck.sh): the modem comes up partially and looks like a software bug; the
  whole card is tinted.
- MM visibility marker is shown only when it disagrees with the protocol (MM would steal the
  channel), and the "ghost" icon only for `mm_exclude === '1'` strictly (a "non-zero" check flagged
  modems without the flag, 2026-07-31).
- PDP type is stored per protocol (fibocom/atc `IPV4V6`, qmi/mbim `ipv4v6`, see `mkiface.sh`) and
  displayed normalised. Option names: xmm/atc `pdp` (IP/IPV4V6), modemmanager `iptype`, fibocom
  `pdptype` upper case, kernel protos `pdptype` lower case (`mkiface.sh: set_pdp_opt`). Default for
  new interfaces is IPv4: dual stack broke dialling on Quectel EC21. Dual stack under MM also needs
  `init_epsbearer`, otherwise the attach is IPv4-only.
- PDP auth (PAP/CHAP) for MVNOs (Ekomobile: APN plus login/password, 2026-08-16): modemmanager reads
  `allowedauth`, fibocom/qmi/mbim read `auth`.
- APN and PDP type fields used to be display-only ("Manual + own APN + Save" changed nothing and the
  hint overwrote the value, issue #12); in manual mode they now write to the live interface and the
  hint never touches the field. An empty APN is sent to `mkiface.sh` as `-` (explicitly none),
  otherwise it keeps the previous APN.
- Protocol list is built from installed `protocol/<name>.js` handlers. `widgets.NetworkSelect` was
  replaced by a plain uci list: it requires LuCI handlers of every interface proto, and a missing
  `luci-proto-3g/wwan` made the whole page fail with 404. `fibocom` is listed (FM350 has no
  cdc-wdm, so mbim/qmi/MM do not apply); `qmiraw` is shown only next to `qmi` (same hardware, static
  address from QMI instead of a DHCP child).
- Choosing ModemManager clears "Hide from ModemManager" immediately (both together leave the
  interface without IP); the reverse is not automatic.
- HiLink and phones (`kind=tether`) have no netifd dial: no protocol/APN/PDP/DNS fields, a separate
  "HiLink DHCP" button (`mkhilink`). HiLink roaming is `RoamAutoConnectEnable` in
  `/api/dialup/connection`, written through the modem API.
- Roaming for other modems is the netifd option `network.<iface>.allow_roaming` (read by mbim,
  modemmanager and fibocom); hidden for qmi, which has no such mechanism. FM350 has no AT roaming
  switch, so fibocom simply refuses to connect in roaming.
- AT under ModemManager is gated by `quirks.sh: mm_at_allowed` (T77W968/DW5821e dropped the link on
  every tab open); a checkbox forces it. A separate "no background AT" switch exists for firmwares
  where AT next to data traffic hangs the session (Quectel RM551E-GL, issue #28).
- Toggle options save instantly via granted scripts (`setopt.sh`, `esim.sh setshow`,
  `mm-inhibit.sh`), not `uci.apply()`: apply would also commit half-edited structural fields and
  re-create the interface. The eSIM tab override goes through the backend because `uci.add` of a
  named `m_<path>` section did not stick when the section did not exist yet.
- The LED level block is outside the form: saving the form rewrites hidden port fields.
- `ui.Dropdown` emits `cbi-dropdown-change`, not native `change`. `RichListValue` is used for all
  lists, falling back to `ListValue` on old LuCI. Nested arrays in `E()` children are stringified
  (`[object HTMLBRElement]`), so children are built flat. Sort comparators must return numbers.
- "Forget disconnected modems" is explicit: a modem disappears for a minute on `AT+CFUN=1,1`, and
  same-port swaps are handled by `modemswitch.sh: swap_cleanup`. Identical modems swapped between
  ports are detected by IMEI and only warned about.

### Hidden port fields must survive save

`network`, `device` and `at_port` depend on `auto_port=0`. LuCI calls `remove()` on options whose
dependencies are not met, so saving the page with auto-detection on erased `device` and rewrote
`at_port` to the first port (ttyUSB0, no AT) and metrics vanished; `network` holds the managed
interface name. These options override `remove` with a no-op; the values are set by `resolve`.
A second `o.remove` on `at_port` once overrode the no-op and left `sms.{readport,sendport,ussdport,
atport}` mirrors pointing to the old port (audit 2026-09-12). `at_port.write` mirrors into those four
sms fields.

## AT console (sendat.js)

- Commands go through `atcmd.sh`, not `sms_tool`: the ACL used to allow `exec` of `/usr/bin/sms_tool`
  with any arguments (`send`, `delete all`, foreign `/dev/*`). Port, command form and port ownership
  are now checked on the router. An explicit timeout argument is passed: without it the script waits
  up to 25 s for the port queue while the browser drops the ubus call at 20 s (audit 2026-09-12).
- Chaining (V.250/27.007): `AT` once at the start, stripped from following extended commands
  (`+ ^ $ * #`), so `AT+CPBS="ON";AT+CNUM` becomes `AT+CPBS="ON";+CNUM` (otherwise "No response"/
  "NO CARRIER"). Basic commands (ATI, ATZ) keep it.
- Template files (`etc/5gmodem/modem/atcmmds/`): `## Section`, `# description` directly above the
  command, command line sent as is, blank line resets a pending description. Legacy formats
  `Name ➜ AT` (`➜`, `→`, `->`) and `Name;AT` are still read so existing `.user` files keep working.
- Family template per active modem: exact vid:pid, then vendor, then model. 05c6:90d5/9025 are
  ambiguous (Foxconn T99W175 or Compal prototype) and are told apart by model, like `iscompal.sh`.
  1e2d:00b3/00b7/00b8/00b9 are stock Thales T99W175/MV31-W compositions (`AT^CUSTOMER=14/16/33`),
  not Compal. EM7345 (1199:a001, Intel XMM7160) has its own file: Sierra `!` commands answer ERROR
  (`AT!ENTERCND="A710"`), and the L850/L860 xmm file is Fibocom-flavoured. File choice is remembered
  per vid:pid in localStorage.
- Dangerous commands ask for confirmation: `AT+QPCIE="adb",1` on the PCIe RM520N kills all USB ports
  permanently (recovery only via EDL), composition changes (usbcfg, data_interface, pcie/mode) and
  fastboot can make the modem invisible. Reads such as `AT+QCFG="usbnet"` without a value are not
  flagged; write patterns require a comma with an argument.
- Fallback port for MM modems: their section has no `at_port` on purpose; the second AT tty from
  `listmodems` is used (the first is usually MM's). Read after `uci.load`, otherwise `active_modem`
  was undefined.
- UI traps fixed in the audit of 2026-09-12: an empty placeholder selection erased the typed command;
  a `mousedown` handler overwrote the input when merely opening the list; bare Delete cleared the
  whole field (now only with Ctrl/Shift).

## 5gtop

Terminal version of the Network page for weak routers (MT7628) where LuCI is slow or does not fit in
RAM. It uses the same backends (`5gmodem.sh cached`, `netpri.sh`, `speedtest.sh`, `esim.sh`,
`smsbridge.sh`, `simslot.sh`) and adds no AT commands.

- Polling is slow (10-13 s for `5gmodem.sh json` on a weak router with a modem that rejects long AT
  chains), so it runs in a background process. `cached` is used so only one process touches the port
  (lock in `5gmodem.sh`); with the web page open both used to triple the poll time.
- No full redraws: frames are printed once, values are rewritten in place. Spaces are painted
  cells and showed as black bars on themed terminals (Tabby), so padding uses `ESC[<n>X` (erase with
  the default background, cursor does not move) plus `ESC[<n>C`. No box-drawing borders for the same
  reason; row count per frame is kept because `draw_*` writes to absolute rows.
- `fit` truncates with `~` and must get plain text only (cutting inside an escape sequence breaks the
  line); colour is applied after.
- Character length: busybox `wc -m` counts bytes; `clen` drops UTF-8 continuation bytes.
  `TOP_ASCII=1` restores `#` bars on non-UTF-8 consoles.
- Width: `stty size` first (the kernel keeps the pty size, ssh updates it), then a CPR query
  (`ESC[6n`), default 60. `tput`/`$COLUMNS` do not work on this busybox. Some builds have no `stty`
  at all (MT7628: `stty: not found`); then neither echo nor canonical mode can be switched off, the
  CPR reply lands on screen, and keys work only after Enter. Explicit width (argument or `COLS`) is
  not recomputed on SIGWINCH. Height only detects the 52x22 Almond LCD terminal (tight layout).
- Every `read` has `-t` except the explicit line input (the loop hung three times before). `read -t 1`
  is also the frame pause; if input is closed it returns instantly, so the loop sleeps itself when an
  iteration ends within the same second (a busy loop froze a weak router). `IFS=` keeps Tab; the
  exit code distinguishes Enter from timeout. `-icanon` is kept for the whole session: between reads
  the line discipline ate 0x7f (Backspace with erase=^?).
- `read_line` returns via the global `_RL`: called through `$( )` it captured the prompt and cursor
  codes, which were then sent to the modem as part of the command.
- `TAB` must be assigned (`TAB=${TAB:-1}`), not only defaulted in `case`: an empty `TAB` broke every
  `tab_id "$TAB"` branch. The modem switch command is `modemswitch.sh switch` (`set` does not exist
  and silently did nothing).
- Modem tabs show only modems present in `listmodems.sh` (sections `m_*` intentionally outlive
  unplugged modems), parsed with jsonfilter: the list is one line and a greedy sed returned only the
  last path.
- Language: English unless `ru` is given as an argument; LuCI/LANG are not consulted.
- SMS: multipart messages are grouped by UDH reference, not time (parts differ by seconds), one
  jsonfilter call per message with several `-e` (6 forks x 15 messages took tens of seconds on
  MT7628). sms_tool 2025.08.x sign-extends code points with low byte >= 0x80 in JSON
  (`ÿffffa0` instead of ` `); the same fix as `readsms.js` is applied. U+FFFD is replaced by
  a space. Missing parts are marked (a full SIM drops tails: 3 of 5 parts at 15/15). SMS are read via
  `smsbridge.sh` (port queue, HiLink over HTTP); the result file is always published, an empty file
  means "no messages" (absence means "still reading").
- eSIM tab is shown only when an eUICC exists, checked once from `esim.sh`'s cache.
- Thermal throttling level is appended to the temperature; Compal RXM-G1 gives no degrees at all,
  only `+CEITHERM` levels 0-3, shown as a word.
- Profiles emit HTML entities for the web (`56.0 &deg;C`); they are decoded, and the unit is appended
  only when missing.

## Telemetry (telemetry.sh)

Writes `/tmp/5gmodem/tele.json`, a flat JSON in the canonical schema (`docs/telemetry.md` at the
repository root), from the existing metrics snapshot; it issues no modem requests. External
consumers (home automation, LCD screens, dashboards) read it instead of calling `5gmodem.sh` over
ssh, which forked a full poll each time. Verbs: `write`, `publish` (MQTT via `mosquitto_pub`),
`discovery` (Home Assistant retain topics), `show`, `tick` (watchdog loop).

- Privacy: no IMEI, IMSI, ICCID or coordinates; phone only with `tele.publish_phone=1`; IP addresses
  only with `tele.publish_ip=1` (the file goes to MQTT brokers with history and is served over HTTP
  without auth; a stream of timestamped addresses is a tunnel/IP log). The country code of the
  external address is always allowed. Cell details (cid/tac/enb, wan_ip, phone, neighbours, CA
  carriers s1..s4) go to a separate local file that nobody publishes.
- "No data = no key", never 0 or -1. Numbers are rounded to nearest and printed with `%.0f`:
  busybox awk `%d` clamps to int32, so a 5G NCI (up to 2^36, Foxconn puts `nr_cell_id` into `cid`)
  became -2147483648 (audit 2026-09-12).
- MNC is a string: the leading zero matters (250-02 vs 250-2).
- Freshness gate: a stale snapshot (modem removed, page closed) showed "signal 67" for a dead modem
  (7 hours stale, 2026-08-20). Stale means modem fields are omitted while the file is still rewritten
  (mtime shows the exporter is alive).
- A fresh snapshot with an empty signal core (port busy during the poll) does not overwrite a
  previous file that had the core: a single port hiccup blanked the consumer's modem card (Almond
  screen, 2026-08-20). Real modem loss shows as the snapshot stamp going stale.
- The metrics collector runs only while the Network page is open (`page_active`, 15 s). With the
  page closed and the snapshot stale, telemetry refreshes it itself through the same collector
  (serialised via LOCKDIR), at most every `tele.refresh` seconds (default 120, 0 disables), bounded
  to 25 s. A full collection is ~1.5 s CPU.
- `rx`/`tx` are rates from counter deltas between writes; the first write after start has none.
  Device change or counter wrap invalidates the point.
- `mode` uses phone-style labels (4G / 4G+ / 5G NSA / 5G SA / 3G / 2G); `band` is the primary
  carrier, `ca` lists active carriers PCC first joined by `+`.
- External IP is queried through the modem interface (`extip.sh`, cached, default 5 min), otherwise
  it would report the neighbouring uplink's address.
- HA discovery publishes address sensors only when addresses are in the file.

## Statistics (stats.sh)

Series for the Statistics tab: `ping` (RTT from the watchdog's state files
`/tmp/5gmodem/health/<iface>`, field `ms`; no own probes), `signal` (percent from the snapshot field
`signal`, already modem-specific, e.g. FM350 uses CSQ), `temp` (from `mtemp`, which arrives as
`38 &deg;C`; L850/XMM have no sensor), and monthly `traffic` accumulators.

- Collection is tied to tab visibility (`show_stats`); a separate "collect" checkbox only confused.
- Ring series: one line `"<uptime_s> <value>"`, trimmed to `RING_MAX` (about 24 h at 60 s). They use
  uptime timestamps, so they are never merged across boots. `down` is written as 0 so gaps are visible.
- Traffic: deltas of device counters into `<year-month> rx tx`. A counter that went down (reboot,
  interface re-creation) only resets the base. Monthly totals are monotonic, so merging two sources
  is "take the larger value per month".
- Traffic key is the SIM ICCID, not the interface: the carrier bills per SIM, and per-interface keys
  mixed cards after a SIM swap. Without an identified SIM it falls back to the interface. The snapshot
  field is `operator_name` (`operator` does not exist; the operator was always empty, 2026-08-07); the
  operator is remembered per card because the snapshot does not always carry it. Label: operator +
  number, or the full ICCID when the card has no `AT+CNUM`.
- Signal series cover all modems keyed by modem section, labelled by alias or model; series started
  in dBm by an older version are restarted (percent and dBm do not share a scale).
- Storage: `/tmp/5gmodem/stats/` is the working copy. With `persist=1` monthly totals are flushed
  hourly to `/etc/5gmodem/stats/` or a custom path (`stats.path`, e.g. a USB stick). A custom path
  must be on a mounted filesystem, not just an existing directory: after unplugging, the mount point
  is a plain directory on internal flash and writes "succeed" while filling the flash. While it is
  unavailable the fallback `/etc/5gmodem/stats` is used and merged back when the stick returns
  (before the first write, so the stick's totals are not overwritten). Ring series go only to a
  removable path, never to internal flash.
- SIM labels are persisted too (after reboot a removed card showed as raw `sim-8970...`, 2026-08-09),
  only on real change, and never when persist is off: `_pdir_now` does mkdir plus a write probe, and
  `_label` runs every tick, which was a flash write per minute and resurrected a deleted directory
  (audit 2026-09-12). `list` does no write probe either (it runs on every chart refresh).
- `forget <key> <YYYY-MM>` deletes from /tmp, the persistent copy and the custom path; otherwise the
  hourly merge restores it. Disabling persist removes our files from `/etc` but never touches a custom
  directory.
- The custom path from the browser must be absolute and free of spaces/metacharacters (it reaches
  mkdir/cp).
