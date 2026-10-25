#!/bin/sh

RES=/usr/share/5gmodem
. "$RES/atlock.sh" 2>/dev/null
. "$RES/lib.sh" 2>/dev/null

IF="$1"; PORT="$2"; IP="$3"; IV="$4"
case "$IV" in ''|*[!0-9]*) IV=20 ;; esac
[ "$IV" -ge 5 ] || IV=5

trap 'exit 0' TERM INT

_bad=0
while :; do
	sleep "$IV" &
	wait $!
	[ -c "$PORT" ] || { logger -t 5gmodem "ipwatch: $IF: AT port $PORT is gone - stopping the session"; exit 1; }
	_why=""
	_act=$(at_query "$PORT" "AT+CGACT?" 8 | tr -d '\r' | sed -n 's/^+CGACT: *1, *\([0-9]\).*/\1/p' | head -1)
	case "$_act" in
		0) _why="the network dropped the data session (CGACT=0)" ;;
		1)
			_new=$(at_query "$PORT" "AT+CGPADDR=1" 8 | tr -d '\r' \
				| sed -n 's/.*+CGPADDR: *1,//p' | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9]{1,3}([.][0-9]{1,3}){3}$' | head -1)
			[ -n "$_new" ] && [ "$_new" != "$IP" ] && _why="the network changed the address ($IP -> $_new)"
			;;
	esac
	if [ -z "$_why" ]; then
		_bad=0
		continue
	fi
	_bad=$((_bad + 1))
	[ "$_bad" -ge 2 ] || continue
	logger -t 5gmodem "ipwatch: $IF: $_why - reconnecting"
	exit 1
done
