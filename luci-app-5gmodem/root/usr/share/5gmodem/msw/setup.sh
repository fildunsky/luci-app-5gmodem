setup_one_modem() {
	P="$1"
	if ! usb_path_present "$P"; then
		logger -t 5gmodem "autosetup: $P is gone from the bus - skipping (device appeared and vanished)"
		return 0
	fi
	if is_hilink "$P"; then
		uci -q set "$CFG.$(secname "$P").kind=hilink"
		uci -q commit "$CFG"
		_hnet=$(hilink_netdev "$P")
		[ -n "$_hnet" ] && setup_hilink "$P" "$_hnet" >/dev/null
		if try_at_debug "$P"; then
			rm -f /tmp/5gmodem/listmodems.cache /tmp/5gmodem/listmodems.stamp 2>/dev/null
			_hnet=$(hilink_netdev "$P")
			[ -n "$_hnet" ] && setup_hilink "$P" "$_hnet" >/dev/null
		fi
		_dbg_at=$(at_for_path "$P")
		if [ -n "$_dbg_at" ]; then
			uci -q set "$CFG.$(secname "$P").at_port=$_dbg_at"
			[ "$P" = "$(active_path)" ] && uci -q set "$CFG.@5gmodem[0].at_port=$_dbg_at"
			uci -q commit "$CFG"
		fi
		"$RES/ensureports.sh" >/dev/null 2>&1
		return 0
	fi

	if is_tether "$P"; then
		is_iphone "$P" && usbmuxd_ensure
		_tnet=$(tether_netdev "$P")
		if [ -n "$_tnet" ]; then
			setup_hilink "$P" "$_tnet" tether >/dev/null
			is_iphone "$P" || ( exec 1000>&- 6>&- 7>&- 8>&- 9>&-; tether_web_recheck "$P" "$_tnet" ) >/dev/null 2>&1 </dev/null &
		elif is_iphone "$P"; then
			ucitx_take; _t_lk=$?
			_tsec=$(ensure_section "$P")
			uci -q set "$CFG.$_tsec.kind=tether"
			uci -q set "$CFG.$_tsec.tether=iphone"
			uci -q commit "$CFG"
			[ "$_t_lk" = 0 ] && ucitx_drop
			logger -t 5gmodem "iphone: $P is connected without a network device ($(iphone_state "$P")) - waiting for Trust and Personal Hotspot"
		else
			logger -t 5gmodem "tether: $P looks like USB tethering but has no network device yet"
		fi
		return 0
	fi

	SEC=$(ensure_section "$P")
	if [ "$(uci -q get "$CFG.$SEC.kind")" = tether ]; then
		uci -q delete "$CFG.$SEC.kind"
		uci -q delete "$CFG.$SEC.tether"
		_tni=$(uci -q get "$CFG.$SEC.network")
		if [ -n "$_tni" ] && [ "$(uci -q get "network.$_tni.modem_kind")" = tether ]; then
			uci -q delete "network.$_tni.modem_kind"
			uci -q delete "network.$_tni.modem_tether"
			uci -q commit network
		fi
		logger -t 5gmodem "tether: $P is a known modem - phone mark removed"
	fi

	_am=$(active_path)
	if [ -z "$_am" ] || ! "$RES/listmodems.sh" 2>/dev/null | grep -qF "\"path\":\"$_am\""; then
		uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	fi
	A=$(at_for_path "$P")
	[ -n "$A" ] && {
		uci -q set "$CFG.$SEC.at_port=$A"
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].at_port=$A"
	}
	uci -q commit "$CFG"

	_wp=$(uci -q get "$CFG.$SEC.want_proto")
	if [ -n "$_wp" ]; then
		uci -q delete "$CFG.$SEC.want_proto"; uci -q commit "$CFG"
		MODEM_PATH="$P" "$RES/mkiface.sh" "$(uci -q get "$CFG.$SEC.network")" "$_wp" >/dev/null 2>&1
		_made=$(uci -q get "$CFG.$SEC.network")
		_mp=$(at_for_path "$P")
		if [ -n "$_mp" ]; then
			uci -q set "$CFG.$SEC.at_port=$_mp"
			[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].at_port=$_mp"
		fi
		uci -q commit "$CFG"
		"$RES/ensureports.sh" >/dev/null 2>&1
		[ -n "$_made" ] && { ubus call network reload >/dev/null 2>&1; ifup "$_made" >/dev/null 2>&1; }
		logger -t 5gmodem "autosetup: $P -> want_proto=$_wp port=${_mp:-?} -> ${_made:-fail}"
		[ -n "$_made" ] && ( "$RES/modemswitch.sh" autoapn "$_made" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
		return 0
	fi

	_ex=$(iface_for_imei "$(imei_for_path "$P")")
	[ -n "$_ex" ] || _ex=$(iface_for_path "$P")
	if [ -n "$_ex" ] && ! iface_owned_by "$_ex" "$P" "$(imei_for_path "$P")"; then
		logger -t 5gmodem "autosetup: $_ex is owned by another modem - not adopting, will create our own"
		_ex=""
	fi
	if [ -n "$_ex" ] && [ "$(uci -q get "network.$_ex.modem_stale")" = "1" ]; then
		logger -t 5gmodem "autosetup: $_ex marked stale - recreating"
		_ex=""
	fi
	if [ -n "$_ex" ]; then
		uci -q set "$CFG.$SEC.network=$_ex"
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].network=$_ex"
		_fp_was="$(uci -q get "network.$_ex.proto")|$(uci -q get "network.$_ex.device")|$(uci -q get "network.$_ex.devpath")"
		uci -q delete "network.$_ex.auto" 2>/dev/null
		uci -q delete "network.$_ex.modem_swapped" 2>/dev/null
		stamp_iface_owner "$_ex" "$P"
		follow_iface_device "$_ex" "$P"
		fix_iface_proto "$_ex"
		_pr=$(uci -q get "network.$_ex.proto")
		case "$(uci -q get "$CFG.$SEC.iface_proto")" in
			mbim|qmi)
				case "$_pr" in
					mbim|qmi) uci -q set "$CFG.$SEC.iface_proto=$_pr" ;;
				esac
				;;
		esac
		if [ "$(active_path)" = "$P" ] && proto_in mm "$_pr" \
		   && uci -q get "$CFG.sms" >/dev/null 2>&1 && [ -z "$(uci -q get "$CFG.sms.sms_via_mm")" ]; then
			uci -q set "$CFG.sms.sms_via_mm=1"
			uci -q set "$CFG.sms.ussd_via_mm=1"
		fi
		uci -q commit "$CFG"
		"$RES/ensureports.sh" >/dev/null 2>&1
		_fp_now="$(uci -q get "network.$_ex.proto")|$(uci -q get "network.$_ex.device")|$(uci -q get "network.$_ex.devpath")"
		_fp_up=0
		if [ "$_fp_was" != "$_fp_now" ] \
		   || ! ubus -S call "network.interface.$_ex" status >/dev/null 2>&1; then
			ubus call network reload >/dev/null 2>&1
		elif [ "$(ubus -S call "network.interface.$_ex" status 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null)" = true ]; then
			_fp_up=1
		fi
		[ "$_fp_up" = 1 ] || ifup "$_ex" >/dev/null 2>&1
		logger -t 5gmodem "autosetup: $P -> adopted existing $_ex"
		( "$RES/modemswitch.sh" autoapn "$_ex" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
		return 0
	fi

	MODEM_PATH="$P" "$RES/mkiface.sh" "" auto >/dev/null 2>&1
	"$RES/ensureports.sh" >/dev/null 2>&1
	_made=$(uci -q get "$CFG.$SEC.network")
	logger -t 5gmodem "autosetup: $P -> ${_made:-failed}"
	[ -n "$_made" ] && drop_stale_ifaces "$P" "$_made"
	[ -n "$_made" ] && ( "$RES/modemswitch.sh" autoapn "$_made" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
}
