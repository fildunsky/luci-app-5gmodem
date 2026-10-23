#!/bin/sh
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.@5gmodem[0].ifdedupe_done)" = "2" ] && exit 0
/usr/share/5gmodem/modemswitch.sh dedupe-ifaces >/dev/null 2>&1
uci -q set 5gmodem.@5gmodem[0].ifdedupe_done='2'
uci -q commit 5gmodem
exit 0
