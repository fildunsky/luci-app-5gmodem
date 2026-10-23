#!/bin/sh

Z=$(uci show firewall 2>/dev/null \
	| sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
[ -n "$Z" ] || exit 0

case "$(uci -q get "firewall.$Z.network")" in
	*"'"*) : ;;
	*) exit 0 ;;
esac

CUR=$(uci -q get "firewall.$Z.network" | tr -d "'\"")
uci -q delete "firewall.$Z.network"
for N in $CUR; do
	uci -q get "firewall.$Z.network" 2>/dev/null | grep -qw "$N" && continue
	uci add_list "firewall.$Z.network=$N"
done
uci commit firewall
logger -t 5gmodem "wan zone network list was collapsed into a single element - split it back out: $CUR"
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1

exit 0
