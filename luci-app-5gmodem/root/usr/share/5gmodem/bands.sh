#!/bin/sh

#
# (c) 2022-2024 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2022-2024 modified by Rafał Wabik - IceG - From eko.one.pl forum
#

# Активный модем. По умолчанию - глобальный выбор из uci. Но восстановление
# бендов после перезагрузки (restorebands из hotplug) должно бить в КОНКРЕТНЫЙ
# модем, а не в тот, что сейчас активен на странице: на двухмодемном роутере это
# разные модемы. Поэтому env BANDS_ACTIVE_MODEM (usb-путь, напр. "2-1.4") имеет
# приоритет и прокидывает выбор через весь скрипт - профиль, AT-порт, маску,
# реконнект интерфейса считаем уже для него.
active_modem() {
	[ -n "$BANDS_ACTIVE_MODEM" ] && { printf '%s\n' "$BANDS_ACTIVE_MODEM"; return 0; }
	uci -q get 5gmodem.@5gmodem[0].active_modem
}

# Запомнить выбор диапазонов в секции ЕГО модема, чтобы восстановить после
# перезагрузки (FM350 и подобные сбрасывают маску на заводскую). $1 - суффикс
# домена ("" 4G / "5gnsa" / "5gsa"), $2 - список бендов или "default".
#   "default"/пусто -> поле удаляем: восстанавливать «все диапазоны» незачем, это
#   и есть то, к чему модем возвращается сам.
_persist_bands() {
	_pb_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
	[ "$_pb_sec" != "m_" ] || return 0
	case "$2" in
		default|'') uci -q delete "5gmodem.$_pb_sec.save_band$1" 2>/dev/null ;;
		*)          uci -q set "5gmodem.$_pb_sec.save_band$1=$2" ;;
	esac
	uci -q commit 5gmodem
	# Пользователь ЯВНО задал диапазоны сейчас - модем уже встаёт на них (setbands
	# применит + reboot_modem soft переподнимет). Восстанавливать в ЭТУ загрузку
	# нечего, поэтому ставим restore-маркер той же формы, что и hotplug. Без него
	# ifup, который порождает наш же reboot_modem soft, разбудил бы restorebands, и
	# тот сделал бы ЛИШНИЙ CFUN поверх смены бендов. На FM350 два CFUN подряд
	# вешают PDP-контекст ("context won't activate"), и модем остаётся без сети -
	# ровно этот регресс и наблюдался при смене бендов из UI.
	_pb_if=$(uci -q get "5gmodem.$_pb_sec.network")
	[ -n "$_pb_if" ] && : > "/tmp/5gmodem_bandrestore_$_pb_if" 2>/dev/null
}

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
# Стиль 3G-диапазонов: "combo" (по умолчанию) - готовые комбинации, id:подпись,
# одиночный выбор (Telit); "mask" - галочки произвольного набора, как LTE/NR
# (FM350: getsupportedbands3g отдаёт список бендов "1 2 4 5 8", getbands3g -
# включённые, setbands3g принимает список через пробел). json-билдер по этому
# флагу отдаёт combos3g/current3g ЛИБО supported3g/enabled3g.
bands3g_style() {
	echo "combo"
}

# Формат getsupportedbands3g: combo-стиль - ПО ОДНОЙ паре "id:подпись" НА СТРОКУ;
# mask-стиль - список номеров бендов через пробел (как getsupportedbands).
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
	_ri_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_ri_sec" ] || return
	_ri_if=$(uci -q get "5gmodem.m_$_ri_sec.network")
	[ -n "$_ri_if" ] || return
	# Это НАМЕРЕННЫЙ реконнект (смена 5G-режима/cell-lock/восстановление бендов), а
	# не холодный boot-attach. Ставим restore-маркер, чтобы порождённый нами ifup не
	# разбудил restorebands с лишним CFUN поверх (двойной CFUN вешает PDP FM350).
	: > "/tmp/5gmodem_bandrestore_$_ri_if" 2>/dev/null
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
	# ПРИЦЕЛЬНЫЙ подъём через ubus, а НЕ `ifup`.
	#
	# На части прошивок `ifup` тянет за собой ПОЛНУЮ перезагрузку конфигурации:
	# в журнале видно "hostapd: Reload all interfaces", и вместе с ней перетряхивает
	# ВСЕ интерфейсы, включая чужие. На двухмодемном роутере это роняло второй
	# модем, к которому мы даже не обращались (воспроизведено: из трёх прогонов
	# соседний интерфейс упал дважды - переживает перезагрузку он не всегда).
	# DOWN+UP, а не один `up`: после CFUN-цикла netifd считает интерфейс всё ещё
	# поднятым (у fibocom/xmm RNDIS-устройство не отваливается), и `up` на
	# up-интерфейсе - no-op, дозвон не повторяется -> IP есть, инета нет (регресс
	# 1.7.1 на FM350). down форсирует teardown прото, up - заново дозвон; оба
	# прицельные, глобального hostapd-reload нет (в отличие от ifup, который ронял
	# соседний модем). ifup - фолбэк.
	ubus call "network.interface.$_ri_if" down >/dev/null 2>&1
	sleep 3
	ubus call "network.interface.$_ri_if" up >/dev/null 2>&1 || ifup "$_ri_if" >/dev/null 2>&1
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


# Любая ЗАПИСЬ диапазонов/режима делает json-кэш устаревшим - сбрасываем его,
# чтобы следующее чтение пошло в порт за новой маской. get*/json - не трогаем.
case "$1" in set*|restorebands) rm -f /tmp/5gmodem_bands_* 2>/dev/null ;; esac

# CACHE-FIRST + фоновое обновление для json.
#
# json грузится ПРИ КАЖДОМ открытии страницы «Сеть» и синхронно лез в порт за
# маской диапазонов, стоя в очереди at_lock за опросом метрик - вклад в «холодный»
# тормоз. Но маска меняется ТОЛЬКО через setbands (эти ветки чистят кэш), поэтому
# json можно отдавать из кэша МГНОВЕННО, а обновлять в фоне.
#
# Обёртка, а не правка веток вывода: реальный json печатает штатный код ниже,
# запущенный как 'jsonrefresh'; здесь мы только кэшируем его вывод и решаем,
# идти ли в порт. Кэшируем лишь валидный JSON ('{...}'); ошибку/пусто - нет.
_BJ_REFRESH=""
[ "$1" = "jsonrefresh" ] && { _BJ_REFRESH=1; set -- json; }
if [ "$1" = "json" ] && [ -z "$_BJ_REFRESH" ]; then
	_BJAM=$(active_modem)
	_BJF="/tmp/5gmodem_bands_$_BJAM"
	_BJT=$(cat "$_BJF.t" 2>/dev/null)
	case "$_BJT" in ''|*[!0-9]*) _BJT="" ;; esac
	# ПРОТОКОЛ ИНТЕРФЕЙСА - часть валидности кэша, а не только время. От него
	# зависит признак readonly (см. гейт _BAND_VIA ниже): на kernel-протоколе
	# управление запрещено, под modemmanager - разрешено. Без этой проверки после
	# переключения qmi -> modemmanager до 5 минут отдавался старый снимок с
	# readonly=1, и UI продолжал советовать «переключитесь на ModemManager», хотя
	# пользователь уже переключился. Ровно это и наблюдалось.
	_BJP=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null).proto" 2>/dev/null)
	# ИДЕНТИЧНОСТЬ МОДЕМА - вторая линия обороны против чужого снимка. Файл keyed
	# путём, но если в него всё же попали данные другого модема (историческая
	# гонка active_modem, см. запись ниже) - имя не спасёт. Содержимое несёт своё
	# поле "modem": сверяем его с моделью активного модема из uci и при
	# расхождении считаем кэш промахом, а не отдаём чужие диапазоны.
	_BJMDL=$(uci -q get "5gmodem.m_$(echo "$_BJAM" | sed 's/[^A-Za-z0-9]/_/g').model" 2>/dev/null)
	_BJCM=$(sed -n 's/.*"modem": *"\([^"]*\)".*/\1/p' "$_BJF" 2>/dev/null)
	if [ -s "$_BJF" ] && [ -n "$_BJT" ] \
	   && [ "$_BJP" = "$(cat "$_BJF.p" 2>/dev/null)" ] \
	   && { [ -z "$_BJMDL" ] || [ -z "$_BJCM" ] || [ "$_BJMDL" = "$_BJCM" ]; } \
	   && [ "$(( $(cut -d. -f1 /proc/uptime) - _BJT ))" -lt 300 ]; then
		# Фонового обновления НЕ делаем: маска меняется только через setbands (она
		# чистит кэш), поэтому «протухнуть» сама не может, а refresh на каждый показ
		# грузил бы порт впустую и мешал опросу метрик.
		cat "$_BJF"
		exit 0
	fi
	# кэш-промах (первое открытие/протух) - считаем сейчас, синхронно, и кэшируем
	_o=$("$0" jsonrefresh 2>/dev/null)
	# ГОНКА АКТИВНОГО МОДЕМА. Имя файла ($_BJF) взято из active_modem ВЫШЕ, а
	# jsonrefresh - ОТДЕЛЬНЫЙ процесс, читающий active_modem ЗАНОВО. Если между
	# этими чтениями пользователь переключил вкладку модема (это переписывает
	# active_modem), подпроцесс соберёт данные ДРУГОГО модема, а мы запишем их в
	# файл со старым именем - и до 300 c страница показывала бы диапазоны чужого
	# модема (воспроизведено: у Telit блок бендов был от FM350). Поэтому кэшируем
	# ТОЛЬКО если active_modem не сменился за время обновления; иначе отдаём
	# результат как есть, но в кэш НЕ кладём - следующий показ пересчитает под
	# актуальный модем.
	_BJAM2=$(active_modem)
	case "$_o" in
		'{'*) if [ "$_BJAM2" = "$_BJAM" ]; then
		          printf '%s\n' "$_o" > "$_BJF.tmp" && mv "$_BJF.tmp" "$_BJF"
		          cut -d. -f1 /proc/uptime > "$_BJF.t"
		          # запоминаем протокол, при котором снят снимок (см. проверку выше)
		          printf '%s\n' "$_BJP" > "$_BJF.p"
		      fi
		      printf '%s\n' "$_o" ;;
		*)    printf '%s\n' "$_o" ;;
	esac
	exit 0
fi

# --- МОДЕМ БЕЗ AT-ПОРТОВ -----------------------------------------------------
# У HiLink-модема диапазоны читаются и меняются его же API (маска LTEBand в
# /api/net/net-mode), а не AT-командами. Профилей modemband для него нет и быть
# не может - перехватываем здесь, до выбора профиля.
_bs_am=$(active_modem)
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
			# 3G (WCDMA) и 2G (GSM) диапазоны Huawei - галочки (mask-стиль).
			# supported* из net-mode-list, enabled* из текущей NetworkBand.
			_sup3g=$("$_HL" supbands3g "$_bs_am" 2>/dev/null)
			_en3g=""; [ -n "$_sup3g" ] && _en3g=$("$_HL" getbands3g "$_bs_am" 2>/dev/null)
			_sup2g=$("$_HL" supbands2g "$_bs_am" 2>/dev/null)
			_en2g=""; [ -n "$_sup2g" ] && _en2g=$("$_HL" getbands2g "$_bs_am" 2>/dev/null)
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
			printf '], "enabled": [%s]' "$(echo $_en | tr ' ' ',')"
			if [ -n "$_sup3g" ]; then
				printf ', "supported3g": ['
				_f3=1
				for _b in $_sup3g; do
					[ "$_f3" = 1 ] || printf ','
					_f3=0
					printf '{"band":%s}' "$_b"
				done
				printf '], "enabled3g": [%s]' "$(echo $_en3g | tr ' ' ',')"
			fi
			if [ -n "$_sup2g" ]; then
				printf ', "supported2g": ['
				_f2=1
				for _b in $_sup2g; do
					[ "$_f2" = 1 ] || printf ','
					_f2=0
					printf '{"band":%s}' "$_b"
				done
				printf '], "enabled2g": [%s]' "$(echo $_en2g | tr ' ' ',')"
			fi
			printf ' }\n'
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
		setbands3g)
			"$_HL" setbands3g "$2" "$_bs_am"
			# Тот же сторож debug, что и у setbands: смена NetworkBand может
			# заставить модем перерегистрироваться и уронить USB-композицию.
			( sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null &
			exit 0 ;;
		setbands2g)
			"$_HL" setbands2g "$2" "$_bs_am"
			( sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null &
			exit 0 ;;
		*) echo "Unsupported"; exit 0 ;;
	esac
fi

RES="/usr/share/5gmodem/modemband"

# Multi-modem: load the band profile of the ACTIVE modem (by USB path), not of
# whichever USB device is enumerated first - otherwise band management operates
# on the wrong modem (both tabs showed/set the same bands).
_AMP=$(active_modem)
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
		# AT-порт берём у ТЕКУЩЕЙ секции ($_bs_at, вычислен из active_modem выше),
		# а не из глобального at_port: под BANDS_ACTIVE_MODEM глобальный принадлежит
		# другому модему, и CGMM ушёл бы не туда.
		_atp="$_bs_at"; [ -n "$_atp" ] || _atp=$(uci -q get 5gmodem.@5gmodem[0].at_port)
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
	# Порт ТЕКУЩЕЙ секции ($_bs_at из active_modem) в приоритете над глобальным
	# at_port: под BANDS_ACTIVE_MODEM глобальный - порт другого модема, и _DEVICE
	# указал бы не на тот. Без override оба совпадают.
	_ATP="$_bs_at"
	[ -n "$_ATP" ] || _ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
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
# mmcli-профиль на KERNEL-протоколе (mbim/qmi/ncm/...) НЕ УПРАВЛЯЕМ, но ЧИТАЕМ.
# Такой модем прячет от ModemManager инхибитор (mm-inhibit.sh) - иначе MM и
# uqmi/umbim дерутся за канал cdc-wdm. Применить бенды/режим без mmcli нельзя:
# в CLI libqmi у --nas-set-system-selection-preference нет TLV предпочтения
# диапазонов. А вот ПРОЧИТАТЬ можно напрямую по QMI - профиль умеет это через
# qmicli (см. _qmi_current_bands в modemband/05c690d6).
# Поэтому здесь НЕ глушим списки (статичные и так не зависят от mmcli), а
# помечаем состояние readonly: UI покажет привычные кнопки с подсветкой текущих
# диапазонов, но неактивными, и предложит переключить интерфейс на ModemManager.
# Раньше тут всё отдавалось как Unsupported - на тот момент qmicli-пути чтения
# ещё не существовало, и показывать было нечего.
if [ "$_BAND_VIA" = "mmcli" ]; then
	# Интерфейс ТЕКУЩЕЙ секции, не глобальный: под BANDS_ACTIVE_MODEM это разные.
	_IFACE=$(uci -q get "5gmodem.$_bs_sec.network")
	[ -n "$_IFACE" ] || _IFACE=$(uci -q get 5gmodem.@5gmodem[0].network)
	if [ "$(uci -q get "network.$_IFACE.proto" 2>/dev/null)" != "modemmanager" ]; then
		_BAND_READONLY=1
		# Живые чтения гейтим по доступности qmicli: он тут единственный источник.
		_PORT_OK=0
		[ -c "${_QWDM:-/dev/cdc-wdm0}" ] && command -v qmicli >/dev/null 2>&1 && _PORT_OK=1
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

# ОТПУСКАЕМ AT-ЗАМОК РАНЬШЕ, если профиль работает через ModemManager.
#
# Замок берётся в начале скрипта безусловно, и это правильно: выбор профиля выше
# в последнюю очередь спрашивает модель у самого модема (AT+CGMM), т.е. МОЖЕТ
# сходить в порт. Но дальше mmcli-профиль в AT-порт не ходит вовсе - диапазоны и
# режим он читает и пишет через mmcli/qmicli.
#
# Пока замок держался до конца, любая операция с диапазонами на таком модеме
# (напр. «Применить все диапазоны» у Compal) на всё своё время монополизировала
# порт, которого не касалась. Опрос метрик при этом не висит - он видит занятый
# замок и мгновенно отдаёт УСТАРЕВШИЙ снимок, поэтому со стороны это выглядело
# как замершие цифры: наблюдалось устаревание до ~18 секунд.
#
# Порядок захвата НЕ меняем (это трогало бы сериализатор целиком) - только
# освобождаем, как только стало известно, что порт больше не понадобится.
if [ "$_BAND_VIA" = "mmcli" ] && [ -n "$_bs_at" ]; then
	at_unlock
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
		#
		# ПРИМЕНЕНИЕ - ЗДЕСЬ ЖЕ, СТРОГО ПОСЛЕ ЗАПИСИ, а не отдельным вызовом из UI.
		# Раньше UI дёргал reboot_modem.sh сразу после этой команды - но она
		# фоновая и возвращается МГНОВЕННО, до записи маски: радио перезапускалось
		# на СТАРОМ наборе.
		#
		# ПЕРЕЗАПУСК НУЖЕН НЕ ВСЕМ. На SIM7600 (CNBP) маска применяется ВЖИВУЮ -
		# модем сам пере-камплю за секунды, - а CFUN=4->1 её, наоборот, ОТКАТЫВАЕТ
		# (проверено: снятый B7 возвращался после перезапуска, а без него модем
		# уходил с B7 на B3 сам). Такой профиль ставит _BANDS_APPLY_LIVE=1, и
		# перезапуск пропускается. Остальным (по умолчанию) радио перезапускаем.
		#
		# Выбор ЗАПОМИНАЕМ в секции модема (для восстановления после перезагрузки -
		# см. restorebands). Делаем до фонового применения: нужно намерение
		# пользователя ($2), а не то, что реально ляжет в маску.
		[ -n "$2" ] && { _persist_bands "" "$2"; ( setbands "$2" && { [ "$_BANDS_APPLY_LIVE" = 1 ] || /usr/share/5gmodem/reboot_modem.sh soft; } ) >/dev/null 2>&1 </dev/null & }
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
		# Перезапуск радио - в той же подоболочке после записи (см. setbands).
		[ -n "$2" ] && { _persist_bands 5gnsa "$2"; ( setbands5gnsa "$2" && { [ "$_BANDS_APPLY_LIVE" = 1 ] || /usr/share/5gmodem/reboot_modem.sh soft; } ) >/dev/null 2>&1 </dev/null & }
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
		[ -n "$2" ] && { _persist_bands 5gsa "$2"; ( setbands5gsa "$2" && { [ "$_BANDS_APPLY_LIVE" = 1 ] || /usr/share/5gmodem/reboot_modem.sh soft; } ) >/dev/null 2>&1 </dev/null & }
		;;
	"restorebands")
		# Восстановить сохранённый выбор диапазонов ПОСЛЕ перезагрузки модема.
		# Зовётся из hotplug (31-5gmodem-bands) с BANDS_ACTIVE_MODEM=<usb-путь> -
		# профиль/порт/маска выше уже посчитаны для НУЖНОГО модема. По каждому
		# домену сравниваем сохранённое с текущим и переписываем ТОЛЬКО то, что
		# отличается: модемам, которые маску не сбрасывают (NV), делать нечего -
		# сохранённое совпадёт с текущим, и мы их не трогаем.
		_rb_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
		_rb_changed=0
		# нормализация набора: только числа, по возрастанию, без повторов - чтобы
		# "20 3 7" и "3 7 20" считались одинаковыми, а "Unsupported"/мусор - пустыми.
		_rb_norm() { echo "$1" | tr ' ,' '\n\n' | grep -E '^[0-9]+$' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//'; }
		_rb_one() {  # $1 суффикс домена, $2 функция чтения, $3 функция записи
			_rb_saved=$(uci -q get "5gmodem.$_rb_sec.save_band$1")
			_rb_savedn=$(_rb_norm "$_rb_saved")
			[ -n "$_rb_savedn" ] || return 0
			# Пустое/нечисловое текущее = порт молчит или домен не поддержан: НЕ
			# трогаем, иначе пустое сравнение дало бы ложное «отличается» и лишний
			# CFUN на ровном месте.
			_rb_curn=$(_rb_norm "$("$2" 2>/dev/null)")
			[ -n "$_rb_curn" ] || return 0
			[ "$_rb_savedn" = "$_rb_curn" ] && return 0
			"$3" "$_rb_saved" && _rb_changed=1
		}
		# РЕЖИМ prepare зовётся из net-hotplug СРАЗУ на появление eth2 - а модем в
		# этот момент часто ещё НЕ отвечает на AT (getbands пуст), и без ожидания
		# prepare вышел бы вхолостую, а ifup дозвонился бы на всех бендах (ровно этот
		# баг и наблюдался на живой загрузке). Ждём готовности AT - непустой маски
		# LTE - до ~30 c. netifd после NETDEV_MISSING заблокирован и сам не дозвонится,
		# пока мы не сделаем ifup, поэтому ожидание ничего не роняет.
		if [ "$2" = "prepare" ]; then
			_pw=0
			while [ "$_pw" -lt 15 ]; do
				[ -n "$(_rb_norm "$(getbands 2>/dev/null)")" ] && break
				sleep 2; _pw=$((_pw + 1))
			done
		fi
		_rb_one ""     getbands       setbands
		_rb_one 5gnsa  getbands5gnsa  setbands5gnsa
		_rb_one 5gsa   getbands5gsa   setbands5gsa
		# РЕЖИМ prepare: только записать маску и выйти, БЕЗ CFUN и реконнекта -
		# дозвон сделает сам прото следом. Код возврата сообщает вызвавшему прото,
		# менялась ли маска: 0 = записали новую (прото должен идти ХОЛОДНЫМ дозвоном,
		# а не переиспользовать старый бирер на сброшенных бендах), 3 = уже совпадало
		# (можно fast-path). CGACT release в самом прото снимает возможный GTACT-затык.
		if [ "$2" = "prepare" ]; then
			if [ "$_rb_changed" = 1 ]; then
				logger -t 5gmodem "restorebands(prepare): маска записана до дозвона для $(active_modem)"
				exit 0
			fi
			exit 3
		fi
		if [ "$_rb_changed" = 1 ]; then
			logger -t 5gmodem "restorebands: восстановлены сохранённые диапазоны для $(active_modem)"
			# Применяем ПРИЦЕЛЬНО (вариант A): CFUN на порт нужного модема, затем
			# down/up ЕГО интерфейса (_reconnect_iface). reboot_modem.sh soft тут не
			# годится - его реконнект бьёт по глобально активному модему, а под
			# override это другой. Модемам с живым применением (_BANDS_APPLY_LIVE)
			# CFUN не делаем: он откатывает маску - им достаточно реконнекта.
			if [ "$_BANDS_APPLY_LIVE" != 1 ] && [ -n "$_DEVICE" ]; then
				sms_tool -d "$_DEVICE" at "AT+CFUN=4" >/dev/null 2>&1
				sleep 3
				sms_tool -d "$_DEVICE" at "AT+CFUN=1" >/dev/null 2>&1
			fi
			_reconnect_iface
		fi
		;;
	"getsupportedmodes")
		getsupportedmodes
		;;
	"getmode")
		getmode
		;;
	"setmode")
		# Как и смена диапазонов: применяется у части модемов ВЖИВУЮ (SIM7600 -
		# AT+CNMP берёт эффект сразу, а CFUN=4->1 его ОТКАТЫВАЕТ, проверено). Флаг
		# _BANDS_APPLY_LIVE из профиля решает, перезапускать ли радио. В фоне -
		# перерегистрация модема может не уложиться в таймаут rpcd.
		[ -n "$2" ] && { ( setmode "$2" && { [ "$_BANDS_APPLY_LIVE" = 1 ] || /usr/share/5gmodem/reboot_modem.sh soft; } ) >/dev/null 2>&1 </dev/null & }
		;;
	"getsupportedbands3g")
		getsupportedbands3g
		;;
	"getbands3g")
		getbands3g
		;;
	"setbands3g")
		# Как setbands: в ФОНЕ с отвязкой дескрипторов, и СТРОГО ПОСЛЕ записи -
		# soft-реконнект (GTACT рвёт PDP на FM350). Раньше реконнект дёргал UI
		# (setBands3gAT) - для combos Telit; теперь один путь для обоих стилей.
		[ -n "$2" ] && { ( setbands3g "$2" && { [ "$_BANDS_APPLY_LIVE" = 1 ] || /usr/share/5gmodem/reboot_modem.sh soft; } ) >/dev/null 2>&1 </dev/null & }
		;;
	"getcelllock")
		# ЧТО МЫ САМИ СТАВИЛИ. Нужно из-за поведения, проверенного на живом
		# FM350-GL: после перезагрузки модема привязка ПРОДОЛЖАЕТ ДЕЙСТВОВАТЬ, но
		# AT+EMMCHLCK? отвечает "0". Доказано так: модем остался на закреплённой
		# соте (EARFCN 1450, PCI 359), а стоило снять привязку явной командой -
		# ушёл на 100/480, свой обычный выбор. Показывать в такой момент «лока
		# нет» - врать пользователю: он видит одно, а модем делает другое.
		_cl_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
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
			_cl_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
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
		# Состояние читается, но применить его нельзя (см. гейт _BAND_VIA выше).
		# UI по этому признаку рисует кнопки неактивными и показывает подсказку
		# с предложением переключить интерфейс на ModemManager.
		[ "$_BAND_READONLY" = "1" ] && json_add_int readonly 1
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

		# --- 3G ---
		T3=$(getsupportedbands3g)
		if [ -n "$T3" ] && [ "x$T3" != "xUnsupported" ]; then
			if [ "$(bands3g_style)" = "mask" ]; then
				# MASK-стиль (FM350): галочки, как LTE/NR. supported3g = список
				# бендов, enabled3g = включённые. Строку 3G показываем, только если
				# UMTS-бенды вообще есть в текущем режиме (getsupportedbands3g не пуст).
				json_add_array supported3g
				for BAND in $T3; do
					case "$BAND" in ''|*[!0-9]*) continue ;; esac
					json_add_object ""
					json_add_int band "$BAND"
					json_close_object
				done
				json_close_array
				json_add_array enabled3g
				if [ "$_PORT_OK" = "1" ]; then
					for BAND in $(getbands3g); do
						case "$BAND" in ''|*[!0-9]*) continue ;; esac
						json_add_int "" "$BAND"
					done
				fi
				json_close_array
			else
				# COMBO-стиль (Telit): готовые комбинации, одиночный выбор.
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
