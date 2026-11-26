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

# CFUN transitions can be rejected after a SIM-wait cancellation. A fresh
# SIM event permits one native modem power-on recovery, never a reset loop.
ccmni_recover_radio() {
	local interface="$1" dir=/tmp/5gmodem/simwait stamp previous consumed
	case "$interface" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	[ -r "$dir/$interface.resume" ] || return 1
	read -r stamp < "$dir/$interface.resume"
	case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
	consumed=$(cat "$dir/$interface.ccmni_resume" 2>/dev/null || :)
	[ "$stamp" != "$consumed" ] || return 1
	previous=$(cat "$dir/$interface.ccmni_radio" 2>/dev/null || :)
	[ "$stamp" != "$previous" ] || return 1
	# Record before sending: EPON may remove the AT port before replying.
	printf '%s\n' "$stamp" > "$dir/$interface.ccmni_radio" || return 1
	echo "ccmni: restoring modem power after SIM insertion"
	ccmni_at 'AT+EPON' 10000 >/dev/null || :
	return 0
}

ccmni_attach_packet() {
	local i
	for i in $(seq 1 12); do
		if ccmni_at 'AT+CGATT?' | grep -q '^+CGATT: *1$'; then
			break
		fi
		# Detach completion can precede readiness for another attach request.
		# Retry transient errors; only the queried state confirms completion.
		ccmni_at 'AT+CGATT=1' 5000 >/dev/null
		sleep 1
	done
	ccmni_at 'AT+CGATT?' | grep -q '^+CGATT: *1$' || return 1
}

# A newly inserted SIM needs a fresh packet session even if the old bearer
# still reports an address. Consume each SIM-ready event only after reattach.
ccmni_resume_sim() {
	local interface="$1" dir=/tmp/5gmodem/simwait stamp consumed i detached=0
	case "$interface" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	[ -r "$dir/$interface.resume" ] || return 0
	read -r stamp < "$dir/$interface.resume"
	case "$stamp" in ''|*[!0-9]*) return 0 ;; esac
	consumed=$(cat "$dir/$interface.ccmni_resume" 2>/dev/null || :)
	[ "$stamp" != "$consumed" ] || return 0
	echo "ccmni: renewing packet session after SIM insertion"
	ccmni_at 'AT+CGATT=0' 10000 | grep -q '^OK$' || return 1
	for i in $(seq 1 5); do
		if ccmni_at 'AT+CGATT?' | grep -q '^+CGATT: *0$'; then
			detached=1
			break
		fi
		sleep 1
	done
	[ "$detached" = 1 ] || return 1
	ccmni_attach_packet || return 1
	printf '%s\n' "$stamp" > "$dir/$interface.ccmni_resume"
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
	local ifname at_device apn pdptype regtimeout defaultroute peerdns metric i ip rdp dns1 dns2 ctx cur_pdp cur_apn zone6 context_changed=0 packet_detached=0
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
	fi

	# Waiting for an absent SIM can cancel setup between CFUN=0 and CFUN=4.
	# Resume from that intermediate state before attempting to enable the radio.
	case "$(ccmni_at 'AT+CFUN?')" in
		*"CFUN: 0"*)
			ccmni_at 'AT+CFUN=4' 15000 | grep -q '^OK$' || {
				ccmni_recover_radio "$interface" || \
					proto_notify_error "$interface" RADIO_PREPARE_FAILED
				sleep 5
				return 1
			}
			;;
	esac

	# SIM reinsertion can restore the modem's placeholder attach context.
	# An unset APN means automatic selection, not reuse of that context.
	ctx=$(ccmni_ctx)
	[ -n "$ctx" ] || {
		proto_notify_error "$interface" NO_ATTACH_CONTEXT
		return 1
	}
	cur_pdp="${ctx%% *}"
	cur_apn="${ctx#* }"
	[ "$ctx" = "$cur_pdp" ] && cur_apn=""
	[ -n "$pdptype" ] || pdptype="$cur_pdp"
	if [ "$pdptype" != "$cur_pdp" ] || [ "$apn" != "$cur_apn" ]; then
		echo "ccmni: configuring attach context before registration"
		case "$(ccmni_at 'AT+CFUN?')" in
			*"CFUN: 0"*|*"CFUN: 4"*) ;;
			*)
				if ccmni_at "AT+EFUN=0" 15000 | grep -q '^OK$'; then
					sleep 3
				elif ccmni_at 'AT+CGATT?' | grep -q '^+CGATT: *0$'; then
					# With no packet registration EFUN may be rejected even
					# though the attach context is writable. Reattach explicitly.
					packet_detached=1
				else
					proto_notify_error "$interface" ATTACH_CONTEXT_FAILED
					sleep 5
					return 1
				fi
				;;
		esac
		ccmni_at "AT+CGDCONT=0,\"$pdptype\",\"$apn\"" | grep -q '^OK$' || {
			proto_notify_error "$interface" ATTACH_CONTEXT_FAILED
			sleep 5
			return 1
		}
		context_changed=1
	fi

	if [ "$packet_detached" = 1 ]; then
		ccmni_attach_packet || {
			proto_notify_error "$interface" PACKET_ATTACH_FAILED
			sleep 5
			return 1
		}
		context_changed=0
	fi

	if [ "$context_changed" = 1 ] || ! ccmni_registered; then
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

	ccmni_registered || {
		echo "ccmni: not registered: $(ccmni_at 'AT+CEREG?' | grep CEREG) $(ccmni_at 'AT+COPS?' | grep COPS)"
		proto_notify_error "$interface" NOT_REGISTERED
		return 1
	}

	ccmni_resume_sim "$interface" || {
		proto_notify_error "$interface" PACKET_ATTACH_FAILED
		sleep 5
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
