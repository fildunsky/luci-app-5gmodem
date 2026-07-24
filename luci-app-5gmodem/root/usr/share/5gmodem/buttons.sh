#!/bin/sh
# Автоопределение железных кнопок роутера и привязка команды на нажатие/отпускание
# (вкладка «Кнопки»).
#
# ГЛАВНОЕ: в событии кнопки $BUTTON - это имя INPUT-КОДА (BTN_0, reset, wps...), а
# НЕ DTS-label. label ("mode") - лишь человекочитаемая подпись; kmod-gpio-button-
# hotplug кладёт в $BUTTON имя, выведенное из linux,code (проверено live: DTS
# "mode" с linux,code=256 приходит как BUTTON=BTN_0). События доставляются в
# /etc/hotplug.d/button/ с $BUTTON / $ACTION (pressed|released) / $SEEN (сек
# удержания). procd-путь `config button` на части плат (напр. Huasifei WH3000) НЕ
# срабатывает - идём через hotplug.d/button, он универсальнее.
#
#   buttons.sh detect
#   buttons.sh set <name> <pressed|released> [command]   # пусто = снять действие
#   buttons.sh run <name> <action> <seen>                # из hotplug-диспетчера

CFG=5gmodem
LEDS_DIR="${LEDS_DIR:-/sys/class/leds}"

_sid() { echo "btn_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

# Цвет светодиода из его имени: у большинства плат имя вида "green:wan",
# "white:signal1", "red:power" - слово до двоеточия и есть цвет. Отдаём его,
# только если это узнаваемый цвет (иначе у LED "wan"/"phy0tx" двоеточия нет
# или перед ним не цвет - тогда пусто, точку рисуем нейтральной).
_led_color() {
	case "$1" in *:*) _c="${1%%:*}" ;; *) _c="" ;; esac
	case "$_c" in
		red|green|blue|white|amber|orange|yellow|cyan|purple|violet|pink|magenta) echo "$_c" ;;
		*) echo "" ;;
	esac
}

# Яркость «включено» у светодиода своя (1 или 255) - читаем из sysfs.
_led_max() {
	_m=$(cat "$LEDS_DIR/$1/max_brightness" 2>/dev/null)
	case "$_m" in ''|*[!0-9]*|0) _m=255 ;; esac
	printf '%s' "$_m"
}

# Dummy-светодиоды радио mac80211 (mt76-phy0, ath10k-phy0 и пр.): физического
# диода за ними нет, в OpenWrt они не используются и есть на всех платах.
# Прячем и из списка, и из управления.
_led_dummy() { case "$1" in *-phy[0-9]*) return 0 ;; *) return 1 ;; esac; }

# Отцепить светодиод от его kernel-триггера ПЕРСИСТЕНТНО - через стандартный
# uci system (config led ... option trigger 'none'). Без этого netdev-триггер
# возвращает свою яркость сразу после нашей записи. Секцию ищем по sysfs-имени,
# нет - создаём. commit/reload делает вызывающий (пакетно).
_led_detach() {
	_name="$1"; [ -n "$_name" ] || return 0
	_sec=""
	for _s in $(uci show system 2>/dev/null | sed -n 's/^system\.\([^.=]*\)=led$/\1/p'); do
		[ "$(uci -q get "system.$_s.sysfs")" = "$_name" ] && { _sec="$_s"; break; }
	done
	if [ -z "$_sec" ]; then
		_sec=$(uci add system led 2>/dev/null) || return 0
		uci -q set "system.$_sec.name=$_name"
		uci -q set "system.$_sec.sysfs=$_name"
	fi
	uci -q set "system.$_sec.trigger=none"
}

# Применить спецификацию светодиодов: "имя=1 имя=0 ...". 1 - зажечь на макс.
# яркость, 0 - погасить. Трогаем ТОЛЬКО перечисленные (остальные не наши).
# Перед записью яркости сбрасываем kernel-триггер в none В РАНТАЙМЕ (дёшево, без
# флеша): персистентно это же делает _led_detach при сохранении, но триггер мог
# ещё висеть - иначе netdev вернул бы свою яркость поверх нашей.
_apply_leds() {
	for _kv in $1; do
		_ln="${_kv%=*}"; _lv="${_kv##*=}"
		[ -n "$_ln" ] || continue
		_led_dummy "$_ln" && continue
		[ -e "$LEDS_DIR/$_ln/brightness" ] || continue
		[ -e "$LEDS_DIR/$_ln/trigger" ] && printf 'none' > "$LEDS_DIR/$_ln/trigger" 2>/dev/null
		if [ "$_lv" = "1" ]; then
			printf '%s' "$(_led_max "$_ln")" > "$LEDS_DIR/$_ln/brightness" 2>/dev/null
		else
			printf '0' > "$LEDS_DIR/$_ln/brightness" 2>/dev/null
		fi
	done
}

# Запущен ли сервис. Общий хелпер (нужен и в svc, и в условных командах run).
_svc_running() {
	# Надёжный источник - procd: сервис есть в service list с "running": true.
	# Остановленный сервис в списке = {} (нет совпадения).
	ubus -S call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true' && return 0
	# Фолбэк - по EXIT-КОДУ status, а НЕ по тексту: «inactive» содержит «active»,
	# «not running» содержит «running» - grep по тексту ложно срабатывал.
	/etc/init.d/"$1" status >/dev/null 2>&1
}

# input-код -> имя кнопки, как его шлёт kmod. Покрываем ходовые; неизвестный код
# пропускаем (его реальное имя нам неизвестно - позже добавим режим «обучения»
# нажатием). BTN_0..15 = 0x100.., KEY_* - по стандартным кодам.
_code_name() {
	case "$1" in
		256) echo BTN_0;; 257) echo BTN_1;; 258) echo BTN_2;; 259) echo BTN_3;;
		260) echo BTN_4;; 261) echo BTN_5;; 262) echo BTN_6;; 263) echo BTN_7;;
		264) echo BTN_8;; 265) echo BTN_9;;
		408) echo reset;; 529) echo wps;; 247) echo rfkill;; 116) echo power;;
		*) echo "";;
	esac
}

# Кнопки из DTS: печатает "имя<TAB>label<TAB>type". Имя выведено из linux,code,
# type - из linux,input-type: EV_SW(5)=switch (переключатель, два положения дают
# pressed/released), отсутствует/EV_KEY(1)=button (моментальная).
_dts_buttons() {
	# Известно-ОШИБОЧНЫЕ DTS: у Huasifei WH3000* моментальную кнопку объявили
	# EV_SW (залипающего переключателя на плате нет). На таких платах трактуем
	# EV_SW как обычную кнопку. Список плат зафиксирован (board_name = compatible).
	_force_key=0
	case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
		huasifei,wh3000*) _force_key=1 ;;
	esac
	for _kd in /sys/firmware/devicetree/base/gpio-keys \
	           /sys/firmware/devicetree/base/gpio-keys-polled; do
		[ -d "$_kd" ] || continue
		for _b in "$_kd"/*/; do
			[ -f "${_b}linux,code" ] || continue
			_hex=$(hexdump -v -e '/1 "%02x"' "${_b}linux,code" 2>/dev/null)
			[ -n "$_hex" ] || continue
			_nm=$(_code_name "$((0x$_hex))")
			[ -n "$_nm" ] || continue
			_lbl=""; [ -f "${_b}label" ] && _lbl=$(tr -d '\0' < "${_b}label")
			_type=button
			if [ "$_force_key" != 1 ] && [ -f "${_b}linux,input-type" ]; then
				_ith=$(hexdump -v -e '/1 "%02x"' "${_b}linux,input-type" 2>/dev/null)
				[ "$((0x${_ith:-0}))" = 5 ] && _type=switch
			fi
			printf '%s\t%s\t%s\n' "$_nm" "$_lbl" "$_type"
		done
	done
}

# «Системная» кнопка = есть заводской обработчик /etc/rc.button/<name>
# (reset/wps/...). Такой не переназначаем - у неё своё поведение.
# Системная = ТОЛЬКО заводской сброс (reset): его переназначать нельзя, поведение
# критично. Остальные кнопки с заводским обработчиком (wps и пр.) назначаемы:
# заводской wps в чистом OpenWrt на деле ничего не делает (rc.wps - пустышка),
# так что глушить его смысла нет - пользовательская команда просто отрабатывает.
_is_system() { [ "$1" = "reset" ]; }

_json_esc() { sed 's/\\/\\\\/g; s/"/\\"/g'; }

case "$1" in
detect)
	# Возвращаем ВСЕ сохранённые поля, иначе UI при перезагрузке терял тип
	# команды/сервис/условные диоды и сбрасывал их в дефолт. По каждому
	# состоянию (pressed/released): тип команды, команда-терминал, сервис и три
	# набора диодов - статичный (простая) и on/off (условная).
	_jf() { printf '%s' "$(uci -q get "$CFG.$1.$2" 2>/dev/null)" | _json_esc; }
	printf '{"buttons":['
	_f=1
	_dts_buttons | sort -u | while IFS='	' read -r _name _label _type; do
		[ -n "$_name" ] || continue
		[ -n "$_type" ] || _type=button
		_def=0; _is_system "$_name" && _def=1
		_s=$(_sid "$_name")
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '{"name":"%s","label":"%s","type":"%s","default":%d,"btntype":"%s","debounce":"%s"' \
			"$_name" "$(printf '%s' "$_label" | _json_esc)" "$_type" "$_def" \
			"$(_jf "$_s" btntype)" "$(_jf "$_s" debounce)"
		for _st in pressed released; do
			printf ',"ct_%s":"%s","cmd_%s":"%s","svc_%s":"%s"' \
				"$_st" "$(_jf "$_s" "ct_$_st")" \
				"$_st" "$(_jf "$_s" "$_st")" \
				"$_st" "$(_jf "$_s" "svc_$_st")"
			printf ',"leds_%s":"%s","ledson_%s":"%s","ledsoff_%s":"%s"' \
				"$_st" "$(_jf "$_s" "leds_$_st")" \
				"$_st" "$(_jf "$_s" "leds_on_$_st")" \
				"$_st" "$(_jf "$_s" "leds_off_$_st")"
		done
		printf '}'
	done
	printf ']}\n'
	;;
services)
	# Сервисы роутера (init.d) - для выпадашки условной команды: пользователь
	# выбирает сервис, а команда переключения подставляется в терминал.
	printf '{"services":['
	_f=1
	for _sv in /etc/init.d/*; do
		[ -f "$_sv" ] && [ -x "$_sv" ] || continue
		_n=$(basename "$_sv")
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '"%s"' "$(printf '%s' "$_n" | _json_esc)"
	done
	printf ']}\n'
	;;
set)
	# set <name> <pressed|released|debounce> [value]. Без авто-очистки: секцию с
	# одним debounce (без команд) run всё равно игнорирует, а очистка на каждый
	# вызов ломала бы порядок сохранения (debounce до команд удалял секцию).
	# Полное снятие привязки - через `del`.
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	case "$3" in pressed|released|debounce|type_override|btntype|ct_pressed|ct_released|svc_pressed|svc_released) ;; *) echo '{"error":"bad field"}'; exit 0 ;; esac
	_s=$(_sid "$2")
	uci -q get "$CFG.$_s" >/dev/null 2>&1 || uci -q set "$CFG.$_s=button"
	uci -q set "$CFG.$_s.name=$2"
	if [ -z "$4" ]; then
		uci -q delete "$CFG.$_s.$3" 2>/dev/null
	else
		uci -q set "$CFG.$_s.$3=$4"
	fi
	uci -q commit "$CFG"
	echo '{"ok":1}'
	;;
del)
	# del <name> - снять привязку целиком
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	uci -q delete "$CFG.$(_sid "$2")" 2>/dev/null
	uci -q commit "$CFG"
	echo '{"ok":1}'
	;;
leds)
	# Все светодиоды роутера: имя, цвет (из label), текущее состояние (горит?).
	# Отдаём как есть - страница «Кнопки» рисует сеткой точек, где пользователь
	# выбирает, что делать с каждым при нажатии/отжатии.
	printf '{"leds":['
	_f=1
	for _d in "$LEDS_DIR"/*; do
		[ -d "$_d" ] || continue
		[ -e "$_d/brightness" ] || continue
		_n=$(basename "$_d")
		_led_dummy "$_n" && continue
		_b=$(cat "$_d/brightness" 2>/dev/null); case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
		_on=0; [ "$_b" -gt 0 ] && _on=1
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '{"name":"%s","color":"%s","on":%d}' \
			"$(printf '%s' "$_n" | _json_esc)" "$(_led_color "$_n")" "$_on"
	done
	printf ']}\n'
	;;
setleds)
	# setleds <name> <key> [spec]. spec = "имя=1 имя=0 ...". Пусто = снять.
	# key: pressed/released - статичные диоды простой команды/положения;
	#      on_pressed/off_pressed/on_released/off_released - диоды условной
	#      команды для запущенного/остановленного сервиса в этом состоянии.
	# Хранятся как leds_<key>.
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	case "$3" in pressed|released|on_pressed|off_pressed|on_released|off_released) ;; *) echo '{"error":"bad action"}'; exit 0 ;; esac
	_s=$(_sid "$2")
	uci -q get "$CFG.$_s" >/dev/null 2>&1 || uci -q set "$CFG.$_s=button"
	uci -q set "$CFG.$_s.name=$2"
	if [ -z "$4" ]; then
		uci -q delete "$CFG.$_s.leds_$3" 2>/dev/null
	else
		uci -q set "$CFG.$_s.leds_$3=$4"
	fi
	uci -q commit "$CFG"
	# Персистентно отцепляем выбранные диоды от их триггеров (uci system),
	# чтобы netdev и пр. не возвращали яркость. Только для реально выбранных
	# (on/off); «не трогать» в спеку не попадает.
	if [ -n "$4" ]; then
		_any=0
		for _kv in $4; do
			_ln="${_kv%=*}"
			_led_dummy "$_ln" && continue
			[ -e "$LEDS_DIR/$_ln/brightness" ] || continue
			_led_detach "$_ln"; _any=1
		done
		[ "$_any" = 1 ] && { uci -q commit system; /etc/init.d/led reload 2>/dev/null; }
	fi
	echo '{"ok":1}'
	;;
applyleds)
	# applyleds "<spec>" - применить светодиоды прямо сейчас (превью со страницы).
	_apply_leds "$2"
	echo '{"ok":1}'
	;;
run)
	# run <name> <action> <seen> - отработать состояние (из hotplug-диспетчера).
	# action = pressed|released - ПРЯМОЕ событие. У каждого состояния свой тип
	# команды: простая (команда + статичные диоды) или условная (переключить
	# сервис + диоды под его реальное состояние). Виртуального тумблера больше
	# нет: «нажата»/«отжата» - самостоятельные события (моментальная кнопка на
	# одно нажатие шлёт оба; пользователь настраивает нужное).
	[ -n "$2" ] || exit 0
	case "$3" in pressed|released) ;; *) exit 0 ;; esac
	_s=$(_sid "$2")
	_st="$3"
	_ct=$(uci -q get "$CFG.$_s.ct_$_st")

	# АНТИДРЕБЕЗГ - до любых действий. Время из /proc/uptime (монотонное).
	_dbc=$(uci -q get "$CFG.$_s.debounce")
	case "$_dbc" in ''|*[!0-9]*) _dbc=0 ;; esac
	if [ "$_dbc" -gt 0 ]; then
		_m="/tmp/5gmodem_btndbc_${_s}_$_st"
		_now=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
		_last=$(cat "$_m" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
		[ "$_last" -gt 0 ] && [ "$((_now - _last))" -lt "$_dbc" ] && exit 0
	fi

	_cmd=$(uci -q get "$CFG.$_s.$_st")

	if [ "$_ct" = "conditional" ]; then
		# УСЛОВНАЯ: сервис берём ИЗ САМОЙ КОМАНДЫ (отдельного поля больше нет,
		# чтобы не путать две сущности). Команда-тумблер («svc toggle <svc>» из
		# выпадашки, либо /etc/init.d/<svc> ...) сама переключает сервис; мы лишь
		# извлекаем имя, чтобы выставить диоды под БУДУЩЕЕ состояние (команда
		# сейчас переключит), потом её и выполняем.
		_svc=$(printf '%s' "$_cmd" | sed -n 's/.*svc[[:space:]]\{1,\}[a-z]\{1,\}[[:space:]]\{1,\}\([A-Za-z0-9_.-]\{1,\}\).*/\1/p')
		[ -n "$_svc" ] || _svc=$(printf '%s' "$_cmd" | sed -n 's#.*/etc/init.d/\([A-Za-z0-9_.-]\{1,\}\).*#\1#p')
		[ "$_dbc" -gt 0 ] && echo "$_now" > "$_m" 2>/dev/null
		if [ -n "$_svc" ] && [ -x "/etc/init.d/$_svc" ]; then
			if _svc_running "$_svc"; then
				_apply_leds "$(uci -q get "$CFG.$_s.leds_off_$_st")"   # тумблер остановит -> «остановлен»
			else
				_apply_leds "$(uci -q get "$CFG.$_s.leds_on_$_st")"    # тумблер запустит -> «запущен»
			fi
		fi
		# Сама команда (она и переключает сервис).
		[ -n "$_cmd" ] && BUTTON="$2" ACTION="$_st" SEEN="$4" sh -c "$_cmd"
		exit 0
	fi

	# ПРОСТАЯ: статичные диоды + команда.
	_leds=$(uci -q get "$CFG.$_s.leds_$_st")
	[ -n "$_cmd$_leds" ] || exit 0
	[ "$_dbc" -gt 0 ] && echo "$_now" > "$_m" 2>/dev/null
	# Светодиоды - ПЕРЕД командой: визуальный отклик мгновенный.
	[ -n "$_leds" ] && _apply_leds "$_leds"
	[ -n "$_cmd" ] && BUTTON="$2" ACTION="$_st" SEEN="$4" sh -c "$_cmd"
	;;
syncleds)
	# Выставить диоды ПОД ТЕКУЩЕЕ состояние сервиса. Зовётся при загрузке роутера
	# (init 5gmodem-btnleds).
	#
	# ЗАЧЕМ. Диоды условной кнопки выставляет только обработчик нажатия, поэтому
	# после перезагрузки они оставались тёмными до первого физического нажатия -
	# хотя сервис уже работал (наблюдалось на кнопке-тумблере ssclash).
	#
	# ВНИМАНИЕ НА СЕМАНТИКУ. При НАЖАТИИ диоды показывают БУДУЩЕЕ состояние
	# (команда сейчас переключит сервис), а здесь - ТЕКУЩЕЕ. Поэтому соответствие
	# ОБРАТНОЕ к ветке run: сервис запущен -> leds_on_*, остановлен -> leds_off_*.
	#
	# Только УСЛОВНЫЕ кнопки: у простой диоды статичны и отражают факт нажатия,
	# а не наблюдаемое состояние - применять их на старте значило бы соврать.
	for _s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\([^.=]*\)=button\$/\1/p"); do
		for _st in pressed released; do
			[ "$(uci -q get "$CFG.$_s.ct_$_st")" = "conditional" ] || continue
			_cmd=$(uci -q get "$CFG.$_s.$_st")
			# Имя сервиса берём из самой команды - тем же разбором, что и run.
			_svc=$(printf '%s' "$_cmd" | sed -n 's/.*svc[[:space:]]\{1,\}[a-z]\{1,\}[[:space:]]\{1,\}\([A-Za-z0-9_.-]\{1,\}\).*/\1/p')
			[ -n "$_svc" ] || _svc=$(printf '%s' "$_cmd" | sed -n 's#.*/etc/init.d/\([A-Za-z0-9_.-]\{1,\}\).*#\1#p')
			[ -n "$_svc" ] && [ -x "/etc/init.d/$_svc" ] || continue
			if _svc_running "$_svc"; then
				_apply_leds "$(uci -q get "$CFG.$_s.leds_on_$_st")"
			else
				_apply_leds "$(uci -q get "$CFG.$_s.leds_off_$_st")"
			fi
		done
	done
	;;
svc)
	# svc <toggle|start|stop|restart> <service> - универсальное управление сервисом
	# для одной МОМЕНТАЛЬНОЙ кнопки (toggle: запущен -> stop+disable, иначе
	# enable+start). Ставится в команду кнопки, напр.:
	#   /usr/share/5gmodem/buttons.sh svc toggle clash
	[ -n "$3" ] || { echo "usage: svc <toggle|start|stop|restart> <service>"; exit 1; }
	[ -x "/etc/init.d/$3" ] || { echo "no such service: $3"; exit 1; }
	case "$2" in
		toggle)
			if _svc_running "$3"; then /etc/init.d/"$3" stop; /etc/init.d/"$3" disable
			else /etc/init.d/"$3" enable; /etc/init.d/"$3" start; fi ;;
		start)   /etc/init.d/"$3" enable;  /etc/init.d/"$3" start ;;
		stop)    /etc/init.d/"$3" stop;    /etc/init.d/"$3" disable ;;
		restart) /etc/init.d/"$3" restart ;;
		*) echo "usage: svc <toggle|start|stop|restart> <service>"; exit 1 ;;
	esac
	;;
*)
	echo '{"error":"usage: detect|set|run"}'
	;;
esac
