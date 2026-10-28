#!/bin/sh

CFG=5gmodem
SD=/tmp/5gmodem/stapark
MARK=parked_by_5gmodem

mkdir -p "$SD" 2>/dev/null

_g() { uci -q get "$CFG.health.$1"; }
_n() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
_now() { cut -d. -f1 /proc/uptime; }
_log() { logger -t 5gmodem "stapark: $*"; }
_rd() { _r=$(cat "$SD/$1" 2>/dev/null); _n "$_r" "$2"; }

sta_secs() {
	uci -q show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.mode='\{0,1\}sta'\{0,1\}\$/\1/p"
}

is_parked() { [ "$(uci -q get "wireless.$1.$MARK")" = 1 ]; }

has_ap() {
	for _ha in $(uci -q show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.device='\{0,1\}$1'\{0,1\}\$/\1/p"); do
		[ "$(uci -q get "wireless.$_ha.mode")" = ap ] || continue
		[ "$(uci -q get "wireless.$_ha.disabled")" = 1 ] && continue
		return 0
	done
	return 1
}

_wst() {
	[ -n "$WST" ] || WST=$(ubus call network.wireless status 2>/dev/null)
	printf '%s' "$WST"
}

ap_ifname() { _wst | jsonfilter -e "@['$1'].interfaces[@.config.mode='ap'].ifname" 2>/dev/null | head -1; }
sta_ifname() { _wst | jsonfilter -e "@['$1'].interfaces[@.section='$2'].ifname" 2>/dev/null | head -1; }

sta_linked() {
	[ -n "$1" ] && iw dev "$1" link 2>/dev/null | grep -q '^Connected'
}

seen() {
	timeout 20 iw dev "$1" scan ap-force 2>/dev/null | awk -v s="$2" -v b="$3" '
		/^BSS / { m = tolower(substr($2, 1, 17)); next }
		/^[ \t]*SSID: / { sub(/^[ \t]*SSID: /, ""); if ($0 == s && (b == "" || m == tolower(b))) f = 1 }
		END { exit !f }'
}

park() {
	uci -q set "wireless.$1.disabled=1"
	uci -q set "wireless.$1.$MARK=1"
	CHANGED=1
}

unpark() {
	uci -q delete "wireless.$1.disabled"
	uci -q delete "wireless.$1.$MARK"
	rm -f "$SD/$1.bad"
	CHANGED=1
}

apply() {
	[ -n "$CHANGED" ] || return 0
	uci -q commit wireless
	ubus call network reload >/dev/null 2>&1
}

tick() {
	WAIT=$(_n "$(_g sta_park_wait)" 30)
	SCAN=$(_n "$(_g sta_park_scan)" 90)
	[ "$SCAN" -ge 30 ] || SCAN=30
	T=$(_now)
	for s in $(sta_secs); do
		r=$(uci -q get "wireless.$s.device")
		[ -n "$r" ] || continue
		if is_parked "$s"; then
			ap=$(ap_ifname "$r")
			if [ -z "$ap" ] || ! has_ap "$r"; then
				_log "$s: no access point on $r any more - enabling the station"
				unpark "$s"; continue
			fi
			[ "$T" -ge "$(_rd "$s.next" 0)" ] || continue
			ssid=$(uci -q get "wireless.$s.ssid")
			[ -n "$ssid" ] || continue
			if seen "$ap" "$ssid" "$(uci -q get "wireless.$s.bssid")"; then
				_log "$s: network $ssid is in range - enabling the station"
				echo "$T" > "$SD/$s.tried"
				unpark "$s"
			else
				echo $((T + SCAN)) > "$SD/$s.next"
			fi
			continue
		fi
		if [ "$(uci -q get "wireless.$s.disabled")" = 1 ] || ! has_ap "$r"; then
			rm -f "$SD/$s.bad" "$SD/$s.tried" "$SD/$s.fails"
			continue
		fi
		if sta_linked "$(sta_ifname "$r" "$s")"; then
			rm -f "$SD/$s.bad" "$SD/$s.tried" "$SD/$s.fails"
			continue
		fi
		b=$(_rd "$s.bad" "")
		if [ -z "$b" ]; then
			echo "$T" > "$SD/$s.bad"
			continue
		fi
		[ $((T - b)) -ge "$WAIT" ] || continue
		f=0
		if [ -f "$SD/$s.tried" ]; then
			f=$(( $(_rd "$s.fails" 0) + 1 ))
			[ "$f" -le 4 ] || f=4
			echo "$f" > "$SD/$s.fails"
		fi
		echo $((T + SCAN * (1 << f))) > "$SD/$s.next"
		rm -f "$SD/$s.tried"
		_log "$s: no link to $(uci -q get "wireless.$s.ssid") for $((T - b)) s - disabling the station so the access point keeps working"
		park "$s"
	done
	apply
}

unpark_all() {
	for s in $(sta_secs); do
		is_parked "$s" || continue
		_log "$s: feature turned off - enabling the station"
		unpark "$s"
	done
	rm -f "$SD"/*
	apply
}

status() {
	_o=""
	for s in $(sta_secs); do
		r=$(uci -q get "wireless.$s.device")
		if is_parked "$s"; then
			st=parked
		elif [ "$(uci -q get "wireless.$s.disabled")" = 1 ]; then
			st=off
		elif sta_linked "$(sta_ifname "$r" "$s")"; then
			st=linked
		else
			st=searching
		fi
		ss=$(uci -q get "wireless.$s.ssid" | sed 's/\\/\\\\/g; s/"/\\"/g')
		_o="$_o${_o:+,}{\"section\":\"$s\",\"ssid\":\"$ss\",\"state\":\"$st\"}"
	done
	printf '{"enabled":%s,"stations":[%s]}\n' "$([ "$(_g sta_park)" = 1 ] && echo true || echo false)" "$_o"
}

case "$1" in
	tick)
		if [ "$(_g sta_park)" = 1 ]; then
			tick
		elif uci -q show wireless 2>/dev/null | grep -q "\.$MARK="; then
			unpark_all
		fi ;;
	off)    unpark_all ;;
	status) status ;;
	*) echo "usage: $0 tick|off|status" >&2; exit 1 ;;
esac
exit 0
