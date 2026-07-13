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

# ModemManager modem index whose USB device path matches a usb topology path
mm_index_for_path() {
	[ -n "$1" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	for m in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		d=$(mmcli -m "$m" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p' | xargs)
		case "$d" in */"$1") echo "$m"; return 0 ;; esac
	done
	return 1
}

# cdc-wdm control node of the modem at a usb path
wdm_for_path() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].wdm[0]" 2>/dev/null
}

# ModemManager must run if ANY modem interface uses the modemmanager proto (they
# need MM). Creating an mbim/qmi/atc interface used to blindly disable MM and
# thereby break the modemmanager modems -> keep MM's state driven by ALL
# interfaces, not just the one being created.
apply_mm_state() {
	command -v mmcli >/dev/null 2>&1 || return 0
	if uci show network 2>/dev/null | grep -q "\.proto='modemmanager'"; then
		/etc/init.d/modemmanager enabled >/dev/null 2>&1 || /etc/init.d/modemmanager enable >/dev/null 2>&1
		pgrep -f ModemManager >/dev/null 2>&1 || /etc/init.d/modemmanager start >/dev/null 2>&1
	elif uci show network 2>/dev/null | grep -qE "\.proto='(mbim|qmi)'"; then
		# kernel owns the control channel -> MM must be off
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		/etc/init.d/modemmanager disable >/dev/null 2>&1
	fi
}

# repair a modem's interface: re-point its device to the current node for THIS
# modem's stable USB path (cdc-wdm / ttyUSB numbers are unstable), then bring it
# up if the device changed or it is not up. This is what auto-recovers the
# connection after a reboot / modem swap when the pinned device went stale.
ensure_iface() {
	P="$1"; SEC="$2"
	IF=$(uci -q get "$CFG.$SEC.network")
	[ -n "$IF" ] || return 0
	uci -q get "network.$IF" >/dev/null 2>&1 || return 0
	PROTO=$(uci -q get "network.$IF.proto")
	CUR=$(uci -q get "network.$IF.device")
	NEW=""
	case "$PROTO" in
		mbim|qmi|xmm|ncm) NEW=$(wdm_for_path "$P") ;;
		modemmanager)     NEW=$(readlink -f "/sys/bus/usb/devices/$P" 2>/dev/null) ;;
		atc|3g|wwan|ppp)  NEW=$(uci -q get "$CFG.$SEC.at_port") ;;
		fibocom)          NEW=$(for n in /sys/bus/usb/devices/$P:*/net/*; do [ -e "$n" ] && { basename "$n"; break; }; done) ;;
	esac
	CHG=0
	if [ -n "$NEW" ] && { [ -e "$NEW" ] || [ -d "/sys/class/net/$NEW" ]; } && [ "$NEW" != "$CUR" ]; then
		uci -q set "network.$IF.device=$NEW"; uci -q commit network; CHG=1
	fi
	if [ "$CHG" = 1 ] || ! ifstatus "$IF" 2>/dev/null | grep -q '"up": true'; then
		ifup "$IF" >/dev/null 2>&1
	fi
}

# AT port of the modem at a usb path: fast via ModemManager, else probe its ttys
at_for_path() {
	mi=$(mm_index_for_path "$1")
	if [ -n "$mi" ]; then
		p=$(mmcli -m "$mi" 2>/dev/null | grep -oE '(ttyUSB[0-9]+|ttyACM[0-9]+) \(at\)' | sed 's/ (at)//' | head -1)
		[ -n "$p" ] && [ -e "/dev/$p" ] && { echo "/dev/$p"; return 0; }
	fi
	detect_at $(modem_ttys "$1")
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

# Pick the SMS read storage for the active modem. Incoming messages land in
# different places by modem: many USB modems (e.g. SimCom SIM7100) deliver them
# to ME (modem memory), not SM (SIM) - reading SM then shows an empty inbox and
# the UI complains there is no port. Probe both and prefer the one that holds
# messages; default to ME (the common case). Only sets the value when the user
# has not chosen one, so it never overrides a manual SIM/Memory pick.
set_sms_storage() {
	AT="$1"
	[ -n "$AT" ] && [ -e "$AT" ] || return 0
	command -v sms_tool >/dev/null 2>&1 || return 0
	uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1 || return 0
	[ -z "$(uci -q get sms_tool_js.@sms_tool_js[0].storage)" ] || return 0
	me=$(sms_tool -d "$AT" -s ME status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	sm=$(sms_tool -d "$AT" -s SM status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	if   [ "${me:-0}" -gt 0 ] 2>/dev/null; then STG=ME
	elif [ "${sm:-0}" -gt 0 ] 2>/dev/null; then STG=SM
	elif [ -n "$me" ]; then STG=ME          # ME supported, just empty
	elif [ -n "$sm" ]; then STG=SM          # only SM answered
	else STG=ME
	fi
	uci -q set "sms_tool_js.@sms_tool_js[0].storage=$STG"
	uci -q commit sms_tool_js
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

	# AT port: always resolve from this modem's OWN current ports (ttyUSB numbers
	# are not stable, so a saved one may now belong to another modem). Fast via
	# ModemManager, else probe.
	ATP=$(at_for_path "$P")

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
		set_sms_storage "$ATP"
	fi

	# drop the cached AT port so detect.sh re-resolves for the new modem
	rm -f /tmp/modem

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

resolve)
	# Re-resolve ports/devices for all PRESENT modems by their STABLE USB path.
	# ttyUSB numbering shifts when a modem is added/removed or on reboot, so a
	# pinned ttyUSB goes stale ("Bad file descriptor", no data). Run on boot
	# (coldplug) and on USB hotplug add/remove -> the app self-heals, no manual
	# re-creation needed.
	PRESENT=$("$RES/listmodems.sh" | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')

	# refresh at_port for every present, configured modem
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		A=$(at_for_path "$P")
		[ -n "$A" ] && uci -q set "$CFG.$SEC.at_port=$A"
	done
	uci -q commit "$CFG"

	# active modem: if it was unplugged, fall back to the first present one
	AMP=$(active_path)
	if [ -z "$AMP" ] || ! echo " $PRESENT " | grep -q " $AMP "; then
		AMP=$(echo "$PRESENT" | awk '{print $1}')
		[ -n "$AMP" ] && uci -q set "$CFG.@5gmodem[0].active_modem=$AMP" && uci -q commit "$CFG"
	fi
	[ -n "$AMP" ] || { echo '{"result":"no-modems"}'; exit 0; }

	# apply the active modem's fresh AT port to the working config + SMS ports
	SEC=$(secname "$AMP")
	ATP=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$ATP" ] && [ -e "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
		if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
			for k in readport sendport ussdport atport; do uci -q set "sms_tool_js.@sms_tool_js[0].$k=$ATP"; done
			uci -q commit sms_tool_js
			set_sms_storage "$ATP"
		fi
	fi

	# --- recover the connections ---
	# 0) refresh the ModemManager ignore rules from the current per-modem protos,
	#    so MM keeps its hands off modems we drive via a kernel proto (qmi/mbim/
	#    atc/fibocom/...). Runs on boot (coldplug) and every hotplug.
	"$RES/mm-filter.sh" >/dev/null 2>&1
	# 1) put ModemManager in the state the modem mix needs (creating an atc/mbim
	#    interface had disabled MM and taken the modemmanager modems down).
	apply_mm_state
	# 2) repair EVERY present modem's interface device (stale after renumbering)
	#    and bring it up if it is down - so all modems reconnect automatically.
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " || continue
		ensure_iface "$p" "$s"
	done

	# point the app at the active modem's interface
	IF=$(uci -q get "$CFG.$SEC.network"); [ -n "$IF" ] && uci -q set "$CFG.@5gmodem[0].network=$IF"
	uci -q commit "$CFG"
	rm -f /tmp/modem
	printf '{"result":"resolved","active":"%s","at_port":"%s"}\n' "$AMP" "$ATP"
	;;

mmindex)
	# ModemManager index of the ACTIVE modem (for band/mode targeting)
	mm_index_for_path "$(active_path)"
	;;

wdm)
	# cdc-wdm control node of the ACTIVE modem (for qmicli targeting)
	wdm_for_path "$(active_path)"
	;;

*)
	echo "usage: $0 active|switch <path>|save <path>|resolve|mmindex|wdm" >&2
	exit 1
	;;
esac
