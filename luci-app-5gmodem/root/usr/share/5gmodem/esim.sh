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
ESIM_CAPABLE_VIDPIDS="0e8d:7127 0e8d:7126 2cb7:0104 2cb7:0105 2c7c:0800 2c7c:0801 2c7c:0900 05c6:9025 05c6:90d5 1e2d:00b3 1e2d:00b7 1e2d:00b8 1e2d:00b9"

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
			#
			# УЗЛА НЕТ ВОВСЕ - ВЫБОР ЗАВЕДОМО МЁРТВЫЙ, НЕ УВАЖАЕМ ЕГО.
			# Прежняя сверка ловила только «узел есть, драйвер чужой». А у AT-модема
			# (Fibocom FM350 в fibocom/xmm-композиции) cdc-wdm НЕТ СОВСЕМ: _wdm_driver
			# отдаёт пусто, ветка `*)` возвращала ручной qmi, lpac падал на
			# euicc_init, и вкладка честно писала «eUICC не найден» - при живом
			# eUICC на AT-порту. Живой отчёт 06.08.2026 (FM350-GL, esim_apdu=qmi,
			# cdc-wdm нет, а наша же проба CCHO нашла eUICC на ttyUSB1 и ttyUSB3).
			case "$(_wdm_driver)" in
				*cdc_mbim*) _mbim_or_at ;;
				*qmi_wwan*) echo qmi ;;
				*)
					if [ -z "$(esim_wdm)" ]; then
						logger -t 5gmodem "esim: $_ab selected, but the modem has no cdc-wdm - going over AT via the bridge"
						echo bridge
					else
						echo "$_ab"
					fi ;;
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
				*cdc_mbim*) _mbim_or_at ;;
				*qmi_wwan*) echo qmi ;;
				# Драйвер не определился - решаем по прото, как раньше.
				*) [ "$_abp" = qmi ] && echo qmi || _mbim_or_at ;;
			esac ;;
		# AT-МОДЕМ (cdc-wdm нет вовсе: fibocom/xmm/atc) - ТОЛЬКО ЧЕРЕЗ НАШ МОСТ.
		#
		# Здесь стояло `at` - родной AT-драйвер lpac. Он поехал 25.07 ради быстрой
		# загрузки на медленном eUICC FM350 с патченым lpac 2.3.x, но живые логи
		# 06.08.2026 показали, чем это кончается: `es10b_prepare_download` встаёт
		# РОВНО на 240 c (два захода подряд, секунда в секунду) - у драйвера
		# рассинхронизируется persistent-буфер at_expect на длинной цепочке CGLA,
		# и шаг умирает по его собственному таймеру. Ровно из-за этого мост когда-то
		# и был написан (см. шапку run_lpac).
		#
		# Обратное доказательство прямое: единственная достоверно доведённая до
		# конца загрузка на FM350 (Tele2, 17.07.2026) шла через МОСТ - тогда в
		# коде был безусловный LPAC_APDU=stdio, выбора ещё не существовало.
		#
		# Модемов это касается только AT-класса: у T99W175/MV31-W узел cdc_mbim,
		# и они уходят веткой выше в нативный mbim, который у них и работает.
		# Родной драйвер остаётся доступен вручную: esim_apdu='at'.
		*) echo bridge ;;
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

# --- ВРЕМЕННЫЙ ЗАХВАТ КАНАЛА У MODEMMANAGER (план 16.08.2026, путь A) ---------
#
# Модем под MM (T99W175/MV31-W и родня по MBIM): канал cdc-wdm принадлежит MM,
# и раньше eSIM здесь была закрыта совсем (mm_owns). Теперь на время операций
# канал берётся взаймы: `mmcli --inhibit-device` держится ФОНОВЫМ процессом
# (инхибит жив, пока жив процесс; на kill MM сам пересобирает модем и netifd
# передозванивает). Захват ОДИН на пачку операций: сторож снимает инхибит после
# 90 с без eSIM-обращений - список+включение+обновление идут в одно окно, а не
# по обрыву связи на каждый вызов. Цена захвата - ~1-2 минуты без интернета
# через модем; UI предупреждает и просит явное согласие.
_ESIM_INH_PID=/tmp/5gmodem_esim_mminh.pid
_ESIM_INH_T=/tmp/5gmodem_esim_mminh.t
_mm_inh_held() { [ -f "$_ESIM_INH_PID" ] && kill -0 "$(cat "$_ESIM_INH_PID" 2>/dev/null)" 2>/dev/null; }
_mm_inh_touch() { cut -d. -f1 /proc/uptime > "$_ESIM_INH_T" 2>/dev/null; }
# MM сейчас держит какой-нибудь узел модема (tty/cdc-wdm)? Пока держит - он
# щупает порты, и лезть в канал нельзя; отпустил и модема в списке нет - канал
# фактически свободен.
_mm_busy_on_dev() {
	_mb_pid=$(pidof ModemManager 2>/dev/null | head -1)
	[ -n "$_mb_pid" ] || return 1
	for _mb_f in /proc/"$_mb_pid"/fd/*; do
		case "$(readlink "$_mb_f" 2>/dev/null)" in
			/dev/cdc-wdm*|/dev/ttyUSB*|/dev/ttyACM*) return 0 ;;
		esac
	done
	return 1
}
_mm_esim_take() {
	_mm_inh_held && { _mm_inh_touch; return 0; }
	_ti_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	# MM мог как раз пере-пробить модем (например, сразу после прошлого
	# захвата) - ждём появления индекса, как в band-takeover. НО: если MM
	# модема НЕ собрал и его порты не держит - индекса не будет НИКОГДА
	# (часть прошивок MM не соберёт в принципе: «нет primary AT port»), а
	# канал при этом свободен - работаем без инхибита, не выжидая минуту.
	# Раньше каждый чип-верб ждал тут 60 с под общим замком, и страница
	# крутила busy/mm_owns бесконечно (9eSIM после смены профиля, 17.08.2026).
	_ti_idx=""; _ti_i=0
	while [ "$_ti_i" -lt 20 ]; do
		_ti_idx=$("$RES/modemswitch.sh" mmindex "$_ti_ap" 2>/dev/null)
		[ -n "$_ti_idx" ] && break
		_mm_busy_on_dev || return 0
		sleep 3; _ti_i=$((_ti_i + 1))
	done
	[ -n "$_ti_idx" ] || return 1
	mmcli -m "$_ti_idx" --inhibit-device >/dev/null 2>&1 </dev/null &
	echo $! > "$_ESIM_INH_PID"
	_mm_inh_touch
	# ждём, пока MM реально отпустит устройство (модем пропадает из mmcli)
	_ti_i=0
	while [ "$_ti_i" -lt 15 ]; do
		mmcli -m "$_ti_idx" >/dev/null 2>&1 || break
		sleep 1; _ti_i=$((_ti_i + 1))
	done
	logger -t 5gmodem "esim: channel borrowed from MM (inhibit $_ti_ap) - will return after 90s of eSIM idle"
	# СТОРОЖ-ВОЗВРАЩАТЕЛЬ. Отвязка stdio обязательна (rpcd ждёт EOF).
	(
		while :; do
			sleep 15
			_wd_p=$(cat "$_ESIM_INH_PID" 2>/dev/null)
			{ [ -n "$_wd_p" ] && kill -0 "$_wd_p" 2>/dev/null; } || exit 0
			_wd_now=$(cut -d. -f1 /proc/uptime)
			_wd_t=$(cat "$_ESIM_INH_T" 2>/dev/null || echo 0)
			[ $((_wd_now - _wd_t)) -ge 90 ] || continue
			kill "$_wd_p" 2>/dev/null
			rm -f "$_ESIM_INH_PID" "$_ESIM_INH_T"
			logger -t 5gmodem "esim: inhibit released (idle) - MM is reassembling the modem, the interface will come up on its own"
			exit 0
		done
	) >/dev/null 2>&1 </dev/null &
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
	_ew_lm=$("$RES/listmodems.sh" 2>/dev/null)
	_w=$(printf '%s' "$_ew_lm" | jsonfilter -e "@[@.path=\"$_ap\"].wdm[0]" 2>/dev/null)
	_is_wdm_node "$_w" || _w=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).device")
	_is_wdm_node "$_w" && { echo "$_w"; return; }
	# ЗАПАСНОЙ /dev/cdc-wdm0 - ТОЛЬКО КОГДА ПРО НАШ МОДЕМ НИЧЕГО НЕ ИЗВЕСТНО.
	#
	# Смысл фолбэка был один: listmodems мог сорваться, а узел в системе один -
	# промахнуться не обо что. Но условие «узел один» этого НЕ проверяет: на
	# мультимодеме у модема без своего cdc-wdm (FM350 в RNDIS) единственный узел
	# принадлежит СОСЕДУ, и мы уходили APDU к чужой eUICC, а транспорт выбирали
	# по чужому драйверу. Поймано на стенде 06.08.2026: активен FM350 (`wdm: []`),
	# а функция отдавала /dev/cdc-wdm0 модема EP06 - `apduinfo` показывал
	# `qmi_wwan` там, где своего канала нет вовсе.
	#
	# Теперь: listmodems ОТВЕТИЛ про наш модем и узла у него нет - так и говорим,
	# без подстановок. Фолбэк остаётся ровно для исходного случая - модема в
	# перечислении нет (сорвалось/переэнумерация), и то лишь если единственный
	# узел не числится за другим модемом (числится - он заведомо не наш).
	case "$_ew_lm" in
		*"\"path\":\"$_ap\""*) echo ""; return ;;
	esac
	set -- /dev/cdc-wdm*
	[ "$#" = 1 ] && [ -c "$1" ] || { echo ""; return; }
	case "$_ew_lm" in
		*"\"$1\""*) echo ""; return ;;
	esac
	echo "$1"
}

# УЗЕЛ ПОД KERNEL-ПРОТО mbim (umbim) НЕПРИКАСАЕМ. umbim открывает cdc-wdm
# напрямую и НЕ через прокси; наша mbim-проба поднимает mbim-proxy на тот же
# узел, и прокси отбирает канал - сессия данных рвётся. Живой случай 03.08.2026
# (Cudy TR3000 + DW5821e, proto=mbim): «открываю модуль 5gmodem - отваливается
# инет». qmi НЕ гейтим: QMI мультиплексирует клиентов штатно (наши метрики так
# и живут), а у SDX55 eUICC читается ТОЛЬКО по QMI.
_wdm_owned_by_umbim() {   # $1 - узел /dev/cdc-wdmN
	[ -n "$1" ] || return 1
	for _wo in $(uci show network 2>/dev/null | sed -n "s|^network\.\([^.]*\)\.device='$1'\$|\1|p"); do
		[ "$(uci -q get "network.$_wo.proto")" = "mbim" ] || continue
		# ВЛАДЕЕТ - ЗНАЧИТ ПОДНЯТ. Гейт смотрел ТОЛЬКО на proto, и на опущенном
		# интерфейсе (модем без SIM, ifdown, ещё не дозвонился) запрещал
		# mbim-пробу впустую: узел свободен, umbim не запущен, а eSIM всё равно
		# уводило на AT - и у модемов, где eUICC живёт ТОЛЬКО за QMI/MBIM
		# (Qualcomm SDX55), вкладка отвечала «no eUICC-capable AT port».
		# Живой случай 04.08.2026: Thales MV31-W, proto=mbim, интерфейс down.
		ubus call "network.interface.$_wo" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	done
	return 1
}


# mbim-бэкенд, если узлом не владеет umbim; иначе честный at (мост).
_mbim_or_at() {
	if _wdm_owned_by_umbim "$(esim_wdm)"; then
		# По AT - значит через мост: родной AT-драйвер lpac виснет на длинных
		# цепочках CGLA (см. ветку AT-модема в apdu_backend).
		logger -t 5gmodem "esim: node $(esim_wdm) is owned by umbim (proto=mbim) - mbim probe forbidden, going over AT via the bridge"
		echo bridge
	else
		echo mbim
	fi
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
	# Страховка на случай прямого вызова с бэкендом mbim (мимо apdu_backend).
	if [ "$1" = mbim ] && _wdm_owned_by_umbim "$_pwdev"; then
		logger -t 5gmodem "esim: mbim probe on the umbim node is forbidden (it kills the data session)"
		return 1
	fi
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
			logger -t 5gmodem "esim: mbim probe did not answer, restarting mbim-proxy"
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
	[ -n "$_v" ] && { echo "$_v"; return; }
	# Без явной настройки - АКТИВНЫЙ слот из модема, а не хардкод. Прежний
	# дефолт «2» (исторически «eSIM = слот 2» на MV31-W) отправлял APDU в
	# пустой слот: съёмная 9eSIM живёт в слоте 1, и список профилей честно
	# возвращал «success, пусто» при полностью читаемом чипе - юзер вручную
	# с UIM_SLOT=1 увидел оба профиля (живой кейс 17.08.2026).
	_v=$("$RES/simslot.sh" status 2>/dev/null \
		| jsonfilter -e '@.active' 2>/dev/null)
	case "$_v" in
		''|*[!0-9]*)
			# Слоты сейчас не читаются (канал занят самим lpac/инхибитом или
			# модем пересобирается после смены профиля - наш адресный ресет
			# SDX55). Берём последний УДАЧНЫЙ ответ: переключение ПРОФИЛЯ слот
			# не меняет. Без кэша фолбэк «2» снова целил в пустой слот, и после
			# enable страница вечно крутила «читаю профили», хотя консоль с
			# явным слотом работала (тот же живой кейс, вторая серия).
			_c=""
			[ -z "$(find /tmp/5gmodem_esim_actslot -mmin +60 2>/dev/null)" ] \
				&& _c=$(cat /tmp/5gmodem_esim_actslot 2>/dev/null)
			case "$_c" in ''|*[!0-9]*) echo 2 ;; *) echo "$_c" ;; esac ;;
		*)
			printf '%s' "$_v" > /tmp/5gmodem_esim_actslot 2>/dev/null
			echo "$_v" ;;
	esac
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
	if command -v mbimcli >/dev/null 2>&1; then
		_tie=$(_mbim_target_index) || return 1
		# ТОЧНОЕ СРАВНЕНИЕ, НЕ ПОДСТРОКА. «inactive-esim» СОДЕРЖИТ
		# «active-esim», и grep по подстроке считал НЕАКТИВНЫЙ пустой eUICC
		# активным - защита разрешала lpac слот-маппинг, модем персистентно
		# уезжал на пустой слот, SIM пропадала до ручного AT^switch_slot
		# (живой случай ZBT-Z8102AX + MV31-W, 18.08.2026, «Освободить модем»).
		# Тот же класс, что «connected» в выводе uqmi, матчивший
		# «disconnected» (sessionwatch, июль).
		_tie_st=$(mbimcli -d "$1" -p --ms-query-slot-info-status="$_tie" 2>/dev/null \
			| sed -n 's/.*[Ss]lot state:[^a-zA-Z]*\([a-zA-Z-]*\).*/\1/p' | head -1)
		[ "$_tie_st" = "active-esim" ] && return 0
		return 1
	fi
	# mbimcli В ОБРАЗЕ БЫВАЕТ НЕ ВСЕГДА (пакет umbim/mbim-utils не обязателен).
	# Раньше его отсутствие означало «не активная eSIM» -> политика скатывалась
	# в skip_slot_mapping=1, lpac не мог перемапить executor на eUICC и отвечал
	# «euicc_init: -1». Снаружи это выглядело как «eSIM пропала». Живой случай
	# 04.08.2026: Thales MV31-W на WH3000 Pro - mbimcli не установлен вовсе.
	# Тот же факт достаём по QMI: активен ли слот, помеченный Is eUICC.
	command -v qmicli >/dev/null 2>&1 || return 1
	_tie_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _tie_mb="--device-open-mbim" ;;
	esac
	# Якорь в конце ОБЯЗАТЕЛЕН: «inactive» содержит «active» (см. mbim-ветку).
	qmicli -d "$1" -p $_tie_mb --uim-get-slot-status 2>/dev/null | tr -d '\r' | awk '
		/^ *Physical slot [0-9]+:/          { act = 0; euicc = 0; next }
		/Slot status:[ \t]*active[ \t]*$/   { act = 1 }
		/Is eUICC:[ \t]*yes/                { euicc = 1 }
		act && euicc { found = 1; exit }
		END { exit(found ? 0 : 1) }
	'
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
# ЗАКРЫТЬ ЛОГИЧЕСКИЕ КАНАЛЫ К ISD-R НА cdc-wdm-ПУТИ (аналог AT+CCHC).
#
# Каналов у карты считанные единицы, и открывает их lpac под каждую операцию.
# При ШТАТНОМ завершении он закрывает их сам, а вот убитый по таймауту - нет,
# и утечка копится: через несколько прерванных попыток eUICC начинает отвечать
# «no channel response received: SelectFailed» вообще на всё, и лечится это
# только перезагрузкой модема (power-cycle слота этот модуль не поддерживает -
# QMI отвечает 'NotSupported'). Живой случай 04.08.2026 на Thales MV31-W: два
# ребута подряд, чтобы вернуть eSIM к жизни.
# Для AT-пути ту же работу делает free_channels (AT+CCHC=N), а здесь каналы
# закрываем по QMI - он есть и на MBIM-устройстве (через --device-open-mbim).
_wdm_free_channels() {   # $1 - узел cdc-wdm, $2 - номер слота (1..N)
	command -v qmicli >/dev/null 2>&1 || return 0
	[ -n "$1" ] && [ -e "$1" ] || return 0
	case "$2" in ''|*[!0-9]*) return 0 ;; esac
	_fcmb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _fcmb="--device-open-mbim" ;;
	esac
	for _fc in 1 2 3 4; do
		qmicli -d "$1" -p $_fcmb --uim-close-logical-channel="$2,$_fc" >/dev/null 2>&1
	done
}

# ЧЕРЕЗ mbim-proxy ИЛИ НАПРЯМУЮ?
#
# Прокси нужен, когда канал cdc-wdm делится с кем-то ещё (ModemManager или
# поднятый mbim-интерфейс): без него lpac и сосед подрались бы за устройство.
# Но сам прокси бывает МЁРТВЫМ - после ребута модема (AT+CFUN=1,1) он остаётся
# со старыми дескрипторами, и ЛЮБОЙ запрос через него виснет: «couldn't open
# the QmiDevice: Transaction timed out», а прямой заход работает. Живой случай
# 04.08.2026 (Thales MV31-W): eSIM отвечала «euicc_init: -1», хотя чип цел -
# lpac ходил через сломанный прокси.
# Поэтому: канал занят -> прокси обязателен; свободен -> проверяем прокси
# дешёвым запросом и при отказе идём напрямую. Результат кэшируем на 2 минуты,
# чтобы не платить пробой за каждую операцию.
_mbim_use_proxy() {   # $1 - узел cdc-wdm
	pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1 && { echo 1; return; }
	_upi=$(uci -q get 5gmodem.@5gmodem[0].network)
	if [ -n "$_upi" ] && ubus call "network.interface.$_upi" status 2>/dev/null \
		| grep -q '"up": true'; then
		echo 1; return
	fi
	_upc="/tmp/5gmodem_esim_proxyok"
	if [ -s "$_upc" ] && [ -z "$(find "$_upc" -mmin +2 2>/dev/null)" ]; then
		cat "$_upc"; return
	fi
	_upmb=""
	case "$(readlink -f "/sys/class/usbmisc/${1##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _upmb="--device-open-mbim" ;;
	esac
	if qmicli -d "$1" -p $_upmb --uim-get-slot-status >/dev/null 2>&1; then
		echo 1 > "$_upc"
	else
		logger -t 5gmodem "esim: mbim-proxy not responding - talking to $1 directly (the channel is free)"
		echo 0 > "$_upc"
	fi
	cat "$_upc"
}


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
		_MHTTP=$(http_local_drv)
		_MR="/tmp/5gmodem_esim_res.$$"; rm -f "$_MR"
		if [ "$_MHTTP" = "stdio" ]; then
			# HTTP=stdio ЗНАЧИТ «ES9+ делает внешний мост через stdin/stdout».
			# Здесь lpac запускался НАПРЯМУЮ, без моста: локальным операциям
			# (chip info, список профилей) сеть не нужна, и они работали, а вот
			# ЗАГРУЗКА ПРОФИЛЯ упиралась насмерть - lpac писал запрос
			# {"type":"http",...} в stdout, отвечать было некому, и всё кончалось
			# «HTTP transport failed»; лог прогресса при этом оставался ПУСТЫМ,
			# потому что его ведёт как раз мост. Живой случай 04.08.2026: Thales
			# MV31-W, тестовый профиль LPA:1$rsp.truphone.com$QRF-SPEEDTEST.
			# Ставим мост в пайплайн - APDU по-прежнему нативный mbim (его ветка
			# в мосте не срабатывает), мост обслуживает только HTTP и пишет
			# прогресс/итог.
			_MLOOP="/tmp/5gmodem_esim_mloop.$$"
			rm -f "$_MLOOP"; mkfifo "$_MLOOP" 2>/dev/null
			sh "$BRIDGE" /dev/null "$_MR" "$(ca_bundle)" "$LIVELOG" < "$_MLOOP" \
				| env LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE="$_MDEV" \
					LPAC_APDU_MBIM_UIM_SLOT="$(_mbim_uim_slot)" LPAC_APDU_MBIM_USE_PROXY="$(_mbim_use_proxy "$_MDEV")" \
					LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="$_MSKIP" LPAC_HTTP=stdio \
					"$LPAC" "$@" > "$_MLOOP" 2>/dev/null &
		else
			env LPAC_APDU=mbim LPAC_APDU_MBIM_DEVICE="$_MDEV" \
				LPAC_APDU_MBIM_UIM_SLOT="$(_mbim_uim_slot)" LPAC_APDU_MBIM_USE_PROXY="$(_mbim_use_proxy "$_MDEV")" \
				LPAC_APDU_MBIM_SKIP_SLOT_MAPPING="$_MSKIP" LPAC_HTTP="$_MHTTP" \
				"$LPAC" "$@" > "$_MR" 2>/dev/null &
		fi
		_PID=$!; _n=0
		while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
		# СНАЧАЛА МЯГКО. По TERM lpac успевает закрыть канал к ISD-R сам, и
		# чистить потом нечего; -9 такой возможности не даёт (см. пояснение у
		# _wdm_free_channels - именно так копилась утечка каналов).
		_MKILLED=""
		if kill -0 "$_PID" 2>/dev/null; then
			_MKILLED=1
			kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null
			_n=0
			while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt 5 ]; do sleep 1; _n=$((_n + 1)); done
			kill -9 "$_PID" 2>/dev/null; killall -9 lpac 2>/dev/null
		fi
		rm -f "$_MLOOP"
		# Прибрали за собой только если убивали: штатный выход каналы не оставляет.
		[ -n "$_MKILLED" ] && _wdm_free_channels "$_MDEV" "$(_mbim_uim_slot)"
		# ОТКАТ - ТОЛЬКО ЕСЛИ MAPPING БЫЛ ЗАПРЕЩЁН (skip=1), то есть речь о
		# физической SIM: её нельзя оставить отобранной у соединения. Когда
		# mapping РАЗРЕШЁН ради активной eSIM (skip=0), возвращать executor
		# назад НЕ надо - иначе каждая следующая операция начинает с нуля, а
		# после отката чип отвечает «euicc_init: -1» (проверено на MV31-W).
		# Так же сделано в community-сборке MBIM-lpac для T99W175.
		[ "$_MSKIP" = 1 ] && 
		[ "$_MSKIP" = 1 ] && _mbim_slot_restore "$_MDEV" "$_MOLD"
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
	case "$T" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	# AT+SIMTYPE - КОМАНДА FIBOCOM, и у других вендоров её нет вовсе. Молчание
	# трактовалось как «слот не eSIM», и на модемах со ВСТРОЕННЫМ eUICC вкладка
	# отвечала «esim slot not active» даже когда слот eSIM физически активен.
	# Живой случай 04.08.2026: Thales MV31-W (SDX55) - QMI показывает
	# «Physical slot 2: Is eUICC: yes, Slot status: active», а SIMTYPE молчит.
	# Спрашиваем QMI UIM: активен ли слот, помеченный как eUICC.
	_ea_w=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
	[ -n "$_ea_w" ] && [ -e "$_ea_w" ] || return 1
	command -v qmicli >/dev/null 2>&1 || return 1
	# esim.sh НЕ подключает lib.sh (проверено: ни одной строки с ним), поэтому
	# общего qmicli_p здесь нет - вызов молча уходил в никуда, и ветка всегда
	# отвечала «слот не активен». Свой минимальный вызов: -p обязателен (общий
	# канал через прокси), --device-open-mbim нужен на cdc_mbim-устройстве.
	_ea_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${_ea_w##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _ea_mb="--device-open-mbim" ;;
	esac
	qmicli -d "$_ea_w" -p $_ea_mb --uim-get-slot-status 2>/dev/null | awk '
		/^ *Physical slot [0-9]+:/ { act = 0; euicc = 0; next }
		/Slot status: *active/     { act = 1 }
		/Is eUICC: *yes/           { euicc = 1 }
		act && euicc { found = 1; exit }
		END { exit(found ? 0 : 1) }
	'
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
	_dl_be=$(apdu_backend)
	# СКОЛЬКО РАЗ ПОВТОРЯТЬ.
	#
	# Обычной операции хватает одного ретрая. А вот ЗАГРУЗКА ПРОФИЛЯ на
	# cdc-wdm-модемах (Qualcomm SDX55: T99W175 / MV31-W) нестабильна сама по
	# себе: длинные APDU (authenticateServer, loadBoundProfilePackage) срываются
	# без внятной причины, и в сообществе тот же профиль встаёт «раза с пятого»,
	# после чего работает без нареканий. Поэтому именно для download на этих
	# бэкендах даём пять попыток; между ними закрываем оставшиеся логические
	# каналы (иначе следующая попытка получит SelectFailed) и выдерживаем паузу.
	# AT/bridge (FM350 и родня) поведения не меняют - там ретрай прежний.
	_dl_max=2
	case " $* " in
		*" download "*)
			case "$_dl_be" in qmi|mbim|uqmi) _dl_max=5 ;; esac ;;
	esac
	_dl_n=1
	while :; do
		R=$(run_lpac "$_T" "$@")
		# УСПЕХ - ТОЛЬКО ПО ФИНАЛЬНОЙ lpa-СТРОКЕ. Вывод многострочный, и КАЖДАЯ
		# progress-строка несёт "code":0 - проверка по всему выводу считала
		# успехом даже провалившуюся загрузку, из-за чего ретрай не срабатывал
		# НИ РАЗУ (проверено 04.08.2026: профиль сорвался на
		# load_bound_profile_package, а повтора не последовало). Та же ловушка
		# уже описана в верхе download-ветки - здесь она просто была не учтена.
		printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0' && break
		# «ICCID УЖЕ НА ЧИПЕ» - ЭТО НАШ ЖЕ УСПЕХ, А НЕ ОШИБКА.
		#
		# Установка идёт в два шага: чип принимает пакет профиля и лишь потом
		# отвечает. Если ответ до нас не дошёл (а на длинных APDU он теряется -
		# ровно из-за этого здесь и появились пять попыток), профиль УЖЕ записан.
		# Следующая попытка честно доходит до store_metadata и получает
		# install_failed_due_to_iccid_already_exists_on_euicc - то есть «такой
		# профиль тут уже есть». Продолжать после этого бессмысленно: чип не
		# изменится, а человек ждёт лишние круги и в конце видит «не удалось»,
		# хотя профиль на месте (живой случай 04.08.2026: установилось с
		# четвёртой попытки, дальше шли ещё две впустую, и вкладка показала
		# ошибку - профиль пришлось искать обновлением списка вручную).
		# ОШИБКУ СЕРВЕРА ПОВТОРЯТЬ БЕСПОЛЕЗНО.
		#
		# Пять попыток заведены под срывы длинных APDU (это шаги es10b_*, они у
		# MBIM-модемов теряются). А когда спотыкается САМ ОБМЕН С SM-DP+ - ответ
		# не разобрался как JSON, пришёл не тот HTTP-код - повтор даст ровно то же
		# самое. Живой случай 04.08.2026 (smdpplus.ripsim.com): пять кругов подряд
		# с одинаковым «Not JSON», шесть минут ожидания, и чип к концу перестал
		# отвечать вовсе. Выходим сразу - ошибка уже понятная, пусть человек видит
		# её, а не крутит спиннер.
		case "$(printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1)" in
			*'"data":"Not JSON"'*|*'"data":"Not Object"'*|*'"data":"HTTP status code error"'*|*'"data":"HTTP transport failed"'*)
				# НО ОБРЫВ ЗАКАЧКИ - ДРУГОЕ ДЕЛО. Мост помечает недокачанное тело
				# (truncated: начинается как JSON, а заканчивается не «}»): это не
				# «сервер отвечает не по протоколу», а сорванная передача, и её
				# повторить как раз стоит. Смотрим ПОСЛЕДНЮЮ httpx-строку лога.
				if [ "$(grep '"type":"httpx"' "$LIVELOG" 2>/dev/null | tail -1 \
					| grep -c '"truncated":1')" = 1 ]; then
					logger -t 5gmodem "esim: server response was cut short - retrying"
				else
					logger -t 5gmodem "esim: server response violates the protocol - retries are pointless, stopping"
					break
				fi ;;
		esac
		# ОТКАЗ SM-DP+ - ЭТО РЕШЕНИЕ СЕРВЕРА, А НЕ СБОЙ.
		#
		# Шаги es9p_* - это разговор с сервером оператора. Если он ответил
		# осмысленным отказом (по SGP.22 - коды GSMA в statusCodeData, у lpac они
		# приезжают текстом в data), повтор не изменит НИЧЕГО: код активации не
		# станет снова годным, а профиль - снова доступным. Живой случай
		# 04.08.2026: «MatchingID is refused» - код уже использован, и мы всё
		# равно отработали пять кругов по полторы минуты, прежде чем сказать
		# человеку то, что было известно с первой попытки.
		# Обрыв закачки сюда не попадает - он разобран выше и уходит в повтор.
		case "$(printf '%s\n' "$R" | grep '"type":"lpa"' | tail -1)" in
			*'"message":"es9p_'*'"data":""'*) : ;;
			*'"message":"es9p_'*)
				logger -t 5gmodem "esim: the operator server refused the request - retries are pointless, stopping"
				break ;;
		esac
		if printf '%s\n' "$R" | grep -q 'iccid_already_exists_on_euicc'; then
			logger -t 5gmodem "esim: a profile with this ICCID is already on the chip - treating the install as successful"
			R='{"type":"lpa","payload":{"code":0,"message":"success","data":"already_installed"}}'
			break
		fi
		[ "$_dl_n" -ge "$_dl_max" ] && break
		# Ретрай зависит от бэкенда: AT/bridge держатся за конкретный tty ->
		# сбрасываем кэш и ищем порт заново. qmi/uqmi/mbim ходят по cdc-wdm и
		# PORT игнорируют, а find_port гоняет CCHO-пробы по AT-портам (лишнее и
		# может задеть модем) - для них просто повторяем по cdc-wdm.
		case "$_dl_be" in
			at|bridge)
				rm -f "$PORTCACHE"
				PORT=$(find_port)
				[ -n "$PORT" ] || break ;;
			*)
				_wdm_free_channels "$(esim_wdm)" "$(_mbim_uim_slot)"
				# ПОСЛЕ СОРВАВШЕЙСЯ ЗАГРУЗКИ ЧИП УХОДИТ В ОТКАЗ ЦЕЛИКОМ:
				# следующая попытка отвечает «euicc_init: -1» и закрытие каналов
				# уже не спасает (проверено - пять попыток подряд легли одинаково).
				# Оживляет переинициализация карты: слот туда-обратно вендорной
				# AT-командой (T99W175/MV31-W: 0 = SIM1, 1 = eSIM). Это дешевле
				# перезагрузки модема (та лечила, но стоит полминуты) и не трогает
				# QMI-канал. Команды нет - просто ждём, как раньше.
				if [ "$_dl_max" -gt 2 ]; then
					# sms_tool НАПРЯМУЮ, а не at_query: esim.sh не подключает
					# lib.sh, и вызов at_query здесь молча не выполнялся вовсе -
					# восстановление не происходило ни разу (проверено).
					# Нумерация вендорной команды 0-based: 0 = SIM1, 1 = eSIM,
					# тогда как _mbim_uim_slot отдаёт физический номер (1..N).
					_dl_p=$(live_port)
					_dl_s=$(_mbim_uim_slot); case "$_dl_s" in ''|*[!0-9]*) _dl_s=2 ;; esac
					_dl_cur=$((_dl_s - 1))
					_dl_alt=0; [ "$_dl_cur" = 0 ] && _dl_alt=1
					if [ -n "$_dl_p" ] && sms_tool -d "$_dl_p" at "AT^switch_slot?" 2>/dev/null \
						| grep -qi "SIM"; then
						logger -t 5gmodem "esim: chip not responding - reinitializing the card by cycling the slot $_dl_cur -> $_dl_alt -> $_dl_cur"
						sms_tool -d "$_dl_p" at "AT^switch_slot=$_dl_alt" >/dev/null 2>&1
						sleep 5
						sms_tool -d "$_dl_p" at "AT^switch_slot=$_dl_cur" >/dev/null 2>&1
						sleep 8
					else
						sleep 3
					fi
				fi ;;
		esac
		_dl_n=$((_dl_n + 1))
		[ "$_dl_max" -gt 2 ] && logger -t 5gmodem "esim: profile download failed - attempt $_dl_n of $_dl_max"
		# И В ЖИВОЙ ЛОГ ТОЖЕ - его читает вкладка.
		# Ретраи молчали для человека: он видел, как одни и те же шаги идут по
		# кругу, и не понимал, зависло это или так задумано (пять попыток на
		# qmi/mbim/uqmi - см. выше). Строку кладём в том же формате, что шлёт
		# lpac, чтобы фронту не пришлось разбирать два разных вида записей.
		printf '{"type":"progress","payload":{"code":0,"message":"retry","data":"%s/%s"}}\n' \
			"$_dl_n" "$_dl_max" >> "$LIVELOG" 2>/dev/null
	done
	echo "$R"
}





# КЭШ ВЕРДИКТА О ЧИПЕ: «ЕСТЬ» ХРАНИМ ДОЛГО, «НЕТ» - НЕДОЛГО.
#
# Положительный ответ стабилен: чип никуда не денется, его можно отдавать
# мгновенно хоть весь день. А отрицательный почти всегда следствие МОМЕНТА:
# модем ещё инициализировался, канал был занят соединением, порт не ответил.
# Раньше такой ответ оседал в файле НАВСЕГДА, и вкладка потом упорно писала
# «ни один порт не ответил как eSIM-чип - сообщите vid:pid», хотя чип цел
# (живой случай 07.08.2026, MV31-W на 2.3.3: стоило освободить канал - тот же
# модем отдал EID без заминки). Отметка времени рядом с кэшем писалась и
# раньше, но её никто не читал - теперь читаем.
_SCACHE_NEG_TTL=600
_scache_get() {   # $1 - файл кэша; печатает вердикт и возвращает 0, если он годен
	[ -s "$1" ] || return 1
	case "$(cat "$1" 2>/dev/null)" in
		*'"available":1'*) cat "$1"; return 0 ;;
	esac
	_sg_t=$(cat "$1.t" 2>/dev/null)
	case "$_sg_t" in ''|*[!0-9]*) return 1 ;; esac
	[ $(( $(cut -d. -f1 /proc/uptime) - _sg_t )) -lt "$_SCACHE_NEG_TTL" ] || return 1
	cat "$1"
	return 0
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
setslot)
	# Слот eUICC для APDU (просьба юзера 9eSIM, 18.08.2026): автоопределение по
	# активному слоту работает не на всех связках, а явный uci-ключ до сих пор
	# можно было прописать только руками. «auto» и всё неизвестное = удалить
	# ключи (вернуться к активному слоту). Пишем во ВСЕ wdm-бэкенды lpac: наш
	# _mbim_uim_slot читает lpac.mbim.*, qmi/uqmi-путь - свои секции.
	# Без пакета lpac файла /etc/config/lpac нет, и uci set молча ничего не
	# делает (поймано на стенде 18.08.2026) - создаём пустой конфиг сами.
	[ -f /etc/config/lpac ] || : > /etc/config/lpac
	case "$2" in
		1|2)
			uci -q set "lpac.mbim=mbim";  uci -q set "lpac.mbim.uim_slot=$2"
			uci -q set "lpac.qmi=qmi";    uci -q set "lpac.qmi.uim_slot=$2"
			uci -q set "lpac.uqmi=uqmi";  uci -q set "lpac.uqmi.uim_slot=$2"
			;;
		*)
			uci -q delete "lpac.mbim.slot" 2>/dev/null
			uci -q delete "lpac.mbim.uim_slot" 2>/dev/null
			uci -q delete "lpac.qmi.uim_slot" 2>/dev/null
			uci -q delete "lpac.uqmi.uim_slot" 2>/dev/null
			;;
	esac
	uci -q commit lpac
	rm -f /tmp/5gmodem_esimstat_* /tmp/5gmodem_esim_actslot 2>/dev/null
	echo '{"result":"ok"}'
	exit 0
	;;
getslot)
	_gs=$(uci -q get lpac.mbim.uim_slot)
	[ -n "$_gs" ] || _gs=$(uci -q get lpac.mbim.slot)
	case "$_gs" in 1|2) ;; *) _gs="auto" ;; esac
	printf '{"slot":"%s"}\n' "$_gs"
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
	_scache_get "$_SCACHE" && exit 0
	echo '{"unknown":1}'
	exit 0
	;;
status-probe)
	AVAIL=0; ACTIVE=0
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_es_sec="m_$(echo "$_AP" | sed 's/[^A-Za-z0-9]/_/g')"
	_SCACHE="/tmp/5gmodem_esimstat_$_AP"
	# КАНАЛ ЗАНЯТ СОЕДИНЕНИЕМ - НЕ ПРОБУЕМ И НЕ ХОРОНИМ ЧИП.
	#
	# Пока интерфейс поднят, узлом cdc-wdm владеет umbim, и выбор бэкенда
	# ЗАКОНОМЕРНО падает на «at». А у SDX55 eUICC по AT недостижим - CCHO-проба
	# перебирает порты впустую и возвращает «чипа нет», после чего вердикт ещё и
	# оседает в кэше. Человек читает совет «сообщите vid:pid, добавим поддержку»
	# про модем, на котором eSIM только что работала (04.08.2026, ModemManager ->
	# MBIM). Здесь проверка НУЖНА отдельно: ветка ниже смотрит уже выбранный
	# бэкенд, а он к этому моменту «at», и занятость канала из него не видна.
	_pb_w=$(esim_wdm)
	if [ -n "$_pb_w" ] && _wdm_owned_by_umbim "$_pb_w"; then
		_scache_get "$_SCACHE" && exit 0
		echo '{"available":0,"active":0,"reason":"uplink"}'
		exit 0
	fi
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
			if _mm_owns_channel && ! _mm_inh_held; then
				# Чип НЕ трогаем (канал у MM), но вкладку не хороним: захват
				# возможен - отдаём takeover-флаг, UI спросит согласие на
				# кратковременный обрыв связи. Активность eSIM-слота решает UI
				# по данным слотов. Не кэшируем.
				echo '{"available":1,"active":1,"takeover":1}'
				exit 0
			fi
			# Qualcomm SDX55 (T99W175/MV31-W/DW5930e) и прочие cdc-wdm-модемы: eUICC
			# достаётся по QMI/MBIM, а не по AT+CCHO. Пробуем lpac chip info по cdc-wdm.
			if euicc_probe_wdm "$_BE"; then
				AVAIL=1; ACTIVE=1
				printf '{"available":1,"active":1}\n' > "$_SCACHE"
				cut -d. -f1 /proc/uptime > "$_SCACHE.t"
			elif _wdm_owned_by_umbim "$(esim_wdm)"; then
				# КАНАЛ ЗАНЯТ СОЕДИНЕНИЕМ - ЭТО НЕ «ЧИПА НЕТ».
				#
				# Проба по cdc-wdm при поднятом интерфейсе не проходит по
				# определению: каналом владеет umbim. Раньше мы записывали в кэш
				# «eUICC нет» и вкладка потом ПОКАЗЫВАЛА этот приговор - вплоть до
				# совета «сообщите vid:pid, добавим поддержку» на модеме, где eSIM
				# минуту назад работала (живой случай 04.08.2026 после переключения
				# ModemManager -> MBIM). Отрицательный вердикт тут НЕ кэшируем:
				# отдаём последний хороший, а если его нет - честную причину.
				_scache_get "$_SCACHE" && exit 0
				echo '{"available":0,"active":0,"reason":"uplink"}'
				exit 0
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
			# АКТИВНА ФИЗИЧЕСКАЯ SIM - ЧИП НЕ ОТВЕЧАЕТ ПО ЗАКОНУ, А НЕ ПО БОЛЕЗНИ.
			#
			# У модема один канал к карте: пока активен слот физической SIM,
			# ISD-R eUICC недостижим - CCHO не откроется НИ НА ОДНОМ порту. Мы
			# при этом печатали «ни один порт не ответил как eSIM-чип, сообщите
			# vid:pid, добавим поддержку», то есть валили на композицию модема
			# то, что лечится одной кнопкой (живой стенд 07.08.2026: FM350 с
			# eUICC, слот 0 - и этот же чип читается сразу после переключения на
			# слот eSIM). Отдаём отдельную причину «slot» - страница предложит
			# переключиться. Ответ НЕ кэшируем: он меняется вместе со слотом.
			_es_sl=$("$RES/simslot.sh" status 2>/dev/null)
			case "$_es_sl" in
				*'"label":"eSIM"'*)
					_es_act=$(printf '%s' "$_es_sl" | jsonfilter -e '@.active' 2>/dev/null)
					_es_eid=$(printf '%s' "$_es_sl" \
						| jsonfilter -e '@.slots[@.label="eSIM"].id' 2>/dev/null | head -1)
					if [ -n "$_es_act" ] && [ -n "$_es_eid" ] && [ "$_es_act" != "$_es_eid" ]; then
						echo '{"available":0,"active":0,"reason":"slot"}'
						exit 0
					fi ;;
			esac
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
			elif _scache_get "$_SCACHE" >/dev/null 2>&1; then
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

# ПРОВЕРКА СЕТИ - ДО ВСЕГО ОСТАЛЬНОГО, ОНА ПРО РОУТЕР, А НЕ ПРО ЧИП.
#
# Раньше netcheck стоял среди операций с eUICC, то есть ПОСЛЕ общего гейта
# (замок, активный слот, поиск eUICC-порта). Стоило чипу перестать отвечать -
# например, после серии оборванных загрузок - и netcheck вообще не выполнялся,
# отвечая «no eUICC-capable AT port». Вкладка, не найдя поля net, показывала
# «Нет доступа в интернет», хотя роутер онлайн и человек в этот момент сидит на
# нём удалённо (живой случай 04.08.2026). К eUICC эта проверка отношения не
# имеет, поэтому отвечаем сразу.
case "$1" in
netcheck)
	# Есть ли у роутера доступ в интернет для загрузки профиля? Загрузка идёт с
	# SM-DP+ оператора по HTTPS, и без сети lpac просто молча висит до таймаута.
	# Проверяем ИМЕННО SM-DP+ из activation code (LPA:1$HOST$ID -> 2-е поле $),
	# а не абстрактный хост: у него может быть доступ, а до SM-DP+ - фаервол.
	# Возврат: {"net":1} - всё ок; {"net":1,"smdp":0} - интернет есть, но SM-DP+
	# не ответил; {"net":0} - интернета нет вовсе.
	_host=$(echo "$2" | awk -F'[$]' '{print $2}')
	# ЕДИНСТВЕННЫЙ ЛИ ЭТО ИСТОЧНИК ИНТЕРНЕТА. Изменяющие операции освобождают
	# модем (_uplink_release: ifdown), а загрузка профиля требует интернет
	# ПОСРЕДИ операции - если весь default-трафик шёл через этот модем, загрузка
	# гарантированно сломается на обращении к SM-DP+ (жалоба с 9esim/T99W175).
	# Страница по флагу предупредит ДО старта, а не сломанной загрузкой после.
	_nc_sole=0
	_nc_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_nc_if=$(uci -q get "5gmodem.m_$(echo "$_nc_ap" | sed 's/[^A-Za-z0-9]/_/g').network")
	[ -n "$_nc_if" ] || _nc_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_nc_dev=$(ubus call "network.interface.$_nc_if" status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	if [ -n "$_nc_dev" ]; then
		_nc_defs=$(ip -4 route show default 2>/dev/null)
		if printf '%s\n' "$_nc_defs" | grep -q " dev $_nc_dev " \
		   && ! printf '%s\n' "$_nc_defs" | grep -v " dev $_nc_dev " | grep -q "^default"; then
			_nc_sole=1
		fi
	fi
	if [ -n "$_host" ] && curl -sS -m 15 -o /dev/null "https://$_host/" 2>/dev/null; then
		echo '{"net":1,"smdp":1,"sole":'"$_nc_sole"'}'
	elif curl -sS -m 10 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
		# интернет есть; SM-DP+ мог не ответить на GET корня - это не всегда
		# ошибка (часть серверов отвечает только на RSP-эндпоинты), но флажок даём
		if [ -n "$_host" ]; then
			echo '{"net":1,"smdp":0,"sole":'"$_nc_sole"'}'
		else
			echo '{"net":1,"smdp":1,"sole":'"$_nc_sole"'}'
		fi
	else
		echo '{"net":0}'
	fi
	# ВЫХОДИМ СРАЗУ: ниже идёт работа с чипом под замком, а нам она не нужна -
	# иначе ответ уже отдан, а процесс ещё полминуты держал бы eUICC.
	exit 0
	;;
esac


# КАНАЛ ЗАНЯТ СОЕДИНЕНИЕМ - ОТВЕЧАЕМ СРАЗУ, НЕ БЕРЯ ЗАМОК.
#
# У модема с cdc-wdm под mbim eUICC живёт ЗА ЭТИМ ЖЕ каналом, и пока соединение
# поднято, читать чип нельзя. Раньше мы всё равно шли дальше: брали замок,
# перебирали CCHO-пробами все tty (их у SDX55 три, и ни один не отвечает), и
# висли на минуты - а любой другой запрос в это время получал «busy». Хуже
# того, отвалившись по таймауту, мы отвечали «ни один порт не ответил как
# eUICC», и человек читал это как «модем не поддерживается» (живой случай
# 04.08.2026 после переключения ModemManager -> MBIM).
# Изменяющие операции сюда не попадают: они ниже сами опускают интерфейс
# (_uplink_release) и работают штатно.
case "$1" in
	download|enable|disable|delete|nickname|flush|notif|notifications|dump-free) : ;;
	*)
		_ub_w=$(esim_wdm)
		if [ -n "$_ub_w" ] && _wdm_owned_by_umbim "$_ub_w"; then
			err "uplink busy"; exit 0
		fi ;;
esac

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

# ВРЕМЕННО ОТКЛЮЧАЕМ СОЕДИНЕНИЕ ЭТОГО МОДЕМА НА ВРЕМЯ ОПЕРАЦИИ.
#
# У модемов, где eUICC живёт только за MBIM (Qualcomm SDX55 и родня), канал
# управления ОДИН и на двоих не делится: пока соединение поднято, им владеет
# umbim, и трогать чип нельзя - оборвём интернет. А выключенный профиль без
# доступа к чипу не включить: получался замкнутый круг, из которого человек сам
# выбраться не мог (04.08.2026: eSIM подняла связь, после чего перестала
# управляться).
# Поэтому опускаем интерфейс САМИ - но ТОЛЬКО:
#   * этого модема (имя берём из его секции, а не общее - у соседних модемов
#     свои интерфейсы, и рвать их нельзя ни при каких условиях);
#   * на ИЗМЕНЯЮЩИХ операциях. Чтение списка (dump) идёт при каждом открытии
#     вкладки - рвать из-за него связь было бы дико;
#   * когда канал действительно занят umbim и другого пути к чипу нет.
# Возвращаем обратно в trap - и на нормальном выходе, и когда процесс убьют.
_UPLINK_IF=""
_uplink_release() {
	# ДВА РАЗНЫХ КОНФЛИКТА, А НЕ ОДИН.
	#
	# Изначально здесь проверялся ТОЛЬКО захват cdc-wdm протоколом mbim. Но у
	# AT-модема (Fibocom FM350 - наш главный AT-eSIM) узла cdc-wdm нет вовсе, а
	# дозвонщик дерётся за ТОТ ЖЕ AT-порт, по которому идут APDU: fibocom-прото
	# держит at_lock на весь диалог подъёма. Пока eUICC пуст, регистрации нет, и
	# прото КРУТИТ дозвон бесконечно (каждые ~70 c: «no network registration
	# after 60s» -> down -> setting up). Загрузка профиля занимает минуты - она
	# просто не пролезает в порт и замирает «на подготовке». Живой отчёт
	# 06.08.2026: FM350, EMPTY_EUICC, в журнале десятки «at_lock: порт
	# /dev/ttyUSB1 занят дольше 10c» вперемешку с циклом дозвона.
	#
	# Поэтому опускаем интерфейс в ОБОИХ случаях: канал занят umbim ИЛИ операция
	# идёт по AT-порту, которым владеет наш же дозвонщик.
	_ur_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_ur_ap" ] || return 0
	_ur_sec="m_$(echo "$_ur_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	_ur_if=$(uci -q get "5gmodem.$_ur_sec.network")
	[ -n "$_ur_if" ] || return 0
	# РЕШАЕМ ПО ПРИЧИНЕ, А НЕ ПО ИМЕНИ БЭКЕНДА.
	#
	# Здесь стояла проверка `apdu_backend` = at|bridge - и она сама себя
	# обманывала: у MBIM-модема с поднятым соединением бэкенд И ЕСТЬ «bridge»
	# ровно потому, что канал занят umbim. Мы попадали в AT-ветку, та говорила
	# «интерфейс поднят - не трогаем», канал не освобождался, и операция
	# упиралась в «uplink busy» (проверено на MV31-W 07.08.2026). Сначала
	# спрашиваем про ЗАНЯТЫЙ КАНАЛ, и лишь если дело не в нём - про AT-порт.
	_ur_at=""
	_ur_w=$(esim_wdm)
	if [ -n "$_ur_w" ] && _wdm_owned_by_umbim "$_ur_w"; then
		_ur_at=""
	else
		case "$(apdu_backend)" in
			at|bridge) _ur_at=1 ;;
			*) return 0 ;;
		esac
	fi
	if [ -n "$_ur_at" ]; then
		# ПОДНЯТЫЙ AT-ИНТЕРФЕЙС НЕ ТРОГАЕМ. Во-первых, дозвон уже закончен - за
		# порт дерётся разве что опрос метрик, а он ходит через ту же очередь
		# культурно. Во-вторых, у модема с рабочим профилем это может быть
		# ЕДИНСТВЕННЫЙ путь в интернет, а загрузке профиля нужен HTTPS до SM-DP+:
		# опустив его, мы сами оборвали бы себе загрузку.
		ubus call "network.interface.$_ur_if" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	fi
	if [ -n "$_ur_at" ]; then
		logger -t 5gmodem "esim: dialing holds the AT port - taking $_ur_if down for the operation"
	else
		logger -t 5gmodem "esim: the data connection owns the channel - taking $_ur_if down for the operation"
	fi
	[ -n "$LIVELOG" ] && printf '%s {"type":"progress","payload":{"code":0,"message":"uplink_down","data":"%s"}}\n' \
		"$(date '+%H:%M:%S' 2>/dev/null)" "$_ur_if" >> "$LIVELOG" 2>/dev/null
	ifdown "$_ur_if" >/dev/null 2>&1
	_UPLINK_IF="$_ur_if"
	# Ждём, пока netifd действительно отпустит узел: сразу после ifdown umbim
	# ещё живёт секунду-другую, и mbim-проба упёрлась бы в него же.
	_ur_i=0
	while [ "$_ur_i" -lt 10 ]; do
		ubus call "network.interface.$_ur_if" status 2>/dev/null \
			| grep -q '"up": true' || break
		sleep 1
		_ur_i=$((_ur_i + 1))
	done
	sleep 1
}
_uplink_restore() {
	[ -n "$_UPLINK_IF" ] || return 0
	logger -t 5gmodem "esim: operation finished - bringing $_UPLINK_IF back up"
	ifup "$_UPLINK_IF" >/dev/null 2>&1
	_UPLINK_IF=""
}
trap '_uplink_restore; rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM HUP

case "$1" in
	download|enable|disable|delete|nickname|flush|notif|notifications|dump-free) _uplink_release ;;
esac

# МОДЕМ ПОД MM: к eUICC не ходим вообще - ни по tty, ни по cdc-wdm (см.
# _mm_owns_channel; на T99W175 это роняло модем). Все чиповые вербы ниже
# получают честную ошибку вместо гонки за чужой канал.
if wdm_backend && _mm_owns_channel; then
	# Захват канала на время операции (см. _mm_esim_take): отказ только если
	# MM так и не показал модем (переэнумерация затянулась).
	if ! _mm_esim_take; then
		err "mm_owns"
		exit 0
	fi
fi
_mm_inh_held && _mm_inh_touch

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
	if [ -z "$PORT" ]; then
		# ЧЕСТНАЯ ПРИЧИНА ВМЕСТО «нет eUICC-порта».
		#
		# У модемов, где eUICC живёт ТОЛЬКО за MBIM/QMI (Qualcomm SDX55), AT-порта
		# для чипа нет вовсе, и сюда мы попадаем ровно в одном случае: канал занят
		# ПОДНЯТЫМ соединением (proto=mbim, umbim держит узел), поэтому mbim-проба
		# запрещена гейтом выше. Сообщение «no eUICC-capable AT port» в этой
		# ситуации сбивает с толку - человек ищет проблему в модеме, хотя всё
		# работает и мешает как раз рабочий интернет через эту же eSIM (живой
		# случай 04.08.2026: профиль поднял связь, после чего список профилей
		# перестал читаться).
		if _wdm_owned_by_umbim "$(esim_wdm)"; then
			err "uplink busy"
		else
			err "no eUICC-capable AT port"
		fi
		exit 0
	fi
fi

flush_notifications() {
	R=$(run_lpac 60 notification process -a -r)
	echo "$R" | grep -q '"code":0' || { rm -f "$PORTCACHE"; }
}

# СБРОС МОДЕМА ПОСЛЕ СМЕНЫ АКТИВНОГО ПРОФИЛЯ.
#
# По SGP.22 eUICC после включения профиля выдаёт проактивную команду REFRESH, и
# модем обязан перечитать карту сам. Часть прошивок этого не делает: в eUICC
# профиль уже enabled, а модем работает со старым - человек видит «переключил, и
# ничего не изменилось». Лечится полным сбросом (AT+CFUN=1,1).
#
# Кому именно сбрасывать - решает quirks.sh (esim_reset_after_switch), потому что
# сброс стоит переэнумерации на USB и примерно минуты без сети: там, где REFRESH
# отрабатывает штатно (FM350-GL), это был бы чистый регресс. Для семейства SDX55
# сброс задан штатным шагом и на чужом рабочем стенде с этим модемом
# (luci-app-epm: «Reboot Method: AT Command, AT+CFUN=1,1, /dev/ttyUSB2»).
#
# ФОНОМ И С ОТВЯЗКОЙ ДЕСКРИПТОРОВ НА САМОМ subshell: вызов приходит через rpcd
# (fs.exec) с потолком 30 c, а сброс с переэнумерацией занимает минуту и больше.
# Без перенаправления rpcd продолжает ждать унаследованный stdout и отдаёт
# вкладке «XHR error» на успешно выполненной операции.
esim_reset_after_switch_maybe() {
	printf '%s' "$1" | jsonfilter -e '@.payload.code' 2>/dev/null | grep -qx 0 || return 0
	_ers_ap=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_ers_ap" ] || return 0
	_ers_sec="m_$(echo "$_ers_ap" | sed 's/[^A-Za-z0-9]/_/g')"
	. /usr/share/5gmodem/quirks.sh
	[ "$(esim_reset_after_switch "$(uci -q get "5gmodem.$_ers_sec.model")" \
		"$(uci -q get "5gmodem.$_ers_sec.vidpid")")" = 1 ] || return 0
	_ers_at=$(uci -q get "5gmodem.$_ers_sec.at_port")
	[ -n "$_ers_at" ] && [ -e "$_ers_at" ] || return 0
	logger -t 5gmodem "esim: profile switched - resetting the modem (AT+CFUN=1,1 on $_ers_at)"
	( /usr/share/5gmodem/reboot_modem.sh hard "$_ers_at" ) >/dev/null 2>&1 </dev/null &
}

case "$1" in
dump-free|dump)
	# dump-free - ЯВНОЕ РАЗРЕШЕНИЕ ЧЕЛОВЕКА ОСВОБОДИТЬ МОДЕМ РАДИ ЧТЕНИЯ.
	#
	# У модемов, где eUICC живёт только за MBIM (SDX55 и родня), канал управления
	# один: пока соединение поднято, им владеет umbim, и читать чип нельзя. До сих
	# пор человеку оставалось только читать объяснение и идти опускать интерфейс
	# руками - а на роутере, где модем не единственный аплинк, это совершенно
	# безобидное действие. Тот же самый путь, что у изменяющих операций: интерфейс
	# опускается ПЕРЕД работой и поднимается в trap на любом выходе, включая
	# убийство процесса. Обычный dump ничего не опускает - он идёт при каждом
	# открытии вкладки, и рвать из-за него связь недопустимо.
	CHIP=$(do_lpac 45 chip info)
	LIST=$(do_lpac 45 profile list)
	_OUT="{\"chip\":$CHIP,\"profiles\":$LIST}"
	# Кэш последнего ХОРОШЕГО дампа - его мгновенно отдаёт dump-cached при
	# возврате на вкладку. Пишем только валидный результат (код профилей 0)
	# и атомарно: полудамп в кэше хуже отсутствия кэша.
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	if [ -n "$_AP" ] && printf '%s' "$_OUT" \
	   | jsonfilter -e '@.profiles.payload.code' 2>/dev/null | grep -qx 0; then
		# Чип ответил - старый приговор «чипа нет» больше не имеет силы.
		printf '{"available":1,"active":1}\n' > "/tmp/5gmodem_esimstat_$_AP"
		cut -d. -f1 /proc/uptime > "/tmp/5gmodem_esimstat_$_AP.t"
		printf '%s\n' "$_OUT" > "/tmp/5gmodem_esimdump_$_AP.tmp" \
			&& mv "/tmp/5gmodem_esimdump_$_AP.tmp" "/tmp/5gmodem_esimdump_$_AP"
	fi
	echo "$_OUT"
	;;
enable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile enable "$2"); flush_notifications
	esim_reset_after_switch_maybe "$O"
	echo "$O"
	;;
disable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
	O=$(do_lpac 60 profile disable "$2"); flush_notifications
	esim_reset_after_switch_maybe "$O"
	echo "$O"
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
	# ЧИП ПОСЛЕ НЕУДАЧИ ОСТАЁТСЯ В ОТКАЗЕ - ПОДНИМАЕМ ЕГО САМИ.
	#
	# Серия оборванных сессий доводит eUICC до состояния, когда он не отвечает
	# даже на чтение: следом «euicc_init: -1», и вкладка показывает «eUICC не
	# отвечает», а список профилей не обновляется ничем, кроме перезагрузки
	# (живой случай 04.08.2026 после пяти неудачных попыток подряд). Лечится тем
	# же приёмом, что и между попытками, - переинициализацией карты сменой слота
	# туда-обратно. Делаем ТОЛЬКО при провале: успешная загрузка чип не роняет.
	if ! printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0'; then
		_rc_p=$(live_port)
		_rc_s=$(_mbim_uim_slot); case "$_rc_s" in ''|*[!0-9]*) _rc_s=2 ;; esac
		_rc_cur=$((_rc_s - 1)); _rc_alt=0; [ "$_rc_cur" = 0 ] && _rc_alt=1
		if [ -n "$_rc_p" ] && sms_tool -d "$_rc_p" at "AT^switch_slot?" 2>/dev/null \
			| grep -qi "SIM"; then
			logger -t 5gmodem "esim: download failed - reinitializing the card so the chip responds again"
			sms_tool -d "$_rc_p" at "AT^switch_slot=$_rc_alt" >/dev/null 2>&1
			sleep 5
			sms_tool -d "$_rc_p" at "AT^switch_slot=$_rc_cur" >/dev/null 2>&1
			sleep 8
			rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
		fi
	fi
	flush_notifications
	# ПЕРВЫЙ ПРОФИЛЬ ВКЛЮЧАЕМ САМИ.
	#
	# Пустой чип + один загруженный профиль = других вариантов нет, и человек
	# ожидает, что eSIM просто заработает. У нас же профиль оставался выключенным,
	# и это было совсем неочевидно: список показывает профиль, а связи нет, пока
	# не нажмёшь «Включить» (замечание владельца 04.08.2026).
	# ТОЛЬКО КОГДА ПРОФИЛЬ РОВНО ОДИН И НИ ОДИН НЕ ВКЛЮЧЁН: если на чипе уже
	# работает другая eSIM, молча переключать её нельзя - это увело бы человека с
	# рабочей связи без спроса.
	if printf '%s\n' "$O" | grep '"type":"lpa"' | tail -1 | grep -q '"code":0'; then
		_PL=$(do_lpac 45 profile list)
		_PN=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[*].iccid' 2>/dev/null | grep -c .)
		_PE=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[*].profileState' 2>/dev/null \
			| grep -ci enabled)
		if [ "$_PN" = 1 ] && [ "$_PE" = 0 ]; then
			_PI=$(printf '%s' "$_PL" | jsonfilter -e '@.payload.data[0].iccid' 2>/dev/null)
			if [ -n "$_PI" ]; then
				logger -t 5gmodem "esim: $_PI is the only profile - enabling it automatically"
				_PR=$(do_lpac 60 profile enable "$_PI")
				flush_notifications
				esim_reset_after_switch_maybe "$_PR"
				rm -f "/tmp/5gmodem_esimdump_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null
			fi
		fi
	fi
	echo "$O"
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
	err "usage: esim.sh status|dump|dump-free|enable|disable|delete|nickname|download|notifications|flush|progress"
	;;
esac
exit 0
