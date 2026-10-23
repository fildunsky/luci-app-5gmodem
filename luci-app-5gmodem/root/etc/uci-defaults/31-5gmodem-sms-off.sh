#!/bin/sh
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Licensed to the GNU General Public License v3.0.

if [ "$(uci -q get 5gmodem.sms.lednotify)" = "1" ]; then
	/etc/init.d/5gmodem-sms-notify enable >/dev/null 2>&1
	/etc/init.d/5gmodem-sms-notify restart >/dev/null 2>&1 &
else
	/etc/init.d/5gmodem-sms-notify stop >/dev/null 2>&1 &
	/etc/init.d/5gmodem-sms-notify disable >/dev/null 2>&1 &
fi

exit 0
