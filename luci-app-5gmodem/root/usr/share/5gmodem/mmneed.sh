#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem
RUN=/var/run/5gmodem-mm-inhibit

. /usr/share/5gmodem/lib.sh

_path_for_iface() {
	_s=$(sec_for_iface "$1")
	[ -n "$_s" ] && uci -q get "$CFG.$_s.path"
}

mm_needed() {
	for _pf in "$RUN"/*.pause; do [ -e "$_pf" ] && return 0; done
	_present=""
	_present_done=""
	_mm_iface_seen=""
	for _if in $(uci -q show network 2>/dev/null \
			| sed -n "s/^network\.\([^.]*\)\.proto='\?modemmanager'\?\$/\1/p"); do
		_mm_iface_seen=1
		_dev=$(uci -q get "network.$_if.device")
		case "$_dev" in
			/sys/*) [ -e "$_dev" ] && return 0; continue ;;
		esac
		_p=$(_path_for_iface "$_if")
		if [ -z "$_present_done" ]; then
			_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
			_present_done=1
		fi
		if [ -n "$_p" ]; then
			case " $_present " in *" $_p "*) return 0 ;; esac
			continue
		fi
		return 0
	done
	if [ -n "$_mm_iface_seen" ] && [ -z "$_present_done" ]; then
		_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
	fi
	if [ -n "$_mm_iface_seen" ] && [ -n "$(echo $_present)" ]; then
		return 0
	fi
	for _if in $(_mbimp_ifaces); do
		_dev=$(uci -q get "network.$_if.device")
		[ -c "$_dev" ] && return 0
	done
	return 1
}
_mbimp_ifaces() {
	[ -f /lib/netifd/proto/mbimp.sh ] || return 0
	uci -q show network 2>/dev/null | sed -nE "s/^network\.([^.]*)\.proto='?($(proto_re proxy))'?\$/\1/p"
}

_running() {
	pidof ModemManager >/dev/null 2>&1
}

case "$1" in
	check)
		_n=0; mm_needed && _n=1
		_r=0; _running && _r=1
		printf '{"needed":%d,"running":%d}\n' "$_n" "$_r"
		;;
	apply|grace|"")
		if mm_needed; then
			rm -f /tmp/5gmodem/mmneed_idle
			if ! _running; then
				/etc/init.d/modemmanager enable >/dev/null 2>&1
				/etc/init.d/modemmanager start >/dev/null 2>&1
				logger -t 5gmodem "ModemManager started: a connected modem is managed by it"
			fi
		else
			_mi_ok=1
			if [ "$1" = grace ]; then
				_mi_now=$(cut -d. -f1 /proc/uptime)
				_mi_was=$(cat /tmp/5gmodem/mmneed_idle 2>/dev/null)
				case "$_mi_was" in
					''|*[!0-9]*) echo "$_mi_now" > /tmp/5gmodem/mmneed_idle; _mi_ok=0 ;;
					*) [ "$_mi_was" -le "$_mi_now" ] && [ $((_mi_now - _mi_was)) -lt 300 ] && _mi_ok=0 ;;
				esac
			fi
			[ "$2" != now ] && [ "$(cut -d. -f1 /proc/uptime)" -lt 300 ] && _mi_ok=0
			if [ "$_mi_ok" = 1 ] && _running; then
				sleep 3
				mm_needed && exit 0
				rm -f /tmp/5gmodem/mmneed_idle
				/etc/init.d/modemmanager stop >/dev/null 2>&1
				/etc/init.d/modemmanager disable >/dev/null 2>&1
				logger -t 5gmodem "ModemManager stopped: no connected modem is managed by it"
				[ -n "$(_mbimp_ifaces)" ] || killall mbim-proxy 2>/dev/null
			fi
		fi
		;;
esac
exit 0
