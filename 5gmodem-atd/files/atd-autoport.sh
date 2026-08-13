#!/bin/sh
#
# Автовыбор ЗАПАСНОГО AT-порта под слушатель URC (5gmodem-atd) и включение
# демона - чтобы фича работала "из коробки", без ручного uci.
#
# Что делает:
#   - берёт активный модем (5gmodem.@5gmodem[0].active_modem);
#   - молчит для HiLink и modemmanager-модемов: у них порты не наши, события
#     живут в QMI/MM-индикациях, а не в AT-URC - демону там не место;
#   - ищет AT-порт, которым НИКТО не пользуется (не порт метрик, не порты SMS):
#     подписки на URC действуют, пока порт держит ровно один читатель, поэтому
#     слушателю нужен ЭКСКЛЮЗИВНЫЙ порт;
#   - для Quectel (URC роутятся на ОДИН порт) направляет их на выбранный порт
#     через atd.urcport (usbat=младший AT, usbmodem=старший); у Fibocom и прочих
#     URC вещаются во все порты - маршрут не нужен;
#   - пишет выбор в uci и (только если он изменился) перезапускает службу.
#
# Ручной выбор уважаем: если задан 5gmodem.atd.manual=1, автовыбор не трогает
# ни порт, ни включение. Вызывается из init (start) и из hotplug (модем
# появился/сменился).

RES=/usr/share/5gmodem
CFG=5gmodem

_ensure_section() {
	uci -q get "$CFG.atd" >/dev/null 2>&1 && return 0
	uci -q set "$CFG.atd=atd"
	uci -q commit "$CFG"
}

_disable() {
	[ "$(uci -q get "$CFG.atd.manual")" = "1" ] && return 0
	local was_en was_port
	was_en=$(uci -q get "$CFG.atd.enabled")
	was_port=$(uci -q get "$CFG.atd.port")
	[ "$was_en" != "1" ] && [ -z "$was_port" ] && return 0
	uci -q set "$CFG.atd.enabled=0"
	uci -q delete "$CFG.atd.port"
	uci -q delete "$CFG.atd.urcport"
	uci -q commit "$CFG"
	/etc/init.d/5gmodem-atd stop >/dev/null 2>&1
	[ -n "$1" ] && logger -t 5gmodem "atd: $1 - слушатель выключен"
	return 0
}

_ttynum() { printf '%s' "${1##*ttyUSB}"; }   # /dev/ttyUSB3 -> 3

_ensure_section

# Ручной режим: пользователь сам рулит портом - не вмешиваемся.
[ "$(uci -q get "$CFG.atd.manual")" = "1" ] && exit 0

AM=$(uci -q get "$CFG.@5gmodem[0].active_modem")
[ -n "$AM" ] || { _disable "нет активного модема"; exit 0; }

SEC="m_$(printf '%s' "$AM" | sed 's/[^A-Za-z0-9]/_/g')"

# HiLink - AT-портов нет вовсе.
[ "$(uci -q get "$CFG.$SEC.kind")" = "hilink" ] && { _disable "HiLink"; exit 0; }

# ModemManager - его ttyUSB рулит сам MM, чужой читатель роняет ему команды.
NIF=$(uci -q get "$CFG.$SEC.network")
[ -n "$NIF" ] || NIF=$(uci -q get "$CFG.@5gmodem[0].network")
[ "$(uci -q get "network.$NIF.proto" 2>/dev/null)" = "modemmanager" ] && { _disable "ModemManager"; exit 0; }

# Порты, которые ЗАНЯТЫ (их слушателю брать нельзя): метрики + все порты SMS.
METRICS=$(uci -q get "$CFG.@5gmodem[0].at_port")
BUSY=" $METRICS "
for _o in readport sendport ussdport atport callport; do
	_p=$(uci -q get "$CFG.sms.$_o")
	[ -n "$_p" ] && BUSY="$BUSY $_p "
done

# Перебор AT-портов активного модема; берём первый ОТВЕЧАЮЩИЙ на AT+CGMM
# (настоящий MODEM-порт, не DIAG/NMEA) и НЕ занятый.
SPARE=""
for _t in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$AM\"].tty[*]" 2>/dev/null); do
	[ -e "$_t" ] || continue
	case "$BUSY" in *" $_t "*) continue ;; esac
	if "$RES/atprobe.sh" "$_t" model >/dev/null 2>&1; then SPARE="$_t"; break; fi
done
[ -n "$SPARE" ] || { _disable "нет свободного AT-порта"; exit 0; }

# Quectel (vid 2c7c): URC идут на ОДИН порт - направляем на наш.
URCPORT=""
_vid=$(cat "/sys/bus/usb/devices/$AM/idVendor" 2>/dev/null)
if [ "$_vid" = "2c7c" ]; then
	# usbat - младший AT-порт (обычно метрики), usbmodem - старший.
	if [ -n "$METRICS" ] && [ "$(_ttynum "$SPARE")" -le "$(_ttynum "$METRICS")" ] 2>/dev/null; then
		URCPORT="usbat"
	else
		URCPORT="usbmodem"
	fi
fi

# Применяем ТОЛЬКО при изменении - иначе каждый hotplug дёргал бы демон зря.
CUR_PORT=$(uci -q get "$CFG.atd.port")
CUR_URC=$(uci -q get "$CFG.atd.urcport")
CUR_EN=$(uci -q get "$CFG.atd.enabled")
if [ "$CUR_PORT" = "$SPARE" ] && [ "$CUR_URC" = "$URCPORT" ] && [ "$CUR_EN" = "1" ]; then
	exit 0
fi

uci -q set "$CFG.atd.port=$SPARE"
uci -q set "$CFG.atd.enabled=1"
if [ -n "$URCPORT" ]; then
	uci -q set "$CFG.atd.urcport=$URCPORT"
else
	uci -q delete "$CFG.atd.urcport"
fi
uci -q commit "$CFG"
logger -t 5gmodem "atd: слушатель URC на $SPARE${URCPORT:+ (urcport=$URCPORT)}"
/etc/init.d/5gmodem-atd restart >/dev/null 2>&1
exit 0
