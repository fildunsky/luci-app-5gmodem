#!/bin/sh
RES=/usr/share/5gmodem
. "$RES/lib.sh" 2>/dev/null

PORT="$1"
CMD="$2"
TMO="${3:-10}"

command -v is_devpath >/dev/null 2>&1 || { echo "lib unavailable" >&2; exit 1; }

if ! is_devpath "$PORT"; then
	logger -t 5gmodem "atcmd: device path rejected"
	echo "bad port" >&2; exit 2
fi
if ! is_atcmd "$CMD"; then
	logger -t 5gmodem "atcmd: command rejected by input validation"
	echo "bad command" >&2; exit 2
fi
case "$TMO" in ''|*[!0-9]*) TMO=10 ;; esac
[ "$TMO" -gt 40 ] && TMO=40

_known=0
for _t in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].tty[*]' 2>/dev/null); do
	[ "$_t" = "$PORT" ] && { _known=1; break; }
done
if [ "$_known" != 1 ]; then
	logger -t 5gmodem "atcmd: port $PORT does not belong to any known modem"
	echo "unknown port" >&2; exit 2
fi

at_query "$PORT" "$CMD" "$TMO" 8
_rc=$?
if [ "$_rc" = 2 ]; then
	logger -t 5gmodem "atcmd: queue for $PORT busy for over 8s - running the user command without it"
	_ac_o=$(mktemp /tmp/5gmodem/atcmd.XXXXXX 2>/dev/null) || _ac_o="/tmp/5gmodem/atcmd.$$"
	sms_tool -d "$PORT" at "$CMD" > "$_ac_o" 2>/dev/null &
	_ac_p=$!
	( sleep "$(( ${TMO:-8} + 1 ))"; kill "$_ac_p" 2>/dev/null ) >/dev/null 2>&1 </dev/null & _ac_k=$!
	sleep_tick_init
	_ac_i=0; _ac_max=$(( (${TMO:-8} + 2) * _TICKS_PER_SEC ))
	while kill -0 "$_ac_p" 2>/dev/null && [ "$_ac_i" -lt "$_ac_max" ]; do
		_ac_i=$((_ac_i + 1)); sleep "$_SLEEP_TICK"
	done
	kill -0 "$_ac_p" 2>/dev/null || wait "$_ac_p" 2>/dev/null
	kill "$_ac_k" 2>/dev/null; wait "$_ac_k" 2>/dev/null
	tr -d '\r' < "$_ac_o"; rm -f "$_ac_o"
fi
exit 0
