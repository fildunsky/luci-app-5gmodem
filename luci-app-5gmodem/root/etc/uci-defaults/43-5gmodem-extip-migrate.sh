#!/bin/sh
#
# ПЕРЕЕЗД НАСТРОЕК СЕРВИСА ВНЕШНЕГО АДРЕСА.
#
# Раньше «чем узнаём свой публичный IP» спрашивалось внутри настроек теста
# скорости (speedtest_ip_url / speedtest_cc_url), а потом то же самое
# понадобилось карточке модема и «Приоритету интернета». Настройка одна и та
# же, поэтому теперь она общая: extip_url / extip_cc_url.
#
# Переносим ОДИН РАЗ и только если на новом месте ещё пусто - чужой выбор
# затирать нельзя. Старые ключи убираем, чтобы в конфиге не осталось двух
# правд об одном и том же (скрипты их всё равно читают как запасные).

_g() { uci -q get "5gmodem.@5gmodem[0].$1"; }

_sect=$(uci -q show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\([^.]*\)=5gmodem$/\1/p' | head -1)
[ -n "$_sect" ] || exit 0

_moved=0
for _pair in "speedtest_ip_url extip_url" "speedtest_cc_url extip_cc_url"; do
	_old="${_pair%% *}"; _new="${_pair##* }"
	_v=$(_g "$_old")
	[ -n "$_v" ] || continue
	[ -n "$(_g "$_new")" ] || { uci -q set "5gmodem.$_sect.$_new=$_v"; _moved=1; }
	uci -q delete "5gmodem.$_sect.$_old" && _moved=1
done

[ "$_moved" = 1 ] && uci -q commit 5gmodem

exit 0
