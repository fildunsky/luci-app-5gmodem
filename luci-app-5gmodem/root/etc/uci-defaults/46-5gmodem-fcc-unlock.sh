#!/bin/sh
# luci-app-5gmodem: FCC-разблокировка Dell DW5821e / Foxconn T77W968 под
# ModemManager. MM берёт скрипты из /etc/ModemManager/fcc-unlock.d/<vid:pid> и
# зовёт их только когда модем отказал во включении радио. Ссылку ставим, если
# своей у пользователя нет; чужую не трогаем. MM перечитывает каталог при каждой
# попытке - перезапускать его не нужно.

D=/etc/ModemManager/fcc-unlock.d
S=/usr/share/5gmodem/fcc-unlock.sh
[ -x "$S" ] || exit 0
mkdir -p "$D" 2>/dev/null || exit 0
for id in 413c:81d7 413c:81e0 413c:81e4 413c:81e6 413c:81d8 0489:e0b5 0489:e0b4; do
	[ -e "$D/$id" ] || [ -L "$D/$id" ] || ln -s "$S" "$D/$id" 2>/dev/null
done
exit 0
