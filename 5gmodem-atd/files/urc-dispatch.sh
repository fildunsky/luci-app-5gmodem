#!/bin/sh
# Диспетчер URC от 5gmodem-atd: $1 - порт, $2 - строка от модема.
# Сама строка уже в журнале (пишет демон) - здесь только реакция.
#
# Реакция одна: срочный круг сторожа. Он сам разберётся, что случилось
# (обрыв сессии, потеря регистрации, вынутая SIM) и что делать - вся логика
# лечения уже живёт в health.sh, дублировать её здесь нельзя. Наша задача -
# заменить ожидание опроса (до 30 c) на мгновенный пинок.

PORT="$1"
LINE="$2"

case "$LINE" in
	*CGEV:*DEACT*|*CGEV:*DETACH*|"NO CARRIER"*|\
	*CEREG:\ 0*|*CEREG:\ 2*|*CEREG:\ 3*|*C5GREG:\ 0*|\
	*CREG:\ 0*|*CREG:\ 2*|*CREG:\ 3*|\
	*SIMST*|*CPIN:\ NOT*|*SIM\ REMOVED*)
		# Дебаунс: шквал событий при перерегистрации = один пинок в 5 c.
		# Шкала - секунды аптайма (RTC-less роутеры прыгают по date).
		_k=/tmp/5gmodem_urc_kick
		_now=$(cut -d. -f1 /proc/uptime)
		_prev=0
		[ -f "$_k" ] && read -r _prev < "$_k" 2>/dev/null
		case "$_prev" in ''|*[!0-9]*) _prev=0 ;; esac
		[ $((_now - _prev)) -lt 5 ] && exit 0
		echo "$_now" > "$_k"
		logger -t 5gmodem "URC $PORT: «$LINE» - срочный круг сторожа"
		/usr/share/5gmodem/health.sh once >/dev/null 2>&1 &
		;;
esac
exit 0
