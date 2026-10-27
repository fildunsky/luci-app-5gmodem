#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem

[ -r "$RES/quirks.sh" ] && . "$RES/quirks.sh"

. /usr/share/5gmodem/lib.sh
. /usr/share/5gmodem/atlock.sh

active_path() { uci -q get "$CFG.@5gmodem[0].active_modem"; }

_RR_STAMP=""
_RR_PATH1=""; _RR_REC1=""
_RR_PATH2=""; _RR_REC2=""
_reg_rec() {
	[ -n "$1" ] || return 0
	_rr_s=$(cat /tmp/5gmodem/listmodems.stamp 2>/dev/null)
	if [ "$_rr_s" != "$_RR_STAMP" ]; then
		_RR_STAMP="$_rr_s"; _RR_PATH1=""; _RR_REC1=""; _RR_PATH2=""; _RR_REC2=""
	fi
	[ "$1" = "$_RR_PATH1" ] && [ -n "$_RR_REC1" ] && { printf '%s' "$_RR_REC1"; return 0; }
	[ "$1" = "$_RR_PATH2" ] && [ -n "$_RR_REC2" ] && { printf '%s' "$_RR_REC2"; return 0; }
	_RR_PATH2="$_RR_PATH1"; _RR_REC2="$_RR_REC1"
	_RR_PATH1="$1"; _RR_REC1=$("$RES/registry.sh" path "$1" 2>/dev/null)
	printf '%s' "$_RR_REC1"
}

modem_ttys() {
	_reg_rec "$1" | jsonfilter -e '@.tty[*]' 2>/dev/null
}
modem_product() {
	_reg_rec "$1" | jsonfilter -e '@.product' 2>/dev/null | head -1
}
modem_vidpid() {
	_reg_rec "$1" | jsonfilter -e '@.vidpid' 2>/dev/null | head -1
}

. "$RES/msw/identity.sh"
. "$RES/msw/iface.sh"
. "$RES/msw/apn.sh"
. "$RES/msw/hilink.sh"
. "$RES/msw/setup.sh"

at_probe() {
	. "$RES/noatports.sh"
	tty_no_at "$1" && return 1
	sms_tool -d "$1" at "AT" >/dev/null 2>&1 7>&- 8>&- 9>&- &
	_p=$!
	_n=0
	while kill -0 "$_p" 2>/dev/null; do
		_n=$((_n + 1))
		if [ "$_n" -ge 4 ]; then
			kill "$_p" 2>/dev/null
			sleep 1
			kill -0 "$_p" 2>/dev/null && return 1
			wait "$_p" 2>/dev/null
			return 1
		fi
		sleep 1
	done
	wait "$_p" 2>/dev/null
	return $?
}

detect_at() {
	for t in "$@"; do
		[ -e "$t" ] || continue
		case "$t" in /dev/ttyUSB*|/dev/ttyACM*|/dev/wwan*at*|/dev/ttyMTK*) ;; *) continue ;; esac
		if at_probe "$t"; then echo "$t"; return 0; fi
	done
	return 1
}

mm_index_for_path() {
	[ -n "$1" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	for m in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		_mk=$(mmcli -m "$m" -K 2>/dev/null)
		d=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.generic\.device *: *//p' | xargs)
		case "$d" in */"$1") echo "$m"; return 0 ;; esac
		case "$d" in
			/*) ;;
			*) d=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.generic\.physdev *: *//p' | xargs)
			   case "$d" in */"$1") echo "$m"; return 0 ;; esac ;;
		esac
	done
	return 1
}

wdm_for_path() {
	_reg_rec "$1" | jsonfilter -e '@.wdm[0]' 2>/dev/null
}

path_for_wdm() {
	local d
	d=$(readlink -f "/sys/class/usbmisc/$(basename "${1:-x}")/device" 2>/dev/null)
	while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -f "$d/idVendor" ]; do d=$(dirname "$d"); done
	[ -f "$d/idVendor" ] && basename "$d"
}

at_for_path() {
	mi=$(mm_index_for_path "$1")
	if [ -n "$mi" ]; then
		p=$(mmcli -m "$mi" 2>/dev/null | grep -oE '(ttyUSB[0-9]+|ttyACM[0-9]+) \(at\)' | sed 's/ (at)//' | head -1)
		[ -n "$p" ] && [ -e "/dev/$p" ] && { echo "/dev/$p"; return 0; }
	fi
	_afp_skip=$(dial_port_for_path "$1")
	if [ -z "$_afp_skip" ]; then
		if [ "$_AFP_SKIP_P" = "$1" ]; then
			_afp_skip="$_AFP_SKIP_V"
		else
			_afp_if=$(iface_for_path "$1")
			if [ -n "$_afp_if" ]; then
				proto_in dialtty "$(uci -q get "network.$_afp_if.proto")" \
					&& _afp_skip=$(uci -q get "network.$_afp_if.device")
			fi
			_AFP_SKIP_P="$1"
			_AFP_SKIP_V="$_afp_skip"
		fi
	fi
	_afp_at=$(_reg_rec "$1" | jsonfilter -e '@.at_port' 2>/dev/null)
	_afp_list=""
	[ -n "$_afp_at" ] && [ "$_afp_at" != "$_afp_skip" ] && _afp_list="$_afp_at"
	_afp_rest=""
	for _afp_t in $(modem_ttys "$1"); do
		[ "$_afp_t" = "$_afp_skip" ] && continue
		[ "$_afp_t" = "$_afp_at" ] && continue
		tty_poll_unsafe "$_afp_t" && continue
		if soc_modem_node "$1" >/dev/null; then
			_afp_rest="$_afp_t $_afp_rest"
		else
			_afp_rest="$_afp_rest $_afp_t"
		fi
	done
	_afp_list="$_afp_list $_afp_rest"
	detect_at $_afp_list && return 0
	for _afp_t in $(modem_ttys "$1"); do
		tty_poll_unsafe "$_afp_t" || continue
		at_probe "$_afp_t" || continue
		poll_send_mark "$1"
		echo "$_afp_t"
		return 0
	done
	return 1
}

mmk_val() {
	printf '%s\n' "$1" | sed -n "s/^$2 *: *//p" | head -1
}

mmk_imei() {
	_mki_v=$(mmk_val "$1" 'modem\.3gpp\.imei' | tr -cd '0-9')
	case "${#_mki_v}" in 14|15|16) echo "$_mki_v"; return 0 ;; esac
	_mki_v=$(mmk_val "$1" 'modem\.generic\.equipment-identifier' | tr -cd '0-9')
	case "${#_mki_v}" in 14|15|16) echo "$_mki_v"; return 0 ;; esac
	return 1
}

resolve_at_gate() {
	_RG_QUIET=0; _RG_NEVER=0; _RG_PORT=""; _RG_MM=""; _RG_MMK=""
	_rg_frag=""
	command -v mm_at_fragile >/dev/null 2>&1 && _rg_frag=$(mm_at_fragile "$(modem_vidpid "$1")" "$1")
	_rg_noat=$(uci -q get "$CFG.$2.no_at")
	[ -n "$_rg_frag" ] || [ "$_rg_noat" = "1" ] || return 0
	_RG_MM=$(mm_index_for_path "$1")
	[ -n "$_RG_MM" ] && _RG_MMK=$(mmcli -m "$_RG_MM" -K 2>/dev/null)
	if [ "$_rg_noat" = "1" ]; then
		_RG_QUIET=1
		[ -n "$_RG_MM" ] && _RG_NEVER=1
		return 0
	fi
	_rg_if=$(uci -q get "$CFG.$2.network")
	[ -n "$_RG_MM" ] || [ "$(uci -q get "network.$_rg_if.proto" 2>/dev/null)" = "modemmanager" ] || return 0
	mm_at_allowed "$1" "$2"
	if [ "$?" = 0 ]; then
		[ -n "$MM_AT_PORT" ] || return 0
		_RG_PORT="$MM_AT_PORT"
		_RG_QUIET=1
		return 0
	fi
	_RG_QUIET=1; _RG_NEVER=1
	return 0
}

quiet_at_port() {
	[ -n "$_RG_PORT" ] && [ -c "$_RG_PORT" ] && { echo "$_RG_PORT"; return 0; }
	_qa_pin=$(uci -q get "$CFG.$2.at_port")
	if [ -n "$_qa_pin" ] && [ -e "$_qa_pin" ] && ! tty_poll_unsafe "$_qa_pin" && modem_ttys "$1" | grep -qxF "$_qa_pin"; then
		echo "$_qa_pin"; return 0
	fi
	_qa_if=$(uci -q get "$CFG.$2.at_if")
	if [ -n "$_qa_if" ]; then
		for _qa_d in /sys/bus/usb/devices/"$1":*; do
			[ "$(cat "$_qa_d/bInterfaceNumber" 2>/dev/null)" = "$_qa_if" ] || continue
			for _qa_n in "$_qa_d"/ttyUSB* "$_qa_d"/tty/tty*; do
				[ -e "$_qa_n" ] || continue
				[ -c "/dev/${_qa_n##*/}" ] || continue
				echo "/dev/${_qa_n##*/}"; return 0
			done
		done
	fi
	if [ -n "$_RG_MMK" ]; then
		_qa_p=$(printf '%s\n' "$_RG_MMK" \
			| sed -n 's/^modem\.generic\.ports\.value\[[0-9]*\] *: *\(tty[A-Za-z]*[0-9]*\) *(at)$/\1/p' | head -1)
		[ -n "$_qa_p" ] && [ -e "/dev/$_qa_p" ] && { echo "/dev/$_qa_p"; return 0; }
	fi
	return 1
}

quiet_ident_known() {
	[ -n "$2" ] && [ -n "$3" ] && [ "$2" != "$3" ] && return 1
	[ "$(uci -q get "$CFG.$1.ident_probe")" = "$(uci -q get "$CFG.$1.vidpid")|$3" ] && return 0
	[ -n "$(uci -q get "$CFG.$1.imei" | tr -cd '0-9')" ] || return 1
	[ -n "$(uci -q get "$CFG.$1.model")" ] || [ -n "$(uci -q get "$CFG.$1.at_port")" ]
}

save_to() {
	SEC=$(secname "$1")
	uci -q get "$CFG.$SEC" >/dev/null 2>&1 || SEC=$(ensure_section "$1")
	uci -q set "$CFG.$SEC.at_port=$(uci -q get "$CFG.@5gmodem[0].at_port")"
	uci -q commit "$CFG"
}

HILINK_IDS="12d1:14dc 12d1:14db 1bbb:0196 19d2:0581"

_esim_state() {
	_ee=$(uci -q get "$CFG.$1.esim_show")
	case "$_ee" in
		1) echo "forced-yes"; return ;;
		0) echo "forced-no";  return ;;
	esac
	_ec="/tmp/5gmodem/esimstat_$2"
	[ -s "$_ec" ] || return 0
	if grep -q '"available":1' "$_ec" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

case "$1" in
active)
	active_path
	;;

smsopt)
	shift
	_ch=0; _st_ch=0
	for _kv in "$@"; do
		_k=${_kv%%=*}; _v=${_kv#*=}
		case "$_k" in
			readport|sendport|ussdport|atport)
				[ -z "$_v" ] || is_devpath "$_v" || continue ;;
			sms_count|sms_count_index)
				_okc=1
				for _t in $_v; do
					case "$_t" in
						dfm[0-9]*_[0-9]*) case "${_t#dfm}" in *[!0-9_]*|*_*_*|_*|*_) _okc="" ;; esac ;;
						*) is_num "$_t" || _okc="" ;;
					esac
				done
				[ -n "$_okc" ] || continue
				_v=$(echo $_v) ;;
			information|mergesms|mergesms_auto)
				[ -z "$_v" ] || is_num "$_v" || continue ;;
			storage)
				case "$_v" in *[!A-Za-z]*) continue ;; esac ;;
			*) continue ;;
		esac
		_cur=$(uci -q get "5gmodem.sms.$_k")
		[ "$_cur" = "$_v" ] && continue
		uci -q set "5gmodem.sms.$_k=$_v"
		_ch=1
		[ "$_k" = storage ] && { _st_ch=1; _st_v="$_v"; }
	done
	[ "$_ch" = 1 ] && uci -q commit 5gmodem
	if [ "$_st_ch" = 1 ]; then
		_so_p=$(uci -q get 5gmodem.sms.readport)
		[ -n "$_so_p" ] || _so_p=$(uci -q get 5gmodem.sms.atport)
		rm -f /tmp/5gmodem/cpms_* 2>/dev/null
		[ -c "$_so_p" ] && ( sms_apply_cpms "$_so_p" "$_st_v" ) >/dev/null 2>&1 </dev/null &
	fi
	printf '{"changed":%s}\n' "$_ch"
	;;

ackswap)
	[ -n "$2" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q delete "$CFG.$2.imei_changed" 2>/dev/null
	uci -q delete "$CFG.$2.imei_prev" 2>/dev/null
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;

hidenumberhint)
	uci -q set "5gmodem.sms.information=0"
	uci -q commit 5gmodem
	echo '{"result":"ok"}'
	;;

ussdsupport)
	_p=$(active_path)
	_s=$(secname "$_p")
	_us_at=$(uci -q get "$CFG.$_s.at_port")
	if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
	   && ! { [ -n "$_us_at" ] && [ -c "$_us_at" ]; }; then
		printf '{"supported":0,"reason":"no_at_port","model":"%s"}\n' \
			"$(uci -q get "$CFG.$_s.model")"
		exit 0
	fi
	_v=""
	command -v ussd_supported_for >/dev/null 2>&1 && _v=$(ussd_supported_for \
		"$(uci -q get "$CFG.$_s.model")" "$(uci -q get "$CFG.$_s.vidpid")")

	_snap=$("$RES/5gmodem.sh" peek 2>/dev/null)
	_reg=$(printf '%s' "$_snap" | jsonfilter -e '@.registration_cs' 2>/dev/null)
	_smsonly=0
	case "$_reg" in
		6|7) _smsonly=1 ;;
	esac

	_rat=$(printf '%s' "$_snap" | jsonfilter -e '@.mode' 2>/dev/null)

	printf '{"supported":%s,"sms_only":%s,"registration":"%s","rat":"%s","model":"%s"}\n' \
		"${_v:-1}" "$_smsonly" "$_reg" "$_rat" "$(uci -q get "$CFG.$_s.model")"
	;;

save)
	[ -n "$2" ] || { echo '{"error":"no path"}'; exit 1; }
	save_to "$2"
	echo '{"result":"saved"}'
	;;

switch)
	note_foreign_uci network "modemswitch switch"
	P="$2"
	_sw_list=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null)
	if [ -n "$P" ] && [ -n "$_sw_list" ] && ! printf '%s\n' "$_sw_list" | grep -qxF "$P"; then
		logger -t 5gmodem "switch: \"$P\" is not a modem (not in the list) - not making it active"
		printf '{"error":"not a modem","path":"%s"}\n' "$P"
		exit 0
	fi
	[ -n "$P" ] || { echo '{"error":"no path"}'; exit 1; }

	CUR=$(active_path)
	[ -n "$CUR" ] && [ "$CUR" != "$P" ] && save_to "$CUR"

	SEC=$(ensure_section "$P")

	SAVED=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$SAVED" ] && [ -e "$SAVED" ] && ! tty_poll_unsafe "$SAVED" && modem_ttys "$P" | grep -qxF "$SAVED"; then
		ATP="$SAVED"
	else
		ATP=$(at_for_path "$P")
	fi

	uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	uci -q set "$CFG.@5gmodem[0].preferred_modem=$P"

	if [ -n "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
	else
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi
	NET=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$NET" ]; then
		fix_iface_proto "$NET"
		_np=$(uci -q get "network.$NET.proto")
		case "$(uci -q get "$CFG.$SEC.iface_proto")" in
			mbim|qmi)
				case "$_np" in
					mbim|qmi) uci -q set "$CFG.$SEC.iface_proto=$_np" ;;
				esac
				;;
		esac
		uci -q set "$CFG.@5gmodem[0].network=$NET"
	else
		uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
	fi
	PRO=$(uci -q get "$CFG.$SEC.iface_proto")
	if [ -n "$PRO" ]; then
		uci -q set "$CFG.@5gmodem[0].iface_proto=$PRO"
	else
		uci -q delete "$CFG.@5gmodem[0].iface_proto" 2>/dev/null
	fi
	uci -q commit "$CFG"

	if [ -n "$ATP" ] && uci -q get 5gmodem.sms >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q set "5gmodem.sms.$k=$ATP"
		done
		apply_ussd_quirk "$SEC"
		uci -q commit 5gmodem
		set_sms_storage "$ATP"
	elif [ -z "$ATP" ] && uci -q get 5gmodem.sms >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q delete "5gmodem.sms.$k" 2>/dev/null
		done
		uci -q commit 5gmodem
	fi

	rm -f /tmp/5gmodem/modem

	_pw=/tmp/5gmodem/prewarm.pid
	_pwold=$(cat "$_pw" 2>/dev/null)
	case "$_pwold" in *[!0-9]*|'') ;; *)
		if kill -0 "$_pwold" 2>/dev/null \
		   && grep -q 5gmodem_prewarm "/proc/$_pwold/cmdline" 2>/dev/null; then
			kill -- "-$_pwold" 2>/dev/null
		fi ;;
	esac
	setsid sh -c '
	  # 5gmodem_prewarm - маркер для проверки перед kill
	  /usr/share/5gmodem/simslot.sh status >/dev/null 2>&1
	  /usr/share/5gmodem/bands.sh   json   >/dev/null 2>&1
	  [ "$(cat /tmp/5gmodem/prewarm.pid 2>/dev/null)" = "$$" ] && rm -f /tmp/5gmodem/prewarm.pid
	' 5gmodem_prewarm >/dev/null 2>&1 </dev/null &
	echo $! > "$_pw" 

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

mkhilink)
	note_foreign_uci network "modemswitch mkhilink"
	note_foreign_uci firewall "modemswitch mkhilink"
	_p="$2"
	[ -n "$_p" ] || _p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_k=hilink
	if ! is_hilink "$_p"; then
		is_tether "$_p" || { echo '{"error":"not a hilink modem"}'; exit 0; }
		_k=tether
	fi
	if [ "$_k" = tether ]; then _d=$(tether_netdev "$_p"); else _d=$(hilink_netdev "$_p"); fi
	[ -n "$_d" ] || { echo '{"error":"no network card"}'; exit 0; }
	_r=$(setup_hilink "$_p" "$_d" "$_k")
	printf '{"success":true,"iface":"%s","netdev":"%s"}\n' "$_r" "$_d"
	exit 0
	;;

profiles)
	_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
	_act=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_dump=$(uci -q show "$CFG" 2>/dev/null)
	_ifaces=" $(printf '%s\n' "$_dump" | sed -n "s/^$CFG\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | tr '\n' ' ') "
	printf '['
	_first=1
	_bf=""
	for _sec in $(printf '%s\n' "$_dump" | sed -n 's/^'"$CFG"'\.\(m_[^.]*\)=modem$/\1/p'); do
		case "$_sec" in m_park_*) continue ;; esac
		_ss=$(uci_sec_snap "$CFG" "$_sec")
		_pg() { uci_sec_val "$_ss" "$CFG.$_sec" "$1"; }
		[ "$(_pg parked)" = "1" ] && continue
		_p=$(_pg path)
		if [ -z "$_p" ]; then
			_p=$(echo "${_sec#m_}" | sed 's/_/-/;s/_/./g')
			[ -n "$_p" ] && { uci -q set "$CFG.$_sec.path=$_p"; _bf=1; }
		fi
		[ -n "$_p" ] || continue
		_if=$(_pg network)
		_proto=""; _apn=""; _pdp=""
		if [ -n "$_if" ]; then
			_ns=$(uci_sec_snap network "$_if")
			_proto=$(uci_sec_val "$_ns" "network.$_if" proto)
			_apn=$(uci_sec_val "$_ns" "network.$_if" apn)
			_pdp=$(uci_sec_val "$_ns" "network.$_if" pdptype)
		fi
		[ -n "$_proto" ] || _proto=$(_pg iface_proto)
		_on=0
		case " $_present " in *" $_p "*) _on=1 ;; esac
		_shared=0
		if [ -n "$_if" ]; then
			_n=0
			for _x in $_ifaces; do
				[ "$_x" = "$_if" ] && _n=$((_n + 1))
			done
			[ "$_n" -gt 1 ] && _shared=1
		fi
		[ "$_first" = 1 ] || printf ','
		_first=0
		_kind=$(_pg kind)
		printf '{"sec":"%s","path":"%s","model":"%s","imei":"%s","iface":"%s","proto":"%s","apn":"%s","pdptype":"%s","present":%d,"active":%d,"iface_shared":%d,"celllock":"%s","mm_exclude":"%s","vidpid":"%s","kind":"%s","netdev":"%s","webaddr":"%s","esim":"%s","save_band":"%s","save_band5gnsa":"%s","save_band5gsa":"%s"}' \
			"$_sec" "$_p" \
			"$(json_esc "$(_pg model)")" \
			"$(_pg imei)" \
			"$_if" "$_proto" "$(json_esc "$_apn")" "$_pdp" "$_on" \
			"$([ "$_p" = "$_act" ] && echo 1 || echo 0)" "$_shared" \
			"$(json_esc "$(_pg celllock)")" \
			"$(_pg mm_exclude)" \
			"$(_pg vidpid)" \
			"$_kind" \
			"$(json_esc "$(_pg netdev)")" \
			"$(json_esc "$([ "$_kind" = "hilink" ] && "$RES/hilink.sh" addr "$_p" 2>/dev/null)")" \
			"$(json_esc "$(_esim_state "$_sec" "$_p")")" \
			"$(_pg save_band)" \
			"$(_pg save_band5gnsa)" \
			"$(_pg save_band5gsa)"
	done
	printf ']\n'
	[ -n "$_bf" ] && uci -q commit "$CFG"
	exit 0
	;;
delprofile)
	note_foreign_uci network "modemswitch delprofile"
	_sec="$2"
	[ -n "$_sec" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q get "$CFG.$_sec" >/dev/null 2>&1 || { echo '{"error":"not found"}'; exit 0; }
	_p=$(uci -q get "$CFG.$_sec.path")
	_if=$(uci -q get "$CFG.$_sec.network")
	_killed=""
	if [ -n "$_if" ]; then
		_n=$(uci -q show "$CFG" 2>/dev/null | grep -c "^$CFG\.m_[^.]*\.network='\?$_if'\?\$")
		if [ "${_n:-0}" -le 1 ]; then
			ifdown "$_if" >/dev/null 2>&1
			uci -q delete "network.$_if"
			uci -q commit network
			_killed="$_if"
		fi
	fi
	uci -q delete "$CFG.$_sec"
	if [ "$(uci -q get "$CFG.@5gmodem[0].active_modem")" = "$_p" ]; then
		_present=" $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
		uci -q delete "$CFG.@5gmodem[0].preferred_modem" 2>/dev/null
		case "$_present" in
			*" $_p "*)
				logger -t 5gmodem "profile $_sec deleted, modem $_p still on the bus - keeping it active"
				;;
			*)
				_other=""
				for _pp in $_present; do [ -n "$_pp" ] && { _other="$_pp"; break; }; done
				if [ -n "$_other" ]; then
					uci -q set "$CFG.@5gmodem[0].active_modem=$_other"
				else
					uci -q delete "$CFG.@5gmodem[0].active_modem" 2>/dev/null
				fi
				;;
		esac
	fi
	uci -q commit "$CFG"
	[ -n "$_killed" ] && /etc/init.d/network reload >/dev/null 2>&1
	logger -t 5gmodem "profile $_sec ($_p) deleted${_killed:+, interface $_killed too}"
	printf '{"success":true,"iface_removed":"%s"}\n' "$_killed"
	exit 0
	;;
apnfor)
	_j=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"
	_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		for _c in "${_imsi%${_imsi#??????}}" "${_imsi%${_imsi#?????}}"; do
			_sim_plmns="$_sim_plmns ${_c%${_c#???}}-${_c#???}"
		done
	fi
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	[ "$_reg" = "5" ] && exit 0
	_iccid=$(printf '%s' "$_j" | jsonfilter -e '@.iccid' 2>/dev/null | tr -cd '0-9')
	apn_pick "$_op" "$_plmn" "$_sim_plmns" "$_imsi" "$_iccid"
	exit 0
	;;
autoapn)
	note_foreign_uci network "modemswitch autoapn"
	IFACE="${2:-$(uci -q get "$CFG.@5gmodem[0].network")}"
	[ -n "$IFACE" ] || exit 0

	_am_sec=$(sec_for_iface "$IFACE")
	case "$(uci -q get "$CFG.$_am_sec.kind")" in
		tether|hilink) exit 0 ;;
	esac
	[ "$(uci -q get "network.$IFACE.proto")" = ccmni ] && exit 0
	if [ "$(uci -q get "$CFG.$_am_sec.apn_mode")" = "manual" ]; then
		logger -t 5gmodem "autoapn: $IFACE is in manual mode, leaving the APN alone"
		exit 0
	fi

	_am_gv="/tmp/5gmodem/autoapn_${_am_sec}.gaveup"
	_apn_giveup() { [ -n "$_am_sec" ] && : > "$_am_gv" 2>/dev/null; }
	_apn_done()   { [ -n "$_am_sec" ] && rm -f "$_am_gv" 2>/dev/null; }
	_am_path=$(uci -q get "$CFG.$_am_sec.path")

	_imsi_hint=$(printf '%s' "$3" | tr -cd '0-9')

	_w=0; _ip=""
	if [ ${#_imsi_hint} -lt 6 ]; then
		while [ "$_w" -lt 60 ]; do
			_ip=$(ubus call network.interface."$IFACE" status 2>/dev/null \
				| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
			[ -n "$_ip" ] && break
			sleep 5; _w=$((_w + 5))
		done
	fi

	_j=""; _op=""; _mcc=""; _mnc=""; _imsi=""; _apn_w=0
	if [ ${#_imsi_hint} -ge 6 ]; then
		_imsi="$_imsi_hint"
	else
	while [ "$_apn_w" -lt 40 ]; do
		_j=$(POLL_MODEM="$_am_path" "$RES/5gmodem.sh" cached 5 2>/dev/null)
		_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
		_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
		{ [ -n "$_op" ] && [ "$_op" != "-" ]; } || [ ${#_imsi} -ge 6 ] && break
		if [ "$_apn_w" -lt 6 ]; then sleep 1; _apn_w=$((_apn_w + 1))
		else sleep 5; _apn_w=$((_apn_w + 5)); fi
	done
	fi
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)

	if [ ${#_imsi} -lt 6 ] || [ -z "$_mcc" ] || [ "$_mcc" = "-" ]; then
		if command -v mmcli >/dev/null 2>&1; then
			_aa_p=$(uci -q get "$CFG.$(sec_for_iface "$IFACE" 2>/dev/null).path" 2>/dev/null)
			[ -n "$_aa_p" ] || _aa_p=$(active_path)
			_aa_i=$(mm_index_for_path "$_aa_p" 2>/dev/null)
			if [ -n "$_aa_i" ]; then
				_aa_k=$(mmcli -m "$_aa_i" -K 2>/dev/null)
				if [ -z "$_mcc" ] || [ "$_mcc" = "-" ]; then
					_aa_oc=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.3gpp\.operator-code *: *//p' | tr -cd '0-9')
					case "${#_aa_oc}" in
						5|6) _mcc=$(printf '%s' "$_aa_oc" | cut -c1-3)
						     _mnc=$(printf '%s' "$_aa_oc" | cut -c4-) ;;
					esac
				fi
				if [ -z "$_op" ] || [ "$_op" = "-" ]; then
					_op=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.3gpp\.operator-name *: *//p' | head -1)
				fi
				if [ ${#_imsi} -lt 6 ]; then
					_aa_sim=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.generic\.sim *: *//p' | head -1)
					case "$_aa_sim" in
						*/SIM/*) _imsi=$(mmcli -i "${_aa_sim##*/}" -K 2>/dev/null \
							| sed -n 's/^sim\.properties\.imsi *: *//p' | tr -cd '0-9') ;;
					esac
				fi
				logger -t 5gmodem "autoapn: details fetched from ModemManager - operator \"${_op:--}\", network ${_mcc:--}-${_mnc:--}, IMSI ${#_imsi} digits"
			fi
		fi
	fi
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"

	[ ${#_imsi} -ge 6 ] || _imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		_sim_plmns="${_imsi%${_imsi#??????}} ${_imsi%${_imsi#?????}}"
		_tmp=""
		for _c in $_sim_plmns; do _tmp="$_tmp ${_c%${_c#???}}-${_c#???}"; done
		_sim_plmns="$_tmp"
	fi
	if [ -z "$_op$_plmn" ] && [ ${#_imsi} -lt 6 ]; then
		logger -t 5gmodem "autoapn: neither operator nor IMSI - skipping"
		_apn_giveup
		exit 0
	fi

	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	if [ "$_reg" = "5" ]; then
		logger -t 5gmodem "autoapn: roaming (network \"$_op\", $_plmn) - leaving the APN empty"
		_apn_giveup
		exit 0
	fi

	_iccid=$(printf '%s' "$_j" | jsonfilter -e '@.iccid' 2>/dev/null | tr -cd '0-9')
	_apn=$(apn_pick "$_op" "$_plmn" "$_sim_plmns" "$_imsi" "$_iccid") || {
		logger -t 5gmodem "autoapn: no APN found for \"$_op\" ($_plmn, SIM$_sim_plmns)"
		_apn_giveup
		exit 0
	}
	_apn_stamp_sec() {
		[ -n "$_am_sec" ] || return 0
		[ -n "$_plmn" ] && uci -q set "$CFG.$_am_sec.apn_plmn=$_plmn"
		[ -n "$_imsi" ] && uci -q set "$CFG.$_am_sec.apn_imsi=$_imsi"
		uci -q commit "$CFG"
	}
	_cur=$(uci -q get "network.$IFACE.apn")
	if [ "$_cur" = "$_apn" ]; then
		logger -t 5gmodem "autoapn: APN is already set to $_apn"
		_apn_stamp_sec
		_apn_done
		exit 0
	fi

	uci -q set "network.$IFACE.apn=$_apn"
	uci -q commit network
	_apn_stamp_sec
	_apn_done
	logger -t 5gmodem "autoapn: $IFACE -> APN $_apn (was \"${_cur:-empty}\", operator \"$_op\", $_plmn)"
	ifdown "$IFACE" >/dev/null 2>&1
	sleep 3
	_aa_mi=""
	command -v mmcli >/dev/null 2>&1 && _aa_mi=$(mm_index_for_path "$_am_path" 2>/dev/null)
	if [ -n "$_aa_mi" ]; then
		_aa_w=0
		while [ "$_aa_w" -lt 30 ]; do
			case "$(mmcli -m "$_aa_mi" -K 2>/dev/null \
				| sed -n 's/^modem\.generic\.state *: *//p')" in
				registered|connected|connecting|disconnecting) break ;;
			esac
			sleep 1; _aa_w=$((_aa_w + 1))
		done
		[ "$_aa_w" -gt 0 ] && logger -t 5gmodem "autoapn: waited ${_aa_w}s for the modem to become ready"
	else
		_aa_p=$(uci -q get "$CFG.$_am_sec.at_port")
		[ -n "$_aa_p" ] || _aa_p=$("$RES/detect.sh" 2>/dev/null)
		if [ -n "$_aa_p" ] && [ -c "$_aa_p" ]; then
			_aa_w=0
			while [ "$_aa_w" -lt 30 ]; do
				case "$(at_query "$_aa_p" "AT+CEREG?" 5 2>/dev/null | tr -d '\r' \
					| sed -n 's/^+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)" in
					1|5|6|7|9|10) break ;;
				esac
				sleep 2; _aa_w=$((_aa_w + 2))
			done
			[ "$_aa_w" -gt 0 ] && logger -t 5gmodem "autoapn: waited ${_aa_w}s for network registration (no MM)"
		fi
	fi
	ifup "$IFACE" >/dev/null 2>&1
	;;

autosetup)
	note_foreign_uci network "modemswitch autosetup"
	note_foreign_uci firewall "modemswitch autosetup"
	[ "$(uci -q get "$CFG.@5gmodem[0].auto_setup")" = "0" ] && exit 0

	TARGETS="$2"
	if [ -z "$TARGETS" ]; then
		for _p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
			   && [ "$(uci -q get "$CFG.$_s.at_debug")" != "0" ] \
			   && [ -z "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_p\"].tty[0]" 2>/dev/null)" ]; then
				TARGETS="$TARGETS $_p"
				continue
			fi
			if is_tether "$_p"; then
				_tn=$(tether_netdev "$_p")
				_tok=0
				[ -n "$_n" ] && [ "$(uci -q get "network.$_n.proto")" = dhcp ] \
					&& [ -n "$_tn" ] \
					&& [ "$(uci -q get "network.$_n.device")" = "$_tn" ] && _tok=1
				[ "$_tok" = 1 ] || { TARGETS="$TARGETS $_p"; continue; }
			fi
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && continue
			TARGETS="$TARGETS $_p"
		done
	fi
	[ -n "$TARGETS" ] || exit 0

	for P in $TARGETS; do
		setup_one_modem "$P"
	done
	exit 0
	;;

resolve)
	exec 7>/tmp/5gmodem/ucitx.lock
	flock 7
	note_foreign_uci network "modemswitch resolve"
	PRESENT=$("$RES/listmodems.sh" | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')

	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		case "$SEC" in m_park_*) continue ;; esac
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		_dd_imei=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
		[ -n "$_dd_imei" ] || continue
		_dd_old=$(sec_by_imei "$_dd_imei" "$SEC")
		[ -n "$_dd_old" ] || continue
		case "$_dd_old" in m_park_*) continue ;; esac
		_dd_op=$(uci -q get "$CFG.$_dd_old.path")
		[ -n "$_dd_op" ] && [ -e "/sys/bus/usb/devices/$_dd_op" ] && continue
		_dd_os=$(uci -q get "$CFG.$_dd_old.serial")
		_dd_ns=$(uci -q get "$CFG.$SEC.serial")
		[ -n "$_dd_os" ] && [ -n "$_dd_ns" ] && [ "$_dd_os" != "$_dd_ns" ] && continue
		logger -t 5gmodem "resolve: duplicate profile by IMEI $_dd_imei ($_dd_old, path ${_dd_op:-?} is gone) - moving into $SEC"
		migrate_profile "$_dd_old" "$SEC"
	done

	_nc_changed=""
	for _nc_if in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
		_nc_p=$(uci -q get "network.$_nc_if.modem_path")
		if echo " $PRESENT " | grep -q " $_nc_p "; then
			if [ "$(uci -q get "network.$_nc_if.modem_parked")" = "1" ]; then
				uci -q delete "network.$_nc_if.auto"
				uci -q delete "network.$_nc_if.modem_parked"
				_nc_changed=1
				logger -t 5gmodem "resolve: modem $_nc_p is back - interface $_nc_if re-enabled"
			fi
			continue
		fi
		[ "$(uci -q get "network.$_nc_if.modem_parked")" = "1" ] && continue
		_nc_dev=$(uci -q get "network.$_nc_if.device")
		case "$_nc_dev" in /dev/tty*) : ;; *) continue ;; esac
		[ -e "$_nc_dev" ] || continue
		_nc_own=""
		for _nc_pp in $PRESENT; do
			modem_ttys "$_nc_pp" 2>/dev/null | grep -qxF "$_nc_dev" && { _nc_own="$_nc_pp"; break; }
		done
		[ -n "$_nc_own" ] || continue
		logger -t 5gmodem "resolve: interface $_nc_if has no modem (path $_nc_p) and its node $_nc_dev belongs to live $_nc_own - disabling until the modem returns"
		ifdown "$_nc_if" 2>/dev/null
		uci -q set "network.$_nc_if.auto=0"
		uci -q set "network.$_nc_if.modem_parked=1"
		_nc_changed=1
	done
	[ -n "$_nc_changed" ] && { uci -q commit network; ubus call network reload >/dev/null 2>&1; }

	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		swap_cleanup "$P" "$SEC"
		_rs_oser=$(uci -q get "$CFG.$SEC.serial")
		_rs_ser=$(modem_serial "$P")
		[ -n "$_rs_ser" ] && uci -q set "$CFG.$SEC.serial=$_rs_ser"
		resolve_at_gate "$P" "$SEC"
		_rs_known=0
		[ "$_RG_QUIET" = 1 ] && quiet_ident_known "$SEC" "$_rs_oser" "$_rs_ser" && _rs_known=1
		A=""
		_pin=$(uci -q get "$CFG.$SEC.at_port")
		if [ "$_RG_QUIET" != 1 ] && [ -n "$_pin" ] && [ -e "$_pin" ] && ! tty_poll_unsafe "$_pin" && modem_ttys "$P" | grep -qxF "$_pin"; then
			if [ "$(uci -q get "$CFG.@5gmodem[0].auto_port")" = 0 ]; then
				A="$_pin"
			else
				"$RES/atprobe.sh" "$_pin" >/dev/null 2>&1 && A="$_pin"
			fi
		fi
		_try=0
		while [ -z "$A" ] && [ "$_try" -lt 6 ]; do
			if [ "$_RG_QUIET" = 1 ]; then
				A=$(quiet_at_port "$P" "$SEC")
				if [ -z "$A" ] && [ "$_RG_NEVER" != 1 ]; then
					[ "$_try" = 0 ] && logger -t 5gmodem-resolve "modem $P: background AT is off, but its AT port is unknown - probing once"
					A=$(at_for_path "$P")
					_rs_known=0
				fi
			else
				A=$(at_for_path "$P")
			fi
			[ -n "$A" ] && break
			_try=$((_try + 1)); sleep 2
			[ "$_RG_NEVER" = 1 ] && [ -n "$_RG_MM" ] && _RG_MMK=$(mmcli -m "$_RG_MM" -K 2>/dev/null)
		done
		if [ -n "$A" ] && [ "$_RG_QUIET" = 1 ] && command -v _tty_ifnum >/dev/null 2>&1; then
			_rs_ti=$(_tty_ifnum "${A##*/}")
			[ "${_rs_ti%% *}" = "$P" ] && [ -n "${_rs_ti#* }" ] && uci -q set "$CFG.$SEC.at_if=${_rs_ti#* }"
		fi
		if [ -n "$A" ]; then
			uci -q set "$CFG.$SEC.at_port=$A"
		else
			SAVED=$(uci -q get "$CFG.$SEC.at_port")
			if [ -n "$SAVED" ] && { [ ! -e "$SAVED" ] || tty_poll_unsafe "$SAVED" || ! modem_ttys "$P" | grep -qxF "$SAVED"; }; then
				uci -q delete "$CFG.$SEC.at_port" 2>/dev/null
			fi
		fi
		_rs_ask=0
		if [ "$_RG_QUIET" = 1 ]; then
			[ -z "$_RG_MMK" ] && [ -n "$A" ] && [ "$_RG_NEVER" != 1 ] && [ "$_rs_known" != 1 ] && _rs_ask=1
		elif [ -n "$A" ] && [ -n "$(uci -q get "$CFG.$SEC.model")" ]; then
			_rs_ask=1
		fi
		if [ "$_rs_ask" = 1 ] || [ -n "$_RG_MMK" ]; then
			if [ "$_rs_ask" = 1 ]; then
				_rs_imei=$(sms_tool -d "$A" at "AT+CGSN" 2>/dev/null | tr -s '\r\n' '\n\n' \
					| grep -oE '^[0-9]{14,16}$' | head -1)
			else
				_rs_imei=$(mmk_imei "$_RG_MMK")
			fi
			_rs_prev=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
			if [ "$_RG_QUIET" = 1 ] && [ -n "$_rs_imei" ] && [ -z "$_rs_prev" ]; then
				uci -q set "$CFG.$SEC.imei=$_rs_imei"
			fi
			if [ -n "$_rs_imei" ] && [ -n "$_rs_prev" ] && [ "$_rs_imei" != "$_rs_prev" ]; then
				logger -t 5gmodem "resolve: a different unit in port $P with the same vid:pid (IMEI $_rs_prev -> $_rs_imei) - re-reading the model"
				uci -q delete "$CFG.$SEC.model" 2>/dev/null
				uci -q delete "$CFG.$SEC.model_vp" 2>/dev/null
				uci -q set "$CFG.$SEC.imei=$_rs_imei"
				uci -q commit "$CFG"
				purge_path_caches "$P"
			fi
		fi
		_rs_mask=0
		if [ -z "$(uci -q get "$CFG.$SEC.model")" ]; then
			if [ "$_RG_QUIET" != 1 ]; then
				[ -n "$A" ] && _rs_mask=1
			elif [ -n "$_RG_MMK" ]; then
				_rs_mask=2
			elif [ -n "$A" ] && [ "$_RG_NEVER" != 1 ] && [ "$_rs_known" != 1 ]; then
				_rs_mask=1
			fi
		fi
		if [ "$_rs_mask" != 0 ]; then
			if [ "$_rs_mask" = 2 ]; then
				_rm=$(mmk_val "$_RG_MMK" 'modem\.generic\.model')
			else
				_rm=$(sms_tool -d "$A" at "AT+CGMM" 2>/dev/null | tr -s '\r\n' '\n\n' \
					| grep -vE '^[[:space:]]*$|^OK$|^AT' | head -1)
			fi
			_rm=$(printf '%s' "$_rm" \
				| sed -e 's/^+\{0,1\}CGMM:[[:space:]]*//' -e 's/^"//' -e 's/"$//' \
				      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			if [ -n "$_rm" ] && _model_sane "$_rm" \
			   && _model_vendor_ok "$_rm" "$(uci -q get "$CFG.$SEC.vidpid")"; then
				uci -q set "$CFG.$SEC.model=$(model_alias "$_rm")"
				uci -q set "$CFG.$SEC.model_vp=$(uci -q get "$CFG.$SEC.vidpid")"
				logger -t 5gmodem-resolve "model for $SEC identified: $_rm"
			fi
		fi
		if [ "$_RG_QUIET" = 1 ] && [ -n "$A" ] && { [ "$_rs_ask" = 1 ] || [ "$_rs_mask" = 1 ]; }; then
			uci -q set "$CFG.$SEC.ident_probe=$(uci -q get "$CFG.$SEC.vidpid")|$_rs_ser"
		fi
	done
	uci -q commit "$CFG"

	_sl_chg=0
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		_sl_if=$(uci -q get "$CFG.$SEC.network")
		[ -n "$_sl_if" ] || continue
		uci -q get "network.$_sl_if" >/dev/null 2>&1 || continue
		_sl_p=$(uci -q get "$CFG.$SEC.path")
		[ -n "$_sl_p" ] && echo " $PRESENT " | grep -q " $_sl_p " || continue
		[ "$(uci -q get "network.$_sl_if.auto")" = "0" ] || continue
		[ "$(uci -q get "$CFG.$SEC.kind")" = tether ] && iface_user_off "$_sl_if" && continue
		uci -q delete "network.$_sl_if.auto"; uci -q delete "network.$_sl_if.modem_swapped"; _sl_chg=1
		if proto_in wdm "$(uci -q get "network.$_sl_if.proto")"; then
			for _sl_w in /sys/bus/usb/devices/"$_sl_p":*/usbmisc/cdc-wdm* \
			             /sys/bus/usb/devices/"$_sl_p":*/usbmisc/wdm*; do
				[ -e "$_sl_w" ] || continue
				_sl_dp=$(readlink -f "$(dirname "$(dirname "$_sl_w")")")
				[ -n "$_sl_dp" ] || _sl_dp=$(dirname "$(dirname "$_sl_w")")
				uci -q set "network.$_sl_if.device=/dev/$(basename "$_sl_w")"
				uci -q set "network.$_sl_if.devpath=$_sl_dp"
				logger -t 5gmodem-resolve "interface $_sl_if: control channel re-bound to $_sl_dp"
				break
			done
		fi
		logger -t 5gmodem-resolve "interface $_sl_if woken up: modem $_sl_p is back"
	done
	[ "$_sl_chg" = 1 ] && { uci -q commit network; ubus call network reload >/dev/null 2>&1; }

	AMP=$(active_path)
	PREF=$(uci -q get "$CFG.@5gmodem[0].preferred_modem")
	if [ -n "$PREF" ] && [ -n "$PRESENT" ] \
	   && ! echo " $PRESENT " | grep -q " $PREF " \
	   && [ ! -e "/sys/bus/usb/devices/$PREF" ]; then
		:
	elif [ -n "$PREF" ] && [ -n "$PRESENT" ] && ! echo " $PRESENT " | grep -q " $PREF " \
	     && [ -e "/sys/bus/usb/devices/$PREF" ]; then
		logger -t 5gmodem-resolve "preferred \"$PREF\" is on the bus but is not a modem - clearing the mark"
		uci -q delete "$CFG.@5gmodem[0].preferred_modem"; uci -q commit "$CFG"
		PREF=""
	fi
	if [ -n "$PREF" ] && echo " $PRESENT " | grep -q " $PREF " && [ "$AMP" != "$PREF" ]; then
		AMP="$PREF"
		uci -q set "$CFG.@5gmodem[0].active_modem=$AMP"
		uci -q commit "$CFG"
	elif [ -z "$AMP" ] || ! echo " $PRESENT " | grep -q " $AMP "; then
		_cand=""
		for _p in $PRESENT; do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && { _cand="$_p"; break; }
		done
		[ -n "$_cand" ] || _cand=$(echo "$PRESENT" | awk '{print $1}')
		AMP="$_cand"
		[ -n "$AMP" ] && uci -q set "$CFG.@5gmodem[0].active_modem=$AMP" && uci -q commit "$CFG"
	fi
	[ -n "$AMP" ] || { echo '{"result":"no-modems"}'; exit 0; }

	SEC=$(secname "$AMP")
	ATP=$(uci -q get "$CFG.$SEC.at_port")
	if tty_poll_unsafe "$ATP"; then
		ATP=$(at_for_path "$AMP")
		if [ -n "$ATP" ]; then
			uci -q set "$CFG.$SEC.at_port=$ATP"
		else
			uci -q delete "$CFG.$SEC.at_port"
		fi
	fi
	if [ -n "$ATP" ] && [ -e "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
		resolve_at_gate "$AMP" "$SEC"
		if [ "$_RG_QUIET" = 1 ] && uci -q get 5gmodem.sms >/dev/null 2>&1; then
			for k in readport sendport ussdport atport; do
				_rs_sp=$(uci -q get "5gmodem.sms.$k")
				[ -z "$_RG_PORT" ] && [ -n "$_rs_sp" ] && [ -c "$_rs_sp" ] && modem_ttys "$AMP" | grep -qxF "$_rs_sp" && continue
				uci -q set "5gmodem.sms.$k=$ATP"
			done
			uci -q commit 5gmodem
		elif uci -q get 5gmodem.sms >/dev/null 2>&1; then
			for k in readport sendport ussdport atport; do uci -q set "5gmodem.sms.$k=$ATP"; done
			uci -q commit 5gmodem
			set_sms_storage "$ATP"
			"$RES/ensureports.sh" >/dev/null 2>&1
		fi
	else
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi

	apply_mm_state
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " && continue
		ifa=$(uci -q get "$CFG.$s.network"); [ -n "$ifa" ] || continue
		proto_in wdm "$(uci -q get "network.$ifa.proto")" || continue
		deva=$(uci -q get "network.$ifa.device"); [ -n "$deva" ] || continue
		owp=$(path_for_wdm "$deva")
		if [ -n "$owp" ] && [ "$owp" != "$p" ]; then
			ifdown "$ifa" >/dev/null 2>&1
			uci -q delete "network.$ifa.device"; uci -q delete "network.$ifa.devpath"; uci -q commit network
			logger -t 5gmodem-resolve "iface $ifa: owner $p absent, device $deva now belongs to $owp - parked to free its wwan"
		fi
	done
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " || continue
		if proto_in wdm "$(uci -q get "network.$(uci -q get "$CFG.$s.network").proto" 2>/dev/null)"; then
			( "$RES/fcc-unlock.sh" kernel "$p" ) >/dev/null 2>&1 </dev/null 7>&- 8>&- 9>&- &
		fi
		ensure_iface "$p" "$s"
		fi_=$(orphan_iface_for "$p")
		if [ -n "$fi_" ]; then
			uci -q set "$CFG.$s.foreign_iface=$fi_"
			logger -t 5gmodem-resolve "modem $p: iface '$fi_' was made for another modem (stale APN/settings)"
		else
			uci -q delete "$CFG.$s.foreign_iface" 2>/dev/null
		fi
	done

	SEC=$(secname "$AMP")
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		uci -q set "$CFG.@5gmodem[0].network=$IF"
	else
		_cur=$(uci -q get "$CFG.@5gmodem[0].network")
		_mmn=$(uci -q show network 2>/dev/null | grep -c "\.proto='modemmanager'")
		if [ -n "$_cur" ] && [ "$_mmn" = "1" ] \
		   && [ "$(uci -q get "network.$_cur.proto")" = "modemmanager" ]; then
			:
		else
			uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
		fi
	fi
	uci -q commit "$CFG"
	[ -n "$IF" ] && uci -q get "network.$IF" >/dev/null 2>&1 && ( fix_iface_proto "$IF" ) 7>&-
	rm -f /tmp/5gmodem/modem
	( "$0" cleanup apply >/dev/null 2>&1 7>&- & ) >/dev/null 2>&1 </dev/null 7>&- &
	printf '{"result":"resolved","active":"%s","at_port":"%s"}\n' "$AMP" "$ATP"
	;;

setalias)
	_sa_p="$2"
	[ -n "$_sa_p" ] || { echo '{"error":"no path"}'; exit 0; }
	_sa_sec="m_$(echo "$_sa_p" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q get "$CFG.$_sa_sec" >/dev/null 2>&1 || { echo '{"error":"no section"}'; exit 0; }
	shift 2
	_sa_name=$(printf '%s' "$*" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	_sa_name=$(printf '%s' "$_sa_name" | LC_ALL=C awk 'BEGIN { for (n = 128; n < 192; n++) cb[sprintf("%c", n)] = 1 }
		{ o = ""; k = 0; L = length($0)
		  for (i = 1; i <= L; i++) { b = substr($0, i, 1); if (!(b in cb)) { if (k == 32) break; k++ }; o = o b }
		  printf "%s", o; exit }')
	if [ -z "$_sa_name" ]; then
		uci -q delete "$CFG.$_sa_sec.alias" 2>/dev/null
		uci -q delete "$CFG.$_sa_sec.alias_imei" 2>/dev/null
	else
		uci -q set "$CFG.$_sa_sec.alias=$_sa_name"
		_sa_im=$(uci -q get "$CFG.$_sa_sec.imei" 2>/dev/null)
		if [ -n "$_sa_im" ]; then
			uci -q set "$CFG.$_sa_sec.alias_imei=$_sa_im"
		else
			uci -q delete "$CFG.$_sa_sec.alias_imei" 2>/dev/null
		fi
	fi
	uci -q commit "$CFG"
	rm -f /tmp/5gmodem/listmodems.cache 2>/dev/null
	printf '{"ok":1,"alias":"%s"}\n' "$_sa_name"
	;;

webpass)
	_wp_p="$2"
	[ -n "$_wp_p" ] || { echo '{"error":"no path"}'; exit 0; }
	_wp_sec="m_$(echo "$_wp_p" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q get "$CFG.$_wp_sec" >/dev/null 2>&1 || { echo '{"error":"no section"}'; exit 0; }
	case "$3" in
		get)
			if [ -n "$(uci -q get "$CFG.$_wp_sec.web_pass")" ]; then echo '{"set":1}'; else echo '{"set":0}'; fi
			exit 0 ;;
		set)
			_wp_v="$4"
			if [ -z "$_wp_v" ]; then
				uci -q delete "$CFG.$_wp_sec.web_pass" 2>/dev/null
			else
				uci -q set "$CFG.$_wp_sec.web_pass=$_wp_v"
			fi
			uci -q commit "$CFG"
			rm -f /tmp/5gmodem/tendaauth_* /tmp/5gmodem/ztestok_* /tmp/5gmodem/tendaapi_* 2>/dev/null
			echo '{"ok":1}' ;;
		*) echo '{"error":"usage: webpass <path> get|set [password]"}' ;;
	esac
	;;

mmindex)
	mm_index_for_path "${2:-$(active_path)}"
	;;

wdmdrv)
	_wd_n=$(wdm_for_path "${2:-$(active_path)}")
	[ -n "$_wd_n" ] && basename "$(readlink -f "/sys/class/usbmisc/${_wd_n##*/}/device/driver" 2>/dev/null)" 2>/dev/null
	;;

wdm)
	wdm_for_path "${2:-$(active_path)}"
	;;

dedupe-ifaces)
	note_foreign_uci network "modemswitch dedupe-ifaces"
	note_foreign_uci firewall "modemswitch dedupe-ifaces"
	_dd_used=" $(uci -q show "$CFG" 2>/dev/null \
		| sed -n "s/^$CFG\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | tr '\n' ' ') "
	_dd_gone=""
	for _dd_if in $(uci -q show network 2>/dev/null \
			| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
		_dd_dev=$(uci -q get "network.$_dd_if.device")
		_dd_path=$(uci -q get "network.$_dd_if.modem_path")
		[ -n "$_dd_dev" ] && [ -n "$_dd_path" ] || continue
		case "$_dd_used" in *" $_dd_if "*) continue ;; esac
		_dd_owner=""
		for _dd_o in $(uci -q show network 2>/dev/null \
				| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
			[ "$_dd_o" = "$_dd_if" ] && continue
			[ "$(uci -q get "network.$_dd_o.device")" = "$_dd_dev" ] || continue
			[ "$(uci -q get "network.$_dd_o.modem_path")" = "$_dd_path" ] || continue
			case "$_dd_used" in *" $_dd_o "*) _dd_owner="$_dd_o"; break ;; esac
		done
		[ -n "$_dd_owner" ] || continue
		ubus call network.interface."$_dd_owner" status 2>/dev/null \
			| grep -q '"up": true' || {
				logger -t 5gmodem "dedupe-ifaces: $_dd_if looks like a duplicate of $_dd_owner, but $_dd_owner is down - leaving both alone"
				continue
			}
		ifdown "$_dd_if" >/dev/null 2>&1
		uci -q delete "network.$_dd_if"
		_dd_z=$(uci show firewall 2>/dev/null \
			| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
		[ -n "$_dd_z" ] && uci -q del_list "firewall.$_dd_z.network=$_dd_if"
		_dd_gone="$_dd_gone $_dd_if"
	done
	if [ -n "$_dd_gone" ]; then
		uci -q commit network
		uci -q commit firewall
		ubus call network reload >/dev/null 2>&1
		logger -t 5gmodem "dedupe-ifaces: removed duplicate interfaces on the same network card:$_dd_gone"
	fi
	printf '{"removed":"%s"}\n' "${_dd_gone# }"
	exit 0
	;;

forget)
	note_foreign_uci network "modemswitch forget"
	PRESENT=" $("$RES/listmodems.sh" --refresh | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
	case "$PRESENT" in
		*[!\ ]*) ;;
		*) printf '{"result":"ok","forgotten":0,"note":"no modems enumerated - nothing removed"}\n'; exit 0 ;;
	esac
	AMP=$(active_path)
	N=0
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo "$PRESENT" | grep -q " $P " && continue
		[ "$P" = "$AMP" ] && continue
		_if=$(uci -q get "$CFG.$SEC.network")
		if [ -n "$_if" ] && ifstatus "$_if" 2>/dev/null | grep -q '"up": true'; then
			continue
		fi
		uci -q delete "$CFG.$SEC"
		N=$((N + 1))
	done
	_fg_ids=" "
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		case "$SEC" in m_park_*) continue ;; esac
		_fg_ids="$_fg_ids$(uci -q get "$CFG.$SEC.imei") $(uci -q get "$CFG.$SEC.serial") "
	done
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_park_[^.=]*\)=modem\$/\1/p"); do
		_fg_m=$(uci -q get "$CFG.$SEC.imei")
		_fg_s=$(uci -q get "$CFG.$SEC.serial")
		[ -n "$_fg_m" ] && case "$_fg_ids" in *" $_fg_m "*) continue ;; esac
		[ -n "$_fg_s" ] && case "$_fg_ids" in *" $_fg_s "*) continue ;; esac
		uci -q delete "$CFG.$SEC"
		N=$((N + 1))
	done
	[ "$N" -gt 0 ] && uci -q commit "$CFG"
	_fg_rm=""
	[ "$N" -gt 0 ] && _fg_rm=$("$RES/modemswitch.sh" cleanup apply 2>/dev/null \
		| jsonfilter -e '@.orphans[*].iface' 2>/dev/null | tr '\n' ' ')
	_fg_rm=${_fg_rm% }
	printf '{"result":"ok","forgotten":%s,"ifaces":"%s"}\n' "$N" "$_fg_rm"
	;;

xmm)
	P=$(active_path)
	A=$(uci -q get "$CFG.@5gmodem[0].at_port")
	[ -n "$P" ] && [ -n "$A" ] || { echo '{"error":"no active modem"}'; exit 0; }
	MSEC="m_$(echo "$P" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q set "$CFG.$MSEC.want_proto=xmm"; uci -q commit "$CFG"
	_xm_o=$(sms_tool -d "$A" at "AT+GTUSBMODE=0" 2>/dev/null | tr -d '\r')
	case "$_xm_o" in
		*ERROR*)
			logger -t 5gmodem "xmm: AT+GTUSBMODE rejected (L860 firmware?) - switching via at@nvm:cal_usbmode"
			sms_tool -d "$A" at "at@nvm:cal_usbmode.num=0" >/dev/null 2>&1
			sms_tool -d "$A" at "at@store_nvm(cal_usbmode)" >/dev/null 2>&1 ;;
	esac
	sms_tool -d "$A" at "AT+CFUN=15" >/dev/null 2>&1
	printf '{"ok":1}\n'
	;;

cleanup)
	_cl_apply=""; [ "$2" = apply ] && _cl_apply=1
	[ -n "$_cl_apply" ] && note_foreign_uci network "modemswitch cleanup"
	_cl_did=""
	_cl_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	_cl_owned=" $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | tr '\n' ' ') "
	_cl_first=1
	printf '{"orphans":['
	for _cl_i in $(uci show network 2>/dev/null \
			| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p" | sort -u); do
		[ -n "$_cl_i" ] || continue
		case "$_cl_owned" in *" $_cl_i "*) continue ;; esac
		_cl_up=$(ifstatus "$_cl_i" 2>/dev/null | grep -c '"up": true')
		_cl_ip=$(ifstatus "$_cl_i" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
		{ [ "$_cl_up" != 0 ] || [ -n "$_cl_ip" ]; } && continue
		_cl_p=$(uci -q get "network.$_cl_i.modem_path")
		_cl_m=$(uci -q get "network.$_cl_i.modem_imei")
		[ "$_cl_first" = 1 ] || printf ','
		_cl_first=0
		printf '{"iface":"%s","path":"%s","imei":"%s","proto":"%s"}' \
			"$_cl_i" "$_cl_p" "$_cl_m" "$(uci -q get "network.$_cl_i.proto")"
		[ -n "$_cl_apply" ] || continue
		ifdown "$_cl_i" >/dev/null 2>&1
		uci -q delete "network.$_cl_i"
		_cl_did=1
		[ -n "$_cl_z" ] && uci -q del_list "firewall.$_cl_z.network=$_cl_i"
		logger -t 5gmodem "cleanup: removed orphan interface $_cl_i (path ${_cl_p:-?}, IMEI ${_cl_m:-?}) - no owner among modems or parked profiles"
	done
	printf '],"parked":['
	_cl_ttl=$(uci -q get "$CFG.@5gmodem[0].park_ttl_days")
	case "$_cl_ttl" in ''|*[!0-9]*) _cl_ttl=30 ;; esac
	_cl_now=$(date +%s 2>/dev/null); case "$_cl_now" in ''|*[!0-9]*) _cl_now=0 ;; esac
	_cl_pfirst=1
	if [ "$_cl_ttl" != 0 ] && [ "$_cl_now" != 0 ]; then
		for _cl_s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_park_[^.]*\)=modem\$/\1/p"); do
			_cl_at=$(uci -q get "$CFG.$_cl_s.parked_at")
			case "$_cl_at" in ''|*[!0-9]*) continue ;; esac
			_cl_age=$(( (_cl_now - _cl_at) / 86400 ))
			[ "$_cl_age" -ge "$_cl_ttl" ] || continue
			_cl_pif=$(uci -q get "$CFG.$_cl_s.network")
			_cl_pimei=$(uci -q get "$CFG.$_cl_s.imei")
			[ "$_cl_pfirst" = 1 ] || printf ','
			_cl_pfirst=0
			printf '{"section":"%s","iface":"%s","imei":"%s","days":%s}' \
				"$_cl_s" "$_cl_pif" "$_cl_pimei" "$_cl_age"
			[ -n "$_cl_apply" ] || continue
			if [ -n "$_cl_pif" ] && [ -n "$(uci -q get "network.$_cl_pif.modem_imei")" ] \
			   && [ "$(ifstatus "$_cl_pif" 2>/dev/null | grep -c '"up": true')" = 0 ]; then
				ifdown "$_cl_pif" >/dev/null 2>&1
				uci -q delete "network.$_cl_pif"
				[ -n "$_cl_z" ] && uci -q del_list "firewall.$_cl_z.network=$_cl_pif"
			fi
			uci -q delete "$CFG.$_cl_s"
			_cl_did=1
			logger -t 5gmodem "cleanup: parked profile $_cl_s (IMEI ${_cl_pimei:-?}, $_cl_age days) and its interface ${_cl_pif:-none} removed"
		done
	fi
	printf ']'
	if [ -n "$_cl_apply" ]; then
		if [ -n "$_cl_did" ]; then
			uci -q commit "$CFG"
			uci -q commit network
			uci -q commit firewall
		fi
		printf ',"applied":true'
	else
		printf ',"applied":false'
	fi
	printf '}\n'
	;;

*)
	echo "usage: $0 active|switch <path>|save <path>|resolve|forget|cleanup [apply]|mmindex|wdm|xmm" >&2
	exit 1
	;;
esac
