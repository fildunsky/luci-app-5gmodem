#!/bin/sh
#
# Модемы без AT-портов, управляемые своим веб-интерфейсом (HiLink).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ БЭКЕНД. Huawei E3372h и родственные ему (ZTE, Alcatel и часть
# D-Link) держат IP-стек сами и отдают роутеру обычную сетевую карту. У них НЕТ
# ни AT-порта, ни cdc-wdm: sms_tool к ним неприменим в принципе, и весь наш
# основной путь опроса для них не существует. Зато у них есть HTTP-API, где
# лежит ровно то же самое - сигнал, оператор, режим сети, трафик, SMS.
#
# Этот скрипт - второй источник метрик рядом с AT. Отдаёт JSON В ТОМ ЖЕ ФОРМАТЕ,
# что и 5gmodem.sh, чтобы страницы не знали, с каким классом модема имеют дело.
#
# --- ОБ АВТОРИЗАЦИИ ----------------------------------------------------------
# Каждый запрос требует пары «сессия + токен» из /api/webserver/SesTokInfo.
# Токен ОДНОРАЗОВЫЙ у операций записи и живёт недолго у чтения, поэтому кэшируем
# на несколько секунд и перезапрашиваем при первой же ошибке, а не по таймеру:
# так один лишний запрос вместо гадания о сроке жизни.
#
# --- ОБ АДРЕСЕ МОДЕМА --------------------------------------------------------
# Модем - это шлюз по умолчанию на СВОЁЙ сетевой карте. Берём адрес оттуда, а не
# из захардкоженного 192.168.8.1: у разных прошивок он разный (на проверенном
# E3372h - 192.168.43.1), да и пользователь мог его сменить.

RES=/usr/share/5gmodem
CFG=5gmodem
CACHE_DIR=/tmp
UA="5gmodem"
. "$RES/lib.sh"   # opname_brand - бренд MVNO по IMSI

# --- адрес модема ------------------------------------------------------------

# Сетевая карта модема по usb-пути (или у активного, если путь не задан).
_netdev_for() {
	_p="$1"
	[ -n "$_p" ] || _p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	[ -n "$_p" ] || return 1
	_s="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_d=$(uci -q get "$CFG.$_s.netdev")
	[ -n "$_d" ] && { echo "$_d"; return 0; }
	# в конфиге ещё нет - спросим у перечислителя
	"$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_p\"].net[0]" 2>/dev/null
}

# НАШ адрес в подсети модема. Нужен, чтобы явно привязывать запросы к нему.
#
# ЗАЧЕМ. На карте модема может быть НЕСКОЛЬКО адресов: часть прошивок отдаёт
# роутеру ещё и настоящий WAN-адрес (наблюдалось: eth3 = 100.81.31.131 и
# 192.168.43.2 одновременно). Тогда ядро выбирает источником первый попавшийся,
# модем видит чужую сеть и не отвечает - API молча замолкает. Поэтому источник
# задаём сами, из той же подсети, где живёт модем.
_srcip_for() {   # $1 - usb-путь, $2 - адрес модема
	_dev=$(_netdev_for "$1") || return 1
	_net="${2%.*}."
	ip -4 addr show dev "$_dev" 2>/dev/null \
		| sed -n 's|.*inet \([0-9.]*\)/.*|\1|p' \
		| grep "^$_net" | head -1
}

# Адрес модема = шлюз на его сетевой карте.
_addr_for() {
	_dev=$(_netdev_for "$1") || return 1
	[ -n "$_dev" ] || return 1
	_gw=$(ip route show dev "$_dev" 2>/dev/null \
		| sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
	if [ -z "$_gw" ]; then
		# Интерфейс мог быть поднят без маршрута по умолчанию (метрика, политика
		# маршрутизации). Тогда берём сеть карты и предполагаем .1 - так устроены
		# все виденные прошивки.
		_ip=$(ip -4 addr show dev "$_dev" 2>/dev/null \
			| sed -n 's|.*inet \([0-9.]*\)/.*|\1|p' | head -1)
		[ -n "$_ip" ] && _gw="${_ip%.*}.1"
	fi
	[ -n "$_gw" ] || return 1
	echo "$_gw"
}

# --- сессия ------------------------------------------------------------------

_sess_file() { echo "$CACHE_DIR/5gmodem_hilink_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"; }

# Обновить пару сессия/токен. Печатает "SID<TAB>TOK".
_sess_new() {
	_a="$1"; _d="$2"
	_src=$(_srcip_for "" "$_a"); [ -n "$_src" ] || _src="$_d"
	_r=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
		"http://$_a/api/webserver/SesTokInfo" 2>/dev/null)
	_sid=$(echo "$_r" | sed -n 's|.*<SesInfo>\(.*\)</SesInfo>.*|\1|p')
	_tok=$(echo "$_r" | sed -n 's|.*<TokInfo>\(.*\)</TokInfo>.*|\1|p')
	[ -n "$_sid" ] && [ -n "$_tok" ] || return 1
	printf '%s\t%s\n' "$_sid" "$_tok" > "$(_sess_file "$_a")"
	printf '%s\t%s\n' "$_sid" "$_tok"
}

_sess_get() {
	_f=$(_sess_file "$1")
	# 10 секунд - компромисс: токен живёт дольше, но при записи он одноразовый,
	# и слишком долгий кэш означал бы гарантированный промах на каждой команде.
	if [ -s "$_f" ] && [ -z "$(find "$_f" -mmin +1 2>/dev/null)" ]; then
		cat "$_f"
		return 0
	fi
	_sess_new "$1" "$2"
}

# GET к API. При ошибке сессии (125002/125003) обновляет её и повторяет ОДИН раз.
api_get() {   # $1 - путь вида /api/..., $2 - usb-путь модема (необяз.)
	_ep="$1"
	_a=$(_addr_for "$2") || return 1
	_d=$(_netdev_for "$2") || return 1
	_s=$(_sess_get "$_a" "$_d") || return 1
	_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
	_src=$(_srcip_for "$2" "$_a"); [ -n "$_src" ] || _src="$_d"
	_out=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		"http://$_a$_ep" 2>/dev/null)
	# Повторяем не только на кодах сессии, но и на ПУСТОМ ответе: часть прошивок на
	# протухшую сессию отдаёт не 125003, а пустоту (или curl оборвался). Раньше
	# пустой ответ уходил наверх как есть -> все поля бланк -> 5gmodem.sh кэшировал
	# бланк поверх хорошего снимка. Обновляем сессию и пробуем ещё раз.
	case "$_out" in
		''|*'<code>125002</code>'*|*'<code>125003</code>'*|*'<code>125001</code>'*)
			_s=$(_sess_new "$_a" "$_d") || return 1
			_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
			_out=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
				-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
				"http://$_a$_ep" 2>/dev/null)
			;;
	esac
	printf '%s' "$_out"
}

# POST к API (операции записи). Токен одноразовый - всегда берём свежий.
api_post() {   # $1 - путь, $2 - тело XML, $3 - usb-путь
	_ep="$1"; _body="$2"
	_a=$(_addr_for "$3") || return 1
	_d=$(_netdev_for "$3") || return 1
	_s=$(_sess_new "$_a" "$_d") || return 1
	_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
	_src=$(_srcip_for "$3" "$_a"); [ -n "$_src" ] || _src="$_d"
	curl -s --max-time 10 --interface "$_src" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>$_body</request>" \
		"http://$_a$_ep" 2>/dev/null
}

# Значение одного тега из ответа.
#
# ФОРМАТИРОВАНИЕ ОТВЕТА У РАЗНЫХ ЭНДПОИНТОВ РАЗНОЕ. monitoring/status приходит
# «тег на строку», а dialup/connection - ВСЕ ТЕГИ В ОДНУ СТРОКУ. Прежняя версия
# требовала тег на отдельной строке и на однострочном XML молча возвращала
# пустоту: настройка роуминга читалась как «выключено» при включённой в модеме.
# Поэтому сначала САМИ расставляем переводы строк перед каждым тегом, и разбор
# перестаёт зависеть от того, как прошивка отформатировала ответ.
#
# tr -d '\r' ОБЯЗАТЕЛЕН: прошивка отдаёт CRLF, и без него якорь $ не совпадал.
xval() {
	# Разбиваем по тегам ЛИТЕРАЛЬНЫМ переводом строки: в busybox sed
	# последовательность \n в ПРАВОЙ части не разворачивается в перевод строки
	# (проверено - разбор молча ломался, все поля выходили пустыми).
	tr -d '\r' | sed 's|<|\
<|g' | sed -n "s|^<$1>\(.*\)\$|\1|p" | head -1
}

# Значение, безопасное для вставки в JSON: убираем управляющие символы и
# экранируем кавычки со слэшем. Один сбойный байт ломает разбор ВСЕГО ответа на
# странице, а выглядит это как «данных нет» - искать потом долго.
jsafe() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ДАННЫЕ В РОУМИНГЕ у HiLink-модема.
#
# Настройка живёт в /api/dialup/connection, поле RoamAutoConnectEnable - это
# ровно тот тумблер, что есть в веб-админке модема. Отдельного «состояния» тут
# нет: прошивка сама решает, дозваниваться ли, зарегистрировавшись в роуминге.
#
# ВАЖНО про запись: прошивка принимает ТОЛЬКО ПОЛНЫЙ набор полей. Пошлёшь одно
# RoamAutoConnectEnable - остальные обнулятся (MTU станет 0, автодозвон
# выключится). Поэтому сперва читаем текущие, потом переписываем одно поле.
hl_getroaming() {   # $1 - usb-путь
	_gr=$(api_get /api/dialup/connection "$1" 2>/dev/null | xval RoamAutoConnectEnable)
	case "$_gr" in 1) echo 1 ;; *) echo 0 ;; esac
}

hl_setroaming() {   # $1 - usb-путь, $2 - 0|1
	case "$2" in 0|1) : ;; *) echo '{"error":"value must be 0 or 1"}'; return 0 ;; esac
	_sr_cur=$(api_get /api/dialup/connection "$1" 2>/dev/null)
	_sr_idle=$(printf '%s' "$_sr_cur" | xval MaxIdelTime);   [ -n "$_sr_idle" ] || _sr_idle=0
	_sr_cm=$(printf '%s' "$_sr_cur"   | xval ConnectMode);   [ -n "$_sr_cm" ]   || _sr_cm=0
	_sr_mtu=$(printf '%s' "$_sr_cur"  | xval MTU);           [ -n "$_sr_mtu" ]  || _sr_mtu=1500
	_sr_ads=$(printf '%s' "$_sr_cur"  | xval auto_dial_switch); [ -n "$_sr_ads" ] || _sr_ads=1
	_sr_pao=$(printf '%s' "$_sr_cur"  | xval pdp_always_on);    [ -n "$_sr_pao" ] || _sr_pao=1
	_sr_r=$(api_post /api/dialup/connection \
		"<RoamAutoConnectEnable>$2</RoamAutoConnectEnable><MaxIdelTime>$_sr_idle</MaxIdelTime><ConnectMode>$_sr_cm</ConnectMode><MTU>$_sr_mtu</MTU><auto_dial_switch>$_sr_ads</auto_dial_switch><pdp_always_on>$_sr_pao</pdp_always_on>" \
		"$1")
	case "$_sr_r" in
		*'<response>OK</response>'*) printf '{"success":true,"allow_roaming":"%s"}\n' "$2" ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_sr_r" | xval code)" ;;
	esac
}

# --- расшифровка кодов -------------------------------------------------------

# CurrentNetworkType. Коды взяты из ответов прошивки и общеизвестного списка
# Huawei; неизвестные отдаём числом, а не выдумываем название.
nettype_name() {
	case "$1" in
		0)  echo "-" ;;
		1)  echo "GSM" ;;
		2)  echo "GPRS" ;;
		3)  echo "EDGE" ;;
		4)  echo "WCDMA" ;;
		5)  echo "HSDPA" ;;
		6)  echo "HSUPA" ;;
		7)  echo "HSPA" ;;
		9)  echo "HSPA+" ;;
		19) echo "LTE" ;;
		41) echo "UMTS" ;;
		44) echo "HSPA" ;;
		45) echo "HSPA+" ;;
		46) echo "LTE-A" ;;
		101) echo "5G NSA" ;;
		102) echo "5G SA" ;;
		*)  echo "$1" ;;
	esac
}

# Байты в человекочитаемый вид - теми же единицами, что показывает ifconfig
# (MiB/GiB), чтобы у двух классов модемов трафик выглядел одинаково.
_human() {
	_b="$1"
	case "$_b" in ''|*[!0-9]*) echo "-"; return ;; esac
	if   [ "$_b" -ge 1073741824 ]; then
		printf '%d.%d GiB\n' $(( _b / 1073741824 )) $(( _b % 1073741824 * 10 / 1073741824 ))
	elif [ "$_b" -ge 1048576 ]; then
		printf '%d.%d MiB\n' $(( _b / 1048576 )) $(( _b % 1048576 * 10 / 1048576 ))
	elif [ "$_b" -ge 1024 ]; then
		printf '%d.%d KiB\n' $(( _b / 1024 )) $(( _b % 1024 * 10 / 1024 ))
	else
		printf '%d B\n' "$_b"
	fi
}

# ConnectionStatus -> есть ли соединение. 901 = подключено.
conn_up() { [ "$1" = "901" ]; }

# --- ZTE (MF79 и родня): goform-API ------------------------------------------
#
# У ZTE-стиков не Huawei-XML, а /goform/goform_get_cmd_process с JSON-ответом.
# Два обязательных заголовка: Referer на index.html и X-Requested-With - без
# них прошивка отвечает {"result":"failure"} (проверено сообществом на MF79U).
# Чтение метрик доступно без логина; операции записи (подключение, ребут) на
# части прошивок требуют сессии - шлём best-effort, отказ безвреден.
_zte_get() {   # $1 - адрес, $2 - список cmd через запятую
	_zg_src=$(_srcip_for "" "$1")
	curl -s --max-time 6 ${_zg_src:+--interface "$_zg_src"} -A "$UA" \
		-H "Referer: http://$1/index.html" \
		-H "X-Requested-With: XMLHttpRequest" \
		"http://$1/goform/goform_get_cmd_process?isTest=false&multi_data=1&cmd=$2" 2>/dev/null
}

_zte_set() {   # $1 - адрес, $2 - тело goformId=...
	_zs_src=$(_srcip_for "" "$1")
	curl -s --max-time 8 ${_zs_src:+--interface "$_zs_src"} -A "$UA" \
		-H "Referer: http://$1/index.html" \
		-H "X-Requested-With: XMLHttpRequest" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "isTest=false&$2" \
		"http://$1/goform/goform_set_cmd_process" 2>/dev/null
}

_zj() { printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null; }

# vid:pid модема по usb-пути (или активного) - для развилки Huawei/ZTE
_vidpid_for() {
	_vf_p="$1"
	[ -n "$_vf_p" ] || _vf_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	uci -q get "$CFG.m_$(echo "$_vf_p" | sed 's/[^A-Za-z0-9]/_/g').vidpid"
}

zte_metrics_json() {
	_p="$1"
	_a=$(_addr_for "$_p") || return 1
	_r=$(_zte_get "$_a" "modem_main_state,ppp_status,network_type,network_provider,network_provider_fullname,signalbar,lte_rsrp,lte_rsrq,lte_rssi,lte_snr,rssi,rscp,ecio,cell_id,lac_code,rmcc,rmnc,hmcc,hmnc,wan_ipaddr,imei,msisdn,sim_imsi,iccid,wa_inner_version")
	# Пустой или отказный ответ - НЕ печатаем бланк (правило то же, что у
	# Huawei-ветки: вызывающий отдаст прошлый снимок).
	case "$_r" in *modem_main_state*|*ppp_status*) ;; *) return 1 ;; esac
	_model="ZTE"
	_ntype=$(_zj "$_r" network_type)
	_op=$(_zj "$_r" network_provider_fullname)
	[ -n "$_op" ] || _op=$(_zj "$_r" network_provider)
	_bars=$(_zj "$_r" signalbar | tr -cd '0-9')
	_pct=""; [ -n "$_bars" ] && _pct=$(( _bars * 20 )) && [ "$_pct" -gt 100 ] && _pct=100
	_rsrp=$(_zj "$_r" lte_rsrp | tr -cd '0-9-')
	_rsrq=$(_zj "$_r" lte_rsrq | tr -cd '0-9.-')
	_sinr=$(_zj "$_r" lte_snr | tr -cd '0-9.-')
	_rssi=$(_zj "$_r" lte_rssi | tr -cd '0-9-')
	[ -n "$_rssi" ] || _rssi=$(_zj "$_r" rssi | tr -cd '0-9-')
	_cid_hex=$(_zj "$_r" cell_id)
	_cid=""; [ -n "$_cid_hex" ] && _cid=$(printf '%d' "0x$_cid_hex" 2>/dev/null)
	_lac=$(_zj "$_r" lac_code)
	_mcc=$(_zj "$_r" rmcc); [ -n "$_mcc" ] || _mcc=$(_zj "$_r" hmcc)
	_mnc=$(_zj "$_r" rmnc); [ -n "$_mnc" ] || _mnc=$(_zj "$_r" hmnc)
	_wanip=$(_zj "$_r" wan_ipaddr)
	_imei=$(_zj "$_r" imei)
	_imsi=$(_zj "$_r" sim_imsi)
	_iccid=$(_zj "$_r" iccid)
	_fw=$(_zj "$_r" wa_inner_version)
	_phone=$(_zj "$_r" msisdn)
	case "$_fw" in MF*) _model="ZTE ${_fw%%V*}" ;; esac
	_pps=$(_zj "$_r" ppp_status)
	_reg=0
	if [ "$_pps" = "ppp_connected" ]; then
		if [ -n "$_mcc" ] && [ "$_mcc" = "$(_zj "$_r" hmcc)" ]; then _reg=1; else _reg=5; fi
		[ -z "$(_zj "$_r" hmcc)" ] && _reg=1
	fi
	_csq=""
	if [ -n "$_rssi" ]; then
		_csq=$(( ( _rssi + 113 ) / 2 ))
		[ "$_csq" -lt 0 ] && _csq=0; [ "$_csq" -gt 31 ] && _csq=31
	fi
	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s",' "$_a"
	printf '"protocol":"HiLink (web API)",'
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s","imsi":"%s","iccid":"%s",' "$_imei" "$_imsi" "$_iccid"
	printf '"firmware":"%s","phone":"%s",' "$(jsafe "$_fw")" "$(jsafe "$_phone")"
	printf '"operator_name":"%s",' "$(jsafe "$_op")"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	printf '"mode":"%s",' "$(jsafe "$_ntype")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"cid_dec":"%s","cid_hex":"%s","lac_hex":"%s",' "$_cid" "$_cid_hex" "$_lac"
	printf '"ipaddr":"%s",' "$_wanip"
	printf '"csq":"%s",' "$_csq"
	printf '"conn_status":"%s"' "$_pps"
	printf '}\n'
}

# --- метрики В НАШЕМ ФОРМАТЕ -------------------------------------------------
#
# Ключи те же, что у 5gmodem.sh: страницы не должны знать, кем добыты данные.
metrics_json() {
	_p="$1"
	# ZTE-стики (MF79 и родня) говорят по goform, а не по Huawei-XML
	case "$(_vidpid_for "$_p")" in 19d2:*) zte_metrics_json "$_p"; return $? ;; esac
	_inf=$(api_get /api/device/information "$_p")
	# Первый запрос - индикатор живости API/сессии (api_get внутри уже обновил
	# сессию и повторил на пустой ответ). Если ВСЁ РАВНО пусто - модем недоступен:
	# НЕ печатаем бланк-JSON (иначе 5gmodem.sh закэшировал бы его поверх хорошего
	# снимка и страница показала бы прочерки) и не тратим время на остальные 4
	# запроса по 6-12 c каждый. Возврат без вывода -> вызывающий отдаст прошлый
	# снимок, как при любом другом сбое json.
	[ -n "$_inf" ] || return 1
	_st=$(api_get /api/monitoring/status "$_p")
	_sig=$(api_get /api/device/signal "$_p")
	_tr=$(api_get /api/monitoring/traffic-statistics "$_p")
	_plmn=$(api_get /api/net/current-plmn "$_p")

	_model=$(printf '%s' "$_inf" | xval DeviceName)
	# API отдаёт только модель ("E3372") без производителя. Дописываем его по
	# VID устройства - в заголовке "Huawei E3372" читается однозначно.
	_vid=$(uci -q get "$CFG.m_$(echo "${_p:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}" \
		| sed 's/[^A-Za-z0-9]/_/g').vidpid" | cut -d: -f1)
	case "$_vid" in
		12d1) _vend="Huawei" ;;
		19d2) _vend="ZTE" ;;
		1bbb) _vend="Alcatel" ;;
		2001) _vend="D-Link" ;;
		*)    _vend="" ;;
	esac
	case "$_model" in
		"$_vend"*|"") ;;
		*) [ -n "$_vend" ] && _model="$_vend $_model" ;;
	esac
	# Пометку класса в САМО ИМЯ не добавляем: имя расходится по вкладкам, кнопкам
	# и карточкам профилей, где она была бы шумом. Класс отдаём отдельным полем
	# (backend), а показываем его только там, где он к месту.
	_imei=$(printf '%s' "$_inf" | xval Imei)
	_imsi=$(printf '%s' "$_inf" | xval Imsi)
	_iccid=$(printf '%s' "$_inf" | xval Iccid)
	_fw=$(printf '%s' "$_inf" | xval SoftwareVersion)
	# Номер SIM у этого API ЕСТЬ - поле Msisdn. Основной путь берёт его из
	# AT+CNUM и кладёт в "phone"; кладём туда же, чтобы страница не различала.
	_phone=$(printf '%s' "$_inf" | xval Msisdn)

	_cs=$(printf '%s' "$_st" | xval ConnectionStatus)
	# «Палочки» лежат то в SignalStrength, то в SignalIcon - зависит от прошивки.
	# На проверенном E3372h (22.300.09) первое ПУСТОЕ, а второе заполнено, из-за
	# чего процент сигнала не считался вовсе. Берём то, что есть.
	_sigbars=$(printf '%s' "$_st" | xval SignalStrength)
	[ -n "$_sigbars" ] || _sigbars=$(printf '%s' "$_st" | xval SignalIcon)
	_maxbars=$(printf '%s' "$_st" | xval maxsignal)
	_ntype=$(printf '%s' "$_st" | xval CurrentNetworkType)
	_wanip=$(printf '%s' "$_st" | xval WanIPAddress)
	_sim=$(printf '%s' "$_st" | xval SimStatus)
	# РОУМИНГ: СОСТОЯНИЕ, А НЕ НАСТРОЙКА.
	#
	# Здесь читался RoamingStatus - и это оказалось поле НЕ ПРО ТО. У Huawei в
	# monitoring/status RoamingStatus - это НАСТРОЙКА «разрешён ли роуминг» (тот
	# самый тумблер из веб-админки), а фактическое состояние лежит в cellroam.
	# Живьём на стенде: RoamingStatus=1 (роуминг разрешён), cellroam=0 (модем
	# дома, Tele2 на симке Tele2) - и страница рисовала значок роуминга при
	# домашней сети.
	_roam=$(printf '%s' "$_st" | xval cellroam)
	# Настройку отдаём отдельным полем - на ней строится тумблер «данные в
	# роуминге» для этого класса модемов.
	_roamset=$(printf '%s' "$_st" | xval RoamingStatus)

	_rsrp=$(printf '%s' "$_sig" | xval rsrp | tr -cd '0-9-')
	_rsrq=$(printf '%s' "$_sig" | xval rsrq | tr -cd '0-9.-')
	_sinr=$(printf '%s' "$_sig" | xval sinr | tr -cd '0-9.-')
	_rssi=$(printf '%s' "$_sig" | xval rssi | tr -cd '0-9-')
	_pci=$(printf '%s' "$_sig" | xval pci)
	# cell_id у этого API - ДЕСЯТИЧНЫЙ. Проверено арифметикой: 93540375 < 2^28,
	# то есть укладывается в 28-битный LTE Cell Identity, а как шестнадцатеричное
	# то же число дало бы 2471756661 - вдвое больше допустимого. Раньше я клал
	# его в cid_hex, и страница, ожидающая пару dec+hex, показывала прочерк.
	_cid=$(printf '%s' "$_sig" | xval cell_id | tr -cd '0-9')
	_cid_hex=""; _enb=""; _sect=""
	if [ -n "$_cid" ]; then
		_cid_hex=$(printf '%X' "$_cid" 2>/dev/null)
		# Разложение LTE ECI: старшие 20 бит - базовая станция, младшие 8 - сектор.
		_enb=$(( _cid >> 8 ))
		_sect=$(( _cid & 255 ))
	fi

	_up=$(printf '%s' "$_tr" | xval CurrentUpload)
	_down=$(printf '%s' "$_tr" | xval CurrentDownload)
	_ctime=$(printf '%s' "$_tr" | xval CurrentConnectTime)

	_op=$(printf '%s' "$_plmn" | xval FullName)
	[ -n "$_op" ] || _op=$(printf '%s' "$_plmn" | xval ShortName)
	_mcc=""; _mnc=""
	_num=$(printf '%s' "$_plmn" | xval Numeric | tr -cd '0-9')
	if [ ${#_num} -ge 5 ]; then _mcc=${_num%${_num#???}}; _mnc=${_num#???}; fi
	# ИМЯ ИЗ НАШЕЙ БАЗЫ, если код сети известен. Прошивки пишут его кто во что
	# горазд ("MegaFon RUS", "MTS RUS"), и рядом с AT-путём, который берёт имя из
	# mccmnc.dat, получался разнобой: в одном месте "Megafon", в другом
	# "MegaFon RUS". База - единый источник написания.
	if [ -n "$_num" ]; then
		# tr -d '\r' ОБЯЗАТЕЛЕН: строки mccmnc.dat в формате CRLF, и возврат
		# каретки попадал ПРЯМО В JSON ("Megafon\r"). jsonfilter такое глотает,
		# а JSON.parse в браузере - нет: обе страницы молча оставались пустыми.
		_dbop=$(awk -F';' -v k="$_num" '$1 == k { print $3 }' "$RES/mccmnc.dat" 2>/dev/null \
			| head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
		[ -n "$_dbop" ] && _op="$_dbop"
	fi
	# Выверенный бренд MVNO из apn.list по IMSI - последним словом. У HiLink нет
	# доступа к SPN, а web-API отдаёт хост-оператора (Tele2); наш список знает,
	# что за кодом 250-62 стоит T-Mobile. Пусто - оставляем имя из web-API/базы.
	_obr=$(opname_brand "$_imsi") && _op="$_obr"

	# Процент сигнала. У этих модемов есть готовые «палочки» (0..maxsignal) -
	# берём их, а не пересчитываем из RSRP: прошивка знает свою антенну лучше.
	# ПО RSSI, а не по «палочкам». Палочек всего пять - шаг 20%, и показания
	# скачут грубо; RSSI даёт непрерывную шкалу. Переводим по той же таблице
	# 3GPP, что и CSQ: -113 dBm = 0%, -51 dBm = 100%.
	_pct=""
	if [ -n "$_rssi" ]; then
		_pct=$(( ( _rssi + 113 ) * 100 / 62 ))
		[ "$_pct" -gt 100 ] && _pct=100
		[ "$_pct" -lt 0 ] && _pct=0
	elif [ -n "$_sigbars" ] && [ -n "$_maxbars" ] && [ "$_maxbars" -gt 0 ] 2>/dev/null; then
		_pct=$(( _sigbars * 100 / _maxbars ))
	elif [ -n "$_rsrp" ]; then
		# Палочек нет ни там, ни там - считаем из RSRP по той же шкале, что и
		# основной путь опроса (-140 дно, -75 потолок), иначе у одного модема
		# процент был бы по одной шкале, у другого по другой.
		_pct=$(( ( _rsrp + 140 ) * 100 / 65 ))
		[ "$_pct" -gt 100 ] && _pct=100
		[ "$_pct" -lt 0 ] && _pct=0
	fi

	# ЗАПОМИНАЕМ модель и IMEI в профиле. У обычных модемов это делает AT-опрос,
	# а у HiLink их взять больше неоткуда: без этого в секции оставались данные
	# ПРЕДЫДУЩЕГО модема на том же USB-пути (наблюдалось: у Huawei значились имя
	# и IMEI от FM350). Пишем только при расхождении - uci не любит лишних правок,
	# а метрики опрашиваются постоянно.
	if [ -n "$_imei" ] || [ -n "$_model" ]; then
		_hsec="m_$(echo "${_p:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}" \
			| sed 's/[^A-Za-z0-9]/_/g')"
		_ch=0
		[ -n "$_model" ] && [ "$(uci -q get "$CFG.$_hsec.model")" != "$_model" ] && {
			uci -q set "$CFG.$_hsec.model=$_model"
			# Штамп железа - см. пояснение в modemswitch.sh (resolve).
			uci -q set "$CFG.$_hsec.model_vp=$(uci -q get "$CFG.$_hsec.vidpid")"; _ch=1; }
		[ -n "$_imei" ] && [ "$(uci -q get "$CFG.$_hsec.imei")" != "$_imei" ] && {
			uci -q set "$CFG.$_hsec.imei=$_imei"; _ch=1; }
		[ "$_ch" = "1" ] && uci -q commit "$CFG"
	fi

	# Регистрация в терминах основного пути: 1 - дома, 5 - роуминг, 0 - нет.
	_reg=0
	if conn_up "$_cs"; then
		[ "$_roam" = "1" ] && _reg=5 || _reg=1
	fi

	printf '{'
	printf '"backend":"hilink",'
	# Поля блока «Информация о модеме»: у обычного модема это AT-порт и протокол
	# интерфейса. У HiLink «порт связи» - это адрес его веб-API, а протокол -
	# сам факт того, что модемом правит его прошивка, а не мы. Без них в блоке
	# стояли прочерки.
	printf '"cport":"%s",' "$(_addr_for "$_p" 2>/dev/null)"
	printf '"protocol":"HiLink (web API)",'
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s",' "$_imei"
	printf '"imsi":"%s",' "$_imsi"
	printf '"iccid":"%s",' "$_iccid"
	printf '"firmware":"%s",' "$(jsafe "$_fw")"
	printf '"phone":"%s",' "$(jsafe "$_phone")"
	printf '"operator_name":"%s",' "$(jsafe "$_op")"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	printf '"allow_roaming":"%s",' "$([ "$_roamset" = "1" ] && echo 1 || echo 0)"
	printf '"mode":"%s",' "$(nettype_name "$_ntype")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"pci":"%s",' "$_pci"
	printf '"cid_dec":"%s","cid_hex":"%s",' "$_cid" "$_cid_hex"
	printf '"enbid":"%s","sector":"%s",' "$_enb" "$_sect"
	printf '"ipaddr":"%s",' "$_wanip"
	# ФОРМАТ КАК У ОСНОВНОГО ПУТИ, иначе страница показывает сырые числа.
	# Он отдаёт conn_time строкой "0d, 00:02:59", conn_time_sec - секундами,
	# а трафик - человекочитаемым "112.9 MiB" (берёт готовую строку у ifconfig).
	# Наблюдалось: у HiLink стояли "3462" и "4254912" - время не читалось, а
	# байты выглядели как случайное число.
	_ct_str="-"
	if [ -n "$_ctime" ] && [ "$_ctime" -ge 0 ] 2>/dev/null; then
		_ct_str=$(printf "%dd, %02d:%02d:%02d" \
			$(( _ctime / 86400 )) $(( _ctime / 3600 % 24 )) \
			$(( _ctime / 60 % 60 )) $(( _ctime % 60 )))
	fi
	printf '"conn_time":"%s","conn_time_sec":"%s",' "$_ct_str" "${_ctime:-0}"
	printf '"rx":"%s","tx":"%s",' "$(_human "$_down")" "$(_human "$_up")"
	# CSQ у API нет, но он однозначно выводится из RSSI по таблице 3GPP 27.007:
	# 0 = -113 dBm, шаг 2 dBm, 31 = -51 dBm. Это пересчёт, а не выдуманное число.
	_csq=""
	if [ -n "$_rssi" ]; then
		_csq=$(( ( _rssi + 113 ) / 2 ))
		[ "$_csq" -lt 0 ] && _csq=0
		[ "$_csq" -gt 31 ] && _csq=31
	fi
	printf '"csq":"%s",' "$_csq"
	printf '"sim_status":"%s","conn_status":"%s"' "$_sim" "$_cs"
	printf '}\n'
}

# --- SMS ---------------------------------------------------------------------
#
# У этих модемов SMS живут в самом модеме и достаются тем же API. Формат вывода
# делаем как у sms_tool -j: страницы разбирают его одинаково независимо от того,
# добыты сообщения по AT или по HTTP. Объект {"msg":[...]}, ключи те же.
# reference/part/total у API нет - многочастные сообщения прошивка склеивает
# сама, поэтому ставим 1/1: для страницы это одно цельное сообщение.
# BoxType: 1 - входящие, 2 - исходящие.
sms_list() {   # $1 - ящик (in|out), $2 - usb-путь
	case "$1" in out) _box=2 ;; *) _box=1 ;; esac
	_r=$(api_post /api/sms/sms-list \
		"<PageIndex>1</PageIndex><ReadCount>50</ReadCount><BoxType>$_box</BoxType>\
<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred>" "$2")
	# Разбор. Две ловушки, обе поймались на живом модеме:
	#   1. Запись выдавать надо по </Message>, а НЕ по <Smstat>: этот тег идёт
	#      ПЕРВЫМ в блоке, и выдача по нему давала пустую первую запись и сдвиг
	#      всех остальных на одну.
	#   2. Текст бывает МНОГОСТРОЧНЫМ (перевод строки внутри SMS - обычное дело),
	#      поэтому Content собираем до закрывающего тега, а не берём одной строкой.
	printf '%s' "$_r" | tr -d '\r' | awk '
		BEGIN { printf "{\"msg\":["; first = 1; inc = 0 }
		function esc(v) {
			gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v)
			gsub(/\t/, " ", v); gsub(/\n/, " ", v)
			return v
		}
		/<Message>/  { idx=""; ph=""; txt=""; dt=""; inc=0 }
		/<Index>/    { v=$0; sub(/.*<Index>/, "", v); sub(/<\/Index>.*/, "", v); idx=v }
		/<Phone>/    { v=$0; sub(/.*<Phone>/, "", v); sub(/<\/Phone>.*/, "", v); ph=v }
		/<Date>/     { v=$0; sub(/.*<Date>/, "", v); sub(/<\/Date>.*/, "", v); dt=v }
		/<Content>/  {
			v=$0; sub(/.*<Content>/, "", v)
			if (v ~ /<\/Content>/) { sub(/<\/Content>.*/, "", v); txt=v }
			else { txt=v; inc=1 }
			next
		}
		inc == 1 {
			if ($0 ~ /<\/Content>/) { v=$0; sub(/<\/Content>.*/, "", v); txt=txt " " v; inc=0 }
			else { txt=txt " " $0 }
			next
		}
		/<\/Message>/ {
			if (idx == "") next
			if (!first) printf ",\n"; first = 0
			printf "{\"index\":%s,\"sender\":\"%s\",\"timestamp\":\"%s\",\"reference\":0,\"part\":1,\"total\":1,\"content\":\"%s\"}", idx, esc(ph), esc(dt), esc(txt)
		}
		END { print "]}" }'
}

sms_send() {   # $1 - номер, $2 - текст, $3 - usb-путь
	_n="$1"; _t="$2"
	[ -n "$_n" ] && [ -n "$_t" ] || { echo '{"error":"no number or text"}'; return 1; }
	_d=$(date '+%Y-%m-%d %H:%M:%S')
	_r=$(api_post /api/sms/send-sms \
		"<Index>-1</Index><Phones><Phone>$_n</Phone></Phones><Sca></Sca>\
<Content>$_t</Content><Length>${#_t}</Length><Reserved>1</Reserved><Date>$_d</Date>" "$3")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

sms_delete() {   # $1 - индекс, $2 - usb-путь
	_r=$(api_post /api/sms/delete-sms "<Index>$1</Index>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

# --- USSD --------------------------------------------------------------------
#
# У этого класса модемов USSD работает через API, а не AT: в /api/global/
# module-switch у проверенного E3372h стоит ussd_enabled=1.
#
# Порядок такой: отправить запрос, дождаться готовности ответа (модем отвечает
# не мгновенно - сеть думает секунды), забрать ответ, закрыть сессию. Без
# закрытия следующий запрос упрётся в «сессия занята».
hl_ussd() {   # $1 - код (*100#), $2 - usb-путь
	_code="$1"
	[ -n "$_code" ] || { echo '{"error":"no code"}'; return 1; }

	# Незакрытая сессия с прошлого раза - закрываем, иначе отправка не пройдёт.
	api_post /api/ussd/release "" "$2" >/dev/null 2>&1

	_r=$(api_post /api/ussd/send \
		"<content>$_code</content><codeType>CodeType</codeType><timeout></timeout>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)"; return 1 ;;
	esac

	# Ждём ответа. Пока он не готов, API отвечает кодом 111019 - это НЕ ошибка,
	# а «ещё обрабатывается». 30 секунд: на живом МегаФоне ответ не пришёл и за
	# это время, так что таймаут тут - штатный исход, а не поломка.
	_n=0
	while [ "$_n" -lt 30 ]; do
		sleep 1
		_g=$(api_get /api/ussd/get "$2")
		_c=$(printf '%s' "$_g" | xval content)
		if [ -n "$_c" ]; then
			api_post /api/ussd/release "" "$2" >/dev/null 2>&1
			# Экранируем то, что сломало бы JSON, и склеиваем строки: ответ
			# оператора бывает многострочным.
			_c=$(printf '%s' "$_c" | tr -d '\r' | tr '\n' ' ' \
				| sed 's/\\/\\\\/g; s/"/\\"/g')
			printf '{"success":true,"content":"%s"}\n' "$_c"
			return 0
		fi
		_n=$(( _n + 1 ))
	done
	api_post /api/ussd/release "" "$2" >/dev/null 2>&1
	echo '{"success":false,"error":"timeout"}'
	return 1
}

# --- диапазоны ---------------------------------------------------------------
#
# Читаются и МЕНЯЮТСЯ через /api/net/net-mode. LTEBand - шестнадцатеричная
# битовая маска: бит 0 = B1, бит 1 = B2 и так далее. Проверено на живом модеме:
# 800C5 = B1, B3, B7, B8, B20 (1 + 4 + 64 + 128 + 524288 = 0x800C5).
#
# Маска 3FFFFFFF в NetworkBand означает «все» - её и ставим, когда пользователь
# снимает ограничение, а не перечисляем диапазоны поимённо.
_mask_to_bands() {   # $1 - hex-маска; печатает номера диапазонов через пробел
	_m=$(printf '%d' "0x$1" 2>/dev/null) || return 1
	_i=0; _out=""
	while [ "$_i" -lt 32 ]; do
		if [ $(( (_m >> _i) & 1 )) -eq 1 ]; then _out="$_out $(( _i + 1 ))"; fi
		_i=$(( _i + 1 ))
	done
	echo "$_out" | xargs
}

_bands_to_mask() {   # $1 - номера через пробел; печатает hex-маску
	_m=0
	for _b in $1; do
		case "$_b" in ''|*[!0-9]*) continue ;; esac
		[ "$_b" -ge 1 ] && [ "$_b" -le 32 ] || continue
		_m=$(( _m | (1 << (_b - 1)) ))
	done
	printf '%X\n' "$_m"
}

hl_getbands() {
	_r=$(api_get /api/net/net-mode "$1")
	_lte=$(printf '%s' "$_r" | xval LTEBand)
	[ -n "$_lte" ] || return 1
	# 3FFFFFFF (и подобные «все биты») - ограничения нет.
	_mask_to_bands "$_lte"
}

hl_setbands() {   # $1 - номера диапазонов или "default", $2 - usb-путь
	_cur=$(api_get /api/net/net-mode "$2")
	_nm=$(printf '%s' "$_cur" | xval NetworkMode)
	[ -n "$_nm" ] || _nm="03"
	if [ "$1" = "default" ] || [ -z "$1" ]; then
		_lte="7FFFFFFFFFFFFFFF"; _nb="3FFFFFFF"
	else
		_lte=$(_bands_to_mask "$1"); _nb="3FFFFFFF"
		[ "$_lte" = "0" ] && return 1
	fi
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_nb</NetworkBand><LTEBand>$_lte</LTEBand>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

# --- ДИАПАЗОНЫ 2G/3G через NetworkBand ---------------------------------------
# NetworkBand - hex-маска 2G/3G-бендов (LTE - отдельно в LTEBand). Биты Huawei НЕ
# последовательны, часть - в расширенном диапазоне (>32 бит). Значения ПРОВЕРЕНЫ
# на живом E3372: net-mode-list дал комбо-маску 2000000400380 (= B1|B8|GSM900|
# GSM1800), рекомбинация сошлась точно; проба NetworkBand=400000 увела модем на 3G
# 2100 (mode=2, HSPA+). ВНИМАНИЕ: B8 - бит 49 (0x2000000000000), а НЕ 0x2000000 из
# «стандартных» таблиц - потому и выверяли на железе.
#
# «БЕЗ ОГРАНИЧЕНИЙ». В Auto прошивка отдаёт NetworkBand=3FFFFFFF (все младшие 30
# бит), но это НЕ включает расширенные биты (B8=49). Трактуем такой mask как «все
# поддерживаемые бенды доступны» - в UI все галочки стоят (интуитивно), а не B8
# внезапно снятый. Реальное ограничение (напр. только B1) 3FFFFFFF никогда не даст.
_hl_nb_all() { [ $(( ($1 & 0x3FFFFFFF) == 0x3FFFFFFF )) -eq 1 ]; }

_umts_bit() {   # WCDMA номер -> hex-бит NetworkBand
	case "$1" in
		1) echo 400000 ;;            # B1 2100 IMT (проверено)
		2) echo 800000 ;;            # B2 1900 PCS
		5) echo 4000000 ;;           # B5 850 CLR
		8) echo 2000000000000 ;;     # B8 900 (расширенный бит 49, проверено)
		*) echo "" ;;
	esac
}
_gsm_bit() {    # GSM частота (МГц) -> hex-бит NetworkBand
	case "$1" in
		900)  echo 300 ;;            # GSM900 (проверено в комбо-маске)
		1800) echo 80 ;;            # GSM1800 (проверено)
		850)  echo 80000 ;;         # GSM850
		1900) echo 200000 ;;        # GSM1900 PCS
		*) echo "" ;;
	esac
}
# Бит бенда данного RAT (2g|3g).
_hl_bandbit() { [ "$1" = 3g ] && _umts_bit "$2" || _gsm_bit "$2"; }

_umts_roman() {   # римская часть WCDMA BC<...> -> номер
	case "$1" in
		I) echo 1 ;; II) echo 2 ;; IV) echo 4 ;; V) echo 5 ;;
		VI) echo 6 ;; VIII) echo 8 ;; *) echo "" ;;
	esac
}

# Поддерживаемые бенды RAT из net-mode-list. 3g -> номера (1 8), 2g -> частоты (900 1800).
hl_supbands3g() {
	api_get /api/net/net-mode-list "$1" 2>/dev/null | grep -oE 'WCDMA BC[IVX]+' | sed 's/WCDMA BC//' \
		| while read -r _rn; do _n=$(_umts_roman "$_rn"); [ -n "$_n" ] && echo "$_n"; done | sort -nu | xargs
}
hl_supbands2g() {
	api_get /api/net/net-mode-list "$1" 2>/dev/null | grep -oE 'GSM[0-9]+' | sed 's/GSM//' | sort -nu | xargs
}

# Комбо-маска ВСЕХ поддерживаемых 2G/3G-бит (BandList, БЕЗ LTE) - число. Модем
# принимает NetworkBand только в пределах набора; строим маску строго из него.
hl_supmask3g() {
	_mm=0
	for _x in $(api_get /api/net/net-mode-list "$1" 2>/dev/null | sed 's/<LTEBandList>.*//' \
			| grep -oE '<Value>[0-9A-Fa-f]+</Value>' | sed 's/<[^>]*>//g'); do
		_mm=$(( _mm | $(printf '%d' "0x$_x") ))
	done
	echo "$_mm"
}

# Биты выбранных бендов RAT ($1=2g|3g, далее номера/частоты).
_hl_ratmask() {
	_rm=0; _rt="$1"; shift
	for _b in "$@"; do
		case "$_b" in ''|*[!0-9]*) continue ;; esac
		_bit=$(_hl_bandbit "$_rt" "$_b"); [ -n "$_bit" ] && _rm=$(( _rm | $(printf '%d' "0x$_bit") ))
	done
	echo "$_rm"
}

# Включённые бенды RAT ($1=2g|3g, $2=путь). «Без ограничений» -> все поддерживаемые.
_hl_getbands() {
	_rt="$1"; _p="$2"
	_nb=$(api_get /api/net/net-mode "$_p" | xval NetworkBand)
	[ -n "$_nb" ] || return 1
	_m=$(printf '%d' "0x$_nb" 2>/dev/null) || return 1
	[ "$_rt" = 3g ] && _sup=$(hl_supbands3g "$_p") || _sup=$(hl_supbands2g "$_p")
	_hl_nb_all "$_m" && { echo $_sup | xargs; return; }
	for _b in $_sup; do
		_bit=$(_hl_bandbit "$_rt" "$_b"); [ -n "$_bit" ] || continue
		[ $(( (_m & $(printf '%d' "0x$_bit")) != 0 )) -eq 1 ] && printf '%s ' "$_b"
	done
	echo ""
}
hl_getbands3g() { _hl_getbands 3g "$1"; }
hl_getbands2g() { _hl_getbands 2g "$1"; }

# Задать бенды RAT: сохраняем биты ДРУГОГО RAT (при «без ограничений» - ВСЕ его
# поддерживаемые, иначе только реально включённые), ставим выбранные ЭТОГО RAT;
# LTEBand/NetworkMode не трогаем. $1=2g|3g, $2=номера|default, $3=путь.
_hl_setbands() {
	_rt="$1"; _selarg="$2"; _p="$3"
	_cur=$(api_get /api/net/net-mode "$_p")
	_nm=$(printf '%s' "$_cur" | xval NetworkMode); [ -n "$_nm" ] || _nm="00"
	_lte=$(printf '%s' "$_cur" | xval LTEBand);    [ -n "$_lte" ] || _lte="7FFFFFFFFFFFFFFF"
	_nb=$(printf '%s' "$_cur" | xval NetworkBand); [ -n "$_nb" ] || _nb="3FFFFFFF"
	_m=$(printf '%d' "0x$_nb")
	[ "$_rt" = 3g ] && _sup=$(hl_supbands3g "$_p") || _sup=$(hl_supbands2g "$_p")
	_allsup=$(hl_supmask3g "$_p")
	_thismask=$(_hl_ratmask "$_rt" $_sup)
	_othermask=$(( _allsup & ~_thismask ))
	if _hl_nb_all "$_m"; then _keep=$_othermask; else _keep=$(( _m & _othermask )); fi
	[ "$_selarg" = "default" ] || [ -z "$_selarg" ] && _sel="$_sup" || _sel="$_selarg"
	_new=$(( _keep | $(_hl_ratmask "$_rt" $_sel) ))
	_newnb=$(printf '%X' "$_new")
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_newnb</NetworkBand><LTEBand>$_lte</LTEBand>" "$_p")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}
hl_setbands3g() { _hl_setbands 3g "$1" "$2"; }
hl_setbands2g() { _hl_setbands 2g "$1" "$2"; }

# Режим сети (Auto/3G/4G) через API - как и диапазоны, НЕ роняет debug, в отличие
# от AT^SYSCFGEX. NetworkMode: 00 авто, 02 только 3G, 03 только 4G.
hl_getmode() {   # $1 - usb-путь; печатает id режима нашего формата (1/8/2/4)
	_nm=$(api_get /api/net/net-mode "$1" | xval NetworkMode)
	case "$_nm" in
		03) echo 4 ;;
		02) echo 2 ;;
		01) echo 8 ;;
		00|"") echo 1 ;;
		*) echo 1 ;;
	esac
}

hl_setmode() {   # $1 - id (1/8/2/4), $2 - usb-путь
	case "$1" in
		1) _nm="00" ;;
		8) _nm="01" ;;
		2) _nm="02" ;;
		4) _nm="03" ;;
		*) echo '{"error":"bad mode"}'; return 1 ;;
	esac
	# Диапазоны сохраняем как есть - меняем только тип сети.
	_cur=$(api_get /api/net/net-mode "$2")
	_nb=$(printf '%s' "$_cur" | xval NetworkBand); [ -n "$_nb" ] || _nb="3FFFFFFF"
	_lte=$(printf '%s' "$_cur" | xval LTEBand); [ -n "$_lte" ] || _lte="7FFFFFFFFFFFFFFF"
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_nb</NetworkBand><LTEBand>$_lte</LTEBand>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

# --- команды -----------------------------------------------------------------

case "$1" in
	# Есть ли у этого модема веб-API (и отвечает ли он).
	probe)
		_a=$(_addr_for "$2") || { echo '{"hilink":0}'; exit 0; }
		_r=$(api_get /api/device/basic_information "$2")
		case "$_r" in
			*'<classify>'*) printf '{"hilink":1,"addr":"%s","classify":"%s"}\n' \
				"$_a" "$(printf '%s' "$_r" | xval classify)" ; exit 0 ;;
		esac
		# не Huawei - вдруг ZTE goform (MF79 и родня)
		_r=$(_zte_get "$_a" modem_main_state)
		case "$_r" in
			*modem_main_state*) printf '{"hilink":1,"addr":"%s","classify":"zte"}\n' "$_a" ;;
			*) printf '{"hilink":0,"addr":"%s"}\n' "$_a" ;;
		esac
		;;
	json|metrics) metrics_json "$2" ;;
	addr)        _addr_for "$2" ;;
	get)         api_get "$2" "$3" ;;
	# Подключить/отключить передачу данных. У ZTE - goform, best-effort
	# (часть прошивок требует веб-логина; отказ безвреден).
	connect)
		case "$(_vidpid_for "$2")" in
			19d2:*) _a=$(_addr_for "$2") && _zte_set "$_a" "goformId=CONNECT_NETWORK" >/dev/null ;;
			*) api_post /api/dialup/mobile-dataswitch "<dataswitch>1</dataswitch>" "$2" ;;
		esac ;;
	disconnect)
		case "$(_vidpid_for "$2")" in
			19d2:*) _a=$(_addr_for "$2") && _zte_set "$_a" "goformId=DISCONNECT_NETWORK" >/dev/null ;;
			*) api_post /api/dialup/mobile-dataswitch "<dataswitch>0</dataswitch>" "$2" ;;
		esac ;;
	reboot)
		case "$(_vidpid_for "$2")" in
			19d2:*) _a=$(_addr_for "$2") && _zte_set "$_a" "goformId=REBOOT_DEVICE" >/dev/null ;;
			*) api_post /api/device/control "<Control>1</Control>" "$2" ;;
		esac ;;
	# Переключить композицию USB.
	#
	# ЗАЧЕМ. Часть HiLink-модемов умеет отдавать последовательные AT-порты - в
	# их админке это называется debug mode. После переключения модем перестаёт
	# быть «только веб-интерфейс» и становится обычным: появляются TAC, диапазон,
	# EARFCN, USSD и AT-консоль, то есть всё, чего у веб-API нет.
	# Проверено на E3372: 12d1:14dc -> 12d1:1566, шесть портов за 10 секунд.
	#
	# АВТОМАТИЧЕСКИ ЭТОГО НЕ ДЕЛАЕМ: смена композиции меняет поведение модема и
	# может отключить его веб-интерфейс. Решение за пользователем.
	mode)
		case "$2" in
			debug|1) _m=1 ;;
			normal|0) _m=0 ;;
			*) echo '{"error":"mode must be debug or normal"}'; exit 0 ;;
		esac
		_r=$(api_post /api/device/mode "<mode>$_m</mode>" "$3")
		case "$_r" in
			*'<response>OK</response>'*) printf '{"success":true,"mode":"%s"}\n' "$2" ;;
			*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
		esac
		;;
	smsread)     sms_list "${2:-in}" "$3" ;;
	smscount)    api_get /api/sms/sms-count "$2" ;;
	smssend)     sms_send "$2" "$3" "$4" ;;
	smsdel)      sms_delete "$2" "$3" ;;
	ussd)        hl_ussd "$2" "$3" ;;
	getbands)    hl_getbands "$2" ;;
	setbands)    hl_setbands "$2" "$3" ;;
	getbands3g)  hl_getbands3g "$2" ;;
	setbands3g)  hl_setbands3g "$2" "$3" ;;
	supbands3g)  hl_supbands3g "$2" ;;
	getbands2g)  hl_getbands2g "$2" ;;
	setbands2g)  hl_setbands2g "$2" "$3" ;;
	supbands2g)  hl_supbands2g "$2" ;;
	getmode)     hl_getmode "$2" ;;
	setmode)     hl_setmode "$2" "$3" ;;
	getroaming)  hl_getroaming "$2" ;;
	setroaming)  hl_setroaming "$2" "$3" ;;
	*)
		echo "usage: hilink.sh {probe|json|addr|get <ep>|connect|disconnect|reboot} [usb-path]" >&2
		exit 1
		;;
esac
exit 0
