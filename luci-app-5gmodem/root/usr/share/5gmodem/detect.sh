#!/bin/sh

#
# (c) 2023-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2023-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#

. /usr/share/5gmodem/lib.sh 2>/dev/null
. /usr/share/5gmodem/notmodem.sh 2>/dev/null
_dt_am=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$_dt_am" ]; then
	_dt_sec="m_$(echo "$_dt_am" | sed 's/[^A-Za-z0-9]/_/g')"
	_dt_p=$(uci -q get "5gmodem.$_dt_sec.at_port")
	if [ "$(uci -q get "5gmodem.$_dt_sec.kind")" = "hilink" ]; then
		[ -n "$_dt_p" ] && [ -c "$_dt_p" ] && { echo "$_dt_p"; exit 0; }
		exit 0
	fi
	_dt_nif=$(uci -q get "5gmodem.$_dt_sec.network")
	if proto_in mm "$(uci -q get "network.$_dt_nif.proto" 2>/dev/null)"; then
		. /usr/share/5gmodem/quirks.sh 2>/dev/null
		mm_at_allowed "$_dt_am" "$_dt_sec" || exit 0
		[ -n "$MM_AT_PORT" ] && { echo "$MM_AT_PORT"; exit 0; }
	fi
fi

_dev_ok() {
	if ! tty_poll_unsafe "$1" && ! poll_send_settle "$_dt_am" "$1"; then return 0; fi
	if exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
		uci -q delete 5gmodem.@5gmodem[0].device
		uci -q delete 5gmodem.@5gmodem[0].at_port
		uci -q commit 5gmodem 2>/dev/null
		flock -u 6
	fi
	return 1
}

CONFIG=modemdefine
MODEMZ=0
[ -f /etc/config/$CONFIG ] && MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [ -n "$MODEMZ" ]; then

	if [ "$MODEMZ" -eq 0 ]; then
    		DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
		if [ -n "$DEVICE" ] && _dev_ok "$DEVICE"; then
			echo $DEVICE
			exit 0
		fi
    	fi

	if [ "$MODEMZ" -eq 1 ]; then
    		DEVICE=$(uci -q get modemdefine.@modemdefine[0].comm_port)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi

	if [ "$MODEMZ" -gt 1 ]; then
		DEVICE=$(uci -q get modemdefine.@general[0].main_modem)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi
fi

getdevicepath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		echo ${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
		echo ${devpath%/*}
		;;
	esac
}

DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
if [ -n "$DEVICE" ] && _dev_ok "$DEVICE"; then
	echo $DEVICE
	exit 0
fi

AUTO=$(uci -q get 5gmodem.@5gmodem[0].auto_port)
[ "$AUTO" = "0" ] && { echo ""; exit 0; }

tty_belongs() {
	[ -n "$2" ] || return 0
	[ "$(tty_usbpath "$1")" = "$2" ]
}

_sec_port_fix() {
	_spf_s="5gmodem.$(secname "$1").at_port"
	_spf_v=$(uci -q get "$_spf_s")
	[ "$_spf_v" = "$2" ] && return 0
	[ -z "$_spf_v" ] || tty_poll_unsafe "$_spf_v" || return 0
	uci -q set "$_spf_s=$2"
}

ACTP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
_ACTM=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$ACTP" ] && [ -c "$ACTP" ] && tty_belongs "$ACTP" "$_ACTM" && ! tty_poll_unsafe "$ACTP" && ! poll_send_settle "$_ACTM" "$ACTP"; then
	_dt_sp=""
	[ -n "$_ACTM" ] && _dt_sp=$(uci -q get "5gmodem.$(secname "$_ACTM").at_port")
	if [ -n "$_ACTM" ] && [ "$_dt_sp" != "$ACTP" ] && { [ -z "$_dt_sp" ] || tty_poll_unsafe "$_dt_sp"; } \
	   && exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
		_sec_port_fix "$_ACTM" "$ACTP"
		uci -q commit 5gmodem 2>/dev/null
		flock -u 6
	fi
	echo "$ACTP"
	exit 0
fi
if [ -n "$ACTP" ] && [ -c "$ACTP" ]; then
	if exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
		uci -q delete 5gmodem.@5gmodem[0].at_port
		uci -q commit 5gmodem 2>/dev/null
		flock -u 6
	fi
fi
AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$AMP" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
	ATCACHE="/tmp/5gmodem/atport_$(echo "$AMP" | tr -c 'A-Za-z0-9' '_')"
	CP=$(cat "$ATCACHE" 2>/dev/null)
	if [ -n "$CP" ] && [ -c "$CP" ] && tty_belongs "$CP" "$AMP" && ! tty_poll_unsafe "$CP" && ! poll_send_settle "$AMP" "$CP"; then
		echo "$CP"
		exit 0
	fi
	[ -n "$CP" ] && rm -f "$ATCACHE" 2>/dev/null
	NEG="$ATCACHE.neg"
	_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	if [ -f "$NEG" ] && [ -n "$_now" ]; then
		_na=$(cat "$NEG" 2>/dev/null); case "$_na" in ''|*[!0-9]*) _na=0 ;; esac
		[ $((_now - _na)) -ge 0 ] && [ $((_now - _na)) -lt 20 ] && { echo ""; exit 0; }
	fi
	exec 7>"/tmp/5gmodem/detect.lock" 2>/dev/null
	flock -n 7 2>/dev/null || { echo ""; exit 0; }
	ALLT=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$AMP\"].tty[*]" 2>/dev/null)
	TTYS=$(drop_dial_port "$AMP" $ALLT)
	SENDT=""
	for T in $ALLT; do tty_poll_unsafe "$T" && SENDT="$SENDT $T"; done
	for MODE in model send at; do
		LIST=$TTYS
		[ "$MODE" = send ] && LIST=$SENDT
		for T in $LIST; do
			case "$MODE" in
				at) /usr/share/5gmodem/atprobe.sh "$T" || continue ;;
				*) /usr/share/5gmodem/atprobe.sh "$T" model || continue ;;
			esac
			[ "$MODE" = send ] && poll_send_mark "$AMP"
			rm -f "$NEG" 2>/dev/null
			echo "$T" > "$ATCACHE"
			[ "$(uci -q get 5gmodem.@5gmodem[0].at_port)" = "$T" ] || {
				if exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
					uci -q set 5gmodem.@5gmodem[0].at_port="$T"
					_sec_port_fix "$AMP" "$T"
					uci -q commit 5gmodem 2>/dev/null
					flock -u 6
				fi
			}
			echo "$T"
			exit 0
		done
	done
	[ -n "$_now" ] && echo "$_now" > "$NEG" 2>/dev/null
	echo ""
	exit 0
fi

MODEMFILE=/tmp/5gmodem/modem
touch $MODEMFILE
DEVICE=$(cat $MODEMFILE)
if [ -n "$DEVICE" ]; then
	echo $DEVICE
	exit 0
fi

DEVICES=$(find /dev -name "ttyUSB*" -o -name "ttyACM*" -o -name "wwan*at*" | sort -r)
WAN=$(uci -q get network.wan.device)
if [ -e "$WAN" ]; then
	DEVPATH=$(getdevicepath "$WAN")
	DEVICESFOUND=""
	for DEVICE in $DEVICES; do
		T=$(getdevicepath $DEVICE)
		[ "x$T" = "x$DEVPATH" ] && DEVICESFOUND="$DEVICESFOUND $DEVICE"
	done
	DEVICES="$DEVICESFOUND"
fi

for DEVICE in $DEVICES; do
	_dp=$(tty_usbpath "$DEVICE" 2>/dev/null)
	if [ -n "$_dp" ] && command -v usb_is_modem >/dev/null 2>&1 \
	   && ! usb_is_modem "/sys/bus/usb/devices/$_dp"; then
		continue
	fi
	if /usr/share/5gmodem/atprobe.sh "$DEVICE"; then
		echo "$DEVICE" | tee $MODEMFILE
		exit 0
	fi
done

echo ""
exit 0
