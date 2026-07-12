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
	soft|hard) ;;
	/dev/*)    PORT="$MODE"; MODE="soft" ;;   # старый вызов: reboot_modem.sh <port>
	*)         MODE="soft" ;;
esac

[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

if [ "$MODE" = "hard" ]; then
	# полная перезагрузка модема (переинициализация USB)
	sms_tool -d "$PORT" at "AT+CFUN=1,1" >/dev/null 2>&1
else
	# мягкий рестарт радио, без переэнумерации USB
	sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
	sleep 3
	sms_tool -d "$PORT" at "AT+CFUN=1" >/dev/null 2>&1
fi

echo "{\"success\":true,\"mode\":\"$MODE\"}"
exit 0
