#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

MTK_SOCK=/dev/socket/rild-atci
MTK_USOCK=/usr/share/5gmodem/mtk/usock-armv7

ccmni_at() {
	$MTK_USOCK $MTK_SOCK "$1" "${2:-3000}" 2>/dev/null | tr -d '\r' | grep -v '^$'
}

ccmni_registered() {
	case "$(ccmni_at 'AT+CEREG?')" in
		*"CEREG: "[0-9]",1"*|*"CEREG: "[0-9]",5"*) return 0 ;;
	esac
	return 1
}

proto_ccmni_init_config() {
	no_device=1
	available=1
	proto_config_add_string "ifname"
	proto_config_add_int "regtimeout"
	proto_config_add_boolean "defaultroute"
	proto_config_add_boolean "peerdns"
	proto_config_add_int "metric"
}

proto_ccmni_setup() {
	local interface="$1"
	local ifname regtimeout defaultroute peerdns metric i ip rdp dns1 dns2
	json_get_vars ifname regtimeout defaultroute peerdns metric
	ifname="${ifname:-ccmni0}"
	regtimeout="${regtimeout:-90}"

	[ -x "$MTK_USOCK" ] || {
		proto_notify_error "$interface" NO_AT_CLIENT
		proto_block_restart "$interface"
		return 1
	}
	for i in $(seq 1 30); do
		[ -S "$MTK_SOCK" ] && ccmni_at AT 2000 | grep -q OK && break
		sleep 2
	done
	ccmni_at AT 2000 | grep -q OK || {
		proto_notify_error "$interface" NO_ATCI
		return 1
	}

	if ! ccmni_registered; then
		ccmni_at "AT+EMSR=0,0" >/dev/null
		ccmni_at "AT+EGFB=0,1" >/dev/null
		ccmni_at "AT+EGTYPE=3" >/dev/null
		ccmni_at "AT+EGTYPE=2" >/dev/null
		ccmni_at "AT+EFUN=1" 15000 >/dev/null
		for i in $(seq 1 "$regtimeout"); do
			ccmni_registered && break
			sleep 1
		done
	fi
	ccmni_registered || {
		echo "ccmni: not registered: $(ccmni_at 'AT+CEREG?' | grep CEREG) $(ccmni_at 'AT+COPS?' | grep COPS)"
		proto_notify_error "$interface" NOT_REGISTERED
		return 1
	}

	ip=""
	for i in $(seq 1 30); do
		ip=$(ccmni_at "AT+CGPADDR=0" | sed -n 's/.*"\([0-9.]*\)".*/\1/p' | head -1)
		[ -n "$ip" ] && break
		sleep 1
	done
	[ -n "$ip" ] || {
		proto_notify_error "$interface" NO_ADDRESS
		return 1
	}
	rdp=$(ccmni_at "AT+CGCONTRDP" | grep '+CGCONTRDP:' | head -1)
	dns1=$(echo "$rdp" | cut -d, -f6 | tr -d '" ')
	dns2=$(echo "$rdp" | cut -d, -f7 | tr -d '" ')

	ccmni_at 'AT+CGDATA="M-CCMNI",0,1' 10000 >/dev/null
	ip addr flush dev "$ifname" 2>/dev/null
	ip link set "$ifname" up

	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_ipv4_address "$ip" 32
	[ "${defaultroute:-1}" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "" "" "$metric"
	[ "${peerdns:-1}" = 0 ] || {
		[ -n "$dns1" ] && proto_add_dns_server "$dns1"
		[ -n "$dns2" ] && proto_add_dns_server "$dns2"
	}
	proto_send_update "$interface"

	proto_run_command "$interface" /usr/share/5gmodem/mtk/ccmni-watch.sh "$ip"
}

proto_ccmni_teardown() {
	local interface="$1"
	local ifname
	json_get_vars ifname
	ifname="${ifname:-ccmni0}"
	proto_kill_command "$interface"
	ip addr flush dev "$ifname" 2>/dev/null
	ip link set "$ifname" down 2>/dev/null
	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol ccmni
}
