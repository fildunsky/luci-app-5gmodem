#!/bin/sh
#
# Один вход для чтения SMS, независимо от того, чем модем управляется.
#
# ЗАЧЕМ. У модемов без AT-портов (HiLink: Huawei E3372h и родня) sms_tool
# неприменим - разговаривать не с чем. Их сообщения лежат в самом модеме и
# достаются его HTTP-API. Страницам про это знать незачем, поэтому решение
# принимается здесь, а наружу отдаётся ОДИН И ТОТ ЖЕ формат - тот, что даёт
# `sms_tool -j`.
#
# Для обычного модема вызов проксируется в sms_tool БЕЗ ИЗМЕНЕНИЙ - с теми же
# аргументами, что раньше слал интерфейс. Так рабочий путь остаётся ровно тем
# же, а новая ветка добавляется рядом, а не поверх.
#
# Usage: smsbridge.sh recv|sent [store] [port]

RES=/usr/share/5gmodem
CFG=5gmodem

# ЧАСОВОЙ ПОЯС НЕ ЧИНИМ ЗДЕСЬ. sms_tool печатает время SMS в UTC и ИГНОРИРУЕТ
# $TZ (проверено на живом порту: и TZ=MSK-3, и TZ=UTC0 дают одинаковый +0000).
# Перевод в местное время делает фронтенд (readsms.js sms_localtime): у него
# есть пояс пользователя, а он может быть даже точнее пояса роутера.

_active_kind() {
	_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_p" ] || return 1
	uci -q get "$CFG.m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g').kind"
}

_smstool() {
	command -v sms_tool >/dev/null 2>&1 && echo /usr/bin/sms_tool || echo sms_tool
}

BOX="${1:-recv}"
STORE="$2"
PORT="$3"

# Есть AT-порт (режим debug) - обычный путь: sms_tool умеет больше, чем API.
_sb_p=$(uci -q get "5gmodem.@5gmodem[0].at_port")
if [ "$(_active_kind)" = "hilink" ] && ! { [ -n "$_sb_p" ] && [ -c "$_sb_p" ]; }; then
	case "$BOX" in
		sent) "$RES/hilink.sh" smsread out ;;
		status)
			# Страница разбирает СТРОКУ формата sms_tool: "Storage type: ME,
			# used: N, total: M" - позиции подстрок в ней зашиты в разборе.
			# Поэтому отдаём ровно её, а не JSON.
			_c=$("$RES/hilink.sh" smscount 2>/dev/null | tr -d '\r')
			_u=$(printf '%s' "$_c" | sed -n 's|.*<LocalInbox>\(.*\)</LocalInbox>.*|\1|p')
			_m=$(printf '%s' "$_c" | sed -n 's|.*<LocalMaxInbox>\(.*\)</LocalMaxInbox>.*|\1|p')
			[ -n "$_u" ] || _u=0
			[ -n "$_m" ] || _m=100
			echo "Storage type: ME, used: $_u, total: $_m"
			;;
		*)    "$RES/hilink.sh" smsread in ;;
	esac
	exit 0
fi

# Обычный модем - прежний путь. Порт берём из аргумента, иначе из настроек.
[ -n "$PORT" ] || PORT=$(uci -q get sms_tool_js.@sms_tool_js[0].readport)
[ -n "$PORT" ] || PORT=$("$RES/detect.sh" 2>/dev/null)
# Порта нет вовсе - отдаём пустой список, а не ошибку: страница покажет
# «сообщений нет», и это честнее, чем красный текст про несуществующий /dev.
[ -n "$PORT" ] || { echo "[]"; exit 0; }

# Ждём своей очереди к порту: чтение SMS идёт параллельно опросу метрик, и без
# этого списки приходили обрезанными, а в текст сообщения попадали чужие ответы.
# Блокировку снимет ядро при выходе. Не дождались - идём как раньше: потерять
# сообщения хуже, чем рискнуть смешением.
. "$RES/atlock.sh"
at_lock "$PORT" 15

set -- -d "$PORT" -f '%Y-%m-%d %H:%M' -j
[ -n "$STORE" ] && set -- -s "$STORE" "$@"
case "$BOX" in
	status) exec $(_smstool) -d "$PORT" ${STORE:+-s "$STORE"} status 2>/dev/null ;;
	sent)   exec $(_smstool) "$@" recv SR 2>/dev/null ;;
	*)      exec $(_smstool) "$@" recv 2>/dev/null ;;
esac
