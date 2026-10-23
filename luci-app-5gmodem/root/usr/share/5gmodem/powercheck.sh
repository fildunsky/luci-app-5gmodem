#!/bin/sh

RES=/usr/share/5gmodem

PATHS=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null)

TOTAL=0
COUNT=0
SUSPECT=0
WHO=""

for P in $PATHS; do
	D="/sys/bus/usb/devices/$P"
	[ -d "$D" ] || continue
	COUNT=$((COUNT + 1))

	MA=$(cat "$D/bMaxPower" 2>/dev/null | tr -cd '0-9')
	[ -n "$MA" ] && TOTAL=$((TOTAL + MA))

	for I in "$D"/*:*; do
		[ -d "$I" ] || continue
		[ "$(cat "$I/bInterfaceClass" 2>/dev/null)" = "02" ] || continue
		if [ ! -e "$I/driver" ]; then
			SUSPECT=1
			WHO="$WHO $P"
		fi
	done
done

NOW=$(cut -d. -f1 /proc/uptime 2>/dev/null)
KERR=0
if [ -n "$NOW" ]; then
	RECENT=$(dmesg 2>/dev/null \
		| grep -iE "error -71|Cannot enable|over-current" \
		| sed -n 's/^\[ *\([0-9]\{1,\}\)\..*/\1/p' \
		| tail -10 \
		| awk -v now="$NOW" 'now - $1 <= 120 { c++ } END { print c + 0 }')
	if [ "${RECENT:-0}" -gt 0 ]; then
		KERR=1
		SUSPECT=1
	fi
fi

printf '{"modems":%d,"total_ma":%d,"kernel_errors":%d,"suspect":%d,"paths":"%s"}\n' \
	"$COUNT" "$TOTAL" "$KERR" "$SUSPECT" "$(echo $WHO)"
