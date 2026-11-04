#!/bin/sh

for _pb_fd in $(ls /proc/self/fd 2>/dev/null); do
	[ "$_pb_fd" -gt 2 ] 2>/dev/null && eval "exec $_pb_fd>&-"
done
exec </dev/null >/dev/null 2>&1

RES=/usr/share/5gmodem
LOG=/tmp/5gmodem/postinst.log
mkdir -p /tmp/5gmodem 2>/dev/null
: > "$LOG" 2>/dev/null

_pb_t0=$(cut -d. -f1 /proc/uptime)
_pb_step() {
	printf '%s +%ss %s\n' "$(date '+%F %T')" "$(( $(cut -d. -f1 /proc/uptime) - _pb_t0 ))" "$1" >> "$LOG" 2>/dev/null
	return 0
}

_pb_upgrade=0
[ -n "$(uci -q get 5gmodem.@5gmodem[0].widgets_seeded 2>/dev/null)" ] && _pb_upgrade=1

_pb_svc() {
	[ -x "/etc/init.d/$1" ] || return 0
	if [ ! -e "/etc/5gmodem/.svc/$1" ]; then
		mkdir -p /etc/5gmodem/.svc 2>/dev/null
		: > "/etc/5gmodem/.svc/$1" 2>/dev/null
		[ "$_pb_upgrade" = 1 ] || "/etc/init.d/$1" enable
	fi
	if "/etc/init.d/$1" enabled; then
		"/etc/init.d/$1" "$2"
	else
		"/etc/init.d/$1" stop
	fi
	return 0
}

_pb_step services
_pb_svc 5gmodem-mm-inhibit restart
_pb_svc 5gmodem-usbports start
_pb_svc 5gmodem-sessionwatch restart
_pb_svc 5gmodem-btnleds start

_pb_step system
modprobe rndis_host
modprobe cdc_ether
"$RES/usbmode-fix.sh"
sh /etc/uci-defaults/5gmodem-rebind-allow.sh
sh /etc/uci-defaults/5gmodem-ttl-migrate.sh

_pb_step network
ubus call network reload

_pb_step modems
"$RES/modemswitch.sh" resolve
_pb_step ports
"$RES/ensureports.sh"
_pb_step autosetup
"$RES/modemswitch.sh" autosetup

_pb_step protos
"$RES/register_proto.sh"

_pb_step leds
if [ "$(uci -q get 5gmodem.@5gmodem[0].signal_leds)" != "0" ]; then
	/etc/init.d/5gmodem-leds enable
	/etc/init.d/5gmodem-leds restart
fi
if "$RES/antenna.sh" detect | grep -q '"available":1'; then
	/etc/init.d/5gmodem-antenna enable
	/etc/init.d/5gmodem-antenna restart
fi

_pb_step done
exit 0
