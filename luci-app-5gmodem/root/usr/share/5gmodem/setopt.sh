#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null
RES=/usr/share/5gmodem

_sec_for_path() { echo "m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }
_norm01() { [ "$1" = "1" ] && echo 1 || echo 0; }

case "$1" in
roaming)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 1
	note_foreign_uci network "setopt roaming"
	uci -q set "network.$_ifn.allow_roaming=$(_norm01 "$3")"
	uci -q commit network
	ubus call network reload >/dev/null 2>&1
	ifup "$_ifn" >/dev/null 2>&1
	;;
ipwatch)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 1
	note_foreign_uci network "setopt ipwatch"
	if [ "$(_norm01 "$3")" = 1 ]; then
		uci -q set "network.$_ifn.ipwatch=1"
	else
		uci -q delete "network.$_ifn.ipwatch"
	fi
	uci -q commit network
	ubus call network reload >/dev/null 2>&1
	ifup "$_ifn" >/dev/null 2>&1
	;;
ippass)
	# bridge (IP pass-through) of Unisoc-based Fibocom modules; applied by the proto on redial
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 1
	note_foreign_uci network "setopt ippass"
	uci -q set "network.$_ifn.ippass=$(_norm01 "$3")"
	uci -q commit network
	ubus call network reload >/dev/null 2>&1
	ifup "$_ifn" >/dev/null 2>&1
	;;
atdebug)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$2"
	}
	uci -q set "5gmodem.$_sec.at_debug=$(_norm01 "$3")"
	uci -q commit 5gmodem
	;;
mmat)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$2"
	}
	uci -q set "5gmodem.$_sec.mm_at=$(_norm01 "$3")"
	uci -q commit 5gmodem
	;;
noat)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$2"
	}
	if [ "$(_norm01 "$3")" = 1 ]; then
		uci -q set "5gmodem.$_sec.no_at=1"
	else
		uci -q delete "5gmodem.$_sec.no_at" 2>/dev/null
	fi
	uci -q commit 5gmodem
	;;
dnsfb)
	[ -n "$2" ] || exit 1
	_sec=$(_sec_for_path "$2")
	_ifn=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 0
	_flag=$(_norm01 "$3")
	if [ $# -ge 3 ]; then shift 3; else set --; fi
	_srv="$*"
	note_foreign_uci network "setopt dnsfb"
	if [ "$_flag" = "1" ] && [ -n "$_srv" ]; then
		uci -q set "network.$_ifn.dns=$_srv"
	else
		uci -q delete "network.$_ifn.dns"
	fi
	uci -q commit network
	ubus call network reload >/dev/null 2>&1
	;;
simpleview)
	uci -q set "5gmodem.@5gmodem[0].simple_view=$(_norm01 "$2")"
	uci -q commit 5gmodem
	;;
netblocks)
	shift
	_bo=""
	_bh=""
	for _bk in "$@"; do
		_bn=${_bk#-}
		case "$_bn" in
			net|conn|restart|cell|freq|ttl|hist) ;;
			*) continue ;;
		esac
		case " $_bo " in *" $_bn "*) continue ;; esac
		_bo="${_bo:+$_bo }$_bn"
		[ "$_bk" = "-$_bn" ] && [ "$_bn" != "conn" ] && _bh="${_bh:+$_bh }$_bn"
	done
	if [ -n "$_bo" ]; then
		uci -q set "5gmodem.@5gmodem[0].net_order=$_bo"
	else
		uci -q delete "5gmodem.@5gmodem[0].net_order"
	fi
	if [ -n "$_bh" ]; then
		uci -q set "5gmodem.@5gmodem[0].net_hidden=$_bh"
	else
		uci -q delete "5gmodem.@5gmodem[0].net_hidden"
	fi
	uci -q delete "5gmodem.@5gmodem[0].net_layout"
	uci -q delete "5gmodem.@5gmodem[0].tiles_order"
	uci -q delete "5gmodem.@5gmodem[0].tiles_hidden"
	uci -q commit 5gmodem
	;;
reconnect)
	# "reconnect for=<usb path>": that modem's interface; the global one only when it has none of its own
	_ifn=""
	case "$2" in
		for=*[!0-9A-Za-z.:_-]*|for=) : ;;
		for=*) _ifn=$(uci -q get "5gmodem.$(_sec_for_path "${2#for=}").network") ;;
	esac
	[ -n "$_ifn" ] || _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_ifn" ] || exit 0
	( ifdown "$_ifn"; sleep 2; ifup "$_ifn" ) >/dev/null 2>&1 </dev/null &
	sleep 1
	;;
applyset)
	uci -q commit 5gmodem
	rm -f /tmp/luci-indexcache* 2>/dev/null
	( exec 1000>&- 7>&- 8>&- 9>&-; /usr/share/5gmodem/netonly.sh apply ) >/dev/null 2>&1 </dev/null &
	_sp=$(uci -q get 5gmodem.sms.readport)
	[ -n "$_sp" ] || _sp=$(uci -q get 5gmodem.sms.atport)
	if [ -c "$_sp" ]; then
		rm -f /tmp/5gmodem/cpms_* 2>/dev/null
		( set_sms_storage "$_sp" ) >/dev/null 2>&1 </dev/null &
	fi
	rm -f /tmp/5gmodem/listmodems.cache /tmp/5gmodem/listmodems.stamp 2>/dev/null
	sleep 1
	;;
menuflush)
	rm -f /tmp/luci-indexcache* 2>/dev/null
	;;
webreq)
	# uhttpd max_requests: how many CGI/ubus requests the web server runs at once (OpenWrt ships 3).
	# No value: print {"value":N,"mem_mb":M}. A value: set it and restart uhttpd detached, so the
	# request that asked for it still gets its answer.
	if [ -z "$2" ]; then
		_wr=$(uci -q get uhttpd.main.max_requests); [ -n "$_wr" ] || _wr=3
		_wm=$(awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null)
		printf '{"value":%s,"mem_mb":%s}\n' "$_wr" "${_wm:-0}"
		exit 0
	fi
	case "$2" in ''|*[!0-9]*) exit 1 ;; esac
	[ "$2" -ge 1 ] && [ "$2" -le 50 ] || exit 1
	uci -q get uhttpd.main >/dev/null || exit 1
	[ "$(uci -q get uhttpd.main.max_requests)" = "$2" ] && exit 0
	note_foreign_uci uhttpd "setopt webreq"
	uci -q set "uhttpd.main.max_requests=$2"
	uci -q commit uhttpd
	logger -t 5gmodem "uhttpd max_requests set to $2"
	# late enough for the page to finish saving and applying its other settings first
	( sleep 8; /etc/init.d/uhttpd restart ) >/dev/null 2>&1 </dev/null &
	;;
*)
	echo "usage: $0 {roaming <path> <0|1>|atdebug <path> <0|1>|mmat <path> <0|1>|noat <path> <0|1>|dnsfb <path> <0|1> [servers]|simpleview <0|1>|netblocks [key|-key]...|reconnect [for=<path>]|applyset|menuflush|webreq [1-50]}" >&2
	exit 1
	;;
esac
exit 0
