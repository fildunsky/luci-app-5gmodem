#!/bin/sh
#
# Multi-modem control. A modem is identified by its stable USB topology PATH
# (e.g. "1-1.3"), so it survives reboots and is unique even for two identical
# VID:PID modems. This script makes one modem "active" - the app then reads
# metrics / SMS / USSD from that modem's ports and interface.
#
# Storage in the 5gmodem config:
#   5gmodem.@5gmodem[0].active_modem = <usb path>
#   config modem 'm_<path>'  { path, product, at_port, network, iface_proto }
# The per-modem section remembers each modem's chosen AT port and interface, so
# switching back and forth restores its settings.
#
# Usage:
#   modemswitch.sh active            - print the active USB path
#   modemswitch.sh switch <path>     - make <path> active (detect ports, apply)
#   modemswitch.sh save <path>       - persist the current working config into
#                                      the given modem's section (before switch)
#

RES=/usr/share/5gmodem
CFG=5gmodem

secname() { echo "m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }
active_path() { uci -q get "$CFG.@5gmodem[0].active_modem"; }

# ports (tty) of the modem at a given usb path, from listmodems.sh
modem_ttys() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null
}
modem_product() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].product" 2>/dev/null | head -1
}

# first tty that answers "AT" = the modem's AT port
detect_at() {
	for t in "$@"; do
		[ -e "$t" ] || continue
		case "$t" in /dev/ttyUSB*|/dev/ttyACM*) ;; *) continue ;; esac
		if sms_tool -d "$t" at "AT" >/dev/null 2>&1; then echo "$t"; return 0; fi
	done
	return 1
}

# make sure a 'modem' section exists for a path; echo its name
ensure_section() {
	SEC=$(secname "$1")
	if ! uci -q get "$CFG.$SEC" >/dev/null 2>&1; then
		uci -q set "$CFG.$SEC=modem"
		uci -q set "$CFG.$SEC.path=$1"
		uci -q set "$CFG.$SEC.product=$(modem_product "$1")"
	fi
	echo "$SEC"
}

# snapshot the current AT port into a modem section. NOTE: we deliberately do
# NOT copy 'network'/'iface_proto' here - those belong to the interface and are
# owned by mkiface.sh (which assigns a UNIQUE interface per modem). Copying the
# working 'network' here used to propagate a shared "modem" into every modem's
# section, so two modems ended up on one interface (shared IP).
save_to() {
	SEC=$(ensure_section "$1")
	uci -q set "$CFG.$SEC.at_port=$(uci -q get $CFG.@5gmodem[0].at_port)"
	uci -q commit "$CFG"
}

case "$1" in
active)
	active_path
	;;

save)
	[ -n "$2" ] || { echo '{"error":"no path"}'; exit 1; }
	save_to "$2"
	echo '{"result":"saved"}'
	;;

switch)
	P="$2"
	[ -n "$P" ] || { echo '{"error":"no path"}'; exit 1; }

	# remember the currently-active modem's settings first (if any)
	CUR=$(active_path)
	[ -n "$CUR" ] && [ "$CUR" != "$P" ] && save_to "$CUR"

	SEC=$(ensure_section "$P")

	# AT port: saved one (if still present) wins, else auto-detect among the
	# modem's own ports so ports of a different modem are never picked.
	ATP=$(uci -q get "$CFG.$SEC.at_port")
	if [ -z "$ATP" ] || [ ! -e "$ATP" ]; then
		ATP=$(detect_at $(modem_ttys "$P"))
	fi

	# apply to the working config. detect.sh (and thus 5gmodem.sh) resolves the
	# modem port from 5gmodem.device FIRST - so we pin BOTH device and at_port
	# to this modem's AT port, otherwise detect.sh falls through to
	# "mmcli -m any" and reads a different modem.
	uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	if [ -n "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
	fi
	NET=$(uci -q get "$CFG.$SEC.network")
	[ -n "$NET" ] && uci -q set "$CFG.@5gmodem[0].network=$NET"
	PRO=$(uci -q get "$CFG.$SEC.iface_proto")
	[ -n "$PRO" ] && uci -q set "$CFG.@5gmodem[0].iface_proto=$PRO"
	uci -q commit "$CFG"

	# SMS/USSD ports follow the AT port
	if [ -n "$ATP" ] && uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q set "sms_tool_js.@sms_tool_js[0].$k=$ATP"
		done
		uci -q commit sms_tool_js
	fi

	# drop the cached AT port so detect.sh re-resolves for the new modem
	rm -f /tmp/modem

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

*)
	echo "usage: $0 active|switch <path>|save <path>" >&2
	exit 1
	;;
esac
