# GPS services: clock, Traccar, NMEA over TCP

`gpsfeed.sh` passes the position from the modem GNSS receiver (`gps.sh status`, see
[gps.md](gps.md)) on to three optional services. Each is off by default. The options live in
the main section (`5gmodem.@5gmodem[0]`) and appear in the "GPS" section of Settings, below the
tab and map options. They are shown only with `show_gps=1`.

`gpsfeed.sh tick` runs from the sessionwatch loop right after `telemetry.sh tick`, about every
30 s. With every service off it reads the config once (`uci show`) and exits: no `gps.sh` call,
no modem access. With `netonly=1` or `show_gps=0` all three are off. When several services are
on, one tick calls `gps.sh status` at most once.

| Option | Default | Meaning |
|---|---|---|
| `gps_time` | `0` | set the clock from GNSS when there is no NTP sync |
| `gps_traccar_url` | empty (off) | Traccar OsmAnd endpoint, `http(s)://host[:port][/path]` |
| `gps_traccar_id` | empty | device identifier on the Traccar server |
| `gps_traccar_interval` | `60` | seconds between positions, at least 30 |
| `gps_nmea_port` | empty (off) | TCP port for the NMEA stream |
| `gps_nmea_bind` | LAN address | listen address, IPv4 only; not in the UI |

## Clock from GNSS

A router with no internet after a boot keeps the time `sysfixtime` restored (the newest file in
`/etc`), so logs, SMS times and certificate checks are wrong. A receiver with a fix knows UTC.

**NTP state.** OpenWrt's `sysntpd` starts busybox `ntpd` with `-S /usr/sbin/ntpd-hotplug` when
that script exists. ntpd runs it on `step`, `stratum`, `periodic` and `unsync` with `stratum`
in the environment (16 means not synced); the script forwards the event through
`ubus call hotplug.ntp`, and procd runs `/etc/hotplug.d/ntp/*`. OpenWrt's own
`25-dnsmasqsec` uses the same event to decide that the time is valid. The package adds
`/etc/hotplug.d/ntp/30-5gmodem-ntp`, which writes `ACTION stratum uptime` to
`/tmp/5gmodem/ntp_state`. The clock counts as synced when the last event is not `unsync` and the
stratum is below 16. No record (no event since the boot, ntpd off, or another NTP client such as
chrony) counts as not synced.

**Rules.**
- NTP synced: the clock is never touched, and `gps.sh` is not called for it.
- Needs a fix (`fix` > 0) and a `utc` field. The status may come from `gps.sh`'s 3 s cache, so
  the difference between `ts` and the current clock is added.
- GNSS time before 2024 or from 2100 on is ignored. That catches a receiver after a GPS week
  rollover, which reports a date 1024 weeks (19.6 years) back.
- The clock is never moved more than a year back.
- Until the first set the receiver is asked on every tick; the first step needs a difference of
  5 s or more. After that it is checked every 10 minutes and stepped only when it is off by more
  than 60 s, so it does not fight a slow drift correction.
- The step is `date -u -s "YYYY-MM-DD hh:mm:ss"` and a `logger -t 5gmodem` line. The RTC is not
  written (`hwclock`): most routers have none.

## Traccar (OsmAnd protocol)

Traccar's OsmAnd port (5055 by default in the Traccar config) takes a position as an HTTP
request with query or form parameters. Source: <https://www.traccar.org/osmand/> and
`OsmAndProtocolDecoder.java` in the Traccar server repository (`decodeQuery`):

| Parameter | Value sent | Decoder |
|---|---|---|
| `id` | `gps_traccar_id` | `id` or `deviceid`; an unknown device gets HTTP 400 |
| `lat`, `lon` | degrees from `gps.sh` | parsed as double |
| `timestamp` | seconds since 1970 from the GNSS `utc` (the router clock when there is none) | a number below 2^31 is seconds, otherwise ms; ISO 8601 and `yyyy-MM-dd HH:mm:ss` also accepted |
| `altitude` | metres | double |
| `speed` | knots (`gps.sh` gives km/h, divided by 1.852) | `convertSpeed(value, "kn")` |
| `bearing` | degrees | `bearing` or `heading` |
| `hdop` | as reported | stored as `hdop` |
| `sat` | satellites used | no dedicated case: kept as a custom attribute `sat` |

The request is a GET to `<url>/?<query>` (or `<url>?<query>` when the URL has a path), with
`curl --connect-timeout 5 -m 8`, or `wget -T 8` (uclient-fetch) when curl is missing. Success is
HTTP 200, usually with an empty body. Nothing is sent without a fix, and positions are not queued
while the server is unreachable. A failure is logged once, and so is the recovery. The URL must
be `http://` or `https://` with a host name, IPv4 or `[IPv6]` address, an optional port and a
plain path, no query; the id allows `A-Z a-z 0-9 . _ -` up to 64 characters. Invalid settings
send nothing and log once.

**Privacy.** The position leaves the router on every interval. Everyone with access to that
server sees where the router is and has been. The UI says so next to the option.

## NMEA over TCP

`gps_nmea_port` (10110 is the registered `nmea-0183` port) serves `$GPGGA` and `$GPRMC` once a
second to every client, for gpsd (`gpsd tcp://<router>:10110`), navigation apps and car head
units that read a network GPS.

- **Server.** busybox `nc` on OpenWrt is built without listen mode, so the server needs `socat`
  (preferred: `TCP-LISTEN:<port>,bind=<addr>,reuseaddr,fork,max-children=4`) or `ncat`
  (`-l -k --max-conns 4 --sh-exec`). Each connection runs `gpsfeed.sh stream`, which calls
  `gps.sh status` every second; `gps.sh` serves answers younger than 3 s from its cache, so
  several clients cost one receiver query per 3 s. Without either tool the service logs
  "install socat (or ncat)" and does not start. Neither is a package dependency.
- **procd.** `/etc/init.d/5gmodem-gpsfeed` starts the instance only when
  `gpsfeed.sh nmea-ready` agrees: a valid port, GPS allowed, a tool installed, a listen address.
  It reloads on a `5gmodem` config change (LuCI Save & Apply) and on `lan` interface events.
  `postinst-bg.sh` enables it like the other services.
- **Watchdog.** The tick checks `/proc/net/tcp` and `/proc/net/tcp6` for a listening socket on
  the port. If none, it runs `restart` at most every 5 minutes (a port set with `uci` alone, a late
  LAN, socat installed later). When the port is cleared it runs `stop` once.
- **Address.** The LAN IPv4 address from `ubus call network.interface.lan status`. There is no
  password, so it never listens on the WAN unless `gps_nmea_bind` says so (`0.0.0.0` for all).
  The LAN zone accepts input by default; no firewall rule is added.
- **Sentences.** `gpsfeed.sh nmea` turns the status JSON on stdin into the two sentences
  (testable without a modem). The talker is `GP`, which older head units expect. Coordinates are
  `ddmm.mmmmm`/`dddmm.mmmmm` with N/S/E/W, minutes rounded to 5 decimals with a carry into the
  degrees; speed in knots; checksum is the XOR of the bytes between `$` and `*`, computed in awk
  without `xor()` (mawk lacks it); lines end in CRLF. Without a fix GGA has quality 0 and RMC
  status `V` with empty position fields, and the time is the router clock. GSA and GSV are not
  sent: gpsd takes 2D/3D from the GGA altitude.

## Not verified on hardware

The NMEA stream through socat with gpsd, the Traccar upload against a live server, and the ntpd
hotplug sequence on a router have not been run end to end; the unit tests in
`tools/issue-regressions/test_gpsfeed.py` cover the generators, the validation and the tick
decisions with stubs.
