#!/bin/sh
set -eu
is_modem() { return 0; }
modem_path_for() { echo 2-1; }
modem_section() { :; }
_lm() { printf '[{"path":"2-1","alias":"","product":"%s","vidpid":"2c7c:0801","model":"%s"}]' "$PRODUCT" "$MODEL"; }
src=${1:-$(dirname "$0")/../root/usr/share/5gmodem/netpri.sh}
work=$(mktemp); trap 'rm -f "$work"' EXIT
sed -n '/^model_for() {/,/^ssid_for() {/p' "$src" | sed '$d' > "$work"
. "$work"

check() {
 PRODUCT="$1" MODEL="$2"; export PRODUCT MODEL
 result=$(model_for fixture)
 [ "$result" = "$3" ] || { printf 'expected %s, got %s\n' "$3" "$result" >&2; exit 1; }
}
check RG520N-EU RG520N-EU 'Quectel RG520N-EU'
check RM520N-GL RM520N-GL 'Quectel RM520N-GL'
check 'USB Modem' 'USB Modem' 'Quectel 5G'
check 'USB Modem' RG520N-EU RG520N-EU
printf 'PASS model labels\n'
