#!/bin/sh

_TGT=""; _args=""
for _a in "$@"; do
	case "$_a" in
		for=*) _TGT="${_a#for=}" ;;
		*)     _args="$_args $_a" ;;
	esac
done
set -- $_args
[ -n "$_TGT" ] || _TGT=$(uci -q get 5gmodem.@5gmodem[0].active_modem)

if [ "$1" = "set" ]; then
	[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
	case "$2" in
		*[!0-9]*)
			logger -t 5gmodem "simslot: invalid slot number - rejected"
			echo '{"error":"bad slot"}'; exit 0 ;;
	esac
fi

[ "$1" = "set" ] && rm -f /tmp/5gmodem/slot_* /tmp/5gmodem/slots_* \
	/tmp/5gmodem/bandsprep_* /tmp/5gmodem/bandrestore_* \
	/tmp/5gmodem/metrics_* /tmp/5gmodem/esim_actslot \
	/tmp/5gmodem/esimstat_* 2>/dev/null

_umbim_owns_wdm() {
	[ -n "$1" ] || return 1
	for _uo in $(uci show network 2>/dev/null | sed -n "s|^network\.\([^.]*\)\.device='$1'\$|\1|p"); do
		[ "$(uci -q get "network.$_uo.proto")" = "mbim" ] || continue
		ubus call "network.interface.$_uo" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	done
	return 1
}

_REFRESH=""
[ "$1" = "refresh" ] && { _REFRESH=1; set -- status; }

_ss_am="$_TGT"
_ss_sec="m_$(echo "$_ss_am" | sed 's/[^A-Za-z0-9]/_/g')"
if [ -n "$_ss_am" ] && [ "$(uci -q get "5gmodem.$_ss_sec.kind")" = "hilink" ]; then
	echo '{"slots":[],"active":""}'
	exit 0
fi

if [ "$1" = "status" ] && [ -z "$_REFRESH" ]; then
	_SF="/tmp/5gmodem/slots_$_ss_am"
	_SFT=$(cat "$_SF.t" 2>/dev/null)
	_SNOW=$(cut -d. -f1 /proc/uptime)
	_SFRESH=""
	case "$_SFT" in
		''|*[!0-9]*) : ;;
		*) [ -s "$_SF" ] && [ "$(( _SNOW - _SFT ))" -lt 300 ] && _SFRESH=1 ;;
	esac
	if [ -n "$_SFRESH" ]; then
		cat "$_SF"
		exit 0
	fi
	_SLK="$_SF.upd"
	_SLKT=$(cat "$_SLK" 2>/dev/null)
	_SRUN=1
	case "$_SLKT" in
		''|*[!0-9]*) : ;;
		*) [ "$(( _SNOW - _SLKT ))" -lt 60 ] && _SRUN="" ;;
	esac
	if [ -n "$_SRUN" ]; then
		printf '%s\n' "$_SNOW" > "$_SLK"
		( /usr/share/5gmodem/simslot.sh refresh for="$_ss_am" ) >/dev/null 2>&1 </dev/null &
	fi
	if [ -s "$_SF" ]; then
		cat "$_SF"
		exit 0
	fi
	printf '{"type":"","slots":[],"active":""}\n'
	exit 0
fi

MI=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_TGT" 2>/dev/null)

_AP="$_TGT"

if [ "$1" != "set" ] && [ -n "$_AP" ] && [ -s "/tmp/5gmodem/slots_$_AP" ]; then
	_sc_t=$(cat "/tmp/5gmodem/slots_$_AP.t" 2>/dev/null)
	case "$_sc_t" in
		''|*[!0-9]*) : ;;
		*) _sc_age=$(( $(cut -d. -f1 /proc/uptime) - _sc_t ))
		   if [ "$_sc_age" -ge 0 ] && [ "$_sc_age" -lt 30 ]; then
			cat "/tmp/5gmodem/slots_$_AP"; exit 0
		   fi ;;
	esac
fi

_SEC=$(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.path='$_AP'\$/\1/p" | head -1)
_NET=$(uci -q get "5gmodem.$_SEC.network")
_PROTO=$(uci -q get "network.$_NET.proto")
export QMI_TARGET_PATH="$_AP"
case "$_PROTO" in
	modemmanager) ;;
	"") [ -n "$MI" ] || MI="" ;;
	*) MI="" ;;
esac

_AVIDPID=""; _APROD=""
if [ -n "$_AP" ]; then
	_AJ=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
	_AVIDPID=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].vidpid" 2>/dev/null)
	_APROD=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].product" 2>/dev/null)
fi

. /usr/share/5gmodem/lib.sh 2>/dev/null
. /usr/share/5gmodem/quirks.sh
. /usr/share/5gmodem/esimcaps.sh
_SVIA=$(sim_slots_via "$(uci -q get "5gmodem.$_SEC.model") $_APROD" "$_AVIDPID")
if [ "$1" != "set" ] && [ "$_SVIA" = none ]; then
	echo '{"type":"","slots":[],"active":""}'; exit 0
fi
_SLOT_NOAT=""
if [ "$1" != set ] && bg_at_off "$_AP"; then
	_SLOT_NOAT=1
	at_query() { return 1; }
	sms_tool() { return 1; }
fi
. /usr/share/5gmodem/iscompal.sh
if is_compal "$_AP" "" "$(uci -q get "5gmodem.$_SEC.at_port")"; then
	MI=""
fi
_FRAG=$(mm_at_fragile "$_AVIDPID" "$_AP")

_at_slot_cmd() {
	for _asc_n in "^switch_slot" "+SWITCH_SLOT"; do
		at_query "$1" "AT${_asc_n}?" 6 2>/dev/null | grep -qi "SIM" && {
			printf '%s\n' "$_asc_n"
			return 0
		}
	done
	return 1
}

_at_slot_set() {
	_as_at="$SLOT_AT_PORT"
	[ -n "$_as_at" ] || _as_at=$(uci -q get "5gmodem.$_ss_sec.at_port")
	[ -n "$_as_at" ] && [ -e "$_as_at" ] || return 1
	_as_cmd=$(_at_slot_cmd "$_as_at") || return 1
	_as_o=$(at_query "$_as_at" "AT${_as_cmd}=$(($1 - 1))" 8 2>/dev/null)
	case "$_as_o" in
		*ERROR*)
			logger -t 5gmodem "simslot: AT$_as_cmd=$(($1 - 1)) rejected by the firmware"
			return 1 ;;
	esac
	_as_ok=0
	for _as_i in 1 2 3 4 5 6; do
		sleep 2
		at_query "$_as_at" "AT${_as_cmd}?" 6 2>/dev/null \
			| grep -qi "SIM$1 ENABLE" && { _as_ok=1; break; }
	done
	[ "$_as_ok" = 1 ] || return 1
	logger -t 5gmodem "SIM slot switched to $1 via AT$_as_cmd"
	rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
	( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
	  _IF=$(uci -q get "5gmodem.$_ss_sec.network")
	  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
	) >/dev/null 2>&1 </dev/null &
	echo '{"result":"ok"}'
	sleep 1
	return 0
}

_slot_at_mm() {
	mm_at_allowed "$_AP" "$_SEC" || return 0
	if [ -n "$MM_AT_PORT" ]; then
		echo "$MM_AT_PORT"
	else
		uci -q get "5gmodem.$_SEC.at_port"
	fi
}
SLOT_AT_PORT=""

if [ -n "$MI" ]; then
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		if [ -n "$_FRAG" ]; then
			SLOT_AT_PORT=$(_slot_at_mm)
			[ -n "$SLOT_AT_PORT" ] || SLOT_AT_PORT=$(uci -q get "5gmodem.$_SEC.at_port")
			_at_slot_set "$2" && exit 0
			echo '{"error":"switch failed"}'; exit 0
		fi
		if mmcli -m "$MI" --set-primary-sim-slot="$2" >/dev/null 2>&1; then
			echo '{"result":"ok"}'
			exit 0
		fi
		logger -t 5gmodem "slots: ModemManager did not switch the slot - trying directly"
		SLOT_AT_PORT=$(_slot_at_mm)
		;;
	*)
		K=$(mmcli -m "$MI" -K 2>/dev/null)
		N=$(echo "$K" | sed -n 's/^modem\.generic\.sim-slots\.length *: *//p' | tr -dc 0-9)
		ACT=$(echo "$K" | sed -n 's/^modem\.generic\.primary-sim-slot *: *//p' | tr -dc 0-9)
		OUT=""
		if [ "${N:-0}" -le 1 ] 2>/dev/null && [ "$_SVIA" = qmi ] && [ -n "$(mm_at_fragile "$_AVIDPID" "$_AP")" ]; then
			_nsw="/tmp/5gmodem/noswslot_$(echo "$_AP" | tr -c 'A-Za-z0-9' '_')"
			if [ -z "$(find "$_nsw" -mmin -10 2>/dev/null)" ]; then
				SLOT_AT_PORT=$(_slot_at_mm)
				if [ -n "$SLOT_AT_PORT" ] && [ -c "$SLOT_AT_PORT" ]; then
					_mcmd=$(_at_slot_cmd "$SLOT_AT_PORT")
					_mswa=""
					if [ -n "$_mcmd" ]; then
						case "$(at_query "$SLOT_AT_PORT" "AT${_mcmd}?" 6 2>/dev/null | tr -d '\r')" in
							*SIM1*) _mswa=1 ;;
							*SIM2*) _mswa=2 ;;
						esac
					else
						case "$(at_query "$SLOT_AT_PORT" "AT^switch_slot?" 6 2>/dev/null)" in
							*ERROR*) : > "$_nsw" ;;
							*)
								if grep -q '"id":"2"' "/tmp/5gmodem/slots_$_ss_am" 2>/dev/null; then
									cat "/tmp/5gmodem/slots_$_ss_am"
									exit 0
								fi ;;
						esac
					fi
					if [ -n "$_mswa" ]; then
						printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"1"},{"id":"2","label":"eSIM","present":"1"}],"active":"%s"}\n' "$_mswa" \
							> "/tmp/5gmodem/slots_$_ss_am"
						cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_ss_am.t"
						cat "/tmp/5gmodem/slots_$_ss_am"
						exit 0
					fi
				fi
			fi
		fi
		if [ -n "$N" ] && [ "$N" = 1 ] 2>/dev/null; then
			_SP1=$(echo "$K" | sed -n 's/^modem\.generic\.sim-slots\.value\[1\] *: *//p')
			_PR1=1; case "$_SP1" in ''|'/'|'--') _PR1=0 ;; esac
			printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"%s"}],"active":"1"}\n' "$_PR1" \
				> "/tmp/5gmodem/slots_$_ss_am"
			cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_ss_am.t"
			cat "/tmp/5gmodem/slots_$_ss_am"
			exit 0
		fi
		if [ -n "$N" ] && [ "$N" -ge 2 ] 2>/dev/null; then
			L_ALL=""; P_ALL=""
			i=1
			while [ "$i" -le "$N" ]; do
				LBL="SIM$i"
				SP=$(echo "$K" | sed -n "s/^modem\.generic\.sim-slots\.value\[$i\] *: *//p")
				_PR=0
				case "$SP" in
					/org/*)
						_PR=1
						ST=$(mmcli --sim "$SP" -K 2>/dev/null \
							| sed -n 's/^sim\.properties\.sim-type *: *//p' | tr -d ' ')
						case "$ST" in
							esim)     LBL="eSIM";;
							physical) LBL="SIM";;
						esac
						;;
				esac
				L_ALL="$L_ALL $LBL"
				P_ALL="$P_ALL $_PR"
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$i\",\"label\":\"$LBL\",\"present\":\"$_PR\"}"
				i=$((i + 1))
			done
			if [ "$(echo $L_ALL | tr ' ' '\n' | sort | uniq -d)" != "" ]; then
				OUT=""
				i=1
				for _pr in $P_ALL; do
					[ -n "$OUT" ] && OUT="$OUT,"
					OUT="$OUT{\"id\":\"$i\",\"label\":\"SIM$i\",\"present\":\"$_pr\"}"
					i=$((i + 1))
				done
			fi
		fi
		case "$_FRAG:$OUT" in
			1:*|*'"label":"eSIM"'*) : ;;
			:?*)
				_UW=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].wdm[0]" 2>/dev/null)
				case "$(readlink -f "/sys/class/usbmisc/${_UW##*/}/device/driver" 2>/dev/null)" in
					*/cdc_mbim)
						command -v mbimcli >/dev/null 2>&1 && {
							_ui=0
							while [ "$_ui" -lt 4 ]; do
								_us=$(mbimcli -p -d "$_UW" --ms-query-slot-info-status="$_ui" 2>/dev/null \
									| sed -n "s/.*Slot '$_ui': '\([a-z0-9-]*\)'.*/\1/p" | head -1)
								[ -n "$_us" ] || break
								case "$_us" in
									*esim*) OUT=$(printf '%s' "$OUT" | sed "s/{\"id\":\"$((_ui + 1))\",\"label\":\"[^\"]*\"/{\"id\":\"$((_ui + 1))\",\"label\":\"eSIM\"/") ;;
								esac
								_ui=$((_ui + 1))
							done
						} ;;
				esac ;;
		esac
		if [ -n "$OUT" ]; then
			_MMC="/tmp/5gmodem/slots_$_ss_am"
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$OUT" "$ACT" > "$_MMC"
			cut -d. -f1 /proc/uptime > "$_MMC.t"
			cat "$_MMC"
			exit 0
		fi
		[ -n "$_FRAG" ] && { echo '{"type":"","slots":[],"active":""}'; exit 0; }
		logger -t 5gmodem "slots: ModemManager did not report them - asking the modem directly"
		;;
	esac
fi

_VIA="$_SVIA"
if [ "$_VIA" = none ] && [ "$1" != set ]; then
	echo '{"type":"","slots":[],"active":""}'; exit 0
fi

if [ -n "$_FRAG" ] && [ -z "$MI" ] && [ "$_PROTO" = modemmanager ]; then
	[ "$1" = set ] && { echo '{"error":"switch failed"}'; exit 0; }
	echo '{"type":"","slots":[],"active":""}'; exit 0
fi
if [ -n "$_FRAG" ] && [ -z "$MI" ]; then
	if [ "$1" = set ]; then
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		_at_slot_set "$2" && exit 0
	else
		_fr_at=$(uci -q get "5gmodem.$_SEC.at_port")
		if [ -n "$_fr_at" ] && [ -c "$_fr_at" ] && _fr_cmd=$(_at_slot_cmd "$_fr_at"); then
			_fr_a=""
			case "$(at_query "$_fr_at" "AT${_fr_cmd}?" 6 2>/dev/null | tr -d '\r')" in
				*SIM1*) _fr_a=1 ;;
				*SIM2*) _fr_a=2 ;;
			esac
			if [ -n "$_fr_a" ]; then
				printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"1"},{"id":"2","label":"eSIM","present":"1"}],"active":"%s"}\n' "$_fr_a" \
					> "/tmp/5gmodem/slots_$_AP"
				cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_AP.t"
				cat "/tmp/5gmodem/slots_$_AP"
				exit 0
			fi
		fi
	fi
fi

if [ "$_VIA" = simdet ]; then
	if [ -n "$MI" ] || [ "$_PROTO" = modemmanager ]; then
		_sd_at=$(_slot_at_mm)
	else
		_sd_at=$(uci -q get "5gmodem.$_SEC.at_port")
	fi
	[ -n "$_sd_at" ] && [ -c "$_sd_at" ] || _sd_at=""
	[ "$1" = set ] || [ "$(uci -q get "5gmodem.$_SEC.no_at")" != 1 ] || _sd_at=""
	_sd_qss() {
		at_query "$_sd_at" "AT#QSS?" 4 2>/dev/null \
			| sed -n 's/^#QSS: *[0-9]*, *\([0-9]\), *\([01]\).*/\1 \2/p' | head -1
	}
	if [ -n "$_sd_at" ] && [ "$1" = set ]; then
		case "$2" in
			1|2) ;;
			*) logger -t 5gmodem "simslot: invalid slot number - rejected"
			   echo '{"error":"bad slot"}'; exit 0 ;;
		esac
		. /usr/share/5gmodem/atlock.sh
		_sd_held="$_AT_LOCK_HELD"
		at_lock "$_sd_at" 8 || { echo '{"error":"port busy"}'; exit 0; }
		at_query "$_sd_at" "AT#SIMDET=$(($2 - 1))" 6 >/dev/null 2>&1
		_sd_m=$(at_query "$_sd_at" "AT#SIMDET?" 4 2>/dev/null \
			| sed -n 's/^#SIMDET: *\([0-9]\).*/\1/p' | head -1)
		_sd_ok=0
		if [ "$_sd_m" = "$(($2 - 1))" ]; then
			for _sd_i in 1 2 3 4 5; do
				_sd_q=$(_sd_qss)
				[ "${_sd_q#* }" = "$(($2 - 1))" ] && { _sd_ok=1; break; }
				sleep 1
			done
		fi
		[ -n "$_sd_held" ] || at_unlock
		if [ "$_sd_ok" != 1 ]; then
			logger -t 5gmodem "simslot: AT#SIMDET=$(($2 - 1)) rejected by the firmware"
			echo '{"error":"switch failed"}'; exit 0
		fi
		logger -t 5gmodem "SIM slot switched to $2 via AT#SIMDET"
		rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
		( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
		  _IF=$(uci -q get "5gmodem.$_ss_sec.network")
		  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
		) >/dev/null 2>&1 </dev/null &
		echo '{"result":"ok"}'
		sleep 1
		exit 0
	fi
	if [ -n "$_sd_at" ]; then
		_sd_q=$(_sd_qss)
		case "$_sd_q" in
			[0-9]" "[01])
				_sd_a=$(( ${_sd_q#* } + 1 ))
				_sd_p=1; [ "${_sd_q% *}" = 0 ] && _sd_p=0
				_sd_p1=""; _sd_p2=""
				if [ "$_sd_a" = 1 ]; then _sd_p1=",\"present\":\"$_sd_p\""; else _sd_p2=",\"present\":\"$_sd_p\""; fi
				_sd_out=$(printf '{"type":"","slots":[{"id":"1","label":"SIM1"%s},{"id":"2","label":"SIM2"%s}],"active":"%s"}' "$_sd_p1" "$_sd_p2" "$_sd_a")
				printf '%s\n' "$_sd_out" > "/tmp/5gmodem/slots_$_AP"
				cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_AP.t"
				printf '%s\n' "$_sd_out"
				exit 0 ;;
		esac
		if [ -s "/tmp/5gmodem/slots_$_AP" ]; then
			cat "/tmp/5gmodem/slots_$_AP"; exit 0
		fi
	fi
	_VIA=qmi
fi

if [ "$_VIA" = qmi ]; then
	if command -v qmi_channel_free >/dev/null 2>&1 && ! qmi_channel_free; then
		if [ "$1" = set ]; then
			[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
			_at_slot_set "$2" && exit 0
			echo '{"error":"qmi busy"}'; exit 0
		fi
		_swf_at=$(uci -q get "5gmodem.$_SEC.at_port")
		if [ "$1" != set ] && [ -n "$_swf_at" ] && [ -c "$_swf_at" ]; then
			_swf=""
			for _swf_n in "^switch_slot" "+SWITCH_SLOT"; do
				_swf=$(at_query "$_swf_at" "AT${_swf_n}?" 6 2>/dev/null | tr -d '\r')
				case "$_swf" in *SIM[12]*) break ;; esac
				_swf=""
			done
			_swf_a=""
			case "$_swf" in
				*SIM1*) _swf_a=1 ;;
				*SIM2*) _swf_a=2 ;;
			esac
			if [ -n "$_swf_a" ]; then
				_swf_out=$(printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"1"},{"id":"2","label":"eSIM","present":"1"}],"active":"%s"}' "$_swf_a")
				printf '%s\n' "$_swf_out" > "/tmp/5gmodem/slots_$_AP"
				cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_AP.t"
				printf '%s\n' "$_swf_out"
				exit 0
			fi
		fi
		echo '{"error":"qmi busy"}'; exit 0
	fi
	_WDM=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].wdm[0]" 2>/dev/null)
	[ -n "$_WDM" ] && [ -e "$_WDM" ] || { echo '{"error":"no qmi device"}'; exit 0; }
	_q() {
		_qo="/tmp/5gmodem/uim.$$"
		qmicli_p "$_WDM" "$@" > "$_qo" 2>&1 &
		_qp=$!
		( sleep 20; kill -9 "$_qp" 2>/dev/null ) >/dev/null 2>&1 &
		_qw=$!
		wait "$_qp" 2>/dev/null; kill "$_qw" 2>/dev/null; wait "$_qw" 2>/dev/null
		cat "$_qo"; rm -f "$_qo"
	}
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		_at_slot_set "$2" && exit 0
		if _q --uim-switch-slot="$2" 2>/dev/null | grep -qi "success"; then
			rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
			( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
			  _IF=$(uci -q get "5gmodem.$_ss_sec.network")
			  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
			) >/dev/null 2>&1 </dev/null &
			echo '{"result":"ok"}'
			sleep 1
		else
			echo '{"error":"switch failed"}'
		fi
		;;
	*)
		_S=""
		_MBS=""
		case "$(readlink -f "/sys/class/usbmisc/${_WDM##*/}/device/driver" 2>/dev/null)" in
			*/cdc_mbim)
				if command -v mbimcli >/dev/null 2>&1 && qmi_channel_free; then
					_MLK="/var/lock/5gmodem_qmi_${_WDM##*/}.lock"
					exec 8>"$_MLK" 2>/dev/null
					_mi=0
					while [ "$_mi" -lt 10 ]; do
						flock -n 8 2>/dev/null && break
						sleep 1
						_mi=$((_mi + 1))
					done
					_MPX=""
					pgrep -f 'sbin/ModemManager$' >/dev/null 2>&1 && _MPX="-p"
					_umbim_owns_wdm "$_WDM" && _MPX="SKIP"
					if [ "$_MPX" = "SKIP" ]; then
						_MMAP=""
					else
					_MMAP=$(mbimcli $_MPX -d "$_WDM" --ms-query-device-slot-mappings 2>/dev/null)
					_MACT=$(printf '%s' "$_MMAP" | sed -n "s/.*Executor '0': slot '\([0-9]*\)'.*/\1/p" | head -1)
					if [ -n "$_MACT" ]; then
						_mn=0
						while [ "$_mn" -lt 4 ]; do
							_MST=""
							for _mt in 1 2; do
								_MI=$(mbimcli $_MPX -d "$_WDM" --ms-query-slot-info-status="$_mn" 2>/dev/null)
								_MST=$(printf '%s' "$_MI" | sed -n "s/.*Slot '$_mn': '\([a-z0-9-]*\)'.*/\1/p" | head -1)
								[ -n "$_MST" ] && break
								sleep 1
							done
							[ -n "$_MST" ] || break
							case "$_MST" in
								*empty*) _MP=0 ;;
								*)       _MP=1 ;;
							esac
							case "$_MST" in
								*esim*) _ML="eSIM" ;;
								*)      _ML="SIM$((_mn + 1))" ;;
							esac
							[ -n "$_MBS" ] && _MBS="$_MBS,"
							_MBS="$_MBS{\"id\":\"$((_mn + 1))\",\"label\":\"$_ML\",\"present\":\"$_MP\"}"
							_mn=$((_mn + 1))
						done
						[ -n "$_MBS" ] && _MACT=$((_MACT + 1))
					fi
					fi
					exec 8>&- 2>/dev/null
				fi
				;;
		esac
		case ",$(printf '%s' "$_MBS" | sed 's/[^0-9,]*"id":"\([0-9]*\)"[^0-9,]*/\1,/g')" in
			*",$_MACT,"*) : ;;
			*) [ -n "$_MBS" ] && logger -t 5gmodem "slots: active $_MACT missing from the list - incomplete read, using the cache"
			   _MBS="" ;;
		esac
		if [ -n "$_MBS" ]; then
			_CACHE="/tmp/5gmodem/slots_$_AP"
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$_MBS" "$_MACT" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"
			cat "$_CACHE"
			exit 0
		fi
		_S=$(_q --uim-get-slot-status 2>/dev/null)
		_OUT=""; _ACT=""
		_N=$(echo "$_S" | sed -n 's/^ *Physical slot \([0-9]*\):.*/\1/p')
		for _i in $_N; do
			_B=$(echo "$_S" | sed -n "/^ *Physical slot $_i:/,/^ *Physical slot [0-9]*:/p" \
				| grep -v "^ *Physical slot $((_i + 1)):")
			echo "$_B" | grep -qi "Card status: *present" && _P=1 || _P=0
			echo "$_B" | grep -qi "Slot status: *active" && _ACT="$_i"
			if echo "$_B" | grep -qi "Is eUICC: *yes"; then _L="eSIM"; else _L="SIM$_i"; fi
			[ -n "$_OUT" ] && _OUT="$_OUT,"
			_OUT="$_OUT{\"id\":\"$_i\",\"label\":\"$_L\",\"present\":\"$_P\"}"
		done
		_CACHE="/tmp/5gmodem/slots_$_AP"
		if [ -n "$_OUT" ] && [ -n "$_ACT" ]; then
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$_OUT" "$_ACT" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"
			cat "$_CACHE"
		elif [ -s "$_CACHE" ]; then
			cat "$_CACHE"
		else
			printf '{"type":"","slots":[],"active":""}\n'
		fi
		;;
	esac
	exit 0
fi

live_port() {
	_LPT=$(drop_dial_port "$_TGT" $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$_TGT\"].tty[*]" 2>/dev/null))
	[ -n "$_LPT" ] || return 1
	_D=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	case " $_LPT " in
		*" $_D "*) _LPT="$_D $_LPT" ;;
	esac
	for _t in $_LPT; do
		[ -e "$_t" ] || continue
		/usr/share/5gmodem/atprobe.sh "$_t" >/dev/null 2>&1 && { echo "$_t"; return 0; }
	done
	return 1
}

D=""
[ -n "$_SLOT_NOAT" ] || D=$(live_port)
. /usr/share/5gmodem/atlock.sh
_LOCKED=1
[ -n "$D" ] && { at_lock "$D" 10; _LOCKED=$?; }
if [ -z "$D" ]; then
	if [ "$1" != "set" ] && [ -s "/tmp/5gmodem/slots_$_AP" ]; then
		cat "/tmp/5gmodem/slots_$_AP"; exit 0
	fi
	echo '{"error":"no device"}'; exit 0
fi

at_has_gtdualsim() {
	at_query "$D" "AT+GTDUALSIM=?" 6 | grep -qE '\(0[-,]1\)'
}

slot_redial() {
	_n=0
	while [ "$_n" -lt 120 ]; do
		sleep 3; _n=$((_n + 3))
		[ -n "$_TGT" ] || break
		/usr/share/5gmodem/listmodems.sh 2>/dev/null | grep -q "\"$_TGT\"" && break
	done
	/usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
	_IF=$(uci -q get "5gmodem.$_ss_sec.network")
	[ -n "$_IF" ] || return 0
	ifdown "$_IF" >/dev/null 2>&1
	sleep 2
	ifup "$_IF" >/dev/null 2>&1
}

if [ "$_VIA" = uims ]; then
	case "$1" in
	set)
		case "$2" in
			1|2) ;;
			*) logger -t 5gmodem "simslot: invalid slot number - rejected"
			   echo '{"error":"bad slot"}'; exit 0 ;;
		esac
		O=$(at_query "$D" "AT!UIMS=$(($2 - 1))" 8)
		if echo "$O" | grep -q "ERROR"; then
			echo '{"error":"switch failed"}'
		else
			rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
			( slot_redial ) >/dev/null 2>&1 </dev/null &
			echo '{"result":"ok"}'
			sleep 1
		fi
		;;
	*)
		_uq=$(at_query "$D" "AT!UIMS?" 6 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*!UIMS: *\([0-9]\)[, ]*\([0-9]\)\{0,1\}.*/\1 \2/p' | head -1)
		_usel="${_uq%% *}"; _uused="${_uq#* }"
		[ "$_usel" = 3 ] && _usel="$_uused"
		case "$_usel" in
			0) _uact=1 ;;
			1) _uact=2 ;;
			*) echo '{"type":"","slots":[],"active":""}'; exit 0 ;;
		esac
		_uo=$(printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"1"},{"id":"2","label":"eSIM","present":"1"}],"active":"%s"}' "$_uact")
		printf '%s\n' "$_uo" > "/tmp/5gmodem/slots_$_AP"
		cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_AP.t"
		printf '%s\n' "$_uo"
		;;
	esac
	exit 0
fi

if [ "$_VIA" = quimslot ]; then
	_qi_read() {
		at_query "$D" "AT+QUIMSLOT?" 6 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*+QUIMSLOT: *\([0-9]\).*/\1/p' | head -1
	}
	case "$1" in
	set)
		case "$2" in
			1|2) ;;
			*) logger -t 5gmodem "simslot: invalid slot number - rejected"
			   echo '{"error":"bad slot"}'; exit 0 ;;
		esac
		O=$(at_query "$D" "AT+QUIMSLOT=$2" 8)
		if echo "$O" | grep -q "ERROR"; then
			echo '{"error":"switch failed"}'; exit 0
		fi
		_qi_a=""
		for _qi_i in 1 2 3; do
			sleep 2
			_qi_a=$(_qi_read)
			[ "$_qi_a" = "$2" ] && break
		done
		if [ -n "$_qi_a" ] && [ "$_qi_a" != "$2" ]; then
			echo '{"error":"switch failed"}'; exit 0
		fi
		rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
		logger -t 5gmodem "SIM slot switched to $2 via AT+QUIMSLOT"
		( slot_redial ) >/dev/null 2>&1 </dev/null &
		echo '{"result":"ok"}'
		sleep 1
		;;
	*)
		_qi_act=$(_qi_read)
		case "$_qi_act" in
			1|2) ;;
			*)
			    if [ -s "/tmp/5gmodem/slots_$_AP" ]; then
				cat "/tmp/5gmodem/slots_$_AP"; exit 0
			    fi
			    echo '{"type":"","slots":[],"active":""}'; exit 0 ;;
		esac
		_qi_l2="SIM2"
		_qi_es=$(sed -n 's/.*"available": *\([0-9]\).*/\1/p' \
			"/tmp/5gmodem/esimstat_$_TGT" 2>/dev/null)
		if [ "$_qi_es" != 1 ] && esim_capable "$_AVIDPID" "$_APROD"; then
			at_query "$D" "AT+QESIM=\"eid\"" 6 2>/dev/null \
				| grep -q '"eid",[0-9]' && _qi_es=1
		fi
		[ "$_qi_es" = 1 ] && _qi_l2="eSIM"
		_qi_out=$(printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"1"},{"id":"2","label":"%s","present":"1"}],"active":"%s"}' "$_qi_l2" "$_qi_act")
		printf '%s\n' "$_qi_out" > "/tmp/5gmodem/slots_$_AP"
		cut -d. -f1 /proc/uptime > "/tmp/5gmodem/slots_$_AP.t"
		printf '%s\n' "$_qi_out"
		;;
	esac
	exit 0
fi

case "$1" in
set)
	[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
	if command -v is_num >/dev/null 2>&1 && ! is_num "$2"; then
		logger -t 5gmodem "simslot: invalid slot number - rejected"
		echo '{"error":"bad slot"}'; exit 0
	fi
	if at_has_gtdualsim; then
		O=$(at_query "$D" "AT+GTDUALSIM=$2" 8)
	else
		O=$(at_query "$D" "AT+CEISWITCHSIM=$2" 8)
	fi
	# see docs/subsystems/sim-slots.md#empty-answer-after-switch
	if echo "$O" | grep -q "ERROR"; then
		echo '{"error":"switch failed"}'
	else
		rm -f "/tmp/5gmodem/slots_$_AP" "/tmp/5gmodem/slots_$_AP.t"
		( slot_redial ) >/dev/null 2>&1 </dev/null &
		echo '{"result":"ok"}'
		sleep 1
	fi
	;;
*)
	TYPE=""; ACT=""
	if [ "$_VIA" != ceiswitchsim ]; then
		T=$(at_query "$D" "AT+SIMTYPE?" 6 \
			| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
		case "$T" in
			0) TYPE="USIM";;
			1) TYPE="eSIM";;
		esac
		ACT=$(at_query "$D" "AT+GTDUALSIM?" 6 \
			| sed -n 's/^+GTDUALSIM *: *\([0-9]\).*/\1/p' | head -1)
	fi
	if [ -n "$_SEC" ] && [ -n "$ACT" ] && [ -n "$TYPE" ]; then
		if [ "$(uci -q get "5gmodem.$_SEC.slot_type_$ACT")" != "$TYPE" ]; then
			uci -q set "5gmodem.$_SEC.slot_type_$ACT=$TYPE"
			uci -q commit 5gmodem
		fi
	fi
	slot_label() {
		case "$(uci -q get "5gmodem.$_SEC.slot_type_$1")" in
			eSIM) echo "eSIM";;
			USIM) echo "SIM";;
			*)    echo "$2";;
		esac
	}
	OUT=""
	R=$(at_query "$D" "AT+GTDUALSIM=?" 6 | grep -i '^+GTDUALSIM' | head -1)
	if echo "$R" | grep -qE '\(0[-,]1\)'; then
		L0=$(slot_label 0 SIM0)
		L1=$(slot_label 1 SIM1)
		_ESAV=$(sed -n 's/.*"available": *\([0-9]\).*/\1/p' \
			"/tmp/5gmodem/esimstat_$_TGT" 2>/dev/null)
		if [ "$_ESAV" != 1 ] \
		   && esim_capable "$(uci -q get "5gmodem.$_SEC.vidpid")" \
				   "$(uci -q get "5gmodem.$_SEC.product")"; then
			_ESAV=1
		fi
		if [ "$_ESAV" = 1 ]; then
			[ "$L0" = SIM ] && case "$L1" in SIM0|SIM1) L1="eSIM";; esac
			[ "$L1" = SIM ] && case "$L0" in SIM0|SIM1) L0="eSIM";; esac
		fi
		[ "$L0" = "$L1" ] && { L0="SIM0"; L1="SIM1"; }
		OUT='{"id":"0","label":"'$L0'"},{"id":"1","label":"'$L1'"}'
	fi

	if [ -z "$OUT" ]; then
		CEI=$(sms_tool -d "$D" at "AT+CEISWITCHSIM?" 2>/dev/null | tr -d '\r')
		if echo "$CEI" | grep -q "^Physical SIM SLOT"; then
			ACT=$(echo "$CEI" | sed -n 's/^Physical SIM SLOT \([0-9]\) maps to SIM1,.*/\1/p' | head -1)
			OUT=""
			for _i in 1 2; do
				_ins=$(echo "$CEI" | sed -n "s/^Physical SIM SLOT $_i maps to SIM[0-9],SIM inserted \([0-9]\).*/\1/p" | head -1)
				[ -n "$_ins" ] || continue
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$_i\",\"label\":\"SIM$_i\",\"present\":\"$_ins\"}"
			done
		fi
	fi
	_CACHE="/tmp/5gmodem/slots_$_AP"
	_SJSON="{\"type\":\"$TYPE\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
	if [ -n "$OUT" ] && [ -n "$ACT" ]; then
		printf '%s\n' "$_SJSON" > "$_CACHE"
		cut -d. -f1 /proc/uptime > "$_CACHE.t"
		cat "$_CACHE"
	elif [ -s "$_CACHE" ]; then
		cat "$_CACHE"
	else
		if [ "$_LOCKED" = 0 ]; then
			printf '%s\n' "$_SJSON" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"
		fi
		printf '%s\n' "$_SJSON"
	fi
	;;
esac
exit 0
