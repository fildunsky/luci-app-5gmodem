#!/bin/sh
#
# Управление eSIM (eUICC) активного модема через lpac (SGP.22).
#
#   esim.sh status               -> {"available":0|1,"active":0|1}  (дёшево, без lpac)
#   esim.sh dump                 -> {"chip":<lpac chip info>,"profiles":<lpac profile list>}
#   esim.sh enable  <iccid>      -> включить профиль (+ отослать нотификации)
#   esim.sh disable <iccid>      -> выключить профиль (+ нотификации)
#   esim.sh delete  <iccid>      -> удалить профиль (+ нотификации)
#   esim.sh nickname <iccid> <n> -> задать псевдоним
#   esim.sh download <code>      -> скачать профиль по activation code (LPA:1$..)
#   esim.sh notifications        -> lpac notification list
#   esim.sh flush                -> отослать (+удалить) все ожидающие нотификации
#
# lpac зовём НАПРЯМУЮ (/usr/lib/lpac): /usr/bin/lpac в пакете OpenWrt - это
# UCI-обёртка, которая игнорирует env и по умолчанию ходит через uqmi.
#
# ВЫБОР ПОРТА. На FM350 доступ к SIM (+CCHO/+CGLA) есть только на ОДНОМ tty, и
# его номер меняется при каждом USB-переперечислении. Остальные порты отвечают
# на "AT", но CCHO глотают (lpac бы завис - страхует сторожевой таймер).
# Рабочий порт находим дорогой пробой один раз и КЭШИРУЕМ; дальше доверяем
# кэшу, пока tty жив и отвечает на AT (дёшево). При сбое операции кэш
# сбрасываем и переоткрываем порт (модем мог переперечислиться).

RES="/usr/share/5gmodem"
# lpac бинарь: 2.3.x кладёт его в /usr/lib/lpac/lpac + driver-плагины в
# /usr/lib/lpac/driver (loader находит их по LPAC_DRIVER_HOME - наш патч, т.к.
# OpenWrt срезает RUNPATH). 2.1.x был единым файлом /usr/lib/lpac. Поддерживаем оба.
if [ -x /usr/lib/lpac/lpac ]; then
	LPAC="/usr/lib/lpac/lpac"
	export LPAC_DRIVER_HOME="/usr/lib/lpac"
elif [ -x /usr/bin/lpac ]; then
	# Официальный OpenWrt-пакет lpac кладёт бинарь в /usr/bin/lpac; наша сборка
	# lpac-build - туда же wrapper (сам ставит LPAC_DRIVER_HOME). Без этой ветки
	# приложение писало «lpac не установлен», хотя он есть (живой случай: T99W175
	# с официальным lpac 2.3.0 - вкладка eSIM отказывалась работать).
	LPAC="/usr/bin/lpac"
	# ПОЛУДОХЛАЯ УСТАНОВКА. /usr/bin/lpac - обёртка, она запускает /usr/lib/lpac/lpac.
	# Патченый пакет не встаёт поверх официального (тот кладёт /usr/lib/lpac ФАЙЛОМ,
	# нашему нужен КАТАЛОГ): apk сыплет «failed to extract ... Not a directory»,
	# сносит бинарь, а обёртку оставляет - пакет числится установленным, но запускать
	# нечего. Раньше вкладка молча отвечала «eSIM нет» и пользователь искал причину
	# в модеме. Воспроизведено на стенде 28.07.2026.
	[ -e /usr/lib/lpac/lpac ] || LPAC_BROKEN="обёртка /usr/bin/lpac есть, но самого бинаря /usr/lib/lpac/lpac нет: установка lpac испорчена (обычно - патченый пакет ставили поверх официального). Лечится: apk del lpac; rm -rf /usr/lib/lpac /usr/bin/lpac; установить заново"
elif [ -x /usr/lib/lpac ]; then
	LPAC="/usr/lib/lpac"
else
	# Последний рубеж: вдруг lpac где-то в PATH.
	LPAC="$(command -v lpac 2>/dev/null)"
	[ -n "$LPAC" ] || LPAC="/usr/lib/lpac"
fi

# Очередь к AT-порту: проба CCHO и работа lpac идут в тот же tty, что и опрос
# метрик. Без очереди проба срывалась на коллизии, и мы записывали «eSIM нет»
# у модема, где eUICC есть, - живой случай на FM350 с eSIM.
. /usr/share/5gmodem/atlock.sh
BRIDGE="/usr/share/5gmodem/esim-apdu-bridge.sh"
# Кэш порта eUICC - ПО ПУТИ МОДЕМА, а не один на всех. Был общий файл, и когда
# активный модем менялся, find_port проверял ЧУЖОЙ закэшированный порт: на нём
# открывался eUICC ДРУГОГО модема, и односимочный SIM7600 объявлялся с eSIM,
# потому что рядом стоял FM350 с настоящей eUICC на /dev/ttyUSB1.
# Модемы, у которых ПОТЕНЦИАЛЬНО есть eSIM (eUICC) - по vid:pid. Список для
# ВИДИМОСТИ ВКЛАДКИ (не для работы с чипом): показать вкладку, если воткнут
# такой модуль. Ошибка в сторону «показали лишнее» дёшева - в настройках есть
# галка скрыть; ошибка «спрятали нужное» хуже. Расширяется по мере проверки.
#   0e8d:7127 Fibocom FM350-GL (проверено живьём: eUICC есть)
#   2cb7:0104/0105 Fibocom FM150/FM160
#   2c7c:0800/0801 Quectel RM500Q / RM520N-GL (варианты с eUICC)
#   2c7c:0900 Quectel RG500Q
#   Foxconn T99W175 / Dell DW5930e (SDX55, eUICC) - несколько композиций:
#     05c6:9025, 05c6:90d5, 1e2d:00b3, 1e2d:00b7, 1e2d:00b8, 1e2d:00b9.
#     ВНИМАНИЕ: 05c6:90d5 и 1e2d:00b7 делят с Compal RXM-G1 / Thales MV31-W - у
#     них eSIM может не быть, тогда вкладка покажется зря; прячется галкой в
#     настройках (цена ложного «показали» ниже, чем «спрятали нужное»).
ESIM_CAPABLE_VIDPIDS="0e8d:7127 2cb7:0104 2cb7:0105 2c7c:0800 2c7c:0801 2c7c:0900 05c6:9025 05c6:90d5 1e2d:00b3 1e2d:00b7 1e2d:00b8 1e2d:00b9"

PORTCACHE="/tmp/5gmodem_esim_port_$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null | tr -c 'A-Za-z0-9' '_')"
# Живой лог операции: мост дописывает сюда строки прогресса ПО МЕРЕ их прихода,
# UI читает его во время спиннера. Переживает неудачу - нужен для диагностики.
LIVELOG="/tmp/5gmodem_esim_progress.log"
GSMACERT="/usr/share/5gmodem/certs/gsma-ci.pem"
CACACHE="/tmp/5gmodem_esim_ca.pem"

# HTTP-бэкенд lpac: auto|curl|bridge (см. шапку esim-apdu-bridge.sh).
#   curl   - встроенный в lpac. С mbedTLS не берёт SM-DP+ с сертификатами GSMA CI.
#   bridge - наш stdio-мост поверх wget/OpenSSL, берёт и обычные, и GSMA CI.
#   auto   - bridge, если есть wget и наш корень; иначе curl.
# Возвращает "bridge" или "curl".
http_backend() {
	_hb=$(uci -q get 5gmodem.@5gmodem[0].esim_http)
	[ -n "$_hb" ] || _hb="auto"
	case "$_hb" in
		curl)   echo curl ;;
		bridge) echo bridge ;;
		*)      if command -v wget >/dev/null 2>&1 && [ -f "$GSMACERT" ]; then
				echo bridge
			else
				echo curl
			fi ;;
	esac
}

# APDU-бэкенд lpac: at|bridge (см. шапку esim-apdu-bridge.sh).
#   at     - НАТИВНЫЙ AT-драйвер lpac (CCHO/CGLA сам на tty). С патчами #446/#448
#            (дедлайны + байтовые чтения) он не залипает на большом CGLA - тот самый
#            транспортный флап, из-за которого падала загрузка через sms_tool-мост.
#            Требует lpac >= 2.3.x с плагинами (LPAC_DRIVER_HOME) и bare-CCHO (#449).
#   bridge - наш stdio-мост поверх sms_tool (CCHO/CGLA через AT-команды). Фолбэк.
# HTTP при этом ВСЕГДА через мост (LPAC_HTTP=stdio), т.к. TLS у GSMA-CI SM-DP+
# (truphone/redtea) mbedTLS-curl не берёт. Т.е. at = нативный APDU + мостовой HTTP.
# APDU-транспорт к eUICC. Ручной выбор (UCI esim_apdu) в приоритете, иначе auto по
# протоколу интерфейса активного модема:
#   серийные (fibocom/atc/xmm/ncm/3g/wwan) умеют AT+CCHO -> at;
#   mbim / modemmanager -> mbim ; qmi -> qmi (eUICC через cdc-wdm + прокси).
# Нужен lpac >= 2.3.0_p2 (в нём собраны бэкенды qmi/uqmi/mbim). Старый single-file
# lpac (2.1) отдаёт только stdio-мост. Юзер может задать явно: at|qmi|uqmi|mbim|bridge.
apdu_backend() {
	_ab=$(uci -q get 5gmodem.@5gmodem[0].esim_apdu)
	case "$_ab" in
		at|uqmi|bridge) echo "$_ab"; return ;;
		qmi|mbim)
			# qmi/mbim ходят по cdc-wdm и зависят от ЕГО драйвера. ЗАЛИПШИЙ ручной
			# выбор ломает eSIM: у форумчанина esim_apdu=qmi остался на модеме в
			# MBIM-композиции, а qmi-бэкенд lpac на cdc_mbim канал не открывает
			# (проба отвечала "ни один порт не eSIM"). Сверяем с реальным драйвером
			# и берём совместимый бэкенд; драйвер неизвестен - доверяем юзеру.
			case "$(_wdm_driver)" in
				*cdc_mbim*) echo mbim ;;
				*qmi_wwan*) echo qmi ;;
				*)          echo "$_ab" ;;
			esac
			return ;;
	esac
	[ -x /usr/lib/lpac/lpac ] || { echo bridge; return; }   # старый layout - только мост
	_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_sec="m_$(echo "$_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	_if=$(uci -q get "5gmodem.$_sec.network")
	[ -n "$_if" ] || _if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_abp=$(uci -q get "network.$_if.proto")
	case "$_abp" in
		mbim|modemmanager|qmi)
			# БЭКЕНД ОПРЕДЕЛЯЕТ ДРАЙВЕР УЗЛА cdc-wdm, А НЕ ИМЯ ПРОТОКОЛА.
			#
			# Ручной выбор эту сверку делал (выше), авто - нет, и на
			# proto=modemmanager безусловно брался mbim. Но modemmanager рулит
			# модемом в ЛЮБОЙ композиции: у двух T99W175 на ZBT (05c6:9025) узлы
			# сидят на qmi_wwan, mbim-бэкенд lpac канал на них не открывает, и
			# eSIM отвечала code -1 "euicc_init" - в отчёте это выглядело как
			# «eSIM нет», хотя eUICC у SDX55 читается именно по QMI.
			case "$(_wdm_driver)" in
				*cdc_mbim*) echo mbim ;;
				*qmi_wwan*) echo qmi ;;
				# Драйвер не определился - решаем по прото, как раньше.
				*) [ "$_abp" = qmi ] && echo qmi || echo mbim ;;
			esac ;;
		*) echo at ;;
	esac
}

# eUICC достаётся по cdc-wdm (MBIM), а не по AT-tty. Тогда весь AT-only преамбул
# (живой порт / esim_active по AT+SIMTYPE / чистка ISD-R каналов / find_port) не
# применим и дал бы ложное "no AT port" - его пропускаем для mbim.
mbim_backend() { [ "$(apdu_backend)" = "mbim" ]; }

# ЛЮБОЙ бэкенд, работающий ПО cdc-wdm: mbim, qmi, uqmi. Преамбул надо пропускать
# всем трём, а не только mbim - иначе qmi-бэкенд (модем на qmi_wwan, у которого
# AT-портов может не быть вовсе) спотыкался бы на "no AT port" ещё до того, как
# lpac открыл бы канал по своему узлу.
wdm_backend() {
	case "$(apdu_backend)" in
		mbim|qmi|uqmi) return 0 ;;
	esac
	return 1
}

# КАНАЛ cdc-wdm МОДЕМА ПОД ModemManager - НЕ НАШ, И К eUICC ПО НЕМУ НЕ ХОДИМ.
#
# Это то же правило владения, что везде (registry owner=mm), но здесь у него
# самая высокая цена из виденных: у пользователя с двумя T99W175 под MM заход на
# вкладку eSIM РОНЯЛ МОДЕМ В РЕБУТ. Механизм: euicc_probe_wdm открывал
# mbim-proxy на том же cdc-wdm, которым в этот момент живёт ModemManager, - два
# хозяина на управляющем канале, и прошивка не выдерживает. Диагностика при этом
# не роняла: она ходит последовательно, а страница - параллельно с опросом.
# Для работы с eSIM у такого модема надо сперва забрать его у MM (галка
# «Скрыть от ModemManager» / смена прото) - об этом честно говорит reason.
_mm_owns_channel() {
	[ "$("$RES/registry.sh" active 2>/dev/null \
		| jsonfilter -e '@.owner' 2>/dev/null)" = "mm" ]
}

# cdc-wdm управляющего узла активного модема (для qmi/mbim-бэкендов lpac).
# УЗЕЛ ДОЛЖЕН БЫТЬ ИМЕННО КАНАЛОМ УПРАВЛЕНИЯ, А НЕ ЛЮБЫМ СИМВОЛЬНЫМ УСТРОЙСТВОМ.
#
# Проверки `-c` мало: ttyUSB - тоже символьное устройство, и запасной вариант
# «взять network.<iface>.device» ниже спокойно отдавал AT-порт. У протоколов
# atc/xmm/fibocom там ИМЕННО он и лежит (живой отчёт WH3000, FM350 в RNDIS:
# «узел cdc-wdm: /dev/ttyUSB1»), а дальше этот путь уходит в LPAC_APDU_*_DEVICE,
# то есть lpac получает tty вместо канала qmi/mbim. Признак настоящего узла - он
# зарегистрирован ядром как канал управления: usbmisc (cdc-wdm, оттуда же
# _wdm_driver читает драйвер) или wwan (узлы /dev/wwanXpYMBIM нового
# подсистемного интерфейса - listmodems кладёт их в тот же wdm[]).
_is_wdm_node() {   # $1 - путь к узлу
	[ -c "$1" ] || return 1
	[ -e "/sys/class/usbmisc/${1##*/}" ] || [ -e "/sys/class/wwan/${1##*/}" ]
}

esim_wdm() {
	_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_w=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_ap\"].wdm[0]" 2>/dev/null)
	_is_wdm_node "$_w" || _w=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).device")
	_is_wdm_node "$_w" && { echo "$_w"; return; }
	# ЗАПАСНОЙ /dev/cdc-wdm0 - ТОЛЬКО КОГДА УЗЕЛ В СИСТЕМЕ ОДИН.
	#
	# Он стоял здесь безусловно и на мультимодеме бил мимо: у модема без своего
	# cdc-wdm (FM350 в RNDIS) это узел СОСЕДА, то есть APDU к чужой eUICC и чужой
	# драйвер в определении транспорта. Один узел в системе - промахнуться не обо
	# что, там фолбэк по-прежнему полезен (listmodems мог сорваться).
	set -- /dev/cdc-wdm*
	[ "$#" = 1 ] && [ -c "$1" ] && { echo "$1"; return; }
	echo ""
}

# Драйвер cdc-wdm активного модема: cdc_mbim | qmi_wwan | пусто. По нему apdu_backend
# сверяет ручной qmi/mbim-выбор (см. там). Путь берём из /sys самого узла.
_wdm_driver() {
	_wd=$(esim_wdm)
	readlink -f "/sys/class/usbmisc/${_wd##*/}/device/driver" 2>/dev/null | sed 's#.*/##'
}

# Проба eUICC по cdc-wdm (qmi/mbim/uqmi): lpac chip info. 0 = eUICC ответила (в
# выводе есть EID). НЕ трогает AT-порт (Qualcomm SDX55: eUICC доступен только по
# QMI/MBIM). Через прокси (qmi-proxy/mbim-proxy) канал делится с data-сессией.
# Нужен lpac >= 2.3.0_p2 (с этими бэкендами). $1 = бэкенд.
euicc_probe_wdm() {
	_pwdev=$(esim_wdm)
	# Узел не определился - НЕ пробуем: с пустым LPAC_APDU_*_DEVICE lpac возьмёт
	# устройство по своему умолчанию, а это опять чужой модем.
	[ -c "$_pwdev" ] || return 1
	_pwsave=""
	_pwskip=1
	case "$1" in
		qmi)  _pw="LPAC_APDU=qmi LPAC_APDU_QMI_DEVICE=$_pwdev" ;;
		uqmi) _pw="LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE=$_pwdev" ;;
		mbim) # даже простое чтение chip info может увести активный слот на пустую
		      # eSIM -> запоминаем mapping (см. _mbim_slot_*). Разрешаем переключение
		      # только там, где целевой слот уже активная eSIM (см. _mbim_skipmap).
		      _pwskip=$(_mbim_skipmap "$_pwdev")
		      _pw="LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE=$_pwdev LPAC_APDU_MBIM_USE_PROXY=1 LPAC_APDU_MBIM_UIM_SLOT=$(_mbim_uim_slot) LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=$_pwskip"
		      _pwsave=$(_mbim_slot_get "$_pwdev") ;;
		*)    return 1 ;;
	esac
	_pwr=1
	_pwtry=0
	while [ "$_pwtry" -lt 2 ]; do
		_pwtry=$((_pwtry + 1))
		_pwo="/tmp/5gmodem_esim_wdmprobe.$$"
		rm -f "$_pwo"
		( env $_pw LPAC_HTTP="$(http_local_drv)" "$LPAC" chip info >"$_pwo" 2>/dev/null ) &
		_pwp=$!
		_pwn=0
		while kill -0 "$_pwp" 2>/dev/null && [ "$_pwn" -lt 15 ]; do sleep 1; _pwn=$((_pwn + 1)); done
		kill "$_pwp" 2>/dev/null
		grep -qi '"eidValue"\|"eid"' "$_pwo" 2>/dev/null && _pwr=0
		rm -f "$_pwo"
		[ "$_pwr" = 0 ] && break
		# ЗАКЛИНИВШИЙ mbim-proxy = ложное "noeuicc". У Cudy TR3000 (DW5821e,
		# proto=mbim) висящий прокси одновременно валил data-сессию и пробу eUICC.
		# Если прокси есть, а канал не наш MM - перезапускаем его и пробуем ещё
		# раз. У MM-модемов прокси трогать нельзя: это его рабочий канал.
		if [ "$_pwtry" = 1 ] && [ "$1" = mbim ] \
			&& pidof mbim-proxy >/dev/null 2>&1 && ! _mm_owns_channel; then
			logger -t 5gmodem "esim: mbim-проба не ответила, перезапускаю mbim-proxy"
			killall mbim-proxy 2>/dev/null
			sleep 2
		else
			break
		fi
	done
	# ВОЗВРАЩАЕМ MAPPING ВСЕГДА, а не только когда запрещали переключение.
	#
	# active-esim в ответе модема описывает СОСТОЯНИЕ КАРТЫ в слоте («там eSIM с
	# профилями»), а НЕ то, что исполнитель уже привязан к этому слоту. То есть
	# у модема с рабочей SIM1 и eSIM в SIM2 проверка честно скажет «да», мы
	# разрешим переключение - и модем уйдёт на SIM2. Ровно это пользователи и
	# видят: «захожу на вкладку eSIM, а модем сам переключается на SIM2» и связь
	# по основной симке пропадает.
	#
	# Поэтому разрешение и откат решают РАЗНЫЕ задачи: разрешение даёт lpac
	# добраться до eUICC (иначе профили не прочитать вовсе), а откат возвращает
	# рабочую SIM после того, как чтение закончено.
	[ "$1" = mbim ] && _mbim_slot_restore "$_pwdev" "$_pwsave"
	return $_pwr
}

# Системный бандл + корень GSMA в один файл (wget принимает только один
# --ca-certificate). Пересобираем, если исходники новее кэша: бандл обновляется
# пакетом ca-certificates.
ca_bundle() {
	_sys="/etc/ssl/certs/ca-certificates.crt"
	[ -f "$GSMACERT" ] || { echo ""; return; }
	if [ ! -f "$CACACHE" ] || [ "$GSMACERT" -nt "$CACACHE" ] || \
	   { [ -f "$_sys" ] && [ "$_sys" -nt "$CACACHE" ]; }; then
		{ [ -f "$_sys" ] && cat "$_sys"; cat "$GSMACERT"; } > "$CACACHE" 2>/dev/null
	fi
	echo "$CACACHE"
}

err() { echo "{\"type\":\"lpa\",\"payload\":{\"code\":-1,\"message\":\"$1\",\"data\":\"\"}}"; }

# --- Защита активного SIM-слота при работе с eUICC по MBIM --------------------
# У Qualcomm SDX55 (Foxconn T99W175 / Thales MV31-W / Dell DW5930e) eUICC сидит на
# SIM2. Чтобы дотянуться до него, lpac/модем может ПЕРЕМАПить активный слот на
# eSIM - а она обычно ПУСТАЯ, и рабочая SIM1 тут же отваливается, wwan падает
# (это происходит просто от ЧТЕНИЯ eUICC - напр. при открытии вкладки eSIM).
# Двойная защита: (1) LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1 просит lpac слот не трогать;
# (2) эти хелперы запоминают mapping ДО операции и возвращают его, если он ушёл.
# Нумерация mbim: slot 0 = SIM1, slot 1 = SIM2/eSIM (в LuCI это SIM1/SIM2).
# Перенесено с рабочей community-сборки MBIM-lpac для T99W175.
_mbim_slot_get() {   # $1 = cdc-wdm -> номер активного слота executor'а 0
	command -v mbimcli >/dev/null 2>&1 || return 0
	mbimcli -d "$1" -p --ms-query-device-slot-mappings 2>/dev/null \
		| sed -n "s/.*Executor '0': slot '\([0-9][0-9]*\)'.*/\1/p" | head -1
}
_mbim_slot_restore() {   # $1 = cdc-wdm, $2 = сохранённый слот (пусто = ничего не делаем)
	[ -n "$2" ] || return 0
	command -v mbimcli >/dev/null 2>&1 || return 0
	_msr=$(_mbim_slot_get "$1")
	[ -n "$_msr" ] && [ "$_msr" != "$2" ] \
		&& mbimcli -d "$1" -p --ms-set-device-slot-mappings="$2" >/dev/null 2>&1
}
# HTTP-ДРАЙВЕР, КОТОРЫЙ РЕАЛЬНО ЕСТЬ В СБОРКЕ. Локальным операциям (проба eUICC,
# chip info, список профилей) сеть не нужна, но lpac всё равно поднимает HTTP-плечо
# при старте и падает с «No HTTP driver found», если запрошенного драйвера нет.
# В сборке lpac-fm350 из HTTP-плагинов лежит только stdio, а здесь был жёстко
# прописан curl - проба валилась ДО APDU, и вкладка честно писала «eUICC не
# ответил», хотя чип живой (живой случай: Thales MV31-W / T99W175 на MBIM).
http_local_drv() {
	[ -d /usr/lib/lpac/driver ] || { echo curl; return; }   # 2.1.x: единый бинарь, драйверы внутри
	[ -f /usr/lib/lpac/driver/driver_http_curl.so ] && { echo curl; return; }
	[ -f /usr/lib/lpac/driver/driver_http_stdio.so ] && { echo stdio; return; }
	echo curl
}

# Слот eUICC. Обёртка /usr/bin/lpac из пакета lpac-build читает uim_slot, а мы
# исторически slot - при ручной настройке легко промахнуться мимо нужного ключа,
# поэтому принимаем оба.
_mbim_uim_slot() {
	_v=$(uci -q get lpac.mbim.slot)
	[ -n "$_v" ] || _v=$(uci -q get lpac.mbim.uim_slot)
	[ -n "$_v" ] && echo "$_v" || echo 2
}
# ИНДЕКС ЦЕЛЕВОГО СЛОТА ДЛЯ mbimcli: у него нумерация с НУЛЯ, а у нас, как и у
# lpac, слоты считаются с единицы.
_mbim_target_index() {
	_mti=$(_mbim_uim_slot)
	case "$_mti" in ''|*[!0-9]*) return 1 ;; esac
	[ "$_mti" -gt 0 ] || return 1
	echo $((_mti - 1))
}

# В ЦЕЛЕВОМ СЛОТЕ УЖЕ АКТИВНАЯ eSIM? Спрашиваем сам модем.
# Через прокси (-p) - канал общий с ModemManager и с самим lpac.
_mbim_target_is_active_esim() {
	command -v mbimcli >/dev/null 2>&1 || return 1
	_tie=$(_mbim_target_index) || return 1
	mbimcli -d "$1" -p --ms-query-slot-info-status="$_tie" 2>/dev/null \
		| grep -qi "active-esim"
}

# РАЗРЕШАТЬ ЛИ lpac ПЕРЕКЛЮЧАТЬ СЛОТ.
#
# Раньше здесь стояло жёсткое «1» - не трогать никогда. Это спасало рабочую
# физическую SIM (см. пояснение у _mbim_slot_*), но у модемов, где eUICC сидит
# ВО ВТОРОМ слоте, оборачивалось другой бедой: после перезагрузки MBIM-исполнитель
# остаётся привязан к SIM1, добраться до eUICC lpac не может, и вкладка честно
# сообщает «eSIM недоступна». Живой случай - T99W175 / Thales MV31-W (правку
# прислал пользователь, проверив на своём модеме).
#
# Теперь решаем по состоянию ЦЕЛЕВОГО слота: если модем уже помечает его как
# active-esim, переключение туда физическую симку увести не может - разрешаем.
# Во всех остальных случаях запрет остаётся, как и был.
#
# Отказ безопасный: нет mbimcli, модем не понимает запроса, слот не задан - всё
# это даёт «1», то есть прежнее поведение.
# Явная настройка пользователя всегда важнее автоматики.
_mbim_skipmap() {
	_v=$(uci -q get lpac.mbim.skip_slot_mapping)
	[ -n "$_v" ] && { echo "$_v"; return; }
	_mbim_target_is_active_esim "$1" && echo 0 || echo 1
}

# lpac через STDIO-бэкенд + наш AT-мост (esim-apdu-bridge.sh). Прямой AT-драйвер
# lpac виснет на FM350-GL (persistent-буфер at_expect рассинхронизируется), зато
# stdio+bridge работает без залипаний — транспорт APDU (CCHO/CGLA/CCHC) делает мост,
# lpac только гоняет JSON. Нужен lpac >= 2.3.0-fm350-fix (исправлен json_request в
# stdio.c) либо lpac 2.1.x (stdio читал корректно из коробки).
# Пламбинг «зеркальный»: мост читает запросы lpac из FIFO и пишет ответы в pipe ->
# stdin lpac; stdout lpac -> FIFO -> stdin моста. Финальный "lpa"-результат мост
# кладёт в файл. Всё под сторожевым таймером.
# run_lpac <timeout_s> <args...>   (порт = $PORT, установленный вызывающим кодом)
run_lpac() {
	_T="$1"; shift
	# СЕРИАЛИЗУЕМ AT-ПОРТ НА ВСЮ lpac-СЕССИЮ. Нативный AT-драйвер держит tty
	# непрерывно 10-240 c, а опрос метрик (5gmodem.sh) дёргает ТОТ ЖЕ порт FM350
	# за RSSI/RSRP. Параллельный доступ рвёт связь драйвера ("read error / Device
	# not responding to AT commands", CGLA без ответа) - download спотыкался на
	# большом CGLA prepare_download/load. Мост это переживал (короткие sms_tool-
	# вызовы), нативный драйвер - нет. Берём at_lock на всё (включая чистку каналов
	# и сам lpac). _prelock: если лок УЖЕ держит предок - не отпускаем его чужой лок.
	_BE=$(apdu_backend)
	# --- MBIM: ОТДЕЛЬНАЯ ветка (нативный mbim-драйвер lpac, без AT-моста). --------
	# У Qualcomm SDX55 (Foxconn T99W175 / Thales MV31-W / Dell DW5930e) eUICC сидит
	# на SIM2, и чтобы дотянуться до него, lpac/модем может ПЕРЕМАПить активный слот
	# на eSIM. eSIM обычно пустая -> рабочая SIM1 отваливается, wwan падает (просто
	# от ОТКРЫТИЯ вкладки eSIM). Двойная защита:
	#   1) LPAC_APDU_MBIM_SKIP_SLOT_MAPPING=1 - lpac не трогает активный слот;
	#   2) запоминаем slot mapping ДО lpac и возвращаем, если он всё же ушёл.
	# Нумерация: в mbim slot 0 = SIM1, slot 1 = SIM2/eSIM (в LuCI это SIM1/SIM2).
	# Подход перенесён с рабочей community-сборки MBIM-lpac для T99W175.
	if [ "$_BE" = "mbim" ]; then
		_MDEV=$(esim_wdm)
		_MOLD=$(_mbim_slot_get "$_MDEV")
		# Решение о переключении слота принимаем ОДИН раз и запоминаем: ниже по
		# нему же решаем, откатывать ли mapping (см. _mbim_skipmap).
		_MSKIP=$(_mbim_skipmap "$_MDEV")
		_MR="/tmp/5gmodem_esim_mbim.$$"; rm -f "$_MR"
		env LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE="$_MDEV" \
			LPAC_APDU_MBIM_UIM_SLOT="$(_mbim_uim_slot)" LPAC_APDU_MBIM_USE_PROXY=1 \
			LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="$_MSKIP" LPAC_HTTP="$(http_local_drv)" \
			"$LPAC" "$@" > "$_MR" 2>/dev/null &
		_PID=$!; _n=0
		while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
		kill -0 "$_PID" 2>/dev/null && { kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null; }
		# Откат безусловный - см. пояснение в euicc_probe_wdm: разрешение нужно,
		# чтобы дотянуться до eUICC, а вернуть рабочую SIM надо в любом случае.
		_mbim_slot_restore "$_MDEV" "$_MOLD"
		if [ -s "$_MR" ]; then cat "$_MR"; else err "timeout"; fi
		rm -f "$_MR"
		return
	fi
	_prelock="$_AT_LOCK_HELD"
	_locked=0
	# AT-порт трогают только at (напрямую) и bridge (через мост). qmi/mbim достают
	# eUICC по cdc-wdm (+ прокси), метрики его не используют -> ни замок, ни чистка
	# AT-каналов там не нужны.
	case "$_BE" in
	at|bridge)
		at_lock "$PORT" 20; _locked=1
		# Чистим утёкшие логические каналы ISD-R ПЕРЕД КАЖДОЙ операцией lpac: после
		# предыдущей операции канал мог остаться открытым (или закрылся не полностью),
		# и следующий CCHO завис бы -> euicc_init падает. Одна операция = чистый старт.
		for _c in 1 2 3 4 5 6 7 8; do at_bounded "$PORT" "AT+CCHC=$_c" 2 >/dev/null; done
		;;
	esac
	_RES="/tmp/5gmodem_esim_res.$$"
	_LOOP="/tmp/5gmodem_esim_loop.$$"
	rm -f "$_RES" "$_LOOP"; mkfifo "$_LOOP" 2>/dev/null
	# Зеркальный пайплайн: мост читает запросы lpac из FIFO (loop), пишет ответы в
	# pipe -> stdin lpac; stdout lpac -> loop -> stdin моста. Мост выходит на "lpa"
	# результате -> lpac ловит SIGPIPE и завершается -> пайплайн закрывается сразу.
	# HTTP: либо отдаём lpac его curl, либо заворачиваем ES9+ в тот же stdio-поток
	# к мосту (бэкенды различаются полем "type", поток один).
	if [ "$(http_backend)" = "bridge" ]; then
		_CA=$(ca_bundle); _HTTPDRV="stdio"
	else
		_CA=""; _HTTPDRV="curl"
	fi
	# curl-драйвера в сборке может не быть вовсе - тогда lpac упал бы с «No HTTP
	# driver found» уже на старте. Уходим на мост вместе с CA-бандлом.
	if [ "$_HTTPDRV" = curl ] && [ "$(http_local_drv)" != curl ]; then
		_HTTPDRV="stdio"; _CA=$(ca_bundle)
	fi
	# APDU: нативный AT-драйвер (tty напрямую) ЛИБО stdio-мост. В обоих случаях мост
	# в пайплайне остаётся - он ловит HTTP (если stdio) и ЗАХВАТЫВАЕТ progress/lpa в
	# $_RES. При APDU=at мост НЕ трогает tty (его apdu-ветка не срабатывает), так что
	# конфликта с нативным драйвером за порт нет. $PORT без пробелов (путь к tty).
	case "$_BE" in
		at)   _APDU_ENV="LPAC_APDU=at LPAC_APDU_AT_DEVICE=$PORT" ;;
		# qmi/uqmi берут cdc-wdm через qmi-proxy (делят канал с data-сессией);
		# mbim - через mbim-proxy (LPAC_APDU_MBIM_USE_PROXY=1). Устройство - esim_wdm.
		qmi)  _APDU_ENV="LPAC_APDU=qmi LPAC_APDU_QMI_DEVICE=$(esim_wdm)" ;;
		uqmi) _APDU_ENV="LPAC_APDU=uqmi LPAC_APDU_QMI_DEVICE=$(esim_wdm)" ;;
		mbim) _APDU_ENV="LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE=$(esim_wdm) LPAC_APDU_MBIM_USE_PROXY=1" ;;
		*)    _APDU_ENV="LPAC_APDU=stdio" ;;
	esac
	sh "$BRIDGE" "$PORT" "$_RES" "$_CA" "$LIVELOG" < "$_LOOP" \
		| env $_APDU_ENV LPAC_HTTP="$_HTTPDRV" "$LPAC" "$@" > "$_LOOP" 2>/dev/null &
	_PID=$!
	# Опрос вместо wait+сторож: busybox плохо реапит сабшелл пайплайна через wait
	# (зомби + зависание на 40 c). kill -0 ловит завершение мгновенно. Мост выходит
	# на "lpa", lpac умирает по SIGPIPE -> пайплайн закрывается в ту же секунду.
	_n=0
	while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
	kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null
	# Отпускаем порт СРАЗУ после lpac (результат - чтение файла, порт не нужен).
	# Только если захватывали САМИ (не отбираем лок у предка-опросчика) и только
	# для AT-путей (qmi/mbim замок не берут - см. _locked выше).
	[ "$_locked" = 1 ] && [ -z "$_prelock" ] && at_unlock
	rm -f "$_LOOP"
	if [ -s "$_RES" ]; then cat "$_RES"; else err "timeout"; fi
	rm -f "$_RES"
}

# AT-команда с ограничением по времени (sms_tool сам таймаута не имеет и на
# молчащем порту висит ~35 c). Возвращает ответ без CR.
at_bounded() {
	_ao="/tmp/5gmodem_esim_at.$$"
	sms_tool -d "$1" at "$2" > "$_ao" 2>/dev/null &
	_ap=$!
	# fd отвязаны ОТ ПОДОБОЛОЧКИ: иначе осиротевший `sleep` держит stdout
	# вызывающего, и читатель (rpcd/cgi-io) ждёт EOF лишние ${3:-6} c уже после
	# того, как ответ готов (см. atprobe.sh - там это стоило 1.4 c на опрос).
	( sleep "${3:-6}"; kill "$_ap" 2>/dev/null ) >/dev/null 2>&1 </dev/null & _aw=$!
	wait "$_ap" 2>/dev/null; kill "$_aw" 2>/dev/null; wait "$_aw" 2>/dev/null
	tr -d '\r' < "$_ao"; rm -f "$_ao"
}

# eUICC-порт? БЕЗОПАСНАЯ и БЫСТРАЯ проба через AT+CCHO (открыть логический канал
# к ISD-R). Порт eUICC мгновенно отвечает номером канала - закрываем его (CCHC=N)
# за собой. Остальные AT-порты отвечают ERROR/пусто сразу.
#
# ФОРМАТ ОТВЕТА: стандарт "+CCHO: N", НО FM350-GL отдаёт ГОЛЫЙ номер канала (просто
# "1") без префикса - как и в нашем патче lpac (0002-...bare-CCHO). Принимаем ОБА,
# иначе find_port не распознаёт рабочий eUICC-порт и dump падает с "no eUICC-capable
# AT port", хотя CCHO по факту работает.
#
# ВАЖНО: раньше здесь перебирали порты через "lpac chip info". На FM350 номер
# eUICC-порта плавает при каждой переперечисления USB, а lpac на НЕВЕРНОМ порту
# шлёт CGLA и ВИСНЕТ ~20-40 c, ОСТАВЛЯЯ логический канал открытым. За несколько
# таких проб все каналы ISD-R утекают, и eUICC перестаёт отвечать до аппаратного
# сброса (переподключения модема). CCHO-проба быстрая и мусора не оставляет.
port_ok() {
	_AID=$(uci -q get lpac.global.custom_isd_r_aid 2>/dev/null)
	[ -n "$_AID" ] || _AID="A0000005591010FFFFFFFF8900000100"
	# СНАЧАЛА ЗАКРЫВАЕМ УТЁКШИЕ КАНАЛЫ, потом пробуем открыть свой.
	#
	# Каналов к ISD-R у модема считанные единицы, и если предыдущая операция
	# оставила канал открытым (а так бывает: lpac убит по таймауту, модем
	# переэнумерировался посреди обмена), новый CCHO молча не открывается -
	# проба возвращает пустоту, и мы делаем вывод «eUICC нет».
	#
	# Живой случай: пользователь переключил eSIM-профиль, канал остался
	# открытым, и через полчаса карточка FM350 показывала «eSIM: нет» при
	# работающем eSIM-профиле. Проверено прямо на стенде: до чистки все семь
	# портов молчат, после - CCHO отвечает номером канала.
	#
	# run_lpac делает ровно это перед каждой операцией; проба обязана тоже,
	# иначе она отвечает на вопрос «свободен ли канал», а не «есть ли eUICC».
	# Проба КОРОТКАЯ. Порт с eUICC отвечает практически мгновенно, а модем без
	# неё молчит - и ждать по 6 c на каждом из семи портов значит держать
	# страницу почти минуту (наступал на это: вкладка eSIM висела, пока перебор
	# не закончится). Двух секунд достаточно, чтобы отличить ответ от молчания.
	_R=$(at_bounded "$1" "AT+CCHO=\"$_AID\"" "${2:-2}")
	# формат "+CCHO: N"
	_CH=$(echo "$_R" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
	# либо голый номер канала (FM350): строка ТОЛЬКО из цифр (не эхо "AT+CCHO=...")
	[ -n "$_CH" ] || _CH=$(echo "$_R" | grep -E '^[0-9]+$' | head -1)
	[ -n "$_CH" ] || return 1
	at_bounded "$1" "AT+CCHC=$_CH" 4 >/dev/null   # закрыть канал за собой
	return 0
}

# Живой AT-порт активного модема (дёшево).
#
# ТОЛЬКО ПОРТЫ ЭТОГО МОДЕМА - то же правило, что в find_port ниже. Раньше здесь
# первым стоял detect.sh, и его ответ принимался, как только отвечал на AT. Но
# detect.sh при путанице отдаёт порт ЧУЖОГО модема, и тогда:
#   - at_lock (ниже) брался на порт соседа, а проба шла по нашему - то есть
#     защита от столкновения с опросом метрик просто не работала, давая ложное
#     «eUICC не отвечает»;
#   - проверка «модем на связи» проходила по соседу, и ложное «eUICC нет»
#     попадало в КЭШ как хороший ответ;
#   - AT+SIMTYPE? читался у соседа, и решение «слот eSIM не активен» принималось
#     по чужой SIM.
# Ровно так односимочный SIM7600 однажды получил «eSIM» от стоящего рядом FM350 -
# в find_port это уже учтено, а здесь оставалось незакрытым.
#
# Порядок сохраняем дешёвым: ответ detect.sh пробуем ПЕРВЫМ, но лишь если он
# принадлежит этому модему. Список портов даёт реестр.
live_port() {
	_LPR=$("$RES/registry.sh" active 2>/dev/null)
	_LPT=$(printf '%s' "$_LPR" | jsonfilter -e '@.tty[*]' 2>/dev/null | tr '\n' ' ')
	[ -n "$_LPT" ] || return 1
	_D=$("$RES/detect.sh" 2>/dev/null)
	case " $_LPT " in
		*" $_D "*) _LPT="$_D $_LPT" ;;   # свой и выбранный приложением - вперёд
	esac
	for _t in $_LPT; do
		[ -e "$_t" ] || continue
		"$RES/atprobe.sh" "$_t" >/dev/null 2>&1 && { echo "$_t"; return 0; }
	done
	return 1
}

esim_active() {   # AT+SIMTYPE: 1 = ESIM
	T=$(sms_tool -d "$1" at "AT+SIMTYPE?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
	[ "$T" = "1" ]
}

# Найти eUICC-порт. Быстрый путь: кэш жив и отвечает на AT - доверяем без
# дорогой lpac-пробы. Иначе перебираем tty модема с пробой chip info.
# Закрыть утёкшие логические каналы к ISD-R.
#
# Каналов у модема считанные единицы, и если предыдущая операция оставила канал
# открытым (lpac убит по таймауту, модем переэнумерировался посреди обмена),
# новый CCHO молча не открывается - проба отвечает «eUICC нет».
#
# Зовём ОДИН РАЗ на весь перебор портов, а не на каждый порт: восемь команд по
# 2 c на каждом из семи портов - это больше минуты, и именно так я однажды
# подвесил страницу настроек.
free_channels() {   # $1 - порт
	for _fc in 1 2 3 4 5 6 7 8; do at_bounded "$1" "AT+CCHC=$_fc" 2 >/dev/null; done
}

find_port() {
	# Проверяем кэш CCHO-пробой (а не только atprobe): номер eUICC-порта на FM350
	# плавает при переперечислении, и AT-живой, но НЕ-eUICC порт повесил бы lpac.
	C=$(cat "$PORTCACHE" 2>/dev/null)
	if [ -n "$C" ] && [ -e "$C" ] && port_ok "$C"; then
		echo "$C"; return 0
	fi
	rm -f "$PORTCACHE"
	P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	# ТОЛЬКО ПОРТЫ ЭТОГО МОДЕМА. detect.sh при путанице отдаёт порт чужого
	# модема, а CCHO на нём откроет eUICC соседа - ровно так односимочный
	# SIM7600 получал «eSIM» от стоящего рядом FM350. Берём tty строго по
	# USB-пути активного модема; detect.sh добавляем, лишь если он этому пути
	# и принадлежит.
	if [ -n "$P" ]; then
		CANDS=$("$RES/listmodems.sh" 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null)
	else
		# Путь неизвестен (старый одномодемный конфиг) - поведение прежнее.
		CANDS=$("$RES/detect.sh" 2>/dev/null)
	fi
	SEEN=""; ALIVE=""
	for t in $CANDS; do
		case " $SEEN " in *" $t "*) continue;; esac
		SEEN="$SEEN $t"
		[ -e "$t" ] || continue
		"$RES/atprobe.sh" "$t" >/dev/null 2>&1 || continue
		ALIVE="$ALIVE $t"
		if port_ok "$t"; then
			echo "$t" > "$PORTCACHE"; echo "$t"; return 0
		fi
	done
	# БЫСТРЫЙ ПРОХОД НИЧЕГО НЕ ДАЛ. Возможная причина - утёкший канал: тогда
	# CCHO не открывается ни на одном порту, хотя eUICC есть. Чистим каналы и
	# пробуем ЕЩЁ РАЗ, с большим терпением - но только теперь, один раз, а не
	# на каждом порту в первом проходе.
	for t in $ALIVE; do
		free_channels "$t"
		if port_ok "$t" 6; then
			echo "$t" > "$PORTCACHE"; echo "$t"; return 0
		fi
	done
	return 1
}

# Операция lpac с авто-переоткрытием порта: при неуспехе (напр. кэш устарел
# после переперечисления) сбрасываем кэш, ищем порт заново и повторяем один раз.
do_lpac() {
	_T="$1"; shift
	R=$(run_lpac "$_T" "$@")
	if ! echo "$R" | grep -q '"code":0'; then
		# Ретрай зависит от бэкенда: AT/bridge держатся за конкретный tty -> сбрасываем
		# кэш и ищем порт заново. qmi/uqmi/mbim ходят по cdc-wdm и PORT игнорируют, а
		# find_port гоняет CCHO-пробы по AT-портам (лишнее и может задеть модем) - для
		# них просто повторяем ту же операцию по cdc-wdm.
		case "$(apdu_backend)" in
			at|bridge)
				rm -f "$PORTCACHE"
				PORT=$(find_port)
				[ -n "$PORT" ] && R=$(run_lpac "$_T" "$@") ;;
			*)
				R=$(run_lpac "$_T" "$@") ;;
		esac
	fi
	echo "$R"
}

# ---- дешёвый статус: без lpac и без замка -----------------------------------
case "$1" in
# progress ДО блокировки: это чтение файла, порт не трогает. Под блокировкой
# он возвращал бы "busy" во время самой операции - то есть ровно тогда, когда
# прогресс и нужен, а UI затирал бы этим ответом накопленный лог.
reapply)
	# Переподнять интерфейс модема ПОСЛЕ смены профиля. Без этого netifd держит
	# аренду и маршрут от СТАРОГО профиля: интерфейс остаётся up со старым IP,
	# система считает себя подключённой, а данные не идут (наблюдалось вживую -
	# uptime 6300 c и адрес прошлого оператора при уже другой карте).
	#
	# Ждём ГОТОВНОСТИ модема, а не спим фиксированно: после жёсткого ребута он
	# переэнумерируется на USB 30-60 c, и ifup по мёртвому порту словил бы гонку.
	# Признак готовности - tty снова отвечает на AT (atprobe).
	#
	# Всё в фоне с ОТВЯЗКОЙ дескрипторов ИМЕННО НА ПОДОБОЛОЧКЕ: иначе rpcd ждёт
	# EOF и упирается в 30-секундный таймаут ("XHR error").
	(
		# Имя интерфейса ищем в трёх местах: глобальная секция бывает пустой, а
		# фактическое значение лежит в секции КОНКРЕТНОГО модема (имя секции -
		# это его USB-путь, где всё, кроме букв и цифр, заменено на "_":
		# 2-1.4 -> m_2_1_4). Последний рубеж - интерфейс с нашим прото.
		_IF=$(uci -q get 5gmodem.@5gmodem[0].network)
		if [ -z "$_IF" ]; then
			_AM=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null \
				| tr -c 'A-Za-z0-9' '_')
			[ -n "$_AM" ] && _IF=$(uci -q get "5gmodem.m_${_AM%_}.network" 2>/dev/null)
		fi
		if [ -z "$_IF" ]; then
			_PR=$(uci -q get 5gmodem.@5gmodem[0].iface_proto 2>/dev/null)
			[ -n "$_PR" ] && _IF=$(uci -q show network 2>/dev/null \
				| sed -n "s/^network\.\([^.]*\)\.proto='$_PR'$/\1/p" | head -1)
		fi
		[ -n "$_IF" ] || exit 0
		_n=0
		while [ "$_n" -lt 60 ]; do
			sleep 2; _n=$((_n + 1))
			_D=$("$RES/detect.sh" 2>/dev/null)
			[ -n "$_D" ] || continue
			"$RES/atprobe.sh" "$_D" >/dev/null 2>&1 && break
		done
		# модем ответил - передоговариваемся с сетью на новом профиле
		ifdown "$_IF" 2>/dev/null
		sleep 3
		ifup "$_IF" 2>/dev/null
	) >/dev/null 2>&1 </dev/null &
	echo '{"type":"lpa","payload":{"code":0,"message":"reapply","data":""}}'
	exit 0
	;;
progress)
	# progress reset - обнулить лог ПЕРЕД стартом. Без явного сброса UI успевает
	# прочитать лог прошлого запуска раньше, чем его обнулит ветка download, и
	# показывает пользователю чужие шаги целиком.
	if [ "$2" = "reset" ]; then : > "$LIVELOG"; echo "{}"; exit 0; fi
	[ -f "$LIVELOG" ] && cat "$LIVELOG"
	exit 0
	;;
download-bg)
	# ФОНОВАЯ ЗАГРУЗКА: снимаем 60-секундный потолок uhttpd (cgi-exec). Медленный
	# eUICC FM350 отвечает на крипто-команды (финальный Store Data) по многу секунд,
	# и синхронный download резался на 60 c -> попап «?». Запускаем реальный
	# `download` ОТДЕЛЁННЫМ воркером (fd отвязаны, чтобы cgi-io не ждал EOF и вернулся
	# сразу), итог (многострочный O) пишем в файл; фронт опрашивает download-status.
	# Так же поступает EasyLPAC: cmd.Run() без таймаута ждёт медленный eUICC.
	[ -n "$2" ] || { echo '{"started":0,"error":"no code"}'; exit 0; }
	_DLRES="/tmp/5gmodem_esim_dlresult"
	if [ -f "$_DLRES.running" ]; then
		_wp=$(cat "$_DLRES.running" 2>/dev/null)
		[ -n "$_wp" ] && [ -d "/proc/$_wp" ] && { echo '{"started":0,"busy":1}'; exit 0; }
	fi
	rm -f "$_DLRES" "$_DLRES.tmp" "$_DLRES.running"
	# Воркер: esim.sh download (берёт замок eUICC, делает всё, echo O). fd отвязаны.
	(
		"$0" download "$2" > "$_DLRES.tmp" 2>/dev/null
		mv "$_DLRES.tmp" "$_DLRES"
		rm -f "$_DLRES.running"
	) >/dev/null 2>&1 </dev/null &
	echo "$!" > "$_DLRES.running"
	echo '{"started":1}'
	exit 0
	;;
download-status)
	# Идемпотентно: идёт -> {"dlstate":"running"}; готово -> отдаём итог O (многостроч-
	# ный, НЕ удаляем - почистит следующий download-bg); нет ничего -> {"dlstate":"idle"};
	# воркер умер без итога -> lpa-ошибка.
	_DLRES="/tmp/5gmodem_esim_dlresult"
	[ -f "$_DLRES" ] && { cat "$_DLRES"; exit 0; }
	if [ -f "$_DLRES.running" ]; then
		_wp=$(cat "$_DLRES.running" 2>/dev/null)
		[ -n "$_wp" ] && [ -d "/proc/$_wp" ] && { echo '{"dlstate":"running"}'; exit 0; }
		rm -f "$_DLRES.running"
		echo '{"type":"lpa","payload":{"code":-1,"message":"download worker exited without result","data":""}}'
		exit 0
	fi
	echo '{"dlstate":"idle"}'
	exit 0
	;;
setshow)
	# Записать галку «вкладка eSIM» НАДЁЖНО, из бэкенда. Раньше вьюха писала её
	# через uci.add именованной секции в кэше формы, и на модеме, чьей секции
	# m_<путь> ещё не было, запись не приживалась - «не сохранялось, пока не
	# пересоздал интерфейс». Здесь секцию гарантированно заводим и коммитим.
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] || exit 0
	_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q get "5gmodem.$_sec" >/dev/null 2>&1 || {
		uci -q set "5gmodem.$_sec=modem"
		uci -q set "5gmodem.$_sec.path=$_AP"
	}
	case "$2" in
		0|1) uci -q set "5gmodem.$_sec.esim_show=$2" ;;
		*)   uci -q delete "5gmodem.$_sec.esim_show" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	# Кэш статуса протух - при возврате в «авто» надо переспросить.
	rm -f "/tmp/5gmodem_esimstat_$_AP" 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
sethttp)
	# Транспорт ES9+ (esim_http) НАДЁЖНО, из бэкенда: запись из формы через
	# uci.save()+uci.apply() дельту не коммитила (изменение висело в «Настройки/
	# Изменения»). Тот же приём, что и setshow - set + commit прямо здесь.
	case "$2" in
		auto|curl|bridge) uci -q set "5gmodem.@5gmodem[0].esim_http=$2" ;;
		*)                uci -q delete "5gmodem.@5gmodem[0].esim_http" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	echo '{"result":"ok"}'
	exit 0
	;;
setapdu)
	# Транспорт APDU к eUICC (esim_apdu) - тем же приёмом, что sethttp. "auto" и
	# всё неизвестное -> удаляем ключ (вернуться к автоопределению по прото). Смена
	# инвалидирует кэш вердикта eUICC (пробовали другим транспортом).
	case "$2" in
		at|qmi|uqmi|mbim|bridge) uci -q set "5gmodem.@5gmodem[0].esim_apdu=$2" ;;
		*)                       uci -q delete "5gmodem.@5gmodem[0].esim_apdu" 2>/dev/null ;;
	esac
	uci -q commit 5gmodem
	rm -f /tmp/5gmodem_esimstat_* 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
# ЧЕМ lpac ХОДИТ В СЕТЬ - для отчёта диагностики.
#
# Раньше отчёт проверял это сам, одной строкой: strings /usr/lib/lpac | grep curl.
# Проверка врала дважды. Во-первых, у патченой раскладки /usr/lib/lpac - КАТАЛОГ
# (бинарь лежит внутри), strings по каталогу молчит, и исправная установка
# получала вердикт «curl: НЕТ -> lpac не сможет скачать профиль» (живой отчёт
# WH3000, 02.08.2026, сразу после верной переустановки). Во-вторых, при драйвере
# stdio запросы делает САМ РОУТЕР, и curl внутри lpac не нужен вовсе - пугать им
# там нечего. Знание о выборе драйвера живёт в http_local_drv, поэтому спрашиваем
# её, а не гадаем со стороны.
httpinfo)
	_hi=$(http_local_drv)
	printf 'драйвер HTTP: %s\n' "$_hi"
	if [ "$_hi" = stdio ]; then
		echo 'запросы к серверу профилей делает роутер (stdio) - curl внутри lpac НЕ нужен'
		exit 0
	fi
	if [ -f /usr/lib/lpac/driver/driver_http_curl.so ]; then
		if ldd /usr/lib/lpac/driver/driver_http_curl.so 2>/dev/null | grep -q "not found"; then
			echo 'ПРОБЛЕМА: плагину curl не хватает библиотек:'
			ldd /usr/lib/lpac/driver/driver_http_curl.so 2>/dev/null | grep "not found" | sed 's/^/  /'
		else
			echo 'плагин curl на месте, библиотеки разрешаются'
		fi
	elif [ -f "$LPAC" ] && strings "$LPAC" 2>/dev/null | grep -qi curl_easy_perform; then
		echo 'curl вшит в бинарь (раскладка 2.1.x без плагинов)'
	else
		echo 'ПРОБЛЕМА: драйвер curl выбран, но ни плагина, ни curl в бинаре не видно'
	fi
	exit 0
	;;
apduinfo)
	# ЧЕМ ИМЕННО МЫ ХОДИМ К eUICC - для отчёта диагностики.
	#
	# Без этого разбор «eSIM не читается» упирался в стену: наружу видно только
	# code -1 "euicc_init", а какой транспорт выбран, ручной он или авто и на
	# каком драйвере сидит узел - не видно ни из чего. Живой случай (два T99W175,
	# 30.07): авто-выбор дал mbim на узле qmi_wwan, и eSIM молчала «по-честному».
	printf 'выбранный APDU-бэкенд: %s\n' "$(apdu_backend)"
	printf 'задан вручную (esim_apdu): %s\n' "$(uci -q get 5gmodem.@5gmodem[0].esim_apdu || echo '(нет, автоопределение)')"
	# Пустые значения подписываем словами: в отчёте пустая строка после двоеточия
	# читается как обрыв вывода, а не как «узла нет» - а это разные диагнозы.
	_ai_wdm=$(esim_wdm)
	_ai_drv=$(_wdm_driver)
	printf 'узел cdc-wdm: %s\n' "${_ai_wdm:-(нет - у этого модема канала управления нет)}"
	printf 'драйвер узла: %s\n' "${_ai_drv:-(не определён)}"
	printf 'прото интерфейса: %s\n' "$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto")"
	printf 'HTTP-драйвер lpac: %s\n' "$(http_local_drv 2>/dev/null || echo '(не определён)')"
	exit 0
	;;
recheck)
	# ПЕРЕПРОВЕРИТЬ НАЛИЧИЕ eUICC ЗАНОВО. Отрицательный ответ кэшируется (перебор
	# портов стоит секунд), и без этой команды выйти из него нельзя: модем,
	# который при первой пробе молчал, навсегда остался бы «без eSIM».
	# Снимаем и кэш статуса, и кэш eUICC-порта - второй мог указывать на порт,
	# исчезнувший при переперечислении.
	rm -f "/tmp/5gmodem_esimstat_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" \
	      "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" \
	      "$PORTCACHE" 2>/dev/null
	exec "$0" status-probe
	;;
dump-cached)
	# Последний УДАЧНЫЙ дамп eUICC (chip + список профилей) МГНОВЕННО, без
	# порта и замков: вкладка показывает список сразу при возврате, живой
	# dump освежает его следом. Кэш пишет сам dump (только валидный результат)
	# и стирают операции (enable/disable/delete/download) и recheck.
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] && [ -s "/tmp/5gmodem_esimdump_$_AP" ] && { cat "/tmp/5gmodem_esimdump_$_AP"; exit 0; }
	echo '{}'
	exit 0
	;;
status)
	# ВИДИМОСТЬ ВКЛАДКИ eSIM - СТАТИЧЕСКИ, ПО vid:pid, БЕЗ ОБРАЩЕНИЯ К ПОРТУ.
	#
	# Раньше здесь была CCHO-проба eUICC: она брала at_lock и голодила опрос
	# метрик, а зовётся видимость на КАЖДОЙ загрузке И при переключении модемов -
	# отсюда «дикие тормоза» и прочерки на новой вкладке. Проба нужна для РАБОТЫ
	# с eUICC (dump/enable - там мы реально говорим с чипом), но НЕ для того,
	# чтобы просто показать вкладку.
	#
	# Логика (по решению владельца): модем на шине и его vid:pid есть в списке
	# потенциально-eSIM -> вкладку показываем; модема нет -> прячем; ручная
	# галка (esim_show) перебивает. Реальную работу с eUICC (есть ли профили,
	# активен ли слот) выясняет сама страница eSIM при открытии.
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_AP" ] || { echo '{"available":0,"active":0}'; exit 0; }
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"

	# Ручное переопределение (галка в настройках модема) - высший приоритет.
	_ES_FORCE=$(uci -q get "5gmodem.$_es_sec.esim_show")
	[ "$_ES_FORCE" = "0" ] && { echo '{"available":0,"active":0,"forced":1}'; exit 0; }
	[ "$_ES_FORCE" = "1" ] && { echo '{"available":1,"active":0,"forced":1}'; exit 0; }

	# lpac не установлен - работать с eSIM всё равно нечем, вкладку не показываем.
	# А вот испорченную установку показываем: молчаливое «eSIM нет» отправляло
	# искать причину в модеме, хотя чинить надо пакет (см. LPAC_BROKEN выше).
	[ -n "$LPAC_BROKEN" ] && { echo '{"available":0,"active":0,"broken":1}'; exit 0; }
	[ -x "$LPAC" ] || { echo '{"available":0,"active":0}'; exit 0; }

	_vp=$(uci -q get "5gmodem.$_es_sec.vidpid")
	[ -n "$_vp" ] || _vp=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_AP\"].vidpid" 2>/dev/null | head -1)
	for _cap in $ESIM_CAPABLE_VIDPIDS; do
		[ "$_vp" = "$_cap" ] && { echo '{"available":1,"active":0}'; exit 0; }
	done
	# МОДЕЛЬ, У КОТОРОЙ «eSIM» НАПИСАНО ПРЯМО В ИМЕНИ. Списка vid:pid мало: у
	# Dell DW5821e-eSIM (0489:e0b5) вкладка не показывалась, хотя eUICC у него
	# распаян - буквально в названии. Общий признак закрывает и будущие модели
	# без правки списка. Вариант без eSIM у того же vid:pid ярлыка в имени не
	# несёт - ложных показов не даёт.
	_prod=$("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$_AP\"].product" 2>/dev/null | head -1)
	case "$_prod" in
		*eSIM*|*ESIM*) echo '{"available":1,"active":0}'; exit 0 ;;
	esac
	echo '{"available":0,"active":0}'
	exit 0
	;;
status-cached)
	# МГНОВЕННЫЙ ответ для открытия вкладки eSIM: последний ХОРОШИЙ вердикт
	# CCHO-пробы (кэш status-probe, ключ - USB-путь модема), ни порта, ни
	# замков. Кэша нет - честно отвечаем unknown: страница покажет каркас
	# сразу и запустит настоящую пробу ФОНОМ, а не заставит пользователя
	# смотреть на пустой экран со спиннером (наблюдалось на FM350: load()
	# блокировался на status-probe секундами).
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	# Приоритеты как у status: ручная галка перебивает, без lpac делать нечего.
	_ES_FORCE=$(uci -q get "5gmodem.$_es_sec.esim_show")
	[ "$_ES_FORCE" = "0" ] && { echo '{"available":0,"active":0,"forced":1}'; exit 0; }
	[ -x "$LPAC" ] || { echo '{"available":0,"active":0,"reason":"nolpac"}'; exit 0; }
	_SCACHE="/tmp/5gmodem_esimstat_$_AP"
	[ -s "$_SCACHE" ] && { cat "$_SCACHE"; exit 0; }
	echo '{"unknown":1}'
	exit 0
	;;
status-probe)
	AVAIL=0; ACTIVE=0
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	_SCACHE="/tmp/5gmodem_esimstat_$_AP"
	if [ -x "$LPAC" ]; then
		_NET=$(uci -q show 5gmodem 2>/dev/null | sed -n \
			"s/^5gmodem\.\(m_[^.]*\)\.path='$_AP'\$/\1/p" | head -1)
		_PROTO=$(uci -q get "network.$(uci -q get "5gmodem.$_NET.network").proto")
		_BE=$(apdu_backend)
		case "$_BE" in
		qmi|uqmi|mbim)
			# Модем под MM - канал занят, проба ЗАПРЕЩЕНА (см. _mm_owns_channel:
			# на T99W175 второй хозяин канала ронял модем в ребут). Ответ не
			# кэшируем: состояние меняется галкой mm_exclude.
			if _mm_owns_channel; then
				echo '{"available":0,"active":0,"reason":"mm_owns"}'
				exit 0
			fi
			# Qualcomm SDX55 (T99W175/MV31-W/DW5930e) и прочие cdc-wdm-модемы: eUICC
			# достаётся по QMI/MBIM, а не по AT+CCHO. Пробуем lpac chip info по cdc-wdm.
			if euicc_probe_wdm "$_BE"; then
				AVAIL=1; ACTIVE=1
				printf '{"available":1,"active":1}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			else
				printf '{"available":0,"active":0,"reason":"noeuicc"}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			fi
			;;
		*)
		if [ "$_PROTO" != "modemmanager" ]; then
			# НАЛИЧИЕ AT-ПОРТА - НЕ ПРИЗНАК eSIM. Здесь стоял live_port, и
			# AVAIL=1 выставлялся просто потому, что модем отвечает на AT и в
			# системе лежит lpac: вкладка eSIM показывалась КАЖДОМУ модему,
			# включая Telit LM960 без eUICC. Спрашиваем сам eUICC - find_port
			# перебирает порты модема пробой CCHO (открытие канала к ISD-R):
			# канал открылся - eUICC есть, не открылся - её нет.
			# Блокировку берём НА ВРЕМЯ ПРОБЫ: find_port перебирает порты
			# командой CCHO, и столкновение с опросом метрик даёт ложное
			# «eUICC не отвечает».
			at_lock "$(live_port 2>/dev/null)" 10; _es_locked=$?
			D=$(find_port)
			if [ -n "$D" ]; then
				AVAIL=1
				esim_active "$D" && ACTIVE=1
				# запомнить ХОРОШИЙ ответ (ключ - стабильный USB-путь модема)
				printf '{"available":%s,"active":%s}\n' "$AVAIL" "$ACTIVE" > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif live_port >/dev/null 2>&1 && [ "$_es_locked" = 0 ]; then
				# Модем НА СВЯЗИ, проба прошла ПОД БЛОКИРОВКОЙ (порт был наш), а
				# eUICC не открылась - значит её нет. Только теперь запоминаем
				# отрицательный ответ надолго.
				#
				# ЕСЛИ БЛОКИРОВКУ ВЗЯТЬ НЕ УДАЛОСЬ ($_es_locked != 0) - проба шла
				# по занятому порту и могла соврать. Живой случай (чужой FM350):
				# eUICC есть, но при загрузке порт был занят опросом, проба
				# сорвалась, и вкладка eSIM пропадала на 15 минут. Такой ответ НЕ
				# кэшируем - перепроверим на следующем заходе.
				printf '{"available":0,"active":0,"reason":"noeuicc"}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif [ -s "$_SCACHE" ]; then
				# Порт не ответил: он общий с метриками и simslot.sh, коллизии
				# неизбежны, а модем мог ещё и переперечисляться. Раньше отсюда
				# уходил available=0, и вкладка eSIM ПРОПАДАЛА при живом eUICC -
				# при том что кнопки слотов рядом оставались (у них свой опрос).
				# Отдаём последний валидный ответ вместо ложного «eSIM нет».
				cat "$_SCACHE"; exit 0
			fi
		fi
			;;
		esac
	fi
	# Причина недоступности - чтобы вкладка сказала КОНКРЕТНО, а не «lpac нет ИЛИ
	# не АТ-модем». Порядок проверок = цена: сперва нет lpac, потом прото под
	# ModemManager (наш AT-путь к eUICC недоступен), иначе eUICC не отозвалась
	# (нет порта / чужая композиция / нет чипа) - тут нужен лог от пользователя.
	if [ "$AVAIL" = 0 ]; then
		if [ ! -x "$LPAC" ]; then REASON=nolpac
		elif [ "$_BE" = at ] && [ "$_PROTO" = modemmanager ]; then REASON=modemmanager
		else REASON=noeuicc; fi
		echo "{\"available\":0,\"active\":$ACTIVE,\"reason\":\"$REASON\"}"
	else
		echo "{\"available\":$AVAIL,\"active\":$ACTIVE}"
	fi
	exit 0
	;;
esac

[ -n "$LPAC_BROKEN" ] && { err "$LPAC_BROKEN"; exit 0; }
[ -x "$LPAC" ] || { err "lpac not installed"; exit 0; }

# ---- всё остальное: под замком (у eUICC один логический канал) ---------------
LOCK="/tmp/5gmodem_esim.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
	# ЗАМОК-СИРОТА. Страницу закрыли/перезагрузили посреди операции - процесс
	# умер, а каталог остался, и до 6 минут ВСЁ отвечало busy («eUICC не
	# отвечает» у пользователя). Пишем PID владельца в замок: владелец жив -
	# честный busy; мёртв - забираем замок сразу. Замок без pid-файла (от
	# прежней версии) чистим по старому правилу 6 минут.
	_lp=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$_lp" ] && [ -d "/proc/$_lp" ]; then
		err "busy"; exit 0
	fi
	if [ -z "$_lp" ] && [ -z "$(find "$LOCK" -mmin +6 2>/dev/null)" ]; then
		err "busy"; exit 0
	fi
	rm -rf "$LOCK" 2>/dev/null
	mkdir "$LOCK" 2>/dev/null || { err "busy"; exit 0; }
fi
echo "$$" > "$LOCK/pid" 2>/dev/null
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP

# МОДЕМ ПОД MM: к eUICC не ходим вообще - ни по tty, ни по cdc-wdm (см.
# _mm_owns_channel; на T99W175 это роняло модем). Все чиповые вербы ниже
# получают честную ошибку вместо гонки за чужой канал.
if wdm_backend && _mm_owns_channel; then
	err "mm_owns"
	exit 0
fi

# AT-only преамбул: для бэкендов по cdc-wdm (mbim/qmi/uqmi) eUICC достаётся не по
# tty, порт/esim_active/каналы не нужны (иначе ложное "no AT port"). run_lpac и
# do_lpac сами ходят по cdc-wdm.
if ! wdm_backend; then
	# дешёвая проверка слота, чтобы не сканировать все порты на физической SIM
	D=$(live_port)
	[ -n "$D" ] || { err "no AT port"; exit 0; }
	esim_active "$D" || { err "esim slot not active"; exit 0; }

	# ПЕРЕД поиском порта закрываем ВСЕ возможные УТЕКШИЕ логические каналы ISD-R.
	# Утечка (от прибитого сторожём lpac или прерванной CCHO-пробы) вешает CCHO
	# НАМЕРТВО: find_port не находит eUICC-порт ("no eUICC-capable AT port"), хотя
	# CCHO по факту работает. ПРОВЕРЕНО (FM350): после закрытия всех каналов CCHO
	# снова открывает канал - т.е. клин лечится БЕЗ power-cycle. Каналы общие для
	# eUICC, поэтому чистим на живом AT-порту D до пробы портов.
	for _ch in 1 2 3 4 5 6 7 8 9 10; do at_bounded "$D" "AT+CCHC=$_ch" 2 >/dev/null; done

	PORT=$(find_port)
	[ -n "$PORT" ] || { err "no eUICC-capable AT port"; exit 0; }
fi

flush_notifications() {
	R=$(run_lpac 60 notification process -a -r)
	echo "$R" | grep -q '"code":0' || { rm -f "$PORTCACHE"; }
}

case "$1" in
dump)
	CHIP=$(do_lpac 45 chip info)
	LIST=$(do_lpac 45 profile list)
	_OUT="{\"chip\":$CHIP,\"profiles\":$LIST}"
	# Кэш последнего ХОРОШЕГО дампа - его мгновенно отдаёт dump-cached при
	# возврате на вкладку. Пишем только валидный результат (код профилей 0)
	# и атомарно: полудамп в кэше хуже отсутствия кэша.
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	if [ -n "$_AP" ] && printf '%s' "$_OUT" \
	   | jsonfilter -e '@.profiles.payload.code' 2>/dev/null | grep -qx 0; then
		printf '%s\n' "$_OUT" > "/tmp/5gmodem_esimdump_$_AP.tmp" \
			&& mv "/tmp/5gmodem_esimdump_$_AP.tmp" "/tmp/5gmodem_esimdump_$_AP"
	fi
	echo "$_OUT"
	;;
enable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile enable "$2"); flush_notifications; echo "$O"
	;;
disable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile disable "$2"); flush_notifications; echo "$O"
	;;
delete)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile delete "$2"); flush_notifications; echo "$O"
	;;
nickname)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	do_lpac 45 profile nickname "$2" "$3"
	;;
netcheck)
	# Есть ли у роутера доступ в интернет для загрузки профиля? Загрузка идёт с
	# SM-DP+ оператора по HTTPS, и без сети lpac просто молча висит до таймаута.
	# Проверяем ИМЕННО SM-DP+ из activation code (LPA:1$HOST$ID -> 2-е поле $),
	# а не абстрактный хост: у него может быть доступ, а до SM-DP+ - фаервол.
	# Возврат: {"net":1} - всё ок; {"net":1,"smdp":0} - интернет есть, но SM-DP+
	# не ответил; {"net":0} - интернета нет вовсе.
	_host=$(echo "$2" | awk -F'[$]' '{print $2}')
	if [ -n "$_host" ] && curl -sS -m 15 -o /dev/null "https://$_host/" 2>/dev/null; then
		echo '{"net":1,"smdp":1}'
	elif curl -sS -m 10 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
		# интернет есть; SM-DP+ мог не ответить на GET корня - это не всегда
		# ошибка (часть серверов отвечает только на RSP-эндпоинты), но флажок даём
		[ -n "$_host" ] && echo '{"net":1,"smdp":0}' || echo '{"net":1,"smdp":1}'
	else
		echo '{"net":0}'
	fi
	;;
download)
	[ -n "$2" ] || { err "no activation code"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	: > "$LIVELOG"
	# es9err (тело ES9+-ошибки с кодами GSMA) чистим ОДИН РАЗ до запуска: bridge
	# допишет его при неудаче и НЕ трогает на старте, чтобы ошибка пережила retry
	# внутри do_lpac. Убираем файл прошлой попытки, чтобы не прицепить чужие коды.
	_ERRFILE="/tmp/5gmodem_esim_res.$$.es9err"
	rm -f "$_ERRFILE"
	# Сторож 600 c (не 240): eUICC FM350 медленный на крипто-Store-Data, а фонового
	# режима 60-секундный потолок uhttpd больше не режет (см. download-bg).
	O=$(do_lpac 600 profile download -a "$2")
	# Провал загрузки: SM-DP+ по SGP.22 кладёт коды GSMA в statusCodeData
	# (subjectCode/reasonCode) - bridge сохранил тело в $RESULT.es9err. Достаём
	# коды и вписываем в текст ошибки, чтобы пользователь видел то же, что
	# показывает телефон ("тема X, причина Y: <message>").
	# $O МНОГОСТРОЧНЫЙ (progress-строки + финальная lpa), и progress НЕСЁТ "code":0.
	# Поэтому успех/провал определяем ТОЛЬКО по lpa-строке, а не по всему $O -
	# иначе grep находит code:0 в прогрессе и считает провал успехом.
	_LPALINE=$(printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1)
	if ! printf '%s' "$_LPALINE" | grep -q '"code":0' && [ -s "$_ERRFILE" ]; then
		_SC=$(jsonfilter -i "$_ERRFILE" -e '@.header.functionExecutionStatus.statusCodeData' 2>/dev/null)
		_SUBJ=""; _RC=""; _MSG=""; _EC=""; _SUBJID=""
		if [ -n "$_SC" ]; then
			# v3: subjectCode + reasonCode (+ optional errorCode/message/subjectIdentifier)
			_SUBJ=$(printf '%s' "$_SC" | jsonfilter -e '@.subjectCode' 2>/dev/null)
			_RC=$(printf '%s' "$_SC" | jsonfilter -e '@.reasonCode' 2>/dev/null)
			_MSG=$(printf '%s' "$_SC" | jsonfilter -e '@.message' 2>/dev/null)
			_EC=$(printf '%s' "$_SC" | jsonfilter -e '@.errorCode' 2>/dev/null)
			_SUBJID=$(printf '%s' "$_SC" | jsonfilter -e '@.subjectIdentifier' 2>/dev/null)
		else
			# v2: плоские errorCode + errorDescription
			_EC=$(jsonfilter -i "$_ERRFILE" -e '@.errorCode' 2>/dev/null)
			_MSG=$(jsonfilter -i "$_ERRFILE" -e '@.errorDescription' 2>/dev/null)
		fi
		# Код: предпочитаем subjectCode/reasonCode (v3), иначе errorCode (v2).
		if [ -n "$_SUBJ" ] || [ -n "$_RC" ]; then
			_CODE="${_SUBJ:-?}/${_RC:-?}"
		else
			_CODE="$_EC"
		fi
		# Читаемый хвост из кодов SM-DP+ (авторитетнее строки lpac): "код [объект]: текст",
		# напр. "8.2.6/3.8 Matching ID: Refused" - как коды темы/причины на телефоне.
		_TAIL="$_CODE"
		[ -n "$_SUBJID" ] && _TAIL="${_TAIL:+$_TAIL }$_SUBJID"
		[ -n "$_MSG" ] && _TAIL="${_TAIL:+$_TAIL: }$_MSG"
		if [ -n "$_TAIL" ]; then
			# $O МНОГОСТРОЧНЫЙ: bridge дописывает В RESULT каждую строку прогресса,
			# финальный результат - ПОСЛЕДНЯЯ строка '"type":"lpa"'. Правим ТОЛЬКО её:
			# иначе sed заменит data первой попавшейся progress-строки ("data":"smdp.io"),
			# а UI (parseLpa берёт lpa-строку) покажет неизменённый текст. lpac кладёт в
			# data свой текст ("Refused"/"profile status is error") - оставляем контекстом.
			# Меняем ЗНАЧЕНИЕ data целиком ([^"]* - кавычек в data lpac нет), но по
			# АДРЕСУ lpa-строки. sed-разделитель '|' и спецсимволы (&,\) в кодах/сообщении
			# GSMA не встречаются.
			_LP=$(printf '%s' "$_LPALINE" | jsonfilter -e '@.payload.data' 2>/dev/null)
			_NEW="$_TAIL"
			# lpac нередко кладёт в data ТО ЖЕ сообщение, что уже в _TAIL (message
			# из statusCodeData) - не дублируем ("...pool is empty — ...pool is empty").
			case "$_LP" in
				""|Refused) : ;;
				*) case "$_TAIL" in *"$_LP") : ;; *) _NEW="$_TAIL — $_LP" ;; esac ;;
			esac
			O=$(printf '%s' "$O" | sed '/"type":"lpa"/ s|"data":"[^"]*"|"data":"'"$_NEW"'"|')
		fi
	fi
	rm -f "$_ERRFILE"
	flush_notifications; echo "$O"
	;;
notifications)
	do_lpac 45 notification list
	;;
notif)
	# Управление ОДНОЙ нотификацией (для UI-списка «Уведомления», как в EasyLPAC):
	#   notif process <seq> - дослать на SM-DP+ и убрать локально (-r);
	#   notif remove  <seq> - убрать локально без отправки.
	# Синтаксис lpac: флаг -r ПЕРЕД seq (см. EasyLPAC LpacNotificationProcess).
	case "$2" in
		process) [ -n "$3" ] || { err "no seq"; exit 0; }
			do_lpac 60 notification process -r "$3" ;;
		remove)  [ -n "$3" ] || { err "no seq"; exit 0; }
			do_lpac 30 notification remove "$3" ;;
		*) err "usage: notif process|remove <seq>" ;;
	esac
	;;
flush)
	flush_notifications
	echo '{"type":"lpa","payload":{"code":0,"message":"success","data":""}}'
	;;
*)
	err "usage: esim.sh status|dump|enable|disable|delete|nickname|download|notifications|flush|progress"
	;;
esac
exit 0
