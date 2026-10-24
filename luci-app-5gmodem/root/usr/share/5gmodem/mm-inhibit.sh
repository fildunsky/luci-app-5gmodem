#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null
. /usr/share/5gmodem/iscompal.sh 2>/dev/null
. /usr/share/5gmodem/quirks.sh 2>/dev/null

RES=/usr/share/5gmodem
CFG=5gmodem
RUN=/var/run/5gmodem-mm-inhibit
mkdir -p "$RUN"

_is_kernel_proto() {
	proto_in nomm "$1"
}

_proto_for_path() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		NP=$(uci -q get "network.$IF.proto")
		[ -n "$NP" ] && { echo "$NP"; return; }
	fi
	uci -q get "$CFG.$SEC.iface_proto"
}

_mm_excluded() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	case "$(uci -q get "$CFG.$SEC.mm_exclude")" in
		0) return 1 ;;
		1) return 0 ;;
	esac
	[ "$(uci -q get "$CFG.$SEC.kind")" = hilink ] && return 0
	_is_kernel_proto "$(_proto_for_path "$1")"
}

inhibit_pass() {
	command -v mmcli >/dev/null 2>&1 || return 0

	for _ip_pf in "$RUN"/*.pid; do
		[ -f "$_ip_pf" ] || continue
		_ip_p="${_ip_pf##*/}"; _ip_p="${_ip_p%.pid}"
		[ -d "/sys/bus/usb/devices/$_ip_p" ] && continue
		kill "$(cat "$_ip_pf" 2>/dev/null)" 2>/dev/null
		rm -f "$_ip_pf"
	done

	_cur=$(pgrep -f '/usr/sbin/ModemManager' 2>/dev/null | head -1)
	_prev=$(cat "$RUN/.mmpid" 2>/dev/null)
	if [ -n "$_cur" ] && [ "$_cur" != "$_prev" ]; then
		for pf in "$RUN"/*.pid; do
			[ -f "$pf" ] || continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		done
		echo "$_cur" > "$RUN/.mmpid"
	fi

	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		DEV=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ -n "$DEV" ] || continue
		PATHID=$(basename "$DEV")
		case "$PATHID" in *-*) ;; *) continue ;; esac
		_mm_excluded "$PATHID" || continue
		if [ -f "$RUN/$PATHID.pause" ]; then
			pf="$RUN/$PATHID.pid"
			[ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
			continue
		fi
		pf="$RUN/$PATHID.pid"
		if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
			[ -z "$(find "$pf" -mmin +1 2>/dev/null)" ] && continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		fi
		setsid mmcli --inhibit-device="$DEV" >/dev/null 2>&1 &
		echo $! > "$pf"
		: > "$RUN/$PATHID.stolen"
	done
	for pf in "$RUN"/*.pid; do
		[ -f "$pf" ] || continue
		kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null || rm -f "$pf"
	done
	_restore_stolen
	_am=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	if [ -n "$_am" ]; then
		read -r _qr_up _qr_rest < /proc/uptime
		_qr_up=${_qr_up%%.*}
		case "$_QR_LAST" in ''|*[!0-9]*) _QR_LAST=0 ;; esac
		if [ $((_qr_up - _QR_LAST)) -ge 120 ] || [ "$_qr_up" -lt "$_QR_LAST" ]; then
			_QR_LAST=$_qr_up
			"$RES/qmi-recover.sh" recover "$_am" >/dev/null 2>&1
		fi
	fi
	"$RES/mmneed.sh" grace >/dev/null 2>&1
}

_mm_ifup_if_down() {
	local _p _sec _mif _lk
	_p="$1"
	_sec="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_mif=$(uci -q get "$CFG.$_sec.network"); [ -n "$_mif" ] || return 0
	[ "$(uci -q get "network.$_mif.proto")" = modemmanager ] || return 0
	ifstatus "$_mif" 2>/dev/null | grep -q '"up": true' && return 0
	ifstatus "$_mif" 2>/dev/null | grep -q '"pending": true' && return 0
	_lk="$RUN/$_p.ifup"
	[ -f "$_lk" ] && [ -z "$(find "$_lk" -mmin +5 2>/dev/null)" ] && return 0
	: > "$_lk"
	(
		_w=0
		while [ "$_w" -lt 120 ]; do
			for J in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
				_jd=$(mmcli -m "$J" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
				[ "$(basename "$_jd" 2>/dev/null)" = "$_p" ] || continue
				case "$(ifstatus "$_mif" 2>/dev/null)" in
					*'"up": true'*|*'"pending": true'*) rm -f "$_lk"; exit 0 ;;
				esac
				mm_ghost_bearer "$_mif" "$J"; [ $? = 1 ] || { rm -f "$_lk"; exit 0; }
				logger -t 5gmodem "MM discovered modem $_p - bringing up interface $_mif (netifd tore it down at boot before MM started)"
				: > "$_lk"
				ifup "$_mif"
				_c=0
				while [ "$_c" -lt 90 ]; do
					ifstatus "$_mif" 2>/dev/null | grep -q '"up": true' && break
					sleep 3; _c=$((_c + 3))
				done
				rm -f "$_lk"; exit 0
			done
			sleep 2; _w=$((_w + 2))
		done
		rm -f "$_lk"
	) >/dev/null 2>&1 </dev/null &
}

_mm_fix_atonly() {
	local _fp="$1" _fw _fwdm _fi I _d _fk _fstate _fmark _fnow _flast _fwait
	command -v mmcli >/dev/null 2>&1 || return 0
	_fwdm=""
	for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
		[ -e "$_fw" ] && { _fwdm="$_fw"; break; }
	done
	[ -n "$_fwdm" ] || return 0
	_fi=""
	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		_d=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ "$(basename "$_d" 2>/dev/null)" = "$_fp" ] && { _fi="$I"; break; }
	done
	[ -n "$_fi" ] || return 0
	_fk=$(mmcli -m "$_fi" -K 2>/dev/null)
	printf '%s\n' "$_fk" | grep -qE '^modem\.generic\.ports\.value\[[0-9]+\] *: *[A-Za-z0-9-]+ \((mbim|qmi)\)' && return 0
	_fstate=$(printf '%s\n' "$_fk" | sed -n 's/^modem\.generic\.state *: *//p')
	case "$_fstate" in connected|connecting|disconnecting) return 0 ;; esac
	_fmark="/tmp/5gmodem/mmfix_$(printf '%s' "$_fp" | tr -c 'A-Za-z0-9' '_')"
	_fnow=$(cut -d. -f1 /proc/uptime)
	_flast=$(cat "$_fmark" 2>/dev/null); case "$_flast" in ''|*[!0-9]*) _flast="" ;; esac
	[ -n "$_flast" ] && [ "$((_fnow - _flast))" -lt 300 ] && return 0
	printf '%s' "$_fnow" > "$_fmark" 2>/dev/null
	logger -t 5gmodem "MM assembled $_fp without a control port ($(basename "$_fwdm") exists) - rebuilding the modem"
	_mm_rebind "$_fp"
	return 0
}

_mm_rebind() {
	local _rb_p="$1" _fw _fwait
	printf '%s' "$_rb_p" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
	sleep 4
	printf '%s' "$_rb_p" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
	_fp="$_rb_p"
	_fw=""; _fwait=0
	while [ "$_fwait" -lt 40 ]; do
		for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
			[ -e "$_fw" ] && break 2
		done
		_fw=""; sleep 2; _fwait=$((_fwait + 2))
	done
	[ -n "$_fw" ] || { logger -t 5gmodem "rebuild of $_fp: control port did not come back within ${_fwait}s"; return 1; }
	sleep 3
	for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
		[ -e "$_fw" ] && mmcli --report-kernel-event="action=add,subsystem=usbmisc,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 2
	for _fw in /sys/bus/usb/devices/"$_fp":*/net/*; do
		[ -e "$_fw" ] && mmcli --report-kernel-event="action=add,subsystem=net,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 1
	for _fw in /sys/bus/usb/devices/"$_fp":*/ttyUSB* /sys/bus/usb/devices/"$_fp":*/tty/ttyUSB*; do
		[ -e "$_fw" ] || continue
		mm_tty_reserved "$(basename "$_fw")" && continue
		mmcli --report-kernel-event="action=add,subsystem=tty,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 10
	_mm_ifup_if_down "$_fp"
}

_compal_mm_only() {
	local _cm_path="$1" _cm_wdm="$2" _cm_vp="$3" _cm_key="$4" _cm_dev="" _cm_at=""
	[ -f "$RUN/$_cm_key.compal" ] && return 1
	[ -n "$_cm_wdm" ] && _cm_dev="/dev/$(basename "$_cm_wdm")"
	[ -c "$_cm_dev" ] || _cm_dev=""
	case "$_cm_vp" in
		05c6:*)
			_mm_probing "$_cm_path" || _cm_at=$("$RES/registry.sh" path "$_cm_path" 2>/dev/null \
				| jsonfilter -e '@.at_port' 2>/dev/null)
			;;
	esac
	is_compal "$_cm_path" "$_cm_dev" "$_cm_at" || return 0
	: > "$RUN/$_cm_key.compal" 2>/dev/null
	return 1
}

_mm_probing() {
	local _path="$1" _pp _fd _tgt _dp _mmpids
	_mmpids=$(pgrep -f '/usr/sbin/ModemManager' 2>/dev/null)
	[ -n "$_mmpids" ] || return 1
	for _pp in $_mmpids; do
		for _fd in /proc/"$_pp"/fd/*; do
			_tgt=$(readlink "$_fd" 2>/dev/null)
			case "$_tgt" in /dev/ttyUSB*|/dev/ttyACM*|/dev/cdc-wdm*|/dev/wdm*) ;; *) continue ;; esac
			for _dp in /sys/bus/usb/devices/"$_path":*/ttyUSB* \
				/sys/bus/usb/devices/"$_path":*/tty/ttyUSB* \
				/sys/bus/usb/devices/"$_path":*/ttyACM* \
				/sys/bus/usb/devices/"$_path":*/tty/ttyACM* \
				/sys/bus/usb/devices/"$_path":*/usbmisc/cdc-wdm* \
				/sys/bus/usb/devices/"$_path":*/usbmisc/wdm*; do
				[ -e "$_dp" ] && [ "/dev/${_dp##*/}" = "$_tgt" ] && return 0
			done
		done
	done
	return 1
}

mm_recover_missing() {
	local _rp _seen I _d _if _t _w _n _rb_mk _rb_now _rb_first _rb_cd _rb_last _rb_fail _rb_key _has_wdm _wdm_node _wdm_drv _sw_pro _sw_vp
	command -v mmcli >/dev/null 2>&1 || return 0
	pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1 || return 0
	for _rp in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_rp" in *-*) ;; *) continue ;; esac
		[ "$(_proto_for_path "$_rp")" = modemmanager ] || continue
		_seen=0
		for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
			_d=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
			[ "$(basename "$_d" 2>/dev/null)" = "$_rp" ] && { _seen=1; break; }
		done
		if [ "$_seen" = 0 ]; then
			_rb_key=$(printf '%s' "$_rp" | tr -c 'A-Za-z0-9' '_')
			_rb_mk="$RUN/$_rb_key.missing"
			_rb_fail="$RUN/$_rb_key.rebindfail"
			_rb_now=$(cut -d. -f1 /proc/uptime)
			[ -f "$_rb_fail" ] && continue
			_has_wdm=""; _wdm_node=""
			for _w in /sys/bus/usb/devices/"$_rp":*/usbmisc/cdc-wdm* \
				/sys/bus/usb/devices/"$_rp":*/usbmisc/wdm*; do
				[ -e "$_w" ] && { _has_wdm=1; _wdm_node="$_w"; break; }
			done
			_wdm_drv=""
			[ -n "$_wdm_node" ] && _wdm_drv=$(basename "$(readlink -f "${_wdm_node%/usbmisc/*}/driver" 2>/dev/null)" 2>/dev/null)
			case "$_wdm_drv" in
				qmi_wwan) _sw_pro="qmi" ;;
				cdc_mbim) _sw_pro="mbim" ;;
				*)        _sw_pro="" ;;
			esac
			_sw_vp=""
			[ -f "/sys/bus/usb/devices/$_rp/idVendor" ] && \
				_sw_vp="$(cat "/sys/bus/usb/devices/$_rp/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$_rp/idProduct" 2>/dev/null)"
			case "$_sw_pro:$_sw_vp" in
				qmi:413c:81d7|qmi:413c:81e0|qmi:413c:81e4|qmi:413c:81e6|qmi:413c:81d8|qmi:0489:e0b5|qmi:0489:e0b4|qmi:1bc7:1911)
					if [ ! -f "$RUN/$_rb_key.mmonly" ]; then
						: > "$RUN/$_rb_key.mmonly" 2>/dev/null
						logger -t 5gmodem "modem $_rp ($_sw_vp): ModemManager has not assembled it (yet), but this module only works under MM - NOT switching the interface to qmi, waiting for MM"
					fi
					continue
					;;
			esac
			if [ "$_sw_pro" = "mbim" ]; then
				case "$_sw_vp" in
					413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911|05c6:90d5)
						if [ ! -f "$RUN/$_rb_key.mmonly" ]; then
							: > "$RUN/$_rb_key.mmonly" 2>/dev/null
							logger -t 5gmodem "modem $_rp ($_sw_vp): ModemManager has not assembled it (yet), but this module only works under MM - NOT switching the interface to mbim, waiting for MM"
						fi
						continue
						;;
				esac
			fi
			if [ -n "$_has_wdm" ]; then
				[ -n "$_sw_pro" ] || continue
				if [ "$_sw_pro" = "qmi" ] && ! _compal_mm_only "$_rp" "$_wdm_node" "$_sw_vp" "$_rb_key"; then
					if [ ! -f "$RUN/$_rb_key.mmonly" ]; then
						: > "$RUN/$_rb_key.mmonly" 2>/dev/null
						logger -t 5gmodem "modem $_rp ($_sw_vp, SG500M2-X): ModemManager has not assembled it yet; this model requires ModemManager (uqmi cannot open its QMI services) - NOT switching the interface to qmi, waiting for MM"
					fi
					continue
				fi
				if [ ! -f "$RUN/$_rb_key.qmihint" ]; then
					cut -d. -f1 /proc/uptime > "$RUN/$_rb_key.qmihint" 2>/dev/null
					if [ "$_sw_pro" = "mbim" ] && ! _compal_mm_only "$_rp" "$_wdm_node" "$_sw_vp" "$_rb_key"; then
						continue
					fi
					logger -t 5gmodem "modem $_rp: ModemManager could not assemble it (no primary AT port), but it DOES have a control channel (cdc-wdm, driver $_wdm_drv) - switch the interface to proto $_sw_pro. NOT rebinding: it risks killing the device (config #1 error -71)."
					continue
				fi
				[ -f "$RUN/$_rb_key.qmiswitch" ] && continue
				pidof ModemManager >/dev/null 2>&1 || continue
				_mm_probing "$_rp" && continue
				_sw_t0=$(cat "$RUN/$_rb_key.qmihint" 2>/dev/null)
				case "$_sw_t0" in ''|*[!0-9]*) _sw_t0=0 ;; esac
				[ "$(( $(cut -d. -f1 /proc/uptime) - _sw_t0 ))" -ge 120 ] || continue
				_sw_sec="m_$_rb_key"
				_sw_p=$(uci -q get "5gmodem.$_sw_sec.iface_proto")
				[ -n "$_sw_p" ] || _sw_p=$(uci -q get 5gmodem.@5gmodem[0].iface_proto)
				[ "$_sw_p" = "auto" ] || continue
				_sw_if=$(uci -q get "5gmodem.$_sw_sec.network")
				[ -n "$_sw_if" ] || _sw_if=$(uci -q get 5gmodem.@5gmodem[0].network)
				[ -n "$_sw_if" ] || continue
				[ "$(uci -q get "network.$_sw_if.proto")" = "modemmanager" ] || continue
				: > "$RUN/$_rb_key.qmiswitch" 2>/dev/null
				logger -t 5gmodem "modem $_rp: MM never assembled it and the protocol is on auto - switching interface $_sw_if to proto $_sw_pro (cdc-wdm driver $_wdm_drv)"
				MKIFACE_AUTOFALLBACK=1 "$RES/mkiface.sh" "$_sw_if" "$_sw_pro" >/dev/null 2>&1
				continue
			fi
			if _mm_probing "$_rp"; then
				printf '%s' "$_rb_now" > "$_rb_mk" 2>/dev/null
				continue
			fi
			_rb_first=$(cat "$_rb_mk" 2>/dev/null)
			case "$_rb_first" in ''|*[!0-9]*) _rb_first="" ;; esac
			if [ -z "$_rb_first" ]; then
				printf '%s' "$_rb_now" > "$_rb_mk" 2>/dev/null
			elif [ "$((_rb_now - _rb_first))" -ge 150 ]; then
				_rb_cd="/tmp/5gmodem/mmrebind_$_rb_key"
				_rb_last=$(cat "$_rb_cd" 2>/dev/null)
				case "$_rb_last" in ''|*[!0-9]*) _rb_last="" ;; esac
				if [ -z "$_rb_last" ] || [ "$((_rb_now - _rb_last))" -ge 300 ]; then
					printf '%s' "$_rb_now" > "$_rb_cd" 2>/dev/null
					rm -f "$_rb_mk" 2>/dev/null
					logger -t 5gmodem "MM did not assemble modem $_rp after event replay - rebinding the device"
					if ! _mm_rebind "$_rp"; then
						: > "$_rb_fail" 2>/dev/null
						logger -t 5gmodem "rebind of $_rp did NOT bring the device back (usually config #1 error -71) - POWER OFF the router; the modem may need proto QMI instead of ModemManager"
					fi
					continue
				fi
			fi
			for _if in /sys/bus/usb/devices/"$_rp":*; do
				[ -d "$_if" ] || continue
				for _t in "$_if"/ttyUSB* "$_if"/tty/ttyUSB* "$_if"/tty/tty*; do
					[ -e "$_t" ] || continue
					mm_tty_reserved "$(basename "$_t")" && continue
					mmcli --report-kernel-event="action=add,subsystem=tty,name=$(basename "$_t")" >/dev/null 2>&1
				done
				for _w in "$_if"/usbmisc/cdc-wdm* "$_if"/usbmisc/wdm*; do
					[ -e "$_w" ] && mmcli --report-kernel-event="action=add,subsystem=usbmisc,name=$(basename "$_w")" >/dev/null 2>&1
				done
				for _n in "$_if"/net/*; do
					[ -e "$_n" ] && mmcli --report-kernel-event="action=add,subsystem=net,name=$(basename "$_n")" >/dev/null 2>&1
				done
			done
		fi
		[ "$_seen" = 1 ] && {
			_rb_key=$(printf '%s' "$_rp" | tr -c 'A-Za-z0-9' '_')
			rm -f "$RUN/$_rb_key.missing" "$RUN/$_rb_key.rebindfail" "$RUN/$_rb_key.qmihint" "$RUN/$_rb_key.mmonly" "$RUN/$_rb_key.compal" 2>/dev/null
			_mm_fix_atonly "$_rp"
		}
		_mm_ifup_if_down "$_rp"
	done
}

_restore_stolen() {
	for mf in "$RUN"/*.stolen; do
		[ -f "$mf" ] || continue
		[ -z "$(find "$mf" -mmin +1 2>/dev/null)" ] && continue
		PATHID=$(basename "$mf" .stolen)
		rm -f "$mf"
		SEC="m_$(echo "$PATHID" | sed 's/[^A-Za-z0-9]/_/g')"
		IF=$(uci -q get "$CFG.$SEC.network")
		[ -n "$IF" ] || continue
		_dead=""
		ATP=$(uci -q get "$CFG.$SEC.at_port")
		if [ -n "$ATP" ] && [ -c "$ATP" ] && command -v sms_tool >/dev/null 2>&1; then
			RAW=$(at_query "$ATP" "AT+CGACT?" 6)
			if echo "$RAW" | grep -q "OK"; then
				echo "$RAW" | grep -qE '\+CGACT: *[0-9]+, *1' && continue
				_dead="context is not active"
			fi
		fi
		if [ -z "$_dead" ]; then
			L3=$(ubus call "network.interface.$IF" status 2>/dev/null \
				| jsonfilter -e '@.l3_device' 2>/dev/null)
			[ -n "$L3" ] || continue
			ping -c 2 -W 4 -I "$L3" 77.88.8.8 >/dev/null 2>&1 && continue
			ping -c 2 -W 4 -I "$L3" 1.1.1.1 >/dev/null 2>&1 && continue
			if command -v curl >/dev/null 2>&1; then
				# see docs/subsystems/health-and-recovery.md#curl-interface-if-prefix
				curl -s --max-time 8 --interface "if!$L3" -o /dev/null \
					http://ip-api.com/line/?fields=query 2>/dev/null && continue
				_wl_ok=""
				for _wl_t in $(uci -q get 5gmodem.health.restricted_targets || echo 77.88.55.242 5.255.255.242); do
					curl -sk --max-time 5 --interface "if!$L3" -o /dev/null "https://$_wl_t/" 2>/dev/null && { _wl_ok=1; break; }
				done
				[ -n "$_wl_ok" ] && continue
			fi
			_dead="no connectivity via $L3"
		fi
		logger -t 5gmodem "MM took over $PATHID and left it without a data session ($_dead) - bringing up $IF"
		ifdown "$IF" >/dev/null 2>&1
		sleep 3
		ifup "$IF" >/dev/null 2>&1
	done
}

case "$1" in
set-exclude)
	[ -n "$2" ] || exit 0
	uci -q set "$CFG.$2.mm_exclude=${3:-1}"
	uci -q commit "$CFG"
	PATHID=$(uci -q get "$CFG.$2.path")
	if [ "${3:-1}" = "0" ] && [ -n "$PATHID" ]; then
		pf="$RUN/$PATHID.pid"
		[ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
	else
		inhibit_pass
	fi
	;;
once)  inhibit_pass; mm_recover_missing ;;
pause)   [ -n "$2" ] && { mkdir -p "$RUN"; : > "$RUN/$2.pause"; pf="$RUN/$2.pid"; [ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }; } ;;
resume)  [ -n "$2" ] && rm -f "$RUN/$2.pause" ;;
stop)  for pf in "$RUN"/*.pid; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; done ;;
*)
	_last_pid=""
	_n=99
	while :; do
		if [ ! -x /usr/sbin/ModemManager ]; then
			_last_pid=""; _n=99
			sleep 3
			continue
		fi
		_pid=""
		if [ -n "$_last_pid" ]; then
			_pc=""
			read -r _pc 2>/dev/null < "/proc/$_last_pid/comm"
			[ "$_pc" = ModemManager ] && _pid="$_last_pid"
		fi
		[ -n "$_pid" ] || _pid=$(pidof ModemManager 2>/dev/null)
		if [ "$_pid" != "$_last_pid" ] || [ "$_n" -ge 5 ]; then
			_last_pid="$_pid"
			_n=0
			inhibit_pass
			mm_recover_missing
		fi
		_n=$((_n + 1))
		sleep 3
	done
	;;
esac
