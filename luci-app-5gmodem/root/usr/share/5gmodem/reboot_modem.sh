#!/bin/sh
#
# Reboot the modem with AT+CFUN=1,1 and help ModemManager re-detect it.
#
# On MM-managed modems the reset triggers a full USB re-enumeration; MM
# probes the AT port immediately, but the modem is still booting and does
# not answer AT in time, so MM gives up ("Failed to find primary AT port")
# and never retries. We wait until the modem is back and AT-ready, then
# restart ModemManager so it re-probes cleanly.
#
# Usage: reboot_modem.sh [at_port]
#

PORT="$1"
[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

# fire the reset (the port drops right after)
sms_tool -d "$PORT" at "AT+CFUN=1,1" >/dev/null 2>&1

# background recovery: wait for the modem to come back AT-ready, then nudge MM
(
	# 1) wait for the port to disappear (disconnect), up to 30s
	i=0
	while [ $i -lt 30 ]; do
		[ -e "$PORT" ] || break
		sleep 1; i=$((i + 1))
	done

	# 2) wait for any ttyUSB port to answer AT again (re-enumeration may
	#    change the number), up to 150s
	i=0; ready=""
	while [ $i -lt 150 ]; do
		for p in /dev/ttyUSB*; do
			[ -e "$p" ] || continue
			if sms_tool -d "$p" at "AT" >/dev/null 2>&1; then ready="$p"; break; fi
		done
		[ -n "$ready" ] && break
		sleep 3; i=$((i + 3))
	done

	# 3) if MM still has no modem, restart it so it re-probes the (now ready) modem
	if [ -n "$ready" ]; then
		if ! mmcli -L 2>/dev/null | grep -q "/Modem/"; then
			/etc/init.d/modemmanager restart >/dev/null 2>&1
			sleep 20
		fi
		# 4) bring the data interface back up (MM comes back "disabled")
		IF=$(uci -q get 5gmodem.@5gmodem[0].network)
		[ -n "$IF" ] || IF=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='modemmanager'\$/\1/p" | head -1)
		[ -n "$IF" ] && ifup "$IF" >/dev/null 2>&1
	fi
) >/dev/null 2>&1 &

echo '{"success":true}'
exit 0
