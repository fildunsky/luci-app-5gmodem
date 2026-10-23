#!/bin/sh

LOGTAG=5gmodem
FOXCONN_IDS="413c:81d7 413c:81e0 413c:81e4 413c:81e6 413c:81d8 0489:e0b5 0489:e0b4"

is_foxconn_x20() {
	case " $FOXCONN_IDS " in *" $1 "*) return 0 ;; esac
	return 1
}

send_auth() {
	command -v qmicli >/dev/null 2>&1 || { echo "qmicli is not installed"; return 2; }
	_sa_px=""
	if pidof ModemManager >/dev/null 2>&1 || pidof qmi-proxy >/dev/null 2>&1 || pidof mbim-proxy >/dev/null 2>&1; then
		_sa_px="-p"
	fi
	_sa_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _sa_mb="--device-open-mbim" ;;
	esac
	case "$1" in *mbim*) _sa_mb="--device-open-mbim" ;; esac
	_sa_out="/tmp/5gmodem/fcc.$$"
	qmicli $_sa_px $_sa_mb -d "$1" --dms-foxconn-set-fcc-authentication=0 > "$_sa_out" 2>&1 &
	_sa_p=$!
	_sa_n=0
	while kill -0 "$_sa_p" 2>/dev/null && [ "$_sa_n" -lt "${2:-15}" ]; do
		sleep 1; _sa_n=$((_sa_n + 1))
	done
	kill -9 "$_sa_p" 2>/dev/null
	wait "$_sa_p" 2>/dev/null
	_sa_txt=$(tr '\n' ' ' < "$_sa_out" 2>/dev/null)
	rm -f "$_sa_out"
	echo "$_sa_txt"
	case "$_sa_txt" in
		*[Ss]uccessfully*) return 0 ;;
		*InvalidQmiCommand*|*[Nn]ot\ supported*|*NotSupported*|*InvalidOperation*) return 3 ;;
	esac
	return 1
}

wdm_of_path() {
	for _wp in /sys/bus/usb/devices/"$1":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$1":*/usbmisc/wdm*; do
		[ -e "$_wp" ] && { echo "/dev/${_wp##*/}"; return 0; }
	done
	return 1
}

radio_already_on() {
	_ro_sec=$(secname "$1")
	_ro_if=$(uci -q get "5gmodem.$_ro_sec.network")
	_ro_st=""
	[ -n "$_ro_if" ] && _ro_st=$(ubus call "network.interface.$_ro_if" status 2>/dev/null)
	case "$_ro_st" in
		*'"up": true'*) echo "interface $_ro_if is up"; return 0 ;;
	esac
	_ro_at=$(uci -q get "5gmodem.$_ro_sec.at_port")
	if [ -n "$_ro_at" ] && [ -c "$_ro_at" ] && [ "$(tty_usbpath "$_ro_at")" = "$1" ]; then
		_ro_cf=$(at_query "$_ro_at" "AT+CFUN?" 6 | sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
		[ "$_ro_cf" = 1 ] && { echo "CFUN=1 on $_ro_at"; return 0; }
		[ -n "$_ro_cf" ] && return 1
	fi
	case "$_ro_st" in
		*'"pending": true'*) return 2 ;;
	esac
	pgrep -f "umbim .*cdc-wdm" >/dev/null 2>&1 && return 2
	pgrep -f "uqmi .*cdc-wdm" >/dev/null 2>&1 && return 2
	return 1
}

case "$1" in
kernel)
	. /usr/share/5gmodem/lib.sh
	P="$2"
	[ -n "$P" ] && [ -f "/sys/bus/usb/devices/$P/idVendor" ] || exit 0
	VP="$(cat "/sys/bus/usb/devices/$P/idVendor"):$(cat "/sys/bus/usb/devices/$P/idProduct")"
	is_foxconn_x20 "$VP" || exit 0
	DEVNUM=$(cat "/sys/bus/usb/devices/$P/devnum" 2>/dev/null)
	MARK="/tmp/5gmodem/fcc_$(printf '%s' "$P" | tr -c 'A-Za-z0-9' '_')_$DEVNUM"
	[ -f "$MARK" ] && exit 0
	[ -f "$MARK.run" ] && kill -0 "$(cat "$MARK.run" 2>/dev/null)" 2>/dev/null && exit 0
	for _om in "${MARK%_*}"_[0-9]*; do
		[ -f "$_om" ] || continue
		[ "$_om" = "$MARK" ] && continue
		case "${_om#"${MARK%_*}"_}" in *[!0-9]*) continue ;; esac
		rm -f "$_om" "$_om.run"
	done
	echo $$ > "$MARK.run"
	_try=0
	while [ "$_try" -lt 15 ]; do
		_try=$((_try + 1))
		[ "$(cat "/sys/bus/usb/devices/$P/devnum" 2>/dev/null)" = "$DEVNUM" ] || break
		WHY=$(radio_already_on "$P"); RC=$?
		if [ "$RC" = 0 ]; then
			logger -t "$LOGTAG" "fcc: $VP on $P - radio is already on ($WHY), FCC authentication not needed"
			: > "$MARK"; break
		elif [ "$RC" = 2 ] && [ "$_try" -lt 10 ]; then
			OUT="the connection is being set up"
			sleep 3; continue
		fi
		W=$(wdm_of_path "$P")
		OUT="no control channel (cdc-wdm) found for $P"
		if [ -n "$W" ] && [ -c "$W" ]; then
			OUT=$(send_auth "$W" 15); RC=$?
			if [ "$RC" = 0 ]; then
				logger -t "$LOGTAG" "fcc: $VP on $P - FCC authentication sent via $W (attempt $_try)"
				: > "$MARK"; break
			elif [ "$RC" = 2 ] || [ "$RC" = 3 ]; then
				logger -t "$LOGTAG" "fcc: $VP on $P - not needed or not possible: $OUT"
				: > "$MARK"; break
			fi
		fi
		sleep 3
	done
	[ -f "$MARK" ] || logger -t "$LOGTAG" "fcc: $VP on $P - FCC authentication did not go through after $_try attempts: $OUT"
	rm -f "$MARK.run"
	exit 0
	;;
esac

[ $# -ge 2 ] || exit 1
shift
PORT=""
for _p in "$@"; do
	case "$_p" in
		cdc-wdm*|wdm*|*mbim*|*qmi*) PORT="$_p"; break ;;
	esac
done
[ -n "$PORT" ] || exit 2
OUT=$(send_auth "/dev/$PORT" 4); RC=$?
logger -t "$LOGTAG" "fcc: ModemManager requested FCC unlock on $PORT - rc $RC: $OUT"
[ "$RC" = 3 ] && exit 0
exit $RC
