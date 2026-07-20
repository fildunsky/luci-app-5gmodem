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

. /usr/share/5gmodem/lib.sh   # secname / sec_for_iface / active_path

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

	# СМЕНА РЕЖИМА - НЕ СМЕНА МОДЕМА.
	#
	# Один и тот же модем может менять USB-композицию: переключение режима в его
	# веб-интерфейсе, usb-modeswitch, смена CUSTOMER. Наблюдалось вживую: Huawei
	# E3372 перешёл с 12d1:14dc на 12d1:1566, и мы стёрли ему kind/netdev/network,
	# после чего профиль потерял признак HiLink и подхватил чужой AT-порт от
	# соседнего модема.
	# IMEI - настоящая личность железа. Совпал - это тот же модем, и настройки
	# его. Обновляем только идентификаторы композиции.
	# ТОТ ЖЕ ВЕНДОР НА ТОМ ЖЕ USB-ПУТИ = смена композиции, а не модема. USB-путь
	# стабилен (это физический разъём), и если вендор не сменился, а поменялся
	# только PID - это тот же модем в другом режиме (E3372: 14dc <-> 1566 <-> 1442).
	# IMEI тут ненадёжен: в переходных композициях он не читается ни по AT, ни по
	# веб-API, и раньше проверка по нему проваливалась - настройки стирались.
	# Свойства САМОГО ЖЕЛЕЗА (kind, netdev, at_debug) при смене режима сохраняем,
	# обновляя лишь идентификаторы композиции.
	_vid_old=${_old%%:*}
	_vid_new=${_new%%:*}
	if [ "$_vid_old" = "$_vid_new" ]; then
		logger -t 5gmodem "modem mode change on $1: $_old -> $_new (тот же вендор, свойства железа сохраняем)"
		uci -q set "$CFG.$2.vidpid=$_new"
		uci -q set "$CFG.$2.product=$(modem_product "$1")"
		# at_port сбрасываем - в новой композиции нумерация портов другая, его
		# заново найдёт resolve. Остальное (kind/netdev/at_debug/network) - нет.
		uci -q delete "$CFG.$2.at_port" 2>/dev/null
		uci -q delete "$CFG.$2.data_at_port" 2>/dev/null
		uci -q commit "$CFG"
		return 0
	fi

	logger -t 5gmodem "modem swap on $1: $_old -> $_new, dropping stale settings"
	# Интерфейс, созданный НАМИ для прежнего модема (штамп modem_path == этот путь),
	# теперь заведомо неверен: у другого модема другой прото/устройство. netifd
	# поднимает его по кругу со стухшим device - живой баг: FM350 -> L850 в тот же
	# USB-разъём, xmm-прото циклит "AT port not valid! / Device path not found!"
	# каждые 5 c. Гасим интерфейс и снимаем автозапуск, чтобы цикл прекратился; при
	# повторной настройке mkiface.sh пересоздаст его с нуля (delete+recreate).
	# ЧУЖИЕ (настроенные вручную) интерфейсы НЕ трогаем - только со своим штампом.
	_oif=$(uci -q get "$CFG.$2.network")
	if [ -n "$_oif" ] && [ "$(uci -q get "network.$_oif.modem_path" 2>/dev/null)" = "$1" ]; then
		ifdown "$_oif" >/dev/null 2>&1
		uci -q set "network.$_oif.auto=0"
		# ЯВНАЯ МЕТКА «пересоздать, а не подхватывать». Без неё autosetup находил
		# этот интерфейс по USB-пути и брал его СЕБЕ вместе с настройками прежнего
		# модема: у Telit LM960A18 на месте Compal оставались proto=mbim,
		# device=/dev/cdc-wdm0 и auto=0 - соединение не поднималось никогда, а в
		# журнале всё выглядело благополучно ("подхвачен существующий modem").
		uci -q set "network.$_oif.modem_stale=1"
		uci -q commit network
		logger -t 5gmodem "swap: stopped stale owned interface '$_oif' (rerun setup to rebuild)"
	fi
	# ВСЁ, что относилось к прежнему модему. imei тут обязателен: без него
	# в секции оставался чужой номер, и сверка подмены при следующей замене
	# сравнивала бы с ним (наблюдалось: в секции Huawei лежал IMEI от FM350).
	# celllock/kind/netdev - настройки конкретного железа, другому не годятся.
	# mm_exclude - осознанный выбор ДЛЯ ТОГО модема, новый его не наследует.
	for o in at_port data_at_port network iface_proto imei celllock kind netdev \
	         mm_exclude slot_type_0 slot_type_1 slot_type_2; do
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
# Привести proto интерфейса в соответствие ДРАЙВЕРУ его cdc-wdm устройства.
#
# Интерфейс может остаться от другого модема - имя одно, железо разное.
# Наблюдалось вживую: Compal RXM-G1 (cdc_mbim) подхватил интерфейс от Telit
# LM960A18 (qmi_wwan) вместе с proto=qmi. uqmi на MBIM-устройстве висел
# минутами, netifd писал "Request timed out" и клал интерфейс - модем не
# поднимался вообще, а причина ниоткуда не видна.
#
# Вызывается и при первичной настройке, и при переключении модемов: проверка
# только на первой настройке не починила бы уже сломанные конфигурации.
fix_iface_proto() {   # $1 - имя интерфейса
	_fp_if="$1"
	[ -n "$_fp_if" ] || return
	_fp_pr=$(uci -q get "network.$_fp_if.proto")
	_fp_dev=$(uci -q get "network.$_fp_if.device")
	_fp_drv=""
	case "$_fp_dev" in
		/dev/cdc-wdm*)
			_fp_drv=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$_fp_dev")/device/driver" 2>/dev/null)" 2>/dev/null)
			;;
	esac
	case "$_fp_drv" in
		cdc_mbim) _fp_want="mbim" ;;
		qmi_wwan) _fp_want="qmi" ;;
		*)        return ;;
	esac
	[ "$_fp_pr" = "$_fp_want" ] && return
	# Правим ТОЛЬКО заведомо несовместимую пару kernel-протоколов. Всё прочее
	# (modemmanager, xmm, atc, ncm...) - осознанный выбор пользователя, и
	# перебивать его мы не вправе, даже если он выглядит непривычно.
	case "$_fp_pr" in
		mbim|qmi) ;;
		*) return ;;
	esac
	logger -t 5gmodem "iface $_fp_if: proto=$_fp_pr не подходит драйверу $_fp_drv - ставим $_fp_want"
	uci -q set "network.$_fp_if.proto=$_fp_want"
	uci -q commit network
}

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
		claimed=$(sec_for_iface "$IF")
		[ -n "$claimed" ] && continue
		# IPv6-БЛИЗНЕЦ НЕ ЧУЖОЙ. Прошивки заводят пару "wwan" (dhcp) и "wwan6"
		# (dhcpv6) НА ОДНОМ И ТОМ ЖЕ устройстве. Секция модема держит только
		# первый, второй формально ничей - и попадал сюда как «интерфейс от
		# другого модема», из-за чего на живом LT300 показывалось пугающее
		# предупреждение о чужих настройках и предложение пересоздать интерфейс.
		# Признак близнеца: имя оканчивается на 6, а интерфейс без этой цифры
		# существует и сидит на том же устройстве. Тот же приём уже применён в
		# netpri.sh, где такая пара удваивала аплинк.
		case "$IF" in
			*6)
				_base=${IF%6}
				if [ "$(uci -q get "network.$_base.device")" = "$DEV" ]; then
					continue
				fi
				;;
		esac
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

# Подобрать APN по оператору. $1 - имя оператора, $2 - код сети (MCC-MNC).
# Сперва по ИМЕНИ: у MVNO оно своё, а код принадлежит хосту сети (SIM Сбера
# работает на Tele2 и отдаёт её PLMN, но APN нужен сберовский).
# Понижение регистра, пригодное для кириллицы.
#
# tr 'A-ZА-Я' 'a-zа-я' НЕ РАБОТАЕТ: busybox tr обрабатывает БАЙТЫ, а кириллица в
# UTF-8 двухбайтовая. Проверено на роутере - "Тинькофф" превращался в
# "\xd0\xa2инь\xd0\xbaофф"-подобный мусор, и все кириллические образцы в
# apn.list (т-мобайл, тинькоф, сбер, газпром) не могли совпасть НИКОГДА.
# sed работает с UTF-8 последовательностями как с литералами, поэтому годится.
_tolower() {
	printf '%s' "$1" | tr 'A-Z' 'a-z' | sed \
		-e 's/А/а/g;s/Б/б/g;s/В/в/g;s/Г/г/g;s/Д/д/g;s/Е/е/g;s/Ё/ё/g' \
		-e 's/Ж/ж/g;s/З/з/g;s/И/и/g;s/Й/й/g;s/К/к/g;s/Л/л/g;s/М/м/g' \
		-e 's/Н/н/g;s/О/о/g;s/П/п/g;s/Р/р/g;s/С/с/g;s/Т/т/g;s/У/у/g' \
		-e 's/Ф/ф/g;s/Х/х/g;s/Ц/ц/g;s/Ч/ч/g;s/Ш/ш/g;s/Щ/щ/g;s/Ъ/ъ/g' \
		-e 's/Ы/ы/g;s/Ь/ь/g;s/Э/э/g;s/Ю/ю/g;s/Я/я/g'
}

# Порядок поиска APN. Сперва код ИЗ SIM (у MVNO он собственный), затем имя,
# затем код зарегистрированной сети. Так MVNO получает свой APN, а обычная
# симка - прежний результат: её код в IMSI и в сети совпадает.
apn_pick() {   # $1 - имя оператора, $2 - PLMN сети, $3 - список PLMN из IMSI
	for _sp in $3; do
		_a=$(apn_lookup "" "$_sp") && { echo "$_a"; return 0; }
	done
	apn_lookup "$1" "$2"
}

apn_lookup() {
	_n=$(_tolower "$1")
	_p="$2"
	[ -f "$RES/apn.list" ] || return 1
	if [ -n "$_n" ]; then
		while IFS=: read -r _t _pat _apn; do
			case "$_t" in name) : ;; *) continue ;; esac
			[ -n "$_pat" ] || continue
			case "$_n" in *"$_pat"*) echo "$_apn"; return 0 ;; esac
		done < "$RES/apn.list"
	fi
	if [ -n "$_p" ]; then
		while IFS=: read -r _t _pat _apn; do
			case "$_t" in plmn) : ;; *) continue ;; esac
			[ "$_pat" = "$_p" ] && { echo "$_apn"; return 0; }
		done < "$RES/apn.list"
	fi
	return 1
}

# Найти интерфейс, который УЖЕ смотрит на этот модем ($1 = USB-путь).
# Нужен, чтобы не плодить дубли: на роутерах, где модем настроен вендором или
# самим пользователем до установки пакета, интерфейс уже есть и работает
# (у Cudy LT300 это "wwan" на usb0). Создав рядом второй, мы получили бы два
# интерфейса на одном устройстве и войну за маршрут по умолчанию.
#
# Ищем по ФАКТИЧЕСКОМУ устройству, а не по имени: network.<iface>.device может
# быть и сетевым узлом (eth2, usb0), и управляющим (/dev/cdc-wdm0), а у части
# протоколов его нет вовсе - тогда смотрим на поднятый l3_device.
iface_for_path() {
	_want="$1"; [ -n "$_want" ] || return 1
	for _if in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		case "$_if" in loopback|lan|wan6) continue ;; esac
		_dev=$(uci -q get "network.$_if.device")
		[ -n "$_dev" ] || _dev=$(ifup_state_dev "$_if")
		[ -n "$_dev" ] || continue
		_p=""
		case "$_dev" in
			/dev/cdc-wdm*)
				_p=$(readlink -f "/sys/class/usbmisc/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
			/dev/tty*)
				_p=$(readlink -f "/sys/class/tty/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/ttyUSB[0-9]*$||;s|.*/||;s|:.*||') ;;
			*)
				[ -e "/sys/class/net/$_dev" ] || continue
				_p=$(readlink -f "/sys/class/net/$_dev/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
		esac
		[ "$_p" = "$_want" ] && { echo "$_if"; return 0; }
	done
	return 1
}

# l3_device поднятого интерфейса (для тех, у кого device в конфиге не задан)
ifup_state_dev() {
	ubus call network.interface."$1" status 2>/dev/null \
		| jsonfilter -e '@["l3_device"]' 2>/dev/null
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

# Настроить ОДИН модем по usb-пути. Вынесено из autosetup ради цикла по всем
# найденным: тело одинаковое, разница только в том, чей это модем.
# Это HiLink-модем (управляется своим IP-стеком, интерфейс DHCP)? Свойство
# ЖЕЛЕЗА, а не текущей композиции: в режиме debug у него появляются AT-порты, но
# интернет он всё равно держит сам. Смотрим на запомненный kind ИЛИ на наличие
# сетевой карты - НЕ на отсутствие портов.
# Известные HiLink-модемы - ПОШТУЧНО, по vid:pid.
#
# Эвристики тут были ошибкой. Сначала признаком считалась сетевая карта, но она
# есть и у обычного модема: qmi_wwan создаёт wwan0. Telit LM960 (1bc7:1040)
# из-за этого объявлялся HiLink и переставал настраиваться вовсе - подпись
# "(Debug)", настройка через несуществующий веб-API, модем "не определяется".
# Цена ошибки несимметрична: лишний модем в списке ломает ему всю настройку, а
# недостающий - всего лишь не даст автопереключения в debug.
#
# 12d1:14dc - Huawei E3372 в режиме "только веб-интерфейс". В 12d1:1566 он уже
# с AT-портами, и там срабатывает запомненный kind из секции.
HILINK_IDS="12d1:14dc"

is_hilink() {   # $1 - usb-путь
	_ih_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ih_sec.kind")" = "hilink" ] && return 0
	_ih_id=$(modem_vidpid "$1")
	[ -n "$_ih_id" ] || return 1
	for _ih_k in $HILINK_IDS; do
		[ "$_ih_id" = "$_ih_k" ] && return 0
	done
	return 1
}

# Сетевая карта HiLink-модема (eth*/usb* через cdc_ether), если есть.
hilink_netdev() {   # $1 - usb-путь
	for _hd in /sys/bus/usb/devices/"$1":*/net/*; do
		[ -e "$_hd" ] || continue
		basename "$_hd"; return 0
	done
	return 1
}

# Сетевое имя модема, если он БЕЗ ПОРТОВ (HiLink). Пусто - обычный модем.
# Признак строгий: есть net[], и при этом нет ни tty, ни wdm.
hilink_net() {   # $1 - usb-путь
	_hl=$("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$1\"].net[0]" 2>/dev/null)
	[ -n "$_hl" ] || return 1
	_ht=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].tty[0]" 2>/dev/null)
	_hw=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].wdm[0]" 2>/dev/null)
	[ -n "$_ht$_hw" ] && return 1
	echo "$_hl"
}

# Интерфейс для модема без портов. Никакого mkiface: у HiLink нет ни AT, ни
# cdc-wdm, дозваниваться некуда - модем держит соединение сам и раздаёт адрес
# по DHCP. Роутеру остаётся обычный dhcp-клиент на его сетевой карте.
setup_hilink() {   # $1 - usb-путь, $2 - сетевое имя (eth3)
	_hp="$1"; _hd="$2"
	_hsec=$(ensure_section "$_hp")
	uci -q set "$CFG.$_hsec.kind=hilink"
	uci -q set "$CFG.$_hsec.netdev=$_hd"
	_hif=$(uci -q get "$CFG.$_hsec.network")
	if [ -z "$_hif" ]; then
		# имя по образцу остальных: modem, modem2, ...
		_hn=1; _hif="modem"
		while uci -q get "network.$_hif" >/dev/null 2>&1; do
			_hn=$((_hn + 1)); _hif="modem$_hn"
		done
	fi
	uci -q set "network.$_hif=interface"
	uci -q set "network.$_hif.proto=dhcp"
	uci -q set "network.$_hif.device=$_hd"
	uci -q commit network
	# ЗОНА ФАЕРВОЛА. Без неё интерфейс остаётся «серым»: не в wan, значит нет ни
	# NAT, ни разрешающих правил - клиенты в интернет не выходят, хотя у самого
	# роутера связь есть. Добавляем в ту же зону, где остальные модемы.
	_hz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	if [ -n "$_hz" ]; then
		case " $(uci -q get "firewall.$_hz.network") " in
			*" $_hif "*) ;;
			*) uci -q add_list "firewall.$_hz.network=$_hif"
			   uci -q commit firewall
			   logger -t 5gmodem "hilink: $_hif добавлен в зону wan" ;;
		esac
	fi
	uci -q set "$CFG.$_hsec.network=$_hif"
	uci -q set "$CFG.$_hsec.iface_proto=dhcp"
	uci -q commit "$CFG"
	ifup "$_hif" >/dev/null 2>&1
	logger -t 5gmodem "hilink: $_hp ($_hd) -> интерфейс $_hif (dhcp)"
	echo "$_hif"
}

# Перевести HiLink-модем в режим с AT-портами (у Huawei это «debug mode»).
#
# ЗАЧЕМ. В обычном режиме такой модем отдаёт только веб-API, где нет ни TAC, ни
# диапазона, ни EARFCN, ни USSD. В режиме debug он показывает ещё и шесть
# последовательных портов, СОХРАНЯЯ при этом сетевую карту и рабочий интернет
# (проверено на E3372: ping и HTTP через него проходят, счётчики трафика растут).
# Тогда модем ведётся обычным путём, наравне с остальными.
#
# Режим НЕ переживает перезагрузку модема, поэтому переключаем при каждом его
# появлении на шине. Управляется галкой at_debug в настройках модема; по
# умолчанию включено, но выключить можно - у кого-то модем настроен под свой
# веб-интерфейс, и менять поведение железа молча нельзя.
try_at_debug() {   # $1 - usb-путь
	_ad_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ad_sec.at_debug")" = "0" ] && return 1
	# Уже с портами - ничего не делаем.
	[ -n "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].tty[0]" 2>/dev/null)" ] && return 1
	# ЖДЁМ ГОТОВНОСТИ ВЕБ-API. Сразу после подключения (cdrom -> HiLink) веб-сервер
	# модема поднимается не мгновенно - секунд 30-40, и вызванный раньше времени
	# mode debug молча не срабатывает. Именно это и ловил хотплаг: модем оставался
	# в HiLink. Ждём, пока probe вернёт hilink:1, и только тогда переключаем.
	_ad_w=0
	while [ "$_ad_w" -lt 25 ]; do
		"$RES/hilink.sh" probe "$1" 2>/dev/null | grep -q '"hilink":1' && break
		sleep 3
		_ad_w=$((_ad_w + 1))
	done
	# Пробуем переключить, до трёх раз: первая команда иногда теряется, пока
	# прошивка достартовывает свои службы.
	_ad_ok=""
	_ad_t=0
	while [ "$_ad_t" -lt 3 ]; do
		"$RES/hilink.sh" mode debug "$1" 2>/dev/null | grep -q '"success":true' && { _ad_ok=1; break; }
		sleep 4
		_ad_t=$((_ad_t + 1))
	done
	[ -n "$_ad_ok" ] || return 1
	logger -t 5gmodem "hilink: $1 переведён в режим с AT-портами"
	# Порты появляются не мгновенно.
	_ad_n=0
	while [ "$_ad_n" -lt 20 ]; do
		sleep 2
		rm -f /tmp/5gmodem_listmodems.cache 2>/dev/null
		[ -n "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].tty[0]" 2>/dev/null)" ] && break
		_ad_n=$((_ad_n + 1))
	done
	# После смены режима передача данных сама не поднимается - включаем.
	"$RES/hilink.sh" connect "$1" >/dev/null 2>&1
	return 0
}

setup_one_modem() {
	P="$1"
	# HiLink-модем ведём ОСОБО: интернет у него всегда через собственную сетевую
	# карту (интерфейс DHCP), а AT-порты - лишь источник метрик/SMS/USSD, когда
	# модем в debug. Сначала пробуем открыть порты, затем ВСЕГДА создаём/подхватываем
	# DHCP-интерфейс. Обычный путь (mkiface) создал бы второй, лишний интерфейс.
	if is_hilink "$P"; then
		uci -q set "$CFG.$(secname "$P").kind=hilink"
		uci -q commit "$CFG"
		try_at_debug "$P" && rm -f /tmp/5gmodem_listmodems.cache 2>/dev/null
		_hnet=$(hilink_netdev "$P")
		[ -n "$_hnet" ] && setup_hilink "$P" "$_hnet" >/dev/null
		"$RES/ensureports.sh" >/dev/null 2>&1
		return 0
	fi

	SEC=$(ensure_section "$P")

	# АКТИВНОСТЬ НЕ ОТБИРАЕМ. Свежевоткнутый модем настраиваем, но активным
	# делаем только если действующего активного нет или он пропал с шины:
	# иначе установка второго модема молча переключала бы на него и рабочую
	# страницу первого, и глобальные порты sms_tool_js.
	_am=$(active_path)
	if [ -z "$_am" ] || ! "$RES/listmodems.sh" 2>/dev/null | grep -q "\"path\":\"$_am\""; then
		uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	fi
	A=$(at_for_path "$P")
	[ -n "$A" ] && {
		uci -q set "$CFG.$SEC.at_port=$A"
		# Глобальный порт принадлежит АКТИВНОМУ модему: перезаписав его при
		# настройке второго, мы увели бы метрики и SMS на чужой порт.
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].at_port=$A"
	}
	uci -q commit "$CFG"

	# СНАЧАЛА ПОДХВАТ. Если интерфейс для этого модема уже существует - берём
	# его себе, а не создаём второй. Так пакет, установленный на роутер с уже
	# настроенным модемом, просто начинает им управлять.
	_ex=$(iface_for_path "$P")
	# Интерфейс, помеченный swap_cleanup как устаревший, НЕ подхватываем: его
	# настройки относятся к прежнему модему на этом же USB-разъёме. Пропускаем
	# подхват - ниже mkiface пересоздаст интерфейс с нуля под текущий модем.
	if [ -n "$_ex" ] && [ "$(uci -q get "network.$_ex.modem_stale")" = "1" ]; then
		logger -t 5gmodem "autosetup: $_ex помечен устаревшим - пересоздаём"
		_ex=""
	fi
	if [ -n "$_ex" ]; then
		uci -q set "$CFG.$SEC.network=$_ex"
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].network=$_ex"
		fix_iface_proto "$_ex"
		_pr=$(uci -q get "network.$_ex.proto")
		[ -n "$_pr" ] && uci -q set "$CFG.$SEC.iface_proto=$_pr"
		uci -q commit "$CFG"
		"$RES/ensureports.sh" >/dev/null 2>&1
		logger -t 5gmodem "autosetup: $P -> подхвачен существующий $_ex"
		# APN проверяем И ДЛЯ ПОДХВАЧЕННОГО интерфейса. Раньше подбор вызывался
		# только при создании нового, и унаследованный интерфейс навсегда
		# оставался с APN прежней симки - именно так Beeline работал с "tt".
		( "$RES/modemswitch.sh" autoapn "$_ex" ) >/dev/null 2>&1 </dev/null &
		return 0
	fi

	# ИМЯ ИНТЕРФЕЙСА ВЫБИРАЕТ mkiface, а не мы. У него для этого есть готовая и
	# более правильная логика: имя закрепляется ЗА СЕКЦИЕЙ МОДЕМА и увеличивается
	# только если занято ДРУГИМ модемом - так два модема гарантированно не делят
	# один интерфейс. Я сперва подбирал имя сам, проверяя network.<имя> в конфиге
	# сети, - это другой вопрос: осиротевший интерфейс от снятого модема выглядел
	# занятым, и в журнал уходило одно имя, а создавалось другое.
	# proto=auto: mkiface определит его по драйверу управляющего узла - надёжнее,
	# чем гадать по vid:pid, и не создаёт нерабочий qmi поверх MBIM.
	# MODEM_PATH: mkiface по умолчанию берёт АКТИВНЫЙ модем, а мы можем настраивать
	# и неактивный. С этой переменной он работает с нужным и не трогает глобальные
	# ключи чужого модема (см. пояснение в mkiface.sh).
	MODEM_PATH="$P" "$RES/mkiface.sh" "" auto >/dev/null 2>&1
	"$RES/ensureports.sh" >/dev/null 2>&1
	# В журнал пишем то, что получилось НА САМОМ ДЕЛЕ.
	_made=$(uci -q get "$CFG.$SEC.network")
	logger -t 5gmodem "autosetup: $P -> ${_made:-не удалось}"
	# APN подбираем В ФОНЕ: команда ждёт до минуты, а hotplug столько держать
	# нельзя. Дескрипторы отвязываем на подоболочке - иначе вызвавший нас
	# процесс будет ждать EOF.
	[ -n "$_made" ] && ( "$RES/modemswitch.sh" autoapn "$_made" ) >/dev/null 2>&1 </dev/null &
}

# Как определилась eSIM у профиля - ДЛЯ ПОКАЗА В КАРТОЧКЕ. Читаем только УЖЕ
# ГОТОВЫЕ данные: uci (ручное переопределение) и кэш автоопределения. В порт не
# ходим ни при каких условиях - список профилей рисуется на каждом открытии
# страницы, и проба CCHO по каждому модему стоила бы секунд.
#   yes/no       - определили сами;
#   forced-yes/no - пользователь переопределил;
#   ""            - ещё не проверяли.
_esim_state() {   # $1 - секция, $2 - USB-путь
	_ee=$(uci -q get "$CFG.$1.esim_show")
	case "$_ee" in
		1) echo "forced-yes"; return ;;
		0) echo "forced-no";  return ;;
	esac
	_ec="/tmp/5gmodem_esimstat_$2"
	[ -s "$_ec" ] || return 0
	if grep -q '"available":1' "$_ec" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

case "$1" in
active)
	active_path
	;;

# Поддерживает ли АКТИВНЫЙ модем USSD. Отвечает по базе проверенных модемов
# (quirks.sh), сам модем не трогает: запрос к data-only модулю как раз и
# подвешивает порт на минуту - ровно то, от чего мы хотим избавить пользователя.
#   {"supported":0} - проверено, что не работает
#   {"supported":1} - про этот модем ничего плохого не знаем (не гарантия)
# Записать опции sms_tool_js СРАЗУ в конфиг (set + commit), в обход стейджинга.
#
# Страницы SMS пишут служебные значения сами: счётчик сообщений, порт при смене
# модема, автовключение склейки. Если делать это через uci.set/uci.save в
# браузере, правка ложится в СЕССИОННЫЙ стейджинг LuCI и наверху появляется
# «непринятые изменения» с кнопкой «Применить» - при том, что пользователь
# ничего не настраивал, а просто открыл вкладку и пришло новое сообщение.
# Пишем только известные ключи: команда доступна из веб-интерфейса.
#
# Usage: modemswitch.sh smsopt key=value [key=value ...]
smsopt)
	shift
	_ch=0
	for _kv in "$@"; do
		_k=${_kv%%=*}; _v=${_kv#*=}
		case "$_k" in
			sms_count|sms_count_index|readport|sendport|ussdport|atport|\
			information|mergesms|mergesms_auto|storage) ;;
			*) continue ;;
		esac
		_cur=$(uci -q get "sms_tool_js.@sms_tool_js[0].$_k")
		[ "$_cur" = "$_v" ] && continue
		uci -q set "sms_tool_js.@sms_tool_js[0].$_k=$_v"
		_ch=1
	done
	[ "$_ch" = 1 ] && uci -q commit sms_tool_js
	printf '{"changed":%s}\n' "$_ch"
	;;

# Спрятать подсказку о формате номера на вкладке «Исходящие» (кнопка «Закрыть»).
# Пишем и КОММИТИМ здесь, а не через uci.set/uci.save в браузере: тот кладёт
# правку в сессионный стейджинг LuCI, и наверху появляется «непринятые
# изменения», которые пользователь должен применять руками. Для нажатия
# «Закрыть» это неуместно - человек закрыл подсказку, а не менял настройки сети.
# Пользователь увидел предупреждение о перестановке модемов - снимаем метку,
# чтобы оно не повторялось на каждом заходе. Решение (пересоздавать интерфейс
# или нет) остаётся за ним.
ackswap)
	[ -n "$2" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q delete "$CFG.$2.imei_changed" 2>/dev/null
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;

hidenumberhint)
	uci -q set "sms_tool_js.@sms_tool_js[0].information=0"
	uci -q commit sms_tool_js
	echo '{"result":"ok"}'
	;;

ussdsupport)
	_p=$(active_path)
	_s=$(secname "$_p")
	# Модем без AT-порта: USSD - услуга AT-канала, отправлять её некуда.
	# Отвечаем ДО опроса базы: иначе страница предлагала бы то, чего нет.
	_us_at=$(uci -q get "$CFG.$_s.at_port")
	if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
	   && ! { [ -n "$_us_at" ] && [ -c "$_us_at" ]; }; then
		printf '{"supported":0,"reason":"no_at_port","model":"%s"}\n' \
			"$(uci -q get "$CFG.$_s.model")"
		exit 0
	fi
	_v=""
	command -v ussd_supported_for >/dev/null 2>&1 && _v=$(ussd_supported_for \
		"$(uci -q get "$CFG.$_s.model")" "$(uci -q get "$CFG.$_s.vidpid")")

	# ВТОРАЯ ПРИЧИНА, ПОМИМО ПРОШИВКИ: РЕГИСТРАЦИЯ «ТОЛЬКО SMS».
	#
	# База выше отвечает на вопрос «умеет ли модем» - это свойство железа и
	# прошивки, оно не меняется. Но USSD может не работать и у вполне
	# способного модема: это услуга голосового домена, и если сеть
	# зарегистрировала абонента как "SMS only", канала для неё нет.
	# Наблюдалось живьём на MeigLink SLM770A-R: AT+CUSD=? отвечает "(0-2)",
	# то есть поддержка заявлена, а любой запрос молчит - при AT+CREG? = 2,6.
	#
	# Коды CREG/CGREG (3GPP 27.007): 1 - дома, 5 - роуминг (оба нормальные),
	# 6 - "SMS only" дома, 7 - "SMS only" в роуминге. Шестёрка и семёрка и
	# означают отсутствие голосового домена.
	#
	# Читаем СНИМОК, а не лезем в порт: страница может открываться при занятом
	# порту, и ещё один опрос ради подсказки - плохой обмен.
	# Берём registration_cs - статус ГОЛОСОВОГО домена. Поле registration для
	# этого не годится: там "SMS only" НАМЕРЕННО подменён статусом данных,
	# чтобы не пугать пользователя при живом интернете (см. 5gmodem.sh).
	_reg=$("$RES/5gmodem.sh" cached 30 2>/dev/null | jsonfilter -e '@.registration_cs' 2>/dev/null)
	_smsonly=0
	case "$_reg" in
		6|7) _smsonly=1 ;;
	esac

	printf '{"supported":%s,"sms_only":%s,"registration":"%s","model":"%s"}\n' \
		"${_v:-1}" "$_smsonly" "$_reg" "$(uci -q get "$CFG.$_s.model")"
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

	# Снимок метрик остался от ПРЕЖНЕГО модема. Снимаем метку владельца -
	# 5gmodem.sh считает такой снимок чужим и сам уходит в свежий опрос
	# (сам файл не трогаем: пусть доживёт как последнее известное значение,
	# если опрос нового модема не удастся).
	rm -f /tmp/5gmodem_metrics.owner 2>/dev/null
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
		# Интерфейс мог достаться от другого модема - сверяем proto с драйвером.
		fix_iface_proto "$NET"
		# И подтягиваем запись модема под РЕАЛЬНЫЙ proto интерфейса: иначе в
		# секции останется прежнее значение, глобальный ключ унаследует его, и
		# настройки покажут "QMI" там, где интерфейс уже работает по MBIM.
		# Переписываем только kernel-протоколы - выбор пользователя не трогаем.
		_np=$(uci -q get "network.$NET.proto")
		case "$(uci -q get "$CFG.$SEC.iface_proto")" in
			mbim|qmi)
				case "$_np" in
					mbim|qmi) uci -q set "$CFG.$SEC.iface_proto=$_np" ;;
				esac
				;;
		esac
		uci -q set "$CFG.@5gmodem[0].network=$NET"
	else
		uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
	fi
	# Как и network выше: пусто честнее чужого. Раньше значение только
	# копировалось при непустом - и у модема, которому протокол ещё не назначен,
	# в глобальной секции оставался протокол ПРЕДЫДУЩЕГО модема. В настройках
	# это выглядело так, будто программа спутала модемы: у Compal значился
	# "Fibocom (AT-dial, FM350)".
	PRO=$(uci -q get "$CFG.$SEC.iface_proto")
	if [ -n "$PRO" ]; then
		uci -q set "$CFG.@5gmodem[0].iface_proto=$PRO"
	else
		uci -q delete "$CFG.@5gmodem[0].iface_proto" 2>/dev/null
	fi
	uci -q commit "$CFG"

	# SMS/USSD ports follow the AT port
	if [ -n "$ATP" ] && uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q set "sms_tool_js.@sms_tool_js[0].$k=$ATP"
		done
		apply_ussd_quirk "$SEC"
		uci -q commit sms_tool_js
		set_sms_storage "$ATP"
	elif [ -z "$ATP" ] && uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
		# У модема НЕТ AT-порта (HiLink). Раньше порты просто оставались от
		# предыдущего модема - и страница SMS показывала ЕГО сообщения, выдавая
		# их за сообщения выбранного модема. Чужая переписка под чужим именем
		# хуже пустого экрана, поэтому чистим.
		for k in readport sendport ussdport atport; do
			uci -q delete "sms_tool_js.@sms_tool_js[0].$k" 2>/dev/null
		done
		uci -q commit sms_tool_js
	fi

	# drop the cached AT port so detect.sh re-resolves for the new modem
	rm -f /tmp/modem

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

# ПОДБОР APN, если связь не поднялась сама.
#
# Порядок именно такой: сперва пробуем подняться БЕЗ APN (у многих операторов
# так и работает), и только если адреса нет - читаем оператора и подставляем APN
# из таблицы. Наоборот нельзя: чтобы узнать оператора, модем должен
# зарегистрироваться в сети, а до регистрации мы не знаем, чей APN ставить.
#
# Рабочую настройку НЕ ТРОГАЕМ никогда: есть адрес - выходим сразу.
# Какой APN мы бы подставили - БЕЗ каких-либо изменений. Нужен интерфейсу
# настроек: раньше он считал APN сам, своей копией таблицы в JavaScript, знавшей
# только имена операторов. Для MVNO это давало APN хост-сети (Т-Мобайл -> Tele2),
# и значение прыгало между заходами на страницу.
# Список профилей модемов - всё, что программа когда-либо видела.
#
# Секции 5gmodem.m_* переживают отключение модема НАМЕРЕННО: в них настройки
# (порт, интерфейс, протокол, привязка соты, IMEI). Но до сих пор их не было
# ВИДНО, и это стоило дорого: секция вынутого Telit продолжала claim'ить имя
# интерфейса, из-за чего Compal подхватил чужой proto=qmi к своему MBIM-железу и
# не поднимался; в 5gtop висели три вкладки при одном модеме. Всё это
# пользователь находил глазами, а не интерфейсом.
#
# Здесь только ЧТЕНИЕ. Отдаём JSON-массив.
# Создать DHCP-интерфейс для модема без портов (кнопка в карточке профиля).
mkhilink)
	_p="$2"
	[ -n "$_p" ] || _p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	_d=$(hilink_net "$_p") || { echo '{"error":"not a hilink modem"}'; exit 0; }
	_r=$(setup_hilink "$_p" "$_d")
	printf '{"success":true,"iface":"%s","netdev":"%s"}\n' "$_r" "$_d"
	exit 0
	;;

profiles)
	_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
	_act=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	printf '['
	_first=1
	for _sec in $(uci -q show "$CFG" 2>/dev/null | sed -n 's/^'"$CFG"'\.\(m_[^.]*\)\.path=.*/\1/p'); do
		_p=$(uci -q get "$CFG.$_sec.path")
		[ -n "$_p" ] || continue
		_if=$(uci -q get "$CFG.$_sec.network")
		_proto=""; _apn=""; _pdp=""
		if [ -n "$_if" ]; then
			_proto=$(uci -q get "network.$_if.proto")
			_apn=$(uci -q get "network.$_if.apn")
			_pdp=$(uci -q get "network.$_if.pdptype")
		fi
		# Протокол, запомненный в секции, если интерфейса ещё нет.
		[ -n "$_proto" ] || _proto=$(uci -q get "$CFG.$_sec.iface_proto")
		_on=0
		case " $_present " in *" $_p "*) _on=1 ;; esac
		# Интерфейс делят несколько профилей - это ровно та беда, что была с
		# Telit и Compal. Помечаем, чтобы удаление не срезало чужое.
		_shared=0
		if [ -n "$_if" ]; then
			# Только секции m_* : глобальный @5gmodem[0].network - это
			# указатель на активный интерфейс, а не второй владелец.
			_n=$(uci -q show "$CFG" 2>/dev/null | grep -c "^$CFG\.m_[^.]*\.network='\?$_if'\?\$")
			[ "${_n:-0}" -gt 1 ] && _shared=1
		fi
		[ "$_first" = 1 ] || printf ','
		_first=0
		printf '{"sec":"%s","path":"%s","model":"%s","imei":"%s","iface":"%s","proto":"%s","apn":"%s","pdptype":"%s","present":%d,"active":%d,"iface_shared":%d,"celllock":"%s","mm_exclude":"%s","vidpid":"%s","kind":"%s","netdev":"%s","webaddr":"%s","esim":"%s"}' \
			"$_sec" "$_p" \
			"$(uci -q get "$CFG.$_sec.model")" \
			"$(uci -q get "$CFG.$_sec.imei")" \
			"$_if" "$_proto" "$_apn" "$_pdp" "$_on" \
			"$([ "$_p" = "$_act" ] && echo 1 || echo 0)" "$_shared" \
			"$(uci -q get "$CFG.$_sec.celllock")" \
			"$(uci -q get "$CFG.$_sec.mm_exclude")" \
			"$(uci -q get "$CFG.$_sec.vidpid")" \
			"$(uci -q get "$CFG.$_sec.kind")" \
			"$(uci -q get "$CFG.$_sec.netdev")" \
			"$([ "$(uci -q get "$CFG.$_sec.kind")" = "hilink" ] && "$RES/hilink.sh" addr "$_p" 2>/dev/null)" \
			"$(_esim_state "$_sec" "$_p")"
	done
	printf ']\n'
	exit 0
	;;

# Удалить профиль ЦЕЛИКОМ - и секцию, и её сетевой интерфейс.
#
# Интерфейс убираем вместе с секцией сознательно: осиротевший интерфейс от
# вынутого модема - не безобидный мусор. Именно такой (от Telit) дрался с Compal
# за /dev/cdc-wdm0 и мешал ему подняться.
# ИСКЛЮЧЕНИЕ: если тем же интерфейсом пользуется другой профиль, интерфейс НЕ
# трогаем - иначе удаление одного модема оборвало бы связь у другого.
delprofile)
	_sec="$2"
	[ -n "$_sec" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q get "$CFG.$_sec" >/dev/null 2>&1 || { echo '{"error":"not found"}'; exit 0; }
	_p=$(uci -q get "$CFG.$_sec.path")
	_if=$(uci -q get "$CFG.$_sec.network")
	_killed=""
	if [ -n "$_if" ]; then
		_n=$(uci -q show "$CFG" 2>/dev/null | grep -c "^$CFG\.m_[^.]*\.network='\?$_if'\?\$")
		if [ "${_n:-0}" -le 1 ]; then
			ifdown "$_if" >/dev/null 2>&1
			uci -q delete "network.$_if"
			uci -q commit network
			_killed="$_if"
		fi
	fi
	uci -q delete "$CFG.$_sec"
	# Если удалили активный - снимаем указатель, иначе он повиснет на пустоту.
	[ "$(uci -q get "$CFG.@5gmodem[0].active_modem")" = "$_p" ] && {
		uci -q delete "$CFG.@5gmodem[0].active_modem" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].preferred_modem" 2>/dev/null
	}
	uci -q commit "$CFG"
	[ -n "$_killed" ] && /etc/init.d/network reload >/dev/null 2>&1
	logger -t 5gmodem "профиль $_sec ($_p) удалён${_killed:+, интерфейс $_killed тоже}"
	printf '{"success":true,"iface_removed":"%s"}\n' "$_killed"
	exit 0
	;;
apnfor)
	_j=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)
	# Метрики отдают ПРОЧЕРК, а не пустоту, когда код сети неизвестен. Без этой
	# нормализации в apn_plmn попадало "---", а сравнение с настоящим PLMN
	# никогда не совпадало.
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"
	_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		for _c in "${_imsi%${_imsi#??????}}" "${_imsi%${_imsi#?????}}"; do
			_sim_plmns="$_sim_plmns ${_c%${_c#???}}-${_c#???}"
		done
	fi
	# В роуминге APN из таблицы не годится - см. пояснение в autoapn.
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	[ "$_reg" = "5" ] && exit 0
	apn_pick "$_op" "$_plmn" "$_sim_plmns"
	exit 0
	;;
autoapn)
	IFACE="${2:-$(uci -q get "$CFG.@5gmodem[0].network")}"
	[ -n "$IFACE" ] || exit 0

	# РУЧНОЙ РЕЖИМ: APN распоряжается пользователь. Он его уже выбрал, и его
	# выбор хранится в самом интерфейсе - переписать значит потерять. Подсказку
	# с найденным APN страница показывает и так, применить её - одна кнопка.
	_am_sec=$(sec_for_iface "$IFACE")
	if [ "$(uci -q get "$CFG.$_am_sec.apn_mode")" = "manual" ]; then
		logger -t 5gmodem "autoapn: $IFACE в ручном режиме, APN не трогаем"
		exit 0
	fi

	# Ждём адрес: регистрация и первый дозвон занимают десятки секунд. РАНЬШЕ
	# появление адреса было поводом выйти совсем - APN считался «раз связь есть,
	# значит подходящий». На деле оператор нередко пускает с любым APN, и в
	# интерфейсе годами оставался чужой: у Beeline-симки стоял "tt" от прежней
	# T-Mobile. Поэтому адрес больше не повод молчать - решает СРАВНЕНИЕ APN
	# ниже, а сам факт связи лишь избавляет от ожидания.
	_w=0; _ip=""
	while [ "$_w" -lt 60 ]; do
		_ip=$(ubus call network.interface."$IFACE" status 2>/dev/null \
			| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
		[ -n "$_ip" ] && break
		sleep 5; _w=$((_w + 5))
	done

	# Узнаём, в чьей мы сети.
	_j=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)
	# Метрики отдают ПРОЧЕРК, а не пустоту, когда код сети неизвестен. Без этой
	# нормализации в apn_plmn попадало "---", а сравнение с настоящим PLMN
	# никогда не совпадало.
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"

	# КЛЮЧ ОТ САМОЙ SIM. У MVNO код зарегистрированной сети принадлежит ХОСТУ
	# (Т-Мобайл виден как 250-20 Tele2), а в IMSI записан СВОЙ код - 250-62.
	# Наблюдалось вживую: Compal получил APN "internet" от Tele2 вместо своего.
	# Имя оператора тут не спасает - этот модем отдаёт вместо него мусор
	# ("00540030"), а имя с SIM (EF_SPN) читается только если AT-порт в этот
	# момент отвечает, чего после перетасовки портов не случилось.
	# Длину MNC заранее не знаем (2 или 3 цифры), поэтому пробуем оба варианта.
	_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		_sim_plmns="${_imsi%${_imsi#??????}} ${_imsi%${_imsi#?????}}"
		# приводим к виду MCC-MNC
		_tmp=""
		for _c in $_sim_plmns; do _tmp="$_tmp ${_c%${_c#???}}-${_c#???}"; done
		_sim_plmns="$_tmp"
	fi
	[ -n "$_op$_plmn" ] || { logger -t 5gmodem "autoapn: оператор неизвестен, пропускаем"; exit 0; }

	# РОУМИНГ: APN из таблицы НЕ ПОДХОДИТ. В роуминге модем зарегистрирован в
	# ЧУЖОЙ сети, и её APN симке не годится - нужен домашний, которого мы знать
	# не можем: и имя, и код сети принадлежат гостевой стороне. Для travel-eSIM
	# и большинства роуминговых профилей правильное значение - ПУСТО: оператор
	# выдаёт настройки сам. Подставив APN гостевой сети, мы бы сломали связь,
	# которая иначе поднялась бы без нашего участия.
	# Признак роуминга - код регистрации 5 (registered, roaming) против 1 (home).
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	if [ "$_reg" = "5" ]; then
		logger -t 5gmodem "autoapn: роуминг (сеть «$_op», $_plmn) - APN оставляем пустым"
		exit 0
	fi

	_apn=$(apn_pick "$_op" "$_plmn" "$_sim_plmns") || {
		logger -t 5gmodem "autoapn: APN для «$_op» ($_plmn, SIM$_sim_plmns) не найден"
		exit 0
	}
	_cur=$(uci -q get "network.$IFACE.apn")
	if [ "$_cur" = "$_apn" ]; then
		logger -t 5gmodem "autoapn: APN уже $_apn"
		[ -n "$_am_sec" ] && { uci -q set "$CFG.$_am_sec.apn_plmn=$_plmn"; uci -q commit "$CFG"; }
		exit 0
	fi

	uci -q set "network.$IFACE.apn=$_apn"
	uci -q commit network
	# Помним, ДЛЯ КАКОЙ сети подобран APN: по этой записи видно в отладке, что
	# значение относится к нынешней симке, а не осталось от прежней.
	[ -n "$_am_sec" ] && { uci -q set "$CFG.$_am_sec.apn_plmn=$_plmn"; uci -q commit "$CFG"; }
	logger -t 5gmodem "autoapn: $IFACE -> APN $_apn (было «${_cur:-пусто}», оператор «$_op», $_plmn)"
	ifdown "$IFACE" >/dev/null 2>&1
	sleep 3
	ifup "$IFACE" >/dev/null 2>&1
	# APN исправлен, а адреса всё нет - тогда дело может быть в типе PDP.
	( "$RES/modemswitch.sh" autopdp "$IFACE" ) >/dev/null 2>&1 </dev/null &
	;;

# ПОДБОР ТИПА PDP (IPv4 / IPv4v6).
#
# ЗАЧЕМ. Симптом неотличим от «нет сети»: модем зарегистрирован, сигнал есть, а
# адреса нет - и по одному этому виду не понять, при чём тут тип контекста.
# Причём случаи ПРОТИВОПОЛОЖНЫ друг другу, так что «правильного» значения на все
# модемы не существует:
#   - FM350 на Tele2: с IPV4-only контекст вообще не активируется, CGACT виснет;
#   - Quectel EC21: на dual-stack не дозванивается, поднимается только с IPV4.
# Определять это по журналу бесполезно - у qmi, mbim, atc и modemmanager тексты
# ошибок разные, и мы бы гадали. Поэтому не гадаем, а ПРОБУЕМ и запоминаем.
#
# ПОРЯДОК: сперва ipv4v6, потом ipv4. Не по вкусу, а потому что при неудаче
# ipv4v6 отваливается быстро, а неверный ipv4 именно ЗАВИСАЕТ - начав с него, мы
# бы ждали таймаута вместо честного отказа.
autopdp)
	IFACE="${2:-$(uci -q get "$CFG.@5gmodem[0].network")}"
	[ -n "$IFACE" ] || exit 0

	_pd_sec=$(sec_for_iface "$IFACE")
	if [ "$(uci -q get "$CFG.$_pd_sec.pdp_mode")" = "manual" ]; then
		logger -t 5gmodem "autopdp: $IFACE в ручном режиме, тип PDP не трогаем"
		exit 0
	fi

	# Уже с адресом - чинить нечего. Это РЕМОНТНАЯ операция, а не регулярная:
	# перебор типов рвёт связь, и делать это на работающем интерфейсе нельзя.
	_pd_ip=$(ubus call network.interface."$IFACE" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -n "$_pd_ip" ] && { logger -t 5gmodem "autopdp: $IFACE уже с адресом $_pd_ip"; exit 0; }

	# Имя опции и регистр значения у протоколов разные - то же соответствие,
	# что в mkiface.sh (set_pdp_opt).
	case "$(uci -q get "network.$IFACE.proto")" in
		modemmanager) _pd_opt=iptype;  _pd_up=0 ;;
		qmi|mbim)     _pd_opt=pdptype; _pd_up=0 ;;
		fibocom)      _pd_opt=pdptype; _pd_up=1 ;;
		atc)          _pd_opt=pdp;     _pd_up=1 ;;
		xmm)          _pd_opt=pdp;     _pd_up=0 ;;
		*)            logger -t 5gmodem "autopdp: протокол $IFACE типа PDP не имеет"; exit 0 ;;
	esac

	_pd_was=$(uci -q get "network.$IFACE.$_pd_opt")
	_pd_plmn=""
	_pd_j=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_pd_mcc=$(printf '%s' "$_pd_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_pd_mnc=$(printf '%s' "$_pd_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)
	[ "$_pd_mcc" = "-" ] && _pd_mcc=""
	[ "$_pd_mnc" = "-" ] && _pd_mnc=""
	[ -n "$_pd_mcc" ] && [ -n "$_pd_mnc" ] && _pd_plmn="$_pd_mcc-$_pd_mnc"

	for _pd_try in ipv4v6 ipv4; do
		_pd_val="$_pd_try"
		[ "$_pd_up" = "1" ] && _pd_val=$(echo "$_pd_try" | tr a-z A-Z)
		uci -q set "network.$IFACE.$_pd_opt=$_pd_val"
		uci -q commit network
		ifdown "$IFACE" >/dev/null 2>&1
		sleep 3
		ifup "$IFACE" >/dev/null 2>&1

		_pd_w=0
		while [ "$_pd_w" -lt 45 ]; do
			sleep 5; _pd_w=$((_pd_w + 5))
			_pd_ip=$(ubus call network.interface."$IFACE" status 2>/dev/null \
				| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
			[ -n "$_pd_ip" ] && break
		done

		if [ -n "$_pd_ip" ]; then
			[ -n "$_pd_sec" ] && {
				uci -q set "$CFG.$_pd_sec.pdp_ok=$_pd_try"
				uci -q set "$CFG.$_pd_sec.pdp_plmn=$_pd_plmn"
				uci -q commit "$CFG"
			}
			logger -t 5gmodem "autopdp: $IFACE поднялся на $_pd_val (адрес $_pd_ip, сеть $_pd_plmn)"
			exit 0
		fi
		logger -t 5gmodem "autopdp: $IFACE на $_pd_val адрес не получил"
	done

	# Не помогло ни то, ни другое - причина не в типе PDP. ВОЗВРАЩАЕМ как было:
	# оставить свой последний перебор значит подменить осознанный выбор
	# пользователя результатом неудачной пробы.
	if [ -n "$_pd_was" ]; then
		uci -q set "network.$IFACE.$_pd_opt=$_pd_was"
	else
		uci -q delete "network.$IFACE.$_pd_opt"
	fi
	uci -q commit network
	ifup "$IFACE" >/dev/null 2>&1
	logger -t 5gmodem "autopdp: ни ipv4v6, ни ipv4 не дали адреса - дело не в типе PDP, вернул «${_pd_was:-пусто}»"
	;;

# АВТОНАСТРОЙКА НОВОГО МОДЕМА (plug-and-play).
#
# Задача: воткнул модем - получил интернет, без хождения по вкладкам. Но делать
# это безоглядно нельзя: mkiface настраивает АКТИВНЫЙ модем, и на роутере с уже
# работающим модемом второй воткнутый перехватил бы конфигурацию. Поэтому
# автонастройка срабатывает ТОЛЬКО когда рабочего интерфейса ещё нет - то есть
# ровно в том случае, ради которого затевалась: первый запуск или первый модем.
#
# Выключается: uci set 5gmodem.@5gmodem[0].auto_setup=0
autosetup)
	[ "$(uci -q get "$CFG.@5gmodem[0].auto_setup")" = "0" ] && exit 0

	# ЦЕЛЬ - ПРИСУТСТВУЮЩИЙ МОДЕМ БЕЗ РАБОЧЕГО ИНТЕРФЕЙСА.
	#
	# Раньше здесь стоял ГЛОБАЛЬНЫЙ гард: если хоть у одного модема есть живая
	# сеть, autosetup выходил целиком. На роутере с одним настроенным модемом это
	# означало, что второй, только что воткнутый, не настраивался НИКОГДА. Ровно
	# этот случай и наблюдался: ветка обработки замены модема на том же USB-пути
	# пишет в лог "rerun setup to rebuild", гасит устаревший интерфейс и ждёт,
	# что setup отработает заново, - а он выходил на первом же гарде.
	# Проверяем теперь ПОМОДЕМНО: модем с живой сетью пропускаем (его не трогаем,
	# ради чего гард и был), берём первый без неё.
	# ВСЕ модемы без рабочей сети, а не первый попавшийся.
	#
	# Раньше здесь стоял `break`: за один заход настраивался ровно один модем.
	# При установке пакета на роутер с ДВУМЯ воткнутыми модемами второй так и
	# оставался без секции и интерфейса - до собственного hotplug-события или
	# ручного переключения. На странице профилей это выглядело как «программа нашла только один модем».
	TARGETS="$2"
	if [ -z "$TARGETS" ]; then
		for _p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			# HiLink-модем без AT-портов - ЦЕЛЬ, даже если интерфейс уже есть.
			# Режим debug слетает при каждом переподключении модема, а интерфейс
			# при этом остаётся на месте - и проверка «интерфейс есть, значит
			# настроен» пропускала модем, оставляя его в чистом HiLink: ни TAC, ни
			# диапазонов, ни USSD. Наблюдалось ровно так после перетыкания.
			if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
			   && [ "$(uci -q get "$CFG.$_s.at_debug")" != "0" ] \
			   && [ -z "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_p\"].tty[0]" 2>/dev/null)" ]; then
				TARGETS="$TARGETS $_p"
				continue
			fi
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && continue
			TARGETS="$TARGETS $_p"
		done
	fi
	[ -n "$TARGETS" ] || exit 0

	for P in $TARGETS; do
		setup_one_modem "$P"
	done
	exit 0
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
		# ПРИВЯЗКА К СЛОТУ. Найденный ранее порт закреплён за секцией модема, а
		# секция - за стабильным USB-путём. Если порт всё ещё принадлежит ЭТОМУ
		# пути и отвечает на AT, перебирать заново незачем.
		# Замерено: resolve занимал 4.4 c и выполняется на КАЖДОМ событии USB и при
		# загрузке, а проверка закреплённого порта укладывается в сотые доли.
		# Перебор остаётся запасным путём - нумерация tty после переподключения
		# сдвигается, и тогда закрепление протухает.
		A=""
		_pin=$(uci -q get "$CFG.$SEC.at_port")
		if [ -n "$_pin" ] && [ -e "$_pin" ] && modem_ttys "$P" | grep -qxF "$_pin"; then
			"$RES/atprobe.sh" "$_pin" >/dev/null 2>&1 && A="$_pin"
		fi
		_try=0
		while [ -z "$A" ] && [ "$_try" -lt 6 ]; do
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
		# Активный пропал с шины. Кого брать вместо него - НЕ «первого в списке».
		# У FM350 есть штатный флап переэнумерации (см. quirks), и ровно в эту
		# секунду рядом может оказаться только что воткнутый НЕНАСТРОЕННЫЙ модем.
		# Тогда активность уезжала на него, а следом - и ГЛОБАЛЬНЫЕ порты
		# sms_tool_js (ниже по ветке): открытая страница прежнего модема начинала
		# показывать чужой сигнал, чужую SIM и чужой номер, ничего не сообщая.
		# Предпочитаем модем с РАБОЧИМ интерфейсом: он почти наверняка и есть тот,
		# что работал до сих пор.
		_cand=""
		for _p in $PRESENT; do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && { _cand="$_p"; break; }
		done
		[ -n "$_cand" ] || _cand=$(echo "$PRESENT" | awk '{print $1}')
		AMP="$_cand"
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
			# ...и СРАЗУ развести обратно. Строкой выше все порты SMS/USSD/AT
			# приравнены к порту метрик - это правильная отправная точка (порт
			# заведомо рабочий), но оставлять их так нельзя: sms_tool открывает
			# порт на каждый вызов, и чтение, попавшее на опрос метрик,
			# возвращает пустоту. Живой случай: после resolve USSD на MeigLink
			# отвечал "No response from modem", пока ussdport совпадал с at_port.
			# ensureports.sh сам найдёт свободный AT-порт, если модем его даёт,
			# и ничего не сделает, если порт единственный.
			"$RES/ensureports.sh" >/dev/null 2>&1
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
