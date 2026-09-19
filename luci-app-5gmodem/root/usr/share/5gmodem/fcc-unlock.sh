#!/bin/sh
#
# FCC-разблокировка Dell DW5821e / Foxconn T77W968 (Snapdragon X20):
# 413c:81d7, 413c:81e0, 0489:e0b5, 0489:e0b4.
#
# Прошивка ждёт от хоста QMI-команду Foxconn «FCC authentication» и без неё не
# включает радио, а по полевому отчёту 14.09.2026 (WH3000, 413c:81e0) ещё и
# сбрасывает USB примерно раз в пять минут. Незаблокированный модем команду
# просто подтверждает или отвечает ошибкой - перезагрузки она не вызывает.
#
# ДВА РЕЖИМА.
#   fcc-unlock.sh <dbus-путь> <порт>...   - так зовёт ModemManager из
#       /etc/ModemManager/fcc-unlock.d/<vid:pid>. MM делает это ТОЛЬКО когда
#       модем отказал во включении радио (MM_CORE_ERROR_RETRY), один раз на
#       попытку. Штатный скрипт Foxconn («105b») сюда не годится: он ищет порт
#       MBIM, а в QMI-композиции у модуля лишь cdc-wdm на qmi_wwan - и выходил
#       с кодом 2, ничего не отправив.
#   fcc-unlock.sh kernel <usb-путь>       - интерфейс на qmi/mbim, ModemManager
#       модемом не занимается. Шлём один раз на каждое появление модема на
#       шине (ключ - номер устройства на шине, он меняется при переподключении).

LOGTAG=5gmodem
FOXCONN_IDS="413c:81d7 413c:81e0 0489:e0b5 0489:e0b4"

is_foxconn_x20() {
	case " $FOXCONN_IDS " in *" $1 "*) return 0 ;; esac
	return 1
}

# Команду даём через прокси (-p), только если он уже нужен: канал держит
# ModemManager или прокси уже запущен кем-то ещё. Без MM свой прокси остаётся
# жить после qmicli, сторож sessionwatch видит «прокси на прямом канале» и
# передозванивает только что поднятый интерфейс - находка у владельца
# DW5821e 413c:81e0 17.09.2026. У cdc_mbim-узла канал открывается только с
# --device-open-mbim. qmicli на занятом канале умеет висеть бесконечно -
# ограничиваем временем сами.
send_auth() {   # $1 - узел /dev/cdc-wdmN, $2 - предел ожидания, с
	command -v qmicli >/dev/null 2>&1 || { echo "qmicli is not installed"; return 2; }
	_sa_px=""
	if pidof ModemManager >/dev/null 2>&1 || pidof qmi-proxy >/dev/null 2>&1 || pidof mbim-proxy >/dev/null 2>&1; then
		_sa_px="-p"
	fi
	_sa_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _sa_mb="--device-open-mbim" ;;
	esac
	case "$1" in *mbim*) _sa_mb="--device-open-mbim" ;; esac
	_sa_out="/tmp/5gmodem_fcc.$$"
	qmicli $_sa_px $_sa_mb -d "$1" --dms-foxconn-set-fcc-authentication=0 > "$_sa_out" 2>&1 &
	_sa_p=$!
	_sa_n=0
	while kill -0 "$_sa_p" 2>/dev/null && [ "$_sa_n" -lt "${2:-15}" ]; do
		sleep 1; _sa_n=$((_sa_n + 1))
	done
	kill -9 "$_sa_p" 2>/dev/null
	wait "$_sa_p" 2>/dev/null
	_sa_txt=$(tr '\n' ' ' < "$_sa_out" 2>/dev/null)
	rm -f "$_sa_out"
	echo "$_sa_txt"
	case "$_sa_txt" in
		*[Ss]uccessfully*) return 0 ;;
		# Команда до модема дошла, но он её не знает или не нуждается в ней -
		# повторять бессмысленно.
		*InvalidQmiCommand*|*[Nn]ot\ supported*|*NotSupported*|*InvalidOperation*) return 3 ;;
	esac
	return 1
}

wdm_of_path() {   # $1 - usb-путь
	for _wp in /sys/bus/usb/devices/"$1":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$1":*/usbmisc/wdm*; do
		[ -e "$_wp" ] && { echo "/dev/${_wp##*/}"; return 0; }
	done
	return 1
}

radio_already_on() {   # $1 - usb-путь
	_ro_sec=$(secname "$1")
	_ro_if=$(uci -q get "5gmodem.$_ro_sec.network")
	_ro_st=""
	[ -n "$_ro_if" ] && _ro_st=$(ubus call "network.interface.$_ro_if" status 2>/dev/null)
	case "$_ro_st" in
		*'"up": true'*) echo "interface $_ro_if is up"; return 0 ;;
	esac
	_ro_at=$(uci -q get "5gmodem.$_ro_sec.at_port")
	if [ -n "$_ro_at" ] && [ -c "$_ro_at" ] && [ "$(tty_usbpath "$_ro_at")" = "$1" ]; then
		_ro_cf=$(at_query "$_ro_at" "AT+CFUN?" 6 | sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
		[ "$_ro_cf" = 1 ] && { echo "CFUN=1 on $_ro_at"; return 0; }
		[ -n "$_ro_cf" ] && return 1
	fi
	case "$_ro_st" in
		*'"pending": true'*) return 2 ;;
	esac
	pgrep -f "umbim .*cdc-wdm" >/dev/null 2>&1 && return 2
	pgrep -f "uqmi .*cdc-wdm" >/dev/null 2>&1 && return 2
	return 1
}

case "$1" in
kernel)
	. /usr/share/5gmodem/lib.sh
	P="$2"
	[ -n "$P" ] && [ -f "/sys/bus/usb/devices/$P/idVendor" ] || exit 0
	VP="$(cat "/sys/bus/usb/devices/$P/idVendor"):$(cat "/sys/bus/usb/devices/$P/idProduct")"
	is_foxconn_x20 "$VP" || exit 0
	DEVNUM=$(cat "/sys/bus/usb/devices/$P/devnum" 2>/dev/null)
	MARK="/tmp/5gmodem_fcc_$(printf '%s' "$P" | tr -c 'A-Za-z0-9' '_')_$DEVNUM"
	[ -f "$MARK" ] && exit 0
	[ -f "$MARK.run" ] && kill -0 "$(cat "$MARK.run" 2>/dev/null)" 2>/dev/null && exit 0
	echo $$ > "$MARK.run"
	_try=0
	while [ "$_try" -lt 15 ]; do
		_try=$((_try + 1))
		# Модем переподключился - этот запуск уже не про него.
		[ "$(cat "/sys/bus/usb/devices/$P/devnum" 2>/dev/null)" = "$DEVNUM" ] || break
		WHY=$(radio_already_on "$P"); RC=$?
		if [ "$RC" = 0 ]; then
			logger -t "$LOGTAG" "fcc: $VP on $P - radio is already on ($WHY), FCC authentication not needed"
			: > "$MARK"; break
		elif [ "$RC" = 2 ] && [ "$_try" -lt 10 ]; then
			OUT="the connection is being set up"
			sleep 3; continue
		fi
		W=$(wdm_of_path "$P")
		if [ -n "$W" ] && [ -c "$W" ]; then
			OUT=$(send_auth "$W" 15); RC=$?
			if [ "$RC" = 0 ]; then
				logger -t "$LOGTAG" "fcc: $VP on $P - FCC authentication sent via $W (attempt $_try)"
				: > "$MARK"; break
			elif [ "$RC" = 2 ] || [ "$RC" = 3 ]; then
				logger -t "$LOGTAG" "fcc: $VP on $P - not needed or not possible: $OUT"
				: > "$MARK"; break
			fi
		fi
		sleep 3
	done
	[ -f "$MARK" ] || logger -t "$LOGTAG" "fcc: $VP on $P - FCC authentication did not go through after $_try attempts: $OUT"
	rm -f "$MARK.run"
	exit 0
	;;
esac

# Режим ModemManager: $1 - dbus-путь модема, дальше имена портов управления.
[ $# -ge 2 ] || exit 1
shift
PORT=""
for _p in "$@"; do
	case "$_p" in
		cdc-wdm*|wdm*|*mbim*|*qmi*) PORT="$_p"; break ;;
	esac
done
[ -n "$PORT" ] || exit 2
# MM ждёт скрипт не дольше 5 с (MAX_FCC_UNLOCK_EXEC_TIME_SECS) - укладываемся.
OUT=$(send_auth "/dev/$PORT" 4); RC=$?
logger -t "$LOGTAG" "fcc: ModemManager requested FCC unlock on $PORT - rc $RC: $OUT"
[ "$RC" = 3 ] && exit 0
exit $RC
