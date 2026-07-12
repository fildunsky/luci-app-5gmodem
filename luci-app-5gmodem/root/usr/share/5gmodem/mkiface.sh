#!/bin/sh
#
# Create / switch the network interface for the connected modem.
#
# Usage: mkiface.sh [name] [proto]
#   name  : interface name (default: modem)
#   proto : auto | mbim | qmi | ncm | xmm | atc | wwan | 3g | modemmanager
#           (default: auto). Any proto whose handler is installed can be passed;
#           the UI offers the ones actually available on the router.
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

# --- multi-modem: build the interface for the ACTIVE modem (by USB path), so
# two modems get SEPARATE interfaces + separate cdc-wdm nodes instead of both
# clobbering a single "modem" interface (which made the IP look shared). ---
AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
MSEC=""
WANTWDM=""
if [ -n "$AMP" ]; then
	MSEC="m_$(echo "$AMP" | sed 's/[^A-Za-z0-9]/_/g')"
	# interface name: prefer the one remembered for THIS modem, default "modem".
	# Then guarantee uniqueness - if that name is already claimed by ANOTHER
	# modem's section, bump to modem2/modem3/… so two modems never share one
	# interface (which made the IP look shared).
	USED=$(uci show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\(.*\)'\$/\1=\2/p" | grep -v "^$MSEC=" | cut -d= -f2)
	cand=$(uci -q get "5gmodem.$MSEC.network")
	[ -n "$cand" ] || cand="modem"
	n=1
	while echo " $USED " | grep -q " $cand "; do n=$((n + 1)); cand="modem$n"; done
	IF="$cand"
	# the cdc-wdm control node that belongs to THIS modem
	WANTWDM=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$AMP\"].wdm[0]" 2>/dev/null)
fi

# --- locate the cdc-wdm control node and its driver (this modem's, if known) ---
DEV=""; DRV=""
if [ -n "$WANTWDM" ] && [ -c "$WANTWDM" ]; then
	DEV="$WANTWDM"
	DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$WANTWDM")/device/driver" 2>/dev/null)")
else
	for wdm in /dev/cdc-wdm*; do
		[ -c "$wdm" ] || continue
		DEV="$wdm"
		DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$wdm")/device/driver" 2>/dev/null)")
		break
	done
fi

# --- decide the proto ---
# auto: pick from the cdc-wdm driver. Any other value is passed through as-is,
# so any installed netifd/luci proto handler (mbim, qmi, ncm, xmm, atc, wwan,
# 3g, modemmanager, ...) can be selected from the UI.
case "$REQ" in
	auto|"")
		case "$DRV" in
			cdc_mbim) PROTO="mbim" ;;
			qmi_wwan) PROTO="qmi" ;;
			*)        PROTO="mbim" ;;
		esac ;;
	*) PROTO="$REQ" ;;
esac

# --- ModemManager service: on ONLY for the modemmanager proto; every other
# proto (umbim/uqmi/ncm/xmm/atc/...) drives the modem itself and would fight
# ModemManager over the control channel, so MM is stopped+disabled. ---
case "$PROTO" in
	modemmanager)
		/etc/init.d/modemmanager enable >/dev/null 2>&1
		/etc/init.d/modemmanager restart >/dev/null 2>&1
		;;
	*)
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		/etc/init.d/modemmanager disable >/dev/null 2>&1
		;;
esac

# --- AT / serial control port (for serial-based protos) ---
ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
[ -n "$ATP" ] || ATP=$(/usr/share/5gmodem/detect.sh 2>/dev/null)

# --- device path for the interface, by proto family ---
case "$PROTO" in
	modemmanager)
		# MM wants the modem's USB sysfs path: walk up from cdc-wdm to the node
		# that carries idVendor (the usb_device).
		IDEV=$(readlink -f "/sys/class/usbmisc/$(basename "${DEV:-cdc-wdm0}")/device" 2>/dev/null)
		while [ -n "$IDEV" ] && [ "$IDEV" != "/" ] && [ ! -f "$IDEV/idVendor" ]; do
			IDEV=$(dirname "$IDEV")
		done
		[ -f "$IDEV/idVendor" ] || IDEV=""
		;;
	mbim|qmi|xmm)
		# control channel over the cdc-wdm node
		IDEV="$DEV"
		;;
	ncm|atc|3g|wwan|ppp)
		# serial-controlled protos talk AT on a ttyUSB/ttyACM port
		IDEV="$ATP"
		;;
	*)
		# unknown proto: prefer the cdc-wdm node, fall back to the AT port
		IDEV="${DEV:-$ATP}"
		;;
esac

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
	qmi|mbim|xmm)
		uci set "network.$IF.pdptype=ipv4v6"
		uci set "network.$IF.auth=none"
		;;
	ncm|atc|3g|wwan)
		# серийные протоколы: базовый auth; порт (ttyUSB) уже задан выше.
		# Часть модемов требует ещё 'mode'/'delay'/'service' - это оставляем
		# на доводку в стандартном разделе Сеть > Интерфейсы.
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

# point the app at the interface, and remember the user's protocol choice
# (auto/mbim/modemmanager/qmi) so the settings page shows it on return - done
# here, on the router, so LuCI does not raise an "unsaved changes" banner.
uci -q set "5gmodem.@5gmodem[0].network=$IF"
uci -q set "5gmodem.@5gmodem[0].iface_proto=$REQ"
# remember the interface+proto for THIS modem so switching back restores it and
# the other modem keeps its own separate interface (no clobbering, distinct IP).
if [ -n "$MSEC" ]; then
	uci -q get "5gmodem.$MSEC" >/dev/null 2>&1 || { uci -q set "5gmodem.$MSEC=modem"; uci -q set "5gmodem.$MSEC.path=$AMP"; }
	uci -q set "5gmodem.$MSEC.network=$IF"
	uci -q set "5gmodem.$MSEC.iface_proto=$REQ"
fi
uci -q commit 5gmodem

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
		*)
			# любой не-MM протокол: MM выключен -> SMS/USSD через AT-порт
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
