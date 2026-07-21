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
LPAC="/usr/lib/lpac"

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

# lpac через STDIO-бэкенд + наш AT-мост (esim-apdu-bridge.sh). На FM350-GL прямой
# AT-драйвер lpac 2.3.0 виснет, а его stdio в нашей сборке не читает stdin - зато
# lpac 2.1.x stdio читает корректно, а транспорт APDU (CCHO/CGLA/CCHC) делает мост.
# Пламбинг «зеркальный»: мост читает запросы lpac из FIFO и пишет ответы в pipe ->
# stdin lpac; stdout lpac -> FIFO -> stdin моста. Финальный "lpa"-результат мост
# кладёт в файл. Всё под сторожевым таймером.
# run_lpac <timeout_s> <args...>   (порт = $PORT, установленный вызывающим кодом)
run_lpac() {
	_T="$1"; shift
	# Чистим утёкшие логические каналы ISD-R ПЕРЕД КАЖДОЙ операцией lpac: после
	# предыдущей операции канал мог остаться открытым (или закрылся не полностью),
	# и следующий CCHO завис бы -> euicc_init падает. Одна операция = чистый старт.
	for _c in 1 2 3 4 5 6 7 8; do at_bounded "$PORT" "AT+CCHC=$_c" 2 >/dev/null; done
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
	sh "$BRIDGE" "$PORT" "$_RES" "$_CA" "$LIVELOG" < "$_LOOP" \
		| LPAC_APDU=stdio LPAC_HTTP="$_HTTPDRV" "$LPAC" "$@" > "$_LOOP" 2>/dev/null &
	_PID=$!
	# Опрос вместо wait+сторож: busybox плохо реапит сабшелл пайплайна через wait
	# (зомби + зависание на 40 c). kill -0 ловит завершение мгновенно. Мост выходит
	# на "lpa", lpac умирает по SIGPIPE -> пайплайн закрывается в ту же секунду.
	_n=0
	while kill -0 "$_PID" 2>/dev/null && [ "$_n" -lt "$_T" ]; do sleep 1; _n=$((_n + 1)); done
	kill "$_PID" 2>/dev/null; killall lpac 2>/dev/null
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

# Живой AT-порт активного модема (дёшево). detect.sh после переперечисления
# может дать устаревший tty - тогда берём первый отвечающий tty ЭТОГО модема.
live_port() {
	_D=$("$RES/detect.sh" 2>/dev/null)
	[ -n "$_D" ] && "$RES/atprobe.sh" "$_D" >/dev/null 2>&1 && { echo "$_D"; return 0; }
	_P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_P" ] || return 1
	for _t in $("$RES/listmodems.sh" 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$_P\"].tty[*]" 2>/dev/null); do
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
		rm -f "$PORTCACHE"
		PORT=$(find_port)
		[ -n "$PORT" ] && R=$(run_lpac "$_T" "$@")
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
recheck)
	# ПЕРЕПРОВЕРИТЬ НАЛИЧИЕ eUICC ЗАНОВО. Отрицательный ответ кэшируется (перебор
	# портов стоит секунд), и без этой команды выйти из него нельзя: модем,
	# который при первой пробе молчал, навсегда остался бы «без eSIM».
	# Снимаем и кэш статуса, и кэш eUICC-порта - второй мог указывать на порт,
	# исчезнувший при переперечислении.
	rm -f "/tmp/5gmodem_esimstat_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" \
	      "$PORTCACHE" 2>/dev/null
	exec "$0" status-probe
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
	[ -x "$LPAC" ] || { echo '{"available":0,"active":0}'; exit 0; }

	_vp=$(uci -q get "5gmodem.$_es_sec.vidpid")
	[ -n "$_vp" ] || _vp=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_AP\"].vidpid" 2>/dev/null | head -1)
	for _cap in $ESIM_CAPABLE_VIDPIDS; do
		[ "$_vp" = "$_cap" ] && { echo '{"available":1,"active":0}'; exit 0; }
	done
	echo '{"available":0,"active":0}'
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
				printf '{"available":0,"active":0}\n' > "$_SCACHE"
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
	fi
	echo "{\"available\":$AVAIL,\"active\":$ACTIVE}"
	exit 0
	;;
esac

[ -x "$LPAC" ] || { err "lpac not installed"; exit 0; }

# ---- всё остальное: под замком (у eUICC один логический канал) ---------------
LOCK="/tmp/5gmodem_esim.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
	[ -n "$(find "$LOCK" -mmin +6 2>/dev/null)" ] && rmdir "$LOCK" 2>/dev/null
	mkdir "$LOCK" 2>/dev/null || { err "busy"; exit 0; }
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM HUP

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

flush_notifications() {
	R=$(run_lpac 60 notification process -a -r)
	echo "$R" | grep -q '"code":0' || { rm -f "$PORTCACHE"; }
}

case "$1" in
dump)
	CHIP=$(do_lpac 45 chip info)
	LIST=$(do_lpac 45 profile list)
	echo "{\"chip\":$CHIP,\"profiles\":$LIST}"
	;;
enable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	O=$(do_lpac 60 profile enable "$2"); flush_notifications; echo "$O"
	;;
disable)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
	O=$(do_lpac 60 profile disable "$2"); flush_notifications; echo "$O"
	;;
delete)
	[ -n "$2" ] || { err "no iccid"; exit 0; }
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
	: > "$LIVELOG"
	O=$(do_lpac 240 profile download -a "$2"); flush_notifications; echo "$O"
	;;
notifications)
	do_lpac 45 notification list
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
