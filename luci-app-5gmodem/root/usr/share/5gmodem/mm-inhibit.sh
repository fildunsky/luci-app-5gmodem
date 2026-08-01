#!/bin/sh
#
# Keep ModemManager OFF our kernel-proto modems on systems where the udev
# ID_MM_DEVICE_IGNORE rule can't apply - e.g. routers using libudev-zero, which
# provides the libudev API but runs no udevd and processes no /etc/udev rules.
# There MM grabs a kernel-proto modem (qmi/mbim/xmm/atc/fibocom/...), fails to
# manage it (the kernel owns the netdev), and then keeps re-probing its AT ports,
# colliding with our metrics reads -> the whole info page flickers.
#
# mmcli --inhibit releases a modem from MM and holds it released for as long as
# the mmcli process lives. So we run one background inhibitor per kernel-proto
# modem and keep them alive. Self-heals across MM restarts (the inhibitor's DBus
# drop makes MM re-add the modem; the next loop re-inhibits it) and modem
# re-plugs. Modems on the 'modemmanager' protocol are NEVER inhibited - MM must
# manage those. On systems WITH working udev the kernel-proto modems aren't
# visible to MM at all, so this simply finds nothing to do (harmless).
#
# Runs as a small procd service (see /etc/init.d/5gmodem-mm-inhibit).

. /usr/share/5gmodem/lib.sh 2>/dev/null   # at_query: очередь к порту + таймаут

RES=/usr/share/5gmodem
CFG=5gmodem
RUN=/var/run/5gmodem-mm-inhibit
mkdir -p "$RUN"

_is_kernel_proto() {
	case "$1" in qmi|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom) return 0 ;; *) return 1 ;; esac
}

# effective protocol of the modem at usb path $1: real iface proto, else remembered
_proto_for_path() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		NP=$(uci -q get "network.$IF.proto")
		[ -n "$NP" ] && { echo "$NP"; return; }
	fi
	uci -q get "$CFG.$SEC.iface_proto"
}

# Надо ли прятать модем на usb-пути $1 от ModemManager?
# Управляется галкой в настройках модема: 5gmodem.m_<path>.mm_exclude
#   1     - прятать; 0 - НЕ прятать (пользователь осознанно отдал модем MM);
#   пусто - умолчание: прячем всё, что работает на kernel-прото.
# Отключать бывает нужно: у MM богаче управление (режимы сети, 3G-бенды), и на
# части модемов оно полнее нашего qmi/AT-пути.
_mm_excluded() {
	SEC="m_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	case "$(uci -q get "$CFG.$SEC.mm_exclude")" in
		0) return 1 ;;
		1) return 0 ;;
	esac
	_is_kernel_proto "$(_proto_for_path "$1")"
}

# one pass: inhibit every kernel-proto modem currently visible in MM
#
# ВАЖНО: если модем ВИДЕН в `mmcli -L`, значит инхибиция на него сейчас НЕ
# действует - у работающей инхибиции MM модем не показывает вовсе. Поэтому сам
# факт попадания сюда означает, что держатель (если он есть) бесполезен.
inhibit_pass() {
	command -v mmcli >/dev/null 2>&1 || return 0

	# УБОРКА ДЕРЖАТЕЛЕЙ ОТСУТСТВУЮЩИХ МОДЕМОВ. Модем вынули - его pid-файл
	# инхибиции оставался навсегда (живой случай 31.07.2026: 1-1.3.pid после
	# извлечения Telit) и при возвращении железки давал бы гонку со свежим
	# держателем. Нет пути в sysfs - держателю жить незачем.
	for _ip_pf in "$RUN"/*.pid; do
		[ -f "$_ip_pf" ] || continue
		_ip_p="${_ip_pf##*/}"; _ip_p="${_ip_p%.pid}"
		[ -d "/sys/bus/usb/devices/$_ip_p" ] && continue
		kill "$(cat "$_ip_pf" 2>/dev/null)" 2>/dev/null
		rm -f "$_ip_pf"
	done

	# Инхибиция регистрируется по D-Bus и умирает ВМЕСТЕ с процессом MM (проверено:
	# после рестарта MM держатель жив, а модем снова захвачен). Поэтому следим за
	# pid'ом самого MM: сменился - все держатели устарели, снимаем их немедленно,
	# не дожидаясь таймаутов, иначе модем останется открытым и у qmi отберут канал.
	_cur=$(pgrep -f '/usr/sbin/ModemManager' 2>/dev/null | head -1)
	_prev=$(cat "$RUN/.mmpid" 2>/dev/null)
	if [ -n "$_cur" ] && [ "$_cur" != "$_prev" ]; then
		for pf in "$RUN"/*.pid; do
			[ -f "$pf" ] || continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		done
		echo "$_cur" > "$RUN/.mmpid"
	fi

	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		DEV=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ -n "$DEV" ] || continue
		PATHID=$(basename "$DEV")                 # e.g. 1-1.3
		case "$PATHID" in *-*) ;; *) continue ;; esac
		_mm_excluded "$PATHID" || continue        # modemmanager-прото / галка снята
		# ПАУЗА захвата (bands.sh mmtakeover): смена диапазонов на kernel-прото
		# временно отдаёт ЭТОТ модем ModemManager'у. Пока флаг есть - держатель
		# снимаем и модем НЕ инхибируем; остальные модемы инхибируются как обычно.
		if [ -f "$RUN/$PATHID.pause" ]; then
			pf="$RUN/$PATHID.pid"
			[ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
			continue
		fi
		pf="$RUN/$PATHID.pid"
		if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null; then
			# Держатель жив, но модем всё равно виден -> инхибиция не работает.
			# Даём ей минуту (она срабатывает не мгновенно), потом пересоздаём:
			# так лечится главный баг - держатель, зацепившийся за УСТАРЕВШИЙ
			# индекс. Индекс меняется при каждом рестарте MM, а `kill -0` при этом
			# по-прежнему говорит "процесс жив", и старый код считал, что всё в
			# порядке, - модем оставался у MM (у qmi отбирался канал -> нет IP).
			[ -z "$(find "$pf" -mmin +1 2>/dev/null)" ] && continue
			kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null
			rm -f "$pf"
		fi
		# Держим инхибицию по СТАБИЛЬНОМУ идентификатору устройства (sysfs-путь
		# из modem.generic.device), а НЕ по индексу -m: индекс живёт только до
		# следующего рестарта MM.
		setsid mmcli --inhibit-device="$DEV" >/dev/null 2>&1 &
		echo $! > "$pf"
		# Модем был ВИДЕН в MM - значит MM успел его забрать. Помечаем: на
		# следующем проходе проверим, не остался ли он без сессии данных.
		: > "$RUN/$PATHID.stolen"
	done
	# reap inhibitors whose process has exited (modem gone / MM restarted)
	for pf in "$RUN"/*.pid; do
		[ -f "$pf" ] || continue
		kill -0 "$(cat "$pf" 2>/dev/null)" 2>/dev/null || rm -f "$pf"
	done
	_restore_stolen
	# QMI-пул client-ID мог исчерпаться (утечки убитых прямых вызовов, повторы MM):
	# у Compal/SDX55 он ~6, и тогда MM не инициализирует модем ('unknown-capabilities')
	# - нет ни данных, ни управления бендами. Проверяем активный модем и при
	# исчерпании сбрасываем его (AT+CFUN=1,1, не чаще раза в 3 мин). Дёшево - один
	# qmicli -p за проход; для не-QMI модема (FM350) helper молча выходит.
	_am=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_am" ] && "$RES/qmi-recover.sh" recover "$_am" >/dev/null 2>&1
	# Держать MM запущенным ради ОТСУТСТВУЮЩЕГО модема незачем - именно он
	# при старте и хватает чужие модемы. Решение принимает mmneed.sh.
	"$RES/mmneed.sh" apply >/dev/null 2>&1
}

# MM видит модем на пути $1, а его modemmanager-интерфейс лежит -> поднять.
#
# netifd на буте поднимает modemmanager-интерфейс РАНЬШЕ, чем MM встаёт на D-Bus,
# не находит модем ("Device not managed by ModemManager"), кладёт интерфейс и
# БОЛЬШЕ НЕ ПРОБУЕТ. Кроме нас поднять его некому. Ждём появления ИМЕННО этого
# модема в mmcli (события ему только что переотправлены), затем ifup - в фоне и
# под гардом от параллельных подъёмов одного интерфейса.
_mm_ifup_if_down() {
	# local ОБЯЗАТЕЛЕН: без него _p/_sec/... утекают в главный цикл сервиса, а его
	# счётчик _n делит имя с нашими переменными -> "$((_n+1))" над строкой роняет
	# шелл (procd crash-loop, модем без IP на буте). Проверено трейсом на стенде.
	local _p _sec _mif _lk
	_p="$1"
	_sec="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_mif=$(uci -q get "$CFG.$_sec.network"); [ -n "$_mif" ] || return 0
	[ "$(uci -q get "network.$_mif.proto")" = modemmanager ] || return 0
	ifstatus "$_mif" 2>/dev/null | grep -q '"up": true' && return 0   # уже поднят
	# ГАРД от параллельных подъёмов + COOLDOWN: лок держится всё время попытки
	# (ожидание MM + ifup + добор коннекта), чтобы НЕ дёргать ifup повторно, пока
	# MM ещё коннектит. Повторный ifup делает teardown->setup и ПЕРЕБИВАЕТ коннект
	# (thrash: модем гоняется registered<->disabling и IP не встаёт - наблюдалось).
	# Порог staleness щедрый (>5 мин) - только страховка от умершего waiter'а;
	# в норме waiter снимает лок сам, закончив (успех или добор-таймаут).
	_lk="$RUN/$_p.ifup"
	[ -f "$_lk" ] && [ -z "$(find "$_lk" -mmin +5 2>/dev/null)" ] && return 0
	: > "$_lk"
	(
		_w=0
		while [ "$_w" -lt 120 ]; do
			for J in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
				_jd=$(mmcli -m "$J" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
				[ "$(basename "$_jd" 2>/dev/null)" = "$_p" ] || continue
				logger -t 5gmodem "MM увидел модем $_p - поднимаю интерфейс $_mif (netifd снёс его на буте до старта MM)"
				: > "$_lk"          # отметить старт попытки - от него считаем cooldown
				ifup "$_mif"
				# Не дёргаем повторно, пока идёт коннект: ждём up до 90с. Поднялся -
				# готово; нет - отпускаем лок, следующий проход попробует заново.
				_c=0
				while [ "$_c" -lt 90 ]; do
					ifstatus "$_mif" 2>/dev/null | grep -q '"up": true' && break
					sleep 3; _c=$((_c + 3))
				done
				rm -f "$_lk"; exit 0
			done
			sleep 2; _w=$((_w + 2))
		done
		rm -f "$_lk"
	) >/dev/null 2>&1 </dev/null &
}

# ЗЕРКАЛО inhibit_pass для modemmanager-прото: вернуть MM модем(ы), которые он
# ПОТЕРЯЛ на буте, и ПОДНЯТЬ их интерфейсы.
#
# На системах без рабочего udev (libudev-zero) MM НЕ сканирует уже существующие
# устройства при старте - живёт только на hotplug-событиях. При загрузке порты
# модема (cdc-wdm/ttyUSB/wwan) появляются РАНЬШЕ, чем MM встаёт на D-Bus, события
# летят в пустоту ("Couldn't report kernel event: couldn't find the ModemManager
# process in the bus"), а netifd ещё раньше кладёт интерфейс. Итог: модем БЕЗ IP.
# ПРОВЕРЕНО на Compal (Hiveton, MM 1.24): переотправка add-событий ПОСЛЕ подъёма MM
# -> модем появляется (Modem/N). Идемпотентно.
#
# ВАЖНО: чиним КАЖДЫЙ присутствующий modemmanager-модем, а не только активный -
# без IP на буте оставался каждый (в multi-modem раньше чинился лишь active_modem).
# И обязательно ДЕЛАЕМ ifup: без него модем появлялся в MM, но интерфейс, снесённый
# netifd, так и лежал.
# МОДЕМ СОБРАН БЕЗ КОНТРОЛ-ПОРТА (AT-only) - ПЕРЕСОБРАТЬ.
#
# ЗАЧЕМ. События портов приходят раньше, чем ModemManager готов их принять
# (libudev-zero не отдаёт coldplug, а наш new_id-бинд добавляет порты ещё
# позже). Если к моменту сборки модема MM не знал про cdc-wdm, он собирает его
# AT-only: primary становится ttyUSB, сетевой интерфейс числится ignored, и
# дата-беарер не поднимается НИКОГДА - connect падает с MobileEquipment.Unknown
# «No cause information available». Ребут не лечит: на следующем буте та же
# гонка. Воспроизведено на Compal RXM-G1 (05c6:90d6) после подключения второго
# модема - и повторяется после каждой перезагрузки.
#
# mm_recover_missing этот случай НЕ покрывал: он репортит порты, только когда
# модема в MM нет вовсе, а тут объект есть - просто неполный.
#
# Досыл события мало: MM не добавляет контрол-порт к УЖЕ собранному модему.
# Нужно, чтобы он забыл объект - поэтому передёргиваем само USB-устройство
# (unbind/bind), а затем объявляем порты в правильном порядке: сперва
# контрол-порт, потом сеть, потом tty. Проверено на живом модеме: primary
# становится cdc-wdm0 (mbim), wwan0 - (net), модем сразу connected.
_mm_fix_atonly() {   # $1 - usb-путь
	local _fp="$1" _fw _fwdm _fi I _d _fk _fstate _fmark _fnow _flast _fwait
	command -v mmcli >/dev/null 2>&1 || return 0
	# контрол-порт есть в СИСТЕМЕ? (иначе модем честно AT-only, чинить нечего)
	_fwdm=""
	for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
		[ -e "$_fw" ] && { _fwdm="$_fw"; break; }
	done
	[ -n "$_fwdm" ] || return 0
	# найти объект модема в MM по стабильному sysfs-пути
	_fi=""
	for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		_d=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
		[ "$(basename "$_d" 2>/dev/null)" = "$_fp" ] && { _fi="$I"; break; }
	done
	[ -n "$_fi" ] || return 0
	_fk=$(mmcli -m "$_fi" -K 2>/dev/null)
	# контрол-порт уже у модема - всё в порядке
	printf '%s\n' "$_fk" | grep -qE '^modem\.generic\.ports\.value\[[0-9]+\] *: *[A-Za-z0-9-]+ \((mbim|qmi)\)' && return 0
	# рабочее соединение НЕ рвём (на всякий случай - у AT-only его быть не может)
	_fstate=$(printf '%s\n' "$_fk" | sed -n 's/^modem\.generic\.state *: *//p')
	case "$_fstate" in connected|connecting|disconnecting) return 0 ;; esac
	# анти-цикл: не чаще раза в 5 минут на модем
	_fmark="/tmp/5gmodem_mmfix_$(printf '%s' "$_fp" | tr -c 'A-Za-z0-9' '_')"
	_fnow=$(cut -d. -f1 /proc/uptime)
	# Маркера НЕТ - чинить можно. Раньше здесь стоял _flast=0, и сразу после
	# загрузки (uptime < 300) разница uptime-0 оказывалась меньше порога, то есть
	# анти-цикл глушил фикс ровно в то окно, ради которого он и написан.
	_flast=$(cat "$_fmark" 2>/dev/null); case "$_flast" in ''|*[!0-9]*) _flast="" ;; esac
	[ -n "$_flast" ] && [ "$((_fnow - _flast))" -lt 300 ] && return 0
	printf '%s' "$_fnow" > "$_fmark" 2>/dev/null
	logger -t 5gmodem "MM собрал $_fp без контрол-порта (есть $(basename "$_fwdm")) - пересобираю модем"
	_mm_rebind "$_fp"
	return 0
}

# ПЕРЕПРИВЯЗКА USB-УСТРОЙСТВА - НАСТОЯЩИЙ HOTPLUG ВМЕСТО РУЧНОГО РЕПОРТА.
#
# mmcli --report-kernel-event сообщает MM ИМЯ узла, но не даёт свойств, которые
# на нормальной системе приносит udev. С libudev-zero этого не хватает: MM
# добавляет порты и тут же признаёт их неопознанными -
#   [plugin/generic] could not grab port cdc-wdm1: unhandled port type
#   [base-manager] couldn't create modem ...: Failed to find primary AT port
# - и модем не собирается ВООБЩЕ. unbind/bind рождает честные события ядра, и
# тот же модем собирается с первого раза (проверено на стенде 01.08.2026:
# после трёх безуспешных репортов - «modem successfully created»).
_mm_rebind() {   # $1 - usb-путь
	local _rb_p="$1" _fw _fwait
	printf '%s' "$_rb_p" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
	sleep 4
	printf '%s' "$_rb_p" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
	_fp="$_rb_p"
	# ЖДЁМ ФАКТА, А НЕ СЕКУНД. Переэнумерация этого модуля занимает ~20-30 c
	# (у него ещё и наш new_id-бинд ttyUSB следом), а фиксированный sleep 8
	# уходил вперёд: события уходили в MM до появления узлов, и модем пропадал
	# из MM совсем. Ждём сам контрол-порт, максимум 40 c.
	_fw=""; _fwait=0
	while [ "$_fwait" -lt 40 ]; do
		for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
			[ -e "$_fw" ] && break 2
		done
		_fw=""; sleep 2; _fwait=$((_fwait + 2))
	done
	[ -n "$_fw" ] || { logger -t 5gmodem "пересборка $_fp: контрол-порт не вернулся за ${_fwait}c"; return 0; }
	sleep 3
	for _fw in /sys/bus/usb/devices/"$_fp":*/usbmisc/cdc-wdm* /sys/bus/usb/devices/"$_fp":*/usbmisc/wdm*; do
		[ -e "$_fw" ] && mmcli --report-kernel-event="action=add,subsystem=usbmisc,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 2
	for _fw in /sys/bus/usb/devices/"$_fp":*/net/*; do
		[ -e "$_fw" ] && mmcli --report-kernel-event="action=add,subsystem=net,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 1
	for _fw in /sys/bus/usb/devices/"$_fp":*/ttyUSB* /sys/bus/usb/devices/"$_fp":*/tty/ttyUSB*; do
		[ -e "$_fw" ] && mmcli --report-kernel-event="action=add,subsystem=tty,name=$(basename "$_fw")" >/dev/null 2>&1
	done
	sleep 10
	_mm_ifup_if_down "$_fp"
}

mm_recover_missing() {
	# local ОБЯЗАТЕЛЕН: цикл `for _n in .../net/*` ниже делит имя _n со счётчиком
	# главного цикла сервиса - без local он утекал и ронял шелл на арифметике
	# (см. _mm_ifup_if_down).
	local _rp _seen I _d _if _t _w _n _rb_mk _rb_now _rb_first _rb_cd _rb_last
	command -v mmcli >/dev/null 2>&1 || return 0
	pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1 || return 0   # демон должен быть жив
	for _rp in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_rp" in *-*) ;; *) continue ;; esac
		[ "$(_proto_for_path "$_rp")" = modemmanager ] || continue  # только modemmanager-прото
		# уже собран в MM? сверяем по СТАБИЛЬНОМУ sysfs-пути (basename == usb path)
		_seen=0
		for I in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
			_d=$(mmcli -m "$I" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p')
			[ "$(basename "$_d" 2>/dev/null)" = "$_rp" ] && { _seen=1; break; }
		done
		if [ "$_seen" = 0 ]; then
			# ЕСЛИ РЕПОРТ УЖЕ НЕ ПОМОГ - ПЕРЕПРИВЯЗЫВАЕМ УСТРОЙСТВО.
			#
			# Ручной --report-kernel-event с libudev-zero часто бесполезен: MM
			# добавляет порты, но не может их классифицировать («unhandled port
			# type», «Failed to find primary AT port») и модем не собирает. На
			# стенде 01.08.2026 три круга репортов подряд не дали ничего, а
			# unbind/bind собрал модем с первого раза. Поэтому: первый круг -
			# дешёвый репорт, а если через минуту модема в MM всё ещё нет -
			# настоящий hotplug. Кулдаун 5 минут на модем, как у пересборки
			# AT-only: перепривязка это десятки секунд переэнумерации.
			_rb_mk="$RUN/$(printf '%s' "$_rp" | tr -c 'A-Za-z0-9' '_').missing"
			_rb_now=$(cut -d. -f1 /proc/uptime)
			_rb_first=$(cat "$_rb_mk" 2>/dev/null)
			case "$_rb_first" in ''|*[!0-9]*) _rb_first="" ;; esac
			if [ -z "$_rb_first" ]; then
				printf '%s' "$_rb_now" > "$_rb_mk" 2>/dev/null
			elif [ "$((_rb_now - _rb_first))" -ge 60 ]; then
				_rb_cd="/tmp/5gmodem_mmrebind_$(printf '%s' "$_rp" | tr -c 'A-Za-z0-9' '_')"
				_rb_last=$(cat "$_rb_cd" 2>/dev/null)
				case "$_rb_last" in ''|*[!0-9]*) _rb_last="" ;; esac
				if [ -z "$_rb_last" ] || [ "$((_rb_now - _rb_last))" -ge 300 ]; then
					printf '%s' "$_rb_now" > "$_rb_cd" 2>/dev/null
					rm -f "$_rb_mk" 2>/dev/null
					logger -t 5gmodem "MM не собрал модем $_rp после переотправки событий - перепривязываю устройство"
					_mm_rebind "$_rp"
					continue
				fi
			fi
			# объекта нет -> переотправляем MM add-события всех портов USB-устройства
			for _if in /sys/bus/usb/devices/"$_rp":*; do
				[ -d "$_if" ] || continue
				for _t in "$_if"/ttyUSB* "$_if"/tty/ttyUSB* "$_if"/tty/tty*; do
					[ -e "$_t" ] && mmcli --report-kernel-event="action=add,subsystem=tty,name=$(basename "$_t")" >/dev/null 2>&1
				done
				for _w in "$_if"/usbmisc/cdc-wdm* "$_if"/usbmisc/wdm*; do
					[ -e "$_w" ] && mmcli --report-kernel-event="action=add,subsystem=usbmisc,name=$(basename "$_w")" >/dev/null 2>&1
				done
				for _n in "$_if"/net/*; do
					[ -e "$_n" ] && mmcli --report-kernel-event="action=add,subsystem=net,name=$(basename "$_n")" >/dev/null 2>&1
				done
			done
		fi
		# Модем В MM ЕСТЬ, но собран без контрол-порта - пересобрать (см. функцию).
		[ "$_seen" = 1 ] && {
			rm -f "$RUN/$(printf '%s' "$_rp" | tr -c 'A-Za-z0-9' '_').missing" 2>/dev/null
			_mm_fix_atonly "$_rp"
		}
		# MM (вот-вот) видит модем -> поднять его интерфейс, если лежит.
		_mm_ifup_if_down "$_rp"
	done
}

# Поднять модем, у которого MM отобрал и разорвал сессию данных.
#
# ЗАЧЕМ. Захватив чужой модем, MM снимает регистрацию и выключает его
# ("state changed (registered -> disabling)" -> "disabled modem"). Запрет,
# наложенный следом, возвращает нам модем, но НЕ восстанавливает соединение, и
# поднять его некому. Наблюдалось вживую на FM350: netifd держал up=true со
# СТАРЫМ адресом и маршрутом "default dev eth2 scope link" в никуда, интернета
# не было, метрики показывали один диапазон - и ничто в интерфейсе не намекало
# на причину.
_restore_stolen() {
	for mf in "$RUN"/*.stolen; do
		[ -f "$mf" ] || continue
		# Даём запрету время лечь: сразу после mmcli модем ещё возвращается в
		# наши руки, и спрашивать его рано.
		[ -z "$(find "$mf" -mmin +1 2>/dev/null)" ] && continue
		PATHID=$(basename "$mf" .stolen)
		rm -f "$mf"
		SEC="m_$(echo "$PATHID" | sed 's/[^A-Za-z0-9]/_/g')"
		IF=$(uci -q get "$CFG.$SEC.network")
		[ -n "$IF" ] || continue
		# Правду о сессии знает МОДЕМ, а не netifd - см. пояснение выше.
		# Спрашиваем ДВУМЯ независимыми способами, потому что ни один не
		# самодостаточен:
		#   AT+CGACT? - точен, но порт может молчать (он занят нашим же опросом
		#     метрик, а после встряски со стороны MM ещё и перенумеровывается);
		#     именно это и наблюдалось - в момент разрыва порт не отвечал вовсе.
		#   ping через интерфейс - не зависит от AT-портов, но отвечает на вопрос
		#     "есть ли связь", а не "жив ли контекст".
		# Действуем, только если ЕСТЬ положительное доказательство разрыва.
		_dead=""
		ATP=$(uci -q get "$CFG.$SEC.at_port")
		if [ -n "$ATP" ] && [ -c "$ATP" ] && command -v sms_tool >/dev/null 2>&1; then
			# at_query: очередь к порту и таймаут. Этот вызов идёт из петли, живущей
			# всё время работы демона, и без очереди он конкурировал с опросом метрик.
			RAW=$(at_query "$ATP" "AT+CGACT?" 6)
			if echo "$RAW" | grep -q "OK"; then
				# Порт ответил - верим ему.
				echo "$RAW" | grep -qE '\+CGACT: *[0-9]+, *1' && continue
				_dead="контекст не активен"
			fi
		fi
		if [ -z "$_dead" ]; then
			# Порт промолчал. Проверяем связь через сам интерфейс.
			L3=$(ubus call "network.interface.$IF" status 2>/dev/null \
				| jsonfilter -e '@.l3_device' 2>/dev/null)
			[ -n "$L3" ] || continue
			# 77.88.8.8 (Яндекс), а не 8.8.8.8 - последний недоступен в РФ.
			ping -c 2 -W 4 -I "$L3" 77.88.8.8 >/dev/null 2>&1 && continue
			# ПИНГА МАЛО. У части операторов ICMP закрыт наглухо, и молчание на
			# пинг не значит отсутствия связи: проверено на живом МегаФоне -
			# 100% потерь пакетов, при этом HTTP отвечает за 0.4 с. Полагаться
			# на один пинг значило бы регулярно рвать рабочее соединение.
			if command -v curl >/dev/null 2>&1; then
				curl -s --max-time 8 --interface "$L3" -o /dev/null \
					http://ip-api.com/line/?fields=query 2>/dev/null && continue
			fi
			_dead="нет связи через $L3"
		fi
		logger -t 5gmodem "MM забрал $PATHID и оставил без сессии данных ($_dead) - поднимаем $IF"
		ifdown "$IF" >/dev/null 2>&1
		sleep 3
		ifup "$IF" >/dev/null 2>&1
	done
}

case "$1" in
# set-exclude <секция модема> <0|1> - переключатель из настроек модема.
# Пишем флаг и СРАЗУ применяем: при включении прячем модем от MM, при выключении
# снимаем держателя, чтобы MM подхватил модем без перезагрузки.
set-exclude)
	[ -n "$2" ] || exit 0
	uci -q set "$CFG.$2.mm_exclude=${3:-1}"
	uci -q commit "$CFG"
	PATHID=$(uci -q get "$CFG.$2.path")
	if [ "${3:-1}" = "0" ] && [ -n "$PATHID" ]; then
		pf="$RUN/$PATHID.pid"
		[ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }
	else
		inhibit_pass
	fi
	;;
once)  inhibit_pass; mm_recover_missing ;;
# Пауза/снятие инхибиции ОДНОГО модема (usb-путь $2) на время захвата MM под
# смену диапазонов. pause снимает держателя сразу, чтобы MM подхватил модем без
# ожидания; resume убирает флаг - следующий проход инхибирует обратно.
pause)   [ -n "$2" ] && { mkdir -p "$RUN"; : > "$RUN/$2.pause"; pf="$RUN/$2.pid"; [ -f "$pf" ] && { kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null; rm -f "$pf"; }; } ;;
resume)  [ -n "$2" ] && rm -f "$RUN/$2.pause" ;;
stop)  for pf in "$RUN"/*.pid; do [ -f "$pf" ] && kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; done ;;
*)
	# Реагируем на СТАРТ MM сразу, а не по общему таймеру. Пока запрет не лёг,
	# MM успевает захватить и выключить чужой модем - при 15-секундном цикле это
	# окно почти гарантированно ловится (проверено: MM поднялся ради соседнего
	# модема на proto=modemmanager и по дороге выключил FM350).
	# Дорогой проход (mmcli -L, по процессу на модем) делаем по-прежнему раз в
	# ~15 с, а между ними только дешёвый pgrep.
	_last_pid=""
	_n=99                       # первый проход - сразу
	while :; do
		_pid=$(pgrep -f '/usr/sbin/ModemManager' 2>/dev/null | head -1)
		if [ "$_pid" != "$_last_pid" ] || [ "$_n" -ge 5 ]; then
			_last_pid="$_pid"
			_n=0
			inhibit_pass
			mm_recover_missing
		fi
		_n=$((_n + 1))
		sleep 3
	done
	;;
esac
