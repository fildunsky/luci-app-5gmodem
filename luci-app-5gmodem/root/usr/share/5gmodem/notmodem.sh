#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null
NOT_MODEM_VIDPIDS="1a86:7522 1a86:7523 1a86:55d3 0403:6001 0403:6010 0403:6011 0403:6014 0403:6015 10c4:ea60 10c4:ea70 10c4:ea71 067b:2303 067b:23a3 067b:23c3"
NOT_MODEM_SERVICE="05c6:9008 05c6:900e 19d2:9008 12d1:1443 12d1:36dd 1199:9078 1199:9090 0e8d:0003 1bbb:007a"

_NM_CFG=""
_nm_cfg() {
	[ -n "$_NM_CFG" ] && return 0
	_NM_CFG=1
	NOT_MODEM_EXTRA=$(uci -q get 5gmodem.@5gmodem[0].ignore_vidpid 2>/dev/null)
	NOT_MODEM_FORCE=$(uci -q get 5gmodem.@5gmodem[0].modem_vidpid 2>/dev/null)
}

is_not_modem() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	_nm_cfg
	for _nm in $NOT_MODEM_FORCE; do
		[ "$1" = "$_nm" ] && return 1
	done
	for _nm in $NOT_MODEM_VIDPIDS $NOT_MODEM_SERVICE $NOT_MODEM_EXTRA; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

is_not_modem_builtin() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	for _nm in $NOT_MODEM_VIDPIDS $NOT_MODEM_SERVICE; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

is_not_modem_service() {
	case " $NOT_MODEM_SERVICE " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

MODEM_DRIVERS="option qcserial sierra sierra_net usb_wwan qmi_wwan cdc_mbim cdc_ncm cdc_wdm huawei_cdc_ncm cdc_ether rndis_host cdc_subset qcaux GobiNet GobiSerial simcom_wwan"

CELL_VENDORS="12d1 19d2 2c7c 1e0e 1bc7 0e8d 2cb7 1e2d 2dee 05c6 1199 2020 1c9e 0af0 1bbb 2001 0421 1546 1782 1410 16d8 106c"

IM_WHY=""
IM_DETAIL=""

usb_is_modem() {
	_im_n="$1"
	IM_WHY=""; IM_DETAIL=""
	[ -n "$_im_n" ] && [ -f "$_im_n/idVendor" ] || { IM_WHY=none; IM_DETAIL=""; return 1; }
	_im_v=$(cat "$_im_n/idVendor" 2>/dev/null)
	_im_p=$(cat "$_im_n/idProduct" 2>/dev/null)
	_nm_cfg

	for _im_x in $NOT_MODEM_FORCE; do
		[ "$_im_v:$_im_p" = "$_im_x" ] && { IM_WHY=forced; IM_DETAIL=""; return 0; }
	done
	if is_not_modem "$_im_v:$_im_p"; then
		IM_DETAIL=""
		if is_not_modem_service "$_im_v:$_im_p"; then
			IM_WHY=service
		elif is_not_modem_builtin "$_im_v:$_im_p"; then
			IM_WHY=bridge
		else
			IM_WHY=ignored
		fi
		return 1
	fi

	case " $CELL_VENDORS " in
		*" $_im_v "*) IM_WHY=vendor; IM_DETAIL="$_im_v"; return 0 ;;
	esac

	for _im_i in "$_im_n"/*:*; do
		[ -d "$_im_i" ] || continue
		_im_d=$(readlink "$_im_i/driver" 2>/dev/null); _im_d=${_im_d##*/}
		case " $MODEM_DRIVERS " in
			*" $_im_d "*) IM_WHY=driver; IM_DETAIL="$_im_d"; return 0 ;;
		esac
		case "$(cat "$_im_i/bInterfaceClass" 2>/dev/null):$(cat "$_im_i/bInterfaceSubClass" 2>/dev/null)" in
			02:0e) IM_WHY=mbim; IM_DETAIL=""; return 0 ;;
			02:06) IM_WHY=ecm; IM_DETAIL=""; return 0 ;;
			02:0d) IM_WHY=ncm; IM_DETAIL=""; return 0 ;;
		esac
	done

	_im_s="m_$(basename "$_im_n" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ -n "$(uci -q get "5gmodem.$_im_s.imei" 2>/dev/null)$(uci -q get "5gmodem.$_im_s.model" 2>/dev/null)" ]; then
		IM_WHY=profile; IM_DETAIL=""
		return 0
	fi

	IM_WHY=none; IM_DETAIL=""
	return 1
}

usb_is_modem_vidpid() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	for _iv_n in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
		case "$_iv_n" in *:*) continue ;; esac
		[ -f "$_iv_n/idVendor" ] || continue
		[ "$(cat "$_iv_n/idVendor" 2>/dev/null):$(cat "$_iv_n/idProduct" 2>/dev/null)" = "$1" ] || continue
		usb_is_modem "$_iv_n"
		return $?
	done
	IM_WHY=absent; IM_DETAIL=""
	return 1
}

nm_scan() {
	_nm_cfg
	_ns_esc() {
		case "$1" in
			*\\*|*\"*) echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
			*) echo "$1" ;;
		esac
	}
	_ns_out=""
	_ns_seen=""
	_ns_auto() {
		_sa_e="$NOT_MODEM_EXTRA"; _sa_f="$NOT_MODEM_FORCE"
		NOT_MODEM_EXTRA=""; NOT_MODEM_FORCE=""
		usb_is_modem "$1"; _sa_r=$?
		NOT_MODEM_EXTRA="$_sa_e"; NOT_MODEM_FORCE="$_sa_f"
		return $_sa_r
	}
	_ns_add() {
		_nb=0; is_not_modem_builtin "$2" && _nb=1
		_nk2=0; [ -f "/usr/share/5gmodem/modem/usb/$(echo "$2" | tr -d ':')" ] && _nk2=1
		_na=0; _nw=""
		if [ -n "$6" ]; then
			_ns_auto "$6" && _na=1
			_nk=0; usb_is_modem "$6" || _nk=1
			_nw="$IM_WHY"; _nwd="$IM_DETAIL"
		else
			_na=0
			_nk=0; is_not_modem "$2" && _nk=1
			usb_is_modem_vidpid "$2" >/dev/null 2>&1
			_nw=absent; _nwd=""
		fi
		[ -n "$_ns_out" ] && _ns_out="$_ns_out,"
		_ns_out="$_ns_out{\"path\":\"$(_ns_esc "$1")\",\"vidpid\":\"$(_ns_esc "$2")\",\"product\":\"$(_ns_esc "$3")\",\"ports\":[$4],\"skip\":\"$_nk\",\"builtin\":\"$_nb\",\"known\":\"$_nk2\",\"auto\":\"$_na\",\"why\":\"$(_ns_esc "$_nw")\",\"detail\":\"$(_ns_esc "$_nwd")\",\"absent\":\"$5\"}"
	}

	for _nd in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
		[ -f "$_nd/idVendor" ] || continue
		case "$_nd" in *:*) continue ;; esac
		_np=""
		for _ni in "$_nd"/*:*; do
			for _nn in "$_ni"/tty/* "$_ni"/usbmisc/* "$_ni"/*/tty/* "$_ni"/*/usbmisc/*; do
				[ -e "$_nn" ] || continue
				_nnb=$(basename "$_nn")
				case ",$_np," in *"\"/dev/$_nnb\","*) continue ;; esac
				_np="${_np}${_np:+,}\"/dev/$_nnb\""
			done
		done
		_nvp="$(cat "$_nd/idVendor" 2>/dev/null):$(cat "$_nd/idProduct" 2>/dev/null)"
		_nbn=$(basename "$_nd")
		if [ -z "$_np" ]; then
			case " $NM_MODEM_PATHS " in *" $_nbn "*) ;; *) continue ;; esac
		fi
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "$_nbn" "$_nvp" "$(cat "$_nd/product" 2>/dev/null)" "$_np" 0 "$_nd"
	done

	_nm_cfg
	for _nvp in $NOT_MODEM_EXTRA $NOT_MODEM_FORCE; do
		case " $_ns_seen " in *" $_nvp "*) continue ;; esac
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "" "$_nvp" "" "" 1 ""
	done

	echo "[$_ns_out]"
}

case "$0" in
	*/notmodem.sh|notmodem.sh)
		case "$1" in
			setblack)
				_sb_i=""; _sb_f=""
				for _sb_t in $2; do
					case "$_sb_t" in
						[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
							_sb_i="$_sb_i${_sb_i:+ }$_sb_t" ;;
					esac
				done
				for _sb_t in $3; do
					case "$_sb_t" in
						[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
							_sb_f="$_sb_f${_sb_f:+ }$_sb_t" ;;
					esac
				done
				if [ -n "$_sb_i" ]; then
					uci -q set "5gmodem.@5gmodem[0].ignore_vidpid=$_sb_i"
				else
					uci -q delete 5gmodem.@5gmodem[0].ignore_vidpid
				fi
				if [ -n "$_sb_f" ]; then
					uci -q set "5gmodem.@5gmodem[0].modem_vidpid=$_sb_f"
				else
					uci -q delete 5gmodem.@5gmodem[0].modem_vidpid
				fi
				uci -q commit 5gmodem
				rm -f /tmp/5gmodem/listmodems.* /tmp/luci-indexcache* 2>/dev/null
				echo ok
				;;
			scan)
				NM_MODEM_PATHS=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
					| jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
				nm_scan
				;;
			*) echo "usage: notmodem.sh scan | setblack <ignore> <force>" >&2; exit 1 ;;
		esac
		;;
esac
