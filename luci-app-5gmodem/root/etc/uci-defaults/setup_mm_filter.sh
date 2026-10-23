#!/bin/sh

rm -f /etc/udev/rules.d/99-5gmodem-mm-ignore.rules 2>/dev/null
rm -f /usr/share/5gmodem/mm-filter.sh 2>/dev/null

_is_kernel_proto() {
	case "$1" in qmi|qmiraw|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom) return 0 ;; *) return 1 ;; esac
}

for SEC in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.=]*\)=modem\$/\1/p"); do
	[ -n "$(uci -q get "5gmodem.$SEC.mm_exclude")" ] && continue

	PROTO=""
	IF=$(uci -q get "5gmodem.$SEC.network")
	[ -n "$IF" ] && PROTO=$(uci -q get "network.$IF.proto")
	[ -n "$PROTO" ] || PROTO=$(uci -q get "5gmodem.$SEC.iface_proto")

	if _is_kernel_proto "$PROTO"; then
		uci -q set "5gmodem.$SEC.mm_exclude=1"
	elif [ "$PROTO" = modemmanager ]; then
		uci -q set "5gmodem.$SEC.mm_exclude=0"
	fi
done
uci -q commit 5gmodem

[ -x /usr/share/5gmodem/mm-inhibit.sh ] && /usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 &

exit 0
