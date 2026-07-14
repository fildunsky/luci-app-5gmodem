#!/bin/sh

#
# (c) 2023-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2023-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#


#
# from config modemdefine
#
CONFIG=modemdefine
MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [ -n "$MODEMZ" ]; then

	if [[ $MODEMZ = 0 ]]; then
    		DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
    	fi

	if [[ $MODEMZ = 1 ]]; then
    		DEVICE=$(uci -q get modemdefine.@modemdefine[0].comm_port)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi

	if [[ $MODEMZ > 1 ]]; then
		DEVICE=$(uci -q get modemdefine.@general[0].main_modem)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi
fi


getdevicepath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		echo ${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
		echo ${devpath%/*}
		;;
	esac
}

# from config (manual selection always wins)
DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
if [ -n "$DEVICE" ]; then
	echo $DEVICE
	exit 0
fi

# auto-detection can be turned off in the settings (checkbox); default on.
# When off and no manual device is set, report nothing.
AUTO=$(uci -q get 5gmodem.@5gmodem[0].auto_port)
[ "$AUTO" = "0" ] && { echo ""; exit 0; }

# Multi-modem: return the ACTIVE modem's AT port, tracked by the app's
# modemswitch/listmodems by STABLE USB path. This replaces the old
# "mmcli -m any", which read whichever modem ModemManager listed FIRST (the
# wrong one when two modems are present) and required MM to be running - but our
# modems are deliberately hidden from MM. modemswitch pins at_port and the
# resolve hotplug self-heals it across renumbering.
ACTP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
if [ -n "$ACTP" ] && [ -e "$ACTP" ]; then
	echo "$ACTP"
	exit 0
fi
# not pinned yet (fresh boot before resolve): resolve the active modem's AT port
# by probing the ttys of its USB path (time-bounded, skips DIAG ports).
AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$AMP" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
	for T in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$AMP\"].tty[*]" 2>/dev/null); do
		if /usr/share/5gmodem/atprobe.sh "$T"; then
			echo "$T"
			exit 0
		fi
	done
fi

# from temporary config
MODEMFILE=/tmp/modem
touch $MODEMFILE
DEVICE=$(cat $MODEMFILE)
if [ -n "$DEVICE" ]; then
	echo $DEVICE
	exit 0
fi

# find any device
DEVICES=$(find /dev -name "ttyUSB*" -o -name "ttyACM*" -o -name "wwan*at*" | sort -r)
# limit to devices from the modem
WAN=$(uci -q get network.wan.device)
if [ -e "$WAN" ]; then
	DEVPATH=$(getdevicepath "$WAN")
	DEVICESFOUND=""
	for DEVICE in $DEVICES; do
		T=$(getdevicepath $DEVICE)
		[ "x$T" = "x$DEVPATH" ] && DEVICESFOUND="$DEVICESFOUND $DEVICE"
	done
	DEVICES="$DEVICESFOUND"
fi

# Probe each candidate for an AT reply, time-bounded (~4s each). The old
# 'gcom check.gcom' has no timeout and blocked ~35s on a silent DIAG port, so
# auto-detection froze the page. atprobe.sh caps the wait AND rejects DIAG/NMEA
# ports (they never answer AT), so we land on a real AT port.
for DEVICE in $DEVICES; do
	if /usr/share/5gmodem/atprobe.sh "$DEVICE"; then
		echo "$DEVICE" | tee $MODEMFILE
		exit 0
	fi
done

echo ""
exit 0
