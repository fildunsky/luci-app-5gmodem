#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

netonly_active() {
	[ "$(uci -q get 5gmodem.@5gmodem[0].netonly)" = "1" ]
}

NETONLY_SVCS="5gmodem-mm-inhibit 5gmodem-usbports 5gmodem-leds 5gmodem-sms-notify"

[ "${0##*/}" = netonly.sh ] || return 0 2>/dev/null

case "$1" in
	state)
		if netonly_active; then echo 1; else echo 0; fi
		;;
	apply)
		if netonly_active; then _no_new=1; else _no_new=0; fi
		_no_old=$(cat /tmp/5gmodem/netonly.state 2>/dev/null)
		[ "$_no_new" = "$_no_old" ] && exit 0
		printf '%s\n' "$_no_new" > /tmp/5gmodem/netonly.state
		for _no_s in $NETONLY_SVCS; do
			[ -x "/etc/init.d/$_no_s" ] || continue
			if [ "$_no_new" = 1 ]; then
				"/etc/init.d/$_no_s" stop >/dev/null 2>&1
			elif "/etc/init.d/$_no_s" enabled 2>/dev/null; then
				"/etc/init.d/$_no_s" start >/dev/null 2>&1
			fi
		done
		[ -x /etc/init.d/5gmodem-sessionwatch ] && /etc/init.d/5gmodem-sessionwatch restart >/dev/null 2>&1
		if [ "$_no_new" = 1 ]; then
			logger -t 5gmodem "network-only mode: modem services are off, uplink priorities and the watchdog keep running"
		else
			logger -t 5gmodem "network-only mode is off: modem services are back"
		fi
		;;
esac
