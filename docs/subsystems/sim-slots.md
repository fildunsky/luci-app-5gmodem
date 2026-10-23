# SIM slot reading and switching

`simslot.sh` reports the SIM slots of a modem and switches the active one. It is used by the "SIM menu" popup and the SIM/eSIM buttons on the Network page, and by the eSIM page (`esim.sh`, `5gesim.js`) to detect whether the eSIM slot is active. eUICC profile management itself is described in [esim.md](esim.md).

```
simslot.sh status  [for=<usbpath>] -> {"type":"USIM|eSIM|","slots":[{"id":..,"label":..,"present":"0|1"}...],"active":"<id>"}
simslot.sh set <id> [for=<usbpath>] -> {"result":"ok"} | {"error":"..."}
simslot.sh refresh [for=<usbpath>]  -> status that bypasses the fast cache (background refresh)
```

The UI shows slot buttons only when there are two or more slots.

## Target modem

Slots belong to the modem of the tab the user opened, not to the active uplink; on a multi-modem router these differ. The UI passes `for=<usbpath>`, without it the active modem is used (scripts, cron). The background refresh passes `for=` too, otherwise it would refresh the active modem and the other tab's cache would never fill. `QMI_TARGET_PATH` is exported so lib.sh channel gates (`qmi_channel_free`, `qmicli_p`) judge this modem's interface, not the globally active one.

## Validation

The slot number is validated before any branch: there are several `set` paths (MM, AT, QMI/UIM, vendor AT), and the QMI path computes `$((n - 1))` first. On `1x` busybox ash aborts the whole script with an arithmetic error (no JSON at all), and on `abc` arithmetic yields -1 and `AT^switch_slot=-1` reaches the modem. A CR inside the value would also split one AT command into two.

## Caches

- `set` clears `/tmp/5gmodem/slot_*` (metrics' active-slot cache), `slots_*` (our list; note `slot_*` does not match `slots_*`), `bandsprep_*`/`bandrestore_*`, `metrics_*`, `esim_actslot`, `esimstat_*`. Clearing is done before branching; doing it in only the AT branch missed the other transports.
  - Band markers: a SIM change re-enumerates the modem and FM350 resets the band mask to all bands; the proto reapplies saved bands once per boot (`bandsprep`), so without clearing the new SIM came up on all bands.
  - Metrics snapshot is keyed by USB path, not SIM; without clearing the cache-first path served the previous SIM's operator/cell ID until a full poll.
  - eSIM caches: without clearing, the eSIM tab highlighted the previous slot for an hour (ZBT + MV31-W).
- `status` is cache-first: `slots_<path>` younger than 300 s is returned immediately with no mmindex, port or `at_lock`. Slots change only by physical SIM change or `set` (which clears the cache).
- Stale or missing cache: answer with what we have and refresh in the background (at most once per 60 s, `.upd` marker). A synchronous read took up to 20 s and mostly returned nothing because metrics polling occupied the channel; the Network page stalled and the SIM buttons never appeared (MV31-W without a card). The background subshell must detach its fds or rpcd waits the same 20 s.
- Empty answers are not cached (a busy or wedged channel, e.g. mbim-proxy after re-enumeration, returns nothing; caching hid the buttons for 5 minutes). Exception: the AT path caches an empty list when it held `at_lock` (`_LOCKED=0`), because then nobody could have stolen the answer and it is genuinely one SIM.
- When no tty answers (re-enumeration after a switch/CFUN, port busy), `status` returns the last valid answer instead of "no slots".
- An MBIM read whose active slot is missing from the list is a partial read and is discarded (the UI hides buttons on fewer than two slots).
- The ModemManager branch writes the cache as well; once `status` became cache-first, the MM path that bypassed the cache left it empty forever.

## Modem classes without slots

- HiLink (`kind=hilink`): physically one slot. E3372 answers AT probes as if it had SIM1 and eSIM.
- `quirks.sh: sim_slots_via` = `none` (e.g. SIM7600E-H): no buttons under any protocol. Its firmware reports two physical slots via QMI/MM, only one works, and switching to slot 2 lost the network. The gate used to exist only in the QMI branch.
- `sim_slots_via` is computed once (`_SVIA`) with "<uci model> <USB product>". Two calls with different first arguments disagreed while the model was not yet written to the section: the gate saw `ceiswitchsim` and the transport saw `qmi` on the Compal prototype at `05c6:90d5`.
- `bg_at_off`: background AT polling is disabled for the modem, so `at_query`/`sms_tool` are stubbed to fail for `status`.

## Transport selection

The mmcli path is chosen by the interface protocol, not by MM visibility: kernel-proto modems (e.g. FM350/fibocom) get re-registered by MM after each USB re-enumeration, and a blind mmindex sent the request to a half-dead MM object.

Order: ModemManager (proto `modemmanager`) -> vendor/AT per `sim_slots_via` (`simdet`, `uims`, `quimslot`, default GTDUALSIM/CEISWITCHSIM) -> QMI/UIM (`qmi`).

### ModemManager

- `mmcli --set-primary-sim-slot`; on failure fall through to the vendor AT command and QMI instead of giving up.
- Labels come from `sim.properties.sim-type` (MM >= 1.20: physical/esim). An empty slot is the path `/`; we export `present:0` so the page greys out the button. Two T99W175 without a card reported `length=2`, both paths `/`, and the UI looked like two inserted SIMs.
- Duplicate labels (two physical SIMs) revert to numeric `SIM<n>`.
- One slot from MM is an answer: return it instead of probing a channel MM owns.
- Empty or <2 slots from MM (MV31-W in MBIM) is not "no slots": fall through to MBIM/QMI via the proxy.
- If MM gave no eSIM label and the node is `cdc_mbim`, ask `mbimcli -p --ms-query-slot-info-status=<n>` and relabel slots in an `*esim*` state (MV31-W under MM shows two unnamed slots).

### DW5821e / T77W968 (`mm_at_fragile`, 413c:81e0)

- `mmcli --set-primary-sim-slot` drops the MBIM session ("Transaction timed out"), MM declares the modem unusable, the module leaves USB for 1.5-2 min.
- `mbimcli --ms-query-device-slot-mappings` hangs and holds the channel lock, stalling metrics.
- `AT^switch_slot?` answers at once, `AT^switch_slot=0/1` switches in a second. So slots for this family are AT-only.
- In MBIM the firmware reports the eSIM slot in `state-error`; MM shows `sim-slots.length 1` and `--set-primary-sim-slot=2` is "out of bounds". The modem knows the slots: `AT^switch_slot?` -> "SIM1 ENABLE"/"SIM2 ENABLE". Asked only through a port where AT under MM is allowed (`mm_at_allowed`, `MM_AT_PORT`), because a query in MM's port drops the session. A modem without the command is remembered for 10 min (`noswslot_<path>`).
- Interface on `modemmanager` but MM has not assembled the modem yet: port and channel are MM's, do nothing.

### Vendor AT `^switch_slot` (SDX55/SDX62) — `_at_slot_set`

- Foxconn T99W175 / Thales MV31-W: `AT^switch_slot`; T99W373 / MV32-W manual calls the same command `AT+SWITCH_SLOT` (section 15.38), same answers and numbering. `_at_slot_cmd` tries both and uses whichever answers with "SIM".
- 0-based (0 = SIM1, 1 = eSIM); our ids are 1-based.
- Goes over tty and does not depend on the QMI channel, so it is used both in the normal `set` path and when netifd owns the channel. With kernel qmi/mbim the channel is always busy and `set` used to stop at "qmi busy" while the same command from the AT menu worked (ZBT + MV31-W).
- Uses `at_query` (queued) rather than raw `sms_tool`: the port is shared with the eSIM bridge and metrics.
- Waits for confirmation (`SIM<n> ENABLE`, 6 x 2 s) instead of a fixed `sleep 3`: the switch takes 3-6 s.
- When the QMI channel is held by netifd, `status` reads the active slot from `^switch_slot?` and reports the fixed pair 1 = SIM1, 2 = eSIM. Models without the command (Telit LM960) fall back to "qmi busy".

### Telit `#SIMDET` (`simdet`)

`AT#SIMDET=<0|1>` selects the slot, `AT#SIMDET?` confirms, then `AT#QSS?` (`#QSS: <mode>,<inserted>,<slot>`) is polled until the slot matches. Runs under `at_lock`. Under ModemManager only the MM-safe port is used. Without a usable port it falls through to QMI.

### Sierra `AT!UIMS` (`uims`, EM9190)

0 = UIM1, 1 = UIM2 (second slot or eSIM, depending on hardware), 3 = auto-switch (actual slot is the second field of `!UIMS: <uim>,<used>`). No password, no reset, persistent (reference 41113480 r14). Slot 2 is labelled "eSIM" so the eSIM tab gets its switch button; for a physical second slot only the label is inexact.

### Quectel `AT+QUIMSLOT` (`quimslot`, RM520N-GL)

- `AT+QUIMSLOT?` -> `+QUIMSLOT: 1`, `AT+QUIMSLOT=<n>` -> OK. Applied immediately, no modem reset (an extra `CFUN=1,1` would cost a minute offline), but the switch drops the data session, so the interface is redialed.
- Result is re-read; an empty read is not a failure (port briefly unavailable while the slot already switched).
- Slot 2 is labelled "eSIM" only if `esimstat` says available or `AT+QESIM="eid"` returns an EID: the eUICC is not soldered on most units of this family (ERROR on common variants), so vid:pid alone is not enough.

### Fibocom `AT+GTDUALSIM` / Compal `AT+CEISWITCHSIM` (default AT path)

- FM350: `AT+GTDUALSIM?` -> `+GTDUALSIM : 0, "SUB1", "L"` (the space before `:` varies); `=?` -> `(0-1)` or `(0,1)` means two slots. `AT+SIMTYPE?` 0 = USIM, 1 = eSIM (manual 3.15) reports only the active slot. Ids and labels are 0-based (SIM0/SIM1) to match the "SIM Slot" metric; the FM350 manual (4.3) calls them SIM1/SIM2 but the firmware's first slot is 0.
- The type of each visited slot is remembered in UCI (`slot_type_<n>`) because SIMTYPE reads only the active one. A never-visited eSIM slot is labelled "eSIM" if the other is a known physical SIM and either `esimstat` says available or the model is in `esimcaps.sh`. The cache alone is a deadlock: while the physical SIM is active ISD-R is unreachable, `available=1` is never cached, the slot stays "SIM1", and the eSIM page cannot offer "switch to eSIM" (FM350 with soldered eUICC).
- Compal RXM-G1 (SG500M2-X) knows neither SIMTYPE nor GTDUALSIM. `AT+CEISWITCHSIM?` -> `Physical SIM SLOT 1 maps to SIM1,SIM inserted 1, ...`; id = physical slot, active = the one that maps to SIM1. "SIM inserted" appears twice in the line (the second is the CD pin), so the first occurrence is anchored. `AT+CEISWITCHSIM=<n>` maps physical slot n to SIM1 (`=?`: "1:Set physical SIM SLOT 1 to SIM1, 2:Set physical SIM SLOT 2 to SIM1").
- Compal is handled over AT even under ModemManager (`is_compal`, one predicate for all compositions `05c6:90d6`, `05c6:90d5`, `1e2d:00b7`, `05c6:9025`; the latter has a generic "HSUSB Device" descriptor): MM reports a wrong slot picture (sticks to SIM2, shows an empty slot as active) and switching via mmcli does not work.
- Fibocom commands are sent only to modems that have them (or unknown ones): extra commands in a shared AT port collide with metrics polling (an echo of `AT+SIMTYPE?` once ended up as the modem name read by `AT+CGMM`).
- `live_port` uses only tty of the target modem (`detect.sh` output first only if it belongs to it) and drops the xmm/atc dial port (`drop_dial_port`). `AT+GTDUALSIM=<n>`/`AT+CEISWITCHSIM=<n>` physically switch the slot, so hitting a neighbour's port would switch the wrong SIM in the wrong modem; querying the dial port kills the data session.
- The AT queue (`at_lock`) is required: without it `AT+GTDUALSIM?` received the answer of another command.

#### Empty answer after switch

For `AT+GTDUALSIM=<n>`/`AT+CEISWITCHSIM=<n>` only an explicit `ERROR` is a failure. FM350 resets and re-enumerates immediately after the switch and often never prints `OK`, although the slot did change (verified on hardware).

### QMI/UIM (`qmi`)

- Used where firmware gives slots only via QMI, e.g. Telit LM960A18 (dual SIM single standby, no `#SIMSELECT`). `qmicli --uim-get-slot-status` prints `Physical slot N:` blocks with `Card status`, `Slot status: active`, `Is eUICC: yes`; id = physical slot (1..N), eUICC slot labelled "eSIM".
- If netifd owns the channel (`qmi_channel_free`, proto qmi via uqmi) we do not become a second master: answers get mixed and link setup hangs. Switching goes via vendor AT instead.
- `qmicli` always via qmi-proxy (`qmicli_p`, `-p`) and killed after 20 s. A direct qmicli killed with -9 does not release its QMI client ID; leaked IDs exhaust the pool (`ClientIdsExhausted`) and ModemManager stops initialising the modem (`unknown-capabilities`), which broke data and band control on Compal. With `-p` the proxy owns the client.
- `set`: vendor AT first, then `--uim-switch-slot`. QMI is often busy or wedged with mbim-proxy and the switch silently never reaches the modem.
- `status` on `cdc_mbim`: native MBIM first, QMI as fallback. QMI is tunnelled over MBIM and fails first: while netifd keeps re-raising the interface (forever without SIM, every 15 s) qmicli gets "couldn't open the QmiDevice: device is closed", while native MBIM queries work (MV31-W).
  - `--ms-query-device-slot-mappings` -> `Executor '0': slot '<N>'`; `--ms-query-slot-info-status=<N>` -> `Slot '<N>': '<state>'`. 0-based. `state-empty` = no card, `*esim*` = eUICC, anything else = card present.
  - Two attempts per slot: a single failed query ended the loop with one slot and the buttons disappeared.
  - Same channel lock as `qmicli_p` (`/var/lock/5gmodem_qmi_<node>.lock`, flock -n loop up to 10 s).
  - Under a live ModemManager only via the proxy (`-p`): direct access steals MM's channel ("internet drops when opening the page").
  - Under a live umbim (`proto=mbim`, interface up, `_umbim_owns_wdm`) the node is not touched at all: both direct and `-p` (which spawns mbim-proxy) take the channel and umbim gets "mbim message timeout". Slots then come from the sticky cache / QMI path.
  - The variable holding the proxy flag is `_MPX`, distinct from `_MP` (card present); a name clash once passed `1` as an mbimcli argument.

## Redial after a switch

A slot switch means a different SIM; netifd keeps the old SIM's address and traffic stops until ifdown/ifup. `slot_redial` waits (up to 120 s) for the target modem to return to USB (FM350 re-enumerates for tens of seconds), runs `modemswitch.sh resolve` (rebinds ttyUSB/cdc-wdm that moved and restores preferred-modem activity), then ifdown/ifup of that modem's interface. It runs in the background with fds detached on the subshell, otherwise it holds rpcd's pipes for ~120 s and the UI XHR times out.
