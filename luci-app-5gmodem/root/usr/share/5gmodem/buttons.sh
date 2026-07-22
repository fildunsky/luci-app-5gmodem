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

_sid() { echo "btn_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

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
	printf '{"buttons":['
	_f=1
	_dts_buttons | sort -u | while IFS='	' read -r _name _label _type; do
		[ -n "$_name" ] || continue
		[ -n "$_type" ] || _type=button
		_def=0; _is_system "$_name" && _def=1
		_s=$(_sid "$_name")
		_pc=$(uci -q get "$CFG.$_s.pressed")
		_rc=$(uci -q get "$CFG.$_s.released")
		_db=$(uci -q get "$CFG.$_s.debounce")
		_to=$(uci -q get "$CFG.$_s.type_override")
		[ "$_f" = 1 ] || printf ','
		_f=0
		printf '{"name":"%s","label":"%s","type":"%s","type_override":"%s","default":%d,"pressed":"%s","released":"%s","debounce":"%s"}' \
			"$_name" "$(printf '%s' "$_label" | _json_esc)" "$_type" "$_to" "$_def" \
			"$(printf '%s' "$_pc" | _json_esc)" "$(printf '%s' "$_rc" | _json_esc)" "$_db"
	done
	printf ']}\n'
	;;
set)
	# set <name> <pressed|released|debounce> [value]. Без авто-очистки: секцию с
	# одним debounce (без команд) run всё равно игнорирует, а очистка на каждый
	# вызов ломала бы порядок сохранения (debounce до команд удалял секцию).
	# Полное снятие привязки - через `del`.
	[ -n "$2" ] || { echo '{"error":"no button"}'; exit 0; }
	case "$3" in pressed|released|debounce|type_override) ;; *) echo '{"error":"bad field"}'; exit 0 ;; esac
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
run)
	# run <name> <action> <seen> - выполнить привязанную команду (из диспетчера).
	[ -n "$2" ] || exit 0
	case "$3" in pressed|released) ;; *) exit 0 ;; esac
	_s=$(_sid "$2")
	_cmd=$(uci -q get "$CFG.$_s.$3")
	[ -n "$_cmd" ] || exit 0
	# АНТИДРЕБЕЗГ. Долгие сервисы (напр. ssclash stop ~секунды) при частых нажатиях
	# двоятся. Если с прошлого срабатывания этой кнопки+действия прошло меньше
	# debounce секунд - игнорируем. Время берём из /proc/uptime (монотонное,
	# переживает сдвиг часов), маркер - в /tmp.
	_dbc=$(uci -q get "$CFG.$_s.debounce")
	case "$_dbc" in ''|*[!0-9]*) _dbc=0 ;; esac
	if [ "$_dbc" -gt 0 ]; then
		_m="/tmp/5gmodem_btndbc_${_s}_$3"
		_now=$(cut -d. -f1 /proc/uptime 2>/dev/null); case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
		_last=$(cat "$_m" 2>/dev/null); case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
		[ "$_last" -gt 0 ] && [ "$((_now - _last))" -lt "$_dbc" ] && exit 0
		echo "$_now" > "$_m" 2>/dev/null
	fi
	BUTTON="$2" ACTION="$3" SEEN="$4" sh -c "$_cmd"
	;;
svc)
	# svc <toggle|start|stop|restart> <service> - универсальное управление сервисом
	# для одной МОМЕНТАЛЬНОЙ кнопки (toggle: запущен -> stop+disable, иначе
	# enable+start). Ставится в команду кнопки, напр.:
	#   /usr/share/5gmodem/buttons.sh svc toggle clash
	[ -n "$3" ] || { echo "usage: svc <toggle|start|stop|restart> <service>"; exit 1; }
	[ -x "/etc/init.d/$3" ] || { echo "no such service: $3"; exit 1; }
	_svc_running() {
		# Надёжный источник - procd: сервис есть в service list с "running": true.
		# Остановленный сервис в списке = {} (нет совпадения).
		ubus -S call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true' && return 0
		# Фолбэк - по EXIT-КОДУ status, а НЕ по тексту: «inactive» содержит
		# «active», «not running» содержит «running» - grep по тексту ложно
		# срабатывал (сервис после stop не включался повторным нажатием).
		/etc/init.d/"$1" status >/dev/null 2>&1
	}
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
