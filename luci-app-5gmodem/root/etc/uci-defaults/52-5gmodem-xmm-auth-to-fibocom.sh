#!/bin/sh

[ -f /etc/config/network ] || exit 0
[ -f /usr/share/5gmodem/mkiface.sh ] || exit 0
for s in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='\{0,1\}xmm'\{0,1\}$/\1/p"); do
	[ -n "$(uci -q get "network.$s.username")" ] || continue
	logger -t 5gmodem "migration: interface $s has a PAP/CHAP login on proto xmm, recreating it on fibocom"
	setsid sh -c "sleep 60; /bin/sh /usr/share/5gmodem/mkiface.sh '$s' fibocom" </dev/null >/dev/null 2>&1 &
done
exit 0
