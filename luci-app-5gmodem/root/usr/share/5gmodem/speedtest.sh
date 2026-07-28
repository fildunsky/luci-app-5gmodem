#!/bin/sh
#
# Router-side speed test over the ACTIVE uplink - i.e. wherever the internet
# actually goes from (the default route). That is exactly what the "Internet
# priority" bar sets: clicking an uplink there makes it primary (metric 1 = the
# default route), so testing the default route measures the uplink the user
# selected - modem or another WAN, no guessing. Plain curl follows that route and
# uses the system resolver.
#
# LIVE: the download samples curl's own progress meter (the "current speed"
# column on stderr) once a second and publishes it, so the UI shows the speed
# climbing in real time - without ever storing the downloaded bytes (RAM-safe).
#
# Runs in the BACKGROUND with detached fds (rpcd/cgi-io wait for EOF on the
# caller's pipes; a foreground curl would trip the 30s timeout = "XHR error").
# Progress/result is a small JSON file the UI polls.
#
# Usage:
#   speedtest.sh start    -> kicks off a test, returns {"running":1,...}
#   speedtest.sh status   -> live/final JSON
#
# Config (uci 5gmodem.@5gmodem[0]):
#   speedtest_url     download file URL   (default: Yandex mirror, ~16 MB)
#   speedtest_up_url  upload POST endpoint(default: Cloudflare __up)
#   speedtest_ip_url  public-IP service   (default: api.ipify.org)
#   speedtest_secs    per-phase time cap  (default 15)

CACHE="/tmp/5gmodem_speedtest.json"
URL_DEFAULT="http://speedtest.tele2.net/1GB.zip"   # RU-достижимый ~1 ГБ: тест 15 c успевает разогнаться. Cloudflare/Hetzner на РФ-сотовой отдают 403/недоступны, поэтому дефолт RU (мелкий файл кончался раньше и занижал скорость)

_write() {   # atomic write of $1 to CACHE
	echo "$1" > "$CACHE.$$" 2>/dev/null && mv "$CACHE.$$" "$CACHE" 2>/dev/null
}

# Дружелюбное имя сервиса замера (верхняя строка карточки) из URL загрузки.
_service_name() {
	_u=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$_u" ] || _u="$URL_DEFAULT"
	_h=$(echo "$_u" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*##' -e 's#:.*##')
	case "$_h" in
		*yandex*)     echo "Yandex" ;;
		*cloudflare*) echo "Cloudflare" ;;
		*librespeed*) echo "LibreSpeed" ;;
		*selectel*)   echo "Selectel" ;;
		*hetzner*)    echo "Hetzner" ;;
		*tele2*)      echo "Tele2" ;;
		*thinkbroadband*) echo "ThinkBroadband" ;;
		*)            echo "$_h" ;;
	esac
}

# Код страны (2 буквы, в верхнем регистре) из ответа гео-сервиса. Понимаем оба
# распространённых формата: строку ровно из двух букв (ip-api /line) и JSON с
# полем "countryCode"/"country_code". Пусто - значит сервис страну не отдал.
# Первый IPv4 из ответа, С ПРОВЕРКОЙ октетов (<=255). Голый grep на четыре
# группы цифр цепляет мусор из HTML-страниц ошибок - так в тест уже попадал
# несуществующий адрес, а по нему потом резолвился неверный флаг.
_parse_ip() {
	echo "$1" | grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' \
		| grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		| awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print; exit}'
}

_parse_cc() {
	_g="$1"
	_c=$(echo "$_g" | grep -oE '^[A-Za-z][A-Za-z]$' | head -1)
	[ -n "$_c" ] || _c=$(echo "$_g" \
		| grep -oiE '"country_?code"[ :]*"[A-Za-z][A-Za-z]"' \
		| grep -oE '[A-Za-z][A-Za-z]"$' | tr -d '"' | head -1)
	echo "$_c" | tr 'a-z' 'A-Z'
}

# "3.92M"/"512k"/"1.2G"/"0" (bytes/s из прогресса curl, 1024-я система) -> Mbps.
_tombps() {
	echo "$1" | awk '{
		v=$1; u="";
		if (v ~ /[kKmMgGtT]$/) { u=substr(v,length(v)); v=substr(v,1,length(v)-1) }
		v=v+0; m=1;
		if (u=="k"||u=="K") m=1024;
		else if (u=="m"||u=="M") m=1048576;
		else if (u=="g"||u=="G") m=1073741824;
		printf "%.1f", (v*m*8)/1000000
	}'
}

case "$1" in
start)
	# БЕЗ curl ТЕСТ НЕВОЗМОЖЕН - и об этом надо сказать, а не молчать.
	# Весь замер построен на нём: скорость берётся из его же счётчика прогресса,
	# отдача - из speed_upload, маршрут задаётся --interface. wget этого не умеет
	# (в busybox нет ни разбираемого прогресса, ни выгрузки тела), поэтому подмена
	# была бы не «запасным путём», а другим, менее точным измерением.
	# curl не заявлен в зависимостях пакета: он тянет libcurl и на роутерах с 8 МБ
	# флеша это заметно. Поэтому вместо тихого отказа объясняем, чего не хватает -
	# пользователь сам решит, ставить ли (apk add curl).
	if ! command -v curl >/dev/null 2>&1; then
		printf '{"running":0,"ok":0,"error":"no-curl"}\n' > "$CACHE" 2>/dev/null
		printf '{"running":0,"ok":0,"error":"no-curl"}\n'
		exit 0
	fi
	URL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$URL" ] || URL="$URL_DEFAULT"
	SECS=$(uci -q get 5gmodem.@5gmodem[0].speedtest_secs)
	case "$SECS" in ''|*[!0-9]*) SECS=15 ;; esac
	UPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_up_url)
	# по умолчанию Yandex - единственный, кто доступен и напрямую через сотовую в
	# РФ, и через прокси. Отвечает 404/403, но ЧИТАЕТ тело -> скорость отдачи
	# измеряется (наш код берёт speed_upload независимо от HTTP-кода).
	[ -n "$UPURL" ] || UPURL="https://speedtest.rt.ru/backend/empty.php"
	IPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ip_url)
	# по умолчанию ip-api.com/line - отдаёт СТРАНУ и IP простым текстом
	# ("RU\n<ip>"), чтобы рядом с IP показать флаг страны. Сервис можно сменить.
	[ -n "$IPURL" ] || IPURL="http://ip-api.com/line/?fields=countryCode,query"
	# Сервис для ДОЗАПРОСА страны по IP (когда основной её не отдаёт).
	# {ip} подставляется. По умолчанию ip-api /line - возвращает голое "RU".
	CCURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_cc_url)
	[ -n "$CCURL" ] || CCURL="http://ip-api.com/line/{ip}?fields=countryCode"
	# Резервный гео-сервис: отдаёт адрес И страну разом. Используется, когда
	# основной (speedtest_ip_url) не ответил.
	CCFALLBACK="http://ip-api.com/line/?fields=countryCode,query"
	SERVICE=$(_service_name)

	rm -f /tmp/5gmodem_st_stop 2>/dev/null
	_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":0}"

	# ФОН с отвязкой дескрипторов - редирект ИМЕННО на подоболочке, иначе rpcd
	# досидит до 30 c таймаута, пока curl качает (грабли из reboot_modem/collect).
	(
		PROG="/tmp/5gmodem_st_prog.$$"
		RESF="/tmp/5gmodem_st_res.$$"
		: > "$PROG"; : > "$RESF"

		# --- ПУБЛИЧНЫЙ IP + КОД СТРАНЫ (для флага) - ПАРАЛЛЕЛЬНО замеру ---
		# Раньше 2-3 geo-запроса шли ПОСЛЕДОВАТЕЛЬНО ДО закачки (6+5+4 c
		# max-time): на сотовой это съедало до ~15 c, и пользователь видел
		# «полоска ползёт, а цифра 0» - фаза загрузки уже шла, а curl закачки
		# ещё даже не стартовал. Теперь geo-подоболочка работает рядом с
		# замером, результат кладёт в файлы - циклы семплирования подхватывают
		# их на каждом тике. Ценой небольшой честности запроса (geo делит канал
		# с замером), но старт цифр важнее.
		GEOIP="/tmp/5gmodem_st_ip.$$"; GEOCC="/tmp/5gmodem_st_cc.$$"
		: > "$GEOIP"; : > "$GEOCC"
		(
			_g=$(curl --max-time 6 -s "$IPURL" 2>/dev/null)
			_pub=$(_parse_ip "$_g"); _cc=$(_parse_cc "$_g")
			if [ -z "$_pub" ]; then
				_g2=$(curl --max-time 5 -s "$CCFALLBACK" 2>/dev/null)
				_pub=$(_parse_ip "$_g2")
				[ -n "$_cc" ] || _cc=$(_parse_cc "$_g2")
			fi
			_local=0
			if [ -z "$_pub" ]; then
				# адрес самого модема (HiLink: src маршрута - внутренний 192.168.43.x)
				_pub=$(/usr/share/5gmodem/5gmodem.sh cached 30 2>/dev/null \
					| jsonfilter -e '@.ipaddr' 2>/dev/null | grep -E '^[0-9.]+$')
				_local=1
			fi
			if [ -z "$_pub" ]; then
				_pub=$(ip route get 77.88.8.8 2>/dev/null \
					| grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
				_local=1
			fi
			printf '%s' "$_pub" > "$GEOIP" 2>/dev/null
			printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
			# дозапрос страны - только для реально публичного адреса
			if [ -z "$_cc" ] && [ -n "$_pub" ] && [ "$_local" = 0 ]; then
				_ccu=$(echo "$CCURL" | sed "s|{ip}|$_pub|g")
				_cc=$(_parse_cc "$(curl --max-time 4 -s "$_ccu" 2>/dev/null)")
				[ -n "$_cc" ] && printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
			fi
		) >/dev/null 2>&1 </dev/null &
		PUB=""; CC=""

		# --- DOWNLOAD: живое семплирование, ИТОГ = МАКС по секундным семплам ---
		# stderr (прогресс-метр) -> PROG, stdout (итоговый -w) -> RESF. Заголовком
		# берём максимум устойчивой скорости из посекундных семплов (это «скорость
		# канала»), а НЕ среднее от curl: короткая загрузка = среднее занижено
		# разгоном TCP. Среднее оставляем фолбэком, если семплов не было.
		# -A маркер: по нему stop убивает ИМЕННО замерные curl'ы (busybox без pkill
		# по имени+аргументам, pgrep -f по маркеру - точечно, чужие curl не трогаем)
		curl -A 5gmodem-speedtest -o /dev/null --max-time "$SECS" --connect-timeout 8 \
			-w '%{speed_download} %{http_code}' "$URL" 2>"$PROG" >"$RESF" &
		CPID=$!
		MAXD=0
		while kill -0 "$CPID" 2>/dev/null; do
			sleep 1
			CUR=$(tr '\r' '\n' < "$PROG" 2>/dev/null | grep -E '^[ ]*[0-9]' | tail -1 | awk '{print $NF}')
			[ -n "$CUR" ] || CUR=0
			LIVE=$(_tombps "$CUR")
			MAXD=$(awk "BEGIN{m=$MAXD+0;v=$LIVE+0;printf \"%.1f\",(v>m)?v:m}")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":${LIVE:-0},\"secs\":$SECS,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$CPID" 2>/dev/null
		SPD=$(awk '{print $1+0}' "$RESF")
		HTTP=$(awk '{print $2}' "$RESF")
		AVGD=$(awk "BEGIN{printf \"%.1f\", ($SPD*8)/1000000}")
		DMBPS=$(awk "BEGIN{printf \"%.1f\", ($MAXD>0)?$MAXD:$AVGD}")
		rm -f "$PROG" "$RESF"

		# Пользователь остановил тест (повторный клик по карточке): выходим тихо,
		# показав, что успели намерить.
		if [ -f /tmp/5gmodem_st_stop ]; then
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			rm -f "$GEOIP" "$GEOCC" /tmp/5gmodem_st_stop
			_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
			exit 0
		fi

		# --- UPLOAD: живое семплирование + макс по секундным семплам ---
		# ЦИКЛ буферизованных 8-МБ POST'ов НА ВСЮ ФАЗУ, а не один буфер:
		# одиночные 8 МБ быстрый аплинк (5+ МБ/с) выливал за 1-2 c - фаза
		# кончалась на разгоне TCP, и «макс по семплам» ловил только первые
		# заниженные тики («аплоад срывается и показывает мало»). Потоковые
		# альтернативы проверены и НЕ работают: chunked -T (PUT и POST) rt.ru
		# режет 403 на ~10 МБ, явный Content-Length - 403 сразу, FTP tele2 с
		# сотовой (CGNAT) молчит. Поэтому шлём подряд, пока не истечёт $SECS;
		# провалы на передоговоре TCP между POST'ами съедает макс-семплинг,
		# в итог идёт максимум из (семплы, лучшая среди POST'ов средняя).
		UPROG="/tmp/5gmodem_st_uprog.$$"; URES="/tmp/5gmodem_st_ures.$$"
		: > "$UPROG"; : > "$URES"
		(
			_up_t0=$(cut -d. -f1 /proc/uptime)
			# ПЕРВЫЙ POST маленький (2 МБ), дальше по 8 МБ. Живая цифра берётся
			# из ЗАВЕРШЁННЫХ POST'ов (у HTTPS-выгрузки прогресса внутри передачи
			# нет), и с 8 МБ на медленном аплинке (1-2 МБ/с) первый отсчёт
			# приходил только через 4-8 c - карточка висела на нуле при ползущей
			# полоске. 2 МБ дают цифру через ~1-2 c; лёгкое занижение первого
			# отсчёта (короткий разгон TCP) гасится макс-агрегацией остальных.
			_up_sz=2097152
			while :; do
				[ -f /tmp/5gmodem_st_stop ] && break
				_up_now=$(cut -d. -f1 /proc/uptime)
				_up_left=$(( SECS - (_up_now - _up_t0) ))
				[ "$_up_left" -ge 2 ] || break
				head -c "$_up_sz" /dev/zero 2>/dev/null | curl -A 5gmodem-speedtest -o /dev/null \
					--max-time "$_up_left" --connect-timeout 6 \
					--data-binary @- -w '%{speed_upload}\n' "$UPURL" \
					2>>"$UPROG" >>"$URES"
				_up_sz=8388608
			done
		) </dev/null &
		UPID=$!
		MAXU=0
		LIVEU=0
		while kill -0 "$UPID" 2>/dev/null; do
			sleep 1
			# Живая цифра - средняя ПОСЛЕДНЕГО ЗАВЕРШЁННОГО POST'а (строки URES):
			# на HTTPS-выгрузке прогресс-метр curl держит «Current Speed» нулём
			# до конца передачи, поэтому семплить его бесполезно (наблюдалось:
			# live_up почти всегда 0.0 с редким проскоком средней). Обновление
			# ступенчатое (раз в ~3-4 c на POST), зато честное; между POST'ами
			# держим последнее значение, а не мигаем нулём.
			_upb=$(awk 'END{print $1+0}' "$URES" 2>/dev/null)
			_upn=$(awk "BEGIN{printf \"%.1f\", (${_upb:-0}*8)/1000000}")
			[ "$(awk "BEGIN{print ($_upn>0)?1:0}")" = 1 ] && LIVEU="$_upn"
			MAXU=$(awk "BEGIN{m=$MAXU+0;v=$LIVEU+0;printf \"%.1f\",(v>m)?v:m}")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"phase\":\"up\",\"down_mbps\":$DMBPS,\"live_up\":${LIVEU:-0},\"secs\":$SECS,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$UPID" 2>/dev/null
		# лучшая средняя среди POST'ов цикла (каждый пишет свою строку)
		USPD=$(awk '{v=$1+0; if (v>m) m=v} END{print m+0}' "$URES")
		rm -f "$UPROG" "$URES"
		# финальный снимок IP/страны: geo мог доехать позже последнего тика
		[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
		[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
		rm -f "$GEOIP" "$GEOCC"
		AVGU=$(awk "BEGIN{printf \"%.1f\", ($USPD*8)/1000000}")
		UBEST=$(awk "BEGIN{printf \"%.1f\", ($MAXU>0)?$MAXU:$AVGU}")
		UMBPS=""
		[ "$(awk "BEGIN{print ($UBEST>0)?1:0}")" = 1 ] && UMBPS="$UBEST"

		case "$HTTP" in
			200|206)
				_write "{\"running\":0,\"ok\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"up_mbps\":${UMBPS:-null},\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ts\":$(date +%s 2>/dev/null)}"
				;;
			*)
				_write "{\"running\":0,\"ok\":0,\"service\":\"$SERVICE\",\"http\":\"$HTTP\",\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
				;;
		esac
	) >/dev/null 2>&1 </dev/null &

	echo "{\"running\":1,\"service\":\"$SERVICE\"}"
	;;
status)
	if [ -f "$CACHE" ]; then
		cat "$CACHE"
	else
		echo "{\"running\":0,\"ok\":0,\"service\":\"$(_service_name)\"}"
	fi
	;;
stop)
	# Повторный клик по карточке. Флаг останавливает фазы теста (циклы его
	# проверяют), а замерные curl'ы убиваем сразу по маркеру в User-Agent -
	# точечно, чужие curl процессы не трогаем. Итоговый JSON пишет сам тест
	# («показать, что успели»), либо, если он уже мёртв, чистим running здесь.
	touch /tmp/5gmodem_st_stop 2>/dev/null
	kill $(pgrep -f 5gmodem-speedtest) 2>/dev/null
	sleep 1
	grep -q '"running":1' "$CACHE" 2>/dev/null && \
		_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$(_service_name)\"}"
	echo '{"running":0,"cancelled":1}'
	;;
*)
	echo '{"error":"usage: speedtest.sh start|status|stop"}'
	;;
esac
exit 0
