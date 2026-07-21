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
# Путь активного модема: он же КЛЮЧ всех файлов снимка/замка.
_active_path() { uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null; }

# СНИМОК И ЗАМОК - ПО МОДЕМУ, А НЕ ОДИН НА ВСЕХ.
#
# Раньше был ОДИН файл-снимок и ОДИН замок-опросчик на всю систему. На двух
# модемах это ломало переключение: опрос модема B ждал глобальный замок за
# опросом A (хотя порты разные), а в единственном снимке несколько секунд лежали
# данные A - страница показывала ЧУЖОЙ модем и мешала IP/протоколы. Ключ по пути
# развязывает: у каждого модема свой снимок и своя очередь, опросы идут
# параллельно (AT ждёт serial, не CPU), переключение читает СВОЙ снимок мгновенно.
_MKEY=$(_active_path | tr -c 'A-Za-z0-9' '_')
[ -n "$_MKEY" ] || _MKEY="none"
CACHE="/tmp/5gmodem_metrics_$_MKEY.json"
STAMP="/tmp/5gmodem_metrics_$_MKEY.stamp"
LOCKDIR="/tmp/5gmodem_poll_$_MKEY.lock"

uptime_s() { cut -d. -f1 /proc/uptime; }

# ОДИН ПИШУЩИЙ, МНОГО ЧИТАЮЩИХ.
#
# Опрос модема стоит ~3.8 c, и это почти вся задержка: обвязка rpcd добавляет
# 0.01 c (замерено). Но КОНКУРЕНЦИЯ дорога по-настоящему: когда в порт лезут
# двое, тот же опрос занимает 13.4 c вместо 3.8 - в три с половиной раза дольше.
# Поэтому в порт ходит РОВНО ОДИН процесс, а остальные читают снимок.
#
# Блокировка на каталоге - mkdir атомарен на любой ФС, в отличие от проверки
# существования файла. Протухшую (процесс убит) снимаем по возрасту. Ключ - тот
# же путь модема (см. _MKEY выше): замок у каждого модема свой.

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
	# Владельца проверять НЕ НУЖНО: файл снимка назван по пути активного модема
	# (_MKEY), значит это по определению снимок ИМЕННО текущего модема.
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
# ВАЖНО: признака kind=hilink МАЛО. Такой модем может быть переведён в режим с
# AT-портами (debug), и тогда он обычный - у него есть всё, чего веб-API не даёт
# (TAC, диапазон, USSD). Через API идём, только если AT-порта нет.
_hl_sec="m_$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')"
_hl_at=$(uci -q get "5gmodem.$_hl_sec.at_port")
[ -n "$_hl_at" ] && [ -c "$_hl_at" ] && _hl_at="yes" || _hl_at=""
if [ "$(uci -q get "5gmodem.$_hl_sec.kind")" = "hilink" ] && [ -z "$_hl_at" ]; then
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

# СЕРИАЛИЗАЦИЯ ДОСТУПА К ПОРТУ. Блокировка выше (LOCKDIR) разводит только опрос
# с опросом, но в тот же tty ходят bands.sh, simslot.sh, esim.sh, smsbridge.sh,
# collect.sh и консоль - именно на ЭТОМ наложении ответы перепутывались (на
# AT#MONI приходил +COPS чужой команды, ATI возвращал +CPIN/+CSQ).
#
# Берём ДО atprobe.sh: он тоже ходит в порт. Не дождались - отдаём снимок:
# устаревшие данные честнее перемешанных, а отличить перепутанный ответ от
# «модем молчит» потом невозможно.
. "$RES/atlock.sh"
. "$RES/lib.sh"   # opname_brand - бренд MVNO по IMSI
if [ -n "$DEVICE" ] && ! at_lock "$DEVICE" 10; then
	_age=$(_snapshot_age)
	[ -n "$_age" ] && { serve_cache "$_age"; exit 0; }
	# Снимка нет вовсе (первый запуск) - опрашиваем без блокировки: пустая
	# страница хуже, чем данные с риском смешения.
fi

# ПОРТ ДОЛЖЕН ПРИНАДЛЕЖАТЬ ЭТОМУ МОДЕМУ.
#
# detect.sh при неудаче отдаёт ЛЮБОЙ отвечающий tty, а на роутере с двумя
# модемами это порт ЧУЖОГО. Живой случай: воткнули Huawei в режиме HiLink (своих
# AT-портов у него нет), active_modem уже переключился на него, а kind=hilink
# секция получить не успела - опрос пошёл в порт FM350, прочитал его модель и
# записал «Fibocom FM350-GL» в секцию Huawei. Дальше страница показывала чушь.
#
# Проверяем по списку портов ЭТОГО USB-пути. Осторожно: если модема нет в
# listmodems (нестандартная композиция, старый конфиг), НЕ судим - иначе
# сломаем метрики там, где раньше работало.
if [ -n "$DEVICE" ]; then
	_own_path=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null)
	if [ -n "$_own_path" ]; then
		_own_json=$("$RES/listmodems.sh" 2>/dev/null)
		if printf '%s' "$_own_json" | jsonfilter -e "@[@.path=\"$_own_path\"].path" >/dev/null 2>&1; then
			_own_ttys=$(printf '%s' "$_own_json" \
				| jsonfilter -e "@[@.path=\"$_own_path\"].tty[*]" 2>/dev/null | tr '\n' ' ')
			case " $_own_ttys " in
				*" $DEVICE "*) : ;;
				*) logger -t 5gmodem "порт $DEVICE не принадлежит модему $_own_path - опрос пропускаем"
				   DEVICE="" ;;
			esac
		fi
	fi
fi

# Bounded probe: sms_tool has no timeout and blocks ~35s on a silent/DIAG port,
# so a wrong pinned port froze this whole page on every metrics poll (only
# fixable by editing the config by hand). If the port does not answer AT within
# a few seconds, treat it as not found - every sms_tool call below then fails
# instantly instead of hanging.
[ -n "$DEVICE" ] && ! "$RES/atprobe.sh" "$DEVICE" && DEVICE=""
if [ -z "$DEVICE" ]; then
	# Порт не ответил на atprobe. Это ЧАСТО ЛОЖНО: порт на миг занят/медленный
	# (особенно на слабом мобильном заходе, где всё грузится разом) или модем
	# коротко переперечислился. Если есть НЕ СЛИШКОМ старый снимок этого модема -
	# отдаём его, а не пугаем «модема нет»: пользователь видел мелькание сообщения
	# на 2-3 c при заходе на «Сеть». Снимок старше 30 c - модем, вероятно, реально
	# пропал, тогда честно сообщаем. Свежие снимки (< ttl) уже отдал cached выше.
	_age=$(_snapshot_age)
	[ -n "$_age" ] && [ "$_age" -lt 30 ] && { serve_cache "$_age"; exit 0; }
	echo '{"error":"Device not found"}'
	exit 0
fi

# СТОРОЖ НА ВСЕ ВЫЗОВЫ sms_tool. У sms_tool нет таймаута: на подвисшем (или
# занятом чужим опросом) порту он блокирует ~35 c. Под сериализатором это держит
# at_lock, и ВСЯ страница ждёт за одним зависшим опросом - пользователь видел
# «данные не обновлялись 33/56 c, потом пошло». atprobe ограничивал только
# НАЧАЛЬНУЮ пробу, а сам опрос и вызовы из профиля были без предела.
#
# Переопределяем sms_tool ФУНКЦИЕЙ: любой вызов (и здесь, и в profile-файлах,
# что подключаются через "." ниже) идёт со сторожем. Не ответил за 8 c - убиваем,
# отдаём что успело. Реальный бинарь - по абсолютному пути. Счётчик в имени
# temp-файла: вызовы последовательны, но так надёжнее при вложенности.
_st_n=0
sms_tool() {
	_st_n=$((_st_n + 1)); _stf="/tmp/5gmodem_st.$$.$_st_n"
	# ЗАКРЫВАЕМ fd лока (8) и хотплаг-лока (9) и у sms_tool, и у сторожа: обоим
	# нужен только сам serial-порт (-d), а НЕ файл блокировки. Иначе они держат
	# его OFD, и осиротевший `sleep` сторожа продолжает держать лок ещё до 8 c
	# ПОСЛЕ выхода опроса - следующий опрос упирался в него на ~8 c (наблюдалось:
	# первый холодный опрос 1 c, каждый следующий 8-9 c).
	/usr/bin/sms_tool "$@" > "$_stf" 2>/dev/null 8>&- 9>&- &
	_stp=$!
	( exec 8>&- 9>&-; sleep 8; kill "$_stp" 2>/dev/null ) >/dev/null 2>&1 </dev/null & _stk=$!
	wait "$_stp" 2>/dev/null; kill "$_stk" 2>/dev/null; wait "$_stk" 2>/dev/null
	cat "$_stf" 2>/dev/null; rm -f "$_stf"
}

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
	# Фолбэк ТОЛЬКО для эхо-модемов (ответ есть, но без +CSQ). При ПУСТОМ $O
	# порт подвис и опрос вылетел по сторожу - гонять ещё 7 команд по 8 c
	# бессмысленно и вредно (те самые «минуты ожидания»). Пусто -> пропускаем.
	case "$O" in
		*"+CSQ:"*) : ;;
		"") : ;;
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
	# ПОРТ ПОДВИС ПОСРЕДИ ОПРОСА (ядро вылетело по сторожу, ответ пуст, хотя
	# atprobe вначале прошёл). Дальше идёт профиль - ещё несколько вызовов
	# sms_tool по 8 c: на мёртвом порту это сложится в те самые «десятки секунд».
	# Не продолжаем: отдаём ПРОШЛЫЙ снимок этого же модема (владелец совпадает) и
	# выходим, освобождая at_lock. Свежего снимка нет (первый заход) - идём
	# дальше как есть, покажем что успели.
	if [ -z "$O" ]; then
		_wg=$(_snapshot_age) && {
			logger -t 5gmodem "опрос $DEVICE подвис - отдаю прошлый снимок (${_wg}c)"
			serve_cache "$_wg"; exit 0
		}
	fi
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
	# $TAC из +CEREG - уже ШЕСТНАДЦАТЕРИЧНЫЙ. Раньше здесь стояло
	# TAC_HEX=$(printf %d 0x$TAC), т.е. в поле *_HEX клался ДЕСЯТИЧНЫЙ результат,
	# а TAC_DEC не заполнялся вовсе - в снимке выходило tac_hex="136" (на самом
	# деле десятичное от 0x88) при пустом tac_dec="-". Раскладываем по местам.
	TAC_HEX="$TAC"
	TAC_DEC=$(printf %d 0x$TAC 2>/dev/null)
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
# РОУМИНГ ВНУТРИ СТРАНЫ - НЕ РОУМИНГ.
#
# Модем считает роумингом любую сеть, чей код не совпадает с домашним кодом
# симки. Для MVNO это ЛОЖНАЯ тревога: T-Mobile (250-62) работает НА СЕТИ Tele2
# (250-20), и модем рапортует "+CREG: 2,5" при том, что абонент дома и платит
# по домашнему тарифу. Прошивка самого Huawei это понимает - в её API cellroam=0
# при том же состоянии; а вот AT-статус врёт.
#
# Правило: совпал MCC (страна) - показываем как дом. Роуминг для пользователя -
# это про другой тариф, а MVNO на своей хост-сети тарифицируется как дом;
# национальный роуминг в РФ отменён с 2017 года. Заодно это выравнивает
# поведение разных модемов с одной и той же симкой: Telit рапортовал "дом",
# Huawei - "роуминг".
#
# Коды роуминга: 5 (registered, roaming), 7 (SMS only, roaming),
# 10 (CSFB not preferred, roaming). Домашние аналоги: 1, 6, 9.
case "$REG" in
	5|7|10)
		_sim_mcc=$(printf '%s' "$SIMID" | cut -c1-3)
		case "$_sim_mcc" in
			''|*[!0-9]*) : ;;
			*)
				if [ -n "$COPS_MCC" ] && [ "$COPS_MCC" = "$_sim_mcc" ]; then
					case "$REG" in
						5)  REG=1 ;;
						7)  REG=6 ;;
						10) REG=9 ;;
					esac
					logger -t 5gmodem "сеть $COPS_NUM той же страны, что и SIM ($_sim_mcc) - роуминг не показываем"
				fi
				;;
		esac
		;;
esac

_PREV_IMSI=$(cat "${STATIC_CACHE}.imsi" 2>/dev/null)
if [ -n "$SIMID" ] && [ "$_PREV_IMSI" != "$SIMID" ]; then
	rm -f "${STATIC_CACHE}"_* 2>/dev/null
	printf '%s' "$SIMID" > "${STATIC_CACHE}.imsi"
fi

# ПЕРЕПОДБОР APN ПРИ СМЕНЕ СИМКИ - ПО ПЕРСИСТЕНТНОМУ КЛЮЧУ (IMSI в секции).
#
# Своего hotplug-события у смены SIM нет: модем с шины не уходит. Раньше триггер
# сравнивал IMSI с файлом в /tmp - но смена eSIM-профиля гонит модем через
# жёсткий ребут (CFUN=1,1), resolve чистит /tmp-кэш, и ПЕРВЫЙ опрос видел пустой
# prev-IMSI, принимал смену за «первый опрос после загрузки» и APN не трогал.
# Живой случай: включили eSIM Tele2, а в интерфейсе осталось "tt" от прежней
# T-Mobile. Причём сеть у обеих одна (Tele2 - хост MVNO), по коду сети смены не
# видно - видно только по IMSI самой симки.
#
# Ключ храним В СЕКЦИИ модема: переживает и ребут модема, и очистку /tmp. Пустой
# apn_imsi у уже настроенного модема - это ПЕРВАЯ встреча с симкой (обновились со
# старой версии или свежая установка): один раз подберём и запомним.
if [ -n "$SIMID" ]; then
	_apn_sec="$_hl_sec"
	[ -n "$(uci -q get "5gmodem.$_apn_sec" 2>/dev/null)" ] || _apn_sec=""
	if [ -n "$_apn_sec" ] \
	   && [ "$(uci -q get "5gmodem.$_apn_sec.apn_mode")" != "manual" ] \
	   && [ "$(uci -q get "5gmodem.$_apn_sec.apn_imsi")" != "$SIMID" ]; then
		_SIM_IF=$(uci -q get "5gmodem.$_apn_sec.network" 2>/dev/null)
		[ -n "$_SIM_IF" ] || _SIM_IF=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
		# Дебаунс: опрос идёт раз в пару секунд, а autoapn — секунды. Без метки
		# он запускался бы пачкой, пока первый не допишет apn_imsi.
		_apn_stamp="/tmp/5gmodem_autoapn_$_apn_sec"
		if [ -n "$_SIM_IF" ] && { [ ! -f "$_apn_stamp" ] || [ -n "$(find "$_apn_stamp" -mmin +1 2>/dev/null)" ]; }; then
			: > "$_apn_stamp"
			logger -t 5gmodem "смена SIM (IMSI) на $_SIM_IF - переподбираем APN"
			# unset _AT_LOCK_HELD + закрыть fd лока: этот фон ОТДЕЛЯЕТСЯ и может
			# взять at_lock уже ПОСЛЕ нашего выхода - он должен захватывать лок
			# сам, а не думать, что его держит (уже мёртвый) предок.
			( unset _AT_LOCK_HELD; eval "exec $AT_LOCK_FD>&-" 2>/dev/null
			  /usr/share/5gmodem/modemswitch.sh autoapn "$_SIM_IF" ) \
				>/dev/null 2>&1 </dev/null &
		fi
	fi
fi
# at_static <key> <atcmd> [шаблон проверки] : сырой ответ из кэша, иначе запрос.
#
# ПРОВЕРЯЕМ ПЕРЕД ЗАПИСЬЮ В КЭШ. Раньше сохранялось что угодно, и один-
# единственный столкнувшийся обмен портил значение НАВСЕГДА: кэш статики не
# протухает, а в файл IMEI живьём попал ответ чужой команды -
#   5gmodem_static_1_1__imei: «at#bnd=? #BND: (0),(0-11,17,18),...»
# после чего IMEI показывался прочерком, сколько ни перезапрашивай.
# Очередь к порту (atlock.sh) делает такие столкновения редкими, но «редко» для
# вечного кэша недостаточно: одного раза хватает, чтобы сломать поле навсегда.
at_static() {
	_cf="${STATIC_CACHE}_$1"
	[ -s "$_cf" ] && { cat "$_cf"; return; }
	_out=$(sms_tool -d "$DEVICE" at "$2" 2>/dev/null)
	printf '%s' "$_out"
	# Шаблон не задан - поведение прежнее (кэшируем непустой ответ).
	if [ -n "$3" ]; then
		printf '%s' "$_out" | tr -d '\r' | grep -qE "$3" || return 0
	fi
	[ -n "$_out" ] && printf '%s' "$_out" > "$_cf"
	return 0
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

# У HiLink-модема адрес интерфейса - это ЛОКАЛЬНАЯ сеть модема (192.168.43.2):
# модем сам держит IP-стек и NAT-ит, а роутер сидит за ним. Настоящий WAN-адрес
# оператора знает только модем - берём его AT-командой AT+CGPADDR (в debug-режиме
# порт есть). Иначе в карточке светился бы 192.168.43.x, а не адрес в сети.
if [ "$(uci -q get "5gmodem.$_hl_sec.kind")" = "hilink" ] && [ -n "$DEVICE" ]; then
	_wan=$(sms_tool -d "$DEVICE" at "AT+CGPADDR" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CGPADDR: *[0-9]*, *"\([0-9.]*\)".*/\1/p' | grep -v '^0\.0\.0\.0$' | head -1)
	[ -n "$_wan" ] && IPADDR="$_wan"
fi

# Реальный протокол интерфейса модема (modemmanager/mbim/qmi/ncm/...). Раньше
# в JSON шла случайная переменная цикла $PROTO, из-за чего при modemmanager
# показывался mbim. Берём напрямую из uci выбранного интерфейса $SEC.
IFPROTO=$(uci -q get "network.$SEC.proto")
[ -n "$IFPROTO" ] && PROTO="$IFPROTO"

# Брендовое имя оператора с SIM (SPN) применяем В КОНЦЕ - после модем-скриптов,
# которые могли перезаписать COPS именем хост-сети (напр. Telit ставит "Tele2
# RU", тогда как на SIM записан бренд MVNO "T-Mobile").
[ -n "$SPN_NAME" ] && COPS="$SPN_NAME"

# Выверенный вручную бренд MVNO из apn.list по IMSI - последним словом. SPN есть
# не у всех (и бывает мусором "T0"), а сеть отдаёт хост-оператора (Tele2); наш
# список знает, что за кодом 250-62 стоит T-Mobile. Пусто - оставляем как есть.
_ob=$(opname_brand "$SIMID") && COPS="$_ob"

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
# ВЕНДОР В МОДЕЛИ ДОЛЖЕН СОВПАДАТЬ С ВЕНДОРОМ ПО vid:pid.
#
# _model_sane проверяет, ПОХОЖА ли строка на модель, но не ЧЬЯ она - и этого
# оказалось мало. Живой случай: воткнули Huawei, опрос по чужому порту прочитал
# "Fibocom FM350-GL" и записал в секцию Huawei (12d1). Строка была совершенно
# правдоподобной, поэтому проверка на «похоже на модель» её пропустила.
#
# Судим ТОЛЬКО когда уверены: у vid есть однозначный вендор И в строке назван
# ДРУГОЙ известный вендор. Qualcomm-овый 05c6 не трогаем - под ним ходят модемы
# разных производителей, и там расхождение имени с vid нормально.
_vendor_by_vid() {
	case "$1" in
		0e8d:*|2cb7:*) echo fibocom ;;
		12d1:*)        echo huawei ;;
		1bc7:*)        echo telit ;;
		2c7c:*)        echo quectel ;;
		19d2:*)        echo zte ;;
		1e2d:*)        echo cinterion ;;
		2dee:*)        echo meiglink ;;
		1e0e:*)        echo simcom ;;
	esac
}
_model_vendor_ok() {   # $1 - модель, $2 - vidpid
	_mv_want=$(_vendor_by_vid "$2")
	[ -n "$_mv_want" ] || return 0            # вендор по vid неизвестен - не судим
	_mv_low=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	case "$_mv_low" in *"$_mv_want"*) return 0 ;; esac
	# Имя вендора в строке вообще не названо - тоже не судим: многие модемы
	# отдают голую модель ("RM520N-GL", "E3372"), и это нормально.
	for _mv_other in fibocom huawei telit quectel zte cinterion meiglink simcom; do
		[ "$_mv_other" = "$_mv_want" ] && continue
		case "$_mv_low" in *"$_mv_other"*) return 1 ;; esac
	done
	return 0
}
if [ -n "$MODEL" ] && [ -n "$AMP_SEC" ] \
   && ! _model_vendor_ok "$MODEL" "$(uci -q get "5gmodem.$AMP_SEC.vidpid")"; then
	logger -t 5gmodem "модель «$MODEL» не от вендора $(uci -q get "5gmodem.$AMP_SEC.vidpid") - в профиль не пишем"
	MODEL=""
fi
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
	# Шаблон обязателен: IMEI - это 14-16 цифр отдельной строкой, и всё, что на
	# него не похоже, в кэш попасть не должно (см. at_static).
	NR_IMEI=$(at_static imei "AT+CGSN" '^[0-9]{14,16}$' 2>/dev/null | tr -d '\r' \
		| grep -oE '^[0-9]{14,16}$' | head -1)
fi

# IMSI - БЕСПЛАТНО, из общего батча. Присваивать его должен профиль модема, но
# делают это не все (у Telit LM960 запроса нет вовсе), и в карточке SIM стоял
# прочерк при том, что +CIMI в батче честно отвечал. Ни одной лишней команды:
# SIMID уже разобран выше из того же ответа.
if [ -z "$NR_IMSI" ] || [ "$NR_IMSI" = "-" ]; then
	case "$SIMID" in
		''|*[!0-9]*) : ;;
		*) NR_IMSI="$SIMID" ;;
	esac
fi

# ICCID - через кэш статики, одна команда на модем. Команда РАЗНАЯ у вендоров:
# Telit отвечает только на AT+ICCID (на AT+CCID и AT#CCID молчит), большинство
# остальных - на AT+CCID. Пробуем по очереди; шаблон не пускает в кэш чужой
# ответ (см. at_static).
if [ -z "$NR_ICCID" ] || [ "$NR_ICCID" = "-" ]; then
	NR_ICCID=$(at_static iccid "AT+ICCID" '[0-9]{18,22}' 2>/dev/null | tr -d '\r' \
		| grep -oE '[0-9]{18,22}' | head -1)
	[ -n "$NR_ICCID" ] || NR_ICCID=$(at_static ccid "AT+CCID" '[0-9]{18,22}' 2>/dev/null \
		| tr -d '\r' | grep -oE '[0-9]{18,22}' | head -1)
fi

# АКТИВНЫЙ SIM-СЛОТ, если профиль модема его не дал. Заполняют это поле только
# профили Quectel (AT+QUIMSLOT?), а слоты есть и у других: у Telit LM960 их два,
# simslot.sh их видит, но в метрики значение не попадало - в карточке стоял
# прочерк при двух живых слотах.
#
# ЧЕРЕЗ КЭШ. simslot.sh спрашивает QMI (qmicli --uim-get-slot-status) и стоит
# ~1 c - при опросе в 2 c это половина сверху на каждом тике. Слот же меняется
# только когда его переключает пользователь, поэтому держим ответ минуту, а
# simslot.sh при переключении сбрасывает кэш сам - иначе UI минуту показывал бы
# старый слот сразу после переключения.
if [ -z "$SSIM" ] || [ "$SSIM" = "-" ]; then
	_slot_c="/tmp/5gmodem_slot_$_STKEY"
	_slot_age=""
	if [ -s "$_slot_c" ]; then
		_slot_t=$(cat "${_slot_c}.t" 2>/dev/null)
		case "$_slot_t" in
			''|*[!0-9]*) : ;;
			*) _slot_age=$(( $(uptime_s) - _slot_t )) ;;
		esac
	fi
	if [ -n "$_slot_age" ] && [ "$_slot_age" -ge 0 ] && [ "$_slot_age" -lt 60 ]; then
		SSIM=$(cat "$_slot_c" 2>/dev/null)
	else
		_slot_v=$("$RES/simslot.sh" status 2>/dev/null \
			| jsonfilter -e '@.active' 2>/dev/null)
		case "$_slot_v" in
			''|*[!0-9]*) : ;;
			*) SSIM="$_slot_v"
			   printf '%s' "$_slot_v" > "$_slot_c" 2>/dev/null
			   uptime_s > "${_slot_c}.t" 2>/dev/null ;;
		esac
	fi
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

# ПРОЦЕНТ СИГНАЛА ИЗ RSRP, КОГДА +CSQ БЕСПОЛЕЗЕН.
#
# На LTE ряд модемов (SIMCOM SIM7600E - по отчёту) отдаёт "+CSQ: 99,99" -
# «неизвестно», и процент выходил пустым: шкала CSQ рассчитана на 0..31.
# Но RSRP профиль к этому моменту уже прочитал, а это честный уровень LTE.
# Пересчитываем по стандартной шкале -140..-44 дБм -> 0..100 %.
#
# НЕ ПРОВЕРЕНО НА ЖИВОМ SIM7600E (модема нет): формула стандартная, значение
# лишь ЗАПАСНОЕ - при валидном CSQ (0..31) используется он, тут ничего не
# меняется. Считаем через awk: в busybox $(( )) не умеет дробное/отрицательное
# надёжно, а RSRP приходит со знаком.
if [ -z "$CSQ_PER" ] && [ -n "$RSRP" ]; then
	case "$RSRP" in
		-[0-9]*|[0-9]*)
			CSQ_PER=$(awk -v r="$RSRP" 'BEGIN {
				p = (r + 140) * 100 / 96;      # -140 -> 0, -44 -> 100
				if (p < 0) p = 0; if (p > 100) p = 100;
				printf "%d", p + 0.5;
			}' 2>/dev/null)
			;;
	esac
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
"rxdiv":"$(sanitize_string "$RXDIV")",
"firmware":"$(sanitize_string "$FW")",
"cport":"$(sanitize_string "$DEVICE")",
"protocol":"$(sanitize_string "$PROTO")",
"iface_proto":"$(sanitize_string "$(uci -q get "network.$SEC.proto")")",
"iface_apn":"$(sanitize_string "$(uci -q get "network.$SEC.apn")")",
"iface_pdptype":"$(sanitize_string "$(uci -q get "network.$SEC.pdptype")$(uci -q get "network.$SEC.pdp")$(uci -q get "network.$SEC.iptype")")",
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
"allow_roaming":"$([ "$(uci -q get "network.$SEC.allow_roaming")" = "1" ] && echo 1 || echo 0)",
"imei":"$(sanitize_string "$NR_IMEI")",
"imsi":"$(sanitize_string "$NR_IMSI")",
"iccid":"$(sanitize_string "$NR_ICCID")",
"at_debug":"$([ "$(uci -q get "5gmodem.$_hl_sec.kind")" = "hilink" ] && echo 1 || echo 0)",
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
"sinr":"$(sanitize_string "$SINR")",
"neighbors":[$NEIGHBORS]
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
	# OWNER не нужен: имя $CACHE закодировано путём модема (_MKEY), снимок по
	# определению принадлежит текущему модему - чужого не прочитаешь.
else
	cat "$_TMP" 2>/dev/null  # ответ отдаём в любом случае, но в кэш не кладём
	rm -f "$_TMP"
fi
exit 0

