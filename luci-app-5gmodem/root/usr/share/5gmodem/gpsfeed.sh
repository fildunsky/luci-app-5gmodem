#!/bin/sh
# Services fed by the modem GNSS receiver (docs/subsystems/gps-feed.md):
#   gpsfeed.sh tick          from the sessionwatch loop: clock from GNSS, Traccar upload,
#                            keeps the NMEA server in line with gps_nmea_port
#   gpsfeed.sh nmea          status JSON on stdin -> GGA and RMC sentences
#   gpsfeed.sh osmand <id>   status JSON on stdin -> OsmAnd query string for Traccar
#   gpsfeed.sh stream        GGA/RMC once a second to stdout (one per NMEA client)
#   gpsfeed.sh serve         the NMEA TCP server (procd, /etc/init.d/5gmodem-gpsfeed)
#   gpsfeed.sh nmea-ready    exit 0 when the NMEA server can and should run

RES="${GPSFEED_RES:-/usr/share/5gmodem}"
TD="${GPSFEED_TMP:-/tmp/5gmodem}"
INIT="${GPSFEED_INIT:-/etc/init.d/5gmodem-gpsfeed}"

# --- pure helpers (no modem access; covered by tools/issue-regressions/test_gpsfeed.py) ---

_AWK_LIB='
function jv(k,   s, n) {
	n = length(k) + 3
	if (!match(J, "\"" k "\":[^,}]*")) return ""
	s = substr(J, RSTART + n, RLENGTH - n); gsub(/"/, "", s)
	return (s == "null") ? "" : s
}
function isnum(v) { return v ~ /^-?[0-9]+(\.[0-9]+)?$/ }
function days(y, m, d,   a) {
	y -= (m <= 2); a = int(y / 400)
	return a * 146097 + (y - a * 400) * 365 + int((y - a * 400) / 4) - int((y - a * 400) / 100) \
		+ int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1 - 719468
}
function u2e(u) {
	if (u !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/) return ""
	return days(substr(u, 1, 4) + 0, substr(u, 6, 2) + 0, substr(u, 9, 2) + 0) * 86400 \
		+ substr(u, 12, 2) * 3600 + substr(u, 15, 2) * 60 + substr(u, 18, 2)
}
'

_jv() { printf '%s' "$1" | awk -v k="$2" "$_AWK_LIB"'{ J = J $0 } END { print jv(k) }'; }

# UTC "YYYY-MM-DDTHH:MM:SSZ" -> seconds since 1970 (empty when malformed)
utc_epoch() { awk -v u="$1" "$_AWK_LIB"'BEGIN { print u2e(u) }'; }

# seconds since 1970 -> "YYYY-MM-DD hh:mm:ss" (UTC), the form busybox date -s takes
epoch_utc() {
	awk -v e="$1" 'BEGIN {
		if (e !~ /^[0-9]+$/) exit
		z = int(e / 86400) + 719468; s = e % 86400
		era = int(z / 146097); doe = z - era * 146097
		yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
		doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100)); mp = int((5 * doy + 2) / 153)
		d = doy - int((153 * mp + 2) / 5) + 1; m = mp + (mp < 10 ? 3 : -9); y = yoe + era * 400 + (m <= 2)
		printf "%04d-%02d-%02d %02d:%02d:%02d\n", y, m, d, int(s / 3600), int(s % 3600 / 60), s % 60
	}'
}

# status JSON on stdin -> $GPGGA and $GPRMC with checksums, CRLF line ends.
# $1: UTC time to use when the status has none (the receiver gave a position without a clock).
nmea_gen() {
	awk -v now="$1" "$_AWK_LIB"'
	function cs(s,   i, c, x, b, r, p) {
		x = 0
		for (i = 1; i <= length(s); i++) {
			c = ORD[substr(s, i, 1)]; r = 0; p = 1
			for (b = 0; b < 8; b++) {
				if ((int(c / p) % 2) != (int(x / p) % 2)) r += p
				p *= 2
			}
			x = r
		}
		return sprintf("%02X", x)
	}
	function put(s) { printf "$%s*%s\r\n", s, cs(s) }
	function dm(v, w, pos, neg,   a, m, d) {
		a = (v < 0) ? -v : v
		m = int(a * 6000000 + 0.5); d = int(m / 6000000)
		return sprintf("%0" w "d%08.5f,%s", d, (m - d * 6000000) / 100000, (v < 0) ? neg : pos)
	}
	BEGIN { for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i }
	{ J = J $0 }
	END {
		fx = jv("fix"); la = jv("lat"); lo = jv("lon"); u = jv("utc")
		ok = (fx ~ /^[1-9]/ && isnum(la) && isnum(lo))
		if (u2e(u) == "") u = now
		t = ""; d = ""
		if (u2e(u) != "") {
			t = substr(u, 12, 2) substr(u, 15, 2) substr(u, 18, 2) ".00"
			d = substr(u, 9, 2) substr(u, 6, 2) substr(u, 3, 2)
		}
		pos = ok ? dm(la + 0, 2, "N", "S") "," dm(lo + 0, 3, "E", "W") : ",,,"
		sa = jv("sats"); hd = jv("hdop"); al = jv("alt")
		sa = (ok && sa ~ /^[0-9]+$/) ? sprintf("%02d", sa) : ""
		hd = (ok && isnum(hd)) ? sprintf("%.1f", hd) : ""
		al = (ok && isnum(al)) ? sprintf("%.1f", al) : ""
		put("GPGGA," t "," pos "," (ok ? 1 : 0) "," sa "," hd "," al ",M,,M,,")
		sp = jv("speed"); co = jv("course")
		sp = (ok && isnum(sp)) ? sprintf("%.1f", sp / 1.852) : ""
		co = (ok && isnum(co)) ? sprintf("%.1f", co) : ""
		put("GPRMC," t "," (ok ? "A" : "V") "," pos "," sp "," co "," d ",,," (ok ? "A" : "N"))
	}'
}

# status JSON on stdin -> OsmAnd query (Traccar OsmAndProtocolDecoder): speed in knots,
# timestamp in seconds. Nothing is printed without a fix. $2: time to use when the status has none.
osmand_query() {
	awk -v id="$1" -v now="$2" "$_AWK_LIB"'
	{ J = J $0 }
	END {
		fx = jv("fix"); la = jv("lat"); lo = jv("lon")
		if (fx !~ /^[1-9]/ || !isnum(la) || !isnum(lo)) exit 1
		ts = u2e(jv("utc")); if (ts == "") ts = now
		q = "id=" id "&lat=" la "&lon=" lo
		if (ts ~ /^[0-9]+$/) q = q "&timestamp=" ts
		v = jv("alt");    if (isnum(v)) q = q "&altitude=" v
		v = jv("speed");  if (isnum(v)) q = q "&speed=" sprintf("%.1f", v / 1.852)
		v = jv("course"); if (isnum(v)) q = q "&bearing=" v
		v = jv("hdop");   if (isnum(v)) q = q "&hdop=" v
		v = jv("sats");   if (v ~ /^[0-9]+$/) q = q "&sat=" v
		print q
	}'
}

url_ok() {
	printf '%s\n' "$1" | grep -qE '^https?://([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$'
}
id_ok() { printf '%s\n' "$1" | grep -qE '^[A-Za-z0-9._-]{1,64}$'; }
port_ok() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
ip4_ok() { printf '%s\n' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

case "$1" in
	nmea)   nmea_gen "$2"; exit 0 ;;
	osmand) osmand_query "$2" "$3"; exit $? ;;
	utc-epoch) utc_epoch "$2"; exit 0 ;;
	epoch-utc) epoch_utc "$2"; exit 0 ;;
	url-ok) url_ok "$2"; exit $? ;;
	id-ok)  id_ok "$2"; exit $? ;;
esac

# --- configuration: one uci call; with every feature off the tick stops here ---

_CFG=$(uci -q show 5gmodem.@5gmodem[0] 2>/dev/null)
if [ "$1" = tick ]; then
	case "$_CFG" in
		*".gps_time='1'"*|*.gps_traccar_url=*|*.gps_nmea_port=*) ;;
		*) [ -f "$TD/gpsfeed_nmea" ] || exit 0 ;;
	esac
fi
_o() { printf '%s\n' "$_CFG" | sed -n "s/^5gmodem\.[^.]*\.$1='\(.*\)'\$/\1/p" | head -n 1; }

mkdir -p "$TD" 2>/dev/null
_log() { logger -t 5gmodem "gpsfeed: $*"; }
_up() { cut -d. -f1 /proc/uptime 2>/dev/null; }

# the GNSS features follow the GPS tab: off with "Internet priorities only" or show_gps=0
_gps_allowed() { [ "$(_o netonly)" != 1 ] && [ "$(_o show_gps)" != 0 ]; }

# one gps.sh call per tick, shared by the features (sets _ST in the calling shell)
_ST=""; _ST_DONE=""
_status() {
	[ -n "$_ST_DONE" ] || { _ST=$("$RES/gps.sh" status 2>/dev/null); _ST_DONE=1; }
}

# --- clock from GNSS ---

# busybox ntpd reports through /usr/sbin/ntpd-hotplug -> /etc/hotplug.d/ntp/30-5gmodem-ntp,
# which keeps "ACTION stratum uptime" in $TD/ntp_state (gone after a reboot: /tmp)
ntp_synced() {
	_ns=$(cat "$TD/ntp_state" 2>/dev/null) || return 1
	set -- $_ns
	[ "$1" = unsync ] && return 1
	case "$2" in ''|*[!0-9]*) return 1 ;; esac
	[ "$2" -lt 16 ]
}

_time_tick() {
	ntp_synced && return 0
	_tt_now=$(_up); _tt_f="$TD/gpsfeed_time"
	_tt_last=$(sed -n 1p "$_tt_f" 2>/dev/null); _tt_set=$(sed -n 2p "$_tt_f" 2>/dev/null)
	case "$_tt_last" in ''|*[!0-9]*) _tt_last="" ;; esac
	# until the first fix every tick looks; once the clock is set, every 10 minutes
	[ "$_tt_set" = 1 ] && [ -n "$_tt_last" ] && [ $((_tt_now - _tt_last)) -lt 600 ] && return 0
	_status; _tt_s="$_ST"
	case "$(_jv "$_tt_s" fix)" in [1-9]*) ;; *) return 0 ;; esac
	_tt_g=$(utc_epoch "$(_jv "$_tt_s" utc)")
	case "$_tt_g" in ''|*[!0-9]*) return 0 ;; esac
	# the position may come from a cache up to 3 s old: move its time on by the age
	_tt_ts=$(_jv "$_tt_s" ts); _tt_sys=$(date +%s)
	case "$_tt_ts" in ''|*[!0-9]*) ;; *) [ "$_tt_sys" -ge "$_tt_ts" ] && [ $((_tt_sys - _tt_ts)) -le 10 ] && _tt_g=$((_tt_g + _tt_sys - _tt_ts)) ;; esac
	# a receiver after a GPS week rollover reports a date 19.6 years back
	if [ "$_tt_g" -lt 1704067200 ] || [ "$_tt_g" -ge 4102444800 ]; then
		return 0
	fi
	printf '%s\n%s\n' "$_tt_now" "${_tt_set:-0}" > "$_tt_f"
	_tt_d=$((_tt_g - _tt_sys)); _tt_a=${_tt_d#-}
	_tt_lim=5; [ "$_tt_set" = 1 ] && _tt_lim=60
	[ "$_tt_a" -lt "$_tt_lim" ] && { printf '%s\n1\n' "$_tt_now" > "$_tt_f"; return 0; }
	# never more than a year back: a wrong receiver must not drag a sane clock into the past
	if [ "$_tt_d" -lt -31536000 ]; then
		[ -f "$TD/gpsfeed_time_refused" ] || _log "GNSS time $(epoch_utc "$_tt_g") is over a year behind the clock, not set"
		: > "$TD/gpsfeed_time_refused"
		return 0
	fi
	_tt_v=$(epoch_utc "$_tt_g")
	if date -u -s "$_tt_v" >/dev/null 2>&1; then
		_log "clock set from GNSS to $_tt_v UTC (was off by ${_tt_d} s, no NTP sync)"
		printf '%s\n1\n' "$_tt_now" > "$_tt_f"
	fi
}

# --- Traccar (OsmAnd protocol) ---

_http_get() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsS -o /dev/null --connect-timeout 5 -m 8 "$1" 2>/dev/null
	else
		wget -q -O /dev/null -T 8 "$1" 2>/dev/null
	fi
}

_traccar_tick() {
	_tr_u="$1"; _tr_id=$(_o gps_traccar_id); _tr_iv=$(_o gps_traccar_interval)
	_tr_bad="$TD/gpsfeed_traccar_bad"
	if ! url_ok "$_tr_u" || ! id_ok "$_tr_id"; then
		[ -f "$_tr_bad" ] || _log "Traccar: the server address or the device id is not valid, nothing sent"
		: > "$_tr_bad"; return 0
	fi
	rm -f "$_tr_bad"
	case "$_tr_iv" in ''|*[!0-9]*) _tr_iv=60 ;; esac
	[ "$_tr_iv" -lt 30 ] && _tr_iv=30
	_tr_now=$(_up); _tr_f="$TD/gpsfeed_traccar"
	_tr_last=$(sed -n 1p "$_tr_f" 2>/dev/null)
	case "$_tr_last" in ''|*[!0-9]*) ;; *)
		# the loop runs a little over its period: a few seconds of slack keep 60 from becoming 90
		[ "$_tr_now" -ge "$_tr_last" ] && [ $((_tr_now - _tr_last + 5)) -lt "$_tr_iv" ] && return 0 ;;
	esac
	_status
	_tr_q=$(printf '%s' "$_ST" | osmand_query "$_tr_id" "$(date +%s)") || return 0
	[ -n "$_tr_q" ] || return 0
	_tr_was=$(sed -n 2p "$_tr_f" 2>/dev/null)
	case "$_tr_u" in *://*/*) _tr_full="$_tr_u?$_tr_q" ;; *) _tr_full="$_tr_u/?$_tr_q" ;; esac
	if _http_get "$_tr_full"; then _tr_r=ok; else _tr_r=fail; fi
	printf '%s\n%s\n' "$_tr_now" "$_tr_r" > "$_tr_f"
	[ "$_tr_r" = fail ] && [ "$_tr_was" != fail ] && _log "Traccar: the server did not accept the position"
	[ "$_tr_r" = ok ] && [ "$_tr_was" = fail ] && _log "Traccar: sending again"
	return 0
}

# --- NMEA over TCP ---

_nmea_tool() {
	command -v socat >/dev/null 2>&1 && { echo socat; return 0; }
	command -v ncat >/dev/null 2>&1 && { echo ncat; return 0; }
	return 1
}

_nmea_bind() {
	_nb=$(_o gps_nmea_bind)
	if [ -n "$_nb" ]; then ip4_ok "$_nb" && echo "$_nb"; return; fi
	ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null
}

# a listening socket on the port, from /proc/net/tcp (state 0A)
_listening() {
	_lh=$(printf '%04X' "$1")
	awk -v p=":$_lh" '$4 == "0A" && substr($2, length($2) - 4) == p { f = 1 } END { exit !f }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

_nmea_ready() {
	_nr_p=$(_o gps_nmea_port)
	[ -n "$_nr_p" ] || return 1
	_gps_allowed || return 1
	port_ok "$_nr_p" || { _log "NMEA: port '$_nr_p' is not valid"; return 1; }
	_nmea_tool >/dev/null || { _log "NMEA: install socat (or ncat) to serve NMEA on port $_nr_p"; return 1; }
	[ -n "$(_nmea_bind)" ] || { _log "NMEA: no LAN address to listen on"; return 1; }
	return 0
}

_nmea_tick() {
	_nt_p="$1"; _nt_f="$TD/gpsfeed_nmea"
	if [ -z "$_nt_p" ]; then
		[ -f "$_nt_f" ] || return 0
		rm -f "$_nt_f"; "$INIT" stop >/dev/null 2>&1
		return 0
	fi
	if port_ok "$_nt_p" && _listening "$_nt_p"; then
		# remembered, so that clearing the port later stops the server
		[ -f "$_nt_f" ] || _up > "$_nt_f"
		return 0
	fi
	# a changed port, a late LAN or a newly installed socat: try again every 5 minutes
	_nt_now=$(_up); _nt_last=$(sed -n 1p "$_nt_f" 2>/dev/null)
	case "$_nt_last" in ''|*[!0-9]*) ;; *) [ "$_nt_now" -ge "$_nt_last" ] && [ $((_nt_now - _nt_last)) -lt 300 ] && return 0 ;; esac
	printf '%s\n' "$_nt_now" > "$_nt_f"
	"$INIT" restart >/dev/null 2>&1
	return 0
}

_stream() {
	while :; do
		_ST_DONE=""; _status
		printf '%s' "$_ST" | nmea_gen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 0
		sleep 1
	done
}

_serve() {
	_sv_p=$(_o gps_nmea_port); _sv_a=$(_nmea_bind)
	port_ok "$_sv_p" && [ -n "$_sv_a" ] || exit 1
	_sv_me="$RES/gpsfeed.sh"
	case "$(_nmea_tool)" in
		socat) exec socat "TCP-LISTEN:$_sv_p,bind=$_sv_a,reuseaddr,fork,max-children=4" "EXEC:$_sv_me stream" ;;
		ncat)  exec ncat -l -k --max-conns 4 "$_sv_a" "$_sv_p" --sh-exec "$_sv_me stream" ;;
	esac
	exit 1
}

case "$1" in
	tick)
		_t=$(_o gps_time); _u=$(_o gps_traccar_url); _p=$(_o gps_nmea_port)
		_gps_allowed || { _t=""; _u=""; _p=""; }
		[ "$_t" = 1 ] && _time_tick
		[ -n "$_u" ] && _traccar_tick "$_u"
		_nmea_tick "$_p"
		;;
	stream)     _stream ;;
	serve)      _serve ;;
	nmea-ready) _nmea_ready; exit $? ;;
	*) echo "usage: $0 {tick|nmea|osmand|stream|serve|nmea-ready}" >&2; exit 1 ;;
esac
exit 0
