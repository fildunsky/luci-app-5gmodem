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
# Usage: smsbridge.sh recv|sent|status [store] [port]
#        smsbridge.sh delete <index|all> [store] [port]
#        smsbridge.sh send <number> <text> [port]
#        smsbridge.sh dump [store] [port]      - входящие ТЕКСТОМ (для файла)
#        smsbridge.sh seen                     - список уже виденных сообщений
#        smsbridge.sh seen-add <ключ>...       - пометить прочитанными
#        smsbridge.sh seen-reset               - забыть всё (снова «новые»)

RES=/usr/share/5gmodem
CFG=5gmodem

# ЧАСОВОЙ ПОЯС НЕ ЧИНИМ ЗДЕСЬ. sms_tool печатает время SMS в UTC и ИГНОРИРУЕТ
# $TZ (проверено на живом порту: и TZ=MSK-3, и TZ=UTC0 дают одинаковый +0000).
# Перевод в местное время делает фронтенд (readsms.js sms_localtime): у него
# есть пояс пользователя, а он может быть даже точнее пояса роутера.

_active_kind() {
	_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_p" ] || return 1
	uci -q get "$CFG.m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g').kind"
}

# ВЫБОР БИНАРЯ - ЗДЕСЬ, а не на странице. У модема под ModemManager (MBIM/QMI,
# напр. Compal RXM-G1) входящие перехватывает MM, и в AT-хранилищах их нет -
# sms_tool их не видит, нужен sms_tool_mm поверх mmcli. Раньше страница сама
# подменяла путь к бинарю, из-за чего КАЖДАЯ операция (чтение, удаление,
# отправка) знала про транспорт и повторяла эту логику по-своему.
# АКТИВНЫЙ МОДЕМ ПОД ModemManager? Флаг sms_via_mm - ГЛОБАЛЬНЫЙ, а транспорт
# у каждого модема свой: с флагом, взведённым ради MM-модема (Compal), смена
# активного на AT-модем гнала и его СМС в mmcli - Telit «разучился читать»,
# recv честно отдавал пустой список ЧУЖОГО (отсутствующего в MM) модема.
# Поэтому флаг теперь значит «MM-путь разрешён», а решает протокол интерфейса
# АКТИВНОГО модема: только modemmanager-модему СМС читает MM.
_active_is_mm() {
	_amp=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_amp" ] || return 1
	_ams="m_$(echo "$_amp" | sed 's/[^A-Za-z0-9]/_/g')"
	_amif=$(uci -q get "$CFG.$_ams.network")
	[ -n "$_amif" ] || _amif=$(uci -q get "$CFG.@5gmodem[0].network")
	[ "$(uci -q get "network.$_amif.proto")" = "modemmanager" ]
}

_smstool() {
	if [ "$(uci -q get 5gmodem.sms.sms_via_mm)" = "1" ] \
	   && [ -x /usr/share/5gmodem/sms_tool_mm ] && _active_is_mm; then
		echo /usr/share/5gmodem/sms_tool_mm
		return
	fi
	command -v sms_tool >/dev/null 2>&1 && echo /usr/bin/sms_tool || echo sms_tool
}

# ===== ПАМЯТЬ О ПРОЧИТАННОМ =====
#
# ЗАЧЕМ ЗДЕСЬ, А НЕ В БРАУЗЕРЕ. Статуса прочтения у модема не спросишь:
# `sms_tool -j` его не отдаёт вовсе, а AT+CMGL="ALL" показывает REC UNREAD только
# ДО первого чтения - дальше модем сам переводит всё в REC READ. Значит новизну
# приложение обязано считать само, и помнить виденное должен РОУТЕР: в
# localStorage память своя у каждого браузера (телефон не знал бы, что прочитано
# с ноутбука) и пропадает при чистке кеша. Этой же памятью будет пользоваться
# автопересылка в Telegram - иначе после каждой перезагрузки она слала бы
# дубликаты.
#
# КЛЮЧ СООБЩЕНИЯ считает страница (там настоящий разбор JSON) из отправителя,
# времени, номера склейки и части - но НЕ из порядкового номера: модем
# переиспользует освободившиеся номера после удаления, и чужое сообщение молча
# унаследовало бы чужую отметку. Здесь ключи только хранятся.
#
# ФАЙЛ НА МОДЕМ (по его USB-пути, как и остальные секции). Привязать к SIM было
# бы точнее - карту переставляют вместе с сообщениями, - но ICCID приложение
# нигде не хранит, а спрашивать его у модема ради каждой отметки значит лезть в
# AT-порт в общей очереди. Цена промаха мягкая: после смены SIM в том же модеме
# часть сообщений один раз подсветится как новые.
SEEN_DIR=/etc/5gmodem
SEEN_MAX=500

_seen_file() {
	_sp=$(uci -q get "$CFG.@5gmodem[0].active_modem" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_sp" ] && echo "$SEEN_DIR/sms_seen.$_sp" || echo "$SEEN_DIR/sms_seen"
}

case "$1" in
	seen)
		_sf=$(_seen_file)
		# ПЕРВЫЙ ЗАПУСК ОТДАЁМ ОТДЕЛЬНЫМ ПРИЗНАКОМ. Файла нет - значит мы про
		# эту карту ещё ничего не знаем, и подсветить ВСЁ разом было бы враньём:
		# сообщения могли прийти год назад. Страница в этом случае просто
		# запоминает текущие как виденные и метки не рисует.
		if [ ! -f "$_sf" ]; then
			echo '{"first":1,"keys":[]}'
			exit 0
		fi
		printf '{"first":0,"keys":['
		_n=0
		while IFS= read -r _k; do
			[ -n "$_k" ] || continue
			[ "$_n" = 0 ] || printf ','
			printf '"%s"' "$_k"
			_n=$((_n+1))
		done < "$_sf"
		printf ']}\n'
		exit 0 ;;
	seen-add)
		shift
		[ -n "$1" ] || { echo '{"success":true}'; exit 0; }
		mkdir -p "$SEEN_DIR" 2>/dev/null
		_sf=$(_seen_file)
		for _k in "$@"; do
			[ -n "$_k" ] || continue
			grep -qxF "$_k" "$_sf" 2>/dev/null || echo "$_k" >> "$_sf"
		done
		# ХВОСТ ОБРЕЗАЕМ. Файл лежит во флеш-памяти и растёт с каждым новым
		# сообщением; помнить нужно ровно столько, сколько модем способен
		# хранить, дальше отметка бесполезна.
		if [ "$(wc -l < "$_sf" 2>/dev/null || echo 0)" -gt "$SEEN_MAX" ]; then
			tail -n "$SEEN_MAX" "$_sf" > "$_sf.tmp" 2>/dev/null && mv "$_sf.tmp" "$_sf"
		fi
		echo '{"success":true}'
		exit 0 ;;
	seen-reset)
		rm -f "$(_seen_file)" 2>/dev/null
		echo '{"success":true}'
		exit 0 ;;
esac

BOX="${1:-recv}"
case "$BOX" in
	delete) DEL="$2"; STORE="$3"; PORT="$4" ;;
	send)   SND_TO="$2"; SND_TXT="$3"; PORT="$4" ;;
	*)      STORE="$2"; PORT="$3" ;;
esac

# Есть AT-порт (режим debug) - обычный путь: sms_tool умеет больше, чем API.
_sb_p=$(uci -q get "5gmodem.@5gmodem[0].at_port")
if [ "$(_active_kind)" = "hilink" ] && ! { [ -n "$_sb_p" ] && [ -c "$_sb_p" ]; }; then
	case "$BOX" in
		sent) "$RES/hilink.sh" smsread out ;;
		status)
			# Страница разбирает СТРОКУ формата sms_tool: "Storage type: ME,
			# used: N, total: M" - позиции подстрок в ней зашиты в разборе.
			# Поэтому отдаём ровно её, а не JSON.
			_c=$("$RES/hilink.sh" smscount 2>/dev/null | tr -d '\r')
			_u=$(printf '%s' "$_c" | sed -n 's|.*<LocalInbox>\(.*\)</LocalInbox>.*|\1|p')
			_m=$(printf '%s' "$_c" | sed -n 's|.*<LocalMaxInbox>\(.*\)</LocalMaxInbox>.*|\1|p')
			[ -n "$_u" ] || _u=0
			[ -n "$_m" ] || _m=100
			echo "Storage type: ME, used: $_u, total: $_m"
			;;
		delete)
			# У API свистка нет «удалить всё» - только по одному индексу.
			# Для all перебираем то, что реально лежит во входящих.
			if [ "$DEL" = all ]; then
				"$RES/hilink.sh" smsread in 2>/dev/null \
					| jsonfilter -e '@.msg[*].index' 2>/dev/null \
					| while read -r _i; do
						[ -n "$_i" ] && "$RES/hilink.sh" smsdel "$_i" >/dev/null 2>&1
					done
				echo '{"success":true}'
			else
				"$RES/hilink.sh" smsdel "$DEL"
			fi ;;
		send)   "$RES/hilink.sh" smssend "$SND_TO" "$SND_TXT" ;;
		*)    "$RES/hilink.sh" smsread in ;;
	esac
	exit 0
fi

# Обычный модем - прежний путь. Порт берём из аргумента, иначе из настроек.
[ -n "$PORT" ] || PORT=$(uci -q get 5gmodem.sms.readport)
[ -n "$PORT" ] || PORT=$("$RES/detect.sh" 2>/dev/null)
# Порта нет вовсе - отдаём пустой список, а не ошибку: страница покажет
# «сообщений нет», и это честнее, чем красный текст про несуществующий /dev.
[ -n "$PORT" ] || { echo "[]"; exit 0; }

# Ждём своей очереди к порту: чтение SMS идёт параллельно опросу метрик, и без
# этого списки приходили обрезанными, а в текст сообщения попадали чужие ответы.
# Блокировку снимет ядро при выходе. Не дождались - идём как раньше: потерять
# сообщения хуже, чем рискнуть смешением.
. "$RES/atlock.sh"
at_lock "$PORT" 15

# ОГРАНИЧИТЕЛЬ ВРЕМЕНИ: sms_tool своего таймаута не имеет, и модем, не
# ответивший на команду, оставлял процесс держать порт НАВСЕГДА (живой случай
# 31.07.2026: L850/XMM молча виснет на «delete all») - все последующие
# SMS-операции вставали за ним в очередь навечно, страница крутила
# «Загрузка сообщений» без конца. Паттерн киллера тот же, что в at_query:
# фон + сторож, дескрипторы порта у сторожа закрыты.
_sms_run() {   # $1 - таймаут (с), дальше - команда
	_sr_t="$1"; shift
	"$@" 2>/dev/null &
	_sr_p=$!
	( exec >/dev/null 2>&1 8>&- 9>&-; sleep "$_sr_t"; kill "$_sr_p" 2>/dev/null ) </dev/null & _sr_w=$!
	wait "$_sr_p"; _sr_rc=$?
	kill "$_sr_w" 2>/dev/null; wait "$_sr_w" 2>/dev/null
	return $_sr_rc
}

set -- -d "$PORT" -f '%Y-%m-%d %H:%M' -j
[ -n "$STORE" ] && set -- -s "$STORE" "$@"
case "$BOX" in
	status) _sms_run 20 $(_smstool) -d "$PORT" ${STORE:+-s "$STORE"} status; exit $? ;;
	sent)   _sms_run 45 $(_smstool) "$@" recv SR; exit $? ;;
	# delete <index|all> - индекс проверяем здесь: наружу уходит уже
	# безопасное значение, а страница не решает, что можно слать в модем.
	delete)
		case "$DEL" in
			all)
				# У части модемов «delete all» виснет (L850/XMM) - тогда
				# добиваем ПОШТУЧНО по индексам из списка, каждый шаг с
				# собственным потолком.
				if ! _sms_run 40 $(_smstool) -d "$PORT" delete all; then
					for _dl_i in $(_sms_run 45 $(_smstool) "$@" recv \
							| jsonfilter -e '@.msg[*].index' 2>/dev/null); do
						case "$_dl_i" in ''|*[!0-9]*) continue ;; esac
						_sms_run 12 $(_smstool) -d "$PORT" delete "$_dl_i"
					done
				fi
				exit 0 ;;
			''|*[!0-9]*) echo "bad index" >&2; exit 2 ;;
			*)   _sms_run 15 $(_smstool) -d "$PORT" delete "$DEL"; exit $? ;;
		esac ;;
	send)
		[ -n "$SND_TO" ] || { echo "no number" >&2; exit 2; }
		# КОДИРОВКА - ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ sms_tool. Модем в PDU-режиме
		# (AT+CMGF=0), кодировку выбирает сам sms_tool и на кириллице ставит
		# GSM-7, где её нет - до адресата доходят «?????». Проверено: баг
		# воспроизводится и прямым вызовом из консоли, БЕЗ нашего приложения,
		# и флаг «-c 2» его не лечит (для send он не действует).
		# Лечится только своим PDU-кодером (UCS2 + AT+CMGS) - см. роадмап.
		_sms_run 45 $(_smstool) -d "$PORT" send "$SND_TO" "$SND_TXT"; exit $? ;;
	# ТЕКСТОМ, а не JSON. Нужно кнопке «сохранить сообщения в файл»: она пишет
	# человекочитаемый .txt, и JSON там не к месту. Раньше страница ради этого
	# исполняла БИНАРЬ sms_tool напрямую (в ACL был разрешён exec на него), то есть
	# из браузера уходили любые аргументы. Теперь формат выбирается здесь.
	dump)   _sms_run 45 $(_smstool) -d "$PORT" -f '%Y-%m-%d %H:%M' ${STORE:+-s "$STORE"} recv; exit $? ;;
	*)      _sms_run 45 $(_smstool) "$@" recv; exit $? ;;
esac
