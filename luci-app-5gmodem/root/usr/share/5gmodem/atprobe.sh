#!/bin/sh
#
# Bounded AT probe. Exit 0 if the given tty answers "AT" within ~4 seconds,
# else 1.
#
# sms_tool and gcom have NO timeout and block ~35 seconds on a silent DIAG port
# with no reply. That froze the whole info page (every metrics poll ran sms_tool
# on the pinned port) and port auto-detection whenever a wrong/DIAG port was
# selected - the only recovery was editing the config by hand. This helper caps
# the wait by running sms_tool in the background and killing it if it does not
# answer quickly. As a side effect it also rejects DIAG/NMEA ports (they never
# answer AT), so callers get a real AT port.
#
# Usage: atprobe.sh /dev/ttyUSBx   ->   exit 0 = answers AT, exit 1 = no/timeout

D="$1"
[ -n "$D" ] && [ -e "$D" ] || exit 1

# run sms_tool in the background; a killer terminates it after 4s if it hangs.
# 'wait' returns the instant sms_tool finishes, so a good port answers in well
# under a second while a silent one is capped at 4s.
sms_tool -d "$D" at "AT" >/dev/null 2>&1 &
p=$!
( sleep 4; kill "$p" 2>/dev/null ) &
k=$!

wait "$p" 2>/dev/null
rc=$?

kill "$k" 2>/dev/null   # cancel the killer if sms_tool finished first
wait "$k" 2>/dev/null

exit $rc   # 0 when the port answered AT, non-zero on no reply / timeout kill
