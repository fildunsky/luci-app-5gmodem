#!/bin/sh
# GNSS receiver of the active modem (or a USB GNSS receiver): on/off, start mode, position.
#   gps.sh status [for=<path>]    position and receiver state as JSON
#   gps.sh caps   [for=<path>]    what this modem can do (cached per modem)
#   gps.sh on|off [for=<path>]
#   gps.sh start cold|warm|hot [for=<path>]
# Families and their commands: docs/subsystems/gps.md.

RES="${GPS_RES:-/usr/share/5gmodem}"
TD="${GPS_TMP:-/tmp/5gmodem}"
SYS="${GPS_SYS:-/sys}"

# --- parsers (no modem access; covered by tools/issue-regressions/test_gps.py) ---

# NMEA sentences on stdin -> "key=value" lines. GGA gives the fix, RMC speed/course/date,
# GSA the 2D/3D mode, GSV the satellites in view (summed over GP/GL/GA/GB/GQ talkers).
# Without GGA the satellites in use and HDOP come from GSA. "$PELCSLOC,..." is the FM350
# "+ELCSLOC:" position line (_fm_urc_read renames it): used when the sentences give no position.
#   lat,lon,alt,speed,course,hacc,vacc,spacc,cacc,ms,"yyyy/mm/dd,hh:mm:ss",pdop,hdop,vdop
gnss_parse_nmea() {
	awk -F, '
	function coord(v, h,   d, m) {
		if (v == "" || v !~ /^[0-9]+(\.[0-9]+)?$/) return ""
		d = int(v / 100); m = v - d * 100
		v = d + m / 60
		if (h == "S" || h == "W") v = -v
		return sprintf("%.6f", v)
	}
	{ sub(/\*[0-9A-Fa-f][0-9A-Fa-f][ \t]*$/, ""); t = substr($1, 4, 3); tk = substr($1, 2, 2) }
	$1 == "$PELCSLOC" {
		if ($2 ~ /^-?[0-9]+\.[0-9]+$/ && $3 ~ /^-?[0-9]+\.[0-9]+$/ && !($2 + 0 == 0 && $3 + 0 == 0)) {
			elat = sprintf("%.6f", $2); elon = sprintf("%.6f", $3)
			if ($4 ~ /^-?[0-9.]+$/) eal = $4 + 0
			if ($15 ~ /^[0-9.]+$/) ehd = $15 + 0
			d = $12; gsub(/[^0-9]/, "", d); h = $13; gsub(/[^0-9]/, "", h)
			if (length(d) == 8 && length(h) == 6)
				eutc = substr(d, 1, 4) "-" substr(d, 5, 2) "-" substr(d, 7, 2) "T" substr(h, 1, 2) ":" substr(h, 3, 2) ":" substr(h, 5, 2) "Z"
		}
		next
	}
	$1 !~ /^\$G[PLNABQ][A-Z][A-Z][A-Z]$/ { next }
	t == "GGA" {
		if ($7 != "" && $7 + 0 > 0) {
			la = coord($3, $4); lo = coord($5, $6)
			if (la != "" && lo != "") { lat = la; lon = lo; q = $7 + 0 }
			if ($8 != "") su = $8 + 0
			if ($9 != "") hd = $9 + 0
			if ($10 != "") al = $10 + 0
		} else if (q == "") q = 0
		if ($2 ~ /^[0-9]{6}/) tm = substr($2, 1, 6)
	}
	t == "RMC" {
		if ($3 == "A") {
			if ($8 != "") sp = sprintf("%.1f", $8 * 1.852)
			if ($9 != "") co = sprintf("%.1f", $9)
			if (lat == "") { la = coord($4, $5); lo = coord($6, $7); if (la != "" && lo != "") { lat = la; lon = lo; if (q == "") q = 1 } }
		}
		if ($10 ~ /^[0-9]{6}$/) dt = $10
		if ($2 ~ /^[0-9]{6}/) tm = substr($2, 1, 6)
	}
	t == "GSA" {
		if ($3 ~ /^[123]$/) md = $3 + 0
		# satellites in use: unique ids over all GSA sentences (one per system, NMEA 4.1 system id in $19)
		for (i = 4; i <= 15; i++) if ($i ~ /^[0-9]+$/ && !((($19 "") ":" ($i + 0)) in used)) { used[($19 "") ":" ($i + 0)] = 1; gu++ }
		if ($17 ~ /^[0-9.]+$/ && $17 + 0 < 99) ghd = $17 + 0
	}
	t == "GSV" { if ($4 ~ /^[0-9]+$/) vis[tk] = $4 + 0 }
	END {
		n = 0; for (k in vis) n += vis[k]
		if (su == "" && gu > 0 && md >= 2) su = gu
		if (hd == "" && ghd != "") hd = ghd
		if (lat == "" && elat != "") {
			lat = elat; lon = elon; if (q == "" || q == 0) q = 1
			if (al == "" && eal != "") al = eal
			if (hd == "" && ehd != "") hd = ehd
		}
		print "nmea=1"
		if (q != "") print "fix=" (q > 0 ? (md >= 2 ? md : 2) : 0)
		if (lat != "") { print "lat=" lat; print "lon=" lon }
		if (al != "") print "alt=" al
		if (sp != "") print "speed=" sp
		if (co != "") print "course=" co
		if (su != "") print "sats=" su
		if (n > 0) print "inview=" n
		if (hd != "") print "hdop=" hd
		if (dt != "" && tm != "") print "utc=20" substr(dt, 5, 2) "-" substr(dt, 3, 2) "-" substr(dt, 1, 2) "T" substr(tm, 1, 2) ":" substr(tm, 3, 2) ":" substr(tm, 5, 2) "Z"
		else if (eutc != "") print "utc=" eutc
	}'
}

# Position from an AT answer on stdin -> "key=value" lines.
#   quectel  +QGPSLOC: utc,lat,lon,hdop,alt,fix,cog,spkm,spkn,date,nsat   (mode 2: signed degrees)
#   telit    $GPSACP: utc,ddmm.mmmmN,dddmm.mmmmE,hdop,alt,fix,cog,spkm,spkn,date,nsat
#   simcom   +CGPSINFO: ddmm.mmmm,N,dddmm.mmmm,E,date,utc,alt,speed(kn),course
#   meig     +GpsLoc: utc,lat,N/S,lon,E/W,hdop,alt,fix,cog,speed,date,nsat
gnss_parse_at() {
	awk -v fam="$1" '
	function coord(v, h,   d, m) {
		if (v == "") return ""
		if (h == "") { if (v ~ /[NSEW]$/) { h = substr(v, length(v)); v = substr(v, 1, length(v) - 1) } }
		if (v !~ /^-?[0-9]+(\.[0-9]+)?$/) return ""
		if (h == "") return sprintf("%.6f", v)
		d = int(v / 100); m = v - d * 100; v = d + m / 60
		if (h == "S" || h == "W") v = -v
		return sprintf("%.6f", v)
	}
	function stamp(d, t) {
		if (d !~ /^[0-9]{6}$/ || t !~ /^[0-9]{6}/) return ""
		return "20" substr(d, 5, 2) "-" substr(d, 3, 2) "-" substr(d, 1, 2) "T" substr(t, 1, 2) ":" substr(t, 3, 2) ":" substr(t, 5, 2) "Z"
	}
	{ gsub(/\r/, "") }
	/^\+QGPSLOC:|^\$GPSACP:|^\+CGPSINFO:|^\+GpsLoc:|^\+GPSLOC:/ {
		s = $0; sub(/^[^:]*: */, "", s); n = split(s, f, ",")
		if (fam == "quectel" || fam == "telit") {
			la = coord(f[2], ""); lo = coord(f[3], "")
			fx = f[6]; hd = f[4]; al = f[5]; co = f[7]; sp = f[8]; su = f[11]; ut = stamp(f[10], f[1])
		} else if (fam == "simcom") {
			la = coord(f[1], f[2]); lo = coord(f[3], f[4])
			al = f[7]; co = f[9]; sp = (f[8] != "" ? sprintf("%.1f", f[8] * 1.852) : ""); fx = (la != "" ? 2 : ""); ut = stamp(f[5], f[6])
		} else if (fam == "meig") {
			la = coord(f[2], f[3]); lo = coord(f[4], f[5])
			hd = f[6]; al = f[7]; fx = f[8]; co = f[9]; su = f[12]; ut = stamp(f[11], f[1])
		}
		if (la == "" || lo == "") next
		got = 1
	}
	END {
		if (!got) { print "fix=0"; exit }
		if (fx !~ /^[23]$/) fx = 2
		print "fix=" fx; print "lat=" la; print "lon=" lo
		if (al ~ /^-?[0-9.]+$/) print "alt=" al + 0
		if (sp ~ /^[0-9.]+$/) print "speed=" sp + 0
		if (co ~ /^[0-9.]+$/) print "course=" co + 0
		if (su ~ /^[0-9]+$/) print "sats=" su + 0
		if (hd ~ /^[0-9.]+$/) print "hdop=" hd + 0
		if (ut != "") print "utc=" ut
	}'
}

# qmicli --loc-get-position-report on stdin -> "key=value" lines (libqmi 1.36 wording,
# src/qmicli/qmicli-loc.c: position_report_received). Speed comes in m/s, time as ms since 1970.
gnss_parse_qmi() {
	awk '
	/^\[position report\] status:/ { if (seen) exit; seen = 1; st = $NF; next }
	!seen { next }
	/^ *latitude: *-?[0-9]/  { la = sprintf("%.6f", $2) }
	/^ *longitude: *-?[0-9]/ { lo = sprintf("%.6f", $2) }
	/altitude w\.r\.t\. mean sea level: *-?[0-9]/ { al = sprintf("%.1f", $(NF - 1)) }
	/^ *horizontal speed: *[0-9]/ { sp = sprintf("%.1f", $3 * 3.6) }
	/^ *heading: *[0-9]/ { co = sprintf("%.1f", $2) }
	/^ *horizontal DOP: *[0-9]/ { hd = sprintf("%.1f", $3) }
	/^ *UTC timestamp: *[0-9]/ { ut = $3 }
	/^ *technology:/ { tech = tolower($0); sub(/^ *technology: */, "", tech) }
	/^ *Satellites used: *[0-9]/ { s = $0; sub(/^.*: */, "", s); su = split(s, x, ",") }
	END {
		if (!seen) { print "qmi=none"; exit }
		print "qmi=" st
		if (la == "" || lo == "" || st != "success" || la + 0 < -90 || la + 0 > 90 || lo + 0 < -180 || lo + 0 > 180 || (tech != "" && tech !~ /satellite/)) { print "fix=0"; exit }
		print "fix=" (al != "" ? 3 : 2); print "lat=" la; print "lon=" lo
		if (al != "") print "alt=" al
		if (sp != "") print "speed=" sp
		if (co != "") print "course=" co
		if (su > 0) print "sats=" su
		if (hd != "") print "hdop=" hd
		if (ut ~ /^[0-9]+$/) print "utcms=" ut
	}'
}

# CellProbe gnss JSON (an Android phone, android-cells.dex) on stdin -> "key=value" lines.
# A fix made during this call wins; otherwise the phone's last GPS fix if it is under 30 s old.
gnss_parse_android() {
	_pa=$(cat)
	_pr='@.fix'
	_pv=$(jsonfilter -s "$_pa" -e "$_pr.lat" 2>/dev/null)
	if [ -z "$_pv" ]; then
		_pr='@.last'
		_pg=$(jsonfilter -s "$_pa" -e '@.last.age_s' 2>/dev/null)
		case "$_pg" in ''|*[!0-9]*) _pg=999 ;; esac
		[ "$_pg" -le 30 ] && _pv=$(jsonfilter -s "$_pa" -e '@.last.lat' 2>/dev/null)
	fi
	_pu=$(jsonfilter -s "$_pa" -e '@.used' 2>/dev/null); _pi=$(jsonfilter -s "$_pa" -e '@.inview' 2>/dev/null)
	{
		[ -n "$_pu" ] && echo "sats=$_pu"
		[ -n "$_pi" ] && echo "inview=$_pi"
		if [ -z "$_pv" ]; then echo "fix=0"; else
			_pal=$(jsonfilter -s "$_pa" -e "$_pr.msl_alt" 2>/dev/null)
			[ -n "$_pal" ] || _pal=$(jsonfilter -s "$_pa" -e "$_pr.alt" 2>/dev/null)
			[ -n "$_pal" ] && echo "fix=3" || echo "fix=2"
			echo "lat=$_pv"; echo "lon=$(jsonfilter -s "$_pa" -e "$_pr.lon" 2>/dev/null)"
			[ -n "$_pal" ] && echo "alt=$_pal"
			echo "speedms=$(jsonfilter -s "$_pa" -e "$_pr.speed_ms" 2>/dev/null)"
			echo "course=$(jsonfilter -s "$_pa" -e "$_pr.bearing" 2>/dev/null)"
			echo "acc=$(jsonfilter -s "$_pa" -e "$_pr.accuracy_m" 2>/dev/null)"
			echo "utcms=$(jsonfilter -s "$_pa" -e "$_pr.time_ms" 2>/dev/null)"
		fi
	} | awk -F= '
		$1 == "speedms" { if ($2 ~ /^[0-9.]+$/) printf "speed=%.1f\n", $2 * 3.6; next }
		$1 == "course" || $1 == "alt" || $1 == "acc" { if ($2 ~ /^-?[0-9.]+(E-?[0-9]+)?$/) printf "%s=%.1f\n", $1, $2; next }
		$1 == "lat" || $1 == "lon" { if ($2 ~ /^-?[0-9.]+(E-?[0-9]+)?$/) printf "%s=%.6f\n", $1, $2; next }
		$2 != "" { print }'
}

# Receiver state from the answer to the family probe -> on|off|"" (unknown).
gnss_parse_state() {
	awk -v fam="$1" '
	{ gsub(/\r/, "") }
	fam == "quectel" && /^\+QGPS: *[01]/   { s = ($0 ~ /: *1/) ? "on" : "off" }
	fam == "simcom"  && /^\+CGPS: *[01]/   { s = ($0 ~ /: *1/) ? "on" : "off" }
	fam == "telit"   && /^\$GPSP: *[01]/   { s = ($0 ~ /: *1/) ? "on" : "off" }
	fam == "meig"    && /^\+GPSSTATE: *[0-9]/ { s = ($0 ~ /: *0/) ? "off" : "on" }
	fam == "fibocom" && /^\+ *GTGPSPOWER: *[01]/ { s = ($0 ~ /: *1/) ? "on" : "off" }
	fam == "foxconn" && /GPS is (Enable|Disable)/ { s = ($0 ~ /Enable/) ? "on" : "off" }
	fam == "foxconn" && /^(\+GPS(_MODE)?: *)?[01]$/ { s = ($0 ~ /1$/) ? "on" : "off" }
	# Huawei ^WPINFO: a bit mask of the GNSS systems in the positioning state, 0 = none
	fam == "huawei"  && /^\^WPINFO: *[0-9]+/ { v = $0; sub(/^[^:]*: */, "", v); s = (v + 0 > 0) ? "on" : "off" }
	END { print s }'
}

# Quectel AT+QGPSCFG="outport" answer on stdin -> the NMEA output port (none, usbnmea, uartdebug...).
gnss_parse_outport() {
	awk '{ gsub(/\r/, "") }
	/^\+QGPSCFG: *"outport" *, *"[A-Za-z0-9_]+"/ { v = $0; sub(/^[^,]*, *"/, "", v); sub(/".*$/, "", v); o = v }
	END { print o }'
}

# mmcli -J -m <i> --location-status on stdin -> "mmsrc=<gps sources it can give>" and "state=on|off".
# mmcli 1.24 prints the masks as arrays of nicks: modem.location.capabilities / .enabled.
gnss_parse_mm_status() {
	_pms=$(cat)
	_pms_c=$(printf '%s' "$_pms" | jsonfilter -e '@.modem.location.capabilities[*]' 2>/dev/null)
	_pms_e=$(printf '%s' "$_pms" | jsonfilter -e '@.modem.location.enabled[*]' 2>/dev/null)
	_pms_s=""
	for _pms_x in gps-nmea gps-raw; do
		printf '%s\n' "$_pms_c" | grep -qx "$_pms_x" && _pms_s="$_pms_s $_pms_x"
	done
	echo "mmsrc=${_pms_s# }"
	if printf '%s\n' "$_pms_e" | grep -qxE 'gps-(nmea|raw)'; then echo "state=on"; else echo "state=off"; fi
}

# mmcli -J -m <i> --location-get on stdin -> "key=value" lines. modem.location.gps.nmea[] holds the
# last NMEA traces (parsed with gnss_parse_nmea for speed, course, satellites, HDOP); latitude,
# longitude and altitude come from GPS-raw as "%lf" strings, "--" when unknown.
gnss_parse_mm() {
	_pm=$(cat)
	{
		for _pm_f in latitude:lat longitude:lon altitude:alt; do
			echo "r_${_pm_f#*:}=$(printf '%s' "$_pm" | jsonfilter -e "@.modem.location.gps.${_pm_f%%:*}" 2>/dev/null)"
		done
		printf '%s' "$_pm" | jsonfilter -e '@.modem.location.gps.nmea[*]' 2>/dev/null | tr -d '\r' | gnss_parse_nmea
	} | awk '
	function num(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
	{ k = $0; sub(/=.*/, "", k); v = substr($0, length(k) + 2) }
	k ~ /^r_/ { r[substr(k, 3)] = v; next }
	k != "nmea" { n[k] = v; ord[++cnt] = k }
	END {
		print "mm=1"
		la = r["lat"] + 0; lo = r["lon"] + 0; al = r["alt"] + 0
		rok = num(r["lat"]) && num(r["lon"]) && la >= -90 && la <= 90 && lo >= -180 && lo <= 180
		ra = num(r["alt"]) && al > -2000 && al < 100000
		if (n["fix"] == "0" || (n["lat"] == "" && !rok)) { print "fix=0"; exit }
		if (n["lat"] == "") {
			print "fix=" (ra ? 3 : 2)
			printf "lat=%.6f\nlon=%.6f\n", la, lo
			if (ra) printf "alt=%.1f\n", al
		}
		for (i = 1; i <= cnt; i++) print ord[i] "=" n[ord[i]]
		if (n["lat"] != "" && n["alt"] == "" && ra) printf "alt=%.1f\n", al
	}'
}

_TGT=""; _args=""
for _a in "$@"; do
	case "$_a" in
		for=*) _TGT="${_a#for=}" ;;
		*)     _args="$_args $_a" ;;
	esac
done
set -- $_args
case "$_TGT" in *[!A-Za-z0-9._:-]*) _TGT="" ;; esac

case "$1" in
	parse-nmea)  gnss_parse_nmea; exit 0 ;;
	parse-at)    gnss_parse_at "$2"; exit 0 ;;
	parse-state) gnss_parse_state "$2"; exit 0 ;;
	parse-qmi)   gnss_parse_qmi; exit 0 ;;
	parse-mm)    gnss_parse_mm; exit 0 ;;
	parse-mm-status) gnss_parse_mm_status; exit 0 ;;
	parse-outport)   gnss_parse_outport; exit 0 ;;
	parse-android)   gnss_parse_android; exit 0 ;;
esac

# --- modem access ---

. "$RES/lib.sh" 2>/dev/null
mkdir -p "$TD" 2>/dev/null
[ -n "$_TGT" ] || _TGT=$(uci -q get 5gmodem.@5gmodem[0].active_modem)

_sec=""; _vp=""; _atp=""; _kind=""
[ -n "$_TGT" ] && _sec=$(secname "$_TGT")
if [ -n "$_sec" ]; then
	_vp=$(uci -q get "5gmodem.$_sec.vidpid" | tr 'A-F' 'a-f')
	_atp=$(uci -q get "5gmodem.$_sec.at_port")
	_kind=$(uci -q get "5gmodem.$_sec.kind")
fi
[ -n "$_atp" ] || _atp=$(uci -q get 5gmodem.@5gmodem[0].at_port)
_K=$(printf '%s' "${_sec:-none}" | tr -c 'A-Za-z0-9_\n' '_')
CAPS="$TD/gnss_caps_$_K"
LAST="$TD/gnss_last_$_K.json"

_at() { at_query "$_atp" "$1" "${2:-6}" 8; }

# a command with a time limit when busybox has "timeout"
_tmo() {
	_tm_t="$1"; shift
	if command -v timeout >/dev/null 2>&1; then timeout "$_tm_t" "$@"; return; fi
	# no "timeout" applet: run it in the background and kill it when the time is up
	"$@" &
	_tm_p=$!
	( sleep "$_tm_t"; kill "$_tm_p" 2>/dev/null ) >/dev/null 2>&1 &
	_tm_k=$!
	wait "$_tm_p"; _tm_rc=$?
	kill "$_tm_k" 2>/dev/null
	return $_tm_rc
}

# Family by USB vendor; Dell ids split between Foxconn and Sierra builds.
_family_hint() {
	if [ -n "$_TGT" ]; then
		case "$(cat "/sys/bus/usb/devices/$_TGT/product" 2>/dev/null)" in
			*VOS_5G*|*RXMG1*|*RXM-G1*|*SG500M2*) echo compal; return ;;
		esac
	fi
	case "$_vp" in
		2c7c:*) echo quectel ;;
		1e0e:*) echo simcom ;;
		1bc7:*) echo telit ;;
		2dee:*) echo meig ;;
		0e8d:*|2cb7:*) echo fibocom ;;
		0489:*|1e2d:*|105b:*) echo foxconn ;;
		05c6:90d5|05c6:90d6|05c6:9025) echo foxconn ;;
		413c:81d7|413c:81d8|413c:81d9|413c:81e0|413c:81e4|413c:81e6) echo foxconn ;;
		1199:*|0f3d:*|413c:*) echo sierra ;;
		# ME909/ME906 and other modules with ^WPDGP; HiLink sticks share the vendor id and fail the probe
		12d1:*) echo huawei ;;
	esac
}

_probe_cmd() {
	case "$1" in
		quectel) echo 'AT+QGPS?' ;;
		simcom)  echo 'AT+CGPS?' ;;
		telit)   echo 'AT$GPSP?' ;;
		meig)    echo 'AT+GPSSTATE?' ;;
		fibocom) echo 'AT+GTGPSPOWER?' ;;
		foxconn) echo 'AT+GPS?' ;;
		sierra)  echo 'AT!GPSSTATUS?' ;;
		huawei)  echo 'AT^WPDOM?' ;;
	esac
}

# the receiver state; the same command as the probe except on Huawei
_state_cmd() {
	case "$1" in
		huawei) echo 'AT^WPINFO?' ;;
		*) _probe_cmd "$1" ;;
	esac
}

# NMEA port: a tty of this modem that is not the AT/SMS port and streams $G... sentences.
_tty_list() {
	"$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path='$_TGT'].tty[*]" 2>/dev/null
}

_nmea_read() {
	[ -c "$1" ] || return 1
	case "$1" in
		/dev/wwan*) ;;   # MHI/WWAN char device, not a tty: no line discipline to switch off
		*) command -v stty >/dev/null 2>&1 || return 1
		   stty -F "$1" raw -echo 2>/dev/null || return 1 ;;
	esac
	_nr_o=$(mktemp "$TD/nmea.XXXXXX" 2>/dev/null) || return 1
	# a log/debug port of the same modem can stream megabytes: keep at most 64 KiB in RAM.
	# One process that the timer kills: with "cat | head" only head was killed and cat stayed
	# blocked on a silent port for good, and so did gps.sh waiting for it
	dd if="$1" of="$_nr_o" bs=256 count=256 </dev/null 2>/dev/null &
	_nr_p=$!
	sleep "${2:-2}"
	kill "$_nr_p" 2>/dev/null; wait "$_nr_p" 2>/dev/null
	tr -d '\r' < "$_nr_o" | grep -a '^\$G[PLNABQ][A-Z][A-Z][A-Z],' | tail -n 60
	rm -f "$_nr_o"
}

# USB interface class/subclass/protocol of a tty ("ff/01/14"); ttyUSB sits one level below its interface
_tty_ifc() {
	_ti_d=$(readlink -f "$SYS/class/tty/$1/device" 2>/dev/null) || return 1
	[ -f "$_ti_d/bInterfaceClass" ] || _ti_d="${_ti_d%/*}"
	[ -f "$_ti_d/bInterfaceClass" ] || return 1
	echo "$(cat "$_ti_d/bInterfaceClass")/$(cat "$_ti_d/bInterfaceSubClass")/$(cat "$_ti_d/bInterfaceProtocol")"
}

# vid:pid of the USB device a tty belongs to
_tty_vidpid() {
	_tv_d=$(readlink -f "$SYS/class/tty/$1/device" 2>/dev/null) || return 1
	while [ -n "$_tv_d" ] && [ "$_tv_d" != / ] && [ ! -f "$_tv_d/idVendor" ]; do _tv_d="${_tv_d%/*}"; done
	[ -f "$_tv_d/idVendor" ] || return 1
	echo "$(cat "$_tv_d/idVendor"):$(cat "$_tv_d/idProduct")" | tr 'A-F' 'a-f'
}

# Huawei marks its NMEA interface ff/01/05, ff/01/14 or ff/06/14 (ModemManager
# 77-mm-huawei-net-port-types.rules); those ttys are read first
_tty_order() {
	_to_a=""; _to_b=""
	for _to in "$@"; do
		case "$_fam:$(_tty_ifc "${_to##*/}")" in
			huawei:ff/01/05|huawei:ff/01/14|huawei:ff/06/14) _to_a="$_to_a $_to" ;;
			*) _to_b="$_to_b $_to" ;;
		esac
	done
	echo $_to_a $_to_b
}

_np_skip() {
	echo " $_atp $(uci -q get 5gmodem.@5gmodem[0].device) $(uci -q get 5gmodem.sms.readport) $(uci -q get 5gmodem.sms.sendport) $(uci -q get 5gmodem.sms.ussdport) $(uci -q get 5gmodem.sms.atport) "
}

_nmea_port() {
	_np_c="$TD/gnss_port_$_K"
	if [ -s "$_np_c" ]; then
		_np=$(cat "$_np_c")
		[ -c "$_np" ] && { echo "$_np"; return 0; }
	fi
	_np_skip=$(_np_skip)
	# PCIe modems (T99W175/T99W373 over MHI) give NMEA on /dev/wwanXnmeaY, which listmodems does not list
	for _np in $(_tty_order $(_tty_list)) $(ls /dev/wwan*nmea* 2>/dev/null); do
		case "$_np_skip" in *" $_np "*) continue ;; esac
		is_devpath "$_np" || continue
		if [ -n "$(_nmea_read "$_np" 2)" ]; then
			echo "$_np" > "$_np_c"
			echo "$_np"
			return 0
		fi
	done
	return 1
}

# QMI LOC service (Qualcomm): works over the QMI control port and over MBIM (QMI-over-MBIM),
# without an NMEA port or vendor AT commands. A LOC session belongs to the client that started
# it, so the client id is kept in gnss_qcid_<modem> and every poll reuses it.
_wdm() {
	"$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path='$_TGT'].wdm[0]" 2>/dev/null
}
QCID="$TD/gnss_qcid_$_K"

_q() {
	command -v qmicli_p >/dev/null 2>&1 || return 1
	_q_w=$(_wdm); [ -n "$_q_w" ] || return 1
	qmicli_p "$_q_w" "$@"
}

_qstart() {
	_qs=$(_q --loc-start --client-no-release-cid) || return 1
	_qc=$(printf '%s\n' "$_qs" | sed -n "s/^.*CID: *'\([0-9]*\)'.*$/\1/p" | head -n 1)
	case "$_qc" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$_qs" | grep -q 'Successfully started' || { _q --client-cid="$_qc" --loc-noop >/dev/null; return 1; }
	echo "$_qc" > "$QCID"
}

_qstop() {
	_qc=$(cat "$QCID" 2>/dev/null)
	rm -f "$QCID"
	case "$_qc" in ''|*[!0-9]*) return 0 ;; esac
	# without --client-no-release-cid the client is released together with its session
	_q --client-cid="$_qc" --loc-stop >/dev/null
}

# ModemManager location API (mmcli). Every call is limited in time: mmcli --timeout covers the
# D-Bus call, "timeout" the whole process. The MM index of this modem is kept in gnss_mmidx_<modem>
# and looked up again when a call with it fails (MM restarted, modem re-probed).
_mm() { _tmo 20 mmcli --timeout=15 "$@" 2>/dev/null; }

_mm_index() {
	[ -n "$_TGT" ] && [ "$_kind" != hilink ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	_mx_c="$TD/gnss_mmidx_$_K"
	if [ "$1" != fresh ] && [ -s "$_mx_c" ]; then cat "$_mx_c"; return 0; fi
	_mx_if=$(uci -q get "5gmodem.$_sec.network")
	if [ -z "$_mx_if" ] || [ "$(uci -q get "network.$_mx_if.proto")" != modemmanager ]; then
		command -v mm_owns_path >/dev/null 2>&1 && mm_owns_path "$_TGT" || return 1
	fi
	_mx=$(_tmo 30 "$RES/modemswitch.sh" mmindex "$_TGT" 2>/dev/null)
	case "$_mx" in ''|*[!0-9]*) rm -f "$_mx_c"; return 1 ;; esac
	echo "$_mx" > "$_mx_c"
	echo "$_mx"
}

# location status of the MM modem -> mmsrc=, state=, mmidx=
_mm_status() {
	for _ms_t in cached fresh; do
		_ms_i=$(_mm_index "$_ms_t") || return 1
		_ms_o=$(_mm -m "$_ms_i" -J --location-status)
		if [ -n "$_ms_o" ]; then
			printf '%s
' "$_ms_o" | gnss_parse_mm_status
			echo "mmidx=$_ms_i"
			return 0
		fi
		rm -f "$TD/gnss_mmidx_$_K"
	done
	return 1
}

# on|off for the GPS sources this modem has in MM ($2: "gps-nmea gps-raw")
_mm_setup() {
	_mu_s=$(_mm_status) || return 1
	_mu_i=$(_kv "$_mu_s" mmidx); _mu_a=""
	for _mu_x in $(_kv "$_mu_s" mmsrc); do
		[ "$1" = on ] && _mu_a="$_mu_a --location-enable-$_mu_x" || _mu_a="$_mu_a --location-disable-$_mu_x"
	done
	[ -n "$_mu_a" ] || return 1
	_mm -m "$_mu_i" $_mu_a | grep -q 'successfully setup'
}

# USB GNSS receiver that is not a modem -> "port family how" (how: explicit|auto).
# 5gmodem.@5gmodem[0].gps_port names a tty explicitly (u-blox or a USB-UART bridge: CP210x
# 10c4:ea60, CH340 1a86:7523, PL2303 067b:2303). Without it, only u-blox GNSS receivers are found
# on their own: 1546:01a4..01a8 on cdc_acm (other u-blox ids are cellular modules).
_usbgps() {
	_ug_p=$(uci -q get 5gmodem.@5gmodem[0].gps_port)
	if [ -n "$_ug_p" ] && is_devpath "$_ug_p" && [ -c "$_ug_p" ]; then
		case "$(_np_skip)" in *" $_ug_p "*) ;; *)
			case "$(_tty_vidpid "${_ug_p##*/}")" in
				1546:*) echo "$_ug_p ublox explicit" ;;
				*) echo "$_ug_p uart explicit" ;;
			esac
			return 0 ;;
		esac
	fi
	for _ug_d in "$SYS"/bus/usb/devices/*; do
		[ "$(cat "$_ug_d/idVendor" 2>/dev/null)" = 1546 ] || continue
		case "$(cat "$_ug_d/idProduct" 2>/dev/null)" in 01a[4-8]) ;; *) continue ;; esac
		for _ug_t in "$_ug_d":*/tty/ttyACM*; do
			[ -e "$_ug_t" ] || continue
			echo "/dev/${_ug_t##*/} ublox auto"
			return 0
		done
	done
	return 1
}

# Android phone over ADB: the cells helper turns GPS on for up to 4 s as the shell user
# (docs/modems/android-phones.md#gnss). On/off is our own choice in gps_on: the phone's
# location switch is not touched.
_android() { [ "$_kind" = tether ] && command -v android_tether_path >/dev/null 2>&1 && android_tether_path "$_TGT"; }
_android_fix() {
	command -v android_cells_ready >/dev/null 2>&1 || . "$RES/android.sh"
	_as=$(android_cells_ready "$_TGT") || return 1
	android_adb -s "$_as" shell "CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe gnss 4" \
		| gnss_parse_android
}
_android_on() { [ "$(uci -q get "5gmodem.$_sec.gps_on")" != 0 ]; }

# A dozing phone (screen off) throttles background location: the shell user's request is accepted
# but the GNSS engine never starts. Listing com.android.shell in the throttle whitelist lets it
# start; other entries of the list are kept, and turning GNSS off removes only ours.
_android_wl() {
	command -v android_cells_ready >/dev/null 2>&1 || . "$RES/android.sh"
	_aw_s=$(android_usb_serial "$_TGT") || return 1
	_aw_k=location_background_throttle_package_whitelist
	_aw_v=$(android_adb -s "$_aw_s" shell "settings get global $_aw_k" | tr -d '\r')
	[ "$_aw_v" = null ] && _aw_v=""
	case ",$_aw_v," in *,com.android.shell,*) _aw_in=1 ;; *) _aw_in=0 ;; esac
	if [ "$1" = add ]; then
		[ "$_aw_in" = 1 ] && return 0
		logger -t 5gmodem "gps: phone location throttle whitelist += com.android.shell"
		android_adb -s "$_aw_s" shell "settings put global $_aw_k ${_aw_v:+$_aw_v,}com.android.shell" >/dev/null
	else
		[ "$_aw_in" = 1 ] || return 0
		_aw_n=$(printf '%s' "$_aw_v" | awk -v RS=, -v ORS= '$0 != "com.android.shell" && $0 != "" { printf "%s%s", s, $0; s = "," }')
		if [ -n "$_aw_n" ]; then
			android_adb -s "$_aw_s" shell "settings put global $_aw_k $_aw_n" >/dev/null
		else
			android_adb -s "$_aw_s" shell "settings delete global $_aw_k" >/dev/null
		fi
	fi
}

_qwant() { [ -n "$_sec" ] && [ "$(uci -q get "5gmodem.$_sec.gps_on")" = 1 ]; }

_qwant_set() {
	[ -n "$_sec" ] || return 0
	if [ "$1" = 1 ]; then uci -q set "5gmodem.$_sec.gps_on=1"; else uci -q delete "5gmodem.$_sec.gps_on"; fi
	uci -q commit 5gmodem
}

_caps() {
	# the cache belongs to one modem: another modem on the same USB port gets a fresh probe
	# (the usb hotplug script 71-5gmodem-resolve drops these files as well)
	if [ -s "$CAPS" ]; then
		_cached_family=$(sed -n 's/^fam=//p' "$CAPS" | head -n 1)
		_current_family=$(_family_hint)
		if [ "$(sed -n 's/^vp=//p' "$CAPS" | head -n 1)" = "$_vp" ] \
			&& { { [ "$_cached_family" != compal ] && [ "$_current_family" != compal ]; } || [ "$_cached_family" = "$_current_family" ]; }; then
			cat "$CAPS"; return
		fi
		rm -f "$CAPS" "$TD/gnss_port_$_K"
	fi
	# a silent or busy port is not cached for good, but it is not asked again for a minute:
	# the FM350 probe walks every tty of the modem, 4 s each, on every status poll otherwise
	if [ -s "$CAPS.neg" ]; then
		_cn_a=$(( $(date +%s) - $(date -r "$CAPS.neg" +%s 2>/dev/null || echo 0) ))
		[ "$_cn_a" -ge 0 ] && [ "$_cn_a" -lt 60 ] && { cat "$CAPS.neg"; return; }
		rm -f "$CAPS.neg"
	fi
	# a HiLink stick is a router of its own: no AT port, no GNSS commands
	if [ "$_kind" = hilink ]; then printf '%s\n' "sup=0" "fam=" "loc=" "modes=" "reboot=0" "hw=" "lock=" "outport="; return; fi
	if _android; then
		printf '%s\n' "sup=1" "fam=android" "loc=android" "modes=cold" "reboot=0" "hw=" "lock=" "outport="
		return
	fi
	_fam=$(_family_hint)
	# ModemManager owns the modem: its location API, not AT commands on a port MM holds
	if _mc_s=$(_mm_status) && [ -n "$(_kv "$_mc_s" mmsrc)" ]; then
		_c="sup=1
fam=${_fam:-modemmanager}
loc=mm
modes=
reboot=0
hw=$(_kv "$_mc_s" state)
lock=
outport=
vp=$_vp"
		printf '%s\n' "$_c" > "$CAPS"
		printf '%s\n' "$_c"
		return
	fi
	_sup=0; _st=""; _r=""; _op=""; _gap=""
	if [ -n "$_fam" ] && [ -n "$_atp" ]; then
		_probe=$(_probe_cmd "$_fam")
		[ -z "$_probe" ] || _r=$(_at "$_probe")
		case "$_fam" in
			sierra) printf '%s' "$_r" | grep -q 'ERROR' || { [ -n "$_r" ] && _sup=1; } ;;
			fibocom)
				_st=$(printf '%s\n' "$_r" | gnss_parse_state fibocom)
				# FM350 (0e8d) answers the GNSS commands on the AP-side AT port (interface 3), not on
				# the modem AT port (interface 6) the app polls: that one gives ERROR or nothing
				if [ -z "$_st" ] && [ "${_vp%%:*}" = 0e8d ]; then
					for _gp in $(_tty_list); do
						[ "$_gp" = "$_atp" ] && continue
						is_devpath "$_gp" || continue
						_st=$(at_query "$_gp" 'AT+GTGPSPOWER?' 4 4 | gnss_parse_state fibocom)
						[ -n "$_st" ] && { _gap="$_gp"; _atp="$_gp"; break; }
					done
				fi
				if [ -n "$_st" ]; then _sup=1
				elif printf '%s' "$(_at 'AT+GTGPSSWITCH?')" | grep -q 'GTGPSSWITCH: *0'; then _sup=1; _st=locked
				fi ;;
			huawei)
				# ^WPDOM: answers only where the GPS service interface exists
				if printf '%s\n' "$_r" | grep -q '^\^WPDOM:'; then
					_sup=1; _st=$(_at "$(_state_cmd huawei)" | gnss_parse_state huawei)
				fi ;;
			*) _st=$(printf '%s\n' "$_r" | gnss_parse_state "$_fam"); [ -n "$_st" ] && _sup=1 ;;
		esac
		# Quectel: where NMEA goes (none, usbnmea, uartdebug); "none" leaves ugps/gpsd without data
		[ "$_fam:$_sup" = quectel:1 ] && _op=$(_at 'AT+QGPSCFG="outport"' | gnss_parse_outport)
	fi
	_loc=nmea
	case "$_fam" in quectel|simcom|telit|meig) _loc=at ;; esac
	_modes=""
	case "$_fam" in
		quectel|telit|fibocom) _modes="cold warm hot" ;;
		simcom) _modes="cold hot" ;;
	esac
	_reboot=0; [ "$_fam" = foxconn ] && _reboot=1
	_lock=""; _qr=""
	# QMI LOC first for the modems that give the position only as NMEA (and for unknown vendors):
	# no port hunting, and on/off is a session, not a stored setting with a modem restart
	if [ "$_loc" = nmea ] && _qr=$(_q --get-service-version-info) \
	   && printf '%s\n' "$_qr" | grep -qE '^[[:space:]]+loc \('; then
		_sup=1; _loc=qmi; _modes=cold; [ -n "$_fam" ] || _fam=qualcomm
		_lock=$(_q --loc-get-engine-lock | sed -n 's/^.*engine lock: *//p' | head -n 1)
		# Foxconn: with AT+GPS=0 the receiver is off in hardware; only AT+GPS=1 (a restart) brings it back
		[ "$_fam" = foxconn ] && [ "$_st" = off ] || _reboot=0
	fi
	_c="sup=$_sup
fam=$_fam
loc=$_loc
modes=$_modes
reboot=$_reboot
hw=$_st
lock=$_lock
outport=$_op
atport=$_gap
vp=$_vp"
	# a "no" is cached too (the probe costs a round trip), but not a busy or silent port
	if [ "$_sup" = 1 ] || [ -n "$_r" ] || [ -n "$_qr" ]; then
		printf '%s\n' "$_c" > "$CAPS"; rm -f "$CAPS.neg"
	else
		printf '%s\n' "$_c" > "$CAPS.neg"
	fi
	printf '%s\n' "$_c"
}

_kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# the AT port that takes the GNSS commands, when caps found it on another tty of the modem
_use_gnss_atp() { _ua=$(_kv "$1" atport); [ -n "$_ua" ] && [ -c "$_ua" ] && _atp="$_ua"; return 0; }

# caps with a USB GNSS receiver: an explicit gps_port wins over the modem, a u-blox found on its
# own is used when the modem has no source. Not cached: a receiver can be plugged in at any time.
_caps_eff() {
	if _ce_u=$(_usbgps); then
		set -- $_ce_u
		if [ "$3" = auto ]; then
			_ce_c=$(_caps)
			[ "$(_kv "$_ce_c" sup)" = 1 ] && { printf '%s\n' "$_ce_c"; return; }
		fi
		printf '%s\n' "sup=1" "fam=$2" "loc=usbgps" "modes=" "reboot=0" "hw=" "lock=" "outport=" "port=$1"
		return
	fi
	_caps
}

_ugps() {
	command -v ubus >/dev/null 2>&1 || return 1
	_u=$(ubus -S call gps info 2>/dev/null) || return 1
	_la=$(printf '%s' "$_u" | jsonfilter -e '@.latitude' 2>/dev/null)
	_lo=$(printf '%s' "$_u" | jsonfilter -e '@.longitude' 2>/dev/null)
	echo "ugps=1"
	case "$_la$_lo" in ''|*[!0-9.-]*) echo "fix=0"; return 0 ;; esac
	echo "fix=2"; echo "lat=$_la"; echo "lon=$_lo"
	# ugps: signed degrees, speed from VTG in km/h, satellites and HDOP from GGA
	for _f in elevation:alt speed:speed course:course satellites:sats HDOP:hdop; do
		_v=$(printf '%s' "$_u" | jsonfilter -e "@.${_f%%:*}" 2>/dev/null)
		case "$_v" in ''|*[!0-9.-]*) ;; *) echo "${_f#*:}=$_v" ;; esac
	done
	return 0
}

_num() { case "$1" in ''|*[!0-9.-]*) printf 'null' ;; *) printf '%s' "$1" ;; esac; }
_str() { printf '"%s"' "$(printf '%s' "$1" | tr -cd 'A-Za-z0-9 :._/-')"; }

_json() {
	# $1 caps, $2 key=value data, $3 state, $4 source, $5 port
	printf '{"supported":%s,"family":%s,"state":%s,"source":%s,"port":%s,"modes":%s,"reboot":%s,"outport":%s,' \
		"$(_num "$(_kv "$1" sup)")" "$(_str "$(_kv "$1" fam)")" "$(_str "$3")" "$(_str "$4")" \
		"$(_str "$5")" "$(_str "$(_kv "$1" modes)")" "$(_num "$(_kv "$1" reboot)")" "$(_str "$(_kv "$1" outport)")"
	printf '"fix":%s,"lat":%s,"lon":%s,"alt":%s,"speed":%s,"course":%s,"sats":%s,"inview":%s,"hdop":%s,"utc":%s,"ts":%s}\n' \
		"$(_num "$(_kv "$2" fix)")" "$(_num "$(_kv "$2" lat)")" "$(_num "$(_kv "$2" lon)")" \
		"$(_num "$(_kv "$2" alt)")" "$(_num "$(_kv "$2" speed)")" "$(_num "$(_kv "$2" course)")" \
		"$(_num "$(_kv "$2" sats)")" "$(_num "$(_kv "$2" inview)")" "$(_num "$(_kv "$2" hdop)")" \
		"$(_str "$(_kv "$2" utc)")" "$(date +%s)"
}

_status() {
	# two open tabs must not split one NMEA stream: a fresh answer is shared
	if [ -s "$LAST" ]; then
		_age=$(( $(date +%s) - $(date -r "$LAST" +%s 2>/dev/null || echo 0) ))
		# FM350: one read holds the modem's AT port for ~3 s, so its answer is shared for longer
		# (the NMEA TCP server asks every second per client)
		_ttl=3; [ "${_vp%%:*}" = 0e8d ] && _ttl=10
		[ "$_age" -ge 0 ] && [ "$_age" -lt "$_ttl" ] && { cat "$LAST"; return; }
	fi
	_lk="$TD/gnss_lock_$_K"
	if ! mkdir "$_lk" 2>/dev/null; then
		# a lock older than a minute is left by a killed run
		if [ -n "$(find "$_lk" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then rmdir "$_lk" 2>/dev/null; fi
		[ -s "$LAST" ] && { cat "$LAST"; return; }
		mkdir "$_lk" 2>/dev/null || { echo '{"supported":0,"busy":1}'; return; }
	fi
	_c=$(_caps_eff); _use_gnss_atp "$_c"
	_fam=$(_kv "$_c" fam); _st=""; _src=""; _port=""; _d=""
	if _d=$(_ugps); then
		_src=ugps
	elif [ "$(_kv "$_c" loc)" = usbgps ]; then
		# a plain NMEA receiver: no on/off, no start modes
		_src=usbgps; _port=$(_kv "$_c" port)
		_d=$(_nmea_read "$_port" 2 | gnss_parse_nmea)
	elif [ "$(_kv "$_c" loc)" = android ]; then
		_src=android; _st=off
		if _android_on; then
			_st=on
			# once per phone connection (the marker lives in /tmp like the dex marker)
			[ -f "$TD/gnss_awl_$_K" ] || { _android_wl add && : > "$TD/gnss_awl_$_K"; }
			_d=$(_android_fix)
			_um=$(_kv "$_d" utcms)
			[ -n "$_um" ] && _d="$_d
utc=$(date -u -d "@$((_um / 1000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
		fi
	elif [ "$(_kv "$_c" loc)" = mm ]; then
		_src=mm
		if _ms=$(_mm_status); then
			_st=$(_kv "$_ms" state)
			# MM forgets the setup on its own restart and on a modem restart: the stored choice brings it back
			[ "$_st" = off ] && _qwant && _mm_setup on && _st=on
			[ "$_st" = on ] && _d=$(_mm -m "$(_kv "$_ms" mmidx)" -J --location-get | gnss_parse_mm)
		else
			# MM let the modem go (other protocol, modem gone): probe again next time
			rm -f "$CAPS"
		fi
	elif [ "$(_kv "$_c" sup)" = 1 ]; then
		case "$_fam" in
			sierra|qualcomm|compal) ;;
			*) [ -n "$_atp" ] && _st=$(_at "$(_state_cmd "$_fam")" | gnss_parse_state "$_fam") ;;
		esac
		if [ "$(_kv "$_c" loc)" = qmi ]; then
			_src=qmi
			if [ "$_fam" = foxconn ] && [ "$_st" = off ]; then
				rm -f "$QCID"
			else
				[ -s "$QCID" ] || { _qwant && _qstart; }
				_st=off
				if [ -s "$QCID" ]; then
					_st=on
					_qo=$(_q --client-cid="$(cat "$QCID")" --client-no-release-cid \
						--loc-get-position-report --loc-timeout=4)
					# an empty answer is a busy QMI channel: keep the session and try again on the next poll
					if [ -n "$_qo" ]; then
						_d=$(printf '%s\n' "$_qo" | gnss_parse_qmi)
						case "$(_kv "$_d" qmi)" in
							none|phone-offline|engine-locked|general-failure)
								# the client is gone (modem restart) or the session died: start over next time
								_qstop; _st="" ;;
						esac
					fi
					_um=$(_kv "$_d" utcms)
					[ -n "$_um" ] && _d="$_d
utc=$(date -u -d "@$((_um / 1000))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
				fi
			fi
		elif [ "$(_kv "$_c" loc)" = at ]; then
			_src=at
			if [ "$_st" != off ]; then
				case "$_fam" in
					quectel) _d=$(_at 'AT+QGPSLOC=2' | gnss_parse_at quectel) ;;
					telit)   _d=$(_at 'AT$GPSACP' | gnss_parse_at telit) ;;
					simcom)  _d=$(_at 'AT+CGPSINFO' | gnss_parse_at simcom) ;;
					meig)    _d=$(_at 'AT+GPSLOC' | gnss_parse_at meig) ;;
				esac
			fi
		elif [ "$_fam:${_vp%%:*}" = fibocom:0e8d ]; then
			# the receiver was switched on here and the modem turned it off by itself: on again,
			# at most once a minute, so a module that refuses is not asked on every poll
			_fr="$TD/gnss_fmrevive_$_K"
			# switched on before this check existed (or from the AT console): remember it now
			[ "$_st" = on ] && ! _qwant && _qwant_set 1
			if [ "$_st" = off ] && _qwant && [ -n "$_atp" ] \
			   && { [ ! -f "$_fr" ] || [ -n "$(find "$_fr" -mmin +0 2>/dev/null)" ]; }; then
				: > "$_fr"
				if _fibo_on; then
					_st=on
					logger -t 5gmodem "gps: the modem switched the receiver off (GTGPSPOWER 0), switched it back on"
				else
					logger -t 5gmodem "gps: the modem switched the receiver off and refused to switch it back on"
				fi
			fi
			# never hunt for an NMEA port here: the other ttys are AT/debug ports of the same module,
			# and a raw read without the lock would eat answers meant for other pollers
			if [ "$_st" = on ] && _d=$(_fm_urc_read 2 | gnss_parse_nmea) && [ "$(_kv "$_d" fix)" != "" ]; then
				_src=nmea; _port="$_atp"
			else
				_d=""
			fi
		elif [ "$_st" != off ] && _port=$(_nmea_port); then
			_src=nmea
			_d=$(_nmea_read "$_port" 2 | gnss_parse_nmea)
			[ "$_fam" = sierra ] && [ -n "$_d" ] && _st=on
		fi
	fi
	_out=$(_json "$_c" "$_d" "$_st" "$_src" "$_port")
	printf '%s\n' "$_out" > "$LAST"
	rmdir "$_lk" 2>/dev/null
	printf '%s\n' "$_out"
}

# FM350 (0e8d) gives NMEA only as "+ELCSNMEA: \"$G...\"" lines on its GNSS AT port, which is
# also an AT port the app may poll. The output is switched on (MTK AT+ELCSNMEACFG=1: every
# sentence; AT+GTCFGNMEA=1 left only $GNACCURACY after a power cycle) only for the read
# and off again, under the port lock, so the stream never lands in another command's answer.
_fm_urc_read() {
	[ -n "$_atp" ] || return 1
	command -v at_lock >/dev/null 2>&1 || . "$RES/atlock.sh" 2>/dev/null
	at_lock "$_atp" 10 || return 1
	_at 'AT+ELCSNMEACFG=1' >/dev/null
	_fu_o=$(mktemp "$TD/nmea.XXXXXX" 2>/dev/null) || { _at 'AT+ELCSNMEACFG=0' >/dev/null; at_unlock; return 1; }
	# raw, no echo: in the default line mode the tty would echo the +ELCSNMEA lines back to the modem
	stty -F "$_atp" raw -echo 2>/dev/null
	dd if="$_atp" of="$_fu_o" bs=256 count=256 </dev/null 2>/dev/null &
	_fu_p=$!
	sleep "${1:-2}"
	kill "$_fu_p" 2>/dev/null; wait "$_fu_p" 2>/dev/null
	_at 'AT+ELCSNMEACFG=0' >/dev/null
	at_unlock
	# +ELCSLOC (the ready position) goes along as a "$PELCSLOC," line for gnss_parse_nmea
	tr -d '\r' < "$_fu_o" | sed -n -e 's/^+ELCSNMEA: *"\(\$G[^"]*\)".*/\1/p' -e 's/^+ELCSLOC: */$PELCSLOC,/p' | tail -n 60
	rm -f "$_fu_o"
}

_reply() { printf '{"ok":%s,"msg":%s}\n' "$1" "$(_str "$2")"; }

# the answer with its final OK/ERROR line (plain sms_tool output has neither)
_at_raw() { AT_QUERY_RAW=1; _ar_o=$(_at "$1" "${2:-10}"); AT_QUERY_RAW=""; printf '%s\n' "$_ar_o"; }
_send_ok() { _at_raw "$1" | grep -q '^OK'; }

_fibo_on() {
	_at 'AT+GTGPSSWITCH?' | grep -q 'GTGPSSWITCH: *0' && _send_ok 'AT+GTGPSSWITCH=1'
	# FM350 builds ship GNSS_CFG_ENABLE=false in the modem's gnss_adpd.conf: GTGPSPOWER=1 is
	# then refused ("gnss feature disabled") until the MTK AT+ELCSGNSSENABLE=1 turns it on
	_send_ok 'AT+GTGPSPOWER=1' || { _at 'AT+ELCSGNSSENABLE=1' >/dev/null; _send_ok 'AT+GTGPSPOWER=1'; } || false
	_fo_rc=$?
	# NMEA comes as URCs on this AT port: keep them off between reads (_fm_urc_read)
	[ "${_vp%%:*}" = 0e8d ] && _at 'AT+ELCSNMEACFG=0' >/dev/null
	[ "$_fo_rc" = 0 ]
}

_power() {
	_c=$(_caps); _use_gnss_atp "$_c"; _fam=$(_kv "$_c" fam)
	[ "$(_kv "$_c" sup)" = 1 ] || { _reply 0 "not supported"; return; }
	rm -f "$LAST"
	if [ "$(_kv "$_c" loc)" = android ]; then
		[ "$1" = on ] && _v=1 || _v=0
		uci -q set "5gmodem.$_sec.gps_on=$_v" && uci -q commit 5gmodem
		rm -f "$TD/gnss_awl_$_K"
		if [ "$_v" = 1 ]; then _android_wl add; else _android_wl del; fi
		_reply 1 "$1"; return
	fi
	if [ "$(_kv "$_c" loc)" = mm ]; then
		# the choice is kept like the QMI session: the next poll after a restart enables it again
		if [ "$1" = on ]; then _qwant_set 1; else _qwant_set 0; fi
		rm -f "$CAPS"
		_mm_setup "$1" && _reply 1 "$1" || _reply 0 "modem refused"
		return
	fi
	if [ "$(_kv "$_c" loc)" = qmi ] && ! { [ "$_fam:$1" = foxconn:on ] && [ "$(_kv "$_c" reboot)" = 1 ]; }; then
		if [ "$1" = on ]; then
			case "$(_kv "$_c" lock)" in ''|none) ;; *) _q --loc-set-engine-lock=none >/dev/null; rm -f "$CAPS" ;; esac
			_qwant_set 1
			[ -s "$QCID" ] || _qstart || { _reply 0 "modem refused"; return; }
		else
			# only the session stops: on Foxconn this never sends AT+GPS=0 (a restart, and a boot loop on some firmware)
			_qwant_set 0; _qstop
		fi
		_reply 1 "$1"; return
	fi
	case "$_fam:$1" in
		quectel:on)
			# NMEA output switched off: route it to the USB NMEA port (stored in NVRAM), so ugps,
			# gpsd and the NMEA readers get data; the position here is read with AT+QGPSLOC anyway
			[ "$(_at 'AT+QGPSCFG="outport"' | gnss_parse_outport)" = none ] \
				&& _at 'AT+QGPSCFG="outport","usbnmea"' >/dev/null
			_send_ok 'AT+QGPS=1' || _at 'AT+QGPS?' | grep -q 'QGPS: *1' ;;
		quectel:off) _send_ok 'AT+QGPSEND' ;;
		simcom:on)   _send_ok 'AT+CGPS=1,1' || _at 'AT+CGPS?' | grep -q 'CGPS: *1' ;;
		simcom:off)  _send_ok 'AT+CGPS=0' ;;
		telit:on)    _send_ok 'AT$GPSP=1' ;;
		telit:off)   _send_ok 'AT$GPSP=0' ;;
		# SLM770A takes a bare GPSRUN; SLM820/828 want the NMEA outport and run parameters (luci-app-gpoint)
		meig:on)     _send_ok 'AT+GPSRUN' || { _at 'AT+GPSCFG="outport",1' >/dev/null; _send_ok 'AT+GPSRUN=0,30,100,0,1'; } ;;
		meig:off)    _send_ok 'AT+GPSSTOP' ;;
		fibocom:on)
			# FM350 drops the receiver power on its own now and then: the choice is kept, and the
			# next status poll switches it back on (_status)
			[ "${_vp%%:*}" = 0e8d ] && _qwant_set 1
			_fibo_on ;;
		fibocom:off)
			[ "${_vp%%:*}" = 0e8d ] && _qwant_set 0
			_send_ok 'AT+GTGPSPOWER=0' ;;
		foxconn:on|foxconn:off)
			# the setting is stored in the modem and takes a modem restart; ports come back after it
			[ "$1" = on ] && _v=1 || _v=0
			rm -f "$CAPS" "$TD/gnss_port_$_K"
			logger -t 5gmodem "gps: AT+GPS=$_v, the modem restarts"
			# T77W968 answers "+GPS: Setting success! Module would reboot..." and may restart before "OK"
			_at_raw "AT+GPS=$_v" | grep -qE '^OK|Setting success' ;;
		huawei:on)
			# tracking session (type 1) with unlimited fixes every second, then start;
			# ^WPDGP gives an error when a session already runs
			_at 'AT^WPDST=1' >/dev/null; _at 'AT^WPDFR=65535,1' >/dev/null
			_send_ok 'AT^WPDGP' || _at 'AT^WPINFO?' | grep -q '^\^WPINFO: *[1-9]' ;;
		huawei:off)
			# "+CME ERROR: PD session is in off status" means it is already off
			_at_raw 'AT^WPEND' | grep -qE '^OK|in off status' ;;
		sierra:on|sierra:off)
			_p=$(_nmea_port) || { _reply 0 "no NMEA port"; return; }
			[ "$1" = on ] && _w='$GPS_START' || _w='$GPS_STOP'
			printf '%s\r\n' "$_w" > "$_p" 2>/dev/null ;;
		*) false ;;
	esac
	_rc=$?
	rm -f "$CAPS"
	[ "$_rc" = 0 ] && _reply 1 "$1" || _reply 0 "modem refused"
}

_start() {
	_c=$(_caps); _use_gnss_atp "$_c"; _fam=$(_kv "$_c" fam)
	case " $(_kv "$_c" modes) " in *" $1 "*) ;; *) _reply 0 "mode not supported"; return ;; esac
	rm -f "$LAST"
	if [ "$(_kv "$_c" loc)" = android ]; then
		command -v android_cells_ready >/dev/null 2>&1 || . "$RES/android.sh"
		_as=$(android_cells_ready "$_TGT") \
			&& android_adb -s "$_as" shell 'cmd location providers send-extra-command gps delete_aiding_data' >/dev/null \
			&& _reply 1 "$1" || _reply 0 "phone refused"
		return
	fi
	if [ "$(_kv "$_c" loc)" = qmi ]; then
		_qstop
		_q --loc-delete-assistance-data >/dev/null
		_qwant_set 1
		_qstart && _reply 1 "$1" || _reply 0 "modem refused"
		return
	fi
	case "$_fam" in
		quectel)
			case "$1" in cold) _t=0 ;; warm) _t=2 ;; hot) _t=1 ;; esac
			_at 'AT+QGPSEND' >/dev/null
			_send_ok "AT+QGPSDEL=$_t" && _send_ok 'AT+QGPS=1' ;;
		telit)
			case "$1" in cold) _t=1 ;; warm) _t=2 ;; hot) _t=3 ;; esac
			_at 'AT$GPSP=0' >/dev/null
			_send_ok "AT\$GPSR=$_t" && _send_ok 'AT$GPSP=1' ;;
		fibocom)
			case "$1" in cold) _t=0 ;; warm) _t=1 ;; hot) _t=2 ;; esac
			_at 'AT+GTGPSPOWER=0' >/dev/null
			_send_ok "AT+GTGPSDELAID=$_t" && { _send_ok 'AT+GTGPSPOWER=1' \
				|| { _at 'AT+ELCSGNSSENABLE=1' >/dev/null; _send_ok 'AT+GTGPSPOWER=1'; }; } ;;
		simcom)
			# CGPSCOLD/CGPSHOT start the receiver themselves and need it stopped first
			_at 'AT+CGPS=0' >/dev/null; sleep 2
			case "$1" in cold) _send_ok 'AT+CGPSCOLD' ;; hot) _send_ok 'AT+CGPSHOT' ;; esac ;;
		*) false ;;
	esac
	[ $? = 0 ] && _reply 1 "$1" || _reply 0 "modem refused"
}

# Telit: which connector the GNSS receiver listens on (AT$GPSANTPORT, stored in the modem).
#   1 AUX (diversity) connector, passive   2 GNSS connector, passive (the modem's default)
#   3 GNSS connector, active (DC bias on)  4 the same with high gain (not on every model)
# With the antenna on the other connector the receiver runs and sees no satellite at all.
_antport() {
	_c=$(_caps); _fam=$(_kv "$_c" fam)
	[ "$_fam" = telit ] && [ "$(_kv "$_c" loc)" = at ] || { echo '{"supported":0}'; return; }
	_ap_m=$(_at 'AT$GPSANTPORT=?' | tr -d '\r' | sed -n 's/^\$GPSANTPORT: *(0-\([0-9]\)).*/\1/p' | head -n 1)
	if [ -n "$1" ]; then
		case "$1" in [1-4]) ;; *) _reply 0 "bad value"; return ;; esac
		[ "$1" -le "${_ap_m:-3}" ] || { _reply 0 "bad value"; return; }
		# the receiver is restarted around the change, so the new path is used at once
		_ap_was=$(_at "$(_state_cmd telit)" | gnss_parse_state telit)
		[ "$_ap_was" = on ] && _send_ok 'AT$GPSP=0'
		_send_ok "AT\$GPSANTPORT=$1"; _ap_rc=$?
		[ "$_ap_was" = on ] && _send_ok 'AT$GPSP=1'
		rm -f "$LAST"
		if [ "$_ap_rc" = 0 ]; then _reply 1 "$1"; else _reply 0 "modem refused"; fi
		return
	fi
	_ap_v=$(_at 'AT$GPSANTPORT?' | tr -d '\r' | sed -n 's/^\$GPSANTPORT: *\([0-9]\).*/\1/p' | head -n 1)
	[ -n "$_ap_v" ] || { echo '{"supported":0}'; return; }
	printf '{"supported":1,"value":%s,"max":%s}\n' "$_ap_v" "${_ap_m:-3}"
}

case "$1" in
	status|'') _status ;;
	caps)
		_c=$(_caps_eff)
		printf '{"supported":%s,"family":%s,"source":%s,"modes":%s,"reboot":%s,"outport":%s}\n' "$(_num "$(_kv "$_c" sup)")" \
			"$(_str "$(_kv "$_c" fam)")" "$(_str "$(_kv "$_c" loc)")" "$(_str "$(_kv "$_c" modes)")" \
			"$(_num "$(_kv "$_c" reboot)")" "$(_str "$(_kv "$_c" outport)")" ;;
	on|off) _power "$1" ;;
	antport) _antport "$2" ;;
	start)
		case "$2" in cold|warm|hot) _start "$2" ;; *) _reply 0 "bad mode" ;; esac ;;
	*) echo '{"error":"bad action"}'; exit 1 ;;
esac
