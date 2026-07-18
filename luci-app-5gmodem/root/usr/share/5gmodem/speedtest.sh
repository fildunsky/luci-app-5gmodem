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
URL_DEFAULT="http://mirror.yandex.ru/debian/ls-lR.gz"   # ~16 МБ, ограниченный трафик

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
		*)            echo "$_h" ;;
	esac
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
	URL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$URL" ] || URL="$URL_DEFAULT"
	SECS=$(uci -q get 5gmodem.@5gmodem[0].speedtest_secs)
	case "$SECS" in ''|*[!0-9]*) SECS=15 ;; esac
	UPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_up_url)
	# по умолчанию Yandex - единственный, кто доступен и напрямую через сотовую в
	# РФ, и через прокси. Отвечает 404/403, но ЧИТАЕТ тело -> скорость отдачи
	# измеряется (наш код берёт speed_upload независимо от HTTP-кода).
	[ -n "$UPURL" ] || UPURL="https://yandex.ru/internet/api/v1/upload"
	IPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ip_url)
	# по умолчанию ip-api.com/line - отдаёт СТРАНУ и IP простым текстом
	# ("RU\n<ip>"), чтобы рядом с IP показать флаг страны. Сервис можно сменить.
	[ -n "$IPURL" ] || IPURL="http://ip-api.com/line/?fields=countryCode,query"
	SERVICE=$(_service_name)

	_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":0}"

	# ФОН с отвязкой дескрипторов - редирект ИМЕННО на подоболочке, иначе rpcd
	# досидит до 30 c таймаута, пока curl качает (грабли из reboot_modem/collect).
	(
		PROG="/tmp/5gmodem_st_prog.$$"
		RESF="/tmp/5gmodem_st_res.$$"
		: > "$PROG"; : > "$RESF"

		# --- DOWNLOAD: живое семплирование, ИТОГ = МАКС по секундным семплам ---
		# stderr (прогресс-метр) -> PROG, stdout (итоговый -w) -> RESF. Заголовком
		# берём максимум устойчивой скорости из посекундных семплов (это «скорость
		# канала»), а НЕ среднее от curl: короткая загрузка = среднее занижено
		# разгоном TCP. Среднее оставляем фолбэком, если семплов не было.
		curl -o /dev/null --max-time "$SECS" --connect-timeout 8 \
			-w '%{speed_download} %{http_code}' "$URL" 2>"$PROG" >"$RESF" &
		CPID=$!
		MAXD=0
		while kill -0 "$CPID" 2>/dev/null; do
			sleep 1
			CUR=$(tr '\r' '\n' < "$PROG" 2>/dev/null | grep -E '^[ ]*[0-9]' | tail -1 | awk '{print $NF}')
			[ -n "$CUR" ] || CUR=0
			LIVE=$(_tombps "$CUR")
			MAXD=$(awk "BEGIN{m=$MAXD+0;v=$LIVE+0;printf \"%.1f\",(v>m)?v:m}")
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":${LIVE:-0}}"
		done
		wait "$CPID" 2>/dev/null
		SPD=$(awk '{print $1+0}' "$RESF")
		HTTP=$(awk '{print $2}' "$RESF")
		AVGD=$(awk "BEGIN{printf \"%.1f\", ($SPD*8)/1000000}")
		DMBPS=$(awk "BEGIN{printf \"%.1f\", ($MAXD>0)?$MAXD:$AVGD}")
		rm -f "$PROG" "$RESF"

		# --- UPLOAD: то же - живое семплирование + макс по секундным семплам ---
		UPROG="/tmp/5gmodem_st_uprog.$$"; URES="/tmp/5gmodem_st_ures.$$"
		: > "$UPROG"; : > "$URES"
		head -c 8388608 /dev/zero 2>/dev/null | curl -o /dev/null --max-time "$SECS" --connect-timeout 6 \
			--data-binary @- -w '%{speed_upload}' "$UPURL" 2>"$UPROG" >"$URES" &
		UPID=$!
		MAXU=0
		while kill -0 "$UPID" 2>/dev/null; do
			sleep 1
			CUR=$(tr '\r' '\n' < "$UPROG" 2>/dev/null | grep -E '^[ ]*[0-9]' | tail -1 | awk '{print $NF}')
			[ -n "$CUR" ] || CUR=0
			LIVEU=$(_tombps "$CUR")
			MAXU=$(awk "BEGIN{m=$MAXU+0;v=$LIVEU+0;printf \"%.1f\",(v>m)?v:m}")
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"phase\":\"up\",\"down_mbps\":$DMBPS,\"live_up\":${LIVEU:-0}}"
		done
		wait "$UPID" 2>/dev/null
		USPD=$(awk '{print $1+0}' "$URES")
		rm -f "$UPROG" "$URES"
		AVGU=$(awk "BEGIN{printf \"%.1f\", ($USPD*8)/1000000}")
		UBEST=$(awk "BEGIN{printf \"%.1f\", ($MAXU>0)?$MAXU:$AVGU}")
		UMBPS=""
		[ "$(awk "BEGIN{print ($UBEST>0)?1:0}")" = 1 ] && UMBPS="$UBEST"

		# --- ПУБЛИЧНЫЙ IP + КОД СТРАНЫ (для флага). ip-api /line отдаёт "RU\n<ip>";
		# у плоских сервисов (ipify) страны нет - тогда просто IP без флага. Из
		# ответа тащим первый IPv4 и, если есть, 2-буквенный код страны (строкой
		# ровно из 2 букв или из JSON "country_code":"XX"). Фолбэк IP - src маршрута.
		GEO=$(curl --max-time 6 -s "$IPURL" 2>/dev/null)
		PUB=$(echo "$GEO" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		[ -n "$PUB" ] || PUB=$(ip route get 77.88.8.8 2>/dev/null \
			| grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
		CC=$(echo "$GEO" | grep -oE '^[A-Za-z][A-Za-z]$' | head -1)
		[ -n "$CC" ] || CC=$(echo "$GEO" | grep -oiE '"country_code"[ :]*"[A-Za-z]{2}"' | grep -oE '[A-Za-z]{2}"$' | tr -d '"' | head -1)
		CC=$(echo "$CC" | tr 'a-z' 'A-Z')

		case "$HTTP" in
			200|206)
				_write "{\"running\":0,\"ok\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"up_mbps\":${UMBPS:-null},\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ts\":$(date +%s 2>/dev/null)}"
				;;
			*)
				_write "{\"running\":0,\"ok\":0,\"service\":\"$SERVICE\",\"http\":\"$HTTP\"}"
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
*)
	echo '{"error":"usage: speedtest.sh start|status"}'
	;;
esac
exit 0
