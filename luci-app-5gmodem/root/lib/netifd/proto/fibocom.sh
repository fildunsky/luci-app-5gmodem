#!/bin/sh
#
# netifd protocol handler: "fibocom"
#
# Data connection for AT-dialed RNDIS/ECM modems that ModemManager cannot drive
# (e.g. Fibocom FM350-GL, USB id 0e8d:7127 / 0e8d:7126). These modems expose NO
# cdc-wdm control channel - data goes over a plain usbnet device (eth*), and the
# host must bring up the PDP context itself over an AT port and then assign the
# modem-provided IP/DNS statically (the modem serves no DHCP).
#
# Sequence: AT+CGDCONT (define APN) -> AT+CGACT=1,1 (activate) ->
#   AT+CGPADDR (assigned IP) -> AT+CGCONTRDP (gateway/DNS), all standard 3GPP.
# The interface is bound to the modem by its STABLE USB topology path (usbpath),
# so it survives ttyUSB/eth renumbering across reboots and modem swaps.
#
# Interface options:
#   usbpath  - USB topology path of the modem, e.g. "1-1.3" (preferred)
#   device   - usbnet device (eth2); used only if usbpath is unset
#   atport   - AT port to dial on; auto-picked (avoiding the metrics port) if unset
#   apn      - access point name (default: internet)
#   pdptype  - IP, IPV6 or IPV4V6 (default: IPV4V6)
#   metric   - route metric (default: 0)

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

# usbnet device (eth*) that belongs to a given USB topology path
_fibocom_netdev() {
	local p="$1" n
	for n in /sys/bus/usb/devices/$p:*/net/*; do
		[ -e "$n" ] || continue
		basename "$n"
		return 0
	done
	return 1
}

# an AT-capable ttyUSB of this modem, preferring one that is NOT the app's
# metrics/AT port (so the periodic metrics poll and our dial do not collide on
# the same tty and cross their replies)
_fibocom_atport() {
	local p="$1" avoid="$2" t tt fallback=""
	for t in /sys/bus/usb/devices/$p:*/ttyUSB* /sys/bus/usb/devices/$p:*/ttyACM*; do
		[ -e "$t" ] || continue
		tt="/dev/$(basename "$t")"
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

proto_fibocom_init_config() {
	no_device=1
	available=1
	proto_config_add_string "usbpath"
	proto_config_add_string "device"
	proto_config_add_string "atport"
	proto_config_add_string "apn"
	proto_config_add_string "pdptype"
	proto_config_add_int "metric"
	proto_config_add_defaults
}

proto_fibocom_setup() {
	local interface="$1"
	local usbpath device atport apn pdptype metric
	json_get_vars usbpath device atport apn pdptype metric

	[ -n "$apn" ] || apn="internet"
	[ -n "$pdptype" ] || pdptype="IPV4V6"

	# resolve the usbnet device (eth*) and a dial AT port from the stable path
	local netdev=""
	if [ -n "$usbpath" ]; then
		netdev=$(_fibocom_netdev "$usbpath")
		# Сетевого устройства нет - вероятно, usbnet-драйвер не загружен. FM350 в
		# RNDIS-композиции (GTUSBMODE 41: IAD Cls=e0 Sub=01 Prot=03) требует
		# rndis_host; на части прошивок (напр. Cudy WBR3000UAX, ядро 6.12) он не
		# загружен, пока его явно не подтянуть, и интерфейсы модема остаются с
		# Driver=(none). Грузим драйверы и ждём, пока ядро привяжет их к уже
		# воткнутому модему (при загрузке usbnet-модуль сканирует существующие
		# устройства). modprobe идемпотентен: если уже загружен - no-op.
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
		proto_notify_error "$interface" NO_NETDEV
		proto_set_available "$interface" 0
		return 1
	fi
	# Устройство из uci (fallback) может НЕ СУЩЕСТВОВАТЬ в системе. Так бывает,
	# когда драйвер usbnet не привязался к FM350: на части прошивок (напр. Cudy
	# WBR3000UAX, OpenWrt 25.12.5 / ядро 6.12) сетевые интерфейсы модема остаются
	# с Driver=(none), и /sys/class/net/wwanN не создаётся. Раньше мы всё равно
	# слали netifd proto_send_update на несуществующий wwanN -> netifd отвечал
	# "Unknown error", интерфейс падал, netifd тут же поднимал его заново - и так
	# по кругу каждые 5 c, забивая лог. Честная ошибка лучше бесконечного цикла.
	if [ ! -d "/sys/class/net/$netdev" ]; then
		proto_notify_error "$interface" NETDEV_MISSING
		proto_block_restart "$interface"
		return 1
	fi

	local dial="$atport"
	if [ -z "$dial" ] && [ -n "$usbpath" ]; then
		dial=$(_fibocom_atport "$usbpath" "$(uci -q get 5gmodem.@5gmodem[0].at_port)")
	fi
	if [ -z "$dial" ]; then
		proto_notify_error "$interface" NO_AT_PORT
		proto_set_available "$interface" 0
		return 1
	fi

	# FAST PATH: if the PDP context is ALREADY active with a valid address, reuse
	# it instead of re-dialing. netifd calls teardown+setup on any reconfigure -
	# e.g. a route-metric change from the WAN-priority switcher, or a spurious
	# reload - and a cold re-dial tore the data session for ~30-60 s every time we
	# switched TO this modem. Together with the teardown that no longer releases
	# the context, a priority switch becomes instant and lossless (we just
	# re-publish the IP/route with the new metric).
	local ip="" try
	if sms_tool -d "$dial" at "AT+CGACT?" 2>/dev/null | tr -d '\r' | grep -qE '^\+CGACT: *1,1'; then
		ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*+CGPADDR: *1,"\([0-9.]\{7,\}\)".*/\1/p' | head -1)
		[ "$ip" = "0.0.0.0" ] && ip=""
	fi

	# COLD DIAL: define the APN, activate the PDP context and read the assigned
	# IPv4 from CGPADDR, retrying a few times - right after a modem swap / USB
	# re-enumeration the context needs a moment, and a single try would leave the
	# interface down until netifd happens to retry.
	if [ -z "$ip" ]; then
		sms_tool -d "$dial" at "AT+CGDCONT=1,\"$pdptype\",\"$apn\"" >/dev/null 2>&1
		# RELEASE FIRST: a bare AT+CGACT=1,1 HANGS when the PDP context is wedged in
		# a half-active state - the exact state a band change (AT+GTACT) leaves it in
		# on the FM350: the old bearer is gone but the context engine keeps answering
		# nothing to a plain re-activate, so the IP never comes back (user report:
		# disable B3 -> IP vanishes for good). Deactivating the context first
		# (AT+CGACT=0,1) clears that wedge; the following re-activate then succeeds
		# and CGPADDR returns a fresh address. On a cold (already-down) context the
		# release is a harmless no-op/ERROR. Verified live on FM350-GL: GTACT drop of
		# a band + CGACT=0,1 -> CGACT=1,1 restored data (new IP) with no CFUN reset.
		sms_tool -d "$dial" at "AT+CGACT=0,1" >/dev/null 2>&1
		sleep 2
		for try in 1 2 3 4 5 6; do
			sms_tool -d "$dial" at "AT+CGACT=1,1" >/dev/null 2>&1
			sleep 2
			ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CGPADDR: *1,"\([0-9.]\{7,\}\)".*/\1/p' | head -1)
			[ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && break
			ip=""
		done
	fi
	if [ -z "$ip" ]; then
		proto_notify_error "$interface" NO_IP_ADDRESS
		proto_block_restart "$interface"
		return 1
	fi

	# gateway (field 5) and DNS (fields 6,7) from CGCONTRDP - gw is usually empty
	# on cellular (point-to-point), in which case the default route is on-link.
	local rdp gw dns1 dns2
	rdp=$(sms_tool -d "$dial" at "AT+CGCONTRDP=1" 2>/dev/null | tr -d '\r' | grep '+CGCONTRDP:' | head -1)
	gw=$(echo "$rdp"   | awk -F',' '{gsub(/"/,"",$5); print $5}')
	dns1=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$6); print $6}')
	dns2=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$7); print $7}')

	ip link set "$netdev" up 2>/dev/null

	proto_init_update "$netdev" 1
	proto_add_ipv4_address "$ip" "255.255.255.0"
	case "$gw" in
		""|"0.0.0.0") proto_add_ipv4_route "0.0.0.0" "0" ;;   # on-link default
		*)            proto_add_ipv4_route "0.0.0.0" "0" "$gw" ;;
	esac
	[ -n "$dns1" ] && [ "$dns1" != "0.0.0.0" ] && proto_add_dns_server "$dns1"
	[ -n "$dns2" ] && [ "$dns2" != "0.0.0.0" ] && proto_add_dns_server "$dns2"
	proto_send_update "$interface"
}

proto_fibocom_teardown() {
	local interface="$1"

	# NOTE: we deliberately do NOT deactivate the PDP context here. netifd calls
	# teardown+setup on any interface reconfigure (notably a route-metric change
	# from the WAN-priority switcher); releasing the context (AT+CGACT=0,1) each
	# time tore the data session and forced a slow re-dial. Leaving the bearer up
	# lets setup's fast path reuse it, so switching priority is instant and
	# lossless. The bearer costs nothing while the interface is down (no route, no
	# traffic); a true disconnect happens on USB re-enumeration / modem controls.
	proto_init_update "*" 0
	proto_send_update "$interface"
}

add_protocol fibocom
