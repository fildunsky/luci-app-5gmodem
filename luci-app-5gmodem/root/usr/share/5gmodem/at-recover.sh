#!/bin/sh
RES=/usr/share/5gmodem
RUN=/tmp/5gmodem
PORT="$1"
case "$PORT" in /dev/ttyUSB*) ;; *) exit 0 ;; esac
case "${PORT#/dev/ttyUSB}" in ''|*[!0-9]*) exit 0 ;; esac
iface=$(readlink -f "/sys/class/tty/${PORT##*/}/device" 2>/dev/null)
level=0
while [ ! -f "$iface/bInterfaceNumber" ] && [ "$level" -lt 3 ]; do
	iface=${iface%/*}; level=$((level + 1))
done
[ "$(cat "$iface/bInterfaceNumber" 2>/dev/null)" = 06 ] || exit 0
usb=${iface%/*}; path=${usb##*/}
[ "$(cat "$usb/idVendor" 2>/dev/null):$(cat "$usb/idProduct" 2>/dev/null)" = 0e8d:7127 ] || exit 0
driver=$(readlink -f "$iface/driver" 2>/dev/null)
case "${driver##*/}" in option|option1) ;; *) exit 0 ;; esac
[ -w "$driver/unbind" ] && [ -w "$driver/bind" ] || exit 0
sec="m_$(printf '%s' "$path" | sed 's/[^A-Za-z0-9]/_/g')"
network=$(uci -q get "5gmodem.$sec.network")
case "$(uci -q get "network.$network.proto")" in fibocom|ncm|atc|xmm|3g|wwan) ;; *) exit 0 ;; esac
. "$RES/atlock.sh"
at_long_busy "$PORT" && exit 0
mkdir -p "$RUN"
key="atrecover_$sec"
exec 9>"$RUN/$key.lock"
flock -n 9 || exit 0
now=$(cut -d. -f1 /proc/uptime)
devnum=$(cat "$usb/devnum" 2>/dev/null)
case "$now:$devnum" in *[!0-9:]*|:*) exit 0 ;; esac
[ -n "$devnum" ] || exit 0
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
	[ "$(cat "$proc/comm" 2>/dev/null)" = sms_tool ] || continue
	set -- $(cat "$proc/stat" 2>/dev/null)
	[ "$3" = D ] || continue
	candidate=${22}
	case "$candidate" in ''|*[!0-9]*) continue ;; esac
	tr '\0' '\n' < "$proc/cmdline" 2>/dev/null | awk -v port="$PORT" '
		previous=="-d" && $0==port {found=1} {previous=$0} END {exit !found}' || continue
	if [ -z "$start" ] || [ "$candidate" -lt "$start" ]; then
		pid=${proc##*/}; start=$candidate
	fi
done
[ -n "$pid" ] || { rm -f "$RUN/$key.seen"; exit 0; }
seen_dev=""; seen_pid=""; seen_start=""; seen_at=0
[ -r "$RUN/$key.seen" ] && read -r seen_dev seen_pid seen_start seen_at < "$RUN/$key.seen"
case "$seen_at" in ''|*[!0-9]*) seen_at=0 ;; esac
if [ "$seen_dev:$seen_pid:$seen_start" != "$devnum:$pid:$start" ]; then
	printf '%s %s %s %s\n' "$devnum" "$pid" "$start" "$now" > "$RUN/$key.seen"
	exit 0
fi
[ "$((now - seen_at))" -ge 30 ] || exit 0
[ "$(cat "$usb/devnum" 2>/dev/null)" = "$devnum" ] \
	&& [ "$(readlink -f "$iface/driver" 2>/dev/null)" = "$driver" ] \
	&& [ "$(cat "$usb/idVendor" 2>/dev/null):$(cat "$usb/idProduct" 2>/dev/null):$(cat "$iface/bInterfaceNumber" 2>/dev/null)" = 0e8d:7127:06 ] || exit 0
set -- $(cat "/proc/$pid/stat" 2>/dev/null)
[ "$3" = D ] && [ "${22}" = "$start" ] || exit 0
at_long_busy "$PORT" && exit 0
printf '%s %s %s\n' "$devnum" "$now" "$((count + 1))" > "$RUN/$key.attempt"
logger -t 5gmodem "AT recovery: FM350 $path has sms_tool $pid in D on $PORT for repeated failures - rebinding serial interface ${iface##*/} (attempt $((count + 1))/3)"
printf '%s' "${iface##*/}" > "$driver/unbind" || exit 1
sleep 2
[ "$(cat "$usb/devnum" 2>/dev/null)" = "$devnum" ] \
	&& [ "$(cat "$usb/idVendor" 2>/dev/null):$(cat "$usb/idProduct" 2>/dev/null)" = 0e8d:7127 ] || exit 0
printf '%s' "${iface##*/}" > "$driver/bind" || exit 1
snap=$(printf '%s\n' "$path" | tr -c 'A-Za-z0-9' '_')
rm -f "$RUN/$key.seen" "$RUN/portok_$snap" "$RUN/listmodems.cache" "$RUN/listmodems.stamp"
logger -t 5gmodem "AT recovery: FM350 $path serial interface rebound; waiting for the next AT poll to confirm recovery"
