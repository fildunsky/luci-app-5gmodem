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

if [ "$(_active_kind)" = "hilink" ]; then
	case "$BOX" in
		sent) "$RES/hilink.sh" smsread out ;;
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

set -- -d "$PORT" -f '%Y-%m-%d %H:%M' -j
[ -n "$STORE" ] && set -- -s "$STORE" "$@"
case "$BOX" in
	sent) exec $(_smstool) "$@" recv SR 2>/dev/null ;;
	*)    exec $(_smstool) "$@" recv 2>/dev/null ;;
esac
