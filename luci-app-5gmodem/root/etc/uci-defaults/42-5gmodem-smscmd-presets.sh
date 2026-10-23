#!/bin/sh

[ "$(uci -q get 5gmodem.sms.cmd_presets)" = "1" ] && exit 0

uci -q get 5gmodem.sms >/dev/null 2>&1 || uci -q set 5gmodem.sms=sms

if [ -z "$(uci -q show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\([^.]*\)=smscmd$/\1/p')" ]; then
	[ -n "$(uci -q get 5gmodem.sms.cmd_secret)" ] || uci -q set 5gmodem.sms.cmd_secret='secret'

	_s=$(uci -q add 5gmodem smscmd)
	uci -q set "5gmodem.$_s.keyword=reboot"
	uci -q set "5gmodem.$_s.exec=reboot"
	uci -q set "5gmodem.$_s.answer=1"
	uci -q set "5gmodem.$_s.answer_text=Rebooting the router"
	uci -q set "5gmodem.$_s.delay=10"

	_s=$(uci -q add 5gmodem smscmd)
	uci -q set "5gmodem.$_s.keyword=modem"
	uci -q set "5gmodem.$_s.exec=/usr/share/5gmodem/reboot_modem.sh power"
	uci -q set "5gmodem.$_s.answer=1"
	uci -q set "5gmodem.$_s.answer_text=Power-cycling the modem"
	uci -q set "5gmodem.$_s.delay=10"
fi

uci -q set 5gmodem.sms.cmd_presets=1
uci -q commit 5gmodem

exit 0
