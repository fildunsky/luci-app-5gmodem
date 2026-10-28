# Health checks and recovery

Several background pieces keep the uplinks alive without a human. `sessionwatch.sh` is the main daemon loop (30 s round, sliced into 5 s steps). Each round it checks the data session of every modem it owns, warms the metrics snapshots, runs the internet watchdog (`health.sh tick`), and does SMS, LED and telemetry housekeeping. `health.sh` probes every uplink through its own device, moves traffic off dead links with a penalty route metric, and climbs a per-modem healing ladder. `qmi-recover.sh` and `reboot_modem.sh` are the reset tools that the ladder and the UI call. `mm-inhibit.sh` keeps ModemManager away from modems that run on kernel protocols (see [modemmanager.md](modemmanager.md)). `buttons.sh` and the hotplug dispatcher bind commands and LEDs to the hardware buttons. `healthform.js` is the shared settings form for the watchdog.

## health.sh: internet watchdog

### Why active probing

The kernel switches traffic only when a link loses its route (ifdown, USB drop, end of lease). A modem that has a valid IP but that the operator no longer lets out looks healthy to the kernel, so traffic keeps flowing into a hole. The only way to see this is to probe through that specific interface.

### Probing (`probe_dev`, `probe_proxy`)

- `ping -I <dev>` uses SO_BINDTODEVICE, the same method mwan3 uses. It goes out through the device even when the default route points elsewhere. Timeouts come from `ping -W`, because busybox has no `timeout`.
- The device is the parent's `l3_device`, otherwise the dynamic child `<iface>_4`. qmi and dhcp modems keep the address on the child, and the parent has no IP (`iface_dev`).
- **Fake-IP targets are skipped.** With clash or ssclash, a domain target resolves into 198.18.0.0/15. Such a ping measures the tunnel or clash's local responder, and the result is wrong both ways. The default numeric targets are never affected.
- **TCP second opinion.** Some operators block ICMP completely, and a false "down" would lead to false healing of a healthy modem. If ping fails, a TCP connect to port 443 of the same numeric targets is tried through the same device. Success means `time_connect > 0`. The HTTP/TLS answer does not matter.
- **Proxy check (`probe_proxy`).** If every direct probe failed but the internet works through the local proxy (clash), at least one link is alive and the direct probes are being cut by the firewall (a VPN killswitch). In that case hardware healing is not allowed, even for a single link. The check is expensive (curl), so it runs only when no link has a live verdict. `-k` is deliberate: the probe needs reachability, not a valid certificate on a bare IP.
- Default targets are `77.88.8.8 1.1.1.1`. 8.8.8.8 is unreachable in some regions, and the Yandex address also stays reachable on operators that use whitelists.

### curl interface if-prefix

`curl --interface "if!<dev>"` must keep the `if!` prefix. Without it, curl treats the argument as either a device name or an address. If binding to the device fails, curl silently binds to the device's IP, and the packet leaves through **another** route with only our source address. Behind NAT that succeeds, so a dead link got an "up" verdict. In a field case (Aug 2026), a cable WAN got a DHCP address without a gateway and had no default route, but the watchdog still reported it as up. `if!` means device only. The same applies to the curl probe in `mm-inhibit.sh: _restore_stolen`.

### Verdict with hysteresis (`judge`)

- A link is "down" after `fail_n` consecutive failures and "up" after `ok_n` consecutive successes. Without hysteresis, the verdict on cellular would flap on every lost packet.
- From `unknown`/`gone`, one success is enough: hysteresis protects against flapping, not against startup.
- "Recovered after a failure" covers down->up, and also gone->up while a ladder is active (a module reboot passes through gone). A fresh link (unknown->up) does not count as a recovery and is not demoted.
- On recovery the ladder file is deleted together with its companion markers (`.mmoff`, `.on2g`, `.srch`). They live for exactly one episode. If they survived it, they would spoil the next episode (Sep 2026 audit).
- State file: `/tmp/5gmodem/health/<iface>` = `state fails oks ms since`. `since` is the uptime of the last state change. The files survive disabling the watchdog. `status` hides stale entries instead of losing history.
- The round timestamp is written in `round`, not only in `tick`. `once` from the page is also a round, and without the timestamp the dots would look stale.

### Round composition (`round`)

- The wan-zone members are computed once per round (they were asked three times before). Uplinks outside the wan zone are included too (`extra_uplink_nets` in lib.sh, for example LAN-DHCP on single-port routers). Otherwise the link that actually carries the default would have no probes or penalties.
- IPv6 companions are not probed separately. Priority and health belong to a link, not to an address family (same rule as `netpri.sh list`).
- **gone vs. removed.** If a link with history in this boot has no device, it becomes `gone` instead of being deleted. The card must survive re-enumeration, which takes tens of seconds during a ladder reboot. `list` hides gone links after a grace period counted from `since`. A parked interface (section present, hardware never seen) gets no state file. Otherwise parked slots would hang as dotted placeholders.
- **No device and no history, but the hardware is on the bus** means a modem that failed to come up, not a parked interface. After a router reboot, a QMI modem with an illegal SIM never exposes an l3 device: netifd power-cycles the SIM and gives up with `autostart=false`. Without a state file, the ladder would never see it (Telit LM960, Aug 2026). In that case a `gone` entry is created, but only if the modem section is really on the bus and the interface is not disabled by the user.
- **Ghost cleanup.** An interface can leave the wan zone for good (HiLink recreates it under another name when the USB composition changes, for example modem5 -> modem4). Its stale "up" file would break the "all links down" guards. Ladder companions (`.mmoff`, `.on2g`, `.srch`) are not ghosts. An earlier cleanup deleted them every round, so "once per episode" events repeated every 30 s and the 12-minute search ceiling was never reached (Sep 2026 audit).

### Settings

- All eleven settings come from one section and are read with a single section snapshot (`uci5g_sec_get`). Measured: `uci get` takes about 3 ms per key (33 ms total), and a snapshot takes one 4 ms spawn. A full-config dump was slower by 30 ms (see lib.sh above `_uci_snap_get`). The writers (`setconf`, `setheal`) use uci directly, after all reads.
- **Disabled "Internet priority" widget disables the whole watchdog.** Otherwise the panel is hidden (`widget_netpri=0`) while the watchdog keeps pinging, applying penalties and healing modems, and the gear that turns it off is hidden with the panel. Rule: no widget, no function.
- `failback`: `restore` (default) gives the recovered link its priority back. `demote` keeps it last until the user moves it (`netpri set/order` clear the mark). With a single link there is nowhere to demote to, so the mark is ignored.
- `manual` (space-separated names): such a link never gets traffic automatically. Its default route always keeps the penalty metric until the user makes it first. The use case is a backup STA uplink to a phone hotspot that is usually not on air.
- `healing` (modems) is **on by default** (decided 19.08.2026). With healing off, common self-healing failures (EP06 SIM illegal, MM-disabled modem) stayed down, and there was nothing to switch it on with, because a dead interface disappears from the uplink list together with its setting. An explicit `0` from the user is respected.
- `heal_wifi` is also **on by default** (24.08.2026), and it is independent of `healing`. A migration removes only a `0` written by the modal itself.
- `setconf` accepts keys only from a whitelist, because the string comes from the browser.
- `setheal <iface> <''|none|ifup|reboot|power>`: an empty value means the default (`reboot`), and `none` means an explicit "do not heal". Without `none`, "do not heal" could not be told apart from "never chosen".

### Locking and rpcd

- **One round at a time** (flock). A background `tick` and a `once` from the page can overlap, and then one round's penalties overwrite the other round's restores (seen live). `tick` skips its turn when the lock is busy.
- `tick` has an internal rate limit with 2 s slack, because the sessionwatch step jitters while the interval is a user setting.
- **`once` returns immediately.** The lock is blocking, and the round goes to the network and AT ports. Waiting for another tick plus our own probes easily exceeds rpcd's 30 s limit. Saving the watchdog settings then ended in "XHR error" even though they were already saved. The round runs in the background with the subshell's file descriptors detached. Without detaching, rpcd waits for EOF on its pipes. The page does not read the result: it re-reads the state on the next poll (Sep 2026 audit).
- `event <iface>` runs an extra round on hotplug ifup/ifdown. Without it, a modem that just came up showed a dotted slot for up to a minute despite a live IP. Healing is not triggered from events. The cooldowns handle that on the regular round.
- When the function is turned off, `once` runs right after saving, so the penalties are removed at once without waiting for a tick.

## health.sh: penalty-route failover (`enforce`)

- **The uci metrics are the user's order, and the watchdog never touches them.** Every `uci commit network` also flushes other packages' uci deltas. A dead link is penalized only in the live routing table: its default route is moved to `base + 1000` (`PEN`), so traffic moves to the next live link by itself. When the link recovers, the metric goes back (automatic failback).
- netifd can reinstall the route with its own metric at any time (redial, lease). Its events are not tracked. `enforce` simply re-applies the penalties after every round, so a wrong route lasts at most one interval.
- **A dead link is never brought down.** The probe is bound to the device and does not need a default route, but the modem's PDP session must stay up, otherwise recovery cannot be detected.
- A penalty is applied only when a live alternative exists. If every link is down, the user's order is left as it is.
- Interfaces with `ip4table` keep their default in their own table (issue #12), so `_rt4_args` adds `table X`. v6 defaults may live in the table of the `<iface>6` / `<iface>_6` companion.
- **`default from <prefix>` is never touched.** These are IPv6 source-specific defaults, one per delegated prefix. An older version dropped the `from` selector and rebuilt each one into the same plain default. The first one succeeded, and the rest failed with "File exists" and ended up at metrics +1..+8 (VOS 5G / SG500M2-X, Sep 2026).
- **Add first, then delete.** A default-route metric must be unique in the table, and `add` fails if another interface already has that metric. Deleting first used to leave the link with no default at all (green, but no internet until reboot).
- **"Already penalized?" compares the metric field, not the line end.** `ip route show` prints a trailing space, so `metric N$` never matched. Traffic moved correctly, but the "no internet, moving traffic" event was written every 30 s (Aug 2026). That is why the patterns use `( |$)`.
- **Missing default route is restored (`_ensure_defaults`, `_nd_gw`).** In a field case (Aug 2026), the modem was up with an address and both cards were green, but the modem had no default route at all, so traffic stayed on Wi-Fi. The probes did not notice, because they are bound to the device. `_move_defaults` moves only existing routes. The route is never invented: it is taken from what netifd knows for the interface or its `_4`/`_6` child (qmi and mbim put address and gateway there). If netifd knows no default, none is added.

### DNS of dead links (`_dns_demote`, `_dns_restore`)

The route moves, but dnsmasq reads its upstreams from `/tmp/resolv.conf.d/resolv.conf.auto`, which netifd writes. The servers of a dead link stay there, often first. Typical failure: a STA uplink lost its beacons, netifd keeps the interface up with an old lease, and the penalty moved traffic to the modem. Every name lookup still goes to the home 192.168.8.1, which is gone. From outside this looks like "no internet" while ping by IP works. With clash's DNS cache on top, the problem lasts even longer.

Rules:

- The file is rebuilt every round, because netifd can rewrite it at any time. The operation is idempotent and costs one file read.
- The list is never left empty. Stale servers are better than none, because dnsmasq would not answer at all.
- The block of a dynamic child (`<iface>_4` / `_6`) belongs to the same link.
- dnsmasq re-reads the file on SIGHUP, so no service restart is needed.
- DNS is demoted only when there is somewhere to switch to.

### Turning the watchdog off (`_off_cleanup`, `_teardown`)

Turning the watchdog off used to stop the ticks but leave the +1000 penalties and the state files in place, so traffic could stay away forever from a link that had recovered long ago. Now every known link gets its uci metric back (exactly what netifd would do on its next event), and the state directory is deleted. Ladder steps already started are atomic (`ifdown; sleep; ifup` in one subshell) and finish by themselves. The cleanup has to run under the lock. The tick/once prologue reaches it without going through `round`, so it fills the `_HDUMP` snapshot itself. Otherwise `iface_dev` would return empty and the penalties would stay.

## health.sh: modem healing ladder (`heal`)

Healing is a separate axis from traffic switching: moving traffic takes seconds and can be undone, while healing a modem takes minutes and touches hardware. The per-modem ceiling `5gmodem.<sec>.heal` sets the highest step: `ifup` (reconnect), `reboot` (+ `AT+CFUN=1,1`), `power` (+ USB port power cycle). The ladder climbs one step per cooldown and repeats the top step once it reaches the ceiling. If the option is not set, the ceiling is `reboot`, because reconnect and module reboot are safe and fix the main self-healing classes. Power cycling must be chosen explicitly.

State: `/tmp/5gmodem/health/<iface>.heal` = `step last_uptime attempts`.

Safeguards:

- `HEAL_COOLDOWN` (default 300 s). A module reboot means tens of seconds of re-enumeration, and retrying more often only causes flapping.
- `HEAL_MAX=6`. After that the ladder stops and waits for a human. An endless ladder on a dead SIM would wear out the modem for nothing.
- Modem not on the bus: no healing, and the attempt does not count. Absence is often temporary.
- Recovery resets the ladder.
- **Truncated ladder file.** `read` on an empty file sets the variables to empty strings, and `[ "" -lt N ]` in busybox is a "bad number" error (exit 2). A `continue` would then freeze healing of that link forever, so empty fields are defaulted (Sep 2026 audit).

### Guards before any step

- **Common cause.** If several links are watched and all of them are down at once, the cause is almost certainly not the modems (dead probe targets, upstream router, regional operator outage). Rebooting every modem would only cause damage. A single link is always healed, because a one-modem router has nothing to compare against.
- **Probes blocked by the firewall** (see `probe_proxy`). Even a single link is not healed. Otherwise, with a VPN killswitch, a one-modem router would climb to `CFUN=1,1` on a healthy modem.
- **SIM absent (`sim_absent`)**, checked before every attempt. HiLink: API `SimStatus` (1 = present, 255/0 = absent). MM: the failed reason in the modem record. AT: a short `CPIN` through the port queue. Only a confident "no card" returns 0. Silence or a busy port does not block healing. With no card, the attempt is not counted and the event is logged once per episode.
- **Operator cut off the traffic.** If the interface **has an address**, the session is established: SIM alive, registered, bearer up. The operator is cutting the traffic (quota used up, zero balance, block). Reboot, USB power cycle and ifup cannot fix that. In one case (Aug 2026) the ladder rebooted a healthy EP06 three times and then kept burning attempts at "Reconnect (3/6)". So the ladder stops completely: the attempt is not counted, the ladder is reset, and the event is logged once. When the address disappears, the mark is cleared. Stuck sessions that keep an address are handled by sessionwatch, which compares the address with the modem.
  - **The address in netifd is not the address on the device.** Protocols with `proto_set_keep 1` (qmiraw and similar) keep the interface "up" after the modem left the bus and came back. ubus still shows the old address, but the netdev is DOWN and empty. Reading only ubus stopped healing forever (EC21, Sep 2026). The address is checked in the kernel on the l3 device.
  - **Exception: fallen back to 2G.** "Address but no traffic" on GSM/EDGE is a radio failure, not a quota limit. LTE was lost and there is practically no data on 2G (SIM7100E stuck overnight on EGSM 900, Aug 2026). A module reboot brings LTE back. The mode comes from a fresh metrics snapshot. A stale snapshot does not change the decision.
- **MM-disabled modem: enable, do not heal.** MM sometimes leaves a modem `disabled` (EP06 after a USB composition change stayed disabled/registered until `mmcli --enable`). The ladder used to spend three heavy steps on what one command fixes. Now, before the ladder, a disabled MM modem gets `mmcli --enable`, and netifd brings the interface up when MM reports the modem. There is no forced ifup here, because MM does not report the modem as available instantly. The attempt is not counted and the ladder does not move. Only one `enable` runs at a time, with a 30 s timeout. On a wedged MM the command never finishes, and without the guard every round would leak another hanging mmcli.

### gone and down states

- **gone with the hardware present is a failure, not an absent modem.** In one class of failure netifd is stuck dialing: there is no l3 device yet, so the state is gone, but the modem needs healing now. Case: EP06 on qmi, uqmi got "illegal" for the SIM state, and `qmi.sh` entered an endless `--uim-power-off/--uim-power-on` loop every 8 s. That loop is bounded by a timeout that defaults to 0, which means infinite. This modem needs about two minutes to initialize the card after a reset, so the SIM never comes up. sessionwatch does not interfere with netifd in pending, and health had written it off as gone. `GONE_HEAL_MIN=180` covers a normal dial and our own re-enumeration. The USB path check filters out a really absent modem.
- **Disabled interface: user choice vs. accident.** `autostart=false` has two causes. One is the user's choice written in the config (`auto='0'` / `disabled='1'`), which is always respected. The other is an unfinished `ifdown` from someone else, or from our own first step (`ifdown` + `iface_up`) when the modem re-enumerated in between. That second kind is not in the config and must not be respected forever: in Aug 2026 a modem stayed down an hour after healing was enabled. It is respected for `STUCK_DOWN_MIN=900` s, and after that it is treated as a failure.
- **Protocol error is not the user's choice.** When a protocol gives up, it calls `proto_block_restart`, and netifd clears `autostart`. From outside that looks the same as a manual stop. The `errors` list tells them apart: it is empty after a manual ifdown and holds the reason here (for example `{"subsystem":"qmi","code":"SIM_ILLEGAL_STATE"}` on EP06). Such interfaces are healed immediately.
- **SIM illegal raises the minimum step to `reboot`.** After a router reboot, QMI modems (Telit LM960, Quectel EP06) often come up with the card in illegal state. ifup only restarts the same failure (and the qmi.sh power-cycle loop). Only `AT+CFUN=1,1` clears it (verified: illegal->ready in one reset, then ifup got an IP). Even with `heal=ifup` the minimum step becomes reboot. sessionwatch defers its own ifup while waiting for the ladder (see below), so without this minimum step both watchdogs would wait for each other.
- **Not on the bus with ceiling `power`.** If the interface has been gone longer than `GONE_HEAL_MIN`, it is healed with the power step. Case: an Android stick boots slower than the router and sometimes does not enumerate at all on a cold start (Cudy TR3000, Aug 2026: empty bus, no enumeration in dmesg). Only a port power cycle fixes it. Port control lives on the hub and works without the device (`_usb_port_dir` builds the path from the string).
- **Device not on the bus:** ifup and AT are pointless, so the ladder goes straight to the power step.

### Step selection

- **HiLink step 2 is its API** (`device/control`), not AT. `AT+CFUN=1,1` would knock a Huawei out of its debug composition (see bands.sh). The API reboots the module in any composition, as long as its address answers.
- Modems without an AT port: with `power` allowed, the ladder goes straight to USB, otherwise it stays on reconnect.
- The AT port is resolved once and reset each loop iteration. Otherwise the loop variable would carry the previous modem's port.
- **Network search guard.** A module reboot in the middle of a scan sends registration back to the start. On a weak signal a scan takes longer than the cooldown, so the ladder itself kept the modem from registering (SIM7100E after a network-mode change, Aug 2026). `CREG`/`CEREG` stat=2 ("searching") means: do not count, do nothing this round. The ceiling is 12 minutes of continuous search (`.srch` marker), because endless search is a failure in itself. The check runs only before the heavy steps (reboot/power) and only when an AT port is alive.

### Power script (`health.power_script`)

Boards without per-port USB power control can supply their own power cycle, for example a GPIO wired to the enable pin of the modem's voltage regulator. When `health.power_script` holds an absolute path (letters, digits and `/ . _ -` only, checked by `setconf` and again when read) and the file is executable, step 3 runs it instead of `reboot_modem.sh usbpower`, in the background, with arguments `<interface> <modem usb path> <AT port>`; the first 400 bytes of its output go to syslog under `5gmodem-power`. Step 3 is still only reached for modems whose level is `power`.

### Wi-Fi uplink ladder

The Wi-Fi uplink is detected from the wireless config (`wifi-iface` with `network=<iface>`), not from the live device, because in the gone state there is no device. Its ladder also handles `gone`: netifd can detach the interface from the radio during a USB enumeration storm (NO_DEVICE while the station is associated), and only a rebuild fixes that, not ifup.

- **Manual ifdown is not healed** (`autostart=false`, empty errors). Seen live: a test `ifdown wwan` got a `network reload` from the ladder one cooldown later. A detach keeps `autostart=true`.
- **A station with an IP but no internet is not healed** when the association is alive (`iw link` Connected). The upstream router is the problem, and failover moves the traffic. **But an address proves nothing without a live association.** After `CTRL-EVENT-BEACON-LOSS`, netifd keeps the interface up with the old DHCP lease. In one case (Aug 2026) the link stayed red for 25 minutes and "not healed because it has an IP" until someone toggled it by hand.
- **Radio from the live device, not the first config section (`wifi_radio_for`).** Several `wifi-iface` sections, some disabled, can point to the same network. The old `head -1` picked a disabled section on radio1 while the working station was on radio0 (Sep 2026). The device is now resolved through netifd, and the config is used only when there is no device, skipping disabled sections.
- Only **enabled stations** count (`wifi_sta_count`). An AP on the same network is just a bridge and does not detach the interface.
- **Several enabled stations on one network is a config defect** (`_h_multi`). netifd gives the logical interface to the station that came up last. While another station looks for its absent AP, every attempt detaches the interface again ("Interface 'wwan' is disabled/enabled" endlessly), and DHCP never gets a lease. A `network reload` only restarts the race and briefly takes down the router's AP. The soft steps stay. The global rebuild is forbidden, and the log says that the config needs fixing.
- **Step 1: reassociate the station only.** The station and the AP share one radio, so rebuilding the radio (let alone `network reload`) takes the AP down too ("Remove interface", AP-DISABLED, all clients drop). wpa_supplicant can do exactly what is needed: `REASSOCIATE` over ubus (`wpa_supplicant.<sta>`). `wpa_cli` may not be installed on OpenWrt. Measured: deauth -> auth -> assoc -> CONNECTED took 1.5 s, hostapd was not restarted, and the AP saw only a sub-second bridge port bounce. The fallback is `iw dev <sta> disconnect`, after which wpa_supplicant reconnects by itself.
- **Step 2: rebuild only that radio** through `network.wireless` on ubus. The AP on it goes dark for a few seconds. This fixes the NO_DEVICE detach, which `REASSOCIATE` does not fix. `wifi up <radio>` cannot be used: `/sbin/wifi` calls `ubus call network reload` internally (`wifi_updown`) and so restarts every interface.
- **Step 3: global `network reload`**, only when the radio rebuild failed **and** no other uplink is alive. An earlier version did this as step 2 and took down a working modem whenever Wi-Fi failed ("modem stopping network" in the log).

## stapark.sh: Wi-Fi client parking (one radio)

On a radio with one channel (`iw phy`: `#channels <= 1`, for example wcn36xx), the access point has to follow the channel of the station. When the station loses its network, wpa_supplicant scans every channel and the access point stays down until the network returns.

With `5gmodem.health.sta_park=1`, `stapark.sh tick` runs every sessionwatch round:

- A station that shares its radio with an enabled AP and has no link (`iw dev <sta> link` is not Connected) for `sta_park_wait` seconds (default 30) is parked: `wireless.<sec>.disabled=1` plus the marker `parked_by_5gmodem=1`, then commit and `ubus call network reload`. The access point comes up on its own channel, and the internet goes through the modem.
- A parked station is looked for every `sta_park_scan` seconds (default 90, at least 30) with `iw dev <ap> scan ap-force`. The scan runs from the working access point, so it stays up. When the SSID (and the BSSID, if set) is seen, the marker and `disabled` are removed, and the station connects. The access point moves to the station's channel, and its devices drop for a few seconds.
- When a station is re-enabled but never connects (wrong key, weak signal), the next scan interval doubles after each failure, up to 16 times `sta_park_scan`. Without this, the access point would switch channels every 1.5 minutes.
- Only stations with the marker are touched. A station that the user disabled stays disabled. Turning the option off (or `stapark.sh off`) enables every parked station again.
- The marker lives in the wireless config, so a parked station stays parked after a reboot until the scan finds its network.
- The Wi-Fi uplink ladder skips an interface that has no enabled station. Without this rule it would "heal" the parked uplink by rebuilding the radio and take the access point down every cooldown.
- `stapark.sh status` prints `{"enabled":..,"stations":[{"section","ssid","state"}]}`. The state is linked, searching, parked or off. The watchdog form shows it under the option.

## sessionwatch.sh: data session watchdog

netifd brings an interface up once and then stops watching the session. If the network drops the session or recreates it with another address, the interface stays "up" with the old IP while traffic goes nowhere. Example: crossing into another macro-region, the operator handed out an address from another range (10.x -> 100.x), and only a manual ifup restored the connection.

The right fix would be listening for unsolicited `+CGEV: NW PDN DEACT / NW PDN MODIFY` (as the stock `atc` protocol does). But that needs the AT port held open, and the same port serves metrics, SMS, USSD and band control. A permanent reader would either block them or steal their answers. So the session is polled instead.

### What is checked (`check_one`)

- **AT protocols** (`_watched_proto`): the modem's address (`AT+CGPADDR`) is compared with the netifd address. If both are known and they differ, the session was recreated. `AT+CGACT: 0` means the context is down. An empty answer means "unknown" and is never a reason to restart. A busy port does not mean a dead session. AT calls go through the shared port queue. The port is already matched against this modem by `registry.sh`. A manual check here used to cause "wrong modem" bugs.
- **qmi/mbim** (`_kernel_proto`): netifd runs the session through uqmi/umbim. Asking the modem over AT is useless, because it can consider the context alive after the WDS session died. The sign is "interface up but no address".
  - **Look for the address on the children too.** On qmi/mbim the parent never gets the address. The DHCP child `<iface>_4` / `_6` gets it. Checking only the parent restarted a working connection every two minutes (Telit).
  - A v6-only session (`_iface_ip6`) is a live connection. Do not mix this helper into the CGPADDR (v4) comparison.
  - **Compare the whole word.** uqmi answers "connected" or "disconnected", and `grep -q connected` matches both. A dead session was never restarted: on LM960 the lease expired, uqmi said "disconnected", and the interface stayed up without an address for 20 minutes.
  - Two consecutive misses are required, because a single miss happens during a normal redial.
- **"Session but no address" is a wedged channel** (SIM7100E): QMI says connected and gives an address over QMI, but nothing is received (TX grows, RX is zero). ifup, DHCP and static-from-QMI do not help, only re-initializing the modem does (`qmi-recover.sh reset`). It waits three rounds in a row.
  - **Frame format.** If driver and firmware disagree (raw_ip vs 802-3), received frames are dropped silently, and the log names the mismatch. Read it only through `qmicli_p`: a bare `qmicli -p` here started a qmi-proxy that stayed alive, the next round killed it as an orphan and ran ifup, and so the watchdog chased its own tail (FN990A28, Sep 2026). `qmicli_p` reads directly when proto=qmi.
  - **802.3 without an address** (SIM7100E): driver and modem agree on 802.3, the QMI session is connected and has an address, but the modem never answers DHCP in 802.3. Stock `qmi.sh` forces 802.3 on every dial, so a reset loops. Switching to raw-ip (IP set statically from QMI) brings the address up without a reset, and raw-ip survives redials (verified Aug 2026). It is tried once per episode, and if it fails the watchdog falls back to the reset.
- **Deregistered by command.** `+COPS: 2` leaves the modem not searching for a network: xmm/gcom scripts send `COPS=2` at the start, and an interrupted dial leaves it that way. The interface stays down and redials spin uselessly (L850 on MTS, "Not registered"). The watchdog sends `AT+COPS=0` at most once per 5 minutes, and only while the dialer is not using the port.
- **Stuck WDS session.** The modem says "connected" but the interface is down: netifd's previous dial timed out, and the session hangs with another client id. Every new attempt fails ("SIM in illegal state", "Request timed out", "Unknown error"), and this never clears by itself (EP06, seen twice). The watchdog stops the network through uqmi before ifup, which is safe on a free channel.

### Down interfaces are our job too

The old code exited immediately for a down interface, assuming netifd would bring it up. But a protocol that fails calls `proto_block_restart`, and netifd makes no more automatic attempts. health also skipped it as gone. So a modem whose dial failed once stayed down until a manual ifup (EP06, Aug 2026). Now sessionwatch brings up interfaces with autostart, or with autostart cleared but a protocol error in `errors` (the same rule as health.sh). It does this only if the modem device is present and at most once per `COOLDOWN=180` s (`_revive`). An explicit `auto=0` / `disabled=1` is always respected. If the modem is not on the bus, that is `resolve`'s job.

- **Pending means netifd is working.** A down/up during a dial would abort it and create a race between two dialers.

### Stuck uqmi processes (`_kill_stuck_uqmi`, `_sw_run`)

- uqmi **hangs forever** on a wedged channel and ignores its own `-t`. In Aug 2026 two hung `--get-data-status` calls held cdc-wdm, and netifd's dial queued behind them. `_sw_run` runs our own uqmi calls with a timeout killer (same pattern as smsbridge), because one hung call would freeze every check of the daemon.
- Processes started by netifd are cleaned by nobody. After the protocol gives up ("Stopping network"), they stay on `/dev/cdc-wdm0` and block dialing (EP06: hung `--uim-power-off` from the SIM power-cycle loop and `--get-pin-status`). Killing them let the next ifup succeed.
- Only processes older than 15 s are killed. Every uqmi call has its own `-t` of 1-10 s, so 15 s is already abnormal. A community QMI how-to applies the same fix inside qmi.sh (kill the first `--get-pin-status` after 3 s, "connects every other time" on SimCom/Telit). Stock qmi.sh is not patched, because it is updated with the system.
- **Match the executable name, not a cmdline substring.** A substring match also hit shell wrappers, our scripts and grep. The first match in testing was the test command itself.
- Stuck uqmi processes are removed **before** the pending check, because they are what keeps netifd in an endless dial.

### SIM failure: do not feed the loop (`_sw_sim_ready`)

After "illegal" (or empty) for the card state, qmi.sh power-cycles the SIM every 8 s forever. A modem that needs minutes to initialize the card (EP06: about two) never comes up. Our own ifup would only restart the loop. So sessionwatch waits while the interface sits in gone, and the health ladder takes it to `AT+CFUN=1,1`, the only thing that clears the state. The wait is limited: if the state cannot be read for several rounds (busy channel), ifup is allowed as before. The check uses uqmi, so it applies to qmi only.

The same function guards both the stuck-WDS branch and the orphan-proxy branch. Before, only the first branch had it. The proxy branch reset the interface error every two minutes on an illegal-SIM modem, so the health ladder never counted an attempt (FN990A28 on WH3000 Pro, Sep 2026).

### Orphan proxies on a direct channel

If the interface runs on umbim/uqmi (proto mbim/qmi/qmiraw) and an mbim-proxy/qmi-proxy is alive **without** ModemManager, that proxy holds cdc-wdm, netifd's direct requests fail, and the session does not come up until reboot (ZBT-Z8102AX + MV31-W, Aug 2026). The `qmi_channel_free` gate prevents new proxies, and this cleaner removes the existing ones and redials.

- At most once per two minutes. Otherwise there is a window where the proxy is up but the dial has not yet registered a process or pending: the cleaner killed the proxy, netifd started over and spawned a new proxy, and the cycle repeated every two seconds (T99W175 after the eSIM page).
- A **down** interface plus a proxy with **no clients** is also an orphan, and the worst kind: it strangles the dial itself. "Only when up" turned into a deadlock: the interface stayed pending forever and the cleaner waited for up (Netcore N60 Pro + T99W175). Live eSIM/slot operations are not affected, because they have a live lpac/qmicli/mbimcli.
- The proxy is always removed, but the interface is brought up again only with a ready card (see above).

### Round structure (`check_once` and the main loop)

- **One registry snapshot per round, in flat form** (`registry.sh flat`), parsed with `while read` and no subprocesses. Before, there were up to eight jsonfilter calls per modem plus two full registry builds per tick. The snapshot is shared by the session check and the warm-up.
- **Every modem is checked, not only the active one.** On a four-section stand, three interfaces stayed down because the watchdog could see only one. Rules:
  1. Modems owned by ModemManager are skipped (registry `owner`). MM watches its own session, and our polling broke its connection setup.
  2. At most one AT check per round, round-robin. qmi/mbim checks need no AT and run every round.
  3. ifup of one interface at most once per `COOLDOWN`.
- The round-robin counter lives in `/tmp`, so it survives separate `once` calls but not a reboot.
- Order inside a round: session check, then warm-up (restoring connectivity matters more than a warm card), then `health.sh tick` (network only, no port), then stats, button LEDs, uci-delta safety net, SMS bot, SMS commands, SMS drain, outbox, telemetry.
- `_sweep_tmp` runs every ~10 rounds.

### Metrics snapshots

- **Background collector while the page is open (`_page_refresh`).** Before, every page tick did a full collection (1.3-1.8 s CPU every 5 s). Now the page only marks its presence (verb `cached` in 5gmodem.sh), and sessionwatch collects every ~5-6 s as the only collector, under the same LOCKDIR. The page tick hits a ready cache (~90 ms). The marker expires 15 s after the page closes. `SW_BG=1` keeps our own calls from extending the marker, which would otherwise create an endless loop. It is also called between duties, because the duty phase lasts 10-20 s and the snapshot would expire (measured: every other page tick took 1.9-2.4 s).
- A fresh snapshot is detected by reading the stamp file directly, without spawning 5gmodem.sh. Even the "instant exit" costs parsing the script, lib.sh and the registry, 4-6 times per round. The key formula matches `snap_key` in lib.sh. `echo` is used instead of `printf` because the key needs the trailing `_` that the newline produces.
- **Warming inactive modems (`warm_snapshots`).** Only the active modem has a snapshot, so switching tabs showed an empty card for about a second ("the second modem is dead"). Rules: never the active one, one modem per round round-robin (a full AT poll takes ~1.3 s and holds the port), and only when the snapshot is missing or stale. It has its own counter, separate from the session check, because the lists differ.
- **MM modems are not warmed.** Their metrics come from mmcli. While MM initializes them (EM9190 flaps, re-enumerating every ~15 s), an AT poll is just a port fight that hangs and keeps the modem from coming up.

### Housekeeping

- **Orphaned temp files** with a PID in the name (`5gmodem_st.$$.N`, `atq.$$`, `qmicli.$$`, `providers.$$`, `.atprobe.$$`, `cache.tmp.$$`, `.tgcidr.$$`, eSIM bridge files) are removed only on the success path. When the owner is killed (by our 25 s killer or by rpcd at 30 s), they leak into tmpfs, which means RAM. Files older than 10 minutes are deleted. eSIM files use 30 minutes, because the profile download watchdog runs for 600 s, and 10 minutes would delete the response file of a live download (same threshold as esim.sh).
- **Protocol registration guard** (once per boot). LuCI shows "unsupported protocol" when netifd started without our handler (fibocom/qmiraw). If such an interface exists and netifd does not know the protocol, `register_proto` is forced. It restarts the network only in that case.
- **Registration self-heal.** A modem is in the registry but has no section of ours, so the card has no name or SIM data. This happens on firmware with built-in auto-up, where netifd brings the modem up without a USB-add event (SIM7100E showed the raw descriptor "SimTech, Incorporated"), or when the interface was created by hand. No section: `autosetup`, at most once per 2 minutes. Section present but no active modem: `resolve`.
- **Button LEDs** are re-synced every round (`buttons.sh`, see below).
- **Uncommitted 5gmodem uci delta.** The Settings page stages edits immediately (visible to everyone through `/tmp/.uci`), but the commit is a separate rpcd exec. If rpcd is busy and the user leaves the page, the commit is lost and the edit disappears after reboot (ZBT-Z8102AX, Aug 2026). A delta unchanged for two rounds is committed here. sessionwatch never stages 5gmodem edits itself.
- SMS order: bot -> commands -> drain. The drain deletes from the modem only what both the bot and the command handler have processed. Non-active modems are drained every 5 minutes. The unread mirror for external programs (`sms.mirror_interval`, default 60 s, 0 = off) is written atomically. It is skipped for modems with `bg_at_off`.

## fiboipwatch.sh: operator address changes (fibocom proto)

Some operators drop the data session or hand out a new address every few hours while the
modem keeps the old one on the interface. With `network.<iface>.ipwatch=1` the fibocom proto
starts `fiboipwatch.sh` next to the session. Every `ipwatch_interval` seconds (default 20,
range 5-3600) it asks `AT+CGACT?` and `AT+CGPADDR=1`. Two bad checks in a row (CGACT=0 or a
different IPv4) make it exit, and netifd reconnects the interface.

The flag is shown in two places: Network → Interfaces → the modem interface → Advanced
Settings, and the Modem tab (only for the fibocom proto). The interval is set only in
Interfaces. The watcher starts on the next connect, so the Modem tab saves the flag at once
(`setopt.sh ipwatch`) and reconnects the link.

## qmi-recover.sh: QMI client-id pool exhaustion

Some modems (Compal RXM-G1 / Qualcomm SDX55) have a tiny QMI client pool, measured at about 6 per NAS service. Any leak (a direct QMI call killed on timeout does not release its CID, or MM's retry loop on failure) exhausts it. MM then cannot create a NAS client and its init fails ("couldn't peek client for service nas" -> `state=failed`, `unknown-capabilities`). The modem loses both data and band control (Compal bands work only through MM). Leaked CIDs cannot be released because their numbers are unknown, so the only fix is `AT+CFUN=1,1`: after re-enumeration the pool is clean.

- Our own calls go through `qmicli -p` (qmi-proxy), where a killed call does not leak. With 6 slots, exhaustion is still possible, so auto-recovery stays.
- `qmi_pool_exhausted`: `qmicli` has no `-t` and hangs on a busy channel, so it gets an external 8 s timeout.
- **Second trigger `_mm_failed_unknowncaps`.** After exhaustion MM stays failed **even when the pool is free again**, because it does not retry init. Only re-enumeration makes MM probe again.
- **ModemManager only.** On umbim/uqmi, our `qmicli -p` started a permanent proxy over the live session. The orphan-proxy cleaner killed it and redialed, so the connection dropped every few minutes (2.5.7, MV31-W on mbim). Before 2.5.7 the call failed on the non-existent `-t` and never started the proxy. That is why it is gated on a running ModemManager and `qmi_channel_free`.
- At most once per 3 minutes per modem (marker in `/tmp/5gmodem/qmirecover_<path>`).
- `qmi_force_reset` (`reset <path> <reason>`) is the same reset with a reason supplied by the caller. sessionwatch uses it for the SIM7100E "connected, address over QMI, zero RX" state, which only re-initialization fixes (verified twice on two stands, and DHCP came up on the first try after the reset).

## reboot_modem.sh: modem reboot paths

- `soft` (default): `AT+CFUN=4` -> `AT+CFUN=1`. Forces a new attach without USB re-enumeration, so MM keeps its MBIM port classification. Use it for re-register or applying bands.
- `hard`: `AT+CFUN=1,1`. Full reset with re-enumeration. On MM-managed MBIM modems, MM may briefly misclassify the data port afterwards.
- A first argument of `/dev/...` is accepted for backward compatibility (port, soft mode).
- **Sierra Wireless (USB vendor 1199, except EM7345 1199:a001): both modes send `AT!ENTERCND` (cached profile password, then `A710`, then `F710`) and `AT!RESET`** and then follow the hard path without CFUN. On an EM9190 with kernel `mbim`, `CFUN=4/1` left MBIM answering nothing but timeouts until a manual reset. If the modem rejects `AT!RESET`, the usual CFUN path runs. For `mbim` interfaces the script does not force an ifup at re-enumeration: the MBIM channel needs ~30-45 s after the module reappears and the proto's own 15 s retry brings the link up; a watcher reconnects once only if the interface is still on its pre-reset session 60 s after the comeback. Every `soft` caller (band apply, buttons, healing) gets the full reset on Sierra.

### rpcd and background work

Every long branch runs in the background with `>/dev/null 2>&1 </dev/null` **on the subshell itself**, not only on the commands inside. rpcd (LuCI `fs.exec`) waits for EOF on stdout/stderr, not just for process exit. A background subshell inherits the pipes and holds them, so rpcd hits its 30 s timeout and the UI shows "XHR error" even though the action succeeded. With detached descriptors, `ubus file exec` returns at once.

- `hard`: the AT port disappears in the middle of the command, so a synchronous sms_tool would block for about 35 s.
- `soft`: the whole cycle runs in one background subshell (Sep 2026 audit). sms_tool has no timeout of its own, so waiting for the queue plus the CFUN easily exceeded 30 s. The subshell inherits the AT lock fd 8 on purpose, so the lock lives exactly as long as the CFUN exchange. It is then released with `at_unlock`. Before, it was never released, and the next metrics poll hit "port busy". down/up run after `CFUN=1`, otherwise the redial would hit a radio that is not up yet.
- The AT queue must actually be **acquired** (`at_lock` returns 1 on timeout). A CFUN sent in the middle of another exchange fails silently. Answering "port busy" is better.

### Redial after reset

- **Phantom session after `CFUN=1,1`.** On fibocom/xmm/ecm the RNDIS/CDC netdev does not disappear, so netifd thinks the interface is still up and does not redial. The old IP stays, but the session is dead. The watcher waits until the modem really leaves and returns on its USB path, then forces down+up. ifup on an "up" interface does nothing.
- **Wait for the card before redialing.** On QMI modems (Telit LM960) the card takes up to ~100 s after a reset. Dialing right after re-enumeration hits an illegal card, and qmi.sh's 8 s SIM power cycle keeps it illegal forever (Aug 2026: the ladder rebooted the modem and the redial immediately pushed it back). The protocol is already down, so the script waits for card readiness in that quiet window (120 s ceiling), then brings the interface up once. If the card cannot be read (no proxy), it waits out the ceiling. Non-QMI modems (device not cdc-wdm) skip the window.
- **Soft mode uses ubus down+up, not `ifup`.** On some firmware `ifup` reloads the whole config ("hostapd: Reload all interfaces") and drops other interfaces: on a dual-modem router the neighbor modem went down. A single `ubus ... up` is not enough either. After the CFUN cycle netifd still considers the interface up (the fibocom/xmm RNDIS device stays), so `up` does nothing and no redial happens. That was a regression in 1.7.1 on FM350: IP but no traffic. down forces the protocol teardown and up starts a new dial. `ifup` is only the fallback when ubus is missing.
- Soft reconnect suppresses band restore for the ifup it triggers. Otherwise `31-5gmodem-bands` would send another CFUN on top, and two CFUNs in a row wedge the FM350 PDP context.

### Power: GPIO

Board GPIO for modem power or reset (`modem_power` on Huasifei WH3000, `4g`/`5g1`/`5g2` on other boards, list from `target/.../03_gpio_switches`). It works without AT: the slot is set to the inverse of its current value, then after a pause back to the original value, because polarity differs per board (on KuWfi T960 `modem_power=1` means powered, on WH3000 the opposite). The interface comes back in about 1 minute. On WH3000 this powers **only the M.2 slot** and does not affect USB modems.

- `modem_reset` is per board. On Teltonika RUT2xx/RUT9xx it is the module's real reset line (HC595). On Almond 3S the same export is the mini-PCIe slot's `#PERST`, which the modem ignores (it works over USB lines, and 5 s LOW had no effect). So `modem_reset` is dropped on Almond by `board_name`, and the button falls back to `usbpower`. MT7621 xHCI has no real per-port VBUS, so disabling the downstream port is the hardest reset available.
- GPIO33 is active_low. The kernel handles polarity, and the sysfs value is logical, so it uses the same 1 -> pause -> 0 sequence.

### Power: USB port (`usb_power_method`, `_usb_port_dir`)

This is the last resort when nothing over AT helps. FM350 after `CFUN=1,1` hung during USB reconnect: CSQ 99,99, no registration, the port answering only sometimes. `CFUN=4/1`, `COPS=0` and another `CFUN=1,1` did not help: the AT channel was alive but the radio was dead. GPIO power does not help on boards where it only powers the M.2 slot.

Methods, strongest first:

1. `<hub>/<port>/disable`: the hub disables the port. On hubs with power control this removes VBUS.
2. `authorized`: deauthorize the device. Power stays, but the kernel reinstalls the device completely.
3. unbind/bind of the usb driver: the mildest, and it helps a hung modem less often.

- A modem plugged directly into the root hub: `2-1` -> `usb2`, port 1.
- The modem may not come back (issue #25: root hub port, "device descriptor read -110" until the controller resets). The script checks for it, clears `disable` again and logs loudly.
- **Redial after power cycle is mandatory.** After re-enumeration the data session is dead, but netifd does not see it (up=true while the netdev is DOWN), because kernel protocols have no keepalive. The link stayed dead until a manual ifup (qmiraw, wwan0 DOWN for 100 minutes, while the watchdog moved traffic to Wi-Fi). Ports are re-pinned and the interface is brought up.

### HiLink

A HiLink modem has no AT channel, so it is rebooted through its own API. Without this branch the button returned "AT port not found".

## buttons.sh and hotplug.d/button: hardware buttons

- `$BUTTON` in a button event is the **input-code name** (BTN_0, reset, wps...), not the DTS label. kmod-gpio-button-hotplug derives it from `linux,code` (DTS label "mode" with `linux,code=256` arrives as `BUTTON=BTN_0`). Events reach `/etc/hotplug.d/button/` with `$BUTTON`, `$ACTION` (pressed|released) and `$SEEN` (seconds held). The procd `config button` path does not fire on some boards (Huasifei WH3000), so hotplug.d is used instead.
- `30-5gmodem-buttons` never handles `reset` (factory reset is critical and is not offered in the UI). It runs the binding in the background with descriptors detached, because hotplug must not wait for the user's command.
- **System button = reset only (`_is_system`).** Other buttons with a stock handler (wps...) can be assigned: stock `rc.wps` does nothing on plain OpenWrt.
- **Button nodes are found by `compatible=gpio-keys[-polled]`, not by node name (`_dts_buttons`).** Almond 3S names the node "keys". A scan by name missed both Tamper (`linux,code=256`=BTN_0) and reset, even though gpio-button-hotplug sent the events correctly.
- `linux,input-type`: EV_SW(5) = switch (two positions send pressed/released), EV_KEY(1) or absent = momentary. **Huasifei WH3000\* declare a momentary button as EV_SW**, so on those boards (fixed `board_name` list) EV_SW is treated as a button.
- Unknown input codes are skipped (`_code_name` covers BTN_0..15 = 0x100.. and common KEY_*).
- `pressed` and `released` are independent events, each with its own command type. **Simple**: command plus static LEDs. **Conditional**: toggle a service plus LEDs for its state. A momentary button sends both events on one press. There is no virtual toggle anymore.
- Debounce comes first, using `/proc/uptime` (monotonic).
- The conditional command's service name is parsed from the command itself (`svc toggle <svc>` or `/etc/init.d/<svc> ...`), and there is no separate field. On a press, the LEDs show the **future** state (the command is about to toggle it). In `_sync_leds_all` they show the **current** state, so the mapping is the opposite: running -> `leds_on_*`.
- LEDs are set before the command so the user gets instant feedback.
- `set` does no automatic cleanup: a section with only `debounce` is ignored by `run`. A cleanup on every call would break the save order (debounce saved before the commands deleted the section). Use `del` to remove a binding.
- `get` returns all stored fields, otherwise the UI lost the command type, service or conditional LEDs on reload.
- `svc <toggle|start|stop|restart> <service>`: toggle stops and disables a running service, and enables and starts it otherwise. "Is it running?" is `svc_running` in lib.sh. That function also covers the `status` trap on non-procd services, which made a button stop passwall2 and never start it again.

### LEDs

- Color comes from the name (`green:wan`, `white:signal1`): the word before the colon, but only if it is a known color. The "on" brightness differs per LED (1 or 255) and is read from sysfs `max_brightness`.
- Hidden LEDs (`_led_dummy`): mac80211 dummy LEDs (`mt76-phy0`, `ath10k-phy0`), and `white:power` **on Almond 3S only**, which is the LCD backlight described as an LED in the DTS. Turning that "lamp" off gives a black screen. On other boards `white:power` is a normal LED.
- **Detach from the kernel trigger persistently** (`_led_detach`: uci system `config led`, `trigger 'none'`), otherwise the netdev trigger restores its brightness right after our write. `_apply_leds` also sets `trigger=none` at runtime before writing (cheap, no flash write).
- **`led reload` turns all configured LEDs off.** `/etc/init.d/led reload` applies each configured LED's trigger and, with `trigger=none`, takes the brightness from `default` (0 if absent). Our own save, the LuCI LED page or any package editing uci system turned the button LEDs off for good (Aug 2026: service running, both LEDs dark). Fixes:
  - the last applied state is stored in `default`, so reload and boot restore it. It is written only on a real change, because the sync runs every 30 s and a commit each round would be a flash write;
  - the commit is done without `led reload` (the hardware is already set, and reload would blink it off);
  - `setleds` calls `_sync_leds_all` right after its own reload;
  - init `5gmodem-btnleds` syncs at boot (before, the LEDs stayed dark until the first press);
  - sessionwatch re-syncs every round.
- Only **conditional** buttons are synced. Static LEDs show the press, not an observed state, so applying them at boot would show a wrong state.

## healthform.js: watchdog settings form

- One form shared by the netpri.js modal and the Settings page block (5gsettings.js). Before, it lived only in the modal, so with the priority widget disabled there was nowhere to configure the watchdog (issue #12). It uses only the `getconf`/`setconf`/`setheal` verbs, with no direct uci access from the browser.
- Standard luci-base widgets only (ui.Checkbox, ui.Dropdown, ui.Textfield, ui.DynamicList in `.cbi-value` rows). Hand-made inputs looked foreign in themes.
- Multi-select uses `ui.Dropdown` with `multiple`, like `form.MultiValue`. `ui.Select` with `widget:'checkbox'` reads only radio buttons in `getValue()` and returns null for multiple selection.
- `isChecked()` is called on the healing checkbox only when it was rendered. Without modem uplinks, `render()` is never called, and `isChecked()` threw a TypeError, so the modal did not open (Sep 2026 audit). The same applies in `save()`: without modems or Wi-Fi, the stored `healing`/`heal_wifi` value is sent back instead of 0.
- The failover explanation sits under the checkbox, not inside the collapsible group, because the group hides exactly when the user is deciding whether to turn it on.
- The Wi-Fi heal block is shown when Wi-Fi healing is already enabled even with no Wi-Fi uplink present. Otherwise an enabled setting would become invisible and impossible to turn off while the link is down.
- Targets are sanitized to `[A-Za-z0-9.:-]`, because they go to a shell verb as one argument.
- The `once` call after save is wrapped in `L.resolveDefault`. The round is blocking and longer than the 20 s XHR limit with three uplinks, and an unhandled reject showed an error over the page (Sep 2026 audit).
- Autosave debounces 500 ms (checkbox + select = one backend call) and listens to `change`, `widget-change` (luci-base widgets) and `cbi-dynlist-change` (DynamicList).
