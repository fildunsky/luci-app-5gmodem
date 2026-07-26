#!/bin/sh
# МГНОВЕННОЕ СОХРАНЕНИЕ настроек со страницы «Модем».
#
# ЗАЧЕМ. Простые тумблеры (данные в роуминге, AT-порты debug) раньше жили в
# form.Map и требовали общей кнопки «Сохранить/Применить» внизу страницы: без неё
# uci commit не происходил. Пользователю приходилось переключить тумблер,
# промотать вниз и нажать «Применить». Теперь фронтенд по изменению зовёт этот
# скрипт, и опция сохраняется СРАЗУ.
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ СКРИПТ, а не uci из фронтенда: fs.exec под rpcd проверяется по
# ACL, а давать вебу право на ПРОИЗВОЛЬНЫЙ `uci` небезопасно. Здесь ровно две
# фиксированные команды - их и разрешаем в acl.d.

RES=/usr/share/5gmodem

_sec_for_path() { echo "m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }
_norm01() { [ "$1" = "1" ] && echo 1 || echo 0; }

case "$1" in
# roaming <usb-path> <0|1> - разрешение данных в роуминге. Пишем СТАНДАРТНУЮ опцию
# netifd network.<iface>.allow_roaming (её читают mbim/modemmanager и наш fibocom)
# и передёргиваем интерфейс: решение принимается при дозвоне.
roaming)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 1
	uci -q set "network.$_ifn.allow_roaming=$(_norm01 "$3")"
	uci -q commit network
	ifup "$_ifn" >/dev/null 2>&1
	;;
# atdebug <usb-path> <0|1> - показывать ли AT-порты у веб-модема (HiLink). Секцию
# модема заводим, если её ещё нет (её обычно создаёт resolve).
atdebug)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || uci -q set "5gmodem.$_sec=modem"
	uci -q set "5gmodem.$_sec.at_debug=$(_norm01 "$3")"
	uci -q commit 5gmodem
	;;
*)
	echo "usage: $0 {roaming <path> <0|1>|atdebug <path> <0|1>}" >&2
	exit 1
	;;
esac
exit 0
