# uplink_notify only, without lib.sh: sourced by lib.sh and by
# /etc/hotplug.d/iface/62-5gmodem-uplink, which runs on every ifupdate.
# Keep it free of lib.sh helpers.

# Primary uplink = the IPv4 default route with the lowest metric in the main
# table. When it differs from the last one seen, fire
#   ACTION=primary INTERFACE DEVICE PREVIOUS PREVIOUS_DEVICE REASON
#   /sbin/hotplug-call 5gmodem-uplink   (and ubus event 5gmodem.uplink)
# in the background. Contract: docs/subsystems/internet-priority.md#primary-uplink-event
# $1 = reason (netpri, health, iface)
uplink_notify() {
	[ -x /sbin/hotplug-call ] || return 0
	mkdir -p /tmp/5gmodem 2>/dev/null
	(
		exec 5>/tmp/5gmodem/uplink.lock 2>/dev/null || exit 0
		flock 5
		_un_dev=$(ip -4 route show default 2>/dev/null | awk '
			$1 == "default" && $2 != "from" {
				m = 0; d = ""
				for (i = 2; i < NF; i++) { if ($i == "dev") d = $(i + 1); if ($i == "metric") m = $(i + 1) + 0 }
				if (d != "" && (b == "" || m < bm)) { bm = m; b = d }
			}
			END { print b }')
		_un_if=""
		if [ -n "$_un_dev" ]; then
			_un_dump=$(ubus call network.interface dump 2>/dev/null)
			for _un_c in $(printf '%s' "$_un_dump" | jsonfilter \
					-e "@.interface[@.l3_device=\"$_un_dev\"].interface" 2>/dev/null); do
				[ -n "$(printf '%s' "$_un_dump" | jsonfilter \
					-e "@.interface[@.interface=\"$_un_c\"][\"ipv4-address\"][0].address" 2>/dev/null)" ] \
					&& { _un_if="$_un_c"; break; }
				[ -n "$_un_if" ] || _un_if="$_un_c"
			done
			[ -n "$_un_if" ] || _un_if="$_un_dev"
		fi
		_un_prev=""; _un_pdev=""
		[ -f /tmp/5gmodem/uplink.primary ] && read -r _un_prev _un_pdev < /tmp/5gmodem/uplink.primary
		[ "$_un_if" = "$_un_prev" ] && [ "$_un_dev" = "$_un_pdev" ] && exit 0
		echo "$_un_if $_un_dev" > /tmp/5gmodem/uplink.primary
		logger -t 5gmodem "uplink: primary ${_un_prev:-none} -> ${_un_if:-none} (${1:-unknown})"
		(
			exec 5>&- 6>&- 7>&- 8>&- 9>&-
			unset _AT_LOCK_HELD
			ACTION=primary INTERFACE="$_un_if" DEVICE="$_un_dev" \
			PREVIOUS="$_un_prev" PREVIOUS_DEVICE="$_un_pdev" REASON="${1:-unknown}" \
				/sbin/hotplug-call 5gmodem-uplink
			ubus send 5gmodem.uplink "{\"action\":\"primary\",\"interface\":\"$_un_if\",\"device\":\"$_un_dev\",\"previous\":\"$_un_prev\",\"previous_device\":\"$_un_pdev\",\"reason\":\"${1:-unknown}\"}"
		) >/dev/null 2>&1 </dev/null &
	) >/dev/null 2>&1 </dev/null
}
