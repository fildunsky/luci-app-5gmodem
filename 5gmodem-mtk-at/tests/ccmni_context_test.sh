#!/bin/sh
set -eu
src=${1:-$(cd "$(dirname "$0")/.." && pwd)/root/lib/netifd/proto/ccmni.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Load the production protocol without the device-specific environment.
eval "$(sed '/^\. \/usr\/share\/5gmodem\/mtk\/env.sh$/d' "$src" | sed '/^\[ -n "\$INCLUDE_ONLY" \] || {/,/^}/d')"
MTK_USOCK=/bin/true
MTK_SOCK=$work/port
: > "$MTK_SOCK"
sleep() { :; }
json_get_vars() { ifname=ccmni0; apn=$wanted_apn; pdptype=$wanted_pdp; regtimeout=1; at_device=; }
proto_notify_error() { echo "$2" > "$work/error"; }
ccmni_at() {
 printf '%s\n' "$1" >> "$work/commands"
 case "$1" in
  AT) echo OK ;;
  'AT+CPIN?') echo '+CPIN: READY' ;;
  'AT+CFUN?') printf '+CFUN: %s\n' "$initial_cfun" ;;
  'AT+CEREG?')
   if [ "$(cat "$work/registered")" = 1 ]; then echo '+CEREG: 2,1'; else echo '+CEREG: 2,2'; fi ;;
  'AT+CGDCONT?') cat "$work/context" ;;
  AT+EFUN=0) echo 0 > "$work/registered"; echo OK ;;
  AT+CGDCONT=*)
   if [ "$reject_write" = 1 ]; then echo ERROR; else echo "$1" > "$work/written"; echo OK; fi ;;
  AT+EFUN=1) echo 1 > "$work/registered"; echo OK ;;
  'AT+CGPADDR=0') : ;;
  *) echo OK ;;
 esac
}
run_case() {
 rm -f "$work/error" "$work/written"
 : > "$work/commands"
 echo "$initial_registered" > "$work/registered"
 printf '+CGDCONT: 0, "%s", "%s", "0.0.0.0"\n' "$current_pdp" "$current_apn" > "$work/context"
 if proto_ccmni_setup wan >/dev/null; then echo 'unexpected setup success without address'; exit 1; fi
}
assert_write() {
 [ "$(cat "$work/written")" = "AT+CGDCONT=0,\"$1\",\"$2\"" ]
 # The context must be written before the first radio attach, never after registration waits.
 awk '/^AT\+CGDCONT=/{written=1} /^AT\+EFUN=1$/{if (!written) exit 1; attached=1} END {if (!attached) exit 1}' "$work/commands"
 [ "$(cat "$work/error")" = NO_ADDRESS ]
}
initial_cfun=1 initial_registered=0 current_pdp=IP current_apn=placeholder.invalid wanted_pdp=IPV4V6 wanted_apn= reject_write=0
run_case; assert_write IPV4V6 ''
# A configured APN replaces even a different modem context before registration.
wanted_apn=private.example
run_case; assert_write IPV4V6 private.example
# A radio already off needs no extra shutdown.
initial_cfun=4
run_case; assert_write IPV4V6 private.example
! grep -q '^AT+EFUN=0$' "$work/commands"
# Unspecified PDP preserves the modem type; automatic APN still clears stale data.
initial_cfun=1 wanted_pdp= wanted_apn=
run_case; assert_write IP ''
# A matching active context is left untouched.
initial_registered=1 current_pdp=IPV4V6 current_apn= wanted_pdp=IPV4V6
run_case
[ ! -e "$work/written" ]
! grep -q '^AT+EFUN=' "$work/commands"
# A rejected context write must not start attaching with the old context.
initial_registered=0 current_apn=placeholder.invalid reject_write=1
run_case
[ "$(cat "$work/error")" = ATTACH_CONTEXT_FAILED ]
! grep -q '^AT+EFUN=1$' "$work/commands"
echo 'PASS: ccmni attach context (6 scenarios)'
