#!/bin/sh
#
# Restart the modem. Two modes:
#
#   soft (default): cycle the radio only, AT+CFUN=4 -> AT+CFUN=1. Forces a fresh
#     network attach/reconnect WITHOUT re-enumerating USB, so ModemManager keeps
#     its MBIM port classification and the data channel is only briefly
#     interrupted. Use this for "re-register / apply bands".
#
#   hard: full modem reset, AT+CFUN=1,1. The modem reboots and re-enumerates on
#     the USB bus. Takes longer and, on MM-managed MBIM modems, MM may briefly
#     misclassify the data port after re-enumeration (connection can drop for a
#     minute). Use this when the soft restart is not enough (modem wedged).
#
# Usage: reboot_modem.sh [soft|hard] [at_port]
#   For backwards compatibility a first argument of /dev/... is treated as the
#   port and the mode defaults to soft.
#

MODE="$1"
PORT="$2"
case "$MODE" in
	soft|hard|power|haspower) ;;
	/dev/*)    PORT="$MODE"; MODE="soft" ;;   # старый вызов: reboot_modem.sh <port>
	*)         MODE="soft" ;;
esac

# Аппаратная перезагрузка модема по питанию через GPIO платы (например
# modem_power у Huasifei WH3000; у части плат - 4g/5g1/5g2). Работает независимо
# от AT: снимаем питание слота (value=1), пауза, возвращаем (value=0); интерфейс
# поднимается ~1 мин. На WH3000 это питает ТОЛЬКО M.2-слот (USB-модем не трогает).
# Список известных имён GPIO сброса/питания модема (по target/.../03_gpio_switches).
# modem_reset (напр. Almond 3S, GPIO33 active_high) сбрасывается той же
# последовательностью 1->пауза->0, что и modem_power, поэтому в общем списке.
POWER_GPIOS="modem_power modem_reset 4g 5g1 5g2"
first_power_gpio() {
	for _g in $POWER_GPIOS; do
		[ -e "/sys/class/gpio/$_g/value" ] && { echo "$_g"; return 0; }
	done
	return 1
}

if [ "$MODE" = haspower ]; then
	# наличие кнопки: отдаём имя первого доступного GPIO питания (или пусто)
	echo "{\"gpio\":\"$(first_power_gpio)\"}"
	exit 0
fi

if [ "$MODE" = power ]; then
	# 2-й аргумент можно использовать как явное имя GPIO; иначе - первый доступный
	G="$PORT"; [ -n "$G" ] || G=$(first_power_gpio)
	GP="/sys/class/gpio/$G/value"
	[ -n "$G" ] && [ -e "$GP" ] || { echo '{"success":false,"error":"no modem power gpio"}'; exit 0; }
	# в фоне: снять питание, пауза 5с, вернуть. Скрипт возвращается сразу, чтобы
	# XHR не висел всю паузу + переподнятие интерфейса.
	( echo 1 > "$GP" 2>/dev/null; sleep 5; echo 0 > "$GP" 2>/dev/null ) &
	echo "{\"success\":true,\"mode\":\"power\",\"gpio\":\"$G\"}"
	exit 0
fi

[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

if [ "$MODE" = "hard" ]; then
	# Full reset (AT+CFUN=1,1): the modem reboots and RE-ENUMERATES on USB, so
	# the AT port vanishes mid-command - a synchronous sms_tool would block ~35s
	# and the UI XHR would time out even though the reset succeeded. Fire it in
	# the background and return at once; the resolve hotplug re-pins ports and
	# brings the interface back after re-enumeration (no ifup here - the port is
	# gone).
	( sms_tool -d "$PORT" at "AT+CFUN=1,1" >/dev/null 2>&1 ) &
else
	# Soft radio restart (CFUN=4 -> CFUN=1): no USB re-enumeration, the port
	# stays. This drops the data bearer, so nudge the app's interface back up
	# (kernel qmi/mbim/atc/fibocom need it; MM-managed modems reconnect on their
	# own). Backgrounded so the script returns promptly to the UI.
	sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
	sleep 3
	sms_tool -d "$PORT" at "AT+CFUN=1" >/dev/null 2>&1
	IF=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$IF" ] && ( sleep 6; ifup "$IF" >/dev/null 2>&1 ) &
fi

echo "{\"success\":true,\"mode\":\"$MODE\"}"
exit 0
