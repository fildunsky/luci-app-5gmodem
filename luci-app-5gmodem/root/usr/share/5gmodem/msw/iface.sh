apply_mm_state() {
	command -v mmcli >/dev/null 2>&1 || return 0
	_ams_net=$(uci show network 2>/dev/null)
	if printf '%s' "$_ams_net" | grep -qE "\.proto='($(proto_re mm))'"; then
		/etc/init.d/modemmanager enabled >/dev/null 2>&1 || /etc/init.d/modemmanager enable >/dev/null 2>&1
	elif printf '%s' "$_ams_net" | grep -qE "\.proto='($(proto_re direct))'"; then
		/etc/init.d/modemmanager disable >/dev/null 2>&1
	fi
	/usr/share/5gmodem/mmneed.sh apply >/dev/null 2>&1
}

follow_iface_device() {
	local _fd_if="$1" _fd_p="$2" _fd_new="" _fd_dp="" _fd_ch=0 _fd_pr=""
	[ -n "$_fd_if" ] && [ -n "$_fd_p" ] || return 0
	_fd_pr=$(uci -q get "network.$_fd_if.proto")
	if [ "$_fd_pr" = modemmanager ]; then
		_fd_new=$(readlink -f "/sys/bus/usb/devices/$_fd_p" 2>/dev/null)
		[ -n "$_fd_new" ] && [ -f "$_fd_new/idVendor" ] || _fd_new=""
	elif proto_in wdmdev "$_fd_pr"; then
		_fd_new=$(wdm_for_path "$_fd_p")
		[ -n "$_fd_new" ] && [ -e "$_fd_new" ] \
			&& [ "$(path_for_wdm "$_fd_new")" = "$_fd_p" ] || _fd_new=""
	else
		return 0
	fi
	[ -n "$_fd_new" ] || return 0
	if [ "$(uci -q get "network.$_fd_if.device")" != "$_fd_new" ]; then
		uci -q set "network.$_fd_if.device=$_fd_new"
		_fd_ch=1
	fi
	if proto_in wdm "$_fd_pr"; then
		_fd_dp=$(readlink -f "/sys/class/usbmisc/$(basename "$_fd_new")/device" 2>/dev/null)
		if [ -n "$_fd_dp" ] && [ -d "$_fd_dp/usbmisc" ] \
		   && [ "$(uci -q get "network.$_fd_if.devpath")" != "$_fd_dp" ]; then
			uci -q set "network.$_fd_if.devpath=$_fd_dp"
			_fd_ch=1
		fi
	fi
	if [ "$_fd_ch" = 1 ]; then
		uci -q commit network
		logger -t 5gmodem "iface $_fd_if: modem $_fd_p returned on another path - device now $_fd_new"
	fi
	return 0
}

ensure_iface() {
	local P="$1" SEC="$2" IF PROTO CUR NEW CHG MET t tt OWNER _dp _dpo _ifst
	IF=$(uci -q get "$CFG.$SEC.network")
	[ -n "$IF" ] || return 0
	uci -q get "network.$IF" >/dev/null 2>&1 || return 0

	if ! iface_owned_by "$IF" "$P" "$(imei_for_path "$P")"; then
		OWNER=$(uci -q get "network.$IF.modem_imei")
		[ -n "$OWNER" ] || OWNER=$(uci -q get "network.$IF.modem_path")
		logger -t 5gmodem-resolve "iface $IF belongs to modem $OWNER, not $P - not touching it"
		_ei_mine=""
		_ei_imei=$(imei_for_path "$P")
		for _ei_c in $(uci -q show network 2>/dev/null \
				| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
			[ "$_ei_c" = "$IF" ] && continue
			if iface_owned_by "$_ei_c" "$P" "$_ei_imei"; then _ei_mine="$_ei_c"; break; fi
		done
		if [ -n "$_ei_mine" ]; then
			uci -q set "$CFG.$SEC.network=$_ei_mine"
			uci -q commit "$CFG"
			logger -t 5gmodem-resolve "section $SEC referenced foreign $IF - switched to its own $_ei_mine"
			IF="$_ei_mine"
		else
			uci -q delete "$CFG.$SEC.network"
			uci -q commit "$CFG"
			logger -t 5gmodem-resolve "section $SEC referenced foreign $IF - reference cleared, the interface will be recreated"
			return 0
		fi
	fi

	if [ -z "$(uci -q get "network.$IF.modem_imei")" ]; then
		stamp_iface_owner "$IF" "$P"
	fi

	PROTO=$(uci -q get "network.$IF.proto")
	CUR=$(uci -q get "network.$IF.device")
	NEW=""
	_ei_pc="$PROTO"
	proto_in serial "$PROTO" && _ei_pc=serial
	proto_in dialtty "$PROTO" && _ei_pc=dialtty
	proto_in wdmdev "$PROTO" && _ei_pc=wdmdev
	case "$_ei_pc" in
		wdmdev)           NEW=$(wdm_for_path "$P") ;;
		modemmanager)     NEW=$(readlink -f "/sys/bus/usb/devices/$P" 2>/dev/null) ;;
		dialtty)
			if [ -n "$(uci -q get "$CFG.$SEC.data_at_port")" ]; then
				MET=$(uci -q get "$CFG.@5gmodem[0].at_port")
				_rp_gcom=""
				[ "$PROTO" = xmm ] && [ -f /etc/gcom/probeport.gcom ] \
					&& command -v gcom >/dev/null 2>&1 && _rp_gcom=1
				_dp_cur=$(uci -q get "$CFG.$SEC.data_at_port")
				if [ -n "$_dp_cur" ] && [ -c "$_dp_cur" ] && [ "$_dp_cur" != "$MET" ]; then
					for t in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
					         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
						[ -e "$t" ] || continue
						[ "/dev/$(basename "$t")" = "$_dp_cur" ] || continue
						if [ -n "$_rp_gcom" ] && [ "$(uci -q get "$CFG.$SEC.no_at")" != "1" ]; then
							DEVPORT="$_dp_cur" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || break
						fi
						NEW="$_dp_cur"; break
					done
				fi
				[ -n "$NEW" ] || for DPMODE in model at; do
					for t in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
					         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
						[ -e "$t" ] || continue
						tt="/dev/$(basename "$t")"
						[ "$tt" = "$MET" ] && continue
						if [ -n "$_rp_gcom" ]; then
							DEVPORT="$tt" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || continue
						elif [ "$DPMODE" = model ]; then
							/usr/share/5gmodem/atprobe.sh "$tt" model >/dev/null 2>&1 || continue
						else
							/usr/share/5gmodem/atprobe.sh "$tt" >/dev/null 2>&1 || continue
						fi
						NEW="$tt"; break
					done
					[ -n "$NEW" ] && break
				done
				[ -n "$NEW" ] || NEW=$(uci -q get "$CFG.$SEC.at_port")
				[ -n "$NEW" ] && uci -q set "$CFG.$SEC.data_at_port=$NEW"
			else
				NEW=$(uci -q get "$CFG.$SEC.at_port")
			fi
			;;
		serial)           NEW=$(uci -q get "$CFG.$SEC.at_port") ;;
		fibocom)          NEW=$(for n in /sys/bus/usb/devices/$P:*/net/*; do [ -e "$n" ] && { basename "$n"; break; }; done) ;;
	esac
	CHG=0
	if [ -n "$NEW" ] && { [ -e "$NEW" ] || [ -d "/sys/class/net/$NEW" ]; } && [ "$NEW" != "$CUR" ]; then
		uci -q set "network.$IF.device=$NEW"; uci -q commit network; CHG=1
	fi
	if proto_in wdm "$PROTO"; then
		_dp=$(readlink -f "/sys/class/usbmisc/$(basename "$NEW")/device" 2>/dev/null)
		_dpo=$(uci -q get "network.$IF.devpath")
		if [ -n "$_dp" ] && [ -d "$_dp/usbmisc" ] && [ "$_dp" != "$_dpo" ]; then
			uci -q set "network.$IF.devpath=$_dp"; uci -q commit network; CHG=1
		fi
	fi
	_ifst=$(ifstatus "$IF" 2>/dev/null)
	if [ "$CHG" = 1 ] || ! printf '%s\n' "$_ifst" | grep -q '"up": true'; then
		if [ "$CHG" != 1 ] && printf '%s\n' "$_ifst" | grep -q '"pending": true'; then
			logger -t 5gmodem-resolve "interface $IF is already pending - not starting a parallel ifup"
			return 0
		fi
		ifup "$IF" >/dev/null 2>&1
	fi
}

fix_iface_proto() {
	_fp_if="$1"
	[ -n "$_fp_if" ] || return
	_fp_pr=$(uci -q get "network.$_fp_if.proto")
	_fp_dev=$(uci -q get "network.$_fp_if.device")
	_fp_drv=""
	case "$_fp_dev" in
		/dev/cdc-wdm*)
			_fp_drv=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$_fp_dev")/device/driver" 2>/dev/null)" 2>/dev/null)
			;;
	esac
	case "$_fp_drv" in
		cdc_mbim) _fp_want="mbim" ;;
		qmi_wwan) _fp_want="qmi" ;;
		*)        return ;;
	esac
	_fp_amp=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$_fp_dev")/device/.." 2>/dev/null)" 2>/dev/null)
	_fp_vp=""
	[ -n "$_fp_amp" ] && [ -f "/sys/bus/usb/devices/$_fp_amp/idVendor" ] && \
		_fp_vp="$(cat "/sys/bus/usb/devices/$_fp_amp/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$_fp_amp/idProduct" 2>/dev/null)"
	if [ "$_fp_pr" = "qmi" ] && [ "$_fp_drv" = "qmi_wwan" ] \
	   && [ -f /lib/netifd/proto/modemmanager.sh ]; then
		case "$_fp_vp" in
			05c6:*)
				. /usr/share/5gmodem/iscompal.sh
				if is_compal "$_fp_amp" "$_fp_dev"; then
					logger -t 5gmodem "iface $_fp_if: Compal RXM-G1 / SG500M2-X ($_fp_vp) - uqmi cannot open its QMI services, rebuilding the interface on proto=modemmanager"
					MKIFACE_AUTOFALLBACK=1 MODEM_PATH="$_fp_amp" \
						/usr/share/5gmodem/mkiface.sh "$_fp_if" modemmanager >/dev/null 2>&1
					return
				fi
				;;
		esac
	fi
	[ "$_fp_pr" = "$_fp_want" ] && return
	case "$_fp_pr" in
		mbim|qmi) ;;
		*) return ;;
	esac
	_fp_sec=$(sec_for_iface "$_fp_if")
	if [ -n "$_fp_sec" ] && [ "$(uci -q get "5gmodem.$_fp_sec.iface_proto")" = "$_fp_pr" ]; then
		logger -t 5gmodem "iface $_fp_if: dropping the automatic iface_proto=$_fp_pr from 5gmodem.$_fp_sec so auto-detect (and the vendor exceptions) can decide again"
		uci -q delete "5gmodem.$_fp_sec.iface_proto"
	fi
	if [ "$(uci -q get 5gmodem.@5gmodem[0].network)" = "$_fp_if" ] \
	   && [ "$(uci -q get 5gmodem.@5gmodem[0].iface_proto)" = "$_fp_pr" ]; then
		uci -q delete 5gmodem.@5gmodem[0].iface_proto
	fi
	uci -q commit 5gmodem

	case "$_fp_vp" in
		413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911|05c6:90d5)
			if [ -f /lib/netifd/proto/modemmanager.sh ]; then
				logger -t 5gmodem "iface $_fp_if: $_fp_vp only works under ModemManager - rebuilding the interface on proto=modemmanager"
				MKIFACE_AUTOFALLBACK=1 MODEM_PATH="$_fp_amp" \
					/usr/share/5gmodem/mkiface.sh "$_fp_if" modemmanager >/dev/null 2>&1
				return
			fi
			;;
	esac
	logger -t 5gmodem "iface $_fp_if: proto=$_fp_pr does not match driver $_fp_drv - setting $_fp_want"
	uci -q set "network.$_fp_if.proto=$_fp_want"
	uci -q commit network
}

orphan_iface_for() {
	local P="$1" IF OWNER DEV NODES n claimed
	NODES=" $(wdm_for_path "$P") "
	for n in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
	         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
		[ -e "$n" ] && NODES="$NODES /dev/$(basename "$n") "
	done
	for n in /sys/bus/usb/devices/$P:*/net/*; do
		[ -e "$n" ] && NODES="$NODES $(basename "$n") "
	done
	for IF in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		DEV=$(uci -q get "network.$IF.device")
		[ -n "$DEV" ] || continue
		echo "$NODES" | grep -q " $DEV " || continue
		iface_owned_by "$IF" "$P" "$(imei_for_path "$P")" && continue
		claimed=$(sec_for_iface "$IF")
		[ -n "$claimed" ] && continue
		case "$IF" in
			*6)
				_base=${IF%6}
				if [ "$(uci -q get "network.$_base.device")" = "$DEV" ]; then
					continue
				fi
				;;
		esac
		echo "$IF"; return 0
	done
	return 1
}

iface_for_path() {
	_want="$1"; [ -n "$_want" ] || return 1
	for _if in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		case "$_if" in loopback|lan|wan6) continue ;; esac
		if [ "$(uci -q get "network.$_if.proto")" = ccmni ]; then
			[ "$_want" = ccci ] && { echo "$_if"; return 0; }
			continue
		fi
		_dev=$(uci -q get "network.$_if.device")
		[ -n "$_dev" ] || _dev=$(ifup_state_dev "$_if")
		[ -n "$_dev" ] || continue
		_p=""
		if [ "$(uci -q get "network.$_if.proto")" = modemmanager ]; then
			case "$_dev" in
				/sys/*) _p="${_dev##*/}" ;;
				*) _p=$(mmcli --modem="$_dev" -K 2>/dev/null | sed -n 's/^modem\.generic\.physdev *: *//p' | head -1)
				   _p="${_p##*/}" ;;
			esac
			[ -n "$_p" ] && [ "$_p" = "$_want" ] && { echo "$_if"; return 0; }
			continue
		fi
		case "$_dev" in
			/dev/cdc-wdm*)
				_p=$(readlink -f "/sys/class/usbmisc/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
			/dev/tty*)
				_p=$(readlink -f "/sys/class/tty/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/ttyUSB[0-9]*$||;s|.*/||;s|:.*||') ;;
			*)
				[ -e "/sys/class/net/$_dev" ] || continue
				_p=$(readlink -f "/sys/class/net/$_dev/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
		esac
		[ "$_p" = "$_want" ] && { echo "$_if"; return 0; }
	done
	return 1
}

ifup_state_dev() {
	ubus call network.interface."$1" status 2>/dev/null \
		| jsonfilter -e '@["l3_device"]' 2>/dev/null
}

drop_stale_ifaces() {
	[ -n "$1" ] || return 0
	_ds_imei=$(imei_for_path "$1")
	_ds_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	for _ds_i in $(uci show network 2>/dev/null | grep -F ".modem_path='$1'" \
			| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
		[ "$_ds_i" = "$2" ] && continue
		iface_owned_by "$_ds_i" "$1" "$_ds_imei" || continue
		ifdown "$_ds_i" >/dev/null 2>&1
		uci -q delete "network.$_ds_i"
		[ -n "$_ds_z" ] && uci -q del_list "firewall.$_ds_z.network=$_ds_i"
		logger -t 5gmodem "removed orphan interface $_ds_i (modem $1 is now on ${2:-?})"
	done
	uci -q commit network
	uci -q commit firewall
}
