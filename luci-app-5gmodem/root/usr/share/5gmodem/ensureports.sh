#!/bin/sh

RES="/usr/share/5gmodem"
PORT="$1"

. "$RES/lib.sh" 2>/dev/null
. "$RES/quirks.sh" 2>/dev/null

pick_sms_port() {
	_at=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	_path=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_path" ] || return 1
	command -v bg_at_off >/dev/null 2>&1 && bg_at_off "$_path" && return 1

	_ep_sec="m_$(printf '%s' "$_path" | sed 's/[^A-Za-z0-9]/_/g')"
	_ep_if=$(uci -q get "5gmodem.$_ep_sec.network")
	[ -n "$_ep_if" ] || _ep_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ "$(uci -q get "network.$_ep_if.proto" 2>/dev/null)" = "modemmanager" ] && return 1

	for _t in $(drop_dial_port "$_path" $("$RES/listmodems.sh" 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$_path\"].tty[*]" 2>/dev/null)); do
		[ -c "$_t" ] || continue
		[ "$_t" = "$_at" ] && continue
		if "$RES/atprobe.sh" "$_t" >/dev/null 2>&1; then echo "$_t"; return 0; fi
	done
	return 1
}

_SNDP=$(sms_send_port "$(uci -q get 5gmodem.@5gmodem[0].active_modem)")
SHARED=$(uci -q get 5gmodem.sms.shared_at_port)
[ -n "$_SNDP" ] && SHARED=1
if [ -z "$PORT" ] && [ "$SHARED" = 1 ]; then
	_sh_at=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	[ -c "$_sh_at" ] && PORT="$_sh_at"
fi
[ -n "$PORT" ] || PORT=$(pick_sms_port)
[ -n "$PORT" ] || PORT=$("$RES/detect.sh" 2>/dev/null)

if [ -z "$PORT" ] || [ ! -c "$PORT" ]; then
	echo '{"ok":0,"reason":"no port"}'
	exit 0
fi

_ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
_DLP=$(dial_port_for_path "$(uci -q get 5gmodem.@5gmodem[0].active_modem)")

CHANGED=0
for _opt in readport sendport ussdport atport; do
	_cur=$(uci -q get "5gmodem.sms.$_opt")
	if [ -z "$_cur" ] || [ ! -c "$_cur" ] || \
	   { [ "$SHARED" != 1 ] && [ -n "$_ATP" ] && [ "$_cur" = "$_ATP" ] && [ "$PORT" != "$_ATP" ]; } || \
	   { [ -n "$_DLP" ] && [ "$_cur" = "$_DLP" ] && [ "$PORT" != "$_DLP" ]; } || \
	   { [ "$_opt" != sendport ] && [ -n "$_SNDP" ] && [ "$_cur" = "$_SNDP" ] && [ "$PORT" != "$_SNDP" ]; }; then
		uci -q set "5gmodem.sms.$_opt=$PORT"
		CHANGED=1
	fi
done

if [ -n "$_SNDP" ] && [ "$(uci -q get 5gmodem.sms.sendport)" != "$_SNDP" ]; then
	uci -q set "5gmodem.sms.sendport=$_SNDP"
	CHANGED=1
fi

[ "$CHANGED" = 1 ] && uci -q commit 5gmodem

printf '{"ok":1,"port":"%s","changed":%s}\n' "$PORT" "$CHANGED"
