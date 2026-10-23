#!/bin/sh

RES=/usr/share/5gmodem
[ -r "$RES/atlock.sh" ] && . "$RES/atlock.sh"
[ -r "$RES/lib.sh" ] && . "$RES/lib.sh"
. "$RES/noatports.sh"

_pm_imei() {
	command -v at_lock >/dev/null 2>&1 && { at_lock "$1" 5 2>/dev/null || return 1; }
	_pm_i=$(at_query "$1" "AT+CGSN" 6 \
		| grep -xE '[0-9]{14,16}' | head -1)
	command -v at_unlock >/dev/null 2>&1 && at_unlock 2>/dev/null
	[ -n "$_pm_i" ] || return 1
	printf '%s' "$_pm_i"
}

_pm_seen=""
_pm_dupes=""

for _pm_d in /sys/bus/usb/devices/*; do
	case "$_pm_d" in *:*) continue ;; esac
	[ -f "$_pm_d/idVendor" ] || continue
	_pm_path=$(basename "$_pm_d")
	case "$_pm_path" in usb*) continue ;; esac
	_pm_vid=$(cat "$_pm_d/idVendor" 2>/dev/null)
	_pm_pid=$(cat "$_pm_d/idProduct" 2>/dev/null)

	_pm_ttys=""
	for _pm_if in "$_pm_d"/*:*; do
		[ -d "$_pm_if" ] || continue
		for _pm_t in "$_pm_if"/ttyUSB* "$_pm_if"/tty/ttyUSB* "$_pm_if"/ttyACM* "$_pm_if"/tty/ttyACM*; do
			[ -e "$_pm_t" ] && _pm_ttys="$_pm_ttys $(basename "$_pm_t")"
		done
	done
	_pm_wdm=""
	for _pm_w in "$_pm_d"/*:*/usbmisc/cdc-wdm* "$_pm_d"/*:*/usbmisc/wdm*; do
		[ -e "$_pm_w" ] && _pm_wdm="$_pm_wdm $(basename "$_pm_w")"
	done
	_pm_net=""
	for _pm_n in "$_pm_d"/*:*/net/*; do
		[ -e "$_pm_n" ] && _pm_net="$_pm_net $(basename "$_pm_n")"
	done
	[ -n "$_pm_ttys$_pm_wdm$_pm_net" ] || continue

	echo "### $_pm_path  [$_pm_vid:$_pm_pid]  serial=$(cat "$_pm_d/serial" 2>/dev/null || echo '-')"
	echo "    product: $(cat "$_pm_d/product" 2>/dev/null || echo '-')"
	echo "    ports:  ${_pm_ttys:- none}"
	echo "    cdc-wdm:${_pm_wdm:- none}    net:${_pm_net:- none}"

	_pm_imei_dev=""
	_pm_tried=0
	for _pm_t in $_pm_ttys; do
		tty_no_at "$_pm_t" && continue
		[ "$_pm_tried" -ge 2 ] && break
		_pm_tried=$((_pm_tried + 1))
		_pm_r=$(_pm_imei "/dev/$_pm_t") || continue
		_pm_imei_dev="$_pm_r"
		echo "    IMEI:   $_pm_r  (read from /dev/$_pm_t)"
		break
	done
	if [ -z "$_pm_imei_dev" ]; then
		if [ -n "$_pm_ttys" ]; then
			echo "    IMEI:   no port answered AT+CGSN"
		else
			echo "    IMEI:   no AT ports (HiLink, or a composition without them)"
		fi
		continue
	fi

	for _pm_e in $_pm_seen; do
		case "$_pm_e" in
			"$_pm_imei_dev":*)
				_pm_other=${_pm_e#*:}
				_pm_dupes="$_pm_dupes$_pm_imei_dev ($_pm_other and $_pm_path)
"
				;;
		esac
	done
	_pm_seen="$_pm_seen $_pm_imei_dev:$_pm_path"
done

echo ""
if [ -n "$_pm_dupes" ]; then
	echo "!!! THE SAME IMEI ON DIFFERENT DEVICES:"
	printf '%s' "$_pm_dupes" | sed 's/^/    /'
	echo "    The devices differ by the USB serial above, so these are"
	echo "    physically DIFFERENT modules sharing one IMEI (cloned, or never"
	echo "    flashed). The app survives this, but interface ownership and"
	echo "    profiles are then decided by USB path, not by IMEI."
else
	echo "Every polled device has its own IMEI - no duplicates."
fi
exit 0
