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
TG_CMD=$(_cfg tg_commands)
# ОКНО «ПЕРВОЙ ВСТРЕЧИ» С МОДЕМОМ, ЧАСЫ. Модем, которого бот видит впервые, не
# должен вываливать в чат всю память SIM - но и молчать про свежие сообщения
# неправильно: человек только что воткнул модем и ждёт, что бот заработает.
# Компромисс: шлём то, что пришло за последние N часов, остальное помечаем
# виденным молча. 0 - прежнее поведение (не слать ничего).
TG_FIRSTH=$(_cfg tg_first_hours); case "$TG_FIRSTH" in ''|*[!0-9]*) TG_FIRSTH=24 ;; esac
STORE=$(_cfg storage); [ -n "$STORE" ] || STORE=SM
PORT=$(_cfg readport)

STAMP=/tmp/5gmodem_tg_last
# Номер последнего разобранного апдейта. НА ФЛЕШЕ: после перезагрузки роутера
# команды из чата не должны выполниться повторно - «отправь SMS» дважды это не
# то же самое, что дважды показать страницу.
OFFSET=/etc/5gmodem/tg_offset
# Отметка «в чат уже объяснили, как отправлять». На флеше: приглашение должно
# прийти ОДИН раз за всё время, а не после каждой перезагрузки.
ANNOUNCED=/etc/5gmodem/tg_announced
LASTLOG=/tmp/5gmodem_tg_result

_log() { logger -t 5gmodem "telegram: $*"; }

_ready() {
	[ "$TG_EN" = "1" ] || return 1
	[ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ] || return 1
	command -v curl >/dev/null 2>&1 || return 1
	return 0
}

# КОДИРОВКУ ЧИНИТ МОСТ (smsbridge -> utf8_fix в lib.sh), здесь остаётся
# страховка на СВОИ тексты: ответы на команды и статус собираются из имён
# операторов и моделей, а они тоже приходят из модема. Функция идемпотентна,
# двойной проход валидный текст не портит.
. "$RES/lib.sh" 2>/dev/null

# Отправка одного сообщения. Текст уходит через --data-urlencode: в SMS бывает
# что угодно, включая переводы строк, & и знаки процента, и собирать URL руками
# здесь значит однажды отправить обрезанный текст.
#
# Код возврата: 0 - доставлено, 1 - не дошли (сеть, токен, чат) - надо повторить,
# 2 - Телеграм ОТКАЗАЛСЯ принимать это сообщение (4xx). Разница принципиальна:
# при 1 круг надо прервать и повторить позже, а при 2 повторять бессмысленно -
# одно негодное сообщение иначе держит очередь вечно (так и было с битой SMS).
# ПРЯМОЙ 443 К TELEGRAM У ОПЕРАТОРОВ РФ ЗАКРЫТ, а СВОЙ трафик роутера идёт
# мимо clash: tproxy перехватывает только форвард из LAN (живой стенд
# 07.08.2026: прямой curl - таймаут, через mixed-порт отвечает). Тот же обход,
# что у пробы Telegram в netpri.sh и geo-запросов спидтеста: сначала прямой
# путь (за границей и на VPN-роуте он быстрее и не зависит от clash), при
# молчании - повтор через http/mixed-порт clash. Ответ с полем "ok" - ЛЮБОЕ
# слово от сервера, включая честную ошибку токена: такое прокси не лечит и
# повторять его не надо.
# Запрос к API clash (ssclash держит его на 9090); секрет - если задан в конфиге.
_TG_CAPI=http://127.0.0.1:9090
_tg_capi() {
	if [ -n "$_TG_CSEC" ]; then
		curl -s -m 3 -H "Authorization: Bearer $_TG_CSEC" "$@" 2>/dev/null
	else
		curl -s -m 3 "$@" 2>/dev/null
	fi
}

# HTTP-порт clash тремя способами, по возрастанию хитрости:
#   1) mixed-port/port из файла конфига (legacy-раскладка ssclash);
#   2) РАНТАЙМ mihomo: в tproxy/tun-конфиге HTTP-порта в файле нет вовсе, но
#      он мог быть открыт на лету - спрашиваем /configs;
#   3) порт закрыт - просим mihomo ОТКРЫТЬ его через PATCH /configs. Это
#      штатная ручка (ею пользуются все дашборды), слушает только 127.0.0.1 и
#      живёт до перезапуска clash; повторные вызовы находят порт шагом 2 и
#      PATCH больше не дёргают. Проверено на живом стенде (mihomo 1.19.29,
#      tproxy-конфиг без единого HTTP-порта): 204 -> порт слушает -> Telegram
#      отвечает через него 302.
_tg_proxy_port() {
	_tp_f=$(sed -n 's/^ *\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	case "$_tp_f" in ''|0) ;; *) printf '%s' "$_tp_f"; return 0 ;; esac
	_TG_CSEC=$(sed -n "s/^ *secret *: *[\"']*\([^\"' ]*\).*/\1/p" \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	_tp_r=$(_tg_capi "$_TG_CAPI/configs" | jsonfilter -e '@["mixed-port"]' 2>/dev/null)
	case "$_tp_r" in ''|*[!0-9]*) return 1 ;; esac
	if [ "$_tp_r" = "0" ]; then
		_tg_capi -X PATCH "$_TG_CAPI/configs" -d '{"mixed-port":7895}' -o /dev/null || return 1
		_tp_r=7895
		logger -t 5gmodem "telegram: direct path to api.telegram.org is blocked - opened clash mixed-port 7895 (API, 127.0.0.1 only)"
	fi
	printf '%s' "$_tp_r"
}

# Отметка «прямой путь мёртв»: без неё КАЖДЫЙ вызов (а тик шлёт и опрашивает
# каждые ~30 c) сжигал бы таймаут прямой попытки впустую. TTL 10 минут: смена
# аплинка на туннельный снимет блокировку - и мы это заметим.
_TG_DDEAD=/tmp/5gmodem_tg_direct_dead
_tg_direct_dead() {
	_td_t=$(cat "$_TG_DDEAD" 2>/dev/null)
	case "$_td_t" in ''|*[!0-9]*) return 1 ;; esac
	read -r _td_n _ < /proc/uptime; _td_n=${_td_n%%.*}
	[ $((_td_n - _td_t)) -lt 600 ]
}

_tg_curl() {   # аргументы curl без -s/-m
	_tc_o=""
	if ! _tg_direct_dead; then
		# 8 c, не 20: живой прямой путь отвечает за секунды, а на закрытом
		# каждая лишняя секунда - это висящая кнопка и замёрзший тик.
		_tc_o=$(curl -s -m 8 "$@" 2>&1)
		case "$_tc_o" in
			*'"ok":'*) rm -f "$_TG_DDEAD" 2>/dev/null; printf '%s' "$_tc_o"; return 0 ;;
		esac
		read -r _tc_n _ < /proc/uptime; printf '%s' "${_tc_n%%.*}" > "$_TG_DDEAD" 2>/dev/null
	fi
	_tc_pp=$(_tg_proxy_port)
	if [ -n "$_tc_pp" ] && [ "$_tc_pp" != "0" ]; then
		_tc_p=$(curl -s -m 20 -x "http://127.0.0.1:$_tc_pp" "$@" 2>&1)
		case "$_tc_p" in
			*'"ok":'*) printf '%s' "$_tc_p"; return 0 ;;
		esac
	fi
	printf '%s' "$_tc_o"
	return 1
}

_tg_send() {   # $1 - текст
	_ts_t=$(printf '%s' "$1" | utf8_fix)
	_ts_o=$(_tg_curl "https://api.telegram.org/bot$TG_TOKEN/sendMessage" \
		--data-urlencode "chat_id=$TG_CHAT" \
		--data-urlencode "text=$_ts_t" \
		-d "disable_web_page_preview=true")
	case "$_ts_o" in
		*'"ok":true'*) printf 'ok' > "$LASTLOG" 2>/dev/null; return 0 ;;
	esac
	# Причину сохраняем для страницы: чаще всего это неверный токен, чужой
	# chat_id или недоступный api.telegram.org.
	printf '%s' "$(printf '%s' "$_ts_o" | tr -d '\n' | head -c 200)" > "$LASTLOG" 2>/dev/null
	case "$_ts_o" in
		*'"error_code":40'*) return 2 ;;
	esac
	return 1
}

_seen_json() { SMS_MODEM="$1" "$RES/smsbridge.sh" seen 2>/dev/null; }

# ===== КОГО ОБХОДИМ =====
#
# ВСЕ модемы, а не только активный. Раньше порт брался один - sms.readport, а он
# описывает модем, чья вкладка открыта: у человека с Compal и Telit входящие
# Telit не приходили в чат ВООБЩЕ, пока он не переключит вкладку (живой случай
# 01.08.2026). Список даёт реестр, порт - секция модема; память о прочитанном у
# каждого модема своя и раньше (smsbridge sms_seen.<путь>), так что дубликатов
# от этой перемены нет.
_tg_paths() { "$RES/registry.sh" paths 2>/dev/null; }

_tg_sec() { printf 'm_%s' "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

# Порт для чтения SMS у модема $1. У АКТИВНОГО - настроенный readport: он выбран
# так, чтобы не конкурировать с портом метрик. У остальных - AT-порт из их
# секции. Пусто - модем читается не по tty (HiLink/MM), мост разберётся сам.
_tg_port() {
	[ "$1" = "$(uci -q get "$CFG.@5gmodem[0].active_modem")" ] && { printf '%s' "$PORT"; return; }
	uci -q get "$CFG.$(_tg_sec "$1").at_port"
}

# Человеческое имя модема для подписи сообщения: модель, иначе путь.
_tg_name() {
	_tn=$(uci -q get "$CFG.$(_tg_sec "$1").model")
	[ -n "$_tn" ] || _tn=$(uci -q get "$CFG.$(_tg_sec "$1").product")
	[ -n "$_tn" ] || _tn="$1"
	printf '%s' "$_tn"
}

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

	# Модем за модемом. Провал доставки прекращает круг ЦЕЛИКОМ (лежит сеть -
	# остальным тоже не уйдёт), а провал чтения одного модема - только его:
	# соседи не должны молчать из-за занятого порта.
	_tk_any=$(_tg_paths)
	[ -n "$_tk_any" ] || _tk_any=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	for _tk_p in $_tk_any; do
		_tk_one "$_tk_p" || return 0
	done
	return 0
}

# Есть ли у устройства канал SMS вообще: tty или cdc-wdm в списке, либо HiLink.
# Телефон-тетеринг (в списке ради вкладки) не имеет НИЧЕГО из этого - и его
# нужно пропустить ДО чтения: у неактивного модема с пустым портом smsbridge
# падает на глобальный readport, то есть бот читал бы входящие АКТИВНОГО модема
# под именем телефона - каждое сообщение приходило бы в чат дважды.
_tg_has_sms() {   # $1 - usb-путь
	[ "$(uci -q get "$CFG.$(_tg_sec "$1").kind")" = "hilink" ] && return 0
	"$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$1\"].tty[0]" -e "@[@.path=\"$1\"].wdm[0]" 2>/dev/null \
		| grep -q .
}

_tk_one() {   # $1 - usb-путь модема; 1 = дальше идти нельзя (Telegram недоступен)
	_tk_path="$1"
	_tg_has_sms "$_tk_path" || return 0
	_tk_port=$(_tg_port "$_tk_path")
	_tk_seen=$(_seen_json "$_tk_path")
	_tk_first=$(printf '%s' "$_tk_seen" | jsonfilter -e '@.first' 2>/dev/null)
	_tk_keys=$(printf '%s' "$_tk_seen" | jsonfilter -e '@.keys[*]' 2>/dev/null)

	_tk_msgs=$(SMS_MODEM="$_tk_path" "$RES/smsbridge.sh" recv "$STORE" "$_tk_port" 2>/dev/null)
	[ -n "$_tk_msgs" ] || return 0
	# Подпись модема ставим, только когда их несколько: с одним она лишний шум.
	_tk_tag=""
	case "$_tk_any" in
		*" "*) _tk_tag=" ($(_tg_name "$_tk_path"))" ;;
	esac

	_tk_idx=$(printf '%s' "$_tk_msgs" | jsonfilter -e '@.msg[*].index' 2>/dev/null)
	_tk_n=0
	for _tk_i in $_tk_idx; do
		_tk_snd=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].sender" 2>/dev/null)
		_tk_ts=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].timestamp" 2>/dev/null)
		_tk_txt=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].content" 2>/dev/null)
		_tk_tot=$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_i].total" 2>/dev/null)
		_tk_key="$_tk_snd|$_tk_ts"
		# Уже видели - пропускаем (ключ тот же, что считает страница). В список
		# виденного дописываем и то, что отправили В ЭТОМ круге: у длинной SMS
		# все части несут ОДИН ключ, а список прочитан до цикла - без этого
		# сообщение из шести частей улетало в чат шестью кусками.
		case "
$_tk_keys
" in
			*"
$_tk_key
"*) continue ;;
		esac
		_tk_keys="$_tk_keys
$_tk_key"
		# ДЛИННАЯ SMS - СОБИРАЕМ ЦЕЛИКОМ. Модем отдаёт её частями (part/total), и
		# читать в чате «...ерь баланс» без начала невозможно. Порядок берём по
		# номеру части, а не по индексу в памяти модема: они совпадают не всегда.
		case "$_tk_tot" in
			''|0|1) : ;;
			*[!0-9]*) : ;;
			*)
				_tk_full=""
				_tk_pn=1
				while [ "$_tk_pn" -le "$_tk_tot" ]; do
					for _tk_j in $_tk_idx; do
						[ "$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_j].sender" 2>/dev/null)" = "$_tk_snd" ] || continue
						[ "$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_j].timestamp" 2>/dev/null)" = "$_tk_ts" ] || continue
						[ "$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_j].part" 2>/dev/null)" = "$_tk_pn" ] || continue
						_tk_full="$_tk_full$(printf '%s' "$_tk_msgs" | jsonfilter -e "@.msg[@.index=$_tk_j].content" 2>/dev/null)"
						break
					done
					_tk_pn=$((_tk_pn + 1))
				done
				[ -n "$_tk_full" ] && _tk_txt="$_tk_full" ;;
		esac
		if [ "$_tk_first" = "1" ]; then
			# ПЕРВАЯ ВСТРЕЧА С МОДЕМОМ. Старое обещанное правило - «ничего не
			# слать» - целиком верно только для памяти, набитой за год. Свежие
			# сообщения человек ждёт: он воткнул модем минуту назад. Поэтому
			# окно TG_FIRSTH часов: что новее - уходит в чат обычным путём (код
			# ниже), что старше - помечаем виденным молча.
			#
			# Метку времени sms_tool печатает в UTC и игнорирует $TZ (проверено),
			# поэтому и сравниваем в UTC. Не разобралось - считаем старым: лучше
			# промолчать, чем высыпать архив.
			_tk_old=1
			if [ "$TG_FIRSTH" != 0 ]; then
				_tk_ts_e=$(date -u -D '%Y-%m-%d %H:%M' -d "$_tk_ts" +%s 2>/dev/null)
				case "$_tk_ts_e" in
					''|*[!0-9]*) : ;;
					*) [ $(( $(date -u +%s) - _tk_ts_e )) -lt $((TG_FIRSTH * 3600)) ] && _tk_old="" ;;
				esac
			fi
			if [ -n "$_tk_old" ]; then
				SMS_MODEM="$_tk_path" "$RES/smsbridge.sh" seen-add "$_tk_key" >/dev/null 2>&1
				_tk_n=$((_tk_n + 1))
				continue
			fi
		fi
		_tg_send "SMS $_tk_snd$_tk_tag
$_tk_ts

$_tk_txt"
		case "$?" in
			0)
				SMS_MODEM="$_tk_path" "$RES/smsbridge.sh" seen-add "$_tk_key" >/dev/null 2>&1
				_tk_n=$((_tk_n + 1)) ;;
			2)
				# ТЕЛЕГРАМ ОТКАЗАЛСЯ ИМЕННО ОТ ЭТОГО ТЕКСТА. Повторять нечего, а
				# держать им очередь нельзя - следом стоят нормальные сообщения.
				# Человеку шлём хотя бы факт: от кого и когда, чтобы он открыл
				# «Входящие» и прочитал глазами.
				_log "Telegram rejected the message from $_tk_snd ($_tk_ts): $(cat "$LASTLOG" 2>/dev/null | head -c 120)"
				_tg_send "SMS $_tk_snd$_tk_tag
$_tk_ts

(текст не принят Telegram - откройте «Входящие» на роутере)" >/dev/null 2>&1
				SMS_MODEM="$_tk_path" "$RES/smsbridge.sh" seen-add "$_tk_key" >/dev/null 2>&1 ;;
			*)
				# Не доставили - НЕ помечаем и прекращаем ВЕСЬ круг: если лежит
				# сеть, остальным модемам в этом круге тоже не уйдёт. Сообщение
				# остаётся в памяти модема и в «невиденных» - следующий круг
				# попробует снова. Это и есть очередь недоставленного: терять
				# нечего, пока сообщение не подтверждено Телеграмом.
				_log "not delivered ($(cat "$LASTLOG" 2>/dev/null | head -c 120))"
				return 1 ;;
		esac
	done
	if [ "$_tk_first" = "1" ] && [ "$_tk_n" -gt 0 ]; then
		_log "first encounter with modem $(_tg_name "$_tk_path"): processed $_tk_n messages (newer than ${TG_FIRSTH}h go to the chat, older ones are silently marked seen)"
	elif [ "$_tk_n" -gt 0 ]; then
		_log "messages forwarded: $_tk_n ($(_tg_name "$_tk_path"))"
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
	_ci_o=$(_tg_curl "https://api.telegram.org/bot$TG_TOKEN/getUpdates")
	case "$_ci_o" in
		*'"ok":true'*) ;;
		'')
			# Пустота = не ответил ни прямой путь, ни прокси: это не «неверный
			# токен», а сеть. Отдаём код - страница покажет человеку, что
			# именно происходит и чем лечится.
			echo '{"ok":false,"error":"noreply"}'
			return 0 ;;
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

# СОСТОЯНИЕ МОДЕМА ДЛЯ ЧАТА - ТЕМИ ЖЕ ПРАВИЛАМИ, ЧТО И КАРТОЧКА.
#
# Пустые поля НЕ печатаем: снимок отдаёт «-» там, где модем промолчал, и строка
# «Температура: -» в чате бесполезна.
#
# ТЕМПЕРАТУРА КАК В КАРТОЧКЕ. Часть модемов градусов не отдаёт вовсе, но
# сообщает уровень троттлинга 0..3 - тогда карточка пишет словом («В норме»), и
# бот должен говорить то же самое. Есть градусы - показываем их, а уровень 1..3
# добавляем через запятую (0 не добавляем: «32 °C, В норме» - шум).
_st_field() {   # $1 - снимок, $2 - поле
	_sf_v=$(printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null)
	case "$_sf_v" in ''|-) return 1 ;; esac
	printf '%s' "$_sf_v"
}
_st_therm() {   # $1 - снимок; печатает готовую строку температуры или ничего
	_th_t=$(_st_field "$1" mtemp)
	_th_l=$(_st_field "$1" mtherm)
	case "$_th_l" in
		0) _th_w="В норме" ;;
		1) _th_w="Тёплый" ;;
		2) _th_w="Горячий" ;;
		3) _th_w="Критический" ;;
		*) _th_w="" ;;
	esac
	if [ -n "$_th_t" ]; then
		# Снимок отдаёт «32 &deg;C» - для чата приводим к обычному градусу.
		_th_t=$(printf '%s' "$_th_t" | sed 's/&deg;/°/g')
		case "$_th_l" in
			1|2|3) printf 'Температура: %s, %s' "$_th_t" "$_th_w" ;;
			*)     printf 'Температура: %s' "$_th_t" ;;
		esac
		return 0
	fi
	[ -n "$_th_w" ] && printf 'Температура: %s' "$_th_w"
	return 0
}
# НОМЕРА МОДЕМОВ ДЛЯ ЧАТА. Порядок - как отдаёт реестр (он стабилен: ключ
# секции = USB-путь). Номер живёт ровно один разговор и нигде не хранится:
# показывать человеку USB-путь «2-1.4» в команде - издевательство.
_tg_path_by_num() {   # $1 - номер (с единицы)
	_pn=0
	for _pp in $(_tg_paths); do
		_pn=$((_pn + 1))
		[ "$_pn" = "$1" ] && { printf '%s' "$_pp"; return 0; }
	done
	return 1
}

_tg_list() {
	_lact=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_ln=0
	for _lp in $(_tg_paths); do
		_ln=$((_ln + 1))
		_lop=$(printf '%s' "$("$RES/5gmodem.sh" peek "$_lp" 2>/dev/null)" \
			| jsonfilter -e '@.operator_name' 2>/dev/null)
		case "$_lop" in ''|-) _lop="" ;; *) _lop=" - $_lop" ;; esac
		[ "$_lp" = "$_lact" ] && _lop="$_lop (активный)"
		printf '%s. %s%s\n' "$_ln" "$(_tg_name "$_lp")" "$_lop"
	done
}

status_text() {   # $1 - usb-путь модема (пусто - активный)
	if [ -n "$1" ]; then
		_st_j=$("$RES/5gmodem.sh" peek "$1" 2>/dev/null)
	else
		_st_j=$("$RES/5gmodem.sh" peek 2>/dev/null)
	fi
	[ -n "$_st_j" ] || { printf 'Снимка метрик пока нет - модем ещё опрашивается.'; return 0; }
	_st_out="Модем: $(_st_field "$_st_j" modem)"
	_st_v=$(_st_field "$_st_j" operator_name) && _st_out="$_st_out
Оператор: $_st_v"
	_st_v=$(_st_field "$_st_j" mode) && _st_out="$_st_out
Сеть: $_st_v"
	_st_v=$(_st_field "$_st_j" signal) && _st_out="$_st_out
Сигнал: $_st_v%"
	_st_v=$(_st_therm "$_st_j"); [ -n "$_st_v" ] && _st_out="$_st_out
$_st_v"
	_st_v=$(_st_field "$_st_j" conn_time) && _st_out="$_st_out
Соединение: $_st_v"
	_st_rx=$(_st_field "$_st_j" rx); _st_tx=$(_st_field "$_st_j" tx)
	[ -n "$_st_rx$_st_tx" ] && _st_out="$_st_out
Трафик: ↓ ${_st_rx:-?}  ↑ ${_st_tx:-?}"
	_st_v=$(_st_field "$_st_j" ipaddr) && _st_out="$_st_out
Адрес: $_st_v"
	printf '%s' "$_st_out"
}

# КОМАНДЫ ИЗ ЧАТА - ОТПРАВКА SMS ИЗ TELEGRAM.
#
# КТО МОЖЕТ КОМАНДОВАТЬ. Только тот чат, который записан в настройках
# (tg_chat). Бот доступен любому, кто узнал его имя, а команда тратит деньги и
# говорит от имени владельца симки - поэтому проверка авторства здесь не
# «на будущее», а обязательная часть функции. Всем прочим отвечаем молчанием:
# сообщать чужому, что он «не хозяин», значит подтверждать, что бот боевой.
#
# ЧТО ПОНИМАЕМ:
#   /sms <номер> <текст>  - отправить SMS (номер в любом виде, приводится к
#                           международному самим smsbridge)
#   /status [<номер>|all] - оператор, сигнал, адрес одного модема или всех
#   /modem [<номер>]      - список модемов / смена активного
#   /help                 - подсказка со списком модемов
#
# ПОВТОРОВ НЕ ДОПУСКАЕМ. Telegram отдаёт апдейт, пока его не подтвердили
# смещением; смещение храним на флеше и двигаем ТОЛЬКО после разбора, иначе
# перезагрузка роутера посреди круга отправила бы то же сообщение второй раз.
_tg_reply() { _tg_send "$1" >/dev/null 2>&1; }

# «Через что ушло»: модель и оператор активного модема. При двух модемах это
# первый вопрос, который возникает у человека, увидевшего «отправлено».
_tg_via() {
	_tv_j=$("$RES/5gmodem.sh" peek 2>/dev/null)
	_tv_m=$(printf '%s' "$_tv_j" | jsonfilter -e '@.modem' 2>/dev/null)
	_tv_o=$(printf '%s' "$_tv_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
	case "$_tv_m" in ''|-) return 0 ;; esac
	case "$_tv_o" in ''|-) printf ' через %s' "$_tv_m"; return 0 ;; esac
	printf ' через %s (%s)' "$_tv_m" "$_tv_o"
}

commands() {
	[ "$TG_CMD" = "1" ] || return 0
	_ready || return 0
	# ПЕРВОЕ ВКЛЮЧЕНИЕ - ОБЪЯСНЯЕМ В САМОМ ЧАТЕ. Документация, которая приходит
	# туда, где человек будет работать, стоит десяти строк подсказки в вебе.
	if [ ! -f "$ANNOUNCED" ]; then
		if _tg_send "Отправка SMS из чата включена.
Команда: /sms <номер> <текст>
Например: /sms +79001234567 Привет
Ещё есть /status - состояние модема (/status all - все),
и /modem - список модемов, /modem <номер> - сделать активным."; then
			: > "$ANNOUNCED" 2>/dev/null
		fi
	fi
	_co_off=$(cat "$OFFSET" 2>/dev/null)
	case "$_co_off" in ''|*[!0-9]*) _co_off=0 ;; esac
	_co_url="https://api.telegram.org/bot$TG_TOKEN/getUpdates?timeout=0&limit=10"
	[ "$_co_off" -gt 0 ] && _co_url="$_co_url&offset=$_co_off"
	_co_j=$(_tg_curl "$_co_url")
	case "$_co_j" in *'"ok":true'*) ;; *) return 0 ;; esac

	_co_i=0
	_co_max="$_co_off"
	while [ "$_co_i" -lt 10 ]; do
		_co_u=$(printf '%s' "$_co_j" | jsonfilter -e "@.result[$_co_i].update_id" 2>/dev/null)
		[ -n "$_co_u" ] || break
		_co_i=$((_co_i + 1))
		# СВОЯ ЗАЩИТА ОТ ПОВТОРА, а не только серверная. Telegram отдаёт лишь
		# апдейты новее смещения, но полагаться на это нельзя: сбой сети, чужой
		# опрос тем же токеном или наш собственный getUpdates из кнопки «найти
		# Chat ID» могут вернуть старое. Команда тратит деньги - повтор
		# недопустим, поэтому старое отбрасываем сами.
		[ "$_co_u" -lt "$_co_off" ] && continue
		[ "$_co_u" -ge "$_co_max" ] && _co_max=$((_co_u + 1))
		_co_chat=$(printf '%s' "$_co_j" | jsonfilter -e "@.result[$((_co_i - 1))].message.chat.id" 2>/dev/null)
		_co_txt=$(printf '%s' "$_co_j" | jsonfilter -e "@.result[$((_co_i - 1))].message.text" 2>/dev/null)
		[ -n "$_co_txt" ] || continue
		# ЧУЖОЙ ЧАТ - МОЛЧА МИМО.
		[ "$_co_chat" = "$TG_CHAT" ] || {
			_log "command from foreign chat $_co_chat ignored"
			continue
		}
		case "$_co_txt" in
			/sms\ *)
				_co_rest=${_co_txt#/sms }
				_co_to=${_co_rest%% *}
				_co_body=${_co_rest#* }
				if [ -z "$_co_to" ] || [ "$_co_body" = "$_co_rest" ] || [ -z "$_co_body" ]; then
					_tg_reply "Формат: /sms <номер> <текст>"
					continue
				fi
				_co_port=$(uci -q get "$CFG.sms.sendport")
				_co_out=$("$RES/smsbridge.sh" send "$_co_to" "$_co_body" "$_co_port" 2>&1)
				case "$_co_out" in
					*sucessfully*) _tg_reply "SMS отправлена на $_co_to$(_tg_via)" ;;
					*queued*)      _tg_reply "Порт занят, поставил в очередь - отправлю при первой возможности ($_co_to)" ;;
					*)             _tg_reply "Не удалось отправить на $_co_to: ${_co_out:-нет ответа}" ;;
				esac
				_log "chat command: SMS to $_co_to" ;;
			/sms|/sms@*)
				_tg_reply "Формат: /sms <номер> <текст>" ;;
			/status\ *)
				_co_arg=${_co_txt#/status }
				_co_arg=${_co_arg%% *}
				case "$_co_arg" in
					all)
						_co_n=0
						for _co_p in $(_tg_paths); do
							_co_n=$((_co_n + 1))
							_tg_reply "[$_co_n] $(_tg_name "$_co_p")
$(status_text "$_co_p")"
						done
						[ "$_co_n" = 0 ] && _tg_reply "Модемов не найдено." ;;
					[0-9]*)
						_co_p=$(_tg_path_by_num "$_co_arg") \
							&& _tg_reply "[$_co_arg] $(_tg_name "$_co_p")
$(status_text "$_co_p")" \
							|| _tg_reply "Нет модема с номером $_co_arg. Список:
$(_tg_list)" ;;
					*) _tg_reply "Формат: /status, /status <номер> или /status all
$(_tg_list)" ;;
				esac ;;
			/status*)
				_tg_reply "$(status_text)" ;;
			/modem\ *)
				# СМЕНА АКТИВНОГО МОДЕМА ИЗ ЧАТА. Для входящих SMS она больше не
				# нужна (бот обходит всех), но остаётся управлением: активный
				# модем - это и вкладка в вебе, и цель /sms, и источник /status
				# без аргумента.
				_co_arg=${_co_txt#/modem }
				_co_arg=${_co_arg%% *}
				_co_p=$(_tg_path_by_num "$_co_arg") || {
					_tg_reply "Нет модема с номером $_co_arg. Список:
$(_tg_list)"
					continue
				}
				if "$RES/modemswitch.sh" switch "$_co_p" >/dev/null 2>&1; then
					_log "chat command: active modem -> $_co_p"
					_tg_reply "Активный модем: $(_tg_name "$_co_p")
$(status_text "$_co_p")"
				else
					_tg_reply "Не удалось переключиться на $(_tg_name "$_co_p")"
				fi ;;
			/modem*)
				_tg_reply "Модемы:
$(_tg_list)
Переключить: /modem <номер>" ;;
			/help*|/start*)
				_tg_reply "Команды:
/sms <номер> <текст> - отправить SMS
/status - состояние активного модема
/status <номер> | /status all - состояние конкретного или всех
/modem - список модемов, /modem <номер> - сделать активным
Входящие SMS приходят сюда сами - со всех модемов.

Модемы:
$(_tg_list)" ;;
		esac
	done
	[ "$_co_max" != "$_co_off" ] && printf '%s' "$_co_max" > "$OFFSET" 2>/dev/null
	return 0
}

case "$1" in
	tick) tick; commands ;;
	commands) commands ;;
	# То же, что покажет /modem в чате. Отдельным вербом - чтобы проверять
	# нумерацию, не трогая живой чат.
	modems) _tg_list ;;
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
	*) echo "usage: $0 tick|test|chatid|setchat <id>|commands|modems|status" >&2; exit 2 ;;
esac
exit 0
