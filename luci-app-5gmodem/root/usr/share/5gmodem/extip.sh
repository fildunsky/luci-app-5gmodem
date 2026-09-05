#!/bin/sh
# Внешний (публичный) адрес роутера - тот, каким его видит интернет.
#
# Зачем: адрес на интерфейсе и адрес, с которого роутер реально ходит наружу,
# совпадают далеко не всегда. У сотовой это CGNAT оператора, за туннелем -
# адрес выходного узла. Разница между ними и есть ответ на вопрос «идёт ли
# трафик самого роутера через VPN».
#
# ПО УМОЛЧАНИЮ ВЫКЛЮЧЕНО. Это запрос к постороннему сервису: пока человек сам
# не выбрал, к какому именно, никто никуда не ходит.
#
# СПРАШИВАЕМ РОВНО ТО, ЧТО ЗАДАНО. Ни фолбэков на «запасные» сервисы, ни
# дозапросов - иначе выбор сервиса терял бы смысл (человек выбирает его в том
# числе из соображений «кому я показываю свой адрес»).
#
# ЧЕРЕЗ КАКОЙ КАНАЛ СПРАШИВАЕМ. Обычный запрос уходит по маршруту по
# умолчанию - и отвечает на вопрос «с какого адреса виден РОУТЕР». Для карточки
# модема этого мало: когда основным выбран другой аплинк (Wi-Fi-станция,
# провод), там показался бы чужой адрес. Поэтому можно назвать интерфейс -
# запрос уйдёт именно через него (curl --interface), а кэш будет свой.
# Если названный интерфейс и так основной, запроса не будет вовсе: берём общий
# кэш - тот же самый ответ, только даром.
#
# Использование:
#   extip.sh get [iface]   - мгновенно: кэш + фоновое обновление, если протух
#   extip.sh now [iface]   - обновить прямо сейчас (блокирующе)
#   extip.sh flush         - выбросить все кэши
#   extip.sh probe <url> [4|6] [ua] - разовая проверка сервиса для настроек

CACHE="/tmp/5gmodem_extip.json"
LOCK="/tmp/5gmodem_extip.lock"
DEV=""

URL4_DEFAULT="http://ip-api.com/line/?fields=countryCode,query"
URL6_DEFAULT="https://api6.ipify.org"
CCURL_DEFAULT="http://ip-api.com/line/{ip}?fields=countryCode"
TTL_DEFAULT=300
TMO=7

_u() { uci -q get "5gmodem.@5gmodem[0].$1"; }

# Сервис определения адреса ОБЩИЙ с тестом скорости: раньше он спрашивался
# двумя настройками в двух разных местах. Старые ключи читаем как запасные -
# у кого они выставлены, тот менял их осознанно (переезд делает uci-defaults).
_url4() { _v=$(_u extip_url);    [ -n "$_v" ] || _v=$(_u speedtest_ip_url); [ -n "$_v" ] || _v="$URL4_DEFAULT"; printf '%s' "$_v"; }
_url6() { _v=$(_u extip_url6);   [ -n "$_v" ] || _v="$URL6_DEFAULT"; printf '%s' "$_v"; }
_ccurl() { _v=$(_u extip_cc_url); [ -n "$_v" ] || _v=$(_u speedtest_cc_url); [ -n "$_v" ] || _v="$CCURL_DEFAULT"; printf '%s' "$_v"; }

_now() { read -r _n _ < /proc/uptime; printf '%s' "${_n%%.*}"; }

_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Хост сервиса - подпись под адресом («откуда узнали»).
_host() { printf '%s' "$1" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*##' -e 's#:.*##'; }

_defdev() { ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}'; }

# Имя из интерфейса сети (uci) или прямо имя устройства - на выходе устройство.
_devof() {
	[ -n "$1" ] || return 0
	if [ -e "/sys/class/net/$1" ]; then printf '%s' "$1"; return 0; fi
	_d=$(ifstatus "$1" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	[ -n "$_d" ] || _d=$(ifstatus "${1}_4" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	[ -n "$_d" ] && [ -e "/sys/class/net/$_d" ] && printf '%s' "$_d"
}

# Ключ маршрута: шлюз и устройство маршрута по умолчанию. Сменился аплинк -
# прежний внешний адрес недействителен, и ждать конца TTL незачем.
# Для запроса через конкретный интерфейс ключ - его собственный адрес (модем
# перезвонил с новым - ответ протух) плюс основное устройство: стал основным
# он сам - переезжаем на общий кэш.
_rkey() {
	if [ -n "$DEV" ]; then
		_a4=$(ip -4 -o addr show dev "$DEV" 2>/dev/null | awk 'NR==1{print $4}')
		_a6=$(ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | awk 'NR==1{print $4}')
		printf '%s@%s@%s|%s' "$DEV" "$_a4" "$_a6" "$(_defdev)"
		return 0
	fi
	_r4=$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $3"@"$5}')
	_r6=$(ip -6 route show default 2>/dev/null | awk 'NR==1{print $3"@"$5}')
	printf '%s|%s' "$_r4" "$_r6"
}

# Кэш у каждого канала свой: общий (маршрут по умолчанию) и по устройству.
_setscope() {
	DEV=$(_devof "$1")
	[ -n "$DEV" ] && [ "$DEV" = "$(_defdev)" ] && DEV=""
	if [ -n "$DEV" ]; then
		_sfx=$(printf '%s' "$DEV" | tr -c 'A-Za-z0-9_.-' '_')
		CACHE="/tmp/5gmodem_extip_$_sfx.json"
		LOCK="/tmp/5gmodem_extip_$_sfx.lock"
	fi
}

_has_v6() {
	[ -n "$(ip -6 route show default 2>/dev/null | head -1)" ] || return 1
	[ -z "$DEV" ] && return 0
	[ -n "$(ip -6 -o addr show dev "$DEV" scope global 2>/dev/null | head -1)" ]
}

# Первый IPv4 С ПРОВЕРКОЙ ОКТЕТОВ: голый grep на четыре группы цифр цепляет
# мусор со страниц ошибок, и в карточку попадал несуществующий адрес.
_parse4() {
	printf '%s' "$1" | grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' \
		| grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		| awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print; exit}'
}

_parse6() {
	printf '%s' "$1" | grep -oE '([0-9a-fA-F]{1,4}:){2,7}(:|[0-9a-fA-F]{1,4})(:[0-9a-fA-F]{1,4})*' \
		| head -1
}

# Код страны: либо голые две буквы (ip-api /line), либо поле JSON.
_parsecc() {
	_c=$(printf '%s\n' "$1" | grep -oE '^[A-Za-z][A-Za-z]$' | head -1)
	[ -n "$_c" ] || _c=$(printf '%s' "$1" \
		| grep -oiE '"country_?code"[ :]*"[A-Za-z][A-Za-z]"' \
		| grep -oE '[A-Za-z][A-Za-z]"$' | tr -d '"' | head -1)
	printf '%s' "$_c" | tr 'a-z' 'A-Z'
}

# curl умеет всё нужное, но в зависимостях пакета его нет (тянет libcurl).
# uclient-fetch есть в любой сборке OpenWrt и тоже знает -4/-6, -U и таймаут.
# ЗАПРОС ЧЕРЕЗ ЗАДАННЫЙ ИНТЕРФЕЙС УМЕЕТ ТОЛЬКО curl. У uclient-fetch привязки
# нет, поэтому без curl адрес по конкретному каналу узнать нечем - лучше
# промолчать, чем показать в карточке модема адрес соседнего аплинка.
_fetch() {
	_fu="$1"; _ff="$2"; _fa="$3"
	if command -v curl >/dev/null 2>&1; then
		set -- -"$_ff" -s -L --max-time "$TMO"
		[ -n "$DEV" ] && set -- "$@" --interface "$DEV"
		[ -n "$_fa" ] && set -- "$@" -A "$_fa"
		curl "$@" "$_fu" 2>/dev/null
	else
		[ -n "$DEV" ] && return 0
		if [ -n "$_fa" ]; then
			wget -"$_ff" -q -O - -T "$TMO" -U "$_fa" "$_fu" 2>/dev/null
		else
			wget -"$_ff" -q -O - -T "$TMO" "$_fu" 2>/dev/null
		fi
	fi
}

_write() {
	printf '%s' "$1" > "$CACHE.$$" 2>/dev/null && mv "$CACHE.$$" "$CACHE" 2>/dev/null
}

_enabled() { [ "$(_u extip_enabled)" = "1" ]; }

_refresh() {
	URL4=$(_url4)
	URL6=$(_url6)
	UA=$(_u extip_ua)

	IP4=""; CC=""; IP6=""; SRC4=""; SRC6=""
	if [ -n "$URL4" ]; then
		_o=$(_fetch "$URL4" 4 "$UA")
		IP4=$(_parse4 "$_o")
		CC=$(_parsecc "$_o")
		[ -n "$IP4" ] && SRC4=$(_host "$URL4")
	fi
	# ДОЗАПРОС СТРАНЫ - НЕ ЗАПАСНОЙ ИСТОЧНИК АДРЕСА. Адрес мы уже знаем; сюда
	# идём, только если выбранный сервис страну не отдаёт (ipify, ifconfig.me
	# и прочие «голый IP»), и только за флагом. Сервис для этого - тот же, что
	# у теста скорости, и виден в настройках.
	if [ -z "$CC" ] && [ -n "$IP4" ]; then
		_cu=$(_ccurl)
		if [ -n "$_cu" ]; then
			CC=$(_parsecc "$(_fetch "$(printf '%s' "$_cu" | sed "s|{ip}|$IP4|g")" 4 "$UA")")
		fi
	fi
	# IPv6 спрашиваем, только если маршрут по умолчанию для него вообще есть:
	# иначе каждый цикл впустую висел бы до таймаута.
	if [ -n "$URL6" ] && _has_v6; then
		_o6=$(_fetch "$URL6" 6 "$UA")
		IP6=$(_parse6 "$_o6")
		[ -n "$IP6" ] && SRC6=$(_host "$URL6")
		[ -n "$CC" ] || CC=$(_parsecc "$_o6")
	fi

	_write "$(printf '{"enabled":1,"dev":"%s","ip":"%s","ip6":"%s","cc":"%s","src":"%s","src6":"%s","ts":%s,"rk":"%s"}' \
		"$(_esc "$DEV")" "$(_esc "$IP4")" "$(_esc "$IP6")" "$(_esc "$CC")" \
		"$(_esc "$SRC4")" "$(_esc "$SRC6")" "$(_now)" "$(_esc "$(_rkey)")")"
}

# Фоновое обновление с отвязкой дескрипторов: rpcd/cgi-io ждут EOF на трубах
# вызывающего, и обычный `&` держал бы XHR до самого таймаута в 30 c.
_spawn() {
	(
		flock -n 9 2>/dev/null || exit 0
		_refresh
	) 9>"$LOCK" >/dev/null 2>&1 </dev/null &
}

case "$1" in
get)
	if ! _enabled; then
		rm -f /tmp/5gmodem_extip.json /tmp/5gmodem_extip_*.json 2>/dev/null
		echo '{"enabled":0}'
		exit 0
	fi
	_setscope "$2"
	TTL=$(_u extip_ttl); case "$TTL" in ''|*[!0-9]*) TTL="$TTL_DEFAULT" ;; esac
	[ "$TTL" -ge 30 ] 2>/dev/null || TTL="$TTL_DEFAULT"
	OLD=$(cat "$CACHE" 2>/dev/null)
	STALE=1
	if [ -n "$OLD" ]; then
		_ts=$(printf '%s' "$OLD" | sed -n 's/.*"ts":\([0-9]*\).*/\1/p')
		_rk=$(printf '%s' "$OLD" | sed -n 's/.*"rk":"\([^"]*\)".*/\1/p')
		case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
		_age=$(( $(_now) - _ts ))
		[ "$_age" -lt 0 ] && _age=0
		if [ "$_age" -lt "$TTL" ] && [ "$_rk" = "$(_rkey)" ]; then STALE=0; fi
	fi
	[ "$STALE" = 1 ] && _spawn
	if [ -n "$OLD" ]; then printf '%s\n' "$OLD"; else echo '{"enabled":1}'; fi
	;;
now)
	_enabled || { echo '{"enabled":0}'; exit 0; }
	_setscope "$2"
	_refresh
	cat "$CACHE" 2>/dev/null || echo '{"enabled":1}'
	echo
	;;
flush)
	rm -f /tmp/5gmodem_extip.json /tmp/5gmodem_extip_*.json 2>/dev/null
	echo '{"ok":1}'
	;;
probe)
	# Разовая проверка сервиса из настроек - мимо кэша и мимо выключателя.
	_pu="$2"; _pf="$3"; _pa="$4"
	case "$_pf" in 6) _pf=6 ;; *) _pf=4 ;; esac
	[ -n "$_pu" ] || { echo '{"ok":0,"error":"no-url"}'; exit 0; }
	_po=$(_fetch "$_pu" "$_pf" "$_pa")
	if [ "$_pf" = 6 ]; then _pi=$(_parse6 "$_po"); else _pi=$(_parse4 "$_po"); fi
	_pc=$(_parsecc "$_po")
	if [ -z "$_pc" ] && [ -n "$_pi" ] && [ "$_pf" = 4 ]; then
		_pcu=$(_ccurl)
		[ -n "$_pcu" ] && _pc=$(_parsecc "$(_fetch "$(printf '%s' "$_pcu" | sed "s|{ip}|$_pi|g")" 4 "$_pa")")
	fi
	if [ -n "$_pi" ]; then
		printf '{"ok":1,"ip":"%s","cc":"%s","src":"%s"}\n' \
			"$(_esc "$_pi")" "$(_esc "$_pc")" "$(_esc "$(_host "$_pu")")"
	else
		printf '{"ok":0,"error":"no-answer","src":"%s"}\n' "$(_esc "$(_host "$_pu")")"
	fi
	;;
*)
	echo "Usage: $0 get [iface] | now [iface] | flush | probe <url> [4|6] [ua]" >&2
	exit 1
	;;
esac
