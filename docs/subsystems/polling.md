# Metrics poll (`5gmodem.sh`)

`root/usr/share/5gmodem/5gmodem.sh` produces the metrics snapshot (one flat JSON
object, ~100 fields) shown on the Network page, the status widget, the
"internet priority" cards and in telemetry. It resolves which modem to poll,
takes the per-modem poll lock and the per-port AT lock, sends one batched AT
"core" request, parses CREG/CEREG/COPS/CPIN/CSQ/CNUM/CIMI, sources the vendor
profile `modem/<usb|pci|soc>/<vidpid>`, fills the gaps from ModemManager
(`mmcli`) and QMI (`qmicli -p`), normalises operator/IMEI/IMSI/ICCID/model, writes
identity back to uci, and publishes the snapshot atomically to
`/tmp/5gmodem/metrics_<key>.json`.

Related docs: `polling-at-access.md` (AT lock, port detection, registry, MM
gates), `polling-quirks.md` (`quirks.sh` per-modem facts).

## Verbs

| Call | Behaviour |
|---|---|
| `json` | Full poll, write snapshot. Under lock; if lock busy and snapshot younger than 3 s, serve it. |
| `cached [ttl] [for=<path>\|<path>]` | Serve snapshot if younger than `ttl` (default 15 s), else poll. Also stamps `/tmp/5gmodem/page_active` (unless `SW_BG=1`). |
| `peek [<path>]` | Last snapshot of any age (`age` = real age, `9999` if stamp lost) or `{}`. Never touches port or lock (~10 ms). |
| `hist [<path>]` | Signal history ring (`hist_<key>`), points younger than 600 s, time given as age. |

`for=<path>` anywhere in the arguments means "answer only for this modem"; if it
is not the polled one the answer is `{"error":"not_active",...}`. Every snapshot
carries `path`, so foreign data is detectable even without `for=`.

## Which modem is polled

- `_POLL_AM` is read from `active_modem` **once** per run. Re-reading it in several
  places (snapshot key, section, IMEI stamp) mixed two modems when the user
  switched tabs mid-poll (IMEI of one modem written into the other's section).
  Every later step uses `_POLL_AM`, never `active_modem` again.
- `POLL_MODEM=<usb-path>` (env) or the path argument of `cached`/`peek`/`hist`
  pins a non-active modem. `sessionwatch` uses it to pre-warm snapshots of all
  modems so a tab switch has data within ~40 ms instead of an empty card for ~1 s.
  The browser cannot set env (`fs.exec`), hence the argument. The page sends
  `for=<path>`; until 31.07.2026 the backend ignored it, which was the source of
  "data of two modems mixed".
- Pinning is accepted only if the path exists in sysfs **or** in `registry.sh
  paths`. The sysfs check was added because the registry is slow under load and
  pinning silently fell back to the active modem, so both tabs showed one modem.
- Under `_PINNED` every fallback to global `@5gmodem[0]` keys (port, interface,
  device) is disabled: they describe the active modem. Writes go only to the
  polled modem's section (`$_hl_sec` / `$AMP_SEC`) and its interface.
- `_ACT_AM` keeps what the page considers active; helpers that only know the
  active modem (`simslot.sh`) are skipped when `_POLL_AM != _ACT_AM`.
- `QMI_TARGET_PATH` is exported so QMI gates in `lib.sh` judge the polled modem.

## Snapshot, lock and freshness

- Snapshot, stamp, poll lock and history are keyed per modem (`snap_key`, shared
  with `sessionwatch.sh`). A single global snapshot/lock made modem B wait for A
  and served A's data on B's tab for seconds after a switch.
- One writer, many readers: a contended poll took 13.4 s instead of 3.8 s. The
  poll lock is a directory (`mkdir` is atomic on any FS). Stale lock: stamp older
  than 40 s (or dir older than 1 min without stamp) is removed.
- Age is computed from `/proc/uptime`, not `date`: busybox `find -mmin` only has
  minute resolution and wall clock jumps on routers without RTC.
- Snapshot is written to a temp file and `mv`-ed; it is published only if it
  parses (`jsonfilter -e @.modem`), so a half-dead poll never replaces a good one.
- Do not write the snapshot through a pipeline (`( cat <<EOF ) | tee`): via rpcd
  the call hung until rpcd's 30 s timeout (4/4) because the extra process kept
  stdout open; from a console it took 0.64 s.
- `serve_cache` rewrites `age` and `alias` on output. The alias changes instantly
  on a button but the snapshot lives up to 10 s; refetching the whole snapshot for
  a label would be an extra modem poll. The alias is escaped like `_sanv` (quotes
  broke JSON) and matched as a whole line (`[^"]*` stopped at an escaped quote).
- `trap _cleanup_tmp EXIT` removes PID-suffixed temp files on any exit: rpcd kills
  calls at 30 s and leftovers accumulated forever in tmpfs on 32-64 MB routers.
  Subshells do not inherit the trap under busybox ash.
- **Never put `#` comments inside the `emit_snapshot` heredoc** (or any JSON block
  printed as-is): the line goes straight into the response and breaks parsing
  ("quoted object property name expected", all metrics empty). Happened twice.

### `cached` flow

- Removed: "serve-stale + background refresh". It was worse than a synchronous
  poll: data lagged a whole cycle (CA during a speedtest appeared 3-5 s late), and
  the background poll held `LOCKDIR` while waiting up to 10 s for `at_lock`, so
  stale data aged past 20 s during modem switches. A synchronous poll is ~1 s now
  (static cache + port-alive marker).
- Cold start (no snapshot): start a background `json` poll (with fds 8/9 closed)
  and wait for the snapshot to appear (1 s steps, busybox has no fractional
  sleep). The partial snapshot published after the AT core (see below) makes it
  available in ~2 s. After 20 s answer `{"error":"busy"}` rather than falling into
  a second 20 s wait that would hit rpcd's 30 s limit ("XHR error").
- Lock held by someone else: serve whatever snapshot exists; with none, wait up
  to 20 s for the other poller.

### Partial snapshot

On a cold start (no snapshot file) the snapshot is published right after the AT
core is parsed, before the vendor profile runs. It is not published when a
snapshot already exists: that would temporarily blank model/IP for readers. After
the partial emit `_SNAP_PREPARED` is reset because the profile may change config.

### `_snap_prepare` / `_sanv`

- Values that do not change during a poll (iface proto, APN, PDP type, kind,
  `mm_exclude`, vid:pid, MM running, XMM capability) are computed once; inside the
  heredoc every `$(...)` is a subshell, and the snapshot is printed twice on cold
  start.
- `_sanv` sanitises into copies `_J_<name>` without command substitution: ~98
  forks per snapshot cost 134 -> 86 ms (07.08.2026). Originals are not touched
  because profiles distinguish empty from `-` (`[ -z "$RSRP" ]`). Forks only for
  values with control chars or `"`/`\` (user text like alias/APN with quotes made
  the snapshot invalid, so it was never published and every tick did a full poll).
- Control characters 0x00-0x1F are stripped: DW5821e left a raw control char in a
  signal value and broke `JSON.parse` ("Bad control character"). Before, every
  value went through `tr` (71 calls, ~0.17 s); now only when `case` finds one.
  `printf` instead of `echo` because values like `-n` are eaten as flags.
- `usb_enum`/`usb_flaps`: count of `usb <path>: new` and disconnects in the last
  10 min from `dmesg`. "Endless initialization" reports (L860 on a Cudy TR3000, 7
  re-enumerations in 12 min) were a modem dropping off the bus, not a hung dial.
- `conn_status`: while not connected, last meaningful `netifd: <iface> (` log line
  (dial progress written by proto handlers); `notify_proto`/`Permission denied`
  noise filtered out.

## Special paths before the AT poll

- **Tethered phone / USB router** (`is_iphone`, or `kind=tether` and not a known
  modem): no AT; reports tether state, netdev, IP. For `tether=router` with a
  gateway, telemetry is read from the device (`remote_tele`) and turned into a
  normal snapshot (`backend=router`).
- **MM takeover pause** (`/var/run/5gmodem-mm-inhibit/<path>.pause`, set by
  `bands.sh mmtakeover`): serve the snapshot and do not touch the modem. Polling
  the same cdc-wdm/AT port stretched MM's re-probe past its timeout (MM did not
  bring the modem up within 60 s with the page open).
- **HiLink** (`kind=hilink`) without an AT port: metrics come from the modem's web
  API (`hilink.sh json <path>`), same JSON shape, own cache (default TTL 5 s). The
  path is passed explicitly: the web API poll takes tens of seconds and the active
  modem may change meanwhile (model/IMEI went into another modem's section). If the
  API fails, serve the cache only if younger than 30 s, else "Device not found"
  (issue #2: HiLink numbers stayed "live" for hours). A HiLink stick switched to
  debug mode has AT ports and is polled normally (TAC, band, USSD are only there).
- Empty stamp files must be validated (`case ''|*[!0-9]*`): `$(( uptime - ))`
  aborts the whole script. Empty stamps appear when a process is killed between
  create and write; stamps are written via temp + `mv` for the same reason.

## Port selection

- Not pinned: `detect.sh` (see `polling-at-access.md`).
- Pinned: `at_port` from `registry.sh path` (already checked against this modem's
  ports). If the owner is `mm` or the iface proto is in the `proxy` class, the
  port goes through `mm_at_allowed` (quirks.sh), same gate as `detect.sh` and
  `bands.sh`.
  History: until 01.08.2026 a pinned MM modem had `DEVICE=""`, which made pinned
  polling stricter than normal (Compal under MM lost throttling/temperature in
  the neighbour snapshot). That was relaxed, then on 12.09.2026 the "works for
  hours, open the tab, link restarts" class came back on DW5821e/T77W968 (proto
  modemmanager) because the registry port bypassed the `detect.sh` gate. Now
  `mm_at_allowed` is the single rule.
- `at_dialer_busy`: the gcom dialer of xmm/atc does not respect our queue, so while
  it runs we yield immediately (serve snapshot or `{}`).
- `at_lock $DEVICE 10`, failure -> serve snapshot or `{}`. Stale but consistent data
  is better than mixed answers that cannot be told from "modem silent".
- **Port must belong to the polled modem**: `detect.sh` may return any answering
  tty, i.e. a neighbour's. A HiLink Huawei (no AT ports) became active before its
  section got `kind=hilink`, the poll read FM350's model and wrote it into the
  Huawei section. Check against listmodems' `tty` list of `_POLL_AM` (directly,
  not via registry: registry cost ~150 ms per poll). If the modem is absent from
  listmodems, do not judge (unusual composition). If present with no tty (e.g.
  05c6:9025 in QMI), reject: exactly then `detect.sh` likes to return a
  neighbour's port. Presence = non-empty `path` field.
- **Port-alive marker** (`portok_<key>`, 30 s): skip `atprobe.sh` if the same port
  answered `+CSQ` in the core batch within 30 s; removed if the core times out.
  `atprobe` costs a round-trip per poll, up to 2 s on a silent port.
- `no_at=1` in the section: no AT at all (`_MM_OWNS=1`, `_SN_NOAT=1`).
- `mm_owns_path` while the iface proto is not `modemmanager`: config can disagree
  with reality, and the old "AT unless proto=modemmanager" gate missed it.
  DW5821e/T77W968 dropped the data session on every tab open (issue #13). The
  port then goes through `mm_at_allowed` like everywhere else and is cleared only
  when it refuses; the mmcli block fills the card either way. Until 3.9.8 it was
  cleared unconditionally, so Compal under `mbimp` lost CEITHERM and `AT+BINFO`.

### Port did not answer `atprobe`

Often a false negative (port briefly busy, slow mobile page load, short
re-enumeration). Serve a snapshot younger than 30 s instead of flashing "modem
not found". Exceptions that continue without a port: proto `modemmanager`,
`no_at=1` while on bus, `mm_owns_path`.

- Self-heal: if `_POLL_AM` is missing from listmodems, run `modemswitch.sh resolve`
  in the background at most once a minute. Hotplug does not notice removal of a
  non-modem device (phone in tethering mode); the page then stuck on an empty
  card (03.08.2026).
- Modem on the bus with tty ports but silent (hung `sms_tool` in D state, busy
  modem): serve snapshot of any age or `{"error":"Device not found","onbus":"1",
  "hasports":"1"}`. Before, the page showed the "phone without AT ports" text for an
  FM350 with seven ttys (14.09.2026).
- `onbus` lets the page distinguish "stuck on the bus" (power-cycle helps) from
  "removed".

## `sms_tool` wrapper

`sms_tool` is redefined as a shell function, so every call (here and in sourced
profiles) is guarded:

- **No timeout in sms_tool**: on a hung or busy port it blocks ~35 s while holding
  `at_lock`, the whole page waits ("data not updated 33/56 s"). The wrapper kills
  it after 8 s and returns what was read.
- Empty `DEVICE` -> no-op (MM-owned modem; empty `-d` also breaks argument parsing).
- fds 8 (AT lock) and 9 (hotplug lock) are closed for `sms_tool` and the watchdog.
  Otherwise the orphaned watchdog `sleep` held the lock's OFD up to 8 s after the
  poll exited, and every following poll waited ~8 s.
- **Not a bare `wait`**: a port that put `sms_tool` into D state ignores kill and
  `wait` would block forever (T99W175 05c6:9025, 17.08.2026: rpcd killed the call
  at 30 s and the process kept `at_lock`). Poll with a ~10 s ceiling and abandon an
  unkillable child. Step 0.05 s if `sleep 0.0` works (busybox FANCY_SLEEP; the
  step is paid on every call, ~10 calls per poll). Without fractional sleep a
  `sleep 8` watcher races the call through a pipe and the first to finish wins.
- **Static cache**: identity commands (CGMI/GMI, CGMM/GMM, CGMR/GMR, CGSN/GSN,
  CIMI, CCID/ICCID/QCCID, GTPKGVER) sent as a single command are served from
  `${STATIC_CACHE}_cmd_<CMD>` byte for byte. Only 3 of 61 profiles used
  `at_static`; the rest re-asked 6 identity commands every 5 s (0.5-1 s on L850).
  Not cached: batches (`;`), vendor `@` commands, `-D` calls (different output
  format), calls before `STATIC_CACHE` is set. Only valid answers are cached (no
  ERROR, real content, >= 14 digits for IMEI/IMSI/ICCID): one stolen answer would
  poison a cache that never expires.
- **Trailing `OK`** is dropped only for identity commands (liveness probes need
  it). Profiles join answers with `tr -s "\n" | xargs`, so `OK` ended up in values:
  "Quectel OK RM520N-GL OK", firmware "RM520NGLAAR01A06M4G OK" (RM520N-GL,
  05.09.2026). Some firmwares separate lines with CR only, so CR/LF are normalised
  before the filter. A second pass, `strip_ok_var` on MODEL/FW/NR_IMEI/NR_IMSI/
  NR_ICCID/PHONE after the profile, catches the single-line-with-CR case.

## AT core batch

One round-trip: `AT+CPIN?;+CSQ;+COPS=3,0;+COPS?;+COPS=3,2;+COPS?;+CREG=2;+CREG?;
+CEREG=2;+CEREG?;+CNUM;+CIMI`. Separate calls cost 0.5-1 s each.

- **Fallback for modems that cannot digest the long batch**: MeigLink SLM770A-R
  answers only the echo. Then the same commands are sent in groups of 2-3.
- The failure signal is **missing `+CREG:`/`+CEREG:`**, not missing `+CSQ`: per
  spec an error aborts the rest of the batch. Altair ALT3800 (NTLM-500,
  10.09.2026) answered CSQ, then failed on a later command; operator, registration
  and IMSI stayed empty forever under the old check.
- Empty answer = port hung, skip the fallback (7 more commands x 8 s).
- Empty core with a non-empty `DEVICE` = port hung mid-poll: drop the alive marker,
  serve the previous snapshot and exit (frees `at_lock`). Not for empty `DEVICE`
  (MM modem): exiting there froze the snapshot forever (log "poll of  is stuck"
  with an empty port name was the signature).

## Parsing

### Operator name

- `+COPS` format 0 may be UCS2 hex (Compal RXM-G1: `beeline` ->
  `006200650065006C0069006E0065`). A hex-only string with length % 4 == 0 is
  decoded as UCS2 to UTF-8 for the whole BMP, including Cyrillic (`Т-Мобайл`),
  otherwise the MVNO name was replaced by the host network (Tele2). busybox ash
  needs `$((0x..))`, not `16#`.
- Numeric names: the `case` pattern `*[!0-9\ ]*` must contain the space. ModemManager
  gives `250 11`; without the space every string with a space counted as a real
  name and the number never resolved to "Yota" (no operator icon either).
- Reversed numeric names (`11 250`, MNC first; DW5821e on Yota) are matched too.
  In the mmcli prefill the order is detected by length (MCC is always 3 digits).
- Junk names are only digits/spaces. Checking for "no Latin letters" treated
  Cyrillic names as junk.
- Operator cache per IMSI (`operator_<IMSI>`): MVNO modems alternate between their
  brand and junk; `mccmnc.dat` knows only the host network. Only names that came
  from the modem are cached (not from `mccmnc.dat`, which would overwrite it with
  Tele2). IMSI keys it so a hot SIM swap does not show the old operator.
- **SPN** (EF_SPN 6F46, `AT+CRSM=176,28486,0,0,17`) cached per IMSI, negative
  cache 4 min. Formats: quoted on Compal, unquoted on Telit LM960 (`+CRSM:
  144,0,00542D...`), with spaces after commas on FM350 (`+CRSM: 144, 0, "00..."`,
  SPN was always empty there and eSIM brands like "GigSky" were lost). First byte
  is the display condition, name until `FF`. SPN is applied at the very end because
  vendor profiles (Telit `1bc71040`) overwrite COPS. If SPN equals the
  `mccmnc.dat` name (case-insensitive) the database spelling is used, otherwise
  SPN is an MVNO brand.
- Country suffix is removed by `operator_clean` ("MegaFon RUS" -> "MegaFon"), also
  for the netpri cache file.
- Home vs visited: home MCC/MNC from IMSI (try 6-digit then 5-digit key;
  `mccmnc.dat` is CRLF, strip `\r`). Home name: SPN, else IMSI lookup. In roaming
  COPS stays visited and `home_operator` carries the home brand; at home the brand
  (SPN, then `opname_brand` from apn.list) replaces the host network. Under MM IMSI
  is only known after the mmcli block, so `opname_brand` runs again there.
- MVNOs that report the host PLMN and SPN (Ekomobile on MTS: 25001, "MTS RUS")
  are told apart by APN: `opname_by_apn` matches the iface APN against
  `opapn:<glob>:<name>` lines in apn.list, applied after `opname_brand`, at home
  only.
- `/tmp/5gmodem/op_<iface>` (read by `netpri.sh`) gets the home operator in
  roaming (the widget identifies the SIM, not the network). `op_cache_iface` only
  writes when the AT port belongs to the iface's modem; with no port it resolves
  the iface from `_POLL_AM` (issue #10: two EM7455 under MM showed the active tab's
  operator on both cards).

### Registration

- SIM state is kept separate from `REG`: CREG parsing reuses `$T` and used to
  overwrite REG, so "SIM not inserted" never reached the card.
- PIN2/PUK2 do not block data and are not reported as "PIN required".
- `+CME ERROR` code is matched whole: prefix matching mapped `100` (unknown
  command, common inside a long batch) and 107/112/132/148 to "no SIM".
- CEREG overrides CS status 0/2/3/4/6/7/empty when CEREG says 1/5. FM350 registers
  CS as "SMS only" on every operator while data works; LTE-only data modules have
  no CS domain at all, and vendor profiles skip all cell metrics unless `REGOK`.
- `REG_CS` keeps the original CS status: USSD needs the CS domain; on MeigLink
  SLM770A-R `AT+CUSD=?` answers `(0-2)` but every request is silent with `CREG
  2,6`. The USSD tab uses it to tell "modem can't" from "network won't now".
- SIM state is used as REG only if neither CS nor EPS gave a status; otherwise a
  CME error in the batch hid a live EPS registration.
- `+C5GREG?` is asked when not registered by CREG/CEREG.
- **Domestic roaming is not roaming**: codes 5/7/10 become 1/6/9 when the network
  MCC equals the SIM's MCC. MVNO T-Mobile (250-62) on Tele2 (250-20) reports
  `+CREG: 2,5` while billed as home; Huawei's own API says `cellroam=0`; Telit and
  Huawei with the same SIM disagreed. National roaming in Russia was abolished in
  2017.

### Mode / TAC / CID

- `MODE_NUM` from `+COPS: <any>,2,...`: manual selection (`AT+COPS=1,2,"PLMN"`) left
  it empty and L850/L860 profiles parsed no cell metrics.
- Fallback AcT from `+CEREG` (last field); `+CREG` is often empty on LTE-only.
- TAC from `+CEREG` is already hex. An old version stored `printf %d` into
  `TAC_HEX` and left `TAC_DEC` empty.
- `CID 0` means "not filled" (SIM7100E: `+CREG: 2,1,E936,0`); it is replaced from
  QMI. Same for `EARFCN 0` (T99W373 in NSA prints `channel:0`, issue #15).
- `ENBID = CID / 256` for LTE/5G only (28-bit ECI = 20-bit eNB + 8-bit sector;
  Telit 92686855 -> 362058 sector 7; same as `cell4cellsUrl`). Computed before QMI
  (so modems without cdc-wdm get it) and again after `_qmi_supplement` (under MM the
  CID only arrives from QMI).

### MSISDN

`+CNUM`: take the quoted field that looks like a number (5+ digits); UCS2 alpha
contains letters. Type 145 adds `+`. Fallback `mmcli own-numbers` (Compal is
silent on `+CNUM`).

## Interface and IP

- Interface comes from the polled modem's section first; the global
  `@5gmodem[0].network` is only a fallback and never when pinned. They diverge
  (not every writer of `active_modem` updates it) and the card showed the
  neighbour's IP (FM350 active, card showed Huawei's 192.168.43.2).
- `ifstatus` once per poll (was ~6 calls x ~0.5 s). Re-read if `SEC` changed.
- IPs come from the l3 device: umbim/MBIM puts addresses on virtual `<iface>_4` /
  `<iface>_6` children. ubus children are the fallback.
- HiLink in debug mode: the iface IP is the modem's LAN (192.168.43.2); the real WAN
  address comes from `AT+CGPADDR`.
- `protocol` = uci proto of `SEC`; previously a loop variable `$PROTO` leaked
  (modemmanager shown as mbim).
- Last-resort iface discovery: first interface with proto
  modemmanager/qmi/mbim/ncm/wwan; dangerous on multi-modem, hence all earlier steps.

## Vendor profile

- vid:pid is needed even without a tty (MM modems: Compal reads mmcli/qmicli
  without an AT port): from tty, SoC node, or sysfs of `_POLL_AM`.
- `IFS` is saved/restored around the sourced profile: 16 profiles set IFS to
  newline and never restore it; that silently broke the FM350 temperature outlier
  filter (`read` put the whole line into the first variable).
- Board `zte,mf289f` always uses `modem/usb/19d21485`.

## ModemManager prefill and fill

Before the profile (`_pf_*`): when proto is `modemmanager` or MM owns the modem
and REG is empty, map mmcli values to AT codes (`home`->1, `roaming`->5, `5gnr`->13,
`lte`->7, `umts`->2), take operator name/code (needed by the 4cells cell-map
button), and show MM's primary port as `cport` (display only; `DEVICE` must stay
empty or the wrapper would send AT into MM's channel). Profiles gate on REGOK and
MODE_NUM; without the prefill all serving-cell metrics were `-`.

After the profile (only empty fields):

- Index of the **polled** modem (`modemswitch.sh mmindex <path>`); the pathless
  form returns the active modem and leaked its operator into neighbour snapshots
  (issue #10).
- Signal % from mmcli only without RSRP (pessimistic: Compal 12 % at RSRP -106).
- Registration words mapped to 3GPP codes (they were passed through as words and
  the page never matched them); failed/locked states mapped to SIM messages.
- Model: section name first (normalised "Compal RXM-G1"), then `model_alias` of
  mmcli's raw USB name ("VOS_5G").
- Firmware from `modem.generic.revision`: DW5821e prints it split,
  `T77W968...GC.013\n050  1  [May 31 2021...]`; `AT^VERSION?` shows the real value
  `T77W968.F1.0.0.5.2.GC.013.050`, so the first field of line 2 is appended with a
  dot. If MM has no revision (Compal SG500M2-X with a Beeline config: `--`),
  `qmicli --dms-get-software-version` (e.g. `ZX56_643_0.78-12`), cached per IMEI.
- IMSI/ICCID from the SIM object (`mmcli -i <n>`).

## QMI supplement

Functions: `_qmi_supplement`, `_qmi_refresh`, `_qmi_fill`, `_qmi_kick`.

Generic NAS queries answer in the same format across vendors (verified on Compal
RXM-G1 and Telit LM960A18), so neighbours etc. live here, not in one profile.
Works regardless of iface proto (`qmicli -p` through the proxy). The profile wins:
only empty fields are filled. Modems without cdc-wdm (FM350 RNDIS) skip it.

- cdc-wdm is the polled modem's own (`wdm` from listmodems, skipping `wwan*at*`),
  **no fallback to `/dev/cdc-wdm0`**: it fed the neighbour's (Telit) neighbours
  into FM350's files.
- **Gate `qmi_channel_free`**: with iface proto `qmi`, netifd's uqmi talks to the
  same cdc-wdm directly and does not know about qmi-proxy. Two owners mix answers:
  netifd hung at "Waiting for network registration" with "Failed to parse message
  data", interface pending, kernel NETDEV WATCHDOG resets; symptom was "works after
  install, after the first reboot never connects again, fixed by removing the
  package". Under MM the proxy is shared and no gate is needed.
- `_poll_chan_free`: `qmi_channel_free` checks the **active** modem's interface; for
  a pinned non-active modem the same check is done here (iface up/pending or a
  running uqmi/umbim on its device -> refuse).
- Cache-first: fill from files younger than 300 s immediately, refresh in the
  background when older than 25 s, at most one refresher per 5 s (time lock, a
  dead refresher cannot wedge it). The refresh subshell closes stdio on the
  subshell (rpcd fd-detach rule) and fds 8/9. Key and cdc-wdm are passed in so a
  modem switch during the ~700 ms of qmicli does not file data under another key.
- Sources: `--nas-get-rf-band-info` (bandwidth; in 3G the bandwidth is a class
  `wcdma-5` and the band `wcdma-*` + UARFCN), `--nas-get-tx-rx-info=lte` (TX power
  only while transmitting; RX chains), `--nas-get-signal-info`,
  `--nas-get-lte-cphy-ca-info` (CA), `--nas-get-cell-location-info` (TAC, CID,
  neighbours, UMTS cell, timing advance).
- RX chains: firmware drops signs (RSRP `100.3 dBm`), restored. `-256.0 dBm` on a
  tuned chain means "no measurement" (Compal RXM-G1 25.08.2026: chains 2/3 at
  exactly -256); only -160..-20 is kept. Diversity verdict from live chains
  (> -130): 2 -> `2rx`, 3-4 -> `4rx`, 2-4 measured with 1 live -> `noant`; fewer
  than two measured -> no verdict.
- CA from `lte-cphy-ca-info`, not `rf-band-info` (the first attempt produced junk
  like `,|1,100` on both modems and made two cards identical, 31.07; the reader
  accepts only `digits,...`). Only activated SCCs; deactivated = configured but
  asleep. Issue #11: Telit LN960A16 under MM showed one carrier while qmicli saw CA.
- **Band from EARFCN, not the `LTE Band` field**: T77W968/DW5821e report band+1 in
  `cphy-ca-info` (1348 -> eutran-4, 300 -> eutran-2, 6300 -> eutran-21), seen after
  2.5.0 when QMI started filling cards under MM. `earfcn2band` (3GPP 36.101 table
  5.7.3-1) is the shared table; profiles used to carry divergent copies.
- SCC RSRP/RSRQ are matched from the Interfrequency neighbours by PCI+EARFCN (SCC1
  B40 PCI 378 EARFCN 38950 -> neighbour with RSRP -119.9); no source gives SCC SINR.
- Serving PCI from the neighbour with `serving:1` (Compal NSA: `cphy-ca-info`
  returns `InformationUnavailable`).
- **SINR from QMI overrides the AT value** (the only unconditional override). On
  EP06-E (07.08.2026, two cells) `+QENG` SINR was 2-7 dB off (24 vs 21.4, 8 vs
  -6.2); the older formula `x*0.2-20` was worse, `+QCSQ` gave 9.5 dB at RSRQ -15.
  Cross-check on three modems showed QMI is the common reference; RSRP/RSRQ from
  AT are accurate and kept.
- Timing advance: `distance = TA_us * 150 m`, coarse (~150 m steps), only in
  RRC-connected.
- RAT change: if mode is not 3G but `.b3g` is non-empty, the 3G files are stale
  (TTL 25 s) and are cleared. In 3G with an empty `.b3g` (CS fallback window for
  USSD ~10 s is shorter than the TTL) one synchronous rf-band-info / cell-location
  call (~0.2 s) is made and cached; steady LTE/3G never pays it.
- In 3G the honest level is RSCP; it is also used as RSSI.
- Max rate: `--wds-get-channel-rates`, not `--dms-get-capabilities` (a firmware
  constant: HP lt4120 Cat 4 and Quectel EC21 Cat 1 both say 100/50; WDS gave 150/50
  and 10/5). Directions by magnitude, not label: EC21 swaps TX/RX. Cached per IMEI
  (tmp files survive a modem swap in the same slot, a path key would give the new
  module old numbers). awk `%.0f`, busybox `%d` is int32. Queried and cached only
  in LTE/5G: WDS reports the limits of the current RAT, and a Compal RXM-G1 polled
  on 3G right after boot cached HSPA+ 42/6 while LTE gave 400/150.

## AT CA fallback (`_at_ca_supplement`)

Runs after QMI, only when no SCC was found and no `_CA_FROM_PROFILE` (set by
profiles that already asked, e.g. Telit FN990 - otherwise a single-carrier modem
paid an extra AT round-trip every TTL). LTE/NR only. Answer TTL 20 s, negative
cache 10 min for modems that do not know the command.

- `AT^CA_INFO?` (Foxconn, Telit LN940, Compal, one format). Issue #15: T99W373's
  `^DEBUG?` lists only pcell while `^CA_INFO?` lists all:
  `PCC info: Band is LTE_B66, Band_width is 15.0 MHz` / `SCC1 info: ... LTE_B5` /
  `PCC info: Band is NR5G_N77, ...`. The NR carrier in NSA is also a "PCC info" line
  and may have no section header, so carriers are classified by band name
  (`LTE_B`/`NR5G_N`). Listed carriers are active.
- Telit: `AT#CAINFOEXT?` (`PCC- BandClass: 126, RX_CH: 3048, DL_BW: 5, ...`). Band
  from RX_CH via the EARFCN table; BandClass is a Qualcomm enum that diverges from
  "class - 119" for late bands and is only a fallback. DL_BW is an enum
  0=1.4 1=3 2=5 3=10 4=15 5=20 (FN990A28 live: 20/20/20/15/10 MHz). SCC with STATE
  != 2 skipped. The 5G block is skipped: no live sample, wrong band is worse than
  none.

## Signal percentage

- CSQ from RSSI when there was no AT batch: `CSQ = (RSSI + 113) / 2`, clamp 0..31,
  percent `CSQ*100/31`, so the same modem shows the same level in MBIM (AT alive)
  and MM (Compal 22 vs 19 before).
- Final percent: `sig_percent` (lib.sh) from the metrics of the current RAT wins
  over `+CSQ`. 25.08.2026: CSQ 23 = 74 % at RSRP -109, RSRQ -19, SINR 0 and 1 Mbit/s;
  RAT thresholds give 27 %. CSQ is used for 2G and modems that give nothing else.
- SIM7600E returns `+CSQ: 99,99` on LTE.
- FM350 under-reports `+CSQ`; its profile (`0e8d7127`) overrides with a weighted
  RSRP .5 / SINR .3 / RSRQ .2 formula.

## AMBR / QCI

With a port and registration: `AT+CGACT?` (first 3 active CIDs) and
`AT+CGEQOSRDP=<cid>`, highest DL AMBR wins; cached 300 s or until the IP changes.

## Identity

Model, IMEI, IMSI, ICCID, SIM slot.

- Model fallback from listmodems (normalised name from descriptor/vid:pid table)
  when nothing was read (DW5821e-eSIM 0489:e0b5 had no profile). Tabs and card stop
  disagreeing.
- `_model_vendor_ok` (lib.sh) against section vid:pid; model of a device with
  neither tty nor wdm is dropped (a phone in tethering mode became "FM350",
  03.08.2026; the guard referenced `$AMP`, which does not exist in this file, until
  12.09.2026). `model_refine` adds the variant letter from the USB product
  ("Quectel EP06" + "EP06-E"). `model_alias` normalises any source (raw "SIMCOM
  SIM7100E" from AT overwrote "SimCom SIM7100E").
- Model/IMEI are recorded only if `tty_usbpath $DEVICE == _POLL_AM`. Generic
  Qualcomm vid (05c6) is not judged by the vendor check, and `model_vp` was stamped
  with the same foreign value. Empty owner also refuses (port gone during
  re-enumeration; 01.08.2026 Compal flap during a speedtest: section 2-1.4 got the
  neighbour's IMEI, then the interface stamp too).
- Model written with `model_vp` = current vid:pid (see `modemswitch.sh resolve`).
  The USB descriptor is often useless (EC21 = "Android", SimCom one vid:pid for
  7100/7600/8200; only `AT+CGMM` distinguishes).
- IMEI: profile, else `at_static imei AT+CGSN` with pattern; digits only (echo
  `AT+CGSN` leaks without SIM); else `$IMEI` from mmcli (the variable was never
  connected to `NR_IMEI` before).
- IMSI: digits only. 18 profiles strip the echo with `${O#AT+CIMI }`; without a SIM
  the modem returns only the echo and the tooltip said "IMSI: AT+CIMI" (MV31-W,
  04.08.2026). Fallback `SIMID` from the batch (Telit LM960 profile has no CIMI).
- ICCID: Telit answers only `AT+ICCID`, most others `AT+CCID`. Trailing `F` padding
  is stripped here for all three sources (profile, mmcli, AT fallback): only Dell
  profiles did it, so the number appeared "with and without F" depending on whether
  AT or MM answered.
- `at_static` validates against a pattern before caching: an answer of another
  command (`at#bnd=? #BND: (0),(0-11,17,18),...`) once landed in the IMEI file and
  stuck forever.
- Static cache key is the USB path of the **port in hand** (`tty_usbpath
  $DEVICE`), not `active_modem`: two MV31-W (05c6:90d5 at 1-1.2 and 1-1.3); a tab
  switch changes `active_modem` and `at_port` non-atomically; a poll in that gap
  read IMEI from the old port and cached it under the new key, both profiles
  showed one IMEI. Reset on IMSI change; on "SIM not inserted" only SIM-related
  entries are dropped.
- Active SIM slot when the profile gives none (only Quectel profiles do; Telit
  LM960 has two): `simslot.sh status`, cached 60 s (QMI ~1 s). Not asked for a
  non-active modem: simslot.sh only knows the active one, the neighbour snapshot
  got the active modem's slot and the lock request for another port failed
  ("at_lock: refused" every second warm-up round).

### IMEI stamp and modem swap

- Stamp only if `active_modem` is unchanged since the start (`_active_path ==
  _POLL_AM`) and the port belongs to the polled modem.
- Refuse an IMEI that another **present** modem's section already holds (same rule
  as `ensure_section`).
- Section IMEI differs -> `imei_prev`, new `imei`, `imei_changed=1`, log; nothing is
  deleted (background poll must not silently drop someone's APN/interface; the
  settings page offers re-creation). Two identical modems swapped between ports
  are invisible to the vid:pid check in `modemswitch.sh`.
- `imei_prev` is needed by `park_profile`, which runs a round later: by then the
  section already had the new IMEI and the old profile was parked under it
  (08.09.2026: EC21's APN/iface parked as `m_park_<lt4120 IMEI>`).
- Interface ownership stamp `network.<iface>.modem_imei` is corrected only when the
  iface's `modem_path` is this modem and the IMEI was not rejected.

## APN re-selection on SIM change

No hotplug event exists for a SIM change. The key is `apn_imsi` in the modem
section (survives modem reboot and `/tmp` cleanup): an eSIM profile switch does
`CFUN=1,1`, resolve clears `/tmp`, and the first poll saw an empty previous IMSI
and treated it as first boot (Tele2 eSIM enabled, APN stayed "tt" of T-Mobile;
both on the same host network, only IMSI shows the change). Skipped when
`apn_mode=manual`. Debounce 1 min, 30 min after `autoapn` gave up (it does not
write `apn_imsi` on failure; with a 1 min debounce it ran for days). Also drops
the simslot cache: only simslot's own `set` cleared it, a physical card swap kept
the old SIM type for 5 min. The background `autoapn` unsets `_AT_LOCK_HELD` and
closes the lock fd so it takes the lock itself after we exit.

## Signal history

On each published fresh snapshot with signal values, a line `uptime rsrp rsrq
sinr rssi pci earfcn band` is appended to `hist_<key>` (kept 240-260 lines).
Previously only the browser kept the history in sessionStorage: a new tab started
empty and stale snapshots (>= 30 s) added no points. Ages instead of timestamps:
router (no RTC) and browser clocks differ.

## Band helpers

`band3g` accepts a QMI class (`wcdma-2100`; Compal in CS fallback: `wcdma-2100` +
channel 10563) or a UARFCN. `band4g`/`band5g` default branches use an unquoted `*`;
a quoted `"*"` matched only a literal asterisk (no default branch at all).
