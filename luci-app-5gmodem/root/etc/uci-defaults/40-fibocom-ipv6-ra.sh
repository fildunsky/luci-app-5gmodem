#!/bin/sh

. /lib/functions.sh

_have=0
check_rule() {
	[ "$(uci -q get "firewall.$1.name")" = "Allow modem RA (fe80::1)" ] && _have=1
}
config_load firewall
config_foreach check_rule rule

[ "$_have" = 1 ] || {
	s=$(uci add firewall rule)
	uci set "firewall.$s.name=Allow modem RA (fe80::1)"
	uci set "firewall.$s.src=wan"
	uci set "firewall.$s.target=ACCEPT"
	uci set "firewall.$s.family=ipv6"
	uci add_list "firewall.$s.proto=icmp"
	uci add_list "firewall.$s.src_ip=fe80::1"
	uci commit firewall
}

exit 0
