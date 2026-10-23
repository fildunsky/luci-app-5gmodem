#!/bin/sh
uci -q get 5gmodem.stats >/dev/null 2>&1 || {
	uci -q set 5gmodem.stats=stats
	uci -q set 5gmodem.stats.enabled=1
	uci -q set 5gmodem.stats.persist=0
	uci -q commit 5gmodem
}
[ -n "$(uci -q get 5gmodem.@5gmodem[0].show_stats)" ] || {
	uci -q set 5gmodem.@5gmodem[0].show_stats=1
	uci -q commit 5gmodem
}
exit 0
