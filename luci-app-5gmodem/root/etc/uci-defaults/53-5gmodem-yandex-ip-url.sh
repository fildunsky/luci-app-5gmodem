#!/bin/sh

[ -f /etc/config/5gmodem ] || exit 0
for k in extip_url speedtest_ip_url speedtest_ru_ip_url; do
	[ "$(uci -q get "5gmodem.@5gmodem[0].$k")" = "https://yandex.ru/internet/api/v0/ip" ] || continue
	uci -q set "5gmodem.@5gmodem[0].$k=https://ipv4-internet.yandex.net/api/v0/ip"
	_ch=1
done
[ -n "$_ch" ] && uci -q commit 5gmodem
exit 0
