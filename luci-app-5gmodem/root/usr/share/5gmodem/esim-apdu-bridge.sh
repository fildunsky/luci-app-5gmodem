#!/bin/sh
#
# lpac stdio APDU backend -> eUICC via AT (+CCHO/+CGLA/+CCHC), using sms_tool.
#
# Почему так: пропатченный lpac 2.3.0 (AT-драйвер) ВИСНЕТ на FM350-GL (persistent-
# буфер at_expect рассинхронизируется, 20 c/команда), а его stdio-бэкенд в нашей
# сборке НЕ ЧИТАЕТ stdin (euicc_init падает мгновенно). lpac 2.1.x stdio читает
# stdin корректно. Поэтому eSIM гоняем через lpac 2.1.x c LPAC_APDU=stdio, а
# транспорт APDU делаем ЗДЕСЬ по AT - ровно те CCHO/CGLA, что рабочи на FM350
# (CCHO отдаёт голый номер канала "1"; CGLA - стандартный "+CGLA: len,\"hex\"").
# Это порт того, что делает обёртка prusa (EasyLPAC) на Windows.
#
# Протокол (одна JSON-строка на сообщение):
#   lpac -> нам (stdin):  {"type":"apdu","payload":{"func":"...","param":"hex|null"}}
#                         {"type":"lpa","payload":{...}}   <- финальный результат
#   мы -> lpac (stdout):  {"type":"apdu","payload":{"ecode":<n>[, "data":"hex"]}}
#
# Usage: esim-apdu-bridge.sh <at_port> <result_file>
#   Читает запросы lpac со stdin, пишет ответы в stdout, финальный "lpa" - в
#   <result_file> (и завершается).

PORT="$1"
RESULT="$2"
: > "$RESULT"
CH=""

while IFS= read -r line; do
	[ -n "$line" ] || continue
	# Быстрый разбор типа без jsonfilter (на каждую строку - дорого).
	case "$line" in
		*'"type":"apdu"'*) : ;;
		*)  # не apdu -> это финальный результат ("lpa"): пишем и выходим
			printf '%s\n' "$line" >> "$RESULT"
			case "$line" in *'"type":"lpa"'*) exit 0 ;; esac
			continue ;;
	esac
	func=$(printf '%s' "$line" | jsonfilter -e '@.payload.func' 2>/dev/null)
	param=$(printf '%s' "$line" | jsonfilter -e '@.payload.param' 2>/dev/null)
	case "$func" in
	logic_channel_open)
		# param = AID (hex). AT+CCHO="<AID>" -> "+CCHO: N" ИЛИ голый "N" (FM350).
		r=$(sms_tool -d "$PORT" at "AT+CCHO=\"$param\"" 2>/dev/null | tr -d '\r')
		c=$(printf '%s' "$r" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
		[ -n "$c" ] || c=$(printf '%s' "$r" | grep -E '^[0-9]+$' | head -1)
		CH="$c"
		printf '{"type":"apdu","payload":{"ecode":%s}}\n' "${c:--1}" ;;
	logic_channel_close)
		# param = номер канала (hex-байт, напр. "01")
		cc=$(printf '%d' "0x$param" 2>/dev/null)
		[ -n "$cc" ] && sms_tool -d "$PORT" at "AT+CCHC=$cc" >/dev/null 2>&1
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	transmit)
		# param = APDU (hex). AT+CGLA=<канал>,<len_hex_chars>,"<APDU>" -> "+CGLA: n,\"hex\"".
		out=$(sms_tool -d "$PORT" at "AT+CGLA=$CH,${#param},\"$param\"" 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*+CGLA: *[0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p' | head -1)
		printf '{"type":"apdu","payload":{"ecode":0,"data":"%s"}}\n' "$out" ;;
	connect|disconnect|*)
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	esac
done
