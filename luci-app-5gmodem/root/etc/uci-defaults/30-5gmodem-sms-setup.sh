#!/bin/sh
# 
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Licensed to the GNU General Public License v3.0.
#

chmod +x /usr/share/5gmodem/sms_led.sh >/dev/null 2>&1 &
chmod +x /usr/share/5gmodem/smstool_led.sh >/dev/null 2>&1 &
chmod +x /etc/uci-defaults/31-5gmodem-sms-off.sh >/dev/null 2>&1 &
chmod +x /etc/uci-defaults/30-5gmodem-sms-setup.sh >/dev/null 2>&1 &
chmod +x /etc/init.d/5gmodem-sms-notify >/dev/null 2>&1 &
chmod +x /usr/share/5gmodem/sms_tool_mm >/dev/null 2>&1 &

mkdir -p /etc/5gmodem/modem/atcmmds >/dev/null 2>&1 &
mkdir -p /etc/5gmodem/modem/ussdcodes >/dev/null 2>&1 &

chmod +x /usr/libexec/rpcd/5gmodem_sms_forward >/dev/null 2>&1 &

if ! uci -q get 5gmodem.sms >/dev/null 2>&1; then
	uci set 5gmodem.sms=sms
fi

[ "$(uci -q get 5gmodem.sms.pnumber)" = "48" ] && {
	uci -q set 5gmodem.sms.pnumber='7'
}

uci commit 5gmodem >/dev/null 2>&1

# If a Compal RXM-G1 is already connected at install time, auto-configure
# it now (via_mm / WMS routes / AT ports) instead of waiting for a reboot.
[ -x /etc/hotplug.d/usb/70-5gmodem-sms-modems ] && \
	ACTION="" /etc/hotplug.d/usb/70-5gmodem-sms-modems >/dev/null 2>&1 &

rm -rf /tmp/luci-indexcache >/dev/null 2>&1 &
rm -rf /tmp/luci-modulecache/ >/dev/null 2>&1 &
exit 0
