#!/bin/sh
# Пробы связности клиентских ОС - вон из-под защиты DNS-rebind.
#
# У сотовых операторов (CGNAT + перехват DNS) ответы на проверочные домены
# Windows/Android/Apple регулярно содержат ПРИВАТНЫЕ адреса, и rebind-защита
# dnsmasq их режет. Клиент при этом РАБОТАЕТ, но показывает «без доступа к
# интернету» - постоянно. Волна одинаковых жалоб 03.08.2026 (три пользователя,
# разные операторы: «на роутере инет есть, на клиентах нет», при этом торренты
# у клиента качают): во всех отчётах роутерная сторона исправна, а в rebind-логе
# порезаны именно пробы связности. Проводной WAN этим не страдает - потому
# симптом и выглядит «появился вместе с нашей программой».
#
# Домены принадлежат Microsoft/Google/Apple - исключение их из rebind-защиты
# поверхность атаки не расширяет. Сеем ОДИН раз (маркер rebind_seeded):
# если пользователь исключения удалит - молча не возвращаем.
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
