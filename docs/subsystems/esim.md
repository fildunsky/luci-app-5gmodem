# eSIM (eUICC) management

`esim.sh` drives the eUICC of the active modem through lpac (SGP.22): chip info, profile list, enable/disable/delete/nickname, download by activation code, and SGP.22 notifications. APDUs reach the chip either over AT (`+CCHO/+CGLA/+CCHC`, through our stdio bridge `esim-apdu-bridge.sh` or lpac's native AT driver) or over the cdc-wdm control channel (lpac's `qmi`/`uqmi`/`mbim` drivers). ES9+ HTTP to the SM-DP+ goes either through lpac's own curl or through the bridge (GNU wget/OpenSSL, curl fallback). `esimcaps.sh` holds the static list of eUICC-capable modems. The LuCI page is `htdocs/.../view/modem5g/5gesim.js`. SIM slot switching lives in `simslot.sh`, see [sim-slots.md](sim-slots.md).

Verbs: `status`, `status-cached`, `status-probe`, `recheck`, `dump`, `dump-cached`, `dump-free`, `enable|disable|delete <iccid>`, `nickname <iccid> <name>`, `download <code>`, `download-bg <code>`, `download-status`, `notifications`, `notif process|remove <seq>`, `flush`, `progress [reset]`, `reapply`, `netcheck <code>`, `setshow|sethttp|setapdu|setslot|getslot`, `httpinfo`, `apduinfo`.

## lpac binary layout

- lpac 2.3.x: binary `/usr/lib/lpac/lpac` plus driver plugins in `/usr/lib/lpac/driver`. The loader finds them via `LPAC_DRIVER_HOME` (our patch, OpenWrt strips RUNPATH).
- lpac 2.1.x: single file `/usr/lib/lpac`.
- Official OpenWrt package: `/usr/bin/lpac` is a UCI wrapper that ignores env and defaults to uqmi, so we call the real binary directly when possible. If only the wrapper is present, we still use it.
- Broken install (`LPAC_BROKEN`): the patched package cannot be installed over the official one (official ships `/usr/lib/lpac` as a FILE, ours needs a DIRECTORY). apk prints "failed to extract ... Not a directory", removes the binary, keeps the wrapper, and the package still counts as installed. We report this explicitly instead of "no eSIM"; fix is `apk del lpac; rm -rf /usr/lib/lpac /usr/bin/lpac` and reinstall.
- `http_local_drv`: lpac initialises its HTTP driver even for local operations and dies with "No HTTP driver found" if the requested one is absent. Some builds ship only `driver_http_stdio.so`; hard-coding `curl` broke chip info on MV31-W/T99W175. We pick whatever plugin exists.
- `httpinfo` exists because the old diagnostic (`strings /usr/lib/lpac | grep curl`) lied on the directory layout and also flagged a missing curl when the stdio driver (router does HTTP) is in use.

## Visibility vs. real probing

- `status` decides tab visibility statically (vid:pid list + "eSIM" in the model name, manual `esim_show` override wins). It must not touch the port: it is called on every page load and on modem switch, and the old CCHO probe took `at_lock` and starved metrics polling.
- `status-cached` answers instantly from the last good `status-probe` verdict (`/tmp/5gmodem/esimstat_<usbpath>`), or `{"unknown":1}`; the page then runs the real probe in the background instead of blocking `load()`.
- `_scache_get`: a positive verdict is kept indefinitely, a negative one only for 600 s. A negative answer is usually momentary (modem initialising, channel busy); it used to be cached forever and the tab kept telling the user to report the vid:pid.
- `status-probe` returns specific reasons: `nolpac`, `modemmanager`, `noeuicc`, `uplink` (channel held by a live connection, not cached), `slot` (physical SIM slot active, not cached), `takeover` (modem under ModemManager, consent needed).
- A port answering AT is not evidence of an eUICC; the probe must open a logical channel to ISD-R. Otherwise every modem (e.g. Telit LM960) got the tab.
- Negative "noeuicc" is cached only when the probe ran under our own `at_lock`; a probe on a busy port may lie (the tab disappeared for 15 minutes on an FM350 with a real eUICC).
- `recheck` drops the status, dump and port caches and re-probes; without it a modem that was silent on the first probe stayed "no eSIM" forever.
- `dump-cached` returns the last valid dump instantly so the list is clickable on return to the tab; written atomically only when the profile list code is 0, removed by every mutating verb.

## esimcaps.sh: eUICC-capable list

The list is a hint for tab visibility and for labelling an unvisited second slot "eSIM" in `simslot.sh`. Showing the tab needlessly is cheap (there is a hide toggle), hiding it when needed is worse.

- `0e8d:7127`/`0e8d:7126` Fibocom FM350-GL (verified, eUICC present).
- `2cb7:0104/0105` Fibocom FM150/FM160; `2c7c:0800/0801` Quectel RM500Q/RM520N-GL eUICC variants; `2c7c:0900` RG500Q.
- Foxconn T99W175 / Dell DW5930e (SDX55): `05c6:9025`, `05c6:90d5`, `1e2d:00b3`, `1e2d:00b7`, `1e2d:00b8`, `1e2d:00b9`. `05c6:90d5` and `1e2d:00b7` are shared with Compal RXM-G1 / Thales MV31-W, which may lack eSIM.
- `0489:e0f0` Foxconn T99W373 / Thales MV32-W: eUICC is always soldered (datasheet: "with an integrated Thales eSIM inside"), but the model name has no "eSIM", so the name heuristic would miss it.
- `413c:81e0` (DW5821e-eSIM, customer=3) and `0489:e0b5` (T77W968 with eSIM): listed explicitly because under ModemManager the model arrives as "4116"/"DW5821e" without the suffix.
- Name heuristic (`*eSIM*`): models with eSIM in the name have the eUICC soldered; the non-eSIM variant of the same vid:pid does not carry the label.

## APDU backend selection

`apdu_backend` returns `at|bridge|qmi|uqmi|mbim`.

- Manual `esim_apdu` wins, but `qmi`/`mbim` are checked against the real cdc-wdm driver (`_wdm_driver`): a stale manual `qmi` on a modem now in MBIM composition (or the reverse) makes lpac fail `euicc_init`. If the modem has no cdc-wdm at all (FM350 in fibocom/xmm composition) a manual `qmi`/`mbim` is ignored and we fall back to `bridge`; this was a real report where the CCHO probe found the eUICC on ttyUSB1/ttyUSB3 while `qmi` was forced.
- Auto for `mbim|modemmanager|qmi` protocols: decided by the cdc-wdm driver, not the protocol name. Two T99W175 (`05c6:9025`) under ModemManager had their nodes on `qmi_wwan`; the mbim backend could not open a channel and the result looked like "no eSIM", although SDX55 reads the eUICC fine over QMI.
- Auto for AT-class protocols (fibocom/atc/xmm/ncm/3g/wwan) is `bridge`, not lpac's native `at` driver. The native driver was tried for faster downloads on FM350 with patched lpac 2.3.x, but its persistent `at_expect` buffer desynchronises on long CGLA chains: `es10b_prepare_download` stalled exactly 240 s twice in a row. The only download verified end-to-end on FM350 (Tele2) went through the bridge. Native `at` stays available via `esim_apdu='at'`.
- Old 2.1.x layout (no `/usr/lib/lpac/lpac`) supports only the bridge.
- `wdm_backend` (mbim/qmi/uqmi) skips the AT-only preamble (live port, `AT+SIMTYPE`, CCHC cleanup, `find_port`), otherwise QMI modems without AT ports failed with "no AT port".
- `apduinfo` prints backend, manual/auto, node and its driver for diagnostic reports; without it "euicc_init -1" gave no clue which transport was used.

## cdc-wdm node resolution

- `_is_wdm_node`: a char device is not enough; ttyUSB is one too, and `network.<iface>.device` holds the AT tty for atc/xmm/fibocom (seen: "cdc-wdm node: /dev/ttyUSB1" on FM350 in RNDIS). A real node is registered under `/sys/class/usbmisc` or `/sys/class/wwan` (`/dev/wwanXpYMBIM`).
- `esim_wdm` falls back to the single `/dev/cdc-wdm*` only when listmodems knows nothing about our modem and the node is not attributed to another modem. On a multi-modem router FM350 in RNDIS has `wdm: []` and the only node belonged to an EP06; we sent APDUs to the neighbour's chip.
- `euicc_probe_wdm` refuses to run with an empty device: lpac would pick its default node, again possibly another modem.

## Channel ownership

### ModemManager

- `_mm_owns_channel`: opening mbim-proxy on a cdc-wdm that ModemManager is using rebooted a T99W175 (two masters on the control channel). Diagnostics did not trigger it because they run sequentially; the page polls in parallel.
- Temporary takeover (`_mm_esim_take`): `mmcli --inhibit-device` is kept alive by a background process (inhibit lasts while the process lives; on kill MM rebuilds the modem and netifd redials). One takeover covers a batch of operations; a watchdog releases it after 90 s of eSIM idle. Costs ~1-2 min without internet through the modem; the UI asks for explicit consent.
- If MM has not assembled the modem and holds none of its nodes (`_mm_busy_on_dev` reads `/proc/<pid>/fd`), the channel is free and we proceed without inhibit instead of waiting 60 s per verb (some firmware is never assembled: "no primary AT port").
- The watchdog subshell must detach stdio, otherwise rpcd waits for EOF.

### umbim (kernel `proto=mbim`)

- `_wdm_owned_by_umbim`: umbim opens cdc-wdm directly, not through a proxy. Our mbim probe starts mbim-proxy on the same node, the proxy takes the channel, and the data session drops (Cudy TR3000 + DW5821e: "opening the 5gmodem page kills internet"). QMI is not gated: QMI multiplexes clients and SDX55 eUICC is reachable only over QMI.
- Ownership requires the interface to be up. Gating on `proto` alone blocked the probe on a down interface (no SIM, ifdown) and redirected eSIM to AT, which SDX55 does not support ("no eUICC-capable AT port" on MV31-W with interface down).
- `_mbim_or_at`: if umbim owns the node we use the bridge (AT), never the native AT driver.
- Read-only verbs answer `uplink busy` immediately instead of taking the lock and scanning every tty with CCHO (SDX55 has three tty, none answers), which used to hang for minutes and end with "no eUICC-capable AT port".
- `esim_active` caches the QMI slot verdict per node because the QMI query cannot run while netifd owns the node.

### Temporary uplink release

`_uplink_release` takes down the modem's own interface (from its `m_<path>` section, never a neighbour's) for mutating verbs (`download|enable|disable|delete|nickname|flush|notif|notifications|dump-free`), and `_uplink_restore` brings it back from the EXIT/INT/TERM/HUP trap.

- Without it SDX55 modems were stuck: once an eSIM profile brought the link up, the chip could no longer be managed.
- Two different conflicts: umbim owning cdc-wdm, and the fibocom dialer holding `at_lock` on the very AT port used for APDUs. With an empty eUICC there is no registration, the proto redials every ~70 s ("no network registration after 60s"), and the download never gets the port (FM350, EMPTY_EUICC, dozens of "at_lock: port /dev/ttyUSB1 busy longer than 10s").
- Decide by cause, not backend name: on an MBIM modem with a live link the backend is `bridge` precisely because umbim owns the channel; checking `at|bridge` first left the channel occupied and ended in "uplink busy" (MV31-W).
- An AT-class interface that is already up is left alone: dialing is finished, metrics queue politely, and it may be the only path to the SM-DP+.
- After ifdown we wait until netifd reports the interface down; umbim lingers a second or two.
- `dump-free` is an explicit user consent to release the modem for reading; a plain `dump` never takes the link down because it runs on every tab open.
- `ESIM_READONLY=1` (used by the diagnostics collector) forbids any uplink release. A report run reached "eSIM: notifications", the verb took the MV31-W interface down, and the redial hit a PIN2 trap; the user lost internet by pressing "collect report".
- `netcheck` returns `sole=1` when the modem carries the only default route: download needs internet mid-operation, and releasing the only uplink breaks it.

## MBIM slot mapping protection (SDX55)

On Qualcomm SDX55 (T99W175 / MV31-W / DW5930e) the eUICC sits behind SIM2. To reach it lpac may remap the executor slot to the eSIM; usually that slot is empty and SIM1 drops out, killing wwan just by opening the eSIM tab.

- Slot numbering: mbim slot 0 = SIM1, slot 1 = SIM2/eSIM. `mbimcli` is 0-based, lpac and our UI are 1-based (`_mbim_target_index`).
- `_mbim_skipmap`: `LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1` unless the target slot is already `active-esim`. A hard `1` made the eUICC unreachable after reboot on T99W175/MV31-W when the executor stayed bound to SIM1. Explicit `lpac.mbim.skip_slot_mapping` wins.
- Exact string comparison is mandatory: `inactive-esim` contains `active-esim`; substring matching let lpac remap to an empty slot persistently, and the SIM vanished until a manual `AT^switch_slot` (ZBT-Z8102AX + MV31-W). Same anchor in the QMI awk (`Slot status: active$`).
- Without `mbimcli` (it is optional) `_mbim_target_is_active_esim` asks QMI `--uim-get-slot-status` for an active slot with `Is eUICC: yes`; previously a missing mbimcli forced skip=1 and "euicc_init: -1" (MV31-W on WH3000 Pro).
- `active-esim` describes the card in the slot, not the executor binding: with SIM1 working and the eSIM in SIM2 the check says yes and the modem moves to SIM2. Hence `euicc_probe_wdm` always restores the mapping after the probe.
- `run_lpac` restores the mapping only when it was forbidden (skip=1). When allowed for an active eSIM, restoring makes the next operation start from scratch and the chip answers "euicc_init: -1" (verified on MV31-W).
- The approach is ported from a community MBIM-lpac build for T99W175.

### eUICC slot (`_mbim_uim_slot`)

- Accepts both `lpac.mbim.slot` and `lpac.mbim.uim_slot` (the lpac-build wrapper reads `uim_slot`).
- Without explicit config we use the modem's active slot from `simslot.sh`, not a hard-coded 2. A removable 9eSIM card lives in slot 1, and slot 2 returned "success, empty list" while the chip was readable.
- When slots cannot be read (channel busy with lpac/inhibit, modem rebuilding after a profile switch) we use the last successful answer (`/tmp/5gmodem/esim_actslot`, 60 min): switching a profile does not change the slot.
- `setslot` writes `uim_slot` into `lpac.mbim`, `lpac.qmi`, `lpac.uqmi`; it creates an empty `/etc/config/lpac` first because `uci set` silently does nothing without the file.

### mbim-proxy health (`_mbim_use_proxy`)

The proxy is mandatory when MM runs or our interface is up. Otherwise we probe it with a cheap `qmicli -p --uim-get-slot-status` and go direct if it fails, cached for 2 min. After `AT+CFUN=1,1` the proxy keeps stale descriptors and every request through it times out ("couldn't open the QmiDevice: Transaction timed out") while direct access works.

`euicc_probe_wdm` restarts a wedged mbim-proxy once (never for MM-owned channels): on Cudy TR3000 (DW5821e, proto=mbim) a hung proxy broke both the data session and the probe.

## Logical channel leaks (ISD-R)

The card has only a few logical channels. lpac opens one per operation and closes it on normal exit, but a killed lpac does not. After several aborted attempts the eUICC answers "no channel response received: SelectFailed" to everything.

- AT path: `AT+CCHC=1..N` before every lpac run (`run_lpac`), before `find_port`, and once in `find_port`'s second pass (`free_channels`). Verified on FM350: closing all channels revives CCHO without a power cycle. Closing is done once per scan, not per port: 8 commands x 2 s x 7 ports was over a minute.
- cdc-wdm path: `_wdm_free_channels` closes channels via `qmicli --uim-close-logical-channel=<slot>,<ch>` (works on MBIM devices via `--device-open-mbim`). MV31-W cannot power-cycle the slot (QMI "NotSupported") and needed two reboots before this existed.
- `run_lpac` (mbim branch) sends TERM first and waits 5 s before KILL, so lpac can close the ISD-R channel itself; channels are freed only if we had to kill.

## AT port discovery (FM350 and other AT modems)

- FM350 exposes SIM access (`+CCHO/+CGLA`) on only one tty, and its number changes on every USB re-enumeration. Other ports answer `AT` but swallow CCHO.
- `port_ok` probes with `AT+CCHO="<ISD-R AID>"` (default `A0000005591010FFFFFFFF8900000100`, override `lpac.global.custom_isd_r_aid`) and closes the channel. Probing with `lpac chip info` on a wrong port sent CGLA, hung 20-40 s and leaked a channel per try until the eUICC stopped answering.
- FM350 answers CCHO with a bare channel number (`1`) instead of `+CCHO: 1`; both forms are accepted (same as our lpac patch `0002-...bare-CCHO`).
- Probe timeout is 2 s on the first pass (a port with eUICC answers instantly; 6 s x 7 ports froze the page), 6 s on the second pass after freeing channels.
- The port cache is per modem path (`esim_port_<path>`). A single shared cache made a single-SIM SIM7600 report eSIM because a neighbouring FM350 had one on `/dev/ttyUSB1`.
- `find_port` and `live_port` consider only tty of the target modem (registry / listmodems by USB path); `detect.sh` output is tried first only if it belongs to this modem. Otherwise `at_lock`, the liveness check, `AT+SIMTYPE?` and the CCHO probe could all hit the neighbour.
- The xmm/atc dial port is excluded (CCHO goes into the data channel and kills the session, seen on L860-GL with ttyACM0), unless it is the only tty. Logic mirrors `drop_dial_port` in lib.sh; esim.sh deliberately does not source lib.sh, so helpers like `at_query`/`qmicli_p` are not available here and calls to them silently did nothing in the past.
- Sierra (`1199:*`): no CCHO/CCHC scan. On EM9190 the probe wedged the SIM subsystem until the card was physically reinserted; use QMI/MBIM.
- `esim_active`: `AT+SIMTYPE?` is Fibocom-only. Other vendors are asked via QMI UIM for an active slot with `Is eUICC: yes` (MV31-W: "Physical slot 2: Is eUICC: yes, Slot status: active" while SIMTYPE is silent).
- With the physical SIM slot active the ISD-R is unreachable on every port; `status-probe` returns `reason:"slot"` (from `simslot.sh status`) so the page offers a switch instead of "report your vid:pid".
- `at_bounded` wraps `sms_tool` (no timeout of its own, ~35 s on a silent port). The timer subshell must detach its fds, otherwise the orphan `sleep` keeps the caller's stdout open and rpcd/cgi-io waits for EOF.
- The AT path takes `at_lock` for the whole lpac session: metrics polling hits the same FM350 port, and concurrent access broke the native driver ("Device not responding to AT commands", CGLA without answer). `_prelock` avoids releasing a lock held by a parent.

## stdio bridge (esim-apdu-bridge.sh)

lpac runs with `LPAC_APDU=stdio` and/or `LPAC_HTTP=stdio`; both multiplex one ndJSON stream distinguished by `type`.

```
lpac -> bridge (stdin):  {"type":"apdu","payload":{"func":"...","param":"hex|null"}}
                         {"type":"http","payload":{"url":"...","tx":"hex","headers":[...]}}
                         {"type":"lpa","payload":{...}}   final result
bridge -> lpac (stdout): {"type":"apdu","payload":{"ecode":<n>[,"data":"hex"]}}
                         {"type":"http","payload":{"rcode":<n>,"rx":"hex"}}
```

HTTP bodies are hex both ways (`driver/http/stdio.c` in lpac). Usage: `esim-apdu-bridge.sh <at_port> <result_file> [ca_bundle] [livelog]`.

- Why the bridge exists: lpac 2.3.0's direct AT driver hangs on FM350-GL (persistent `at_expect` buffer desync, 20 s per command). The stdio backend of lpac 2.3.0-fm350-fix (fixed `json_request` in `stdio.c`) and lpac 2.1.x read stdin correctly. Same idea as the EasyLPAC wrapper on Windows.
- Plumbing in `run_lpac`: bridge reads lpac's requests from a FIFO and writes answers into a pipe to lpac's stdin; lpac's stdout goes to the FIFO. The bridge exits on the `lpa` line, lpac gets SIGPIPE, the pipeline closes immediately.
- Completion is polled with `kill -0`, not `wait`: busybox reaps the pipeline subshell badly (zombie + 40 s hang).
- With `LPAC_APDU=at`/`mbim` the bridge still sits in the pipeline to serve HTTP and capture progress; its apdu branch is never hit, so it does not compete for the tty.
- mbim with `LPAC_HTTP=stdio` must also run through the bridge. It used to run lpac directly: local operations worked, but download wrote `{"type":"http"}` to stdout with nobody answering ("HTTP transport failed", empty progress log; MV31-W with a test profile).
- Every non-apdu/http line is appended to the result file and to `LIVELOG` (`/tmp/5gmodem/esim_progress.log`) so the UI shows progress while it happens; the result file is PID-named and invisible to the UI.

### APDU over AT

- `logic_channel_open`: `AT+CCHO="<AID>"`, `+CCHO: N` or bare `N`. On failure close channels 1-4 and retry once: a leftover channel makes CCHO fail and lpac aborts the whole operation with `euicc_init` although the chip is fine (trace `CCHO ... ch=-1`, then an outer retry succeeded). Retrying here saves a full retry round, which for download costs an attempt on the operator's server.
- `logic_channel_close`: param is a hex byte, converted with `printf '%d' 0x..`.

### CGLA length is in hex characters

`AT+CGLA=<ch>,<len>,"<apdu>"`: FM350 expects `<len>` as the number of hex characters (`${#param}`), not bytes. With the byte count the modem rejects the command without any answer.

- An empty CGLA answer is a lost exchange, not an empty response (a real answer always contains SW1SW2): the port was taken by the dialer, the modem re-enumerated, or a parallel reader ate the answer. One retry after 1 s.
- Still empty: report `ecode:-1`. Reporting `ecode:0` with no data made lpac keep sending APDUs into a dead channel for minutes and end with a bare `es10b_prepare_download`.
- The TRACE line is timestamped (two runs stalled 240 s on `es10b_prepare_download` and without time it was impossible to say which APDU hung) and the raw answer is folded to one line (sms_tool output contains blank lines that split the trace).

### ES9+ HTTP

- Why: OpenWrt's libcurl is built with mbedTLS, which rejects any unknown critical X.509 extension (-0x2080 "X509 - Unavailable feature"). The "GSM Association - RSP2 Root CI1" root carries critical Certificate Policies (OID 2.23.146.1.2.1.0), so SM-DP+ servers presenting GSMA CI chains (rsp.truphone.com, rsp-eu.redteamobile.com, ...) are unreachable; adding the root to the bundle does not help because mbedTLS cannot even load it. Servers with ordinary web certificates work, hence "some profiles download, others don't". GNU wget is linked with OpenSSL and passes with `certs/gsma-ci.pem`. mbedTLS also cannot do RSA-PSS used by some SM-DP+; the page tells the user to install wget-ssl.
- `http_backend`: `auto` = bridge if wget and our GSMA root exist, else curl. If curl is chosen but the build has no curl plugin, we switch to stdio + CA bundle.
- `ca_bundle` concatenates system CAs and the GSMA root (wget takes only one `--ca-certificate`), rebuilt when either source is newer.
- busybox wget does not know `--method/--body-file/-S/--content-on-error` and prints its help instead of a request; the help text ended up as the error reason. With busybox wget we fall back to curl and log it; GNU wget remains preferred.
- `-nv`, not `-q`: `-q` also suppresses TLS errors, so the certificate fallback never triggered and every unverifiable chain ended as a synthetic 500 (mno-0b.esimservices.com). `--content-on-error` is required: ES9+ sends meaningful JSON in 4xx/5xx.
- Certificate fallback: if no HTTP status and stderr mentions certificate/issuer, retry with `--no-check-certificate`/`-k`. lpac's own curl backend sets `CURLOPT_SSL_VERIFYPEER=0`, so this is not weaker than stock; without it test SM-DP+ (sysmocom TS.48, GSMA Test CI) break. Profiles are protected cryptographically at the eUICC level, not by this TLS.
- Transport failure (DNS/TLS/timeout) is answered with `rcode:500` so lpac does not hang, and the real reason is logged as `httpx` with `transport:failed,why:...`. The reason is taken from the saved stderr of the first attempt, not from a new bare wget call (on busybox it printed help into the report).
- gzip bodies are decompressed by signature `1f 8b`, not by header (some servers compress without `Content-Encoding`). Otherwise lpac says "Not JSON" on an honest HTTP 200 (smdpplus.ripsim.com, `getBoundProfilePackage`, five identical failures).
- Each response logs `json`, `truncated` (starts with `{`, does not end with `}`: server did not close, wget saved a partial body) and the first 16 bytes in hex, because lpac's "Not JSON" alone does not distinguish HTML, gzip and truncation.
- ES9+ error body: SGP.22 servers put GSMA codes into `statusCodeData`, often with HTTP 200 and `functionExecutionStatus.status="Failed"`, so detection is by content. Only the FIRST error per session is saved to `<result>.es9err`: the following `cancelSession` often returns a secondary error ("8.1/6.1 eUICC: Verification Failed") that would hide the real one ("8.2.6/3.8 Matching ID: Refused"). The bridge never truncates `.es9err` on start; `esim.sh download` clears it once before `do_lpac`, so it survives the internal retries.

## Retry policy (`do_lpac`)

- Success is judged only by the final `"type":"lpa"` line. Every progress line carries `"code":0`, so grepping the whole output treated failed downloads as success and the retry never ran.
- Default 2 attempts; download on qmi/mbim/uqmi gets 5. Long APDUs (authenticateServer, loadBoundProfilePackage) on SDX55 fail without a clear reason and the same profile installs "on the fifth try".
- No retry for protocol errors from the server (`Not JSON`, `Not Object`, `HTTP status code error`, `HTTP transport failed`): five rounds of identical "Not JSON" took six minutes and left the chip unresponsive. Exception: the last `httpx` line has `truncated:1`, which is a broken transfer worth retrying.
- No retry for `es9p_*` failures with non-empty data: that is an SM-DP+ decision (e.g. "MatchingID is refused", code already used).
- `iccid_already_exists_on_euicc` is our own success: the package was written but the answer was lost on a previous attempt; reported as `already_installed`.
- Between attempts: AT/bridge drops the port cache and rediscovers; cdc-wdm backends free channels via QMI and, for downloads, reinitialise the card by cycling the vendor slot (`AT^switch_slot=<alt>`, 5 s, back, 8 s; T99W175/MV31-W numbering 0 = SIM1, 1 = eSIM). After a failed download the chip answered "euicc_init: -1" to every retry and closing channels did not help; slot cycling is cheaper than a modem reboot.
- The same slot cycle runs once after a final download failure, so the next read works without a reboot.
- A `retry` progress line (`data:"n/max"`) is appended to the live log so the UI shows the attempt number.

## Download flow

- `download-bg` starts `esim.sh download` as a detached worker and returns at once; the page polls `download-status` (`running`, final output, `idle`, or a synthetic error if the worker died). uhttpd's cgi-exec caps synchronous calls at 60 s and the slow FM350 eUICC needs many seconds for the final Store Data. Watchdog is 600 s.
- `progress reset` clears the live log before the start; otherwise the UI could read the previous run's steps before `download` truncates the file.
- `netcheck` runs before the lock and eUICC gate: it is about the router, not the chip. It used to sit after the gate, and a stuck chip made the page claim "no internet" for a router the user was remotely logged into. It checks the SM-DP+ host from the activation code (`LPA:1$HOST$ID`), then `generate_204`. The UI no longer warns on "SM-DP+ did not answer": the check used the built-in curl, which always fails on GSMA CI servers.
- GSMA codes from `.es9err`: v3 `statusCodeData` (`subjectCode`/`reasonCode`/`message`/`subjectIdentifier`/`errorCode`), v2 flat `errorCode`/`errorDescription`. The text replaces `data` of the last `lpa` line only (replacing the first match hit a progress line). The server text is untrusted: `| & " \ CR LF` are removed and length is capped at 200, because `|` broke the sed expression (empty output), `&` inserted the match, and quotes/backslashes produced invalid JSON. Duplicate text from lpac is not repeated.
- First profile auto-enable: if download succeeded and the chip now has exactly one profile and none enabled, enable it (by `isdpAid` if it is 32 hex chars, else ICCID). Never switch away from an already enabled profile.

## After a profile switch

- `esim_reset_after_switch_maybe`: per SGP.22 the eUICC issues REFRESH and the modem should reread the card, but some firmware does not, so the old profile keeps working. `quirks.sh: esim_reset_after_switch` decides per model; reset (`reboot_modem.sh hard`, `AT+CFUN=1,1`) costs USB re-enumeration and about a minute offline, so it is not done where REFRESH works (FM350-GL). SDX55 has it as a standard step.
- The reset runs in the background with fds detached on the subshell; rpcd's 30 s limit would otherwise return "XHR error" on a successful operation.
- The response gets `payload.reset:1` (`_ers_echo`) so the page does not start a second `reboot_modem.sh hard`. Two parallel resets each ran their own "wait for disappearance, ifdown, ifup" watcher and interleaved.
- `reapply` waits until the modem answers AT again (up to 120 s) and does ifdown/ifup; otherwise netifd keeps the old lease and route (interface up with the previous operator's address, no traffic). Interface name lookup: global `network`, then the modem section `m_<path>`, then any interface with `iface_proto`.
- `flush` returns lpac's real answer; a constant `code:0` made "Send all" report success with no network.

## Locking and temp files

- `/tmp/5gmodem/esim.lock` is a directory with the owner PID. Closing the page mid-operation used to leave the lock and everything answered busy for 6 minutes; a dead owner is now taken over immediately; a lock without a PID file (old version) still expires after 6 min.
- The EXIT trap removes `/tmp/5gmodem/esim_*.$$` (res/loop/mloop/at/wdmprobe, including FIFOs): we are routinely killed by rpcd at 30 s or by our own watchdogs, and tmpfs leaked a file per aborted tab view. KILL skips the trap, so the script start also removes `esim_*.<pid>` older than 30 min (the longest operation fits into the 10 min watchdog).
- `setshow`/`sethttp`/`setapdu` write UCI and commit from the backend. Writing from the form via `uci.add`/`uci.save()+uci.apply()` did not stick for a modem without an `m_<path>` section, or left the delta uncommitted in "Changes". `setapdu`/`setslot` invalidate the status cache.

## LuCI page (5gesim.js)

- lpac output is several JSON objects line by line (progress stream, then final `lpa`). `JSON.parse` on the whole output failed, which produced false "cannot add profile" popups on success. `parseLpa` takes the last `lpa` object, else the last valid JSON line.
- Error text shows `payload.data` (the reason, e.g. GSMA codes) first and the failed step (`payload.message`) in brackets. Known GSMA pairs are translated; local lpac/eUICC failures in `es10b_load/prepare_*` get advice. Memory exhaustion is claimed only when the chip says so: generic "unknown" install failures used to be shown as "not enough memory" although they were long-APDU breaks cured by retry.
- Strings that may contain SM-DP+ or eUICC text (error data, profile names) are passed to `E()` inside an array to create a text node; a plain string is innerHTML.
- If the bridge logged `transport:failed`, its `why` (connection refused, DNS, TLS) is shown instead of lpac's misleading "HTTP status code error"; with the curl/mbedTLS transport the error suggests installing wget-ssl.
- `load()` uses `status-cached` and the sticky slot cache; the real probe runs in the background on the visible page. A background recheck runs only when no eUICC work is about to start (a parallel CCHO probe would fight the dump for the logical channel). The uci package must be loaded in `load()`: without it both selectors showed "Auto" and "Save" erased a mandatory manual `esim_apdu` on T99W175/MV31-W.
- Takeover under ModemManager requires explicit consent (remembered until leaving the page), because each session interrupts the modem's internet for ~1-2 min.
- `busy` from the backend means another dump/operation holds the lock; the page retries quietly under the same spinner (12 x 2 s covers an FM350 dump of ~10 s) instead of showing "operation failed: busy". The first `dump` often fails right after a session or CFUN; retries are silent.
- Mutating calls and downloads use `fs.exec_direct` (cgi-exec), not `fs.exec`: ubus RPC has a client timeout (`L.env.rpctimeout`, 20 s), and operations legitimately take longer ("XHR request timed out" while the backend was still working).
- Live log polling (1.2 s) pauses while the tab is hidden or the spinner is detached; a one-line `lpa` answer (e.g. busy) never replaces the accumulated log. Only the current step is shown, prefixed with the attempt number counted from `retry` lines.
- After enable/disable the page waits for the modem to actually disappear from and return to USB (`listmodems.sh`) before rereading; a "20 s and still present" threshold fired before delayed reboots (one modem disappeared at ~40 s) and the dump hit a dying eUICC. Fallback 90 s. Rereads use a wall-clock budget, not an attempt count: each dump on a half-up modem waits for lpac's 45 s timeout, so "60 attempts" turned into tens of minutes. The overlay is always removed, even if waiting throws.
- After enabling a different profile the page checks APN through the same server code as a physical SIM change (`modemswitch.sh`): in automatic mode autoapn applies it, in manual mode a suggestion is shown. A local APN table copy had already drifted from the original once.
- Translations use two whole sentences for enabled/disabled; composing "Profile %s" with a translated adjective breaks grammatical agreement in Russian and translators cannot fix fragments.
- The read progress bar uses the last successful duration per modem from localStorage (default 12 s, smoothed 50/50), grows to 95% and then says "longer than usual".
- Empty chip: some modems misbehave on a slot with no profiles at all (flapping, "modem failed", endless dialing); in the field a 9esim v3 card on T99W175 started working after loading any public test profile, so the page links the osmocom list of known test profiles.

### QR decoding

QR images are decoded entirely in the browser with jsQR (no zbar/quirc on the router, the image never leaves the browser). jsQR (256 KB) is loaded lazily on button press. It is UMD: if an AMD `define` is present globally it registers as a module instead of setting `window.jsQR`, so `define` is hidden while the script loads and restored afterwards. The file input is reset so selecting the same file again fires `change`.
