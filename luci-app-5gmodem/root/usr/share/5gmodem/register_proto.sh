#!/bin/sh
# Зарегистрировать/обновить наш netifd-обработчик протокола
# (/lib/netifd/proto/fibocom.sh) после установки пакета.
#
# ПОЧЕМУ ЭТО НУЖНО. netifd сканирует shell-обработчики протоколов ТОЛЬКО при
# своём старте и держит их в памяти. Ни `/etc/init.d/network reload`, ни
# `ubus call network reload` их НЕ перечитывают (reload лишь перечитывает
# /etc/config/network). А `ubus ... down/up` интерфейса гоняет СТАРЫЙ код
# обработчика. Перечитать обработчик можно ТОЛЬКО рестартом netifd - а он на
# пару секунд роняет ВСЕ интерфейсы. Поэтому делаем его лишь когда реально нужно.
#
# ДВА случая, когда нужен рестарт (оба - только если есть интерфейс на fibocom,
# иначе рестартовать netifd ради неиспользуемого прото незачем):
#   1) Прото ещё НЕ ЗАРЕГИСТРИРОВАН: свежая установка, netifd стартовал раньше,
#      чем появился файл обработчика (ifstatus -> "available": false).
#   2) СОДЕРЖИМОЕ обработчика ИЗМЕНИЛОСЬ с прошлого применения: апгрейд заменил
#      fibocom.sh новой логикой (напр. PDP-fallback), а в памяти netifd - старая.
#      opkg переписывает файл при каждой установке, поэтому «изменилось» ловим не
#      по mtime, а по ХЕШУ: рестарт только когда прото реально другой, а не на
#      каждый апдейт (в т.ч. чисто-UI - модем при нём дёргать не за что).

HANDLER=/lib/netifd/proto/fibocom.sh
STAMP=/etc/5gmodem_proto.md5   # персистентный (не /tmp): переживает перезагрузку

# РЕСТАРТ NETIFD - ТОЛЬКО КОГДА БЕЗ НЕГО ИНТЕРФЕЙС МЁРТВ.
#
# Живой урок 08.08.2026: обновление пакета ПО ZEROTIER. Постинст дошёл сюда,
# хеш обработчика оказался новым - и network restart уронил все интерфейсы
# разом. Wi-Fi-аплинк не переассоциировался, ZeroTier не собрался, и роутер
# пропал из сети до физического вмешательства. Причём хватило СЕКЦИИ
# proto='fibocom' в конфиге от когда-то стоявшего модема - сам модем был
# уже другой.
#
# Поэтому смена СОДЕРЖИМОГО обработчика рестартом больше не лечится вовсе:
# дозвонная логика - шелл-скрипт, netifd запускает его С ДИСКА при каждом
# дозвоне, то есть новый код возьмётся сам на ближайшем передозвоне. В памяти
# netifd живут только регистрация и метаданные dump - они дождутся штатной
# перезагрузки. Рестарт остаётся ровно для случаев, когда прото НЕ
# ЗАРЕГИСТРИРОВАН - интерфейс на нём и так мёртв («Не поддерживаемый тип
# протокола»), хуже не сделать.
NEED=0
HAS_FIBO=0
for _if in $(uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([^.]*\)\.proto='fibocom'\$/\1/p"); do
	HAS_FIBO=1
	_av=$(ubus call network.interface."$_if" status 2>/dev/null \
		| jsonfilter -e '@.available' 2>/dev/null)
	[ "$_av" = "false" ] && NEED=1
done

# ПРОТО НЕИЗВЕСТЕН NETIFD, А ИНТЕРФЕЙСА НЕТ - РЕСТАРТ ТОЛЬКО ПО ЯВНОЙ ПРОСЬБЕ.
#
# История в两 шага. Сначала рестарта без интерфейса не было вовсе - и на свежей
# установке LuCI показывала «Не поддерживаемый тип протокола» до ребута (список
# прото LuCI берёт у netifd). В 2.3.3 рестарт сделали безусловным - и это
# уронило УДАЛЁННЫЙ роутер (08.08.2026): месяцы аптайма, netifd стартовал до
# самой первой установки пакета, Fibocom-модема НЕ БЫЛО НИКОГДА - а обновление
# всё равно передёрнуло сеть; NAT-путь ZeroTier протух, реле в той сети режет
# ТСПУ, и доступ пропал при «онлайн» в контроллере.
#
# Поэтому теперь так: postinst сам по себе сеть ради голой регистрации НЕ
# рестартует. Рестарт делает СОЗДАНИЕ fibocom-интерфейса (mkiface зовёт нас с
# REGISTER_PROTO_FORCE=1) - в этот момент человек настраивает модем, ждёт
# именно этого и почти наверняка сидит рядом.
if [ -r "$HANDLER" ] && ! ubus call network get_proto_handlers 2>/dev/null \
		| grep -q '"fibocom"'; then
	if [ "$REGISTER_PROTO_FORCE" = "1" ] || [ "$HAS_FIBO" = "1" ]; then
		NEED=1
	else
		logger -t 5gmodem "register_proto: proto fibocom is not registered, but no interfaces use it - leaving the network alone (registration will happen on interface creation or after a reboot)"
	fi
fi

CUR=""
[ -r "$HANDLER" ] && CUR=$(md5sum "$HANDLER" 2>/dev/null | awk '{print $1}')
if [ "$HAS_FIBO" = 1 ] && [ -n "$CUR" ] \
   && [ "$CUR" != "$(cat "$STAMP" 2>/dev/null)" ]; then
	logger -t 5gmodem "register_proto: fibocom handler updated; dialing will pick up the new code from disk, metadata after a reboot (not restarting the network for this)"
fi

# qmiraw (наш raw-ip QMI для SimCom) - та же логика регистрации, без слежения за
# содержимым (дозвон делает uqmi, не наш шелл): рестарт netifd лишь когда есть
# интерфейс на qmiraw, а netifd про прото не знает - тогда интерфейс и так мёртв.
HAS_QMIRAW=0
for _if in $(uci -q show network 2>/dev/null \
		| sed -n "s/^network\.\([^.]*\)\.proto='qmiraw'\$/\1/p"); do
	HAS_QMIRAW=1
done
if [ -r /lib/netifd/proto/qmiraw.sh ] && ! ubus call network get_proto_handlers 2>/dev/null \
		| grep -q '"qmiraw"'; then
	if [ "$REGISTER_PROTO_FORCE" = "1" ] || [ "$HAS_QMIRAW" = "1" ]; then
		NEED=1
	fi
fi

if [ "$NEED" = "1" ]; then
	logger -t 5gmodem "register_proto: our proto is not registered in netifd - restarting the network (interfaces will briefly drop)"
	/etc/init.d/network restart >/dev/null 2>&1
fi

# Запоминаем хеш С ДИСКА: это то содержимое, которое возьмёт и ближайший
# дозвон, и netifd после перезагрузки.
[ -n "$CUR" ] && printf '%s\n' "$CUR" > "$STAMP" 2>/dev/null
exit 0
