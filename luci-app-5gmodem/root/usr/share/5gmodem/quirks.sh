#!/bin/sh
# see docs/subsystems/polling-quirks.md for how each entry was verified
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

ussd_raw_for() {
	case "$1" in
		*SIM7600*) echo 1; return ;;
	esac

	case "$2" in
		0e8d:7127|0e8d:7126) return ;;
		1bc7:1040) echo 1; return ;;
	esac

	return
}

ussd_needs_3g_for() {
	case "$2" in
		1bc7:1040) echo 1; return ;;
	esac
	return
}

ussd_supported_for() {
	case "$2" in
		0e8d:7127|0e8d:7126) echo 0; return ;;
		2c7c:0306)
			case "$1" in *EP06-E*|*EG06-E*) echo 0; return ;; esac
			return ;;
	esac
	return
}

sim_slots_via() {
	case "$2" in
		1bc7:1040) echo simdet; return ;;
		1bc7:1070|1bc7:1077|1bc7:1080) echo qmi; return ;;
		0e8d:7127|0e8d:7126) echo gtdualsim; return ;;
		1199:90d3|1199:90e3) echo uims; return ;;
		05c6:90d6) echo ceiswitchsim; return ;;
		05c6:90d5)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo ceiswitchsim; return ;;
			esac
			echo qmi; return ;;
		05c6:9025|413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911) echo qmi; return ;;
		1e2d:00b7)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo ceiswitchsim; return ;;
			esac
			echo qmi; return ;;
		1e2d:00b3|1e2d:00b8|1e2d:00b9) echo qmi; return ;;
		0489:e0f0|1e2d:00f1|1e2d:00f2|1e2d:00f3|1e2d:00f4) echo qmi; return ;;
		2c7c:0306) echo qmi; return ;;
		2c7c:0800|2c7c:0801|2c7c:0900|2c7c:0512|2c7c:0620) echo quimslot; return ;;
	esac
	case "$1" in
		*SIM7600*) echo none; return ;;
	esac
	return
}

esim_reset_after_switch() {
	case "$2" in
		05c6:90d5)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo 0; return ;;
			esac
			echo 1; return ;;
		05c6:9025|413c:81d7|413c:81e0|413c:81e4|0489:e0b5) echo 1; return ;;
		1e2d:00b7)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo 0; return ;;
			esac
			echo 1; return ;;
		1e2d:00b3|1e2d:00b8|1e2d:00b9) echo 1; return ;;
		0489:e0f0|1e2d:00f1|1e2d:00f2|1e2d:00f3|1e2d:00f4) echo 1; return ;;
	esac
	echo 0
}

mm_at_fragile() {
	case "$1" in
		413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911) echo 1 ;;
	esac
}

_mm_index_cached() {
	_mic_c="/tmp/5gmodem/mmowns_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	_mic_i=""
	if [ -s "$_mic_c" ] && [ -n "$(find "$_mic_c" -mmin -1 2>/dev/null)" ]; then
		read -r _mic_i < "$_mic_c" 2>/dev/null
	else
		_mic_i=$(/usr/share/5gmodem/modemswitch.sh mmindex "$1" 2>/dev/null)
		printf '%s\n' "${_mic_i:-none}" > "$_mic_c" 2>/dev/null
	fi
	[ "$_mic_i" = "none" ] && _mic_i=""
	echo "$_mic_i"
}

_mm_ports_cached() {
	_mpc_c="/tmp/5gmodem/mmports_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ -s "$_mpc_c" ] && [ -n "$(find "$_mpc_c" -mmin -1 2>/dev/null)" ]; then
		cat "$_mpc_c" 2>/dev/null
		return 0
	fi
	mmcli -m "$2" -K 2>/dev/null \
		| sed -n 's/^modem\.generic\.ports\.value\[[0-9]*\] *: *\([^ ]*\) *(\(.*\))$/\1 \2/p' > "$_mpc_c.$$"
	mv -f "$_mpc_c.$$" "$_mpc_c" 2>/dev/null
	cat "$_mpc_c" 2>/dev/null
}

_tty_ifnum() {
	_ti_d=$(readlink -f "/sys/class/tty/$1/device" 2>/dev/null)
	[ -n "$_ti_d" ] || return 1
	[ -f "$_ti_d/bInterfaceNumber" ] || _ti_d=${_ti_d%/*}
	[ -f "$_ti_d/bInterfaceNumber" ] || return 1
	_ti_p=${_ti_d##*/}; _ti_p=${_ti_p%%:*}
	echo "$_ti_p $(cat "$_ti_d/bInterfaceNumber" 2>/dev/null)"
}

sms_send_port() {
	[ -n "$1" ] && [ -f "/sys/bus/usb/devices/$1/idVendor" ] || return 1
	case "$(cat "/sys/bus/usb/devices/$1/idVendor"):$(cat "/sys/bus/usb/devices/$1/idProduct")" in
		0e8d:7127) _ssp_if=06 ;;
		*) return 1 ;;
	esac
	for _ssp_t in /sys/class/tty/ttyUSB*; do
		[ -e "$_ssp_t" ] || continue
		[ "$(_tty_ifnum "${_ssp_t##*/}")" = "$1 $_ssp_if" ] || continue
		[ -c "/dev/${_ssp_t##*/}" ] && { echo "/dev/${_ssp_t##*/}"; return 0; }
	done
	return 1
}

mm_dedicated_at() {
	[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
	[ "$(uci -q get "5gmodem.$2.no_at" 2>/dev/null)" = "1" ] && return 0
	_mda_nif=$(uci -q get "5gmodem.$2.network")
	case "$(uci -q get "network.$_mda_nif.proto" 2>/dev/null)" in modemmanager|mbimp) ;; *) return 0 ;; esac
	command -v mmcli >/dev/null 2>&1 || return 0
	_mda_i=$(_mm_index_cached "$1")
	[ -n "$_mda_i" ] || return 0
	_mda_ports=$(_mm_ports_cached "$1" "$_mda_i")
	[ -n "$_mda_ports" ] || return 0
	_mda_if=$(uci -q get "5gmodem.$2.mm_at_if")
	if [ -z "$_mda_if" ] || [ "$(uci -q get "5gmodem.$2.mm_at_vp")" != "$3" ]; then
		_mda_at=$(echo "$_mda_ports" | awk '$2 == "at" && $1 ~ /^tty/ { print $1 }')
		[ "$(echo "$_mda_at" | grep -c .)" -ge 2 ] || return 0
		_mda_t=$(echo "$_mda_at" | tail -n 1)
		set -- "$1" "$2" "$3" $(_tty_ifnum "$_mda_t")
		[ "$4" = "$1" ] && [ -n "$5" ] || return 0
		if exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
			uci -q set "5gmodem.$2.mm_at_if=$5"
			uci -q set "5gmodem.$2.mm_at_vp=$3"
			uci -q commit 5gmodem 2>/dev/null
			flock -u 6
			logger -t 5gmodem "mm-at: $1 has two AT ports under ModemManager - $_mda_t (interface $5) will be kept for metrics from the next reconnect" >/dev/null 2>&1
		fi
		return 0
	fi
	for _mda_d in /sys/bus/usb/devices/"$1":*; do
		[ "$(cat "$_mda_d/bInterfaceNumber" 2>/dev/null)" = "$_mda_if" ] || continue
		for _mda_n in "$_mda_d"/ttyUSB* "$_mda_d"/tty/tty*; do
			[ -e "$_mda_n" ] || continue
			_mda_n=${_mda_n##*/}
			[ -c "/dev/$_mda_n" ] || continue
			echo "$_mda_ports" | awk -v t="$_mda_n" '$1 == t { f = 1 } END { exit !f }' && return 0
			echo "/dev/$_mda_n"
			return 0
		done
	done
	return 0
}

mm_tty_reserved() {
	set -- "$1" $(_tty_ifnum "$1")
	[ -n "$3" ] || return 1
	_mtr_s="m_$(echo "$2" | sed 's/[^A-Za-z0-9]/_/g')"
	_mtr_if=$(uci -q get "5gmodem.$_mtr_s.mm_at_if")
	[ -n "$_mtr_if" ] && [ "$_mtr_if" = "$3" ] || return 1
	[ -f "/sys/bus/usb/devices/$2/idVendor" ] || return 1
	_mtr_vp="$(cat "/sys/bus/usb/devices/$2/idVendor"):$(cat "/sys/bus/usb/devices/$2/idProduct")"
	[ "$(uci -q get "5gmodem.$_mtr_s.mm_at_vp")" = "$_mtr_vp" ] || return 1
	[ -n "$(mm_at_fragile "$_mtr_vp")" ] || return 1
	[ "$(uci -q get "5gmodem.$_mtr_s.no_at" 2>/dev/null)" = "1" ] && return 1
	_mtr_nif=$(uci -q get "5gmodem.$_mtr_s.network")
	case "$(uci -q get "network.$_mtr_nif.proto" 2>/dev/null)" in modemmanager|mbimp) return 0 ;; esac
	return 1
}

mm_at_allowed() {
	MM_AT_PORT=""
	_maa_vp=""
	[ -n "$1" ] && [ -f "/sys/bus/usb/devices/$1/idVendor" ] && \
		_maa_vp="$(cat "/sys/bus/usb/devices/$1/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$1/idProduct" 2>/dev/null)"
	if [ -n "$(mm_at_fragile "$_maa_vp")" ]; then
		MM_AT_PORT=$(mm_dedicated_at "$1" "$2" "$_maa_vp")
		[ -n "$MM_AT_PORT" ] && return 0
	fi
	[ "$(uci -q get "5gmodem.$2.mm_at" 2>/dev/null)" = "1" ] && return 0
	[ -n "$(mm_at_fragile "$_maa_vp")" ] && return 2
	_maa_if=$(uci -q get "5gmodem.$2.network" 2>/dev/null)
	case "$(uci -q get "network.$_maa_if.proto" 2>/dev/null)" in
		mbimp)
			ubus call "network.interface.$_maa_if" status 2>/dev/null | grep -q '"up": true' && return 0
			[ -s "/tmp/5gmodem/mbimp_sim_$_maa_if" ]
			return $? ;;
	esac
	command -v mmcli >/dev/null 2>&1 || return 1
	_maa_i=$(_mm_index_cached "$1")
	[ -n "$_maa_i" ] || return 1
	[ "$(mmcli -m "$_maa_i" -K 2>/dev/null \
		| sed -n 's/^modem\.generic\.state *: *//p' | head -1)" = "connected" ]
}
