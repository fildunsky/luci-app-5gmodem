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
#   speedtest_url     download source: a URL, or "internetometer" (default) -
#                     the Yandex Internetometer probe list, see YA_* below
#   speedtest_up_url  upload POST endpoint; empty = chosen by the download
#                     source (Internetometer node, otherwise Rostelecom)
#   speedtest_ip_url  public-IP service   (default: api.ipify.org)
#   speedtest_secs    per-phase time cap  (default 15)

CACHE="/tmp/5gmodem_speedtest.json"
URL_DEFAULT="internetometer"     # зонды Яндекс-Интернетометра, см. YA_* ниже
UPURL_DEFAULT="internetometer"   # то же и для отдачи
# Запасной источник на случай, когда список зондов не пришёл. Здесь был Tele2
# и снят: с двух наших роутеров он молчит наглухо (curl отдаёт 000), а фолбэк
# обязан работать именно тогда, когда основной путь уже не сработал.
# Selectel отвечает и напрямую, и через сотовую; файл большой - 15-секундный
# тест успевает разогнаться (мелкий кончался раньше и занижал скорость).
URL_FALLBACK="https://speedtest.selectel.ru/1GB"
UPURL_FALLBACK="https://speedtest.rt.ru/backend/empty.php"

# ИНТЕРНЕТОМЕТР ЯНДЕКСА. Публичный список зондов: узлы CDN подбираются под
# клиента, поэтому на сотовой в РФ это самый близкий сервер, а не случайное
# зеркало. Ключей и заголовков не требует (проверено: 200 без Referer).
# Адреса СЕССИОННЫЕ - в них зашиты mid/sid, поэтому статической настройкой
# их не задать, и список приходится брать перед каждым замером.
YA_PROBES_URL="https://yandex.ru/internet/api/v0/get-probes"
# Ответ сервиса - ДАННЫЕ ИЗВНЕ, а мы по ним льём POST с телом. Поэтому адреса
# не «разбираем», а ВЫКУСЫВАЕМ по строгому шаблону: хост обязан оканчиваться
# на .cdn.yandex.net (после .net сразу «/», так что .cdn.yandex.net.zlo.com не
# пройдёт), путь - ровно один из двух. Это и есть проверка, а не украшение.
YA_RE_HOST='https://[a-zA-Z0-9.-]+\.cdn\.yandex\.net/[A-Za-z0-9_-]+'
YA_RE_DOWN="$YA_RE_HOST/probes/50mb\?[A-Za-z0-9._~%&=:/-]+"
YA_RE_UP="$YA_RE_HOST/upload\?[A-Za-z0-9._~%&=:/-]+"

_write() {   # atomic write of $1 to CACHE
	echo "$1" > "$CACHE.$$" 2>/dev/null && mv "$CACHE.$$" "$CACHE" 2>/dev/null
}

# Дружелюбное имя сервиса замера (верхняя строка карточки) из URL загрузки.
# $1 - адрес; без него берём настройку (так зовут status и стартовый снимок).
_service_name() {
	_u="$1"
	[ -n "$_u" ] || _u=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$_u" ] || _u="$URL_DEFAULT"
	[ "$_u" = internetometer ] && { echo "Интернетометр"; return; }
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
# Значение из прогресс-метра curl ("7.23M", "949.8k") -> БАЙТЫ. Множители у
# curl двоичные (k = 1024), как и в _tombps ниже.
_tobytes() {
	echo "$1" | awk '{
		v=$1; u="";
		if (v ~ /[kKmMgGtT]$/) { u=substr(v,length(v)); v=substr(v,1,length(v)-1) }
		v=v+0; m=1;
		if (u=="k"||u=="K") m=1024;
		else if (u=="m"||u=="M") m=1048576;
		else if (u=="g"||u=="G") m=1073741824;
		else if (u=="t"||u=="T") m=1099511627776;
		printf "%.0f", v*m
	}'
}

# ЧИСЛО ИЛИ НОЛЬ. Остановка теста убивает curl, и файл с его итогом остаётся
# ПУСТЫМ: `awk '{print $1+0}'` по пустому файлу не печатает ничего, дальше
# падал уже awk с пустой подстановкой, и DMBPS оставался пустым. В кэш уходило
# "down_mbps":, - невалидный JSON, который фронт разобрать не мог, поэтому
# после отмены карточка молча теряла и результат, и адрес.
_num() { case "$1" in ''|*[!0-9.]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

_spent() {
	printf '%s' "$1" | awk '{
		n=0; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+:[0-9]+(:[0-9]+)?$/) t[++n]=$i;
		s=(n>=2)?t[2]:((n==1)?t[1]:"0");
		m=split(s,a,":"); v=0; for (i=1;i<=m;i++) v=v*60+a[i];
		printf "%d", v }'
}

_up_rates() {
	awk 'NF>=5 {
		want=$1+0; got=$2+0; t=$3-$4; c=$5+0
		if (c<=0 || got<want || want<=0 || t<=0) next
		printf "%.0f\n", got/t
	}' "$1" 2>/dev/null
}

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

# Гео-запрос: тот же curl, но со СВОИМ User-Agent, если он задан в настройках
# «Внешнего IP». Отдельная функция, а не подстановка аргументов: заголовок
# содержит пробелы, и голое ${VAR:+-A $VAR} развалило бы его на слова.
_geo() {
	if [ -n "$GEOUA" ]; then curl --max-time "$1" -s -A "$GEOUA" "$2" 2>/dev/null
	else curl --max-time "$1" -s "$2" 2>/dev/null; fi
}

case "$1" in
start)
	# ВТОРОЙ ЗАМЕР ПОВЕРХ ПЕРВОГО - ЭТО ДВА ЗАНИЖЕННЫХ ЗАМЕРА. Повторный клик
	# (или вторая вкладка) запускал ещё один тест: оба пишут ОДИН $CACHE и делят
	# канал, цифры выходят вдвое меньше настоящих. Отказываем, только когда
	# замер ЖИВОЙ - есть наш curl по маркеру; застрявший в кэше running от
	# упавшего теста не должен запирать карточку навсегда (аудит 12.09.2026).
	if grep -q '"running":1' "$CACHE" 2>/dev/null \
		&& pgrep -f 5gmodem-speedtest >/dev/null 2>&1; then
		cat "$CACHE"
		exit 0
	fi
	# БЕЗ curl ТЕСТ НЕВОЗМОЖЕН - и об этом надо сказать, а не молчать.
	# Весь замер построен на нём: скорость берётся из его же счётчика прогресса,
	# отдача - из speed_upload, маршрут задаётся --interface. wget этого не умеет
	# (в busybox нет ни разбираемого прогресса, ни выгрузки тела), поэтому подмена
	# была бы не «запасным путём», а другим, менее точным измерением.
	# curl не заявлен в зависимостях пакета: он тянет libcurl и на роутерах с 8 МБ
	# флеша это заметно. Поэтому вместо тихого отказа объясняем, чего не хватает -
	# пользователь сам решит, ставить ли (apk add curl).
	if ! command -v curl >/dev/null 2>&1; then
		printf '{"running":0,"ok":0,"error":"no-curl","ts":%s}\n' "$(date +%s 2>/dev/null)" > "$CACHE" 2>/dev/null
		printf '{"running":0,"ok":0,"error":"no-curl"}\n'
		exit 0
	fi
	URL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$URL" ] || URL="$URL_DEFAULT"
	SECS=$(uci -q get 5gmodem.@5gmodem[0].speedtest_secs)
	case "$SECS" in ''|*[!0-9]*) SECS=15 ;; esac
	# Точка отдачи - такой же выбор из списка, как источник загрузки, и в нём
	# есть тот же «internetometer»: тогда узел берётся из зондов. ПУСТО значит
	# ровно то же самое - это умолчание, и трактовать его иначе нельзя, иначе
	# страница показывала бы один сервис, а замер шёл на другой. Любой другой
	# адрес - явный выбор пользователя, зонды его не перебивают.
	UPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_up_url)
	[ -n "$UPURL" ] || UPURL="$UPURL_DEFAULT"
	# СЕРВИС ОПРЕДЕЛЕНИЯ АДРЕСА - ОБЩИЙ С «Внешним IP» (настройки в одном
	# месте, см. extip.sh): раньше одно и то же спрашивалось двумя настройками.
	# Прежние ключи читаем как запасные - ради тех, кто выставил их до переезда.
	IPURL=$(uci -q get 5gmodem.@5gmodem[0].extip_url)
	[ -n "$IPURL" ] || IPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ip_url)
	# по умолчанию ip-api.com/line - отдаёт СТРАНУ и IP простым текстом
	# ("RU\n<ip>"), чтобы рядом с IP показать флаг страны. Сервис можно сменить.
	[ -n "$IPURL" ] || IPURL="http://ip-api.com/line/?fields=countryCode,query"
	# Сервис для ДОЗАПРОСА страны по IP (когда основной её не отдаёт).
	# {ip} подставляется. По умолчанию ip-api /line - возвращает голое "RU".
	CCURL=$(uci -q get 5gmodem.@5gmodem[0].extip_cc_url)
	[ -n "$CCURL" ] || CCURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_cc_url)
	[ -n "$CCURL" ] || CCURL="http://ip-api.com/line/{ip}?fields=countryCode"
	# Свой User-Agent - оттуда же. К ЗАМЕРУ его НЕ применяем: у закачки маркер
	# 5gmodem-speedtest, по нему stop находит и убивает именно наши curl.
	GEOUA=$(uci -q get 5gmodem.@5gmodem[0].extip_ua)
	# Резервный гео-сервис: отдаёт адрес И страну разом. Используется, когда
	# основной (speedtest_ip_url) не ответил.
	CCFALLBACK="http://ip-api.com/line/?fields=countryCode,query"
	# Российский фолбэк адреса (см. ниже): единственный, что отвечает с сотовой
	# в РФ. Настраивается на случай, если понадобится другой.
	YAIPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ru_ip_url)
	[ -n "$YAIPURL" ] || YAIPURL="https://yandex.ru/internet/api/v0/ip"
	SERVICE=$(_service_name)

	rm -f /tmp/5gmodem_st_stop /tmp/5gmodem_st_ip.* /tmp/5gmodem_st_cc.* /tmp/5gmodem_st_loc.* 2>/dev/null
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
		GEOLOC="/tmp/5gmodem_st_loc.$$"
		: > "$GEOIP"; : > "$GEOCC"; : > "$GEOLOC"
		(
			# СНАЧАЛА - БЫСТРЫЙ ИСТОЧНИК, И СРАЗУ В ФАЙЛ. Зарубежные geo-сервисы
			# на сотовой в РФ молчат ДО ТАЙМАУТА (6+5 c), и всё это время карточка
			# показывала «***.***.***.***» - почти до конца замера. Яндекс отвечает
			# за доли секунды и доступен всегда; страну он не даёт, поэтому дальше
			# идут обычные источники - они лишь уточнят IP и добавят cc.
			_fast=$(_parse_ip "$(_geo 3 "$YAIPURL")")
			[ -n "$_fast" ] && printf '%s' "$_fast" > "$GEOIP" 2>/dev/null
			_g=$(_geo 6 "$IPURL")
			_pub=$(_parse_ip "$_g"); _cc=$(_parse_cc "$_g")
			[ -n "$_pub" ] || _pub="$_fast"
			if [ -z "$_pub" ]; then
				_g2=$(_geo 5 "$CCFALLBACK")
				_pub=$(_parse_ip "$_g2")
				[ -n "$_cc" ] || _cc=$(_parse_cc "$_g2")
			fi
			# РОССИЙСКИЙ ФОЛБЭК. Зарубежные ip-сервисы (ip-api, ipify, ifconfig.me,
			# icanhazip, ident.me, cloudflare...) с сотовой в РФ не отвечают ВСЕ -
			# проверено на Мегафоне: интернет живой (ping/DNS/ya.ru работают), а
			# каждый из них молчит. Тогда показывался адрес самого модема
			# (10.78.71.235 - CGNAT оператора), и это выглядело как «белый IP».
			# Яндекс доступен всегда, отдаёт чистый JSON-строкой "1.2.3.4".
			# Страну он не даёт - флаг в таком случае просто не покажем.
			if [ -z "$_pub" ]; then
				_pub=$(_parse_ip "$(_geo 6 "$YAIPURL")")
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
			# Пометка «это НЕ публичный адрес»: показали адрес модема/маршрута,
			# внешний узнать не удалось. Без неё CGNAT-адрес оператора (10.x)
			# выглядел как настоящий белый IP.
			printf '%s' "$_local" > "$GEOLOC" 2>/dev/null
			# дозапрос страны - только для реально публичного адреса
			if [ -z "$_cc" ] && [ -n "$_pub" ] && [ "$_local" = 0 ]; then
				_ccu=$(echo "$CCURL" | sed "s|{ip}|$_pub|g")
				_cc=$(_parse_cc "$(_geo 4 "$_ccu")")
				[ -n "$_cc" ] && printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
			fi
			# ФОЛБЭК: ЧЕРЕЗ ПРОКСИ CLASH. Свой трафик роутера идёт МИМО туннеля
			# (tproxy перехватывает только форвард LAN), поэтому зарубежные
			# geo-сервисы с роутера молчат, хотя у клиентов открываются. Если у
			# clash поднят http/mixed-порт - повторяем запрос через него.
			# ВАЖНО: tproxy-порт для этого НЕ годится (это не HTTP-прокси), его
			# намеренно не берём - на стенде только он и есть.
			if [ -z "$_cc" ]; then
				_pp=$(sed -n 's/^ *\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
					/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
				if [ -n "$_pp" ] && [ "$_pp" != "0" ]; then
					if [ -n "$GEOUA" ]; then
						_cc=$(_parse_cc "$(curl --max-time 5 -s -A "$GEOUA" \
							-x "http://127.0.0.1:$_pp" "$CCFALLBACK" 2>/dev/null)")
					else
						_cc=$(_parse_cc "$(curl --max-time 5 -s \
							-x "http://127.0.0.1:$_pp" "$CCFALLBACK" 2>/dev/null)")
					fi
					[ -n "$_cc" ] && printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
				fi
			fi
		) >/dev/null 2>&1 </dev/null &
		PUB=""; CC=""

		# --- ЗОНДЫ ИНТЕРНЕТОМЕТРА ---
		# Берём ЗДЕСЬ, в фоне: запрос сетевой, а стартовый ответ rpcd уже отдан.
		# Имя сервиса на карточке уже написано, но при неудаче мы честно
		# переключаемся на запасной источник и МЕНЯЕМ имя - иначе карточка
		# говорила бы «Интернетометр», меряя Tele2.
		# Список нужен, если Интернетометр выбран ХОТЯ БЫ ДЛЯ ОДНОЙ фазы:
		# источник загрузки и точка отдачи настраиваются независимо, и «своя
		# ссылка на загрузку + узел Яндекса на отдачу» - рабочее сочетание.
		if [ "$URL" = internetometer ] || [ "$UPURL" = internetometer ]; then
			_yp=$(curl -A 5gmodem-speedtest -s --connect-timeout 5 --max-time 8 \
				"$YA_PROBES_URL" 2>/dev/null)
			_yd=$(printf '%s' "$_yp" | grep -oE "$YA_RE_DOWN" | head -1)
			# Быстрые зонды (timeout=) - для замера задержки, они обрываются
			# на сотне миллисекунд и для скорости не годятся.
			_yu=$(printf '%s' "$_yp" | grep -oE "$YA_RE_UP" | grep -v 'timeout=' | head -1)
			if [ -z "$_yd" ] || [ -z "$_yu" ]; then
				logger -t 5gmodem "speedtest: Internetometer probes unavailable - falling back to $URL_FALLBACK"
				_yd=""; _yu=""
			fi
			if [ "$URL" = internetometer ]; then
				if [ -n "$_yd" ]; then
					URL="$_yd"
				else
					# Имя пересчитываем ТОЛЬКО при откате: у зонда в адресе
					# стоит yandex.net, и по нему карточка подписалась бы
					# «Yandex» вместо «Интернетометра».
					URL="$URL_FALLBACK"
					SERVICE=$(_service_name "$URL")
				fi
			fi
			if [ "$UPURL" = internetometer ]; then
				if [ -n "$_yu" ]; then UPURL="$_yu"; else UPURL="$UPURL_FALLBACK"; fi
			fi
			_yp=""
		fi

		# --- DOWNLOAD: живое семплирование, ИТОГ = МАКС по секундным семплам ---
		# stderr (прогресс-метр) -> PROG, stdout (итоговый -w) -> RESF. Заголовком
		# берём максимум устойчивой скорости из посекундных семплов (это «скорость
		# канала»), а НЕ среднее от curl: короткая загрузка = среднее занижено
		# разгоном TCP. Среднее оставляем фолбэком, если семплов не было.
		# -A маркер: по нему stop убивает ИМЕННО замерные curl'ы (busybox без pkill
		# по имени+аргументам, pgrep -f по маркеру - точечно, чужие curl не трогаем)
		_DL_T0=$(cut -d. -f1 /proc/uptime)
		# ЦИКЛ ЗАКАЧЕК, А НЕ ОДНА. Зонд Интернетометра - файл на 50 МБ: на
		# быстром канале он кончается за три секунды, и фаза обрывалась бы на
		# разгоне TCP, как это было с «экономичным» 16-МБ зеркалом. Качаем
		# заново, пока не выйдет $SECS. Для большого файла (Tele2, 1 ГБ) второй
		# итерации не случается - там поведение ровно прежнее.
		# --max-time у curl считается НА ПЕРЕДАЧУ, не на команду, поэтому предел
		# каждой итерации - остаток фазы, и общее время не разъезжается.
		(
			while :; do
				[ -f /tmp/5gmodem_st_stop ] && break
				_dl_left=$(( SECS - ($(cut -d. -f1 /proc/uptime) - _DL_T0) ))
				[ "$_dl_left" -ge 2 ] || break
				curl -A 5gmodem-speedtest -o /dev/null --max-time "$_dl_left" \
					--connect-timeout 8 -w '%{speed_download} %{http_code}\n' \
					"$URL" 2>>"$PROG" >>"$RESF"
			done
		) </dev/null &
		CPID=$!
		MAXD=0
		# ЖИВУЮ СКОРОСТЬ СЧИТАЕМ САМИ - ПО ДЕЛЬТЕ ПРИНЯТЫХ БАЙТ.
		#
		# Раньше бралась последняя колонка прогресс-метра ("Current Speed"), а
		# это скользящее среднее ЗА ПЯТЬ СЕКУНД: первые две секунды она честно
		# показывает 0, дальше тянется за реальной скоростью с большим
		# отставанием. Снаружи это выглядело как «полоска ползёт, а скорость 0».
		# Замер на стенде: 0, 0, 598.6k, 660.8k, 884.2k, 951.4k при фактическом
		# мегабайте в секунду с первой же секунды.
		#
		# Колонка «Received» (4-е поле) - счётчик принятых байт, и разница между
		# двумя отсчётами делённая на время даёт МГНОВЕННУЮ скорость с первой
		# секунды. Если разобрать не удалось (формат метра поехал), откатываемся
		# на прежнюю колонку - хуже, чем было, не станет.
		_PREVB=0; _PREVS=0; _LASTLIVE=0; _DONEN=0
		while kill -0 "$CPID" 2>/dev/null; do
			sleep 1
			_LINE=$(tr '\r' '\n' 2>/dev/null < "$PROG" | grep -E '^[ ]*[0-9]' | tail -1)
			_RECV=$(printf '%s' "$_LINE" | awk '{print $4}')
			# СКОЛЬКО ЗАКАЧЕК УЖЕ ЗАВЕРШИЛОСЬ - по строкам итогов (-w пишет по
			# строке на каждую). Это НАДЁЖНЫЙ признак границы файлов; по самим
			# счётчикам метра её не видно: новая закачка может успеть набрать
			# больше байт, чем было в прошлом отсчёте у предыдущей, и тогда
			# «сброс» не распознаётся, а дельта получается завышенной.
			_NDONE=$(wc -l < "$RESF" 2>/dev/null | tr -d ' ')
			case "$_NDONE" in ''|*[!0-9]*) _NDONE="$_DONEN" ;; esac
			_NOWT=$(cut -d. -f1 /proc/uptime)
			LIVE=""
			if [ -n "$_RECV" ]; then
				_NOWB=$(_tobytes "$_RECV")
				_SP=$(_spent "$_LINE")
				case "$_NOWB" in
					''|*[!0-9]*) : ;;
					# СЧЁТЧИКИ МЕТРА СБРАСЫВАЮТСЯ НА КАЖДОЙ ЗАКАЧКЕ. Цикл выше
					# качает файл заново, и «Received» с «Time Spent» начинают
					# с нуля.
					# НА САМОМ СБРОСЕ СКОРОСТЬ НЕ СЧИТАЕМ, а только берём новую
					# точку отсчёта: «Time Spent» округлён до целой секунды, и
					# на первом отрезке новой закачки делитель занижен - цифра
					# выходила вдвое больше настоящей (на стенде 297 при плато
					# 136) и, как максимум по семплам, попадала в заголовок.
					*) if [ "$_NDONE" != "$_DONEN" ] || [ "$_NOWB" -lt "$_PREVB" ] || [ "$_SP" -lt "$_PREVS" ]; then
						_DONEN="$_NDONE"
						_PREVB="$_NOWB"; _PREVS="$_SP"
						LIVE="$_LASTLIVE"
					   else
						_DS=$(( _SP - _PREVS ))
						if [ "$_DS" -ge 1 ] && [ "$_NOWB" -ge "$_PREVB" ]; then
							LIVE=$(awk "BEGIN{printf \"%.1f\", (($_NOWB-$_PREVB)*8)/1000000/$_DS}")
							_PREVB="$_NOWB"; _PREVS="$_SP"
						else
							LIVE="$_LASTLIVE"
						fi
					   fi ;;
				esac
			fi
			if [ -z "$LIVE" ]; then
				CUR=$(printf '%s' "$_LINE" | awk '{print $NF}')
				[ -n "$CUR" ] || CUR=0
				LIVE=$(_tombps "$CUR")
			fi
			# НУЛЁМ НЕ МИГАЕМ. Ноль в середине замера означает не «скорость
			# упала», а «в этот тик новых байт не насчиталось» - последний
			# отсчёт перед завершением curl всегда такой. Карточка на фронте
			# плавно анимирует значение, и такой ноль выглядит как провал связи
			# (жалоба «показывает 0, хотя полоска ползёт»). Держим последнее
			# известное, как это уже сделано в фазе отдачи.
			case "$LIVE" in
				0|0.0) [ "$(awk "BEGIN{print ($MAXD+0>0)?1:0}")" = 1 ] && LIVE="$_LASTLIVE" ;;
				*) _LASTLIVE="$LIVE" ;;
			esac
			LIVE=$(_num "$LIVE"); MAXD=$(_num "$MAXD")
			MAXD=$(awk "BEGIN{m=$MAXD+0;v=$LIVE+0;printf \"%.1f\",(v>m)?v:m}")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			# elapsed - сколько секунд фаза УЖЕ идёт (от старта curl): фронт по
			# нему строит полосу прогресса, не выдумывая собственного отсчёта -
			# иначе полоса стартовала с клика и врала на медленном коннекте.
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":${LIVE:-0},\"secs\":$SECS,\"elapsed\":$(( _NOWT - _DL_T0 )),\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$CPID" 2>/dev/null
		# В РЕЗУЛЬТАТАХ ТЕПЕРЬ НЕСКОЛЬКО СТРОК - по одной на закачку цикла.
		# Средним берём ЛУЧШУЮ из них (как в фазе отдачи), а кодом ответа -
		# успешный, если он был хоть раз: обрыв последней закачки по остатку
		# времени не должен зачёркивать удачно измеренные до него.
		SPD=$(_num "$(awk '{v=$1+0; if (v>m) m=v} END{printf "%.0f", m+0}' "$RESF")")
		HTTP=$(awk '{c=$2; if (c==200 || c==206) ok=c} END{print (ok!="")?ok:c}' "$RESF")
		AVGD=$(awk "BEGIN{printf \"%.1f\", ($SPD*8)/1000000}")
		AVGD=$(_num "$AVGD"); MAXD=$(_num "$MAXD")
		DMBPS=$(_num "$(awk "BEGIN{printf \"%.1f\", ($MAXD>0)?$MAXD:$AVGD}")")
		rm -f "$PROG" "$RESF"

		# Пользователь остановил тест (повторный клик по карточке): выходим тихо,
		# показав, что успели намерить.
		if [ -f /tmp/5gmodem_st_stop ]; then
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			rm -f "$GEOIP" "$GEOCC" "$GEOLOC" /tmp/5gmodem_st_stop
			_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ts\":$(date +%s 2>/dev/null)}"
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
			_up_sz=262144; _up_n=1
			while :; do
				[ -f /tmp/5gmodem_st_stop ] && break
				_up_now=$(cut -d. -f1 /proc/uptime)
				_up_left=$(( SECS - (_up_now - _up_t0) ))
				[ "$_up_left" -ge 2 ] || break
				set --
				_up_i=0
				while [ "$_up_i" -lt "$_up_n" ]; do
					set -- "$@" -o /dev/null "$UPURL"
					_up_i=$((_up_i + 1))
				done
				head -c "$_up_sz" /dev/zero 2>/dev/null | curl -A 5gmodem-speedtest \
					--max-time "$_up_left" --connect-timeout 6 -H 'Expect:' \
					--data-binary @- \
					-w "$_up_sz"' %{size_upload} %{time_total} %{time_pretransfer} %{http_code}\n' \
					"$@" 2>/dev/null >>"$URES"
				_up_bps=$(_up_rates "$URES" | awk '{v=$1} END{printf "%.0f", v+0}')
				case "$_up_bps" in
					''|0|*[!0-9]*)
						[ "$(wc -l < "$URES" 2>/dev/null | tr -d ' ')" -ge 3 ] 2>/dev/null && break
						sleep 1
						_up_sz=262144; _up_n=1 ;;
					*)
						_up_sz=$(awk "BEGIN{v=$_up_bps*2; if (v<262144) v=262144; if (v>8388608) v=8388608; printf \"%.0f\", v}")
						_up_n=3 ;;
				esac
			done
		) </dev/null &
		UPID=$!
		UPT0=$(cut -d. -f1 /proc/uptime)
		MAXU=0
		LIVEU=0
		while kill -0 "$UPID" 2>/dev/null; do
			sleep 1
			_up_el=$(( $(cut -d. -f1 /proc/uptime) - UPT0 ))
			if [ "$_up_el" -gt $(( SECS + 2 )) ]; then
				kill $(pgrep -f 5gmodem-speedtest) 2>/dev/null
			fi
			_upl=$(_up_rates "$URES" | awk '{v=$1; if (v>m) m=v} END{printf "%.1f %.1f", (v*8)/1000000, (m*8)/1000000}')
			LIVEU=$(_num "${_upl%% *}"); MAXU=$(_num "${_upl##* }")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"phase\":\"up\",\"down_mbps\":$DMBPS,\"live_up\":${LIVEU:-0},\"secs\":$SECS,\"elapsed\":$_up_el,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$UPID" 2>/dev/null
		MAXU=$(_num "$(_up_rates "$URES" | awk '{v=$1; if (v>m) m=v} END{printf "%.1f", (m*8)/1000000}')")
		UERR=""
		if [ "$(awk "BEGIN{print ($MAXU>0)?1:0}")" != 1 ]; then
			UERR=$(awk '$5+0>0 {c=$5} END{print (c!="")?"http-" c:"no-answer"}' "$URES" 2>/dev/null)
			[ -n "$UERR" ] || UERR="no-answer"
		fi
		# лучшая средняя среди POST'ов цикла (каждый пишет свою строку)
		rm -f "$UPROG" "$URES"
		# финальный снимок IP/страны: geo мог доехать позже последнего тика
		[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
		[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
		[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
		rm -f "$GEOIP" "$GEOCC" "$GEOLOC"
		UMBPS=""
		[ -z "$UERR" ] && UMBPS="$MAXU"

		case "$HTTP" in
			200|206)
				_write "{\"running\":0,\"ok\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"up_mbps\":${UMBPS:-null},\"up_error\":\"$UERR\",\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ip_local\":${IPLOC:-0},\"ts\":$(date +%s 2>/dev/null)}"
				;;
			*)
				# ts во ВСЕХ финалах (не только ok): фронт отличает свежий финал от
			# протухшего кэша прошлого теста побайтовым сравнением - без метки
			# два одинаковых исхода неразличимы.
				_write "{\"running\":0,\"ok\":0,\"service\":\"$SERVICE\",\"http\":\"$HTTP\",\"up_mbps\":${UMBPS:-null},\"up_error\":\"$UERR\",\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ip_local\":${IPLOC:-0},\"ts\":$(date +%s 2>/dev/null)}"
				;;
		esac
	) >/dev/null 2>&1 </dev/null &

	echo "{\"running\":1,\"service\":\"$SERVICE\"}"
	;;
status)
	# БИТЫЙ КЭШ ВЫБРАСЫВАЕМ, А НЕ ОТДАЁМ. Испорченный файл мог остаться от
	# прежних версий (см. _num выше), и карточка на нём молча пустела до
	# следующего теста - хотя лечится он один раз и сам.
	if [ -s "$CACHE" ] && ! jsonfilter -i "$CACHE" -e '@' >/dev/null 2>&1; then
		rm -f "$CACHE" 2>/dev/null
	fi
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
		_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$(_service_name)\",\"ts\":$(date +%s 2>/dev/null)}"
	echo '{"running":0,"cancelled":1}'
	;;
*)
	echo '{"error":"usage: speedtest.sh start|status|stop"}'
	;;
esac
exit 0
