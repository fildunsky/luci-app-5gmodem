#!/bin/sh
#
# Сбор исторических рядов для вкладки «Статистика».
#
# ЧТО СОБИРАЕМ
#   ping   - RTT каждого аплинка. Источник бесплатный: сторож (health.sh) и так
#            меряет его каждый круг и кладёт в /tmp/5gmodem_health/<iface>
#            (поле ms). Своих проб НЕ делаем - лишний трафик и лишние процессы.
#   signal - уровень сигнала модемов из последнего снимка метрик (поле signal,
#            проценты 0-100) - тоже готовое, без похода в порт.
#   traffic- байты rx/tx по интерфейсам. Сырые счётчики устройства сбрасываются
#            на ребуте и при пересоздании интерфейса, поэтому копим ДЕЛЬТЫ в
#            месячный аккумулятор: <год-месяц> -> rx tx.
#
# ГДЕ ХРАНИМ
#   /tmp/5gmodem_stats/       - кольцевые ряды (RAM, быстро, не жжёт флеш).
#                               Это ВСЕГДА рабочая копия и единственный источник
#                               правды на время работы.
#   при persist=1 - ещё и на диск, раз в час (см. flush):
#     по умолчанию /etc/5gmodem/stats/ - переживает перезагрузку и апгрейд;
#     свой путь (stats.path) - например каталог на USB-флешке.
#
# ФЛЕШКА МОЖЕТ ОТВАЛИТЬСЯ, И ЭТО НЕ ИСКЛЮЧЕНИЕ, А ШТАТНЫЙ РЕЖИМ. Проверяем не
# существование каталога, а факт МОНТИРОВАНИЯ: после выдёргивания флешки точка
# монтирования остаётся обычным каталогом на внутренней памяти, и запись «удаётся»
# - молча забивая флеш роутера. Пока свой путь недоступен, пишем в запасной
# (/etc/5gmodem/stats), а когда флешка вернётся - сливаем.
#
# СЛИЯНИЕ ТРИВИАЛЬНО И ТОЧНО. Месячные итоги - монотонные счётчики, поэтому
# «склеить» два источника = взять ПОБОЛЬШЕ по каждому месяцу. Никаких разборов
# файлов и порядка строк. Ряды графиков в слиянии не участвуют вовсе: их
# отметка времени - uptime, который обнуляется на ребуте, и склеивать их между
# загрузками бессмысленно (они и восстанавливаются только внутри одной сессии).
#
# ФОРМАТ РЯДА - одна строка на точку: "<uptime_s> <значение>". Ряд обрезается по
# RING_MAX точкам; при шаге 60 c это ~24 часа на метрику.

RES=/usr/share/5gmodem
CFG=5gmodem
DIR=/tmp/5gmodem_stats
# Запасной каталог (внутренняя память). Он же основной, пока не задан свой путь.
PDIR_DEF=/etc/5gmodem/stats
RING_MAX=1440
FLUSH_EVERY=3600

. "$RES/lib.sh" 2>/dev/null

_cfg() { uci -q get "$CFG.stats.$1" 2>/dev/null; }
# Сбор привязан к ВИДИМОСТИ ВКЛАДКИ: отдельная галочка «собирать» на странице
#только путала - вкладка есть, а данных нет. Ключ один: show_stats (Настройки).
_enabled() { [ "$(uci -q get "$CFG.@5gmodem[0].show_stats" 2>/dev/null)" != "0" ]; }
_persist() { [ "$(_cfg persist)" = "1" ]; }

# Куда просили писать (пусто - внутренняя память).
_pdir_want() { _pw=$(_cfg path); [ -n "$_pw" ] && printf '%s' "${_pw%/}" || printf '%s' "$PDIR_DEF"; }

# КАТАЛОГ ДОСТУПЕН ДЛЯ ЗАПИСИ? Для своего пути этого мало: нужно, чтобы он ЛЕЖАЛ
# НА СМОНТИРОВАННОМ носителе. Иначе после выдёргивания флешки запись пойдёт в
# каталог-пустышку на внутренней флеш-памяти, и человек узнает об этом, когда
# кончится место.
# Лежит ли каталог на отдельном смонтированном носителе (а не на корне).
_mounted() {   # $1 - каталог
	_mp="$1"
	while [ -n "$_mp" ] && [ "$_mp" != "/" ]; do
		awk -v p="$_mp" '$2 == p { found = 1 } END { exit(found ? 0 : 1) }' /proc/mounts && return 0
		_mp="${_mp%/*}"
	done
	return 1
}

_dir_live() {   # $1 - каталог, $2 - 1 если требовать монтирование
	[ -n "$1" ] || return 1
	mkdir -p "$1" 2>/dev/null || return 1
	[ "$2" = 1 ] && { _mounted "$1" || return 1; }
	# Носитель бывает смонтирован только на чтение - проверяем записью.
	: > "$1/.wtest" 2>/dev/null || return 1
	rm -f "$1/.wtest" 2>/dev/null
	return 0
}

# Куда пишем ПРЯМО СЕЙЧАС: свой путь, если он жив, иначе запасной.
_pdir_now() {
	_pn=$(_pdir_want)
	if [ "$_pn" = "$PDIR_DEF" ]; then
		_dir_live "$_pn" 0 && { printf '%s' "$_pn"; return 0; }
		return 1
	fi
	_dir_live "$_pn" 1 && { printf '%s' "$_pn"; return 0; }
	_dir_live "$PDIR_DEF" 0 && { printf '%s' "$PDIR_DEF"; return 0; }
	return 1
}

# Слить месячные итоги из каталога в /tmp по правилу «больше побеждает».
_merge_from() {   # $1 - каталог
	[ -d "$1" ] || return 0
	mkdir -p "$DIR" 2>/dev/null
	for _mf_f in "$1"/traffic.*; do
		[ -f "$_mf_f" ] || continue
		_mf_n="${_mf_f##*/}"
		_mf_rx=0; _mf_tx=0
		read -r _mf_rx _mf_tx 2>/dev/null < "$_mf_f"
		case "$_mf_rx" in ''|*[!0-9]*) _mf_rx=0 ;; esac
		case "$_mf_tx" in ''|*[!0-9]*) _mf_tx=0 ;; esac
		_mf_crx=0; _mf_ctx=0
		[ -f "$DIR/$_mf_n" ] && read -r _mf_crx _mf_ctx 2>/dev/null < "$DIR/$_mf_n"
		case "$_mf_crx" in ''|*[!0-9]*) _mf_crx=0 ;; esac
		case "$_mf_ctx" in ''|*[!0-9]*) _mf_ctx=0 ;; esac
		[ "$_mf_rx" -gt "$_mf_crx" ] || _mf_rx="$_mf_crx"
		[ "$_mf_tx" -gt "$_mf_ctx" ] || _mf_tx="$_mf_ctx"
		printf '%s %s\n' "$_mf_rx" "$_mf_tx" > "$DIR/$_mf_n"
	done
	# Подписи - «в /tmp пусто -> берём сохранённую»: свежая из живого модема
	# всегда перезапишет её обычным путём.
	for _mf_f in "$1"/*.label; do
		[ -f "$_mf_f" ] || continue
		_mf_n="${_mf_f##*/}"
		[ -f "$DIR/$_mf_n" ] || cat "$_mf_f" > "$DIR/$_mf_n" 2>/dev/null
	done
}

_now() { uptime_s 2>/dev/null || cut -d. -f1 /proc/uptime; }
json_esc_s() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
# Подпись ряда для UI (человеческая). $1 - имя ряда, $2 - подпись.
#
# ПОДПИСИ SIM-РЯДОВ - ЕЩЁ И В ПЕРСИСТ. Счётчики месяцев живут в /etc и
# переживают ребут, а подписи жили только в /tmp - и после перезагрузки ряд
# симки, которой сейчас нет ни в одном модеме, показывался сырым ключом
# «sim-8970...» (живой стенд 09.08.2026: МегаФон-карта лежала на столе).
# Пишем только при РЕАЛЬНОЙ смене значения: подписи меняются редко, а каждая
# запись в /etc - цикл флеш-памяти.
_label() {
	[ -n "$2" ] || return 0
	printf '%s\n' "$2" > "$DIR/$1.label"
	case "$1" in
		sim-*|op.sim-*)
			# ПЕРСИСТ ВЫКЛЮЧЕН - В /etc НЕ ЛЕЗЕМ ВОВСЕ. _pdir_now делает mkdir и
			# пробу записью, а _label зовётся каждый тик сбора: это был цикл
			# записи во флеш-память раз в минуту и каталог, воскресающий сразу
			# после того, как его удалил setconf (аудит 12.09.2026).
			_persist || return 0
			_lb_d=$(_pdir_now 2>/dev/null) || return 0
			if [ "$(cat "$_lb_d/$1.label" 2>/dev/null)" != "$2" ]; then
				printf '%s\n' "$2" > "$_lb_d/$1.label" 2>/dev/null
			fi ;;
	esac
}
_month() { date '+%Y-%m'; }

# Добавить точку в ряд с кольцевой обрезкой. $1 - имя ряда, $2 - значение.
_push() {
	[ -n "$2" ] || return 0
	case "$2" in *[!0-9.-]*) return 0 ;; esac
	_p_f="$DIR/$1"
	_p_t=$(_now)
	[ "$(tail -n1 "$_p_f" 2>/dev/null | cut -d' ' -f1)" = "$_p_t" ] && return 0
	printf '%s %s\n' "$_p_t" "$2" >> "$_p_f"
	_p_n=$(wc -l 2>/dev/null < "$_p_f" || echo 0)
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
		read -r _cp_st _ _ _cp_ms _ 2>/dev/null < "$_cp_f" || continue
		# «down» пишем нулём: разрыв в графике должен быть виден, а не сглажен
		[ "$_cp_st" = up ] || _cp_ms=0
		_push "ping.$_cp_if" "${_cp_ms:-0}"
		_cp_mp=$(uci5g_get "$(sec_for_iface "$_cp_if")" path)
		if [ ! -f "$DIR/ping.$_cp_if.label" ] || [ -n "$(find "$DIR/ping.$_cp_if.label" -mmin +10 2>/dev/null)" ]; then
			_cp_w=$(_iface_label "$_cp_if")
			[ -n "$_cp_mp" ] && _mdm_dup "$_cp_mp" && _cp_w="$_cp_w ($_cp_mp)"
			_cp_l=""
			{ read -r _cp_l < "$DIR/ping.$_cp_if.label"; } 2>/dev/null
			if [ "$_cp_l" = "$_cp_w" ]; then
				touch "$DIR/ping.$_cp_if.label" 2>/dev/null
			else
				_label "ping.$_cp_if" "$_cp_w"
			fi
		fi
	done
}

_metric_num() {
	printf '%s\n' "$1" | sed -n 's/^ *\(-\{0,1\}[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p' | head -1
}

_METRICS="signal temp rsrp sinr"
_MDM_PATHS=""; _MDM_SECS=" "; _MDM_LBL=""; _MDM_OLD=""

_mdm_init() {
	uci5g_snapshot
	_mi_lm=$("$RES/listmodems.sh" 2>/dev/null)
	_MDM_PATHS=$(printf '%s' "$_mi_lm" | jsonfilter -e '@[*].path' 2>/dev/null)
	_mi_rows=""; _MDM_OLD="$_UCI_NL"
	for _mi_p in $_MDM_PATHS; do
		_mi_s=$(secname "$_mi_p")
		_MDM_SECS="$_MDM_SECS$_mi_s "
		_mi_m=$(uci5g_get "$_mi_s" model)
		_mi_o="$_mi_m"
		[ -n "$_mi_o" ] || _mi_o="$_mi_p"
		_MDM_OLD="$_MDM_OLD$(printf '%s' "$_mi_o" | sed 's/[^A-Za-z0-9]/_/g') $_mi_s$_UCI_NL"
		_mi_n=$(printf '%s' "$_mi_lm" | jsonfilter -e "@[@.path=\"$_mi_p\"].alias" 2>/dev/null | head -1)
		[ -n "$_mi_n" ] || _mi_n="$_mi_m"
		[ -n "$_mi_n" ] || _mi_n=$(printf '%s' "$_mi_lm" | jsonfilter -e "@[@.path=\"$_mi_p\"].model" 2>/dev/null | head -1)
		[ -n "$_mi_n" ] || _mi_n="$_mi_p"
		_mi_rows="$_mi_rows$_mi_p	$_mi_n$_UCI_NL"
	done
	_MDM_LBL="$_UCI_NL$(printf '%s' "$_mi_rows" | awk -F'\t' 'NF >= 2 { p[++n] = $1; l[n] = $2; c[$2]++ }
		END { for (i = 1; i <= n; i++) print p[i] "\t" (c[l[i]] > 1 ? l[i] " (" p[i] ")" : l[i]) }')$_UCI_NL"
}

_mdm_label() {
	case "$_MDM_LBL" in *"$_UCI_NL$1	"*) ;; *) return 1 ;; esac
	_ml_r="${_MDM_LBL#*"$_UCI_NL$1	"}"
	printf '%s' "${_ml_r%%"$_UCI_NL"*}"
}

_mdm_dup() {
	case "$(_mdm_label "$1")" in *" ($1)") return 0 ;; esac
	return 1
}

_label_set() {
	[ -n "$2" ] || return 0
	_lb_c=""
	{ read -r _lb_c < "$DIR/$1.label"; } 2>/dev/null
	[ "$_lb_c" = "$2" ] || _label "$1" "$2"
}

_sec_id() {
	_cv=$(uci5g_get "$1" vidpid)
	_ci=$(uci5g_get "$1" imei | tr -cd '0-9')
	_cs=$(uci5g_get "$1" serial)
	case "$_cs" in *[!A-Za-z0-9._:-]*) _cs="" ;; esac
}

_id_get() {
	_idv=""; _idi=""; _ids=""
	[ -f "$DIR/id.$1" ] || return 1
	read -r _idv _idi _ids 2>/dev/null < "$DIR/id.$1"
	[ "$_idv" = - ] && _idv=""
	[ "$_idi" = - ] && _idi=""
	[ "$_ids" = - ] && _ids=""
	return 0
}

_id_put() {
	printf '%s %s %s\n' "${2:--}" "${3:--}" "${4:--}" > "$DIR/id.$1"
}

_series_move() {
	[ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ] || return 0
	for _sm_m in $_METRICS; do
		_sm_a="$DIR/$_sm_m.$1"; _sm_b="$DIR/$_sm_m.$2"
		if [ -f "$_sm_a" ]; then
			if [ -f "$_sm_b" ]; then
				sort -n -k1,1 "$_sm_a" "$_sm_b" \
					| awk -v m="$_sm_m" 'm == "signal" && $2 < 0 { next } $1 != p { print; p = $1 }' \
					| tail -n "$RING_MAX" > "$_sm_b.tmp" && mv "$_sm_b.tmp" "$_sm_b"
				rm -f "$_sm_a"
			else
				mv "$_sm_a" "$_sm_b"
			fi
		fi
		if [ -f "$_sm_a.label" ]; then
			[ -f "$_sm_b.label" ] || mv "$_sm_a.label" "$_sm_b.label"
			rm -f "$_sm_a.label"
		fi
	done
	if _id_get "$1"; then
		_sm_v="$_idv"; _sm_i="$_idi"; _sm_s="$_ids"
		if _id_get "$2"; then
			[ -n "$_idv" ] || _idv="$_sm_v"
			[ -n "$_idi" ] || _idi="$_sm_i"
			[ -n "$_ids" ] || _ids="$_sm_s"
			_id_put "$2" "$_idv" "$_idi" "$_ids"
		else
			_id_put "$2" "$_sm_v" "$_sm_i" "$_sm_s"
		fi
		rm -f "$DIR/id.$1"
	fi
	logger -t 5gmodem "stats: series $1 -> $2"
}

_imei_secs() {
	printf '%s\n' "$_UCI5G_SNAP" | grep -c "^$CFG\.m_[^.]*\.imei='\{0,1\}$1'\{0,1\}\$"
}

_mdm_claim() {
	for _mc_f in "$DIR"/id.*; do
		[ -f "$_mc_f" ] || continue
		_mc_k="${_mc_f##*/id.}"
		[ "$_mc_k" = "$1" ] && continue
		case "$_MDM_SECS" in *" $_mc_k "*) continue ;; esac
		case "$_UCI5G_SNAP" in *"$_UCI_NL$CFG.$_mc_k=modem$_UCI_NL"*|*"$_UCI_NL$CFG.$_mc_k=modem") continue ;; esac
		_id_get "$_mc_k" || continue
		_mc_ok=""
		if [ -n "$_ids" ] && [ -n "$_cs" ]; then
			[ "$_ids" = "$_cs" ] && ! stub_serial_known "$_ids" && _mc_ok=1
		elif [ -n "$_idi" ] && [ "$_idi" = "$_ci" ] && [ "$(_imei_secs "$_ci")" = 1 ]; then
			_mc_ok=1
		fi
		[ -n "$_mc_ok" ] && _series_move "$_mc_k" "$1"
	done
}

_mdm_reconcile() {
	for _mr_p in $_MDM_PATHS; do
		_mr_s=$(secname "$_mr_p")
		_sec_id "$_mr_s"
		if _id_get "$_mr_s"; then
			if [ -n "$_idv" ] && [ -n "$_cv" ] && [ "${_idv%%:*}" != "${_cv%%:*}" ]; then
				if [ -n "$_idi" ]; then
					_mr_k="m_park_$_idi"
				elif [ -n "$_ids" ]; then
					_mr_k="m_park_s$(printf '%s' "$_ids" | sed 's/[^A-Za-z0-9]/_/g')"
				else
					_mr_k="x_${_mr_s#m_}_$(printf '%s' "$_idv" | sed 's/[^A-Za-z0-9]/_/g')"
				fi
				_series_move "$_mr_s" "$_mr_k"
				_id_put "$_mr_s" "$_cv" "$_ci" "$_cs"
			else
				_mr_o="$_idv $_idi $_ids"
				[ -n "$_cv" ] && _idv="$_cv"
				[ -n "$_idi" ] || _idi="$_ci"
				[ -n "$_ids" ] || _ids="$_cs"
				[ "$_mr_o" = "$_idv $_idi $_ids" ] || _id_put "$_mr_s" "$_idv" "$_idi" "$_ids"
			fi
		else
			_id_put "$_mr_s" "$_cv" "$_ci" "$_cs"
		fi
		_mdm_claim "$_mr_s"
	done
	_mr_done=" "
	for _mr_f in "$DIR"/signal.* "$DIR"/temp.* "$DIR"/rsrp.* "$DIR"/sinr.*; do
		[ -f "$_mr_f" ] || continue
		_mr_k="${_mr_f##*/}"; _mr_k="${_mr_k#*.}"
		case "$_mr_k" in *.*|m_*|x_*) continue ;; esac
		case "$_mr_done" in *" $_mr_k "*) continue ;; esac
		_mr_done="$_mr_done$_mr_k "
		_mr_to=$(printf '%s' "$_MDM_OLD" | awk -v k="$_mr_k" -v x="x_$_mr_k" '$1 == k { n++; s = $2 } END { if (n == 1) print s; else if (n > 1) print x }')
		[ -n "$_mr_to" ] && _series_move "$_mr_k" "$_mr_to"
	done
}

# Уровень сигнала активного модема из последнего снимка (без похода в порт).
_collect_signal() {
	# ВСЕ модемы, а не только активный: ряд соседа копится из его снимка
	# (подогрев sessionwatch их обновляет), иначе на графике одна линия и
	# сравнить нечего. Ключ ряда - секция модема (та же лестница личности, что
	# у профилей на странице Модем), подпись - алиас или модель: «2_1_4_»
	# в легенде ни о чём не говорит.
	for _cs_p in $_MDM_PATHS; do
		[ -n "$_cs_p" ] || continue
		_cs_j=$("$RES/5gmodem.sh" peek "$_cs_p" 2>/dev/null)
		[ -n "$_cs_j" ] || continue
		_cs_age=$(printf '%s' "$_cs_j" | jsonfilter -e '@.age' 2>/dev/null)
		case "$_cs_age" in
			''|*[!0-9]*) : ;;
			*) [ "$_cs_age" -gt 90 ] && continue ;;
		esac
		# Процент из снимка (поле signal): он уже посчитан модемо-специфично
		# (у FM350 честен именно CSQ, а не RSSI) и совпадает с планкой на
		# главной странице. Сырые dBm на графике читались только специалистом.
		_cs_v=$(printf '%s' "$_cs_j" | jsonfilter -e '@.signal' 2>/dev/null)
		case "$_cs_v" in ''|*[!0-9]*) continue ;; esac
		[ "$_cs_v" -le 100 ] || _cs_v=100
		_cs_n=$(_mdm_label "$_cs_p")
		[ -n "$_cs_n" ] || _cs_n="$_cs_p"
		_cs_k=$(secname "$_cs_p")
		# Ряд, начатый прошлой версией, хранит dBm (отрицательные числа) -
		# проценты с ними в одной шкале не живут, начинаем ряд заново.
		_cs_old=$(tail -n1 "$DIR/signal.$_cs_k" 2>/dev/null | cut -d' ' -f2)
		case "$_cs_old" in -*) : > "$DIR/signal.$_cs_k" ;; esac
		_push "signal.$_cs_k" "$_cs_v"
		_label_set "signal.$_cs_k" "$_cs_n"
		# Температура - из того же снимка (поле temp, «45 C» -> 45). Отдают не
		# все модули (у L850/XMM датчика нет вовсе) - тогда ряда просто не будет.
		# Поле называется mtemp (temp в снимке НЕТ), значение приходит с
		# HTML-мнемоникой: «38 &deg;C» - берём ведущее число.
		_cs_t=$(printf '%s' "$_cs_j" | jsonfilter -e '@.mtemp' 2>/dev/null \
			| sed -n 's/^ *\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -1)
		if [ -n "$_cs_t" ]; then
			_push "temp.$_cs_k" "$_cs_t"
			_label_set "temp.$_cs_k" "$_cs_n"
		fi
		_cs_rp=$(_metric_num "$(printf '%s' "$_cs_j" | jsonfilter -e '@.rsrp' 2>/dev/null)")
		_cs_sn=$(_metric_num "$(printf '%s' "$_cs_j" | jsonfilter -e '@.sinr' 2>/dev/null)")
		if [ -n "$_cs_sn" ]; then
			_cs_rq=$(_metric_num "$(printf '%s' "$_cs_j" | jsonfilter -e '@.rsrq' 2>/dev/null)")
			_cs_sn=$(awk -v s="$_cs_sn" -v q="$_cs_rq" 'BEGIN { if (!(s + 0 == 0 && q != "" && q + 0 >= -14)) print s }')
		fi
		if [ -n "$_cs_rp" ]; then
			_push "rsrp.$_cs_k" "$_cs_rp"
			_label_set "rsrp.$_cs_k" "$_cs_n"
		fi
		if [ -n "$_cs_sn" ]; then
			_push "sinr.$_cs_k" "$_cs_sn"
			_label_set "sinr.$_cs_k" "$_cs_n"
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
		_ct_prx=0; _ct_ptx=0; _ct_pdev=""
		[ -f "$_ct_base" ] && read -r _ct_prx _ct_ptx _ct_pdev 2>/dev/null < "$_ct_base"
		case "$_ct_prx" in ''|*[!0-9]*) _ct_prx=0 ;; esac
		case "$_ct_ptx" in ''|*[!0-9]*) _ct_ptx=0 ;; esac
		printf '%s %s %s\n' "$_ct_rx" "$_ct_tx" "$_ct_dev" > "$_ct_base"
		[ "$_ct_pdev" = "$_ct_dev" ] || continue
		[ "$_ct_rx" -lt "$_ct_prx" ] || [ "$_ct_tx" -lt "$_ct_ptx" ] && continue
		[ "$_ct_prx" = 0 ] && [ "$_ct_ptx" = 0 ] && continue
		_ct_drx=$((_ct_rx - _ct_prx)); _ct_dtx=$((_ct_tx - _ct_ptx))
		[ "$_ct_drx" = 0 ] && [ "$_ct_dtx" = 0 ] && continue
		# КЛЮЧ - SIM-КАРТА, А НЕ ИНТЕРФЕЙС (запрос владельца).
		#
		# Интерфейс принадлежит МОДЕМУ, а трафик тарифицирует ОПЕРАТОР по SIM.
		# При смене SIM в том же модеме (или переносе SIM в другой модем) счёт
		# по интерфейсу смешивал разные симки в одну строку и терял историю при
		# перестановке. ICCID - постоянный номер самой карты, он и стал ключом.
		# SIM не опознали (модем молчит, снимка ещё нет) - копим по интерфейсу,
		# как раньше: терять байты хуже, чем показать их под именем линка.
		_ct_key="$_ct_if"
		_ct_sec=$(sec_for_iface "$_ct_if" 2>/dev/null)
		_ct_path=$(uci -q get "$CFG.$_ct_sec.path" 2>/dev/null)
		if [ -n "$_ct_path" ]; then
			_ct_snap=$("$RES/5gmodem.sh" peek "$_ct_path" 2>/dev/null)
			_ct_icc=$(printf '%s' "$_ct_snap" | jsonfilter -e '@.iccid' 2>/dev/null | tr -cd '0-9')
			if [ -n "$_ct_icc" ]; then
				_ct_key="sim-$_ct_icc"
				# Подпись строки: оператор и номер, если SIM его отдала (AT+CNUM
				# хранят не все карты). Иначе - хвост ICCID, чтобы карты можно
				# было различить между собой.
				# ПОЛЕ НАЗЫВАЕТСЯ operator_name. Здесь читали `@.operator`, которого
				# в снимке нет вовсе, - оператор всегда выходил пустым, и строка
				# трафика оставалась с одним номером телефона и нейтральным
				# значком SIM (07.08.2026). Старое имя оставляем запасным на
				# случай снимков прежних версий.
				_ct_op=$(printf '%s' "$_ct_snap" | jsonfilter -e '@.operator_name' 2>/dev/null)
				[ -n "$_ct_op" ] || _ct_op=$(printf '%s' "$_ct_snap" | jsonfilter -e '@.operator' 2>/dev/null)
				_ct_ph=$(printf '%s' "$_ct_snap" | jsonfilter -e '@.phone' 2>/dev/null)
				case "$_ct_ph" in ''|-) _ct_ph="" ;; esac
				case "$_ct_op" in ''|-) _ct_op="" ;; esac
				# ОПЕРАТОРА ЗАПОМИНАЕМ ЗА КАРТОЙ. Снимок отдаёт его не всегда:
				# модем мог быть не опрошен, лежать в поиске сети или вовсе не
				# быть активным - и строка трафика теряла и подпись, и значок
				# оператора (в таблице оставался нейтральный «SIM»). Имя карты не
				# меняется, поэтому один раз узнали - и держим; новое непустое
				# значение перезаписывает старое.
				_ct_opf="$DIR/$_ct_key.op"
				if [ -n "$_ct_op" ]; then
					printf '%s\n' "$_ct_op" > "$_ct_opf" 2>/dev/null
				else
					_ct_op=$(cat "$_ct_opf" 2>/dev/null)
				fi
				# Оператор отдельным ярлыком - страница берёт по нему ЗНАЧОК, не
				# разбирая подпись строки (в ней может не быть ничего, кроме
				# номера телефона).
				[ -n "$_ct_op" ] && _label "op.$_ct_key" "$_ct_op"
				_ct_lbl="$_ct_op"
				# Номера нет (карта не отдаёт AT+CNUM) - подписываем полным
				# ICCID: «t2 ICCID: 8970...». Появится номер - подпись сменится
				# на обычную, а ключ (ICCID) тот же, история строки сохранится.
				if [ -n "$_ct_ph" ]; then
					_ct_lbl="${_ct_lbl:+$_ct_lbl }$_ct_ph"
				else
					_ct_lbl="${_ct_lbl:+$_ct_lbl }ICCID: $_ct_icc"
				fi
				_label "$_ct_key" "$_ct_lbl"
			fi
		fi
		_ct_acc="$DIR/traffic.$_ct_key.$(_month)"
		_ct_arx=0; _ct_atx=0
		[ -f "$_ct_acc" ] && read -r _ct_arx _ct_atx 2>/dev/null < "$_ct_acc"
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
	[ -f "$_fl_st" ] && read -r _fl_last 2>/dev/null < "$_fl_st"
	case "$_fl_last" in ''|*[!0-9]*) _fl_last=0 ;; esac
	[ $(( $(_now) - _fl_last )) -ge "$FLUSH_EVERY" ] || return 0
	_fl_d=$(_pdir_now) || {
		# Ни свой путь, ни запасной не пишутся - молчать нельзя, иначе
		# «статистика не сохраняется» выясняется через месяц.
		logger -t 5gmodem "stats: cannot save history ($(_pdir_want) is unavailable)"
		return 0
	}
	# ВЕРНУЛАСЬ ФЛЕШКА - СНАЧАЛА ЗАБИРАЕМ ТО, ЧТО КОПИЛОСЬ В ЗАПАСНОМ. Иначе
	# первая же запись затёрла бы на носителе итоги, которые он пропустил.
	[ "$_fl_d" = "$PDIR_DEF" ] || _merge_from "$PDIR_DEF"
	mkdir -p "$_fl_d" 2>/dev/null
	for _fl_f in "$DIR"/traffic.*; do
		[ -f "$_fl_f" ] || continue
		cp "$_fl_f" "$_fl_d/${_fl_f##*/}" 2>/dev/null
	done
	# НА СЪЁМНЫЙ НОСИТЕЛЬ КЛАДЁМ И РЯДЫ ГРАФИКОВ - человек за тем флешку и
	# указывает. Во внутреннюю память их не пишем никогда: мегабайты в час на
	# ресурс флеш-памяти роутера того не стоят.
	if [ "$_fl_d" != "$PDIR_DEF" ]; then
		for _fl_f in "$DIR"/ping.* "$DIR"/signal.* "$DIR"/temp.* "$DIR"/rsrp.* "$DIR"/sinr.*; do
			[ -f "$_fl_f" ] || continue
			cp "$_fl_f" "$_fl_d/${_fl_f##*/}" 2>/dev/null
		done
	fi
	_now > "$_fl_st"
}

# Поднять месячные итоги с диска после ребута (ряды в /tmp переживать не должны).
# Берём ОБА источника - свой путь и запасной: пока флешки не было, итоги копились
# во внутренней памяти, а пока она была - на ней. Правило слияния - «больше
# побеждает», счётчики монотонные (см. шапку).
_restore() {
	_merge_from "$PDIR_DEF"
	_rs_w=$(_pdir_want)
	[ "$_rs_w" = "$PDIR_DEF" ] || { _dir_live "$_rs_w" 1 && _merge_from "$_rs_w"; }
	return 0
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
	_mdm_init
	_mdm_reconcile
	_collect_ping
	_collect_signal
	_collect_traffic
	_flush
	;;
list)
	# Какие ряды есть: {"ping":["modem",...],"signal":[...],"traffic":[...]}
	_ls_p=""; _ls_s=""; _ls_t=""; _ls_m=""; _ls_rp=""; _ls_sn=""
	for _ls_f in "$DIR"/ping.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_p="$_ls_p,\"${_ls_f##*/ping.}\""; done
	for _ls_f in "$DIR"/signal.*;  do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_s="$_ls_s,\"${_ls_f##*/signal.}\""; done
	for _ls_f in "$DIR"/traffic.*; do [ -f "$_ls_f" ] && _ls_t="$_ls_t,\"${_ls_f##*/traffic.}\""; done
	for _ls_f in "$DIR"/temp.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_m="$_ls_m,\"${_ls_f##*/temp.}\""; done
	for _ls_f in "$DIR"/rsrp.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_rp="$_ls_rp,\"${_ls_f##*/rsrp.}\""; done
	for _ls_f in "$DIR"/sinr.*;    do case "$_ls_f" in *.label) continue ;; esac
		[ -f "$_ls_f" ] && _ls_sn="$_ls_sn,\"${_ls_f##*/sinr.}\""; done
	# Человеческие подписи рядов: "<имя ряда>" -> "Compal RXM-G1" / "Wi-Fi do".
	# Пишутся сборщиком рядом с рядом (файл .label) - в имени файла дефисы и
	# пробелы недопустимы, а в легенде нужны именно они.
	_ls_l=""
	for _ls_f in "$DIR"/*.label; do
		[ -f "$_ls_f" ] || continue
		_ls_k="${_ls_f##*/}"; _ls_k="${_ls_k%.label}"
		read -r _ls_v 2>/dev/null < "$_ls_f"
		[ -n "$_ls_v" ] && _ls_l="$_ls_l,\"$_ls_k\":\"$(json_esc_s "$_ls_v")\""
	done
	# Куда пишем и куда просили: страница обязана показать, что данные уходят
	# не туда, куда человек указал (флешка отвалилась) - молчаливый фоллбек
	# страшнее самой пропажи.
	# ПРОБУ ЗАПИСЬЮ ЗДЕСЬ НЕ ДЕЛАЕМ. list зовёт страница при каждом обновлении, а
	# _pdir_now создаёт и удаляет файл - это цикл записи во флеш-память на каждый
	# показ графика. Смотрим дёшево: смонтирован ли свой путь; настоящая проверка
	# остаётся в flush, раз в час.
	_ls_now=""
	if _persist; then
		_ls_now=$(_pdir_want)
		if [ "$_ls_now" != "$PDIR_DEF" ] && ! _mounted "$_ls_now"; then
			_ls_now="$PDIR_DEF"
		fi
	fi
	_ls_bg=$(uci -q get "$CFG.stats.bgpoll" 2>/dev/null)
	case "$_ls_bg" in 60|300) : ;; *) _ls_bg=0 ;; esac
	printf '{"enabled":%s,"persist":%s,"bgpoll":%s,"path":"%s","path_now":"%s","path_default":"%s","ping":[%s],"signal":[%s],"traffic":[%s],"temp":[%s],"rsrp":[%s],"sinr":[%s],"labels":{%s}}\n' \
		"$(_enabled && echo 1 || echo 0)" "$(_persist && echo 1 || echo 0)" "$_ls_bg" \
		"$(json_esc_s "$(_cfg path)")" "$(json_esc_s "$_ls_now")" "$PDIR_DEF" \
		"${_ls_p#,}" "${_ls_s#,}" "${_ls_t#,}" "${_ls_m#,}" "${_ls_rp#,}" "${_ls_sn#,}" "${_ls_l#,}"
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
		read -r _tr_rx _tr_tx 2>/dev/null < "$_tr_f"
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
			bgpoll)
				case "$_sc_v" in
					60|300) uci -q set "$CFG.stats.bgpoll=$_sc_v" ;;
					*) uci -q delete "$CFG.stats.bgpoll" ;;
				esac ;;
			# Свой путь: абсолютный, без пробелов и метасимволов - строка
			# приходит из браузера и уходит в mkdir/cp.
			path)
				case "$_sc_v" in
					'') uci -q delete "$CFG.stats.path" ;;
					/*[!A-Za-z0-9._/-]*|*' '*) echo '{"error":"bad path"}'; exit 1 ;;
					/*) uci -q set "$CFG.stats.path=${_sc_v%/}" ;;
					*)  echo '{"error":"path must be absolute"}'; exit 1 ;;
				esac ;;
		esac
	done
	uci -q commit "$CFG"
	# Выключили персист - убираем то, что уже лежит на диске. Чужой каталог
	# (свой путь) НЕ трогаем: там могут лежать и не наши файлы.
	_persist || rm -rf "$PDIR_DEF" 2>/dev/null
	echo '{"result":"ok"}'
	;;
forget)
	# forget <ключ> <YYYY-MM> - убрать одну строку помесячного трафика. Стираем
	# и в /tmp, и в персисте (иначе часовой merge воскресит её из /etc), и в
	# своём каталоге пользователя, если задан.
	case "$2" in ''|*[!A-Za-z0-9._-]*) echo '{"error":"bad key"}'; exit 1 ;; esac
	case "$3" in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]) ;;
		*) echo '{"error":"bad month"}'; exit 1 ;;
	esac
	rm -f "$DIR/traffic.$2.$3" "$PDIR_DEF/traffic.$2.$3" 2>/dev/null
	_fg_d=$(_pdir_now 2>/dev/null)
	[ -n "$_fg_d" ] && rm -f "$_fg_d/traffic.$2.$3" 2>/dev/null
	echo '{"result":"ok"}'
	;;
reset)
	_rs_c=$(_pdir_want)
	if [ "$_rs_c" != "$PDIR_DEF" ] && [ -d "$_rs_c" ]; then
		rm -f "$_rs_c"/traffic.* "$_rs_c"/ping.* "$_rs_c"/signal.* "$_rs_c"/temp.* \
			"$_rs_c"/rsrp.* "$_rs_c"/sinr.* \
			"$_rs_c"/sim-*.label "$_rs_c"/op.sim-*.label 2>/dev/null
	fi
	rm -rf "$DIR" "$PDIR_DEF" 2>/dev/null
	mkdir -p "$DIR" 2>/dev/null
	echo '{"result":"ok"}'
	;;
*)
	echo '{"error":"usage: stats.sh tick|list|series <name>|traffic|setconf k=v|forget <key> <month>|reset"}'
	exit 1
	;;
esac
