#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null

RES=/usr/share/5gmodem

_qr_recent() {
	[ -f "$1" ] || return 1
	_qr_w=$(cat "$1" 2>/dev/null)
	_qr_n=$(cut -d. -f1 /proc/uptime)
	case "$_qr_w" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_qr_w" -le "$_qr_n" ] && [ $((_qr_n - _qr_w)) -lt 180 ]
}

qmi_pool_exhausted() {
	[ -n "$1" ] && [ -e "$1" ] || return 1
	_qpe_o="/tmp/5gmodem/qmipool.$$"
	qmicli -p -d "$1" --nas-get-serving-system >"$_qpe_o" 2>&1 </dev/null &
	_qpe_p=$!
	_qpe_n=0
	while kill -0 "$_qpe_p" 2>/dev/null && [ "$_qpe_n" -lt 8 ]; do
		sleep 1; _qpe_n=$((_qpe_n + 1))
	done
	kill -9 "$_qpe_p" 2>/dev/null
	wait "$_qpe_p" 2>/dev/null
	grep -qi "ClientIdsExhausted" "$_qpe_o" 2>/dev/null; _qpe_rc=$?
	rm -f "$_qpe_o"
	return $_qpe_rc
}

_mm_failed_unknowncaps() {
	command -v mmcli >/dev/null 2>&1 || return 1
	for _i in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		_d=$(mmcli -m "$_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		case "$_d" in *"$1") ;; *) continue ;; esac
		[ "$(mmcli -m "$_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state-failed-reason *: *//p')" \
			= "unknown-capabilities" ] && return 0
		return 1
	done
	return 1
}

qmi_pool_recover() {
	_qp="$1"; [ -n "$_qp" ] || return 1
	pgrep -f 'sbin/ModemManager' >/dev/null 2>&1 || return 1
	QMI_TARGET_PATH="$_qp"
	command -v qmi_channel_free >/dev/null 2>&1 && qmi_channel_free || return 1
	_lm=$("$RES/listmodems.sh" 2>/dev/null)
	_qw=$(printf '%s' "$_lm" | jsonfilter -e "@[@.path=\"$_qp\"].wdm[0]" 2>/dev/null)
	[ -n "$_qw" ] && [ -e "$_qw" ] || return 1
	_trig=""
	qmi_pool_exhausted "$_qw" && _trig="QMI client pool exhausted"
	[ -z "$_trig" ] && _mm_failed_unknowncaps "$_qp" && _trig="MM failed: unknown-capabilities"
	[ -n "$_trig" ] || return 1
	_mk="/tmp/5gmodem/qmirecover_$(printf '%s' "$_qp" | tr -c 'A-Za-z0-9' _)"
	_qr_recent "$_mk" && return 1
	for _t in $(printf '%s' "$_lm" | jsonfilter -e "@[@.path=\"$_qp\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		at_query "$_t" "AT" 5 | grep -q "OK" || continue
		logger -t 5gmodem "$_trig on $_qp - resetting the modem (AT+CFUN=1,1 on $_t)"
		cut -d. -f1 /proc/uptime > "$_mk" 2>/dev/null
		at_query "$_t" "AT+CFUN=1,1" 5 >/dev/null 2>&1
		return 0
	done
	logger -t 5gmodem "QMI pool exhausted on $_qp, but no live AT port to reset with"
	return 1
}

qmi_force_reset() {
	_fr_p="$1"; [ -n "$_fr_p" ] || return 1
	_mk="/tmp/5gmodem/qmirecover_$(printf '%s' "$_fr_p" | tr -c 'A-Za-z0-9' _)"
	_qr_recent "$_mk" && return 1
	_lm=$("$RES/listmodems.sh" 2>/dev/null)
	for _t in $(printf '%s' "$_lm" | jsonfilter -e "@[@.path=\"$_fr_p\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		at_query "$_t" "AT" 5 | grep -q "OK" || continue
		logger -t 5gmodem "${2:-reset needed} on $_fr_p - resetting the modem (AT+CFUN=1,1 on $_t)"
		cut -d. -f1 /proc/uptime > "$_mk" 2>/dev/null
		at_query "$_t" "AT+CFUN=1,1" 5 >/dev/null 2>&1
		return 0
	done
	logger -t 5gmodem "${2:-reset needed} on $_fr_p, but no live AT port to reset with"
	return 1
}

case "$1" in
	check)   qmi_pool_exhausted "$2" && echo exhausted || echo ok ;;
	recover) qmi_pool_recover "$2" ;;
	reset)   qmi_force_reset "$2" "$3" ;;
	*) echo "usage: $0 {check <cdc-wdm>|recover <usb-path>|reset <usb-path> [reason]}" >&2; exit 1 ;;
esac
