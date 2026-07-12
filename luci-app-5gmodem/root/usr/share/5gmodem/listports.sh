#!/bin/sh
#
# List modem serial / control ports with the USB device that owns each one
# (vid:pid, product name, USB topology path). The UI uses this to LABEL the
# AT-port drop-downs so it is clear which /dev/ttyUSB* belongs to which modem
# when several modems are connected at once.
#
# Output: a JSON object  { "<port>": {"vidpid","product","path"}, ... }
#

esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

first=1
printf '{'
for t in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan*; do
	[ -e "$t" ] || continue
	b=$(basename "$t")
	# walk up from the char device to the usb_device node (has idVendor)
	p=$(readlink -f "/sys/class/tty/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/usbmisc/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/net/$b/device" 2>/dev/null)
	while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -f "$p/idVendor" ]; do p="${p%/*}"; done
	[ -f "$p/idVendor" ] || continue
	vid=$(cat "$p/idVendor" 2>/dev/null)
	pid=$(cat "$p/idProduct" 2>/dev/null)
	prod=$(esc "$(cat "$p/product" 2>/dev/null)")
	path=$(basename "$p" 2>/dev/null)
	[ "$first" = 1 ] || printf ','
	first=0
	printf '"%s":{"vidpid":"%s:%s","product":"%s","path":"%s"}' "$t" "$vid" "$pid" "$prod" "$path"
done
printf '}\n'
