#!/bin/sh

. /usr/share/5gmodem/mtk/env.sh
[ "$MTK_MODE" = rild ] && exit 0

mkdir -p /tmp/5gmodem
exec 9>/tmp/5gmodem/mtk-init.lock
flock -n 9 || exit 0

at() { "$MTK_USOCK" "$1" "$2" 3000 2>/dev/null | tr -d '\r '; }

_ok=0
for i in $(seq 1 30); do
	case "$(at "$MTK_SOCK" "AT+CNMI?")" in
		*"+CNMI:2,1,0,0,0"*)
			_ok=$((_ok + 1))
			[ "$_ok" -ge 3 ] && exit 0
			;;
		*)
			_ok=0
			for c in "ATE0" "AT+CMEE=1" "AT+CMGF=0" "AT+CNMI=2,1,0,0,0"; do
				at "$MTK_SOCK" "$c" >/dev/null
			done
			;;
	esac
	sleep 3
done
logger -t 5gmodem "mtk: AT setup did not hold (CNMI)"
exit 0
