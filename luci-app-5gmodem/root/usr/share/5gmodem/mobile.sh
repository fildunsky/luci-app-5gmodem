#!/bin/sh

RES=/usr/share/5gmodem
. "$RES/lib.sh" 2>/dev/null
. "$RES/atlock.sh" 2>/dev/null

CFG=5gmodem
MARK=/tmp/5gmodem/airplane.applied

_log() { logger -t 5gmodem "mobile: $*"; }

_iface() {
	_mi_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_mi_n=""
	[ -n "$_mi_p" ] && _mi_n=$(uci -q get "$CFG.m_$(printf '%s' "$_mi_p" | sed 's/[^A-Za-z0-9]/_/g').network")
	[ -n "$_mi_n" ] || _mi_n=$(uci -q get "$CFG.@5gmodem[0].network")
	[ -n "$_mi_n" ] && uci -q get "network.$_mi_n" >/dev/null 2>&1 && printf '%s' "$_mi_n"
}

data_get() {
	_dg_i=$(_iface) || { echo unknown; return 1; }
	[ "$(uci -q get "network.$_dg_i.auto")" = 0 ] && echo off || echo on
}

data_set() {
	_ds_i=$(_iface) || { echo '{"error":"no modem interface"}'; return 1; }
	note_foreign_uci network "mobile data $1" 2>/dev/null
	if [ "$1" = off ]; then
		uci -q set "network.$_ds_i.auto=0"
		uci -q commit network
		_log "mobile data off ($_ds_i)"
		ifdown "$_ds_i" >/dev/null 2>&1
	else
		uci -q delete "network.$_ds_i.auto"
		uci -q commit network
		_log "mobile data on ($_ds_i)"
		ifup "$_ds_i" >/dev/null 2>&1
	fi
	echo '{"result":"ok"}'
}

_mm_idx() {
	command -v mmcli >/dev/null 2>&1 || return 1
	_mx_l=$(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$')
	# the modem shown on the page first: with two modems "the only one under ModemManager"
	# may be the other one
	_mx_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	if [ -n "$_mx_p" ]; then
		for _mx_m in $_mx_l; do
			_mx_k=$(mmcli -m "$_mx_m" -K 2>/dev/null)
			for _mx_d in $(printf '%s\n' "$_mx_k" | sed -n -e 's/^modem\.generic\.device *: *//p' -e 's/^modem\.generic\.physdev *: *//p'); do
				case "$_mx_d" in */"$_mx_p") printf '%s' "$_mx_m"; return 0 ;; esac
			done
		done
		# not found by path: the single modem counts only when the page modem runs under ModemManager
		_mx_i=$(_iface) || return 1
		proto_in mm "$(uci -q get "network.$_mx_i.proto")" || return 1
	fi
	[ "$(printf '%s\n' "$_mx_l" | grep -c .)" = 1 ] || return 1
	printf '%s' "$_mx_l"
}

radio() {
	_r_m=$(_mm_idx)
	if [ -n "$_r_m" ]; then
		if [ "$1" = off ]; then
			mmcli -m "$_r_m" --set-power-state-low >/dev/null 2>&1
		else
			mmcli -m "$_r_m" --set-power-state-on >/dev/null 2>&1
		fi
		return
	fi
	_r_p=$("$RES/detect.sh" 2>/dev/null)
	[ -n "$_r_p" ] || return 1
	# AT_QUERY_RAW: plain sms_tool output has no OK line, so the check never passed
	[ "$1" = off ] && _r_c="AT+CFUN=4" || _r_c="AT+CFUN=1"
	AT_QUERY_RAW=1 at_query "$_r_p" "$_r_c" 8 | tr -d '\r' | grep -q '^OK'
	_r_rc=$?; unset AT_QUERY_RAW; return $_r_rc
}

air_get() {
	[ "$(uci -q get "$CFG.@5gmodem[0].airplane")" = 1 ] && echo on || echo off
}

air_set() {
	if [ "$1" = on ]; then
		[ "$(air_get)" = on ] || uci -q set "$CFG.@5gmodem[0].airplane_data=$(data_get)"
		uci -q set "$CFG.@5gmodem[0].airplane=1"
		uci -q commit "$CFG"
		_log "airplane mode on"
		[ "$(data_get)" = off ] || data_set off >/dev/null
		rm -f "$MARK"
		radio off && : > "$MARK"
	else
		_as_d=$(uci -q get "$CFG.@5gmodem[0].airplane_data")
		uci -q delete "$CFG.@5gmodem[0].airplane"
		uci -q delete "$CFG.@5gmodem[0].airplane_data"
		uci -q commit "$CFG"
		rm -f "$MARK"
		_log "airplane mode off"
		radio on
		[ "$_as_d" = off ] || data_set on >/dev/null
	fi
	echo '{"result":"ok"}'
}

case "$1:$2" in
	data:get)     data_get ;;
	data:on|data:off)
		[ "$2" = on ] && [ "$(air_get)" = on ] && { echo '{"error":"airplane mode is on"}'; exit 1; }
		data_set "$2" ;;
	airplane:get) air_get ;;
	airplane:on|airplane:off) air_set "$2" ;;
	tick:)
		[ "$(air_get)" = on ] || exit 0
		[ -f "$MARK" ] && exit 0
		radio off && { : > "$MARK"; _log "airplane mode re-applied after boot"; } ;;
	*) echo "usage: $0 data get|on|off | airplane get|on|off | tick" >&2; exit 1 ;;
esac
exit 0
