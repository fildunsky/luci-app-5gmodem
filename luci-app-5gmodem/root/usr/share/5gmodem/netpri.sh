#!/bin/sh
#
# Internet-priority switcher. Lists the interfaces in the firewall 'wan' zone
# that currently have an IPv4 address, and makes one of them the primary uplink
# by giving it the lowest route metric (others get a high metric). The chosen
# uplink then wins the default route.
#
# Usage:
#   netpri.sh list          - JSON array of WAN-zone interfaces with an IP
#   netpri.sh set <iface>   - make <iface> primary (metric 1), others metric 20
#

# networks that belong to the firewall 'wan' zone
wan_nets() {
	z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
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
ifdump_drop() { _IFDUMP=""; }
ifup_state() {
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

# СНИМОК ПЕРЕЧИСЛЕНИЯ МОДЕМОВ на один вызов. listmodems.sh спрашивался трижды за
# один `list`: список присутствующих путей и по разу на каждый модем в model_for.
# У самого listmodems есть кэш (9 мс тёплый), но каждый вызов - это ещё fork+shell,
# а мы в цикле. Снимок берётся явно, как и остальные (см. ifdump_snapshot).
_LM_SNAP=""
lm_snapshot() { _LM_SNAP=$("/usr/share/5gmodem/listmodems.sh" 2>/dev/null); }
lm_drop() { _LM_SNAP=""; }
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
_MS_KEYS=""; _MS_VALS=""
modem_section() {
	[ -n "$1" ] || return 1
	# Поиск в плоском списке "iface=секция iface=секция ..." - без подпроцессов.
	case " $_MS_KEYS " in
		*" $1 "*)
			for _msp in $_MS_VALS; do
				case "$_msp" in
					"$1="*) printf '%s' "${_msp#*=}"; return 0 ;;
				esac
			done
			return 0 ;;
	esac
	_msv=$(sec_for_iface "$1")
	_MS_KEYS="$_MS_KEYS $1"
	_MS_VALS="$_MS_VALS $1=$_msv"
	printf '%s' "$_msv"
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
iface_type() {
	i="$1"
	is_modem "$i" && { echo modem; return; }
	# ИМЯ ИНТЕРФЕЙСА - НЕ ПРИЗНАК ТИПА. Проверка на "wan" стояла первой и
	# обрывала разбор: у роутера с аплинком по Wi-Fi клиентский интерфейс тоже
	# называется "wan", и беспроводное подключение показывалось проводным WAN -
	# с чужим значком и без имени сети. Решает УСТРОЙСТВО, имя лишь запасной
	# вариант для тех, у кого l3_device ещё не поднят.
	dev=$(ifup_state "$i" '@["l3_device"]')
	case "$dev" in phy*-sta*|wlan*) echo wifi; return;; esac
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
	if [ -f "/tmp/5gmodem_op_$1" ]; then cat "/tmp/5gmodem_op_$1"; return; fi
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
		_lm=$(_lm)
		prod=$(echo "$_lm" | jsonfilter -e "@[@.path=\"$path\"].product" 2>/dev/null | head -1)
		vidpid=$(echo "$_lm" | jsonfilter -e "@[@.path=\"$path\"].vidpid" 2>/dev/null | head -1)
		lmmodel=$(echo "$_lm" | jsonfilter -e "@[@.path=\"$path\"].model" 2>/dev/null | head -1)
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
		if [ "$(iface_type "$n")" = modem ]; then
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
				echo "$PRESENT_PATHS" | grep -q " $_mp " && { _any_present=1; break; }
			done
			if [ -z "$_any_present" ] && { [ -n "$_any_path" ] || [ -n "$_any_parked" ]; }; then
				continue
			fi
		fi
		# NOTE: no IP filter for modems/Wi-Fi - keep them visible even without an
		# address, so a modem that briefly drops its IP while re-dialing after a
		# switch does not vanish from the bar (which used to leave only Wi-Fi
		# looking "selected").
		ip=$(iface_ip "$n")
		t=$(iface_type "$n")
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
		_np_s=$(sec_for_iface "$n")
		if [ -n "$_np_s" ] && [ "$(uci -q get "5gmodem.$_np_s.kind")" = "hilink" ]; then
			_np_wan=$(/usr/share/5gmodem/hilink.sh json "$(uci -q get "5gmodem.$_np_s.path")" 2>/dev/null \
				| jsonfilter -e '@.ipaddr' 2>/dev/null)
			[ -n "$_np_wan" ] && ip="$_np_wan"
		fi
		m=$(ucinet_get "$n" metric); [ -n "$m" ] || m=0
		[ "$first" = 1 ] || printf ','
		first=0
		printf '{"iface":"%s","type":"%s","sub":"%s","label":"%s","ip":"%s","metric":%s}' \
			"$n" "$t" "$(json_esc "$sub")" "$(json_esc "$(label_for "$n")")" "$ip" "$m"
	done
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
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		ucinet_has "$n" || continue
		if [ "$n" = "$CH" ]; then NEW=1; else NEW=20; fi
		OLD=$(ucinet_get "$n" metric)
		[ "x$OLD" = "x$NEW" ] && continue
		uci -q set "network.$n.metric=$NEW"
		CHANGED=1
	done
	[ "$CHANGED" = 1 ] || { echo '{"result":"ok","active":"'"$CH"'","changed":false}'; exit 0; }
	# Персистентность: сохраняем метрики в конфиг (netifd возьмёт их на будущих
	# событиях - передозвон, hotplug).
	uci -q commit network
	# ЖИВОЕ переключение БЕЗ `network reload`: приоритет аплинка - это МЕТРИКА
	# default-маршрута, чистая операция таблицы маршрутизации. Меняем её напрямую
	# через `ip route`, не трогая netifd и, главное, PDP-сессию модема - никакого
	# передозвона и моргания IP. Метрика входит в идентичность маршрута, поэтому
	# «сменить метрику» = удалить старый default через этот dev и добавить с новой
	# (via сохраняем, если шлюз есть; у сотовых он часто on-link). Делаем и для
	# IPv4, и для IPv6. netifd при своём следующем событии переустановит маршруты
	# уже из обновлённого uci - итог совпадёт.
	# Переустановить default-маршрут интерфейса $1 с метрикой $2 (v4 и v6). Шлюз
	# берём у netifd (авторитетно), а НЕ из живой таблицы: у не-primary интерфейса
	# default-маршрута может не быть. 0.0.0.0/:: = честный on-link (у сотовых
	# point-to-point шлюза нет). У интерфейса с адресом /32 (Wi-Fi client, сотовый)
	# шлюз не on-link - сперва добавляем прямой маршрут до самого шлюза (как netifd).
	# Добавить default-маршрут интерфейса $1 с метрикой $2 (v4+v6). БЕЗ удаления -
	# удаляем всё заранее (см. ниже). Шлюз берём у netifd; 0.0.0.0/:: = on-link.
	_add_default_route() {
		_dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dev" ] || return 0
		_gw4=$(ifup_state "$1" '@.route[@.target="0.0.0.0"].nexthop')
		if [ -n "$_gw4" ] && [ "$_gw4" != "0.0.0.0" ]; then
			# у адреса /32 (Wi-Fi client, сотовый) шлюз не on-link - сперва прямой
			# маршрут до шлюза (как netifd), потом default через него.
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
	# СНОСИМ все default-маршруты управляемых интерфейсов, ПОТОМ добавляем с
	# УНИКАЛЬНЫМИ метриками. Иначе два default с ОДИНАКОВОЙ метрикой конфликтуют в
	# ядре ("RTNETLINK: File exists") - именно поэтому «переставить метрику» в лоб
	# не срабатывало. chosen=1, остальные 20,21,22... (метрика default-маршрута
	# должна быть уникальной).
	# `ip route del default dev X` удаляет РОВНО ОДИН маршрут за вызов. Если на
	# устройстве их несколько (а так и выходит: разные метрики, плюс формы via и
	# on-link сосуществуют), один вызов сносит первый, а мы тут же добавляем
	# новый - остаток копится с каждым переключением. Наблюдалось вживую: после
	# нескольких нажатий в таблице висело шесть default-маршрутов вместо двух,
	# среди них `default dev usb0 scope link` без шлюза, которые ничего не
	# маршрутизируют, но при неудачных метриках могут перехватить трафик.
	# Поэтому удаляем В ЦИКЛЕ, пока есть что удалять. Потолок - страховка от
	# вечного цикла, если ядро вдруг начнёт возвращать успех на пустом месте.
	_del_all_default() {
		_i=0
		while [ "$_i" -lt 16 ]; do
			ip -4 route del default dev "$1" 2>/dev/null || break
			_i=$((_i + 1))
		done
		_i=0
		while [ "$_i" -lt 16 ]; do
			ip -6 route del default dev "$1" 2>/dev/null || break
			_i=$((_i + 1))
		done
	}
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
	_add_once "$CH" 1
	_m=20
	for n in $(wan_nets); do
		[ -n "$n" ] && [ "$n" != "$CH" ] && { _add_once "$n" "$_m" && _m=$((_m + 1)); }
	done
	echo '{"result":"ok","active":"'"$CH"'","changed":true,"mode":"live-route"}'
	;;

order)
	# order <if1> <if2> ...  - задать ПОРЯДОК аплинков перетаскиванием карточек.
	# Метрика = РАНГ: первый 1, второй 2, третий 3 ... Это и есть failover: отвалился
	# первый (нет default-маршрута с метрикой 1) - трафик сам уходит на метрику 2.
	# В отличие от `set` (выбранный=1, остальные 20,21...), тут пользователь задаёт
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
	note_foreign_uci network "netpri order"
	_rank=1
	# uci-метрики по рангу; интерфейсы вне переданного порядка - в хвост (метрики
	# должны быть уникальными: два default с одной метрикой конфликтуют в ядре).
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_o " in *" $n "*) continue ;; esac
		_seen_o="$_seen_o $n"
		ucinet_has "$n" || continue
		uci -q set "network.$n.metric=$_rank"
		_rank=$((_rank + 1))
	done
	uci -q commit network
	# --- живое переустановление default-маршрутов (копия логики из `set`) ---
	_add_default_route() {   # $1 - iface, $2 - метрика
		_dev=$(ifup_state "$1" '@["l3_device"]'); [ -n "$_dev" ] || return 0
		_gw4=$(ifup_state "$1" '@.route[@.target="0.0.0.0"].nexthop')
		if [ -n "$_gw4" ] && [ "$_gw4" != "0.0.0.0" ]; then
			ip -4 route add "$_gw4" dev "$_dev" 2>/dev/null
			ip -4 route add default via "$_gw4" dev "$_dev" metric "$2" 2>/dev/null
		else
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
	_del_all_default() {   # $1 - l3_device
		_i=0; while [ "$_i" -lt 16 ]; do ip -4 route del default dev "$1" 2>/dev/null || break; _i=$((_i + 1)); done
		_i=0; while [ "$_i" -lt 16 ]; do ip -6 route del default dev "$1" 2>/dev/null || break; _i=$((_i + 1)); done
	}
	for n in $(wan_nets); do
		[ -n "$n" ] || continue
		_d=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_d" ] || continue
		_del_all_default "$_d"
	done
	# Один маршрут на устройство (IPv6-спутник делит l3_device - не дублируем).
	_seen=""; _rank=1
	for n in $_ord $(wan_nets); do
		[ -n "$n" ] || continue
		case " $_seen_r " in *" $n "*) continue ;; esac
		_seen_r="$_seen_r $n"
		_dv=$(ifup_state "$n" '@["l3_device"]'); [ -n "$_dv" ] || continue
		case " $_seen " in *" $_dv "*) continue ;; esac
		_seen="$_seen $_dv"
		_add_default_route "$n" "$_rank"
		_rank=$((_rank + 1))
	done
	echo '{"result":"ok","changed":true,"mode":"order"}'
	;;

ping)
	# Пинг до выбранного хоста для виджета «Статус сервиса»: {"ok":1,"ms":23} либо {"ok":0}.
	# Идёт по активному аплинку (default route). Один пакет, таймаут 2 c.
	# ICMP до youtube.com обычно проходит даже там, где TCP шейпится.
	_h="${2:-youtube.com}"
	_ms=$(ping -c 1 -W 2 "$_h" 2>/dev/null | sed -n 's/.*time=\([0-9]*\).*/\1/p' | head -1)
	if [ -n "$_ms" ]; then
		printf '{"ok":1,"ms":%s}\n' "$_ms"
	else
		echo '{"ok":0}'
	fi
	;;
svcstatus)
	# Запущен ли сервис $2 - для виджета «Сервисы» (точка запущен/остановлен).
	R=0
	if [ -n "$2" ] && [ -x "/etc/init.d/$2" ]; then
		if ubus -S call service list "{\"name\":\"$2\"}" 2>/dev/null | grep -q '"running": *true'; then
			R=1
		elif /etc/init.d/"$2" status >/dev/null 2>&1; then
			R=1
		fi
	fi
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"error":"usage: netpri.sh list|set <iface>"}'
	exit 1
	;;
esac
