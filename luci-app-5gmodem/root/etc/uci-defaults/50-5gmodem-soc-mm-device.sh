#!/bin/sh

CHANGED=0
for sec in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.proto='modemmanager'$/\1/p"); do
	dev=$(uci -q get "network.$sec.device")
	case "$dev" in
		/sys/*.remoteproc) [ -d "$dev/remoteproc" ] || continue ;;
		*) continue ;;
	esac
	uci -q set "network.$sec.device=qcom-soc"
	CHANGED=1
done
[ "$CHANGED" = 1 ] && uci -q commit network
exit 0
