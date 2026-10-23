# SMS: reading, sending, storage, archive

Every SMS operation in the app goes through one script, `root/usr/share/5gmodem/smsbridge.sh`. It picks the transport for the target modem: `sms_tool` on an AT port, the `sms_tool_mm` wrapper over `mmcli` for modems owned by ModemManager, or `hilink.sh` (HTTP API) for HiLink sticks that have no AT port. Whatever the transport, the output is in `sms_tool -j` format, so the pages (`readsms.js`, `smssettings.js`, the status include `10_5gmodem_sms_info.js`), the notifier (`tgnotify.sh`) and SMS commands (`smscmd.sh`) never need to know which one was used. The bridge also owns the read/unread memory, the outgoing queue, the router-side archive, and the slot purge. Its own PDU encoder, `smspdu.sh`, handles text that GSM-7 cannot carry.

Related docs: [notifications.md](notifications.md) (Telegram/ntfy/webhook, SMS commands, LED, cron), [ussd.md](ussd.md).

## smsbridge.sh verbs

| Verb | Purpose |
|---|---|
| `recv`, `sent`, `status [store] [port]` | inbox / sent list (JSON), storage line |
| `dump [store] [port]` | inbox as plain text (for "save to file") |
| `delete <index\|all> [store] [port]` | synchronous delete |
| `delete-start <i,j,...>` / `delete-run` / `delete-status` | background bulk delete with progress in `/tmp/5gmodem/smsdel_<path>.json` |
| `send <number> <text> [port]` | send, falling back to the queue |
| `queue-run`, `queue-list` | resend one queued message per round / list the queue |
| `seen`, `seen-add <key>...`, `seen-reset` | read/unread memory |
| `tg-add`, `list-add <channel> <key>...` | per-channel "delivered" lists (tg, ntfy, hook) |
| `unseen <lists> [store] [port]` | unread messages for the given lists (used by the notifier) |
| `newdump`, `newcount [for=<path>]` | unread mirror for external programs and the envelope badge |
| `markread` | HiLink only: mark read on the stick |
| `fwdhead` | header line for forwarded messages |
| `archive-run`, `archive-why` | archive merge plus slot purge / purge diagnostics |

The target modem is `SMS_MODEM=<usb path>`. When it is not set, the active modem is used. The notifier and SMS commands go through every modem in `registry.sh paths` this way. Before that change, a router with a Compal and a Telit never forwarded the Telit's messages (2026-08-01).

`dump` exists so that the browser no longer needs `exec` permission on `/usr/bin/sms_tool` in the ACL, which used to let any arguments through from the page. `smssettings.js` and the status include also call the bridge instead of the binary for the same reason. One side effect: the string `'2>/dev/null'` used to be passed to `sms_tool` as a literal argument, because `fs.exec` is not a shell.

## Transport selection

- `_via_mm` decides. It requires `5gmodem.sms.sms_via_mm=1`, an executable `sms_tool_mm`, and `_active_is_mm` for the target modem. The flag is global, but the transport belongs to each modem. When the flag was set for a Compal, switching the active modem to a Telit sent the Telit's SMS through `mmcli` as well, and the list came back empty. So the flag now only means "the MM path is allowed". The protocol of the target modem's interface decides:
  - `modemmanager` always uses MM;
  - proxy protocols (`mbimp` and the like, `proto_in proxy`) use MM only while `_mm_ready` says MM has the modem in an `enabled`..`connected` state. The answer is cached for 15 s in `/tmp/5gmodem/smsmm_*`, and a change is logged.
- Deciding by protocol alone failed on hardware. On a Compal RXM-G1, sending through ModemManager fails inside the firmware (`MobileEquipment.PhoneFailure: MBIM status error: Couldn't send SMS part`), while `sms_tool` on the same modem's AT port works. The global zero in the config was correct for that hardware, so the flag stays decisive.
- `_port_is_mm` (used for sending) asks `registry.sh port` for the port's owner, and also requires `mmcli -L` to list a modem. While the bridge itself inhibits the modem, the port is free and plain AT is the right path.
- HiLink branch: used when `kind=hilink` and either web metrics are on or the modem has no AT character device. The AT port is read from the target modem's own section, not the global key: the global key describes the active modem, so a neighbouring stick would otherwise use someone else's port. `hilink.sh` always gets the path. Without it, delete, send and the counter all went to the active modem's SIM (audit 2026-09-12).
- When there is no port at all, the bridge returns `[]` rather than an error, so the page shows "no messages" instead of a red message about a missing `/dev` node.

## Port lock and timeouts

- Reads take `at_lock` (atlock.sh) with a 15 s timeout. Before this, reads running in parallel with metric polling came back truncated, and other commands' answers ended up in the message text. If the lock times out, a read goes ahead anyway: losing messages is worse than the risk of mixed output.
- `at_lock` sets nothing on failure (`_AT_LOCK_HELD` stays empty), so "did we get the lock" is taken from its return code (`_AT_LOCKED`). Testing the variable meant the send guard never fired (audit 2026-09-12).
- `_sms_run <timeout> cmd...` runs `sms_tool` in the background with a watchdog, because `sms_tool` has no timeout of its own. An L850/XMM silently hangs on `delete all` (2026-07-31). Every SMS operation after it queued forever, and the page spun "Loading messages" endlessly. The watchdog closes the port fds (`8>&- 9>&-`), like `at_query`. If another process holds the port in a long operation (`at_long_busy`), the call returns early.
- `queue-run` with an empty queue exits before the lock, and before sourcing `lib.sh`. It runs every `sessionwatch` round, and its idle waits of up to 15 s piled up with the real readers until they choked the SMS page (2026-08-10).
- `status` while the port is busy returns the last good answer from `/tmp/5gmodem/smsstatus_<port>`. A counter has nothing to lose. One more waiter on a hung port also used the short `-s ME` form, which moves FM350 reception to the SIM (see below). Field report from 2026-09-14 (FM350-GL, app 2.5.1): `sms_tool -s ME status` stuck in D state on ttyUSB3, and the metrics port busy for eight minutes.

## Storage (CPMS)

- `sms_tool -s XX` sends the short form `AT+CPMS="XX"`. In answer, the FM350-GL resets mem2/mem3 to the factory `SM`: `ME|ME|ME` became `ME|SM|SM`, checked on a live modem on 2026-08-31. Every opening of the Inbox therefore moved reception back to the SIM while we read modem memory, and the user saw an empty list with an SMS already delivered.
- So `_store_pick` applies the full three-slot form (`sms_apply_cpms`, lib.sh) and calls `sms_tool` without `-s`, because it reads the current mem1 anyway. The short form is used only when the full form could not be applied. `smstool_led.sh: store_arg` does the same, since the LED watchdog runs in a loop and would otherwise break reception again and again.
- The storage is set again once per boot, under the port lock, for the active modem only. The `storage` key is global, and the bot walking neighbouring modems would otherwise overwrite it with their values. There are two reasons for this. First, many modems lose `+CPMS` after their own reset, and `set_sms_storage` only runs from resolve/autosetup, so mem3 goes back to the factory value in between. Second, version 2.4.38 wrote an unreachable storage into the config for some users (complaint of 2026-08-30). The marker `/tmp/5gmodem/cpms_<port>` is set only on success, with at most three failed attempts, because a silent modem would cost an AT timeout on every bot round. If the value was corrected to match reality, the corrected one is used.
- `sms.storage_touched=1` (written by `smssettings.js` only when the user changes the value) makes `set_sms_storage` in `msw/iface.sh` keep the user's choice. Without it, the choice would be overwritten on every modem switch.

## Reading

### Status line format

`status` prints `Storage type: XX, used: N, total: M`, the `sms_tool` format. Older code took the count as `substring(17, indexOf("total"))`, and `Storage type: MT,` is exactly 17 characters, so every producer (the bridge with the archive on, `sms_tool_mm`, HiLink) prints a two-letter label. `readsms.js: sms_parse_status` now uses a regex. The positional parse broke on any format deviation, `u` came back empty, and the list silently stopped redrawing because rendering was guarded by `if (u)`.

With the archive on, `status` counts the archive rather than the modem. When the purge is active the modem is nearly always empty, so "used: 0 of 10" would be true for the hardware and false for the inbox the user actually reads.

### Timezone

`sms_tool` prints SMS time in UTC and ignores `$TZ` (on a live port, `TZ=MSK-3` and `TZ=UTC0` both give `+0000`). The browser converts to local time (`readsms.js: sms_localtime`), since it knows the user's zone. Messages displayed three hours off before this. The bridge adds a `tz` field when it knows better:
- `_pdu_tz` reads the raw PDU (`sms_tool -r`), takes the timezone from the SCTS (quarter-hours, sign bit) and caches it per port in `/tmp/5gmodem/smstz_<port>`, keyed by a signature of indices and timestamps. It is skipped for MM.
- `sms_tool_mm` emits `tz: local`, because `mmcli` timestamps are already local.
- The archive stores `#tz=` in the file header.

The notifier and SMS commands compare ages in UTC for the same reason.

### Encoding fixes

- `utf8_fix` (lib.sh) runs once, at the bridge output. `sms_tool` prints U+00A0 and guillemets as single latin1 bytes. This used to be fixed only in the bot, so the Inbox page showed replacement diamonds. The bridge is the only way in to messages for every consumer, so the fix lives there. It is idempotent: valid UTF-8 passes through unchanged.
- `sms_tool` 2025.08.x `-j` sign-extends code points whose low byte is >= 0x80 and prints `ÿffffa0`-style escapes. `readsms.js` rewrites `\uHHffffffLL` to `\uHHLL` before `JSON.parse`. The real fix belongs in the `sms_tool` JSON escaper.
- `sms_tool` escapes `\n` but not `\r`. On an MV31-W the sender arrives as `beeline\r`, and a raw CR is illegal in JSON, so `JSON.parse` threw and the page showed "no messages" with a counter of 3/3 (2026-08-10). Over SSH the same JSON looked fine, because `jsonfilter` is lenient. The page replaces raw control characters with spaces and trims the result. The archive strips CR from the sender for the same reason (see below).
- The `sms_tool` UCS2 decoder replaces U+0080..U+00FF with U+FFFD. Operators use those code points mostly as spaces, so the page turns U+FFFD into a space.
- The bridge escapes JSON with `sed`, not awk `gsub` (`_nd_jesc`, `seen`). In busybox awk the `gsub` replacement `"\\\\"` produced one backslash and `"\\\""` a bare quote, so the function failed to escape exactly the characters it was written for. A sender name containing a quote or backslash broke the whole `seen` JSON, and the page and bot then got an empty seen list and resent everything every round (audit 2026-09-12).

### Multipart messages

- Parts are stored and returned as they are, with `part`, `total` and `reference`. Consumers merge them: `readsms.js` and `tgnotify.sh`, plus the key builder `_kb_build` in the bridge.
- The merge groups by UDH reference (plus sender and total), not by timestamp: parts of one message differ by seconds. Parts are ordered by part number, not by storage index.
- One part number means one segment. A segment can be stored twice when the operator resends a lost part, and both copies stay on the SIM with different times. On 2026-09-06 (T-Mobile, ref=8) part 1/4 arrived at 15:09 and the full set at 15:10, so the start of the message was shown twice. The later copy wins, because it belongs to the set that arrived complete.
- If fewer parts exist than declared, the page shows a notice. On a full SIM the tail of a long message simply does not fit (seen: 3 of 5 parts at 15/15), and a silent fragment looks like our bug.
- `mergesms` handling: an unset value rendered nothing, because neither branch ran, so the page now normalizes it with "1" as the default. The shipped config has `mergesms='0'`, so the page turns merging on automatically when it sees `total > 1`. It records `mergesms_auto` so that a later opt-out by the user is respected.

## Read/unread memory

- A modem cannot be asked whether a message was read. `sms_tool -j` does not return the status, and `AT+CMGL="ALL"` reports `REC UNREAD` only until the first read, after which the modem marks everything `REC READ`. So the app tracks this itself, and the router keeps the memory. `localStorage` would be different in every browser (a phone would not know what was read on a laptop) and is lost when the cache is cleared. The bot uses the same memory, which is why it does not resend after a reboot.
- Files: `/etc/5gmodem/sms_seen.<path>` for the page, and `sms_tg.<path>`, `sms_ntfy.<path>`, `sms_hook.<path>` for each forwarding channel. `sms_tg` is copied from `sms_seen` once (marker `sms_tg_migrated`). The files are kept per USB path, not per SIM: the app does not store the ICCID, and asking the modem for it on every mark would mean an AT round-trip in the shared queue. The cost of a miss is mild, because after a SIM swap some messages light up as new once. Each list is trimmed to `SEEN_MAX` (500) plus `archive_limit` lines.
- Keys are built in the bridge (`_kb_build`) and returned in a `keys` array next to `msg`. A single message gets `sender|time|hash16(sender|time|text)`. A multipart group gets the time of its first part plus a hash of the joined text. The legacy key `sender|time` is still accepted (`_kb_known` checks the old form for every member of a group), so lists written by older versions stay valid.
- The storage index is never part of a key, because the modem reuses freed indices and a new message would inherit an old mark. The part number is not part of a key either: the page has merged and split views, so a key that included it would change on toggle and flash the whole inbox as new.
- A merged card carries all its part keys (`data-keys`), including dropped duplicates, and marking it marks all of them. Parts of one message can carry different times (the SMSC stamps each segment, and a resent segment arrives a minute later). When only the first part was marked, the envelope badge never cleared, because `newcount` counts per part (2026-09-06, the T-Mobile ref=8 case above). A card counts as unread if any part is unmarked.
- The seen file belongs to the modem whose list is on screen. The arrows on the page change only `sms.readport`, so marking a neighbour's messages wrote its keys into the active modem's file. The neighbour's badge never cleared, and the foreign keys could hide a future message from the same sender in the same minute (audit 2026-09-12). The page resolves the path from the port via `listmodems.sh` and, if it differs from the active modem, calls the bridge through `fs.exec` with `SMS_MODEM` set.
- First run (no file yet): `seen` returns `{"first":1}`. The page records the current messages as seen and draws no badges, since they may have arrived a year ago. `newdump` does the same for a modem it meets for the first time, writing the file directly because keys contain spaces and would split as `seen-add` arguments. With the bot enabled, `tgnotify` runs before `newdump` in the loop and has already created the file.
- `newdump` writes the unread mirror `/tmp/5gmodem/sms_new.json` once per `sessionwatch` round, for every modem. `newcount` reads the mirror, which is cheap and needs no AT, so the page can poll it on every tick. Because the page writes `seen` instantly but the mirror updates only once a round, `newcount` subtracts each modem's seen file. It does this for the total across all modems too, otherwise the total overcounts.
- Devices without an SMS channel (no tty, no cdc-wdm, not HiLink; a tethered phone, for example) are skipped before reading. With an empty port, the bridge falls back to the global `readport`, and the active modem's inbox would show up again under the phone's name. Modems with background AT disabled by their owner (`bg_at_off`) are skipped too.

## Sending

### Transport per port

`_send_one <port> <number> <text> [fast|slow]`:

- **The port belongs to MM** (`_port_is_mm`, or a proxy proto with MM ready): send through `sms_tool_mm`, since MM keeps the port open and reads every answer, and it encodes UCS2 itself. If MM fails, the AT path is tried, because it sometimes wins the read race. Cyrillic needs our own PDU there too: `sms_tool` would send `?????`.
- **The port is ours**: our PDU path (`_send_pdu`) is primary for all text, and `sms_tool` is the fallback only for GSM-7 text. `sms_tool send` does not wait for the `>` prompt after `AT+CMGS`. It sleeps exactly 1 s, sends the body, then waits only 5 s for `+CMGS:`. Modems that are slower than that answer `No response from modem`. On an EP06-E sending never worked through `sms_tool`, while our dialog (2 s pause, read up to 25 s) got `> / +CMGS: 71` on the same port. UCS2 also encodes Latin text correctly, with a slightly shorter part limit.
- **Time budget**: the page uses fast mode (MM 20 s, AT 15 s), the background queue slow mode (60/45 s). Through MM, a Compal in MBIM took 6 s for one run of a command and 88 s for the next. It is better to say "queued" quickly and finish in the background.
- **Lock**: `send` requires the port lock. Writing over another exchange loses the `>` prompt and leaves garbage on the port. Without the lock the message goes to the queue.

### Encoding limit of sms_tool

`sms_tool` works in PDU mode and picks GSM-7 for Cyrillic, so the recipient gets `?????`. This reproduces with the tool alone, without the app, and `-c 2` has no effect on `send` (it applies to USSD). Non-GSM-7 text is therefore always sent as our own UCS2 PDU (`smspdu.sh`).

### Number normalization

`_norm_num` brings the number to international format once, for every transport. The page passes the number as typed or as stored in the phonebook, and the `+` gets lost. Two failures looked like "SMS does not go out":
- ModemManager on a QMI modem (Compal): `Unhandled QMI protocol error (54): Couldn't write SMS part ... WmsCauseCode`;
- our PDU marked the number as national (TOA 0x81) and the SMSC answered `+CMS ERROR` (Telit).

Rules: a leading `+` is kept. A leading `00` becomes `+` only if at least 9 digits follow, because service numbers such as `000100` also start with `00` and the network rejects `+0100`. 11 or more digits not starting with the trunk prefix `8` or `0` are treated as international without the `+`. Short numbers (900, 0500) and national `8XXXXXXXXXX` are left alone. `smspdu.sh: _num_pdu` applies the same TOA rules. Queue entries written before normalization existed are normalized when they are sent.

### PDU send dialog

`_send_pdu <port> <number> <text>`:
- `AT+CMGS=<len>` is answered with a `>` prompt, and only then does the modem accept the PDU terminated by Ctrl-Z. `sms_tool at` cannot hold such a dialog.
- gcom was tried and proved unreliable: on a Compal RXM-G1 it timed out even on `AT+CMGF=0` while `sms_tool` worked on the same port. The bridge now does the exchange itself: `stty raw -echo`, `exec 3<>port`, `AT+CMGF=0`, a 1 s sleep, `AT+CMGS=<len>`, a 2 s sleep, then the PDU and `\032`. Answers are read for up to 25 s. The `>` arrives without a newline, so `read` cannot catch it, and fixed pauses are used instead (busybox has no fractional sleep). Success is a `+CMGS:` line.
- Long text is sent part by part (one `AT+CMGS` per part). Any failed part stops the send: an honest error is better than half a message at the recipient.
- On failure the bridge writes ESC (0x1B) to the port. If the modem already showed `>`, it is waiting for a body, and the next metrics command would go out as SMS text. ESC cancels input, as 27.005 specifies. It then logs `AT+CEER`.
- On a port owned by ModemManager the bridge refuses at once (return 3). MM keeps the port open and swallows both `>` and `+CMGS:`. On the Compal RXM-G1 neither gcom nor a direct exchange got an answer, although single `sms_tool` commands pass (they sometimes win the read race). This used to look like a two-minute page hang.
- `SMS_PDU_CMD=CMGW` swaps the verb to write-to-memory, which tests the encoder without actually sending (and without cost).

### Success line

Only the code that actually sent the message prints the success line. `sms_tool` and `sms_tool_mm` print `sms sent sucessfully: N`, with `sms_tool`'s typo, while our PDU path is silent. The `send` branch prints its own line only when no `*sucessfully*` line came back. Otherwise the page showed two lines. `sms_tool_mm` keeps the typo on purpose, because callers match it.

### Outgoing queue

- The AT port is shared by metric polling, inbox reads, SMS and USSD. If the user pressed Send while the modem was receiving a two-part message, the `>` prompt came late: the user saw `sms sending failed` and the message was lost. Failed or blocked sends now go to `/etc/5gmodem/smsq/<time>.<pid>.sms`, and `queue-run` (from `sessionwatch`) sends one message per round, because the port is also needed for metrics.
- The queue lives on flash, not in `/tmp`: an unsent message must survive a reboot. Entries are few and tiny, so flash wear does not matter.
- File format: `to=`, `port=`, `tries=`, `born=`, a `text:` line, then the body with no trailing newline. The read loop needs `|| [ -n "$line" ]`, because `read` does not return a final line without a newline. Without it the body was read as empty, the entry was treated as corrupt, and the message was deleted silently (caught on the first queue run).
- Limits: 10 tries or 24 h, after which the entry is dropped with a log line.
- `send_inhibit_mm=1` (off by default) is a last resort, used in the background queue only. It runs `mmcli --inhibit-device`, waits up to 15 s for MM to release the modem, sends through our PDU, then releases it. On a Compal RXM-G1 in MBIM with weak signal (RSRP -114, SINR -5), sending through MM randomly worked, failed with `Couldn't send SMS part: Failure`, or hung. With MM inhibited, the same message went out by PDU in 4 s. The cost is high: MM picks the modem up again slowly, and the interface was down for about a minute on the test stand.

## sms_tool_mm (ModemManager wrapper)

- This is an `sms_tool`-compatible wrapper over `mmcli` for MBIM/QMI modems under ModemManager, for example the Compal RXM-G1 ("Tri Cascade Inc. VOS_5G", 05c6:90d6). MM captures incoming SMS, so the AT storages (`+CMGL`) stay empty, and sending over AT is unreliable on those firmwares. It supports `recv`/`status`/`send`/`delete` and the flags `-s/-d/-f/-j`; port and storage are ignored.
- Modem index: `mmcli -m any` fails silently when MM has two modems. With a pair of T99W175 (2026-07-30), "any" hit the modem without a SIM: the list was empty and sends went nowhere, with no error anywhere. The index now comes from `modemswitch.sh mmindex [MM_MODEM_PATH]`, and `any` is only the fallback. When the bridge purges or deletes, it passes `MM_MODEM_PATH`, because otherwise the delete would go to the active modem.
- Stale partial messages: over MBIM, MM sometimes fails to assemble a multipart SMS (operator messages with an alphanumeric sender). The object stays in `receiving` forever and blocks reception of every later message, which are then lost. Deleting the stub unblocks reception (verified on hardware). A healthy multipart assembles in seconds, so anything stuck in `receiving` for more than `STALE_RX_SECS` (120 s) is deleted. The age is measured from when we first saw it stuck (uptime marks in `/tmp/5gmodem/smsrx/<mm index>`), not from the message timestamp. Messages handed over from storage after a reboot carry the sender's hours-old or days-old time and were deleted the moment they passed through `receiving`.
- `mmcli` uses `key='value'` syntax, which breaks on a single quote in the text, so the wrapper replaces `'` with U+2019.
- After sending, the MM object is deleted (sms_tool keeps no sent messages). On failure it is deleted too, so drafts do not pile up.
- `mmcli -s` answers are cached per MM pid in `/tmp/5gmodem/mmsms/` for messages already in state `received`.

## Router-side archive

### Why

- **ModemManager path**: on a Compal RXM-G1 in MBIM, incoming messages exist only in MM's RAM. With an unread message present, all three AT storages report `used: 0`, and after MM recreates the modem object it logs `couldn't load SMS parts from storage 'mt': No SMS PDUs read`. MM recreates the object routinely: our own recovery in `mm-inhibit.sh` (unbind/bind), our send-time inhibit, a USB flap, an MM restart, a reboot. On 2026-08-02 a message survived ten idle minutes and vanished exactly at an unbind/bind, together with the change from Modem/3 to Modem/4. So for the MM path the archive is always on.
- **AT modems**: modem memory is tiny, and some modems have none. The FM350 answers `AT+CPMS=?` with `("SM"),("SM"),("SM")`, which means SIM only, with ten slots. After ten messages the operator stops delivering until someone empties the inbox. For these modems the archive is opt-in (`sms.archive=1`). Without it the page shows exactly what the modem holds, including deletions made elsewhere (a phone, another tool). Turning it on changes the source of truth, so the user has to agree to that.

### Format

- Directory `/etc/5gmodem/sms_arch.<path>/`, one file per message named `<n>.<key16>`. The key (`md5(sender|time|text)`, 16 hex characters) deduplicates, and the number is a stable index for deleting. Archive numbers start at `ARCH_BASE` = 100000, so they never collide with modem indices: the number alone tells whether a delete is for the modem or only for the archive.
- File contents: optional `#tz=` and `#p=<part>/<total>/<ref>` header lines, then the time, the sender, and the text as is. With one file per message there is no escaping and no parsing, even with newlines and quotes in the text. Single-part messages without a tz have no header, which is exactly the original format. The time line never starts with `#p=`, so old files still read correctly.
- Limit: `archive_limit`, 10..2000, default 200. When the archive merely duplicated MM memory, the limit was a fixed 200. With the purge, the archive is the only place messages live, so the user decides how many to keep.

### Merge rules (_arch_merge)

- The live list is merged into the archive on every read, and the archive is returned. A cache keyed by a signature of the live JSON and the directory listing (`/tmp/5gmodem/archmerge_*`) skips repeated merges.
- Unparsed PDUs are never archived. On a broken PDU `sms_tool` returns an entry with an `error` field and empty sender and text (reproduced: a SUBMIT PDU landed in modem memory and `recv` returned "error decoding pdu"). Archiving it would clutter the inbox. More importantly, such a message must never be purged from the modem, because another tool may still be able to read it.
- The merge counts occurrences, not mere presence. Time has minute precision, so the same text from the same sender in the same minute produces the same key. Without counting, the second message would disappear.
- A live modem index is handed to one archive entry only (`_arch_index`). The other duplicates get archive numbers.
- Deleting by live index removes exactly one archive file with that key, not every duplicate.
- The archive used to store the sender as `beeline\r`, `recv` returned it the same way, and the seen key built via `_nd_jesc` had the CR stripped. The keys never matched, so the notifier rediscovered the same three SMS every round (FM350, 2026-09-13). `_arch_read` now strips CR.
- The multipart fields `part`/`total`/`reference` are returned only when present. A `total: 1` out of nowhere would push the page and the bot into merging for no reason.

### Slot purge (archive-run)

`archive-run` is its own verb, called by `sessionwatch` after the notifier and the commands. A message must never be deleted from the modem just because someone opened a page. A message may be deleted from the modem only once:

1. it is in the archive, because otherwise a failed write would mean loss;
2. every enabled forwarding channel (tg/ntfy/hook) has confirmed delivery, since a channel marks a key only after confirmed delivery and the router's network may be down;
3. SMS commands have processed it, if they are enabled (`sms_cmd_done_file`, same key as `smscmd.sh`).

Conditions 2 and 3 used to be strict, and on real routers that recreated the very problem the purge exists for. With the notifier on and Telegram unreachable (common in Russia without a VPN on the router), the bot never confirmed anything, so no message was ever deleted and the modem filled up anyway. Now, after `ARCH_GRACE_MIN` (60 min) since the archive file's mtime, the message is deleted regardless. The guarantee holds, because with the archive on the archive is the source of truth, and the bot and the commands read through the bridge.

- `archive_purge=0` turns the purge off.
- On the MM path the purge is needed too. MM reads messages from the physical storage (usually the SIM) and never removes them, so the card fills up exactly as without MM. Since the archive was never offered to the user there, slots are freed only with an explicit `archive=1`. Otherwise the verb returns `{"result":"mm"}`.
- Messages that cannot be removed ("stuck") are logged at most once an hour, with a pointer to `smsbridge.sh archive-why`. That verb changes nothing: it prints the purge settings and the reason for every message still in the modem.
- Delete-all: some modems hang on `delete all` (L850/XMM), so after it the bridge deletes index by index, each call with its own timeout.

## Bulk delete (delete-start)

`delete-start` validates the comma list, refuses to start while another job runs (`busy`), starts `delete-run` detached, and writes progress JSON (`pid`, `state`, `total`, `done`, `ok[]`, `fail[{index,why,arg}]`). It sleeps 1 s before exiting, because rpcd loses a fast exit when a background child is left behind. `delete-run` deletes archive-only indices directly and tries the lock up to three times. It stops sending to the modem after three unanswered deletes in a row, then re-reads the list and judges each index by whether it is still present with the same timestamp, because some modems answer nothing yet do delete.

## Settings page notes (smssettings.js)

### Settings: keep hidden

Many fields are hidden while their parent switch is off. LuCI deletes options whose dependencies are not met, so values the user entered (mail credentials, token, whitelist) disappeared silently on every temporary toggle. Those options override `remove()` with a no-op, so the value stays until the user changes it. The security code (`cmd_secret`) is the deliberate exception: see [notifications.md](notifications.md#security-code).

### Other notes

- The package manager is detected with `fs.stat` on the binary rather than by trying to run each one. On apk firmwares, the failed attempts logged two `POST /cgi-bin/cgi-exec 404` lines per page view. A sent XHR cannot be suppressed from JS, and `fs.stat` leaves no console trace.
- The storage choice writes `storage_touched` only when the value changed (LuCI calls `write()` only on a diff).
- Background writes from the Inbox page (`sms_persist`: count, port) used to log `RPC call to uci/apply failed with ubus code 5` (NO_DATA). `uci.save()` is asynchronous, so `uci.apply()` ran before the changes reached staging, and an apply with nothing changed also answers NO_DATA. Only changed keys are written now, and apply runs only if something was written. Settings written from page buttons go straight to the config, because `uci.save` left a "unsaved changes" banner.

## Inbox page notes (readsms.js)

- A single list-state model, `smsSetState` (`loading`/`list`/`empty`/`error`), is the only code that touches `#smsList`. Four independent places used to decide the list state and raced each other, which caused "messages appeared and then vanished". `error` keeps the list already shown, since a stale list is better than an empty screen. On an empty screen it draws its own error text: a read failure once looked exactly like "no messages" while the counter showed 3/3 (2026-08-10). The placeholder carries `data-state` because both states share the class `sms-empty`, and without it the spinner was never replaced by "no messages".
- The list is cleared only after a successful parse. A truncated answer (port busy with metrics and dialing, which happens regularly on the FM350) used to throw in `JSON.parse` after the list had already been cleared.
- Selection is kept across redraws, because the list is rebuilt on every poll tick and selected cards lost their state under the user's hands. Indices that disappear are dropped from the selection, so they do not revive on other cards. Cards are `<button>`s with no checkboxes, since an `<input>` inside a `<button>` is invalid. Indices of a merged card are kept in `data-index`, joined with `-`.
- The first read waits for the list element to exist, polling for about 5 s. The read lives in `uci.load().then()` and races `render()`. `setTimeout(0)` did not fix this, because it only deferred from the resolve of `uci.load`. Before the fix, messages appeared only on the first auto-refresh tick, 15 s later.
- The last shown list is kept in `localStorage` (keyed by storage and port) for an instant warm render.
- Radios may not be in the DOM yet when the settings promise resolves (it runs as a microtask). Accessing `.checked` on null aborted the whole status/recv chain, so it is guarded.
- The SMS LED is reset only if `smsled` is configured. Otherwise the write went to `/sys/class/leds/undefined/brightness` as an unhandled rejection (audit 2026-09-12).
- The port-missing popup shows once per page, because it used to multiply on every poll. The early exit on a missing port no longer shares the popup's one-shot flag: that flag was set before the first call, so the check never fired and the bridge was called with an empty port (audit 2026-09-12). HiLink modems need no port.
- Links: http(s) URLs, `www.*`, and bare domains such as `t.tb.ru/appand` and `unblock.t2.ru`, which operators send without a scheme. A domain needs an alphabetic TLD of 2-24 Latin letters, so `т.д.`, `1.5`, IP addresses and e-mail addresses do not match. Trailing punctuation is excluded. A link inside a card stops propagation and opens itself, because browsers need not handle `<a>` inside `<button>`.
- Phone formatting (`+7 (962) 699-90-32`) applies only to Russian-looking numbers (11 digits starting with 7/8, or 10 digits). Alphanumeric senders, short codes, foreign and masked numbers stay as they are.

### XSS: text nodes

With a string as the third argument, LuCI's `E(tag, props, 'string')` sets `innerHTML`. The sender name comes from the operator (alphanumeric, up to 11 characters), so markup in it would run inside the router admin page. Sender and text are always passed as array children, which `dom.append` turns into text nodes (audit 2026-09-12).

## smspdu.sh (UCS2 SMS-SUBMIT encoder)

- `smspdu.sh needucs2 <text>` returns 0 if any byte is >= 0x80. The few ASCII characters outside GSM-7 are left to the modem.
- `smspdu.sh encode <number> <text>` prints `<TPDU length> <PDU>`, one line per part. It does not touch the port.
- It uses awk because the router has no iconv, python or perl, and this busybox build has no `od`. awk under `LC_ALL=C` reads a string as bytes, and a byte-to-number table is built with `sprintf("%c")`. UTF-8 is decoded to UTF-16BE by hand.
- The number is nibble-swapped as 3GPP 23.040 requires. TOA is 0x91 (international) or 0x81 (national), using the same rules as `_norm_num`. A number like `79626999032` declared national is rejected with `+CMS ERROR`.
- Parts: up to 70 UCS2 units fit a single message. With the 6-octet concatenation UDH, 134 of the 140 octets are left, which is 67 units per part. A surrogate pair (emoji) is never split across parts.
- The concatenation reference is uptime seconds mod 256, since the router clock may not be set.
- First octet: 0x11 (SUBMIT, relative VP) for a single part, 0x51 (adds UDHI) for multipart. PID 00, DCS 08, VP 0xAA. The length given to `AT+CMGS` counts octets without the leading SCA byte (`00`).
