#!/bin/sh
#
# Единственное место, где композиция USB сопоставляется драйверу usb-serial.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Привязку портов делали два обработчика хотплага
# независимо, и они успели разойтись:
#   - 90d6: 20-compal-t99w175 писал option1, а 70-5gmodem-sms-modems - generic.
#     Отрабатывали ОБА, то есть одна композиция привязывалась к двум драйверам
#     подряд, и какой в итоге обслуживал порты - зависело от порядка событий.
#   - у профилей modemband ровно та же болезнь уже случилась (шесть копий,
#     разошедшихся между собой), поэтому таблицу выносим сразу.
#
# Драйвер здесь ВЫБИРАЕТСЯ, но НЕ решается, надо ли вообще трогать устройство:
# это остаётся за обработчиками, у них разные условия (например, 90d5 делят
# Foxconn T99W175 и прототип Compal, их различают по USB-дескриптору).

# Драйвер для композиции. Неизвестные - generic: он безопаснее, порты выйдут
# урезанными, но выйдут.
driver_for() {   # $1 - vid, $2 - pid
	case "$1:$2" in
		# ЕДИНСТВЕННАЯ композиция, которой нужен option1: T99W175 в режиме QMI.
		# Сам порты не отдаёт вовсе, а нумерация отличается от 90d5.
		05c6:9025) echo "option1" ;;
		# Android-палки MDM9600/9610 в режиме «только модем» (см. newid_for).
		05c6:9091) echo "option1" ;;
		# Всё остальное - generic. Это касается и Compal RXM-G1 (90d5 и 90d6),
		# и T99W175 в 90d5.
		#
		# Раньше 20-compal-t99w175 заводил 90d6 через option1, а
		# 70-5gmodem-sms-modems - через generic, и отрабатывали ОБА. Измерено на
		# живом Компале: в new_id обоих драйверов лежало "05c6 90d6", порты
		# достались generic, и все три (ttyUSB7/8/9) отвечали ошибкой ввода-вывода
		# - то есть модем оставался без единого рабочего AT-порта.
		*)         echo "generic" ;;
	esac
}

# Строка для new_id. Обычно «vid pid»; ядро usb-serial принимает МАКСИМУМ
# третье поле - класс интерфейса («vid pid class»). Пятипольная форма с
# subclass/protocol ОТВЕРГАЕТСЯ записью (проверено на стенде 18.08.2026:
# rc=1) - первый вариант этого фикса писал «ff 00 00», отказ тонул в
# 2>/dev/null, и у юзера пропали все порты при бодром «bound ... via option1»
# в журнале.
# 05c6:9091 (Android-палки MDM9600/9610, режим «только модем»): класс ff
# накрывает и rmnet-канал (If#2, ff/ff/ff) - тоньше ядро не умеет, поэтому
# канал спасает адресная хирургия _rescue_rmnet ниже.
newid_for() {   # $1 - vid, $2 - pid
	case "$1:$2" in
		05c6:9091) echo "$1 $2 ff" ;;
		*)         echo "$1 $2" ;;
	esac
}

# АДРЕСНАЯ ХИРУРГИЯ ДЛЯ КОМПОЗИЦИЙ, ГДЕ КАНАЛ ДАННЫХ ТОЖЕ vendor-класса.
# Общая хирургия в bind_ports возвращает родным драйверам только НЕ-ff
# интерфейсы; у 9091 rmnet - ff/ff/ff, и на реэнумерации option может успеть
# забрать его раньше qmi_wwan (dynamic id живёт в драйвере до ребута). Здесь
# по НОМЕРУ интерфейса: If#2 = rmnet, usb-serial'у не принадлежит - снимаем и
# отдаём drivers_probe, qmi_wwan заберёт обратно. Вызывается и когда порты уже
# есть: ранний выход bind_ports не должен пропускать спасение канала.
_rescue_rmnet() {   # $1 - vid, $2 - pid, $3 - номер интерфейса канала (02)
	for _rr_d in /sys/bus/usb/devices/*; do
		[ -f "$_rr_d/idVendor" ] || continue
		[ "$(cat "$_rr_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_rr_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _rr_i in "$_rr_d":*."$3"; do
			[ -f "$_rr_i/bInterfaceNumber" ] || continue
			_rr_drv=$(basename "$(readlink -f "$_rr_i/driver" 2>/dev/null)" 2>/dev/null)
			case "$_rr_drv" in
				option1|usb_serial_generic|generic)
					_rr_if=$(basename "$_rr_i")
					echo "$_rr_if" > "$_rr_i/driver/unbind" 2>/dev/null
					echo "$_rr_if" > /sys/bus/usb/drivers_probe 2>/dev/null
					logger -t 5gmodem-usbports "rescued data interface $_rr_if from $_rr_drv (returned to its native driver)"
					;;
			esac
		done
	done
}

# Привязать порты. Идемпотентно: new_id можно писать повторно, поэтому вызов на
# уже привязанном устройстве безвреден.
bind_ports() {   # $1 - vid, $2 - pid
	[ -n "$1" ] && [ -n "$2" ] || return 1

	# Спасение канала - ДО раннего выхода «порты уже есть»: после реэнумерации
	# порты есть (dynamic id жив), но rmnet мог достаться usb-serial'у.
	case "$1:$2" in
		05c6:9091) _rescue_rmnet "$1" "$2" 2 ;;
	esac

	# У МОДЕМА ЕСТЬ РАБОЧИЙ КАНАЛ ДАННЫХ - НЕ ТРОГАЕМ ВОВСЕ.
	#
	# Это важнее проверки портов ниже и стоит первым. Драйвер usbserial_generic
	# ЖАДНЫЙ: он забирает ВСЕ интерфейсы устройства, включая тот, что должен
	# достаться qmi_wwan или cdc_mbim. Пока модем не переподключался, порядок
	# привязки складывается удачно и канал остаётся у своего драйвера, но стоит
	# устройству пройти через usb reset - и generic успевает первым.
	#
	# Живой отчёт (T99W175, 05c6:9025): после ресета в журнале
	#   usbserial_generic 1-1.1:1.4: generic converter detected
	#   usb 1-1.1: generic converter now attached to ttyUSB4
	# и следом cdc-wdm пропал, а интерфейс встал с NO_DEVICE. До ресета всё
	# работало. Пользователь при этом привязывает порты сам, строкой в
	# автозагрузке, - две записи в new_id (его generic и наш option1) и дают ту
	# самую гонку. На версиях без этого скрипта (1.9.0 и старше) конкурента не
	# было, поэтому там «всё работает».
	#
	# Правило: если у устройства уже есть cdc-wdm или сетевой интерфейс, значит
	# канал данных поднят и ttyUSB не стоят того, чтобы им рисковать. Метрики
	# переживут отсутствие AT-порта, потеря интернета - нет.
	# Канал поднят - привязываем ОСТОРОЖНО: сам факт wdm/net больше не повод
	# отказаться (у MBIM-композиций Compal 90d5/90d6 канал есть ВСЕГДА, и гвард
	# оставлял их без единого tty после каждой переэнумерации - метрики пустые,
	# «Модем не подключен» при живом IP). Риск гварда реален (жадный serial
	# может забрать CDC-интерфейс канала), поэтому после new_id делаем ХИРУРГИЮ:
	# у всех интерфейсов НЕ vendor-класса (ff), доставшихся usb-serial, привязку
	# снимаем и возвращаем их родным драйверам через drivers_probe.
	_bp_haswdm=0
	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_w in "$_bp_d":*/usbmisc/cdc-wdm* "$_bp_d":*/net/*; do
			[ -e "$_bp_w" ] || continue
			_bp_haswdm=1
			break
		done
	done

	# ПОРТЫ УЖЕ ЕСТЬ - НЕ ТРОГАЕМ.
	#
	# new_id можно писать повторно, но НЕ РАЗНЫМ драйверам: если одна и та же
	# композиция вписана и в generic, и в option1, ядро отдаёт интерфейсы тому,
	# кто успел, и порты нередко выходят нерабочими (проверено на живом Compal:
	# все ttyUSB отвечали ошибкой ввода-вывода).
	#
	# Ровно в это упирались пользователи, которые ПРИВЯЗЫВАЮТ ПОРТЫ САМИ - строкой
	# «echo "05c6 9025" > .../generic/new_id» в автозагрузке. До появления этого
	# скрипта (версии 1.5.x) приложение привязкой не занималось вовсе, их способ
	# работал, а потом мы стали вписывать ту же композицию в option1 - и модем
	# переставал подниматься. Отсюда и «на 1.5.0 всё работает, на новых нет».
	#
	# Поэтому: видим у устройства хоть один tty - значит его уже кто-то привязал
	# (ядро своей таблицей, чужой скрипт или наш прошлый проход), и вмешиваться
	# не нужно. Наш выбор драйвера - подсказка для случая, когда портов НЕТ.
	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_t in "$_bp_d":*/ttyUSB* "$_bp_d":*/tty/ttyUSB*; do
			[ -e "$_bp_t" ] || continue
			logger -t 5gmodem-usbports "$1:$2 already has ports - leaving the binding alone"
			return 0
		done
	done

	_bp_drv=$(driver_for "$1" "$2")
	_bp_path="/sys/bus/usb-serial/drivers/$_bp_drv/new_id"
	if [ ! -w "$_bp_path" ]; then
		# Драйвер не собран или не загружен - это не авария, но молчать нельзя:
		# без портов не будет ни метрик, ни SMS, и причина иначе не видна.
		logger -t 5gmodem-usbports "no $_bp_drv driver for $1:$2 ($_bp_path missing)"
		return 1
	fi
	# Отказ записи НЕ глотаем: именно молчаливый rc=1 (пятипольная форма)
	# оставил юзера без портов при бодром «bound» в журнале (18.08.2026).
	if ! echo "$(newid_for "$1" "$2")" > "$_bp_path" 2>/dev/null; then
		logger -t 5gmodem-usbports "new_id write failed for $1:$2 via $_bp_drv (kernel rejected '$(newid_for "$1" "$2")')"
		return 1
	fi
	logger -t 5gmodem-usbports "bound $1:$2 via $_bp_drv"
	case "$1:$2" in
		05c6:9091) sleep 1; _rescue_rmnet "$1" "$2" 2 ;;
	esac

	[ "$_bp_haswdm" = 1 ] || return 0
	# Хирургия после привязки при живом канале: не-ff интерфейсы (CDC comm/data,
	# сетевые) usb-serial'у не принадлежат - снимаем и отдаём drivers_probe,
	# родной драйвер (cdc_mbim/qmi_wwan) заберёт их обратно.
	sleep 2
	for _bp_d in /sys/bus/usb/devices/*; do
		[ -f "$_bp_d/idVendor" ] || continue
		[ "$(cat "$_bp_d/idVendor" 2>/dev/null)" = "$1" ] || continue
		[ "$(cat "$_bp_d/idProduct" 2>/dev/null)" = "$2" ] || continue
		for _bp_i in "$_bp_d":*; do
			[ -f "$_bp_i/bInterfaceClass" ] || continue
			_bp_cls=$(cat "$_bp_i/bInterfaceClass" 2>/dev/null)
			[ "$_bp_cls" = "ff" ] && continue
			_bp_idrv=$(basename "$(readlink -f "$_bp_i/driver" 2>/dev/null)" 2>/dev/null)
			case "$_bp_idrv" in
				option1|"usb_serial_generic"|generic)
					_bp_if=$(basename "$_bp_i")
					echo "$_bp_if" > "$_bp_i/driver/unbind" 2>/dev/null
					echo "$_bp_if" > /sys/bus/usb/drivers_probe 2>/dev/null
					logger -t 5gmodem-usbports "returned interface $_bp_if (class $_bp_cls) to its native driver"
					;;
			esac
		done
	done
}

# Привязка new_id НЕ переживает перезагрузку, а hotplug-событие 'add' для модема,
# воткнутого ДО загрузки (coldplug), в procd не приходит - его netlink-слушатель
# стартует уже после ранней энумерации USB, и ранние uevent'ы теряются. Итог: у
# композиций, которых нет в статической таблице драйвера (05c6:9025 - option1,
# 05c6:90d5/90d6 - generic), после ребута не появлялось НИ ОДНОГО ttyUSB - ни
# метрик, ни SMS, только IP через qmi_wwan (тот привязывается сам). Драйверы с
# 1e2d в статической таблице от этого не страдали, потому баг всплыл только на
# 05c6. Скан шины на каждом буте (init.d 5gmodem-usbports) закрывает дыру.
# ВЫБОР РАБОЧЕЙ КОНФИГУРАЦИИ USB.
#
# Модем может отдавать НЕСКОЛЬКО конфигураций, и ядро берёт первую по порядку -
# а она не всегда рабочая. Живой случай: Compal RXM-G1 с ЗАВОДСКОЙ прошивкой
# (05c6:9063, дескриптор VOS_5G) отдаёт три:
#   1 - CDC ECM   (простая сетевая карта; берётся по умолчанию)
#   2 - RNDIS
#   3 - CDC MBIM  (полноценный канал: cdc-wdm + wwan)
# В ECM прошивка себя НЕ УДЕРЖИВАЕТ: устройство перечислялось заново каждые
# полторы секунды - 115 раз подряд в логе пользователя, - и настроить его было
# нельзя в принципе. В Windows тот же модем работает, потому что там выбирается
# другая конфигурация. Переключение на MBIM останавливает цикл сразу же
# (проверено на живом аппарате 29.07: после записи «3» - ни одного отвала).
#
# ЗНАЧЕНИЕ НЕ ПЕРЕЖИВАЕТ ПЕРЕЗАГРУЗКУ, поэтому чиним на каждом буте, как и
# привязку портов. Правим ТОЛЬКО известные пары «модем -> конфигурация»: выбор
# конфигурации меняет поведение железа, и угадывать тут нельзя.
pick_config() {   # $1 - каталог устройства в sysfs, $2 - нужная конфигурация
	[ -f "$1/bConfigurationValue" ] || return 0
	_pc_now=$(cat "$1/bConfigurationValue" 2>/dev/null)
	[ "$_pc_now" = "$2" ] && return 0
	# Конфигурация должна существовать - иначе запись просто отвалится ошибкой.
	_pc_num=$(cat "$1/bNumConfigurations" 2>/dev/null)
	case "$_pc_num" in ''|*[!0-9]*) return 0 ;; esac
	[ "$_pc_num" -ge "$2" ] || return 0
	echo "$2" > "$1/bConfigurationValue" 2>/dev/null \
		&& logger -t 5gmodem "usb: $(basename "$1") switched to configuration $2 (was $_pc_now)"
}

coldplug() {
	for _cp_d in /sys/bus/usb/devices/*; do
		[ -f "$_cp_d/idVendor" ] || continue
		_cp_v=$(cat "$_cp_d/idVendor" 2>/dev/null)
		_cp_p=$(cat "$_cp_d/idProduct" 2>/dev/null)
		case "$_cp_v:$_cp_p" in
			05c6:9025|05c6:90d5|05c6:90d6|05c6:9091) bind_ports "$_cp_v" "$_cp_p" ;;
			# Заводской Compal RXM-G1: ECM по умолчанию не работает, нужен MBIM.
			05c6:9063) pick_config "$_cp_d" 3 ;;
		esac
	done
}

case "$1" in
	bind)     bind_ports "$2" "$3" ;;
	driver)   driver_for "$2" "$3" ;;
	coldplug) coldplug ;;
esac
