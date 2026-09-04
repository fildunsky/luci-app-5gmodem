#!/bin/sh
#
# КОМАНДЫ ПО SMS: «прислал сообщение - роутер выполнил».
#
# ЗАЧЕМ. Роутер с модемом часто стоит там, куда по сети не достучаться: канал
# лёг, оператор сменил адрес, туннель не поднялся. SMS доходит и тогда - это
# последний работающий канал управления, и через него нужно уметь хотя бы
# перезагрузиться и спросить, что происходит.
#
# ЧЕМ ЭТО ОПАСНО И ЧТО С ЭТИМ СДЕЛАНО. Команда приходит СНАРУЖИ, от кого угодно,
# кто знает номер симки. Поэтому:
#   - выключено по умолчанию (cmd_enabled);
#   - белый список номеров, тоже по умолчанию включённый: пустой список при
#     включённом белом списке = не выполнять НИЧЕГО. Открыть всем можно, но
#     только сняв галочку руками;
#   - сравнение номеров по последним десяти цифрам: +7XXX, 8XXX и 7XXX - один и
#     тот же человек, а вот буквенный отправитель («t2.ru») не совпадёт никогда;
#   - текст сообщения НЕ ПОПАДАЕТ В КОМАНДНУЮ СТРОКУ. Хвост после ключевого
#     слова уходит в переменную окружения SMS_ARGS - иначе «reboot; rm -rf /»
#     от постороннего было бы вопросом одной SMS.
#
# ВЫПОЛНЯЕМ РОВНО ОДИН РАЗ. Список выполненного лежит на флеше (см.
# sms_cmd_done_file в lib.sh) - перезагрузка роутера не должна выполнить те же
# команды заново. Первая встреча с модемом НИЧЕГО не выполняет: в памяти могли
# лежать сообщения годичной давности, и выполнить их скопом - худшее, что можно
# придумать. Их молча записываем выполненными и следим с этого момента.
#
#   smscmd.sh run    - круг обработки (зовётся из sessionwatch)
#   smscmd.sh test <ключевое слово> - выполнить команду вручную, как будто пришла

RES=/usr/share/5gmodem
CFG=5gmodem

. "$RES/lib.sh" 2>/dev/null

_cfg() { uci -q get "$CFG.sms.$1" 2>/dev/null; }
_log() { logger -t 5gmodem "sms-команды: $*"; }

CMD_EN=$(_cfg cmd_enabled)
CMD_WL=$(_cfg cmd_whitelist_only); [ -n "$CMD_WL" ] || CMD_WL=1
CMD_SECRET=$(_cfg cmd_secret)
# СРОК ГОДНОСТИ КОМАНДЫ (часы; 0 - без ограничения).
#
# «Выполняем ровно один раз» держится на списке выполненного, привязанном к
# МОДЕМУ. Пачка ранее не виденных сообщений появляется и на знакомом модеме -
# достаточно сменить SIM: в памяти карты лежит её собственная переписка за
# месяцы, и команда из неё выполнилась бы как свежая (живой случай 02.09.2026:
# после перестановки eSIM -> физическая SIM модем отдал 50 сообщений, самые
# старые - январские). Команда «перезагрузись», пришедшая полгода назад, к
# исполнению не относится: её отправитель давно забыл о ней.
CMD_MAXAGE=$(_cfg cmd_max_age); case "$CMD_MAXAGE" in ''|*[!0-9]*) CMD_MAXAGE=24 ;; esac

# КУЛДАУН НА ПОВТОР ОДНОЙ КОМАНДЫ (секунды; 0 - выключен).
#
# Оператор доставляет дубли, человек шлёт «reboot» трижды, не дождавшись
# ответа, - и каждая копия с ОТДЕЛЬНОЙ меткой времени является для нас
# самостоятельным сообщением со своим ключом. Разобрано по шагам: первая копия
# помечается и уводит роутер в перезагрузку, остальные пометиться не успевают,
# после загрузки круг находит их снова - и так по копии на перезагрузку.
# Кулдаун разрывает это независимо от того, сколько сообщений просят одного
# и того же.
#
# ЛЕЖИТ НА ФЛЕШЕ, а не в /tmp: перезагрузка - самая частая команда, и кулдаун,
# исчезающий вместе с /tmp, не защитил бы ровно от неё.
CMD_COOLDOWN=$(_cfg cmd_cooldown); case "$CMD_COOLDOWN" in ''|*[!0-9]*) CMD_COOLDOWN=300 ;; esac

# Ключ слова - хешем: в поле может оказаться что угодно, включая пробелы, а
# строки файла разбираются по пробелу.
_cool_key() { printf '%s' "$1" | md5sum | cut -c1-12; }

# 0 - выполнять можно
_cool_ok() {   # $1 - ключевое слово
	[ "$CMD_COOLDOWN" = 0 ] && return 0
	_ck_now=$(date +%s 2>/dev/null); case "$_ck_now" in ''|*[!0-9]*) return 0 ;; esac
	_ck_k=$(_cool_key "$1")
	_ck_f=$(sms_cmd_cool_file "$MPATH")
	[ -f "$_ck_f" ] || return 0
	while read -r _ck_w _ck_t; do
		[ "$_ck_w" = "$_ck_k" ] || continue
		case "$_ck_t" in ''|*[!0-9]*) return 0 ;; esac
		# Часы могли прыгнуть назад (роутер без RTC поймал время по NTP позже) -
		# отметка «из будущего» не должна запирать команду навсегда.
		[ "$_ck_now" -lt "$_ck_t" ] && return 0
		[ $((_ck_now - _ck_t)) -lt "$CMD_COOLDOWN" ] && return 1
		return 0
	done < "$_ck_f"
	return 0
}

_cool_mark() {   # $1 - ключевое слово
	[ "$CMD_COOLDOWN" = 0 ] && return 0
	_cm_now=$(date +%s 2>/dev/null); case "$_cm_now" in ''|*[!0-9]*) return 0 ;; esac
	_cm_k=$(_cool_key "$1")
	_cm_f=$(sms_cmd_cool_file "$MPATH")
	mkdir -p "$(dirname "$_cm_f")" 2>/dev/null
	{
		if [ -f "$_cm_f" ]; then
			while read -r _cm_w _cm_t; do
				[ "$_cm_w" = "$_cm_k" ] && continue
				[ -n "$_cm_w" ] && printf '%s %s\n' "$_cm_w" "$_cm_t"
			done < "$_cm_f"
		fi
		printf '%s %s\n' "$_cm_k" "$_cm_now"
	} > "$_cm_f.tmp" 2>/dev/null && mv "$_cm_f.tmp" "$_cm_f" 2>/dev/null
	sync 2>/dev/null
}

# 0 - команда достаточно свежая. Метку времени sms_tool печатает в UTC и
# игнорирует $TZ, поэтому сравниваем в UTC. Не разобрали метку - считаем
# СТАРЫМ: неизвестного возраста команда исполнению не подлежит.
_fresh_cmd() {   # $1 - метка времени сообщения
	[ "$CMD_MAXAGE" = 0 ] && return 0
	_fc_e=$(date -u -D '%Y-%m-%d %H:%M' -d "$1" +%s 2>/dev/null)
	case "$_fc_e" in ''|*[!0-9]*) return 1 ;; esac
	[ $(( $(date -u +%s) - _fc_e )) -lt $((CMD_MAXAGE * 3600)) ]
}
STORE=$(_cfg storage); [ -n "$STORE" ] || STORE=SM

DONE_MAX=300
# Потолок ответа: SMS длинная не бесплатна, а вывод команды бывает километровым.
ANS_MAX=600

# Последние 10 цифр номера - устойчивая форма для сравнения (+7/8/7 - одно и то
# же). У буквенного отправителя цифр нет, и он не совпадёт ни с чем.
_num10() {
	_n=$(printf '%s' "$1" | tr -cd '0-9')
	_l=${#_n}
	[ "$_l" -gt 10 ] && _n=$(printf '%s' "$_n" | cut -c$((_l - 9))-)
	printf '%s' "$_n"
}

_allowed() {   # $1 - отправитель
	[ "$CMD_WL" = "1" ] || return 0
	_a=$(_num10 "$1")
	[ -n "$_a" ] || return 1
	for _w in $(uci -q get "$CFG.sms.cmd_phone" 2>/dev/null); do
		[ "$(_num10 "$_w")" = "$_a" ] && return 0
	done
	return 1
}

# Секция команды по ключевому слову. Сравнение без учёта регистра: человек
# набирает с телефона, и «Reboot» должно работать так же, как «reboot».
_find_cmd() {   # $1 - первое слово сообщения; печатает имя секции
	_fk=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	[ -n "$_fk" ] || return 1
	for _sec in $(uci -q show "$CFG" 2>/dev/null \
			| sed -n "s/^\($CFG\.[^.]*\)=smscmd\$/\1/p"); do
		_kw=$(uci -q get "$_sec.keyword" | tr 'A-Z' 'a-z')
		[ -n "$_kw" ] && [ "$_kw" = "$_fk" ] && { printf '%s' "$_sec"; return 0; }
	done
	return 1
}

# Выполнение одной команды. Ответ и задержка разведены СОЗНАТЕЛЬНО: команда
# вроде reboot убивает нас раньше, чем ответ успеет уйти, поэтому при заданной
# задержке ответ отправляется ДО выполнения, а сама команда уходит в фон и ждёт.
_run_cmd() {   # $1 - секция, $2 - отправитель, $3 - хвост после ключевого слова, $4 - весь текст
	_rc_ex=$(uci -q get "$1.exec")
	[ -n "$_rc_ex" ] || return 1
	_rc_ans=$(uci -q get "$1.answer")
	_rc_txt=$(uci -q get "$1.answer_text")
	_rc_dly=$(uci -q get "$1.delay")
	case "$_rc_dly" in ''|*[!0-9]*) _rc_dly=0 ;; esac
	[ "$_rc_dly" -gt 300 ] 2>/dev/null && _rc_dly=300

	_log "от $2: $(uci -q get "$1.keyword") -> $_rc_ex"

	if [ "$_rc_dly" -gt 0 ]; then
		# Ответ вперёд, команда следом и в фоне: иначе на reboot человек не
		# получает ничего и не знает, дошло ли вообще.
		[ "$_rc_ans" = "1" ] && _answer "$2" "${_rc_txt:-OK}"
		(
			exec >/dev/null 2>&1 </dev/null
			sleep "$_rc_dly"
			SMS_FROM="$2" SMS_ARGS="$3" SMS_TEXT="$4" sh -c "$_rc_ex"
		) &
		return 0
	fi

	_rc_out=$(SMS_FROM="$2" SMS_ARGS="$3" SMS_TEXT="$4" sh -c "$_rc_ex" 2>&1)
	if [ "$_rc_ans" = "1" ]; then
		_rc_body="$_rc_txt"
		[ -n "$_rc_out" ] && _rc_body="${_rc_body:+$_rc_body
}$(printf '%s' "$_rc_out" | head -c "$ANS_MAX")"
		_answer "$2" "${_rc_body:-OK}"
	fi
	return 0
}

# Ответ отправителю. Через общий мост - он сам решает, чем слать (свой PDU для
# кириллицы, sms_tool для латиницы, MM для модема под ModemManager) и сам
# положит в очередь, если порт сейчас занят.
_answer() {   # $1 - номер, $2 - текст
	[ -n "$1" ] || return 0
	case "$(_num10 "$1")" in '') return 0 ;; esac   # буквенному отправителю не ответить
	SMS_MODEM="$MPATH" "$RES/smsbridge.sh" send "$1" "$2" "$MPORT" >/dev/null 2>&1
}

# --- круг по одному модему ---------------------------------------------------
_one() {   # $1 - usb-путь
	MPATH="$1"
	_o_sec="m_$(printf '%s' "$MPATH" | sed 's/[^A-Za-z0-9]/_/g')"
	_o_act=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	if [ "$MPATH" = "$_o_act" ]; then
		MPORT=$(_cfg readport)
	else
		MPORT=$(uci -q get "$CFG.$_o_sec.at_port")
	fi

	_o_msgs=$(SMS_MODEM="$MPATH" "$RES/smsbridge.sh" recv "$STORE" "$MPORT" 2>/dev/null)
	[ -n "$_o_msgs" ] || return 0
	_o_idx=$(printf '%s' "$_o_msgs" | jsonfilter -e '@.msg[*].index' 2>/dev/null)
	[ -n "$_o_idx" ] || return 0

	_o_df=$(sms_cmd_done_file "$MPATH")
	_o_first=0
	[ -f "$_o_df" ] || _o_first=1
	mkdir -p "$(dirname "$_o_df")" 2>/dev/null

	# Части длинной SMS собираем в одно сообщение (ключ «отправитель|время»),
	# иначе команда, не поместившаяся в одну часть, не совпала бы ни с чем, а
	# части остались бы навсегда необработанными - и слив в память роутера из-за
	# них никогда не удалил бы их из модема.
	_o_seen_keys=""
	for _o_i in $_o_idx; do
		_o_s=$(printf '%s' "$_o_msgs" | jsonfilter -e "@.msg[@.index=$_o_i].sender" 2>/dev/null)
		_o_t=$(printf '%s' "$_o_msgs" | jsonfilter -e "@.msg[@.index=$_o_i].timestamp" 2>/dev/null)
		_o_grp="$_o_s|$_o_t"
		case "
$_o_seen_keys
" in *"
$_o_grp
"*) continue ;; esac
		_o_seen_keys="$_o_seen_keys
$_o_grp"

		# Текст группы целиком + ключи всех её частей (их и помечаем).
		_o_text=""; _o_keys=""
		for _o_j in $_o_idx; do
			[ "$(printf '%s' "$_o_msgs" | jsonfilter -e "@.msg[@.index=$_o_j].sender" 2>/dev/null)" = "$_o_s" ] || continue
			[ "$(printf '%s' "$_o_msgs" | jsonfilter -e "@.msg[@.index=$_o_j].timestamp" 2>/dev/null)" = "$_o_t" ] || continue
			_o_c=$(printf '%s' "$_o_msgs" | jsonfilter -e "@.msg[@.index=$_o_j].content" 2>/dev/null)
			_o_text="$_o_text$_o_c"
			_o_keys="$_o_keys $(sms_cmd_key "$_o_s" "$_o_t" "$_o_c")"
		done

		# Уже обработано? Признак - ключ ПЕРВОЙ части: он записывается последним
		# (см. ниже), поэтому его наличие означает, что группа дошла до конца.
		_o_k1=${_o_keys# }; _o_k1=${_o_k1%% *}
		[ -n "$_o_k1" ] && grep -qxF "$_o_k1" "$_o_df" 2>/dev/null && continue

		# ПОМЕЧАЕМ ДО ВЫПОЛНЕНИЯ, А НЕ ПОСЛЕ.
		#
		# Раньше отметка стояла после _run_cmd - и команда `reboot` без задержки
		# уносила роутер в перезагрузку РАНЬШЕ, чем ключ ложился на флеш. После
		# загрузки сообщение всё ещё лежало в модеме необработанным, круг снова
		# находил его и снова перезагружал: роутер уходил в петлю, а со стороны
		# это выглядело как «команда reboot по SMS не работает». Цена обратного
		# порядка - невыполненная команда, если процесс умрёт между отметкой и
		# запуском; цена прежнего - бесконечная перезагрузка. Выбор очевиден.
		#
		# Помечаем ВСЕГДА, даже если команда не нашлась: иначе каждый круг мы
		# заново разбирали бы всю память модема, а слив никогда не смог бы
		# удалить обычное сообщение (условие «команды отработали» не выполнено).
		# Ключ первой части пишем ПОСЛЕДНИМ - он и служит признаком «готово».
		for _o_k in $_o_keys; do
			[ -n "$_o_k" ] || continue
			[ "$_o_k" = "$_o_k1" ] && continue
			grep -qxF "$_o_k" "$_o_df" 2>/dev/null || echo "$_o_k" >> "$_o_df"
		done
		if [ -n "$_o_k1" ]; then
			grep -qxF "$_o_k1" "$_o_df" 2>/dev/null || echo "$_o_k1" >> "$_o_df"
		fi
		# НА ФЛЕШ ПРЯМО СЕЙЧАС. Порядок «пометить, потом выполнить» спасает от
		# петли только если отметка действительно записана: при выключении
		# питания в момент перезагрузки роутера несинхронизированная запись
		# пропадает вместе с кешем, и после подъёма та же команда выполняется
		# заново. sync стоит миллисекунды и ставится один раз на сообщение.
		sync 2>/dev/null

		if [ "$_o_first" = 0 ] && ! _fresh_cmd "$_o_t"; then
			_log "пропущено: сообщению от $_o_s больше ${CMD_MAXAGE} ч (${_o_t}) - команды из старой переписки не выполняем"
		elif [ "$_o_first" = 0 ]; then
			# ЗАЩИТНЫЙ КОД, если задан: первое слово сообщения. Номер отправителя
			# подделывается (SMS-спуфинг - услуга, а не фантастика), поэтому
			# белого списка мало тому, кто рулит роутером по SMS всерьёз. Код
			# знает только хозяин; без него сообщение не команда, а текст.
			_o_body="$_o_text"
			if [ -n "$CMD_SECRET" ]; then
				_o_w1=$(printf '%s' "$_o_body" | awk '{print $1; exit}')
				if [ "$(printf '%s' "$_o_w1" | tr 'A-Z' 'a-z')" \
				   = "$(printf '%s' "$CMD_SECRET" | tr 'A-Z' 'a-z')" ]; then
					_o_body=$(printf '%s' "$_o_body" | awk '{ $1=""; sub(/^[ \t]+/,""); print; exit }')
				else
					_o_body=""
				fi
			fi
			_o_word=$(printf '%s' "$_o_body" | awk '{print $1; exit}')
			_o_rest=$(printf '%s' "$_o_body" | awk '{ $1=""; sub(/^[ \t]+/,""); print; exit }')
			if _o_cs=$(_find_cmd "$_o_word"); then
				if ! _allowed "$_o_s"; then
					_log "отклонено: номер $_o_s не в белом списке"
				elif ! _cool_ok "$_o_word"; then
					_log "пропущено: «$_o_word» уже выполнялась меньше ${CMD_COOLDOWN} c назад (дубль сообщения)"
				else
					_cool_mark "$_o_word"
					_run_cmd "$_o_cs" "$_o_s" "$_o_rest" "$_o_text"
				fi
			fi
		fi
	done

	# Хвост обрезаем: файл на флеше и растёт с каждым сообщением.
	if [ "$(wc -l 2>/dev/null < "$_o_df" || echo 0)" -gt "$DONE_MAX" ]; then
		tail -n "$DONE_MAX" "$_o_df" > "$_o_df.tmp" 2>/dev/null && mv "$_o_df.tmp" "$_o_df"
	fi
	# «Первая встреча» теперь про КАРТУ: список выполненного привязан к ICCID
	# (см. sms_cmd_done_file), и незнакомой считается новая SIM, а не модем.
	[ "$_o_first" = 1 ] && _log "первая встреча с этой SIM (модем $MPATH): её сообщения помечены обработанными, команды не выполнялись"
	return 0
}

# Есть ли у устройства канал SMS вообще (тот же гард, что у бота): у
# телефона-тетеринга порта нет, и recv свалился бы на АКТИВНЫЙ модем - команды
# выполнялись бы дважды.
_has_sms() {   # $1 - usb-путь
	[ "$(uci -q get "$CFG.m_$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g').kind")" = "hilink" ] && return 0
	"$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$1\"].tty[0]" -e "@[@.path=\"$1\"].wdm[0]" 2>/dev/null \
		| grep -q .
}

case "$1" in
run)
	[ "$CMD_EN" = "1" ] || exit 0
	_paths=$("$RES/registry.sh" paths 2>/dev/null)
	[ -n "$_paths" ] || _paths=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	for _p in $_paths; do
		_has_sms "$_p" || continue
		_one "$_p"
	done
	;;
test)
	# Ручная проверка команды со страницы: то же выполнение, но без SMS.
	[ -n "$2" ] || { echo '{"error":"no keyword"}'; exit 2; }
	MPATH=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	MPORT=$(_cfg readport)
	if _cs=$(_find_cmd "$2"); then
		_out=$(SMS_FROM="test" SMS_ARGS="$3" SMS_TEXT="$2 $3" \
			sh -c "$(uci -q get "$_cs.exec")" 2>&1 | head -c "$ANS_MAX")
		printf '{"result":"ok","output":"%s"}\n' \
			"$(printf '%s' "$_out" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')"
	else
		echo '{"error":"no such command"}'
		exit 1
	fi
	;;
*)
	echo "usage: $0 run | test <keyword> [args]" >&2
	exit 2 ;;
esac
exit 0
