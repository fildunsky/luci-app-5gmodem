#!/bin/sh

SIMWAIT_DIR=/tmp/5gmodem/simwait

simwait_at_state() {
	local answer
	answer=$(
		exec 5>&- 6>&- 7>&- 8>&- 9>&-
		AT_QUERY_RAW=1 at_query "$1" 'AT+CPIN?' 4 1 2>/dev/null | tr -d '\r'
	)
	printf '%s\n' "$answer" | awk '
		/^\+CPIN: *(READY|SIM PIN2|SIM PUK2)[[:space:]]*$/ { state="ready" }
		/^\+CPIN: *SIM PIN[[:space:]]*$/ { state="pin" }
		/^\+CPIN: *SIM PUK[[:space:]]*$/ { state="locked" }
		/^\+CME ERROR: *10[[:space:]]*$/ { state="absent" }
		{ line=tolower($0); if (line ~ /sim not inserted|sim_absent/) state="absent" }
		END { print state ? state : "unknown" }
	'
}

simwait_run() {
	local timeout="$1"; shift
	"$@" 2>/dev/null 5>&- 6>&- 7>&- 8>&- 9>&- &
	local child=$! timer result
	( exec >/dev/null 2>&1 5>&- 6>&- 7>&- 8>&- 9>&-; sleep "$timeout" & timer=$!; trap 'kill "$timer" 2>/dev/null; exit' TERM; wait "$timer"; kill -9 "$child" 2>/dev/null ) </dev/null &
	timer=$!
	wait "$child"; result=$?
	kill "$timer" 2>/dev/null; wait "$timer" 2>/dev/null
	return "$result"
}

simwait_control_state() {
	local interface="$1" path="$2" device proto real answer
	device=$(uci -q get "network.$interface.device")
	case "$device" in /dev/*) ;; *) echo unknown; return ;; esac
	real=$(readlink -f "/sys/class/usbmisc/${device##*/}/device" 2>/dev/null)
	[ -n "$real" ] || real=$(readlink -f "/sys/class/wwan/${device##*/}/device" 2>/dev/null)
	case "$real" in */"$path"/*|*/"$path":*/*) ;; *) echo unknown; return ;; esac
	if pgrep -x uqmi >/dev/null 2>&1 || pgrep -x umbim >/dev/null 2>&1 \
		|| pgrep -x qmicli >/dev/null 2>&1 || pgrep -x mbimcli >/dev/null 2>&1 \
		|| pgrep -x lpac >/dev/null 2>&1; then
		echo unknown; return
	fi
	proto=$(uci -q get "network.$interface.proto")
	case "$proto" in
		qmi|qmiraw)
			answer=$(simwait_run 5 uqmi -s -d "$device" -t 2000 --uim-get-sim-state)
			case "$(printf '%s' "$answer" | jsonfilter -e '@.card_state' 2>/dev/null)" in
				absent) echo absent; return ;;
			esac
			case "$(printf '%s' "$answer" | jsonfilter -e '@.card_application_state' 2>/dev/null)" in
				ready) echo ready; return ;;
				pin-required|pin1_or_upin_required) echo pin; return ;;
				puk-required|puk1_or_upuk_required) echo locked; return ;;
			esac
			if command -v qmicli >/dev/null 2>&1 && ! pgrep -x qmi-proxy >/dev/null 2>&1; then
				answer=$(simwait_run 5 qmicli -d "$device" --uim-get-card-status)
				if printf '%s\n' "$answer" | awk '
					/Card state:/ {
						count++
						if ($0 !~ /Card state:[[:space:]]*\047absent\047[[:space:]]*$/) other++
					}
					END { exit !(count > 0 && other == 0) }
				'; then
					echo absent; return
				fi
			fi ;;

		mbim)
			answer=$(simwait_run 5 umbim -d "$device" subscriber)
			case "$(printf '%s\n' "$answer" | sed -n 's/^[[:space:]]*readystate: *[0-9]* *(\([^)]*\)).*/\1/p' | head -1)" in
				initialized) echo ready; return ;;
				sim-not-inserted) echo absent; return ;;
				device-locked) echo locked; return ;;
			esac ;;
		mbimp)
			answer=$(simwait_run 5 mbimcli -p -d "$device" --query-subscriber-ready-status)
			case "$(printf '%s\n' "$answer" | sed -n "s/^[[:space:]]*Ready state: *'\([^']*\)'.*/\1/p" | head -1)" in
				initialized) echo ready; return ;;
				sim-not-inserted) echo absent; return ;;
				device-locked) echo locked; return ;;
			esac ;;
	esac
	echo unknown
}

simwait_state() {
	local section="$1" path="$2" port="$3" owner="$4" answer index state interface
	interface=$(uci -q get "5gmodem.$section.network")
	if [ "$(uci -q get "5gmodem.$section.kind")" = hilink ]; then
		answer=$(/usr/share/5gmodem/hilink.sh json "$path" 2>/dev/null)
		state=$(printf '%s' "$answer" | jsonfilter -e '@.registration' 2>/dev/null)
		case "$state" in
			'SIM not inserted') echo absent; return ;;
			*PIN2*|*PUK2*) echo ready; return ;;
			*PIN*) echo pin; return ;;
			*PUK*) echo locked; return ;;
		esac
		case "$(printf '%s' "$answer" | jsonfilter -e '@.sim_status' 2>/dev/null)" in
			0|255) echo absent; return ;;
			1) echo ready; return ;;
		esac
		echo unknown; return
	fi
	if [ "$owner" = mm ] || { command -v mm_owns_path >/dev/null 2>&1 && mm_owns_path "$path"; }; then
		index=$(/usr/share/5gmodem/modemswitch.sh mmindex "$path" 2>/dev/null)
		case "$index" in ''|*[!0-9]*) echo unknown; return ;; esac
		answer=$(simwait_run 6 mmcli -m "$index" -K --timeout=4)
		case "$answer" in
			*'sim-missing'*) echo absent; return ;;
		esac
		state=$(printf '%s\n' "$answer" | sed -n 's/^modem.generic.unlock-required *: *//p' | head -1)
		case "$state" in
			sim-pin) echo pin; return ;;
			sim-puk) echo locked; return ;;
			none|sim-pin2|sim-puk2) printf '%s\n' "$answer" | grep -qE '^modem.generic.sim *: */org/freedesktop/ModemManager1/SIM/' && { echo ready; return; } ;;
		esac
		echo unknown; return
	fi
	case "$port" in
		/dev/*)
			if [ "$(tty_usbpath "$port" 2>/dev/null)" = "$path" ]; then
				state=$(simwait_at_state "$port")
				[ "$state" = unknown ] || { echo "$state"; return; }
			fi ;;
	esac
	simwait_control_state "$interface" "$path"
}

simwait_identity() {
	printf '%s|%s|%s\n' "$2" "$(uci -q get "5gmodem.$1.vidpid")" "$(uci -q get "5gmodem.$1.imei")"
}

simwait_clear() {
	rm -f "$SIMWAIT_DIR/$1" "$SIMWAIT_DIR/$1.blocked"
}

simwait_check_locked() {
	local interface="$1" section="$2" path="$3" port="$4" owner="${5:-}" hint="${6:-}" state identity previous previous_imei current_imei
	case "$interface" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
	case "$section:$path" in *[!A-Za-z0-9_.:-]*) return 0 ;; esac
	identity=$(simwait_identity "$section" "$path")
	previous=$(cat "$SIMWAIT_DIR/$interface" 2>/dev/null)
	if [ -n "$previous" ] && [ "$previous" != "$identity" ]; then
		previous_imei=${previous##*|}
		current_imei=${identity##*|}
		if [ "${previous%|*}" != "${identity%|*}" ] \
			|| { [ -n "$previous_imei" ] && [ -n "$current_imei" ] && [ "$previous_imei" != "$current_imei" ]; }; then
			simwait_clear "$interface"
		fi
	fi
	state=$(simwait_state "$section" "$path" "$port" "$owner")
	case "$state" in absent|ready|locked|pin) ;; *) state=unknown ;; esac
	[ "$state:$hint" != unknown:absent ] || state=absent
	mkdir -p "$SIMWAIT_DIR"
	printf '%s %s\n' "$state" "$(uptime_s)" > "$SIMWAIT_DIR/$interface.status.tmp.$$"
	mv "$SIMWAIT_DIR/$interface.status.tmp.$$" "$SIMWAIT_DIR/$interface.status"
	case "$state" in
		absent)
			rm -f "$SIMWAIT_DIR/$interface.resume"
			mkdir -p "$SIMWAIT_DIR"
			if [ ! -f "$SIMWAIT_DIR/$interface" ]; then
				printf '%s\n' "$identity" > "$SIMWAIT_DIR/$interface.tmp.$$"
				mv "$SIMWAIT_DIR/$interface.tmp.$$" "$SIMWAIT_DIR/$interface"
				logger -t 5gmodem "SIM wait: $interface has no SIM - automatic connection postponed"
			fi
			return 1 ;;
		ready) return 0 ;;
		pin)
			[ -n "$(uci -q get "network.$interface.pincode")" ] && return 0
			[ ! -f "$SIMWAIT_DIR/$interface" ] ;;
		*) [ ! -f "$SIMWAIT_DIR/$interface" ] ;;
	esac
}

simwait_check() (
	local attempt=0
	case "$1" in ''|*[!A-Za-z0-9_-]*) return 0 ;; esac
	mkdir -p "$SIMWAIT_DIR"
	exec 5>"$SIMWAIT_DIR/.lock.$1"
	until flock -n 5; do
		[ "$attempt" -lt 2 ] || { [ ! -f "$SIMWAIT_DIR/$1" ]; return; }
		attempt=$((attempt + 1))
		sleep 1
	done
	simwait_check_locked "$@"
)

simwait_tick_one_locked() {
	local path="$1" section="$2" interface="$3" proto="$4" port="$5" owner="$6"
	local status up pending available autostart error identity state hint
	case "$interface" in ''|-|*[!A-Za-z0-9_-]*) return ;; esac
	[ "$(uci -q get "network.$interface.auto")" != 0 ] && [ "$(uci -q get "network.$interface.disabled")" != 1 ] || return
	usb_path_present "$path" || { simwait_clear "$interface"; return; }
	status=$(ubus call "network.interface.$interface" status 2>/dev/null)
	[ -n "$status" ] || return
	up=$(printf '%s' "$status" | jsonfilter -e '@.up' 2>/dev/null)
	pending=$(printf '%s' "$status" | jsonfilter -e '@.pending' 2>/dev/null)
	autostart=$(printf '%s' "$status" | jsonfilter -e '@.autostart' 2>/dev/null)
	error=$(printf '%s' "$status" | jsonfilter -e '@.errors[0].code' 2>/dev/null)
	available=$(printf '%s' "$status" | jsonfilter -e '@.available' 2>/dev/null)
	if [ "$autostart" != true ] && [ -z "$error" ]; then
		if [ -f "$SIMWAIT_DIR/$interface.blocked" ]; then
			ubus call network.interface notify_proto "{\"interface\":\"$interface\",\"action\":5,\"available\":true}" >/dev/null 2>&1 || return
		fi
		simwait_clear "$interface"
		return
	fi
	[ "$(uci -q get "5gmodem.$section.network")" = "$interface" ] || return
	case "$error" in SIM_MISSING|SIM_NOT_PRESENT|NO_SIM) hint=absent ;; esac
	if ! simwait_check_locked "$interface" "$section" "$path" "$port" "$owner" "$hint"; then
		if [ ! -f "$SIMWAIT_DIR/$interface.blocked" ]; then
			ubus call network.interface notify_proto "{\"interface\":\"$interface\",\"action\":5,\"available\":false}" >/dev/null 2>&1 || return
			ubus call network.interface notify_proto "{\"interface\":\"$interface\",\"action\":3,\"error\":[\"SIM_MISSING\"]}" >/dev/null 2>&1 || return
			: > "$SIMWAIT_DIR/$interface.blocked"
		fi
		return
	fi
	[ -f "$SIMWAIT_DIR/$interface" ] || return
	uptime_s > "$SIMWAIT_DIR/$interface.resume.tmp.$$"
	mv "$SIMWAIT_DIR/$interface.resume.tmp.$$" "$SIMWAIT_DIR/$interface.resume"
	if [ -f "$SIMWAIT_DIR/$interface.blocked" ]; then
		ubus call network.interface notify_proto "{\"interface\":\"$interface\",\"action\":5,\"available\":true}" >/dev/null 2>&1 || return
	fi
	if [ "$up" != true ] && [ "$pending" != true ] && { [ "$autostart" != true ] || [ "$available" != false ]; }; then
		ubus call network.interface up "{\"interface\":\"$interface\"}" >/dev/null 2>&1 || return
	fi
	simwait_clear "$interface"
	rm -f "/tmp/5gmodem/health/$interface.heal" "/tmp/5gmodem/health/$interface.nosim" "/tmp/5gmodem/health/$interface.srch" "/tmp/5gmodem/sw_last_$interface"
	logger -t 5gmodem "SIM wait: $interface SIM ready - starting normal connection"
}

simwait_tick_one() (
	case "$3" in ''|-|*[!A-Za-z0-9_-]*) return ;; esac
	mkdir -p "$SIMWAIT_DIR"
	exec 5>"$SIMWAIT_DIR/.lock.$3"
	flock -n 5 || return 0
	simwait_tick_one_locked "$@"
)

simwait_check_interface() {
	local wanted="$1" path section interface proto port owner
	while read -r path section interface proto port owner; do
		[ "$interface" = "$wanted" ] || continue
		simwait_check "$interface" "$section" "$path" "$port" "$owner"
		return $?
	done <<EOF_REGISTRY
$(/usr/share/5gmodem/registry.sh flat 2>/dev/null)
EOF_REGISTRY
	return 0
}

simwait_recovering() {
	local stamp now
	case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	[ -r "$SIMWAIT_DIR/$1.resume" ] || return 1
	read -r stamp < "$SIMWAIT_DIR/$1.resume"
	case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
	now=$(uptime_s)
	[ "$now" -ge "$stamp" ] && [ $((now - stamp)) -lt 120 ]
}

simwait_blocked() {
	local state stamp
	case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
	[ -f "$SIMWAIT_DIR/$1" ] || return 1
	state=unknown
	if [ -r "$SIMWAIT_DIR/$1.status" ]; then
		read -r state stamp < "$SIMWAIT_DIR/$1.status"
	fi
	[ "$state" != ready ] || return 1
	[ "$state" != pin ] || [ -z "$(uci -q get "network.$1.pincode")" ] || return 1
	return 0
}

simwait_status() {
	local state=unknown stamp=0 waiting=false
	case "$1" in ''|*[!A-Za-z0-9_-]*) echo '{"sim_state":"unknown","waiting_sim":false}'; return ;; esac
	if [ -r "$SIMWAIT_DIR/$1.status" ]; then
		read -r state stamp < "$SIMWAIT_DIR/$1.status"
	fi
	case "$stamp" in ''|*[!0-9]*) stamp=0 ;; esac
	[ "$(uptime_s)" -ge "$stamp" ] && [ $(( $(uptime_s) - stamp )) -le 90 ] || state=unknown
	case "$state" in absent|ready|locked) ;; pin) state=locked ;; *) state=unknown ;; esac
	[ ! -f "$SIMWAIT_DIR/$1" ] || waiting=true
	printf '{"sim_state":"%s","waiting_sim":%s}\n' "$state" "$waiting"
}

simwait_tick() {
	local path section interface proto port owner
	mkdir -p "$SIMWAIT_DIR"
	exec 6>"$SIMWAIT_DIR/.lock"
	flock -n 6 || return
	while read -r path section interface proto port owner; do
		[ -n "$path" ] || continue
		simwait_tick_one "$path" "$section" "$interface" "$proto" "$port" "$owner"
	done <<EOF_REGISTRY
$(/usr/share/5gmodem/registry.sh flat 2>/dev/null)
EOF_REGISTRY
	flock -u 6
	exec 6>&-
}

if [ "${0##*/}" = simwait.sh ]; then
	. /usr/share/5gmodem/lib.sh
	case "$1" in
		tick) simwait_tick ;;
		status) simwait_status "$2" ;;
		check-interface) simwait_check_interface "$2" ;;
		blocked) simwait_blocked "$2" ;;
		recovering) simwait_recovering "$2" ;;
		check) shift; simwait_check "$@" ;;
		*) exit 1 ;;
	esac
fi
