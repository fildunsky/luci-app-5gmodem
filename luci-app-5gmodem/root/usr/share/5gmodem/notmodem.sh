#!/bin/sh
#
# УСТРОЙСТВА, КОТОРЫЕ МОДЕМАМИ НЕ ЯВЛЯЮТСЯ (по vid:pid).
#
# Модем в этой программе опознаётся по портам: всё, что отдаёт ttyUSB/ttyACM/
# cdc-wdm, попадает в список модемов и получает свою вкладку (см. listmodems.sh).
# Правило работает, пока в USB воткнут только модем, - но ttyUSB делает и любой
# переходник USB-UART, а их в роутер втыкают: консоль другой железки, счётчик,
# контроллер. Такой переходник показывался ОТДЕЛЬНЫМ модемом - с вкладкой, с
# попытками опроса по AT и с местом в приоритете интернета (живой случай
# 01.09.2026: WCH CH340 1a86:7523).
#
# Отсюда список известных мостов USB-UART. Это чистые преобразователи: сотовым
# модемом такое устройство быть не может физически, никакого QMI/MBIM/HiLink у
# него нет, а единственный «модем», который к нему подключают, - чужая железка
# на другом конце провода, и говорить с ней должна не наша программа.
#
#   1a86:7522 1a86:7523 CH340/CH341, 1a86:55d3 CH9102/CH343 - WCH (QinHeng)
#   0403:6001 0403:6010 0403:6011 0403:6014 0403:6015       - FTDI FT232/FT2232/FT-X
#   10c4:ea60 10c4:ea70 10c4:ea71                           - Silicon Labs CP210x
#   067b:2303 067b:23a3 067b:23c3                           - Prolific PL2303
#
# ДВЕ РУЧКИ В КОНФИГЕ, обе - списки vid:pid через пробел:
#   5gmodem.@5gmodem[0].ignore_vidpid - добавить своё устройство в исключения;
#   5gmodem.@5gmodem[0].modem_vidpid  - НАОБОРОТ, вернуть устройство из списка
#     выше в модемы. Нужна для отладочной платы, где сотовый модуль подключён к
#     роутеру именно через такой мост и других портов у него нет: список выше
#     тогда прячет настоящий модем.
NOT_MODEM_VIDPIDS="1a86:7522 1a86:7523 1a86:55d3 0403:6001 0403:6010 0403:6011 0403:6014 0403:6015 10c4:ea60 10c4:ea70 10c4:ea71 067b:2303 067b:23a3 067b:23c3"

# Обе ручки читаем ОДИН раз на процесс: is_not_modem зовётся на каждое USB-
# устройство, а listmodems.sh за одну загрузку страницы запускается шесть раз -
# лишний uci здесь стоит дороже самой проверки.
_NM_CFG=""
_nm_cfg() {
	[ -n "$_NM_CFG" ] && return 0
	_NM_CFG=1
	NOT_MODEM_EXTRA=$(uci -q get 5gmodem.@5gmodem[0].ignore_vidpid 2>/dev/null)
	NOT_MODEM_FORCE=$(uci -q get 5gmodem.@5gmodem[0].modem_vidpid 2>/dev/null)
}

# Usage: is_not_modem <vid:pid>   ->  0 = это не модем, прятать
is_not_modem() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	_nm_cfg
	for _nm in $NOT_MODEM_FORCE; do
		[ "$1" = "$_nm" ] && return 1
	done
	for _nm in $NOT_MODEM_VIDPIDS $NOT_MODEM_EXTRA; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

# ТОЛЬКО встроенный список, без обеих ручек. Нужна странице настроек: по ней она
# понимает, куда писать галочку - в ignore_vidpid (скрыть то, что мы считаем
# модемом) или в modem_vidpid (вернуть то, что прячем сами).
is_not_modem_builtin() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	for _nm in $NOT_MODEM_VIDPIDS; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

# --- notmodem.sh scan --------------------------------------------------------
#
# Список устройств для страницы настроек: что сейчас на шине, чем мы это считаем
# и почему. Отдельная команда, а не режим listmodems.sh: тот скрипт горячий (шесть
# запусков на загрузку страницы, кэш, ветки HiLink), и мешать в него редкий вызов
# из настроек - платить за него постоянно.
#
# Показываем устройства С ПОРТАМИ (tty/cdc-wdm) - именно они получают вкладку, -
# плюс всё, что listmodems.sh уже считает модемом (модем без портов, HiLink: его
# тоже может понадобиться скрыть). Хабы, флешки и прочая USB-мелочь сюда не
# попадают: список настроек должен оставаться коротким и осмысленным.
#
# Вывод: JSON-массив
#   [ { "path","vidpid","product","ports":[...],
#       "skip":"1"     - прячем сейчас (с учётом обеих ручек),
#       "builtin":"1"  - прячем по встроенному списку,
#       "absent":"1" } - устройства на шине нет, запись из конфига ]
nm_scan() {
	_ns_esc() {
		case "$1" in
			*\\*|*\"*) echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
			*) echo "$1" ;;
		esac
	}
	_ns_out=""
	_ns_seen=""
	_ns_add() {   # _ns_add <path> <vidpid> <product> <ports> <absent>
		_nb=0; is_not_modem_builtin "$2" && _nb=1
		_nk=0; is_not_modem "$2" && _nk=1
		[ -n "$_ns_out" ] && _ns_out="$_ns_out,"
		_ns_out="$_ns_out{\"path\":\"$(_ns_esc "$1")\",\"vidpid\":\"$(_ns_esc "$2")\",\"product\":\"$(_ns_esc "$3")\",\"ports\":[$4],\"skip\":\"$_nk\",\"builtin\":\"$_nb\",\"absent\":\"$5\"}"
	}

	for _nd in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
		[ -f "$_nd/idVendor" ] || continue
		case "$_nd" in *:*) continue ;; esac   # интерфейс, а не устройство
		_np=""
		for _ni in "$_nd":*; do
			for _nn in "$_ni"/tty/* "$_ni"/usbmisc/*; do
				[ -e "$_nn" ] || continue
				_np="${_np}${_np:+,}\"/dev/$(basename "$_nn")\""
			done
		done
		_nvp="$(cat "$_nd/idVendor" 2>/dev/null):$(cat "$_nd/idProduct" 2>/dev/null)"
		_nbn=$(basename "$_nd")
		# без портов - берём только то, что уже показано модемом (HiLink и родня)
		if [ -z "$_np" ]; then
			case " $NM_MODEM_PATHS " in *" $_nbn "*) ;; *) continue ;; esac
		fi
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "$_nbn" "$_nvp" "$(cat "$_nd/product" 2>/dev/null)" "$_np" 0
	done

	# ЗАПИСИ КОНФИГА БЕЗ ЖЕЛЕЗА. Устройство могли вынуть из разъёма - если не
	# показать его строку, галочка молча потерялась бы при следующем сохранении
	# (страница отдаёт то, что видит).
	_nm_cfg
	for _nvp in $NOT_MODEM_EXTRA $NOT_MODEM_FORCE; do
		case " $_ns_seen " in *" $_nvp "*) continue ;; esac
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "" "$_nvp" "" "" 1
	done

	echo "[$_ns_out]"
}

# Запуск как команды (не sourcing). При `. notmodem.sh` $0 остаётся именем
# родителя, поэтому сюда мы не попадаем даже с его аргументами.
case "$0" in
	*/notmodem.sh|notmodem.sh)
		case "$1" in
			scan)
				NM_MODEM_PATHS=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
					| jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
				nm_scan
				;;
			*) echo "usage: notmodem.sh scan" >&2; exit 1 ;;
		esac
		;;
esac
