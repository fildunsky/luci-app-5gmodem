#!/bin/sh
[ -n "$(uci -q show 5gmodem.health 2>/dev/null)" ] && exit 0
uci -q set 5gmodem.health=health
uci -q set 5gmodem.health.enabled='1'
uci -q set 5gmodem.health.failover='1'
uci -q commit 5gmodem
exit 0
