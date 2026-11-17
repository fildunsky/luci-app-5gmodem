#!/bin/sh
set -eu
src=${1:-$(dirname "$0")/../root/usr/share/5gmodem/modemband/2c7c0620}
. "$src"
_DEVICE=/dev/test
sms_tool() {
 case "$*" in
  *'mode_pref",'*) printf '%s\n' "$*" ;;
  *mode_pref*) printf '+QNWPREFCFG: "mode_pref",%s\n' "${RAT:-AUTO}" ;;
  *'common/4g",'*) [ "${FAIL:-0}" = 0 ] ;;
  *common/4g*) printf '%s\n' "${LOCK:-+QNWLOCK: \"common/4g\",0}" ;;
 esac
}
logger() { :; }
[ "$(getsupportedmodes)" = '0:Auto 1:3G 2:4G' ]
for pair in AUTO:0 WCDMA:1 LTE:2; do
 RAT=${pair%:*}; export RAT
 [ "$(getmode)" = "${pair#*:}" ]
done
[ "$(setmode 2)" = '-d /dev/test at at+qnwprefcfg="mode_pref",LTE' ]
if setmode 4 >/dev/null; then exit 1; fi
[ "$(getcelllock)" = off ]
LOCK='+QNWLOCK: "common/4g",1,1300,123'; export LOCK
[ "$(getcelllock)" = 'cell 1300 123' ]
LOCK=ERROR; export LOCK
[ "$(getcelllock)" = Unsupported ]
setcelllock cell 1300 123
setcelllock off
if setcelllock cell 1300 504 >/dev/null; then exit 1; fi
FAIL=1; export FAIL
if setcelllock cell 1300 123 >/dev/null; then exit 1; fi
if setcelllock off >/dev/null; then exit 1; fi
printf 'PASS EM160 controls\n'
