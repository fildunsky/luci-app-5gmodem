#!/bin/sh
#
# Internet-priority switcher. Lists the interfaces in the firewall 'wan' zone
# that currently have an IPv4 address, and makes one of them the primary uplink
# by giving it the lowest route metric (others get a high metric). The chosen
# uplink then wins the default route.
#
# Usage:
#   netpri.sh list          - JSON array of WAN-zone interfaces with an IP
#   netpri.sh set <iface>   - make <iface> primary (metric 1), others metric 20
#

# networks that belong to the firewall 'wan' zone
wan_nets() {
	z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
	[ -n "$z" ] && uci -q get "firewall.$z.network"
}

ifup_state()  { ifstatus "$1" 2>/dev/null | jsonfilter -e "$2" 2>/dev/null; }
json_esc()    { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# IPv4 of an uplink. qmi/dhcp modems keep the real address on a dynamically
# created child interface "<name>_4" (the parent "<name>" stays up but IP-less),
# so if the parent has no address we look at its "<name>_*" children.
iface_ip() {
	p="$1"
	ip=$(ifup_state "$p" '@["ipv4-address"][0].address')
	[ -n "$ip" ] && { echo "$ip"; return; }
	for c in $(ubus call network.interface dump 2>/dev/null \
		| jsonfilter -e '@.interface[*].interface' 2>/dev/null | grep -E "^${p}_"); do
		ip=$(ifup_state "$c" '@["ipv4-address"][0].address')
		[ -n "$ip" ] && { echo "$ip"; return; }
	done
}

# uplink kind: wan | modem | wifi | other. Modem interfaces are checked BEFORE the
# Wi-Fi guess, because a modem's l3_device can be wwanN (must not read as Wi-Fi).
modem_section() {  # -> "m_<path>" whose network== $1, or empty
	uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='$1'\$/\1/p" | head -1
}
iface_type() {
	i="$1"
	case "$i" in wan|wan6) echo wan; return;; esac
	[ -n "$(modem_section "$i")" ] && { echo modem; return; }
	dev=$(ifup_state "$i" '@["l3_device"]')
	case "$dev" in phy*-sta*|wlan*) echo wifi; return;; esac
	echo other
}

# bounded AT query (~5s cap) so a wedged port can't freeze the caller
at_query() {
	D="$1"; C="$2"; tmp="/tmp/netpri_at.$$"
	sms_tool -d "$D" at "$C" >"$tmp" 2>/dev/null &
	p=$!; ( sleep 5; kill "$p" 2>/dev/null ) & k=$!
	wait "$p" 2>/dev/null; kill "$k" 2>/dev/null; wait "$k" 2>/dev/null
	cat "$tmp" 2>/dev/null; rm -f "$tmp"
}

# Cache-ONLY operator name (no AT, always instant). Empty if not cached / stale.
# 'list' uses this so it never blocks; the cache is filled by 'refresh' in the
# background. Cache is valid for 30 min.
operator_cached() {
	cf="/tmp/netpri_op_$1"
	[ -f "$cf" ] && [ -z "$(find "$cf" -mmin +30 2>/dev/null)" ] && cat "$cf"
}

# Probe the operator for ONE modem iface via AT+COPS and cache the result (used only
# by 'refresh', never by 'list'). ttyUSB numbering is unstable, so the saved at_port
# can be stale after a renumber; we try it first, then fall back to the modem's
# CURRENT ttys resolved from its stable USB path (listmodems), stopping at the first
# port that returns an operator name. Each modem has its own ports - no switch.
operator_probe() {
	i="$1"
	sec=$(modem_section "$i"); [ -n "$sec" ] || return
	path=$(uci -q get "5gmodem.$sec.path")
	cands=$(uci -q get "5gmodem.$sec.at_port")
	if [ -n "$path" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
		cands="$cands $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$path\"].tty[*]" 2>/dev/null)"
	fi
	for port in $cands; do
		[ -n "$port" ] && [ -e "$port" ] || continue
		# "=3,0" selects long alphanumeric format (read-only), then query
		name=$(at_query "$port" "AT+COPS=3,0;+COPS?" | tr -d '\r' \
			| sed -n 's/.*+COPS[^"]*"\([^"]*\)".*/\1/p' | head -1)
		# collapse a doubled long name ("T-Mobile T-Mobile" -> "T-Mobile")
		name=$(printf '%s' "$name" | awk '{
			if (NF>0 && NF%2==0) { h=NF/2; same=1;
				for(j=1;j<=h;j++) if($j!=$(j+h)) same=0;
				if(same){ s=$1; for(j=2;j<=h;j++) s=s" "$j; print s; next } }
			print }')
		[ -n "$name" ] && { printf '%s' "$name" > "/tmp/netpri_op_$i"; return; }
	done
}

# modem model name for the small top line (matches the modem-switch tab). Product
# from listmodems (by stable USB path), with a couple of friendly overrides.
model_for() {
	sec=$(modem_section "$1"); [ -n "$sec" ] || return
	path=$(uci -q get "5gmodem.$sec.path")
	prod=""
	[ -n "$path" ] && prod=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$path\"].product" 2>/dev/null | head -1)
	[ -n "$prod" ] || prod=$(uci -q get "5gmodem.$sec.product")
	case "$prod" in
		VOS_5G|RXMG1|RXM-G1) echo "Compal RXM-G1" ;;
		FM350*) echo "Fibocom $prod" ;;
		*) echo "$prod" ;;
	esac
}

# SSID of a Wi-Fi station interface
ssid_for() {
	dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$dev" ] || return
	ubus call network.wireless status 2>/dev/null \
		| jsonfilter -e "@[*].interfaces[@.ifname=\"$dev\"].config.ssid" 2>/dev/null | head -1
}

# friendly label: modem -> operator ("Модем N" fallback), wifi -> SSID, wan -> WAN
label_for() {
	i="$1"
	case "$(iface_type "$i")" in
	wan)  echo "WAN" ;;
	wifi) s=$(ssid_for "$i"); [ -n "$s" ] && echo "$s" || echo "Wi-Fi" ;;
	modem)
		# operator name once known; until the background probe fills the cache, fall
		# back to the standardized interface name (modem / modem2), not "Модем N"
		op=$(operator_cached "$i")
		[ -n "$op" ] && echo "$op" || echo "$i" ;;
	*) echo "$i" ;;
	esac
}

case "$1" in
list)
	printf '['
	first=1
	NEEDREFRESH=0
	# sort by interface name, like the LuCI "Interfaces" overview (naturalCompare)
	for n in $(wan_nets | tr ' ' '\n' | sort); do
		[ -n "$n" ] || continue
		uci -q get "network.$n" >/dev/null 2>&1 || continue
		[ "$n" = wan6 ] && continue                                   # ipv6 twin of wan
		[ "$(uci -q get "network.$n.disabled")" = "1" ] && continue
		# NOTE: no IP filter - keep every uplink visible even without an address, so
		# a modem that briefly drops its IP while re-dialing after a switch does not
		# vanish from the bar (which used to leave only Wi-Fi looking "selected").
		ip=$(iface_ip "$n")
		t=$(iface_type "$n")
		[ "$t" = modem ] && [ -z "$(operator_cached "$n")" ] && NEEDREFRESH=1
		# small top line: modem model / Wi-Fi interface name / device for the rest
		# (never empty, so every button keeps the same three-line height)
		case "$t" in
			modem) sub=$(model_for "$n"); [ -n "$sub" ] || sub="$n" ;;
			wifi)  sub="$n" ;;
			*)     sub=$(ifup_state "$n" '@["l3_device"]')
			       [ -n "$sub" ] || sub=$(uci -q get "network.$n.device")
			       [ -n "$sub" ] || sub="$n" ;;
		esac
		m=$(uci -q get "network.$n.metric"); [ -n "$m" ] || m=0
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"iface":"%s","type":"%s","sub":"%s","label":"%s","ip":"%s","metric":%s}' \
			"$n" "$t" "$(json_esc "$sub")" "$(json_esc "$(label_for "$n")")" "$ip" "$m"
	done
	printf ']\n'
	# fill the operator cache in the background (bounded AT probes) for next time,
	# but at most once a minute so page polls don't pile up probes on a modem whose
	# operator can't be read.
	if [ "$NEEDREFRESH" = 1 ]; then
		stamp=/tmp/netpri_refresh
		if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +1 2>/dev/null)" ]; then
			: > "$stamp"
			( /usr/share/5gmodem/netpri.sh refresh >/dev/null 2>&1 & ) &
		fi
	fi
	;;

refresh)
	# (re)probe each modem uplink's operator name into the cache
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		[ "$(iface_type "$n")" = modem ] && operator_probe "$n"
	done
	;;

set)
	CH="$2"
	[ -n "$CH" ] || { echo '{"error":"no interface"}'; exit 1; }
	CHANGED=0
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		uci -q get "network.$n" >/dev/null 2>&1 || continue
		if [ "$n" = "$CH" ]; then NEW=1; else NEW=20; fi
		OLD=$(uci -q get "network.$n.metric")
		[ "x$OLD" = "x$NEW" ] && continue
		uci -q set "network.$n.metric=$NEW"
		CHANGED=1
	done
	[ "$CHANGED" = 1 ] || { echo '{"result":"ok","active":"'"$CH"'","changed":false}'; exit 0; }
	# Apply exactly like LuCI "Save & Apply" on an interface's gateway-metric field:
	# commit the new metrics and reload the network. netifd re-installs the default
	# routes with the new priorities; a metric-only change does not tear down the
	# link, so the internet just starts going through the chosen uplink.
	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1
	echo '{"result":"ok","active":"'"$CH"'","changed":true}'
	;;

*)
	echo '{"error":"usage: netpri.sh list|set <iface>"}'
	exit 1
	;;
esac
