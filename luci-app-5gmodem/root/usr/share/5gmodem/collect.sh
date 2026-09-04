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

. /usr/share/5gmodem/lib.sh 2>/dev/null   # at_query: очередь к порту + таймаут

RES="/usr/share/5gmodem"

# ОТЧЁТ НИЧЕГО НЕ ЛОМАЕТ. Диагностика обязана быть чтением: единственный
# инструмент, которым человек зовёт на помощь, не имеет права оборвать ему
# связь. Флаг видят все наши скрипты, которые умеют забирать себе канал
# (esim.sh) - в этом режиме они уступают и отвечают «занято».
ESIM_READONLY=1
export ESIM_READONLY
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

at() {   # at <порт> <команда> - одна AT-команда с таймаутом и ОЧЕРЕДЬЮ к порту
	[ -n "$1" ] || { echo "(нет AT-порта)"; return; }
	# at_query, а не sms_tool напрямую: он берёт at_lock. Без очереди диагностика
	# конкурировала с опросом метрик, и ответы СЪЕЗЖАЛИ по командам - в живом
	# отчёте (T99W175, issue #8) ответ на ATI оказался под «AT+CGDCONT?», а ответ
	# на AT+CGMM - под «AT+CEREG?». Такой отчёт хуже отсутствующего: по нему
	# ставится неверный диагноз. Свой таймаут run оставляем внешним
	# предохранителем - at_query ограничивает время сам, но пусть будет запас.
	run 12 "AT $2" at_query "$1" "$2" 8
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
	# ТРЕТЬЯ ЛОВУШКА - ПРОТОКОЛ НЕ ТОТ, ЧТО У УЗЛА. cdc-wdm под драйвером
	# qmi_wwan говорит по QMI: umbim в него шлёт MBIM-кадры и вечно получает
	# «mbim message timeout», цикл retry выглядит как мёртвый модем (живой
	# случай: T99W175 в композиции 05c6:9025, Netcore N60 Pro, 17.08.2026).
	_mv_dev=$(uci -q get "network.$_mv_if.device")
	case "$_mv_dev" in
		/dev/cdc-wdm*)
			_mv_drv=$(basename "$(readlink -f "/sys/class/usbmisc/${_mv_dev##*/}/device/driver" 2>/dev/null)" 2>/dev/null)
			if [ "$_mv_drv" = "qmi_wwan" ]; then
				echo "ПРОБЛЕМА: узел $_mv_dev создан драйвером qmi_wwan (канал QMI),"
				echo "  а прото интерфейса - mbim. MBIM тут не заговорит никогда:"
				echo "  будет вечный «mbim message timeout»."
				echo "  ЧТО ДЕЛАТЬ: uci set network.$_mv_if.proto='qmi'; uci commit network; ifup $_mv_if"
				return
			fi ;;
	esac
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
# ДОСТУП К АДМИНКЕ: ЖИВА ЛИ ОНА И КТО МОГ ЕЁ ОТРЕЗАТЬ.
#
# ЗАЧЕМ. Два обращения с одним симптомом - «интернет есть, админка LuCI не
# отвечает» (мультимодем + mwan3 после ребута; wwGate после мастера настройки).
# В обоих случаях к моменту сбора отчёта состояние уже было потеряно (сброс/
# удаление mwan3), и разбор упёрся в отсутствие улик. Эта секция собирает их.
#
# ВАЖНО ДЛЯ ТАКИХ СЛУЧАЕВ: отчёт снимается и БЕЗ веб-морды - по SSH:
#   /usr/share/5gmodem/collect.sh run > /tmp/diag.txt
#
# ДВА УРОКА ИЗ ЛОЖНОЙ ДИАГНОСТИКИ (наступил сам, 30.07):
#   - `timeout` в busybox ОТСУТСТВУЕТ: «timeout N cmd || echo висит» печатает
#     «висит» на ЛЮБОЙ системе. Ограничение по времени здесь даёт run().
#   - логин LuCI отдаётся с кодом HTTP 403: «403 + html-тело» - это НОРМА
#     (страница входа), а не поломка. Поломка - таймаут, пустой ответ или 500.
webstack_verdict() {
	echo "--- процессы ---"
	for _wv_p in uhttpd rpcd ubusd; do
		if ps w 2>/dev/null | grep -q "[${_wv_p%"${_wv_p#?}"}]${_wv_p#?}"; then
			echo "$_wv_p: работает"
		else
			echo "$_wv_p: НЕ ЗАПУЩЕН - вот и причина мёртвой админки"
		fi
	done
	echo "--- ubus отвечает? ---"
	_wv_t0=$(cut -d. -f1 /proc/uptime)
	if ubus call system board >/dev/null 2>&1; then
		echo "ubus: ok ($(( $(cut -d. -f1 /proc/uptime) - _wv_t0 )) c)"
	else
		echo "ubus: ОШИБКА - rpcd/LuCI без него не работают"
	fi
	echo "--- страница входа ---"
	# busybox wget ТЕЛО ошибочного ответа НЕ сохраняет (проверено: rc=8, тело
	# 0 байт при живом LuCI) - поэтому судим по КОДУ ВОЗВРАТА и скорости:
	#   rc=0 - HTTP 200; rc=8 - сервер ответил ошибкой, и для /cgi-bin/luci/ это
	#   ровно 403 страницы входа: диспетчер LuCI отработал, админка ЖИВА.
	#   Всё прочее (или долгий ответ) - не достучались.
	_wv_t1=$(cut -d. -f1 /proc/uptime)
	wget -q -O /dev/null -T 8 http://127.0.0.1/cgi-bin/luci/ 2>/dev/null
	_wv_c=$?
	_wv_dt=$(( $(cut -d. -f1 /proc/uptime) - _wv_t1 ))
	case "$_wv_c" in
		0) echo "LuCI отвечает (HTTP 200 за ${_wv_dt} c)" ;;
		8) echo "LuCI отвечает (страница входа, HTTP 403 за ${_wv_dt} c - это норма)" ;;
		*) echo "LuCI НЕ ОТВЕЧАЕТ (wget rc=$_wv_c за ${_wv_dt} c)" ;;
	esac
}

policyrouting_verdict() {
	echo "--- правила policy routing (ip rule) ---"
	ip rule show 2>/dev/null
	_pr_n=$(ip rule show 2>/dev/null | wc -l)
	# Штатных правил три: 0 lookup local, 32766 main, 32767 default.
	if [ "$_pr_n" -gt 3 ] 2>/dev/null; then
		echo "нестандартных правил: $((_pr_n - 3)) - работает policy routing (mwan3?)."
		echo "Если админка недоступна из локалки при живом интернете - смотреть сюда:"
		echo "ответы самого роутера могли уйти в таблицу аплинка, где нет маршрута в LAN."
		for _pr_t in $(ip rule show 2>/dev/null | sed -n 's/.*lookup \([0-9]\{1,\}\).*/\1/p' | sort -u); do
			echo "  таблица $_pr_t: $(ip route show table "$_pr_t" 2>/dev/null | head -3 | tr '\n' '; ')"
		done
	else
		echo "policy routing не используется (только штатные правила)"
	fi
	echo "--- mwan3 ---"
	if [ -x /etc/init.d/mwan3 ] || [ -f /etc/config/mwan3 ]; then
		echo "mwan3 УСТАНОВЛЕН; статус: $(mwan3 status 2>/dev/null | head -5 | tr '\n' ' ' || echo 'не отвечает')"
	else
		echo "mwan3 не установлен"
		# Осиротевшие правила от удалённого mwan3 продолжают действовать до ребута.
		ip rule show 2>/dev/null | grep -q "lookup 25[0-9]" \
			&& echo "НО остались его таблицы (25x) в ip rule - policy routing ещё жив!"
	fi
	echo "--- lan в правильной зоне? ---"
	_pr_lz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'\$/\1/p" | head -1)
	_pr_wz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	echo "input зоны lan: $(uci -q get "firewall.$_pr_lz.input")"
	case " $(uci -q get "firewall.$_pr_wz.network") " in
		*" lan "*) echo "ПРОБЛЕМА: интерфейс lan состоит в зоне WAN (input=REJECT) - админка отрезана межсетевым экраном" ;;
	esac
}

# Команда с пределом времени, но БЕЗ заголовка (run печатает свой). Нужна
# внутри вердиктов, где один блок делает несколько ограниченных проб подряд.
# busybox timeout в системе нет - только эта пара «фон + kill» (см. память
# проекта: на ней я дважды «сломал» живой стенд ложными пробами).
cap() {   # cap <секунды> <команда...>
	_c_t="$1"; shift
	_c_f="/tmp/.diagcap.$$"
	( "$@" ) > "$_c_f" 2>&1 &
	_c_p=$!
	( sleep "$_c_t"; kill -9 "$_c_p" 2>/dev/null ) >/dev/null 2>&1 &
	_c_w=$!
	wait "$_c_p" 2>/dev/null
	kill "$_c_w" 2>/dev/null; wait "$_c_w" 2>/dev/null
	cat "$_c_f" 2>/dev/null; rm -f "$_c_f"
}

# КТО ДЕРЖИТ ИНТЕРНЕТ - И ЖИВ ЛИ ОН.
#
# Главный вопрос отчёта «инета нет», на который до сих пор приходилось отвечать
# вручную, сводя `ip route` с `uci show network` и логом. Живой случай (4 модема,
# zbt): Wi-Fi-аплинк стоял первым в «Приоритете интернета» (metric 10), после
# загрузки прицепился к точке БЕЗ интернета и держал default поверх четырёх
# работающих модемов - трафик семь минут лился в дыру. В отчёте всё выглядело
# исправным: модемы connected, ping с роутера проходил (он уходил уже по другому
# маршруту, после того как пользователь снёс станцию).
#
# Поэтому здесь: порядок аплинков по метрикам, КТО реально несёт default,
# отвечает ли ИМЕННО ОН (ping с привязкой к его устройству), и что об этом
# думает сторож - вместе с состоянием его выключателей.
# USB_MODESWITCH СБРОСИЛ КОНФИГУРАЦИЮ - И МОДЕМ ОСТАЛСЯ БЕЗ КАНАЛА ДАННЫХ.
#
# В базе /etc/usb-mode.json встречаются записи «config: 0» для модемов, которые
# и так приходят в рабочей композиции (Dell DW5821e / Foxconn T77W968). Ядро по
# такому правилу снимает уже привязанный драйвер, и модем остаётся с одними
# AT-портами: ни cdc-wdm, ни wwan0, настраивать интерфейс не на чем. Снаружи это
# выглядит как «модем появился и сразу отвалился» - живой отчёт 26.08.2026,
# Cudy TR3000. Раздел ищет ОБА следа: запись в базе и характерные строки ядра.
usbmode_verdict() {
	_um_hit=0
	if logread 2>/dev/null | grep -q "usbmode.*sets config #0"; then
		echo "В ЖУРНАЛЕ ЕСТЬ СЛЕД: usbmode выставлял устройству config #0."
		echo "Это снимает драйвер данных: в логе рядом видно «cdc_mbim ... unregister»."
		_um_hit=1
	fi
	for _um_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].vidpid' 2>/dev/null | sort -u); do
		[ "$(jsonfilter -i /etc/usb-mode.json -e "@.devices[\"$_um_p\"][\"*\"].config" 2>/dev/null)" = "0" ] || continue
		echo "ПРАВИЛО НА МЕСТЕ: у $_um_p в /etc/usb-mode.json стоит «config: 0» -"
		echo "оно сломает композицию при следующем подключении модема."
		_um_hit=1
	done
	# Есть AT-порты, но нет ни cdc-wdm, ни сетевого - ровно тот итог, к которому
	# приводит сброс конфигурации.
	#
	# СЕТЕВОЙ ИНТЕРФЕЙС ИЩЕМ В SYSFS, А НЕ В ПОЛЕ net[] СПИСКА МОДЕМОВ: туда он
	# попадает только у HiLink-стиков и телефонов, а у модема, найденного по
	# портам, остаётся пустым, даже когда канал данных на месте. У RNDIS-модема
	# (Rolling RW350-GL: eth2 на rndis_host) отчёт из-за этого объявлял
	# «композиция сломана» на исправном устройстве - живой отчёт 03.09.2026.
	_um_bad=""
	for _um_mp in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_um_mp" in *-*) ;; *) continue ;; esac
		# без AT-портов проверять нечего: разговор про модем, потерявший данные
		ls /sys/bus/usb/devices/"$_um_mp":*/tty/* >/dev/null 2>&1 \
			|| ls /sys/bus/usb/devices/"$_um_mp":*/*/tty/* >/dev/null 2>&1 || continue
		ls /sys/bus/usb/devices/"$_um_mp":*/net/* >/dev/null 2>&1 && continue
		ls /sys/bus/usb/devices/"$_um_mp":*/usbmisc/cdc-wdm* >/dev/null 2>&1 && continue
		_um_bad="$_um_bad $_um_mp"
	done
	if [ -n "$_um_bad" ]; then
		echo "У модема есть AT-порты, но НЕТ канала данных (cdc-wdm/сетевого интерфейса):$_um_bad"
		echo "Настраивать интерфейс не на чем - это и есть последствие сброса конфигурации."
		_um_hit=1
	fi
	if [ "$_um_hit" = 0 ]; then
		echo "следов нет - раздел не применим"
		return
	fi
	echo
	echo "ЧТО ДЕЛАТЬ: приложение снимает вредное правило само и заново применяет"
	echo "конфигурацию USB, чтобы ядро вернуло драйверы. Если этого не случилось"
	echo "(старая версия приложения) - обновитесь и переподключите модем."
	echo "Проверить руками:  /usr/share/5gmodem/usbmode-fix.sh"
}

uplink_verdict() {
	_uv_dump=$(ubus call network.interface dump 2>/dev/null)
	_uv_wz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	_uv_nets=$(uci -q get "firewall.$_uv_wz.network")
	_uv_cfg=$("$RES/health.sh" getconf 2>/dev/null)
	_uv_en=$(printf '%s' "$_uv_cfg" | jsonfilter -e '@.enabled' 2>/dev/null)
	_uv_fo=$(printf '%s' "$_uv_cfg" | jsonfilter -e '@.failover' 2>/dev/null)

	# Устройство и адрес: у qmi/dhcp-модемов они висят на ДИНАМИЧЕСКОМ ребёнке
	# "<имя>_4", а родитель стоит пустым - спрашиваем обоих (как iface_dev в
	# health.sh). И только скобочный синтаксис jsonfilter: "ipv4-address" с
	# дефисом в точечной записи не разбирается, поле молча выходило пустым.
	_uv_get() {   # $1 - интерфейс, $2 - выражение после имени
		_uvg=$(printf '%s' "$_uv_dump" | jsonfilter -e "@.interface[@.interface=\"$1\"]$2" 2>/dev/null | head -1)
		[ -n "$_uvg" ] || _uvg=$(printf '%s' "$_uv_dump" | jsonfilter -e "@.interface[@.interface=\"${1}_4\"]$2" 2>/dev/null | head -1)
		printf '%s' "$_uvg"
	}
	echo "--- аплинки зоны wan по приоритету ---"
	for _uv_n in $_uv_nets; do
		_uv_m=$(uci -q get "network.$_uv_n.metric"); [ -n "$_uv_m" ] || _uv_m=0
		_uv_d=$(_uv_get "$_uv_n" '.l3_device')
		_uv_ip=$(_uv_get "$_uv_n" '["ipv4-address"][0].address')
		_uv_h="-"
		[ -f "/tmp/5gmodem_health/$_uv_n" ] && read -r _uv_h _ _ _ _ 2>/dev/null < "/tmp/5gmodem_health/$_uv_n"
		# «ЕСТЬ АДРЕС» И «МОЖЕТ НЕСТИ ТРАФИК» - РАЗНЫЕ ВЕЩИ. Линк с адресом, но
		# без шлюза (DHCP не прислал option router) выглядел в этом списке
		# здоровым - и человек не понимал, почему приоритет на него не
		# переключается: переключать не на что, default-маршрута у линка нет и
		# взяться ему неоткуда (живой случай 25.08.2026, WH3000 Pro).
		_uv_gw=$(_uv_get "$_uv_n" '.route[@.target="0.0.0.0"].nexthop')
		_uv_note=""
		if [ -n "$_uv_d" ] && [ -n "$_uv_ip" ]; then
			ip -4 route show default 2>/dev/null | grep -qE " dev $_uv_d( |$)" \
				|| _uv_note="  БЕЗ МАРШРУТА"
			[ -n "$_uv_note" ] && [ -z "$_uv_gw" ] && _uv_note="  БЕЗ ШЛЮЗА (DHCP не дал option router)"
		fi
		printf 'metric %-5s %-8s %-10s %-16s сторож: %s%s\n' \
			"$_uv_m" "$_uv_n" "${_uv_d:--}" "${_uv_ip:-нет адреса}" "$_uv_h" "$_uv_note"
	done | sort -n -k2

	# ЖИВОЙ маршрут, а не порядок в uci: сторож штрафует метрику в таблице ядра,
	# не трогая конфиг, и эти две картины расходятся штатно.
	echo "--- кто реально несёт default ---"
	ip -4 route show default 2>/dev/null | sed 's/^/  /'
	_uv_ldev=$(ip -4 route show default 2>/dev/null \
		| awk '{m=0; d=""; for(i=1;i<NF;i++){if($i=="dev")d=$(i+1); if($i=="metric")m=$(i+1)+0} if(d!="")print m, d}' \
		| sort -n | head -1 | cut -d' ' -f2)
	if [ -z "$_uv_ldev" ]; then
		echo "default-маршрута НЕТ вовсе - интернета нет ни у кого"
		return
	fi
	_uv_lif=""
	for _uv_n in $_uv_nets; do
		[ "$(_uv_get "$_uv_n" '.l3_device')" = "$_uv_ldev" ] && { _uv_lif="$_uv_n"; break; }
	done
	echo "трафик идёт через: ${_uv_lif:-?} ($_uv_ldev)"
	# Линки выше по приоритету, которые НЕ МОГУТ взять трафик, - объясняем
	# прямо здесь: иначе «почему не переключается на кабель» остаётся загадкой.
	for _uv_n in $_uv_nets; do
		_uv_d2=$(_uv_get "$_uv_n" '.l3_device'); [ -n "$_uv_d2" ] || continue
		[ "$_uv_d2" = "$_uv_ldev" ] && continue
		_uv_m2=$(uci -q get "network.$_uv_n.metric"); [ -n "$_uv_m2" ] || _uv_m2=0
		_uv_lm=$(uci -q get "network.${_uv_lif}.metric"); [ -n "$_uv_lm" ] || _uv_lm=0
		[ "$_uv_m2" -lt "$_uv_lm" ] 2>/dev/null || continue
		ip -4 route show default 2>/dev/null | grep -qE " dev $_uv_d2( |$)" && continue
		echo "  ВНИМАНИЕ: $_uv_n ($_uv_d2) стоит выше по приоритету (metric $_uv_m2),"
		echo "  но default-маршрута у него нет - переключиться на него не на что."
		if [ -z "$(_uv_get "$_uv_n" '.route[@.target="0.0.0.0"].nexthop')" ]; then
			echo "  Причина: сеть не выдала шлюз (у DHCP нет option router)."
			echo "  Чинить у вышестоящего роутера либо прописать шлюз статикой."
		fi
	done

	# Проба ИМЕННО через это устройство (SO_BINDTODEVICE): обычный ping с
	# роутера ходит по любому маршруту и на вопрос «жив ли ЭТОТ линк» не
	# отвечает - именно так поломка и пряталась в прежних отчётах.
	_uv_ok=""
	for _uv_t in 77.88.8.8 1.1.1.1; do
		case "$(cap 6 ping -I "$_uv_ldev" -c 2 -W 2 "$_uv_t")" in
			*" 0% packet loss"*|*"1 packets received"*|*"2 packets received"*) _uv_ok=1; break ;;
		esac
	done
	if [ -n "$_uv_ok" ]; then
		echo "проба через $_uv_ldev: интернет ЕСТЬ"
	else
		echo "проба через $_uv_ldev: ИНТЕРНЕТА НЕТ - трафик уходит в дыру"
		echo "  (аплинк с адресом, но без выхода в сеть, для ядра здоров:"
		echo "   маршрут есть, значит сам он не переключится)"
		if [ "$_uv_en" != "1" ]; then
			echo "  сторож интернета ВЫКЛЮЧЕН - некому это заметить"
		elif [ "$_uv_fo" != "1" ]; then
			echo "  сторож включён, но «переключать трафик» ВЫКЛЮЧЕНО -"
			echo "  он видит провал и намеренно ничего не делает"
		else
			echo "  переключение включено - смотреть ниже, почему сторож не увёл трафик"
		fi
	fi

	echo "--- сторож интернета ---"
	echo "настройки: ${_uv_cfg:-(нет ответа)}"
	if [ -d /tmp/5gmodem_health ]; then
		for _uv_f in /tmp/5gmodem_health/*; do
			[ -f "$_uv_f" ] || continue
			case "$_uv_f" in */.t) continue ;; esac
			printf '  %s: %s\n' "${_uv_f##*/}" "$(cat "$_uv_f" 2>/dev/null | head -1)"
		done
	else
		echo "  состояния нет - сторож ни разу не отработал круг"
	fi
}

# DNS: КЛИЕНТ ГОВОРИТ «ИНТЕРНЕТА НЕТ», А РОУТЕР ПИНГУЕТ.
#
# Два живых механизма, оба невидимы в маршрутах.
#   1. Защита от DNS-rebind рубит ответ, если в нём приватный адрес. У этого
#      пользователя так режется dns.msftncsi.com - проба связности Windows, и
#      КАЖДЫЙ его компьютер постоянно показывает «Без доступа к Интернету»,
#      хотя сайты открываются. Три отчёта подряд с жалобой «инета нет» - и во
#      всех роутер был полностью в сети.
#   2. У мультимодемного роутера в resolv.conf.auto лежат серверы ВСЕХ
#      операторов сразу. Запрос к чужому резолверу уходит через default другого
#      оператора, и тот его молча роняет: резолвинг то работает, то нет.
dns_verdict() {
	_dv_auto=/tmp/resolv.conf.d/resolv.conf.auto
	echo "--- локальный резолвер (как у клиентов) ---"
	cap 8 nslookup ya.ru 127.0.0.1 2>&1 | head -8
	echo "--- апстримы: чей и отвечает ли ---"
	if [ -s "$_dv_auto" ]; then
		# resolv.conf.auto пишет netifd, комментарием над серверами - чей они
		# интерфейс. По нему и раскладываем ответственность.
		_dv_if="?"
		while read -r _dv_a _dv_b _dv_c; do
			case "$_dv_a" in
				'#') [ "$_dv_b" = "Interface" ] && _dv_if="$_dv_c"; continue ;;
				nameserver) ;;
				*) continue ;;
			esac
			_dv_s="$_dv_b"
			case "$(cap 6 nslookup ya.ru "$_dv_s" 2>&1)" in
				*"Address"*[0-9]*) _dv_r="отвечает" ;;
				*) _dv_r="НЕ ОТВЕЧАЕТ (запрос ушёл не через свой аплинк?)" ;;
			esac
			printf '  %-16s от %-8s - %s\n' "$_dv_s" "$_dv_if" "$_dv_r"
		done < "$_dv_auto"
	else
		echo "  $_dv_auto пуст или отсутствует"
	fi
	_dv_n=$(grep -c "^nameserver" "$_dv_auto" 2>/dev/null)
	case "$_dv_n" in ''|*[!0-9]*) _dv_n=0 ;; esac
	[ "$_dv_n" -gt 3 ] && {
		echo "  серверов $_dv_n - это резолверы РАЗНЫХ операторов сразу."
		echo "  Запрос к чужому уходит через default другого аплинка, и тот его"
		echo "  роняет: у клиентов это выглядит как «сайты открываются через раз»."
	}
	echo "--- защита от DNS-rebind ---"
	_dv_rb=$(logread 2>/dev/null | grep -i "rebind" | tail -20)
	if [ -n "$_dv_rb" ]; then
		# Имена достаём мягким шаблоном, а если он не совпал - показываем САМИ
		# строки лога. Жёсткое 's/.*detected: *//' на 25.12.5 перестало
		# совпадать (dnsmasq сменил формат), и три отчёта подряд печатали
		# предупреждение БЕЗ имён - по ним нельзя было понять, режется ли проба
		# связности Windows/Android или что-то безобидное.
		_dv_names=$(printf '%s\n' "$_dv_rb" | sed -n 's/.*[Dd]etected[:,]* *//p' | sort | uniq -c)
		if [ -n "$_dv_names" ]; then
			printf '%s\n' "$_dv_names" | sed 's/^/  /'
		else
			printf '%s\n' "$_dv_rb" | tail -5 | sed 's/^/  | /'
		fi
		echo "  Эти имена dnsmasq НЕ отдаёт клиентам: ответ содержал приватный адрес."
		case "$_dv_rb" in
			*msftncsi*|*msftconnecttest*)
				echo "  СРЕДИ НИХ ПРОБА СВЯЗНОСТИ WINDOWS (msftncsi/msftconnecttest):"
				echo "  все Windows-клиенты будут показывать «Без доступа к Интернету»"
				echo "  ПОСТОЯННО, даже когда интернет работает. Лечится исключением:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftncsi.com'"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftconnecttest.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
		case "$_dv_rb" in
			*gstatic*|*connectivitycheck*)
				echo "  СРЕДИ НИХ ПРОБА СВЯЗНОСТИ ANDROID (connectivitycheck.gstatic.com):"
				echo "  телефоны на Wi-Fi будут показывать «Подключено, без интернета»."
				echo "  Лечится исключением:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='connectivitycheck.gstatic.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
	else
		echo "  срабатываний в логе нет"
	fi
}

# ФОРМАТ КАДРОВ QMI: RAW-IP ПРОТИВ 802.3.
#
# Самый неприятный вид отказа: `uqmi --get-data-status` отвечает "connected",
# адрес выдан, маршрут стоит - а трафика нет. Снаружи неотличимо от исправной
# работы, и человек ищет причину в операторе, APN и сигнале. На деле драйвер и
# прошивка договорились о РАЗНОМ формате кадров: qmi_wwan ждёт raw-ip, модем
# шлёт 802.3 (или наоборот). Приём молча отбрасывается - TX растёт, RX ноль.
#
# Живой случай 01.08.2026 (SIM7100E): raw_ip=Y при '802-3' у модема. Лечится
# приведением сторон к одному формату; у этого аппарата помог AT+CFUN=1,1, после
# которого атрибут вернулся в N и совпал с прошивкой. Через `option dhcp 0`
# «чинить» бесполезно: адрес назначится, канала не будет.
qmi_format_verdict() {
	_qf_any=""
	for _qf_n in /sys/class/net/*/qmi/raw_ip; do
		[ -f "$_qf_n" ] || continue
		_qf_any=1
		_qf_if=$(basename "$(dirname "$(dirname "$_qf_n")")")
		_qf_raw=$(cat "$_qf_n" 2>/dev/null)
		# Узел управления этого же USB-устройства.
		_qf_dev=$(readlink -f "/sys/class/net/$_qf_if/device" 2>/dev/null)
		_qf_wdm=""
		for _qf_w in "$(dirname "$_qf_dev")"/*/usbmisc/cdc-wdm*; do
			[ -e "$_qf_w" ] && { _qf_wdm="/dev/$(basename "$_qf_w")"; break; }
		done
		printf '%s: raw_ip=%s' "$_qf_if" "${_qf_raw:-?}"
		if [ -n "$_qf_wdm" ] && command -v qmicli >/dev/null 2>&1; then
			_qf_fmt=$(cap 15 qmicli -p -d "$_qf_wdm" --wda-get-data-format 2>/dev/null \
				| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
			printf ', модем: %s' "${_qf_fmt:-не ответил}"
			case "$_qf_raw:$_qf_fmt" in
				Y:raw-ip|N:802-3|*:) : ;;
				*) printf ' <- РАССИНХРОН: приём отбрасывается молча' ;;
			esac
		fi
		# Счётчики: RX=0 при растущем TX - тот же симптом с другой стороны.
		_qf_rx=$(cat "/sys/class/net/$_qf_if/statistics/rx_packets" 2>/dev/null)
		_qf_tx=$(cat "/sys/class/net/$_qf_if/statistics/tx_packets" 2>/dev/null)
		printf ' | пакеты rx=%s tx=%s' "${_qf_rx:-?}" "${_qf_tx:-?}"
		case "$_qf_rx" in
			0|1|2|3) [ "${_qf_tx:-0}" -gt 50 ] 2>/dev/null && printf ' <- ТРАФИК НЕ ХОДИТ (ушло %s, пришло %s)' "$_qf_tx" "$_qf_rx" ;;
		esac
		echo
	done
	[ -n "$_qf_any" ] || echo "qmi-интерфейсов нет - проверка не нужна"
}

# ПОДМЕНА TTL: НАСТРОЕНА ЛИ И ПРИМЕНЕНА ЛИ.
#
# Частый и незаметный класс отказов: у оператора включена блокировка раздачи
# (у Yota она жёсткая), человек ставит галочку TTL в интерфейсе, а правила по
# факту не создаются - и картина выглядит как «сессия есть, адрес есть, трафика
# нет». По конфигу этого не видно вовсе, поэтому смотрим ЖИВЫЕ правила: наша
# таблица inet modem5g_ttl и счётчики попаданий. Ноль пакетов при включённой
# подмене - тоже улика (правило есть, но трафик мимо него).
ttl_verdict() {
	_t_on=$(uci -q get 5gmodem.@5gmodem[0].show_ttl)
	_t_in=$(uci -q get 5gmodem.@5gmodem[0].ttl4in)
	_t_out=$(uci -q get 5gmodem.@5gmodem[0].ttl4out)
	if [ "$_t_on" != "1" ] || { [ -z "$_t_in" ] && [ -z "$_t_out" ]; }; then
		echo "подмена TTL выключена в настройках - раздел не применим"
		echo "  (если оператор режет раздачу, включить её стоит: Сеть -> Модем -> TTL)"
		return 0
	fi
	echo "в настройках: вход=${_t_in:-—} выход=${_t_out:-—}"
	if ! command -v nft >/dev/null 2>&1; then
		echo "  nft в образе нет - проверить живые правила нечем"
		return 0
	fi
	if nft list table inet modem5g_ttl >/dev/null 2>&1; then
		echo "  таблица inet modem5g_ttl СОЗДАНА:"
		nft -a list table inet modem5g_ttl 2>/dev/null | grep -E "ttl set|packets" | head -8
	else
		echo "  таблицы inet modem5g_ttl НЕТ - подмена включена, но НЕ ПРИМЕНЕНА."
		echo "  Это и есть причина, если оператор блокирует раздачу: правила"
		echo "  создаёт /usr/share/5gmodem/ttl.sh, посмотрите logread на предмет его ошибок."
	fi
}

# APN: СОВПАДАЕТ ЛИ С БАЗОЙ ДЛЯ ЭТОЙ SIM.
#
# Самая частая причина «модем зарегистрирован, а IP нет» - не тот APN. По логам
# это неотличимо от поломки: сеть найдена, сигнал есть, а сессия не встаёт.
# Автоподбор ставит APN сам, но НЕ перетирает значение, если для этой симки он
# уже отрабатывал (штамп apn_imsi) - то есть ручную правку уважает. В итоге
# опечатка в APN живёт сколько угодно и выглядит как отказ программы (живой
# случай 05.08.2026: APN «tt» на симке Тинькофф, база знает «m.tinkoff»; после
# замены связь поднялась сразу).
# Поэтому просто сверяем: что стоит в интерфейсе и что предлагает база.
apn_verdict() {
	_av_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_av_if" ] || { echo "интерфейс модема не настроен - проверка не применима"; return 0; }
	_av_cur=$(uci -q get "network.$_av_if.apn")
	echo "APN в интерфейсе: ${_av_cur:-(пусто)}"
	_av_imsi=$(printf '%s' "$(cat /tmp/5gmodem_snapshot_* 2>/dev/null | head -c 4000)" \
		| sed -n 's/.*"imsi":"\([0-9]\{6,\}\)".*/\1/p' | head -1)
	[ -n "$_av_imsi" ] || _av_imsi=$(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.apn_imsi='\([0-9]*\)'$/\1/p" | head -1)
	if [ -z "$_av_imsi" ]; then
		echo "  IMSI неизвестен - сверить с базой не с чем"
		return 0
	fi
	echo "IMSI: $_av_imsi (PLMN ${_av_imsi%??????????})"
	_av_db=$(awk -F'\t' -v p="${_av_imsi%??????????}" '$1 == p && $7 != "" && $7 != "-" {print $6" -> "$7}' \
		/usr/share/5gmodem/providers.tsv 2>/dev/null | head -3)
	if [ -z "$_av_db" ]; then
		echo "  в базе для этого PLMN записей нет - сверять не с чем"
		return 0
	fi
	echo "  база знает для этой сети:"
	printf '%s\n' "$_av_db" | sed 's/^/    /'
	if printf '%s\n' "$_av_db" | grep -q -- "-> *$_av_cur\$"; then
		echo "  СОВПАДАЕТ - APN из базы"
	else
		echo "  НЕ СОВПАДАЕТ. Если интернета нет, начните отсюда: поставьте APN из"
		echo "  списка выше (Сеть -> Модем -> Настройки соединения) и переподнимите"
		echo "  интерфейс. Автоподбор его не меняет, если APN правили вручную."
	fi
}

fw_zone_verdict() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
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
	# КОГДА ОТВАЛИВАЛОСЬ И ЧТО БЫЛО ПЕРЕД ЭТИМ.
	#
	# Голого счётчика мало: он говорит «модем не держится», но не отвечает на
	# главный вопрос - роняет ли модуль что-то НАШЕ. Разница видна по журналу:
	# наш опрос метрик перед смертью модуля пишет «poll of <порт> is stuck», и
	# если такая строка стоит перед каждым отвалом, подозрение на AT-команды
	# опроса; если отвалы приходят сами по себе - это питание, кабель или
	# прошивка модема. Живой отчёт 03.09.2026 (Rolling RW350-GL): два отвала из
	# двух наблюдаемых шли через 16 и 22 с после подвисшего опроса, и выяснять
	# это пришлось вручную - человека просили останавливать службы и следить за
	# логом. Теперь ответ виден прямо в отчёте.
	logread 2>/dev/null | awk '
		function t2s(t,   a) {
			if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return -1
			split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3]
		}
		/poll of .* is stuck/ {
			s = t2s($4); if (s < 0) next
			st = s; have = 1
			p = $0; sub(/.*poll of /, "", p); sub(/ .*/, "", p)
			port = p; next
		}
		/usb [0-9]+-[0-9.]+: USB disconnect/ {
			now = t2s($4); if (now < 0) next
			d = $0; sub(/.*usb /, "", d); sub(/:.*/, "", d)
			n++
			g = now - st
			if (have && g >= 0 && g <= 120) {
				pre++
				line[n] = sprintf("  %s  usb %-8s опрос %s подвис за %d c до отвала", $4, d, port, g)
			} else {
				line[n] = sprintf("  %s  usb %-8s опрос перед этим не подвисал", $4, d)
			}
		}
		END {
			if (n == 0) exit
			print "последние отвалы (время, устройство, что было перед ним):"
			start = n - 7; if (start < 1) start = 1
			for (i = start; i <= n; i++) print line[i]
			if (pre >= 2 && pre * 2 >= n) {
				print "  ПЕРЕД БОЛЬШИНСТВОМ ОТВАЛОВ ПОДВИСАЛ НАШ ОПРОС МОДЕМА."
				print "  Это надо проверить прежде питания: возможно, модуль роняют AT-команды"
				print "  опроса метрик. Опыт: /etc/init.d/5gmodem-sessionwatch stop, закрыть в"
				print "  браузере страницу «Сеть» (она опрашивает модем тоже) и подождать час."
				print "  Отвалы прекратились - виноват опрос, отчёт с этим наблюдением в issue."
			} else {
				print "  Отвалы с опросом модема не совпадают - причина вне приложения:"
				print "  питание, кабель/переходник или прошивка самого модуля."
			}
		}'
	# УСТРОЙСТВО ЕСТЬ, НО НЕ ЭНУМЕРИРУЕТСЯ - до драйверов дело не доходит, и
	# все прочие разделы честно молчат «модема нет». Приметы в dmesg: серия
	# «device descriptor read ... error -62/-71», «device not accepting
	# address», финал «unable to enumerate USB device»; часто рядом падение
	# high-speed -> full-speed (модем всплывает на шине OHCI). Это физика:
	# питание рывком на старте, кабель/переходник без линий данных, битый
	# модуль. Живой отчёт Cudy TR1200, 19.08.2026 - без этого вердикта отчёт
	# выглядел как «модем не подключён вовсе».
	_uf_en=$(dmesg 2>/dev/null | grep -cE "unable to enumerate USB device|device not accepting address|device descriptor read.*error")
	if [ "${_uf_en:-0}" -ge 3 ]; then
		echo "  ПРОБЛЕМА: устройство на шине есть, но НЕ ЭНУМЕРИРУЕТСЯ ($_uf_en ошибок в dmesg:"
		dmesg 2>/dev/null | grep -E "unable to enumerate|not accepting address|descriptor read.*error" | tail -3 | sed 's/^/    /'
		echo "  ). Это физический уровень - до драйверов и приложения дело не доходит."
		echo "  Лечится железом: короткий качественный кабель без переходников, хаб с"
		echo "  внешним питанием (порту роутера может не хватать тока на старт модема),"
		echo "  проверка модема на ПК. Как только в dmesg появится строка"
		echo "  «new high-speed USB device» - приложение подхватит модем само."
	fi
	# УМЕР САМ КОНТРОЛЛЕР - ЭТО НЕ ПИТАНИЕ, И ГОВОРИТЬ ПРО ПИТАНИЕ ЗДЕСЬ ВРЕДНО.
	#
	# Живой отчёт (Banana Pi R4 Lite, FM350 в RNDIS, 30.07): сначала зависла
	# передача - «rndis_host eth1: NETDEV WATCHDOG: transmit queue 0 timed out
	# 5280 ms», потом ядро попыталось остановить эндпойнт, а контроллер не ответил:
	#   xhci-mtk: xHCI host not responding to stop endpoint command
	#   xhci-mtk: Host halt failed, -110
	#   xhci-mtk: HC died; cleaning up
	# И следом ОДНОВРЕМЕННО отвалились ВСЕ устройства шины (usb 1-1, 2-1, 2-1.2).
	# Признаков просадки при этом НОЛЬ: ни error -71, ни «device descriptor read»,
	# ни over-current. Просадка роняет ОДНО устройство и оставляет эти следы -
	# здесь легла вся шина и не вернулась до перезагрузки.
	#
	# Наш прежний вердикт в такой ситуации уверенно советовал блок питания и
	# кабель, то есть отправлял человека не туда. Проверяем это ПЕРВЫМ.
	if logread 2>/dev/null | grep -qE "HC died|Host halt failed|host controller not responding"; then
		echo "ПРОБЛЕМА: умер САМ USB-контроллер (xHCI), а не модем."
		logread 2>/dev/null | grep -oE "(xhci[^:]*): (HC died[^,]*|Host halt failed, -[0-9]+|xHCI host controller not responding[^,]*)" | tail -3
		echo "Признак: устройства пропали ВСЕ И СРАЗУ, и шина не поднялась до"
		echo "перезагрузки. Это НЕ нехватка питания - при просадке отваливается одно"
		echo "устройство и в логе остаются error -71 / device descriptor read."
		logread 2>/dev/null | grep -qE "NETDEV WATCHDOG.*(rndis|cdc|usb)" && {
			echo "Перед смертью контроллера зависла ПЕРЕДАЧА в сетевом драйвере"
			echo "(NETDEV WATCHDOG, transmit queue timed out) - именно попытка ядра"
			echo "сбросить эндпойнт и добивает контроллер."
		}
		echo "Что имеет смысл: (1) снять USB-автосуспенд -"
		echo "  echo on > /sys/bus/usb/devices/usbN/power/control;"
		echo "(2) поднимать шину без перезагрузки перезагрузкой модулей"
		echo "  (rmmod/modprobe xhci-mtk и драйвера модема);"
		echo "(3) если плата отдаёт все порты одним контроллером (Banana Pi R4 и"
		echo "  родня), смена ПОРТА не поможет - он тот же; помогает только другой"
		echo "  контроллер или другая плата."
		echo "Менять блок питания и кабель тут смысла нет - следов просадки в логе нет."
		return
	fi

	[ "${_uf_n:-0}" -ge 1 ] || return
	echo "ПРОБЛЕМА: устройство пропадало с шины и перечислялось заново."
	echo "Если это происходит ВСКОРЕ ПОСЛЕ подключения к сети - почти наверняка"
	echo "не хватает питания: модем берёт пиковый ток на передаче, и просадка"
	echo "роняет линк. Проверять по порядку: другой USB-порт (лучше USB 3.0),"
	echo "короткий кабель без удлинителей, переходник/хаб С ВНЕШНИМ ПИТАНИЕМ."
	[ "$_uf_sp" = "480" ] && echo "Отдельно: линк поднялся как USB 2.0. Если модем умеет USB 3.0, дело в кабеле или переходнике - контакты SuperSpeed не задействованы."
}

# УСТРОЙСТВО ЕСТЬ НА ШИНЕ, НО КОНТРОЛЛЕР НЕ СМОГ ЕГО НАСТРОИТЬ.
#
# Живой случай (ZBT, 02.08.2026): два FM350 и две Sierra EM7565 на одном
# xhci-mtk. В lsusb видны все четыре, в программе - три, и какой именно исчезнет,
# решает порядок энумерации: до перезагрузки не было обеих Sierra, после -
# одного FM350. В журнале ядра:
#   usb 2-1.1: Not enough host controller resources for new device state.
#   usb 2-1.1: can't set config #1, error -12
# Контроллер вернул на команду Configure Endpoint статус RESOURCE_ERROR, то есть
# у него кончились конечные точки. Без конфигурации у устройства нет ИНТЕРФЕЙСОВ,
# значит ни один драйвер к нему не цепляется, портов не появляется - и для
# listmodems.sh (он перечисляет модемы по узлам в /dev) модема просто нет.
#
# Отчёт при этом молчал: «переподключений: 0», ни одного признака беды. Человек
# идёт искать просадку питания, которой нет, и винит программу. Поэтому спрашиваем
# sysfs прямо: конфигурация не назначена - скажем об этом словами и покажем, кто
# съел бюджет (число интерфейсов у каждого устройства на шине).
usb_unconfigured_verdict() {
	_uu_bad=""
	for _uu_d in /sys/bus/usb/devices/*; do
		_uu_b=${_uu_d##*/}
		# каталоги интерфейсов (1-1.3:1.0) и корневые хабы (usb1) - не устройства
		case "$_uu_b" in *:*|usb*) continue ;; esac
		[ -f "$_uu_d/idVendor" ] || continue
		_uu_cfg=$(cat "$_uu_d/bConfigurationValue" 2>/dev/null)
		case "$_uu_cfg" in ''|0) ;; *) continue ;; esac
		_uu_bad="$_uu_bad $_uu_b"
	done
	if [ -z "$_uu_bad" ]; then
		echo "устройств без конфигурации нет - раздел не применим"
		return
	fi
	for _uu_b in $_uu_bad; do
		_uu_d="/sys/bus/usb/devices/$_uu_b"
		echo "$_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] $(cat "$_uu_d/product" 2>/dev/null)"
		echo "  конфигурация НЕ назначена - интерфейсов нет, драйверы не подключены"
	done
	echo "ПРОБЛЕМА: устройство физически на шине (его видно в lsusb), но ядро не"
	echo "смогло его настроить. Портов у него нет, поэтому в списке модемов его тоже нет."
	# Была ли по этому устройству НАША перепривязка (mm_recover_missing)? Тогда
	# это, скорее всего, ЕЁ след, а не «само сломалось»: unbind/bind не вернул
	# устройство (config #1 error -71). Не выдаём ложное «это НЕ ошибка приложения».
	_uu_rb=""
	for _uu_b in $_uu_bad; do
		_uu_k=$(printf '%s' "$_uu_b" | tr -c 'A-Za-z0-9' '_')
		{ [ -f "/var/run/5gmodem-mm-inhibit/$_uu_k.rebindfail" ] || \
		  [ -f "/tmp/5gmodem_mmrebind_$_uu_k" ]; } && _uu_rb=1
	done
	if [ -n "$_uu_rb" ]; then
		echo "ВНИМАНИЕ: приложение НЕДАВНО перепривязывало это USB-устройство"
		echo "(mm_recover_missing: ModemManager не собрал модем). Похоже, unbind/bind"
		echo "не вернул устройство - обычно это 'can't set config #1, error -71'."
		echo "ЛЕЧЕНИЕ: ОБЕСТОЧИТЬ роутер (вынуть питание на несколько секунд, не reboot)."
		echo "Для такого модема стоит выбрать прото QMI вместо ModemManager - тогда"
		echo "перепривязка его больше не тронет."
	else
		echo "Это НЕ ошибка приложения и НЕ питание."
	fi
	_uu_why=$(dmesg 2>/dev/null | grep -E "Not enough host controller resources|Not enough bandwidth|can't set config" | tail -4)
	[ -n "$_uu_why" ] && { echo "Из журнала ядра:"; printf '%s\n' "$_uu_why" | sed 's/^/  /'; }
	if dmesg 2>/dev/null | grep -q "Not enough host controller resources"; then
		echo "Причина названа ядром прямо: у КОНТРОЛЛЕРА кончились ресурсы"
		echo "(конечные точки). Кто их занял - видно по числу интерфейсов:"
		for _uu_d in /sys/bus/usb/devices/*; do
			_uu_b=${_uu_d##*/}
			case "$_uu_b" in *:*|usb*) continue ;; esac
			[ -f "$_uu_d/idVendor" ] || continue
			_uu_n=0
			for _uu_i in "$_uu_d":*; do [ -d "$_uu_i" ] && _uu_n=$((_uu_n + 1)); done
			echo "  $_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] интерфейсов: $_uu_n"
		done
		echo "Модули с RNDIS и россыпью ttyUSB (Fibocom FM350 - 10 интерфейсов,"
		echo "7 из них последовательные) стоят дороже всех; модем в MBIM - 2."
		echo "Что имеет смысл: (1) снять с этого контроллера лишнее устройство;"
		echo "(2) учесть, что РАЗНЫЕ ХАБЫ и даже разные bus одного контроллера"
		echo "  бюджет НЕ делят - смена разъёма сама по себе не лечит;"
		echo "(3) сменить композицию на более скромную, если модуль это умеет"
		echo "  (у FM350 обе композиции, 40 и 41, одинаково прожорливы)."
	elif dmesg 2>/dev/null | grep -q "Not enough bandwidth"; then
		echo "Ядро назвало причиной нехватку ПОЛОСЫ шины, а не ресурсов контроллера:"
		echo "устройству не хватило периодической пропускной способности. Помогает"
		echo "развести устройства по разным контроллерам или снизить скорость линка."
	fi
}

# МОДЕМ ЗАВИС В FASTBOOT (загрузчик вместо рабочей композиции).
# В списке модемов его нет вовсе, портов нет, и отчёт выглядит так, будто модем
# не подключён - хотя lsusb его показывает, просто под ДРУГИМ pid. Живой случай:
# Dell DW5821e в слоте M.2 у Huasifei WH3000 Pro - на плате пин сброса (67)
# притянут к земле, и модем стартует в загрузчик после каждого ребута.
fastboot_verdict() {
	# vid:pid загрузчиков рядом с рабочими: 413c:81e1 - DW5821e (рабочий 81e0),
	# 413c:81e6 - DW5829e (рабочий 81e5). Список открытый: у других моделей свои.
	# ПО SYSFS, а не lsusb: usbutils на роутерах чаще НЕТ, ошибка глоталась
	# 2>/dev/null, и вердикт врал «не видно» ровно в живом случае (WH3000 Pro +
	# DW5821e-eSIM в fastboot, 18.08.2026). Вторая примета - для НЕизвестных
	# загрузчиков: единственный vendor-интерфейс subclass 42 protocol 03
	# (fastboot) без драйвера.
	_fb=""
	_fb_nl='
'
	for _fb_d in /sys/bus/usb/devices/[0-9]*; do
		[ -f "$_fb_d/idVendor" ] || continue
		_fb_id="$(cat "$_fb_d/idVendor" 2>/dev/null):$(cat "$_fb_d/idProduct" 2>/dev/null)"
		case "$_fb_id" in
			413c:81e1|413c:81e6|05c6:9008|1199:9070)
				_fb="$_fb  $_fb_id $(cat "$_fb_d/manufacturer" 2>/dev/null) $(cat "$_fb_d/product" 2>/dev/null)$_fb_nl" ;;
			*)
				if [ "$(cat "$_fb_d/bNumInterfaces" 2>/dev/null | tr -d ' ')" = "1" ]; then
					for _fb_i in "$_fb_d":*.0; do
						[ -f "$_fb_i/bInterfaceSubClass" ] || continue
						[ "$(cat "$_fb_i/bInterfaceClass" 2>/dev/null)" = "ff" ] || continue
						[ "$(cat "$_fb_i/bInterfaceSubClass" 2>/dev/null)" = "42" ] || continue
						[ "$(cat "$_fb_i/bInterfaceProtocol" 2>/dev/null)" = "03" ] || continue
						[ -e "$_fb_i/driver" ] && continue
						_fb="$_fb  $_fb_id $(cat "$_fb_d/manufacturer" 2>/dev/null) $(cat "$_fb_d/product" 2>/dev/null) (fastboot-композиция)$_fb_nl"
					done
				fi ;;
		esac
	done
	if [ -z "$_fb" ]; then
		echo "модемов в режиме загрузчика не видно"
		return
	fi
	printf '%s' "$_fb"
	echo "ПРОБЛЕМА: устройство отдаёт композицию ЗАГРУЗЧИКА (fastboot/EDL), а не"
	echo "модема - поэтому портов нет и в списке модемов оно не появляется."
	echo "На плате Huasifei WH3000 Pro (слот M.2) причина аппаратная - пин 67"
	echo "прижат к земле, и модем уходит в загрузчик при КАЖДОЙ загрузке."
	echo "С версии 2.4.27 приложение выводит такой модем из загрузчика САМО,"
	echo "без пакета fastboot (его в штатных фидах OpenWrt нет): команда"
	echo "протокола шлётся через usb-serial (hotplug, не чаще раза в минуту,"
	echo "до 3 попыток; выключатель: uci set"
	echo "5gmodem.@5gmodem[0].fastboot_rescue='0'). EDL (05c6:9008) не"
	echo "трогается никогда. В загрузчик приложение не переводит: прошивочные"
	echo "режимы - не наша зона."
}

# МОДЕМ СПИТ (power-state: low).
# Причина неочевидная: интерфейс бесконечно пересоздаётся, в журнале сыплется
# «couldn't enable the modem: Invalid transition», и выглядит это как поломка
# протокола. На деле у модема выключено радио: ModemManager пытается поднять
# питание, модем отвечает OperationNotAllowed, включение падает, netifd повторяет
# попытку каждые пару секунд. Единственный признак - одна строка в mmcli, которую
# в длинном выводе легко пропустить (живой отчёт: Dell DW5821e на Radxa ROCK 5T).
power_state_verdict() {
	command -v mmcli >/dev/null 2>&1 || { echo "mmcli нет - проверить нечем"; return; }
	_ps_i=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
	[ -n "$_ps_i" ] || { echo "модем не зарегистрирован в ModemManager - проверка не нужна"; return; }
	_ps_k=$(mmcli -m "$_ps_i" -K 2>/dev/null)
	_ps_p=$(printf '%s\n' "$_ps_k" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
	_ps_s=$(printf '%s\n' "$_ps_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
	echo "power-state: ${_ps_p:-?}   state: ${_ps_s:-?}"
	case "$_ps_p" in
		low|off)
			# АППАРАТНЫЙ РУБИЛЬНИК - отдельный вердикт. Прошивка сообщает MM, что
			# радио выключено пином W_DISABLE# (M.2). Софтом это не лечится ВООБЩЕ:
			# любые записи отскакивают (MBIM OperationNotAllowed, QMI FwWriteFailed,
			# MM Invalid transition), при этом ЧТЕНИЯ живы - AT отвечает CFUN=1,
			# dms-get-operating-mode отдаёт online, и картина выглядит как
			# «прошивка сошла с ума». Живой случай: DW5821e на Radxa ROCK 5T за
			# USB-хабом - хаб делил 500 мА EHCI-порта, модем в пике тянет >1 А,
			# и адаптер прижимал W_DISABLE. Строка в логе MM - единственная улика,
			# и появляется она только с --log-level=INFO.
			if logread 2>/dev/null | grep -q "hardware radio switch is OFF"; then
				echo "ПРОБЛЕМА (АППАРАТНАЯ): прошивка сообщает, что радио выключено"
				echo "аппаратным рубильником (пин W_DISABLE# на M.2). Программно это"
				echo "НЕ лечится - не помогут ни AT, ни qmicli, ни перезагрузки."
				echo "Проверьте:"
				echo "  - переключатель/джампер отключения радио на M.2-адаптере;"
				echo "  - питание: модем за USB-хабом делит 500 мА порта, а в пике"
				echo "    тянет больше ампера - подключите адаптер напрямую или через"
				echo "    хаб с внешним питанием;"
				echo "  - после смены питания/порта полностью передёрните модем."
				return
			fi
			echo "ПРОБЛЕМА: радио модема выключено. Пока он в этом состоянии, соединение"
			echo "не поднимется НИКАКИМ протоколом, а в журнале будет бесконечное"
			echo "«couldn't enable the modem: Invalid transition» - это следствие, а не причина."
			echo "Лечится по возрастанию усилий:"
			echo "  mmcli -m $_ps_i --set-power-state-on   (и затем ifup нужного интерфейса)"
			echo "  либо по AT на его порту:  sms_tool -d <порт> at \"AT+CFUN=1\""
			echo "  либо снять питание с модема - часть прошивок выходит из сна только так."
			;;
	esac
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

# МОДЕМ ЕСТЬ, AT-ПОРТ ЕСТЬ, А КАНАЛА QMI НЕТ - ДЕЛО В КОМПОЗИЦИИ USB.
#
# Класс отказа, который проверка накопителя выше НЕ ловит: порты ttyUSB на месте
# (значит модем опознан и переключён), но нет ни cdc-wdm, ни сетевого узла - и
# proto=qmi просто некуда прицепить. У Qualcomm-модулей за это отвечает вендорная
# настройка композиции, и без неё человек бесконечно чинит usb_modeswitch и
# драйверы, хотя лечится это одной AT-командой с последующим передёргом питания
# (модем должен переэнумерироваться).
#
# Сетевой узел проверяем ОТДЕЛЬНО: часть модулей ходит через ECM/RNDIS без всякого
# cdc-wdm (наш профиль 2c7c:6005 - как раз такой), и для них это норма, а не беда.
usbcomp_verdict() {
	echo ""
	echo "----- Есть AT-порт, но нет канала QMI? (итог) -----"
	_uc_found=""
	for _uc_d in /sys/bus/usb/devices/*; do
		case "$_uc_d" in *:*) continue ;; esac
		[ -f "$_uc_d/idVendor" ] || continue
		_uc_v=$(cat "$_uc_d/idVendor" 2>/dev/null)
		case "$_uc_v" in
			2c7c|1e0e|1bc7) ;;             # Quectel, SimCom, Telit
			*) continue ;;
		esac
		_uc_tty=""; _uc_wdm=""; _uc_net=""
		for _uc_n in "$_uc_d":*/ttyUSB* "$_uc_d":*/tty/ttyUSB*; do
			[ -e "$_uc_n" ] && { _uc_tty=1; break; }
		done
		for _uc_n in "$_uc_d":*/usbmisc/cdc-wdm*; do
			[ -e "$_uc_n" ] && { _uc_wdm=1; break; }
		done
		for _uc_n in "$_uc_d":*/net/*; do
			[ -e "$_uc_n" ] && { _uc_net=1; break; }
		done
		[ -n "$_uc_tty" ] || continue
		[ -z "$_uc_wdm" ] && [ -z "$_uc_net" ] || continue
		_uc_found="$_uc_found
   $(basename "$_uc_d")  $_uc_v:$(cat "$_uc_d/idProduct" 2>/dev/null)"
	done
	if [ -z "$_uc_found" ]; then
		echo "нет - у модемов с AT-портом канал данных на месте"
		return
	fi
	echo "ДА, у модема есть ttyUSB, но нет ни cdc-wdm, ни сетевого узла:"
	printf '   %s\n' $_uc_found
	echo "  Композиция USB не содержит канала данных. Лечится вендорной командой"
	echo "  в AT-консоли, после неё модем нужно передёрнуть ПО ПИТАНИЮ:"
	echo "    Quectel: AT+QCFG=\"usbnet\"      -> должно быть 0, иначе AT+QCFG=\"usbnet\",0"
	echo "    SimCom:  AT+CUSBPIDSWITCH?      -> должно быть 9001, иначе"
	echo "             AT+CUSBPIDSWITCH=9001,1,1"
}

radio_verdict() {   # $1 - АТ-порт
	echo ""
	echo "----- Состояние радио (итог) -----"
	if [ -z "$1" ]; then
		# AT-ПОРТА НЕТ - ЭТО НЕ «ПРОВЕРИТЬ НЕЧЕМ».
		#
		# У целого класса модемов (05c6:9025 и родня в QMI/MBIM-композиции) tty не
		# бывает вовсе, и раздел молча сдавался, хотя ModemManager знает и питание
		# радио, и состояние модема. Живой отчёт с двумя T99W175 (30.07) как раз
		# так и читался: «радио проверить нечем» при полностью рабочем модеме.
		_rvi=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
		if [ -n "$_rvi" ]; then
			_rvk=$(mmcli -m "$_rvi" -K 2>/dev/null)
			_rvp=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
			_rvs=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
			_rvf=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.state-failed-reason *: *//p' | head -1)
			echo "AT-порта нет - состояние берём у ModemManager."
			case "$_rvp" in
				on)  echo "питание радио: on (норма)" ;;
				low) echo "питание радио: LOW POWER - эквивалент CFUN=4, соединение не поднимется" ;;
				off) echo "питание радио: OFF - радио выключено" ;;
				*)   echo "питание радио: ${_rvp:-неизвестно}" ;;
			esac
			echo "состояние модема: ${_rvs:-неизвестно}"
			case "$_rvf" in
				''|--) ;;
				sim-missing) echo "ПРИЧИНА ОТКАЗА: SIM НЕ ОБНАРУЖЕНА - проверить карту и лоток" ;;
				esim-without-profiles)
					echo "ПРИЧИНА ОТКАЗА: АКТИВЕН ПУСТОЙ СЛОТ eSIM - профилей на чипе нет,"
					echo "  и ModemManager отказывается поднимать модем. Лечится переключением"
					echo "  на слот физической SIM (страница «Сеть» -> кнопки SIM/eSIM) либо"
					echo "  загрузкой профиля на чип." ;;
				*) echo "ПРИЧИНА ОТКАЗА: $_rvf" ;;
			esac
			return
		fi
		echo "AT-порта нет, и в ModemManager модема нет - проверить нечем"
		return
	fi
	_rv=$(at_query "$1" "AT+CFUN?" 6 \
		| sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
	case "$_rv" in
		1)  echo "CFUN=1 - радио включено (норма)" ;;
		0)  echo "CFUN=0 - РАДИО ВЫКЛЮЧЕНО: соединение не поднимется ни одним протоколом" ;;
		4)  echo "CFUN=4 - режим полёта: соединение не поднимется" ;;
		'') echo "CFUN не прочитан (порт занят или модем молчит)" ;;
		*)  echo "CFUN=$_rv - НЕ полный режим, ожидается CFUN=1: данные могут не работать" ;;
	esac
}

# ТО ЖЕ САМОЕ, НО БЕЗ ModemManager - ПО AT-ОТВЕТАМ.
#
# Раздел ниже умел спрашивать только MM и на сборке без него писал «не применим»
# ровно там, где ответ лежит в трёх строчках. Живой отчёт (WH3000 Pro, сборка
# lite, 02.08.2026): +CEREG stat 2, +CGATT 0, +CSQ 5 - модем искал сеть с
# отключёнными антеннами, а интерфейс честно не поднимался. Отчёт про это молчал,
# и разбор ушёл в APN, тип PDP и наш прото - то есть мимо.
#
# Команды уже опрошены выше (см. блок at "$P"), здесь только истолкование, но
# спрашиваем заново: между тем блоком и этим местом проходит вся секция MM, а
# состояние сети за это время меняется - истолковывать надо то, что есть сейчас.
at_conn_verdict() {   # $1 - AT-порт
	[ -n "$1" ] || { echo "    AT-порта нет - спросить модем нечем, причину назвать не можем"; return; }
	_ac_reg=$(at_query "$1" "AT+CEREG?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CEREG: *[0-9]*,\([0-9]*\).*/\1/p' | head -1)
	[ -n "$_ac_reg" ] || _ac_reg=$(at_query "$1" "AT+CREG?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CREG: *[0-9]*,\([0-9]*\).*/\1/p' | head -1)
	_ac_att=$(at_query "$1" "AT+CGATT?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CGATT: *\([0-9]*\).*/\1/p' | head -1)
	_ac_csq=$(at_query "$1" "AT+CSQ" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CSQ: *\([0-9]*\).*/\1/p' | head -1)
	_ac_raw_ops=$(at_query "$1" "AT+COPS?" 8 2>/dev/null | tr -d '\r')
	_ac_ops=$(printf '%s\n' "$_ac_raw_ops" \
		| sed -n 's/^+COPS:.*,"\([^"]*\)".*/\1/p' | head -1)
	_ac_copsmode=$(printf '%s\n' "$_ac_raw_ops" \
		| sed -n 's/^+COPS: *\([0-9]*\).*/\1/p' | head -1)

	# УРОВЕНЬ СИГНАЛА СЧИТАЕМ ПО +CSQ И НЕ УМНИЧАЕМ. 99 - «неизвестно»,
	# иначе dBm = -113 + 2*rssi. У FM350 именно +CSQ честен (RSRP он занижает).
	_ac_dbm=""
	case "$_ac_csq" in
		''|99) ;;
		*[!0-9]*) ;;
		*) _ac_dbm=$((-113 + 2 * _ac_csq)) ;;
	esac
	echo "    сигнал: ${_ac_csq:-нет ответа}${_ac_dbm:+ (~${_ac_dbm} dBm)}, оператор: ${_ac_ops:-пусто}, +CGATT: ${_ac_att:-нет ответа}"

	case "$_ac_reg" in
		1|6|9)
			if [ "$_ac_att" = "1" ]; then
				# ИСПРАВНЫЙ СЛУЧАЙ НАЗЫВАЕМ ИСПРАВНЫМ. Раздел спрашивает «почему не
				# подключается», и на живом соединении он не должен выдумывать
				# проблему - иначе разбор уходит искать несуществующее.
				_ac_if=$(uci -q get 5gmodem.@5gmodem[0].network)
				_ac_up=""
				[ -n "$_ac_if" ] && _ac_up=$(ubus call "network.interface.$_ac_if" status 2>/dev/null \
					| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
				if [ -n "$_ac_up" ]; then
					echo "    подключение работает: адрес $_ac_up на интерфейсе $_ac_if - вопрос снят."
				else
					echo "    зарегистрирован и подключён к пакетной сети - радио в норме."
					echo "    Раз адреса всё равно нет, причина дальше: APN, тип PDP или netifd."
				fi
			else
				echo "    зарегистрирован, но к ПАКЕТНОЙ сети не подключён (+CGATT: 0)."
				echo "    Это APN или тип PDP, а не антенны: проверить APN у оператора"
				echo "    и попробовать IPV4V6 - часть модулей на чистом IPV4 не активирует контекст."
			fi ;;
		5|7|10)
			echo "    зарегистрирован В РОУМИНГЕ (stat $_ac_reg). Если тумблер роуминга выключен,"
			echo "    соединение не поднимется намеренно - это защита от счёта за трафик." ;;
		2)
			echo "    СЕТЬ НЕ НАЙДЕНА: модем ищет её (+CEREG stat 2) и не может зарегистрироваться."
			echo "    Никакие APN и типы PDP этого не обойдут - сперва должна появиться сеть." ;;
		3)
			echo "    СЕТЬ ОТКАЗАЛА В РЕГИСТРАЦИИ (+CEREG stat 3). Это не антенны:"
			echo "    так отвечают на незарегистрированную SIM, неоплаченный тариф"
			echo "    или заблокированный IMEI. Проверить ту же SIM в телефоне." ;;
		0|4)
			echo "    НЕ ЗАРЕГИСТРИРОВАН (+CEREG stat ${_ac_reg}) и поиск не идёт."
			# +COPS: 2 - модем ДЕРЕГИСТРИРОВАН КОМАНДОЙ и сам искать сеть не
			# будет никогда. Так остаётся после оборванного дозвона (скрипты
			# xmm/gcom шлют COPS=2 в начале цикла); в другом роутере тот же
			# модем регистрируется сразу - потому что там его никто не
			# дерегистрировал. Живой отчёт 09.08.2026 (L850, МТС).
			if [ "$_ac_copsmode" = "2" ]; then
				echo "    ПРИЧИНА НАЙДЕНА: +COPS: 2 - модем дерегистрирован КОМАНДОЙ."
				echo "    Пока не сказать AT+COPS=0, он не начнёт искать сеть вовсе."
				echo "    Обычно так остаётся после оборванного цикла дозвона (xmm)."
				echo "    Сторож приложения возвращает регистрацию сам; вручную:"
				echo "    sms_tool -d $1 at \"AT+COPS=0\""
			else
				echo "    Смотреть режим сети (не заперт ли на недоступный RAT), диапазоны и CFUN."
			fi ;;
		8)
			echo "    только экстренные вызовы (+CEREG stat 8) - обычной сети для данных нет." ;;
		'')
			echo "    состояние регистрации прочитать не удалось - порт занят или модем молчит." ;;
		*)
			echo "    +CEREG stat $_ac_reg" ;;
	esac

	# АНТЕННЫ. Говорим про них только когда сети нет - при живой регистрации
	# слабый сигнал это «медленно», а не «не подключается», и совет уводил бы вбок.
	case "$_ac_reg" in
		1|5|6|7|9|10) ;;
		*)
			if [ -n "$_ac_dbm" ] && [ "$_ac_dbm" -le -100 ]; then
				echo "    СИГНАЛ НА ПОЛУ (~${_ac_dbm} dBm). Первым делом антенны: прикручены ли,"
				echo "    в те ли разъёмы (main/aux, а не GNSS), цел ли пигтейл."
			fi ;;
	esac
}

# ПОЧЕМУ МОДЕМ НЕ ПОДКЛЮЧАЕТСЯ - ПО ВСЕМ МОДЕМАМ СРАЗУ.
#
# ЗАЧЕМ. ModemManager называет причину отказа одной строкой
# (state-failed-reason), и она решает разбор: «sim-missing» - это карта и лоток, а
# не наше приложение. Но лежит она внутри дампа `mmcli -m N -K` на 200 строк, по
# одному дампу на модем, и найти её удавалось не всегда. Живой случай: у человека
# с двумя T99W175 (30.07) второй модем не работал ровно из-за sim-missing, а
# разбор ушёл в приложение, композиции и питание.
#
# Раздел про ВСЕ модемы, а не про активный: «работает только один из двух» - самая
# частая жалоба на мультимодемной машине, и вердикт должен отвечать про оба.
mm_fail_verdict() {   # $1 - АТ-порт (для модемов вне MM)
	echo ""
	echo "----- Почему модем не подключается (итог) -----"
	if ! command -v mmcli >/dev/null 2>&1; then
		echo "ModemManager не установлен - разбираем по AT:"
		at_conn_verdict "$1"
		return
	fi
	_mf_l=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p')
	# MM установлен, но модема в нём нет - значит он не под MM (наш fibocom,
	# atc, xmm). Молчать здесь нельзя: раздел называется «почему не подключается».
	[ -n "$_mf_l" ] || { echo "в ModemManager нет ни одного модема - разбираем по AT:"; at_conn_verdict "$1"; return; }
	for _mf_i in $_mf_l; do
		_mf_k=$(mmcli -m "$_mf_i" -K 2>/dev/null)
		_mf_d=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.device *: *//p' | head -1)
		_mf_s=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
		_mf_r=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state-failed-reason *: *//p' | head -1)
		_mf_sim=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.sim *: *//p' | head -1)
		echo "### модем $_mf_i (${_mf_d##*/}): состояние $_mf_s"
		case "$_mf_s" in
			connected) echo "    норма - соединение установлено" ;;
			registered|enabled) echo "    радио готово, но сессии данных нет: смотреть APN и netifd" ;;
			failed)
				case "$_mf_r" in
					sim-missing)
						echo "    SIM НЕ ОБНАРУЖЕНА. Это железо, а не настройки:"
						echo "    проверить наличие карты, ориентацию и посадку в лотке,"
						echo "    а на модулях с двумя слотами - что активен тот слот, где карта." ;;
					sim-error|sim-wrong) echo "    ОШИБКА SIM ($_mf_r) - карта не читается: контакты, другая карта" ;;
					esim-without-profiles)
						# Живой отчёт 07.08.2026 (MV31-W, WH3000 Pro): активен слот
						# eSIM, профилей на чипе нет - MM объявляет модем failed и
						# НЕ регистрируется. Снаружи выглядит как «модем в вечном
						# поиске сети», хотя физическая SIM лежит в соседнем слоте.
						echo "    АКТИВЕН ПУСТОЙ СЛОТ eSIM: профилей на чипе нет, и MM"
						echo "    отказывается поднимать модем - отсюда «вечный поиск сети»."
						echo "    Что делать: вернуть активным слот физической SIM (кнопки"
						echo "    SIM/eSIM на странице «Сеть»), а для загрузки профиля"
						echo "    сперва спрятать модем от MM (галка «Скрыть от ModemManager»)."
						echo "    Слоты и их наполнение - в разделе «Слоты SIM» ниже." ;;
					unknown-capabilities) echo "    MM не смог определить возможности модема - обычно AT-only сборка модема (см. раздел про cdc-wdm)" ;;
					''|--) echo "    состояние failed без указанной причины" ;;
					*) echo "    причина отказа: $_mf_r" ;;
				esac ;;
			locked) echo "    модем заблокирован (PIN/PUK) - см. unlock-required в дампе" ;;
			disabled) echo "    модем выключен: netifd его ещё не включал или отключён вручную" ;;
			*) echo "    состояние: $_mf_s" ;;
		esac
		# FCC LOCK ПОД ModemManager. Подпись однозначная: питание радио «low»,
		# состояние застряло в enabling/disabled, а netifd крутит «couldn't
		# enable ... Retry: Invalid transition». Модуль не включит радио, пока
		# хост не пришлёт разблокировку; у MM скрипты ЕСТЬ, но по умолчанию
		# ВЫКЛЮЧЕНЫ (лежат в fcc-unlock.available.d, работают из fcc-unlock.d).
		# Живой случай: DW5821e (413c:81d7) на Radxa ROCK 5T - месяц «модем не
		# заводится», а это два симлинка. Для Dell/Foxconn (413c:81d7,
		# 0489:e0b5, 105b:*) годится скрипт «105b»: его фолбэк
		# dms-foxconn-set-fcc-authentication=0 - штатный метод T77W968/DW5821e.
		_mf_pw=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
		if [ "$_mf_pw" = "low" ] && { [ "$_mf_s" = "enabling" ] || [ "$_mf_s" = "disabled" ] || [ "$_mf_s" = "failed" ]; }; then
			_mf_vp=$(printf '%s\n' "$_mf_k" | sed -n 's#^modem\.generic\.device *: .*/\([0-9.-]*\)$#\1#p' | head -1)
			_mf_vid=""; _mf_pid=""
			if [ -n "$_mf_vp" ] && [ -r "/sys/bus/usb/devices/$_mf_vp/idVendor" ]; then
				_mf_vid=$(cat "/sys/bus/usb/devices/$_mf_vp/idVendor")
				_mf_pid=$(cat "/sys/bus/usb/devices/$_mf_vp/idProduct")
			fi
			echo "    ПОХОЖЕ НА FCC LOCK: питание радио «low», включение не проходит."
			_mf_av=/usr/share/ModemManager/fcc-unlock.available.d
			_mf_en=/etc/ModemManager/fcc-unlock.d
			if [ -d "$_mf_av" ]; then
				_mf_script=""
				[ -n "$_mf_vid" ] && [ -e "$_mf_av/$_mf_vid:$_mf_pid" ] && _mf_script="$_mf_vid:$_mf_pid"
				[ -z "$_mf_script" ] && [ -n "$_mf_vid" ] && [ -e "$_mf_av/$_mf_vid" ] && _mf_script="$_mf_vid"
				# Dell/Foxconn-родня без своего скрипта - подходит foxconn (105b)
				case "$_mf_vid:$_mf_pid" in
					413c:81d7|0489:e0b5) [ -z "$_mf_script" ] && [ -e "$_mf_av/105b" ] && _mf_script=105b ;;
				esac
				if [ -e "$_mf_en/$_mf_vid:$_mf_pid" ]; then
					echo "    скрипт разблокировки УЖЕ включён - причина в другом"
				elif [ -n "$_mf_script" ]; then
					echo "    ЧТО СДЕЛАТЬ (нужен пакет qmi-utils):"
					echo "      mkdir -p $_mf_en"
					echo "      ln -s $_mf_av/$_mf_script $_mf_en/$_mf_vid:$_mf_pid"
					echo "      ifdown у интерфейса модема, /etc/init.d/modemmanager restart, подождать минуту, ifup"
				else
					echo "    готового скрипта под $_mf_vid:$_mf_pid в $_mf_av нет - смотреть свежий ModemManager"
				fi
			fi
		fi
		case "$_mf_sim" in
			''|--) echo "    объект SIM у модема отсутствует - карты нет ни в одном слоте" ;;
		esac
	done
}

# FCC LOCK - модуль не выйдет в эфир, пока его не разблокируют.
#
# ЗАЧЕМ ЭТО В ОТЧЁТЕ. Заблокированный модем выглядит просто сломанным: AT+CFUN=1
# отвечает «+CME ERROR: 0» или «phone failure», по QMI - «Invalid transition», по
# MBIM - «Operation not allowed», интерфейс не встаёт, лампочка на переходнике не
# горит. Причина при этом НИОТКУДА НЕ ВИДНА, и человек ищет её в кабеле, питании,
# прошивке и нашем приложении - то есть везде, кроме нужного места. Три команды
# дают точный ответ, и место им ровно здесь, рядом с «радио выключено».
#
# Блокировка бывает у модулей, предназначенных ноутбукам (Lenovo, Dell, HP); у
# FM350-GL замечена в версиях для Lenovo. Смысл её - привязать модуль к конкретной
# модели ноутбука ради сертификации FCC в США, за пределами этого регулирования
# смысла у неё нет.
#
# Команды фибокомовские. У других вендоров их нет, и это НЕ повод для тревоги -
# тогда просто молчим, а не пишем «проверить не удалось».
fcclock_verdict() {   # $1 - АТ-порт
	echo ""
	echo "----- FCC lock (итог) -----"
	[ -n "$1" ] || { echo "AT-порта нет - проверить нечем"; return; }
	_fl=$(at_query "$1" "AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?" 8)
	_flm=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKMODE: *\([0-9]*\).*/\1/p' | head -1)
	_fls=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKSTATE: *\([0-9]*\).*/\1/p' | head -1)

	if [ -z "$_flm" ]; then
		echo "модем про FCC lock не отвечает - у этого вендора такой блокировки нет"
		return
	fi
	if [ "$_flm" = "0" ]; then
		echo "FCC lock выключен (mode 0) - модем выходит в эфир свободно"
		return
	fi

	# mode 1 - разблокировать нужно ОДИН раз, mode 2 - при каждом включении.
	case "$_flm" in
		1) echo "FCC lock ВКЛЮЧЁН (mode 1: разблокировка нужна однократно)" ;;
		2) echo "FCC lock ВКЛЮЧЁН (mode 2: разблокировка нужна при КАЖДОМ включении)" ;;
		*) echo "FCC lock ВКЛЮЧЁН (mode $_flm)" ;;
	esac
	if [ "$_fls" = "1" ]; then
		echo "Сейчас модем РАЗБЛОКИРОВАН (state 1) - радио работает."
		[ "$_flm" = "2" ] && echo "Но при mode 2 после выключения питания блокировка вернётся."
		return
	fi
	echo "И НЕ РАЗБЛОКИРОВАН (state 0) - ЭТО И ЕСТЬ ПРИЧИНА, если модем не выходит"
	echo "в эфир: AT+CFUN=1 отвечает ошибкой, соединение не поднимается ни одним"
	echo "протоколом, и выглядит это как неисправность железа. Железо цело."
	echo "Разблокировка: AT+GTFCCLOCKGEN даёт challenge, из него считается"
	echo "проверочный код (SHA256 от challenge + vendor hash), затем"
	echo "AT+GTFCCLOCKVER=<код>. Снять навсегда - AT+GTFCCLOCKMODE=0 и"
	echo "переподключить модем. Процедура описана в документации ModemManager;"
	echo "пошаговый вариант - в docs/FM350-reference.md нашего репозитория."
	echo "Приложение само этого НЕ делает: разблокировка - разовое действие"
	echo "владельца, и лезть в неё из веб-морды мы не хотим."
}

# ОБРАЗ ПРОШИВКИ И ПРОФИЛЬ ОПЕРАТОРА У SIERRA (итог).
#
# ЗАЧЕМ ЭТО В ОТЧЁТЕ. У модулей Sierra прошивка и профиль оператора (PRI) -
# ДВЕ РАЗНЫЕ картинки, и модем держит несколько пар сразу: заводскую от
# ноутбучного вендора (ATT, VERIZON, GENERIC) и залитые позже. Что выбрано,
# говорит AT!IMPREF?. Если ЗАЯВЛЕННОЕ (preferred) и ФАКТИЧЕСКОЕ (current) не
# совпали - модем сам печатает строки «fw version mismatch», «carrier name
# mismatch» - и уходит в пониженное питание: радио молчит, регистрации нет,
# ошибок никаких. Живой случай (EM9190, август 2026): обновление прошивки
# успело переставить preferred, но сам образ не залился - и модем «умер», пока
# preferred не вернули на прежнего оператора командой AT!IMPREF="ATT".
#
# Снаружи это неотличимо от мёртвого модема, а причина - одна строка в ответе,
# которую без этой секции никто не увидит.
sierra_image_verdict() {   # $1 - АТ-порт
	[ -n "$1" ] || return 0
	_si=$(at_query "$1" "AT!IMPREF?" 8)
	case "$_si" in
		*IMPREF*) ;;
		*) return 0 ;;   # не Sierra (или команда не поддержана) - молчим
	esac
	echo ""
	echo "----- Sierra: образ прошивки и профиль оператора (итог) -----"
	printf '%s\n' "$_si" | grep -E "version|name|index" | sed 's/^[[:space:]]*/  /'
	if printf '%s' "$_si" | grep -q "mismatch"; then
		echo "РАСХОЖДЕНИЕ: выбранный образ/профиль НЕ СОВПАДАЕТ с загруженным."
		echo "Модем в таком состоянии уходит в пониженное питание: радио молчит,"
		echo "регистрации нет, при этом ни одна команда не ругается. Обычно так"
		echo "заканчивается НЕДОКАЧАННОЕ обновление прошивки - preferred уже"
		echo "переставлен, а сам образ не залит."
		echo "Лечение - вернуть preferred на тот профиль, который РЕАЛЬНО в"
		echo "модеме (строка current), например: AT!IMPREF=\"GENERIC\", и"
		echo "переподключить питание. Список того, что залито: AT!IMAGE?"
	else
		echo "выбранный образ и профиль совпадают с загруженными - норма"
	fi
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

# --- СВОДКА ДЛЯ ЧЕЛОВЕКА -----------------------------------------------------
#
# ЗАЧЕМ. Отчёт вырос до полутора тысяч строк и начинался со списка пакетов - то
# есть с того, что нужно НАМ, а не тому, кто его прислал. Человек не понимал,
# что у него не так, и просто пересылал простыню целиком. Теперь сверху -
# короткая сводка: что за роутер, какая версия программы, какой модем, есть ли
# интернет и один общий вердикт. Всё подробное осталось ниже без изменений.
#
# ПРАВИЛО ЭТОГО БЛОКА: только УЖЕ СОБРАННЫЕ дешёвые источники (uci, ubus, sysfs,
# файлы состояния сторожа). Ни одной новой AT-команды и ни одного запроса в
# порт: сводка не должна ни задерживать отчёт, ни мешать модему.
_sum_verdict() {
	# несём ли трафик
	_sv_def=$(ip -4 route show default 2>/dev/null | head -1)
	_sv_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_sv_ip=""
	[ -n "$_sv_if" ] && _sv_ip=$(ubus call "network.interface.$_sv_if" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -n "$_sv_ip" ] || _sv_ip=$(ubus call "network.interface.${_sv_if}_4" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	# модем на шине?
	_sv_mod=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[0].model' 2>/dev/null)
	if [ -z "$_sv_mod" ]; then
		echo "МОДЕМ НЕ НАЙДЕН на USB-шине. Проверьте питание и подключение;"
		echo "если модем в слоте M.2 - раздел «Модем в режиме загрузчика» ниже."
		return
	fi
	if [ -z "$_sv_ip" ]; then
		echo "Модем найден, но АДРЕСА У НЕГО НЕТ - соединение не поднялось."
		echo "Смотрите разделы «Почему модем не подключается» и «APN: сверка с базой»."
		return
	fi
	if [ -z "$_sv_def" ]; then
		echo "У модема есть адрес ($_sv_ip), но МАРШРУТА ПО УМОЛЧАНИЮ НЕТ -"
		echo "трафик идти некуда. Смотрите раздел «Кто держит интернет»."
		return
	fi
	# есть адрес и маршрут - спросим сторожа, ходят ли пакеты
	_sv_st=""
	[ -n "$_sv_if" ] && [ -f "/tmp/5gmodem_health/$_sv_if" ] \
		&& read -r _sv_st _ _ _ _ 2>/dev/null < "/tmp/5gmodem_health/$_sv_if"
	case "$_sv_st" in
		down) echo "Адрес есть ($_sv_ip), но интернет через модем НЕ ОТВЕЧАЕТ на пробы."
		      echo "Смотрите разделы «Кто держит интернет» и «DNS»." ;;
		up)   echo "Всё в порядке: модем на связи, адрес $_sv_ip, пробы проходят." ;;
		*)    echo "Модем на связи, адрес $_sv_ip. Проверок сторожа пока нет" \
		      "(слежение выключено или роутер только загрузился)." ;;
	esac
}

report() {
	echo "===== luci-app-5gmodem: диагностический отчёт ====="
	echo "Собран: $(date)"
	echo ""
	echo "ВНИМАНИЕ: отчёт содержит идентификаторы модема и SIM (IMEI, IMSI,"
	echo "ICCID, EID) и имя оператора. Пароли и ключи Wi-Fi сюда НЕ попадают."
	echo "Если не хотите публиковать идентификаторы - отправьте файл лично."
	echo ""
	echo "----- КОРОТКО О ГЛАВНОМ -----"
	echo "Роутер:    $(cat /tmp/sysinfo/model 2>/dev/null | head -1)"
	echo "Прошивка:  $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)"
	echo "Программа: $( (apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) \
		| sed -n 's/^\(luci-app-5gmodem[a-z-]*\)[ -]\([0-9][^ ]*\).*/\1 \2/p' | head -1)"
	_sum_m=$("$RES/listmodems.sh" 2>/dev/null)
	echo "Модем:     $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].model' 2>/dev/null) $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].vidpid' 2>/dev/null)"
	echo "Оператор:  $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].operator' 2>/dev/null)"
	echo "Интерфейс: $(uci -q get 5gmodem.@5gmodem[0].network) ($(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null))"
	echo ""
	echo "ВЕРДИКТ:"
	_sum_verdict | sed 's/^/  /'
	echo ""
	echo "Ниже - подробная диагностика. Она нужна разработчику: если всё"
	echo "работает, читать её не обязательно."

	collect "system"
	run 5  "Версия приложения" sh -c "(apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | grep -iE '5gmodem|sms-tool|modemmanager|lpac|ca-bundle|libcurl|qmi-utils|mbim-utils|libmbim|libqmi|umbim|uqmi|comgt'"
	run 5  "Прошивка" cat /etc/openwrt_release
	run 5  "Модель железа" sh -c "cat /tmp/sysinfo/model 2>/dev/null; cat /proc/device-tree/model 2>/dev/null"
	run 5  "Uptime / память" sh -c "uptime; free"
	run 5  "Время (важно для TLS eSIM)" sh -c "date; echo 'UTC:'; date -u"

	collect "config"
	run 5  "uci 5gmodem" uci -q show 5gmodem
	run 5  "uci 5gmodem (SMS-раздел)" sh -c "uci -q show 5gmodem | grep -E '\.sms\.' || echo '(секция sms пуста)'"
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

	# ПОЧЕМУ У МОДЕМА НЕТ AT-ПОРТОВ.
	#
	# У части композиций (05c6:9025/90d5/90d6) ttyUSB появляются только после
	# ручной привязки через new_id, и мы её НАМЕРЕННО пропускаем, если у модема уже
	# поднят канал данных (usbserial_generic жадный и способен отобрать интерфейс у
	# qmi_wwan - см. usbports.sh). Решение верное, но снаружи оно неотличимо от
	# поломки: «портов нет», радио «проверить нечем», бенды «Port not found». Живой
	# отчёт с двумя T99W175 на ZBT (30.07) разбирался именно об это.
	run 10 "Привязка AT-портов (итог)" sh -c '
		N=0
		for d in /sys/bus/usb/devices/*; do
			[ -f "$d/idVendor" ] || continue
			v=$(cat "$d/idVendor"); p=$(cat "$d/idProduct")
			case "$v:$p" in
				05c6:9025|05c6:90d5|05c6:90d6) ;;
				*) continue ;;
			esac
			N=$((N+1))
			t=""
			for f in "$d":*/ttyUSB* "$d":*/tty/ttyUSB*; do [ -e "$f" ] && t="$t $(basename "$f")"; done
			echo "$(basename "$d") [$v:$p] порты:${t:- НЕТ}"
		done
		[ "$N" = 0 ] && { echo "модемов с ручной привязкой портов нет - раздел не применим"; exit 0; }
		echo "--- журнал привязки ---"
		logread 2>/dev/null | grep "5gmodem-usbports" | tail -10 || echo "(записей нет - скрипт привязки не отработал)"
		if logread 2>/dev/null | grep -q "канал данных уже поднят"; then
			echo "ИТОГ: привязка пропущена НАМЕРЕННО - у модема уже поднят cdc-wdm/сеть."
			echo "Это защита связи: usbserial_generic при переподключении отбирает интерфейс"
			echo "у qmi_wwan, и модем остаётся без канала данных (issue #8)."
			echo "Цена: нет AT-порта -> нет подробностей по диапазонам, чтения SIM по AT и eSIM по AT."
			echo "Для этих модемов данные надо брать по QMI/MBIM - см. разделы QMI-дополнения и eSIM: транспорт APDU."
		fi'

	collect "mm"
	# На lite-пакете ModemManager отсутствует по определению - честная строка
	# вместо сырого «mmcli: not found» в отчёте (живой отчёт TR1200, 19.08.2026).
	run 15 "mmcli -L" sh -c 'command -v mmcli >/dev/null && mmcli -L || echo "mmcli не установлен (пакет modemmanager) - для lite-сборки это норма"'
	# Индексы берём из mmcli -L, а не наугад "-m 0": индекс меняется при каждом
	# рестарте MM, а на мёртвой шине "-m 0" просто висит до таймаута.
	run 40 "Модемы в MM (детально)" sh -c "mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | while read -r i; do echo \"### модем \$i\"; mmcli -m \"\$i\" -K 2>&1 | grep -viE 'password|\.pin'; done"
	# ВАЖНО: у mm-inhibit.sh НЕТ команды status - неизвестный аргумент попадает в
	# ветку "*)", а это ДЕМОН (while :; sleep 15). Вызов отсюда запускал бы лишнего
	# держателя инхибиции. Читаем состояние напрямую: pid-файлы + флаги в uci.
	run 5  "Инхибиция (наша)" sh -c "echo '--- активные держатели ---'; for f in /var/run/5gmodem-mm-inhibit/*.pid; do [ -f \"\$f\" ] || continue; p=\$(cat \"\$f\"); kill -0 \"\$p\" 2>/dev/null && echo \"\$(basename \"\$f\" .pid): pid \$p (жив)\" || echo \"\$(basename \"\$f\" .pid): pid \$p (мёртв)\"; done; echo '--- флаги mm_exclude ---'; uci -q show 5gmodem | grep mm_exclude || echo '(не задано)'"
	run 5  "Автозапуск MM" sh -c "[ -x /etc/init.d/modemmanager ] || { echo 'ModemManager не установлен'; exit 0; }; /etc/init.d/modemmanager enabled && echo 'включён' || echo 'выключен'"

	collect "at"
	P=$("$RES/detect.sh" 2>/dev/null)
	echo ""
	echo "AT-порт для опроса: ${P:-(не найден)}"
	# ЖИВОЙ ДОЗВОНЩИК НА ПОРТУ ДЕЛАЕТ AT-ОТВЕТЫ МУСОРОМ: gcom (прото xmm/atc)
	# не знает про нашу очередь, ответы воруются в обе стороны и приходят со
	# сдвигом на команду. По такому мусору дальше строятся ложные вердикты
	# (живой отчёт 09.08.2026: фантомная «привязка к соте» на L850). Порт
	# уступаем, а в отчёте говорим прямо - это ценный факт: передозвон
	# крутится прямо сейчас.
	if [ -n "$P" ] && at_dialer_busy "$P" 2>/dev/null; then
		echo ""
		echo "ВНИМАНИЕ: на порту прямо сейчас работает дозвонщик netifd (gcom)."
		echo "AT-опрос пропущен: при наложении ответы перемешиваются, и по ним"
		echo "выходят ложные диагнозы. Сам факт важен: интерфейс в цикле"
		echo "передозвона - смотреть журнал netifd (logread | grep netifd)."
		P=""
	fi
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
	mm_fail_verdict "$P"
	fcclock_verdict "$P"
	sierra_image_verdict "$P"
	proxy_verdict
	stick_verdict
	usbcomp_verdict
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
	# QMI-ДОПОЛНЕНИЯ. У модема без AT-порта (или под ModemManager) текущий
	# диапазон, полоса и RSRP приходят ТОЛЬКО отсюда, и когда в карточке стоит
	# голое «4G» без подробностей, вопрос ровно один: qmicli вообще есть и что он
	# отвечает по этому узлу. По отчёту это было не видно - ни бинарника, ни
	# вывода (живой случай: два T99W175 на ZBT, 30.07).
	run 20 "QMI-дополнения (диапазон/сигнал)" sh -c '
		command -v qmicli >/dev/null 2>&1 || { echo "qmicli НЕ УСТАНОВЛЕН (пакет qmi-utils) - диапазон и RSRP брать неоткуда"; exit 0; }
		W=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
		[ -c "$W" ] || { echo "у активного модема нет своего cdc-wdm - QMI-дополнений не будет"; exit 0; }
		echo "узел: $W"
		. /usr/share/5gmodem/lib.sh 2>/dev/null
		if command -v qmi_channel_free >/dev/null 2>&1 && ! qmi_channel_free; then
			echo "канал занят netifd (kernel-прото qmi/qmiraw/mbim) - опрос намеренно пропущен, связь дороже"
			exit 0
		fi
		echo "--- rf-band-info ---"; qmicli -d "$W" -p --nas-get-rf-band-info 2>&1 | head -20
		echo "--- signal-info ---";  qmicli -d "$W" -p --nas-get-signal-info 2>&1 | head -20'
	run 5  "lpac установлен?" sh -c "ls -l /usr/bin/lpac /usr/lib/lpac 2>/dev/null; echo '--- зависимости ---'; ldd /usr/lib/lpac 2>/dev/null"
	# HTTPS к SM-DP+ - самая частая причина, почему СПИСОК профилей обновляется
	# (это чистый APDU), а ЗАГРУЗКА профиля молча не идёт: нет ca-bundle, кривое
	# время или lpac собран без HTTP-бэкенда.
	run 5  "CA-сертификаты (нужны для загрузки профиля)" sh -c "ls -l /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'ca-bundle НЕ УСТАНОВЛЕН -> загрузка профиля eSIM работать не будет'"
	run 5  "HTTP-бэкенд в lpac" "$RES/esim.sh" httpinfo
	run 15 "Проверка HTTPS наружу" sh -c "curl -sS -o /dev/null -w 'код=%{http_code} tls=%{ssl_verify_result} время=%{time_total}s\n' https://ya.ru 2>&1 | head -3"
	# ЧЕМ ХОДИТ МОСТ APDU. Он написан под GNU wget (wget-ssl): --method,
	# --body-file, -S. busybox-wget этих ключей не знает и печатает СПРАВКУ
	# вместо запроса - в отчёте это выглядело как «transport failed» с текстом
	# man-страницы в поле причины, и распознать причину было нельзя (живой лог
	# 06.08.2026, FM350 на чистой прошивке). Теперь при busybox уходим на curl,
	# но GNU wget всё равно предпочтительнее: curl с mbedTLS не тянет часть
	# цепочек GSMA CI. Показываем, что есть на роутере.
	run 5  "HTTP-клиент для eSIM (wget/curl)" sh -c '
		_w=$(wget --version 2>/dev/null | head -1)
		case "$_w" in
			*"GNU Wget"*) echo "wget: $_w - подходит для загрузки профиля" ;;
			*) echo "wget: busybox (нет --method/--body-file) - мост пойдёт через curl"
			   echo "  для самой надёжной загрузки профиля: apk add wget-ssl" ;;
		esac
		if command -v curl >/dev/null 2>&1; then
			echo "curl: $(curl --version 2>/dev/null | head -1)"
		else
			echo "curl: НЕ УСТАНОВЛЕН - если wget тоже busybox, загрузка профиля невозможна"
		fi'
	collect "esim"
	run 5  "eSIM: конфиг lpac (порт AT/uqmi)" sh -c "uci -q show lpac 2>/dev/null; echo '--- custom AID ---'; uci -q get lpac.global.custom_isd_r_aid 2>/dev/null || echo '(по умолчанию A0000005591010FFFFFFFF8900000100)'"
	# ЧЕМ ХОДИМ К eUICC. Транспорт APDU выбирается автоматически по протоколу и
	# драйверу узла, и ошибка выбора выглядит снаружи неотличимо от «eSIM нет»:
	# code -1 "euicc_init" и «модем без eUICC». Печатаем выбор явно.
	run 10 "eSIM: транспорт APDU" "$RES/esim.sh" apduinfo
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
		# Sierra (1199:*): CCHO/CCHC в tty НЕ шлём. На EM9190 эта проба
		# подвесила SIM-подсистему намертво (subscriber timeout) - не лечилось
		# даже питанием, только физическим перетыком карты (живой случай
		# 18.08.2026). eUICC у Sierra достаётся по QMI/MBIM, AT-мост там не
		# путь, так что проба и не нужна.
		VP=$(uci -q get "5gmodem.m_$(echo "$P" | sed "s/[^A-Za-z0-9]/_/g").vidpid" 2>/dev/null)
		case "$VP" in
			1199:*)
				echo "Sierra ($VP): CCHO-проба пропущена - на EM9190 она подвешивала SIM-подсистему до перетыка карты; eUICC у Sierra живёт за QMI/MBIM, не за AT"
				exit 0 ;;
		esac
		# АКТИВНА ФИЗИЧЕСКАЯ SIM - ПЕРЕБОР БЕССМЫСЛЕН, И ЭТО НАДО СКАЗАТЬ.
		# Канал к карте у модема один: пока активен слот физической SIM, ISD-R
		# eUICC недостижим, и CCHO молчит на ВСЕХ портах. Отчёт при этом
		# выглядел как «модем не поддерживается» (жалоба 30.08.2026 по FM350 с
		# распаянной eUICC) - хотя лечится переключением слота.
		SL=$(/usr/share/5gmodem/simslot.sh status 2>/dev/null)
		SLA=$(printf "%s" "$SL" | jsonfilter -e "@.active" 2>/dev/null)
		SLE=$(printf "%s" "$SL" | jsonfilter -e "@.slots[@.label=\"eSIM\"].id" 2>/dev/null | head -1)
		echo "активный слот SIM: $(printf "%s" "$SL" | grep -o "\"active\":\"[^\"]*\"")"
		if [ -n "$SLE" ] && [ -n "$SLA" ] && [ "$SLE" != "$SLA" ]; then
			echo "активен слот физической SIM ($SLA), eSIM - слот $SLE: канал к карте у модема ОДИН, поэтому ISD-R eUICC сейчас недостижим и CCHO не откроется НИ НА ОДНОМ порту. Это не признак отсутствия чипа - переключите слот на eSIM и повторите."
			exit 0
		fi
		echo "порты модема $P:"
		for t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null); do
			for c in 1 2 3 4; do sms_tool -d "$t" at "AT+CCHC=$c" >/dev/null 2>&1; done
			R=$(sms_tool -d "$t" at "AT+CCHO=\"$AID\"" 2>/dev/null | tr -d "\r" | grep -v "^$" | grep -vi "^at+ccho" | head -1)
			case "$R" in
				*CCHO:*|[0-9]*) echo "  $t -> ОТКРЫЛСЯ КАНАЛ [$R]  <= это eUICC-порт" ;;
				*) echo "  $t -> нет ([$R])" ;;
			esac
		done'
	# ТРИ САМЫХ ДОРОГИХ ШАГА ОТЧЁТА (60+90+60 c бюджета - треть всего). Гоняем их
	# только когда у eSIM есть хоть какой-то путь до чипа. Без lpac пути нет
	# вовсе; при AT-транспорте нужен tty, и на модеме без единого порта все три
	# шага гарантированно упрутся в "no AT port", отняв минуты. Человек с двумя
	# T99W175 (30.07) именно на этом месте решил, что диагностика повисла.
	_ES_SKIP=""
	if [ ! -x /usr/bin/lpac ]; then
		_ES_SKIP="lpac не установлен"
	elif [ "$("$RES/esim.sh" apduinfo 2>/dev/null | sed -n 's/^выбранный APDU-бэкенд: //p')" = "at" ] \
	     && [ -z "$("$RES/registry.sh" active 2>/dev/null | jsonfilter -e '@.tty[*]' 2>/dev/null)" ]; then
		_ES_SKIP="транспорт APDU=at, а у активного модема нет ни одного tty"
	fi
	if [ -n "$_ES_SKIP" ]; then
		run 5 "eSIM: статус/профили/уведомления" echo "пропущено: $_ES_SKIP"
	else
		run 60 "eSIM: статус" "$RES/esim.sh" status-probe
		run 90 "eSIM: профили и чип" "$RES/esim.sh" dump
		run 60 "eSIM: уведомления" "$RES/esim.sh" notifications
	fi

	collect "net"
	run 10 "Маршруты" sh -c "ip route; echo '--- ipv6 ---'; ip -6 route"
	# ПЕРВЫЙ ВОПРОС ЖАЛОБЫ «ИНЕТА НЕТ» - кто держит трафик и жив ли он. Стоит
	# сразу за маршрутами: дальше по отчёту читателя уносит в модемы, а причина
	# чаще здесь (аплинк с адресом, но без выхода) и в DNS ниже.
	run 40 "Кто держит интернет (итог)" uplink_verdict
	run 60 "DNS: резолвинг и rebind (итог)" dns_verdict
	run 40 "QMI: формат кадров и счётчики (итог)" qmi_format_verdict
	run 10 "uci firewall (зоны)" sh -c "uci show firewall 2>/dev/null | grep -E 'zone|forwarding' | head -40"
	run 10 "Зона wan и NAT (итог)" fw_zone_verdict
	run 15 "APN: сверка с базой (итог)" apn_verdict
	run 15 "Подмена TTL (итог)" ttl_verdict
	run 15 "Доступ к админке (итог)" webstack_verdict
	run 15 "Policy routing / mwan3 (итог)" policyrouting_verdict
	# МИНЫ ЗАМЕДЛЕННОГО ДЕЙСТВИЯ: незакоммиченные правки uci. Дельты лежат в общем
	# /tmp/.uci и применяются ЧУЖИМ коммитом - спустя часы, из другого кода. Смена
	# lan.ipaddr, застрявшая здесь, выглядит потом как «роутер сам сломался»
	# (живой симптом: пинга до роутера нет, инет есть). Если тут что-то есть -
	# вот оно и есть главная улика.
	run 10 "Незакоммиченные правки uci (мины)" sh -c 'uci changes 2>/dev/null | head -40; [ -z "$(uci changes 2>/dev/null)" ] && echo "(пусто - мин нет)"'
	run 10 "Питание и стабильность USB (итог)" usb_flap_verdict
	run 10 "Устройство на шине, но без конфигурации? (итог)" usb_unconfigured_verdict
	run 15 "usb_modeswitch сломал композицию? (итог)" usbmode_verdict
	run 10 "Модем в режиме загрузчика? (итог)" fastboot_verdict
	run 20 "Питание радио модема (итог)" power_state_verdict
	run 10 "Пинг 77.88.8.8" ping -c 3 -W 2 77.88.8.8
	# IPv6-связность ЛИТЕРАЛОМ (без DNS - его при глушении тоже режут): Яндекс-DNS
	# 2a02:6b8::feed:0ff - v6-аналог 77.88.8.8. ipv6-internet.yandex.net не резолвится.
	run 10 "Пинг IPv6 (2a02:6b8::feed:0ff)" sh -c "ping6 -c 3 -W 2 2a02:6b8::feed:0ff 2>/dev/null || ping -6 -c 3 -W 2 2a02:6b8::feed:0ff"
	run 20 "Лог: ModemManager" sh -c "logread 2>/dev/null | grep -i modemmanager | tail -80"
	run 20 "Лог: netifd/интерфейсы" sh -c "logread 2>/dev/null | grep -iE 'netifd|wwan|qmi|mbim|fibocom' | tail -80"
	run 20 "Лог: ядро (USB)" sh -c "dmesg 2>/dev/null | grep -iE 'usb|option|qmi_wwan|cdc_|reset' | tail -60"
	run 20 "Лог: весь хвост" sh -c "logread 2>/dev/null | tail -120"

	# Расшифровка кодов +CME ERROR, попавшихся ВЫШЕ по отчёту и в журнале.
	# Голое «+CME ERROR: 133» не говорит ничего даже нам; таблица общая
	# (см. cme.sh), поэтому раздел стоит копейки и закрывает вопрос «а что
	# это за число» разом для всех модемов.
	run 10 "Коды +CME ERROR из этого отчёта" sh -c '
		. /usr/share/5gmodem/cme.sh
		{ cat /tmp/5gmodem-diag.txt 2>/dev/null; logread 2>/dev/null | tail -200; } \
			| grep -oE "CME ERROR: *[0-9]+" | grep -oE "[0-9]+" | sort -un | while read -r c; do
				t=$(cme_text "$c" 2>/dev/null) || t="(нет в справочнике)"
				printf "  %-4s %s\n" "$c" "$t"
			done
		[ -s /tmp/5gmodem-diag.txt ] || echo "  (ошибок CME в отчёте нет)"
	'

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
