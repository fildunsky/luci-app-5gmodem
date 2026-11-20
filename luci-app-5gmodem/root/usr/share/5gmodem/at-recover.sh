#!/bin/sh
RES=/usr/share/5gmodem
RUN=/tmp/5gmodem
PORT="$1"
case "$PORT" in /dev/ttyUSB*) ;; *) exit 0 ;; esac
case "${PORT#/dev/ttyUSB}" in ''|*[!0-9]*) exit 0 ;; esac

tty_interface() {
	local node level=0
	node=$(readlink -f "/sys/class/tty/${PORT##*/}/device" 2>/dev/null) || return 1
	while [ ! -f "$node/bInterfaceNumber" ] && [ "$level" -lt 3 ]; do
		node=${node%/*}; level=$((level + 1))
	done
	[ "$(cat "$node/bInterfaceNumber" 2>/dev/null)" = 06 ] || return 1
	printf '%s\n' "$node"
}

usb_enumeration() {
	local number inode
	[ "$(cat "$usb/idVendor" 2>/dev/null):$(cat "$usb/idProduct" 2>/dev/null)" = 0e8d:7127 ] || return 1
	number=$(cat "$usb/devnum" 2>/dev/null) || return 1
	inode=$(ls -di "$usb" 2>/dev/null | awk 'NR == 1 { print $1 }')
	case "$number:$inode" in *[!0-9:]*|:*|*:) return 1 ;; esac
	printf '%s:%s\n' "$number" "$inode"
}

native_network() {
	local network
	network=$(uci -q get "5gmodem.$sec.network") || return 1
	case "$(uci -q get "network.$network.proto")" in
		fibocom|ncm|atc|xmm|3g|wwan) return 0 ;;
	esac
	return 1
}

stalled_worker_start() {
	local proc="$1" started
	[ "$(cat "$proc/comm" 2>/dev/null)" = sms_tool ] || return 1
	set -- $(cat "$proc/stat" 2>/dev/null)
	[ "$3" = D ] || return 1
	started=${22}
	case "$started" in ''|*[!0-9]*) return 1 ;; esac
	tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | awk -v port="$PORT" '
		previous=="-d" && $0==port {found=1} {previous=$0} END {exit !found}' || return 1
	printf '%s\n' "$started"
}

iface=$(tty_interface) || exit 0
usb=${iface%/*}; path=${usb##*/}
enumeration=$(usb_enumeration) || exit 0
devnum=${enumeration%%:*}
driver=$(readlink -f "$iface/driver" 2>/dev/null)
case "${driver##*/}" in option|option1) ;; *) exit 0 ;; esac
[ -w "$driver/unbind" ] && [ -w "$driver/bind" ] || exit 0
sec="m_$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/_/g')"
native_network || exit 0
. "$RES/atlock.sh"
at_long_busy "$PORT" && exit 0
mkdir -p "$RUN" || exit 0
key="atrecover_$sec"
exec 9>"$RUN/$key.lock"
flock -n 9 || exit 0
now=$(cut -d. -f1 /proc/uptime)
case "$now" in ''|*[!0-9]*) exit 0 ;; esac
last_dev=""; last=0; count=0
[ -r "$RUN/$key.attempt" ] && read -r last_dev last count < "$RUN/$key.attempt"
case "$last:$count" in *[!0-9:]*|:*|*:) last=0; count=0 ;; esac
if [ "$last_dev" = "$devnum" ]; then
	[ "$count" -lt 3 ] && [ "$((now - last))" -ge 300 ] || exit 0
else
	count=0
fi
pid=""; start=""
for proc in /proc/[0-9]*; do
	candidate=$(stalled_worker_start "$proc") || continue
	if [ -z "$start" ] || [ "$candidate" -lt "$start" ]; then
		pid=${proc##*/}; start=$candidate
	fi
done
[ -n "$pid" ] || exit 0
logger -t 5gmodem "AT recovery: FM350 $path has sms_tool $pid in D on $PORT; checking again in 30s"
sleep 30 || exit 0
[ "$(tty_interface)" = "$iface" ] \
	&& [ "$(usb_enumeration)" = "$enumeration" ] \
	&& [ "$(readlink -f "$iface/driver" 2>/dev/null)" = "$driver" ] || exit 0
native_network || exit 0
at_long_busy "$PORT" && exit 0
[ "$(stalled_worker_start "/proc/$pid")" = "$start" ] || exit 0
now=$(cut -d. -f1 /proc/uptime)
case "$now" in ''|*[!0-9]*) exit 0 ;; esac
printf '%s %s %s\n' "$devnum" "$now" "$((count + 1))" > "$RUN/$key.attempt" || exit 1
logger -t 5gmodem "AT recovery: FM350 $path has sms_tool $pid in D on $PORT for repeated failures - rebinding serial interface ${iface##*/} (attempt $((count + 1))/3)"
if ! printf '%s' "${iface##*/}" > "$driver/unbind"; then
	logger -t 5gmodem "AT recovery: FM350 $path could not unbind serial interface ${iface##*/}"
	exit 1
fi
sleep 2
[ "$(usb_enumeration)" = "$enumeration" ] || exit 0
if ! printf '%s' "${iface##*/}" > "$driver/bind"; then
	logger -t 5gmodem "AT recovery: FM350 $path could not bind serial interface ${iface##*/}"
	exit 1
fi
snap=$(printf '%s\n' "$path" | tr -c 'A-Za-z0-9' '_')
rm -f "$RUN/portok_$snap" "$RUN/listmodems.cache" "$RUN/listmodems.stamp"
logger -t 5gmodem "AT recovery: FM350 $path serial interface rebound; waiting for the next AT poll to confirm recovery"
