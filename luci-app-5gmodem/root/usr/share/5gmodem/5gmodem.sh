#!/bin/sh

#
# (c) 2010-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2021-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#


band4g() {
# see https://en.wikipedia.org/wiki/LTE_frequency_bands
	echo -n "B${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"4") echo " (1700 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"11") echo " (1500 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"17") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"19") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"21") echo " (1500 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"31") echo " (450 MHz)";;
		"32") echo " (1500 MHz)";;
		"34") echo " (2000 MHz)";;
		"37") echo " (1900 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"42") echo " (3500 MHz)";;
		"43") echo " (3700 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700 MHz)";;
		"67") echo " (700 MHz)";;
		"69") echo " (2600 MHz)";;
		"70") echo " (1700 MHz)";;
		"71") echo " (600 MHz)";;
		"72") echo " (450 MHz)";;
		"73") echo " (450 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"85") echo " (700 MHz)";;
		"87") echo " (410 MHz)";;
		"88") echo " (410 MHz)";;
		"103") echo " (700 MHz)";;
		"106") echo " (900 MHz)";;
		"*") echo "";;
	esac
}

band5g() {
# see https://en.wikipedia.org/wiki/5G_NR_frequency_bands
	echo -n "n${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"34") echo " (2100 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700/2100 MHz)";;
		"67") echo " (700 MHz)";;
		"70") echo " (2000 MHz)";;
		"71") echo " (600 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"77") echo " (3700 MHz)";;
		"78") echo " (3500 MHz)";;
		"79") echo " (4700 MHz)";;
		"80") echo " (1800 MHz)";;
		"81") echo " (900 MHz)";;
		"82") echo " (800 MHz)";;
		"83") echo " (700 MHz)";;
		"84") echo " (2100 MHz)";;
		"85") echo " (700 MHz)";;
		"86") echo " (1700 MHz)";;
		"89") echo " (850 MHz)";;
		"90") echo " (2500 MHz)";;
		"91") echo " (800/1500 MHz)";;
		"92") echo " (800/1500 MHz)";;
		"93") echo " (900/1500 MHz)";;
		"94") echo " (900/1500 MHz)";;
		"95") echo " (2100 MHz)";;
		"96") echo " (6000 MHz)";;
		"97") echo " (2300 MHz)";;
		"98") echo " (1900 MHz)";;
		"99") echo " (1600 MHz)";;
		"100") echo " (900 MHz)";;
		"101") echo " (1900 MHz)";;
		"102") echo " (6200 MHz)";;
		"104") echo " (6700 MHz)";;
		"105") echo " (600 MHz)";;
		"106") echo " (900 MHz)";;
		"109") echo " (700/1500 MHz)";;
		"257") echo " (28 GHz)";;
		"258") echo " (26 GHz)";;
		"259") echo " (41 GHz)";;
		"260") echo " (39 GHz)";;
		"261") echo " (28 GHz)";;
		"262") echo " (47 GHz)";;
		"263") echo " (60 GHz)";;
		"*") echo "";;
	esac
}

getdevicevendorproduct() {
	devname="$(basename $1)"
	case "$devname" in
		'wwan'*'at'*)
			devpath="$(readlink -f /sys/class/wwan/$devname/device)"
			T=${devpath%/*/*/*}
			if [ -e $T/vendor ] && [ -e $T/device ]; then
				V=$(cat $T/vendor)
				D=$(cat $T/device)
				echo "pci/${V/0x/}${D/0x/}"
			fi
			;;
		'ttyACM'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		'tty'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		*)
			devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
	esac
}

RES="/usr/share/5gmodem"

# --- Кэш метрик: снимок для тех, кому не нужен свежий опрос -------------------
#
# Полный опрос стоит ~0.6 c, и ЛЮБОЙ его вызов лезет в AT-порт, за который и так
# дерутся SMS, слоты и профили (при коллизии ответы перепутываются). Виджету на
# странице статуса свежесть до секунды не нужна - ему хватит последнего снимка.
#
#   5gmodem.sh json          - полный опрос (как раньше) + запись снимка
#   5gmodem.sh cached [сек]  - отдать снимок, если он свежее <сек> (по умолчанию
#                              15); иначе сделать полный опрос. Модем не трогаем
#                              вовсе, пока снимок свежий.
#
# Снимок пишется АТОМАРНО (tmp + mv): читатель никогда не увидит полфайла.
# Возраст считаем по /proc/uptime, а не date: у busybox `find -mmin` умеет
# только минуты, а /proc/uptime не врёт при скачках системного времени
# (тот же приём, что в listmodems.sh).
CACHE="/tmp/5gmodem_metrics.json"
STAMP="/tmp/5gmodem_metrics.stamp"
# ЧЕЙ снимок. Файл один на всю систему, а модемов может быть несколько, и
# активный меняется - вручную (switch) и сам (hotplug/resolve при втыкании или
# пропаже модема). Без пометки читатели получали ЧУЖИЕ данные: страница и 5gtop
# несколько секунд показывали прежний модем, а основной опрос успевал записать
# чужую модель в секцию нового - на вкладке появлялось "Telit Fibocom FM350-GL"
# (вендор от одного модема, модель от другого).
OWNER="/tmp/5gmodem_metrics.owner"

# Путь активного модема: им помечаем снимок и по нему же его проверяем.
_active_path() { uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null; }

uptime_s() { cut -d. -f1 /proc/uptime; }

# ОДИН ПИШУЩИЙ, МНОГО ЧИТАЮЩИХ.
#
# Опрос модема стоит ~3.8 c, и это почти вся задержка: обвязка rpcd добавляет
# 0.01 c (замерено). Но КОНКУРЕНЦИЯ дорога по-настоящему: когда в порт лезут
# двое, тот же опрос занимает 13.4 c вместо 3.8 - в три с половиной раза дольше.
# Поэтому в порт ходит РОВНО ОДИН процесс, а остальные читают снимок.
#
# Блокировка на каталоге - mkdir атомарен на любой ФС, в отличие от проверки
# существования файла. Протухшую (процесс убит) снимаем по возрасту.
LOCKDIR="/tmp/5gmodem_poll.lock"

# Отдать снимок, подставив в него реальный возраст.
# В сам файл поле "age" пишется нулём (в момент записи он и есть ноль), а здесь
# подменяется на фактический. Потребители читают ОБЩИЙ снимок, и без возраста
# застрявший опрос выглядел бы как живые, но неверные показания.
#
# ВАЖНО: пояснения держим ЗДЕСЬ, а не рядом с полем - блок вывода JSON печатается
# как есть, и любая строка с "#" внутри него уезжает прямо в ответ и ломает
# разбор. Я допустил это дважды: оба раза симптом был один - "quoted object
# property name expected" и разом опустевшие метрики на странице.
serve_cache() {
	_a="${1:-0}"
	sed "s/\"age\":\"[0-9]*\"/\"age\":\"$_a\"/" "$CACHE" 2>/dev/null || cat "$CACHE"
}

_snapshot_age() {   # возраст снимка в секундах, либо пусто
	[ -s "$CACHE" ] || return 1
	# Снимок ЧУЖОГО модема не годится ни на что: пусть считается отсутствующим,
	# тогда все ветки ниже сами уйдут в свежий опрос.
	_own=$(cat "$OWNER" 2>/dev/null)
	[ "$_own" = "$(_active_path)" ] || return 1
	_n=$(uptime_s); _t=$(cat "$STAMP" 2>/dev/null)
	case "$_t" in ''|*[!0-9]*) return 1 ;; esac
	_a=$((_n - _t)); [ "$_a" -ge 0 ] || return 1
	printf '%s' "$_a"
}

_take_lock() {
	if mkdir "$LOCKDIR" 2>/dev/null; then return 0; fi
	# Протухшая блокировка: опрос дольше 40 c означает, что писавший процесс умер
	# (сам опрос укладывается в 4-14 c даже на медленном железе).
	_lt=$(cat "$LOCKDIR/stamp" 2>/dev/null)
	case "$_lt" in ''|*[!0-9]*) _lt="" ;; esac
	if [ -n "$_lt" ] && [ "$(( $(uptime_s) - _lt ))" -gt 40 ]; then
		rm -rf "$LOCKDIR" 2>/dev/null
		mkdir "$LOCKDIR" 2>/dev/null && return 0
	fi
	return 1
}

# --- МОДЕМ БЕЗ AT-ПОРТОВ ------------------------------------------------------
#
# HiLink-модемы (Huawei E3372h и родня) не имеют ни AT-порта, ни cdc-wdm: весь
# код ниже к ним неприменим - опрашивать нечего и нечем. Их метрики берутся из
# HTTP-API самого модема; формат JSON тот же, поэтому страницы разницы не видят.
#
# Проверка ДО всего остального и делается по конфигу (kind=hilink), а не опросом:
# это одна строка uci, она не стоит ничего и не трогает порты.
_hl_sec="m_$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')"
if [ "$(uci -q get "5gmodem.$_hl_sec.kind")" = "hilink" ]; then
	# Кэш у этого пути свой: запрос по HTTP дешевле AT-опроса, но дёргать модем
	# на каждый чих всё равно не стоит - страница опрашивает метрики раз в 2 c.
	_hl_cache="/tmp/5gmodem_hilink_metrics"
	_hl_ttl="${2:-5}"
	case "$_hl_ttl" in ''|*[!0-9]*) _hl_ttl=5 ;; esac
	if [ -s "$_hl_cache" ] && [ -z "$(find "$_hl_cache" -mmin +1 2>/dev/null)" ] 	   && [ "$(( $(cut -d. -f1 /proc/uptime) - $(cat "$_hl_cache.t" 2>/dev/null || echo 0) ))" -lt "$_hl_ttl" ]; then
		cat "$_hl_cache"
		exit 0
	fi
	_hl_out=$("$RES/hilink.sh" json 2>/dev/null)
	case "$_hl_out" in
		'{'*)
			printf '%s\n' "$_hl_out" > "$_hl_cache.tmp" && mv "$_hl_cache.tmp" "$_hl_cache"
			cut -d. -f1 /proc/uptime > "$_hl_cache.t"
			printf '%s\n' "$_hl_out"
			;;
		# Модем не ответил - отдаём прошлый снимок, если он есть: пустой экран
		# хуже слегка устаревших цифр.
		*) [ -s "$_hl_cache" ] && cat "$_hl_cache" || echo '{"backend":"hilink"}' ;;
	esac
	exit 0
fi

if [ "$1" = "cached" ]; then
	_ttl="${2:-15}"
	case "$_ttl" in ''|*[!0-9]*) _ttl=15 ;; esac
	_age=$(_snapshot_age)
	if [ -n "$_age" ] && [ "$_age" -lt "$_ttl" ]; then
		serve_cache "$_age"
		exit 0
	fi
	# Снимок протух. Пробуем стать ТЕМ САМЫМ единственным опрашивающим.
	if ! _take_lock; then
		# Кто-то уже опрашивает. Ждать его бессмысленно: отдаём что есть - чуть
		# устаревшие данные лучше, чем секунды ожидания и вторая ходка в порт.
		# Возраст виден потребителю по stamp, он сам решит, показывать ли пометку.
		_a=$(_snapshot_age) && { serve_cache "$_a"; exit 0; }
		# снимка нет вовсе (первый запуск) - ждём чужой опрос, но недолго
		_w=0
		while [ "$_w" -lt 20 ]; do
			sleep 1; _w=$((_w + 1))
			_a=$(_snapshot_age) && { serve_cache "$_a"; exit 0; }
			[ -d "$LOCKDIR" ] || break
		done
		echo '{"error":"busy"}'
		exit 0
	fi
	uptime_s > "$LOCKDIR/stamp" 2>/dev/null
	trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT INT TERM HUP
	# блокировка наша - проваливаемся в полный опрос ниже
else
	# Полный опрос по явному запросу тоже под блокировкой: иначе два таких
	# вызова столкнутся в порту ровно так же, как раньше страница с терминалом.
	if _take_lock; then
		uptime_s > "$LOCKDIR/stamp" 2>/dev/null
		trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT INT TERM HUP
	else
		# Порт занят. Свежий снимок (моложе 3 c) - это ровно то, что сейчас
		# дописывает другой процесс; отдаём его вместо второй ходки в модем.
		_age=$(_snapshot_age)
		[ -n "$_age" ] && [ "$_age" -lt 3 ] && { serve_cache "$_age"; exit 0; }
	fi
fi

DEVICE=$($RES/detect.sh)
# Bounded probe: sms_tool has no timeout and blocks ~35s on a silent/DIAG port,
# so a wrong pinned port froze this whole page on every metrics poll (only
# fixable by editing the config by hand). If the port does not answer AT within
# a few seconds, treat it as not found - every sms_tool call below then fails
# instantly instead of hanging.
[ -n "$DEVICE" ] && ! "$RES/atprobe.sh" "$DEVICE" && DEVICE=""
if [ -z "$DEVICE" ]; then
	echo '{"error":"Device not found"}'
	exit 0
fi

O=""
if [ -e /usr/bin/sms_tool ]; then
	# Один round-trip на всё «ядро»: PIN, сигнал, оператор (буквенный+числовой),
	# CREG/CEREG (с =2, чтобы CEREG отдал TAC), номер (CNUM) и IMSI (CIMI).
	# Раньше COPS?, CEREG и CIMI дёргались ещё и отдельными вызовами - каждый
	# лишний AT-сеанс добавлял ~0.5-1 c к загрузке страницы.
	O=$(sms_tool -D -d $DEVICE at "AT+CPIN?;+CSQ;+COPS=3,0;+COPS?;+COPS=3,2;+COPS?;+CREG=2;+CREG?;+CEREG=2;+CEREG?;+CNUM;+CIMI")
	# ФОЛБЭК ДЛЯ МОДЕМОВ, НЕ ПЕРЕВАРИВАЮЩИХ ДЛИННУЮ СКЛЕЙКУ.
	# Двенадцать команд через ";" - это оптимизация на один round-trip, и на
	# Qualcomm/Fibocom она работает. Но встречаются модули (MeigLink SLM770A-R,
	# проверено вживую), которые на такую цепочку возвращают ТОЛЬКО ЭХО, без
	# единого ответа: страница показывала прочерки вместо сигнала, оператора и
	# режима, хотя те же команды поодиночке отвечают исправно.
	# Признак провала - в ответе нет "+CSQ:". Тогда добираем короткими группами
	# (по 2-3 команды - столько принимают и слабые модули), сохраняя формат $O.
	case "$O" in
		*"+CSQ:"*) : ;;
		*)
			O=$(sms_tool -D -d $DEVICE at "AT+CPIN?;+CSQ")
			O="$O
$(sms_tool -D -d $DEVICE at "AT+COPS=3,0;+COPS?")
$(sms_tool -D -d $DEVICE at "AT+COPS=3,2;+COPS?")
$(sms_tool -D -d $DEVICE at "AT+CREG=2;+CREG?")
$(sms_tool -D -d $DEVICE at "AT+CEREG=2;+CEREG?")
$(sms_tool -D -d $DEVICE at "AT+CNUM")
$(sms_tool -D -d $DEVICE at "AT+CIMI")"
			;;
	esac
else
	O=$(gcom -d $DEVICE -s $RES/info.gcom 2>/dev/null)
fi

getpath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		P=${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
		P=${devpath%/*}
		;;
	esac
}

# --- modemdefine - WAN config ---
CONFIG=modemdefine
MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [[ $MODEMZ -gt 1 ]]; then
	SEC=$(uci -q get modemdefine.@general[0].main_network)
fi
if [[ $MODEMZ -eq 0 ]]; then
	# Интерфейс берём У СЕКЦИИ АКТИВНОГО МОДЕМА, а глобальный ключ - только
	# запасной путь. Эти два значения могут разойтись (глобальный обновляет
	# switch, но не всякий, кто трогает active_modem), и тогда метрики показывали
	# IP ЧУЖОГО модема: наблюдалось - активен FM350, а в карточке его адрес
	# 192.168.43.2 от соседнего Huawei.
	SEC=$(uci -q get "5gmodem.m_$(uci -q get 5gmodem.@5gmodem[0].active_modem \
		| sed 's/[^A-Za-z0-9]/_/g').network")
	[ -n "$SEC" ] || SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
fi
if [[ $MODEMZ -eq 1 ]]; then
	SEC=$(uci -q get modemdefine.@modemdefine[0].network)
fi

# Интерфейс АКТИВНОГО модема из его собственной секции. Глобальная
# 5gmodem.@5gmodem[0].network часто пуста, и без этого шага управление доходило
# до фолбэка «первый интерфейс с модемным прото» - а он на роутере с ДВУМЯ
# модемами отдавал чужой: метрики и модель брались с активного модема, а iface и
# IP - с соседнего (наблюдалось: модель FM350, но iface=modem и адрес wwan0
# второго модема). Имя секции - USB-путь, где всё кроме букв и цифр заменено
# на "_": 2-1.4 -> m_2_1_4.
if [ -z "$SEC" ]; then
	_AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null | tr -c 'A-Za-z0-9' '_')
	[ -n "$_AMP" ] && SEC=$(uci -q get "5gmodem.m_${_AMP%_}.network" 2>/dev/null)
fi

if [ -z "$SEC" ]; then
	getpath $DEVICE
	PORIG=$P
	for DEV in /sys/class/tty/* /sys/class/usbmisc/*; do
		getpath "/dev/"${DEV##/*/}
		if [ "x$PORIG" == "x$P" ]; then
			SEC=$(uci show network | grep "/dev/"${DEV##/*/} | cut -f2 -d.)
			[ -n "$SEC" ] && break
		fi
	done
fi

# ModemManager / wwan modems: the interface uses a control-channel proto
# (modemmanager/qmi/mbim/ncm) and is not bound to a /dev tty, so the
# path-matching above misses it. Pick that interface directly.
if [ -z "$SEC" ]; then
	for PROTO in modemmanager qmi mbim ncm wwan; do
		S=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='$PROTO'\$/\1/p" | head -1)
		if [ -n "$S" ]; then
			SEC=$S
			break
		fi
	done
fi
# --- modemdefine config ---

CONN_TIME="-"
RX="-"
TX="-"

# Один вызов ifstatus на интерфейс (раньше его дёргали ~6 раз - каждый
# отдельный ubus-запрос ~0.5с = основной тормоз опроса). Парсим всё отсюда.
SECSTATUS=$(ifstatus "$SEC" 2>/dev/null)
NETUP=$(echo "$SECSTATUS" | grep "\"up\": true")
if [ -n "$NETUP" ]; then

		CT=$(uci -q -P /var/state/ get network.$SEC.connect_time)
		if [ -z $CT ]; then
			CT=$(echo "$SECSTATUS" | awk -F[:,] '/uptime/ {print $2}' | xargs)
		else
			UPTIME=$(cut -d. -f1 /proc/uptime)
			CT=$((UPTIME-CT))
		fi
		if [ ! -z $CT ]; then

			D=$(expr $CT / 60 / 60 / 24)
			H=$(expr $CT / 60 / 60 % 24)
			M=$(expr $CT / 60 % 60)
			S=$(expr $CT % 60)
			CONN_TIME=$(printf "%dd, %02d:%02d:%02d" $D $H $M $S)
			CONN_TIME_SINCE=$(date "+%Y%m%d%H%M%S" -d "@$(($(date +%s) - CT))")
			
		fi
		
		IFACE=$(echo "$SECSTATUS" | awk -F\" '/l3_device/ {print $4}')
		if [ -n "$IFACE" ]; then
			RX=$(ifconfig $IFACE | awk -F[\(\)] '/bytes/ {printf "%s",$2}')
			TX=$(ifconfig $IFACE | awk -F[\(\)] '/bytes/ {printf "%s",$4}')
		fi
fi

# CSQ
CSQ=$(echo "$O" | awk -F[,\ ] '/^\+CSQ/ {print $2}')

[ "x$CSQ" == "x" ] && CSQ=-1
if [ $CSQ -ge 0 -a $CSQ -le 31 ]; then
	CSQ_PER=$(($CSQ * 100/31))
else
	CSQ=""
	CSQ_PER=""
fi

# COPS numeric
# see https://mcc-mnc.com/
# Update: 11/11/2024 items: 3121
COPS=""
COPS_MCC=""
COPS_MNC=""
COPS_FROM_MODEM=0   # 1, если имя получено от самого модема, а не из mccmnc.dat
COPS_NUM=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,2/ {print $2}')
if [ -n "$COPS_NUM" ]; then
	COPS_MCC=${COPS_NUM:0:3}
	COPS_MNC=${COPS_NUM:3:3}
fi

TCOPS=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,0/ {print $2}')
# Некоторые модемы (напр. Compal RXM-G1) отдают имя оператора в UCS2-hex,
# т.е. "beeline" приходит как 006200650065006C0069006E0065. Настоящее имя
# содержит нешестнадцатеричные буквы, поэтому строку из ОДНИХ hex длиной
# кратно 4 считаем UCS2: латиницу (00XX) декодируем, иначе (кириллица и т.п.)
# отбрасываем в пользу mccmnc.dat-имени.
if [ -n "$TCOPS" ] && [ $(( ${#TCOPS} % 4 )) -eq 0 ] && echo "$TCOPS" | grep -qE '^[0-9A-Fa-f]+$'; then
	# Каждые 4 hex = один codepoint UCS2. Декодируем в UTF-8 весь BMP,
	# включая кириллицу ("Т-Мобайл" = 0422002D041C...), а не только латиницу -
	# иначе кириллическое имя MVNO терялось и подменялось хост-сетью Tele2.
	DEC=""
	for h in $(echo "$TCOPS" | sed 's/\(....\)/\1 /g'); do
		c=$((0x$h))   # busybox ash не понимает 16#, используем 0x
		if [ "$c" -lt 128 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' "$c")")"
		elif [ "$c" -lt 2048 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' $((192 | (c >> 6))))\\$(printf '%03o' $((128 | (c & 63))))")"
		else
			DEC="$DEC$(printf "\\$(printf '%03o' $((224 | (c >> 12))))\\$(printf '%03o' $((128 | ((c >> 6) & 63))))\\$(printf '%03o' $((128 | (c & 63))))")"
		fi
	done
	[ -n "$DEC" ] && TCOPS="$DEC"
fi
[ "x$TCOPS" != "x" ] && { COPS="$TCOPS"; COPS_FROM_MODEM=1; }

if [ -z "$COPS" ]; then
	if [ -n "$COPS_NUM" ]; then
		COPS=$(awk -F[\;] '/^'$COPS_NUM';/ {print $3}' $RES/mccmnc.dat | xargs)
		LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
	fi
fi
[ -z "$COPS" ] && COPS=$COPS_NUM

# Телефонный номер (MSISDN) из AT+CNUM, если SIM его хранит.
# Формат: +CNUM: "<alpha>","<number>",<type>[,...]  (type 145 = международный).
# Берём поле в кавычках, которое похоже на номер (5+ цифр, возможен '+'); alpha в
# UCS2-hex содержит буквы (E/B/F...) и под шаблон не попадает.
PHONE=$(echo "$O" | awk -F'"' '/^\+CNUM:/{for(i=1;i<=NF;i++){if($i ~ /^[+]?[0-9][0-9][0-9][0-9][0-9]+$/){print $i; exit}}}')
if [ -n "$PHONE" ] && [ "${PHONE#+}" = "$PHONE" ]; then
	echo "$O" | grep '^+CNUM:' | grep -q ',145' && PHONE="+$PHONE"
fi

case "$COPS" in
    *\ *) 
        COPS=$(echo "$COPS" | awk '{if(NF==2 && tolower($1)==tolower($2)){print $1}else{print $0}}')
        ;;
esac

isp_num="$COPS_MCC $COPS_MNC"
isp_numws="$COPS_MCC$COPS_MNC"
# Числовой код оператора уже получен батчем (AT+COPS? формат 2 == COPS_MCC+MNC),
# отдельный round-trip к модему не нужен. Используем как ключ mccmnc.dat.
isp="$isp_numws"

case "$COPS" in
    *[!0-9]* | '')
	# Non-numeric characters or is blank
        ;;
    *) 
        if [ "$COPS" = "$isp_num" ] || [ "$COPS" = "$isp_numws" ]; then
            if [ -n "$isp" ]; then
                COPS=$(awk -F[\;] '/^'"$isp"';/ {print $3}' $RES/mccmnc.dat | xargs)
                LOC=$(awk -F[\;] '/^'"$isp"';/ {print $2}' $RES/mccmnc.dat)
            fi
        fi
	;;
esac

# Финальная нормализация имени оператора.
# Раньше проверяли отсутствие латиницы (grep '[A-Za-z]') - но кириллическое
# имя (Т-Мобайл) латиницы не содержит и ошибочно считалось мусором, после чего
# подменялось хост-сетью из mccmnc.dat (Tele2). Теперь мусором считаем имя ТОЛЬКО
# из цифр/пробелов (напр. "0062003 0062003").
#
# Модем-MVNO то отдаёт свой бренд ("Т-Мобайл"), то мусор; mccmnc.dat знает лишь
# хост-сеть (Tele2). Поэтому хорошее буквенное имя запоминаем для этого кода
# оператора, а при мусоре берём последнее запомненное имя, и лишь если его нет -
# имя из mccmnc.dat.
# Идентификатор SIM (IMSI) - ключ кэшей оператора/SPN. Без него при горячей
# замене SIM показывался бы закэшированный старый оператор (поставили Билайн, а
# светится Т-Мобайл). При смене SIM IMSI меняется -> кэш инвалидируется.
# IMSI уже в батче (+CIMI отдаёт его отдельной строкой из одних цифр).
SIMID=$(echo "$O" | tr -d '\r' | grep -xE '[0-9]{14,16}' | head -1)

OPCACHE="/tmp/5gmodem_operator"
if [ -n "$COPS" ] && echo "$COPS" | grep -qE '^[0-9 ]+$'; then
	CACHED=""
	if [ -n "$SIMID" ] && [ -f "$OPCACHE" ] && [ "$(cut -f1 "$OPCACHE")" = "$SIMID" ]; then
		CACHED=$(cut -f2- "$OPCACHE")
	fi
	if [ -n "$CACHED" ]; then
		COPS="$CACHED"
	elif [ -n "$COPS_NUM" ]; then
		NAME=$(awk -F[\;] '/^'"$COPS_NUM"';/ {print $3}' "$RES/mccmnc.dat" | xargs)
		[ -n "$NAME" ] && COPS="$NAME"
	fi
elif [ "$COPS_FROM_MODEM" = "1" ] && [ -n "$SIMID" ] && [ -n "$COPS" ]; then
	# запоминаем только имя, полученное от самого модема (не из mccmnc.dat),
	# иначе кэш затёрся бы хост-сетью Tele2 при первом же мусорном чтении
	printf '%s\t%s\n' "$SIMID" "$COPS" > "$OPCACHE"
fi

# Имя оператора с SIM (EF_SPN, файл 6F46) - самое надёжное брендовое имя
# абонента. Для MVNO (Т-Мобайл / T-Mobile на сети Tele2) модем часто отдаёт
# мусор ("T0"), а числовой код 25020 указывает лишь на хост-сеть Tele2, тогда
# как на SIM записано настоящее "T-Mobile". Кэшируем по IMSI (не читаем CRSM
# каждый раз, но при замене SIM перечитываем); если модем не умеет CRSM или
# IMSI не прочитался - тихо пропускаем.
SPNCACHE="/tmp/5gmodem_spn"
SPN=""
if [ -n "$SIMID" ] && [ -f "$SPNCACHE" ] && [ "$(cut -f1 "$SPNCACHE")" = "$SIMID" ]; then
	SPN=$(cut -f2- "$SPNCACHE")
else
	# Ответ CRSM у разных модемов: с кавычками ("...") у Compal, БЕЗ кавычек у
	# Telit LM960 (+CRSM: 144,0,00542D...). Убираем кавычки и берём hex после
	# двух статус-байтов (sw1,sw2,), чтобы работало в обоих форматах.
	SPNHEX=$(sms_tool -d "$DEVICE" at "AT+CRSM=176,28486,0,0,17" 2>/dev/null | tr -d '\r"' \
		| sed -n 's/.*+CRSM:[^,]*,[^,]*,\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')
	if [ -n "$SPNHEX" ]; then
		# первый байт - условие отображения, пропускаем; далее имя (GSM7/ASCII)
		# до заполнителя FF. Печатаемые ASCII декодируем, старшие байты UCS2 (00)
		# и служебные - пропускаем.
		SPN=$(echo "$SPNHEX" | sed 's/^..//' | sed 's/\(..\)/\1 /g' | tr ' ' '\n' | while read b; do
			[ -z "$b" ] && continue
			{ [ "$b" = "FF" ] || [ "$b" = "ff" ]; } && break
			v=$((0x$b))   # busybox ash не понимает 16#, используем 0x
			[ "$v" -ge 32 ] && [ "$v" -lt 127 ] && printf "\\$(printf '%03o' "$v")"
		done)
		[ -n "$SPN" ] && [ -n "$SIMID" ] && printf '%s\t%s\n' "$SIMID" "$SPN" > "$SPNCACHE"
	fi
fi
# Определяем брендовое имя из SPN (если осмысленное). НЕ присваиваем COPS
# здесь: модем-специфичные скрипты (напр. Telit 1bc71040) ниже перезаписывают
# COPS именем сети из своих AT-команд. Поэтому применяем SPN В САМОМ КОНЦЕ,
# после источения профиля модема (см. блок перед выводом JSON).
SPN_NAME=""
if [ -n "$SPN" ] && ! echo "$SPN" | grep -qE '^[0-9 ]*$'; then
	# Если SPN совпадает (без учёта регистра) с именем сети из mccmnc.dat -
	# это обычный оператор: берём аккуратно оформленное имя из базы
	# ("beeline" -> "Beeline"). Если отличается - это MVNO, оставляем SPN
	# ("T-Mobile" вместо хост-сети "Tele2").
	MCCNAME=""
	[ -n "$COPS_NUM" ] && MCCNAME=$(awk -F[\;] '/^'"$COPS_NUM"';/ {print $3}' "$RES/mccmnc.dat" | xargs)
	if [ -n "$MCCNAME" ] && [ "$(echo "$SPN" | tr 'A-Z' 'a-z')" = "$(echo "$MCCNAME" | tr 'A-Z' 'a-z')" ]; then
		SPN_NAME="$MCCNAME"
	else
		SPN_NAME="$SPN"
	fi
fi


# operator location from temporary config
LOCATIONFILE=/tmp/location
if [ -e "$LOCATIONFILE" ]; then
	touch $LOCATIONFILE
	LOC=$(cat $LOCATIONFILE)
	if [ -n "$LOC" ]; then
		LOC=$(cat $LOCATIONFILE)
			if [[ $LOC == "-" ]]; then
				rm $LOCATIONFILE
				LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
				if [ -n "$LOC" ]; then
					echo "$LOC" > /tmp/location
				fi
			else
				LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
				if [ -n "$LOC" ]; then
					echo "$LOC" > /tmp/location
				fi
			fi
	fi
else
	case "$COPS_MCC$COPS_MNC" in
    		*[!0-9]* | '')
        	# Non-numeric characters or is blank
        	;;
    		*) 
        		if [ -n "$LOC" ]; then
            			LOC=$(awk -F[\;] '/^'"$COPS_MCC$COPS_MNC"';/ {print $2}' $RES/mccmnc.dat)
            			echo "$LOC" > /tmp/location
        		else
            			echo "-" > /tmp/location
        		fi
        	;;
	esac
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CPIN:/ {print $0;exit}' | xargs)
if [ -n "$T" ]; then
	[ "$T" == "+CPIN: READY" ] || REG=$(echo "$T" | cut -f2 -d: | xargs)
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CME ERROR:/ {print $0;exit}')
if [ -n "$T" ]; then
	case "$T" in
		"+CME ERROR: 10"*) REG="SIM not inserted";;
		"+CME ERROR: 11"*) REG="SIM PIN required";;
		"+CME ERROR: 12"*) REG="SIM PUK required";;
		"+CME ERROR: 13"*) REG="SIM failure";;
		"+CME ERROR: 14"*) REG="SIM busy";;
		"+CME ERROR: 15"*) REG="SIM wrong";;
		"+CME ERROR: 17"*) REG="SIM PIN2 required";;
		"+CME ERROR: 18"*) REG="SIM PUK2 required";;
		*) REG=$(echo "$T" | cut -f2 -d: | xargs);;
	esac
fi

# CREG
eval $(echo "$O" | busybox awk -F[,] '/^\+CREG/ {gsub(/[[:space:]"]+/,"");printf "T=\"%d\";LAC_HEX=\"%X\";CID_HEX=\"%X\";LAC_DEC=\"%d\";CID_DEC=\"%d\";MODE_NUM=\"%d\"", $2, "0x"$3, "0x"$4, "0x"$3, "0x"$4, $5}')
case "$T" in
	0*) REG="0";;
	1*) REG="1";;
	2*) REG="2";;
	3*) REG="3";;
	5*) REG="5";;
	6*) REG="6";;
	7*) REG="7";;
	*) REG="";;
esac

# EPS/data registration (CEREG) overrides a "SMS only" CS status. Many LTE data
# modems (e.g. Fibocom FM350-GL) register the CS/voice domain as "SMS only"
# (CREG 6/7) on every operator while the PS/data domain is fully registered and
# the connection works fine - showing "registered, SMS only" then just confuses
# the user. So when CS says SMS-only but CEREG says registered (1=home, 5=roam),
# report the data status instead.
# CS-статус СОХРАНЯЕМ ОТДЕЛЬНО, прежде чем подменить. Он не нужен для показа
# связи, но по нему видно, доступен ли голосовой домен: USSD - услуга именно
# этого домена, и при "SMS only" сеть её не даёт (проверено на MeigLink
# SLM770A-R: AT+CUSD=? отвечает "(0-2)", а любой запрос молчит при CREG 2,6).
# Без этого поля подсказка на вкладке USSD не смогла бы отличить «модем не
# умеет» от «сеть сейчас не даёт».
REG_CS="$REG"
if [ "$REG" = "6" ] || [ "$REG" = "7" ]; then
	CEREG_STAT=$(echo "$O" | busybox awk -F[,] '/^\+CEREG/{gsub(/[[:space:]"]+/,"");print $2;exit}')
	case "$CEREG_STAT" in
		1) REG="1";;
		5) REG="5";;
	esac
fi

# MODE
if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" == "x0" ]; then
#	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS/ {print $4;exit}' | xargs)
	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS: 0,2/ {print $4;exit}' | xargs)
fi
case "$MODE_NUM" in
	2*) MODE="UMTS";;
	3*) MODE="EDGE";;
	4*) MODE="HSDPA";;
	5*) MODE="HSUPA";;
	6*) MODE="HSPA";;
	7*) MODE="LTE";;
	 *) MODE="-";;
esac

# TAC - из CEREG, уже полученного батчем (там включён CEREG=2, поэтому поле TAC
# присутствует). Отдельный вызов at+cereg убран; к тому же прежний без CEREG=2
# возвращал "+CEREG: 0,1" без TAC, т.е. tac_hex всегда был пустым.
TAC=$(echo "$O" | awk -F[,] '/^\+CEREG/ {printf "%s", toupper($3)}' | sed 's/[^A-F0-9]//g')
if [ "x$TAC" != "x" ]; then
	TAC_HEX=$(printf %d 0x$TAC)
else
	TAC="-"
	TAC_HEX="-"
fi

CONF_DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
if echo "x$CONF_DEVICE" | grep -q "192.168."; then
	if grep -q "Vendor=1bbb" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/alcatel_hilink.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	if grep -q "Vendor=12d1" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/huawei_hilink.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	if grep -q "Vendor=19d2" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/zte.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	# Интерфейс берём У СЕКЦИИ АКТИВНОГО МОДЕМА, а глобальный ключ - только
	# запасной путь. Эти два значения могут разойтись (глобальный обновляет
	# switch, но не всякий, кто трогает active_modem), и тогда метрики показывали
	# IP ЧУЖОГО модема: наблюдалось - активен FM350, а в карточке его адрес
	# 192.168.43.2 от соседнего Huawei.
	SEC=$(uci -q get "5gmodem.m_$(uci -q get 5gmodem.@5gmodem[0].active_modem \
		| sed 's/[^A-Za-z0-9]/_/g').network")
	[ -n "$SEC" ] || SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
	SEC=${SEC:-wan}
else

# --- Модульный опрос + кэш статичных полей ---------------------------------
# $2 = список нужных секций (core,signal,ca). Пусто/"all" = все (обратная
# совместимость). Профили читают WANT_SIGNAL/WANT_CA, чтобы не дёргать AT/QMI
# для свёрнутых блоков страницы.
SECTIONS="${2:-all}"
WANT_SIGNAL=1; WANT_CA=1
case "$SECTIONS" in
	all|"") ;;
	*)
		case ",$SECTIONS," in *,signal,*) WANT_SIGNAL=1;; *) WANT_SIGNAL=0;; esac
		case ",$SECTIONS," in *,ca,*)     WANT_CA=1;;     *) WANT_CA=0;;     esac
		;;
esac

# Кэш статичных полей (модель/IMEI/прошивка/ICCID) - они не меняются, но
# опрашивались КАЖДЫЙ опрос (5 из 6 AT-вызовов = основные ~секунды). Ключ - USB-
# путь модема; при смене SIM (IMSI из батча != сохранённого) кэш сбрасывается.
_STKEY=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null | tr -c 'A-Za-z0-9' '_')
[ -n "$_STKEY" ] || _STKEY="$(basename "$DEVICE" 2>/dev/null)"
STATIC_CACHE="/tmp/5gmodem_static_$_STKEY"
if [ -n "$SIMID" ] && [ "$(cat "${STATIC_CACHE}.imsi" 2>/dev/null)" != "$SIMID" ]; then
	rm -f "${STATIC_CACHE}"_* 2>/dev/null
	printf '%s' "$SIMID" > "${STATIC_CACHE}.imsi"
fi
# at_static <key> <atcmd> : сырой ответ из кэша, иначе запрос + кэш.
at_static() {
	_cf="${STATIC_CACHE}_$1"
	[ -s "$_cf" ] && { cat "$_cf"; return; }
	sms_tool -d "$DEVICE" at "$2" 2>/dev/null | tee "$_cf"
}

if [ -e /usr/bin/sms_tool ]; then
	REGOK=0
	[ "x$REG" == "x1" ] || [ "x$REG" == "x5" ] || [ "x$REG" == "x6" ] || [ "x$REG" == "x7" ] && REGOK=1
	VIDPID=$(getdevicevendorproduct $DEVICE)
	if [ -e "$RES/modem/$VIDPID" ]; then
		# IFS СОХРАНЯЕМ И ВОССТАНАВЛИВАЕМ ВОКРУГ ПРОФИЛЯ.
		# Шестнадцать профилей переводят IFS в перевод строки для разбора сот и
		# НЕ возвращают обратно, а профиль подключается через "." - то есть в
		# нашем же окружении. Дальше пробел перестаёт быть разделителем, и любой
		# код ниже, полагающийся на разбиение по пробелам, тихо ломается: именно
		# так у FM350 отключился фильтр выбросов температуры (read клал всю
		# строку в первую переменную), и заметить это удалось только по журналу.
		# Чиним в ОДНОМ месте, а не в шестнадцати: так защищены и будущие профили.
		_SAVED_IFS="$IFS"
		case $(cat /tmp/sysinfo/board_name) in
			"zte,mf289f")
				. "$RES/modem/usb/19d21485"
				;;
			*)
				. "$RES/modem/$VIDPID"
				;;
		esac
		IFS="$_SAVED_IFS"
	fi
fi

fi

# Оба хелпера вырезают ВСЕ управляющие символы C0 (0x00-0x1F), а не только
# \r\n: у некоторых модемов (напр. DW5821e) разбор AT оставлял в значении
# сигнала «сырой» control-символ, который попадал прямо в JSON-строку и ронял
# парсер («Bad control character in string literal in JSON»). Числовые поля
# тоже эмитятся как строки в кавычках, поэтому чистить их безопасно и нужно.
# Очистка значения перед вставкой в JSON. Управляющие символы (0x00-0x1F) рвут
# JSON и приходят от модема при коллизии на AT-порту. Раньше КАЖДЫЙ вызов гонял
# внешний `tr` - а их за один опрос ~71, и это была самая дорогая часть скрипта
# (замерено: 71x tr ~0.17 c, почти как весь остальной опрос). tr нужен РЕДКО -
# только когда мусор реально есть; проверяем встроенным `case` (без fork).
# printf, а не echo: echo проглатывает значения вида "-n"/"-e" как флаги.
sanitize_string() {
	case "$1" in
		'') printf '%s\n' "-" ;;
		*[[:cntrl:]]*) printf '%s' "$1" | tr -d '\000-\037'; printf '\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}
sanitize_number() {
	case "$1" in
		'') printf '%s\n' "-" ;;
		*[[:cntrl:]]*) printf '%s' "$1" | tr -d '\000-\037'; printf '\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

# IP addresses of the modem network interface (for the main page).
# umbim/MBIM puts the address on a virtual <iface>_4 / <iface>_6 child, not on
# the parent, so read straight from the l3 device - works for umbim,
# modemmanager, qmi and plain static alike. ubus children are a fallback.
# IP-блок читает СВЕЖИЙ статус интерфейса (SECSTATUS считается раньше, до
# финализации SEC для некоторых конфигов, и мог быть для другого/пустого SEC).
IFSTAT=$(ifstatus "$SEC" 2>/dev/null)
L3DEV=$(echo "$IFSTAT" | awk -F\" '/l3_device/ {print $4; exit}')
IPADDR=""
IPADDR6=""
if [ -n "$L3DEV" ]; then
	IPADDR=$(ip -4 addr show dev "$L3DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
	IPADDR6=$(ip -6 addr show dev "$L3DEV" scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
fi
[ -z "$IPADDR" ]  && IPADDR=$(echo "$IFSTAT" | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR" ]  && IPADDR=$(ifstatus "${SEC}_4" 2>/dev/null | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(echo "$IFSTAT" | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(ifstatus "${SEC}_6" 2>/dev/null | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)

# Реальный протокол интерфейса модема (modemmanager/mbim/qmi/ncm/...). Раньше
# в JSON шла случайная переменная цикла $PROTO, из-за чего при modemmanager
# показывался mbim. Берём напрямую из uci выбранного интерфейса $SEC.
IFPROTO=$(uci -q get "network.$SEC.proto")
[ -n "$IFPROTO" ] && PROTO="$IFPROTO"

# Брендовое имя оператора с SIM (SPN) применяем В КОНЦЕ - после модем-скриптов,
# которые могли перезаписать COPS именем хост-сети (напр. Telit ставит "Tele2
# RU", тогда как на SIM записан бренд MVNO "T-Mobile").
[ -n "$SPN_NAME" ] && COPS="$SPN_NAME"

# MSISDN (номер телефона) - универсальный фолбэк для ВСЕХ модемов. AT+CNUM выше
# отдаёт номер на AT-модемах; если он пуст, а модем управляется ModemManager
# (напр. Compal, который на AT+CNUM молчит), берём номер из mmcli own-numbers.
# Так номер читается везде, где SIM его хранит, независимо от типа модема.
if [ -z "$PHONE" ] && command -v mmcli >/dev/null 2>&1; then
	_MI=$(/usr/share/5gmodem/modemswitch.sh mmindex 2>/dev/null)
	if [ -n "$_MI" ]; then
		PHONE=$(mmcli -m "$_MI" -K 2>/dev/null \
			| sed -n 's/^modem\.generic\.own-numbers[^:]*:[[:space:]]*//p' \
			| tr -d ' ' | grep -E '^[+]?[0-9]{5,}$' | head -1)
	fi
fi

# Разрешённое имя оператора кладём в кэш, читаемый переключателем приоритета
# (netpri.sh): у MBIM/QMI-модемов оператор часто доступен только здесь (числовой
# COPS + mccmnc.dat / UCS2), а не через отдельный AT+COPS у netpri.
# Имя модели, разобранное этим опросом, запоминаем в секции модема. USB-дескриптор
# часто бесполезен (Quectel EC21 = "Android", SimCom = "SimTech, Incorporated"), а
# VID:PID у SimCom один на 7100/7600/8200 - различить их можно только по AT+CGMM.
# Табы и «Приоритет интернета» читают это поле и показывают человеческое имя.
# Пишем только когда модель осмысленная и реально поменялась.
AMP_SEC=""
_amp=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
[ -n "$_amp" ] && AMP_SEC="m_$(echo "$_amp" | sed 's/[^A-Za-z0-9]/_/g')"
# ВАЛИДАЦИЯ ОБЯЗАТЕЛЬНА. AT-порт делят опрос метрик, simslot.sh и esim.sh; при
# столкновении ответ одной команды прилетает на чтение другой. Так в секцию уже
# попадало ЭХО ЧУЖОЙ КОМАНДЫ - "AT+SIMTYPE?" (её шлёт simslot.sh) - и висело там
# как имя модема: в интерфейсе показывалось «SimCom AT+SIMTYPE?». Разовая
# коллизия становилась ПОСТОЯННОЙ, потому что мы её сохраняли.
# Поэтому принимаем только правдоподобное имя: не эхо команды (AT.../+CME.../?),
# не ошибка, разумной длины.
_model_sane() {
	case "$1" in
		AT+*|AT^*|AT$*|at+*|at^*) return 1 ;;   # эхо AT-команды
		# эхо AT-команды и в «пробельной» форме: L850 с ATE1 при коллизии на общем
		# AT-порту отдавал "AT  4"/"AT+GTDUALSIM?" - раньше "AT " (пробел) проскакивал
		# мимо шаблонов выше и оседал как имя модема НАВСЕГДА.
		AT|AT[\ 0-9]*|at|at[\ 0-9]*) return 1 ;;
		*ERROR*|*error*) return 1 ;;
		*'?'*|*'='*|*'"'*) return 1 ;;          # синтаксис команды, не имя
		# ОТВЕТЫ чужих команд. Первая версия ловила только ЭХО (AT+...), и мусор
		# вида "Telit #BND: 0,18,A7E0BB0F38DF,42" или "Telit +CSQ: 23,4"
		# проскакивал в конфиг НАВСЕГДА (проверено). У AT-ответа опознаваемая
		# форма: префикс # или + и двоеточие после кода.
		*'#'*|*': '*) return 1 ;;
		+[A-Z]*|*' +'[A-Z]*) return 1 ;;
		'') return 1 ;;
	esac
	[ "${#1}" -ge 3 ] && [ "${#1}" -le 40 ] || return 1
	case "$1" in *[A-Za-z]*) return 0 ;; esac   # хоть одна буква
	return 1
}
if [ -n "$MODEL" ] && [ -n "$AMP_SEC" ] && _model_sane "$MODEL"; then
	[ "$(uci -q get "5gmodem.$AMP_SEC.model")" = "$MODEL" ] || {
		uci -q set "5gmodem.$AMP_SEC.model=$MODEL"
		uci -q commit 5gmodem
	}
fi

# ПОДМЕНА МОДЕМА, КОТОРУЮ НЕ ВИДНО ПО vid:pid.
#
# modemswitch.sh ловит замену сравнением vid:pid на USB-пути. Но два ОДИНАКОВЫХ
# модема (один вид, одна модель) при перестановке между разъёмами так не
# различаются: vid:pid совпадает, и секция продолжает считать, что железо то же.
# В итоге интерфейс и APN остаются привязаны к разъёму и достаются ЧУЖОЙ SIM.
#
# IMEI уникален для каждого устройства и уже прочитан этим опросом - значит
# различить их можно без единой лишней AT-команды. Запоминаем его в секции и
# сверяем: разошёлся - настройки относятся к прежнему модему и заведомо неверны.
#
# Сами НИЧЕГО НЕ УДАЛЯЕМ: опрос идёт в фоне, а тихо снести чужой APN и интерфейс -
# именно тот неочевидный сюрприз, которого быть не должно. Ставим метку и пишем
# в журнал; страница настроек модема покажет её и предложит пересоздать.
# IMEI читаем сами, если профиль модема его не дал (у части профилей запроса
# нет вовсе - например у MeigLink). Идём через кэш статики: команда уходит в
# порт ОДИН раз на модем, дальше берётся из файла, поэтому на стоимость опроса
# это не влияет.
if [ -z "$NR_IMEI" ] || [ "$NR_IMEI" = "-" ]; then
	NR_IMEI=$(at_static imei "AT+CGSN" 2>/dev/null | tr -d '\r' \
		| grep -oE '^[0-9]{14,16}$' | head -1)
fi

if [ -n "$AMP_SEC" ] && [ -n "$NR_IMEI" ]; then
	case "$NR_IMEI" in
		*[!0-9]*|'') : ;;                      # не IMEI - молчим
		*)
			_old_imei=$(uci -q get "5gmodem.$AMP_SEC.imei")
			if [ -z "$_old_imei" ]; then
				uci -q set "5gmodem.$AMP_SEC.imei=$NR_IMEI"
				uci -q commit 5gmodem
			elif [ "$_old_imei" != "$NR_IMEI" ]; then
				logger -t 5gmodem "modem swap on $(uci -q get 5gmodem.@5gmodem[0].active_modem): IMEI $_old_imei -> $NR_IMEI, settings may belong to the previous modem"
				uci -q set "5gmodem.$AMP_SEC.imei=$NR_IMEI"
				uci -q set "5gmodem.$AMP_SEC.imei_changed=1"
				uci -q commit 5gmodem
			fi
			;;
	esac
fi

# ЗАЩИТА ОТ ОТРАВЛЕНИЯ КЭША: $SEC берётся из 5gmodem.network, а $DEVICE - из
# 5gmodem.device/at_port. Если эти два поля разъехались по модемам (см. инвариант
# в modemswitch.sh), COPS прочитан с порта СОСЕДА, и запись в кэш этого
# интерфейса показала бы его оператора у обоих модемов. Пишем, только если порт
# действительно принадлежит модему интерфейса $SEC; иначе молчим - netpri.sh
# сделает собственный probe по стабильному USB-пути.
op_cache_iface() {
	[ -n "$DEVICE" ] || { printf '%s' "$SEC"; return; }
	_n=$(readlink -f "/sys/class/tty/$(basename "$DEVICE")/device" 2>/dev/null)
	while [ -n "$_n" ] && [ "$_n" != "/" ] && [ ! -f "$_n/idVendor" ]; do _n="${_n%/*}"; done
	[ -f "$_n/idVendor" ] || { printf '%s' "$SEC"; return; }
	_s=$(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.path='$(basename "$_n")'\$/\1/p" | head -1)
	[ -n "$_s" ] || { printf '%s' "$SEC"; return; }
	uci -q get "5gmodem.$_s.network"
}
if [ -n "$SEC" ] && [ -n "$COPS" ] && ! echo "$COPS" | grep -qE '^[0-9 ]*$'; then
	OPIF=$(op_cache_iface)
	[ -n "$OPIF" ] && printf '%s' "$COPS" > "/tmp/5gmodem_op_$OPIF" 2>/dev/null
fi

_TMP="$CACHE.$$"
cat > "$_TMP" <<EOF
{
"ipaddr":"$(sanitize_string "$IPADDR")",
"ipaddr6":"$(sanitize_string "$IPADDR6")",
"iface":"$(sanitize_string "$SEC")",
"conn_time":"$(sanitize_string "$CONN_TIME")",
"conn_time_sec":"$(sanitize_number "$CT")",
"conn_time_since":"$(sanitize_string "$CONN_TIME_SINCE")",
"rx":"$(sanitize_number "$RX")",
"tx":"$(sanitize_number "$TX")",
"modem":"$(sanitize_string "$MODEL")",
"mtemp":"$(sanitize_string "$TEMP")",
"mtherm":"$(sanitize_number "$THERM")",
"antports":"$(sanitize_string "$ANTPORTS")",
"firmware":"$(sanitize_string "$FW")",
"cport":"$(sanitize_string "$DEVICE")",
"protocol":"$(sanitize_string "$PROTO")",
"csq":"$(sanitize_number "$CSQ")",
"signal":"$(sanitize_number "$CSQ_PER")",
"operator_name":"$(sanitize_string "$COPS")",
"phone":"$(sanitize_string "$PHONE")",
"operator_mcc":"$(sanitize_string "$COPS_MCC")",
"operator_mnc":"$(sanitize_string "$COPS_MNC")",
"location":"$(sanitize_string "$LOC")",
"mode":"$(sanitize_string "$MODE")",
"registration":"$(sanitize_string "$REG")",
"registration_cs":"$(sanitize_string "$REG_CS")",
"simslot":"$(sanitize_string "$SSIM")",
"imei":"$(sanitize_string "$NR_IMEI")",
"imsi":"$(sanitize_string "$NR_IMSI")",
"iccid":"$(sanitize_string "$NR_ICCID")",
"lac_dec":"$(sanitize_number "$LAC_DEC")",
"lac_hex":"$(sanitize_string "$LAC_HEX")",
"tac_dec":"$(sanitize_number "$TAC_DEC")",
"tac_hex":"$(sanitize_string "$TAC_HEX")",
"tac_h":"$(sanitize_string "$T_HEX")",
"tac_d":"$(sanitize_number "$T_DEC")",
"cid_dec":"$(sanitize_number "$CID_DEC")",
"cid_hex":"$(sanitize_string "$CID_HEX")",
"pci":"$(sanitize_number "$PCI")",
"earfcn":"$(sanitize_number "$EARFCN")",
"pband":"$(sanitize_string "$PBAND")",
"s1band":"$(sanitize_string "$S1BAND")",
"s1pci":"$(sanitize_number "$S1PCI")",
"s1earfcn":"$(sanitize_number "$S1EARFCN")",
"s2band":"$(sanitize_string "$S2BAND")",
"s2pci":"$(sanitize_number "$S2PCI")",
"s2earfcn":"$(sanitize_number "$S2EARFCN")",
"s3band":"$(sanitize_string "$S3BAND")",
"s3pci":"$(sanitize_number "$S3PCI")",
"s3earfcn":"$(sanitize_number "$S3EARFCN")",
"s4band":"$(sanitize_string "$S4BAND")",
"s4pci":"$(sanitize_number "$S4PCI")",
"s4earfcn":"$(sanitize_number "$S4EARFCN")",
"s1rsrp":"$(sanitize_number "$S1RSRP")",
"s2rsrp":"$(sanitize_number "$S2RSRP")",
"s3rsrp":"$(sanitize_number "$S3RSRP")",
"s4rsrp":"$(sanitize_number "$S4RSRP")",
"pmimo":"$(sanitize_string "$PMIMO")",
"pmod":"$(sanitize_string "$PMOD")",
"s1mimo":"$(sanitize_string "$S1MIMO")",
"s1mod":"$(sanitize_string "$S1MOD")",
"s2mimo":"$(sanitize_string "$S2MIMO")",
"s2mod":"$(sanitize_string "$S2MOD")",
"s3mimo":"$(sanitize_string "$S3MIMO")",
"s3mod":"$(sanitize_string "$S3MOD")",
"s4mimo":"$(sanitize_string "$S4MIMO")",
"s4mod":"$(sanitize_string "$S4MOD")",
"age":"0",
"bandwidth":"$(sanitize_string "$BANDWIDTH")",
"enbid":"$(sanitize_string "$ENBID")",
"pathloss":"$(sanitize_string "$PATHLOSS")",
"txpower":"$(sanitize_string "$TXPOWER")",
"uecat":"$(sanitize_string "$UECAT")",
"cqi":"$(sanitize_string "$CQI")",
"volte":"$(sanitize_string "$VOLTE")",
"rscp":"$(sanitize_string "$RSCP")",
"ecio":"$(sanitize_string "$ECIO")",
"rsrp":"$(sanitize_string "$RSRP")",
"rsrq":"$(sanitize_string "$RSRQ")",
"rssi":"$(sanitize_string "$RSSI")",
"sinr":"$(sanitize_string "$SINR")"
}
EOF

# БЕЗ ПАЙПЛАЙНА. Первая версия писала снимок через `( cat <<EOF ) | tee файл` -
# и вызов через rpcd намертво упирался в его 30-секундный таймаут (проверено:
# 4 из 4), хотя напрямую в консоли отрабатывал за 0.64 c. rpcd ждёт EOF на
# stdout, а лишний процесс в пайплайне держал дескриптор. Пишем в файл, потом
# отдаём его - ни подоболочки, ни tee.
#
# Снимок публикуем, только если он ВАЛИДЕН: полуживой ответ (модем отвалился на
# середине опроса) не должен затирать последний хороший - виджеты читают кэш.
if [ -s "$_TMP" ] && jsonfilter -i "$_TMP" -e '@.modem' >/dev/null 2>&1; then
	cat "$_TMP"
	mv "$_TMP" "$CACHE"      # атомарно: читатель видит либо старый снимок, либо новый
	uptime_s > "$STAMP"
	# Помечаем, ЧЕЙ это снимок (см. OWNER выше). Пишем ПОСЛЕ mv: пока метки нет,
	# читатель считает снимок чужим и просто опросит сам - это безопасно.
	printf '%s' "$(_active_path)" > "$OWNER" 2>/dev/null
else
	cat "$_TMP" 2>/dev/null  # ответ отдаём в любом случае, но в кэш не кладём
	rm -f "$_TMP"
fi
exit 0

