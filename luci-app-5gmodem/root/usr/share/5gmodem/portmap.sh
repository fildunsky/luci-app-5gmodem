#!/bin/sh
#
# КАРТА ПОРТОВ: устройство на шине -> его tty -> IMEI, прочитанный С ЭТОГО tty.
#
# ЗАЧЕМ. Когда на роутере два одинаковых модуля (один vid:pid), разобрать по
# отчёту, что чему принадлежит, было нельзя: привязку «порт -> модем» строит наш
# же listmodems.sh, и если бы она врала, отчёт врал бы вместе с ней - проверить
# нечем. Живой случай: два Thales MV31-W отдали ОДИН И ТОТ ЖЕ IMEI, и по отчёту
# невозможно было отличить «клонированный IMEI на двух модулях» от «наша
# привязка портов ошиблась и мы дважды прочитали один модем».
#
# Поэтому здесь ВСЁ берётся напрямую из sysfs, минуя наш код:
#   - устройства: /sys/bus/usb/devices/<путь> (idVendor/idProduct/serial)
#   - порты: из интерфейсов ЭТОГО устройства (<путь>:*/ttyUSB*)
#   - IMEI: AT+CGSN, прочитанный с портов ИМЕННО этого устройства
# USB-серийник печатается рядом: он различает два одинаковых модуля даже когда
# всё остальное совпадает.
#
# Вывод заканчивается вердиктом, чтобы не пришлось сверять числа глазами:
#   - разные устройства с одинаковым IMEI -> прямо сказано, что это дубликат;
#   - у устройства нет ни одного отвечающего порта -> тоже сказано.
#
# ЧИТАЕМ АККУРАТНО. Порт может быть занят опросом метрик, поэтому берём
# at_lock (короткое ожидание) и опрашиваем НЕ БОЛЬШЕ двух портов на устройство:
# AT-порт у модемов из первых, а полный перебор на 4 модемах стоил бы десятки
# секунд и мешал бы работе.

RES=/usr/share/5gmodem
[ -r "$RES/atlock.sh" ] && . "$RES/atlock.sh"
[ -r "$RES/lib.sh" ] && . "$RES/lib.sh"   # at_query: очередь + таймаут

_pm_imei() {   # $1 - tty; печатает IMEI либо пусто
	command -v at_lock >/dev/null 2>&1 && { at_lock "$1" 5 2>/dev/null || return 1; }
	_pm_i=$(at_query "$1" "AT+CGSN" 6 \
		| grep -xE '[0-9]{14,16}' | head -1)
	command -v at_unlock >/dev/null 2>&1 && at_unlock 2>/dev/null
	[ -n "$_pm_i" ] || return 1
	printf '%s' "$_pm_i"
}

_pm_seen=""      # "imei:путь imei:путь ..." - для поиска дубликатов
_pm_dupes=""

for _pm_d in /sys/bus/usb/devices/*; do
	case "$_pm_d" in *:*) continue ;; esac          # интерфейсы, а не устройства
	[ -f "$_pm_d/idVendor" ] || continue
	_pm_path=$(basename "$_pm_d")
	case "$_pm_path" in usb*) continue ;; esac      # корневые хабы
	_pm_vid=$(cat "$_pm_d/idVendor" 2>/dev/null)
	_pm_pid=$(cat "$_pm_d/idProduct" 2>/dev/null)

	# порты ЭТОГО устройства
	_pm_ttys=""
	for _pm_if in "$_pm_d":*; do
		[ -d "$_pm_if" ] || continue
		for _pm_t in "$_pm_if"/ttyUSB* "$_pm_if"/tty/ttyUSB* "$_pm_if"/ttyACM* "$_pm_if"/tty/ttyACM*; do
			[ -e "$_pm_t" ] && _pm_ttys="$_pm_ttys $(basename "$_pm_t")"
		done
	done
	# управляющие узлы (для полноты картины)
	_pm_wdm=""
	for _pm_w in "$_pm_d":*/usbmisc/cdc-wdm* "$_pm_d":*/usbmisc/wdm*; do
		[ -e "$_pm_w" ] && _pm_wdm="$_pm_wdm $(basename "$_pm_w")"
	done
	# сетевые карты (HiLink и подобные)
	_pm_net=""
	for _pm_n in "$_pm_d":*/net/*; do
		[ -e "$_pm_n" ] && _pm_net="$_pm_net $(basename "$_pm_n")"
	done
	# устройство без единого модемного узла - не модем, пропускаем
	[ -n "$_pm_ttys$_pm_wdm$_pm_net" ] || continue

	echo "### $_pm_path  [$_pm_vid:$_pm_pid]  serial=$(cat "$_pm_d/serial" 2>/dev/null || echo '-')"
	echo "    продукт: $(cat "$_pm_d/product" 2>/dev/null || echo '-')"
	echo "    порты:  ${_pm_ttys:- нет}"
	echo "    cdc-wdm:${_pm_wdm:- нет}    сеть:${_pm_net:- нет}"

	_pm_imei_dev=""
	_pm_tried=0
	for _pm_t in $_pm_ttys; do
		[ "$_pm_tried" -ge 2 ] && break
		_pm_tried=$((_pm_tried + 1))
		_pm_r=$(_pm_imei "/dev/$_pm_t") || continue
		_pm_imei_dev="$_pm_r"
		echo "    IMEI:   $_pm_r  (прочитан с /dev/$_pm_t)"
		break
	done
	if [ -z "$_pm_imei_dev" ]; then
		if [ -n "$_pm_ttys" ]; then
			echo "    IMEI:   порты не ответили на AT+CGSN"
		else
			echo "    IMEI:   AT-портов нет (HiLink или композиция без них)"
		fi
		continue
	fi

	# дубликат IMEI у ДРУГОГО устройства?
	for _pm_e in $_pm_seen; do
		case "$_pm_e" in
			"$_pm_imei_dev":*)
				_pm_other=${_pm_e#*:}
				_pm_dupes="$_pm_dupes$_pm_imei_dev ($_pm_other и $_pm_path)
"
				;;
		esac
	done
	_pm_seen="$_pm_seen $_pm_imei_dev:$_pm_path"
done

echo ""
if [ -n "$_pm_dupes" ]; then
	echo "!!! ОДИНАКОВЫЙ IMEI У РАЗНЫХ УСТРОЙСТВ:"
	printf '%s' "$_pm_dupes" | sed 's/^/    /'
	echo "    Устройства различаются по USB-серийнику выше, то есть это"
	echo "    физически РАЗНЫЕ модули с совпадающим IMEI (клонированный или"
	echo "    не прошитый). Приложение это переживает, но владение интерфейсом"
	echo "    и профили в таком случае решаются по USB-пути, а не по IMEI."
else
	echo "IMEI у всех опрошенных устройств различаются - дубликатов нет."
fi
exit 0
