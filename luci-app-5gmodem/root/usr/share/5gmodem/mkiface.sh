#!/bin/sh
#
# Create a network interface for the connected modem (best-effort).
# Detects the control protocol (ModemManager / QMI / MBIM), creates the
# uci interface, adds it to the 'wan' firewall zone, points the app at it
# and brings it up. Prints a small JSON result.
#
# Usage: mkiface.sh [name]     (default interface name: modem)
#

IF="${1:-modem}"

json() { printf '{"result":"%s","iface":"%s","proto":"%s","device":"%s"}\n' "$1" "$IF" "$2" "$3"; }

# already there? just make sure it is up
if uci -q get "network.$IF" >/dev/null 2>&1; then
	ifup "$IF" >/dev/null 2>&1
	json exists "$(uci -q get network.$IF.proto)" "$(uci -q get network.$IF.device)"
	exit 0
fi

PROTO=""; DEV=""

# 1) ModemManager-managed modem -> proto modemmanager (device = sysfs path)
if command -v mmcli >/dev/null 2>&1; then
	DEV=$(mmcli -m any -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p' | head -1)
	[ -n "$DEV" ] && PROTO="modemmanager"
fi

# 2) fallback: raw control node cdc-wdmX (QMI or MBIM)
if [ -z "$PROTO" ]; then
	for wdm in /dev/cdc-wdm*; do
		[ -c "$wdm" ] || continue
		DEV="$wdm"
		if command -v qmicli >/dev/null 2>&1 && qmicli -p -d "$wdm" --dms-get-model >/dev/null 2>&1; then
			PROTO="qmi"
		else
			PROTO="mbim"
		fi
		break
	done
fi

[ -n "$PROTO" ] || { json nomodem "" ""; exit 1; }

uci set "network.$IF=interface"
uci set "network.$IF.proto=$PROTO"
uci set "network.$IF.device=$DEV"
case "$PROTO" in
	modemmanager)
		uci set "network.$IF.apn=internet"
		uci set "network.$IF.iptype=ipv4v6"
		;;
	qmi|mbim)
		uci set "network.$IF.apn=internet"
		uci set "network.$IF.pdptype=ipv4v6"
		uci set "network.$IF.auth=none"
		;;
esac
uci commit network

# add to the 'wan' firewall zone (if one exists) so NAT/forwarding works
Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
if [ -n "$Z" ]; then
	if ! uci -q get "firewall.$Z.network" | grep -qw "$IF"; then
		uci add_list "firewall.$Z.network=$IF"
		uci commit firewall
	fi
fi

# point the app at the new interface
uci -q set "5gmodem.@5gmodem[0].network=$IF" && uci -q commit 5gmodem

ifup "$IF" >/dev/null 2>&1

json created "$PROTO" "$DEV"
exit 0
