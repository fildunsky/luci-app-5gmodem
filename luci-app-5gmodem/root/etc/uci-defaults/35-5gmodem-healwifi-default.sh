#!/bin/sh
# Разовая миграция (24.08.2026): лечение Wi-Fi-аплинка стало включённым по
# умолчанию (health.sh: heal_wifi без значения = вкл). Как и с healing, у
# большинства установок в конфиге лежит ЯВНЫЙ heal_wifi='0', записанный самой
# модалкой сторожа (setconf сохраняет все ключи разом), а не выбранный
# человеком. Снимаем такой '0' один раз; выключенный ПОСЛЕ миграции - воля
# пользователя, маркер защищает её от повторного снятия.
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.healwifi_migrated)" = "1" ] && exit 0
uci -q get 5gmodem.health >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.heal_wifi)" = "0" ] && uci -q delete 5gmodem.health.heal_wifi
uci -q set 5gmodem.health.healwifi_migrated='1'
uci -q commit 5gmodem
exit 0
