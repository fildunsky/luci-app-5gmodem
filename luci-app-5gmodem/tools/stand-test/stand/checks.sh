#!/bin/sh
R=/usr/share/5gmodem
NONCE="${NONCE:-st$$}"

_up() { cut -d' ' -f1 /proc/uptime; }

run() {
	_n="$1"; _t="$2"; shift 2
	_o=/tmp/stand-test.$$.out
	_a=$(_up)
	( "$@" ) >"$_o" 2>&1 </dev/null &
	_p=$!
	( exec >/dev/null 2>&1; sleep "$_t"; kill "$_p"; sleep 1; kill -9 "$_p" ) </dev/null &
	_w=$!
	wait "$_p"; _rc=$?
	kill "$_w" 2>/dev/null; wait "$_w" 2>/dev/null
	_b=$(_up)
	echo "@@$NONCE BEGIN $_n $_rc $(awk -v a="$_a" -v b="$_b" 'BEGIN{printf "%.2f", b-a}')"
	cat "$_o"
	echo
	echo "@@$NONCE END $_n"
	rm -f "$_o"
}

cfg() { uci -q get "5gmodem.$1"; }

AT=$(cfg @5gmodem[0].at_port)
[ -n "$AT" ] || AT=$($R/detect.sh 2>/dev/null)
IFACE=$(cfg @5gmodem[0].network)
STORE=$(cfg sms.storage); STORE=${STORE:-ME}
RPORT=$(cfg sms.readport)
USSDCODE="${USSDCODE:-}"

run env 5 sh -c "echo at=$AT iface=$IFACE store=$STORE rport=$RPORT; cat /etc/openwrt_release | grep DESCRIPTION; apk list -I 2>/dev/null | grep luci-app-5gmodem; uptime"
run peek 15 $R/5gmodem.sh peek
run cached 40 $R/5gmodem.sh cached 20
run json 60 $R/5gmodem.sh json
run listmodems 20 $R/listmodems.sh
run detect 30 $R/detect.sh
run resolve 40 $R/modemswitch.sh resolve
run active 10 $R/modemswitch.sh active
run bands_json 40 $R/bands.sh json
run bands_mgmtinfo 30 $R/bands.sh mgmtinfo
run simslot 40 $R/simslot.sh status
run sms_status 40 $R/smsbridge.sh status "$STORE" "$RPORT"
run sms_recv 60 $R/smsbridge.sh recv "$STORE" "$RPORT"
run sms_newcount 30 $R/smsbridge.sh newcount
run at_ati 20 $R/atcmd.sh "$AT" ATI 8
run at_csq 20 $R/atcmd.sh "$AT" AT+CSQ 8
run at_foreign 20 $R/atcmd.sh /dev/ttyS0 ATI 8
run stats_list 20 $R/stats.sh list
run stats_traffic 20 $R/stats.sh traffic
run ttl_get 20 $R/ttl.sh get
run netpri_list 30 $R/netpri.sh list
run netpri_status 20 $R/netpri.sh status
run netpri_ping 30 $R/netpri.sh ping 77.88.8.8
run extip_get 30 $R/extip.sh get
run health_conf 20 $R/health.sh getconf
run ussd_support 20 $R/modemswitch.sh ussdsupport
run ussd_status 20 $R/ussd.sh status
[ -n "$USSDCODE" ] && run ussd_send 90 sh -c "$R/ussd.sh send '$USSDCODE'; i=0; while [ \$i -lt 40 ]; do s=\$($R/ussd.sh status); case \"\$s\" in *'\"status\":\"busy\"'*|*'\"status\":\"sending\"'*|*'\"status\":\"running\"'*) sleep 2; i=\$((i+1));; *) echo \"\$s\"; break;; esac; done"
run esim_status 30 $R/esim.sh status
run antenna 20 $R/antenna.sh status
run usbpower 20 $R/reboot_modem.sh hasusbpower
run sw_daemon 10 sh -c "pgrep -f 'sessionwatch.sh' >/dev/null && echo running || echo stopped; /etc/init.d/5gmodem-sessionwatch enabled && echo enabled || echo disabled"
run iface_status 10 ifstatus "$IFACE"
run procs 10 sh -c "ps w | awk '\$4 ~ /Z/ {z++} /sms_tool/ && !/awk/ {s++} END {print \"zombies=\" z+0, \"sms_tool=\" s+0}'; free | awk '/Mem/ {print \"memfree=\" \$4, \"avail=\" \$7}'; ps | wc -l"
run log_errors 10 sh -c "logread | grep -E '5gmodem|netifd|fibocom' | grep -icE 'error|fail|segfault' ; logread | grep -E 'Interface .* is now down|ifdown|modem.*restart|reboot_modem|qmi-recover|healing|heal' | tail -n 15"
