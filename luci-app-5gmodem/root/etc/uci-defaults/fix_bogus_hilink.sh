#!/bin/sh

[ -f /etc/config/5gmodem ] || exit 0

CHANGED=0

for SEC in $(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.\(m_[A-Za-z0-9_]*\)\.kind='hilink'\$/\1/p"); do
	VIDPID=$(uci -q get "5gmodem.$SEC.vidpid")
	[ -n "$VIDPID" ] || continue
	case "$VIDPID" in
		12d1:*|1bbb:0196|19d2:*|15a9:*|1076:8002|0846:68e1) continue ;;
	esac
	uci -q delete "5gmodem.$SEC.kind"
	uci -q delete "5gmodem.$SEC.netdev"
	uci -q delete "5gmodem.$SEC.at_debug"
	logger -t 5gmodem "migration: removed bogus hilink mark from $SEC ($VIDPID)"
	CHANGED=1
done

[ "$CHANGED" = "1" ] && uci -q commit 5gmodem

exit 0
