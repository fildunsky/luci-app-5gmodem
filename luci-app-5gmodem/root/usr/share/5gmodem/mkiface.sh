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
# APN, переданный из UI (автоподстановка по оператору или ручной ввод).
#   <строка> - применить его;
#   "-"      - ЯВНО без APN (оператор опознан, но APN для него неизвестен) -> опцию
#              удаляем, модем возьмёт APN сети по умолчанию;
#   пусто    - аргумент не передан (вызов не из UI) -> сохранить прежний APN.
# Разделять "-" и пусто пришлось потому, что раньше стереть APN было НЕЛЬЗЯ:
# ${APNARG:-${OLDAPN:-internet}} трактует пустую строку как «не передано» и
# молча возвращал прежнее значение.
APNARG="$3"

# Записать APN интерфейса $1 по правилам выше ($2 = прежний APN)
set_apn_opt() {
	case "$APNARG" in
		-)  uci -q delete "network.$1.apn" ;;
		"") uci set "network.$1.apn=${2:-internet}" ;;
		*)  uci set "network.$1.apn=$APNARG" ;;
	esac
}

json() { printf '{"result":"%s","iface":"%s","proto":"%s","device":"%s"}\n' "$1" "$IF" "$2" "$3"; }

# Безопасный (пере)запуск ModemManager.
# НЕЛЬЗЯ `/etc/init.d/modemmanager restart`: procd поднимает новый процесс, не
# дожидаясь, пока прежний отпустит имя на D-Bus. Новый не может забрать
# org.freedesktop.ModemManager1 ("could not acquire the service name") и сразу
# умирает, а старый уже остановлен - MM пропадает на 1-2 минуты и "теряет модем"
# (видно в логе: два "ModemManager is shut down" подряд, затем пауза ~68 c до
# respawn'а). Поэтому: остановить, ДОЖДАТЬСЯ исчезновения процесса, запустить.
# Если MM не запущен - просто стартуем (как это делает modemswitch.sh).
mm_restart_safe() {
	if pgrep -f ModemManager >/dev/null 2>&1; then
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		_n=0
		while pgrep -f ModemManager >/dev/null 2>&1 && [ "$_n" -lt 15 ]; do
			sleep 1; _n=$((_n + 1))
		done
	fi
	/etc/init.d/modemmanager start >/dev/null 2>&1
}

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

# --- AT-dialed RNDIS/ECM modems (Fibocom FM350-GL 0e8d:7127 and similar): they
# expose NO cdc-wdm control channel; data rides a usbnet device (eth*) that we
# fill via an AT PDP dial. ModemManager cannot enable them (fails with
# UnexpectedDataValue) and mbim/qmi need a cdc-wdm that does not exist here - so
# route them to our 'fibocom' netifd proto instead of the mbim fallback below. ---
if [ -n "$AMP" ] && [ -z "$WANTWDM" ] && { [ "$REQ" = auto ] || [ "$REQ" = "" ] || [ "$REQ" = fibocom ] || [ "$REQ" = atc ] || [ "$REQ" = xmm ]; }; then
	FNET=""
	for n in /sys/bus/usb/devices/$AMP:*/net/*; do
		[ -e "$n" ] || continue
		FNET=$(basename "$n"); break
	done
	if [ -n "$FNET" ]; then
		OLDAPN=$(uci -q get "network.$IF.apn")
		uci -q delete "network.$IF" 2>/dev/null
		uci set "network.$IF=interface"

		# Default to the built-in 'fibocom' proto: stable, SMS-safe (does not
		# touch the modem's SMS) and self-healing. 'atc' and 'xmm' are used ONLY
		# when the user explicitly selects them AND the handler is installed -
		# atc in particular takes over SMS and holds an AT port open, so making
		# it a silent default caused deregistration/port churn on multi-modem
		# setups. Opt-in keeps auto-detection predictable.
		FPROTO=fibocom
		[ "$REQ" = xmm ] && [ -f /lib/netifd/proto/xmm.sh ] && FPROTO=xmm
		[ "$REQ" = atc ] && [ -f /lib/netifd/proto/atc.sh ] && FPROTO=atc

		if [ "$FPROTO" = atc ]; then
			# atc dials over an AT port and derives the usbnet device itself. It
			# keeps that port open for URC monitoring, so hand it a DIFFERENT AT
			# port than the app's metrics/SMS port to avoid clashing reads.
			METRIC_AT=$(uci -q get 5gmodem.@5gmodem[0].at_port)
			ATCPORT=""
			for t in /sys/bus/usb/devices/$AMP:*/ttyUSB* /sys/bus/usb/devices/$AMP:*/ttyACM*; do
				[ -e "$t" ] || continue
				tt="/dev/$(basename "$t")"
				[ "$tt" = "$METRIC_AT" ] && continue
				sms_tool -d "$tt" at "AT" >/dev/null 2>&1 && { ATCPORT="$tt"; break; }
			done
			[ -n "$ATCPORT" ] || ATCPORT="$METRIC_AT"
			uci set "network.$IF.proto=atc"
			uci set "network.$IF.device=$ATCPORT"
			set_apn_opt "$IF" "$OLDAPN"
			uci set "network.$IF.pdp=IPV4V6"
			uci set "network.$IF.metric=20"
			FDEV="$ATCPORT"
			# remember the atc data port so resolve can re-pin it after renumbering
			[ -n "$MSEC" ] && uci -q set "5gmodem.$MSEC.data_at_port=$ATCPORT"
		else
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.usbpath=$AMP"
			uci set "network.$IF.device=$FNET"
			set_apn_opt "$IF" "$OLDAPN"
			uci set "network.$IF.pdptype=IPV4V6"
			FDEV="$FNET"
		fi
		# secondary uplink by default so (re)creating it never hijacks another
		# modem's default route; lower the metric in Network > Interfaces to make
		# it primary.
		uci set "network.$IF.metric=20"
		uci commit network

		# add to the 'wan' firewall zone for NAT/forwarding. Самолечащий:
		# сперва убираем ВСЕ вхождения $IF (старые версии приложения могли
		# накопить дубликаты - интерфейс появлялся в зоне по 4 раза и столько же
		# раз в «Приоритете интернета»), потом добавляем РОВНО один.
		Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
		if [ -n "$Z" ]; then
			while uci -q get "firewall.$Z.network" | grep -qw "$IF"; do
				uci del_list "firewall.$Z.network=$IF"
			done
			uci add_list "firewall.$Z.network=$IF"
			uci commit firewall
		fi

		# point the app at this interface and remember it for this modem
		uci -q set "5gmodem.@5gmodem[0].network=$IF"
		uci -q set "5gmodem.@5gmodem[0].iface_proto=$FPROTO"
		if [ -n "$MSEC" ]; then
			uci -q get "5gmodem.$MSEC" >/dev/null 2>&1 || { uci -q set "5gmodem.$MSEC=modem"; uci -q set "5gmodem.$MSEC.path=$AMP"; }
			uci -q set "5gmodem.$MSEC.network=$IF"
			uci -q set "5gmodem.$MSEC.iface_proto=$FPROTO"
		fi
		uci -q commit 5gmodem

		# SMS/USSD via the AT port - ModemManager cannot manage this modem
		if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=0"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=0"
			uci -q commit sms_tool_js
		fi

		# NOTE: deliberately leave ModemManager as-is (another modem may need it);
		# the fibocom path uses AT + the usbnet device and does not touch MM.
		# refresh the ModemManager ignore list (fibocom is a kernel proto -> MM
		# must not touch this modem)
		/usr/share/5gmodem/mm-filter.sh >/dev/null 2>&1
		ifup "$IF" >/dev/null 2>&1
		json created "$FPROTO" "$FDEV"
		exit 0
	fi
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

# --- ModemManager service, MULTI-MODEM aware. MM must run if THIS interface OR
# any EXISTING interface uses the modemmanager proto (they need MM). Only
# stop+disable MM when nothing needs it and a kernel proto (mbim/qmi) needs the
# control channel free. Previously this blindly disabled MM for any non-MM proto
# (e.g. creating an atc interface), which took the OTHER modemmanager modems
# down. A restart (when MM must run) also clears a wedged MM. ---
_MM_WANT=0
[ "$PROTO" = "modemmanager" ] && _MM_WANT=1
uci show network 2>/dev/null | grep -q "\.proto='modemmanager'" && _MM_WANT=1
if [ "$_MM_WANT" = "1" ]; then
	/etc/init.d/modemmanager enable >/dev/null 2>&1
	mm_restart_safe
elif [ "$PROTO" = "mbim" ] || [ "$PROTO" = "qmi" ] || uci show network 2>/dev/null | grep -qE "\.proto='(mbim|qmi)'"; then
	/etc/init.d/modemmanager stop >/dev/null 2>&1
	/etc/init.d/modemmanager disable >/dev/null 2>&1
fi

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
set_apn_opt "$IF" "$OLDAPN"
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

# add to the 'wan' firewall zone (if one exists) so NAT/forwarding works.
# Самолечащий (см. выше): убрать все дубликаты $IF, добавить ровно один.
Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
if [ -n "$Z" ]; then
	while uci -q get "firewall.$Z.network" | grep -qw "$IF"; do
		uci del_list "firewall.$Z.network=$IF"
	done
	uci add_list "firewall.$Z.network=$IF"
	uci commit firewall
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

# refresh the ModemManager ignore list for the chosen proto: hide the modem from
# MM for kernel protos (qmi/mbim/...), or let MM see it for the modemmanager proto
/usr/share/5gmodem/mm-filter.sh >/dev/null 2>&1

if [ "$PROTO" = "modemmanager" ]; then
	# ifup ТОЛЬКО после того, как MM реально увидит модем. Сразу после
	# (пере)запуска MM модема ещё нет - он допрашивает порты десятки секунд, - а
	# прото modemmanager в этот момент не находит его, netifd пишет "Device not
	# managed by ModemManager", кладёт интерфейс и БОЛЬШЕ НЕ ПРОБУЕТ. Именно так
	# после пересоздания интерфейса модем оставался registered, но без IP.
	# В ФОНЕ и с отвязанными дескрипторами: скрипт зовут через rpcd (LuCI
	# fs.exec), а тот ждёт EOF на пайпах и упирается в свой 30-секундный таймаут -
	# ожидание в основном потоке дало бы UI "ошибку XHR" при успешной операции.
	(
		_n=0
		while [ "$_n" -lt 120 ]; do
			mmcli -L 2>/dev/null | grep -q "/Modem/" && break
			sleep 2; _n=$((_n + 2))
		done
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null &
else
	ifup "$IF" >/dev/null 2>&1
fi

json created "$PROTO" "$IDEV"
exit 0
