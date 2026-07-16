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
BRIDGE="/usr/share/5gmodem/esim-apdu-bridge.sh"
PORTCACHE="/tmp/5gmodem_esim_port"

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
	sh "$BRIDGE" "$PORT" "$_RES" < "$_LOOP" | LPAC_APDU=stdio "$LPAC" "$@" > "$_LOOP" 2>/dev/null &
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
	( sleep "${3:-6}"; kill "$_ap" 2>/dev/null ) & _aw=$!
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
	_R=$(at_bounded "$1" "AT+CCHO=\"$_AID\"" 6)
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
find_port() {
	# Проверяем кэш CCHO-пробой (а не только atprobe): номер eUICC-порта на FM350
	# плавает при переперечислении, и AT-живой, но НЕ-eUICC порт повесил бы lpac.
	C=$(cat "$PORTCACHE" 2>/dev/null)
	if [ -n "$C" ] && [ -e "$C" ] && port_ok "$C"; then
		echo "$C"; return 0
	fi
	rm -f "$PORTCACHE"
	P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	CANDS="$("$RES/detect.sh" 2>/dev/null)"
	[ -n "$P" ] && CANDS="$CANDS $("$RES/listmodems.sh" 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null)"
	SEEN=""
	for t in $CANDS; do
		case " $SEEN " in *" $t "*) continue;; esac
		SEEN="$SEEN $t"
		[ -e "$t" ] || continue
		"$RES/atprobe.sh" "$t" >/dev/null 2>&1 || continue
		if port_ok "$t"; then
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
status)
	AVAIL=0; ACTIVE=0
	if [ -x "$LPAC" ]; then
		_NET=$(uci -q show 5gmodem 2>/dev/null | sed -n \
			"s/^5gmodem\.\(m_[^.]*\)\.path='$(uci -q get 5gmodem.@5gmodem[0].active_modem)'\$/\1/p" | head -1)
		_PROTO=$(uci -q get "network.$(uci -q get "5gmodem.$_NET.network").proto")
		if [ "$_PROTO" != "modemmanager" ]; then
			D=$(live_port)
			if [ -n "$D" ]; then
				AVAIL=1
				esim_active "$D" && ACTIVE=1
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
download)
	[ -n "$2" ] || { err "no activation code"; exit 0; }
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
	err "usage: esim.sh status|dump|enable|disable|delete|nickname|download|notifications|flush"
	;;
esac
exit 0
