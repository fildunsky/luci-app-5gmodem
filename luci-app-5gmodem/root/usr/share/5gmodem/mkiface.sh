#!/bin/sh
#
# Create / switch the network interface for the connected modem.
#
# Usage: mkiface.sh [name] [proto]
#   name  : interface name (default: modem)
#   proto : auto | mbim | modemmanager | qmi   (default: auto)
#
# - auto: pick the proto from the real driver of the cdc-wdm control node
#   (cdc_mbim -> mbim, qmi_wwan -> qmi). This is far more reliable than mmcli,
#   which on many MBIM modems (e.g. Compal RXM-G1) misclassifies the port and
#   builds a non-working modem, and it never creates a non-working qmi over an
#   MBIM composition.
# - mbim/qmi: the kernel (umbim/uqmi) owns cdc-wdm0. ModemManager MUST NOT run,
#   or the two fight over the control channel -> so we stop+disable it.
# - modemmanager: MM owns the modem. We enable+(re)start it and point the
#   interface at the modem's sysfs path.
#
# Adds the interface to the 'wan' firewall zone, points the app at it, brings
# it up, and prints a small JSON result.
#

IF="${1:-modem}"
REQ="${2:-auto}"

json() { printf '{"result":"%s","iface":"%s","proto":"%s","device":"%s"}\n' "$1" "$IF" "$2" "$3"; }

# --- locate the cdc-wdm control node and its driver ---
DEV=""; DRV=""
for wdm in /dev/cdc-wdm*; do
	[ -c "$wdm" ] || continue
	DEV="$wdm"
	DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$wdm")/device/driver" 2>/dev/null)")
	break
done

# --- decide the proto ---
case "$REQ" in
	mbim)         PROTO="mbim" ;;
	qmi)          PROTO="qmi" ;;
	modemmanager) PROTO="modemmanager" ;;
	*)  # auto: match the driver
		case "$DRV" in
			cdc_mbim) PROTO="mbim" ;;
			qmi_wwan) PROTO="qmi" ;;
			*)        PROTO="mbim" ;;
		esac ;;
esac

# --- ModemManager service: on for modemmanager, off for umbim/uqmi ---
case "$PROTO" in
	modemmanager)
		/etc/init.d/modemmanager enable >/dev/null 2>&1
		/etc/init.d/modemmanager restart >/dev/null 2>&1
		;;
	mbim|qmi)
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		/etc/init.d/modemmanager disable >/dev/null 2>&1
		;;
esac

# --- device path for the interface ---
if [ "$PROTO" = "modemmanager" ]; then
	# MM wants the modem's USB sysfs path: walk up from cdc-wdm to the node
	# that carries idVendor (the usb_device).
	IDEV=$(readlink -f "/sys/class/usbmisc/$(basename "${DEV:-cdc-wdm0}")/device" 2>/dev/null)
	while [ -n "$IDEV" ] && [ "$IDEV" != "/" ] && [ ! -f "$IDEV/idVendor" ]; do
		IDEV=$(dirname "$IDEV")
	done
	[ -f "$IDEV/idVendor" ] || IDEV=""
else
	IDEV="$DEV"
fi

[ -n "$IDEV" ] || { json nomodem "$PROTO" ""; exit 1; }

# --- (re)write the interface ---
# keep the existing APN if the interface already exists, else a generic default
OLDAPN=$(uci -q get "network.$IF.apn")
uci -q delete "network.$IF" 2>/dev/null
uci set "network.$IF=interface"
uci set "network.$IF.proto=$PROTO"
uci set "network.$IF.device=$IDEV"
uci set "network.$IF.apn=${OLDAPN:-internet}"
case "$PROTO" in
	modemmanager)
		uci set "network.$IF.iptype=ipv4v6"
		;;
	qmi|mbim)
		uci set "network.$IF.pdptype=ipv4v6"
		uci set "network.$IF.auth=none"
		;;
esac
uci commit network

# add to the 'wan' firewall zone (if one exists) so NAT/forwarding works
Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
if [ -n "$Z" ]; then
	if ! uci -q get "firewall.$Z.network" | grep -qw "$IF"; then
		uci add_list "firewall.$Z.network=$IF"
		uci commit firewall
	fi
fi

# point the app at the interface
uci -q set "5gmodem.@5gmodem[0].network=$IF" && uci -q commit 5gmodem

# SMS/USSD routing must follow the modem's owner:
#  - modemmanager: MM captures all messaging -> use the mmcli path
#  - mbim/qmi (umbim/uqmi): MM is off -> use the raw AT port (sms_tool),
#    which needs the WMS routes on the SIM (set below) to receive SMS.
# This keeps the SMS/USSD pages working whichever interface is active,
# instead of silently talking to a daemon that is no longer running.
if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
	case "$PROTO" in
		modemmanager)
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=1"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=1"
			;;
		mbim|qmi)
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=0"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=0"
			;;
	esac
	uci -q commit sms_tool_js
fi

# WMS SMS routes: this modem's factory default stores incoming messages in NV,
# where MBIM/ModemManager/AT cannot read them. Redirect classes to the SIM (uim)
# so incoming SMS are received. The hotplug does this on device appearance, but
# switching to modemmanager here does not re-enumerate USB, so re-apply on every
# switch. qmicli works over QMI-in-MBIM even while ModemManager owns the modem.
if [ -n "$DEV" ] && command -v qmicli >/dev/null 2>&1; then
	for c in 0 1 2 3 none; do
		qmicli -p -d "$DEV" \
			--wms-set-routes="type=point,class=$c,storage=uim,receipt-action=store-and-notify" \
			>/dev/null 2>&1
	done
fi

ifup "$IF" >/dev/null 2>&1

json created "$PROTO" "$IDEV"
exit 0
