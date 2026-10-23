#!/bin/sh

[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null
CFG=5gmodem
NFT=/etc/nftables.d/10-5gmodem-ttl.nft

modem_iface() {
	I=$(uci -q get $CFG.@5gmodem[0].network)
	if [ -z "$I" ]; then
		for P in modemmanager qmi mbim ncm wwan; do
			I=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='$P'\$/\1/p" | head -1)
			[ -n "$I" ] && break
		done
	fi
	echo "$I"
}

l3dev() {
	ifstatus "$1" 2>/dev/null | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1
}

case "$1" in
set)
	for f in ttl4in:2 ttl4out:3 ttl6in:4 ttl6out:5; do
		k=${f%%:*}; n=${f##*:}; eval v="\$$n"
		case "$v" in ''|*[!0-9]*) uci -q delete $CFG.@5gmodem[0].$k;; *) uci set $CFG.@5gmodem[0].$k="$v";; esac
	done
	uci commit $CFG
	"$0" apply
	;;
get)
	IFACE=$(modem_iface)
	DEV=$(l3dev "$IFACE")
	DEF4=$(sysctl -n net.ipv4.ip_default_ttl 2>/dev/null); [ -n "$DEF4" ] || DEF4=64
	DEF6=$(sysctl -n net.ipv6.conf.all.hop_limit 2>/dev/null); [ -n "$DEF6" ] || DEF6=64
	HITS=$( { nft list table inet modem5g_ttl; nft list table netdev modem5g_ttl_dev; } 2>/dev/null | awk '/ttl set|hoplimit set/ {
		for (i = 1; i <= NF; i++) if ($i == "packets") { s += $(i + 1); break } } END { print s + 0 }')
	printf '{"iface":"%s","device":"%s","def4":"%s","def6":"%s","hits":"%s","ttl4in":"%s","ttl4out":"%s","ttl6in":"%s","ttl6out":"%s"}\n' \
		"$IFACE" "$DEV" "$DEF4" "$DEF6" "$HITS" \
		"$(uci -q get $CFG.@5gmodem[0].ttl4in)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl4out)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl6in)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl6out)"
	;;

apply)
	IFACE=$(modem_iface)
	DEV=$(l3dev "$IFACE")
	T4I=$(uci -q get $CFG.@5gmodem[0].ttl4in)
	T4O=$(uci -q get $CFG.@5gmodem[0].ttl4out)
	T6I=$(uci -q get $CFG.@5gmodem[0].ttl6in)
	T6O=$(uci -q get $CFG.@5gmodem[0].ttl6out)

	if [ -f "$NFT" ]; then
		rm -f "$NFT"
		fw4 reload >/dev/null 2>&1
	fi

	if [ -n "$DEV" ] && [ -n "$T4I$T4O$T6I$T6O" ]; then
		TMP="/tmp/5gmodem/ttl.$$.nft"
		{
			echo "table inet modem5g_ttl"
			echo "flush table inet modem5g_ttl"
			echo "table inet modem5g_ttl {"
			echo "	chain prerouting {"
			echo "		type filter hook prerouting priority mangle; policy accept;"
			[ -n "$T4I" ] && echo "		iifname \"$DEV\" counter ip ttl set $T4I"
			[ -n "$T6I" ] && echo "		iifname \"$DEV\" meta l4proto != ipv6-icmp counter ip6 hoplimit set $T6I"
			echo "	}"
			echo "	chain postrouting {"
			echo "		type filter hook postrouting priority mangle; policy accept;"
			[ -n "$T4O" ] && echo "		oifname \"$DEV\" counter ip ttl set $T4O"
			[ -n "$T6O" ] && echo "		oifname \"$DEV\" meta l4proto != ipv6-icmp counter ip6 hoplimit set $T6O"
			echo "	}"
			echo "}"
		} > "$TMP"
		if ! nft -f "$TMP" 2>/dev/null; then
			logger -t 5gmodem "ttl: nft rejected the rules (check: nft -c -f $TMP)"
			echo "FAIL"
			exit 1
		fi
		rm -f "$TMP"

		TMPD="/tmp/5gmodem/ttl_dev.$$.nft"
		{
			echo "table netdev modem5g_ttl_dev"
			echo "delete table netdev modem5g_ttl_dev"
			echo "table netdev modem5g_ttl_dev {"
			if [ -n "$T4I$T6I" ]; then
				echo "	chain ingress {"
				echo "		type filter hook ingress device \"$DEV\" priority -300; policy accept;"
				[ -n "$T4I" ] && echo "		meta protocol ip counter ip ttl set $T4I"
				[ -n "$T6I" ] && echo "		meta protocol ip6 meta l4proto != ipv6-icmp counter ip6 hoplimit set $T6I"
				echo "	}"
			fi
			if [ -n "$T4O$T6O" ]; then
				echo "	chain egress {"
				echo "		type filter hook egress device \"$DEV\" priority 0; policy accept;"
				[ -n "$T4O" ] && echo "		meta protocol ip counter ip ttl set $T4O"
				[ -n "$T6O" ] && echo "		meta protocol ip6 meta l4proto != ipv6-icmp counter ip6 hoplimit set $T6O"
				echo "	}"
			fi
			echo "}"
		} > "$TMPD"
		if ! nft -f "$TMPD" 2>/dev/null; then
			nft delete table netdev modem5g_ttl_dev 2>/dev/null
			[ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ] && \
				logger -t 5gmodem "ttl: no netdev egress hook in this kernel - with flow offloading on, accelerated connections keep the original TTL; turn offloading off in Network > Firewall"
		fi
		rm -f "$TMPD"
	else
		nft delete table inet modem5g_ttl 2>/dev/null
		nft delete table netdev modem5g_ttl_dev 2>/dev/null
	fi
	echo "OK"
	;;

*)
	echo "usage: $0 apply|get|set <ttl4in> <ttl4out> <ttl6in> <ttl6out>" >&2
	exit 1
	;;
esac
