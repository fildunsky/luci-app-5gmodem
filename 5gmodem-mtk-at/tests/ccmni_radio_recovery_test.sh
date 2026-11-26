#!/bin/sh
set -eu
src=$(cd "$(dirname "$0")/.." && pwd)/root/lib/netifd/proto/ccmni.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
eval "$(sed -n '/^ccmni_recover_radio() {/,/^}/p' "$src" | sed "s|/tmp/5gmodem/simwait|$work|g")"
ccmni_at() { echo "$1" >> "$work/commands"; return 1; }
: > "$work/commands"
# No SIM insertion event: do not power-cycle anything.
if ccmni_recover_radio wan; then exit 1; fi
[ ! -s "$work/commands" ]
# Power-on can remove the AT port before replying. Record before invoking it.
echo 100 > "$work/wan.resume"
ccmni_recover_radio wan >/dev/null
[ "$(cat "$work/wan.ccmni_radio")" = 100 ]
[ "$(cat "$work/commands")" = AT+EPON ]
# Repeated setup retries cannot loop resets for that event.
if ccmni_recover_radio wan; then exit 1; fi
[ "$(wc -l < "$work/commands")" -eq 1 ]
# Another physical insertion allows one new recovery.
echo 200 > "$work/wan.resume"
ccmni_recover_radio wan >/dev/null
[ "$(wc -l < "$work/commands")" -eq 2 ]
# A completed insertion must not be reused to reset an unrelated later fault.
echo 300 > "$work/wan.resume"
echo 300 > "$work/wan.ccmni_resume"
if ccmni_recover_radio wan; then exit 1; fi
[ "$(wc -l < "$work/commands")" -eq 2 ]
echo invalid > "$work/wan.resume"
if ccmni_recover_radio wan; then exit 1; fi
if ccmni_recover_radio '../invalid'; then exit 1; fi
[ "$(wc -l < "$work/commands")" -eq 2 ]
echo 'PASS: bounded native radio recovery (7 scenarios)'
