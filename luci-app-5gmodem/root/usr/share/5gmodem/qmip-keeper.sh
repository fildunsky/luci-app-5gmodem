#!/bin/sh

DEV="$1"
IFACE="$2"
CID4="$3"
CID6="$4"
PERIOD=20
FAILS=0
MM_SYNC_AT=$(( $(cut -d. -f1 /proc/uptime) - 120 ))
UNKNOWN=0

[ -c "$DEV" ] || exit 1

probe_cid() {
	case "$1" in ''|0|*[!0-9]*) return 0 ;; esac
	_kp_o="/tmp/qmip-keeper.$$.out"
	qmicli -p -d "$DEV" --wds-get-packet-service-status --client-cid="$1" --client-no-release-cid > "$_kp_o" 2>&1 </dev/null &
	_kp_p=$!
	_kp_n=0
	while kill -0 "$_kp_p" 2>/dev/null && [ "$_kp_n" -lt 15 ]; do
		sleep 1; _kp_n=$((_kp_n + 1))
	done
	kill -9 "$_kp_p" 2>/dev/null
	wait "$_kp_p" 2>/dev/null
	_kp_r=2
	grep -q "Connection status: 'connected'" "$_kp_o" 2>/dev/null && _kp_r=0
	grep -q "Connection status: 'disconnected'" "$_kp_o" 2>/dev/null && _kp_r=1
	rm -f "$_kp_o"
	return $_kp_r
}

probe() {
	case "$CID4" in
		''|0) probe_cid "$CID6" ;;
		*) probe_cid "$CID4" ;;
	esac
}

mm_enable() {
	command -v mmcli >/dev/null 2>&1 || return 0
	pidof ModemManager >/dev/null 2>&1 || return 0
	_me_p=$(uci -q get "network.$IFACE.modem_path")
	[ -n "$_me_p" ] || return 0
	_me_i=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_me_p" 2>/dev/null)
	case "$_me_i" in ''|*[!0-9]*) return 0 ;; esac
	_me_s=$(mmcli -m "$_me_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -n 1)
	[ "$_me_s" = "disabled" ] || return 0
	_me_now=$(cut -d. -f1 /proc/uptime)
	[ "$(( _me_now - MM_SYNC_AT ))" -ge 120 ] || return 0
	MM_SYNC_AT=$_me_now
	mmcli -m "$_me_i" --enable >/dev/null 2>&1 </dev/null &
	_me_k=$!
	_me_n=0
	while kill -0 "$_me_k" 2>/dev/null && [ "$_me_n" -lt 30 ]; do
		sleep 1; _me_n=$((_me_n + 1))
	done
	kill -9 "$_me_k" 2>/dev/null
	wait "$_me_k" 2>/dev/null
	rm -f /tmp/5gmodem_bands_* 2>/dev/null
	logger -t 5gmodem "QMI+MM: enabled modem $_me_p in ModemManager (management only, the data session stays with interface $IFACE)"
}

KICK="/tmp/qmip-keeper.$IFACE.kick"
FAST_UNTIL=0
rm -f "$KICK"

trap 'rm -f "/tmp/qmip-keeper.$$.out" "$KICK"; exit 0' TERM INT

while :; do
	_kl_now=$(cut -d. -f1 /proc/uptime)
	_kl_wait=$PERIOD
	[ "$_kl_now" -lt "$FAST_UNTIL" ] && _kl_wait=3
	_kl_n=0
	while [ "$_kl_n" -lt "$_kl_wait" ]; do
		if [ -e "$KICK" ]; then
			rm -f "$KICK"
			FAST_UNTIL=$(( $(cut -d. -f1 /proc/uptime) + 60 ))
			break
		fi
		sleep 1 &
		wait $!
		_kl_n=$((_kl_n + 1))
	done
	[ -c "$DEV" ] || { logger -t 5gmodem "QMI+MM: $DEV is gone - leaving interface $IFACE to netifd"; exit 1; }
	probe
	case $? in
		0)
			FAILS=0; UNKNOWN=0
			[ "$(cut -d. -f1 /proc/uptime)" -lt "$FAST_UNTIL" ] || mm_enable ;;
		1)
			UNKNOWN=0
			FAILS=$((FAILS + 1))
			if [ "$FAILS" -ge 2 ]; then
				logger -t 5gmodem "QMI+MM: the data session on $DEV is no longer active - redialing interface $IFACE"
				exit 1
			fi ;;
		*)
			UNKNOWN=$((UNKNOWN + 1))
			[ "$UNKNOWN" = 6 ] && logger -t 5gmodem "QMI+MM: $DEV does not answer the session probe for 2 minutes - leaving the session alone" ;;
	esac
done
