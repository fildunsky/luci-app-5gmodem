_td_at() {
	local response rc
	response=$(at_query "$1" "$2" 8 5)
	rc=$?
	[ "$rc" = 0 ] || return "$rc"
	[ -n "$response" ] || return 1
	printf '%s\n' "$response"
}

_td_ok() {
	printf '%s\n' "$1" | tr -d '\r' | grep -q '^OK$' || return 1
	! printf '%s\n' "$1" | grep -q 'ERROR'
}

_td_pcui() {
	local path="$1" iface tty
	for iface in /sys/bus/usb/devices/"$path":*; do
		[ "$(cat "$iface/bInterfaceClass" 2>/dev/null):$(cat "$iface/bInterfaceSubClass" 2>/dev/null):$(cat "$iface/bInterfaceProtocol" 2>/dev/null)" = ff:06:12 ] || continue
		for tty in "$iface"/ttyUSB* "$iface"/tty/ttyUSB*; do
			[ -e "$tty" ] || continue
			printf '/dev/%s\n' "${tty##*/}"
			return 0
		done
	done
	return 1
}

_td_up() {
	_td_at "$1" 'AT^NDISSTATQRY?' | tr -d '\r" ' | awk -F'[:,]' '
		/^\^NDISSTATQRY:/ { if ($2 == 1 && $3 == 1) f = 1 }
		END { exit !f }'
}

_td_registration() {
	local port="$1" command response state
	for command in 'AT+CEREG?' 'AT+C5GREG?' 'AT+CREG?'; do
		response=$(_td_at "$port" "$command")
		state=$(printf '%s\n' "$response" | tr -d '\r' | sed -n 's/^+[A-Z0-9]*REG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
		case "$state" in 1|5|6|7|9|10) printf '%s\n' "$state"; return 0 ;; esac
	done
	printf '%s\n' "$state"
	return 1
}

_td_profile() {
	printf '%s\n' "$1" | tr -d '\r' | awk '
		/^\^SETAUTOD(IAL|AIL):/ {
			sub(/^[^:]*:/, "")
			quoted = 0
			for (i = 1; i <= length($0); i++) {
				c = substr($0, i, 1)
				if (c == "\"") quoted = !quoted
				if (quoted || c !~ /[ \t]/) printf "%s", c
			}
			printf "\n"
			exit
		}'
}

_td_profile_matches() {
	local profile="$1" context
	case "$profile" in
		"$wanted"|"$base") return 0 ;;
		1|1,1)
			context=$(_td_at "$port" 'AT+CGDCONT?' | tr -d '\r ')
			printf '%s\n' "$context" | grep -Fq "+CGDCONT:1,\"$pdptype\",\"$apn\","
			return $?
			;;
	esac
	return 1
}

_td_enable_autodial() {
	local port="$1" response profile wanted base am=0 user="$username" pass="$password"
	case "$apn$username$password" in *'"'*|*'\'*|*';'*) return 1 ;; esac
	[ "$(printf '%s' "$apn$username$password" | tr -d '\r\n')" = "$apn$username$password" ] || return 1
	[ "${#apn}" -le 99 ] && [ "${#username}" -le 31 ] && [ "${#password}" -le 31 ] || return 1
	case "$pdptype" in IP|IPV6|IPV4V6) ;; *) return 1 ;; esac
	case "$auth" in pap|both) am=1 ;; chap) am=2 ;; *) user=""; pass="" ;; esac
	base="1,1,\"$pdptype\",\"$apn\""
	wanted="$base,\"$user\",\"$pass\",$am"
	response=$(_td_at "$port" 'AT^SETAUTODIAL?')
	profile=$(_td_profile "$response")
	_td_profile_matches "$profile" && return 0
	response=$(_td_at "$port" "AT^SETAUTODIAL=$wanted")
	_td_ok "$response" || return 1
	response=$(_td_at "$port" 'AT^SETAUTODIAL?')
	profile=$(_td_profile "$response")
	_td_profile_matches "$profile"
}

_td_data_ready() {
	local response
	_td_up "$1" && return 0
	response=$(_td_at "$1" 'AT+CGACT?' | tr -d '\r ')
	case "$(printf '%s\n' "$response" | sed -n 's/^+CGACT:1,\([01]\)$/\1/p' | head -1)" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	return 0
}

_td_restore_bands() {
	local path="$1" sec="m_$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')" devnum mark saved rc
	devnum=$(cat "/sys/bus/usb/devices/$path/devnum" 2>/dev/null)
	mark="/tmp/5gmodem/bandsprep_$interface"
	[ -n "$devnum" ] || return 1
	[ "$(cat "$mark" 2>/dev/null)" = "$devnum" ] && return 0
	if [ "$(uci -q get 5gmodem.@5gmodem[0].save_bands)" != 0 ]; then
		saved="$(uci -q get "5gmodem.$sec.save_band")$(uci -q get "5gmodem.$sec.save_band5gnsa")$(uci -q get "5gmodem.$sec.save_band5gsa")$(uci -q get "5gmodem.$sec.save_mode")"
		if [ -n "$saved" ]; then
			BANDS_ACTIVE_MODEM="$path" /usr/share/5gmodem/bands.sh restorebands prepare
			rc=$?
			case "$rc" in 0|3) ;; *) return 1 ;; esac
		fi
	fi
	printf '%s\n' "$devnum" > "$mark"
	: > "/tmp/5gmodem/bandrestore_$interface"
}

_td_bootstrap() {
	local path="$1" delay started now registration response
	_td_netdev=""; _td_port=""; _td_error=TDTECH_STARTUP_TIMEOUT
	started=$(cut -d. -f1 /proc/uptime)
	for delay in 0 5 10 15 30 60; do
		[ "$delay" = 0 ] || sleep "$delay"
		now=$(cut -d. -f1 /proc/uptime)
		[ "$((now - started))" -lt 180 ] || break
		if [ "$(cat "/sys/bus/usb/devices/$path/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$path/idProduct" 2>/dev/null)" != 3466:3301 ]; then
			_td_error=NO_DEVICE
			continue
		fi
		/usr/share/5gmodem/usbports.sh bind 3466 3301
		_td_port=$(_td_pcui "$path")
		if [ -z "$_td_port" ]; then _td_error=NO_AT_PORT; continue; fi
		registration=$(_td_registration "$_td_port")
		case "$registration" in
			5|7|10)
				if [ "$allow_roaming" != 1 ]; then _td_error=ROAMING_NOT_ALLOWED; return 1; fi
				;;
			1|6|9) ;;
			*)
				if [ -z "$registration" ]; then
					_td_error=TDTECH_REGISTRATION_UNAVAILABLE
					echo "fibocom[$$] TD Tech: no usable registration reply on $_td_port - retrying"
					continue
				fi
				_td_error=NOT_REGISTERED
				response=$(_td_at "$_td_port" 'AT+COPS?' | tr -d '\r ')
				case "$response" in *'+COPS:2,'*) _td_at "$_td_port" 'AT+COPS=0' >/dev/null ;; esac
				echo "fibocom[$$] TD Tech: waiting for network registration"
				continue
				;;
		esac
		_td_restore_bands "$path" || { _td_error=BAND_RESTORE_FAILED; continue; }
		if ! _td_enable_autodial "$_td_port"; then
			_td_error=TDTECH_AUTODIAL_FAILED
			echo "fibocom[$$] TD Tech: USB autodial was not confirmed - retrying after backoff"
			continue
		fi
		_td_netdev=$(_fibocom_netdev "$path")
		if [ -n "$_td_netdev" ] && [ -d "/sys/class/net/$_td_netdev" ]; then
			if _td_data_ready "$_td_port"; then return 0; fi
			_td_error=TDTECH_PDP_PENDING
			echo "fibocom[$$] TD Tech: USB interface exists; waiting for the data context"
			continue
		fi
		_td_error=TDTECH_NO_NETDEV
		echo "fibocom[$$] TD Tech: USB autodial enabled; waiting for this modem's network interface"
	done
	if [ "$_td_error" = TDTECH_NO_NETDEV ] \
	   && [ "$(cat "/sys/bus/usb/devices/$path:2.0/bInterfaceClass" 2>/dev/null):$(cat "/sys/bus/usb/devices/$path:2.0/bInterfaceSubClass" 2>/dev/null):$(cat "/sys/bus/usb/devices/$path:2.0/bInterfaceProtocol" 2>/dev/null)" = ff:02:16 ]; then
		_td_error=TDTECH_VENDOR_NCM
		echo "fibocom[$$] TD Tech: USB autodial is enabled but vendor NCM ff/02/16 is not bound to huawei_cdc_ncm"
	fi
	return 1
}

_td_add_child() {
	local parent="$1" suffix="$2" protocol="$3" zone="$4"
	json_init
	json_add_string name "${parent}_$suffix"
	json_add_string ifname "@$parent"
	json_add_string proto "$protocol"
	proto_add_dynamic_defaults
	[ -n "$delegate" ] && json_add_boolean delegate "$delegate"
	[ -n "$mtu" ] && json_add_int mtu "$mtu"
	if [ "$protocol" = dhcpv6 ]; then
		json_add_string reqaddress try
		json_add_string reqprefix auto
		json_add_boolean extendprefix 1
		[ -n "$sourcefilter" ] && json_add_boolean sourcefilter "$sourcefilter"
		[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
	else
		[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
	fi
	[ -n "$zone" ] && json_add_string zone "$zone"
	ubus call network add_dynamic "$(json_dump)"
}

_td_setup() {
	local interface="$1" path="$2" zone context livepdp
	local allow_roaming defaultroute peerdns delegate mtu ip4table ip6table
	json_get_vars allow_roaming defaultroute peerdns delegate mtu ip4table ip6table
	. /usr/share/5gmodem/lib.sh
	if ! _td_bootstrap "$path"; then
		proto_notify_error "$interface" "$_td_error"
		return 1
	fi
	context=$(_td_at "$_td_port" 'AT+CGDCONT?' | tr -d '\r' \
		| sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p' | head -1)
	livepdp="${context:-$pdptype}"
	zone=$(_fibocom_fwzone "$interface")
	proto_init_update "$_td_netdev" 1
	proto_send_update "$interface" || return 1
	if [ "$pdptype" != IPV6 ]; then
		_td_add_child "$interface" 4 dhcp "$zone" || { proto_notify_error "$interface" DHCP_SETUP_FAILED; return 1; }
	fi
	case "$pdptype" in
		*[vV]6*) _td_add_child "$interface" 6 dhcpv6 "$zone" || { proto_notify_error "$interface" DHCPV6_SETUP_FAILED; return 1; } ;;
	esac
	echo "fibocom[$$] TD Tech: USB autodial ready on $_td_netdev; addresses are managed by DHCP (requested $pdptype, current $livepdp)"
}
