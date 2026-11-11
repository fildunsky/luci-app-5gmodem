#!/bin/sh
set -eu
src=${1:-$(dirname "$0")/../root/usr/share/5gmodem/modem/usb/_quectel_qrsrp}
DEVICE=/dev/test
sms_tool() {
 case "$*" in
  *qrsrp*) printf '+QRSRP: -86,-113,-140,-140,LTE\n' ;;
  *qrsrq*) printf '%s\n' "$QUALITY" ;;
 esac
}
check() {
 QUALITY=$1; export QUALITY
 ANTPORTS= RXDIV= _QA_READ_RSRQ=1
 . "$src"
 [ "$ANTPORTS" = "$2" ] || { printf 'wrong ports: %s\n' "$ANTPORTS" >&2; exit 1; }
 [ "$RXDIV" = 2rx ] || exit 1
}
check '+QRSRQ: -10,-8,-32768,-32768,LTE' '0:-86:-10 1:-113:-8'
check '+QRSRQ: -10,-32768,-32768,-32768,LTE' '0:-86:-10 1:-113:'
check '+QRSRQ: -10,-8,-32768,-32768,NR5G' '0:-86: 1:-113:'
check 'ERROR' '0:-86: 1:-113:'
printf 'PASS Quectel per-chain RSRQ\n'
