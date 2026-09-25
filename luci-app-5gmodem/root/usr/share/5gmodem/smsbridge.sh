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
#        smsbridge.sh archive-run [store] [port] - перенести входящие в память
#                                                роутера и освободить модем

RES=/usr/share/5gmodem
CFG=5gmodem

# utf8_fix: чиним latin1-байты sms_tool ОДИН раз, на выходе моста - см. ниже.
. "$RES/lib.sh" 2>/dev/null

# ЧАСОВОЙ ПОЯС НЕ ЧИНИМ ЗДЕСЬ. sms_tool печатает время SMS в UTC и ИГНОРИРУЕТ
# $TZ (проверено на живом порту: и TZ=MSK-3, и TZ=UTC0 дают одинаковый +0000).
# Перевод в местное время делает фронтенд (readsms.js sms_localtime): у него
# есть пояс пользователя, а он может быть даже точнее пояса роутера.

# КАКОЙ МОДЕМ ОБСЛУЖИВАЕМ. По умолчанию активный - как было. Но бот в Telegram
# обходит ВСЕ модемы (иначе входящие видны только у того, чья вкладка открыта:
# у человека с Compal и Telit сообщения Telit не приходили вовсе), поэтому цель
# можно задать снаружи: SMS_MODEM=<usb-путь>. Отсюда же берётся и файл
# «виденного» - он и раньше был отдельным на каждый модем.
_TGT_PATH="${SMS_MODEM:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}"
_TGT_SEC="m_$(echo "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')"

_active_kind() {
	[ -n "$_TGT_PATH" ] || return 1
	uci -q get "$CFG.$_TGT_SEC.kind"
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
	_amp="$_TGT_PATH"
	[ -n "$_amp" ] || return 1
	_ams="$_TGT_SEC"
	_amif=$(uci -q get "$CFG.$_ams.network")
	[ -n "$_amif" ] || _amif=$(uci -q get "$CFG.@5gmodem[0].network")
	_ampr=$(uci -q get "network.$_amif.proto")
	[ "$_ampr" = "modemmanager" ] && return 0
	proto_in proxy "$_ampr" && _mm_ready "$_amp"
}

_mm_ready() {
	[ -n "$1" ] || return 1
	_mr_f="/tmp/5gmodem_smsmm_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"
	_mr_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$_mr_now" in ''|*[!0-9]*) _mr_now=0 ;; esac
	_mr_old=""; _mr_t=0
	[ -f "$_mr_f" ] && read -r _mr_old _mr_t < "$_mr_f"
	case "$_mr_t" in ''|*[!0-9]*) _mr_t=0 ;; esac
	if [ -n "$_mr_old" ] && [ "$_mr_t" -le "$_mr_now" ] && [ $((_mr_now - _mr_t)) -lt 15 ]; then
		[ "$_mr_old" = 1 ]
		return
	fi
	_mr_v=0
	if command -v mmcli >/dev/null 2>&1 && mm_owns_path "$1"; then
		_mr_i=$("$RES/modemswitch.sh" mmindex "$1" 2>/dev/null)
		case "$_mr_i" in
			''|*[!0-9]*) ;;
			*)
				case "$(mmcli -m "$_mr_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -1)" in
					enabled|searching|registered|connecting|connected|disconnecting) _mr_v=1 ;;
				esac ;;
		esac
	fi
	printf '%s %s\n' "$_mr_v" "$_mr_now" > "$_mr_f" 2>/dev/null
	if [ "$_mr_v" != "$_mr_old" ]; then
		if [ "$_mr_v" = 1 ]; then
			logger -t 5gmodem "smsbridge: modem $1 is ready in ModemManager - SMS through ModemManager"
		else
			logger -t 5gmodem "smsbridge: modem $1 is not ready in ModemManager - SMS over the AT port"
		fi
	fi
	[ "$_mr_v" = 1 ]
}

_port_proxy_mm() {
	[ "$(uci -q get 5gmodem.sms.sms_via_mm)" = "1" ] || return 1
	_ppm_p=$(tty_usbpath "$1" 2>/dev/null)
	[ -n "$_ppm_p" ] || return 1
	_ppm_if=$(uci -q get "$CFG.$(secname "$_ppm_p").network")
	proto_in proxy "$(uci -q get "network.$_ppm_if.proto")" || return 1
	_mm_ready "$_ppm_p"
}

if [ -z "$MM_MODEM_PATH" ] && [ -n "$_TGT_PATH" ]; then
	_tp_if=$(uci -q get "$CFG.$_TGT_SEC.network")
	[ -n "$_tp_if" ] || _tp_if=$(uci -q get "$CFG.@5gmodem[0].network")
	proto_in mm "$(uci -q get "network.$_tp_if.proto")" && export MM_MODEM_PATH="$_TGT_PATH"
fi

# ТРАНСПОРТ ВЫБИРАЕТ ФЛАГ, И ЭТО ПРОВЕРЕНО ЖЕЛЕЗОМ.
#
# Была попытка решать «по протоколу активного модема» (раз им владеет MM - через
# MM). На стенде она провалилась: у Compal RXM-G1 отправка через ModemManager
# ломается в самой прошивке -
#   MobileEquipment.PhoneFailure: MBIM status error: Couldn't send SMS part
# - тогда как AT-порт того же модема на sms_tool отвечает нормально. То есть
# глобальный ноль в конфиге был не наследством от соседнего модема, а верным
# описанием этого железа. Флаг остаётся решающим.
_via_mm() {
	[ "$(uci -q get 5gmodem.sms.sms_via_mm)" = "1" ] \
		&& [ -x /usr/share/5gmodem/sms_tool_mm ] && _active_is_mm
}

_smstool() {
	if _via_mm; then
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
	_sp=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_sp" ] && echo "$SEEN_DIR/sms_seen.$_sp" || echo "$SEEN_DIR/sms_seen"
}

# Печатает JSON-строку (в кавычках) из $1 - для верба newdump. Экранируем ровно
# то, что бывает в SMS: обратный слэш, кавычку, перевод строки, таб; CR убираем.
#
# СЛЭШ И КАВЫЧКУ ЭКРАНИРУЕМ SED-ом, А НЕ gsub. В замене gsub обратный слэш сам
# служит экранирующим символом, и «\\\\» давало на выходе ОДИН слэш, а «\\"» -
# голую кавычку: функция не экранировала ровно то, ради чего написана (проверено
# на busybox awk). У sed правила замены однозначны. Перевод строки оставляем
# awk - он один знает, где кончилась строка (аудит 12.09.2026).
_nd_jesc() {
	printf '%s' "$1" | tr -d '\r' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '
		BEGIN { ORS=""; printf "\"" }
		{ if (NR>1) printf "\\n"; printf "%s", $0 }
		END { printf "\"" }'
}

TG_MIG="$SEEN_DIR/sms_tg_migrated"

_tg_file() {
	_tp=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_tp" ] && echo "$SEEN_DIR/sms_tg.$_tp" || echo "$SEEN_DIR/sms_tg"
}

_tg_migrate() {
	[ -f "$TG_MIG" ] && return 0
	mkdir -p "$SEEN_DIR" 2>/dev/null || return 0
	for _tm_f in "$SEEN_DIR"/sms_seen "$SEEN_DIR"/sms_seen.*; do
		[ -f "$_tm_f" ] || continue
		case "$_tm_f" in *.tmp) continue ;; esac
		_tm_t="$SEEN_DIR/sms_tg${_tm_f#"$SEEN_DIR/sms_seen"}"
		[ -f "$_tm_t" ] || cp "$_tm_f" "$_tm_t" 2>/dev/null
	done
	: > "$TG_MIG" 2>/dev/null
}

_list_add() {
	_la_f="$1"; shift
	mkdir -p "$SEEN_DIR" 2>/dev/null
	for _k in "$@"; do
		[ -n "$_k" ] || continue
		grep -qxF "$_k" "$_la_f" 2>/dev/null || echo "$_k" >> "$_la_f"
	done
	[ -f "$_la_f" ] || : > "$_la_f" 2>/dev/null
	_la_max=$(uci -q get "$CFG.sms.archive_limit")
	case "$_la_max" in ''|*[!0-9]*) _la_max=0 ;; esac
	[ "${#_la_max}" -le 4 ] && [ "$_la_max" -le 2000 ] || _la_max=2000
	_la_max=$((SEEN_MAX + _la_max))
	if [ "$(wc -l 2>/dev/null < "$_la_f" || echo 0)" -gt "$_la_max" ]; then
		tail -n "$_la_max" "$_la_f" > "$_la_f.tmp" 2>/dev/null && mv "$_la_f.tmp" "$_la_f"
	fi
}

_kb_n=0

_kb_norm() {
	_KB_S="$1"
	case "$_KB_S" in
		*[[:cntrl:]]*) _KB_S=$(printf '%s' "$_KB_S" | tr -d '\r' | tr '\000-\037' ' ') ;;
	esac
	while :; do
		case "$_KB_S" in *' ') _KB_S=${_KB_S% } ;; *) break ;; esac
	done
}

_kb_put() {
	_kb_n=$((_kb_n + 1))
	_kb_norm "$2"
	_kb_pc="$4"
	while :; do
		case "$_kb_pc" in
			*"
") _kb_pc=${_kb_pc%?} ;;
			*) break ;;
		esac
	done
	eval "_kb_x$_kb_n=\$1; _kb_f$_kb_n=\$2; _kb_s$_kb_n=\$_KB_S; _kb_t$_kb_n=\$3; _kb_c$_kb_n=\$_kb_pc; _kb_p$_kb_n=\$5; _kb_o$_kb_n=\$6; _kb_r$_kb_n=\$7; _kb_h$_kb_n=\$8; _kb_k$_kb_n=''; _kb_g$_kb_n=''; _kb_gm$_kb_n=''"
	case "$1" in ''|*[!0-9]*) ;; *) eval "_kb_ix$1=$_kb_n" ;; esac
}

_kb_feed_json() {
	_kf_n=$(printf '%s' "$1" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_kf_n" in ''|*[!0-9]*) return 0 ;; esac
	_kf_i=0
	while [ "$_kf_i" -lt "$_kf_n" ]; do
		_kf_x=""; _kf_s=""; _kf_t=""; _kf_c=""; _kf_p=""; _kf_o=""; _kf_r=""
		eval "$(printf '%s' "$1" | jsonfilter \
			-e "_kf_x=@.msg[$_kf_i].index" -e "_kf_s=@.msg[$_kf_i].sender" \
			-e "_kf_t=@.msg[$_kf_i].timestamp" -e "_kf_c=@.msg[$_kf_i].content" \
			-e "_kf_p=@.msg[$_kf_i].part" -e "_kf_o=@.msg[$_kf_i].total" \
			-e "_kf_r=@.msg[$_kf_i].reference" 2>/dev/null)"
		_kf_i=$((_kf_i + 1))
		[ -n "$_kf_s$_kf_c" ] || continue
		_kb_put "$_kf_x" "$_kf_s" "$_kf_t" "$_kf_c" "$_kf_p" "$_kf_o" "$_kf_r" ""
	done
}

_kb_feed_arch() {
	_ka_d=$(_arch_dir)
	for _ka_f in $(_arch_files "$_ka_d"); do
		[ -f "$_ka_d/$_ka_f" ] || continue
		_arch_read "$_ka_d/$_ka_f"
		_ka_h=""
		case "$_A_TOTAL" in ''|0|1|*[!0-9]*) _ka_h=${_ka_f#*.} ;; esac
		_kb_put "${_ka_f%%.*}" "$_A_FROM" "$_A_TS" "$_A_TEXT" "$_A_PART" "$_A_TOTAL" "$_A_REF" "$_ka_h"
	done
}

_kb_build() {
	_kb_i=1
	while [ "$_kb_i" -le "$_kb_n" ]; do
		eval "_kb_k=\$_kb_k$_kb_i; _kb_s=\$_kb_s$_kb_i; _kb_f=\$_kb_f$_kb_i; _kb_t=\$_kb_t$_kb_i; _kb_p=\$_kb_p$_kb_i; _kb_o=\$_kb_o$_kb_i; _kb_r=\$_kb_r$_kb_i; _kb_h=\$_kb_h$_kb_i"
		if [ -n "$_kb_k" ]; then _kb_i=$((_kb_i + 1)); continue; fi
		_kb_multi=1
		case "$_kb_o" in ''|0|1|*[!0-9]*) _kb_multi=0 ;; esac
		case "$_kb_p" in ''|*[!0-9]*) _kb_multi=0 ;; esac
		if [ "$_kb_multi" = 0 ]; then
			if [ -z "$_kb_h" ]; then
				eval "_kb_c=\$_kb_c$_kb_i"
				_kb_h=$(printf '%s|%s|%s' "$_kb_f" "$_kb_t" "$_kb_c" | md5sum)
				_kb_h=${_kb_h%% *}; _kb_h=${_kb_h%????????????????}
			fi
			eval "_kb_k$_kb_i=\"\$_kb_s|\$_kb_t|\$_kb_h\"; _kb_g$_kb_i=1"
			_kb_i=$((_kb_i + 1)); continue
		fi
		_kb_mem=""
		_kb_q=1
		while [ "$_kb_q" -le "$_kb_o" ]; do eval "_kb_b$_kb_q=''"; _kb_q=$((_kb_q + 1)); done
		_kb_j="$_kb_i"
		while [ "$_kb_j" -le "$_kb_n" ]; do
			eval "_kb_jk=\$_kb_k$_kb_j; _kb_jf=\$_kb_f$_kb_j; _kb_jo=\$_kb_o$_kb_j; _kb_jr=\$_kb_r$_kb_j; _kb_jp=\$_kb_p$_kb_j; _kb_jt=\$_kb_t$_kb_j"
			if [ -z "$_kb_jk" ] && [ "$_kb_jf" = "$_kb_f" ] && [ "$_kb_jo" = "$_kb_o" ] && [ "$_kb_jr" = "$_kb_r" ]; then
				case "$_kb_jp" in
					''|*[!0-9]*) ;;
					*)
						_kb_mem="$_kb_mem $_kb_j"
						if [ "$_kb_jp" -ge 1 ] && [ "$_kb_jp" -le "$_kb_o" ]; then
							eval "_kb_bq=\$_kb_b$_kb_jp"
							if [ -z "$_kb_bq" ]; then
								eval "_kb_b$_kb_jp=$_kb_j"
							else
								eval "_kb_bt=\$_kb_t$_kb_bq"
								[ "$_kb_jt" \< "$_kb_bt" ] || eval "_kb_b$_kb_jp=$_kb_j"
							fi
						fi ;;
				esac
			fi
			_kb_j=$((_kb_j + 1))
		done
		_kb_txt=""; _kb_have=0; _kb_tf=""
		_kb_q=1
		while [ "$_kb_q" -le "$_kb_o" ]; do
			eval "_kb_bq=\$_kb_b$_kb_q"
			if [ -n "$_kb_bq" ]; then
				eval "_kb_txt=\$_kb_txt\$_kb_c$_kb_bq"
				[ -n "$_kb_tf" ] || eval "_kb_tf=\$_kb_t$_kb_bq"
				_kb_have=$((_kb_have + 1))
			fi
			_kb_q=$((_kb_q + 1))
		done
		[ -n "$_kb_tf" ] || _kb_tf="$_kb_t"
		_kb_h=$(printf '%s|%s|%s' "$_kb_f" "$_kb_tf" "$_kb_txt" | md5sum)
		_kb_h=${_kb_h%% *}; _kb_h=${_kb_h%????????????????}
		_kb_lead=1
		for _kb_j in $_kb_mem; do
			eval "_kb_k$_kb_j=\"\$_kb_s|\$_kb_tf|\$_kb_h\"; _kb_g$_kb_j=''; _kb_gm$_kb_j=\$_kb_mem"
			if [ "$_kb_lead" = 1 ]; then
				eval "_kb_g$_kb_j=1; _kb_gt$_kb_j=\$_kb_txt; _kb_gh$_kb_j=$_kb_have; _kb_gf$_kb_j=\$_kb_tf"
				_kb_lead=0
			fi
		done
		_kb_i=$((_kb_i + 1))
	done
}

_kb_jq() {
	case "$1" in
		*[\\\"]*|*[[:cntrl:]]*) _nd_jesc "$1" ;;
		*) printf '"%s"' "$1" ;;
	esac
}

_kb_side() {
	_ks_i=1; _ks_any=0
	printf '"keys":['
	while [ "$_ks_i" -le "$_kb_n" ]; do
		eval "_ks_x=\$_kb_x$_ks_i; _ks_k=\$_kb_k$_ks_i; _ks_s=\$_kb_s$_ks_i; _ks_t=\$_kb_t$_ks_i"
		_ks_i=$((_ks_i + 1))
		[ -n "$_ks_k" ] || continue
		case "$_ks_x" in ''|*[!0-9]*) continue ;; esac
		[ "$_ks_any" = 0 ] || printf ','
		_ks_any=1
		printf '{"index":%s,"key":' "$_ks_x"
		_kb_jq "$_ks_k"
		printf ',"old":'
		_kb_jq "$_ks_s|$_ks_t"
		printf '}'
	done
	printf ']'
}

_kb_in_list() {
	case "
$_KB_LIST
" in
		*"
$1
"*) return 0 ;;
	esac
	return 1
}

_kb_list_load() {
	_KB_LIST=""
	[ -f "$1" ] && _KB_LIST=$(tr -d '\r' < "$1" 2>/dev/null)
}

_kb_known() {
	eval "_kk_k=\$_kb_k$1; _kk_g=\$_kb_gm$1"
	_kb_in_list "$_kk_k" && return 0
	[ -n "$_kk_g" ] || _kk_g="$1"
	for _kk_j in $_kk_g; do
		eval "_kk_o=\"\$_kb_s$_kk_j|\$_kb_t$_kk_j\""
		_kb_in_list "$_kk_o" || return 1
	done
	return 0
}

_kb_unseen() {
	_ku_first=0
	[ -f "$1" ] || _ku_first=1
	_kb_list_load "$1"
	printf '{"first":%s,"sms":[' "$_ku_first"
	_ku_i=1; _ku_any=0
	while [ "$_ku_i" -le "$_kb_n" ]; do
		eval "_ku_g=\$_kb_g$_ku_i"
		if [ -n "$_ku_g" ] && ! _kb_known "$_ku_i"; then
			eval "_ku_k=\$_kb_k$_ku_i; _ku_s=\$_kb_s$_ku_i; _ku_t=\$_kb_t$_ku_i; _ku_o=\$_kb_o$_ku_i; _ku_m=\$_kb_gm$_ku_i"
			if [ -n "$_ku_m" ]; then
				eval "_ku_c=\$_kb_gt$_ku_i; _ku_h=\$_kb_gh$_ku_i; _ku_t=\$_kb_gf$_ku_i"
			else
				eval "_ku_c=\$_kb_c$_ku_i"
				_ku_h=1; _ku_o=1
			fi
			_ku_c=$(printf '%s' "$_ku_c" | utf8_fix)
			[ "$_ku_any" = 0 ] || printf ','
			_ku_any=1
			printf '{"sender":%s,"time":%s,"text":%s,"key":%s,"have":%s,"total":%s}' \
				"$(_nd_jesc "$_ku_s")" "$(_nd_jesc "$_ku_t")" "$(_nd_jesc "$_ku_c")" \
				"$(_nd_jesc "$_ku_k")" "$_ku_h" "$_ku_o"
		fi
		_ku_i=$((_ku_i + 1))
	done
	printf ']}\n'
}

_kb_out() {
	if [ "$BOX" = unseen ]; then
		[ -n "$1" ] || return 0
		_kb_feed_json "$1"
		_kb_build
		if [ "$UL" = tg ]; then _tg_migrate; _kb_unseen "$(_tg_file)"; else _kb_unseen "$(_seen_file)"; fi
		return 0
	fi
	_ko_j="$1"
	while :; do
		case "$_ko_j" in *[[:space:]]) _ko_j=${_ko_j%?} ;; *) break ;; esac
	done
	case "$_ko_j" in
		*'}')
			_kb_feed_json "$1"
			_kb_build
			if [ "$_kb_n" -gt 0 ]; then
				printf '%s,' "${_ko_j%\}}"
				_kb_side
				printf '}\n'
				return 0
			fi ;;
	esac
	[ -n "$1" ] && printf '%s\n' "$1"
	return 0
}

case "$1" in
	newdump)
		# НЕПРОЧИТАННЫЕ ВХОДЯЩИЕ В JSON для внешних программ (файл-зеркало
		# /tmp/5gmodem_sms_new.json, пишет sessionwatch раз в круг). «Новое» =
		# сообщение из recv, чей ключ sender|timestamp ещё НЕ в seen - ровно то,
		# что подсвечивает страница «Входящие» и шлёт Telegram. Обходим ВСЕ модемы
		# (как tgnotify): у каждого свой seen (sms_seen.<путь>), в каждой записи -
		# поле modem. Порт и гард SMS-канала - как в tgnotify.
		_nd_active=$(uci -q get "$CFG.@5gmodem[0].active_modem")
		_nd_paths=$("$RES/registry.sh" paths 2>/dev/null)
		[ -n "$_nd_paths" ] || _nd_paths="$_nd_active"
		_nd_store=$(uci -q get "$CFG.sms.storage")
		_nd_now=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$_nd_now" in ''|*[!0-9]*) _nd_now=0 ;; esac
		_nd_out=""; _nd_cnt=0
		for _nd_p in $_nd_paths; do
			# Есть ли у устройства SMS-канал (tty/cdc-wdm/HiLink)? Иначе пропускаем:
			# у телефона-тетеринга порта нет, и recv свалился бы на АКТИВНЫЙ модем
			# (тогда его входящие задвоились бы под чужим именем).
			_nd_sec="m_$(printf '%s' "$_nd_p" | sed 's/[^A-Za-z0-9]/_/g')"
			if [ "$(uci -q get "$CFG.$_nd_sec.kind")" != "hilink" ]; then
				bg_at_off "$_nd_p" && continue
				"$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_nd_p\"].tty[0]" -e "@[@.path=\"$_nd_p\"].wdm[0]" 2>/dev/null | grep -q . || continue
			fi
			# Порт: у активного - настроенный readport (выбран не мешать метрикам),
			# у прочих - at_port их секции. Пусто - HiLink/MM, мост разберётся сам.
			if [ "$_nd_p" = "$_nd_active" ]; then
				_nd_port=$(uci -q get "$CFG.sms.readport")
			else
				_nd_port=$(uci -q get "$CFG.$_nd_sec.at_port")
			fi
			_nd_recv=$(SMS_MODEM="$_nd_p" "$RES/smsbridge.sh" unseen seen "$_nd_store" "$_nd_port" 2>/dev/null)
			[ -n "$_nd_recv" ] || continue
			_nd_gn=$(printf '%s' "$_nd_recv" | jsonfilter -e '@.sms[*].have' 2>/dev/null | wc -l)
			case "$_nd_gn" in ''|*[!0-9]*) continue ;; esac
			# ПЕРВАЯ ВСТРЕЧА С МОДЕМОМ (seen пуст - после перепрошивки / чистой
			# установки). Его сообщения могли прийти давно и быть прочитаны; отдавать
			# их как новые (конвертик/счётчик) - враньё. Молча помечаем ТЕКУЩИЕ
			# виденными и НЕ отдаём как новое; дальше новое = только пришедшее позже.
			# Пишем прямо в seen-файл: ключи содержат пробел в timestamp, через
			# аргументы seen-add они бы разъехались. tgnotify со своим окном
			# отрабатывает РАНЬШЕ newdump в цикле, поэтому при включённом боте недавние
			# он уже разослал и файл создал - сюда попадаем только когда бота нет.
			if [ "$(printf '%s' "$_nd_recv" | jsonfilter -e '@.first' 2>/dev/null)" = "1" ]; then
				mkdir -p "$SEEN_DIR" 2>/dev/null
				_nd_g=0
				while [ "$_nd_g" -lt "$_nd_gn" ]; do
					printf '%s\n' "$(printf '%s' "$_nd_recv" | jsonfilter -e "@.sms[$_nd_g].key" 2>/dev/null)"
					_nd_g=$((_nd_g + 1))
				done | sort -u > "$SEEN_DIR/sms_seen.$(printf '%s' "$_nd_p" | sed 's/[^A-Za-z0-9]/_/g')" 2>/dev/null
				continue
			fi
			_nd_g=0
			while [ "$_nd_g" -lt "$_nd_gn" ]; do
				_nd_s=""; _nd_t=""; _nd_c=""; _nd_key=""
				eval "$(printf '%s' "$_nd_recv" | jsonfilter -e "_nd_s=@.sms[$_nd_g].sender" \
					-e "_nd_t=@.sms[$_nd_g].time" -e "_nd_c=@.sms[$_nd_g].text" \
					-e "_nd_key=@.sms[$_nd_g].key" 2>/dev/null)"
				_nd_g=$((_nd_g + 1))
				[ -n "$_nd_key" ] || continue
				[ -n "$_nd_out" ] && _nd_out="$_nd_out,"
				_nd_out="$_nd_out{\"modem\":$(_nd_jesc "$_nd_p"),\"sender\":$(_nd_jesc "$_nd_s"),\"time\":$(_nd_jesc "$_nd_t"),\"text\":$(_nd_jesc "$_nd_c"),\"key\":$(_nd_jesc "$_nd_key")}"
				_nd_cnt=$((_nd_cnt + 1))
			done
		done
		printf '{"count":%s,"ts":%s,"sms":[%s]}\n' "$_nd_cnt" "$_nd_now" "$_nd_out"
		exit 0 ;;
	newcount)
		# СКОЛЬКО НЕПРОЧИТАННЫХ - одним числом, для конвертика на карточке и любых
		# внешних программ. Читаем ГОТОВОЕ зеркало newdump (пишет sessionwatch раз
		# в круг): дёшево и без похода в AT-порт, поэтому годится для частого опроса
		# страницей на каждом тике. Зеркало восстанавливается из ПОСТОЯННЫХ источников
		# (SIM у обычных модемов, архив у MM), так что переживает перезагрузку - после
		# бута первый круг sessionwatch наполнит его заново. for=<путь> - считать
		# только этот модем (его вкладка); без аргумента - по всем.
		_ncf="/tmp/5gmodem_sms_new.json"
		_nc_for=""
		for _nc_a in "$@"; do case "$_nc_a" in for=*) _nc_for="${_nc_a#for=}" ;; esac; done
		[ -f "$_ncf" ] || { echo 0; exit 0; }
		_nc_j=$(cat "$_ncf" 2>/dev/null)
		# ВЫЧИТАЕМ УЖЕ ПРОЧИТАННЫЕ. seen пишется МГНОВЕННО при отметке на «Входящих»,
		# а зеркало обновляется лишь раз в круг sessionwatch - без вычета конверт
		# висел бы до следующего круга (до минуты) после отметки прочитанным. Считаем
		# ПОМОДЕМНО: ключи зеркала этого модема минус его seen (путь как в _seen_file,
		# getline из отсутствующего файла - пусто). Это делаем И для суммы по всем
		# модемам, иначе без for= total был бы завышен на уже прочитанные.
		_nc_one() {   # $1 - usb-путь модема; печатает число непрочитанных
			_nco_sf="$SEEN_DIR/sms_seen.$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"
			printf '%s' "$_nc_j" | jsonfilter -e "@.sms[@.modem=\"$1\"].key" 2>/dev/null \
				| awk -v sf="$_nco_sf" '
					BEGIN { while ((getline l < sf) > 0) { sub(/\r$/, "", l); if (l != "") seen[l] = 1 } }
					$0 != "" && !($0 in seen) { k = $0; sub(/\|[^|]*$/, "", k); if (!(k in seen)) c++ }
					END { print c + 0 }'
		}
		if [ -n "$_nc_for" ]; then
			_nc_n=$(_nc_one "$_nc_for")
		else
			_nc_n=0
			for _nc_m in $(printf '%s' "$_nc_j" | jsonfilter -e '@.sms[*].modem' 2>/dev/null | sort -u); do
				_nc_n=$((_nc_n + $(_nc_one "$_nc_m")))
			done
		fi
		case "$_nc_n" in ''|*[!0-9]*) _nc_n=0 ;; esac
		echo "$_nc_n"
		exit 0 ;;
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
			# КЛЮЧ ЭКРАНИРУЕМ. В нём имя отправителя, а буквенное имя с кавычкой
			# или слэшем ломало ВЕСЬ JSON: страница и бот получали пустой список
			# виденного и слали всё заново каждым кругом (аудит 12.09.2026).
			_nd_jesc "$_k"
			_n=$((_n+1))
		done < "$_sf"
		printf ']}\n'
		exit 0 ;;
	seen-add)
		shift
		[ -n "$1" ] || { echo '{"success":true}'; exit 0; }
		_list_add "$(_seen_file)" "$@"
		# ХВОСТ ОБРЕЗАЕМ. Файл лежит во флеш-памяти и растёт с каждым новым
		# сообщением; помнить нужно ровно столько, сколько модем способен
		# хранить, дальше отметка бесполезна.
		echo '{"success":true}'
		exit 0 ;;
	tg-add)
		shift
		_tg_migrate
		_list_add "$(_tg_file)" "$@"
		echo '{"success":true}'
		exit 0 ;;
	seen-reset)
		rm -f "$(_seen_file)" 2>/dev/null
		echo '{"success":true}'
		exit 0 ;;
esac

# ЧЕЙ ЭТОТ ПОРТ - НАШ ИЛИ ModemManager. Ответ даёт реестр (он же отвечает на этот
# вопрос всем остальным), поэтому здесь только тонкая обёртка с памятью на вызов.
_PORT_OWNER=""
_port_is_mm() {   # $1 - порт
	[ -n "$1" ] || return 1
	[ -n "$_PORT_OWNER" ] || _PORT_OWNER=$(printf '%s' "$("$RES/registry.sh" port "$1" 2>/dev/null)" \
		| jsonfilter -e '@.owner' 2>/dev/null)
	[ "$_PORT_OWNER" = "mm" ] || return 1
	# ВЛАДЕЕТ ЛИ ОН ИМ ПРЯМО СЕЙЧАС. Реестр отвечает по конфигу (прото
	# интерфейса), а модем может быть у MM отобран - например, нашей же
	# инхибицией на время отправки. Тогда порт свободен, и правильный путь -
	# обычный AT. Признак простой: MM не видит ни одного модема.
	command -v mmcli >/dev/null 2>&1 || return 1
	mmcli -L 2>/dev/null | grep -q "/Modem/"
}

# ОТПРАВКА ОДНОГО СООБЩЕНИЯ - С ВЫБОРОМ ТРАНСПОРТА ПО ВЛАДЕЛЬЦУ ПОРТА.
#
# Правило выведено двумя живыми стендами, и оно НЕ про флаг sms_via_mm:
#   - порт под ModemManager: он держит его открытым и вычитывает ответы, поэтому
#     свой AT-обмен там ненадёжен - шлём через MM (он же сам кодирует UCS2);
#   - если MM отказал (прошивка Compal в MBIM однажды вернула PhoneFailure) -
#     пробуем AT: иногда он выигрывает гонку чтения, и сообщение уходит;
#   - порт наш: латиница - sms_tool, кириллица - свой PDU (см. smspdu.sh).
# Возвращает 0 - ушло, 1 - не ушло.
# БЮДЖЕТ ВРЕМЕНИ РАЗНЫЙ У СТРАНИЦЫ И У ОЧЕРЕДИ.
#
# Отправка через MM на Compal в MBIM ведёт себя непредсказуемо: то уходит за
# секунду, то висит до таймаута (замерено на стенде: одна и та же команда - 6 c
# и 88 c). Пользователю у экрана ждать полторы минуты нельзя: лучше быстро
# сказать «поставил в очередь» и дослать фоном, где ожидание никому не мешает.
_send_one() {   # $1 - порт, $2 - номер, $3 - текст, [$4 - fast|slow]
	_so_port="$1"; _so_to="$2"; _so_txt="$3"
	if [ "$4" = slow ]; then _so_tmm=60; _so_tat=45; else _so_tmm=20; _so_tat=15; fi
	_so_mm=""; _so_mmp=""
	if _port_is_mm "$_so_port"; then
		_so_mm=1
	elif _port_proxy_mm "$_so_port"; then
		_so_mm=1; _so_mmp="$_ppm_p"
	fi
	if [ -n "$_so_mm" ] && [ -x "$RES/sms_tool_mm" ]; then
		if [ -n "$_so_mmp" ]; then
			MM_MODEM_PATH="$_so_mmp" _sms_run "$_so_tmm" "$RES/sms_tool_mm" -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null && return 0
		elif _sms_run "$_so_tmm" "$RES/sms_tool_mm" -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null; then
			return 0
		fi
		logger -t 5gmodem "smsbridge: MM send failed within ${_so_tmm}s, trying the AT port"
		# Кириллице и на запасном пути нужен наш PDU: sms_tool закодирует её
		# GSM-7 и адресат получит «?????».
		if "$RES/smspdu.sh" needucs2 "$_so_txt"; then
			_send_pdu "$_so_port" "$_so_to" "$_so_txt" 2>/dev/null
			return $?
		fi
		_sms_run "$_so_tat" $(_smstool_at) -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null
		return $?
	fi
	# НЕ-MM ПОРТ: НАШ PDU-ПУТЬ ОСНОВНОЙ, sms_tool - ЗАПАСНОЙ.
	#
	# Раньше кириллица шла нашим PDU, а латиница - sms_tool. Но у sms_tool
	# отправка жёстко зашита: после AT+CMGS он НЕ ждёт приглашение «>», а спит
	# ровно 1 c и шлёт тело, потом ждёт «+CMGS:» всего 5 c (alarm). Модемы, у
	# которых «>» приходит позже секунды или «+CMGS:» позже пяти, отдают
	# «No response from modem» - у EP06-E отправка не работала вовсе (проверено
	# на стенде: тот же порт, наш PDU-диалог с паузой 2 c и чтением до 25 c,
	# отдаёт «> / +CMGS: 71» и сообщение уходит). Наш _send_pdu мягче и уже
	# годами носит кириллицу, поэтому пускаем через него ВСЁ; латиница в UCS2
	# кодируется корректно (чуть короче лимит части, но это отправку не ломает).
	# sms_tool остаётся запасным ТОЛЬКО для латиницы (кириллицу он испортит в
	# «?????») - на случай, если наш путь по какой-то причине не прошёл.
	_send_pdu "$_so_port" "$_so_to" "$_so_txt" 2>/dev/null
	_so_pdurc=$?
	[ "$_so_pdurc" = 0 ] && return 0
	if ! "$RES/smspdu.sh" needucs2 "$_so_txt"; then
		_sms_run "$_so_tat" $(_smstool_at) -d "$_so_port" send "$_so_to" "$_so_txt" 2>/dev/null
		return $?
	fi
	return "$_so_pdurc"
}

# Сырой sms_tool, без подмены на MM-мост: нужен там, где мы СОЗНАТЕЛЬНО идём в
# AT-порт (запасной путь выше и наш PDU).
_smstool_at() {
	command -v sms_tool >/dev/null 2>&1 && echo /usr/bin/sms_tool || echo sms_tool
}

# НОМЕР ПРИВОДИМ К МЕЖДУНАРОДНОМУ ВИДУ - ОДИН РАЗ, ДЛЯ ВСЕХ ТРАНСПОРТОВ.
#
# Страница отдаёт номер так, как он лежит в поле или в телефонной книге, и «+»
# там теряется. Для сети это не мелочь:
#   - ModemManager на QMI-модеме отвечает «Unhandled QMI protocol error (54):
#     Couldn't write SMS part ... WmsCauseCode» (проверено на Compal, стенд 88);
#   - наш PDU-путь помечал такой номер национальным (TOA=81), и SMSC отклонял
#     его «+CMS ERROR» (проверено на Telit, стенд 11).
# Оба отказа выглядели как «сообщение не уходит», хотя дело было в одной цифре
# формата. Правило: «+» - уже международный; «00» - международный, только если
# после него остаётся полноценный номер (короткие сервисные вроде 000100 тоже
# начинаются с 00, и «+0100» сеть отвергает); 11 и более цифр, не начинающихся
# с транковых «8»/«0», - международный без «+»; короткие номера (900, 0500)
# и настоящие национальные (8XXXXXXXXXX) не трогаем.
_norm_num() {   # $1 - номер как его дала страница
	_nn=$(printf '%s' "$1" | tr -cd '0-9+')
	case "$_nn" in
		+*) printf '%s' "$_nn"; return ;;
		00*) _nt="${_nn#00}"
		     [ "${#_nt}" -ge 9 ] && { printf '+%s' "$_nt"; return; }
		     printf '%s' "$_nn"; return ;;
	esac
	case "$_nn" in
		[1-79]*) [ "${#_nn}" -ge 11 ] && { printf '+%s' "$_nn"; return; } ;;
	esac
	printf '%s' "$_nn"
}

# ОЧЕРЕДЬ ИСХОДЯЩИХ - ЧТОБЫ ЗАНЯТЫЙ ПОРТ НЕ ТЕРЯЛ СООБЩЕНИЕ.
#
# ЗАЧЕМ. AT-порт делят опрос метрик, приём входящих, SMS и USSD. Если в момент
# «Отправить» модем как раз принимал двухчастную рассылку, приглашение «>» не
# приходит вовремя - и пользователь получал «sms sending failed», а сообщение
# исчезало. Теперь оно не исчезает: кладётся в очередь и уходит следующим кругом
# сторожа, когда порт освободится.
#
# ОЧЕРЕДЬ НА ФЛЕШЕ, а не в /tmp: неотправленное сообщение обязано пережить
# перезагрузку - иначе «ушло или нет» становится лотереей. Записей мало и они
# крошечные, износ флеша тут ни при чём.
SMSQ_DIR=/etc/5gmodem/smsq
SMSQ_MAX_TRIES=10
SMSQ_MAX_AGE=86400

_q_enqueue() {   # $1 - номер, $2 - текст, $3 - порт
	mkdir -p "$SMSQ_DIR" 2>/dev/null || return 1
	_qe_f="$SMSQ_DIR/$(date +%s 2>/dev/null).$$"
	{
		printf 'to=%s\n' "$1"
		printf 'port=%s\n' "$3"
		printf 'tries=0\n'
		printf 'born=%s\n' "$(date +%s 2>/dev/null)"
		printf 'text:\n'
		printf '%s' "$2"
	} > "$_qe_f.tmp" 2>/dev/null && mv "$_qe_f.tmp" "$_qe_f.sms" 2>/dev/null
}

# Отправка одного файла очереди. Возвращает 0 - ушло (файл удалён),
# 1 - не вышло (счётчик попыток увеличен), 2 - сдались (файл удалён с записью
# в журнал: вечно копить нельзя, а молча выбрасывать - тем более).
_q_send_one() {   # $1 - файл
	_qs_f="$1"
	_qs_to=""; _qs_port=""; _qs_tries=0; _qs_born=0; _qs_txt=""; _qs_inbody=0
	# «|| [ -n "$_qs_l" ]» ОБЯЗАТЕЛЕН: тело письма пишется БЕЗ завершающего
	# перевода строки, а `read` последнюю такую строку не отдаёт - текст читался
	# пустым, файл признавался битым и сообщение УДАЛЯЛОСЬ молча (поймано на
	# первом же прогоне очереди).
	while IFS= read -r _qs_l || [ -n "$_qs_l" ]; do
		if [ "$_qs_inbody" = 1 ]; then
			_qs_txt="${_qs_txt:+$_qs_txt
}$_qs_l"
			continue
		fi
		case "$_qs_l" in
			to=*)    _qs_to="${_qs_l#to=}" ;;
			port=*)  _qs_port="${_qs_l#port=}" ;;
			tries=*) _qs_tries="${_qs_l#tries=}" ;;
			born=*)  _qs_born="${_qs_l#born=}" ;;
			text:)   _qs_inbody=1 ;;
		esac
	done < "$_qs_f"
	case "$_qs_tries" in ''|*[!0-9]*) _qs_tries=0 ;; esac
	case "$_qs_born" in ''|*[!0-9]*) _qs_born=0 ;; esac
	if [ -z "$_qs_to" ] || [ -z "$_qs_txt" ]; then
		logger -t 5gmodem "smsbridge: corrupt queue entry $_qs_f (no number or text) - deleting"
		rm -f "$_qs_f"
		return 2
	fi

	_qs_now=$(date +%s 2>/dev/null); case "$_qs_now" in ''|*[!0-9]*) _qs_now=0 ;; esac
	if [ "$_qs_tries" -ge "$SMSQ_MAX_TRIES" ] \
	   || { [ "$_qs_born" -gt 0 ] && [ "$_qs_now" -gt 0 ] && [ $((_qs_now - _qs_born)) -gt "$SMSQ_MAX_AGE" ]; }; then
		logger -t 5gmodem "smsbridge: message for \"$_qs_to\" never went out after $_qs_tries attempts - dropping it from the queue"
		rm -f "$_qs_f"
		return 2
	fi

	# Записи, попавшие в очередь ДО нормализации, чиним на лету.
	_qs_to=$(_norm_num "$_qs_to")
	[ -n "$_qs_port" ] || _qs_port=$(uci -q get "$CFG.sms.sendport")
	[ -n "$_qs_port" ] && [ -c "$_qs_port" ] || return 1

	_send_one "$_qs_port" "$_qs_to" "$_qs_txt" slow
	_qs_rc=$?

	# ПОСЛЕДНЕЕ СРЕДСТВО - ЗАБРАТЬ МОДЕМ У ModemManager НА ВРЕМЯ ОТПРАВКИ.
	#
	# Замерено на Compal RXM-G1 в MBIM (стенд 11.1, слабый сигнал RSRP -114,
	# SINR -5): отправка через MM то уходит за секунду, то возвращает «Couldn't
	# send SMS part: Failure» или висит до таймаута, а наш AT-обмен не проходит,
	# пока MM держит порт открытым. Стоит его инхибировать - и то же сообщение
	# уходит своим PDU за 4 c.
	#
	# ЦЕНА ВЫСОКА, поэтому по умолчанию ВЫКЛЮЧЕНО: на время инхибиции MM теряет
	# модем, и после снятия он подхватывает его не сразу - на стенде интерфейс
	# лежал около минуты. Включается осознанно: 5gmodem.sms.send_inhibit_mm=1.
	#
	# И только в ФОНОВОЙ досылке: страница должна отвечать быстро, а не держать
	# пользователя, пока мы передёргиваем стек.
	if [ "$_qs_rc" != 0 ] && [ "$(uci -q get "$CFG.sms.send_inhibit_mm")" = "1" ] \
	   && _port_is_mm "$_qs_port" && command -v mmcli >/dev/null 2>&1; then
		_qs_uid=$(mmcli -L 2>/dev/null | sed -n "s|.*/Modem/\([0-9]*\).*|\1|p" | head -1)
		[ -n "$_qs_uid" ] && _qs_uid=$(mmcli -m "$_qs_uid" 2>/dev/null \
			| sed -n "s|.*device: *||p" | head -1 | tr -d " '")
		if [ -n "$_qs_uid" ]; then
			logger -t 5gmodem "smsbridge: last attempt - borrowing the modem from ModemManager for the send"
			( mmcli --inhibit-device="$_qs_uid" >/dev/null 2>&1 & echo $! > /tmp/5gmodem_sms_inhibit.pid ) 
			_qs_w=0
			while [ "$_qs_w" -lt 15 ]; do
				mmcli -L 2>/dev/null | grep -q "/Modem/" || break
				sleep 1; _qs_w=$((_qs_w + 1))
			done
			_send_one "$_qs_port" "$_qs_to" "$_qs_txt" slow
			_qs_rc=$?
			kill "$(cat /tmp/5gmodem_sms_inhibit.pid 2>/dev/null)" 2>/dev/null
			rm -f /tmp/5gmodem_sms_inhibit.pid
			logger -t 5gmodem "smsbridge: modem returned to ModemManager (send $([ "$_qs_rc" = 0 ] && echo succeeded || echo failed))"
		fi
	fi
	( exit "$_qs_rc" )
	if [ $? = 0 ]; then
		rm -f "$_qs_f"
		logger -t 5gmodem "smsbridge: queued message for \"$_qs_to\" sent (attempt $((_qs_tries + 1)))"
		return 0
	fi
	sed -i "s/^tries=.*/tries=$((_qs_tries + 1))/" "$_qs_f" 2>/dev/null
	return 1
}

# ОТПРАВКА СВОИМ PDU - РАДИ КИРИЛЛИЦЫ (см. smspdu.sh).
#
# Диалог с модемом здесь НЕ односторонний: на «AT+CMGS=<длина>» он отвечает
# приглашением «>», и только после него принимает тело PDU, завершённое Ctrl-Z.
# `sms_tool at` так не умеет (шлёт команду и читает ответ), поэтому обмен ведёт
# gcom - он для того и создан, и уже лежит в зависимостях пакета.
#
# Отправка ПОЧАСТНО: длинный текст smspdu.sh разбивает на части с UDH, и каждая
# уходит отдельной AT+CMGS. Провал любой части прекращает отправку - лучше
# честная ошибка, чем половина сообщения у адресата.
#
# SMS_PDU_CMD позволяет подменить глагол на CMGW (запись в память модема) -
# этим путём проверяется кодировщик без реальной отправки и без денег.
_send_pdu() {   # $1 - порт, $2 - номер, $3 - текст
	_sp_port="$1"
	[ -n "$_sp_port" ] && [ -c "$_sp_port" ] || { echo "no port" >&2; return 2; }

	# ПОРТ ПОД ModemManager - НАШ ОБМЕН ТАМ НЕВОЗМОЖЕН, И ПРОБОВАТЬ НЕЛЬЗЯ.
	#
	# MM держит управляющий порт ОТКРЫТЫМ и вычитывает из него всё подряд:
	# приглашение «>» и ответ «+CMGS:» уходят ему, а мы ждём их до таймаута.
	# Проверено на Compal RXM-G1 - молчат и gcom, и прямой обмен, хотя одиночные
	# команды через sms_tool на том же порту проходят (там гонка чтения, которую
	# он иногда выигрывает). Раньше это выглядело как двухминутное зависание
	# страницы, поэтому отказываем сразу и внятно.
	if _port_is_mm "$_sp_port"; then
		_SP_LASTERR="портом владеет ModemManager: кириллица через AT недоступна"
		logger -t 5gmodem "smsbridge: $_sp_port is under ModemManager - PDU path skipped"
		return 3
	fi
	_sp_cmd="${SMS_PDU_CMD:-CMGS}"
	_sp_parts=$("$RES/smspdu.sh" encode "$2" "$3" 2>/dev/null)
	[ -n "$_sp_parts" ] || { echo "pdu encode failed" >&2; return 1; }
	_sp_rc=0
	# ОБМЕН ВЕДЁМ САМИ, БЕЗ gcom.
	#
	# gcom оказался ненадёжным транспортом: на Compal RXM-G1 он не смог даже
	# «AT+CMGF=0» - таймаут на всех командах, хотя sms_tool с тем же портом
	# работает. Разбираться в его настройках порта дороже, чем открыть порт
	# самим: нам нужны ровно три записи и одно чтение ответа.
	#
	# Приглашение «>» приходит БЕЗ перевода строки, а `read` ждёт именно его -
	# поэтому его не вычитываем, а выдерживаем паузу (busybox без дробного
	# sleep) и шлём тело. Признак успеха - строка «+CMGS:» в ответе.
	while read -r _sp_len _sp_pdu; do
		[ -n "$_sp_pdu" ] || continue
		[ "$_sp_rc" = 0 ] || break
		stty -F "$_sp_port" 115200 raw -echo 2>/dev/null
		_sp_ans=""
		if command exec 3<>"$_sp_port" 2>/dev/null; then
			printf 'AT+CMGF=0\r' >&3
			sleep 1
			printf 'AT+%s=%s\r' "$_sp_cmd" "$_sp_len" >&3
			sleep 2
			printf '%s\032' "$_sp_pdu" >&3
			while read -t 25 -r _sp_l <&3; do
				_sp_l=$(printf '%s' "$_sp_l" | tr -d '\r')
				[ -n "$_sp_l" ] || continue
				_sp_ans="$_sp_l"
				case "$_sp_l" in
					"+$_sp_cmd:"*) _sp_ans="OK:$_sp_l"; break ;;
					*"+CMS ERROR"*|*"+CME ERROR"*|ERROR) break ;;
				esac
			done
			exec 3>&-
		fi
		case "$_sp_ans" in
			OK:*) ;;
			*) _sp_rc=1
			   # ПРИГЛАШЕНИЕ НАДО ЗАКРЫТЬ. Если модем успел показать «>», он ЖДЁТ
			   # тело сообщения, и следующая же команда опроса метрик уедет в него
			   # как текст SMS. ESC отменяет ввод - штатный выход по 3GPP 27.005.
			   printf '\033' > "$_sp_port" 2>/dev/null
			   _sp_ceer=$(_sms_run 8 $(_smstool) -d "$_sp_port" at "AT+CEER" 2>/dev/null \
				| tr -d '\r' | grep -iE "CEER|ERROR" | head -1)
			   logger -t 5gmodem "smsbridge: a PDU part did not go out ($_sp_cmd, number \"$2\", len=$_sp_len): ${_sp_ans:-no answer}${_sp_ceer:+ | $_sp_ceer}"
			   _SP_LASTERR="${_sp_ans:-нет ответа от модема}" ;;
		esac
	done <<PARTS_EOF
$_sp_parts
PARTS_EOF
	if [ "$_sp_rc" = 0 ]; then
		# Строку успеха печатает ВЫЗЫВАЮЩИЙ (ветка send), иначе она уходила
		# дважды - и пользователь видел её в интерфейсе продублированной.
		return 0
	fi
	echo "sms sending failed: ${_SP_LASTERR:-no answer from modem}" >&2
	return 1
}

BOX="${1:-recv}"
case "$BOX" in
	delete|delete-start|delete-run) DEL="$2"; STORE="$3"; PORT="$4" ;;
	send)   SND_TO="$2"; SND_TXT="$3"; PORT="$4" ;;
	queue-run|queue-list) PORT="${2:-$(uci -q get "$CFG.sms.sendport")}" ;;
	unseen) UL="$2"; STORE="$3"; PORT="$4" ;;
	*)      STORE="$2"; PORT="$3" ;;
esac

_DJ_FILE="/tmp/5gmodem_smsdel_$(printf '%s' "$_TGT_PATH" | tr -c 'A-Za-z0-9' '_').json"
_DJ_OK=""; _DJ_FAIL=""; _DJ_DONE=0; _DJ_TOTAL=0

_dj_pid() {
	sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$_DJ_FILE" 2>/dev/null | head -1
}

_dj_running() {
	case "$(cat "$_DJ_FILE" 2>/dev/null)" in *'"state":"running"'*) ;; *) return 1 ;; esac
	_djr_p=$(_dj_pid)
	[ -n "$_djr_p" ] && kill -0 "$_djr_p" 2>/dev/null
}

_dj_write() {
	printf '{"pid":%s,"state":"%s","total":%s,"done":%s,"ok":[%s],"fail":[%s]}\n' \
		"${2:-$$}" "$1" "$_DJ_TOTAL" "$_DJ_DONE" "$_DJ_OK" "$_DJ_FAIL" > "$_DJ_FILE.tmp" 2>/dev/null \
		&& mv "$_DJ_FILE.tmp" "$_DJ_FILE" 2>/dev/null
}

_dj_ok() {
	_DJ_OK="${_DJ_OK}${_DJ_OK:+,}$1"
	_DJ_DONE=$((_DJ_DONE + 1))
}

_dj_fail() {
	_DJ_FAIL="${_DJ_FAIL}${_DJ_FAIL:+,}{\"index\":$1,\"why\":\"$2\",\"arg\":\"$3\"}"
	_DJ_DONE=$((_DJ_DONE + 1))
}

_dj_count() {
	_djc_n=0
	for _djc_i in $(printf '%s' "$1" | tr ',' ' '); do _djc_n=$((_djc_n + 1)); done
	echo "$_djc_n"
}

case "$BOX" in
	delete-status)
		if [ -s "$_DJ_FILE" ]; then
			if _dj_running; then cat "$_DJ_FILE"
			else sed 's/"state":"running"/"state":"dead"/' "$_DJ_FILE"
			fi
		else
			echo '{"state":"none"}'
		fi
		exit 0 ;;
	delete-start)
		case "$DEL" in ''|*[!0-9,]*|,*|*,|*,,*) echo '{"state":"bad"}'; exit 2 ;; esac
		if _dj_running; then echo '{"state":"busy"}'; exit 0; fi
		_DJ_TOTAL=$(_dj_count "$DEL")
		( SMS_MODEM="$_TGT_PATH" exec "$0" delete-run "$DEL" "$STORE" "$PORT" ) >/dev/null 2>&1 </dev/null &
		_dj_write running "$!"
		printf '{"state":"running","pid":%s,"total":%s}\n' "$!" "$_DJ_TOTAL"
		sleep 1
		exit 0 ;;
	delete-run)
		case "$DEL" in ''|*[!0-9,]*) exit 2 ;; esac
		_DJ_TOTAL=$(_dj_count "$DEL")
		_dj_write running ;;
esac

# Есть AT-порт (режим debug) - обычный путь: sms_tool умеет больше, чем API.
# AT-порт спрашиваем У ЦЕЛЕВОГО модема: при обходе всех модемов глобальный ключ
# описывает активного, и свисток-сосед пошёл бы по AT-ветке с чужим портом.
_sb_p=$(uci -q get "5gmodem.$_TGT_SEC.at_port")
[ -n "$_sb_p" ] || _sb_p=$(uci -q get "5gmodem.@5gmodem[0].at_port")
if [ "$(_active_kind)" = "hilink" ] && ! { [ -n "$_sb_p" ] && [ -c "$_sb_p" ]; }; then
	case "$BOX" in
		sent) "$RES/hilink.sh" smsread out "$_TGT_PATH" ;;
		status)
			# Страница разбирает СТРОКУ формата sms_tool: "Storage type: ME,
			# used: N, total: M" - позиции подстрок в ней зашиты в разборе.
			# Поэтому отдаём ровно её, а не JSON.
			# Путь обязателен и здесь: без него hilink.sh берёт активный
			# модем, и счётчик приходил бы от соседа (аудит 12.09.2026).
			_c=$("$RES/hilink.sh" smscount "$_TGT_PATH" 2>/dev/null | tr -d '\r')
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
				"$RES/hilink.sh" smsread in "$_TGT_PATH" 2>/dev/null \
					| jsonfilter -e '@.msg[*].index' 2>/dev/null \
					| while read -r _i; do
						[ -n "$_i" ] && "$RES/hilink.sh" smsdel "$_i" "$_TGT_PATH" >/dev/null 2>&1
					done
				echo '{"success":true}'
			else
				"$RES/hilink.sh" smsdel "$DEL" "$_TGT_PATH"
			fi ;;
		delete-run)
			for _dr_i in $(printf '%s' "$DEL" | tr ',' ' '); do
				_dr_o=$("$RES/hilink.sh" smsdel "$_dr_i" "$_TGT_PATH" 2>/dev/null)
				case "$_dr_o" in
					*'"success":true'*) _dj_ok "$_dr_i" ;;
					*) _dj_fail "$_dr_i" refused "$(printf '%s' "$_dr_o" | sed -n 's/.*"code":"\([0-9A-Za-z_-]*\)".*/\1/p')" ;;
				esac
				_dj_write running
			done
			_dj_write done ;;
		# Путь передаём ВСЕГДА: без него удаление и отправка уходили активному
		# модему, то есть чужой симке (аудит 12.09.2026).
		send)   "$RES/hilink.sh" smssend "$SND_TO" "$SND_TXT" "$_TGT_PATH" ;;
		*)    _kb_out "$("$RES/hilink.sh" smsread in "$_TGT_PATH")" ;;
	esac
	exit 0
fi

# Обычный модем - прежний путь. Порт берём из аргумента, иначе из настроек.
[ -n "$PORT" ] || PORT=$(uci -q get 5gmodem.sms.readport)
[ -n "$PORT" ] || PORT=$("$RES/detect.sh" 2>/dev/null)
# Порта нет вовсе - отдаём пустой список, а не ошибку: страница покажет
# «сообщений нет», и это честнее, чем красный текст про несуществующий /dev.
[ -n "$PORT" ] || [ "$BOX" = delete-run ] || { echo "[]"; exit 0; }

# ПУСТАЯ ОЧЕРЕДЬ ДОСЫЛКИ - ВЫХОД ДО ЗАМКА. queue-run зовётся каждым кругом
# sessionwatch, и с пустой очередью ему у порта делать нечего, а общий at_lock
# ниже ставил его в очередь на срок до 15 c - на загруженном порту эти холостые
# ожидания складывались с настоящими читателями и душили страницу SMS (разбор
# на роутере Андрея, 10.08.2026).
if [ "$BOX" = "queue-run" ]; then
	_qr_any=0
	for _qr_f in "$SMSQ_DIR"/*.sms; do
		[ -f "$_qr_f" ] && { _qr_any=1; break; }
	done
	[ "$_qr_any" = 1 ] || exit 0
fi

# Ждём своей очереди к порту: чтение SMS идёт параллельно опросу метрик, и без
# этого списки приходили обрезанными, а в текст сообщения попадали чужие ответы.
# Блокировку снимет ядро при выходе. Не дождались - идём как раньше: потерять
# сообщения хуже, чем рискнуть смешением.
. "$RES/atlock.sh"
# РЕЗУЛЬТАТ ЗАПОМИНАЕМ. По неудаче at_lock НИЧЕГО не выставляет (_AT_LOCK_HELD
# остаётся пустым), поэтому судить о занятости порта по этой переменной нельзя -
# ветка send ниже так и не срабатывала (аудит 12.09.2026).
_AT_INH="$_AT_LOCK_HELD"
if [ "$BOX" = delete-run ]; then _AT_LOCKED=1; else at_lock "$PORT" 15; _AT_LOCKED=$?; fi

# СЧЁТЧИК ПРИ ЗАНЯТОМ ПОРТУ - ИЗ ПОСЛЕДНЕГО ОТВЕТА, А НЕ ИЗ МОДЕМА. Правило
# «не дождались очереди - идём всё равно» написано ради чтения сообщений: их
# терять нельзя. Счётчику терять нечего, а заход в порт, который держит
# зависший процесс, добавлял ещё одного ждущего - и шёл с короткой формой
# «-s ME» (хранилище не прочиталось), которая у FM350 уводит приём на SIM.
# Живой отчёт 14.09.2026 (FM350-GL, 2.5.1): «sms_tool -s ME status» в
# D-состоянии на ttyUSB3, порт метрик занят восемь минут подряд.
_ST_CACHE="/tmp/5gmodem_smsstatus_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
if [ "$BOX" = status ] && [ "$_AT_LOCKED" != 0 ] && ! _via_mm; then
	cat "$_ST_CACHE" 2>/dev/null
	exit 0
fi

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

# ===== АРХИВ ВХОДЯЩИХ =====
#
# ЗАЧЕМ. У модема под ModemManager (Compal RXM-G1 в MBIM) входящие не хранятся
# НИГДЕ, кроме оперативной памяти MM: при живом непрочитанном сообщении все три
# AT-хранилища показывают used: 0, а MM после пересоздания объекта модема честно
# пишет «couldn't load SMS parts from storage 'mt': No SMS PDUs read». Значит
# любое пересоздание модема в MM стирает переписку насовсем, а пересоздают его
# рутинно: наше же лечение в mm-inhibit.sh (unbind/bind), наша инхибиция на
# время отправки, флап USB, перезапуск MM, перезагрузка роутера. Проверено на
# стенде 02.08.2026: сообщение прожило десять минут в покое и исчезло ровно на
# unbind/bind, вместе со сменой Modem/3 на Modem/4.
#
# Поэтому сообщения храним У СЕБЯ, рядом с памятью о прочитанном. Живой список
# из MM при каждом чтении ДОЛИВАЕТСЯ в архив, а наружу уходит архив: пропажа
# сообщения из MM перестаёт что-либо значить.
#
# ТОЛЬКО ДЛЯ MM-ПУТИ. У обычного модема сообщения лежат в нём самом, там архив
# только мешал бы - показывал бы удалённое мимо нас (с телефона, другой утилитой).
#
# ФАЙЛ НА СООБЩЕНИЕ, а не общий список: текст SMS содержит и переводы строк, и
# кавычки, и что угодно ещё, а так его не надо ни экранировать, ни разбирать -
# первая строка время, вторая отправитель, дальше текст как есть. Имя файла -
# «<номер>.<ключ>»: ключ (хеш отправителя, времени и текста) даёт дедупликацию,
# номер - устойчивый индекс для удаления.
# ПРЕДЕЛ АРХИВА НАСТРАИВАЕМЫЙ. У MM-пути он был жёстким (200) - там архив лишь
# дублировал память MM. Со сливом из модема архив становится ЕДИНСТВЕННЫМ
# местом, где сообщения живут, и «сколько хранить» - решение человека.
ARCH_MAX=$(uci -q get "$CFG.sms.archive_limit")
case "$ARCH_MAX" in ''|*[!0-9]*) ARCH_MAX=200 ;; esac
[ "$ARCH_MAX" -ge 10 ] 2>/dev/null || ARCH_MAX=10
[ "$ARCH_MAX" -le 2000 ] 2>/dev/null || ARCH_MAX=2000
ARCH_BASE=100000
_LIVE_MAP=" "

# ВКЛЮЧЁН ЛИ АРХИВ ДЛЯ ЭТОГО МОДЕМА.
#
# У MM-пути - всегда: там без архива переписка исчезает при любом пересоздании
# модема в MM (см. выше). У обычного AT-модема - по настройке `archive`, и это
# ОСОЗНАННО не по умолчанию: пока архива нет, сообщения лежат в модеме, и мы
# показываем ровно его содержимое - в том числе удалённое мимо нас, с телефона
# или другой утилитой. Включённый архив меняет источник правды, и человек должен
# согласиться на это сам.
_ARCH_ON=""
_arch_on() {
	if [ -z "$_ARCH_ON" ]; then
		if _via_mm; then _ARCH_ON=1
		elif [ "$(uci -q get "$CFG.sms.archive")" = "1" ]; then _ARCH_ON=1
		else _ARCH_ON=0
		fi
	fi
	[ "$_ARCH_ON" = 1 ]
}

_arch_dir() {
	_ad=$(printf '%s' "$_TGT_PATH" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_ad" ] && echo "$SEEN_DIR/sms_arch.$_ad" || echo "$SEEN_DIR/sms_arch"
}

_arch_key() {   # $1 - отправитель, $2 - время, $3 - текст
	printf '%s|%s|%s' "$1" "$2" "$3" | md5sum | cut -c1-16
}

# Номера архива начинаются с ARCH_BASE и с индексами модема не пересекаются:
# по номеру всегда видно, кому адресовано удаление - модему или только архиву.
_arch_next() {   # $1 - каталог
	_an="$ARCH_BASE"
	for _anf in "$1"/*.*; do
		[ -f "$_anf" ] || continue
		_ani=${_anf##*/}; _ani=${_ani%%.*}
		case "$_ani" in ''|*[!0-9]*) continue ;; esac
		[ "$_ani" -ge "$_an" ] && _an=$((_ani + 1))
	done
	echo "$_an"
}

_arch_files() {   # $1 - каталог; имена в порядке номеров
	ls "$1" 2>/dev/null | sort -t. -k1,1n
}

# ЧАСТИ ДЛИННОЙ SMS ХРАНИМ КАК ЕСТЬ, а не склеиваем при записи. Склейка на
# входе выглядит заманчиво, но части приходят РАЗНЫМИ кругами опроса (вторая
# может прийти через минуту), и «собранное» сообщение пришлось бы потом
# дописывать - то есть держать незавершённые склейки и разбираться, что делать с
# частью, которая не пришла никогда. Поэтому части остаются отдельными записями
# со своими part/total/reference, а собирают их те же, кто собирал раньше:
# страница «Входящие» (mergesms) и уведомитель Telegram. Ничего в них менять не
# пришлось.
#
# СТАРЫЕ ФАЙЛЫ ЧИТАЮТСЯ КАК РАНЬШЕ. Первая строка нового формата - «#p=часть/
# всего/ссылка»; в старом формате первой строкой шло время, и с «#p=» оно не
# начинается никогда. Одночастные сообщения пишутся вообще без заголовка, то
# есть в точности прежним форматом.
_arch_read() {   # $1 - файл; заполняет _A_TS _A_FROM _A_TEXT _A_PART _A_TOTAL _A_REF
	_A_TS=""; _A_FROM=""; _A_TEXT=""; _A_PART=""; _A_TOTAL=""; _A_REF=""; _A_TZ=""
	{
		IFS= read -r _A_TS
		while :; do
			case "$_A_TS" in
				'#p='*)
					_arh=${_A_TS#\#p=}
					_A_PART=${_arh%%/*}; _arh=${_arh#*/}
					_A_TOTAL=${_arh%%/*}; _A_REF=${_arh#*/}
					IFS= read -r _A_TS ;;
				'#tz='*)
					_A_TZ=${_A_TS#\#tz=}
					IFS= read -r _A_TS ;;
				*) break ;;
			esac
		done
		IFS= read -r _A_FROM
		# ОТПРАВИТЕЛЬ БЕЗ СЫРОГО CR. В архив он попадал как «beeline\r», recv
		# отдавал его так же, а ключ «виденного» (seen) строится через _nd_jesc,
		# который CR вырезает, - ключи никогда не совпадали, и уведомитель
		# каждый круг заново «находил» те же три SMS (стенд FM350, 13.09.2026).
		_A_FROM=$(printf '%s' "$_A_FROM" | tr -d '\r')
		while IFS= read -r _arl || [ -n "$_arl" ]; do
			_A_TEXT="${_A_TEXT:+$_A_TEXT
}$_arl"
		done
	} < "$1"
}

_arch_trim() {   # $1 - каталог
	_atn=0
	for _atf in "$1"/*.*; do [ -f "$_atf" ] && _atn=$((_atn + 1)); done
	[ "$_atn" -gt "$ARCH_MAX" ] || return 0
	for _atf in $(_arch_files "$1" | head -n "$((_atn - ARCH_MAX))"); do
		rm -f "$1/$_atf" 2>/dev/null
	done
}

# Доливка живого списка в архив. Заодно запоминаем, у каких сообщений СЕЙЧАС
# есть индекс в модеме: их наружу отдаём с ним, чтобы удаление уходило в модем,
# а не только в архив.
_arch_merge() {   # $1 - живой JSON от sms_tool -j
	_amd=$(_arch_dir)
	mkdir -p "$_amd" 2>/dev/null || return 0
	_amj="$1"
	_LIVE_MAP=" "
	_AM_SEEN=" "
	[ -n "$_amj" ] || return 0
	_amn=$(printf '%s' "$_amj" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_amn" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_amn" -gt 0 ] || return 0
	_amnext=$(_arch_next "$_amd")
	_ami=0
	while [ "$_ami" -lt "$_amn" ]; do
		_amx=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].index" 2>/dev/null)
		_ams=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].sender" 2>/dev/null)
		_amt=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].timestamp" 2>/dev/null)
		_amc=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].content" 2>/dev/null)
		_ampt=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].part" 2>/dev/null)
		_amtt=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].total" 2>/dev/null)
		_amrf=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].reference" 2>/dev/null)
		_amtz=$(printf '%s' "$_amj" | jsonfilter -e "@.msg[$_ami].tz" 2>/dev/null)
		_ami=$((_ami + 1))
		# НЕРАЗОБРАННОЕ СООБЩЕНИЕ НЕ АРХИВИРУЕМ. sms_tool на битом PDU отдаёт
		# запись с полем error и пустыми отправителем/текстом (воспроизведено на
		# стенде: в память модема попал SUBMIT-PDU, и recv вернул «error decoding
		# pdu»). Складывать такие пустышки в архив - засорять ящик, а главное -
		# они не должны дать повода СТЕРЕТЬ их из модема: сообщение, которое мы
		# не смогли прочитать, ещё может быть прочитано другой утилитой.
		[ -n "$_ams$_amc" ] || continue
		_amk=$(_arch_key "$_ams" "$_amt" "$_amc")
		case "$_amx" in ''|*[!0-9]*) ;; *) _LIVE_MAP="$_LIVE_MAP$_amk:$_amx " ;; esac
		# СЧИТАЕМ КРАТНОСТЬ, а не «есть ли такой ключ». Время у сообщения с
		# точностью до минуты, поэтому повторная доставка того же текста тем же
		# отправителем в ту же минуту даёт ТОТ ЖЕ ключ - и второе сообщение
		# просто исчезло бы. Сверяем, сколько таких в живом списке и сколько уже
		# лежит в архиве, и дописываем недостающие.
		_amseen=${_AM_SEEN#* $_amk:}
		case "$_AM_SEEN" in
			*" $_amk:"*) _amseen=$((${_amseen%% *} + 1))
				_AM_SEEN=$(printf '%s' "$_AM_SEEN" | sed "s| $_amk:[0-9]* | |") ;;
			*) _amseen=1 ;;
		esac
		_AM_SEEN="$_AM_SEEN$_amk:$_amseen "
		_amhave=0
		for _amf in "$_amd"/*."$_amk"; do [ -f "$_amf" ] && _amhave=$((_amhave + 1)); done
		[ "$_amseen" -le "$_amhave" ] && continue
		_amhd=""
		case "$_amtz" in local) _amhd='#tz=local' ;; esac
		case "$_ampt$_amtt" in
			''|*[!0-9]*)
				{ [ -n "$_amhd" ] && printf '%s\n' "$_amhd"
				  printf '%s\n%s\n%s' "$_amt" "$_ams" "$_amc"; } > "$_amd/$_amnext.$_amk" 2>/dev/null ;;
			*)
				{ [ -n "$_amhd" ] && printf '%s\n' "$_amhd"
				  printf '#p=%s/%s/%s\n%s\n%s\n%s' "$_ampt" "$_amtt" "${_amrf:-0}" \
					"$_amt" "$_ams" "$_amc"; } > "$_amd/$_amnext.$_amk" 2>/dev/null ;;
		esac
		_amnext=$((_amnext + 1))
	done
	_arch_trim "$_amd"
}

# Индекс сообщения для выдачи: живой, если оно ещё в модеме, иначе архивный.
# Ответ кладём в _A_IDX, а не печатаем: на выдаче списка это вызов на каждое
# сообщение, и подстановка $(...) стоила бы форка на каждое.
_arch_index() {   # $1 - номер файла, $2 - ключ
	case "$_LIVE_MAP" in
		*" $2:"*)
			_A_IDX=${_LIVE_MAP#* $2:}
			_A_IDX=${_A_IDX%% *}
			# Живой индекс ОДНОРАЗОВЫЙ: при кратности одинаковых сообщений он
			# принадлежит только первому, остальные отдаём с архивными.
			_aipre=${_LIVE_MAP%% $2:*}
			_airest=${_LIVE_MAP#* $2:}
			_LIVE_MAP="$_aipre ${_airest#* }" ;;
		*) _A_IDX="$1" ;;
	esac
}

_arch_json() {
	. /usr/share/libubox/jshn.sh
	_ajd=$(_arch_dir)
	json_init
	json_add_array msg
	for _ajf in $(_arch_files "$_ajd"); do
		[ -f "$_ajd/$_ajf" ] || continue
		_arch_read "$_ajd/$_ajf"
		_arch_index "${_ajf%%.*}" "${_ajf#*.}"
		_aj_h=""
		case "$_A_TOTAL" in ''|0|1|*[!0-9]*) _aj_h=${_ajf#*.} ;; esac
		_kb_put "$_A_IDX" "$_A_FROM" "$_A_TS" "$_A_TEXT" "$_A_PART" "$_A_TOTAL" "$_A_REF" "$_aj_h"
		json_add_object ""
		json_add_int index "$_A_IDX"
		json_add_string sender "$_A_FROM"
		json_add_string timestamp "$_A_TS"
		[ -n "$_A_TZ" ] && json_add_string tz "$_A_TZ"
		json_add_string content "$_A_TEXT"
		# Поля мультипарта отдаём ТОЛЬКО когда они есть: у одночастного
		# сообщения их не было и в живом ответе sms_tool, а «total: 1» на пустом
		# месте заставил бы страницу и бота лезть в склейку без надобности.
		case "$_A_TOTAL" in
			''|*[!0-9]*) ;;
			*)
				json_add_int part "${_A_PART:-1}"
				json_add_int total "$_A_TOTAL"
				json_add_int reference "${_A_REF:-0}" ;;
		esac
		json_close_object
	done
	json_close_array
	_kb_build
	json_add_array keys
	_aj_i=1
	while [ "$_aj_i" -le "$_kb_n" ]; do
		eval "_aj_x=\$_kb_x$_aj_i; _aj_k=\$_kb_k$_aj_i; _aj_o=\"\$_kb_s$_aj_i|\$_kb_t$_aj_i\""
		_aj_i=$((_aj_i + 1))
		[ -n "$_aj_k" ] || continue
		json_add_object ""
		json_add_int index "$_aj_x"
		json_add_string key "$_aj_k"
		json_add_string old "$_aj_o"
		json_close_object
	done
	json_close_array
	json_dump
}

_arch_text() {
	_axd=$(_arch_dir)
	for _axf in $(_arch_files "$_axd"); do
		[ -f "$_axd/$_axf" ] || continue
		_arch_read "$_axd/$_axf"
		_arch_index "${_axf%%.*}" "${_axf#*.}"
		printf 'MSG: %s\nFrom: %s\nDate/Time: %s\n%s\n\n' \
			"$_A_IDX" "$_A_FROM" "$_A_TS" "$_A_TEXT"
	done
}

_arch_count() {
	_acn=0
	for _acf in "$(_arch_dir)"/*.*; do [ -f "$_acf" ] && _acn=$((_acn + 1)); done
	echo "$_acn"
}

_arch_del_index() {   # $1 - архивный номер
	rm -f "$(_arch_dir)/$1".* 2>/dev/null
}

# Удаление по ЖИВОМУ индексу: он про модем, а в архиве сообщение лежит под своим
# номером - находим его по ключу из того же живого списка.
_arch_del_live() {   # $1 - индекс модема, $2 - живой JSON
	_adn=$(printf '%s' "$2" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_adn" in ''|*[!0-9]*) return 0 ;; esac
	_adi=0
	while [ "$_adi" -lt "$_adn" ]; do
		_adx=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].index" 2>/dev/null)
		if [ "$_adx" = "$1" ]; then
			_ads=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].sender" 2>/dev/null)
			_adt=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].timestamp" 2>/dev/null)
			_adc=$(printf '%s' "$2" | jsonfilter -e "@.msg[$_adi].content" 2>/dev/null)
			# ОДИН файл, а не все с этим ключом: одинаковые сообщения хранятся
			# по отдельности, и удаление одного не должно уносить остальные.
			for _adf in "$(_arch_dir)"/*."$(_arch_key "$_ads" "$_adt" "$_adc")"; do
				[ -f "$_adf" ] && { rm -f "$_adf" 2>/dev/null; break; }
			done
			return 0
		fi
		_adi=$((_adi + 1))
	done
}

_arch_wipe() {
	rm -f "$(_arch_dir)"/*.* 2>/dev/null
}

_arch_live_json() {
	_sms_run 45 $(_smstool) -d "$PORT" -f '%Y-%m-%d %H:%M' -j $_STORE_ARG recv 2>/dev/null | utf8_fix
}

# ===== СЛИВ В ПАМЯТЬ РОУТЕРА =====
#
# ЗАЧЕМ. Память для входящих у модема крошечная и у некоторых её нет вовсе.
# Живой пример, с которого всё началось: Fibocom FM350 на вопрос AT+CPMS=?
# отвечает («SM»),(«SM»),(«SM») - памяти модема у него НЕТ, только SIM, и на
# карте десять слотов. Десять сообщений - и оператор просто перестаёт доставлять
# новые, пока человек не почистит ящик руками. Никакая настройка хранилища тут
# не поможет: класть больше некуда.
#
# Поэтому сообщения переносим к себе и освобождаем слоты. Архив у нас уже был
# написан ради MM-пути (файл на сообщение, дедупликация по хешу, обрезка по
# количеству) - здесь он же, только теперь ещё и с удалением из модема.
#
# ПОРЯДОК ГАРАНТИЙ - ГЛАВНОЕ В ЭТОЙ ФУНКЦИИ. Удалять из модема можно ТОЛЬКО то,
# что уже:
#   1) лежит в архиве - иначе неудачная запись (нет места, сбой) means потерю;
#   2) отдано уведомителю Telegram, если он включён. Бот помечает ключ
#      «отправитель|время» ТОЛЬКО после подтверждённой доставки: сеть у роутера
#      может лежать, и сообщение обязано дождаться следующего круга В МОДЕМЕ.
#      Технически архив бота бы и так выручил (он читает через этот же мост), но
#      полагаться на это - значит связать две независимые гарантии в узел;
#   3) обработано командами по SMS, если они включены (у них свой список
#      выполненного - см. smscmd.sh).
# Ни одно из условий не «оптимизируется»: цена ошибки - молча потерянное
# сообщение, а это худшее, что может сделать программа с SMS.
# ЖДАТЬ БОТА И КОМАНДЫ - НО НЕ ВЕЧНО (крайний срок).
#
# Условия 2 и 3 были жёсткими, и на живых роутерах это обернулось ровно тем, от
# чего слив спасает. У человека с включённым уведомителем и недоступным
# Telegram (в РФ без VPN на роутере это обычное дело) бот НИКОГДА не
# подтверждает доставку - значит из модема не удаляется НИ ОДНО сообщение:
# галочка «хранить в памяти роутера» стоит, архив полон, а ящик модема всё
# равно забивается до отказа и оператор перестаёт доставлять. То же самое, если
# круг команд по SMS почему-либо не доходит до конца.
#
# Поэтому ждём ARCH_GRACE_MIN минут с того момента, как сообщение легло в архив
# (возраст файла), и дальше удаляем из модема независимо от бота и команд.
# Гарантия при этом НЕ теряется: при включённом архиве источник правды - он, а
# не модем (recv отдаёт архив), и бот с командами читают через этот же мост, то
# есть увидят сообщение и после того, как оно ушло из памяти модема.
ARCH_GRACE_MIN=60

# Диагностика «почему сообщение до сих пор в модеме»: при _AP_WHY=1 функция
# ничего не удаляет, а печатает построчно «индекс<TAB>причина» (верб archive-why).
_AP_WHY=""
_ap_why() {   # $1 - индекс, $2 - причина
	[ -n "$_AP_WHY" ] || return 0
	printf '%s\t%s\n' "$1" "$2"
}

_arch_purge() {   # $1 - живой JSON от sms_tool
	if [ "$(uci -q get "$CFG.sms.archive_purge")" = "0" ]; then
		_ap_why '-' "освобождение слотов выключено настройкой"
		return 0
	fi
	_apd=$(_arch_dir)
	[ -d "$_apd" ] || return 0
	_apn=$(printf '%s' "$1" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	case "$_apn" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_apn" -gt 0 ] || return 0

	_ap_tg=$(uci -q get "$CFG.sms.tg_enabled")
	_ap_cmd=$(uci -q get "$CFG.sms.cmd_enabled")
	_ap_sf=$(_seen_file)
	_ap_df=$(sms_cmd_done_file "$_TGT_PATH")

	_ap_i=0; _ap_del=0; _ap_stuck=0; _ap_late_n=0; _ap_kb=0
	while [ "$_ap_i" -lt "$_apn" ]; do
		_ap_x=$(printf '%s' "$1" | jsonfilter -e "@.msg[$_ap_i].index" 2>/dev/null)
		_ap_s=$(printf '%s' "$1" | jsonfilter -e "@.msg[$_ap_i].sender" 2>/dev/null)
		_ap_t=$(printf '%s' "$1" | jsonfilter -e "@.msg[$_ap_i].timestamp" 2>/dev/null)
		_ap_c=$(printf '%s' "$1" | jsonfilter -e "@.msg[$_ap_i].content" 2>/dev/null)
		_ap_i=$((_ap_i + 1))
		case "$_ap_x" in ''|*[!0-9]*) continue ;; esac
		# Номер из диапазона архива - сообщения в модеме уже нет, удалять нечего.
		[ "$_ap_x" -ge "$ARCH_BASE" ] 2>/dev/null && continue
		# Пустая запись = sms_tool не разобрал PDU. В архив она не попала (см.
		# _arch_merge), и удалять её отсюда НЕЛЬЗЯ: мы бы уничтожили сообщение,
		# которого никогда не видели.
		if [ -z "$_ap_s$_ap_c" ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "PDU не разобран - в архив не попало"
			continue
		fi

		# 1) в архиве?
		_ap_k=$(_arch_key "$_ap_s" "$_ap_t" "$_ap_c")
		_ap_have=""
		for _apf in "$_apd"/*."$_ap_k"; do [ -f "$_apf" ] && { _ap_have="$_apf"; break; }; done
		if [ -z "$_ap_have" ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "ещё не в архиве"
			continue
		fi

		# Пролежало в архиве дольше крайнего срока - ждать больше нечего.
		_ap_late=0
		[ -n "$(find "$_ap_have" -mmin +"$ARCH_GRACE_MIN" 2>/dev/null)" ] && _ap_late=1

		# 2) бот уже доставил?
		_ap_wait=0
		if [ "$_ap_tg" = "1" ] && [ "$_ap_late" = 0 ]; then
			if [ "$_ap_kb" = 0 ]; then
				_kb_n=0
				_kb_feed_arch
				_kb_build
				_tg_migrate
				_kb_list_load "$(_tg_file)"
				_ap_kb=1
			fi
			_ap_fn=${_ap_have##*/}; _ap_fn=${_ap_fn%%.*}
			_ap_kn=""
			case "$_ap_fn" in ''|*[!0-9]*) ;; *) eval "_ap_kn=\$_kb_ix$_ap_fn" ;; esac
			{ [ -n "$_ap_kn" ] && _kb_known "$_ap_kn"; } || _ap_wait=1
		fi
		if [ "$_ap_wait" = 1 ]; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "ждём отправки в Telegram (крайний срок ${ARCH_GRACE_MIN} мин)"
			continue
		fi

		# 3) команды по SMS уже отработали? Ключ тот же, что у smscmd.sh.
		if [ "$_ap_cmd" = "1" ] && [ "$_ap_late" = 0 ] \
		   && ! grep -qxF "$(sms_cmd_key "$_ap_s" "$_ap_t" "$_ap_c")" "$_ap_df" 2>/dev/null; then
			_ap_stuck=$((_ap_stuck + 1))
			_ap_why "$_ap_x" "ждём круга команд по SMS (крайний срок ${ARCH_GRACE_MIN} мин)"
			continue
		fi

		[ "$_ap_late" = 1 ] && _ap_late_n=$((_ap_late_n + 1))
		if [ -n "$_AP_WHY" ]; then
			_ap_why "$_ap_x" "готово к удалению"
			continue
		fi
		# У MM-пути цель задаётся путём, а не портом: mmcli адресуется по индексу
		# модема (см. sms_tool_mm), и без этого удаление ушло бы в активный.
		MM_MODEM_PATH="$_TGT_PATH" _sms_run 12 $(_smstool) -d "$PORT" delete "$_ap_x" >/dev/null 2>&1 \
			&& _ap_del=$((_ap_del + 1))
	done
	[ -n "$_AP_WHY" ] && return 0
	if [ "$_ap_del" -gt 0 ]; then
		logger -t 5gmodem "sms: в память роутера перенесено и удалено из модема сообщений: $_ap_del"
		[ "$_ap_late_n" -gt 0 ] && logger -t 5gmodem \
			"sms: из них по крайнему сроку (бот или команды так и не отчитались): $_ap_late_n"
	fi
	# ЗАСТРЯВШИЕ - В ЛОГ, НО НЕ КАЖДЫЕ ПОЛМИНУТЫ. Сообщения, которые слив не
	# может убрать, - единственный симптом, по которому человек поймёт, почему
	# ящик всё-таки заполняется; молчать о них нельзя, но и круг сторожа
	# засорять незачем. Раз в час, с подсказкой, где смотреть подробности.
	if [ "$_ap_stuck" -gt 0 ]; then
		_ap_mk=/tmp/5gmodem_arch_stuck.stamp
		_ap_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
		_ap_prev=$(cat "$_ap_mk" 2>/dev/null)
		case "$_ap_prev" in ''|*[!0-9]*) _ap_prev=0 ;; esac
		if [ "$((_ap_now - _ap_prev))" -ge 3600 ]; then
			printf '%s' "$_ap_now" > "$_ap_mk" 2>/dev/null
			logger -t 5gmodem "sms: в модеме осталось сообщений, которые пока нельзя удалить: $_ap_stuck (почему - smsbridge.sh archive-why)"
		fi
	fi
	return 0
}

# ХРАНИЛИЩЕ ДОКЛАДЫВАЕМ МОДЕМУ РАЗ ЗА ЗАГРУЗКУ - ЗДЕСЬ, А НЕ ТОЛЬКО ПРИ
# ПЕРЕВЫБОРЕ МОДЕМА. Причин две, и обе живые:
#
#   1. +CPMS у многих модемов не переживает своего же сброса, а set_sms_storage
#      зовётся лишь из resolve/autosetup - между ними mem3 успевает вернуться к
#      заводскому, и входящие снова уходят мимо читаемого ящика.
#   2. У тех, кому 2.4.38 уже записал в настройку недостижимое хранилище, оно
#      так и осталось бы до следующего перевыбора модема: ящик пустой, а
#      сообщения на SIM (жалоба 30.08.2026).
#
# Стоит ПОД замком порта, платит двумя AT-обменами один раз за загрузку, и
# правит настройку по факту - страница читает оттуда, куда модем реально кладёт.
case "$BOX" in
recv|unseen|sent|status|dump|archive-run|archive-why)
	# ТОЛЬКО ДЛЯ АКТИВНОГО МОДЕМА. Ключ storage - ОДИН на конфиг, а бот обходит
	# ВСЕ модемы (SMS_MODEM=<путь>): без этой проверки круг бота по соседнему
	# модему переписал бы настройку активного его хранилищем.
	if ! _via_mm && [ "$_TGT_PATH" = "$(uci -q get "$CFG.@5gmodem[0].active_modem")" ]; then
		_cs_mark="/tmp/5gmodem_cpms_$(printf '%s' "$PORT" | tr -c 'A-Za-z0-9' '_')"
		# Отметка ставится ПО УСПЕХУ, а не по факту попытки: порт мог быть занят
		# опросом метрик, и «сходили один раз» означало бы промолчать до
		# перезагрузки. Но и вечно долбиться нельзя - молчащий модем стоил бы
		# по AT-таймауту каждому кругу бота, поэтому попыток три.
		_cs_st=$(cat "$_cs_mark" 2>/dev/null)
		if [ "$_cs_st" != ok ] && [ "${#_cs_st}" -lt 3 ]; then
			if set_sms_storage "$PORT" 2>/dev/null; then
				printf 'ok' > "$_cs_mark"
				# Настройку могли поправить под факт - читаем ту, что вышла.
				_cs_eff=$(uci -q get "$CFG.sms.storage")
				[ -n "$_cs_eff" ] && [ -n "$STORE" ] && STORE="$_cs_eff"
			else
				printf '.' >> "$_cs_mark"
			fi
		fi
	fi ;;
esac

# КЛЮЧ `-s` СБРАСЫВАЕТ mem3 - ИМЕННО ЭТИМ ЯЩИК И ПУСТЕЛ.
# sms_tool -s XX шлёт КОРОТКУЮ форму AT+CPMS="XX", а FM350-GL на неё возвращает
# mem2/mem3 к заводскому SM: было ME|ME|ME - стало ME|SM|SM (проверено на живом
# модеме 31.08.2026, сразу после команды). То есть каждое открытие «Входящих»
# своими руками уводило ПРИЁМ обратно на SIM, а читали мы память модема - и
# пользователь видел пустой список при пришедшей SMS.
# Поэтому хранилище выбираем ПОЛНОЙ формой (sms_apply_cpms, все три слота), а
# sms_tool зовём БЕЗ -s: он и так читает текущий mem1. Короткую форму оставляем
# только там, где полную применить не вышло - хуже, чем сегодня, не станет.
_STORE_ARG=""
_store_pick() {
	_STORE_ARG=""
	[ -n "$STORE" ] || return 0
	_STORE_ARG="-s $STORE"
	if ! _via_mm && [ -c "$PORT" ]; then
		case "$(sms_cpms_state "$PORT" 2>/dev/null)" in
			"$STORE|"*) _STORE_ARG="" ;;
			?*) sms_apply_cpms "$PORT" "$STORE" >/dev/null 2>&1 && _STORE_ARG="" ;;
		esac
	fi
}
[ "$BOX" = delete-run ] || _store_pick

set -- -d "$PORT" -f '%Y-%m-%d %H:%M' -j
[ -n "$_STORE_ARG" ] && set -- $_STORE_ARG "$@"
case "$BOX" in
	status)
		if _arch_on; then
			_arch_merge "$(_arch_live_json)"
			# СЧИТАЕМ АРХИВ, А НЕ МОДЕМ. При включённом сливе модем почти всегда
			# пуст - «used: 0 из 10» было бы правдой про железку и враньём про
			# ящик, в котором человек читает переписку.
			# Формат и ширина префикса важны: страница вырезает счётчик как
			# substring(17, indexOf("total")), а «Storage type: MT,» - ровно 17,
			# поэтому метка хранилища тут всегда двухбуквенная.
			_st_l="MT"
			_via_mm || { _st_l=${STORE:-SM}; _st_l=$(printf '%.2s' "$_st_l"); }
			printf 'Storage type: %s, used: %d, total: %d\n' \
				"$_st_l" "$(_arch_count)" "$ARCH_MAX" | tee "$_ST_CACHE.tmp"
			mv "$_ST_CACHE.tmp" "$_ST_CACHE" 2>/dev/null
			exit 0
		fi
		_st_out=$(_sms_run 20 $(_smstool) -d "$PORT" $_STORE_ARG status); _st_rc=$?
		case "$_st_out" in
			*used:*) printf '%s\n' "$_st_out" > "$_ST_CACHE.tmp" && mv "$_ST_CACHE.tmp" "$_ST_CACHE" 2>/dev/null ;;
		esac
		[ -n "$_st_out" ] && printf '%s\n' "$_st_out"
		exit $_st_rc ;;
	# КРУГ СЛИВА. Зовётся из sessionwatch ПОСЛЕ уведомителя и команд - только
	# тогда выполнены условия, при которых сообщение разрешено убирать из модема
	# (см. _arch_purge). Отдельным глаголом, а не «заодно при чтении»: удаление
	# не должно случаться от того, что кто-то открыл страницу.
	archive-run)
		_arch_on || { echo '{"result":"off"}'; exit 0; }
		# У MM-ПУТИ СЛИВ ТОЖЕ НУЖЕН. Считалось, что удалять там нечего:
		# сообщения живут в памяти ModemManager. Но приходят они в то же
		# физическое хранилище (чаще всего на SIM), MM их оттуда читает и НЕ
		# убирает - карта заполняется, и оператор перестаёт доставлять ровно
		# так же, как без ModemManager. mmcli умеет удалять (sms_tool_mm delete),
		# поэтому единственное отличие MM-пути остаётся такое: архив там
		# включён всегда, а вот освобождать хранилище можно только по ЯВНОЙ
		# галочке человека - у него архива никто не спрашивал.
		if _via_mm && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; then
			echo '{"result":"mm"}'; exit 0
		fi
		_ar_j=$(_arch_live_json)
		_arch_merge "$_ar_j"
		_arch_purge "$_ar_j"
		echo '{"result":"ok"}'
		exit 0 ;;
	# ПОЧЕМУ СООБЩЕНИЯ ВСЁ ЕЩЁ В МОДЕМЕ. Диагностика для случая «галочка стоит,
	# а ящик заполняется»: печатает состояние слива и построчно - что мешает
	# каждому сообщению. Ничего не меняет и ничего не удаляет.
	archive-why)
		echo "модем:        ${_TGT_PATH:-?}"
		echo "порт:         ${PORT:-?}"
		echo "хранилище:    ${STORE:-$(uci -q get "$CFG.sms.storage")}"
		echo "через MM:     $(_via_mm && echo да || echo нет)"
		echo "архив:        $(_arch_on && echo включён || echo выключен)"
		echo "слив слотов:  $([ "$(uci -q get "$CFG.sms.archive_purge")" = "0" ] && echo выключен || echo включён)"
		echo "Telegram:     $([ "$(uci -q get "$CFG.sms.tg_enabled")" = "1" ] && echo включён || echo выключен)"
		echo "команды SMS:  $([ "$(uci -q get "$CFG.sms.cmd_enabled")" = "1" ] && echo включены || echo выключены)"
		if ! _arch_on; then
			echo
			echo "Архив выключен - сообщения остаются в модеме. Настройки -> SMS -> «Хранить сообщения в памяти роутера»."
			exit 0
		fi
		if _via_mm && [ "$(uci -q get "$CFG.sms.archive")" != "1" ]; then
			echo
			echo "Модем работает через ModemManager, а галочка «Хранить сообщения в памяти роутера» не стоит: слоты не освобождаются."
			exit 0
		fi
		_aw_j=$(_arch_live_json)
		echo "в архиве:     $(_arch_count)"
		echo "в модеме:     $(printf '%s' "$_aw_j" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)"
		echo
		_arch_merge "$_aw_j"
		_AP_WHY=1
		_arch_purge "$_aw_j"
		exit 0 ;;
	sent)   _sms_run 45 $(_smstool) "$@" recv SR | utf8_fix; exit $? ;;
	# delete <index|all> - индекс проверяем здесь: наружу уходит уже
	# безопасное значение, а страница не решает, что можно слать в модем.
	delete)
		case "$DEL" in
			all)
				_arch_on && _arch_wipe
				# У части модемов «delete all» виснет (L850/XMM) - тогда
				# добиваем ПОШТУЧНО по индексам из списка, каждый шаг с
				# собственным потолком.
				_sms_run 40 $(_smstool) -d "$PORT" delete all
				for _dl_i in $(_sms_run 45 $(_smstool) "$@" recv \
						| jsonfilter -e '@.msg[*].index' 2>/dev/null); do
					case "$_dl_i" in ''|*[!0-9]*) continue ;; esac
					_sms_run 12 $(_smstool) -d "$PORT" delete "$_dl_i"
				done
				exit 0 ;;
			''|*[!0-9]*) echo "bad index" >&2; exit 2 ;;
			*)
				if _arch_on; then
					# Номер от ARCH_BASE - сообщения в модеме уже нет, удалять
					# нечего и негде, кроме архива.
					if [ "$DEL" -ge "$ARCH_BASE" ]; then
						_arch_del_index "$DEL"
						echo "delete msg from $DEL to $DEL"
						exit 0
					fi
					_arch_del_live "$DEL" "$(_arch_live_json)"
				fi
				_sms_run 15 $(_smstool) -d "$PORT" delete "$DEL"; exit $? ;;
		esac ;;
	delete-run)
		_dr_live=""
		for _dr_i in $(printf '%s' "$DEL" | tr ',' ' '); do
			if [ "$_dr_i" -ge "$ARCH_BASE" ]; then
				_arch_del_index "$_dr_i"
				_dr_left=""
				for _dr_f in "$(_arch_dir)/$_dr_i".*; do [ -f "$_dr_f" ] && _dr_left=1; done
				if [ -n "$_dr_left" ]; then _dj_fail "$_dr_i" archive ""; else _dj_ok "$_dr_i"; fi
				_dj_write running
			else
				_dr_live="$_dr_live $_dr_i"
			fi
		done
		[ -n "$_dr_live" ] || { _dj_write done; exit 0; }
		_dr_why=""
		if [ -z "$PORT" ]; then
			_dr_why=noport
		else
			_dr_try=0
			while [ "$_AT_LOCKED" != 0 ] && [ "$_dr_try" -lt 3 ]; do
				at_lock "$PORT" 15; _AT_LOCKED=$?
				_dr_try=$((_dr_try + 1))
			done
			[ "$_AT_LOCKED" = 0 ] || _dr_why=busy
		fi
		if [ -n "$_dr_why" ]; then
			for _dr_i in $_dr_live; do _dj_fail "$_dr_i" "$_dr_why" ""; done
			_dj_write done
			exit 0
		fi
		_store_pick
		_dr_before=$(_arch_live_json)
		_dr_pend=""; _dr_hang=0; _dr_base=$_DJ_DONE
		for _dr_i in $_dr_live; do
			if [ "$_dr_hang" -ge 3 ]; then
				_dr_pend="$_dr_pend $_dr_i:noanswer:"
				continue
			fi
			_dr_o=$(MM_MODEM_PATH="$_TGT_PATH" _sms_run 12 $(_smstool) -d "$PORT" delete "$_dr_i"); _dr_rc=$?
			case "$_dr_o" in
				*"Deleted message $_dr_i"*) _dr_pend="$_dr_pend $_dr_i:ok:"; _dr_hang=0 ;;
				*"Error deleting message $_dr_i"*)
					_dr_a=$(printf '%s' "$_dr_o" | sed -n "s/.*Error deleting message $_dr_i: *\\([0-9A-Za-z ]*\\).*/\\1/p" | head -1 | tr -d '\r')
					_dr_pend="$_dr_pend $_dr_i:refused:$(printf '%s' "$_dr_a" | tr ' ' '_')"; _dr_hang=0 ;;
				*)
					if [ "$_dr_rc" = 0 ]; then _dr_pend="$_dr_pend $_dr_i:ok:"; _dr_hang=0
					else _dr_pend="$_dr_pend $_dr_i:noanswer:"; _dr_hang=$((_dr_hang + 1))
					fi ;;
			esac
			_DJ_DONE=$((_DJ_DONE + 1)); _dj_write running
		done
		_dr_after=$(_arch_live_json)
		_dr_seen=""
		case "$_dr_after" in
			*'"msg"'*) _dr_seen=1
				_dr_left=" $(printf '%s' "$_dr_after" | jsonfilter -e '@.msg[*].index' 2>/dev/null | tr '\n' ' ')" ;;
		esac
		_DJ_DONE=$_dr_base
		for _dr_p in $_dr_pend; do
			_dr_i=${_dr_p%%:*}; _dr_v=${_dr_p#*:}; _dr_a=${_dr_v#*:}; _dr_v=${_dr_v%%:*}
			if [ -n "$_dr_seen" ]; then
				case "$_dr_left" in
					*" $_dr_i "*)
						_dr_b=$(printf '%s' "$_dr_before" | jsonfilter -e "@.msg[@.index=$_dr_i].timestamp" 2>/dev/null | head -1)
						_dr_c=$(printf '%s' "$_dr_after" | jsonfilter -e "@.msg[@.index=$_dr_i].timestamp" 2>/dev/null | head -1)
						if [ "$_dr_b" = "$_dr_c" ]; then
							[ "$_dr_v" = ok ] && _dr_v=refused
						else
							_dr_v=ok
						fi ;;
					*) _dr_v=ok ;;
				esac
			fi
			if [ "$_dr_v" = ok ]; then
				_arch_on && _arch_del_live "$_dr_i" "$_dr_before"
				_dj_ok "$_dr_i"
			else
				_dj_fail "$_dr_i" "$_dr_v" "$_dr_a"
			fi
		done
		_dj_write done
		exit 0 ;;
	send)
		[ -n "$SND_TO" ] || { echo "no number" >&2; exit 2; }
		SND_TO=$(_norm_num "$SND_TO")
		# ОЧЕРЕДЬ К ПОРТУ ОБЯЗАТЕЛЬНА ИМЕННО ЗДЕСЬ. Общий at_lock выше при
		# неудаче пропускает вперёд (для чтения это верно: лучше рискнуть
		# смешением, чем не показать сообщения). Для ОТПРАВКИ наоборот: лезть в
		# порт поверх чужого обмена - это потерянное приглашение «>» и мусор в
		# эфире. Не дождались - кладём в очередь, следующий круг отправит.
		# Смотрим на КОД ВОЗВРАТА замка, а не на _AT_LOCK_HELD: при таймауте
		# флаг пуст, и гард молчал ровно тогда, когда был нужен (аудит 12.09.2026).
		if [ "$_AT_LOCKED" != 0 ] || \
			{ [ -n "$_AT_LOCK_HELD" ] && [ "$_AT_LOCK_HELD" != "$(basename "$PORT")" ]; }; then
			if _q_enqueue "$SND_TO" "$SND_TXT" "$PORT"; then
				echo "sms queued: порт сейчас занят, отправлю при первой возможности"
				exit 0
			fi
		fi
		# КОДИРОВКА - ИЗВЕСТНОЕ ОГРАНИЧЕНИЕ sms_tool. Модем в PDU-режиме
		# (AT+CMGF=0), кодировку выбирает сам инструмент и на кириллице ставит
		# GSM-7, где её нет - до адресата доходят «?????». Баг воспроизводится и
		# прямым вызовом из консоли, БЕЗ нашего приложения, и флаг «-c 2» его не
		# лечит (для send он не действует).
		# Поэтому текст вне GSM-7 отправляем СВОИМ PDU (UCS2), а латиницу
		# оставляем инструменту - его путь проверен годами.
		# МОДЕМ ПОД ModemManager - СВОЙ PDU ЕМУ НЕ ПОДХОДИТ.
		#
		# У такого модема AT-портом распоряжается MM, и приглашение «>» после
		# AT+CMGS перехватывает он: наш обмен просто не состоится (живой отказ
		# пользователя на Compal - «модем не дал приглашение»). Зато MM сам умеет
		# выбирать кодировку, в том числе UCS2, - значит кириллицу ему можно
		# отдавать как есть, через sms_tool_mm. Флаг sms_via_mm тут не спрашиваем:
		# он про предпочтение пользователя, а это про физическую невозможность.
		# Строку успеха печатает ТОТ, КТО ОТПРАВИЛ: sms_tool и мост MM выводят
		# свою («sms sent sucessfully: 14»), наш PDU-путь молчит. Без этой сверки
		# на странице появлялись ДВЕ строки подряд.
		_snd_out=$(_send_one "$PORT" "$SND_TO" "$SND_TXT" 2>/dev/null)
		if [ $? = 0 ]; then
			case "$_snd_out" in
				*sucessfully*) printf '%s\n' "$_snd_out" ;;
				*) echo "sms sent sucessfully" ;;
			esac
			exit 0
		fi
		# НЕ ТЕРЯЕМ СООБЩЕНИЕ: отказ мог быть от занятого порта или временной
		# ошибки сети - следующий круг сторожа попробует снова.
		if _q_enqueue "$SND_TO" "$SND_TXT" "$PORT"; then
			echo "sms queued: не удалось отправить сейчас, отправлю при первой возможности"
			exit 0
		fi
		echo "sms sending failed"
		exit 1 ;;
	queue-run)
		# Круг досылки: зовётся из цикла sessionwatch. Одно сообщение за круг -
		# порт нужен и метрикам, а очередь не горит.
		[ -d "$SMSQ_DIR" ] || exit 0
		for _qr_f in "$SMSQ_DIR"/*.sms; do
			[ -f "$_qr_f" ] || continue
			_q_send_one "$_qr_f"
			break
		done
		exit 0 ;;
	queue-list)
		# Для страницы: что ещё не ушло.
		printf '{"queued":['
		_ql_n=0
		for _ql_f in "$SMSQ_DIR"/*.sms; do
			[ -f "$_ql_f" ] || continue
			_ql_to=$(sed -n 's/^to=//p' "$_ql_f" | head -1)
			_ql_tr=$(sed -n 's/^tries=//p' "$_ql_f" | head -1)
			[ "$_ql_n" = 0 ] || printf ','
			printf '{"to":"%s","tries":%s}' "$_ql_to" "${_ql_tr:-0}"
			_ql_n=$((_ql_n + 1))
		done
		printf ']}\n'
		exit 0 ;;
	# ТЕКСТОМ, а не JSON. Нужно кнопке «сохранить сообщения в файл»: она пишет
	# человекочитаемый .txt, и JSON там не к месту. Раньше страница ради этого
	# исполняла БИНАРЬ sms_tool напрямую (в ACL был разрешён exec на него), то есть
	# из браузера уходили любые аргументы. Теперь формат выбирается здесь.
	# ВЫХОД С ТЕКСТОМ СООБЩЕНИЙ ЧИНИМ ПО КОДИРОВКЕ - ОДИН РАЗ, ЗДЕСЬ.
	#
	# sms_tool отдаёт U+00A0 и ёлочки одним байтом (latin1). Раньше это чинил
	# только бот перед отправкой в Telegram, а страница «Входящие» показывала на
	# их месте ромбы. Мост - единственный вход к сообщениям для ВСЕХ (страница,
	# бот, выгрузка в файл), поэтому починка живёт тут. utf8_fix идемпотентна:
	# валидный UTF-8 через неё проходит без изменений.
	dump)
		if _arch_on; then
			_arch_merge "$(_arch_live_json)"
			_arch_text
			exit 0
		fi
		_sms_run 45 $(_smstool) -d "$PORT" -f '%Y-%m-%d %H:%M' $_STORE_ARG recv | utf8_fix; exit $? ;;
	*)
		if _arch_on; then
			_arch_merge "$(_arch_live_json)"
			if [ "$BOX" = unseen ]; then
				[ -n "$_AT_INH" ] || at_unlock
				_kb_feed_arch
				_kb_build
				if [ "$UL" = tg ]; then _tg_migrate; _kb_unseen "$(_tg_file)"; else _kb_unseen "$(_seen_file)"; fi
				exit 0
			fi
			_arch_json
			exit 0
		fi
		_rv_j=$(_sms_run 45 $(_smstool) "$@" recv | utf8_fix)
		[ -n "$_AT_INH" ] || at_unlock
		_kb_out "$_rv_j"
		exit 0 ;;
esac
