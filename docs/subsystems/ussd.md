# USSD

USSD requests are sent by `root/usr/share/5gmodem/ussd.sh`, which `htdocs/luci-static/resources/view/modem5g/sendussd.js` starts and then polls. On the AT path the script can move the modem to 3G for the duration of the request and always restores the previous network mode afterwards. The page decodes the raw network reply itself. A second path sends USSD through ModemManager (`mmcli --3gpp-ussd-*`) for modems whose AT port cannot do `+CUSD` while ModemManager owns them.

Usage: `ussd.sh send <code> [port]`, `ussd.sh status`, `ussd.sh cancel`. The state is kept in `/tmp/5gmodem/ussd.json`.

## Why switch to 3G

USSD is a CS-domain service, and LTE has no CS domain. The modem tries CSFB by itself, and on a Telit LM960 (MegaFon) that is a dead end. It takes 30 s, passes through `+CREG: 3` (denied) and `+CREG: 2` (searching), ends with `+CUSD: 4` ("operation not supported"), and the modem needs another 30 s to get back onto the network. The same code with the modem already registered in 3G returns the balance within seconds.

Changing a single RAT is applied live, without restarting the radio, and takes about 5 s each way (Telit `AT+WS46=22/31`, FM350 `AT+GTACT=1` / `20,6,3`). The full cycle, request included, fits in about 20 s, against 30 s for a failed CSFB.

### When the script switches

Switching is off by default. Some modems do get a USSD answer in LTE through CSFB, and switching costs about 20 s offline, so forcing it on everyone would break setups that work. The decision is per modem:

1. the explicit `ussd_3g` in the modem's own section (`m_<path>`);
2. otherwise the verified-modem database `quirks.sh: ussd_needs_3g_for` (currently only the Telit LM960A18);
3. otherwise no switch.

The global `sms.ussd_3g` describes only the last selected modem (it is set by `msw/identity.sh apply_ussd_quirk` on a modem switch). On a fresh install or after an upgrade it could hold a `1` left over from another modem. A Fibocom L850 then went to 3G for nothing as soon as its profile gained 3G modes, dropped its session, and still answered "modem did not respond" (2026-07-31). The page's banner reads the same per-modem key. It used to read the global key, so it promised a switch the script would not make (audit 2026-09-12). The settings checkbox writes both the global key and the modem section, so the choice survives a modem switch, where `modemswitch.sh` would otherwise reset it from the database.

The switch also happens only when:
- the modem is not already on a CS-capable RAT. The current technology comes from the last field of `AT+COPS?` (7 = LTE, 11/13 = NR). `CREG` is not used, because its format depends on `<n>`, and with `n=0` it carries no technology at all (the FM350 answers `+CREG: 0,1`);
- the port belongs to the active modem. `bands.sh` works on the active modem only, so switching for a request to another modem's port would disrupt the neighbour's network. The reply then carries `noswitch: not_active`;
- the modem is not marked "USSD does not work" (see below).

The "3G" mode id is looked up in the modem profile by its label, which must be exactly `3G`. Profiles number modes differently (Telit `2:3G`, FM350 `1:3G`), and the FM350 also has `3G+4G`, which would keep it in LTE.

### Restoring the mode

Leaving the modem in 3G silently cuts the user's speed to a third, so the restore runs from a `trap` on EXIT/INT/TERM and is checked afterwards.

- The first version once left a modem in 3G. The original mode could not be read because the port was busy, `setmodelive` got an empty string, answered "no mode", and nobody noticed. Now `getmode` is retried after 3 s, the fallback target is the profile mode labelled `Auto`, and after restoring the script checks `getmode` again and retries once if the modem is still in 3G. The interface is brought up again (`ifup`) at the end.
- `SWITCHED=1` is set right after the switch command is sent: if the command took effect, the mode must come back however the wait ends. Restoring is idempotent.
- The switch counts as successful when CS registration appears, not when `setmodelive` answers. `setmodelive` verifies through `getmode`, which reads the AT port and is slow on a busy port.

`_wait_reg` waits up to `REG_WAIT` (25 s), which leaves margin over the measured 5 s for when a 3G cell is busy or has to be searched for. It polls every second for the first 6 s, where the answer usually arrives, and every 3 s after that. A fixed 5 s step added up to 8 s of idle waiting. A 1 s step over the whole window would mean 25 AT requests into a busy port.

## One request only

- Exactly one request is sent, switched or not. The script makes no second attempt with the opposite `-R` form: an extra `+CUSD` in LTE itself triggers CSFB and drops registration for half a minute (measured), so the "cheap" retry is the most expensive option.
- Concurrency is controlled with `flock -n` on `/tmp/5gmodem/ussd.lock`, held on fd 9 for the whole run. The background subshell inherits it, and the kernel releases it when the subshell exits, even if it is killed. The previous check (a `running` state younger than 120 s) left a window between reading and writing the state file in which two sends could both pass and flip the RAT against each other. That check remains as the fallback when `flock` is missing.
- When a request is refused (bad code, no port), the state is reset to idle, otherwise the page kept showing the previous `done`. On `busy` the state is left alone, because the file belongs to the running request (audit 2026-09-12).
- The code goes into an AT command, so only `[0-9*#+]` is accepted. A quote in the field would otherwise close the string, and the rest would reach the modem as a separate command.

## Background execution

rpcd kills a call after 30 s, and the cycle comes too close to that, so the work runs in a detached subshell and the page polls `status`. The subshell's stdout, stderr and stdin are redirected on the subshell itself (`( ... ) >/dev/null 2>&1 </dev/null &`), not inside it. Otherwise rpcd keeps waiting for our output and hits its own 30 s limit (the same pitfall as `collect.sh`). The script sleeps 1 s before exiting, because rpcd tends to lose a fast exit that leaves a background child behind. `stage` starts as a neutral `starting`. It used to be `switching` before the decision was made, so the page announced a switch even where none would happen (Compal, 2026-07-31). The `out`/`err` fields are base64, because raw `sms_tool` output contains quotes and newlines.

## Port selection

Order: `sms.ussdport` (the page shows the modem behind this port, so the request must go there), then the active modem's `at_port` from `registry.sh active`, then `detect.sh`. Putting the active modem's port first was tried and was worse: the active modem and the open tab can differ, and requests went to the wrong modem. That bug (2026-07-30) came from three local helpers (port choice, "is this the active modem's port", port owner) that disagreed with each other. Everything now comes from `registry.sh`, which also checks the saved `at_port` against the modem's real port list and returns nothing when the setting is stale.

## sms_tool arguments

The script builds them, not the page, so that the sending policy lives in one place:
- `-R` sends the code as plain text (unless `sms.ussd=0`). Otherwise `sms_tool` packs it into GSM-7 hex, which is correct only with the TE character set `"HEX"`, and we never set that;
- `-r` returns the answer raw. The page decodes it, because `sms_tool`'s own decoding breaks on modems with byte-swapped UCS2;
- `-c <coding>` is passed only when the user set one explicitly.

## Decoding the reply (sendussd.js)

- The Telit LM960 returns UCS2 with the bytes swapped: `54.76 р.` arrives as `350034002E00…`. 3GPP TS 27.007 (and the FM350 manual, word for word) require the high octet first. `sms_tool` follows the spec and prints `㔀㐀⸀㜀㘀` (verified with a MegaFon balance). The byte order is therefore detected from the data. The high half of every pair is small, because every script that shows up in USSD lives in the first Unicode pages, while the low half is spread over the whole range. "Every other byte is zero" is not enough, because in Russian text the high byte is 00 for Latin letters and digits but 04 for Cyrillic. The first version of the parser failed on exactly that. The comparison is strict: a tie keeps the spec order (BE).
- The modem is never asked for the coding scheme. Per the manual, in UCS2 it must send hex, and with the 7-bit alphabet it converts the string to the TE character set itself. Hex therefore means UCS2, and anything else is already text. If a full `+CUSD: <m>,"<str>",<dcs>` line is present, its `<dcs>` wins: per 23.038, bits 3-2 = 10 means UCS2 (e.g. 0x48 = 72). Without a dcs, UCS2 is recognised when one half is almost entirely small. The threshold is below 100%, so that an emoji or one wide character does not break detection.
- GSM-7 with a GSM-7 dcs arrives as packed septets and is unpacked. A trailing 0x00 left by padding is dropped (0x00 in the middle is `@`). Some modems send unpacked text with dcs=15, in which case the readable variant is used.
- A bare number is not hex. A balance of `1500` minutes has an even length and only digits, so it was "decoded" into a single invisible control character (audit 2026-09-12). Hex decoding now requires at least 4 characters, and the result is accepted only if it is readable.
- MM path: `mmcli` prints the reply in single quotes inside its service text. The capture is greedy up to the last quote, because the reply may contain apostrophes. stderr is shown as is.
- "No network service" while the internet works almost always means the modem is registered in LTE only and USSD needs CS (Telit LM960: this exact error in LTE, and the balance after switching to 3G). The page shows a hint instead of leaving the user stuck.

## Page behaviour

- Stages are printed with the same typewriter animation as the answer, and only when the stage changes, because the poll runs every 2 s and restarting the animation on every tick would reset it. In history mode ("keep previous answer"), `typewrite()` clears the whole `<pre>`, so the first "Sending request…" wiped the operator's menu and there was nothing left to reply to (audit 2026-09-12). In that mode stages are appended without animation, and the history is restored before the answer. The last stage's animation is stopped before the answer is printed, because it kept typing into the answer.
- A start failure is parsed immediately. `ussd.sh` prints `{"error":...}` without touching the state file, which still holds the previous `done`, so the first poll showed the previous answer as the answer to the new code (audit 2026-09-12).
- The poll gives up with margin over the measured 18 s. An in-flight guard stops rpcd calls from stacking up. The timer is stored on the view and stopped in `leave`: before that, polling lived for up to two minutes on a closed page, wrote into a detached `<pre>`, and after returning there were two pollers (audit 2026-09-12).
- An empty answer is explained: `unsupported` (the module's firmware cannot do USSD) or `noswitch` (the request went to a modem that is not active, so no 3G switch was made).
- A bare `Delete` key used to wipe the whole code field, so a long code could not be edited (audit 2026-09-12). Clearing now needs Ctrl or Shift.
- A ReferenceError on `res` in an outer scope used to swallow the real error, and the user got no notification at all.
- The code list is a `ui.Dropdown` rebuilt when the code file changes. It has no `<option>` or `.value`, so the node is replaced. A select placeholder ensures that picking the first code also fires an event.

## Warnings on the page

There are three distinct causes, and they must not be confused:
- `supported=0`: the module cannot do USSD at all. This is a firmware property from the verified-modem database (`quirks.sh: ussd_supported_for`). Some data-only modules advertise `+CUSD` but never answer, so the page used to hang until timeout and the app got the blame. The FM350 firmware does not answer `+CUSD` in any mode (full matrix tested). The page warns but does not block, since the database may lag behind new firmware. `ussd.sh` still sends the request, without the 3G detour.
- `sms_only=1`: the module could, but the network registered the subscriber as "SMS only" (CREG 6/7), and USSD belongs to the voice domain. This may resolve itself on another network or plan.
- The modem is in LTE/5G, so USSD will go through CSFB. The text depends on the per-modem `ussd_3g` setting.

The data comes from `modemswitch.sh ussdsupport`, which is the sixth result of `load()`. The code used to read the fifth, `uci.load('defmodems')`, which resolves to a list of package names, so `JSON.parse` always threw and all three warnings were dead (audit 2026-09-12). The network mode is taken from the metrics snapshot, keeping only the mode part (`LTE | B3 (1800 MHz)` gives `LTE`).

## ModemManager path (ussd_via_mm)

- Used for modems whose `+CUSD` on the AT port does not work while ModemManager manages them (Compal RXM-G1 / Tri Cascade VOS_5G). No port is needed.
- `ussd_via_mm` is global, but the transport belongs to each modem. Set for a Compal, the flag sent a Telit's USSD through `mmcli` as well once the Telit became active. The flag means "MM path allowed", and the active modem's interface protocol decides, using the same logic as SMS (`smsbridge.sh: _active_is_mm`).
- The MM index is not stable across reboots and reconnects, so `mmcli -L` is queried every time. With several modems, the one in the best working state is chosen (connected > registered > enabled), skipping disabled and locked ones. The first one in the list may be disabled, which gave `modem not enabled yet`.
- Sessions: if the network is waiting for an answer, `respond` is used, otherwise `initiate`. Before a new session any stuck session is cancelled: after a timeout or error, MM leaves the status `active`, and further `initiate` calls fail with "a session is already active".
- Every `mmcli` call has a timeout below rpcd's 30 s. Cancel had none, and on the Compal, with its USSD state machine stuck ("active", cancel answering QMI `Internal` after many seconds), the XHR died before any reply and the user saw an endless spinner.
