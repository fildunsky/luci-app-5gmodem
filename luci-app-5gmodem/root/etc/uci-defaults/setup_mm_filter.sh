#!/bin/sh
# luci-app-5gmodem: перевод «скрытия от ModemManager» с udev-правил на инхибицию.
#
# Раньше этим занимался mm-filter.sh: он писал
# /etc/udev/rules.d/99-5gmodem-mm-ignore.rules с ENV{ID_MM_DEVICE_IGNORE}="1".
# На OpenWrt это НЕ РАБОТАЕТ и работать не может: в системе стоит libudev-zero
# (даёт libudev-API, но не запускает udevd и НЕ читает файлы правил), а udevadm
# отсутствует вовсе. Проверено на живом роутере: правило для модема в файле есть,
# а свойства ID_MM_DEVICE_IGNORE у устройства нет. Следствие: MM спокойно
# захватывал модем на qmi/mbim, отбирал у ядра управляющий канал, и интерфейс
# оставался без IP.
#
# Теперь механизм один - mm-inhibit.sh (mmcli --inhibit-device по СТАБИЛЬНОМУ
# sysfs-пути), а решение «прятать или нет» хранится ПОМОДЕМНО в
# 5gmodem.m_<путь>.mm_exclude и переключается галкой в настройках модема.
#
# Здесь: 1) убираем мёртвые правила и сам mm-filter.sh (могли остаться от прежних
# версий), 2) проставляем mm_exclude уже настроенным модемам по их текущему
# протоколу - чтобы после обновления поведение не изменилось молча.

rm -f /etc/udev/rules.d/99-5gmodem-mm-ignore.rules 2>/dev/null
rm -f /usr/share/5gmodem/mm-filter.sh 2>/dev/null

_is_kernel_proto() {
	case "$1" in qmi|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom) return 0 ;; *) return 1 ;; esac
}

for SEC in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.=]*\)=modem\$/\1/p"); do
	# уже выставлено (в т.ч. вручную галкой) - не трогаем
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

# применить сразу, не дожидаясь прохода демона
[ -x /usr/share/5gmodem/mm-inhibit.sh ] && /usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 &

exit 0
