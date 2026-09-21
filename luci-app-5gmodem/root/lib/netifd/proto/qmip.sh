#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

QMIP_KEEPER=/usr/share/5gmodem/qmip-keeper.sh

proto_qmip_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string pincode
	proto_config_add_int delay
	proto_config_add_boolean allow_roaming
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pdptype
	proto_config_add_string devpath
	proto_config_add_int profile
	proto_config_add_boolean dhcp
	proto_config_add_boolean dhcpv6
	proto_config_add_boolean sourcefilter
	proto_config_add_boolean delegate
	proto_config_add_int mtu
	proto_config_add_int timeout
	proto_config_add_defaults
}

_qmip_run() {
	local _qr_t="$1"; shift
	local _qr_o="/tmp/qmip.$$.out"
	"$@" > "$_qr_o" 2>&1 </dev/null &
	local _qr_p=$! _qr_n=0
	while kill -0 "$_qr_p" 2>/dev/null && [ "$_qr_n" -lt "$_qr_t" ]; do
		sleep 1; _qr_n=$((_qr_n + 1))
	done
	local _qr_rc=0
	if kill -0 "$_qr_p" 2>/dev/null; then
		kill -9 "$_qr_p" 2>/dev/null
		_qr_rc=124
	fi
	wait "$_qr_p" 2>/dev/null || [ "$_qr_rc" = 124 ] || _qr_rc=$?
	cat "$_qr_o" 2>/dev/null
	rm -f "$_qr_o"
	return $_qr_rc
}

_qmip_cli() {
	local _qc_t="$1"; shift
	_qmip_run "$_qc_t" qmicli -p -d "$_QMIP_DEV" "$@"
}

_qmip_q() {
	printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1: *'\\(.*\\)'[[:space:]]*\$/\\1/p" | head -n 1
}

_qmip_v() {
	printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1: *\\(.*\\)\$/\\1/p" | tr -d "'" | sed 's/[[:space:]]*$//' | head -n 1
}

_qmip_proxy() {
	local _qp_pid
	_qp_pid=$(pidof qmi-proxy 2>/dev/null | awk '{print $1}')
	if [ -n "$_qp_pid" ]; then
		case "$(tr '\0' ' ' < "/proc/$_qp_pid/cmdline" 2>/dev/null)" in
			*--no-exit*|*--empty-timeout=0*) return 0 ;;
		esac
		pidof ModemManager >/dev/null 2>&1 && return 0
		kill "$_qp_pid" 2>/dev/null
		sleep 1
	fi
	local _qp_bin=""
	for _qp_bin in /usr/libexec/qmi-proxy /usr/lib/libqmi/qmi-proxy /usr/lib/qmi-proxy; do
		[ -x "$_qp_bin" ] && break
		_qp_bin=""
	done
	[ -n "$_qp_bin" ] || return 0
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -x "$_qp_bin" -- --no-exit >/dev/null 2>&1
	else
		( "$_qp_bin" --no-exit </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
	fi
	local _qp_n=0
	while ! pidof qmi-proxy >/dev/null 2>&1 && [ "$_qp_n" -lt 5 ]; do
		sleep 1; _qp_n=$((_qp_n + 1))
	done
	return 0
}

_qmip_fail() {
	echo "QMI+MM[$$] $3"
	proto_notify_error "$1" "$2"
	[ "$4" = block ] && proto_block_restart "$1"
	return 1
}

_qmip_stop() {
	case "$1" in ''|*[!0-9]*) return 0 ;; esac
	case "$2" in
		''|*[!0-9]*) _qmip_cli 10 --wds-noop --client-cid="$1" >/dev/null 2>&1 ;;
		*) _qmip_cli 15 --wds-stop-network="$2" --client-cid="$1" >/dev/null 2>&1 ;;
	esac
}

_qmip_usbid() {
	local _ui_d
	_ui_d=$(readlink -f "/sys/class/usbmisc/${1##*/}/device" 2>/dev/null)
	_ui_d="${_ui_d%/*}"
	[ -f "$_ui_d/devnum" ] || return 0
	echo "$(cat "$_ui_d/busnum" 2>/dev/null)-$(cat "$_ui_d/devnum" 2>/dev/null)"
}

_qmip_drop_state() {
	local _ds_if="$1" _ds_now="$2" _ds_f _ds_was
	_ds_was=$(uci_get_state network "$_ds_if" qmip_usbid)
	for _ds_f in 4 6; do
		if [ -n "$_ds_now" ] && [ "$_ds_was" = "$_ds_now" ]; then
			_qmip_stop "$(uci_get_state network "$_ds_if" "qmip_cid_$_ds_f")" "$(uci_get_state network "$_ds_if" "qmip_pdh_$_ds_f")"
		fi
		uci_revert_state network "$_ds_if" "qmip_cid_$_ds_f"
		uci_revert_state network "$_ds_if" "qmip_pdh_$_ds_f"
	done
	uci_revert_state network "$_ds_if" qmip_usbid
}

_qmip_start() {
	local _st_fam="$1" _st_str="$2" _st_out _st_cid _st_pdh
	_st_out=$(_qmip_cli 20 --wds-set-ip-family="$_st_fam" --client-no-release-cid)
	_st_cid=$(_qmip_q 'CID' "$_st_out")
	case "$_st_cid" in ''|*[!0-9]*) echo "QMI+MM[$$] Unable to obtain a WDS client (IPv$_st_fam)"; return 1 ;; esac
	_st_out=$(_qmip_cli 60 --wds-start-network="$_st_str,ip-type=$_st_fam" --client-cid="$_st_cid" --client-no-release-cid)
	_st_pdh=$(_qmip_q 'Packet data handle' "$_st_out")
	case "$_st_pdh" in
		''|*[!0-9]*)
			printf '%s\n' "$_st_out" | grep -iE "error|fail|reason" | head -n 3
			_qmip_stop "$_st_cid" ""
			return 1 ;;
	esac
	_QMIP_CID="$_st_cid"
	_QMIP_PDH="$_st_pdh"
	return 0
}

_qmip_radio_on() {
	local _ro_if="$1" _ro_p _ro_i _ro_s _ro_out
	_ro_p=$(uci -q get "network.$_ro_if.modem_path" 2>/dev/null)
	if [ -n "$_ro_p" ] && command -v mmcli >/dev/null 2>&1 && pidof ModemManager >/dev/null 2>&1; then
		_ro_i=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_ro_p" 2>/dev/null)
		case "$_ro_i" in
			''|*[!0-9]*) ;;
			*)
				_ro_s=$(mmcli -m "$_ro_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -n 1)
				if [ "$_ro_s" = "disabled" ]; then
					echo "QMI+MM[$$] Enabling the modem in ModemManager (radio is off)"
					_qmip_run 30 mmcli -m "$_ro_i" --enable >/dev/null
				fi
				return 0 ;;
		esac
	fi
	_ro_out=$(_qmip_cli 15 --dms-get-operating-mode)
	case "$(_qmip_q 'Mode' "$_ro_out")" in
		online|'') ;;
		*)
			echo "QMI+MM[$$] Switching the modem radio online"
			_qmip_cli 20 --dms-set-operating-mode=online >/dev/null ;;
	esac
}

_qmip_mask2prefix() {
	local _mp_n=0 _mp_o IFS=.
	for _mp_o in $1; do
		case "$_mp_o" in
			255) _mp_n=$((_mp_n + 8)) ;;
			254) _mp_n=$((_mp_n + 7)) ;;
			252) _mp_n=$((_mp_n + 6)) ;;
			248) _mp_n=$((_mp_n + 5)) ;;
			240) _mp_n=$((_mp_n + 4)) ;;
			224) _mp_n=$((_mp_n + 3)) ;;
			192) _mp_n=$((_mp_n + 2)) ;;
			128) _mp_n=$((_mp_n + 1)) ;;
		esac
	done
	echo "$_mp_n"
}

proto_qmip_setup() {
	local interface="$1"
	local allow_roaming apn auth delay device devpath password pincode username profile
	json_get_vars allow_roaming apn auth delay device devpath password pincode username profile
	local dhcp dhcpv6 pdptype timeout
	json_get_vars dhcp dhcpv6 pdptype timeout
	local delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS
	json_get_vars delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS
	local ipv6
	[ ! -e /proc/sys/net/ipv6 ] && ipv6=0 || json_get_var ipv6 ipv6

	[ -n "$ctl_device" ] && device=$ctl_device
	if [ -n "$devpath" ]; then
		local _p
		for _p in "$devpath"/usbmisc/cdc-wdm* "$devpath"/*/usbmisc/cdc-wdm*; do
			[ -e "$_p" ] || continue
			device="/dev/${_p##*/}"
			break
		done
	fi
	[ -n "$device" ] || { proto_set_available "$interface" 0; _qmip_fail "$interface" NO_DEVICE "No control device specified"; return 1; }
	[ -c "$device" ] || { proto_set_available "$interface" 0; _qmip_fail "$interface" NO_DEVICE "The control device $device does not exist"; return 1; }
	command -v qmicli >/dev/null 2>&1 || { _qmip_fail "$interface" NO_QMICLI "qmicli is not installed (package qmi-utils)" block; return 1; }

	local devname ifname syspath
	devname="$(basename "$device")"
	syspath="$(readlink -f "/sys/class/usbmisc/$devname/device/")"
	ifname="$(ls "$syspath"/net 2>/dev/null | head -n 1)"
	[ -n "$ifname" ] || { proto_set_available "$interface" 0; _qmip_fail "$interface" NO_IFNAME "Failed to find the network interface of $device"; return 1; }
	[ -n "$apn" ] || { _qmip_fail "$interface" NO_APN "No APN specified"; return 1; }

	[ -n "$delay" ] && sleep "$delay"
	[ -n "$timeout" ] || timeout=30
	_QMIP_DEV="$device"
	_qmip_proxy
	local usbid
	usbid=$(_qmip_usbid "$device")
	_qmip_drop_state "$interface" "$usbid"

	local out n
	echo "QMI+MM[$$] Waiting for the SIM"
	n=0
	while :; do
		out=$(_qmip_cli 20 --uim-get-card-status)
		case "$out" in
			*"Application state: 'ready'"*) break ;;
			*"Application state: 'pin1-or-upin-pin-required'"*)
				if [ -n "$pincode" ]; then
					echo "QMI+MM[$$] Sending pin"
					_qmip_cli 20 --uim-verify-pin="PIN1,$pincode" >/dev/null 2>&1
					pincode=""
				else
					_qmip_fail "$interface" PIN_FAILED "PIN required" block
					return 1
				fi ;;
			*"Application state: 'puk1-or-upin-puk-required'"*|*"Application state: 'pin1-blocked'"*)
				_qmip_fail "$interface" PIN_FAILED "SIM is blocked (PUK required)" block
				return 1 ;;
		esac
		n=$((n + 3))
		[ "$n" -ge "$timeout" ] && { _qmip_fail "$interface" SIM_NOT_READY "SIM is not ready"; return 1; }
		sleep 3
	done

	_qmip_radio_on "$interface"

	echo "QMI+MM[$$] Register with network"
	local reg="" roam="" ok=0
	n=0
	while :; do
		out=$(_qmip_cli 20 --nas-get-serving-system)
		reg=$(_qmip_q 'Registration state' "$out")
		roam=$(_qmip_q 'Roaming status' "$out")
		if [ "$reg" = "registered" ]; then
			case "$out" in
				*"PS: 'attached'"*)
					if [ "$roam" = "on" ] && [ "$allow_roaming" != 1 ]; then ok=2; else ok=1; fi ;;
			esac
		fi
		[ "$ok" != 0 ] && break
		n=$((n + 3))
		[ "$n" -ge "$timeout" ] && break
		sleep 3
	done
	if [ "$ok" = 2 ]; then
		_qmip_fail "$interface" ROAMING "Registered in roaming, but roaming is not allowed"
		return 1
	fi
	if [ "$ok" != 1 ]; then
		_qmip_fail "$interface" NO_REGISTRATION "Registration failed (state: ${reg:-no answer})"
		return 1
	fi
	echo "QMI+MM[$$] Registered ($(_qmip_q 'Description' "$out"))"

	out=$(_qmip_cli 15 --wds-get-autoconnect-settings)
	case "$out" in
		*"Status: 'enabled'"*|*"Status: 'paused'"*)
			echo "QMI+MM[$$] Disabling the modem's own autoconnect"
			_qmip_cli 20 --wds-stop-network=disable-autoconnect >/dev/null 2>&1 ;;
	esac

	out=$(_qmip_cli 15 --wda-get-data-format)
	if [ "$(_qmip_q 'Link layer protocol' "$out")" = "raw-ip" ] && [ -f "/sys/class/net/$ifname/qmi/raw_ip" ] \
	   && [ "$(cat "/sys/class/net/$ifname/qmi/raw_ip" 2>/dev/null)" != "Y" ]; then
		echo "QMI+MM[$$] Switching $ifname to raw-ip"
		ip link set dev "$ifname" down 2>/dev/null
		echo Y > "/sys/class/net/$ifname/qmi/raw_ip" 2>/dev/null
	fi

	pdptype=$(echo "$pdptype" | awk '{print tolower($0)}')
	[ "$ipv6" = 0 ] && pdptype="ipv4"
	case "$pdptype" in ip) pdptype="ipv4" ;; ipv4|ipv6|ipv4v6) ;; *) pdptype="ipv4" ;; esac
	local cstr="apn=$apn"
	case "$(echo "$auth" | awk '{print tolower($0)}')" in
		pap) cstr="$cstr,auth=PAP" ;;
		chap) cstr="$cstr,auth=CHAP" ;;
		both) cstr="$cstr,auth=BOTH" ;;
	esac
	[ -n "$username" ] && cstr="$cstr,username=$username"
	[ -n "$password" ] && cstr="$cstr,password=$password"
	case "$profile" in ''|*[!0-9]*) ;; *) cstr="$cstr,3gpp-profile=$profile" ;; esac

	local ptype=IP
	case "$pdptype" in ipv6) ptype=IPV6 ;; ipv4v6) ptype=IPV4V6 ;; esac
	_qmip_cli 15 --wds-modify-profile="3gpp,1,apn=$apn,pdp-type=$ptype" >/dev/null 2>&1

	local cid_4="" pdh_4="" cid_6="" pdh_6=""
	echo "QMI+MM[$$] Connect to network"
	[ -n "$usbid" ] && uci_set_state network "$interface" qmip_usbid "$usbid"
	if [ "$pdptype" != "ipv6" ]; then
		if _qmip_start 4 "$cstr"; then
			cid_4="$_QMIP_CID"; pdh_4="$_QMIP_PDH"
			uci_set_state network "$interface" qmip_cid_4 "$cid_4"
			uci_set_state network "$interface" qmip_pdh_4 "$pdh_4"
		elif [ "$pdptype" = "ipv4" ]; then
			_qmip_fail "$interface" CONNECT_FAILED "Failed to start the IPv4 session"
			return 1
		fi
	fi
	if [ "$pdptype" != "ipv4" ]; then
		if _qmip_start 6 "$cstr"; then
			cid_6="$_QMIP_CID"; pdh_6="$_QMIP_PDH"
			uci_set_state network "$interface" qmip_cid_6 "$cid_6"
			uci_set_state network "$interface" qmip_pdh_6 "$pdh_6"
		elif [ "$pdptype" = "ipv6" ]; then
			_qmip_fail "$interface" CONNECT_FAILED "Failed to start the IPv6 session"
			return 1
		fi
	fi
	if [ -z "$pdh_4" ] && [ -z "$pdh_6" ]; then
		_qmip_fail "$interface" CONNECT_FAILED "Failed to start the data session"
		return 1
	fi
	echo "QMI+MM[$$] Connected (${pdh_4:+ipv4}${pdh_4:+${pdh_6:+ + }}${pdh_6:+ipv6})"

	local cfg4="" cfg6=""
	[ -n "$cid_4" ] && cfg4=$(_qmip_cli 20 --wds-get-current-settings --client-cid="$cid_4" --client-no-release-cid)
	[ -n "$cid_6" ] && cfg6=$(_qmip_cli 20 --wds-get-current-settings --client-cid="$cid_6" --client-no-release-cid)
	local zone
	zone="$(fw3 -q network "$interface" 2>/dev/null)"

	echo "QMI+MM[$$] Setting up $ifname"
	ip link set dev "$ifname" up 2>/dev/null
	proto_init_update "$ifname" 1
	proto_send_update "$interface"

	[ -z "$dhcp" ] && dhcp="auto"
	[ -z "$dhcpv6" ] && dhcpv6="auto"

	local s v4addr v4mask v4gw v6addr v6gw
	[ -n "$cid_4" ] && {
		v4addr=$(_qmip_v 'IPv4 address' "$cfg4")
		v4mask=$(_qmip_v 'IPv4 subnet mask' "$cfg4")
		v4gw=$(_qmip_v 'IPv4 gateway address' "$cfg4")
		json_init
		json_add_string name "${interface}_4"
		json_add_string ifname "@$interface"
		if [ -n "$v4addr" ] && [ "$dhcp" = 0 ]; then
			json_add_string proto "static"
			json_add_array ipaddr
			json_add_string "" "$v4addr/$(_qmip_mask2prefix "${v4mask:-255.255.255.255}")"
			json_close_array
			[ -n "$v4gw" ] && json_add_string gateway "$v4gw"
		else
			echo "QMI+MM[$$] Starting DHCP on $ifname"
			json_add_string proto "dhcp"
		fi
		[ "$peerdns" = 0 ] || [ "$dhcp" != 0 ] || {
			json_add_array dns
			for s in "$(_qmip_v 'IPv4 primary DNS' "$cfg4")" "$(_qmip_v 'IPv4 secondary DNS' "$cfg4")"; do
				[ -n "$s" ] && [ "$s" != "0.0.0.0" ] && json_add_string "" "$s"
			done
			json_close_array
		}
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	[ -n "$cid_6" ] && {
		v6addr=$(_qmip_v 'IPv6 address' "$cfg6")
		v6gw=$(_qmip_v 'IPv6 gateway address' "$cfg6")
		json_init
		json_add_string name "${interface}_6"
		json_add_string ifname "@$interface"
		if [ -n "$v6addr" ] && [ "$dhcpv6" != 1 ]; then
			json_add_string proto "static"
			json_add_array ip6addr
			json_add_string "" "$v6addr"
			json_close_array
			json_add_array ip6prefix
			json_add_string "" "$v6addr"
			json_close_array
			[ -n "$v6gw" ] && json_add_string ip6gw "${v6gw%%/*}"
		elif [ "$dhcpv6" != 0 ]; then
			echo "QMI+MM[$$] Starting DHCPv6 on $ifname"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			[ "$delegate" = "0" ] && json_add_boolean delegate "0"
			[ "$sourcefilter" = "0" ] && json_add_boolean sourcefilter "0"
		fi
		[ "$peerdns" = 0 -a "$dhcpv6" != 1 ] || {
			json_add_array dns
			for s in "$(_qmip_v 'IPv6 primary DNS' "$cfg6")" "$(_qmip_v 'IPv6 secondary DNS' "$cfg6")"; do
				[ -n "$s" ] && json_add_string "" "$s"
			done
			json_close_array
		}
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	case "$mtu" in
		''|*[!0-9]*) ;;
		*) [ "$mtu" -ge 576 ] && { echo "QMI+MM[$$] Setting MTU of $ifname to $mtu"; ip link set "$ifname" mtu "$mtu" 2>/dev/null; } ;;
	esac

	uci_set_state network "$interface" qmip_device "$device"
	[ -x "$QMIP_KEEPER" ] && proto_run_command "$interface" "$QMIP_KEEPER" "$device" "$interface" "${cid_4:-0}" "${cid_6:-0}"
}

proto_qmip_teardown() {
	local interface="$1"
	local device
	device="$(uci_get_state network "$interface" qmip_device)"
	[ -n "$device" ] || { json_get_vars device; }
	echo "QMI+MM[$$] Stopping network"
	proto_kill_command "$interface"
	if [ -n "$device" ] && [ -c "$device" ] && command -v qmicli >/dev/null 2>&1; then
		_QMIP_DEV="$device"
		_qmip_drop_state "$interface" "$(_qmip_usbid "$device")"
	else
		_qmip_drop_state "$interface" ""
	fi
	uci_revert_state network "$interface" qmip_device
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || add_protocol qmip
