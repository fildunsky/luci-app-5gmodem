#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

JSON=/etc/usb-mode.json
RES=/usr/share/5gmodem

BAD_IDS="413c:81d7 413c:81e0 413c:81e4 413c:81e6 413c:81d8 03f0:9d1d"

[ -f "$JSON" ] || exit 0

_fix_one() {
	grep -q "\"$1\"" "$JSON" 2>/dev/null || return 1
	[ -f "$JSON.5gmodem-bak" ] || cp "$JSON" "$JSON.5gmodem-bak" 2>/dev/null
	sed -e "/\"$1\": {/,/},/d" "$JSON" > "$JSON.tmp" 2>/dev/null || { rm -f "$JSON.tmp"; return 1; }
	if [ -s "$JSON.tmp" ] && jsonfilter -i "$JSON.tmp" -e '@.devices' >/dev/null 2>&1; then
		mv "$JSON.tmp" "$JSON"
		logger -t 5gmodem "usb_modeswitch: removed a harmful rule for $1 (it was breaking the modem composition)"
		return 0
	fi
	rm -f "$JSON.tmp"
	return 1
}

_scan_present() {
	command -v jsonfilter >/dev/null 2>&1 || return 0
	[ -x "$RES/listmodems.sh" ] || return 0
	for _pid in $("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e '@[*].vidpid' 2>/dev/null | sort -u); do
		case "$_pid" in
			[0-9a-f]*:[0-9a-f]*) : ;;
			*) continue ;;
		esac
		[ "$(jsonfilter -i "$JSON" -e "@.devices[\"$_pid\"][\"*\"].config" 2>/dev/null)" = "0" ] \
			|| continue
		_fix_one "$_pid" && { _changed=1; _reprobe "$_pid"; }
	done
}

_reprobe() {
	_rp_v=${1%%:*}; _rp_p=${1##*:}
	for _rp_d in /sys/bus/usb/devices/*; do
		[ -f "$_rp_d/idVendor" ] || continue
		[ "$(cat "$_rp_d/idVendor" 2>/dev/null)" = "$_rp_v" ] || continue
		[ "$(cat "$_rp_d/idProduct" 2>/dev/null)" = "$_rp_p" ] || continue
		_rp_mem="/tmp/5gmodem/lastcfg_$(echo "$1" | tr -d ':')"
		for _rp_x in "$_rp_d"/*/net/* "$_rp_d"/*/usbmisc/cdc-wdm* "$_rp_d"/*/cdc-wdm*; do
			[ -e "$_rp_x" ] && { cat "$_rp_d/bConfigurationValue" > "$_rp_mem" 2>/dev/null; return 0; }
		done
		_rp_cfg=$(cat "$_rp_d/bConfigurationValue" 2>/dev/null | tr -cd '0-9')
		if [ -z "$_rp_cfg" ] || [ "$_rp_cfg" = 0 ]; then
			:
		else
			_rp_has=0
			for _rp_i in "$_rp_d"/*:*/bInterfaceClass; do
				[ -f "$_rp_i" ] || continue
				case "$(cat "$_rp_i" 2>/dev/null)" in
					02) [ "$(cat "${_rp_i%Class}SubClass" 2>/dev/null)" = "0e" ] && _rp_has=1 ;;
					ff) _rp_has=1 ;;
				esac
			done
			[ "$_rp_has" = 1 ] || return 0
		fi
		_rp_st="/tmp/5gmodem/reprobe_$(echo "$1" | tr -d ':')"
		if [ -f "$_rp_st" ] && [ -z "$(find "$_rp_st" -mmin +5 2>/dev/null)" ]; then
			return 0
		fi
		: > "$_rp_st" 2>/dev/null
		_rp_cur="$_rp_cfg"
		_rp_num=$(cat "$_rp_d/bNumConfigurations" 2>/dev/null)
		case "$_rp_num" in ''|*[!0-9]*) return 0 ;; esac
		_rp_last=$(cat "$_rp_mem" 2>/dev/null | tr -cd '0-9')
		case "$_rp_cur" in
			''|0) _rp_set="${_rp_last:-$_rp_num}" ;;
			*)    _rp_set="$_rp_cur" ;;
		esac
		case "$_rp_set" in ''|0|*[!0-9]*) _rp_set="$_rp_num" ;; esac
		echo "$_rp_set" > "$_rp_d/bConfigurationValue" 2>/dev/null \
			&& logger -t 5gmodem "usb_modeswitch: $1 was left without a data channel - re-applied USB configuration $_rp_set to make the kernel bind drivers again"
		return 0
	done
}

_changed=0
for _id in ${1:-$BAD_IDS}; do
	_fix_one "$_id" && _changed=1
done
[ -n "$1" ] || _scan_present

for _id in ${1:-$BAD_IDS}; do
	_reprobe "$_id"
done
exit 0
