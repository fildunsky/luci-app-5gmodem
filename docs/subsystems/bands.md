# Band, network-mode and cell-lock management

`root/usr/share/5gmodem/bands.sh` is the single backend for the "Frequency management" block of the Network page. It picks the band profile of the target modem (`modemband/<vidpid>[<model>]`), assigns it the AT port of that modem, and exposes read verbs (`json`, `mgmtinfo`, `get*`) and write verbs (`setbands*`, `setmode`, `setall`, `setcelllock*`, `set5gmode`, `set256qam`, `setulca`, `mmsetbands`, `setmodemm`, `restorebands`). HiLink modems are handled by their web API, ModemManager-owned modems through `mmcli`, everything else through vendor AT commands in the profile. The frontend is `htdocs/luci-static/resources/view/modem5g/bandsui.js`, a module split out of `5gdetail.js` that owns all band-related state and draws whatever the backend returns. Vendor-specific command quirks live in [bands-profiles.md](bands-profiles.md).

## Target modem selection

- Default target is `active_modem` from uci. `BANDS_ACTIVE_MODEM` (USB path, e.g. `2-1.4`) overrides it for the whole script: profile, AT port, mask and interface reconnect are all computed for that modem. `restorebands` from hotplug relies on this; on a two-modem router the restored modem is usually not the one shown on the page.
- Read verbs (`json`, `jsonrefresh`, `mgmtinfo`, `getmode`, `getsupportedmodes`, `getcelllock`, `applyresult`) accept the USB path as `$2`, so the page addresses the selected tab instead of trusting `active_modem`. Write verbs use `$2` for the value and cannot take it.
- The vidpid/model binding comes from the registry (`registry.sh`), not a private `listmodems` query; duplicated lookups were the source of "action went to the wrong modem" bugs.
- Profile lookup order: `<vidpid><Product>` first, then plain `<vidpid>`. Some Quectel models only exist with a model suffix (`2c7c0306EP06-E`, `2c7c0800RM500Q-GL`), and looking up only `<vidpid>` left them without a profile on multi-modem setups.
- USB descriptors lie (EC21 reports "Android"). If neither descriptor nor plain vidpid matches, the script asks `AT+CGMM` and looks for a file whose model part starts with the answer (`EP06` matches `2c7c0306EP06-E`). This also separates EG06-E and EP06-E on the same `2c7c:0306`. This AT query is the last resort, so most modems never pay for it, and it goes to the AT port of the target section, not the global `at_port`.
- If the active modem is known but has no profile, the script reports "Unsupported". Falling back to another modem's profile would manage the wrong device.
- Profiles are sourced with IFS saved and restored (some profiles change IFS to newline and never restore it; same pattern as `5gmodem.sh`).

## AT port and gating

- Profiles never hard-code `_DEVICE`; a "fallback" tty in a profile is the port of another modem on a multi-modem router (Compal once pointed at the FM350 port and "proved" itself working). `_PROFILE_LOADED` tells "profile loaded, port assigned below" from "no profile".
- The port comes from the registry for the target section; the registry has already checked it against the modem's own ports. Falling back to the global `at_port` happens only when there is no explicit target; otherwise `_DEVICE` stays empty (`_PORT_OK=0`).
- The `at_lock` queue is taken on the section's `at_port` at start. If the actual write port differs (RW350-GL on Radxa: lock on ttyUSB3, writes on ttyUSB1), the lock is moved, otherwise writes raced the metrics poll and nested `at_query` calls failed with "already holding".
- Static lists (`getsupported*`, `getsupportedmodes`) are always reported, even without a port. This is the recovery path: a modem moved onto a band without coverage may have a hung AT port, and the user still needs the buttons to switch back. Only live reads (current bands/mode) are gated on `_PORT_OK`.
- Live reads are skipped (static lists stay) when:
  - a netifd dialer (gcom, proto `xmm`/`atc`) is active on the port: reads steal its answers and return garbage;
  - ModemManager actually owns the modem while the interface is not `modemmanager` (AT under MM drops the data session on DW5821e/T77W968), or `5gmodem.<section>.no_at=1` is set;
  - proto is `modemmanager` and `mm_at_allowed` (quirks.sh) refuses: fragile firmware never gets live AT under MM, others only with an up session.
- Explicit writes (Apply) still pass in the `no_at` and fragile-under-MM cases (`_MM_AT_STATIC`): a band change drops the session anyway, and on T77W968 `AT^SLBAND`/`AT^SLMODE` are the only levers. Before this, Apply failed with "Port not found" (RM551E-GL with `no_at=1`).
- `mgmtinfo` and single-value callers: `mgmtinfo` decides on its own and needs no AT port (a Foxconn 0489:e0b5 without a profile showed nothing although MM knew its bands). Other non-json single-value queries keep the classic port guard.

## Transport: `_BAND_VIA` and readonly/takeover

- `_BAND_VIA=at` (default): vendor AT commands, work on any proto.
- `_BAND_VIA=mmcli`: only through ModemManager (no AT band lock in firmware, e.g. Compal RXM-G1). On a kernel proto (`mbim`/`qmi`/`ncm`) MM is hidden by `mm-inhibit.sh` so it does not fight uqmi/umbim for cdc-wdm. Writing is impossible without MM: libqmi's CLI `--nas-set-system-selection-preference` has no band-preference TLV. Reading works through qmicli (`_qmi_current_bands` in `modemband/05c690d6`). So the lists are kept and the state is marked `readonly`/`takeover` instead of returning "Unsupported".
- For mmcli profiles a tty means nothing either way (Compal ttys never answer AT); live reads are gated on `mmcli` (or `qmicli` on kernel proto) availability instead.
- When the profile works through mmcli, the AT lock is released right after profile selection. Holding it for the whole operation monopolised a port the operation never touched; metrics then served stale snapshots (up to ~18 s frozen numbers).
- `_BAND_READONLY=1` in a profile (EM7345) shows the list with inactive buttons.

### MM takeover (`_needs_mm_takeover`, `_mm_takeover_run`)

Enabled by default (`5gmodem.@5gmodem[0].band_takeover=0` disables it; without it such configurations have no band control at all). Used for an mmcli profile on a kernel proto:

1. release cdc-wdm from umbim/uqmi;
2. pause inhibition of this modem only (`mm-inhibit.sh`) and start MM;
3. wait until MM re-probes and enables the modem (MBIM re-probe ~40 s, allow up to ~120 s; metrics serve cache meanwhile);
4. run the profile write (`mmcli -m "$_MMIDX"`);
5. unpause inhibition; `mmneed` stops MM; ifup the data interface, wait for up, check traffic (`_mt_traffic_ok`: ping health targets through the interface device) and bounce once if silent.

Verified on Compal RXM-G1 90d6 with proto=mbim: 62-71 s per cycle, four cycles in a row. The second consecutive takeover once returned a zombie session (WDS connected, address present, no packets) that one ifdown/ifup cured, hence the traffic probe. The old "MM does not stop" blocker was a false negative in `mmneed.sh` `_running` (it grepped `ModemManager --`, procd starts it without arguments). `$RES` points at `modemband/`, so helpers are addressed via a separate root `_R`; using `$RES/mm-inhibit.sh` silently failed and MM never saw the modem.

The UI gets `"takeover"` (buttons active, warning about a ~1 minute outage); `"readonly"` only with `band_takeover=0`.

## Writes

### Input validation

Values from the page go straight into AT commands, where a CR is command injection (`1<CR>AT+CPIN=...`). Every write verb validates with whitelist predicates from `lib.sh`, logs and returns the reason on rejection. Band numbers are also checked against what the modem itself declared (`getsupported*`, part before `:` since profiles emit `3` or `3:B3`): the modem rejects an invalid number silently. Found when the FM350 profile added 100 to an already prefixed 103 and GTACT rejected the whole command. If the modem did not answer the supported list, the check is skipped. `mmsetbands` accepts only `eutran-N|utran-N|ngran-N` joined by `|`, and rejects empty names (`|eutran-3`, `a||b`) which mmcli refuses as a whole.

### Background execution

All set verbs run in a background subshell with fds detached on the subshell itself (rpcd 30 s timeout; on MT7628 + SLM770A a synchronous write returned "XHR error" although bands were applied). Radio restart happens in the same subshell strictly after the write; when the UI called `reboot_modem.sh` itself, the restart overtook the write and the modem came back on the old set (SIM7600: removed B7 stayed active).

### Applying after a write (`_BANDS_APPLY_LIVE`, `_bands_after_write`)

Set by the profile, measured on live hardware:

- `1`: applied live, data context survives (Telit LM960: `#BND` rewritten in 4 s, same address, ping 3/3). Nothing to do. SIMCom also uses `1` because `CFUN=4->1` reverts the volatile mask.
- `reconnect`: applied live but the context breaks (FM350 GTACT: still registered, same address on eth2, ping 0/3). Reconnect the interface; much cheaper than a modem reboot.
- empty: not measured, soft reboot of the modem (slow but predictable).

### One Apply, one restart (`_band_write`)

The page sends LTE and NSA lists as two calls. Each used to restart the radio, and the second `CFUN=4` landed one second after the first `CFUN=1`, in the middle of dialing (RM551E-GL). Now writes are serialised by `/var/lock/5gmodem_bandwrite.lock`; each writer stores its token, releases the port, waits 5 s and restarts only if no newer write started; the pending flag carries success to the last writer.

### `setall` / `applyresult`

`setall mode=.. lte=.. nsa=.. sa=.. 3g=.. 2g=..` applies everything in one background job and writes progress to `/tmp/5gmodem/bandapply_<path>.res` (`running`/`settling`/`done`, `applied`, `failed` with `unsupported`/`rejected`/`mmtimeout`). A non-zero rc is still counted as applied if reading back shows the wanted set. `applyresult` returns that file.

### Persisting the choice (`_persist_bands`, `_persist_mode`)

Bands are stored as `save_band`/`save_band5gnsa`/`save_band5gsa` in the modem's section (FM350 and others reset the mask on reboot), `default` deletes the key. The network mode goes to `save_mode` (RM520N firmware resets `mode_pref` to AUTO on reboot and "LTE only" was lost). The user's intent (`$2`) is saved, not what ends up in the mask. A restore marker `/tmp/5gmodem/bandrestore_<iface>` is set at the same time: otherwise the ifup caused by our own reconnect wakes `restorebands`, which adds a second CFUN; two CFUNs in a row leave the FM350 PDP context unable to activate.

## Restore after reboot (`restorebands`)

Called from hotplug (`31-5gmodem-bands`) with `BANDS_ACTIVE_MODEM`. For each domain the saved set is normalised (numbers, sorted, unique) and compared with the current one; only differences are written, so modems that keep the mask in NV are untouched. An empty/non-numeric current value means the port is silent or the domain unsupported and is skipped (otherwise a false "different" causes a needless CFUN). Mode is restored the same way via `save_mode`.

`prepare` mode is called by net-hotplug as soon as the netdev appears, when the modem often does not answer AT yet: it waits up to ~30 s for a non-empty LTE mask (netifd is blocked after `NETDEV_MISSING` and will not dial until we ifup). It writes the mask and exits without CFUN/reconnect; rc 0 means "mask changed, do a cold dial, do not reuse the old bearer", rc 3 means "already matched, fast path ok". Normal mode applies per target: CFUN on that modem's port (skipped for `_BANDS_APPLY_LIVE` profiles, where CFUN reverts the mask) and `_reconnect_iface` of its interface. `reboot_modem.sh soft` is not usable here: it reconnects the globally active modem. The json cache is flushed only here (synchronous write).

## Reconnect after a radio cycle

Cell lock, 5G mode and restore go through `AT+CFUN=4`. The modem re-registers on its own but the PDP context stays empty and the interface down (FM350: `CEREG: 2,1`, empty `CGACT`, no internet). `_reconnect_iface` sets the restore marker, waits for registration (bringing the interface up earlier fails and puts netifd into backoff), then does a targeted `ubus call network.interface.<if> down` + `up`, with `ifup` only as fallback:

- `ifup` on some builds triggers a full config reload ("hostapd: Reload all interfaces") and bounced every interface; on a two-modem router the other modem dropped in two of three runs.
- A bare `up` is a no-op: after a CFUN cycle netifd still considers the interface up (fibocom/xmm RNDIS device does not disappear), so no re-dial happens: IP present, no internet (regression in 1.7.1 on FM350). `down` forces proto teardown.

## Cell lock contract

`getcelllock` returns `Unsupported` | `off` | `arfcn <n>` | `cell <n> <pci>`, optionally followed by `readonly` (state readable, profile cannot change it: show without an Unlock button) or `remembered` (the modem is silent, value comes from our uci stamp). `setcelllock off | arfcn <n> | cell <n> <pci>`.

- `_celllock_effective`: some firmware cannot read the lock (Intel XMM always says `off`; FM350-GL after reboot keeps the lock but `AT+EMMCHLCK?` answers 0, proven by the modem staying on EARFCN 1450 / PCI 359 until an explicit unlock). On `off` the uci stamp `celllock` is substituted and marked. Without a stamp and with a write-only profile (`_CELLLOCK_WRITEONLY`) `off unlockable` is returned so the Unlock button stays (once a user had to remove an XMM lock with three AT commands over SSH).
- The stamp is written before the job and removed if the profile answered "Unsupported" (T99W175 showed "Locked" while the modem got nothing).
- After a lock the modem may not come back from the CFUN cycle at all (Intel XMM 8087:095a: AT dead, card name replaced by command echo). The job waits and probes AT; USB power is not toggled automatically (a modem on a root-hub port of a VM-passthrough controller never returned after disable), the USB power reset stays a user button.
- The json cache is flushed after the write (EP06-E kept showing an already removed lock).
- 5G cell lock is a separate contract (`getcelllock5g`/`setcelllock5g`, `off | cell <nr-arfcn> <pci>`): firmware keeps LTE and NR locks independently (T99W175 `AT^LTE_LOCK` / `AT^NR5G_LOCK`). No uci stamp for 5G: `_celllock_effective` applies the stamp to the 4G row only and a second stamp would show the 5G lock there.

## Other vendor rows

Each returns `Unsupported` to hide the row.

- `get5gmode` / `set5gmode full`: 5G can be disabled in firmware while bands and cell lock look fine; `sa+nsa` | `sa` | `nsa` | `off`. Applied via the airplane cycle, so in background.
- `getcaenabled`: carrier aggregation switched off in firmware (module behaves like cat4).
- `get256qam` / `set256qam 0|1`: only on/off is shown, no promise of speed (forum reports gains only at SINR ~21 dB with eNB support).
- `getulca` / `setulca on`: uplink CA on DW5821e/T77W968 (1-2 Mbit/s up with rich DL, 55-90 Mbit/s after enabling). No disabling command is known, so only `on` is accepted and the button is shown only when disabled.
- `getantports`: one `port:rsrp:rsrq` line per antenna port; RSRP around -140 means no antenna.
- `bandwarn` in json: the profile sets `_BAND_RECONNECT_WARN=1` (FM350) and the page shows a permanent hint that Apply drops the link for ~15-20 s.

## 3G and 2G bands

- 3G style is per profile (`bands3g_style`): `combo` (default, Telit) means the firmware accepts only a predefined combination id (`AT#BND=?` -> `(0-11,17,18)`), shown as a single-choice list; checkboxes would lie. `mask` (FM350, SDX55, Sierra, SIMCom) works like LTE. json gives `combos3g`/`current3g` or `supported3g`/`enabled3g`. For `combo` `getsupportedbands3g` prints one `id:label` per line (labels contain spaces); the json loop iterates with IFS=newline instead of `echo | while read`, because a pipe runs in a subshell and `json_add_*` calls would be lost.
- 2G is always mask style with frequency labels (900/1800/850/1900); the UI adds the "GSM" prefix. Quectel EC21 was the first AT profile with 2G.

## json cache

- Cache-first: `json` is requested on every page open and used to queue behind the metrics poll for the mask. Since the mask changes only through our writes, `json` returns the cached result immediately; `jsonrefresh` produces the real output. Only valid `{...}` is cached. No background refresh: it would only load the port.
- Cache validity includes the interface proto (readonly depends on it; after switching qmi -> modemmanager the UI kept saying "switch to ModemManager" for 5 minutes) and modem identity from a sidecar `.m` holding the uci model. Comparing the json `modem` field failed forever (profile name "Thales\/Cinterion MV31-W" vs uci "Thales MV31-W"), so every view ran a full AT refresh, blocking the port for tens of seconds and starving metrics/SMS.
- Race: the cache file name is computed from `active_modem`, while `jsonrefresh` is a separate process that re-reads it. If the user switched tabs in between, data of another modem landed under the old name (Telit tab showed FM350 bands for up to 300 s). The result is cached only if `active_modem` did not change; the path is passed to `jsonrefresh` explicitly.
- Flushing: set verbs flush the cache from the background subshell after the write, not immediately. An immediate flush let the UI re-read in the middle of the write (between the bare `AT^BAND_PREF` reset and the new list on MV31-W) and cache "all enabled". A cold read during a write queues behind it in `at_lock`.

## `mgmtinfo`

Single source of truth for how the block is driven: `{"source":"mmcli",...}` with band lists and mode from config, `{"source":"mmcli","pending":1}` while MM is still assembling the modem (do not fall back to vendor, the block would flicker), `{"source":"vendor"}` for `bands.sh json`. A modem in MM that reports no bands (FM350 under MM) goes vendor. `other` (bands of other RATs) must be `[]`, not `[""]`: printf of an empty current-bands produced one empty element, which the page sent first to `mmsetbands` and mmcli rejected the whole list. HiLink answers `vendor` explicitly (before that, HiLink lost the block entirely after `mgmtinfo` appeared in 2.0.9).

## ModemManager writes

- `mmsetbands` runs `mmcli --set-current-bands` under the same per-device lock as `qmicli_p` in `lib.sh`. Called directly from the browser it hit a busy QMI channel ("couldn't set selection preference: Transaction timed out") and the modem dropped (DW5821e). Wait up to 20 s, then run anyway: it is a user action.

### ModemManager network mode

`setmodemm` writes `allowedmode`/`preferredmode` into the interface config and runs `ubus call network reload`. A live `--set-allowed-modes` was wrong both ways: narrowing (3G) worked until netifd re-dialed and the proto reset modes (back to auto after 10 s); widening (Auto) silently did nothing because nothing re-dialed. A plain down/up re-uses netifd's cached config with the old options; reload makes netifd re-read and restart the interface with the new ones. `default` deletes the options.

`setmodelive` is a synchronous mode change without radio restart for a short switch to 3G for USSD (`ussd.sh`). Single-RAT changes apply live (LM960 `AT+WS46=22` -> UTRAN in 5 s, FM350 `AT+GTACT=1` -> HSPA). The result is verified by reading back with retry: `sms_tool ... at` exits 0 even on ERROR, and `AT+WS46?` once stayed at 31 while "ok" was reported.

## HiLink modems

Bands are read and set through the device API (`LTEBand` mask in `/api/net/net-mode`), even in debug mode: `at^syscfgex` resets the USB composition, the stick falls back from debug to plain HiLink, loses AT ports and briefly leaves the bus. The API does not expose the full supported list, so it is read once from the AT profile while in debug and stored as `band_full`; otherwise a disabled band would disappear from the buttons. 3G/2G use `net-mode-list` (supported) and `NetworkBand` (enabled). A background watchdog after `setbands`/`setbands3g` restores debug mode and the interface (seen on B20 re-registration). The model name is sanitised before the printf-built JSON (a quote or backslash from the USB descriptor broke the whole answer). ZTE-API HiLinks (`hl_api=zte`) have their own branch; MediaTek ones (0e8d:2004/2008) need `5gmodem-mtk-at` for band control.

## Shared helpers

- `hextobands`: an empty mask (`0x` from a profile on an empty modem answer) used to fail with "arithmetic syntax error" in ash; one check here covers all profiles. `HHEX` is reset on every call: it is not local, and in the same shell a previous long mask added phantom bands 65+.
- `bandstohex`: 64-bit-safe mask building used by profiles (SIMCom's own nibble math miscomputed the full default mask).

## Frontend: `bandsui.js`

- Module API is narrow (`init(ctx)` gets the busy banner, `sameRender`, MM index and the MM-proto flag via `ctx.isMM()`/`ctx.setMM()`); state (source, gates, retries, takeover) is private.
- Warm render: the last successful data per modem is stored in localStorage and drawn instantly when a tab opens; live data then confirms or corrects (renders are idempotent via `sameRender`). The key includes the active modem path and a version suffix that invalidates entries written before mmcli addressing was fixed (hard reload does not clear localStorage). The cached model must match the current one, and the cache is not drawn at all when either side is unknown: with a port permanently busy (xmm dial loop) live answers never came and an L850 kept showing FM350's "5G SA+NSA".
- An empty `mgmtinfo` answer (rpcd busy) changes nothing. Treating it as "not mmcli" switched to the vendor path for one tick and made the whole 4G/5G row flicker.
- MM path hides vendor rows (5G mode, CA, cell lock) so a previous FM350 row does not stay on an SIM7100E tab; mode highlight comes from interface config, not live `current-modes`.
- Retries: an empty band list from MM can be permanent (FM350 under MM), so re-polling is capped (`_bandsRetryMax`: 3 x 1.5 s normally, 20 x 1.5 s after switching to ModemManager, which takes tens of seconds to enumerate). A modem with supported but no enabled bands (slow E3372 `at^syscfgex?`) is re-read after 1.5 s.
- Empty `supported` is `[]`, which is truthy in JS; availability is checked by length. A transient empty answer does not tear down an already drawn modemband block.
- Writes: `setall` through `bands.sh`, never bare `mmcli`; reads after a write bypass the cache. No busy banner for live-applied masks (it hung for the 8 s minimum for nothing). The mmcli path applies live (~0.1 s on Compal, connection unaffected), so no radio restart and no banner. Mode buttons without the RAT the modem currently uses ask for confirmation (a "5G" click where there is no 5G leaves the router offline). Mode change through `setmodemm` refreshes several times over the ~10-20 s interface bounce.
- Cell lock: the "lock to current cell" button reads the serving cell at click time (metrics may not have arrived when the row renders). 5G lock takes the carrier whose band starts with `n` from `s1..s4`. For `unlockable` without a known lock the button is labelled "Reset lock" (a bare "Unlock" made users look for a non-existent lock). Rows for 256QAM, uplink CA and 5G lock are created by this module because `5gdetail` does not have them.
- Switching tabs in place resets module state and hides vendor rows of the previous modem immediately.
