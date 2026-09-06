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
	if [ -s "$_tmp" ]; then cat "$_tmp"; else echo "(empty, or timed out after ${_t}s)"; fi
	rm -f "$_tmp"
}

at() {   # at <порт> <команда> - одна AT-команда с таймаутом и ОЧЕРЕДЬЮ к порту
	[ -n "$1" ] || { echo "(no AT port)"; return; }
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
	echo "----- Why MBIM did not come up (verdict) -----"
	_mv_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_mv_if" ] || { echo "the modem interface is not configured"; return; }
	[ "$(uci -q get "network.$_mv_if.proto")" = mbim ] || {
		echo "the interface does not run mbim - this check does not apply"; return; }
	# ТРЕТЬЯ ЛОВУШКА - ПРОТОКОЛ НЕ ТОТ, ЧТО У УЗЛА. cdc-wdm под драйвером
	# qmi_wwan говорит по QMI: umbim в него шлёт MBIM-кадры и вечно получает
	# «mbim message timeout», цикл retry выглядит как мёртвый модем (живой
	# случай: T99W175 в композиции 05c6:9025, Netcore N60 Pro, 17.08.2026).
	_mv_dev=$(uci -q get "network.$_mv_if.device")
	case "$_mv_dev" in
		/dev/cdc-wdm*)
			_mv_drv=$(basename "$(readlink -f "/sys/class/usbmisc/${_mv_dev##*/}/device/driver" 2>/dev/null)" 2>/dev/null)
			if [ "$_mv_drv" = "qmi_wwan" ]; then
				echo "PROBLEM: node $_mv_dev was created by the qmi_wwan driver (a QMI channel),"
				echo "  but the interface protocol is mbim. MBIM will never speak here:"
				echo "  you will get an endless 'mbim message timeout'."
				echo "  WHAT TO DO: uci set network.$_mv_if.proto='qmi'; uci commit network; ifup $_mv_if"
				return
			fi ;;
	esac
	_mv_err=$(ubus call network.interface."$_mv_if" status 2>/dev/null \
		| sed -n 's/.*"code": *"\([^"]*\)".*/\1/p' | head -1)
	_mv_log=$(logread 2>/dev/null | grep -c "Failed to attach to network")
	_mv_pin=$(logread 2>/dev/null | grep -oE "required pin: [0-9]+ - [a-z0-9]+" | tail -1)
	[ -n "$_mv_err" ] && echo "interface error: $_mv_err"
	[ -n "$_mv_pin" ] && echo "the modem reports: $_mv_pin"
	case "$_mv_pin" in
		*pin2*) echo "  PIN2 is a service code (FDN, limits); the internet does NOT need it."
		        echo "  But umbim treats it as a blocker and fails the setup with PIN_FAILED." ;;
	esac
	[ "$_mv_log" -gt 0 ] 2>/dev/null && \
		echo "'Failed to attach to network' appears $_mv_log time(s) in the log - umbim cannot bring up the PDP context"
	if [ "$_mv_err" = PIN_FAILED ] || [ "$_mv_log" -gt 0 ] 2>/dev/null; then
		echo "  WHAT TO DO: switch the interface to the ModemManager protocol."
		echo "  On Dell DW5821e / Foxconn T77W968 modems this is the only path that works"
		echo "  (confirmed by several users): mbim and QMI on them either fail to"
		echo "  attach to the network, or give an IP with no traffic."
	else
		echo "no clear signs of either of these two traps"
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
	echo "--- processes ---"
	for _wv_p in uhttpd rpcd ubusd; do
		if ps w 2>/dev/null | grep -q "[${_wv_p%"${_wv_p#?}"}]${_wv_p#?}"; then
			echo "$_wv_p: running"
		else
			echo "$_wv_p: NOT RUNNING - that alone explains a dead admin page"
		fi
	done
	echo "--- does ubus answer? ---"
	_wv_t0=$(cut -d. -f1 /proc/uptime)
	if ubus call system board >/dev/null 2>&1; then
		echo "ubus: ok ($(( $(cut -d. -f1 /proc/uptime) - _wv_t0 )) c)"
	else
		echo "ubus: ERROR - rpcd/LuCI do not work without it"
	fi
	echo "--- login page ---"
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
		0) echo "LuCI answers (HTTP 200 in ${_wv_dt} s)" ;;
		8) echo "LuCI answers (login page, HTTP 403 in ${_wv_dt} s - this is normal)" ;;
		*) echo "LuCI DOES NOT ANSWER (wget rc=$_wv_c in ${_wv_dt} s)" ;;
	esac
}

policyrouting_verdict() {
	echo "--- policy routing rules (ip rule) ---"
	ip rule show 2>/dev/null
	_pr_n=$(ip rule show 2>/dev/null | wc -l)
	# Штатных правил три: 0 lookup local, 32766 main, 32767 default.
	if [ "$_pr_n" -gt 3 ] 2>/dev/null; then
		echo "non-standard rules: $((_pr_n - 3)) - policy routing is active (mwan3?)."
		echo "If the admin page is unreachable from the LAN while the internet works, look here:"
		echo "the router's own replies may go to an uplink table that has no route back to the LAN."
		for _pr_t in $(ip rule show 2>/dev/null | sed -n 's/.*lookup \([0-9]\{1,\}\).*/\1/p' | sort -u); do
			echo "  table $_pr_t: $(ip route show table "$_pr_t" 2>/dev/null | head -3 | tr '\n' '; ')"
		done
	else
		echo "policy routing is not in use (stock rules only)"
	fi
	echo "--- mwan3 ---"
	if [ -x /etc/init.d/mwan3 ] || [ -f /etc/config/mwan3 ]; then
		echo "mwan3 is INSTALLED; status: $(mwan3 status 2>/dev/null | head -5 | tr '\n' ' ' || echo 'no answer')"
	else
		echo "mwan3 is not installed"
		# Осиротевшие правила от удалённого mwan3 продолжают действовать до ребута.
		ip rule show 2>/dev/null | grep -q "lookup 25[0-9]" \
			&& echo "BUT its tables (25x) are still in ip rule - policy routing is still alive!"
	fi
	echo "--- is lan in the right zone? ---"
	_pr_lz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'\$/\1/p" | head -1)
	_pr_wz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	echo "lan zone input: $(uci -q get "firewall.$_pr_lz.input")"
	case " $(uci -q get "firewall.$_pr_wz.network") " in
		*" lan "*) echo "PROBLEM: the lan interface belongs to the WAN zone (input=REJECT) - the firewall cuts off the admin page" ;;
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
		echo "THE LOG HAS A TRACE: usbmode set config #0 on the device."
		echo "That strips the data driver: the log nearby shows 'cdc_mbim ... unregister'."
		_um_hit=1
	fi
	for _um_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].vidpid' 2>/dev/null | sort -u); do
		[ "$(jsonfilter -i /etc/usb-mode.json -e "@.devices[\"$_um_p\"][\"*\"].config" 2>/dev/null)" = "0" ] || continue
		echo "THE RULE IS STILL THERE: $_um_p has 'config: 0' in /etc/usb-mode.json -"
		echo "it will break the composition the next time the modem is plugged in."
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
	# ПОТЕРЯННЫЙ КАНАЛ САМ ПО СЕБЕ НИЧЕГО НЕ ДОКАЗЫВАЕТ.
	#
	# Раньше этот признак ставил вердикт сам по себе, и раздел объявлял
	# «последствие сброса конфигурации» там, где ни правила, ни следа в
	# журнале не было вовсе, - а затем советовал usbmode-fix.sh, который в
	# таком случае не сделает ничего. Живой отчёт issue #16 (T99W175 на
	# BPI-R4 Lite): канал увёл жадный usb-serial, а отчёт указывал на
	# usb_modeswitch. Теперь потерянный канал - лишь ПОДТВЕРЖДЕНИЕ уже
	# найденного следа; сам по себе он разбирается в разделе «Есть AT-порт,
	# но нет канала данных».
	if [ -n "$_um_bad" ] && [ "$_um_hit" = 1 ]; then
		echo "AND THE RESULT IS VISIBLE: the modem has AT ports but NO data channel"
		echo "(no cdc-wdm, no network device):$_um_bad"
		echo "There is nothing left to configure the interface on - that is what the config reset does."
	fi
	if [ "$_um_hit" = 0 ]; then
		echo "no traces - this section does not apply"
		[ -n "$_um_bad" ] && echo "  (the data channel of$_um_bad is lost anyway - see the section 'AT port present, data channel missing')"
		return
	fi
	echo
	echo "WHAT TO DO: the app removes the harmful rule by itself and re-applies the USB"
	echo "configuration so the kernel gives the drivers back. If that did not happen"
	echo "(an older version of the app), update and re-plug the modem."
	echo "Check by hand:  /usr/share/5gmodem/usbmode-fix.sh"
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
	echo "--- wan zone uplinks by priority ---"
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
				|| _uv_note="  NO ROUTE"
			[ -n "$_uv_note" ] && [ -z "$_uv_gw" ] && _uv_note="  NO GATEWAY (DHCP gave no router option)"
		fi
		printf 'metric %-5s %-8s %-10s %-16s watchdog: %s%s\n' \
			"$_uv_m" "$_uv_n" "${_uv_d:--}" "${_uv_ip:-no address}" "$_uv_h" "$_uv_note"
	done | sort -n -k2

	# ЖИВОЙ маршрут, а не порядок в uci: сторож штрафует метрику в таблице ядра,
	# не трогая конфиг, и эти две картины расходятся штатно.
	echo "--- who actually carries the default route ---"
	ip -4 route show default 2>/dev/null | sed 's/^/  /'
	_uv_ldev=$(ip -4 route show default 2>/dev/null \
		| awk '{m=0; d=""; for(i=1;i<NF;i++){if($i=="dev")d=$(i+1); if($i=="metric")m=$(i+1)+0} if(d!="")print m, d}' \
		| sort -n | head -1 | cut -d' ' -f2)
	if [ -z "$_uv_ldev" ]; then
		echo "there is NO default route at all - nobody has internet"
		return
	fi
	_uv_lif=""
	for _uv_n in $_uv_nets; do
		[ "$(_uv_get "$_uv_n" '.l3_device')" = "$_uv_ldev" ] && { _uv_lif="$_uv_n"; break; }
	done
	echo "traffic goes through: ${_uv_lif:-?} ($_uv_ldev)"
	# Линки выше по приоритету, которые НЕ МОГУТ взять трафик, - объясняем
	# прямо здесь: иначе «почему не переключается на кабель» остаётся загадкой.
	for _uv_n in $_uv_nets; do
		_uv_d2=$(_uv_get "$_uv_n" '.l3_device'); [ -n "$_uv_d2" ] || continue
		[ "$_uv_d2" = "$_uv_ldev" ] && continue
		_uv_m2=$(uci -q get "network.$_uv_n.metric"); [ -n "$_uv_m2" ] || _uv_m2=0
		_uv_lm=$(uci -q get "network.${_uv_lif}.metric"); [ -n "$_uv_lm" ] || _uv_lm=0
		[ "$_uv_m2" -lt "$_uv_lm" ] 2>/dev/null || continue
		ip -4 route show default 2>/dev/null | grep -qE " dev $_uv_d2( |$)" && continue
		echo "  NOTE: $_uv_n ($_uv_d2) has a higher priority (metric $_uv_m2),"
		echo "  but it has no default route - there is nothing to switch over to."
		if [ -z "$(_uv_get "$_uv_n" '.route[@.target="0.0.0.0"].nexthop')" ]; then
			echo "  Cause: the network gave no gateway (no DHCP router option)."
			echo "  Fix it on the upstream router, or set the gateway statically."
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
		echo "probe via $_uv_ldev: internet IS there"
	else
		echo "probe via $_uv_ldev: NO INTERNET - traffic goes into a hole"
		echo "  (an uplink with an address but no way out looks healthy to the kernel:"
		echo "   the route is there, so nothing will switch away on its own)"
		if [ "$_uv_en" != "1" ]; then
			echo "  the internet watchdog is OFF - nobody is there to notice"
		elif [ "$_uv_fo" != "1" ]; then
			echo "  the watchdog is on, but 'switch traffic over' is OFF -"
			echo "  it sees the failure and deliberately does nothing"
		else
			echo "  failover is on - see below why the watchdog did not move the traffic"
		fi
	fi

	echo "--- internet watchdog ---"
	echo "settings: ${_uv_cfg:-(no answer)}"
	if [ -d /tmp/5gmodem_health ]; then
		for _uv_f in /tmp/5gmodem_health/*; do
			[ -f "$_uv_f" ] || continue
			case "$_uv_f" in */.t) continue ;; esac
			printf '  %s: %s\n' "${_uv_f##*/}" "$(cat "$_uv_f" 2>/dev/null | head -1)"
		done
	else
		echo "  no state yet - the watchdog has not completed a single round"
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
	echo "--- local resolver (as clients see it) ---"
	cap 8 nslookup ya.ru 127.0.0.1 2>&1 | head -8
	echo "--- upstreams: whose they are and whether they answer ---"
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
				*"Address"*[0-9]*) _dv_r="answers" ;;
				*) _dv_r="NO ANSWER (did the query leave through the wrong uplink?)" ;;
			esac
			printf '  %-16s from %-8s - %s\n' "$_dv_s" "$_dv_if" "$_dv_r"
		done < "$_dv_auto"
	else
		echo "  $_dv_auto is empty or missing"
	fi
	_dv_n=$(grep -c "^nameserver" "$_dv_auto" 2>/dev/null)
	case "$_dv_n" in ''|*[!0-9]*) _dv_n=0 ;; esac
	[ "$_dv_n" -gt 3 ] && {
		echo "  $_dv_n servers - these are resolvers of DIFFERENT carriers at once."
		echo "  A query to a foreign one leaves via another uplink's default route, and that"
		echo "  uplink drops it: to clients it looks like 'sites load every other time'."
	}
	echo "--- DNS rebind protection ---"
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
		echo "  dnsmasq does NOT pass these names to clients: the answer held a private address."
		case "$_dv_rb" in
			*msftncsi*|*msftconnecttest*)
				echo "  ONE OF THEM IS THE WINDOWS CONNECTIVITY PROBE (msftncsi/msftconnecttest):"
				echo "  every Windows client will show 'No internet access'"
				echo "  ALL THE TIME, even while the internet works. Cure - add an exception:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftncsi.com'"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftconnecttest.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
		case "$_dv_rb" in
			*gstatic*|*connectivitycheck*)
				echo "  ONE OF THEM IS THE ANDROID CONNECTIVITY PROBE (connectivitycheck.gstatic.com):"
				echo "  phones on Wi-Fi will show 'Connected, no internet'."
				echo "  Cure - add an exception:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='connectivitycheck.gstatic.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
	else
		echo "  no hits in the log"
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
		# ПОДНЯТ ЛИ ИНТЕРФЕЙС - ОТ ЭТОГО ЗАВИСИТ, ЕСТЬ ЛИ ЧТО СВЕРЯТЬ.
		_qf_up=$(ubus call network.interface dump 2>/dev/null \
			| jsonfilter -e "@.interface[@.l3_device=\"$_qf_if\"].up" 2>/dev/null | head -1)
		_qf_fmt=""
		# СПРАШИВАЕМ МОДЕМ, ТОЛЬКО ЕСЛИ КАНАЛ СВОБОДЕН - И БЕЗ -p.
		#
		# Флаг прокси поднимал qmi-proxy, который переживал сбор отчёта, а
		# следующий круг sessionwatch видел его как сироту: убивал и делал ifup.
		# На модеме с картой в illegal этот ifup перезапускал петлю qmi.sh и
		# обнулял ошибку интерфейса, за которую держится лестница health - то
		# есть САМ СБОР ОТЧЁТА ронял дозвон (живой случай Telit FN990A28 на
		# WH3000 Pro, 04.09.2026: отчёт в 23:51, сорванный дозвон в 23:52).
		# Канал проверен свободным, поэтому прямой заход безопасен.
		if [ -n "$_qf_wdm" ] && command -v qmicli >/dev/null 2>&1 \
		   && command -v qmi_channel_free >/dev/null 2>&1 && qmi_channel_free; then
			_qf_mb=""
			case "$(readlink -f "/sys/class/usbmisc/${_qf_wdm##*/}/device/driver" 2>/dev/null)" in
				*/cdc_mbim) _qf_mb="--device-open-mbim" ;;
			esac
			_qf_fmt=$(cap 15 qmicli -d "$_qf_wdm" $_qf_mb --wda-get-data-format 2>/dev/null \
				| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
			printf ', modem: %s' "${_qf_fmt:-no answer}"
		fi
		# ВЕРДИКТ - ТОЛЬКО ПРИ ПОДНЯТОМ ИНТЕРФЕЙСЕ.
		# raw_ip у qmi_wwan по умолчанию N, а Y его выставляет netifd в момент
		# дозвона. Пока дозвон не прошёл, «N против raw-ip» - не рассинхрон, а
		# просто незаполненная настройка. Без этой оговорки отчёт писал «приём
		# отбрасывается молча» КАЖДОМУ модему, который не подключился, и увозил
		# разбор в сторону от настоящей причины (тот же FN990A28: карта в
		# illegal, интерфейс не поднимался ни разу).
		if [ "$_qf_up" = "true" ]; then
			case "$_qf_raw:$_qf_fmt" in
				Y:raw-ip|N:802-3|*:) : ;;
				*) printf ' <- MISMATCH: incoming packets are dropped silently' ;;
			esac
		else
			printf ' | the interface is down - the frame format is set while dialling, nothing to compare'
		fi
		# Счётчики: RX=0 при растущем TX - тот же симптом с другой стороны.
		_qf_rx=$(cat "/sys/class/net/$_qf_if/statistics/rx_packets" 2>/dev/null)
		_qf_tx=$(cat "/sys/class/net/$_qf_if/statistics/tx_packets" 2>/dev/null)
		printf ' | packets rx=%s tx=%s' "${_qf_rx:-?}" "${_qf_tx:-?}"
		case "$_qf_rx" in
			0|1|2|3) [ "${_qf_tx:-0}" -gt 50 ] 2>/dev/null && printf ' <- NO TRAFFIC (sent %s, received %s); the usual cause is a frame format mismatch between the driver and the firmware' "$_qf_tx" "$_qf_rx" ;;
		esac
		echo
	done
	[ -n "$_qf_any" ] || echo "no qmi interfaces - this check does not apply"
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
		echo "TTL override is disabled in the settings - this section does not apply"
		echo "  (if the carrier throttles tethering, turning it on is worth a try: Network -> Modem -> TTL)"
		return 0
	fi
	echo "in the settings: in=${_t_in:-—} out=${_t_out:-—}"
	if ! command -v nft >/dev/null 2>&1; then
		echo "  nft is not in the image - no way to check the live rules"
		return 0
	fi
	if nft list table inet modem5g_ttl >/dev/null 2>&1; then
		echo "  the inet modem5g_ttl table IS CREATED:"
		nft -a list table inet modem5g_ttl 2>/dev/null | grep -E "ttl set|packets" | head -8
	else
		echo "  there is NO inet modem5g_ttl table - the override is enabled but NOT APPLIED."
		echo "  That is the cause if the carrier blocks tethering: the rules are"
		echo "  created by /usr/share/5gmodem/ttl.sh - check logread for its errors."
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
	[ -n "$_av_if" ] || { echo "the modem interface is not configured - this check does not apply"; return 0; }
	_av_cur=$(uci -q get "network.$_av_if.apn")
	echo "APN on the interface: ${_av_cur:-(empty)}"
	_av_imsi=$(printf '%s' "$(cat /tmp/5gmodem_snapshot_* 2>/dev/null | head -c 4000)" \
		| sed -n 's/.*"imsi":"\([0-9]\{6,\}\)".*/\1/p' | head -1)
	[ -n "$_av_imsi" ] || _av_imsi=$(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.apn_imsi='\([0-9]*\)'$/\1/p" | head -1)
	if [ -z "$_av_imsi" ]; then
		echo "  the IMSI is unknown - nothing to match against the database"
		return 0
	fi
	echo "IMSI: $_av_imsi (PLMN ${_av_imsi%??????????})"
	_av_db=$(awk -F'\t' -v p="${_av_imsi%??????????}" '$1 == p && $7 != "" && $7 != "-" {print $6" -> "$7}' \
		/usr/share/5gmodem/providers.tsv 2>/dev/null | head -3)
	if [ -z "$_av_db" ]; then
		echo "  the database has no entries for this PLMN - nothing to compare"
		return 0
	fi
	echo "  the database knows for this network:"
	printf '%s\n' "$_av_db" | sed 's/^/    /'
	if printf '%s\n' "$_av_db" | grep -q -- "-> *$_av_cur\$"; then
		echo "  MATCHES - the APN comes from the database"
	else
		echo "  DOES NOT MATCH. If there is no internet, start here: set an APN from"
		echo "  the list above (Network -> Modem -> Connection settings) and bring the"
		echo "  interface back up. Auto-selection leaves it alone once the APN was edited by hand."
	fi
}

fw_zone_verdict() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	if [ -z "$_fz" ]; then
		echo "there is no wan zone at all - NAT is set up some other way, check it by hand"
		return
	fi
	_fnet=$(uci -q get "firewall.$_fz.network")
	_fmasq=$(uci -q get "firewall.$_fz.masq")
	echo "wan zone networks: $_fnet"
	echo "masq: ${_fmasq:-<not set>}"
	case "$_fnet" in
		*"'"*)
			echo "PROBLEM: a list item with an EMBEDDED space - the string 'wan wan6'"
			echo "went into the list as one piece. No network has that name, so the REAL"
			echo "wan is not in the zone and NAT does not work for it: the router itself"
			echo "reaches the internet, the LAN does not. Cure: reinstall the package (the"
			echo "uci-defaults script unglues it) or fix it by hand in Network > Firewall."
			;;
	esac
	# Интерфейсы модемов, которых в зоне нет: их трафик не будет NAT-иться.
	for _fi in $(uci show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | sort -u); do
		[ -n "$_fi" ] || continue
		echo " $_fnet " | grep -q " $_fi " || echo "WARNING: interface $_fi is NOT in the wan zone - no NAT"
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
	[ -n "$_uf_p" ] || { echo "no active modem is selected"; return; }
	_uf_d="/sys/bus/usb/devices/$_uf_p"
	_uf_sp=$(cat "$_uf_d/speed" 2>/dev/null)
	_uf_pw=$(cat "$_uf_d/bMaxPower" 2>/dev/null)
	echo "link: ${_uf_sp:-?} Mbit/s, requested current: ${_uf_pw:-?}"
	case "$_uf_sp" in
		480)  echo "this is USB 2.0 High-Speed - the port supplies up to 500 mA" ;;
		5000|10000) echo "this is USB 3.x SuperSpeed - the port supplies up to 900 mA" ;;
	esac
	# Отвалы именно этого устройства, а не любые в системе.
	_uf_n=$(logread 2>/dev/null | grep -c "usb $_uf_p: USB disconnect")
	echo "USB re-connects in the current log: $_uf_n"
	# И ПО ВСЕМ ОСТАЛЬНЫМ УСТРОЙСТВАМ ТОЖЕ. Скакать может СОСЕДНИЙ модем, а не
	# активный: живой отчёт с двумя модемами - активный Fibocom работал ровно, а
	# Compal на 2-1.3 перечислялся заново каждые полторы секунды (80+ раз за
	# минуту), и по разделам отчёта это выглядело просто как «модема нет».
	logread 2>/dev/null | sed -n 's/.*usb \([0-9][^:]*\): USB disconnect.*/\1/p' \
		| sort | uniq -c | sort -rn | while read -r _c _d; do
			[ "$_d" = "$_uf_p" ] && continue
			echo "  neighbouring device $_d: $_c re-connects"
			[ "${_c:-0}" -ge 10 ] && echo "  THAT IS A LOT: the device does not stay on the bus - check power, cable and the USB composition"
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
				line[n] = sprintf("  %s  usb %-8s polling of %s stalled %d s before the drop", $4, d, port, g)
			} else {
				line[n] = sprintf("  %s  usb %-8s no polling stall before this one", $4, d)
			}
		}
		END {
			if (n == 0) exit
			print "recent drops (time, device, what happened right before):"
			start = n - 7; if (start < 1) start = 1
			for (i = start; i <= n; i++) print line[i]
			if (pre >= 2 && pre * 2 >= n) {
				print "  OUR OWN MODEM POLLING STALLED BEFORE MOST OF THE DROPS."
				print "  Check this before blaming power: the metric AT commands may be what"
				print "  knocks the module over. Experiment: /etc/init.d/5gmodem-sessionwatch stop,"
				print "  close the Network page in the browser (it polls the modem too) and wait an hour."
				print "  If the drops stop, polling is to blame - please file an issue with this observation."
			} else {
				print "  The drops do not line up with modem polling - the cause is outside the app:"
				print "  power, the cable/adapter, or the module firmware itself."
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
		echo "  PROBLEM: the device is on the bus but DOES NOT ENUMERATE ($_uf_en errors in dmesg:"
		dmesg 2>/dev/null | grep -E "unable to enumerate|not accepting address|descriptor read.*error" | tail -3 | sed 's/^/    /'
		echo "  ). This is the physical layer - it never gets as far as the drivers or the app."
		echo "  The cure is hardware: a short, good cable with no adapters, a hub with its"
		echo "  own power supply (the router port may not have enough current to start the"
		echo "  modem), and testing the modem on a PC. As soon as dmesg shows the line"
		echo "  'new high-speed USB device', the app will pick the modem up on its own."
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
		echo "PROBLEM: the USB CONTROLLER itself (xHCI) died, not the modem."
		logread 2>/dev/null | grep -oE "(xhci[^:]*): (HC died[^,]*|Host halt failed, -[0-9]+|xHCI host controller not responding[^,]*)" | tail -3
		echo "The sign: ALL devices disappeared AT ONCE and the bus never came back until"
		echo "a reboot. This is NOT a power shortage - a brownout drops a single device"
		echo "and leaves error -71 / device descriptor read in the log."
		logread 2>/dev/null | grep -qE "NETDEV WATCHDOG.*(rndis|cdc|usb)" && {
			echo "Right before the controller died, TRANSMIT hung in the network driver"
			echo "(NETDEV WATCHDOG, transmit queue timed out) - it is the kernel trying to"
			echo "reset the endpoint that finishes the controller off."
		}
		echo "What is worth trying: (1) turn off USB autosuspend -"
		echo "  echo on > /sys/bus/usb/devices/usbN/power/control;"
		echo "(2) bring the bus back without a reboot by reloading the modules"
		echo "  (rmmod/modprobe xhci-mtk and the modem driver);"
		echo "(3) if the board serves every port from one controller (Banana Pi R4 and"
		echo "  relatives), changing the PORT will not help - it is the same controller;"
		echo "  only another controller or another board will."
		echo "Swapping the power supply or the cable makes no sense here - the log shows no brownout."
		return
	fi

	[ "${_uf_n:-0}" -ge 1 ] || return
	echo "PROBLEM: the device disappeared from the bus and re-enumerated."
	echo "If this happens SHORTLY AFTER attaching to the network, it is almost certainly"
	echo "a power shortage: the modem draws peak current while transmitting, and the"
	echo "brownout drops the link. Check in order: another USB port (USB 3.0 is better),"
	echo "a short cable with no extensions, an adapter/hub WITH ITS OWN POWER SUPPLY."
	[ "$_uf_sp" = "480" ] && echo "Separately: the link came up as USB 2.0. If the modem supports USB 3.0, the cable or the adapter is to blame - the SuperSpeed contacts are not in use."
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
		echo "no unconfigured devices - this section does not apply"
		return
	fi
	for _uu_b in $_uu_bad; do
		_uu_d="/sys/bus/usb/devices/$_uu_b"
		echo "$_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] $(cat "$_uu_d/product" 2>/dev/null)"
		echo "  no configuration is assigned - there are no interfaces and no drivers bound"
	done
	echo "PROBLEM: the device is physically on the bus (lsusb sees it), but the kernel"
	echo "could not configure it. It has no ports, so it is missing from the modem list too."
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
		echo "NOTE: the app RECENTLY re-bound this USB device"
		echo "(mm_recover_missing: ModemManager did not assemble the modem). It looks like"
		echo "unbind/bind did not bring it back - usually that is 'can't set config #1, error -71'."
		echo "CURE: POWER THE ROUTER OFF (pull the power for a few seconds - not a reboot)."
		echo "For such a modem it is worth choosing the QMI protocol instead of ModemManager -"
		echo "then re-binding will never touch it again."
	else
		echo "This is NOT an app bug and NOT a power problem."
	fi
	_uu_why=$(dmesg 2>/dev/null | grep -E "Not enough host controller resources|Not enough bandwidth|can't set config" | tail -4)
	[ -n "$_uu_why" ] && { echo "From the kernel log:"; printf '%s\n' "$_uu_why" | sed 's/^/  /'; }
	if dmesg 2>/dev/null | grep -q "Not enough host controller resources"; then
		echo "The kernel named the cause outright: the CONTROLLER ran out of resources"
		echo "(endpoints). Who took them is visible from the interface count:"
		for _uu_d in /sys/bus/usb/devices/*; do
			_uu_b=${_uu_d##*/}
			case "$_uu_b" in *:*|usb*) continue ;; esac
			[ -f "$_uu_d/idVendor" ] || continue
			_uu_n=0
			for _uu_i in "$_uu_d":*; do [ -d "$_uu_i" ] && _uu_n=$((_uu_n + 1)); done
			echo "  $_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] interfaces: $_uu_n"
		done
		echo "Modules with RNDIS and a pile of ttyUSB ports (Fibocom FM350 - 10 interfaces,"
		echo "7 of them serial) cost the most; a modem in MBIM costs 2."
		echo "What is worth trying: (1) remove a spare device from this controller;"
		echo "(2) remember that DIFFERENT HUBS, and even different buses of one controller,"
		echo "  do NOT split the budget - changing the socket alone cures nothing;"
		echo "(3) switch to a leaner USB composition if the module can do it"
		echo "  (on the FM350 both compositions, 40 and 41, are equally hungry)."
	elif dmesg 2>/dev/null | grep -q "Not enough bandwidth"; then
		echo "The kernel blamed bus BANDWIDTH, not controller resources:"
		echo "the device did not get enough periodic bandwidth. What helps is spreading"
		echo "the devices over different controllers, or lowering the link speed."
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
						_fb="$_fb  $_fb_id $(cat "$_fb_d/manufacturer" 2>/dev/null) $(cat "$_fb_d/product" 2>/dev/null) (fastboot composition)$_fb_nl"
					done
				fi ;;
		esac
	done
	if [ -z "$_fb" ]; then
		echo "no modems in bootloader mode"
		return
	fi
	printf '%s' "$_fb"
	echo "PROBLEM: the device exposes a BOOTLOADER composition (fastboot/EDL) instead of"
	echo "a modem - hence no ports, and it never shows up in the modem list."
	echo "On the Huasifei WH3000 Pro board (M.2 slot) the cause is hardware: pin 67 is"
	echo "tied to ground, and the modem enters the bootloader on EVERY boot."
	echo "Since version 2.4.27 the app brings such a modem out of the bootloader BY ITSELF,"
	echo "without the fastboot package (OpenWrt feeds do not carry one): the protocol"
	echo "command is sent over usb-serial (on hotplug, at most once a minute,"
	echo "up to 3 attempts; switch it off with: uci set"
	echo "5gmodem.@5gmodem[0].fastboot_rescue='0'). EDL (05c6:9008) is never"
	echo "touched. The app never puts a modem INTO the bootloader: flashing modes"
	echo "are not our business."
}

# МОДЕМ СПИТ (power-state: low).
# Причина неочевидная: интерфейс бесконечно пересоздаётся, в журнале сыплется
# «couldn't enable the modem: Invalid transition», и выглядит это как поломка
# протокола. На деле у модема выключено радио: ModemManager пытается поднять
# питание, модем отвечает OperationNotAllowed, включение падает, netifd повторяет
# попытку каждые пару секунд. Единственный признак - одна строка в mmcli, которую
# в длинном выводе легко пропустить (живой отчёт: Dell DW5821e на Radxa ROCK 5T).
power_state_verdict() {
	command -v mmcli >/dev/null 2>&1 || { echo "no mmcli - nothing to check with"; return; }
	_ps_i=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
	[ -n "$_ps_i" ] || { echo "the modem is not registered in ModemManager - this check does not apply"; return; }
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
				echo "PROBLEM (HARDWARE): the firmware reports that the radio is switched off"
				echo "by the hardware switch (pin W_DISABLE# on M.2). Software cannot cure"
				echo "this - neither AT, nor qmicli, nor reboots will help."
				echo "Check:"
				echo "  - the radio-disable switch/jumper on the M.2 adapter;"
				echo "  - power: behind a USB hub the modem shares the port's 500 mA, while its"
				echo "    peak draw is over an amp - connect the adapter directly or through a"
				echo "    hub with its own power supply;"
				echo "  - after changing power or port, fully re-plug the modem."
				return
			fi
			echo "PROBLEM: the modem radio is off. While it stays in this state, no protocol"
			echo "will bring the connection up, and the log will show an endless"
			echo "'couldn't enable the modem: Invalid transition' is a consequence, not the cause."
			echo "Cures, from least to most effort:"
			echo "  mmcli -m $_ps_i --set-power-state-on   (then ifup the interface you need)"
			echo "  or over AT on its port:  sms_tool -d <port> at \"AT+CFUN=1\""
			echo "  or cut power to the modem - some firmwares wake up no other way."
			;;
	esac
}

proxy_verdict() {
	echo ""
	echo "----- Fight over the control channel (verdict) -----"
	_pv=$(ps w 2>/dev/null | grep -E "mbim-proxy|qmi-proxy" | grep -v grep)
	if [ -z "$_pv" ]; then
		echo "no proxy processes - the channel is free"
		return
	fi
	printf '%s\n' "$_pv"
	_pvproto=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null)
	case "$_pvproto" in
		mbim|qmi)
			echo "WARNING: the interface runs protocol '$_pvproto', which opens"
			echo "  /dev/cdc-wdm* directly, while the proxy above holds the same device."
			echo "  That is what produces 'mbim message timeout'. Cure: killall mbim-proxy qmi-proxy,"
			echo "  then ifup the interface you need." ;;
		*) echo "(interface protocol '$_pvproto' - a proxy usually does not bother it)" ;;
	esac
}

# МОДЕМ ЕЩЁ В РЕЖИМЕ НАКОПИТЕЛЯ. Многие свистки при включении отдаются как
# CD-ROM с драйверами (режим Stick), и лишь usb_modeswitch переводит их в
# модемную композицию. Пока этого не случилось, у устройства нет ни tty, ни
# cdc-wdm, ни сетевой карты - приложение честно показывает «модема нет», и
# пользователь ищет поломку там, где её нет. Отдельная строка вместо молчания.
stick_verdict() {
	echo ""
	echo "----- Is the modem stuck in mass-storage mode? (verdict) -----"
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
		echo "no - no modem is stuck in mass-storage mode"
		return
	fi
	echo "YES, the device shows up as a USB mass-storage device and has no modem ports:"
	printf '   %s\n' $_sv_found
	echo "  usb_modeswitch is supposed to switch it. Check:"
	echo "    /etc/init.d/usbmode enable; /etc/init.d/usbmode start"
	echo "  and that usb-modeswitch, kmod-usb-net-cdc-ether,"
	echo "  kmod-usb-serial-option."
}

# МОДЕМ ЕСТЬ, AT-ПОРТ ЕСТЬ, А КАНАЛА ДАННЫХ НЕТ.
#
# Класс отказа, который проверка накопителя выше НЕ ловит: порты ttyUSB на месте
# (значит модем опознан и переключён), но нет ни cdc-wdm, ни сетевого узла - и
# proto=qmi/mbim просто некуда прицепить.
#
# ПРИЧИН РОВНО ДВЕ, и лечатся они по-разному:
#   1. КОМПОЗИЦИЯ. У Qualcomm-модулей канал включается вендорной настройкой, и
#      без неё человек бесконечно чинит usb_modeswitch и драйверы, хотя
#      лечится это одной AT-командой с последующим передёргом питания.
#   2. ЖАДНЫЙ USB-SERIAL. Канал в композиции ЕСТЬ, но его интерфейс - тоже
#      vendor-класса (ff), и динамический new_id отдаёт его usb-serial наравне
#      с обычными портами. Пока модем не переподключался, порядок привязки
#      складывается удачно; после реэнумерации generic успевает первым, и
#      cdc-wdm пропадает. Живой отчёт issue #16 (T99W175, 05c6:9025 на
#      BPI-R4 Lite): в 08:30:51 cdc-wdm0 и wwan0 поднялись, в 08:31:38 модем
#      переэнумерировался - и все пять ff-интерфейсов ушли usbserial_generic.
# Различаем по таблице usbports.sh: если номер интерфейса канала для этой
# композиции известен, канал в ней есть, и виноват тот, кто им сейчас владеет.
#
# РАНЬШЕ РАЗДЕЛ СМОТРЕЛ ТОЛЬКО НА ТРИ VID (Quectel, SimCom, Telit) и молча
# отвечал «канал данных на месте» на модеме, у которого его не было вовсе.
# Устройства берём из нашего же списка модемов - тогда чужой USB-UART сюда не
# попадёт, а любой модем попадёт.
#
# Сетевой узел проверяем ОТДЕЛЬНО: часть модулей ходит через ECM/RNDIS без всякого
# cdc-wdm (наш профиль 2c7c:6005 - как раз такой), и для них это норма, а не беда.
usbcomp_verdict() {
	echo ""
	echo "----- AT port present, data channel missing? (verdict) -----"
	_uc_found=""
	_uc_stolen=""
	for _uc_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_uc_p" in *-*) ;; *) continue ;; esac
		_uc_d="/sys/bus/usb/devices/$_uc_p"
		[ -f "$_uc_d/idVendor" ] || continue
		_uc_v=$(cat "$_uc_d/idVendor" 2>/dev/null)
		_uc_i=$(cat "$_uc_d/idProduct" 2>/dev/null)
		_uc_tty=""; _uc_wdm=""; _uc_net=""
		for _uc_n in "$_uc_d":*/ttyUSB* "$_uc_d":*/tty/ttyUSB* "$_uc_d":*/tty/ttyACM*; do
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
   $_uc_p  $_uc_v:$_uc_i"
		# Канал в композиции есть, но им владеет usb-serial - значит его увели.
		_uc_num=$("$RES/usbports.sh" dataif "$_uc_v" "$_uc_i" 2>/dev/null)
		[ -n "$_uc_num" ] || continue
		# Номер КОНФИГУРАЦИИ в имени интерфейса не всегда 1 (у Compal рабочая -
		# третья), поэтому берём маской, а не «:1.N».
		for _uc_if in "$_uc_d":*."$_uc_num"; do
			[ -f "$_uc_if/bInterfaceNumber" ] || continue
			_uc_drv=$(basename "$(readlink -f "$_uc_if/driver" 2>/dev/null)" 2>/dev/null)
			case "$_uc_drv" in
				option1|usb_serial_generic|generic|option)
					_uc_stolen="$_uc_stolen
   $_uc_p  $_uc_v:$_uc_i  interface $_uc_num held by driver $_uc_drv" ;;
			esac
		done
	done
	if [ -z "$_uc_found" ]; then
		echo "no - every modem with an AT port has its data channel"
		return
	fi
	echo "YES, the modem has ttyUSB ports but neither cdc-wdm nor a network device:"
	# ПЕЧАТАЕМ СТРОКАМИ, А НЕ СЛОВАМИ. Раньше здесь был неквотированный
	# printf '   %s\n' $_uc_found: оболочка резала запись по пробелам, и путь
	# с vid:pid уезжали на РАЗНЫЕ строки.
	printf '%s\n' "$_uc_found" | sed '/^[[:space:]]*$/d'
	if [ -n "$_uc_stolen" ]; then
		echo ""
		echo "CAUSE FOUND: the composition DOES have a data channel, but its interface"
		echo "was taken by the serial-port driver: it is handed the whole vendor class"
		echo "and cannot tell the channel from an ordinary port:"
		printf '%s\n' "$_uc_stolen" | sed '/^[[:space:]]*$/d'
		echo "  This happens after the modem re-enumerates while its ports are bound"
		echo "  dynamically (new_id). We never touch a device whose channel is alive,"
		echo "  but the same new_id line is often kept in rc.local by hand, and the"
		echo "  kernel cannot take it back - usb-serial has no remove_id."
		echo "  CURED WITHOUT A REBOOT: the app returns the interface to its native"
		echo "  driver by itself, every time the device appears on the bus."
		echo "  Check by hand:  /usr/share/5gmodem/usbports.sh rescue"
		echo "  If your rc.local carries a port-binding line, better remove it:"
		echo "  the app sets the ports up on its own."
		return
	fi
	echo "  The USB composition carries no data channel. The cure is a vendor command"
	echo "  in the AT console, after which the modem must be POWER-CYCLED:"
	echo "    Quectel: AT+QCFG=\"usbnet\"      -> must be 0, otherwise AT+QCFG=\"usbnet\",0"
	echo "    SimCom:  AT+CUSBPIDSWITCH?      -> must be 9001, otherwise"
	echo "             AT+CUSBPIDSWITCH=9001,1,1"
}

radio_verdict() {   # $1 - АТ-порт
	echo ""
	echo "----- Radio state (verdict) -----"
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
			echo "No AT port - taking the state from ModemManager."
			case "$_rvp" in
				on)  echo "radio power: on (normal)" ;;
				low) echo "radio power: LOW POWER - the equivalent of CFUN=4, no connection will come up" ;;
				off) echo "radio power: OFF - the radio is switched off" ;;
				*)   echo "radio power: ${_rvp:-unknown}" ;;
			esac
			echo "modem state: ${_rvs:-unknown}"
			case "$_rvf" in
				''|--) ;;
				sim-missing) echo "FAILURE REASON: NO SIM DETECTED - check the card and the tray" ;;
				esim-without-profiles)
					echo "FAILURE REASON: AN EMPTY eSIM SLOT IS ACTIVE - the chip holds no profiles,"
					echo "  and ModemManager refuses to bring the modem up. Cure: switch to the"
					echo "  physical SIM slot (Network page -> SIM/eSIM buttons), or download a"
					echo "  profile onto the chip." ;;
				*) echo "FAILURE REASON: $_rvf" ;;
			esac
			return
		fi
		echo "No AT port and no modem in ModemManager - nothing to check with"
		return
	fi
	_rv=$(at_query "$1" "AT+CFUN?" 6 \
		| sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
	case "$_rv" in
		1)  echo "CFUN=1 - the radio is on (normal)" ;;
		0)  echo "CFUN=0 - THE RADIO IS OFF: no protocol will bring the connection up"
		    echo "    Often this is a LEFTOVER of an aborted dial, not somebody's choice: on"
		    echo "    giving up, the protocol turns the radio off while tearing the session"
		    echo "    down. A module reboot turns it back on - AT+CFUN=1,1 or the 'Reboot modem' button." ;;
		4)  echo "CFUN=4 - airplane mode: no connection will come up" ;;
		'') echo "CFUN could not be read (the port is busy or the modem is silent)" ;;
		*)  echo "CFUN=$_rv - NOT full functionality, CFUN=1 is expected: data may not work" ;;
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
	[ -n "$1" ] || { echo "    No AT port - nothing to ask the modem with, the cause cannot be named"; return; }
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
	echo "    signal: ${_ac_csq:-no answer}${_ac_dbm:+ (~${_ac_dbm} dBm)}, operator: ${_ac_ops:-empty}, +CGATT: ${_ac_att:-no answer}"

	# КАРТА В «illegal» - НАЗЫВАЕМ ЭТО ВСЛУХ. Данные для вывода в отчёте были и
	# раньше (ошибка интерфейса, строки в журнале), но истолкования не было, и
	# разбор уходил в APN, протокол и «попробуйте MBIM» - мимо. netifd, получив
	# illegal, каждые ~8 c режет питание слота и пробует снова; карте, которой на
	# инициализацию нужны минуты, он не даёт подняться никогда. Снимает illegal
	# только перезагрузка модуля. Смотрим и ошибку интерфейса, и журнал: сдавшись,
	# протокол ошибку обнуляет, а строки в логе остаются.
	_ac_ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	_ac_ifst=""
	[ -n "$_ac_ifn" ] && _ac_ifst=$(ubus call "network.interface.$_ac_ifn" status 2>/dev/null)
	_ac_ifip=$(printf '%s' "$_ac_ifst" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	# Адрес у qmi/mbim нередко живёт на ДЕТЁНЫШЕ («<имя>_4»), а не на самом
	# интерфейсе - без него исправный модем выглядел бы как «без адреса».
	[ -n "$_ac_ifip" ] || [ -z "$_ac_ifn" ] || _ac_ifip=$(ubus call "network.interface.${_ac_ifn}_4" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	_ac_ill=""
	# ТОЛЬКО ПОКА СВЯЗИ НЕТ. Журнал живёт сутками, и один давний круг петли на
	# давно работающем модеме выдавал бы «карта в illegal» поверх исправной
	# связи - поймано на своём же роутере при первой проверке этой врезки.
	# Подключённый к пакетной сети модем (+CGATT: 1) в illegal быть не может.
	if [ -z "$_ac_ifip" ] && [ "$_ac_att" != "1" ]; then
		printf '%s' "$_ac_ifst" | grep -q "SIM_ILLEGAL_STATE" && _ac_ill=1
		if [ -z "$_ac_ill" ]; then
			logread 2>/dev/null | tail -200 | grep -q "SIM in illegal state" && _ac_ill=1
		fi
	fi
	if [ -n "$_ac_ill" ]; then
		echo "    THE CARD IS IN THE illegal STATE - and that is most likely the main cause."
		echo "    On seeing illegal, the qmi protocol power-cycles the slot every ~8 s and"
		echo "    tries again. A card that needs 1-2 minutes to initialise NEVER gets the"
		echo "    chance - and changing the protocol (MBIM or any other) does not cure it."
		echo "    Only a module reboot followed by a wait clears illegal:"
		echo "      sms_tool -d ${1:-<AT port>} at \"AT+CFUN=1,1\"   and WAIT ~2 minutes"
		echo "    The 'Reboot modem' button on the Modem page does the same thing,"
		echo "    and the internet watchdog does it on its own (the 'reboot the module' step)."
		echo "    If the card was moved between slots, check the 'SIM slots' section first:"
		echo "    the active slot must be the one the card sits in."
	fi

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
					echo "    the connection works: address $_ac_up on interface $_ac_if - question closed."
				else
					echo "    registered and attached to the packet network - the radio is fine."
					echo "    Since there is still no address, the cause is further on: APN, PDP type or netifd."
				fi
			else
				echo "    registered, but NOT attached to the packet network (+CGATT: 0)."
				echo "    That is the APN or the PDP type, not the antennas: check the APN with the"
				echo "    carrier and try IPV4V6 - some modules refuse to activate a plain IPV4 context."
			fi ;;
		5|7|10)
			echo "    registered IN ROAMING (stat $_ac_reg). If the roaming switch is off, the"
			echo "    connection is refused on purpose - a guard against a data bill." ;;
		2)
			echo "    NO NETWORK FOUND: the modem is searching (+CEREG stat 2) and cannot register."
			echo "    No APN or PDP type gets around this - a network has to appear first." ;;
		3)
			echo "    THE NETWORK REFUSED REGISTRATION (+CEREG stat 3). This is not the antennas:"
			echo "    that is the answer for an unregistered SIM, an unpaid plan or a blocked"
			echo "    IMEI. Try the same SIM in a phone." ;;
		0|4)
			echo "    NOT REGISTERED (+CEREG stat ${_ac_reg}) and no search is running."
			# +COPS: 2 - модем ДЕРЕГИСТРИРОВАН КОМАНДОЙ и сам искать сеть не
			# будет никогда. Так остаётся после оборванного дозвона (скрипты
			# xmm/gcom шлют COPS=2 в начале цикла); в другом роутере тот же
			# модем регистрируется сразу - потому что там его никто не
			# дерегистрировал. Живой отчёт 09.08.2026 (L850, МТС).
			if [ "$_ac_copsmode" = "2" ]; then
				echo "    CAUSE FOUND: +COPS: 2 - the modem was deregistered BY A COMMAND."
				echo "    Until AT+COPS=0 is issued it will not even start searching."
				echo "    Usually a leftover of an aborted dial loop (xmm)."
				echo "    The app watchdog restores registration by itself; by hand:"
				echo "    sms_tool -d $1 at \"AT+COPS=0\""
			else
				echo "    Check the network mode (locked to an unavailable RAT?), the bands and CFUN."
			fi ;;
		8)
			echo "    emergency calls only (+CEREG stat 8) - there is no normal network for data." ;;
		'')
			echo "    the registration state could not be read - the port is busy or the modem is silent." ;;
		*)
			echo "    +CEREG stat $_ac_reg" ;;
	esac

	# АНТЕННЫ. Говорим про них только когда сети нет - при живой регистрации
	# слабый сигнал это «медленно», а не «не подключается», и совет уводил бы вбок.
	case "$_ac_reg" in
		1|5|6|7|9|10) ;;
		*)
			if [ -n "$_ac_dbm" ] && [ "$_ac_dbm" -le -100 ]; then
				echo "    THE SIGNAL IS ON THE FLOOR (~${_ac_dbm} dBm). Antennas first: are they screwed"
				echo "    on, in the right sockets (main/aux, not GNSS), is the pigtail intact."
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
	echo "----- Why the modem does not connect (verdict) -----"
	if ! command -v mmcli >/dev/null 2>&1; then
		echo "ModemManager is not installed - working it out over AT:"
		at_conn_verdict "$1"
		return
	fi
	_mf_l=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p')
	# MM установлен, но модема в нём нет - значит он не под MM (наш fibocom,
	# atc, xmm). Молчать здесь нельзя: раздел называется «почему не подключается».
	[ -n "$_mf_l" ] || { echo "ModemManager has no modems at all - working it out over AT:"; at_conn_verdict "$1"; return; }
	for _mf_i in $_mf_l; do
		_mf_k=$(mmcli -m "$_mf_i" -K 2>/dev/null)
		_mf_d=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.device *: *//p' | head -1)
		_mf_s=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
		_mf_r=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state-failed-reason *: *//p' | head -1)
		_mf_sim=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.sim *: *//p' | head -1)
		echo "### modem $_mf_i (${_mf_d##*/}): state $_mf_s"
		case "$_mf_s" in
			connected) echo "    normal - the connection is established" ;;
			registered|enabled) echo "    the radio is ready but there is no data session: check the APN and netifd" ;;
			failed)
				case "$_mf_r" in
					sim-missing)
						echo "    NO SIM DETECTED. This is hardware, not settings:"
						echo "    check that the card is there, the right way round and seated in the tray,"
						echo "    and on dual-slot modules - that the active slot is the one holding the card." ;;
					sim-error|sim-wrong) echo "    SIM ERROR ($_mf_r) - the card cannot be read: contacts, or try another card" ;;
					esim-without-profiles)
						# Живой отчёт 07.08.2026 (MV31-W, WH3000 Pro): активен слот
						# eSIM, профилей на чипе нет - MM объявляет модем failed и
						# НЕ регистрируется. Снаружи выглядит как «модем в вечном
						# поиске сети», хотя физическая SIM лежит в соседнем слоте.
						echo "    AN EMPTY eSIM SLOT IS ACTIVE: the chip holds no profiles, and MM"
						echo "    refuses to bring the modem up - hence the 'endless network search'."
						echo "    What to do: make the physical SIM slot active again (the SIM/eSIM"
						echo "    buttons on the Network page); to download a profile, first hide the"
						echo "    modem from MM (the 'Hide from ModemManager' checkbox)."
						echo "    The slots and their contents are in the 'SIM slots' section below." ;;
					unknown-capabilities) echo "    MM could not determine the modem capabilities - usually an AT-only assembly (see the cdc-wdm section)" ;;
					''|--) echo "    state failed with no reason given" ;;
					*) echo "    failure reason: $_mf_r" ;;
				esac ;;
			locked) echo "    the modem is locked (PIN/PUK) - see unlock-required in the dump" ;;
			disabled) echo "    the modem is disabled: netifd has not enabled it yet, or it was disabled by hand" ;;
			*) echo "    state: $_mf_s" ;;
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
			echo "    LOOKS LIKE AN FCC LOCK: radio power is 'low' and enabling does not go through."
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
					echo "    the unlock script is ALREADY enabled - the cause is something else"
				elif [ -n "$_mf_script" ]; then
					echo "    WHAT TO DO (the qmi-utils package is required):"
					echo "      mkdir -p $_mf_en"
					echo "      ln -s $_mf_av/$_mf_script $_mf_en/$_mf_vid:$_mf_pid"
					echo "      ifdown the modem interface, /etc/init.d/modemmanager restart, wait a minute, ifup"
				else
					echo "    there is no ready-made script for $_mf_vid:$_mf_pid in $_mf_av - check a newer ModemManager"
				fi
			fi
		fi
		case "$_mf_sim" in
			''|--) echo "    the modem has no SIM object - there is no card in any slot" ;;
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
	echo "----- FCC lock (verdict) -----"
	[ -n "$1" ] || { echo "no AT port - nothing to check with"; return; }
	_fl=$(at_query "$1" "AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?" 8)
	_flm=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKMODE: *\([0-9]*\).*/\1/p' | head -1)
	_fls=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKSTATE: *\([0-9]*\).*/\1/p' | head -1)

	if [ -z "$_flm" ]; then
		echo "the modem does not answer about FCC lock - this vendor has no such lock"
		return
	fi
	if [ "$_flm" = "0" ]; then
		echo "FCC lock is off (mode 0) - the modem transmits freely"
		return
	fi

	# mode 1 - разблокировать нужно ОДИН раз, mode 2 - при каждом включении.
	case "$_flm" in
		1) echo "FCC lock is ON (mode 1: unlocking is needed once)" ;;
		2) echo "FCC lock is ON (mode 2: unlocking is needed at EVERY power-on)" ;;
		*) echo "FCC lock is ON (mode $_flm)" ;;
	esac
	if [ "$_fls" = "1" ]; then
		echo "Right now the modem is UNLOCKED (state 1) - the radio works."
		[ "$_flm" = "2" ] && echo "But with mode 2 the lock comes back after a power-off."
		return
	fi
	echo "AND IT IS NOT UNLOCKED (state 0) - THAT IS THE CAUSE if the modem does not"
	echo "transmit: AT+CFUN=1 answers with an error, no protocol brings the connection"
	echo "up, and it all looks like broken hardware. The hardware is fine."
	echo "Unlocking: AT+GTFCCLOCKGEN gives a challenge, from which a verification"
	echo "code is computed (SHA256 of the challenge + vendor hash), then"
	echo "AT+GTFCCLOCKVER=<code>. To remove it for good - AT+GTFCCLOCKMODE=0 and"
	echo "re-plug the modem. The procedure is described in the ModemManager docs;"
	echo "a step-by-step version is in docs/FM350-reference.md of our repository."
	echo "The app does NOT do this by itself: unlocking is a one-off action by the"
	echo "owner, and we do not want to reach into it from a web UI."
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
	echo "----- Sierra: firmware image and carrier profile (verdict) -----"
	printf '%s\n' "$_si" | grep -E "version|name|index" | sed 's/^[[:space:]]*/  /'
	if printf '%s' "$_si" | grep -q "mismatch"; then
		echo "MISMATCH: the selected image/profile DOES NOT MATCH the loaded one."
		echo "In this state the modem drops into low power: the radio is silent, there is"
		echo "no registration, and yet no command complains. This is usually how an"
		echo "UNFINISHED firmware update ends - preferred is already switched over while"
		echo "the image itself was never flashed."
		echo "The cure is to point preferred back at the profile that is ACTUALLY in the"
		echo "modem (the current line), for example: AT!IMPREF=\"GENERIC\", and re-plug"
		echo "the power. To list what is flashed: AT!IMAGE?"
	else
		echo "the selected image and profile match the loaded ones - normal"
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
		echo "NO MODEM FOUND on the USB bus. Check the power and the connection;"
		echo "if the modem sits in an M.2 slot, see the 'bootloader mode' section below."
		return
	fi
	# КАНАЛА ДАННЫХ НЕТ ВОВСЕ - это важнее отсутствия адреса и должно стоять
	# первым: без cdc-wdm/сетевого узла прото не за что зацепиться, и советы
	# про APN и регистрацию уводят в сторону. Живой отчёт issue #16: человек
	# читал «адреса нет - смотрите APN», а на деле канал увёл usb-serial.
	if [ -z "$_sv_ip" ]; then
		_sv_bad=""
		for _sv_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
			case "$_sv_p" in *-*) ;; *) continue ;; esac
			ls /sys/bus/usb/devices/"$_sv_p":*/net/* >/dev/null 2>&1 && continue
			ls /sys/bus/usb/devices/"$_sv_p":*/usbmisc/cdc-wdm* >/dev/null 2>&1 && continue
			_sv_bad="$_sv_bad $_sv_p"
		done
		if [ -n "$_sv_bad" ]; then
			echo "The modem has NO DATA CHANNEL:$_sv_bad - neither cdc-wdm nor a network"
			echo "device. There will be no address until the channel comes back: there is"
			echo "nothing for the protocol to attach to. See 'AT port present, data channel missing'."
			return
		fi
		echo "The modem was found, but it HAS NO ADDRESS - the connection never came up."
		echo "See the sections 'Why the modem does not connect' and 'APN vs. the database'."
		return
	fi
	if [ -z "$_sv_def" ]; then
		echo "The modem has an address ($_sv_ip), but there is NO DEFAULT ROUTE -"
		echo "traffic has nowhere to go. See the section 'Who holds the internet'."
		return
	fi
	# есть адрес и маршрут - спросим сторожа, ходят ли пакеты
	_sv_st=""
	[ -n "$_sv_if" ] && [ -f "/tmp/5gmodem_health/$_sv_if" ] \
		&& read -r _sv_st _ _ _ _ 2>/dev/null < "/tmp/5gmodem_health/$_sv_if"
	case "$_sv_st" in
		down) echo "There is an address ($_sv_ip), but the internet through the modem DOES NOT ANSWER probes."
		      echo "See the sections 'Who holds the internet' and 'DNS'." ;;
		up)   echo "All good: the modem is online, address $_sv_ip, probes go through." ;;
		*)    echo "The modem is online, address $_sv_ip. No watchdog checks yet" \
		      "(monitoring is off, or the router has just booted)." ;;
	esac
}

report() {
	echo "===== luci-app-5gmodem: diagnostic report ====="
	echo "Collected: $(date)"
	echo ""
	echo "WARNING: this report contains modem and SIM identifiers (IMEI, IMSI,"
	echo "ICCID, EID) and the carrier name. Passwords and Wi-Fi keys are NOT included."
	echo "If you would rather not publish the identifiers, send the file privately."
	echo ""
	echo "----- THE SHORT STORY -----"
	echo "Router:    $(cat /tmp/sysinfo/model 2>/dev/null | head -1)"
	echo "Firmware:  $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)"
	echo "Package:   $( (apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) \
		| sed -n 's/^\(luci-app-5gmodem[a-z-]*\)[ -]\([0-9][^ ]*\).*/\1 \2/p' | head -1)"
	_sum_m=$("$RES/listmodems.sh" 2>/dev/null)
	echo "Modem:     $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].model' 2>/dev/null) $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].vidpid' 2>/dev/null)"
	echo "Operator:  $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].operator' 2>/dev/null)"
	echo "Interface: $(uci -q get 5gmodem.@5gmodem[0].network) ($(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null))"
	echo ""
	echo "VERDICT:"
	_sum_verdict | sed 's/^/  /'
	echo ""
	echo "Below is the detailed diagnostic dump. It is meant for the developer:"
	echo "if everything works, there is no need to read it."

	collect "system"
	run 5  "Installed packages" sh -c "(apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | grep -iE '5gmodem|sms-tool|modemmanager|lpac|ca-bundle|libcurl|qmi-utils|mbim-utils|libmbim|libqmi|umbim|uqmi|comgt'"
	run 5  "Firmware" cat /etc/openwrt_release
	run 5  "Board model" sh -c "cat /tmp/sysinfo/model 2>/dev/null; cat /proc/device-tree/model 2>/dev/null"
	run 5  "Uptime / memory" sh -c "uptime; free"
	run 5  "Time (matters for eSIM TLS)" sh -c "date; echo 'UTC:'; date -u"

	collect "config"
	run 5  "uci 5gmodem" uci -q show 5gmodem
	run 5  "uci 5gmodem (SMS section)" sh -c "uci -q show 5gmodem | grep -E '\.sms\.' || echo '(the sms section is empty)'"
	run 5  "uci lpac" uci -q show lpac
	# Пароли/ключи из network не выводим: там PPP/PPPoE-креды и Wi-Fi.
	run 5  "uci network (secrets stripped)" sh -c "uci -q show network | grep -viE 'password|key|passwd|psk|secret'"
	# Интерфейсы: и СЕКЦИОННЫЕ (из 5gmodem), и ВСЕ модемные из network - секция
	# может ссылаться на чужой/несуществующий интерфейс, а собственный при этом
	# осиротеет, и в отчёте его было не видно вовсе. Плюс ДОЧЕРНИЕ интерфейсы
	# (<iface>_4/_6): у qmi/mbim IPv4 живёт именно в них, и без них нельзя
	# отличить «поднялся с адресом» от «поднялся, но DHCP не дал IP».
	run 10 "Modem interfaces" sh -c "for i in \$( { uci -q show 5gmodem | sed -n \"s/.*\.network='\(.*\)'/\1/p\"; uci -q show network | sed -n \"s/^network\.\([^.]*\)\.modem_path=.*/\1/p\"; } | sort -u); do for j in \"\$i\" \"\${i}_4\" \"\${i}_6\"; do s=\$(ifstatus \"\$j\" 2>/dev/null | grep -vE '\"(dns-search|route)\"'); [ -n \"\$s\" ] && { echo \"### \$j\"; echo \"\$s\"; }; done; done"

	collect "usb"
	run 10 "USB devices" sh -c "lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null"
	run 10 "Modem list" "$RES/listmodems.sh" --refresh
	# КАРТА ПОРТОВ ПРЯМО ИЗ SYSFS + IMEI с портов каждого устройства. Список
	# выше строит наш listmodems, и проверить его по отчёту было нечем: на двух
	# одинаковых модулях (один vid:pid) нельзя было отличить «клонированный IMEI»
	# от «наша привязка портов ошиблась». Здесь всё берётся мимо нашего кода, плюс
	# печатается USB-серийник (различает одинаковые модули) и готовый вердикт.
	run 40 "Port map and IMEI (from sysfs)" "$RES/portmap.sh"
	run 5  "Active modem" "$RES/modemswitch.sh" active
	# УСТРОЙСТВО В ЧЁРНОМ СПИСКЕ - НАЗЫВАЕМ ЭТО ВСЛУХ.
	#
	# Отмеченное устройство мы намеренно не считаем модемом: ему не ищут
	# AT-порт, у него нет метрик и диапазонов. Со стороны это выглядит как
	# поломка - «модем есть, а приложение его не видит», и в отчёте признак
	# был виден только строкой ignore_vidpid среди сотни строк uci. Живой
	# случай 04.09.2026: человек дважды прислал отчёт с заблокированным
	# собственным модемом и не заметил причину.
	run 5  "Device blacklist" sh -c '
		_bl=$(uci -q get 5gmodem.@5gmodem[0].ignore_vidpid)
		if [ -z "$_bl" ]; then echo "empty - this section does not apply"; exit 0; fi
		echo "hidden by hand: $_bl"
		for _p in $(/usr/share/5gmodem/registry.sh paths 2>/dev/null); do
			_v=$(cat /sys/bus/usb/devices/"$_p"/idVendor 2>/dev/null)
			_d=$(cat /sys/bus/usb/devices/"$_p"/idProduct 2>/dev/null)
			[ -n "$_v" ] || continue
			for _b in $_bl; do
				[ "$_v:$_d" = "$_b" ] || continue
				echo "WARNING: device $_p ($_b) IS ON THE BUS but is marked"
				echo "  as \"not a modem\". The app does not look for an AT port for it"
				echo "  and shows no metrics - which looks exactly like \"the modem is gone\"."
				echo "  To undo: Settings -> Device blacklist, clear the checkbox."
			done
		done'
	run 5  "AT port (detect.sh)" "$RES/detect.sh"
	run 5  "tty/cdc-wdm in the system" sh -c "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan* 2>/dev/null"
	run 10 "Who holds the ports" sh -c "for f in /dev/ttyUSB* /dev/cdc-wdm*; do [ -e \"\$f\" ] || continue; u=\$(fuser \"\$f\" 2>/dev/null); [ -n \"\$u\" ] && echo \"\$f: \$u\"; done; echo '--- processes ---'; ps w 2>/dev/null | grep -iE 'ModemManager|uqmi|mbim|sms_tool|lpac|gcom' | grep -v grep"

	# ПОЧЕМУ У МОДЕМА НЕТ AT-ПОРТОВ.
	#
	# У части композиций (05c6:9025/90d5/90d6) ttyUSB появляются только после
	# ручной привязки через new_id. Здесь видно, кому в итоге достались порты и
	# что об этом писал наш скрипт: снаружи «портов нет» неотличимо от поломки -
	# радио «проверить нечем», бенды «Port not found». Живой отчёт с двумя
	# T99W175 на ZBT (30.07) разбирался именно об это.
	run 10 "AT port binding (verdict)" sh -c '
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
			echo "$(basename "$d") [$v:$p] ports:${t:- NONE}"
		done
		[ "$N" = 0 ] && { echo "no modems that need manual port binding - this section does not apply"; exit 0; }
		echo "--- binding log ---"
		logread 2>/dev/null | grep "5gmodem-usbports" | tail -10 || echo "(no entries - the binding script never ran)"
		# СТРОКИ ЖУРНАЛА СВЕРЯЕМ С ТЕМ, ЧТО РЕАЛЬНО ПИШЕТ usbports.sh.
		#
		# Раньше здесь искалась фраза на русском («канал данных уже поднят») от
		# гварда, которого в скрипте давно нет: тот гвард вовсе отказывался
		# привязывать порты при живом канале, а теперь привязка идёт всегда и
		# канал спасается адресно. Условие не срабатывало НИКОГДА, и раздел
		# заканчивался списком портов без единого слова объяснения.
		if logread 2>/dev/null | grep -q "rescued data interface"; then
			echo "VERDICT: the serial driver DID take the data interface, and the app"
			echo "returned it to its native driver (see \"rescued data interface\" above)."
			echo "If cdc-wdm is still missing, the rescue did not stick - attach this report to the issue."
		elif logread 2>/dev/null | grep -q "already has ports - leaving the binding alone"; then
			echo "VERDICT: the ports were bound by someone else (the kernel table, an rc.local"
			echo "line, or our own earlier pass), so the app left the binding alone."
			echo "That is deliberate: the same composition written into new_id of TWO different"
			echo "drivers makes the kernel hand out interfaces at random, and the ports come out"
			echo "dead (measured on a live Compal: every ttyUSB answered with an I/O error)."
		fi'

	collect "mm"
	# На lite-пакете ModemManager отсутствует по определению - честная строка
	# вместо сырого «mmcli: not found» в отчёте (живой отчёт TR1200, 19.08.2026).
	run 15 "mmcli -L" sh -c 'command -v mmcli >/dev/null && mmcli -L || echo "mmcli is not installed (the modemmanager package) - normal for a lite build"'
	# Индексы берём из mmcli -L, а не наугад "-m 0": индекс меняется при каждом
	# рестарте MM, а на мёртвой шине "-m 0" просто висит до таймаута.
	run 40 "Modems in MM (detailed)" sh -c "mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | while read -r i; do echo \"### modem \$i\"; mmcli -m \"\$i\" -K 2>&1 | grep -viE 'password|\.pin'; done"
	# ВАЖНО: у mm-inhibit.sh НЕТ команды status - неизвестный аргумент попадает в
	# ветку "*)", а это ДЕМОН (while :; sleep 15). Вызов отсюда запускал бы лишнего
	# держателя инхибиции. Читаем состояние напрямую: pid-файлы + флаги в uci.
	run 5  "MM inhibition (ours)" sh -c "echo '--- active holders ---'; for f in /var/run/5gmodem-mm-inhibit/*.pid; do [ -f \"\$f\" ] || continue; p=\$(cat \"\$f\"); kill -0 \"\$p\" 2>/dev/null && echo \"\$(basename \"\$f\" .pid): pid \$p (alive)\" || echo \"\$(basename \"\$f\" .pid): pid \$p (dead)\"; done; echo '--- mm_exclude flags ---'; uci -q show 5gmodem | grep mm_exclude || echo '(not set)'"
	run 5  "MM autostart" sh -c "[ -x /etc/init.d/modemmanager ] || { echo 'ModemManager is not installed'; exit 0; }; /etc/init.d/modemmanager enabled && echo 'enabled' || echo 'disabled'"

	collect "at"
	P=$("$RES/detect.sh" 2>/dev/null)
	echo ""
	echo "AT port used for polling: ${P:-(not found)}"
	# ЖИВОЙ ДОЗВОНЩИК НА ПОРТУ ДЕЛАЕТ AT-ОТВЕТЫ МУСОРОМ: gcom (прото xmm/atc)
	# не знает про нашу очередь, ответы воруются в обе стороны и приходят со
	# сдвигом на команду. По такому мусору дальше строятся ложные вердикты
	# (живой отчёт 09.08.2026: фантомная «привязка к соте» на L850). Порт
	# уступаем, а в отчёте говорим прямо - это ценный факт: передозвон
	# крутится прямо сейчас.
	if [ -n "$P" ] && at_dialer_busy "$P" 2>/dev/null; then
		echo ""
		echo "WARNING: the netifd dialer (gcom) is working on this port right now."
		echo "AT polling was skipped: overlapping requests scramble the answers, and"
		echo "false diagnoses follow. The fact itself matters: the interface is in a"
		echo "redial loop - check the netifd log (logread | grep netifd)."
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
	run 20 "SIM slots" "$RES/simslot.sh" status
	# Сигнал по антенным портам: сразу видно неподключённый пигтейл (RSRP около
	# -140). Есть не у всех модемов - у кого нет, профиль отдаст "Unsupported".
	run 15 "Antenna ports (RSRP/RSRQ)" "$RES/bands.sh" getantports

	# УПРАВЛЕНИЕ БЕНДАМИ: каким путём идёт (vendor/mmcli) и что модем реально
	# отдаёт. Без этого «кнопки бендов не работают» приходилось разбирать вслепую:
	# по отчёту не видно ни какой профиль подключился, ни отвечает ли модем на
	# команды бенд-лока. Живой случай: Thales MV31-W (05c6:90d5) - тот же vid:pid
	# делят Thales и прототип Compal, у которых РАЗНЫЕ пути управления.
	run 20 "Band management: path" "$RES/bands.sh" mgmtinfo
	run 25 "Band management: what the app sees" "$RES/bands.sh" getinfo
	# QMI-ДОПОЛНЕНИЯ. У модема без AT-порта (или под ModemManager) текущий
	# диапазон, полоса и RSRP приходят ТОЛЬКО отсюда, и когда в карточке стоит
	# голое «4G» без подробностей, вопрос ровно один: qmicli вообще есть и что он
	# отвечает по этому узлу. По отчёту это было не видно - ни бинарника, ни
	# вывода (живой случай: два T99W175 на ZBT, 30.07).
	run 20 "QMI extras (band/signal)" sh -c '
		command -v qmicli >/dev/null 2>&1 || { echo "qmicli is NOT INSTALLED (the qmi-utils package) - nowhere to read the band and RSRP from"; exit 0; }
		W=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
		[ -c "$W" ] || { echo "the active modem has no cdc-wdm of its own - no QMI extras"; exit 0; }
		echo "node: $W"
		. /usr/share/5gmodem/lib.sh 2>/dev/null
		if command -v qmi_channel_free >/dev/null 2>&1 && ! qmi_channel_free; then
			echo "the channel is held by netifd (kernel proto qmi/qmiraw/mbim) - polling skipped on purpose, the connection matters more"
			exit 0
		fi
		MB=""
		case "$(readlink -f "/sys/class/usbmisc/${W##*/}/device/driver" 2>/dev/null)" in
			*/cdc_mbim) MB="--device-open-mbim" ;;
		esac
		# БЕЗ ФЛАГА ПРОКСИ. Он поднимал qmi-proxy, тот оставался жить после отчёта,
		# и следующий круг sessionwatch убивал его как сироту вместе с дозвоном.
		# Канал выше проверен свободным - идём напрямую и демона не плодим.
		echo "--- rf-band-info ---"; qmicli -d "$W" $MB --nas-get-rf-band-info 2>&1 | head -20
		echo "--- signal-info ---";  qmicli -d "$W" $MB --nas-get-signal-info 2>&1 | head -20'
	run 5  "Is lpac installed?" sh -c "ls -l /usr/bin/lpac /usr/lib/lpac 2>/dev/null; echo '--- dependencies ---'; ldd /usr/lib/lpac 2>/dev/null"
	# HTTPS к SM-DP+ - самая частая причина, почему СПИСОК профилей обновляется
	# (это чистый APDU), а ЗАГРУЗКА профиля молча не идёт: нет ca-bundle, кривое
	# время или lpac собран без HTTP-бэкенда.
	run 5  "CA certificates (needed to download a profile)" sh -c "ls -l /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'ca-bundle is NOT INSTALLED -> eSIM profile download will not work'"
	run 5  "HTTP backend in lpac" "$RES/esim.sh" httpinfo
	run 15 "Outbound HTTPS check" sh -c "curl -sS -o /dev/null -w 'code=%{http_code} tls=%{ssl_verify_result} time=%{time_total}s\n' https://ya.ru 2>&1 | head -3"
	# ЧЕМ ХОДИТ МОСТ APDU. Он написан под GNU wget (wget-ssl): --method,
	# --body-file, -S. busybox-wget этих ключей не знает и печатает СПРАВКУ
	# вместо запроса - в отчёте это выглядело как «transport failed» с текстом
	# man-страницы в поле причины, и распознать причину было нельзя (живой лог
	# 06.08.2026, FM350 на чистой прошивке). Теперь при busybox уходим на curl,
	# но GNU wget всё равно предпочтительнее: curl с mbedTLS не тянет часть
	# цепочек GSMA CI. Показываем, что есть на роутере.
	run 5  "HTTP client for eSIM (wget/curl)" sh -c '
		_w=$(wget --version 2>/dev/null | head -1)
		case "$_w" in
			*"GNU Wget"*) echo "wget: $_w - suitable for downloading a profile" ;;
			*) echo "wget: busybox (no --method/--body-file) - the bridge will use curl"
			   echo "  for the most reliable profile download: apk add wget-ssl" ;;
		esac
		if command -v curl >/dev/null 2>&1; then
			echo "curl: $(curl --version 2>/dev/null | head -1)"
		else
			echo "curl: NOT INSTALLED - if wget is busybox too, a profile download is impossible"
		fi'
	collect "esim"
	run 5  "eSIM: lpac config (AT/uqmi port)" sh -c "uci -q show lpac 2>/dev/null; echo '--- custom AID ---'; uci -q get lpac.global.custom_isd_r_aid 2>/dev/null || echo '(default A0000005591010FFFFFFFF8900000100)'"
	# ЧЕМ ХОДИМ К eUICC. Транспорт APDU выбирается автоматически по протоколу и
	# драйверу узла, и ошибка выбора выглядит снаружи неотличимо от «eSIM нет»:
	# code -1 "euicc_init" и «модем без eUICC». Печатаем выбор явно.
	run 10 "eSIM: APDU transport" "$RES/esim.sh" apduinfo
	# КАКОЙ ПОРТ РЕАЛЬНО ОТВЕЧАЕТ eUICC. Главная неочевидная причина «профиль не
	# читается»: eUICC-порт плавает при переперечислении (FM350 виден то на
	# ttyUSB1, то на ttyUSB3), а в lpac.at.device прибит один конкретный. Здесь
	# перебираем ВСЕ tty активного модема пробой CCHO (открытие канала к ISD-R):
	# порт, где канал открывается (ответ "+CCHO: N" или голый номер), и есть
	# eUICC-порт. Плюс печатаем АКТИВНЫЙ слот: lpac видит eUICC только когда
	# активен слот eSIM, а не физической SIM (у человека было active=0 - SIM).
	run 60 "eSIM: hunting for the eUICC port (CCHO over every tty)" sh -c '
		# Без lpac eSIM недоступна, и перебор (5 AT-команд на каждый порт,
		# до минуты на многопортовом модеме) не даст ничего полезного.
		if [ ! -x /usr/bin/lpac ]; then
			echo "lpac is not installed - the port sweep was skipped (eSIM unavailable)"
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
				echo "Sierra ($VP): the CCHO probe was skipped - on the EM9190 it wedged the SIM subsystem until the card was re-seated; on Sierra the eUICC lives behind QMI/MBIM, not AT"
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
		echo "active SIM slot: $(printf "%s" "$SL" | grep -o "\"active\":\"[^\"]*\"")"
		if [ -n "$SLE" ] && [ -n "$SLA" ] && [ "$SLE" != "$SLA" ]; then
			echo "the physical SIM slot ($SLA) is active, eSIM is slot $SLE: the modem has ONE channel to the card, so the eUICC ISD-R is unreachable right now and CCHO will not open on ANY port. This does not mean the chip is missing - switch the slot to eSIM and try again."
			exit 0
		fi
		echo "ports of modem $P:"
		for t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null); do
			for c in 1 2 3 4; do sms_tool -d "$t" at "AT+CCHC=$c" >/dev/null 2>&1; done
			R=$(sms_tool -d "$t" at "AT+CCHO=\"$AID\"" 2>/dev/null | tr -d "\r" | grep -v "^$" | grep -vi "^at+ccho" | head -1)
			case "$R" in
				*CCHO:*|[0-9]*) echo "  $t -> CHANNEL OPENED [$R]  <= this is the eUICC port" ;;
				*) echo "  $t -> no ([$R])" ;;
			esac
		done'
	# ТРИ САМЫХ ДОРОГИХ ШАГА ОТЧЁТА (60+90+60 c бюджета - треть всего). Гоняем их
	# только когда у eSIM есть хоть какой-то путь до чипа. Без lpac пути нет
	# вовсе; при AT-транспорте нужен tty, и на модеме без единого порта все три
	# шага гарантированно упрутся в "no AT port", отняв минуты. Человек с двумя
	# T99W175 (30.07) именно на этом месте решил, что диагностика повисла.
	_ES_SKIP=""
	if [ ! -x /usr/bin/lpac ]; then
		_ES_SKIP="lpac is not installed"
	elif [ "$("$RES/esim.sh" apduinfo 2>/dev/null | sed -n 's/^selected APDU backend: //p')" = "at" ] \
	     && [ -z "$("$RES/registry.sh" active 2>/dev/null | jsonfilter -e '@.tty[*]' 2>/dev/null)" ]; then
		_ES_SKIP="APDU transport is at, but the active modem has no tty at all"
	fi
	if [ -n "$_ES_SKIP" ]; then
		run 5 "eSIM: status/profiles/notifications" echo "skipped: $_ES_SKIP"
	else
		run 60 "eSIM: status" "$RES/esim.sh" status-probe
		run 90 "eSIM: profiles and chip" "$RES/esim.sh" dump
		run 60 "eSIM: notifications" "$RES/esim.sh" notifications
	fi

	collect "net"
	run 10 "Routes" sh -c "ip route; echo '--- ipv6 ---'; ip -6 route"
	# ПЕРВЫЙ ВОПРОС ЖАЛОБЫ «ИНЕТА НЕТ» - кто держит трафик и жив ли он. Стоит
	# сразу за маршрутами: дальше по отчёту читателя уносит в модемы, а причина
	# чаще здесь (аплинк с адресом, но без выхода) и в DNS ниже.
	run 40 "Who holds the internet (verdict)" uplink_verdict
	run 60 "DNS: resolving and rebind (verdict)" dns_verdict
	run 40 "QMI: frame format and counters (verdict)" qmi_format_verdict
	run 10 "uci firewall (zones)" sh -c "uci show firewall 2>/dev/null | grep -E 'zone|forwarding' | head -40"
	run 10 "The wan zone and NAT (verdict)" fw_zone_verdict
	run 15 "APN vs. the database (verdict)" apn_verdict
	run 15 "TTL override (verdict)" ttl_verdict
	run 15 "Access to the admin page (verdict)" webstack_verdict
	run 15 "Policy routing / mwan3 (verdict)" policyrouting_verdict
	# МИНЫ ЗАМЕДЛЕННОГО ДЕЙСТВИЯ: незакоммиченные правки uci. Дельты лежат в общем
	# /tmp/.uci и применяются ЧУЖИМ коммитом - спустя часы, из другого кода. Смена
	# lan.ipaddr, застрявшая здесь, выглядит потом как «роутер сам сломался»
	# (живой симптом: пинга до роутера нет, инет есть). Если тут что-то есть -
	# вот оно и есть главная улика.
	run 10 "Uncommitted uci changes (landmines)" sh -c 'uci changes 2>/dev/null | head -40; [ -z "$(uci changes 2>/dev/null)" ] && echo "(empty - no landmines)"'
	run 10 "USB power and stability (verdict)" usb_flap_verdict
	run 10 "On the bus but unconfigured? (verdict)" usb_unconfigured_verdict
	run 15 "Did usb_modeswitch break the composition? (verdict)" usbmode_verdict
	run 10 "Is the modem in bootloader mode? (verdict)" fastboot_verdict
	run 20 "Modem radio power (verdict)" power_state_verdict
	run 10 "Ping 77.88.8.8" ping -c 3 -W 2 77.88.8.8
	# IPv6-связность ЛИТЕРАЛОМ (без DNS - его при глушении тоже режут): Яндекс-DNS
	# 2a02:6b8::feed:0ff - v6-аналог 77.88.8.8. ipv6-internet.yandex.net не резолвится.
	run 10 "Ping IPv6 (2a02:6b8::feed:0ff)" sh -c "ping6 -c 3 -W 2 2a02:6b8::feed:0ff 2>/dev/null || ping -6 -c 3 -W 2 2a02:6b8::feed:0ff"
	run 20 "Log: ModemManager" sh -c "logread 2>/dev/null | grep -i modemmanager | tail -80"
	run 20 "Log: netifd/interfaces" sh -c "logread 2>/dev/null | grep -iE 'netifd|wwan|qmi|mbim|fibocom' | tail -80"
	run 20 "Log: kernel (USB)" sh -c "dmesg 2>/dev/null | grep -iE 'usb|option|qmi_wwan|cdc_|reset' | tail -60"
	run 20 "Log: the whole tail" sh -c "logread 2>/dev/null | tail -120"

	# Расшифровка кодов +CME ERROR, попавшихся ВЫШЕ по отчёту и в журнале.
	# Голое «+CME ERROR: 133» не говорит ничего даже нам; таблица общая
	# (см. cme.sh), поэтому раздел стоит копейки и закрывает вопрос «а что
	# это за число» разом для всех модемов.
	run 10 "+CME ERROR codes seen in this report" sh -c '
		. /usr/share/5gmodem/cme.sh
		{ cat /tmp/5gmodem-diag.txt 2>/dev/null; logread 2>/dev/null | tail -200; } \
			| grep -oE "CME ERROR: *[0-9]+" | grep -oE "[0-9]+" | sort -un | while read -r c; do
				t=$(cme_text "$c" 2>/dev/null) || t="(not in the reference table)"
				printf "  %-4s %s\n" "$c" "$t"
			done
		[ -s /tmp/5gmodem-diag.txt ] || echo "  (no CME errors in this report)"
	'

	collect "done"
	echo ""
	echo "===== end of report ====="
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
