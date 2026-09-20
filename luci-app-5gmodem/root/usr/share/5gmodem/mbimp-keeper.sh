#!/bin/sh

DEV="$1"
IFACE="$2"
USBDEV="$3"
MM_SYNC_AT=$(( $(cut -d. -f1 /proc/uptime) - 120 ))
PERIOD=20
FAILS=0

[ -c "$DEV" ] || exit 1

probe() {
	_kp_o="/tmp/mbimp-keeper.$$.out"
	mbimcli -p -d "$DEV" --query-connection-state=0 > "$_kp_o" 2>&1 </dev/null &
	_kp_p=$!
	_kp_n=0
	while kill -0 "$_kp_p" 2>/dev/null && [ "$_kp_n" -lt 15 ]; do
		sleep 1; _kp_n=$((_kp_n + 1))
	done
	kill -9 "$_kp_p" 2>/dev/null
	wait "$_kp_p" 2>/dev/null
	_kp_r=1
	grep -q "Activation state: 'activated'" "$_kp_o" 2>/dev/null && _kp_r=0
	rm -f "$_kp_o"
	return $_kp_r
}

mm_report() {
	for _mr_n in "$USBDEV":*/usbmisc/cdc-wdm*; do
		[ -e "$_mr_n" ] && mmcli --report-kernel-event="action=$1,subsystem=usbmisc,name=${_mr_n##*/}" >/dev/null 2>&1
	done
	[ "$1" = add ] && sleep 2
	for _mr_n in "$USBDEV":*/net/*; do
		[ -e "$_mr_n" ] && mmcli --report-kernel-event="action=$1,subsystem=net,name=${_mr_n##*/}" >/dev/null 2>&1
	done
	for _mr_n in "$USBDEV":*/ttyUSB* "$USBDEV":*/tty/ttyUSB* "$USBDEV":*/tty/ttyACM*; do
		[ -e "$_mr_n" ] && mmcli --report-kernel-event="action=$1,subsystem=tty,name=${_mr_n##*/}" >/dev/null 2>&1
	done
}

mm_enable() {
	command -v mmcli >/dev/null 2>&1 || return 0
	pidof ModemManager >/dev/null 2>&1 || return 0
	_me_p=$(uci -q get "network.$IFACE.modem_path")
	[ -n "$_me_p" ] || return 0
	_me_now=$(cut -d. -f1 /proc/uptime)
	_me_i=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_me_p" 2>/dev/null)
	case "$_me_i" in
		''|*[!0-9]*)
			if [ -n "$USBDEV" ] && [ "$(( _me_now - MM_SYNC_AT ))" -ge 120 ]; then
				MM_SYNC_AT=$_me_now
				mm_report add
			fi
			return 0 ;;
	esac
	_me_k=$(mmcli -m "$_me_i" -K 2>/dev/null)
	if [ -n "$USBDEV" ] && ! printf '%s\n' "$_me_k" | grep -qE '^modem\.generic\.ports\.value\[[0-9]+\] *: *[A-Za-z0-9-]+ \(mbim\)'; then
		if [ "$(( _me_now - MM_SYNC_AT ))" -ge 300 ]; then
			MM_SYNC_AT=$_me_now
			logger -t 5gmodem "mbimp: ModemManager assembled $_me_p without its MBIM port - re-reporting the ports (the data session is not touched)"
			mm_report remove
			sleep 4
			mm_report add
		fi
		return 0
	fi
	_me_s=$(printf '%s\n' "$_me_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -n 1)
	[ "$_me_s" = "disabled" ] || return 0
	mmcli -m "$_me_i" --enable >/dev/null 2>&1 </dev/null &
	_me_k=$!
	_me_n=0
	while kill -0 "$_me_k" 2>/dev/null && [ "$_me_n" -lt 30 ]; do
		sleep 1; _me_n=$((_me_n + 1))
	done
	kill -9 "$_me_k" 2>/dev/null
	wait "$_me_k" 2>/dev/null
	logger -t 5gmodem "mbimp: enabled modem $_me_p in ModemManager (management only, the data session stays with interface $IFACE)"
}

trap 'rm -f "/tmp/mbimp-keeper.$$.out"; exit 0' TERM INT

while :; do
	sleep "$PERIOD" &
	wait $!
	[ -c "$DEV" ] || { logger -t 5gmodem "mbimp: $DEV is gone - leaving interface $IFACE to netifd"; exit 1; }
	if probe; then
		FAILS=0
		mm_enable
	else
		FAILS=$((FAILS + 1))
		if [ "$FAILS" -ge 2 ]; then
			logger -t 5gmodem "mbimp: the data session on $DEV is no longer active - redialing interface $IFACE"
			exit 1
		fi
	fi
done
