#!/bin/sh
#
# Internet-priority switcher. Lists the interfaces in the firewall 'wan' zone
# that currently have an IPv4 address, and makes one of them the primary uplink
# by giving it the lowest route metric (others get a high metric). The chosen
# uplink then wins the default route.
#
# Usage:
#   netpri.sh list          - JSON array of WAN-zone interfaces with an IP
#   netpri.sh set <iface>   - make <iface> primary (metric 10), others 20, 30...
#

# networks that belong to the firewall 'wan' zone
wan_nets() {
	z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	[ -n "$z" ] && uci -q get "firewall.$z.network"
}

. /usr/share/5gmodem/atlock.sh
. /usr/share/5gmodem/lib.sh

# СОСТОЯНИЕ ИНТЕРФЕЙСОВ - ОДНИМ ДАМПОМ НА ВЕСЬ ВЫЗОВ.
#
# ifup_state = `ifstatus <if> | jsonfilter` - ДВА процесса на КАЖДОЕ поле, а поля
# спрашиваются по три-четыре на интерфейс (тип, l3_device, адрес). На стенде это
# давало 11 ifstatus за один `netpri.sh list` из ~145 подпроцессов и 690 мс, и всё
# это каждые 5 c при открытой странице.
#
# `ubus call network.interface dump` отдаёт ВСЕ интерфейсы сразу, и выборка по
# нему даёт тот же ответ (сверено на стенде побайтово с ifstatus). Дамп берётся
# явно - тем, кто читает пачкой; без него поведение прежнее, так что вызывающие
# вне списка ничего не теряют.
_IFDUMP=""
ifdump_snapshot() { _IFDUMP=$(ubus call network.interface dump 2>/dev/null); }
# РАЗБОР ОДНОГО ИНТЕРФЕЙСА - ОДИН jsonfilter НА ВСЕ ЕГО ПОЛЯ.
#
# Раньше каждое поле стоило пары процессов (jsonfilter + head), а list спрашивает
# у интерфейса адрес, устройство и адрес ребёнка - по замеру на стенде это 25
# запусков jsonfilter и 40 head на вызов. Теперь объект интерфейса достаётся
# ОДИН раз, а поля вынимаются подстановками оболочки.
#
# ВАЖНО: заполнять только из ОСНОВНОЙ оболочки (в начале тела цикла) - вызов из
# `$(...)` ушёл бы в подоболочку, и запомненное умерло бы вместе с ней. На этих
# граблях уже стоял реестр: его «мемоизация» не работала ни разу.
_IFO_NAME=""; _IFO_DEV=""; _IFO_IP=""
_if_scan() {   # $1 - интерфейс
	_IFO_NAME="$1"; _IFO_DEV=""; _IFO_IP=""
	[ -n "$_IFDUMP" ] && [ -n "$1" ] || return 0
	_ifo=$(printf '%s' "$_IFDUMP" | jsonfilter -e "@.interface[@.interface=\"$1\"]" 2>/dev/null)
	[ -n "$_ifo" ] || return 0
	# Блок "inactive" держит ПРОШЛЫЕ адреса того же интерфейса. Без обрезки у
	# интерфейса без адреса мы бы вытащили старый и показали его как живой.
	_ifo="${_ifo%%\"inactive\"*}"
	case "$_ifo" in
		*'"l3_device": "'*) _ifx="${_ifo#*\"l3_device\": \"}"; _IFO_DEV="${_ifx%%\"*}" ;;
	esac
	case "$_ifo" in
		*'"ipv4-address": [ { "address": "'*)
			_ifx="${_ifo#*\"ipv4-address\": [ { \"address\": \"}"
			_IFO_IP="${_ifx%%\"*}" ;;
	esac
	return 0
}

ifup_state() {
	# Разобранный интерфейс - отвечаем из памяти, без процессов.
	if [ -n "$_IFO_NAME" ] && [ "$1" = "$_IFO_NAME" ]; then
		case "$2" in
			'@["l3_device"]')              printf '%s\n' "$_IFO_DEV"; return ;;
			'@["ipv4-address"][0].address') printf '%s\n' "$_IFO_IP"; return ;;
		esac
	fi
	if [ -n "$_IFDUMP" ]; then
		printf '%s' "$_IFDUMP" \
			| jsonfilter -e "@.interface[@.interface=\"$1\"]${2#@}" 2>/dev/null | head -1
		return
	fi
	ifstatus "$1" 2>/dev/null | jsonfilter -e "$2" 2>/dev/null
}
# Имена интерфейсов из дампа (для поиска детей "<имя>_4"): без дампа - как раньше.
_ifdump_names() {
	if [ -n "$_IFDUMP" ]; then
		printf '%s' "$_IFDUMP" | jsonfilter -e '@.interface[*].interface' 2>/dev/null
		return
	fi
	ubus call network.interface dump 2>/dev/null | jsonfilter -e '@.interface[*].interface' 2>/dev/null
}
# Экранирование для JSON. sed зовём ТОЛЬКО когда экранировать реально нечего -
# то есть почти никогда: в именах интерфейсов, моделях и операторах кавычек и
# обратных слэшей не бывает, а процесс на каждое поле - это 4 поля на аплинк.
json_esc() {
	case "$1" in
		*\\*|*\"*) printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*)         printf '%s' "$1" ;;
	esac
}

# {"running":N,"version":"..."} для одного сервиса (без перевода строки) -
# общее тело вербов svcstatus и svcall. Версия известных сервисов берётся из
# пакетного менеджера С КЭШЕМ на загрузку: опрос идёт раз в 5 секунд, а opkg на
# каждый тик - заметный процесс ради неизменного ответа (версия меняется только
# апгрейдом пакета, кэш в /tmp это переживёт).
_svc_json() {
	_sv_r=0
	if [ -n "$1" ] && [ -x "/etc/init.d/$1" ]; then
		if ubus -S call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true'; then
			_sv_r=1
		elif /etc/init.d/"$1" status >/dev/null 2>&1; then
			_sv_r=1
		fi
	fi
	# ВЕРСИЯ - ЛЮБОМУ СЕРВИСУ, А НЕ ТОЛЬКО zapret.
	#
	# В карточке верхняя строка показывает версию, и лишь при её отсутствии -
	# слово «Сервис». Раньше версию доставали ровно для одного сервиса, поэтому
	# у всех остальных (ZeroTier и прочих) там висело бесполезное «Сервис».
	# Имя пакета почти всегда совпадает с именем init-скрипта; не совпало -
	# просто останется пусто, и карточка выглядит как раньше.
	# Кэш обязателен: опрос идёт раз в 5 c, а apk/opkg - заметный процесс ради
	# значения, которое меняется только апгрейдом пакета.
	#
	# НО ЖИВЁТ ОН ДО АПГРЕЙДА, А НЕ ДО ПЕРЕЗАГРУЗКИ. Раньше файл в /tmp считался
	# верным всю загрузку - «версия же меняется только апгрейдом». Именно апгрейд
	# и ломал это рассуждение: пакет обновили, а карточка до перезагрузки роутера
	# показывала старую версию, и никакая чистка кэша браузера не помогала -
	# устаревшее значение лежало на роутере (живой случай 06.08.2026: ZeroTier
	# обновлён до 1.16.2, в карточке 1.16.0). Привязываемся к базе пакетов: она
	# при любой установке переписывается, поэтому кэш старше неё - недействителен.
	_sv_ver=""
	if [ -n "$1" ]; then
		_sv_vf="/tmp/5gmodem_svcver_$1"
		_sv_db=/lib/apk/db/installed
		[ -f "$_sv_db" ] || _sv_db=/usr/lib/opkg/status
		if [ -s "$_sv_vf" ] && [ ! "$_sv_db" -nt "$_sv_vf" ]; then
			read -r _sv_ver < "$_sv_vf"
		else
			if command -v opkg >/dev/null 2>&1; then
				_sv_ver=$(opkg list-installed "$1" 2>/dev/null \
					| awk '{sub(/-r[0-9]+$/, "", $3); print $3; exit}')
			else
				_sv_ver=$(apk info -v 2>/dev/null | grep "^$1-[0-9]" | head -1 \
					| sed "s/^$1-//; s/-r[0-9]*$//")
			fi
			printf '%s\n' "$_sv_ver" > "$_sv_vf"
		fi
	fi
	# ZeroTier: КАРТОЧКЕ НУЖЕН АДРЕС В СЕТИ, а не только «работает/нет».
	#
	# Смысл ZeroTier для пользователя ровно в этом адресе - по нему он ходит на
	# роутер издалека, и держать его в голове неудобно. Берём с интерфейса (zt*),
	# а не из zerotier-cli: cli требует authtoken и заметно дороже, тогда как
	# адрес уже назначен ядром. Сетей может быть несколько - показываем первый
	# адрес, этого достаточно для «куда подключаться».
	_sv_ip=""
	if [ "$1" = "zerotier" ] && [ "$_sv_r" = 1 ]; then
		for _sv_if in $(ls /sys/class/net 2>/dev/null | grep '^zt'); do
			_sv_ip=$(ip -4 -o addr show dev "$_sv_if" 2>/dev/null \
				| awk '{split($4, a, "/"); print a[1]; exit}')
			[ -n "$_sv_ip" ] && break
		done
	fi
	printf '{"running":%s,"version":"%s","ip":"%s"}' \
		"$_sv_r" "$(json_esc "$_sv_ver")" "$(json_esc "$_sv_ip")"
}

# СНИМОК ПЕРЕЧИСЛЕНИЯ МОДЕМОВ на один вызов. listmodems.sh спрашивался трижды за
# один `list`: список присутствующих путей и по разу на каждый модем в model_for.
# У самого listmodems есть кэш (9 мс тёплый), но каждый вызов - это ещё fork+shell,
# а мы в цикле. Снимок берётся явно, как и остальные (см. ifdump_snapshot).
_LM_SNAP=""
lm_snapshot() { _LM_SNAP=$("/usr/share/5gmodem/listmodems.sh" 2>/dev/null); }
_lm() {
	[ -n "$_LM_SNAP" ] && { printf '%s' "$_LM_SNAP"; return; }
	"/usr/share/5gmodem/listmodems.sh" 2>/dev/null
}

# IPv4 of an uplink. qmi/dhcp modems keep the real address on a dynamically
# created child interface "<name>_4" (the parent "<name>" stays up but IP-less),
# so if the parent has no address we look at its "<name>_*" children.
iface_ip() {
	p="$1"
	ip=$(ifup_state "$p" '@["ipv4-address"][0].address')
	[ -n "$ip" ] && { echo "$ip"; return; }
	for c in $(_ifdump_names | grep -E "^${p}_"); do
		ip=$(ifup_state "$c" '@["ipv4-address"][0].address')
		[ -n "$ip" ] && { echo "$ip"; return; }
	done
}

# СЕКЦИЯ МОДЕМА ПО ИНТЕРФЕЙСУ - С ЗАПОМИНАНИЕМ ОТВЕТА.
#
# Реализация одна (sec_for_iface в lib.sh), здесь только память на ответ: за один
# `list` она спрашивается по цепочке is_modem -> iface_type -> modem_path_for ->
# model_for -> label_for, то есть 4-6 раз НА КАЖДЫЙ интерфейс с одинаковым
# результатом. Ключ - имя интерфейса; в пределах одного вызова конфиг не меняется
# (list только читает).
# КАРТА «ИНТЕРФЕЙС -> СЕКЦИЯ», СОБРАННАЯ ОДНИМ ПРОХОДОМ.
#
# Прежняя «память на ответ» не работала НИ РАЗУ: modem_section почти всегда
# зовут из `$(...)`, а присваивание в подоболочке умирает вместе с ней (та же
# ловушка, что была в реестре). По замеру это стоило двадцати `sed` и полутора
# десятков `head` на один `list` - по паре процессов на каждое обращение.
# Теперь карта строится ЯВНО, один раз, из уже взятого снимка конфига.
_MS_MAP=""
ms_map_build() {
	_MS_MAP=" $(_uci5g_dump \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\?\([^']*\)'\?\$/\2=\1/p" \
		| tr '\n' ' ') "
}
modem_section() {
	[ -n "$1" ] || return 1
	# Первое совпадение - как у sec_for_iface (head -1): у интерфейса может быть
	# несколько секций, и порядок тот же, что в дампе конфига.
	case "$_MS_MAP" in
		*" $1="*)
			_msv="${_MS_MAP#* $1=}"
			printf '%s' "${_msv%% *}"
			return 0 ;;
	esac
	# Карта не построена (глагол не list) или интерфейс в ней не значится -
	# прежний путь.
	[ -n "$_MS_MAP" ] && return 0
	sec_for_iface "$1"
}
# Является ли $1 модем-интерфейсом? Мульти-модем -> m_*-секция; одиночный
# (legacy) конфиг -> @5gmodem[0].network указывает на этот интерфейс.
is_modem() {
	[ -n "$(modem_section "$1")" ] && return 0
	[ -n "$1" ] && [ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && return 0
	return 1
}
# USB-путь и AT-порт модема, обслуживающего $1, независимо от стиля конфига.
modem_path_for() {
	s=$(modem_section "$1")
	if [ -n "$s" ]; then uci5g_get "$s" path; return; fi
	[ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && uci5g_get "@5gmodem[0]" active_modem
}
modem_atport_for() {
	s=$(modem_section "$1")
	if [ -n "$s" ]; then uci5g_get "$s" at_port; return; fi
	[ "$1" = "$(uci5g_get "@5gmodem[0]" network)" ] && uci5g_get "@5gmodem[0]" at_port
}
# uplink kind: wan | modem | wifi | other. Modem interfaces are checked BEFORE the
# Wi-Fi guess, because a modem's l3_device can be wwanN (must not read as Wi-Fi).
# Есть ли в конфиге беспроводки wifi-iface, привязанный к этому интерфейсу.
# Дамп берём один раз на вызов: list проходит по всем аплинкам.
_WLD=""; _WLD_DONE=""
_is_wifi_cfg() {
	if [ -z "$_WLD_DONE" ]; then
		_WLD_DONE=1
		_WLD=$(uci -q show wireless 2>/dev/null)
	fi
	case "$_WLD" in
		*".network='$1'"*) return 0 ;;
		*) return 1 ;;
	esac
}

iface_type() {
	i="$1"
	is_modem "$i" && { echo modem; return; }
	dev=$(ifup_state "$i" '@["l3_device"]')
	case "$dev" in phy*-sta*|wlan*) echo wifi; return;; esac
	# УСТРОЙСТВА МОЖЕТ НЕ БЫТЬ ВОВСЕ - А ИНТЕРФЕЙС ВСЁ РАВНО Wi-Fi.
	# Пока станция ассоциирована, l3_device есть; стоит линку упасть (или netifd
	# расцепить интерфейс с радио - живой класс отказа, см. health.sh), устройство
	# исчезает, и тип становился «other». Последствие видел пользователь: из
	# модалки «Приоритет интернета» пропадала галка «Лечить Wi-Fi», потому что она
	# показывается только при наличии аплинка типа wifi, - то есть настройка
	# исчезала ровно тогда, когда она нужнее всего.
	# Судим по КОНФИГУ беспроводки, тем же правилом, что и сам сторож (health.sh:
	# is_wifi_iface), - иначе UI и лечение расходятся во мнении об одном линке.
	_is_wifi_cfg "$i" && { echo wifi; return; }
	case "$i" in wan|wan6) echo wan; return;; esac
	echo other
}

# AT-запрос - через общий at_query из lib.sh (очередь к порту, таймаут, проверка
# команды). Здесь была своя копия; она отличалась только параметрами, и они теперь
# передаются аргументами: таймаут 5 c, ожидание очереди 3 c.
#
# ЖДЁМ НЕДОЛГО И УХОДИМ. Имя оператора спрашивается на КАЖДОЙ загрузке страницы
# «Приоритет интернета», одновременно с опросом метрик. Задерживать страницу ради
# фоновой справки нельзя, а лезть в порт без очереди - тем более: под нагрузкой
# этот вызов чаще прочих не успевал взять блокировку и портил данные ТОМУ, кто
# дождался. Потерять одно обновление имени дёшево - оно кэшируется, и его же
# пишет основной опрос метрик. Код 2 от at_query означает ровно «порт занят».
_npri_at() {   # $1 - порт, $2 - команда
	at_query "$1" "$2" 5 3
	_na_rc=$?
	[ "$_na_rc" = 2 ] && logger -t 5gmodem "netpri: порт занят, имя оператора берём из кэша"
	return 0
}

# Cache-ONLY operator name (no AT, always instant). Empty if not cached / stale.
# 'list' uses this so it never blocks; the cache is filled by 'refresh' in the
# background. Cache is valid for 30 min.
operator_cached() {
	# HiLink-модем: имя оператора и настоящий адрес в сети берём у его API.
	# Через AT его не спросить, а интерфейсный адрес - это адрес ЛОКАЛЬНОЙ
	# сетевой карты модема (192.168.43.2), а не выданный оператором.
	# СНАЧАЛА ИМЯ ОТ ОСНОВНОГО ОПРОСА, и только потом API модема.
	#
	# Порядок был обратный, и у HiLink-модема в списке стоял оператор СЕТИ, а не
	# симки: у T-Mobile (MVNO на Tele2) API отдаёт "Tele2", тогда как главная
	# карточка честно показывала "T-Mobile". Разбор MVNO по коду из IMSI умеет
	# только основной опрос - он и должен быть первым источником.
	if [ -f "/tmp/5gmodem_op_$1" ] && [ -s "/tmp/5gmodem_op_$1" ]; then
		cat "/tmp/5gmodem_op_$1"; return
	fi
	# ЗДЕСЬ НЕ ХОДИМ В СЕТЬ. Функция обязана быть мгновенной - её зовёт "list"
	# на каждой загрузке страницы. Раньше ветка HiLink делала HTTP-запрос к
	# модему, и открытие «Сети» упиралось в него на секунды. Запрос перенесён в
	# operator_probe (фоновый refresh), сюда остался только чтение кэша.
	# ПРИОРИТЕТ у имени от ОСНОВНОГО опроса (5gmodem.sh пишет /tmp/5gmodem_op_<iface>):
	# только он разбирает UCS2, mccmnc.dat и MVNO. Наш operator_probe знает лишь
	# имя СЕТИ, поэтому раньше в «Приоритете интернета» появлялся «Tele2 RU» там,
	# где главная карточка честно показывала «T-Mobile»: probe писал свой кэш, а
	# он проверялся ПЕРВЫМ и затенял точное имя.
	if [ -s "/tmp/5gmodem_op_$1" ]; then cat "/tmp/5gmodem_op_$1"; return; fi
	# Фолбэк - собственный кэш probe: основной опрос ведёт файл только для
	# АКТИВНОГО модема, а в списке показываются все.
	cf="/tmp/netpri_op_$1"
	if [ -f "$cf" ] && [ -z "$(find "$cf" -mmin +30 2>/dev/null)" ]; then
		cat "$cf"; return
	fi
}

# Probe the operator for ONE modem iface via AT+COPS and cache the result (used only
# by 'refresh', never by 'list'). ttyUSB numbering is unstable, so the saved at_port
# can be stale after a renumber; we try it first, then fall back to the modem's
# CURRENT ttys resolved from its stable USB path (listmodems), stopping at the first
# port that returns an operator name. Each modem has its own ports - no switch.
operator_probe() {
	i="$1"
	is_modem "$i" || return
	# HiLink: имя оператора спрашиваем у его веб-API - AT-порта у такого модема
	# может не быть вовсе. Делаем это ЗДЕСЬ, в фоне, а не в "list".
	_op_sec=$(sec_for_iface "$i")
	if [ -n "$_op_sec" ] && [ "$(uci5g_get "$_op_sec" kind)" = "hilink" ]; then
		_op_p=$(uci5g_get "$_op_sec" path)
		_op_n=$(/usr/share/5gmodem/hilink.sh json "$_op_p" 2>/dev/null \
			| jsonfilter -e '@.operator_name' 2>/dev/null)
		[ -n "$_op_n" ] || _op_n=$(uci5g_get "$_op_sec" model)
		[ -n "$_op_n" ] && printf '%s' "$_op_n" > "/tmp/netpri_op_$i"
		return
	fi
	# MM-модемы: имя оператора берём из mmcli (AT+COPS конфликтует с
	# ModemManager, который держит порт, и на MBIM/QMI часто пуст).
	if [ "$(ucinet_get "$i" proto)" = "modemmanager" ]; then
		# ИНДЕКС ИМЕННО ЭТОГО МОДЕМА, А НЕ АКТИВНОГО.
		#
		# Здесь стоял безадресный mmindex, то есть индекс активного модема, а имя
		# записывалось в кэш опрашиваемого ($i). На двухмодемной машине это прямая
		# подмена: у человека с двумя T99W175 (30.07) модем БЕЗ SIM показывал
		# оператора соседа - и держал его 30 минут, пока жив кэш. Путь модема
		# стабилен, привязка «интерфейс -> путь» уже есть в modem_path_for.
		# Путь неизвестен - НЕ спрашиваем вовсе: пустой аргумент у mmindex
		# означает «активный», а это ровно та подмена, от которой уходим.
		_op_path=$(modem_path_for "$i")
		mi=""
		[ -n "$_op_path" ] && mi=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_op_path" 2>/dev/null)
		if [ -n "$mi" ]; then
			_mk=$(mmcli -m "$mi" -K 2>/dev/null)
			nm=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.3gpp\.operator-name *: *//p' | head -1)
			# Тот же последний шаг, что в AT-ветке: mmcli отдаёт имя СЕТИ
			# («MegaFon RUS»), а показывать надо выверенное («Megafon»), иначе
			# список и карточка подписаны по-разному (см. opname_pretty).
			_mc=$(printf '%s\n' "$_mk" | sed -n 's/^modem\.3gpp\.operator-code *: *//p' | head -1)
			[ "$_mc" = "--" ] && _mc=""
			[ -n "$nm" ] && [ "$nm" != "--" ] && {
				printf '%s' "$(opname_pretty "$_mc" "$nm")" > "/tmp/netpri_op_$i"; return; }
		fi
		# ИМЕНИ НЕТ - НА ЭТОМ И ЗАКАНЧИВАЕМ. Раньше отсюда проваливались в перебор
		# AT-портов ниже, и это било по самому больному: у модема под MM порты
		# принадлежат ему, а не нам. Пока модем не зарегистрирован (mmcli отдаёт
		# «--»), мы начинали слать AT во ВСЕ его tty подряд - включая те, что MM
		# отвёл под GPS и служебные. Живой случай: DW5821e в состоянии low power,
		# MM по кругу пытается его включить, а мы в это время дёргаем ttyUSB2
		# (gps) командой AT+COPS. Помочь это не может, помешать - вполне.
		#
		# Имя оператора подождёт: появится, как только модем зарегистрируется.
		return
	fi
	path=$(modem_path_for "$i")
	cands=$(modem_atport_for "$i")
	if [ -n "$path" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
		cands="$cands $(_lm | jsonfilter -e "@[@.path=\"$path\"].tty[*]" 2>/dev/null)"
	fi
	for port in $cands; do
		[ -n "$port" ] && [ -e "$port" ] || continue
		# "=3,0" selects long alphanumeric format (read-only), then query
		name=$(_npri_at "$port" "AT+COPS=3,0;+COPS?" | tr -d '\r' \
			| sed -n 's/.*+COPS[^"]*"\([^"]*\)".*/\1/p' | head -1)
		# collapse a doubled long name ("T-Mobile T-Mobile" -> "T-Mobile")
		name=$(printf '%s' "$name" | awk '{
			if (NF>0 && NF%2==0) { h=NF/2; same=1;
				for(j=1;j<=h;j++) if($j!=$(j+h)) same=0;
				if(same){ s=$1; for(j=2;j<=h;j++) s=s" "$j; print s; next } }
			print }')
		# ЧИСЛОВОЙ КОД НУЖЕН ВСЕГДА, а не только когда имени нет.
		#
		# Раньше формат 2 спрашивался лишь как фолбэк при пустом/числовом имени.
		# Но код нужен и при НЕПУСТОМ имени: по нему берётся выверенное написание
		# из mccmnc.dat, и без этого шага список подписывал модем сырым именем
		# сети («MegaFon RUS») там, где карточка показывает «Megafon» - см.
		# opname_pretty в lib.sh. Лишняя AT-команда идёт по той же очереди и
		# только в ФОНОВОМ refresh (list в порт не ходит вовсе).
		num=$(_npri_at "$port" "AT+COPS=3,2;+COPS?" | tr -d '\r' \
			| sed -n 's/.*+COPS[^"]*"\([0-9]\{4,\}\)".*/\1/p' | head -1)
		if [ -z "$name" ] || echo "$name" | grep -qE '^[0-9 ]*$'; then
			# tr -d '\r': mccmnc.dat в CRLF, иначе имя уезжает в кэш с возвратом
			# каретки на конце (см. lib.sh/opname_pretty и hilink.sh).
			[ -n "$num" ] && name=$(awk -F';' '/^'"$num"';/{print $3}' \
				/usr/share/5gmodem/mccmnc.dat 2>/dev/null | head -1 | tr -d '\r' \
				| sed 's/^ *//;s/ *$//')
		else
			name=$(opname_pretty "$num" "$name")
		fi
		[ -n "$name" ] && { printf '%s' "$name" > "/tmp/netpri_op_$i"; return; }
	done
}

# modem model name for the small top line (matches the modem-switch tab). Product
# from listmodems (by stable USB path), with a couple of friendly overrides.
model_for() {
	is_modem "$1" || return
	path=$(modem_path_for "$1")
	prod=""; vidpid=""; lmmodel=""
	if [ -n "$path" ]; then
		# Три поля - ОДИН вызов jsonfilter в фиксированном порядке: listmodems
		# печатает эти ключи всегда, пустое значение даёт пустую строку и порядок
		# не рвёт. Было шесть процессов на каждый модемный аплинк.
		_mf_i=0
		while IFS= read -r _mf_l; do
			_mf_i=$((_mf_i + 1))
			case "$_mf_i" in
				1) prod="$_mf_l" ;;
				2) vidpid="$_mf_l" ;;
				3) lmmodel="$_mf_l" ;;
			esac
		done <<MF_EOF
$(_lm | jsonfilter -e "@[@.path=\"$path\"].product" -e "@[@.path=\"$path\"].vidpid" -e "@[@.path=\"$path\"].model" 2>/dev/null)
MF_EOF
	fi
	# Имя модели, разобранное основным опросом по AT+CGMM (5gmodem.m_<путь>.model),
	# ТОЧНЕЕ дескриптора: у SimCom он говорит "SimTech, Incorporated", у Quectel
	# EC21 - "Android", а VID:PID 1e0e:9001 общий для 7100/7600/8200.
	sec=$(modem_section "$1")
	if [ -n "$sec" ]; then
		_m=$(uci5g_get "$sec" model)
		# Отсекаем ЧУЖУЮ/устаревшую модель, осевшую в секции от ПРЕЖНЕГО модема на
		# этом же USB-пути (опрос пишет model только активному, у неактивного она
		# висит вечно). Живой баг: "Compal RXM-G1" осел в секции FM350 (0e8d), и
		# FM350 показывался вторым «Compal» и в табах, и здесь в приоритетах.
		if [ -n "$_m" ] && [ -n "$vidpid" ] && ! _model_vendor_ok "$_m" "$vidpid"; then
			_m=""
		fi
		# ШТАМП ЖЕЛЕЗА - ТА ЖЕ ПРОВЕРКА, ЧТО В listmodems. Эвристика выше судит
		# по ИМЕНИ вендора и бессильна для неизвестных (Samsung 04e8 - «не судим»).
		# Живой случай 03.08.2026: во флип-флопе активного опрос прочитал CGMM
		# через чужой порт и записал «Fibocom FM350-GL» в секцию ТЕЛЕФОНА -
		# listmodems имя отбросил по штампу, а приоритеты показывали его дальше.
		_mvp=$(uci5g_get "$sec" model_vp)
		if [ -n "$_m" ] && [ -n "$_mvp" ] && [ -n "$vidpid" ] && [ "$_mvp" != "$vidpid" ]; then
			_m=""
		fi
		[ -n "$_m" ] && { echo "$_m"; return; }
	fi
	# ГОТОВОЕ НОРМАЛИЗОВАННОЕ ИМЯ ИЗ listmodems - ТО ЖЕ, ЧТО В ТАБАХ.
	#
	# Раньше поле model из listmodems здесь не читалось вовсе, хотя именно оно
	# приводит дескриптор к человеческому виду (model_alias + таблица vid:pid) и
	# именно его показывают вкладки переключателя модемов. В итоге один модем
	# назывался по-разному в двух местах одной страницы: вкладка «T99W175», а
	# приоритеты - «Generic Mobile Broadband Adapter» (05c6:9025 нормализуется в
	# listmodems, а в локальной таблице ниже его нет). Живой отчёт, 30.07.
	#
	# Стоит ПОСЛЕ секции (там имя от AT+CGMM, оно точнее) и ДО дескриптора.
	if [ -n "$lmmodel" ] && [ "$lmmodel" != "$prod" ]; then echo "$lmmodel"; return; fi
	if [ -z "$prod" ] && [ -n "$sec" ]; then prod=$(uci5g_get "$sec" product); fi

	# USB-дескриптор часто врёт: Quectel EC21 представляется как "Android",
	# Compal - как "VOS_5G". Поэтому НЕ доверяем product вслепую: сперва точная
	# модель по VID:PID, затем бренд по VID (как в modemtabs.js), и лишь потом
	# сам дескриптор.
	case "$vidpid" in
		2c7c:0121) echo "Quectel EC21"; return ;;
		2c7c:0125) echo "Quectel EC25"; return ;;
		2c7c:0296) echo "Quectel BG96"; return ;;
		2c7c:0306) echo "Quectel EP06"; return ;;
		2c7c:0512) echo "Quectel EG12"; return ;;
		2c7c:0620) echo "Quectel EM060K"; return ;;
		2c7c:0800) echo "Quectel RM500Q"; return ;;
		2c7c:0801) echo "Quectel RM520N"; return ;;
		2c7c:0900) echo "Quectel RG500Q"; return ;;
		2c7c:6005) echo "Quectel EC200A"; return ;;
		2dee:4d57) echo "MeigLink SLM770A"; return ;;
	esac
	case "$prod" in
		VOS_5G|RXMG1|RXM-G1) echo "Compal RXM-G1"; return ;;
		FM350*) echo "Fibocom $prod"; return ;;
	esac

	# Дескриптор бесполезен (Android/USB Modem/пусто) - подставляем бренд по VID.
	case "$prod" in
		''|[Aa]ndroid|USB*|[Mm]odem|*Composite*|*[Dd]evice\ [Bb]us*)
			case "${vidpid%%:*}" in
				2c7c) echo "Quectel"; return ;;
				1bc7) echo "Telit"; return ;;
				2cb7|0e8d) echo "Fibocom"; return ;;
				1e2d) echo "Cinterion"; return ;;
				12d1) echo "Huawei"; return ;;
				19d2) echo "ZTE"; return ;;
				2dee) echo "MeigLink"; return ;;
				0489) echo "Foxconn"; return ;;
				# 05c6 (Qualcomm) НЕ мапим в Compal: id общий для Compal RXM-G1,
				# Foxconn T99W175, Dell, Thales. Настоящий Compal ловится выше по
				# VOS_5G/RXMG1; прочим 05c6 бренд по vid не присваиваем.
			esac
			;;
	esac
	echo "$prod"
}

# SSID of a Wi-Fi station interface
ssid_for() {
	dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$dev" ] || return
	ubus call network.wireless status 2>/dev/null \
		| jsonfilter -e "@[*].interfaces[@.ifname=\"$dev\"].config.ssid" 2>/dev/null | head -1
}

# friendly label: modem -> operator ("Модем N" fallback), wifi -> SSID, wan -> WAN
label_for() {
	i="$1"
	case "$(iface_type "$i")" in
	wan)  echo "WAN" ;;
	wifi) s=$(ssid_for "$i"); [ -n "$s" ] && echo "$s" || echo "Wi-Fi" ;;
	modem)
		# operator name once known; until the background probe fills the cache, fall
		# back to the standardized interface name (modem / modem2), not "Модем N"
		op=$(operator_cached "$i")
		[ -n "$op" ] && echo "$op" || echo "$i" ;;
	*) echo "$i" ;;
	esac
}

# Живое переустановление default-маршрутов - общее для `set` и `order` (раньше
# в каждом жила своя копия ~50 строк, и правки v6-логики приходилось дублировать).
#
# Добавить default-маршрут интерфейса $1 с метрикой $2 (v4+v6). БЕЗ удаления -
# удаляем всё заранее (_del_all_default). Шлюз берём у netifd (авторитетно), а НЕ
# из живой таблицы: у не-primary интерфейса default-маршрута может не быть.
# 0.0.0.0/:: = честный on-link (у сотовых point-to-point шлюза нет). У интерфейса
# с адресом /32 (Wi-Fi client, сотовый) шлюз не on-link - сперва прямой маршрут
# до самого шлюза (как netifd).
_add_default_route() {   # $1 - iface, $2 - метрика
	_dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dev" ] || return 0
	_gw4=$(ifup_state "$1" '@.route[@.target="0.0.0.0"].nexthop')
	if [ -n "$_gw4" ] && [ "$_gw4" != "0.0.0.0" ]; then
		ip -4 route add "$_gw4" dev "$_dev" 2>/dev/null
		ip -4 route add default via "$_gw4" dev "$_dev" metric "$2" 2>/dev/null
	else
		# on-link default (сотовый point-to-point) - обязателен scope link.
		ip -4 route add default dev "$_dev" metric "$2" scope link 2>/dev/null
	fi
	# IPv6-шлюз ЖИВЁТ НЕ У РОДИТЕЛЯ. Default v6 обычно держит спутник
	# (`wan6`, `<имя>_6`) - отдельная сеть на ТОМ ЖЕ устройстве. Фаза удаления
	# сметает с устройства ОБЕ семьи маршрутов, а восстановление читало шлюз
	# только у самого интерфейса - у родителя его нет, спутник отсекает дедуп
	# по устройству. Итог: каждое переключение приоритета УБИВАЛО IPv6 default
	# до следующего события netifd. Теперь шлюз ищем и у спутников.
	_gw6=$(ifup_state "$1" '@.route[@.target="::"].nexthop')
	if [ -z "$_gw6" ] || [ "$_gw6" = "::" ]; then
		for _sat in "${1}6" "${1}_6"; do
			_gw6=$(ifup_state "$_sat" '@.route[@.target="::"].nexthop')
			[ -n "$_gw6" ] && [ "$_gw6" != "::" ] && break
		done
	fi
	[ -n "$_gw6" ] && [ "$_gw6" != "::" ] && \
		ip -6 route add default via "$_gw6" dev "$_dev" metric "$2" 2>/dev/null
}
# `ip route del default dev X` удаляет РОВНО ОДИН маршрут за вызов. Если на
# устройстве их несколько (разные метрики, формы via и on-link сосуществуют),
# один вызов сносит первый, а мы тут же добавляем новый - остаток копится с
# каждым переключением (наблюдалось вживую: шесть default-маршрутов вместо двух).
# Поэтому удаляем В ЦИКЛЕ, пока есть что удалять; потолок - страховка от вечного
# цикла.
_del_all_default() {   # $1 - l3_device
	_i=0; while [ "$_i" -lt 16 ]; do ip -4 route del default dev "$1" 2>/dev/null || break; _i=$((_i + 1)); done
	_i=0; while [ "$_i" -lt 16 ]; do ip -6 route del default dev "$1" 2>/dev/null || break; _i=$((_i + 1)); done
}

# ТРЕТЬЕ МНЕНИЕ - ЧЕРЕЗ ТУННЕЛЬ CLASH. Собственный трафик роутера идёт МИМО
# clash (tproxy перехватывает только форвард LAN), и на аплинке с блокировками
# прямые ICMP и TCP с роутера мертвы, хотя у клиентов сервис открывается.
# Замер делает САМ clash своим delay-API (тем же, каким SSClash меряет свои
# сервера): группа спрашивается по списку из /proxies, служебные пропускаются.
# ПРОБА ЧУЖИМИ РУКАМИ: ПУСТЬ CLASH САМ СХОДИТ НА ХОСТ.
#
# Свой трафик роутера идёт МИМО clash (tproxy перехватывает только форвард LAN),
# поэтому на заблокированном у оператора сервисе прямая проба всегда мертва -
# а у клиентов он открывается. HTTP-прокси (mixed-port) выручает не всегда: в
# полностью прозрачной схеме его вообще нет, объявлен только tproxy-port (живой
# конфиг 05.08.2026). Тогда спрашиваем сам clash по его API - он измеряет путь
# ровно тот, которым ходят клиенты.
# Имена групп идут В ПУТИ запроса: пробелы кодируем, а не-ASCII (эмодзи в
# названиях стран) пропускаем - кодировать их в shell дорого, а латинская
# группа есть в любом конфиге.
_clash_ping() {   # $1 - хост; печатает json и возвращает 0 при успехе
	command -v curl >/dev/null 2>&1 || return 1
	# ХОСТ СОХРАНЯЕМ СРАЗУ: ниже идёт `set --` для заголовка авторизации, а он
	# затирает позиционные параметры функции - и хост в URL уезжал пустым.
	_cp_h="$1"
	[ -n "$_cp_h" ] || return 1
	_cp_ctl=$(sed -n 's/^external-controller:.*:\([0-9]*\).*/\1/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	[ -n "$_cp_ctl" ] || _cp_ctl=9090
	# API может быть закрыт секретом - без заголовка он ответит 401, и проба
	# молча считала бы сервис недоступным.
	_cp_sec=$(sed -n 's/^ *secret *: *\(.*\)$/\1/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1 | tr -d '"'"'"' ')
	set --
	[ -n "$_cp_sec" ] && set -- -H "Authorization: Bearer $_cp_sec"
	_cp_n=0
	for _cp_g in $(curl -s -m 3 "$@" "http://127.0.0.1:$_cp_ctl/proxies" 2>/dev/null \
		| grep -o '"name":"[A-Za-z0-9_.-]*"' | cut -d'"' -f4 | sort -u); do
		case "$_cp_g" in GLOBAL|DIRECT|REJECT*|PASS*|COMPATIBLE|'') continue ;; esac
		_cp_n=$((_cp_n + 1)); [ "$_cp_n" -gt 4 ] && break
		# Сначала /generate_204 (лёгкий и без тела), затем корень: у части
		# сервисов такого пути нет, и clash отдаёт ошибку вместо задержки.
		for _cp_u in "https%3A%2F%2F$_cp_h%2Fgenerate_204" "https%3A%2F%2F$_cp_h%2F"; do
			_cp_d=$(curl -s -m 6 "$@" \
				"http://127.0.0.1:$_cp_ctl/proxies/$_cp_g/delay?timeout=4000&url=$_cp_u" 2>/dev/null \
				| sed -n 's/.*"delay":\([0-9]*\).*/\1/p')
			[ -n "$_cp_d" ] && { printf '{"ok":1,"ms":%s,"via":"proxy"}\n' "$_cp_d"; return 0; }
		done
	done
	return 1
}


case "$1" in
list)
	# СНИМКИ ПЕРЕД ЦИКЛОМ. `list` только читает и живёт доли секунды, поэтому
	# состояние интерфейсов, конфиг 5gmodem и перечисление модемов берём по одному
	# разу, а не по разу на каждое поле каждого интерфейса. Это и есть основная
	# цена этого глагола: замер на стенде до правки - 690 мс и ~145 подпроцессов
	# (70 uci, 34 sed, 19 jsonfilter, 11 ifstatus) на КАЖДЫЙ вызов, а страница
	# метрик зовёт его раз в 5 c.
	ifdump_snapshot
	uci5g_snapshot
	ucinet_snapshot
	lm_snapshot
	# Секундомер один на весь вызов: uptime_s - это чтение /proc/uptime отдельным
	# процессом, а нужен он в цикле по разу-два на карточку со сторожем.
	_NOW_S=$(uptime_s)
	# Настройку сторожа спрашиваем один раз на вызов, а не в каждой карточке.
	_HEALTH_ON=$(uci5g_get health enabled)
	# Переключение трафика - тем же снимком: страница обязана предупредить, когда
	# трафик держит линк БЕЗ интернета, а увести его некому (галка снята).
	_HEALTH_FO=$(uci5g_get health failover)
	ms_map_build
	# УСТРОЙСТВО, ЧЕРЕЗ КОТОРОЕ РЕАЛЬНО ИДЁТ ТРАФИК: default с наименьшей живой
	# метрикой. Нужно сторожу (health.sh): при штрафном переключении uci-порядок
	# и реальность расходятся, и подсветка активной карточки обязана следовать
	# реальности. Одна команда на весь list.
	_LIVE_DEV=$(ip -4 route show default 2>/dev/null | awk '{m=0; d=""; for(i=1;i<NF;i++){if($i=="dev")d=$(i+1); if($i=="metric")m=$(i+1)+0} if(d!="")print m, d}' | sort -n | head -1 | cut -d' ' -f2)
	printf '['
	first=1
	NEEDREFRESH=0
	# USB-пути присутствующих сейчас модемов (один вызов на весь список).
	PRESENT_PATHS=" $(_lm | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
	# sort by interface name, like the LuCI "Interfaces" overview (naturalCompare).
	# uniq: firewall-зона могла накопить дубликаты интерфейса (см. mkiface.sh) -
	# показываем каждый uplink РОВНО один раз, даже если конфиг ещё не вылечен.
	for n in $(wan_nets | tr ' ' '\n' | sort | uniq); do
		[ -n "$n" ] || continue
		ucinet_has "$n" || continue
		# Объект интерфейса - один раз на карточку (см. _if_scan).
		_if_scan "$n"
		# IPv6-спутник прячем: в OpenWrt он заводится отдельной сетью с именем
		# "<имя>6" поверх ТОГО ЖЕ устройства (wan/wan6, wwan/wwan6). Раньше
		# отсекался только "wan6" по имени, поэтому на роутере с модемом на usb0
		# в списке висели ДВА аплинка: wwan с адресом и wwan6 без него.
		# Приоритет задаётся маршруту устройства, так что спутник тут не нужен.
		#
		# НО СУДИТЬ ПО ОДНОМУ ИМЕНИ НЕЛЬЗЯ. Наши модемные интерфейсы нумеруются
		# (modem2, modem3, ...), и ШЕСТОЙ зовётся «modem6» - имя кончается на «6»,
		# интерфейс «modem» в конфиге есть (парковка прежнего модема держит имя), и
		# рабочий аплинк свежевоткнутого модема исчезал из приоритетов. Живой
		# случай: Quectel EC21 на месте Telit - модем работает, в списке его нет.
		# Настоящий спутник отличается ПРОТОКОЛОМ (dhcpv6/6in4/6to4/6rd) либо
		# device-ссылкой на родителя (@wan) - по ним и решаем; наши динамические
		# дети и вовсе зовутся «<имя>_6», с подчёркиванием.
		case "$n" in
			*6)
				if ucinet_has "${n%6}"; then
					_sat_p=$(ucinet_get "$n" proto)
					_sat_d=$(ucinet_get "$n" device)
					case "$_sat_p" in
						dhcpv6|6in4|6to4|6rd) continue ;;
					esac
					case "$_sat_d" in
						@*) continue ;;
					esac
				fi ;;
		esac
		[ "$(ucinet_get "$n" disabled)" = "1" ] && continue
		# Отсутствующий модем в списке приоритетов не нужен: его интерфейс остаётся
		# в firewall-зоне (мы его не удаляем - модем ещё вернётся), но выбирать его
		# приоритетом бессмысленно, трафика через него всё равно не будет. Прячем
		# ТОЛЬКО если модем наш и мы точно знаем его USB-путь: при неизвестной
		# секции (одномодемный legacy-конфиг) поведение прежнее - показываем.
		# Тип считаем ОДИН раз на интерфейс: iface_type = is_modem + jsonfilter
		# по снимку, и второй вызов ниже удваивал эти форки на каждый uplink.
		t=$(iface_type "$n")
		if [ "$t" = modem ]; then
			# У одного интерфейса может быть НЕСКОЛЬКО модем-секций: рядом с живой
			# остаётся устаревшая от прежнего модема на том же разъёме (её путь уже
			# не present). modem_section вернул бы ЛЮБУЮ, и если это оказалась
			# stale - живой модем пропадал из приоритетов. Поэтому смотрим ВСЕ
			# секции этого интерфейса и прячем, ТОЛЬКО если НИ ОДНА не присутствует.
			# Нет ни одной секции с путём (legacy-конфиг) - поведение прежнее: показываем.
			_any_path=""; _any_present=""; _any_parked=""
			for _ms in $(_uci5g_dump | sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\?$n'\?\$/\1/p"); do
				_mp=$(uci5g_get "$_ms" path)
				if [ -z "$_mp" ]; then
					# Секция БЕЗ пути - это ПАРКОВКА вытесненного модема (park_profile
					# в modemswitch.sh): она держит имя интерфейса за железом, которого
					# сейчас на шине нет. Раньше такая секция молча пропускалась, и
					# _any_path оставался пустым - интерфейс считался «legacy без пути»
					# и продолжал висеть в приоритетах (наблюдалось: modem4 от Compal
					# после возврата E3372). Парковка - достоверный признак отсутствия.
					[ "$(uci5g_get "$_ms" parked)" = "1" ] && _any_parked=1
					continue
				fi
				_any_path=1
				case "$PRESENT_PATHS" in *" $_mp "*) _any_present=1 ;; esac
				[ -n "$_any_present" ] && break
			done
			# РАБОЧИЙ АПЛИНК НЕ ПРЯЧЕМ НИКОГДА, НО И МОДЕМОМ НЕ ЗОВЁМ.
			#
			# Смысл правила выше - «модема нет, трафика через него не будет».
			# Если у интерфейса ЕСТЬ адрес, трафик как раз идёт, и прятать его -
			# значит врать и лишать человека возможности назначить приоритет.
			# Живой случай 03.08.2026: телефон в режиме USB-модема. Пока он отдавал
			# AT-порт, он числился модемом и получил нашу секцию; сменил композицию
			# на чистый тетеринг - модемом быть перестал, секция осталась владеть
			# интерфейсом, и рабочий аплинк пропал из приоритетов вместе с
			# интернетом, который через него шёл.
			#
			# Тип при этом ПОНИЖАЕМ до "other" - и только здесь, после решения о
			# скрытии. Менять его раньше (в iface_type) нельзя: весь этот блок
			# висит под `t = modem`, и тогда переставали прятаться интерфейсы
			# по-настоящему вынутых модемов. А без понижения подпись берётся из
			# model_for, который при отсутствующем пути подставляет имя ДРУГОГО
			# модема: на интерфейсе телефона красовалось «Fibocom FM350-GL».
			if [ -z "$_any_present" ] && { [ -n "$_any_path" ] || [ -n "$_any_parked" ]; }; then
				[ -z "$(iface_ip "$n")" ] && continue
				t=other
			fi
		fi
		# NOTE: no IP filter for modems/Wi-Fi - keep them visible even without an
		# address, so a modem that briefly drops its IP while re-dialing after a
		# switch does not vanish from the bar (which used to leave only Wi-Fi
		# looking "selected").
		ip=$(iface_ip "$n")
		# УСТРОЙСТВА НЕТ - МАРШРУТИЗИРОВАТЬ НЕ ЧЕРЕЗ ЧТО.
		#
		# Интерфейс вынутого USB-модема остаётся и в конфиге, и в firewall-зоне
		# (мы его намеренно не удаляем - модем вернётся), но предлагать его
		# приоритетом бессмысленно: трафика через него не будет.
		#
		# Проверка по нашим секциям выше покрывает не все случаи: она требует,
		# чтобы iface_type дал "modem", а у ОСИРОТЕВШЕГО интерфейса (профиль
		# модема удалён, а интерфейс остался) владельца уже нет, и тип выходит
		# "other". Живой пример: после того как вынули Huawei, "modem4" на eth3
		# висел в списке с пустым адресом.
		#
		# Судим только по ЯВНО заданному имени устройства. sysfs-путь (proto
		# modemmanager) и пустое поле не трогаем: там имя вычисляется иначе, и
		# ошибиться в эту сторону - значит спрятать рабочий аплинк.
		_np_dev=$(ucinet_get "$n" device)
		case "$_np_dev" in
			'') : ;;
			# Узел модема (/dev/cdc-wdm0) или sysfs-путь: проверяем НАПРЯМУЮ его
			# существование. Такой интерфейс тоже остаётся от вынутого модема -
			# на стенде "modem" на /dev/cdc-wdm0 висел в списке от Compal,
			# которого давно нет.
			/*) [ -e "$_np_dev" ] || [ -n "$ip" ] || continue ;;
			*)  [ -e "/sys/class/net/$_np_dev" ] || [ -n "$ip" ] || continue ;;
		esac
		# ИСКЛЮЧЕНИЕ - проводной WAN-порт. У него нет фазы «переподнимается»: нет
		# адреса = в порт ничего не воткнуто (или линк мёртв), и назначать его
		# приоритетом бессмысленно - трафика через него не будет. У пользователей
		# без провода он висел в панели постоянно и только мешал. Модемов и Wi-Fi
		# это НЕ касается: там пустой IP - нормальное временное состояние.
		[ "$t" = wan ] && [ -z "$ip" ] && continue
		[ "$t" = modem ] && [ -z "$(operator_cached "$n")" ] && NEEDREFRESH=1
		# small top line: modem model / Wi-Fi interface name / device for the rest
		# (never empty, so every button keeps the same three-line height)
		case "$t" in
			modem) sub=$(model_for "$n"); [ -n "$sub" ] || sub="$n" ;;
			wifi)  sub="$n" ;;
			*)     sub=$(ifup_state "$n" '@["l3_device"]')
			       [ -n "$sub" ] || sub=$(ucinet_get "$n" device)
			       [ -n "$sub" ] || sub="$n" ;;
		esac
		# У HiLink адрес интерфейса - это адрес ЛОКАЛЬНОЙ сети модема
		# (192.168.43.2), а не выданный оператором. Показываем настоящий, из API:
		# иначе в списке у всех таких модемов стоял бы адрес их внутренней сети.
		_np_s=$(modem_section "$n")
		if [ -n "$_np_s" ] && [ "$(uci5g_get "$_np_s" kind)" = "hilink" ]; then
			_np_wan=$(/usr/share/5gmodem/hilink.sh json "$(uci5g_get "$_np_s" path)" 2>/dev/null \
				| jsonfilter -e '@.ipaddr' 2>/dev/null)
			[ -n "$_np_wan" ] && ip="$_np_wan"
		fi
		m=$(ucinet_get "$n" metric); [ -n "$m" ] || m=0
		# Здоровье линка от сторожа (health.sh) - чтением файла состояния и
		# uci-снимка, без подпроцессов: list зовётся каждые 5 c. Нет файла или
		# слежение выключено - поля нет, страница точку не рисует.
		_np_h=""
		if [ "$_HEALTH_ON" = "1" ] && [ -f "/tmp/5gmodem_health/$n" ]; then
			if read -r _np_hst _np_hf _np_ho _np_hms _np_hs < "/tmp/5gmodem_health/$n" 2>/dev/null; then
				# Линк без устройства (gone) показываем - карточка обязана
				# пережить переэнумерацию при лечении; прячем, когда ничего не
				# поднимается дольше грейс-периода. Грейс зависит от контекста:
				# идёт лечение - ждём долго (перезагрузка модуля с лестницей -
				# это минуты), лечения нет - предположение «он перезагружается»
				# быстро теряет силу, две минуты и хватит.
				_np_gr=120
				[ -f "/tmp/5gmodem_health/$n.heal" ] && _np_gr=600
				if [ "$_np_hst" = "gone" ] && [ $(( _NOW_S - ${_np_hs:-0} )) -gt "$_np_gr" ]; then
					continue
				fi
				_np_h=",\"health\":\"$_np_hst\",\"hms\":${_np_hms:-0}"
				# идёт лечение - карточка рисует статус реанимации
				if [ -f "/tmp/5gmodem_health/$n.heal" ] \
				   && read -r _np_hstep _np_hlast _np_hn < "/tmp/5gmodem_health/$n.heal" 2>/dev/null; then
					_np_h="$_np_h,\"healstep\":${_np_hstep:-0},\"healn\":${_np_hn:-0},\"healmax\":6,\"healfor\":$(( _NOW_S - ${_np_hlast:-0} ))"
				fi
			fi
		fi
		if [ -n "$_LIVE_DEV" ]; then
			_np_ld=$(ifup_state "$n" '@["l3_device"]')
			[ -n "$_np_ld" ] || _np_ld=$(ifup_state "${n}_4" '@["l3_device"]')
			[ "$_np_ld" = "$_LIVE_DEV" ] && _np_h="$_np_h,\"live\":1"
		fi
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"iface":"%s","type":"%s","sub":"%s","label":"%s","ip":"%s","metric":%s%s}' \
			"$n" "$t" "$(json_esc "$sub")" "$(json_esc "$(label_for "$n")")" "$ip" "$m" "$_np_h"
	done
	# Последнее событие сторожа и его выключатели - хвостовым элементом ТОГО ЖЕ
	# списка: страница и так забирает list каждые 5 с, отдельный опрос ради двух
	# значений - лишний процесс. Фронт вынимает элемент с полем event до
	# отрисовки карточек (и берёт из него failover для предупреждения).
	if [ "$first" != 1 ] && [ "$_HEALTH_ON" = "1" ]; then
		_np_ev=""
		[ -s /tmp/5gmodem_health/.last_event ] && \
			read -r _np_ev < /tmp/5gmodem_health/.last_event 2>/dev/null
		printf ',{"event":"%s","failover":%s}' "$(json_esc "$_np_ev")" \
			"$([ "$_HEALTH_FO" = "1" ] && echo 1 || echo 0)"
	fi
	printf ']\n'
	# fill the operator cache in the background (bounded AT probes) for next time,
	# but at most once a minute so page polls don't pile up probes on a modem whose
	# operator can't be read.
	if [ "$NEEDREFRESH" = 1 ]; then
		stamp=/tmp/netpri_refresh
		if [ ! -f "$stamp" ] || [ -n "$(find "$stamp" -mmin +1 2>/dev/null)" ]; then
			: > "$stamp"
			# ДЕСКРИПТОРЫ ОТВЯЗЫВАЕМ ОТ ПОДОБОЛОЧКИ, а не от команды внутри.
			# Здесь стояло ( cmd >/dev/null 2>&1 & ) & - перенаправлена только
			# команда, а подоболочка продолжала держать унаследованный stdout,
			# и rpcd ЖДАЛ EOF, то есть конца фоновой пробы. На стенде это 11 c:
			# страница «Сеть» столько и висела при открытии.
			( /usr/share/5gmodem/netpri.sh refresh & ) >/dev/null 2>&1 </dev/null &
		fi
	fi
	;;

refresh)
	# (re)probe each modem uplink's operator name into the cache
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		[ "$(iface_type "$n")" = modem ] && operator_probe "$n"
	done
	;;

op)
	# Оператор ОДНОГО интерфейса (для автоподстановки APN на форме создания
	# интерфейса). Сначала мгновенный кэш; если пусто - разовый bounded-probe.
	#   op <iface> fresh - ОБОЙТИ кэш и опросить модем заново.
	# Это нужно странице настроек: кэш живёт 30 минут, и после смены SIM она
	# предлагала APN ПРЕЖНЕГО оператора. Тут лишние ~секунда опроса допустима -
	# страница открывается редко, в отличие от list, который дёргается поллом.
	I="${2:-$(uci -q get 5gmodem.@5gmodem[0].network)}"; [ -n "$I" ] || I=modem
	if [ "$3" = fresh ]; then
		# Сбрасываем ТОЛЬКО свой кэш. Файл /tmp/5gmodem_op_<iface> принадлежит
		# ОСНОВНОМУ опросу (5gmodem.sh) и содержит имя, разобранное со всей
		# логикой: UCS2, mccmnc.dat и, главное, MVNO (сеть Tele2 25020 -> бренд
		# «Т-Мобайл»). Наш operator_probe этого не умеет и вернул бы имя СЕТИ -
		# именно так в «Приоритете интернета» появлялся Tele2 вместо Т-Мобайла,
		# тогда как главная карточка показывала верно.
		rm -f "/tmp/netpri_op_$I"
		# Чтобы имя было и верным, и свежим (после смены SIM), просим основной
		# опрос перечитать модем - он и обновит свой кэш. Только для АКТИВНОГО
		# модема: 5gmodem.sh опрашивает именно его, и для другого интерфейса это
		# записало бы чужого оператора.
		# cached, а НЕ json: если страница или 5gtop только что опросили модем,
		# берём их снимок вместо второй ходки в порт. Раньше здесь был полный
		# опрос, и открытие «Приоритета интернета» на фоне открытой страницы
		# давало ровно ту конкуренцию, из-за которой опрос замедлялся втрое.
		if [ "$I" = "$(uci -q get 5gmodem.@5gmodem[0].network)" ]; then
			rm -f "/tmp/5gmodem_op_$I"
			/usr/share/5gmodem/5gmodem.sh cached 10 >/dev/null 2>&1
		fi
	fi
	OP=$(operator_cached "$I")
	[ -n "$OP" ] || { operator_probe "$I" 2>/dev/null; OP=$(operator_cached "$I"); }
	printf '%s' "$OP"
	;;

set)
	CH="$2"
	[ -n "$CH" ] || { echo '{"error":"no interface"}'; exit 1; }
	# ТОЛЬКО АПЛИНК ИЗ WAN-ЗОНЫ. Аргумент приходит из UI, но скрипт доступен
	# любому вызывающему, и без проверки `set lan` прошёл бы до живых маршрутов:
	# метрики пишутся циклом по wan_nets (lan не заденут), а вот
	# _add_default_route выполнялась для АРГУМЕНТА как есть - и на интерфейсе без
	# шлюза (lan статический) ветка on-link добавила бы
	# `default dev br-lan scope link metric 1`: маршрут-ловушку, уводящую весь
	# интернет-трафик обратно в локалку.
	case " $(wan_nets) " in
		*" $CH "*) ;;
		*) echo '{"error":"not a wan uplink"}'; exit 1 ;;
	esac
	note_foreign_uci network "netpri set"
	CHANGED=0
	# Метрики с шагом 10 (10, 20, 30...): остаётся место вставить линк между
	# существующими без перенумерации остальных, нет столкновения с чужой
	# metric=1 (её любят дефолтные конфиги), и это соглашение mwan3 - меньше
	# сюрпризов при сожительстве. Шаг оставляет место и под будущие «штрафные»
	# промежуточные значения сторожа.
	_mset=20
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		ucinet_has "$n" || continue
		if [ "$n" = "$CH" ]; then NEW=10; else NEW=$_mset; _mset=$((_mset + 10)); fi
		OLD=$(ucinet_get "$n" metric)
		[ "x$OLD" = "x$NEW" ] && continue
		uci -q set "network.$n.metric=$NEW"
		CHANGED=1
	done
	# ручной выбор пользователя снимает метку «оставлен в конце» у ожившего
	# линка (сторож, политика failback=demote) - порядок теперь снова его
	rm -f /tmp/5gmodem_health/*.demoted 2>/dev/null
	# ДАЖЕ ПРИ CHANGED=0 живые маршруты переустанавливаем: uci мог совпадать,
	# а реальная таблица - нет (штрафная метрика сторожа). Ранний выход делал
	# клик по аплинку «несработавшим» до следующего круга сторожа (ревью №12).
	_np_changed=false; [ "$CHANGED" = 1 ] && _np_changed=true
	# Персистентность: сохраняем метрики в конфиг (netifd возьмёт их на будущих
	# событиях - передозвон, hotplug).
	[ "$CHANGED" = 1 ] && uci -q commit network
	# ЖИВОЕ переключение БЕЗ `network reload`: приоритет аплинка - это МЕТРИКА
	# default-маршрута, чистая операция таблицы маршрутизации. Меняем её напрямую
	# через `ip route`, не трогая netifd и, главное, PDP-сессию модема - никакого
	# передозвона и моргания IP. Метрика входит в идентичность маршрута, поэтому
	# «сменить метрику» = удалить старый default через этот dev и добавить с новой
	# (via сохраняем, если шлюз есть; у сотовых он часто on-link). Делаем и для
	# IPv4, и для IPv6. netifd при своём следующем событии переустановит маршруты
	# уже из обновлённого uci - итог совпадёт.
	# СНОСИМ все default-маршруты управляемых интерфейсов, ПОТОМ добавляем с
	# УНИКАЛЬНЫМИ метриками. Иначе два default с ОДИНАКОВОЙ метрикой конфликтуют в
	# ядре ("RTNETLINK: File exists") - именно поэтому «переставить метрику» в лоб
	# не срабатывало. chosen=1, остальные 20,21,22... (метрика default-маршрута
	# должна быть уникальной). Сами функции - общие с `order`, см. над case.
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		_del_all_default "$_d"
	done
	# ОДИН default-маршрут НА УСТРОЙСТВО. IPv6-спутник (`<имя>6`) - это ОТДЕЛЬНАЯ
	# сеть на ТОМ ЖЕ l3_device, и раньше цикл добавлял ей собственный маршрут:
	# одно переключение оставляло на usb0 сразу несколько записей, а с каждым
	# следующим их становилось больше (наблюдалось: 5 маршрутов после одного
	# нажатия, 7 после шести). В списке аплинков спутник мы уже скрываем - здесь
	# нужно то же самое, но по устройству, а не по имени: так отсечём и любые
	# другие сети, делящие один интерфейс.
	_seen=""
	_add_once() {   # _add_once <сеть> <метрика>; возвращает 1, если добавили
		_dv=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dv" ] || return 1
		case " $_seen " in *" $_dv "*) return 1 ;; esac
		_seen="$_seen $_dv"
		_add_default_route "$1" "$2"
		return 0
	}
	_add_once "$CH" 10
	_m=20
	for n in $(wan_nets); do
		[ -n "$n" ] && [ "$n" != "$CH" ] && { _add_once "$n" "$_m" && _m=$((_m + 10)); }
	done
	echo '{"result":"ok","active":"'"$CH"'","changed":'"$_np_changed"',"mode":"live-route"}'
	;;

order)
	# order <if1> <if2> ...  - задать ПОРЯДОК аплинков перетаскиванием карточек.
	# Метрика = РАНГ с шагом 10: первый 10, второй 20, третий 30 ... Это и есть
	# failover: отвалился первый (нет default-маршрута с метрикой 10) - трафик
	# сам уходит на метрику 20.
	# В отличие от `set` (выбранный=10, остальные 20,30...), тут пользователь задаёт
	# ВЕСЬ порядок. Живое применение маршрутов - то же, что у `set`.
	shift
	[ -n "$1" ] || { echo '{"error":"no order"}'; exit 1; }
	# Чужие имена выбрасываем сразу (та же причина, что у set: реальный не-wan
	# интерфейс - например lan - получил бы живой default-маршрут в хвосте).
	_ord=""
	_wz=" $(wan_nets) "
	for _oi in "$@"; do
		case "$_wz" in
			*" $_oi "*) _ord="$_ord $_oi" ;;
			*) logger -t 5gmodem "netpri order: '$_oi' не аплинк wan-зоны - пропускаю" ;;
		esac
	done
	[ -n "$_ord" ] || { echo '{"error":"no valid interfaces"}'; exit 1; }
	# перетаскивание = пользователь заново задал порядок: метки «оставлен в
	# конце» от сторожа (failback=demote) больше не действуют
	rm -f /tmp/5gmodem_health/*.demoted 2>/dev/null
	note_foreign_uci network "netpri order"
	_rank=10
	# uci-метрики по рангу с шагом 10 (см. пояснение в set); интерфейсы вне
	# переданного порядка - в хвост (метрики должны быть уникальными: два
	# default с одной метрикой конфликтуют в ядре).
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_o " in *" $n "*) continue ;; esac
		_seen_o="$_seen_o $n"
		ucinet_has "$n" || continue
		uci -q set "network.$n.metric=$_rank"
		_rank=$((_rank + 10))
	done
	uci -q commit network
	# живое переустановление default-маршрутов - общие функции, см. над case
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		_del_all_default "$_d"
	done
	# Один маршрут на устройство (IPv6-спутник делит l3_device - не дублируем).
	_seen=""; _rank=10
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_r " in *" $n "*) continue ;; esac
		_seen_r="$_seen_r $n"
		_dv=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_dv" ] || continue
		case " $_seen " in *" $_dv "*) continue ;; esac
		_seen="$_seen $_dv"
		_add_default_route "$n" "$_rank"
		_rank=$((_rank + 10))
	done
	echo '{"result":"ok","changed":true,"mode":"order"}'
	;;

ping)
	# TELEGRAM ПРОВЕРЯЕТСЯ ОСОБО - ПИНГ ПРО НЕГО ВРЁТ В ОБЕ СТОРОНЫ.
	#
	# ICMP до серверов Telegram не ходит вовсе (красная точка на живом сервисе),
	# а в РФ его домен вдобавок подменяют на операторском резолвере - «зелёный»
	# ответ мог бы прийти от заглушки провайдера. Поэтому:
	#   1) резолвим api.telegram.org;
	#   2) сверяем адрес с ОФИЦИАЛЬНЫМ списком сетей Telegram (cidr.txt лежит в
	#      пакете) - не совпал, значит это не Telegram, а подмена;
	#   3) стучимся в 443 по этому адресу с правильным SNI. Любой ответ HTTP -
	#      сервис доступен (api.telegram.org на корень отвечает 404, и это ОК).
	# Резолв не удался - берём адрес из того же списка (149.154.167.220, это и
	# есть api.telegram.org): так карточка работает и при мёртвом DNS.
	# ГДЕ ЛЕЖИТ СПИСОК СЕТЕЙ. В пакете - снимок на день сборки; свежую копию
	# кладём В /etc, а не поверх пакетной: /usr/share принадлежит менеджеру
	# пакетов и переписывается при обновлении приложения (ровно тем же уроком,
	# что и путь для статистики). Есть свежая - она главнее.
	_TG_CIDR_PKG=/usr/share/5gmodem/telegram-cidr.txt
	_TG_CIDR_NEW=/etc/5gmodem/telegram-cidr.txt
	_tg_cidr_file() {
		[ -s "$_TG_CIDR_NEW" ] && { printf '%s' "$_TG_CIDR_NEW"; return 0; }
		[ -s "$_TG_CIDR_PKG" ] && { printf '%s' "$_TG_CIDR_PKG"; return 0; }
		return 1
	}

	# ОБНОВЛЕНИЕ СПИСКА - ПОПУТНО И ТОЛЬКО ПОСЛЕ УДАЧНОЙ ПРОБЫ.
	#
	# Список у Telegram меняется раз в годы, отдельная кнопка ради этого - шум в
	# интерфейсе, а расписание - лишняя служба. Зато момент, когда мы ТОЧНО
	# достучались до Telegram, у нас уже есть: успешная проба карточки. В нём и
	# обновляемся, не чаще раза в 30 дней, в фоне и молча.
	#
	# ПРОВЕРЯЕМ, ЧТО СКАЧАЛОСЬ. За cidr.txt легко получить страницу-заглушку
	# оператора: берём файл, только если КАЖДАЯ его строка - сеть, и их не
	# меньше пяти. Подмена списка на «0.0.0.0/0» превратила бы проверку
	# подмены DNS в решето, поэтому здесь строго.
	_tg_cidr_refresh() {
		command -v curl >/dev/null 2>&1 || return 0
		_tr_f=$(_tg_cidr_file) || _tr_f=""
		if [ -n "$_tr_f" ] && [ -z "$(find "$_tr_f" -mtime +30 2>/dev/null)" ]; then
			return 0
		fi
		( _tr_t="/tmp/.tgcidr.$$"
		  curl -fsSL -m 20 https://core.telegram.org/resources/cidr.txt -o "$_tr_t" 2>/dev/null || {
		  	rm -f "$_tr_t"; exit 0; }
		  if awk '
		  		# Слишком широкая сеть (короче /8) - признак подделки: с ней
		  		# «адрес принадлежит Telegram» становится истиной для всех, и
		  		# проверка подмены DNS перестаёт что-либо значить.
		  		/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
		  			split($0, c, "/"); if (c[2] + 0 < 8) bad = 1; n++; next }
		  		/^[0-9a-fA-F:]+\/[0-9]+$/ { n++; next }
		  		/^[[:space:]]*$/ { next }
		  		{ bad = 1 }
		  		END { exit((bad || n < 5) ? 1 : 0) }
		  	' "$_tr_t"; then
		  	mkdir -p /etc/5gmodem 2>/dev/null
		  	mv "$_tr_t" "$_TG_CIDR_NEW" 2>/dev/null \
		  		&& logger -t 5gmodem "список сетей Telegram обновлён ($(wc -l < "$_TG_CIDR_NEW" | tr -d " ") строк)"
		  else
		  	rm -f "$_tr_t"
		  fi ) >/dev/null 2>&1 </dev/null &
	}

	_tg_cidr_has() {   # $1 - IPv4
		_tc_f=$(_tg_cidr_file) || return 1
		# Побитового И в busybox awk нет, поэтому принадлежность к сети считаем
		# делением: адреса в одной /N-сети, когда их старшие N бит совпадают,
		# то есть целые части от деления на 2^(32-N) равны. Строки IPv6
		# пропускаем - проба всё равно идёт по IPv4.
		awk -v ip="$1" '
			function toint(a,   p) { split(a, p, "."); return p[1]*16777216 + p[2]*65536 + p[3]*256 + p[4] }
			/:/ { next }
			/^[0-9]/ {
				split($1, c, "/")
				bits = c[2] + 0
				if (bits < 1 || bits > 32) next
				d = 2 ^ (32 - bits)
				if (int(toint(ip) / d) == int(toint(c[1]) / d)) { found = 1; exit }
			}
			END { exit(found ? 0 : 1) }
		' "$_tc_f"
	}
	_tg_probe() {
		_tp_ip=$(nslookup api.telegram.org 2>/dev/null \
			| sed -n 's/^Address: *\([0-9.]*\)$/\1/p' | grep -v '^127\.' | head -1)
		# FAKE-IP от clash (198.18.x/198.19.x) - не подмена оператора, а туннель:
		# так резолвит сам clash. «Подменой» это считать нельзя, а прямая проба
		# по такому адресу бессмысленна - сразу уходим на пробу через туннель.
		_tp_fake=""
		case "$_tp_ip" in 198.18.*|198.19.*) _tp_fake=1 ;; esac
		if [ -n "$_tp_ip" ] && [ -z "$_tp_fake" ] && ! _tg_cidr_has "$_tp_ip"; then
			printf '{"ok":0,"why":"dns","ip":"%s"}\n' "$_tp_ip"
			return 0
		fi
		[ -n "$_tp_ip" ] || _tp_ip=149.154.167.220
		if command -v curl >/dev/null 2>&1; then
			if [ -z "$_tp_fake" ]; then
				_tp_w=$(curl -o /dev/null -s -m 5 \
					--resolve "api.telegram.org:443:$_tp_ip" \
					-w '%{http_code} %{time_starttransfer}' \
					"https://api.telegram.org/" 2>/dev/null)
				_tp_c="${_tp_w%% *}"; _tp_t="${_tp_w##* }"
				if [ -n "$_tp_c" ] && [ "$_tp_c" != "000" ]; then
					# Достучались - самое время освежить список сетей (раз в 30 дней).
					_tg_cidr_refresh
					printf '{"ok":1,"ms":%s,"via":"tls"}\n' \
						"$(printf '%s' "$_tp_t" | awk '{printf "%d", $1 * 1000}')"
					return 0
				fi
			fi
			# ПРЯМОГО ПУТИ НЕТ - МЕРЯЕМ КАК КЛИЕНТ, ЧЕРЕЗ ТУННЕЛЬ. Прямой 443 к
			# Telegram у операторов РФ закрыт, а СВОЙ трафик роутера идёт мимо
			# clash (tproxy перехватывает только форвард LAN) - точка горела
			# красным на живом для пользователей сервисе (живой случай
			# 03.08.2026: DNS честный, прямой 000, через mixed-port 302).
			# Тот же обход, что у geo-запросов спидтеста: http/mixed-порт clash;
			# tproxy-порт не годится - это не HTTP-прокси.
			_tp_pp=$(sed -n 's/^ *\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
				/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
			if [ -n "$_tp_pp" ] && [ "$_tp_pp" != "0" ]; then
				_tp_w=$(curl -o /dev/null -s -m 6 -x "http://127.0.0.1:$_tp_pp" \
					-w '%{http_code} %{time_starttransfer}' \
					"https://api.telegram.org/" 2>/dev/null)
				_tp_c="${_tp_w%% *}"; _tp_t="${_tp_w##* }"
				if [ -n "$_tp_c" ] && [ "$_tp_c" != "000" ]; then
					printf '{"ok":1,"ms":%s,"via":"proxy"}\n' \
						"$(printf '%s' "$_tp_t" | awk '{printf "%d", $1 * 1000}')"
					return 0
				fi
			fi
			# Прокси-порта нет или он не помог - спрашиваем clash по API
			# (общая проба, см. _clash_ping).
			_tp_cp=$(_clash_ping api.telegram.org) && { echo "$_tp_cp"; return 0; }
		fi
		echo '{"ok":0,"via":"tls"}'
	}
	case "${2:-}" in
		api.telegram.org|telegram.org|telegram|web.telegram.org)
			_tg_probe; exit 0 ;;
	esac
	# Пинг до выбранного хоста для виджета «Статус сервиса»: {"ok":1,"ms":23} либо {"ok":0}.
	# Идёт по активному аплинку (default route). Один пакет, таймаут 2 c.
	# ICMP до youtube.com обычно проходит даже там, где TCP шейпится.
	_h="${2:-youtube.com}"
	_po=$(ping -c 1 -W 2 "$_h" 2>/dev/null)
	case "$_po" in
		*"(198.18."*|*"(198.19."*)
			# FAKE-IP (clash/ssclash): домен разрешился в фиктивный адрес, и
			# ICMP до него меряет туннель либо локальный ответчик clash - в обе
			# стороны враньё. Меряем ЧЕСТНО, как браузер клиента: HTTPS-запрос
			# обычным маршрутом (то есть ЧЕРЕЗ clash) - раз сервис открывается
			# у людей, откроется и здесь, и время будет настоящим.
			if command -v curl >/dev/null 2>&1; then
				_hw=$(curl -o /dev/null -s -m 4 -w '%{http_code} %{time_starttransfer}' "https://$_h/" 2>/dev/null)
				_hc="${_hw%% *}"; _ht="${_hw##* }"
				if [ -n "$_hc" ] && [ "$_hc" != "000" ]; then
					printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(printf '%s' "$_ht" | awk '{printf "%d", $1 * 1000}')"
				else
					# Тот же обход, что и ниже: у сервиса, закрытого для самого
					# роутера, спрашиваем время у clash - он ходит путём клиентов.
					_cp_out=$(_clash_ping "$_h") && echo "$_cp_out" || echo '{"ok":0,"via":"http"}'
				fi
			else
				# без curl - хотя бы факт доступности (wget-spider) и грубое
				# время по /proc/uptime (шаг 10 мс)
				_t0=$(awk '{printf "%d", $1 * 100}' /proc/uptime)
				if wget -q --spider -T 4 "https://$_h/" 2>/dev/null; then
					_t1=$(awk '{printf "%d", $1 * 100}' /proc/uptime)
					printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(( (_t1 - _t0) * 10 ))"
				else
					echo '{"ok":0,"via":"http"}'
				fi
			fi
			;;
		*)
			_ms=$(printf '%s\n' "$_po" | sed -n 's/.*time=\([0-9]*\).*/\1/p' | head -1)
			if [ -n "$_ms" ]; then
				printf '{"ok":1,"ms":%s}\n' "$_ms"
			else
				# ICMP молчит - ВТОРОЕ МНЕНИЕ по TCP, независимо от fake-ip.
				# ICMP режут не только clash: фильтруют операторы и сами сервисы,
				# а сайт при этом открывается. Красная точка на живом сервисе -
				# ложь; HTTPS-проба тем же путём, что у браузера, честнее.
				if command -v curl >/dev/null 2>&1; then
					_hw=$(curl -o /dev/null -s -m 4 -w '%{http_code} %{time_starttransfer}' "https://$_h/" 2>/dev/null)
					_hc="${_hw%% *}"; _ht="${_hw##* }"
					if [ -n "$_hc" ] && [ "$_hc" != "000" ]; then
						printf '{"ok":1,"ms":%s,"via":"http"}\n' "$(printf '%s' "$_ht" | awk '{printf "%d", $1 * 1000}')"
					else
						_cp_out=$(_clash_ping "$_h"); [ -n "$_cp_out" ] && echo "$_cp_out" || echo '{"ok":0}'
					fi
				elif wget -q --spider -T 4 "https://$_h/" 2>/dev/null; then
					echo '{"ok":1,"ms":0,"via":"http"}'
				else
					_cp_out=$(_clash_ping "$_h"); [ -n "$_cp_out" ] && echo "$_cp_out" || echo '{"ok":0}'
				fi
			fi
			;;
	esac
	;;
svcstatus)
	# Запущен ли сервис $2 - для виджета «Сервисы» (точка запущен/остановлен).
	_svc_json "$2"
	echo
	;;
svcall)
	# Агрегат для панели виджетов: статусы всех сервисов + веток SSClash ОДНИМ
	# вызовом ubus/rpcd вместо N параллельных exec_direct (каждый - отдельный
	# spawn rpcd каждые 5 секунд). $2 = сервисы через запятую, $3 = ветки
	# ssclash (go/legacy) через запятую.
	# '-' = пустой список: exec_direct теряет пустые аргументы (см. netpri.js).
	_sj=""
	for _s in $(printf '%s' "$2" | tr ',' ' '); do
		case "$_s" in ''|-) continue ;; esac
		_sj="$_sj,\"$(json_esc "$_s")\":$(_svc_json "$_s")"
	done
	_cj=""
	for _k in $(printf '%s' "$3" | tr ',' ' '); do
		case "$_k" in go|legacy) ;; *) continue ;; esac
		_ko=$(/usr/share/5gmodem/ssclash.sh status "$_k" 2>/dev/null)
		[ -n "$_ko" ] || _ko='{}'
		_cj="$_cj,\"$_k\":$_ko"
	done
	printf '{"svc":{%s},"ssc":{%s}}\n' "${_sj#,}" "${_cj#,}"
	;;
*)
	echo '{"error":"usage: netpri.sh list|set <iface>"}'
	exit 1
	;;
esac
