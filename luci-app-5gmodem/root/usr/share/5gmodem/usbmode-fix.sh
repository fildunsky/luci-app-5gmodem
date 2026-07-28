#!/bin/sh
#
# СНЯТИЕ ВРЕДНЫХ ПРАВИЛ usb_modeswitch.
#
# ЗАЧЕМ. В базе /etc/usb-mode.json встречаются записи вида
#   "413c:81d7": { "*": { "msg": [ ], "config": 0 } }
# то есть «перевести устройство в конфигурацию 0». Для модема, который и так
# приходит в рабочей композиции, это РАЗРУШИТЕЛЬНО: конфигурация 0 - это
# «не сконфигурировано», ядро снимает уже привязанные драйверы
# (в логе: «cdc_mbim wwan0: unregister»), а сам usbmode при этом держит
# интерфейс через usbfs («interface 1 claimed by usbfs while 'usbmode' sets
# config #0»), из-за чего cdc_mbim не может привязаться обратно.
#
# Итог у пользователя (Dell DW5821e / Foxconn T77W968, 413c:81d7 на Radxa
# ROCK 5T): cdc-wdm и wwan0 исчезают, остаются только AT-порты, mbim/qmi
# настроить не на чем - «модем застревает на установке соединения», autosetup
# отвечает «не удалось». Само по себе это не проходит: usbmode запускается на
# каждое hotplug-событие и ломает композицию снова.
#
# ЧТО ДЕЛАЕМ. Убираем запись целиком - для этих модемов переключать нечего,
# они и так стартуют в нужной композиции. Файл принадлежит пакету
# usb-modeswitch, поэтому: (1) правим только известные ID, (2) кладём рядом
# резервную копию, (3) действуем идемпотентно - повторный запуск ничего не
# меняет. При обновлении usb-modeswitch запись вернётся, поэтому скрипт
# вызывается и из postinst, и из hotplug при появлении такого модема.
#
# Usage: usbmode-fix.sh [vid:pid]   (без аргумента - проверить весь список)

JSON=/etc/usb-mode.json

# Модемы, которым правило usb_modeswitch ВРЕДИТ. Только проверенное:
#   413c:81d7 - Dell DW5821e / Foxconn T77W968 (Snapdragon X20), отчёт 28.07:
#               config 0 сносит cdc_mbim, модем остаётся без канала данных.
BAD_IDS="413c:81d7"

[ -f "$JSON" ] || exit 0

_fix_one() {   # $1 - vid:pid
	grep -q "\"$1\"" "$JSON" 2>/dev/null || return 1   # записи нет - нечего делать
	[ -f "$JSON.5gmodem-bak" ] || cp "$JSON" "$JSON.5gmodem-bak" 2>/dev/null
	sed -e "/\"$1\": {/,/},/d" "$JSON" > "$JSON.tmp" 2>/dev/null || { rm -f "$JSON.tmp"; return 1; }
	# Правку принимаем ТОЛЬКО если файл остался валидным JSON и не опустел:
	# сломанная база лишила бы modeswitch'а все остальные модемы.
	if [ -s "$JSON.tmp" ] && jsonfilter -i "$JSON.tmp" -e '@.devices' >/dev/null 2>&1; then
		mv "$JSON.tmp" "$JSON"
		logger -t 5gmodem "usb_modeswitch: снято вредное правило для $1 (ломало композицию модема)"
		return 0
	fi
	rm -f "$JSON.tmp"
	return 1
}

_changed=0
for _id in ${1:-$BAD_IDS}; do
	_fix_one "$_id" && _changed=1
done
exit 0
