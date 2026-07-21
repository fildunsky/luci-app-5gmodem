#!/bin/sh
#
# ЕДИНАЯ точка опознания Compal RXM-G1 (модуль SG500M2-X).
#
# Зачем отдельный файл. Этот модем меняет USB-композицию командой AT+USBCOMP,
# и в КАЖДОЙ композиции у него свой VID:PID, причём почти все они ЧУЖИЕ -
# делятся с Foxconn T99W175 / Thales MV31-W / Dell DW5930e, прошивки которых
# несовместимы с ним по AT-командам:
#
#   AT+USBCOMP=user   MBIM   05c6:90d5 (прототип) | 05c6:90d6 (новый аппарат)
#   AT+USBCOMP=debug  QMI    1e2d:00b7 (прототип) | 05c6:9025 (новый аппарат)
#   AT+USBCOMP=rndis  RNDIS  05c6:9058 (прототип) | 05c6:9025 (новый аппарат)
#
# Раньше проверка «это Compal?» была скопирована по семи местам (профили метрик,
# профили диапазонов, simslot.sh, mkiface.sh), каждое со своим набором признаков.
# Стоило появиться новой композиции - и часть мест про неё не знала: именно так
# в режиме 1e2d:00b7 снова сломалось определение SIM-слотов, хотя для 90d5/90d6
# оно было починено. Поэтому признак теперь один на всех.
#
# ПОЧЕМУ НЕСКОЛЬКО ИСТОЧНИКОВ, а не просто список VID:PID:
#   - список ID недостаточен: 05c6:9025 и 1e2d:00b7 принадлежат и чужим модемам;
#   - USB-дескриптор ("Tri Cascade" / "VOS_5G") различает их, НО у нового
#     аппарата в композиции QMI/RNDIS дескриптор generic - "Qualcomm, Inc.
#     HSUSB Device", и строковая проверка там молча провалилась бы;
#   - поэтому запасной признак - МОДЕЛЬ (SG500M2-X): её отдают и QMI, и MM, и AT.
# Источники опрошены в порядке ЦЕНЫ: sysfs (бесплатно) -> QMI (~25 мс) ->
# ModemManager -> AT (сотни мс, и порт может быть занят опросом метрик).

# is_compal [usb_path] [cdc_wdm] [at_port]
# Все аргументы необязательны - без них проверяются только глобальные признаки.
is_compal() {
	_ic_path="$1"
	_ic_wdm="$2"
	_ic_at="$3"

	# 1) USB-дескриптор. Даром, работает без единого обращения к модему.
	if [ -n "$_ic_path" ] && [ -r "/sys/bus/usb/devices/$_ic_path/product" ]; then
		case "$(cat "/sys/bus/usb/devices/$_ic_path/product" 2>/dev/null)" in
			*VOS_5G*|*RXMG1*) return 0 ;;
		esac
		case "$(cat "/sys/bus/usb/devices/$_ic_path/manufacturer" 2>/dev/null)" in
			*Tri\ Cascade*) return 0 ;;
		esac
	else
		grep -qiE "VOS_5G|RXMG1" /sys/bus/usb/devices/*/product 2>/dev/null && return 0
		grep -qiE "Product=VOS_5G|Manufacturer=Tri Cascade" \
			/sys/kernel/debug/usb/devices 2>/dev/null && return 0
	fi

	# 2) Модель по QMI. Спасает там, где дескриптор generic (HSUSB Device).
	[ -n "$_ic_wdm" ] || _ic_wdm=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
	[ -c "$_ic_wdm" ] || _ic_wdm=/dev/cdc-wdm0
	if [ -c "$_ic_wdm" ] && command -v qmicli >/dev/null 2>&1; then
		qmicli -d "$_ic_wdm" -p --dms-get-model 2>/dev/null \
			| grep -q "SG500M2-X" && return 0
	fi

	# 3) ModemManager - когда интерфейс под MM и модем ему отдан.
	if command -v mmcli >/dev/null 2>&1; then
		_ic_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex 2>/dev/null)
		[ -n "$_ic_mi" ] || _ic_mi=any
		mmcli -m "$_ic_mi" -K 2>/dev/null \
			| grep -qE "RXMG1|SG500M2-X" && return 0
	fi

	# 4) AT - последний рубеж: дороже всего и порт может быть занят.
	if [ -n "$_ic_at" ] && [ -c "$_ic_at" ]; then
		sms_tool -d "$_ic_at" at "AT+CGMM" 2>/dev/null \
			| grep -q "SG500M2-X" && return 0
	fi

	return 1
}

# Вызов как отдельной командой: iscompal.sh [usb_path] [cdc_wdm] [at_port]
# (нужен там, где подключить файл через "." неудобно). Код возврата тот же.
case "$0" in
	*iscompal.sh) is_compal "$@" ;;
esac
