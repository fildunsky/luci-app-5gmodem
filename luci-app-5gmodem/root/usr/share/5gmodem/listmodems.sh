#!/bin/sh
#
# Enumerate the modems physically present, grouping all serial/control ports by
# the USB device (topology path) that owns them. One entry per modem. This is
# the basis for the multi-modem tabs: a modem is identified by its USB PATH
# (stable across reboots, unlike the ttyUSB numbering, and unique even for two
# identical VID:PID modems).
#
# Output: JSON array
#   [ { "path":"2-1.4", "vidpid":"05c6:90d6", "product":"VOS_5G",
#       "tty":["/dev/ttyUSB4","/dev/ttyUSB5"], "wdm":["/dev/cdc-wdm1"] }, ... ]
#
# ПРОИЗВОДИТЕЛЬНОСТЬ (замерено на WH3000 через /proc/uptime; busybox date не
# понимает %N и молча даёт нули - мерить только так):
# скрипт зовётся 6 РАЗ за одну загрузку страницы (netpri.sh - 4 из них, плюс
# modemtabs/simslot/bands/modemswitch) и стоил 0.19 c за вызов = 1.14 c, то есть
# 48% всего бэкенда страницы. Отсюда два изменения:
#   1) КЭШ вывода в /tmp (инвалидация hotplug-хуком + короткий TTL-страховка);
#   2) ОДИН проход по портам вместо O(n^2): раньше owner_node() звался для
#      каждого порта, а затем ЕЩЁ РАЗ для каждого порта внутри цикла по модемам
#      (~100 readlink на 11 портов).
#
#   listmodems.sh              - обычный вызов (может отдать кэш)
#   listmodems.sh --refresh    - пересобрать и обновить кэш (зовёт hotplug-хук)

CACHE=/tmp/5gmodem_listmodems.cache
STAMP=/tmp/5gmodem_listmodems.stamp
TTL=8   # секунд; страховка, если hotplug-инвалидация не сработала

uptime_s() { cut -d. -f1 /proc/uptime; }

if [ "$1" = "--refresh" ]; then
	rm -f "$CACHE" "$STAMP"
elif [ -s "$CACHE" ]; then
	# find -mmin умеет только минуты, поэтому возраст считаем по /proc/uptime
	_now=$(uptime_s)
	_then=$(cat "$STAMP" 2>/dev/null)
	case "$_then" in ''|*[!0-9]*) _then="" ;; esac
	if [ -n "$_then" ] && [ "$((_now - _then))" -ge 0 ] && [ "$((_now - _then))" -lt "$TTL" ]; then
		cat "$CACHE"
		exit 0
	fi
fi

esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Валидаторы модели (_model_vendor_ok): отсекаем чужую/устаревшую модель, осевшую
# в секции после свопа модема (см. ниже). lib.sh - только определения функций,
# сорсить дёшево и без побочек.
[ -r /usr/share/5gmodem/lib.sh ] && . /usr/share/5gmodem/lib.sh

# usb_device sysfs node (has idVendor) that owns a given /dev char device
owner_node() {
	b=$(basename "$1")
	p=$(readlink -f "/sys/class/tty/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/usbmisc/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/net/$b/device" 2>/dev/null)
	while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -f "$p/idVendor" ]; do p="${p%/*}"; done
	[ -f "$p/idVendor" ] && echo "$p"
}

# ОДИН проход: каждый порт сразу кладём в список СВОЕГО модема.
# NODES хранит порядок первого появления (как и раньше), TTYS_<i>/WDMS_<i> - порты.
NODES=""
NCNT=0
for t in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan*; do
	[ -e "$t" ] || continue
	n=$(owner_node "$t")
	[ -n "$n" ] || continue

	idx=""
	i=1
	for known in $NODES; do
		[ "$known" = "$n" ] && { idx=$i; break; }
		i=$((i + 1))
	done
	if [ -z "$idx" ]; then
		NCNT=$((NCNT + 1)); idx=$NCNT
		NODES="$NODES $n"
	fi

	case "$t" in
		/dev/ttyUSB*|/dev/ttyACM*) eval "TTYS_$idx=\"\${TTYS_$idx}\${TTYS_$idx:+,}\\\"$t\\\"\"" ;;
		*)                         eval "WDMS_$idx=\"\${WDMS_$idx}\${WDMS_$idx:+,}\\\"$t\\\"\"" ;;
	esac
done

# --- Модемы БЕЗ портов (HiLink) ------------------------------------------
#
# Часть модемов не отдаёт роутеру ни AT-порта, ни cdc-wdm: они держат IP-стек
# сами и выглядят как обычная сетевая карта (cdc_ether/NCM), а управляются своим
# веб-интерфейсом. Пример - Huawei E3372h: после переключения режима у него три
# USB-интерфейса, из них ни одного последовательного, и цикл выше его не видел
# ВОВСЕ. Устройство воткнуто, а в программе пусто - и понять, почему, нельзя.
#
# Ищем ОСТОРОЖНО: только у известных сотовых вендоров и только когда у устройства
# нет ни tty, ни wdm. Иначе в список модемов попала бы любая USB-сетевая карта.
# Вендоры: 12d1 Huawei, 19d2 ZTE, 1bbb Alcatel, 2001 D-Link, 0421 Nokia,
# 1546 U-Blox, 2020 Olicard, 05c6 Qualcomm.
#
# 05c6 ДОБАВЛЕН ПОЗЖЕ и заслуживает оговорки: это самый широкий вендор из всех -
# под ним ходит и референсная Qualcomm-периферия, не только модемы. Пустили сюда
# из-за Compal RXM-G1 с ЗАВОДСКОЙ прошивкой (05c6:9063): она отдаёт роутеру одну
# лишь сетевую карту (cdc_ether -> usb0), ни AT-порта, ни cdc-wdm, - и модем не
# появлялся в программе ВООБЩЕ, хотя в Windows тот же аппарат раздаёт интернет.
# От чужих устройств защищают две проверки ниже: нет ни tty, ни wdm И нет ни
# одного интерфейса класса ff. У настоящего модема-стика ff есть всегда (из него
# и делаются ttyUSB), у сетевой карты - никогда.
_HILINK_VENDORS="12d1 19d2 1bbb 2001 0421 1546 2020 05c6"
for _nd in /sys/class/net/*; do
	[ -e "$_nd/device" ] || continue
	_dev=$(readlink -f "$_nd/device" 2>/dev/null)
	while [ -n "$_dev" ] && [ "$_dev" != "/" ] && [ ! -f "$_dev/idVendor" ]; do _dev="${_dev%/*}"; done
	[ -f "$_dev/idVendor" ] || continue
	_v=$(cat "$_dev/idVendor" 2>/dev/null)
	case " $_HILINK_VENDORS " in *" $_v "*) ;; *) continue ;; esac
	# уже найден по портам - значит это обычный модем, не HiLink
	case " $NODES " in *" $_dev "*) continue ;; esac
	# ГЛАВНАЯ ПРОВЕРКА: есть ли у устройства последовательные интерфейсы.
	#
	# «Нет портов» само по себе НЕ означает HiLink: у обычного стика порты не
	# появятся, пока драйверу не прописан его VID:PID через new_id, - и до этого
	# момента он выглядит так же. Но в ДЕСКРИПТОРЕ разница есть: у стика
	# интерфейсы класса ff (vendor-specific, из них и делаются ttyUSB), у HiLink
	# их нет вовсе - только 02/0a (CDC Ethernet) и 08 (остаток «диска»).
	# Проверено на живых: E3372h - 02,0a,08; FM350 - 02,0a,ff,ff.
	_hasff=0
	for _if in "$_dev":*; do
		[ -f "$_if/bInterfaceClass" ] || continue
		[ "$(cat "$_if/bInterfaceClass" 2>/dev/null)" = "ff" ] && { _hasff=1; break; }
	done
	[ "$_hasff" = "1" ] && continue
	NCNT=$((NCNT + 1))
	NODES="$NODES $_dev"
	eval "NETS_$NCNT=\"\\\"$(basename "$_nd")\\\"\""
done

OUT=""
i=0
for n in $NODES; do
	i=$((i + 1))
	path=$(basename "$n")
	vid=$(cat "$n/idVendor" 2>/dev/null)
	pid=$(cat "$n/idProduct" 2>/dev/null)
	prod=$(esc "$(cat "$n/product" 2>/dev/null)")
	eval "ttys=\$TTYS_$i"
	eval "wdms=\$WDMS_$i"
	eval "nets=\$NETS_$i"
	# model - имя, разобранное основным опросом по AT+CGMM (пишется в секцию
	# модема). Дескриптор product часто бесполезен: "Android" у Quectel EC21,
	# "SimTech, Incorporated" у SimCom. Читаем из uci (это дёшево), AT здесь не
	# трогаем - скрипт зовётся часто и должен оставаться быстрым.
	_sec="m_$(echo "$path" | sed 's/[^A-Za-z0-9]/_/g')"
	model=$(uci -q get "5gmodem.$_sec.model" 2>/dev/null)
	# УСТАРЕВШАЯ/ЧУЖАЯ модель. Опрос пишет model только АКТИВНОМУ модему, поэтому в
	# секции неактивного она может остаться от ПРЕЖНЕГО модема на этом же USB-пути
	# (живой баг: "Compal RXM-G1" осел в секции FM350 0e8d, и FM350 показывался
	# вторым «Compal» в табах и в приоритетах). Если имя называет ДРУГОГО вендора,
	# чем vid секции - не верим ему и берём дескриптор product (для FM350 = "FM350-GL").
	if [ -n "$model" ] && command -v _model_vendor_ok >/dev/null 2>&1 \
	   && ! _model_vendor_ok "$model" "$vid:$pid"; then
		model=""
	fi
	# Фолбэк, когда секция ещё без model (свежее пересоздание / неактивный модем):
	# берём дескриптор product. НО у Compal RXM-G1 сырой product = "VOS_5G" - имя
	# семейства, а не модели, и вкладка показывала «Compal VOS_5G». Product-строка
	# VOS_5G/RXMG1 однозначно опознаёт Compal (у T99W175 в тех же 90d5/1e2d:00b7
	# она иная), поэтому даём единое имя сразу, БЕЗ дорогих AT/QMI-проб (listmodems
	# зовётся часто - см. perf). Композиция 05c6:9025 с generic-product сюда не
	# попадёт - там имя приходит из секции по опросу.
	if [ -z "$model" ]; then
		_prodraw=$(cat "$n/product" 2>/dev/null)
		# Правило нормализации общее, см. model_alias в lib.sh.
		model=$(model_alias "$_prodraw")
		# ДЛИННЫЕ ДЕСКРИПТОРЫ -> КОРОТКОЕ ИМЯ. Производитель пишет в USB-строку
		# всё сразу: «DW5821e-eSIM Snapdragon X20 LTE» - это название чипсета, а
		# не модели, и в узкой вкладке модема оно занимает всю ширину, вытесняя
		# оператора и IP. Режем хвост с чипсетом, модель остаётся.
		case "$model" in
			*\ Snapdragon\ *) model=$(printf '%s' "$model" | sed 's/ Snapdragon .*$//') ;;
		esac

		# GENERIC-ДЕСКРИПТОР -> КОРОТКОЕ ИМЯ СЕМЕЙСТВА.
		# Модули на Qualcomm SDX55 (Foxconn T99W175, Dell DW5930e, Thales MV31-W,
		# прототип Compal) представляются одинаковой строкой «Generic Mobile
		# Broadband Adapter»: во вкладке она занимала половину ширины и ничего не
		# говорила. Точную модель без опроса не узнать - показываем компактное имя
		# семейства, а как только опрос прочитает AT+CGMM, в секции появится
		# настоящее имя (оно берётся выше и главнее этого фолбэка).
		case "$_prodraw" in
			*Generic\ Mobile\ Broadband*|*HSUSB\ Device*|*Mobile\ Broadband\ Adapter*)
				case "$vid:$pid" in
					05c6:90d5|05c6:9025|1e2d:00b7|1e2d:00b8) model="T99W175" ;;
					*) model="$vid:$pid" ;;
				esac
				;;
		esac
	fi
	model=$(esc "$model")
	# ОПЕРАТОР ЭТОГО МОДЕМА - для значка сети на вкладке (у кого какая SIM).
	# Берём из кэша, который пишет основной опрос (/tmp/5gmodem_op_<iface>, тот же
	# источник, что у «Приоритета интернета»): модем не трогаем вовсе, а для
	# НЕАКТИВНЫХ модемов это единственный доступный источник - их AT-порты никто
	# не опрашивает. Пусто, пока модем ни разу не опрашивался.
	_opname=""
	_opif=$(uci -q get "5gmodem.$_sec.network" 2>/dev/null)
	[ -n "$_opif" ] && [ -s "/tmp/5gmodem_op_$_opif" ] && \
		_opname=$(esc "$(cat "/tmp/5gmodem_op_$_opif" 2>/dev/null | tr -d '\n')")
	# ЗАПАСНОЙ ИСТОЧНИК - КЭШ «ПРИОРИТЕТА ИНТЕРНЕТА» (/tmp/netpri_op_<iface>).
	# У HiLink-модема AT-порта может не быть вовсе, и основной опрос его имя не
	# пишет - зато netpri спрашивает веб-API модема в фоне и кладёт ответ в СВОЙ
	# файл. Читали мы только первый, поэтому у таких модемов operator оставался
	# пустым, и вкладка показывала значок USB вместо логотипа оператора, хотя имя
	# было известно рядом.
	# Порядок именно такой: имя от основного опроса ТОЧНЕЕ - только он разбирает
	# UCS2, mccmnc.dat и подменяет хост-сеть брендом MVNO. netpri знает лишь имя
	# сети, и ставить его первым значило бы показывать «Tele2 RU» там, где
	# карточка честно пишет «T-Mobile».
	[ -z "$_opname" ] && [ -n "$_opif" ] && [ -s "/tmp/netpri_op_$_opif" ] && \
		_opname=$(esc "$(cat "/tmp/netpri_op_$_opif" 2>/dev/null | tr -d '\n')")
	[ -n "$OUT" ] && OUT="$OUT,"
	# net[] - сетевые имена у модемов без портов; по нему интерфейс отличает
	# HiLink от обычного и не предлагает для него AT-возможности.
	OUT="$OUT{\"path\":\"$path\",\"vidpid\":\"$vid:$pid\",\"product\":\"$prod\",\"model\":\"$model\",\"operator\":\"$_opname\",\"tty\":[$ttys],\"wdm\":[$wdms],\"net\":[$nets]}"
done
OUT="[$OUT]"

# Кэш пишем атомарно (tmp+mv): скрипт зовут несколько процессов разом при
# открытии страницы, и читатель не должен увидеть обрывок файла.
printf '%s\n' "$OUT" > "$CACHE.tmp" 2>/dev/null && mv "$CACHE.tmp" "$CACHE" 2>/dev/null
uptime_s > "$STAMP" 2>/dev/null

printf '%s\n' "$OUT"
