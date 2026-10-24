is_hilink() {
	_ih_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ih_sec.kind")" = "hilink" ] && return 0
	_ih_id=$(modem_vidpid "$1")
	[ -n "$_ih_id" ] || return 1
	for _ih_k in $HILINK_IDS; do
		[ "$_ih_id" = "$_ih_k" ] && return 0
	done
	case "$_ih_id" in
		12d1:*|05c6:90b4|19d2:*|15a9:*|1076:8002|0846:68e1)
			_ih_j=$("$RES/listmodems.sh" 2>/dev/null)
			_ih_tty=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null)
			_ih_wdm=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].wdm[*]" 2>/dev/null)
			_ih_net=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].net[*]" 2>/dev/null)
			[ -z "$_ih_tty" ] && [ -z "$_ih_wdm" ] && [ -n "$_ih_net" ] && return 0
			[ "$_ih_id" = 05c6:90b4 ] && [ -z "$_ih_wdm" ] && [ -n "$_ih_net" ] && return 0
			;;
	esac
	return 1
}

is_tether() {
	is_iphone "$1" && return 0
	known_modem_path "$1" && return 1
	[ "$(uci -q get "$CFG.$(secname "$1").kind")" = "tether" ] && return 0
	_it_d="/sys/bus/usb/devices/$1"
	[ -f "$_it_d/idVendor" ] || return 1
	for _it_p in "$_it_d"/*:*/ttyUSB* "$_it_d"/*:*/tty/tty* "$_it_d"/*:*/usbmisc/*; do
		[ -e "$_it_p" ] && return 1
	done
	_it_cdc=""
	for _it_i in "$_it_d"/*:*; do
		[ -f "$_it_i/bInterfaceClass" ] || continue
		case "$(cat "$_it_i/bInterfaceClass" 2>/dev/null)/$(cat "$_it_i/bInterfaceSubClass" 2>/dev/null)/$(cat "$_it_i/bInterfaceProtocol" 2>/dev/null)" in
			ef/04/01|e0/01/03) return 0 ;;
			02/0d/*|02/06/*) _it_cdc=1 ;;
		esac
	done
	[ -n "$_it_cdc" ] || return 1
	read -r _it_v < "$_it_d/idVendor"
	tether_cdc_vid "$_it_v" || return 1
	hilink_netdev "$1" >/dev/null
}

tether_netdev() {
	if is_iphone "$1"; then iphone_netdev "$1"; else hilink_netdev "$1"; fi
}

ucitx_take() {
	_ut_n=0
	exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null || return 1
	while ! flock -n 6 2>/dev/null; do
		_ut_n=$((_ut_n + 1))
		[ "$_ut_n" -ge 20 ] && { logger -t 5gmodem "ucitx: lock is busy for 20 s - writing without it"; return 1; }
		sleep 1
	done
	return 0
}

ucitx_drop() {
	flock -u 6 2>/dev/null
	exec 6>&- 2>/dev/null
}

iface_user_off() {
	[ "$(uci -q get "network.$1.disabled")" = 1 ] && return 0
	[ "$(uci -q get "network.$1.auto")" = 0 ] || return 1
	[ "$(uci -q get "network.$1.modem_swapped")" = 1 ] && return 1
	[ "$(uci -q get "network.$1.modem_parked")" = 1 ] && return 1
	return 0
}

hilink_netdev() {
	for _hd in /sys/bus/usb/devices/"$1":*/net/*; do
		[ -e "$_hd" ] || continue
		basename "$_hd"; return 0
	done
	return 1
}

setup_hilink() {
	_hp="$1"; _hd="$2"; _hkind="${3:-hilink}"
	ucitx_take; _h_lk=$?
	_hsec=$(ensure_section "$_hp")
	uci -q set "$CFG.$_hsec.kind=$_hkind"
	_htos=""
	if [ "$_hkind" = tether ]; then
		_htos=$(tether_os "$_hp") && uci -q set "$CFG.$_hsec.tether=$_htos"
	else
		uci -q delete "$CFG.$_hsec.tether" 2>/dev/null
	fi
	uci -q set "$CFG.$_hsec.netdev=$_hd"
	_hif=$(uci -q get "$CFG.$_hsec.network")
	[ -n "$_hif" ] || _hif=$(iface_for_imei "$(imei_for_path "$_hp")")
	if [ -z "$_hif" ]; then
		_hn=1; _hif="modem"
		while uci -q get "network.$_hif" >/dev/null 2>&1; do
			_hn=$((_hn + 1)); _hif="modem$_hn"
		done
	fi
	_h_pre=$(uci -q show "network.$_hif" 2>/dev/null | grep -v "\.modem_tether=")
	_h_off=""
	[ -n "$_h_pre" ] && iface_user_off "$_hif" && _h_off=1
	uci -q set "network.$_hif=interface"
	uci -q set "network.$_hif.proto=dhcp"
	uci -q set "network.$_hif.device=$_hd"
	for _hk in apn pdptype usbpath auth username password devpath allow_roaming; do
		uci -q delete "network.$_hif.$_hk" 2>/dev/null
	done
	[ -n "$(uci -q get "network.$_hif.metric")" ] || uci -q set "network.$_hif.metric=20"
	[ -n "$_h_off" ] || uci -q delete "network.$_hif.auto" 2>/dev/null
	uci -q delete "network.$_hif.modem_swapped" 2>/dev/null
	uci -q delete "network.$_hif.modem_stale" 2>/dev/null
	if [ "$_hkind" = tether ]; then
		uci -q set "network.$_hif.modem_kind=tether"
		uci -q set "network.$_hif.modem_tether=$_htos"
	else
		uci -q delete "network.$_hif.modem_kind" 2>/dev/null
		uci -q delete "network.$_hif.modem_tether" 2>/dev/null
	fi
	uci -q commit network
	stamp_iface_owner "$_hif" "$_hp"
	_hz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	if [ -n "$_hz" ]; then
		case " $(uci -q get "firewall.$_hz.network") " in
			*" $_hif "*) ;;
			*) case "$(uci -q show "firewall.$_hz.network" 2>/dev/null)" in
				*"' '"*) ;;
				*=\'*\ *\')
					_hzl=$(uci -q get "firewall.$_hz.network" | tr -d "'\"")
					uci -q delete "firewall.$_hz.network"
					for _hze in $_hzl; do uci -q add_list "firewall.$_hz.network=$_hze"; done ;;
			   esac
			   uci -q add_list "firewall.$_hz.network=$_hif"
			   uci -q commit firewall
			   logger -t 5gmodem "$_hkind: $_hif added to the wan zone" ;;
		esac
	fi
	uci -q set "$CFG.$_hsec.network=$_hif"
	drop_stale_ifaces "$_hp" "$_hif"
	uci -q set "$CFG.$_hsec.iface_proto=dhcp"
	uci -q commit "$CFG"
	[ "$_h_lk" = 0 ] && ucitx_drop
	_h_post=$(uci -q show "network.$_hif" 2>/dev/null | grep -v "\.modem_tether=")
	_h_live=$(ubus call "network.interface.$_hif" status 2>/dev/null)
	_h_skip=""
	case "$_h_live" in
		*'"up": true'*)
			case "$_h_live" in
				*"\"l3_device\": \"$_hd\""*)
					[ "$_h_pre" = "$_h_post" ] && _h_skip=1 ;;
			esac ;;
	esac
	if [ -n "$_h_off" ]; then
		logger -t 5gmodem "$_hkind: $_hp ($_hd) -> interface $_hif is turned off by the user - device updated, not bringing it up"
	elif [ -n "$_h_skip" ]; then
		logger -t 5gmodem "$_hkind: $_hp ($_hd) is already up on interface $_hif - leaving it alone"
	else
		ifup "$_hif" >/dev/null 2>&1
		logger -t 5gmodem "$_hkind: $_hp ($_hd) -> interface $_hif (dhcp)"
	fi
	echo "$_hif"
}

tether_web_recheck() {
	_tw_n=0
	while [ "$_tw_n" -lt 12 ]; do
		sleep 5
		_tw_n=$((_tw_n + 1))
		usb_path_present "$1" || return 0
		[ "$(uci -q get "$CFG.$(secname "$1").kind")" = tether ] || return 0
		_tw_r=$("$RES/hilink.sh" probe "$1" 2>/dev/null)
		case "$_tw_r" in
			*'"hilink":1'*)
				_tw_c=$(printf '%s' "$_tw_r" | jsonfilter -e '@.classify' 2>/dev/null)
				[ "$_tw_c" = zte ] && uci -q set "$CFG.$(secname "$1").hl_api=zte"
				setup_hilink "$1" "$2" hilink >/dev/null
				rm -f /tmp/5gmodem/listmodems.cache /tmp/5gmodem/listmodems.stamp 2>/dev/null
				logger -t 5gmodem "tether: $1 answers a modem web API (${_tw_c:-unknown}) - it is a stick, not a phone"
				return 0 ;;
		esac
	done
}

_ad_hastty() {
	for _ht in /sys/bus/usb/devices/"$1":*/ttyUSB* /sys/bus/usb/devices/"$1":*/tty/tty*; do
		[ -e "$_ht" ] && return 0
	done
	return 1
}

try_at_debug() {
	_ad_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ad_sec.at_debug")" = "0" ] && return 1
	hl_brovi "$_ad_sec" && return 1
	case "$(modem_vidpid "$1")" in 15a9:*|1076:8002|0846:68e1) return 1 ;; esac
	[ -n "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].tty[0]" 2>/dev/null)" ] && return 1
	_ad_w=0
	while [ "$_ad_w" -lt 25 ]; do
		"$RES/hilink.sh" probe "$1" 2>/dev/null | grep -q '"hilink":1' && break
		sleep 3
		_ad_w=$((_ad_w + 1))
	done
	if [ -z "$(uci -q get "$CFG.$_ad_sec.model")" ]; then
		case "$("$RES/hilink.sh" devname "$1" 2>/dev/null)" in
			*-325*)
				logger -t 5gmodem "hilink: $1 is a Brovi -325 (ASR), its debug AT port is silent - staying on the web API"
				return 1 ;;
		esac
	fi
	_ad_ok=""
	_ad_t=0
	while [ "$_ad_t" -lt 3 ]; do
		"$RES/hilink.sh" mode debug "$1" 2>/dev/null | grep -q '"success":true' && { _ad_ok=1; break; }
		sleep 4
		_ad_t=$((_ad_t + 1))
	done
	[ -n "$_ad_ok" ] || return 1
	logger -t 5gmodem "hilink: $1 switched to debug mode (AT ports exposed)"
	_ad_n=0
	while [ "$_ad_n" -lt 40 ]; do
		sleep 1
		_ad_hastty "$1" && break
		_ad_n=$((_ad_n + 1))
	done
	"$RES/listmodems.sh" --refresh >/dev/null 2>&1
	"$RES/hilink.sh" connect "$1" >/dev/null 2>&1
	return 0
}
