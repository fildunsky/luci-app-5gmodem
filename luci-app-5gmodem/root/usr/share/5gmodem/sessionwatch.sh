#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem
INTERVAL="${SESSIONWATCH_INTERVAL:-30}"
export SW_BG=1

. "$RES/atlock.sh" 2>/dev/null
. "$RES/lib.sh" 2>/dev/null
. "$RES/netonly.sh" 2>/dev/null

_log() { logger -t 5gmodem "sessionwatch: $*"; }

_sw_run() {
	_swr_t="$1"; shift
	"$@" 2>/dev/null &
	_swr_p=$!
	( exec >/dev/null 2>&1; sleep "$_swr_t"; kill "$_swr_p" 2>/dev/null ) </dev/null & _swr_w=$!
	wait "$_swr_p"; _swr_rc=$?
	kill "$_swr_w" 2>/dev/null; wait "$_swr_w" 2>/dev/null
	return $_swr_rc
}

_kill_stuck_uqmi() {
	[ -n "$1" ] || return 0
	_ku_up=$(_now)
	for _ku_p in /proc/[0-9]*; do
		read -r _ku_cm 2>/dev/null < "$_ku_p/comm" || continue
		[ "$_ku_cm" = uqmi ] || continue
		_ku_cl=$(tr '\0' ' ' 2>/dev/null < "$_ku_p/cmdline") || continue
		case "$_ku_cl" in
			*" $1 "*|*" $1") ;;
			*) continue ;;
		esac
		_ku_st=$(cut -d' ' -f22 "$_ku_p/stat" 2>/dev/null)
		case "$_ku_st" in ''|*[!0-9]*) continue ;; esac
		[ $((_ku_up - _ku_st / 100)) -ge 15 ] || continue
		_ku_pid="${_ku_p#/proc/}"
		_log "killing stuck uqmi $_ku_pid on $1 - it is holding the channel of a down interface"
		kill -9 "$_ku_pid" 2>/dev/null
		_ku_killed=1
	done
	[ -n "$_ku_killed" ] && { _ku_killed=""; sleep 2; }
	return 0
}

_watched_proto() {
	proto_in at "$1" || proto_in direct "$1"
}
_kernel_proto() {
	proto_in direct "$1"
}

_iface_ip() {
	ifstatus "$1" 2>/dev/null \
		| sed -n 's/.*"address": *"\([0-9.]\{7,\}\)".*/\1/p' | head -1
}

_iface_ip6() {
	ifstatus "$1" 2>/dev/null \
		| sed -n 's/.*"address": *"\([0-9a-fA-F:]*:[0-9a-fA-F:]*\)".*/\1/p' | head -1
}

_modem_ip() {
	_mi_out=$(at_query "$1" "AT+CGPADDR=1" 8)
	printf '%s' "$_mi_out" | sed -n 's/.*+CGPADDR: *1,//p' | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9]{1,3}([.][0-9]{1,3}){3}$' | head -1
}

_ctx_active() {
	_ca=$(at_query "$1" "AT+CGACT?" 8 \
		| sed -n 's/.*+CGACT: *1, *\([0-9]\).*/\1/p' | head -1)
	[ -z "$_ca" ] && return 0
	[ "$_ca" = "1" ]
}

COOLDOWN=180

_now() { IFS=' ' read -r _nw_u _ < /proc/uptime; printf '%s\n' "${_nw_u%%.*}"; }

_sw_sim_ready() {
	_ssr_if="$1"
	proto_in uqmi "$(uci -q get "network.$_ssr_if.proto" 2>/dev/null)" || return 0
	_ssr_dev=$(uci -q get "network.$_ssr_if.device" 2>/dev/null)
	case "$_ssr_dev" in /dev/*) : ;; *) return 0 ;; esac
	_ssr_st=$(_sw_run 8 uqmi -s -d "$_ssr_dev" -t 2000 --uim-get-sim-state 2>/dev/null)
	_ssr_bad=""
	case "$_ssr_st" in
		*'"card_application_state"'*)
			case "$_ssr_st" in *'"illegal"'*) _ssr_bad=1 ;; esac ;;
		*) _ssr_bad=1 ;;
	esac
	_ssr_f="/tmp/5gmodem/sw_sim_$_ssr_if"
	if [ -z "$_ssr_bad" ]; then
		rm -f "$_ssr_f" 2>/dev/null
		return 0
	fi
	_ssr_n=$(cat "$_ssr_f" 2>/dev/null)
	case "$_ssr_n" in ''|*[!0-9]*) _ssr_n=0 ;; esac
	[ "$_ssr_n" -lt 6 ] || return 0
	printf '%s' "$((_ssr_n + 1))" > "$_ssr_f" 2>/dev/null
	_log "$_ssr_if: SIM not ready - bring-up postponed, waiting for the recovery ladder ($((_ssr_n + 1))/6)"
	return 1
}

_revive() {
	_rv_f="/tmp/5gmodem/sw_last_$1"
	_rv_now=$(_now)
	_rv_prev=$(cat "$_rv_f" 2>/dev/null)
	case "$_rv_prev" in
		''|*[!0-9]*) _rv_prev=0 ;;
	esac
	if [ $((_rv_now - _rv_prev)) -lt "$COOLDOWN" ]; then
		_log "$1: $2 - last bring-up was $((_rv_now - _rv_prev))s ago, waiting"
		return 0
	fi
	printf '%s' "$_rv_now" > "$_rv_f" 2>/dev/null
	_log "$1: $2 - restarting"
	iface_up "$1"
}

check_one() {
	_path="$1"; _if="$2"; _proto="$3"; _port="$4"

	_sw_st=$(ifstatus "$_if" 2>/dev/null)
	case "$_sw_st" in
		*'"up": true'*) : ;;
		*)
			_swwhy="down while autostart is on"
			case "$_sw_st" in
				*'"autostart": true'*) : ;;
				*)
					_swerr=$(printf '%s' "$_sw_st" \
						| jsonfilter -e '@.errors[0].code' 2>/dev/null)
					[ -n "$_swerr" ] || return 0
					[ "$(uci -q get "network.$_if.auto")" = "0" ] && return 0
					[ "$(uci -q get "network.$_if.disabled")" = "1" ] && return 0
					_swwhy="down with protocol error ($_swerr)"
					;;
			esac
			[ -n "$_path" ] && [ -e "/sys/bus/usb/devices/$_path/idVendor" ] || return 0
			if [ -n "$_proto" ] && [ ! -f "/lib/netifd/proto/$_proto.sh" ]; then
				if [ ! -f "/tmp/5gmodem/sw_noproto_$_if" ]; then
					: > "/tmp/5gmodem/sw_noproto_$_if"
					_log "$_if: protocol $_proto is not installed - not restarting the interface"
				fi
				return 0
			fi
			rm -f "/tmp/5gmodem/sw_noproto_$_if"
			proto_in uqmi "$_proto" && _kill_stuck_uqmi "$(uci -q get "network.$_if.device")"
			case "$_sw_st" in *'"pending": true'*) return 0 ;; esac
			if [ "$_proto" = modemmanager ] && case "$_sw_st" in *DISCONNECT_FAILED*) true ;; *) false ;; esac; then
				mm_ghost_bearer "$_if" "$("$RES/modemswitch.sh" mmindex "$_path" 2>/dev/null)"
				[ $? = 1 ] || return 0
			fi
			_dflag="/tmp/5gmodem/sw_down_$_if"
			if [ -f "$_dflag" ]; then
				rm -f "$_dflag"
				if [ -n "$_port" ] && ! at_dialer_busy "$_port"; then
					if proto_in at "$_proto"; then
						_swcf="/tmp/5gmodem/sw_cops_$_if"
						_swnow=$(_now)
						_swlast=$(cat "$_swcf" 2>/dev/null)
						case "$_swlast" in ''|*[!0-9]*) _swlast=0 ;; esac
						if [ $((_swnow - _swlast)) -ge 300 ]; then
							_swc=$(at_query "$_port" "AT+COPS?" 6 4 2>/dev/null 									| tr -d '\r' \
								| sed -n 's/^+COPS: *\([0-9]*\).*/\1/p' | head -1)
							if [ "$_swc" = "2" ]; then
								_log "modem on $_if was deregistered by command (+COPS: 2) - re-enabling network search"
								at_query "$_port" "AT+COPS=0" 20 4 >/dev/null 2>&1
								printf '%s' "$_swnow" > "$_swcf" 2>/dev/null
							fi
						fi
					fi
				fi
				if proto_in uqmi "$_proto"; then
					_swd=$(uci -q get "network.$_if.device")
					case "$_swd" in
						/dev/*)
							_sw_sim_ready "$_if" || return 0
							if [ "$(_sw_run 8 uqmi -d "$_swd" --get-data-status \
								| tr -d '"' | tr -d '[:space:]')" = "connected" ]; then
								_log "$_if: session stuck \"connected\" while the interface is down - stopping it before bring-up"
								_sw_run 10 uqmi -d "$_swd" --stop-network 0xffffffff --autoconnect >/dev/null 2>&1
								sleep 2
							fi ;;
					esac
				fi
				_revive "$_if" "$_swwhy"
			else
				: > "$_dflag"
			fi
			return 0 ;;
	esac
	rm -f "/tmp/5gmodem/sw_down_$_if" "/tmp/5gmodem/sw_sim_$_if" 2>/dev/null

	if _kernel_proto "$_proto"; then
		_iip=$(_iface_ip "$_if")
		[ -n "$_iip" ] || _iip=$(_iface_ip "${_if}_4")
		[ -n "$_iip" ] || _iip=$(_iface_ip "${_if}_6")
		[ -n "$_iip" ] || _iip=$(_iface_ip6 "$_if")
		[ -n "$_iip" ] || _iip=$(_iface_ip6 "${_if}_6")
		if [ -z "$_iip" ] && [ "$_proto" = qmi ]; then
			_wdm=$(uci -q get "network.$_if.device")
			case "$_wdm" in
				/dev/*)
					_ds=$(_sw_run 10 uqmi -d "$_wdm" --get-data-status \
						| tr -d '"' | tr -d '[:space:]')
					[ "$_ds" = "connected" ] && _iip="connected" ;;
			esac
			if [ "$_iip" = "connected" ]; then
				_qf="/tmp/5gmodem/sw_qmistuck_$_if"
				_qn=$(cat "$_qf" 2>/dev/null); case "$_qn" in ''|*[!0-9]*) _qn=0 ;; esac
				_qn=$((_qn + 1)); printf '%s' "$_qn" > "$_qf" 2>/dev/null
				if [ "$_qn" -ge 3 ]; then
					rm -f "$_qf" 2>/dev/null
					_qdev=$(ifstatus "$_if" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
					_qraw=$(cat "/sys/class/net/$_qdev/qmi/raw_ip" 2>/dev/null)
					_qfmt=""
					[ -c "$_wdm" ] && \
						_qfmt=$(qmicli_p "$_wdm" --wda-get-data-format 2>/dev/null \
							| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
					_qrf="/tmp/5gmodem/sw_rawiptry_$_if"
					if [ ! -f "$_qrf" ] && [ -f /lib/netifd/proto/qmiraw.sh ] \
					   && [ "$(uci -q get "network.$_if.proto")" = qmi ]; then
						: > "$_qrf"
						_log "$_if: QMI connected but no address in 802.3 mode - switching the interface to proto=qmiraw (raw-ip + static from QMI) and redialing"
						uci set "network.$_if.proto=qmiraw"
						uci set "network.$_if.dhcp=0"
						uci commit network
						REGISTER_PROTO_FORCE=1 "$RES/register_proto.sh" >/dev/null 2>&1
						( ifdown "$_if"; sleep 2; iface_up "$_if" ) >/dev/null 2>&1 </dev/null &
					else
						case "$_qraw:$_qfmt" in
							Y:802-3|N:raw-ip)
								_log "$_if: frame format mismatch (driver raw_ip=$_qraw, modem $_qfmt) - inbound traffic is being dropped" ;;
						esac
						_log "$_if: QMI says connected but no address for $_qn cycles - reinitializing the modem"
						"$RES/qmi-recover.sh" reset "$_path" "channel did not come up ($_if)" >/dev/null 2>&1
					fi
				fi
			fi
		fi
		[ -n "$_iip" ] && [ "$_iip" != "connected" ] && rm -f "/tmp/5gmodem/sw_qmistuck_$_if" "/tmp/5gmodem/sw_rawiptry_$_if" 2>/dev/null
		if [ -z "$_iip" ]; then
			_flag="/tmp/5gmodem/sw_noip_$_if"
			if [ -f "$_flag" ]; then
				rm -f "$_flag"
				_revive "$_if" "up ($_proto) but without an address"
			else
				: > "$_flag"
			fi
		else
			rm -f "/tmp/5gmodem/sw_noip_$_if" 2>/dev/null
		fi
		return 0
	fi

	[ -n "$_port" ] && [ -c "$_port" ] || return 0

	command -v at_lock >/dev/null 2>&1 && { at_lock "$_port" 10 || return 0; }
	_mip=$(_modem_ip "$_port")
	_act=0; _ctx_active "$_port" && _act=1
	command -v at_unlock >/dev/null 2>&1 && at_unlock 2>/dev/null

	_iip=$(_iface_ip "$_if")

	if [ "$_act" = "0" ]; then
		_revive "$_if" "data context went down (CGACT=0)"
		return 0
	fi

	if [ -n "$_mip" ] && [ -n "$_iip" ] && [ "$_mip" != "$_iip" ]; then
		_revive "$_if" "address changed ($_iip -> $_mip)"
		return 0
	fi
	return 0
}

_REG_FLAT=""
_reg_refresh() { _REG_FLAT=$("$RES/registry.sh" flat 2>/dev/null); }

check_once() {
	[ -n "$_REG_FLAT" ] || return 0

	_turnf=/tmp/5gmodem/sw_turn
	_turn=$(cat "$_turnf" 2>/dev/null)
	case "$_turn" in ''|*[!0-9]*) _turn=0 ;; esac

	_atlist=""
	while read -r _p _sec _i _pr _at _o; do
		[ -n "$_p" ] || continue
		[ "$_o" = "mm" ] && continue
		[ "$_i" = "-" ] && continue
		_watched_proto "$_pr" || continue
		_kernel_proto "$_pr" && continue
		_atlist="$_atlist $_p"
	done <<EOF
$_REG_FLAT
EOF
	_atn=0
	for _x in $_atlist; do _atn=$((_atn + 1)); done
	_atpick=""
	if [ "$_atn" -gt 0 ]; then
		_k=$((_turn % _atn)); _j=0
		for _x in $_atlist; do
			[ "$_j" = "$_k" ] && { _atpick="$_x"; break; }
			_j=$((_j + 1))
		done
		printf '%s' "$(( (_turn + 1) % 1000 ))" > "$_turnf" 2>/dev/null
	fi

	while read -r _p _sec _if _proto _at _own; do
		[ -n "$_p" ] || continue
		[ "$_own" = "mm" ] && continue
		[ "$_if" = "-" ] && continue
		_watched_proto "$_proto" || continue
		if ! _kernel_proto "$_proto" && [ "$_p" != "$_atpick" ]; then
			continue
		fi
		[ "$_at" = "-" ] && _at=""
		check_one "$_p" "$_if" "$_proto" "$_at"
	done <<EOF
$_REG_FLAT
EOF
}

WARM_MAXAGE="${SESSIONWATCH_WARM_MAXAGE:-45}"
warm_snapshots() {
	[ "$WARM_MAXAGE" = "0" ] && return 0
	_wa=$(active_path)
	_wnow=$(uptime_s)
	_wall=""
	while read -r _wp _wrest; do
		[ -n "$_wp" ] && _wall="$_wall $_wp"
	done <<EOF
$_REG_FLAT
EOF
	_wlist=""
	for _wp in $_wall; do
		[ "$_wp" = "$_wa" ] && continue
		_wsec="m_$(printf '%s' "$_wp" | sed 's/[^A-Za-z0-9]/_/g')"
		_wif=$(uci -q get "$CFG.$_wsec.network")
		[ -n "$_wif" ] && [ "$(uci -q get "network.$_wif.proto")" = "modemmanager" ] && continue
		_wk=$(snap_key "$_wp")
		[ -s "/tmp/5gmodem/metrics_$_wk.json" ] || { _wlist="$_wlist $_wp"; continue; }
		_wt=$(cat "/tmp/5gmodem/metrics_$_wk.stamp" 2>/dev/null)
		case "$_wt" in
			''|*[!0-9]*) _wlist="$_wlist $_wp"; continue ;;
		esac
		[ "$(( _wnow - _wt ))" -ge "$WARM_MAXAGE" ] && _wlist="$_wlist $_wp"
	done
	_wn=0
	for _x in $_wlist; do _wn=$((_wn + 1)); done
	[ "$_wn" -gt 0 ] || return 0
	_wtf=/tmp/5gmodem/sw_warm
	_wt=$(cat "$_wtf" 2>/dev/null)
	case "$_wt" in ''|*[!0-9]*) _wt=0 ;; esac
	_wk=$(( _wt % _wn )); _wj=0; _wpick=""
	for _x in $_wlist; do
		[ "$_wj" = "$_wk" ] && { _wpick="$_x"; break; }
		_wj=$((_wj + 1))
	done
	printf '%s' "$(( (_wt + 1) % 1000 ))" > "$_wtf" 2>/dev/null
	[ -n "$_wpick" ] || return 0
	logger -t 5gmodem "snapshot warm-up: polling inactive modem $_wpick"
	POLL_MODEM="$_wpick" "$RES/5gmodem.sh" json >/dev/null 2>&1
}

warm_active() {
	_wb=$(uci -q get "$CFG.stats.bgpoll" 2>/dev/null)
	case "$_wb" in 60|300) : ;; *) return 0 ;; esac
	[ "$(uci -q get "$CFG.@5gmodem[0].show_stats" 2>/dev/null)" = "0" ] && return 0
	_wba=$(active_path)
	[ -n "$_wba" ] || return 0
	usb_path_present "$_wba" || return 0
	bg_at_off "$_wba" && return 0
	_wbt=$(cat "/tmp/5gmodem/metrics_$(snap_key "$_wba").stamp" 2>/dev/null)
	case "$_wbt" in ''|*[!0-9]*) _wbt=0 ;; esac
	[ "$(( $(uptime_s) - _wbt ))" -ge "$(( _wb - 10 ))" ] || return 0
	POLL_MODEM="$_wba" "$RES/5gmodem.sh" json >/dev/null 2>&1
}

_page_refresh() {
	_pr_t=""
	read -r _pr_t 2>/dev/null < /tmp/5gmodem/page_active
	case "$_pr_t" in ''|*[!0-9]*) return 0 ;; esac
	[ $(( $(_now) - _pr_t )) -lt 15 ] || return 0
	_pr_ap=$(active_path)
	[ -n "$_pr_ap" ] || return 0
	_pr_k=$(echo "$_pr_ap" | tr -c 'A-Za-z0-9' '_')
	_pr_sm=$(cat "/tmp/5gmodem/metrics_${_pr_k}.stamp" 2>/dev/null)
	case "$_pr_sm" in
		''|*[!0-9]*) ;;
		*) [ $(( $(_now) - _pr_sm )) -lt 7 ] && return 0 ;;
	esac
	_sw_run 25 "$RES/5gmodem.sh" cached 7 "for=$_pr_ap" >/dev/null 2>&1
	return 0
}

_sweep_tmp() {
	find /tmp/5gmodem -maxdepth 1 \( \
		-name 'st.[0-9]*' -o -name 'atq.*' \
		-o -name 'qmicli.*' -o -name 'providers.[0-9]*' \
		-o -name 'bounded.*' \
		-o -name '.atprobe.[0-9]*' -o -name 'listmodems.cache.tmp.[0-9]*' \
		-o -name 'uim.[0-9]*' -o -name 'ttl.[0-9]*.nft' \
		-o -name 'metrics_*.p[0-9]*' \
		-o -name '.tgcidr.*' \
		-o -name 'mbimp.[0-9]*.out' -o -name 'mbimp-keeper.[0-9]*.out' \
		-o -name 'fcc.[0-9]*' -o -name 'qmipool.[0-9]*' \
	\) -mmin +10 -exec rm -f {} + 2>/dev/null
	find /tmp/5gmodem -maxdepth 1 \( \
		-name 'esim_hreq.[0-9]*' -o -name 'esim_hbody.[0-9]*' \
		-o -name 'esim_hhdr.[0-9]*' -o -name 'esim_res.[0-9]*' \
		-o -name 'esim_wdmprobe.[0-9]*' -o -name 'esim_mloop.[0-9]*' \
		-o -name 'esim_loop.[0-9]*' -o -name 'esim_at.[0-9]*' \
	\) -mmin +30 -exec rm -f {} + 2>/dev/null
}

case "$1" in
	*)
		if [ ! -f /tmp/5gmodem/protoguard ]; then
			: > /tmp/5gmodem/protoguard
			( sleep 45
			  _pg_h=$(ubus call network get_proto_handlers 2>/dev/null)
			  for _pg_p in fibocom qmiraw; do
				uci -q show network 2>/dev/null | grep -q "\.proto='$_pg_p'" || continue
				echo "$_pg_h" | grep -q "\"$_pg_p\"" && continue
				logger -t 5gmodem "protoguard: an interface uses $_pg_p but netifd does not know the proto - forcing registration"
				REGISTER_PROTO_FORCE=1 "$RES/register_proto.sh" >/dev/null 2>&1
				break
			  done
			) >/dev/null 2>&1 </dev/null &
		fi
		_stray_ok() {
			_so_f=/tmp/5gmodem/straykill
			_so_now=$(cut -d. -f1 /proc/uptime)
			_so_last=$(cat "$_so_f" 2>/dev/null)
			case "$_so_last" in ''|*[!0-9]*) _so_last=0 ;; esac
			[ $((_so_now - _so_last)) -ge 120 ] || return 1
			printf '%s\n' "$_so_now" > "$_so_f"
			return 0
		}

		_sweep_n=0
		while :; do
			if ! pidof ModemManager >/dev/null 2>&1 \
			   && ! uci -q show network 2>/dev/null | grep -qE "\.proto='?($(proto_re proxy))'?\$"; then
				_ps_if=$(uci -q get 5gmodem.@5gmodem[0].network)
				if proto_in direct "$(uci -q get "network.$_ps_if.proto" 2>/dev/null)"; then
					if pidof mbim-proxy >/dev/null 2>&1 || pidof qmi-proxy >/dev/null 2>&1; then
						if ubus call "network.interface.$_ps_if" status 2>/dev/null | grep -q '"up": true'; then
							if pgrep -x lpac >/dev/null 2>&1 \
							   || pgrep -x qmicli >/dev/null 2>&1 \
							   || pgrep -x mbimcli >/dev/null 2>&1 \
							   || ! _stray_ok; then
								:
							else
								_log "a stray proxy sits on a direct channel ($_ps_if) - killing mbim/qmi-proxy and redialing"
								killall mbim-proxy 2>/dev/null
								killall qmi-proxy 2>/dev/null
								( sleep 2; ifup "$_ps_if" ) >/dev/null 2>&1 </dev/null &
							fi
						elif ! pgrep -x lpac >/dev/null 2>&1 \
						   && ! pgrep -x qmicli >/dev/null 2>&1 \
						   && ! pgrep -x mbimcli >/dev/null 2>&1 \
						   && ! pgrep -x umbim >/dev/null 2>&1 \
						   && ! pgrep -x uqmi >/dev/null 2>&1 \
						   && ! pgrep -f "[m]bim\.sh|[q]mi\.sh" >/dev/null 2>&1 \
						   && ! ubus call "network.interface.$_ps_if" status 2>/dev/null | grep -q '"pending": true' \
						   && _stray_ok; then
							_log "a stray proxy is blocking the dial ($_ps_if is down) - killing mbim/qmi-proxy"
							killall mbim-proxy 2>/dev/null
							killall qmi-proxy 2>/dev/null
							if _sw_sim_ready "$_ps_if"; then
								( sleep 2; ifup "$_ps_if" ) >/dev/null 2>&1 </dev/null &
							fi
						fi
					fi
				fi
			fi
			_sl=0
			while [ "$_sl" -lt "$INTERVAL" ]; do
				sleep 5
				_sl=$((_sl + 5))
				_page_refresh
			done
			_sweep_n=$((_sweep_n + 1))
			if [ "$_sweep_n" -ge 10 ]; then _sweep_n=0; _sweep_tmp; fi
			_SW_NETONLY=""
			netonly_active && _SW_NETONLY=1
			if [ -n "$_SW_NETONLY" ]; then _REG_FLAT=""; else _reg_refresh; fi
			if [ -n "$_REG_FLAT" ]; then
				_sh_noreg=""
				for _sh_p in $(printf '%s\n' "$_REG_FLAT" | awk 'NF{print $1}'); do
					uci -q get "5gmodem.m_$(printf '%s' "$_sh_p" | sed 's/[^A-Za-z0-9]/_/g')" >/dev/null 2>&1 \
						|| { _sh_noreg=1; break; }
				done
				if [ -n "$_sh_noreg" ]; then
					_sh_f=/tmp/5gmodem/sw_autoreg
					_sh_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
					_sh_last=$(cat "$_sh_f" 2>/dev/null)
					case "$_sh_last" in ''|*[!0-9]*) _sh_last=0 ;; esac
					if [ "$((_sh_now - _sh_last))" -ge 120 ]; then
						printf '%s' "$_sh_now" > "$_sh_f" 2>/dev/null
						"$RES/modemswitch.sh" autosetup >/dev/null 2>&1
					fi
				elif [ -z "$(uci -q get "5gmodem.@5gmodem[0].active_modem")" ]; then
					"$RES/modemswitch.sh" resolve >/dev/null 2>&1
				fi
			fi
			[ -n "$_SW_NETONLY" ] || check_once
			_page_refresh
			[ -n "$_SW_NETONLY" ] || warm_snapshots
			[ -n "$_SW_NETONLY" ] || warm_active
			_page_refresh
			"$RES/health.sh" tick >/dev/null 2>&1
			_page_refresh
			"$RES/stats.sh" tick >/dev/null 2>&1
			if uci -q show 5gmodem 2>/dev/null | grep -q "\.ct_[a-z]*='conditional'"; then
				_sw_run 10 "$RES/buttons.sh" syncleds >/dev/null 2>&1
			fi
			_ucd_l=$(uci -q changes 5gmodem 2>/dev/null)
			if [ -n "$_ucd_l" ]; then
				_ucd=$(printf '%s' "$_ucd_l" | md5sum | cut -d' ' -f1)
				if [ "$(cat /tmp/5gmodem/ucidelta 2>/dev/null)" = "$_ucd" ]; then
					uci -q commit 5gmodem 2>/dev/null && \
						_log "committed a stale staged 5gmodem delta (the settings page could not finish its own commit)"
					rm -f /tmp/5gmodem/ucidelta
				else
					printf '%s' "$_ucd" > /tmp/5gmodem/ucidelta
				fi
			else
				rm -f /tmp/5gmodem/ucidelta
			fi
			"$RES/tgnotify.sh" tick >/dev/null 2>&1
			_sw_bgo=""
			[ -n "$_REG_FLAT" ] && bg_at_off && _sw_bgo=1
			_smw_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
			_smw_prev=$(cat /tmp/5gmodem/sms_new.stamp 2>/dev/null)
			case "$_smw_prev" in ''|*[!0-9]*) _smw_prev=0 ;; esac
			_smw_iv=$(uci -q get 5gmodem.sms.mirror_interval)
			case "$_smw_iv" in ''|*[!0-9]*) _smw_iv=60 ;; esac
			if [ -n "$_REG_FLAT" ] && [ "$_smw_iv" -gt 0 ] && [ -z "$_sw_bgo" ] \
			   && [ "$((_smw_now - _smw_prev))" -ge "$_smw_iv" ]; then
				printf '%s' "$_smw_now" > /tmp/5gmodem/sms_new.stamp 2>/dev/null
				"$RES/smsbridge.sh" newdump > /tmp/5gmodem/sms_new.json.tmp 2>/dev/null \
					&& mv /tmp/5gmodem/sms_new.json.tmp /tmp/5gmodem/sms_new.json 2>/dev/null
			fi
			if [ -n "$_REG_FLAT" ]; then
			[ -n "$_sw_bgo" ] || "$RES/smscmd.sh" run >/dev/null 2>&1
			[ -n "$_sw_bgo" ] || "$RES/smsbridge.sh" archive-run >/dev/null 2>&1
			_ar_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
			_ar_prev=$(cat /tmp/5gmodem/arch_all.stamp 2>/dev/null)
			case "$_ar_prev" in ''|*[!0-9]*) _ar_prev=0 ;; esac
			if [ "$((_ar_now - _ar_prev))" -ge 300 ]; then
				printf '%s' "$_ar_now" > /tmp/5gmodem/arch_all.stamp 2>/dev/null
				_ar_act=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
				_ar_list=$("$RES/listmodems.sh" 2>/dev/null)
				for _ar_p in $("$RES/registry.sh" paths 2>/dev/null); do
					[ "$_ar_p" = "$_ar_act" ] && continue
					bg_at_off "$_ar_p" && continue
					printf '%s' "$_ar_list" \
						| jsonfilter -e "@[@.path=\"$_ar_p\"].tty[0]" \
						             -e "@[@.path=\"$_ar_p\"].wdm[0]" 2>/dev/null \
						| grep -q . || continue
					( export SMS_MODEM="$_ar_p"
					  _sw_run 45 "$RES/smsbridge.sh" archive-run ) >/dev/null 2>&1
				done
			fi
			"$RES/smsbridge.sh" queue-run >/dev/null 2>&1
			fi
			for _ipw in /sys/bus/usb/devices/*-*; do
				case "$_ipw" in *:*) continue ;; esac
				is_iphone "${_ipw##*/}" && { usbmuxd_ensure >/dev/null 2>&1; break; }
			done
			"$RES/telemetry.sh" tick >/dev/null 2>&1
		done
		;;
esac
