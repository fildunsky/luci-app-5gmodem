#!/bin/sh
#
# lpac stdio backend: APDU -> eUICC по AT (+CCHO/+CGLA/+CCHC) через sms_tool,
# и (опционально) HTTP -> ES9+ через wget/OpenSSL.
#
# ЗАЧЕМ HTTP-ветка: libcurl в OpenWrt по умолчанию собран с mbedTLS, а mbedTLS
# отвергает ЛЮБОЕ незнакомое critical-расширение X.509 (-0x2080 "X509 -
# Unavailable feature"). Корень "GSM Association - RSP2 Root CI1" несёт
# "Certificate Policies: critical" (OID 2.23.146.1.2.1.0), поэтому SM-DP+,
# предъявляющие сертификаты GSMA CI (rsp.truphone.com, rsp-eu.redteamobile.com
# и др.), недостижимы: добавить корень в бандл НЕ помогает - mbedTLS не может
# его даже загрузить. SM-DP+ с обычными веб-сертификатами при этом работают,
# отсюда "у одних профилей качается, у других нет". wget слинкован с OpenSSL,
# который такие расширения переносит, и с корнем из certs/gsma-ci.pem проходит
# ES9+ насквозь. Оба stdio-бэкенда мультиплексируют ОДИН поток и различаются
# полем "type", поэтому обслуживаются здесь же.
#
# Почему так: прямой AT-драйвер lpac 2.3.0 ВИСНЕТ на FM350-GL (persistent-буфер
# at_expect рассинхронизируется, 20 c/команда). stdio-бэкенд lpac 2.3.0-fm350-fix
# (исправлен json_request в stdio.c) читает stdin корректно — так же как и lpac
# 2.1.x делал это из коробки. Поэтому eSIM гоняем через lpac >= 2.3.0-fm350-fix
# (или 2.1.x) c LPAC_APDU=stdio, а транспорт APDU делаем ЗДЕСЬ по AT — ровно те
# CCHO/CGLA, что работают на FM350 (CCHO отдаёт голый номер канала "1"; CGLA —
# стандартный "+CGLA: len,\"hex\""). Это порт того, что делает обёртка prusa
# (EasyLPAC) на Windows.
#
# Протокол (одна JSON-строка на сообщение, ndJSON):
#   lpac -> нам (stdin):  {"type":"apdu","payload":{"func":"...","param":"hex|null"}}
#                         {"type":"http","payload":{"url":"...","tx":"hex","headers":[...]}}
#                         {"type":"lpa","payload":{...}}   <- финальный результат
#   мы -> lpac (stdout):  {"type":"apdu","payload":{"ecode":<n>[, "data":"hex"]}}
#                         {"type":"http","payload":{"rcode":<n>,"rx":"hex"}}
#   Тела HTTP в обе стороны - hex (см. driver/http/stdio.c в lpac).
#
# Usage: esim-apdu-bridge.sh <at_port> <result_file> [ca_bundle] [livelog]
#   Читает запросы lpac со stdin, пишет ответы в stdout, финальный "lpa" - в
#   <result_file> (и завершается). <ca_bundle> нужен только для HTTP-ветки.
#   <livelog> — файл для дублирования прогресса и CGLA-трассировки.

PORT="$1"
RESULT="$2"
CABUNDLE="$3"
LIVELOG="$4"
: > "$RESULT"
# NB: $RESULT.es9err (тело ES9+-ошибки с кодами GSMA) здесь НЕ трогаем. Его
# чистит esim.sh ОДИН РАЗ перед do_lpac: do_lpac при неудаче повторяет запуск,
# и очистка на старте bridge стёрла бы ошибку первой попытки, если ретрай упал
# раньше ES9+. Пишем сюда только при ошибке (ниже), перезаписывая - последняя
# ES9+-ошибка за все попытки и побеждает.
CH=""

# hex -> бинарный файл. Через printf с \xNN: бинарно-безопасно, od/xxd в образе
# может не быть, а hexdump есть всегда.
hex2bin() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')" > "$2"; }
# бинарный файл -> hex одной строкой
bin2hex() { hexdump -v -e '/1 "%02x"' "$1" 2>/dev/null; }

while IFS= read -r line; do
	[ -n "$line" ] || continue
	# Быстрый разбор типа без jsonfilter (на каждую строку - дорого).
	case "$line" in
		*'"type":"apdu"'*) : ;;
		*'"type":"http"'*)
			# --- ES9+ через wget/OpenSSL (см. шапку: mbedTLS не тянет GSMA CI) ---
			url=$(printf '%s' "$line" | jsonfilter -e '@.payload.url' 2>/dev/null)
			tx=$(printf '%s' "$line" | jsonfilter -e '@.payload.tx' 2>/dev/null)
			_rq="/tmp/5gmodem_esim_hreq.$$"
			_rb="/tmp/5gmodem_esim_hbody.$$"
			_rh="/tmp/5gmodem_esim_hhdr.$$"
			# Заголовки -> позиционные параметры: в них есть пробелы, склеивать
			# в строку нельзя. IFS сохраняем - снаружи крутится read с IFS=''.
			set --
			_oldifs="$IFS"; IFS='
'
			for _h in $(printf '%s' "$line" | jsonfilter -e '@.payload.headers[*]' 2>/dev/null); do
				[ -n "$_h" ] && set -- "$@" "--header=$_h"
			done
			IFS="$_oldifs"
			[ -n "$CABUNDLE" ] && set -- "$@" "--ca-certificate=$CABUNDLE"
			# tx пустой -> GET, иначе POST телом. --content-on-error обязателен:
			# ES9+ кладёт осмысленный JSON и в 4xx/5xx, его нельзя терять.
			if [ -n "$tx" ]; then
				hex2bin "$tx" "$_rq"
				set -- "$@" --method=POST "--body-file=$_rq"
			fi
			wget -q -S -O "$_rb" --content-on-error --timeout=30 --tries=1 \
				"$@" "$url" 2>"$_rh"
			rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			# ОТКАТ НА НЕПРОВЕРЯЕМОЕ СОЕДИНЕНИЕ, если сорвалась именно проверка
			# сертификата. Так ходит сам lpac (его curl-бэкенд ставит
			# CURLOPT_SSL_VERIFYPEER=0), поэтому мы тут НЕ слабее базового
			# поведения - но без этого отката мы СТРОЖЕ и ломаем то, что раньше
			# работало: тестовые SM-DP+ (sysmocom TS.48) предъявляют сертификаты
			# GSMA *Test* CI, которого в публичных бандлах нет и быть не может.
			# Профиль защищён криптографией на уровне eUICC, а не этим TLS.
			if [ -z "$rcode" ] && grep -qi "certificate\|issuer" "$_rh" 2>/dev/null; then
				wget -q -S -O "$_rb" --content-on-error --timeout=30 --tries=1 \
					--no-check-certificate "$@" "$url" 2>"$_rh"
				rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			fi
			# Транспорт не состоялся (DNS/TLS/таймаут) - ответа нет вообще.
			# Отдаём 500: lpac трактует как ошибку ES9+ и не виснет в ожидании.
			[ -n "$rcode" ] || rcode=500
			# Сохраняем тело ответа ES9+, когда в нём есть маркеры ошибки: по
			# SGP.22 SM-DP+ кладёт коды GSMA (errorCode/subjectCode/reasonCode)
			# в statusCodeData, но HTTP-статус при этом ЧАСТО 200 - ошибка
			# сидит в functionExecutionStatus.status="Failed". Поэтому ловим не
			# по rcode, а по содержимому: тело ES9+ - JSON, ищем в нём признаки
			# отказа. esim.sh потом спарсит и покажет пользователю.
			# Пишем ТОЛЬКО ПЕРВУЮ ошибку за сессию: провал приходит на authenticateClient
			# (напр. "8.2.6/3.8 Matching ID: Refused" - точная причина), а следующий за
			# ним cancelSession нередко возвращает ВТОРИЧНУЮ ошибку ("8.1/6.1 eUICC:
			# Verification Failed"), которая перетёрла бы первую. Первая - авторитетная.
			if [ ! -s "$RESULT.es9err" ] && [ -s "$_rb" ] \
			   && grep -q '"statusCodeData"\|"status" *: *"Failed"\|"reasonCode"' "$_rb" 2>/dev/null; then
				cat "$_rb" > "$RESULT.es9err"
			fi
			printf '{"type":"http","payload":{"rcode":%s,"rx":"%s"}}\n' \
				"$rcode" "$(bin2hex "$_rb")"
			rm -f "$_rq" "$_rb" "$_rh"
			continue ;;
		*)  # не apdu/http -> прогресс или финальный результат ("lpa")
			printf '%s\n' "$line" >> "$RESULT"
			# Дублируем в стабильный файл: $RESULT именован по PID и наружу не
			# виден, а UI должен показывать ход операции ПОКА она идёт (иначе
			# прогресс доезжает до пользователя только вместе с итогом).
			[ -n "$LIVELOG" ] && printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$line" >> "$LIVELOG"
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
		[ -n "$LIVELOG" ] && printf 'TRACE CCHO aid=%.40s ch=%s\n' "$param" "${c:--1}" >> "$LIVELOG"
		printf '{"type":"apdu","payload":{"ecode":%s}}\n' "${c:--1}" ;;
	logic_channel_close)
		# param = номер канала (hex-байт, напр. "01")
		cc=$(printf '%d' "0x$param" 2>/dev/null)
		[ -n "$cc" ] && sms_tool -d "$PORT" at "AT+CCHC=$cc" >/dev/null 2>&1
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	transmit)
		# param = APDU (hex). AT+CGLA=<канал>,<len>,"<APDU>"
		# CGLA на FM350 (SDX55) ожидает длину в hex-СИМВОЛАХ (chars), не в байтах.
		# При передаче кол-ва байт (chars/2) модем отвергает команду без ответа.
		_cgla_out=$(sms_tool -d "$PORT" at "AT+CGLA=$CH,${#param},\"$param\"" 2>/dev/null | tr -d '\r')
		out=$(printf '%s' "$_cgla_out" | sed -n 's/.*+CGLA: *[0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p' | head -1)
		# DEBUG: последний CGLA-обмен в лог
		[ -n "$LIVELOG" ] && printf 'TRACE CGLA ch=%s len=%s apdu_head=%.40s raw=%s ret=%.40s\n' \
			"$CH" "${#param}" "$param" "$_cgla_out" "$out" >> "$LIVELOG"
		printf '{"type":"apdu","payload":{"ecode":0,"data":"%s"}}\n' "$out" ;;
	connect|disconnect|*)
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	esac
done
