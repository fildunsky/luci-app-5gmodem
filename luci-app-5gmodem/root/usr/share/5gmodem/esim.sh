#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

RES="/usr/share/5gmodem"

find /tmp/5gmodem -maxdepth 1 -name 'esim_*.[0-9]*' -mmin +30 -exec rm -f {} + 2>/dev/null

if [ -x /usr/lib/lpac/lpac ]; then
	LPAC="/usr/lib/lpac/lpac"
	export LPAC_DRIVER_HOME="/usr/lib/lpac"
elif [ -x /usr/bin/lpac ]; then
	LPAC="/usr/bin/lpac"
	[ -e /usr/lib/lpac/lpac ] || LPAC_BROKEN="/usr/bin/lpac wrapper exists but /usr/lib/lpac/lpac is missing: broken lpac install (usually a patched package over the official one). Fix: apk del lpac; rm -rf /usr/lib/lpac /usr/bin/lpac; reinstall"
elif [ -x /usr/lib/lpac ]; then
	LPAC="/usr/lib/lpac"
else
	LPAC="$(command -v lpac 2>/dev/null)"
	[ -n "$LPAC" ] || LPAC="/usr/lib/lpac"
fi

. /usr/share/5gmodem/atlock.sh
BRIDGE="/usr/share/5gmodem/esim-apdu-bridge.sh"
. /usr/share/5gmodem/esimcaps.sh

PORTCACHE="/tmp/5gmodem/esim_port_$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null | tr -c 'A-Za-z0-9' '_')"
LIVELOG="/tmp/5gmodem/esim_progress.log"
GSMACERT="/usr/share/5gmodem/certs/gsma-ci.pem"
CACACHE="/tmp/5gmodem/esim_ca.pem"

http_backend() {
	_hb=$(uci -q get 5gmodem.@5gmodem[0].esim_http)
	[ -n "$_hb" ] || _hb="auto"
	case "$_hb" in
		curl)   echo curl ;;
		bridge) echo bridge ;;
		*)      if command -v wget >/dev/null 2>&1 && [ -f "$GSMACERT" ]; then
				echo bridge
			else
				echo curl
			fi ;;
	esac
}

apdu_backend() {
	_ab=$(uci -q get 5gmodem.@5gmodem[0].esim_apdu)
	case "$_ab" in
		at|uqmi|bridge) echo "$_ab"; return ;;
		qmi|mbim)
			case "$(_wdm_driver)" in
				*cdc_mbim*) _mbim_or_at ;;
				*qmi_wwan*) echo qmi ;;
				*)
					if [ -z "$(esim_wdm)" ]; then
						logger -t 5gmodem "esim: $_ab selected, but the modem has no cdc-wdm - going over AT via the bridge"
						echo bridge
					else
						echo "$_ab"
					fi ;;
			esac
			return ;;
	esac
	[ -x /usr/lib/lpac/lpac ] || { echo bridge; return; }
	_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_sec="m_$(echo "$_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	_if=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_if" ] || _if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_abp=$(uci -q get "network.$_if.proto")
	case "$_abp" in
		mbim|modemmanager|qmi)
			case "$(_wdm_driver)" in
				*cdc_mbim*) _mbim_or_at ;;
				*qmi_wwan*) echo qmi ;;
				*) [ "$_abp" = qmi ] && echo qmi || _mbim_or_at ;;
			esac ;;
		# see docs/subsystems/esim.md#apdu-backend-selection
		*) echo bridge ;;
	esac
}

mbim_backend() { [ "$(apdu_backend)" = "mbim" ]; }

wdm_backend() {
	case "$(apdu_backend)" in
		mbim|qmi|uqmi) return 0 ;;
	esac
	return 1
}

_mm_owns_channel() {
	[ "$("$RES/registry.sh" active 2>/dev/null \
		| jsonfilter -e '@.owner' 2>/dev/null)" = "mm" ]
}

_ESIM_INH_PID=/tmp/5gmodem/esim_mminh.pid
_ESIM_INH_T=/tmp/5gmodem/esim_mminh.t
_mm_inh_held() { [ -f "$_ESIM_INH_PID" ] && kill -0 "$(cat "$_ESIM_INH_PID" 2>/dev/null)" 2>/dev/null; }
_mm_inh_touch() { cut -d. -f1 /proc/uptime > "$_ESIM_INH_T" 2>/dev/null; }
_mm_busy_on_dev() {
	_mb_pid=$(pidof ModemManager 2>/dev/null | head -1)
	[ -n "$_mb_pid" ] || return 1
	for _mb_f in /proc/"$_mb_pid"/fd/*; do
		case "$(readlink "$_mb_f" 2>/dev/null)" in
			/dev/cdc-wdm*|/dev/ttyUSB*|/dev/ttyACM*) return 0 ;;
		esac
	done
	return 1
}
_mm_esim_take() {
	_mm_inh_held && { _mm_inh_touch; return 0; }
	_ti_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_ti_idx=""; _ti_i=0
	while [ "$_ti_i" -lt 20 ]; do
		_ti_idx=$("$RES/modemswitch.sh" mmindex "$_ti_ap" 2>/dev/null)
		[ -n "$_ti_idx" ] && break
		_mm_busy_on_dev || return 0
		sleep 3; _ti_i=$((_ti_i + 1))
	done
	[ -n "$_ti_idx" ] || return 1
	mmcli -m "$_ti_idx" --inhibit-device >/dev/null 2>&1 </dev/null &
	echo $! > "$_ESIM_INH_PID"
	_mm_inh_touch
	_ti_i=0
	while [ "$_ti_i" -lt 15 ]; do
		mmcli -m "$_ti_idx" >/dev/null 2>&1 || break
		sleep 1; _ti_i=$((_ti_i + 1))
	done
	logger -t 5gmodem "esim: channel borrowed from MM (inhibit $_ti_ap) - will return after 90s of eSIM idle"
	(
		while :; do
			sleep 15
			_wd_p=$(cat "$_ESIM_INH_PID" 2>/dev/null)
			{ [ -n "$_wd_p" ] && kill -0 "$_wd_p" 2>/dev/null; } || exit 0
			_wd_now=$(cut -d. -f1 /proc/uptime)
			_wd_t=$(cat "$_ESIM_INH_T" 2>/dev/null || echo 0)
			[ $((_wd_now - _wd_t)) -ge 90 ] || continue
			kill "$_wd_p" 2>/dev/null
			rm -f "$_ESIM_INH_PID" "$_ESIM_INH_T"
			logger -t 5gmodem "esim: inhibit released (idle) - MM is reassembling the modem, the interface will come up on its own"
			exit 0
		done
	) >/dev/null 2>&1 </dev/null &
}

_is_wdm_node() {
	[ -c "$1" ] || return 1
	[ -e "/sys/class/usbmisc/${1##*/}" ] || [ -e "/sys/class/wwan/${1##*/}" ]
}

esim_wdm() {
	_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_ew_lm=$("$RES/listmodems.sh" 2>/dev/null)
	_w=$(printf '%s' "$_ew_lm" | jsonfilter -e "@[@.path=\"$_ap\"].wdm[0]" 2>/dev/null)
	_is_wdm_node "$_w" || _w=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).device")
	_is_wdm_node "$_w" && { echo "$_w"; return; }
	case "$_ew_lm" in
		*"\"path\":\"$_ap\""*) echo ""; return ;;
	esac
	set -- /dev/cdc-wdm*
	[ "$#" = 1 ] && [ -c "$1" ] || { echo ""; return; }
	case "$_ew_lm" in
		*"\"$1\""*) echo ""; return ;;
	esac
	echo "$1"
}

_wdm_owned_by_netifd() {
	[ -n "$1" ] || return 1
	for _wn in $(uci show network 2>/dev/null | sed -n "s|^network\.\([^.]*\)\.device='$1'\$|\1|p"); do
		case "$(uci -q get "network.$_wn.proto")" in
			mbim|qmi|qmiraw) : ;;
			*) continue ;;
		esac
		case "$(ubus call "network.interface.$_wn" status 2>/dev/null)" in
			*'"up": true'*|*'"pending": true'*) return 0 ;;
		esac
	done
	return 1
}

_wdm_owned_by_umbim() {
	[ -n "$1" ] || return 1
	for _wo in $(uci show network 2>/dev/null | sed -n "s|^network\.\([^.]*\)\.device='$1'\$|\1|p"); do
		[ "$(uci -q get "network.$_wo.proto")" = "mbim" ] || continue
		ubus call "network.interface.$_wo" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	done
	return 1
}

_mbim_or_at() {
	if _wdm_owned_by_umbim "$(esim_wdm)"; then
		logger -t 5gmodem "esim: node $(esim_wdm) is owned by umbim (proto=mbim) - mbim probe forbidden, going over AT via the bridge"
		echo bridge
	else
		echo mbim
	fi
}

_wdm_driver() {
	_wd=$(esim_wdm)
	readlink -f "/sys/class/usbmisc/${_wd##*/}/device/driver" 2>/dev/null | sed 's#.*/##'
}

euicc_probe_wdm() {
	_pwdev=$(esim_wdm)
	[ -c "$_pwdev" ] || return 1
	if [ "$1" = mbim ] && _wdm_owned_by_umbim "$_pwdev"; then
		logger -t 5gmodem "esim: mbim probe on the umbim node is forbidden (it kills the data session)"
		return 1
	fi
	_pwsave=""
	_pwskip=1
	case "$1" in
		qmi)  _pw="LPAC_APDU=qmi LPAC_APDU_QMI_DEVICE=$_pwdev" ;;
		uqmi) _pw="LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE=$_pwdev" ;;
		mbim)
		      _pwskip=$(_mbim_skipmap "$_pwdev")
		      _pw="LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE=$_pwdev LPAC_APDU_MBIM_USE_PROXY=1 LPAC_APDU_MBIM_UIM_SLOT=$(_mbim_uim_slot) LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=$_pwskip"
		      _pwsave=$(_mbim_slot_get "$_pwdev") ;;
		*)    return 1 ;;
	esac
	_pwr=1
	_pwtry=0
	while [ "$_pwtry" -lt 2 ]; do
		_pwtry=$((_pwtry + 1))
		_pwo="/tmp/5gmodem/esim_wdmprobe.$$"
		rm -f "$_pwo"
		( env $_pw LPAC_HTTP="$(http_local_drv)" "$LPAC" chip info >"$_pwo" 2>/dev/null ) &
		_pwp=$!
		_pwn=0
		while kill -0 "$_pwp" 2>/dev/null && [ "$_pwn" -lt 15 ]; do sleep 1; _pwn=$((_pwn + 1)); done
		kill "$_pwp" 2>/dev/null
		grep -qi '"eidValue"\|"eid"' "$_pwo" 2>/dev/null && _pwr=0
		rm -f "$_pwo"
		[ "$_pwr" = 0 ] && break
		if [ "$_pwtry" = 1 ] && [ "$1" = mbim ] \
			&& pidof mbim-proxy >/dev/null 2>&1 && ! _mm_owns_channel; then
			logger -t 5gmodem "esim: mbim probe did not answer, restarting mbim-proxy"
			killall mbim-proxy 2>/dev/null
			sleep 2
		else
			break
		fi
	done
	[ "$1" = mbim ] && _mbim_slot_restore "$_pwdev" "$_pwsave"
	return $_pwr
}

ca_bundle() {
	_sys="/etc/ssl/certs/ca-certificates.crt"
	[ -f "$GSMACERT" ] || { echo ""; return; }
	if [ ! -f "$CACACHE" ] || [ "$GSMACERT" -nt "$CACACHE" ] || \
	   { [ -f "$_sys" ] && [ "$_sys" -nt "$CACACHE" ]; }; then
		{ [ -f "$_sys" ] && cat "$_sys"; cat "$GSMACERT"; } > "$CACACHE" 2>/dev/null
	fi
	echo "$CACACHE"
}

err() { echo "{\"type\":\"lpa\",\"payload\":{\"code\":-1,\"message\":\"$1\",\"data\":\"\"}}"; }

_mbim_slot_get() {
	command -v mbimcli >/dev/null 2>&1 || return 0
	mbimcli -d "$1" -p --ms-query-device-slot-mappings 2>/dev/null \
		| sed -n "s/.*Executor '0': slot '\([0-9][0-9]*\)'.*/\1/p" | head -1
}
_mbim_slot_restore() {
	[ -n "$2" ] || return 0
	command -v mbimcli >/dev/null 2>&1 || return 0
	_msr=$(_mbim_slot_get "$1")
	[ -n "$_msr" ] && [ "$_msr" != "$2" ] \
		&& mbimcli -d "$1" -p --ms-set-device-slot-mappings="$2" >/dev/null 2>&1
}
http_local_drv() {
	[ -d /usr/lib/lpac/driver ] || { echo curl; return; }
	[ -f /usr/lib/lpac/driver/driver_http_curl.so ] && { echo curl; return; }
	[ -f /usr/lib/lpac/driver/driver_http_stdio.so ] && { echo stdio; return; }
	echo curl
}

_mbim_uim_slot() {
	_v=$(uci -q get lpac.mbim.slot)
	[ -n "$_v" ] || _v=$(uci -q get lpac.mbim.uim_slot)
	[ -n "$_v" ] && { echo "$_v"; return; }
	_v=$("$RES/simslot.sh" status 2>/dev/null \
		| jsonfilter -e '@.active' 2>/dev/null)
	case "$_v" in
		''|*[!0-9]*)
			_c=""
			[ -z "$(find /tmp/5gmodem/esim_actslot -mmin +60 2>/dev/null)" ] \
				&& _c=$(cat /tmp/5gmodem/esim_actslot 2>/dev/null)
			case "$_c" in ''|*[!0-9]*) echo 2 ;; *) echo "$_c" ;; esac ;;
		*)
			printf '%s' "$_v" > /tmp/5gmodem/esim_actslot 2>/dev/null
			echo "$_v" ;;
	esac
}
_mbim_target_index() {
	_mti=$(_mbim_uim_slot)
	case "$_mti" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_mti" -gt 0 ] || return 1
	echo $((_mti - 1))
}

_mbim_target_is_active_esim() {
	if command -v mbimcli >/dev/null 2>&1; then
		_tie=$(_mbim_target_index) || return 1
		_tie_st=$(mbimcli -d "$1" -p --ms-query-slot-info-status="$_tie" 2>/dev/null \
			| sed -n 's/.*[Ss]lot state:[^a-zA-Z]*\([a-zA-Z-]*\).*/\1/p' | head -1)
		[ "$_tie_st" = "active-esim" ] && return 0
		return 1
	fi
	command -v qmicli >/dev/null 2>&1 || return 1
	_tie_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _tie_mb="--device-open-mbim" ;;
	esac
	qmicli -d "$1" -p $_tie_mb --uim-get-slot-status 2>/dev/null | tr -d '\r' | awk '
		/^ *Physical slot [0-9]+:/          { act = 0; euicc = 0; next }
		/Slot status:[ \t]*active[ \t]*$/   { act = 1 }
		/Is eUICC:[ \t]*yes/                { euicc = 1 }
		act && euicc { found = 1; exit }
		END { exit(found ? 0 : 1) }
	'
}

_wdm_free_channels() {
	command -v qmicli >/dev/null 2>&1 || return 0
	[ -n "$1" ] && [ -e "$1" ] || return 0
	case "$2" in ''|*[!0-9]*) return 0 ;; esac
	_fcmb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _fcmb="--device-open-mbim" ;;
	esac
	for _fc in 1 2 3 4; do
		qmicli -d "$1" -p $_fcmb --uim-close-logical-channel="$2,$_fc" >/dev/null 2>&1
	done
}

_mbim_use_proxy() {
	pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1 && { echo 1; return; }
	_upi=$(uci -q get 5gmodem.@5gmodem[0].network)
	if [ -n "$_upi" ] && ubus call "network.interface.$_upi" status 2>/dev/null \
		| grep -q '"up": true'; then
		echo 1; return
	fi
	_upc="/tmp/5gmodem/esim_proxyok"
	if [ -s "$_upc" ] && [ -z "$(find "$_upc" -mmin +2 2>/dev/null)" ]; then
		cat "$_upc"; return
	fi
	_upmb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _upmb="--device-open-mbim" ;;
	esac
	if qmicli -d "$1" -p $_upmb --uim-get-slot-status >/dev/null 2>&1; then
		echo 1 > "$_upc"
	else
		logger -t 5gmodem "esim: mbim-proxy not responding - talking to $1 directly (the channel is free)"
		echo 0 > "$_upc"
	fi
	cat "$_upc"
}

_mbim_skipmap() {
	_v=$(uci -q get lpac.mbim.skip_slot_mapping)
	[ -n "$_v" ] && { echo "$_v"; return; }
	_mbim_target_is_active_esim "$1" && echo 0 || echo 1
}

run_lpac() {
	_T="$1"; shift
	_BE=$(apdu_backend)
	if [ "$_BE" = "mbim" ]; then
		_MDEV=$(esim_wdm)
		_MOLD=$(_mbim_slot_get "$_MDEV")
		_MSKIP=$(_mbim_skipmap "$_MDEV")
		_MHTTP=$(http_local_drv)
		_MR="/tmp/5gmodem/esim_res.$$"; rm -f "$_MR"
		if [ "$_MHTTP" = "stdio" ]; then
			_MLOOP="/tmp/5gmodem/esim_mloop.$$"
			rm -f "$_MLOOP"; mkfifo "$_MLOOP" 2>/dev/null
			sh "$BRIDGE" /dev/null "$_MR" "$(ca_bundle)" "$LIVELOG" < "$_MLOOP" \
				| env LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE="$_MDEV" \
					LPAC_APDU_MBIM_UIM_SLOT="$(_mbim_uim_slot)" LPAC_APDU_MBIM_USE_PROXY="$(_mbim_use_proxy "$_MDEV")" \
					LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="$_MSKIP" LPAC_HTTP=stdio \
					"$LPAC" "$@" > "$_MLOOP" 2>/dev/null &
		else
			env LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE="$_MDEV" \
				LPAC_APDU_MBIM_UIM_SLOT="$(_mbim_uim_slot)" LPAC_APDU_MBIM_USE_PROXY="$(_mbim_use_proxy "$_MDEV")" \
				LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="$_MSKIP" LPAC_HTTP="$_MHTTP" \
				"$LPAC" "$@" > "$_MR" 2>/dev/null &
		fi
		_PID=$!; _n=0
		while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
		_MKILLED=""
		if kill -0 "$_PID" 2>/dev/null; then
			_MKILLED=1
			kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null
			_n=0
			while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
			kill -9 "$_PID" 2>/dev/null; killall -9 lpac 2>/dev/null
		fi
		rm -f "$_MLOOP"
		[ -n "$_MKILLED" ] && _wdm_free_channels "$_MDEV" "$(_mbim_uim_slot)"
		[ "$_MSKIP" = 1 ] && _mbim_slot_restore "$_MDEV" "$_MOLD"
		if [ -s "$_MR" ]; then cat "$_MR"; else err "timeout"; fi
		rm -f "$_MR"
		return
	fi

	_prelock="$_AT_LOCK_HELD"
	_locked=0
	case "$_BE" in
	at|bridge)
		at_lock "$PORT" 20; _locked=1
		for _c in 1 2 3 4 5 6 7 8; do at_bounded "$PORT" "AT+CCHC=$_c" 2 >/dev/null; done
		;;
	esac
	_RES="/tmp/5gmodem/esim_res.$$"
	_LOOP="/tmp/5gmodem/esim_loop.$$"
	rm -f "$_RES" "$_LOOP"; mkfifo "$_LOOP" 2>/dev/null
	if [ "$(http_backend)" = "bridge" ]; then
		_CA=$(ca_bundle); _HTTPDRV="stdio"
	else
		_CA=""; _HTTPDRV="curl"
	fi
	if [ "$_HTTPDRV" = curl ] && [ "$(http_local_drv)" != curl ]; then
		_HTTPDRV="stdio"; _CA=$(ca_bundle)
	fi
	case "$_BE" in
		at)   _APDU_ENV="LPAC_APDU=at LPAC_APDU_AT_DEVICE=$PORT" ;;
		qmi)  _APDU_ENV="LPAC_APDU=qmi LPAC_APDU_QMI_DEVICE=$(esim_wdm)" ;;
		uqmi) _APDU_ENV="LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE=$(esim_wdm)" ;;
		mbim) _APDU_ENV="LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE=$(esim_wdm) LPAC_APDU_MBIM_USE_PROXY=1" ;;
		*)    _APDU_ENV="LPAC_APDU=stdio" ;;
	esac
	sh "$BRIDGE" "$PORT" "$_RES" "$_CA" "$LIVELOG" < "$_LOOP" \
		| env $_APDU_ENV LPAC_HTTP="$_HTTPDRV" "$LPAC" "$@" > "$_LOOP" 2>/dev/null &
	_PID=$!
	_n=0
	while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
	kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null
	[ "$_locked" = 1 ] && [ -z "$_prelock" ] && at_unlock
	rm -f "$_LOOP"
	if [ -s "$_RES" ]; then cat "$_RES"; else err "timeout"; fi
	rm -f "$_RES"
}

at_bounded() {
	_ao="/tmp/5gmodem/esim_at.$$"
	sms_tool -d "$1" at "$2" > "$_ao" 2>/dev/null &
	_ap=$!
	( sleep "${3:-6}"; kill "$_ap" 2>/dev/null ) >/dev/null 2>&1 </dev/null & _aw=$!
	wait "$_ap" 2>/dev/null; kill "$_aw" 2>/dev/null; wait "$_aw" 2>/dev/null
	tr -d '\r' < "$_ao"; rm -f "$_ao"
}

port_ok() {
	_AID=$(uci -q get lpac.global.custom_isd_r_aid 2>/dev/null)
	[ -n "$_AID" ] || _AID="A0000005591010FFFFFFFF8900000100"
	_R=$(at_bounded "$1" "AT+CCHO=\"$_AID\"" "${2:-2}")
	_CH=$(echo "$_R" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
	[ -n "$_CH" ] || _CH=$(echo "$_R" | grep -E '^[0-9]+$' | head -1)
	[ -n "$_CH" ] || return 1
	at_bounded "$1" "AT+CCHC=$_CH" 4 >/dev/null
	return 0
}

live_port() {
	_LPR=$("$RES/registry.sh" active 2>/dev/null)
	_LPT=$(printf '%s' "$_LPR" | jsonfilter -e '@.tty[*]' 2>/dev/null | tr '\n' ' ')
	[ -n "$_LPT" ] || return 1
	_D=$("$RES/detect.sh" 2>/dev/null)
	case " $_LPT " in
		*" $_D "*) _LPT="$_D $_LPT" ;;
	esac
	for _t in $_LPT; do
		[ -e "$_t" ] || continue
		"$RES/atprobe.sh" "$_t" >/dev/null 2>&1 && { echo "$_t"; return 0; }
	done
	return 1
}

esim_active() {
	T=$(sms_tool -d "$1" at "AT+SIMTYPE?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
	case "$T" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	_ea_w=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
	[ -n "$_ea_w" ] && [ -e "$_ea_w" ] || return 1
	command -v qmicli >/dev/null 2>&1 || return 1
	_ea_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${_ea_w##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _ea_mb="--device-open-mbim" ;;
	esac
	_ea_c="/tmp/5gmodem/esim_act_$(printf '%s' "$_ea_w" | tr -c 'A-Za-z0-9' '_')"
	if ! pidof ModemManager >/dev/null 2>&1 && _wdm_owned_by_netifd "$_ea_w"; then
		[ "$(cat "$_ea_c" 2>/dev/null)" = 0 ] && return 1
		return 0
	fi
	qmicli -d "$_ea_w" -p $_ea_mb --uim-get-slot-status 2>/dev/null | awk '
		/^ *Physical slot [0-9]+:/ { act = 0; euicc = 0; seen = 1; next }
		/Slot status: *active/     { act = 1 }
		/Is eUICC: *yes/           { euicc = 1 }
		act && euicc { found = 1; exit }
		END { exit(found ? 0 : (seen ? 1 : 2)) }
	'
	_ea_rc=$?
	case "$_ea_rc" in
		0) echo 1 > "$_ea_c" 2>/dev/null; return 0 ;;
		1) echo 0 > "$_ea_c" 2>/dev/null; return 1 ;;
	esac
	return 1
}

free_channels() {
	for _fc in 1 2 3 4 5 6 7 8; do at_bounded "$1" "AT+CCHC=$_fc" 2 >/dev/null; done
}

find_port() {
	_fp_vp=$(uci -q get "5gmodem.m_$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g').vidpid" 2>/dev/null)
	case "$_fp_vp" in
		1199:*)
			logger -t 5gmodem "esim: CCHO port scan skipped on Sierra ($_fp_vp) - it wedges the SIM subsystem; use the QMI/MBIM transport"
			return 1 ;;
	esac
	C=$(cat "$PORTCACHE" 2>/dev/null)
	if [ -n "$C" ] && [ -e "$C" ] && port_ok "$C"; then
		echo "$C"; return 0
	fi
	rm -f "$PORTCACHE"
	P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_fp_skip=""
	_fp_if=$(uci -q get "5gmodem.m_$(printf '%s' "$P" | sed 's/[^A-Za-z0-9]/_/g').network")
	if [ -n "$_fp_if" ]; then
		case "$(uci -q get "network.$_fp_if.proto" 2>/dev/null)" in
			xmm|atc) _fp_skip=$(uci -q get "network.$_fp_if.device" 2>/dev/null) ;;
		esac
	fi
	if [ -n "$P" ]; then
		CANDS=$("$RES/listmodems.sh" 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null)
	else
		CANDS=$("$RES/detect.sh" 2>/dev/null)
	fi
	if [ -n "$_fp_skip" ]; then
		_fp_n=0
		for _fp_t in $CANDS; do _fp_n=$((_fp_n + 1)); done
		[ "$_fp_n" -gt 1 ] && CANDS=$(printf '%s\n' $CANDS | grep -vxF "$_fp_skip")
	fi
	SEEN=""; ALIVE=""
	for t in $CANDS; do
		case " $SEEN " in *" $t "*) continue;; esac
		SEEN="$SEEN $t"
		[ -e "$t" ] || continue
		"$RES/atprobe.sh" "$t" >/dev/null 2>&1 || continue
		ALIVE="$ALIVE $t"
		if port_ok "$t"; then
			echo "$t" > "$PORTCACHE"; echo "$t"; return 0
		fi
	done
	for t in $ALIVE; do
		free_channels "$t"
		if port_ok "$t" 6; then
			echo "$t" > "$PORTCACHE"; echo "$t"; return 0
		fi
	done
	return 1
}

do_lpac() {
	_T="$1"; shift
	_dl_be=$(apdu_backend)
	_dl_max=2
	case " $* " in
		*" download "*)
			case "$_dl_be" in qmi|mbim|uqmi) _dl_max=5 ;; esac ;;
	esac
	_dl_n=1
	while :; do
		R=$(run_lpac "$_T" "$@")
		printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0' && break
		case "$(printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1)" in
			*'"data":"Not JSON"'*|*'"data":"Not Object"'*|*'"data":"HTTP status code error"'*|*'"data":"HTTP transport failed"'*)
				if [ "$(grep '"type":"httpx"' "$LIVELOG" 2>/dev/null | tail -1 \
					| grep -c '"truncated":1')" = 1 ]; then
					logger -t 5gmodem "esim: server response was cut short - retrying"
				else
					logger -t 5gmodem "esim: server response violates the protocol - retries are pointless, stopping"
					break
				fi ;;
		esac
		case "$(printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1)" in
			*'"message":"es9p_'*'"data":""'*) : ;;
			*'"message":"es9p_'*)
				logger -t 5gmodem "esim: the operator server refused the request - retries are pointless, stopping"
				break ;;
		esac
		if printf '%s\n' "$R" | grep -q 'iccid_already_exists_on_euicc'; then
			logger -t 5gmodem "esim: a profile with this ICCID is already on the chip - treating the install as successful"
			R='{"type":"lpa","payload":{"code":0,"message":"success","data":"already_installed"}}'
			break
		fi
		[ "$_dl_n" -ge "$_dl_max" ] && break
		case "$_dl_be" in
			at|bridge)
				rm -f "$PORTCACHE"
				PORT=$(find_port)
				[ -n "$PORT" ] || break ;;
			*)
				_wdm_free_channels "$(esim_wdm)" "$(_mbim_uim_slot)"
				if [ "$_dl_max" -gt 2 ]; then
					_dl_p=$(live_port)
					_dl_s=$(_mbim_uim_slot); case "$_dl_s" in ''|*[!0-9]*) _dl_s=2 ;; esac
					_dl_cur=$((_dl_s - 1))
					_dl_alt=0; [ "$_dl_cur" = 0 ] && _dl_alt=1
					if [ -n "$_dl_p" ] && sms_tool -d "$_dl_p" at "AT^switch_slot?" 2>/dev/null \
						| grep -qi "SIM"; then
						logger -t 5gmodem "esim: chip not responding - reinitializing the card by cycling the slot $_dl_cur -> $_dl_alt -> $_dl_cur"
						sms_tool -d "$_dl_p" at "AT^switch_slot=$_dl_alt" >/dev/null 2>&1
						sleep 5
						sms_tool -d "$_dl_p" at "AT^switch_slot=$_dl_cur" >/dev/null 2>&1
						sleep 8
					else
						sleep 3
					fi
				fi ;;
		esac
		_dl_n=$((_dl_n + 1))
		[ "$_dl_max" -gt 2 ] && logger -t 5gmodem "esim: profile download failed - attempt $_dl_n of $_dl_max"
		printf '{"type":"progress","payload":{"code":0,"message":"retry","data":"%s/%s"}}\n' \
			"$_dl_n" "$_dl_max" >> "$LIVELOG" 2>/dev/null
	done
	echo "$R"
}

_SCACHE_NEG_TTL=600
_scache_get() {
	[ -s "$1" ] || return 1
	case "$(cat "$1" 2>/dev/null)" in
		*'"available":1'*) cat "$1"; return 0 ;;
	esac
	_sg_t=$(cat "$1.t" 2>/dev/null)
	case "$_sg_t" in ''|*[!0-9]*) return 1 ;; esac
	[ $(( $(cut -d. -f1 /proc/uptime) - _sg_t )) -lt "$_SCACHE_NEG_TTL" ] || return 1
	cat "$1"
	return 0
}

case "$1" in
reapply)
	(
		_IF=$(uci -q get 5gmodem.@5gmodem[0].network)
		if [ -z "$_IF" ]; then
			_AM=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null \
				| tr -c 'A-Za-z0-9' '_')
			[ -n "$_AM" ] && _IF=$(uci -q get "5gmodem.m_${_AM%_}.network" 2>/dev/null)
		fi
		if [ -z "$_IF" ]; then
			_PR=$(uci -q get 5gmodem.@5gmodem[0].iface_proto 2>/dev/null)
			[ -n "$_PR" ] && _IF=$(uci -q show network 2>/dev/null \
				| sed -n "s/^network\.\([^.]*\)\.proto='$_PR'$/\1/p" | head -1)
		fi
		[ -n "$_IF" ] || exit 0
		_n=0
		while [ "$_n" -lt 60 ]; do
			sleep 2; _n=$((_n + 1))
			_D=$("$RES/detect.sh" 2>/dev/null)
			[ -n "$_D" ] || continue
			"$RES/atprobe.sh" "$_D" >/dev/null 2>&1 && break
		done
		ifdown "$_IF" 2>/dev/null
		sleep 3
		ifup "$_IF" 2>/dev/null
	) >/dev/null 2>&1 </dev/null &
	echo '{"type":"lpa","payload":{"code":0,"message":"reapply","data":""}}'
	exit 0
	;;
progress)
	if [ "$2" = "reset" ]; then : > "$LIVELOG"; echo "{}"; exit 0; fi
	[ -f "$LIVELOG" ] && cat "$LIVELOG"
	exit 0
	;;
download-bg)
	[ -n "$2" ] || { echo '{"started":0,"error":"no code"}'; exit 0; }
	_DLRES="/tmp/5gmodem/esim_dlresult"
	if [ -f "$_DLRES.running" ]; then
		_wp=$(cat "$_DLRES.running" 2>/dev/null)
		[ -n "$_wp" ] && [ -d "/proc/$_wp" ] && { echo '{"started":0,"busy":1}'; exit 0; }
	fi
	rm -f "$_DLRES" "$_DLRES.tmp" "$_DLRES.running"
	(
		"$0" download "$2" > "$_DLRES.tmp" 2>/dev/null
		mv "$_DLRES.tmp" "$_DLRES"
		rm -f "$_DLRES.running"
	) >/dev/null 2>&1 </dev/null &
	echo "$!" > "$_DLRES.running"
	echo '{"started":1}'
	exit 0
	;;
download-status)
	_DLRES="/tmp/5gmodem/esim_dlresult"
	[ -f "$_DLRES" ] && { cat "$_DLRES"; exit 0; }
	if [ -f "$_DLRES.running" ]; then
		_wp=$(cat "$_DLRES.running" 2>/dev/null)
		[ -n "$_wp" ] && [ -d "/proc/$_wp" ] && { echo '{"dlstate":"running"}'; exit 0; }
		rm -f "$_DLRES.running"
		echo '{"type":"lpa","payload":{"code":-1,"message":"download worker exited without result","data":""}}'
		exit 0
	fi
	echo '{"dlstate":"idle"}'
	exit 0
	;;
setshow)
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] || exit 0
	_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$_AP"
	}
	case "$2" in
		0|1) uci -q set "5gmodem.$_sec.esim_show=$2" ;;
		*)   uci -q delete "5gmodem.$_sec.esim_show" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	rm -f "/tmp/5gmodem/esimstat_$_AP" 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
sethttp)
	case "$2" in
		auto|curl|bridge) uci -q set "5gmodem.@5gmodem[0].esim_http=$2" ;;
		*)                uci -q delete "5gmodem.@5gmodem[0].esim_http" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	echo '{"result":"ok"}'
	exit 0
	;;
setapdu)
	case "$2" in
		at|qmi|uqmi|mbim|bridge) uci -q set "5gmodem.@5gmodem[0].esim_apdu=$2" ;;
		*)                       uci -q delete "5gmodem.@5gmodem[0].esim_apdu" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	rm -f /tmp/5gmodem/esimstat_* 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
setslot)
	[ -f /etc/config/lpac ] || : > /etc/config/lpac
	case "$2" in
		1|2)
			uci -q set "lpac.mbim=mbim";  uci -q set "lpac.mbim.uim_slot=$2"
			uci -q set "lpac.qmi=qmi";    uci -q set "lpac.qmi.uim_slot=$2"
			uci -q set "lpac.uqmi=uqmi";  uci -q set "lpac.uqmi.uim_slot=$2"
			;;
		*)
			uci -q delete "lpac.mbim.slot" 2>/dev/null
			uci -q delete "lpac.mbim.uim_slot" 2>/dev/null
			uci -q delete "lpac.qmi.uim_slot" 2>/dev/null
			uci -q delete "lpac.uqmi.uim_slot" 2>/dev/null
			;;
	esac
	uci -q commit lpac
	rm -f /tmp/5gmodem/esimstat_* /tmp/5gmodem/esim_actslot 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
getslot)
	_gs=$(uci -q get lpac.mbim.uim_slot)
	[ -n "$_gs" ] || _gs=$(uci -q get lpac.mbim.slot)
	case "$_gs" in 1|2) ;; *) _gs="auto" ;; esac
	printf '{"slot":"%s"}\n' "$_gs"
	exit 0
	;;
httpinfo)
	_hi=$(http_local_drv)
	printf 'HTTP driver: %s\n' "$_hi"
	if [ "$_hi" = stdio ]; then
		echo 'the router itself talks to the profile server (stdio) - curl inside lpac is NOT needed'
		exit 0
	fi
	if [ -f /usr/lib/lpac/driver/driver_http_curl.so ]; then
		if ldd /usr/lib/lpac/driver/driver_http_curl.so 2>/dev/null | grep -q "not found"; then
			echo 'PROBLEM: the curl plugin is missing libraries:'
			ldd /usr/lib/lpac/driver/driver_http_curl.so 2>/dev/null | grep "not found" | sed 's/^/  /'
		else
			echo 'the curl plugin is in place, its libraries resolve'
		fi
	elif [ -f "$LPAC" ] && strings "$LPAC" 2>/dev/null | grep -qi curl_easy_perform; then
		echo 'curl is built into the binary (2.1.x layout, no plugins)'
	else
		echo 'PROBLEM: the curl driver is selected, but neither the plugin nor curl in the binary is visible'
	fi
	exit 0
	;;
apduinfo)
	printf 'selected APDU backend: %s\n' "$(apdu_backend)"
	printf 'set by hand (esim_apdu): %s\n' "$(uci -q get 5gmodem.@5gmodem[0].esim_apdu || echo '(no, autodetected)')"
	_ai_wdm=$(esim_wdm)
	_ai_drv=$(_wdm_driver)
	printf 'cdc-wdm node: %s\n' "${_ai_wdm:-(none - this modem has no control channel)}"
	printf 'node driver: %s\n' "${_ai_drv:-(undetermined)}"
	printf 'interface protocol: %s\n' "$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto")"
	printf 'lpac HTTP driver: %s\n' "$(http_local_drv 2>/dev/null || echo '(undetermined)')"
	exit 0
	;;
recheck)
	rm -f "/tmp/5gmodem/esimstat_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" \
	      "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" \
	      "$PORTCACHE" 2>/dev/null
	exec "$0" status-probe
	;;
dump-cached)
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] && [ -s "/tmp/5gmodem/esimdump_$_AP" ] && { cat "/tmp/5gmodem/esimdump_$_AP"; exit 0; }
	echo '{}'
	exit 0
	;;
status)
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] || { echo '{"available":0,"active":0}'; exit 0; }
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"

	_ES_FORCE=$(uci -q get "5gmodem.$_es_sec.esim_show")
	[ "$_ES_FORCE" = "0" ] && { echo '{"available":0,"active":0,"forced":1}'; exit 0; }
	[ "$_ES_FORCE" = "1" ] && { echo '{"available":1,"active":0,"forced":1}'; exit 0; }

	[ -n "$LPAC_BROKEN" ] && { echo '{"available":0,"active":0,"broken":1}'; exit 0; }
	[ -x "$LPAC" ] || { echo '{"available":0,"active":0}'; exit 0; }

	_vp=$(uci -q get "5gmodem.$_es_sec.vidpid")
	[ -n "$_vp" ] || _vp=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_AP\"].vidpid" 2>/dev/null | head -1)
	_prod=$("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$_AP\"].product" 2>/dev/null | head -1)
	esim_capable "$_vp" "$_prod" && { echo '{"available":1,"active":0}'; exit 0; }
	echo '{"available":0,"active":0}'
	exit 0
	;;
status-cached)
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	_ES_FORCE=$(uci -q get "5gmodem.$_es_sec.esim_show")
	[ "$_ES_FORCE" = "0" ] && { echo '{"available":0,"active":0,"forced":1}'; exit 0; }
	[ -x "$LPAC" ] || { echo '{"available":0,"active":0,"reason":"nolpac"}'; exit 0; }
	_SCACHE="/tmp/5gmodem/esimstat_$_AP"
	_scache_get "$_SCACHE" && exit 0
	echo '{"unknown":1}'
	exit 0
	;;
status-probe)
	AVAIL=0; ACTIVE=0
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	_SCACHE="/tmp/5gmodem/esimstat_$_AP"
	_pb_w=$(esim_wdm)
	if [ -n "$_pb_w" ] && _wdm_owned_by_umbim "$_pb_w"; then
		_scache_get "$_SCACHE" && exit 0
		echo '{"available":0,"active":0,"reason":"uplink"}'
		exit 0
	fi
	if [ -x "$LPAC" ]; then
		_NET=$(uci -q show 5gmodem 2>/dev/null | sed -n \
			"s/^5gmodem\.\(m_[^.]*\)\.path='$_AP'\$/\1/p" | head -1)
		_PROTO=$(uci -q get "network.$(uci -q get "5gmodem.$_NET.network").proto")
		_BE=$(apdu_backend)
		case "$_BE" in
		qmi|uqmi|mbim)
			if _mm_owns_channel && ! _mm_inh_held; then
				echo '{"available":1,"active":1,"takeover":1}'
				exit 0
			fi
			if euicc_probe_wdm "$_BE"; then
				AVAIL=1; ACTIVE=1
				printf '{"available":1,"active":1}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif _wdm_owned_by_umbim "$(esim_wdm)"; then
				_scache_get "$_SCACHE" && exit 0
				echo '{"available":0,"active":0,"reason":"uplink"}'
				exit 0
			else
				printf '{"available":0,"active":0,"reason":"noeuicc"}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			fi
			;;
		*)
		if [ "$_PROTO" != "modemmanager" ]; then
			_es_sl=$("$RES/simslot.sh" status 2>/dev/null)
			case "$_es_sl" in
				*'"label":"eSIM"'*)
					_es_act=$(printf '%s' "$_es_sl" | jsonfilter -e '@.active' 2>/dev/null)
					_es_eid=$(printf '%s' "$_es_sl" \
						| jsonfilter -e '@.slots[@.label="eSIM"].id' 2>/dev/null | head -1)
					if [ -n "$_es_act" ] && [ -n "$_es_eid" ] && [ "$_es_act" != "$_es_eid" ]; then
						echo '{"available":0,"active":0,"reason":"slot"}'
						exit 0
					fi ;;
			esac
			at_lock "$(live_port 2>/dev/null)" 10; _es_locked=$?
			D=$(find_port)
			if [ -n "$D" ]; then
				AVAIL=1
				esim_active "$D" && ACTIVE=1
				printf '{"available":%s,"active":%s}\n' "$AVAIL" "$ACTIVE" > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif live_port >/dev/null 2>&1 && [ "$_es_locked" = 0 ]; then
				printf '{"available":0,"active":0,"reason":"noeuicc"}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif _scache_get "$_SCACHE" >/dev/null 2>&1; then
				cat "$_SCACHE"; exit 0
			fi
		fi
			;;
		esac
	fi
	if [ "$AVAIL" = 0 ]; then
		if [ ! -x "$LPAC" ]; then REASON=nolpac
		elif [ "$_BE" = at ] && [ "$_PROTO" = modemmanager ]; then REASON=modemmanager
		else REASON=noeuicc; fi
		echo "{\"available\":0,\"active\":$ACTIVE,\"reason\":\"$REASON\"}"
	else
		echo "{\"available\":$AVAIL,\"active\":$ACTIVE}"
	fi
	exit 0
	;;
esac

[ -n "$LPAC_BROKEN" ] && { err "$LPAC_BROKEN"; exit 0; }
[ -x "$LPAC" ] || { err "lpac not installed"; exit 0; }

case "$1" in
netcheck)
	_host=$(echo "$2" | awk -F'[$]' '{print $2}')
	_nc_sole=0
	_nc_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_nc_if=$(uci -q get "5gmodem.m_$(echo "$_nc_ap" | sed 's/[^A-Za-z0-9]/_/g').network")
	[ -n "$_nc_if" ] || _nc_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_nc_dev=$(ubus call "network.interface.$_nc_if" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	if [ -n "$_nc_dev" ]; then
		_nc_defs=$(ip -4 route show default 2>/dev/null)
		if printf '%s\n' "$_nc_defs" | grep -q " dev $_nc_dev " \
		   && ! printf '%s\n' "$_nc_defs" | grep -v " dev $_nc_dev " | grep -q "^default"; then
			_nc_sole=1
		fi
	fi
	if [ -n "$_host" ] && curl -sS -m 15 -o /dev/null "https://$_host/" 2>/dev/null; then
		echo '{"net":1,"smdp":1,"sole":'"$_nc_sole"'}'
	elif curl -sS -m 10 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
		if [ -n "$_host" ]; then
			echo '{"net":1,"smdp":0,"sole":'"$_nc_sole"'}'
		else
			echo '{"net":1,"smdp":1,"sole":'"$_nc_sole"'}'
		fi
	else
		echo '{"net":0}'
	fi
	exit 0
	;;
esac

_esim_may_disrupt=1
case "$1" in
	download|enable|disable|delete|nickname|flush|notif|notifications|dump-free) ;;
	*) _esim_may_disrupt="" ;;
esac
[ "$ESIM_READONLY" = "1" ] && _esim_may_disrupt=""
if [ -z "$_esim_may_disrupt" ]; then
	_ub_w=$(esim_wdm)
	if [ -n "$_ub_w" ] && _wdm_owned_by_umbim "$_ub_w"; then
		err "uplink busy"; exit 0
	fi
fi

LOCK="/tmp/5gmodem/esim.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
	_lp=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then
		err "busy"; exit 0
	fi
	if [ -z "$_lp" ] && [ -z "$(find "$LOCK" -mmin +6 2>/dev/null)" ]; then
		err "busy"; exit 0
	fi
	rm -rf "$LOCK" 2>/dev/null
	mkdir "$LOCK" 2>/dev/null || { err "busy"; exit 0; }
fi
echo "$$" > "$LOCK/pid" 2>/dev/null

_UPLINK_IF=""
_uplink_release() {
	if [ "$ESIM_READONLY" = "1" ]; then
		logger -t 5gmodem "esim: read-only mode - leaving the data connection alone"
		return 0
	fi
	_ur_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_ur_ap" ] || return 0
	_ur_sec="m_$(echo "$_ur_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	_ur_if=$(uci -q get "5gmodem.$_ur_sec.network")
	[ -n "$_ur_if" ] || return 0
	_ur_at=""
	_ur_w=$(esim_wdm)
	if [ -n "$_ur_w" ] && _wdm_owned_by_umbim "$_ur_w"; then
		_ur_at=""
	else
		case "$(apdu_backend)" in
			at|bridge) _ur_at=1 ;;
			*) return 0 ;;
		esac
	fi
	if [ -n "$_ur_at" ]; then
		ubus call "network.interface.$_ur_if" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	fi
	if [ -n "$_ur_at" ]; then
		logger -t 5gmodem "esim: dialing holds the AT port - taking $_ur_if down for the operation"
	else
		logger -t 5gmodem "esim: the data connection owns the channel - taking $_ur_if down for the operation"
	fi
	[ -n "$LIVELOG" ] && printf '%s {"type":"progress","payload":{"code":0,"message":"uplink_down","data":"%s"}}\n' \
		"$(date '+%H:%M:%S' 2>/dev/null)" "$_ur_if" >> "$LIVELOG" 2>/dev/null
	ifdown "$_ur_if" >/dev/null 2>&1
	_UPLINK_IF="$_ur_if"
	_ur_i=0
	while [ "$_ur_i" -lt 10 ]; do
		ubus call "network.interface.$_ur_if" status 2>/dev/null \
			| grep -q '"up": true' || break
		sleep 1
		_ur_i=$((_ur_i + 1))
	done
	sleep 1
}
_uplink_restore() {
	[ -n "$_UPLINK_IF" ] || return 0
	logger -t 5gmodem "esim: operation finished - bringing $_UPLINK_IF back up"
	ifup "$_UPLINK_IF" >/dev/null 2>&1
	_UPLINK_IF=""
}
trap '_uplink_restore; rm -rf "$LOCK" 2>/dev/null; rm -f /tmp/5gmodem/esim_*.$$ 2>/dev/null' EXIT INT TERM HUP

case "$1" in
	download|enable|disable|delete|nickname|flush|notif|notifications|dump-free) _uplink_release ;;
esac

if wdm_backend && _mm_owns_channel; then
	if ! _mm_esim_take; then
		err "mm_owns"
		exit 0
	fi
fi
_mm_inh_held && _mm_inh_touch

if ! wdm_backend; then
	D=$(live_port)
	[ -n "$D" ] || { err "no AT port"; exit 0; }
	esim_active "$D" || { err "esim slot not active"; exit 0; }

	for _ch in 1 2 3 4 5 6 7 8 9 10; do at_bounded "$D" "AT+CCHC=$_ch" 2 >/dev/null; done

	PORT=$(find_port)
	if [ -z "$PORT" ]; then
		if _wdm_owned_by_umbim "$(esim_wdm)"; then
			err "uplink busy"
		else
			err "no eUICC-capable AT port"
		fi
		exit 0
	fi
fi

flush_notifications() {
	R=$(run_lpac 60 notification process -a -r)
	_FLUSH_OUT="$R"
	echo "$R" | grep -q '"code":0' || { rm -f "$PORTCACHE"; }
}

_ERS_STARTED=""
_ers_echo() {
	if [ "$_ERS_STARTED" = 1 ]; then
		printf '%s\n' "$1" | sed 's/"payload":{/"payload":{"reset":1,/'
	else
		printf '%s\n' "$1"
	fi
}

esim_reset_after_switch_maybe() {
	printf '%s\n' "$1" | grep '"type":"lpa"' | tail -1 | jsonfilter -e '@.payload.code' 2>/dev/null | grep -qx 0 || return 0
	_ers_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_ers_ap" ] || return 0
	_ers_sec="m_$(echo "$_ers_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	. /usr/share/5gmodem/quirks.sh
	[ "$(esim_reset_after_switch "$(uci -q get "5gmodem.$_ers_sec.model")" \
		"$(uci -q get "5gmodem.$_ers_sec.vidpid")")" = 1 ] || return 0
	_ers_at=$(uci -q get "5gmodem.$_ers_sec.at_port")
	[ -n "$_ers_at" ] && [ -e "$_ers_at" ] || return 0
	logger -t 5gmodem "esim: profile switched - resetting the modem (AT+CFUN=1,1 on $_ers_at)"
	( /usr/share/5gmodem/reboot_modem.sh hard "$_ers_at" ) >/dev/null 2>&1 </dev/null &
	_ERS_STARTED=1
}

case "$1" in
dump-free|dump)
	CHIP=$(do_lpac 45 chip info)
	LIST=$(do_lpac 45 profile list)
	_OUT="{\"chip\":$CHIP,\"profiles\":$LIST}"
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	if [ -n "$_AP" ] && printf '%s' "$_OUT" \
	   | jsonfilter -e '@.profiles.payload.code' 2>/dev/null | grep -qx 0; then
		printf '{"available":1,"active":1}\n' > "/tmp/5gmodem/esimstat_$_AP"
		cut -d. -f1 /proc/uptime > "/tmp/5gmodem/esimstat_$_AP.t"
		printf '%s\n' "$_OUT" > "/tmp/5gmodem/esimdump_$_AP.tmp" \
			&& mv "/tmp/5gmodem/esimdump_$_AP.tmp" "/tmp/5gmodem/esimdump_$_AP"
	fi
	echo "$_OUT"
	;;
enable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile enable "$2"); flush_notifications
	esim_reset_after_switch_maybe "$O"
	_ers_echo "$O"
	;;
disable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile disable "$2"); flush_notifications
	esim_reset_after_switch_maybe "$O"
	_ers_echo "$O"
	;;
delete)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile delete "$2"); flush_notifications; echo "$O"
	;;
nickname)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	do_lpac 45 profile nickname "$2" "$3"
	;;
download)
	[ -n "$2" ] || { err "no activation code"; exit 0; }
	rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	: > "$LIVELOG"
	_ERRFILE="/tmp/5gmodem/esim_res.$$.es9err"
	rm -f "$_ERRFILE"
	O=$(do_lpac 600 profile download -a "$2")
	_LPALINE=$(printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1)
	if ! printf '%s' "$_LPALINE" | grep -q '"code":0' && [ -s "$_ERRFILE" ]; then
		_SC=$(jsonfilter -i "$_ERRFILE" -e '@.header.functionExecutionStatus.statusCodeData' 2>/dev/null)
		_SUBJ=""; _RC=""; _MSG=""; _EC=""; _SUBJID=""
		if [ -n "$_SC" ]; then
			_SUBJ=$(printf '%s' "$_SC" | jsonfilter -e '@.subjectCode' 2>/dev/null)
			_RC=$(printf '%s' "$_SC" | jsonfilter -e '@.reasonCode' 2>/dev/null)
			_MSG=$(printf '%s' "$_SC" | jsonfilter -e '@.message' 2>/dev/null)
			_EC=$(printf '%s' "$_SC" | jsonfilter -e '@.errorCode' 2>/dev/null)
			_SUBJID=$(printf '%s' "$_SC" | jsonfilter -e '@.subjectIdentifier' 2>/dev/null)
		else
			_EC=$(jsonfilter -i "$_ERRFILE" -e '@.errorCode' 2>/dev/null)
			_MSG=$(jsonfilter -i "$_ERRFILE" -e '@.errorDescription' 2>/dev/null)
		fi
		if [ -n "$_SUBJ" ] || [ -n "$_RC" ]; then
			_CODE="${_SUBJ:-?}/${_RC:-?}"
		else
			_CODE="$_EC"
		fi
		_TAIL="$_CODE"
		[ -n "$_SUBJID" ] && _TAIL="${_TAIL:+$_TAIL }$_SUBJID"
		[ -n "$_MSG" ] && _TAIL="${_TAIL:+$_TAIL: }$_MSG"
		if [ -n "$_TAIL" ]; then
			_LP=$(printf '%s' "$_LPALINE" | jsonfilter -e '@.payload.data' 2>/dev/null)
			_NEW="$_TAIL"
			case "$_LP" in
				""|Refused) : ;;
				*) case "$_TAIL" in *"$_LP") : ;; *) _NEW="$_TAIL — $_LP" ;; esac ;;
			esac
			_NEW=$(printf '%s' "$_NEW" | tr -d '\\"|&\r\n' | cut -c1-200)
			O=$(printf '%s' "$O" | sed '/"type":"lpa"/ s|"data":"[^"]*"|"data":"'"$_NEW"'"|')
		fi
	fi
	rm -f "$_ERRFILE"
	if ! printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0'; then
		_rc_p=$(live_port)
		_rc_s=$(_mbim_uim_slot); case "$_rc_s" in ''|*[!0-9]*) _rc_s=2 ;; esac
		_rc_cur=$((_rc_s - 1)); _rc_alt=0; [ "$_rc_cur" = 0 ] && _rc_alt=1
		if [ -n "$_rc_p" ] && sms_tool -d "$_rc_p" at "AT^switch_slot?" 2>/dev/null \
			| grep -qi "SIM"; then
			logger -t 5gmodem "esim: download failed - reinitializing the card so the chip responds again"
			sms_tool -d "$_rc_p" at "AT^switch_slot=$_rc_alt" >/dev/null 2>&1
			sleep 5
			sms_tool -d "$_rc_p" at "AT^switch_slot=$_rc_cur" >/dev/null 2>&1
			sleep 8
			rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
		fi
	fi
	flush_notifications
	if printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0'; then
		_PL=$(do_lpac 45 profile list)
		_PN=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[*].iccid' 2>/dev/null | grep -c .)
		_PE=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[*].profileState' 2>/dev/null \
			| grep -ci enabled)
		if [ "$_PN" = 1 ] && [ "$_PE" = 0 ]; then
			_PI=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[0].isdpAid' 2>/dev/null)
			case "$_PI" in *[!0-9A-Fa-f]*) _PI="" ;; esac
			[ "${#_PI}" -eq 32 ] || _PI=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[0].iccid' 2>/dev/null)
			if [ -n "$_PI" ]; then
				logger -t 5gmodem "esim: $_PI is the only profile - enabling it automatically"
				_PR=$(do_lpac 60 profile enable "$_PI")
				flush_notifications
				esim_reset_after_switch_maybe "$_PR"
				rm -f "/tmp/5gmodem/esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
			fi
		fi
	fi
	_ers_echo "$O"
	;;
notifications)
	do_lpac 45 notification list
	;;
notif)
	case "$2" in
		process) [ -n "$3" ] || { err "no seq"; exit 0; }
			do_lpac 60 notification process -r "$3" ;;
		remove)  [ -n "$3" ] || { err "no seq"; exit 0; }
			do_lpac 30 notification remove "$3" ;;
		*) err "usage: notif process|remove <seq>" ;;
	esac
	;;
flush)
	flush_notifications
	case "$_FLUSH_OUT" in
		*'"payload"'*) printf '%s\n' "$_FLUSH_OUT" ;;
		*) echo '{"type":"lpa","payload":{"code":-1,"message":"no answer from lpac","data":""}}' ;;
	esac
	;;
*)
	err "usage: esim.sh status|dump|dump-free|enable|disable|delete|nickname|download|notifications|flush|progress"
	;;
esac
exit 0
