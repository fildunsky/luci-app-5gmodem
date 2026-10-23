#!/bin/sh

[ -r /usr/share/5gmodem/notmodem.sh ] && . /usr/share/5gmodem/notmodem.sh

esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

first=1
printf '{'
for t in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan*; do
	[ -e "$t" ] || continue
	b=$(basename "$t")
	p=$(readlink -f "/sys/class/tty/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/usbmisc/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/net/$b/device" 2>/dev/null)
	while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -f "$p/idVendor" ]; do p="${p%/*}"; done
	[ -f "$p/idVendor" ] || continue
	vid=$(cat "$p/idVendor" 2>/dev/null)
	pid=$(cat "$p/idProduct" 2>/dev/null)
	command -v usb_is_modem >/dev/null 2>&1 && ! usb_is_modem "$p" && continue
	prod=$(esc "$(cat "$p/product" 2>/dev/null)")
	path=$(basename "$p" 2>/dev/null)
	[ "$first" = 1 ] || printf ','
	first=0
	printf '"%s":{"vidpid":"%s:%s","product":"%s","path":"%s"}' "$t" "$vid" "$pid" "$prod" "$path"
done
printf '}\n'
