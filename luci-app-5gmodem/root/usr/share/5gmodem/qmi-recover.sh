#!/bin/sh
# Восстановление QMI-пула модема при исчерпании client-ID (ClientIdsExhausted).
#
# ЗАЧЕМ. У части модемов (Compal RXM-G1 / Qualcomm SDX55) пул QMI-клиентов
# КРОШЕЧНЫЙ - замерено живьём ~6 на сервис NAS. Любая утечка (убитый по таймауту
# ПРЯМОЙ QMI-вызов не освобождает свой CID; цикл failed-повторов ModemManager)
# быстро его исчерпывает. После этого MM не может создать NAS-клиент, падает init
# ('couldn't peek client for service nas' -> state=failed, 'unknown-capabilities'),
# и у модема пропадают И данные, И управление диапазонами (у Compal бенды ставятся
# ТОЛЬКО через MM). Освободить «повисшие» CID нельзя - их номера неизвестны, -
# поэтому единственное лечение это СБРОС модема (AT+CFUN=1,1): после
# переэнумерации пул чист, и MM инициализируется нормально.
#
# Основную утечку мы устранили, переведя свои QMI-вызовы на qmi-proxy (-p): убитый
# proxy-вызов пул не трогает. Но при 6 слотах исчерпание всё равно возможно (чужой
# код, повторы MM, подвисший proxy), поэтому держим ещё и это авто-восстановление.

. /usr/share/5gmodem/lib.sh 2>/dev/null   # at_query: очередь к порту + таймаут

RES=/usr/share/5gmodem

# Пул исчерпан?  $1 = cdc-wdm.  0 = да (исчерпан).
qmi_pool_exhausted() {
	[ -n "$1" ] && [ -e "$1" ] || return 1
	# -t 5: не виснуть; -p: спрашиваем через прокси (свой клиент не плодим).
	qmicli -p -t 5 -d "$1" --nas-get-serving-system 2>&1 | grep -qi "ClientIdsExhausted"
}

# MM держит модем на usb-пути $1 в состоянии failed из-за unknown-capabilities?
# ВАЖНО: после исчерпания пула MM остаётся failed ДАЖЕ когда пул уже освободился -
# сам init он не повторяет. Поэтому это ОТДЕЛЬНЫЙ триггер сброса помимо
# qmi_pool_exhausted: только переэнумерация заставит MM переопросить модем начисто.
_mm_failed_unknowncaps() {   # $1 = usb path
	command -v mmcli >/dev/null 2>&1 || return 1
	for _i in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		_d=$(mmcli -m "$_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		case "$_d" in *"$1") ;; *) continue ;; esac
		[ "$(mmcli -m "$_i" -K 2>/dev/null | sed -n 's/^modem\.generic\.state-failed-reason *: *//p')" \
			= "unknown-capabilities" ] && return 0
		return 1
	done
	return 1
}

# Сбросить модем, если пул исчерпан.  $1 = usb-путь.  Не чаще раза в 3 минуты.
qmi_pool_recover() {
	_qp="$1"; [ -n "$_qp" ] || return 1
	_lm=$("$RES/listmodems.sh" 2>/dev/null)
	_qw=$(printf '%s' "$_lm" | jsonfilter -e "@[@.path=\"$_qp\"].wdm[0]" 2>/dev/null)
	[ -n "$_qw" ] && [ -e "$_qw" ] || return 1
	# Триггер сброса: пул исчерпан ЛИБО MM залип в failed/unknown-capabilities.
	_trig=""
	qmi_pool_exhausted "$_qw" && _trig="QMI-пул исчерпан"
	[ -z "$_trig" ] && _mm_failed_unknowncaps "$_qp" && _trig="MM failed: unknown-capabilities"
	[ -n "$_trig" ] || return 1
	# Защита от цикла сбросов: маркер в /tmp (переживает до перезагрузки).
	_mk="/tmp/5gmodem_qmirecover_$(printf '%s' "$_qp" | tr -c 'A-Za-z0-9' _)"
	[ -n "$(find "$_mk" -mmin -3 2>/dev/null)" ] && return 1
	# Живой AT-порт этого модема для сброса.
	for _t in $(printf '%s' "$_lm" | jsonfilter -e "@[@.path=\"$_qp\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		at_query "$_t" "AT" 5 | grep -q "OK" || continue
		logger -t 5gmodem "$_trig на $_qp - сбрасываю модем (AT+CFUN=1,1 на $_t)"
		touch "$_mk" 2>/dev/null
		at_query "$_t" "AT+CFUN=1,1" 5 >/dev/null 2>&1
		return 0
	done
	logger -t 5gmodem "QMI pool exhausted on $_qp, но живого AT-порта для сброса нет"
	return 1
}

case "$1" in
	check)   qmi_pool_exhausted "$2" && echo exhausted || echo ok ;;
	recover) qmi_pool_recover "$2" ;;
	*) echo "usage: $0 {check <cdc-wdm>|recover <usb-path>}" >&2; exit 1 ;;
esac
