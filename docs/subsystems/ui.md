# UI: LuCI views and shared JS helpers

The web UI lives in `htdocs/luci-static/resources/view/modem5g/`. `5gdetail.js` is the "Network" page (modem card, cell info, CA/neighbour/antenna tables, band management, TTL, simple view). `modemtabs.js` is the modem switcher bar shown on every page, and it also decides which menu tabs are visible. `mutil.js` holds stateless helpers shared by all pages: band frequency tables, labels, formatters, the signal quality scale, operator icons and localStorage hygiene. `align.js` is the antenna alignment page, `5gstats.js` the statistics page, `buttons.js` the hardware buttons page, and `sendsms.js` the SMS composer. All styling is in `modem.css`, described in [ui-css.md](ui-css.md). Polling and snapshot freshness on the backend side are covered in [polling.md](polling.md).

## Shared CSS and theme probes

- `modemtabs.js` injects `modem.css` once (`#tg-modem-css`). Every app page requires `modemtabs`, so one loader is enough, and the file is cached like any other static asset. Before this, 19 `<style>` blocks were rebuilt on every page load.
- `buttons.js` keeps its own copy of the loader and of the `tg-boxed-sec` probe on purpose. That page does not show modem tabs and does not require `modemtabs`. Without the copy it rendered unstyled.
- The loader IIFE has to come **after** all `'require ...'` directives. Any code between them stops LuCI from parsing the rest of the directives.
- `tg-boxed-sec` on `<html>` means the theme draws `.cbi-section` as a card (border, background or shadow). This is true for proton2025 and argon. Only these themes get an inner section padding. bootstrap does not frame sections, so the same padding showed up as empty side margins. The probe uses a real element in the page container, because a theme rule can be scoped to it. It runs once, before rendering.
- `tg-theme-argon` is set from the theme stylesheet URL. It scopes the few argon-only fixes (see ui-css.md).
- `detectBoxedHeading` (5gdetail.js) checks with a real element whether the theme renders `h3` as a card header with its own side padding (argon). It also runs once before render, so nothing jumps afterwards.
- `align.js: probeCheckmark` sets `tg-fixcheck` only when the browser shows that a checked checkbox `::after` has a mask and content but a transparent fill. See [ui-css.md#broken-checkbox-mask](ui-css.md#broken-checkbox-mask).

## Browser cache and API versioning

`modemtabs.js` and `mutil.js` export `API: 30600`. Each page's `load()` calls `fresh.check(30600, [modules...])`. If a required module reports a different API, the browser is serving stale cached JS. `fresh.js` then re-fetches every app resource found in `performance.getEntriesByType('resource')` with `cache: 'reload'` and reloads the page. A sessionStorage key limits this to once per minute. After that, it only shows a "clear the browser cache" notice. Bump `API` and every `fresh.check` value together whenever a shared module's interface changes.

## mutil.js

- `BAND_MHZ_4G` / `BAND_MHZ_5G` copy `band4g` / `band5g` from `5gmodem.sh` (Wikipedia band tables). They add a frequency even when a backend path did not supply one.
- `BAND_DL_ONLY_4G/5G`: downlink-only bands that can only work as secondary carriers. LTE 29/32/67/69/75/76 are SDL and 46 is LAA. NR n29/n75/n76 are SDL and n46 is NR-U. T99W175/MV31-W list B46 as "DL only" in the datasheet. If only such a band stays enabled, the modem has no network. `bandTitle` puts this warning in the **tooltip** and keeps the button label short (`B46`), because long labels make the band rows overflow on narrow screens.
- `netModeRank` must also match Cyrillic labels ("Авто"). The backend sends mode labels already translated. Matching only `/auto/` ranked Auto as unknown (999), so HiLink modems showed `2G, 3G, 4G, Авто`. Order: Auto, then by generation, with each combo right after its lower generation (`Auto | 2G | 2G+3G | 3G | 3G+4G | 4G | 4G+5G | 5G`, rank = `min_gen*10 + (max_gen-min_gen)`).
- `operatorIcon` matches on word boundaries. "RT-Mobile" contains "t-mobile" and "РТ-Мобайл" contains "т-мобайл", and both used to map to T-Bank. Rostelecom can only be identified by the SIM-reported name. It is in neither `providers.tsv` nor `mccmnc.dat`, and it runs on the Tele2 network, so the PLMN does not tell it apart. Regional operators and MVNOs (Motiv, Tattelecom/Letai, Vainah Telecom, SberMobile) are also matched by name. DobroSim runs on the Beeline PLMN 250-99 and shares its APN, so only the network name "DobroSim" tells it apart; it is checked before Beeline. KT (MCC 450) arrives as the short token `KT` and is matched as a standalone token.
- `localizeBytes` also translates a bare `B` (bytes). Otherwise strings like `322.0 B  2.2 КиБ` appeared. It only translates units of an already formatted string. Pass a raw number to `5gstats.js`'s own formatter instead.
- `lsSweep(prefixes, maxAgeDays)`: warm caches in localStorage (`bands5g2-<path>`, per-modem eSIM/USSD tab memory, ping state) are keyed by modem or host and never deleted. An index (`5gmodem.lsidx`) records the last access time. Unknown keys start counting from now, and keys idle past the limit (30 days by default) are removed. If the clock jumps backwards, counting simply restarts. `5gdetail.js: load` runs it.
- Signal quality scale (`QUAL_T`, `qualLevel`, `qualPct`, `QUAL_COLOR`, `QUAL_GRAD`): **one** scale for the big bars and for every table (CA, neighbours, antenna ports, alignment). `edges = [worst, t1, t2, t3, best]`, four levels Weak/Fair/Good/Excellent, each one quarter of the bar. A larger value is always better. Fill length, colour and label all come from the same edges. History: each bar used to have its own width formula (RSRQ used `115-vn`, which gives 134% at -19 dB) and its own colour thresholds. Tables used a different 3-level scale, so RSSI -66 dBm was green in the header and yellow in the CA row (2026-09-18).

## Modem tab labels

`modemtabs.js: vendor/modelFor/label`:
- The brand comes from the VID or a product string. USB descriptors often only name a platform ("VOS_5G", "Android").
- `05c6` is deliberately **not** in the VID map. It is the Qualcomm VID shared by Compal RXM-G1, Foxconn T99W175, Dell DW5930e and Thales MV31-W. Mapping it blindly to Compal named a T99W175 "Compal Generic Mobile Broadband Adapter". Real Compal units are recognised by the product string (`VOS_5G`/`RXMG1`) or by `m.model`, which profile `05c690d6` sets to "Compal RXM-G1".
- `0e8d` is Fibocom only for `0e8d:712x`.
- An exact model by VID:PID covers useless descriptors. Quectel EC21 reports "Android". The same list is kept in `netpri.sh: model_for`.
- The model parsed from `AT+CGMM` (`5gmodem.m_<path>.model`) wins over both. SimCom reports "SimTech, Incorporated", and `1e0e:9001` is shared by SIM7100/7600/8200.
- A user alias (resolved by `listmodems`: bound to IMEI, falling back to the path section) beats any automatic name. Aliases are never de-duplicated.
- When two automatic labels are identical, the USB path is appended to them. The path is tied to the physical port, so it stays the same across reboots.
- The Modem tab offers MBIM+MM only when the active modem's cdc-wdm is on `cdc_mbim` (`modemswitch.sh wdmdrv`, result `res[7]` of `_load5g`). From 3.5.21 to 3.9.6 the call was missing and the check read the LED list, so the option was hidden for everyone not already on it.
- The USB icon is shown for VID `12d1` (Huawei sticks). Having a netdev is not a usable sign, because M.2 ECM modules (FM350) have one too. An operator logo replaces the hardware icon once `listmodems` reports a recognised operator.
- Labels are cached in localStorage, so the placeholder row drawn before any request matches the final text.

## Modem switcher behaviour

- `renderBar` always draws the bar, even for one modem. It starts with a placeholder button so the row height is reserved from the first frame. Earlier, the bar appeared after two shell calls and pushed the whole page down. `attach()` inserts it above the sub-tab menu, or at the top of the content, unless the theme (proton2025) already placed a `.modembar`.
- The highlighted tab comes from sessionStorage `5gm-tab` (written on click before reload), and only if that path is still in the modem list. Waiting for `active_modem` caused a "sticks the first time" delay of up to 4 s.
- **Page identity is the clicked tab.** The path goes to sessionStorage before switch/reload. Deriving the path from `active` made two tabs show the same modem (2026-07-31).
- `modemswitch.sh switch` output is parsed. It can print `{"error":"not a modem"}` with exit 0, `{"error":"no path"}` with exit 1, or rpcd may not answer, in which case resolveDefault gives `{}`. On failure the highlight and sessionStorage go back to the previous modem, the bar clicks are re-enabled, and the page does **not** reload. A reload would show the old active modem under the new tab.
- In-place switch: if the page registered `window.__5gmInPlaceSwitch` **and** `#modemname` exists, only the card is redrawn. The handler is global and survives navigation, so the DOM check stops a dead handler from firing on SMS/USSD/settings pages. The card is redrawn immediately: data is addressed with `for=<path>`, and the warm snapshot does not depend on `active`. Switch runs in the background, through resolveDefault.
- A 12 s safety reload restores the bar if switch hangs (busy rpcd, slow hotplug resolve). Without it, the panel stayed dead with the highlight on the new tab.
- The page content fades out only at the moment reload is called. Fading on click left the page blank for up to 12 s. A timer removes the class if the reload never happens (bfcache, cancelled navigation).
- Change detection without spawning scripts: `listmodems.sh` keeps JSON in `/tmp/5gmodem/listmodems.cache`. The hotplug hook `71-5gmodem-resolve` clears it on add/remove and rebuilds it 5 s later. The bar only reads this file. The signature includes vid:pid, model and operator, because a modem swapped into the same port has the same path. An empty read is the hotplug gap, not "no modems", so the bar waits for the next tick. While the rename editor is open, the bar does not redraw.
- Rename: `modemswitch.sh setalias` (it also stamps the IMEI), then the page reloads, because the name is used in several separately built places. Only one editor can be open per row. Cancel happens on outside mousedown (capture phase, so it closes before the click switches modems) or on Escape. There is no cancel button.

## Menu tab visibility (eSIM, USSD, Alignment, Statistics)

The LuCI menu tree is cached in `/tmp/luci-indexcache.<hash>.json`. The hash is computed from the menu **files** (inode/mtime/size), not from uci values. `depends.uci` therefore keeps its old verdict while the cache lives: on 2026-08-25, `align_enabled=1` still had `"satisfied": false`. The menu nodes are now unconditional, and links are hidden with a `<style>` rule. The rule applies before paint, so the tab does not flash.

- eSIM: shown when `esim.sh status` reports `available` (an eUICC exists), not when an eSIM profile is active. `PENDING` (background probe still running) means retry a few seconds later, up to a small cap. Running 8 retries cost up to 9 `esim.sh` runs per page. State is remembered per **active modem**. If uci is not loaded yet the modem is unknown, and the tab stays hidden instead of inheriting another modem's memory. Otherwise, after switching to a Huawei (no eUICC), the tab stayed visible for the whole probe. Use `fs.exec` (ubus `file.exec`), not `fs.exec_direct`: `/cgi-bin/cgi-exec` answered "404 Executable not found" here.
- USSD: hidden only on an explicit "unsupported" verdict from `modemswitch.sh ussdsupport` (the `quirks.sh` table by vid:pid). FM350-GL answers `+CUSD` with OK and never returns a result, in any mode or encoding. Visible by default, because hiding a working tab costs more than briefly showing a dead one.
- Alignment is hidden when `align_enabled` is empty. Statistics is shown when its flag is empty, because collection is on by default. The settings page calls the refresh hook after saving, so no reload is needed.
- Tab visibility is computed after the first render. Calls made in the same tick share one ubus batch, and the page would otherwise wait for the slowest script.

## Busy overlay

`modemtabs.setBusy(selector, msg[, safetyMs[, progressSec]])` and `clearBusy()` cover a block while the modem re-enumerates (30–60 s). It is used by the Network page and by eSIM. `progressSec` shows a progress bar styled like the metric bars. It fills by expected time, stops at 97%, and completes to 100% when `clearBusy` is called. Spinner and progress bar are mutually exclusive. Styles are in `modem.css`. `_busyCss` is an intentionally empty stub kept for existing callers. `5gdetail.js: setModemBusy` is the card-level variant. `pollData` clears it once registration or signal is back, but not before a minimum hold time. Right after the command, the modem still looks alive, and the next poll would have cleared the overlay too early.

## Network page (5gdetail.js)

### Load and page identity

- Render-first: `load()` does not block on `mmindex`, `5gmodem.sh json`, `mmcli -K` or `ttl.sh`. Previously the page stayed blank for about 0.7 s or more. The skeleton renders at once, and the first poll fills it. `mmIdx` is fetched in the background, because only the lazy band block needs it.
- Warm start: `5gmodem.sh peek [path]` returns the last snapshot of any age (about 10 ms, no port, no lock). It is applied on a macrotask after render, because the DOM is not attached yet while `render()` runs. An empty peek is not applied over the skeleton.
- `pageModemPath` order: sessionStorage tab, then the `path` from peek (read from the router config), then the uci cache. `uci.js` keeps its own config snapshot, which could still hold the previous `active_modem`.
- The pinned path is used only if a section with that `path` exists **and** the path is in `listmodems`. A removed modem's section is parked and loses `path`, which caused a `not_active` reload loop (2026-07-31). A phone in tethering mode has a section with a matching path but is not a modem, so the page stayed pinned to an empty card across F5 (2026-08-03).
- `applyMetrics` skips snapshots for another modem (`not_active`, or a path mismatch). A report with two T99W175 showed the neighbour's data in the card of a modem without a SIM (07-30). After several foreign ticks in a row, the active modem was changed elsewhere: the page clears the remembered tab and reloads. Without clearing it, the reload loop never ends.
- The SIM menu modal and every metrics call also use `for=<path>`.
- `ledsAvail` must be awaited before render, because `render()` reads it. It uses `fs.list('/sys/class/leds')` (ACL `list` entry) instead of running a script. `fs.exec_direct` hits the broken cgi-exec, and `fs.exec` may lack the exec grant.

### Polling

- The poll is always registered, even if the peek snapshot had an error. Earlier, `poll.add` sat inside `if (!json.error)`, so a busy modem at page open froze the page until F5.
- `5gmodem.sh cached <ttl> for=<path>` reads the shared snapshot. Only one process talks to the port. A page, a second browser and `5gtop` polling at once took 13.4 s per poll instead of 3.8 s. `sessionwatch` refreshes the snapshot while a page is open (presence marker, every ~5–6 s), so a tick usually costs about 90 ms. The ttl is 10 for AT modems and 6 for MM, as a fallback if the watcher is dead. A fixed `cached 4` made each tick run a full collection (1.3–1.8 s CPU).
- `align.js` asks for exactly the freshness of the selected interval (at least 1 s, because age is counted in whole seconds from `/proc/uptime`). A fixed `cached 4` made the interval field meaningless for antenna alignment (2026-08-26).
- Never overlap requests. A slow poll queues in rpcd, which kills calls at 30 s ("XHR error"). Skipping a tick is harmless. The same guard is used for `loadSimSlots`.
- An empty response (busy rpcd) or broken JSON skips the tick. An `{"error":"busy"}` snapshot has no metric fields. Guard every `.includes`/`.length` on metric fields, because one `undefined` aborted the whole tick (2026-09-12).
- `simslot.sh` and `bands.sh` start after the first successful poll tick (`afterFirstPoll`), with a 1.5 s safety timer. Fixed 400/600 ms timers made them hit `at_lock` during the first full poll.
- The band block is refreshed by a single scheduler, every ~3 polls (`_bandsPollN`) and only when expanded. Background band changes (restore after reboot, proto auto-apply) do not notify the page. A second refresher only doubled requests and redraw races.
- `align.js` takes the click rate for sound feedback from `au.curSinr`. `st` has no such field, and reading it played clicks at the SINR=0 rate.

### Render stability rules

The scroll jumps on proton2025 had several independent causes. Rules:

- **`sameRender(el, sig)`**: rebuild a container only when its data signature changes. `innerHTML=''` empties the container for a moment, document height drops, the browser **clamps** `scrollTop`, and the scroll stays clamped after the content returns. It was hard to find: height looks constant to measurements, no JS touches `scrollTop`, and `overflow-anchor: none` does not help, because this is clamping, not anchoring. It applies to band rows, SIM slots, the temperature, the mode line (rebuilding it also reset native tooltip timers, so tooltips never appeared, 2026-08-19) and the 4cells button. `data-sig` lives on the element: if you write plain `textContent` into a sameRender element, clear its signature or it will never be rebuilt.
- **`setRowVisible(view, hasData)`**: a row that has ever had data is never hidden again, and the last value stays. An empty field almost always means an AT port collision (metrics share the tty with SMS, slots and profiles), not a missing parameter. A row that never had data is hidden after 3 empty polls.
- Tables keep a constant structure. The CA table has pre-drawn PCC/SCC1..4 rows, and SCC rows that never had data are hidden. The neighbour table grows to the maximum row count ever seen: XMCI on L850/L860 reports 1, 2 or 0 neighbours on consecutive polls. Extra rows keep their last values, because a text dash is shorter than a bar cell and would shrink the row. The antenna port table rebuilds its skeleton only when the **port numbers** change. Its signature once included live levels and rebuilt the table on every tick.
- `paintMetricCell` updates existing nodes so the CSS width transition animates. On proton2025 it uses the theme's `.cbi-progressbar` (24px pill with the label inside, from `title`). Elsewhere it draws a thin bar under the number: bootstrap's progressbar puts its label 1.4em above the bar.
- Single-line bars follow `caQuality`, the same function that colours the number. Antenna levels around -130 dBm and below mean "no antenna" (an unconnected LM960 port gives -134), so they get their own label.
- The CA block's visibility follows the connection (`pband` present, debounced), not the component count.
- The "keep scroll at bottom" helper was removed. Measurements showed page height stayed constant and that helper was the one moving the scroll.
- `display:flow-root` on the card header contains the floated protocol chip. Without it, the float leaked into the status row on bootstrap.
- Elements floated right in the header stack right to left in DOM order. To put the vid:pid chip left of the protocol chip, append it **after** the protocol chip (`renderVidPid` runs last). The same applies to the USB-drop icon.

### Card content notes

- `formatModeDisplay`: the phone-style label (LTE→4G, LTE-A→4G+, HSPA→H+, UMTS→3G, EDGE→E, GSM→2G) and `4G | B1 (2100 MHz)` change only the display. Raw `json.mode` still drives band parsing and the 4cells link. Calling it twice gives the same result.
- `json.bandwidth` is a fallback when the band string has no `@NN MHz`.
- The mode line also shows configured but deactivated SCCs as dimmed chips. There is no de-duplication by band name: intra-band CA (B7+B7, EP06 on MegaFon, 2026-08-22) needs one chip per carrier. Band matching uses word boundaries (B4 vs B40).
- MIMO badge: `MIMO N×N` from `pmimo` (real rank). Otherwise `RX N/M` from antenna levels. Telit `rxdiv` wins over the port count, because `#LAPS` lists 2 ports with 4 receivers.
- Missing RSSI shows a dash. `j.signal` (percent) used to be substituted for it. No measured antenna port also shows a dash, not `MIMO: 0x0`.
- The "weak signal" hint in simple view uses the same CSQ percent as the icon. RSRP is only a fallback, because the two scales legitimately disagree (Compal: 77% from RSSI -66 with RSRP -116). It hides with hysteresis.
- Temperature is normalised to one `°C`; two chained replaces used to produce `°°C`. Compal RXM-G1 has no temperature command, only `+CEITHERM` throttling level 0–3, shown as a word. LM960 gives both (`#TEMPSENS=2`, `#TMLVL?`). Level 0 is not printed.
- The phone number sticks across empty reads (port collision), but resets on IMSI change.
- Connection time: the base is `conn_time_sec + json.age`, re-anchored only when it drifts by more than 3 s (a real redial), with a local 1 s tick in between. Without the age correction, cached snapshots made the counter lag and jump (2026-08-16).
- Interface IP and external IP share one line. If both are equal (public IP), only the flagged external one is shown. The external IP is fetched **through the modem** (`extip.js`), because the default route may be another uplink.
- Stale indicator: an hourglass icon in the header when the snapshot is older than 10 s. The age is shown in the tooltip only.
- A USB-drop icon appears at 3 or more drops in 10 minutes. A single drop happens during a normal recovery reset. Three in a row is almost always power (two Cudy TR3000 reports, 2026-08-09).
- A connection stage text replaces raw netifd log lines while there is no IP. The enumeration counter is appended to every waiting stage.
- 4cells link (`cell4cellsUrl`): LTE/NSA is `tech=3`, with `num = eNB = CID>>8` and no LAC. LAC in the 4cells database is inconsistent between towers, and SIM7600 sends `0xFFFE`. UMTS is `tech=2` with short CID (low 16 bits) plus live `lac_dec`, because `tac_dec` is 0 on 3G. GSM is `tech=1` without LAC. NR SA has no known formula, so no button. Tech is decided by live LTE signs (EARFCN, band, eNB), because the `mode` string flickers. The last full result is reused when mcc/mnc drop for one tick. The button sits on the row whose number goes into the URL.
- Modem absent: `Device not found`, or a stale snapshot (age ≥ 30) whose modem the bus does not confirm. A stale snapshot alone is not enough: with two modems the queue can delay a live one. `onbus=1` with `hasports=0` is a non-modem device such as a tethering phone, so "modem not connected" is the wrong message there. A localStorage flag lets a modem-less router draw the dashed card immediately.
- HiLink rows that can never be filled (TAC/LAC, CA) are removed in the poll loop, not in render, because the loop would show them again.
- The HiLink debug switch goes through `autosetup`. The page reloads when `cached` shows the switch has finished (`backend != hilink` with `at_debug=1`), capped at ~55 s. A blind 25 s reload landed in the middle of the ~34 s 14dc→1566 switch.
- The modem reboot has a soft mode (CFUN=4→1, no re-enumeration) and a hard mode (CFUN=1,1). The hard-mode progress cap is 90 s (reboot plus redial). Power reboot is shown when `reboot_modem.sh haspower` reports a GPIO. Otherwise a USB port reset is offered: on Almond 3S (MT7621) `modem_reset` is mini-PCIe `#PERST`, which USB modems ignore, and xHCI has no per-port VBUS.
- TTL apply sends the configured IPv6 values when the IPv6 fields are not rendered. `ttl.sh set` treats an empty value as delete, and the configured hop-limit was being erased (2026-09-12).
- `this.error()` does not exist on `baseclass` (use `L.error`). Calling it threw again inside the handler, so the stopped poll never resumed.

### Band management glue

- `bandsui.loadBands` (`bands.sh mgmtinfo`) is the single entry point. The backend decides between mmcli and vendor paths. Calling both loaders made the vendor path hide rows the mmcli path had just shown.
- `mmIdx` empty means MM does not manage **this** modem (`mm_index_for_path` matches the sysfs path). Never fall back to `any`: on an FM350 outside MM, `any` showed E3372 bands and would have written to the wrong modem.
- `ifaceProtoIsMM` comes from `iface_proto`, not `protocol`. `protocol` is the data channel, which is `mbim` for Compal under MM. It is updated live on every tick.
- A forbid flag from `bands.sh` (profile `_BAND_VIA=mmcli`, interface on a kernel proto, modem hidden from MM) blocks the mmcli path. Without it, `mmcli -m any -K` hit a foreign modem.
- `readonly=1` means state is readable (direct qmicli) but writes need MM. `takeover=1` means writes temporarily hand the modem to MM (Compal in MBIM), with a warning first.
- The band block state resets when the hardware key (model + vid:pid) changes on the same path.
- `mmcli --set-current-bands` replaces all technologies at once, so utran/cdma bands are preserved.
- 3G rows: `hasMm3g` keeps the modemband path from hiding rows filled by mmcli (Huawei E3372). Clearing goes through `renderBandToggles([])`, which also updates `data-sig`. FM350 once showed the previous modem's 3G bands.
- After a band apply, read with `force` (`jsonrefresh`), because the normal path serves a 300 s cache.
- Switching to ModemManager from the hint does not pass an APN, because an empty APN in `mkiface.sh` means keep the current one.
- A non-modem device (tethering phone) gets no "switch to ModemManager" hint.
- L850/L860 XMM switch (`modemswitch.sh xmm`: `GTUSBMODE=0` + `CFUN=15`) is a dormant fallback. These modems expose bands in MBIM.

### SIM slots and SMS envelope

- Slot buttons appear only when the modem has two or more slots (`AT+GTDUALSIM` or MM `sim-slots`). Addressing uses `for=<path>`.
- Slots are re-read when the IMSI changes, plus a rare safety tick (every ~12 ticks). `simslot.sh` has a 300 s router cache, so repeats are cheap. Until slots have been seen once, retry every other tick and never give up. A hard stop after 6 early attempts hid the buttons forever if the modem was re-enumerating (2026-08-04).
- After a switch, `pollSlotUntilSwitched` stops at the first answer that shows the requested slot active. Seven fixed timers made up to 13 port visits.
- A transient `{"error":"no device"}` keeps the last good list.
- Empty slots are marked but stay clickable. A user may insert the card later, and on MV31-W with an eUICC, a disabled SIM1 could not be reached at all. The active slot is also marked when empty: MM reports slot 1 active on a modem without a card. Protection against lpac switching slots during MBIM eSIM operations is in `esim.sh` (`_mbim_slot_get/_mbim_slot_restore`).
- The unread SMS envelope uses `smsbridge.sh newcount for=<path>` through `fs.exec_direct`. `read_direct` uses cgi-download, which the ACL rejects with 403.

### Simple view and collapsible blocks

- Collapsible blocks animate a grid track from `0fr` to `1fr`, because content height is unknown. State is kept in localStorage. Collapsed blocks do not poll.
- Simple view is the same card with a `body.sc-simple` class and `!important` CSS rules. Inline `display` is owned by the page logic. Rewriting it directly would restore the wrong state when leaving the mode.
- The ring buffer history is written by `5gmodem.sh hist` on the router. Points carry an age, not a timestamp, because the router has no RTC and its clock disagrees with the browser.

## modemtabs.js page fade

`renderBar` also removes the entry-fade class after the animation. Leaving the class on would block later transitions on the same container.

## sendsms.js

- The SMS transport (sms_tool / sms_tool_mm) is chosen by `smsbridge.sh`. The page does not know it.
- The character counter never truncates text. Long messages are supported: the bridge splits UCS2 into 67-unit parts with concatenation UDH (`smspdu.sh`), and sms_tool handles GSM-7 multipart. Changing the encoding only converts the text to GSM-7.
- Buttons restore their own previous `disabled` state. Enabling every button on the page also enabled intentionally disabled ones in the SMS settings panel.
- The country prefix is added at send time, and only to 10-digit national numbers. Prefilling the field turned service number `000100` into `7000100` (MegaFon, 2026-08-20).
- The send mode comes from the `ui.ComboButton` value (second handler argument). The label text never matched in translations, so "send to number" went to the whole phone book.
- Contacts are parsed pairs kept in JS. `ui.Dropdown` has no `.value`/`.options`, and both the widget and the broadcast loop use these pairs.
- The broadcast log is its own variable. It used to write into an undefined `res` and threw synchronously, outside `.finally`, which left the button locked forever.
- The format hint is an inline block, not `ui.addNotification`, which draws a global banner over the tabs. Closing it calls `modemswitch.sh hidenumberhint` instead of `uci.set/save`, so no "unsaved changes" banner appears.

## 5gstats.js

- Uses its own small canvas renderer, with no CDN, because routers may be offline. The canvas is sized in physical pixels (`devicePixelRatio`). Geometry is stored on the element (`__chart`) for hover lookup. Fill and line share the same quadratic-midpoint path, so the gradient never crosses the line. Cubic splines overshot.
- Hover redraw must pass the same options as the normal draw, or a fixed 0..100 scale is lost.
- A hidden card has a zero-width canvas. Redraw when it becomes visible.
- Traffic rows are keyed `sim-<iccid>` or by interface name. A bare `sim-...` key with no label is shown as `ICCID: ...`, and the number formatter is not applied to it. The operator label `op.<key>` is stored per card on the router.
- While the page is open, it triggers collection every 10 s. The background collector runs every 30 s.

## buttons.js

- Buttons and switches come from DTS `linux,code` / `linux,input-type` (EV_KEY = button, EV_SW = switch). The backend is `buttons.sh`.
- Saves run **sequentially**. Each `buttons.sh set/setleds` call does `uci set` plus `uci commit`, and commit clears the delta: a parallel write between read and clear was lost while `Promise.all` reported success. Two parallel `setleds` also restarted `/etc/init.d/led` on top of each other. `btntype` is not written, because nothing reads it and every commit is a flash write.

- Bootstrap's help icon (`.cbi-value-description::before`, absolute, 1em) sits at the top of the first line box. With the 18 px line height of a 13 px description it was 2.5 px above the text. On our pages it is moved down by `calc((1lh - 1em) / 2)`, with `.19em` as a fallback for browsers without `lh`. Checkbox rows hide the icon (see the flag-row rules).
