#!/bin/sh
#
# Multi-modem control. A modem is identified by its stable USB topology PATH
# (e.g. "1-1.3"), so it survives reboots and is unique even for two identical
# VID:PID modems. This script makes one modem "active" - the app then reads
# metrics / SMS / USSD from that modem's ports and interface.
#
# Storage in the 5gmodem config:
#   5gmodem.@5gmodem[0].active_modem = <usb path>
#   config modem 'm_<path>'  { path, product, at_port, network, iface_proto }
# The per-modem section remembers each modem's chosen AT port and interface, so
# switching back and forth restores its settings.
#
# Usage:
#   modemswitch.sh active            - print the active USB path
#   modemswitch.sh switch <path>     - make <path> active (detect ports, apply)
#   modemswitch.sh save <path>       - persist the current working config into
#                                      the given modem's section (before switch)
#

RES=/usr/share/5gmodem
CFG=5gmodem

[ -r "$RES/quirks.sh" ] && . "$RES/quirks.sh"

secname() { echo "m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }

# Галка «слать USSD обычным текстом» (sms_tool -R) - ОДНА на весь sms_tool_js, а
# модемы переключаются, и правильное значение у каждого своё. Поэтому при смене
# активного модема выставляем её по нему:
#   1) ручная настройка пользователя для ЭТОГО модема (5gmodem.m_X.ussd_raw) -
#      она главнее базы: человек мог проверить руками то, чего мы не знаем;
#   2) иначе - проверенная база (quirks.sh);
#   3) если модем в базе неизвестен - НЕ ТРОГАЕМ: у пользователя может быть
#      рабочая настройка, и молча ломать её нельзя.
apply_ussd_quirk() {   # $1 = секция модема
	command -v ussd_raw_for >/dev/null 2>&1 || return 0
	_v=$(uci -q get "$CFG.$1.ussd_raw")
	if [ -z "$_v" ]; then
		_v=$(ussd_raw_for "$(uci -q get "$CFG.$1.model")" "$(uci -q get "$CFG.$1.vidpid")")
	fi
	case "$_v" in
		0|1) uci -q set "sms_tool_js.@sms_tool_js[0].ussd=$_v" ;;
	esac
}
active_path() { uci -q get "$CFG.@5gmodem[0].active_modem"; }

# ports (tty) of the modem at a given usb path, from listmodems.sh
modem_ttys() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null
}
modem_product() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].product" 2>/dev/null | head -1
}
modem_vidpid() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].vidpid" 2>/dev/null | head -1
}

# Модем на этом USB-пути ПОДМЕНИЛИ на другой?
# Секция помнит vidpid; если на шине по тому же пути другой - всё, что мы про
# него запомнили (at_port, network, iface_proto, тип слотов), относится к
# ПРЕЖНЕМУ модему и заведомо неверно. Это НЕ то же самое, что временное
# отсутствие: модем регулярно пропадает на минуту при AT+CFUN=1,1 (в т.ч. по
# нашей команде - после добавления eSIM-профиля), и удалять настройки в такой
# момент нельзя. Поэтому чистим ТОЛЬКО по факту подмены.
swap_cleanup() {   # $1 = usb path, $2 = section
	_new=$(modem_vidpid "$1")
	[ -n "$_new" ] || return 0                  # модема нет на шине - не трогаем
	_old=$(uci -q get "$CFG.$2.vidpid")
	if [ -z "$_old" ]; then                     # старая секция без vidpid - просто запомним
		uci -q set "$CFG.$2.vidpid=$_new"
		uci -q set "$CFG.$2.product=$(modem_product "$1")"
		uci -q commit "$CFG"
		return 0
	fi
	[ "$_old" = "$_new" ] && return 0
	logger -t 5gmodem "modem swap on $1: $_old -> $_new, dropping stale settings"
	for o in at_port data_at_port network iface_proto slot_type_0 slot_type_1 slot_type_2; do
		uci -q delete "$CFG.$2.$o" 2>/dev/null
	done
	uci -q set "$CFG.$2.vidpid=$_new"
	uci -q set "$CFG.$2.product=$(modem_product "$1")"
	uci -q set "$CFG.$2.model="                 # имя модели переопределится опросом
	uci -q delete "$CFG.$2.model" 2>/dev/null
	uci -q commit "$CFG"
}

# AT probe of ONE port, time-bounded to ~4s. sms_tool has no timeout option and
# blocks ~35s on a silent DIAG port with no reply, which made switching modems
# take half a minute (the UI "Switching…" spinner hung). Run it in the
# background and kill it if it does not answer quickly.
at_probe() {
	sms_tool -d "$1" at "AT" >/dev/null 2>&1 &
	_p=$!
	_n=0
	while kill -0 "$_p" 2>/dev/null; do
		_n=$((_n + 1))
		if [ "$_n" -ge 4 ]; then kill "$_p" 2>/dev/null; wait "$_p" 2>/dev/null; return 1; fi
		sleep 1
	done
	wait "$_p" 2>/dev/null   # sms_tool exit code: 0 when the port answered AT
	return $?
}

# first tty that answers "AT" = the modem's AT port
detect_at() {
	for t in "$@"; do
		[ -e "$t" ] || continue
		case "$t" in /dev/ttyUSB*|/dev/ttyACM*) ;; *) continue ;; esac
		if at_probe "$t"; then echo "$t"; return 0; fi
	done
	return 1
}

# ModemManager modem index whose USB device path matches a usb topology path
mm_index_for_path() {
	[ -n "$1" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	for m in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		d=$(mmcli -m "$m" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p' | xargs)
		case "$d" in */"$1") echo "$m"; return 0 ;; esac
	done
	return 1
}

# cdc-wdm control node of the modem at a usb path
wdm_for_path() {
	"$RES/listmodems.sh" | jsonfilter -e "@[@.path=\"$1\"].wdm[0]" 2>/dev/null
}

# ModemManager must run if ANY modem interface uses the modemmanager proto (they
# need MM). Creating an mbim/qmi/atc interface used to blindly disable MM and
# thereby break the modemmanager modems -> keep MM's state driven by ALL
# interfaces, not just the one being created.
apply_mm_state() {
	command -v mmcli >/dev/null 2>&1 || return 0
	if uci show network 2>/dev/null | grep -q "\.proto='modemmanager'"; then
		/etc/init.d/modemmanager enabled >/dev/null 2>&1 || /etc/init.d/modemmanager enable >/dev/null 2>&1
		pgrep -f ModemManager >/dev/null 2>&1 || /etc/init.d/modemmanager start >/dev/null 2>&1
	elif uci show network 2>/dev/null | grep -qE "\.proto='(mbim|qmi)'"; then
		# kernel owns the control channel -> MM must be off
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		/etc/init.d/modemmanager disable >/dev/null 2>&1
	fi
}

# repair a modem's interface: re-point its device to the current node for THIS
# modem's stable USB path (cdc-wdm / ttyUSB numbers are unstable), then bring it
# up if the device changed or it is not up. This is what auto-recovers the
# connection after a reboot / modem swap when the pinned device went stale.
ensure_iface() {
	# ВСЕ переменные - local. Без этого функция затирала ГЛОБАЛЬНЫЕ SEC/P/IF
	# вызывающего, а resolve зовёт её в цикле по ВСЕМ присутствующим модемам:
	# после цикла SEC указывала на ПОСЛЕДНИЙ модем цикла, а не на активный, и
	# строка "point the app at the active modem's interface" прописывала в
	# @5gmodem[0].network интерфейс ЧУЖОГО модема (at_port/active_modem при этом
	# оставались от активного). Так секция и разъезжалась на каждой загрузке.
	local P="$1" SEC="$2" IF PROTO CUR NEW CHG MET t tt OWNER
	IF=$(uci -q get "$CFG.$SEC.network")
	[ -n "$IF" ] || return 0
	uci -q get "network.$IF" >/dev/null 2>&1 || return 0

	# ШТАМП ВЛАДЕЛЬЦА (network.<if>.modem_path, ставит mkiface.sh). Если интерфейс
	# создан для ДРУГОГО модема - не трогаем его. Иначе мы бы своими руками
	# перенаправили device чужого интерфейса на этот модем и подняли его с чужими
	# настройками (APN прежнего оператора) - ровно та беда, от которой штамп и
	# заведён. Пустой штамп = интерфейс из старых версий: считаем своим (миграция
	# в uci-defaults проставит штампы существующим).
	OWNER=$(uci -q get "network.$IF.modem_path")
	if [ -n "$OWNER" ] && [ "$OWNER" != "$P" ]; then
		logger -t 5gmodem-resolve "iface $IF belongs to modem $OWNER, not $P - not touching it"
		return 0
	fi

	PROTO=$(uci -q get "network.$IF.proto")
	CUR=$(uci -q get "network.$IF.device")
	NEW=""
	case "$PROTO" in
		mbim|qmi|xmm|ncm) NEW=$(wdm_for_path "$P") ;;
		modemmanager)     NEW=$(readlink -f "/sys/bus/usb/devices/$P" 2>/dev/null) ;;
		atc)
			# atc holds its AT port open for URC monitoring, so it must stay on a
			# tty DISTINCT from the app's metrics/SMS port (data_at_port marks such
			# a modem). Re-resolve an AT-answering tty under this modem's path that
			# is not the metrics port, and remember it.
			if [ -n "$(uci -q get "$CFG.$SEC.data_at_port")" ]; then
				MET=$(uci -q get "$CFG.@5gmodem[0].at_port")
				for t in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/ttyACM*; do
					[ -e "$t" ] || continue
					tt="/dev/$(basename "$t")"
					[ "$tt" = "$MET" ] && continue
					at_probe "$tt" && { NEW="$tt"; break; }
				done
				[ -n "$NEW" ] || NEW=$(uci -q get "$CFG.$SEC.at_port")
				[ -n "$NEW" ] && uci -q set "$CFG.$SEC.data_at_port=$NEW"
			else
				NEW=$(uci -q get "$CFG.$SEC.at_port")
			fi
			;;
		3g|wwan|ppp)      NEW=$(uci -q get "$CFG.$SEC.at_port") ;;
		fibocom)          NEW=$(for n in /sys/bus/usb/devices/$P:*/net/*; do [ -e "$n" ] && { basename "$n"; break; }; done) ;;
	esac
	CHG=0
	if [ -n "$NEW" ] && { [ -e "$NEW" ] || [ -d "/sys/class/net/$NEW" ]; } && [ "$NEW" != "$CUR" ]; then
		uci -q set "network.$IF.device=$NEW"; uci -q commit network; CHG=1
	fi
	if [ "$CHG" = 1 ] || ! ifstatus "$IF" 2>/dev/null | grep -q '"up": true'; then
		ifup "$IF" >/dev/null 2>&1
	fi
}

# ИНТЕРФЕЙС-СИРОТА для модема $1: указывает на устройство ЭТОГО модема, но создан
# НЕ для него и не принадлежит ни одной секции модема.
#
# Так выглядит подмена модема, которую swap_cleanup не ловит: он срабатывает на
# смену vid:pid по ТОМУ ЖЕ пути, а если модем воткнули в другой разъём (1-1.3.3 ->
# 1-1.3), для программы это просто новый модем. Интерфейс же старого остаётся и
# висит на device-ноде (/dev/cdc-wdm0), которую ядро отдаёт новому модему - и тот
# молча дозванивается с APN прежнего оператора.
# Сам конфиг НЕ ПРАВИМ: интерфейс мог быть настроен пользователем вручную.
# Только помечаем находку, чтобы показать её в интерфейсе.
orphan_iface_for() {
	local P="$1" IF OWNER DEV NODES n claimed
	NODES=" $(wdm_for_path "$P") "
	for n in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/ttyACM*; do
		[ -e "$n" ] && NODES="$NODES /dev/$(basename "$n") "
	done
	for n in /sys/bus/usb/devices/$P:*/net/*; do
		[ -e "$n" ] && NODES="$NODES $(basename "$n") "
	done
	for IF in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		DEV=$(uci -q get "network.$IF.device")
		[ -n "$DEV" ] || continue
		echo "$NODES" | grep -q " $DEV " || continue
		OWNER=$(uci -q get "network.$IF.modem_path")
		[ "$OWNER" = "$P" ] && continue     # штамп наш - всё честно
		# держит ли этот интерфейс какая-нибудь секция модема?
		claimed=$(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.]*\)\.network='$IF'\$/\1/p" | head -1)
		[ -n "$claimed" ] && continue
		echo "$IF"; return 0
	done
	return 1
}

# AT port of the modem at a usb path: fast via ModemManager, else probe its ttys
at_for_path() {
	mi=$(mm_index_for_path "$1")
	if [ -n "$mi" ]; then
		p=$(mmcli -m "$mi" 2>/dev/null | grep -oE '(ttyUSB[0-9]+|ttyACM[0-9]+) \(at\)' | sed 's/ (at)//' | head -1)
		[ -n "$p" ] && [ -e "/dev/$p" ] && { echo "/dev/$p"; return 0; }
	fi
	detect_at $(modem_ttys "$1")
}

# make sure a 'modem' section exists for a path; echo its name
ensure_section() {
	SEC=$(secname "$1")
	if ! uci -q get "$CFG.$SEC" >/dev/null 2>&1; then
		uci -q set "$CFG.$SEC=modem"
		uci -q set "$CFG.$SEC.path=$1"
		uci -q set "$CFG.$SEC.product=$(modem_product "$1")"
		uci -q set "$CFG.$SEC.vidpid=$(modem_vidpid "$1")"
	else
		swap_cleanup "$1" "$SEC"
	fi
	echo "$SEC"
}

# snapshot the current AT port into a modem section. NOTE: we deliberately do
# NOT copy 'network'/'iface_proto' here - those belong to the interface and are
# owned by mkiface.sh (which assigns a UNIQUE interface per modem). Copying the
# working 'network' here used to propagate a shared "modem" into every modem's
# section, so two modems ended up on one interface (shared IP).
save_to() {
	SEC=$(ensure_section "$1")
	uci -q set "$CFG.$SEC.at_port=$(uci -q get $CFG.@5gmodem[0].at_port)"
	uci -q commit "$CFG"
}

# Pick the SMS read storage for the active modem. Incoming messages land in
# different places by modem: many USB modems (e.g. SimCom SIM7100) deliver them
# to ME (modem memory), not SM (SIM) - reading SM then shows an empty inbox and
# the UI complains there is no port. Probe both and prefer the one that holds
# messages; default to ME (the common case). Only sets the value when the user
# has not chosen one, so it never overrides a manual SIM/Memory pick.
set_sms_storage() {
	AT="$1"
	[ -n "$AT" ] && [ -e "$AT" ] || return 0
	command -v sms_tool >/dev/null 2>&1 || return 0
	uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1 || return 0
	[ -z "$(uci -q get sms_tool_js.@sms_tool_js[0].storage)" ] || return 0
	me=$(sms_tool -d "$AT" -s ME status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	sm=$(sms_tool -d "$AT" -s SM status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	if   [ "${me:-0}" -gt 0 ] 2>/dev/null; then STG=ME
	elif [ "${sm:-0}" -gt 0 ] 2>/dev/null; then STG=SM
	elif [ -n "$me" ]; then STG=ME          # ME supported, just empty
	elif [ -n "$sm" ]; then STG=SM          # only SM answered
	else STG=ME
	fi
	uci -q set "sms_tool_js.@sms_tool_js[0].storage=$STG"
	uci -q commit sms_tool_js
}

case "$1" in
active)
	active_path
	;;

save)
	[ -n "$2" ] || { echo '{"error":"no path"}'; exit 1; }
	save_to "$2"
	echo '{"result":"saved"}'
	;;

switch)
	P="$2"
	[ -n "$P" ] || { echo '{"error":"no path"}'; exit 1; }

	# remember the currently-active modem's settings first (if any)
	CUR=$(active_path)
	[ -n "$CUR" ] && [ "$CUR" != "$P" ] && save_to "$CUR"

	SEC=$(ensure_section "$P")

	# AT port: prefer the port already saved for THIS modem when it is still
	# valid (present AND still one of this modem's own ports). ttyUSB numbers
	# only change on re-enumeration (unplug / reboot), which the resolve hotplug
	# fixes - so a plain tab switch needs no slow AT re-probe. Fall back to a
	# full detect only when the saved port is gone or now belongs elsewhere.
	SAVED=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$SAVED" ] && [ -e "$SAVED" ] && modem_ttys "$P" | grep -qxF "$SAVED"; then
		ATP="$SAVED"
	else
		ATP=$(at_for_path "$P")
	fi

	# apply to the working config. detect.sh (and thus 5gmodem.sh) resolves the
	# modem port from 5gmodem.device FIRST - so we pin BOTH device and at_port
	# to this modem's AT port, otherwise detect.sh falls through to
	# "mmcli -m any" and reads a different modem.
	# ИНВАРИАНТ: active_modem, at_port/device и network в @5gmodem[0] обязаны
	# описывать ОДИН И ТОТ ЖЕ модем. Раньше at_port обновлялся только при непустом
	# $ATP, а active_modem/network - всегда: если порт нового модема в этот момент
	# не разрешался (он как раз переэнумерируется после CFUN=1,1 / загрузки), то
	# at_port ОСТАВАЛСЯ от ПРЕДЫДУЩЕГО модема. Секция описывала два разных модема,
	# и все потребители at_port (основной опрос, netpri, sms_tool) читали ЧУЖОЙ:
	# оператор соседа попадал в кэш этого интерфейса - отсюда «Beeline у обоих».
	# Пустой at_port безопаснее чужого: его потребители трактуют как «порта нет»,
	# а resolve/hotplug проставит верный, когда модем вернётся на шину.
	uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	# Явный выбор пользователя: resolve вернёт активность сюда, когда модем
	# переживёт переперечисление USB (напр. после AT+CFUN=1,1) - см. ветку resolve.
	uci -q set "$CFG.@5gmodem[0].preferred_modem=$P"
	if [ -n "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
	else
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi
	# Тот же инвариант, что и для at_port: network обязан описывать АКТИВНЫЙ модем.
	# У свежевоткнутого модема интерфейса ещё нет - и раньше network оставался от
	# ПРЕДЫДУЩЕГО модема. Основной опрос читает IP/статистику именно по network,
	# поэтому в карточке нового модема показывался IP соседа. Пусто честнее чужого:
	# метрики просто не покажут IP, пока интерфейс не создан.
	NET=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$NET" ]; then
		uci -q set "$CFG.@5gmodem[0].network=$NET"
	else
		uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
	fi
	PRO=$(uci -q get "$CFG.$SEC.iface_proto")
	[ -n "$PRO" ] && uci -q set "$CFG.@5gmodem[0].iface_proto=$PRO"
	uci -q commit "$CFG"

	# SMS/USSD ports follow the AT port
	if [ -n "$ATP" ] && uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q set "sms_tool_js.@sms_tool_js[0].$k=$ATP"
		done
		apply_ussd_quirk "$SEC"
		uci -q commit sms_tool_js
		set_sms_storage "$ATP"
	fi

	# drop the cached AT port so detect.sh re-resolves for the new modem
	rm -f /tmp/modem

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

resolve)
	# Re-resolve ports/devices for all PRESENT modems by their STABLE USB path.
	# ttyUSB numbering shifts when a modem is added/removed or on reboot, so a
	# pinned ttyUSB goes stale ("Bad file descriptor", no data). Run on boot
	# (coldplug) and on USB hotplug add/remove -> the app self-heals, no manual
	# re-creation needed.
	PRESENT=$("$RES/listmodems.sh" | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')

	# refresh at_port for every present, configured modem
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		# модем на этом пути мог смениться на другой - тогда всё запомненное о
		# прежнем недействительно (см. swap_cleanup)
		swap_cleanup "$P" "$SEC"
		# Порты появляются НЕ мгновенно: после hotplug-add ядро заводит ttyUSB*
		# ещё несколько секунд (FM350 отдаёт 7 штук), а hotplug ждёт всего 5с.
		# Ждём порт, но не бесконечно (resolve всегда вызывается из фона).
		A=""; _try=0
		while [ "$_try" -lt 6 ]; do
			A=$(at_for_path "$P")
			[ -n "$A" ] && break
			_try=$((_try + 1)); sleep 2
		done
		if [ -n "$A" ]; then
			uci -q set "$CFG.$SEC.at_port=$A"
		else
			# Порт не отдался. Раньше СТАРОЕ значение молча оставалось в конфиге -
			# а после «включили роутер без модема, воткнули позже» нумерация ttyUSB
			# другая, и там лежал порт от прошлой загрузки, часто уже принадлежащий
			# СОСЕДНЕМУ модему: метрики читали чужой tty (0% сигнала, ни uptime, ни
			# rx/tx - до ручного переключения модема в UI, которое всё чинило).
			# Сохранённый оставляем, ТОЛЬКО если он ещё существует и принадлежит
			# ЭТОМУ модему (значит, AT-проба просто столкнулась за порт); иначе
			# чистим - пусто честнее чужого (см. инвариант в ветке switch).
			SAVED=$(uci -q get "$CFG.$SEC.at_port")
			if [ -n "$SAVED" ] && { [ ! -e "$SAVED" ] || ! modem_ttys "$P" | grep -qxF "$SAVED"; }; then
				uci -q delete "$CFG.$SEC.at_port" 2>/dev/null
			fi
		fi
	done
	uci -q commit "$CFG"

	# Активный модем. preferred_modem - ЯВНЫЙ выбор пользователя (ставится веткой
	# switch). Модем может пропасть с шины НЕНАДОЛГО: AT+CFUN=1,1 (перезагрузка
	# модема, в т.ч. наша - после добавления eSIM-профиля) переперечисляет USB на
	# десятки секунд. Раньше resolve в этот момент НАВСЕГДА переставлял активность
	# на соседа, и после возвращения модема она к нему не возвращалась - выбор
	# пользователя молча терялся. Теперь: вернулся предпочтительный - отдаём
	# активность ему; нет - временно берём первый присутствующий, НЕ трогая
	# preferred_modem, чтобы следующий resolve всё вернул на место.
	AMP=$(active_path)
	PREF=$(uci -q get "$CFG.@5gmodem[0].preferred_modem")
	if [ -n "$PREF" ] && echo " $PRESENT " | grep -q " $PREF " && [ "$AMP" != "$PREF" ]; then
		AMP="$PREF"
		uci -q set "$CFG.@5gmodem[0].active_modem=$AMP"
		uci -q commit "$CFG"
	elif [ -z "$AMP" ] || ! echo " $PRESENT " | grep -q " $AMP "; then
		AMP=$(echo "$PRESENT" | awk '{print $1}')
		[ -n "$AMP" ] && uci -q set "$CFG.@5gmodem[0].active_modem=$AMP" && uci -q commit "$CFG"
	fi
	[ -n "$AMP" ] || { echo '{"result":"no-modems"}'; exit 0; }

	# apply the active modem's fresh AT port to the working config + SMS ports
	SEC=$(secname "$AMP")
	ATP=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$ATP" ] && [ -e "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
		if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
			for k in readport sendport ussdport atport; do uci -q set "sms_tool_js.@sms_tool_js[0].$k=$ATP"; done
			uci -q commit sms_tool_js
			set_sms_storage "$ATP"
		fi
	else
		# см. инвариант в ветке switch: лучше пусто, чем порт ЧУЖОГО модема
		# (active_modem/network ниже переезжают на $AMP в любом случае).
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi

	# --- recover the connections ---
	# 0) refresh the ModemManager ignore rules from the current per-modem protos,
	#    so MM keeps its hands off modems we drive via a kernel proto (qmi/mbim/
	#    atc/fibocom/...). Runs on boot (coldplug) and every hotplug.
	# 1) put ModemManager in the state the modem mix needs (creating an atc/mbim
	#    interface had disabled MM and taken the modemmanager modems down).
	apply_mm_state
	# 2) repair EVERY present modem's interface device (stale after renumbering)
	#    and bring it up if it is down - so all modems reconnect automatically.
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " || continue
		ensure_iface "$p" "$s"
		# Пометить чужой интерфейс, прилипший к этому модему через
		# переиспользованную device-ноду (см. orphan_iface_for). Метку читает
		# страница настроек модема и предупреждает пользователя.
		fi_=$(orphan_iface_for "$p")
		if [ -n "$fi_" ]; then
			uci -q set "$CFG.$s.foreign_iface=$fi_"
			logger -t 5gmodem-resolve "modem $p: iface '$fi_' was made for another modem (stale APN/settings)"
		else
			uci -q delete "$CFG.$s.foreign_iface" 2>/dev/null
		fi
	done

	# point the app at the active modem's interface. SEC пересчитываем от $AMP
	# заново (а не полагаемся на значение до цикла ensure_iface выше) - страховка
	# на случай, если какой-нибудь хелпер снова начнёт трогать глобальные имена.
	SEC=$(secname "$AMP")
	# ТОТ ЖЕ ИНВАРИАНТ, ЧТО И В switch (см. выше): network обязан описывать
	# АКТИВНЫЙ модем. Раньше здесь стоял `[ -n "$IF" ] && set`, и у только что
	# воткнутого модема (интерфейса у него ещё нет) network ОСТАВАЛСЯ ОТ ПРЕДЫДУЩЕГО.
	# Живой случай: active_modem=1-1.3 (Telit), а network=modem2 - интерфейс Compal.
	# Основной опрос читает по network IP и статистику, и страница показывала бы
	# сигнал Telit вперемешку с адресом и трафиком Compal. Пусто безопаснее чужого.
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		uci -q set "$CFG.@5gmodem[0].network=$IF"
	else
		uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
	fi
	uci -q commit "$CFG"
	rm -f /tmp/modem
	printf '{"result":"resolved","active":"%s","at_port":"%s"}\n' "$AMP" "$ATP"
	;;

mmindex)
	# ModemManager index of the ACTIVE modem (for band/mode targeting)
	mm_index_for_path "$(active_path)"
	;;

wdm)
	# cdc-wdm control node of the ACTIVE modem (for qmicli targeting)
	wdm_for_path "$(active_path)"
	;;

forget)
	# «Забыть отключённые модемы»: удалить секции модемов, которых нет на шине.
	# ЯВНОЕ действие пользователя - автоматически по отключению так делать нельзя:
	# модем штатно пропадает на минуту при AT+CFUN=1,1 (в т.ч. по нашей команде),
	# и настройки бы терялись на ровном месте.
	# Секцию АКТИВНОГО модема не трогаем: он может как раз перезагружаться.
	# --refresh ОБЯЗАТЕЛЕН: обычный вызов может отдать кэш (до 8 c), а мы по этому
	# списку УДАЛЯЕМ настройки. Устаревший кэш = присутствующий модем сочтётся
	# отсутствующим, и его секция будет стёрта вместе с network/iface_proto/
	# mm_exclude. Цена ошибки несимметрична: лишний раз не забыть - безобидно,
	# забыть работающий модем - потеря настроек.
	PRESENT=" $("$RES/listmodems.sh" --refresh | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
	# Пустой список - это почти наверняка сбой перечисления, а не «модемов нет».
	# Ничего не удаляем: иначе одна осечка стёрла бы настройки ВСЕХ модемов.
	case "$PRESENT" in
		*[!\ ]*) ;;
		*) printf '{"result":"ok","forgotten":0,"note":"no modems enumerated - nothing removed"}\n'; exit 0 ;;
	esac
	AMP=$(active_path)
	N=0
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo "$PRESENT" | grep -q " $P " && continue
		[ "$P" = "$AMP" ] && continue
		# Страховка: интерфейс этого модема сейчас ПОДНЯТ - значит модем живой, а
		# в перечислении его нет по случайности (переэнумерация/сбой). Забывать
		# рабочий модем нельзя: вместе с секцией уйдут network/iface_proto/
		# mm_exclude, и он потеряется в UI. Именно так эта кнопка однажды стёрла
		# настройки присутствующего модема.
		_if=$(uci -q get "$CFG.$SEC.network")
		if [ -n "$_if" ] && ifstatus "$_if" 2>/dev/null | grep -q '"up": true'; then
			continue
		fi
		# интерфейс модема оставляем в network/firewall: он мог быть настроен
		# вручную, а модем ещё вернётся. Забываем только НАШУ привязку.
		uci -q delete "$CFG.$SEC"
		N=$((N + 1))
	done
	[ "$N" -gt 0 ] && uci -q commit "$CFG"
	printf '{"result":"ok","forgotten":%s}\n' "$N"
	;;

*)
	echo "usage: $0 active|switch <path>|save <path>|resolve|forget|mmindex|wdm" >&2
	exit 1
	;;
esac
