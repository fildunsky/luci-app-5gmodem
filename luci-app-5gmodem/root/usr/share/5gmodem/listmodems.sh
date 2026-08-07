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

uptime_s() {
	read -r _us _ < /proc/uptime
	printf '%s\n' "${_us%%.*}"
}

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

# sed - только когда экранировать реально есть что (в дескрипторах USB кавычки
# не встречаются почти никогда, а esc зовётся на каждое поле каждого модема).
esc() {
	case "$1" in
		*\\*|*\"*) echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*) echo "$1" ;;
	esac
}

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
NL='
'
PORTREC=""
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

	# БЕЗ eval. Раньше здесь были самодельные «массивы» TTYS_<i>/WDMS_<i> через
	# eval - т.е. исполнение строк, куда подставляются имена устройств. Для
	# /dev-глоба это безопасно, но приём как класс в этом дереве запрещён
	# (аудит 1.4): один невинный eval прикрывает следующий, уже с чужим вводом.
	# Вместо этого - плоский список записей «индекс тип путь», по записи на
	# строку; выборка при сборке JSON идёт чистым read-циклом без подпроцессов.
	case "$t" in
		/dev/ttyUSB*|/dev/ttyACM*) PORTREC="${PORTREC}${idx} tty ${t}${NL}" ;;
		*)                         PORTREC="${PORTREC}${idx} wdm ${t}${NL}" ;;
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
	PORTREC="${PORTREC}${NCNT} net $(basename "$_nd")${NL}"
done

# --- Известные устройства С СЕТЬЮ, но БЕЗ модемных портов (телефон) ----------
#
# Телефон в режиме USB-модема - сетевая карта: ни tty, ни cdc-wdm, по портам он
# не находится, а под HiLink-ветку не подходит (вендор чужой, интерфейсы ff от
# ADB). Пока композиция отдавала ACM-порт, телефон попадал в список и имел
# вкладку; композиция сменилась - вкладка МОЛЧА исчезала, хотя железка на месте
# и интернет через неё идёт (живой случай 03.08.2026, Samsung S21). Карточка
# такой вкладки честно объясняет, что это за устройство (см. 5gdetail,
# «устройство на шине есть, но модемом не отвечает»).
#
# Показываем ТОЛЬКО по нашей же секции: она появляется, когда устройство хоть
# раз побывало в списке (телефон с ACM-портом побывал). Случайная USB-сетевуха
# (RTL8153 и родня) секции не имеет и сюда не попадёт. Сверяем ВЕНДОРА, а не
# vid:pid целиком: PID у телефона скачет со сменой композиции (04e8:6860/6862/
# 6864 - один и тот же аппарат), а вот чужой вендор в том же разъёме - это уже
# подмена устройства, ей займётся identity.sh.
for _ts in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.=]*\)=modem\$/\1/p"); do
	_tp=$(uci -q get "5gmodem.$_ts.path")
	case "$_tp" in *-*) ;; *) continue ;; esac
	_td=$(readlink -f "/sys/bus/usb/devices/$_tp" 2>/dev/null)
	[ -n "$_td" ] && [ -f "$_td/idVendor" ] || continue
	case " $NODES " in *" $_td "*) continue ;; esac
	_tsv=$(uci -q get "5gmodem.$_ts.vidpid"); _tsv="${_tsv%%:*}"
	[ -n "$_tsv" ] && [ "$(cat "$_td/idVendor" 2>/dev/null)" = "$_tsv" ] || continue
	_tn=""
	for _ti in /sys/bus/usb/devices/"$_tp":*/net/*; do
		[ -e "$_ti" ] && { _tn=$(basename "$_ti"); break; }
	done
	[ -n "$_tn" ] || continue
	NCNT=$((NCNT + 1))
	NODES="$NODES $_td"
	PORTREC="${PORTREC}${NCNT} net ${_tn}${NL}"
done

# КАРТА «IMEI -> своё имя» и список IMEI ПРИСУТСТВУЮЩИХ модемов - собираем ОДИН
# раз на весь список: скрипт зовётся часто, и лишний десяток `uci get` на каждый
# модем тут дороже всего остального. Формат карты: "<imei>\t<имя>" по строке.
_UCISNAP=$(uci -q show 5gmodem 2>/dev/null)
_ALIASMAP=$(printf '%s\n' "$_UCISNAP" | awk -F"[.=]" '
	/\.alias_imei=/ { gsub(/^.|.$/, "", $NF); imei[$2] = $NF; next }
	/\.alias=/       { line = $0; sub(/^[^=]*=/, "", line); gsub(/^.|.$/, "", line); nm[$2] = line }
	END { for (s in nm) if (nm[s] != "" && imei[s] != "") printf "%s\t%s\n", imei[s], nm[s] }')
_IMEIS_PRESENT=""
for _n in $NODES; do
	_p=$(basename "$_n")
	_s="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_im=$(printf '%s\n' "$_UCISNAP" | sed -n "s/^5gmodem\.$_s\.imei='\(.*\)'\$/\1/p" | head -1)
	[ -n "$_im" ] && _IMEIS_PRESENT="$_IMEIS_PRESENT$_im
"
done

OUT=""
i=0
for n in $NODES; do
	i=$((i + 1))
	path=$(basename "$n")
	vid=$(cat "$n/idVendor" 2>/dev/null)
	pid=$(cat "$n/idProduct" 2>/dev/null)
	prod=$(esc "$(cat "$n/product" 2>/dev/null)")
	# Порты этого модема - из плоского списка (см. сбор выше). Кавычки для JSON
	# навешиваются здесь же; в путях /dev и именах сетевых устройств кавычек и
	# пробелов не бывает (имена даёт ядро).
	ttys=""; wdms=""; nets=""
	while read -r _ri _rt _rp; do
		[ "$_ri" = "$i" ] || continue
		case "$_rt" in
			tty) ttys="${ttys}${ttys:+,}\"$_rp\"" ;;
			wdm) wdms="${wdms}${wdms:+,}\"$_rp\"" ;;
			net) nets="${nets}${nets:+,}\"$_rp\"" ;;
		esac
	done <<PORTREC_EOF
$PORTREC
PORTREC_EOF
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
	# ШТАМП ЖЕЛЕЗА СИЛЬНЕЕ ЭВРИСТИКИ ПО ИМЕНИ ВЕНДОРА.
	#
	# Проверка выше судит по НАЗВАНИЮ («Compal» в секции Fibocom») и потому
	# бессильна, когда вендор нового устройства ей неизвестен: у Samsung (04e8)
	# _vendor_by_vid не отвечает ничего, и функция выходит с «не судим». Живой
	# случай 03.08.2026: телефон Samsung, воткнутый в разъём от SIM7100E,
	# показывался в списке как «SIMCOM SIM7100E» - секция была смешанной,
	# vidpid/product/serial уже телефона, а model от прежнего модема.
	#
	# model_vp - тот vid:pid, с которого имя реально прочитали (ставят все три
	# писателя: resolve, основной опрос, hilink). Не совпал с железом на шине -
	# имя чужое, каким бы правдоподобным ни выглядело. Пустой штамп НЕ судим:
	# так выглядят секции, заполненные до появления штампа.
	_mv=$(uci -q get "5gmodem.$_sec.model_vp" 2>/dev/null)
	[ -n "$_mv" ] && [ "$_mv" != "$vid:$pid" ] && model=""
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
	# СВОЁ ИМЯ ОТ ПОЛЬЗОВАТЕЛЯ. Привязка - к IMEI (имя ездит вместе с железкой,
	# а не остаётся у разъёма), с откатом на секцию пути: IMEI бывает нечитаем,
	# а в дешёвых партиях - одинаковым у всех модулей. Одинаковый IMEI у двух
	# ПРИСУТСТВУЮЩИХ модемов = привязку по нему не используем вовсе, иначе одно
	# имя показалось бы обоим.
	_alias=""
	_myimei=$(uci -q get "5gmodem.$_sec.imei" 2>/dev/null)
	if [ -n "$_myimei" ] && [ "$(printf '%s\n' "$_IMEIS_PRESENT" | grep -c "^$_myimei\$")" = 1 ]; then
		_alias=$(printf '%s\n' "$_ALIASMAP" | sed -n "s/^$_myimei	//p" | head -1)
	fi
	[ -n "$_alias" ] || _alias=$(uci -q get "5gmodem.$_sec.alias" 2>/dev/null)
	_alias=$(esc "$_alias")
	OUT="$OUT{\"path\":\"$path\",\"vidpid\":\"$vid:$pid\",\"product\":\"$prod\",\"model\":\"$model\",\"alias\":\"$_alias\",\"serial\":\"$(esc "$(serial_of "$n")")\",\"operator\":\"$_opname\",\"tty\":[$ttys],\"wdm\":[$wdms],\"net\":[$nets]}"
done
OUT="[$OUT]"

# Кэш пишем атомарно (tmp+mv): скрипт зовут несколько процессов разом при
# открытии страницы, и читатель не должен увидеть обрывок файла.
# tmp УНИКАЛЕН на процесс: общий $CACHE.tmp при параллельных писателях
# давал перемешанный JSON в кэше до конца TTL (ревью)
printf '%s\n' "$OUT" > "$CACHE.tmp.$$" 2>/dev/null && mv "$CACHE.tmp.$$" "$CACHE" 2>/dev/null
uptime_s > "$STAMP" 2>/dev/null

printf '%s\n' "$OUT"
