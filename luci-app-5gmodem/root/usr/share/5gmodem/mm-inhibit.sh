#!/bin/sh
#
# Keep ModemManager OFF our kernel-proto modems on systems where the udev
# ID_MM_DEVICE_IGNORE rule can't apply - e.g. routers using libudev-zero, which
# provides the libudev API but runs no udevd and processes no /etc/udev rules.
# There MM grabs a kernel-proto modem (qmi/mbim/xmm/atc/fibocom/...), fails to
# manage it (the kernel owns the netdev), and then keeps re-probing its AT ports,
# colliding with our metrics reads -> the whole info page flickers.
#
# mmcli --inhibit releases a modem from MM and holds it released for as long as
# the mmcli process lives. So we run one background inhibitor per kernel-proto
# modem and keep them alive. Self-heals across MM restarts (the inhibitor's DBus
# drop makes MM re-add the modem; the next loop re-inhibits it) and modem
# re-plugs. Modems on the 'modemmanager' protocol are NEVER inhibited - MM must
# manage those. On systems WITH working udev the kernel-proto modems aren't
# visible to MM at all, so this simply finds nothing to do (harmless).
#
# Runs as a small procd service (see /etc/init.d/5gmodem-mm-inhibit).

RES=/usr/share/5gmodem
CFG=5gmodem
RUN=/var/run/5gmodem-mm-inhibit
mkdir -p "$RUN"

_is_kernel_proto() {
	case "$1" in qmi|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom) return 0 ;; *) return 1 ;; esac
}

# effective protocol of the modem at usb path $1: real iface proto, else remembered
_proto_for_path() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		NP=$(uci -q get "network.$IF.proto")
		[ -n "$NP" ] && { echo "$NP"; return; }
	fi
	uci -q get "$CFG.$SEC.iface_proto"
}

# Надо ли прятать модем на usb-пути $1 от ModemManager?
# Управляется галкой в настройках модема: 5gmodem.m_<path>.mm_exclude
#   1     - прятать; 0 - НЕ прятать (пользователь осознанно отдал модем MM);
#   пусто - умолчание: прячем всё, что работает на kernel-прото.
# Отключать бывает нужно: у MM богаче управление (режимы сети, 3G-бенды), и на
# части модемов оно полнее нашего qmi/AT-пути.
_mm_excluded() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	case "$(uci -q get "$CFG.$SEC.mm_exclude")" in
		0) return 1 ;;
		1) return 0 ;;
	esac
	_is_kernel_proto "$(_proto_for_path "$1")"
}

# one pass: inhibit every kernel-proto modem currently visible in MM
#
# ВАЖНО: если модем ВИДЕН в `mmcli -L`, значит инхибиция на него сейчас НЕ
# действует - у работающей инхибиции MM модем не показывает вовсе. Поэтому сам
# факт попадания сюда означает, что держатель (если он есть) бесполезен.
inhibit_pass() {
	command -v mmcli >/dev/null 2>&1 || return 0

	# Инхибиция регистрируется по D-Bus и умирает ВМЕСТЕ с процессом MM (проверено:
	# после рестарта MM держатель жив, а модем снова захвачен). Поэтому следим за
	# pid'ом самого MM: сменился - все держатели устарели, снимаем их немедленно,
	# не дожидаясь таймаутов, иначе модем останется открытым и у qmi отберут канал.
	_cur=$(pgrep -f '/usr/sbin/ModemManager' 2>/dev/null | head -1)
	_prev=$(cat "$RUN/.mmpid" 2>/dev/null)
	if [ -n "$_cur" ] && [ "$_cur" != "$_prev" ]; then
		for pf in "$RUN"/*.pid; do
			[ -f "$pf" ] || continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		done
		echo "$_cur" > "$RUN/.mmpid"
	fi

	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		DEV=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ -n "$DEV" ] || continue
		PATHID=$(basename "$DEV")                 # e.g. 1-1.3
		case "$PATHID" in *-*) ;; *) continue ;; esac
		_mm_excluded "$PATHID" || continue        # modemmanager-прото / галка снята
		pf="$RUN/$PATHID.pid"
		if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
			# Держатель жив, но модем всё равно виден -> инхибиция не работает.
			# Даём ей минуту (она срабатывает не мгновенно), потом пересоздаём:
			# так лечится главный баг - держатель, зацепившийся за УСТАРЕВШИЙ
			# индекс. Индекс меняется при каждом рестарте MM, а `kill -0` при этом
			# по-прежнему говорит "процесс жив", и старый код считал, что всё в
			# порядке, - модем оставался у MM (у qmi отбирался канал -> нет IP).
			[ -z "$(find "$pf" -mmin +1 2>/dev/null)" ] && continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		fi
		# Держим инхибицию по СТАБИЛЬНОМУ идентификатору устройства (sysfs-путь
		# из modem.generic.device), а НЕ по индексу -m: индекс живёт только до
		# следующего рестарта MM.
		setsid mmcli --inhibit-device="$DEV" >/dev/null 2>&1 &
		echo $! > "$pf"
	done
	# reap inhibitors whose process has exited (modem gone / MM restarted)
	for pf in "$RUN"/*.pid; do
		[ -f "$pf" ] || continue
		kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null || rm -f "$pf"
	done
}

case "$1" in
# set-exclude <секция модема> <0|1> - переключатель из настроек модема.
# Пишем флаг и СРАЗУ применяем: при включении прячем модем от MM, при выключении
# снимаем держателя, чтобы MM подхватил модем без перезагрузки.
set-exclude)
	[ -n "$2" ] || exit 0
	uci -q set "$CFG.$2.mm_exclude=${3:-1}"
	uci -q commit "$CFG"
	PATHID=$(uci -q get "$CFG.$2.path")
	if [ "${3:-1}" = "0" ] && [ -n "$PATHID" ]; then
		pf="$RUN/$PATHID.pid"
		[ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
	else
		inhibit_pass
	fi
	;;
once)  inhibit_pass ;;
stop)  for pf in "$RUN"/*.pid; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; done ;;
*)     while :; do inhibit_pass; sleep 15; done ;;   # daemon (procd)
esac
