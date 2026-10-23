# Speed test and external IP

`speedtest.sh` runs a router-side download/upload test over the active uplink (the default route, i.e. whatever "Internet priority" put first) and publishes live progress to `/tmp/5gmodem/speedtest.json`, which the speed-test card in `netpri.js` polls. `extip.sh` reports the router's public address (with country flag) for the modem card and, optionally, the active uplink card; `extip.js` runs one shared poll for the whole page. Both share the IP-service settings (`extip_*`; old `speedtest_ip_url`/`speedtest_cc_url` keys are read as fallbacks, migration is done by uci-defaults).

## speedtest.sh

Verbs: `start` (returns `{"running":1,...}`), `status` (live/final JSON), `stop`.

Config (`5gmodem.@5gmodem[0]`): `speedtest_url` (URL or `internetometer`, default), `speedtest_up_url` (POST endpoint; empty means the same as `internetometer`, so the page and the test never disagree; any other URL is an explicit choice), `speedtest_secs` (per-phase cap, default 15).

### Running in the background

The test runs in a subshell with all fds redirected on the subshell itself; rpcd/cgi-io wait for EOF on the caller's pipes, and a foreground curl (or a redirect only on the inner command) hits the 30 s timeout as an "XHR error".

- `start` refuses a second test only while a test curl is actually alive (found by the User-Agent marker `5gmodem-speedtest`). Two tests share one cache file and the link, giving two halved results. A stale `running` left by a crashed test must not lock the card (audit 12.09.2026).
- `stop` sets a flag the phase loops check and kills test curls by the UA marker (busybox has no pkill by args; `pgrep -f` on the marker leaves foreign curl processes alone). The test writes "what was measured so far"; if it is already dead, `stop` clears `running`. The custom User-Agent from the external-IP settings is used for geo requests only, never for the transfer, so the marker stays intact.
- curl is required and not a package dependency (libcurl is noticeable on 8 MB flash). Without it the test reports what is missing instead of silently failing; busybox wget has neither a parseable progress meter nor body upload, so it would be a different, less accurate measurement.

### Yandex Internetometer probes

- `https://yandex.ru/internet/api/v0/get-probes` returns CDN nodes chosen for the client, so on RU cellular it is the nearest server. No keys or Referer needed (200 without Referer). The URLs are per-session (mid/sid embedded), so the list is fetched before each test, in the background after `start` has answered.
- The answer is external data used for POSTs, so URLs are extracted with strict patterns (`YA_RE_HOST`, `YA_RE_DOWN`, `YA_RE_UP`): host must end in `.cdn.yandex.net` followed by `/` (so `.cdn.yandex.net.evil.com` fails), path is exactly `probes/50mb?...` or `upload?...`. Fast probes (`timeout=`) are latency probes that abort after ~100 ms and are not used.
- The list is needed if Internetometer is selected for either phase (own download URL plus Yandex upload is valid).
- If the list does not arrive the test switches to the fallback and renames the card (otherwise it said "Internetometer" while measuring something else). The name is recalculated only on fallback; the probe URL contains `yandex.net` and would be labelled "Yandex".
- Fallbacks: download `https://speedtest.selectel.ru/1GB` (answers direct and over cellular; a large file lets a 15 s test ramp up, a small one ended early and under-reported), upload `https://speedtest.rt.ru/backend/empty.php`. Tele2 was removed as fallback: it is completely silent from our routers (curl `000`), and a fallback must work exactly when the primary path failed.

### Download phase

- A loop of downloads until `$SECS` runs out, not one: the 50 MB probe finishes in three seconds on a fast link and the phase would end during TCP ramp-up (as with an earlier 16 MB mirror). `--max-time` is per transfer, so each iteration gets the remaining phase time.
- stderr (progress meter) goes to `PROG`, stdout (`-w` summary, one line per transfer) to `RESF`.
- Live speed is computed from the delta of the "Received" column (4th field) over "Time Spent", not from "Current Speed": that column is a 5-second moving average that shows 0 for two seconds and lags (measured 0, 0, 598.6k, 660.8k, 884.2k, 951.4k at a real ~1 MB/s). If parsing fails it falls back to the old column.
- Transfer boundaries are detected by the number of summary lines in `RESF`, not by counters going down: a new transfer can already exceed the previous sample's byte count. At a boundary only a new reference point is taken; "Time Spent" is rounded to whole seconds, so the first segment of a new transfer has an understated divisor and produced double values (297 vs a plateau of 136) that then became the max.
- Zero is never published mid-phase; a tick without new bytes (always the last one before curl exits) keeps the last value, because the animated card turns a zero into an apparent link drop.
- Headline = max of per-second samples (link capacity), not curl's average, which ramp-up depresses; the best per-transfer average is the fallback. HTTP success counts if any transfer succeeded, so the last transfer cut by the time limit does not void earlier results.
- `elapsed` (seconds since curl start) is published so the UI progress bar follows the backend, not the click time.

### Upload phase

- A loop of buffered POSTs for the whole phase: one 8 MB POST finished in 1-2 s on 5+ MB/s uplinks and the max-of-samples caught only ramp-up ticks. Streaming alternatives do not work: chunked `-T` (PUT and POST) is cut with 403 by rt.ru at ~10 MB, an explicit Content-Length gets 403 immediately, Tele2 FTP is silent from cellular (CGNAT). Gaps between POSTs are absorbed by max sampling; the result is max(samples, best POST average).
- The first POST is 2 MB, then 8 MB: HTTPS upload has no in-transfer progress, so the live value comes from completed POSTs, and with 8 MB on a slow uplink the first number arrived after 4-8 s.

### Public IP and country during the test

- Geo requests run in parallel with the measurement and write to files the sampling loops pick up. Sequential geo requests before the download (6+5+4 s max-time) used to eat up to 15 s on cellular, so the bar moved while the number stayed 0.
- Yandex first (`https://ipv4-internet.yandex.net/api/v0/ip`, returns a JSON string `"1.2.3.4"`; the older `yandex.ru/internet/api/v0/ip` setting is replaced): it answers in a fraction of a second and is always reachable. Foreign services (ip-api, ipify, ifconfig.me, icanhazip, ident.me, cloudflare) all stay silent from RU cellular until timeout (checked on MegaFon with working ping/DNS/ya.ru), and the card showed the modem's CGNAT address (10.78.71.235) as if it were public. Then the configured service (default `http://ip-api.com/line/?fields=countryCode,query`) refines IP and adds the country, then the backup service, then a country lookup by IP (`{ip}` placeholder) for public addresses only.
- Clash fallback: the router's own traffic bypasses the tunnel (tproxy only intercepts LAN forwarding), so geo services may only answer via clash's HTTP/mixed port. The tproxy port is not an HTTP proxy and is never used.
- If no public IP is found, the modem/route source address is shown and flagged as non-public (HiLink: the route source is the internal 192.168.43.x).
- `_parse_ip` validates octets and excludes private/CGNAT/link-local ranges; a bare four-group grep picked garbage from HTML error pages and produced a wrong flag. `_parse_cc` understands a bare two-letter answer (ip-api `/line`) and JSON `countryCode`/`country_code`.
- `_geo` is a function because a User-Agent with spaces would split in `${VAR:+-A $VAR}`.
- A final snapshot of IP/country is taken after the upload because geo may finish after the last tick.

### Result file

- `_num` turns empty into 0: a stopped test leaves curl's result file empty, awk printed nothing and `"down_mbps":,` made invalid JSON; after cancel the card silently lost result and IP. `status` discards a corrupt cache instead of serving it.
- Every final JSON carries `ts`, so the frontend can tell a fresh final from the previous test's cached final by byte comparison.
- Unit helpers: `_tobytes` converts curl meter values (`7.23M`, `949.8k`, binary multipliers, k = 1024) to bytes; `_tombps` to Mbps.

## Speed-test card (netpri.js)

- State is module-level so it survives the 5/15 s redraw of the row; there can be more than one card in the document (`mount()` plus `renderBar()`), so all are updated, not the first `querySelector` hit (audit 12.09.2026).
- The progress bar appears only once real numbers arrive (`hasData`); before that the card pulses its border in the phase colour. Progress = backend `elapsed / secs`, interpolated between polls at 200 ms. Phase change resets the data wait (upload has its own connect and first POST).
- Fixed-width two-number layout in every phase with dimmed `000.0` placeholders, so the card width never changes; arrow glued after the number in an inline-flex with gap 0.
- Live numbers are animated towards the target over ~0.9 s; the counter resets only on phase change, not when the IP arrives mid-phase (the IP is part of the redraw key).
- `start` is not awaited: rpcd busy with other pollers held the start XHR for ~19 s and the card showed "test error" while the result was already cached. Polling starts immediately; the previous final is recognised via the `staleFinal` snapshot. A single empty poll answer is a transport glitch (`exec_direct` via cgi-io), not a failure; the card gives up after four in a row. Poll limit ~70 ticks.
- Second click = stop: the card resets to default on the next tick, whatever final JSON arrives. Known failure reasons (e.g. missing curl) are shown explicitly.
- A test started before leaving the page is picked up by `stInit` on return.
- The non-public IP flag is shown so the operator's CGNAT address is not read as a "white IP".

## extip.sh

Verbs: `get [iface]` (instant: cache plus background refresh when stale), `now [iface]` (blocking refresh), `flush`, `probe <url> [4|6] [ua]` (one-off check from the settings page, bypassing cache and the enable switch).

- Off by default (`extip_enabled`): it queries a third-party service, and nothing is sent until the user picks one. Only the configured service is asked, with no fallbacks; the choice of service is also a choice of who sees the address. The only extra request is the country lookup (`extip_cc_url`, default `http://ip-api.com/line/{ip}?fields=countryCode`) when the service returns a bare IP (ipify, ifconfig.me), and it is visible in the settings.
- Defaults: IPv4 `http://ip-api.com/line/?fields=countryCode,query`, IPv6 `https://api6.ipify.org`, TTL 300 s (minimum 30). IPv6 is queried only if an IPv6 default route exists, otherwise every cycle waits for a timeout.
- Two channels: the default route (what address the router is seen from) and a named interface (`curl --interface`), because the modem card must show the modem's address even when another uplink is primary. If the named interface is the primary one, the shared cache is used with no request. Each channel has its own cache (`_setscope`).
- Cache key (`_rkey`): gateway + device of the default route; for an interface channel its own address plus the primary device. A changed uplink or a redial invalidates the answer before TTL; an interface that became primary moves to the shared cache.
- Fetching via a specific interface needs curl; `uclient-fetch` (present in every OpenWrt build, supports `-4/-6`, `-U`, timeout) has no interface binding, so without curl the interface channel stays empty rather than showing a neighbouring uplink's address.
- `_spawn` detaches fds for the background refresh; a plain `&` kept the XHR open until rpcd's 30 s timeout.
- IPv4 parsing validates octets (same reason as in speedtest.sh).

## extip.js

- One poll per page shared by the modem card and the active-uplink card. Channel `''` = default route, channel `<iface>` = through that interface. The backend serves cache and refreshes itself, so polling is cheap.
- The poll is created on the first `watch()`. `peek` reads a channel's state without creating it; cards ask about interfaces nobody may be watching. Changing the modem on the page stops watching the old interface.
- The flag is shown next to the address because it answers "tunnel or direct" at a glance.
- Unsubscribe is paired: the priority block is re-created inside another page, and each instance added a redraw on detached nodes. With no subscribers and no channels the poll itself is removed (audit 12.09.2026).
