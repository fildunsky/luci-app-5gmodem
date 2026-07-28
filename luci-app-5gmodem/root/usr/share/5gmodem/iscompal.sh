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
	# Путь ЗАДАН -> смотрим ТОЛЬКО его узел. Глобальный поиск по всей шине при
	# заданном пути ЗАПРЕЩЁН, даже если узла сейчас нет (переэнумерация): он
	# отвечает про ЧУЖИЕ устройства - отсутствующий Telit засчитывался за
	# Compal по дескриптору соседа (воспроизведено на стенде).
	if [ -n "$_ic_path" ]; then
		if [ -r "/sys/bus/usb/devices/$_ic_path/product" ]; then
			case "$(cat "/sys/bus/usb/devices/$_ic_path/product" 2>/dev/null)" in
				*VOS_5G*|*RXMG1*) return 0 ;;
			esac
			case "$(cat "/sys/bus/usb/devices/$_ic_path/manufacturer" 2>/dev/null)" in
				*Tri\ Cascade*) return 0 ;;
			esac
		fi
	else
		grep -qiE "VOS_5G|RXMG1" /sys/bus/usb/devices/*/product 2>/dev/null && return 0
		grep -qiE "Product=VOS_5G|Manufacturer=Tri Cascade" \
			/sys/kernel/debug/usb/devices 2>/dev/null && return 0
	fi

	# 2) Модель по QMI. Спасает там, где дескриптор generic (HSUSB Device).
	# ЯВНЫЙ wdm ($2) - авторитетный источник в ОБЕ стороны: если КОНКРЕТНЫЙ
	# канал назвал ЧУЖУЮ модель (T99W175 и т.п.) - это НЕ Compal, и дальше не
	# идём. Раньше проверка проваливалась в шаги 3-4 с фолбэками «активный
	# модем»/«any», и на двухмодемном роутере СОСЕДНИЙ Compal засчитывался за
	# этот модем: T99W175 в 9025 уводило в Compal-профиль - без метрик.
	# Фолбэки (wdm активного модема, cdc-wdm0) - ТОЛЬКО когда wdm не передан.
	# Явный, но ИСЧЕЗНУВШИЙ канал (переэнумерация) не подменяем: подмена
	# спрашивала модель у СОСЕДА - отсутствующий Telit отвечал Compal'ом.
	_ic_wdm_explicit="$_ic_wdm"
	if [ -z "$_ic_wdm" ]; then
		_ic_wdm=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
		[ -c "$_ic_wdm" ] || _ic_wdm=/dev/cdc-wdm0
	fi
	if [ -c "$_ic_wdm" ] && command -v qmicli >/dev/null 2>&1; then
		_ic_model=$(qmicli -d "$_ic_wdm" -p --dms-get-model 2>/dev/null \
			| sed -n "s/.*Model: '\{0,1\}\([^']*\)'\{0,1\}.*/\1/p" | head -1)
		case "$_ic_model" in *SG500M2-X*) return 0 ;; esac
		[ -n "$_ic_wdm_explicit" ] && [ -n "$_ic_model" ] && return 1
	fi

	# 3) ModemManager - когда интерфейс под MM и модем ему отдан.
	# При ЯВНОМ пути ($1) ответ засчитываем ТОЛЬКО если MM-модем стоит на ЭТОМ
	# пути: mmindex/any - это «активный»/«какой-нибудь», и на двухмодемном
	# роутере сюда попадал СОСЕДНИЙ Compal (Telit с молчащим QMI засчитывался
	# за Compal - воспроизведено на стенде).
	if command -v mmcli >/dev/null 2>&1; then
		_ic_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex 2>/dev/null)
		[ -n "$_ic_mi" ] || _ic_mi=any
		_ic_mk=$(mmcli -m "$_ic_mi" -K 2>/dev/null)
		if [ -n "$_ic_path" ]; then
			printf '%s\n' "$_ic_mk" | grep -q "modem\.generic\.device .*/$_ic_path\$" || _ic_mk=""
		fi
		printf '%s\n' "$_ic_mk" | grep -qE "RXMG1|SG500M2-X" && return 0
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
