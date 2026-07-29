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

# ПОЧЕМУ НЕ ПОДНЯЛСЯ ИНТЕРФЕЙС ПО MBIM. Две живые ловушки, обе выглядят как
# «модем не работает», хотя модем исправен:
#   PIN_FAILED - штатный mbim.sh валит подъём, если umbim вернул «нужен PIN».
#     Модем при этом может требовать PIN2 (pintype 3) - сервисный код для FDN и
#     лимитов, к передаче данных отношения НЕ имеющий. Плюс сразу зовётся
#     proto_block_restart, и интерфейс перестаёт перезапускаться сам.
#   Failed to attach to network / mbim message timeout - у части модемов
#     (Dell DW5821e / Foxconn T77W968) umbim просто не поднимает PDP-контекст,
#     тогда как ModemManager с тем же модемом и SIM работает.
mbim_verdict() {
	echo ""
	echo "----- Почему не поднялся MBIM (итог) -----"
	_mv_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_mv_if" ] || { echo "интерфейс модема не настроен"; return; }
	[ "$(uci -q get "network.$_mv_if.proto")" = mbim ] || {
		echo "интерфейс работает не по mbim - проверка не нужна"; return; }
	_mv_err=$(ubus call network.interface."$_mv_if" status 2>/dev/null \
		| sed -n 's/.*"code": *"\([^"]*\)".*/\1/p' | head -1)
	_mv_log=$(logread 2>/dev/null | grep -c "Failed to attach to network")
	_mv_pin=$(logread 2>/dev/null | grep -oE "required pin: [0-9]+ - [a-z0-9]+" | tail -1)
	[ -n "$_mv_err" ] && echo "ошибка интерфейса: $_mv_err"
	[ -n "$_mv_pin" ] && echo "модем сообщает: $_mv_pin"
	case "$_mv_pin" in
		*pin2*) echo "  PIN2 - это сервисный код (FDN, лимиты), для интернета он НЕ нужен."
		        echo "  Но umbim считает его блокером и валит подъём с PIN_FAILED." ;;
	esac
	[ "$_mv_log" -gt 0 ] 2>/dev/null && \
		echo "в логе $_mv_log раз «Failed to attach to network» - umbim не поднимает PDP-контекст"
	if [ "$_mv_err" = PIN_FAILED ] || [ "$_mv_log" -gt 0 ] 2>/dev/null; then
		echo "  ЧТО ДЕЛАТЬ: перевести интерфейс на протокол ModemManager."
		echo "  На модемах Dell DW5821e / Foxconn T77W968 это единственный рабочий путь"
		echo "  (проверено несколькими пользователями): mbim и QMI у них либо не"
		echo "  цепляются к сети, либо дают IP без трафика."
	else
		echo "явных признаков этих двух ловушек нет"
	fi
}

# ИТОГ ПО РАДИО человеческим языком. CFUN=0/4 = «радио выключено», и тогда НИ
# ОДИН протокол интерфейс не поднимет: mbim/qmi таймаутят, ModemManager висит в
# disabled. В сыром выводе AT это одна неприметная строка среди двух десятков -
# её пропускали и искали причину в протоколе (живой случай: Dell DW5821e,
# «висит на установке соединения», а у модема радио было выключено).
# КОНФЛИКТ ЗА КАНАЛ УПРАВЛЕНИЯ. Штатный протокол mbim в OpenWrt работает с
# umbim НАПРЯМУЮ (без прокси), поэтому чужой mbim-proxy/qmi-proxy, висящий на
# том же /dev/cdc-wdm*, отбирает устройство - интерфейс валится в «mbim message
# timeout / Failed to read modem caps», хотя модем исправен и зарегистрирован.
# Живой случай: Dell DW5821e, «висит на установке соединения».
# ЗОНА wan: ЕСТЬ ЛИ NAT ДЛЯ ЛОКАЛКИ.
# Отдельный вердикт, потому что симптом обманчив: с самого роутера всё работает
# (пинги идут, DNS отвечает), а клиенты в локалке сидят без интернета - и по
# маршрутам, которые тут же рядом, это НЕ ВИДНО. Причина обычно одна: в зоне нет
# сети wan. Наши прошлые версии сами её оттуда выбивали - `uci add_list` не
# разбирал `option network 'wan wan6'` и делал из строки ОДИН элемент.
fw_zone_verdict() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='wan'\$/\1/p" | head -1)
	if [ -z "$_fz" ]; then
		echo "зоны wan нет вовсе - NAT настроен как-то иначе, проверять вручную"
		return
	fi
	_fnet=$(uci -q get "firewall.$_fz.network")
	_fmasq=$(uci -q get "firewall.$_fz.masq")
	echo "сети зоны wan: $_fnet"
	echo "masq: ${_fmasq:-<не задан>}"
	case "$_fnet" in
		*"'"*)
			echo "ПРОБЛЕМА: элемент списка со ВСТАВЛЕННЫМ пробелом - строка «wan wan6»"
			echo "попала в список одним куском. Сети с таким именем нет, значит НАСТОЯЩИЙ"
			echo "wan в зону не входит и NAT для него не работает: роутер выходит в"
			echo "интернет сам, а локалка - нет. Лечится переустановкой пакета (скрипт"
			echo "uci-defaults расклеит) либо вручную в Сеть > Межсетевой экран."
			;;
	esac
	# Интерфейсы модемов, которых в зоне нет: их трафик не будет NAT-иться.
	for _fi in $(uci show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | sort -u); do
		[ -n "$_fi" ] || continue
		echo " $_fnet " | grep -q " $_fi " || echo "ВНИМАНИЕ: интерфейс $_fi НЕ в зоне wan - без NAT"
	done
}

# МОДЕМ ОТВАЛИВАЕТСЯ ПО USB (питание, кабель, переходник).
# Симптом обманчив: модем определяется, SIM читается, MM даже рапортует
# «successfully connected», а через несколько секунд устройство исчезает с шины и
# перечисляется заново. По верхним разделам отчёта это выглядит как «AT-порт не
# отвечает» или «нет регистрации», и причину ищут в прошивке. Живой случай: один
# и тот же DW5821e в двух переходниках - в одном (линк SuperSpeed) работает
# часами без единого события, в другом (линк high-speed) отваливается через
# 10 секунд ПОСЛЕ установления соединения, то есть ровно когда пошёл трафик и
# вырос ток.
usb_flap_verdict() {
	_uf_p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_uf_p" ] || { echo "активный модем не выбран"; return; }
	_uf_d="/sys/bus/usb/devices/$_uf_p"
	_uf_sp=$(cat "$_uf_d/speed" 2>/dev/null)
	_uf_pw=$(cat "$_uf_d/bMaxPower" 2>/dev/null)
	echo "линк: ${_uf_sp:-?} Мбит/с, запрашиваемый ток: ${_uf_pw:-?}"
	case "$_uf_sp" in
		480)  echo "это USB 2.0 High-Speed - порт отдаёт до 500 мА" ;;
		5000|10000) echo "это USB 3.x SuperSpeed - порт отдаёт до 900 мА" ;;
	esac
	# Отвалы именно этого устройства, а не любые в системе.
	_uf_n=$(logread 2>/dev/null | grep -c "usb $_uf_p: USB disconnect")
	echo "переподключений по USB в текущем логе: $_uf_n"
	# И ПО ВСЕМ ОСТАЛЬНЫМ УСТРОЙСТВАМ ТОЖЕ. Скакать может СОСЕДНИЙ модем, а не
	# активный: живой отчёт с двумя модемами - активный Fibocom работал ровно, а
	# Compal на 2-1.3 перечислялся заново каждые полторы секунды (80+ раз за
	# минуту), и по разделам отчёта это выглядело просто как «модема нет».
	logread 2>/dev/null | sed -n 's/.*usb \([0-9][^:]*\): USB disconnect.*/\1/p' \
		| sort | uniq -c | sort -rn | while read -r _c _d; do
			[ "$_d" = "$_uf_p" ] && continue
			echo "  соседнее устройство $_d: $_c переподключений"
			[ "${_c:-0}" -ge 10 ] && echo "  ЭТО МНОГО: устройство не удерживается на шине - смотреть питание, кабель и режим composition"
		done
	[ "${_uf_n:-0}" -ge 1 ] || return
	echo "ПРОБЛЕМА: устройство пропадало с шины и перечислялось заново."
	echo "Если это происходит ВСКОРЕ ПОСЛЕ подключения к сети - почти наверняка"
	echo "не хватает питания: модем берёт пиковый ток на передаче, и просадка"
	echo "роняет линк. Проверять по порядку: другой USB-порт (лучше USB 3.0),"
	echo "короткий кабель без удлинителей, переходник/хаб С ВНЕШНИМ ПИТАНИЕМ."
	[ "$_uf_sp" = "480" ] && echo "Отдельно: линк поднялся как USB 2.0. Если модем умеет USB 3.0, дело в кабеле или переходнике - контакты SuperSpeed не задействованы."
}

# МОДЕМ ЗАВИС В FASTBOOT (загрузчик вместо рабочей композиции).
# В списке модемов его нет вовсе, портов нет, и отчёт выглядит так, будто модем
# не подключён - хотя lsusb его показывает, просто под ДРУГИМ pid. Живой случай:
# Dell DW5821e в слоте M.2 у Huasifei WH3000 Pro - на плате пин сброса (67)
# притянут к земле, и модем стартует в загрузчик после каждого ребута.
fastboot_verdict() {
	# vid:pid загрузчиков рядом с рабочими: 413c:81e1 - DW5821e (рабочий 81e0),
	# 413c:81e6 - DW5829e (рабочий 81e5). Список открытый: у других моделей свои.
	_fb=$(lsusb 2>/dev/null | grep -iE "413c:81e1|413c:81e6|05c6:9008|1199:9070" )
	if [ -z "$_fb" ]; then
		echo "модемов в режиме загрузчика не видно"
		return
	fi
	echo "$_fb"
	echo "ПРОБЛЕМА: устройство отдаёт композицию ЗАГРУЗЧИКА (fastboot/EDL), а не"
	echo "модема - поэтому портов нет и в списке модемов оно не появляется."
	echo "Обычно лечится командой «fastboot reboot» с роутера; на плате Huasifei"
	echo "WH3000 Pro (слот M.2) причина аппаратная - пин 67 прижат к земле, и"
	echo "модем уходит в загрузчик при КАЖДОЙ загрузке, то есть нужен автозапуск."
	echo "Приложение само в загрузчик не лезет: прошивочные режимы - не наша зона."
}

proxy_verdict() {
	echo ""
	echo "----- Конфликт за канал управления (итог) -----"
	_pv=$(ps w 2>/dev/null | grep -E "mbim-proxy|qmi-proxy" | grep -v grep)
	if [ -z "$_pv" ]; then
		echo "прокси-процессов нет - канал свободен"
		return
	fi
	printf '%s\n' "$_pv"
	_pvproto=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null)
	case "$_pvproto" in
		mbim|qmi)
			echo "ВНИМАНИЕ: интерфейс работает по протоколу '$_pvproto', который открывает"
			echo "  /dev/cdc-wdm* напрямую, а прокси выше держит это же устройство."
			echo "  Это и даёт 'mbim message timeout'. Лечится: killall mbim-proxy qmi-proxy,"
			echo "  затем ifup нужного интерфейса." ;;
		*) echo "(протокол интерфейса '$_pvproto' - прокси ему обычно не мешает)" ;;
	esac
}

# МОДЕМ ЕЩЁ В РЕЖИМЕ НАКОПИТЕЛЯ. Многие свистки при включении отдаются как
# CD-ROM с драйверами (режим Stick), и лишь usb_modeswitch переводит их в
# модемную композицию. Пока этого не случилось, у устройства нет ни tty, ни
# cdc-wdm, ни сетевой карты - приложение честно показывает «модема нет», и
# пользователь ищет поломку там, где её нет. Отдельная строка вместо молчания.
stick_verdict() {
	echo ""
	echo "----- Модем в режиме накопителя? (итог) -----"
	_sv_found=""
	for _sv_d in /sys/bus/usb/devices/*; do
		case "$_sv_d" in *:*) continue ;; esac
		[ -f "$_sv_d/idVendor" ] || continue
		_sv_v=$(cat "$_sv_d/idVendor" 2>/dev/null)
		# вендоры, у которых бывает режим накопителя (Huawei, ZTE, Alcatel,
		# Option, D-Link, Qualcomm-based свистки)
		case "$_sv_v" in
			12d1|19d2|1bbb|0af0|2001|1c9e|05c6|1e0e|2020) ;;
			*) continue ;;
		esac
		# модемные узлы уже есть -> устройство переключилось, всё хорошо
		_sv_ok=""
		for _sv_n in "$_sv_d":*/ttyUSB* "$_sv_d":*/tty/ttyUSB* "$_sv_d":*/ttyACM* \
		             "$_sv_d":*/usbmisc/cdc-wdm* "$_sv_d":*/net/*; do
			[ -e "$_sv_n" ] && { _sv_ok=1; break; }
		done
		[ -n "$_sv_ok" ] && continue
		# УЗЛОВ НЕТ ПРЯМО СЕЙЧАС - ЕЩЁ НЕ ПРИГОВОР. Модем, который в этот момент
		# ресетится (usb reset), на доли секунды остаётся без ttyUSB и cdc-wdm, и
		# проверка выше объявляла его «застрявшим накопителем» - у пользователя с
		# T99W175 отчёт советовал чинить usb_modeswitch, хотя модем был опознан и
		# порты у него есть. Сверяемся со списком модемов: если устройство там
		# есть, значит узлы были совсем недавно и это не накопитель.
		_sv_p=$(basename "$_sv_d")
		if "$RES/listmodems.sh" 2>/dev/null | grep -q "\"path\":\"$_sv_p\""; then
			continue
		fi
		# ни одного модемного узла: смотрим, не mass storage ли это
		for _sv_i in "$_sv_d":*; do
			[ -f "$_sv_i/bInterfaceClass" ] || continue
			case "$(cat "$_sv_i/bInterfaceClass" 2>/dev/null)" in
				08) _sv_found="$_sv_found
   $(basename "$_sv_d")  $_sv_v:$(cat "$_sv_d/idProduct" 2>/dev/null)" ;;
			esac
		done
	done
	if [ -z "$_sv_found" ]; then
		echo "нет - модемы в накопителе не застряли"
		return
	fi
	echo "ДА, устройство отдаётся как USB-накопитель и модемных портов не имеет:"
	printf '   %s\n' $_sv_found
	echo "  Его должен переключить usb_modeswitch. Проверить:"
	echo "    /etc/init.d/usbmode enable; /etc/init.d/usbmode start"
	echo "  и что установлены usb-modeswitch, kmod-usb-net-cdc-ether,"
	echo "  kmod-usb-serial-option."
}

radio_verdict() {   # $1 - АТ-порт
	echo ""
	echo "----- Состояние радио (итог) -----"
	if [ -z "$1" ]; then echo "AT-порта нет - проверить нечем"; return; fi
	_rv=$(sms_tool -d "$1" at "AT+CFUN?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
	case "$_rv" in
		1)  echo "CFUN=1 - радио включено (норма)" ;;
		0)  echo "CFUN=0 - РАДИО ВЫКЛЮЧЕНО: соединение не поднимется ни одним протоколом" ;;
		4)  echo "CFUN=4 - режим полёта: соединение не поднимется" ;;
		'') echo "CFUN не прочитан (порт занят или модем молчит)" ;;
		*)  echo "CFUN=$_rv - НЕ полный режим, ожидается CFUN=1: данные могут не работать" ;;
	esac
}

# ЭТАП СБОРА -> файл прогресса. Пишем КЛЮЧ (латиницей) и номер шага, а не
# готовую фразу: подпись переводится на фронте, иначе в английском интерфейсе
# в строке статуса торчало русское «SIM и eSIM». Номер шага показывает
# движение - самый долгий этап (eSIM: перебор портов, проверка HTTPS) идёт
# больше минуты, и без «5 из 10» это выглядело как зависание.
STEP_N=0
STEP_TOTAL=9
collect() {
	STEP_N=$((STEP_N + 1))
	echo "$STEP_N/$STEP_TOTAL $1" > "$STEP"
}

report() {
	echo "===== luci-app-5gmodem: диагностический отчёт ====="
	echo "Собран: $(date)"
	echo ""
	echo "ВНИМАНИЕ: отчёт содержит идентификаторы модема и SIM (IMEI, IMSI,"
	echo "ICCID, EID) и имя оператора. Пароли и ключи Wi-Fi сюда НЕ попадают."
	echo "Если не хотите публиковать идентификаторы - отправьте файл лично."

	collect "system"
	run 5  "Версия приложения" sh -c "(apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | grep -iE '5gmodem|sms-tool|modemmanager|lpac|ca-bundle|libcurl|qmi-utils|comgt'"
	run 5  "Прошивка" cat /etc/openwrt_release
	run 5  "Модель железа" sh -c "cat /tmp/sysinfo/model 2>/dev/null; cat /proc/device-tree/model 2>/dev/null"
	run 5  "Uptime / память" sh -c "uptime; free"
	run 5  "Время (важно для TLS eSIM)" sh -c "date; echo 'UTC:'; date -u"

	collect "config"
	run 5  "uci 5gmodem" uci -q show 5gmodem
	run 5  "uci sms_tool_js" uci -q show sms_tool_js
	run 5  "uci lpac" uci -q show lpac
	# Пароли/ключи из network не выводим: там PPP/PPPoE-креды и Wi-Fi.
	run 5  "uci network (без секретов)" sh -c "uci -q show network | grep -viE 'password|key|passwd|psk|secret'"
	# Интерфейсы: и СЕКЦИОННЫЕ (из 5gmodem), и ВСЕ модемные из network - секция
	# может ссылаться на чужой/несуществующий интерфейс, а собственный при этом
	# осиротеет, и в отчёте его было не видно вовсе. Плюс ДОЧЕРНИЕ интерфейсы
	# (<iface>_4/_6): у qmi/mbim IPv4 живёт именно в них, и без них нельзя
	# отличить «поднялся с адресом» от «поднялся, но DHCP не дал IP».
	run 10 "Интерфейсы модемов" sh -c "for i in \$( { uci -q show 5gmodem | sed -n \"s/.*\.network='\(.*\)'/\1/p\"; uci -q show network | sed -n \"s/^network\.\([^.]*\)\.modem_path=.*/\1/p\"; } | sort -u); do for j in \"\$i\" \"\${i}_4\" \"\${i}_6\"; do s=\$(ifstatus \"\$j\" 2>/dev/null | grep -vE '\"(dns-search|route)\"'); [ -n \"\$s\" ] && { echo \"### \$j\"; echo \"\$s\"; }; done; done"

	collect "usb"
	run 10 "USB-устройства" sh -c "lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null"
	run 10 "Список модемов" "$RES/listmodems.sh" --refresh
	# КАРТА ПОРТОВ ПРЯМО ИЗ SYSFS + IMEI с портов каждого устройства. Список
	# выше строит наш listmodems, и проверить его по отчёту было нечем: на двух
	# одинаковых модулях (один vid:pid) нельзя было отличить «клонированный IMEI»
	# от «наша привязка портов ошиблась». Здесь всё берётся мимо нашего кода, плюс
	# печатается USB-серийник (различает одинаковые модули) и готовый вердикт.
	run 40 "Карта портов и IMEI (из sysfs)" "$RES/portmap.sh"
	run 5  "Активный модем" "$RES/modemswitch.sh" active
	run 5  "AT-порт (detect.sh)" "$RES/detect.sh"
	run 5  "tty/cdc-wdm в системе" sh -c "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan* 2>/dev/null"
	run 10 "Кто держит порты" sh -c "for f in /dev/ttyUSB* /dev/cdc-wdm*; do [ -e \"\$f\" ] || continue; u=\$(fuser \"\$f\" 2>/dev/null); [ -n \"\$u\" ] && echo \"\$f: \$u\"; done; echo '--- процессы ---'; ps w 2>/dev/null | grep -iE 'ModemManager|uqmi|mbim|sms_tool|lpac|gcom' | grep -v grep"

	collect "mm"
	run 15 "mmcli -L" mmcli -L
	# Индексы берём из mmcli -L, а не наугад "-m 0": индекс меняется при каждом
	# рестарте MM, а на мёртвой шине "-m 0" просто висит до таймаута.
	run 40 "Модемы в MM (детально)" sh -c "mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | while read -r i; do echo \"### модем \$i\"; mmcli -m \"\$i\" -K 2>&1 | grep -viE 'password|\.pin'; done"
	# ВАЖНО: у mm-inhibit.sh НЕТ команды status - неизвестный аргумент попадает в
	# ветку "*)", а это ДЕМОН (while :; sleep 15). Вызов отсюда запускал бы лишнего
	# держателя инхибиции. Читаем состояние напрямую: pid-файлы + флаги в uci.
	run 5  "Инхибиция (наша)" sh -c "echo '--- активные держатели ---'; for f in /var/run/5gmodem-mm-inhibit/*.pid; do [ -f \"\$f\" ] || continue; p=\$(cat \"\$f\"); kill -0 \"\$p\" 2>/dev/null && echo \"\$(basename \"\$f\" .pid): pid \$p (жив)\" || echo \"\$(basename \"\$f\" .pid): pid \$p (мёртв)\"; done; echo '--- флаги mm_exclude ---'; uci -q show 5gmodem | grep mm_exclude || echo '(не задано)'"
	run 5  "Автозапуск MM" sh -c "/etc/init.d/modemmanager enabled && echo 'включён' || echo 'выключен'"

	collect "at"
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
	radio_verdict "$P"
	proxy_verdict
	stick_verdict
	mbim_verdict

	collect "sim"
	run 20 "Слоты SIM" "$RES/simslot.sh" status
	# Сигнал по антенным портам: сразу видно неподключённый пигтейл (RSRP около
	# -140). Есть не у всех модемов - у кого нет, профиль отдаст "Unsupported".
	run 15 "Антенные порты (RSRP/RSRQ)" "$RES/bands.sh" getantports

	# УПРАВЛЕНИЕ БЕНДАМИ: каким путём идёт (vendor/mmcli) и что модем реально
	# отдаёт. Без этого «кнопки бендов не работают» приходилось разбирать вслепую:
	# по отчёту не видно ни какой профиль подключился, ни отвечает ли модем на
	# команды бенд-лока. Живой случай: Thales MV31-W (05c6:90d5) - тот же vid:pid
	# делят Thales и прототип Compal, у которых РАЗНЫЕ пути управления.
	run 20 "Управление бендами: путь" "$RES/bands.sh" mgmtinfo
	run 25 "Управление бендами: что видит приложение" "$RES/bands.sh" getinfo
	run 5  "lpac установлен?" sh -c "ls -l /usr/bin/lpac /usr/lib/lpac 2>/dev/null; echo '--- зависимости ---'; ldd /usr/lib/lpac 2>/dev/null"
	# HTTPS к SM-DP+ - самая частая причина, почему СПИСОК профилей обновляется
	# (это чистый APDU), а ЗАГРУЗКА профиля молча не идёт: нет ca-bundle, кривое
	# время или lpac собран без HTTP-бэкенда.
	run 5  "CA-сертификаты (нужны для загрузки профиля)" sh -c "ls -l /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'ca-bundle НЕ УСТАНОВЛЕН -> загрузка профиля eSIM работать не будет'"
	run 5  "HTTP-бэкенд в lpac" sh -c "strings /usr/lib/lpac 2>/dev/null | grep -qi curl_easy_perform && echo 'curl: есть' || echo 'curl: НЕТ -> lpac не сможет скачать профиль'"
	run 15 "Проверка HTTPS наружу" sh -c "curl -sS -o /dev/null -w 'код=%{http_code} tls=%{ssl_verify_result} время=%{time_total}s\n' https://ya.ru 2>&1 | head -3"
	collect "esim"
	run 5  "eSIM: конфиг lpac (порт AT/uqmi)" sh -c "uci -q show lpac 2>/dev/null; echo '--- custom AID ---'; uci -q get lpac.global.custom_isd_r_aid 2>/dev/null || echo '(по умолчанию A0000005591010FFFFFFFF8900000100)'"
	# КАКОЙ ПОРТ РЕАЛЬНО ОТВЕЧАЕТ eUICC. Главная неочевидная причина «профиль не
	# читается»: eUICC-порт плавает при переперечислении (FM350 виден то на
	# ttyUSB1, то на ttyUSB3), а в lpac.at.device прибит один конкретный. Здесь
	# перебираем ВСЕ tty активного модема пробой CCHO (открытие канала к ISD-R):
	# порт, где канал открывается (ответ "+CCHO: N" или голый номер), и есть
	# eUICC-порт. Плюс печатаем АКТИВНЫЙ слот: lpac видит eUICC только когда
	# активен слот eSIM, а не физической SIM (у человека было active=0 - SIM).
	run 60 "eSIM: поиск eUICC-порта (CCHO по всем tty)" sh -c '
		# Без lpac eSIM недоступна, и перебор (5 AT-команд на каждый порт,
		# до минуты на многопортовом модеме) не даст ничего полезного.
		if [ ! -x /usr/bin/lpac ]; then
			echo "lpac не установлен - перебор портов пропущен (eSIM недоступна)"
			exit 0
		fi
		AID=$(uci -q get lpac.global.custom_isd_r_aid 2>/dev/null)
		[ -n "$AID" ] || AID=A0000005591010FFFFFFFF8900000100
		P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
		echo "активный слот SIM: $(/usr/share/5gmodem/simslot.sh status 2>/dev/null | grep -o "\"active\":\"[^\"]*\"")"
		echo "порты модема $P:"
		for t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null); do
			for c in 1 2 3 4; do sms_tool -d "$t" at "AT+CCHC=$c" >/dev/null 2>&1; done
			R=$(sms_tool -d "$t" at "AT+CCHO=\"$AID\"" 2>/dev/null | tr -d "\r" | grep -v "^$" | grep -vi "^at+ccho" | head -1)
			case "$R" in
				*CCHO:*|[0-9]*) echo "  $t -> ОТКРЫЛСЯ КАНАЛ [$R]  <= это eUICC-порт" ;;
				*) echo "  $t -> нет ([$R])" ;;
			esac
		done'
	run 60 "eSIM: статус" "$RES/esim.sh" status-probe
	run 90 "eSIM: профили и чип" "$RES/esim.sh" dump
	run 60 "eSIM: уведомления" "$RES/esim.sh" notifications

	collect "net"
	run 10 "Маршруты" sh -c "ip route; echo '--- ipv6 ---'; ip -6 route"
	run 10 "uci firewall (зоны)" sh -c "uci show firewall 2>/dev/null | grep -E 'zone|forwarding' | head -40"
	run 10 "Зона wan и NAT (итог)" fw_zone_verdict
	run 10 "Питание и стабильность USB (итог)" usb_flap_verdict
	run 10 "Модем в режиме загрузчика? (итог)" fastboot_verdict
	run 10 "Пинг 77.88.8.8" ping -c 3 -W 2 77.88.8.8
	# IPv6-связность ЛИТЕРАЛОМ (без DNS - его при глушении тоже режут): Яндекс-DNS
	# 2a02:6b8::feed:0ff - v6-аналог 77.88.8.8. ipv6-internet.yandex.net не резолвится.
	run 10 "Пинг IPv6 (2a02:6b8::feed:0ff)" sh -c "ping6 -c 3 -W 2 2a02:6b8::feed:0ff 2>/dev/null || ping -6 -c 3 -W 2 2a02:6b8::feed:0ff"
	run 20 "Лог: ModemManager" sh -c "logread 2>/dev/null | grep -i modemmanager | tail -80"
	run 20 "Лог: netifd/интерфейсы" sh -c "logread 2>/dev/null | grep -iE 'netifd|wwan|qmi|mbim|fibocom' | tail -80"
	run 20 "Лог: ядро (USB)" sh -c "dmesg 2>/dev/null | grep -iE 'usb|option|qmi_wwan|cdc_|reset' | tail -60"
	run 20 "Лог: весь хвост" sh -c "logread 2>/dev/null | tail -120"

	collect "done"
	echo ""
	echo "===== конец отчёта ====="
}

case "$1" in
start)
	# Уже идёт - не плодим второй сбор (AT-порт один, второй сбор его отберёт).
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		echo '{"state":"running"}'; exit 0
	fi
	rm -f "$OUT"; echo "0/9 start" > "$STEP"
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
