#!/bin/sh

_z=$(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
[ -n "$_z" ] || exit 0

_nets=$(uci -q get "firewall.$_z.network")
_max=0
for _n in $_nets; do
	_m=$(uci -q get "network.$_n.metric")
	case "$_m" in ''|*[!0-9]*) continue ;; esac
	[ "$_m" -gt "$_max" ] && _max="$_m"
done

_seen=""
_changed=0
for _n in $_nets; do
	_m=$(uci -q get "network.$_n.metric")
	case "$_m" in ''|*[!0-9]*) continue ;; esac
	_d=$(uci -q get "network.$_n.device")
	_dup=""
	for _e in $_seen; do
		_em=${_e%%|*}; _rest=${_e#*|}; _en=${_rest%%|*}; _ed=${_rest#*|}
		[ "$_em" = "$_m" ] || continue
		[ -n "$_d" ] && [ "$_d" = "$_ed" ] && continue
		case "$_n" in "${_en}6"|"${_en}_6") continue ;; esac
		case "$_en" in "${_n}6"|"${_n}_6") continue ;; esac
		_dup=1
		break
	done
	if [ -n "$_dup" ]; then
		_max=$((_max + 10))
		uci -q set "network.$_n.metric=$_max"
		logger -t 5gmodem "migration: $_n shared metric $_m with another uplink - moved to $_max"
		_changed=1
		_m="$_max"
	fi
	_seen="$_seen $_m|$_n|$_d"
done

[ "$_changed" = 1 ] && uci -q commit network
exit 0
