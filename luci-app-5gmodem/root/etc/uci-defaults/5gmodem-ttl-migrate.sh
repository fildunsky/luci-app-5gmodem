#!/bin/sh
# Убрать инклюд старого TTL-механизма: он ломал сборку fw4 на холодном старте
# (безтиповый chain до объявлений fw4 -> «Chain of type "filter" is not
# supported» -> роутер без таблицы fw4 и masquerade). Подробности - в ttl.sh.
# Новые правила пересоздаст hotplug (30-5gmodem-ttl) при подъёме модема.
[ -f /etc/nftables.d/10-5gmodem-ttl.nft ] || exit 0
rm -f /etc/nftables.d/10-5gmodem-ttl.nft
fw4 reload >/dev/null 2>&1
exit 0
