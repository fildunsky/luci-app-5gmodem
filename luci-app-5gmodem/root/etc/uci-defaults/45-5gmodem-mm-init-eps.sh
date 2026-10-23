#!/bin/sh

soc_iface() {
	case "$(uci -q get "network.$1.device")" in qcom-soc|*.remoteproc) return 0 ;; esac
	_mp=$(uci -q get "network.$1.modem_path")
	[ -n "$_mp" ] && [ -d "/sys/bus/platform/devices/$_mp/remoteproc" ]
}

CHANGED=0
for sec in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.proto='modemmanager'$/\1/p"); do
	if soc_iface "$sec"; then
		if [ "$(uci -q get "network.$sec.init_epsbearer")" = "default" ]; then
			uci -q delete "network.$sec.init_epsbearer"
			CHANGED=1
		fi
		continue
	fi
	[ "$(uci -q get "network.$sec.iptype")" = "ipv4v6" ] || continue
	[ -z "$(uci -q get "network.$sec.init_epsbearer")" ] || continue
	uci -q set "network.$sec.init_epsbearer=default"
	CHANGED=1
done
[ "$CHANGED" = 1 ] && uci -q commit network
exit 0
