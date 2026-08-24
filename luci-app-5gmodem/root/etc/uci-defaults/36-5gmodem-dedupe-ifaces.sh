#!/bin/sh
# Разовая уборка (24.08.2026): интерфейсы-дубли на одной сетевой карте модема.
# Их наплодил свисток с рандомизатором IMEI (см. dedupe-ifaces в
# modemswitch.sh): каждый новый IMEI выглядел новым модемом. Причину закрыл
# якорь по MAC, здесь убираем уже накопившееся - один раз, с маркером.
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.@5gmodem[0].ifdedupe_done)" = "1" ] && exit 0
/usr/share/5gmodem/modemswitch.sh dedupe-ifaces >/dev/null 2>&1
uci -q set 5gmodem.@5gmodem[0].ifdedupe_done='1'
uci -q commit 5gmodem
exit 0
