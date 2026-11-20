#!/bin/sh

cache=/tmp/fg360-status-cache
vendor=/usr/share/fg360-modem
endpoint=127.0.0.1:17171

controls_available() {
	[ -x "$vendor/fg360_modem_lock.sh" ] && [ -x "$vendor/fg360_at_debug.sh" ] &&
		[ -x "$vendor/fg360_control.sh" ]
}

payload() {
	sed -n "s/^+$1:[[:space:]]*//p" | head -1 | tr -d '[:space:]'
}

read_bands() {
	awk -v rat="$2" -v start="$3" '
		match($0, /\+GTACT:[[:space:]]*/) {
			line = substr($0, RSTART + RLENGTH)
			gsub(/[()[:space:]]/, "", line)
			count = split(line, fields, ",")
			for (i = start; i <= count; i++) {
				if (fields[i] !~ /^[0-9]+$/) continue
				code = fields[i] + 0
				band = 0
				if (rat == "lte" && code > 100 && code <= 356) band = code - 100
				if (rat == "nr" && code > 500 && code < 510) band = code - 500
				if (rat == "nr" && code >= 5010 && code <= 5256) band = code - 5000
				if (band > 0) print band
			}
			exit
		}
	' "$1" 2>/dev/null | sort -nu
}

get_mode() {
	local mode
	mode=$(payload GTRAT 2>/dev/null < "$cache/gtrat")
	mode=${mode%%,*}
	case "$mode" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s\n' "$mode"
}

get_5g_mode() {
	case "$(payload E5GOPT 2>/dev/null < "$cache/e5gopt")" in
		3) echo sa ;;
		5) echo nsa ;;
		7) echo sa+nsa ;;
	esac
}

parse_lock() {
	local state="$1" rat="$2"
	printf '%s\n' "$state" | awk -F, -v rat="$rat" '
		$1 == "0" { print "off"; exit 0 }
		$1 == 1 && ($2 == 7 || $2 == 11) && $3 == 0 &&
		$4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ {
			if ($2 == rat) print "cell", $4, $5
			else print "off"
			exit 0
		}
		$1 == 1 { print "off unlockable" }
	'
}

get_cell_lock() {
	local result
	result=$(parse_lock "$(payload EMMCHLCK 2>/dev/null < "$cache/cell_lock")" "$1")
	[ -n "$result" ] || return 1
	controls_available || result="$result readonly"
	printf '%s\n' "$result"
}

terminal_ok() {
	tr -d '\r' | awk 'NF { last = $0 } END { exit last !~ /^[[:space:]]*OK[[:space:]]*$/ }'
}

at() {
	local reply
	reply=$(AT_TCP_TIMEOUT=4 FG360_AT_LOCK_WAIT=0 "$vendor/fg360_at_debug.sh" "$endpoint" "$1") || return 1
	printf '%s\n' "$reply" | terminal_ok || return 1
	printf '%s\n' "$reply"
}

save_readback() {
	[ -d "$cache" ] || return 0
	printf '%s\n' "$2" > "$cache/$1.5gmodem.$$" &&
		mv -f "$cache/$1.5gmodem.$$" "$cache/$1"
}

normalize_bands() {
	local supported="$1" request="$2" band
	if [ "$request" = default ]; then
		[ -n "$supported" ] && printf '%s\n' "$supported"
		return $?
	fi
	[ "${#request}" -le 1024 ] || return 1
	case "$request" in ''|*[!0-9\ ]*) return 1 ;; *[0-9]*) ;; *) return 1 ;; esac
	for band in $request; do
		printf '%s\n' "$supported" | grep -qxF "$band" || { printf '%s\n' "$band"; return 1; }
	done
	printf '%s\n' $request | sort -nu
}

valid_mask() {
	printf '%s\n' "$1" | grep -qxE '[0-9]+,[0-9]*,[0-9]*(,[0-9]+)*'
}

mask_key() {
	printf '%s\n' "$1" | cut -d, -f1-3
	printf '%s\n' "$1" | cut -d, -f4- | tr ',' '\n' | sort -nu
}

change_masks() {
	local reply current caps lte nsa sa nr band tail next applied
	reply=$(at 'AT+GTACT?') || { echo 'current bands unavailable'; return 1; }
	current=$(printf '%s\n' "$reply" | payload GTACT)
	valid_mask "$current" || { echo 'invalid current band mask'; return 1; }
	caps=$(at 'AT+GTACT=?') || { echo 'supported bands unavailable'; return 1; }
	if [ -n "$1" ]; then
		lte=$(normalize_bands "$(printf '%s\n' "$caps" | read_bands - lte 1)" "$1") ||
			{ echo "unsupported LTE band $lte"; return 1; }
	fi
	if [ -n "$2" ]; then
		nsa=$(normalize_bands "$(printf '%s\n' "$caps" | read_bands - nr 1)" "$2") ||
			{ echo "unsupported NR band $nsa"; return 1; }
	fi
	if [ -n "$3" ]; then
		sa=$(normalize_bands "$(printf '%s\n' "$caps" | read_bands - nr 1)" "$3") ||
			{ echo "unsupported NR band $sa"; return 1; }
	fi
	if [ -n "$nsa" ] && [ -n "$sa" ] && [ "$nsa" != "$sa" ]; then
		echo 'SA and NSA use the same NR bands'
		return 1
	fi
	nr=${nsa:-$sa}
	next=$(printf '%s\n' "$current" | cut -d, -f1-3)
	tail=$(printf '%s\n' "$current" | cut -d, -f4-)
	for band in $(printf '%s' "$tail" | tr ',' ' '); do
		[ -z "$lte" ] || [ "$band" -le 100 ] || [ "$band" -gt 356 ] || continue
		if [ -n "$nr" ] && { { [ "$band" -gt 500 ] && [ "$band" -lt 510 ]; } ||
				   { [ "$band" -ge 5010 ] && [ "$band" -le 5256 ]; }; }; then
			continue
		fi
		next="$next,$band"
	done
	for band in $lte; do next="$next,$((100 + band))"; done
	for band in $nr; do
		if [ "$band" -lt 10 ]; then next="$next,$((500 + band))"
		else next="$next,$((5000 + band))"; fi
	done
	[ "$(mask_key "$current")" != "$(mask_key "$next")" ] || { save_readback gtact "$reply"; return 0; }
	at "AT+GTACT=$next" >/dev/null || { echo 'band write rejected'; return 1; }
	sleep 1
	reply=$(at 'AT+GTACT?') || { echo 'band readback unavailable'; return 1; }
	applied=$(printf '%s\n' "$reply" | payload GTACT)
	valid_mask "$applied" && [ "$(mask_key "$applied")" = "$(mask_key "$next")" ] ||
		{ echo 'band readback mismatch'; return 1; }
	save_readback gtact "$reply"
	echo changed
}

change_mode() {
	local command="$1" setting="$2" key="$3" reply current wanted verify
	reply=$(at "AT+$command?") || { echo 'mode unavailable'; return 1; }
	current=$(printf '%s\n' "$reply" | payload "$command")
	case "$command" in
		GTRAT)
			printf '%s\n' "$current" | grep -qxE '[0-9]+(,[0-9]*){0,2}' || return 1
			wanted="$setting${current#"${current%%,*}"}" ;;
		E5GOPT) wanted="$setting" ;;
	esac
	[ "${current%%,*}" != "$setting" ] || { save_readback "$key" "$reply"; return 0; }
	at "AT+$command=$wanted" >/dev/null || { echo 'mode write rejected'; return 1; }
	sleep 1
	reply=$(at "AT+$command?") || { echo 'mode readback unavailable'; return 1; }
	verify=$(printf '%s\n' "$reply" | payload "$command")
	[ "${verify%%,*}" = "$setting" ] || { echo 'mode readback mismatch'; return 1; }
	save_readback "$key" "$reply"
	echo changed
}

change_cell_lock() {
	local rat="$1" state="$2" arfcn="$3" pci="$4" reply wanted
	[ ! -s /data/fg360-traffic/active ] || { echo 'Traffic quota active'; return 1; }
	case "$state" in
		off) wanted=0 ;;
		cell) wanted="1,$rat,0,$arfcn,$pci" ;;
		*) return 1 ;;
	esac
	AT_TCP_TIMEOUT=4 FG360_AT_LOCK_WAIT=0 "$vendor/fg360_control.sh" apply-cell "$endpoint" "AT+EMMCHLCK=$wanted" >/dev/null ||
		{ echo 'cell lock write rejected'; return 1; }
	reply=$(at 'AT+EMMCHLCK?') || { echo 'cell lock readback unavailable'; return 1; }
	state=$(printf '%s\n' "$reply" | payload EMMCHLCK)
	case "$state" in
		"$wanted"|"$wanted",*) ;;
		*) echo 'cell lock readback mismatch'; return 1 ;;
	esac
	save_readback cell_lock "$reply"
	echo changed
}

# EFMAXPWR uses 1/8 dBm and replaces one complete RAT table at a time.
power_table() {
	LC_ALL=C awk -v group="$1" '
		{ gsub(/[[:space:]]/, "") }
		index($0, "+EFMAXPWR:" group ",") == 1 {
			found++
			v = substr($0, length("+EFMAXPWR:" group ",") + 1)
			if (v !~ /^\([0-9,]*\),\([-0-9,]*\)$/) { invalid = 1; next }
			v = substr(v, 2, length(v) - 2)
			split(v, pair, /\),\(/)
			if (pair[1] == "" && pair[2] == "") next
			n = split(pair[1], bands, ",")
			m = split(pair[2], powers, ",")
			if (n != m || n > 64) { invalid = 1; next }
			for (i = 1; i <= n; i++) {
				band = bands[i] + 0
				if (bands[i] !~ /^[0-9]+$/ || band < 1 || band > 1024 || seen[band]++ ||
				    powers[i] !~ /^-?[0-9]+$/ || powers[i] < -32768 || powers[i] > 32767) invalid = 1
			}
		}
		END {
			if (found != 1 || invalid) exit 1
			for (i = 1; i <= n; i++) print bands[i] + 0, powers[i] + 0
		}
	'
}

live_nr_bands() {
	local reply bands
	reply=$(at 'AT+GTCAINFO?')
	bands=$(printf '%s\n' "$reply" | awk -F, '
		function nr(code) {
			if (code !~ /^[0-9]+$/) return
			code = code >= 5010 ? code - 5000 : (code >= 501 && code <= 509 ? code - 500 : 0)
			if (code > 0 && code <= 1024) print code
		}
		{ gsub(/[[:space:]"]/, "") }
		/^PCC:/ { nr(substr($1, 5)) }
		# 1 means configured but deactivated, 2 means activated.
		/^SCC[0-9]+:2,/ { nr($3) }
	' | sort -nu)
	if [ -n "$bands" ]; then
		printf '%s\n' "$bands"
		return
	fi

	# Some firmware returns no carrier rows. Only accept explicitly labelled serving NR from the live cell query.
	reply=$(at 'AT+GTCCINFO?') || return 1
	printf '%s\n' "$reply" | awk -F, '
		/LTE-NR EN-DC service cell:/ { section = "endc"; next }
		/NR service cell:/ { section = "nr"; next }
		/cell:/ { section = ""; next }
		/^[[:space:]]*[0-9]+,/ && (section == "nr" || (section == "endc" && $2 + 0 == 9)) {
			b = (section == "endc" && NF == 13) ? $8 : $9
			gsub(/[[:space:]"]/, "", b)
			if (b !~ /^[0-9]+$/) next
			b = b >= 5010 ? b - 5000 : (b >= 501 && b <= 509 ? b - 500 : 0)
			if (b > 0 && b <= 1024) print b
		}
	' | sort -nu
}

tx_power_json() {
	local reply lte nr wcdma active
	reply=$(at 'AT+EFMAXPWR?') || return 1
	lte=$(printf '%s\n' "$reply" | power_table 4) || return 1
	nr=$(printf '%s\n' "$reply" | power_table 7) || return 1
	wcdma=$(printf '%s\n' "$reply" | power_table 1) || return 1
	active=$(live_nr_bands)
	printf '{"current_nr_bands":[%s],"groups":{' "$(printf '%s\n' "$active" | awk 'NF { printf "%s%d", sep, $1; sep = "," }')"
	printf '"lte":[%s],"nr":[%s],"wcdma":[%s]}}\n' \
		"$(printf '%s\n' "$lte" | power_json_entries)" \
		"$(printf '%s\n' "$nr" | power_json_entries)" \
		"$(printf '%s\n' "$wcdma" | power_json_entries)"
}

power_json_entries() {
	LC_ALL=C awk 'NF { printf "%s{\"band\":%d,\"dbm\":%.3f}", sep, $1, $2/8; sep = "," }'
}

change_tx_power() {
	local band="$1" dbm="$2" reply current desired entries verify
	reply=$(at 'AT+EFMAXPWR?') || { echo 'TX power unavailable'; return 1; }
	current=$(printf '%s\n' "$reply" | power_table 7) || { echo 'Invalid NR power table'; return 1; }
	desired=$(printf '%s\n' "$current" | awk -v band="$band" -v power="$((dbm * 8))" '
		NF && $1 != band { print } END { print band, power }
	' | sort -n)
	entries=$(printf '%s\n' "$desired" | awk '
		{ bands = bands "," $1; powers = powers "," $2 }
		END { if (NR > 64) exit 1; print NR bands powers }
	') || { echo 'NR power table is full'; return 1; }
	if ! live_nr_bands | grep -qxF "$band"; then
		echo 'The NR band is not active'
		return 1
	fi
	[ "$desired" != "$(printf '%s\n' "$current" | sort -n)" ] || return 0
	at "AT+EFMAXPWR=7,$entries,1" >/dev/null || { echo 'TX power write rejected'; return 1; }
	reply=$(at 'AT+EFMAXPWR?') || { echo 'TX power readback unavailable'; return 1; }
	verify=$(printf '%s\n' "$reply" | power_table 7) || { echo 'Invalid NR power readback'; return 1; }
	[ "$desired" = "$(printf '%s\n' "$verify" | sort -n)" ] || { echo 'NR power readback mismatch'; return 1; }
}

locked() {
	case "$1" in
		masks) shift; change_masks "$@" ;;
		gtrat) change_mode GTRAT "$2" gtrat ;;
		e5gopt) change_mode E5GOPT "$2" e5gopt ;;
		cell) shift; change_cell_lock "$@" ;;
		power-read) tx_power_json ;;
		power-write) change_tx_power "$2" "$3" ;;
		*) return 1 ;;
	esac
}

reconnect() {
	local iface
	iface=$(. /usr/share/5gmodem/lib.sh; fg360_native_iface ccci) || return 0
	[ "$(uci -q get "network.$iface.auto")" != 0 ] || return 0
	# netifd takes the same AT lock from its MIPC protocol. Release it before reconnecting.
	( exec 7>&- 8>&- 9>&-
	  "$vendor/fg360_control.sh" reconnect-data "$endpoint" "$iface" ||
		logger -t 5gmodem 'FG360: could not reconnect the MIPC interface' ) >/dev/null 2>&1 </dev/null &
}

write_setting() {
	local result rc
	controls_available || { echo 'Unsupported'; return 1; }
	result=$(FG360_MODEM_LOCK_WAIT=8 "$vendor/fg360_modem_lock.sh" --priority high -- \
		/bin/sh "$0" _locked "$@" 2>&1)
	rc=$?
	if [ "$rc" != 0 ]; then
		printf '%s\n' "$result"
		return "$rc"
	fi
	[ "$result" != changed ] || reconnect
}

set_all() {
	local arg lte nsa sa requested result applied failed item
	for arg in "$@"; do
		case "$arg" in
			lte=?*) lte=${arg#*=} ;;
			nsa=?*) nsa=${arg#*=} ;;
			sa=?*) sa=${arg#*=} ;;
			*) echo 'Unsupported'; return 1 ;;
		esac
	done
	[ -n "$lte$nsa$sa" ] || { echo 'No bands selected'; return 1; }
	[ -z "$lte" ] || requested="$requested lte"
	[ -z "$nsa" ] || requested="$requested nsa"
	[ -z "$sa" ] || requested="$requested sa"
	if result=$(write_setting masks "$lte" "$nsa" "$sa"); then
		for item in $requested; do applied="${applied:+$applied,}\"$item\""; done
	else
		result=$(printf '%s' "$result" | tr -cd 'A-Za-z0-9 .,_()+/-' | cut -c1-100)
		for item in $requested; do
			failed="${failed:+$failed,}{\"what\":\"$item\",\"why\":\"rejected\",\"arg\":\"$result\"}"
		done
	fi
	printf '{"id":"%s","state":"done","takeover":0,"applied":[%s],"failed":[%s]}\n' "$$" "$applied" "$failed"
}

valid_number() {
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	[ "${#1}" -le "${#2}" ] && [ "$1" -le "$2" ]
}

set_cell_lock() {
	local rat="$1"
	shift
	case "$1:$rat" in
		off:*) ;;
		cell:7) valid_number "$2" 262143 && valid_number "$3" 503 || return 1 ;;
		cell:11) valid_number "$2" 3279165 && valid_number "$3" 1007 || return 1 ;;
		*) return 1 ;;
	esac
	write_setting cell "$rat" "$@"
}

case "$1" in
	_locked) shift; locked "$@"; exit $? ;;
	getsupportedbands) read_bands "$cache/gtact_supported" lte 1; exit ;;
	getbands) read_bands "$cache/gtact" lte 4; exit ;;
	getsupportedbands5gnsa|getsupportedbands5gsa) read_bands "$cache/gtact_supported" nr 1; exit ;;
	getbands5gnsa|getbands5gsa) read_bands "$cache/gtact" nr 4; exit ;;
	getcelllock) get_cell_lock 7; exit ;;
	getcelllock5g) get_cell_lock 11; exit ;;
	getmode) get_mode; exit ;;
	getsupportedmodes) printf '20 Auto\n17 LTE/NR\n'; exit ;;
	get5gmode) get_5g_mode; exit ;;
	setmode|setmodelive)
		case "$2" in 17|20) write_setting gtrat "$2"; exit $? ;; *) exit 1 ;; esac ;;
	set5gmode)
		case "$2" in
			full|auto|sa+nsa|7) mode=7 ;;
			sa|3) mode=3 ;;
			nsa|5) mode=5 ;;
			*) exit 1 ;;
		esac
		write_setting e5gopt "$mode"; exit $? ;;
	setcelllock) set_cell_lock 7 "$2" "$3" "$4"; exit $? ;;
	setcelllock5g) set_cell_lock 11 "$2" "$3" "$4"; exit $? ;;
	txpowerjson)
		controls_available || exit 1
		FG360_MODEM_LOCK_WAIT=2 "$vendor/fg360_modem_lock.sh" --priority low -- /bin/sh "$0" _locked power-read
		exit $? ;;
	settxpower)
		valid_number "$2" 1024 && [ "$2" -gt 0 ] && [ "${2#0}" = "$2" ] || exit 1
		case "$3" in 23|26|29) write_setting power-write "$2" "$3"; exit $? ;; *) exit 1 ;; esac ;;
	setbands) [ -n "$2" ] && write_setting masks "$2" "" ""; exit $? ;;
	setbands5gnsa|setbands5gsa) [ -n "$2" ] && write_setting masks "" "$2" ""; exit $? ;;
	setall) shift; set_all "$@"; exit $? ;;
	applyresult) echo '{"state":"none"}'; exit ;;
	json|jsonrefresh|mgmtjson) ;;
	mgmtinfo) echo '{"source":"vendor"}'; exit ;;
	*) exit 1 ;;
esac

. /usr/share/libubox/jshn.sh
json_init
json_add_string modem 'Fibocom FG360'
json_add_boolean fg360 1
json_add_boolean sharednr 1
controls_available || json_add_boolean readonly 1

add_band_lists() {
	local band
	json_add_array "supported$1"
	for band in $2; do
		json_add_object ''
		json_add_int band "$band"
		json_close_object
	done
	json_close_array
	json_add_array "enabled$1"
	for band in $3; do json_add_int '' "$band"; done
	json_close_array
}

lte=$(read_bands "$cache/gtact_supported" lte 1)
nr=$(read_bands "$cache/gtact_supported" nr 1)
selected_lte=$(read_bands "$cache/gtact" lte 4)
selected_nr=$(read_bands "$cache/gtact" nr 4)
add_band_lists '' "$lte" "$selected_lte"
add_band_lists 5gnsa "$nr" "$selected_nr"
add_band_lists 5gsa "$nr" "$selected_nr"
[ -n "$lte$nr" ] || json_add_boolean nobandctl 1
lock_state=$(get_cell_lock 7)
[ -z "$lock_state" ] || json_add_string celllock "$lock_state"
lock_state=$(get_cell_lock 11)
case "$lock_state" in ''|*readonly|*unlockable) ;; *) json_add_string celllock5g "$lock_state" ;; esac
mode5g=$(get_5g_mode)
[ -z "$mode5g" ] || json_add_string mode5g "$mode5g"
currentmode=$(get_mode)
if [ -n "$currentmode" ]; then
	json_add_string currentmode "$currentmode"
	json_add_array modes
	for mode in '20:Auto' '17:LTE/NR'; do
		json_add_object ''
		json_add_string id "${mode%%:*}"
		json_add_string label "${mode#*:}"
		json_close_object
	done
	json_close_array
fi

if [ "$1" = mgmtjson ]; then
	printf '{"source":"vendor","bands":%s}\n' "$(json_dump)"
else
	json_dump
fi
