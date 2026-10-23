apply_ussd_quirk() {
	command -v ussd_raw_for >/dev/null 2>&1 || return 0
	_v=$(uci -q get "$CFG.$1.ussd_raw")
	if [ -z "$_v" ]; then
		_v=$(ussd_raw_for "$(uci -q get "$CFG.$1.model")" "$(uci -q get "$CFG.$1.vidpid")")
	fi
	case "$_v" in
		0|1) uci -q set "5gmodem.sms.ussd=$_v" ;;
	esac

	command -v ussd_needs_3g_for >/dev/null 2>&1 || return 0
	_g=$(uci -q get "$CFG.$1.ussd_3g")
	if [ -z "$_g" ]; then
		_g=$(ussd_needs_3g_for "$(uci -q get "$CFG.$1.model")" "$(uci -q get "$CFG.$1.vidpid")")
	fi
	case "$_g" in
		0|1) : ;;
		*)   _g=0 ;;
	esac
	uci -q set "5gmodem.sms.ussd_3g=$_g"
}

prune_parks() {
	_pp_now=$(date +%s 2>/dev/null); [ -n "$_pp_now" ] || return 0
	_pp_ttl=2592000
	for _pp_s in $(uci -q show "$CFG" 2>/dev/null | sed -n 's/^'"$CFG"'\.\(m_park_[^.]*\)=modem$/\1/p'); do
		_pp_at=$(uci -q get "$CFG.$_pp_s.parked_at")
		case "$_pp_at" in
			''|*[!0-9]*) uci -q set "$CFG.$_pp_s.parked_at=$_pp_now"; continue ;;
		esac
		[ $((_pp_now - _pp_at)) -gt "$_pp_ttl" ] && {
			uci -q delete "$CFG.$_pp_s"
			logger -t 5gmodem "parked profile $_pp_s removed (older than 30 days)"
		}
	done
	uci -q commit "$CFG"
}

park_profile() {
	_pk_imei=$(uci -q get "$CFG.$1.imei_prev" | tr -cd '0-9')
	[ -n "$_pk_imei" ] || _pk_imei=$(uci -q get "$CFG.$1.imei" | tr -cd '0-9')
	_pk_ser=$(uci -q get "$CFG.$1.serial")
	if [ -n "$_pk_imei" ]; then
		_pk_dst="m_park_$_pk_imei"
	elif [ -n "$_pk_ser" ]; then
		_pk_dst="m_park_s$(echo "$_pk_ser" | sed 's/[^A-Za-z0-9]/_/g')"
	else
		return 0
	fi
	uci -q set "$CFG.$_pk_dst=modem"
	[ -n "$_pk_imei" ] && uci -q set "$CFG.$_pk_dst.imei=$_pk_imei"
	[ -n "$_pk_ser" ] && uci -q set "$CFG.$_pk_dst.serial=$_pk_ser"
	uci -q set "$CFG.$_pk_dst.parked=1"
	uci -q set "$CFG.$_pk_dst.parked_at=$(date +%s 2>/dev/null)"
	for _pk_k in network apn_mode apn_plmn esim_show allow_roaming mm_exclude \
	             celllock at_debug pdp_mode pdp_ok save_band save_band5gnsa save_band5gsa save_mode \
	             alias alias_imei no_at mm_at mm_at_if mm_at_vp; do
		_pk_v=$(uci -q get "$CFG.$1.$_pk_k")
		[ -n "$_pk_v" ] && uci -q set "$CFG.$_pk_dst.$_pk_k=$_pk_v"
	done
	uci -q delete "$CFG.$1.imei_prev"
	prune_parks
	logger -t 5gmodem "modem profile ${_pk_imei:+IMEI $_pk_imei}${_pk_imei:+ }${_pk_ser:+serial $_pk_ser} parked ($1 -> $_pk_dst) until it returns"
}

swap_cleanup() {
	_new=$(modem_vidpid "$1")
	[ -n "$_new" ] || return 0
	_old=$(uci -q get "$CFG.$2.vidpid")
	if [ -z "$_old" ]; then
		uci -q set "$CFG.$2.vidpid=$_new"
		uci -q set "$CFG.$2.product=$(modem_product "$1")"
		uci -q commit "$CFG"
		return 0
	fi
	[ "$_old" = "$_new" ] && return 0

	_vid_old=${_old%%:*}
	_vid_new=${_new%%:*}
	if [ "$_vid_old" = "$_vid_new" ]; then
		logger -t 5gmodem "modem mode change on $1: $_old -> $_new (same vendor, keeping hardware properties)"
		purge_path_caches "$1"
		uci -q set "$CFG.$2.vidpid=$_new"
		uci -q set "$CFG.$2.product=$(modem_product "$1")"
		uci -q delete "$CFG.$2.at_port" 2>/dev/null
		uci -q delete "$CFG.$2.data_at_port" 2>/dev/null
		uci -q delete "$CFG.$2.at_if" 2>/dev/null
		uci -q delete "$CFG.$2.ident_probe" 2>/dev/null
		uci -q commit "$CFG"
		return 0
	fi

	logger -t 5gmodem "modem swap on $1: $_old -> $_new, dropping stale settings"
	purge_path_caches "$1"
	park_profile "$2"
	_oif=$(uci -q get "$CFG.$2.network")
	_oimei=$(uci -q get "$CFG.$2.imei")
	if [ -n "$_oif" ] && uci -q get "network.$_oif" >/dev/null 2>&1 \
	   && iface_owned_by "$_oif" "$1" "$_oimei"; then
		ifdown "$_oif" >/dev/null 2>&1
		uci -q set "network.$_oif.auto=0"
		uci -q set "network.$_oif.modem_swapped=1"
		_ostamp=$(uci -q get "network.$_oif.modem_imei")
		if [ -n "$_ostamp" ]; then
			logger -t 5gmodem "swap: interface '$_oif' kept for modem IMEI $_ostamp (auto=0 until it returns)"
		else
			uci -q set "network.$_oif.modem_stale=1"
			logger -t 5gmodem "swap: stopped stale owned interface '$_oif' (rerun setup to rebuild)"
		fi
		uci -q commit network
	fi
	for o in at_port data_at_port network iface_proto imei serial celllock kind netdev \
	         mm_exclude ussd_3g heal slot_type_0 slot_type_1 slot_type_2 \
	         model_vp apn_plmn apn_imsi band_full save_band save_band5gnsa save_band5gsa save_mode \
	         no_at mm_at mm_at_if mm_at_vp at_if ident_probe; do
		uci -q delete "$CFG.$2.$o" 2>/dev/null
	done
	uci -q set "$CFG.$2.vidpid=$_new"
	uci -q set "$CFG.$2.product=$(modem_product "$1")"
	uci -q set "$CFG.$2.model="
	uci -q delete "$CFG.$2.model" 2>/dev/null
	uci -q commit "$CFG"
	[ "$1" = "$(active_path)" ] && apply_ussd_quirk "$2"
}

modem_imei() {
	_mi=$(uci -q get "$CFG.$(secname "$1").imei")
	case "$_mi" in ''|*[!0-9]*) : ;; *) echo "$_mi"; return 0 ;; esac
	if [ "$(uci -q get "$CFG.$(secname "$1").kind")" = "hilink" ]; then
		_mi=$("$RES/hilink.sh" json "$1" 2>/dev/null | jsonfilter -e '@.imei' 2>/dev/null)
		case "$_mi" in ''|*[!0-9]*) : ;; *) echo "$_mi"; return 0 ;; esac
	fi
	_mi_mm=$(mm_index_for_path "$1")
	if [ -n "$_mi_mm" ]; then
		_mi=$(mmk_imei "$(mmcli -m "$_mi_mm" -K 2>/dev/null)")
		[ -n "$_mi" ] && { echo "$_mi"; return 0; }
	fi
	_mi_sec=$(secname "$1")
	if command -v mm_at_fragile >/dev/null 2>&1 && [ -n "$(mm_at_fragile "$(modem_vidpid "$1")")" ] \
	   && { [ -n "$_mi_mm" ] || [ "$(uci -q get "network.$(uci -q get "$CFG.$_mi_sec.network").proto" 2>/dev/null)" = "modemmanager" ]; }; then
		mm_at_allowed "$1" "$_mi_sec" || return 1
		if [ -n "$MM_AT_PORT" ]; then
			at_lock "$MM_AT_PORT" 8 2>/dev/null || return 1
			_mi=$(at_query "$MM_AT_PORT" "AT+CGSN" 6 | grep -oE '^[0-9]{14,16}$' | head -1)
			at_unlock 2>/dev/null
			[ -n "$_mi" ] && { echo "$_mi"; return 0; }
			return 1
		fi
	fi
	_mi_nc="/tmp/5gmodem/imei_none_$(snap_key "$1")"
	_mi_now=$(uptime_s)
	_mi_ttys=$("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null | tr '\n' ' ')
	if [ -f "$_mi_nc" ]; then
		read -r _mi_ot _mi_op 2>/dev/null < "$_mi_nc"
		case "$_mi_ot" in ''|*[!0-9]*) _mi_ot=0 ;; esac
		if [ "$_mi_op" = "${_mi_ttys% }" ] \
		   && [ "$((_mi_now - _mi_ot))" -ge 0 ] \
		   && [ "$((_mi_now - _mi_ot))" -lt "${IMEI_NEG_TTL:-60}" ]; then
			return 1
		fi
	fi

	_mi_fresh=$("$RES/listmodems.sh" --refresh 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null | tr '\n' ' ')
	for _mt in $_mi_fresh; do
		[ -e "$_mt" ] || continue
		at_lock "$_mt" 8 2>/dev/null || continue
		_mi=$(at_query "$_mt" "AT+CGSN" 6 \
			| grep -oE '^[0-9]{14,16}$' | head -1)
		at_unlock 2>/dev/null
		[ -n "$_mi" ] && { rm -f "$_mi_nc" 2>/dev/null; echo "$_mi"; return 0; }
	done
	printf '%s %s\n' "$_mi_now" "${_mi_fresh% }" > "$_mi_nc" 2>/dev/null
	return 1
}

sec_by_imei() {
	[ -n "$1" ] || return 1
	uci -q show "$CFG" 2>/dev/null \
		| sed -n "s/^$CFG\.\(m_[^.]*\)\.imei='\?$1'\?\$/\1/p" \
		| while read -r _si; do [ "$_si" = "$2" ] || echo "$_si"; done | head -1
}

sec_by_serial() {
	[ -n "$1" ] || return 1
	uci -q show "$CFG" 2>/dev/null | grep -F ".serial='$1'" \
		| sed -n "s/^$CFG\.\(m_[^.]*\)\.serial=.*/\1/p" \
		| while read -r _ss; do [ "$_ss" = "$2" ] || echo "$_ss"; done | head -1
}

modem_serial() {
	_reg_rec "$1" | jsonfilter -e '@.serial' 2>/dev/null | head -1
}

migrate_profile() {
	[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 0
	_mp_keepnet=""
	_mp_dstnet=$(uci -q get "$CFG.$2.network")
	if [ -n "$_mp_dstnet" ] && [ -n "$(uci -q get "network.$_mp_dstnet")" ]; then
		_mp_dstimei=$(uci -q get "$CFG.$2.imei")
		[ -n "$_mp_dstimei" ] \
			&& [ "$(uci -q get "network.$_mp_dstnet.modem_imei")" = "$_mp_dstimei" ] \
			&& _mp_keepnet=1
	fi
	_mp_skipmm=""
	[ "$(uci -q get "$CFG.$1.iface_proto")" = "$(uci -q get "$CFG.$2.iface_proto")" ] || _mp_skipmm=1
	for _mk in network apn_mode apn_plmn esim_show allow_roaming mm_exclude \
	           celllock at_debug pdp_mode pdp_ok save_band save_band5gnsa save_band5gsa save_mode imei \
	           alias alias_imei no_at mm_at mm_at_if mm_at_vp; do
		[ "$_mk" = mm_exclude ] && [ -n "$_mp_skipmm" ] && {
			logger -t 5gmodem "profile move $1 -> $2: protocols differ, not carrying mm_exclude over"
			continue
		}
		[ "$_mk" = network ] && [ -n "$_mp_keepnet" ] && {
			logger -t 5gmodem "profile move $1 -> $2: interface $_mp_dstnet is already owned by IMEI $_mp_dstimei, leaving it"
			continue
		}
		_mv=$(uci -q get "$CFG.$1.$_mk")
		[ -n "$_mv" ] && uci -q set "$CFG.$2.$_mk=$_mv"
	done
	if [ -n "$_mp_keepnet" ]; then
		_mp_oldnet=$(uci -q get "$CFG.$1.network")
		if [ -n "$_mp_oldnet" ] && [ "$_mp_oldnet" != "$_mp_dstnet" ] \
		   && [ "$(uci -q get "network.$_mp_oldnet.modem_imei")" = "$_mp_dstimei" ]; then
			ifdown "$_mp_oldnet" 2>/dev/null
			uci -q delete "network.$_mp_oldnet"
			uci -q commit network
			ubus call network reload >/dev/null 2>&1
			logger -t 5gmodem "profile move $1 -> $2: twin interface $_mp_oldnet removed (same IMEI $_mp_dstimei, the modem already lives on $_mp_dstnet)"
		fi
	fi
	uci -q delete "$CFG.$1"
	uci -q commit "$CFG"
	logger -t 5gmodem "profile moved: $1 -> $2 (same modem in a different port)"
}

ensure_section() {
	SEC=$(secname "$1")
	if ! uci -q get "$CFG.$SEC" >/dev/null 2>&1 && ! usb_path_present "$1"; then
		echo "$SEC"
		return 0
	fi
	if ! uci -q get "$CFG.$SEC" >/dev/null 2>&1; then
		uci -q set "$CFG.$SEC=modem"
		uci -q set "$CFG.$SEC.path=$1"
		uci -q set "$CFG.$SEC.product=$(modem_product "$1")"
		uci -q set "$CFG.$SEC.vidpid=$(modem_vidpid "$1")"
	else
		swap_cleanup "$1" "$SEC"
	fi
	[ -n "$(uci -q get "$CFG.$SEC.path")" ] || uci -q set "$CFG.$SEC.path=$1"
	_es_ser=$(modem_serial "$1")
	stub_serial_known "$_es_ser" && _es_ser=""
	[ -n "$_es_ser" ] && uci -q set "$CFG.$SEC.serial=$_es_ser"

	if [ -n "$_es_ser" ]; then
		_es_sold=$(sec_by_serial "$_es_ser" "$SEC")
		if [ -n "$_es_sold" ]; then
			_es_soldpath=$(uci -q get "$CFG.$_es_sold.path")
			if [ -n "$_es_soldpath" ] && [ -e "/sys/bus/usb/devices/$_es_soldpath" ]; then
				stub_serial_add "$_es_ser"
				uci -q delete "$CFG.$SEC.serial"
				uci -q delete "$CFG.$_es_sold.serial"
				uci -q commit "$CFG"
				_es_ser=""
			else
				logger -t 5gmodem "modem serial=$_es_ser recognized on $1 (was $_es_soldpath) - moving the profile"
				migrate_profile "$_es_sold" "$SEC"
			fi
		fi
	fi

	_es_imei=$(modem_imei "$1")
	[ -n "$_es_imei" ] || _es_imei=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
	_es_previmei=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
	if [ -n "$_es_imei" ] && [ -n "$_es_previmei" ] && [ "$_es_imei" != "$_es_previmei" ]; then
		logger -t 5gmodem "a different unit in port $1 with the same vid:pid (IMEI $_es_previmei -> $_es_imei) - re-reading model and ports"
		uci -q delete "$CFG.$SEC.model" 2>/dev/null
		uci -q delete "$CFG.$SEC.model_vp" 2>/dev/null
		uci -q delete "$CFG.$SEC.at_port" 2>/dev/null
		uci -q delete "$CFG.$SEC.data_at_port" 2>/dev/null
		uci -q commit "$CFG"
		purge_path_caches "$1"
	fi

	if [ -n "$_es_imei" ]; then
		_es_old=$(sec_by_imei "$_es_imei" "$SEC")
		if [ -n "$_es_old" ] && [ -n "$_es_ser" ]; then
			_es_oser=$(uci -q get "$CFG.$_es_old.serial")
			if [ -n "$_es_oser" ] && [ "$_es_oser" != "$_es_ser" ]; then
				logger -t 5gmodem "IMEI $_es_imei on $1 matches section $_es_old but serial differs ($_es_ser vs $_es_oser) - different unit, cancelling migration"
				echo "$SEC"
				return 0
			fi
		fi
		if [ -n "$_es_old" ]; then
			_es_oldpath=$(uci -q get "$CFG.$_es_old.path")
			if [ -n "$_es_oldpath" ] && [ -e "/sys/bus/usb/devices/$_es_oldpath" ]; then
				logger -t 5gmodem "IMEI $_es_imei read from $1 but belongs to present $_es_oldpath - cancelling profile migration"
				echo "$SEC"
				return 0
			fi
			uci -q set "$CFG.$SEC.imei=$_es_imei"
			migrate_profile "$_es_old" "$SEC"
		else
			uci -q set "$CFG.$SEC.imei=$_es_imei"
		fi
	fi
	echo "$SEC"
}
