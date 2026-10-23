#!/bin/sh
[ "$(uci -q get 5gmodem.@5gmodem[0].fwzone_dedupe)" = "1" ] && exit 0

for _z in $(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='[^']*'\$/\1/p"); do
	_cur=$(uci -q get "firewall.$_z.network" | tr -d "'\"")
	[ -n "$_cur" ] || continue
	_dirty=0; _seen=" "
	for _e in $_cur; do
		case "$_seen" in *" $_e "*) _dirty=1 ;; esac
		_seen="$_seen$_e "
	done
	[ "$_dirty" = 1 ] || continue
	uci -q delete "firewall.$_z.network"
	_seen=" "
	for _e in $_cur; do
		case "$_seen" in *" $_e "*) continue ;; esac
		_seen="$_seen$_e "
		uci add_list "firewall.$_z.network=$_e"
	done
	logger -t 5gmodem "firewall zone $_z: duplicate networks removed"
done
uci -q commit firewall

uci -q set 5gmodem.@5gmodem[0].fwzone_dedupe=1
uci -q commit 5gmodem
exit 0
