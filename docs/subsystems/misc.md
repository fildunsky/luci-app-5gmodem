# Miscellaneous subsystems

This document covers the Settings page (`5gsettings.js`), the package `Makefile`, the self-updater (`update.sh`) and a set of small helper scripts under `root/usr/share/5gmodem/`: AT console and probing (`atcmd.sh`, `atprobe.sh`, `cme.sh`), port helpers (`listports.sh`, `portmap.sh`, `ensureports.sh`, `noatports.sh`), modem identification (`iscompal.sh`), ModemManager on/off (`mmneed.sh`), netifd proto registration (`register_proto.sh`), instant-save verbs (`setopt.sh`), TTL fixing (`ttl.sh`), FCC unlock (`fcc-unlock.sh`), case LEDs and antenna switch (`signal-leds.sh`, `antenna.sh`), USB power diagnostics (`powercheck.sh`), APN database updates (`apn-update.sh`) and proxy panel detection (`ssclash.sh`, `nikki.sh`). Most scripts print JSON and are called from LuCI through rpcd `file exec`, so they must stay well below the 20 s ubus client / 30 s rpcd limits.

## 5gsettings.js
The "Settings" tab: application update, APN database update, Network page display options, widgets (ping/service cards, speed test, internet watchdog), telemetry/MQTT, and "For experts" (TTL block, alignment, external IP, mwan3 metrics, device blacklist). Split out of the Modem page so that page is only about the modem.

### Saving model
- Instant apply: every change is saved and applied by itself; Save/Reset buttons are removed (`handleSave: null`, `handleReset: null`), only "Save & Apply" remains as a safety net. Changes are debounced (400 ms) so a burst goes as one commit.
- Listens to `change`, `widget-change` and `cbi-dropdown-change`: LuCI custom widgets (ListValue dropdowns) do not fire native `change`; without the extra listeners list choices were never saved (2026-08-16, "widgets and services are not applied"). Clicks on add/remove of nested tables trigger a full `m.save()` (rows appear/disappear, re-render needed).
- formSig snapshot of all values: ui.Dropdown fires cbi-dropdown-change when a list is closed without a choice; without the comparison every miss would trigger a save.
- Save without re-render: `m.save()` ends with renderContents() and the whole page blinks after every choice. The fast path uses `m.parse()` + `uci.save()`; dependent field visibility is recalculated by form.js on widget-change.
- applyOwn: `uci.callApply(0, false)` only when the pending list contains exactly one config and it is `5gmodem`. Foreign pending edits (e.g. network edited elsewhere and not applied) are never applied on the user's behalf. rollback=false because the standard apply with confirm timer reverted settings when the confirm did not arrive; 5gmodem holds only app settings, nothing to cut access with. procd triggers on 5gmodem reload only 5gmodem-leds and 5gmodem-sms-notify.
- Pending LuCI changes live in the rpcd *session*, not in the shared /tmp/.uci (there is only an empty placeholder file there). Verified 2026-08-25: after `ubus uci set` with a session, plain `uci changes` is empty, `uci commit` writes nothing, the session delta is alive; after a router reboot the session (and the change) was gone, e.g. the speed-test source reverted. Hence `uciCommit` (rpc `uci.commit`) through the browser session, for *all* configs with pending changes (nested forms touch network/firewall too). Not uci.apply(): that has a confirm-timeout rollback.
- After commit the LuCI "unsaved changes" indicator does not know about it; the list is re-read and `ui.changes.setIndicator(n)` is set from the actual count.
- `setopt.sh applyset` still runs after commit: it flushes the LuCI menu cache and commits anything our own scripts left in /tmp/.uci.
- "Save & Apply" (handleSave_): calls save() of every .cbi-map, then verifies the pending list is empty; if not, commits via session and only as last resort `ui.changes.apply(true)`. Needed because instant save can fail silently: an old setopt.sh without `applyset` (only htdocs updated), or a backend call failed (ACL, busy rpcd, timeout) swallowed by resolveDefault (2026-08-23: a dozen `uci set` hung unapplied with no way to apply them on the page).
- Gating options (`align_enabled`, `show_stats`, `netonly`): the menu tree is cached by menu file mtime, not uci, and the open page got its tab bar once at load (2026-08-25: "enabled Alignment, no tab"). Alignment/Statistics tabs are hidden by style (modemtabs.applyGateTabs/refreshGateTabs) so they appear in place; `netonly` change reloads the page after applyset.

### Update block
- Status shows the version in `<strong>` like "Current version"; tag prefix "v" is stripped.
- `asset_pending` error: release tag exists but CI is still building the .apk; shown as "wait 15-20 minutes".
- CACHED_RES must list *all* our JS/CSS: after update the new 5gdetail.js met an old cached bandsui.js (modules split out of 5gdetail/5gsettings), with inconsistent ctx (audit 2026-09-12). Resources are re-fetched with `cache: 'reload'`, then logout (re-issues ACLs).
- Poll the result *file* /tmp/5gmodem/update.json every 4 s (up to ~5 min), never update.sh (it is replaced during install). The start request may never answer although installation proceeds (rpcd loses the exit of a script with a live background child, ~every second run on 25.12.5, and install restarts rpcd); on request error the status file is checked and polling continues, otherwise the user retried and got "Install failed" over an installed package (2026-09-14).
- "Install update" starts at once, without a `confirm()` dialog: the button is shown only after a check found a newer release, so a second question added nothing.
- Progress is an own bar (`.tg-updbar` / `.tg-updfill` in modem.css), not `<progress>`. Themes draw an indeterminate `<progress>` as a flat grey strip, and every stage except a sized download was indeterminate, so users saw no movement at all. The fill follows the stage: prepare 5 %, download 10-70 % by bytes, install 75 %, finish 92 %, done 100 %; it never moves back, and stripes run while a stage is in progress.

### APN database
- Updated separately from the app and only manually: data changes between releases (new MVNOs), the packaged file is refreshed at release time. The installed version is read immediately (local file); "Check" goes online only on user action.

### Options
- Dropdowns: `form.RichListValue` (ui.Dropdown) everywhere instead of ListValue (native `<select>` looks different); falls back to ListValue on old LuCI.
- Network page blocks are on by default; the page hides a block only for an explicit '0'.
- netpri_rank (card background) off by default; '1' means priority number for compatibility with the old "show numbers" checkbox.
- Internet watchdog is a collapsible block under Internet priority with its own immediate save (healthform.js autosave, setconf), not tied to the page form; no depends - the watchdog works with the widget off. Uses `.tg-collapse` (grid track 0fr -> 1fr, modem.css).
- Ping cards: TableSection; "+" button with the full title as tooltip. The default card (youtube.com) is seeded by uci-defaults/seed_widgets.sh; a placeholder here duplicated youtube.com in the combobox list (placeholder becomes select_placeholder). Telegram is checked via the official network list plus 403/404 from api.telegram.org (netpri.sh ping).
- Service cards: dropdown, not free text: form.Value with placeholder 'ssclash' saved a svcwidget without `service` and no card appeared. Default = first installed proxy panel in the seed order nikki, ssclash, clash. `restart_on_uplink` hands the service to hotplug 70-5gmodem-svcrestart, which restarts it when the uplink actually carries packets (tunnels start before any uplink - Wi-Fi STA and DHCP WAN come up late too - and initialize without network).
- Speed test: `internetometer` is a marker, not a URL: Internetometer probe URLs are session-bound (mid/sid), the script fetches them before each run. No placeholder and rmempty=false: an optional field gets an extra raw "internetometer" entry in the list (ui.js optional branch). Selecting Internetometer for download also sets it for upload (same CDN node). Upload default equals download default, and the script treats empty the same way.
- The public IP service is shared with "External IP" and lives under "For experts"; the speed-test block only links to it.
- "For experts" is intentionally last (UX audit P6): users could not tell "breaks the internet" from "changes card colour".
- `align_enabled`: one key for both data collection and the tab (two switches gave "tab exists, no data"); off by default.
- External IP: interface address and the address seen by the internet differ under CGNAT or a tunnel; the difference tells whether the router itself goes through the VPN. The service is always visible (shared with speed test), the switch controls only display. No silent fallbacks - only the configured service is queried. "Check now" queries what is currently in the fields (before saving); the answer is shown under the button, because a LuCI notification appears at the top of the page while this section is at the bottom.
- `mwan3_metrics`: uplink metrics 100, 110, 120... by default leaving 1-99 for tunnels (wireguard, zerotier); checked gives 10, 20, 30... (mwan3 convention). Read by netpri.sh (_metric_base) and mkiface.sh.
- Device blacklist: modem detection uses drivers and interface classes (notmodem.sh), but a USB-serial gadget can still get a tab and AT probing (2026-09-01, CH340 1a86:7523). Listed: devices not in the modem database (modem/usb/<vidpid>, `known`), plus those with an existing override. Known modems are not listed (a checked "is a modem" read as an already-answered question). Checked = excluded: on an auto-modem device it goes to `ignore_vidpid`, unchecked on a non-modem goes to `modem_vidpid` (e.g. a dev board with a cellular module behind a USB-UART bridge). Final state `skip` is computed by the backend. Written by `notmodem.sh setblack` (commits immediately, page reloads), debounced 600 ms to merge several clicks. Overrides are written only where the checkbox differs from `auto`.
- Theme quirks: the manually built update block is wrapped in `.cbi-map` because themes draw the section card via `.cbi-map .cbi-section` (2026-08-07); widget tables are wrapped in `.tg-modem-form` to shrink `cbi-section-table` columns to content in both bootstrap and proton. The description column is one flex column next to the theme's help icon.

## Makefile
- Dependencies: `mbim-utils` (mbimcli) is needed for eSIM on MBIM modems - only it reads and restores the slot mapping (`_mbim_slot_*` in esim.sh). Without it a user with a working SIM1 and an eUICC in SIM2 gets switched to the eSIM by just opening the eSIM tab, losing the link, and the slot state ("active-esim" / "no-profiles") cannot be told apart over QMI. Cost is ~180 KB: libmbim already comes with ModemManager. `coreutils-stty` is needed by the 5gtop terminal tool: without it line mode cannot be turned off (keys only act after Enter) and the window width is unknown (layout falls back to narrow); this is termios, and busybox stty is missing on some builds.
- postinst services (`_5gm_svc`): enabled once on a fresh install (marker in /etc/5gmodem/.svc), on upgrade the user's enable/disable is respected. 5gmodem-usbports re-binds usb-serial ports on every boot (new_id does not survive reboot, procd does not deliver coldplug hotplug; see 05c6:9025/90d5/90d6) and applies them immediately to an already plugged modem. 5gmodem-sessionwatch watches the data session (the network may re-create it with a new address, e.g. when changing macro-region while travelling, and netifd does not track that; see sessionwatch.sh). 5gmodem-btnleds syncs button LEDs to service state once at boot (they stayed dark until the first press).
- usbmode-fix.sh runs in postinst too, not only in hotplug: some usb_modeswitch database entries prescribe configuration 0, which removes the data channel; an usb-modeswitch upgrade brings the entry back while the modem is already plugged, so no event fires.
- 5gmodem-rebind-allow.sh: Windows/Android/Apple connectivity probes are exempted from dnsmasq rebind protection (on cellular uplinks it blocks them and clients report "no internet"). Run in postinst because uci-defaults only runs on next boot.
- 5gmodem-ttl-migrate.sh removes the old fw4 TTL include immediately (see ttl.sh): it breaks fw4 on cold start, so the next boot would already fail.
- Japanese up to 2.5.13 shipped inside the package and was copied into the LuCI i18n dir; now it is only in luci-i18n-5gmodem-ja. An orphan copy is removed unless that package is installed.
- `ubus call network reload` re-reads /etc/config/network but does not register proto handlers; that is register_proto.sh, run after autosetup (which may have just created the modem interface).
- `modemswitch.sh resolve`, `ensureports.sh`, `modemswitch.sh autosetup`: a modem plugged in before install produces no hotplug event, so without these the config stays empty (no active_modem, no port, page shows only dashes), and the SMS/USSD/AT ports (separate config) stay unset.
- Browser cache: all package resource directories are touched with a future mtime. Previously only `view/modem` (non-existent; pages live in view/modem5g) was touched, so main JS kept mtime 1970 after upgrade and browsers did not revalidate them for years or got 304 on any If-Modified-Since (2026-07-31: on a fresh 2.1.0 the SSClash card was red because of a week-old netpri.js). Before that a stray `}` closed the group early ("syntax error: unexpected }") and the touch never ran.
- Lite variant `luci-app-5gmodem-lite`: same files without heavy dependencies (modemmanager, qmi-utils, kmods, protos) for 8 MB flash routers. Built by the same CI and attached to the release (a manual `apk mkpkg` build once lost dependencies). conffiles/install/postinst/prerm are reused from the main package by plain make assignment (a copy would diverge). CONFLICTS is mandatory: both packages own the same files.

## update.sh
`update.sh version|check|install|status` - checks and installs the latest luci-app-5gmodem release from the project GitHub releases. Prints JSON.
- Downloads go through net_fetch (lib.sh): direct requests from the router die behind carrier whitelists, the local clash gets through (2026-08-19: "the updater must fetch like the widgets do").
- detect_pkg: two packages exist, full and lite (see Makefile); the update must use the installed variant. Full does not fit on an 8 MB flash router; lite over a working QMI/MBIM setup would remove qmi-utils and modemmanager as orphans and drop the link. `check` returns `variant` so the UI shows what will be installed.
- asset_url anchors on the asset file name (`/<basename>[-_]<digit>...<ext>`): the repo name appears in every asset URL, and a greedy `.*` picked the last .apk (an i18n package such as zh-tw); installing it left the main version unchanged ("version stayed 1.2.3"). apk uses `-` before the version, ipk uses `_`.
- install runs in the background (two packages over a modem link exceed the LuCI RPC/XHR timeout) and writes the result to /tmp/5gmodem/update.json via tmp+mv; the page polls that *file* (calling update.sh itself is unsafe while it is being replaced). The file is created immediately with `{"running":true}`: otherwise every poll hit cgi-download for a missing path and the browser console printed "404 (Failed to stat requested path)" every 4 s.
- A second install while one runs is refused with `already:true`: both wrote the same status file and the second hit the locked apk DB and overwrote the first one's success with "Install failed" (2026-09-14: XHR error on the first click, error on the retry although the package was installed).
- Lock PID is read from /proc/self/stat inside the subshell: `$$` there is the PID of the parent, which has already exited.
- `asset_pending` is a stable code (localized by the UI) for "tag exists but CI has not uploaded the .apk yet".
- Non-zero package manager exit is treated as success if the installed version equals the version parsed from the asset name (`luci-app-5gmodem-2.5.5-r1.apk`, `luci-app-5gmodem_2.5.5-r1_all.ipk`).
- The Russian translation is bundled into the main package (.lmo deployed by postinst). The obsolete standalone luci-i18n-5gmodem-ru is removed (best effort) and since removing it also deletes its .lmo, the bundled copies from /usr/share/5gmodem/i18n are re-copied.
- After install the version must change: opkg/apk return 0 for a package of the same version (a release asset built with an old version used to report silent "success"). A same-version reinstall equal to the latest tag is reported as success (`reinstalled:1`), not as "mispackaged release".
- apk refuses any install when /etc/apk/world lists a package it cannot find (installed from a file and then lost, or from a removed feed): "unable to select packages: X (no such package): required by: world[...]". `apk_world_blockers` parses such names from the log and the result is `world_broken` with `pkgs`; the page tells the user to delete the line or reinstall that package. `--force-broken-world` is not used: it drops world entries and can remove the user's packages. When the missing package is one of our own dependencies (empty index cache), `apk update` runs once and the install is retried.
- `sleep 1` before exit is required: rpcd (file exec) loses the output of a script that exits immediately after spawning a background child; the request hangs until rpcd's 30 s timeout and the page shows XHR error. Measured on OpenWrt 25.12.5 via `ubus call file exec`: about every second call hung without the pause, 6/6 answered within a second with it (2026-09-14). The page also falls back to reading the status file (5gsettings.js).

## mobile.sh
`mobile.sh data get|on|off`, `mobile.sh airplane get|on|off`, `mobile.sh tick`. These are switches for external front ends (device screens, buttons, scripts) that the watchdogs respect. `get` prints `on` or `off`.
- Mobile data off sets `network.<iface>.auto=0` on the active modem's interface and runs ifdown. A bare `ifdown` is not enough: sessionwatch and health only skip a down interface with `auto=0`, and health heals a link that stays down without errors after `STUCK_DOWN_MIN`. Data on deletes `auto` and runs ifup. Under ModemManager, ifdown also disables the modem, so it detaches from the network.
- Airplane mode turns data off, remembers the previous data state (`5gmodem.@5gmodem[0].airplane_data`) and puts the radio in low power: `mmcli --set-power-state-low` when MM has exactly one modem, otherwise `AT+CFUN=4` on the detect.sh port. Off restores the power and the previous data state. `data on` is refused while airplane mode is on.
- The modem powers its radio on again after a router or modem reboot. `tick` (every sessionwatch round) re-applies low power once per boot while `airplane=1`, and `/tmp/5gmodem/airplane.applied` marks that it is done. MM appears about a minute into the boot, so the first ticks fail and retry.

## setopt.sh
Instant-save verbs for the Modem/Settings pages: roaming, atdebug, mmat, noat, dnsfb, simpleview, netblocks, reconnect, applyset, menuflush. Toggles used to live in form.Map and needed the page-wide Save & Apply. A dedicated script rather than uci from the frontend: fs.exec under rpcd is ACL-checked, and granting arbitrary `uci` to the web is unsafe; only these fixed verbs are allowed in acl.d.
- roaming: writes the standard netifd option network.<iface>.allow_roaming (read by mbim/modemmanager and our fibocom) and ifups the interface, since roaming is decided at dial time.
- ipwatch: sets or deletes network.<iface>.ipwatch (fibocom proto address watch, see health-and-recovery.md) and reconnects the interface, since the watcher starts at dial time.
- atdebug/mmat/noat create the modem section *with* `path` if missing: without path the modem drops out of "Saved profiles" (modemswitch.sh profiles) and every m_* loop keyed by path; atdebug used to create a bare section that stayed pathless forever if it ran before resolve. mmat = AT polling of an MM-owned modem (mm_at_allowed in quirks.sh); noat = no background AT (bg_at_off in lib.sh).
- dnsfb: DNS fallback state *is* network.<iface>.dns (no separate flag). Applied with `ubus call network reload`, not ifup: static dns is picked up by re-reading config and the user is fixing an already-up link. mkiface keeps it across interface re-creation (OLDDNS). `shift 3` only when there are 3+ args: otherwise the verb's own arguments ended up in the server list (audit 2026-09-12).
- reconnect ("doctor" button step 1): ifdown/ifup in background with fds detached - rpcd waits for EOF and ifup may take tens of seconds.
- applyset: rpcd staged deltas live in the shared /tmp/.uci (uci -c is not a sandbox), so a plain commit picks them up; LuCI menu cache is flushed for tab gating. Also applies SMS storage to the modem in background (set_sms_storage): the config choice only changes reading (sms_tool -s sends mem1); where new messages land is decided by mem3 of +CPMS, otherwise messages keep filling the SIM. Drops the listmodems.sh cache so the "this is a modem" checkbox takes effect immediately rather than after up to 8 s.
- menuflush: LuCI menu tree is cached by mtime of menu files, not by uci, so options gating tabs via menu.d `depends.uci` (align_enabled) need /tmp/luci-indexcache* removed or the tab changes only after reboot.

## atcmd.sh
`atcmd.sh <port> <command> [timeout]` - the only entry for an arbitrary AT command from the AT console page. Previously the page exec'ed /usr/bin/sms_tool directly with browser-supplied arguments (ACL allowed exec on the binary), so anything could be sent: `send <number> <text>`, `delete all`, any /dev port. Same model as setopt.sh: a narrow verb instead of a generic executor. Checks port (is_devpath), command (is_atcmd: no CR/LF inside, otherwise `AT<CR>AT+CPIN=1234` would run as two commands), and that the port belongs to a known modem (listmodems.sh tty list; is_devpath accepts any ttyUSB, incl. foreign USB-UART adapters). Timeout capped at 40 s.
- User command always runs: waits for the AT queue up to 8 s, then runs bypassing the lock (rc=2 from at_query) with its own kill timer. Rationale: the port is usually busy with our own metrics poll and "busy, retry" never succeeds (2026-08-05 a band reset never went through). Queue wait must stay below the ubus client limit of 20 s; 25 s wait + command timeout always produced "XHR error".

## atprobe.sh
`atprobe.sh <tty> [model]` - bounded AT probe (exit 0 if the port answers within ~2 s). sms_tool and gcom have no timeout and block ~35 s on a silent DIAG port; that froze the info page and port auto-detection whenever a DIAG port was selected.
- `model` mode requires an AT+CGMM answer with a model string: on multi-port modems (FM350 has 7 ttyUSB) several ports answer bare "AT", some are auxiliary/DIAG ports without metrics; detect used to take the first one and on some firmware IP came up while metrics stayed empty.
- `[ -c "$D" ]`, not `-e`: after the modem is unplugged the node disappears, but sms_tool opening the dead path creates a regular file (O_CREAT). With `-e` the phantom counted as alive, the poll served a stale snapshot forever (23 h+) and the "modem missing" self-heal never ran.
- Temp file removed by EXIT trap: rpcd kills cold detect of a multi-port modem at 30 s and .atprobe.* files used to pile up in tmpfs (audit 2026-09-12).
- File descriptors: the watchdog subshell redirects its own stdout to /dev/null, otherwise the orphaned sleep holds the caller's pipe and rpcd/cgi-io waits for EOF 2 s more (5gmodem.sh json 0.64 -> 2.03 s). fds 7/8/9 are closed because callers hold the port flock on fd 8 (atlock); an orphaned watchdog kept the port locked after exit.
- No bare `wait`: if sms_tool is stuck in D-state in the tty driver, kill does not work and wait would hang until rpcd's 30 s limit (T99W175 05c6:9025, 2026-08-17). Polls with a ~3 s cap; an unkillable child is abandoned.
- Fractional sleep is not in every busybox (`invalid number`, would become a zero-timeout busy loop); `(sleep 0.0)` probe selects 0.1 s or 1 s step.
- CR/LF folded to newlines, not deleted: some firmware separate the answer with bare CR, and `tr -d` glued it into one line (see at_strip_ok in lib.sh).

## cme.sh
`cme_text <code>` - shared +CME ERROR table (3GPP 27.007 plus vendor extensions). Previously each consumer (smsbridge, 5gmodem.sh, quirks, report) knew ~10 codes and the user saw a bare number like "+CME ERROR: 133". Unknown code returns empty / rc 1; the caller decides what to print.

## listports.sh
Lists /dev/ttyUSB*, ttyACM*, cdc-wdm*, wwan* with owning USB device (vidpid, product, path) as JSON; UI labels AT-port drop-downs with it when several modems are present. Uses the same notmodem.sh filter as listmodems.sh so USB-UART adapters never appear in AT-port lists (picking one would send AT commands into another device's console).

## portmap.sh
Diagnostic port map: USB device -> its tty -> IMEI read from that tty. Built entirely from sysfs, bypassing listmodems.sh, so it can verify our own port-to-modem mapping. Motivating case: two Thales MV31-W reported the same IMEI and the report could not tell "cloned IMEI on two modules" from "our port mapping is wrong and we read one modem twice". The USB serial is printed to distinguish identical modules. Ends with a verdict (duplicate IMEI / no answering port).
- Uses at_lock (short wait) and at most two ports per device (AT port is among the first; full scan of 4 modems would take tens of seconds). Skips noatports.

## ensureports.sh
`ensureports.sh [port]` - seeds AT ports for the SMS/USSD/AT tabs (5gmodem.sms readport/sendport/ussdport/atport). Normally hotplug fills them; a modem plugged in before package install produces no event and the tabs ask "select port" although metrics already work. Only empty/stale values are replaced, deliberate user choices are kept.
- pick_sms_port: separate port for SMS when the modem has several AT ports. SMS tabs and the metrics poll share a tty badly: sms_tool opens the port per call and reads empty if the poll is running (Telit LM960A18: 2 of 5 back-to-back reads empty, 8 of 8 with pauses). Telit has three AT ports (ttyUSB9/10/11). Takes the first answering port other than the metrics port.
- Under ModemManager ports are not ours (GPS/service ports; see netpri.sh operator_probe); SMS go through MM (sms_via_mm), no separate port.
- Dial port is excluded (drop_dial_port): L860-GL under xmm got SMS/USSD/AT console on ttyACM0, the data channel, and every access dropped the session (2026-09-06).
- Existing values are overwritten when: empty; not a char device any more (tty numbers shift after reconnect; `-c` because sms_tool leaves a phantom regular file, see atprobe.sh); equal to the metrics port while a free one was found; equal to the dial port (L860-GL had all four keys on ttyACM0); equal to the dedicated send port (sms_send_port) for non-send keys.

## noatports.sh
Ports where AT must never be sent. Some modems expose a service tty that crashes the modem on AT; port scanning ("who answers AT") turns into a reboot loop (probe -> reset -> re-enumerate -> probe).
- MikroTik R11e-LTE (2cd2:0001, Marvell PXA1802): ttyACM0 (interface 02) is a binary firmware log; AT port is ttyACM1 (interface 04). 2026-09-11: the dial proto picked ttyACM0 and the modem rebooted ~25 s after each ifup; with the interface stopped there were no drops.
- Key is vid:pid:bInterfaceNumber, not node name, since ttyACM numbering shifts with several modems.
- noat_unbind / noat_unbind_iface unbind the driver from the forbidden interface: our guards only cover our code, third-party packages (3ginfo-lite, modemband, sms-tool-js) also scan ttyACM* and crash the modem. Without a driver there is no /dev node at all. Harmless for the modem: it discards the unread log anyway.

## iscompal.sh
`is_compal [usb_path] [cdc_wdm] [at_port]` (also runnable as `iscompal.sh ...`, same exit code) - single identification point for Compal RXM-G1 (module SG500M2-X). The modem switches USB composition with AT+USBCOMP and each composition has its own VID:PID, mostly shared with Foxconn T99W175 / Thales MV31-W / Dell DW5930e (AT-incompatible firmware):

| AT+USBCOMP | class | prototype | new unit |
|---|---|---|---|
| user | MBIM | 05c6:90d5 | 05c6:90d6 |
| debug | QMI | 1e2d:00b7 | 05c6:9025 |
| rndis | RNDIS | 05c6:9058 | 05c6:9025 |

The check used to be copied in seven places (metrics/band profiles, simslot.sh, mkiface.sh) with different criteria; a new composition (1e2d:00b7) broke SIM slot detection again although 90d5/90d6 had been fixed.

Sources, cheapest first: sysfs descriptor -> QMI model (~25 ms) -> ModemManager -> AT.
- Descriptor: "Tri Cascade" manufacturer, product spelled "VOS_5G", "Compal RXM-G1" (with hyphen), "RXMG1" or "SG500M2-X" (same set as quirks.sh). Only RXMG1 used to be matched; a hyphen-spelled unit in QMI composition 05c6:9091 went to proto=qmi with mm_exclude=1 where uqmi cannot open services (2026-09-13). The new unit in QMI/RNDIS has a generic "Qualcomm, Inc. HSUSB Device" descriptor, hence the model fallback.
- With an explicit path only that node is checked, never a bus-wide grep, even if the node is absent (re-enumeration): an absent Telit was counted as Compal by its neighbour's descriptor.
- An explicit wdm is authoritative both ways: if it names another model (T99W175) the answer is "no"; otherwise the fallbacks (active modem, any) let a neighbouring Compal claim a T99W175 in 9025 on a two-modem router. A vanished explicit wdm is never substituted. qmicli_p refuses a channel owned by netifd (proto=qmi).
- MM: with explicit path the answer counts only if the MM modem's generic.device is on that path.
- AT goes through at_query (queue + timeout); a parallel reader used to steal the answer.

## mmneed.sh
`mmneed.sh check|apply|grace [now]` - decides whether ModemManager is needed and starts/stops the service. Previously the decision used config only (any proto=modemmanager interface => MM needed), so MM ran for a modem that was not on the bus. Not harmless: MM grabs all modems at start, including mm_exclude=1 ones; observed MM starting for an unplugged Compal and disabling a working FM350 ("disabled modem"). mm-inhibit.sh is applied afterwards but a window remains.
- MM runs if at least one *present* modem is managed by it. The profile of an absent modem is never touched (user choices: proto, APN).
- A band takeover pause (`/var/run/5gmodem-mm-inhibit/<path>.pause`, bands.sh mmtakeover) keeps MM needed.
- Per MM interface: device as sysfs path -> exact presence check; otherwise profile path vs listmodems.sh; unknown mapping => needed (silently stopping MM for an unknown interface is the worst option).
- Modem moved to another USB port: the stale path said "absent", MM was stopped, then mkiface restarted it, giving several stop/starts at boot over a live MBIM function. DW5821e/T77W968 on Radxa (issue #7) then stuck in power low with "OperationNotAllowed" on every enable; only a power cycle helped. Rule now: MM interface configured and any modem on the bus => keep MM. Stopping is only an optimization (free channels for kernel-proto modems), so err towards keeping it.
- mbimp interfaces with a present cdc-wdm also need MM (shared proxy).
- `_running` uses pidof: procd starts ModemManager without arguments, so the old grep for "ModemManager --" never matched; stop was never called and MM kept the modem after band takeover ("no IP").
- apply never restarts a running MM: restart takes MM down for 1-2 min (D-Bus name race) and drops connections.
- Stop is delayed: not within the first 300 s of uptime (unless `now`), `grace` requires 300 s of continuous "not needed" (stamp in /tmp/5gmodem/mmneed_idle), and the decision is re-checked after 3 s.
- After stopping MM an orphaned mbim-proxy keeps cdc-wdm open (2026-08-03, alive since boot); umbim needs the node exclusively ("open the page - internet drops", manual fix was killall mbim-proxy). Killed only at MM stop (and only if no mbimp interface), not on every apply, since an eSIM MBIM probe may legitimately start it later. qmi-proxy is left alone: QMI multiplexes and our metrics use it.

## register_proto.sh
Registers our netifd proto handlers (fibocom.sh, qmiraw.sh) after package install. netifd scans shell proto handlers only at start; `network reload` / `ubus call network reload` re-read only /etc/config/network, and ifdown/ifup runs the old in-memory registration. Only a netifd restart re-registers, and it drops all interfaces for a few seconds.
- Restart happens only when the proto is not registered (`ubus call network get_proto_handlers` lacks it) and either an interface uses it or `REGISTER_PROTO_FORCE=1` (mkiface sets it when creating a fibocom/qmiraw interface - the user is configuring the modem right now).
- Handler content changes are not a reason to restart: netifd runs the proto script from disk on every dial, so new code is picked up on the next redial; only registration metadata waits for a reboot. The md5 in /etc/5gmodem_proto.md5 (persistent) is logged/stored only.
- History: without restart a fresh install showed "Unsupported protocol type" in LuCI until reboot (LuCI gets the proto list from netifd). 2.3.3 made the restart unconditional; on 2026-08-08 a package upgrade over ZeroTier restarted the network on a remote router (only a stale proto='fibocom' section, or no Fibocom ever), the Wi-Fi uplink did not reassociate / ZeroTier path went stale and the router was lost until physical access.

## ttl.sh
`ttl.sh set <ttl4in> <ttl4out> <ttl6in> <ttl6out>|apply|get` - fixed TTL / hop limit on the modem L3 device. Values in `5gmodem.@5gmodem[0].{ttl4in,ttl4out,ttl6in,ttl6out}`, empty = direction untouched. Interface: configured `network` option, else the first modemmanager/qmi/mbim/ncm/wwan interface.
- Own table `inet modem5g_ttl` (like clash) instead of a fw4 include: independent of fw4 build order and survives fw4 reloads (fw4 flushes only `inet fw4`). "declare - flush - declare with rules" replaces contents atomically on first and later runs.
- The old fw4 include /etc/nftables.d/10-5gmodem-ttl.nft is only deleted now. fw4 in 25.12 places user includes before its own chain declarations; our include declared `chain mangle_prerouting { rule }` without type/hook, so on a cold start nft created a regular chain, then fw4 declared it as base chain and failed with `Chain of type "filter" is not supported`, rejecting the whole ruleset: no fw4 table, no masquerade ("router has internet, clients do not"). Toggling TTL "fixed" it until next reboot because merging into a live table passes. Reproduced with a minimal t4.nft.
- Every rule has `counter`: ping from the router shows TTL of the *reply*, while we change outgoing TTL that only the carrier sees; packet counters are the only proof. `get` sums counters of our tables only - summing the whole ruleset counted foreign TTL rules and showed "working" with our table absent (audit 2026-09-12).
- Flow offloading bypasses prerouting/postrouting: fw4 puts zone devices into the flowtable and established flows are forwarded by the flowtable ingress hook, so only the first packets got the TTL (complaints 2026-09-18). Rules are duplicated in `netdev modem5g_ttl_dev` on the device: egress sees every outgoing packet, ingress at priority -300 runs before the flowtable (fw4 uses 0). Needs NETFILTER_EGRESS in the kernel (official builds have it); without it a log line advises disabling offloading. Hardware offload (PPE) does not accelerate USB modems anyway.
- ICMPv6 is excluded from hop-limit rewriting (`meta l4proto != ipv6-icmp`): Neighbor Discovery requires hop limit 255.

## fcc-unlock.sh
FCC unlock for Dell DW5821e / Foxconn T77W968 (Snapdragon X20): 413c:81d7, 413c:81e0, 413c:81e4, 413c:81e6, 413c:81d8, 0489:e0b5, 0489:e0b4. The firmware waits for the Foxconn QMI "FCC authentication" command (`qmicli --dms-foxconn-set-fcc-authentication=0`) and does not enable the radio without it; per a 2026-09-14 field report (WH3000, 413c:81e0) it also resets USB about every five minutes. An unlocked modem just acknowledges or errors, no reboot.
- `fcc-unlock.sh <dbus-path> <port>...`: called by ModemManager from /etc/ModemManager/fcc-unlock.d/<vid:pid>, only when the modem refused to enable radio (MM_CORE_ERROR_RETRY), once per attempt. MM waits at most 5 s (MAX_FCC_UNLOCK_EXEC_TIME_SECS), so the qmicli wait is 4 s. The stock Foxconn "105b" script does not work here: it looks for an MBIM port, but in QMI composition there is only cdc-wdm on qmi_wwan, so it exited 2 without sending anything.
- `fcc-unlock.sh kernel <usb-path>`: interface on qmi/mbim without MM. Sent once per appearance on the bus (marker keyed by USB devnum, which changes on reconnect); up to 15 attempts, skipped if the interface is already up or AT+CFUN? = 1, waits while umbim/uqmi are dialing.
- send_auth uses the proxy (`-p`) only if MM, qmi-proxy or mbim-proxy already runs: without MM our own proxy stays alive after qmicli, sessionwatch sees "proxy on a direct channel" and redials the freshly up interface (DW5821e 413c:81e0, 2026-09-17). A cdc_mbim node needs `--device-open-mbim`. qmicli can hang forever on a busy channel, so it is time-limited and killed.
- InvalidQmiCommand / not supported / InvalidOperation => the modem does not need it; no retry (rc 3, MM mode exits 0).

## signal-leds.sh
`signal-leds.sh detect|once|off|run|metric <m>|enable|disable` - signal level on case LEDs (Cudy LT300 and compatibles), run by /etc/init.d/5gmodem-leds.
- Does not poll the modem. The original script sent AT+CESQ every 10 s: on LT300 (MT7628, 56 MB RAM) that slowed the system, and two processes on one AT port slow each other ~3x and break SMS reads. Now it reads `5gmodem.sh cached <ttl>` (cache if fresh, otherwise one locked poll); TTL is interval + 5 s so ticks do not always find the snapshot stale. With the web page or 5gtop open the LEDs cost nothing.
- `LEDS_DIR` overrides /sys/class/leds for testing without hardware (`LEDS_DIR=/tmp/5gmodem/fakeleds signal-leds.sh once`).
- LED names from `signal_leds_names` (default `white:signal1 white:signal2 white:signal3`). Availability is checked by LED presence, not board_name (compatible boards; LT300 revisions without them).
- Enabled by default where LEDs exist: empty `signal_leds` means "never configured", only explicit 0 disables (stock Cudy firmware shows the indicator).
- Brightness uses each LED's max_brightness (1 or 255).
- Metric `signal_leds_metric` (rsrp default: tied to physics, not compressed at the top). Thresholds match the web page colouring (5gdetail.js qcolor). Percent (CSQ) thresholds are stricter: on LT300 it stayed at 64-74% with clearly different quality and always lit three LEDs. Missing metric (e.g. SINR on 3G) falls back to percent; not registered (registration not 1/5) => all off.
- enable/disable/metric write and commit uci here rather than uci.save in the browser, which would leave "unsaved changes" in LuCI staging after a checkbox click.

## antenna.sh
`antenna.sh detect|status|set <mode>|apply|run` - case antenna switch of Notion R281 / Yota C300-1 (MT7621), run by /etc/init.d/5gmodem-antenna. Logic from the stock antenna-gpio.ko driver (OpenWrt 15, kernel 3.10), which wrote GPIO bank 0 registers directly; here via sysfs:

| GPIO (bank0) | meaning |
|---|---|
| 11 | chain 1: 1 = external, 0 = internal |
| 9 | chain 2: 0 = external, 1 = internal |
| 14 | chain 1 detect: 0 = antenna connected |
| 12 | chain 2 detect: 0 = antenna connected |

- Modes: internal, external, auto (each chain external if its sensor sees an antenna), mix (chain 1 as auto, chain 2 always internal). The driver re-evaluated auto/mix on a timer; here it is the `run` loop (3 s).
- Sensor only detects antennas that short the connector to ground at DC; a passive antenna without such a path is "absent".
- Only this board: on other boards the same pins can be anything (LED, modem reset), so GPIO is touched only with board_name `notion,r281` and controller label `1e000600.gpio-bank0`.
- Pin numbers are computed from the bank base (not hardcoded 521): base depends on kernel and controller registration order.
- Output is set by writing high/low to `direction`: level and direction change in one operation, without a short low glitch.
- Detect read empty = pin busy or not muxed as GPIO in this build's DTS.
- `ANT_SYSGPIO`, `ANT_BOARD_FILE` override paths for testing.

## powercheck.sh
Read-only JSON report of USB power starvation signs. An under-powered modem enumerates *partially* and looks like a software bug: FM350 kept the AT channel but radio was dead (CSQ 99,99); Compal brought up AT ports but the CDC (MBIM) interface stayed driverless, so MM reported "no modems". Two modems at 896 mA bMaxPower each = ~1.8 A, more than the bus provides; kernel says "device descriptor read/8, error -71" and "Cannot enable. Maybe the USB cable is bad?".
- Main sign: a CDC control interface (class 02) without a driver. Class ff interfaces (DIAG etc.) without a driver are normal and not counted.
- Kernel errors are counted only if fresh (<=120 s by dmesg timestamp vs /proc/uptime). Previously `dmesg | tail -80` was used: tail counts lines, not time, so on a quiet bus an old error stayed in the tail forever and the warning showed on a working modem.

## apn-update.sh
`apn-update.sh version|check|update`. Updates the world APN database (providers.tsv, generated from GNOME MBPI + AOSP, see licenses/PROVIDERS-NOTICE.txt) from upstream.
- URL from `5gmodem.@5gmodem[0].apn_db_url` (set a mirror on whitelisted-only routers). Default points to the openwrt-apn-autoconfig repository under its current owner; the URL under the previous owner name returns 404, and updates silently failed for everyone because the script is only run manually.
- Downloaded DB goes to /etc/5gmodem/providers.tsv, not over the packaged /usr/share/5gmodem/providers.tsv: /usr/share belongs to the package manager and an app upgrade would restore the build-day snapshot, losing the user's download. Readers (apn_pick in msw/apn.sh) prefer /etc.
- Fetch through net_fetch (lib.sh): direct, then via local clash/mihomo (carrier whitelists block direct router requests).
- Validation: >=500 data rows with >=8 TAB fields, so an HTML error page or a truncated file never replaces the DB; replacement is a single mv.
- Version comes from the header line `# database-version: YYYY.MM.DD`; operator count changes by a few between versions, so comparing counts alone would report "no updates".

## ssclash.sh
`ssclash.sh detect|status <go|legacy>` - detects SSClash for the web-UI link cards in the "Internet priority" block. Two independent branches that may both be installed (5.x is often installed over 4.7), each with its own card:
- go: SSClash-Go 5.x, binary /opt/clash/bin/ssclash, service `ssclash`, web UI of `ssclash serve` on :9091 (env SSCLASH_ADDR in /etc/init.d/ssclash), path "/". Port is taken from the actually listening process first (survives SSCLASH_ADDR changes), then from the init script. HTTPS if SSCLASH_TLS_CERT is set.
- legacy: SSClash 4.7.x, package luci-app-ssclash, service `clash`, binary /opt/clash/bin/clash (mihomo). No own web server; the dashboard is served by clash external-controller (config.yaml, :9090) + external-ui at "/ui/". Version is from the luci-app-ssclash package (fallback: clash core).
- The "v" prefix is added by us: 5.2.4 prints "ssclash v5.2.4", 5.3.0 prints no "v"; the package prints bare "4.7.0".
- status uses shared svc_running (lib.sh): a procd service without instances exits 0 from `status`, so the dot would show green falsely.

## nikki.sh
`nikki.sh detect|status` - detects nikki (mihomo, nikkinikki-org/OpenWrt-nikki) for the web-panel link card in "Internet priority". Same verbs and JSON as ssclash.sh. Separate file because it is a different project (own service, paths, config), not a third SSClash branch.
- Service /etc/init.d/nikki (procd), core /usr/bin/mihomo. Runtime config /etc/nikki/run/config.yaml is generated from uci at service start (files/ucode/mixin.uc), so it reflects what the process really listens on; before the first start it is absent and uci section `nikki.mixin` is used. uci keys: api_listen -> external-controller, api_tls_listen -> external-controller-tls, ui_name -> external-ui-name, api_secret -> secret.
- Panel served by mihomo external-ui at "/ui/" or "/ui/<external-ui-name>/", same as luci-app-nikki (tools/nikki.js openDashboard).
- addr_port takes the part after the last colon: default api_listen is '[::]:9090', and the `[^:]*` parse used in ssclash.sh yields garbage on it. Default port 9090 when nothing is configured.
- TLS listener wins; secret is passed to the card (luci-app-nikki puts it in the link as query parameter, otherwise the panel asks for a password).
- Version is from the nikki package (date-numbered, 2026.04.08), fallback mihomo core; "v" prefix added by us.
- status: svc_running, because procd `status` on a stopped service prints "active with no instances" and exits 0 (measured 2026-09-09).
