#!/bin/sh

#
# (c) 2022-2024 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2022-2024 modified by Rafał Wabik - IceG - From eko.one.pl forum
#

case "$1" in
	json|jsonrefresh|mgmtinfo|getmode|getsupportedmodes|getcelllock|applyresult)
		case "$2" in
			'') : ;;
			*[!0-9.:_-]*) : ;;
			*) BANDS_ACTIVE_MODEM="$2" ;;
		esac ;;
esac

if [ "$1" = "mmsetbands" ]; then
	[ -n "$2" ] || { echo "no bands"; exit 1; }
	[ -n "$3" ] || { echo "no modem index"; exit 1; }
	case "$3" in ''|*[!0-9]*) echo "bad index"; exit 1 ;; esac
	command -v mmcli >/dev/null 2>&1 || { echo "no mmcli"; exit 1; }
	case "$2" in
		*[!a-zA-Z0-9\|-]*) echo "bad bands"; exit 1 ;;
	esac
	case "$2" in
		\|*|*\|) echo "bad bands"; exit 1 ;;
		*\|\|*)  echo "bad bands"; exit 1 ;;
	esac
	_mb_w=""
	for _mb_d in /dev/cdc-wdm*; do [ -e "$_mb_d" ] && { _mb_w="$_mb_d"; break; }; done
	if [ -n "$_mb_w" ]; then
		exec 7>"/var/lock/5gmodem_qmi_${_mb_w##*/}.lock" 2>/dev/null
		_mb_i=0
		while [ "$_mb_i" -lt 20 ]; do
			flock -n 7 2>/dev/null && break
			sleep 1
			_mb_i=$((_mb_i + 1))
		done
	fi
	logger -t 5gmodem "bands: applying via MM ($2)"
	mmcli -m "$3" --set-current-bands="$2" 2>&1
	_mb_rc=$?
	exec 7>&- 2>/dev/null
	exit "$_mb_rc"
fi

active_modem() {
	[ -n "$BANDS_ACTIVE_MODEM" ] && { printf '%s\n' "$BANDS_ACTIVE_MODEM"; return 0; }
	uci -q get 5gmodem.@5gmodem[0].active_modem
}

_persist_bands() {
	_pb_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
	[ "$_pb_sec" != "m_" ] || return 0
	case "$2" in
		default|'') uci -q delete "5gmodem.$_pb_sec.save_band$1" 2>/dev/null ;;
		*)          uci -q set "5gmodem.$_pb_sec.save_band$1=$2" ;;
	esac
	uci -q commit 5gmodem
	_pb_if=$(uci -q get "5gmodem.$_pb_sec.network")
	[ -n "$_pb_if" ] && : > "/tmp/5gmodem/bandrestore_$_pb_if" 2>/dev/null
}

_persist_mode() {
	_pm_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
	[ "$_pm_sec" != "m_" ] || return 0
	case "$1" in
		'') uci -q delete "5gmodem.$_pm_sec.save_mode" 2>/dev/null ;;
		*)  uci -q set "5gmodem.$_pm_sec.save_mode=$1" ;;
	esac
	uci -q commit 5gmodem
	_pm_if=$(uci -q get "5gmodem.$_pm_sec.network")
	[ -n "$_pm_if" ] && : > "/tmp/5gmodem/bandrestore_$_pm_if" 2>/dev/null
}

hextobands() {
	BANDS=""
	HHEX=""
	HEX="$1"
	case "${HEX#0x}" in
		''|*[!0-9A-Fa-f]*) echo ""; return 0 ;;
	esac
	LEN=${#HEX}
	if [ $LEN -gt 18 ]; then
		CNT=$((LEN - 16))
		HHEX=${HEX:0:CNT}
		HEX="0x"${HEX:CNT}
	fi

	for B in $(seq 0 63); do
		POW=$((2 ** $B))
		T=$((HEX&$POW))
		[ "x$T" = "x$POW" ] && BANDS="${BANDS}$((B + 1)) "
	done
	if [ -n "$HHEX" ]; then
		for B in $(seq 0 63); do
			POW=$((2 ** $B))
			T=$((HHEX&$POW))
			[ "x$T" = "x$POW" ] && BANDS="${BANDS}$((B + 1 + 64)) "
		done
	fi
	echo "$BANDS"
}

bandstohex() {
	BANDS="$1"
	SUM=0
	HSUM=0
	for BAND in $BANDS; do
		case $BAND in
			''|0|*[!0-9]*) continue ;;
		esac
		if [ $BAND -gt 64 ]; then
			B=$((BAND - 1 - 64))
			POW=$((2 ** $B))
			HSUM=$((HSUM | POW))
		else
			B=$((BAND - 1))
			POW=$((2 ** $B))
			SUM=$((SUM | POW))
		fi
	done
	if [ $HSUM -eq 0 ]; then
		HEX=$(printf '%x' $SUM)
	else
		HEX=$(printf '%x%016x' $HSUM $SUM)
	fi
	echo "$HEX"
}

bandtxt() {
	BAND=$1

	case "$BAND" in
	"1") echo " $BAND: FDD 2100 MHz";;
	"2") echo " $BAND: FDD 1900 MHz";;
	"3") echo " $BAND: FDD 1800 MHz";;
	"4") echo " $BAND: FDD 1700/2100 MHz";;
	"5") echo " $BAND: FDD  850 MHz";;
	"7") echo " $BAND: FDD 2600 MHz";;
	"8") echo " $BAND: FDD  900 MHz";;
	"11") echo "$BAND: FDD 1500 MHz";;
	"12") echo "$BAND: FDD  700 MHz";;
	"13") echo "$BAND: FDD  700 MHz";;
	"14") echo "$BAND: FDD  700 MHz";;
	"17") echo "$BAND: FDD  700 MHz";;
	"18") echo "$BAND: FDD  850 MHz";;
	"19") echo "$BAND: FDD  850 MHz";;
	"20") echo "$BAND: FDD  800 MHz";;
	"21") echo "$BAND: FDD 1500 MHz";;
	"24") echo "$BAND: FDD 1600 MHz";;
	"25") echo "$BAND: FDD 1900 MHz";;
	"26") echo "$BAND: FDD  850 MHz";;
	"28") echo "$BAND: FDD  700 MHz";;
	"29") echo "$BAND: SDL  700 MHz";;
	"30") echo "$BAND: FDD 2300 MHz";;
	"31") echo "$BAND: FDD  450 MHz";;
	"32") echo "$BAND: SDL 1500 MHz";;
	"34") echo "$BAND: TDD 2000 MHz";;
	"37") echo "$BAND: TDD 1900 MHz";;
	"38") echo "$BAND: TDD 2600 MHz";;
	"39") echo "$BAND: TDD 1900 MHz";;
	"40") echo "$BAND: TDD 2300 MHz";;
	"41") echo "$BAND: TDD 2500 MHz";;
	"42") echo "$BAND: TDD 3500 MHz";;
	"43") echo "$BAND: TDD 3700 MHz";;
	"46") echo "$BAND: LAA 5200 MHz";;
	"47") echo "$BAND: TDD 5900 MHz";;
	"48") echo "$BAND: TDD 3500 MHz";;
	"50") echo "$BAND: TDD 1500 MHz";;
	"51") echo "$BAND: TDD 1500 MHz";;
	"53") echo "$BAND: TDD 2400 MHz";;
	"54") echo "$BAND: TDD 1600 MHz";;
	"65") echo "$BAND: FDD 2100 MHz";;
	"66") echo "$BAND: FDD 1700/2100 MHz";;
	"67") echo "$BAND: SDL  700 MHz";;
	"69") echo "$BAND: SDL 2600 MHz";;
	"70") echo "$BAND: FDD 1700/2000 MHz";;
	"71") echo "$BAND: FDD  600 MHz";;
	"72") echo "$BAND: FDD  450 MHz";;
	"73") echo "$BAND: FDD  450 MHz";;
	"74") echo "$BAND: FDD 1500 MHz";;
	"75") echo "$BAND: SDL 1500 MHz";;
	"76") echo "$BAND: SDL 1500 MHz";;
	"85") echo "$BAND: FDD  700 MHz";;
	"87") echo "$BAND: FDD  410 MHz";;
	"88") echo "$BAND: FDD  410 MHz";;
	"103") echo "$BAND: FDD  700 MHz";;
	"106") echo "$BAND: FDD  900 MHz";;
	esac
}

bandtxt5g() {
	BAND=$1

	case "$BAND" in
	"1") echo " $BAND: FDD 2100 MHz";;
	"2") echo " $BAND: FDD 1900 MHz";;
	"3") echo " $BAND: FDD 1800 MHz";;
	"5") echo " $BAND: FDD  850 MHz";;
	"7") echo " $BAND: FDD 2600 MHz";;
	"8") echo " $BAND: FDD  900 MHz";;
	"12") echo "$BAND: FDD  700 MHz";;
	"13") echo "$BAND: FDD  700 MHz";;
	"14") echo "$BAND: FDD  700 MHz";;
	"18") echo "$BAND: FDD  850 MHz";;
	"20") echo "$BAND: FDD  800 MHz";;
	"24") echo "$BAND: FDD 1600 MHz";;
	"25") echo "$BAND: FDD 1900 MHz";;
	"26") echo "$BAND: FDD  850 MHz";;
	"28") echo "$BAND: FDD  700 MHz";;
	"29") echo "$BAND: SDL  700 MHz";;
	"30") echo "$BAND: TDD 2300 MHz";;
	"34") echo "$BAND: TDD 2100 MHz";;
	"38") echo "$BAND: TDD 2600 MHz";;
	"39") echo "$BAND: TDD 1900 MHz";;
	"40") echo "$BAND: TDD 2300 MHz";;
	"41") echo "$BAND: TDD 2500 MHz";;
	"46") echo "$BAND: NR-U 5200 MHz";;
	"47") echo "$BAND: TDD 5900 MHz";;
	"48") echo "$BAND: TDD 3500 MHz";;
	"50") echo "$BAND: TDD 1500 MHz";;
	"51") echo "$BAND: TDD 1500 MHz";;
	"53") echo "$BAND: TDD 2400 MHz";;
	"54") echo "$BAND: TDD 1600 MHz";;
	"65") echo "$BAND: FDD 2100 MHz";;
	"66") echo "$BAND: FDD 1700/2100 MHz";;
	"67") echo "$BAND: SDL  700 MHz";;
	"70") echo "$BAND: FDD 2000 MHz";;
	"71") echo "$BAND: FDD  600 MHz";;
	"74") echo "$BAND: FDD 1500 MHz";;
	"75") echo "$BAND: SDL 1500 MHz";;
	"76") echo "$BAND: SDL 1500 MHz";;
	"77") echo "$BAND: TDD 3700 MHz";;
	"78") echo "$BAND: TDD 3500 MHz";;
	"79") echo "$BAND: TDD 4700 MHz";;
	"80") echo "$BAND: SUL 1800 MHz";;
	"81") echo "$BAND: SUL  900 MHz";;
	"82") echo "$BAND: SUL  800 MHz";;
	"83") echo "$BAND: SUL  700 MHz";;
	"84") echo "$BAND: SUL 2100 MHz";;
	"85") echo "$BAND: FDD  700 MHz";;
	"86") echo "$BAND: SUL 1700 MHz";;
	"89") echo "$BAND: SUL  850 MHz";;
	"90") echo "$BAND: TDD 2500 MHz";;
	"91") echo "$BAND: FDD  800/1500 MHz";;
	"92") echo "$BAND: FDD  800/1500 MHz";;
	"93") echo "$BAND: FDD  900/1500 MHz";;
	"94") echo "$BAND: FDD  900/1500 MHz";;
	"95") echo "$BAND: SUL 2100 MHz";;
	"96") echo "$BAND: TDD 6000 MHz";;
	"97") echo "$BAND: SUL 2300 MHz";;
	"98") echo "$BAND: SUL 1900 MHz";;
	"99") echo "$BAND: SUL 1600 MHz)";;
	"100") echo "$BAND: FDD  900 MHz";;
	"101") echo "$BAND: TDD 1900 MHz";;
	"102") echo "$BAND: TDD 6200 MHz";;
	"104") echo "$BAND: TDD 6700 MHz";;
	"105") echo "$BAND: FDD  600 MHz";;
	"257") echo "$BAND: 28 GHz";;
	"258") echo "$BAND: 26 GHz";;
	"259") echo "$BAND: 41 GHz";;
	"260") echo "$BAND: 39 GHz";;
	"261") echo "$BAND: 28 GHz";;
	"262") echo "$BAND: 47 GHz";;
	"263") echo "$BAND: 60 GHz";;
	esac
}

_DEVICE=""
_PROFILE_LOADED=""
_DEFAULT_LTE_BANDS=""
_DEFAULT_5GNSA_BANDS=""
_DEFAULT_5GSA_BANDS=""

getinfo() {
	echo "Unsupported"
}

getsupportedbands() {
	echo "Unsupported"
}

getsupportedbandsext() {
	T=$(getsupportedbands)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt "$BAND"
	done
}

getbands() {
	echo "Unsupported"
}

getbandsext() {
	T=$(getbands)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt "$BAND"
	done
}

setbands() {
	echo "Unsupported"
}

getsupportedbands5gnsa() {
	echo "Unsupported"
}

getsupportedbandsext5gnsa() {
	T=$(getsupportedbands5gnsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

getbands5gnsa() {
	echo "Unsupported"
}

getbandsext5gnsa() {
	T=$(getbands5gnsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

setbands5gnsa() {
	echo "Unsupported"
}

getsupportedbands5gsa() {
	echo "Unsupported"
}

getsupportedbandsext5gsa() {
	T=$(getsupportedbands5gsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

getbands5gsa() {
	echo "Unsupported"
}

getbandsext5gsa() {
	T=$(getbands5gsa)
	[ "x$T" = "xUnsupported" ] && return
	for BAND in $T; do
		bandtxt5g "$BAND"
	done
}

setbands5gsa() {
	echo "Unsupported"
}

getsupportedmodes() {
	echo "Unsupported"
}

getmode() {
	echo "Unsupported"
}

setmode() {
	echo "Unsupported"
}

bands3g_style() {
	echo "combo"
}

getsupportedbands3g() {
	echo "Unsupported"
}

getbands3g() {
	echo "Unsupported"
}

setbands3g() {
	echo "Unsupported"
}

getsupportedbands2g() {
	echo "Unsupported"
}
getbands2g() {
	echo "Unsupported"
}
setbands2g() {
	echo "Unsupported"
}

getcelllock() {
	echo "Unsupported"
}

setcelllock() {
	echo "Unsupported"
}

getcelllock5g() {
	echo "Unsupported"
}

setcelllock5g() {
	echo "Unsupported"
}

get5gmode() {
	echo "Unsupported"
}

set5gmode() {
	echo "Unsupported"
}

_celllock_effective() {
	_cle_now=$(getcelllock)
	[ "$_cle_now" = "off" ] || { printf '%s\n' "$_cle_now"; return 0; }
	_cle_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_cle_sec" ] || { printf '%s\n' "$_cle_now"; return 0; }
	case "$(uci -q get "5gmodem.m_$_cle_sec.celllock")" in
		arfcn\ *|cell\ *) printf '%s remembered\n' "$(uci -q get "5gmodem.m_$_cle_sec.celllock")"; return 0 ;;
	esac
	if [ "$_CELLLOCK_WRITEONLY" = "1" ]; then
		printf 'off unlockable\n'
		return 0
	fi
	printf '%s\n' "$_cle_now"
}

_celllock_remembered() {
	_clr_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_clr_sec" ] || { echo "Unsupported"; return 0; }
	_clr_v=$(uci -q get "5gmodem.m_$_clr_sec.celllock")
	case "$_clr_v" in
		arfcn\ *|cell\ *) printf '%s remembered\n' "$_clr_v" ;;
		*) if [ "$_CELLLOCK_WRITEONLY" = "1" ]; then echo "off unlockable"; else echo "Unsupported"; fi ;;
	esac
}

_live_or_unsupported() {
	if [ "$_PORT_OK" = "1" ]; then "$@"; else echo "Unsupported"; fi
}

_ri_cereg() {
	if command -v at_query >/dev/null 2>&1; then
		at_query "$_DEVICE" "AT+CEREG?" 5 3 2>/dev/null
	else
		sms_tool -d "$_DEVICE" at "AT+CEREG?" 2>/dev/null
	fi
}

_reconnect_iface() {
	_ri_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_ri_sec" ] || return
	_ri_if=$(uci -q get "5gmodem.m_$_ri_sec.network")
	[ -n "$_ri_if" ] || return
	: > "/tmp/5gmodem/bandrestore_$_ri_if" 2>/dev/null
	_ri_n=0
	_ri_t0=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$_ri_t0" in ''|*[!0-9]*) _ri_t0=0 ;; esac
	while [ "$_ri_n" -lt 40 ]; do
		case "$(_ri_cereg | tr -d '\r' \
			| sed -n 's/^+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)" in
			1|5) break ;;
		esac
		sleep 2
		_ri_n=$((_ri_n + 1))
		_ri_t1=$(cut -d. -f1 /proc/uptime 2>/dev/null)
		case "$_ri_t1" in ''|*[!0-9]*) _ri_t1="$_ri_t0" ;; esac
		[ "$((_ri_t1 - _ri_t0))" -ge 80 ] && break
	done
	# targeted down+up instead of ifup: see docs/subsystems/bands.md#reconnect-after-a-radio-cycle
	ubus call "network.interface.$_ri_if" down >/dev/null 2>&1
	sleep 3
	ubus call "network.interface.$_ri_if" up >/dev/null 2>&1 || ifup "$_ri_if" >/dev/null 2>&1
}

_bands_live() {
	case "$_BANDS_APPLY_LIVE" in 1|reconnect) return 0 ;; *) return 1 ;; esac
}
_bands_kick() {
	[ -n "$_MBIMP_IFACE" ] && : > "/tmp/5gmodem/${_MBIMP_KIND:-mbimp}-keeper.$_MBIMP_IFACE.kick"
}
_bands_after_write() {
	_bands_kick
	case "$_BANDS_APPLY_LIVE" in
		1)         return 0 ;;
		reconnect) _reconnect_iface ;;
		*)         /usr/share/5gmodem/reboot_modem.sh soft ;;
	esac
}
_bands_flush() {
	rm -f /tmp/5gmodem/bands_* 2>/dev/null
}
_bands_set_bg() {
	(
		_sbg_how="$1"; shift
		case "$_sbg_how" in
			band)      _band_write "$@" ;;
			after)     "$@" && { _bands_flush; at_unlock; _bands_after_write; } ;;
			mode)      "$@" && { _persist_mode "$2"; _bands_flush; at_unlock; _bands_after_write; } ;;
			reconnect) "$@"; _bands_flush; at_unlock; _reconnect_iface ;;
			*)         "$@" ;;
		esac
		_bands_flush
	) >/dev/null 2>&1 </dev/null &
}

getcaenabled() {
	echo "Unsupported"
}

setcaenabled() {
	echo "Unsupported"; return 1
}

get256qam() {
	echo "Unsupported"
}

set256qam() {
	echo "Unsupported"
}

getulca() {
	echo "Unsupported"
}

setulca() {
	echo "Unsupported"
}

getantports() {
	echo "Unsupported"
}

case "$1" in restorebands) _bands_flush ;; esac

_BJ_REFRESH=""; _BJ_FORCE=""
if [ "$1" = "jsonrefresh" ]; then
	if [ -n "$_BJ_INNER" ]; then _BJ_REFRESH=1; else _BJ_FORCE=1; fi
	set -- json
fi
if [ "$1" = "json" ] && [ -z "$_BJ_REFRESH" ]; then
	_BJAM=$(active_modem)
	_BJF="/tmp/5gmodem/bands_$_BJAM"
	_BJT=$(cat "$_BJF.t" 2>/dev/null)
	case "$_BJT" in ''|*[!0-9]*) _BJT="" ;; esac
	_BJIF=$(uci -q get "5gmodem.m_$(echo "$_BJAM" | sed 's/[^A-Za-z0-9]/_/g').network" 2>/dev/null)
	[ -n "$_BJIF" ] || _BJIF=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
	_BJP=$(uci -q get "network.$_BJIF.proto" 2>/dev/null)
	_BJMDL=$(uci -q get "5gmodem.m_$(echo "$_BJAM" | sed 's/[^A-Za-z0-9]/_/g').model" 2>/dev/null)
	_BJCM=$(cat "$_BJF.m" 2>/dev/null)
	_BJTTL=300
	if [ "$_BJP" = "mbimp" ] && grep -q '"readonly": *1' "$_BJF" 2>/dev/null; then
		_BJTTL=15
	fi
	grep -q '"nolive": *1' "$_BJF" 2>/dev/null && _BJTTL=15
	_bj_idok() {
		[ -s "$_BJF" ] && [ "$_BJP" = "$(cat "$_BJF.p" 2>/dev/null)" ] \
		   && { _bjc=$(cat "$_BJF.m" 2>/dev/null); [ -z "$_BJMDL" ] || [ -z "$_bjc" ] || [ "$_BJMDL" = "$_bjc" ]; }
	}
	if [ -z "$_BJ_FORCE" ] && [ -s "$_BJF" ] && [ -n "$_BJT" ] \
	   && [ "$_BJP" = "$(cat "$_BJF.p" 2>/dev/null)" ] \
	   && { [ -z "$_BJMDL" ] || [ -z "$_BJCM" ] || [ "$_BJMDL" = "$_BJCM" ]; } \
	   && [ "$(( $(cut -d. -f1 /proc/uptime) - _BJT ))" -lt "$_BJTTL" ]; then
		cat "$_BJF"
		exit 0
	fi
	_bj_t0=$(cut -d. -f1 /proc/uptime)
	while ! mkdir "$_BJF.lk" 2>/dev/null; do
		_bj_now=$(cut -d. -f1 /proc/uptime)
		_bj_lt=$(cat "$_BJF.lk/t" 2>/dev/null)
		case "$_bj_lt" in ''|*[!0-9]*) _bj_lt="$_bj_now" ;; esac
		if [ $((_bj_now - _bj_lt)) -ge 120 ]; then rm -rf "$_BJF.lk"; continue; fi
		if [ ! -d "$_BJF.lk" ]; then
			_bj_ct=$(cat "$_BJF.t" 2>/dev/null)
			case "$_bj_ct" in ''|*[!0-9]*) _bj_ct=0 ;; esac
			[ "$_bj_ct" -ge "$_bj_t0" ] && _bj_idok && { cat "$_BJF"; exit 0; }
			continue
		fi
		if [ $((_bj_now - _bj_t0)) -ge 20 ]; then
			if _bj_idok; then cat "$_BJF"; else echo '{}'; fi
			exit 0
		fi
		sleep 1
	done
	cut -d. -f1 /proc/uptime > "$_BJF.lk/t"
	trap 'rm -rf "$_BJF.lk"' EXIT
	trap 'exit 143' INT TERM HUP
	_o=$(_BJ_INNER=1 "$0" jsonrefresh ${BANDS_ACTIVE_MODEM:+"$BANDS_ACTIVE_MODEM"} 2>/dev/null)
	_BJAM2=$(active_modem)
	case "$_o" in
		'{'*) if [ "$_BJAM2" = "$_BJAM" ]; then
		          printf '%s\n' "$_o" > "$_BJF.tmp" && mv "$_BJF.tmp" "$_BJF"
		          cut -d. -f1 /proc/uptime > "$_BJF.t"
		          printf '%s\n' "$_BJP" > "$_BJF.p"
		          printf '%s\n' "$_BJMDL" > "$_BJF.m"
		      fi
		      printf '%s\n' "$_o" ;;
		*)    printf '%s\n' "$_o" ;;
	esac
	exit 0
fi

_sa_resfile() {
	printf '/tmp/5gmodem/bandapply_%s.res\n' "$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
}
_sa_islist() {
	case "$1" in
		default) return 0 ;;
		''|*[!0-9\ ]*) return 1 ;;
	esac
	case "$1" in *[0-9]*) return 0 ;; esac
	return 1
}
_sa_bad() {
	logger -t 5gmodem "bands: invalid setall argument - rejected"
	echo "bad arguments"
	exit 2
}
_sa_res_write() {
	_srw_f=$(_sa_resfile)
	if [ "$1" != "running" ]; then
		case "$(cat "$_srw_f" 2>/dev/null)" in
			*"\"id\":\"$_SA_ID\""*) : ;;
			*) return 0 ;;
		esac
	fi
	printf '{"id":"%s","state":"%s","takeover":%s,"applied":[%s],"failed":[%s]}\n' \
		"$_SA_ID" "$1" "${_SA_TAKEOVER:-0}" "$_SA_OKJ" "$_SA_FAILJ" > "$_srw_f.tmp" 2>/dev/null \
		&& mv "$_srw_f.tmp" "$_srw_f" 2>/dev/null
}
_sa_fail_add() {
	_SA_FAILJ="${_SA_FAILJ}${_SA_FAILJ:+,}{\"what\":\"$1\",\"why\":\"$2\",\"arg\":\"$3\"}"
}
if [ "$1" = "applyresult" ]; then
	_ar_f=$(_sa_resfile)
	if [ -s "$_ar_f" ]; then cat "$_ar_f"; else echo '{"state":"none"}'; fi
	exit 0
fi
if [ "$1" = "setall" ]; then
	_SA_MODE=""; _SA_LTE=""; _SA_NSA=""; _SA_SA=""; _SA_3G=""; _SA_2G=""
	_SA_OKJ=""; _SA_FAILJ=""; _SA_TAKEOVER=0
	_SA_ID="$$"
	shift
	for _sa_a in "$@"; do
		case "$_sa_a" in *=*) : ;; *) _sa_bad ;; esac
		_sa_k="${_sa_a%%=*}"; _sa_v="${_sa_a#*=}"
		case "$_sa_k" in
			mode)
				case "$_sa_v" in *[!0-9]*) _sa_bad ;; esac
				_SA_MODE="$_sa_v" ;;
			lte|nsa|sa|3g|2g)
				if [ -n "$_sa_v" ]; then _sa_islist "$_sa_v" || _sa_bad; fi
				case "$_sa_k" in
					lte) _SA_LTE="$_sa_v" ;;
					nsa) _SA_NSA="$_sa_v" ;;
					sa)  _SA_SA="$_sa_v" ;;
					3g)  _SA_3G="$_sa_v" ;;
					2g)  _SA_2G="$_sa_v" ;;
				esac ;;
			*) _sa_bad ;;
		esac
	done
	set -- setall
	if [ -z "$_SA_MODE$_SA_LTE$_SA_NSA$_SA_SA$_SA_3G$_SA_2G" ]; then
		echo "nothing to apply"
		exit 2
	fi
fi

_bs_am=$(active_modem)
_bs_sec="m_$(echo "$_bs_am" | sed 's/[^A-Za-z0-9]/_/g')"
_bs_at=$(uci -q get "5gmodem.$_bs_sec.at_port")
. /usr/share/5gmodem/atlock.sh
if [ -n "$_bs_at" ] && ! at_lock "$_bs_at" 15 && [ "$(uci -q get "5gmodem.$_bs_sec.kind")" != hilink ]; then
	case "$1" in
		mgmtinfo|getmode|getsupportedmodes|getcelllock|applyresult) : ;;
		restorebands) at_lock "$_bs_at" 45 || logger -t 5gmodem "bands: port $_bs_at still busy, restoring bands without the queue" ;;
		json)
			_bs_cf="/tmp/5gmodem/bands_$_bs_am"
			[ -s "$_bs_cf" ] && { cat "$_bs_cf"; exit 0; }
			echo "AT port $_bs_at is busy"
			exit 1 ;;
		*)
			echo "AT port $_bs_at is busy, try again later"
			exit 1 ;;
	esac
fi
if [ -n "$_bs_am" ] && [ -z "$_bs_at" ] && [ "$(uci -q get "5gmodem.$_bs_sec.kind")" = hilink ] \
   && [ "$(uci -q get "5gmodem.$_bs_sec.hl_api")" = zte ]; then
	_HL=/usr/share/5gmodem/hilink.sh
	_bs_mtk=""
	case "$(uci -q get "5gmodem.$_bs_sec.vidpid")" in 0e8d:2004|0e8d:2008) _bs_mtk=1 ;; esac
	case "$1" in
		json)
			_bs_mb=""; [ -n "$_bs_mtk" ] && _bs_mb=$("$_HL" mtkbands "$_bs_am" 2>/dev/null)
			printf '{ "modem": "%s", "currentmode": "%s", "modes": [' \
				"$(uci -q get "5gmodem.$_bs_sec.model" | tr -d '\\"\r\n')" \
				"$("$_HL" zgetmode "$_bs_am" 2>/dev/null | tr -cd '0-9')"
			printf '{"id":"1","label":"Авто"},{"id":"8","label":"2G"},{"id":"2","label":"3G"},{"id":"4","label":"4G"}'
			if [ -n "$_bs_mb" ]; then
				printf '], "supported": ['
				_f=1
				for _b in ${_bs_mb%%|*}; do
					[ "$_f" = 1 ] || printf ','
					_f=0
					printf '{"band":%s,"txt":"B%s"}' "$_b" "$_b"
				done
				printf '], "enabled": [%s] }\n' "$(echo ${_bs_mb#*|} | tr ' ' ',')"
			else
				_bs_np=""
				[ -n "$_bs_mtk" ] && [ ! -f /usr/share/5gmodem/mtk/usock-armv7 ] && _bs_np=', "needpkg": "5gmodem-mtk-at"'
				printf '], "supported": [ ], "enabled": [ ], "nobandctl": 1%s }\n' "$_bs_np"
			fi
			exit 0 ;;
		getbands)          [ -n "$_bs_mtk" ] && { _bs_mb=$("$_HL" mtkbands "$_bs_am"); echo "${_bs_mb#*|}"; }; exit 0 ;;
		getsupportedbands) [ -n "$_bs_mtk" ] && { _bs_mb=$("$_HL" mtkbands "$_bs_am"); echo "${_bs_mb%%|*}"; }; exit 0 ;;
		setbands)          [ -n "$_bs_mtk" ] && "$_HL" mtksetbands "$2" "$_bs_am"; _bands_flush; exit 0 ;;
		getmode)           "$_HL" zgetmode "$_bs_am"; exit 0 ;;
		getsupportedmodes) echo "1:Авто 8:2G 2:3G 4:4G"; exit 0 ;;
		setmode)           "$_HL" zsetmode "$2" "$_bs_am"; _bands_flush; exit 0 ;;
		setall)
			_sa_z() {
				case "$("$_HL" "$2" "$3" "$_bs_am" 2>/dev/null)" in
					*'"success":true'*) _SA_OKJ="${_SA_OKJ}${_SA_OKJ:+,}\"$1\"" ;;
					*) _sa_fail_add "$1" rejected "" ;;
				esac
			}
			[ -z "$_SA_MODE" ] || _sa_z mode zsetmode "$_SA_MODE"
			if [ -n "$_SA_LTE" ]; then
				if [ -n "$_bs_mtk" ]; then _sa_z lte mtksetbands "$_SA_LTE"; else _sa_fail_add lte unsupported ""; fi
			fi
			[ -z "$_SA_3G" ] || _sa_fail_add 3g unsupported ""
			[ -z "$_SA_2G" ] || _sa_fail_add 2g unsupported ""
			[ -z "$_SA_NSA" ] || _sa_fail_add nsa unsupported ""
			[ -z "$_SA_SA" ] || _sa_fail_add sa unsupported ""
			_bands_flush
			_sa_res_write running
			_sa_res_write done
			cat "$(_sa_resfile)" 2>/dev/null
			exit 0 ;;
		mgmtinfo)          echo '{"source":"vendor"}'; exit 0 ;;
		*)                 echo "Unsupported"; exit 0 ;;
	esac
fi
if [ -n "$_bs_am" ] && [ "$(uci -q get "5gmodem.$_bs_sec.kind")" = "hilink" ] \
   && ! case "$(uci -q get "5gmodem.$_bs_sec.vidpid")" in 19d2:*|05c6:90b4) true ;; *) false ;; esac \
   && [ "$(uci -q get "5gmodem.$_bs_sec.hl_api")" != zte ]; then
	_HL=/usr/share/5gmodem/hilink.sh
	_bs_full=$(uci -q get "5gmodem.$_bs_sec.band_full")
	if [ -z "$_bs_full" ] && [ -n "$_bs_at" ] && [ -c "$_bs_at" ]; then
		_bs_full=$(RES="/usr/share/5gmodem/modemband"; . "$RES/$(uci -q get "5gmodem.$_bs_sec.vidpid" | tr -d ':')" 2>/dev/null; _DEVICE="$_bs_at"; getsupportedbands 2>/dev/null)
		[ -n "$_bs_full" ] && { uci -q set "5gmodem.$_bs_sec.band_full=$_bs_full"; uci -q commit 5gmodem; }
	fi
	_en=$("$_HL" getbands "$_bs_am" 2>/dev/null)
	_sup="$_bs_full"; [ -n "$_sup" ] || _sup="$_en"
	case "$1" in
		json)
			_cm=$("$_HL" getmode "$_bs_am" 2>/dev/null)
			_sup3g=$("$_HL" supbands3g "$_bs_am" 2>/dev/null)
			_en3g=""; [ -n "$_sup3g" ] && _en3g=$("$_HL" getbands3g "$_bs_am" 2>/dev/null)
			_sup2g=$("$_HL" supbands2g "$_bs_am" 2>/dev/null)
			_en2g=""; [ -n "$_sup2g" ] && _en2g=$("$_HL" getbands2g "$_bs_am" 2>/dev/null)
			_bs_mdl=$(uci -q get "5gmodem.$_bs_sec.model" | tr -d '\\"\r\n')
			_cm=$(printf '%s' "$_cm" | tr -d '\\"\r\n')
			printf '{ "modem": "%s", "currentmode": "%s", "modes": [' \
				"$_bs_mdl" "$_cm"
			printf '{"id":"1","label":"Авто"},{"id":"8","label":"2G"},{"id":"2","label":"3G"},{"id":"4","label":"4G"}'
			printf '], "supported": ['
			_f=1
			for _b in $_sup; do
				[ "$_f" = 1 ] || printf ','
				_f=0
				printf '{"band":%s,"txt":"B%s"}' "$_b" "$_b"
			done
			printf '], "enabled": [%s]' "$(echo $_en | tr ' ' ',')"
			if [ -n "$_sup3g" ]; then
				printf ', "supported3g": ['
				_f3=1
				for _b in $_sup3g; do
					[ "$_f3" = 1 ] || printf ','
					_f3=0
					printf '{"band":%s}' "$_b"
				done
				printf '], "enabled3g": [%s]' "$(echo $_en3g | tr ' ' ',')"
			fi
			if [ -n "$_sup2g" ]; then
				printf ', "supported2g": ['
				_f2=1
				for _b in $_sup2g; do
					[ "$_f2" = 1 ] || printf ','
					_f2=0
					printf '{"band":%s}' "$_b"
				done
				printf '], "enabled2g": [%s]' "$(echo $_en2g | tr ' ' ',')"
			fi
			printf ' }\n'
			exit 0 ;;
		getbands)          echo "$_en"; exit 0 ;;
		getsupportedbands) echo "$_sup"; exit 0 ;;
		getmode)           "$_HL" getmode "$_bs_am"; exit 0 ;;
		getsupportedmodes) echo "1:Авто 8:2G 2:3G 4:4G"; exit 0 ;;
		setbands)
			"$_HL" setbands "$2" "$_bs_am"
			( unset _AT_LOCK_HELD; sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null 8>&- &
			exit 0 ;;
		setmode)
			"$_HL" setmode "$2" "$_bs_am"
			( unset _AT_LOCK_HELD; sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null 8>&- &
			exit 0 ;;
		setbands3g)
			"$_HL" setbands3g "$2" "$_bs_am"
			( unset _AT_LOCK_HELD; sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null 8>&- &
			exit 0 ;;
		setbands2g)
			"$_HL" setbands2g "$2" "$_bs_am"
			( unset _AT_LOCK_HELD; sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null 8>&- &
			exit 0 ;;
		setall)
			_sa_hl() {
				case "$("$_HL" "$2" "$3" "$_bs_am" 2>/dev/null)" in
					*'"success":true'*) _SA_OKJ="${_SA_OKJ}${_SA_OKJ:+,}\"$1\"" ;;
					*) _sa_fail_add "$1" rejected "" ;;
				esac
			}
			[ -z "$_SA_MODE" ] || _sa_hl mode setmode "$_SA_MODE"
			[ -z "$_SA_LTE" ] || _sa_hl lte setbands "$_SA_LTE"
			[ -z "$_SA_3G" ] || _sa_hl 3g setbands3g "$_SA_3G"
			[ -z "$_SA_2G" ] || _sa_hl 2g setbands2g "$_SA_2G"
			[ -z "$_SA_NSA" ] || _sa_fail_add nsa unsupported ""
			[ -z "$_SA_SA" ] || _sa_fail_add sa unsupported ""
			_sa_res_write running
			_sa_res_write done
			cat "$(_sa_resfile)" 2>/dev/null
			( unset _AT_LOCK_HELD; sleep 8; /usr/share/5gmodem/modemswitch.sh autosetup "$_bs_am" ) >/dev/null 2>&1 </dev/null 8>&- &
			sleep 1
			exit 0 ;;
		mgmtinfo)
			echo '{"source":"vendor"}'; exit 0 ;;
		*) echo "Unsupported"; exit 0 ;;
	esac
fi

RES="/usr/share/5gmodem/modemband"

_AMP=$(active_modem)
_AVIDPID=""; _APROD=""
if [ -n "$_AMP" ]; then
	_AREG=$(/usr/share/5gmodem/registry.sh path "$_AMP" 2>/dev/null)
	_AVIDPID=$(printf '%s' "$_AREG" | jsonfilter -e '@.vidpid' 2>/dev/null | tr -d ':')
	_APROD=$(printf '%s' "$_AREG" | jsonfilter -e '@.product' 2>/dev/null | head -1)
	case "$_APROD" in *[!A-Za-z0-9_.-]*) _APROD="" ;; esac
fi

if [ -n "$_AMP" ]; then
	_found=""
	_ASUB=$(cat "/sys/bus/pci/devices/${_AMP##*/}/subsystem_vendor" 2>/dev/null)
	_ASUB=${_ASUB#0x}
	for _cand in "${_ASUB:+${_AVIDPID}_$_ASUB}" "$_AVIDPID$_APROD" "$_AVIDPID"; do
		[ -n "$_cand" ] || continue
		[ -e "$RES/$_cand" ] || continue
		_found="$_cand"; break
	done

	if [ -z "$_found" ] && [ -n "$_AVIDPID" ]; then
		_atp="$_bs_at"; [ -n "$_atp" ] || _atp=$(uci -q get 5gmodem.@5gmodem[0].at_port)
		if [ -n "$_atp" ] && [ -e "$_atp" ]; then
			_mdl=$(sms_tool -d "$_atp" at "AT+CGMM" 2>/dev/null | tr -d '\r' \
				| grep -vE '^(AT|OK|ERROR|$)' | head -1 | tr -d ' ')
			case "$_mdl" in
				''|*[!A-Za-z0-9_.-]*) _mdl="" ;;
			esac
			if [ -n "$_mdl" ]; then
				_nf=0
				for _f in "$RES/$_AVIDPID$_mdl"*; do
					[ -e "$_f" ] || continue
					_nf=$((_nf + 1))
					[ -n "$_found" ] || _found=$(basename "$_f")
				done
				if [ "$_nf" -gt 1 ]; then
					_rev=$(sms_tool -d "$_atp" at "AT+CGMR" 2>/dev/null | tr -d '\r' \
						| grep -vE '^(AT|OK|ERROR|$)' | head -1 | sed 's/^Revision://' | tr -d ' ')
					_best=""; _bl=0
					for _f in "$RES/$_AVIDPID$_mdl"-*; do
						[ -e "$_f" ] || continue
						_sfx=${_f##*/$_AVIDPID$_mdl-}
						case "$_rev" in
							"$_mdl$_sfx"*)
								[ "${#_sfx}" -gt "$_bl" ] && { _best=$(basename "$_f"); _bl=${#_sfx}; }
								;;
						esac
					done
					if [ -n "$_best" ]; then
						_found="$_best"
					elif [ -e "$RES/$_AVIDPID$_mdl-E" ]; then
						_found="$_AVIDPID$_mdl-E"
					fi
				fi
			fi
		fi
	fi

	[ -n "$_found" ] && { _SIFS="$IFS"; . "$RES/$_found"; IFS="$_SIFS"; _PROFILE_LOADED=1; }
else
	_DEVS=$(awk '{gsub("="," ");
	if ($0 ~ /Bus.*Lev.*Prnt.*Port.*/) {T=$0}
	if ($0 ~ /Vendor.*ProdID/) {idvendor[T]=$3; idproduct[T]=$5}
	if ($0 ~ /Product/) {product[T]=$3}}
	END {for (idx in idvendor) {printf "%s%s\n%s%s%s\n", idvendor[idx], idproduct[idx], idvendor[idx], idproduct[idx], product[idx]}}' /sys/kernel/debug/usb/devices)
	for _DEV in $_DEVS; do
		if [ -e "$RES/$_DEV" ]; then
			_SIFS="$IFS"; . "$RES/$_DEV"; IFS="$_SIFS"
			_PROFILE_LOADED=1
			break
		fi
	done
fi

if [ -n "$_PROFILE_LOADED" ]; then
	_ATP=$(printf '%s' "$_AREG" | jsonfilter -e '@.at_port' 2>/dev/null)
	[ -n "$_ATP" ] || _ATP="$_bs_at"
	if [ -z "$_ATP" ] && [ "$(printf '%s' "$_AREG" | jsonfilter -e '@.active' 2>/dev/null)" = "true" ]; then
		_ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
		[ -n "$_ATP" ] || _ATP=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	fi
	case "$_ATP" in
		/dev/*) [ -e "$_ATP" ] && _DEVICE="$_ATP" ;;
	esac
fi

if [ -n "$_DEVICE" ] && [ "$_DEVICE" != "$_bs_at" ]; then
	at_unlock
	at_lock "$_DEVICE" 15
fi

_PORT_OK=0
[ -n "$_DEVICE" ] && [ -e "$_DEVICE" ] && _PORT_OK=1
if [ "$_PORT_OK" = 1 ] && pgrep -f "gcom .*-d *$_DEVICE" >/dev/null 2>&1; then
	_PORT_OK=0
fi

_NOAT_STATIC=""
if [ "$_PORT_OK" = 1 ]; then
	if [ "$(uci -q get "5gmodem.$_bs_sec.no_at" 2>/dev/null)" = "1" ]; then
		_NOAT_STATIC=1
		_PORT_OK=0
	else
		_bo_if=$(uci -q get "5gmodem.$_bs_sec.network")
		[ -n "$_bo_if" ] || _bo_if=$(uci -q get 5gmodem.@5gmodem[0].network)
		if [ "$(uci -q get "network.$_bo_if.proto" 2>/dev/null)" != "modemmanager" ] \
		   && pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1; then
			_bo_c="/tmp/5gmodem/mmowns_$(echo "$_bs_am" | sed 's/[^A-Za-z0-9]/_/g')"
			if [ -s "$_bo_c" ] && [ -n "$(find "$_bo_c" -mmin -1 2>/dev/null)" ]; then
				_bo_v=$(cat "$_bo_c" 2>/dev/null)
			else
				_bo_v=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_bs_am" 2>/dev/null)
				_bo_v="${_bo_v:-none}"
				printf '%s\n' "$_bo_v" > "$_bo_c" 2>/dev/null
			fi
			[ -n "$_bo_v" ] && [ "$_bo_v" != "none" ] && _PORT_OK=0
		fi
		_MM_AT_STATIC=""
		if [ "$_PORT_OK" = 1 ] \
		   && [ "$(uci -q get "network.$_bo_if.proto" 2>/dev/null)" = "modemmanager" ]; then
			. /usr/share/5gmodem/quirks.sh 2>/dev/null
			mm_at_allowed "$_bs_am" "$_bs_sec"
			case "$?" in
				0)
					if [ -n "$MM_AT_PORT" ] && [ "$MM_AT_PORT" != "$_DEVICE" ]; then
						_DEVICE="$MM_AT_PORT"
						at_unlock
						at_lock "$_DEVICE" 15
					fi ;;
				2) _MM_AT_STATIC=1; _PORT_OK=0 ;;
				*) _PORT_OK=0 ;;
			esac
		fi
	fi
fi

if [ "$_BAND_VIA" = "mmcli" ]; then
	_IFACE=$(uci -q get "5gmodem.$_bs_sec.network")
	[ -n "$_IFACE" ] || _IFACE=$(uci -q get 5gmodem.@5gmodem[0].network)
	_bs_ipr=$(uci -q get "network.$_IFACE.proto" 2>/dev/null)
	_BAND_NO_TAKEOVER=""
	if [ "$_bs_ipr" = "mbimp" ]; then
		_BAND_NO_TAKEOVER=1
		_BANDS_APPLY_LIVE=1
		_MBIMP_IFACE="$_IFACE"
		_MBIMP_KIND="$_bs_ipr"
		if [ -n "$_MMIDX" ] && mmcli -m "$_MMIDX" -K >/dev/null 2>&1; then
			_bs_ipr="modemmanager"
		fi
	fi
	if [ "$_bs_ipr" != "modemmanager" ]; then
		_BAND_READONLY=1
		_PORT_OK=0
		[ -c "${_QWDM:-/dev/cdc-wdm0}" ] && command -v qmicli >/dev/null 2>&1 && _PORT_OK=1
	else
		_PORT_OK=0
		mmcli -m "$_MMIDX" -K >/dev/null 2>&1 && _PORT_OK=1
	fi
fi

if [ "$_BAND_VIA" = "mmcli" ] && [ -n "$_bs_at$_DEVICE" ]; then
	at_unlock
fi

if [ "x$1" != "xjson" ]; then
	case "$1" in
		getsupported*) : ;;
		mgmtinfo) : ;;
		setmodemm) : ;;
		set*)
			[ -n "$_MM_AT_STATIC$_NOAT_STATIC" ] && [ -n "$_DEVICE" ] && [ -c "$_DEVICE" ] && _PORT_OK=1
			if [ "$_PORT_OK" != "1" ]; then
				echo '{"error":"port not found"}'
				exit 1
			fi
			;;
		*)
			if [ "$_PORT_OK" != "1" ]; then
				echo "Port not found, quitting..."
				exit 0
			fi
			;;
	esac
fi

_needs_mm_takeover() {
	[ "$(uci -q get 5gmodem.@5gmodem[0].band_takeover 2>/dev/null)" != "0" ] || return 1
	[ "$_BAND_NO_TAKEOVER" = "1" ] && return 1
	[ "$_BAND_VIA" = "mmcli" ] && [ "$_BAND_READONLY" = "1" ]
}

_mt_traffic_ok() {
	_mtt_dev=$(ubus call "network.interface.$_mt_if" status 2>/dev/null \
		| jsonfilter -e '@.l3_device' 2>/dev/null)
	[ -n "$_mtt_dev" ] || return 0
	_mtt_t=$(uci -q get 5gmodem.health.targets 2>/dev/null)
	[ -n "$_mtt_t" ] || _mtt_t="77.88.8.8 1.1.1.1"
	for _mtt_h in $_mtt_t; do
		ping -I "$_mtt_dev" -c 1 -W 2 "$_mtt_h" >/dev/null 2>&1 && return 0
	done
	command -v curl >/dev/null 2>&1 || return 1
	for _mtt_h in $(uci -q get 5gmodem.health.restricted_targets || echo 77.88.55.242 5.255.255.242); do
		curl -sk -m 4 --interface "if!$_mtt_dev" -o /dev/null "https://$_mtt_h/" 2>/dev/null && return 0
	done
	return 1
}

_mm_takeover_run() {
	_R=/usr/share/5gmodem
	_mt_op="$1"; _mt_list="$2"
	_mt_path="$_bs_am"
	_mt_if=$(uci -q get "5gmodem.$_bs_sec.network" 2>/dev/null)
	[ -n "$_mt_if" ] || _mt_if=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
	logger -t 5gmodem "band-set: temporary MM takeover for $_mt_path (iface $_mt_if): $_mt_op $_mt_list"
	[ -n "$_mt_if" ] && ifdown "$_mt_if" 2>/dev/null
	"$_R/mm-inhibit.sh" pause "$_mt_path" 2>/dev/null
	"$_R/mmneed.sh" apply >/dev/null 2>&1
	_mt_idx=""; _mt_i=0
	while [ "$_mt_i" -lt 40 ]; do
		_mt_idx=$("$_R/modemswitch.sh" mmindex "$(active_modem)" 2>/dev/null)
		[ -n "$_mt_idx" ] && mmcli -m "$_mt_idx" -K >/dev/null 2>&1 && break
		sleep 3; _mt_i=$((_mt_i + 1))
	done
	if [ -n "$_mt_idx" ]; then
		mmcli -m "$_mt_idx" --enable >/dev/null 2>&1
		sleep 2
		_MMIDX="$_mt_idx"
		"$_mt_op" "$_mt_list"
	else
		logger -t 5gmodem "band-set: MM did not see $_mt_path in time - change cancelled"
	fi
	"$_R/mm-inhibit.sh" resume "$_mt_path" 2>/dev/null
	"$_R/mmneed.sh" apply now >/dev/null 2>&1
	_mt_i=0
	while [ "$_mt_i" -lt 20 ]; do
		mmcli -L 2>/dev/null | grep -q "/Modem/" || break
		sleep 3; _mt_i=$((_mt_i + 1))
	done
	if [ -n "$_mt_if" ]; then
		ifup "$_mt_if" 2>/dev/null
		_mt_i=0
		while [ "$_mt_i" -lt 9 ]; do
			sleep 4
			ubus call "network.interface.$_mt_if" status 2>/dev/null | grep -q '"up": true' && break
			[ "$_mt_i" = 3 ] && { ifdown "$_mt_if" 2>/dev/null; sleep 2; ifup "$_mt_if" 2>/dev/null; }
			_mt_i=$((_mt_i + 1))
		done
		_mt_i=0; _mt_ok=""
		while [ "$_mt_i" -lt 4 ]; do
			_mt_traffic_ok && { _mt_ok=1; break; }
			sleep 5; _mt_i=$((_mt_i + 1))
		done
		if [ -z "$_mt_ok" ]; then
			logger -t 5gmodem "band-set: $_mt_if is up but passes no traffic (zombie session) - bouncing it"
			ifdown "$_mt_if" 2>/dev/null; sleep 2; ifup "$_mt_if" 2>/dev/null
			_mt_i=0
			while [ "$_mt_i" -lt 9 ]; do
				sleep 4
				_mt_traffic_ok && break
				_mt_i=$((_mt_i + 1))
			done
		fi
	fi
	logger -t 5gmodem "band-set: MM takeover finished, $_mt_if is up"
}

_BW_TOK=/tmp/5gmodem/bandapply.tok
_BW_PEND=/tmp/5gmodem/bandapply.pending
_bw_serial_lock() {
	_bsl_f=/var/lock/5gmodem_bandwrite.lock
	[ -d /var/lock ] || _bsl_f=/tmp/5gmodem/bandwrite.lock
	touch "$_bsl_f" 2>/dev/null || return 0
	exec 7>"$_bsl_f"
	_bsl_n=0
	while [ "$_bsl_n" -lt 150 ]; do
		flock -n 7 2>/dev/null && return 0
		sleep 2
		_bsl_n=$((_bsl_n + 1))
	done
	return 0
}
_bw_serial_unlock() {
	flock -u 7 2>/dev/null
	exec 7>&- 2>/dev/null
	return 0
}
_band_write() {
	if _needs_mm_takeover; then
		_bw_serial_lock
		_mm_takeover_run "$1" "$2"
		_bw_serial_unlock
		return
	fi
	read -r _bw_me _ < /proc/self/stat
	_bw_serial_lock
	echo "$_bw_me" > "$_BW_TOK"
	"$1" "$2" && : > "$_BW_PEND"
	_bw_serial_unlock
	_bands_flush
	[ -f "$_BW_PEND" ] || return 1
	_bw_sr=""
	[ -f "/tmp/5gmodem/selfreset.$$" ] && { _bw_sr=1; rm -f "/tmp/5gmodem/selfreset.$$"; }
	if [ "$_BANDS_APPLY_LIVE" = 1 ] || [ -n "$_bw_sr" ]; then
		rm -f "$_BW_PEND"
		_bands_kick
		return 0
	fi
	at_unlock
	sleep 5
	[ "$(cat "$_BW_TOK" 2>/dev/null)" = "$_bw_me" ] || return 0
	rm -f "$_BW_PEND" "$_BW_TOK"
	_bands_after_write
}

. /usr/share/5gmodem/lib.sh 2>/dev/null
if command -v is_num >/dev/null 2>&1; then
	case "$1" in
		setbands|setbands5gnsa|setbands5gsa|setbands3g|setbands2g)
			if [ "$2" != "default" ] && ! is_numlist "$2"; then
				logger -t 5gmodem "bands: invalid band list for $1 - rejected"
				echo "bad bands"; exit 2
			fi
			if [ "$2" != "default" ] && command -v getsupportedbands >/dev/null 2>&1; then
				case "$1" in
					setbands)      _bsup=$(getsupportedbands 2>/dev/null) ;;
					setbands5gnsa) _bsup=$(getsupportedbands5gnsa 2>/dev/null) ;;
					setbands5gsa)  _bsup=$(getsupportedbands5gsa 2>/dev/null) ;;
					setbands3g)    _bsup=$(getsupportedbands3g 2>/dev/null) ;;
					setbands2g)    _bsup=$(getsupportedbands2g 2>/dev/null) ;;
				esac
				case "$_bsup" in
					''|Unsupported*) : ;;
					*)
						for _bwant in $2; do
							_bok=0
							for _bhave in $_bsup; do
								[ "${_bhave%%:*}" = "$_bwant" ] && { _bok=1; break; }
							done
							if [ "$_bok" != 1 ]; then
								logger -t 5gmodem "bands: band $_bwant is not supported by the modem ($1)"
								echo "band $_bwant not supported"; exit 2
							fi
						done ;;
				esac
			fi ;;
		set5gmode)
			if [ "$2" != "full" ]; then
				logger -t 5gmodem "bands: invalid 5G mode for $1 - rejected"
				echo "bad mode"; exit 2
			fi ;;
		setmode|setmodelive)
			if ! is_num "$2"; then
				logger -t 5gmodem "bands: invalid mode number for $1 - rejected"
				echo "bad mode"; exit 2
			fi ;;
		setcelllock)
			case "$2" in
				off) : ;;
				cell)  is_num "$3" && is_num "$4" || { logger -t 5gmodem "bands: invalid cell lock arguments - rejected"; echo "bad cell"; exit 2; } ;;
				arfcn) is_num "$3" || { logger -t 5gmodem "bands: invalid arfcn - rejected"; echo "bad arfcn"; exit 2; } ;;
				*) logger -t 5gmodem "bands: unknown cell lock mode - rejected"; echo "bad lock"; exit 2 ;;
			esac ;;
	esac
fi

if [ "$1" = "setall" ]; then
	_sa_check() {
		case "$3" in ''|Unsupported*) return 0 ;; esac
		for _bwant in $2; do
			_bok=0
			for _bhave in $3; do
				[ "${_bhave%%:*}" = "$_bwant" ] && { _bok=1; break; }
			done
			if [ "$_bok" != 1 ]; then
				logger -t 5gmodem "bands: band $_bwant is not supported by the modem (setall $1)"
				_sa_fail_add "$1" badband "$_bwant"
				return 1
			fi
		done
		return 0
	}
	case "$_SA_LTE" in ''|default) : ;; *) _sa_check lte "$_SA_LTE" "$(getsupportedbands 2>/dev/null)" || _SA_LTE="" ;; esac
	case "$_SA_NSA" in ''|default) : ;; *) _sa_check nsa "$_SA_NSA" "$(getsupportedbands5gnsa 2>/dev/null)" || _SA_NSA="" ;; esac
	case "$_SA_SA" in ''|default) : ;; *) _sa_check sa "$_SA_SA" "$(getsupportedbands5gsa 2>/dev/null)" || _SA_SA="" ;; esac
	case "$_SA_3G" in ''|default) : ;; *) _sa_check 3g "$_SA_3G" "$(getsupportedbands3g 2>/dev/null)" || _SA_3G="" ;; esac
	case "$_SA_2G" in ''|default) : ;; *) _sa_check 2g "$_SA_2G" "$(getsupportedbands2g 2>/dev/null)" || _SA_2G="" ;; esac
	if [ -z "$_SA_MODE$_SA_LTE$_SA_NSA$_SA_SA$_SA_3G$_SA_2G" ]; then
		_sa_res_write running
		_sa_res_write done
		cat "$(_sa_resfile)" 2>/dev/null
		exit 2
	fi
fi

case $1 in
	"getinfo")
		getinfo
		;;
	"getsupportedbands")
		getsupportedbands
		;;
	"getsupportedbandsext")
		getsupportedbandsext
		;;
	"getbands")
		getbands
		;;
	"getbandsext")
		getbandsext
		;;
	"setbands")
		[ -n "$2" ] && { _persist_bands "" "$2"; _bands_set_bg band setbands "$2"; }
		;;
	"setall")
		_sa_norm() { echo "$1" | sed 's/:[^ ,]*//g' | tr ' ,' '\n\n' | grep -E '^[0-9]+$' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//'; }
		_sa_same() {
			case "$1" in
				mode) _ss_want="$2"; _ss_have=$(getmode 2>/dev/null | head -1 | tr -d ' \r') ;;
				lte)  _ss_g=getbands; _ss_s=getsupportedbands ;;
				nsa)  _ss_g=getbands5gnsa; _ss_s=getsupportedbands5gnsa ;;
				sa)   _ss_g=getbands5gsa; _ss_s=getsupportedbands5gsa ;;
				3g)   _ss_g=getbands3g; _ss_s=getsupportedbands3g ;;
				2g)   _ss_g=getbands2g; _ss_s=getsupportedbands2g ;;
			esac
			if [ "$1" != "mode" ]; then
				if [ "$2" = "default" ]; then _ss_want=$(_sa_norm "$("$_ss_s" 2>/dev/null)"); else _ss_want=$(_sa_norm "$2"); fi
				_ss_have=$(_sa_norm "$("$_ss_g" 2>/dev/null)")
			fi
			[ -n "$_ss_have" ] && [ "$_ss_have" = "$_ss_want" ]
		}
		_sa_one() {
			_so_out=$("$2" "$3" 2>&1)
			_so_rc=$?
			case "$_so_out" in
				*Unsupported*) _sa_fail_add "$1" unsupported ""; return 1 ;;
			esac
			if [ "$_so_rc" != 0 ] && _sa_same "$1" "$3"; then
				_SA_OKJ="${_SA_OKJ}${_SA_OKJ:+,}\"$1\""
				return 1
			fi
			if [ "$_so_rc" != 0 ]; then
				_so_d=$(printf '%s' "$_so_out" | tr -d '\r' | grep -v '^$' | tail -1 | tr -cd 'A-Za-z0-9 .,:_()/+-' | cut -c1-120)
				logger -t 5gmodem "bands: setall $1 was not applied (rc=$_so_rc) $_so_d"
				_sa_fail_add "$1" rejected "$_so_d"
				return 1
			fi
			_SA_OKJ="${_SA_OKJ}${_SA_OKJ:+,}\"$1\""
			return 0
		}
		_sa_apply() {
			_SA_RAN=1
			_sa_any=1
			if [ -n "$_SA_MODE" ] && _sa_one mode setmode "$_SA_MODE"; then
				_persist_mode "$_SA_MODE"
				_sa_any=0
			fi
			[ -z "$_SA_LTE" ] || { _sa_one lte setbands "$_SA_LTE" && _sa_any=0; }
			[ -z "$_SA_NSA" ] || { _sa_one nsa setbands5gnsa "$_SA_NSA" && _sa_any=0; }
			[ -z "$_SA_SA" ] || { _sa_one sa setbands5gsa "$_SA_SA" && _sa_any=0; }
			[ -z "$_SA_3G" ] || { _sa_one 3g setbands3g "$_SA_3G" && _sa_any=0; }
			[ -z "$_SA_2G" ] || { _sa_one 2g setbands2g "$_SA_2G" && _sa_any=0; }
			_sa_res_write settling
			return "$_sa_any"
		}
		_sa_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
		if [ "$_sa_sec" != "m_" ] && [ -n "$_SA_LTE$_SA_NSA$_SA_SA" ]; then
			for _sa_p in ":$_SA_LTE" "5gnsa:$_SA_NSA" "5gsa:$_SA_SA"; do
				_sa_pk="${_sa_p%%:*}"; _sa_pv="${_sa_p#*:}"
				case "$_sa_pv" in
					'') : ;;
					default) uci -q delete "5gmodem.$_sa_sec.save_band$_sa_pk" 2>/dev/null ;;
					*) uci -q set "5gmodem.$_sa_sec.save_band$_sa_pk=$_sa_pv" ;;
				esac
			done
			uci -q commit 5gmodem
			_sa_if=$(uci -q get "5gmodem.$_sa_sec.network")
			[ -n "$_sa_if" ] && : > "/tmp/5gmodem/bandrestore_$_sa_if" 2>/dev/null
		fi
		_needs_mm_takeover && _SA_TAKEOVER=1
		_sa_res_write running
		( _SA_RAN=""
		  _band_write _sa_apply "mode=$_SA_MODE lte=$_SA_LTE nsa=$_SA_NSA sa=$_SA_SA 3g=$_SA_3G 2g=$_SA_2G"
		  if [ -z "$_SA_RAN" ]; then
			for _sa_w in "mode:$_SA_MODE" "lte:$_SA_LTE" "nsa:$_SA_NSA" "sa:$_SA_SA" "3g:$_SA_3G" "2g:$_SA_2G"; do
				[ -n "${_sa_w#*:}" ] && _sa_fail_add "${_sa_w%%:*}" mmtimeout ""
			done
		  fi
		  _bands_flush
		  _sa_res_write done
		) >/dev/null 2>&1 </dev/null &
		cat "$(_sa_resfile)" 2>/dev/null
		sleep 1
		;;
	"getsupportedbands5gnsa")
		getsupportedbands5gnsa
		;;
	"getsupportedbandsext5gnsa")
		getsupportedbandsext5gnsa
		;;
	"getbands5gnsa")
		getbands5gnsa
		;;
	"getbandsext5gnsa")
		getbandsext5gnsa
		;;
	"setbands5gnsa")
		[ -n "$2" ] && { _persist_bands 5gnsa "$2"; _bands_set_bg band setbands5gnsa "$2"; }
		;;
	"getsupportedbands5gsa")
		getsupportedbands5gsa
		;;
	"getsupportedbandsext5gsa")
		getsupportedbandsext5gsa
		;;
	"getbands5gsa")
		getbands5gsa
		;;
	"getbandsext5gsa")
		getbandsext5gsa
		;;
	"setbands5gsa")
		[ -n "$2" ] && { _persist_bands 5gsa "$2"; _bands_set_bg band setbands5gsa "$2"; }
		;;
	"mgmtinfo")
		_mi_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
		_mi_if=$(uci -q get "5gmodem.$_mi_sec.network")
		_mi_proto=$(uci -q get "network.$_mi_if.proto")
		if [ "$_mi_proto" != "modemmanager" ] || ! command -v mmcli >/dev/null 2>&1; then
			echo '{"source":"vendor"}'
			exit 0
		fi
		_mi_idx=$(/usr/share/5gmodem/modemswitch.sh mmindex "$(active_modem)" 2>/dev/null)
		_mi_k=""
		[ -n "$_mi_idx" ] && _mi_k=$(mmcli -m "$_mi_idx" -K 2>/dev/null)
		if [ -z "$_mi_k" ]; then
			echo '{"source":"mmcli","pending":1}'
			exit 0
		fi
		if ! printf '%s' "$_mi_k" | grep -q "supported-bands\.value"; then
			echo '{"source":"vendor"}'
			exit 0
		fi
		_mi_sup=$(printf '%s\n' "$_mi_k" | sed -n 's/^modem\.generic\.supported-bands\.value\[[0-9]*\][[:space:]]*:[[:space:]]*//p' | sort -u)
		_mi_cur=$(printf '%s\n' "$_mi_k" | sed -n 's/^modem\.generic\.current-bands\.value\[[0-9]*\][[:space:]]*:[[:space:]]*//p' | sort -u)
		_mi_arr() {
			printf '%s\n' "$1" | grep "^$2" | sed "s/^$2//" | sort -n | sed "s/^/$2/" \
				| sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//'
		}
		_mi_modes=$(printf '%s\n' "$_mi_k" \
			| sed -n 's/^modem\.generic\.supported-modes\.value\[[0-9]*\][[:space:]]*:[[:space:]]*allowed: \([^;]*\); preferred: \(.*\)$/\1:\2/p' \
			| sed 's/, /|/g; s/.*/"&"/' | tr '\n' ',' | sed 's/,$//')
		printf '{"source":"mmcli","allowedmode":"%s","preferredmode":"%s","modes":[%s],"sup3g":[%s],"cur3g":[%s],"sup4g":[%s],"cur4g":[%s],"sup5g":[%s],"cur5g":[%s],"other":[%s]}\n' \
			"$(uci -q get "network.$_mi_if.allowedmode")" \
			"$(uci -q get "network.$_mi_if.preferredmode")" \
			"$_mi_modes" \
			"$(_mi_arr "$_mi_sup" utran-)"  "$(_mi_arr "$_mi_cur" utran-)" \
			"$(_mi_arr "$_mi_sup" eutran-)" "$(_mi_arr "$_mi_cur" eutran-)" \
			"$(_mi_arr "$_mi_sup" ngran-)"  "$(_mi_arr "$_mi_cur" ngran-)" \
			"$(printf '%s\n' "$_mi_cur" | grep -v '^$' | grep -vE '^(utran-|eutran-|ngran-)' | sed 's/.*/"&"/' | tr '\n' ',' | sed 's/,$//')"
		;;
	"setmodemm")
		_smm_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
		_smm_if=$(uci -q get "5gmodem.$_smm_sec.network")
		logger -t 5gmodem "setmodemm: allowed='$2' preferred='$3' iface='$_smm_if'"
		[ -n "$_smm_if" ] || { echo '{"error":"no iface"}'; exit 0; }
		note_foreign_uci network "bands setmodemm"
		if [ -z "$2" ] || [ "$2" = "default" ]; then
			uci -q delete "network.$_smm_if.allowedmode"
			uci -q delete "network.$_smm_if.preferredmode"
		else
			uci -q set "network.$_smm_if.allowedmode=$2"
			_smm_pref="$3"
			case "$2" in
				*"|"*)
					_smm_idx=$(/usr/share/5gmodem/modemswitch.sh mmindex "$(active_modem)" 2>/dev/null)
					_smm_sup=""
					[ -n "$_smm_idx" ] && _smm_sup=$(mmcli -m "$_smm_idx" -K 2>/dev/null \
						| sed -n 's/^modem\.generic\.supported-modes\.value\[[0-9]*\][[:space:]]*:[[:space:]]*//p')
					if [ -n "$_smm_pref" ] && [ -n "$_smm_sup" ] \
					   && ! printf '%s\n' "$_smm_sup" | grep -qxF "allowed: $(echo "$2" | sed 's/|/, /g'); preferred: $_smm_pref"; then
						logger -t 5gmodem "setmodemm: the modem does not support preferred '$_smm_pref' with '$2' - using none"
						_smm_pref=""
					fi
					[ -n "$_smm_pref" ] || _smm_pref="none"
					;;
			esac
			if [ -n "$_smm_pref" ]; then
				uci -q set "network.$_smm_if.preferredmode=$_smm_pref"
			else
				uci -q delete "network.$_smm_if.preferredmode"
			fi
		fi
		uci -q commit network
		# reload, not down/up: see docs/subsystems/bands.md#modemmanager-network-mode
		( ubus call network reload ) >/dev/null 2>&1 </dev/null &
		echo '{"result":"ok"}'
		;;
	"restorebands")
		_rb_sec="m_$(active_modem | sed 's/[^A-Za-z0-9]/_/g')"
		_rb_changed=0
		_rb_norm() { echo "$1" | tr ' ,' '\n\n' | grep -E '^[0-9]+$' | sort -n | uniq | tr '\n' ' ' | sed 's/ *$//'; }
		_rb_one() {
			_rb_saved=$(uci -q get "5gmodem.$_rb_sec.save_band$1")
			_rb_savedn=$(_rb_norm "$_rb_saved")
			[ -n "$_rb_savedn" ] || return 0
			_rb_curn=$(_rb_norm "$("$2" 2>/dev/null)")
			[ -n "$_rb_curn" ] || return 0
			[ "$_rb_savedn" = "$_rb_curn" ] && return 0
			"$3" "$_rb_saved" && _rb_changed=1
		}
		if [ "$2" = "prepare" ]; then
			_pw=0
			while [ "$_pw" -lt 15 ]; do
				[ -n "$(_rb_norm "$(getbands 2>/dev/null)")" ] && break
				sleep 2; _pw=$((_pw + 1))
			done
		fi
		_rb_one ""     getbands       setbands
		_rb_one 5gnsa  getbands5gnsa  setbands5gnsa
		_rb_one 5gsa   getbands5gsa   setbands5gsa
		_rb_msaved=$(uci -q get "5gmodem.$_rb_sec.save_mode")
		if [ -n "$_rb_msaved" ]; then
			_rb_mcur=$(getmode 2>/dev/null | head -1 | tr -d ' \r')
			if [ -n "$_rb_mcur" ] && [ "$_rb_mcur" != "$_rb_msaved" ]; then
				setmode "$_rb_msaved" >/dev/null 2>&1 && _rb_changed=1
			fi
		fi
		if [ "$2" = "prepare" ]; then
			if [ "$_rb_changed" = 1 ]; then
				logger -t 5gmodem "restorebands(prepare): mask written before dialing for $(active_modem)"
				exit 0
			fi
			exit 3
		fi
		if [ "$_rb_changed" = 1 ]; then
			logger -t 5gmodem "restorebands: saved bands restored for $(active_modem)"
			if ! _bands_live && [ -n "$_DEVICE" ]; then
				sms_tool -d "$_DEVICE" at "AT+CFUN=4" >/dev/null 2>&1
				sleep 3
				_cf_n=0
				while [ "$_cf_n" -lt 3 ]; do
					_cf_n=$((_cf_n + 1))
					sms_tool -d "$_DEVICE" at "AT+CFUN=1" >/dev/null 2>&1
					sleep 2
					case "$(sms_tool -d "$_DEVICE" at "AT+CFUN?" 2>/dev/null)" in *"+CFUN: 1"*) break ;; esac
				done
			fi
			_reconnect_iface
		fi
		;;
	"getsupportedmodes")
		getsupportedmodes
		;;
	"getmode")
		getmode
		;;
	"setmode")
		[ -n "$2" ] && _bands_set_bg mode setmode "$2"
		;;
	"setmodelive")
		[ -n "$2" ] || { echo "no mode"; exit 2; }
		setmode "$2" >/dev/null 2>&1
		_bands_flush
		_smv=0
		while [ "$_smv" -lt 3 ]; do
			[ "$(getmode 2>/dev/null)" = "$2" ] && { echo "ok"; exit 0; }
			_smv=$((_smv + 1)); sleep 1
		done
		echo "fail"; exit 1
		;;
	"getsupportedbands3g")
		getsupportedbands3g
		;;
	"getbands3g")
		getbands3g
		;;
	"setbands3g")
		[ -n "$2" ] && _bands_set_bg after setbands3g "$2"
		;;
	"getsupportedbands2g")
		getsupportedbands2g
		;;
	"getbands2g")
		getbands2g
		;;
	"setbands2g")
		[ -n "$2" ] && _bands_set_bg after setbands2g "$2"
		;;
	"getcelllock")
		_celllock_effective
		;;
	"get5gmode")
		get5gmode
		;;
	"getcaenabled")
		getcaenabled
		;;
	"setcaenabled")
		case "$2" in
			0|1) _bands_set_bg plain setcaenabled "$2" ;;
		esac
		;;
	"get256qam")
		get256qam
		;;
	"set256qam")
		case "$2" in
			0|1) _bands_set_bg after set256qam "$2" ;;
		esac
		;;
	"getulca")
		getulca
		;;
	"setulca")
		case "$2" in
			on) _bands_set_bg after setulca on ;;
		esac
		;;
	"getcelllock5g")
		getcelllock5g
		;;
	"setcelllock5g")
		if [ -n "$2" ]; then
			( _cl5_out=$(setcelllock5g "$2" "$3" "$4" 2>/dev/null)
			  case "$_cl5_out" in
				*Unsupported*)
					logger -t 5gmodem "celllock5g: this modem profile cannot write a 5G cell lock - nothing was sent"
					exit 0 ;;
			  esac
			  _bands_flush
			  _reconnect_iface
			  _bands_flush
			) >/dev/null 2>&1 </dev/null &
		fi
		;;
	"set5gmode")
		[ -n "$2" ] && _bands_set_bg reconnect set5gmode "$2"
		;;
	"setcelllock")
		if [ -n "$2" ]; then
			_cl_sec=$(active_modem | sed 's/[^A-Za-z0-9]/_/g')
			if [ -n "$_cl_sec" ]; then
				_cl_sec="m_$_cl_sec"
				case "$2" in
					off) uci -q delete "5gmodem.$_cl_sec.celllock" 2>/dev/null ;;
					*)   uci -q set "5gmodem.$_cl_sec.celllock=$2 $3 $4" ;;
				esac
				uci -q commit 5gmodem
			fi
			( _cl_out=$(setcelllock "$2" "$3" "$4" 2>/dev/null)
			  _bands_flush
			  case "$_cl_out" in
				*Unsupported*)
					[ -n "$_cl_sec" ] && { uci -q delete "5gmodem.$_cl_sec.celllock"; uci -q commit 5gmodem; }
					logger -t 5gmodem "celllock: this modem profile cannot write a cell lock - the choice was not remembered"
					exit 0 ;;
			  esac
			  _reconnect_iface
			  _cl_at=$(uci -q get "5gmodem.$_cl_sec.at_port")
			  [ -n "$_cl_at" ] || _cl_at=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
			  if [ -n "$_cl_at" ] && [ -e "$_cl_at" ]; then
				_cl_ok=0
				for _cl_i in 1 2 3 4 5 6; do
					sleep 5
					sms_tool -d "$_cl_at" at "AT" 2>/dev/null | grep -qi "OK" && { _cl_ok=1; break; }
				done
				[ "$_cl_ok" = 0 ] && logger -t 5gmodem "cell-lock: modem stopped answering AT after locking - power-cycle it from Frequency management if it does not recover"
			  fi
			  _bands_flush
			) >/dev/null 2>&1 </dev/null &
		fi
		;;
	"getantports")
		getantports
		;;
	"json")
		. /usr/share/libubox/jshn.sh
		json_init
		if [ "$_PORT_OK" = "1" ]; then
			json_add_string modem "$(getinfo)"
		else
			json_add_string modem "$(uci -q get "5gmodem.$_bs_sec.model")"
			[ -n "$_MM_AT_STATIC$_NOAT_STATIC" ] || json_add_int nolive 1
		fi
		if [ "$_BAND_READONLY" = "1" ]; then
			if _needs_mm_takeover; then json_add_int takeover 1; else json_add_int readonly 1; fi
		fi
		[ -n "$_MM_AT_STATIC" ] && json_add_int mm_at_static 1
		[ -n "$_NOAT_STATIC" ] && json_add_int noat_static 1
		MODES=$(getsupportedmodes)
		if [ "x$MODES" != "xUnsupported" ]; then
			[ "$_PORT_OK" = "1" ] && json_add_string currentmode "$(getmode)"
			json_add_array modes
			for PAIR in $MODES; do
				json_add_object ""
				json_add_string id "${PAIR%%:*}"
				json_add_string label "${PAIR#*:}"
				json_close_object
			done
			json_close_array
		fi
		if [ "$_PORT_OK" = "1" ]; then CL=$(_celllock_effective); else CL=$(_celllock_remembered); fi
		if [ "x$CL" != "xUnsupported" ]; then
			json_add_string celllock "$CL"
		fi
		G5=$(_live_or_unsupported get5gmode)
		if [ "x$G5" != "xUnsupported" ]; then
			json_add_string mode5g "$G5"
		fi
		CAE=$(_live_or_unsupported getcaenabled)
		if [ "x$CAE" != "xUnsupported" ]; then
			json_add_string ca_enabled "$CAE"
			[ "$_CA_SWITCH" = 1 ] && json_add_string ca_switch 1
		fi
		CL5=$(_live_or_unsupported getcelllock5g)
		if [ "x$CL5" != "xUnsupported" ]; then
			json_add_string celllock5g "$CL5"
		fi
		Q256=$(_live_or_unsupported get256qam)
		if [ "x$Q256" != "xUnsupported" ]; then
			json_add_string qam256 "$Q256"
		fi
		ULCA=$(_live_or_unsupported getulca)
		if [ "x$ULCA" != "xUnsupported" ]; then
			json_add_string ulca "$ULCA"
		fi
		json_add_array supported
		T=$(getsupportedbands)
		if [ "x$T" != "xUnsupported" ]; then
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
		fi
		json_close_array
		json_add_array enabled
		T=$([ "$_PORT_OK" = "1" ] && getbands)
		if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
			for BAND in $T; do
				json_add_int "" $BAND
			done
		fi
		json_close_array

		T3=$(getsupportedbands3g)
		if [ -n "$T3" ] && [ "x$T3" != "xUnsupported" ]; then
			if [ "$(bands3g_style)" = "mask" ]; then
				json_add_array supported3g
				for BAND in $T3; do
					case "$BAND" in ''|*[!0-9]*) continue ;; esac
					json_add_object ""
					json_add_int band "$BAND"
					json_close_object
				done
				json_close_array
				json_add_array enabled3g
				if [ "$_PORT_OK" = "1" ]; then
					for BAND in $(getbands3g); do
						case "$BAND" in ''|*[!0-9]*) continue ;; esac
						json_add_int "" "$BAND"
					done
				fi
				json_close_array
			else
				json_add_array combos3g
				_OIFS="$IFS"; IFS='
'
				for LINE in $T3; do
					[ -n "$LINE" ] || continue
					json_add_object ""
					json_add_string id "${LINE%%:*}"
					json_add_string label "${LINE#*:}"
					json_close_object
				done
				IFS="$_OIFS"
				json_close_array
				[ "$_PORT_OK" = "1" ] && json_add_string current3g "$(getbands3g)"
			fi
		fi

		T2=$(getsupportedbands2g)
		if [ -n "$T2" ] && [ "x$T2" != "xUnsupported" ]; then
			json_add_array supported2g
			for BAND in $T2; do
				case "$BAND" in ''|*[!0-9]*) continue ;; esac
				json_add_object ""
				json_add_int band "$BAND"
				json_close_object
			done
			json_close_array
			json_add_array enabled2g
			if [ "$_PORT_OK" = "1" ]; then
				for BAND in $(getbands2g); do
					case "$BAND" in ''|*[!0-9]*) continue ;; esac
					json_add_int "" "$BAND"
				done
			fi
			json_close_array
		fi

		T=$(getsupportedbands5gnsa)
		if [ "x$T" != "xUnsupported" ]; then
			json_add_array supported5gnsa
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt5g $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
			json_close_array
			json_add_array enabled5gnsa
			T=$([ "$_PORT_OK" = "1" ] && getbands5gnsa)
			if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
				for BAND in $T; do
					json_add_int "" $BAND
				done
			fi
			json_close_array
		fi
		T=$(getsupportedbands5gsa)
		if [ "x$T" != "xUnsupported" ]; then
			json_add_array supported5gsa
			for BAND in $T; do
				json_add_object ""
				json_add_int band $BAND
				TXT="$(bandtxt5g $BAND)"
				json_add_string txt "${TXT##*: }"
				json_close_object
			done
			json_close_array
			json_add_array enabled5gsa
			T=$([ "$_PORT_OK" = "1" ] && getbands5gsa)
			if [ -n "$T" ] && [ "x$T" != "xUnsupported" ]; then
				for BAND in $T; do
					json_add_int "" $BAND
				done
			fi
			json_close_array
		fi
		[ -n "$_BAND_RECONNECT_WARN" ] && json_add_boolean bandwarn 1
		[ -n "$_BAND_MODES_ONLY" ] && json_add_int nobandctl 1
		json_dump
		;;
	"help")
		echo "Available commands:"
		echo " $0 getinfo"
		echo " $0 json"
		echo " $0 help"
		echo ""
		echo "for LTE modem"
		echo " $0 getsupportedbands"
		echo " $0 getsupportedbandsext"
		echo " $0 getbands"
		echo " $0 getbandsext"
		echo " $0 setbands \"<band list>\""
		echo ""
		echo "for 5G NSA modem"
		echo " $0 getsupportedbands5gnsa"
		echo " $0 getsupportedbandsext5gnsa"
		echo " $0 getbands5gnsa"
		echo " $0 getbandsext5gnsa"
		echo " $0 setbands5gnsa \"<band list>\""
		echo ""
		echo "for 5G SA modem"
		echo " $0 getsupportedbands5gsa"
		echo " $0 getsupportedbandsext5gsa"
		echo " $0 getbands5gsa"
		echo " $0 getbandsext5gsa"
		echo " $0 setbands5gsa \"<band list>\""
		echo ""
		echo "several lists and the mode in one pass (one radio restart / one MM takeover)"
		echo " $0 setall [mode=<id>] [lte=\"<band list>\"|default] [nsa=...] [sa=...] [3g=...] [2g=...]"
		echo " $0 applyresult [<usb path>]"
		;;
	*)
		echo -n "Modem: "
		getinfo
		echo -n "Supported LTE bands: "
		getsupportedbands
		echo -n "Enabled LTE bands: "
		getbands
		echo ""
		getsupportedbandsext
		T=$(getsupportedbands5gnsa)
		if [ "x$T" != "xUnsupported" ]; then
			echo -n "Supported 5G NSA bands: "
			getsupportedbands5gnsa
			echo -n "Enabled 5G NSA bands: "
			getbands5gnsa
			echo ""
			getsupportedbandsext5gnsa
		fi
		T=$(getsupportedbands5gsa)
		if [ "x$T" != "xUnsupported" ]; then
			echo -n "Supported 5G SA bands: "
			getsupportedbands5gsa
			echo -n "Enabled 5G SA bands: "
			getbands5gsa
			echo ""
			getsupportedbandsext5gsa
		fi
		;;
esac

exit 0
