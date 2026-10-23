#!/bin/sh
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.healwifi_migrated)" = "1" ] && exit 0
uci -q get 5gmodem.health >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.heal_wifi)" = "0" ] && uci -q delete 5gmodem.health.heal_wifi
uci -q set 5gmodem.health.healwifi_migrated='1'
uci -q commit 5gmodem
exit 0
