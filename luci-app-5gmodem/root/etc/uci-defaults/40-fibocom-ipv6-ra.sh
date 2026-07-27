#!/bin/sh
# IPv6 для сотовых модемов на нашем fibocom-протоколе (и ATC): маршрутизируемый
# префикс приходит по Router Advertisement от link-local модема fe80::1. На части
# сетей дефолтного правила Allow-ICMPv6-Input не хватает (замечено на FM350 -
# см. atc.sh), поэтому явно разрешаем ВЕСЬ ICMPv6 от fe80::1 во входящем на wan:
# это и RA, и Neighbor Advertisement шлюза. Идемпотентно - по имени правила.
#
# Правило безвредно и без IPv6-модема: оно лишь ПРИНИМАЕТ ICMPv6 от адреса,
# который в норме есть только у модема на point-to-point линке.

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
