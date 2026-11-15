#!/bin/sh
# External address on by default for new installations: next to the carrier address in
# the modem card and on the active uplink card of "Internet priority". Only a fresh
# install is touched: seed_widgets.sh (runs after this script) has not marked the config
# yet and neither option is set. An upgrade keeps whatever the user had; an absent
# option still means "off" there.
[ -f /etc/config/5gmodem ] || exit 0
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 || exit 0
[ "$(uci -q get 5gmodem.@5gmodem[0].widgets_seeded)" = 1 ] && exit 0
[ -n "$(uci -q get 5gmodem.@5gmodem[0].extip_enabled)" ] && exit 0
uci -q set 5gmodem.@5gmodem[0].extip_enabled=1
[ -n "$(uci -q get 5gmodem.@5gmodem[0].extip_in_netpri)" ] \
	|| uci -q set 5gmodem.@5gmodem[0].extip_in_netpri=1
uci -q commit 5gmodem
exit 0
