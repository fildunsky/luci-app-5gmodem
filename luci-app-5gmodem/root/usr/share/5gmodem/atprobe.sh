#!/bin/sh

[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null
D="$1"
MODE="$2"
[ -n "$D" ] && [ -c "$D" ] || exit 1
. /usr/share/5gmodem/noatports.sh
tty_no_at "$D" && exit 1

CMD="AT"
[ "$MODE" = "model" ] && CMD="AT+CGMM"

OUT="/tmp/5gmodem/.atprobe.$$"
trap 'rm -f "$OUT" 2>/dev/null' EXIT
trap '[ -n "$p" ] && kill "$p" 2>/dev/null; exit 143' INT TERM HUP
sms_tool -d "$D" at "$CMD" > "$OUT" 2>/dev/null </dev/null 7>&- 8>&- 9>&- &
p=$!
( exec 7>&- 8>&- 9>&-; sleep 2; kill "$p" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
k=$!

if (sleep 0.0) 2>/dev/null; then ts=0.1; tmax=30; else ts=1; tmax=3; fi
i=0
while kill -0 "$p" 2>/dev/null && [ "$i" -lt "$tmax" ]; do i=$((i+1)); sleep "$ts"; done
if kill -0 "$p" 2>/dev/null; then rc=1; else wait "$p" 2>/dev/null; rc=$?; fi

kill "$k" 2>/dev/null
wait "$k" 2>/dev/null

if [ "$MODE" = "model" ]; then
	MODEL=$(tr -s '\r\n' '\n\n' 2>/dev/null < "$OUT" | grep -vE '^AT|^OK$|^ERROR|^\+CME|^$' | head -1)
	rm -f "$OUT"
	[ -n "$MODEL" ] && exit 0 || exit 1
fi

rm -f "$OUT"
exit $rc
