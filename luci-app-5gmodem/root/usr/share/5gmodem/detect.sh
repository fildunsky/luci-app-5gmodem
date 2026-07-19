#!/bin/sh

#
# (c) 2023-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2023-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#


#
# from config modemdefine
#
# --- МОДЕМ БЕЗ AT-ПОРТОВ -----------------------------------------------------
#
# У HiLink-модемов (Huawei E3372h и родня) AT-порта нет вовсе. Молчать об этом
# НЕЛЬЗЯ: без явного выхода поиск ниже доходил до перебора всех ttyUSB и отдавал
# порт ДРУГОГО модема - на живом стенде при активном Huawei возвращался
# /dev/ttyUSB3 от FM350. AT-консоль, SMS и USSD в таком случае молча говорили бы
# не с тем модемом, а пользователь видел бы ответы «своего».
# Пустой ответ честнее: вызывающие уже умеют его обрабатывать.
_dt_am=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$_dt_am" ]; then
	_dt_sec="m_$(echo "$_dt_am" | sed 's/[^A-Za-z0-9]/_/g')"
	[ "$(uci -q get "5gmodem.$_dt_sec.kind")" = "hilink" ] && exit 0
fi

CONFIG=modemdefine
MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [ -n "$MODEMZ" ]; then

	if [[ $MODEMZ = 0 ]]; then
    		DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
    	fi

	if [[ $MODEMZ = 1 ]]; then
    		DEVICE=$(uci -q get modemdefine.@modemdefine[0].comm_port)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi

	if [[ $MODEMZ > 1 ]]; then
		DEVICE=$(uci -q get modemdefine.@general[0].main_modem)
		if [ -n "$DEVICE" ]; then
			echo $DEVICE
			exit 0
		fi
	fi
fi


getdevicepath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		echo ${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		echo ${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
		echo ${devpath%/*}
		;;
	esac
}

# from config (manual selection always wins)
DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
if [ -n "$DEVICE" ]; then
	echo $DEVICE
	exit 0
fi

# auto-detection can be turned off in the settings (checkbox); default on.
# When off and no manual device is set, report nothing.
AUTO=$(uci -q get 5gmodem.@5gmodem[0].auto_port)
[ "$AUTO" = "0" ] && { echo ""; exit 0; }

# Multi-modem: return the ACTIVE modem's AT port, tracked by the app's
# modemswitch/listmodems by STABLE USB path. This replaces the old
# "mmcli -m any", which read whichever modem ModemManager listed FIRST (the
# wrong one when two modems are present) and required MM to be running - but our
# modems are deliberately hidden from MM. modemswitch pins at_port and the
# resolve hotplug self-heals it across renumbering.
# Принадлежит ли tty ЭТОМУ модему? Нумерация ttyUSB глобальная и при
# переэнумерации сдвигается, поэтому проверки "файл существует" НЕДОСТАТОЧНО:
# с двумя модемами /dev/ttyUSB1 легко оказывается портом СОСЕДНЕГО модема, и
# тогда метрики одного модема показываются на странице другого. Сверяем USB-путь
# из sysfs (дёшево, без единой AT-команды).
#   /sys/class/tty/ttyUSB1/device -> .../usb2/2-1/2-1.4/2-1.4:1.3/ttyUSB1
#   нас интересует "2-1.4" - каталог интерфейса без суффикса ":1.N".
tty_usbpath() {
	_tp=$(readlink -f "/sys/class/tty/$(basename "$1")/device" 2>/dev/null) || return 1
	[ -n "$_tp" ] || return 1
	_tp=${_tp%/*}          # отбросить сам ttyUSBn
	_tp=${_tp##*/}         # взять каталог интерфейса, напр. 2-1.4:1.3
	echo "${_tp%%:*}"      # -> 2-1.4
}
tty_belongs() {   # tty_belongs <tty> <usb_path>
	[ -n "$2" ] || return 0          # путь неизвестен - не мешаем работать
	[ "$(tty_usbpath "$1")" = "$2" ]
}

ACTP=$(uci -q get 5gmodem.@5gmodem[0].at_port)
_ACTM=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$ACTP" ] && [ -e "$ACTP" ] && tty_belongs "$ACTP" "$_ACTM"; then
	echo "$ACTP"
	exit 0
fi
# порт есть, но принадлежит ДРУГОМУ модему (сдвинулась нумерация после
# переэнумерации) - закреплённое значение протухло, сбрасываем и ищем заново
[ -n "$ACTP" ] && [ -e "$ACTP" ] && uci -q delete 5gmodem.@5gmodem[0].at_port
# not pinned yet (fresh boot before resolve): resolve the active modem's AT port
# by probing the ttys of its USB path (time-bounded, skips DIAG ports).
AMP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
if [ -n "$AMP" ] && [ -x /usr/share/5gmodem/listmodems.sh ]; then
	# Дешёвый кэш: atprobe молчащего DIAG-порта ждёт ~4 c, а перебор до
	# рабочего порта (напр. 3-го) давал ~8 c НА КАЖДЫЙ вызов detect.sh (а его
	# за загрузку страницы зовут несколько раз). Один раз найденный порт
	# кэшируем; проверка живого порта - это одна быстрая atprobe (~0.5 c).
	ATCACHE="/tmp/5gmodem_atport_$(echo "$AMP" | tr -c 'A-Za-z0-9' '_')"
	CP=$(cat "$ATCACHE" 2>/dev/null)
	# Проверку кэша НЕ делаем через atprobe: на MM-модеме atprobe шлёт AT на
	# порт, которым владеет ModemManager, и ждёт ~4 c (это и был весь тормоз
	# загрузки). Достаточно, что tty жив (символьное устройство). Если модем
	# переперечислился - tty исчезнет и кэш инвалидируется; смена функции того
	# же номера редка, и тогда downstream-запрос сам вызовет пере-детект.
	if [ -n "$CP" ] && [ -c "$CP" ] && tty_belongs "$CP" "$AMP"; then
		echo "$CP"
		exit 0
	fi
	# кэш указывает на чужой порт - выбрасываем (см. tty_belongs)
	[ -n "$CP" ] && rm -f "$ATCACHE" 2>/dev/null
	# TWO-PASS. Сначала ищем НАСТОЯЩИЙ MODEM-порт (отвечает на AT+CGMM моделью) -
	# у многопортовых модемов (FM350 = 7 ttyUSB) на голый "AT" отвечает и часть
	# вспомогательных/DIAG-портов, а метрик они не отдают. Раньше брали первый
	# ответивший на "AT" - и на части прошивок это был не тот порт: IP есть,
	# метрики/логи пусты. Если MODEM-порт не нашёлся (у некоторых модемов CGMM
	# не на дозвонном порту) - второй проход берёт любой отвечающий на "AT".
	TTYS=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$AMP\"].tty[*]" 2>/dev/null)
	for MODE in model at; do
		for T in $TTYS; do
			[ "$MODE" = model ] && { /usr/share/5gmodem/atprobe.sh "$T" model || continue; } \
			                    || { /usr/share/5gmodem/atprobe.sh "$T" || continue; }
			echo "$T" > "$ATCACHE"
			# ПИННИМ порт в uci: переживает ребут, и следующий detect берёт
			# быстрый путь (at_port pinned) вместо перебора DIAG-портов через
			# atprobe (это и был весь холодный детект ~8 c). Пиннится один раз -
			# дальше сюда не доходим. Если модем переперечислится и tty исчезнет,
			# быстрый путь провалит [ -e ] и мы снова окажемся здесь.
			[ "$(uci -q get 5gmodem.@5gmodem[0].at_port)" = "$T" ] || {
				uci -q set 5gmodem.@5gmodem[0].at_port="$T"
				uci -q commit 5gmodem 2>/dev/null
			}
			echo "$T"
			exit 0
		done
	done
fi

# from temporary config
MODEMFILE=/tmp/modem
touch $MODEMFILE
DEVICE=$(cat $MODEMFILE)
if [ -n "$DEVICE" ]; then
	echo $DEVICE
	exit 0
fi

# find any device
DEVICES=$(find /dev -name "ttyUSB*" -o -name "ttyACM*" -o -name "wwan*at*" | sort -r)
# limit to devices from the modem
WAN=$(uci -q get network.wan.device)
if [ -e "$WAN" ]; then
	DEVPATH=$(getdevicepath "$WAN")
	DEVICESFOUND=""
	for DEVICE in $DEVICES; do
		T=$(getdevicepath $DEVICE)
		[ "x$T" = "x$DEVPATH" ] && DEVICESFOUND="$DEVICESFOUND $DEVICE"
	done
	DEVICES="$DEVICESFOUND"
fi

# Probe each candidate for an AT reply, time-bounded (~4s each). The old
# 'gcom check.gcom' has no timeout and blocked ~35s on a silent DIAG port, so
# auto-detection froze the page. atprobe.sh caps the wait AND rejects DIAG/NMEA
# ports (they never answer AT), so we land on a real AT port.
for DEVICE in $DEVICES; do
	if /usr/share/5gmodem/atprobe.sh "$DEVICE"; then
		echo "$DEVICE" | tee $MODEMFILE
		exit 0
	fi
done

echo ""
exit 0
