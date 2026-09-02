#!/bin/sh
#
# УСТРОЙСТВА, КОТОРЫЕ МОДЕМАМИ НЕ ЯВЛЯЮТСЯ (по vid:pid).
#
# Модем в этой программе опознаётся по портам: всё, что отдаёт ttyUSB/ttyACM/
# cdc-wdm, попадает в список модемов и получает свою вкладку (см. listmodems.sh).
# Правило работает, пока в USB воткнут только модем, - но ttyUSB делает и любой
# переходник USB-UART, а их в роутер втыкают: консоль другой железки, счётчик,
# контроллер. Такой переходник показывался ОТДЕЛЬНЫМ модемом - с вкладкой, с
# попытками опроса по AT и с местом в приоритете интернета (живой случай
# 01.09.2026: WCH CH340 1a86:7523).
#
# Отсюда список известных мостов USB-UART. Это чистые преобразователи: сотовым
# модемом такое устройство быть не может физически, никакого QMI/MBIM/HiLink у
# него нет, а единственный «модем», который к нему подключают, - чужая железка
# на другом конце провода, и говорить с ней должна не наша программа.
#
#   1a86:7522 1a86:7523 CH340/CH341, 1a86:55d3 CH9102/CH343 - WCH (QinHeng)
#   0403:6001 0403:6010 0403:6011 0403:6014 0403:6015       - FTDI FT232/FT2232/FT-X
#   10c4:ea60 10c4:ea70 10c4:ea71                           - Silicon Labs CP210x
#   067b:2303 067b:23a3 067b:23c3                           - Prolific PL2303
#
# ДВЕ РУЧКИ В КОНФИГЕ, обе - списки vid:pid через пробел:
#   5gmodem.@5gmodem[0].ignore_vidpid - добавить своё устройство в исключения;
#   5gmodem.@5gmodem[0].modem_vidpid  - НАОБОРОТ, вернуть устройство из списка
#     выше в модемы. Нужна для отладочной платы, где сотовый модуль подключён к
#     роутеру именно через такой мост и других портов у него нет: список выше
#     тогда прячет настоящий модем.
NOT_MODEM_VIDPIDS="1a86:7522 1a86:7523 1a86:55d3 0403:6001 0403:6010 0403:6011 0403:6014 0403:6015 10c4:ea60 10c4:ea70 10c4:ea71 067b:2303 067b:23a3 067b:23c3"

# Обе ручки читаем ОДИН раз на процесс: is_not_modem зовётся на каждое USB-
# устройство, а listmodems.sh за одну загрузку страницы запускается шесть раз -
# лишний uci здесь стоит дороже самой проверки.
_NM_CFG=""
_nm_cfg() {
	[ -n "$_NM_CFG" ] && return 0
	_NM_CFG=1
	NOT_MODEM_EXTRA=$(uci -q get 5gmodem.@5gmodem[0].ignore_vidpid 2>/dev/null)
	NOT_MODEM_FORCE=$(uci -q get 5gmodem.@5gmodem[0].modem_vidpid 2>/dev/null)
}

# Usage: is_not_modem <vid:pid>   ->  0 = это не модем, прятать
is_not_modem() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	_nm_cfg
	for _nm in $NOT_MODEM_FORCE; do
		[ "$1" = "$_nm" ] && return 1
	done
	for _nm in $NOT_MODEM_VIDPIDS $NOT_MODEM_EXTRA; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

# ТОЛЬКО встроенный список, без обеих ручек. Нужна странице настроек: по ней она
# понимает, куда писать галочку - в ignore_vidpid (скрыть то, что мы считаем
# модемом) или в modem_vidpid (вернуть то, что прячем сами).
is_not_modem_builtin() {
	case "$1" in *:*) ;; *) return 1 ;; esac
	for _nm in $NOT_MODEM_VIDPIDS; do
		[ "$1" = "$_nm" ] && return 0
	done
	return 1
}

# ===== ЧТО ВООБЩЕ СЧИТАТЬ МОДЕМОМ =====
#
# Чёрный список выше лечил симптом: воткнули переходник - добавили его vid:pid.
# Но правило, по которому программа искала модемы, звучало как «есть ttyUSB или
# cdc-wdm - значит модем», и под него попадает что угодно: счётчик, контроллер,
# плата с USB-UART, принтер, отладочный адаптер. Каждое такое устройство
# получало вкладку, секцию в конфиге, место в приоритете интернета и попытки
# опроса AT-командами. Перечислить всё, что бывает воткнуто в роутер, нельзя -
# значит решать должен не список, а признаки самого устройства.
#
# ПРИЗНАКИ. Всё, что нужно, ядро уже выяснило, когда привязывало драйверы к
# интерфейсам устройства, - надо лишь прочитать это в sysfs:
#
#   1. ДРАЙВЕР интерфейса. У сотового модема это option/qcserial/sierra/
#      usb_wwan (порты) и qmi_wwan/cdc_mbim/cdc_ncm/cdc_ether/rndis_host (канал
#      данных). У переходника - ch341/ftdi_sio/cp210x/pl2303, и он не бывает ни
#      тем, ни другим: разные драйверы, разные классы, разное железо.
#   2. КЛАСС интерфейса: MBIM (02:0e), CDC ECM (02:06), NCM (02:0d). Это всегда
#      сетевой канал, и у переходника с принтером его нет.
#   3. ВЕНДОР. Список сотовых вендоров короткий и меняется раз в годы, а модем в
#      «сыром» виде (драйвер ещё не привязан, портов нет) узнаётся только по нему.
#   4. НАША СЕКЦИЯ В КОНФИГЕ с IMEI или моделью: устройство уже отвечало нам как
#      модем, что бы ни думали пункты выше. Это страховка от главного риска
#      такой проверки - спрятать чей-то работающий модем незнакомой модели.
#
# Не подошло ни одно - не модем. Ошиблись - человек ставит галочку в Настройках
# («Что считать модемом»), vid:pid уезжает в modem_vidpid, и устройство
# возвращается: ручной ответ всегда сильнее любой эвристики.
MODEM_DRIVERS="option qcserial sierra sierra_net usb_wwan qmi_wwan cdc_mbim cdc_ncm cdc_wdm huawei_cdc_ncm cdc_ether rndis_host cdc_subset qcaux GobiNet GobiSerial simcom_wwan"

# Вендоры сотовых модулей и свистков. 05c6 (Qualcomm) и 0e8d (MediaTek) - самые
# широкие: под ними ходит и референсная периферия, но в роутер её втыкают редко,
# а модемов на этих идентификаторах - половина всего, что мы поддерживаем.
#
# ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ. Dell (413c), HP (03f0), Intel (8087), Foxconn (0489),
# TP-Link (2357) выпускают модемы, но под теми же вендорами ходят клавиатуры,
# принтеры, Bluetooth-контроллеры и Wi-Fi свистки - по вендору их не отличить.
# Их модемы попадают сюда другим путём: у DW5821e и L850 интерфейс MBIM, у
# HP lt4120 - qmi_wwan, и признаки 1-2 узнают их и без списка.
CELL_VENDORS="12d1 19d2 2c7c 1e0e 1bc7 0e8d 2cb7 1e2d 2dee 05c6 1199 2020 1c9e 0af0 1bbb 2001 0421 1546 1782 1410 16d8 106c"

# ПРИЧИНА РЕШЕНИЯ - КОДОМ, А НЕ ФРАЗОЙ. Строку показывает страница настроек, а
# она бывает на трёх языках: перевести пришедшее из скрипта нельзя, поэтому
# отсюда уходит короткий код (vendor/driver/mbim/bridge/...) и, если есть,
# уточнение - имя драйвера или вендора. Фразу собирает страница.
IM_WHY=""
IM_DETAIL=""

# Usage: usb_is_modem <каталог usb-устройства в sysfs>  ->  0 = это модем
usb_is_modem() {
	_im_n="$1"
	IM_WHY=""; IM_DETAIL=""
	[ -n "$_im_n" ] && [ -f "$_im_n/idVendor" ] || { IM_WHY=none; IM_DETAIL=""; return 1; }
	_im_v=$(cat "$_im_n/idVendor" 2>/dev/null)
	_im_p=$(cat "$_im_n/idProduct" 2>/dev/null)
	_nm_cfg

	# РУЧНОЙ ОТВЕТ ВЫШЕ ВСЕГО ОСТАЛЬНОГО - в обе стороны.
	for _im_x in $NOT_MODEM_FORCE; do
		[ "$_im_v:$_im_p" = "$_im_x" ] && { IM_WHY=forced; IM_DETAIL=""; return 0; }
	done
	if is_not_modem "$_im_v:$_im_p"; then
		IM_DETAIL=""
		is_not_modem_builtin "$_im_v:$_im_p" && IM_WHY=bridge || IM_WHY=ignored
		return 1
	fi

	case " $CELL_VENDORS " in
		*" $_im_v "*) IM_WHY=vendor; IM_DETAIL="$_im_v"; return 0 ;;
	esac

	for _im_i in "$_im_n":*; do
		[ -d "$_im_i" ] || continue
		_im_d=$(readlink "$_im_i/driver" 2>/dev/null); _im_d=${_im_d##*/}
		case " $MODEM_DRIVERS " in
			*" $_im_d "*) IM_WHY=driver; IM_DETAIL="$_im_d"; return 0 ;;
		esac
		case "$(cat "$_im_i/bInterfaceClass" 2>/dev/null):$(cat "$_im_i/bInterfaceSubClass" 2>/dev/null)" in
			02:0e) IM_WHY=mbim; IM_DETAIL=""; return 0 ;;
			02:06) IM_WHY=ecm; IM_DETAIL=""; return 0 ;;
			02:0d) IM_WHY=ncm; IM_DETAIL=""; return 0 ;;
		esac
	done

	# ПОСЛЕДНЯЯ СТРАХОВКА: у нас уже есть профиль этого устройства с IMEI или
	# моделью - значит когда-то оно отвечало нам как модем. Признаки выше могли
	# не сработать (модем незнакомого вендора, порты которому подсунули руками
	# через new_id), а спрятать чей-то работающий модем - худшее, что эта
	# проверка может сделать. Стоит в конце, чтобы причина в настройках
	# называла настоящий признак, когда он есть.
	_im_s="m_$(basename "$_im_n" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ -n "$(uci -q get "5gmodem.$_im_s.imei" 2>/dev/null)$(uci -q get "5gmodem.$_im_s.model" 2>/dev/null)" ]; then
		IM_WHY=profile; IM_DETAIL=""
		return 0
	fi

	IM_WHY=none; IM_DETAIL=""
	return 1
}

# То же по vid:pid, когда каталога устройства под рукой нет: ищем его на шине.
usb_is_modem_vidpid() {   # $1 - vid:pid
	case "$1" in *:*) ;; *) return 1 ;; esac
	for _iv_n in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
		case "$_iv_n" in *:*) continue ;; esac
		[ -f "$_iv_n/idVendor" ] || continue
		[ "$(cat "$_iv_n/idVendor" 2>/dev/null):$(cat "$_iv_n/idProduct" 2>/dev/null)" = "$1" ] || continue
		usb_is_modem "$_iv_n"
		return $?
	done
	IM_WHY=absent; IM_DETAIL=""
	return 1
}

# --- notmodem.sh scan --------------------------------------------------------
#
# Список устройств для страницы настроек: что сейчас на шине, чем мы это считаем
# и почему. Отдельная команда, а не режим listmodems.sh: тот скрипт горячий (шесть
# запусков на загрузку страницы, кэш, ветки HiLink), и мешать в него редкий вызов
# из настроек - платить за него постоянно.
#
# Показываем устройства С ПОРТАМИ (tty/cdc-wdm) - именно они получают вкладку, -
# плюс всё, что listmodems.sh уже считает модемом (модем без портов, HiLink: его
# тоже может понадобиться скрыть). Хабы, флешки и прочая USB-мелочь сюда не
# попадают: список настроек должен оставаться коротким и осмысленным.
#
# Вывод: JSON-массив
#   [ { "path","vidpid","product","ports":[...],
#       "skip":"1"     - не показываем сейчас (с учётом обеих ручек),
#       "builtin":"1"  - в списке переходников USB-UART,
#       "auto":"1"     - считалось бы модемом само по себе, без ручек,
#       "why":"vendor|driver|mbim|ecm|ncm|profile|forced|bridge|ignored|none|absent"
#       "detail":"..."  - уточнение к причине: имя драйвера или вендор,
#       "absent":"1" } - устройства на шине нет, запись из конфига ]
nm_scan() {
	_ns_esc() {
		case "$1" in
			*\\*|*\"*) echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
			*) echo "$1" ;;
		esac
	}
	_ns_out=""
	_ns_seen=""
	# КЕМ УСТРОЙСТВО СЧИТАЛОСЬ БЫ БЕЗ РУЧЕК. Страница по этому полю решает, куда
	# писать галочку: чтобы ПОКАЗАТЬ то, что само по себе модемом не считается,
	# нужен modem_vidpid; чтобы СПРЯТАТЬ то, что считается, - ignore_vidpid.
	_ns_auto() {   # $1 - каталог устройства
		_sa_e="$NOT_MODEM_EXTRA"; _sa_f="$NOT_MODEM_FORCE"
		NOT_MODEM_EXTRA=""; NOT_MODEM_FORCE=""
		usb_is_modem "$1"; _sa_r=$?
		NOT_MODEM_EXTRA="$_sa_e"; NOT_MODEM_FORCE="$_sa_f"
		return $_sa_r
	}
	_ns_add() {   # _ns_add <path> <vidpid> <product> <ports> <absent> <узел>
		_nb=0; is_not_modem_builtin "$2" && _nb=1
		_na=0; _nw=""
		if [ -n "$6" ]; then
			_ns_auto "$6" && _na=1
			_nk=0; usb_is_modem "$6" || _nk=1
			_nw="$IM_WHY"; _nwd="$IM_DETAIL"
		else
			_na=0
			_nk=0; is_not_modem "$2" && _nk=1
			usb_is_modem_vidpid "$2" >/dev/null 2>&1
			_nw=absent; _nwd=""
		fi
		[ -n "$_ns_out" ] && _ns_out="$_ns_out,"
		_ns_out="$_ns_out{\"path\":\"$(_ns_esc "$1")\",\"vidpid\":\"$(_ns_esc "$2")\",\"product\":\"$(_ns_esc "$3")\",\"ports\":[$4],\"skip\":\"$_nk\",\"builtin\":\"$_nb\",\"auto\":\"$_na\",\"why\":\"$(_ns_esc "$_nw")\",\"detail\":\"$(_ns_esc "$_nwd")\",\"absent\":\"$5\"}"
	}

	for _nd in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
		[ -f "$_nd/idVendor" ] || continue
		case "$_nd" in *:*) continue ;; esac   # интерфейс, а не устройство
		_np=""
		# ГДЕ ЛЕЖАТ ПОРТА. У cdc_acm и cdc-wdm узел висит прямо на интерфейсе
		# (<iface>/tty/ttyACM0), а у usb-serial - уровнем глубже, через
		# собственный узел порта (<iface>/ttyUSB0/tty/ttyUSB0). Без второго
		# шаблона список портов у любого модема на option оставался пустым.
		for _ni in "$_nd":*; do
			for _nn in "$_ni"/tty/* "$_ni"/usbmisc/* "$_ni"/*/tty/* "$_ni"/*/usbmisc/*; do
				[ -e "$_nn" ] || continue
				_nnb=$(basename "$_nn")
				case ",$_np," in *"\"/dev/$_nnb\","*) continue ;; esac
				_np="${_np}${_np:+,}\"/dev/$_nnb\""
			done
		done
		_nvp="$(cat "$_nd/idVendor" 2>/dev/null):$(cat "$_nd/idProduct" 2>/dev/null)"
		_nbn=$(basename "$_nd")
		# без портов - берём только то, что уже показано модемом (HiLink и родня)
		if [ -z "$_np" ]; then
			case " $NM_MODEM_PATHS " in *" $_nbn "*) ;; *) continue ;; esac
		fi
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "$_nbn" "$_nvp" "$(cat "$_nd/product" 2>/dev/null)" "$_np" 0 "$_nd"
	done

	# ЗАПИСИ КОНФИГА БЕЗ ЖЕЛЕЗА. Устройство могли вынуть из разъёма - если не
	# показать его строку, галочка молча потерялась бы при следующем сохранении
	# (страница отдаёт то, что видит).
	_nm_cfg
	for _nvp in $NOT_MODEM_EXTRA $NOT_MODEM_FORCE; do
		case " $_ns_seen " in *" $_nvp "*) continue ;; esac
		_ns_seen="$_ns_seen $_nvp"
		_ns_add "" "$_nvp" "" "" 1 ""
	done

	echo "[$_ns_out]"
}

# Запуск как команды (не sourcing). При `. notmodem.sh` $0 остаётся именем
# родителя, поэтому сюда мы не попадаем даже с его аргументами.
case "$0" in
	*/notmodem.sh|notmodem.sh)
		case "$1" in
			scan)
				NM_MODEM_PATHS=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
					| jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
				nm_scan
				;;
			*) echo "usage: notmodem.sh scan" >&2; exit 1 ;;
		esac
		;;
esac
