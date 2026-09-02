#!/bin/sh
# Разовая миграция (19.08.2026): лечение модемов стало включённым по умолчанию
# (health.sh: healing без значения = вкл). Но у большинства установок в конфиге
# лежит ЯВНЫЙ healing='0' - его писала сама модалка сторожа (setconf сохраняет
# все ключи разом при любом изменении), а не осознанный выбор человека. Один
# раз снимаем такой '0', чтобы умолчание применилось; выключенный ПОСЛЕ этой
# миграции '0' - уже воля пользователя, маркер не даёт тронуть его повторно
# (uci-defaults перезапускаются при каждом обновлении пакета).
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.healing_migrated)" = "1" ] && exit 0
uci -q get 5gmodem.health >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.health.healing)" = "0" ] && uci -q delete 5gmodem.health.healing
uci -q set 5gmodem.health.healing_migrated='1'
uci -q commit 5gmodem
exit 0
