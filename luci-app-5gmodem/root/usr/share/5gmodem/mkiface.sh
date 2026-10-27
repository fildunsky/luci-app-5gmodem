#!/bin/sh

IF="${1:-modem}"
REQ="${2:-auto}"
APNARG="$3"

. /usr/share/5gmodem/lib.sh
_fw_zone_add() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	[ -n "$_fz" ] && [ -n "$1" ] || return 0
	_fcur=$(uci -q get "firewall.$_fz.network" | tr -d "'\"")
	_fdirty=0
	case "$(uci -q show "firewall.$_fz.network" 2>/dev/null)" in
		*"' '"*) ;;
		*=\'*\ *\') _fdirty=1 ;;
	esac
	_fseen=" "
	for _fe in $_fcur; do
		case "$_fseen" in *" $_fe "*) _fdirty=1 ;; esac
		_fseen="$_fseen$_fe "
	done
	if [ "$_fdirty" = 0 ]; then
		case " $_fcur " in *" $1 "*) return 0 ;; esac
		uci add_list "firewall.$_fz.network=$1"
		uci commit firewall
		return 0
	fi
	uci -q delete "firewall.$_fz.network"
	_fadd=" "
	for _fe in $_fcur; do
		[ "$_fe" = "$1" ] && continue
		case "$_fadd" in *" $_fe "*) continue ;; esac
		_fadd="$_fadd$_fe "
		uci add_list "firewall.$_fz.network=$_fe"
	done
	uci add_list "firewall.$_fz.network=$1"
	uci commit firewall
}

stamp_iface() {
	stamp_iface_owner "$1" "$2"
}

_def_metric() {
	if [ "$(uci -q get 5gmodem.@5gmodem[0].mwan3_metrics)" = "1" ]; then
		_dm_v=20
	else
		_dm_v=110
	fi
	_dm_z=$(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	for _dm_n in $([ -n "$_dm_z" ] && uci -q get "firewall.$_dm_z.network"); do
		[ "$_dm_n" = "$IF" ] && continue
		_dm_m=$(uci -q get "network.$_dm_n.metric")
		case "$_dm_m" in ''|*[!0-9]*) continue ;; esac
		[ $((_dm_m + 10)) -gt "$_dm_v" ] && _dm_v=$((_dm_m + 10))
	done
	echo "$_dm_v"
}

set_apn_opt() {
	case "$APNARG" in
		-)  uci -q delete "network.$1.apn" ;;
		"") uci set "network.$1.apn=${2:-internet}" ;;
		*)  uci set "network.$1.apn=$APNARG" ;;
	esac
}

PDPARG="$4"

MMEXCLARG="$5"
USERARG="$6"

set_pdp_opt() {
	_opt="$2"; _up="$3"
	_v="$PDPARG"
	[ -n "$_v" ] || _v=$(uci -q get "network.$1.$_opt")
	[ -n "$_v" ] || _v="$OLDPDP"
	[ -n "$_v" ] || _v="ipv4"
	case "$_v" in
		ipv4v6|IPV4V6) _v=ipv4v6 ;;
		*)             _v=ipv4 ;;
	esac
	[ "$_up" = upper ] && _v=$(echo "$_v" | tr a-z A-Z)
	uci set "network.$1.$_opt=$_v"
}

json() { printf '{"result":"%s","iface":"%s","proto":"%s","device":"%s"}\n' "$1" "$IF" "$2" "$3"; }

MK_KEEP_OPTS="defaultroute peerdns delegate ip4table ip6table"
_mk_keep_save() {
	MK_KEEP=""
	for _mk_o in $MK_KEEP_OPTS; do
		_mk_v=$(uci -q get "network.$1.$_mk_o") || continue
		MK_KEEP="$MK_KEEP $_mk_o=$_mk_v"
	done
}
_mk_keep_restore() {
	for _mk_kv in $MK_KEEP; do
		uci -q set "network.$1.${_mk_kv%%=*}=${_mk_kv#*=}"
	done
}

_mk_if_ok() {
	case "$1" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
	uci -q get "network.$1" >/dev/null 2>&1 || return 0
	[ "$(uci -q get "network.$1")" = interface ] || return 1
	[ -n "$(uci -q get "network.$1.modem_path")$(uci -q get "network.$1.modem_imei")" ] && return 0
	case "$(uci -q get "network.$1.proto")" in
		mbim|mbimp|qmi|qmiraw|qmip|ncm|xmm|atc|wwan|3g|modemmanager|fibocom|quectel) return 0 ;;
	esac
	uci show 5gmodem 2>/dev/null | grep -q "\.network='$1'\$" && return 0
	return 1
}
_mk_guard_if() {
	_mk_if_ok "$1" && return 0
	logger -t 5gmodem-mkiface "refusing interface name '$1': not a valid name or a network section that does not belong to a modem"
	IF="$1"
	json "invalid interface name" "" ""
	exit 1
}
_mk_guard_if "$IF"

run_bounded() {
	_lim="$1"; shift
	_out=$(mktemp /tmp/5gmodem/bounded.XXXXXX 2>/dev/null) || _out="/tmp/5gmodem/bounded.$$.$(date +%s)"
	rm -f "$_out"
	( "$@" >"$_out" 2>&1 ) &
	_p=$!
	_rb_n=0
	while kill -0 "$_p" 2>/dev/null && [ "$_rb_n" -lt "$_lim" ]; do sleep 1; _rb_n=$((_rb_n + 1)); done
	kill -9 "$_p" 2>/dev/null
	cat "$_out" 2>/dev/null
	rm -f "$_out"
}

qmi_alive() {
	if command -v uqmi >/dev/null 2>&1; then
		case "$(run_bounded 8 uqmi -s -d "$1" -t 3000 --uim-get-sim-state 2>/dev/null)" in
			*'"card_application_state"'*|*'"pin1_status"'*) return 0 ;;
		esac
		return 1
	fi
	case "$(run_bounded 8 qmicli -d "$1" --uim-get-card-status 2>/dev/null)" in
		*"card status"*|*"Card state"*|*present*) return 0 ;;
	esac
	return 1
}

at_port_of() {
	for _t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		case "$(at_query "$_t" "AT+CGMM" 6)" in
			*ERROR*|*"No response"*|"") continue ;;
			*) echo "$_t"; return 0 ;;
		esac
	done
	return 1
}

kernel_proto_prepare() {
	_wdm="$1"; _path="$2"
	[ -n "$_wdm" ] && [ -e "$_wdm" ] || return 0

	if pgrep -f ModemManager >/dev/null 2>&1; then
		if mmcli -L 2>/dev/null | grep -q "/Modem/"; then
			echo "prepare: inhibiting $_path in ModemManager (leaving neighbors alone)" >&2
			/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1
			_n=0
			while [ "$_n" -lt 20 ]; do
				_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_path" 2>/dev/null)
				[ -n "$_mi" ] || break
				sleep 1; _n=$((_n + 1))
			done
		fi
	fi

	for _p in $(pgrep -f "uqmi .*$_wdm" 2>/dev/null); do
		echo "prepare: killing wedged uqmi (pid $_p) holding $_wdm" >&2
		kill -9 "$_p" 2>/dev/null
	done

	[ "$PROTO" = qmi ] || return 0
	qmi_alive "$_wdm" && return 0

	_atp=$(at_port_of "$_path")
	[ -n "$_atp" ] || { echo "prepare: QMI wedged and no AT port to reset the modem" >&2; return 1; }
	echo "prepare: QMI is wedged - resetting the modem via AT+CFUN=1,1 on $_atp" >&2
	( at_query "$_atp" "AT+CFUN=1,1" 6 ) >/dev/null 2>&1 </dev/null 7>&- 8>&- 9>&- &

	_n=0
	while [ "$_n" -lt 90 ]; do
		sleep 3; _n=$((_n + 3))
		/usr/share/5gmodem/listmodems.sh --refresh 2>/dev/null | grep -q "\"$_path\"" || continue
		_w=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$_path\"].wdm[0]" 2>/dev/null)
		[ -n "$_w" ] && [ -e "$_w" ] || continue
		qmi_alive "$_w" && { echo "prepare: QMI recovered after ${_n}s" >&2; return 0; }
	done
	echo "prepare: QMI did not recover in ${_n}s" >&2
	return 1
}

mm_restart_safe() {
	if pgrep -f ModemManager >/dev/null 2>&1; then
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		_n=0
		while pgrep -f ModemManager >/dev/null 2>&1 && [ "$_n" -lt 15 ]; do
			sleep 1; _n=$((_n + 1))
		done
	fi
	/etc/init.d/modemmanager start >/dev/null 2>&1
}

note_foreign_uci network "mkiface"
note_foreign_uci firewall "mkiface"
AMP=${MODEM_PATH:-$(uci -q get 5gmodem.@5gmodem[0].active_modem)}
_ACTPATH=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_IS_ACTIVE=1
[ -n "$MODEM_PATH" ] && [ -n "$_ACTPATH" ] && [ "$MODEM_PATH" != "$_ACTPATH" ] && _IS_ACTIVE=0
MSEC=""
WANTWDM=""

_mk_atport() {
	[ -n "$AMP" ] || return 0
	_ma=$(/usr/share/5gmodem/registry.sh path "$AMP" 2>/dev/null \
		| jsonfilter -e '@.at_port' 2>/dev/null)
	[ -n "$_ma" ] && { printf '%s' "$_ma"; return 0; }
	[ "$_IS_ACTIVE" = "1" ] || return 0
	_ma=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	[ -n "$_ma" ] || _ma=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	printf '%s' "$_ma"
}

if [ -n "$AMP" ]; then
	MSEC=$(secname "$AMP")
	USED=$(uci show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\(.*\)'\$/\1=\2/p" | grep -v "^$MSEC=" | cut -d= -f2 | tr '\n' ' ')
	cand=$(uci -q get "5gmodem.$MSEC.network")
	[ -n "$cand" ] || cand="modem"
	n=1
	MYIMEI=$(imei_for_path "$AMP")
	while echo " $USED " | grep -q " $cand " \
	      || { uci -q get "network.$cand" >/dev/null 2>&1 \
	           && ! iface_owned_by "$cand" "$AMP" "$MYIMEI"; }; do
		n=$((n + 1)); cand="modem$n"
	done
	IF="$cand"

	if ! uci -q get "network.$IF" >/dev/null 2>&1; then
		_mk_nd=""
		for _mk_n in /sys/bus/usb/devices/"$AMP":*/net/*; do
			[ -e "$_mk_n" ] || continue
			_mk_nd=$(basename "$_mk_n"); break
		done
		if [ -n "$_mk_nd" ]; then
			for _mk_c in $(uci -q show network 2>/dev/null \
					| sed -n "s/^network\.\([^.]*\)\.device='\?$_mk_nd'\?\$/\1/p"); do
				[ "$(uci -q get "network.$_mk_c.modem_path")" = "$AMP" ] || continue
				logger -t 5gmodem-mkiface "interface $_mk_c already serves $_mk_nd of modem $AMP - reusing it instead of creating $IF"
				IF="$_mk_c"
				break
			done
		fi
	fi

	WANTWDM=$(/usr/share/5gmodem/registry.sh path "$AMP" 2>/dev/null \
		| jsonfilter -e '@.wdm[0]' 2>/dev/null)
	if [ -z "$WANTWDM" ]; then
		for _w in /sys/bus/usb/devices/"$AMP":*/usbmisc/cdc-wdm* \
		          /sys/bus/usb/devices/"$AMP":*/usbmisc/wdm*; do
			[ -e "$_w" ] || continue
			WANTWDM="/dev/$(basename "$_w")"
			logger -t 5gmodem-mkiface "registry did not provide a control channel for $AMP; found one in sysfs: $WANTWDM"
			break
		done
	fi
fi

if [ "$AMP" = ccci ]; then
	[ -f /lib/netifd/proto/ccmni.sh ] || { json error ccmni ""; exit 1; }
	_mk_cc=$(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='\?ccmni'\?\$/\1/p" | head -1)
	[ -n "$_mk_cc" ] || _mk_cc=$(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.\(device\|ifname\)='\?ccmni0'\?\$/\1/p" | head -1)
	[ -n "$_mk_cc" ] && IF="$_mk_cc"
	if [ "$(uci -q get "network.$IF.proto")" != ccmni ]; then
		OLDMETRIC=$(uci -q get "network.$IF.metric")
		_mk_guard_if "$IF"
		uci -q delete "network.$IF" 2>/dev/null
		uci set "network.$IF=interface"
		uci set "network.$IF.proto=ccmni"
		uci set "network.$IF.ifname=ccmni0"
		uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
		uci commit network
		_fw_zone_add "$IF"
	fi
	if [ "$_IS_ACTIVE" = 1 ]; then
		uci -q set "5gmodem.@5gmodem[0].network=$IF"
		uci -q set "5gmodem.@5gmodem[0].iface_proto=ccmni"
	fi
	uci -q set "5gmodem.$MSEC.network=$IF"
	uci -q set "5gmodem.$MSEC.iface_proto=ccmni"
	stamp_iface "$IF" "$AMP"
	uci -q commit 5gmodem
	ifup "$IF" >/dev/null 2>&1
	json created ccmni ccmni0
	exit 0
fi

if [ -n "$AMP" ] && [ -z "$WANTWDM" ] && { [ "$REQ" = auto ] || [ "$REQ" = "" ] || [ "$REQ" = fibocom ] || [ "$REQ" = atc ] || [ "$REQ" = xmm ]; }; then
	FNET=""
	for n in /sys/bus/usb/devices/$AMP:*/net/*; do
		[ -e "$n" ] || continue
		FNET=$(basename "$n"); break
	done
	if [ -n "$FNET" ]; then
		OLDAPN=$(uci -q get "network.$IF.apn")
		OLDPDP=$(uci -q get "network.$IF.pdptype")
		[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.pdp")
		[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.iptype")
		OLDROAM=$(uci -q get "network.$IF.allow_roaming")
		OLDMETRIC=$(uci -q get "network.$IF.metric")
		OLDAUTH=$(uci -q get "network.$IF.auth")
		OLDUSER=$(uci -q get "network.$IF.username")
		OLDPASS=$(uci -q get "network.$IF.password")
		OLDDNS=$(uci -q get "network.$IF.dns")
		_mk_guard_if "$IF"
		_mk_keep_save "$IF"
		uci -q delete "network.$IF" 2>/dev/null
		uci set "network.$IF=interface"

		FPROTO=fibocom
		[ "$REQ" = xmm ] && [ -f /lib/netifd/proto/xmm.sh ] && [ -z "$OLDUSER" ] && FPROTO=xmm
		[ "$REQ" = atc ] && [ -f /lib/netifd/proto/atc.sh ] && FPROTO=atc

		_mki_xvp="$(cat "/sys/bus/usb/devices/$AMP/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$AMP/idProduct" 2>/dev/null)"
		if { [ "$REQ" = auto ] || [ -z "$REQ" ]; } \
		   && { [ "${_mki_xvp%%:*}" = "8087" ] || [ "$_mki_xvp" = "2cb7:000b" ]; }; then
			if [ -f /lib/netifd/proto/xmm.sh ] && [ -n "$OLDUSER" ]; then
				FPROTO=fibocom
				logger -t 5gmodem-mkiface "Intel XMM ($AMP) - setting proto=fibocom (PAP/CHAP login set, xmm.sh drops it)"
			elif [ -f /lib/netifd/proto/xmm.sh ]; then
				FPROTO=xmm
				logger -t 5gmodem-mkiface "Intel XMM ($AMP) - setting proto=xmm (xmm-modem package installed)"
			else
				FPROTO=fibocom
				logger -t 5gmodem-mkiface "Intel XMM ($AMP) - setting proto=fibocom (built-in XMM branch)"
			fi
		fi

		if [ "$FPROTO" = atc ] || [ "$FPROTO" = xmm ]; then
			METRIC_AT=$(_mk_atport)
			DIALPORT=""
			_dp_gcom=""
			[ "$FPROTO" = xmm ] && [ -f /etc/gcom/probeport.gcom ] \
				&& command -v gcom >/dev/null 2>&1 && _dp_gcom=1
			for DPMODE in model at; do
				for t in /sys/bus/usb/devices/$AMP:*/ttyUSB* /sys/bus/usb/devices/$AMP:*/tty/ttyUSB* \
				         /sys/bus/usb/devices/$AMP:*/ttyACM* /sys/bus/usb/devices/$AMP:*/tty/ttyACM*; do
					[ -e "$t" ] || continue
					tt="/dev/$(basename "$t")"
					[ "$tt" = "$METRIC_AT" ] && continue
					if [ -n "$_dp_gcom" ]; then
						DEVPORT="$tt" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || continue
					elif [ "$DPMODE" = model ]; then
						/usr/share/5gmodem/atprobe.sh "$tt" model >/dev/null 2>&1 || continue
					else
						/usr/share/5gmodem/atprobe.sh "$tt" >/dev/null 2>&1 || continue
					fi
					DIALPORT="$tt"; break
				done
				[ -n "$DIALPORT" ] && break
			done
			[ -n "$DIALPORT" ] || DIALPORT="$METRIC_AT"
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.device=$DIALPORT"
			set_apn_opt "$IF" "$OLDAPN"
			set_pdp_opt "$IF" pdp upper
			[ "$(uci -q get "network.$IF.pdp")" = "IPV4" ] && uci set "network.$IF.pdp=IP"
			uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
			FDEV="$DIALPORT"
			[ -n "$MSEC" ] && uci -q set "5gmodem.$MSEC.data_at_port=$DIALPORT"
		else
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.usbpath=$AMP"
			uci set "network.$IF.device=$FNET"
			set_apn_opt "$IF" "$OLDAPN"
			set_pdp_opt "$IF" pdptype upper
			FDEV="$FNET"
		fi
		uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
		[ -n "$OLDROAM" ] && uci set "network.$IF.allow_roaming=$OLDROAM"
		[ -n "$OLDAUTH" ] && uci set "network.$IF.auth=$OLDAUTH"
		[ -n "$OLDUSER" ] && uci set "network.$IF.username=$OLDUSER"
		[ -n "$OLDPASS" ] && uci set "network.$IF.password=$OLDPASS"
		[ -n "$OLDDNS" ] && uci set "network.$IF.dns=$OLDDNS"
		_mk_keep_restore "$IF"
		uci commit network

		_fw_zone_add "$IF"

		if [ "$_IS_ACTIVE" = 1 ]; then
			uci -q set "5gmodem.@5gmodem[0].network=$IF"
			uci -q set "5gmodem.@5gmodem[0].iface_proto=$FPROTO"
		fi
		if [ -n "$MSEC" ]; then
			if ! uci -q get "5gmodem.$MSEC" >/dev/null 2>&1; then
				uci -q set "5gmodem.$MSEC=modem"
				uci -q set "5gmodem.$MSEC.path=$AMP"
				_mk_lm=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
				_mk_vp=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].vidpid" 2>/dev/null | head -1)
				_mk_pr=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].product" 2>/dev/null | head -1)
				[ -n "$_mk_vp" ] && uci -q set "5gmodem.$MSEC.vidpid=$_mk_vp"
				[ -n "$_mk_pr" ] && uci -q set "5gmodem.$MSEC.product=$_mk_pr"
			fi
			uci -q set "5gmodem.$MSEC.network=$IF"
			uci -q set "5gmodem.$MSEC.iface_proto=$FPROTO"
			uci -q delete "5gmodem.$MSEC.foreign_iface" 2>/dev/null
		fi
		stamp_iface "$IF" "$AMP"
		uci -q commit 5gmodem

		if uci -q get 5gmodem.sms >/dev/null 2>&1; then
			uci -q set "5gmodem.sms.sms_via_mm=0"
			uci -q set "5gmodem.sms.ussd_via_mm=0"
			uci -q commit 5gmodem
		fi

		if [ -n "$MSEC" ]; then
			uci -q set "5gmodem.$MSEC.mm_exclude=1"
			uci -q commit 5gmodem
			/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 7>&- 8>&- 9>&- &
		fi
		ifup "$IF" >/dev/null 2>&1
		json created "$FPROTO" "$FDEV"
		exit 0
	fi
fi

DEV=""; DRV=""
if [ -n "$WANTWDM" ] && [ -c "$WANTWDM" ]; then
	DEV="$WANTWDM"
	DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$WANTWDM")/device/driver" 2>/dev/null)")
else
	for wdm in /dev/cdc-wdm*; do
		[ -c "$wdm" ] || continue
		DEV="$wdm"
		DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$wdm")/device/driver" 2>/dev/null)")
		break
	done
fi

. /usr/share/5gmodem/iscompal.sh

case "$REQ" in
	auto|"")
		_mki_saved=$(uci -q get "5gmodem.$MSEC.iface_proto" 2>/dev/null)
		[ "$USERARG" = user ] && _mki_saved=""
		if [ -n "$_mki_saved" ] && [ "$_mki_saved" != "auto" ] \
		   && [ -f "/lib/netifd/proto/$_mki_saved.sh" ]; then
			PROTO="$_mki_saved"
			logger -t 5gmodem "mkiface: auto -> saved user choice ($_mki_saved)"
		elif soc_modem_node "$AMP" >/dev/null && [ -f /lib/netifd/proto/modemmanager.sh ]; then
			PROTO="modemmanager"
			logger -t 5gmodem "mkiface: $AMP is a built-in SoC modem - driving via ModemManager"
		else
		case "$DRV" in
			cdc_mbim) PROTO="mbim" ;;
			qmi_wwan) PROTO="qmi" ;;
			*)        PROTO="mbim" ;;
		esac
		_mki_vp=""
		[ -n "$AMP" ] && [ -f "/sys/bus/usb/devices/$AMP/idVendor" ] && \
			_mki_vp="$(cat "/sys/bus/usb/devices/$AMP/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$AMP/idProduct" 2>/dev/null)"
		_mki_cat=""
		if [ "$PROTO" = "qmi" ]; then
			case "$_mki_vp" in 05c6:*) _mki_cat=$(_mk_atport) ;; esac
		fi
		if [ "$PROTO" = "qmi" ] && [ -f /lib/netifd/proto/modemmanager.sh ] \
		   && is_compal "$AMP" "$DEV" "$_mki_cat"; then
			logger -t 5gmodem "mkiface: Compal RXM-G1 / SG500M2-X ($_mki_vp) - driving via ModemManager (uqmi cannot open its QMI services)"
			PROTO="modemmanager"
			MKI_COMPAL_MM=1
		fi
		case "$_mki_vp" in
			413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911|05c6:9025|03f0:9d1d)
				if [ -f /lib/netifd/proto/modemmanager.sh ]; then
					logger -t 5gmodem "mkiface: $_mki_vp - driving via ModemManager (shared channel, otherwise cdc-wdm contention)"
					PROTO="modemmanager"
				fi
				;;
			05c6:90d5)
				if [ -f /lib/netifd/proto/modemmanager.sh ] && ! is_compal "$AMP" "$DEV"; then
					logger -t 5gmodem "mkiface: 05c6:90d5 (Foxconn T99W175/T99W373, not Compal) - driving via ModemManager"
					PROTO="modemmanager"
				fi
				;;
		esac
			if [ "$PROTO" = "qmi" ] && [ -f /lib/netifd/proto/qmiraw.sh ]; then
				case "$_mki_vp" in
					1e0e:*) logger -t 5gmodem "mkiface: $_mki_vp - SimCom QMI: proto=qmiraw (802.3 without DHCP)"; PROTO="qmiraw" ;;
					1bc7:1070|1bc7:1077|1bc7:1080) logger -t 5gmodem "mkiface: $_mki_vp - Telit FN990 QMI: proto=qmiraw (radio on before SIM checks)"; PROTO="qmiraw" ;;
					19d2:1485) logger -t 5gmodem "mkiface: $_mki_vp - ZTE MF286D QMI: proto=qmiraw (stock qmi power-cycles a SIM that is still initializing)"; PROTO="qmiraw" ;;
					*)
						if [ -c "$DEV" ]; then
							_mki_fmt=$(uqmi -s -d "$DEV" -t 4000 --wda-get-data-format 2>/dev/null \
								| sed -n 's/.*"link-layer-protocol":"\([^"]*\)".*/\1/p' | head -1)
							if [ -z "$_mki_fmt" ]; then
								_mki_to=""
								command -v timeout >/dev/null 2>&1 && _mki_to="timeout 5"
								_mki_fmt=$($_mki_to qmicli -p -d "$DEV" --wda-get-data-format 2>/dev/null \
									| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
							fi
							if [ "$_mki_fmt" = "raw-ip" ]; then
								logger -t 5gmodem "mkiface: $_mki_vp - modem is natively raw-ip: proto=qmiraw (raw-ip + static)"
								PROTO="qmiraw"
							fi
						fi
						;;
				esac
			fi
		fi
		;;
	*) PROTO="$REQ" ;;
esac

_MM_WANT=0
if [ "$PROTO" = "mbimp" ]; then
	_mki_wdrv=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "${DEV:-none}")/device/driver" 2>/dev/null)" 2>/dev/null)
	if [ "$_mki_wdrv" != "cdc_mbim" ]; then
		logger -t 5gmodem "mkiface: MBIM+MM needs an MBIM control channel (driver cdc_mbim), but ${DEV:-the modem} is on ${_mki_wdrv:-no cdc-wdm node} - not creating the interface"
		printf '{"result":"MBIM+MM needs an MBIM composition, this modem is on %s","proto":"mbimp"}\n' "${_mki_wdrv:-no cdc-wdm node}"
		exit 1
	fi
fi
[ "$PROTO" = "modemmanager" ] && _MM_WANT=1
proto_in proxy "$PROTO" && [ -f /lib/netifd/proto/modemmanager.sh ] && _MM_WANT=1
[ "$_MM_WANT" = "1" ] || /usr/share/5gmodem/mmneed.sh check 2>/dev/null | grep -q '"needed":1' && _MM_WANT=1
if [ "$_MM_WANT" = "1" ]; then
	/etc/init.d/modemmanager enable >/dev/null 2>&1
	if ! pgrep -f ModemManager >/dev/null 2>&1; then
		mm_restart_safe
	elif [ "$PROTO" = "modemmanager" ] && ! mmcli -L 2>/dev/null | grep -q "/Modem/"; then
		mm_restart_safe
	fi
elif proto_in direct "$PROTO" || uci show network 2>/dev/null | grep -qE "\.proto='($(proto_re direct))'"; then
	/etc/init.d/modemmanager stop >/dev/null 2>&1
	/etc/init.d/modemmanager disable >/dev/null 2>&1
fi

ATP=$(_mk_atport)

if [ "$PROTO" = modemmanager ]; then
	IDEV=$(readlink -f "/sys/class/usbmisc/$(basename "${DEV:-cdc-wdm0}")/device" 2>/dev/null)
	while [ -n "$IDEV" ] && [ "$IDEV" != "/" ] && [ ! -f "$IDEV/idVendor" ]; do
		IDEV=$(dirname "$IDEV")
	done
	[ -f "$IDEV/idVendor" ] || IDEV=""
	if [ -z "$IDEV" ] && soc_modem_node "$AMP" >/dev/null; then
		IDEV=qcom-soc
	fi
elif proto_in wdm "$PROTO"; then
	IDEV="$DEV"
elif proto_in serial "$PROTO"; then
	IDEV="$ATP"
else
	IDEV="${DEV:-$ATP}"
fi

[ -n "$IDEV" ] || {
	if [ -n "$AMP" ] && ! usb_path_present "$AMP"; then
		logger -t 5gmodem "mkiface: $AMP is gone from the bus - not creating an interface for proto '$PROTO'"
	else
		logger -t 5gmodem "mkiface: cannot create interface for proto '$PROTO': no control device (cdc-wdm='$DEV', at-port='$ATP', modem path='$AMP')"
	fi
	json nomodem "$PROTO" ""
	exit 1
}

ctrl_devpath() { readlink -f "/sys/class/usbmisc/$(basename "${1:-}")/device" 2>/dev/null; }

OLDAPN=$(uci -q get "network.$IF.apn")
OLDAUTH=$(uci -q get "network.$IF.auth")
[ -n "$OLDAUTH" ] || OLDAUTH=$(uci -q get "network.$IF.allowedauth")
OLDUSER=$(uci -q get "network.$IF.username")
OLDPASS=$(uci -q get "network.$IF.password")
OLDPDP=$(uci -q get "network.$IF.pdptype")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.pdp")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.iptype")
OLDROAM=$(uci -q get "network.$IF.allow_roaming")
OLDMETRIC=$(uci -q get "network.$IF.metric")
OLDDNS=$(uci -q get "network.$IF.dns")
OLDFORCE=$(uci -q get "network.$IF.force_connection")
OLDEPS=$(uci -q get "network.$IF.init_epsbearer")
OLDEPS_APN=$(uci -q get "network.$IF.init_apn")
OLDEPS_IPT=$(uci -q get "network.$IF.init_iptype")
OLDEPS_AUTH=$(uci -q get "network.$IF.init_allowedauth")
OLDEPS_USER=$(uci -q get "network.$IF.init_username")
OLDEPS_PASS=$(uci -q get "network.$IF.init_password")
_mk_guard_if "$IF"
_mk_keep_save "$IF"
uci -q delete "network.$IF" 2>/dev/null
uci set "network.$IF=interface"
uci set "network.$IF.proto=$PROTO"
[ -f "/lib/netifd/proto/$PROTO.sh" ] || logger -t 5gmodem "mkiface: protocol $PROTO has no handler on this router (/lib/netifd/proto/$PROTO.sh is missing) - the interface will not come up until its package is installed (mbim: umbim, qmi: uqmi)"
uci set "network.$IF.device=$IDEV"
set_apn_opt "$IF" "$OLDAPN"
case "$PROTO" in
	modemmanager)
		set_pdp_opt "$IF" iptype
		[ "$MKI_COMPAL_MM" = "1" ] && uci set "network.$IF.force_connection=1"
		[ -n "$OLDFORCE" ] && uci set "network.$IF.force_connection=$OLDFORCE"
		[ -n "$OLDEPS" ] && uci set "network.$IF.init_epsbearer=$OLDEPS"
		[ -n "$OLDEPS_APN" ] && uci set "network.$IF.init_apn=$OLDEPS_APN"
		[ -n "$OLDEPS_IPT" ] && uci set "network.$IF.init_iptype=$OLDEPS_IPT"
		[ -n "$OLDEPS_AUTH" ] && uci set "network.$IF.init_allowedauth=$OLDEPS_AUTH"
		[ -n "$OLDEPS_USER" ] && uci set "network.$IF.init_username=$OLDEPS_USER"
		[ -n "$OLDEPS_PASS" ] && uci set "network.$IF.init_password=$OLDEPS_PASS"
		[ "$(uci -q get "network.$IF.iptype")" = "ipv4v6" ] \
			&& ! soc_modem_node "$AMP" >/dev/null \
			&& [ -z "$(uci -q get "network.$IF.init_epsbearer")" ] \
			&& uci set "network.$IF.init_epsbearer=default"
		;;
	xmm)
		set_pdp_opt "$IF" pdp
		uci set "network.$IF.auth=none"
		;;
	*)
		if proto_in wdm "$PROTO"; then
			set_pdp_opt "$IF" pdptype
			uci set "network.$IF.auth=none"
			_mdp=$(ctrl_devpath "$IDEV")
			[ -n "$_mdp" ] && [ -d "$_mdp/usbmisc" ] && uci set "network.$IF.devpath=$_mdp"
		elif proto_in serial "$PROTO" && [ "$PROTO" != ppp ]; then
			uci set "network.$IF.auth=none"
		fi
		;;
esac
[ -n "$OLDROAM" ] && uci set "network.$IF.allow_roaming=$OLDROAM"
if [ -n "$OLDAUTH" ]; then
	if [ "$PROTO" = "modemmanager" ]; then
		uci set "network.$IF.allowedauth=$OLDAUTH"
	else
		uci set "network.$IF.auth=$OLDAUTH"
	fi
fi
[ -n "$OLDUSER" ] && uci set "network.$IF.username=$OLDUSER"
[ -n "$OLDPASS" ] && uci set "network.$IF.password=$OLDPASS"
uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
[ -n "$OLDDNS" ] && uci set "network.$IF.dns=$OLDDNS"
_mk_keep_restore "$IF"
uci commit network

# netifd holds the old section in memory; see docs/subsystems/interfaces.md#netifd-reload-after-recreate
ubus call network reload >/dev/null 2>&1

if proto_in proxy "$PROTO"; then
	if ! ubus call network get_proto_handlers 2>/dev/null | grep -q "\"$PROTO\""; then
		logger -t 5gmodem "mkiface: protocol MBIM+MM is not registered with netifd yet - restarting the network to register it (interfaces will briefly drop)"
		/etc/init.d/network restart >/dev/null 2>&1
	fi
elif proto_in own "$PROTO"; then
	REGISTER_PROTO_FORCE=1 /usr/share/5gmodem/register_proto.sh >/dev/null 2>&1
fi

if ! proto_in own "$PROTO"; then
	if [ -n "$PROTO" ] && [ -f "/lib/netifd/proto/$PROTO.sh" ] \
	   && ! ubus call network get_proto_handlers 2>/dev/null | grep -q "\"$PROTO\""; then
		logger -t 5gmodem "mkiface: proto $PROTO was installed after netifd started - restarting the network to register it (interfaces will briefly drop)"
		/etc/init.d/network restart >/dev/null 2>&1
	fi
fi

_fw_zone_add "$IF"

if [ "$MKIFACE_AUTOFALLBACK" = "1" ]; then
	if [ "$_IS_ACTIVE" = 1 ]; then
		uci -q set "5gmodem.@5gmodem[0].network=$IF"
		uci -q delete "5gmodem.@5gmodem[0].iface_proto" 2>/dev/null
	fi
elif [ "$_IS_ACTIVE" = 1 ]; then
	uci -q set "5gmodem.@5gmodem[0].network=$IF"
	uci -q set "5gmodem.@5gmodem[0].iface_proto=$REQ"
fi
if [ -n "$MSEC" ]; then
	if ! uci -q get "5gmodem.$MSEC" >/dev/null 2>&1; then
				uci -q set "5gmodem.$MSEC=modem"
				uci -q set "5gmodem.$MSEC.path=$AMP"
				_mk_lm=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
				_mk_vp=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].vidpid" 2>/dev/null | head -1)
				_mk_pr=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].product" 2>/dev/null | head -1)
				[ -n "$_mk_vp" ] && uci -q set "5gmodem.$MSEC.vidpid=$_mk_vp"
				[ -n "$_mk_pr" ] && uci -q set "5gmodem.$MSEC.product=$_mk_pr"
			fi
	uci -q set "5gmodem.$MSEC.network=$IF"
	if [ "$MKIFACE_AUTOFALLBACK" = "1" ]; then
		uci -q delete "5gmodem.$MSEC.iface_proto" 2>/dev/null
	else
		uci -q set "5gmodem.$MSEC.iface_proto=$REQ"
	fi
	uci -q delete "5gmodem.$MSEC.foreign_iface" 2>/dev/null
fi
stamp_iface "$IF" "$AMP"
uci -q commit 5gmodem

if uci -q get 5gmodem.sms >/dev/null 2>&1; then
	if proto_in mm "$PROTO"; then
		uci -q set "5gmodem.sms.sms_via_mm=1"
		uci -q set "5gmodem.sms.ussd_via_mm=1"
	else
		uci -q set "5gmodem.sms.sms_via_mm=0"
		uci -q set "5gmodem.sms.ussd_via_mm=0"
	fi
	uci -q commit 5gmodem
fi

if [ -n "$DEV" ] && command -v qmicli >/dev/null 2>&1 && is_compal "$AMP" "$DEV"; then
	for c in 0 1 2 3 none; do
		qmicli -p -d "$DEV" \
			--wms-set-routes="type=point,class=$c,storage=uim,receipt-action=store-and-notify" \
			>/dev/null 2>&1
	done
fi

if [ -n "$MSEC" ]; then
	if proto_in mm "$PROTO"; then
		uci -q set "5gmodem.$MSEC.mm_exclude=0"
	else
		case "$MMEXCLARG" in
			0|1) uci -q set "5gmodem.$MSEC.mm_exclude=$MMEXCLARG" ;;
			*)   uci -q set "5gmodem.$MSEC.mm_exclude=1" ;;
		esac
	fi
	uci -q commit 5gmodem
	if proto_in mm "$PROTO" && [ -n "$AMP" ]; then
		_mki_ipf="/var/run/5gmodem-mm-inhibit/$AMP.pid"
		[ -f "$_mki_ipf" ] && { kill "$(cat "$_mki_ipf" 2>/dev/null)" 2>/dev/null; rm -f "$_mki_ipf"; }
	fi
	/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 7>&- 8>&- 9>&- &
fi

if [ "$PROTO" = "modemmanager" ]; then
	(
		_n=0
		while [ "$_n" -lt 120 ]; do
			mmcli -L 2>/dev/null | grep -q "/Modem/" && break
			sleep 2; _n=$((_n + 2))
		done
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null 7>&- 8>&- 9>&- &
elif proto_in direct "$PROTO"; then
	(
		kernel_proto_prepare "$IDEV" "$AMP" || logger -t 5gmodem-mkiface \
			"kernel_proto_prepare failed for $IF ($PROTO) - bringing it up anyway"
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null 7>&- 8>&- 9>&- &
elif [ "$PROTO" = xmm ] || [ "$PROTO" = atc ]; then
	(
		_xr_at=$(_mk_atport)
		if [ -n "$_xr_at" ] && [ -e "$_xr_at" ]; then
			_xr_n=0
			while [ "$_xr_n" -lt 90 ]; do
				_xr_o=$(sms_tool -d "$_xr_at" at "AT+CEREG?;+CGREG?;+COPS?" 2>/dev/null | tr -d '\r')
				case "$_xr_o" in
					*"+CEREG: "*",1"*|*"+CEREG: "*",5"*|*"+CGREG: "*",1"*|*"+CGREG: "*",5"*)
						logger -t 5gmodem-mkiface "$IF ($PROTO): modem registered after ${_xr_n}s - dialing"
						break ;;
				esac
				case "$_xr_o" in
					*"+COPS: 2"*)
						logger -t 5gmodem-mkiface "$IF ($PROTO): modem was deregistered (+COPS: 2) - nudging AT+COPS=0"
						sms_tool -d "$_xr_at" at "AT+COPS=0" >/dev/null 2>&1 ;;
				esac
				sleep 5; _xr_n=$((_xr_n + 5))
			done
			[ "$_xr_n" -ge 90 ] && logger -t 5gmodem-mkiface \
				"$IF ($PROTO): no registration in 90 s, bringing the interface up anyway"
		fi
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null 7>&- 8>&- 9>&- &
else
	ifup "$IF" >/dev/null 2>&1
fi

json created "$PROTO" "$IDEV"
exit 0
