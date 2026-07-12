#!/bin/sh
#
# Enumerate the modems physically present, grouping all serial/control ports by
# the USB device (topology path) that owns them. One entry per modem. This is
# the basis for the multi-modem tabs: a modem is identified by its USB PATH
# (stable across reboots, unlike the ttyUSB numbering, and unique even for two
# identical VID:PID modems).
#
# Output: JSON array
#   [ { "path":"2-1.4", "vidpid":"05c6:90d6", "product":"VOS_5G",
#       "tty":["/dev/ttyUSB4","/dev/ttyUSB5"], "wdm":["/dev/cdc-wdm1"] }, ... ]
#

esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# usb_device sysfs node (has idVendor) that owns a given /dev char device
owner_node() {
	b=$(basename "$1")
	p=$(readlink -f "/sys/class/tty/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/usbmisc/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/net/$b/device" 2>/dev/null)
	while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -f "$p/idVendor" ]; do p="${p%/*}"; done
	[ -f "$p/idVendor" ] && echo "$p"
}

# collect the distinct owner nodes (one per modem), preserving first-seen order
NODES=""
for t in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan*; do
	[ -e "$t" ] || continue
	n=$(owner_node "$t")
	[ -n "$n" ] || continue
	case " $NODES " in *" $n "*) ;; *) NODES="$NODES $n" ;; esac
done

first=1
printf '['
for n in $NODES; do
	path=$(basename "$n")
	vid=$(cat "$n/idVendor" 2>/dev/null)
	pid=$(cat "$n/idProduct" 2>/dev/null)
	prod=$(esc "$(cat "$n/product" 2>/dev/null)")

	# ports belonging to this node
	ttys=""; wdms=""
	for t in /dev/ttyUSB* /dev/ttyACM*; do
		[ -e "$t" ] || continue
		[ "$(owner_node "$t")" = "$n" ] || continue
		ttys="$ttys${ttys:+,}\"$t\""
	done
	for t in /dev/cdc-wdm* /dev/wwan*; do
		[ -e "$t" ] || continue
		[ "$(owner_node "$t")" = "$n" ] || continue
		wdms="$wdms${wdms:+,}\"$t\""
	done

	[ "$first" = 1 ] || printf ','
	first=0
	printf '{"path":"%s","vidpid":"%s:%s","product":"%s","tty":[%s],"wdm":[%s]}' \
		"$path" "$vid" "$pid" "$prod" "$ttys" "$wdms"
done
printf ']\n'
