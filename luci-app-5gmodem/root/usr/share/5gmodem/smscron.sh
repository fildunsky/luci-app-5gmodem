#!/bin/sh

CRON=/etc/crontabs/root
MARK=5gmodem-sms-notify
RES=/usr/share/5gmodem

_strip_ours() {
	[ -f "$CRON" ] || { : > "$CRON"; return; }
	grep -v "$MARK" "$CRON" 2>/dev/null | grep -v '^[[:space:]]*$' > "$CRON.tmp" 2>/dev/null
	mv "$CRON.tmp" "$CRON" 2>/dev/null
}

case "$1" in
on)
	H="$2"
	case "$H" in
		''|*[!0-9]*) echo '{"error":"bad interval"}'; exit 2 ;;
	esac
	[ "$H" -ge 1 ] && [ "$H" -le 24 ] || { echo '{"error":"interval out of range"}'; exit 2; }

	_strip_ours
	printf '1 */%s * * * /etc/init.d/%s enable && /etc/init.d/%s restart\n' \
		"$H" "$MARK" "$MARK" >> "$CRON"
	/etc/init.d/cron restart >/dev/null 2>&1
	/etc/init.d/"$MARK" enable >/dev/null 2>&1
	/etc/init.d/"$MARK" start >/dev/null 2>&1
	logger -t 5gmodem "smscron: SMS notifier restart scheduled every ${H}h"
	echo '{"result":"ok","every":'"$H"'}'
	;;
off)
	_strip_ours
	/etc/init.d/cron restart >/dev/null 2>&1
	/etc/init.d/"$MARK" stop >/dev/null 2>&1
	/etc/init.d/"$MARK" disable >/dev/null 2>&1
	logger -t 5gmodem "smscron: SMS notifier schedule removed"
	echo '{"result":"ok"}'
	;;
status)
	_ours=$(grep "$MARK" "$CRON" 2>/dev/null | head -1)
	_every=$(printf '%s' "$_ours" | sed -n 's|^1 \*/\([0-9]*\) .*|\1|p')
	printf '{"enabled":%s,"every":"%s"}\n' \
		"$([ -n "$_ours" ] && echo 1 || echo 0)" "$_every"
	;;
*)
	echo '{"error":"usage: on <hours> | off | status"}'
	exit 2 ;;
esac
exit 0
