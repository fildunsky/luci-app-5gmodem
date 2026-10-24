#!/bin/sh

U=/usr/share/5gmodem/mtk/usock-armv7
S=/dev/socket/rild-atci
IP="$1"
miss=0

while sleep 10; do
	a=$($U $S "AT+CGATT?" 3000 2>/dev/null | tr -d '\r' | sed -n 's/^+CGATT: *\([0-9]\).*/\1/p' | head -1)
	o=""
	[ "$a" = 1 ] && o=$($U $S "AT+CGPADDR=0" 3000 2>/dev/null | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)
	case "$o" in ''|0.0.0.0)
		miss=$((miss + 1))
		[ "$miss" -ge 3 ] && { echo "ccmni: not attached, restarting"; exit 1; }
		continue ;;
	esac
	miss=0
	[ "$o" = "$IP" ] || { echo "ccmni: address changed $IP -> $o, restarting"; exit 1; }
done
