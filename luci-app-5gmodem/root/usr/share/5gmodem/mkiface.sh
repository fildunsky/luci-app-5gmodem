#!/bin/sh
#
# Create / switch the network interface for the connected modem.
#
# Usage: mkiface.sh [name] [proto]
#   name  : interface name (default: modem)
#   proto : auto | mbim | qmi | ncm | xmm | atc | wwan | 3g | modemmanager
#           (default: auto). Any proto whose handler is installed can be passed;
#           the UI offers the ones actually available on the router.
#
# - auto: pick the proto from the real driver of the cdc-wdm control node
#   (cdc_mbim -> mbim, qmi_wwan -> qmi). This is far more reliable than mmcli,
#   which on many MBIM modems (e.g. Compal RXM-G1) misclassifies the port and
#   builds a non-working modem, and it never creates a non-working qmi over an
#   MBIM composition.
# - mbim/qmi: the kernel (umbim/uqmi) owns cdc-wdm0. ModemManager MUST NOT run,
#   or the two fight over the control channel -> so we stop+disable it.
# - modemmanager: MM owns the modem. We enable+(re)start it and point the
#   interface at the modem's sysfs path.
#
# Adds the interface to the 'wan' firewall zone, points the app at it, brings
# it up, and prints a small JSON result.
#

IF="${1:-modem}"
REQ="${2:-auto}"
# APN, переданный из UI (автоподстановка по оператору или ручной ввод).
#   <строка> - применить его;
#   "-"      - ЯВНО без APN (оператор опознан, но APN для него неизвестен) -> опцию
#              удаляем, модем возьмёт APN сети по умолчанию;
#   пусто    - аргумент не передан (вызов не из UI) -> сохранить прежний APN.
# Разделять "-" и пусто пришлось потому, что раньше стереть APN было НЕЛЬЗЯ:
# ${APNARG:-${OLDAPN:-internet}} трактует пустую строку как «не передано» и
# молча возвращал прежнее значение.
APNARG="$3"

# ШТАМП ВЛАДЕЛЬЦА: запомнить В САМОМ ИНТЕРФЕЙСЕ, для какого модема он создан
# (стабильный USB-путь, а не номер устройства). $1 = имя интерфейса, $2 = путь.
#
# ЗАЧЕМ. Связь «модем -> интерфейс» была ОДНОСТОРОННЕЙ: 5gmodem.m_<путь>.network.
# Стоило секции модема исчезнуть (кнопка «Забыть», подмена модема), и интерфейс
# оставался сиротой, привязанной к device-ноде (/dev/cdc-wdm0). Ноды не
# стабильны: следующий модем в тот же разъём получал ту же ноду и МОЛЧА
# наследовал чужие настройки. Живой случай: SIM7600 сменили на Telit LM960 -
# новый модем подхватил интерфейс с APN internet.beeline.ru, хотя в нём стоит
# симка Т-Мобайл. Штамп даёт обратную ссылку и позволяет отличить свой
# интерфейс от чужого наследства.
#
# ВЛАДЕНИЕ ПО ЖЕЛЕЗУ. Кроме пути пишем и IMEI (network.<if>.modem_imei) - он и
# есть первичный ключ: два РАЗНЫХ модема в одном разъёме имеют один путь, и по
# пути их не различить (интерфейс прежнего сносился при подмене). Реализация -
# общая, в lib.sh (её же используют resolve/swap_cleanup).
. /usr/share/5gmodem/lib.sh
stamp_iface() {
	stamp_iface_owner "$1" "$2"
}

# Записать APN интерфейса $1 по правилам выше ($2 = прежний APN)
set_apn_opt() {
	case "$APNARG" in
		-)  uci -q delete "network.$1.apn" ;;
		"") uci set "network.$1.apn=${2:-internet}" ;;
		*)  uci set "network.$1.apn=$APNARG" ;;
	esac
}

# Тип PDP для НОВОГО интерфейса: ipv4 | ipv4v6 (4-й аргумент из UI).
# По умолчанию ipv4, а не ipv4v6, как было раньше: dual-stack ломает дозвон на
# части модемов (Quectel EC21 проверен живьём - поднялся только после смены на
# ipv4), а выгоды от IPv6 у сотовых операторов РФ почти нет: его либо не выдают,
# либо выдают криво. Кому нужен - переключает в настройках модема.
# СУЩЕСТВУЮЩИЕ интерфейсы не трогаем: если аргумент не передан (вызов не из UI),
# сохраняем то, что уже стоит.
PDPARG="$4"

# Записать тип PDP интерфейса $1. Имя опции и РЕГИСТР значения отличаются у
# разных прото: atc ждёт pdp=IPV4V6 (верхний), fibocom - pdptype=IPV4V6,
# qmi/mbim - pdptype=ipv4v6 (нижний). Поэтому вид значения задаёт вызывающий:
# $2 = имя опции (pdp|pdptype), $3 = 'upper' для верхнего регистра.
set_pdp_opt() {
	_opt="$2"; _up="$3"
	_v="$PDPARG"
	[ -n "$_v" ] || _v=$(uci -q get "network.$1.$_opt")   # не из UI - оставить как есть
	[ -n "$_v" ] || _v="$OLDPDP"                           # значение до пересоздания интерфейса
	# По умолчанию IPV4. Полевые данные на всём тестовом парке: на IPV4V6 модем
	# часто регистрируется, но АДРЕС НЕ ПОЛУЧАЕТ (контекст не активируется), а на
	# IPV4 сразу получает IP. Раньше дефолтом был IPV4V6 из-за единичного кейса
	# (Tele2/FM350 виснул на IPV4-only) - он оказался операторо-специфичным, а
	# страдало большинство. Кому нужен dual-stack - переключит в настройках модема.
	[ -n "$_v" ] || _v="ipv4"
	case "$_v" in
		ipv4v6|IPV4V6) _v=ipv4v6 ;;
		*)             _v=ipv4 ;;
	esac
	[ "$_up" = upper ] && _v=$(echo "$_v" | tr a-z A-Z)
	uci set "network.$1.$_opt=$_v"
}

json() { printf '{"result":"%s","iface":"%s","proto":"%s","device":"%s"}\n' "$1" "$IF" "$2" "$3"; }

# ---- подготовка kernel-прото (qmi/mbim) -------------------------------------
# Диагностика живого EC21 (см. ниже) показала цепочку, из-за которой модем
# оставался без интернета НАВСЕГДА, хотя сам был полностью исправен:
#   1) ModemManager и uqmi одновременно претендовали на один cdc-wdm ->
#      QMI-стек модема заклинивало;
#   2) uqmi ВИСЛА НАВЕЧНО, игнорируя собственный -t 3000 (в qmi.sh над этим
#      вызовом даже стоит комментарий "timeout 3s to avoid hanging uqmi"),
#      и держала cdc-wdm открытым;
#   3) все следующие запросы -> "Request timed out" / "No data link!",
#      netifd клал интерфейс и пробовал снова - бесконечный цикл;
#   4) модем при этом отвечал по AT: CGMM=EC21, CPIN=READY. Умирал только QMI.
# Лечится сбросом модема (AT+CFUN=1,1): после переэнумерации QMI оживает.
# Здесь мы делаем это автоматически ПЕРЕД поднятием интерфейса.

# Запустить команду с ЖЁСТКИМ ограничением по времени: busybox не имеет timeout(1),
# а uqmi не соблюдает свой -t. Возвращает вывод; при зависании убивает процесс.
run_bounded() {   # $1 = секунды, далее команда
	_lim="$1"; shift
	_out="/tmp/5gmodem_bounded.$$"
	rm -f "$_out"
	( "$@" >"$_out" 2>&1 ) &
	_p=$!
	_n=0
	while kill -0 "$_p" 2>/dev/null && [ "$_n" -lt "$_lim" ]; do sleep 1; _n=$((_n + 1)); done
	kill -9 "$_p" 2>/dev/null
	cat "$_out" 2>/dev/null
	rm -f "$_out"
}

# QMI отвечает? Спрашиваем UIM (а НЕ --get-pin-status: на EC21 он штатно отдаёт
# "Not supported" даже на здоровом модеме, это не признак поломки).
qmi_alive() {   # $1 = cdc-wdm
	case "$(run_bounded 8 uqmi -d "$1" -t 5000 --uim-get-sim-state)" in
		*card_application_state*|*card_slot*) return 0 ;;
	esac
	return 1
}

# AT-порт этого модема (для сброса)
at_port_of() {   # $1 = usb path
	for _t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		case "$(run_bounded 6 sms_tool -d "$_t" at "AT+CGMM")" in
			*ERROR*|*"No response"*|"") continue ;;
			*) echo "$_t"; return 0 ;;
		esac
	done
	return 1
}

# Подготовить модем к kernel-прото: отобрать порт у MM, снять зависшие uqmi,
# при заклиненном QMI - сбросить модем и дождаться возвращения на шину.
kernel_proto_prepare() {   # $1 = cdc-wdm, $2 = usb path
	_wdm="$1"; _path="$2"
	[ -n "$_wdm" ] && [ -e "$_wdm" ] || return 0

	# 1) MM не должен держать ЭТОТ модем. Прячет его mm-inhibit.sh
	# (mmcli --inhibit-device), но демон ходит раз в 15 c, а нам порт нужен
	# СЕЙЧАС. Если MM нужен другому модему, глушить его нельзя: аккуратно
	# перезапускаем и ждём, пока он отпустит наш модем - инхибитор подхватит.
	if pgrep -f ModemManager >/dev/null 2>&1; then
		if mmcli -L 2>/dev/null | grep -q "/Modem/"; then
			echo "prepare: ModemManager is running - restarting it so it releases $_wdm" >&2
			mm_restart_safe
			_n=0
			while [ "$_n" -lt 20 ]; do
				mmcli -L 2>/dev/null | grep -q "$(basename "$_path")" || break
				sleep 1; _n=$((_n + 1))
			done
		fi
	fi

	# 2) Зависшая uqmi держит cdc-wdm - её надо снять, иначе всё упрётся в неё.
	for _p in $(pgrep -f "uqmi .*$_wdm" 2>/dev/null); do
		echo "prepare: killing wedged uqmi (pid $_p) holding $_wdm" >&2
		kill -9 "$_p" 2>/dev/null
	done

	# 3) QMI жив? Если нет - сброс модема. Только для qmi: у mbim свой стек.
	[ "$PROTO" = qmi ] || return 0
	qmi_alive "$_wdm" && return 0

	_atp=$(at_port_of "$_path")
	[ -n "$_atp" ] || { echo "prepare: QMI wedged and no AT port to reset the modem" >&2; return 1; }
	echo "prepare: QMI is wedged - resetting the modem via AT+CFUN=1,1 on $_atp" >&2
	( sms_tool -d "$_atp" at "AT+CFUN=1,1" ) >/dev/null 2>&1 </dev/null &

	# ждём возвращения на шину (переэнумерация) + готовности QMI
	_n=0
	while [ "$_n" -lt 90 ]; do
		sleep 3; _n=$((_n + 3))
		/usr/share/5gmodem/listmodems.sh --refresh 2>/dev/null | grep -q "\"$_path\"" || continue
		_w=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$_path\"].wdm[0]" 2>/dev/null)
		[ -n "$_w" ] && [ -e "$_w" ] || continue
		qmi_alive "$_w" && { echo "prepare: QMI recovered after ${_n}s" >&2; return 0; }
	done
	echo "prepare: QMI did not recover in ${_n}s" >&2
	return 1
}

# Безопасный (пере)запуск ModemManager.
# НЕЛЬЗЯ `/etc/init.d/modemmanager restart`: procd поднимает новый процесс, не
# дожидаясь, пока прежний отпустит имя на D-Bus. Новый не может забрать
# org.freedesktop.ModemManager1 ("could not acquire the service name") и сразу
# умирает, а старый уже остановлен - MM пропадает на 1-2 минуты и "теряет модем"
# (видно в логе: два "ModemManager is shut down" подряд, затем пауза ~68 c до
# respawn'а). Поэтому: остановить, ДОЖДАТЬСЯ исчезновения процесса, запустить.
# Если MM не запущен - просто стартуем (как это делает modemswitch.sh).
mm_restart_safe() {
	if pgrep -f ModemManager >/dev/null 2>&1; then
		/etc/init.d/modemmanager stop >/dev/null 2>&1
		_n=0
		while pgrep -f ModemManager >/dev/null 2>&1 && [ "$_n" -lt 15 ]; do
			sleep 1; _n=$((_n + 1))
		done
	fi
	/etc/init.d/modemmanager start >/dev/null 2>&1
}

# --- multi-modem: build the interface for the ACTIVE modem (by USB path), so
# two modems get SEPARATE interfaces + separate cdc-wdm nodes instead of both
# clobbering a single "modem" interface (which made the IP look shared). ---
# Обычно работаем с АКТИВНЫМ модемом. Но autosetup при установке настраивает и
# неактивные тоже (иначе второй воткнутый модем остаётся без интерфейса), и для
# этого задаёт MODEM_PATH. Тогда все глобальные ключи @5gmodem[0] - трогать
# НЕЛЬЗЯ: они описывают активный модем, и запись в них увела бы страницу и порты
# sms_tool_js на чужой модем.
AMP=${MODEM_PATH:-$(uci -q get 5gmodem.@5gmodem[0].active_modem)}
_ACTPATH=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_IS_ACTIVE=1
[ -n "$MODEM_PATH" ] && [ -n "$_ACTPATH" ] && [ "$MODEM_PATH" != "$_ACTPATH" ] && _IS_ACTIVE=0
MSEC=""
WANTWDM=""
if [ -n "$AMP" ]; then
	MSEC="m_$(echo "$AMP" | sed 's/[^A-Za-z0-9]/_/g')"
	# interface name: prefer the one remembered for THIS modem, default "modem".
	# Then guarantee uniqueness - if that name is already claimed by ANOTHER
	# modem's section, bump to modem2/modem3/… so two modems never share one
	# interface (which made the IP look shared).
	# tr '\n' ' ' обязателен: cut отдаёт имена ПОСТРОЧНО, а проверка ниже делает
	# `echo " $USED " | grep -q " $cand "` - пробелы приклеиваются лишь к началу
	# ПЕРВОЙ и концу ПОСЛЕДНЕЙ строки. У имени в середине (и у первого в строке)
	# ведущего пробела нет, " modem " не совпадает - и занятое имя молча
	# считалось свободным. Так два модема получали ОДИН интерфейс "modem", ради
	# чего эта проверка и писалась (общий IP, см. комментарий выше).
	USED=$(uci show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\(.*\)'\$/\1=\2/p" | grep -v "^$MSEC=" | cut -d= -f2 | tr '\n' ' ')
	cand=$(uci -q get "5gmodem.$MSEC.network")
	[ -n "$cand" ] || cand="modem"
	n=1
	# Имя занято, если его держит ДРУГАЯ секция (USED) ИЛИ существующий интерфейс
	# с таким именем ЗАКРЕПЛЁН ЗА ДРУГИМ ЖЕЛЕЗОМ (штамп modem_imei, см. lib.sh).
	# Вторая проверка нужна потому, что интерфейс вытесненного модема мы больше не
	# сносим: он ждёт возвращения своего модема, и отдавать его имя новому нельзя
	# (наблюдалось: Compal занял modem2, сохранённый за Huawei E3372).
	MYIMEI=$(imei_for_path "$AMP")
	while echo " $USED " | grep -q " $cand " \
	      || { uci -q get "network.$cand" >/dev/null 2>&1 \
	           && ! iface_owned_by "$cand" "$AMP" "$MYIMEI"; }; do
		n=$((n + 1)); cand="modem$n"
	done
	IF="$cand"
	# the cdc-wdm control node that belongs to THIS modem
	WANTWDM=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$AMP\"].wdm[0]" 2>/dev/null)
fi

# --- AT-dialed RNDIS/ECM modems (Fibocom FM350-GL 0e8d:7127 and similar): they
# expose NO cdc-wdm control channel; data rides a usbnet device (eth*) that we
# fill via an AT PDP dial. ModemManager cannot enable them (fails with
# UnexpectedDataValue) and mbim/qmi need a cdc-wdm that does not exist here - so
# route them to our 'fibocom' netifd proto instead of the mbim fallback below. ---
if [ -n "$AMP" ] && [ -z "$WANTWDM" ] && { [ "$REQ" = auto ] || [ "$REQ" = "" ] || [ "$REQ" = fibocom ] || [ "$REQ" = atc ] || [ "$REQ" = xmm ]; }; then
	FNET=""
	for n in /sys/bus/usb/devices/$AMP:*/net/*; do
		[ -e "$n" ] || continue
		FNET=$(basename "$n"); break
	done
	if [ -n "$FNET" ]; then
		OLDAPN=$(uci -q get "network.$IF.apn")
		# Сохраняем ТИП PDP через пересоздание: интерфейс удаляется ниже, а
		# set_pdp_opt читает uci ПОСЛЕ удаления - без этого выбор пользователя
		# (напр. IPV4V6, нужный Tele2/FM350) терялся и сбрасывался на дефолт.
		OLDPDP=$(uci -q get "network.$IF.pdptype")
		[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.pdp")
		[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.iptype")
		uci -q delete "network.$IF" 2>/dev/null
		uci set "network.$IF=interface"

		# Default to the built-in 'fibocom' proto: stable, SMS-safe (does not
		# touch the modem's SMS) and self-healing. 'atc' and 'xmm' are used ONLY
		# when the user explicitly selects them AND the handler is installed -
		# atc in particular takes over SMS and holds an AT port open, so making
		# it a silent default caused deregistration/port churn on multi-modem
		# setups. Opt-in keeps auto-detection predictable.
		FPROTO=fibocom
		[ "$REQ" = xmm ] && [ -f /lib/netifd/proto/xmm.sh ] && FPROTO=xmm
		[ "$REQ" = atc ] && [ -f /lib/netifd/proto/atc.sh ] && FPROTO=atc

		if [ "$FPROTO" = atc ] || [ "$FPROTO" = xmm ]; then
			# atc И xmm дозваниваются ПО AT-ПОРТУ (ttyACM/ttyUSB), а сетевое
			# устройство (wwan*/eth*) выводят сами. Поэтому device = AT-порт, НЕ
			# net-устройство. Раньше xmm валился в общую fibocom-ветку и получал
			# device=<net> (wwan2) - протокол xmm делает basename $device и ищет его
			# в /sys/class/tty: net-нода там отсутствует => "AT port not valid!" и
			# "Device path not found!" в цикле (живой баг на L850 после FM350 в том
			# же USB-разъёме). Даём отдельный от метрик AT-порт, чтобы дозвон и
			# периодический опрос не сталкивались на одном tty.
			METRIC_AT=$(uci -q get "5gmodem.$MSEC.at_port")
			[ -n "$METRIC_AT" ] || METRIC_AT=$(uci -q get 5gmodem.@5gmodem[0].at_port)
			DIALPORT=""
			for t in /sys/bus/usb/devices/$AMP:*/ttyUSB* /sys/bus/usb/devices/$AMP:*/ttyACM*; do
				[ -e "$t" ] || continue
				tt="/dev/$(basename "$t")"
				[ "$tt" = "$METRIC_AT" ] && continue
				sms_tool -d "$tt" at "AT" >/dev/null 2>&1 && { DIALPORT="$tt"; break; }
			done
			[ -n "$DIALPORT" ] || DIALPORT="$METRIC_AT"
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.device=$DIALPORT"
			set_apn_opt "$IF" "$OLDAPN"
			# имя опции у протоколов разное: atc читает 'pdp', xmm тоже 'pdp'.
			set_pdp_opt "$IF" pdp upper
			uci set "network.$IF.metric=20"
			FDEV="$DIALPORT"
			# remember the dial AT port so resolve can re-pin it after renumbering
			[ -n "$MSEC" ] && uci -q set "5gmodem.$MSEC.data_at_port=$DIALPORT"
		else
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.usbpath=$AMP"
			uci set "network.$IF.device=$FNET"
			set_apn_opt "$IF" "$OLDAPN"
			set_pdp_opt "$IF" pdptype upper
			FDEV="$FNET"
		fi
		# secondary uplink by default so (re)creating it never hijacks another
		# modem's default route; lower the metric in Network > Interfaces to make
		# it primary.
		uci set "network.$IF.metric=20"
		uci commit network

		# add to the 'wan' firewall zone for NAT/forwarding. Самолечащий:
		# сперва убираем ВСЕ вхождения $IF (старые версии приложения могли
		# накопить дубликаты - интерфейс появлялся в зоне по 4 раза и столько же
		# раз в «Приоритете интернета»), потом добавляем РОВНО один.
		Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
		if [ -n "$Z" ]; then
			while uci -q get "firewall.$Z.network" | grep -qw "$IF"; do
				uci del_list "firewall.$Z.network=$IF"
			done
			uci add_list "firewall.$Z.network=$IF"
			uci commit firewall
		fi

		# point the app at this interface and remember it for this modem
		if [ "$_IS_ACTIVE" = 1 ]; then
			uci -q set "5gmodem.@5gmodem[0].network=$IF"
			uci -q set "5gmodem.@5gmodem[0].iface_proto=$FPROTO"
		fi
		if [ -n "$MSEC" ]; then
			if ! uci -q get "5gmodem.$MSEC" >/dev/null 2>&1; then
				# Заводим секцию ПОЛНОЙ (path + vidpid + product из listmodems), а
				# не голой: пересозданный после delprofile профиль иначе оставался
				# без vid:pid и «безымянным». Модель дольёт опрос метрик (AT+CGMM).
				uci -q set "5gmodem.$MSEC=modem"
				uci -q set "5gmodem.$MSEC.path=$AMP"
				_mk_lm=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
				_mk_vp=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].vidpid" 2>/dev/null | head -1)
				_mk_pr=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].product" 2>/dev/null | head -1)
				[ -n "$_mk_vp" ] && uci -q set "5gmodem.$MSEC.vidpid=$_mk_vp"
				[ -n "$_mk_pr" ] && uci -q set "5gmodem.$MSEC.product=$_mk_pr"
			fi
			uci -q set "5gmodem.$MSEC.network=$IF"
			uci -q set "5gmodem.$MSEC.iface_proto=$FPROTO"
			# интерфейс только что создан ДЛЯ ЭТОГО модема и проштампован - метка
			# «настройки от прежнего модема» больше не про него. Снимаем СРАЗУ:
			# ставит её resolve, и без этого предупреждение висело в UI до
			# следующего hotplug/перезагрузки, хотя пользователь всё уже исправил.
			uci -q delete "5gmodem.$MSEC.foreign_iface" 2>/dev/null
		fi
		stamp_iface "$IF" "$AMP"
		uci -q commit 5gmodem

		# SMS/USSD via the AT port - ModemManager cannot manage this modem
		if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=0"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=0"
			uci -q commit sms_tool_js
		fi

		# NOTE: deliberately leave ModemManager as-is (another modem may need it);
		# the fibocom path uses AT + the usbnet device and does not touch MM.
		# fibocom - kernel-прото: MM трогать этот модем не должен. Ставим флаг и
		# применяем инхибицию (udev-правила на OpenWrt не работают, см. mm-inhibit.sh).
		if [ -n "$MSEC" ]; then
			uci -q set "5gmodem.$MSEC.mm_exclude=1"
			uci -q commit 5gmodem
			/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 &
		fi
		ifup "$IF" >/dev/null 2>&1
		json created "$FPROTO" "$FDEV"
		exit 0
	fi
fi

# --- locate the cdc-wdm control node and its driver (this modem's, if known) ---
DEV=""; DRV=""
if [ -n "$WANTWDM" ] && [ -c "$WANTWDM" ]; then
	DEV="$WANTWDM"
	DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$WANTWDM")/device/driver" 2>/dev/null)")
else
	for wdm in /dev/cdc-wdm*; do
		[ -c "$wdm" ] || continue
		DEV="$wdm"
		DRV=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$wdm")/device/driver" 2>/dev/null)")
		break
	done
fi

# Опознание Compal - через ОБЩИЙ помощник (см. iscompal.sh): у этого модема свой
# VID:PID в каждой композиции, и держать копию проверки в каждом файле - ровно
# тот путь, которым уже сломалось определение SIM-слотов в новой композиции.
. /usr/share/5gmodem/iscompal.sh

# --- decide the proto ---
# auto: pick from the cdc-wdm driver. Any other value is passed through as-is,
# so any installed netifd/luci proto handler (mbim, qmi, ncm, xmm, atc, wwan,
# 3g, modemmanager, ...) can be selected from the UI.
case "$REQ" in
	auto|"")
		case "$DRV" in
			cdc_mbim) PROTO="mbim" ;;
			qmi_wwan) PROTO="qmi" ;;
			*)        PROTO="mbim" ;;
		esac
		# Compal RXM-G1 в QMI-композиции - ИСКЛЮЧЕНИЕ в пользу ModemManager.
		# У этой прошивки нет своих AT-команд бенд-лока, а в CLI libqmi нет TLV
		# для ИХ ЗАПИСИ (только чтение), поэтому управлять диапазонами и режимом
		# сети можно ИСКЛЮЧИТЕЛЬНО через mmcli. На kernel-протоколе mm-inhibit.sh
		# прячет модем от MM (иначе MM и uqmi дерутся за cdc-wdm), и остаётся
		# только чтение - т.е. auto=qmi осознанно лишал бы пользователя управления.
		# Проверено: в этой композиции MM поднимает модем сразу и отдаёт всё.
		# Условие СТРОГО на qmi_wwan: в MBIM-композиции наоборот - там MM неверно
		# классифицирует порт и строит нерабочий модем (см. шапку файла).
		if [ "$PROTO" = "qmi" ] && [ -f /lib/netifd/proto/modemmanager.sh ] && is_compal "" "$DEV"; then
			PROTO="modemmanager"
		fi
		;;
	*) PROTO="$REQ" ;;
esac

# --- ModemManager service, MULTI-MODEM aware. MM must run if THIS interface OR
# any EXISTING interface uses the modemmanager proto (they need MM). Only
# stop+disable MM when nothing needs it and a kernel proto (mbim/qmi) needs the
# control channel free. Previously this blindly disabled MM for any non-MM proto
# (e.g. creating an atc interface), which took the OTHER modemmanager modems
# down. A restart (when MM must run) also clears a wedged MM. ---
# ПРИСУТСТВИЕ, а не только конфиг: интерфейс отсутствующего модема больше не
# держит MM запущенным (см. mmneed.sh - там же объяснение, чем это вредно).
_MM_WANT=0
[ "$PROTO" = "modemmanager" ] && _MM_WANT=1
[ "$_MM_WANT" = "1" ] || /usr/share/5gmodem/mmneed.sh check 2>/dev/null | grep -q '"needed":1' && _MM_WANT=1
if [ "$_MM_WANT" = "1" ]; then
	/etc/init.d/modemmanager enable >/dev/null 2>&1
	mm_restart_safe
elif [ "$PROTO" = "mbim" ] || [ "$PROTO" = "qmi" ] || uci show network 2>/dev/null | grep -qE "\.proto='(mbim|qmi)'"; then
	/etc/init.d/modemmanager stop >/dev/null 2>&1
	/etc/init.d/modemmanager disable >/dev/null 2>&1
fi

# --- AT / serial control port (for serial-based protos) ---
ATP=$(uci -q get "5gmodem.$MSEC.at_port")
[ -n "$ATP" ] || ATP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
[ -n "$ATP" ] || ATP=$(/usr/share/5gmodem/detect.sh 2>/dev/null)

# --- device path for the interface, by proto family ---
case "$PROTO" in
	modemmanager)
		# MM wants the modem's USB sysfs path: walk up from cdc-wdm to the node
		# that carries idVendor (the usb_device).
		IDEV=$(readlink -f "/sys/class/usbmisc/$(basename "${DEV:-cdc-wdm0}")/device" 2>/dev/null)
		while [ -n "$IDEV" ] && [ "$IDEV" != "/" ] && [ ! -f "$IDEV/idVendor" ]; do
			IDEV=$(dirname "$IDEV")
		done
		[ -f "$IDEV/idVendor" ] || IDEV=""
		;;
	mbim|qmi)
		# control channel over the cdc-wdm node
		IDEV="$DEV"
		;;
	xmm|ncm|atc|3g|wwan|ppp)
		# serial-controlled protos talk AT on a ttyUSB/ttyACM port. xmm тоже
		# дозванивается по AT-порту (Intel/Fibocom L850/FM350 NCM), НЕ по cdc-wdm.
		IDEV="$ATP"
		;;
	*)
		# unknown proto: prefer the cdc-wdm node, fall back to the AT port
		IDEV="${DEV:-$ATP}"
		;;
esac

[ -n "$IDEV" ] || { json nomodem "$PROTO" ""; exit 1; }

# --- (re)write the interface ---
# keep the existing APN if the interface already exists, else a generic default
OLDAPN=$(uci -q get "network.$IF.apn")
# сохраняем тип PDP через пересоздание (см. коммент в ветке fibocom выше)
OLDPDP=$(uci -q get "network.$IF.pdptype")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.pdp")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.iptype")
uci -q delete "network.$IF" 2>/dev/null
uci set "network.$IF=interface"
uci set "network.$IF.proto=$PROTO"
uci set "network.$IF.device=$IDEV"
set_apn_opt "$IF" "$OLDAPN"
case "$PROTO" in
	modemmanager)
		set_pdp_opt "$IF" iptype   # у прото modemmanager опция называется iptype
		;;
	qmi|mbim)
		set_pdp_opt "$IF" pdptype
		uci set "network.$IF.auth=none"
		;;
	xmm)
		set_pdp_opt "$IF" pdp        # прото xmm читает опцию 'pdp', не 'pdptype'
		uci set "network.$IF.auth=none"
		;;
	ncm|atc|3g|wwan)
		# серийные протоколы: базовый auth; порт (ttyUSB) уже задан выше.
		# Часть модемов требует ещё 'mode'/'delay'/'service' - это оставляем
		# на доводку в стандартном разделе Сеть > Интерфейсы.
		uci set "network.$IF.auth=none"
		;;
esac
uci commit network

# add to the 'wan' firewall zone (if one exists) so NAT/forwarding works.
# Самолечащий (см. выше): убрать все дубликаты $IF, добавить ровно один.
Z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
if [ -n "$Z" ]; then
	while uci -q get "firewall.$Z.network" | grep -qw "$IF"; do
		uci del_list "firewall.$Z.network=$IF"
	done
	uci add_list "firewall.$Z.network=$IF"
	uci commit firewall
fi

# point the app at the interface, and remember the user's protocol choice
# (auto/mbim/modemmanager/qmi) so the settings page shows it on return - done
# here, on the router, so LuCI does not raise an "unsaved changes" banner.
if [ "$_IS_ACTIVE" = 1 ]; then
	uci -q set "5gmodem.@5gmodem[0].network=$IF"
	uci -q set "5gmodem.@5gmodem[0].iface_proto=$REQ"
fi
# remember the interface+proto for THIS modem so switching back restores it and
# the other modem keeps its own separate interface (no clobbering, distinct IP).
if [ -n "$MSEC" ]; then
	if ! uci -q get "5gmodem.$MSEC" >/dev/null 2>&1; then
				# Заводим секцию ПОЛНОЙ (path + vidpid + product из listmodems), а
				# не голой: пересозданный после delprofile профиль иначе оставался
				# без vid:pid и «безымянным». Модель дольёт опрос метрик (AT+CGMM).
				uci -q set "5gmodem.$MSEC=modem"
				uci -q set "5gmodem.$MSEC.path=$AMP"
				_mk_lm=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
				_mk_vp=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].vidpid" 2>/dev/null | head -1)
				_mk_pr=$(echo "$_mk_lm" | jsonfilter -e "@[@.path=\"$AMP\"].product" 2>/dev/null | head -1)
				[ -n "$_mk_vp" ] && uci -q set "5gmodem.$MSEC.vidpid=$_mk_vp"
				[ -n "$_mk_pr" ] && uci -q set "5gmodem.$MSEC.product=$_mk_pr"
			fi
	uci -q set "5gmodem.$MSEC.network=$IF"
	uci -q set "5gmodem.$MSEC.iface_proto=$REQ"
	# см. ту же ветку выше: интерфейс пересоздан для этого модема - метка снята.
	uci -q delete "5gmodem.$MSEC.foreign_iface" 2>/dev/null
fi
stamp_iface "$IF" "$AMP"
uci -q commit 5gmodem

# SMS/USSD routing must follow the modem's owner:
#  - modemmanager: MM captures all messaging -> use the mmcli path
#  - mbim/qmi (umbim/uqmi): MM is off -> use the raw AT port (sms_tool),
#    which needs the WMS routes on the SIM (set below) to receive SMS.
# This keeps the SMS/USSD pages working whichever interface is active,
# instead of silently talking to a daemon that is no longer running.
if uci -q get sms_tool_js.@sms_tool_js[0] >/dev/null 2>&1; then
	case "$PROTO" in
		modemmanager)
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=1"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=1"
			;;
		*)
			# любой не-MM протокол: MM выключен -> SMS/USSD через AT-порт
			uci -q set "sms_tool_js.@sms_tool_js[0].sms_via_mm=0"
			uci -q set "sms_tool_js.@sms_tool_js[0].ussd_via_mm=0"
			;;
	esac
	uci -q commit sms_tool_js
fi

# WMS SMS routes: this modem's factory default stores incoming messages in NV,
# where MBIM/ModemManager/AT cannot read them. Redirect classes to the SIM (uim)
# so incoming SMS are received. The hotplug does this on device appearance, but
# switching to modemmanager here does not re-enumerate USB, so re-apply on every
# switch. qmicli works over QMI-in-MBIM even while ModemManager owns the modem.
if [ -n "$DEV" ] && command -v qmicli >/dev/null 2>&1; then
	for c in 0 1 2 3 none; do
		qmicli -p -d "$DEV" \
			--wms-set-routes="type=point,class=$c,storage=uim,receipt-action=store-and-notify" \
			>/dev/null 2>&1
	done
fi

# refresh the ModemManager ignore list for the chosen proto: hide the modem from
# MM for kernel protos (qmi/mbim/...), or let MM see it for the modemmanager proto

# Флаг «прятать от ModemManager» для ЭТОГО модема: включаем всем kernel-прото
# (MM и ядро не делят один управляющий канал - MM забирает его, и интерфейс
# остаётся без IP), выключаем для прото modemmanager - им MM обязан управлять.
# Ставим при КАЖДОМ создании: смена прото меняет и правильное значение. Дальше
# пользователь может переопределить галкой в настройках модема.
if [ -n "$MSEC" ]; then
	case "$PROTO" in
		modemmanager) uci -q set "5gmodem.$MSEC.mm_exclude=0" ;;
		*)            uci -q set "5gmodem.$MSEC.mm_exclude=1" ;;
	esac
	uci -q commit 5gmodem
	# применить немедленно, не дожидаясь 15-секундного прохода демона
	/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1 &
fi

if [ "$PROTO" = "modemmanager" ]; then
	# ifup ТОЛЬКО после того, как MM реально увидит модем. Сразу после
	# (пере)запуска MM модема ещё нет - он допрашивает порты десятки секунд, - а
	# прото modemmanager в этот момент не находит его, netifd пишет "Device not
	# managed by ModemManager", кладёт интерфейс и БОЛЬШЕ НЕ ПРОБУЕТ. Именно так
	# после пересоздания интерфейса модем оставался registered, но без IP.
	# В ФОНЕ и с отвязанными дескрипторами: скрипт зовут через rpcd (LuCI
	# fs.exec), а тот ждёт EOF на пайпах и упирается в свой 30-секундный таймаут -
	# ожидание в основном потоке дало бы UI "ошибку XHR" при успешной операции.
	(
		_n=0
		while [ "$_n" -lt 120 ]; do
			mmcli -L 2>/dev/null | grep -q "/Modem/" && break
			sleep 2; _n=$((_n + 2))
		done
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null &
elif [ "$PROTO" = qmi ] || [ "$PROTO" = mbim ]; then
	# kernel-прото: сначала автоматически привести модем в рабочее состояние
	# (отобрать порт у MM, снять зависшие uqmi, при заклиненном QMI - сбросить
	# модем), и только потом ifup. Иначе netifd упрётся в мёртвый управляющий
	# канал и зациклится, оставив модем без интернета до ручного вмешательства.
	# В ФОНЕ с отвязанными дескрипторами: подготовка может занять до ~2 минут
	# (сброс + переэнумерация), а rpcd ждёт EOF и упал бы по таймауту (XHR error).
	(
		kernel_proto_prepare "$IDEV" "$AMP" || logger -t 5gmodem-mkiface \
			"kernel_proto_prepare failed for $IF ($PROTO) - bringing it up anyway"
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null &
else
	ifup "$IF" >/dev/null 2>&1
fi

json created "$PROTO" "$IDEV"
exit 0
