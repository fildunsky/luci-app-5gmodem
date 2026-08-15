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
# ДОБАВИТЬ ИНТЕРФЕЙС В ЗОНУ wan - ЧЕРЕЗ ПОЛНУЮ ПЕРЕСБОРКУ СПИСКА.
#
# ЗАЧЕМ ТАК, А НЕ add_list. Список сетей зоны в /etc/config/firewall бывает ДВУХ
# видов, и оба законны:
#     list network 'wan'      list network 'wan6'     <- список
#     option network 'wan wan6'                       <- одна строка
# `uci add_list` на ВТОРОЙ вид не разбирает строку, а считает её ОДНИМ элементом:
# получается список из «wan wan6» (сети с таким именем нет) и нашего модема. То
# есть настоящий wan ВЫПАДАЕТ из зоны - вместе с ним пропадает NAT, и роутер
# продолжает работать сам, а вот локалка остаётся без интернета. Ровно этот
# случай пришёл от пользователя после «настроил и перезагрузил».
# `uci get` оба вида отдаёт одинаково - словами через пробел, - поэтому читаем,
# разбираем по пробелам и пересобираем ЯВНЫМ списком. Заодно это чинит уже
# испорченную зону и убирает дубликаты (старые версии добавляли интерфейс по
# нескольку раз - он появлялся в «Приоритете интернета» четырежды).
_fw_zone_add() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	[ -n "$_fz" ] && [ -n "$1" ] || return 0
	# КАВЫЧКИ СНИМАЕМ. Если элемент списка содержит пробел (ровно то, что
	# оставляла прошлая версия: один элемент «wan wan6»), uciget отдаёт его в
	# одинарных кавычках - и разбор по пробелам дал бы «'wan» и «wan6'». Убрав
	# кавычки, мы заодно РАСКЛЕИВАЕМ такой элемент обратно в две сети, то есть
	# чиним уже испорченную зону.
	_fcur=$(uci -q get "firewall.$_fz.network" | tr -d "'\"")
	# ЧИСТУЮ ЗОНУ НЕ ПЕРЕСОБИРАЕМ (ревью, баг №9): delete+rebuild оставляет в
	# общем стейджинге /tmp/.uci окно «зона без сетей», и оборванная операция
	# детонирует чужим commit'ом - вся локалка без NAT. Полная пересборка
	# остаётся только для грязного списка (дубликаты/склейка).
	_fdirty=0; _fseen=" "
	for _fe in $_fcur; do
		case "$_fseen" in *" $_fe "*) _fdirty=1 ;; esac
		_fseen="$_fseen$_fe "
	done
	if [ "$_fdirty" = 0 ]; then
		case " $_fcur " in *" $1 "*) return 0 ;; esac
		uci add_list "firewall.$_fz.network=$1"
		uci commit firewall
		return 0
	fi
	uci -q delete "firewall.$_fz.network"
	for _fe in $_fcur; do
		[ "$_fe" = "$1" ] && continue
		uci add_list "firewall.$_fz.network=$_fe"
	done
	uci add_list "firewall.$_fz.network=$1"
	uci commit firewall
}

stamp_iface() {
	stamp_iface_owner "$1" "$2"
}

# Записать APN интерфейса $1 по правилам выше ($2 = прежний APN)
# Метрика нового аплинка по умолчанию: ступень ниже базы «Приоритета
# интернета» (база переключаемая, см. _metric_base в netpri.sh) - созданный
# интерфейс никогда не перехватывает default-маршрут у соседей.
_def_metric() {
	if [ "$(uci -q get 5gmodem.@5gmodem[0].mwan3_metrics)" = "1" ]; then
		echo 20
	else
		echo 110
	fi
}

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

# $5 - ЯВНЫЙ выбор галки «Скрыть от ModemManager» из формы создания интерфейса
# (1 прятать, 0 отдать MM). Пусто/иное = аргумент не передан -> mkiface сам ставит
# дефолт по прото (см. ниже). Нужно, чтобы снятая пользователем галка не затиралась
# безусловным дефолтом при создании QMI/MBIM-интерфейса.
MMEXCLARG="$5"

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
	# СВОЙ счётчик: _n принадлежит вызывающим циклам (kernel_proto_prepare
	# крутит while по _n и зовёт нас внутри - общий _n давал вечный цикл, ревью)
	_rb_n=0
	while kill -0 "$_p" 2>/dev/null && [ "$_rb_n" -lt "$_lim" ]; do sleep 1; _rb_n=$((_rb_n + 1)); done
	kill -9 "$_p" 2>/dev/null
	cat "$_out" 2>/dev/null
	rm -f "$_out"
}

# QMI отвечает? Спрашиваем UIM (а НЕ --get-pin-status: на EC21 он штатно отдаёт
# "Not supported" даже на здоровом модеме, это не признак поломки).
#
# ТОЛЬКО через qmi-proxy (-p) и qmicli, НЕ через прямой uqmi. run_bounded ниже
# добивает зависший вызов через kill -9, а убитый ПРЯМОЙ QMI-клиент не
# освобождает свой client-ID на модеме - утечка. Копясь, они исчерпывают пул
# ('ClientIdsExhausted'), и ModemManager перестаёт инициализировать модем
# ('unknown-capabilities' -> у Compal пропадали и данные, и управление бендами).
# С -p убитый qmicli пул не трогает: client-ID держит ПРОКСИ. uqmi прокси не
# умеет, поэтому спрашиваем UIM через qmicli --uim-get-card-status.
qmi_alive() {   # $1 = cdc-wdm
	case "$(run_bounded 8 qmicli -d "$1" -p -t 5 --uim-get-card-status 2>/dev/null)" in
		*"card status"*|*"Card state"*|*present*) return 0 ;;
	esac
	return 1
}

# AT-порт этого модема (для сброса)
at_port_of() {   # $1 = usb path
	for _t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		# at_query вместо своего run_bounded: он делает то же (таймаут), но ещё и
		# берёт очередь к порту. Здесь это важнее всего - мы перебираем порты и
		# запросто пересекаемся с опросом метрик соседнего модема.
		case "$(at_query "$_t" "AT+CGMM" 6)" in
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
	# СЕЙЧАС - делаем синхронный проход инхибиции.
	# ЗДЕСЬ БЫЛ РЕСТАРТ MM («аккуратно перезапускаем, чтобы отпустил наш») -
	# и он РВАЛ СОСЕДА: MM на SIGTERM штатно разрывает соединения ВСЕХ своих
	# модемов (caught signal -> bearer finished), интерфейс соседа падал и
	# поднимался только через mm-recover. Живой случай 03.08.2026: воткнули
	# SIM7100E (qmi) - «переподключился» внутренний Compal под MM. Прото уже
	# закоммичен к этому моменту, поэтому inhibit_pass точечно заберёт у MM
	# именно наш модем, не трогая остальные.
	if pgrep -f ModemManager >/dev/null 2>&1; then
		if mmcli -L 2>/dev/null | grep -q "/Modem/"; then
			echo "prepare: инхибирую $_path у ModemManager (соседей не трогаем)" >&2
			/usr/share/5gmodem/mm-inhibit.sh once >/dev/null 2>&1
			_n=0
			while [ "$_n" -lt 20 ]; do
				_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_path" 2>/dev/null)
				[ -n "$_mi" ] || break
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
	( at_query "$_atp" "AT+CFUN=1,1" 6 ) >/dev/null 2>&1 </dev/null &

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
note_foreign_uci network "mkiface"
note_foreign_uci firewall "mkiface"
AMP=${MODEM_PATH:-$(uci -q get 5gmodem.@5gmodem[0].active_modem)}
_ACTPATH=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_IS_ACTIVE=1
[ -n "$MODEM_PATH" ] && [ -n "$_ACTPATH" ] && [ "$MODEM_PATH" != "$_ACTPATH" ] && _IS_ACTIVE=0
MSEC=""
WANTWDM=""

# AT-ПОРТ ЦЕЛЕВОГО МОДЕМА - ИЗ РЕЕСТРА, А ГЛОБАЛЬНЫЙ ОТКАТ ТОЛЬКО ДЛЯ АКТИВНОГО.
#
# Ниже было дважды (METRIC_AT для atc/xmm и ATP для серийных прото) одно и то же:
#   порт из секции -> ИНАЧЕ глобальный @5gmodem[0].at_port -> ИНАЧЕ detect.sh
# Оба отката описывают АКТИВНЫЙ модем. А mkiface вызывается и для НЕАКТИВНЫХ -
# ровно для этого выше считается _IS_ACTIVE и запрещается запись в глобальные
# ключи. Но на ЧТЕНИЕ тот же запрет не распространялся, и у модема без своего
# at_port в секции интерфейс получал `device` = AT-порт СОСЕДА: для atc/xmm это
# дозвон в чужой модем (у них device и есть порт дозвона). Та же дыра была в
# bands.sh и закрыта там же тем же правилом.
#
# Порт из реестра вдобавок СВЕРЕН со списком портов этого модема - устаревшую
# настройку (модем переставили, композиция сменилась) реестр гасит сам.
_mk_atport() {
	[ -n "$AMP" ] || return 0
	_ma=$(/usr/share/5gmodem/registry.sh path "$AMP" 2>/dev/null \
		| jsonfilter -e '@.at_port' 2>/dev/null)
	[ -n "$_ma" ] && { printf '%s' "$_ma"; return 0; }
	[ "$_IS_ACTIVE" = "1" ] || return 0
	_ma=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	[ -n "$_ma" ] || _ma=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	printf '%s' "$_ma"
}

if [ -n "$AMP" ]; then
	MSEC=$(secname "$AMP")
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
	WANTWDM=$(/usr/share/5gmodem/registry.sh path "$AMP" 2>/dev/null \
		| jsonfilter -e '@.wdm[0]' 2>/dev/null)
	# РЕЕСТР МОЖЕТ ОТСТАВАТЬ - ПЕРЕСПРАШИВАЕМ SYSFS.
	#
	# Пустой WANTWDM ниже означает «у модема нет канала управления» и уводит его
	# в AT-дозвон (proto=fibocom). Но пустым он бывает и просто потому, что
	# автонастройка началась раньше, чем реестр увидел свежий узел: на хотплаге
	# это доли секунды. Живой случай 01.08.2026: Compal в композиции 1e2d:00b7
	# (QMI!) получил proto=fibocom и device=wwan0 - штамп остался в секции
	# навсегда. sysfs детерминирован: воткнут - есть, и стоит одного взгляда.
	if [ -z "$WANTWDM" ]; then
		for _w in /sys/bus/usb/devices/"$AMP":*/usbmisc/cdc-wdm* \
		          /sys/bus/usb/devices/"$AMP":*/usbmisc/wdm*; do
			[ -e "$_w" ] || continue
			WANTWDM="/dev/$(basename "$_w")"
			logger -t 5gmodem-mkiface "реестр не отдал канал управления для $AMP, нашёл в sysfs: $WANTWDM"
			break
		done
	fi
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
		# «данные в роуминге» сохраняем через пересоздание, как pdptype (см. ниже)
		OLDROAM=$(uci -q get "network.$IF.allow_roaming")
		# МЕТРИКА - ЭТО ПРИОРИТЕТ, ВЫСТАВЛЕННЫЙ ПОЛЬЗОВАТЕЛЕМ (netpri пишет её в
		# uci). Безусловное metric=20 ниже сбрасывало порядок аплинков при каждом
		# пересоздании интерфейса (смена SIM, hotplug, кнопка) - сохраняем, как APN.
		OLDMETRIC=$(uci -q get "network.$IF.metric")
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

		# ИСКЛЮЧЕНИЕ ИЗ ЭТОГО ПРАВИЛА - INTEL XMM (вендор 8087: Fibocom L850,
		# L860 и родня в NCM-композиции). Им fibocom не подходит В ПРИНЦИПЕ, а не
		# «хуже работает»: у xmm.sh сверх нашего дозвона есть две обязательные
		# вещи - `ip link set dev <ncm> arp off` (на NCM-канале XMM модем на ARP не
		# отвечает, и без этого адрес есть, а трафика нет) и чтение DNS
		# интеловской XDNS вместо CGCONTRDP. Пользователь с L850+L860 (Cudy
		# TR3000) поднял связь ровно так: proto=xmm, device=/dev/ttyACM0.
		#
		# Регрессии здесь быть не может: до правки глоба ttyACM наш прото у этих
		# модемов вообще не находил AT-порта, то есть рабочих установок на
		# fibocom с вендором 8087 не существует. Явный выбор пользователя
		# (REQ=fibocom) не трогаем - только автоопределение.
		if { [ "$REQ" = auto ] || [ -z "$REQ" ]; } && [ -f /lib/netifd/proto/xmm.sh ] \
		   && [ "$(cat "/sys/bus/usb/devices/$AMP/idVendor" 2>/dev/null)" = "8087" ]; then
			FPROTO=xmm
			logger -t 5gmodem-mkiface "Intel XMM ($AMP) - ставлю proto=xmm: fibocom на NCM-канале не поднимет трафик"
		fi

		if [ "$FPROTO" = atc ] || [ "$FPROTO" = xmm ]; then
			# atc И xmm дозваниваются ПО AT-ПОРТУ (ttyACM/ttyUSB), а сетевое
			# устройство (wwan*/eth*) выводят сами. Поэтому device = AT-порт, НЕ
			# net-устройство. Раньше xmm валился в общую fibocom-ветку и получал
			# device=<net> (wwan2) - протокол xmm делает basename $device и ищет его
			# в /sys/class/tty: net-нода там отсутствует => "AT port not valid!" и
			# "Device path not found!" в цикле (живой баг на L850 после FM350 в том
			# же USB-разъёме). Даём отдельный от метрик AT-порт, чтобы дозвон и
			# периодический опрос не сталкивались на одном tty.
			METRIC_AT=$(_mk_atport)
			DIALPORT=""
			# ПОРТ ДОЗВОНА ИЩЕМ ТЕМ ЖЕ АРБИТРОМ, ЧТО И ПОРТ МЕТРИК.
			#
			# Здесь стоял голый `at_query "AT"` с выходом на ПЕРВОМ ответившем. У
			# многопортовых модемов этого мало: на голый AT отзываются и
			# вспомогательные/DIAG-порты, модемом при этом не являясь. detect.sh
			# знает это давно и потому ходит двумя проходами через atprobe -
			# сперва ищет порт, отвечающий моделью на AT+CGMM.
			#
			# Живой стенд (FM350, 03.08.2026): настоящие модемные порты - ttyUSB1
			# и ttyUSB3, а «первым ответившим» оказывался ttyUSB0. Его и получал
			# xmm/atc, после чего падал с «AT port not answer!» по кругу, а
			# интерфейс показывал NO_DEVICE. Тот же двухпроходный отбор здесь
			# закрывает вопрос: сперва настоящий модемный порт, и лишь потом любой
			# отвечающий.
			#
			# Формы глоба - все четыре: у cdc_acm (ttyACM, Intel XMM) узел лежит
			# под <интерфейс>/tty/, прямого потомка нет. См. portmap.sh.
			# ПРОБНИК = ИНСТРУМЕНТ ПРОТОКОЛА (для xmm): см. пояснение в msw/iface.sh.
			_dp_gcom=""
			[ "$FPROTO" = xmm ] && [ -f /etc/gcom/probeport.gcom ] \
				&& command -v gcom >/dev/null 2>&1 && _dp_gcom=1
			for DPMODE in model at; do
				for t in /sys/bus/usb/devices/$AMP:*/ttyUSB* /sys/bus/usb/devices/$AMP:*/tty/ttyUSB* \
				         /sys/bus/usb/devices/$AMP:*/ttyACM* /sys/bus/usb/devices/$AMP:*/tty/ttyACM*; do
					[ -e "$t" ] || continue
					tt="/dev/$(basename "$t")"
					[ "$tt" = "$METRIC_AT" ] && continue
					if [ -n "$_dp_gcom" ]; then
						DEVPORT="$tt" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || continue
					elif [ "$DPMODE" = model ]; then
						/usr/share/5gmodem/atprobe.sh "$tt" model >/dev/null 2>&1 || continue
					else
						/usr/share/5gmodem/atprobe.sh "$tt" >/dev/null 2>&1 || continue
					fi
					DIALPORT="$tt"; break
				done
				[ -n "$DIALPORT" ] && break
			done
			[ -n "$DIALPORT" ] || DIALPORT="$METRIC_AT"
			uci set "network.$IF.proto=$FPROTO"
			uci set "network.$IF.device=$DIALPORT"
			set_apn_opt "$IF" "$OLDAPN"
			# имя опции у протоколов разное: atc читает 'pdp', xmm тоже 'pdp'.
			set_pdp_opt "$IF" pdp upper
			# И СЛОВАРЬ ЗНАЧЕНИЙ У НИХ СВОЙ: IP / IPV6 / IPV4V6. Нашего «IPV4» в
			# нём нет - xmm.sh (строка 146) молча заменяет неизвестное на IP, то
			# есть в конфиге стояло бы одно, а модем набирал бы другое. Пишем
			# сразу то, что протокол понимает; смысл тот же (IP = IPv4).
			[ "$(uci -q get "network.$IF.pdp")" = "IPV4" ] && uci set "network.$IF.pdp=IP"
			uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
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
		uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
		[ -n "$OLDROAM" ] && uci set "network.$IF.allow_roaming=$OLDROAM"
		uci commit network


		# в зону wan - для NAT/forwarding (см. _fw_zone_add выше)
		_fw_zone_add "$IF"

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
		if uci -q get 5gmodem.sms >/dev/null 2>&1; then
			uci -q set "5gmodem.sms.sms_via_mm=0"
			uci -q set "5gmodem.sms.ussd_via_mm=0"
			uci -q commit 5gmodem
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
		# СОХРАНЁННЫЙ ВЫБОР ПОЛЬЗОВАТЕЛЯ ГЛАВНЕЕ АВТО-ДЕТЕКТА. Смена прото из UI
		# вызывает переэнумерацию модема, hotplug-автонастройка пересоздаёт
		# интерфейс с auto - и детект по драйверу узла МОЛЧА возвращал прежний
		# kernel-прото, стирая только что сделанный выбор (живой случай
		# 31.07.2026: Compal перевели на modemmanager, после переэнумерации
		# интерфейс снова mbim, MM выключен apply_mm_state, метрики пустые -
		# «Модем не подключен» при живом IP). iface_proto пишется в секцию при
		# каждом ЯВНОМ выборе; swap_cleanup чистит его при смене железа в
		# разъёме, так что чужому модему он не достанется.
		_mki_saved=$(uci -q get "5gmodem.$MSEC.iface_proto" 2>/dev/null)
		if [ -n "$_mki_saved" ] && [ "$_mki_saved" != "auto" ] \
		   && [ -f "/lib/netifd/proto/$_mki_saved.sh" ]; then
			PROTO="$_mki_saved"
			logger -t 5gmodem "mkiface: auto -> сохранённый выбор пользователя ($_mki_saved)"
		else
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
		# Путь модема (AMP) передаём ЯВНО: без него is_compal падал в глобальный
		# grep по ВСЕЙ шине, и на двухмодемном роутере СОСЕДНИЙ Compal превращал
		# чужой QMI-модем (T99W175) в proto=modemmanager - «программа затёрла
		# мой тип интерфейса».
		if [ "$PROTO" = "qmi" ] && [ -f /lib/netifd/proto/modemmanager.sh ] && is_compal "$AMP" "$DEV"; then
			PROTO="modemmanager"
		fi
		# Dell DW5821e / Foxconn T77W968 (413c:81d7) - ИСКЛЮЧЕНИЕ в пользу
		# ModemManager. У этого модуля штатный mbim НЕ поднимает сессию: umbim
		# либо валится на «Failed to attach to network», либо считает блокером
		# сервисный PIN2 (pintype 3) и выдаёт PIN_FAILED вместе с
		# proto_block_restart. QMI-путь тоже не годится: quectel-CM выдаёт IP,
		# но трафик не идёт (RX=0). ModemManager с тем же модемом и той же SIM
		# работает - подтверждено ПЯТЬЮ независимыми пользователями (Билайн,
		# YOTA, МТС; OpenWrt 24.10 и 25.12; MediaTek, Radxa, x86).
		# Раньше auto по драйверу cdc_mbim уводил такого пользователя в путь,
		# который заведомо не работает, и он неделями искал причину.
		_mki_vp=""
		[ -n "$AMP" ] && [ -f "/sys/bus/usb/devices/$AMP/idVendor" ] && \
			_mki_vp="$(cat "/sys/bus/usb/devices/$AMP/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$AMP/idProduct" 2>/dev/null)"
		# 05c6:9025 - модули на Qualcomm SDX55 (Foxconn T99W175 / Dell, Compal в
		# debug-композиции). Здесь причина другая, чем у 81d7: сессию qmi поднимает,
		# но КАНАЛ cdc-wdm у него один, а нам он нужен постоянно - диапазоны и режим
		# сети у SDX55 управляются ТОЛЬКО через ModemManager, метрики полнее по
		# QMI-generic. При proto=qmi каналом владеет netifd через uqmi, наши
		# запросы туда запрещены (см. qmicli_p), то есть половина возможностей
		# приложения выключена, а при попытке читать - соединение срывалось:
		# «Failed to parse message data», интерфейс навсегда pending, лечилось
		# только удалением пакета (отчёт 29.07, Banana Pi R4).
		# Под ModemManager канал общий через qmi-proxy, и конфликта нет вовсе.
		# 0489:e0b5 - тот же T77W968/DW5821e-eSIM под Foxconn VID: подтверждено на
		# чистой установке 03.08.2026 (Cudy TR3000): umbim циклически валит подъём
		# («Subscriber init failed», мусорные PIN-поля), под MM модем стабилен.
		case "$_mki_vp" in
			413c:81d7|0489:e0b5|05c6:9025)
				if [ -f /lib/netifd/proto/modemmanager.sh ]; then
					logger -t 5gmodem "mkiface: $_mki_vp - ведём через ModemManager (общий канал, иначе конфликт за cdc-wdm)"
					PROTO="modemmanager"
				fi
				;;
			# 05c6:90d5 - MV31-W / T99W175 в MBIM-композиции (тот же SDX55, что 9025):
			# umbim держит AT-порт метриками, местами даёт адрес без трафика - вендор-путь
			# ModemManager. НО 90d5 делит vid:pid с Compal-прототипом, а Compal в MBIM MM
			# строит нерабочим - поэтому ТОЛЬКО когда это НЕ Compal.
			05c6:90d5)
				if [ -f /lib/netifd/proto/modemmanager.sh ] && ! is_compal "$AMP" "$DEV"; then
					logger -t 5gmodem "mkiface: 05c6:90d5 (MV31-W/T99W175, не Compal) - ведём через ModemManager"
					PROTO="modemmanager"
				fi
				;;
		esac
			# SimCom QMI-модемы (SIM7100E, 1e0e:*): в 802.3 не отдают DHCP -
			# интерфейс без адреса (uqmi connected, RX=0). Ведём на proto=qmiraw
			# (raw-ip + статика из QMI, см. /lib/netifd/proto/qmiraw.sh).
			if [ "$PROTO" = "qmi" ] && [ -f /lib/netifd/proto/qmiraw.sh ]; then
				case "$_mki_vp" in
					1e0e:*) logger -t 5gmodem "mkiface: $_mki_vp - SimCom QMI: proto=qmiraw (802.3 без DHCP)"; PROTO="qmiraw" ;;
					*)
						# Прочие QMI: на qmiraw, только если модем НАТИВНО в raw-ip. Стоковый qmi
						# в raw-ip раздаёт адрес DHCP'ом (в raw-ip ненадёжно) - адрес есть, а
						# трафика нет (Telit LM960). qmiraw берёт IP статикой из QMI. 802.3-модемы
						# читаются как 802-3 и остаются на стоковом qmi - их не трогаем.
						if [ -c "$DEV" ]; then
							# qmicli -p (через qmi-proxy) - тот же путь, что в sessionwatch;
						# надёжнее uqmi WDA (тот часто «Failed to connect to service»).
						# timeout: не виснуть, если канал занят (передетект при живом
						# интерфейсе). Пусто/таймаут -> НЕ raw-ip -> стоковый qmi.
						_mki_fmt=$(timeout 5 qmicli -p -d "$DEV" --wda-get-data-format 2>/dev/null \
							| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
							if [ "$_mki_fmt" = "raw-ip" ]; then
								logger -t 5gmodem "mkiface: $_mki_vp - модем нативно raw-ip: proto=qmiraw (raw-ip+статика)"
								PROTO="qmiraw"
							fi
						fi
						;;
				esac
			fi
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
	# РАБОТАЮЩИЙ MM НЕ ПЕРЕЗАПУСКАЕМ. Здесь стоял безусловный mm_restart_safe
	# («заодно лечит клин») - и создание интерфейса ЛЮБОГО модема рестартовало
	# здоровый MM вместе с СОСЕДОМ: тот штатно рвал его соединение (caught
	# signal -> bearer finished), интерфейс падал и поднимался только через
	# mm-recover. Живой случай 03.08.2026: воткнули SIM7100E (qmi) - внутренний
	# Compal под MM переподключился. Клин MM - забота mm-recover/пересборки,
	# а не побочный эффект mkiface чужого модема.
	if ! pgrep -f ModemManager >/dev/null 2>&1; then
		mm_restart_safe
	elif [ "$PROTO" = "modemmanager" ] && ! mmcli -L 2>/dev/null | grep -q "/Modem/"; then
		# MM жив, но не видит НИ ОДНОГО модема, а этому интерфейсу он нужен -
		# похоже на пропущенные события (libudev-zero, [[mm-boot-race]]).
		# Единственный случай, когда рестарт уместен: подключённых модемов в
		# MM нет, значит и рвать ему некого.
		mm_restart_safe
	fi
elif [ "$PROTO" = "mbim" ] || [ "$PROTO" = "qmi" ] || [ "$PROTO" = "qmiraw" ] || uci show network 2>/dev/null | grep -qE "\.proto='(mbim|qmi|qmiraw)'"; then
	/etc/init.d/modemmanager stop >/dev/null 2>&1
	/etc/init.d/modemmanager disable >/dev/null 2>&1
fi

# --- AT / serial control port (for serial-based protos) ---
ATP=$(_mk_atport)

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
	mbim|qmi|qmiraw)
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

# Стабильный sysfs-путь ИНТЕРФЕЙСА-контроллера (родитель cdc-wdm), напр.
# /sys/devices/.../1-1.2/1-1.2:1.4. Он привязан к ТОПОЛОГИИ USB (путь + номер
# интерфейса) и НЕ меняется при ре-энумерации, тогда как номер /dev/cdc-wdmN -
# меняется. Отдаём его в devpath: системный qmi/mbim.sh по нему при КАЖДОМ setup
# находит актуальный cdc-wdm заново -> netdev всегда СВОЙ (wwan этого модема).
# Зачем: без этого после ре-энумерации /dev/cdc-wdmN указывал на ДРУГОЙ модем,
# qmi.sh резолвил его wwan (соседа), DHCP-ребёнок садился на wwan соседа и при
# обрыве отпускал ЕГО аренду - у рабочего модема пропадал интернет (два
# одинаковых 05c6:9025, отчёт ZBT). device оставляем как фолбэк.
ctrl_devpath() { readlink -f "/sys/class/usbmisc/$(basename "${1:-}")/device" 2>/dev/null; }

# --- (re)write the interface ---
# keep the existing APN if the interface already exists, else a generic default
OLDAPN=$(uci -q get "network.$IF.apn")
# сохраняем тип PDP через пересоздание (см. коммент в ветке fibocom выше)
OLDPDP=$(uci -q get "network.$IF.pdptype")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.pdp")
[ -n "$OLDPDP" ] || OLDPDP=$(uci -q get "network.$IF.iptype")
# Сохраняем «данные в роуминге» через пересоздание - как pdptype. Иначе выбор
# пользователя (галочка Allow data roaming) стирался на каждом пересборе
# интерфейса (переключение SIM/eSIM, кнопка «создать интерфейс», hotplug), и в
# роуминге данные не поднимались - выглядело как «галочка не сохраняется».
OLDROAM=$(uci -q get "network.$IF.allow_roaming")
# Метрика: сохранить пользовательскую, новому интерфейсу дать 20 - как в ветках
# fibocom/atc/xmm. Раньше qmi/mbim/modemmanager создавались БЕЗ метрики: их
# default-маршрут получал metric 0 и бил всех, а в «Приоритете интернета» слот
# нельзя было сдвинуть ниже соседей, пока метрику не выставят руками (живой
# отчёт Cudy TR3000 + DW5821e, 03.08.2026: MM-интерфейс с metric 0).
OLDMETRIC=$(uci -q get "network.$IF.metric")
# DNS пользователя (если вписал руками) сохраняем через пересоздание, как apn.
OLDDNS=$(uci -q get "network.$IF.dns")
uci -q delete "network.$IF" 2>/dev/null
uci set "network.$IF=interface"
uci set "network.$IF.proto=$PROTO"
uci set "network.$IF.device=$IDEV"
set_apn_opt "$IF" "$OLDAPN"
case "$PROTO" in
	modemmanager)
		set_pdp_opt "$IF" iptype   # у прото modemmanager опция называется iptype
		;;
	qmi|mbim|qmiraw)
		set_pdp_opt "$IF" pdptype
		uci set "network.$IF.auth=none"
		# Привязка к железу через стабильный путь (см. ctrl_devpath выше).
		_mdp=$(ctrl_devpath "$IDEV")
		[ -n "$_mdp" ] && [ -d "$_mdp/usbmisc" ] && uci set "network.$IF.devpath=$_mdp"
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
[ -n "$OLDROAM" ] && uci set "network.$IF.allow_roaming=$OLDROAM"
uci set "network.$IF.metric=${OLDMETRIC:-$(_def_metric)}"
# DNS-ФОЛБЭК. Часть операторов/модемов не отдаёт DNS на интерфейс: IP есть, а
# сайты не открываются, пока пользователь не впишет DNS руками. Свой DNS задаётся
# тумблером «Fallback DNS» на карточке модема (verb setopt dnsfb) и хранится прямо
# в network.<iface>.dns - здесь мы лишь ПЕРЕНОСИМ его через пересоздание
# интерфейса. По умолчанию фолбэк выключен, автоматически ничего не ставим.
[ -n "$OLDDNS" ] && uci set "network.$IF.dns=$OLDDNS"
uci commit network

# ПЕРЕЗАГРУЗИТЬ КОНФИГ netifd - ОБЯЗАТЕЛЬНО, И ИМЕННО ЗДЕСЬ.
#
# Секция интерфейса только что ПЕРЕСОЗДАНА (delete + set + commit), а ifup ниже
# работает с копией конфига, которую netifd загрузил В ПАМЯТЬ раньше - о новой
# секции он не знает. Живой случай (DW5821e на Radxa, issue #7): netifd держал
# интерфейс с proto «none» от прежней загрузки, наш recovery дёргал ifup по
# кругу, netifd на каждый раз отвечал «Cannot set device name: /sys/... longer
# than max size 15» (для proto none поле device он разбирает как имя сетевухи
# и режет по точке) - и модем «не заводился» до ручного вмешательства.
# reload сам поднимает autostart-интерфейсы; ifup после него безвреден.
ubus call network reload >/dev/null 2>&1

# СОЗДАЛИ ИНТЕРФЕЙС НА НАШЕМ ШЕЛЛ-ПРОТО, А NETIFD ЕГО НЕ ЗНАЕТ - вот
# ЕДИНСТВЕННЫЙ момент, когда рестарт сети оправдан: без него интерфейс мёртв
# («Не поддерживаемый тип протокола»), человек настраивает модем прямо сейчас
# и короткий обрыв ждёт. Постинст пакета сеть ради регистрации НЕ трогает
# (уронил удалённый роутер - см. register_proto.sh), поэтому форс отсюда.
case "$FPROTO" in
	fibocom) REGISTER_PROTO_FORCE=1 /usr/share/5gmodem/register_proto.sh >/dev/null 2>&1 ;;
esac
# Наш proto=qmiraw (SimCom raw-ip) - та же регистрация, что и fibocom: netifd
# знает обработчики только со старта, а свежесозданный qmiraw-интерфейс без
# регистрации мёртв («Не поддерживаемый тип протокола»).
case "$PROTO" in
	qmiraw) REGISTER_PROTO_FORCE=1 /usr/share/5gmodem/register_proto.sh >/dev/null 2>&1 ;;
esac

# в зону wan - для NAT/forwarding (см. _fw_zone_add выше)
_fw_zone_add "$IF"

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
if uci -q get 5gmodem.sms >/dev/null 2>&1; then
	case "$PROTO" in
		modemmanager)
			uci -q set "5gmodem.sms.sms_via_mm=1"
			uci -q set "5gmodem.sms.ussd_via_mm=1"
			;;
		*)
			# любой не-MM протокол: MM выключен -> SMS/USSD через AT-порт
			uci -q set "5gmodem.sms.sms_via_mm=0"
			uci -q set "5gmodem.sms.ussd_via_mm=0"
			;;
	esac
	uci -q commit 5gmodem
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
# ЕСЛИ форма создания передала явный выбор ($5=0|1) - уважаем его (снятая галка не
# должна затираться дефолтом). Иначе ставим дефолт по прото; смена прото меняет и
# правильное значение. Дальше пользователь может переопределить галкой в настройках.
if [ -n "$MSEC" ]; then
	if [ "$PROTO" = "modemmanager" ]; then
		# прото modemmanager требует, чтобы MM видел модем - прятать нельзя,
		# иначе интерфейс останется без IP. Явный выбор здесь игнорируем.
		uci -q set "5gmodem.$MSEC.mm_exclude=0"
	else
		case "$MMEXCLARG" in
			0|1) uci -q set "5gmodem.$MSEC.mm_exclude=$MMEXCLARG" ;;  # выбор из формы
			*)   uci -q set "5gmodem.$MSEC.mm_exclude=1" ;;           # дефолт kernel-прото
		esac
	fi
	uci -q commit 5gmodem
	# ПЕРЕХОД НА modemmanager СНИМАЕТ ДЕРЖАТЕЛЯ ИНХИБИЦИИ ЯВНО. Флаг mm_exclude
	# выше уже сброшен, но уже ЗАПУЩЕННЫЙ процесс mmcli --inhibit-device живёт,
	# пока его не убьют - и модем моргал в MM после смены прото QMI -> MM
	# (живой случай 31.07.2026: Telit то виден, то нет, метрики скакали).
	# Симметрично ветке set-exclude 0 в mm-inhibit.sh.
	if [ "$PROTO" = "modemmanager" ] && [ -n "$AMP" ]; then
		_mki_ipf="/var/run/5gmodem-mm-inhibit/$AMP.pid"
		[ -f "$_mki_ipf" ] && { kill "$(cat "$_mki_ipf" 2>/dev/null)" 2>/dev/null; rm -f "$_mki_ipf"; }
	fi
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
elif [ "$PROTO" = qmi ] || [ "$PROTO" = mbim ] || [ "$PROTO" = qmiraw ]; then
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
elif [ "$PROTO" = xmm ] || [ "$PROTO" = atc ]; then
	# ДОЗВОН ТОЛЬКО ПОСЛЕ РЕГИСТРАЦИИ В СЕТИ.
	#
	# У xmm/atc дозвон идёт AT-скриптом сразу, а модуль после включения ищет
	# сеть ещё десятки секунд. Дозвон в незарегистрированный модем ПРОХОДИТ, но
	# контекст не получает адрес - netifd пишет «Failed to configure interface»
	# и валится в цикл перезапусков; следующая попытка уже не может открыть
	# порт («AT port not answer!»), и интерфейс не поднимается вовсе, хотя
	# модем к этому времени давно в сети. Живой отчёт (L860-GL-16, чистая
	# прошивка, 03.08.2026): первый заход дошёл до «PDP type is: IP» ->
	# Failed to configure, дальше только AT port not answer, а рядом снятый
	# отчёт показывал уже +CEREG: 2,1 (зарегистрирован).
	#
	# Ждём CEREG/CGREG 1 (домашняя) или 5 (роуминг) до 90 c; модем, снятый с
	# регистрации (+COPS: 2), подталкиваем AT+COPS=0 - тем же приёмом, что и
	# fibocom.sh. Не дождались - поднимаем как есть: сторож переподнимет.
	(
		_xr_at=$(_mk_atport)
		if [ -n "$_xr_at" ] && [ -e "$_xr_at" ]; then
			_xr_n=0
			while [ "$_xr_n" -lt 90 ]; do
				_xr_o=$(sms_tool -d "$_xr_at" at "AT+CEREG?;+CGREG?;+COPS?" 2>/dev/null | tr -d '\r')
				case "$_xr_o" in
					*"+CEREG: "*",1"*|*"+CEREG: "*",5"*|*"+CGREG: "*",1"*|*"+CGREG: "*",5"*)
						logger -t 5gmodem-mkiface "$IF ($PROTO): модем зарегистрирован за ${_xr_n}c - дозваниваюсь"
						break ;;
				esac
				case "$_xr_o" in
					*"+COPS: 2"*)
						logger -t 5gmodem-mkiface "$IF ($PROTO): модем снят с регистрации (+COPS: 2) - толкаю AT+COPS=0"
						sms_tool -d "$_xr_at" at "AT+COPS=0" >/dev/null 2>&1 ;;
				esac
				sleep 5; _xr_n=$((_xr_n + 5))
			done
			[ "$_xr_n" -ge 90 ] && logger -t 5gmodem-mkiface \
				"$IF ($PROTO): регистрации нет за 90c - поднимаю интерфейс как есть"
		fi
		ifup "$IF"
	) >/dev/null 2>&1 </dev/null &
else
	ifup "$IF" >/dev/null 2>&1
fi

json created "$PROTO" "$IDEV"
exit 0
