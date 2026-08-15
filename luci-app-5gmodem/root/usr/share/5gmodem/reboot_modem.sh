#!/bin/sh
#
# Restart the modem. Two modes:
#
#   soft (default): cycle the radio only, AT+CFUN=4 -> AT+CFUN=1. Forces a fresh
#     network attach/reconnect WITHOUT re-enumerating USB, so ModemManager keeps
#     its MBIM port classification and the data channel is only briefly
#     interrupted. Use this for "re-register / apply bands".
#
#   hard: full modem reset, AT+CFUN=1,1. The modem reboots and re-enumerates on
#     the USB bus. Takes longer and, on MM-managed MBIM modems, MM may briefly
#     misclassify the data port after re-enumeration (connection can drop for a
#     minute). Use this when the soft restart is not enough (modem wedged).
#
# Usage: reboot_modem.sh [soft|hard] [at_port]
#   For backwards compatibility a first argument of /dev/... is treated as the
#   port and the mode defaults to soft.
#

MODE="$1"
PORT="$2"
case "$MODE" in
	soft|hard|power|haspower|usbpower|hasusbpower) ;;
	/dev/*)    PORT="$MODE"; MODE="soft" ;;   # старый вызов: reboot_modem.sh <port>
	*)         MODE="soft" ;;
esac

# Аппаратная перезагрузка модема по питанию через GPIO платы (например
# modem_power у Huasifei WH3000; у части плат - 4g/5g1/5g2). Работает независимо
# от AT: снимаем питание слота (value=1), пауза, возвращаем (value=0); интерфейс
# поднимается ~1 мин. На WH3000 это питает ТОЛЬКО M.2-слот (USB-модем не трогает).
# Список известных имён GPIO сброса/питания модема (по target/.../03_gpio_switches).
# modem_reset (напр. Almond 3S, GPIO33 active_low - полярность разруливает ядро,
# sysfs-value логический) сбрасывается той же
# последовательностью 1->пауза->0, что и modem_power, поэтому в общем списке.
POWER_GPIOS="modem_power modem_reset 4g 5g1 5g2"
first_power_gpio() {
	for _g in $POWER_GPIOS; do
		[ -e "/sys/class/gpio/$_g/value" ] && { echo "$_g"; return 0; }
	done
	return 1
}

# --- Снятие питания с USB-порта модема ---------------------------------------
#
# Последний рубеж, когда не помогает НИЧЕГО из AT. Наблюдалось вживую на FM350:
# после AT+CFUN=1,1 модем ушёл в переподключение USB и завис - CSQ 99,99 (сигнала
# нет), регистрации нет, порт то отвечает, то молчит. Ни CFUN=4/1, ни COPS=0,
# ни повторный CFUN=1,1 его не вернули: AT-канал жив, а радио мертво.
#
# GPIO-режим power сюда не годится: на многих платах (в т.ч. Huasifei WH3000) он
# питает ТОЛЬКО M.2-слот и USB-модема не касается.
#
# Три способа по убыванию силы - берём первый доступный:
#   1. <хаб>/<порт>/disable - отключение порта хабом. Самый жёсткий: на хабах с
#      управлением питанием снимает VBUS, то есть настоящее обесточивание.
#   2. authorized - деавторизация устройства. Питание остаётся, но ядро
#      полностью переустанавливает устройство.
#   3. unbind/bind драйвера usb - самый мягкий, на зависшем модеме помогает реже.
_usb_port_dir() {   # $1 - usb-путь модема (напр. 2-1.4)
	case "$1" in
		*.*)
			_hub="${1%.*}"                     # 2-1.4 -> 2-1
			_pn="${1##*.}"                     # -> 4
			echo "/sys/bus/usb/devices/$_hub/$_hub:1.0/$_hub-port$_pn"
			;;
		*-*)
			# Модем воткнут прямо в корневой хаб: 2-1 -> usb2, порт 1
			_bus="${1%%-*}"; _pn="${1##*-}"
			echo "/sys/bus/usb/devices/usb$_bus/$_bus-0:1.0/usb$_bus-port$_pn"
			;;
	esac
}

usb_power_method() {   # $1 - usb-путь; печатает доступный способ или пусто
	_pd=$(_usb_port_dir "$1")
	[ -n "$_pd" ] && [ -w "$_pd/disable" ] && { echo "disable"; return 0; }
	[ -w "/sys/bus/usb/devices/$1/authorized" ] && { echo "authorized"; return 0; }
	[ -w /sys/bus/usb/drivers/usb/unbind ] && [ -e "/sys/bus/usb/devices/$1" ] \
		&& { echo "rebind"; return 0; }
	return 1
}

if [ "$MODE" = hasusbpower ]; then
	# наличие кнопки: путь берём из активного модема, если не задан явно
	_p="$PORT"
	[ -n "$_p" ] || _p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	echo "{\"path\":\"$_p\",\"method\":\"$(usb_power_method "$_p" 2>/dev/null)\"}"
	exit 0
fi

if [ "$MODE" = usbpower ]; then
	_p="$PORT"
	[ -n "$_p" ] || _p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_p" ] || { echo '{"success":false,"error":"no modem path"}'; exit 0; }
	_m=$(usb_power_method "$_p") || { echo '{"success":false,"error":"no usb power control"}'; exit 0; }
	_pd=$(_usb_port_dir "$_p")
	# В фоне с отвязкой дескрипторов НА ПОДОБОЛОЧКЕ - иначе rpcd ждёт EOF и
	# упирается в свой 30-секундный таймаут (та же грабля, что в ветке power).
	(
		case "$_m" in
			disable)
				echo 1 > "$_pd/disable" 2>/dev/null
				sleep 6
				echo 0 > "$_pd/disable" 2>/dev/null
				;;
			authorized)
				echo 0 > "/sys/bus/usb/devices/$_p/authorized" 2>/dev/null
				sleep 6
				echo 1 > "/sys/bus/usb/devices/$_p/authorized" 2>/dev/null
				;;
			rebind)
				echo "$_p" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
				sleep 6
				echo "$_p" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
				;;
		esac
		logger -t 5gmodem "usbpower: $_p перезапущен по питанию ($_m)"
		# Порты после переподключения переименовываются - закрепляем заново.
		sleep 20
		/usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
	echo "{\"success\":true,\"mode\":\"usbpower\",\"method\":\"$_m\",\"path\":\"$_p\"}"
	exit 0
fi

if [ "$MODE" = haspower ]; then
	# наличие кнопки: отдаём имя первого доступного GPIO питания (или пусто)
	echo "{\"gpio\":\"$(first_power_gpio)\"}"
	exit 0
fi

if [ "$MODE" = power ]; then
	# 2-й аргумент можно использовать как явное имя GPIO; иначе - первый доступный
	G="$PORT"; [ -n "$G" ] || G=$(first_power_gpio)
	GP="/sys/class/gpio/$G/value"
	[ -n "$G" ] && [ -e "$GP" ] || { echo '{"success":false,"error":"no modem power gpio"}'; exit 0; }
	# В фоне: снять питание, пауза 5с, вернуть.
	# ВАЖНО - >/dev/null 2>&1 </dev/null НА САМОЙ подоболочке, а не только на
	# командах внутри. Скрипт вызывается через rpcd (LuCI fs.exec), а тот ждёт не
	# только выхода процесса, но и EOF на пайпах stdout/stderr. Фоновая
	# подоболочка наследовала эти пайпы и держала их открытыми -> rpcd упирался в
	# свой 30-секундный таймаут, и UI показывал «ошибка XHR», хотя питание уже
	# было переключено (ровно этот симптом и наблюдался). С отвязанными
	# дескрипторами ubus file exec отвечает мгновенно (проверено на роутере).
	( echo 1 > "$GP" 2>/dev/null; sleep 5; echo 0 > "$GP" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
	echo "{\"success\":true,\"mode\":\"power\",\"gpio\":\"$G\"}"
	exit 0
fi

# --- МОДЕМ БЕЗ AT-ПОРТОВ -----------------------------------------------------
# У HiLink-модема перезагрузка делается его же API: AT-канала, куда послать
# CFUN, попросту нет. Без этой ветки кнопка возвращала бы "AT port not found",
# хотя перезагрузить модем вполне возможно.
_rb_am=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$_rb_am" ]; then
	_rb_sec="m_$(echo "$_rb_am" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ "$(uci -q get "5gmodem.$_rb_sec.kind")" = "hilink" ]; then
		# В фоне с отвязкой дескрипторов: модем уходит с шины, и синхронный
		# вызов досидел бы до таймаута rpcd (та же грабля, что и в ветке power).
		( /usr/share/5gmodem/hilink.sh reboot "$_rb_am" ) >/dev/null 2>&1 </dev/null &
		echo '{"success":true,"mode":"hilink-api"}'
		exit 0
	fi
fi

[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

# Перезагрузка модема должна попасть в порт ЦЕЛИКОМ: команда, перехваченная
# посреди чужого обмена, молча не сработает, а пользователь увидит "перезагружаю"
# и ничего больше.
. /usr/share/5gmodem/atlock.sh
at_lock "$PORT" 15

if [ "$MODE" = "hard" ]; then
	# Full reset (AT+CFUN=1,1): the modem reboots and RE-ENUMERATES on USB, so
	# the AT port vanishes mid-command - a synchronous sms_tool would block ~35s
	# and the UI XHR would time out even though the reset succeeded. Fire it in
	# the background and return at once; the resolve hotplug re-pins ports and
	# brings the interface back after re-enumeration (no ifup here - the port is
	# gone).
	# Редирект нужен НА подоболочке (см. ветку power выше): иначе она наследует
	# пайпы rpcd и держит их, пока sms_tool ждёт ответа от исчезнувшего порта, -
	# rpcd досиживает до таймаута, и «фон» не спасает от «ошибки XHR».
	IF=$(uci -q get 5gmodem.@5gmodem[0].network)
	_AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	( sms_tool -d "$PORT" at "AT+CFUN=1,1" ) >/dev/null 2>&1 </dev/null &
	# ФАНТОМНАЯ СЕССИЯ ПОСЛЕ РЕБУТА. После CFUN=1,1 модем переэнумерируется на USB,
	# НО у fibocom/xmm/ecm сетевое устройство (RNDIS/CDC) не отваливается -> netifd
	# считает интерфейс всё ещё поднятым и после возврата модема НЕ передозванивается.
	# Интерфейс висит со старым IP и мёртвой сессией (проверено вживую: uptime
	# интерфейса не сбрасывался, IP прежний, CGACT/пинг — Network unreachable), из-за
	# чего казалось, что модем вовсе не перезагрузился. Сторож ждёт, пока модем реально
	# исчезнет и вернётся по USB-пути, и форсит down+up: down рвёт прото (teardown),
	# up запускает НОВЫЙ дозвон. ifup здесь мало — на «поднятом» интерфейсе это no-op.
	if [ -n "$IF" ] && [ -n "$_AMP" ]; then
	( eval "exec $AT_LOCK_FD>&-"    # не держим AT-замок весь долгий ожидания
	  _n=0
	  while [ "$_n" -lt 40 ] && [ -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  _n=0
	  while [ "$_n" -lt 100 ] && [ ! -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  [ -e "/sys/bus/usb/devices/$_AMP" ] || exit 0   # модем не вернулся - нечего дозванивать
	  sleep 8                        # дать resolve-hotplug перепривязать порты после переэнумерации
	  ubus call "network.interface.$IF" down >/dev/null 2>&1
	  sleep 3
	  # КАРТА ПОСЛЕ CFUN=1,1 ИНИЦИАЛИЗИРУЕТСЯ ДОЛГО - ДОЗВАНИВАЕМСЯ В ГОТОВУЮ.
	  #
	  # У QMI-модема (Telit LM960) карта после сброса поднимается до ~100 c. Если
	  # дозвониться сразу после переэнумерации, дозвон бьёт в ещё illegal-карту, и
	  # qmi.sh уходит в свой power-cycle-цикл SIM - а он же режет ей питание каждые
	  # 8 c и не даёт подняться НИКОГДА (петля кормит себя, живой случай 12.08.2026:
	  # лестница ребутила модем, а редозвон тут же ронял его обратно в illegal).
	  # Прото уже опущено (down выше), никто не дёргает канал - ждём готовности
	  # карты в этом тихом окне и только потом поднимаем, один раз, в живую карту
	  # (ровно так вручную поднимался IP: CFUN=1,1 -> пауза -> up). Потолок 120 c;
	  # чтение карты не удаётся (нет прокси) - молча досиживаем потолок, этого
	  # хватает на инициализацию. Не-QMI (device не cdc-wdm) окно пропускает.
	  _rbd=$(uci -q get "network.$IF.device")
	  case "$_rbd" in
		/dev/cdc-wdm*)
			_n=0
			while [ "$_n" -lt 24 ]; do
				case "$(uqmi -s -d "$_rbd" -t 3000 --uim-get-sim-state 2>/dev/null)" in
					*'"card_application_state":"ready"'*) break ;;
				esac
				sleep 5; _n=$((_n + 1))
			done ;;
	  esac
	  ubus call "network.interface.$IF" up >/dev/null 2>&1 || ifup "$IF" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
	fi
else
	# Soft radio restart (CFUN=4 -> CFUN=1): no USB re-enumeration, the port
	# stays. This drops the data bearer, so nudge the app's interface back up
	# (kernel qmi/mbim/atc/fibocom need it; MM-managed modems reconnect on their
	# own). Backgrounded so the script returns promptly to the UI.
	sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
	sleep 3
	sms_tool -d "$PORT" at "AT+CFUN=1" >/dev/null 2>&1
	IF=$(uci -q get 5gmodem.@5gmodem[0].network)
	# Намеренный soft-reconnect (кнопка «переподключить», применение бендов и т.п.),
	# не холодный boot-attach: гасим восстановление диапазонов на порождённый нами
	# ifup, иначе 31-5gmodem-bands сделал бы лишний CFUN поверх (двойной CFUN подряд
	# вешает PDP-контекст FM350).
	[ -n "$IF" ] && : > "/tmp/5gmodem_bandrestore_$IF" 2>/dev/null
	# Прицельно через ubus DOWN+UP, а не `ifup`: на части прошивок ifup вызывает
	# полную перезагрузку конфигурации ("hostapd: Reload all interfaces") и роняет
	# ЧУЖИЕ интерфейсы - на двухмодемном роутере от этого падал соседний модем.
	# Но ОДНОГО `ubus ... up` мало: после CFUN-цикла netifd считает интерфейс всё
	# ещё поднятым (у fibocom/xmm RNDIS-устройство не отваливается), и `up` на
	# up-интерфейсе - no-op, дозвон НЕ повторяется -> IP есть, инета нет
	# (регресс 1.7.1 на FM350, воспроизведён: ubus up -> 0 пакетов, down+up -> ок).
	# down форсирует teardown прото, up - заново дозвон; и то и другое прицельно,
	# глобального reload нет. ifup - фолбэк, если ubus-пути нет.
	[ -n "$IF" ] && ( sleep 6
		ubus call "network.interface.$IF" down >/dev/null 2>&1
		sleep 3
		ubus call "network.interface.$IF" up >/dev/null 2>&1 \
			|| ifup "$IF" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
fi

echo "{\"success\":true,\"mode\":\"$MODE\"}"
exit 0
