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

# КАКОЙ У НАС wget. Весь HTTP-путь ниже написан под GNU wget (wget-ssl):
# --method/--body-file/-S/--content-on-error. busybox-wget этих опций не знает
# и вместо запроса печатает СПРАВКУ - у пользователя со свежей прошивкой
# загрузка профиля падала на ПЕРВОМ же запросе, а в «why» уезжали строки этой
# справки («--ca-certificate=<cert>  Load CA certificates...», живой лог
# 06.08.2026). При busybox-wget уходим на curl: он в наших зависимостях.
# Оговорка из шапки остаётся в силе - curl с mbedTLS не тянет часть GSMA CI,
# поэтому GNU wget ПРЕДПОЧТИТЕЛЕН, а curl - запасной выход вместо гарантийного
# отказа; в лог загрузки пишем, чем пошли.
_GNUWGET=""
wget --version 2>/dev/null | head -1 | grep -q "GNU Wget" && _GNUWGET=1
if [ -z "$_GNUWGET" ] && [ -n "$LIVELOG" ]; then
	if command -v curl >/dev/null 2>&1; then
		_wnote="GNU wget (wget-ssl) не найден - HTTP через curl; если SM-DP+ не откроется по TLS, установите wget-ssl"
	else
		_wnote="нет ни GNU wget (wget-ssl), ни curl - HTTP к SM-DP+ невозможен, установите wget-ssl"
	fi
	printf '%s {"type":"httpx","payload":{"note":"%s"}}\n' \
		"$(date '+%H:%M:%S' 2>/dev/null)" "$_wnote" >> "$LIVELOG" 2>/dev/null
fi

# Один HTTP-заход: $1 - файл тела ответа, $2 - файл заголовков/ошибок,
# $3 - «insecure» (непустой = не проверять сертификат), дальше - заголовки
# запроса КАК ЕСТЬ (без префиксов). Использует $url, $_rq (тело POST, если
# есть). Код HTTP достаём из $2 одинаково для обоих транспортов: и wget -S,
# и curl -D пишут туда строки «HTTP/x.x NNN».
_http_go() {
	_hg_b="$1"; _hg_h="$2"; _hg_ins="$3"; shift 3
	# Заголовки перекладываем в форму своего транспорта: крутим позиционные по
	# кругу ровно $# раз (набор заголовков известен только здесь, а в них есть
	# пробелы - склеивать в строку нельзя).
	_hg_n=$#
	while [ "$_hg_n" -gt 0 ]; do
		if [ -n "$_GNUWGET" ]; then set -- "$@" "--header=$1"; else set -- "$@" -H "$1"; fi
		shift
		_hg_n=$((_hg_n - 1))
	done
	if [ -n "$_GNUWGET" ]; then
		[ -n "$CABUNDLE" ] && set -- "$@" "--ca-certificate=$CABUNDLE"
		[ -n "$_hg_ins" ] && set -- "$@" --no-check-certificate
		[ -s "$_rq" ] && set -- "$@" --method=POST "--body-file=$_rq"
		wget -nv -S -O "$_hg_b" --content-on-error --timeout=60 --tries=1 \
			--no-http-keep-alive --header="Connection: close" \
			"$@" "$url" 2>"$_hg_h"
	else
		[ -n "$CABUNDLE" ] && set -- "$@" --cacert "$CABUNDLE"
		[ -n "$_hg_ins" ] && set -- "$@" -k
		[ -s "$_rq" ] && set -- "$@" --data-binary "@$_rq"
		curl -sS -D "$_hg_h" -o "$_hg_b" --max-time 60 -H "Connection: close" \
			"$@" "$url" 2>>"$_hg_h"
	fi
}

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
				[ -n "$_h" ] && set -- "$@" "$_h"
			done
			IFS="$_oldifs"
			# tx пустой -> GET, иначе POST телом. Тело кладём в $_rq: сам запрос
			# соберёт _http_go (у wget и curl это разные ключи).
			rm -f "$_rq"
			[ -n "$tx" ] && hex2bin "$tx" "$_rq"
			# -nv, НЕ -q: GNU wget с -q глушит и ошибки TLS - в stderr не попадало
			# «Self-signed certificate encountered», и сертификатный откат ниже
			# НЕ СРАБАТЫВАЛ НИКОГДА: любой SM-DP+ с неверифицируемой цепочкой
			# кончался синтетическим 500 («HTTP status code error» без цифр).
			# Живой случай: Yota mno-0b.esimservices.com. С -nv ошибки видны,
			# заголовки (-S) и тело (-O) - как прежде. (--content-on-error тоже
			# обязателен: ES9+ кладёт осмысленный JSON и в 4xx/5xx.)
			_http_go "$_rb" "$_rh" "" "$@"
			rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			# ОТКАТ НА НЕПРОВЕРЯЕМОЕ СОЕДИНЕНИЕ, если сорвалась именно проверка
			# сертификата. Так ходит сам lpac (его curl-бэкенд ставит
			# CURLOPT_SSL_VERIFYPEER=0), поэтому мы тут НЕ слабее базового
			# поведения - но без этого отката мы СТРОЖЕ и ломаем то, что раньше
			# работало: тестовые SM-DP+ (sysmocom TS.48) предъявляют сертификаты
			# GSMA *Test* CI, которого в публичных бандлах нет и быть не может.
			# Профиль защищён криптографией на уровне eUICC, а не этим TLS.
			if [ -z "$rcode" ] && grep -qi "certificate\|issuer" "$_rh" 2>/dev/null; then
				_http_go "$_rb" "$_rh" 1 "$@"
				rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			fi
			# Транспорт не состоялся (DNS/TLS/таймаут) - ответа нет вообще.
			# Отдаём 500: lpac трактует как ошибку ES9+ и не виснет в ожидании.
			# В лог загрузки - ЧЕСТНАЯ причина: lpac дальше скажет лишь «HTTP
			# status code error», и по логу пользователя нельзя было отличить
			# отказ сервера (какой код?) от недостижимости (DNS/TLS/таймаут).
			# Живой случай: Yota mno-0b.esimservices.com, в отчёте только
			# es9p_initiate_authentication FAIL без единой цифры.
			if [ -z "$rcode" ]; then
				# Причину берём из уже сохранённых заголовков/stderr прошлого
				# захода, а не новым запросом: повтор шёл ГОЛЫМ wget без наших
				# ключей и на busybox-wget печатал его СПРАВКУ - она и уезжала
				# в отчёт вместо причины (живой лог 06.08.2026: «--ca-certificate
				# =<cert> Load CA certificates...»). Заодно на один заход меньше.
				_why=$(grep -iE 'failed|error|unable|refused|timed|denied|certificate|resolve' "$_rh" 2>/dev/null \
					| grep -vE '^ *--|^ *-[a-zA-Z], ' \
					| tail -2 | tr '\n' ' ' | tr -d '\r')
				[ -n "$_why" ] || _why="транспорт не ответил (DNS/TLS/таймаут)"
				[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","transport":"failed","why":"%s"}}\n' \
					"$(date '+%H:%M:%S' 2>/dev/null)" "$url" "$(printf '%s' "$_why" | tr '"' "'")" >> "$LIVELOG"
			else
				# СЖАТОЕ ТЕЛО РАСПАКОВЫВАЕМ САМИ. wget отдаёт тело КАК ЕСТЬ, а
				# lpac ждёт чистый JSON: если SM-DP+ ответил gzip, парсер
				# спотыкается и говорит «Not JSON» при честном HTTP 200 - причём
				# по логу это неотличимо от битого сервера (живой случай
				# 04.08.2026: smdpplus.ripsim.com, getBoundProfilePackage,
				# 16099 байт, пять попыток подряд с одинаковым «Not JSON»).
				# Узнаём по сигнатуре 1f 8b, а не по заголовку: часть серверов
				# сжимает, не объявляя Content-Encoding.
				if [ -s "$_rb" ] && [ "$(hexdump -v -n 2 -e '/1 "%02x"' "$_rb" 2>/dev/null)" = "1f8b" ]; then
					if gzip -dc "$_rb" > "$_rb.un" 2>/dev/null && [ -s "$_rb.un" ]; then
						mv "$_rb.un" "$_rb"
						[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","note":"gzip распакован"}}\n' \
							"$(date '+%H:%M:%S' 2>/dev/null)" "$url" >> "$LIVELOG"
					fi
					rm -f "$_rb.un"
				fi
				# В ЛОГ - ПРИЗНАК JSON И НАЧАЛО ТЕЛА. Без этого «Not JSON» от lpac
				# ничего не объясняет: непонятно, пришёл ли HTML, сжатый поток или
				# обрезанный ответ. Первые байты в hex стоят даром и сразу
				# показывают, что именно прислал сервер.
				_bh=$(hexdump -v -n 16 -e '/1 "%02x"' "$_rb" 2>/dev/null)
				_bj=0; [ "$(cut -c1 "$_rb" 2>/dev/null)" = "{" ] && _bj=1
				# ОБРЫВ ВИДНО ПО ХВОСТУ. JSON от SM-DP+ заканчивается на «}»;
				# если тело начинается правильно, а кончается чем попало - оно
				# не битое, а НЕДОКАЧАННОЕ (сервер не закрыл соединение, wget
				# дождался таймаута и сохранил, сколько успел). Без этого признака
				# lpac говорит только «Not JSON», и обрыв неотличим от мусора.
				_bt=$(tail -c 1 "$_rb" 2>/dev/null)
				_btr=0; [ "$_bj" = 1 ] && [ "$_bt" != "}" ] && _btr=1
				[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","rcode":%s,"bytes":%s,"json":%s,"truncated":%s,"head":"%s"}}\n' \
					"$(date '+%H:%M:%S' 2>/dev/null)" "$url" "$rcode" "$(wc -c 2>/dev/null < "$_rb" || echo 0)" "$_bj" "$_btr" "$_bh" >> "$LIVELOG"
			fi
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
		# КАНАЛ НЕ ОТКРЫЛСЯ - ЧИСТИМ УТЁКШИЕ И ПРОБУЕМ ЕЩЁ РАЗ.
		#
		# У карты логических каналов считанные единицы, и если предыдущая
		# операция закрылась не полностью, CCHO отвечает отказом - lpac валит
		# ВСЮ операцию с "euicc_init", хотя чип живой. В живом логе 06.08.2026
		# это видно прямо: `TRACE CCHO ... ch=-1` -> euicc_init -1 -> внешний
		# повтор -> тот же чип отвечает нормально. Чистка здесь дешевле: она
		# спасает операцию на месте, не тратя круг ретрая (а у загрузки профиля
		# каждый круг стоит попытки на сервере оператора).
		if [ -z "$c" ]; then
			for _co in 1 2 3 4; do sms_tool -d "$PORT" at "AT+CCHC=$_co" >/dev/null 2>&1; done
			sleep 1
			r=$(sms_tool -d "$PORT" at "AT+CCHO=\"$param\"" 2>/dev/null | tr -d '\r')
			c=$(printf '%s' "$r" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
			[ -n "$c" ] || c=$(printf '%s' "$r" | grep -E '^[0-9]+$' | head -1)
			[ -n "$LIVELOG" ] && printf '%s TRACE CCHO повтор после чистки каналов -> ch=%s\n' \
				"$(date '+%H:%M:%S' 2>/dev/null)" "${c:--1}" >> "$LIVELOG"
		fi
		CH="$c"
		[ -n "$LIVELOG" ] && printf '%s TRACE CCHO aid=%.40s ch=%s\n' \
			"$(date '+%H:%M:%S' 2>/dev/null)" "$param" "${c:--1}" >> "$LIVELOG"
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
		# ОТВЕТА НЕТ - ОДИН ПОВТОР. Ответ CGLA всегда содержит хотя бы SW1SW2, так
		# что пустая строка - это НЕ «карта ответила пусто», а потерянный обмен:
		# порт занял дозвон, модем переэнумерировался, ответ съел параллельный
		# читатель. Один повтор дёшев и спасает одиночную потерю.
		if [ -z "$out" ]; then
			sleep 1
			_cgla_out=$(sms_tool -d "$PORT" at "AT+CGLA=$CH,${#param},\"$param\"" 2>/dev/null | tr -d '\r')
			out=$(printf '%s' "$_cgla_out" | sed -n 's/.*+CGLA: *[0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p' | head -1)
		fi
		# DEBUG: последний CGLA-обмен в лог. ВРЕМЯ ОБЯЗАТЕЛЬНО: без него по трассе
		# нельзя сказать, какой именно APDU встал (живые логи 06.08.2026: два
		# захода, и оба ровно 240 c молчания на es10b_prepare_download).
		# raw В ОДНУ СТРОКУ: ответ sms_tool приходит с пустыми строками, и трасса
		# в живом логе разъезжалась на три строки вместо одной - глазами читать
		# её было нельзя, а фронт видел обрывки без префикса TRACE.
		[ -n "$LIVELOG" ] && printf '%s TRACE CGLA ch=%s len=%s apdu_head=%.40s ret=%.40s raw=%s\n' \
			"$(date '+%H:%M:%S' 2>/dev/null)" "$CH" "${#param}" "$param" "$out" \
			"$(printf '%s' "$_cgla_out" | tr '\n' ' ')" >> "$LIVELOG"
		# ПУСТОЙ ОТВЕТ ОТДАЁМ КАК ОШИБКУ, А НЕ КАК УСПЕХ С ПУСТЫМИ ДАННЫМИ.
		# Раньше мы в любом случае рапортовали ecode:0, и lpac продолжал слать
		# APDU в мёртвый канал - операция висела минутами и кончалась пустым
		# «es10b_prepare_download» без единого слова о причине. Честный отказ
		# завершает шаг сразу, а в живой лог кладём человеческую строку: её
		# видно во вкладке, в отличие от TRACE.
		if [ -z "$out" ]; then
			[ -n "$LIVELOG" ] && printf '%s {"type":"apdux","payload":{"note":"чип не ответил на APDU (канал %s, %s символов) - порт занят или модем переэнумерировался"}}\n' \
				"$(date '+%H:%M:%S' 2>/dev/null)" "$CH" "${#param}" >> "$LIVELOG"
			printf '{"type":"apdu","payload":{"ecode":-1}}\n'
		else
			printf '{"type":"apdu","payload":{"ecode":0,"data":"%s"}}\n' "$out"
		fi ;;
	connect|disconnect|*)
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	esac
done
