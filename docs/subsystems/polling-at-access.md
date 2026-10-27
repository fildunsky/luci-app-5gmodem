# AT port access: lock, detection, registry

Several consumers share one modem tty: the metrics poll (`5gmodem.sh`),
`simslot.sh`, `esim.sh`, `bands.sh`, `smsbridge.sh`, `collect.sh`, profiles and the
AT console. This doc covers the serializer (`atlock.sh`), AT port detection for the
active modem (`detect.sh`), the modem registry (`registry.sh`) and the
ModemManager gates that decide whether we may touch an MM-owned port (in
`quirks.sh`, see also `polling-quirks.md`). Main poll: `polling.md`.

## `atlock.sh`: serializer

Sourced with `.`. Overlapping AT sessions mix answers, and that was observed:

- `AT#MONI` got `+COPS: 0` (another command's answer from the poll);
- `AT+COPS?` returned nothing and looked like a hung modem;
- `ATI` returned `+CPIN`/`+CSQ`, and the echo of `AT+SIMTYPE?` ended up in the modem
  name.

One poller alone was stable (6/6 runs, JSON valid 12/12); two pollers emptied
fields. The worst part is that "modem did not answer" and "answer was stolen" are
indistinguishable, which produced false diagnoses.

### `at_lock <port> [timeout=10]`

- Key is the **port name**, not the modem: two modems on different ttys do not
  block each other.
- Lock file `/var/lock/5gmodem-at-<tty>.lock` (fallback `/tmp`), fd **8**. fd 9 is
  used by the hotplug handler (`71-5gmodem-resolve`); a shared number would make
  our lock drop theirs.
- Fast path `flock -n`. Otherwise a **blocking** `flock` in a background subshell
  plus a watchdog `sleep <max>; kill`. Why not a `flock -n` loop: busybox has no
  fractional sleep, no `usleep`, no `timeout`, so every wait rounded up to a whole
  second (3-4 s extra on a cold page open with several consumers), and `-n` races
  are unfair (random order). Blocking `flock` wakes immediately and is FIFO-fair,
  but busybox `flock` has no `-w`, so a hung holder would block until rpcd kills
  the call at 30 s ("XHR error"). The lock is taken on the OFD opened by our own
  process (`exec 8>file`), so it survives the subshell exit. The watchdog closes its
  copy of fd 8, otherwise it would hold the OFD and the lock would outlive us.
  Verified on a router: the waiter gets the lock the instant the holder releases;
  the timeout branch takes exactly `<max>`.
- **Re-entrancy**: `_AT_LOCK_HELD` (exported) names the port held by an ancestor.
  The poll holds the lock for its whole life and calls `simslot.sh` synchronously,
  which locks again. A second `exec 8>file` opens a new OFD that conflicts with the
  ancestor's OFD, so the process tree deadlocked itself until timeout (cold poll
  11 s = 10 s simslot timeout + 1 s work). Same port held -> return 0.
- Different port while holding one -> explicit refusal (logged). Re-opening fd 8
  silently dropped the first port's lock.
- Timeout race: the background `flock` may succeed exactly when killed; the lock
  then sits on our OFD while we report failure, locking the port for our whole
  lifetime. On timeout we `flock -u` and close fd 8 (no-op on an unlocked OFD).
- On failure `_AT_LOCK_HELD` is not set; callers must use the return code
  (`if at_lock ...; [ -n "$_AT_LOCK_HELD" ]` misses timeouts).
- Release is implicit: the kernel drops the lock when the process exits. Consumers
  are short-lived; `at_unlock` is only for scripts doing long work afterwards.
- Background children spawned while holding the lock must `unset _AT_LOCK_HELD` and
  close fd 8 (`exec 8>&-`), otherwise they believe a dead ancestor holds it.

### `at_long_begin/at_long_end/at_long_busy`

Marker `/tmp/5gmodem/atlong_<tty>` with the PID of a long AT operation; `busy` if
the PID is alive and the file is younger than 6 min, otherwise the stale marker is
removed.

## `detect.sh`: AT port of the active modem

Prints the AT tty of the active modem, or nothing.

- **HiLink without AT ports** (`kind=hilink`): print the section `at_port` only if
  it exists (debug mode adds ports), otherwise print nothing. Without this early
  exit the generic scan returned another modem's port (`/dev/ttyUSB3` of FM350
  while a Huawei was active), so console/SMS/USSD silently talked to the wrong
  modem.
- **ModemManager-owned modem**: MM drives its ttys. If we open the same port with
  `sms_tool`, MM's commands time out ("port ttyUSBn timed out") and MM cannot
  enable/connect: registered but no IP. The AT lock only widens the window, since
  it holds the port for the whole poll. The rule lives in `mm_at_allowed`
  (quirks.sh), shared with the pinned poll and `bands.sh`; before, detect.sh was
  silent while the others took the port from the registry. Exception: an already
  connected modem (enable/connect is what breaks; without a port mmcli has no
  temperature, CA, band/mode control; DW5821e under MM lost temperature and CA).
- Manual `device` wins, unless it is a send-only port (`tty_poll_unsafe`) or in the
  send-settle window (`poll_send_settle`); such a stale value is deleted.
- `auto_port=0` and no manual device -> empty.
- Pinned `at_port` is used only if it is a char device (`-c`, not `-e`: a dead tty
  path leaves a phantom regular file created by `sms_tool`, see `atprobe.sh`),
  belongs to the active modem's USB path (`tty_belongs`; ttyUSB numbering is
  global and shifts on re-enumeration, with two modems ttyUSB1 easily belongs to
  the neighbour), and is poll-safe. The section's `at_port` is synced if empty.
- A pinned port belonging to another modem is deleted under `ucitx.lock` with our
  own commit. A bare `uci delete` lands in the shared `/tmp/.uci` staging and the
  next foreign commit (resolve holds its lock and builds sections for up to ~12 s)
  swallowed it into its transaction. Commits are skipped (not forced) when the lock
  is busy: pinning repeats on the next call.
- Positive cache `/tmp/5gmodem/atport_<path>`: a silent DIAG port costs ~4 s in
  `atprobe`, scanning to the 3rd port ~8 s per call, and detect runs several times
  per page load. Cache check is "tty is a char device and belongs", **not**
  `atprobe`: on an MM modem atprobe sends AT into MM's port and waits ~4 s.
- Negative cache (`.neg`, 20 s): detect is called by 5gmodem.sh, bands.sh,
  simslot.sh, esim.sh on every poll; re-scanning silent ports (2 s x N ttys x 2
  passes) pushed rpcd into its 30 s timeout, the UI hung and the Network page went
  empty. A modem without an answering AT port (some 05c6:9025 generic) is treated
  like HiLink: empty answer, metrics from QMI/cache.
- Herd guard: on a cold page open requests arrive in a burst; one process probes
  (`flock -n` on `detect.lock`, fd 7), the rest answer empty and the next poll uses
  the pinned port. The uci commit uses **fd 6**, not 7: re-opening fd 7 would close
  the OFD and silently drop the herd guard (same trap as in atlock.sh).
- Probe order: `model` pass (answers `AT+CGMM` with a model) over non-dial ports,
  then `send` pass over send-only ports (marks `poll_send_mark`), then `at` pass
  (any `AT` answer). Multi-port modems (FM350 = 7 ttyUSB) answer plain `AT` on some
  auxiliary/DIAG ports that give no metrics; picking the first `AT` responder gave
  "IP present, metrics and logs empty".
- The **dial port is never used** for metrics: xmm/atc carry data on that tty
  (`drop_dial_port` in lib.sh; `mkiface` chooses `DIALPORT != METRIC_AT`).
- The found port is pinned in uci (survives reboot; the fast path then skips the
  ~8 s cold scan).
- Nothing answered: write the negative cache and return empty; do not fall into the
  generic scan (it probes ports of both modems, same 30 s wall).
- Generic scan (no active modem): skip USB-UART adapters (`usb_is_modem`): sending
  AT to a foreign device behind a serial cable is garbage in its console.
  `atprobe.sh` is time-bounded (~4 s) and rejects DIAG/NMEA ports; the old
  `gcom check.gcom` had no timeout and blocked ~35 s on a silent DIAG port.
- The old `mmcli -m any` was replaced: it returned whichever modem MM listed first
  and required MM, while our modems are deliberately hidden from MM.

## `registry.sh`: modem registry

One answer to "which modem, which port, who owns it". Before, each consumer
resolved it on its own (`active_modem` referenced 127 times, global
`@5gmodem[0].at_port/device/network` read 65 times, 5 writers), and the answers
diverged:

- USSD went to the wrong modem: port from "the active one", page modem from
  `sms.ussdport` (30.07);
- the session watchdog compared one modem's address with another's interface
  (global `network` and `at_port` change non-atomically on tab switch);
- band changes went to the neighbour (`bands.sh` uses the active modem, the port
  came from another);
- the watchdog saw one modem of four: path -> section -> iface + AT port was only
  assembled for the active modem.

Verbs: none/`all` (JSON array), `path <usb>`, `port <tty>`, `active`, `paths`,
`flat`. `path` for a modem not on the bus answers `{}` (callers must tell "no such
modem" from "script failed").

- **No own cache**: built on `listmodems.sh` (its cache: 0.01 s warm vs 0.17 s
  cold) plus uci. The field set changes on switch and settings edits; another cache
  layer is another way to serve a stale binding.
- listmodems output is read **once** at start. A previous lazy memo `_lm()` never
  worked: `_jq` runs inside `$(...)`, the assignment died with the subshell, so each
  record ran listmodems 9 times (registry took 260-410 ms with two modems).
- uci snapshots (`uci5g_snapshot`, `ucinet_snapshot`) are used: `uci show` and
  `uci get` both cost ~3.5 ms on 25.12.5 (WH3000), configs are small, two dumps pay
  off by the third read and a record does eight. An earlier measurement against
  snapshots (153 -> 179 ms per record) was taken on top of the listmodems bug.
  `paths` skips the snapshots (used in warm-up loops).
- Two `jsonfilter` calls per record instead of nine: scalars in a fixed order
  (listmodems always prints vidpid/product/serial, empty value keeps the order;
  arrays are not mixed in since missing keys print nothing), then all three port
  lists at once, split back by name shape: `/dev/tty*` and `/dev/wwan*at*` serial
  (PCIe/MHI AT nodes; without that pattern the AT port of a PCIe module was counted
  as control, `at_port` cleared and bands were not read), other `/dev/*` control,
  no `/dev` HiLink netdevs.
- `at_port` from the section is accepted only if it is in this modem's tty list and
  poll-safe: the setting goes stale (modem moved, composition changed) and "wrong
  modem" bugs came from there.
- **vid:pid is live from the enumeration**, uci only as fallback (modem gone from the
  bus, section still needed for parking/"saved profiles"). Sections are named by
  USB path, so a different modem in the same slot inherits the old vid:pid until the
  next resolve, and `bands.sh` picks `modem/usb/<vidpid>` by it: band commands of
  another vendor. `product` (USB descriptor) is needed for `<vidpid><Product>`
  profile lookup; the uci model is normalised and not suitable.
- `serial` is live and only a valid one (`serial_of` drops placeholders like
  `0123456789ABCDEF`); FM350 has none, identification then uses IMEI and path.
- Strings via `json_esc`: a product with a quote broke the JSON.
- `owner`: `mm` if iface proto is `modemmanager` and `mm_exclude != 1`, `none`
  without an iface, otherwise `us`. Our AT polling breaks MM's connection setup;
  the rule used to be repeated in four places.
- `flat`: one line per modem, `path section iface proto at_port owner`, empty fields
  as `-` (positional `read` would shift). Shell readers (session watchdog) spent
  more time on per-field `jsonfilter` calls than on the check itself. Fields never
  contain spaces.

## ModemManager gates (`quirks.sh`)

### `mm_at_allowed <path> <section>`

Return 0 = may use the AT port, 1 = not now (MM still bringing the session up),
2 = never (fragile firmware). On 0, `MM_AT_PORT` may hold a dedicated port the
caller must use instead of the registry port.

- `mm_at=1` in the section: always allowed (explicit user setting, the "AT polling under
  ModemManager" checkbox).
- `mm_at_fragile` vid:pid: denied, unless a dedicated port exists.
- proto `mbimp`: allowed when the iface is up or `/tmp/5gmodem/mbimp_sim_<iface>`
  exists.
- Others: only when `mmcli` reports `connected` (enable/connect is what breaks;
  without the port, temperature, CA and antennas are lost - those are why the
  MBIM/QMI profiles exist).
- Self-contained on purpose: `bands.sh` calls it before sourcing `lib.sh`. MM index
  comes from the same 1-minute cache as `mm_owns_path` and `bands.sh`.

### `mm_at_fragile <vidpid>`

Firmwares where foreign AT traffic in parallel with MM drops the data session:
Foxconn T77W968 = Dell DW5821e / DW5821e-eSIM (413c:81d7, 81e0, 81e4, 81e6, 81d8,
0489:e0b5, e0b4, 1bc7:1911). Two independent reports of "works for hours, open the
tab, link restarts": issue #13 (10.08.2026; the ownership check only covered proto
!= modemmanager) and 12.09.2026 on 2.4.68 with proto modemmanager, where the
addressed poll (`for=<path>`) took the AT port from the registry without any gate.
These modems get their card from mmcli; temperature/carriers come back with
`mm_at=1`.

`mm_at_fragile <vidpid> <path>` also marks as fragile:
- SoC modems behind remoteproc (`/sys/bus/platform/devices/<path>/remoteproc`, Qualcomm MSM8916 `qcom-soc` and the like). On 27.10.2026, a direct AT probe of `wwan0at0/at1` with MM holding the modem crashed the MSS firmware twice (`smd_dsm_memcpy.c:297 Invalid packet size`).
- Any modem whose section has `at_fragile=1` (`uci set 5gmodem.m_<path>.at_fragile=1`), for firmwares found to misbehave in the field.

The card for these modems comes from mmcli and QMI through the MM proxy (`qmicli -p`).

### Dedicated AT port (`mm_dedicated_at`, `mm_tty_reserved`)

DW5821e has two AT ports and MM grabs both; polling either one disrupts MM. Finding
of 17.09.2026 (413c:81e0): if one port is hidden from MM, polling it does not touch
the session.

1. While no port is chosen: if MM lists two or more `at` ttys, store the USB
   interface number of the last one (`mm_at_if`) and vid:pid (`mm_at_vp`) in the
   section (under `ucitx.lock`). Nothing else changes now.
2. On the next port appearance (reboot, reconnect) the hotplug handler
   `tty/26-5gmodem-mmreserve` releases that port from MM right after the event
   (`mm_tty_reserved`): MM 1.24 drops a port that is still pending/being probed
   without rebuilding the modem.
3. The port is given to the poll only while MM really does not hold it (absent from
   MM's port list).

Only fragile modems with proto `modemmanager`/`mbimp`, `no_at != 1`. MM's port list
is cached 1 min (`mmports_<path>`).

### `sms_send_port <path>`

FM350 (0e8d:7127): SMS is sent only via the tty of USB interface 06 (ttyUSB3);
polling uses another port (issue #47: `ttyUSB3` hangs under polling).
