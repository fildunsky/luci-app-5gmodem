#!/bin/sh
DUR="${DUR:-600}"
STEP="${STEP:-30}"
IFACE="${IFACE:-$(uci -q get 5gmodem.@5gmodem[0].network)}"

sample() {
	_up=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.uptime' 2>/dev/null)
	_isup=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)
	_av=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
	_pr=$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)
	_zo=$(grep -l '^State:.*Z' /proc/[0-9]*/status 2>/dev/null | wc -l)
	_st=$(pgrep -f 'sms_tool' 2>/dev/null | wc -l)
	_old=0
	for _p in $(pgrep -f 'sms_tool' 2>/dev/null); do
		_s=$(awk '{print $22}' "/proc/$_p/stat" 2>/dev/null)
		[ -n "$_s" ] || continue
		_age=$(( $(cut -d. -f1 /proc/uptime) - _s / 100 ))
		[ "$_age" -gt 60 ] && _old=$((_old + 1))
	done
	_rp=$(for _p in $(pidof rpcd); do awk '/VmRSS/ {print $2}' /proc/$_p/status; done | awk '{s+=$1} END {print s+0}')
	_tf=$(ls /tmp/5gmodem/st.* /tmp/stand-test.* 2>/dev/null | wc -l)
	_tmp=$(df /tmp | awk 'NR==2 {print $3}')
	_ld=$(cut -d' ' -f1 /proc/loadavg)
	echo "S t=$(cut -d. -f1 /proc/uptime) up=$_isup ifup=$_up memavail=$_av procs=$_pr zombies=$_zo sms_tool=$_st sms_tool_old=$_old rpcd_rss=$_rp tmpfiles=$_tf tmpused=$_tmp load=$_ld"
}

MK="stand-test-mark-$$-$(cut -d. -f1 /proc/uptime)"; logger -t stand-test "$MK"
end=$(( $(cut -d. -f1 /proc/uptime) + DUR ))
sample
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
	sleep "$STEP"
	sample
done
logread | sed -n "/$MK/,\$p" | grep -E "5gmodem|netifd|fibocom|kernel.*usb" | grep -vE "stand-test" > /tmp/stand-test.soaklog
echo "L downs=$(grep -c 'is now down' /tmp/stand-test.soaklog) heal=$(grep -ciE 'heal|reboot_modem|qmi-recover|CFUN' /tmp/stand-test.soaklog) usbdisc=$(grep -c 'USB disconnect' /tmp/stand-test.soaklog) lines=$(wc -l < /tmp/stand-test.soaklog)"
sed 's/^/G /' /tmp/stand-test.soaklog | tail -n 40
rm -f /tmp/stand-test.soaklog
