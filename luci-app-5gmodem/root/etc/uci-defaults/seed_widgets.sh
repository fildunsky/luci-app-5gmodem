#!/bin/sh

CFG=5gmodem

uci -q get "$CFG.@5gmodem[0]" >/dev/null 2>&1 || exit 0

[ "$(uci -q get "$CFG.@5gmodem[0].widgets_seeded")" = "1" ] && exit 0

if ! uci -q show "$CFG" 2>/dev/null | grep -q "=pingwidget$"; then
	_s=$(uci add "$CFG" pingwidget) && {
		uci -q set "$CFG.$_s.host=youtube.com"
		uci -q set "$CFG.$_s.mode=click"
	}
fi

if ! uci -q show "$CFG" 2>/dev/null | grep -q "=svcwidget$"; then
	for _svc in nikki ssclash; do
		[ -x "/etc/init.d/$_svc" ] || continue
		_s=$(uci add "$CFG" svcwidget) && uci -q set "$CFG.$_s.service=$_svc"
		break
	done
fi

[ -n "$(uci -q get "$CFG.@5gmodem[0].netpri_rank")" ] \
	|| uci -q set "$CFG.@5gmodem[0].netpri_rank=icon"

uci -q set "$CFG.@5gmodem[0].widgets_seeded=1"
uci -q commit "$CFG"
exit 0
