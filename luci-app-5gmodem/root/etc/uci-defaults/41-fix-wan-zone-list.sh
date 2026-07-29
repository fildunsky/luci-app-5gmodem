#!/bin/sh
#
# ЧИНИМ ЗОНУ wan, СКЛЕЕННУЮ ПРОШЛОЙ ВЕРСИЕЙ.
#
# Список сетей зоны бывает двух видов, и оба законны:
#     list network 'wan'   list network 'wan6'   <- список
#     option network 'wan wan6'                  <- одна строка
# Прошлые версии добавляли интерфейс модема через `uci add_list`, а он ВТОРОЙ
# вид не разбирает: строка «wan wan6» становилась ОДНИМ элементом списка. Сети с
# таким именем нет, то есть настоящий wan выпадал из зоны - вместе с ним
# пропадал NAT. Роутер при этом работал сам (его трафик в NAT не нуждается), а
# вот локалка оставалась без интернета: ровно та жалоба, с которой это нашлось.
#
# Здесь расклеиваем такие элементы обратно. Правим ТОЛЬКО склеенные - если
# зона в порядке, файл не трогаем вовсе.

Z=$(uci show firewall 2>/dev/null \
	| sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
[ -n "$Z" ] || exit 0

# Элемент с пробелом uci отдаёт в кавычках - по ним и опознаём склейку.
case "$(uci -q get "firewall.$Z.network")" in
	*"'"*) : ;;
	*) exit 0 ;;
esac

CUR=$(uci -q get "firewall.$Z.network" | tr -d "'\"")
uci -q delete "firewall.$Z.network"
for N in $CUR; do
	uci -q get "firewall.$Z.network" 2>/dev/null | grep -qw "$N" && continue
	uci add_list "firewall.$Z.network=$N"
done
uci commit firewall
logger -t 5gmodem "зона wan была склеена в один элемент - расклеил: $CUR"
[ -x /etc/init.d/firewall ] && /etc/init.d/firewall reload >/dev/null 2>&1

exit 0
