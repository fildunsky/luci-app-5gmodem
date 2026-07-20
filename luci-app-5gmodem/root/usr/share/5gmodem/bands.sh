#!/bin/sh

#
# (c) 2022-2024 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2022-2024 modified by Rafał Wabik - IceG - From eko.one.pl forum
#

hextobands() {
	BANDS=""
	HEX="$1"
	LEN=${#HEX}
	if [ $LEN -gt 18 ]; then
		CNT=$((LEN - 16))
		HHEX=${HEX:0:CNT}
		HEX="0x"${HEX:CNT}
	fi

	for B in $(seq 0 63); do
		POW=$((2 ** $B))
		T=$((HEX&$POW))
		[ "x$T" = "x$POW" ] && BANDS="${BANDS}$((B + 1)) "
	done
	if [ -n "$HHEX" ]; then
		for B in $(seq 0 63); do
			POW=$((2 ** $B))
			T=$((HHEX&$POW))
			[ "x$T" = "x$POW" ] && BANDS="${BANDS}$((B + 1 + 64)) "
		done
	fi
	echo "$BANDS"
}

bandstohex() {
	BANDS="$1"
	SUM=0
	HSUM=0
	for BAND in $BANDS; do
		case $BAND in
			''|*[!0-9]*) continue ;;
		esac
		if [ $BAND -gt 64 ]; then
			B=$((BAND - 1 - 64))
			POW=$((2 ** $B))
			HSUM=$((HSUM + POW))
		else
			B=$((BAND - 1))
			POW=$((2 ** $B))
			SUM=$((SUM + POW))
		fi
	done
	if [ $HSUM -eq 0 ]; then
		HEX=$(printf '%x' $SUM)
	else
		HEX=$(printf '%x%016x' $HSUM $SUM)
	fi
	echo "$HEX"
}

bandtxt() {
	BAND=$1

# see https://en.wikipedia.org/wiki/LTE_frequency_bands

	case "$BAND" in
	"1") echo " $BAND: FDD 2100 MHz";;
	"2") echo " $BAND: FDD 1900 MHz";;
	"3") echo " $BAND: FDD 1800 MHz";;
	"4") echo " $BAND: FDD 1700 MHz";;
	"5") echo " $BAND: FDD  850 MHz";;
	"7") echo " $BAND: FDD 2600 MHz";;
	"8") echo " $BAND: FDD  900 MHz";;
	"11") echo "$BAND: FDD 1500 MHz";;
	"12") echo "$BAND: FDD  700 MHz";;
	"13") echo "$BAND: FDD  700 MHz";;
	"14") echo "$BAND: FDD  700 MHz";;
	"17") echo "$BAND: FDD  700 MHz";;
	"18") echo "$BAND: FDD  850 MHz";;
	"19") echo "$BAND: FDD  850 MHz";;
	"20") echo "$BAND: FDD  800 MHz";;
	"21") echo "$BAND: FDD 1500 MHz";;
	"24") echo "$BAND: FDD 1600 MHz";;
	"25") echo "$BAND: FDD 1900 MHz";;
	"26") echo "$BAND: FDD  850 MHz";;
	"28") echo "$BAND: FDD  700 MHz";;
	"29") echo "$BAND: SDL  700 MHz";;
	"30") echo "$BAND: FDD 2300 MHz";;
	"31") echo "$BAND: FDD  450 MHz";;
	"32") echo "$BAND: SDL 1500 MHz";;
	"34") echo "$BAND: TDD 2000 MHz";;
	"37") echo "$BAND: TDD 1900 MHz";;
	"38") echo "$BAND: TDD 2600 MHz";;
	"39") echo "$BAND: TDD 1900 MHz";;
	"40") echo "$BAND: TDD 2300 MHz";;
	"41") echo "$BAND: TDD 2500 MHz";;
	"42") echo "$BAND: TDD 3500 MHz";;
	"43") echo "$BAND: TDD 3700 MHz";;
	"46") echo "$BAND: TDD 5200 MHz";;
	"47") echo "$BAND: TDD 5900 MHz";;
	"48") echo "$BAND: TDD 3500 MHz";;
	"50") echo "$BAND: TDD 1500 MHz";;
	"51") echo "$BAND: TDD 1500 MHz";;
	"53") echo "$BAND: TDD 2400 MHz";;
	"54") echo "$BAND: TDD 1600 MHz";;
	"65") echo "$BAND: FDD 2100 MHz";;
	"66") echo "$BAND: FDD 1700 MHz";;
	"67") echo "$BAND: SDL  700 MHz";;
	"69") echo "$BAND: SDL 2600 MHz";;
	"70") echo "$BAND: FDD 1700 MHz";;
	"71") echo "$BAND: FDD  600 MHz";;
	"72") echo "$BAND: FDD  450 MHz";;
	"73") echo "$BAND: FDD  450 MHz";;
	"74") echo "$BAND: FDD 1500 MHz";;
	"75") echo "$BAND: SDL 1500 MHz";;
	"76") echo "$BAND: SDL 1500 MHz";;
	"85") echo "$BAND: FDD  700 MHz";;
	"87") echo "$BAND: FDD  410 MHz";;
	"88") echo "$BAND: FDD  410 MHz";;
	"103") echo "$BAND: FDD  700 MHz";;
	"106") echo "$BAND: FDD  900 MHz";;
	esac
}

bandtxt5g() {
	BAND=$1

# see https://en.wikipedia.org/wiki/5G_NR_frequency_bands

	case "$BAND" in
	"1") echo " $BAND: FDD 2100 MHz";;
	"2") echo " $BAND: FDD 1900 MHz";;
	"3") echo " $BAND: FDD 1800 MHz";;
	"5") echo " $BAND: FDD  850 MHz";;
	"7") echo " $BAND: FDD 2600 MHz";;
	"8") echo " $BAND: FDD  900 MHz";;
	"12") echo "$BAND: FDD  700 MHz";;
	"13") echo "$BAND: FDD  700 MHz";;
	"14") echo "$BAND: FDD  700 MHz";;
	"18") echo "$BAND: FDD  850 MHz";;
	"20") echo "$BAND: FDD  800 MHz";;
	"24") echo "$BAND: FDD 1600 MHz";;
	"25") echo "$BAND: FDD 1900 MHz";;
	"26") echo "$BAND: FDD  850 MHz";;
	"28") echo "$BAND: FDD  700 MHz";;
	"29") echo "$BAND: SDL  700 MHz";;
	"30") echo "$BAND: TDD 2300 MHz";;
	"34") echo "$BAND: TDD 2100 MHz";;
	"38") echo "$BAND: TDD 2600 MHz";;
	"39") echo "$BAND: TDD 1900 MHz";;
	"40") echo "$BAND: TDD 2300 MHz";;
	"41") echo "$BAND: TDD 2500 MHz";;
	"46") echo "$BAND: TDD 5200 MHz";;
	"47") echo "$BAND: TDD 5900 MHz";;
	"48") echo "$BAND: TDD 3500 MHz";;
	"50") echo "$BAND: TDD 1500 MHz";;
	"51") echo "$BAND: TDD 1500 MHz";;
	"53") echo "$BAND: TDD 2400 MHz";;
	"54") echo "$BAND: TDD 1600 MHz";;
	"65") echo "$BAND: FDD 2100 MHz";;
	"66") echo "$BAND: FDD 1700/2100 MHz";;
	"67") echo "$BAND: SDL  700 MHz";;
	"70") echo "$BAND: FDD 2000 MHz";;
	"71") echo "$BAND: FDD  600 MHz";;
	"74") echo "$BAND: FDD 1500 MHz";;
	"75") echo "$BAND: SDL 1500 MHz";;
	"76") echo "$BAND: SDL 1500 MHz";;
	"77") echo "$BAND: TDD 3700 MHz";;
	"78") echo "$BAND: TDD 3500 MHz";;
	"79") echo "$BAND: TDD 4700 MHz";;
	"80") echo "$BAND: SUL 1800 MHz";;
	"81") echo "$BAND: SUL  900 MHz";;
	"82") echo "$BAND: SUL  800 MHz";;
	"83") echo "$BAND: SUL  700 MHz";;
	"84") echo "$BAND: SUL 2100 MHz";;
	"85") echo "$BAND: FDD  700 MHz";;
	"86") echo "$BAND: SUL 1700 MHz";;
	"89") echo "$BAND: SUL  850 MHz";;
	"90") echo "$BAND: TDD 2500 MHz";;
	"91") echo "$BAND: FDD  800/1500 MHz";;
	"92") echo "$BAND: FDD  800/1500 MHz";;
	"93") echo "$BAND: FDD  900/1500 MHz";;
	"94") echo "$BAND: FDD  900/1500 MHz";;
	"95") echo "$BAND: SUL 2100 MHz";;
	"96") echo "$BAND: TDD 6000 MHz";;
	"97") echo "$BAND: SUL 2300 MHz";;
	"98") echo "$BAND: SUL 1900 MHz";;
	"99") echo "$BAND: SUL 1600 MHz)";;
	"100") echo "$BAND: FDD  900 MHz";;
	"101") echo "$BAND: TDD 1900 MHz";;
	"102") echo "$BAND: TDD 6200 MHz";;
	"104") echo "$BAND: TDD 6700 MHz";;
	"105") echo "$BAND: FDD  600 MHz";;
	"257") echo "$BAND: 28 GHz";;
	"258") echo "$BAND: 26 GHz";;
	"259") echo "$BAND: 41 GHz";;
	"260") echo "$BAND: 39 GHz";;
	"261") echo "$BAND: 28 GHz";;
	"262") echo "$BAND: 47 GHz";;
	"263") echo "$BAND: 60 GHz";;
	esac
}

_DEVICE=""
# Признак «профиль модема реально подключён» (заменяет прежнюю проверку по
# непустому _DEVICE). Профили больше НЕ прибивают _DEVICE=/dev/ttyXXX (это была
# ловушка: на мультимодеме «запасной» порт - порт ДРУГОГО модема). Реальный порт
# профилю задаёт этот скрипт ниже из автодетекта приложения; флаг нужен, чтобы
# отличить «профиль загружен, порт назначим» от «профиля нет -> unsupported».
_PROFILE_LOADED=""
_DEFAULT_LTE_BANDS=""
_DEFAULT_5GNSA_BANDS=""
_DEFAULT_5GSA_BANDS=""

# default templates

# modem name/type
getinfo() {
	echo "Unsupported"
}

# get supported band - 4G
getsupportedbands() {
	echo "Unsupported"
}

getsupportedbandsext() {
	T=$(getsupportedbands)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt "$BAND"
	done
}

# get current configured bands - 4G
getbands() {
	echo "Unsupported"
}

getbandsext() {
	T=$(getbands)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt "$BAND"
	done
}

# set bands - 4G
setbands() {
	echo "Unsupported"
}

# get supported band - 5G NSA
getsupportedbands5gnsa() {
	echo "Unsupported"
}

getsupportedbandsext5gnsa() {
	T=$(getsupportedbands5gnsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

# get current configured bands - 5G NSA
getbands5gnsa() {
	echo "Unsupported"
}

getbandsext5gnsa() {
	T=$(getbands5gnsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

# set bands - 5G NSA
setbands5gnsa() {
	echo "Unsupported"
}

# get supported band - 5G SA
getsupportedbands5gsa() {
	echo "Unsupported"
}

getsupportedbandsext5gsa() {
	T=$(getsupportedbands5gsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

# get current configured bands - 5G SA
getbands5gsa() {
	echo "Unsupported"
}

getbandsext5gsa() {
	T=$(getbands5gsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

# set bands - 5G SA
setbands5gsa() {
	echo "Unsupported"
}

# network mode (2G/3G/4G) - space-separated "id:label" pairs, e.g.
# "2:Auto 13:2G 14:3G 38:4G". "Unsupported" hides the mode selector.
getsupportedmodes() {
	echo "Unsupported"
}

# currently selected mode id
getmode() {
	echo "Unsupported"
}

# set mode by id
setmode() {
	echo "Unsupported"
}

# --- Диапазоны 3G (UMTS) -----------------------------------------------------
#
# ВНИМАНИЕ: модель НЕ такая, как у LTE. У LTE - битовая маска, и пользователь
# свободно набирает любой список диапазонов галочками. У 3G (по крайней мере у
# Telit) прошивка принимает не маску, а ОДНУ ИЗ ГОТОВЫХ КОМБИНАЦИЙ по её номеру:
#   AT#BND=? -> #BND: (0),(0-11,17,18),(A7E0BB0F38DF),(42)
#                         ^^^^^^^^^^^ допустимые номера комбинаций UMTS
# Произвольный набор («850 + 2100») задать НЕЛЬЗЯ, если такой комбинации нет в
# таблице модема. Поэтому здесь список вариантов, а в UI - выпадающий список, а
# не галочки: иначе пользователь снимал бы галочку, а модем применял совсем
# другой набор.
#
# Формат getsupportedbands3g: ПО ОДНОЙ паре "id:подпись" НА СТРОКУ (не через
# пробел, как у getsupportedmodes: подписи содержат пробелы - "2100 + 1900").
# "Unsupported" (или пусто) - скрыть секцию 3G целиком.
getsupportedbands3g() {
	echo "Unsupported"
}

# id текущей комбинации 3G
getbands3g() {
	echo "Unsupported"
}

# выбрать комбинацию 3G по id
setbands3g() {
	echo "Unsupported"
}

# --- Привязка к соте (cell lock) ---------------------------------------------
# Формат getcelllock:
#   "Unsupported" - модем не умеет (секция скрыта)
#   "off"         - привязки нет
#   "arfcn <n>"   - привязка к частоте
#   "cell <n> <pci>" - привязка к конкретной соте
# К привязке может добавляться последним словом признак:
#   "... readonly"  - состояние читается, но менять его профиль не умеет.
#     Нужен, чтобы интерфейс показал привязку БЕЗ кнопки «Снять»: кнопка,
#     которая молча ничего не делает, хуже её отсутствия.
#   "... remembered" - модем о привязке молчит, значение взято из нашей записи
#     (см. ветку getcelllock ниже).
getcelllock() {
	echo "Unsupported"
}

# setcelllock off | arfcn <n> | cell <n> <pci>
setcelllock() {
	echo "Unsupported"
}

# --- Режим 5G в самом модеме -------------------------------------------------
# Отдельная от диапазонов настройка: модем умеет 5G, но 5G ВЫКЛЮЧЕН в прошивке -
# тогда ни выбор диапазонов, ни привязка к соте ничего не дадут, а причина
# никак не видна. Формат get5gmode:
#   "Unsupported" - модем не умеет управлять этим (строка скрыта)
#   "sa+nsa"      - обе схемы включены (нормальное состояние)
#   "sa" | "nsa"  - включена только одна
#   "off"         - 5G выключен в модеме
get5gmode() {
	echo "Unsupported"
}

# set5gmode full - включить и SA, и NSA
set5gmode() {
	echo "Unsupported"
}

# --- Возврат связи после цикла режима полёта ---------------------------------
# Привязка к соте и включение 5G проводят модем через AT+CFUN=4. После возврата
# модем РЕГИСТРИРУЕТСЯ САМ, но PDP-контекст остаётся пустым, а интерфейс -
# опущенным: проверено на живом FM350 (CEREG: 2,1 и оператор есть, при этом
# CGACT пуст, up=false, интернета нет). Без этого пользователь после привязки
# остаётся без связи и должен чинить руками.
_reconnect_iface() {
	_ri_sec=$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_ri_sec" ] || return
	_ri_if=$(uci -q get "5gmodem.m_$_ri_sec.network")
	[ -n "$_ri_if" ] || return
	# Ждём именно РЕГИСТРАЦИИ: поднять интерфейс раньше - значит получить отказ
	# и уйти в паузу netifd, то есть сделать хуже, чем ничего.
	_ri_n=0
	while [ "$_ri_n" -lt 40 ]; do
		case "$(sms_tool -d $_DEVICE at "AT+CEREG?" 2>/dev/null | tr -d '\r' \
			| sed -n 's/^+CEREG: *//p' | cut -d, -f2)" in
			1|5) break ;;
		esac
		sleep 2
		_ri_n=$((_ri_n + 1))
	done
	ifup "$_ri_if" >/dev/null 2>&1
}

# --- Агрегация включена в модеме? --------------------------------------------
# "Unsupported" - не умеем спросить (строка скрыта) | "on" | "off"
getcaenabled() {
	echo "Unsupported"
}

# --- Сигнал по антенным портам -----------------------------------------------
# Формат: по одной строке "порт:rsrp:rsrq" (dBm/dB). "Unsupported" - модем не
# умеет, блок в UI не показывается. Живая диагностика антенн: порт с RSRP около
# -140 = антенна не подключена.
getantports() {
	echo "Unsupported"
}


# --- МОДЕМ БЕЗ AT-ПОРТОВ -----------------------------------------------------
# У HiLink-модема диапазоны читаются и меняются его же API (маска LTEBand в
# /api/net/net-mode), а не AT-командами. Профилей modemband для него нет и быть
# не может - перехватываем здесь, до выбора профиля.
_bs_am=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_bs_sec="m_$(echo "$_bs_am" | sed 's/[^A-Za-z0-9]/_/g')"
_bs_at=$(uci -q get "5gmodem.$_bs_sec.at_port")
# Работа с диапазонами - длинная цепочка AT (чтение маски, запись, перезапрос).
# Без очереди к порту она перемешивалась с опросом метрик, и маска читалась
# частично: именно так «Все диапазоны» иногда оставляли модем на одном бенде.
. /usr/share/5gmodem/atlock.sh
[ -n "$_bs_at" ] && at_lock "$_bs_at" 15
# ДИАПАЗОНЫ HiLink-МОДЕМА - ВСЕГДА ЧЕРЕЗ ЕГО API, даже в режиме debug.
#
# Почему НЕ через AT-профиль: у Huawei смена диапазонов по AT (at^syscfgex)
# сбрасывает USB-композицию - модем ВЫВАЛИВАЕТСЯ из debug обратно в чистый
# HiLink, теряет AT-порты, а вместе с ними метрики, и на секунды пропадает с
# шины (страница успевает переключиться на соседний модем). Проверено вживую.
# API же (net-mode) меняет диапазоны, НЕ трогая композицию - debug сохраняется.
#
# Метрики/SMS/USSD этой ветки не касаются: они идут своим путём (AT в debug).
if [ -n "$_bs_am" ] && [ "$(uci -q get "5gmodem.$_bs_sec.kind")" = "hilink" ]; then
	_HL=/usr/share/5gmodem/hilink.sh
	# Полный список поддерживаемых диапазонов API не отдаёт - только текущую
	# маску. Но когда модем в debug, его знает AT-профиль. Читаем оттуда ОДИН РАЗ
	# и запоминаем: иначе выключенный диапазон пропадал бы из списка кнопок и его
	# нельзя было бы включить обратно.
	_bs_full=$(uci -q get "5gmodem.$_bs_sec.band_full")
	if [ -z "$_bs_full" ] && [ -n "$_bs_at" ] && [ -c "$_bs_at" ]; then
		_bs_full=$(RES="/usr/share/5gmodem/modemband"; . "$RES/$(uci -q get "5gmodem.$_bs_sec.vidpid" | tr -d ':')" 2>/dev/null; _DEVICE="$_bs_at"; getsupportedbands 2>/dev/null)
		[ -n "$_bs_full" ] && { uci -q set "5gmodem.$_bs_sec.band_full=$_bs_full"; uci -q commit 5gmodem; }
	fi
	_en=$("$_HL" getbands "$_bs_am" 2>/dev/null)
	# supported = запомненный полный список; если ещё не знаем - хотя бы включённые.
	_sup="$_bs_full"; [ -n "$_sup" ] || _sup="$_en"
	case "$1" in
		json)
			_cm=$("$_HL" getmode "$_bs_am" 2>/dev/null)
			printf '{ "modem": "%s", "currentmode": "%s", "modes": [' \
				"$(uci -q get "5gmodem.$_bs_sec.model")" "$_cm"
			printf '{"id":"1","label":"Авто"},{"id":"8","label":"2G"},{"id":"2","label":"3G"},{"id":"4","label":"4G"}'
			printf '], "supported": ['
			_f=1
			for _b in $_sup; do
				[ "$_f" = 1 ] || printf ','
				_f=0
				printf '{"band":%s,"txt":"B%s"}' "$_b" "$_b"
			done
			printf '], "enabled": [%s] }\n' "$(echo $_en | tr ' ' ',')"
			exit 0 ;;
		getbands)          echo "$_en"; exit 0 ;;
		getsupportedbands) echo "$_sup"; exit 0 ;;
		getmode)           "$_HL" getmode "$_bs_am"; exit 0 ;;
		getsupportedmodes) echo "1:Авто 8:2G 2:3G 4:4G"; exit 0 ;;
		setbands)
			"$_HL" setbands "$2" "$_bs_am"
			# СТОРОЖ debug. Даже через API смена диапазонов иногда заставляет
			# модем перерегистрироваться в сети и при этом сбросить USB-композицию
			# (наблюдалось на B20): он вываливается из debug в чистый HiLink,
			# теряет AT-порты. В фоне проверяем и возвращаем debug + интерфейс.
			( sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null &
			exit 0 ;;
		setmode)
			"$_HL" setmode "$2" "$_bs_am"
			( sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null &
			exit 0 ;;
		*) echo "Unsupported"; exit 0 ;;
	esac
fi

RES="/usr/share/5gmodem/modemband"

# Multi-modem: load the band profile of the ACTIVE modem (by USB path), not of
# whichever USB device is enumerated first - otherwise band management operates
# on the wrong modem (both tabs showed/set the same bands).
_AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_AVIDPID=""; _APROD=""
if [ -n "$_AMP" ]; then
	_ALM=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
	_AVIDPID=$(echo "$_ALM" | jsonfilter -e "@[@.path=\"$_AMP\"].vidpid" 2>/dev/null | tr -d ':')
	# Модель из USB-дескриптора - ровно то, из чего легаси-путь ниже строит имя
	# "<vidpid><Product>". Пробелы/слэши в имени файла невозможны, поэтому такие
	# дескрипторы (напр. "USB Modem") просто не дадут совпадения - это нормально.
	_APROD=$(echo "$_ALM" | jsonfilter -e "@[@.path=\"$_AMP\"].product" 2>/dev/null | head -1)
	case "$_APROD" in *[!A-Za-z0-9_.-]*) _APROD="" ;; esac
fi

if [ -n "$_AMP" ]; then
	# active modem is known: use ONLY its profile. If it has none (e.g. Fibocom
	# without a band profile), leave _DEVICE unset -> "unsupported", instead of
	# falling back to ANOTHER modem's profile (which would manage the wrong one).
	#
	# Порядок важен: сперва профиль С МОДЕЛЬЮ в имени, затем общий по vidpid.
	# Раньше здесь искался ТОЛЬКО "<vidpid>", а у части Quectel общего файла не
	# существует вовсе - есть лишь "2c7c0306EP06-E", "2c7c0800RM500Q-GL" и т.п.
	# Из-за этого при двух модемах EP06/EG18/RM500Q оставались БЕЗ профиля бендов
	# ("Unsupported"), хотя файл лежал рядом: имя с моделью понимал только
	# легаси-путь ниже (он берёт Product= из debugfs). Теперь оба пути ищут
	# одинаково. Модель точнее, поэтому она в приоритете.
	_found=""
	for _cand in "$_AVIDPID$_APROD" "$_AVIDPID"; do
		[ -n "$_cand" ] || continue
		[ -e "$RES/$_cand" ] || continue
		_found="$_cand"; break
	done

	# Дескриптору верить нельзя: EC21 представляется как "Android" (проверено),
	# и такие модемы не совпадут ни с "<vidpid>EP06-E", ни с чем-либо ещё. Если
	# по дескриптору и по чистому vidpid ничего нет - спрашиваем МОДЕЛЬ у самого
	# модема (AT+CGMM даёт "EC21"/"EP06") и ищем файл, чьё имя с неё НАЧИНАЕТСЯ:
	# в базе профили названы полным вариантом ("2c7c0306EP06-E"), а CGMM отдаёт
	# базовую модель без суффикса региона. Это же различает EG06-E и EP06-E,
	# сидящие на ОДНОМ vidpid 2c7c0306.
	# AT-запрос делаем только здесь, в последнюю очередь: на большинстве модемов
	# профиль находится раньше, и лишнего обращения к порту не будет.
	if [ -z "$_found" ] && [ -n "$_AVIDPID" ]; then
		_atp=$(uci -q get 5gmodem.@5gmodem[0].at_port)
		if [ -n "$_atp" ] && [ -e "$_atp" ]; then
			_mdl=$(sms_tool -d "$_atp" at "AT+CGMM" 2>/dev/null | tr -d '\r' \
				| grep -vE '^(AT|OK|ERROR|$)' | head -1 | tr -d ' ')
			case "$_mdl" in
				''|*[!A-Za-z0-9_.-]*) _mdl="" ;;
			esac
			if [ -n "$_mdl" ]; then
				for _f in "$RES/$_AVIDPID$_mdl"*; do
					[ -e "$_f" ] || continue
					_found=$(basename "$_f"); break
				done
			fi
		fi
	fi

	# IFS вокруг профиля - см. пояснение в 5gmodem.sh: профили переводят его в
	# перевод строки и не возвращают, а подключаются в нашем окружении.
	[ -n "$_found" ] && { _SIFS="$IFS"; . "$RES/$_found"; IFS="$_SIFS"; _PROFILE_LOADED=1; }
else
	# no active modem configured (single-modem legacy): scan for any profile.
	_DEVS=$(awk '{gsub("="," ");
	if ($0 ~ /Bus.*Lev.*Prnt.*Port.*/) {T=$0}
	if ($0 ~ /Vendor.*ProdID/) {idvendor[T]=$3; idproduct[T]=$5}
	if ($0 ~ /Product/) {product[T]=$3}}
	END {for (idx in idvendor) {printf "%s%s\n%s%s%s\n", idvendor[idx], idproduct[idx], idvendor[idx], idproduct[idx], product[idx]}}' /sys/kernel/debug/usb/devices)
	for _DEV in $_DEVS; do
		if [ -e "$RES/$_DEV" ]; then
			_SIFS="$IFS"; . "$RES/$_DEV"; IFS="$_SIFS"
			_PROFILE_LOADED=1
			break
		fi
	done
fi

if [ -n "$_PROFILE_LOADED" ]; then
	# Профиль подключён - назначаем ему AT-порт приложения (uci at_port, иначе
	# detect.sh). Профили больше не содержат прибитого _DEVICE, поэтому источник
	# порта тут ЕДИНСТВЕННЫЙ. Если порт недоступен, _DEVICE останется пустым ->
	# _PORT_OK=0 -> статические списки без живых запросов (см. ниже). Это лучше
	# «запасного» порта из профиля, который на мультимодеме принадлежал бы другому
	# модему.
	_ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	[ -n "$_ATP" ] || _ATP=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	case "$_ATP" in
		/dev/*) [ -e "$_ATP" ] && _DEVICE="$_ATP" ;;
	esac
fi

# _PORT_OK=1 only when we can actually talk to the modem. The STATIC lists
# (getsupported*/getsupportedmodes) come from the modemband profile - already
# sourced above - and must be reported REGARDLESS of port state, so the band /
# mode buttons are always shown. This is the recovery path: if the modem is
# rebooted onto a band with no coverage, its AT port may vanish or hang, but the
# user still needs the buttons to switch back to a working band. Only the LIVE
# queries (getbands/getmode = current selection) are gated on the port.
_PORT_OK=0
[ -n "$_DEVICE" ] && [ -e "$_DEVICE" ] && _PORT_OK=1

# УПРАВЛЯЕМОСТЬ в ТЕКУЩЕМ протоколе интерфейса. Профиль объявляет транспорт:
#   _BAND_VIA=at    (по умолчанию) - вендорные AT-команды, работают всегда;
#   _BAND_VIA=mmcli - только через ModemManager (у прошивки нет AT бенд-лока,
#                     напр. Compal RXM-G1).
# mmcli-профиль на KERNEL-протоколе (mbim/qmi/ncm/...) неуправляем: такой модем
# прячет от ModemManager инхибитор (mm-inhibit.sh), mmcli его не видит - ни
# считать, ни применить бенды/режим нельзя. Тогда глушим ВСЕ статичные списки, и UI покажет
# подсказку «управление диапазонами доступно только через ModemManager» вместо
# кнопок, которые всё равно не сработали бы.
if [ "$_BAND_VIA" = "mmcli" ]; then
	_IFACE=$(uci -q get 5gmodem.@5gmodem[0].network)
	if [ "$(uci -q get "network.$_IFACE.proto" 2>/dev/null)" != "modemmanager" ]; then
		getsupportedbands()      { echo "Unsupported"; }
		getsupportedbands5gnsa() { echo "Unsupported"; }
		getsupportedbands5gsa()  { echo "Unsupported"; }
		getsupportedmodes()      { echo "Unsupported"; }
		_PORT_OK=0
	else
		# Для mmcli-профиля наличие tty НИЧЕГО не значит в обе стороны: управление
		# идёт через ModemManager (у такой прошивки рабочего AT-порта может не быть
		# вовсе - у Compal RXM-G1 ни один из его ttyUSB не отвечает на AT), а _DEVICE
		# выше мог подмениться AT-портом ДРУГОГО модема. Живые запросы гейтим по
		# тому, что действительно требуется - доступности самого mmcli.
		_PORT_OK=0
		mmcli -m "$_MMIDX" -K >/dev/null 2>&1 && _PORT_OK=1
	fi
fi

# Non-json (single-value) callers still expect the classic port guard: a live
# query on a missing port is meaningless. The json builder handles it per-field.
if [ "x$1" != "xjson" ]; then
	case "$1" in
		getsupported*) : ;;  # static, no port needed
		*)
			if [ "$_PORT_OK" != "1" ]; then
				echo "Port not found, quitting..."
				exit 0
			fi
			;;
	esac
fi

case $1 in
	"getinfo")
		getinfo
		;;
	"getsupportedbands")
		getsupportedbands
		;;
	"getsupportedbandsext")
		getsupportedbandsext
		;;
	"getbands")
		getbands
		;;
	"getbandsext")
		getbandsext
		;;
	"setbands")
		# Запись выполняется В ФОНЕ с отвязкой дескрипторов ИМЕННО НА ПОДОБОЛОЧКЕ.
		# Синхронно это не работает на медленном железе: перезапись маски плюс
		# перерегистрация модема укладываются в 30-секундный таймаут rpcd далеко
		# не всегда, и пользователь видит "Failed to set bands: XHR", хотя команда
		# отработала и диапазоны применились (наблюдалось на MT7628 + SLM770A).
		# Результат UI всё равно перечитывает отдельным запросом.
		[ -n "$2" ] && { ( setbands "$2" ) >/dev/null 2>&1 </dev/null & }
		;;
	"getsupportedbands5gnsa")
		getsupportedbands5gnsa
		;;
	"getsupportedbandsext5gnsa")
		getsupportedbandsext5gnsa
		;;
	"getbands5gnsa")
		getbands5gnsa
		;;
	"getbandsext5gnsa")
		getbandsext5gnsa
		;;
	"setbands5gnsa")
		[ -n "$2" ] && setbands5gnsa "$2"
		;;
	"getsupportedbands5gsa")
		getsupportedbands5gsa
		;;
	"getsupportedbandsext5gsa")
		getsupportedbandsext5gsa
		;;
	"getbands5gsa")
		getbands5gsa
		;;
	"getbandsext5gsa")
		getbandsext5gsa
		;;
	"setbands5gsa")
		[ -n "$2" ] && setbands5gsa "$2"
		;;
	"getsupportedmodes")
		getsupportedmodes
		;;
	"getmode")
		getmode
		;;
	"setmode")
		[ -n "$2" ] && setmode "$2"
		;;
	"getsupportedbands3g")
		getsupportedbands3g
		;;
	"getbands3g")
		getbands3g
		;;
	"setbands3g")
		[ -n "$2" ] && setbands3g "$2"
		;;
	"getcelllock")
		# ЧТО МЫ САМИ СТАВИЛИ. Нужно из-за поведения, проверенного на живом
		# FM350-GL: после перезагрузки модема привязка ПРОДОЛЖАЕТ ДЕЙСТВОВАТЬ, но
		# AT+EMMCHLCK? отвечает "0". Доказано так: модем остался на закреплённой
		# соте (EARFCN 1450, PCI 359), а стоило снять привязку явной командой -
		# ушёл на 100/480, свой обычный выбор. Показывать в такой момент «лока
		# нет» - врать пользователю: он видит одно, а модем делает другое.
		_cl_sec=$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')
		[ -n "$_cl_sec" ] && _cl_sec="m_$_cl_sec"
		_cl_now=$(getcelllock)
		if [ "$_cl_now" = "off" ] && [ -n "$_cl_sec" ]; then
			_cl_saved=$(uci -q get "5gmodem.$_cl_sec.celllock")
			# Отдаём запомненное, помечая источник: интерфейс объяснит, что модем
			# о привязке молчит, но она в силе.
			case "$_cl_saved" in
				arfcn\ *|cell\ *) printf '%s remembered\n' "$_cl_saved"; exit 0 ;;
			esac
		fi
		printf '%s\n' "$_cl_now"
		;;
	"get5gmode")
		get5gmode
		;;
	"getcaenabled")
		getcaenabled
		;;
	"set5gmode")
		# Как и привязка к соте: применяется через цикл режима полёта, дольше
		# 30-секундного таймаута rpcd - поэтому в фон с отвязкой дескрипторов.
		[ -n "$2" ] && { ( set5gmode "$2"; _reconnect_iface ) >/dev/null 2>&1 </dev/null & }
		;;
	"setcelllock")
		# Как и setbands - в фоне с отвязкой дескрипторов: привязка делается через
		# цикл режима полёта и в 30-секундный таймаут rpcd не укладывается.
		if [ -n "$2" ]; then
			# Запоминаем СВОЙ выбор до запуска: по нему потом отличим «модем
			# забыл сообщить» от «привязки действительно нет».
			_cl_sec=$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')
			if [ -n "$_cl_sec" ]; then
				_cl_sec="m_$_cl_sec"
				case "$2" in
					off) uci -q delete "5gmodem.$_cl_sec.celllock" 2>/dev/null ;;
					*)   uci -q set "5gmodem.$_cl_sec.celllock=$2 $3 $4" ;;
				esac
				uci -q commit 5gmodem
			fi
			( setcelllock "$2" "$3" "$4"; _reconnect_iface ) >/dev/null 2>&1 </dev/null &
		fi
		;;
	"getantports")
		getantports
		;;
	"json")
		. /usr/share/libubox/jshn.sh
		json_init
		json_add_string modem "$(getinfo)"
		MODES=$(getsupportedmodes)
		if [ "x$MODES" != "xUnsupported" ]; then
			# currentmode is a LIVE query - only when the port is reachable.
			# The modes list itself is static and always shown (recovery path).
			[ "$_PORT_OK" = "1" ] && json_add_string currentmode "$(getmode)"
			json_add_array modes
			for PAIR in $MODES; do
				json_add_object ""
				json_add_string id "${PAIR%%:*}"
				json_add_string label "${PAIR#*:}"
				json_close_object
			done
			json_close_array
		fi
		CL=$(getcelllock)
		if [ "x$CL" != "xUnsupported" ]; then
			json_add_string celllock "$CL"
		fi
		G5=$(get5gmode)
		if [ "x$G5" != "xUnsupported" ]; then
			json_add_string mode5g "$G5"
		fi
		CAE=$(getcaenabled)
		if [ "x$CAE" != "xUnsupported" ]; then
			json_add_string ca_enabled "$CAE"
		fi
		json_add_array supported
		T=$(getsupportedbands)
		if [ "x$T" != "xUnsupported" ]; then
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
		fi
		json_close_array
		json_add_array enabled
		T=$([ "$_PORT_OK" = "1" ] && getbands)
		if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
			for BAND in $T; do
				json_add_int "" $BAND
			done
		fi
		json_close_array

		# --- 3G: список готовых комбинаций (выпадающий список, не галочки) ---
		T3=$(getsupportedbands3g)
		if [ -n "$T3" ] && [ "x$T3" != "xUnsupported" ]; then
			json_add_array combos3g
			# По одной паре "id:подпись" на строку (подписи содержат пробелы).
			# БЕЗ пайпа: `echo | while read` крутится в ПОДОБОЛОЧКЕ, и вызовы
			# json_add_* не долетели бы до JSON родителя - массив вышел бы пустым.
			_OIFS="$IFS"; IFS='
'
			for LINE in $T3; do
				[ -n "$LINE" ] || continue
				json_add_object ""
				json_add_string id "${LINE%%:*}"
				json_add_string label "${LINE#*:}"
				json_close_object
			done
			IFS="$_OIFS"
			json_close_array
			[ "$_PORT_OK" = "1" ] && json_add_string current3g "$(getbands3g)"
		fi

		T=$(getsupportedbands5gnsa)
		if [ "x$T" != "xUnsupported" ]; then
			json_add_array supported5gnsa
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt5g $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
			json_close_array
			json_add_array enabled5gnsa
			T=$([ "$_PORT_OK" = "1" ] && getbands5gnsa)
			if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
				for BAND in $T; do
					json_add_int "" $BAND
				done
			fi
			json_close_array
		fi
		T=$(getsupportedbands5gsa)
		if [ "x$T" != "xUnsupported" ]; then
			json_add_array supported5gsa
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt5g $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
			json_close_array
			json_add_array enabled5gsa
			T=$([ "$_PORT_OK" = "1" ] && getbands5gsa)
			if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
				for BAND in $T; do
					json_add_int "" $BAND
				done
			fi
			json_close_array
		fi
		# Профиль может попросить показать в UI предупреждение, что смена диапазонов
		# кратко разорвёт соединение (у FM350 GTACT рвёт PDP, re-dial поднимает
		# заново - IP на ~15-20 c пропадает). Флаг задаётся в самом профиле
		# (_BAND_RECONNECT_WARN=1), чтобы не хардкодить модель в вебе.
		[ -n "$_BAND_RECONNECT_WARN" ] && json_add_boolean bandwarn 1
		json_dump
		;;
	"help")
		echo "Available commands:"
		echo " $0 getinfo"
		echo " $0 json"
		echo " $0 help"
		echo ""
		echo "for LTE modem"
		echo " $0 getsupportedbands"
		echo " $0 getsupportedbandsext"
		echo " $0 getbands"
		echo " $0 getbandsext"
		echo " $0 setbands \"<band list>\""
		echo ""
		echo "for 5G NSA modem"
		echo " $0 getsupportedbands5gnsa"
		echo " $0 getsupportedbandsext5gnsa"
		echo " $0 getbands5gnsa"
		echo " $0 getbandsext5gnsa"
		echo " $0 setbands5gnsa \"<band list>\""
		echo ""
		echo "for 5G SA modem"
		echo " $0 getsupportedbands5gsa"
		echo " $0 getsupportedbandsext5gsa"
		echo " $0 getbands5gsa"
		echo " $0 getbandsext5gsa"
		echo " $0 setbands5gsa \"<band list>\""
		;;
	*)
		echo -n "Modem: "
		getinfo
		echo -n "Supported LTE bands: "
		getsupportedbands
		echo -n "Enabled LTE bands: "
		getbands
		echo ""
		getsupportedbandsext
		T=$(getsupportedbands5gnsa)
		if [ "x$T" != "xUnsupported" ]; then
			echo -n "Supported 5G NSA bands: "
			getsupportedbands5gnsa
			echo -n "Enabled 5G NSA bands: "
			getbands5gnsa
			echo ""
			getsupportedbandsext5gnsa
		fi
		T=$(getsupportedbands5gsa)
		if [ "x$T" != "xUnsupported" ]; then
			echo -n "Supported 5G SA bands: "
			getsupportedbands5gsa
			echo -n "Enabled 5G SA bands: "
			getbands5gsa
			echo ""
			getsupportedbandsext5gsa
		fi
		;;
esac

exit 0
