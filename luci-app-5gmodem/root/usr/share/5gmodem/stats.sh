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
		read -r _mf_rx _mf_tx < "$_mf_f" 2>/dev/null
		case "$_mf_rx" in ''|*[!0-9]*) _mf_rx=0 ;; esac
		case "$_mf_tx" in ''|*[!0-9]*) _mf_tx=0 ;; esac
		_mf_crx=0; _mf_ctx=0
		[ -f "$DIR/$_mf_n" ] && read -r _mf_crx _mf_ctx < "$DIR/$_mf_n" 2>/dev/null
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
		# Процент из снимка (поле signal): он уже посчитан модемо-специфично
		# (у FM350 честен именно CSQ, а не RSSI) и совпадает с планкой на
		# главной странице. Сырые dBm на графике читались только специалистом.
		_cs_v=$(printf '%s' "$_cs_j" | jsonfilter -e '@.signal' 2>/dev/null)
		case "$_cs_v" in ''|*[!0-9]*) continue ;; esac
		[ "$_cs_v" -le 100 ] || _cs_v=100
		_cs_n=$(uci -q get "$CFG.m_$(echo "$_cs_p" | sed 's/[^A-Za-z0-9]/_/g').model" 2>/dev/null)
		[ -n "$_cs_n" ] || _cs_n="$_cs_p"
		_cs_k=$(printf '%s' "$_cs_n" | sed 's/[^A-Za-z0-9]/_/g')
		# Ряд, начатый прошлой версией, хранит dBm (отрицательные числа) -
		# проценты с ними в одной шкале не живут, начинаем ряд заново.
		_cs_old=$(tail -n1 "$DIR/signal.$_cs_k" 2>/dev/null | cut -d' ' -f2)
		case "$_cs_old" in -*) : > "$DIR/signal.$_cs_k" ;; esac
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
	_fl_d=$(_pdir_now) || {
		# Ни свой путь, ни запасной не пишутся - молчать нельзя, иначе
		# «статистика не сохраняется» выясняется через месяц.
		logger -t 5gmodem "статистика: некуда сохранять ($(_pdir_want) недоступен)"
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
		for _fl_f in "$DIR"/ping.* "$DIR"/signal.* "$DIR"/temp.*; do
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
	printf '{"enabled":%s,"persist":%s,"path":"%s","path_now":"%s","path_default":"%s","ping":[%s],"signal":[%s],"traffic":[%s],"temp":[%s],"labels":{%s}}\n' \
		"$(_enabled && echo 1 || echo 0)" "$(_persist && echo 1 || echo 0)" \
		"$(json_esc_s "$(_cfg path)")" "$(json_esc_s "$_ls_now")" "$PDIR_DEF" \
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
	rm -rf "$DIR" "$PDIR_DEF" 2>/dev/null
	mkdir -p "$DIR" 2>/dev/null
	echo '{"result":"ok"}'
	;;
*)
	echo '{"error":"usage: stats.sh tick|list|series <name>|traffic|setconf k=v|forget <key> <month>|reset"}'
	exit 1
	;;
esac
