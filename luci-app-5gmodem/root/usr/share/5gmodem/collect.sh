#!/bin/sh
#
# Сбор диагностического отчёта для разработчиков.
#
#   collect.sh start   -> запустить сбор в фоне (возвращается сразу)
#   collect.sh status  -> {"state":"running|done|idle","progress":"<шаг>"}
#   collect.sh run     -> собрать синхронно (для консоли/отладки)
#
# Результат: /tmp/5gmodem-diag.txt (обычный текст, его забирает браузер).
#
# ПОЧЕМУ ФОН. Сбор идёт десятки секунд (одни AT-команды на молчащем порту дают
# по 6 c каждая), а rpcd убивает вызов на 30-й секунде - синхронный сбор давал
# бы "XHR error" при фактически идущей работе. Поэтому: start отвечает мгновенно,
# UI опрашивает status. fd отвязываем ОТ ПОДОБОЛОЧКИ - иначе она держит пайпы
# rpcd, и вызов всё равно ждёт EOF (см. reboot_modem.sh, simslot.sh).

RES="/usr/share/5gmodem"
OUT="/tmp/5gmodem-diag.txt"
LOCK="/tmp/5gmodem-diag.lock"
STEP="/tmp/5gmodem-diag.step"

# Команда с ограничением по времени. Без него sms_tool на занятом/молчащем порту
# висит ~35 c, mmcli на полумёртвом MM - бесконечно, и отчёт не собирается вовсе.
# Каждый блок сам себе таймаут: сломанный модем НЕ должен ронять весь сбор.
run() {   # run <timeout> <заголовок> <команда...>
	_t="$1"; _title="$2"; shift 2
	echo ""
	echo "----- $_title -----"
	_tmp="/tmp/.diag.$$"
	( "$@" ) > "$_tmp" 2>&1 &
	_p=$!
	( sleep "$_t"; kill -9 "$_p" 2>/dev/null ) >/dev/null 2>&1 &
	_w=$!
	wait "$_p" 2>/dev/null
	kill "$_w" 2>/dev/null; wait "$_w" 2>/dev/null
	if [ -s "$_tmp" ]; then cat "$_tmp"; else echo "(пусто или таймаут ${_t}c)"; fi
	rm -f "$_tmp"
}

at() {   # at <порт> <команда> - одна AT-команда с таймаутом
	[ -n "$1" ] || { echo "(нет AT-порта)"; return; }
	run 8 "AT $2" sms_tool -d "$1" at "$2"
}

collect() {
	echo "$1" > "$STEP"
}

report() {
	echo "===== luci-app-5gmodem: диагностический отчёт ====="
	echo "Собран: $(date)"
	echo ""
	echo "ВНИМАНИЕ: отчёт содержит идентификаторы модема и SIM (IMEI, IMSI,"
	echo "ICCID, EID) и имя оператора. Пароли и ключи Wi-Fi сюда НЕ попадают."
	echo "Если не хотите публиковать идентификаторы - отправьте файл лично."

	collect "система"
	run 5  "Версия приложения" sh -c "(apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | grep -iE '5gmodem|sms-tool|modemmanager|lpac|ca-bundle|libcurl|qmi-utils|comgt'"
	run 5  "Прошивка" cat /etc/openwrt_release
	run 5  "Модель железа" sh -c "cat /tmp/sysinfo/model 2>/dev/null; cat /proc/device-tree/model 2>/dev/null"
	run 5  "Uptime / память" sh -c "uptime; free"
	run 5  "Время (важно для TLS eSIM)" sh -c "date; echo 'UTC:'; date -u"

	collect "конфиги"
	run 5  "uci 5gmodem" uci -q show 5gmodem
	run 5  "uci sms_tool_js" uci -q show sms_tool_js
	run 5  "uci lpac" uci -q show lpac
	# Пароли/ключи из network не выводим: там PPP/PPPoE-креды и Wi-Fi.
	run 5  "uci network (без секретов)" sh -c "uci -q show network | grep -viE 'password|key|passwd|psk|secret'"
	run 5  "Интерфейсы модемов" sh -c "for i in \$(uci -q show 5gmodem | sed -n \"s/.*\.network='\(.*\)'/\1/p\" | sort -u); do echo \"### \$i\"; ifstatus \"\$i\" 2>/dev/null | grep -vE '\"(dns-search|route)\"'; done"

	collect "USB и порты"
	run 10 "USB-устройства" sh -c "lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null"
	run 10 "Список модемов" "$RES/listmodems.sh" --refresh
	run 5  "Активный модем" "$RES/modemswitch.sh" active
	run 5  "AT-порт (detect.sh)" "$RES/detect.sh"
	run 5  "tty/cdc-wdm в системе" sh -c "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan* 2>/dev/null"
	run 10 "Кто держит порты" sh -c "for f in /dev/ttyUSB* /dev/cdc-wdm*; do [ -e \"\$f\" ] || continue; u=\$(fuser \"\$f\" 2>/dev/null); [ -n \"\$u\" ] && echo \"\$f: \$u\"; done; echo '--- процессы ---'; ps w 2>/dev/null | grep -iE 'ModemManager|uqmi|mbim|sms_tool|lpac|gcom' | grep -v grep"

	collect "ModemManager"
	run 15 "mmcli -L" mmcli -L
	# Индексы берём из mmcli -L, а не наугад "-m 0": индекс меняется при каждом
	# рестарте MM, а на мёртвой шине "-m 0" просто висит до таймаута.
	run 40 "Модемы в MM (детально)" sh -c "mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | while read -r i; do echo \"### модем \$i\"; mmcli -m \"\$i\" -K 2>&1 | grep -viE 'password|\.pin'; done"
	# ВАЖНО: у mm-inhibit.sh НЕТ команды status - неизвестный аргумент попадает в
	# ветку "*)", а это ДЕМОН (while :; sleep 15). Вызов отсюда запускал бы лишнего
	# держателя инхибиции. Читаем состояние напрямую: pid-файлы + флаги в uci.
	run 5  "Инхибиция (наша)" sh -c "echo '--- активные держатели ---'; for f in /var/run/5gmodem-mm-inhibit/*.pid; do [ -f \"\$f\" ] || continue; p=\$(cat \"\$f\"); kill -0 \"\$p\" 2>/dev/null && echo \"\$(basename \"\$f\" .pid): pid \$p (жив)\" || echo \"\$(basename \"\$f\" .pid): pid \$p (мёртв)\"; done; echo '--- флаги mm_exclude ---'; uci -q show 5gmodem | grep mm_exclude || echo '(не задано)'"
	run 5  "Автозапуск MM" sh -c "/etc/init.d/modemmanager enabled && echo 'включён' || echo 'выключен'"

	collect "AT-опрос"
	P=$("$RES/detect.sh" 2>/dev/null)
	echo ""
	echo "AT-порт для опроса: ${P:-(не найден)}"
	at "$P" "ATI"
	at "$P" "AT+CGMM"
	at "$P" "AT+CGMR"
	at "$P" "AT+CPIN?"
	at "$P" "AT+CFUN?"
	at "$P" "AT+COPS?"
	at "$P" "AT+CSQ"
	at "$P" "AT+CGDCONT?"
	at "$P" "AT+CEREG?"
	at "$P" "AT+C5GREG?"
	at "$P" "AT+CGATT?"

	collect "SIM и eSIM"
	run 20 "Слоты SIM" "$RES/simslot.sh" status
	run 5  "lpac установлен?" sh -c "ls -l /usr/bin/lpac /usr/lib/lpac 2>/dev/null; echo '--- зависимости ---'; ldd /usr/lib/lpac 2>/dev/null"
	# HTTPS к SM-DP+ - самая частая причина, почему СПИСОК профилей обновляется
	# (это чистый APDU), а ЗАГРУЗКА профиля молча не идёт: нет ca-bundle, кривое
	# время или lpac собран без HTTP-бэкенда.
	run 5  "CA-сертификаты (нужны для загрузки профиля)" sh -c "ls -l /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'ca-bundle НЕ УСТАНОВЛЕН -> загрузка профиля eSIM работать не будет'"
	run 5  "HTTP-бэкенд в lpac" sh -c "strings /usr/lib/lpac 2>/dev/null | grep -qi curl_easy_perform && echo 'curl: есть' || echo 'curl: НЕТ -> lpac не сможет скачать профиль'"
	run 30 "Проверка HTTPS наружу" sh -c "curl -sS -o /dev/null -w 'код=%{http_code} tls=%{ssl_verify_result} время=%{time_total}s\n' https://www.google.com 2>&1 | head -3"
	run 60 "eSIM: статус" "$RES/esim.sh" status
	run 90 "eSIM: профили и чип" "$RES/esim.sh" dump
	run 60 "eSIM: уведомления" "$RES/esim.sh" notifications

	collect "сеть и логи"
	run 10 "Маршруты" sh -c "ip route; echo '--- ipv6 ---'; ip -6 route"
	run 10 "Пинг 77.88.8.8" ping -c 3 -W 2 77.88.8.8
	run 20 "Лог: ModemManager" sh -c "logread 2>/dev/null | grep -i modemmanager | tail -80"
	run 20 "Лог: netifd/интерфейсы" sh -c "logread 2>/dev/null | grep -iE 'netifd|wwan|qmi|mbim|fibocom' | tail -80"
	run 20 "Лог: ядро (USB)" sh -c "dmesg 2>/dev/null | grep -iE 'usb|option|qmi_wwan|cdc_|reset' | tail -60"
	run 20 "Лог: весь хвост" sh -c "logread 2>/dev/null | tail -120"

	collect "готово"
	echo ""
	echo "===== конец отчёта ====="
}

case "$1" in
start)
	# Уже идёт - не плодим второй сбор (AT-порт один, второй сбор его отберёт).
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		echo '{"state":"running"}'; exit 0
	fi
	rm -f "$OUT"; echo "старт" > "$STEP"
	# Перенаправление ИМЕННО на подоболочке: иначе rpcd ждёт закрытия пайпов
	# и обрывает вызов по таймауту, хотя сбор идёт.
	# tr -d '\000': /proc/device-tree/model и dmesg тащат NUL-байты, из-за которых
	# отчёт становится "binary file" - его неудобно смотреть и грепать.
	( report 2>&1 | tr -d '\000' > "$OUT"; rm -f "$LOCK" ) >/dev/null 2>&1 </dev/null &
	echo $! > "$LOCK"
	echo '{"state":"running"}'
	;;
status)
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		printf '{"state":"running","progress":"%s"}\n' "$(cat "$STEP" 2>/dev/null)"
	elif [ -s "$OUT" ]; then
		printf '{"state":"done","size":"%s"}\n' "$(wc -c < "$OUT" | tr -d ' ')"
	else
		echo '{"state":"idle"}'
	fi
	;;
run)
	report
	;;
*)
	echo "usage: collect.sh start|status|run"
	;;
esac
exit 0
