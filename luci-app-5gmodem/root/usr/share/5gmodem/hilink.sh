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
	_r=$(curl -s --max-time 6 --interface "$_d" -A "$UA" \
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
	_out=$(curl -s --max-time 6 --interface "$_d" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		"http://$_a$_ep" 2>/dev/null)
	case "$_out" in
		*'<code>125002</code>'*|*'<code>125003</code>'*|*'<code>125001</code>'*)
			_s=$(_sess_new "$_a" "$_d") || return 1
			_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
			_out=$(curl -s --max-time 6 --interface "$_d" -A "$UA" \
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
	curl -s --max-time 10 --interface "$_d" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>$_body</request>" \
		"http://$_a$_ep" 2>/dev/null
}

# Значение одного тега из ответа. XML у этих прошивок - тег на строку.
# tr -d '\r' ОБЯЗАТЕЛЕН: прошивка отдаёт CRLF, и без него якорь $ не совпадал -
# все поля молча выходили пустыми, хотя ответ приходил правильный.
xval() { tr -d '\r' | sed -n "s|^<$1>\(.*\)</$1>\$|\1|p" | head -1; }

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

# ConnectionStatus -> есть ли соединение. 901 = подключено.
conn_up() { [ "$1" = "901" ]; }

# --- метрики В НАШЕМ ФОРМАТЕ -------------------------------------------------
#
# Ключи те же, что у 5gmodem.sh: страницы не должны знать, кем добыты данные.
metrics_json() {
	_p="$1"
	_inf=$(api_get /api/device/information "$_p")
	_st=$(api_get /api/monitoring/status "$_p")
	_sig=$(api_get /api/device/signal "$_p")
	_tr=$(api_get /api/monitoring/traffic-statistics "$_p")
	_plmn=$(api_get /api/net/current-plmn "$_p")

	_model=$(printf '%s' "$_inf" | xval DeviceName)
	_imei=$(printf '%s' "$_inf" | xval Imei)
	_imsi=$(printf '%s' "$_inf" | xval Imsi)
	_iccid=$(printf '%s' "$_inf" | xval Iccid)
	_fw=$(printf '%s' "$_inf" | xval SoftwareVersion)

	_cs=$(printf '%s' "$_st" | xval ConnectionStatus)
	_sigbars=$(printf '%s' "$_st" | xval SignalStrength)
	_maxbars=$(printf '%s' "$_st" | xval maxsignal)
	_ntype=$(printf '%s' "$_st" | xval CurrentNetworkType)
	_wanip=$(printf '%s' "$_st" | xval WanIPAddress)
	_sim=$(printf '%s' "$_st" | xval SimStatus)
	_roam=$(printf '%s' "$_st" | xval RoamingStatus)

	_rsrp=$(printf '%s' "$_sig" | xval rsrp | tr -cd '0-9-')
	_rsrq=$(printf '%s' "$_sig" | xval rsrq | tr -cd '0-9.-')
	_sinr=$(printf '%s' "$_sig" | xval sinr | tr -cd '0-9.-')
	_rssi=$(printf '%s' "$_sig" | xval rssi | tr -cd '0-9-')
	_pci=$(printf '%s' "$_sig" | xval pci)
	_cid=$(printf '%s' "$_sig" | xval cell_id)

	_up=$(printf '%s' "$_tr" | xval CurrentUpload)
	_down=$(printf '%s' "$_tr" | xval CurrentDownload)
	_ctime=$(printf '%s' "$_tr" | xval CurrentConnectTime)

	_op=$(printf '%s' "$_plmn" | xval FullName)
	[ -n "$_op" ] || _op=$(printf '%s' "$_plmn" | xval ShortName)
	_mcc=""; _mnc=""
	_num=$(printf '%s' "$_plmn" | xval Numeric | tr -cd '0-9')
	if [ ${#_num} -ge 5 ]; then _mcc=${_num%${_num#???}}; _mnc=${_num#???}; fi

	# Процент сигнала. У этих модемов есть готовые «палочки» (0..maxsignal) -
	# берём их, а не пересчитываем из RSRP: прошивка знает свою антенну лучше.
	_pct=""
	if [ -n "$_sigbars" ] && [ -n "$_maxbars" ] && [ "$_maxbars" -gt 0 ] 2>/dev/null; then
		_pct=$(( _sigbars * 100 / _maxbars ))
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
			uci -q set "$CFG.$_hsec.model=$_model"; _ch=1; }
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
	printf '"modem":"%s",' "$_model"
	printf '"imei":"%s",' "$_imei"
	printf '"imsi":"%s",' "$_imsi"
	printf '"iccid":"%s",' "$_iccid"
	printf '"firmware":"%s",' "$_fw"
	printf '"operator_name":"%s",' "$_op"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	printf '"mode":"%s",' "$(nettype_name "$_ntype")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"pci":"%s","cid_hex":"%s",' "$_pci" "$_cid"
	printf '"ipaddr":"%s",' "$_wanip"
	printf '"conn_time":"%s","rx":"%s","tx":"%s",' "$_ctime" "$_down" "$_up"
	printf '"sim_status":"%s","conn_status":"%s"' "$_sim" "$_cs"
	printf '}\n'
}

# --- SMS ---------------------------------------------------------------------
#
# У этих модемов SMS живут в самом модеме и достаются тем же API. Формат вывода
# делаем как у sms_tool -j: страницы разбирают его одинаково независимо от того,
# добыты сообщения по AT или по HTTP.
# BoxType: 1 - входящие, 2 - исходящие.
sms_list() {   # $1 - ящик (in|out), $2 - usb-путь
	case "$1" in out) _box=2 ;; *) _box=1 ;; esac
	_r=$(api_post /api/sms/sms-list \
		"<PageIndex>1</PageIndex><ReadCount>50</ReadCount><BoxType>$_box</BoxType>\
<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred>" "$2")
	# Разбираем построчно: у прошивки один тег на строку, вложенность плоская.
	printf '%s' "$_r" | tr -d '\r' | awk '
		BEGIN { printf "["; first = 1 }
		/<Index>/    { gsub(/.*<Index>|<\/Index>.*/, ""); idx = $0 }
		/<Phone>/    { gsub(/.*<Phone>|<\/Phone>.*/, ""); ph = $0 }
		/<Content>/  { gsub(/.*<Content>|<\/Content>.*/, ""); txt = $0 }
		/<Date>/     { gsub(/.*<Date>|<\/Date>.*/, ""); dt = $0 }
		/<Smstat>/   {
			gsub(/.*<Smstat>|<\/Smstat>.*/, ""); st = $0
			# экранируем то, что сломало бы JSON
			gsub(/\\/, "\\\\", txt); gsub(/"/, "\\\"", txt)
			gsub(/\t/, " ", txt)
			if (!first) printf ",\n"; first = 0
			printf "{\"index\":\"%s\",\"sender\":\"%s\",\"timestamp\":\"%s\",\"unread\":\"%s\",\"content\":\"%s\"}", idx, ph, dt, st, txt
			idx=""; ph=""; txt=""; dt=""
		}
		END { print "]" }'
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

# --- команды -----------------------------------------------------------------

case "$1" in
	# Есть ли у этого модема веб-API (и отвечает ли он).
	probe)
		_a=$(_addr_for "$2") || { echo '{"hilink":0}'; exit 0; }
		_r=$(api_get /api/device/basic_information "$2")
		case "$_r" in
			*'<classify>'*) printf '{"hilink":1,"addr":"%s","classify":"%s"}\n' \
				"$_a" "$(printf '%s' "$_r" | xval classify)" ;;
			*) printf '{"hilink":0,"addr":"%s"}\n' "$_a" ;;
		esac
		;;
	json|metrics) metrics_json "$2" ;;
	addr)        _addr_for "$2" ;;
	get)         api_get "$2" "$3" ;;
	# Подключить/отключить передачу данных.
	connect)     api_post /api/dialup/mobile-dataswitch "<dataswitch>1</dataswitch>" "$2" ;;
	disconnect)  api_post /api/dialup/mobile-dataswitch "<dataswitch>0</dataswitch>" "$2" ;;
	reboot)      api_post /api/device/control "<Control>1</Control>" "$2" ;;
	smsread)     sms_list "${2:-in}" "$3" ;;
	smscount)    api_get /api/sms/sms-count "$2" ;;
	smssend)     sms_send "$2" "$3" "$4" ;;
	smsdel)      sms_delete "$2" "$3" ;;
	*)
		echo "usage: hilink.sh {probe|json|addr|get <ep>|connect|disconnect|reboot} [usb-path]" >&2
		exit 1
		;;
esac
exit 0
