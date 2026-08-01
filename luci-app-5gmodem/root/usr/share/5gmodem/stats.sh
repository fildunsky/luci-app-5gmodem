#!/bin/sh
#
# Сбор исторических рядов для вкладки «Статистика».
#
# ЧТО СОБИРАЕМ
#   ping   - RTT каждого аплинка. Источник бесплатный: сторож (health.sh) и так
#            меряет его каждый круг и кладёт в /tmp/5gmodem_health/<iface>
#            (поле ms). Своих проб НЕ делаем - лишний трафик и лишние процессы.
#   signal - уровень сигнала активного модема из последнего снимка метрик
#            (rsrp, иначе rssi) - тоже готовое, без похода в порт.
#   traffic- байты rx/tx по интерфейсам. Сырые счётчики устройства сбрасываются
#            на ребуте и при пересоздании интерфейса, поэтому копим ДЕЛЬТЫ в
#            месячный аккумулятор: <год-месяц> -> rx tx.
#
# ГДЕ ХРАНИМ
#   /tmp/5gmodem_stats/       - кольцевые ряды (RAM, быстро, не жжёт флеш)
#   /etc/5gmodem/stats/       - только при persist=1: месячные итоги трафика и
#                               прореженные ряды. Пишем РЕДКО (см. flush).
#
# ФОРМАТ РЯДА - одна строка на точку: "<uptime_s> <значение>". Ряд обрезается по
# RING_MAX точкам; при шаге 60 c это ~24 часа на метрику.

RES=/usr/share/5gmodem
CFG=5gmodem
DIR=/tmp/5gmodem_stats
PDIR=/etc/5gmodem/stats
RING_MAX=1440
FLUSH_EVERY=3600

. "$RES/lib.sh" 2>/dev/null

_cfg() { uci -q get "$CFG.stats.$1" 2>/dev/null; }
# Сбор привязан к ВИДИМОСТИ ВКЛАДКИ: отдельная галочка «собирать» на странице
#только путала - вкладка есть, а данных нет. Ключ один: show_stats (Настройки).
_enabled() { [ "$(uci -q get "$CFG.@5gmodem[0].show_stats" 2>/dev/null)" != "0" ]; }
_persist() { [ "$(_cfg persist)" = "1" ]; }

_now() { uptime_s 2>/dev/null || cut -d. -f1 /proc/uptime; }
json_esc_s() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# Подпись ряда для UI (человеческая). $1 - имя ряда, $2 - подпись.
_label() { [ -n "$2" ] && printf '%s\n' "$2" > "$DIR/$1.label"; }
_month() { date '+%Y-%m'; }

# Добавить точку в ряд с кольцевой обрезкой. $1 - имя ряда, $2 - значение.
_push() {
	[ -n "$2" ] || return 0
	case "$2" in *[!0-9.-]*) return 0 ;; esac
	_p_f="$DIR/$1"
	printf '%s %s\n' "$(_now)" "$2" >> "$_p_f"
	_p_n=$(wc -l < "$_p_f" 2>/dev/null || echo 0)
	if [ "${_p_n:-0}" -gt "$((RING_MAX + 120))" ]; then
		tail -n "$RING_MAX" "$_p_f" > "$_p_f.tmp" 2>/dev/null && mv "$_p_f.tmp" "$_p_f"
	fi
}

# Человеческое имя аплинка: модель модема, имя Wi-Fi-сети или сам интерфейс.
# Берём из netpri list - он это уже считает для карточек (sub/label).
_iface_label() {
	[ -n "$_NP_SNAP" ] || _NP_SNAP=$("$RES/netpri.sh" list 2>/dev/null)
	_il_s=$(printf '%s' "$_NP_SNAP" | jsonfilter -e "@[@.iface=\"$1\"].sub" 2>/dev/null | head -1)
	_il_t=$(printf '%s' "$_NP_SNAP" | jsonfilter -e "@[@.iface=\"$1\"].type" 2>/dev/null | head -1)
	case "$_il_t" in
		wifi) [ -n "$_il_s" ] && printf 'Wi-Fi %s' "$_il_s" || printf 'Wi-Fi' ;;
		*)    [ -n "$_il_s" ] && printf '%s' "$_il_s" || printf '%s' "$1" ;;
	esac
}

# Ряды пингов - из состояния сторожа: "state fails oks ms since".
_collect_ping() {
	for _cp_f in /tmp/5gmodem_health/*; do
		[ -f "$_cp_f" ] || continue
		case "$_cp_f" in */.t|*.heal|*.demoted|*.nosim|*.last_event) continue ;; esac
		_cp_if="${_cp_f##*/}"
		read -r _cp_st _ _ _cp_ms _ < "$_cp_f" 2>/dev/null || continue
		# «down» пишем нулём: разрыв в графике должен быть виден, а не сглажен
		[ "$_cp_st" = up ] || _cp_ms=0
		_push "ping.$_cp_if" "${_cp_ms:-0}"
		[ -f "$DIR/ping.$_cp_if.label" ] || _label "ping.$_cp_if" "$(_iface_label "$_cp_if")"
	done
}

# Уровень сигнала активного модема из последнего снимка (без похода в порт).
_collect_signal() {
	# ВСЕ модемы, а не только активный: ряд соседа копится из его снимка
	# (подогрев sessionwatch их обновляет), иначе на графике одна линия и
	# сравнить нечего. Имя ряда - МОДЕЛЬ модема, а не ключ снимка: «2_1_4_»
	# в легенде ни о чём не говорит.
	for _cs_p in $("$RES/registry.sh" paths 2>/dev/null); do
		[ -n "$_cs_p" ] || continue
		_cs_j=$("$RES/5gmodem.sh" peek "$_cs_p" 2>/dev/null)
		[ -n "$_cs_j" ] || continue
		_cs_v=$(printf '%s' "$_cs_j" | jsonfilter -e '@.rsrp' 2>/dev/null)
		case "$_cs_v" in ''|-) _cs_v=$(printf '%s' "$_cs_j" | jsonfilter -e '@.rssi' 2>/dev/null) ;; esac
		case "$_cs_v" in ''|-) continue ;; esac
		_cs_n=$(uci -q get "$CFG.m_$(echo "$_cs_p" | sed 's/[^A-Za-z0-9]/_/g').model" 2>/dev/null)
		[ -n "$_cs_n" ] || _cs_n="$_cs_p"
		_cs_k=$(printf '%s' "$_cs_n" | sed 's/[^A-Za-z0-9]/_/g')
		_push "signal.$_cs_k" "$_cs_v"
		[ -f "$DIR/signal.$_cs_k.label" ] || _label "signal.$_cs_k" "$_cs_n"
		# Температура - из того же снимка (поле temp, «45 C» -> 45). Отдают не
		# все модули (у L850/XMM датчика нет вовсе) - тогда ряда просто не будет.
		# Поле называется mtemp (temp в снимке НЕТ), значение приходит с
		# HTML-мнемоникой: «38 &deg;C» - берём ведущее число.
		_cs_t=$(printf '%s' "$_cs_j" | jsonfilter -e '@.mtemp' 2>/dev/null \
			| sed -n 's/^ *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -1)
		if [ -n "$_cs_t" ]; then
			_push "temp.$_cs_k" "$_cs_t"
			[ -f "$DIR/temp.$_cs_k.label" ] || _label "temp.$_cs_k" "$_cs_n"
		fi
	done
}

# Трафик: дельты счётчиков устройства -> месячный аккумулятор по интерфейсу.
# Счётчик уехал вниз (ребут/пересоздание) - дельту не берём, просто
# перезапоминаем базу: иначе месяц получил бы отрицательное или гигантское число.
_collect_traffic() {
	for _ct_if in $("$RES/netpri.sh" list 2>/dev/null | jsonfilter -e '@[*].iface' 2>/dev/null); do
		[ -n "$_ct_if" ] || continue
		_ct_dev=$(ubus call network.interface."$_ct_if" status 2>/dev/null \
			| jsonfilter -e '@.l3_device' 2>/dev/null)
		[ -n "$_ct_dev" ] && [ -d "/sys/class/net/$_ct_dev" ] || continue
		_ct_rx=$(cat "/sys/class/net/$_ct_dev/statistics/rx_bytes" 2>/dev/null)
		_ct_tx=$(cat "/sys/class/net/$_ct_dev/statistics/tx_bytes" 2>/dev/null)
		case "$_ct_rx$_ct_tx" in ''|*[!0-9]*) continue ;; esac
		_ct_base="$DIR/base.$_ct_if"
		_ct_prx=0; _ct_ptx=0
		[ -f "$_ct_base" ] && read -r _ct_prx _ct_ptx < "$_ct_base" 2>/dev/null
		case "$_ct_prx" in ''|*[!0-9]*) _ct_prx=0 ;; esac
		case "$_ct_ptx" in ''|*[!0-9]*) _ct_ptx=0 ;; esac
		printf '%s %s\n' "$_ct_rx" "$_ct_tx" > "$_ct_base"
		[ "$_ct_rx" -lt "$_ct_prx" ] || [ "$_ct_tx" -lt "$_ct_ptx" ] && continue
		[ "$_ct_prx" = 0 ] && [ "$_ct_ptx" = 0 ] && continue
		_ct_drx=$((_ct_rx - _ct_prx)); _ct_dtx=$((_ct_tx - _ct_ptx))
		[ "$_ct_drx" = 0 ] && [ "$_ct_dtx" = 0 ] && continue
		_ct_acc="$DIR/traffic.$_ct_if.$(_month)"
		_ct_arx=0; _ct_atx=0
		[ -f "$_ct_acc" ] && read -r _ct_arx _ct_atx < "$_ct_acc" 2>/dev/null
		case "$_ct_arx" in ''|*[!0-9]*) _ct_arx=0 ;; esac
		case "$_ct_atx" in ''|*[!0-9]*) _ct_atx=0 ;; esac
		printf '%s %s\n' "$((_ct_arx + _ct_drx))" "$((_ct_atx + _ct_dtx))" > "$_ct_acc"
	done
}

# Сброс месячных итогов на флеш - РЕДКО и только по настройке. Ряды пингов на
# флеш не пишем никогда: они мелкие по смыслу и частые по природе.
_flush() {
	_persist || return 0
	_fl_st="$DIR/.flush"
	_fl_last=0
	[ -f "$_fl_st" ] && read -r _fl_last < "$_fl_st" 2>/dev/null
	case "$_fl_last" in ''|*[!0-9]*) _fl_last=0 ;; esac
	[ $(( $(_now) - _fl_last )) -ge "$FLUSH_EVERY" ] || return 0
	mkdir -p "$PDIR" 2>/dev/null
	for _fl_f in "$DIR"/traffic.*; do
		[ -f "$_fl_f" ] || continue
		cp "$_fl_f" "$PDIR/${_fl_f##*/}" 2>/dev/null
	done
	_now > "$_fl_st"
}

# Поднять месячные итоги с флеша после ребута (ряды в /tmp переживать не должны).
_restore() {
	[ -d "$PDIR" ] || return 0
	mkdir -p "$DIR" 2>/dev/null
	for _rs_f in "$PDIR"/traffic.*; do
		[ -f "$_rs_f" ] || continue
		[ -f "$DIR/${_rs_f##*/}" ] || cp "$_rs_f" "$DIR/${_rs_f##*/}" 2>/dev/null
	done
}

# Ряд в JSON: {"series":[[t,v],...]}. $2 - имя ряда.
_series_json() {
	_sj_f="$DIR/$1"
	printf '{"name":"%s","series":[' "$1"
	if [ -f "$_sj_f" ]; then
		_sj_n=0
		while read -r _sj_t _sj_v; do
			case "$_sj_t" in ''|*[!0-9]*) continue ;; esac
			[ "$_sj_n" = 0 ] || printf ','
			printf '[%s,%s]' "$_sj_t" "$_sj_v"
			_sj_n=$((_sj_n + 1))
		done < "$_sj_f"
	fi
	printf ']}'
}

mkdir -p "$DIR" 2>/dev/null

case "$1" in
tick)
	_enabled || exit 0
	_restore
	_collect_ping
	_collect_signal
	_collect_traffic
	_flush
	;;
list)
	# Какие ряды есть: {"ping":["modem",...],"signal":[...],"traffic":[...]}
	_ls_p=""; _ls_s=""; _ls_t=""; _ls_m=""
	for _ls_f in "$DIR"/ping.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_p="$_ls_p,\"${_ls_f##*/ping.}\""; done
	for _ls_f in "$DIR"/signal.*;  do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_s="$_ls_s,\"${_ls_f##*/signal.}\""; done
	for _ls_f in "$DIR"/traffic.*; do [ -f "$_ls_f" ] && _ls_t="$_ls_t,\"${_ls_f##*/traffic.}\""; done
	for _ls_f in "$DIR"/temp.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_m="$_ls_m,\"${_ls_f##*/temp.}\""; done
	# Человеческие подписи рядов: "<имя ряда>" -> "Compal RXM-G1" / "Wi-Fi do".
	# Пишутся сборщиком рядом с рядом (файл .label) - в имени файла дефисы и
	# пробелы недопустимы, а в легенде нужны именно они.
	_ls_l=""
	for _ls_f in "$DIR"/*.label; do
		[ -f "$_ls_f" ] || continue
		_ls_k="${_ls_f##*/}"; _ls_k="${_ls_k%.label}"
		read -r _ls_v < "$_ls_f" 2>/dev/null
		[ -n "$_ls_v" ] && _ls_l="$_ls_l,\"$_ls_k\":\"$(json_esc_s "$_ls_v")\""
	done
	printf '{"enabled":%s,"persist":%s,"ping":[%s],"signal":[%s],"traffic":[%s],"temp":[%s],"labels":{%s}}\n' \
		"$(_enabled && echo 1 || echo 0)" "$(_persist && echo 1 || echo 0)" \
		"${_ls_p#,}" "${_ls_s#,}" "${_ls_t#,}" "${_ls_m#,}" "${_ls_l#,}"
	;;
series)
	# series <имя ряда> - точки одного ряда
	[ -n "$2" ] || { echo '{"error":"no series"}'; exit 1; }
	case "$2" in *[!A-Za-z0-9._-]*) echo '{"error":"bad name"}'; exit 1 ;; esac
	_series_json "$2"
	echo
	;;
traffic)
	# Помесячные итоги по всем интерфейсам: {"modem":{"2026-07":{"rx":N,"tx":N}}}
	printf '{'
	_tr_first=1
	for _tr_f in "$DIR"/traffic.*; do
		[ -f "$_tr_f" ] || continue
		_tr_n="${_tr_f##*/traffic.}"
		_tr_if="${_tr_n%.*}"; _tr_m="${_tr_n##*.}"
		read -r _tr_rx _tr_tx < "$_tr_f" 2>/dev/null
		case "$_tr_rx" in ''|*[!0-9]*) _tr_rx=0 ;; esac
		case "$_tr_tx" in ''|*[!0-9]*) _tr_tx=0 ;; esac
		[ "$_tr_first" = 1 ] || printf ','
		_tr_first=0
		printf '"%s|%s":{"rx":%s,"tx":%s}' "$_tr_if" "$_tr_m" "$_tr_rx" "$_tr_tx"
	done
	printf '}\n'
	;;
setconf)
	shift
	uci -q get "$CFG.stats" >/dev/null 2>&1 || uci -q set "$CFG.stats=stats"
	for _sc in "$@"; do
		_sc_k="${_sc%%=*}"; _sc_v="${_sc#*=}"
		case "$_sc_k" in
			enabled|persist) uci -q set "$CFG.stats.$_sc_k=$_sc_v" ;;
		esac
	done
	uci -q commit "$CFG"
	# Выключили персист - убираем то, что уже лежит на флеше.
	_persist || rm -rf "$PDIR" 2>/dev/null
	echo '{"result":"ok"}'
	;;
reset)
	rm -rf "$DIR" "$PDIR" 2>/dev/null
	mkdir -p "$DIR" 2>/dev/null
	echo '{"result":"ok"}'
	;;
*)
	echo '{"error":"usage: stats.sh tick|list|series <name>|traffic|setconf k=v|reset"}'
	exit 1
	;;
esac
