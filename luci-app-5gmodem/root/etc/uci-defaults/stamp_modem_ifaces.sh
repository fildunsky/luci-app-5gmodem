#!/bin/sh
# luci-app-5gmodem: проставить существующим интерфейсам штамп владельца.
#
# Связь «модем -> интерфейс» была ОДНОСТОРОННЕЙ (5gmodem.m_<путь>.network). Когда
# секция модема исчезала (кнопка «Забыть», подмена модема), интерфейс оставался
# сиротой на device-ноде (/dev/cdc-wdm0), а ноды не стабильны: следующий модем в
# тот же разъём получал ту же ноду и МОЛЧА наследовал чужие настройки. Живой
# случай: SIM7600 сменили на Telit LM960 - тот подхватил интерфейс с APN
# internet.beeline.ru, хотя в модеме стояла симка Т-Мобайл.
#
# Теперь mkiface.sh пишет в интерфейс network.<if>.modem_path = стабильный
# USB-путь модема. Здесь проставляем штамп тем интерфейсам, что созданы старыми
# версиями: владельца берём из обратной ссылки в конфиге приложения.
#
# Без штампа интерфейс считается «своим» (ensure_iface его чинит) - иначе после
# обновления мы перестали бы поднимать все ранее созданные интерфейсы.

[ -f /etc/config/5gmodem ] || exit 0

CHANGED=0
for sec in $(uci show 5gmodem 2>/dev/null | sed -n 's/^5gmodem\.\(m_[^.=]*\)=modem$/\1/p'); do
	path=$(uci -q get "5gmodem.$sec.path")
	iface=$(uci -q get "5gmodem.$sec.network")
	[ -n "$path" ] && [ -n "$iface" ] || continue
	uci -q get "network.$iface" >/dev/null 2>&1 || continue
	# уже проставлен (в т.ч. новым mkiface.sh) - не трогаем
	[ -n "$(uci -q get "network.$iface.modem_path")" ] && continue
	uci -q set "network.$iface.modem_path=$path"
	CHANGED=1
done

[ "$CHANGED" = 1 ] && uci -q commit network

exit 0
