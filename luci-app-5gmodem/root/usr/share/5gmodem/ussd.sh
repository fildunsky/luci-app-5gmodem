#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem
ST=/tmp/5gmodem/ussd.json
LOCK=/tmp/5gmodem/ussd.lock

. "$RES/lib.sh" 2>/dev/null
. "$RES/atlock.sh" 2>/dev/null

REG_WAIT=25

_st() {
	_s="$1"; _g="$2"; shift 2
	printf '{"status":"%s","stage":"%s"%s}\n' "$_s" "$_g" "$*" > "$ST"
}

_reg=""
_reg_for_port() {
	_reg=$("$RES/registry.sh" port "$1" 2>/dev/null)
	[ -n "$_reg" ] && [ "$_reg" != "{}" ]
}
_reg_field() {
	printf '%s' "$_reg" | jsonfilter -e "@.$1" 2>/dev/null
}

_port() {
	_p=$(uci -q get "$CFG.sms.ussdport")
	[ -n "$_p" ] && [ -c "$_p" ] && { echo "$_p"; return; }
	_p=$("$RES/registry.sh" active 2>/dev/null | jsonfilter -e '@.at_port' 2>/dev/null)
	[ -n "$_p" ] && [ -c "$_p" ] && { echo "$_p"; return; }
	"$RES/detect.sh" 2>/dev/null
}

_act() {
	sms_tool -d "$1" at 'AT+COPS?' 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+COPS:[[:space:]]*[0-9]*,[0-9]*,"[^"]*",\([0-9]*\).*/\1/p' | head -1
}

_is_cs() {
	case "$1" in
		''|7|11|13) return 1 ;;
		*) return 0 ;;
	esac
}

_mode_by_label() {
	"$RES/bands.sh" getsupportedmodes 2>/dev/null | tr ' ' '\n' | while IFS=: read -r _id _lb; do
		[ "$_lb" = "$1" ] && { echo "$_id"; break; }
	done
}
_mode_3g()   { _mode_by_label 3G ; }
_mode_auto() { _mode_by_label Auto ; }

_wait_reg() {
	_w=0
	while [ "$_w" -lt "$REG_WAIT" ]; do
		if [ "$_w" -lt 6 ]; then _s=1; else _s=3; fi
		sleep "$_s"; _w=$((_w + _s))
		at_lock "$1" 10 2>/dev/null
		_a=$(_act "$1")
		at_unlock 2>/dev/null
		if [ "$2" = 1 ]; then
			_is_cs "$_a" && return 0
		else
			[ -n "$_a" ] && return 0
		fi
	done
	return 1
}

_need3g() {
	_u3_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_u3_s="m_$(echo "$_u3_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_u3_n=$(uci -q get "$CFG.$_u3_s.ussd_3g" 2>/dev/null)
	if [ -z "$_u3_n" ]; then
		. "$RES/quirks.sh" 2>/dev/null
		if command -v ussd_needs_3g_for >/dev/null 2>&1; then
			_u3_n=$(ussd_needs_3g_for \
				"$(uci -q get "$CFG.$_u3_s.model" 2>/dev/null)" \
				"$(uci -q get "$CFG.$_u3_s.vidpid" 2>/dev/null)")
		fi
	fi
	case "$_u3_n" in 1) echo 1 ;; *) echo 0 ;; esac
}

_mm_act() {
	mmcli -m "$1" -K 2>/dev/null | sed -n 's/^modem\.generic\.access-technologies\.value\[[0-9]*\] *: *//p' | tr '\n' ' '
}

_mm_is_cs() {
	case " $1" in *" gsm"*|*" gprs"*|*" edge"*|*" umts"*|*" hsdpa"*|*" hsupa"*|*" hspa"*) return 0 ;; esac
	return 1
}

_mm_restore() {
	_mr_al=$(printf '%s' "$2" | sed -n 's/^allowed: *\([^;]*\);.*/\1/p' | sed 's/, */|/g')
	_mr_pr=$(printf '%s' "$2" | sed -n 's/.*preferred: *//p')
	[ -n "$_mr_al" ] || return 0
	case "$_mr_pr" in
		''|none) mmcli -m "$1" --set-allowed-modes="$_mr_al" >/dev/null 2>&1 ;;
		*) mmcli -m "$1" --set-allowed-modes="$_mr_al" --set-preferred-mode="$_mr_pr" >/dev/null 2>&1 ;;
	esac
	_mr_if=$(uci -q get "$CFG.$(secname "$(active_path)").network" 2>/dev/null)
	[ -n "$_mr_if" ] && ifup "$_mr_if" >/dev/null 2>&1
}

case "$1" in
status)
	[ -f "$ST" ] && cat "$ST" || echo '{"status":"idle","stage":""}'
	exit 0 ;;
cancel)
	_p=$(_port)
	[ -n "$_p" ] && { at_lock "$_p" 10 2>/dev/null; sms_tool -d "$_p" at 'AT+CUSD=2' >/dev/null 2>&1; at_unlock 2>/dev/null; }
	_st idle ""
	exit 0 ;;
send) : ;;
mm)
	case "$2" in ''|*[!0-9]*) echo '{"error":"bad modem"}'; exit 2 ;; esac
	case "$3" in initiate|respond) : ;; *) echo '{"error":"bad mode"}'; exit 2 ;; esac
	case "$4" in ''|*[!0-9*#+]*) echo '{"error":"bad code"}'; exit 2 ;; esac
	command -v mmcli >/dev/null 2>&1 || { echo '{"error":"no mmcli"}'; exit 2; }
	if command -v flock >/dev/null 2>&1; then
		exec 9>"$LOCK" 2>/dev/null || true
		flock -n 9 2>/dev/null || { echo '{"error":"busy"}'; exit 2; }
	fi
	_st running sending
	(
		MMSW=""
		if [ "$3" = initiate ] && [ "$(_need3g)" = 1 ] && ! _mm_is_cs "$(_mm_act "$2")" \
		   && mmcli -m "$2" -K 2>/dev/null | grep -q 'supported-modes\.value\[[0-9]*\] *: *allowed: 3g; preferred: none'; then
			MMCM=$(mmcli -m "$2" -K 2>/dev/null | sed -n 's/^modem\.generic\.current-modes *: *//p')
			_st running switching
			if mmcli -m "$2" --set-allowed-modes=3g >/dev/null 2>&1; then
				MMSW=1
				trap '_mm_restore "$2" "$MMCM"' EXIT INT TERM
				logger -t 5gmodem "ussd: modem $2 switched to 3G for the request (was: $MMCM)"
				_w=0
				while [ "$_w" -lt "$REG_WAIT" ]; do
					sleep 2; _w=$((_w + 2))
					_mm_is_cs "$(_mm_act "$2")" && break
				done
				_mm_is_cs "$(_mm_act "$2")" || logger -t 5gmodem "ussd: no 3G registration within ${REG_WAIT}s - sending the request as is"
			fi
			_st running sending
		fi
		OUT=$(mmcli -m "$2" --timeout=40 "--3gpp-ussd-$3=$4" 2>/tmp/5gmodem/ussd.err)
		ERR=$(cat /tmp/5gmodem/ussd.err 2>/dev/null)
		rm -f /tmp/5gmodem/ussd.err
		if [ -n "$MMSW" ]; then
			mmcli -m "$2" --timeout=8 --3gpp-ussd-cancel >/dev/null 2>&1
			_st running restoring
			_mm_restore "$2" "$MMCM"
			trap - EXIT INT TERM
		fi
		_st done "" ',"out":"'"$(_b64 "$OUT")"'","err":"'"$(_b64 "$ERR")"'"'
	) >/dev/null 2>&1 </dev/null &
	cat "$ST"
	exit 0 ;;
*) echo '{"error":"usage: send <code> | mm <modem> initiate|respond <code> | status | cancel"}'; exit 2 ;;
esac

CODE="$2"
case "$CODE" in
	''|*[!0-9*#+]*) _st idle ""; echo '{"error":"bad code"}'; exit 2 ;;
esac

PORT="${3:-$(_port)}"
[ -n "$PORT" ] && [ -c "$PORT" ] || { _st idle ""; echo '{"error":"no port"}'; exit 2; }

_ussd_busy() { echo '{"error":"busy"}'; exit 2; }
if command -v flock >/dev/null 2>&1; then
	exec 9>"$LOCK" 2>/dev/null || true
	flock -n 9 2>/dev/null || _ussd_busy
else
	if [ -f "$ST" ] && grep -q '"status":"running"' "$ST" 2>/dev/null; then
		_age=$(( $(date +%s) - $(date -r "$ST" +%s 2>/dev/null || echo 0) ))
		[ "$_age" -lt 120 ] && _ussd_busy
	fi
fi

_st running starting
(
	MODE3G=$(_mode_3g)
	CUR=$("$RES/bands.sh" getmode 2>/dev/null)
	[ -n "$CUR" ] || { sleep 3; CUR=$("$RES/bands.sh" getmode 2>/dev/null); }
	at_lock "$PORT" 15 2>/dev/null
	ACT=$(_act "$PORT")
	at_unlock 2>/dev/null

	SWITCHED=0
	_restore() {
		[ "$SWITCHED" = 1 ] || return 0
		_tgt="$CUR"
		[ -n "$_tgt" ] || _tgt=$(_mode_auto)
		[ -n "$_tgt" ] || return 0
		"$RES/bands.sh" setmodelive "$_tgt" >/dev/null 2>&1
		_wait_reg "$PORT" 0
		if [ "$("$RES/bands.sh" getmode 2>/dev/null)" = "$MODE3G" ]; then
			logger -t 5gmodem "ussd: network mode did not return from 3G, retrying ($_tgt)"
			"$RES/bands.sh" setmodelive "$_tgt" >/dev/null 2>&1
			_wait_reg "$PORT" 0
		fi
		_if=$(uci -q get "$CFG.$(secname "$(active_path)").network" 2>/dev/null)
		[ -n "$_if" ] && ifup "$_if" >/dev/null 2>&1
	}
	trap '_restore' EXIT INT TERM

	NOTE=""
	_reg_for_port "$PORT" || _reg=""
	_MODEL=$(_reg_field model)
	_VIDPID=$(_reg_field vidpid)
	_ISACT=$(_reg_field active)

	if [ -n "$_VIDPID" ] && [ -r "$RES/quirks.sh" ]; then
		. "$RES/quirks.sh" 2>/dev/null
		if command -v ussd_supported_for >/dev/null 2>&1 \
		   && [ "$(ussd_supported_for "$_MODEL" "$_VIDPID")" = "0" ]; then
			MODE3G=""
			NOTE=',"unsupported":1'
			logger -t 5gmodem "ussd: $_MODEL is listed as \"USSD does not work\" - not dropping to 3G"
		fi
	fi

	if [ -n "$MODE3G" ] && [ "$_ISACT" != "true" ]; then
		MODE3G=""
		NOTE=',"noswitch":"not_active"'
		logger -t 5gmodem "ussd: $PORT does not belong to the active modem - leaving the network mode alone"
	fi

	_try() {
		set -- -d "$PORT"
		[ "$(uci -q get "$CFG.sms.ussd")" = "0" ] || set -- "$@" -R
		set -- "$@" -r
		_cd=$(uci -q get "$CFG.sms.coding")
		case "$_cd" in ''|auto) : ;; *) set -- "$@" -c "$_cd" ;; esac

		at_lock "$PORT" 20 2>/dev/null
		OUT=$(sms_tool "$@" ussd "$CODE" 2>/tmp/5gmodem/ussd.err)
		at_unlock 2>/dev/null
		ERR=$(cat /tmp/5gmodem/ussd.err 2>/dev/null)
		rm -f /tmp/5gmodem/ussd.err
		[ -n "$OUT" ]
	}

	NEED3G=$(_need3g)

	if [ "$NEED3G" = "1" ] && ! _is_cs "$ACT" && [ -n "$MODE3G" ] && [ "$CUR" != "$MODE3G" ]; then
		_st running switching ',"from":"'"$ACT"'","mode_was":"'"$CUR"'","mode_3g":"'"$MODE3G"'"'
		"$RES/bands.sh" setmodelive "$MODE3G" >/dev/null 2>&1
		SWITCHED=1
		if ! _wait_reg "$PORT" 1; then
			NOTE=',"reason":"no_3g"'
			logger -t 5gmodem "ussd: CS registration did not appear within ${REG_WAIT}s - sending the request as is"
		fi
	fi

	_st running sending
	_try || :

	[ "$SWITCHED" = 1 ] && _st running restoring
	_restore
	SWITCHED=0
	trap - EXIT INT TERM

	_st done "" ',"out":"'"$(_b64 "$OUT")"'","err":"'"$(_b64 "$ERR")"'"'"$NOTE"
) >/dev/null 2>&1 </dev/null &

cat "$ST"
sleep 1
exit 0
