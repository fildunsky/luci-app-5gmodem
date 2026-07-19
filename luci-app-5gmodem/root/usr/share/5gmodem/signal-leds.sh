#!/bin/sh
#
# Индикатор уровня сигнала на светодиодах корпуса (Cudy LT300 и совместимые).
#
# ПОЧЕМУ НЕ КАК В ИСХОДНОМ СКРИПТЕ. Прежний вариант каждые 10 секунд сам слал
# модему AT+CESQ. Это давало две беды сразу:
#   1) на слабом роутере (LT300 - MT7628, 56 МБ ОЗУ) отдельный опрос заметно
#      тормозил систему;
#   2) он лез в тот же AT-порт, что и основной опрос метрик, а два процесса в
#      одном порту замедляют друг друга втрое (замерено) и портят чтение SMS.
#
# Здесь модем не опрашивается вовсе. Берём ГОТОВЫЙ снимок метрик: '5gmodem.sh
# cached <ttl>' отдаёт кэш, если он свежий, и лезет в порт, только когда данные
# протухли, - причём под общей блокировкой, то есть в порту всё равно остаётся
# один процесс. Когда открыта веб-страница или 5gtop, светодиоды не стоят
# роутеру вообще ничего: снимок уже обновлён ими.
#
# Usage:
#   signal-leds.sh detect   - есть ли на этом устройстве нужные светодиоды (JSON)
#   signal-leds.sh once     - обновить один раз
#   signal-leds.sh off      - погасить
#   signal-leds.sh run      - цикл (запускается из init.d)

RES=/usr/share/5gmodem
CFG=5gmodem

# Каталог светодиодов можно переопределить - нужно для проверки логики без
# самого устройства (LEDS_DIR=/tmp/fakeleds signal-leds.sh once).
LEDS_DIR="${LEDS_DIR:-/sys/class/leds}"

# Имена светодиодов LT300. Список задаётся в конфиге, если у устройства они
# называются иначе, - тогда правка не требует изменения кода.
LED_NAMES=$(uci -q get "$CFG.@5gmodem[0].signal_leds_names")
[ -n "$LED_NAMES" ] || LED_NAMES="white:signal1 white:signal2 white:signal3"

# ВКЛЮЧЕНО ПО УМОЛЧАНИЮ там, где светодиоды есть. Пустое значение = «не
# настраивали»: на таких устройствах индикатор - ожидаемое поведение (у Cudy
# он и работает штатной прошивкой), и заставлять человека искать галочку, чтобы
# вернуть привычное, неправильно. Выключение записывается явным нулём.
enabled() {
	case "$(uci -q get "$CFG.@5gmodem[0].signal_leds")" in
		0) return 1 ;;
		*) return 0 ;;
	esac
}

INTERVAL=$(uci -q get "$CFG.@5gmodem[0].signal_leds_interval")
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=15 ;; esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

# Все ли светодиоды на месте. Проверяем НАЛИЧИЕ, а не имя платы: у совместимых
# устройств те же светодиоды могут быть при другом board_name, а на LT300 без
# них (иная ревизия) галочка в интерфейсе только вводила бы в заблуждение.
leds_present() {
	for _l in $LED_NAMES; do
		[ -w "$LEDS_DIR/$_l/brightness" ] || return 1
	done
	return 0
}

# Максимальная яркость у светодиода своя: где-то 1, где-то 255. Читаем из
# sysfs, а не подставляем 255 вслепую.
led_max() {
	_m=$(cat "$LEDS_DIR/$1/max_brightness" 2>/dev/null)
	case "$_m" in ''|*[!0-9]*|0) _m=255 ;; esac
	printf '%s' "$_m"
}

# set_leds <сколько зажечь>
set_leds() {
	_want="$1"; _i=0
	for _l in $LED_NAMES; do
		_i=$((_i + 1))
		if [ "$_i" -le "$_want" ]; then
			printf '%s' "$(led_max "$_l")" > "$LEDS_DIR/$_l/brightness" 2>/dev/null
		else
			printf '0' > "$LEDS_DIR/$_l/brightness" 2>/dev/null
		fi
	done
}

# Какой метрикой светить. Выбор пользователя (настройки модема); по умолчанию
# RSRP - он привязан к физике и не сжат в верхней части шкалы.
METRIC=$(uci -q get "$CFG.@5gmodem[0].signal_leds_metric")
case "$METRIC" in rsrp|rsrq|sinr|signal) ;; *) METRIC=rsrp ;; esac

# Сколько лампочек зажечь для значения выбранной метрики.
#
# Пороги взяты ТЕ ЖЕ, которыми значения окрашены на веб-странице (5gdetail.js:
# qcolor), чтобы «три лампочки» и «зелёный в вебе» означали одно и то же.
# Проценты держим отдельно и строже: шкала модема (CSQ) сжата сверху - на живом
# LT300 она держалась 64-74% при заметно разном качестве, и по ней всегда
# горели три лампочки.
#
# Отсутствие значения (метрика не поддерживается модемом, напр. SINR в 3G) даёт
# 0 лампочек - это честнее, чем показывать выдуманный уровень.
leds_for_metric() {   # $1 - значение
	_v=$(printf '%s' "$1" | sed -n 's/^\(-\{0,1\}[0-9]\{1,\}\).*/\1/p')
	[ -n "$_v" ] || { printf '0'; return; }
	case "$METRIC" in
		rsrp)
			if   [ "$_v" -ge -80 ];  then printf '3'
			elif [ "$_v" -ge -100 ]; then printf '2'
			else printf '1'; fi ;;
		rsrq)
			if   [ "$_v" -ge -10 ]; then printf '3'
			elif [ "$_v" -ge -15 ]; then printf '2'
			else printf '1'; fi ;;
		sinr)
			if   [ "$_v" -ge 10 ]; then printf '3'
			elif [ "$_v" -ge 0 ];  then printf '2'
			else printf '1'; fi ;;
		signal)
			if   [ "$_v" -ge 75 ]; then printf '3'
			elif [ "$_v" -ge 45 ]; then printf '2'
			elif [ "$_v" -ge 1 ];  then printf '1'
			else printf '0'; fi ;;
	esac
}

update_once() {
	# TTL чуть больше периода опроса: иначе каждый тик заставал бы снимок
	# протухшим и лез в порт, ради чего всё и затевалось.
	_j=$("$RES/5gmodem.sh" cached $((INTERVAL + 5)) 2>/dev/null)
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)

	# Не зарегистрированы в сети - гасим всё. Показывать «уровень» при
	# отсутствии регистрации нельзя: сигнал может быть, а связи нет.
	case "$_reg" in
		1|5) : ;;
		*) set_leds 0; return ;;
	esac

	_val=$(printf '%s' "$_j" | jsonfilter -e "@.$METRIC" 2>/dev/null)
	set_leds "$(leds_for_metric "$_val")"
}

case "$1" in
detect)
	if leds_present; then
		printf '{"available":1,"leds":"%s"}\n' "$LED_NAMES"
	else
		printf '{"available":0}\n'
	fi
	;;
once)
	leds_present || { printf '{"error":"no leds"}\n'; exit 0; }
	update_once
	;;
off)
	leds_present && set_leds 0
	;;
# Включение/выключение из интерфейса. Пишем и КОММИТИМ здесь, а не через
# uci.save в браузере: та правка легла бы в сессионный стейджинг LuCI, и
# наверху появились бы «непринятые изменения» после простого щелчка галочкой.
# Смена метрики из интерфейса. Пишем и коммитим здесь же - страница применяет
# настройку сразу, без Save формы (см. пояснение в 5gdebug.js).
metric)
	case "$2" in
		rsrp|rsrq|sinr|signal)
			uci -q set "$CFG.@5gmodem[0].signal_leds_metric=$2"
			uci -q commit "$CFG"
			/etc/init.d/5gmodem-leds restart >/dev/null 2>&1
			printf '{"metric":"%s"}\n' "$2"
			;;
		*) printf '{"error":"bad metric"}\n' ;;
	esac
	;;
enable|disable)
	[ "$1" = "enable" ] && _v=1 || _v=0
	uci -q set "$CFG.@5gmodem[0].signal_leds=$_v"
	uci -q commit "$CFG"
	if [ "$_v" = 1 ]; then
		/etc/init.d/5gmodem-leds enable >/dev/null 2>&1
		/etc/init.d/5gmodem-leds restart >/dev/null 2>&1
	else
		/etc/init.d/5gmodem-leds stop >/dev/null 2>&1
		/etc/init.d/5gmodem-leds disable >/dev/null 2>&1
	fi
	printf '{"signal_leds":%s}\n' "$_v"
	;;
run)
	leds_present || exit 0
	enabled || exit 0
	while :; do
		update_once
		sleep "$INTERVAL"
	done
	;;
*)
	echo "usage: $0 detect|once|off|run" >&2
	exit 1
	;;
esac
exit 0
