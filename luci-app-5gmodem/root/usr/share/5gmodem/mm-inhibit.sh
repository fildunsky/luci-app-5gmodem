#!/bin/sh
#
# Keep ModemManager OFF our kernel-proto modems on systems where the udev
# ID_MM_DEVICE_IGNORE rule can't apply - e.g. routers using libudev-zero, which
# provides the libudev API but runs no udevd and processes no /etc/udev rules.
# There MM grabs a kernel-proto modem (qmi/mbim/xmm/atc/fibocom/...), fails to
# manage it (the kernel owns the netdev), and then keeps re-probing its AT ports,
# colliding with our metrics reads -> the whole info page flickers.
#
# mmcli --inhibit releases a modem from MM and holds it released for as long as
# the mmcli process lives. So we run one background inhibitor per kernel-proto
# modem and keep them alive. Self-heals across MM restarts (the inhibitor's DBus
# drop makes MM re-add the modem; the next loop re-inhibits it) and modem
# re-plugs. Modems on the 'modemmanager' protocol are NEVER inhibited - MM must
# manage those. On systems WITH working udev the kernel-proto modems aren't
# visible to MM at all, so this simply finds nothing to do (harmless).
#
# Runs as a small procd service (see /etc/init.d/5gmodem-mm-inhibit).

RES=/usr/share/5gmodem
CFG=5gmodem
RUN=/var/run/5gmodem-mm-inhibit
mkdir -p "$RUN"

_is_kernel_proto() {
	case "$1" in qmi|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom) return 0 ;; *) return 1 ;; esac
}

# effective protocol of the modem at usb path $1: real iface proto, else remembered
_proto_for_path() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		NP=$(uci -q get "network.$IF.proto")
		[ -n "$NP" ] && { echo "$NP"; return; }
	fi
	uci -q get "$CFG.$SEC.iface_proto"
}

# one pass: inhibit every kernel-proto modem currently visible in MM
inhibit_pass() {
	command -v mmcli >/dev/null 2>&1 || return 0
	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		DEV=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ -n "$DEV" ] || continue
		PATHID=$(basename "$DEV")                 # e.g. 1-1.3
		case "$PATHID" in *-*) ;; *) continue ;; esac
		proto=$(_proto_for_path "$PATHID")
		_is_kernel_proto "$proto" || continue     # leave modemmanager-proto modems alone
		pf="$RUN/$PATHID.pid"
		[ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null && continue
		# hold the inhibition in the background; record its pid
		setsid mmcli --inhibit -m "$I" >/dev/null 2>&1 &
		echo $! > "$pf"
	done
	# reap inhibitors whose process has exited (modem gone / MM restarted)
	for pf in "$RUN"/*.pid; do
		[ -f "$pf" ] || continue
		kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null || rm -f "$pf"
	done
}

case "$1" in
once)  inhibit_pass ;;
stop)  for pf in "$RUN"/*.pid; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; done ;;
*)     while :; do inhibit_pass; sleep 15; done ;;   # daemon (procd)
esac
