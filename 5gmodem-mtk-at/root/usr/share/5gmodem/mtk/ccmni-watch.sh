#!/bin/sh

. /usr/share/5gmodem/mtk/env.sh
U="$MTK_USOCK"
S="$MTK_SOCK"
IP="$1"
miss=0
n=0
F=/tmp/5gmodem/ccmni-v6-retry

v6_dead() {
	ip -6 addr show dev ccmni0 scope global 2>/dev/null | grep -q inet6 || return 1
	curl -6 -s -k -m 6 -o /dev/null "https://[2a02:6b8::2:242]/" && return 1
	curl -6 -s -k -m 6 -o /dev/null "https://[2a02:6b8::2:242]/" && return 1
	curl -4 -s -m 6 -o /dev/null https://ya.ru
}

while sleep 10; do
	n=$((n + 1))
	if [ "$n" = 6 ] && command -v curl >/dev/null && v6_dead; then
		if [ -z "$(find "$F" -mmin -30 2>/dev/null)" ]; then
			mkdir -p /tmp/5gmodem; : > "$F"
			echo "ccmni: IPv6 passes no traffic, re-attaching"
			$U $S "AT+EFUN=0" 15000 >/dev/null 2>&1
			sleep 3
			$U $S "AT+EFUN=1" 15000 >/dev/null 2>&1
			exit 1
		fi
		echo "ccmni: IPv6 passes no traffic"
	fi
	a=$($U $S "AT+CGATT?" 3000 2>/dev/null | tr -d '\r' | sed -n 's/^+CGATT: *\([0-9]\).*/\1/p' | head -1)
	o=""
	[ "$a" = 1 ] && o=$($U $S "AT+CGPADDR=0" 3000 2>/dev/null | sed -n 's/^+CGPADDR: *0, *"\([0-9.]*\)".*/\1/p' | head -1)
	case "$o" in ''|0.0.0.0)
		miss=$((miss + 1))
		[ "$miss" -ge 3 ] && { echo "ccmni: not attached, restarting"; exit 1; }
		continue ;;
	esac
	miss=0
	[ "$o" = "$IP" ] || { echo "ccmni: address changed $IP -> $o, restarting"; exit 1; }
done
