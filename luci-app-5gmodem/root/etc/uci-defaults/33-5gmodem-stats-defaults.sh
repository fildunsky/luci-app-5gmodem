#!/bin/sh
uci -q get 5gmodem.stats >/dev/null 2>&1 || {
	uci -q set 5gmodem.stats=stats
	uci -q set 5gmodem.stats.enabled=1
	uci -q set 5gmodem.stats.persist=1
	uci -q set 5gmodem.stats.defaults_v2=1
	uci -q commit 5gmodem
}
# v2 defaults: monthly totals kept across reboots (about one flash write an hour) and
# background collection every 5 minutes (bgpoll unset). Before, persist=0 was written for
# everyone at install, so it is switched on once; a later "off" from the page is kept.
[ "$(uci -q get 5gmodem.stats.defaults_v2)" = 1 ] || {
	[ "$(uci -q get 5gmodem.stats.persist)" = 0 ] && uci -q set 5gmodem.stats.persist=1
	uci -q set 5gmodem.stats.defaults_v2=1
	uci -q commit 5gmodem
}
[ -n "$(uci -q get 5gmodem.@5gmodem[0].show_stats)" ] || {
	uci -q set 5gmodem.@5gmodem[0].show_stats=1
	uci -q commit 5gmodem
}
exit 0
