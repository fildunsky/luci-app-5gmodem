#!/bin/sh

RES=/usr/share/5gmodem
CFG=5gmodem

. "$RES/lib.sh" 2>/dev/null

_LM=$("$RES/listmodems.sh" 2>/dev/null)

_ACTIVE=""
case "$1" in
	paths) ;;
	*) uci5g_snapshot; ucinet_snapshot; _ACTIVE=$(active_path) ;;
esac

_jq() {
	printf '%s' "$_LM" | jsonfilter "$@" 2>/dev/null
}

_owner() {
	[ -n "$2" ] || { echo none; return; }
	if [ "$3" = "modemmanager" ] && [ "$(uci5g_get "$1" mm_exclude)" != "1" ]; then
		echo mm
	else
		echo us
	fi
}

_record() {
	_r_p="$1"
	_r_s=$(secname "$_r_p")

	_r_vp=""; _r_prod=""; _r_ser=""; _r_i=0
	while IFS= read -r _r_l; do
		_r_i=$((_r_i + 1))
		case "$_r_i" in
			1) _r_vp="$_r_l" ;;
			2) _r_prod="$_r_l" ;;
			3) _r_ser="$_r_l" ;;
		esac
	done <<EOF
$(_jq -e "@[@.path=\"$_r_p\"].vidpid" -e "@[@.path=\"$_r_p\"].product" -e "@[@.path=\"$_r_p\"].serial")
EOF
	_r_tty=""; _r_wdm=""; _r_net=""
	while IFS= read -r _r_l; do
		case "$_r_l" in
			'') ;;
			/dev/tty*) _r_tty="$_r_tty$_r_l " ;;
			/dev/wwan*at*) _r_tty="$_r_tty$_r_l " ;;
			/dev/*)    _r_wdm="$_r_wdm$_r_l " ;;
			*)         _r_net="$_r_net$_r_l " ;;
		esac
	done <<EOF
$(_jq -e "@[@.path=\"$_r_p\"].tty[*]" -e "@[@.path=\"$_r_p\"].wdm[*]" -e "@[@.path=\"$_r_p\"].net[*]")
EOF
	_r_if=$(uci5g_get "$_r_s" network)
	_r_proto=""
	[ -n "$_r_if" ] && _r_proto=$(ucinet_get "$_r_if" proto)
	_r_at=$(uci5g_get "$_r_s" at_port)
	tty_poll_unsafe "$_r_at" && _r_at=""
	if [ -n "$_r_at" ]; then
		case " $_r_tty " in
			*" $_r_at "*) : ;;
			*) _r_at="" ;;
		esac
	fi
	_r_json_list() {
		_l=""
		for _e in $1; do
			[ -n "$_l" ] && _l="$_l,"
			_l="$_l\"$_e\""
		done
		printf '[%s]' "$_l"
	}
	[ -n "$_r_vp" ] || _r_vp=$(uci5g_get "$_r_s" vidpid)
	printf '{"path":"%s","section":"%s","model":"%s","product":"%s","vidpid":"%s","serial":"%s","imei":"%s",' \
		"$(json_esc "$_r_p")" "$(json_esc "$_r_s")" \
		"$(json_esc "$(uci5g_get "$_r_s" model)")" \
		"$(json_esc "$_r_prod")" \
		"$(json_esc "$_r_vp")" \
		"$(json_esc "$_r_ser")" \
		"$(json_esc "$(uci5g_get "$_r_s" imei)")"
	printf '"iface":"%s","proto":"%s","at_port":"%s","owner":"%s","active":%s,' \
		"$(json_esc "$_r_if")" \
		"$(json_esc "$_r_proto")" \
		"$(json_esc "$_r_at")" "$(_owner "$_r_s" "$_r_if" "$_r_proto")" \
		"$([ "$_r_p" = "$_ACTIVE" ] && echo true || echo false)"
	printf '"tty":%s,"wdm":%s,"net":%s}' \
		"$(_r_json_list "$_r_tty")" \
		"$(_r_json_list "$_r_wdm")" \
		"$(_r_json_list "$_r_net")"
}

_all_paths() { _jq -e '@[*].path'; }

_flat() {
	for _f_p in $(_all_paths); do
		_f_s=$(secname "$_f_p")
		_f_if=$(uci5g_get "$_f_s" network)
		_f_pr=""
		[ -n "$_f_if" ] && _f_pr=$(ucinet_get "$_f_if" proto)
		_f_at=$(uci5g_get "$_f_s" at_port)
		tty_poll_unsafe "$_f_at" && _f_at=""
		if [ -n "$_f_at" ]; then
			_f_t=$(_jq -e "@[@.path=\"$_f_p\"].tty[*]" | tr '\n' ' ')
			case " $_f_t " in
				*" $_f_at "*) : ;;
				*) _f_at="" ;;
			esac
		fi
		printf '%s %s %s %s %s %s\n' \
			"$_f_p" "$_f_s" "${_f_if:--}" "${_f_pr:--}" "${_f_at:--}" \
			"$(_owner "$_f_s" "$_f_if" "$_f_pr")"
	done
}

case "$1" in
paths)
	_all_paths ;;
flat)
	_flat ;;
path)
	[ -n "$2" ] || { echo '{"error":"no path"}'; exit 2; }
	_all_paths | grep -qx "$2" || { echo '{}'; exit 0; }
	_record "$2"; echo ;;
port)
	[ -n "$2" ] || { echo '{"error":"no port"}'; exit 2; }
	for _p in $(_all_paths); do
		_t=$(_jq -e "@[@.path=\"$_p\"].tty[*]" | tr '\n' ' ')
		case " $_t " in
			*" $2 "*) _record "$_p"; echo; exit 0 ;;
		esac
	done
	echo '{}' ;;
active)
	_a="$_ACTIVE"
	[ -n "$_a" ] || { echo '{}'; exit 0; }
	_all_paths | grep -qx "$_a" || { echo '{}'; exit 0; }
	_record "$_a"; echo ;;
''|all)
	_first=1
	printf '['
	for _p in $(_all_paths); do
		[ "$_first" = 1 ] || printf ','
		_first=0
		_record "$_p"
	done
	printf ']\n' ;;
*)
	echo '{"error":"usage: [all] | paths | flat | path <usb> | port <tty> | active"}'
	exit 2 ;;
esac
exit 0
