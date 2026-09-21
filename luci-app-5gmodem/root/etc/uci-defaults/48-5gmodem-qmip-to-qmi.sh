#!/bin/sh

[ -f /etc/config/network ] || exit 0
chg=0
for s in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='\{0,1\}qmip'\{0,1\}$/\1/p"); do
	uci -q set "network.$s.proto=qmi"
	case "$(uci -q get "network.$s.pdptype" | tr 'A-Z' 'a-z')" in
		ipv4v6) uci -q set "network.$s.pdptype=ipv4" ;;
	esac
	logger -t 5gmodem "migration: interface $s moved from QMI+MM (qmip, withdrawn) to qmi"
	chg=1
done
if [ -f /etc/config/5gmodem ]; then
	for s in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\([^.]*\)\.iface_proto='\{0,1\}qmip'\{0,1\}$/\1/p"); do
		uci -q set "5gmodem.$s.iface_proto=qmi"
		chg=1
	done
	uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 && [ "$(uci -q get 5gmodem.@5gmodem[0].iface_proto)" = qmip ] && uci -q set 5gmodem.@5gmodem[0].iface_proto=qmi
fi
if [ "$chg" = 1 ]; then
	uci -q commit network
	uci -q commit 5gmodem
	ubus call network reload >/dev/null 2>&1
fi
exit 0
