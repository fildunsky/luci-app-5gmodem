#!/bin/sh

[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null
RES=/usr/share/5gmodem
CFG=5gmodem

LEDS_DIR="${LEDS_DIR:-/sys/class/leds}"

LED_NAMES=$(uci -q get "$CFG.@5gmodem[0].signal_leds_names")
[ -n "$LED_NAMES" ] || LED_NAMES="white:signal1 white:signal2 white:signal3"

enabled() {
	case "$(uci -q get "$CFG.@5gmodem[0].signal_leds")" in
		0) return 1 ;;
		*) return 0 ;;
	esac
}

INTERVAL=$(uci -q get "$CFG.@5gmodem[0].signal_leds_interval")
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=15 ;; esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

leds_present() {
	for _l in $LED_NAMES; do
		[ -w "$LEDS_DIR/$_l/brightness" ] || return 1
	done
	return 0
}

led_max() {
	_m=$(cat "$LEDS_DIR/$1/max_brightness" 2>/dev/null)
	case "$_m" in ''|*[!0-9]*|0) _m=255 ;; esac
	printf '%s' "$_m"
}

set_leds() {
	_want="$1"; _i=0
	for _l in $LED_NAMES; do
		_i=$((_i + 1))
		if [ "$_i" -le "$_want" ]; then
			printf '%s' "$(led_max "$_l")" > "$LEDS_DIR/$_l/brightness" 2>/dev/null
		else
			printf '0' > "$LEDS_DIR/$_l/brightness" 2>/dev/null
		fi
	done
}

METRIC=$(uci -q get "$CFG.@5gmodem[0].signal_leds_metric")
case "$METRIC" in rsrp|rsrq|sinr|signal) ;; *) METRIC=rsrp ;; esac

leds_for_metric() {
	_v=$(printf '%s' "$1" | sed -n 's/^\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')
	[ -n "$_v" ] || { printf '0'; return; }
	case "${2:-$METRIC}" in
		rsrp)
			if   [ "$_v" -ge -80 ];  then printf '3'
			elif [ "$_v" -ge -100 ]; then printf '2'
			else printf '1'; fi ;;
		rsrq)
			if   [ "$_v" -ge -10 ]; then printf '3'
			elif [ "$_v" -ge -15 ]; then printf '2'
			else printf '1'; fi ;;
		sinr)
			if   [ "$_v" -ge 10 ]; then printf '3'
			elif [ "$_v" -ge 0 ];  then printf '2'
			else printf '1'; fi ;;
		signal)
			if   [ "$_v" -ge 75 ]; then printf '3'
			elif [ "$_v" -ge 45 ]; then printf '2'
			elif [ "$_v" -ge 1 ];  then printf '1'
			else printf '0'; fi ;;
	esac
}

update_once() {
	_j=$(SW_BG=1 "$RES/5gmodem.sh" cached $((INTERVAL + 5)) 2>/dev/null)
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)

	case "$_reg" in
		1|5) : ;;
		*) set_leds 0; return ;;
	esac

	_val=$(printf '%s' "$_j" | jsonfilter -e "@.$METRIC" 2>/dev/null)
	_n=$(leds_for_metric "$_val")
	if [ "$_n" = 0 ] && [ "$METRIC" != signal ]; then
		_val=$(printf '%s' "$_j" | jsonfilter -e '@.signal' 2>/dev/null)
		_n=$(leds_for_metric "$_val" signal)
	fi
	set_leds "$_n"
}

case "$1" in
detect)
	if leds_present; then
		printf '{"available":1,"leds":"%s"}\n' "$LED_NAMES"
	else
		printf '{"available":0}\n'
	fi
	;;
once)
	leds_present || { printf '{"error":"no leds"}\n'; exit 0; }
	update_once
	;;
off)
	leds_present && set_leds 0
	;;
metric)
	case "$2" in
		rsrp|rsrq|sinr|signal)
			uci -q set "$CFG.@5gmodem[0].signal_leds_metric=$2"
			uci -q commit "$CFG"
			/etc/init.d/5gmodem-leds restart >/dev/null 2>&1
			printf '{"metric":"%s"}\n' "$2"
			;;
		*) printf '{"error":"bad metric"}\n' ;;
	esac
	;;
enable|disable)
	[ "$1" = "enable" ] && _v=1 || _v=0
	uci -q set "$CFG.@5gmodem[0].signal_leds=$_v"
	uci -q commit "$CFG"
	if [ "$_v" = 1 ]; then
		/etc/init.d/5gmodem-leds enable >/dev/null 2>&1
		/etc/init.d/5gmodem-leds restart >/dev/null 2>&1
	else
		/etc/init.d/5gmodem-leds stop >/dev/null 2>&1
		/etc/init.d/5gmodem-leds disable >/dev/null 2>&1
	fi
	printf '{"signal_leds":%s}\n' "$_v"
	;;
run)
	leds_present || exit 0
	enabled || exit 0
	while :; do
		update_once
		sleep "$INTERVAL"
	done
	;;
*)
	echo "usage: $0 detect|once|off|run|metric <rsrp|rsrq|sinr|signal>|enable|disable" >&2
	exit 1
	;;
esac
exit 0
