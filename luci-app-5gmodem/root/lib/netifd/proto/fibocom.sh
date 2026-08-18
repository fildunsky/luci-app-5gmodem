#!/bin/sh
#
# netifd protocol handler: "fibocom"
#
# Data connection for AT-dialed RNDIS/ECM modems that ModemManager cannot drive
# (e.g. Fibocom FM350-GL, USB id 0e8d:7127 / 0e8d:7126). These modems expose NO
# cdc-wdm control channel - data goes over a plain usbnet device (eth*), and the
# host must bring up the PDP context itself over an AT port and then assign the
# modem-provided IP/DNS statically (the modem serves no DHCP).
#
# Sequence: AT+CGDCONT (define APN) -> AT+CGACT=1,1 (activate) ->
#   AT+CGPADDR (assigned IP) -> AT+CGCONTRDP (gateway/DNS), all standard 3GPP.
# The interface is bound to the modem by its STABLE USB topology path (usbpath),
# so it survives ttyUSB/eth renumbering across reboots and modem swaps.
#
# Interface options:
#   usbpath  - USB topology path of the modem, e.g. "1-1.3" (preferred)
#   device   - usbnet device (eth2); used only if usbpath is unset
#   atport   - AT port to dial on; auto-picked (avoiding the metrics port) if unset
#   apn      - access point name (default: internet)
#   pdptype  - IP, IPV6 or IPV4V6 (default: IPV4V6)
#   metric   - route metric (default: 0)

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

# usbnet device (eth*/wwan*) that belongs to a given USB topology path.
# БЕРЁМ ИНТЕРФЕЙС С НАИМЕНЬШИМ НОМЕРОМ ЧИСЛЕННО, а не первый по глобу: ASCII
# сортирует «1.10» раньше «1.6», и у L860 (3 NCM: 1.6/1.8/1.10) первым выпадал
# wwan2 (1.10) - а привязка XDATACHANNEL="/USBHS/NCM/0" смотрит на ПЕРВЫЙ NCM
# (1.6, wwan0). Живой отчёт Cudy TR3000 16.08.2026: device='wwan2' в конфиге.
_fibocom_netdev() {
	local p="$1" n best="" bestnum=999
	for n in /sys/bus/usb/devices/$p:*/net/*; do
		[ -e "$n" ] || continue
		local ifn="${n%/net/*}"; ifn="${ifn##*:}"; ifn="${ifn#*.}"
		[ "$ifn" -lt "$bestnum" ] 2>/dev/null && { bestnum="$ifn"; best="$n"; }
	done
	[ -n "$best" ] && { basename "$best"; return 0; }
	return 1
}

# an AT-capable ttyUSB of this modem, preferring one that is NOT the app's
# metrics/AT port (so the periodic metrics poll and our dial do not collide on
# the same tty and cross their replies)
# ЧЕТЫРЕ ФОРМЫ ГЛОБА, А НЕ ДВЕ. У usb-serial (option, ttyUSB) узел - прямой
# потомок интерфейса: <путь>:1.2/ttyUSB0. У cdc_acm (ttyACM, это Intel XMM -
# Fibocom L850/L860) такого потомка НЕТ ВОВСЕ, tty регистрируется через класс:
# <путь>:1.0/tty/ttyACM0. Здесь искали только прямую форму, поэтому у модема на
# cdc_acm прото не находил ни одного AT-порта и молча выходил с NO_AT_PORT -
# интерфейс цикл за циклом падал с «NO_DEVICE» без единого объяснения в логе
# (живой отчёт: Cudy TR3000, L850 + L860, оба модема). Правильный набор форм уже
# был в portmap.sh - оттуда и берём.
_fibocom_atport() {
	local p="$1" avoid="$2" t tt fallback=""
	for t in /sys/bus/usb/devices/$p:*/ttyUSB* /sys/bus/usb/devices/$p:*/tty/ttyUSB* \
	         /sys/bus/usb/devices/$p:*/ttyACM* /sys/bus/usb/devices/$p:*/tty/ttyACM*; do
		[ -e "$t" ] || continue
		tt="/dev/$(basename "$t")"
		sms_tool -d "$tt" at "AT" >/dev/null 2>&1 || continue
		if [ "$tt" = "$avoid" ]; then
			[ -z "$fallback" ] && fallback="$tt"
			continue
		fi
		echo "$tt"
		return 0
	done
	[ -n "$fallback" ] && { echo "$fallback"; return 0; }
	return 1
}

# Режим выбора оператора из +COPS? : 0 - авто, 1 - вручную, 2 - СНЯТ С РЕГИСТРАЦИИ.
_fibocom_cops_mode() {
	sms_tool -d "$1" at "AT+COPS?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+COPS: *\([0-9]\).*/\1/p' | head -1
}

# Состояние регистрации в сети: печатает <stat> из +CEREG, иначе из +CREG.
# Пусто - модем не ответил. Коды: 1/6/9 - зарегистрирован дома, 5/7/10 - роуминг,
# 0/2/3/4/8 - сети нет (2 - ищет, 3 - отказано, 8 - только экстренные).
_fibocom_reg() {
	local p="$1" r
	r=$(sms_tool -d "$p" at "AT+CEREG?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CEREG: *[0-9]*,\([0-9]*\).*/\1/p' | head -1)
	[ -n "$r" ] || r=$(sms_tool -d "$p" at "AT+CREG?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CREG: *[0-9]*,\([0-9]*\).*/\1/p' | head -1)
	echo "$r"
}

# АУТЕНТИФИКАЦИЯ PDP (PAP/CHAP). Нужна MVNO вроде Экомобайла (APN+логин+
# пароль): без неё сеть даёт адрес, но роняет трафик в дыру. Команда -
# СТАНДАРТНАЯ 3GPP AT+CGAUTH=<cid>,<1 PAP|2 CHAP>,"user","pass" (сверено с
# xmm.sh: для FM350 0e8d:7127 он шлёт именно CGAUTH). Сброс - CGAUTH=<cid>,0.
# Модем без CGAUTH ответит ERROR - молча пропускаем.
# Вынесена ИЗ activate отдельной функцией: авторизацию надо слать не только в
# холодном дозвоне, но и учитывать в fast path (см. маркер devnum в setup) -
# CGAUTH НЕ переживает ребут модема, а FM350 после ребута сам активирует
# контекст 1, и сеть выдаёт адрес БЕЗ авторизации (живой отчёт Экомобайла
# 17.08.2026: наш usbpower-подъём после клина -> fast path переиспользовал
# неавторизованный bearer -> IP есть, трафик в дыру).
_fibocom_auth() {
	local dial="$1"
	case "$auth" in
		pap)  sms_tool -d "$dial" at "AT+CGAUTH=1,1,\"$username\",\"$password\"" >/dev/null 2>&1 ;;
		chap) sms_tool -d "$dial" at "AT+CGAUTH=1,2,\"$username\",\"$password\"" >/dev/null 2>&1 ;;
		both) sms_tool -d "$dial" at "AT+CGAUTH=1,1,\"$username\",\"$password\"" >/dev/null 2>&1 ;;
		*)    sms_tool -d "$dial" at "AT+CGAUTH=1,0" >/dev/null 2>&1 ;;
	esac
	# маркер «этой инкарнации модема авторизация послана»: ключ - USB devnum,
	# он меняется при каждой переэнумерации (= ребуте модема)
	[ -n "$interface" ] && [ -n "$usbpath" ] && \
		cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null \
			> "/tmp/fibocom_authed_$interface" 2>/dev/null
}

# Define APN with a given PDP type, (re)activate the default PDP context and echo
# the assigned IPv4 (empty on failure). Retries a few times: right after a modem
# swap / band change / USB re-enumeration the context needs a moment, and a single
# try would leave the interface down until netifd happens to retry. RELEASE FIRST
# (AT+CGACT=0,1): a bare re-activate HANGS when the context is wedged half-active -
# exactly the state a band change (AT+GTACT) leaves on the FM350 - and CGACT=0,1
# clears it; on a cold context the release is a harmless no-op.
_fibocom_activate() {
	local dial="$1" pdptype="$2" apn="$3" try ip=""
	# XMM: включить отдачу DNS (XDNS) ДО активации - иначе +XDNS? пуст.
	[ "$IS_XMM" = 1 ] && sms_tool -d "$dial" at "AT+XDNS=1,1" >/dev/null 2>&1
	sms_tool -d "$dial" at "AT+CGDCONT=1,\"$pdptype\",\"$apn\"" >/dev/null 2>&1
	_fibocom_auth "$dial"
	sms_tool -d "$dial" at "AT+CGACT=0,1" >/dev/null 2>&1
	sleep 2
	for try in 1 2 3 4 5 6; do
		sms_tool -d "$dial" at "AT+CGACT=1,1" >/dev/null 2>&1
		sleep 2
		ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
			| sed -n 's/.*+CGPADDR: *1,"\([0-9.]\{7,\}\)".*/\1/p' | head -1)
		[ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && {
			# XMM: привязать первый NCM-канал к контексту и стартовать данные -
			# без этого адрес есть, а кадры в NCM не ходят (суть xmm.sh).
			if [ "$IS_XMM" = 1 ]; then
				sms_tool -d "$dial" at "AT+XDATACHANNEL=1,1,\"/USBCDC/0\",\"/USBHS/NCM/0\",2,1" >/dev/null 2>&1
				sms_tool -d "$dial" at "AT+CGDATA=\"M-RAW_IP\",1" >/dev/null 2>&1
			fi
			echo "$ip"; return 0
		}
	done
	return 1
}

# Firewall-зона интерфейса - нужна ДОЧЕРНЕМУ dhcpv6-интерфейсу (IPv6): без зоны
# его входящие RA/DHCPv6-ответы упрутся в дефолтную политику INPUT и префикс от
# оператора не придёт. fw3 (firewall3) знает зону напрямую; на fw4 такой команды
# нет - тогда ищем зону в uci firewall по списку network.
_fibocom_fwzone() {   # $1 = имя интерфейса
	local z i=0 nm n
	z=$(fw3 -q network "$1" 2>/dev/null)
	[ -n "$z" ] && { echo "$z"; return; }
	while nm=$(uci -q get "firewall.@zone[$i].name" 2>/dev/null); [ -n "$nm" ]; do
		for n in $(uci -q get "firewall.@zone[$i].network" 2>/dev/null); do
			[ "$n" = "$1" ] && { echo "$nm"; return; }
		done
		i=$((i + 1))
	done
}

proto_fibocom_init_config() {
	no_device=1
	available=1
	proto_config_add_string "usbpath"
	# modem_path пишет приложение (штамп владения интерфейсом) и обновляет при
	# переезде модема в другой разъём. Прото читает его как ЗАПАСНОЙ путь - см.
	# setup: usbpath ставится один раз при создании и способен устареть.
	proto_config_add_string "modem_path"
	proto_config_add_string "device"
	proto_config_add_string "atport"
	proto_config_add_string "apn"
	proto_config_add_string "pdptype"
	proto_config_add_string "auth"
	proto_config_add_string "username"
	proto_config_add_string "password"
	proto_config_add_int "metric"
	proto_config_add_boolean "allow_roaming"
	proto_config_add_defaults
}

proto_fibocom_setup() {
	local interface="$1"
	local usbpath modem_path device atport apn pdptype metric
	json_get_vars usbpath modem_path device atport apn pdptype metric allow_roaming auth username password

	[ -n "$apn" ] || apn="internet"
	[ -n "$pdptype" ] || pdptype="IPV4"
	# НОРМАЛИЗАЦИЯ ТИПА PDP. В конфигах исторически лежит «IPV4» (его же пишет
	# UI), но 3GPP-валидные значения CGDCONT - только IP/IPV6/IPV4V6. FM350
	# нестандартное «IPV4» прощал, а Intel L860 отвечает ERROR: контекст НЕ
	# перезаписывался, старый APN (от прежней SIM) жил вечно, и каждый ifup
	# уходил в «холодный дозвон» по кругу (живой отчёт Cudy TR3000, 16.08.2026).
	pdptype=$(echo "$pdptype" | tr 'a-z' 'A-Z')
	case "$pdptype" in
		IPV4) pdptype="IP" ;;
		IP|IPV6|IPV4V6) ;;
		*) pdptype="IPV4V6" ;;
	esac

	# УСТАРЕВШИЙ usbpath. Он пишется ОДИН раз, при создании интерфейса, а модем
	# может переехать в другой разъём - тогда штамп владения (modem_path)
	# приложение обновит, а usbpath останется прежним. Живой отчёт (Cudy TR3000,
	# L850 + L860): usbpath=2-1.3 при модеме на 2-1.2 - ни портов, ни сетевого
	# устройства по этому пути нет вовсе. Признак протухания однозначный: такого
	# USB-устройства в системе НЕТ.
	if [ -n "$modem_path" ] && [ "$modem_path" != "$usbpath" ] \
	   && [ ! -e "/sys/bus/usb/devices/$usbpath/idVendor" ] \
	   && [ -e "/sys/bus/usb/devices/$modem_path/idVendor" ]; then
		echo "fibocom[$$] usbpath \"$usbpath\" is not on the bus, using modem_path \"$modem_path\""
		usbpath="$modem_path"
	fi

	# resolve the usbnet device (eth*) and a dial AT port from the stable path
	local netdev=""
	if [ -n "$usbpath" ]; then
		netdev=$(_fibocom_netdev "$usbpath")
		# Сетевого устройства нет - вероятно, usbnet-драйвер не загружен. FM350 в
		# RNDIS-композиции (GTUSBMODE 41: IAD Cls=e0 Sub=01 Prot=03) требует
		# rndis_host; на части прошивок (напр. Cudy WBR3000UAX, ядро 6.12) он не
		# загружен, пока его явно не подтянуть, и интерфейсы модема остаются с
		# Driver=(none). Грузим драйверы и ждём, пока ядро привяжет их к уже
		# воткнутому модему (при загрузке usbnet-модуль сканирует существующие
		# устройства). modprobe идемпотентен: если уже загружен - no-op.
		if [ -z "$netdev" ]; then
			modprobe rndis_host 2>/dev/null
			modprobe cdc_ether 2>/dev/null
			local _n=0
			while [ "$_n" -lt 5 ]; do
				netdev=$(_fibocom_netdev "$usbpath")
				[ -n "$netdev" ] && break
				sleep 1; _n=$((_n + 1))
			done
		fi
	fi
	[ -n "$netdev" ] || netdev="$device"
	if [ -z "$netdev" ]; then
		# ГОВОРИМ ВСЛУХ. Ветка выходила молча, и в журнале оставался лишь
		# бесконечный «setting up - is now down» без единого намёка на причину
		# (живой отчёт Cudy TR3000). Одна строка экономит час разбора.
		echo "fibocom[$$] no network device: path \"$usbpath\", device \"$device\""
		proto_notify_error "$interface" NO_NETDEV
		proto_set_available "$interface" 0
		return 1
	fi
	# Устройство из uci (fallback) может НЕ СУЩЕСТВОВАТЬ в системе. Так бывает,
	# когда драйвер usbnet не привязался к FM350: на части прошивок (напр. Cudy
	# WBR3000UAX, OpenWrt 25.12.5 / ядро 6.12) сетевые интерфейсы модема остаются
	# с Driver=(none), и /sys/class/net/wwanN не создаётся. Раньше мы всё равно
	# слали netifd proto_send_update на несуществующий wwanN -> netifd отвечал
	# "Unknown error", интерфейс падал, netifd тут же поднимал его заново - и так
	# по кругу каждые 5 c, забивая лог. Честная ошибка лучше бесконечного цикла.
	if [ ! -d "/sys/class/net/$netdev" ]; then
		proto_notify_error "$interface" NETDEV_MISSING
		proto_block_restart "$interface"
		return 1
	fi

	# INTEL XMM (Fibocom L850/L860, вендор 8087): дозвон тот же 3GPP, но данные
	# по NCM идут только после привязки канала (XDATACHANNEL + CGDATA), DNS
	# модем отдаёт через свою XDNS (CGCONTRDP пуст), а на NCM-линке модем НЕ
	# отвечает на ARP - без `arp off` адрес есть, трафика нет. Логика перенесена
	# из xmm.sh (modemfeed), внешний пакет больше не обязателен.
	local IS_XMM=0
	[ "$(cat "/sys/bus/usb/devices/$usbpath/idVendor" 2>/dev/null)" = "8087" ] && IS_XMM=1

	local dial="$atport"
	if [ -z "$dial" ] && [ -n "$usbpath" ]; then
		dial=$(_fibocom_atport "$usbpath" "$(uci -q get 5gmodem.@5gmodem[0].at_port)")
	fi
	if [ -z "$dial" ]; then
		echo "fibocom[$$] no AT port found at path \"$usbpath\" (neither ttyUSB nor ttyACM answered AT)"
		proto_notify_error "$interface" NO_AT_PORT
		proto_set_available "$interface" 0
		return 1
	fi

	# ОЧЕРЕДЬ К AT-ПОРТУ НА ВЕСЬ ДИАЛОГ ПОДЪЁМА.
	#
	# Прото разговаривает с модемом четырнадцатью командами и до сих пор делал это
	# БЕЗ ОЧЕРЕДИ. В тот же порт в это время ходит наш опрос метрик, а у части
	# людей ещё и посторонние пакеты (3ginfo-lite, sms-tool-js, modemband). Ответы
	# при этом путаются: спросивший получает ЧУЖОЙ. Для подъёма связи это особенно
	# дорого - адрес мы берём из ответа на AT+CGPADDR, и в интерфейс уезжал явно не
	# свой адрес (живой отчёт 04.08.2026: 10.137.124.1 при живой регистрации и
	# трафик в никуда; после удаления посторонних пакетов ТОТ ЖЕ прото поднял связь
	# с нормальным 10.9.146.175).
	# ЖДЁМ ОГРАНИЧЕННО и при неудаче идём БЕЗ замка: не поднять связь хуже, чем
	# рискнуть перехватом ответа. Снимаем на всех выходах ниже - _fib_unlock.
	_fib_lock_held=""
	if [ -r /usr/share/5gmodem/atlock.sh ]; then
		. /usr/share/5gmodem/atlock.sh 2>/dev/null
		if command -v at_lock >/dev/null 2>&1 && at_lock "$dial" 20; then
			_fib_lock_held=1
		else
			echo "fibocom[$$] AT port $dial is busy - proceeding without the queue"
		fi
	fi
	_fib_unlock() {
		[ -n "$_fib_lock_held" ] || return 0
		_fib_lock_held=""
		command -v at_unlock >/dev/null 2>&1 && at_unlock "$dial"
	}

	# ДАННЫЕ В РОУМИНГЕ. У FM350 переключателя роуминга В МОДЕМЕ НЕТ - в
	# руководстве по AT-командам (v2.2) такой команды не существует вовсе,
	# единственное упоминание роуминга - тип PDP в +EIAAPN. Поэтому поступаем
	# как mbim.sh: НЕ ПОДНИМАЕМ соединение, увидев роуминговую регистрацию.
	# Это и есть то, чего ждёт пользователь от тумблера - счёт за трафик
	# приходит за переданные байты, а не за факт регистрации.
	#
	# Коды +CEREG/+CREG: 5 - registered, roaming; 7 и 10 - роуминговые
	# разновидности (SMS only / CSFB not preferred). Дом - 1.
	# СНАЧАЛА ВЫЯСНЯЕМ, ЕСТЬ ЛИ ВООБЩЕ СЕТЬ, И ТОЛЬКО ПОТОМ НАБИРАЕМ.
	#
	# Живой отчёт (WH3000 Pro, 02.08.2026): модем искал сеть (+CEREG stat 2,
	# +CGATT 0, +CSQ 5 - антенны), а мы всё равно набирали, получали закономерный
	# отказ и объявляли NO_IP_ADDRESS с proto_block_restart. Диагноз врал - дело
	# было не в контексте, а в отсутствии регистрации, - и блокировка добивала:
	# интерфейс не поднимался сам ДАЖЕ после возвращения сети, до ручного ifup.
	#
	# Поэтому регистрацию читаем ОДИН раз и здесь же решаем всё: и роуминг, и
	# отсутствие сети. Сразу после включения модем честно ищет сеть десятки
	# секунд, поэтому с первого ответа не сдаёмся, а ЖДЁМ - это заодно и есть
	# пауза между попытками netifd, отдельный троттлинг не нужен.
	local _reg="" _rw=0 _kick=0
	while :; do
		_reg=$(_fibocom_reg "$dial")
		case "$_reg" in 1|5|6|7|9|10) break ;; esac
		# СНЯТ С РЕГИСТРАЦИИ - САМ ОН НЕ ВЕРНЁТСЯ. Живой отчёт (Cudy TR3000,
		# L850+L860): +COPS: 2, +CEREG: 2,0, +CSQ: 99,99 - модуль оставили
		# дерегистрированным (прежний прото, ручная команда), и перезапуски
		# интерфейса этого не лечили: при режиме 2 модем сеть не ищет вовсе.
		# Включаем автовыбор оператора ОДИН раз за попытку.
		#
		# РЕШАЕТ ИМЕННО РЕЖИМ +COPS, А НЕ КОД stat. Сперва здесь стояло «stat 0»,
		# и на стенде (FM350) толчок не сработал: после AT+COPS=2 этот модуль
		# отвечает +CEREG: 2,4 («неизвестно»), а не 0 - у разных модемов код свой.
		# Режим 2 однозначен у всех. Режим 1 не трогаем: это осознанный ручной
		# выбор сети пользователем, перебивать его мы не вправе.
		if [ "$_kick" = 0 ] && [ "$(_fibocom_cops_mode "$dial")" = 2 ]; then
			_kick=1
			echo "fibocom[$$] modem was deregistered (+COPS: 2) - enabling automatic network search"
			sms_tool -d "$dial" at "AT+COPS=0" >/dev/null 2>&1
		fi
		[ "$_rw" -ge 60 ] && break
		sleep 5; _rw=$((_rw + 5))
	done

	case "$_reg" in
		5|7|10)
			# ДАННЫЕ В РОУМИНГЕ. У FM350 переключателя роуминга В МОДЕМЕ НЕТ - в
			# руководстве по AT-командам (v2.2) такой команды не существует вовсе,
			# единственное упоминание роуминга - тип PDP в +EIAAPN. Поэтому
			# поступаем как mbim.sh: НЕ ПОДНИМАЕМ соединение, увидев роуминговую
			# регистрацию. Это и есть то, чего ждёт пользователь от тумблера -
			# счёт за трафик приходит за переданные байты, а не за факт регистрации.
			if [ "$allow_roaming" != "1" ]; then
				echo "fibocom[$$] roaming registration ($_reg) and roaming is not allowed"
				_fib_unlock
				proto_notify_error "$interface" ROAMING_NOT_ALLOWED
				# БЛОКИРУЕМ перезапуск: без этого netifd поднимал бы интерфейс
				# заново каждые 5 c, и лог забивался бы одним и тем же отказом.
				# Пользователь включит роуминг тумблером - интерфейс поднимут явно.
				proto_block_restart "$interface"
				return 1
			fi
			;;
		1|6|9) ;;
		3)
			# ОТКАЗ СЕТИ - это не «пока не нашёл»: так отвечают на незарегистрированную
			# SIM, неоплаченный тариф или заблокированный IMEI. Повторять бесполезно,
			# поэтому здесь перезапуск блокируем - как в роуминге.
			echo "fibocom[$$] network refused registration (+CEREG stat 3) - SIM/subscription/IMEI"
			_fib_unlock
			proto_notify_error "$interface" REGISTRATION_DENIED
			proto_block_restart "$interface"
			return 1
			;;
		*)
			# Сети нет и за отведённое время не появилась. Перезапуск НЕ блокируем:
			# сигнал может вернуться сам, и интерфейс обязан подняться без участия
			# человека. Цикл ожидания выше держит повтор примерно раз в минуту.
			echo "fibocom[$$] no network registration (+CEREG stat \"${_reg:-no answer}\") after ${_rw}s"
			_fib_unlock
			proto_notify_error "$interface" NOT_REGISTERED
			return 1
			;;
	esac

	# APPLY SAVED BANDS ONCE PER BOOT, BEFORE dialing. On reboot the FM350 resets
	# its band mask to "all" and auto-activates context 1 - so whoever triggers
	# setup (netifd itself, re-fired when device=eth2 finally appears; our
	# net-hotplug; a reload) would dial, or the fast path below would reuse, on ALL
	# bands, and only afterwards the separate band-restore (31-5gmodem-bands) would
	# re-apply the saved subset - the visible DOUBLE bring-up the user hit. Doing it
	# HERE, right in the dial path, is race-free against every trigger. The marker
	# keeps it to the FIRST bring-up of the boot (/tmp clears on reboot); later
	# reconnects (priority switch, restore's own reconnect) skip it - no extra
	# latency, no nested bands.sh under the at-lock. restorebands prepare returns 0
	# if it rewrote the mask (then we MUST cold-dial, the old bearer is on the wrong
	# bands) or 3 if it already matched (fast path is fine).
	local bands_changed=0
	local bmark="/tmp/5gmodem_bandsprep_$interface"
	if [ ! -e "$bmark" ] && [ "$(uci -q get 5gmodem.@5gmodem[0].save_bands)" != "0" ]; then
		local bsec="" bs bpath
		for bs in $(uci -q show 5gmodem 2>/dev/null \
				| sed -n 's/^\(5gmodem\.m_[0-9A-Za-z_]*\)\.network=.*/\1/p'); do
			[ "$(uci -q get "$bs.network")" = "$interface" ] || continue
			bsec="$bs"; break
		done
		bpath=$(uci -q get "$bsec.path" 2>/dev/null)
		[ -n "$bpath" ] || bpath="$usbpath"
		if [ -n "$bpath" ] && [ -n "$(uci -q get "$bsec.save_band")$(uci -q get "$bsec.save_band5gnsa")$(uci -q get "$bsec.save_band5gsa")" ]; then
			BANDS_ACTIVE_MODEM="$bpath" /usr/share/5gmodem/bands.sh restorebands prepare
			[ "$?" = "0" ] && bands_changed=1
			# Мы применили/сверили сохранённые бенды ПРЯМО ЗДЕСЬ, до дозвона. Гасим
			# восстановление на ifup (31-5gmodem-bands) его же маркером - иначе оно
			# на поднявшемся интерфейсе сделало бы ВТОРОЙ реконнект (тот самый
			# двойной подъём). Прото - единственный, кто трогает бенды на дозвоне.
			: > "/tmp/5gmodem_bandrestore_$interface" 2>/dev/null
		fi
		touch "$bmark" 2>/dev/null
	fi

	# FAST PATH: if the PDP context is ALREADY active with a valid address, reuse
	# it instead of re-dialing. netifd calls teardown+setup on any reconfigure -
	# e.g. a route-metric change from the WAN-priority switcher, or a spurious
	# reload - and a cold re-dial tore the data session for ~30-60 s every time we
	# switched TO this modem. Together with the teardown that no longer releases
	# the context, a priority switch becomes instant and lossless (we just
	# re-publish the IP/route with the new metric). SKIP it right after we changed
	# bands: the still-active bearer is on the reset-to-all mask, not the saved one.
	local ip="" try
	# КОГДА СТАРУЮ СЕССИЮ ПЕРЕИСПОЛЬЗОВАТЬ НЕЛЬЗЯ.
	#
	# В дороге оператор гасит прежнюю сессию, но модем об этом не сообщает:
	# AT+CGACT? отвечает «1,1», APN и тип PDP те же, CGPADDR отдаёт СТАРЫЙ адрес.
	# Fast path объявляет интерфейс поднятым с мёртвым bearer'ом - снаружи это
	# «интернет залип», и ifup не помогает, потому что каждый раз берётся та же
	# сессия (живой случай 05.08.2026: пять часов в дороге, несколько смен
	# региона, каждый раз спасал только перезапуск радио).
	#
	# ПО TAC ЭТО ЛОВИТЬ НЕЛЬЗЯ. Tracking area меняется при обычном перемещении по
	# городу, а сессия при этом жива (сеть делает TAU и сохраняет bearer). Сверка
	# по TAC рвала бы связь на каждом втором перекрёстке - лечение хуже болезни.
	# Поэтому два узких признака, оба означают «сессия точно не та»:
	#   1. СМЕНИЛАСЬ СЕТЬ (PLMN) - другой оператор или возврат из роуминга.
	#      Событие редкое, для него холодный дозвон безусловно правильный.
	#   2. НАС ПОПРОСИЛИ ЛЕЧИТЬ. Сторожа перед восстановительным ifup оставляют
	#      маркер: он значит «связи нет, обычный подъём уже пробовали». Тогда
	#      fast path пропускаем, даже если модем уверяет, что контекст активен.
	# Всё остальное (переключение приоритета, обычный ifup) идёт быстрым путём -
	# он и нужен, чтобы переключение было мгновенным и без разрыва.
	local net_plmn net_was net_f cold_f
	net_f="/tmp/5gmodem_fibo_plmn_$interface"
	cold_f="/tmp/5gmodem_fibo_cold_$interface"
	net_plmn=$(sms_tool -d "$dial" at "AT+COPS?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+COPS:.*,"\([0-9]\{5,6\}\)".*/\1/p' | head -1)
	net_was=$(cat "$net_f" 2>/dev/null)
	if [ -f "$cold_f" ]; then
		rm -f "$cold_f"
		echo "fibocom[$$] recovery requested - re-establishing the session"
		bands_changed=1
	elif [ -n "$net_was" ] && [ -n "$net_plmn" ] && [ "$net_plmn" != "$net_was" ]; then
		echo "fibocom[$$] network changed ($net_was -> $net_plmn) - not reusing the old session"
		bands_changed=1
	fi

	# АВТОРИЗАЦИЯ НЕ ПЕРЕЖИВАЕТ РЕБУТ МОДЕМА. Если настроен PAP/CHAP, а модем
	# с момента последней отправки CGAUTH переэнумерировался (devnum сменился) -
	# fast path запрещён: контекст в модеме персистентен и совпадёт, но bearer
	# будет БЕЗ авторизации (адрес есть, трафика нет). Форсируем холодный дозвон.
	case "$auth" in
		pap|chap|both)
			if [ -n "$username" ]; then
				_au_now=$(cat "/sys/bus/usb/devices/$usbpath/devnum" 2>/dev/null)
				_au_was=$(cat "/tmp/fibocom_authed_$interface" 2>/dev/null)
				if [ -z "$_au_was" ] || [ "$_au_now" != "$_au_was" ]; then
					echo "fibocom[$$] modem was re-enumerated - PAP/CHAP authorization lost, cold dial"
					bands_changed=1
				fi
			fi ;;
	esac
	if [ "$bands_changed" = "0" ] && sms_tool -d "$dial" at "AT+CGACT?" 2>/dev/null | tr -d '\r' | grep -qE '^\+CGACT: *1,1'; then
		# Переиспользуем живой контекст, ТОЛЬКО если он на нашем APN. FM350 сам
		# активирует контекст 1 при загрузке/смене SIM с ТЕМ APN, что был прошит
		# последним (напр. "internet.tele2.ru" от прежней eSIM). Если autoapn затем
		# подобрал новый APN для новой симки, fast path без этой сверки радостно
		# переиспользовал бы СТАРЫЙ bearer и новый APN не применился бы никогда -
		# ровно баг «остался старый APN от eSIM» после смены на физ. Мегафон.
		# apn пуст = роуминг / «пусть решает сеть»: там сверять нечего, переиспользуем
		# что есть (иначе рвали бы lossless-переключение приоритета на каждом ifup).
		local cur_ctx cur_apn cur_pdp
		cur_ctx=$(sms_tool -d "$dial" at "AT+CGDCONT?" 2>/dev/null | tr -d '\r' \
			| grep '^+CGDCONT: *1,' | head -1)
		cur_pdp=$(echo "$cur_ctx" | sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p')
		cur_apn=$(echo "$cur_ctx" | sed -n 's/^+CGDCONT: *1,"[^"]*","\([^"]*\)".*/\1/p')
		# Переиспользуем живой контекст, ТОЛЬКО если совпадают И APN, И тип PDP.
		# По APN - иначе остался бы старый APN (см. выше). По типу PDP - иначе,
		# подняв IPV4V6 поверх активного IPV4-контекста, fast path переиспользовал бы
		# IPv4-only bearer и IPv6 не появился бы НИКОГДА (модем сам IPv4->IPv4v6 не
		# апгрейдит). apn пуст = роуминг: там APN не сверяем, но тип PDP - да.
		if { [ -z "$apn" ] || [ "$cur_apn" = "$apn" ]; } && [ "$cur_pdp" = "$pdptype" ]; then
			ip=$(sms_tool -d "$dial" at "AT+CGPADDR=1" 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CGPADDR: *1,"\([0-9.]\{7,\}\)".*/\1/p' | head -1)
			[ "$ip" = "0.0.0.0" ] && ip=""
			# СВЕРЯЕМ, ЧТО МОДЕМ ВООБЩЕ ПРИКРЕПЛЁН К ПАКЕТНОЙ СЕТИ.
			#
			# Приём взят у штатного qmi.sh: тот после дозвона спрашивает
			# get-data-status и, если сессия не «connected», честно объявляет
			# CALL_FAILED вместо «поднято». У нас аналог по AT: AT+CGATT? - если
			# модем откреплён (0), то активный на бумаге контекст и адрес из
			# CGPADDR не значат ничего, трафика через них не будет. Раньше мы
			# смотрели только на CGACT и адрес и в такой ситуации поднимали
			# интерфейс с мёртвым bearer'ом.
			if [ -n "$ip" ]; then
				case "$(sms_tool -d "$dial" at "AT+CGATT?" 2>/dev/null | tr -d '\r' \
					| sed -n 's/^+CGATT: *\([0-9]\).*/\1/p' | head -1)" in
					1) : ;;
					*) echo "fibocom[$$] context is active but the modem is not attached (CGATT!=1) - cold dial"
					   ip="" ;;
				esac
			fi
		else
			echo "fibocom[$$] context (APN \"$cur_apn\", $cur_pdp) != configured (APN \"$apn\", $pdptype) - cold dial"
		fi
	fi

	# COLD DIAL: define the APN, activate the PDP context and read the assigned
	# IPv4 from CGPADDR, retrying a few times - right after a modem swap / USB
	# re-enumeration the context needs a moment, and a single try would leave the
	# interface down until netifd happens to retry.
	if [ -z "$ip" ]; then
		ip=$(_fibocom_activate "$dial" "$pdptype" "$apn")
		# PDP-TYPE FALLBACK. Some SIMs bring up the default bearer only under a
		# specific PDP type. The fleet default IPV4 gets an IP at once, but Tele2 RU
		# (PLMN 25020) REGISTERS yet CGACT hangs on IPV4 and needs IPV4V6 - verified
		# live on FM350 (user report: disable a band -> IP gone for minutes). The
		# vendor initial-attach-APN knob other handlers use (AT+EIAAPN) is ERROR on
		# this firmware, so we can't align attach that way; instead, when the
		# configured type yields no IP, retry once with the COMPLEMENTARY type. This
		# fires ONLY on failure, so the common case (IPV4 works) pays nothing.
		if [ -z "$ip" ]; then
			local alt="IPV4V6"; [ "$pdptype" = "IPV4V6" ] && alt="IP"
			echo "fibocom[$$] no IP with $pdptype, retrying $alt"
			ip=$(_fibocom_activate "$dial" "$alt" "$apn")
		fi
	fi
	if [ -z "$ip" ]; then
		_fib_unlock
		proto_notify_error "$interface" NO_IP_ADDRESS
		proto_block_restart "$interface"
		return 1
	fi

	# gateway (field 5) and DNS (fields 6,7) from CGCONTRDP - gw is usually empty
	# on cellular (point-to-point), in which case the default route is on-link.
	local rdp gw dns1 dns2
	rdp=$(sms_tool -d "$dial" at "AT+CGCONTRDP=1" 2>/dev/null | tr -d '\r' | grep '+CGCONTRDP:' | head -1)
	gw=$(echo "$rdp"   | awk -F',' '{gsub(/"/,"",$5); print $5}')
	dns1=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$6); print $6}')
	dns2=$(echo "$rdp" | awk -F',' '{gsub(/"/,"",$7); print $7}')

	# Фактический тип PDP ЖИВОГО контекста: после fallback IPV4V6<->IPV4 (см. выше)
	# он мог отличаться от настроенного. По нему решаем, поднимать ли IPv6.
	local ctx_pdp
	ctx_pdp=$(sms_tool -d "$dial" at "AT+CGDCONT?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CGDCONT: *1,"\([^"]*\)".*/\1/p' | head -1)

	ip link set "$netdev" up 2>/dev/null
	if [ "$IS_XMM" = 1 ]; then
		# NCM-канал XMM на ARP не отвечает: без noarp пакеты застревают в
		# neighbour-резолве. Шлюза у XMM нет (CGCONTRDP пуст) - маршрут on-link.
		ip link set "$netdev" arp off 2>/dev/null
		gw=""
		local xd
		xd=$(sms_tool -d "$dial" at "AT+XDNS?" 2>/dev/null | tr -d '\r' | grep '^+XDNS: 1,' | head -1)
		[ -n "$xd" ] && {
			dns1=$(echo "$xd" | awk -F'"' '{print $2}')
			dns2=$(echo "$xd" | awk -F'"' '{print $4}')
		}
	fi

	proto_init_update "$netdev" 1
	proto_add_ipv4_address "$ip" "255.255.255.0"
	case "$gw" in
		""|"0.0.0.0") proto_add_ipv4_route "0.0.0.0" "0" ;;   # on-link default
		*)            proto_add_ipv4_route "0.0.0.0" "0" "$gw" ;;
	esac
	[ -n "$dns1" ] && [ "$dns1" != "0.0.0.0" ] && proto_add_dns_server "$dns1"
	[ -n "$dns2" ] && [ "$dns2" != "0.0.0.0" ] && proto_add_dns_server "$dns2"
	# Дальше идут только объявления адресов и дочерний dhcpv6 - AT-порт больше
	# не нужен, отдаём очередь опросу метрик как можно раньше.
	# Запоминаем сеть удачного дозвона - по ней fast path увидит смену оператора.
	[ -n "$net_plmn" ] && printf '%s' "$net_plmn" > "$net_f" 2>/dev/null
	_fib_unlock
	proto_send_update "$interface"

	# IPv6. У сотовых модемов маршрутизируемый IPv6-префикс приходит НЕ через
	# CGPADDR (там лишь link-local / interface-id), а по RA / DHCPv6-PD на самом
	# usbnet-интерфейсе: модем выступает маршрутизатором. Поэтому статикой IPv6 НЕ
	# прописываем, а поднимаем ДОЧЕРНИЙ dhcpv6-интерфейс (odhcp6c) - он и получает
	# префикс. Так же делают ATC (mrhaav) и XMM. Только если контекст реально
	# двухстековый/IPv6: после fallback он мог оказаться чистый IPv4 - тогда IPv6 нет.
	#
	# ВНИМАНИЕ по firewall: интерфейс модема (и этот dhcpv6-ребёнок, ему передаём
	# зону родителя) должен быть в зоне wan, где INPUT принимает ICMPv6 RA. На части
	# сетей (замечено на FM350) нужно ЯВНО разрешить RA от link-local модема:
	#   config rule / src 'wan' / proto 'icmp' / src_ip 'fe80::1' / family 'ipv6' / ACCEPT
	case "$ctx_pdp" in
		*[vV]6*)
			local zone6
			zone6=$(_fibocom_fwzone "$interface")
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcpv6"
			json_add_string extendprefix 1
			proto_add_dynamic_defaults
			[ -n "$zone6" ] && json_add_string zone "$zone6"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
			echo "fibocom[$$] IPv6 ($ctx_pdp): brought up dhcpv6 interface ${interface}_6 (zone ${zone6:--})"
			;;
	esac
}

proto_fibocom_teardown() {
	local interface="$1"

	# NOTE: we deliberately do NOT deactivate the PDP context here. netifd calls
	# teardown+setup on any interface reconfigure (notably a route-metric change
	# from the WAN-priority switcher); releasing the context (AT+CGACT=0,1) each
	# time tore the data session and forced a slow re-dial. Leaving the bearer up
	# lets setup's fast path reuse it, so switching priority is instant and
	# lossless. The bearer costs nothing while the interface is down (no route, no
	# traffic); a true disconnect happens on USB re-enumeration / modem controls.
	#
	# И НИЧЕГО НЕ СООБЩАЕМ NETIFD. Здесь стояла пара proto_init_update "*" 0 +
	# proto_send_update - как в штатных qmi.sh и mbim.sh. Она НЕ РАБОТАЕТ НИКОГДА:
	# netifd зовёт teardown, уже переведя машину состояний в S_TEARDOWN, а
	# proto_ext_update_link (netifd/proto-ext.c) в этом состоянии отвечает
	# UBUS_STATUS_PERMISSION_DENIED. В журнале это давало строку
	#   Command failed: ubus call network.interface notify_proto ... (Permission denied)
	# на КАЖДЫЙ обрыв - её и принимали за поломку прав. Интерфейс netifd гасит
	# сам, уведомление ему не нужно. Коды ошибок (proto_notify_error, action 3)
	# идут другим обработчиком и по-прежнему доходят.
}

add_protocol fibocom
