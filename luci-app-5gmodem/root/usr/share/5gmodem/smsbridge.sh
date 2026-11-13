#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem

if [ "$1" = queue-run ]; then
	for _qe in /etc/5gmodem/smsq/*.sms; do [ -f "$_qe" ] && break; _qe=""; done
	[ -n "$_qe" ] || exit 0
fi

. "$RES/lib.sh" 2>/dev/null

_TGT_PATH="${SMS_MODEM:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}"
_TGT_SEC="m_$(echo "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')"

_active_kind() {
	[ -n "$_TGT_PATH" ] || return 1
	uci -q get "$CFG.$_TGT_SEC.kind"
}

_active_is_android() {
	[ "$(_active_kind)" = tether ] || return 1
	android_tether_path "$_TGT_PATH" || return 1
	[ -f "$RES/android.sh" ] || return 1
	[ "$(jsonfilter -i "/tmp/5gmodem/metrics_$(snap_key "$_TGT_PATH").json" -e '@.backend' 2>/dev/null)" = android ]
}

_active_is_mm() {
	_amp="$_TGT_PATH"
	[ -n "$_amp" ] || return 1
	_ams="$_TGT_SEC"
	_amif=$(uci -q get "$CFG.$_ams.network")
	[ -n "$_amif" ] || _amif=$(uci -q get "$CFG.@5gmodem[0].network")
	_ampr=$(uci -q get "network.$_amif.proto")
	[ "$_ampr" = "modemmanager" ] && return 0
	proto_in proxy "$_ampr" && _mm_ready "$_amp"
}

_mm_ready() {
	[ -n "$1" ] || return 1
	_mr_f="/tmp/5gmodem/smsmm_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
	_mr_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$_mr_now" in ''|*[!0-9]*) _mr_now=0 ;; esac
	_mr_old=""; _mr_t=0
	[ -f "$_mr_f" ] && read -r _mr_old _mr_t < "$_mr_f"
	case "$_mr_t" in ''|*[!0-9]*) _mr_t=0 ;; esac
	if [ -n "$_mr_old" ] && [ "$_mr_t" -le "$_mr_now" ] && [ $((_mr_now - _mr_t)) -lt 15 ]; then
		[ "$_mr_old" = 1 ]
		return
	fi
	_mr_v=0
	if command -v mmcli >/dev/null 2>&1 && mm_owns_path "$1"; then
		_mr_i=$("$RES/modemswitch.sh" mmindex "$1" 2>/dev/null)
		case "$_mr_i" in
			''|*[!0-9]*) ;;
			*)
				case "$(mmcli -m "$_mr_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -1)" in
					enabled|searching|registered|connecting|connected|disconnecting) _mr_v=1 ;;
				esac ;;
		esac
	fi
	printf '%s %s\n' "$_mr_v" "$_mr_now" > "$_mr_f" 2>/dev/null
	if [ "$_mr_v" != "$_mr_old" ]; then
		if [ "$_mr_v" = 1 ]; then
			logger -t 5gmodem "smsbridge: modem $1 is ready in ModemManager - SMS through ModemManager"
		else
			logger -t 5gmodem "smsbridge: modem $1 is not ready in ModemManager - SMS over the AT port"
		fi
	fi
	[ "$_mr_v" = 1 ]
}

_port_proxy_mm() {
	[ "$(uci -q get 5gmodem.sms.sms_via_mm)" = "1" ] || return 1
	_ppm_p=$(tty_usbpath "$1" 2>/dev/null)
	[ -n "$_ppm_p" ] || return 1
	_ppm_if=$(uci -q get "$CFG.$(secname "$_ppm_p").network")
	proto_in proxy "$(uci -q get "network.$_ppm_if.proto")" || return 1
	_mm_ready "$_ppm_p"
}

if [ -z "$MM_MODEM_PATH" ] && [ -n "$_TGT_PATH" ]; then
	_tp_if=$(uci -q get "$CFG.$_TGT_SEC.network")
	[ -n "$_tp_if" ] || _tp_if=$(uci -q get "$CFG.@5gmodem[0].network")
	proto_in mm "$(uci -q get "network.$_tp_if.proto")" && export MM_MODEM_PATH="$_TGT_PATH"
fi

_via_mm() {
	[ "$(uci -q get 5gmodem.sms.sms_via_mm)" = "1" ] \
		&& [ -x /usr/share/5gmodem/sms_tool_mm ] && _active_is_mm
}

if [ "$1" = archive-run ] && [ "$(_active_kind)" != hilink ] && _via_mm \
   && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; then
	echo '{"result":"mm"}'
	exit 0
fi

_smstool() {
	if _via_mm; then
		echo /usr/share/5gmodem/sms_tool_mm
		return
	fi
	command -v sms_tool >/dev/null 2>&1 && echo /usr/bin/sms_tool || echo sms_tool
}

SEEN_DIR=/etc/5gmodem
SEEN_MAX=500

_seen_file() {
	_sp=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_sp" ] && echo "$SEEN_DIR/sms_seen.$_sp" || echo "$SEEN_DIR/sms_seen"
}

_nd_jesc() {
	printf '%s' "$1" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '
		BEGIN { ORS=""; printf "\"" }
		{ if (NR>1) printf "\\n"; printf "%s", $0 }
		END { printf "\"" }'
}

TG_MIG="$SEEN_DIR/sms_tg_migrated"

_tg_file() {
	_tp=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_tp" ] && echo "$SEEN_DIR/sms_tg.$_tp" || echo "$SEEN_DIR/sms_tg"
}

_tg_migrate() {
	[ -f "$TG_MIG" ] && return 0
	mkdir -p "$SEEN_DIR" 2>/dev/null || return 0
	for _tm_f in "$SEEN_DIR"/sms_seen "$SEEN_DIR"/sms_seen.*; do
		[ -f "$_tm_f" ] || continue
		case "$_tm_f" in *.tmp) continue ;; esac
		_tm_t="$SEEN_DIR/sms_tg${_tm_f#"$SEEN_DIR/sms_seen"}"
		[ -f "$_tm_t" ] || cp "$_tm_f" "$_tm_t" 2>/dev/null
	done
	: > "$TG_MIG" 2>/dev/null
}

_list_file() {
	case "$1" in
		tg) _tg_file ;;
		seen|'') _seen_file ;;
		*)
			_lf_p=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
			[ -n "$_lf_p" ] && echo "$SEEN_DIR/sms_$1.$_lf_p" || echo "$SEEN_DIR/sms_$1" ;;
	esac
}

_fwd_lists() {
	[ "$(uci -q get "$CFG.sms.tg_enabled")" = 1 ] && printf 'tg '
	[ "$(uci -q get "$CFG.sms.ntfy_enabled")" = 1 ] && printf 'ntfy '
	[ "$(uci -q get "$CFG.sms.hook_enabled")" = 1 ] && printf 'hook '
	return 0
}

_list_add() {
	_la_f="$1"; shift
	mkdir -p "$SEEN_DIR" 2>/dev/null
	for _k in "$@"; do
		[ -n "$_k" ] || continue
		grep -qxF "$_k" "$_la_f" 2>/dev/null || echo "$_k" >> "$_la_f"
	done
	[ -f "$_la_f" ] || : > "$_la_f" 2>/dev/null
	_la_max=$(uci -q get "$CFG.sms.archive_limit")
	case "$_la_max" in ''|*[!0-9]*) _la_max=0 ;; esac
	[ "${#_la_max}" -le 4 ] && [ "$_la_max" -le 2000 ] || _la_max=2000
	_la_max=$((SEEN_MAX + _la_max))
	if [ "$(wc -l 2>/dev/null < "$_la_f" || echo 0)" -gt "$_la_max" ]; then
		tail -n "$_la_max" "$_la_f" > "$_la_f.tmp" 2>/dev/null && mv "$_la_f.tmp" "$_la_f"
	fi
}

_kb_n=0

_kb_norm() {
	_KB_S="$1"
	case "$_KB_S" in
		*[[:cntrl:]]*) _KB_S=$(printf '%s' "$_KB_S" | tr -d '\r' | tr '\000-\037' ' ') ;;
	esac
	while :; do
		case "$_KB_S" in *' ') _KB_S=${_KB_S% } ;; *) break ;; esac
	done
}

_kb_put() {
	_kb_n=$((_kb_n + 1))
	_kb_norm "$2"
	_kb_pc="$4"
	while :; do
		case "$_kb_pc" in
			*"
") _kb_pc=${_kb_pc%?} ;;
			*) break ;;
		esac
	done
	eval "_kb_x$_kb_n=\$1; _kb_f$_kb_n=\$2; _kb_s$_kb_n=\$_KB_S; _kb_t$_kb_n=\$3; _kb_c$_kb_n=\$_kb_pc; _kb_p$_kb_n=\$5; _kb_o$_kb_n=\$6; _kb_r$_kb_n=\$7; _kb_h$_kb_n=\$8; _kb_k$_kb_n=''; _kb_g$_kb_n=''; _kb_gm$_kb_n=''"
	case "$1" in ''|*[!0-9]*) ;; *) eval "_kb_ix$1=$_kb_n" ;; esac
}

_kb_feed_json() {
	_kf_n=$(printf '%s' "$1" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_kf_n" in ''|*[!0-9]*) return 0 ;; esac
	_kf_i=0
	while [ "$_kf_i" -lt "$_kf_n" ]; do
		_kf_x=""; _kf_s=""; _kf_t=""; _kf_c=""; _kf_p=""; _kf_o=""; _kf_r=""
		eval "$(printf '%s' "$1" | jsonfilter \
			-e "_kf_x=@.msg[$_kf_i].index" -e "_kf_s=@.msg[$_kf_i].sender" \
			-e "_kf_t=@.msg[$_kf_i].timestamp" -e "_kf_c=@.msg[$_kf_i].content" \
			-e "_kf_p=@.msg[$_kf_i].part" -e "_kf_o=@.msg[$_kf_i].total" \
			-e "_kf_r=@.msg[$_kf_i].reference" 2>/dev/null)"
		_kf_i=$((_kf_i + 1))
		[ -n "$_kf_s$_kf_c" ] || continue
		_kb_put "$_kf_x" "$_kf_s" "$_kf_t" "$_kf_c" "$_kf_p" "$_kf_o" "$_kf_r" ""
	done
}

_kb_feed_arch_one() {
	_ka_h=""
	case "$_A_TOTAL" in ''|0|1|*[!0-9]*) _ka_h="$_A_KEY" ;; esac
	_kb_put "$_A_IDX0" "$_A_FROM" "$_A_TS" "$_A_TEXT" "$_A_PART" "$_A_TOTAL" "$_A_REF" "$_ka_h"
}

_kb_feed_arch() {
	_arch_ready
	_arch_each _kb_feed_arch_one
}

# "YYYY-MM-DD HH:MM..." -> minutes since 1970 in _KB_M (empty when unparsable).
# Shell arithmetic instead of date(1): _kb_build runs it for every stored part.
_kb_min() {
	_KB_M=""
	case "$1" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]*) ;;
		*) return 1 ;;
	esac
	_km_y=${1%%-*}; _km_r=${1#*-}
	_km_m=${_km_r%%-*}; _km_r=${_km_r#*-}
	_km_d=${_km_r%% *}; _km_r=${_km_r#* }
	_km_h=${_km_r%%:*}; _km_r=${_km_r#*:}
	_km_i=${_km_r%"${_km_r#??}"}
	# strip one leading zero: "08" would be read as octal
	_km_m=${_km_m#0}; _km_d=${_km_d#0}; _km_h=${_km_h#0}; _km_i=${_km_i#0}
	[ "$_km_m" -ge 1 ] && [ "$_km_m" -le 12 ] || return 1
	[ "$_km_m" -le 2 ] && _km_y=$((_km_y - 1))
	_km_e=$((_km_y / 400)); _km_yoe=$((_km_y - _km_e * 400))
	if [ "$_km_m" -gt 2 ]; then _km_mp=$((_km_m - 3)); else _km_mp=$((_km_m + 9)); fi
	_km_doe=$((_km_yoe * 365 + _km_yoe / 4 - _km_yoe / 100 + (153 * _km_mp + 2) / 5 + _km_d - 1))
	_KB_M=$((((_km_e * 146097 + _km_doe - 719468) * 24 + ${_km_h:-0}) * 60 + ${_km_i:-0}))
}

# Parts of one long SMS share sender, the 8-bit UDH reference and the part
# count. The reference wraps, so one sender reuses it: a part joins a group only
# within KB_WINDOW minutes of the group's first part and only into a free part
# slot. A byte-identical copy of a stored part rides along (its index is deleted
# with the group); any other part with a taken number starts its own group.
# 24 h: parts carry the SMSC time stamp, so they are seconds apart however late
# they are delivered, and 256 long messages from one sender within a day do not
# happen. Keep in step with sms_merge_parts() in readsms.js.
KB_WINDOW=1440

_kb_build() {
	_kb_i=1
	while [ "$_kb_i" -le "$_kb_n" ]; do
		eval "_kb_t=\$_kb_t$_kb_i"
		_kb_min "$_kb_t"
		eval "_kb_m$_kb_i=\$_KB_M"
		_kb_i=$((_kb_i + 1))
	done
	_kb_i=1
	while [ "$_kb_i" -le "$_kb_n" ]; do
		eval "_kb_k=\$_kb_k$_kb_i; _kb_s=\$_kb_s$_kb_i; _kb_f=\$_kb_f$_kb_i; _kb_t=\$_kb_t$_kb_i; _kb_p=\$_kb_p$_kb_i; _kb_o=\$_kb_o$_kb_i; _kb_r=\$_kb_r$_kb_i; _kb_h=\$_kb_h$_kb_i; _kb_lm=\$_kb_m$_kb_i"
		if [ -n "$_kb_k" ]; then _kb_i=$((_kb_i + 1)); continue; fi
		_kb_multi=1
		case "$_kb_o" in ''|0|1|*[!0-9]*) _kb_multi=0 ;; esac
		case "$_kb_p" in ''|*[!0-9]*) _kb_multi=0 ;; esac
		if [ "$_kb_multi" = 0 ]; then
			if [ -z "$_kb_h" ]; then
				eval "_kb_c=\$_kb_c$_kb_i"
				_kb_h=$(printf '%s|%s|%s' "$_kb_f" "$_kb_t" "$_kb_c" | md5sum)
				_kb_h=${_kb_h%% *}; _kb_h=${_kb_h%????????????????}
			fi
			eval "_kb_k$_kb_i=\"\$_kb_s|\$_kb_t|\$_kb_h\"; _kb_g$_kb_i=1"
			_kb_i=$((_kb_i + 1)); continue
		fi
		_kb_mem=""
		_kb_q=1
		while [ "$_kb_q" -le "$_kb_o" ]; do eval "_kb_b$_kb_q=''"; _kb_q=$((_kb_q + 1)); done
		_kb_j="$_kb_i"
		while [ "$_kb_j" -le "$_kb_n" ]; do
			eval "_kb_jk=\$_kb_k$_kb_j; _kb_jf=\$_kb_f$_kb_j; _kb_jo=\$_kb_o$_kb_j; _kb_jr=\$_kb_r$_kb_j; _kb_jp=\$_kb_p$_kb_j; _kb_jm=\$_kb_m$_kb_j"
			_kb_j0=$_kb_j
			_kb_j=$((_kb_j + 1))
			[ -z "$_kb_jk" ] && [ "$_kb_jf" = "$_kb_f" ] && [ "$_kb_jo" = "$_kb_o" ] && [ "$_kb_jr" = "$_kb_r" ] || continue
			case "$_kb_jp" in ''|*[!0-9]*) continue ;; esac
			if [ -n "$_kb_jm" ] && [ -n "$_kb_lm" ]; then
				_kb_d=$((_kb_jm - _kb_lm))
				[ "$_kb_d" -le "$KB_WINDOW" ] && [ "$_kb_d" -ge "-$KB_WINDOW" ] || continue
			fi
			if [ "$_kb_jp" -ge 1 ] && [ "$_kb_jp" -le "$_kb_o" ]; then
				eval "_kb_bq=\$_kb_b$_kb_jp"
				if [ -z "$_kb_bq" ]; then
					eval "_kb_b$_kb_jp=$_kb_j0"
				else
					eval "_kb_jc=\$_kb_c$_kb_j0; _kb_bc=\$_kb_c$_kb_bq; _kb_jt=\$_kb_t$_kb_j0; _kb_bt=\$_kb_t$_kb_bq"
					[ "$_kb_jc" = "$_kb_bc" ] || continue
					# a resent segment: the later copy gives the time, as before
					[ "$_kb_jt" \< "$_kb_bt" ] || eval "_kb_b$_kb_jp=$_kb_j0"
				fi
			fi
			_kb_mem="$_kb_mem $_kb_j0"
		done
		_kb_txt=""; _kb_have=0; _kb_tf=""
		_kb_q=1
		while [ "$_kb_q" -le "$_kb_o" ]; do
			eval "_kb_bq=\$_kb_b$_kb_q"
			if [ -n "$_kb_bq" ]; then
				eval "_kb_txt=\$_kb_txt\$_kb_c$_kb_bq"
				[ -n "$_kb_tf" ] || eval "_kb_tf=\$_kb_t$_kb_bq"
				_kb_have=$((_kb_have + 1))
			fi
			_kb_q=$((_kb_q + 1))
		done
		[ -n "$_kb_tf" ] || _kb_tf="$_kb_t"
		_kb_h=$(printf '%s|%s|%s' "$_kb_f" "$_kb_tf" "$_kb_txt" | md5sum)
		_kb_h=${_kb_h%% *}; _kb_h=${_kb_h%????????????????}
		_kb_lead=1
		for _kb_j in $_kb_mem; do
			eval "_kb_k$_kb_j=\"\$_kb_s|\$_kb_tf|\$_kb_h\"; _kb_g$_kb_j=''; _kb_gm$_kb_j=\$_kb_mem"
			if [ "$_kb_lead" = 1 ]; then
				eval "_kb_g$_kb_j=1; _kb_gt$_kb_j=\$_kb_txt; _kb_gh$_kb_j=$_kb_have; _kb_gf$_kb_j=\$_kb_tf"
				_kb_lead=0
			fi
		done
		_kb_i=$((_kb_i + 1))
	done
}

_kb_jq() {
	case "$1" in
		*[\\\"]*|*[[:cntrl:]]*) _nd_jesc "$1" ;;
		*) printf '"%s"' "$1" ;;
	esac
}

_kb_side() {
	_ks_i=1; _ks_any=0
	printf '"keys":['
	while [ "$_ks_i" -le "$_kb_n" ]; do
		eval "_ks_x=\$_kb_x$_ks_i; _ks_k=\$_kb_k$_ks_i; _ks_s=\$_kb_s$_ks_i; _ks_t=\$_kb_t$_ks_i"
		_ks_i=$((_ks_i + 1))
		[ -n "$_ks_k" ] || continue
		case "$_ks_x" in ''|*[!0-9]*) continue ;; esac
		[ "$_ks_any" = 0 ] || printf ','
		_ks_any=1
		printf '{"index":%s,"key":' "$_ks_x"
		_kb_jq "$_ks_k"
		printf ',"old":'
		_kb_jq "$_ks_s|$_ks_t"
		printf '}'
	done
	printf ']'
}

_kb_in_list() {
	case "
$_KB_LIST
" in
		*"
$1
"*) return 0 ;;
	esac
	return 1
}

_kb_list_load() {
	_KB_LIST=""
	[ -f "$1" ] && _KB_LIST=$(tr -d '\r' < "$1" 2>/dev/null)
}

_kb_known() {
	eval "_kk_k=\$_kb_k$1; _kk_g=\$_kb_gm$1"
	_kb_in_list "$_kk_k" && return 0
	[ -n "$_kk_g" ] || _kk_g="$1"
	for _kk_j in $_kk_g; do
		eval "_kk_o=\"\$_kb_s$_kk_j|\$_kb_t$_kk_j\""
		_kb_in_list "$_kk_o" || return 1
	done
	return 0
}

_kb_unseen() {
	_ku_first=0
	[ -f "$1" ] || _ku_first=1
	_kb_list_load "$1"
	printf '{"first":%s,"sms":[' "$_ku_first"
	_ku_i=1; _ku_any=0
	while [ "$_ku_i" -le "$_kb_n" ]; do
		eval "_ku_g=\$_kb_g$_ku_i"
		if [ -n "$_ku_g" ] && ! _kb_known "$_ku_i"; then
			eval "_ku_k=\$_kb_k$_ku_i; _ku_s=\$_kb_s$_ku_i; _ku_t=\$_kb_t$_ku_i; _ku_o=\$_kb_o$_ku_i; _ku_m=\$_kb_gm$_ku_i"
			if [ -n "$_ku_m" ]; then
				eval "_ku_c=\$_kb_gt$_ku_i; _ku_h=\$_kb_gh$_ku_i; _ku_t=\$_kb_gf$_ku_i"
			else
				eval "_ku_c=\$_kb_c$_ku_i"
				_ku_h=1; _ku_o=1
			fi
			_ku_c=$(printf '%s' "$_ku_c" | utf8_fix)
			[ "$_ku_any" = 0 ] || printf ','
			_ku_any=1
			printf '{"sender":%s,"time":%s,"text":%s,"key":%s,"have":%s,"total":%s}' \
				"$(_nd_jesc "$_ku_s")" "$(_nd_jesc "$_ku_t")" "$(_nd_jesc "$_ku_c")" \
				"$(_nd_jesc "$_ku_k")" "$_ku_h" "$_ku_o"
		fi
		_ku_i=$((_ku_i + 1))
	done
	printf ']}\n'
}

_kb_unseen_multi() {
	_um_names=$(printf '%s' "$1" | tr ',' ' ')
	_um_first=""
	# channel names come from argv and end up in eval and in a file name
	for _um_n in $_um_names; do
		case "$_um_n" in *[!a-z]*) return 2 ;; esac
	done
	for _um_n in $_um_names; do
		_um_f=$(_list_file "$_um_n")
		[ -f "$_um_f" ] || _um_first="$_um_first $_um_n"
		_kb_list_load "$_um_f"
		eval "_um_L_$_um_n=\$_KB_LIST"
	done
	printf '{"first":%s,"sms":[' "$(_nd_jesc "${_um_first# }")"
	_ku_i=1; _ku_any=0
	while [ "$_ku_i" -le "$_kb_n" ]; do
		eval "_ku_g=\$_kb_g$_ku_i"
		if [ -n "$_ku_g" ]; then
			_um_miss=""
			for _um_n in $_um_names; do
				eval "_KB_LIST=\$_um_L_$_um_n"
				_kb_known "$_ku_i" || _um_miss="$_um_miss $_um_n"
			done
			if [ -n "$_um_miss" ]; then
				eval "_ku_k=\$_kb_k$_ku_i; _ku_s=\$_kb_s$_ku_i; _ku_t=\$_kb_t$_ku_i; _ku_o=\$_kb_o$_ku_i; _ku_m=\$_kb_gm$_ku_i"
				if [ -n "$_ku_m" ]; then
					eval "_ku_c=\$_kb_gt$_ku_i; _ku_h=\$_kb_gh$_ku_i; _ku_t=\$_kb_gf$_ku_i"
				else
					eval "_ku_c=\$_kb_c$_ku_i"
					_ku_h=1; _ku_o=1
				fi
				_ku_c=$(printf '%s' "$_ku_c" | utf8_fix)
				[ "$_ku_any" = 0 ] || printf ','
				_ku_any=1
				printf '{"sender":%s,"time":%s,"text":%s,"key":%s,"have":%s,"total":%s,"miss":%s}' \
					"$(_nd_jesc "$_ku_s")" "$(_nd_jesc "$_ku_t")" "$(_nd_jesc "$_ku_c")" \
					"$(_nd_jesc "$_ku_k")" "$_ku_h" "$_ku_o" "$(_nd_jesc "${_um_miss# }")"
			fi
		fi
		_ku_i=$((_ku_i + 1))
	done
	printf ']}\n'
}

_kb_unseen_ul() {
	case "$UL" in
		tg) _tg_migrate; _kb_unseen "$(_tg_file)" ;;
		seen|'') _kb_unseen "$(_seen_file)" ;;
		*)
			case ",$UL," in *,tg,*) _tg_migrate ;; esac
			_kb_unseen_multi "$UL" ;;
	esac
}

_kb_out() {
	if [ "$BOX" = unseen ]; then
		[ -n "$1" ] || return 0
		_kb_feed_json "$1"
		_kb_build
		_kb_unseen_ul
		return 0
	fi
	_ko_j="$1"
	while :; do
		case "$_ko_j" in *[[:space:]]) _ko_j=${_ko_j%?} ;; *) break ;; esac
	done
	case "$_ko_j" in
		*'}')
			_kb_feed_json "$1"
			_kb_build
			if [ "$_kb_n" -gt 0 ]; then
				printf '%s,' "${_ko_j%\}}"
				_kb_side
				printf '}\n'
				return 0
			fi ;;
	esac
	[ -n "$1" ] && printf '%s\n' "$1"
	return 0
}

# newcount on a phone costs an adb round trip, and every open detail page asks
# every 15 s: answers are reused for NC_TTL seconds per modem and dropped as
# soon as messages are read, deleted or marked seen through the bridge.
NC_TTL=10
_nc_cache() {
	echo "/tmp/5gmodem/smsnc_$(printf '%s' "$_TGT_PATH" | tr -c 'A-Za-z0-9' '_')"
}
_nc_drop() {
	rm -f "$(_nc_cache)" 2>/dev/null
	return 0
}

# One SIM read per sessionwatch pass. The bot (unseen), SMS commands (recv with SMS_BG=1) and the
# archive (archive-run) used to read the whole SIM one after another every 30 s: three AT+CMGL in a
# row, seconds each on a full SIM, while the metrics poller waited. Background readers now share a
# read for _LIVE_TTL seconds; pages always read live and refresh the shared copy. Every delete drops
# it, so a cached index never points at a slot that was freed and refilled.
_LIVE_TTL=20
_live_file() { echo "/tmp/5gmodem/smslive_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')_$(printf '%s' "${STORE:-cur}" | tr -c 'A-Za-z0-9' '_')"; }
_live_drop() { rm -f "/tmp/5gmodem/smslive_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')_"* 2>/dev/null; return 0; }
_live_bg() {
	case "$BOX" in
		archive-run|unseen) return 0 ;;
		recv) [ "$SMS_BG" = 1 ] ;;
		*) return 1 ;;
	esac
}
_live_fresh() {
	_lf_f=$(_live_file)
	[ -s "$_lf_f" ] || return 1
	_lf_n=$(cut -d. -f1 /proc/uptime 2>/dev/null); _lf_t=""
	read -r _lf_t < "$_lf_f.t" 2>/dev/null
	case "$_lf_n:$_lf_t" in *[!0-9:]*|:*|*:) return 1 ;; esac
	[ $((_lf_n - _lf_t)) -ge 0 ] && [ $((_lf_n - _lf_t)) -lt "$_LIVE_TTL" ]
}
# _LIVE_HIT: the caller found a fresh copy before taking the AT lock and does not hold it, so the
# copy is used even if it aged out in between: a live read without the lock is never right here.
_live_json() {
	_lj_f=$(_live_file)
	if [ -n "$_LIVE_HIT" ] || { _live_bg && _live_fresh; }; then
		cat "$_lj_f"; return 0
	fi
	_lj_j=$(_tz_tag "$(_sms_run 45 $(_smstool) -d "$PORT" -f '%Y-%m-%d %H:%M' -j $_STORE_ARG recv 2>/dev/null | utf8_fix)")
	case "$_lj_j" in
		*'"msg"'*)
			printf '%s' "$_lj_j" > "$_lj_f.$$" 2>/dev/null && mv -f "$_lj_f.$$" "$_lj_f" \
				&& cut -d. -f1 /proc/uptime > "$_lj_f.t" 2>/dev/null ;;
	esac
	printf '%s' "$_lj_j"
}

_arch_live_json() { _live_json; }

case "$1" in
	newdump)
		_nd_active=$(uci -q get "$CFG.@5gmodem[0].active_modem")
		_nd_paths=$("$RES/registry.sh" paths 2>/dev/null)
		[ -n "$_nd_paths" ] || _nd_paths="$_nd_active"
		_nd_store=$(uci -q get "$CFG.sms.storage")
		_nd_now=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$_nd_now" in ''|*[!0-9]*) _nd_now=0 ;; esac
		_nd_out=""; _nd_cnt=0; _nd_lm=""
		for _nd_p in $_nd_paths; do
			_nd_sec="m_$(printf '%s' "$_nd_p" | sed 's/[^A-Za-z0-9]/_/g')"
			if [ "$(uci -q get "$CFG.$_nd_sec.kind")" != "hilink" ]; then
				bg_at_off "$_nd_p" && continue
				[ -n "$_nd_lm" ] || _nd_lm=$("$RES/listmodems.sh" 2>/dev/null)
				printf '%s' "$_nd_lm" | jsonfilter -e "@[@.path=\"$_nd_p\"].tty[0]" -e "@[@.path=\"$_nd_p\"].wdm[0]" 2>/dev/null | grep -q . || continue
			fi
			if [ "$_nd_p" = "$_nd_active" ]; then
				_nd_port=$(uci -q get "$CFG.sms.readport")
			else
				_nd_port=$(uci -q get "$CFG.$_nd_sec.at_port")
			fi
			_nd_recv=$(SMS_MODEM="$_nd_p" "$RES/smsbridge.sh" unseen seen "$_nd_store" "$_nd_port" 2>/dev/null)
			[ -n "$_nd_recv" ] || continue
			_nd_gn=$(printf '%s' "$_nd_recv" | jsonfilter -e '@.sms[*].have' 2>/dev/null | wc -l)
			case "$_nd_gn" in ''|*[!0-9]*) continue ;; esac
			if [ "$(printf '%s' "$_nd_recv" | jsonfilter -e '@.first' 2>/dev/null)" = "1" ]; then
				mkdir -p "$SEEN_DIR" 2>/dev/null
				_nd_g=0
				while [ "$_nd_g" -lt "$_nd_gn" ]; do
					printf '%s\n' "$(printf '%s' "$_nd_recv" | jsonfilter -e "@.sms[$_nd_g].key" 2>/dev/null)"
					_nd_g=$((_nd_g + 1))
				done | sort -u > "$SEEN_DIR/sms_seen.$(printf '%s' "$_nd_p" | sed 's/[^A-Za-z0-9]/_/g')" 2>/dev/null
				continue
			fi
			_nd_g=0
			while [ "$_nd_g" -lt "$_nd_gn" ]; do
				_nd_s=""; _nd_t=""; _nd_c=""; _nd_key=""
				eval "$(printf '%s' "$_nd_recv" | jsonfilter -e "_nd_s=@.sms[$_nd_g].sender" \
					-e "_nd_t=@.sms[$_nd_g].time" -e "_nd_c=@.sms[$_nd_g].text" \
					-e "_nd_key=@.sms[$_nd_g].key" 2>/dev/null)"
				_nd_g=$((_nd_g + 1))
				[ -n "$_nd_key" ] || continue
				[ -n "$_nd_out" ] && _nd_out="$_nd_out,"
				_nd_out="$_nd_out{\"modem\":$(_nd_jesc "$_nd_p"),\"sender\":$(_nd_jesc "$_nd_s"),\"time\":$(_nd_jesc "$_nd_t"),\"text\":$(_nd_jesc "$_nd_c"),\"key\":$(_nd_jesc "$_nd_key")}"
				_nd_cnt=$((_nd_cnt + 1))
			done
		done
		printf '{"count":%s,"ts":%s,"sms":[%s]}\n' "$_nd_cnt" "$_nd_now" "$_nd_out"
		exit 0 ;;
	newcount)
		if _active_is_android; then
			_nc_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
			case "$_nc_now" in ''|*[!0-9]*) _nc_now=0 ;; esac
			_ncc_n=""; _ncc_t=""
			[ -f "$(_nc_cache)" ] && read -r _ncc_n _ncc_t < "$(_nc_cache)"
			case "$_ncc_n:$_ncc_t" in :*|*:|*[!0-9:]*) ;; *)
				if [ "$_nc_now" -gt 0 ] && [ "$_ncc_t" -le "$_nc_now" ] && [ $((_nc_now - _ncc_t)) -lt "$NC_TTL" ]; then
					echo "$_ncc_n"; exit 0
				fi ;;
			esac
			. "$RES/android.sh"
			_anc=$(android_sms "$_TGT_PATH" count | jsonfilter -e '@.unseen' 2>/dev/null)
			case "$_anc" in ''|*[!0-9]*) _anc=0 ;; esac
			mkdir -p /tmp/5gmodem 2>/dev/null
			printf '%s %s\n' "$_anc" "$_nc_now" > "$(_nc_cache).$$" 2>/dev/null \
				&& mv "$(_nc_cache).$$" "$(_nc_cache)" 2>/dev/null
			echo "$_anc"; exit 0
		fi
		# AT/HiLink/MM: only reads the sms_new.json snapshot written by newdump, no
		# port access, so there is nothing worth caching here.
		_ncf="/tmp/5gmodem/sms_new.json"
		_nc_for=""
		for _nc_a in "$@"; do case "$_nc_a" in for=*) _nc_for="${_nc_a#for=}" ;; esac; done
		[ -f "$_ncf" ] || { echo 0; exit 0; }
		_nc_j=$(cat "$_ncf" 2>/dev/null)
		_nc_one() {
			_nco_sf="$SEEN_DIR/sms_seen.$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"
			printf '%s' "$_nc_j" | jsonfilter -e "@.sms[@.modem=\"$1\"].key" 2>/dev/null \
				| awk -v sf="$_nco_sf" '
					BEGIN { while ((getline l < sf) > 0) { sub(/\r$/, "", l); if (l != "") seen[l] = 1 } }
					$0 != "" && !($0 in seen) { k = $0; sub(/\|[^|]*$/, "", k); if (!(k in seen)) c++ }
					END { print c + 0 }'
		}
		if [ -n "$_nc_for" ]; then
			_nc_n=$(_nc_one "$_nc_for")
		else
			_nc_n=0
			for _nc_m in $(printf '%s' "$_nc_j" | jsonfilter -e '@.sms[*].modem' 2>/dev/null | sort -u); do
				_nc_n=$((_nc_n + $(_nc_one "$_nc_m")))
			done
		fi
		case "$_nc_n" in ''|*[!0-9]*) _nc_n=0 ;; esac
		echo "$_nc_n"
		exit 0 ;;
	seen)
		_sf=$(_seen_file)
		if [ ! -f "$_sf" ]; then
			echo '{"first":1,"keys":[]}'
			exit 0
		fi
		printf '{"first":0,"keys":['
		tr -d '\r' < "$_sf" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '
			BEGIN { ORS = "" }
			$0 != "" { if (n++) printf ","; printf "\"%s\"", $0 }'
		printf ']}\n'
		exit 0 ;;
	seen-add)
		shift
		_nc_drop
		[ -n "$1" ] || { echo '{"success":true}'; exit 0; }
		_list_add "$(_seen_file)" "$@"
		echo '{"success":true}'
		exit 0 ;;
	markread)
		shift
		_nc_drop
		if [ "$(_active_kind)" = "hilink" ] && [ -n "$1" ]; then
			"$RES/hilink.sh" smsmarkread "$*" "$_TGT_PATH"
		else
			echo '{"success":true}'
		fi
		exit 0 ;;
	tg-add)
		shift
		_tg_migrate
		_list_add "$(_tg_file)" "$@"
		echo '{"success":true}'
		exit 0 ;;
	fwdhead)
		sms_fwd_head "$_TGT_PATH" "$2"
		echo
		exit 0 ;;
	list-add)
		_la_n="$2"; shift 2
		case "$_la_n" in *[!a-z]*) echo '{"success":false}'; exit 2 ;; esac
		[ "$_la_n" = tg ] && _tg_migrate
		_list_add "$(_list_file "$_la_n")" "$@"
		echo '{"success":true}'
		exit 0 ;;
	seen-reset)
		_nc_drop
		rm -f "$(_seen_file)" 2>/dev/null
		echo '{"success":true}'
		exit 0 ;;
esac

_PORT_OWNER=""
_port_is_mm() {
	[ -n "$1" ] || return 1
	[ -n "$_PORT_OWNER" ] || _PORT_OWNER=$(printf '%s' "$("$RES/registry.sh" port "$1" 2>/dev/null)" \
		| jsonfilter -e '@.owner' 2>/dev/null)
	[ "$_PORT_OWNER" = "mm" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	mmcli -L 2>/dev/null | grep -q "/Modem/"
}

_send_one() {
	_so_port="$1"; _so_to="$2"; _so_txt="$3"
	if [ "$4" = slow ]; then _so_tmm=60; _so_tat=45; else _so_tmm=20; _so_tat=15; fi
	_so_mm=""; _so_mmp=""
	if _port_is_mm "$_so_port"; then
		_so_mm=1
	elif _port_proxy_mm "$_so_port"; then
		_so_mm=1; _so_mmp="$_ppm_p"
	fi
	if [ -n "$_so_mm" ] && [ -x "$RES/sms_tool_mm" ]; then
		if [ -n "$_so_mmp" ]; then
			MM_MODEM_PATH="$_so_mmp" _sms_run "$_so_tmm" "$RES/sms_tool_mm" -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null && return 0
		elif _sms_run "$_so_tmm" "$RES/sms_tool_mm" -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null; then
			return 0
		fi
		logger -t 5gmodem "smsbridge: MM send failed within ${_so_tmm}s, trying the AT port"
		if "$RES/smspdu.sh" needucs2 "$_so_txt"; then
			_send_pdu "$_so_port" "$_so_to" "$_so_txt" 2>/dev/null
			return $?
		fi
		_sms_run "$_so_tat" $(_smstool_at) -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null
		return $?
	fi
	_send_pdu "$_so_port" "$_so_to" "$_so_txt" 2>/dev/null
	_so_pdurc=$?
	[ "$_so_pdurc" = 0 ] && return 0
	_sms_tdtech "$_so_port" && return "$_so_pdurc"
	if ! "$RES/smspdu.sh" needucs2 "$_so_txt"; then
		_sms_run "$_so_tat" $(_smstool_at) -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null
		return $?
	fi
	return "$_so_pdurc"
}

_smstool_at() {
	command -v sms_tool >/dev/null 2>&1 && echo /usr/bin/sms_tool || echo sms_tool
}

_sms_tdtech() {
	local path
	path=$(tty_usbpath "$1" 2>/dev/null)
	[ -n "$path" ] || return 1
	[ "$(cat "/sys/bus/usb/devices/$path/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$path/idProduct" 2>/dev/null)" = 3466:3301 ]
}

_td_sms_submit() {
	local response
	response=$(_sms_run 10 $(_smstool_at) -d "$1" at 'AT+CMGF=0' 2>/dev/null)
	printf '%s\n' "$response" | tr -d '\r' | grep -q '^OK$' || return 1
	response=$(_sms_run 60 $(_smstool_at) -d "$1" at "AT+CMGS=$2\r$3" 2>/dev/null)
	if printf '%s\n' "$response" | tr -d '\r' | grep -qE '^\+CMGS: *[0-9]+'; then
		return 0
	fi
	printf '\033' > "$1" 2>/dev/null
	printf '%s\n' "$response"
	printf '%s\n' "$response" | grep -q 'ERROR' && return 1
	return 4
}

_norm_num() {
	_nn=$(printf '%s' "$1" | tr -cd '0-9+')
	case "$_nn" in
		+*) printf '%s' "$_nn"; return ;;
		00*) _nt="${_nn#00}"
		     [ "${#_nt}" -ge 9 ] && { printf '+%s' "$_nt"; return; }
		     printf '%s' "$_nn"; return ;;
	esac
	case "$_nn" in
		[1-79]*) [ "${#_nn}" -ge 11 ] && { printf '+%s' "$_nn"; return; } ;;
	esac
	printf '%s' "$_nn"
}

SMSQ_DIR=/etc/5gmodem/smsq
SMSQ_MAX_TRIES=10
SMSQ_MAX_AGE=86400

_q_enqueue() {
	mkdir -p "$SMSQ_DIR" 2>/dev/null || return 1
	_qe_f="$SMSQ_DIR/$(date +%s 2>/dev/null).$$"
	{
		printf 'to=%s\n' "$1"
		printf 'port=%s\n' "$3"
		printf 'tries=0\n'
		printf 'born=%s\n' "$(date +%s 2>/dev/null)"
		printf 'text:\n'
		printf '%s' "$2"
	} > "$_qe_f.tmp" 2>/dev/null && mv "$_qe_f.tmp" "$_qe_f.sms" 2>/dev/null
}

_q_send_one() {
	_qs_f="$1"
	_qs_to=""; _qs_port=""; _qs_tries=0; _qs_born=0; _qs_txt=""; _qs_inbody=0
	while IFS= read -r _qs_l || [ -n "$_qs_l" ]; do
		if [ "$_qs_inbody" = 1 ]; then
			_qs_txt="${_qs_txt:+$_qs_txt
}$_qs_l"
			continue
		fi
		case "$_qs_l" in
			to=*)    _qs_to="${_qs_l#to=}" ;;
			port=*)  _qs_port="${_qs_l#port=}" ;;
			tries=*) _qs_tries="${_qs_l#tries=}" ;;
			born=*)  _qs_born="${_qs_l#born=}" ;;
			text:)   _qs_inbody=1 ;;
		esac
	done < "$_qs_f"
	case "$_qs_tries" in ''|*[!0-9]*) _qs_tries=0 ;; esac
	case "$_qs_born" in ''|*[!0-9]*) _qs_born=0 ;; esac
	if [ -z "$_qs_to" ] || [ -z "$_qs_txt" ]; then
		logger -t 5gmodem "smsbridge: corrupt queue entry $_qs_f (no number or text) - deleting"
		rm -f "$_qs_f"
		return 2
	fi

	_qs_now=$(date +%s 2>/dev/null); case "$_qs_now" in ''|*[!0-9]*) _qs_now=0 ;; esac
	if [ "$_qs_tries" -ge "$SMSQ_MAX_TRIES" ] \
	   || { [ "$_qs_born" -gt 0 ] && [ "$_qs_now" -gt 0 ] && [ $((_qs_now - _qs_born)) -gt "$SMSQ_MAX_AGE" ]; }; then
		logger -t 5gmodem "smsbridge: message for \"$_qs_to\" never went out after $_qs_tries attempts - dropping it from the queue"
		rm -f "$_qs_f"
		return 2
	fi

	_qs_to=$(_norm_num "$_qs_to")
	[ -n "$_qs_port" ] || _qs_port=$(uci -q get "$CFG.sms.sendport")
	[ -n "$_qs_port" ] && [ -c "$_qs_port" ] || return 1

	_send_one "$_qs_port" "$_qs_to" "$_qs_txt" slow
	_qs_rc=$?
	if [ "$_qs_rc" = 4 ]; then
		mv "$_qs_f" "${_qs_f%.sms}.unknown"
		logger -t 5gmodem "smsbridge: queued SMS result is unknown; automatic retries stopped, saved as ${_qs_f%.sms}.unknown"
		return 4
	fi

	if [ "$_qs_rc" != 0 ] && [ "$(uci -q get "$CFG.sms.send_inhibit_mm")" = "1" ] \
	   && _port_is_mm "$_qs_port" && command -v mmcli >/dev/null 2>&1; then
		_qs_uid=$(mmcli -L 2>/dev/null | sed -n "s|.*/Modem/\([0-9]*\).*|\1|p" | head -1)
		[ -n "$_qs_uid" ] && _qs_uid=$(mmcli -m "$_qs_uid" 2>/dev/null \
			| sed -n "s|.*device: *||p" | head -1 | tr -d " '")
		if [ -n "$_qs_uid" ]; then
			logger -t 5gmodem "smsbridge: last attempt - borrowing the modem from ModemManager for the send"
			( mmcli --inhibit-device="$_qs_uid" >/dev/null 2>&1 & echo $! > /tmp/5gmodem/sms_inhibit.pid ) 
			_qs_w=0
			while [ "$_qs_w" -lt 15 ]; do
				mmcli -L 2>/dev/null | grep -q "/Modem/" || break
				sleep 1; _qs_w=$((_qs_w + 1))
			done
			_send_one "$_qs_port" "$_qs_to" "$_qs_txt" slow
			_qs_rc=$?
			kill "$(cat /tmp/5gmodem/sms_inhibit.pid 2>/dev/null)" 2>/dev/null
			rm -f /tmp/5gmodem/sms_inhibit.pid
			logger -t 5gmodem "smsbridge: modem returned to ModemManager (send $([ "$_qs_rc" = 0 ] && echo succeeded || echo failed))"
		fi
	fi
	( exit "$_qs_rc" )
	if [ $? = 0 ]; then
		rm -f "$_qs_f"
		logger -t 5gmodem "smsbridge: queued message for \"$_qs_to\" sent (attempt $((_qs_tries + 1)))"
		return 0
	fi
	sed -i "s/^tries=.*/tries=$((_qs_tries + 1))/" "$_qs_f" 2>/dev/null
	return 1
}

_send_pdu() {
	_sp_port="$1"
	[ -n "$_sp_port" ] && [ -c "$_sp_port" ] || { echo "no port" >&2; return 2; }

	if _port_is_mm "$_sp_port"; then
		_SP_LASTERR="the port is owned by ModemManager: Cyrillic over AT is unavailable"
		logger -t 5gmodem "smsbridge: $_sp_port is under ModemManager - PDU path skipped"
		return 3
	fi
	at_lock "$_sp_port" 15 || return 1
	_sp_cmd="${SMS_PDU_CMD:-CMGS}"
	_sp_parts=$("$RES/smspdu.sh" encode "$2" "$3" 2>/dev/null)
	[ -n "$_sp_parts" ] || { echo "pdu encode failed" >&2; return 1; }
	_sp_rc=0
	_sp_sent=0
	while read -r _sp_len _sp_pdu; do
		[ -n "$_sp_pdu" ] || continue
		[ "$_sp_rc" = 0 ] || break
		if [ "$_sp_cmd" = CMGS ] && _sms_tdtech "$_sp_port"; then
			_td_sms_submit "$_sp_port" "$_sp_len" "$_sp_pdu"
			_sp_rc=$?
			if [ "$_sp_rc" = 0 ]; then
				_sp_sent=$((_sp_sent + 1))
			elif [ "$_sp_sent" -gt 0 ]; then
				_sp_rc=4
			fi
			continue
		fi
		stty -F "$_sp_port" 115200 raw -echo 2>/dev/null
		_sp_ans=""
		if command exec 3<>"$_sp_port" 2>/dev/null; then
			printf 'AT+CMGF=0\r' >&3
			sleep 1
			printf 'AT+%s=%s\r' "$_sp_cmd" "$_sp_len" >&3
			sleep 2
			printf '%s\032' "$_sp_pdu" >&3
			while read -t 25 -r _sp_l <&3; do
				_sp_l=$(printf '%s' "$_sp_l" | tr -d '\r')
				[ -n "$_sp_l" ] || continue
				_sp_ans="$_sp_l"
				case "$_sp_l" in
					"+$_sp_cmd:"*) _sp_ans="OK:$_sp_l"; break ;;
					*"+CMS ERROR"*|*"+CME ERROR"*|ERROR) break ;;
				esac
			done
			exec 3>&-
		fi
		case "$_sp_ans" in
			OK:*) ;;
			*) _sp_rc=1
			   # see docs/subsystems/sms.md#pdu-send-dialog
			   printf '\033' > "$_sp_port" 2>/dev/null
			   _sp_ceer=$(_sms_run 8 $(_smstool) -d "$_sp_port" at "AT+CEER" 2>/dev/null \
				| tr -d '\r' | grep -iE "CEER|ERROR" | head -1)
			   logger -t 5gmodem "smsbridge: a PDU part did not go out ($_sp_cmd, number \"$2\", len=$_sp_len): ${_sp_ans:-no answer}${_sp_ceer:+ | $_sp_ceer}"
			   _SP_LASTERR="${_sp_ans:-no answer from modem}" ;;
		esac
	done <<PARTS_EOF
$_sp_parts
PARTS_EOF
	if [ "$_sp_rc" = 0 ]; then
		return 0
	fi
	[ "$_sp_rc" = 4 ] && return 4
	echo "sms sending failed: ${_SP_LASTERR:-no answer from modem}" >&2
	return 1
}

BOX="${1:-recv}"
case "$BOX" in
	delete|delete-start|delete-run) DEL="$2"; STORE="$3"; PORT="$4" ;;
	send)   SND_TO="$2"; SND_TXT="$3"; PORT="$4" ;;
	queue-run|queue-list) PORT="${2:-$(uci -q get "$CFG.sms.sendport")}" ;;
	unseen) UL="$2"; STORE="$3"; PORT="$4" ;;
	*)      STORE="$2"; PORT="$3" ;;
esac
# archive-run comes from sessionwatch without arguments. The bot and SMS commands read the configured
# storage (default SM), so the archive does too: same storage, one shared read (_live_json).
[ "$BOX" = archive-run ] && [ -z "$STORE" ] && { STORE=$(uci -q get "$CFG.sms.storage"); [ -n "$STORE" ] || STORE=SM; }

case "$BOX" in delete|delete-start|delete-run) _nc_drop; _live_drop ;; esac

if _active_is_android; then
	. "$RES/android.sh"
	case "$BOX" in
		status)
			_as_count=$(android_sms "$_TGT_PATH" count)
			_as_used=$(printf '%s' "$_as_count" | jsonfilter -e '@.used' 2>/dev/null)
			case "$_as_used" in ''|*[!0-9]*) printf '%s\n' "$_as_count"; exit 1 ;; esac
			printf 'Storage type: ME, used: %s, read-only: 1\n' "$_as_used" ;;
		recv|dump) android_sms "$_TGT_PATH" inbox ;;
		sent) android_sms "$_TGT_PATH" sent ;;
		unseen|archive-run|archive-why) echo '{"read_only":true,"msg":[]}' ;;
		delete-status) echo '{"state":"none","read_only":true}' ;;
		*) echo '{"error":"Android SMS is read-only","read_only":true}'; exit 1 ;;
	esac
	exit $?
fi

_DJ_FILE="/tmp/5gmodem/smsdel_$(printf '%s' "$_TGT_PATH" | tr -c 'A-Za-z0-9' '_').json"
_DJ_OK=""; _DJ_FAIL=""; _DJ_DONE=0; _DJ_TOTAL=0

_dj_pid() {
	sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$_DJ_FILE" 2>/dev/null | head -1
}

_dj_running() {
	case "$(cat "$_DJ_FILE" 2>/dev/null)" in *'"state":"running"'*) ;; *) return 1 ;; esac
	_djr_p=$(_dj_pid)
	[ -n "$_djr_p" ] && kill -0 "$_djr_p" 2>/dev/null
}

_dj_write() {
	printf '{"pid":%s,"state":"%s","total":%s,"done":%s,"ok":[%s],"fail":[%s]}\n' \
		"${2:-$$}" "$1" "$_DJ_TOTAL" "$_DJ_DONE" "$_DJ_OK" "$_DJ_FAIL" > "$_DJ_FILE.tmp" 2>/dev/null \
		&& mv "$_DJ_FILE.tmp" "$_DJ_FILE" 2>/dev/null
}

_dj_ok() {
	_DJ_OK="${_DJ_OK}${_DJ_OK:+,}$1"
	_DJ_DONE=$((_DJ_DONE + 1))
}

_dj_fail() {
	_DJ_FAIL="${_DJ_FAIL}${_DJ_FAIL:+,}{\"index\":$1,\"why\":\"$2\",\"arg\":\"$3\"}"
	_DJ_DONE=$((_DJ_DONE + 1))
}

_dj_count() {
	_djc_n=0
	for _djc_i in $(printf '%s' "$1" | tr ',' ' '); do _djc_n=$((_djc_n + 1)); done
	echo "$_djc_n"
}

case "$BOX" in
	delete-status)
		if [ -s "$_DJ_FILE" ]; then
			if _dj_running; then cat "$_DJ_FILE"
			else sed 's/"state":"running"/"state":"dead"/' "$_DJ_FILE"
			fi
		else
			echo '{"state":"none"}'
		fi
		exit 0 ;;
	delete-start)
		case "$DEL" in ''|*[!0-9,]*|,*|*,|*,,*) echo '{"state":"bad"}'; exit 2 ;; esac
		if _dj_running; then echo '{"state":"busy"}'; exit 0; fi
		_DJ_TOTAL=$(_dj_count "$DEL")
		( SMS_MODEM="$_TGT_PATH" exec "$0" delete-run "$DEL" "$STORE" "$PORT" ) >/dev/null 2>&1 </dev/null &
		_dj_write running "$!"
		printf '{"state":"running","pid":%s,"total":%s}\n' "$!" "$_DJ_TOTAL"
		sleep 1
		exit 0 ;;
	delete-run)
		case "$DEL" in ''|*[!0-9,]*) exit 2 ;; esac
		_DJ_TOTAL=$(_dj_count "$DEL")
		_dj_write running ;;
esac

if [ -z "$PORT" ]; then
	case "$BOX" in
		send|queue-run|queue-list) PORT=$(uci -q get "$CFG.sms.sendport") ;;
		*) PORT=$(uci -q get "$CFG.sms.readport") ;;
	esac
fi
if hl_sms_web "$_TGT_SEC" "$PORT"; then
	case "$BOX" in
		sent) "$RES/hilink.sh" smsread out "$_TGT_PATH" ;;
		status)
			_c=$("$RES/hilink.sh" smscount "$_TGT_PATH" 2>/dev/null | tr -d '\r')
			_u=$(printf '%s' "$_c" | sed -n 's|.*<LocalInbox>\(.*\)</LocalInbox>.*|\1|p')
			_m=$(printf '%s' "$_c" | sed -n 's|.*<LocalMaxInbox>\(.*\)</LocalMaxInbox>.*|\1|p')
			[ -n "$_u" ] || _u=0
			[ -n "$_m" ] || _m=100
			echo "Storage type: ME, used: $_u, total: $_m"
			;;
		delete)
			if [ "$DEL" = all ]; then
				"$RES/hilink.sh" smsread in "$_TGT_PATH" 2>/dev/null \
					| jsonfilter -e '@.msg[*].index' 2>/dev/null \
					| while read -r _i; do
						[ -n "$_i" ] && "$RES/hilink.sh" smsdel "$_i" "$_TGT_PATH" >/dev/null 2>&1
					done
				echo '{"success":true}'
			else
				"$RES/hilink.sh" smsdel "$DEL" "$_TGT_PATH"
			fi ;;
		delete-run)
			for _dr_i in $(printf '%s' "$DEL" | tr ',' ' '); do
				_dr_o=$("$RES/hilink.sh" smsdel "$_dr_i" "$_TGT_PATH" 2>/dev/null)
				case "$_dr_o" in
					*'"success":true'*) _dj_ok "$_dr_i" ;;
					*) _dj_fail "$_dr_i" refused "$(printf '%s' "$_dr_o" | sed -n 's/.*"code":"\([0-9A-Za-z_-]*\)".*/\1/p')" ;;
				esac
				_dj_write running
			done
			_dj_write done ;;
		send)   "$RES/hilink.sh" smssend "$SND_TO" "$SND_TXT" "$_TGT_PATH" ;;
		*)    _kb_out "$("$RES/hilink.sh" smsread in "$_TGT_PATH")" ;;
	esac
	exit 0
fi

[ -n "$PORT" ] || PORT=$(uci -q get 5gmodem.sms.readport)
[ -n "$PORT" ] || PORT=$("$RES/detect.sh" 2>/dev/null)
[ -n "$PORT" ] || [ "$BOX" = delete-run ] || { echo "[]"; exit 0; }

if [ "$BOX" = "queue-run" ]; then
	_qr_any=0
	for _qr_f in "$SMSQ_DIR"/*.sms; do
		[ -f "$_qr_f" ] && { _qr_any=1; break; }
	done
	[ "$_qr_any" = 1 ] || exit 0
fi

. "$RES/atlock.sh"
_AT_INH="$_AT_LOCK_HELD"
# A background reader with a fresh shared read needs neither the port nor the lock, nor the
# AT+CPMS? that picking the storage costs: it only reads the copy (_live_json).
_LIVE_HIT=""
case "$BOX" in recv|unseen|archive-run) _live_bg && _live_fresh && _LIVE_HIT=1 ;; esac
if [ "$BOX" = delete-run ]; then _AT_LOCKED=1
elif [ -n "$_LIVE_HIT" ]; then _AT_LOCKED=0
elif ! _via_mm && at_long_busy "$PORT"; then _AT_LOCKED=1
else at_lock "$PORT" 15; _AT_LOCKED=$?; fi

_ST_CACHE="/tmp/5gmodem/smsstatus_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
if [ "$BOX" = status ] && [ "$_AT_LOCKED" != 0 ] && ! _via_mm; then
	cat "$_ST_CACHE" 2>/dev/null
	exit 0
fi

# Reading past a held lock is kept for the pages only. Background readers
# (archive-run, unseen for the bot, recv with SMS_BG=1 from smscmd) retry next
# round instead: a read mixed with the poller's answers would be archived with
# the wrong text, and the purge would then delete the real message from the slot.
_BG_SKIP=""
if [ "$_AT_LOCKED" != 0 ] && ! _via_mm; then
	case "$BOX" in
		archive-run|unseen) _BG_SKIP=1 ;;
		recv) [ "$SMS_BG" = 1 ] && _BG_SKIP=1 ;;
	esac
fi

_sms_run() {
	_sr_t="$1"; shift
	if [ "$_AT_LOCK_HELD" != "$(basename "$PORT")" ] && command -v at_long_busy >/dev/null 2>&1 \
	   && ! _via_mm && at_long_busy "$PORT"; then
		return 1
	fi
	_sr_o=$(mktemp /tmp/5gmodem-smsrun.XXXXXX) || return 1
	"$@" > "$_sr_o" 2>/dev/null </dev/null 7>&- 8>&- 9>&- &
	_sr_p=$!
	( exec >/dev/null 2>&1 7>&- 8>&- 9>&-; sleep "$_sr_t" & _ws=$!; trap 'kill $_ws 2>/dev/null; exit' TERM; wait $_ws; kill "$_sr_p" 2>/dev/null ) </dev/null & _sr_w=$!
	if (sleep 0.0) 2>/dev/null; then _sr_step=0.1; _sr_max=$(( (_sr_t + 1) * 10 ));
	else _sr_step=1; _sr_max=$((_sr_t + 1)); fi
	_sr_i=0
	while kill -0 "$_sr_p" 2>/dev/null && [ "$_sr_i" -lt "$_sr_max" ]; do
		_sr_i=$((_sr_i + 1)); sleep "$_sr_step"
	done
	if kill -0 "$_sr_p" 2>/dev/null; then
		kill -9 "$_sr_p" 2>/dev/null
		_sr_rc=124
		command -v _at_recover >/dev/null 2>&1 && _at_recover "$PORT"
	else
		wait "$_sr_p" 2>/dev/null; _sr_rc=$?
	fi
	kill "$_sr_w" 2>/dev/null; wait "$_sr_w" 2>/dev/null
	cat "$_sr_o"
	rm -f "$_sr_o"
	return $_sr_rc
}

ARCH_MAX=$(uci -q get "$CFG.sms.archive_limit")
case "$ARCH_MAX" in ''|*[!0-9]*) ARCH_MAX=500 ;; esac
[ "$ARCH_MAX" -ge 10 ] 2>/dev/null || ARCH_MAX=10
[ "$ARCH_MAX" -le 2000 ] 2>/dev/null || ARCH_MAX=2000
ARCH_BASE=100000
_LIVE_MAP=" "

_ARCH_ON=""
_arch_on() {
	if [ -z "$_ARCH_ON" ]; then
		if _via_mm; then _ARCH_ON=1
		elif [ "$(uci -q get "$CFG.sms.archive")" = "1" ]; then _ARCH_ON=1
		else _ARCH_ON=0
		fi
	fi
	[ "$_ARCH_ON" = 1 ]
}

# The archive is one file per modem, $(_arch_dir).db. Each message is one record:
#   @<index>|<key>|<added, epoch s>|<part/total/ref or empty>|<tz or empty>
#   T<timestamp>
#   F<sender>
#    <text line>     (each text line behind one space, so any text reads back as it was)
# One file instead of a file per message: on ubifs every small file costs a 4 KB block, so
# 500 messages took ~2 MB; as one file they take ~80 KB, and ubifs compresses that too.
# New records are appended; deletes and the trim rewrite the file (tmp + mv). Writers take
# flock on fd 4. _arch_dir itself is the old one-file-per-message directory, migrated once.
_arch_dir() {
	_ad=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_ad" ] && echo "$SEEN_DIR/sms_arch.$_ad" || echo "$SEEN_DIR/sms_arch"
}

_arch_file() { echo "$(_arch_dir).db"; }

_arch_lock() {
	mkdir -p /tmp/5gmodem 2>/dev/null
	_alk=$(_arch_dir); _alk="/tmp/5gmodem/archlock_${_alk##*/}"
	exec 4>"$_alk" 2>/dev/null || return 0
	flock 4 2>/dev/null
	return 0
}

_arch_unlock() {
	flock -u 4 2>/dev/null
	exec 4>&- 2>/dev/null
	return 0
}

# One record from the _A_* fields; $1 index, $2 key, $3 added (epoch seconds).
_arch_rec() {
	_arp=""
	case "$_A_TOTAL" in ''|*[!0-9]*) ;; *) _arp="${_A_PART:-1}/$_A_TOTAL/${_A_REF:-0}" ;; esac
	printf '@%s|%s|%s|%s|%s\nT%s\nF%s\n' "$1" "$2" "${3:-0}" "$_arp" "$_A_TZ" "$_A_TS" "$_A_FROM"
	[ -z "$_A_TEXT" ] || printf '%s\n' "$_A_TEXT" | sed 's/^/ /'
}

# Old layout (a directory, one file per message) -> one file. Indexes, keys and the time each
# message was stored are kept, so seen lists, forwarding marks and the purge deadline carry over.
_arch_ready() {
	_ard=$(_arch_dir)
	[ -d "$_ard" ] || return 0
	_arch_lock
	if [ -d "$_ard" ]; then
		_arf=$(_arch_file)
		if : > "$_arf.mig" 2>/dev/null; then
			_arok=1
			for _arn in $(_arch_files "$_ard"); do
				[ -f "$_ard/$_arn" ] || continue
				case "${_arn%%.*}" in ''|*[!0-9]*) continue ;; esac
				_arch_read "$_ard/$_arn"
				_arch_rec "${_arn%%.*}" "${_arn#*.}" "$(date -r "$_ard/$_arn" +%s 2>/dev/null)" \
					>> "$_arf.mig" || { _arok=""; break; }
			done
			[ -s "$_arf" ] && cat "$_arf" >> "$_arf.mig"
			if [ -n "$_arok" ] && mv -f "$_arf.mig" "$_arf"; then
				rm -rf "$_ard"
				logger -t 5gmodem "sms: router archive moved into one file, $_arf"
			fi
			rm -f "$_arf.mig" 2>/dev/null
		fi
	fi
	_arch_unlock
	[ ! -d "$_ard" ]
}

# Calls $1 for every record, with _A_IDX0, _A_KEY, _A_ADD, _A_TS, _A_FROM, _A_TEXT, _A_PART,
# _A_TOTAL, _A_REF and _A_TZ set. A record cut short (power lost mid-append) has no F line: skipped.
_arch_each() {
	_aecb="$1"; _aef=$(_arch_file)
	[ -s "$_aef" ] || return 0
	_ae_ok=""
	while IFS= read -r _ael || [ -n "$_ael" ]; do
		case "$_ael" in
			'@'*)
				[ -n "$_ae_ok" ] && "$_aecb"
				_aeh=${_ael#@}
				_A_IDX0=${_aeh%%|*}; _aeh=${_aeh#*|}
				_A_KEY=${_aeh%%|*}; _aeh=${_aeh#*|}
				_A_ADD=${_aeh%%|*}; _aeh=${_aeh#*|}
				_aep=${_aeh%%|*}; _A_TZ=${_aeh#*|}
				_A_PART=""; _A_TOTAL=""; _A_REF=""
				case "$_aep" in
					*/*/*) _A_PART=${_aep%%/*}; _aep=${_aep#*/}; _A_TOTAL=${_aep%%/*}; _A_REF=${_aep#*/} ;;
				esac
				_A_TS=""; _A_FROM=""; _A_TEXT=""; _ae_nt=0; _ae_ok="" ;;
			T*) _A_TS=${_ael#T} ;;
			F*) _A_FROM=${_ael#F}; _ae_ok=1 ;;
			' '*)
				if [ "$_ae_nt" = 0 ]; then _A_TEXT=${_ael# }; _ae_nt=1
				else _A_TEXT="$_A_TEXT
${_ael# }"
				fi ;;
		esac
	done < "$_aef"
	[ -n "$_ae_ok" ] && "$_aecb"
	return 0
}

# Rewrites the file without the records the awk program drops (pass "skip" = 1 on their @ line
# and print with "!skip"). The caller holds the lock.
_arch_drop() {
	_adf=$(_arch_file)
	[ -f "$_adf" ] || return 0
	awk -F'|' "$@" "$_adf" > "$_adf.tmp" 2>/dev/null && mv -f "$_adf.tmp" "$_adf"
	rm -f "$_adf.tmp" 2>/dev/null
	return 0
}

_nl_trim() {
	eval "_ntr_v=\$$1"
	while :; do
		case "$_ntr_v" in
			*"
") _ntr_v=${_ntr_v%?} ;;
			*) break ;;
		esac
	done
	eval "$1=\$_ntr_v"
}

_arch_key() {
	printf '%s|%s|%s' "$1" "$2" "$3" | md5sum | cut -c1-16
}

_arch_next() {
	[ -s "$1" ] || { echo "$ARCH_BASE"; return 0; }
	awk -F'|' -v b="$ARCH_BASE" '/^@/ { i = substr($1, 2) + 0; if (i >= b) b = i + 1 } END { print b }' "$1"
}

_arch_files() {
	ls "$1" 2>/dev/null | sort -t. -k1,1n
}

_arch_read() {
	_A_TS=""; _A_FROM=""; _A_TEXT=""; _A_PART=""; _A_TOTAL=""; _A_REF=""; _A_TZ=""
	{
		IFS= read -r _A_TS
		while :; do
			case "$_A_TS" in
				'#p='*)
					_arh=${_A_TS#\#p=}
					_A_PART=${_arh%%/*}; _arh=${_arh#*/}
					_A_TOTAL=${_arh%%/*}; _A_REF=${_arh#*/}
					IFS= read -r _A_TS ;;
				'#tz='*)
					_A_TZ=${_A_TS#\#tz=}
					IFS= read -r _A_TS ;;
				*) break ;;
			esac
		done
		IFS= read -r _A_FROM
		_A_FROM=$(printf '%s' "$_A_FROM" | tr -d '\r')
		while IFS= read -r _arl || [ -n "$_arl" ]; do
			_A_TEXT="${_A_TEXT:+$_A_TEXT
}$_arl"
		done
	} < "$1"
}

_arch_trim() {
	_atn=$(grep -c '^@' "$1" 2>/dev/null)
	case "$_atn" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_atn" -gt "$ARCH_MAX" ] || return 0
	# records are appended in index order, so the oldest are the first ones
	_arch_drop -v d="$((_atn - ARCH_MAX))" '/^@/ { r++ } r > d'
}

_arch_merge() {
	_arch_ready || return 0
	mkdir -p "$SEEN_DIR" 2>/dev/null || return 0
	_amd=$(_arch_file)
	_amj="$1"
	_LIVE_MAP=" "
	_AM_SEEN=" "
	[ -n "$_amj" ] || return 0
	_amst=$(_arch_dir); _amst="/tmp/5gmodem/archmerge_${_amst##*/}"
	_amsig=$( { printf '%s' "$_amj"; cat "$_amd" 2>/dev/null; } | md5sum | cut -c1-32)
	if [ "$(sed -n 1p "$_amst" 2>/dev/null)" = "$_amsig" ]; then
		_LIVE_MAP=$(sed -n 2p "$_amst")
		[ -n "$_LIVE_MAP" ] || _LIVE_MAP=" "
		return 0
	fi
	_amn=$(printf '%s' "$_amj" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_amn" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_amn" -gt 0 ] || return 0
	_arch_lock
	_amnext=$(_arch_next "$_amd")
	_amnow=$(date +%s 2>/dev/null)
	_ami=0
	while [ "$_ami" -lt "$_amn" ]; do
		_amx=""; _ams=""; _amt=""; _amc=""; _ampt=""; _amtt=""; _amrf=""; _amtz=""
		eval "$(printf '%s' "$_amj" | jsonfilter \
			-e "_amx=@.msg[$_ami].index" -e "_ams=@.msg[$_ami].sender" \
			-e "_amt=@.msg[$_ami].timestamp" -e "_amc=@.msg[$_ami].content" \
			-e "_ampt=@.msg[$_ami].part" -e "_amtt=@.msg[$_ami].total" \
			-e "_amrf=@.msg[$_ami].reference" -e "_amtz=@.msg[$_ami].tz" 2>/dev/null)"
		_nl_trim _ams; _nl_trim _amt; _nl_trim _amc
		_ami=$((_ami + 1))
		[ -n "$_ams$_amc" ] || continue
		_amk=$(_arch_key "$_ams" "$_amt" "$_amc")
		case "$_amx" in ''|*[!0-9]*) ;; *) _LIVE_MAP="$_LIVE_MAP$_amk:$_amx " ;; esac
		_amseen=${_AM_SEEN#* $_amk:}
		case "$_AM_SEEN" in
			*" $_amk:"*) _amseen=$((${_amseen%% *} + 1))
				_AM_SEEN=$(printf '%s' "$_AM_SEEN" | sed "s| $_amk:[0-9]* | |") ;;
			*) _amseen=1 ;;
		esac
		_AM_SEEN="$_AM_SEEN$_amk:$_amseen "
		_amhave=$(grep -c "^@[0-9]*|$_amk|" "$_amd" 2>/dev/null)
		case "$_amhave" in ''|*[!0-9]*) _amhave=0 ;; esac
		[ "$_amseen" -le "$_amhave" ] && continue
		_A_TZ=""
		case "$_amtz" in local|[+-][0-9]*) _A_TZ="$_amtz" ;; esac
		_A_PART=""; _A_TOTAL=""; _A_REF=""
		case "$_ampt$_amtt" in ''|*[!0-9]*) ;; *) _A_PART="$_ampt"; _A_TOTAL="$_amtt"; _A_REF="${_amrf:-0}" ;; esac
		_A_TS="$_amt"; _A_FROM=$(printf '%s' "$_ams" | tr -d '\r\n'); _A_TEXT="$_amc"
		_arch_rec "$_amnext" "$_amk" "$_amnow" >> "$_amd" 2>/dev/null
		_amnext=$((_amnext + 1))
	done
	_arch_trim "$_amd"
	_arch_unlock
	_amsig=$( { printf '%s' "$_amj"; cat "$_amd" 2>/dev/null; } | md5sum | cut -c1-32)
	printf '%s\n%s\n' "$_amsig" "$_LIVE_MAP" > "$_amst" 2>/dev/null
}

_arch_index() {
	case "$_LIVE_MAP" in
		*" $2:"*)
			_A_IDX=${_LIVE_MAP#* $2:}
			_A_IDX=${_A_IDX%% *}
			_aipre=${_LIVE_MAP%% $2:*}
			_airest=${_LIVE_MAP#* $2:}
			_LIVE_MAP="$_aipre ${_airest#* }" ;;
		*) _A_IDX="$1" ;;
	esac
}

_arch_json_one() {
	_arch_index "$_A_IDX0" "$_A_KEY"
	_aj_h=""
	case "$_A_TOTAL" in ''|0|1|*[!0-9]*) _aj_h="$_A_KEY" ;; esac
	_kb_put "$_A_IDX" "$_A_FROM" "$_A_TS" "$_A_TEXT" "$_A_PART" "$_A_TOTAL" "$_A_REF" "$_aj_h"
	json_add_object ""
	json_add_int index "$_A_IDX"
	json_add_string sender "$_A_FROM"
	json_add_string timestamp "$_A_TS"
	[ -n "$_A_TZ" ] && json_add_string tz "$_A_TZ"
	json_add_string content "$_A_TEXT"
	case "$_A_TOTAL" in
		''|*[!0-9]*) ;;
		*)
			json_add_int part "${_A_PART:-1}"
			json_add_int total "$_A_TOTAL"
			json_add_int reference "${_A_REF:-0}" ;;
	esac
	json_close_object
}

_arch_json() {
	. /usr/share/libubox/jshn.sh
	_arch_ready
	json_init
	json_add_array msg
	_arch_each _arch_json_one
	json_close_array
	_kb_build
	json_add_array keys
	_aj_i=1
	while [ "$_aj_i" -le "$_kb_n" ]; do
		eval "_aj_x=\$_kb_x$_aj_i; _aj_k=\$_kb_k$_aj_i; _aj_o=\"\$_kb_s$_aj_i|\$_kb_t$_aj_i\""
		_aj_i=$((_aj_i + 1))
		[ -n "$_aj_k" ] || continue
		json_add_object ""
		json_add_int index "$_aj_x"
		json_add_string key "$_aj_k"
		json_add_string old "$_aj_o"
		json_close_object
	done
	json_close_array
	json_dump
}

_arch_text_one() {
	_arch_index "$_A_IDX0" "$_A_KEY"
	printf 'MSG: %s\nFrom: %s\nDate/Time: %s\n%s\n\n' "$_A_IDX" "$_A_FROM" "$_A_TS" "$_A_TEXT"
}

_arch_text() {
	_arch_ready
	_arch_each _arch_text_one
}

_arch_count() {
	_arch_ready
	_acn=$(grep -c '^@' "$(_arch_file)" 2>/dev/null)
	case "$_acn" in ''|*[!0-9]*) _acn=0 ;; esac
	echo "$_acn"
}

_arch_del_index() {
	case "$1" in ''|*[!0-9]*) return 0 ;; esac
	_arch_ready
	_arch_lock
	_arch_drop -v x="$1" '/^@/ { skip = (substr($1, 2) == x) } !skip'
	_arch_unlock
}

_arch_del_live() {
	_adn=$(printf '%s' "$2" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_adn" in ''|*[!0-9]*) return 0 ;; esac
	_adi=0
	while [ "$_adi" -lt "$_adn" ]; do
		_adx=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].index" 2>/dev/null)
		if [ "$_adx" = "$1" ]; then
			_ads=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].sender" 2>/dev/null)
			_adt=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].timestamp" 2>/dev/null)
			_adc=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].content" 2>/dev/null)
			_adk=$(_arch_key "$_ads" "$_adt" "$_adc")
			_arch_ready
			_arch_lock
			_arch_drop -v k="$_adk" '/^@/ { skip = 0; if (!done && $2 == k) { skip = 1; done = 1 } } !skip'
			_arch_unlock
			return 0
		fi
		_adi=$((_adi + 1))
	done
}

_arch_wipe() {
	_arch_ready
	_arch_lock
	rm -f "$(_arch_file)" 2>/dev/null
	_arch_unlock
}

_pdu_tz() {
	awk '
	function hx(c) { return index("0123456789ABCDEF", toupper(c)) - 1 }
	function by(s, i) { return hx(substr(s, 2 * i + 1, 1)) * 16 + hx(substr(s, 2 * i + 2, 1)) }
	{
		if (match($0, /"index":[0-9]+/) == 0) next
		ix = substr($0, RSTART + 8, RLENGTH - 8)
		if (match($0, /"content":"[0-9A-Fa-f]+/) == 0) next
		pdu = substr($0, RSTART + 11, RLENGTH - 11)
		n = length(pdu) / 2
		if (n < 12) next
		o = 1 + by(pdu, 0)
		if (o + 2 >= n) next
		if (by(pdu, o) % 4 != 0) next
		oa = by(pdu, o + 1)
		o = o + 3 + int((oa + 1) / 2) + 2
		if (o + 7 > n) next
		t = by(pdu, o + 6)
		q = (t % 8) * 10 + int(t / 16)
		if (q > 56 || int(t / 16) > 9) next
		m = q * 15
		if (int(t / 8) % 2 == 1) m = -m
		printf "%s %s%d\n", ix, (m < 0 ? "-" : "+"), (m < 0 ? -m : m)
	}'
}

_tz_tag() {
	_tt_j="$1"
	case "$(_smstool)" in */sms_tool_mm) printf '%s' "$_tt_j"; return ;; esac
	case "$_tt_j" in *'"index":'*) ;; *) printf '%s' "$_tt_j"; return ;; esac
	_tt_c="/tmp/5gmodem/smstz_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
	_tt_sig=$(printf '%s' "$_tt_j" | jsonfilter -e '@.msg[*].index' -e '@.msg[*].timestamp' 2>/dev/null | tr '\n' ' ' | md5sum | cut -c1-16)
	if [ "$(head -n 1 "$_tt_c" 2>/dev/null)" != "#$_tt_sig" ]; then
		_tt_raw=$(_sms_run 45 $(_smstool) -d "$PORT" -r -j $_STORE_ARG recv 2>/dev/null | tr '{' '\n' | _pdu_tz)
		if [ -n "$_tt_raw" ]; then
			printf '#%s\n%s\n' "$_tt_sig" "$_tt_raw" > "$_tt_c.$$" 2>/dev/null && mv -f "$_tt_c.$$" "$_tt_c"
		fi
	fi
	[ -s "$_tt_c" ] || { printf '%s' "$_tt_j"; return; }
	_tt_sed=""
	while read -r _tt_i _tt_z; do
		case "$_tt_i$_tt_z" in *[!0-9+-]*|'') continue ;; esac
		_tt_sed="$_tt_sed;s/{\"index\":$_tt_i,/{\"index\":$_tt_i,\"tz\":\"$_tt_z\",/"
	done < "$_tt_c"
	[ -n "$_tt_sed" ] || { printf '%s' "$_tt_j"; return; }
	printf '%s' "$_tt_j" | sed "${_tt_sed#;}"
}


ARCH_GRACE_MIN=60

_AP_WHY=""
_ap_why() {
	[ -n "$_AP_WHY" ] || return 0
	printf '%s\t%s\n' "$1" "$2"
}

_arch_purge() {
	if [ "$(uci -q get "$CFG.sms.archive_purge")" = "0" ] && ! _fwd_del_on; then
		_ap_why '-' "slot purge is disabled in settings"
		return 0
	fi
	_arch_ready || return 0
	_apd=$(_arch_file)
	[ -f "$_apd" ] || return 0
	_ap_now=$(date +%s 2>/dev/null); case "$_ap_now" in ''|*[!0-9]*) _ap_now=0 ;; esac
	_apn=$(printf '%s' "$1" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_apn" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_apn" -gt 0 ] || return 0

	_ap_chs=$(_fwd_lists)
	_ap_cmd=$(uci -q get "$CFG.sms.cmd_enabled")
	_ap_sf=$(_seen_file)
	_ap_df=$(sms_cmd_done_file "$_TGT_PATH")

	_ap_i=0; _ap_del=0; _ap_stuck=0; _ap_late_n=0; _ap_kb=0
	while [ "$_ap_i" -lt "$_apn" ]; do
		_ap_x=""; _ap_s=""; _ap_t=""; _ap_c=""
		eval "$(printf '%s' "$1" | jsonfilter \
			-e "_ap_x=@.msg[$_ap_i].index" -e "_ap_s=@.msg[$_ap_i].sender" \
			-e "_ap_t=@.msg[$_ap_i].timestamp" -e "_ap_c=@.msg[$_ap_i].content" 2>/dev/null)"
		_nl_trim _ap_s; _nl_trim _ap_t; _nl_trim _ap_c
		_ap_i=$((_ap_i + 1))
		case "$_ap_x" in ''|*[!0-9]*) continue ;; esac
		[ "$_ap_x" -ge "$ARCH_BASE" ] 2>/dev/null && continue
		if [ -z "$_ap_s$_ap_c" ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "PDU not parsed, not archived"
			continue
		fi

		_ap_k=$(_arch_key "$_ap_s" "$_ap_t" "$_ap_c")
		_ap_have=$(grep -m 1 "^@[0-9]*|$_ap_k|" "$_apd" 2>/dev/null)
		if [ -z "$_ap_have" ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "not archived yet"
			continue
		fi

		# record header: @index|key|added|...
		_ap_fn=${_ap_have#@}; _ap_fn=${_ap_fn%%|*}
		_ap_add=${_ap_have#*|}; _ap_add=${_ap_add#*|}; _ap_add=${_ap_add%%|*}
		case "$_ap_add" in ''|*[!0-9]*) _ap_add=0 ;; esac
		_ap_late=0
		[ $((_ap_now - _ap_add)) -gt $((ARCH_GRACE_MIN * 60)) ] && _ap_late=1

		_ap_wait=0
		if [ -n "$_ap_chs" ] && [ "$_ap_late" = 0 ]; then
			if [ "$_ap_kb" = 0 ]; then
				_kb_n=0
				_kb_feed_arch
				_kb_build
				_tg_migrate
				for _ap_ch in $_ap_chs; do
					_kb_list_load "$(_list_file "$_ap_ch")"
					eval "_ap_L_$_ap_ch=\$_KB_LIST"
				done
				_ap_kb=1
			fi
			_ap_kn=""
			case "$_ap_fn" in ''|*[!0-9]*) ;; *) eval "_ap_kn=\$_kb_ix$_ap_fn" ;; esac
			if [ -n "$_ap_kn" ]; then
				for _ap_ch in $_ap_chs; do
					eval "_KB_LIST=\$_ap_L_$_ap_ch"
					_kb_known "$_ap_kn" || { _ap_wait=1; break; }
				done
			else
				_ap_wait=1
			fi
		fi
		if [ "$_ap_wait" = 1 ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "waiting for Telegram delivery (deadline ${ARCH_GRACE_MIN} min)"
			continue
		fi

		if [ "$_ap_cmd" = "1" ] && [ "$_ap_late" = 0 ] \
		   && ! grep -qxF "$(sms_cmd_key "$_ap_s" "$_ap_t" "$_ap_c")" "$_ap_df" 2>/dev/null; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "waiting for the SMS commands pass (deadline ${ARCH_GRACE_MIN} min)"
			continue
		fi

		[ "$_ap_late" = 1 ] && _ap_late_n=$((_ap_late_n + 1))
		if [ -n "$_AP_WHY" ]; then
			_ap_why "$_ap_x" "ready to delete"
			continue
		fi
		MM_MODEM_PATH="$_TGT_PATH" _sms_run 12 $(_smstool) -d "$PORT" delete "$_ap_x" >/dev/null 2>&1 \
			&& _ap_del=$((_ap_del + 1))
	done
	_live_drop
	[ -n "$_AP_WHY" ] && return 0
	if [ "$_ap_del" -gt 0 ]; then
		logger -t 5gmodem "sms: messages moved to router storage and deleted from the modem: $_ap_del"
		[ "$_ap_late_n" -gt 0 ] && logger -t 5gmodem \
			"sms: of them by deadline (bot or commands never confirmed): $_ap_late_n"
	fi
	if [ "$_ap_stuck" -gt 0 ]; then
		_ap_mk=/tmp/5gmodem/arch_stuck.stamp
		_ap_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
		_ap_prev=$(cat "$_ap_mk" 2>/dev/null)
		case "$_ap_prev" in ''|*[!0-9]*) _ap_prev=0 ;; esac
		if [ "$((_ap_now - _ap_prev))" -ge 3600 ]; then
			printf '%s' "$_ap_now" > "$_ap_mk" 2>/dev/null
			logger -t 5gmodem "sms: messages left in the modem that cannot be deleted yet: $_ap_stuck (see smsbridge.sh archive-why)"
		fi
	fi
	return 0
}

_fwd_del_on() { [ "$(uci -q get "$CFG.sms.fwd_delete")" = 1 ]; }

_fwd_purge() {
	_fwd_del_on || return 0
	_fp_chs=$(_fwd_lists)
	if [ -z "$_fp_chs" ]; then
		_ap_why '-' "no forwarding channel is enabled"
		return 0
	fi
	_kb_n=0
	_kb_feed_json "$1"
	[ "$_kb_n" -gt 0 ] || return 0
	_kb_build
	_tg_migrate
	for _fp_ch in $_fp_chs; do
		_kb_list_load "$(_list_file "$_fp_ch")"
		eval "_fp_L_$_fp_ch=\$_KB_LIST"
	done
	_fp_cmd=$(uci -q get "$CFG.sms.cmd_enabled")
	_fp_df=$(sms_cmd_done_file "$_TGT_PATH")
	_fp_i=1; _fp_del=0
	while [ "$_fp_i" -le "$_kb_n" ]; do
		eval "_fp_x=\$_kb_x$_fp_i; _fp_f=\$_kb_f$_fp_i; _fp_t=\$_kb_t$_fp_i; _fp_c=\$_kb_c$_fp_i"
		_fp_n=$_fp_i
		_fp_i=$((_fp_i + 1))
		case "$_fp_x" in ''|*[!0-9]*) continue ;; esac
		[ "$_fp_x" -ge "$ARCH_BASE" ] 2>/dev/null && continue
		_fp_wait=0
		for _fp_ch in $_fp_chs; do
			eval "_KB_LIST=\$_fp_L_$_fp_ch"
			_kb_known "$_fp_n" || { _fp_wait=1; break; }
		done
		if [ "$_fp_wait" = 1 ]; then
			_ap_why "$_fp_x" "waiting for forwarding"
			continue
		fi
		if [ "$_fp_cmd" = 1 ] \
		   && ! grep -qxF "$(sms_cmd_key "$_fp_f" "$_fp_t" "$_fp_c")" "$_fp_df" 2>/dev/null; then
			_ap_why "$_fp_x" "waiting for the SMS commands pass"
			continue
		fi
		if [ -n "$_AP_WHY" ]; then
			_ap_why "$_fp_x" "forwarded, ready to delete"
			continue
		fi
		MM_MODEM_PATH="$_TGT_PATH" _sms_run 12 $(_smstool) -d "$PORT" delete "$_fp_x" >/dev/null 2>&1 \
			&& _fp_del=$((_fp_del + 1))
	done
	_live_drop
	[ "$_fp_del" -gt 0 ] && [ -z "$_AP_WHY" ] && \
		logger -t 5gmodem "sms: forwarded messages deleted from the modem: $_fp_del"
	return 0
}

case "$BOX" in
recv|unseen|sent|status|dump|archive-run|archive-why)
	if [ -z "$_BG_SKIP" ] && [ -z "$_LIVE_HIT" ] && ! _via_mm && [ "$_TGT_PATH" = "$(uci -q get "$CFG.@5gmodem[0].active_modem")" ]; then
		_cs_mark="/tmp/5gmodem/cpms_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
		_cs_st=$(cat "$_cs_mark" 2>/dev/null)
		if [ "$_cs_st" != ok ] && [ "${#_cs_st}" -lt 3 ] && ! at_long_busy "$PORT" && ! mm_assembling "$_TGT_PATH"; then
			if set_sms_storage "$PORT" 2>/dev/null; then
				printf 'ok' > "$_cs_mark"
				_cs_eff=$(uci -q get "$CFG.sms.storage")
				[ -n "$_cs_eff" ] && [ -n "$STORE" ] && STORE="$_cs_eff"
			else
				printf '.' >> "$_cs_mark"
			fi
		fi
	fi ;;
esac

# see docs/subsystems/sms.md#storage-cpms
_STORE_ARG=""
_store_pick() {
	_STORE_ARG=""
	[ -n "$STORE" ] || return 0
	_STORE_ARG="-s $STORE"
	if ! _via_mm && [ -c "$PORT" ] && ! at_long_busy "$PORT" && ! mm_assembling "$_TGT_PATH"; then
		case "$(sms_cpms_state "$PORT" 2>/dev/null)" in
			"$STORE|"*) _STORE_ARG="" ;;
			?*) sms_apply_cpms "$PORT" "$STORE" >/dev/null 2>&1 && _STORE_ARG="" ;;
		esac
	fi
}
_cnmi_fix() {
	_via_mm && return 0
	[ -c "$PORT" ] || return 0
	case "$(uci -q get "$CFG.$_TGT_SEC.vidpid")" in
		413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4) ;;
		*) return 0 ;;
	esac
	_cf_mk="/tmp/5gmodem/cnmi_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
	[ -f "$_cf_mk" ] && [ -z "$(find "$_cf_mk" -mmin +1 2>/dev/null)" ] && return 0
	at_long_busy "$PORT" && return 0
	: > "$_cf_mk"
	case "$(sms_tool -d "$PORT" at "AT+CNMI?" 2>/dev/null | tr -d '\r ')" in
		*"+CNMI:0,0"*)
			sms_tool -d "$PORT" at "AT+CNMI=2,1,0,0,0" >/dev/null 2>&1
			logger -t 5gmodem "sms: $PORT had CNMI 0,0 (reset by the modem), set 2,1,0,0,0 so incoming SMS are stored" ;;
	esac
}
[ "$BOX" = delete-run ] || [ -n "$_BG_SKIP" ] || [ -n "$_LIVE_HIT" ] || { _store_pick; _cnmi_fix; }

set -- -d "$PORT" -f '%Y-%m-%d %H:%M' -j
[ -n "$_STORE_ARG" ] && set -- $_STORE_ARG "$@"
case "$BOX" in
	status)
		if _arch_on; then
			_arch_merge "$(_arch_live_json)"
			_st_l="MT"
			_via_mm || { _st_l=${STORE:-SM}; _st_l=$(printf '%.2s' "$_st_l"); }
			printf 'Storage type: %s, used: %d, total: %d\n' \
				"$_st_l" "$(_arch_count)" "$ARCH_MAX" | tee "$_ST_CACHE.tmp"
			mv "$_ST_CACHE.tmp" "$_ST_CACHE" 2>/dev/null
			exit 0
		fi
		_st_out=$(_sms_run 20 $(_smstool) -d "$PORT" $_STORE_ARG status); _st_rc=$?
		case "$_st_out" in
			*used:*) printf '%s\n' "$_st_out" > "$_ST_CACHE.tmp" && mv "$_ST_CACHE.tmp" "$_ST_CACHE" 2>/dev/null ;;
		esac
		[ -n "$_st_out" ] && printf '%s\n' "$_st_out"
		exit $_st_rc ;;
	archive-run)
		[ -n "$_BG_SKIP" ] && { echo '{"result":"busy"}'; exit 0; }
		if ! _arch_on || { _via_mm && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; }; then
			_fwd_del_on || { _arch_on && echo '{"result":"mm"}' || echo '{"result":"off"}'; exit 0; }
			_fwd_purge "$(_arch_live_json)"
			echo '{"result":"ok"}'; exit 0
		fi
		_ar_j=$(_arch_live_json)
		_arch_merge "$_ar_j"
		_arch_purge "$_ar_j"
		echo '{"result":"ok"}'
		exit 0 ;;
	archive-why)
		echo "modem:        ${_TGT_PATH:-?}"
		echo "port:         ${PORT:-?}"
		echo "storage:      ${STORE:-$(uci -q get "$CFG.sms.storage")}"
		echo "via MM:       $(_via_mm && echo yes || echo no)"
		echo "archive:      $(_arch_on && echo on || echo off)"
		echo "slot purge:   $([ "$(uci -q get "$CFG.sms.archive_purge")" = "0" ] && echo off || echo on)"
		echo "Telegram:     $([ "$(uci -q get "$CFG.sms.tg_enabled")" = "1" ] && echo on || echo off)"
		echo "SMS commands: $([ "$(uci -q get "$CFG.sms.cmd_enabled")" = "1" ] && echo on || echo off)"
		echo "fwd delete:   $(_fwd_del_on && echo on || echo off)"
		if _fwd_del_on && { ! _arch_on || { _via_mm && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; }; }; then
			echo
			_AP_WHY=1
			_fwd_purge "$(_arch_live_json)"
			exit 0
		fi
		if ! _arch_on; then
			echo
			echo "Archive is off: messages stay in the modem. Settings -> SMS -> \"Keep messages in router storage\"."
			exit 0
		fi
		if _via_mm && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; then
			echo
			echo "The modem runs under ModemManager and \"Keep messages in router storage\" is off: slots are not freed."
			exit 0
		fi
		_aw_j=$(_arch_live_json)
		echo "archived:     $(_arch_count)"
		echo "in modem:     $(printf '%s' "$_aw_j" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)"
		echo
		_arch_merge "$_aw_j"
		_AP_WHY=1
		_arch_purge "$_aw_j"
		exit 0 ;;
	sent)   _sms_run 45 $(_smstool) "$@" recv SR | utf8_fix; exit $? ;;
	delete)
		case "$DEL" in
			all)
				_arch_on && _arch_wipe
				_sms_run 40 $(_smstool) -d "$PORT" delete all
				for _dl_i in $(_sms_run 45 $(_smstool) "$@" recv \
						| jsonfilter -e '@.msg[*].index' 2>/dev/null | sort -rn); do
					case "$_dl_i" in ''|*[!0-9]*) continue ;; esac
					_sms_run 12 $(_smstool) -d "$PORT" delete "$_dl_i"
				done
				_live_drop
				exit 0 ;;
			''|*[!0-9]*) echo "bad index" >&2; exit 2 ;;
			*)
				if _arch_on; then
					if [ "$DEL" -ge "$ARCH_BASE" ]; then
						_arch_del_index "$DEL"
						echo "delete msg from $DEL to $DEL"
						exit 0
					fi
					_arch_del_live "$DEL" "$(_arch_live_json)"
				fi
				_sms_run 15 $(_smstool) -d "$PORT" delete "$DEL"; _dl_rc=$?
				_live_drop
				exit $_dl_rc ;;
		esac ;;
	delete-run)
		_dr_live=""
		for _dr_i in $(printf '%s' "$DEL" | tr ',' ' '); do
			if [ "$_dr_i" -ge "$ARCH_BASE" ]; then
				_arch_del_index "$_dr_i"
				_dr_left=""
				grep -q "^@$_dr_i|" "$(_arch_file)" 2>/dev/null && _dr_left=1
				if [ -n "$_dr_left" ]; then _dj_fail "$_dr_i" archive ""; else _dj_ok "$_dr_i"; fi
				_dj_write running
			else
				_dr_live="$_dr_live $_dr_i"
			fi
		done
		[ -n "$_dr_live" ] || { _dj_write done; exit 0; }
		if _sms_tdtech "$PORT"; then
			_dr_live=$(printf '%s\n' "$_dr_live" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -rn)
		fi
		_dr_why=""
		if [ -z "$PORT" ]; then
			_dr_why=noport
		else
			_dr_try=0
			while [ "$_AT_LOCKED" != 0 ] && [ "$_dr_try" -lt 3 ]; do
				at_lock "$PORT" 15; _AT_LOCKED=$?
				_dr_try=$((_dr_try + 1))
			done
			[ "$_AT_LOCKED" = 0 ] || _dr_why=busy
		fi
		if [ -n "$_dr_why" ]; then
			for _dr_i in $_dr_live; do _dj_fail "$_dr_i" "$_dr_why" ""; done
			_dj_write done
			exit 0
		fi
		_store_pick
		_dr_before=$(_arch_live_json)
		_dr_pend=""; _dr_hang=0; _dr_base=$_DJ_DONE
		for _dr_i in $_dr_live; do
			if [ "$_dr_hang" -ge 3 ]; then
				_dr_pend="$_dr_pend $_dr_i:noanswer:"
				continue
			fi
			_dr_o=$(MM_MODEM_PATH="$_TGT_PATH" _sms_run 12 $(_smstool) -d "$PORT" delete "$_dr_i"); _dr_rc=$?
			case "$_dr_o" in
				*"Deleted message $_dr_i"*) _dr_pend="$_dr_pend $_dr_i:ok:"; _dr_hang=0 ;;
				*"Error deleting message $_dr_i"*)
					_dr_a=$(printf '%s' "$_dr_o" | sed -n "s/.*Error deleting message $_dr_i: *\\([0-9A-Za-z ]*\\).*/\\1/p" | head -1 | tr -d '\r')
					_dr_pend="$_dr_pend $_dr_i:refused:$(printf '%s' "$_dr_a" | tr ' ' '_')"; _dr_hang=0 ;;
				*)
					if [ "$_dr_rc" = 0 ]; then _dr_pend="$_dr_pend $_dr_i:ok:"; _dr_hang=0
					else _dr_pend="$_dr_pend $_dr_i:noanswer:"; _dr_hang=$((_dr_hang + 1))
					fi ;;
			esac
			_DJ_DONE=$((_DJ_DONE + 1)); _dj_write running
		done
		_live_drop
		_dr_after=$(_arch_live_json)
		_dr_seen=""
		case "$_dr_after" in
			*'"msg"'*) _dr_seen=1
				_dr_left=" $(printf '%s' "$_dr_after" | jsonfilter -e '@.msg[*].index' 2>/dev/null | tr '\n' ' ')" ;;
		esac
		_DJ_DONE=$_dr_base
		for _dr_p in $_dr_pend; do
			_dr_i=${_dr_p%%:*}; _dr_v=${_dr_p#*:}; _dr_a=${_dr_v#*:}; _dr_v=${_dr_v%%:*}
			if [ -n "$_dr_seen" ]; then
				case "$_dr_left" in
					*" $_dr_i "*)
						_dr_b=$(printf '%s' "$_dr_before" | jsonfilter -e "@.msg[@.index=$_dr_i].timestamp" 2>/dev/null | head -1)
						_dr_c=$(printf '%s' "$_dr_after" | jsonfilter -e "@.msg[@.index=$_dr_i].timestamp" 2>/dev/null | head -1)
						if [ "$_dr_b" = "$_dr_c" ]; then
							[ "$_dr_v" = ok ] && _dr_v=refused
						else
							_dr_v=ok
						fi ;;
					*) _dr_v=ok ;;
				esac
			fi
			if [ "$_dr_v" = ok ]; then
				_arch_on && _arch_del_live "$_dr_i" "$_dr_before"
				_dj_ok "$_dr_i"
			else
				_dj_fail "$_dr_i" "$_dr_v" "$_dr_a"
			fi
		done
		_dj_write done
		exit 0 ;;
	send)
		[ -n "$SND_TO" ] || { echo "no number" >&2; exit 2; }
		SND_TO=$(_norm_num "$SND_TO")
		if [ "$_AT_LOCKED" != 0 ] || \
			{ [ -n "$_AT_LOCK_HELD" ] && [ "$_AT_LOCK_HELD" != "$(basename "$PORT")" ]; }; then
			if _q_enqueue "$SND_TO" "$SND_TXT" "$PORT"; then
				echo "sms queued: port is busy, will send when possible"
				exit 0
			fi
		fi
		_snd_out=$(_send_one "$PORT" "$SND_TO" "$SND_TXT" 2>/dev/null)
		_snd_rc=$?
		if [ "$_snd_rc" = 0 ]; then
			case "$_snd_out" in
				*sucessfully*) printf '%s\n' "$_snd_out" ;;
				*) echo "sms sent sucessfully" ;;
			esac
			exit 0
		fi
		if [ "$_snd_rc" = 4 ]; then
			echo "SMS result is unknown: the modem did not confirm submission; check delivery before sending again"
			exit 1
		fi
		if _q_enqueue "$SND_TO" "$SND_TXT" "$PORT"; then
			echo "sms queued: sending failed now, will retry when possible"
			exit 0
		fi
		echo "sms sending failed"
		exit 1 ;;
	queue-run)
		[ -d "$SMSQ_DIR" ] || exit 0
		for _qr_f in "$SMSQ_DIR"/*.sms; do
			[ -f "$_qr_f" ] || continue
			_q_send_one "$_qr_f"
			break
		done
		exit 0 ;;
	queue-list)
		printf '{"queued":['
		_ql_n=0
		for _ql_f in "$SMSQ_DIR"/*.sms "$SMSQ_DIR"/*.unknown; do
			[ -f "$_ql_f" ] || continue
			_ql_to=$(sed -n 's/^to=//p' "$_ql_f" | head -1)
			_ql_tr=$(sed -n 's/^tries=//p' "$_ql_f" | head -1)
			[ "$_ql_n" = 0 ] || printf ','
			_ql_state=queued
			case "$_ql_f" in *.unknown) _ql_state=unknown ;; esac
			printf '{"to":"%s","tries":%s,"state":"%s"}' "$_ql_to" "${_ql_tr:-0}" "$_ql_state"
			_ql_n=$((_ql_n + 1))
		done
		printf ']}\n'
		exit 0 ;;
	dump)
		if _arch_on; then
			_arch_merge "$(_arch_live_json)"
			_arch_text
			exit 0
		fi
		_sms_run 45 $(_smstool) -d "$PORT" -f '%Y-%m-%d %H:%M' $_STORE_ARG recv | utf8_fix; exit $? ;;
	*)
		if _arch_on; then
			[ -n "$_BG_SKIP" ] || _arch_merge "$(_arch_live_json)"
			if [ "$BOX" = unseen ]; then
				[ -n "$_AT_INH" ] || at_unlock
				_kb_feed_arch
				_kb_build
				_kb_unseen_ul
				exit 0
			fi
			_arch_json
			exit 0
		fi
		[ -n "$_BG_SKIP" ] && exit 0
		_rv_j=$(_live_json)
		[ -n "$_AT_INH" ] || at_unlock
		_kb_out "$_rv_j"
		exit 0 ;;
esac
