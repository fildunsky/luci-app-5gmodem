#!/bin/sh
#
# ПЕРЕСЫЛКА ВХОДЯЩИХ SMS В TELEGRAM.
#
# ЗАЧЕМ. Роутер часто стоит там, где его веб-морду никто не открывает неделями, а
# сообщения оператора (баланс, коды, отключения) приходят именно на его симку.
# Бот доставляет их туда, где человек и так читает.
#
# ЧТО СЧИТАЕТСЯ НОВЫМ. Ровно то же, что подсвечивает страница «Входящие»: ключ
# сообщения «отправитель|время» и общий список виденных, которым владеет
# smsbridge.sh (seen / seen-add). Своего учёта здесь НЕТ намеренно - иначе бот и
# страница разошлись бы во мнении, что человек уже видел.
#
# ПОРЯДОК ГАРАНТИЙ. Отметка «виденное» ставится ТОЛЬКО после успешной доставки в
# Telegram: сеть у роутера может лежать (а в РФ к api.telegram.org ещё и без
# обхода не достучаться), и потерять сообщение молча нельзя - следующий круг
# попробует снова.
#
# ПЕРВЫЙ ЗАПУСК НИЧЕГО НЕ ШЛЁТ. Если про эту карту мы ещё ничего не знаем,
# входящие могли прийти год назад - высыпать их в чат разом было бы вредно.
# Помечаем текущие виденными и начинаем следить с этого момента.
#
#   tgnotify.sh tick     - круг проверки (зовётся из sessionwatch)
#   tgnotify.sh test     - отправить пробное сообщение (кнопка в настройках)
#   tgnotify.sh chatid   - найти Chat ID по недавним сообщениям боту
#   tgnotify.sh status   - JSON о состоянии для страницы

RES=/usr/share/5gmodem
CFG=5gmodem

_cfg() { uci -q get "$CFG.sms.$1" 2>/dev/null; }

TG_EN=$(_cfg tg_enabled)
TG_TOKEN=$(_cfg tg_token)
TG_CHAT=$(_cfg tg_chat)
TG_INT=$(_cfg tg_interval); case "$TG_INT" in ''|*[!0-9]*) TG_INT=60 ;; esac
STORE=$(_cfg storage); [ -n "$STORE" ] || STORE=SM
PORT=$(_cfg readport)

STAMP=/tmp/5gmodem_tg_last
LASTLOG=/tmp/5gmodem_tg_result

_log() { logger -t 5gmodem "telegram: $*"; }

_ready() {
	[ "$TG_EN" = "1" ] || return 1
	[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 1
	command -v curl >/dev/null 2>&1 || return 1
	return 0
}

# Отправка одного сообщения. Текст уходит через --data-urlencode: в SMS бывает
# что угодно, включая переводы строк, & и знаки процента, и собирать URL руками
# здесь значит однажды отправить обрезанный текст.
_tg_send() {   # $1 - текст
	_ts_o=$(curl -s -m 20 "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
		--data-urlencode "chat_id=$TG_CHAT" \
		--data-urlencode "text=$1" \
		-d "disable_web_page_preview=true" 2>&1)
	case "$_ts_o" in
		*'"ok":true'*) printf 'ok' > "$LASTLOG" 2>/dev/null; return 0 ;;
	esac
	# Причину сохраняем для страницы: чаще всего это неверный токен, чужой
	# chat_id или недоступный api.telegram.org.
	printf '%s' "$(printf '%s' "$_ts_o" | tr -d '\n' | head -c 200)" > "$LASTLOG" 2>/dev/null
	return 1
}

_seen_json() { "$RES/smsbridge.sh" seen 2>/dev/null; }

tick() {
	_ready || return 0
	# Свой предохранитель по времени: сторож зовёт нас каждые 30 c, а лезть в
	# AT-порт за списком сообщений так часто незачем.
	read -r _tk_now _ < /proc/uptime
	_tk_now=${_tk_now%%.*}
	_tk_prev=$(cat "$STAMP" 2>/dev/null)
	case "$_tk_prev" in ''|*[!0-9]*) _tk_prev=0 ;; esac
	[ $((_tk_now - _tk_prev)) -ge "$TG_INT" ] || return 0
	printf '%s' "$_tk_now" > "$STAMP" 2>/dev/null

	_tk_seen=$(_seen_json)
	_tk_first=$(printf '%s' "$_tk_seen" | jsonfilter -e '@.first' 2>/dev/null)
	_tk_keys=$(printf '%s' "$_tk_seen" | jsonfilter -e '@.keys[*]' 2>/dev/null)

	_tk_msgs=$("$RES/smsbridge.sh" recv "$STORE" "$PORT" 2>/dev/null)
	[ -n "$_tk_msgs" ] || return 0

	_tk_n=0
	for _tk_i in $(printf '%s' "$_tk_msgs" | jsonfilter -e '@.msg[*].index' 2>/dev/null); do
		_tk_snd=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].sender" 2>/dev/null)
		_tk_ts=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].timestamp" 2>/dev/null)
		_tk_txt=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].content" 2>/dev/null)
		_tk_key="$_tk_snd|$_tk_ts"
		# Уже видели - пропускаем (ключ тот же, что считает страница).
		case "
$_tk_keys
" in
			*"
$_tk_key
"*) continue ;;
		esac
		if [ "$_tk_first" = "1" ]; then
			# Первый запуск: только запоминаем, ничего не шлём.
			"$RES/smsbridge.sh" seen-add "$_tk_key" >/dev/null 2>&1
			_tk_n=$((_tk_n + 1))
			continue
		fi
		if _tg_send "SMS $_tk_snd
$_tk_ts

$_tk_txt"; then
			"$RES/smsbridge.sh" seen-add "$_tk_key" >/dev/null 2>&1
			_tk_n=$((_tk_n + 1))
		else
			# Не доставили - НЕ помечаем и прекращаем круг: если лежит сеть,
			# остальные попытки в этом круге тоже впустую.
			_log "не доставлено ($(cat "$LASTLOG" 2>/dev/null | head -c 120))"
			return 0
		fi
	done
	if [ "$_tk_first" = "1" ] && [ "$_tk_n" -gt 0 ]; then
		_log "первый запуск: $_tk_n сообщений помечены виденными, слежение начато"
	elif [ "$_tk_n" -gt 0 ]; then
		_log "переслано сообщений: $_tk_n"
	fi
	return 0
}

# CHAT ID БЕЗ РУЧНОЙ ВОЗНИ.
#
# Телеграм не сообщает идентификатор чата ни при создании бота, ни в интерфейсе:
# его отдаёт только getUpdates, и лишь ПОСЛЕ того, как человек написал боту
# (бот не может начать переписку первым). Раньше это была инструкция в подсказке
# поля; теперь то же самое делает кнопка.
#
# Отдаём ВСЕ найденные чаты с именами: у человека может быть и личный чат, и
# канал, и надо понимать, какой из них какой. У каналов и групп id отрицательный
# - это нормально, так и должно уходить в настройку.
chatid() {
	[ -n "$TG_TOKEN" ] || { echo '{"ok":false,"error":"no token"}'; return 0; }
	command -v curl >/dev/null 2>&1 || { echo '{"ok":false,"error":"no curl"}'; return 0; }
	_ci_o=$(curl -s -m 20 "https://api.telegram.org/bot$TG_TOKEN/getUpdates" 2>&1)
	case "$_ci_o" in
		*'"ok":true'*) ;;
		*)
			printf '{"ok":false,"error":"%s"}\n' \
				"$(printf '%s' "$_ci_o" | tr -d '"\\' | tr '\n' ' ' | head -c 180)"
			return 0 ;;
	esac
	# Разбор без jsonfilter: у getUpdates вложенность разная (message,
	# channel_post, my_chat_member), а нужны две вещи - id и подпись.
	printf '%s' "$_ci_o" | awk '
		BEGIN { RS = "{"; n = 0 }
		/"id":-?[0-9]+/ && /"type":"(private|group|supergroup|channel)"/ {
			id = ""; ttl = ""; typ = ""
			if (match($0, /"id":-?[0-9]+/)) { id = substr($0, RSTART + 5, RLENGTH - 5) }
			if (match($0, /"type":"[a-z]+"/)) { typ = substr($0, RSTART + 8, RLENGTH - 9) }
			if (match($0, /"title":"[^"]*"/)) { ttl = substr($0, RSTART + 9, RLENGTH - 10) }
			else if (match($0, /"first_name":"[^"]*"/)) { ttl = substr($0, RSTART + 14, RLENGTH - 15) }
			else if (match($0, /"username":"[^"]*"/)) { ttl = substr($0, RSTART + 12, RLENGTH - 13) }
			if (id != "" && !(id in seen)) {
				seen[id] = 1
				out = out (n++ ? "," : "") "{\"id\":\"" id "\",\"name\":\"" ttl "\",\"type\":\"" typ "\"}"
			}
		}
		END { printf "{\"ok\":true,\"chats\":[%s]}\n", out }
	'
}

# ЗАПИСЬ НАЙДЕННОГО ID - ОТДЕЛЬНЫМ УЗКИМ ГЛАГОЛОМ.
#
# Страница могла бы просто подставить значение в поле, но тогда оно живёт до
# первого «Сохранить», и человек справедливо недоумевает, почему после «Найти»
# в конфиге пусто. Пишем сразу - и проверяем значение здесь: оно приходит из
# браузера, а уходит в конфиг.
setchat() {   # $1 - идентификатор чата
	case "$1" in
		-[0-9]*|[0-9]*)
			case "${1#-}" in
				*[!0-9]*) echo '{"ok":false,"error":"bad id"}'; return 0 ;;
			esac ;;
		*) echo '{"ok":false,"error":"bad id"}'; return 0 ;;
	esac
	[ "${#1}" -le 20 ] || { echo '{"ok":false,"error":"bad id"}'; return 0; }
	uci -q get "$CFG.sms" >/dev/null 2>&1 || uci -q set "$CFG.sms=sms"
	uci -q set "$CFG.sms.tg_chat=$1"
	uci -q commit "$CFG"
	printf '{"ok":true,"chat":"%s"}\n' "$1"
}

case "$1" in
	tick) tick ;;
	chatid) chatid ;;
	setchat) setchat "$2" ;;
	test)
		if ! _ready; then
			echo '{"ok":false,"error":"not configured"}'
			exit 0
		fi
		if _tg_send "Проверка связи: уведомления о входящих SMS с роутера включены."; then
			echo '{"ok":true}'
		else
			printf '{"ok":false,"error":"%s"}\n' "$(cat "$LASTLOG" 2>/dev/null | tr -d '"\\' | head -c 180)"
		fi ;;
	status)
		_st_cfg=0
		[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] && _st_cfg=1
		printf '{"enabled":%s,"configured":%s,"interval":%s,"last":"%s"}\n' \
			"${TG_EN:-0}" "$_st_cfg" "$TG_INT" \
			"$(cat "$LASTLOG" 2>/dev/null | tr -d '"\\' | head -c 180)" ;;
	*) echo "usage: $0 tick|test|chatid|setchat <id>|status" >&2; exit 2 ;;
esac
exit 0
