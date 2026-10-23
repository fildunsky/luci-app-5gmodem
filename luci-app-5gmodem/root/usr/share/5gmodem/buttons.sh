#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null
CFG=5gmodem
LEDS_DIR="${LEDS_DIR:-/sys/class/leds}"

_sid() { echo "btn_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

_led_color() {
	case "$1" in *:*) _c="${1%%:*}" ;; *) _c="" ;; esac
	case "$_c" in
		red|green|blue|white|amber|orange|yellow|cyan|purple|violet|pink|magenta) echo "$_c" ;;
		*) echo "" ;;
	esac
}

_led_max() {
	_m=$(cat "$LEDS_DIR/$1/max_brightness" 2>/dev/null)
	case "$_m" in ''|*[!0-9]*|0) _m=255 ;; esac
	printf '%s' "$_m"
}

_led_dummy() {
	case "$1" in *-phy[0-9]*) return 0 ;; esac
	case "$1" in
		white:power)
			case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
				*almond*) return 0 ;;
			esac ;;
	esac
	return 1
}

_led_sec() {
	for _ls in $(uci show system 2>/dev/null | sed -n 's/^system\.\([^.=]*\)=led$/\1/p'); do
		[ "$(uci -q get "system.$_ls.sysfs")" = "$1" ] && { printf '%s' "$_ls"; return 0; }
	done
	return 1
}

_led_detach() {
	_name="$1"; [ -n "$_name" ] || return 0
	_sec=$(_led_sec "$_name")
	if [ -z "$_sec" ]; then
		_sec=$(uci add system led 2>/dev/null) || return 0
		uci -q set "system.$_sec.name=$_name"
		uci -q set "system.$_sec.sysfs=$_name"
	fi
	uci -q set "system.$_sec.trigger=none"
}

_apply_leds() {
	_al_dirty=0
	for _kv in $1; do
		_ln="${_kv%=*}"; _lv="${_kv##*=}"
		[ -n "$_ln" ] || continue
		_led_dummy "$_ln" && continue
		[ -e "$LEDS_DIR/$_ln/brightness" ] || continue
		[ -e "$LEDS_DIR/$_ln/trigger" ] && printf 'none' > "$LEDS_DIR/$_ln/trigger" 2>/dev/null
		if [ "$_lv" = "1" ]; then
			printf '%s' "$(_led_max "$_ln")" > "$LEDS_DIR/$_ln/brightness" 2>/dev/null
		else
			printf '0' > "$LEDS_DIR/$_ln/brightness" 2>/dev/null
		fi
		_al_sec=$(_led_sec "$_ln")
		[ -n "$_al_sec" ] || continue
		[ "$(uci -q get "system.$_al_sec.default")" = "$_lv" ] && continue
		uci -q set "system.$_al_sec.default=$_lv"
		_al_dirty=1
	done
	[ "$_al_dirty" = 1 ] && uci -q commit system
	return 0
}

_svc_running() { svc_running "$1"; }

_code_name() {
	case "$1" in
		256) echo BTN_0;; 257) echo BTN_1;; 258) echo BTN_2;; 259) echo BTN_3;;
		260) echo BTN_4;; 261) echo BTN_5;; 262) echo BTN_6;; 263) echo BTN_7;;
		264) echo BTN_8;; 265) echo BTN_9;;
		408) echo reset;; 529) echo wps;; 247) echo rfkill;; 116) echo power;;
		*) echo "";;
	esac
}

_dts_buttons() {
	_force_key=0
	case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
		huasifei,wh3000*) _force_key=1 ;;
	esac
	_dtb=/sys/firmware/devicetree/base
	for _cf in "$_dtb"/*/compatible "$_dtb"/*/*/compatible; do
		[ -f "$_cf" ] || continue
		tr '\0' '\n' 2>/dev/null < "$_cf" | grep -qxE 'gpio-keys|gpio-keys-polled' || continue
		_kd="${_cf%/compatible}"
		for _b in "$_kd"/*/; do
			[ -f "${_b}linux,code" ] || continue
			_hex=$(hexdump -v -e '/1 "%02x"' "${_b}linux,code" 2>/dev/null)
			[ -n "$_hex" ] || continue
			_nm=$(_code_name "$((0x$_hex))")
			[ -n "$_nm" ] || continue
			_lbl=""; [ -f "${_b}label" ] && _lbl=$(tr -d '\0' < "${_b}label")
			_type=button
			if [ "$_force_key" != 1 ] && [ -f "${_b}linux,input-type" ]; then
				_ith=$(hexdump -v -e '/1 "%02x"' "${_b}linux,input-type" 2>/dev/null)
				[ "$((0x${_ith:-0}))" = 5 ] && _type=switch
			fi
			printf '%s\t%s\t%s\n' "$_nm" "$_lbl" "$_type"
		done
	done
}

_is_system() { [ "$1" = "reset" ]; }

_json_esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

_sync_leds_all() {
	for _s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\([^.=]*\)=button\$/\1/p"); do
		for _st in pressed released; do
			[ "$(uci -q get "$CFG.$_s.ct_$_st")" = "conditional" ] || continue
			_cmd=$(uci -q get "$CFG.$_s.$_st")
			_svc=$(printf '%s' "$_cmd" | sed -n 's/.*svc[[:space:]]\{1,\}[a-z]\{1,\}[[:space:]]\{1,\}\([A-Za-z0-9_.-]\{1,\}\).*/\1/p')
			[ -n "$_svc" ] || _svc=$(printf '%s' "$_cmd" | sed -n 's#.*/etc/init.d/\([A-Za-z0-9_.-]\{1,\}\).*#\1#p')
			[ -n "$_svc" ] && [ -x "/etc/init.d/$_svc" ] || continue
			if _svc_running "$_svc"; then
				_apply_leds "$(uci -q get "$CFG.$_s.leds_on_$_st")"
			else
				_apply_leds "$(uci -q get "$CFG.$_s.leds_off_$_st")"
			fi
		done
	done
}

case "$1" in
detect)
	_jf() { printf '%s' "$(uci -q get "$CFG.$1.$2" 2>/dev/null)" | _json_esc; }
	printf '{"buttons":['
	_f=1
	_dts_buttons | sort -u | while IFS='	' read -r _name _label _type; do
		[ -n "$_name" ] || continue
		[ -n "$_type" ] || _type=button
		_def=0; _is_system "$_name" && _def=1
		_s=$(_sid "$_name")
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '{"name":"%s","label":"%s","type":"%s","default":%d,"btntype":"%s","debounce":"%s"' \
			"$_name" "$(printf '%s' "$_label" | _json_esc)" "$_type" "$_def" \
			"$(_jf "$_s" btntype)" "$(_jf "$_s" debounce)"
		for _st in pressed released; do
			printf ',"ct_%s":"%s","cmd_%s":"%s","svc_%s":"%s"' \
				"$_st" "$(_jf "$_s" "ct_$_st")" \
				"$_st" "$(_jf "$_s" "$_st")" \
				"$_st" "$(_jf "$_s" "svc_$_st")"
			printf ',"leds_%s":"%s","ledson_%s":"%s","ledsoff_%s":"%s"' \
				"$_st" "$(_jf "$_s" "leds_$_st")" \
				"$_st" "$(_jf "$_s" "leds_on_$_st")" \
				"$_st" "$(_jf "$_s" "leds_off_$_st")"
		done
		printf '}'
	done
	printf ']}\n'
	;;
services)
	printf '{"services":['
	_f=1
	for _sv in /etc/init.d/*; do
		[ -f "$_sv" ] && [ -x "$_sv" ] || continue
		_n=$(basename "$_sv")
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '"%s"' "$(printf '%s' "$_n" | _json_esc)"
	done
	printf ']}\n'
	;;
set)
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	case "$3" in pressed|released|debounce|type_override|btntype|ct_pressed|ct_released|svc_pressed|svc_released) ;; *) echo '{"error":"bad field"}'; exit 0 ;; esac
	_s=$(_sid "$2")
	uci -q get "$CFG.$_s" >/dev/null 2>&1 || uci -q set "$CFG.$_s=button"
	uci -q set "$CFG.$_s.name=$2"
	if [ -z "$4" ]; then
		uci -q delete "$CFG.$_s.$3" 2>/dev/null
	else
		uci -q set "$CFG.$_s.$3=$4"
	fi
	uci -q commit "$CFG"
	echo '{"ok":1}'
	;;
del)
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	uci -q delete "$CFG.$(_sid "$2")" 2>/dev/null
	uci -q commit "$CFG"
	echo '{"ok":1}'
	;;
leds)
	printf '{"leds":['
	_f=1
	for _d in "$LEDS_DIR"/*; do
		[ -d "$_d" ] || continue
		[ -e "$_d/brightness" ] || continue
		_n=$(basename "$_d")
		_led_dummy "$_n" && continue
		_b=$(cat "$_d/brightness" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
		_on=0; [ "$_b" -gt 0 ] && _on=1
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '{"name":"%s","color":"%s","on":%d}' \
			"$(printf '%s' "$_n" | _json_esc)" "$(_led_color "$_n")" "$_on"
	done
	printf ']}\n'
	;;
setleds)
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	case "$3" in pressed|released|on_pressed|off_pressed|on_released|off_released) ;; *) echo '{"error":"bad action"}'; exit 0 ;; esac
	_s=$(_sid "$2")
	uci -q get "$CFG.$_s" >/dev/null 2>&1 || uci -q set "$CFG.$_s=button"
	uci -q set "$CFG.$_s.name=$2"
	if [ -z "$4" ]; then
		uci -q delete "$CFG.$_s.leds_$3" 2>/dev/null
	else
		uci -q set "$CFG.$_s.leds_$3=$4"
	fi
	uci -q commit "$CFG"
	if [ -n "$4" ]; then
		note_foreign_uci system "buttons leds"
		_any=0
		for _kv in $4; do
			_ln="${_kv%=*}"
			_led_dummy "$_ln" && continue
			[ -e "$LEDS_DIR/$_ln/brightness" ] || continue
			_led_detach "$_ln"; _any=1
		done
		[ "$_any" = 1 ] && { uci -q commit system; /etc/init.d/led reload 2>/dev/null; _sync_leds_all; }
	fi
	echo '{"ok":1}'
	;;
applyleds)
	_apply_leds "$2"
	echo '{"ok":1}'
	;;
run)
	[ -n "$2" ] || exit 0
	case "$3" in pressed|released) ;; *) exit 0 ;; esac
	_s=$(_sid "$2")
	_st="$3"
	_ct=$(uci -q get "$CFG.$_s.ct_$_st")

	_dbc=$(uci -q get "$CFG.$_s.debounce")
	case "$_dbc" in ''|*[!0-9]*) _dbc=0 ;; esac
	if [ "$_dbc" -gt 0 ]; then
		_m="/tmp/5gmodem/btndbc_${_s}_$_st"
		_now=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
		_last=$(cat "$_m" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
		[ "$_last" -gt 0 ] && [ "$((_now - _last))" -lt "$_dbc" ] && exit 0
	fi

	_cmd=$(uci -q get "$CFG.$_s.$_st")
	[ -n "$_cmd" ] && ! cmd_allowed "$_cmd" && _cmd=''

	if [ "$_ct" = "conditional" ]; then
		_svc=$(printf '%s' "$_cmd" | sed -n 's/.*svc[[:space:]]\{1,\}[a-z]\{1,\}[[:space:]]\{1,\}\([A-Za-z0-9_.-]\{1,\}\).*/\1/p')
		[ -n "$_svc" ] || _svc=$(printf '%s' "$_cmd" | sed -n 's#.*/etc/init.d/\([A-Za-z0-9_.-]\{1,\}\).*#\1#p')
		[ "$_dbc" -gt 0 ] && echo "$_now" > "$_m" 2>/dev/null
		if [ -n "$_svc" ] && [ -x "/etc/init.d/$_svc" ]; then
			if _svc_running "$_svc"; then
				_apply_leds "$(uci -q get "$CFG.$_s.leds_off_$_st")"
			else
				_apply_leds "$(uci -q get "$CFG.$_s.leds_on_$_st")"
			fi
		fi
		[ -n "$_cmd" ] && BUTTON="$2" ACTION="$_st" SEEN="$4" sh -c "$_cmd"
		exit 0
	fi

	_leds=$(uci -q get "$CFG.$_s.leds_$_st")
	[ -n "$_cmd$_leds" ] || exit 0
	[ "$_dbc" -gt 0 ] && echo "$_now" > "$_m" 2>/dev/null
	[ -n "$_leds" ] && _apply_leds "$_leds"
	[ -n "$_cmd" ] && BUTTON="$2" ACTION="$_st" SEEN="$4" sh -c "$_cmd"
	;;
syncleds)
	_sync_leds_all
	;;
svc)
	[ -n "$3" ] || { echo "usage: svc <toggle|start|stop|restart> <service>"; exit 1; }
	[ -x "/etc/init.d/$3" ] || { echo "no such service: $3"; exit 1; }
	case "$2" in
		toggle)
			if _svc_running "$3"; then /etc/init.d/"$3" stop; /etc/init.d/"$3" disable
			else /etc/init.d/"$3" enable; /etc/init.d/"$3" start; fi ;;
		start)   /etc/init.d/"$3" enable;  /etc/init.d/"$3" start ;;
		stop)    /etc/init.d/"$3" stop;    /etc/init.d/"$3" disable ;;
		restart) /etc/init.d/"$3" restart ;;
		*) echo "usage: svc <toggle|start|stop|restart> <service>"; exit 1 ;;
	esac
	;;
*)
	echo '{"error":"usage: detect|set|run"}'
	;;
esac
