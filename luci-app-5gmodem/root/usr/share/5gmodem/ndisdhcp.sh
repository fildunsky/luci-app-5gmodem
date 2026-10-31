#!/bin/sh
case "$1" in
	bound|renew)
		printf 'ip=%s\nmask=%s\ngw=%s\ndns=%s\n' "$ip" "$subnet" "${router%% *}" "$dns" > "$NDIS_LEASE"
		;;
esac
exit 0
