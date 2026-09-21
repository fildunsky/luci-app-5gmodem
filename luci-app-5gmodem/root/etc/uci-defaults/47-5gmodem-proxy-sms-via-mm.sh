#!/bin/sh

[ -f /etc/config/5gmodem ] || exit 0
[ "$(uci -q get 5gmodem.sms.proxy_mm_migrated)" = 1 ] && exit 0
uci -q get 5gmodem.sms >/dev/null || exit 0
if uci -q show network 2>/dev/null | grep -qE "\.proto='?(mbimp|qmip)'?$"; then
	uci -q set 5gmodem.sms.sms_via_mm=1
	uci -q set 5gmodem.sms.ussd_via_mm=1
fi
uci -q set 5gmodem.sms.proxy_mm_migrated=1
uci -q commit 5gmodem
exit 0
