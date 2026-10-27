#!/bin/sh

wan_nets() {
	z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	_wn=""
	[ -n "$z" ] && _wn=$(uci -q get "firewall.$z.network")
	printf '%s %s\n' "$_wn" "$(extra_uplink_nets "$_wn" | tr '\n' ' ')"
}

. /usr/share/5gmodem/atlock.sh
. /usr/share/5gmodem/lib.sh

_IFDUMP=""
ifdump_snapshot() { _IFDUMP=$(ubus call network.interface dump 2>/dev/null); }

_IFMAP=""
ifmap_build() {
	[ -n "$_IFDUMP" ] || return 0
	_IFMAP=$(printf '%s\n' "$_IFDUMP" | awk '
		function flush() { if (name != "") printf "%s|%s|%s|%s\n", name, up, dev, ip4 }
		/"interface": "/ {
			flush()
			name = $0; sub(/.*"interface": "/, "", name); sub(/".*/, "", name)
			up = "false"; dev = ""; ip4 = ""; inact = 0; want4 = 0; gotup = 0
			next
		}
		inact { next }
		/"inactive"/ { inact = 1; next }
		!gotup && /"up": / { up = ($0 ~ /true/) ? "true" : "false"; gotup = 1; next }
		dev == "" && /"l3_device": "/ {
			dev = $0; sub(/.*"l3_device": "/, "", dev); sub(/".*/, "", dev); next
		}
		/"ipv4-address": \[/ { if (ip4 == "" && $0 !~ /\]/) want4 = 1; next }
		/"ipv6-address"/ { want4 = 0 }
		want4 && /"address": "/ {
			ip4 = $0; sub(/.*"address": "/, "", ip4); sub(/".*/, "", ip4)
			want4 = 0; next
		}
		want4 && /\]/ { want4 = 0; next }
		END { flush() }
	' 2>/dev/null)
}
_IFNL='
'
_ifmap_get() {
	_imx="$_IFNL$_IFMAP$_IFNL"
	case "$_imx" in
		*"$_IFNL$1|"*) : ;;
		*) return 1 ;;
	esac
	_img="${_imx#*"$_IFNL$1|"}"
	_img="${_img%%"$_IFNL"*}"
	case "$2" in
		up)  printf '%s' "${_img%%|*}" ;;
		dev) _img="${_img#*|}"; printf '%s' "${_img%%|*}" ;;
		ip4) printf '%s' "${_img##*|}" ;;
	esac
	return 0
}

_NETMAP=""; _M5MAP=""
ucimap_build() {
	[ -n "$_UCINET_SNAP" ] && _NETMAP=$(printf '%s\n' "$_UCINET_SNAP" | awk '
		/^network\./ {
			line = substr($0, 9)
			dot = index(line, "."); if (!dot) next
			sec = substr(line, 1, dot - 1)
			rest = substr(line, dot + 1)
			eq = index(rest, "="); if (!eq) next
			key = substr(rest, 1, eq - 1)
			val = substr(rest, eq + 1)
			gsub(/^\x27|\x27$/, "", val)
			seen[sec] = 1
			if (key == "proto") p[sec] = val
			else if (key == "device") d[sec] = val
			else if (key == "disabled") x[sec] = val
			else if (key == "metric") m[sec] = val
		}
		END { for (s in seen) printf "%s|%s|%s|%s|%s\n", s, p[s], d[s], x[s], m[s] }
	' 2>/dev/null)
	[ -n "$_UCI5G_SNAP" ] && _M5MAP=$(printf '%s\n' "$_UCI5G_SNAP" | awk '
		/^5gmodem\.m_/ {
			line = substr($0, 9)
			dot = index(line, "."); if (!dot) next
			sec = substr(line, 1, dot - 1)
			rest = substr(line, dot + 1)
			eq = index(rest, "="); if (!eq) next
			key = substr(rest, 1, eq - 1)
			val = substr(rest, eq + 1)
			gsub(/^\x27|\x27$/, "", val)
			seen[sec] = 1
			if (key == "network") n[sec] = val
			else if (key == "path") pt[sec] = val
			else if (key == "parked") pk[sec] = val
			else if (key == "kind") k[sec] = val
		}
		END { for (s in seen) printf "%s|%s|%s|%s|%s\n", s, n[s], pt[s], pk[s], k[s] }
	' 2>/dev/null)
}
_map_field() {
	_mfx="$_IFNL$1$_IFNL"
	case "$_mfx" in
		*"$_IFNL$2|"*) : ;;
		*) return 1 ;;
	esac
	_mfv="${_mfx#*"$_IFNL$2|"}"
	_mfv="${_mfv%%"$_IFNL"*}"
	while [ "$3" -gt 1 ]; do set -- "$1" "$2" $(($3 - 1)); _mfv="${_mfv#*|}"; done
	printf '%s' "${_mfv%%|*}"
	return 0
}
_NP_WLS=""; _NP_WLS_DONE=""
_np_wlsnap() {
	[ -n "$_NP_WLS_DONE" ] || { _NP_WLS_DONE=1; _NP_WLS=$(uci -q show wireless 2>/dev/null); }
	printf '%s' "$_NP_WLS"
}

ucinet_get() {
	if [ -n "$_NETMAP" ]; then
		case "$2" in
			proto)    _map_field "$_NETMAP" "$1" 1; return ;;
			device)   _map_field "$_NETMAP" "$1" 2; return ;;
			disabled) _map_field "$_NETMAP" "$1" 3; return ;;
			metric)   _map_field "$_NETMAP" "$1" 4; return ;;
		esac
	fi
	if [ -n "$_UCINET_SNAP" ]; then
		_uci_snap_get "$_UCINET_SNAP" "network.$1.$2"
		return
	fi
	uci -q get "network.$1.$2" 2>/dev/null
}
uci5g_get() {
	if [ -n "$_M5MAP" ]; then
		case "$1" in m_*)
			case "$2" in
				network) _map_field "$_M5MAP" "$1" 1; return ;;
				path)    _map_field "$_M5MAP" "$1" 2; return ;;
				parked)  _map_field "$_M5MAP" "$1" 3; return ;;
				kind)    _map_field "$_M5MAP" "$1" 4; return ;;
			esac ;;
		esac
	fi
	if [ -n "$_UCI5G_SNAP" ]; then
		_uci_snap_get "$_UCI5G_SNAP" "5gmodem.$1.$2"
		return
	fi
	uci -q get "5gmodem.$1.$2" 2>/dev/null
}
_IFO_NAME=""; _IFO_DEV=""; _IFO_IP=""
_if_scan() {
	_IFO_NAME="$1"; _IFO_DEV=""; _IFO_IP=""
	[ -n "$1" ] || return 0
	if [ -n "$_IFMAP" ]; then
		_IFO_DEV=$(_ifmap_get "$1" dev)
		_IFO_IP=$(_ifmap_get "$1" ip4)
		return 0
	fi
	[ -n "$_IFDUMP" ] || return 0
	_ifo=$(printf '%s' "$_IFDUMP" | jsonfilter -e "@.interface[@.interface=\"$1\"]" 2>/dev/null)
	[ -n "$_ifo" ] || return 0
	_ifo="${_ifo%%\"inactive\"*}"
	case "$_ifo" in
		*'"l3_device": "'*) _ifx="${_ifo#*\"l3_device\": \"}"; _IFO_DEV="${_ifx%%\"*}" ;;
	esac
	case "$_ifo" in
		*'"ipv4-address": [ { "address": "'*)
			_ifx="${_ifo#*\"ipv4-address\": [ { \"address\": \"}"
			_IFO_IP="${_ifx%%\"*}" ;;
	esac
	return 0
}

ifup_state() {
	if [ -n "$_IFO_NAME" ] && [ "$1" = "$_IFO_NAME" ]; then
		case "$2" in
			'@["l3_device"]')              printf '%s\n' "$_IFO_DEV"; return ;;
			'@["ipv4-address"][0].address') printf '%s\n' "$_IFO_IP"; return ;;
		esac
	fi
	if [ -n "$_IFMAP" ]; then
		case "$2" in
			'@["l3_device"]')
				_ifmap_get "$1" dev; printf '\n'; return ;;
			'@["ipv4-address"][0].address')
				_ifmap_get "$1" ip4; printf '\n'; return ;;
		esac
	fi
	if [ -n "$_IFDUMP" ]; then
		printf '%s' "$_IFDUMP" \
			| jsonfilter -e "@.interface[@.interface=\"$1\"]${2#@}" 2>/dev/null | head -1
		return
	fi
	ifstatus "$1" 2>/dev/null | jsonfilter -e "$2" 2>/dev/null
}
_ifdump_names() {
	if [ -n "$_IFMAP" ]; then
		printf '%s\n' "$_IFMAP" | cut -d'|' -f1
		return
	fi
	if [ -n "$_IFDUMP" ]; then
		printf '%s' "$_IFDUMP" | jsonfilter -e '@.interface[*].interface' 2>/dev/null
		return
	fi
	ubus call network.interface dump 2>/dev/null | jsonfilter -e '@.interface[*].interface' 2>/dev/null
}
json_esc() {
	case "$1" in
		*\\*|*\"*) printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*)         printf '%s' "$1" ;;
	esac
}

_svc_json() {
	_sv_r=0
	if [ -n "$1" ] && [ -x "/etc/init.d/$1" ]; then
		svc_running "$1" && _sv_r=1
	fi
	_sv_ver=""
	if [ -n "$1" ]; then
		_sv_vf="/tmp/5gmodem/svcver_$1"
		_sv_db=/lib/apk/db/installed
		[ -f "$_sv_db" ] || _sv_db=/usr/lib/opkg/status
		if [ -s "$_sv_vf" ] && [ ! "$_sv_db" -nt "$_sv_vf" ]; then
			read -r _sv_ver < "$_sv_vf"
		else
			if command -v opkg >/dev/null 2>&1; then
				_sv_ver=$(opkg list-installed "$1" 2>/dev/null \
					| awk '{sub(/-r[0-9]+$/, "", $3); print $3; exit}')
			else
				_sv_ver=$(apk info -v 2>/dev/null | grep "^$1-[0-9]" | head -1 \
					| sed "s/^$1-//; s/-r[0-9]*$//")
			fi
			printf '%s\n' "$_sv_ver" > "$_sv_vf"
		fi
	fi
	_sv_ip=""
	if [ "$1" = "zerotier" ] && [ "$_sv_r" = 1 ]; then
		for _sv_if in $(ls /sys/class/net 2>/dev/null | grep '^zt'); do
			_sv_ip=$(ip -4 -o addr show dev "$_sv_if" 2>/dev/null \
				| awk '{split($4, a, "/"); print a[1]; exit}')
			[ -n "$_sv_ip" ] && break
		done
	fi
	printf '{"running":%s,"version":"%s","ip":"%s"}' \
		"$_sv_r" "$(json_esc "$_sv_ver")" "$(json_esc "$_sv_ip")"
}

_LM_SNAP=""
lm_snapshot() { _LM_SNAP=$("/usr/share/5gmodem/listmodems.sh" 2>/dev/null); }
_lm() {
	[ -n "$_LM_SNAP" ] && { printf '%s' "$_LM_SNAP"; return; }
	"/usr/share/5gmodem/listmodems.sh" 2>/dev/null
}

iface_ip() {
	p="$1"
	ip=$(ifup_state "$p" '@["ipv4-address"][0].address')
	[ -n "$ip" ] && { echo "$ip"; return; }
	if [ -n "$_IFMAP" ]; then
		_iim="$_IFMAP$_IFNL"
		while [ -n "$_iim" ]; do
			_iil="${_iim%%"$_IFNL"*}"
			_iim="${_iim#*"$_IFNL"}"
			case "$_iil" in
				"${p}_"*) _iip="${_iil##*|}"
				          [ -n "$_iip" ] && { echo "$_iip"; return; } ;;
			esac
		done
		return
	fi
	for c in $(_ifdump_names | grep -E "^${p}_"); do
		ip=$(ifup_state "$c" '@["ipv4-address"][0].address')
		[ -n "$ip" ] && { echo "$ip"; return; }
	done
}

_MS_MAP=""
ms_map_build() {
	_MS_MAP=" $(_uci5g_dump \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\?\([^']*\)'\?\$/\2=\1/p" \
		| tr '\n' ' ') "
}
modem_section() {
	[ -n "$1" ] || return 1
	case "$_MS_MAP" in
		*" $1="*)
			_msv="${_MS_MAP#* $1=}"
			printf '%s' "${_msv%% *}"
			return 0 ;;
	esac
	[ -n "$_MS_MAP" ] && return 0
	sec_for_iface "$1"
}
is_modem() {
	[ -n "$(modem_section "$1")" ] && return 0
	[ -n "$1" ] && [ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && return 0
	return 1
}
modem_path_for() {
	s=$(modem_section "$1")
	if [ -n "$s" ]; then uci5g_get "$s" path; return; fi
	[ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && uci5g_get "@5gmodem[0]" active_modem
}
modem_atport_for() {
	s=$(modem_section "$1")
	if [ -n "$s" ]; then
		_ap=$(uci5g_get "$s" at_port)
		if [ -z "$_ap" ] && [ "$(uci5g_get "$s" path)" = "$(uci5g_get "@5gmodem[0]" active_modem)" ]; then
			_ap=$(uci5g_get "@5gmodem[0]" at_port)
		fi
		printf '%s\n' "$_ap"; return
	fi
	[ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && uci5g_get "@5gmodem[0]" at_port
}
_WLD=""; _WLD_DONE=""
_is_wifi_cfg() {
	if [ -z "$_WLD_DONE" ]; then
		_WLD_DONE=1
		_WLD=$(uci -q show wireless 2>/dev/null)
	fi
	case "$_WLD" in
		*".network='$1'"*) return 0 ;;
		*) return 1 ;;
	esac
}

iface_type() {
	i="$1"
	is_modem "$i" && { echo modem; return; }
	dev=$(ifup_state "$i" '@["l3_device"]')
	case "$dev" in phy*-sta*|wlan*) echo wifi; return;; esac
	_is_wifi_cfg "$i" && { echo wifi; return; }
	case "$i" in wan|wan6) echo wan; return;; esac
	[ -n "$dev" ] || dev=$(ucinet_get "$i" device)
	case "$dev" in eth*|br-*|lan*|wan*) echo wan; return ;; esac
	echo other
}

_npri_at() {
	at_query "$1" "$2" 5 3
	_na_rc=$?
	[ "$_na_rc" = 2 ] && logger -t 5gmodem "netpri: port busy, taking the operator name from cache"
	return 0
}

operator_cached() {
	if [ -f "/tmp/5gmodem/op_$1" ] && [ -s "/tmp/5gmodem/op_$1" ]; then
		operator_clean "$(cat "/tmp/5gmodem/op_$1")"; return
	fi
	if [ -s "/tmp/5gmodem/op_$1" ]; then operator_clean "$(cat "/tmp/5gmodem/op_$1")"; return; fi
	cf="/tmp/5gmodem/netpri_op_$1"
	if [ -f "$cf" ] && [ -z "$(find "$cf" -mmin +30 2>/dev/null)" ]; then
		operator_clean "$(cat "$cf")"; return
	fi
}

operator_probe() {
	i="$1"
	is_modem "$i" || return
	_op_sec=$(sec_for_iface "$i")
	if [ -n "$_op_sec" ] && [ "$(uci5g_get "$_op_sec" kind)" = "hilink" ]; then
		_op_p=$(uci5g_get "$_op_sec" path)
		_op_n=$(/usr/share/5gmodem/hilink.sh json "$_op_p" 2>/dev/null \
			| jsonfilter -e '@.operator_name' 2>/dev/null)
		[ -n "$_op_n" ] && printf '%s' "$_op_n" > "/tmp/5gmodem/netpri_op_$i"
		return
	fi
	_op_mmo=""
	[ "$(ucinet_get "$i" proto)" = "modemmanager" ] && _op_mmo=1
	if [ -z "$_op_mmo" ] && command -v mm_owns_path >/dev/null 2>&1; then
		_op_mp=$(modem_path_for "$i")
		[ -n "$_op_mp" ] && mm_owns_path "$_op_mp" && _op_mmo=1
	fi
	if [ -n "$_op_mmo" ]; then
		_op_path=$(modem_path_for "$i")
		mi=""
		[ -n "$_op_path" ] && mi=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_op_path" 2>/dev/null)
		if [ -n "$mi" ]; then
			_mk=$(mmcli -m "$mi" -K 2>/dev/null)
			nm=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.3gpp\.operator-name *: *//p' | head -1)
			_mc=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.3gpp\.operator-code *: *//p' | head -1)
			[ "$_mc" = "--" ] && _mc=""
			[ -n "$nm" ] && [ "$nm" != "--" ] && {
				printf '%s' "$(opname_pretty "$_mc" "$nm")" > "/tmp/5gmodem/netpri_op_$i"; return; }
		fi
		return
	fi
	path=$(modem_path_for "$i")
	if command -v bg_at_off >/dev/null 2>&1 && bg_at_off ${path:+"$path"}; then
		return
	fi
	cands=$(modem_atport_for "$i")
	_op_known=0
	for _op_c in $cands; do [ -c "$_op_c" ] && _op_known=1; done
	if [ "$_op_known" = 0 ] && [ -n "$path" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
		cands=$(drop_dial_port "$path" $cands \
			$(_lm | jsonfilter -e "@[@.path=\"$path\"].tty[*]" 2>/dev/null))
	fi
	for port in $cands; do
		[ -n "$port" ] && [ -e "$port" ] || continue
		name=$(_npri_at "$port" "AT+COPS=3,0;+COPS?" | tr -d '\r' \
			| sed -n 's/.*+COPS[^"]*"\([^"]*\)".*/\1/p' | head -1)
		name=$(printf '%s' "$name" | awk '{
			if (NF>0 && NF%2==0) { h=NF/2; same=1;
				for(j=1;j<=h;j++) if($j!=$(j+h)) same=0;
				if(same){ s=$1; for(j=2;j<=h;j++) s=s" "$j; print s; next } }
			print }')
		num=""
		if [ -z "$name" ] || echo "$name" | grep -qE '^[0-9 ]*$'; then
			num=$(_npri_at "$port" "AT+COPS=3,2;+COPS?" | tr -d '\r' \
				| sed -n 's/.*+COPS[^"]*"\([0-9]\{4,\}\)".*/\1/p' | head -1)
			[ -n "$num" ] && name=$(awk -F';' '/^'"$num"';/{print $3}' \
				/usr/share/5gmodem/mccmnc.dat 2>/dev/null | head -1 | tr -d '\r' \
				| sed 's/^ *//;s/ *$//')
		else
			name=$(opname_pretty "$num" "$name")
		fi
		[ -n "$name" ] && { printf '%s' "$name" > "/tmp/5gmodem/netpri_op_$i"; return; }
	done
}

model_for() {
	is_modem "$1" || return
	path=$(modem_path_for "$1")
	prod=""; vidpid=""; lmmodel=""
	if [ -n "$path" ]; then
		_mf_al=$(_lm | jsonfilter -e "@[@.path=\"$path\"].alias" 2>/dev/null | head -1)
		[ -n "$_mf_al" ] && { printf '%s' "$_mf_al"; return 0; }
	fi
	if [ -n "$path" ]; then
		_mf_i=0
		while IFS= read -r _mf_l; do
			_mf_i=$((_mf_i + 1))
			case "$_mf_i" in
				1) prod="$_mf_l" ;;
				2) vidpid="$_mf_l" ;;
				3) lmmodel="$_mf_l" ;;
			esac
		done <<MF_EOF
$(_lm | jsonfilter -e "@[@.path=\"$path\"].product" -e "@[@.path=\"$path\"].vidpid" -e "@[@.path=\"$path\"].model" 2>/dev/null)
MF_EOF
	fi
	sec=$(modem_section "$1")
	if [ -n "$sec" ]; then
		_m=$(uci5g_get "$sec" model)
		if [ -n "$_m" ] && [ -n "$vidpid" ] && ! _model_vendor_ok "$_m" "$vidpid"; then
			_m=""
		fi
		_mvp=$(uci5g_get "$sec" model_vp)
		if [ -n "$_m" ] && [ -n "$_mvp" ] && [ -n "$vidpid" ] && [ "$_mvp" != "$vidpid" ]; then
			_m=""
		fi
		[ -n "$_m" ] && { echo "$_m"; return; }
	fi
	if [ -n "$lmmodel" ] && [ "$lmmodel" != "$prod" ]; then echo "$lmmodel"; return; fi
	if [ -z "$prod" ] && [ -n "$sec" ]; then prod=$(uci5g_get "$sec" product); fi

	case "$vidpid" in
		2c7c:0121) echo "Quectel EC21"; return ;;
		2c7c:0125) echo "Quectel EC25"; return ;;
		2c7c:0296) echo "Quectel BG96"; return ;;
		2c7c:0203) echo "Quectel BG95-M3"; return ;;
		2c7c:0700) echo "Quectel BG95"; return ;;
		2c7c:0306) echo "Quectel EP06"; return ;;
		2c7c:0512) echo "Quectel EG12"; return ;;
		2c7c:0620) echo "Quectel EM160R"; return ;;
		2c7c:0800) echo "Quectel RM500Q"; return ;;
		2c7c:0801) echo "Quectel RM520N"; return ;;
		2c7c:0900) echo "Quectel RM500U"; return ;;
		2c7c:0901) echo "Quectel EC200U"; return ;;
		2c7c:6005) echo "Quectel EC200A"; return ;;
		2dee:4d57) echo "MeigLink SLM770A"; return ;;
	esac
	case "$prod" in
		VOS_5G|RXMG1|RXM-G1) echo "Compal RXM-G1"; return ;;
		FM350*) echo "Fibocom $prod"; return ;;
	esac

	case "$prod" in
		''|[Aa]ndroid|USB*|[Mm]odem|*Composite*|*[Dd]evice\ [Bb]us*)
			case "${vidpid%%:*}" in
				2c7c) echo "Quectel"; return ;;
				1bc7) echo "Telit"; return ;;
				2cb7) echo "Fibocom"; return ;;
				0e8d) case "$vidpid" in 0e8d:712*) echo "Fibocom"; return ;; esac ;;
				1e2d) echo "Cinterion"; return ;;
				12d1) echo "Huawei"; return ;;
				19d2) echo "ZTE"; return ;;
				2dee) echo "MeigLink"; return ;;
				0489) echo "Foxconn"; return ;;
			esac
			;;
	esac
	echo "$prod"
}

ssid_for() {
	dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$dev" ] || return
	ubus call network.wireless status 2>/dev/null \
		| jsonfilter -e "@[*].interfaces[@.ifname=\"$dev\"].config.ssid" 2>/dev/null | head -1
}

label_for() {
	i="$1"
	case "${2:-$(iface_type "$i")}" in
	wan)  case "$i" in wan|wan6) echo "WAN" ;; *) echo "$i" ;; esac ;;
	wifi) s=$(ssid_for "$i"); [ -n "$s" ] && echo "$s" || echo "Wi-Fi" ;;
	modem)
		op=$(operator_cached "$i")
		[ -n "$op" ] && echo "$op" || echo "$i" ;;
	*) echo "$i" ;;
	esac
}

_metric_base() {
	[ "$(uci5g_get "@5gmodem[0]" mwan3_metrics)" = "1" ] && echo 10 || echo 100
}

_add_default_route() {
	_dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dev" ] || return 0
	_t4=$(uci -q get "network.$1.ip4table" 2>/dev/null)
	_ta4=""; [ -n "$_t4" ] && _ta4="table $_t4"
	_gw4=$(ifup_state "$1" '@.route[@.target="0.0.0.0"].nexthop')
	if [ -z "$_gw4" ] || [ "$_gw4" = "0.0.0.0" ]; then
		_gw4=$(ifup_state "${1}_4" '@.route[@.target="0.0.0.0"].nexthop')
	fi
	if [ -n "$_gw4" ] && [ "$_gw4" != "0.0.0.0" ]; then
		route_add_default -4 "$_dev" "$2" "$_gw4" "$_ta4"
	elif is_p2p_dev "$_dev" \
		|| [ -n "$(ifup_state "$1" '@.route[@.target="0.0.0.0"].target')" ] \
		|| [ -n "$(ifup_state "${1}_4" '@.route[@.target="0.0.0.0"].target')" ]; then
		route_add_default -4 "$_dev" "$2" "" "$_ta4"
	else
		logger -t 5gmodem "netpri: $1 ($_dev) has no gateway - cannot make it the default route; check the upstream DHCP server (option router)"
	fi
	_gw6=$(ifup_state "$1" '@.route[@.target="::"].nexthop')
	_t6=$(uci -q get "network.$1.ip6table" 2>/dev/null)
	if [ -z "$_gw6" ] || [ "$_gw6" = "::" ]; then
		for _sat in "${1}6" "${1}_6"; do
			_gw6=$(ifup_state "$_sat" '@.route[@.target="::"].nexthop')
			if [ -n "$_gw6" ] && [ "$_gw6" != "::" ]; then
				_t6=$(uci -q get "network.$_sat.ip6table" 2>/dev/null)
				break
			fi
		done
	fi
	_ta6=""; [ -n "$_t6" ] && _ta6="table $_t6"
	[ -n "$_gw6" ] && [ "$_gw6" != "::" ] && \
		route_add_default -6 "$_dev" "$2" "$_gw6" "$_ta6"
}
_route_tables() {
	if [ "$1" = "-4" ]; then
		_rt_l="$(uci -q get "network.$2.ip4table" 2>/dev/null)"
	else
		_rt_l="$(uci -q get "network.$2.ip6table" 2>/dev/null) $(uci -q get "network.${2}6.ip6table" 2>/dev/null) $(uci -q get "network.${2}_6.ip6table" 2>/dev/null)"
	fi
	_rt_o="main"
	for _rt_t in $_rt_l; do
		case " $_rt_o " in *" $_rt_t "*) continue ;; esac
		_rt_o="$_rt_o $_rt_t"
	done
	echo "$_rt_o"
}

_default_metrics() {
	for _dm_t in $3; do
		_dm_a=""; [ "$_dm_t" = "main" ] || _dm_a="table $_dm_t"
		ip "$1" route show default $_dm_a 2>/dev/null | grep -E "^default" \
			| grep -v '^default from ' \
			| grep -E " dev $2( |$)" \
			| sed -e 's/.* metric \([0-9][0-9]*\).*/\1/' -e t -e 's/.*/0/'
	done
}

_del_default_family() {
	for _dd_t in $3; do
		_dd_a=""; [ "$_dd_t" = "main" ] || _dd_a="table $_dd_t"
		ip "$1" route show default $_dd_a 2>/dev/null | grep -E "^default" \
			| grep -v '^default from ' \
			| grep -E " dev $2( |$)" | while read -r _dd_ln; do
			_dd_m=0
			case "$_dd_ln" in *" metric "*) _dd_m=${_dd_ln##* metric }; _dd_m=${_dd_m%% *} ;; esac
			[ "$_dd_m" = "$4" ] && continue
			if [ "$_dd_m" = "0" ]; then
				ip "$1" route del default dev "$2" $_dd_a 2>/dev/null
			else
				ip "$1" route del default dev "$2" metric "$_dd_m" $_dd_a 2>/dev/null
			fi
		done
	done
}

_has_metric() {
	case " $(_default_metrics "$1" "$2" "$3" | tr '\n' ' ')" in *" $4 "*) return 0 ;; esac
	return 1
}

_new_metric() {
	for _nm_m in $(_default_metrics "$1" "$2" "$3"); do
		case "$4" in *" $_nm_m "*) continue ;; esac
		echo "$_nm_m"; return 0
	done
}

_free_metric() {
	_fm_r=1
	for _fm_t in $4; do
		_fm_a=""; [ "$_fm_t" = "main" ] || _fm_a="table $_fm_t"
		_fm_all=$(ip "$1" route show default $_fm_a 2>/dev/null | grep -E "^default" \
			| grep -v '^default from ')
		_fm_ln=$(printf '%s\n' "$_fm_all" | grep -E " metric $2( |$)" | head -1)
		[ -n "$_fm_ln" ] || continue
		_fm_d=${_fm_ln##* dev }; _fm_d=${_fm_d%% *}
		[ "$_fm_d" = "$3" ] && continue
		case " $5 " in *" $_fm_d "*) ;; *) continue ;; esac
		if [ "$(printf '%s\n' "$_fm_all" | grep -c "^default")" -lt 2 ]; then
			_fm_r=2; continue
		fi
		ip "$1" route del default dev "$_fm_d" metric "$2" $_fm_a 2>/dev/null && _fm_r=0
	done
	return "$_fm_r"
}

_rerank_default_route() {
	_rd_t4=$(_route_tables -4 "$1")
	_rd_t6=$(_route_tables -6 "$1")
	_rd_s4=" $(_default_metrics -4 "$3" "$_rd_t4" | tr '\n' ' ')"
	_rd_s6=" $(_default_metrics -6 "$3" "$_rd_t6" | tr '\n' ' ')"
	_rd_try=0
	while [ "$_rd_try" -lt 2 ]; do
		_rd_try=$((_rd_try + 1))
		_rd_b4=" $(_default_metrics -4 "$3" "$_rd_t4" | tr '\n' ' ')"
		_rd_b6=" $(_default_metrics -6 "$3" "$_rd_t6" | tr '\n' ' ')"
		_rd_f4=1; case "$_rd_b4" in *" $2 "*) ;; *) _free_metric -4 "$2" "$3" "$_rd_t4" "$4"; _rd_f4=$? ;; esac
		_rd_f6=1; case "$_rd_b6" in *" $2 "*) ;; *) _free_metric -6 "$2" "$3" "$_rd_t6" "$4"; _rd_f6=$? ;; esac
		case "$_rd_b4" in
			*" $2 "*) case "$_rd_b6" in " "|*" $2 "*) break ;; esac ;;
		esac
		_add_default_route "$1" "$2"
		_has_metric -4 "$3" "$_rd_t4" "$2" && break
		_has_metric -6 "$3" "$_rd_t6" "$2" && break
		[ "$_rd_f4" = "2" ] || [ "$_rd_f6" = "2" ] || break
	done
	_rd_rc=1
	_rd_k4="$2"; _has_metric -4 "$3" "$_rd_t4" "$2" || _rd_k4=$(_new_metric -4 "$3" "$_rd_t4" "$_rd_s4")
	_rd_k6="$2"; _has_metric -6 "$3" "$_rd_t6" "$2" || _rd_k6=$(_new_metric -6 "$3" "$_rd_t6" "$_rd_s6")
	[ -n "$_rd_k4" ] && { _del_default_family -4 "$3" "$_rd_t4" "$_rd_k4"; _rd_rc=0; }
	[ -n "$_rd_k6" ] && { _del_default_family -6 "$3" "$_rd_t6" "$_rd_k6"; _rd_rc=0; }
	[ "$_rd_rc" = "0" ] || logger -t 5gmodem "netpri: $1 ($3) keeps its old default route - adding one with metric $2 failed"
	return "$_rd_rc"
}

_rerank_iface_routes() {
	for _rr_fam in -4 -6; do
		if [ "$_rr_fam" = "-4" ]; then
			_rr_tl="$(uci -q get "network.$3.ip4table" 2>/dev/null)"
		else
			_rr_tl="$(uci -q get "network.$3.ip6table" 2>/dev/null) $(uci -q get "network.${3}6.ip6table" 2>/dev/null) $(uci -q get "network.${3}_6.ip6table" 2>/dev/null)"
		fi
		_rr_seen=""
		for _rr_t in "" $_rr_tl; do
			case " $_rr_seen " in *" ${_rr_t:-main} "*) continue ;; esac
			_rr_seen="$_rr_seen ${_rr_t:-main}"
			_rr_a=""; [ -n "$_rr_t" ] && _rr_a="table $_rr_t"
			ip "$_rr_fam" route show $_rr_a 2>/dev/null | grep -E " dev $1( |$)" | while read -r _rr_ln; do
				case "$_rr_ln" in
					default*) continue ;;
					*" metric "*) ;;
					*) continue ;;
				esac
				_rr_cur=$(printf '%s' "$_rr_ln" | sed -n 's/.*metric \([0-9]*\).*/\1/p')
				[ -n "$_rr_cur" ] || continue
				[ "$_rr_cur" = "$2" ] && continue
				_rr_pfx=${_rr_ln%% *}
				_rr_new=$(printf '%s' "$_rr_ln" | sed "s/metric $_rr_cur/metric $2/")
				ip "$_rr_fam" route add $_rr_new $_rr_a 2>/dev/null
				ip "$_rr_fam" route show $_rr_a 2>/dev/null | grep -E "^$_rr_pfx( |$)" \
					| grep -E " dev $1( |$)" | grep -qE " metric $2( |$)" || continue
				ip "$_rr_fam" route del "$_rr_pfx" dev "$1" metric "$_rr_cur" $_rr_a 2>/dev/null
			done
		done
	done
}

_clash_ping() {
	command -v curl >/dev/null 2>&1 || return 1
	_cp_h="$1"
	[ -n "$_cp_h" ] || return 1
	_cp_ctl=$(sed -n 's/^external-controller:.*:\([0-9]*\).*/\1/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	[ -n "$_cp_ctl" ] || _cp_ctl=9090
	_cp_sec=$(sed -n 's/^ *secret *: *\(.*\)$/\1/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1 | tr -d '"'"'"' ')
	set --
	[ -n "$_cp_sec" ] && set -- -H "Authorization: Bearer $_cp_sec"
	_cp_n=0
	for _cp_g in $(curl -s -m 3 "$@" "http://127.0.0.1:$_cp_ctl/proxies" 2>/dev/null \
		| grep -o '"name":"[A-Za-z0-9_.-]*"' | cut -d'"' -f4 | sort -u); do
		case "$_cp_g" in GLOBAL|DIRECT|REJECT*|PASS*|COMPATIBLE|'') continue ;; esac
		_cp_n=$((_cp_n + 1)); [ "$_cp_n" -gt 4 ] && break
		for _cp_u in "https%3A%2F%2F$_cp_h%2Fgenerate_204" "https%3A%2F%2F$_cp_h%2F"; do
			_cp_d=$(curl -s -m 6 "$@" \
				"http://127.0.0.1:$_cp_ctl/proxies/$_cp_g/delay?timeout=4000&url=$_cp_u" 2>/dev/null \
				| sed -n 's/.*"delay":\([0-9]*\).*/\1/p')
			[ -n "$_cp_d" ] && { printf '{"ok":1,"ms":%s,"via":"proxy"}\n' "$_cp_d"; return 0; }
		done
	done
	return 1
}

live_dev() {
	ip -4 route show default 2>/dev/null | awk '
		{ m=0; d=""; for(i=1;i<NF;i++){ if($i=="dev") d=$(i+1); if($i=="metric") m=$(i+1)+0 }
		  if (d != "" && (best == "" || m < bm)) { bm = m; best = d } }
		END { print best }'
}

_iface_by_dev() {
	[ -n "$1" ] || return 0
	_ibd_kid=""
	_ibd_rest="$_IFMAP$_IFNL"
	while [ -n "$_ibd_rest" ]; do
		_ibd_l="${_ibd_rest%%"$_IFNL"*}"
		_ibd_rest="${_ibd_rest#*"$_IFNL"}"
		_ibd_n="${_ibd_l%%|*}"
		_ibd_d="${_ibd_l#*|}"; _ibd_d="${_ibd_d#*|}"; _ibd_d="${_ibd_d%%|*}"
		[ "$_ibd_d" = "$1" ] || continue
		case "$_ibd_n" in
			*_4|*_6) [ -n "$_ibd_kid" ] || _ibd_kid="${_ibd_n%_*}" ;;
			*) printf '%s' "$_ibd_n"; return 0 ;;
		esac
	done
	printf '%s' "$_ibd_kid"
}

case "$1" in
adoptzone)
	_az="$2"
	[ -n "$_az" ] || exit 1
	ucinet_has "$_az" || exit 1
	_azs=$(uci -q show wireless 2>/dev/null \
		| sed -n "s/^wireless\.\([^.]*\)\.network='$_az'\$/\1/p" | head -1)
	{ [ -n "$_azs" ] && [ "$(uci -q get "wireless.$_azs.mode")" = "sta" ]; } || exit 1
	case " $(wan_nets | tr '\n' ' ') " in *" $_az "*) exit 0 ;; esac
	_azz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	[ -n "$_azz" ] || exit 1
	note_foreign_uci firewall "netpri adoptzone"
	case "$(uci -q show "firewall.$_azz.network" 2>/dev/null)" in
		*"' '"*) ;;
		*=\'*\ *\')
			_azc=$(uci -q get "firewall.$_azz.network" | tr -d "'\"")
			uci -q delete "firewall.$_azz.network"
			for _aze in $_azc; do
				uci add_list "firewall.$_azz.network=$_aze"
			done ;;
	esac
	uci add_list "firewall.$_azz.network=$_az"
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	logger -t 5gmodem "adoptzone: $_az added to the wan zone (Wi-Fi uplink from the join wizard)"
	exit 0
	;;
list)
	ifdump_snapshot
	ifmap_build
	uci5g_snapshot
	ucinet_snapshot
	ucimap_build
	lm_snapshot
	_NOW_S=$(uptime_s)
	_HEALTH_ON=$(uci5g_get health enabled)
	_HEALTH_FO=$(uci5g_get health failover)
	ms_map_build
	_LIVE_DEV=$(live_dev)
	printf '['
	first=1
	NEEDREFRESH=0
	PRESENT_PATHS=" $(_lm | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
	for n in $(wan_nets | tr ' ' '\n' | sort | uniq); do
		[ -n "$n" ] || continue
		ucinet_has "$n" || continue
		_if_scan "$n"
		case "$n" in
			*6)
				if ucinet_has "${n%6}"; then
					_sat_p=$(ucinet_get "$n" proto)
					_sat_d=$(ucinet_get "$n" device)
					case "$_sat_p" in
						dhcpv6|6in4|6to4|6rd) continue ;;
					esac
					case "$_sat_d" in
						@*) continue ;;
					esac
				fi ;;
		esac
		[ "$(ucinet_get "$n" disabled)" = "1" ] && continue
		t=$(iface_type "$n")
		if [ "$t" = modem ]; then
			_any_path=""; _any_present=""; _any_parked=""
			_ms_list=""
			_msr=" $_MS_MAP"
			while :; do
				case "$_msr" in
					*" $n="*) _msr="${_msr#* "$n"=}"
					          _ms_list="$_ms_list ${_msr%% *}" ;;
					*) break ;;
				esac
			done
			[ -n "$_ms_list" ] || _ms_list=$(_uci5g_dump \
				| sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\?$n'\?\$/\1/p")
			for _ms in $_ms_list; do
				_mp=$(uci5g_get "$_ms" path)
				if [ -z "$_mp" ]; then
					[ "$(uci5g_get "$_ms" parked)" = "1" ] && _any_parked=1
					continue
				fi
				_any_path=1
				case "$PRESENT_PATHS" in *" $_mp "*) _any_present=1 ;; esac
				[ -n "$_any_present" ] && break
			done
			if [ -z "$_any_present" ] && { [ -n "$_any_path" ] || [ -n "$_any_parked" ]; }; then
				[ -z "$(iface_ip "$n")" ] && continue
				t=other
			fi
		fi
		ip=$(iface_ip "$n")
		_np_dev=$(ucinet_get "$n" device)
		case "$_np_dev" in
			'') : ;;
			/*) [ -e "$_np_dev" ] || [ -n "$ip" ] || continue ;;
			*)  [ -e "/sys/class/net/$_np_dev" ] || [ -n "$ip" ] || continue ;;
		esac
		[ "$t" = wan ] && [ -z "$ip" ] && continue
		[ "$t" = modem ] && [ -z "$(operator_cached "$n")" ] && NEEDREFRESH=1
		case "$t" in
			modem) sub=$(model_for "$n"); [ -n "$sub" ] || sub="$n" ;;
			wifi)  sub="$n" ;;
			*)     sub=$(ifup_state "$n" '@["l3_device"]')
			       [ -n "$sub" ] || sub=$(ucinet_get "$n" device)
			       [ -n "$sub" ] || sub="$n" ;;
		esac
		_np_s=$(modem_section "$n")
		if [ -n "$_np_s" ] && [ "$(uci5g_get "$_np_s" kind)" = "hilink" ]; then
			_np_wan=$(/usr/share/5gmodem/hilink.sh json "$(uci5g_get "$_np_s" path)" 2>/dev/null \
				| jsonfilter -e '@.ipaddr' 2>/dev/null)
			[ -n "$_np_wan" ] && ip="$_np_wan"
		fi
		m=$(ucinet_get "$n" metric); [ -n "$m" ] || m=0
		_np_h=""
		if [ "$_HEALTH_ON" = "1" ] && [ -f "/tmp/5gmodem/health/$n" ]; then
			if read -r _np_hst _np_hf _np_ho _np_hms _np_hs 2>/dev/null < "/tmp/5gmodem/health/$n"; then
				_np_gr=120
				[ -f "/tmp/5gmodem/health/$n.heal" ] && _np_gr=600
				if [ "$_np_hst" = "gone" ] && [ $(( _NOW_S - ${_np_hs:-0} )) -gt "$_np_gr" ]; then
					continue
				fi
				_np_h=",\"health\":\"$_np_hst\",\"hms\":${_np_hms:-0}"
				if [ -f "/tmp/5gmodem/health/$n.heal" ] \
				   && read -r _np_hstep _np_hlast _np_hn 2>/dev/null < "/tmp/5gmodem/health/$n.heal"; then
					_np_hk=modem
					case "$(_np_wlsnap)" in *".network='$n'"*) _np_hk=wifi ;; esac
					if [ "$_np_hk" = modem ] && [ "$(printf '%s\n' "$_M5MAP" \
							| awk -F'|' -v i="$n" '$2==i {print $5; exit}')" = hilink ]; then
						_np_hk=hilink
					fi
					_np_h="$_np_h,\"healstep\":${_np_hstep:-0},\"healn\":${_np_hn:-0},\"healmax\":6,\"healfor\":$(( _NOW_S - ${_np_hlast:-0} )),\"healkind\":\"$_np_hk\""
				fi
			fi
		fi
		if [ -n "$_LIVE_DEV" ]; then
			_np_ld=$(ifup_state "$n" '@["l3_device"]')
			[ -n "$_np_ld" ] || _np_ld=$(ifup_state "${n}_4" '@["l3_device"]')
			[ "$_np_ld" = "$_LIVE_DEV" ] && _np_h="$_np_h,\"live\":1"
		fi
		_np_tp=""
		[ -n "$_np_s" ] && _np_tp=$(uci5g_get "$_np_s" path)
		if [ -n "$_np_s" ] && [ "$(uci5g_get "$_np_s" kind)" = tether ] && ! known_modem_path "$_np_tp"; then
			if [ -n "$_np_tp" ]; then
				_np_to=$(tether_os "$_np_tp")
			else
				_np_to=$(uci5g_get "$_np_s" tether)
			fi
			_np_h="$_np_h,\"tether\":\"${_np_to:-phone}\""
		fi
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"iface":"%s","type":"%s","sub":"%s","label":"%s","ip":"%s","metric":%s%s}' \
			"$n" "$t" "$(json_esc "$sub")" "$(json_esc "$(label_for "$n" "$t")")" "$ip" "$m" "$_np_h"
	done
	if [ "$first" != 1 ] && [ "$_HEALTH_ON" = "1" ]; then
		_np_ev=""
		[ -s /tmp/5gmodem/health/.last_event ] && \
			read -r _np_ev < /tmp/5gmodem/health/.last_event 2>/dev/null
		printf ',{"event":"%s","failover":%s}' "$(json_esc "$_np_ev")" \
			"$([ "$_HEALTH_FO" = "1" ] && echo 1 || echo 0)"
	fi
	_wz=" $(wan_nets | tr '\n' ' ') "
	for _oi in $(printf '%s' "$_IFDUMP" | jsonfilter -e '@.interface[*].interface' 2>/dev/null); do
		case "$_oi" in loopback|lan|*_4|*_6) continue ;; esac
		case "$_wz" in *" $_oi "*) continue ;; esac
		ucinet_has "$_oi" || continue
		_osec=$(uci -q show wireless 2>/dev/null \
			| sed -n "s/^wireless\.\([^.]*\)\.network='$_oi'\$/\1/p" | head -1)
		[ -n "$_osec" ] || continue
		[ "$(uci -q get "wireless.$_osec.mode")" = "sta" ] || continue
		_if_scan "$_oi"
		_oip=$(iface_ip "$_oi")
		[ -n "$_oip" ] || continue
		_ossid=$(uci -q get "wireless.$_osec.ssid")
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"iface":"%s","type":"wifi","sub":"%s","label":"%s","ip":"%s","metric":9999,"nozone":1}' \
			"$(json_esc "$_oi")" "$(json_esc "$_oi")" "$(json_esc "${_ossid:-Wi-Fi}")" "$(json_esc "$_oip")"
	done
	printf ']\n'
	if [ "$NEEDREFRESH" = 1 ]; then
		stamp=/tmp/5gmodem/netpri_refresh
		if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +1 2>/dev/null)" ]; then
			: > "$stamp"
			# redirect the subshell itself, see docs/subsystems/internet-priority.md#background-refresh-and-rpcd
			( /usr/share/5gmodem/netpri.sh refresh & ) >/dev/null 2>&1 </dev/null &
		fi
	fi
	;;

status)
	ifdump_snapshot
	ifmap_build
	_st_act=$(_iface_by_dev "$(live_dev)")
	uci5g_sec_snapshot health
	_st_en=$(uci5g_sec_get enabled); [ "$_st_en" = "1" ] || _st_en=0
	_st_fo=$(uci5g_sec_get failover); [ "$_st_fo" = "1" ] || _st_fo=0
	printf '{"active":"%s","failover":%s,"enabled":%s,"base":%s}\n' \
		"$(json_esc "$_st_act")" "$_st_fo" "$_st_en" "$(_metric_base)"
	;;

refresh)
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		[ "$(iface_type "$n")" = modem ] && operator_probe "$n"
	done
	;;

op)
	I="${2:-$(uci -q get 5gmodem.@5gmodem[0].network)}"; [ -n "$I" ] || I=modem
	if [ "$3" = fresh ]; then
		rm -f "/tmp/5gmodem/netpri_op_$I"
		if [ "$I" = "$(uci -q get 5gmodem.@5gmodem[0].network)" ]; then
			rm -f "/tmp/5gmodem/op_$I"
			/usr/share/5gmodem/5gmodem.sh cached 10 >/dev/null 2>&1
		fi
	fi
	OP=$(operator_cached "$I")
	[ -n "$OP" ] || { operator_probe "$I" 2>/dev/null; OP=$(operator_cached "$I"); }
	printf '%s' "$OP"
	;;

set)
	CH="$2"
	[ -n "$CH" ] || { echo '{"error":"no interface"}'; exit 1; }
	case " $(wan_nets) " in
		*" $CH "*) ;;
		*) echo '{"error":"not a wan uplink"}'; exit 1 ;;
	esac
	note_foreign_uci network "netpri set"
	CHANGED=0
	_mb=$(_metric_base)
	_mset=$((_mb + 10))
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		ucinet_has "$n" || continue
		if [ "$n" = "$CH" ]; then NEW=$_mb; else NEW=$_mset; _mset=$((_mset + 10)); fi
		OLD=$(ucinet_get "$n" metric)
		[ "x$OLD" = "x$NEW" ] && continue
		uci -q set "network.$n.metric=$NEW"
		CHANGED=1
	done
	rm -f /tmp/5gmodem/health/*.demoted 2>/dev/null
	_np_changed=false; [ "$CHANGED" = 1 ] && _np_changed=true
	[ "$CHANGED" = 1 ] && uci -q commit network
	_devs=""
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		case " $_devs " in *" $_d "*) continue ;; esac
		_devs="$_devs $_d"
	done
	_seen=""
	_add_once() {
		_dv=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dv" ] || return 1
		case " $_seen " in *" $_dv "*) return 1 ;; esac
		_seen="$_seen $_dv"
		_rerank_default_route "$1" "$2" "$_dv" "$_devs"
		_rerank_iface_routes "$_dv" "$2" "$1"
		return 0
	}
	_add_once "$CH" "$_mb"
	_m=$((_mb + 10))
	for n in $(wan_nets); do
		[ -n "$n" ] && [ "$n" != "$CH" ] && { _add_once "$n" "$_m" && _m=$((_m + 10)); }
	done
	echo '{"result":"ok","active":"'"$CH"'","changed":'"$_np_changed"',"mode":"live-route"}'
	;;

reapply)
	_ra_n="$2"
	[ -n "$_ra_n" ] || exit 0
	_ra_en=$(uci -q get 5gmodem.health.enabled)
	[ "$(uci -q get 5gmodem.@5gmodem[0].widget_netpri)" = "0" ] && _ra_en=0
	[ "$_ra_en" = "1" ] && exit 0
	case " $(wan_nets) " in *" $_ra_n "*) ;; *) exit 0 ;; esac
	_ra_m=$(uci -q get "network.$_ra_n.metric")
	case "$_ra_m" in ''|*[!0-9]*) exit 0 ;; esac
	_ra_d=$(ifup_state "$_ra_n" '@["l3_device"]'); [ -n "$_ra_d" ] || exit 0
	exec 9>"/tmp/5gmodem/health.lock"
	flock 9
	_devs=""
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		case " $_devs " in *" $_d "*) continue ;; esac
		_devs="$_devs $_d"
	done
	_rerank_default_route "$_ra_n" "$_ra_m" "$_ra_d" "$_devs"
	_rerank_iface_routes "$_ra_d" "$_ra_m" "$_ra_n"
	;;

worder)
	shift
	_wo=""
	for _wk in "$@"; do
		case "$_wk" in
			p:*|s:*|speed) _wo="${_wo:+$_wo }$_wk" ;;
		esac
	done
	if [ -n "$_wo" ]; then
		uci -q set "5gmodem.@5gmodem[0].widget_order=$_wo"
	else
		uci -q delete "5gmodem.@5gmodem[0].widget_order" 2>/dev/null
	fi
	_WRNL='
'
	_wo_reorder() {
		[ -n "$4" ] || return 0
		_wr_pairs=""
		_wr_i=0
		while [ "$(uci -q get "5gmodem.@$1[$_wr_i]" 2>/dev/null)" = "$1" ]; do
			_wr_v=$(uci -q get "5gmodem.@$1[$_wr_i].$2")
			_wr_x=""
			[ -n "$3" ] && _wr_x=$(uci -q get "5gmodem.@$1[$_wr_i].$3")
			_wr_pairs="${_wr_pairs}${_wr_v}~${_wr_x}${_WRNL}"
			_wr_i=$((_wr_i + 1))
		done
		[ "$_wr_i" -gt 1 ] || return 0
		_wr_out=""
		for _wr_want in $4; do
			_wr_rest=""; _wr_hit=""
			_wr_old="$_wr_pairs"
			while [ -n "$_wr_old" ]; do
				_wr_l="${_wr_old%%${_WRNL}*}"; _wr_old="${_wr_old#*${_WRNL}}"
				if [ -z "$_wr_hit" ]; then
					case "$_wr_l" in
						"$_wr_want~"*) _wr_hit="$_wr_l"; continue ;;
					esac
				fi
				_wr_rest="${_wr_rest}${_wr_l}${_WRNL}"
			done
			[ -n "$_wr_hit" ] && { _wr_out="${_wr_out}${_wr_hit}${_WRNL}"; _wr_pairs="$_wr_rest"; }
		done
		_wr_out="${_wr_out}${_wr_pairs}"
		_wr_i=0
		while [ -n "$_wr_out" ]; do
			_wr_l="${_wr_out%%${_WRNL}*}"; _wr_out="${_wr_out#*${_WRNL}}"
			uci -q set "5gmodem.@$1[$_wr_i].$2=${_wr_l%%~*}"
			[ -n "$3" ] && uci -q set "5gmodem.@$1[$_wr_i].$3=${_wr_l#*~}"
			_wr_i=$((_wr_i + 1))
		done
	}
	_wo_ping=""; _wo_svc=""
	for _wk in $_wo; do
		case "$_wk" in
			p:*)          _wo_ping="${_wo_ping:+$_wo_ping }${_wk#p:}" ;;
			s:ssclash-go) _wo_svc="${_wo_svc:+$_wo_svc }ssclash" ;;
			s:ssclash)    _wo_svc="${_wo_svc:+$_wo_svc }clash" ;;
			s:*)          _wo_svc="${_wo_svc:+$_wo_svc }${_wk#s:}" ;;
		esac
	done
	_wo_reorder pingwidget host mode "$_wo_ping"
	_wo_reorder svcwidget service "" "$_wo_svc"
	uci -q commit 5gmodem
	echo '{"ok":1}'
	;;

order)
	shift
	[ -n "$1" ] || { echo '{"error":"no order"}'; exit 1; }
	_ord=""
	_wz=" $(wan_nets) "
	for _oi in "$@"; do
		case "$_wz" in
			*" $_oi "*) _ord="$_ord $_oi" ;;
			*) logger -t 5gmodem "netpri order: '$_oi' is not a wan-zone uplink - skipping" ;;
		esac
	done
	[ -n "$_ord" ] || { echo '{"error":"no valid interfaces"}'; exit 1; }
	rm -f /tmp/5gmodem/health/*.demoted 2>/dev/null
	note_foreign_uci network "netpri order"
	_rank=$(_metric_base)
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_o " in *" $n "*) continue ;; esac
		_seen_o="$_seen_o $n"
		ucinet_has "$n" || continue
		uci -q set "network.$n.metric=$_rank"
		_rank=$((_rank + 10))
	done
	uci -q commit network
	_devs=""
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		case " $_devs " in *" $_d "*) continue ;; esac
		_devs="$_devs $_d"
	done
	_seen=""; _rank=$(_metric_base)
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_r " in *" $n "*) continue ;; esac
		_seen_r="$_seen_r $n"
		_dv=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_dv" ] || continue
		case " $_seen " in *" $_dv "*) continue ;; esac
		_seen="$_seen $_dv"
		_rerank_default_route "$n" "$_rank" "$_dv" "$_devs"
		_rerank_iface_routes "$_dv" "$_rank" "$n"
		_rank=$((_rank + 10))
	done
	echo '{"result":"ok","changed":true,"mode":"order"}'
	;;

ping)
	_TG_CIDR_PKG=/usr/share/5gmodem/telegram-cidr.txt
	_TG_CIDR_NEW=/etc/5gmodem/telegram-cidr.txt
	_tg_cidr_file() {
		[ -s "$_TG_CIDR_NEW" ] && { printf '%s' "$_TG_CIDR_NEW"; return 0; }
		[ -s "$_TG_CIDR_PKG" ] && { printf '%s' "$_TG_CIDR_PKG"; return 0; }
		return 1
	}

	_tg_cidr_refresh() {
		command -v curl >/dev/null 2>&1 || return 0
		_tr_f=$(_tg_cidr_file) || _tr_f=""
		if [ -n "$_tr_f" ] && [ -z "$(find "$_tr_f" -mtime +30 2>/dev/null)" ]; then
			return 0
		fi
		( _tr_t="/tmp/5gmodem/.tgcidr.$$"
		  curl -fsSL -m 20 https://core.telegram.org/resources/cidr.txt -o "$_tr_t" 2>/dev/null || {
		  	rm -f "$_tr_t"; exit 0; }
		  if awk '
		  		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
		  			split($0, c, "/"); if (c[2] + 0 < 8) bad = 1; n++; next }
		  		/^[0-9a-fA-F:]+\/[0-9]+$/ { n++; next }
		  		/^[[:space:]]*$/ { next }
		  		{ bad = 1 }
		  		END { exit((bad || n < 5) ? 1 : 0) }
		  	' "$_tr_t"; then
		  	mkdir -p /etc/5gmodem 2>/dev/null
		  	mv "$_tr_t" "$_TG_CIDR_NEW" 2>/dev/null \
		  		&& logger -t 5gmodem "Telegram network list updated ($(wc -l < "$_TG_CIDR_NEW" | tr -d " ") lines)"
		  else
		  	rm -f "$_tr_t"
		  fi ) >/dev/null 2>&1 </dev/null &
	}

	_tg_cidr_has() {
		_tc_f=$(_tg_cidr_file) || return 1
		awk -v ip="$1" '
			function toint(a,   p) { split(a, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
			/:/ { next }
			/^[0-9]/ {
				split($1, c, "/")
				bits = c[2] + 0
				if (bits < 1 || bits > 32) next
				d = 2 ^ (32 - bits)
				if (int(toint(ip) / d) == int(toint(c[1]) / d)) { found = 1; exit }
			}
			END { exit(found ? 0 : 1) }
		' "$_tc_f"
	}
	_tg_probe() {
		_tp_cu=$(uci -q get 5gmodem.sms.tg_api_url)
		case "$_tp_cu" in
			http://?*|https://?*)
				_tp_k=""; [ "$(uci -q get 5gmodem.sms.tg_api_insecure)" = 1 ] && _tp_k="-k"
				_tp_w=$(curl -o /dev/null -s -m 6 $_tp_k -w '%{http_code} %{time_starttransfer}' "${_tp_cu%/}/" 2>/dev/null)
				_tp_c="${_tp_w%% *}"; _tp_t="${_tp_w##* }"
				if [ -n "$_tp_c" ] && [ "$_tp_c" != "000" ]; then
					printf '{"ok":1,"ms":%s,"via":"custom"}\n' "$(printf '%s' "$_tp_t" | awk '{printf "%d", $1 * 1000}')"
				else
					echo '{"ok":0,"via":"custom"}'
				fi
				return 0 ;;
		esac
		_tp_ip=$(nslookup api.telegram.org 2>/dev/null \
			| sed -n 's/^Address: *\([0-9.]*\)$/\1/p' | grep -v '^127\.' | head -1)
		_tp_fake=""
		case "$_tp_ip" in 198.18.*|198.19.*) _tp_fake=1 ;; esac
		if [ -n "$_tp_ip" ] && [ -z "$_tp_fake" ] && ! _tg_cidr_has "$_tp_ip"; then
			printf '{"ok":0,"why":"dns","ip":"%s"}\n' "$_tp_ip"
			return 0
		fi
		[ -n "$_tp_ip" ] || _tp_ip=149.154.167.220
		if command -v curl >/dev/null 2>&1; then
			if [ -z "$_tp_fake" ]; then
				_tp_w=$(curl -o /dev/null -s -m 5 \
					--resolve "api.telegram.org:443:$_tp_ip" \
					-w '%{http_code} %{time_starttransfer}' \
					"https://api.telegram.org/" 2>/dev/null)
				_tp_c="${_tp_w%% *}"; _tp_t="${_tp_w##* }"
				if [ -n "$_tp_c" ] && [ "$_tp_c" != "000" ]; then
					_tg_cidr_refresh
					printf '{"ok":1,"ms":%s,"via":"tls"}\n' \
						"$(printf '%s' "$_tp_t" | awk '{printf "%d", $1 * 1000}')"
					return 0
				fi
			fi
			_tp_pp=$(sed -n 's/^\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
				/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
			if [ -n "$_tp_pp" ] && [ "$_tp_pp" != "0" ]; then
				_tp_w=$(curl -o /dev/null -s -m 6 -x "http://127.0.0.1:$_tp_pp" \
					-w '%{http_code} %{time_starttransfer}' \
					"https://api.telegram.org/" 2>/dev/null)
				_tp_c="${_tp_w%% *}"; _tp_t="${_tp_w##* }"
				if [ -n "$_tp_c" ] && [ "$_tp_c" != "000" ]; then
					printf '{"ok":1,"ms":%s,"via":"proxy"}\n' \
						"$(printf '%s' "$_tp_t" | awk '{printf "%d", $1 * 1000}')"
					return 0
				fi
			fi
			_tp_cp=$(_clash_ping api.telegram.org) && { echo "$_tp_cp"; return 0; }
		fi
		echo '{"ok":0,"via":"tls"}'
	}
	case "${2:-}" in
		api.telegram.org|telegram.org|telegram|web.telegram.org)
			_tg_probe; exit 0 ;;
	esac
	_h="${2:-youtube.com}"
	_po=$(ping -c 1 -W 2 "$_h" 2>/dev/null)
	case "$_po" in
		*"(198.18."*|*"(198.19."*)
			if command -v curl >/dev/null 2>&1; then
				_hw=$(curl -o /dev/null -s -m 4 -w '%{http_code} %{time_starttransfer}' "https://$_h/" 2>/dev/null)
				_hc="${_hw%% *}"; _ht="${_hw##* }"
				if [ -n "$_hc" ] && [ "$_hc" != "000" ]; then
					printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(printf '%s' "$_ht" | awk '{printf "%d", $1 * 1000}')"
				else
					_cp_out=$(_clash_ping "$_h") && echo "$_cp_out" || echo '{"ok":0,"via":"http"}'
				fi
			else
				_t0=$(awk '{printf "%.0f", $1 * 100}' /proc/uptime)
				if wget -q --spider -T 4 "https://$_h/" 2>/dev/null; then
					_t1=$(awk '{printf "%.0f", $1 * 100}' /proc/uptime)
					printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(( (_t1 - _t0) * 10 ))"
				else
					echo '{"ok":0,"via":"http"}'
				fi
			fi
			;;
		*)
			_ms=$(printf '%s\n' "$_po" | sed -n 's/.*time=\([0-9]*\).*/\1/p' | head -1)
			if [ -n "$_ms" ]; then
				printf '{"ok":1,"ms":%s}\n' "$_ms"
			else
				if command -v curl >/dev/null 2>&1; then
					_hw=$(curl -o /dev/null -s -m 4 -w '%{http_code} %{time_starttransfer}' "https://$_h/" 2>/dev/null)
					_hc="${_hw%% *}"; _ht="${_hw##* }"
					if [ -n "$_hc" ] && [ "$_hc" != "000" ]; then
						printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(printf '%s' "$_ht" | awk '{printf "%d", $1 * 1000}')"
					else
						_cp_out=$(_clash_ping "$_h"); [ -n "$_cp_out" ] && echo "$_cp_out" || echo '{"ok":0}'
					fi
				elif wget -q --spider -T 4 "https://$_h/" 2>/dev/null; then
					echo '{"ok":1,"ms":0,"via":"http"}'
				else
					_cp_out=$(_clash_ping "$_h"); [ -n "$_cp_out" ] && echo "$_cp_out" || echo '{"ok":0}'
				fi
			fi
			;;
	esac
	;;
svcstatus)
	_svc_json "$2"
	echo
	;;
svcall)
	# '-' = empty list, see docs/subsystems/internet-priority.md#svcall-empty-list
	_sj=""
	for _s in $(printf '%s' "$2" | tr ',' ' '); do
		case "$_s" in ''|-) continue ;; esac
		_sj="$_sj,\"$(json_esc "$_s")\":$(_svc_json "$_s")"
	done
	_cj=""
	for _k in $(printf '%s' "$3" | tr ',' ' '); do
		case "$_k" in
			go|legacy) _kb=/usr/share/5gmodem/ssclash.sh ;;
			nikki)     _kb=/usr/share/5gmodem/nikki.sh ;;
			*)         continue ;;
		esac
		_ko=$("$_kb" status "$_k" 2>/dev/null)
		[ -n "$_ko" ] || _ko='{}'
		_cj="$_cj,\"$_k\":$_ko"
	done
	printf '{"svc":{%s},"ssc":{%s}}\n' "${_sj#,}" "${_cj#,}"
	;;
*)
	echo '{"error":"usage: netpri.sh list|set <iface>"}'
	exit 1
	;;
esac
