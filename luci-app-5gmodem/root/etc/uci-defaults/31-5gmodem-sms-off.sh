#!/bin/sh
# 
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Licensed to the GNU General Public License v3.0.
# 

/etc/init.d/5gmodem-sms-notify stop >/dev/null 2>&1 &
/etc/init.d/5gmodem-sms-notify disable >/dev/null 2>&1 &

exit 0
