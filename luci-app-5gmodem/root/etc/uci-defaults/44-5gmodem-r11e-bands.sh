#!/bin/sh
[ "$(uci -q get 5gmodem.@5gmodem[0].r11e_bands_migrated)" = "1" ] && exit 0
for _s in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[A-Za-z0-9_]*\)\.vidpid='2cd2:0001'\$/\1/p"); do
	for _o in save_band save_band5gnsa save_band5gsa band_full; do
		uci -q delete "5gmodem.$_s.$_o" 2>/dev/null
	done
done
uci -q get 5gmodem.@5gmodem[0] >/dev/null 2>&1 && uci -q set 5gmodem.@5gmodem[0].r11e_bands_migrated=1
uci -q commit 5gmodem
exit 0
