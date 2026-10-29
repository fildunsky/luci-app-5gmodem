#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

driver_for() {
	case "$1:$2" in
		05c6:9025) echo "option1" ;;
		05c6:9091|05c6:90b4) echo "option1" ;;
		03f0:9d1d) echo "option1" ;;
		413c:81d8|1bc7:1911) echo "option1" ;;
		2c7c:6004|1bbb:0196) echo "option1" ;;
		2cb7:0110|19d2:0581|19d2:0536) echo "option1" ;;
		*)         echo "generic" ;;
	esac
}

newid_for() {
	case "$1:$2" in
		05c6:9091|05c6:90b4) echo "$1 $2 ff" ;;
		413c:81d8|1bc7:1911) echo "$1 $2 ff" ;;
		2c7c:6004|1bbb:0196|2cb7:0110|19d2:0581|19d2:0536) echo "$1 $2 ff" ;;
		*)         echo "$1 $2" ;;
	esac
}

data_iface_for() {
	case "$1:$2" in
		05c6:9025) echo 4 ;;
		05c6:9091) echo 2 ;;
		03f0:9d1d) echo 1 ;;
		*)         echo "" ;;
	esac
}

_has_adb_iface() {
	case "$1:$2" in
		05c6:9025|05c6:9091|05c6:90b4|05c6:90d5|1bbb:0196|2cb7:0110|19d2:0581|19d2:0536) return 0 ;;
		*)                   return 1 ;;
	esac
}

_rescue_data() {
	_rd_n=$(data_iface_for "$1" "$2")
	[ -n "$_rd_n" ] && _rescue_rmnet "$1" "$2" "$_rd_n"
	_has_adb_iface "$1" "$2" && _release_adb "$1" "$2"
	return 0
}

_rescue_rmnet() {
	for _rr_d in /sys/bus/usb/devices/*; do
		[ -f "$_rr_d/idVendor" ] || continue
		[ "$(cat "$_rr_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_rr_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _rr_i in "$_rr_d":*."$3"; do
			[ -f "$_rr_i/bInterfaceNumber" ] || continue
			_rr_drv=$(basename "$(readlink -f "$_rr_i/driver" 2>/dev/null)" 2>/dev/null)
			case "$_rr_drv" in
				option|option1|usb_serial_generic|usbserial_generic|generic)
					_rr_if=$(basename "$_rr_i")
					echo "$_rr_if" > "$_rr_i/driver/unbind" 2>/dev/null
					_rr_ok=0
					for _rr_nat in qmi_wwan qmi_wwan_q qmi_wwan_f qmi_wwan_s cdc_mbim cdc_ncm cdc_ether rndis_host; do
						[ -d "/sys/bus/usb/drivers/$_rr_nat" ] || continue
						echo "$_rr_if" > "/sys/bus/usb/drivers/$_rr_nat/bind" 2>/dev/null || continue
						[ -e "$_rr_i/driver" ] || continue
						_rr_ok=1
						logger -t 5gmodem-usbports "rescued data interface $_rr_if from $_rr_drv (bound to $_rr_nat)"
						break
					done
					if [ "$_rr_ok" = 0 ]; then
						echo "$_rr_if" > /sys/bus/usb/drivers_probe 2>/dev/null
						logger -t 5gmodem-usbports "rescued data interface $_rr_if from $_rr_drv (returned to its native driver)"
					fi
					;;
			esac
		done
	done
}

_release_adb() {
	for _ra_d in /sys/bus/usb/devices/*; do
		[ -f "$_ra_d/idVendor" ] || continue
		[ "$(cat "$_ra_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_ra_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _ra_i in "$_ra_d":*; do
			[ -f "$_ra_i/bInterfaceSubClass" ] || continue
			[ "$(cat "$_ra_i/bInterfaceSubClass" 2>/dev/null)" = "42" ] || continue
			[ "$(cat "$_ra_i/bInterfaceClass" 2>/dev/null)" = "ff" ] || continue
			[ "$(cat "$_ra_i/bInterfaceProtocol" 2>/dev/null)" = "01" ] || continue
			_ra_drv=$(basename "$(readlink -f "$_ra_i/driver" 2>/dev/null)" 2>/dev/null)
			case "$_ra_drv" in
				option|option1|usb_serial_generic|usbserial_generic|generic)
					_ra_if=$(basename "$_ra_i")
					echo "$_ra_if" > "$_ra_i/driver/unbind" 2>/dev/null
					logger -t 5gmodem-usbports "released ADB interface $_ra_if from $_ra_drv (it is not a serial port)"
					;;
			esac
		done
	done
}

bind_ports() {
	[ -n "$1" ] && [ -n "$2" ] || return 1

	_rescue_data "$1" "$2"

	_bp_haswdm=0
	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_w in "$_bp_d":*/usbmisc/cdc-wdm* "$_bp_d":*/net/*; do
			[ -e "$_bp_w" ] || continue
			_bp_haswdm=1
			break
		done
	done

	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_t in "$_bp_d":*/ttyUSB* "$_bp_d":*/tty/ttyUSB*; do
			[ -e "$_bp_t" ] || continue
			_bp_once="/tmp/5gmodem/usbports_${_bp_d##*/}.hasports"
			if [ ! -f "$_bp_once" ]; then
				: > "$_bp_once" 2>/dev/null
				logger -t 5gmodem-usbports "$1:$2 already has ports - leaving the binding alone"
			fi
			return 0
		done
	done

	_bp_drv=$(driver_for "$1" "$2")
	_bp_path="/sys/bus/usb-serial/drivers/$_bp_drv/new_id"
	if [ ! -w "$_bp_path" ] && [ "$_bp_drv" != "generic" ]; then
		logger -t 5gmodem-usbports "no $_bp_drv driver for $1:$2 ($_bp_path missing) - falling back to generic"
		_bp_drv="generic"
		_bp_path="/sys/bus/usb-serial/drivers/$_bp_drv/new_id"
	fi
	if [ ! -w "$_bp_path" ]; then
		logger -t 5gmodem-usbports "no $_bp_drv driver for $1:$2 ($_bp_path missing)"
		return 1
	fi
	if ! echo "$(newid_for "$1" "$2")" > "$_bp_path" 2>/dev/null; then
		logger -t 5gmodem-usbports "new_id write failed for $1:$2 via $_bp_drv (kernel rejected '$(newid_for "$1" "$2")')"
		return 1
	fi
	logger -t 5gmodem-usbports "bound $1:$2 via $_bp_drv"
	if [ -n "$(data_iface_for "$1" "$2")" ]; then
		sleep 1
		_rescue_data "$1" "$2"
	fi
	if [ "$1:$2" = "1bbb:0196" ] || [ "$1:$2" = "2cb7:0110" ] || [ "$1:$2" = "19d2:0581" ] || [ "$1:$2" = "19d2:0536" ]; then
		sleep 1
		_release_adb "$1" "$2"
	fi

	[ "$_bp_haswdm" = 1 ] || return 0
	sleep 2
	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_i in "$_bp_d":*; do
			[ -f "$_bp_i/bInterfaceClass" ] || continue
			_bp_cls=$(cat "$_bp_i/bInterfaceClass" 2>/dev/null)
			[ "$_bp_cls" = "ff" ] && continue
			_bp_idrv=$(basename "$(readlink -f "$_bp_i/driver" 2>/dev/null)" 2>/dev/null)
			case "$_bp_idrv" in
				option|option1|"usb_serial_generic"|usbserial_generic|generic)
					_bp_if=$(basename "$_bp_i")
					echo "$_bp_if" > "$_bp_i/driver/unbind" 2>/dev/null
					echo "$_bp_if" > /sys/bus/usb/drivers_probe 2>/dev/null
					logger -t 5gmodem-usbports "returned interface $_bp_if (class $_bp_cls) to its native driver"
					;;
			esac
		done
	done
}

pick_config() {
	[ -f "$1/bConfigurationValue" ] || return 0
	_pc_now=$(cat "$1/bConfigurationValue" 2>/dev/null)
	[ "$_pc_now" = "$2" ] && return 0
	_pc_num=$(cat "$1/bNumConfigurations" 2>/dev/null)
	case "$_pc_num" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_pc_num" -ge "$2" ] || return 0
	echo "$2" > "$1/bConfigurationValue" 2>/dev/null \
		&& logger -t 5gmodem "usb: $(basename "$1") switched to configuration $2 (was $_pc_now)"
}

coldplug() {
	for _cp_d in /sys/bus/usb/devices/*; do
		[ -f "$_cp_d/idVendor" ] || continue
		_cp_v=$(cat "$_cp_d/idVendor" 2>/dev/null)
		_cp_p=$(cat "$_cp_d/idProduct" 2>/dev/null)
		case "$_cp_v:$_cp_p" in
			413c:81e1|413c:81d6|1199:9070) _cp_fb=1 ;;
			*) _cp_fb=0
			   [ "$(cat "$_cp_d/bDeviceClass" 2>/dev/null)" != "09" ] \
			   && [ "$(tr -d ' ' < "$_cp_d/bNumInterfaces" 2>/dev/null)" = "1" ] && _cp_fb=1 ;;
		esac
		[ "$_cp_fb" = 1 ] && [ -f /etc/hotplug.d/usb/62-5gmodem-fastboot-rescue ] && \
			ACTION=add DEVTYPE=usb_device DEVPATH="$(readlink -f "$_cp_d" | sed 's#^/sys##')" \
				sh /etc/hotplug.d/usb/62-5gmodem-fastboot-rescue >/dev/null 2>&1 </dev/null
		case "$_cp_v:$_cp_p" in
			05c6:9025|05c6:90d5|05c6:90d6|05c6:9091|05c6:90b4) bind_ports "$_cp_v" "$_cp_p" ;;
			413c:81d8|1bc7:1911|2c7c:6004|1bbb:0196|2cb7:0110|19d2:0581|19d2:0536) bind_ports "$_cp_v" "$_cp_p" ;;
			05c6:9063) pick_config "$_cp_d" 3 ;;
			03f0:9d1d) pick_config "$_cp_d" 1; sleep 2; bind_ports "$_cp_v" "$_cp_p" ;;
		esac
	done
}

case "$1" in
	bind)     bind_ports "$2" "$3" ;;
	driver)   driver_for "$2" "$3" ;;
	dataif)   data_iface_for "$2" "$3" ;;
	coldplug) coldplug ;;
	rescue)
		if [ -n "$2" ] && [ -n "$3" ]; then
			_rescue_data "$2" "$3"
		else
			for _r_d in /sys/bus/usb/devices/*; do
				[ -f "$_r_d/idVendor" ] || continue
				_rescue_data "$(cat "$_r_d/idVendor" 2>/dev/null)" \
					"$(cat "$_r_d/idProduct" 2>/dev/null)"
			done
		fi ;;
esac
