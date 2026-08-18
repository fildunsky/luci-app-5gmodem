#!/bin/sh
#
# Apply fixed TTL / hop-limit on the modem network interface.
# Usage:
#   ttl.sh apply   - rebuild our own nft table (inet modem5g_ttl) from uci
#   ttl.sh get     - print current values + detected device as JSON
#
# TTL values live in uci: 5gmodem.@5gmodem[0].{ttl4in,ttl4out,ttl6in,ttl6out}
# Empty value = leave that direction/family untouched.
#

CFG=5gmodem
# Файл СТАРОГО механизма (инклюд fw4). Больше НЕ пишется - только удаляется:
# он ломал сборку fw4 на холодном старте, подробности в ветке apply.
NFT=/etc/nftables.d/10-5gmodem-ttl.nft

modem_iface() {
	# configured interface first, then the first control-proto interface
	I=$(uci -q get $CFG.@5gmodem[0].network)
	if [ -z "$I" ]; then
		for P in modemmanager qmi mbim ncm wwan; do
			I=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='$P'\$/\1/p" | head -1)
			[ -n "$I" ] && break
		done
	fi
	echo "$I"
}

l3dev() {
	ifstatus "$1" 2>/dev/null | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1
}

case "$1" in
set)
	# ttl.sh set <ttl4in> <ttl4out> <ttl6in> <ttl6out>  (empty = off)
	for f in ttl4in:2 ttl4out:3 ttl6in:4 ttl6out:5; do
		k=${f%%:*}; n=${f##*:}; eval v="\$$n"
		case "$v" in ''|*[!0-9]*) uci -q delete $CFG.@5gmodem[0].$k;; *) uci set $CFG.@5gmodem[0].$k="$v";; esac
	done
	uci commit $CFG
	"$0" apply
	;;
get)
	IFACE=$(modem_iface)
	DEV=$(l3dev "$IFACE")
	DEF4=$(sysctl -n net.ipv4.ip_default_ttl 2>/dev/null); [ -n "$DEF4" ] || DEF4=64
	DEF6=$(sysctl -n net.ipv6.conf.all.hop_limit 2>/dev/null); [ -n "$DEF6" ] || DEF6=64
	# Сколько пакетов реально прошло через наши правила: 0 при заданном TTL =
	# правило есть, но трафик мимо (не то устройство/интерфейс не поднят).
	HITS=$(nft list ruleset 2>/dev/null | awk '/ttl set|hoplimit set/ {
		for (i = 1; i <= NF; i++) if ($i == "packets") { s += $(i + 1); break } } END { print s + 0 }')
	printf '{"iface":"%s","device":"%s","def4":"%s","def6":"%s","hits":"%s","ttl4in":"%s","ttl4out":"%s","ttl6in":"%s","ttl6out":"%s"}\n' \
		"$IFACE" "$DEV" "$DEF4" "$DEF6" "$HITS" \
		"$(uci -q get $CFG.@5gmodem[0].ttl4in)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl4out)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl6in)" \
		"$(uci -q get $CFG.@5gmodem[0].ttl6out)"
	;;

apply)
	IFACE=$(modem_iface)
	DEV=$(l3dev "$IFACE")
	T4I=$(uci -q get $CFG.@5gmodem[0].ttl4in)
	T4O=$(uci -q get $CFG.@5gmodem[0].ttl4out)
	T6I=$(uci -q get $CFG.@5gmodem[0].ttl6in)
	T6O=$(uci -q get $CFG.@5gmodem[0].ttl6out)

	# СТАРЫЙ МЕХАНИЗМ (инклюд fw4) ЛОМАЛ ФАЕРВОЛ НА БУТЕ - убираем его файл.
	#
	# fw4 в 25.12 ставит пользовательские инклюды РАНЬШЕ объявлений собственных
	# чейнов. Наш инклюд объявлял «chain mangle_prerouting { правило }» БЕЗ
	# type/hook: на свежесозданной таблице (холодный старт) nft заводил его
	# ОБЫЧНЫМ чейном, а когда ниже по файлу fw4 объявлял его же базовым - падал
	# с «Chain of type "filter" is not supported» и nft отвергал ВЕСЬ рулсет.
	# Роутер оставался вовсе без таблицы fw4: masquerade нет, «на роутере инет
	# есть, на клиентах нет». Тумблер TTL выкл/вкл «лечил», потому что при
	# перезагрузке БЕЗ инклюда таблица создавалась, а поверх ЖИВОЙ таблицы
	# слияние проходит (flush table не трогает типы чейнов) - до следующего
	# ребута. Воспроизведено на стенде, подтверждено минимальным t4.nft.
	if [ -f "$NFT" ]; then
		rm -f "$NFT"
		fw4 reload >/dev/null 2>&1
	fi

	# Правила живут в СВОЕЙ таблице (как у clash): не зависят от порядка сборки
	# fw4 и переживают его перезагрузки (fw4 чистит только table inet fw4).
	# Идиома «объявить - flush - объявить с правилами» атомарно заменяет
	# содержимое и работает и на первом запуске, и на повторном.
	if [ -n "$DEV" ] && [ -n "$T4I$T4O$T6I$T6O" ]; then
		TMP="/tmp/5gmodem_ttl.$$.nft"
		{
			echo "table inet modem5g_ttl"
			echo "flush table inet modem5g_ttl"
			echo "table inet modem5g_ttl {"
			echo "	chain prerouting {"
			echo "		type filter hook prerouting priority mangle; policy accept;"
			# counter в правиле - НЕ украшение: без него «работает ли TTL» нельзя
			# ни увидеть, ни доказать. Проверять пингом с роутера бесполезно -
			# ping показывает TTL ОТВЕТНОГО пакета (сколько хопов осталось от
			# сервера), а мы правим ttl УХОДЯЩИХ, и снаружи его видит только
			# оператор. Со счётчиком достаточно посмотреть, растут ли пакеты.
			[ -n "$T4I" ] && echo "		iifname \"$DEV\" counter ip ttl set $T4I"
			[ -n "$T6I" ] && echo "		iifname \"$DEV\" counter ip6 hoplimit set $T6I"
			echo "	}"
			echo "	chain postrouting {"
			echo "		type filter hook postrouting priority mangle; policy accept;"
			[ -n "$T4O" ] && echo "		oifname \"$DEV\" counter ip ttl set $T4O"
			[ -n "$T6O" ] && echo "		oifname \"$DEV\" counter ip6 hoplimit set $T6O"
			echo "	}"
			echo "}"
		} > "$TMP"
		if ! nft -f "$TMP" 2>/dev/null; then
			logger -t 5gmodem "ttl: nft rejected the rules (check: nft -c -f $TMP)"
			echo "FAIL"
			exit 1
		fi
		rm -f "$TMP"
	else
		nft delete table inet modem5g_ttl 2>/dev/null
	fi
	echo "OK"
	;;

*)
	echo "usage: $0 apply|get" >&2
	exit 1
	;;
esac
