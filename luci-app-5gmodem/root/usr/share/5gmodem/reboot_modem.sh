#!/bin/sh
#
# "Restart" the modem by cycling its radio (AT+CFUN=4 -> AT+CFUN=1) to force a
# fresh network attach / reconnect.
#
# We deliberately do NOT use AT+CFUN=1,1 (full reset): on MBIM modems managed by
# ModemManager that triggers a full USB re-enumeration, after which MM briefly
# misclassifies the MBIM data port (the generic plugin falls back to AT data)
# and the data connection drops for minutes until MM sorts itself out. A radio
# cycle keeps the USB device (and MM's port classification) intact and just
# re-registers/reconnects.
#
# Usage: reboot_modem.sh [at_port]
#

PORT="$1"
[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

# radio off, then on again
sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
sleep 3
sms_tool -d "$PORT" at "AT+CFUN=1" >/dev/null 2>&1

echo '{"success":true}'
exit 0
