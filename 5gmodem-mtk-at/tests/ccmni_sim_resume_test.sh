#!/bin/sh
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)/root/lib/netifd/proto/ccmni.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
eval "$(sed -n '/^ccmni_attach_packet() {/,/^}/p; /^ccmni_resume_sim() {/,/^}/p' "$src" | sed "s|/tmp/5gmodem/simwait|$work|g")"
sleep() { :; }
ccmni_at() {
 echo "$1" >> "$work/commands"
 case "$1" in
  AT+CGATT=0)
   [ "$detach_fail" = 0 ] || { echo ERROR; return; }
   echo 0 > "$work/attached"; echo OK ;;
  'AT+CGATT?') printf '+CGATT: %s\n' "$(cat "$work/attached")" ;;
  AT+CGATT=1)
   n=$(cat "$work/attempts"); n=$((n+1)); echo "$n" > "$work/attempts"
   if [ "$n" -ge "$ready_after" ]; then
    echo 1 > "$work/attached"; echo OK
   else
    echo '+CME ERROR: 100'
   fi ;;
 esac
}
reset_case() {
 rm -f "$work/wan.resume" "$work/wan.ccmni_resume"
 : > "$work/commands"
 echo 0 > "$work/attempts"
 echo 1 > "$work/attached"
 detach_fail=0; ready_after=3
}
reset_case
ccmni_resume_sim wan
[ ! -s "$work/commands" ]
# Ready events renew the session even when the initial state said attached.
echo 100 > "$work/wan.resume"
ccmni_resume_sim wan >/dev/null
[ "$(cat "$work/attempts")" = 3 ]
[ "$(cat "$work/wan.ccmni_resume")" = 100 ]
[ "$(head -1 "$work/commands")" = AT+CGATT=0 ]
# A redial for the same event must not repeatedly detach a healthy session.
: > "$work/commands"
ccmni_resume_sim wan
[ ! -s "$work/commands" ]
# A later insertion produces another renewal.
echo 200 > "$work/wan.resume"
ccmni_resume_sim wan >/dev/null
[ "$(cat "$work/wan.ccmni_resume")" = 200 ]
[ "$(grep -c '^AT+CGATT=0$' "$work/commands")" = 1 ]
# Transient failure must not consume an event or report successful readiness.
reset_case
echo 300 > "$work/wan.resume"
ready_after=99
if ccmni_resume_sim wan >/dev/null; then echo 'FAIL: attach timeout accepted'; exit 1; fi
[ ! -e "$work/wan.ccmni_resume" ]
[ "$(cat "$work/attempts")" = 12 ]
# A failed detach must not continue with an apparently attached old bearer.
reset_case
echo 400 > "$work/wan.resume"
detach_fail=1
if ccmni_resume_sim wan >/dev/null; then echo 'FAIL: detach failure accepted'; exit 1; fi
[ ! -e "$work/wan.ccmni_resume" ]
[ "$(cat "$work/attempts")" = 0 ]
reset_case
echo 500 > "$work/wan.resume"
ready_after=12
ccmni_resume_sim wan >/dev/null
[ "$(cat "$work/wan.ccmni_resume")" = 500 ]
reset_case
echo invalid > "$work/wan.resume"
ccmni_resume_sim wan
[ ! -s "$work/commands" ]
echo 'PASS: SIM packet session renewal (8 scenarios)'
