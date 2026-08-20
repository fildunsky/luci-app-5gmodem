#!/bin/sh
# Телеметрия по единой канонической схеме (docs/telemetry.md): плоский JSON с
# каноническими короткими полями в /tmp/5gmodem_tele.json. Источник - ГОТОВЫЙ
# снимок метрик активного модема: ни одного нового запроса к модему этот файл
# не порождает, писать его дёшево. Смысл файла - одна точка, откуда умный дом,
# внешние дисплеи и чужие дашборды забирают данные, НЕ дёргая rpcd и наши
# скрипты (раньше внешние интеграции звали 5gmodem.sh по ssh - каждый вызов
# форкал полный опрос).
#
# Приватность BY DESIGN: в файл не попадают IMEI, IMSI, ICCID, номер телефона
# и координаты - только уровень/качество сигнала, оператор, режим, температура
# и трафик. Файл можно отдавать наружу, не подумав дважды.
#
# Вербы:
#   write     - собрать и атомарно переписать /tmp/5gmodem_tele.json
#   publish   - write + отправить в MQTT (нужен mosquitto_pub и настроенный
#               брокер в uci 5gmodem.tele)
#   discovery - опубликовать HA-автообнаружение (retain), один раз после
#               настройки брокера
#   show      - напечатать текущий файл (для отладки)

CFG=5gmodem
TELE=/tmp/5gmodem_tele.json
TELE_CELL=/tmp/5gmodem_tele_cell.json
PREV=/tmp/5gmodem_tele.prev

_g() { uci -q get "$CFG.tele.$1"; }

# Выключатель: отсутствие значения = ВКЛЮЧЕНО (файл локальный и дешёвый).
tele_enabled() { [ "$(_g enabled)" != "0" ]; }

# --- Значение из снимка метрик ------------------------------------------------
_AM=$(uci -q get "$CFG.@5gmodem[0].active_modem")
_KEY=$(echo "$_AM" | tr -c 'A-Za-z0-9' '_')
_SNAP="/tmp/5gmodem_metrics_${_KEY}.json"

_jf() { jsonfilter -i "$_SNAP" -e "@.$1" 2>/dev/null; }

# Число из строки снимка: пустое/прочерк -> пусто; дробное округляется к
# ближайшему целому (правило схемы: одна программа округлила бы floor, другая
# printf - и значения на границах разъезжались бы на единицу).
_int() {
	case "$1" in ''|-|--|---) return ;; esac
	printf '%s' "$1" | awk '/^-?[0-9]+(\.[0-9]+)?$/ { printf "%d", ($1 < 0 ? $1 - 0.5 : $1 + 0.5) }'
}

# Пара "имя":значение / "имя":"строка" - только когда значение непусто
# (правило схемы: нет данных = нет ключа, а не 0 и не -1).
_J=""
_num() { [ -n "$2" ] && _J="$_J${_J:+,}\"$1\":$2"; }
_str() {
	[ -n "$2" ] || return 0
	_s=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
	_J="$_J${_J:+,}\"$1\":\"$_s\""
}

tele_write() {
	# СВЕЖЕСТЬ СНИМКА - ОБЯЗАТЕЛЬНАЯ ПРОВЕРКА. Снимок метрик живёт в /tmp и
	# может протухнуть на часы (модем вынут, интерфейс лежит, страница
	# закрыта) - без гейта телеметрия отдавала бы «сигнал 67» у мёртвого
	# модема (поймано на живом тесте 20.08.2026: снимок отстал на 7 часов).
	# Протух - модемные поля не пишем вовсе (правило схемы: нет данных = нет
	# ключа); файл при этом обновляется - потребитель по отсутствию полей
	# видит, что модемных данных нет, а по mtime - что экспортёр жив.
	_fresh=""
	if [ -n "$_AM" ] && [ -s "$_SNAP" ]; then
		_st=$(cat "${_SNAP%.json}.stamp" 2>/dev/null)
		case "$_st" in
			''|*[!0-9]*) ;;
			*) [ $(( $(cut -d. -f1 /proc/uptime) - _st )) -le 120 ] && _fresh=1 ;;
		esac
	fi

	if [ -n "$_fresh" ]; then
	_num sig  "$(_int "$(_jf signal)")"
	_str oper "$(_jf operator_name | sed 's/^-$//')"
	_num rsrp "$(_int "$(_jf rsrp)")"
	_num rsrq "$(_int "$(_jf rsrq)")"
	_num sinr "$(_int "$(_jf sinr)")"
	_num temp "$(_int "$(_jf mtemp | sed 's/ *&deg;C//')")"

	# band - ПЕРВИЧНАЯ несущая, одним токеном (B3 / n78). Агрегация - отдельным
	# полем ca: активные несущие через "+", в порядке PCC..SCC (поле добавлено
	# в схему нами, см. docs/telemetry.md).
	_pb=$(_jf pband | grep -oE '^[Bn][0-9]+' | head -1)
	_str band "$_pb"
	_ca="$_pb"
	for _i in 1 2 3 4; do
		[ "$(_jf "s${_i}state")" = "activated" ] || continue
		_sb=$(_jf "s${_i}band" | grep -oE '^[Bn][0-9]+' | head -1)
		[ -n "$_sb" ] && _ca="$_ca+$_sb"
	done
	case "$_ca" in *+*) _str ca "$_ca" ;; esac

	# mode - телефонный ярлык по схеме: 4G / 4G+ / 5G NSA / 5G SA / 3G / 2G.
	_md=$(_jf mode | sed 's/ *|.*//; s/ B[0-9].*//')
	case "$_md" in
		LTE-A*) _md="4G+" ;;
		LTE*)   _md="4G" ;;
		*5G\ NSA*|*NSA*) _md="5G NSA" ;;
		*5G\ SA*|NR5G*)  _md="5G SA" ;;
		WCDMA*|UMTS*|HSPA*|HSDPA*|HSUPA*|3G*) _md="3G" ;;
		GSM*|EDGE*|GPRS*|2G*) _md="2G" ;;
		''|-) _md="" ;;
	esac
	_str mode "$_md"

	fi   # _fresh

	# ping - последний замер сторожа по интерфейсу модема (4-е поле state-файла).
	_net=""
	[ -n "$_fresh" ] && _net=$(_jf iface)
	[ -n "$_net" ] || _net=$(uci -q get "$CFG.@5gmodem[0].network")
	if [ -n "$_net" ] && [ -f "/tmp/5gmodem_health/$_net" ]; then
		read -r _hs _hf _ho _hms _hsince < "/tmp/5gmodem_health/$_net"
		[ "$_hs" = "up" ] && _num ping "$(_int "$_hms")"
	fi

	# rx/tx - СКОРОСТЬ в Б/с из дельты счётчиков ядра между нашими записями.
	# Окно усреднения = интервал вызова write (тик сторожа); это и есть
	# канонический способ счёта из схемы. Первая запись после старта поля не
	# даёт (нет прошлой точки) - по правилу «нет данных = нет ключа».
	_dev=""
	[ -n "$_net" ] && _dev=$(ubus call network.interface."$_net" status 2>/dev/null \
		| jsonfilter -e '@.l3_device' 2>/dev/null)
	if [ -n "$_dev" ] && [ -d "/sys/class/net/$_dev" ]; then
		_now=$(cut -d. -f1 /proc/uptime)
		_rxb=$(cat "/sys/class/net/$_dev/statistics/rx_bytes" 2>/dev/null)
		_txb=$(cat "/sys/class/net/$_dev/statistics/tx_bytes" 2>/dev/null)
		if [ -s "$PREV" ]; then
			read -r _pt _prx _ptx _pdev < "$PREV"
			_dt=$((_now - _pt))
			# Смена устройства или переполнение = точка невалидна, пропускаем.
			if [ "$_pdev" = "$_dev" ] && [ "$_dt" -gt 0 ] && [ "$_dt" -lt 3600 ] \
				&& [ "$_rxb" -ge "$_prx" ] && [ "$_txb" -ge "$_ptx" ]; then
				_num rx $(( (_rxb - _prx) / _dt ))
				_num tx $(( (_txb - _ptx) / _dt ))
			fi
		fi
		printf '%s %s %s %s\n' "$_now" "$_rxb" "$_txb" "$_dev" > "$PREV.tmp" \
			&& mv "$PREV.tmp" "$PREV"
	fi

	# sms - непрочитанные, из зеркала для внешних программ (обновляется тем же
	# сторожем не чаще раза в минуту).
	_sc=$(jsonfilter -i /tmp/5gmodem_sms_new.json -e '@.count' 2>/dev/null)
	_num sms "$(_int "$_sc")"

	# ОСЕЧКА ОПРОСА НЕ ПУБЛИКУЕТСЯ. Сборщик метрик публикует снимок и с пустым
	# сигнальным ядром - когда AT-порт в момент сбора был занят (странице это
	# не мешает, она рисует прочерки). Но по контракту телеметрии «свежий файл
	# без модемных полей = модем вынут», и одиночная заминка порта гасила
	# модемную карточку у потребителя (живой отчёт экрана Almond, 20.08.2026).
	# Поэтому: снимок свежий, но ядра нет (ни sig, ни rsrp, ни oper), а прежний
	# файл ядро содержал - НЕ переписываем оба файла, оставляем прежние.
	# Настоящее исчезновение модема сигнализируется иначе - штамп снимка
	# перестаёт обновляться, гейт свежести закрывается, и поля выпадают
	# легально через TTL.
	if [ -n "$_fresh" ]; then
		case "$_J" in
			*'"sig"'*|*'"rsrp"'*|*'"oper"'*) ;;
			*)
				case "$(cat "$TELE" 2>/dev/null)" in
					*'"sig"'*|*'"rsrp"'*|*'"oper"'*) return 0 ;;
				esac ;;
		esac
	fi

	printf '{%s}\n' "$_J" > "$TELE.tmp" && mv "$TELE.tmp" "$TELE"

	# ДЕТАЛИ СОТЫ - ОТДЕЛЬНЫМ ЛОКАЛЬНЫМ ФАЙЛОМ (схема, раздел 2.1; запрос
	# экрана Almond). В основной файл им нельзя: он публикуемый (MQTT целиком,
	# HTTP-рецепт), а cid/tac/enb локализуют положение, wan_ip - приватный
	# адрес. Файл-приложение наружу не публикуется никем по договорённости.
	_J=""
	if [ -n "$_fresh" ]; then
		_num pci    "$(_int "$(_jf pci)")"
		_num earfcn "$(_int "$(_jf earfcn)")"
		_num enb    "$(_int "$(_jf enbid)")"
		_num cid    "$(_int "$(_jf cid_dec)")"
		_num tac    "$(_int "$(_jf tac_dec)")"
		_str apn    "$(_jf iface_apn | sed 's/^-$//')"
		_str wan_ip "$(_jf ipaddr | sed 's/^-$//')"
		_str modem  "$(_jf modem | sed 's/^-$//')"
		# Полный набор для локальной страницы «Сота/Модем» (запрос экрана
		# Almond, 20.08.2026): числа - числами, витринные строки (полоса,
		# мощность, MIMO, антенны) - как в снимке, экран показывает их как
		# есть. phone здесь ДОПУСТИМ: файл-приложение локальный и не
		# публикуется никем - канонический запрет идентификаторов действует
		# для основного (публикуемого) файла.
		_num mcc      "$(_int "$(_jf operator_mcc)")"
		# MNC - СТРОКОЙ: ведущий ноль значащий (250-02 МегаФон и 250-2 -
		# разные сети), int его съедал (поймано на живом деплое 20.08.2026).
		_str mnc      "$(_jf operator_mnc | grep -E '^[0-9]+$')"
		_num lac      "$(_int "$(_jf lac_dec)")"
		_str cid_hex  "$(_jf cid_hex | sed 's/^-$//')"
		_str bandwidth "$(_jf bandwidth | sed 's/^-$//')"
		_num pathloss "$(_int "$(_jf pathloss)")"
		_str txpower  "$(_jf txpower | sed 's/^-$//')"
		_num cqi      "$(_int "$(_jf cqi)")"
		_str uecat    "$(_jf uecat | sed 's/^-$//')"
		_str volte    "$(_jf volte | sed 's/^-$//')"
		_str mimo     "$(_jf pmimo | sed 's/^-$//')"
		_str rxdiv    "$(_jf rxdiv | sed 's/^-$//')"
		_str antports "$(_jf antports | sed 's/^-$//')"
		_num csq      "$(_int "$(_jf csq)")"
		_num rssi     "$(_int "$(_jf rssi)")"
		_num conn_time "$(_int "$(_jf conn_time_sec)")"
		_str therm    "$(_jf mtherm | sed 's/^-$//')"
		_num simslot  "$(_int "$(_jf simslot)")"
		_num roaming  "$(_int "$(_jf roaming)")"
		_str fw       "$(_jf firmware | sed 's/^-$//')"
		_str phone    "$(_jf phone | sed 's/^-$//')"
		# Несущие агрегации s1..s4 + счётчик активных nca.
		_nca=0
		for _i in 1 2 3 4; do
			_sb=$(_jf "s${_i}band" | sed 's/^-$//')
			[ -n "$_sb" ] || continue
			_str "s${_i}band"   "$_sb"
			_num "s${_i}pci"    "$(_int "$(_jf "s${_i}pci")")"
			_num "s${_i}earfcn" "$(_int "$(_jf "s${_i}earfcn")")"
			_num "s${_i}rsrp"   "$(_int "$(_jf "s${_i}rsrp")")"
			_num "s${_i}rsrq"   "$(_int "$(_jf "s${_i}rsrq")")"
			_num "s${_i}sinr"   "$(_int "$(_jf "s${_i}sinr")")"
			_ss=$(_jf "s${_i}state")
			_str "s${_i}state" "$_ss"
			[ "$_ss" = "activated" ] && _nca=$((_nca + 1))
		done
		_num nca "$_nca"
		# Соседние соты - массив из снимка как есть (band/earfcn/pci/rsrp/
		# rsrq/rssi/serving; схема требует подмножество, лишние ключи не
		# мешают). Снимок держит его одной строкой, вложенных скобок в
		# объектах нет - вырезка надёжна.
		_nb=$(grep -o '"neighbors":\[[^]]*\]' "$_SNAP" 2>/dev/null | head -1)
		_nb=${_nb#\"neighbors\":}
		case "$_nb" in \[*\]) [ "$_nb" != "[]" ] && _J="$_J${_J:+,}\"nbrs\":$_nb" ;; esac
	fi
	printf '{%s}\n' "$_J" > "$TELE_CELL.tmp" && mv "$TELE_CELL.tmp" "$TELE_CELL"
}

# --- MQTT ---------------------------------------------------------------------
# Публикация состояния одной темой (схема, раздел 4). Всё опционально: без
# настроенного брокера и mosquitto_pub тихо выходим.
_mqtt_args() {
	_h=$(_g mqtt_host); [ -n "$_h" ] || return 1
	command -v mosquitto_pub >/dev/null 2>&1 || return 1
	_p=$(_g mqtt_port); _u=$(_g mqtt_user); _w=$(_g mqtt_pass)
	MARGS="-h $_h -p ${_p:-1883}"
	[ -n "$_u" ] && MARGS="$MARGS -u $_u"
	[ -n "$_w" ] && MARGS="$MARGS -P $_w"
	_dn=$(_g name); [ -n "$_dn" ] || _dn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	TOPIC=$(_g mqtt_topic); [ -n "$TOPIC" ] || TOPIC="5gmodem/$_dn"
	DEVNAME="$_dn"
	return 0
}

tele_publish() {
	tele_write
	_mqtt_args || return 0
	[ -s "$TELE" ] || return 0
	mosquitto_pub $MARGS -t "$TOPIC/state" -f "$TELE" 2>/dev/null \
		&& mosquitto_pub $MARGS -t "$TOPIC/available" -m online 2>/dev/null
}

# HA-автообнаружение: по одной retain-теме на метрику (схема, раздел 4).
tele_discovery() {
	_mqtt_args || { echo '{"error":"no broker configured or mosquitto_pub missing"}'; return 1; }
	_disc() {   # $1 поле, $2 имя, $3 единица, $4 device_class (пусто = без него)
		_cfg="{\"name\":\"$2\",\"state_topic\":\"$TOPIC/state\",\"value_template\":\"{{ value_json.$1 }}\""
		[ -n "$3" ] && _cfg="$_cfg,\"unit_of_measurement\":\"$3\""
		[ -n "$4" ] && _cfg="$_cfg,\"device_class\":\"$4\""
		_cfg="$_cfg,\"availability_topic\":\"$TOPIC/available\",\"unique_id\":\"${DEVNAME}_$1\""
		_cfg="$_cfg,\"device\":{\"identifiers\":[\"$DEVNAME\"],\"model\":\"luci-app-5gmodem\",\"manufacturer\":\"OpenWrt\"}}"
		mosquitto_pub $MARGS -r -t "homeassistant/sensor/${DEVNAME}_$1/config" -m "$_cfg" 2>/dev/null
	}
	_disc sig  "Signal"        "%"    signal_strength
	_disc rsrp "RSRP"          "dBm"  signal_strength
	_disc rsrq "RSRQ"          "dB"   ""
	_disc sinr "SINR"          "dB"   ""
	_disc temp "Modem temperature" "°C" temperature
	_disc oper "Operator"      ""     ""
	_disc mode "Network mode"  ""     ""
	_disc band "Band"          ""     ""
	_disc ca   "Carrier aggregation" "" ""
	_disc ping "Ping"          "ms"   duration
	_disc rx   "Download rate" "B/s"  data_rate
	_disc tx   "Upload rate"   "B/s"  data_rate
	_disc sms  "Unread SMS"    ""     ""
	echo '{"result":"ok"}'
}

# ФОНОВОЕ ОБНОВЛЕНИЕ СНИМКА БЕЗ СТРАНИЦЫ. Сборщик метрик сторожа работает
# только при открытой странице «Сеть» (маркер page_active, 15 c) - закрыл
# браузер, и снимок протухает, а с ним слепнет и телеметрия (поймано на живом
# Almond_Pro 20.08.2026: модем на шине, а в файле только ping/sms). Умный дом
# живёт без браузера, поэтому при протухшем снимке и закрытой странице
# обновляем его сами - тем же единственным сборщиком (cached сериализуется
# через LOCKDIR), не чаще раза в tele.refresh секунд (по умолчанию 120;
# 0 = не обновлять самим). Полный сбор стоит ~1.5 c CPU - раз в две минуты
# это незаметно даже слабому железу. При открытой странице снимок и так
# свежий (<7 c) - гейт по штампу не даст спавнить лишнего.
_refresh_snap() {
	_rf=$(_g refresh); case "$_rf" in ''|*[!0-9]*) _rf=120 ;; esac
	[ "$_rf" = "0" ] && return 0
	[ -n "$_AM" ] || return 0
	_rs_st=$(cat "${_SNAP%.json}.stamp" 2>/dev/null)
	case "$_rs_st" in
		*[!0-9]*) _rs_st=0 ;;
		'') _rs_st=0 ;;
	esac
	[ $(( $(cut -d. -f1 /proc/uptime) - _rs_st )) -ge "$_rf" ] || return 0
	# Ограниченный по времени сбор: на мёртвом порту полный опрос может висеть,
	# а мы в цикле сторожа - дольше 25 c не ждём (паттерн _sw_run).
	SW_BG=1 "$(dirname "$0")/5gmodem.sh" cached 60 "for=$_AM" >/dev/null 2>&1 &
	_rs_p=$!
	( sleep 25; kill "$_rs_p" 2>/dev/null ) >/dev/null 2>&1 &
	_rs_w=$!
	wait "$_rs_p" 2>/dev/null
	kill "$_rs_w" 2>/dev/null; wait "$_rs_w" 2>/dev/null
	return 0
}

case "$1" in
	# tick - вызов из цикла сторожа: с настроенным брокером публикуем,
	# без него просто обновляем файл.
	tick)      tele_enabled || exit 0
	           _refresh_snap
	           if _mqtt_args >/dev/null 2>&1; then tele_publish; else tele_write; fi ;;
	write)     tele_enabled && tele_write ;;
	publish)   tele_enabled && tele_publish ;;
	discovery) tele_discovery ;;
	show)      cat "$TELE" 2>/dev/null ;;
	*) echo "usage: $0 {write|publish|discovery|show}" >&2; exit 1 ;;
esac
exit 0
