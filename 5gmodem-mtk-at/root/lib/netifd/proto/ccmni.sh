#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

. /usr/share/5gmodem/mtk/env.sh

ccmni_at() {
	$MTK_USOCK $MTK_SOCK "$1" "${2:-3000}" 2>/dev/null | tr -d '\r' | grep -v '^$' | grep -v '^AT'
}

ccmni_addr4() {
	ccmni_at "AT+CGPADDR=0" | sed -n 's/^+CGPADDR: *0, *"\([0-9.]*\)".*/\1/p' | grep -E '^[0-9]+([.][0-9]+){3}$' | head -1
}

ccmni_ctx() {
	ccmni_at "AT+CGDCONT?" | sed -n 's/^+CGDCONT: *0, *"\([^"]*\)", *"\([^"]*\)".*/\1 \2/p' | head -1
}

ccmni_fwzone() {
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

ccmni_cycle() {
	local i
	ccmni_at "AT+EFUN=0" 15000 >/dev/null
	sleep 3
	ccmni_at "AT+EFUN=1" 15000 >/dev/null
	for i in $(seq 1 "$1"); do
		ccmni_registered && return 0
		sleep 1
	done
	return 1
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
	proto_config_add_string "at_device"
	proto_config_add_string "apn"
	proto_config_add_string "pdptype"
	proto_config_add_boolean "peerdns"
	proto_config_add_int "metric"
}

proto_ccmni_setup() {
	local interface="$1"
	local ifname at_device apn pdptype regtimeout defaultroute peerdns metric i ip rdp dns1 dns2 ctx cur_pdp cur_apn zone6
	json_get_vars ifname at_device apn pdptype regtimeout defaultroute peerdns metric
	[ -n "$at_device" ] && MTK_SOCK="$at_device"
	ifname="${ifname:-ccmni0}"
	regtimeout="${regtimeout:-90}"

	[ -x "$MTK_USOCK" ] || {
		proto_notify_error "$interface" NO_AT_CLIENT
		proto_block_restart "$interface"
		return 1
	}
	for i in $(seq 1 60); do
		[ -e "$MTK_SOCK" ] && break
		sleep 1
	done
	for i in $(seq 1 90); do
		[ -e "$MTK_SOCK" ] && ccmni_at AT 2000 | grep -q OK && break
		sleep 1
	done
	ccmni_at AT 2000 | grep -q OK || {
		proto_notify_error "$interface" NO_ATCI
		return 1
	}

	pdptype=$(echo "$pdptype" | tr 'a-z' 'A-Z')
	case "$pdptype" in
		IPV4) pdptype="IP" ;;
		""|IP|IPV6|IPV4V6) ;;
		*) pdptype="IPV4V6" ;;
	esac

	if ! ccmni_registered; then
		case "$(ccmni_at 'AT+CPIN?')" in
			*"CME ERROR: 10"*)
				echo "ccmni: SIM not detected, restarting the SIM"
				ccmni_at "AT+CFUN=0" 15000 >/dev/null
				sleep 2
				ccmni_at "AT+CFUN=4" 15000 >/dev/null
				for i in $(seq 1 15); do
					ccmni_at 'AT+CPIN?' | grep -q 'CPIN: ' && break
					sleep 1
				done
				;;
		esac
		case "$(ccmni_at 'AT+CFUN?')" in
			*"CFUN: 0"*|*"CFUN: 4"*)
				ctx=$(ccmni_ctx)
				cur_pdp="${ctx%% *}"
				cur_apn="${ctx#* }"
				[ "$ctx" = "$cur_pdp" ] && cur_apn=""
				[ -n "$apn" ] || apn="$cur_apn"
				[ -n "$pdptype" ] && { [ "$pdptype" != "$cur_pdp" ] || [ "$apn" != "$cur_apn" ]; } && \
					ccmni_at "AT+CGDCONT=0,\"$pdptype\",\"$apn\"" >/dev/null
				;;
		esac
		ccmni_at "AT+CMEE=1" >/dev/null
		ccmni_at "AT+EMSR=0,0" >/dev/null
		ccmni_at "AT+EGFB=0,1" >/dev/null
		ccmni_at "AT+EGTYPE=3" >/dev/null
		ccmni_at "AT+EGTYPE=2" >/dev/null
		ccmni_at "AT+EFUN=1" 15000 >/dev/null
		for i in $(seq 1 "$regtimeout"); do
			ccmni_registered && break
			sleep 1
		done
		ccmni_registered || ccmni_cycle "$regtimeout"
	fi
	ctx=$(ccmni_ctx)
	cur_pdp="${ctx%% *}"
	cur_apn="${ctx#* }"
	[ "$ctx" = "$cur_pdp" ] && cur_apn=""
	[ -n "$pdptype" ] || pdptype="$cur_pdp"
	[ -n "$apn" ] || apn="$cur_apn"
	if [ -n "$pdptype" ] && { [ "$pdptype" != "$cur_pdp" ] || [ "$apn" != "$cur_apn" ]; }; then
		echo "ccmni: attach context ($cur_pdp \"$cur_apn\") -> ($pdptype \"$apn\"), restarting the radio"
		ccmni_at "AT+EFUN=0" 15000 >/dev/null
		sleep 3
		ccmni_at "AT+CGDCONT=0,\"$pdptype\",\"$apn\"" >/dev/null
		ccmni_at "AT+EFUN=1" 15000 >/dev/null
		for i in $(seq 1 "$regtimeout"); do
			ccmni_registered && break
			sleep 1
		done
		ccmni_registered || ccmni_cycle "$regtimeout"
	fi

	ccmni_registered || {
		echo "ccmni: not registered: $(ccmni_at 'AT+CEREG?' | grep CEREG) $(ccmni_at 'AT+COPS?' | grep COPS)"
		proto_notify_error "$interface" NOT_REGISTERED
		return 1
	}

	ip=""
	for i in $(seq 1 30); do
		ip=$(ccmni_addr4)
		[ -n "$ip" ] && break
		sleep 1
	done
	[ -n "$ip" ] || {
		proto_notify_error "$interface" NO_ADDRESS
		return 1
	}
	for i in $(seq 1 10); do
		rdp=$(ccmni_at "AT+CGCONTRDP" 8000 | grep '+CGCONTRDP:' | head -1)
		dns1=$(echo "$rdp" | cut -d, -f6 | tr -d '" ' | grep -E '^[0-9]+([.][0-9]+){3}$')
		dns2=$(echo "$rdp" | cut -d, -f7 | tr -d '" ' | grep -E '^[0-9]+([.][0-9]+){3}$')
		[ -n "$dns1" ] && break
		sleep 1
	done
	[ -n "$dns1" ] || echo "ccmni: no DNS from the network"

	case "$(ccmni_at 'AT+CGDATA="M-CCMNI",0,1' 10000)" in
		*OK*|*"CME ERROR: 4356"*) ;;
		*) proto_notify_error "$interface" CGDATA_FAILED; return 1 ;;
	esac
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

	case "$(ccmni_ctx)" in
		*V6*)
			zone6=$(ccmni_fwzone "$interface")
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			proto_add_dynamic_defaults
			[ -n "$zone6" ] && json_add_string zone "$zone6"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
			;;
	esac

	/usr/share/5gmodem/mtk/modem-init.sh </dev/null >/dev/null 2>&1 &
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
