#!/bin/sh

RES="/usr/share/5gmodem"
. "$RES/lib.sh"

HDIR=/tmp/5gmodem/health
CFG=5gmodem

uci5g_sec_snapshot health

conf() { uci5g_sec_get "$1"; }

H_EN=$(conf enabled)
[ "$(uci -q get "$CFG.@5gmodem[0].widget_netpri")" = "0" ] && H_EN=0
H_INT=$(conf interval);  case "$H_INT" in ''|*[!0-9]*) H_INT=30 ;; esac
H_TGT=$(conf targets);   [ -n "$H_TGT" ] || H_TGT="77.88.8.8 1.1.1.1"
H_RTGT=$(conf restricted_targets)
[ -n "$H_RTGT" ] || H_RTGT="77.88.55.242 5.255.255.242 87.240.132.72 155.212.204.5"
[ "$(conf restricted)" = "0" ] && H_RTGT=""
H_FAILN=$(conf fail_n);  case "$H_FAILN" in ''|*[!0-9]*) H_FAILN=3 ;; esac
H_OKN=$(conf ok_n);      case "$H_OKN" in ''|*[!0-9]*) H_OKN=5 ;; esac
H_FO=$(conf failover)
H_FB=$(conf failback); [ "$H_FB" = "demote" ] || H_FB="restore"
H_MAN=$(conf manual)
is_manual() { case " $H_MAN " in *" $1 "*) return 0 ;; esac; return 1; }
H_PG=$(conf proxy_guard); [ "$H_PG" = "0" ] || H_PG=1
H_HEAL=$(conf healing); [ "$H_HEAL" = "0" ] || H_HEAL=1
H_HEALWIFI=$(conf heal_wifi); [ "$H_HEALWIFI" = "0" ] || H_HEALWIFI=1
H_STAPARK=$(conf sta_park); [ "$H_STAPARK" = "1" ] || H_STAPARK=0
H_LR=$(conf lock_release); [ "$H_LR" = "0" ] || H_LR=1
H_PSCRIPT=$(conf power_script)
case "$H_PSCRIPT" in /*[!A-Za-z0-9/._-]*|/) H_PSCRIPT="" ;; /*) ;; *) H_PSCRIPT="" ;; esac

_WANNETS=""; _WANNETS_DONE=""
fw_zone_check() {
	_fz_o=""
	read -r _fz_o 2>/dev/null < "$HDIR/.fwdev_$1"
	[ "$_fz_o" = "$2" ] && return 0
	_fz_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	case " $(uci -q get "firewall.$_fz_z.network") " in *" $1 "*) ;; *) return 0 ;; esac
	_fz_c=$(nft list chain inet fw4 input 2>/dev/null) || return 0
	[ -n "$_fz_c" ] || return 0
	echo "$2" > "$HDIR/.fwdev_$1"
	case "$_fz_c" in *"\"$2\""*) return 0 ;; esac
	_ev "firewall has no rules for $2 ($1) - reloading it so LAN clients get internet"
	( /etc/init.d/firewall reload ) >/dev/null 2>&1 </dev/null 9>&- &
}

wan_nets() {
	if [ -z "$_WANNETS_DONE" ]; then
		_WANNETS_DONE=1
		_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
		[ -n "$_z" ] && _WANNETS=$(uci -q get "firewall.$_z.network")
		_WANNETS="$_WANNETS $(extra_uplink_nets "$_WANNETS" | tr '\n' ' ')"
	fi
	printf '%s\n' "$_WANNETS"
}

_ev() {
	logger -t 5gmodem "watchdog: $1"
	mkdir -p "$HDIR"
	printf '%s %s\n' "$(date '+%H:%M')" "$1" > "$HDIR/.last_event"
}

sec_for_iface_h() {
	_sfs_first=""; _sfs_live=""; _sfs_imei=""
	_sfs_want=$(uci -q get "network.$1.modem_imei")
	for _sfs in $(uci show "$CFG" 2>/dev/null | sed -n "s/^5gmodem\.\([^.]*\)=modem\$/\1/p"); do
		[ "$(uci -q get "$CFG.$_sfs.network")" = "$1" ] || continue
		_sfs_p=$(uci -q get "$CFG.$_sfs.path")
		[ -n "$_sfs_p" ] || continue
		[ -n "$_sfs_first" ] || _sfs_first="$_sfs"
		[ -e "/sys/bus/usb/devices/$_sfs_p" ] || continue
		[ -n "$_sfs_live" ] || _sfs_live="$_sfs"
		if [ -n "$_sfs_want" ] && [ "$(uci -q get "$CFG.$_sfs.imei")" = "$_sfs_want" ]; then
			_sfs_imei="$_sfs"
			break
		fi
	done
	_sfs="${_sfs_imei:-${_sfs_live:-$_sfs_first}}"
	[ -n "$_sfs" ] || return 1
	printf '%s\n' "$_sfs"
	return 0
}

_WLDUMP=""; _WLDUMP_DONE=""
is_wifi_iface() {
	if [ -z "$_WLDUMP_DONE" ]; then
		_WLDUMP_DONE=1
		_WLDUMP=$(uci show wireless 2>/dev/null)
	fi
	case "$_WLDUMP" in
		*".network='$1'"*) return 0 ;;
		*) return 1 ;;
	esac
}

wifi_secs_for() {
	is_wifi_iface "$1" || return 1
	printf '%s\n' "$_WLDUMP" | sed -n "s/^wireless\.\([^.]*\)\.network='\?$1'\?\$/\1/p"
}

wifi_sta_count() {
	_wc_n=0
	for _wc_s in $(wifi_secs_for "$1"); do
		[ "$(uci -q get "wireless.$_wc_s.disabled")" = "1" ] && continue
		[ "$(uci -q get "wireless.$_wc_s.mode")" = "sta" ] || continue
		_wc_n=$((_wc_n + 1))
	done
	printf '%s\n' "$_wc_n"
}

_WLST=""; _WLST_DONE=""
wifi_radio_for() {
	is_wifi_iface "$1" || return 1
	_wr_dev=$(printf '%s' "$_HDUMP" | jsonfilter \
		-e "@.interface[@.interface=\"$1\"].device" 2>/dev/null | head -1)
	if [ -n "$_wr_dev" ]; then
		if [ -z "$_WLST_DONE" ]; then
			_WLST_DONE=1
			_WLST=$(ubus call network.wireless status 2>/dev/null)
		fi
		for _wr_r in $(printf '%s\n' "$_WLDUMP" | sed -n "s/^wireless\.\([^.]*\)=wifi-device\$/\1/p"); do
			printf '%s' "$_WLST" | jsonfilter -e "@['$_wr_r'].interfaces[*].ifname" 2>/dev/null \
				| grep -qx "$_wr_dev" && { printf '%s\n' "$_wr_r"; return 0; }
		done
	fi
	for _wr_s in $(wifi_secs_for "$1"); do
		[ "$(uci -q get "wireless.$_wr_s.disabled")" = "1" ] && continue
		_wr_d=$(printf '%s\n' "$_WLDUMP" | sed -n "s/^wireless\.$_wr_s\.device='\?\([^']*\)'\?\$/\1/p" | head -1)
		[ -n "$_wr_d" ] && { printf '%s\n' "$_wr_d"; return 0; }
	done
	return 1
}

iface_dev() {
	printf '%s' "$_HDUMP" | jsonfilter -e "@.interface[@.interface=\"$1\"].l3_device" 2>/dev/null | head -1
}

probe_dev() {
	_pd_dev="$1"; H_MS=""; H_RESTR=""
	for _pd_t in $H_TGT; do
		_pd_o=$(ping -I "$_pd_dev" -c 1 -W 2 "$_pd_t" 2>/dev/null)
		case "$_pd_o" in
			*"(198.18."*|*"(198.19."*) continue ;;
		esac
		case "$_pd_o" in
			*" 0% packet loss"*|*"1 packets received"*)
				H_MS=$(printf '%s\n' "$_pd_o" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
				H_MS="${H_MS%%.*}"
				return 0 ;;
		esac
	done
	command -v curl >/dev/null 2>&1 || return 1
	for _pd_t in $H_TGT; do
		case "$_pd_t" in *[A-Za-z]*) continue ;; esac
		# see docs/subsystems/health-and-recovery.md#curl-interface-if-prefix
		_pd_tc=$(curl -s -m 3 --interface "if!$_pd_dev" -o /dev/null -w '%{time_connect}' "https://$_pd_t/" 2>/dev/null)
		case "$_pd_tc" in
			''|0|0.000000) ;;
			*)
				H_MS=$(printf '%s' "$_pd_tc" | awk '{printf "%d", $1 * 1000}')
				return 0 ;;
		esac
	done
	probe_restricted "$_pd_dev"
}

probe_restricted() {
	[ -n "$H_RTGT" ] || return 1
	mkdir -p "$HDIR"
	_pr_pids=""; _pr_n=0
	for _pr_t in $H_RTGT; do
		case "$_pr_t" in *[!0-9.]*) continue ;; esac
		_pr_n=$((_pr_n + 1))
		(
			_pr_c=$(curl -s -m 3 --interface "if!$1" -o /dev/null -w '%{time_connect}' "https://$_pr_t/" 2>/dev/null)
			case "$_pr_c" in ''|0|0.000000) ;; *) printf '%s\n' "$_pr_c" > "$HDIR/.rp.$$.$_pr_n" ;; esac
		) </dev/null >/dev/null 2>&1 9>&- &
		_pr_pids="$_pr_pids $!"
	done
	[ -n "$_pr_pids" ] || return 1
	wait $_pr_pids 2>/dev/null
	_pr_c=$(cat "$HDIR"/.rp.$$.* 2>/dev/null | head -n 1)
	rm -f "$HDIR"/.rp.$$.* 2>/dev/null
	[ -n "$_pr_c" ] || return 1
	H_MS=$(printf '%s' "$_pr_c" | awk '{printf "%d", $1 * 1000}')
	H_RESTR=1
	return 0
}

restricted_mark() {
	if [ -n "$H_RESTR" ]; then
		[ -f "$HDIR/.restricted_$1" ] && return 0
		if [ ! -f "$HDIR/.restricted_p_$1" ]; then
			: > "$HDIR/.restricted_p_$1"
			return 0
		fi
		rm -f "$HDIR/.restricted_p_$1"
		: > "$HDIR/.restricted_$1"
		_ev "link $1: only whitelisted services answer (restricted network) - kept as alive, no healing"
	else
		rm -f "$HDIR/.restricted_p_$1"
		if [ -f "$HDIR/.restricted_$1" ]; then
			rm -f "$HDIR/.restricted_$1"
			_ev "link $1: full internet is back"
		fi
	fi
}

probe_proxy() {
	command -v curl >/dev/null 2>&1 || return 1
	_pp_p=$(net_proxy_port) || return 1
	for _pp_t in $H_TGT; do
		case "$_pp_t" in *[A-Za-z]*) continue ;; esac
		curl -sk -m 5 -x "http://127.0.0.1:$_pp_p" -o /dev/null "https://$_pp_t/" 2>/dev/null && return 0
	done
	return 1
}

judge() {
	_j_if="$1"; _j_ok="$2"; _j_ms="$3"
	_j_st=unknown; _j_f=0; _j_o=0; _j_lms=""; _j_since=$(uptime_s)
	[ -f "$HDIR/$_j_if" ] && read -r _j_st _j_f _j_o _j_lms _j_since < "$HDIR/$_j_if"
	_j_new="$_j_st"
	if [ "$_j_ok" = 1 ]; then
		_j_f=0; _j_o=$((_j_o + 1)); _j_lms="$_j_ms"
		case "$_j_st" in unknown|gone) _j_new=up ;; esac
		[ "$_j_st" = down ] && [ "$_j_o" -ge "$H_OKN" ] && _j_new=up
	else
		_j_o=0; _j_f=$((_j_f + 1))
		[ "$_j_st" != down ] && [ "$_j_f" -ge "$H_FAILN" ] && _j_new=down
	fi
	if [ "$_j_new" != "$_j_st" ]; then
		_j_since=$(uptime_s)
		if [ "$_j_new" = up ]; then
			_j_wasdown=""
			[ "$_j_st" = down ] && _j_wasdown=1
			[ "$_j_st" = gone ] && [ -f "$HDIR/$_j_if.heal" ] && _j_wasdown=1
			_j_hl=0
			[ -f "$HDIR/$_j_if.heal" ] && read -r _ _j_hl _ < "$HDIR/$_j_if.heal"
			case "$_j_hl" in ''|*[!0-9]*) _j_hl=0 ;; esac
			[ $(( $(uptime_s) - _j_hl )) -ge 900 ] && rm -f "$HDIR/$_j_if.heal"
			rm -f "$HDIR/$_j_if.nosim" "$HDIR/$_j_if.nodata" \
				"$HDIR/$_j_if.mmoff" "$HDIR/$_j_if.on2g" "$HDIR/$_j_if.srch" "$HDIR/$_j_if.noproto"
			if [ "$H_FB" = "demote" ] && [ -n "$_j_wasdown" ]; then
				: > "$HDIR/$_j_if.demoted"
				_ev "link $_j_if is back - kept at the end (per settings)"
			else
				_ev "link $_j_if is back"
			fi
		else
			_ev "link $_j_if went down (missed $_j_f/$H_FAILN pings)"
		fi
	fi
	if [ "$_j_new" = up ] && [ "$_j_st" = up ] && [ -f "$HDIR/$_j_if.heal" ]; then
		_j_hl=0
		read -r _ _j_hl _ < "$HDIR/$_j_if.heal"
		case "$_j_hl" in ''|*[!0-9]*) _j_hl=0 ;; esac
		[ $(( $(uptime_s) - _j_hl )) -ge 900 ] && rm -f "$HDIR/$_j_if.heal"
	fi
	printf '%s %s %s %s %s\n' "$_j_new" "$_j_f" "$_j_o" "${_j_lms:-0}" "$_j_since" > "$HDIR/$_j_if.tmp" \
		&& mv "$HDIR/$_j_if.tmp" "$HDIR/$_j_if"
}

round() {
	mkdir -p "$HDIR"
	ucinet_snapshot
	uptime_s > "$HDIR/.t"
	_HDUMP=$(ubus call network.interface dump 2>/dev/null)
	for _r_n in $(wan_nets); do
		case "$_r_n" in
			*6) _r_p=$(ucinet_get "$_r_n" proto)
			    [ -n "$_r_p" ] || _r_p=$(printf '%s' "$_HDUMP" \
				| jsonfilter -e "@.interface[@.interface='$_r_n'].proto" 2>/dev/null | head -1)
			    case "$_r_p" in dhcpv6|6in4|6to4|6rd) rm -f "$HDIR/$_r_n"; continue ;; esac ;;
		esac
		_r_dev=$(iface_dev "$_r_n")
		[ -n "$_r_dev" ] || _r_dev=$(iface_dev "${_r_n}_4")
		if [ -z "$_r_dev" ]; then
			rm -f "$HDIR/.fwdev_$_r_n"
			if [ -f "$HDIR/$_r_n" ]; then
				read -r _r_ost _ _ _ _r_osince < "$HDIR/$_r_n"
				_r_gs=$(uptime_s)
				[ "$_r_ost" = gone ] && _r_gs="$_r_osince"
				printf 'gone 0 0 0 %s\n' "$_r_gs" > "$HDIR/$_r_n.tmp" \
					&& mv "$HDIR/$_r_n.tmp" "$HDIR/$_r_n"
			else
				_r_sec=$(sec_for_iface_h "$_r_n")
				if [ -n "$_r_sec" ]; then
					_r_pth=$(uci -q get "$CFG.$_r_sec.path")
					if [ -n "$_r_pth" ] && [ -e "/sys/bus/usb/devices/$_r_pth" ] \
					   && [ "$(uci -q get "network.$_r_n.auto")" != "0" ] \
					   && [ "$(uci -q get "network.$_r_n.disabled")" != "1" ]; then
						printf 'gone 0 0 0 %s\n' "$(uptime_s)" > "$HDIR/$_r_n.tmp" \
							&& mv "$HDIR/$_r_n.tmp" "$HDIR/$_r_n"
					fi
				fi
			fi
			continue
		fi
		if probe_dev "$_r_dev"; then judge "$_r_n" 1 "$H_MS"; restricted_mark "$_r_n"; fw_zone_check "$_r_n" "$_r_dev"; else judge "$_r_n" 0 ""; fi
	done
	_r_zone=" $(wan_nets | tr '\n' ' ') "
	for _r_f in "$HDIR"/*; do
		[ -f "$_r_f" ] || continue
		case "$_r_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		_r_bn="${_r_f##*/}"
		case "$_r_zone" in
			*" $_r_bn "*) ;;
			*) rm -f "$_r_f" "$_r_f.heal" "$_r_f.demoted" "$_r_f.nosim" \
				"$_r_f.nodata" "$_r_f.mmoff" "$_r_f.on2g" "$_r_f.srch" "$_r_f.noproto" ;;
		esac
	done
}

PEN=1000

base_metric() {
	_bm=$(ucinet_get "$1" metric); case "$_bm" in ''|*[!0-9]*) _bm=0 ;; esac
	printf '%s' "$_bm"
}

_rt4_args() {
	_r4=$(ucinet_get "$1" ip4table)
	[ -n "$_r4" ] && printf 'table %s' "$_r4"
}

_move_defaults() {
	for _fam in -4 -6; do
		if [ "$_fam" = "-4" ]; then
			_mt_l="$(ucinet_get "$3" ip4table)"
		else
			_mt_l="$(ucinet_get "$3" ip6table) $(ucinet_get "${3}6" ip6table) $(ucinet_get "${3}_6" ip6table)"
		fi
		_mt_seen=""
		for _mt in "" $_mt_l; do
			case " $_mt_seen " in *" ${_mt:-main} "*) continue ;; esac
			_mt_seen="$_mt_seen ${_mt:-main}"
			_mt_a=""; [ -n "$_mt" ] && _mt_a="table $_mt"
			ip "$_fam" route show default $_mt_a 2>/dev/null \
				| grep -v '^default from ' \
				| grep -E " dev $1( |$)" | while read -r _ln; do
				_cm=$(printf '%s' "$_ln" | sed -n 's/.*metric \([0-9]*\).*/\1/p'); _cm="${_cm:-0}"
				[ "$_cm" = "$2" ] && continue
				_gw=$(printf '%s' "$_ln" | sed -n 's/.*via \([^ ]*\).*/\1/p')
				route_add_default "$_fam" "$1" "$2" "$_gw" "$_mt_a" || continue
				[ "$RAD_METRIC" = "$_cm" ] && continue
				ip "$_fam" route del default dev "$1" metric "$_cm" $_mt_a 2>/dev/null
			done
		done
	done
}

_nd_gw() {
	for _ng_n in "$1" "${1}$3"; do
		_ng_v=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_ng_n\"].route[@.target=\"$2\"].nexthop" 2>/dev/null | head -1)
		[ -n "$_ng_v" ] && { printf '%s' "$_ng_v"; return 0; }
	done
	return 1
}

_rt6_args() {
	for _r6 in "$(ucinet_get "$1" ip6table)" \
			"$(ucinet_get "${1}6" ip6table)" \
			"$(ucinet_get "${1}_6" ip6table)"; do
		[ -n "$_r6" ] && { printf 'table %s' "$_r6"; return 0; }
	done
}

_ensure_defaults() {
	_ed_a=$(_rt4_args "$3")
	if ! ip -4 route show default $_ed_a 2>/dev/null | grep -qE " dev $1( |$)" \
	   && ip -4 addr show dev "$1" 2>/dev/null | grep -q ' inet '; then
		if _ed_gw=$(_nd_gw "$3" "0.0.0.0" _4); then
			[ "$_ed_gw" = "0.0.0.0" ] && _ed_gw=""
			route_add_default -4 "$1" "$2" "$_ed_gw" "$_ed_a" && \
				_ev "$3 had no default route - restored (metric $2)"
		fi
	fi
	_ed_a6=$(_rt6_args "$3")
	if ! ip -6 route show default $_ed_a6 2>/dev/null | grep -qE " dev $1( |$)" \
	   && ip -6 addr show dev "$1" scope global 2>/dev/null | grep -q ' inet6 '; then
		if _ed_gw6=$(_nd_gw "$3" "::" _6); then
			[ "$_ed_gw6" = "::" ] && _ed_gw6=""
			[ -n "$_ed_gw6" ] && route_add_default -6 "$1" "$2" "$_ed_gw6" "$_ed_a6" && \
				_ev "$3 had no IPv6 default route - restored (metric $2)"
		fi
	fi
}

_dns_demote() {
	_dd_f=/tmp/resolv.conf.d/resolv.conf.auto
	[ -n "$1" ] || return 0
	[ -f "$_dd_f" ] || return 0
	_dd_out="$_dd_f.5gmodem"
	awk -v dead=" $1 " '
		/^# Interface / {
			ifc = $3
			sub(/_[46]$/, "", ifc)
			skip = (index(dead, " " ifc " ") > 0)
			if (skip) next
		}
		skip && /^nameserver /  { next }
		skip && /^# Interface / { }
		{ print }
	' "$_dd_f" > "$_dd_out" 2>/dev/null || { rm -f "$_dd_out"; return 0; }
	if ! grep -q '^nameserver ' "$_dd_out" 2>/dev/null; then
		rm -f "$_dd_out"; return 0
	fi
	if cmp -s "$_dd_out" "$_dd_f"; then rm -f "$_dd_out"; return 0; fi
	cat "$_dd_out" > "$_dd_f" 2>/dev/null
	rm -f "$_dd_out"
	killall -HUP dnsmasq 2>/dev/null
	_ev "dropped DNS servers of the dead link(s):$1 - the resolver list follows the traffic now"
}

_dns_restore() {
	_dr_f=/tmp/resolv.conf.d/resolv.conf.auto
	[ -f "$_dr_f" ] || return 0
	grep -qE "^# Interface $1(_4)?\$" "$_dr_f" && return 0
	_dr_ns=$(printf '%s' "$_HDUMP" | jsonfilter -e "@.interface[@.interface=\"$1\"]['dns-server'][*]" 2>/dev/null)
	_dr_n="$1"
	if [ -z "$_dr_ns" ]; then
		_dr_ns=$(printf '%s' "$_HDUMP" | jsonfilter -e "@.interface[@.interface=\"${1}_4\"]['dns-server'][*]" 2>/dev/null)
		_dr_n="${1}_4"
	fi
	[ -n "$_dr_ns" ] || return 0
	{ printf '# Interface %s\n' "$_dr_n"; printf 'nameserver %s\n' $_dr_ns; } >> "$_dr_f" 2>/dev/null
	killall -HUP dnsmasq 2>/dev/null
	_ev "returned DNS servers of $1"
}

enforce() {
	_e_anyup=""; _e_cnt=0; _e_min=""; _e_dead=""
	for _e_f in "$HDIR"/*; do
		[ -f "$_e_f" ] || continue; case "$_e_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		read -r _e_st _ _ _ _ < "$_e_f" || continue
		_e_cnt=$((_e_cnt + 1))
		[ "$_e_st" = up ] && _e_anyup=1
		_e_mm=$(base_metric "${_e_f##*/}")
		if [ -z "$_e_min" ] || [ "$_e_mm" -lt "$_e_min" ]; then _e_min="$_e_mm"; fi
	done
	for _e_f in "$HDIR"/*; do
		[ -f "$_e_f" ] || continue; case "$_e_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		_e_if="${_e_f##*/}"
		read -r _e_st _ _ _ _ < "$_e_f" || continue
		_e_dev=$(iface_dev "$_e_if"); [ -n "$_e_dev" ] || _e_dev=$(iface_dev "${_e_if}_4")
		[ -n "$_e_dev" ] || continue
		_e_base=$(base_metric "$_e_if")
		if [ "$_e_st" = down ] && [ -n "$_e_anyup" ] && [ "$H_FO" = "1" ]; then
			_e_want=$((_e_base + PEN))
			_e_ta=$(_rt4_args "$_e_if")
			_e_cur=$(ip -4 route show default $_e_ta 2>/dev/null | awk -v d="$_e_dev" '
				$0 ~ (" dev " d " ") || $0 ~ (" dev " d "$") {
					m = 0
					for (i = 1; i <= NF; i++) if ($i == "metric") m = $(i + 1)
					print m; exit
				}')
			[ -n "$_e_cur" ] || _e_cur=0
			if [ "$_e_cur" != "$_e_want" ]; then
				_ev "$_e_if has no internet - steering traffic away (metric $_e_base -> $_e_want)"
			fi
			_e_dead="$_e_dead $_e_if"
			_e_target=$_e_want
		elif [ "$_e_st" = up ] && [ "$H_FO" = "1" ] && [ "$_e_cnt" -gt 1 ] \
		     && { [ -f "$_e_f.demoted" ] || { is_manual "$_e_if" && [ "$_e_base" -gt "$_e_min" ]; }; }; then
			_e_target=$((_e_base + PEN))
		else
			if ip -4 route show default $(_rt4_args "$_e_if") 2>/dev/null | grep -E " dev $_e_dev( |$)" | grep -qE "metric $((_e_base + PEN))( |$)"; then
				_ev "$_e_if - restoring priority (metric $_e_base)"
				[ "$_e_st" = up ] && _dns_restore "$_e_if"
			fi
			_e_target=$_e_base
		fi
		_ensure_defaults "$_e_dev" "$_e_target" "$_e_if"
		_move_defaults "$_e_dev" "$_e_target" "$_e_if"
	done
	[ -n "$_e_anyup" ] && _dns_demote "$_e_dead"
}

HEAL_COOLDOWN=$(conf heal_cooldown); case "$HEAL_COOLDOWN" in ''|*[!0-9]*) HEAL_COOLDOWN=300 ;; esac
HEAL_MAX=6

GONE_HEAL_MIN=180

STUCK_DOWN_MIN=900

heal_cap() { case "$1" in none) echo 0 ;; ifup) echo 1 ;; power) echo 3 ;; *) echo 2 ;; esac }

sim_absent() {
	if [ "$(uci -q get "$CFG.$1.kind")" = "hilink" ]; then
		_sa_ss=$("$RES/hilink.sh" json "$2" 2>/dev/null \
			| jsonfilter -e '@.sim_status' 2>/dev/null)
		case "$_sa_ss" in 0|255) return 0 ;; esac
		return 1
	fi
	_sa_idx=$("$RES/modemswitch.sh" mmindex "$2" 2>/dev/null)
	if [ -n "$_sa_idx" ] && command -v mmcli >/dev/null 2>&1; then
		mmcli -m "$_sa_idx" -K 2>/dev/null \
			| grep -q "state-failed-reason *: *sim-missing" && return 0
		return 1
	fi
	_sa_at=$(uci -q get "$CFG.$1.at_port")
	[ -n "$_sa_at" ] && [ -e "$_sa_at" ] || return 1
	case "$(readlink -f "/sys/class/tty/${_sa_at##*/}/device" 2>/dev/null)" in
		*"/$2:"*) ;;
		*) return 1 ;;
	esac
	_sa_o=$(at_query "$_sa_at" "AT+CPIN?" 3 2>/dev/null | tr -d '\r')
	case "$_sa_o" in
		*"not inserted"*|*"SIM_ABSENT"*) return 0 ;;
	esac
	printf '%s\n' "$_sa_o" | grep -qx '+CME ERROR: 10' && return 0
	return 1
}

heal() {
	[ "$H_HEAL" = "1" ] || [ "$H_HEALWIFI" = "1" ] || return 0
	_h_cnt=0; _h_anyup=""
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		read -r _h_st _ _ _ _ < "$_h_f" || continue
		_h_cnt=$((_h_cnt + 1))
		[ "$_h_st" = up ] && _h_anyup=1
	done
	if [ -z "$_h_anyup" ] && [ "$_h_cnt" -ge 1 ] && [ "$H_PG" = "1" ] && probe_proxy; then
		_pg_last=$(cat /tmp/5gmodem/health.fwguard 2>/dev/null)
		case "$_pg_last" in ''|*[!0-9]*) _pg_last=0 ;; esac
		_pg_now=$(uptime_s)
		if [ $((_pg_now - _pg_last)) -ge 1800 ] || [ "$_pg_now" -lt "$_pg_last" ]; then
			uptime_s > /tmp/5gmodem/health.fwguard
			_ev "all links fail direct probes, but the internet works via the local proxy - probes look firewall-blocked, healing suspended"
		fi
		return 0
	fi
	_h_dmax=0
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		read -r _h_st _ _ _ _h_since < "$_h_f" || continue
		[ "$_h_st" = down ] || continue
		case "$_h_since" in ''|*[!0-9]*) continue ;; esac
		[ "$_h_since" -gt "$_h_dmax" ] && _h_dmax="$_h_since"
	done
	_h_dcnt=0
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		read -r _h_st _ _ _ _h_since < "$_h_f" || continue
		[ "$_h_st" = down ] || continue
		case "$_h_since" in ''|*[!0-9]*) continue ;; esac
		[ $((_h_dmax - _h_since)) -le 300 ] && _h_dcnt=$((_h_dcnt + 1))
	done
	if [ "$_h_dcnt" -gt 1 ] && [ -z "$_h_anyup" ]; then
		_ad_last=$(cat /tmp/5gmodem/health.alldown 2>/dev/null)
		case "$_ad_last" in ''|*[!0-9]*) _ad_last=0 ;; esac
		_ad_now=$(uptime_s)
		if [ $((_ad_now - _ad_last)) -ge 1800 ] || [ "$_ad_now" -lt "$_ad_last" ]; then
			uptime_s > /tmp/5gmodem/health.alldown
			_ev "all $_h_dcnt watched links went down together - looks like a common cause, not a modem fault: healing suspended"
		fi
		return 0
	fi
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto) continue ;; esac
		_h_if="${_h_f##*/}"
		read -r _h_st _ _ _ _h_since < "$_h_f" || continue
		if [ "$H_HEALWIFI" = "1" ] && is_wifi_iface "$_h_if"; then
			case "$_h_st" in down|gone) ;; *) continue ;; esac
			_h_auto=$(printf '%s' "$_HDUMP" | jsonfilter \
				-e "@.interface[@.interface=\"$_h_if\"].autostart" 2>/dev/null)
			[ "$_h_auto" = "false" ] && continue
			if [ "$_h_st" = down ]; then
				_h_wip=$(printf '%s' "$_HDUMP" | jsonfilter \
					-e "@.interface[@.interface=\"$_h_if\"]['ipv4-address'][0].address" 2>/dev/null)
				if [ -n "$_h_wip" ]; then
					_h_wdev=$(printf '%s' "$_HDUMP" | jsonfilter \
						-e "@.interface[@.interface=\"$_h_if\"].device" 2>/dev/null | head -1)
					if [ -n "$_h_wdev" ] && iw dev "$_h_wdev" link 2>/dev/null | grep -q "^Connected"; then
						continue
					fi
				fi
			fi
			_h_stan=$(wifi_sta_count "$_h_if")
			[ "$_h_stan" -gt 0 ] || continue
			_h_multi=""
			if [ "$_h_stan" -gt 1 ]; then
				_h_multi=1
				_h_mw="/tmp/5gmodem/health.multi.$_h_if"
				_h_mwt=$(cat "$_h_mw" 2>/dev/null)
				case "$_h_mwt" in ''|*[!0-9]*) _h_mwt=0 ;; esac
				_h_mnow=$(uptime_s)
				if [ $((_h_mnow - _h_mwt)) -ge 3600 ] || [ "$_h_mnow" -lt "$_h_mwt" ]; then
					printf '%s\n' "$_h_mnow" > "$_h_mw"
					_ev "$_h_if is shared by several enabled Wi-Fi stations - netifd keeps re-attaching the interface and DHCP cannot finish; leave one station per network"
				fi
			fi
			_h_step=0; _h_last=0; _h_n=0
			[ -f "$HDIR/$_h_if.heal" ] && read -r _h_step _h_last _h_n < "$HDIR/$_h_if.heal"
			case "$_h_step" in ''|*[!0-9]*) _h_step=0 ;; esac
			case "$_h_last" in ''|*[!0-9]*) _h_last=0 ;; esac
			case "$_h_n" in ''|*[!0-9]*) _h_n=0 ;; esac
			[ "$_h_n" -lt "$HEAL_MAX" ] || continue
			_h_now=$(uptime_s)
			[ $((_h_now - _h_last)) -ge "$HEAL_COOLDOWN" ] || continue
			_h_n=$((_h_n + 1))
			if [ "$_h_step" -lt 1 ] && [ "$_h_st" = down ]; then
				_h_next=1
				_ev "healing $_h_if: reconnecting Wi-Fi ($_h_n/$HEAL_MAX)"
				( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
			elif [ "$_h_step" -lt 2 ]; then
				_h_next=2
				_h_sta=$(printf '%s' "$_HDUMP" | jsonfilter \
					-e "@.interface[@.interface=\"$_h_if\"].device" 2>/dev/null | head -1)
				if [ -n "$_h_sta" ]; then
					_ev "healing $_h_if: reconnecting station $_h_sta ($_h_n/$HEAL_MAX)"
					( ubus call "wpa_supplicant.$_h_sta" control '{"command":"REASSOCIATE"}' \
					    || iw dev "$_h_sta" disconnect
					  sleep 6; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: station unknown, reconnecting the interface ($_h_n/$HEAL_MAX)"
					( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
			elif [ "$_h_step" -lt 3 ] || [ -n "$_h_anyup" ] || [ -n "$_h_multi" ]; then
				_h_next=3
				_h_radio=$(wifi_radio_for "$_h_if")
				if [ -n "$_h_radio" ]; then
					_ev "healing $_h_if: rebuilding radio $_h_radio ($_h_n/$HEAL_MAX)"
					( ubus call network.wireless down "{\"device\":\"$_h_radio\"}"
					  sleep 2
					  ubus call network.wireless up "{\"device\":\"$_h_radio\"}"
					  sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: radio unknown, reconnecting the interface ($_h_n/$HEAL_MAX)"
					( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
			else
				_h_next=4
				_ev "healing $_h_if: rebuilding the whole network, network reload ($_h_n/$HEAL_MAX)"
				( ubus call network reload; sleep 2; wifi up >/dev/null 2>&1; sleep 3; ifup "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
			fi
			printf '%s %s %s\n' "$_h_next" "$_h_now" "$_h_n" > "$HDIR/$_h_if.heal"
			[ "$_h_n" -ge "$HEAL_MAX" ] && _ev "healing $_h_if: attempts exhausted - manual intervention needed"
			continue
		fi
		case "$_h_st" in
			down) ;;
			gone)
				case "$_h_since" in ''|*[!0-9]*) continue ;; esac
				[ $(( $(uptime_s) - _h_since )) -ge "$GONE_HEAL_MIN" ] || continue ;;
			*) continue ;;
		esac
		[ "$H_HEAL" = "1" ] || continue
		_h_auto=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"].autostart" 2>/dev/null)
		if [ "$_h_auto" = "false" ]; then
			[ "$(uci -q get "network.$_h_if.auto")" = "0" ] && continue
			[ "$(uci -q get "network.$_h_if.disabled")" = "1" ] && continue
			if [ -z "$(printf '%s' "$_HDUMP" | jsonfilter \
				-e "@.interface[@.interface=\"$_h_if\"].errors[0].code" 2>/dev/null)" ]; then
				case "$_h_since" in ''|*[!0-9]*) continue ;; esac
				[ $(( $(uptime_s) - _h_since )) -ge "$STUCK_DOWN_MIN" ] || continue
			fi
		fi
		_h_sec=$(sec_for_iface_h "$_h_if") || continue
		_h_cap=$(heal_cap "$(uci -q get "$CFG.$_h_sec.heal")")
		[ "$_h_cap" -ge 1 ] || continue
		_h_illegal=""
		case "$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"].errors[0].code" 2>/dev/null)" in
			SIM_ILLEGAL_STATE) _h_illegal=1; [ "$_h_cap" -lt 2 ] && _h_cap=2 ;;
		esac
		_h_path=$(uci -q get "$CFG.$_h_sec.path")
		[ -n "$_h_path" ] || continue
		_h_absent=""
		if ! [ -e "/sys/bus/usb/devices/$_h_path" ]; then
			[ "$_h_cap" -ge 3 ] && [ "$_h_st" = gone ] || continue
			_h_absent=1
		fi
		_h_step=0; _h_last=0; _h_n=0
		[ -f "$HDIR/$_h_if.heal" ] && read -r _h_step _h_last _h_n < "$HDIR/$_h_if.heal"
		case "$_h_step" in ''|*[!0-9]*) _h_step=0 ;; esac
		case "$_h_last" in ''|*[!0-9]*) _h_last=0 ;; esac
		case "$_h_n" in ''|*[!0-9]*) _h_n=0 ;; esac
		[ "$_h_n" -lt "$HEAL_MAX" ] || continue
		_h_now=$(uptime_s)
		[ $((_h_now - _h_last)) -ge "$HEAL_COOLDOWN" ] || continue
		if [ -z "$_h_absent" ] && sim_absent "$_h_sec" "$_h_path"; then
			if [ ! -f "$HDIR/$_h_if.nosim" ]; then
				: > "$HDIR/$_h_if.nosim"
				_ev "healing $_h_if: no SIM inserted - healing postponed"
			fi
			continue
		fi
		rm -f "$HDIR/$_h_if.nosim"
		_h_pr=$(uci -q get "network.$_h_if.proto")
		case "$_h_pr" in
			''|static|none) ;;
			*)
				if [ ! -f "/lib/netifd/proto/$_h_pr.sh" ]; then
					if [ ! -f "$HDIR/$_h_if.noproto" ]; then
						: > "$HDIR/$_h_if.noproto"
						_ev "healing $_h_if: protocol $_h_pr is not installed - healing postponed"
					fi
					continue
				fi
				rm -f "$HDIR/$_h_if.noproto"
				;;
		esac
		_h_lip=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"]['ipv4-address'][0].address" 2>/dev/null)
		[ -n "$_h_lip" ] || _h_lip=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"${_h_if}_4\"]['ipv4-address'][0].address" 2>/dev/null)
		if [ -n "$_h_lip" ]; then
			_h_l3=$(printf '%s' "$_HDUMP" | jsonfilter \
				-e "@.interface[@.interface=\"$_h_if\"].l3_device" 2>/dev/null)
			if [ -n "$_h_l3" ] && ! ip -4 addr show dev "$_h_l3" 2>/dev/null \
				| grep -q "inet $_h_lip"; then
				_h_lip=""
			fi
		fi
		if [ -n "$_h_lip" ]; then
			_h_2g=""
			_h_mk=$(echo "$_h_path" | tr -c 'A-Za-z0-9' '_')
			_h_ms="/tmp/5gmodem/metrics_${_h_mk}.json"
			if [ -s "$_h_ms" ]; then
				_h_mst=$(cat "/tmp/5gmodem/metrics_${_h_mk}.stamp" 2>/dev/null)
				case "$_h_mst" in
					''|*[!0-9]*) ;;
					*) if [ $(( $(uptime_s) - _h_mst )) -le 300 ]; then
						case "$(jsonfilter -i "$_h_ms" -e '@.mode' 2>/dev/null)" in
							*GSM*|*EDGE*|*GPRS*|2G*) _h_2g=1 ;;
						esac
					   fi ;;
				esac
			fi
			if [ -n "$_h_2g" ]; then
				if [ ! -f "$HDIR/$_h_if.on2g" ]; then
					: > "$HDIR/$_h_if.on2g"
					_ev "$_h_if: modem dropped to 2G and data is dead - treating as a failure, healing continues"
				fi
			else
				rm -f "$HDIR/$_h_if.on2g"
				if [ ! -f "$HDIR/$_h_if.nodata" ]; then
					printf 'try %s\n' "$(uptime_s)" > "$HDIR/$_h_if.nodata"
					rm -f "$HDIR/$_h_if.heal"
					_ev "$_h_if: has an address ($_h_lip) but no traffic - one reconnect before calling it a carrier restriction"
					( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
					continue
				fi
				_h_nd=$(cat "$HDIR/$_h_if.nodata" 2>/dev/null)
				case "$_h_nd" in
					try\ *)
						_h_ndt=${_h_nd#try }
						case "$_h_ndt" in ''|*[!0-9]*) _h_ndt=0 ;; esac
						[ $(( $(uptime_s) - _h_ndt )) -ge 120 ] || continue
						: > "$HDIR/$_h_if.nodata"
						_ev "$_h_if: still no traffic after a reconnect ($_h_lip) - looks like a carrier restriction, healing stopped"
						;;
				esac
				continue
			fi
		fi
		rm -f "$HDIR/$_h_if.nodata"
		if command -v mmcli >/dev/null 2>&1; then
			_h_mmi=$("$RES/modemswitch.sh" mmindex "$_h_path" 2>/dev/null)
			if [ -n "$_h_mmi" ]; then
				_h_mms=$(mmcli -m "$_h_mmi" -K 2>/dev/null \
					| sed -n 's/^modem\.generic\.state *: *//p' | head -1)
				case "$_h_mms" in
					disabled|locked)
						if [ ! -f "$HDIR/$_h_if.mmoff" ]; then
							: > "$HDIR/$_h_if.mmoff"
							_ev "healing $_h_if: modem disabled in ModemManager ($_h_mms) - enabling"
						fi
						if ! pgrep -f "mmcli -m $_h_mmi --enable" >/dev/null 2>&1; then
							( mmcli -m "$_h_mmi" --enable >/dev/null 2>&1 & _h_mep=$!
							  ( sleep 30; kill "$_h_mep" 2>/dev/null ) >/dev/null 2>&1 & _h_mew=$!
							  wait "$_h_mep" 2>/dev/null
							  kill "$_h_mew" 2>/dev/null ) >/dev/null 2>&1 </dev/null 9>&- &
						fi
						continue ;;
					connected)
						mm_ghost_bearer "$_h_if" "$_h_mmi"
						case $? in
							0) _ev "healing $_h_if: ModemManager stuck in 'connected' after a failed disconnect - modem reset"; continue ;;
							2) continue ;;
						esac ;;
				esac
			fi
		fi
		rm -f "$HDIR/$_h_if.mmoff"
		_h_next=$((_h_step + 1))
		[ "$_h_next" -gt "$_h_cap" ] && _h_next="$_h_cap"
		[ -n "$_h_illegal" ] && [ "$_h_next" -lt 2 ] && _h_next=2
		[ -n "$_h_absent" ] && _h_next=3
		_h_hilink=""
		[ "$(uci -q get "$CFG.$_h_sec.kind")" = "hilink" ] && _h_hilink=1
		_h_at=$(uci -q get "$CFG.$_h_sec.at_port")
		if [ -n "$_h_at" ] && [ -n "$_h_path" ]; then
			case "$(readlink -f "/sys/class/tty/${_h_at##*/}/device" 2>/dev/null)" in
				*"/$_h_path:"*) ;;
				*) _h_at="" ;;
			esac
		fi
		if [ "$_h_next" = 2 ] && [ -z "$_h_hilink" ]; then
			if [ -z "$_h_at" ] || [ ! -e "$_h_at" ]; then
				if [ "$_h_cap" -ge 3 ]; then _h_next=3; else _h_next=1; fi
			fi
		fi
		if [ "$_h_next" -ge 2 ] && [ -z "$_h_hilink" ] && [ -n "$_h_at" ] && [ -e "$_h_at" ]; then
			_h_reg=$(at_query "$_h_at" "AT+CEREG?" 5 3 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
			[ -n "$_h_reg" ] || _h_reg=$(at_query "$_h_at" "AT+CREG?" 5 3 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
			if [ "$_h_reg" = "2" ]; then
				_h_ss=$(cat "$HDIR/$_h_if.srch" 2>/dev/null)
				_h_snew=""
				case "$_h_ss" in ''|*[!0-9]*) _h_ss=$(uptime_s); printf '%s' "$_h_ss" > "$HDIR/$_h_if.srch"; _h_snew=1 ;; esac
				if [ $(( $(uptime_s) - _h_ss )) -lt 720 ]; then
					[ -n "$_h_snew" ] && _ev "healing $_h_if: modem is searching for a network - postponing healing for up to 12 minutes"
					continue
				fi
			else
				rm -f "$HDIR/$_h_if.srch"
			fi
		fi
		_h_n=$((_h_n + 1))
		case "$_h_next" in
			1)
				_ev "healing $_h_if: reconnecting the interface ($_h_n/$HEAL_MAX)"
				( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				;;
			2)
				if [ -n "$_h_hilink" ]; then
					_ev "healing $_h_if: rebooting the module via API ($_h_n/$HEAL_MAX)"
					( "$RES/hilink.sh" reboot "$_h_path" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: rebooting the module, AT+CFUN=1,1 ($_h_n/$HEAL_MAX)"
					( "$RES/reboot_modem.sh" hard "$_h_at" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
				;;
			3)
				if [ -n "$H_PSCRIPT" ] && [ -x "$H_PSCRIPT" ]; then
					_ev "healing $_h_if: running the power script $H_PSCRIPT ($_h_n/$HEAL_MAX)"
					( "$H_PSCRIPT" "$_h_if" "$_h_path" "$_h_at" 2>&1 | head -c 400 | logger -t 5gmodem-power ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: power-cycling the USB port ($_h_n/$HEAL_MAX)"
					( "$RES/reboot_modem.sh" usbpower "$_h_path" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
				;;
		esac
		printf '%s %s %s\n' "$_h_next" "$_h_now" "$_h_n" > "$HDIR/$_h_if.heal"
		[ "$_h_n" -ge "$HEAL_MAX" ] && _ev "healing $_h_if: attempts exhausted - manual intervention needed"
	done
}

LOCK_RELEASE_MIN=600
LOCK_CHECK_EVERY=60
LOCK_GAP=300
LOCK_RETRY=300

_lg_reg() {
	_lr_k=$(snap_key "$1")
	_lr_t=$(cat "/tmp/5gmodem/metrics_$_lr_k.stamp" 2>/dev/null)
	case "$_lr_t" in
		''|*[!0-9]*) ;;
		*)
			_lr_age=$(( $(uptime_s) - _lr_t ))
			if [ "$_lr_age" -ge 0 ] && [ "$_lr_age" -le 90 ]; then
				case "$(jsonfilter -i "/tmp/5gmodem/metrics_$_lr_k.json" -e '@.registration' 2>/dev/null)" in
					1|5) echo yes; return 0 ;;
					0|2|3|4) echo no; return 0 ;;
				esac
			fi ;;
	esac
	if command -v mmcli >/dev/null 2>&1 && pidof ModemManager >/dev/null 2>&1; then
		_lr_mi=$("$RES/modemswitch.sh" mmindex "$1" 2>/dev/null)
		if [ -n "$_lr_mi" ]; then
			case "$(mmcli -m "$_lr_mi" -K 2>/dev/null \
				| sed -n 's/^modem\.3gpp\.registration-state *: *//p' | head -1)" in
				home|roaming) echo yes ;;
				idle|searching|denied) echo no ;;
			esac
			return 0
		fi
	fi
	[ "$(uci -q get "$CFG.$2.kind")" = "hilink" ] && return 0
	[ "$(uci -q get "$CFG.$2.no_at")" = "1" ] && return 0
	_lr_at=$(uci -q get "$CFG.$2.at_port")
	[ -n "$_lr_at" ] && [ -c "$_lr_at" ] || return 0
	case "$(readlink -f "/sys/class/tty/${_lr_at##*/}/device" 2>/dev/null)" in
		*"/$1:"*|*"/$1/"*) ;;
		*) return 0 ;;
	esac
	at_dialer_busy "$_lr_at" && return 0
	_lr_any=""
	for _lr_c in CEREG C5GREG CREG; do
		_lr_s=$(at_query "$_lr_at" "AT+$_lr_c?" 5 3 2>/dev/null | tr -d '\r' \
			| sed -n "s/.*+$_lr_c: *[0-9]*, *\([0-9]*\).*/\1/p" | head -1)
		case "$_lr_s" in
			1|5) echo yes; return 0 ;;
			0|2|3|4) _lr_any=1 ;;
		esac
	done
	[ -n "$_lr_any" ] && echo no
	return 0
}

_lg_save() {
	printf '%s %s %s %s %s %s\n' "$_lg_chk" "$_lg_since" "$_lg_seen" "$_lg_try" "$_lg_done" "$_lg_vk" > "$_lg_f"
}

lock_guard() {
	[ "$H_LR" = "1" ] || return 0
	_lg_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_lg_p" ] || return 0
	_lg_sec="m_$(printf '%s' "$_lg_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_lg_f="/tmp/5gmodem/lockguard.$_lg_sec"
	_lg_v=$(uci -q get "$CFG.$_lg_sec.celllock")
	case "$_lg_v" in
		arfcn\ *|cell\ *) ;;
		*) rm -f "$_lg_f"; return 0 ;;
	esac
	_lg_vk=$(printf '%s' "$_lg_v" | tr -s ' ' '_')
	_lg_chk=0; _lg_since=0; _lg_seen=0; _lg_try=0; _lg_done=0; _lg_was=""
	[ -f "$_lg_f" ] && read -r _lg_chk _lg_since _lg_seen _lg_try _lg_done _lg_was < "$_lg_f"
	case "$_lg_chk" in ''|*[!0-9]*) _lg_chk=0 ;; esac
	case "$_lg_since" in ''|*[!0-9]*) _lg_since=0 ;; esac
	case "$_lg_seen" in ''|*[!0-9]*) _lg_seen=0 ;; esac
	case "$_lg_try" in ''|*[!0-9]*) _lg_try=0 ;; esac
	if [ "$_lg_was" != "$_lg_vk" ]; then
		_lg_chk=0; _lg_since=0; _lg_seen=0; _lg_try=0; _lg_done=0
	fi
	[ "$_lg_done" = "1" ] && return 0
	_lg_now=$(uptime_s)
	[ "$_lg_now" -lt "$_lg_chk" ] && _lg_chk=0
	[ $((_lg_now - _lg_chk)) -ge "$LOCK_CHECK_EVERY" ] || return 0
	_lg_chk="$_lg_now"
	case "$(_lg_reg "$_lg_p" "$_lg_sec")" in
		yes) _lg_since=0 ;;
		no)
			if [ "$_lg_since" = 0 ] || [ $((_lg_now - _lg_seen)) -gt "$LOCK_GAP" ]; then
				_lg_since="$_lg_now"
			fi
			_lg_seen="$_lg_now" ;;
	esac
	_lg_save
	[ "$_lg_since" -gt 0 ] && [ "$_lg_seen" = "$_lg_now" ] || return 0
	[ $((_lg_now - _lg_since)) -ge "$LOCK_RELEASE_MIN" ] || return 0
	[ "$_lg_try" -gt 0 ] && [ $((_lg_now - _lg_try)) -lt "$LOCK_RETRY" ] && return 0
	_lg_try="$_lg_now"
	_lg_o=$(BANDS_ACTIVE_MODEM="$_lg_p" "$RES/bands.sh" celllockrelease 2>/dev/null </dev/null 9>&-)
	case "$_lg_o" in
		*writeonly*|*Unsupported*|*"not remembered"*) _lg_done=1 ;;
	esac
	if [ -z "$(uci -q get "$CFG.$_lg_sec.celllock")" ]; then
		rm -f "$_lg_f"
		logger -t 5gmodem "lock guard: $_lg_p had no network registration for $(( (_lg_now - _lg_since) / 60 )) min with our lock ($(printf '%s' "$_lg_v" | sed 's/ *$//')) applied - lock released, it will not be re-applied automatically"
		return 0
	fi
	_lg_save
}

_teardown() {
	_HDUMP=$(ubus call network.interface dump 2>/dev/null)
	for _td_f in "$HDIR"/*; do
		[ -f "$_td_f" ] || continue
		case "$_td_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.mmoff|*.on2g|*.srch|*.noproto|*.last_event) continue ;; esac
		_td_if="${_td_f##*/}"
		_td_dev=$(iface_dev "$_td_if"); [ -n "$_td_dev" ] || _td_dev=$(iface_dev "${_td_if}_4")
		[ -n "$_td_dev" ] || continue
		_move_defaults "$_td_dev" "$(base_metric "$_td_if")" "$_td_if"
	done
	rm -rf "$HDIR"
	logger -t 5gmodem "watchdog disabled: penalties lifted, metrics restored from uci, state cleared"
}

_off_cleanup() {
	[ -d "$HDIR" ] || exit 0
	exec 9>"/tmp/5gmodem/health.lock"
	flock 9
	_teardown
	exit 0
}

case "$1" in
tick)
	lock_guard
	[ "$H_EN" = "1" ] || _off_cleanup
	mkdir -p "$HDIR"
	_t_last=$(cat "$HDIR/.t" 2>/dev/null); case "$_t_last" in ''|*[!0-9]*) _t_last=0 ;; esac
	_t_now=$(uptime_s)
	[ $((_t_now - _t_last)) -ge $((H_INT - 2)) ] || exit 0
	exec 9>"/tmp/5gmodem/health.lock"
	flock -n 9 || exit 0
	round
	enforce
	heal
	;;
once)
	[ "$H_EN" = "1" ] || _off_cleanup
	mkdir -p "$HDIR"
	( exec >/dev/null 2>&1 </dev/null
	  exec 9>"/tmp/5gmodem/health.lock"
	  flock 9
	  round
	  enforce
	  heal ) &
	echo '{"result":"ok"}'
	sleep 1
	;;
event)
	[ "$H_EN" = "1" ] || exit 0
	case " $(wan_nets) " in *" $2 "*) ;; *) exit 0 ;; esac
	mkdir -p "$HDIR"
	exec 9>"/tmp/5gmodem/health.lock"
	flock 9
	round
	enforce
	;;
getconf)
	_gc_heal=""
	for _gc_s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^5gmodem\.\([^.]*\)=modem\$/\1/p"); do
		_gc_n=$(uci -q get "$CFG.$_gc_s.network"); [ -n "$_gc_n" ] || continue
		[ -n "$(uci -q get "$CFG.$_gc_s.path")" ] || continue
		_gc_heal="$_gc_heal,\"$_gc_n\":\"$(uci -q get "$CFG.$_gc_s.heal")\""
	done
	printf '{"enabled":%s,"interval":%s,"targets":"%s","fail_n":%s,"ok_n":%s,"failover":%s,"failback":"%s","healing":%s,"heal_wifi":%s,"sta_park":%s,"manual":"%s","proxy_guard":%s,"lock_release":%s,"power_script":"%s","heal":{%s}}\n' \
		"${H_EN:-0}" "$H_INT" "$H_TGT" "$H_FAILN" "$H_OKN" "${H_FO:-0}" "$H_FB" "${H_HEAL:-0}" "${H_HEALWIFI:-0}" "$H_STAPARK" "$H_MAN" "$H_PG" "$H_LR" "$H_PSCRIPT" "${_gc_heal#,}"
	;;
setheal)
	case "$3" in ''|none|ifup|reboot|power) ;; *) echo '{"error":"bad level"}'; exit 1 ;; esac
	_sh_sec=$(sec_for_iface_h "$2") || { echo '{"error":"no modem for iface"}'; exit 1; }
	if [ -n "$3" ]; then
		uci -q set "$CFG.$_sh_sec.heal=$3"
	else
		uci -q delete "$CFG.$_sh_sec.heal"
	fi
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;
setconf)
	shift
	uci -q get "$CFG.health" >/dev/null 2>&1 || uci -q set "$CFG.health=health"
	for _sc in "$@"; do
		_sc_k="${_sc%%=*}"; _sc_v="${_sc#*=}"
		case "$_sc_k" in
			enabled|interval|targets|fail_n|ok_n|failover|failback|healing|heal_wifi|sta_park|heal_cooldown|manual|proxy_guard|lock_release) uci -q set "$CFG.health.$_sc_k=$_sc_v" ;;
			power_script)
				case "$_sc_v" in
					'') uci -q delete "$CFG.health.power_script" ;;
					/*[!A-Za-z0-9/._-]*|/) echo '{"error":"bad script path"}'; exit 1 ;;
					/*) uci -q set "$CFG.health.power_script=$_sc_v" ;;
					*) echo '{"error":"bad script path"}'; exit 1 ;;
				esac ;;
		esac
	done
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;
*)
	echo "usage: $0 tick|once|status|getconf|setconf k=v...|setheal <iface> <none|ifup|reboot|power|>" >&2
	exit 1
	;;
esac
