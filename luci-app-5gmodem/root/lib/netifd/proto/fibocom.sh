#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

_fibocom_netdev() {
	local p="$1" n best="" bestnum=999
	for n in /sys/bus/usb/devices/$p:*/net/*; do
		[ -e "$n" ] || continue
		local ifn="${n%/net/*}"; ifn="${ifn##*:}"; ifn="${ifn#*.}"
		[ "$ifn" -lt "$bestnum" ] 2>/dev/null && { bestnum="$ifn"; best="$n"; }
	done
	[ -n "$best" ] && { basename "$best"; return 0; }
	return 1
}

_fibocom_atport() {
	local p="$1" avoid="$2" t tt fallback=""
	. /usr/share/5gmodem/noatports.sh
	for t in /sys/bus/usb/devices/$p:*/ttyUSB* /sys/bus/usb/devices/$p:*/tty/ttyUSB* \
	         /sys/bus/usb/devices/$p:*/ttyACM* /sys/bus/usb/devices/$p:*/tty/ttyACM*; do
		[ -e "$t" ] || continue
		tt="/dev/$(basename "$t")"
		tty_no_at "$tt" && continue
		sms_tool -d "$tt" at "AT" >/dev/null 2>&1 || continue
		if [ "$tt" = "$avoid" ]; then
			[ -z "$fallback" ] && fallback="$tt"
			continue
		fi
		echo "$tt"
		return 0
	done
	[ -n "$fallback" ] && { echo "$fallback"; return 0; }
	return 1
}

_fibocom_cops_mode() {
	sms_tool -d "$1" at "AT+COPS?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+COPS: *\([0-9]\).*/\1/p' | head -1
}

_fibocom_why() {
	local p="$1" xmm="$2" ceer sn
	ceer=$(sms_tool -d "$p" at "AT+CEER" 2>/dev/null | tr -d '\r' | sed -n 's/^+CEER: *//p' | head -1)
	[ -n "$ceer" ] && echo "fibocom[$$] modem reports the last failure: +CEER: $ceer"
	[ "$xmm" = 1 ] || return 0
	sn=$(sms_tool -d "$p" at "AT+CFSN?" 2>/dev/null | tr -d '\r' | sed -n 's/^+CFSN: *//p' | head -1 | tr -d '"')
	[ -n "$sn" ] && return 0
	echo "fibocom[$$] the module serial number (AT+CFSN?) is EMPTY - an XMM module with a wiped serial is refused by the network; do not write it yourself, the serial can be set only once"
}

_fibocom_reg() {
	local p="$1" r r5 r2
	r=$(sms_tool -d "$p" at "AT+CEREG?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
	case "$r" in 1|5|6|7|9|10) echo "$r"; return ;; esac
	r5=$(sms_tool -d "$p" at "AT+C5GREG?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+C5GREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
	case "$r5" in 1|5|6|7|9|10) echo "$r5"; return ;; esac
	r2=$(sms_tool -d "$p" at "AT+CREG?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
	case "$r2" in 1|5) echo "$r2"; return ;; esac
	echo "${r:-$r2}"
}

_fibocom_auth() {
	local dial="$1" am=0 out
	case "$auth" in
		pap|both) am=1 ;;
		chap)     am=2 ;;
	esac
	if [ "$IS_XMM" = 1 ]; then
		if [ "$am" = 0 ]; then
			out=$(sms_tool -d "$dial" at 'AT+XGAUTH=1,0,"",""' 2>&1)
		else
			out=$(sms_tool -d "$dial" at "AT+XGAUTH=1,$am,\"$username\",\"$password\"" 2>&1)
		fi
		case "$out" in
			*ERROR*) echo "fibocom[$$] AT+XGAUTH rejected, trying AT+CGAUTH" ;;
			*) out="" ;;
		esac
	fi
	if [ "$IS_XMM" != 1 ] || [ -n "$out" ]; then
		if [ "$am" = 0 ]; then
			sms_tool -d "$dial" at "AT+CGAUTH=1,0" >/dev/null 2>&1
		else
			sms_tool -d "$dial" at "AT+CGAUTH=1,$am,\"$username\",\"$password\"" >/dev/null 2>&1
		fi
	fi
	[ -n "$interface" ] && [ -n "$usbpath" ] && \
		cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null \
			> "/tmp/5gmodem/fibocom_authed_$interface" 2>/dev/null
}

_fibocom_activate() {
	local dial="$1" pdptype="$2" apn="$3" try ip=""
	[ "$IS_XMM" = 1 ] && sms_tool -d "$dial" at "AT+XDNS=1,1" >/dev/null 2>&1
	sms_tool -d "$dial" at "AT+CGDCONT=1,\"$pdptype\",\"$apn\"" >/dev/null 2>&1
	_fibocom_auth "$dial"
	sms_tool -d "$dial" at "AT+CGACT=0,1" >/dev/null 2>&1
	sleep 2
	for try in 1 2 3 4 5 6; do
		if sms_tool -d "$dial" at "AT+CGACT?" 2>/dev/null | tr -d '\r' | grep -qE '^\+CGACT: *1,1'; then
			:
		else
			sms_tool -d "$dial" at "AT+CGACT=1,1" >/dev/null 2>&1
		fi
		sleep 2
		ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*+CGPADDR: *1,//p' | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9]{1,3}([.][0-9]{1,3}){3}$' | head -1)
		[ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && {
			if [ "$IS_XMM" = 1 ]; then
				_xdc=""; _xk=0
				for _xi in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
					for _xt in /sys/bus/usb/devices/$usbpath:1.$_xi/tty/ttyACM*; do
						[ -e "$_xt" ] || continue
						[ "/dev/${_xt##*/}" = "$dial" ] && _xdc=$_xk
						_xk=$((_xk + 1))
					done
				done
				[ -n "$_xdc" ] || _xdc=$(printf '%s' "$dial" | sed -n 's/.*ttyACM\([0-9][0-9]*\)$/\1/p'); [ -n "$_xdc" ] || _xdc=0
				sms_tool -d "$dial" at "AT+XDATACHANNEL=1,1,\"/USBCDC/$_xdc\",\"/USBHS/NCM/0\",2,1" >/dev/null 2>&1
				sms_tool -d "$dial" at "AT+CGDATA=\"M-RAW_IP\",1" >/dev/null 2>&1
			fi
			echo "$ip"; return 0
		}
	done
	return 1
}

_fibocom_fwzone() {
	local z i=0 nm n
	z=$(fw3 -q network "$1" 2>/dev/null)
	[ -n "$z" ] && { echo "$z"; return; }
	while nm=$(uci -q get "firewall.@zone[$i].name" 2>/dev/null); [ -n "$nm" ]; do
		for n in $(uci -q get "firewall.@zone[$i].network" 2>/dev/null); do
			[ "$n" = "$1" ] && { echo "$nm"; return; }
		done
		i=$((i + 1))
	done
}

_r11e_at() {
	sms_tool -d "$1" at "$2" 2>/dev/null | tr -d '\r'
}

_r11e_ready() {
	local n=0
	sleep 1
	while [ "$n" -lt 30 ]; do
		if /usr/share/5gmodem/atprobe.sh "$1"; then
			case "$(_r11e_at "$1" 'AT+CMEE=2')" in
				*ERROR*) ;;
				*) return 0 ;;
			esac
		fi
		sleep 1; n=$((n + 1))
	done
	return 1
}

_r11e_prepare() {
	local dev="$1" key mark a s cl o
	key="$(cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null)|$2|$3|$auth|$(printf '%s|%s' "$username" "$password" | md5sum | cut -c1-16)"
	mark="/tmp/5gmodem/r11e_prep_$4"
	[ "$(cat "$mark" 2>/dev/null)" = "$key" ] && return 0
	if ! _r11e_ready "$dev"; then
		echo "fibocom[$$] R11e-LTE: $dev does not answer AT - default bearer not configured"
		return 1
	fi
	case "$auth" in pap|both) a=1 ;; chap) a=2 ;; *) a=0 ;; esac
	for s in $(uci -q show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\(m_[0-9A-Za-z_]*\)\.network=.*/\1/p'); do
		case "$s" in m_park_*) continue ;; esac
		[ "$(uci -q get "5gmodem.$s.network")" = "$4" ] || continue
		cl=$(uci -q get "5gmodem.$s.celllock"); break
	done
	echo "fibocom[$$] R11e-LTE: default bearer APN \"$3\" ($2) - radio off for the change"
	_r11e_at "$dev" 'AT+CFUN=4' >/dev/null
	o=$(_r11e_at "$dev" "AT*CGDFLT=0,\"$2\",\"$3\",,,,,,,,,,1,0,,,,,,,1")
	case "$o" in *ERROR*) echo "fibocom[$$] R11e-LTE: AT*CGDFLT rejected: $(printf '%s' "$o" | tr '\n' ' ' | head -c 100)" ;; esac
	_r11e_at "$dev" "AT*CGDFAUTH=0,$a,\"$username\",\"$password\"" >/dev/null
	set -- $cl
	case "$1" in
		cell)  [ -n "$3" ] && _r11e_at "$dev" "AT*Cell=2,3,,$2,$3" >/dev/null && echo "fibocom[$$] R11e-LTE: cell lock re-applied ($2/$3)" ;;
		arfcn) [ -n "$2" ] && _r11e_at "$dev" "AT*Cell=1,3,,$2" >/dev/null && echo "fibocom[$$] R11e-LTE: frequency lock re-applied ($2)" ;;
	esac
	_r11e_at "$dev" 'AT+CFUN=1' >/dev/null
	printf '%s' "$key" > "$mark" 2>/dev/null
	[ "$a" != 0 ] && cat "/sys/bus/usb/devices/$usbpath/devnum" > "/tmp/5gmodem/fibocom_authed_$interface" 2>/dev/null
	R11E_CYCLED=1
}

_r11e_cid() {
	local n=0 c a first
	while :; do
		first=""
		for c in $(_r11e_at "$1" 'AT+CGACT?' | sed -n 's/^+CGACT: *\([0-9]*\), *1.*/\1/p'); do
			a=$(_r11e_at "$1" "AT+CGCONTRDP=$c" | sed -n 's/^+CGCONTRDP: *[0-9]*, *[0-9]*, *"\([^"]*\)".*/\1/p' | head -1 | tr 'A-Z' 'a-z')
			case "$a" in *ims*) continue ;; esac
			[ -n "$2" ] && case "$a" in "$(echo "$2" | tr 'A-Z' 'a-z')"*) echo "$c"; return 0 ;; esac
			[ -n "$first" ] || first="$c"
		done
		[ -n "$first" ] && { echo "$first"; return 0; }
		[ "$n" -ge "$3" ] && return 1
		sleep 3; n=$((n + 3))
	done
}

_r11e_rdp() {
	printf '%s\n' "$1" | awk -F',' '
		function ip4(v) { return v ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ }
		{
			for (i = 1; i <= NF; i++) gsub(/["[:space:]]/, "", $i)
			a = $4; m = ""
			if (split(a, o, ".") == 8) { a = o[1] "." o[2] "." o[3] "." o[4]; m = o[5] "." o[6] "." o[7] "." o[8] }
			if (!ip4(a) || a == "0.0.0.0") exit
			k = 0
			for (i = 5; i <= NF; i++) {
				if (!ip4($i) || $i == "0.0.0.0" || $i == a) continue
				if ($i ~ /^255\./ && m == "") { m = $i; continue }
				L[++k] = $i
			}
			g = ""; d1 = L[1]; d2 = L[2]
			if (k >= 3) { g = L[1]; d1 = L[2]; d2 = L[3] }
			split(a, q, "."); d = q[4] + 0
			pfx = 0
			if (m != "") {
				split(m, mm, ".")
				for (i = 1; i <= 4; i++) { v = mm[i] + 0; while (v > 0) { pfx += v % 2; v = int(v / 2) } }
			}
			if (pfx < 24 || pfx > 30) {
				y = 4
				while (y < 256 && (d % y == 0 || d % y == y - 1)) y *= 2
				pfx = 32; t = y; while (t > 1) { pfx--; t /= 2 }
			} else {
				y = 1; for (i = pfx; i < 32; i++) y *= 2
			}
			if (g == "") {
				base = d - d % y
				g = q[1] "." q[2] "." q[3] "." ((d == base + 1) ? base + 2 : base + 1)
			}
			printf "r11e_ip=%s\nr11e_mask=%s\nr11e_gw=%s\nr11e_dns1=%s\nr11e_dns2=%s\n", a, pfx, g, d1, d2
		}'
}

proto_fibocom_init_config() {
	no_device=1
	available=1
	proto_config_add_string "usbpath"
	proto_config_add_string "modem_path"
	proto_config_add_string "device"
	proto_config_add_string "atport"
	proto_config_add_string "apn"
	proto_config_add_string "pdptype"
	proto_config_add_string "auth"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_int "metric"
	proto_config_add_boolean "allow_roaming"
	proto_config_add_boolean "sourcefilter"
	proto_config_add_defaults
}

proto_fibocom_setup() {
	local interface="$1"
	local usbpath modem_path device atport apn pdptype metric sourcefilter
	json_get_vars usbpath modem_path device atport apn pdptype metric allow_roaming auth username password sourcefilter

	[ -n "$apn" ] || apn="internet"
	[ -n "$pdptype" ] || pdptype="IPV4"
	pdptype=$(echo "$pdptype" | tr 'a-z' 'A-Z')
	case "$pdptype" in
		IPV4) pdptype="IP" ;;
		IP|IPV6|IPV4V6) ;;
		*) pdptype="IPV4V6" ;;
	esac

	if [ -n "$modem_path" ] && [ "$modem_path" != "$usbpath" ] \
	   && [ ! -e "/sys/bus/usb/devices/$usbpath/idVendor" ] \
	   && [ -e "/sys/bus/usb/devices/$modem_path/idVendor" ]; then
		echo "fibocom[$$] usbpath \"$usbpath\" is not on the bus, using modem_path \"$modem_path\""
		usbpath="$modem_path"
	fi

	local netdev=""
	if [ -n "$usbpath" ]; then
		netdev=$(_fibocom_netdev "$usbpath")
		if [ -z "$netdev" ]; then
			modprobe rndis_host 2>/dev/null
			modprobe cdc_ether 2>/dev/null
			local _n=0
			while [ "$_n" -lt 5 ]; do
				netdev=$(_fibocom_netdev "$usbpath")
				[ -n "$netdev" ] && break
				sleep 1; _n=$((_n + 1))
			done
		fi
	fi
	[ -n "$netdev" ] || netdev="$device"
	if [ -z "$netdev" ]; then
		echo "fibocom[$$] no network device: path \"$usbpath\", device \"$device\""
		proto_notify_error "$interface" NO_NETDEV
		proto_set_available "$interface" 0
		return 1
	fi
	if [ ! -d "/sys/class/net/$netdev" ]; then
		proto_notify_error "$interface" NETDEV_MISSING
		proto_block_restart "$interface"
		return 1
	fi

	local IS_XMM=0
	[ "$(cat "/sys/bus/usb/devices/$usbpath/idVendor" 2>/dev/null)" = "8087" ] && IS_XMM=1
	[ "$(cat "/sys/bus/usb/devices/$usbpath/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$usbpath/idProduct" 2>/dev/null)" = "2cb7:000b" ] && IS_XMM=1
	local IS_R11E=0
	[ "$(cat "/sys/bus/usb/devices/$usbpath/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$usbpath/idProduct" 2>/dev/null)" = "2cd2:0001" ] && IS_R11E=1

	local dial="$atport"
	if [ -z "$dial" ] && [ -n "$usbpath" ]; then
		local own_at
		own_at=$(uci -q get "5gmodem.m_$(printf '%s' "$usbpath" | sed 's/[^A-Za-z0-9]/_/g').at_port")
		[ -n "$own_at" ] || own_at=$(uci -q get 5gmodem.@5gmodem[0].at_port)
		dial=$(_fibocom_atport "$usbpath" "$own_at")
	fi
	if [ -z "$dial" ]; then
		echo "fibocom[$$] no AT port found at path \"$usbpath\" (neither ttyUSB nor ttyACM answered AT)"
		proto_notify_error "$interface" NO_AT_PORT
		sleep 10
		return 1
	fi

	_fib_lock_held=""
	if [ -r /usr/share/5gmodem/atlock.sh ]; then
		. /usr/share/5gmodem/atlock.sh 2>/dev/null
		if command -v at_lock >/dev/null 2>&1 && at_lock "$dial" 20; then
			_fib_lock_held=1
		else
			echo "fibocom[$$] AT port $dial is busy - proceeding without the queue"
		fi
	fi
	_fib_unlock() {
		[ -n "$_fib_lock_held" ] || return 0
		_fib_lock_held=""
		command -v at_unlock >/dev/null 2>&1 && at_unlock "$dial"
	}

	R11E_CYCLED=""
	[ "$IS_R11E" = 1 ] && _r11e_prepare "$dial" "$pdptype" "$apn" "$interface"
	local _reg="" _rw=0 _kick=0
	while :; do
		_reg=$(_fibocom_reg "$dial")
		case "$_reg" in 1|5|6|7|9|10) break ;; esac
		if [ "$_kick" = 0 ] && [ "$(_fibocom_cops_mode "$dial")" = 2 ]; then
			_kick=1
			echo "fibocom[$$] modem was deregistered (+COPS: 2) - enabling automatic network search"
			sms_tool -d "$dial" at "AT+COPS=0" >/dev/null 2>&1
		fi
		[ "$_rw" -ge 60 ] && break
		sleep 5; _rw=$((_rw + 5))
	done

	case "$_reg" in
		5|7|10)
			if [ "$allow_roaming" != "1" ]; then
				echo "fibocom[$$] roaming registration ($_reg) and roaming is not allowed"
				_fib_unlock
				proto_notify_error "$interface" ROAMING_NOT_ALLOWED
				proto_block_restart "$interface"
				return 1
			fi
			;;
		1|6|9) ;;
		3)
			echo "fibocom[$$] network refused registration (+CEREG stat 3) - SIM/subscription/IMEI"
			_fibocom_why "$dial" "$IS_XMM"
			_fib_unlock
			proto_notify_error "$interface" REGISTRATION_DENIED
			proto_block_restart "$interface"
			return 1
			;;
		*)
			echo "fibocom[$$] no network registration (+CEREG stat \"${_reg:-no answer}\") after ${_rw}s"
			_fibocom_why "$dial" "$IS_XMM"
			_fib_unlock
			proto_notify_error "$interface" NOT_REGISTERED
			return 1
			;;
	esac

	local bands_changed=0
	local bmark="/tmp/5gmodem/bandsprep_$interface"
	local bdev
	bdev=$(cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null)
	if { [ ! -e "$bmark" ] || [ "$(cat "$bmark" 2>/dev/null)" != "$bdev" ]; } && [ "$(uci -q get 5gmodem.@5gmodem[0].save_bands)" != "0" ]; then
		local bsec="" bs bpath
		for bs in $(uci -q show 5gmodem 2>/dev/null \
				| sed -n 's/^\(5gmodem\.m_[0-9A-Za-z_]*\)\.network=.*/\1/p'); do
			[ "$(uci -q get "$bs.network")" = "$interface" ] || continue
			bsec="$bs"; break
		done
		bpath=$(uci -q get "$bsec.path" 2>/dev/null)
		[ -n "$bpath" ] || bpath="$usbpath"
		if [ -n "$bpath" ] && [ -n "$(uci -q get "$bsec.save_band")$(uci -q get "$bsec.save_band5gnsa")$(uci -q get "$bsec.save_band5gsa")" ]; then
			BANDS_ACTIVE_MODEM="$bpath" /usr/share/5gmodem/bands.sh restorebands prepare
			[ "$?" = "0" ] && { bands_changed=1; R11E_CYCLED=1; }
			: > "/tmp/5gmodem/bandrestore_$interface" 2>/dev/null
		fi
		echo "$bdev" > "$bmark" 2>/dev/null
	fi

	local ip="" try
	local net_plmn net_was net_f cold_f
	net_f="/tmp/5gmodem/fibo_plmn_$interface"
	cold_f="/tmp/5gmodem/fibo_cold_$interface"
	net_plmn=$(sms_tool -d "$dial" at "AT+COPS?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+COPS:.*,"\([0-9]\{5,6\}\)".*/\1/p' | head -1)
	net_was=$(cat "$net_f" 2>/dev/null)
	if [ -f "$cold_f" ]; then
		rm -f "$cold_f"
		echo "fibocom[$$] recovery requested - re-establishing the session"
		bands_changed=1
	elif [ -n "$net_was" ] && [ -n "$net_plmn" ] && [ "$net_plmn" != "$net_was" ]; then
		echo "fibocom[$$] network changed ($net_was -> $net_plmn) - not reusing the old session"
		bands_changed=1
	fi

	case "$auth" in
		pap|chap|both)
			if [ -n "$username" ]; then
				_au_now=$(cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null)
				_au_was=$(cat "/tmp/5gmodem/fibocom_authed_$interface" 2>/dev/null)
				if [ -z "$_au_was" ] || [ "$_au_now" != "$_au_was" ]; then
					echo "fibocom[$$] modem was re-enumerated - PAP/CHAP authorization lost, cold dial"
					bands_changed=1
				fi
			fi ;;
	esac
	local r11e_cid="" r11e_ip="" r11e_mask="" r11e_gw="" r11e_dns1="" r11e_dns2=""
	if [ "$IS_R11E" = 1 ]; then
		if [ "$bands_changed" = 1 ] && [ "$R11E_CYCLED" != 1 ]; then
			echo "fibocom[$$] R11e-LTE: new session requested - radio off and on"
			_r11e_at "$dial" 'AT+CFUN=4' >/dev/null
			sleep 2
			_r11e_at "$dial" 'AT+CFUN=1' >/dev/null
		fi
		r11e_cid=$(_r11e_cid "$dial" "$apn" 90)
		if [ -n "$r11e_cid" ]; then
			eval "$(_r11e_rdp "$(_r11e_at "$dial" "AT+CGCONTRDP=$r11e_cid" | grep '+CGCONTRDP:' | head -1)")"
			ip="$r11e_ip"
			echo "fibocom[$$] R11e-LTE: context $r11e_cid, address ${ip:-none}/$r11e_mask via $r11e_gw"
		else
			echo "fibocom[$$] R11e-LTE: the network brought up no data context (AT+CGACT? has none active)"
		fi
	fi
	if [ "$IS_R11E" != 1 ] && [ "$bands_changed" = "0" ] && sms_tool -d "$dial" at "AT+CGACT?" 2>/dev/null | tr -d '\r' | grep -qE '^\+CGACT: *1,1'; then
		local cur_ctx cur_apn cur_pdp
		cur_ctx=$(sms_tool -d "$dial" at "AT+CGDCONT?" 2>/dev/null | tr -d '\r' \
			| grep '^+CGDCONT: *1,' | head -1)
		cur_pdp=$(echo "$cur_ctx" | sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p')
		cur_apn=$(echo "$cur_ctx" | sed -n 's/^+CGDCONT: *1,"[^"]*","\([^"]*\)".*/\1/p')
		local pdp_ok="$pdptype"
		[ "$(cat "/tmp/5gmodem/fibo_pdpalt_$interface" 2>/dev/null)" = "$pdptype>$cur_pdp" ] && pdp_ok="$cur_pdp"
		if { [ -z "$apn" ] || [ "$cur_apn" = "$apn" ]; } && [ "$cur_pdp" = "$pdp_ok" ]; then
			ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CGPADDR: *1,//p' | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9]{1,3}([.][0-9]{1,3}){3}$' | head -1)
			[ "$ip" = "0.0.0.0" ] && ip=""
			if [ -n "$ip" ]; then
				case "$(sms_tool -d "$dial" at "AT+CGATT?" 2>/dev/null | tr -d '\r' \
					| sed -n 's/^+CGATT: *\([0-9]\).*/\1/p' | head -1)" in
					1) : ;;
					*) echo "fibocom[$$] context is active but the modem is not attached (CGATT!=1) - cold dial"
					   ip="" ;;
				esac
			fi
		else
			echo "fibocom[$$] context (APN \"$cur_apn\", $cur_pdp) != configured (APN \"$apn\", $pdptype) - cold dial"
		fi
	fi

	if [ -z "$ip" ] && [ "$IS_R11E" != 1 ]; then
		ip=$(_fibocom_activate "$dial" "$pdptype" "$apn")
		if [ -z "$ip" ]; then
			local alt="IPV4V6"; [ "$pdptype" = "IPV4V6" ] && alt="IP"
			echo "fibocom[$$] no IP with $pdptype, retrying $alt"
			ip=$(_fibocom_activate "$dial" "$alt" "$apn")
			[ -n "$ip" ] && echo "$pdptype>$alt" > "/tmp/5gmodem/fibo_pdpalt_$interface"
		fi
	fi
	if [ -z "$ip" ]; then
		_fib_unlock
		proto_notify_error "$interface" NO_IP_ADDRESS
		[ "$IS_R11E" = 1 ] || proto_block_restart "$interface"
		return 1
	fi

	local rdp gw dns1 dns2
	rdp=$(sms_tool -d "$dial" at "AT+CGCONTRDP=${r11e_cid:-1}" 2>/dev/null | tr -d '\r' | grep '+CGCONTRDP:' | head -1)
	gw=$(echo "$rdp"   | awk -F',' '{gsub(/"/,"",$5); print $5}')
	dns1=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$6); print $6}')
	dns2=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$7); print $7}')
	if [ "$IS_R11E" = 1 ]; then
		gw="$r11e_gw"; dns1="$r11e_dns1"; dns2="$r11e_dns2"
	fi

	local ctx_pdp
	ctx_pdp=$(sms_tool -d "$dial" at "AT+CGDCONT?" 2>/dev/null | tr -d '\r' \
		| sed -n "s/^+CGDCONT: *${r11e_cid:-1},\"\([^\"]*\)\".*/\1/p" | head -1)

	ip link set "$netdev" up 2>/dev/null
	if [ "$IS_XMM" = 1 ]; then
		ip link set "$netdev" arp off 2>/dev/null
		gw=""
		local xd
		xd=$(sms_tool -d "$dial" at "AT+XDNS?" 2>/dev/null | tr -d '\r' | grep '^+XDNS: 1,' | head -1)
		[ -n "$xd" ] && {
			dns1=$(echo "$xd" | awk -F'"' '{print $2}')
			dns2=$(echo "$xd" | awk -F'"' '{print $4}')
		}
	fi

	proto_init_update "$netdev" 1
	proto_add_ipv4_address "$ip" "${r11e_mask:-255.255.255.0}"
	case "$gw" in
		""|"0.0.0.0") proto_add_ipv4_route "0.0.0.0" "0" ;;
		*)            proto_add_ipv4_route "0.0.0.0" "0" "$gw" ;;
	esac
	[ -n "$dns1" ] && [ "$dns1" != "0.0.0.0" ] && proto_add_dns_server "$dns1"
	[ -n "$dns2" ] && [ "$dns2" != "0.0.0.0" ] && proto_add_dns_server "$dns2"
	[ -n "$net_plmn" ] && printf '%s' "$net_plmn" > "$net_f" 2>/dev/null
	_fib_unlock
	proto_send_update "$interface"

	case "$ctx_pdp" in
		*[vV]6*)
			local zone6
			zone6=$(_fibocom_fwzone "$interface")
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			[ "$sourcefilter" = "0" ] && json_add_boolean sourcefilter "0"
			proto_add_dynamic_defaults
			[ -n "$zone6" ] && json_add_string zone "$zone6"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
			echo "fibocom[$$] IPv6 ($ctx_pdp): brought up dhcpv6 interface ${interface}_6 (zone ${zone6:--})"
			;;
	esac

	if [ "$IS_R11E" != 1 ] && [ "$(uci -q get "network.$interface.ipwatch")" = 1 ]; then
		echo "fibocom[$$] following network address changes on $dial"
		proto_run_command "$interface" /usr/share/5gmodem/fiboipwatch.sh \
			"$interface" "$dial" "$ip" "$(uci -q get "network.$interface.ipwatch_interval")"
	fi
}

proto_fibocom_teardown() {
	local interface="$1"
	# see docs/modems/fibocom.md#teardown-keeps-the-bearer
}

add_protocol fibocom
