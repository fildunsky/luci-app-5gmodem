#!/bin/sh

#
# (c) 2010-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2021-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#

band3g() {
	case "${1}" in
		wcdma-2100)        echo "B1 (2100 MHz)";;
		wcdma-pcs-1900)    echo "B2 (1900 MHz)";;
		wcdma-dcs-1800)    echo "B3 (1800 MHz)";;
		wcdma-1700-us)     echo "B4 (1700 MHz)";;
		wcdma-850)         echo "B5 (850 MHz)";;
		wcdma-800)         echo "B6 (800 MHz)";;
		wcdma-2600)        echo "B7 (2600 MHz)";;
		wcdma-900)         echo "B8 (900 MHz)";;
		wcdma-1700-japan)  echo "B9 (1700 MHz)";;
		wcdma-1500-japan)  echo "B11 (1500 MHz)";;
		wcdma-850-japan)   echo "B19 (850 MHz)";;
		[0-9]*)
			case "${1}" in
				1056[2-9]|10[6-7][0-9][0-9]|108[0-3][0-9]) echo "B1 (2100 MHz)";;
				96[6-9][0-9]|99[0-3][0-9])                 echo "B2 (1900 MHz)";;
				116[2-9]|1[2-4][0-9][0-9]|150[0-9]|151[0-3]) echo "B3 (1800 MHz)";;
				15[4-9][0-9]|16[0-9][0-9]|17[0-3][0-9])    echo "B4 (1700 MHz)";;
				43[5-9][0-9]|44[0-5][0-9])                 echo "B5 (850 MHz)";;
				22[4-9][0-9]|2[3-4][0-9][0-9]|25[0-5][0-9]|256[0-3]) echo "B7 (2600 MHz)";;
				29[4-9][0-9]|30[0-8][0-9])                 echo "B8 (900 MHz)";;
			esac;;
	esac
}

earfcn2band() {
	case "$1" in ''|*[!0-9]*) return ;; esac
	if   [ "$1" -le 599 ];                          then echo 1
	elif [ "$1" -ge 600 ]   && [ "$1" -le 1199 ];   then echo 2
	elif [ "$1" -ge 1200 ]  && [ "$1" -le 1949 ];   then echo 3
	elif [ "$1" -ge 1950 ]  && [ "$1" -le 2399 ];   then echo 4
	elif [ "$1" -ge 2400 ]  && [ "$1" -le 2649 ];   then echo 5
	elif [ "$1" -ge 2750 ]  && [ "$1" -le 3449 ];   then echo 7
	elif [ "$1" -ge 3450 ]  && [ "$1" -le 3799 ];   then echo 8
	elif [ "$1" -ge 5010 ]  && [ "$1" -le 5179 ];   then echo 12
	elif [ "$1" -ge 5180 ]  && [ "$1" -le 5279 ];   then echo 13
	elif [ "$1" -ge 5280 ]  && [ "$1" -le 5379 ];   then echo 14
	elif [ "$1" -ge 5730 ]  && [ "$1" -le 5849 ];   then echo 17
	elif [ "$1" -ge 5850 ]  && [ "$1" -le 5999 ];   then echo 18
	elif [ "$1" -ge 6000 ]  && [ "$1" -le 6149 ];   then echo 19
	elif [ "$1" -ge 6150 ]  && [ "$1" -le 6449 ];   then echo 20
	elif [ "$1" -ge 8040 ]  && [ "$1" -le 8689 ];   then echo 25
	elif [ "$1" -ge 8690 ]  && [ "$1" -le 9039 ];   then echo 26
	elif [ "$1" -ge 9210 ]  && [ "$1" -le 9659 ];   then echo 28
	elif [ "$1" -ge 9660 ]  && [ "$1" -le 9769 ];   then echo 29
	elif [ "$1" -ge 9770 ]  && [ "$1" -le 9869 ];   then echo 30
	elif [ "$1" -ge 9870 ]  && [ "$1" -le 9919 ];   then echo 31
	elif [ "$1" -ge 9920 ]  && [ "$1" -le 10359 ];  then echo 32
	elif [ "$1" -ge 36200 ] && [ "$1" -le 36349 ];  then echo 34
	elif [ "$1" -ge 37750 ] && [ "$1" -le 38249 ];  then echo 38
	elif [ "$1" -ge 38250 ] && [ "$1" -le 38649 ];  then echo 39
	elif [ "$1" -ge 38650 ] && [ "$1" -le 39649 ];  then echo 40
	elif [ "$1" -ge 39650 ] && [ "$1" -le 41589 ];  then echo 41
	elif [ "$1" -ge 41590 ] && [ "$1" -le 43589 ];  then echo 42
	elif [ "$1" -ge 43590 ] && [ "$1" -le 45589 ];  then echo 43
	elif [ "$1" -ge 46790 ] && [ "$1" -le 54539 ];  then echo 46
	elif [ "$1" -ge 55240 ] && [ "$1" -le 56739 ];  then echo 48
	elif [ "$1" -ge 66436 ] && [ "$1" -le 67335 ];  then echo 66
	elif [ "$1" -ge 68586 ] && [ "$1" -le 68935 ];  then echo 71
	fi
}

band4g() {
	[ -n "$1" ] || return 0
	echo -n "B${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"4") echo " (1700 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"11") echo " (1500 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"17") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"19") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"21") echo " (1500 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"31") echo " (450 MHz)";;
		"32") echo " (1500 MHz)";;
		"34") echo " (2000 MHz)";;
		"37") echo " (1900 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"42") echo " (3500 MHz)";;
		"43") echo " (3700 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700 MHz)";;
		"67") echo " (700 MHz)";;
		"69") echo " (2600 MHz)";;
		"70") echo " (1700 MHz)";;
		"71") echo " (600 MHz)";;
		"72") echo " (450 MHz)";;
		"73") echo " (450 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"85") echo " (700 MHz)";;
		"87") echo " (410 MHz)";;
		"88") echo " (410 MHz)";;
		"103") echo " (700 MHz)";;
		"106") echo " (900 MHz)";;
		*) echo "";;
	esac
}

band5g() {
	[ -n "$1" ] || return 0
	echo -n "n${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"34") echo " (2100 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700/2100 MHz)";;
		"67") echo " (700 MHz)";;
		"70") echo " (2000 MHz)";;
		"71") echo " (600 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"77") echo " (3700 MHz)";;
		"78") echo " (3500 MHz)";;
		"79") echo " (4700 MHz)";;
		"80") echo " (1800 MHz)";;
		"81") echo " (900 MHz)";;
		"82") echo " (800 MHz)";;
		"83") echo " (700 MHz)";;
		"84") echo " (2100 MHz)";;
		"85") echo " (700 MHz)";;
		"86") echo " (1700 MHz)";;
		"89") echo " (850 MHz)";;
		"90") echo " (2500 MHz)";;
		"91") echo " (800/1500 MHz)";;
		"92") echo " (800/1500 MHz)";;
		"93") echo " (900/1500 MHz)";;
		"94") echo " (900/1500 MHz)";;
		"95") echo " (2100 MHz)";;
		"96") echo " (6000 MHz)";;
		"97") echo " (2300 MHz)";;
		"98") echo " (1900 MHz)";;
		"99") echo " (1600 MHz)";;
		"100") echo " (900 MHz)";;
		"101") echo " (1900 MHz)";;
		"102") echo " (6200 MHz)";;
		"104") echo " (6700 MHz)";;
		"105") echo " (600 MHz)";;
		"106") echo " (900 MHz)";;
		"109") echo " (700/1500 MHz)";;
		"257") echo " (28 GHz)";;
		"258") echo " (26 GHz)";;
		"259") echo " (41 GHz)";;
		"260") echo " (39 GHz)";;
		"261") echo " (28 GHz)";;
		"262") echo " (47 GHz)";;
		"263") echo " (60 GHz)";;
		*) echo "";;
	esac
}

getdevicevendorproduct() {
	devname="$(basename $1)"
	case "$devname" in
		'wwan'*'at'*)
			devpath="$(readlink -f /sys/class/wwan/$devname/device)"
			T=${devpath%/*/*/*}
			if [ -d "${devpath%/wwan/*}/remoteproc" ]; then
				echo "soc/$(soc_modem_vidpid | tr -d :)"
			elif [ -e $T/vendor ] && [ -e $T/device ]; then
				V=$(cat $T/vendor)
				D=$(cat $T/device)
				S=$(cat $T/subsystem_vendor 2>/dev/null)
				S=${S#0x}
				if [ -n "$S" ] && [ -e "$RES/modem/pci/${V/0x/}${D/0x/}_$S" ]; then
					echo "pci/${V/0x/}${D/0x/}_$S"
				else
					echo "pci/${V/0x/}${D/0x/}"
				fi
			fi
			;;
		'ttyACM'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		'tty'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		*)
			devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
	esac
}

RES="/usr/share/5gmodem"

. "$RES/lib.sh"

_active_path() { uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null; }

_POLL_AM=$(_active_path)
_ACT_AM="$_POLL_AM"

case "$1" in
	cached) _pm_arg="$3" ;;
	peek)   _pm_arg="$2" ;;
	hist)   _pm_arg="$2" ;;
	*)      _pm_arg="" ;;
esac
case "$_pm_arg" in
	for=*) _pm_arg="${_pm_arg#for=}" ;;
esac
case "$_pm_arg" in
	'' ) : ;;
	*[!0-9.:_-]*) : ;;
	*) POLL_MODEM="$_pm_arg" ;;
esac

_PINNED=""
if [ -n "$POLL_MODEM" ]; then
	case "$POLL_MODEM" in
		*[!A-Za-z0-9.:_-]*) ;;
		*)
			if [ -d "/sys/bus/usb/devices/$POLL_MODEM" ] \
			   || "$RES/registry.sh" paths 2>/dev/null | grep -qx "$POLL_MODEM"; then
				_POLL_AM="$POLL_MODEM"
				_PINNED=1
			fi
			;;
	esac
fi

_MKEY=$(snap_key "$_POLL_AM")
HIST="/tmp/5gmodem/hist_$_MKEY"
CACHE="/tmp/5gmodem/metrics_$_MKEY.json"
STAMP="/tmp/5gmodem/metrics_$_MKEY.stamp"
LOCKDIR="/tmp/5gmodem/poll_$_MKEY.lock"

_cleanup_tmp() { [ -n "$_stp" ] && kill "$_stp" "$_stk" 2>/dev/null; rm -f /tmp/5gmodem/st.$$.* "$CACHE.p$$" "$CACHE.$$" 2>/dev/null; }
trap '_cleanup_tmp' EXIT
trap 'exit 143' INT TERM HUP

_active_onbus() {
	[ -n "$_POLL_AM" ] && [ -e "/sys/bus/usb/devices/$_POLL_AM" ] && echo 1 || echo 0
}

serve_cache() {
	_a="${1:-0}"
	_sc_al=$(alias_for_path "$_POLL_AM")
	[ -n "$_sc_al" ] || _sc_al="-"
	case "$_sc_al" in
		*\\*|*\"*) _sc_al=$(printf '%s' "$_sc_al" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g') ;;
	esac
	case "$_sc_al" in
		*[\&\|\\]*) _sc_al=$(printf '%s' "$_sc_al" | sed 's/[&|\\]/\\&/g') ;;
	esac
	sed -e "s/\"age\":\"[0-9]*\"/\"age\":\"$_a\"/" \
		-e "s|^\"alias\":\".*\",$|\"alias\":\"$_sc_al\",|" \
		"$CACHE" 2>/dev/null || cat "$CACHE"
}

_snapshot_age() {
	[ -s "$CACHE" ] || return 1
	IFS=' ' read -r _n _ < /proc/uptime; _n="${_n%%.*}"
	_t=""; read -r _t 2>/dev/null < "$STAMP"
	case "$_t" in ''|*[!0-9]*) return 1 ;; esac
	_a=$((_n - _t)); [ "$_a" -ge 0 ] || return 1
	printf '%s' "$_a"
}

_take_lock() {
	if mkdir "$LOCKDIR" 2>/dev/null; then return 0; fi
	_lt=$(cat "$LOCKDIR/stamp" 2>/dev/null)
	case "$_lt" in ''|*[!0-9]*) _lt="" ;; esac
	_ls=""
	if [ -n "$_lt" ]; then
		[ "$(( $(uptime_s) - _lt ))" -gt 40 ] && _ls=1
	elif [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
		_ls=1
	fi
	if [ -n "$_ls" ]; then
		rm -rf "$LOCKDIR" 2>/dev/null
		mkdir "$LOCKDIR" 2>/dev/null && return 0
	fi
	return 1
}

_hl_sec=$(secname "$_POLL_AM")
export QMI_TARGET_PATH="$_POLL_AM"
_hl_at=$(uci -q get "5gmodem.$_hl_sec.at_port")
[ -n "$_hl_at" ] && [ -c "$_hl_at" ] && _hl_at="yes" || _hl_at=""
hl_web_metrics "$_hl_sec" && _hl_at=""
_hl_kind=$(uci -q get "5gmodem.$_hl_sec.kind")

_WANT=""
for _a in "$@"; do
	case "$_a" in
		for=*) _WANT="${_a#for=}" ;;
	esac
done
if [ -n "$_WANT" ]; then
	case "$_WANT" in
		*[!A-Za-z0-9.:_-]*)
			printf '{"error":"bad path"}\n'; exit 0 ;;
	esac
	if [ "$_WANT" != "$_POLL_AM" ]; then
		printf '{"error":"not_active","path":"%s","want":"%s"}\n' "$_POLL_AM" "$_WANT"
		exit 0
	fi
fi

if [ "$1" = "hist" ]; then
	_hn=$(uptime_s)
	[ -s "$HIST" ] || { echo '[]'; exit 0; }
	awk -v now="$_hn" 'BEGIN { printf "[" }
		{ a = now - $1; if (a < 0 || a > 600) next
		  pb = ""; for (i = 8; i <= NF; i++) pb = pb (pb == "" ? "" : " ") $i
		  gsub(/["\\]/, "", pb)
		  printf "%s[%d,\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"]", (n++ ? "," : ""), a, $2, $3, $4, $5, $6, $7, pb }
		END { print "]" }' "$HIST"
	exit 0
fi

if [ "$1" = "peek" ]; then
	if [ "$_hl_kind" = "hilink" ] && [ -z "$_hl_at" ]; then
		[ -s "/tmp/5gmodem/hilink_metrics_$_MKEY" ] && cat "/tmp/5gmodem/hilink_metrics_$_MKEY" || echo '{}'
		exit 0
	fi
	_age=$(_snapshot_age) && { serve_cache "$_age"; exit 0; }
	[ -s "$CACHE" ] && { serve_cache 9999; exit 0; }
	echo '{}'
	exit 0
fi

if [ -n "$_POLL_AM" ] \
   && { is_iphone "$_POLL_AM" || { [ "$_hl_kind" = tether ] && ! known_modem_path "$_POLL_AM"; }; }; then
	if [ "$(_active_onbus)" != 1 ]; then
		printf '{"error":"Device not found","onbus":"0","path":"%s","tether":"%s","tether_state":"gone"}\n' \
			"$_POLL_AM" "$(tether_os "$_POLL_AM")"
		exit 0
	fi
	_tj_os=$(tether_os "$_POLL_AM")
	if [ "$_tj_os" = iphone ]; then
		usbmuxd_ensure >/dev/null 2>&1
		_tj_st=$(iphone_state "$_POLL_AM")
		_tj_nd=$(iphone_netdev "$_POLL_AM")
	else
		_tj_nd=""
		for _tj_n in /sys/bus/usb/devices/"$_POLL_AM":*/net/*; do
			[ -e "$_tj_n" ] && { _tj_nd="${_tj_n##*/}"; break; }
		done
		_tj_st=ready; [ -n "$_tj_nd" ] || _tj_st=no_netdev
	fi
	_tj_if=$(uci -q get "5gmodem.$_hl_sec.network")
	_tj_ip=""; _tj_gw=""
	if [ -n "$_tj_if" ]; then
		_tj_js=$(ubus call "network.interface.$_tj_if" status 2>/dev/null)
		_tj_ip=$(printf '%s' "$_tj_js" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
		[ "$_tj_os" = router ] && _tj_gw=$(printf '%s' "$_tj_js" \
			| jsonfilter -e '@.route[@.target="0.0.0.0"].nexthop' 2>/dev/null | head -1)
	fi
	_tj_nm=$(cat "/sys/bus/usb/devices/$_POLL_AM/product" 2>/dev/null | tr -d '"\\')
	if [ "$_tj_os" = router ] && [ "$_tj_st" = ready ] && [ -n "$_tj_gw" ]; then
		_rt=$(remote_tele "$_tj_gw")
		_rt_rsrp=$(printf '%s' "$_rt" | jsonfilter -e '@.rsrp' 2>/dev/null)
		_rt_op=$(printf '%s' "$_rt" | jsonfilter -e '@.oper' 2>/dev/null)
		if [ -n "$_rt_rsrp$_rt_op" ]; then
			_rt_md=$(printf '%s' "$_rt" | jsonfilter -e '@.mode' 2>/dev/null)
			_rt_bd=$(printf '%s' "$_rt" | jsonfilter -e '@.band' 2>/dev/null)
			_rt_ca=$(printf '%s' "$_rt" | jsonfilter -e '@.ca' 2>/dev/null)
			_rt_tp=$(printf '%s' "$_rt" | jsonfilter -e '@.temp' 2>/dev/null)
			_rt_ml=$(printf '%s' "$_rt" | jsonfilter -e '@.model' 2>/dev/null | tr -d '"\\')
			_rt_ph=$(printf '%s' "$_rt" | jsonfilter -e '@.phone' 2>/dev/null | tr -cd '+0-9')
			_rt_pr=dhcp
			for _rt_i in /sys/bus/usb/devices/"$_POLL_AM":*; do
				[ -f "$_rt_i/bInterfaceClass" ] || continue
				case "$(cat "$_rt_i/bInterfaceClass")/$(cat "$_rt_i/bInterfaceSubClass")/$(cat "$_rt_i/bInterfaceProtocol")" in
					02/0d/*) _rt_pr=ncm; break ;;
					02/06/*) _rt_pr=ecm; break ;;
					ef/04/01|e0/01/03) _rt_pr=rndis; break ;;
				esac
			done
			case "$_rt_md" in
				4G) _rt_md=LTE ;; 4G+) _rt_md=LTE-A ;; 3G) _rt_md=WCDMA ;; 2G) _rt_md=GSM ;;
			esac
			[ -n "$_rt_bd" ] && _rt_md="${_rt_md:+$_rt_md | }${_rt_ca:-$_rt_bd}"
			_rt_ct=$(printf '%s' "$_tj_js" | jsonfilter -e '@.uptime' 2>/dev/null)
			_rt_cts="-"; _rt_ctsn="-"; _rt_cto="-"
			case "$_rt_ct" in
				''|*[!0-9]*) ;;
				*) _rt_cto="$_rt_ct"
				   _rt_cts=$(printf "%dd, %02d:%02d:%02d" $((_rt_ct / 86400)) $((_rt_ct / 3600 % 24)) $((_rt_ct / 60 % 60)) $((_rt_ct % 60)))
				   _rt_ctsn=$(date "+%Y%m%d%H%M%S" -d "@$(($(date +%s) - _rt_ct))") ;;
			esac
			_rt_rx="-"; _rt_tx="-"
			_rt_l3=$(printf '%s' "$_tj_js" | jsonfilter -e '@.l3_device' 2>/dev/null)
			if [ -n "$_rt_l3" ]; then
				_rt_x=$(ifconfig "$_rt_l3" 2>/dev/null | awk -F[\(\)] '/bytes/ {printf "%s|%s",$2,$4}')
				[ -n "$_rt_x" ] && { _rt_rx="${_rt_x%%|*}"; _rt_tx="${_rt_x##*|}"; }
			fi
			_rt_tmp="$CACHE.r$$"
			printf '{"backend":"router","protocol":"%s","iface_proto":"%s","path":"%s","vidpid":"%s:%s","modem":"%s","operator_name":"%s","registration":"1","mode":"%s","pband":"%s","signal":"%s","rsrp":"%s","rsrq":"%s","sinr":"%s","mtemp":"%s","phone":"%s","conn_time":"%s","conn_time_sec":"%s","conn_time_since":"%s","rx":"%s","tx":"%s","iface":"%s","ipaddr":"%s","tether":"router","tether_state":"ready","gateway":"%s","netdev":"%s"}\n' \
				"$_rt_pr" "$_rt_pr" "$_POLL_AM" "$(cat "/sys/bus/usb/devices/$_POLL_AM/idVendor" 2>/dev/null)" "$(cat "/sys/bus/usb/devices/$_POLL_AM/idProduct" 2>/dev/null)" \
				"${_rt_ml:-$_tj_nm}" "$(printf '%s' "$_rt_op" | tr -d '"\\')" "$_rt_md" "${_rt_bd:--}" \
				"$(printf '%s' "$_rt" | jsonfilter -e '@.sig' 2>/dev/null)" "$_rt_rsrp" \
				"$(printf '%s' "$_rt" | jsonfilter -e '@.rsrq' 2>/dev/null)" \
				"$(printf '%s' "$_rt" | jsonfilter -e '@.sinr' 2>/dev/null)" \
				"${_rt_tp:+$_rt_tp &deg;C}" "${_rt_ph:--}" "$_rt_cts" "$_rt_cto" "$_rt_ctsn" "$_rt_rx" "$_rt_tx" "$_tj_if" "${_tj_ip:--}" "$_tj_gw" "$_tj_nd" > "$_rt_tmp"
			cat "$_rt_tmp"
			if jsonfilter -i "$_rt_tmp" -e '@.modem' >/dev/null 2>&1; then
				mv "$_rt_tmp" "$CACHE" && uptime_s > "$STAMP"
				_rt_opc=$(operator_clean "$_rt_op")
				[ -n "$_tj_if" ] && [ -n "$_rt_opc" ] && printf '%s' "$_rt_opc" > "/tmp/5gmodem/op_$_tj_if" 2>/dev/null
				_rt_vp="$(cat "/sys/bus/usb/devices/$_POLL_AM/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$_POLL_AM/idProduct" 2>/dev/null)"
				if [ -n "$_rt_ml" ] && { [ "$(uci -q get "5gmodem.$_hl_sec.model")" != "$_rt_ml" ] || [ "$(uci -q get "5gmodem.$_hl_sec.model_vp")" != "$_rt_vp" ]; }; then
					uci -q set "5gmodem.$_hl_sec.model=$_rt_ml"
					uci -q set "5gmodem.$_hl_sec.model_vp=$_rt_vp"
					uci -q commit 5gmodem
					rm -f /tmp/5gmodem/listmodems.cache /tmp/5gmodem/listmodems.stamp 2>/dev/null
				fi
			fi
			rm -f "$_rt_tmp"
			exit 0
		fi
	fi
	printf '{"error":"Device not found","onbus":"1","path":"%s","tether":"%s","tether_state":"%s","tether_name":"%s","netdev":"%s","iface":"%s","ipaddr":"%s","gateway":"%s"}\n' \
		"$_POLL_AM" "$_tj_os" "$_tj_st" "$_tj_nm" "$_tj_nd" "$_tj_if" "$_tj_ip" "$_tj_gw"
	exit 0
fi

if [ -f "/var/run/5gmodem-mm-inhibit/${_POLL_AM}.pause" ]; then
	_age=$(_snapshot_age) && { serve_cache "$_age"; exit 0; }
	[ -s "$CACHE" ] && { serve_cache 9999; exit 0; }
	echo '{}'
	exit 0
fi

if [ "$_hl_kind" = "hilink" ] && [ -z "$_hl_at" ]; then
	_hl_cache="/tmp/5gmodem/hilink_metrics_$_MKEY"
	_hl_ttl="${2:-5}"
	case "$_hl_ttl" in ''|*[!0-9]*) _hl_ttl=5 ;; esac
	_hl_t=$(cat "$_hl_cache.t" 2>/dev/null)
	case "$_hl_t" in ''|*[!0-9]*) _hl_t=0 ;; esac
	if [ -s "$_hl_cache" ] && [ -z "$(find "$_hl_cache" -mmin +1 2>/dev/null)" ] 	   && [ "$(( $(uptime_s) - _hl_t ))" -lt "$_hl_ttl" ]; then
		cat "$_hl_cache"
		exit 0
	fi
	_hl_out=$("$RES/hilink.sh" json "$_POLL_AM" 2>/dev/null)
	case "$_hl_out" in
		'{'*)
			printf '%s\n' "$_hl_out" > "$_hl_cache.tmp" && mv "$_hl_cache.tmp" "$_hl_cache"
			cut -d. -f1 /proc/uptime > "$_hl_cache.t.tmp" && mv "$_hl_cache.t.tmp" "$_hl_cache.t"
			printf '%s\n' "$_hl_out"
			_hl_ml=$(printf '%s' "$_hl_out" | jsonfilter -e '@.modem' 2>/dev/null)
			_hl_vp=$(uci -q get "5gmodem.$_hl_sec.vidpid")
			if [ -n "$_hl_ml" ] && [ "$(uci -q get "5gmodem.$_hl_sec.kind")" = hilink ] \
			   && { [ "$(uci -q get "5gmodem.$_hl_sec.model")" != "$_hl_ml" ] || [ "$(uci -q get "5gmodem.$_hl_sec.model_vp")" != "$_hl_vp" ]; }; then
				uci -q set "5gmodem.$_hl_sec.model=$_hl_ml"
				uci -q set "5gmodem.$_hl_sec.model_vp=$_hl_vp"
				uci -q commit 5gmodem
				rm -f /tmp/5gmodem/listmodems.cache /tmp/5gmodem/listmodems.stamp 2>/dev/null
			fi
			;;
		*)
			_hl_a=$(( $(uptime_s) - _hl_t ))
			if [ -s "$_hl_cache" ] && [ "$_hl_a" -lt 30 ] 2>/dev/null; then
				cat "$_hl_cache"
			else
				echo "{\"error\":\"Device not found\",\"onbus\":\"$(_active_onbus)\"}"
			fi
			;;
	esac
	exit 0
fi

if [ "$1" = "cached" ]; then
	[ -z "$SW_BG" ] && uptime_s > /tmp/5gmodem/page_active 2>/dev/null
	_ttl="${2:-15}"
	case "$_ttl" in ''|*[!0-9]*) _ttl=15 ;; esac
	_age=$(_snapshot_age)
	if [ -n "$_age" ] && [ "$_age" -lt "$_ttl" ]; then
		serve_cache "$_age"
		exit 0
	fi
	if [ -z "$_age" ]; then
		if [ ! -d "$LOCKDIR" ]; then
			( exec 8>&- 9>&-; POLL_MODEM="$POLL_MODEM" "$RES/5gmodem.sh" json ) >/dev/null 2>&1 </dev/null &
		fi
		_w=0
		while [ "$_w" -lt 20 ]; do
			sleep 1; _w=$((_w + 1))
			_a=$(_snapshot_age) && { serve_cache "$_a"; exit 0; }
			[ "$_w" -ge 2 ] && [ ! -d "$LOCKDIR" ] && break
		done
		[ "$_w" -ge 20 ] && { echo '{"error":"busy"}'; exit 0; }
	fi
	if ! _take_lock; then
		_a=$(_snapshot_age) && { serve_cache "$_a"; exit 0; }
		_w=0
		while [ "$_w" -lt 20 ]; do
			sleep 1; _w=$((_w + 1))
			_a=$(_snapshot_age) && { serve_cache "$_a"; exit 0; }
			[ -d "$LOCKDIR" ] || break
		done
		echo '{"error":"busy"}'
		exit 0
	fi
	uptime_s > "$LOCKDIR/stamp" 2>/dev/null
	trap 'rm -rf "$LOCKDIR" 2>/dev/null; _cleanup_tmp' EXIT
else
	if _take_lock; then
		uptime_s > "$LOCKDIR/stamp" 2>/dev/null
		trap 'rm -rf "$LOCKDIR" 2>/dev/null; _cleanup_tmp' EXIT
	else
		_age=$(_snapshot_age)
		[ -n "$_age" ] && [ "$_age" -lt 3 ] && { serve_cache "$_age"; exit 0; }
	fi
fi

if [ -n "$_PINNED" ]; then
	_pin_rec=$("$RES/registry.sh" path "$_POLL_AM" 2>/dev/null)
	DEVICE=$(printf '%s' "$_pin_rec" | jsonfilter -e '@.at_port' 2>/dev/null)
	if [ -n "$DEVICE" ] \
	   && { [ "$(printf '%s' "$_pin_rec" | jsonfilter -e '@.owner' 2>/dev/null)" = "mm" ] \
	        || proto_in proxy "$(uci -q get "network.$(uci -q get "5gmodem.$_hl_sec.network" 2>/dev/null).proto" 2>/dev/null)"; }; then
		. "$RES/quirks.sh" 2>/dev/null
		mm_at_allowed "$_POLL_AM" "$_hl_sec" || DEVICE=""
		[ -n "$MM_AT_PORT" ] && DEVICE="$MM_AT_PORT"
	fi
else
	DEVICE=$($RES/detect.sh)
fi

. "$RES/atlock.sh"
if [ -n "$DEVICE" ] && at_dialer_busy "$DEVICE"; then
	_age=$(_snapshot_age)
	[ -n "$_age" ] && { serve_cache "$_age"; exit 0; }
	echo '{}'
	exit 0
fi
if [ -n "$DEVICE" ] && ! at_lock "$DEVICE" 10; then
	_age=$(_snapshot_age)
	[ -n "$_age" ] && { serve_cache "$_age"; exit 0; }
	echo '{}'
	exit 0
fi

if [ -n "$DEVICE" ] && [ -n "$_POLL_AM" ]; then
	_own_rec=$("$RES/listmodems.sh" 2>/dev/null)
	if [ -n "$(printf '%s' "$_own_rec" | jsonfilter -e "@[@.path=\"$_POLL_AM\"].path" 2>/dev/null)" ]; then
		_own_ttys=$(printf '%s' "$_own_rec" | jsonfilter -e "@[@.path=\"$_POLL_AM\"].tty[*]" 2>/dev/null | tr '\n' ' ')
		case " $_own_ttys " in
			*" $DEVICE "*) : ;;
			*) logger -t 5gmodem "port $DEVICE does not belong to modem $_POLL_AM - skipping the poll"
			   DEVICE="" ;;
		esac
	fi
fi

PORTOK="/tmp/5gmodem/portok_$_MKEY"
_pok=""
if [ -n "$DEVICE" ]; then
	read -r _pok_port _pok_t 2>/dev/null < "$PORTOK"
	case "$_pok_t" in ''|*[!0-9]*) _pok_t="" ;; esac
	if [ "$_pok_port" = "$DEVICE" ] && [ -n "$_pok_t" ] \
	   && [ "$(( $(uptime_s) - _pok_t ))" -lt 30 ] 2>/dev/null; then
		_pok=1
	fi
fi
_hl_noat=$(uci -q get "5gmodem.$_hl_sec.no_at" 2>/dev/null)
[ -n "$DEVICE" ] && [ -z "$_pok" ] && [ "$_hl_noat" != "1" ] \
	&& ! "$RES/atprobe.sh" "$DEVICE" && DEVICE=""
if [ -z "$DEVICE" ]; then
	_amp0_if=$(uci -q get "5gmodem.$_hl_sec.network")
	if [ "$(uci -q get "network.$_amp0_if.proto" 2>/dev/null)" != modemmanager ] \
	   && ! { [ "$_hl_noat" = "1" ] && [ "$(_active_onbus)" = 1 ]; } \
	   && ! mm_owns_path "$_POLL_AM"; then
		_sh_mark=/tmp/5gmodem/selfresolve
		_sh_now=$(cut -d. -f1 /proc/uptime)
		_sh_last=$(cat "$_sh_mark" 2>/dev/null); case "$_sh_last" in ''|*[!0-9]*) _sh_last=0 ;; esac
		if [ -n "$_POLL_AM" ] && [ "$((_sh_now - _sh_last))" -ge 60 ] \
		   && ! "$RES/listmodems.sh" | jsonfilter -e '@[*].path' 2>/dev/null | grep -qxF "$_POLL_AM"; then
			printf '%s' "$_sh_now" > "$_sh_mark" 2>/dev/null
			logger -t 5gmodem "active modem \"$_POLL_AM\" is missing from the list - re-evaluating (resolve)"
			( unset _AT_LOCK_HELD; exec 7>&- 8>&- 9>&-; "$RES/modemswitch.sh" resolve >/dev/null 2>&1 & ) </dev/null
		fi
		_age=$(_snapshot_age)
		[ -n "$_age" ] && [ "$_age" -lt 30 ] && { serve_cache "$_age"; exit 0; }
		if [ "$(_active_onbus)" = 1 ] && [ -n "$_POLL_AM" ] \
		   && [ -n "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_POLL_AM\"].tty[0]" 2>/dev/null)" ]; then
			[ -n "$_age" ] && { serve_cache "$_age"; exit 0; }
			echo '{"error":"Device not found","onbus":"1","hasports":"1"}'
			exit 0
		fi
		echo "{\"error\":\"Device not found\",\"onbus\":\"$(_active_onbus)\"}"
		exit 0
	fi
fi

_st_ident_cmd() {
	case " $* " in *" -D "*) return 0 ;; esac
	case " $* " in *" at "*) : ;; *) return 0 ;; esac
	eval "_stq=\${$#}"
	case "$_stq" in *";"*|*"@"*) return 0 ;; esac
	case "$_stq" in
		*[Gg][Mm][IiMmRr]*|*[Gg][Ss][Nn]*|*[Ii][Mm][Ii]*|*[Cc][Ii][Dd]*|*[Gg][Tt][Pp][Kk][Gg]*) : ;;
		*) return 0 ;;
	esac
	_stn_c=$(printf '%s' "$_stq" | tr 'a-z' 'A-Z' | sed 's/^AT//; s/^[+#]//; s/[? ]*$//')
	case "$_stn_c" in
		CGMI|GMI|CGMM|GMM|CGMR|GMR|CGSN|GSN|CIMI|CCID|ICCID|QCCID|GTPKGVER)
			printf '%s' "$_stn_c" ;;
	esac
}

_st_static_key() {
	[ -n "$STATIC_CACHE" ] || return 0
	_stn_k=$(_st_ident_cmd "$@")
	[ -n "$_stn_k" ] && printf '%s' "${STATIC_CACHE}_cmd_$_stn_k"
}

_st_drop_ok() { tr -s '\r\n' '\n\n' | grep -vE '^[[:space:]]*OK[[:space:]]*$'; }
_st_static_ok() {
	[ -s "$1" ] || return 1
	grep -q "ERROR" "$1" && return 1
	tr -d '\r' < "$1" | grep -qvE '^AT|^OK$|^$' || return 1
	case "$_stc" in
		*_cmd_CGSN|*_cmd_GSN|*_cmd_CIMI|*_cmd_CCID|*_cmd_ICCID|*_cmd_QCCID)
			grep -qE '[0-9]{14}' "$1" || return 1 ;;
	esac
	return 0
}
_st_n=0
if (sleep 0.0) 2>/dev/null; then _sts=0.05; else _sts=1; fi
sms_tool() {
	[ -n "$DEVICE" ] || return 0
	_sti=$(_st_ident_cmd "$@")
	_stc=""
	[ -n "$STATIC_CACHE" ] && [ -n "$_sti" ] && _stc="${STATIC_CACHE}_cmd_$_sti"
	if [ -n "$_stc" ] && [ -s "$_stc" ]; then
		_st_drop_ok < "$_stc"
		return 0
	fi
	_st_n=$((_st_n + 1)); _stf="/tmp/5gmodem/st.$$.$_st_n"
	if [ "$_sts" = 1 ]; then
		{
			( sleep 8 </dev/null & _stw=$!; trap 'kill $_stw; exit' TERM; wait $_stw; echo t ) &
			echo $! > "$_stf.s"
			( /usr/bin/sms_tool "$@" > "$_stf" 2>/dev/null </dev/null & _stw=$!
			  trap 'kill $_stw; exit' TERM; wait $_stw; echo d ) &
			echo $! > "$_stf.p"
		} 2>/dev/null 8>&- 9>&- | read -r _str
		kill "$(cat "$_stf.s" 2>/dev/null)" 2>/dev/null
		_stp=$(cat "$_stf.p" 2>/dev/null)
		[ -n "$_stp" ] && kill -0 "$_stp" 2>/dev/null && kill "$_stp" 2>/dev/null
		rm -f "$_stf.s" "$_stf.p"
	else
		/usr/bin/sms_tool "$@" > "$_stf" 2>/dev/null 8>&- 9>&- &
		_stp=$!
		IFS=' ' read -r _stu _ < /proc/uptime; _st0="${_stu%.*}${_stu#*.}"
		_stkd=""
		while kill -0 "$_stp" 2>/dev/null; do
			sleep "$_sts"
			IFS=' ' read -r _stu _ < /proc/uptime; _stw=$(( ${_stu%.*}${_stu#*.} - _st0 ))
			[ "$_stw" -ge 1000 ] && break
			[ -z "$_stkd" ] && [ "$_stw" -ge 800 ] && { kill "$_stp" 2>/dev/null; _stkd=1; }
		done
		kill -0 "$_stp" 2>/dev/null || wait "$_stp" 2>/dev/null
	fi
	_stp=""; _stk=""
	if [ -n "$_stc" ] && _st_static_ok "$_stf"; then
		cp "$_stf" "$_stc.$$" 2>/dev/null && mv "$_stc.$$" "$_stc" 2>/dev/null
	fi
	if [ -n "$_sti" ]; then _st_drop_ok < "$_stf" 2>/dev/null
	else cat "$_stf" 2>/dev/null; fi
	rm -f "$_stf"
}

_MM_OWNS=""
_SN_NOAT=""
if [ "$_hl_noat" = "1" ]; then
	_MM_OWNS=1
	_SN_NOAT=1
	DEVICE=""
else
	_mo_if=$(uci -q get "5gmodem.$_hl_sec.network")
	if [ "$(uci -q get "network.$_mo_if.proto" 2>/dev/null)" != modemmanager ] \
	   && mm_owns_path "$_POLL_AM"; then
		_MM_OWNS=1
		DEVICE=""
	fi
fi

O=""
if [ -e /usr/bin/sms_tool ]; then
	O=$(sms_tool -D -d $DEVICE at "AT+CPIN?;+CSQ;+COPS=3,0;+COPS?;+COPS=3,2;+COPS?;+CREG=2;+CREG?;+CEREG=2;+CEREG?;+CNUM;+CIMI")
	case "$O" in
		"") : ;;
		*"+CREG:"*|*"+CEREG:"*) : ;;
		*)
			O=$(sms_tool -D -d $DEVICE at "AT+CPIN?;+CSQ")
			O="$O
$(sms_tool -D -d $DEVICE at "AT+COPS=3,0;+COPS?")
$(sms_tool -D -d $DEVICE at "AT+COPS=3,2;+COPS?")
$(sms_tool -D -d $DEVICE at "AT+CREG=2;+CREG?")
$(sms_tool -D -d $DEVICE at "AT+CEREG=2;+CEREG?")
$(sms_tool -D -d $DEVICE at "AT+CNUM")
$(sms_tool -D -d $DEVICE at "AT+CIMI")"
			;;
	esac
	if [ -z "$O" ] && [ -n "$DEVICE" ]; then
		rm -f "$PORTOK" 2>/dev/null
		_wg=$(_snapshot_age) && {
			logger -t 5gmodem "poll of $DEVICE is stuck - serving the previous snapshot (${_wg}s)"
			serve_cache "$_wg"; exit 0
		}
	fi
	case "$O" in
		*"+CSQ:"*) printf '%s %s\n' "$DEVICE" "$(uptime_s)" > "$PORTOK" 2>/dev/null ;;
	esac
else
	O=$(gcom -d $DEVICE -s $RES/info.gcom 2>/dev/null)
fi

getpath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		P=${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
		P=${devpath%/*}
		;;
	esac
}

CONFIG=modemdefine
MODEMZ=0
[ -f /etc/config/$CONFIG ] && MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [ "$MODEMZ" -gt 1 ]; then
	SEC=$(uci -q get modemdefine.@general[0].main_network)
fi
if [ "$MODEMZ" -eq 0 ]; then
	SEC=$(uci -q get "5gmodem.$_hl_sec.network")
	[ -n "$SEC" ] || [ -n "$_PINNED" ] || SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
fi
if [ "$MODEMZ" -eq 1 ]; then
	SEC=$(uci -q get modemdefine.@modemdefine[0].network)
fi

if [ -z "$SEC" ]; then
	_AMP=$(printf '%s' "${_POLL_AM:-$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null)}" | tr -c 'A-Za-z0-9' '_')
	[ -n "$_AMP" ] && SEC=$(uci -q get "5gmodem.m_${_AMP%_}.network" 2>/dev/null)
fi

if [ -z "$SEC" ]; then
	getpath $DEVICE
	PORIG=$P
	for DEV in /sys/class/tty/* /sys/class/usbmisc/*; do
		[ -e "$DEV" ] || continue
		getpath "/dev/${DEV##/*/}"
		if [ "x$PORIG" == "x$P" ]; then
			SEC=$(uci show network | grep "/dev/${DEV##/*/}" | cut -f2 -d.)
			[ -n "$SEC" ] && break
		fi
	done
fi

if [ -z "$SEC" ]; then
	for PROTO in modemmanager qmi mbim ncm wwan; do
		S=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='$PROTO'\$/\1/p" | head -1)
		if [ -n "$S" ]; then
			SEC=$S
			break
		fi
	done
fi

CONN_TIME="-"
RX="-"
TX="-"

SECSTATUS=$(ifstatus "$SEC" 2>/dev/null)
_SECST_FOR="$SEC"
NETUP=$(echo "$SECSTATUS" | grep "\"up\": true")
if [ -n "$NETUP" ]; then

		CT=$(uci -q -P /var/state/ get network.$SEC.connect_time)
		if [ -z "$CT" ]; then
			CT=$(echo "$SECSTATUS" | awk -F[:,] '/uptime/ {print $2}' | xargs)
		else
			UPTIME=$(uptime_s)
			CT=$((UPTIME-CT))
		fi
		if [ -n "$CT" ]; then

			D=$((CT / 60 / 60 / 24))
			H=$((CT / 60 / 60 % 24))
			M=$((CT / 60 % 60))
			S=$((CT % 60))
			CONN_TIME=$(printf "%dd, %02d:%02d:%02d" $D $H $M $S)
			CONN_TIME_SINCE=$(date "+%Y%m%d%H%M%S" -d "@$(($(date +%s) - CT))")
			
		fi
		
		IFACE=$(echo "$SECSTATUS" | awk -F\" '/l3_device/ {print $4}')
		if [ -n "$IFACE" ]; then
			_RXTX=$(ifconfig "$IFACE" 2>/dev/null | awk -F[\(\)] '/bytes/ {printf "%s|%s",$2,$4}')
			if [ -n "$_RXTX" ]; then
				RX="${_RXTX%%|*}"
				TX="${_RXTX##*|}"
			fi
		fi
fi

CSQ=$(echo "$O" | awk -F[,\ ] '/^\+CSQ/ {print $2; exit}')

[ "x$CSQ" == "x" ] && CSQ=-1
if [ $CSQ -ge 0 -a $CSQ -le 31 ]; then
	CSQ_PER=$(($CSQ * 100/31))
else
	CSQ=""
	CSQ_PER=""
fi

COPS=""
COPS_MCC=""
COPS_MNC=""
COPS_FROM_MODEM=0
COPS_NUM=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,2/ {print $2}')
if [ -n "$COPS_NUM" ]; then
	COPS_MCC=${COPS_NUM:0:3}
	COPS_MNC=${COPS_NUM:3:3}
fi

TCOPS=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,0/ {print $2}')
if [ -n "$TCOPS" ] && [ $(( ${#TCOPS} % 4 )) -eq 0 ] && echo "$TCOPS" | grep -qE '^[0-9A-Fa-f]+$'; then
	DEC=""
	for h in $(echo "$TCOPS" | sed 's/\(....\)/\1 /g'); do
		c=$((0x$h))
		if [ "$c" -lt 128 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' "$c")")"
		elif [ "$c" -lt 2048 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' $((192 | (c >> 6))))\\$(printf '%03o' $((128 | (c & 63))))")"
		else
			DEC="$DEC$(printf "\\$(printf '%03o' $((224 | (c >> 12))))\\$(printf '%03o' $((128 | ((c >> 6) & 63))))\\$(printf '%03o' $((128 | (c & 63))))")"
		fi
	done
	[ -n "$DEC" ] && TCOPS="$DEC"
fi
[ "x$TCOPS" != "x" ] && { COPS="$TCOPS"; COPS_FROM_MODEM=1; }

_MCC_K="-"; _MCC_N=""; _MCC_L=""
_mcc_row() {
	[ "$1" = "$_MCC_K" ] && return 0
	_MCC_K="$1"; _MCC_N=""; _MCC_L=""
	case "$1" in ''|*[!0-9]*) return 0 ;; esac
	_mcc_r=$(awk -F';' -v c="$1" '$1 "" == c "" { n = n " " $3; if (!f) { l = $2; f = 1 } }
		END { gsub(/[ \t\r\n]+/, " ", n); sub(/^ /, "", n); sub(/ $/, "", n); printf "%s;%s", l, n }' "$RES/mccmnc.dat" 2>/dev/null)
	_MCC_L="${_mcc_r%%;*}"; _MCC_N="${_mcc_r#*;}"
}

if [ -z "$COPS" ]; then
	if [ -n "$COPS_NUM" ]; then
		_mcc_row "$COPS_NUM"
		COPS="$_MCC_N"
		LOC="$_MCC_L"
	fi
fi
[ -z "$COPS" ] && COPS=$COPS_NUM

PHONE=$(echo "$O" | awk -F'"' '/^\+CNUM:/{for(i=1;i<=NF;i++){if($i ~ /^[+]?[0-9][0-9][0-9][0-9][0-9]+$/){print $i; exit}}}')
if [ -n "$PHONE" ] && [ "${PHONE#+}" = "$PHONE" ]; then
	echo "$O" | grep '^+CNUM:' | grep -q ',145' && PHONE="+$PHONE"
fi

case "$COPS" in
    *\ *) 
        COPS=$(echo "$COPS" | awk '{if(NF==2 && tolower($1)==tolower($2)){print $1}else{print $0}}')
        ;;
esac

isp_num="$COPS_MCC $COPS_MNC"
isp_numws="$COPS_MCC$COPS_MNC"
isp="$isp_numws"

case "$COPS" in
    ''|*[!0-9\ ]*)
        # the space in the pattern is required, see docs/subsystems/polling.md#operator-name
        ;;
    *) 
        isp_rev="$COPS_MNC $COPS_MCC"
        isp_revws="$COPS_MNC$COPS_MCC"
        if [ "$COPS" = "$isp_num" ] || [ "$COPS" = "$isp_numws" ] || \
           [ "$COPS" = "$isp_rev" ] || [ "$COPS" = "$isp_revws" ]; then
            if [ -n "$isp" ]; then
                _mcc_row "$isp"
                COPS="$_MCC_N"
                LOC="$_MCC_L"
            fi
        fi
	;;
esac

SIMID=$(echo "$O" | tr -d '\r' | grep -xE '[0-9]{14,16}' | head -1)

OPCACHE="/tmp/5gmodem/operator_$SIMID"
_opc_v=""
[ -n "$SIMID" ] && [ -f "$OPCACHE" ] && IFS= read -r _opc_v 2>/dev/null < "$OPCACHE"
if [ -n "$COPS" ] && echo "$COPS" | grep -qE '^[0-9 ]+$'; then
	CACHED=""
	if [ -n "$SIMID" ]; then
		CACHED="$_opc_v"
	fi
	if [ -n "$CACHED" ]; then
		COPS="$CACHED"
	elif [ -n "$COPS_NUM" ]; then
		_mcc_row "$COPS_NUM"; NAME="$_MCC_N"
		[ -n "$NAME" ] && COPS="$NAME"
	fi
elif [ "$COPS_FROM_MODEM" = "1" ] && [ -n "$SIMID" ] && [ -n "$COPS" ]; then
	[ "$_opc_v" = "$COPS" ] || printf '%s\n' "$COPS" > "$OPCACHE"
fi

SPNCACHE="/tmp/5gmodem/spn_$SIMID"
SPN=""
if [ -n "$SIMID" ] && [ -s "$SPNCACHE" ]; then
	IFS= read -r SPN 2>/dev/null < "$SPNCACHE"
elif [ -n "$SIMID" ] && [ -f "$SPNCACHE.none" ] && [ -z "$(find "$SPNCACHE.none" -mmin +4 2>/dev/null)" ]; then
	:
else
	_spn_raw=$(sms_tool -d "$DEVICE" at "AT+CRSM=176,28486,0,0,17" 2>/dev/null | tr -d '\r" ')
	SPNHEX=$(printf '%s\n' "$_spn_raw" \
		| sed -n 's/.*+CRSM:[^,]*,[^,]*,\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')
	if [ -n "$SPNHEX" ]; then
		SPN=$(echo "$SPNHEX" | sed 's/^..//' | sed 's/\(..\)/\1 /g' | tr ' ' '\n' | while read b; do
			[ -z "$b" ] && continue
			{ [ "$b" = "FF" ] || [ "$b" = "ff" ]; } && break
			v=$((0x$b))
			[ "$v" -ge 32 ] && [ "$v" -lt 127 ] && printf "\\$(printf '%03o' "$v")"
		done)
		[ -n "$SPN" ] && [ -n "$SIMID" ] && printf '%s\n' "$SPN" > "$SPNCACHE"
	fi
	if [ -z "$SPN" ] && [ -n "$SIMID" ]; then
		case "$_spn_raw" in
			*+CRSM:*|*ERROR*) : > "$SPNCACHE.none" 2>/dev/null ;;
		esac
	fi
fi
SPN_NAME=""
if [ -n "$SPN" ] && ! echo "$SPN" | grep -qE '^[0-9 ]*$'; then
	MCCNAME=""
	[ -n "$COPS_NUM" ] && { _mcc_row "$COPS_NUM"; MCCNAME="$_MCC_N"; }
	if [ -n "$MCCNAME" ] && [ "$(echo "$SPN" | tr 'A-Z' 'a-z')" = "$(echo "$MCCNAME" | tr 'A-Z' 'a-z')" ]; then
		SPN_NAME="$MCCNAME"
	else
		SPN_NAME="$SPN"
	fi
fi

LOCATIONFILE=/tmp/5gmodem/location
if [ -e "$LOCATIONFILE" ]; then
	LOC=""; IFS= read -r LOC 2>/dev/null < "$LOCATIONFILE"
	if [ -n "$LOC" ]; then
		_loc_prev="$LOC"
		if [ "$LOC" = "-" ]; then
			rm -f "$LOCATIONFILE"
			_loc_prev=""
		fi
		_mcc_row "$COPS_NUM"; LOC="$_MCC_L"
		if [ -n "$LOC" ] && [ "$LOC" != "$_loc_prev" ]; then
			echo "$LOC" > /tmp/5gmodem/location
		fi
	fi
else
	case "$COPS_MCC$COPS_MNC" in
		*[!0-9]* | '')
			;;
		*)
			if [ -n "$LOC" ]; then
				_mcc_row "$COPS_MCC$COPS_MNC"; LOC="$_MCC_L"
				echo "$LOC" > /tmp/5gmodem/location
			else
				echo "-" > /tmp/5gmodem/location
			fi
			;;
	esac
fi

SIM_STATE=""
T=$(echo "$O" | awk -F[,\ ] '/^\+CPIN:/ {print $0;exit}' | xargs)
if [ -n "$T" ]; then
	case "$T" in
		"+CPIN: READY"|*PIN2*|*PUK2*) : ;;
		*) SIM_STATE=$(echo "$T" | cut -f2 -d: | xargs);;
	esac
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CME ERROR:/ {print $0;exit}')
if [ -n "$T" ]; then
	CME_CODE=$(printf '%s' "$T" | sed -n 's/^+CME ERROR:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
	case "$CME_CODE" in
		10) SIM_STATE="SIM not inserted";;
		11) SIM_STATE="SIM PIN required";;
		12) SIM_STATE="SIM PUK required";;
		13) SIM_STATE="SIM failure";;
		14) SIM_STATE="SIM busy";;
		15) SIM_STATE="SIM wrong";;
		17) SIM_STATE="SIM PIN2 required";;
		18) SIM_STATE="SIM PUK2 required";;
		"") SIM_STATE=$(echo "$T" | cut -f2 -d: | xargs);;
	esac
fi

eval $(echo "$O" | busybox awk -F[,] '/^\+CREG:[[:space:]]*[0-9][[:space:]]*,[[:space:]]*[0-9][0-9]?[[:space:]]*(,|$)/ {gsub(/[[:space:]"]+/,"");printf "T=\"%d\";LAC_HEX=\"%X\";CID_HEX=\"%X\";LAC_DEC=\"%d\";CID_DEC=\"%d\";MODE_NUM=\"%d\"", $2, "0x"$3, "0x"$4, "0x"$3, "0x"$4, $5; exit}')
case "$T" in
	0*) REG="0";;
	1*) REG="1";;
	2*) REG="2";;
	3*) REG="3";;
	5*) REG="5";;
	6*) REG="6";;
	7*) REG="7";;
	*) REG="";;
esac

REG_CS="$REG"
case "$REG" in
	0|2|3|4|6|7|'')
	CEREG_STAT=$(echo "$O" | busybox awk -F[,] '/^\+CEREG:[[:space:]]*[0-9][[:space:]]*,[[:space:]]*[0-9][0-9]?[[:space:]]*(,|$)/{gsub(/[[:space:]"]+/,"");print $2;exit}')
	case "$CEREG_STAT" in
		1) REG="1";;
		5) REG="5";;
	esac
	;;
esac

[ -n "$REG" ] || REG="$SIM_STATE"

if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" == "x0" ]; then
	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS: [0-9],2/ {print $4;exit}' | xargs)
fi
if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" = "x0" ]; then
	_ceact=$(echo "$O" | tr -d '\r' | awk -F, '/^\+CEREG: *[0-9]+, *[15] *,/ {gsub(/[^0-9]/,"",$5); print $5; exit}')
	case "$_ceact" in [0-9]|1[0-9]) MODE_NUM="$_ceact" ;; esac
fi
case "$MODE_NUM" in
	2*) MODE="UMTS";;
	3*) MODE="EDGE";;
	4*) MODE="HSDPA";;
	5*) MODE="HSUPA";;
	6*) MODE="HSPA";;
	7*) MODE="LTE";;
	 *) MODE="-";;
esac

TAC=$(echo "$O" | awk -F[,] '/^\+CEREG:[[:space:]]*[0-9][[:space:]]*,[[:space:]]*[0-9][0-9]?[[:space:]]*(,|$)/ {printf "%s", toupper($3); exit}' | sed 's/[^A-F0-9]//g')
if [ "x$TAC" != "x" ]; then
	TAC_HEX="$TAC"
	TAC_DEC=$(printf %d 0x$TAC 2>/dev/null)
else
	TAC="-"
	TAC_HEX="-"
fi

if [ -n "$_PINNED" ]; then
	CONF_DEVICE="$DEVICE"
else
	CONF_DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
fi
if echo "x$CONF_DEVICE" | grep -q "192.168."; then
	if grep -q "Vendor=1bbb" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/alcatel_hilink.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	if grep -q "Vendor=12d1" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/huawei_hilink.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	if grep -q "Vendor=19d2" /sys/kernel/debug/usb/devices; then
		_SAVED_IFS="$IFS"; . $RES/modem/hilink/zte.sh $DEVICE; IFS="$_SAVED_IFS"
	fi
	SEC=$(uci -q get "5gmodem.$_hl_sec.network")
	[ -n "$SEC" ] || [ -n "$_PINNED" ] || SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
	SEC=${SEC:-wan}
else

_STKEY=$(tty_usbpath "$DEVICE" 2>/dev/null | tr -d '\n' | tr -c 'A-Za-z0-9' '_')
[ -n "$_STKEY" ] || _STKEY=$(printf '%s' "${_POLL_AM:-$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null)}" | tr -c 'A-Za-z0-9' '_')
[ -n "$_STKEY" ] || _STKEY="$(basename "$DEVICE" 2>/dev/null)"
STATIC_CACHE="/tmp/5gmodem/static_$_STKEY"
case "$REG" in
	5|7|10)
		_sim_mcc=$(printf '%s' "$SIMID" | cut -c1-3)
		case "$_sim_mcc" in
			''|*[!0-9]*) : ;;
			*)
				if [ -n "$COPS_MCC" ] && [ "$COPS_MCC" = "$_sim_mcc" ]; then
					case "$REG" in
						5)  REG=1 ;;
						7)  REG=6 ;;
						10) REG=9 ;;
					esac
					logger -t 5gmodem "network $COPS_NUM is in the same country as the SIM ($_sim_mcc) - not showing roaming"
				fi
				;;
		esac
		;;
esac

_PREV_IMSI=$(cat "${STATIC_CACHE}.imsi" 2>/dev/null)
if [ -n "$SIMID" ] && [ "$_PREV_IMSI" != "$SIMID" ]; then
	rm -f "${STATIC_CACHE}"_* 2>/dev/null
	printf '%s' "$SIMID" > "${STATIC_CACHE}.imsi"
fi
if [ -z "$SIMID" ] && [ -e "${STATIC_CACHE}.imsi" ]; then
	case "$SIM_STATE" in
		*[Nn][Oo][Tt]\ [Ii][Nn][Ss][Ee][Rr][Tt]*)
			rm -f "${STATIC_CACHE}_cmd_CIMI" "${STATIC_CACHE}_cmd_CCID" "${STATIC_CACHE}_cmd_ICCID" \
				"${STATIC_CACHE}_cmd_QCCID" "${STATIC_CACHE}_iccid" "${STATIC_CACHE}_ccid" \
				"${STATIC_CACHE}.imsi" 2>/dev/null ;;
	esac
fi

if [ -n "$SIMID" ]; then
	_apn_sec="$_hl_sec"
	[ -n "$(uci -q get "5gmodem.$_apn_sec" 2>/dev/null)" ] || _apn_sec=""
	if [ -n "$_apn_sec" ] \
	   && [ "$(uci -q get "5gmodem.$_apn_sec.apn_mode")" != "manual" ] \
	   && [ "$(uci -q get "5gmodem.$_apn_sec.apn_imsi")" != "$SIMID" ]; then
		_SIM_IF=$(uci -q get "5gmodem.$_apn_sec.network" 2>/dev/null)
		[ -n "$_SIM_IF" ] || [ "$_POLL_AM" != "$_ACT_AM" ] || _SIM_IF=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
		_apn_stamp="/tmp/5gmodem/autoapn_$_apn_sec"
		_apn_wait=1
		[ -f "$_apn_stamp.gaveup" ] && _apn_wait=30
		if [ -n "$_SIM_IF" ] && { [ ! -f "$_apn_stamp" ] || [ -n "$(find "$_apn_stamp" -mmin +$_apn_wait 2>/dev/null)" ]; }; then
			: > "$_apn_stamp"
			logger -t 5gmodem "SIM change (IMSI) on $_SIM_IF - re-selecting the APN"
			rm -f "/tmp/5gmodem/slots_$_POLL_AM" "/tmp/5gmodem/slots_$_POLL_AM.t" 2>/dev/null
			( unset _AT_LOCK_HELD; eval "exec $AT_LOCK_FD>&-" 2>/dev/null
			  /usr/share/5gmodem/modemswitch.sh autoapn "$_SIM_IF" "$SIMID" ) \
				>/dev/null 2>&1 </dev/null &
		fi
	fi
fi
at_static() {
	_cf="${STATIC_CACHE}_$1"
	[ -s "$_cf" ] && { cat "$_cf"; return; }
	_out=$(sms_tool -d "$DEVICE" at "$2" 2>/dev/null)
	printf '%s' "$_out"
	if [ -n "$3" ]; then
		printf '%s' "$_out" | tr -d '\r' | grep -qE "$3" || return 0
	fi
	[ -n "$_out" ] && printf '%s' "$_out" > "$_cf"
	return 0
}

sanitize_string() {
	case "$1" in
		'') printf '%s\n' "-" ;;
		*[[:cntrl:]]*) printf '%s' "$1" | tr -d '\000-\037'; printf '\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}
sanitize_number() {
	case "$1" in
		'') printf '%s\n' "-" ;;
		*[[:cntrl:]]*) printf '%s' "$1" | tr -d '\000-\037'; printf '\n' ;;
		*) printf '%s\n' "$1" ;;
	esac
}

_sanv() {
	for _sv_n in "$@"; do
		eval "_sv=\$$_sv_n"
		case "$_sv" in
			'') _sv="-" ;;
			*[[:cntrl:]]*) _sv=$(printf '%s' "$_sv" | tr -d '\000-\037') ;;
		esac
		case "$_sv" in
			*\\*|*\"*) _sv=$(printf '%s' "$_sv" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g') ;;
		esac
		eval "_J_$_sv_n=\$_sv"
	done
}

conn_status_line() {
	[ "$CONN_TIME" = "-" ] || return 0
	[ -n "$1" ] || return 0
	logread 2>/dev/null | grep -F "netifd: $1 (" \
		| grep -vE "notify_proto|Command failed|Permission denied" \
		| tail -1 \
		| sed -e 's/.*netifd: '"$1"' ([0-9]*): *//' \
		      -e 's/^[a-zA-Z]*\[[0-9]*\] *//' \
		| tr -d '"\\' | head -c 160
}

_SNAP_PREPARED=""
_snap_prepare() {
	[ -n "$_SNAP_PREPARED" ] && return 0
	_SNAP_PREPARED=1

	_SN_VID=""; _SN_PID=""
	read -r _SN_VID 2>/dev/null < "/sys/bus/usb/devices/$_POLL_AM/idVendor"
	read -r _SN_PID 2>/dev/null < "/sys/bus/usb/devices/$_POLL_AM/idProduct"
	_SN_VIDPID="$_SN_VID:$_SN_PID"
	[ -n "$_SN_VID" ] || [ -z "$_POLL_AM" ] || _SN_VIDPID=$(uci -q get "5gmodem.$_hl_sec.vidpid")

	_SN_IFPROTO=$(uci -q get "network.$SEC.proto")
	_SN_APN=$(uci -q get "network.$SEC.apn")
	case "$_SN_IFPROTO" in
		modemmanager) _SN_PDK="iptype pdptype pdp" ;;
		*) _SN_PDK="pdptype pdp iptype" ;;
	esac
	_SN_PDP=""
	for _SN_K in $_SN_PDK; do
		_SN_PDP=$(uci -q get "network.$SEC.$_SN_K")
		[ -n "$_SN_PDP" ] && break
	done
	[ "$(uci -q get "network.$SEC.allow_roaming")" = "1" ] && _SN_ROAMOK=1 || _SN_ROAMOK=0

	pgrep ModemManager >/dev/null 2>&1 && _SN_MMRUN=1 || _SN_MMRUN=0

	_SN_KIND=$(uci -q get "5gmodem.$_hl_sec.kind")
	[ "$_SN_KIND" = "hilink" ] && _SN_ATDBG=1 || _SN_ATDBG=0
	_SN_ATNAT=0
	[ "$_SN_ATDBG" = 1 ] && [ "$(uci -q get "5gmodem.$_hl_sec.vidpid")" = 05c6:90b4 ] && _SN_ATNAT=1

	_SN_MMX=$(uci -q get "5gmodem.$_hl_sec.mm_exclude")
	case "$_SN_MMX" in
		0|1) _SN_MMHID="$_SN_MMX" ;;
		*) [ "$_SN_IFPROTO" = modemmanager ] && _SN_MMHID=0 || _SN_MMHID=1 ;;
	esac

	_SN_USBENUM=0; _SN_USBFLAP=0
	if [ -n "$_POLL_AM" ]; then
		eval "$(dmesg 2>/dev/null | awk -v p="usb $_POLL_AM:" -v now="$(uptime_s)" '
			index($0, p " new ") { n++ }
			index($0, p " USB disconnect") {
				ts = $0; sub(/^\[[ \t]*/, "", ts); sub(/\..*/, "", ts)
				if (ts + 0 > now - 600) f++
			}
			END { printf "_SN_USBENUM=%d; _SN_USBFLAP=%d", n + 0, f + 0 }')"
	fi

	_SN_XMM=0
	if [ -f /lib/netifd/proto/xmm.sh ] \
	   && uci show 5gmodem 2>/dev/null | grep -qiE "vidpid='(2cb7:0007|8087:095a|413c:81d9)'|\.model='[^']*L8[56]0"; then
		_SN_XMM=1
	fi
}

emit_snapshot() {
_snap_prepare
_SN_CONNST=$(conn_status_line "$SEC")
_SN_ALIAS=$(alias_for_path "$_POLL_AM")
_SN_CPORT="${DEVICE:-$_CPORT_MM}"
[ "$IS_ROAMING" = 1 ] && _SN_ROAM10=1 || _SN_ROAM10=0
COPS=$(operator_clean "$COPS"); HOME_OP=$(operator_clean "$HOME_OP")
_sanv _POLL_AM IPADDR IPADDR6 SEC CONN_TIME CT
_sanv CONN_TIME_SINCE RX TX MODEL _SN_VIDPID TEMP
_sanv THERM ANTPORTS RXDIV FW PROTO _SN_IFPROTO
_sanv _SN_APN _SN_PDP CSQ CSQ_PER COPS HOME_OP
_sanv HOME_MCC HOME_MNC PHONE COPS_MCC COPS_MNC LOC
_sanv MODE REG REG_CS SSIM NR_IMEI NR_IMSI
_sanv NR_ICCID LAC_DEC LAC_HEX TAC_DEC TAC_HEX T_HEX
_sanv T_DEC CID_DEC CID_HEX PCI EARFCN PBAND
_sanv S1BAND S1PCI S1EARFCN S2BAND S2PCI S2EARFCN
_sanv S3BAND S3PCI S3EARFCN S4BAND S4PCI S4EARFCN
_sanv S1STATE S2STATE S3STATE S4STATE S1RSRP S2RSRP
_sanv S3RSRP S4RSRP S1RSRQ S2RSRQ S3RSRQ S4RSRQ
_sanv S1SINR S2SINR S3SINR S4SINR
_sanv S1RSSI S2RSSI S3RSSI S4RSSI RI
_sanv PMIMO PMOD S1MIMO S1MOD S2MIMO S2MOD
_sanv S3MIMO S3MOD S4MIMO S4MOD BANDWIDTH ENBID
_sanv PATHLOSS TXPOWER UECAT CQI VOLTE RSCP
_sanv MAXDL MAXUL AMBRDL AMBRUL QCI
_sanv ECIO RSRP RSRQ RSSI SINR _SN_CONNST
_sanv _SN_ALIAS _SN_CPORT BS_DIST
# no comments inside this heredoc: they would end up in the JSON
cat <<EOF
{
"path":"${_J__POLL_AM}",
"ipaddr":"${_J_IPADDR}",
"ipaddr6":"${_J_IPADDR6}",
"iface":"${_J_SEC}",
"conn_time":"${_J_CONN_TIME}",
"conn_time_sec":"${_J_CT}",
"conn_time_since":"${_J_CONN_TIME_SINCE}",
"conn_status":"${_J__SN_CONNST}",
"rx":"${_J_RX}",
"tx":"${_J_TX}",
"modem":"${_J_MODEL}",
"alias":"${_J__SN_ALIAS}",
"vidpid":"${_J__SN_VIDPID}",
"mtemp":"${_J_TEMP}",
"mtherm":"${_J_THERM}",
"antports":"${_J_ANTPORTS}",
"rxdiv":"${_J_RXDIV}",
"firmware":"${_J_FW}",
"cport":"${_J__SN_CPORT}",
"protocol":"${_J_PROTO}",
"iface_proto":"${_J__SN_IFPROTO}",
"usb_enum":"$_SN_USBENUM",
"usb_flaps":"$_SN_USBFLAP",
"mm_running":"$_SN_MMRUN",
"mm_hidden":"$_SN_MMHID",
"xmm_capable":"$_SN_XMM",
"iface_apn":"${_J__SN_APN}",
"iface_pdptype":"${_J__SN_PDP}",
"csq":"${_J_CSQ}",
"signal":"${_J_CSQ_PER}",
"operator_name":"${_J_COPS}",
"home_operator":"${_J_HOME_OP}",
"home_mcc":"${_J_HOME_MCC}",
"home_mnc":"${_J_HOME_MNC}",
"roaming":"$_SN_ROAM10",
"phone":"${_J_PHONE}",
"operator_mcc":"${_J_COPS_MCC}",
"operator_mnc":"${_J_COPS_MNC}",
"location":"${_J_LOC}",
"mode":"${_J_MODE}",
"registration":"${_J_REG}",
"registration_cs":"${_J_REG_CS}",
"simslot":"${_J_SSIM}",
"allow_roaming":"$_SN_ROAMOK",
"no_at":"$_SN_NOAT",
"imei":"${_J_NR_IMEI}",
"imsi":"${_J_NR_IMSI}",
"iccid":"${_J_NR_ICCID}",
"at_debug":"$_SN_ATDBG",
"at_native":"$_SN_ATNAT",
"lac_dec":"${_J_LAC_DEC}",
"lac_hex":"${_J_LAC_HEX}",
"tac_dec":"${_J_TAC_DEC}",
"tac_hex":"${_J_TAC_HEX}",
"tac_h":"${_J_T_HEX}",
"tac_d":"${_J_T_DEC}",
"cid_dec":"${_J_CID_DEC}",
"cid_hex":"${_J_CID_HEX}",
"pci":"${_J_PCI}",
"earfcn":"${_J_EARFCN}",
"pband":"${_J_PBAND}",
"s1band":"${_J_S1BAND}",
"s1pci":"${_J_S1PCI}",
"s1earfcn":"${_J_S1EARFCN}",
"s2band":"${_J_S2BAND}",
"s2pci":"${_J_S2PCI}",
"s2earfcn":"${_J_S2EARFCN}",
"s3band":"${_J_S3BAND}",
"s3pci":"${_J_S3PCI}",
"s3earfcn":"${_J_S3EARFCN}",
"s4band":"${_J_S4BAND}",
"s4pci":"${_J_S4PCI}",
"s4earfcn":"${_J_S4EARFCN}",
"s1state":"${_J_S1STATE}",
"s2state":"${_J_S2STATE}",
"s3state":"${_J_S3STATE}",
"s4state":"${_J_S4STATE}",
"s1rsrp":"${_J_S1RSRP}",
"s2rsrp":"${_J_S2RSRP}",
"s3rsrp":"${_J_S3RSRP}",
"s4rsrp":"${_J_S4RSRP}",
"s1rsrq":"${_J_S1RSRQ}",
"s2rsrq":"${_J_S2RSRQ}",
"s3rsrq":"${_J_S3RSRQ}",
"s4rsrq":"${_J_S4RSRQ}",
"s1sinr":"${_J_S1SINR}",
"s2sinr":"${_J_S2SINR}",
"s3sinr":"${_J_S3SINR}",
"s4sinr":"${_J_S4SINR}",
"s1rssi":"${_J_S1RSSI}",
"s2rssi":"${_J_S2RSSI}",
"s3rssi":"${_J_S3RSSI}",
"s4rssi":"${_J_S4RSSI}",
"pmimo":"${_J_PMIMO}",
"pmod":"${_J_PMOD}",
"s1mimo":"${_J_S1MIMO}",
"s1mod":"${_J_S1MOD}",
"s2mimo":"${_J_S2MIMO}",
"s2mod":"${_J_S2MOD}",
"s3mimo":"${_J_S3MIMO}",
"s3mod":"${_J_S3MOD}",
"s4mimo":"${_J_S4MIMO}",
"s4mod":"${_J_S4MOD}",
"age":"0",
"bandwidth":"${_J_BANDWIDTH}",
"enbid":"${_J_ENBID}",
"pathloss":"${_J_PATHLOSS}",
"bs_distance":"${_J_BS_DIST}",
"txpower":"${_J_TXPOWER}",
"uecat":"${_J_UECAT}",
"maxdl":"${_J_MAXDL}",
"maxul":"${_J_MAXUL}",
"ambrdl":"${_J_AMBRDL}",
"ambrul":"${_J_AMBRUL}",
"qci":"${_J_QCI}",
"cqi":"${_J_CQI}",
"ri":"${_J_RI}",
"volte":"${_J_VOLTE}",
"rscp":"${_J_RSCP}",
"ecio":"${_J_ECIO}",
"rsrp":"${_J_RSRP}",
"rsrq":"${_J_RSRQ}",
"rssi":"${_J_RSSI}",
"sinr":"${_J_SINR}",
"neighbors":[$NEIGHBORS]
}
EOF
}

if [ ! -s "$CACHE" ] && [ -n "$REG$CSQ" ] && [ -n "$DEVICE" ]; then
	_PTMP="$CACHE.p$$"
	emit_snapshot > "$_PTMP" 2>/dev/null
	if jsonfilter -i "$_PTMP" -e '@.registration' >/dev/null 2>&1; then
		mv "$_PTMP" "$CACHE" && uptime_s > "$STAMP"
	else
		rm -f "$_PTMP"
	fi
	_SNAP_PREPARED=""
fi

_pf_proto=$(uci -q get "network.$SEC.proto")
if { [ "$_pf_proto" = modemmanager ] || [ -n "$_MM_OWNS" ]; } && [ -z "$REG" ] && command -v mmcli >/dev/null 2>&1; then
	_pf_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_POLL_AM" 2>/dev/null)
	if [ -n "$_pf_mi" ]; then
		_pf_k=$(mmcli -m "$_pf_mi" -K 2>/dev/null)
		_pfv() { _v=$(printf '%s\n' "$_pf_k" | grep -F "$1 " | head -1 | sed 's/^[^:]*:[[:space:]]*//'); [ "$_v" = "--" ] && _v=""; printf '%s' "$_v"; }
		case "$(_pfv "modem.3gpp.registration-state")" in
			home) REG=1 ;;
			roaming) REG=5 ;;
		esac
		[ -z "$COPS" ] && COPS=$(_pfv "modem.3gpp.operator-name")
		if [ -z "$DEVICE" ] && [ -z "$_CPORT_MM" ]; then
			_pf_pp=$(_pfv "modem.generic.primary-port")
			[ -n "$_pf_pp" ] && _CPORT_MM="/dev/$_pf_pp"
		fi
		if [ -z "$COPS_NUM" ]; then
			COPS_NUM=$(_pfv "modem.3gpp.operator-code" | tr -dc '0-9')
			if [ -n "$COPS_NUM" ]; then
				COPS_MCC=${COPS_NUM:0:3}
				COPS_MNC=${COPS_NUM:3:3}
			fi
		fi
		case "$COPS" in
			''|*[!0-9\ ]*) : ;;
			*)
				if [ -z "$COPS_NUM" ]; then
					COPS_NUM=$(printf '%s' "$COPS" | awk '
						NF == 2 && length($1) == 3 { print $1 $2; exit }
						NF == 2 && length($2) == 3 { print $2 $1; exit }
						NF == 1 && length($1) >= 5 { print $1; exit }')
					if [ -n "$COPS_NUM" ]; then
						COPS_MCC=${COPS_NUM:0:3}
						COPS_MNC=${COPS_NUM:3:3}
					fi
				fi
				if [ -n "$COPS_NUM" ]; then
					_pf_on=$(awk -F';' '/^'"$COPS_NUM"';/ {print $3; exit}' "$RES/mccmnc.dat" 2>/dev/null | tr -d '\r' | xargs)
					[ -n "$_pf_on" ] && COPS="$_pf_on"
					case "$LOC" in ''|-)
						_pf_lc=$(awk -F';' '/^'"$COPS_NUM"';/ {print $2; exit}' "$RES/mccmnc.dat" 2>/dev/null | tr -d '\r')
						[ -n "$_pf_lc" ] && LOC="$_pf_lc"
						;;
					esac
				fi
				;;
		esac
		_pf_act=$(_pfv "modem.generic.access-technologies.value[1]")
		if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" = "x0" ]; then
			case "$_pf_act" in
				*5gnr*) MODE_NUM=13 ;;
				*lte*)  MODE_NUM=7 ;;
				*umts*|*hsdpa*|*hsupa*|*hspa*) MODE_NUM=2 ;;
			esac
		fi
		if [ "$MODE" = "-" ] || [ -z "$MODE" ]; then
			case "$MODE_NUM" in
				13) MODE="5G NR" ;;
				7)  MODE="LTE" ;;
				2)  MODE="UMTS" ;;
			esac
		fi
	fi
fi

if [ -e /usr/bin/sms_tool ]; then
	REGOK=0
	[ "x$REG" == "x1" ] || [ "x$REG" == "x5" ] || [ "x$REG" == "x6" ] || [ "x$REG" == "x7" ] && REGOK=1
	if [ "$REGOK" = 0 ] && [ -n "$DEVICE" ]; then
		_r5=$(sms_tool -d "$DEVICE" at "AT+C5GREG?" 2>/dev/null | tr -d '\r' \
			| sed -n 's/^+C5GREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
		case "$_r5" in 1|5) REG="$_r5"; REGOK=1 ;; esac
	fi
	if [ -n "$DEVICE" ]; then
		VIDPID=$(getdevicevendorproduct $DEVICE)
	elif soc_modem_node "$_POLL_AM" >/dev/null; then
		VIDPID="soc/$(soc_modem_vidpid | tr -d :)"
	elif [ -r "/sys/bus/usb/devices/$_POLL_AM/idVendor" ]; then
		VIDPID="usb/$(cat "/sys/bus/usb/devices/$_POLL_AM/idVendor")$(cat "/sys/bus/usb/devices/$_POLL_AM/idProduct")"
	else
		VIDPID=""
	fi
	if [ -n "$VIDPID" ] && [ -f "$RES/modem/$VIDPID" ]; then
		_SAVED_IFS="$IFS"
		case $(cat /tmp/sysinfo/board_name) in
			"zte,mf289f")
				. "$RES/modem/usb/19d21485"
				;;
			*)
				. "$RES/modem/$VIDPID"
				;;
		esac
		IFS="$_SAVED_IFS"
	fi
fi

fi

for _ok_v in MODEL FW NR_IMEI NR_IMSI NR_ICCID PHONE; do
	strip_ok_var "$_ok_v"
done

_qmi_refresh() {
	_qr_k="$1"; _qr_w="$2"
	_qr_p="/tmp/5gmodem/qmi_$_qr_k"
	[ -c "$_qr_w" ] || return 0

	_qr_rf=$(qmicli_p "$_qr_w" --nas-get-rf-band-info 2>/dev/null)
	_qr_bw=$(printf '%s\n' "$_qr_rf" | sed -n "s/.*Bandwidth: *'\([0-9]*\)'.*/\1/p" | head -1)
	[ -z "$_qr_bw" ] && _qr_bw=$(printf '%s\n' "$_qr_rf" | sed -n "s/.*Bandwidth: *'wcdma-\([0-9]*\)'.*/\1/p" | head -1)
	[ -n "$_qr_bw" ] && _qr_bw="$_qr_bw MHz"
	_qr_b3=$(printf '%s\n' "$_qr_rf" | sed -n "s/.*Active Band Class: *'\(wcdma-[a-z0-9-]*\)'.*/\1/p" | head -1)
	_qr_u3=""
	[ -n "$_qr_b3" ] && _qr_u3=$(printf '%s\n' "$_qr_rf" | sed -n "s/.*Active Channel: *'\([0-9]*\)'.*/\1/p" | head -1)
	_qr_txraw=$(qmicli_p "$_qr_w" --nas-get-tx-rx-info=lte 2>/dev/null)
	_qr_tx=$(printf '%s\n' "$_qr_txraw" \
		| awk '/^TX:/{f=1} f && /Power:/ {gsub(/[^0-9.-]/,"",$2); print $2; exit}')
	_qr_ant=$(printf '%s\n' "$_qr_txraw" | awk '
		/^RX Chain/ { if (t == "yes" && r != "") emit(); n = 0 + substr($3, 1, 1); t = ""; r = ""; q = "" }
		/Radio tuned:/ { t = ($0 ~ /yes/) ? "yes" : "" }
		/RSRP:/ { gsub(/[^0-9.-]/, "", $2); r = $2; if (r + 0 > 0) r = -r }
		/ECIO:/ { gsub(/[^0-9.-]/, "", $2); q = $2; if (q + 0 > 0) q = -q }
		function emit() { if (r + 0 > -160 && r + 0 < -20) { out = out (out == "" ? "" : " ") n ":" r ":" q; ok++ } }
		END { if (t == "yes" && r != "") emit(); printf "%s", out }
	')
	_qr_rxd=""
	_qr_an=$(printf '%s' "$_qr_ant" | wc -w)
	_qr_live=$(printf '%s' "$_qr_ant" | tr ' ' '\n' | awk -F: '$2 + 0 > -130' | wc -l)
	case "$_qr_an:$_qr_live" in
		*:2)       _qr_rxd="2rx" ;;
		*:3|*:4)   _qr_rxd="4rx" ;;
		[2-4]:1)   _qr_rxd="noant" ;;
	esac
	[ -n "$_qr_tx" ] && _qr_tx="$_qr_tx dBm"

	_qr_si=$(qmicli_p "$_qr_w" --nas-get-signal-info 2>/dev/null)
	_qr_sig=$(printf '%s\n' "$_qr_si" | awk '
		/^LTE:/ { f=1; next }
		/^[A-Z0-9]+:/ { f=0 }
		f && /RSSI:/ { if (match($0, /-?[0-9.]+/)) rssi = substr($0, RSTART, RLENGTH) }
		f && /RSRQ:/ { if (match($0, /-?[0-9.]+/)) rsrq = substr($0, RSTART, RLENGTH) }
		f && /RSRP:/ { if (match($0, /-?[0-9.]+/)) rsrp = substr($0, RSTART, RLENGTH) }
		f && /SNR:/  { if (match($0, /-?[0-9.]+/)) snr  = substr($0, RSTART, RLENGTH) }
		END { if (rsrp != "" || rssi != "") printf "%s|%s|%s|%s", rssi, rsrq, rsrp, snr }
	')
	_qr_lte=$(printf '%s\n' "$_qr_rf" | awk "
		/Active Band Class: *'eutran-/ { if (match(\$0, /eutran-[0-9]+/)) b = substr(\$0, RSTART + 7, RLENGTH - 7) }
		/Active Channel:/ { if (b != \"\" && c == \"\") { if (match(\$0, /[0-9]+/)) c = substr(\$0, RSTART, RLENGTH) } }
		END { if (b != \"\") printf \"%s|%s\", b, c }
	")
	_qr_cai=$(qmicli_p "$_qr_w" --nas-get-lte-cphy-ca-info 2>/dev/null)
	_qr_ca=$(printf '%s\n' "$_qr_cai" | awk '
		function flushs() {
			if (m == "P" && b != "") out = b "," ch
			else if (m == "S" && b != "" && st == "a") out = out "|" b "," ch
			b = ""; ch = ""; st = ""
		}
		/^Primary Cell Info/  { flushs(); m = "P"; next }
		/^Secondary Cell/     { flushs(); m = "S"; next }
		/RX Channel:/  { if (match($0, /[0-9]+/)) ch = substr($0, RSTART, RLENGTH); next }
		/LTE Band:/    { if (match($0, /eutran-[0-9]+/)) b = substr($0, RSTART + 7, RLENGTH - 7); next }
		/State:/       { if ($0 ~ /\047activated/) st = "a"; next }
		END { flushs(); printf "%s", out }
	')
	_qr_cl=$(qmicli_p "$_qr_w" --nas-get-cell-location-info 2>/dev/null)
	_qr_ta=$(printf '%s\n' "$_qr_cl" | sed -n "s/.*LTE Timing Advance: *'\([0-9]*\)'.*/\1/p" | head -1)
	_qr_dist=""
	[ -n "$_qr_ta" ] && _qr_dist=$((_qr_ta * 150))
	_qr_cell=$(printf '%s\n' "$_qr_cl" | awk '
		/^Intrafrequency LTE Info/ { f=1; next }
		/^[^ \t]/ { f=0 }
		f && /Tracking Area Code:/ { if (match($0, /[0-9]+/)) tac = substr($0, RSTART, RLENGTH) }
		f && /Global Cell ID:/     { if (match($0, /[0-9]+/)) cid = substr($0, RSTART, RLENGTH) }
		END { if (tac != "" || cid != "") printf "%s|%s", tac, cid }
	')
	_qr_3g=$(printf '%s\n' "$_qr_cl" | awk '
		/^UMTS Info/ { f=1; next }
		/^[^ \t]/    { f=0 }
		f && /Location Area Code:/    { if (match($0, /[0-9]+/)) lac = substr($0, RSTART, RLENGTH) }
		f && /Primary Scrambling Code:/ { if (match($0, /[0-9]+/)) psc = substr($0, RSTART, RLENGTH) }
		f && /RSCP:/ { if (match($0, /-?[0-9.]+/)) rscp = substr($0, RSTART, RLENGTH) }
		f && /ECIO:/ { if (match($0, /-?[0-9.]+/)) ecio = substr($0, RSTART, RLENGTH) }
		END { if (rscp != "" || psc != "") printf "%s|%s|%s|%s", rscp, ecio, psc, lac }
	')
	_qr_nb=$(printf '%s\n' "$_qr_cl" | awk '
		function emit() {
			if (pci == "") return
			printf "%s{\"band\":\"%s\",\"earfcn\":\"%s\",\"pci\":\"%s\",\"rsrp\":\"%s\",\"rsrq\":\"%s\",\"rssi\":\"%s\",\"serving\":%s}",
				(n++ ? "," : ""), band, earfcn, pci, rsrp, rsrq, rssi,
				((sec == "intra" && pci == serv) ? "1" : "0")
			pci = ""
		}
		/^Intrafrequency LTE Info/ { emit(); sec = "intra"; next }
		/^Interfrequency LTE Info/ { emit(); sec = "inter"; next }
		/^[^ \t]/               { emit(); sec = "" }
		sec == ""               { next }
		/EUTRA Absolute RF Channel Number/ {
			emit()
			if (match($0, /[0-9]+/)) earfcn = substr($0, RSTART, RLENGTH)
			band = ""
			if (match($0, /E-UTRA band [0-9]+/)) band = substr($0, RSTART + 12, RLENGTH - 12)
			next
		}
		/Serving Cell ID/  { if (match($0, /[0-9]+/)) serv = substr($0, RSTART, RLENGTH); next }
		/Physical Cell ID/ {
			emit()
			if (match($0, /[0-9]+/)) pci = substr($0, RSTART, RLENGTH)
			rsrp = ""; rsrq = ""; rssi = ""
			next
		}
		/RSRQ:/ { if (match($0, /-?[0-9.]+/)) rsrq = substr($0, RSTART, RLENGTH); next }
		/RSRP:/ { if (match($0, /-?[0-9.]+/)) rsrp = substr($0, RSTART, RLENGTH); next }
		/RSSI:/ { if (match($0, /-?[0-9.]+/)) rssi = substr($0, RSTART, RLENGTH); next }
		END { emit() }
	')

	printf '%s' "$_qr_ca" > "$_qr_p.ca.tmp" && mv "$_qr_p.ca.tmp" "$_qr_p.ca"
	printf '%s' "$_qr_nb" > "$_qr_p.nb.tmp" && mv "$_qr_p.nb.tmp" "$_qr_p.nb"
	printf '%s' "$_qr_bw" > "$_qr_p.bw.tmp" && mv "$_qr_p.bw.tmp" "$_qr_p.bw"
	printf '%s' "$_qr_tx" > "$_qr_p.tx.tmp" && mv "$_qr_p.tx.tmp" "$_qr_p.tx"
	printf '%s' "$_qr_ant" > "$_qr_p.ant.tmp" && mv "$_qr_p.ant.tmp" "$_qr_p.ant"
	printf '%s' "$_qr_rxd" > "$_qr_p.rxd.tmp" && mv "$_qr_p.rxd.tmp" "$_qr_p.rxd"
	printf '%s' "$_qr_b3" > "$_qr_p.b3g.tmp" && mv "$_qr_p.b3g.tmp" "$_qr_p.b3g"
	printf '%s' "$_qr_u3" > "$_qr_p.u3g.tmp" && mv "$_qr_p.u3g.tmp" "$_qr_p.u3g"
	printf '%s' "$_qr_3g" > "$_qr_p.c3g.tmp" && mv "$_qr_p.c3g.tmp" "$_qr_p.c3g"
	printf '%s' "$_qr_sig" > "$_qr_p.sig.tmp" && mv "$_qr_p.sig.tmp" "$_qr_p.sig"
	printf '%s' "$_qr_lte" > "$_qr_p.lte.tmp" && mv "$_qr_p.lte.tmp" "$_qr_p.lte"
	printf '%s' "$_qr_cell" > "$_qr_p.cell.tmp" && mv "$_qr_p.cell.tmp" "$_qr_p.cell"
	printf '%s' "$_qr_dist" > "$_qr_p.dist.tmp" && mv "$_qr_p.dist.tmp" "$_qr_p.dist"
	cut -d. -f1 /proc/uptime > "$_qr_p.t.tmp" && mv "$_qr_p.t.tmp" "$_qr_p.t"
}

_ATCA_TTL=20
_ATCA_NEG=600
_at_ca_supplement() {
	[ -n "$_CA_FROM_PROFILE" ] && return 0
	case "$S1BAND" in ''|-) : ;; *) return 0 ;; esac
	[ -n "$DEVICE" ] && [ -c "$DEVICE" ] || return 0
	[ "$REGOK" = "1" ] || return 0
	case "$MODE" in
		*GSM*|*GPRS*|*EDGE*|*UMTS*|*WCDMA*|*HSPA*|*HSDPA*|*HSUPA*|*2G*|*3G*) return 0 ;;
	esac
	_ac_p="/tmp/5gmodem/atca_$_MKEY"
	_ac_now=$(uptime_s)
	_ac_ts=$(cat "$_ac_p.t" 2>/dev/null)
	case "$_ac_ts" in ''|*[!0-9]*) _ac_ts=0 ;; esac
	if [ "$(( _ac_now - _ac_ts ))" -lt "$_ATCA_TTL" ]; then
		_ac_l=$(cat "$_ac_p" 2>/dev/null)
	else
		_ac_ng=$(cat "$_ac_p.no" 2>/dev/null)
		case "$_ac_ng" in ''|*[!0-9]*) _ac_ng="" ;; esac
		if [ -n "$_ac_ng" ] && [ "$(( _ac_now - _ac_ng ))" -lt "$_ATCA_NEG" ]; then
			return 0
		fi
		_ac_o=$(sms_tool -d "$DEVICE" at "AT^CA_INFO?" 2>/dev/null)
		case "$_ac_o" in
			*"Band is"*)
				_ac_l=$(printf '%s\n' "$_ac_o" | awk '
					/Band is/ {
						if (!match($0, /Band is [A-Za-z0-9_]+/)) next
						t = substr($0, RSTART + 8, RLENGTH - 8)
						bw = ""
						if (match($0, /Band_width is [0-9.]+/)) bw = substr($0, RSTART + 14, RLENGTH - 14)
						printf "%s%s,%s", (n++ ? " " : ""), t, bw
					}
				')
				;;
			*)
				_ac_o=$(sms_tool -d "$DEVICE" at "AT#CAINFOEXT?" 2>/dev/null)
				case "$_ac_o" in
					*BandClass:*) : ;;
					*) printf '%s' "$_ac_now" > "$_ac_p.no" 2>/dev/null; return 0 ;;
				esac
				_ac_l=$(printf '%s\n' "$_ac_o" | awk '
					function eband(c) {
						if (c <= 0) return 0
						if (c <= 599) return 1
						if (c <= 1199) return 2
						if (c <= 1949) return 3
						if (c <= 2399) return 4
						if (c <= 2649) return 5
						if (c <= 2749) return 6
						if (c <= 3449) return 7
						if (c <= 3799) return 8
						if (c <= 4149) return 9
						if (c <= 4749) return 10
						if (c <= 4949) return 11
						if (c >= 5010 && c <= 5179) return 12
						if (c >= 5180 && c <= 5279) return 13
						if (c >= 5280 && c <= 5379) return 14
						if (c >= 5730 && c <= 5849) return 17
						if (c >= 5850 && c <= 5999) return 18
						if (c >= 6000 && c <= 6149) return 19
						if (c >= 6150 && c <= 6449) return 20
						if (c >= 6450 && c <= 6599) return 21
						if (c >= 6600 && c <= 7399) return 22
						if (c >= 7500 && c <= 7699) return 23
						if (c >= 7700 && c <= 8039) return 24
						if (c >= 8040 && c <= 8689) return 25
						if (c >= 8690 && c <= 9039) return 26
						if (c >= 9040 && c <= 9209) return 27
						if (c >= 9210 && c <= 9659) return 28
						if (c >= 9660 && c <= 9769) return 29
						if (c >= 9770 && c <= 9869) return 30
						if (c >= 9870 && c <= 9919) return 31
						if (c >= 9920 && c <= 10359) return 32
						if (c >= 36000 && c <= 36199) return 33
						if (c >= 36200 && c <= 36349) return 34
						if (c >= 36350 && c <= 36949) return 35
						if (c >= 36950 && c <= 37549) return 36
						if (c >= 37550 && c <= 37749) return 37
						if (c >= 37750 && c <= 38249) return 38
						if (c >= 38250 && c <= 38649) return 39
						if (c >= 38650 && c <= 39649) return 40
						if (c >= 39650 && c <= 41589) return 41
						if (c >= 41590 && c <= 43589) return 42
						if (c >= 43590 && c <= 45589) return 43
						if (c >= 45590 && c <= 46589) return 44
						if (c >= 46590 && c <= 46789) return 45
						if (c >= 46790 && c <= 54539) return 46
						if (c >= 54540 && c <= 55239) return 47
						if (c >= 55240 && c <= 56739) return 48
						if (c >= 66436 && c <= 67335) return 66
						if (c >= 67536 && c <= 67835) return 67
						if (c >= 67836 && c <= 68335) return 68
						if (c >= 68586 && c <= 68935) return 71
						return 0
					}
					function ebw(v) {
						if (v == 0) return "1.4"
						if (v == 1) return "3"
						if (v == 2) return "5"
						if (v == 3) return "10"
						if (v == 4) return "15"
						if (v == 5) return "20"
						return ""
					}
					/^#CAINFOEXT:/ { rat = ($0 ~ /LTE/) ? "LTE" : ""; next }
					rat == "LTE" && /BandClass:/ {
						if ($0 ~ /^[ ]*SCC/ && match($0, /STATE:[ ]*[0-9]+/) && substr($0, RSTART + 6, RLENGTH - 6) + 0 != 2) next
						if (!match($0, /BandClass:[ ]*[0-9]+/)) next
						bc = substr($0, RSTART + 10, RLENGTH - 10) + 0
						ch = 0
						if (match($0, /RX_CH:[ ]*[0-9]+/)) ch = substr($0, RSTART + 6, RLENGTH - 6) + 0
						b = eband(ch)
						if (b == 0) b = bc - 119
						if (b <= 0) next
						bw = ""
						if (match($0, /DL_BW:[ ]*[0-9]+/)) bw = ebw(substr($0, RSTART + 6, RLENGTH - 6) + 0)
						printf "%sLTE_B%d,%s", (n++ ? " " : ""), b, bw
					}
				')
				;;
		esac
		[ -n "$_ac_l" ] || { printf '%s' "$_ac_now" > "$_ac_p.no" 2>/dev/null; return 0; }
		rm -f "$_ac_p.no" 2>/dev/null
		printf '%s' "$_ac_l" > "$_ac_p" 2>/dev/null
		printf '%s' "$_ac_now" > "$_ac_p.t" 2>/dev/null
	fi
	[ -n "$_ac_l" ] || return 0
	_ac_i=0
	for _ac_c in $_ac_l; do
		_ac_t="${_ac_c%%,*}"
		_ac_bw="${_ac_c#*,}"
		case "$_ac_bw" in *.0) _ac_bw="${_ac_bw%.0}" ;; esac
		_ac_b=""
		case "$_ac_t" in
			LTE_B[0-9]*)  _ac_b=$(band4g "${_ac_t#LTE_B}") ;;
			NR5G_N[0-9]*) _ac_b=$(band5g "${_ac_t#NR5G_N}") ;;
			NR_N[0-9]*)   _ac_b=$(band5g "${_ac_t#NR_N}") ;;
		esac
		[ -n "$_ac_b" ] || continue
		[ -n "$_ac_bw" ] && _ac_b="$_ac_b @$_ac_bw MHz"
		if [ "$_ac_i" = 0 ]; then
			case "$PBAND" in ''|-) PBAND="$_ac_b" ;; esac
		else
			case "$_ac_i" in
				1) case "$S1BAND" in ''|-) S1BAND="$_ac_b"; S1STATE="activated" ;; esac ;;
				2) case "$S2BAND" in ''|-) S2BAND="$_ac_b"; S2STATE="activated" ;; esac ;;
				3) case "$S3BAND" in ''|-) S3BAND="$_ac_b"; S3STATE="activated" ;; esac ;;
				4) case "$S4BAND" in ''|-) S4BAND="$_ac_b"; S4STATE="activated" ;; esac ;;
			esac
		fi
		_ac_i=$((_ac_i + 1))
	done
	return 0
}

_poll_chan_free() {
	[ -n "$_POLL_AM" ] || return 0
	[ "$_POLL_AM" = "$(_active_path)" ] && return 0
	_pcf_if=$(uci -q get "5gmodem.$_hl_sec.network" 2>/dev/null)
	[ -n "$_pcf_if" ] || return 0
	proto_in direct "$(uci -q get "network.$_pcf_if.proto" 2>/dev/null)" || return 0
	case "$(ubus call "network.interface.$_pcf_if" status 2>/dev/null)" in
		*'"up": true'*|*'"pending": true'*) return 1 ;;
	esac
	_pcf_dev=$(uci -q get "network.$_pcf_if.device" 2>/dev/null)
	[ -n "$_pcf_dev" ] || return 0
	pgrep -f "uqmi .*$_pcf_dev" >/dev/null 2>&1 && return 1
	pgrep -f "umbim .*$_pcf_dev" >/dev/null 2>&1 && return 1
	return 0
}

_QS_TTL=25
_QS_STALE=300
_qmi_supplement() {
	command -v qmicli >/dev/null 2>&1 || return 0
	_QS_WDM=""
	if [ -n "$_POLL_AM" ]; then
		[ -n "$_own_rec" ] || _own_rec=$("$RES/listmodems.sh" 2>/dev/null)
		for _qs_w in $(printf '%s' "$_own_rec" | jsonfilter -e "@[@.path=\"$_POLL_AM\"].wdm[*]" 2>/dev/null); do
			case "$_qs_w" in /dev/wwan*at*) continue ;; esac
			_QS_WDM="$_qs_w"; break
		done
	fi
	[ -c "$_QS_WDM" ] || return 0

	qmi_channel_free || return 0
	_poll_chan_free || return 0
	_QS_P="/tmp/5gmodem/qmi_$_MKEY"

	if [ -z "$MAXDL" ]; then
		_QS_IM=$(uci -q get "5gmodem.$_hl_sec.imei" 2>/dev/null | tr -cd '0-9')
		if [ -n "$_QS_IM" ]; then
			_QS_MR="/tmp/5gmodem/maxrate_$_QS_IM"
			if [ -s "$_QS_MR" ]; then
				read -r MAXDL MAXUL < "$_QS_MR"
			else
				_QS_RT=$(qmicli_p "$_QS_WDM" --wds-get-channel-rates 2>/dev/null | awk '
					/Max (TX|RX) rate:/ {
						v = $NF; sub(/bps$/, "", v); v += 0
						if (v <= 0) next
						if (v > hi) { lo = hi; hi = v } else if (v > lo) lo = v
					}
					END { if (hi > 0 && lo > 0) printf "%.0f %.0f", hi / 1000000, lo / 1000000 }')
				case "$_QS_RT" in
					[0-9]*' '[0-9]*)
						MAXDL="${_QS_RT%% *}"; MAXUL="${_QS_RT##* }"
						printf '%s %s\n' "$MAXDL" "$MAXUL" > "$_QS_MR" 2>/dev/null ;;
				esac
			fi
		fi
	fi

	_QS_MT=$(cat "$_QS_P.t" 2>/dev/null)
	case "$_QS_MT" in ''|*[!0-9]*) _QS_MT=0 ;; esac
	_QS_AGE=$(( $(uptime_s) - _QS_MT ))
	if [ "$_QS_AGE" -ge 0 ] && [ "$_QS_AGE" -lt "$_QS_STALE" ]; then
		_qmi_fill
	fi
	_qmi_kick
}

_qmi_fill() {
	case "$MODE" in
		UMTS*|WCDMA*|HSDPA*|HSUPA*|HSPA*|3G*) : ;;
		*)
			if [ -s "$_QS_P.b3g" ]; then
				: > "$_QS_P.b3g"; : > "$_QS_P.u3g"; : > "$_QS_P.bw"; : > "$_QS_P.c3g"
				rm -f "$_QS_P.t" 2>/dev/null
			fi ;;
	esac

	[ -z "$NEIGHBORS" ] && [ -s "$_QS_P.nb" ] && NEIGHBORS=$(cat "$_QS_P.nb")
	[ -z "$ANTPORTS" ] && [ -s "$_QS_P.ant" ] && ANTPORTS=$(cat "$_QS_P.ant")
	[ -z "$RXDIV" ] && [ -s "$_QS_P.rxd" ] && RXDIV=$(cat "$_QS_P.rxd")
	if [ -s "$_QS_P.ca" ]; then
		_qs_ca=$(cat "$_QS_P.ca")
		case "$_qs_ca" in
			[0-9]*) : ;;
			*) _qs_ca="" ;;
		esac
		_qs_i=0
		IFS='|'
		for _qs_cc in $_qs_ca; do
			_qs_b="${_qs_cc%%,*}"; _qs_c="${_qs_cc#*,}"
			_qs_eb=$(earfcn2band "$_qs_c")
			[ -n "$_qs_eb" ] && _qs_b="$_qs_eb"
			[ -n "$_qs_b" ] || continue
			if [ "$_qs_i" = 0 ]; then
				case "$PBAND" in ''|-) PBAND="B$_qs_b" ;; esac
				case "$EARFCN" in ''|-|0) EARFCN="$_qs_c" ;; esac
			else
				case "$_qs_i" in
					1) case "$S1BAND" in ''|-) S1BAND="B$_qs_b"; S1EARFCN="$_qs_c" ;; esac ;;
					2) case "$S2BAND" in ''|-) S2BAND="B$_qs_b"; S2EARFCN="$_qs_c" ;; esac ;;
					3) case "$S3BAND" in ''|-) S3BAND="B$_qs_b"; S3EARFCN="$_qs_c" ;; esac ;;
					4) case "$S4BAND" in ''|-) S4BAND="B$_qs_b"; S4EARFCN="$_qs_c" ;; esac ;;
				esac
			fi
			_qs_i=$((_qs_i + 1))
		done
		unset IFS
	fi
	case "$PCI" in ''|-)
		[ -n "$NEIGHBORS" ] && PCI=$(printf '%s' "$NEIGHBORS" \
			| sed -n 's/.*"pci":"\([0-9]*\)"[^}]*"serving":1.*/\1/p' | head -1)
		;;
	esac
	if [ -n "$NEIGHBORS" ]; then
		for _sc_i in 1 2 3 4; do
			eval _sc_pci=\$S${_sc_i}PCI
			eval _sc_ear=\$S${_sc_i}EARFCN
			eval _sc_rsrp=\$S${_sc_i}RSRP
			[ -n "$_sc_pci" ] && [ -n "$_sc_ear" ] || continue
			case "$_sc_rsrp" in ''|-) : ;; *) continue ;; esac
			_sc_rec=$(printf '%s' "$NEIGHBORS" | tr '}' '\n' \
				| grep "\"earfcn\":\"$_sc_ear\"" | grep "\"pci\":\"$_sc_pci\"" | head -1)
			[ -n "$_sc_rec" ] || continue
			_sc_p=$(printf '%s' "$_sc_rec" | sed -n 's/.*"rsrp":"\([^"]*\)".*/\1/p')
			_sc_q=$(printf '%s' "$_sc_rec" | sed -n 's/.*"rsrq":"\([^"]*\)".*/\1/p')
			[ -n "$_sc_p" ] && eval S${_sc_i}RSRP=\$_sc_p
			[ -n "$_sc_q" ] && eval S${_sc_i}RSRQ=\$_sc_q
		done
	fi
	if [ -s "$_QS_P.sig" ]; then
		_QS_S=$(cat "$_QS_P.sig")
		_s_rssi=${_QS_S%%|*}; _s_r=${_QS_S#*|}
		_s_rsrq=${_s_r%%|*};  _s_r=${_s_r#*|}
		_s_rsrp=${_s_r%%|*};  _s_snr=${_s_r##*|}
		case "$RSSI" in ''|-) [ -n "$_s_rssi" ] && RSSI="$_s_rssi" ;; esac
		case "$RSRQ" in ''|-) [ -n "$_s_rsrq" ] && RSRQ="$_s_rsrq" ;; esac
		case "$RSRP" in ''|-) [ -n "$_s_rsrp" ] && RSRP="$_s_rsrp" ;; esac
		case "$SINR" in ''|-) [ -n "$_s_snr" ] && SINR="$_s_snr" ;; esac
		# QMI SINR overrides the AT value on purpose, see docs/subsystems/polling.md#qmi-supplement
		[ -n "$_s_snr" ] && SINR="$_s_snr"
	fi
	if [ -s "$_QS_P.lte" ]; then
		_QS_L=$(cat "$_QS_P.lte")
		_l_band=${_QS_L%%|*}; _l_earfcn=${_QS_L##*|}
		_l_eb=$(earfcn2band "$_l_earfcn")
		[ -n "$_l_eb" ] && _l_band="$_l_eb"
		case "$PBAND" in ''|-)
			[ -n "$_l_band" ] && PBAND=$(band4g "$_l_band")
			;;
		esac
		case "$EARFCN" in ''|-|0) [ -n "$_l_earfcn" ] && EARFCN="$_l_earfcn" ;; esac
		case "$MODE" in
			LTE|LTE-A|4G) [ -n "$PBAND" ] && MODE="$MODE | $PBAND" ;;
		esac
	fi
	if [ -s "$_QS_P.cell" ]; then
		_QS_C=$(cat "$_QS_P.cell")
		_c_tac=${_QS_C%%|*}; _c_cid=${_QS_C##*|}
		case "$TAC_DEC" in ''|-)
			if [ -n "$_c_tac" ]; then
				TAC_DEC="$_c_tac"; TAC_HEX=$(printf '%X' "$_c_tac" 2>/dev/null)
			fi ;;
		esac
		case "$CID_DEC" in ''|-|0)
			if [ -n "$_c_cid" ]; then
				CID_DEC="$_c_cid"; CID_HEX=$(printf '%X' "$_c_cid" 2>/dev/null)
			fi ;;
		esac
	fi
	case "$BANDWIDTH" in ''|-) [ -s "$_QS_P.bw" ] && BANDWIDTH=$(cat "$_QS_P.bw") ;; esac
	case "$TXPOWER"  in ''|-) [ -s "$_QS_P.tx" ] && TXPOWER=$(cat "$_QS_P.tx") ;; esac
	[ -s "$_QS_P.dist" ] && BS_DIST=$(cat "$_QS_P.dist")
	case "$MODE" in
		UMTS*|WCDMA*|HSDPA*|HSUPA*|HSPA*|3G*)
			_QS_B3C=$(cat "$_QS_P.b3g" 2>/dev/null)
			_QS_U3C=$(cat "$_QS_P.u3g" 2>/dev/null)
			if [ -z "$_QS_B3C" ] && qmi_channel_free; then
				_QS_RF=$(qmicli_p "$_QS_WDM" --nas-get-rf-band-info 2>/dev/null)
				_QS_B3C=$(printf '%s\n' "$_QS_RF" | sed -n "s/.*Active Band Class: *'\(wcdma-[a-z0-9-]*\)'.*/\1/p" | head -1)
				if [ -n "$_QS_B3C" ]; then
					_QS_U3C=$(printf '%s\n' "$_QS_RF" | sed -n "s/.*Active Channel: *'\([0-9]*\)'.*/\1/p" | head -1)
					_QS_BW3=$(printf '%s\n' "$_QS_RF" | sed -n "s/.*Bandwidth: *'wcdma-\([0-9]*\)'.*/\1 MHz/p" | head -1)
					[ -n "$_QS_BW3" ] && BANDWIDTH="$_QS_BW3"
					printf '%s' "$_QS_B3C" > "$_QS_P.b3g" 2>/dev/null
					printf '%s' "$_QS_U3C" > "$_QS_P.u3g" 2>/dev/null
					[ -n "$_QS_BW3" ] && printf '%s' "$_QS_BW3" > "$_QS_P.bw" 2>/dev/null
				fi
			fi
			if [ -n "$_QS_B3C" ]; then
				_QS_B3=$(band3g "$_QS_B3C")
				if [ -n "$_QS_B3" ]; then
					case "$PBAND" in ''|-) PBAND="$_QS_B3" ;; esac
					case "$MODE" in *"|"*) : ;; *) MODE="$MODE | $_QS_B3" ;; esac
				fi
			fi
			case "$EARFCN" in ''|-) [ -n "$_QS_U3C" ] && EARFCN="$_QS_U3C" ;; esac
			_QS_C3=$(cat "$_QS_P.c3g" 2>/dev/null)
			if [ -z "$_QS_C3" ] && [ -n "$_QS_B3C" ]; then
				_QS_C3=$(qmicli_p "$_QS_WDM" --nas-get-cell-location-info 2>/dev/null | awk '
					/^UMTS Info/ { f=1; next }
					/^[^ \t]/    { f=0 }
					f && /Location Area Code:/      { if (match($0, /[0-9]+/)) lac = substr($0, RSTART, RLENGTH) }
					f && /Primary Scrambling Code:/ { if (match($0, /[0-9]+/)) psc = substr($0, RSTART, RLENGTH) }
					f && /RSCP:/ { if (match($0, /-?[0-9.]+/)) rscp = substr($0, RSTART, RLENGTH) }
					f && /ECIO:/ { if (match($0, /-?[0-9.]+/)) ecio = substr($0, RSTART, RLENGTH) }
					END { if (rscp != "" || psc != "") printf "%s|%s|%s|%s", rscp, ecio, psc, lac }
				')
				[ -n "$_QS_C3" ] && printf '%s' "$_QS_C3" > "$_QS_P.c3g" 2>/dev/null
			fi
			if [ -n "$_QS_C3" ]; then
				_c3_rscp=${_QS_C3%%|*}; _c3_r=${_QS_C3#*|}
				_c3_ecio=${_c3_r%%|*};  _c3_r=${_c3_r#*|}
				_c3_psc=${_c3_r%%|*};   _c3_lac=${_c3_r##*|}
				case "$RSCP" in ''|-) [ -n "$_c3_rscp" ] && RSCP="$_c3_rscp" ;; esac
				case "$ECIO" in ''|-) [ -n "$_c3_ecio" ] && ECIO="$_c3_ecio" ;; esac
				case "$PCI"  in ''|-) [ -n "$_c3_psc" ] && PCI="$_c3_psc" ;; esac
				case "$LAC_DEC" in ''|-)
					if [ -n "$_c3_lac" ]; then
						LAC_DEC="$_c3_lac"
						LAC_HEX=$(printf '%X' "$_c3_lac" 2>/dev/null)
					fi ;;
				esac
				case "$RSSI" in ''|-) [ -n "$_c3_rscp" ] && RSSI="$_c3_rscp" ;; esac
			fi
			;;
	esac

	return 0
}

_qmi_kick() {
	_QS_MT=$(cat "$_QS_P.t" 2>/dev/null)
	case "$_QS_MT" in ''|*[!0-9]*) _QS_MT=0 ;; esac
	_QS_NOW=$(uptime_s)
	[ "$(( _QS_NOW - _QS_MT ))" -lt "$_QS_TTL" ] && return 0

	_QS_LS=$(cat "$_QS_P.q" 2>/dev/null)
	case "$_QS_LS" in ''|*[!0-9]*) _QS_LS=0 ;; esac
	[ "$(( _QS_NOW - _QS_LS ))" -lt 5 ] && return 0
	echo "$_QS_NOW" > "$_QS_P.q"

	( _qmi_refresh "$_MKEY" "$_QS_WDM" >/dev/null 2>&1 </dev/null 8>&- 9>&- & ) >/dev/null 2>&1
	return 0
}

case "$ENBID" in
	''|-)
		case "$MODE" in
			*LTE*|*5G*)
				case "$CID_DEC" in
					''|0|*[!0-9]*) ;;
					*) [ "$CID_DEC" -gt 255 ] && ENBID=$((CID_DEC / 256)) ;;
				esac
				;;
		esac
		;;
esac

_qmi_supplement
_at_ca_supplement

# second pass: under ModemManager the CID only arrives from _qmi_supplement
case "$ENBID" in
	''|-)
		case "$MODE" in
			*LTE*|*5G*)
				case "$CID_DEC" in
					''|*[!0-9]*) ;;
					*) [ "$CID_DEC" -gt 255 ] && ENBID=$((CID_DEC / 256)) ;;
				esac
				;;
		esac
		;;
esac

if [ "$SEC" = "$_SECST_FOR" ]; then
	IFSTAT="$SECSTATUS"
else
	IFSTAT=$(ifstatus "$SEC" 2>/dev/null)
fi
L3DEV=$(echo "$IFSTAT" | awk -F\" '/l3_device/ {print $4; exit}')
IPADDR=""
IPADDR6=""
if [ -n "$L3DEV" ]; then
	IPADDR=$(ip -4 addr show dev "$L3DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
	IPADDR6=$(ip -6 addr show dev "$L3DEV" scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
fi
[ -z "$IPADDR" ]  && IPADDR=$(echo "$IFSTAT" | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR" ]  && IPADDR=$(ifstatus "${SEC}_4" 2>/dev/null | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(echo "$IFSTAT" | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(ifstatus "${SEC}_6" 2>/dev/null | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)

if [ "$(uci -q get "5gmodem.$_hl_sec.kind")" = "hilink" ] && [ -n "$DEVICE" ]; then
	_wan=$(sms_tool -d "$DEVICE" at "AT+CGPADDR" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CGPADDR: *[0-9]*, *//p' | tr ',' '\n' | tr -d '" ' | grep -E '^[0-9]{1,3}([.][0-9]{1,3}){3}$' | grep -v '^0\.0\.0\.0$' | head -1)
	[ -n "$_wan" ] && IPADDR="$_wan"
fi

IFPROTO=$(uci -q get "network.$SEC.proto")
[ -n "$IFPROTO" ] && PROTO="$IFPROTO"

VISITED_COPS="$COPS"
HOME_MCC=""; HOME_MNC=""; HOME_OP=""
if [ -n "$SIMID" ] && [ "${#SIMID}" -ge 5 ]; then
	HOME_MCC="${SIMID:0:3}"
	_hm3="${SIMID:3:3}"
	_hm2="${SIMID:3:2}"
	_hm_r=$(awk -F';' -v a="${HOME_MCC}${_hm3}" -v b="${HOME_MCC}${_hm2}" '
		$1 "" == a "" && !fa { fa = 1; na = $3 }
		$1 "" == b "" && !fb { fb = 1; nb = $3 }
		END { gsub(/\r/, "", na); gsub(/\r/, "", nb); if (fa) printf "3;%s", na; else printf "2;%s", nb }' "$RES/mccmnc.dat" 2>/dev/null)
	case "$_hm_r" in
		3\;*) HOME_MNC="$_hm3" ;;
		*)    HOME_MNC="$_hm2" ;;
	esac
	HOME_OP="${_hm_r#?;}"
fi
[ -n "$SPN_NAME" ] && HOME_OP="$SPN_NAME"

IS_ROAMING=0
case "$REG" in 5|7|10) IS_ROAMING=1 ;; esac

if [ "$IS_ROAMING" = "1" ]; then
	COPS="$VISITED_COPS"
else
	[ -n "$SPN_NAME" ] && COPS="$SPN_NAME"
	_ob=$(opname_brand "$SIMID") && COPS="$_ob"
	HOME_OP=""
fi

if { [ "$IFPROTO" = modemmanager ] || [ -n "$_MM_OWNS" ]; } && command -v mmcli >/dev/null 2>&1; then
	_MI="$_pf_mi"
	[ -n "$_MI" ] || _MI=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_POLL_AM" 2>/dev/null)
	if [ -n "$_MI" ]; then
		_MK=$(mmcli -m "$_MI" -K 2>/dev/null)
		_mmv() { _v=$(printf '%s\n' "$_MK" | grep -F "$1 " | head -1 | sed 's/^[^:]*:[[:space:]]*//'); [ "$_v" = "--" ] && _v=""; printf '%s' "$_v"; }
		[ -z "$COPS" ]    && COPS=$(_mmv "modem.3gpp.operator-name")
		[ -z "$CSQ_PER" ] && [ -z "$RSRP" ] && CSQ_PER=$(_mmv "modem.generic.signal-quality.value")
		if [ -z "$REG" ]; then
			case "$(_mmv "modem.3gpp.registration-state")" in
				home)             REG=1 ;;
				searching)        REG=2 ;;
				denied)           REG=3 ;;
				roaming)          REG=5 ;;
				home-sms-only)    REG=6 ;;
				roaming-sms-only) REG=7 ;;
				idle)             REG=0 ;;
			esac
		fi
		if [ -z "$REG" ]; then
			case "$(_mmv "modem.generic.state"):$(_mmv "modem.generic.state-failed-reason"):$(_mmv "modem.generic.unlock-required")" in
				failed:sim-missing:*) REG="SIM not inserted" ;;
				failed:sim-error:*)   REG="SIM failure" ;;
				locked:*:sim-pin)     REG="SIM PIN required" ;;
				locked:*:sim-puk)     REG="SIM PUK required" ;;
			esac
		fi
		[ -z "$MODE" ]    && MODE=$(_mmv "modem.generic.access-technologies.value[1]" | tr 'a-z' 'A-Z')
		[ -z "$MODEL" ]   && MODEL=$(uci -q get "5gmodem.$_hl_sec.model")
		[ -z "$MODEL" ]   && MODEL=$(model_alias "$(_mmv "modem.generic.model")")
		[ -z "$IMEI" ]    && IMEI=$(_mmv "modem.3gpp.imei")
		if [ -z "$FW" ]; then
			_fwraw=$(_mmv "modem.generic.revision")
			FW=$(printf '%s' "$_fwraw" | sed 's/\\n/\n/g' | head -1 | xargs)
			_fwtail=$(printf '%s' "$_fwraw" | sed 's/\\n/\n/g' | sed -n '2p' \
				| awk '{print $1}' | grep -xE '[0-9]+' || true)
			[ -n "$_fwtail" ] && FW="$FW.$_fwtail"
		fi
		case "$FW" in ''|--) FW="" ;; esac
		if [ -z "$FW" ] && [ -n "$IMEI" ]; then
			_fwc="/tmp/5gmodem/fw_$IMEI"
			if [ -s "$_fwc" ]; then
				read -r FW < "$_fwc"
			else
				_fw_w=$(/usr/share/5gmodem/modemswitch.sh wdm "$_POLL_AM" 2>/dev/null)
				if [ -c "$_fw_w" ] && _poll_chan_free; then
					FW=$(qmicli_p "$_fw_w" --dms-get-software-version 2>/dev/null \
						| sed -n "s/.*Software version: *'\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" | head -1 | xargs)
					[ -n "$FW" ] && printf '%s\n' "$FW" > "$_fwc"
				fi
			fi
		fi
		if [ -z "$NR_IMSI" ] || [ -z "$NR_ICCID" ]; then
			_mm_simp=$(_mmv "modem.generic.sim")
			if [ -n "$_mm_simp" ]; then
				_mm_simk=$(mmcli -i "${_mm_simp##*/}" -K 2>/dev/null)
				if [ -z "$NR_IMSI" ]; then
					NR_IMSI=$(printf '%s\n' "$_mm_simk" | sed -n 's/^sim\.properties\.imsi *: *//p' | head -1)
					[ "$NR_IMSI" = "--" ] && NR_IMSI=""
				fi
				if [ -z "$NR_ICCID" ]; then
					NR_ICCID=$(printf '%s\n' "$_mm_simk" | sed -n 's/^sim\.properties\.iccid *: *//p' | head -1)
					[ "$NR_ICCID" = "--" ] && NR_ICCID=""
				fi
			fi
		fi
		if [ "$IS_ROAMING" != "1" ]; then
			_ob_mm=$(opname_brand "${SIMID:-$NR_IMSI}") && COPS="$_ob_mm"
		fi
	fi
fi

if [ -z "$PHONE" ] && command -v mmcli >/dev/null 2>&1; then
	if [ -z "$_MI" ]; then
		_MK=""
		mm_owns_path "$_POLL_AM" && _MI=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_POLL_AM" 2>/dev/null)
	fi
	if [ -n "$_MI" ]; then
		[ -n "$_MK" ] || _MK=$(mmcli -m "$_MI" -K 2>/dev/null)
		PHONE=$(printf '%s\n' "$_MK" \
			| sed -n 's/^modem\.generic\.own-numbers[^:]*:[[:space:]]*//p' \
			| tr -d ' ' | grep -E '^[+]?[0-9]{5,}$' | head -1)
	fi
fi

[ -n "$(echo $MODEL)" ] || MODEL=""
if [ -z "$MODEL" ] && [ -n "$_POLL_AM" ]; then
	[ -n "$_own_rec" ] || _own_rec=$("$RES/listmodems.sh" 2>/dev/null)
	MODEL=$(printf '%s' "$_own_rec" \
		| jsonfilter -e "@[@.path=\"$_POLL_AM\"].model" 2>/dev/null | head -1)
fi

AMP_SEC=""
_amp="$_POLL_AM"
[ -n "$_amp" ] && AMP_SEC="$_hl_sec"
if [ -n "$MODEL" ] && [ -n "$AMP_SEC" ] \
   && ! _model_vendor_ok "$MODEL" "$(uci -q get "5gmodem.$AMP_SEC.vidpid")"; then
	logger -t 5gmodem "model \"$MODEL\" is not from vendor $(uci -q get "5gmodem.$AMP_SEC.vidpid") - not writing it to the profile"
	MODEL=""
fi
[ -z "$MODEL" ] || [ -z "$_POLL_AM" ] || [ -n "$_own_rec" ] || _own_rec=$("$RES/listmodems.sh" 2>/dev/null)
if [ -n "$MODEL" ] && [ -n "$_POLL_AM" ] \
   && ! printf '%s' "$_own_rec" \
	| jsonfilter -e "@[@.path=\"$_POLL_AM\"].tty[0]" -e "@[@.path=\"$_POLL_AM\"].wdm[0]" 2>/dev/null \
	| grep -q .; then
	MODEL=""
fi
if [ -n "$MODEL" ] && [ -n "$AMP_SEC" ]; then
	MODEL=$(model_refine "$MODEL" "$(uci -q get "5gmodem.$AMP_SEC.product")")
fi
[ -n "$MODEL" ] && MODEL=$(model_alias "$MODEL")
if [ -n "$MODEL" ] && [ -n "$DEVICE" ] \
   && [ "$(tty_usbpath "$DEVICE" 2>/dev/null)" != "$_POLL_AM" ]; then
	logger -t 5gmodem "port $DEVICE does not belong to the polled modem ${_POLL_AM:-?} - model \"$MODEL\" not recorded"
	MODEL=""
fi
if [ -n "$MODEL" ] && [ -n "$AMP_SEC" ] && _model_sane "$MODEL"; then
	[ "$(uci -q get "5gmodem.$AMP_SEC.model")" = "$MODEL" ] \
	&& [ "$(uci -q get "5gmodem.$AMP_SEC.model_vp")" = "$(uci -q get "5gmodem.$AMP_SEC.vidpid")" ] || {
		uci -q set "5gmodem.$AMP_SEC.model=$MODEL"
		uci -q set "5gmodem.$AMP_SEC.model_vp=$(uci -q get "5gmodem.$AMP_SEC.vidpid")"
		uci -q commit 5gmodem
	}
fi

if [ -z "$NR_IMEI" ] || [ "$NR_IMEI" = "-" ]; then
	NR_IMEI=$(at_static imei "AT+CGSN" '^[0-9]{14,16}$' 2>/dev/null | tr -d '\r' \
		| grep -oE '^[0-9]{14,16}$' | head -1)
fi
case "$NR_IMEI" in
	''|*[!0-9]*) NR_IMEI="" ;;
esac
if [ -z "$NR_IMEI" ] || [ "$NR_IMEI" = "-" ]; then
	case "$IMEI" in
		''|*[!0-9]*) : ;;
		*) NR_IMEI="$IMEI" ;;
	esac
fi

case "$NR_IMSI" in
	''|*[!0-9]*) NR_IMSI="" ;;
esac

if [ -z "$NR_IMSI" ] || [ "$NR_IMSI" = "-" ]; then
	case "$SIMID" in
		''|*[!0-9]*) : ;;
		*) NR_IMSI="$SIMID" ;;
	esac
fi

if [ -z "$NR_ICCID" ] || [ "$NR_ICCID" = "-" ]; then
	NR_ICCID=$(at_static iccid "AT+ICCID" '[0-9]{18,22}' 2>/dev/null | tr -d '\r' \
		| grep -oE '[0-9]{18,22}' | head -1)
	[ -n "$NR_ICCID" ] || NR_ICCID=$(at_static ccid "AT+CCID" '[0-9]{18,22}' 2>/dev/null \
		| tr -d '\r' | grep -oE '[0-9]{18,22}' | head -1)
fi

case "$NR_ICCID" in
	*[Ff]) NR_ICCID=$(printf '%s' "$NR_ICCID" | sed 's/[Ff]*$//') ;;
esac

if [ -z "$SSIM" ] || [ "$SSIM" = "-" ]; then
	_slot_c="/tmp/5gmodem/slot_$_STKEY"
	_slot_age=""
	if [ -s "$_slot_c" ]; then
		_slot_t=$(cat "${_slot_c}.t" 2>/dev/null)
		case "$_slot_t" in
			''|*[!0-9]*) : ;;
			*) _slot_age=$(( $(uptime_s) - _slot_t )) ;;
		esac
	fi
	if [ -n "$_slot_age" ] && [ "$_slot_age" -ge 0 ] && [ "$_slot_age" -lt 60 ]; then
		SSIM=$(cat "$_slot_c" 2>/dev/null)
	elif [ "$_POLL_AM" != "$_ACT_AM" ]; then
		# simslot.sh only knows the active modem, see docs/subsystems/polling.md#identity
		:
	else
		_slot_v=$("$RES/simslot.sh" status 2>/dev/null \
			| jsonfilter -e '@.active' 2>/dev/null)
		case "$_slot_v" in
			''|*[!0-9]*) : ;;
			*) SSIM="$_slot_v"
			   printf '%s' "$_slot_v" > "$_slot_c" 2>/dev/null
			   uptime_s > "${_slot_c}.t" 2>/dev/null ;;
		esac
	fi
fi

_STAMP_PATH=$(tty_usbpath "$DEVICE" 2>/dev/null)
if [ -n "$DEVICE" ] && [ "$_STAMP_PATH" != "$_POLL_AM" ]; then
	logger -t 5gmodem "port $DEVICE belongs to ${_STAMP_PATH:-an unknown device}, not to the polled modem ${_POLL_AM:-?} - IMEI not recorded"
	NR_IMEI=""
fi
if [ -n "$AMP_SEC" ] && [ -n "$NR_IMEI" ] && [ "$(_active_path)" = "$_POLL_AM" ]; then
	case "$NR_IMEI" in
		*[!0-9]*|'') : ;;
		*)
			_foreign=""
			for _fs in $(uci show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.imei='$NR_IMEI'\$/\1/p"); do
				[ "$_fs" = "$AMP_SEC" ] && continue
				_fsp=$(uci -q get "5gmodem.$_fs.path")
				[ -n "$_fsp" ] && [ -e "/sys/bus/usb/devices/$_fsp" ] && { _foreign="$_fsp"; break; }
			done
			if [ -n "$_foreign" ]; then
				logger -t 5gmodem "IMEI $NR_IMEI belongs to present modem $_foreign - not writing it into section $AMP_SEC"
				NR_IMEI=""
			fi
			_old_imei=$(uci -q get "5gmodem.$AMP_SEC.imei")
			if [ -z "$NR_IMEI" ]; then
				:
			elif [ -z "$_old_imei" ]; then
				uci -q set "5gmodem.$AMP_SEC.imei=$NR_IMEI"
				uci -q commit 5gmodem
			elif [ "$_old_imei" != "$NR_IMEI" ]; then
				logger -t 5gmodem "modem swap on $(uci -q get 5gmodem.@5gmodem[0].active_modem): IMEI $_old_imei -> $NR_IMEI, settings may belong to the previous modem"
				uci -q set "5gmodem.$AMP_SEC.imei_prev=$_old_imei"
				uci -q set "5gmodem.$AMP_SEC.imei=$NR_IMEI"
				uci -q set "5gmodem.$AMP_SEC.imei_changed=1"
				uci -q commit 5gmodem
			fi
			_own_if=$(uci -q get "5gmodem.$AMP_SEC.network")
			if [ -n "$NR_IMEI" ] && [ -n "$_own_if" ] \
			   && [ "$(uci -q get "network.$_own_if.modem_path")" = "$_POLL_AM" ] \
			   && [ "$(uci -q get "network.$_own_if.modem_imei")" != "$NR_IMEI" ]; then
				logger -t 5gmodem "interface $_own_if was owned by IMEI $(uci -q get "network.$_own_if.modem_imei") - correcting to $NR_IMEI"
				note_foreign_uci network "опрос: штамп IMEI"
				uci -q set "network.$_own_if.modem_imei=$NR_IMEI"
				uci -q commit network
			fi
			;;
	esac
fi

op_cache_iface() {
	if [ -z "$DEVICE" ]; then
		_oci_p="${_POLL_AM:-$(uci -q get 5gmodem.@5gmodem[0].active_modem)}"
		[ -n "$_oci_p" ] || return 0
		_oci_s=$(secname "$_oci_p")
		uci -q get "5gmodem.$_oci_s.network"
		return
	fi
	_n=$(readlink -f "/sys/class/tty/$(basename "$DEVICE")/device" 2>/dev/null)
	while [ -n "$_n" ] && [ "$_n" != "/" ] && [ ! -f "$_n/idVendor" ]; do _n="${_n%/*}"; done
	[ -f "$_n/idVendor" ] || { printf '%s' "$SEC"; return; }
	_s=$(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.path='$(basename "$_n")'\$/\1/p" | head -1)
	[ -n "$_s" ] || { printf '%s' "$SEC"; return; }
	uci -q get "5gmodem.$_s.network"
}
_OPNAME="$COPS"
[ "$IS_ROAMING" = "1" ] && [ -n "$HOME_OP" ] && _OPNAME="$HOME_OP"
_OPNAME=$(operator_clean "$_OPNAME")
if [ -n "$SEC" ] && [ -n "$_OPNAME" ] && ! echo "$_OPNAME" | grep -qE '^[0-9 ]*$'; then
	OPIF=$(op_cache_iface)
	[ -n "$OPIF" ] && printf '%s' "$_OPNAME" > "/tmp/5gmodem/op_$OPIF" 2>/dev/null
fi

if [ -z "$CSQ" ] && [ -n "$RSSI" ]; then
	_csq_r=${RSSI%%.*}
	case "$_csq_r" in
		-[0-9]*)
			if [ "$_csq_r" -ge -51 ] 2>/dev/null; then
				CSQ=31
			elif [ "$_csq_r" -ge -113 ] 2>/dev/null; then
				CSQ=$(( (_csq_r + 113) / 2 ))
			else
				CSQ=0
			fi
			[ -z "$CSQ_PER" ] && CSQ_PER=$(( CSQ * 100 / 31 )) ;;
	esac
fi

AMBRDL=""; AMBRUL=""; QCI=""
if [ -n "$DEVICE" ] && [ "$REGOK" = 1 ]; then
	_AM_F="/tmp/5gmodem/ambr_$_MKEY"
	_AM_T=0; _AM_IP=""
	[ -s "$_AM_F" ] && read -r _AM_T _AM_IP AMBRDL AMBRUL QCI < "$_AM_F"
	case "$_AM_T" in ''|*[!0-9]*) _AM_T=0 ;; esac
	if [ "$_AM_IP" != "${IPADDR:--}" ] || [ $(( $(uptime_s) - _AM_T )) -ge 300 ]; then
		AMBRDL=""; AMBRUL=""; QCI=""
		for _AM_C in $(sms_tool -d "$DEVICE" at "AT+CGACT?" 2>/dev/null | tr -d '\r' \
			| sed -n 's/^+CGACT: *\([0-9]*\), *1.*/\1/p' | head -3); do
			_AM_R=$(sms_tool -d "$DEVICE" at "AT+CGEQOSRDP=$_AM_C" 2>/dev/null | tr -d '\r' \
				| sed -n 's/^+CGEQOSRDP: *//p' | head -1)
			_AM_V=$(printf '%s' "$_AM_R" | awk -F, '{ gsub(/[ "]/, "")
				if ($7 ~ /^[0-9]+$/ && $8 ~ /^[0-9]+$/ && $7 > 0 && $7 < 100000000)
					printf "%.0f %.0f %s", $7 / 1000, $8 / 1000, $2 }')
			[ -n "$_AM_V" ] || continue
			read -r _AM_D _AM_U _AM_Q <<-EOF
			$_AM_V
			EOF
			if [ -z "$AMBRDL" ] || [ "$_AM_D" -gt "$AMBRDL" ]; then
				AMBRDL="$_AM_D"; AMBRUL="$_AM_U"; QCI="$_AM_Q"
			fi
		done
		printf '%s %s %s %s %s\n' "$(uptime_s)" "${IPADDR:--}" "${AMBRDL:--}" "${AMBRUL:--}" "${QCI:--}" > "$_AM_F" 2>/dev/null
	fi
	[ "$AMBRDL" = "-" ] && AMBRDL=""
	[ "$AMBRUL" = "-" ] && AMBRUL=""
	[ "$QCI" = "-" ] && QCI=""
fi

_sig_pct=$(sig_percent "$MODE" "$RSRP" "$RSRQ" "$SINR" "$RSCP" "$ECIO" "$RSSI")
[ -n "$_sig_pct" ] && CSQ_PER="$_sig_pct"

_TMP="$CACHE.$$"
emit_snapshot > "$_TMP"

if [ -s "$_TMP" ] && jsonfilter -i "$_TMP" -e '@.modem' >/dev/null 2>&1; then
	cat "$_TMP"
	mv "$_TMP" "$CACHE"
	uptime_s > "$STAMP"
	case "$RSRP$RSRQ$SINR$RSSI" in
		''|-|--|---|----) ;;
		*)
			_hv() { case "$1" in ''|*[!0-9.-]*) _hvo="$_hvo -" ;; *) _hvo="$_hvo $1" ;; esac; }
			IFS=' ' read -r _hvo _ < /proc/uptime; _hvo="${_hvo%%.*}"
			_hv "$RSRP"; _hv "$RSRQ"; _hv "$SINR"; _hv "$RSSI"; _hv "$PCI"; _hv "$EARFCN"
			printf '%s %s\n' "$_hvo" "${PBAND:--}" >> "$HIST" 2>/dev/null
			if [ "$(wc -l < "$HIST" 2>/dev/null)" -gt 260 ] 2>/dev/null; then
				tail -n 240 "$HIST" > "$HIST.$$" 2>/dev/null && mv -f "$HIST.$$" "$HIST"
			fi
			;;
	esac
else
	cat "$_TMP" 2>/dev/null
	rm -f "$_TMP"
fi
exit 0
