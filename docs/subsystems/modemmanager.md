# ModemManager: inhibit, takeover and boot recovery

`mm-inhibit.sh` is a small procd service (`/etc/init.d/5gmodem-mm-inhibit`) with two jobs. It keeps ModemManager **off** modems that we run on kernel protocols (qmi/mbim/xmm/atc/fibocom/...), and it **recovers** modems on the `modemmanager` protocol that MM missed at boot. Both problems come from systems without a working udev. See also [health-and-recovery.md](health-and-recovery.md) for the healing ladder and the QMI pool recovery that this loop calls.

## Why inhibit at all

On routers with libudev-zero (libudev API, but no udevd and no `/etc/udev` rules) the `ID_MM_DEVICE_IGNORE` rule never applies. MM grabs a kernel-proto modem, fails to manage it (the kernel owns the netdev), and keeps re-probing its AT ports. That collides with our metric reads, and the info page flickers. On systems with working udev, MM never sees these modems, and the loop finds nothing to do.

`mmcli --inhibit` releases a modem and holds it released for as long as the mmcli process lives. So one background inhibitor runs per kernel-proto modem (`inhibit_pass`). Modems on proto `modemmanager` are never inhibited.

## Inhibitor rules (`inhibit_pass`)

- **Visible in `mmcli -L` = inhibition is not working.** A working inhibition hides the modem completely, so any modem that shows up here has a useless holder, if it has one at all.
- **Hold by the stable device id** (sysfs path from `modem.generic.device`), not by the `-m` index. The index changes on every MM restart, and `kill -0` on the old holder still says "alive". The old code thought everything was fine while MM kept the modem, and qmi lost its channel, so there was no IP. If a holder is alive but the modem is still visible, the holder gets one minute and is then recreated.
- **Inhibition dies with the MM process** (it is registered over D-Bus). After an MM restart the holder is still alive, but the modem is captured again. The loop watches MM's pid, and when it changes, all holders are dropped at once.
- **Holders of absent modems are reaped.** An unplugged modem used to leave its pid file forever (`1-1.3.pid` after a Telit was removed), and when the hardware came back it raced the new holder.
- `mm_exclude` per modem (`5gmodem.m_<path>.mm_exclude`): `1` = hide, `0` = give it to MM on purpose, empty = hide everything on a kernel proto. Turning it off is useful because MM's control is sometimes richer (network modes, 3G bands). `set-exclude` writes the flag and applies it immediately.
- **Takeover pause** (`bands.sh mmtakeover`, `pause`/`resume`): a band change on a kernel proto temporarily hands **this** modem to MM. While the flag exists, its holder is dropped and the modem is not inhibited. Other modems are inhibited as usual.
- Each pass also runs `qmi-recover.sh recover` for the active modem. It is cheap (one `qmicli -p`) and does nothing for non-QMI modems such as FM350.
- Keeping MM running for an **absent** modem is pointless, because at startup it is MM that grabs other modems. `mmneed.sh` decides.

### React to MM start immediately

Until the inhibition is in place, MM can capture and **disable** another modem. With a 15 s loop that window is caught almost every time: MM started for a neighbour on proto=modemmanager and disabled an FM350 on its way. So the expensive pass (`mmcli -L`, one process per modem) still runs every ~15 s, but a cheap `pgrep` runs in between and triggers a pass right after MM starts.

## Restoring a stolen session (`_restore_stolen`)

When MM captures a foreign modem, it deregisters and disables it ("state changed (registered -> disabling)" -> "disabled modem"). The inhibition that follows gives the modem back but does **not** restore the connection, and nothing else brings it up. Seen on FM350: netifd kept `up=true` with the **old** address and a `default dev eth2 scope link` route into nowhere, and the interface gave no hint of the cause.

- A modem that was visible in MM is marked, and the next pass checks its session after the inhibition has settled.
- The truth about the session is in the modem, not in netifd. It is checked in two independent ways, and the script acts only on positive proof of a broken session:
  - `AT+CGACT?` through `at_query` (queue + timeout). This runs from a loop that lives as long as the daemon, so it must not compete with the metrics poll. It is accurate, but the port can stay silent (busy, or renumbered after MM's activity). That silence was exactly what happened at the moment of the break.
  - Ping through the interface: `77.88.8.8` (8.8.8.8 is unreachable in Russia), then `1.1.1.1` as the second target for outside Russia.
  - **Ping is not enough.** Some operators block ICMP completely (MegaFon: 100% loss while HTTP answered in 0.4 s). An HTTP/HTTPS probe with `curl --interface "if!<dev>"` follows (see [curl interface if-prefix](health-and-recovery.md#curl-interface-if-prefix)).

## Boot recovery for proto modemmanager (`mm_recover_missing`)

With libudev-zero, MM does **not** scan existing devices at startup and lives only on hotplug events. At boot the modem's ports (cdc-wdm/ttyUSB/wwan) appear before MM is on D-Bus, so the events are lost ("Couldn't report kernel event: couldn't find the ModemManager process in the bus"). netifd has already failed the interface by then, and the modem has no IP. Re-sending add events after MM starts makes the modem appear (verified on Compal, Hiveton build, MM 1.24). This is idempotent.

- Every present modemmanager modem is fixed, not only the active one. In the multi-modem case all of them stayed without an IP.
- An ifup is required (`_mm_ifup_if_down`). Without it the modem appeared in MM, but the interface that netifd had failed stayed down. netifd brings the interface up before MM is on D-Bus, gets "Device not managed by ModemManager", and never retries.

### `_mm_ifup_if_down`

- The function waits for **this** modem to appear in mmcli, then runs ifup in the background.
- If the interface is pending, the function does nothing. After a session drop, MM's hotplug runs ifup by itself, and the interface stays pending for a few seconds while MM connects. Our ifup at that moment is a teardown in the middle of a connect ("couldn't load bearer path: disconnecting anyway"), and the cycle starts again (T99W175 + Verizon cycled every 20-40 s, Sep 2026).
- A lock against parallel ups plus a cooldown. The lock is held for the whole attempt (MM wait + ifup + up to 90 s for the connect). A second ifup does teardown->setup and interrupts the connect: the modem swings registered<->disabling and never gets an IP. The stale-lock threshold (>5 min) only protects against a dead waiter. The state is checked again right before ifup, because the wait can last up to two minutes.
- **`local` is mandatory** in this function and in `mm_recover_missing`. Without it, `_n` and the other variables leak into the service's main loop, whose counter is also `_n`. `$((_n+1))` on a string then crashes the shell: procd crash-loop, and no IP at boot (confirmed with a trace).

### MM-only modules (DW5821e/T77W968 family)

These modules are never switched to proto qmi/mbim (`.mmonly`). They still take the common path: event replay, then a rebind after 150 s, at most 2 rebinds (`.rebindn`), then `.rebindfail` with a power-cycle hint. Before 27.10.2026 the branch did `continue`. On a cold start the X20 firmware timed out MBIM init ("couldn't start initialization: Transaction timed out" -> "modem is unusable"), and MM never retried on its own. Nothing recovered the modem until a manual power-cycle, and a manual unbind/bind of the USB device brought it back. 05c6:90d5 (Compal) is still excluded from the rebind.

### Rebind instead of a manual report (`_mm_rebind`)

`mmcli --report-kernel-event` gives MM the node name but none of the properties udev normally provides. With libudev-zero, MM adds the ports and immediately rejects them:

```
[plugin/generic] could not grab port cdc-wdm1: unhandled port type
[base-manager] couldn't create modem ...: Failed to find primary AT port
```

USB unbind/bind produces real kernel events, and the same modem is created on the first try (after three failed reports: "modem successfully created"). So the first round sends the cheap report, and if the modem is still missing later, the script rebinds. The cooldown is 5 minutes per modem.

- **Wait for the control port, not a fixed sleep.** Re-enumeration takes ~20-30 s (plus our `new_id` bind of ttyUSB). A fixed `sleep 8` sent the events before the nodes existed, and the modem disappeared from MM completely. The wait is up to 40 s.
- **Control port did not come back** means a failed re-enumeration, usually `can't set config #1, error -71`. The device stays unconfigured and cannot recover by itself. The function returns failure and sets a flag in tmpfs, and then the modem is **not touched again**: repeated unbind/bind does not revive it, only removing power does. The flag clears when the modem finally assembles, or on reboot.
- **Do not rebind while MM is probing (`_mm_probing`).** A slow modem with many ttys takes MM 1-2 minutes to probe. The old fixed 60 s timer cut the device in the middle of the probe, so unbind/bind hit `error -71` (ZBT-Z8102AX, Aug 2026). The signal is MM's open fds on any tty/cdc-wdm of that USB path, with no log parsing. While MM holds any port, the counter is reset to zero.

### Never rebind a modem with a live QMI channel

If MM failed to assemble a modem that has cdc-wdm, a rebind will not help. On some hardware (ZBT-Z8102AX + Genesys hub) unbind/bind drops the device into `error -71` until power is removed. Such a modem can run over uqmi without MM, so the fix is a kernel protocol, not a rebind. This branch is reached only when MM did not assemble the modem. It is logged once.

- **Fallback proto follows the node's driver, not "always qmi".** cdc_mbim has the same cdc-wdm node, and uqmi on it gets nowhere: "Request timed out", "Failed to parse message data", "SIM in illegal state - Power-cycling SIM", pending forever. mkiface also wrote `qmi` into the section's `iface_proto`, where it was then treated as the user's choice, and auto-detect and vendor exceptions never ran again. If the driver is unknown, the modem is left alone.
- `MKIFACE_AUTOFALLBACK`: a forced proto, not the user's choice, so it must not be written to `iface_proto` (see mkiface.sh).
- **Second pass only.** The switch happens when MM is alive, its probe of this device is over, and the modem is still not in MM (Netcore N60 Pro + T99W175 05c6:9025: mute AT ports, MM powerless, QMI alive). It applies only when the protocol is chosen automatically, never over a manual choice, and once per boot.

### Modems that have no fallback

- **MBIM modules we deliberately run through MM**: DW5821e/T77W968 (413c:81d7, 413c:81e0, 0489:e0b5) and MV31-W/T99W175 in MBIM composition (05c6:90d5). umbim either does not bring the session up or gives an address without traffic, which is why mkiface puts them on modemmanager. Switching to mbim would turn "MM has not assembled it yet" into "never works". MM usually fails only temporarily (the libudev-zero boot race heals on the next round), so the script waits. The QMI composition 05c6:9025 is not affected: there the fallback works and rescued mute AT ports.
- **DW5821e/T77W968 is MM-only in the QMI composition too.** In QMI the module has a session but no traffic. The fallback used to switch it to qmi and hide it from MM (413c:81e0 on WH3000, Sep 2026: proto=qmi, mm_exclude=1, USB resets).
- **Compal RXM-G1 / SG500M2-X in QMI composition is MM-only (`_compal_mm_only`).** uqmi cannot open services on this firmware ("Failed to connect to service"). The modem arrives here before MM assembles it (35 s after port binding on NanoPi R3S, Sep 2026), and the fallback could switch it back to qmi. Identification is the same as in mkiface: by **path** (05c6:9091 is also used by other Qualcomm modules), by the cdc-wdm node and by the AT model. The AT port is queried only for vendor 05c6 and only while MM is not probing: a parallel reader steals MM's answers, and MM marks the port "unhandled", which is the very failure being fixed. A positive answer is cached for the boot, and a negative one is asked again. The return value is inverted on purpose: 0 = not Compal (fallback allowed).

## AT-only assembled modem (`_mm_fix_atonly`)

Port events reach MM before it is ready: libudev-zero has no coldplug, and our `new_id` bind adds ports even later. If MM did not know about cdc-wdm when it assembled the modem, it builds it **AT-only**: primary = ttyUSB, the net interface is "ignored", and the data bearer never comes up (connect fails with `MobileEquipment.Unknown` "No cause information available"). A reboot does not help, because the same race happens on every boot. Reproduced on Compal RXM-G1 (05c6:90d6) after a second modem was connected.

- `mm_recover_missing` does not cover this case: it reports ports only when the modem is missing from MM, and here the object exists but is incomplete.
- Re-sending the event is not enough, because MM does not add a control port to an already assembled modem. The device is rebound so that MM forgets the object, then the ports are announced in order: control port, net, tty. Verified: primary becomes cdc-wdm0 (mbim), wwan0 is net, and the modem connects at once.
- Preconditions: a control port exists in the system (otherwise the modem really is AT-only), the modem has no control port yet, and there is no working connection.
- Anti-loop: at most once per 5 minutes per modem. **No marker means a fix is allowed.** The old code used `_flast=0`, and with uptime < 300 the difference was below the threshold, so the anti-loop blocked the fix in exactly the boot window it was written for.
