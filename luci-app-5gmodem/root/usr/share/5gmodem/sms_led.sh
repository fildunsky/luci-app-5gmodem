#!/bin/sh
#
# Copyright 2023-2026 Rafał Wabik (IceG) - From eko.one.pl forum
# Licensed to the GNU General Public License v3.0.
#

sleep 2
CT=$(uci -q get 5gmodem.sms.checktime)
TX=$(echo $CT | tr -dc '0-9')
TM=$(($TX * 60))

while [ 1 ]; do 
	LED=$(uci -q get 5gmodem.sms.lednotify)
	if [ $LED == "1" ]; then
    	sleep $TM
		/usr/share/5gmodem/smstool_led.sh >/dev/null 2>&1 &
		continue
	fi
	sleep 1
done
 
exit 0
