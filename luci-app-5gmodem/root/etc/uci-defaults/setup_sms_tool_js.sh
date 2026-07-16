#!/bin/sh
# 
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Licensed to the GNU General Public License v3.0.
#

chmod +x /sbin/sms_led.sh >/dev/null 2>&1 &
chmod +x /sbin/smstool_led.sh >/dev/null 2>&1 &
chmod +x /etc/uci-defaults/off_sms.sh >/dev/null 2>&1 &
chmod +x /etc/uci-defaults/setup_sms_tool_js.sh >/dev/null 2>&1 &
chmod +x /etc/init.d/my_new_sms >/dev/null 2>&1 &
chmod +x /usr/bin/sms_tool_mm >/dev/null 2>&1 &

mkdir -p /etc/modem/atcmmds >/dev/null 2>&1 &
mkdir -p /etc/modem/ussdcodes >/dev/null 2>&1 &

chmod +x /usr/libexec/rpcd/sms_forward >/dev/null 2>&1 &

if ! uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
	uci set sms_tool_js.config=sms_tool_js
fi

[ "$(uci -q get sms_tool_js.@sms_tool_js[0].pnumber)" = "48" ] && {
	uci -q set sms_tool_js.@sms_tool_js[0].pnumber='7'
}

uci commit sms_tool_js >/dev/null 2>&1

# If a Compal RXM-G1 is already connected at install time, auto-configure
# it now (via_mm / WMS routes / AT ports) instead of waiting for a reboot.
[ -x /etc/hotplug.d/usb/70-sms-tool-js-modems ] && \
	ACTION="" /etc/hotplug.d/usb/70-sms-tool-js-modems >/dev/null 2>&1 &

rm -rf /tmp/luci-indexcache >/dev/null 2>&1 &
rm -rf /tmp/luci-modulecache/ >/dev/null 2>&1 &
exit 0
