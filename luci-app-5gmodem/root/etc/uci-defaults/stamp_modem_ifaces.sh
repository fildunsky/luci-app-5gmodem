#!/bin/sh

[ -f /etc/config/5gmodem ] || exit 0

CHANGED=0
for sec in $(uci show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\(m_[^.=]*\)=modem$/\1/p'); do
	path=$(uci -q get "5gmodem.$sec.path")
	iface=$(uci -q get "5gmodem.$sec.network")
	[ -n "$path" ] && [ -n "$iface" ] || continue
	uci -q get "network.$iface" >/dev/null 2>&1 || continue
	if [ -z "$(uci -q get "network.$iface.modem_path")" ]; then
		uci -q set "network.$iface.modem_path=$path"
		CHANGED=1
	fi
	imei=$(uci -q get "5gmodem.$sec.imei")
	if [ -n "$imei" ] && [ -z "$(uci -q get "network.$iface.modem_imei")" ]; then
		uci -q set "network.$iface.modem_imei=$imei"
		CHANGED=1
	fi
done

[ "$CHANGED" = 1 ] && uci -q commit network

exit 0
