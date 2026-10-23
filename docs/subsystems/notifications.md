# SMS notifications, SMS commands, LED

This doc covers what the router does with incoming SMS on its own, with no page open:

- `root/usr/share/5gmodem/tgnotify.sh` forwards new messages to Telegram, ntfy and a generic webhook. It also runs a small Telegram bot (`/sms`, `/status`, `/modem`, `/help`, plus the configured SMS commands).
- `root/usr/share/5gmodem/smscmd.sh` runs configured commands when a trusted SMS arrives.
- `root/usr/share/5gmodem/sms_led.sh` and `smstool_led.sh` blink an LED when the message count grows, and `smscron.sh` schedules restarts of that notifier.

All of them read messages through `smsbridge.sh` (see [sms.md](sms.md)) and are driven by the `sessionwatch` loop, except the LED loop, which is its own procd service `5gmodem-sms-notify`. Settings live in `5gmodem.sms` and are edited in `htdocs/luci-static/resources/sms-tool-5gm/smssettings.js`.

## Forwarding (tgnotify.sh)

Verbs: `tick` (one forwarding round plus one bot-command round, from `sessionwatch`), `commands`, `test`, `chatid`, `setchat <id>`, `status` and `modems`, which prints the numbering `/modem` would show so it can be checked without touching the live chat.

### What counts as new

New means exactly what the Inbox page highlights: keys from the bridge, compared with a seen list owned by `smsbridge.sh`. Each channel has its own list (`sms_tg.<path>`, `sms_ntfy.<path>`, `sms_hook.<path>`). They are read with `smsbridge.sh unseen tg,ntfy,hook` and written with `list-add`. The script keeps no bookkeeping of its own, so the bot and the page cannot disagree about what the user has already seen.

- A key is written only after confirmed delivery. The router's network may be down, and in Russia `api.telegram.org` is unreachable without a bypass, so an undelivered message waits for the next round.
- First encounter with a modem (no list yet): messages that arrived within the last `tg_first_hours` hours (default 24) are sent, and the rest are marked silently. The SIM may hold a year of messages, but someone who just plugged in a modem expects the bot to work right away. `0` means send nothing (the old behaviour). Freshness is compared in UTC, because `sms_tool` timestamps are UTC regardless of `$TZ`.
- The script keeps its own interval (`tg_interval`, default 60 s), because `sessionwatch` calls it every ~30 s and reading the AT port that often is not needed.

### Walking all modems

Every modem from `registry.sh paths` is read, not just the active one. The port used to be the single `sms.readport`, which describes the modem whose tab is open. On a router with a Compal and a Telit, the Telit's messages never reached the chat until the tab was switched (2026-08-01). Each modem already had its own seen files, so this change produced no duplicates.

- Port: for the active modem, the configured `readport`, which is chosen so it does not compete with the metrics port. For the others, the `at_port` of their section. Empty means HiLink or MM, and the bridge handles it.
- Devices with no SMS channel (no tty, no cdc-wdm, not HiLink; a tethered phone, for example) are skipped before reading. Otherwise the bridge falls back to the global `readport`, and the bot would forward the active modem's inbox a second time under the phone's name. Modems whose owner disabled background AT (`bg_at_off`) are skipped too.
- A modem label is added only when there is more than one modem. `registry.sh paths` prints one path per line. The code used to search for a space and never found one, so the label never appeared even with two modems (audit 2026-09-12).
- A delivery failure on a channel stops that channel for the rest of the round, and once every channel has failed the round ends (if the network is down, the other modems' messages will not get through either). A read failure skips only that modem, so a busy port on one modem does not silence the rest.
- Long SMS are assembled before sending, ordered by part number rather than storage index, because a chat message starting mid-sentence is useless. If parts are still missing, the message waits for up to 3 minutes after its timestamp (`_tk_young`), and after that it is sent with a `[have/total]` suffix.

### Delivery result codes

`_http_rc` maps the HTTP status to an outcome. 2xx means delivered. 408, 425 and 429 mean retry later and end the round. Any other 4xx means the server rejected this particular message: the key is marked, a short "text not accepted, open the Inbox" notice is sent to Telegram, and the round continues, because one malformed message once blocked the queue forever. Everything else means retry. Telegram text goes through `--data-urlencode`, since SMS text may contain newlines, `&` and `%`. The URL with the token is passed to curl as a config file on stdin (`-K -`), so the token never shows up in `ps`.

### Telegram codes

`_tg_codes` wraps one-time codes in `<code>` (tap to copy) when the text mentions a code or password (`код`, `пароль`, `code`, `password`, `pin`, `otp`, `kod`, `验证码`). A code is 4..8 digits or `123 456`. Digits next to letters, decimals, and amounts (`руб`, `р.`, `₽`, `rub`, `usd`, `eur`, `%`) are skipped. The HTML version is sent first. If Telegram rejects it with a 4xx, the plain text is sent.

`utf8_fix` runs again on the bot's own texts (command replies, status), because operator and model names also come from the modem. The function is idempotent.

### Reaching Telegram from Russia

Direct port 443 to Telegram is closed by Russian operators, and the router's own traffic bypasses clash, because tproxy intercepts only traffic forwarded from the LAN (checked live on 2026-08-07: direct curl times out, while curl through the mixed port answers). `_tg_curl` tries, in order:

1. the interface from `tg_iface` (`curl --interface`), if set;
2. the direct path, with an 8 s timeout rather than 20: a working direct path answers within seconds, and on a closed one every extra second is a hanging button and a frozen tick. A failure is remembered in `/tmp/5gmodem/tg_direct_dead` for 10 minutes, so that not every call burns that timeout. The TTL lets a switch to a tunnelled uplink be noticed;
3. the clash HTTP proxy.

Any answer containing `"ok":` counts as a server answer, including an honest token error, which the proxy cannot fix and which therefore is not retried. The same bypass is used by the Telegram probe in `netpri.sh` and by the speedtest geo requests.

`_tg_proxy_port` finds the clash HTTP port in three steps:
1. `mixed-port`/`port` from `/opt/clash/config.yaml` or `/etc/clash/config.yaml` (the legacy ssclash layout);
2. the mihomo runtime: tproxy/tun configs have no HTTP port in the file, but one may have been opened at runtime, so `GET /configs` on the API at `127.0.0.1:9090`, with the `secret` from the config if one is set;
3. if `mixed-port` is 0, `PATCH /configs {"mixed-port":7895}`. This is the standard knob that every dashboard uses. The port listens on 127.0.0.1 only and lasts until clash restarts, and later calls find it at step 2. Verified on mihomo 1.19.29 with a tproxy config that had no HTTP port: 204, the port is listening, and Telegram answers through it with 302.

### Own Bot API server

`sms.tg_api_url` replaces `https://api.telegram.org` in every Bot API call (`sendMessage`, `getUpdates` for the chat lookup and for commands); a trailing `/` is dropped and anything that does not start with `http://` or `https://` is ignored. It is meant for an SNI proxy or a self-hosted Bot API server that forwards the API unchanged. `sms.tg_api_insecure=1` adds `curl -k` to all three paths (interface, direct, clash proxy), only when a custom URL is set. The Telegram ping card probes the custom URL directly (`"via":"custom"`) instead of the api.telegram.org DNS/TLS checks. The two UI fields do not keep their values when hidden, so clearing the URL really clears it.

### Chat ID and setchat

Telegram never shows the chat id, neither when the bot is created nor in the UI. Only `getUpdates` returns it, and only after the user has written to the bot, since a bot cannot start a conversation. `chatid` returns every chat found, with names, because a user may have a private chat and a channel. Channels and groups have negative ids, which is expected. The answer is parsed with awk rather than jsonfilter, because the nesting differs between `message`, `channel_post` and `my_chat_member`. An empty answer means neither the direct path nor the proxy answered. That is the network, not the token, and the page shows `noreply` with an explanation (without a working SSClash or VPN uplink the router cannot reach Telegram). Telegram returns names as `\uXXXX`, and the page decodes them.

`setchat` writes the found id to the config immediately and validates it, because the value comes from the browser and goes into the config. A value merely filled into the form field lived only until the first Save, and after pressing Find the config stayed empty.

`ntfy_*`, `hook_*` and the token keep their values while their switch is off (see [sms.md](sms.md#settings-keep-hidden)).

### Status text

`/status` follows the same rules as the modem card. Empty fields (`-` in the snapshot) are omitted. Temperature: degrees if the modem reports them, plus the throttling level 1..3 as a word (level 0 is omitted, since "32 °C, normal" is noise). If there are no degrees, only the level word is shown, matching the card. `&deg;` is turned into a real degree sign.

## Telegram bot commands

Bot commands are enabled separately with `tg_commands=1`.

- Only the chat configured in `tg_chat` may give commands. Anyone who learns the bot's name can write to it, and a command costs money and speaks for the SIM owner. Other chats get silence, because telling a stranger "you are not the owner" confirms that the bot is live.
- Commands: `/sms <number> <text>` (the number in any form, normalized by `smsbridge.sh`), `/status [<n>|all]`, `/modem [<n>]` (list modems or switch the active one), `/help`. Modem numbers follow registry order, which is stable because section keys are USB paths. They are never stored, since showing the user a USB path like `2-1.4` in a command is unfriendly. Switching the active modem is no longer needed for incoming SMS, because the bot reads all modems. It still controls the web tab, the `/sms` target and the default `/status`.
- Words from the "SMS commands" list also work from the chat (`smscmd.sh chat`). The bot used to know only its own commands and silently ignored a `reboot` configured on the commands page, so `/status` answered and the user assumed the bot was fine (complaint of 2026-09-04). Words that are not commands get no reply, because the chat is also an ordinary conversation.
- No replays. The `getUpdates` offset (last update id + 1) is stored on flash (`/etc/5gmodem/tg_offset`), and it is written and `sync`ed for each update before that update's command runs, so a reboot in the middle of a round cannot send the same SMS twice. There is also a local guard (updates with an id below the stored offset are dropped): network glitches, another poller using the same token, or our own `getUpdates` from the Find Chat ID button can return old updates, and a repeated command costs money.
- On first enable an introduction is posted in the chat. Documentation that arrives where the user works beats ten lines of help on a web page. The marker `/etc/5gmodem/tg_announced` is on flash, so this happens once ever, not after every reboot.
- The reply to `/sms` names the model and operator that sent it, because with two modems that is the first question.
- The Send page shows only a status line about the bot. Bot, token and chat are configured once, in the Inbox settings.

## SMS commands (smscmd.sh)

Verbs: `run` (one round, from `sessionwatch`), `chat <text>` (from the bot), `list` (keywords for `/help`), `test <keyword> [args]` (run from the page as if the SMS had arrived).

SMS is the last working management channel when the router cannot be reached over IP: the uplink is down, the address changed, or the tunnel did not come up.

### Safety

A command comes from outside, from anyone who knows the SIM number:
- Off by default (`cmd_enabled`).
- The whitelist (`cmd_whitelist_only`) is on by default, and an empty whitelist with the whitelist enabled executes nothing. Opening it to everyone requires unchecking the box by hand.
- Numbers are compared by their last ten digits (`+7XXX`, `8XXX` and `7XXX` are the same person). An alphanumeric sender (`t2.ru`) never matches, and is never answered.
- The message text never enters the command line. The tail after the keyword goes into the environment variable `SMS_ARGS` (along with `SMS_FROM` and `SMS_TEXT`). Otherwise `reboot; rm -rf /` from a stranger would be one SMS away. The command itself also passes `cmd_allowed` (lib.sh).
- Keywords match case-insensitively, because people type them on a phone.

### Security code

`cmd_secret` is an optional first word that must come before the command word (`secret reboot`). Sender numbers can be spoofed (SMS spoofing is a commercial service), so a whitelist alone is not enough for someone who really runs the router over SMS. The keyword itself cannot be the secret: it is written in the settings and obvious at a glance. By default there is no code. The `cmd_secret` field deliberately does not override `remove()`, unlike the other hidden fields on the page. LuCI calls `remove()`, not `write()`, for an empty field, so the no-op stub made it impossible to clear the code: the old value came back after every save (complaint of 2026-09-04). The chat path asks for the secret too, so one rule applies to both channels.

### Exactly once

- The done list (`sms_cmd_done_file`, lib.sh) is on flash and keyed by the SIM's ICCID, so a reboot does not run the same commands again. The first encounter with a SIM executes nothing: the memory may hold messages a year old. They are all marked done and logged.
- `cmd_max_age` (hours, default 24, 0 = unlimited). Previously unseen messages also show up on a known modem as soon as the SIM is swapped, because the card brings months of its own messages. On 2026-09-02, after switching from eSIM to a physical SIM, the modem returned 50 messages, the oldest from January. A six-month-old "reboot" is not a command anymore. An unparseable timestamp counts as old. The comparison is in UTC.
- `cmd_cooldown` (seconds, default 300) per keyword, stored on flash (`sms_cmd_cool_file`). Operators deliver duplicates, and people send `reboot` three times without waiting. Each copy has its own timestamp and its own key. The first copy got marked and rebooted the router, the others were never marked, and after boot the next copy rebooted it again, one copy per reboot. The cooldown file has to survive reboots, which is why it is not in `/tmp`. Keys are an md5 of the lower-cased keyword, because the file is split on spaces. A timestamp from the future (a router without an RTC that got NTP time late) does not lock the command forever.

### Mark before execute

The done keys for a message are written and `sync`ed before the command runs, not after. The mark used to be written after `_run_cmd`, and a `reboot` without delay took the router down before the key reached flash. After boot the message was still unprocessed in the modem, the round found it again and rebooted again: a reboot loop that looked like "reboot via SMS doesn't work". The cost of the new order is a command that does not run if the process dies between the mark and the run, which is much better than an endless reboot loop. `sync` matters too: on a power loss during the reboot, an unsynced write disappears with the cache.

- A message is marked even when it holds no command. Otherwise every round would re-scan the whole modem memory, and the slot purge could never delete an ordinary message (its condition "commands processed" would never be met).
- Multipart messages are grouped by `sender|time` into one text. Otherwise a command that does not fit one part would never match, and the parts would stay unprocessed forever, so the purge could never remove them. All part keys are written, and the first part's key goes last: its presence means the group was finished.
- The done list is trimmed to 300 plus `archive_limit` lines.

### Execution

- `delay` (capped at 300 s): the reply is sent first and the command runs in the background after the delay, because a command like `reboot` would kill the script before the reply goes out, and the user would never know it arrived.
- Without delay, the command's output is appended to the reply and capped at `ANS_MAX` (600 bytes), since long SMS cost money.
- Replies go through `smsbridge.sh send`, which picks the transport (our PDU for Cyrillic, `sms_tool` for Latin, MM for MM-owned modems) and queues the reply if the port is busy.
- Modems without an SMS channel and modems with `bg_at_off` are skipped, with the same guard as the bot. A tethered phone would otherwise fall back to the active modem, and commands would run twice.

## LED notifier (sms_led.sh, smstool_led.sh)

This code is inherited from the upstream sms-tool LuCI app. The procd service `5gmodem-sms-notify` runs `sms_led.sh`, which loops every `checktime` minutes (default 10) while `lednotify=1` and runs `smstool_led.sh`. That script reads `used:` from `smsbridge.sh status` and, if the count grew past the saved `sms_count`, puts the LED `smsled` into `timer` mode (1 s on, 5 s off). It honours `bg_at_off`, and uses the full CPMS form like the bridge ([sms.md](sms.md#storage-cpms)).

## Restart schedule (smscron.sh)

The notifier process eventually stops noticing new messages, because it survives modem reconnects poorly, and a restart fixes it. The user picks a period (1..24 h), and `smscron.sh on <hours> | off | status` maintains a single crontab line tagged `5gmodem-sms-notify`.

The script exists to narrow permissions. The page used to read `/etc/crontabs/root`, filter it, and write it back, which required a `write` ACL on the crontab, that is, the ability to schedule any root command from the browser. The filtering lived in the page and could not be enforced there. The script touches only its own line (never other users' lines, which may contain anything), validates the interval (`*/0` is invalid for cron, `*/999` is meaningless), restarts cron and the notifier itself, and `status` returns only our line, never the rest of the crontab. This follows the same "narrow verb instead of a general executor" model as `setopt.sh` and `atcmd.sh`.
