#!/bin/sh
# GL-E750/v2: Switch (Double flip = Show SMS) and Long press (Toggle Standby mode)
[ -f /etc/config/5gmodem ] && [ -x /usr/bin/mcu-switch ] || exit 0
case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in glinet,gl-e750*) ;; *) exit 0 ;; esac
uci -q get 5gmodem.btn_BTN_0 >/dev/null || {
	uci -q set 5gmodem.btn_BTN_0=button
	uci -q set 5gmodem.btn_BTN_0.name=BTN_0
	uci -q set 5gmodem.btn_BTN_0.btntype=switch
	uci -q set 5gmodem.btn_BTN_0.debounce=0
	uci -q set 5gmodem.btn_BTN_0.double='/usr/bin/mcu-switch sms'
	uci -q set 5gmodem.btn_BTN_0.ct_double=simple
}
uci -q get 5gmodem.btn_power >/dev/null || {
	uci -q set 5gmodem.btn_power=button
	uci -q set 5gmodem.btn_power.name=power
	uci -q set 5gmodem.btn_power.pressed='/usr/bin/mcu-switch standby'
	uci -q set 5gmodem.btn_power.ct_pressed=conditional
}
uci -q commit 5gmodem
exit 0
