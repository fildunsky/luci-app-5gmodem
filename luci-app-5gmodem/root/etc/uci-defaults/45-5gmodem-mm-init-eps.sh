#!/bin/sh
# luci-app-5gmodem: двухстековым интерфейсам ModemManager - начальный EPS-носитель
# по параметрам интерфейса (init_epsbearer=default). Без него штатный
# modemmanager.sh очищает начальный носитель, модем прикрепляется только с IPv4
# и IPv6 не поднимается (см. mkiface.sh). Только proto=modemmanager с
# iptype=ipv4v6 и без своей политики; сеть не перезапускаем - опция вступит в
# силу со следующим подключением интерфейса.

CHANGED=0
for sec in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.proto='modemmanager'$/\1/p"); do
	[ "$(uci -q get "network.$sec.iptype")" = "ipv4v6" ] || continue
	[ -z "$(uci -q get "network.$sec.init_epsbearer")" ] || continue
	uci -q set "network.$sec.init_epsbearer=default"
	CHANGED=1
done
[ "$CHANGED" = 1 ] && uci -q commit network
exit 0
