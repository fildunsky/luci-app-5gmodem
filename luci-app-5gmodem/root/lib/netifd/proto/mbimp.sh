#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

MBIMP_KEEPER=/usr/share/5gmodem/mbimp-keeper.sh

proto_mbimp_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string pincode
	proto_config_add_int delay
	proto_config_add_boolean allow_roaming
	proto_config_add_boolean allow_partner
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pdptype
	proto_config_add_string devpath
	proto_config_add_boolean dhcp
	proto_config_add_boolean dhcpv6
	proto_config_add_boolean sourcefilter
	proto_config_add_boolean delegate
	proto_config_add_int mtu
	proto_config_add_int timeout
	proto_config_add_defaults
}

_mbimp_run() {
	local _mr_t="$1"; shift
	local _mr_o="/tmp/mbimp.$$.out"
	"$@" > "$_mr_o" 2>&1 </dev/null &
	local _mr_p=$! _mr_n=0
	while kill -0 "$_mr_p" 2>/dev/null && [ "$_mr_n" -lt "$_mr_t" ]; do
		sleep 1; _mr_n=$((_mr_n + 1))
	done
	local _mr_rc=0
	if kill -0 "$_mr_p" 2>/dev/null; then
		kill -9 "$_mr_p" 2>/dev/null
		_mr_rc=124
	fi
	wait "$_mr_p" 2>/dev/null || [ "$_mr_rc" = 124 ] || _mr_rc=$?
	cat "$_mr_o" 2>/dev/null
	rm -f "$_mr_o"
	return $_mr_rc
}

_mbimp_cli() {
	local _mc_t="$1"; shift
	_mbimp_run "$_mc_t" mbimcli -p -d "$_MBIMP_DEV" "$@"
}

_mbimp_field() {
	printf '%s\n' "$2" | sed -n "s/^[[:space:]]*$1: *'\\(.*\\)'[[:space:]]*\$/\\1/p" | head -n 1
}

_mbimp_ipcfg() {
	printf '%s\n' "$1" | awk -v want="$2" -v key="$3" '
		/IPv4 configuration available/ { sec = "4"; next }
		/IPv6 configuration available/ { sec = "6"; next }
		sec == want {
			line = $0
			sub(/^[[:space:]]+/, "", line)
			if (index(line, key) == 1) {
				n = index(line, "\047")
				if (n > 0) {
					v = substr(line, n + 1)
					sub(/\047.*$/, "", v)
					if (v != "") print v
				}
			}
		}'
}

_mbimp_proxy() {
	local _mp_pid
	_mp_pid=$(pidof mbim-proxy 2>/dev/null | awk '{print $1}')
	if [ -n "$_mp_pid" ]; then
		case "$(tr '\0' ' ' < "/proc/$_mp_pid/cmdline" 2>/dev/null)" in
			*--no-exit*) return 0 ;;
		esac
		pidof ModemManager >/dev/null 2>&1 && return 0
		kill "$_mp_pid" 2>/dev/null
		sleep 1
	fi
	local _mp_bin=""
	for _mp_bin in /usr/libexec/mbim-proxy /usr/lib/libmbim/mbim-proxy /usr/lib/mbim-proxy; do
		[ -x "$_mp_bin" ] && break
		_mp_bin=""
	done
	[ -n "$_mp_bin" ] || return 0
	if command -v start-stop-daemon >/dev/null 2>&1; then
		start-stop-daemon -S -b -x "$_mp_bin" -- --no-exit >/dev/null 2>&1
	else
		( "$_mp_bin" --no-exit </dev/null >/dev/null 2>&1 & ) >/dev/null 2>&1
	fi
	local _mp_n=0
	while ! pidof mbim-proxy >/dev/null 2>&1 && [ "$_mp_n" -lt 5 ]; do
		sleep 1; _mp_n=$((_mp_n + 1))
	done
	return 0
}

_mbimp_mm_detach() {
	command -v mmcli >/dev/null 2>&1 || return 0
	pidof ModemManager >/dev/null 2>&1 || return 0
	local _md_usb="$1" _md_n
	[ -n "$_md_usb" ] || return 0
	for _md_n in "$_md_usb":*/ttyUSB* "$_md_usb":*/tty/ttyUSB* "$_md_usb":*/tty/ttyACM*; do
		[ -e "$_md_n" ] && mmcli --report-kernel-event="action=remove,subsystem=tty,name=${_md_n##*/}" >/dev/null 2>&1
	done
	for _md_n in "$_md_usb":*/net/*; do
		[ -e "$_md_n" ] && mmcli --report-kernel-event="action=remove,subsystem=net,name=${_md_n##*/}" >/dev/null 2>&1
	done
	for _md_n in "$_md_usb":*/usbmisc/cdc-wdm*; do
		[ -e "$_md_n" ] && mmcli --report-kernel-event="action=remove,subsystem=usbmisc,name=${_md_n##*/}" >/dev/null 2>&1
	done
	sleep 2
}

_mbimp_fail() {
	echo "mbimp[$$] $3"
	proto_notify_error "$1" "$2"
	[ "$4" = block ] && proto_block_restart "$1"
	return 1
}

proto_mbimp_setup() {
	local interface="$1"
	local allow_partner allow_roaming apn auth delay device devpath password pincode username
	json_get_vars allow_partner allow_roaming apn auth delay device devpath password pincode username
	local dhcp dhcpv6 pdptype timeout
	json_get_vars dhcp dhcpv6 pdptype timeout
	local delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS
	json_get_vars delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS
	local ipv6
	[ ! -e /proc/sys/net/ipv6 ] && ipv6=0 || json_get_var ipv6 ipv6

	[ -n "$ctl_device" ] && device=$ctl_device
	if [ -n "$devpath" ]; then
		local _p
		for _p in "$devpath"/usbmisc/cdc-wdm* "$devpath"/*/usbmisc/cdc-wdm* \
		    "$devpath"/*/wwan[0-9]*/wwan[0-9]*mbim* "$devpath"/*/*/wwan[0-9]*/wwan[0-9]*mbim*; do
			[ -e "$_p" ] || continue
			device="/dev/${_p##*/}"
			break
		done
	fi
	[ -n "$device" ] || { proto_set_available "$interface" 0; _mbimp_fail "$interface" NO_DEVICE "No control device specified"; return 1; }
	[ -c "$device" ] || { proto_set_available "$interface" 0; _mbimp_fail "$interface" NO_DEVICE "The control device $device does not exist"; return 1; }
	command -v mbimcli >/dev/null 2>&1 || { _mbimp_fail "$interface" NO_MBIMCLI "mbimcli is not installed (package mbim-utils)" block; return 1; }

	local devname ifname syspath
	devname="$(basename "$device")"
	syspath="$(readlink -f "/sys/class/usbmisc/$devname/device/" || readlink -f "/sys/class/wwan/$devname/device/")"
	ifname="$(ls "$syspath"/net 2>/dev/null | head -n 1)"
	[ -n "$ifname" ] || { proto_set_available "$interface" 0; _mbimp_fail "$interface" NO_IFNAME "Failed to find the network interface of $device"; return 1; }
	[ -n "$apn" ] || { _mbimp_fail "$interface" NO_APN "No APN specified"; return 1; }

	[ -n "$delay" ] && sleep "$delay"
	[ -n "$timeout" ] || timeout=30
	_MBIMP_DEV="$device"
	local usbdev="${syspath%/*}"
	if [ -f "$usbdev/idVendor" ]; then
		usbdev="/sys/bus/usb/devices/${usbdev##*/}"
	else
		usbdev=""
	fi
	_mbimp_mm_detach "$usbdev"
	_mbimp_proxy

	local out
	echo "mbimp[$$] Reading capabilities"
	out=$(_mbimp_cli 20 --query-device-caps) || { _mbimp_fail "$interface" NO_CAPS "Failed to read modem caps"; return 1; }
	case "$out" in *"Device ID"*) ;; *) _mbimp_fail "$interface" NO_CAPS "Failed to read modem caps"; return 1 ;; esac

	if [ -n "$pincode" ]; then
		echo "mbimp[$$] Sending pin"
		out=$(_mbimp_cli 20 --enter-pin="$pincode")
	fi
	echo "mbimp[$$] Checking pin"
	out=$(_mbimp_cli 20 --query-pin-state)
	if [ "$(_mbimp_field 'PIN state' "$out")" = "locked" ]; then
		case "$(_mbimp_field 'PIN type' "$out")" in
			pin1|puk1|'')
				_mbimp_fail "$interface" PIN_FAILED "PIN required" block
				return 1 ;;
		esac
	fi

	echo "mbimp[$$] Checking subscriber"
	local n=0 ready=""
	while :; do
		out=$(_mbimp_cli 20 --query-subscriber-ready-status)
		ready=$(_mbimp_field 'Ready state' "$out")
		[ "$ready" = "initialized" ] && break
		n=$((n + 3))
		[ "$n" -ge "$timeout" ] && { _mbimp_fail "$interface" NO_SUBSCRIBER "Subscriber init failed (${ready:-no answer})"; return 1; }
		sleep 3
	done

	echo "mbimp[$$] Register with network"
	local reg="" ok=0
	n=0
	while :; do
		out=$(_mbimp_cli 20 --query-registration-state)
		reg=$(_mbimp_field 'Register state' "$out")
		case "$reg" in
			home) ok=1 ;;
			roaming) [ "$allow_roaming" = 1 ] && ok=1 || ok=2 ;;
			partner) [ "$allow_partner" = 1 ] && ok=1 || ok=2 ;;
		esac
		[ "$ok" != 0 ] && break
		n=$((n + 3))
		[ "$n" -ge "$timeout" ] && break
		sleep 3
	done
	if [ "$ok" != 1 ]; then
		_mbimp_fail "$interface" NO_REGISTRATION "Registration failed (state: ${reg:-no answer})"
		return 1
	fi
	echo "mbimp[$$] Registered ($reg, $(_mbimp_field 'Provider name' "$out"))"

	echo "mbimp[$$] Attach to network"
	out=$(_mbimp_cli 30 --query-packet-service-state)
	if [ "$(_mbimp_field 'Packet service state' "$out")" != "attached" ]; then
		out=$(_mbimp_cli 45 --attach-packet-service)
		case "$(_mbimp_field 'Packet service state' "$out")" in
			attached) ;;
			*) _mbimp_fail "$interface" ATTACH_FAILED "Failed to attach to network"; return 1 ;;
		esac
	fi

	pdptype=$(echo "$pdptype" | awk '{print tolower($0)}')
	[ "$ipv6" = 0 ] && pdptype="ipv4"
	case "$pdptype" in ipv4|ipv6|ipv4v6) ;; *) pdptype="ipv4" ;; esac
	local cstr="apn=$apn,ip-type=$pdptype"
	case "$(echo "$auth" | awk '{print tolower($0)}')" in
		pap) cstr="$cstr,auth=PAP" ;;
		chap) cstr="$cstr,auth=CHAP" ;;
		mschapv2) cstr="$cstr,auth=MSCHAPV2" ;;
	esac
	[ -n "$username" ] && cstr="$cstr,username=$username"
	[ -n "$password" ] && cstr="$cstr,password=$password"

	echo "mbimp[$$] Connect to network"
	out=$(_mbimp_cli 20 --query-connection-state=0)
	if [ "$(_mbimp_field 'Activation state' "$out")" = "activated" ]; then
		_mbimp_cli 20 --disconnect=0 >/dev/null 2>&1
	fi
	out=$(_mbimp_cli 60 --connect="$cstr")
	if [ "$(_mbimp_field 'Activation state' "$out")" != "activated" ]; then
		echo "$out" | grep -iE "error|fail" | head -n 2
		_mbimp_fail "$interface" CONNECT_FAILED "Failed to connect bearer"
		return 1
	fi
	local iptype
	iptype=$(_mbimp_field 'IP type' "$out")
	echo "mbimp[$$] Connected (ip type: $iptype)"

	local cfg
	cfg=$(_mbimp_cli 20 --query-ip-configuration=0)
	local zone
	zone="$(fw3 -q network "$interface" 2>/dev/null)"

	echo "mbimp[$$] Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_send_update "$interface"

	[ -z "$dhcp" ] && dhcp="auto"
	[ -z "$dhcpv6" ] && dhcpv6="auto"

	local a s v4addr v6addr
	[ "$iptype" != "ipv6" ] && {
		v4addr=$(_mbimp_ipcfg "$cfg" 4 "IP [")
		json_init
		json_add_string name "${interface}_4"
		json_add_string ifname "@$interface"
		if [ -n "$v4addr" ] && [ "$dhcp" != 1 ]; then
			json_add_string proto "static"
			json_add_array ipaddr
			for a in $v4addr; do json_add_string "" "$a"; done
			json_close_array
			json_add_string gateway "$(_mbimp_ipcfg "$cfg" 4 "Gateway" | head -n 1)"
		elif [ "$dhcp" != 0 ]; then
			echo "mbimp[$$] Starting DHCP on $ifname"
			json_add_string proto "dhcp"
		fi
		[ "$peerdns" = 0 -a "$dhcp" != 1 ] || {
			json_add_array dns
			for s in $(_mbimp_ipcfg "$cfg" 4 "DNS ["); do json_add_string "" "$s"; done
			json_close_array
		}
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	[ "$iptype" != "ipv4" ] && {
		v6addr=$(_mbimp_ipcfg "$cfg" 6 "IP [")
		json_init
		json_add_string name "${interface}_6"
		json_add_string ifname "@$interface"
		if [ -n "$v6addr" ] && [ "$dhcpv6" != 1 ]; then
			json_add_string proto "static"
			json_add_array ip6addr
			for a in $v6addr; do json_add_string "" "$a"; done
			json_close_array
			json_add_array ip6prefix
			for a in $v6addr; do json_add_string "" "$a"; done
			json_close_array
			json_add_string ip6gw "$(_mbimp_ipcfg "$cfg" 6 "Gateway" | head -n 1)"
		elif [ "$dhcpv6" != 0 ]; then
			echo "mbimp[$$] Starting DHCPv6 on $ifname"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			[ "$delegate" = "0" ] && json_add_boolean delegate "0"
			[ "$sourcefilter" = "0" ] && json_add_boolean sourcefilter "0"
		fi
		[ "$peerdns" = 0 -a "$dhcpv6" != 1 ] || {
			json_add_array dns
			for s in $(_mbimp_ipcfg "$cfg" 6 "DNS ["); do json_add_string "" "$s"; done
			json_close_array
		}
		proto_add_dynamic_defaults
		[ -n "$zone" ] && json_add_string zone "$zone"
		[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
		json_close_object
		ubus call network add_dynamic "$(json_dump)"
	}

	if [ -z "$mtu" ]; then
		mtu=$(_mbimp_ipcfg "$cfg" 4 "MTU" | head -n 1)
		[ -n "$mtu" ] || mtu=$(_mbimp_ipcfg "$cfg" 6 "MTU" | head -n 1)
	fi
	case "$mtu" in
		''|*[!0-9]*) ;;
		*) [ "$mtu" -ge 576 ] && { echo "mbimp[$$] Setting MTU of $ifname to $mtu"; ip link set "$ifname" mtu "$mtu" 2>/dev/null; } ;;
	esac

	uci_set_state network "$interface" mbimp_device "$device"
	[ -x "$MBIMP_KEEPER" ] && proto_run_command "$interface" "$MBIMP_KEEPER" "$device" "$interface" "$usbdev"
}

proto_mbimp_teardown() {
	local interface="$1"
	local device
	device="$(uci_get_state network "$interface" mbimp_device)"
	[ -n "$device" ] || { json_get_vars device; }
	echo "mbimp[$$] Stopping network"
	proto_kill_command "$interface"
	if [ -n "$device" ] && [ -c "$device" ] && command -v mbimcli >/dev/null 2>&1; then
		_MBIMP_DEV="$device"
		_mbimp_cli 15 --disconnect=0 >/dev/null 2>&1
	fi
	uci_revert_state network "$interface" mbimp_device
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || add_protocol mbimp
