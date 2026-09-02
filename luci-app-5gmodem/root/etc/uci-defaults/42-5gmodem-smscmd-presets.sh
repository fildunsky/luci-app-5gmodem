#!/bin/sh
#
# ГОТОВЫЕ КОМАНДЫ ПО SMS.
#
# Раздел «Команды по SMS» открывался ПУСТЫМ: таблица без единой строки и кнопка
# «+», после которой человек оставался один на один с двумя полями без единой
# подсказки, что в них писать. Самые нужные две команды - перезагрузить роутер и
# передёрнуть питание модема - заводим сами.
#
# ВЫПОЛНЯТЬСЯ ОНИ ПРИ ЭТОМ НЕ НАЧНУТ: весь раздел выключен ключом cmd_enabled, и
# он остаётся выключенным. Это заготовки, а не включённая функция.
#
# ЗАВОДИМ ОДИН РАЗ. Отметка cmd_presets не даёт вернуть команды тому, кто их
# удалил: uci-defaults исполняется при каждом обновлении пакета, и без отметки
# удалённое воскресало бы снова и снова.

[ "$(uci -q get 5gmodem.sms.cmd_presets)" = "1" ] && exit 0

uci -q get 5gmodem.sms >/dev/null 2>&1 || uci -q set 5gmodem.sms=sms

# Только если своих команд нет вовсе - в чужой список не вмешиваемся.
if [ -z "$(uci -q show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\([^.]*\)=smscmd$/\1/p')" ]; then
	# ОТВЕТ ВПЕРЁД, КОМАНДА СЛЕДОМ - отсюда задержка. Обе команды рвут связь
	# (роутер уходит в перезагрузку, у модема пропадает питание), и без задержки
	# ответ уйти просто не успевает.
	_s=$(uci -q add 5gmodem smscmd)
	uci -q set "5gmodem.$_s.keyword=reboot"
	uci -q set "5gmodem.$_s.exec=reboot"
	uci -q set "5gmodem.$_s.answer=1"
	uci -q set "5gmodem.$_s.answer_text=Rebooting the router"
	uci -q set "5gmodem.$_s.delay=10"

	# По питанию, а не AT+CFUN=1,1: питание передёргивает и намертво зависший
	# модем, который на AT уже не отвечает. Плата без такой линии GPIO ничего не
	# сделает - для неё в поле «Что выполнить» меняют power на hard.
	_s=$(uci -q add 5gmodem smscmd)
	uci -q set "5gmodem.$_s.keyword=modem"
	uci -q set "5gmodem.$_s.exec=/usr/share/5gmodem/reboot_modem.sh power"
	uci -q set "5gmodem.$_s.answer=1"
	uci -q set "5gmodem.$_s.answer_text=Power-cycling the modem"
	uci -q set "5gmodem.$_s.delay=10"
fi

uci -q set 5gmodem.sms.cmd_presets=1
uci -q commit 5gmodem

exit 0
