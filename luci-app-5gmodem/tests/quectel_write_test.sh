#!/bin/sh
set -u
src=${1:-$(dirname "$0")/../root/usr/share/5gmodem/modemband/_quectel_common2}
_DEVICE=/dev/test
sms_tool() {
 case "$*" in
  *qnwprefcfg*lte_band*,*) return 1 ;;
  *qnwprefcfg*lte_band*) printf '+QNWPREFCFG: "lte_band",8\n'; return 0 ;;
  *qnwlock*common/4g*) [ "${MODE:-fail}" = ok ] && return 0; return 1 ;;
  *save_ctrl*) return 0 ;;
 esac
 return 1
}
. "$src"
result=$(setcelllock cell 3648 439); code=$?
[ "$code" -ne 0 ] && [ "$result" = Unsupported ] || { echo 'FAIL lock transport failure'; exit 1; }
result=$(setcelllock off); code=$?
[ "$code" -ne 0 ] && [ "$result" = Unsupported ] || { echo 'FAIL unlock transport failure'; exit 1; }
MODE=ok; export MODE
setcelllock cell 3648 439 || { echo 'FAIL successful lock'; exit 1; }
_qnw_write lte_band '1 8' && { echo 'FAIL band transport failure'; exit 1; }
echo 'PASS Quectel failed writes'
