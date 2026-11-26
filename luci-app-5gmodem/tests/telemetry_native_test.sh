#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
src=$here/../root/usr/share/5gmodem/telemetry.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/ccci" "$work/usb" "$work/pci" "$work/platform"
G5_LIB=$work/lib.sh
export G5_TEST_NODE
cat > "$G5_LIB" <<'LIB'
soc_modem_node() {
 [ "$1" = ccci ] && [ -d "$G5_TEST_NODE" ] || return 1
 printf '%s\n' "$G5_TEST_NODE"
}
LIB
sed "s|/sys/bus/usb/devices/|$work/usb/|g; s|/sys/bus/pci/devices/|$work/pci/|g; s|/sys/bus/platform/devices/|$work/platform/|g" "$src" > "$work/tele.sh"
eval "$(sed -n '/^_tele_node() {/,/^}/p; /^_tele_device() {/,/^}/p' "$work/tele.sh")"
_AM=ccci
G5_TEST_NODE=$work/ccci
[ "$(_tele_node)" = "$work/ccci" ]
[ "$(_tele_device)" = "$(ls -diL "$work/ccci" | awk '{print $1}')" ]
export G5_LIB
{
 printf '_AM=${G5_TEST_AM:-ccci}\n'
 sed -n '/^_tele_node() {/,/^}/p' "$work/tele.sh"
 printf 'tele_enabled() { [ "${G5_TEST_DISABLED:-0}" != 1 ]; }\n_refresh_snap() { echo refresh; }\n_mqtt_args() { [ "${G5_TEST_MQTT:-0}" = 1 ]; }\ntele_write() { echo write; }\ntele_publish() { echo publish; }\n'
 sed -n '/^case "$1" in/,$p' "$work/tele.sh"
} > "$work/tick.sh"
[ "$(sh "$work/tick.sh" tick)" = "$(printf 'refresh\nwrite')" ]
[ "$(G5_TEST_MQTT=1 sh "$work/tick.sh" tick)" = "$(printf 'refresh\npublish')" ]
[ -z "$(G5_TEST_DISABLED=1 sh "$work/tick.sh" tick)" ]
rmdir "$work/ccci"
if _tele_node >/dev/null; then echo 'FAIL: removed native modem'; exit 1; fi
[ -z "$(sh "$work/tick.sh" tick)" ]
for _AM in 1-9 0000:01:00.0 soc-test; do
 case "$_AM" in
  1-9) node=$work/usb/$_AM ;;
  0000*) node=$work/pci/$_AM ;;
  *) node=$work/platform/$_AM/remoteproc ;;
 esac
 mkdir -p "$node"
 [ "$(_tele_node)" = "$node" ]
 [ -n "$(_tele_device)" ]
 [ "$(G5_TEST_AM=$_AM sh "$work/tick.sh" tick)" = "$(printf 'refresh\nwrite')" ]
 rmdir "$node"
 if _tele_node >/dev/null; then echo 'FAIL: removed modem'; exit 1; fi
 [ -z "$(G5_TEST_AM=$_AM sh "$work/tick.sh" tick)" ]
done
_AM=''
if _tele_node >/dev/null; then echo 'FAIL: empty path'; exit 1; fi
_AM=ccci
G5_LIB=$work/no-library
if _tele_node >/dev/null; then echo 'FAIL: no native support'; exit 1; fi

# Existing transports must not depend on loading the native support library.
_AM=1-9
mkdir "$work/usb/$_AM"
[ -n "$(_tele_device)" ]
rmdir "$work/usb/$_AM"

# Exercise the actual native detection functions, not only the mock above.
libsrc=$here/../root/usr/share/5gmodem/lib.sh
G5_LIB=$work/native-lib.sh
{
 printf 'fg360_native() { return 1; }\n'
 sed -n '/^soc_modem_node() {/,/^}/p; /^mtk_soc_modem() {/,/^}/p; /^usb_path_present() {/,/^}/p' "$libsrc" |
  sed "s|/sys/bus/usb/devices/|$work/usb/|g; s|/sys/bus/pci/devices/|$work/pci/|g; s|/sys/bus/platform/devices/|$work/platform/|g; s|/sys/kernel/ccci|$work/native/ccci|g; s|/dev/socket|$work/native/socket|g; s|/dev/ttyC0|$work/native/ttyC0|g"
} > "$G5_LIB"
mkdir -p "$work/native/ccci"
ln -s /dev/null "$work/native/ttyC0"
_AM=ccci
[ "$(_tele_node)" = "$work/native/ccci" ]
[ "$(_tele_device)" = "$(ls -diL "$work/native/ccci" | awk '{print $1}')" ]
( . "$G5_LIB"; usb_path_present ccci )

# Neither a missing snapshot nor an expired one may hide a present device.
_SNAP=$work/metrics_ccci.json
[ ! -e "$_SNAP" ]
[ "$(sh "$work/tick.sh" tick)" = "$(printf 'refresh\nwrite')" ]
printf '%s\n' '{"modem":"Synthetic","signal":"50"}' > "$_SNAP"
printf '0\n' > "${_SNAP%.json}.stamp"
[ -n "$(_tele_device)" ]
[ "$(sh "$work/tick.sh" tick)" = "$(printf 'refresh\nwrite')" ]

native_id=$(_tele_device)
mv "$work/native/ccci" "$work/native/previous-ccci"
mkdir "$work/native/ccci"
[ "$(_tele_device)" != "$native_id" ]
rmdir "$work/native/previous-ccci"

# A stale snapshot must not substitute for the vanished hardware interface.
rm "$work/native/ttyC0"
if _tele_node >/dev/null; then echo 'FAIL: removed native interface'; exit 1; fi
if ( . "$G5_LIB"; usb_path_present ccci ); then echo 'FAIL: native presence'; exit 1; fi
[ -z "$(sh "$work/tick.sh" tick)" ]
echo 'OK: telemetry identity and presence for CCCI, USB, PCIe and platform modems'
