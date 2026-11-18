# GPS: modem GNSS receiver and map

The "GPS" tab (`view/modem5g/gps.js`) shows the position from the GNSS receiver built into the
modem (or from a USB GNSS receiver, see below), turns the receiver on and off, restarts the search (cold, warm or hot start), and draws
the position and the track on a map. The backend is `gps.sh`. Nothing runs in the background:
the page asks `gps.sh status` every 5 s while it is open and visible. The only other caller is
telemetry, and only with `tele.publish_gps=1`.

## Source order

`gps.sh status` takes the first source that applies (`source` in the answer):

1. `ugps`: the ugps service answers on ubus;
2. `usbgps`: a tty named in `5gmodem.@5gmodem[0].gps_port`;
3. `mm`: ModemManager manages the modem and offers `gps-nmea` or `gps-raw`;
4. `qmi`, `at` or `nmea`: the modem's own commands, per family;
5. `usbgps`: a u-blox receiver found on USB, when the modem has none of the above.

`gps.sh caps` reports the same value as `source` (without ugps). A HiLink stick
(`5gmodem.m_<path>.kind=hilink`) is skipped entirely: no probe, no AT, no MM call.

## Commands per family

The family comes from the USB vendor id (`_family_hint`). Dell ids are split: `413c:81d7`,
`81d8`, `81d9`, `81e0`, `81e4` and `81e6` are Foxconn builds, the other Dell ids are Sierra builds.
The first `caps` call sends a read-only probe to the AT port (Quectel and Huawei add one more
read-only query, see below) and caches the answer in
`/tmp/5gmodem/gnss_caps_<modem>`. A busy or silent port is not cached.

| Family | Probe / state | On / off | Start mode | Position |
|---|---|---|---|---|
| Quectel (`2c7c`) | `AT+QGPS?` → `+QGPS: 0/1` | `AT+QGPS=1` / `AT+QGPSEND` | `AT+QGPSDEL=0/2/1` (cold/warm/hot) with the receiver off, then `AT+QGPS=1` | `AT+QGPSLOC=2`: `utc,lat,lon,hdop,alt,fix,cog,spkm,spkn,date,nsat`, degrees with sign; `+CME ERROR: 516` = no fix yet |
| SIMCom (`1e0e`) | `AT+CGPS?` → `+CGPS: 0/1,mode` | `AT+CGPS=1,1` / `AT+CGPS=0` | `AT+CGPSCOLD` / `AT+CGPSHOT`; both need the receiver stopped and start it themselves. There is no warm start | `AT+CGPSINFO`: `ddmm.mmmmmm,N,dddmm.mmmmmm,E,ddmmyy,hhmmss.s,alt,speed(knots),course` |
| Telit (`1bc7`) | `AT$GPSP?` → `$GPSP: 0/1` | `AT$GPSP=1/0` | `AT$GPSR=1/2/3` (cold/warm/hot) with the receiver off, then `AT$GPSP=1` | `AT$GPSACP`: same fields as Quectel, coordinates as `ddmm.mmmmN` |
| MeiG (`2dee`) | `AT+GPSSTATE?` | `AT+GPSRUN` / `AT+GPSSTOP` | — | `AT+GPSLOC`: `utc,lat,N/S,lon,E/W,hdop,alt,fix,cog,speed,date,nsat` (speed is not shown: the manual gives no unit) |
| Fibocom (`0e8d` FM350, `2cb7`; QMI LOC first on `2cb7`) | `AT+GTGPSPOWER?` (FM350: on the GNSS AT port, see below) | `AT+GTGPSPOWER=1/0`, FM350 first `AT+ELCSGNSSENABLE=1` when refused | `AT+GTGPSDELAID=0/1/2` (cold/warm/hot) with the receiver off, then power on | NMEA port; FM350: `+ELCSNMEA` lines on the AT port |
| Foxconn / Dell (`0489`, `1e2d`, `105b`, Qualcomm generic `05c6:90d5/90d6/9025`, Dell ids above) | `AT+GPS?` → `GPS is Enable/Disable` (MV32 firmware: `1/0`) | `AT+GPS=1/0`, see below | — | NMEA port |
| Sierra (`1199`, `0f3d`, other Dell ids) | `AT!GPSSTATUS?` (anything but `ERROR`) | `$GPS_START` / `$GPS_STOP` written to the NMEA port | — | NMEA port |
| Huawei (`12d1`: ME909/ME906 family) | probe `AT^WPDOM?` (support only if it answers `^WPDOM:`); state `AT^WPINFO?` → `^WPINFO: <mask>`, 0 = off | `AT^WPDST=1`, `AT^WPDFR=65535,1`, `AT^WPDGP` / `AT^WPEND` | — | NMEA port |

`AT+GTGPSSWITCH=0` on Fibocom forbids every GNSS command except itself. The receiver is then
reported as `locked`, and "Turn GNSS on" sends `AT+GTGPSSWITCH=1` first.

**Quectel NMEA outport.** The position is read with `AT+QGPSLOC=2`, but other readers (ugps, gpsd)
need NMEA on the USB NMEA port. `caps` asks `AT+QGPSCFG="outport"` (`+QGPSCFG: "outport","<port>"`,
values `none`, `usbnmea`, `uartdebug`) and reports it as `outport` in `caps` and `status`. When it
is `none`, "Turn GNSS on" first sends `AT+QGPSCFG="outport","usbnmea"`. The module stores this
setting in NVRAM, so any other value is left alone.

**Huawei.** `AT^WPDGP` starts a session with the stored parameters; `AT^WPDST=1` (tracking) and
`AT^WPDFR=65535,1` (fixes every second) are sent first, as ModemManager's Huawei plugin does with its
own interval. Neither is stored over power-off. A second `AT^WPDGP` while a session runs is an
error, so "on" then checks `AT^WPINFO?`; `AT^WPEND` with no session answers `+CME ERROR: PD session
is in off status`, which counts as off. The NMEA interface (class `ff`, subclass/protocol `01/05`,
`01/14` or `06/14`, from ModemManager's udev rules) is tried first when looking for the NMEA port.
Vendor id `12d1` is shared with HiLink sticks and modems without GNSS: only a `^WPDOM:` answer marks
the modem as supported. `AT^WPINFO?` is described in the ME909u-521 manual; on firmware without it
the state stays unknown. The ME909s manual was not available, so its command set is assumed to
match the ME909u-521.

Sources: FM350 AT manual V2.10 chapter 19, MV32-W AT reference r3 §15.12-15.15, SIM7500/SIM7600
AT manual V1.01 chapter 16, LN920 AT reference r0 (`$GPSP`, `$GPSR`, `$GPSACP`), MeiG SLM770A
manual chapter 15, EC20 GNSS AT manual V1.0, EM74xx AT reference r3 (`!GPSAUTOSTART`, `!GPSLOC`),
the start/stop table of luci-app-gpoint, Quectel EM12/EG12/EG18 GNSS Application Note V1.0 §2.1.1
(`AT+QGPSCFG="outport"`), Huawei ME909u-521 AT Command Interface Specification Issue 02 chapter 14
(`^WPDOM`, `^WPDST`, `^WPDFR`, `^WPDGP`, `^WPEND`, `^WPINFO`), and ModemManager 1.24.0
(`src/plugins/huawei/mm-broadband-modem-huawei.c`, `77-mm-huawei-net-port-types.rules`; `cli/mmcli.c`,
`cli/mmcli-output.c`, `cli/mmcli-modem-location.c`, `libmm-glib/mm-location-gps-raw.c`).

### FM350: GNSS behind the modem's own adapter daemon

Checked on an FM350-GL (`0e8d:7127`, USB mode 41). The module runs
its own OpenWrt; GNSS there is `mnld` with `gnss_adpd` in front of it, and `gnss_adpd` owns the
AP-side AT port (interface 3, `ttyUSB1` here). Everything else it forwards to the modem.

- **Port.** `+GTGPS*` answer only on that port; the modem AT port (interface 6) gives `ERROR`.
  When the app's AT port is not the GNSS one, `caps` asks `AT+GTGPSPOWER?` on the other ttys of the
  modem and keeps the one that answers as `atport` in the caps cache.
- **Feature switch.** The build ships `GNSS_CFG_ENABLE=false` in `/etc/lbs/gnss_adpd.conf` inside
  the module: `AT+GTGPSPOWER=1` is then refused (`gnss feature disabled` in the module log) while
  the read commands work. The MTK command `AT+ELCSGNSSENABLE=1` turns the feature on at run time;
  "Turn GNSS on" sends it after a refused `GTGPSPOWER=1` and tries again. The module's files are
  not changed.
- **NMEA.** There is no NMEA port in this mode: the position comes as `+ELCSNMEA: "$G..."`
  unsolicited lines on the same AT port, followed by `+ELCSSAT` and `+ELCSNMEAEND`. Because the app
  may poll that port, the stream is kept off (`AT+ELCSNMEACFG=0`) and `status` switches it on
  (`AT+ELCSNMEACFG=1`, every sentence type) for a 2 s read under the port lock. `AT+GTCFGNMEA=1`
  is not used: after a power cycle of the receiver it left only `$GNACCURACY` in the stream.
- **What the parser takes from the stream.** A 2 s slice may hold no GGA sentence: the satellites
  in use are then the unique ids over the GSA sentences (one per system) and HDOP is the GSA value.
  With a fix the module also prints `+ELCSLOC: lat,lon,alt,speed,course,...,"date,time",pdop,hdop,vdop`
  (signed degrees); `_fm_urc_read` passes it on as `$PELCSLOC,...` and `gnss_parse_nmea` uses it
  for the position, altitude, HDOP and time only when the sentences gave none. A field report with
  a working antenna shows a 3D fix with 57 satellites in view from the same command sequence.
- **Receiver power drops by itself.** The module now and then switches the receiver off
  (`+GTGPSPOWER: 0`) without a request (a field report). "Turn GNSS on" stores `gps_on=1` for the
  modem ("Turn GNSS off" deletes it; a receiver seen on is stored too), and `status` switches the
  receiver back on when it finds it off while `gps_on=1`: at most once a minute
  (`gnss_fmrevive_<sec>` marker), with a syslog line either way.
- `AT+GTGPSDELAID=0/1/2` (cold/warm/hot) answers `OK`; `AT+GTGPSDELAID=?` gives `ERROR`.
- Undocumented, read-only, seen on this build: `AT+GTGPSCFG?` (`2,<n>` matches `GnssMode` in the
  module's `MNL_Config.xml`, 6 = GPS+GLONASS+Galileo+BeiDou).

### Foxconn: the switch restarts the modem

On T77W968, T99W175 and T99W373 `AT+GPS=1/0` is stored in the modem and applied by a modem
restart. With GNSS off the NMEA and DIAG ports disappear from the USB composition. Field reports
on the 4pda forum: on newer firmware some modems kept rebooting in a loop after `AT+GPS=0` while
they sat in a router, but not on a PC. The page therefore asks for confirmation and warns before
turning it off. `gps.sh` drops the cached caps and NMEA port, because the ports come back
renumbered. T77W968 answers `AT+GPS=1` with `Setting success! Module would reboot...` and can
restart before `OK`, so that line counts as success. `AT+GPS_START`/`AT+GPS_TTFF_START` are not used: they start a measurement session for
the time to first fix, not a normal search. On many T77W968 firmwares only GPS satellites appear
in NMEA even though the datasheet lists GLONASS, Galileo and BeiDou.
A field report names `AT^GPS_START=0/1/2` (query `^GPS_START: 0`) as the cold, warm and hot
start; it is not in the AT reference and is not used until checked on a modem.

## Telit: GNSS antenna connector

Telit cards have a dedicated GNSS connector and can also take GNSS from the AUX (diversity)
connector. `AT$GPSANTPORT` picks one, the value is stored in the modem:

| Value | Meaning |
|---|---|
| 0 | GNSS off on both connectors |
| 1 | AUX connector, passive antenna |
| 2 | GNSS connector, passive antenna (default) |
| 3 | GNSS connector, active antenna (DC bias on) |
| 4 | GNSS connector, active antenna, high gain (LM960 only; `AT$GPSANTPORT=?` gives the range) |

With the antenna on the other connector the receiver is on (`$GPSP: 1`) and `AT$GPSACP` stays
empty for good: no satellites at all. Seen on an LM960A18 in a router with antennas on the cellular
connectors only: with the default 2 nothing, with 1 a 3D fix in about 75 s.

`gps.sh antport` prints `{"supported":1,"value":N,"max":M}` for the Telit AT path and
`{"supported":0}` otherwise; `gps.sh antport <1-4>` switches the receiver off, sets the value and
switches it back on. The GPS tab shows the choice in the Receiver block ("GNSS antenna").

## Android phone

A phone connected over ADB (USB tethering, `kind=tether`) is a GNSS source of its own
(`source:"android"`, family `android`). `gps.sh` runs the cells helper in its `gnss` mode:
`CellProbe gnss 4` registers a GPS `LocationListener` and a `GnssStatus.Callback` as the shell
user, which holds `ACCESS_FINE_LOCATION`, waits up to 4 s for a fix made after the request
(the cached last fix that Android hands over on registration is ignored), and prints the fix,
satellites used / in view and the time to first fix. Without a fresh fix the phone's last GPS
fix is shown if it is under 30 s old. HDOP is not available from Android; the accuracy in metres
is passed as `acc` in the parser output only.

- **Screen off.** A dozing phone accepts the shell user's request but does not start the GNSS
  engine: the request counts as background location and is throttled (seen on a Xiaomi 17,
  Android 17: `registration onActive`, no `startNavigating`, no satellites). With
  `com.android.shell` in the global setting `location_background_throttle_package_whitelist`
  the engine starts with the screen off (TTFF 3.3 s, 16 of 49 satellites). `gps.sh` adds it on
  the first poll of a connection and on "Turn GNSS on", keeps any other entries, and removes only
  its own entry on "Turn GNSS off" (`settings delete` when the list becomes empty).
- On/off is the app's choice in `5gmodem.m_<path>.gps_on` (default on); the phone's own location
  switch is never touched.
- Cold start: `cmd location providers send-extra-command gps delete_aiding_data`.
- A poll takes 3-7 s (app_process start plus up to 4 s of GNSS), so the page shows a new
  position every 5-10 s.

## QMI location service

Qualcomm modems carry a GNSS engine behind the QMI LOC service, also on boards whose vendor gives
no GNSS AT commands, and also in MBIM mode (QMI-over-MBIM, `--device-open-mbim`, chosen by
`qmicli_p` from the cdc-wdm driver). For families that give the position only as NMEA (Foxconn,
Fibocom, Sierra) and for unknown vendors, `_caps` asks `--get-service-version-info` first; a
`loc (x.y)` line makes it the source (`loc=qmi`, family `qualcomm` when the vendor is unknown).

- A LOC session belongs to the client that started it. `on` runs `--loc-start
  --client-no-release-cid` and keeps the client id in `/tmp/5gmodem/gnss_qcid_<modem>`; every
  poll is `--client-cid=<id> --client-no-release-cid --loc-get-position-report --loc-timeout=4`.
  A second client sees no reports (checked live: `--loc-get-position-report` in a new client
  times out).
- `off` is `--client-cid=<id> --loc-stop` without `--client-no-release-cid`, so the client is
  released with its session. On Foxconn this replaces `AT+GPS=0`: no restart, no boot loop.
  `AT+GPS=1` is still needed when the receiver was switched off in hardware (`AT+GPS?` says off).
- The choice is kept in `5gmodem.m_<path>.gps_on`, so after a router or modem restart the next
  poll starts a new session by itself.
- An answer with no `[position report]` line (only the "Client ID not released" note) means the
  client is gone, as after a modem restart: the id is dropped and a new session starts on the next
  poll. An empty answer is a busy channel and keeps the session.
- Cold start: stop, `--loc-delete-assistance-data`, start. A non-`none` engine lock is cleared
  with `--loc-set-engine-lock=none` when the user turns GNSS on.
- Report fields (libqmi 1.36 `qmicli-loc.c`): `latitude`/`longitude` in degrees, `altitude w.r.t.
  mean sea level`, `horizontal speed` in m/s (shown in km/h), `heading`, `horizontal DOP`,
  `UTC timestamp` in ms, `Satellites used` as a list. Status `in-progress` with `n/a`
  coordinates is "searching".
- **Channel gate.** With `proto qmi`, `qmiraw` or `mbim` and the interface up, uqmi/umbim own
  cdc-wdm directly, and `qmicli_p` refuses (`qmi_channel_free`): a qmi-proxy next to them makes
  the session fail until a reboot (see health-and-recovery.md). The LOC source therefore works
  with ModemManager, `mbimp`, AT-dialled protocols, or while the modem interface is down; under a
  direct protocol the modem falls back to the AT/NMEA paths and is often "not supported". Checked
  live on a ZTE MF286D (MDM9250, `qmiraw`): with the interface down the service, the session by
  client id, cold start and off worked; with it up the tab stays hidden. That module has no GNSS
  antenna: 3 minutes of NMEA from the engine had no GSV sentence at all.

## ModemManager

When the modem's interface has `proto modemmanager`, or `mm_owns_path` says MM holds it, the AT
port belongs to MM and `gps.sh` uses the MM location API instead (`loc=mm`, family from the vendor
id, else `modemmanager`). The MM index comes from `modemswitch.sh mmindex` and is kept in
`/tmp/5gmodem/gnss_mmidx_<modem>`; when a call with it fails it is looked up once more, and if MM no
longer knows the modem the cached caps are dropped.

- `mmcli -J -m <i> --location-status`: `modem.location.capabilities[]` must hold `gps-nmea` or
  `gps-raw`; the receiver is on when `modem.location.enabled[]` holds one of them.
- On / off: `--location-enable-gps-nmea --location-enable-gps-raw` / `--location-disable-...`, only
  for the sources the modem has (one Setup call). The choice is kept in `5gmodem.m_<path>.gps_on`
  like the QMI session: when a poll finds the GPS sources disabled (after an MM or modem restart),
  it enables them again. No start modes.
- `mmcli -J -m <i> --location-get` (`parse-mm`): `modem.location.gps.nmea[]` holds the last NMEA
  traces and goes through the NMEA parser (speed, course, satellites, HDOP, date); `latitude`,
  `longitude`, `altitude` (GPS-raw, `"%lf"` strings, `--` when unknown) fill in when there is no
  NMEA. MM builds GPS-raw from GGA only and reports an unknown altitude as `-G_MAXDOUBLE`, which is
  dropped.
- Every call is `mmcli --timeout=15` (the D-Bus call) inside `timeout 20` when busybox has it.

## USB GNSS receivers

A GNSS receiver that is not a modem is not in `listmodems.sh`; `gps.sh` finds it in
`/sys/bus/usb/devices` (source `usbgps`, no on/off, no start modes, NMEA read for 2 s like the NMEA
port).

- `5gmodem.@5gmodem[0].gps_port` names the tty explicitly (`/dev/ttyACM*` or `/dev/ttyUSB*`,
  checked with `is_devpath`; the modem's AT and SMS ports are refused). When it is set and the
  device exists, it wins over every modem source for the position, and the modem is not asked at
  all. Family `ublox` for vendor `1546`, else `uart`. This is the only way to use a USB-UART bridge
  (CP210x `10c4:ea60`, CH340 `1a86:7523`, PL2303 `067b:2303`): these chips are not GPS-specific.
  The port is read at its current speed; `gps.sh` only sets `raw -echo`.
- Without it, a u-blox GNSS receiver on cdc_acm is found by itself: `1546:01a4` to `01a8`
  (Antaris 4, u-blox 5 to 8 in usb.ids; the VK-172 dongle is `01a7`) with a `ttyACM` under
  its interface. Other `1546` ids include u-blox cellular modules and are not taken. Such a receiver
  is used only when the modem has no GNSS source.

## NMEA port

Foxconn, Fibocom and Sierra give the position only as NMEA on a separate tty. `_nmea_port` tries
the modem's ttys from `listmodems.sh`, skips the AT port and the SMS/USSD ports, and reads each one
for 2 s. The first one that sends `$G?xxx,` sentences is cached in `/tmp/5gmodem/gnss_port_<modem>`. PCIe modems (T99W175, T99W373 over MHI) give NMEA on `/dev/wwanXnmeaY`; `listmodems.sh` does not list it, so those nodes are tried after the ttys. They are not ttys, so `stty` is skipped for them.

The Qualcomm generic ids `05c6:90d5`, `90d6` and `9025` are shared with the Compal RXM-G1. They are probed as Foxconn: a Compal answers nothing to `AT+GPS?`, so it stays unsupported, and an empty answer is not cached.
Before reading, the port is put into `stty raw -echo`: with the default line discipline the tty
echoes what it receives back into the modem. Without `stty` (it is a dependency of both packages)
the NMEA path is skipped.

`gnss_parse_nmea` reads GGA (fix, position, satellites used, HDOP, altitude), RMC (speed in knots
converted to km/h, course, date), GSA (2D/3D) and GSV (satellites in view, summed per talker:
GP, GL, GA, GB, GQ). Checksums are not verified; a sentence must still have the `$G?xxx` shape and
numeric fields.

Two open pages must not split one NMEA stream between two `cat` processes. A status younger than
3 s is served from `/tmp/5gmodem/gnss_last_<modem>.json`, and a lock directory serialises the
reads (a lock older than a minute is left by a killed run and is removed).

## ugps

If `ubus call gps info` answers (the `ugps` package with `/etc/config/gps`), that service owns the
NMEA port and the page shows its data with the source "ugps service". On/off and start mode
are hidden then: the receiver is configured outside the app.

## Tab

The tab is hidden by the same rules as the others (`modemtabs.js`):
- "Internet priorities only" (`netonly=1`) hides it with the other modem tabs;
- `show_gps=0` (Settings, "Main", "GPS tab") hides it;
- otherwise it is hidden until this modem was seen with a known receiver. `gps.sh caps` runs one
  second after a page opens, like the eSIM check, and the answer is kept in localStorage
  (`5gmodem.gps.supported.<path>`), so the tab does not blink on the next page.

The page follows the modem card of the Network page (`tginfo-*` classes, styles in the `tg-gps-*`
block of `modem.css`):
- header card: "GPS" with the source chip (`AT`, `NMEA`, `QMI`, `ugps`, `MM`, `USB`), a satellite
  icon with the fix type or "used/in view", the coordinates with a copy button, "updated N s ago"
  and a status pill (fix, searching, off). The age comes from `ts`; when the router and browser
  clocks disagree by more than a day, it counts from the moment the answer arrived. When the
  receiver is off, the card has the "Turn GNSS on" button;
- the map (see below), with "Open in" links (Yandex Maps, Google Maps, 2GIS, OSM) and a one-line
  privacy note under it;
- six tiles in the `tg-hist-card` style: altitude, speed, course (rotated arrow and an 8-point
  compass), satellites used / in view and HDOP with a bar, UTC time;
- "Receiver": source, start mode (hot, warm, cold as buttons), "Restart the search" and on/off.
  It is a collapsible block like the Network page sections (`5gm-blk-gpsrx` in localStorage),
  collapsed by default on phones. For `ugps` and `usbgps` it is a one-line note: there is nothing
  to control. Foxconn modems still ask for confirmation before the restart that applies the switch.

Below 700 px the layout is one column, the tiles go three per row without footers, the status
pill moves into the title and the Leaflet zoom buttons are hidden (pinch zoom works). A modem
without a receiver gets one card with the list of supported modems. Updates write into existing
nodes, nothing is rebuilt on a poll.

## Map

The map is Leaflet 1.9.4 (BSD-2, `htdocs/luci-static/resources/5gmodem/leaflet.js` and
`leaflet.css`, license in `root/usr/share/5gmodem/licenses/Leaflet-BSD-2.txt`). It ships in the
package, so nothing is loaded from a CDN. The default marker images are not shipped: the marker is a
`circleMarker`, with an accuracy circle of HDOP × 5 m around it when HDOP is known.

Leaflet assigns `window.L` at the end of its bundle, and `L` is LuCI itself. `gps.js` therefore
fetches the file as text, runs it with `new Function('exports', 'module', src)` and calls
`noConflict()` in the same synchronous step, then puts LuCI's `L` back. A `<script>` tag would leave
a window between the script and its `onload` in which LuCI timers could see Leaflet as `L`.

The page renders first, like the Network page: the header, the map box, the reading tiles (dashes)
and the Receiver block are drawn before the first `status` answer, and the layout is replaced by the
"no receiver" block only when that answer says so. Receiver buttons appear once the state is known.
With `gps_map_auto=1` (the default) Leaflet starts with the page at the world view (zoom 2, which
tells the tile server nothing about the router) and zooms to the position once, at the first fix;
with `0` the box shows a message and no tile is requested until "Load the map". If `leaflet.js` cannot be loaded, the box says so and offers the same
button; the rest of the page works without it. "Keep the position in the center" and "Clear track"
are a Leaflet control on the map (`leaflet-bar tg-gps-ctl`); dragging the map turns following off.
On a dark theme (light page text, the same test as `isDarkUI` in `netpri.js`) the tile layer is
dimmed with a CSS filter; the track and marker keep their colours.

The attribution corner shows only the tile provider's credit: the "Leaflet" prefix (link and
flag) is removed with `attributionControl.setPrefix(false)`.

Tiles come from OpenStreetMap (`https://tile.openstreetmap.org/{z}/{x}/{y}.png`) with attribution,
or from `gps_tiles` (an `https://` template with `{z}`, `{x}`, `{y}`). The browser loads the tiles,
so the tile server learns the area shown; the note under the map names the server. Yandex Maps and
2GIS are offered only as links: their map APIs need a key, and their tile servers are not meant for
third-party pages. The track is kept in the page (at most 2000 points) and is lost when the page
closes.

### Settings block on the tab

The GPS options are edited at the bottom of the GPS tab, in the collapsible "Settings" block (closed
by default): `gps_time`, `gps_traccar_url` / `gps_traccar_id` / `gps_traccar_interval`,
`gps_nmea_port`. One Save button validates them and does `uci save` + `uci commit 5gmodem`;
`gpsfeed.sh tick` picks the change up. The Settings page keeps only the tab switch `show_gps`.
`gps_map_auto` and a custom `gps_tiles` address have no field any more: they are still read, and
can be set with `uci`.

### Map styles

`gps_tiles` holds a style key or, as before, an https address template of the user's own tile
server. The keys (`MAPS` in `gps.js`): `osm`, `osm-hot`, `topo`, `esri-street`, `esri-sat`,
`yandex`, `yandex-dark`, `yandex-sat`. The same list is offered under the map; a choice made there
is kept in the browser (`localStorage` `5gmodem.gps.map`) and wins over the setting.

- Yandex tiles are cut in the elliptical Mercator projection (EPSG:3395). The style carries
  `crs: 3395`, the map's CRS is switched with the layer and the view is rebuilt around the same
  point; on the usual projection the position sits hundreds of metres off.
- The dark-interface CSS filter is applied only to styles marked `inv` (light maps), not to the
  satellite and dark ones.
- OpenTopoMap renders zoom 16 and deeper on demand and often times out there: the style asks for
  tiles up to zoom 15 (`nz`) and stretches them when zoomed in further.
- CARTO basemaps are not in the list: without a key their servers return an "API key required" tile.
- The Yandex addresses are the ones its own web map uses, not a published API.

## Telemetry

`tele.publish_gps=1` adds `gps_fix` and, with a fix, `gps_lat`, `gps_lon`, `gps_alt`,
`gps_speed`, `gps_course`, `gps_sats`, `gps_hdop` to `tele.json` and MQTT, and the matching
Home Assistant sensors to discovery. It is off by default: a stream of coordinates is a log of
where the router has been. Each telemetry tick then calls `gps.sh status`, which costs one AT
query or a 2 s NMEA read.

### QMI LOC position validity

A position report must have status `success` and valid latitude/longitude before
it is shown as a GNSS fix. When the report includes a technology mask, that mask
must include satellite positioning. In-progress reports and cellular-only estimates
are kept in the searching state with no coordinates. A modem can report a
cellular estimate with uncertainty spanning thousands of kilometres and invalid
GNSS time; the presence of coordinate fields alone does not establish a fix.

Compal devices sharing Qualcomm USB IDs with Foxconn are identified through their
USB product descriptor. Their GNSS support is discovered through ModemManager or
the QMI LOC service. Foxconn-specific AT GPS controls are not selected for them.
