#!/bin/sh
[ "$(uci -q get 5gmodem.@5gmodem[0].rebind_seeded)" = "1" ] && exit 0
uci -q get dhcp.@dnsmasq[0] >/dev/null || exit 0
_ch=0
for _d in msftncsi.com msftconnecttest.com connectivitycheck.gstatic.com captive.apple.com; do
	uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null | tr ' ' '\n' | grep -qxF "$_d" && continue
	uci add_list dhcp.@dnsmasq[0].rebind_domain="$_d"
	_ch=1
done
[ "$_ch" = 1 ] && { uci commit dhcp; /etc/init.d/dnsmasq restart >/dev/null 2>&1; }
uci -q set 5gmodem.@5gmodem[0].rebind_seeded=1
uci -q commit 5gmodem
exit 0
