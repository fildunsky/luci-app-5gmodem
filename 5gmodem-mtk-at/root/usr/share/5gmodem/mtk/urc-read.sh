#!/bin/sh

. /usr/share/5gmodem/mtk/env.sh

for i in $(seq 1 60); do
	pidof cmux >/dev/null && [ -c "$MTK_URCTTY" ] && break
	sleep 1
done
stty -F "$MTK_URCTTY" raw -echo clocal </dev/null 2>/dev/null
"$MTK_USOCK" "$MTK_URCTTY" "AT" 2000 >/dev/null 2>&1
CR=$(printf '\r')
while IFS= read -r l; do
	l="${l%$CR}"
	[ -n "$l" ] || continue
	[ "$(wc -c < "$MTK_URC" 2>/dev/null || echo 0)" -lt 65536 ] || : > "$MTK_URC"
	printf '%s\n' "$l" >> "$MTK_URC"
	case "$l" in "+ECELLINFO: 1,"*) printf '%s\n' "$l" > "$MTK_ECI.$$" && mv "$MTK_ECI.$$" "$MTK_ECI" ;; esac
done < "$MTK_URCTTY"
exit 1
