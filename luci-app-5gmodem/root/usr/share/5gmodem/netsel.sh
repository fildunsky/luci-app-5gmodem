#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null
. /usr/share/5gmodem/atlock.sh 2>/dev/null
RES=/usr/share/5gmodem
. "$RES/quirks.sh" 2>/dev/null
mkdir -p /tmp/5gmodem 2>/dev/null

_ok_path() {
	case "$1" in
		''|*[!0-9A-Za-z.:_-]*) return 1 ;;
	esac
	return 0
}

_ns_now() { IFS=' ' read -r _nn_u _ < /proc/uptime; printf '%s' "${_nn_u%%.*}"; }

_ns_init() {
	NS_PATH="$1"
	NS_SEC=$(secname "$1")
	NS_RES="/tmp/5gmodem/netsel_$(snap_key "$1").json"
	NS_BACK=none; NS_PORT=""; NS_LPORT=""; NS_MMI=""
	case "$(uci -q get "5gmodem.$NS_SEC.kind")" in
		hilink|tether|router) return 0 ;;
	esac
	if mm_owns_path "$1"; then
		NS_MMI=$("$RES/modemswitch.sh" mmindex "$1" 2>/dev/null)
		case "$NS_MMI" in ''|*[!0-9]*) NS_MMI="" ;; *) NS_BACK=mm ;; esac
		return 0
	fi
	NS_PORT=$(uci -q get "5gmodem.$NS_SEC.at_port")
	[ -c "$NS_PORT" ] && NS_BACK=at
	NS_LPORT=$(sms_send_port "$1" 2>/dev/null)
	[ -c "$NS_LPORT" ] || NS_LPORT="$NS_PORT"
	return 0
}

_at_long() {
	_al_t="$2"; _al_out=""
	stty -F "$NS_LPORT" raw -echo 2>/dev/null
	command exec 3<>"$NS_LPORT" 2>/dev/null || return 1
	while read -t 1 -r _al_l <&3; do :; done
	printf '%s\r' "$1" >&3
	_al_end=$(( $(_ns_now) + _al_t ))
	_al_rc=1
	while [ "$(_ns_now)" -lt "$_al_end" ]; do
		read -t 5 -r _al_l <&3 || continue
		_al_l=$(printf '%s' "$_al_l" | tr -d '\r')
		[ -n "$_al_l" ] || continue
		case "$_al_l" in
			OK) _al_rc=0; break ;;
			ERROR|*"+CME ERROR"*|*"COMMAND NOT SUPPORT"*) _al_out="$_al_out$_al_l
"; break ;;
		esac
		_al_out="$_al_out$_al_l
"
	done
	exec 3>&-
	printf '%s' "$_al_out"
	return "$_al_rc"
}

_tech() {
	case "$1" in
		0|1|3) echo 2G ;;
		2|4|5|6) echo 3G ;;
		7|8|9) echo 4G ;;
		10|11|12|13) echo 5G ;;
		*gsm*|*GSM*) echo 2G ;;
		*umts*|*UMTS*) echo 3G ;;
		*5gnr*|*ngran*) echo 5G ;;
		*lte*|*LTE*) echo 4G ;;
		*) echo "" ;;
	esac
}

_res_write() {
	printf '{"state":"%s","error":"%s","at":"%s","networks":[%s]}\n' "$1" "$2" "$(date +%s)" "$3" \
		> "$NS_RES.tmp" 2>/dev/null && mv "$NS_RES.tmp" "$NS_RES" 2>/dev/null
}

_net_json() {
	_nj_name=$(opname_pretty "$1" "$3")
	_nj_t="$5"; [ -n "$_nj_t" ] || _nj_t=$(_tech "$2")
	printf '{"plmn":"%s","act":"%s","tech":"%s","name":"%s","stat":"%s"}' \
		"$1" "$2" "$_nj_t" "$(json_esc "$_nj_name")" "$4"
}

_scan_at() {
	if ! at_lock "$NS_LPORT" 30 2>/dev/null; then
		_res_write error busy ""
		return 1
	fi
	at_long_begin "$NS_LPORT"
	_sa_o=$(_at_long "AT+COPS=?" 240)
	_sa_rc=$?
	at_long_end "$NS_LPORT"
	at_unlock 2>/dev/null
	_sa_l=$(printf '%s\n' "$_sa_o" | sed -n '/^+COPS:/,$p' | tr -d '\n')
	if [ "$_sa_rc" != 0 ] || [ -z "$_sa_l" ]; then
		_res_write error "$(json_esc "$(printf '%s' "$_sa_o" | tail -1)")" ""
		return 1
	fi
	_sa_j=""
	while IFS='|' read -r _sa_s _sa_n _sa_p _sa_a; do
		[ -n "$_sa_p" ] || continue
		case "$_sa_n" in *[!0-9A-Fa-f]*) ;; *) _sa_n="" ;; esac
		case "$_sa_s" in 1) _sa_st=available ;; 2) _sa_st=current ;; 3) _sa_st=forbidden ;; *) _sa_st=unknown ;; esac
		_sa_j="$_sa_j${_sa_j:+,}$(_net_json "$_sa_p" "$_sa_a" "$_sa_n" "$_sa_st")"
	done <<EOT
$(printf '%s' "$_sa_l" | grep -oE '\([0-9],"[^"]*","[^"]*","[0-9]{5,6}"(,"[^"]*")?(,[0-9]+)?\)' \
	| sed -n 's/^(\([0-9]\),"\([^"]*\)","[^"]*","\([0-9]*\)"\(,"[^"]*"\)\{0,1\}\(,\([0-9]*\)\)\{0,1\})$/\1|\2|\3|\6/p')
EOT
	_res_write done "" "$_sa_j"
}

_scan_mm() {
	_sm_o=$(mmcli -m "$NS_MMI" --timeout=300 --3gpp-scan -K 2>&1)
	if [ $? != 0 ]; then
		_res_write error "$(json_esc "$(printf '%s' "$_sm_o" | tail -1)")" ""
		return 1
	fi
	_sm_j=""
	_sm_tab=$(printf '\t')
	printf '%s\n' "$_sm_o" | grep 'operator-code' | sed 's/^[^:]*: *//' | while IFS= read -r _sm_l; do
		_sm_p=$(printf '%s' "$_sm_l" | sed -n 's/.*operator-code: *\([0-9]*\).*/\1/p')
		_sm_n=$(printf '%s' "$_sm_l" | sed -n 's/.*operator-name: *\([^,]*\).*/\1/p')
		_sm_a=$(printf '%s' "$_sm_l" | sed -n 's/.*access-technolog[a-z]*: *\(.*\), *availability.*/\1/p')
		_sm_s=$(printf '%s' "$_sm_l" | sed -n 's/.*availability: *\([^,]*\).*/\1/p')
		[ -n "$_sm_p" ] || continue
		printf '%s%s%s%s%s%s%s\n' "$_sm_p" "$_sm_tab" "$_sm_a" "$_sm_tab" "$_sm_n" "$_sm_tab" "$_sm_s"
	done > "$NS_RES.mm"
	while IFS="$_sm_tab" read -r _sm_p _sm_a _sm_n _sm_s; do
		case "$_sm_s" in current|available|forbidden) ;; *) _sm_s=unknown ;; esac
		_sm_t=0G
		for _sm_x in $(printf '%s' "$_sm_a" | tr ',|' '  '); do
			_sm_x=$(_tech "$_sm_x")
			[ -n "$_sm_x" ] && [ "${_sm_x%G}" -gt "${_sm_t%G}" ] && _sm_t="$_sm_x"
		done
		[ "$_sm_t" = 0G ] && _sm_t=""
		_sm_j="$_sm_j${_sm_j:+,}$(_net_json "$_sm_p" "" "$_sm_n" "$_sm_s" "$_sm_t")"
	done < "$NS_RES.mm"
	rm -f "$NS_RES.mm"
	_res_write done "" "$_sm_j"
}

_cur_at() {
	at_query "$NS_PORT" "AT+COPS=3,2;+COPS?" 8 10 2>/dev/null | sed -n 's/^+COPS: *\(.*\)/\1/p' | head -1
}

_apply_at() {
	case "$1" in
		auto) _aa_c="AT+COPS=0" ;;
		*)
			_aa_m=1; [ "$4" = 1 ] && _aa_m=4
			_aa_c="AT+COPS=$_aa_m,2,\"$2\""
			[ -n "$3" ] && _aa_c="$_aa_c,$3" ;;
	esac
	at_lock "$NS_LPORT" 30 2>/dev/null || return 2
	at_long_begin "$NS_LPORT"
	_aa_o=$(_at_long "$_aa_c" 120)
	_aa_rc=$?
	at_long_end "$NS_LPORT"
	at_unlock 2>/dev/null
	[ "$_aa_rc" = 0 ] && return 0
	logger -t 5gmodem "netsel: $_aa_c failed: $(printf '%s' "$_aa_o" | tail -1)"
	return 1
}

_reg_mm() {
	if [ "$1" = auto ]; then
		mmcli -m "$NS_MMI" --timeout=120 --3gpp-register-home 2>&1
	else
		mmcli -m "$NS_MMI" --timeout=120 --3gpp-register-in-operator="$2" 2>&1
	fi
}

_apply_mm() {
	_am_o=$(_reg_mm "$1" "$2")
	_am_rc=$?
	if [ "$_am_rc" != 0 ] && [ "$3" != keep ]; then
		case "$_am_o" in
			*WrongState*|*"while modem is connected"*)
				mmcli -m "$NS_MMI" --simple-disconnect >/dev/null 2>&1
				_am_o=$(_reg_mm "$1" "$2")
				_am_rc=$?
				_am_net=$(uci -q get "5gmodem.$NS_SEC.network")
				if [ -n "$_am_net" ]; then
					sleep 30
					ifstatus "$_am_net" 2>/dev/null | grep -q '"up": true' || ifup "$_am_net"
				fi ;;
		esac
	fi
	[ "$_am_rc" = 0 ] || logger -t 5gmodem "netsel: ModemManager registration ($1 $2) failed: $(printf '%s' "$_am_o" | tail -1)"
	return "$_am_rc"
}

_bg() {
	( exec 1000>&- 7>&- 8>&- 9>&-; "$@" ) >/dev/null 2>&1 </dev/null &
	sleep 1
}

_saved() {
	NS_MODE=$(uci -q get "5gmodem.$NS_SEC.netsel")
	[ "$NS_MODE" = manual ] || NS_MODE=auto
	NS_PLMN=$(uci -q get "5gmodem.$NS_SEC.netsel_plmn")
	NS_ACT=$(uci -q get "5gmodem.$NS_SEC.netsel_act")
	NS_FB=$(uci -q get "5gmodem.$NS_SEC.netsel_fb")
	[ "$NS_FB" = 0 ] || NS_FB=1
	[ -n "$NS_PLMN" ] || NS_MODE=auto
}

_do_apply() {
	_saved
	case "$NS_BACK" in
		at) _apply_at "$NS_MODE" "$NS_PLMN" "$NS_ACT" "$NS_FB" ;;
		mm) _apply_mm "$NS_MODE" "$NS_PLMN" ;;
	esac
}

_reapply() {
	_saved
	[ "$NS_MODE" = manual ] || return 0
	case "$NS_BACK" in
		at)
			_ra_c=$(_cur_at)
			_ra_m=${_ra_c%%,*}
			case "$_ra_m" in
				4) [ "$NS_FB" = 1 ] && return 0 ;;
				1) case "$_ra_c" in *"\"$NS_PLMN\""*) return 0 ;; esac ;;
			esac
			logger -t 5gmodem "netsel: modem $NS_PATH is not on the chosen network $NS_PLMN - registering again"
			_apply_at manual "$NS_PLMN" "$NS_ACT" "$NS_FB" ;;
		mm)
			_ra_c=$(mmcli -m "$NS_MMI" -K 2>/dev/null | sed -n 's/^modem\.3gpp\.operator-code *: *//p' | tr -cd '0-9')
			[ "$_ra_c" = "$NS_PLMN" ] && return 0
			logger -t 5gmodem "netsel: modem $NS_PATH is not on the chosen network $NS_PLMN - registering again"
			_apply_mm manual "$NS_PLMN" keep ;;
	esac
}

_scan_run() {
	case "$NS_BACK" in
		at) _scan_at ;;
		mm) _scan_mm ;;
	esac
}

_ok_path "$2" || { echo '{"error":"bad path"}'; exit 1; }
_ns_init "$2"

case "$1" in
get)
	_saved
	_ng_cur=""; _ng_cm=""
	if [ "$NS_BACK" = at ]; then
		_ng_cur=$(_cur_at)
		_ng_cm=${_ng_cur%%,*}
		case "$_ng_cm" in [0-4]) ;; *) _ng_cm="" ;; esac
	fi
	printf '{"backend":"%s","mode":"%s","plmn":"%s","act":"%s","fallback":"%s","modem_mode":"%s","name":"%s"}\n' \
		"$NS_BACK" "$NS_MODE" "$NS_PLMN" "$NS_ACT" "$NS_FB" "$_ng_cm" \
		"$(json_esc "$(opname_pretty "$NS_PLMN" "")")"
	;;
scan)
	[ "$NS_BACK" != none ] || { echo '{"state":"error","error":"unsupported"}'; exit 1; }
	case "$(cat "$NS_RES" 2>/dev/null)" in
		*'"state":"running"'*)
			if [ -n "$(find "$NS_RES" -mmin -6 2>/dev/null)" ]; then
				cat "$NS_RES"; exit 0
			fi ;;
	esac
	_res_write running "" ""
	_bg _scan_run
	cat "$NS_RES"
	;;
result)
	if [ -s "$NS_RES" ]; then
		case "$(cat "$NS_RES")" in
			*'"state":"running"'*)
				[ -n "$(find "$NS_RES" -mmin -6 2>/dev/null)" ] || _res_write error timeout "" ;;
		esac
		cat "$NS_RES"
	else
		echo '{"state":"none","networks":[]}'
	fi
	;;
set)
	[ "$NS_BACK" != none ] || { echo "unsupported"; exit 1; }
	case "$3" in
		auto)
			uci -q delete "5gmodem.$NS_SEC.netsel" ;;
		manual)
			case "$4" in ''|*[!0-9]*) echo "bad network"; exit 2 ;; esac
			[ ${#4} -ge 5 ] && [ ${#4} -le 6 ] || { echo "bad network"; exit 2; }
			case "$5" in ''|-) _ns_act="" ;; *[!0-9]*) echo "bad act"; exit 2 ;; *) _ns_act="$5" ;; esac
			uci -q get "5gmodem.$NS_SEC" >/dev/null 2>&1 || {
				uci -q set "5gmodem.$NS_SEC=modem"
				uci -q set "5gmodem.$NS_SEC.path=$NS_PATH"
			}
			uci -q set "5gmodem.$NS_SEC.netsel=manual"
			uci -q set "5gmodem.$NS_SEC.netsel_plmn=$4"
			if [ -n "$_ns_act" ]; then uci -q set "5gmodem.$NS_SEC.netsel_act=$_ns_act"
			else uci -q delete "5gmodem.$NS_SEC.netsel_act"; fi
			if [ "$6" = 0 ]; then uci -q set "5gmodem.$NS_SEC.netsel_fb=0"
			else uci -q delete "5gmodem.$NS_SEC.netsel_fb"; fi ;;
		*) echo "bad mode"; exit 2 ;;
	esac
	uci -q commit 5gmodem
	_bg _do_apply
	;;
reapply)
	[ "$NS_BACK" != none ] || exit 0
	_reapply
	;;
*)
	echo "usage: $0 {get|scan|result|reapply} <usb path> | set <usb path> {auto|manual <plmn> [act] [fallback 0|1]}" >&2
	exit 1
	;;
esac
exit 0
