#!/bin/sh

#
# (c) 2010-2025 Cezary Jackiewicz <cezary@eko.one.pl>
#
# (c) 2021-2025 modified by Rafał Wabik - IceG - From eko.one.pl forum
#


band4g() {
# see https://en.wikipedia.org/wiki/LTE_frequency_bands
	echo -n "B${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"4") echo " (1700 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"11") echo " (1500 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"17") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"19") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"21") echo " (1500 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"31") echo " (450 MHz)";;
		"32") echo " (1500 MHz)";;
		"34") echo " (2000 MHz)";;
		"37") echo " (1900 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"42") echo " (3500 MHz)";;
		"43") echo " (3700 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700 MHz)";;
		"67") echo " (700 MHz)";;
		"69") echo " (2600 MHz)";;
		"70") echo " (1700 MHz)";;
		"71") echo " (600 MHz)";;
		"72") echo " (450 MHz)";;
		"73") echo " (450 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"85") echo " (700 MHz)";;
		"87") echo " (410 MHz)";;
		"88") echo " (410 MHz)";;
		"103") echo " (700 MHz)";;
		"106") echo " (900 MHz)";;
		"*") echo "";;
	esac
}

band5g() {
# see https://en.wikipedia.org/wiki/5G_NR_frequency_bands
	echo -n "n${1}"
	case "${1}" in
		"1") echo " (2100 MHz)";;
		"2") echo " (1900 MHz)";;
		"3") echo " (1800 MHz)";;
		"5") echo " (850 MHz)";;
		"7") echo " (2600 MHz)";;
		"8") echo " (900 MHz)";;
		"12") echo " (700 MHz)";;
		"13") echo " (700 MHz)";;
		"14") echo " (700 MHz)";;
		"18") echo " (850 MHz)";;
		"20") echo " (800 MHz)";;
		"24") echo " (1600 MHz)";;
		"25") echo " (1900 MHz)";;
		"26") echo " (850 MHz)";;
		"28") echo " (700 MHz)";;
		"29") echo " (700 MHz)";;
		"30") echo " (2300 MHz)";;
		"34") echo " (2100 MHz)";;
		"38") echo " (2600 MHz)";;
		"39") echo " (1900 MHz)";;
		"40") echo " (2300 MHz)";;
		"41") echo " (2500 MHz)";;
		"46") echo " (5200 MHz)";;
		"47") echo " (5900 MHz)";;
		"48") echo " (3500 MHz)";;
		"50") echo " (1500 MHz)";;
		"51") echo " (1500 MHz)";;
		"53") echo " (2400 MHz)";;
		"54") echo " (1600 MHz)";;
		"65") echo " (2100 MHz)";;
		"66") echo " (1700/2100 MHz)";;
		"67") echo " (700 MHz)";;
		"70") echo " (2000 MHz)";;
		"71") echo " (600 MHz)";;
		"74") echo " (1500 MHz)";;
		"75") echo " (1500 MHz)";;
		"76") echo " (1500 MHz)";;
		"77") echo " (3700 MHz)";;
		"78") echo " (3500 MHz)";;
		"79") echo " (4700 MHz)";;
		"80") echo " (1800 MHz)";;
		"81") echo " (900 MHz)";;
		"82") echo " (800 MHz)";;
		"83") echo " (700 MHz)";;
		"84") echo " (2100 MHz)";;
		"85") echo " (700 MHz)";;
		"86") echo " (1700 MHz)";;
		"89") echo " (850 MHz)";;
		"90") echo " (2500 MHz)";;
		"91") echo " (800/1500 MHz)";;
		"92") echo " (800/1500 MHz)";;
		"93") echo " (900/1500 MHz)";;
		"94") echo " (900/1500 MHz)";;
		"95") echo " (2100 MHz)";;
		"96") echo " (6000 MHz)";;
		"97") echo " (2300 MHz)";;
		"98") echo " (1900 MHz)";;
		"99") echo " (1600 MHz)";;
		"100") echo " (900 MHz)";;
		"101") echo " (1900 MHz)";;
		"102") echo " (6200 MHz)";;
		"104") echo " (6700 MHz)";;
		"105") echo " (600 MHz)";;
		"106") echo " (900 MHz)";;
		"109") echo " (700/1500 MHz)";;
		"257") echo " (28 GHz)";;
		"258") echo " (26 GHz)";;
		"259") echo " (41 GHz)";;
		"260") echo " (39 GHz)";;
		"261") echo " (28 GHz)";;
		"262") echo " (47 GHz)";;
		"263") echo " (60 GHz)";;
		"*") echo "";;
	esac
}

getdevicevendorproduct() {
	devname="$(basename $1)"
	case "$devname" in
		'wwan'*'at'*)
			devpath="$(readlink -f /sys/class/wwan/$devname/device)"
			T=${devpath%/*/*/*}
			if [ -e $T/vendor ] && [ -e $T/device ]; then
				V=$(cat $T/vendor)
				D=$(cat $T/device)
				echo "pci/${V/0x/}${D/0x/}"
			fi
			;;
		'ttyACM'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		'tty'*)
			devpath="$(readlink -f /sys/class/tty/$devname/device)"
			T=${devpath%/*/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
		*)
			devpath="$(readlink -f /sys/class/usbmisc/$devname/device)"
			T=${devpath%/*}
			echo "usb/$(cat $T/idVendor)$(cat $T/idProduct)"
			;;
	esac
}

RES="/usr/share/5gmodem"

DEVICE=$($RES/detect.sh)
# Bounded probe: sms_tool has no timeout and blocks ~35s on a silent/DIAG port,
# so a wrong pinned port froze this whole page on every metrics poll (only
# fixable by editing the config by hand). If the port does not answer AT within
# a few seconds, treat it as not found - every sms_tool call below then fails
# instantly instead of hanging.
[ -n "$DEVICE" ] && ! "$RES/atprobe.sh" "$DEVICE" && DEVICE=""
if [ -z "$DEVICE" ]; then
	echo '{"error":"Device not found"}'
	exit 0
fi

O=""
if [ -e /usr/bin/sms_tool ]; then
	# Один round-trip на всё «ядро»: PIN, сигнал, оператор (буквенный+числовой),
	# CREG/CEREG (с =2, чтобы CEREG отдал TAC), номер (CNUM) и IMSI (CIMI).
	# Раньше COPS?, CEREG и CIMI дёргались ещё и отдельными вызовами - каждый
	# лишний AT-сеанс добавлял ~0.5-1 c к загрузке страницы.
	O=$(sms_tool -D -d $DEVICE at "AT+CPIN?;+CSQ;+COPS=3,0;+COPS?;+COPS=3,2;+COPS?;+CREG=2;+CREG?;+CEREG=2;+CEREG?;+CNUM;+CIMI")
else
	O=$(gcom -d $DEVICE -s $RES/info.gcom 2>/dev/null)
fi

getpath() {
	devname="$(basename $1)"
	case "$devname" in
	'wwan'*'at'*)
		devpath="$(readlink -f /sys/class/wwan/$devname/device)"
		P=${devpath%/*/*/*}
		;;
	'ttyACM'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*}
		;;
	'tty'*)
		devpath="$(readlink -f /sys/class/tty/$devname/device)"
		P=${devpath%/*/*}
		;;
	*)
		devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
		P=${devpath%/*}
		;;
	esac
}

# --- modemdefine - WAN config ---
CONFIG=modemdefine
MODEMZ=$(uci show $CONFIG 2>/dev/null | grep -o "@modemdefine\[[0-9]*\]\.modem" | wc -l | xargs)
if [[ $MODEMZ -gt 1 ]]; then
	SEC=$(uci -q get modemdefine.@general[0].main_network)
fi
if [[ $MODEMZ -eq 0 ]]; then
	SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
fi
if [[ $MODEMZ -eq 1 ]]; then
	SEC=$(uci -q get modemdefine.@modemdefine[0].network)
fi

if [ -z "$SEC" ]; then
	getpath $DEVICE
	PORIG=$P
	for DEV in /sys/class/tty/* /sys/class/usbmisc/*; do
		getpath "/dev/"${DEV##/*/}
		if [ "x$PORIG" == "x$P" ]; then
			SEC=$(uci show network | grep "/dev/"${DEV##/*/} | cut -f2 -d.)
			[ -n "$SEC" ] && break
		fi
	done
fi

# ModemManager / wwan modems: the interface uses a control-channel proto
# (modemmanager/qmi/mbim/ncm) and is not bound to a /dev tty, so the
# path-matching above misses it. Pick that interface directly.
if [ -z "$SEC" ]; then
	for PROTO in modemmanager qmi mbim ncm wwan; do
		S=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.proto='$PROTO'\$/\1/p" | head -1)
		if [ -n "$S" ]; then
			SEC=$S
			break
		fi
	done
fi
# --- modemdefine config ---

CONN_TIME="-"
RX="-"
TX="-"

# Один вызов ifstatus на интерфейс (раньше его дёргали ~6 раз - каждый
# отдельный ubus-запрос ~0.5с = основной тормоз опроса). Парсим всё отсюда.
SECSTATUS=$(ifstatus "$SEC" 2>/dev/null)
NETUP=$(echo "$SECSTATUS" | grep "\"up\": true")
if [ -n "$NETUP" ]; then

		CT=$(uci -q -P /var/state/ get network.$SEC.connect_time)
		if [ -z $CT ]; then
			CT=$(echo "$SECSTATUS" | awk -F[:,] '/uptime/ {print $2}' | xargs)
		else
			UPTIME=$(cut -d. -f1 /proc/uptime)
			CT=$((UPTIME-CT))
		fi
		if [ ! -z $CT ]; then

			D=$(expr $CT / 60 / 60 / 24)
			H=$(expr $CT / 60 / 60 % 24)
			M=$(expr $CT / 60 % 60)
			S=$(expr $CT % 60)
			CONN_TIME=$(printf "%dd, %02d:%02d:%02d" $D $H $M $S)
			CONN_TIME_SINCE=$(date "+%Y%m%d%H%M%S" -d "@$(($(date +%s) - CT))")
			
		fi
		
		IFACE=$(echo "$SECSTATUS" | awk -F\" '/l3_device/ {print $4}')
		if [ -n "$IFACE" ]; then
			RX=$(ifconfig $IFACE | awk -F[\(\)] '/bytes/ {printf "%s",$2}')
			TX=$(ifconfig $IFACE | awk -F[\(\)] '/bytes/ {printf "%s",$4}')
		fi
fi

# CSQ
CSQ=$(echo "$O" | awk -F[,\ ] '/^\+CSQ/ {print $2}')

[ "x$CSQ" == "x" ] && CSQ=-1
if [ $CSQ -ge 0 -a $CSQ -le 31 ]; then
	CSQ_PER=$(($CSQ * 100/31))
else
	CSQ=""
	CSQ_PER=""
fi

# COPS numeric
# see https://mcc-mnc.com/
# Update: 11/11/2024 items: 3121
COPS=""
COPS_MCC=""
COPS_MNC=""
COPS_FROM_MODEM=0   # 1, если имя получено от самого модема, а не из mccmnc.dat
COPS_NUM=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,2/ {print $2}')
if [ -n "$COPS_NUM" ]; then
	COPS_MCC=${COPS_NUM:0:3}
	COPS_MNC=${COPS_NUM:3:3}
fi

TCOPS=$(echo "$O" | awk -F[\"] '/^\+COPS:\s*.,0/ {print $2}')
# Некоторые модемы (напр. Compal RXM-G1) отдают имя оператора в UCS2-hex,
# т.е. "beeline" приходит как 006200650065006C0069006E0065. Настоящее имя
# содержит нешестнадцатеричные буквы, поэтому строку из ОДНИХ hex длиной
# кратно 4 считаем UCS2: латиницу (00XX) декодируем, иначе (кириллица и т.п.)
# отбрасываем в пользу mccmnc.dat-имени.
if [ -n "$TCOPS" ] && [ $(( ${#TCOPS} % 4 )) -eq 0 ] && echo "$TCOPS" | grep -qE '^[0-9A-Fa-f]+$'; then
	# Каждые 4 hex = один codepoint UCS2. Декодируем в UTF-8 весь BMP,
	# включая кириллицу ("Т-Мобайл" = 0422002D041C...), а не только латиницу -
	# иначе кириллическое имя MVNO терялось и подменялось хост-сетью Tele2.
	DEC=""
	for h in $(echo "$TCOPS" | sed 's/\(....\)/\1 /g'); do
		c=$((0x$h))   # busybox ash не понимает 16#, используем 0x
		if [ "$c" -lt 128 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' "$c")")"
		elif [ "$c" -lt 2048 ]; then
			DEC="$DEC$(printf "\\$(printf '%03o' $((192 | (c >> 6))))\\$(printf '%03o' $((128 | (c & 63))))")"
		else
			DEC="$DEC$(printf "\\$(printf '%03o' $((224 | (c >> 12))))\\$(printf '%03o' $((128 | ((c >> 6) & 63))))\\$(printf '%03o' $((128 | (c & 63))))")"
		fi
	done
	[ -n "$DEC" ] && TCOPS="$DEC"
fi
[ "x$TCOPS" != "x" ] && { COPS="$TCOPS"; COPS_FROM_MODEM=1; }

if [ -z "$COPS" ]; then
	if [ -n "$COPS_NUM" ]; then
		COPS=$(awk -F[\;] '/^'$COPS_NUM';/ {print $3}' $RES/mccmnc.dat | xargs)
		LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
	fi
fi
[ -z "$COPS" ] && COPS=$COPS_NUM

# Телефонный номер (MSISDN) из AT+CNUM, если SIM его хранит.
# Формат: +CNUM: "<alpha>","<number>",<type>[,...]  (type 145 = международный).
# Берём поле в кавычках, которое похоже на номер (5+ цифр, возможен '+'); alpha в
# UCS2-hex содержит буквы (E/B/F...) и под шаблон не попадает.
PHONE=$(echo "$O" | awk -F'"' '/^\+CNUM:/{for(i=1;i<=NF;i++){if($i ~ /^[+]?[0-9][0-9][0-9][0-9][0-9]+$/){print $i; exit}}}')
if [ -n "$PHONE" ] && [ "${PHONE#+}" = "$PHONE" ]; then
	echo "$O" | grep '^+CNUM:' | grep -q ',145' && PHONE="+$PHONE"
fi

case "$COPS" in
    *\ *) 
        COPS=$(echo "$COPS" | awk '{if(NF==2 && tolower($1)==tolower($2)){print $1}else{print $0}}')
        ;;
esac

isp_num="$COPS_MCC $COPS_MNC"
isp_numws="$COPS_MCC$COPS_MNC"
# Числовой код оператора уже получен батчем (AT+COPS? формат 2 == COPS_MCC+MNC),
# отдельный round-trip к модему не нужен. Используем как ключ mccmnc.dat.
isp="$isp_numws"

case "$COPS" in
    *[!0-9]* | '')
	# Non-numeric characters or is blank
        ;;
    *) 
        if [ "$COPS" = "$isp_num" ] || [ "$COPS" = "$isp_numws" ]; then
            if [ -n "$isp" ]; then
                COPS=$(awk -F[\;] '/^'"$isp"';/ {print $3}' $RES/mccmnc.dat | xargs)
                LOC=$(awk -F[\;] '/^'"$isp"';/ {print $2}' $RES/mccmnc.dat)
            fi
        fi
	;;
esac

# Финальная нормализация имени оператора.
# Раньше проверяли отсутствие латиницы (grep '[A-Za-z]') - но кириллическое
# имя (Т-Мобайл) латиницы не содержит и ошибочно считалось мусором, после чего
# подменялось хост-сетью из mccmnc.dat (Tele2). Теперь мусором считаем имя ТОЛЬКО
# из цифр/пробелов (напр. "0062003 0062003").
#
# Модем-MVNO то отдаёт свой бренд ("Т-Мобайл"), то мусор; mccmnc.dat знает лишь
# хост-сеть (Tele2). Поэтому хорошее буквенное имя запоминаем для этого кода
# оператора, а при мусоре берём последнее запомненное имя, и лишь если его нет -
# имя из mccmnc.dat.
# Идентификатор SIM (IMSI) - ключ кэшей оператора/SPN. Без него при горячей
# замене SIM показывался бы закэшированный старый оператор (поставили Билайн, а
# светится Т-Мобайл). При смене SIM IMSI меняется -> кэш инвалидируется.
# IMSI уже в батче (+CIMI отдаёт его отдельной строкой из одних цифр).
SIMID=$(echo "$O" | tr -d '\r' | grep -xE '[0-9]{14,16}' | head -1)

OPCACHE="/tmp/5gmodem_operator"
if [ -n "$COPS" ] && echo "$COPS" | grep -qE '^[0-9 ]+$'; then
	CACHED=""
	if [ -n "$SIMID" ] && [ -f "$OPCACHE" ] && [ "$(cut -f1 "$OPCACHE")" = "$SIMID" ]; then
		CACHED=$(cut -f2- "$OPCACHE")
	fi
	if [ -n "$CACHED" ]; then
		COPS="$CACHED"
	elif [ -n "$COPS_NUM" ]; then
		NAME=$(awk -F[\;] '/^'"$COPS_NUM"';/ {print $3}' "$RES/mccmnc.dat" | xargs)
		[ -n "$NAME" ] && COPS="$NAME"
	fi
elif [ "$COPS_FROM_MODEM" = "1" ] && [ -n "$SIMID" ] && [ -n "$COPS" ]; then
	# запоминаем только имя, полученное от самого модема (не из mccmnc.dat),
	# иначе кэш затёрся бы хост-сетью Tele2 при первом же мусорном чтении
	printf '%s\t%s\n' "$SIMID" "$COPS" > "$OPCACHE"
fi

# Имя оператора с SIM (EF_SPN, файл 6F46) - самое надёжное брендовое имя
# абонента. Для MVNO (Т-Мобайл / T-Mobile на сети Tele2) модем часто отдаёт
# мусор ("T0"), а числовой код 25020 указывает лишь на хост-сеть Tele2, тогда
# как на SIM записано настоящее "T-Mobile". Кэшируем по IMSI (не читаем CRSM
# каждый раз, но при замене SIM перечитываем); если модем не умеет CRSM или
# IMSI не прочитался - тихо пропускаем.
SPNCACHE="/tmp/5gmodem_spn"
SPN=""
if [ -n "$SIMID" ] && [ -f "$SPNCACHE" ] && [ "$(cut -f1 "$SPNCACHE")" = "$SIMID" ]; then
	SPN=$(cut -f2- "$SPNCACHE")
else
	# Ответ CRSM у разных модемов: с кавычками ("...") у Compal, БЕЗ кавычек у
	# Telit LM960 (+CRSM: 144,0,00542D...). Убираем кавычки и берём hex после
	# двух статус-байтов (sw1,sw2,), чтобы работало в обоих форматах.
	SPNHEX=$(sms_tool -d "$DEVICE" at "AT+CRSM=176,28486,0,0,17" 2>/dev/null | tr -d '\r"' \
		| sed -n 's/.*+CRSM:[^,]*,[^,]*,\([0-9A-Fa-f][0-9A-Fa-f]*\).*/\1/p')
	if [ -n "$SPNHEX" ]; then
		# первый байт - условие отображения, пропускаем; далее имя (GSM7/ASCII)
		# до заполнителя FF. Печатаемые ASCII декодируем, старшие байты UCS2 (00)
		# и служебные - пропускаем.
		SPN=$(echo "$SPNHEX" | sed 's/^..//' | sed 's/\(..\)/\1 /g' | tr ' ' '\n' | while read b; do
			[ -z "$b" ] && continue
			{ [ "$b" = "FF" ] || [ "$b" = "ff" ]; } && break
			v=$((0x$b))   # busybox ash не понимает 16#, используем 0x
			[ "$v" -ge 32 ] && [ "$v" -lt 127 ] && printf "\\$(printf '%03o' "$v")"
		done)
		[ -n "$SPN" ] && [ -n "$SIMID" ] && printf '%s\t%s\n' "$SIMID" "$SPN" > "$SPNCACHE"
	fi
fi
# Определяем брендовое имя из SPN (если осмысленное). НЕ присваиваем COPS
# здесь: модем-специфичные скрипты (напр. Telit 1bc71040) ниже перезаписывают
# COPS именем сети из своих AT-команд. Поэтому применяем SPN В САМОМ КОНЦЕ,
# после источения профиля модема (см. блок перед выводом JSON).
SPN_NAME=""
if [ -n "$SPN" ] && ! echo "$SPN" | grep -qE '^[0-9 ]*$'; then
	# Если SPN совпадает (без учёта регистра) с именем сети из mccmnc.dat -
	# это обычный оператор: берём аккуратно оформленное имя из базы
	# ("beeline" -> "Beeline"). Если отличается - это MVNO, оставляем SPN
	# ("T-Mobile" вместо хост-сети "Tele2").
	MCCNAME=""
	[ -n "$COPS_NUM" ] && MCCNAME=$(awk -F[\;] '/^'"$COPS_NUM"';/ {print $3}' "$RES/mccmnc.dat" | xargs)
	if [ -n "$MCCNAME" ] && [ "$(echo "$SPN" | tr 'A-Z' 'a-z')" = "$(echo "$MCCNAME" | tr 'A-Z' 'a-z')" ]; then
		SPN_NAME="$MCCNAME"
	else
		SPN_NAME="$SPN"
	fi
fi


# operator location from temporary config
LOCATIONFILE=/tmp/location
if [ -e "$LOCATIONFILE" ]; then
	touch $LOCATIONFILE
	LOC=$(cat $LOCATIONFILE)
	if [ -n "$LOC" ]; then
		LOC=$(cat $LOCATIONFILE)
			if [[ $LOC == "-" ]]; then
				rm $LOCATIONFILE
				LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
				if [ -n "$LOC" ]; then
					echo "$LOC" > /tmp/location
				fi
			else
				LOC=$(awk -F[\;] '/^'$COPS_NUM';/ {print $2}' $RES/mccmnc.dat)
				if [ -n "$LOC" ]; then
					echo "$LOC" > /tmp/location
				fi
			fi
	fi
else
	case "$COPS_MCC$COPS_MNC" in
    		*[!0-9]* | '')
        	# Non-numeric characters or is blank
        	;;
    		*) 
        		if [ -n "$LOC" ]; then
            			LOC=$(awk -F[\;] '/^'"$COPS_MCC$COPS_MNC"';/ {print $2}' $RES/mccmnc.dat)
            			echo "$LOC" > /tmp/location
        		else
            			echo "-" > /tmp/location
        		fi
        	;;
	esac
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CPIN:/ {print $0;exit}' | xargs)
if [ -n "$T" ]; then
	[ "$T" == "+CPIN: READY" ] || REG=$(echo "$T" | cut -f2 -d: | xargs)
fi

T=$(echo "$O" | awk -F[,\ ] '/^\+CME ERROR:/ {print $0;exit}')
if [ -n "$T" ]; then
	case "$T" in
		"+CME ERROR: 10"*) REG="SIM not inserted";;
		"+CME ERROR: 11"*) REG="SIM PIN required";;
		"+CME ERROR: 12"*) REG="SIM PUK required";;
		"+CME ERROR: 13"*) REG="SIM failure";;
		"+CME ERROR: 14"*) REG="SIM busy";;
		"+CME ERROR: 15"*) REG="SIM wrong";;
		"+CME ERROR: 17"*) REG="SIM PIN2 required";;
		"+CME ERROR: 18"*) REG="SIM PUK2 required";;
		*) REG=$(echo "$T" | cut -f2 -d: | xargs);;
	esac
fi

# CREG
eval $(echo "$O" | busybox awk -F[,] '/^\+CREG/ {gsub(/[[:space:]"]+/,"");printf "T=\"%d\";LAC_HEX=\"%X\";CID_HEX=\"%X\";LAC_DEC=\"%d\";CID_DEC=\"%d\";MODE_NUM=\"%d\"", $2, "0x"$3, "0x"$4, "0x"$3, "0x"$4, $5}')
case "$T" in
	0*) REG="0";;
	1*) REG="1";;
	2*) REG="2";;
	3*) REG="3";;
	5*) REG="5";;
	6*) REG="6";;
	7*) REG="7";;
	*) REG="";;
esac

# EPS/data registration (CEREG) overrides a "SMS only" CS status. Many LTE data
# modems (e.g. Fibocom FM350-GL) register the CS/voice domain as "SMS only"
# (CREG 6/7) on every operator while the PS/data domain is fully registered and
# the connection works fine - showing "registered, SMS only" then just confuses
# the user. So when CS says SMS-only but CEREG says registered (1=home, 5=roam),
# report the data status instead.
if [ "$REG" = "6" ] || [ "$REG" = "7" ]; then
	CEREG_STAT=$(echo "$O" | busybox awk -F[,] '/^\+CEREG/{gsub(/[[:space:]"]+/,"");print $2;exit}')
	case "$CEREG_STAT" in
		1) REG="1";;
		5) REG="5";;
	esac
fi

# MODE
if [ -z "$MODE_NUM" ] || [ "x$MODE_NUM" == "x0" ]; then
#	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS/ {print $4;exit}' | xargs)
	MODE_NUM=$(echo "$O" | awk -F[,] '/^\+COPS: 0,2/ {print $4;exit}' | xargs)
fi
case "$MODE_NUM" in
	2*) MODE="UMTS";;
	3*) MODE="EDGE";;
	4*) MODE="HSDPA";;
	5*) MODE="HSUPA";;
	6*) MODE="HSPA";;
	7*) MODE="LTE";;
	 *) MODE="-";;
esac

# TAC - из CEREG, уже полученного батчем (там включён CEREG=2, поэтому поле TAC
# присутствует). Отдельный вызов at+cereg убран; к тому же прежний без CEREG=2
# возвращал "+CEREG: 0,1" без TAC, т.е. tac_hex всегда был пустым.
TAC=$(echo "$O" | awk -F[,] '/^\+CEREG/ {printf "%s", toupper($3)}' | sed 's/[^A-F0-9]//g')
if [ "x$TAC" != "x" ]; then
	TAC_HEX=$(printf %d 0x$TAC)
else
	TAC="-"
	TAC_HEX="-"
fi

CONF_DEVICE=$(uci -q get 5gmodem.@5gmodem[0].device)
if echo "x$CONF_DEVICE" | grep -q "192.168."; then
	if grep -q "Vendor=1bbb" /sys/kernel/debug/usb/devices; then
		. $RES/modem/hilink/alcatel_hilink.sh $DEVICE
	fi
	if grep -q "Vendor=12d1" /sys/kernel/debug/usb/devices; then
		. $RES/modem/hilink/huawei_hilink.sh $DEVICE
	fi
	if grep -q "Vendor=19d2" /sys/kernel/debug/usb/devices; then
		. $RES/modem/hilink/zte.sh $DEVICE
	fi
	SEC=$(uci -q get 5gmodem.@5gmodem[0].network)
	SEC=${SEC:-wan}
else

# --- Модульный опрос + кэш статичных полей ---------------------------------
# $2 = список нужных секций (core,signal,ca). Пусто/"all" = все (обратная
# совместимость). Профили читают WANT_SIGNAL/WANT_CA, чтобы не дёргать AT/QMI
# для свёрнутых блоков страницы.
SECTIONS="${2:-all}"
WANT_SIGNAL=1; WANT_CA=1
case "$SECTIONS" in
	all|"") ;;
	*)
		case ",$SECTIONS," in *,signal,*) WANT_SIGNAL=1;; *) WANT_SIGNAL=0;; esac
		case ",$SECTIONS," in *,ca,*)     WANT_CA=1;;     *) WANT_CA=0;;     esac
		;;
esac

# Кэш статичных полей (модель/IMEI/прошивка/ICCID) - они не меняются, но
# опрашивались КАЖДЫЙ опрос (5 из 6 AT-вызовов = основные ~секунды). Ключ - USB-
# путь модема; при смене SIM (IMSI из батча != сохранённого) кэш сбрасывается.
_STKEY=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null | tr -c 'A-Za-z0-9' '_')
[ -n "$_STKEY" ] || _STKEY="$(basename "$DEVICE" 2>/dev/null)"
STATIC_CACHE="/tmp/5gmodem_static_$_STKEY"
if [ -n "$SIMID" ] && [ "$(cat "${STATIC_CACHE}.imsi" 2>/dev/null)" != "$SIMID" ]; then
	rm -f "${STATIC_CACHE}"_* 2>/dev/null
	printf '%s' "$SIMID" > "${STATIC_CACHE}.imsi"
fi
# at_static <key> <atcmd> : сырой ответ из кэша, иначе запрос + кэш.
at_static() {
	_cf="${STATIC_CACHE}_$1"
	[ -s "$_cf" ] && { cat "$_cf"; return; }
	sms_tool -d "$DEVICE" at "$2" 2>/dev/null | tee "$_cf"
}

if [ -e /usr/bin/sms_tool ]; then
	REGOK=0
	[ "x$REG" == "x1" ] || [ "x$REG" == "x5" ] || [ "x$REG" == "x6" ] || [ "x$REG" == "x7" ] && REGOK=1
	VIDPID=$(getdevicevendorproduct $DEVICE)
	if [ -e "$RES/modem/$VIDPID" ]; then
		case $(cat /tmp/sysinfo/board_name) in
			"zte,mf289f")
				. "$RES/modem/usb/19d21485"
				;;
			*)
				. "$RES/modem/$VIDPID"
				;;
		esac
	fi
fi

fi

sanitize_string() {
[ -z "$1" ] && echo "-" || echo "$1" | tr -d '\r\n'
}
sanitize_number() {
[ -z "$1" ] && echo "-" || echo "$1"
}

# IP addresses of the modem network interface (for the main page).
# umbim/MBIM puts the address on a virtual <iface>_4 / <iface>_6 child, not on
# the parent, so read straight from the l3 device - works for umbim,
# modemmanager, qmi and plain static alike. ubus children are a fallback.
# IP-блок читает СВЕЖИЙ статус интерфейса (SECSTATUS считается раньше, до
# финализации SEC для некоторых конфигов, и мог быть для другого/пустого SEC).
IFSTAT=$(ifstatus "$SEC" 2>/dev/null)
L3DEV=$(echo "$IFSTAT" | awk -F\" '/l3_device/ {print $4; exit}')
IPADDR=""
IPADDR6=""
if [ -n "$L3DEV" ]; then
	IPADDR=$(ip -4 addr show dev "$L3DEV" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -v '^127\.' | head -1)
	IPADDR6=$(ip -6 addr show dev "$L3DEV" scope global 2>/dev/null | awk '/inet6 /{print $2}' | cut -d/ -f1 | head -1)
fi
[ -z "$IPADDR" ]  && IPADDR=$(echo "$IFSTAT" | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR" ]  && IPADDR=$(ifstatus "${SEC}_4" 2>/dev/null | grep -A4 '"ipv4-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(echo "$IFSTAT" | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)
[ -z "$IPADDR6" ] && IPADDR6=$(ifstatus "${SEC}_6" 2>/dev/null | grep -A4 '"ipv6-address"' | sed -n 's/.*"address": *"\([^"]*\)".*/\1/p' | head -1)

# Реальный протокол интерфейса модема (modemmanager/mbim/qmi/ncm/...). Раньше
# в JSON шла случайная переменная цикла $PROTO, из-за чего при modemmanager
# показывался mbim. Берём напрямую из uci выбранного интерфейса $SEC.
IFPROTO=$(uci -q get "network.$SEC.proto")
[ -n "$IFPROTO" ] && PROTO="$IFPROTO"

# Брендовое имя оператора с SIM (SPN) применяем В КОНЦЕ - после модем-скриптов,
# которые могли перезаписать COPS именем хост-сети (напр. Telit ставит "Tele2
# RU", тогда как на SIM записан бренд MVNO "T-Mobile").
[ -n "$SPN_NAME" ] && COPS="$SPN_NAME"

# MSISDN (номер телефона) - универсальный фолбэк для ВСЕХ модемов. AT+CNUM выше
# отдаёт номер на AT-модемах; если он пуст, а модем управляется ModemManager
# (напр. Compal, который на AT+CNUM молчит), берём номер из mmcli own-numbers.
# Так номер читается везде, где SIM его хранит, независимо от типа модема.
if [ -z "$PHONE" ] && command -v mmcli >/dev/null 2>&1; then
	_MI=$(/usr/share/5gmodem/modemswitch.sh mmindex 2>/dev/null)
	if [ -n "$_MI" ]; then
		PHONE=$(mmcli -m "$_MI" -K 2>/dev/null \
			| sed -n 's/^modem\.generic\.own-numbers[^:]*:[[:space:]]*//p' \
			| tr -d ' ' | grep -E '^[+]?[0-9]{5,}$' | head -1)
	fi
fi

# Разрешённое имя оператора кладём в кэш, читаемый переключателем приоритета
# (netpri.sh): у MBIM/QMI-модемов оператор часто доступен только здесь (числовой
# COPS + mccmnc.dat / UCS2), а не через отдельный AT+COPS у netpri.
if [ -n "$SEC" ] && [ -n "$COPS" ] && ! echo "$COPS" | grep -qE '^[0-9 ]*$'; then
	printf '%s' "$COPS" > "/tmp/5gmodem_op_$SEC" 2>/dev/null
fi

cat <<EOF
{
"ipaddr":"$(sanitize_string "$IPADDR")",
"ipaddr6":"$(sanitize_string "$IPADDR6")",
"iface":"$(sanitize_string "$SEC")",
"conn_time":"$(sanitize_string "$CONN_TIME")",
"conn_time_sec":"$(sanitize_number "$CT")",
"conn_time_since":"$(sanitize_string "$CONN_TIME_SINCE")",
"rx":"$(sanitize_number "$RX")",
"tx":"$(sanitize_number "$TX")",
"modem":"$(sanitize_string "$MODEL")",
"mtemp":"$(sanitize_string "$TEMP")",
"firmware":"$(sanitize_string "$FW")",
"cport":"$(sanitize_string "$DEVICE")",
"protocol":"$(sanitize_string "$PROTO")",
"csq":"$(sanitize_number "$CSQ")",
"signal":"$(sanitize_number "$CSQ_PER")",
"operator_name":"$(sanitize_string "$COPS")",
"phone":"$(sanitize_string "$PHONE")",
"operator_mcc":"$(sanitize_string "$COPS_MCC")",
"operator_mnc":"$(sanitize_string "$COPS_MNC")",
"location":"$(sanitize_string "$LOC")",
"mode":"$(sanitize_string "$MODE")",
"registration":"$(sanitize_string "$REG")",
"simslot":"$(sanitize_string "$SSIM")",
"imei":"$(sanitize_string "$NR_IMEI")",
"imsi":"$(sanitize_string "$NR_IMSI")",
"iccid":"$(sanitize_string "$NR_ICCID")",
"lac_dec":"$(sanitize_number "$LAC_DEC")",
"lac_hex":"$(sanitize_string "$LAC_HEX")",
"tac_dec":"$(sanitize_number "$TAC_DEC")",
"tac_hex":"$(sanitize_string "$TAC_HEX")",
"tac_h":"$(sanitize_string "$T_HEX")",
"tac_d":"$(sanitize_number "$T_DEC")",
"cid_dec":"$(sanitize_number "$CID_DEC")",
"cid_hex":"$(sanitize_string "$CID_HEX")",
"pci":"$(sanitize_number "$PCI")",
"earfcn":"$(sanitize_number "$EARFCN")",
"pband":"$(sanitize_string "$PBAND")",
"s1band":"$(sanitize_string "$S1BAND")",
"s1pci":"$(sanitize_number "$S1PCI")",
"s1earfcn":"$(sanitize_number "$S1EARFCN")",
"s2band":"$(sanitize_string "$S2BAND")",
"s2pci":"$(sanitize_number "$S2PCI")",
"s2earfcn":"$(sanitize_number "$S2EARFCN")",
"s3band":"$(sanitize_string "$S3BAND")",
"s3pci":"$(sanitize_number "$S3PCI")",
"s3earfcn":"$(sanitize_number "$S3EARFCN")",
"s4band":"$(sanitize_string "$S4BAND")",
"s4pci":"$(sanitize_number "$S4PCI")",
"s4earfcn":"$(sanitize_number "$S4EARFCN")",
"s1rsrp":"$(sanitize_number "$S1RSRP")",
"s2rsrp":"$(sanitize_number "$S2RSRP")",
"s3rsrp":"$(sanitize_number "$S3RSRP")",
"s4rsrp":"$(sanitize_number "$S4RSRP")",
"pmimo":"$(sanitize_string "$PMIMO")",
"pmod":"$(sanitize_string "$PMOD")",
"s1mimo":"$(sanitize_string "$S1MIMO")",
"s1mod":"$(sanitize_string "$S1MOD")",
"s2mimo":"$(sanitize_string "$S2MIMO")",
"s2mod":"$(sanitize_string "$S2MOD")",
"s3mimo":"$(sanitize_string "$S3MIMO")",
"s3mod":"$(sanitize_string "$S3MOD")",
"s4mimo":"$(sanitize_string "$S4MIMO")",
"s4mod":"$(sanitize_string "$S4MOD")",
"rsrp":"$(sanitize_number "$RSRP")",
"rsrq":"$(sanitize_number "$RSRQ")",
"rssi":"$(sanitize_number "$RSSI")",
"sinr":"$(sanitize_number "$SINR")"
}
EOF
exit 0

