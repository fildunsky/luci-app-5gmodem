#!/bin/sh
# Статистика: включаем сбор на свежей установке (ряды живут в /tmp, флеш не
# трогаем - persist по умолчанию выключен). На апгрейде секцию не трогаем:
# настройку мог менять пользователь.
uci -q get 5gmodem.stats >/dev/null 2>&1 || {
	uci -q set 5gmodem.stats=stats
	uci -q set 5gmodem.stats.enabled=1
	uci -q set 5gmodem.stats.persist=0
	uci -q commit 5gmodem
}
# Вкладка «Статистика» видна по умолчанию (ключ читает menu.d); существующее
# значение не трогаем - его мог снять пользователь.
[ -n "$(uci -q get 5gmodem.@5gmodem[0].show_stats)" ] || {
	uci -q set 5gmodem.@5gmodem[0].show_stats=1
	uci -q commit 5gmodem
}
exit 0
