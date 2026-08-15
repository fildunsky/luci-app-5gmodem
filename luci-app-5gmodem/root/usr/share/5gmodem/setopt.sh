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

. /usr/share/5gmodem/lib.sh 2>/dev/null   # note_foreign_uci
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
	note_foreign_uci network "setopt roaming"
	uci -q set "network.$_ifn.allow_roaming=$(_norm01 "$3")"
	uci -q commit network
	ifup "$_ifn" >/dev/null 2>&1
	;;
# atdebug <usb-path> <0|1> - показывать ли AT-порты у веб-модема (HiLink). Секцию
# модема заводим, если её ещё нет (её обычно создаёт resolve).
atdebug)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	# Секцию заводим С path: без него модем выпадает из «Сохранённых профилей»
	# (modemswitch.sh profiles) и прочих циклов по m_*, которые ищут секции по
	# ключу path. Раньше atdebug создавал её голой (=modem + at_debug), и если он
	# успевал раньше resolve, секция навсегда оставалась без пути.
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$2"
	}
	uci -q set "5gmodem.$_sec.at_debug=$(_norm01 "$3")"
	uci -q commit 5gmodem
	;;
# dnsfb <usb-path> <0|1> [servers] - DNS-фолбэк на интерфейсе модема. Состояние -
# это САМ network.<iface>.dns (отдельного флага нет): вкл + заданные сервера =
# пишем dns, выкл (или пусто) = снимаем. Применяем через network reload, а НЕ
# ifup: смена статического dns подхватывается перечитыванием конфига, дозвон
# рвать незачем (пользователь как раз чинит уже поднятую связь, только без DNS).
# Переезд между пересозданиями интерфейса держит mkiface (OLDDNS).
dnsfb)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 0
	_flag=$(_norm01 "$3")
	shift 3
	_srv="$*"
	note_foreign_uci network "setopt dnsfb"
	if [ "$_flag" = "1" ] && [ -n "$_srv" ]; then
		uci -q set "network.$_ifn.dns=$_srv"
	else
		uci -q delete "network.$_ifn.dns"
	fi
	uci -q commit network
	ubus call network reload >/dev/null 2>&1
	;;
# menuflush - сбросить кэш дерева меню LuCI (/tmp/luci-indexcache*). Нужно после
# смены галочек, которые гейтят вкладки через menu.d depends.uci (align_enabled):
# дерево меню кэшируется по mtime файлов меню, а НЕ по uci, поэтому переключение
# опции сам кэш не подхватывает - вкладка не появляется/не исчезает до ребута.
menuflush)
	rm -f /tmp/luci-indexcache* 2>/dev/null
	;;
*)
	echo "usage: $0 {roaming <path> <0|1>|atdebug <path> <0|1>|dnsfb <path> <0|1>|menuflush}" >&2
	exit 1
	;;
esac
exit 0
