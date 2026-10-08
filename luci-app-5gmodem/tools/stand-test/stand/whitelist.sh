#!/bin/sh
T=wltest
R=/usr/share/5gmodem
IFACE="${IFACE:-$(uci -q get 5gmodem.@5gmodem[0].network)}"
DEV="${DEV:-$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)}"
HOSTS="${HOSTS:-ya.ru yandex.ru ozon.ru max.ru}"
now() { cut -d. -f1 /proc/uptime; }
res() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

resolve4() {
	for _h in $HOSTS; do
		nslookup "$_h" 2>/dev/null | awk '/^Address/ && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $NF}' | grep -vE '^(127\.|192\.168\.|10\.|77\.88\.8\.8$)'
	done | sort -u | tr '\n' ',' | sed 's/,$//'
}

rollback_armed() { kill -0 "$(cat /tmp/wltest.rollback.pid 2>/dev/null)" 2>/dev/null; }

arm() {
	_mode="$1"; _secs="$2"
	[ -n "$DEV" ] || { res FAIL wl.arm 0 "no l3 device for $IFACE"; exit 1; }
	nft list table inet $T >/dev/null 2>&1 && { res FAIL wl.arm 0 "table $T already exists"; exit 1; }
	_ips=$(resolve4)
	[ -n "$_ips" ] || { res FAIL wl.arm 0 "could not resolve whitelist hosts"; exit 1; }
	setsid sh -c "sleep $_secs; nft delete table inet $T 2>/dev/null; logger -t stand-test 'wltest rollback fired'" </dev/null >/dev/null 2>&1 &
	echo $! > /tmp/wltest.rollback.pid
	sleep 1
	kill -0 "$(cat /tmp/wltest.rollback.pid)" 2>/dev/null || { res FAIL wl.arm 0 "rollback timer did not start - not arming"; exit 1; }
	case "$_mode" in
		open) _web="ip daddr @wlset accept"; _dns="ip daddr 77.88.8.8 accept" ;;
		tcp) _web="ip daddr @wlset tcp dport { 80, 443 } accept"; _dns="ip daddr 77.88.8.8 tcp dport { 53, 80, 443 } accept" ;;
		dnsonly) _web="ip daddr @wlset tcp dport { 80, 443 } accept"; _dns="" ;;
		block) _web=""; _dns="" ;;
		*) res FAIL wl.arm 0 "unknown mode $_mode"; exit 1 ;;
	esac
	nft -f - <<EOF || { kill "$(cat /tmp/wltest.rollback.pid)" 2>/dev/null; res FAIL wl.arm 0 "nft load failed"; exit 1; }
table inet $T {
	set wlset { type ipv4_addr; elements = { $_ips } }
	chain wl_out {
		type filter hook output priority -5; policy accept;
		oifname "$DEV" jump wl_gate
	}
	chain wl_fwd {
		type filter hook forward priority -5; policy accept;
		oifname "$DEV" jump wl_gate
	}
	chain wl_gate {
		udp dport 53 accept
		tcp dport 53 accept
		$_web
		$_dns
		counter drop
	}
}
EOF
	logger -t stand-test "wltest armed mode=$_mode dev=$DEV rollback=${_secs}s"
	res INFO wl.arm 0 "mode=$_mode dev=$DEV wl=[$_ips] rollback in ${_secs}s pid=$(cat /tmp/wltest.rollback.pid)"
}

disarm() {
	nft delete table inet $T 2>/dev/null
	kill "$(cat /tmp/wltest.rollback.pid 2>/dev/null)" 2>/dev/null
	rm -f /tmp/wltest.rollback.pid
	logger -t stand-test "wltest disarmed"
	nft list table inet $T >/dev/null 2>&1 && res FAIL wl.disarm 0 "table still present" || res PASS wl.disarm 0 "table removed"
}

selftest() {
	nft add table inet ${T}probe || { res FAIL wl.rollback-selftest 0 "nft add failed"; return 1; }
	setsid sh -c "sleep 4; nft delete table inet ${T}probe" </dev/null >/dev/null 2>&1 &
	sleep 7
	if nft list table inet ${T}probe >/dev/null 2>&1; then
		nft delete table inet ${T}probe
		res FAIL wl.rollback-selftest 7 "detached rollback did not fire"; return 1
	fi
	res PASS wl.rollback-selftest 7 "detached rollback fired"
}

probe() {
	_p=0; ping -I "$DEV" -c 1 -W 2 77.88.8.8 >/dev/null 2>&1 && _p=1
	_p2=0; ping -I "$DEV" -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && _p2=1
	_c=$(curl -s -o /dev/null -m 4 --interface "$DEV" -w '%{http_code}' https://ya.ru/ 2>/dev/null)
	_c2=$(curl -s -o /dev/null -m 4 --interface "$DEV" -w '%{http_code}' https://www.google.com/ 2>/dev/null)
	_d=0; nslookup ya.ru "$(ifstatus "$IFACE" | jsonfilter -e '@["dns-server"][0]')" >/dev/null 2>&1 && _d=1
	echo "ping77=$_p ping1111=$_p2 https_ya=$_c https_google=$_c2 dns_modem=$_d"
}

observe() {
	_dur="$1"; _step="${2:-30}"
	_mk="stand-test-mark-$$-$(now)"; logger -t stand-test "$_mk"
	_u0=$(ifstatus "$IFACE" | jsonfilter -e '@.uptime')
	_end=$(( $(now) + _dur ))
	while :; do
		_st=$(cat "/tmp/5gmodem/health/$IFACE" 2>/dev/null)
		_up=$(ifstatus "$IFACE" | jsonfilter -e '@.uptime')
		_m=$(ip -4 route show default dev "$DEV" 2>/dev/null | sed -n 's/.*metric \([0-9]*\).*/\1/p' | head -n 1)
		_dns=$(grep -c "Interface $IFACE" /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
		_cnt=$(nft list chain inet $T wl_gate 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\).*/\1/p')
		echo "O t=$(now) health=[$_st] ifup=$_up metric=$_m dns_listed=$_dns dropped=${_cnt:--} $(probe)"
		[ "$(now)" -ge "$_end" ] && break
		sleep "$_step"
	done
	logread | sed -n "/$_mk/,\$p" | grep -E "5gmodem|netifd|stand-test|fibocom" > /tmp/wltest.log
	_downs=$(grep -c "Interface '$IFACE' is now down" /tmp/wltest.log)
	_heal=$(grep -ciE "heal|reboot_modem|CFUN|usbpower|ifdown" /tmp/wltest.log)
	_fo=$(grep -ciE "failover|penalt|demot" /tmp/wltest.log)
	_u1=$(ifstatus "$IFACE" | jsonfilter -e '@.uptime')
	echo "L downs=$_downs heal_lines=$_heal failover_lines=$_fo ifup_start=$_u0 ifup_end=$_u1"
	sed 's/^/G /' /tmp/wltest.log | grep -vE "stand-test: wltest" | tail -n 60
	rm -f /tmp/wltest.log
}

case "$1" in
	arm) arm "$2" "${3:-900}" ;;
	disarm) disarm ;;
	selftest) selftest ;;
	probe) echo "P $(probe)" ;;
	observe) observe "${2:-600}" "${3:-30}" ;;
	status) nft list table inet $T 2>/dev/null | head -n 30; rollback_armed && echo armed || echo "no rollback" ;;
esac
