#!/bin/sh

android_adb() {
	adb "$@" 2>/dev/null 6>&- 7>&- 8>&- 9>&- &
	_ad_pid=$!
	( sleep 8 & _ws=$!; trap 'kill $_ws 2>/dev/null; exit' TERM; wait $_ws; kill -KILL "$_ad_pid" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
	_ad_watch=$!
	wait "$_ad_pid" 2>/dev/null
	_ad_rc=$?
	kill "$_ad_watch" 2>/dev/null
	wait "$_ad_watch" 2>/dev/null
	return "$_ad_rc"
}

android_usb_serial() {
	case "$1" in ''|*[!0-9.:_-]*) return 1 ;; esac
	_ad_usb="/sys/bus/usb/devices/$1"
	_ad_serial=$(cat "$_ad_usb/serial" 2>/dev/null)
	case "$_ad_serial" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
	_ad_has=0
	for _ad_i in "$_ad_usb":*; do
		[ "$(cat "$_ad_i/bInterfaceClass" 2>/dev/null)" = ff ] \
			&& [ "$(cat "$_ad_i/bInterfaceSubClass" 2>/dev/null)" = 42 ] \
			&& [ "$(cat "$_ad_i/bInterfaceProtocol" 2>/dev/null)" = 01 ] && _ad_has=1
	done
	[ "$_ad_has" = 1 ] || return 1
	printf '%s\n' "$_ad_serial"
}

android_json() {
	_ad_serial=$(android_usb_serial "$1") || return 1
	_ad_usb="/sys/bus/usb/devices/$1"
	[ "$(android_adb -s "$_ad_serial" get-state)" = device ] || return 1
	_ad_hash=$(md5sum "$RES/android-probe.sh" | cut -d' ' -f1)
	_ad_marker="/tmp/5gmodem/android_probe_$_ad_serial"
	if [ "$(cat "$_ad_marker" 2>/dev/null)" != "$_ad_hash" ]; then
		android_adb -s "$_ad_serial" push "$RES/android-probe.sh" /data/local/tmp/5gmodem-probe.sh >/dev/null || return 1
		mkdir -p /tmp/5gmodem
		printf '%s' "$_ad_hash" > "$_ad_marker"
	fi
	_ad_dump=$(android_adb -s "$_ad_serial" shell 'sh /data/local/tmp/5gmodem-probe.sh') \
		|| { rm -f "$_ad_marker"; return 1; }
	_ad_json=$(printf '%s\n' "$_ad_dump" | awk -v path="$1" -v iface="$2" -v ip="$3" -v netdev="$4" \
		-v vidpid="$(cat "$_ad_usb/idVendor"):$(cat "$_ad_usb/idProduct")" \
		-v sampled_at="$(date +%s)" -f "$RES/android-metrics.awk") || return 1
	if [ -f "$RES/android-cells.dex" ] && command -v jsonfilter >/dev/null 2>&1; then
		_ad_extra=$(android_cells "$1" "$_ad_json" "$_ad_serial") && _ad_json="${_ad_json%?},${_ad_extra#?}"
	fi
	printf '%s\n' "$_ad_json"
}

android_cell_fields() {
	for _acf_key in "$@"; do
		printf '|%s' "$(jsonfilter -s "$_ac_raw" -e "$_ac_root.$_acf_key" 2>/dev/null)"
	done
	printf '\n'
}

# $2: serial whose ADB state the caller has just checked (android_json), saving one adb round trip per poll.
android_cells_ready() {
	if [ -n "$2" ]; then
		_ar_serial=$2
	else
		_ar_serial=$(android_usb_serial "$1") || return 1
		[ "$(android_adb -s "$_ar_serial" get-state)" = device ] || return 1
	fi
	_ar_hash=$(md5sum "$RES/android-cells.dex" | cut -d' ' -f1)
	_ar_marker="/tmp/5gmodem/android_cells_$_ar_serial"
	if [ "$(cat "$_ar_marker" 2>/dev/null)" != "$_ar_hash" ]; then
		android_adb -s "$_ar_serial" shell 'rm -f /data/local/tmp/5gmodem-cells.dex' >/dev/null || return 1
		android_adb -s "$_ar_serial" push "$RES/android-cells.dex" /data/local/tmp/5gmodem-cells.dex >/dev/null || return 1
		android_adb -s "$_ar_serial" shell 'chmod 444 /data/local/tmp/5gmodem-cells.dex' >/dev/null || return 1
		mkdir -p /tmp/5gmodem
		printf '%s' "$_ar_hash" > "$_ar_marker"
	fi
	printf '%s\n' "$_ar_serial"
}

android_cells() {
	_ac_serial=$(android_cells_ready "$1" "$3") || return 1
	_ac_marker="/tmp/5gmodem/android_cells_$_ac_serial"
	_ac_sub=$(jsonfilter -s "$2" -e '@.android_data_subscription' 2>/dev/null)
	case "$_ac_sub" in ''|*[!0-9]*) return 1 ;; esac
	_ac_raw=$(android_adb -s "$_ac_serial" shell "CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe $_ac_sub") \
		|| { rm -f "$_ac_marker"; return 1; }
	_ac_elapsed=$(jsonfilter -s "$_ac_raw" -e '@.elapsed_ms' 2>/dev/null)
	case "$_ac_elapsed" in ''|*[!0-9]*) return 1 ;; esac
	_ac_returned=$(jsonfilter -s "$_ac_raw" -e '@.subscriptions[0].sub_id' 2>/dev/null)
	[ "$_ac_returned" = "$_ac_sub" ] || return 1
	_ac_pci=$(jsonfilter -s "$2" -e '@.pci' 2>/dev/null)
	_ac_ear=$(jsonfilter -s "$2" -e '@.earfcn' 2>/dev/null)
	{
		printf 'META|%s|%s|%s\n' "$_ac_elapsed" "$_ac_pci" "$_ac_ear"
		_ac_root='@.subscriptions[0]'
		printf IDENTITY
		android_cell_fields imsi iccid imei
		printf 'CAPABILITY|%s\n' "$(jsonfilter -s "$_ac_raw" -e '@.can_switch_data' 2>/dev/null)"
		printf 'IMS|%s|%s\n' "$(jsonfilter -s "$_ac_raw" -e '@.subscriptions[0].volte' 2>/dev/null)" "$(jsonfilter -s "$_ac_raw" -e '@.subscriptions[0].wfc' 2>/dev/null)"
		for _ac_i in 0 1 2 3 4 5; do
			_ac_root="@.subscriptions[0].registrations[$_ac_i]"
			[ "$(jsonfilter -s "$_ac_raw" -e "$_ac_root.transport" 2>/dev/null)" = 1 ] || continue
			case "$(jsonfilter -s "$_ac_raw" -e "$_ac_root.domain" 2>/dev/null)" in 2|3) ;; *) continue ;; esac
			printf SERVICE
			android_cell_fields identity.type identity.ci identity.cid identity.tac identity.lac identity.pci identity.earfcn
		done
		_ac_n=0
		while [ "$_ac_n" -lt 64 ]; do
			_ac_root="@.subscriptions[0].cells[$_ac_n]"
			_ac_type=$(jsonfilter -s "$_ac_raw" -e "$_ac_root.identity.type" 2>/dev/null)
			[ -n "$_ac_type" ] || break
			printf CELL
			android_cell_fields registered timestamp_ns identity.type identity.ci identity.cid identity.tac identity.lac identity.pci identity.earfcn 'identity.bands[0]' rssi rsrp rsrq sinr identity.nrarfcn identity.nci ss_rsrp ss_rsrq ss_sinr status
			_ac_n=$((_ac_n + 1))
		done
	} | awk -f "$RES/android-cells.awk"
}

android_slots() {
	case "$2" in
		status|'') _as_command=slots ;;
		set)
			case "$3" in ''|*[!0-9]*) echo '{"error":"bad slot"}'; return 1 ;; esac
			[ "$3" -ge 1 ] && [ "$3" -le 8 ] || { echo '{"error":"bad slot"}'; return 1; }
			_as_command="set-data $3" ;;
		*) echo '{"error":"bad action"}'; return 1 ;;
	esac
	_as_serial=$(android_cells_ready "$1") || { echo '{"error":"Android ADB unavailable","slots":[],"writable":false}'; return 1; }
	_as_result=$(android_adb -s "$_as_serial" shell "CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe $_as_command") \
		|| { echo '{"error":"Android SIM request failed"}'; return 1; }
	[ "$(jsonfilter -s "$_as_result" -e '@.type' 2>/dev/null)" = android ] \
		|| {
		jsonfilter -s "$_as_result" -e '@' >/dev/null 2>&1 || _as_result='{"error":"Android SIM request failed"}'
		printf '%s\n' "$_as_result"; return 1
	}
	if [ "$2" = set ]; then
		[ "$(jsonfilter -s "$_as_result" -e '@.ok' 2>/dev/null)" = true ] || { printf '%s\n' "$_as_result"; return 1; }
		_as_key=$(printf '%s\n' "$1" | tr -c 'A-Za-z0-9' '_')
		rm -f "/tmp/5gmodem/metrics_$_as_key.json" "/tmp/5gmodem/metrics_$_as_key.stamp" \
			"/tmp/5gmodem/slots_$1" "/tmp/5gmodem/slots_$1.t" "/tmp/5gmodem/slots_$1.upd"
	fi
	printf '%s\n' "$_as_result"
}

# ---- Network mode and bands -------------------------------------------------------------------
# Everything below acts on the active data subscription and uses the same DEX helper as the SIM
# switch. Output of the helper is a short line protocol that android-radio.awk understands.

android_sec() {
	printf 'm_%s\n' "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"
}

# The band lists belong to one phone: another phone on the same USB port (the section is named after the port) must
# learn its own, so a list is only used together with the serial of the phone it was read from.
android_caps() {
	_acx_c=$(uci -q get "5gmodem.$(android_sec "$1").android_caps")
	[ -n "$_acx_c" ] || return 0
	_acx_for=$(uci -q get "5gmodem.$(android_sec "$1").android_caps_for")
	[ -n "$_acx_for" ] && [ "$_acx_for" = "$(android_usb_serial "$1")" ] && printf '%s\n' "$_acx_c"
	return 0
}

android_caps_store() {
	[ -n "$2" ] || return 0
	_acs_serial=$(android_usb_serial "$1") || return 0
	_acs_sec=$(android_sec "$1")
	uci -q set "5gmodem.$_acs_sec.android_caps=$2" && uci -q set "5gmodem.$_acs_sec.android_caps_for=$_acs_serial" \
		&& uci -q commit 5gmodem
}

android_radio() {
	_rd_serial=$(android_cells_ready "$1") || { echo 'ERROR|Android ADB unavailable'; return 1; }
	_rd_action=$2; shift 2
	case "$_rd_action" in
		info) _rd_cmd='radio active' ;;
		reset-bands) _rd_cmd='reset-bands active' ;;
		set-mode)
			case "$1" in ''|*[!0-9]*) echo 'ERROR|bad mask'; return 1 ;; esac
			_rd_cmd="set-mode active $1" ;;
		set-bands)
			[ "$#" -ge 1 ] || { echo 'ERROR|no bands'; return 1; }
			for _rd_a in "$@"; do
				case "$_rd_a" in [1236]=[0-9]*) ;; *) echo 'ERROR|bad bands'; return 1 ;; esac
				case "${_rd_a#*=}" in *[!0-9,]*|,*|*,|*,,*) echo 'ERROR|bad bands'; return 1 ;; esac
			done
			_rd_cmd="set-bands active $*" ;;
		*) echo 'ERROR|bad action'; return 1 ;;
	esac
	_rd_out=$(android_adb -s "$_rd_serial" shell "CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe $_rd_cmd") \
		|| { rm -f "/tmp/5gmodem/android_cells_$_rd_serial"; echo 'ERROR|Android radio request failed'; return 1; }
	printf '%s\n' "$_rd_out" | tr -d '\r' | grep -E '^(SUB|WRITABLE|ALLOWED|RAT|DATA|DATA_ENABLED|BANDS|BANDS_UNSUPPORTED|ERROR)[|]|^__5GM_RADIO_END__$'
	return 0
}

# A reset readback is the modem's own band list: it is stored once and used as the list of supported bands. A phone
# whose modem does not answer the band API (Samsung's Exynos modem) is not written to: the readback carries
# BANDS_UNSUPPORTED, the stored "list" only remembers whether NR is allowed, and only the network mode is offered.
android_radio_json() {
	_rj_caps=$(android_caps "$1")
	_rj_raw=""
	if [ -z "$_rj_caps" ]; then
		_rj_raw=$(android_radio "$1" reset-bands)
		_rj_caps=$(printf '%s\n' "$_rj_raw" | awk -v mode=caps -f "$RES/android-radio.awk" 2>/dev/null) \
			&& android_caps_store "$1" "$_rj_caps" || { _rj_raw=""; _rj_caps=""; }
	fi
	[ -n "$_rj_raw" ] || _rj_raw=$(android_radio "$1" info)
	printf '%s\n' "$_rj_raw" | awk -v caps="$_rj_caps" -v model="$2" -f "$RES/android-radio.awk"
}

android_radio_ok() {
	case "$1" in *'ERROR|'*|'') return 1 ;; esac
	case "$1" in *__5GM_RADIO_END__*) return 0 ;; esac
	return 1
}

# Changing the allowed network types or the bands makes the modem select a network again. With 2G allowed it can end
# up camped on GSM/EDGE with a dead data bearer, or on LTE with a bearer that never comes back. Only then it is
# helped: a short radio off/on re-selects the network, and a data off/on restarts the bearer. The decision is based
# on the state read back from the phone (Android may filter a requested mask). Runs detached, one run per phone;
# a further change while it runs makes it start over instead of starting a second one. $2 is the run's lock directory.
android_mode_settle() {
	sleep 12
	_ms_reselected=0; _ms_force=0; _ms_waited=0; _ms_restarts=0; _ms_round=0
	while [ "$_ms_round" -lt 10 ]; do
		_ms_round=$((_ms_round + 1))
		if [ -f "$2/again" ]; then
			rm -f "$2/again"
			_ms_reselected=0; _ms_force=0; _ms_waited=0; _ms_restarts=0; _ms_round=1
			sleep 12
		fi
		_ms_raw=$(android_radio "$1" info) || return 0
		android_radio_ok "$_ms_raw" || return 0
		_ms_rat=$(printf '%s\n' "$_ms_raw" | sed -n 's/^RAT|//p')
		_ms_now=$(printf '%s\n' "$_ms_raw" | sed -n 's/^ALLOWED|//p')
		_ms_state=$(printf '%s\n' "$_ms_raw" | sed -n 's/^DATA|//p')
		_ms_enabled=$(printf '%s\n' "$_ms_raw" | sed -n 's/^DATA_ENABLED|//p')
		# On 2G while LTE or NR is allowed the bearer reports "connected" but carries nothing, so the type decides.
		_ms_stuck=0
		case "$_ms_rat" in
			1|2|16) [ $(( ((_ms_now / 4096) % 2) + ((_ms_now / 524288) % 2) )) -gt 0 ] && _ms_stuck=1 ;;
		esac
		# A bearer that was created while the modem sat on 2G stays "connected" but dead: restart it after a reselection.
		if [ "$_ms_stuck" = 0 ] && [ "$_ms_state" = 2 ] && [ "$_ms_force" = 0 ]; then
			[ -f "$2/again" ] || return 0
			continue
		fi
		_ms_serial=$(android_usb_serial "$1") || return 0
		_ms_pause=15
		if [ "$_ms_stuck" = 1 ]; then
			if [ "$_ms_reselected" = 1 ]; then
				# Still on 2G after a reselection: give the modem a little while, then conclude there is no LTE here.
				_ms_waited=$((_ms_waited + 1))
				[ "$_ms_waited" -lt 3 ] || return 0
			else
				_ms_reselected=1
				_ms_force=1
				logger -t 5gmodem "android: modem camped on 2G after a radio change, reselecting the network"
				android_adb -s "$_ms_serial" shell 'cmd connectivity airplane-mode enable' >/dev/null
				sleep 6
				for _ms_try in 1 2 3; do
					android_adb -s "$_ms_serial" shell 'cmd connectivity airplane-mode disable' >/dev/null && break
					sleep 2
				done
			fi
		else
			# Only a registered 3G/4G/5G connection is restarted; searching or deliberate 2G is left alone.
			case "$_ms_rat" in ''|0|1|2|16) ;; *)
				[ "$_ms_enabled" = 1 ] || return 0
				[ "$_ms_restarts" -lt 2 ] || return 0
				_ms_restarts=$((_ms_restarts + 1))
				_ms_force=0
				logger -t 5gmodem "android: mobile data did not come back after a radio change, restarting it"
				android_adb -s "$_ms_serial" shell 'cmd phone data disable' >/dev/null
				sleep 3
				for _ms_try in 1 2 3; do
					android_adb -s "$_ms_serial" shell 'cmd phone data enable' >/dev/null && break
					sleep 2
				done
				# The connection needs well over 15 s to come up: do not interrupt it with another restart.
				_ms_pause=40 ;;
			esac
		fi
		sleep "$_ms_pause"
	done
	return 0
}

android_mode_recover() {
	_mr_lock="/tmp/5gmodem/android_recover_$(android_sec "$1")"
	mkdir -p /tmp/5gmodem 2>/dev/null
	_mr_up=$(cut -d. -f1 /proc/uptime)
	if ! mkdir "$_mr_lock" 2>/dev/null; then
		_mr_t=$(cat "$_mr_lock/t" 2>/dev/null)
		case "$_mr_t" in ''|*[!0-9]*) _mr_t=0 ;; esac
		if [ $((_mr_up - _mr_t)) -lt 600 ]; then
			: > "$_mr_lock/again" 2>/dev/null
			return 0
		fi
		rm -rf "$_mr_lock"
		mkdir "$_mr_lock" 2>/dev/null || return 0
	fi
	echo "$_mr_up" > "$_mr_lock/t"
	android_mode_settle "$1" "$_mr_lock"
	rm -rf "$_mr_lock" 2>/dev/null
	return 0
}

android_set_mode() {
	_sm_mask=$(awk -v mode=mask -v want="$2" -v caps="$(android_caps "$1")" -f "$RES/android-radio.awk" </dev/null 2>/dev/null) \
		|| { echo '{"error":"unsupported network mode"}'; return 1; }
	_sm_out=$(android_radio "$1" set-mode "$_sm_mask")
	android_radio_ok "$_sm_out" || { printf '{"error":"%s"}\n' "$(printf '%s\n' "$_sm_out" | sed -n 's/^ERROR|//p' | head -1 | tr -d '"\\')"; return 1; }
	( android_mode_recover "$1" ) >/dev/null 2>&1 </dev/null &
	printf '{"ok":true,"allowed_types":"%s"}\n' "$(printf '%s\n' "$_sm_out" | sed -n 's/^ALLOWED|//p')"
}

# $2 lte  $3 5G NR  $4 3G  $5 2G: each empty (leave), "default" (reset) or a space separated band list.
android_set_bands() {
	_ab_caps=$(android_caps "$1")
	_ab_lte=$2; _ab_nsa=$3; _ab_3g=$4; _ab_2g=$5
	_ab_reset=0
	for _ab_v in "$_ab_lte" "$_ab_nsa" "$_ab_3g" "$_ab_2g"; do [ "$_ab_v" = default ] && _ab_reset=1; done
	[ "$_ab_lte" = default ] && _ab_lte=""; [ "$_ab_nsa" = default ] && _ab_nsa=""
	[ "$_ab_3g" = default ] && _ab_3g=""; [ "$_ab_2g" = default ] && _ab_2g=""
	_ab_args=$(awk -v mode=bands -v caps="$_ab_caps" -v sel_lte="$_ab_lte" -v sel_nsa="$_ab_nsa" -v sel_3g="$_ab_3g" -v sel_2g="$_ab_2g" \
		-f "$RES/android-radio.awk" </dev/null 2>/dev/null) || return 2
	[ "$_ab_args" = RESET ] && { _ab_reset=1; _ab_args=""; }
	if [ "$_ab_reset" = 1 ]; then
		_ab_out=$(android_radio "$1" reset-bands)
		android_radio_ok "$_ab_out" || return 1
		[ -n "$_ab_args" ] || { ( android_mode_recover "$1" ) >/dev/null 2>&1 </dev/null & return 0; }
	fi
	[ -n "$_ab_args" ] || return 0
	# shellcheck disable=SC2086
	_ab_out=$(android_radio "$1" set-bands $_ab_args)
	android_radio_ok "$_ab_out" || return 1
	( android_mode_recover "$1" ) >/dev/null 2>&1 </dev/null &
	return 0
}

android_sms() {
	_as_serial=$(android_usb_serial "$1") || { echo '{"error":"Android ADB unavailable","read_only":true}'; return 1; }
	[ "$(android_adb -s "$_as_serial" get-state)" = device ] || { echo '{"error":"Android ADB unauthorized","read_only":true}'; return 1; }
	_as_count=0
	_as_projection='_id:sub_id:type:read:seen:date:hex(address) AS address_hex:hex(body) AS body_hex'
	case "$2" in
		inbox) _as_type=1 ;;
		sent) _as_type=2 ;;
		count) _as_type=1; _as_count=1; _as_projection='_id:read:seen' ;;
		*) echo '{"error":"Android SMS is read-only","read_only":true}'; return 1 ;;
	esac
	_as_dump=$(android_adb -s "$_as_serial" shell "content query --uri content://sms --projection '$_as_projection' --where 'type=$_as_type'; printf '__5GM_SMS_END__\\n'") 		|| { echo '{"error":"Android SMS query timed out","read_only":true}'; return 1; }
	printf '%s\n' "$_as_dump" | LC_ALL=C awk -v count_only="$_as_count" -f "$RES/android-sms.awk"
}

if [ "${0##*/}" = android.sh ]; then
	RES=${RES:-/usr/share/5gmodem}
	case "$1" in
		json) shift; android_json "$@" ;;
		slots) shift; android_slots "$@" ;;
		sms) shift; android_sms "$@" ;;
		*) echo 'usage: android.sh {json <usb-path> [iface] [ip] [netdev]|slots <usb-path> [status|set N]|sms <usb-path> inbox|sent|count}' >&2; exit 1 ;;
	esac
fi
