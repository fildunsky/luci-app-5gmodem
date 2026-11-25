#!/bin/sh

# Only sessions present during installation are expired. The in-app updater signs out
# after refreshing its assets and must retain its session until that work finishes.
[ -z "$IPKG_INSTROOT" ] || exit 0
for fd in $(ls /proc/self/fd 2>/dev/null); do
	[ "$fd" -gt 2 ] 2>/dev/null && eval "exec $fd>&-"
done
update_active() {
	local pid
	read -r pid < /tmp/5gmodem/update.pid 2>/dev/null || return 1
	case "$pid" in ''|*[!0-9]*) return 1 ;; esac
	kill -0 "$pid" 2>/dev/null
}
update_active && exit 0

sessions=$(ubus -t 3 call session list 2>/dev/null \
	| jsonfilter -a -e '@[@.data.token].ubus_rpc_session' 2>/dev/null)
[ -n "$sessions" ] || exit 0

# Walk the post-install caller's ancestry before it exits, then let apk/opkg finish
# its whole transaction so LuCI can receive the installation result first.
parent="$1"
installer=""
while [ -n "$parent" ] && [ "$parent" != 1 ]; do
	case "$parent" in *[!0-9]*) break ;; esac
	read -r name < "/proc/$parent/comm" 2>/dev/null || break
	case "$name" in apk|opkg) installer="$parent"; break ;; esac
	parent=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$parent/status" 2>/dev/null)
done
while [ -n "$installer" ] && kill -0 "$installer" 2>/dev/null; do
	update_active && exit 0
	sleep 1
done
sleep 5
update_active && exit 0

for session in $sessions; do
	case "$session" in ''|*[!0-9a-f]*) continue ;; esac
	[ "${#session}" = 32 ] && [ "$session" != 00000000000000000000000000000000 ] || continue
	ubus -t 3 call session destroy "{\"ubus_rpc_session\":\"$session\"}" >/dev/null 2>&1
done
exit 0
