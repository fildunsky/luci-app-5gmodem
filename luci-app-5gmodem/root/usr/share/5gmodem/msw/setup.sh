# Полная настройка одного модема (autosetup).
#
# Часть modemswitch.sh (см. его шапку): сорсится им, самостоятельно НЕ
# запускается. Все функции перенесены 1:1 при распиле большого файла.

setup_one_modem() {
	P="$1"
	# HiLink-модем ведём ОСОБО: интернет у него всегда через собственную сетевую
	# карту (интерфейс DHCP), а AT-порты - лишь источник метрик/SMS/USSD, когда
	# модем в debug. Сначала пробуем открыть порты, затем ВСЕГДА создаём/подхватываем
	# DHCP-интерфейс. Обычный путь (mkiface) создал бы второй, лишний интерфейс.
	if is_hilink "$P"; then
		uci -q set "$CFG.$(secname "$P").kind=hilink"
		uci -q commit "$CFG"
		# СНАЧАЛА поднимаем DHCP-интерфейс, ПОТОМ переключаем в debug.
		# Порядок критичен: web-API модема (192.168.43.1) доступен ТОЛЬКО когда на
		# его сетевой карте (eth3) есть IP из его подсети - _sess_new/_addr_for
		# биндят curl на этот адрес. Раньше try_at_debug звался ПЕРВЫМ: на свежем
		# подключении eth3 ещё без адреса, сессия к web-API не бралась, mode debug
		# молча проваливался, и модем оставался в HiLink без AT-портов и метрик
		# (issue #2: "часто не переключается в debug сам").
		_hnet=$(hilink_netdev "$P")
		[ -n "$_hnet" ] && setup_hilink "$P" "$_hnet" >/dev/null
		# Теперь связь с модемом есть - переключаем в debug. try_at_debug сам ждёт
		# готовности web-API (в т.ч. получения DHCP-аренды на eth3). После
		# переэнумерации 14dc->1566 сетевая карта та же (eth3), но интерфейс
		# переподхватываем, чтобы аренда восстановилась без задержки.
		if try_at_debug "$P"; then
			rm -f /tmp/5gmodem_listmodems.cache /tmp/5gmodem_listmodems.stamp 2>/dev/null
			_hnet=$(hilink_netdev "$P")
			[ -n "$_hnet" ] && setup_hilink "$P" "$_hnet" >/dev/null
		fi
		# ЗАКРЕПИТЬ AT-ПОРТ, если модем в debug (есть AT-порты) - ВСЕГДА, а не
		# только когда переключили сейчас: модем мог быть в debug уже (кнопка
		# «Отладка» на нём же). Без этого 5gmodem.sh видит «kind=hilink и at_port
		# пуст» и читает метрики по web-API - страница показывает «HiLink», хотя
		# AT-порты есть. resolve назначил бы порт, но autosetup выходит раньше него.
		# at_for_path вернёт пусто для чистого HiLink (портов нет) - тогда не трогаем.
		_dbg_at=$(at_for_path "$P")
		if [ -n "$_dbg_at" ]; then
			uci -q set "$CFG.$(secname "$P").at_port=$_dbg_at"
			[ "$P" = "$(active_path)" ] && uci -q set "$CFG.@5gmodem[0].at_port=$_dbg_at"
			uci -q commit "$CFG"
		fi
		"$RES/ensureports.sh" >/dev/null 2>&1
		return 0
	fi

	SEC=$(ensure_section "$P")

	# АКТИВНОСТЬ НЕ ОТБИРАЕМ. Свежевоткнутый модем настраиваем, но активным
	# делаем только если действующего активного нет или он пропал с шины:
	# иначе установка второго модема молча переключала бы на него и рабочую
	# страницу первого, и глобальные порты sms_tool_js.
	_am=$(active_path)
	if [ -z "$_am" ] || ! "$RES/listmodems.sh" 2>/dev/null | grep -qF "\"path\":\"$_am\""; then
		uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	fi
	A=$(at_for_path "$P")
	[ -n "$A" ] && {
		uci -q set "$CFG.$SEC.at_port=$A"
		# Глобальный порт принадлежит АКТИВНОМУ модему: перезаписав его при
		# настройке второго, мы увели бы метрики и SMS на чужой порт.
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].at_port=$A"
	}
	uci -q commit "$CFG"

	# ЗАПРОШЕННЫЙ proto (кнопка «переключиться в XMM» в блоке бендов): ставим ИМЕННО
	# его, а НЕ подхватываем существующий и не гадаем по драйверу. После смены
	# USB-композиции (GTUSBMODE=0 + ребут) autosetup иначе поставил бы драйверный
	# fibocom, и xmm не поднялся бы. Маркер одноразовый - снимаем сразу.
	_wp=$(uci -q get "$CFG.$SEC.want_proto")
	if [ -n "$_wp" ]; then
		uci -q delete "$CFG.$SEC.want_proto"; uci -q commit "$CFG"
		MODEM_PATH="$P" "$RES/mkiface.sh" "$(uci -q get "$CFG.$SEC.network")" "$_wp" >/dev/null 2>&1
		_made=$(uci -q get "$CFG.$SEC.network")
		# КЛЮЧЕВОЕ для xmm: метрики уводим на AT-порт, ОТЛИЧНЫЙ от dial-порта. xmm
		# держит dial-порт (ttyACM0) под данные (M-RAW_IP), и AT-проба на нём рвёт
		# сессию - интерфейс флапает. at_for_path теперь исключает dial-порт xmm/atc
		# и возвращает другой (у L850/L860 - ttyACM2).
		_mp=$(at_for_path "$P")
		if [ -n "$_mp" ]; then
			uci -q set "$CFG.$SEC.at_port=$_mp"
			[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].at_port=$_mp"
		fi
		uci -q commit "$CFG"
		"$RES/ensureports.sh" >/dev/null 2>&1
		[ -n "$_made" ] && { ubus call network reload >/dev/null 2>&1; ifup "$_made" >/dev/null 2>&1; }
		logger -t 5gmodem "autosetup: $P -> want_proto=$_wp port=${_mp:-?} -> ${_made:-fail}"
		# APN подбираем в фоне (autoapn верно берёт оператора: T-Mobile -> "tt").
		[ -n "$_made" ] && ( "$RES/modemswitch.sh" autoapn "$_made" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
		return 0
	fi

	# СНАЧАЛА ПОДХВАТ. Если интерфейс для этого модема уже существует - берём
	# его себе, а не создаём второй. Так пакет, установленный на роутер с уже
	# настроенным модемом, просто начинает им управлять.
	# ПОДХВАТ ПО ЖЕЛЕЗУ (IMEI) - первым. Интерфейс мог быть СОХРАНЁН за этим
	# модемом при вытеснении из порта (swap_cleanup больше его не сносит) либо
	# модем переехал в другой разъём. В обоих случаях поднимаем ЕГО ЖЕ интерфейс,
	# а не плодим новый (раньше от одного модема копились modem/modem2/modem3).
	_ex=$(iface_for_imei "$(imei_for_path "$P")")
	# Затем прежний признак - по USB-пути (старые конфиги без штампа IMEI).
	[ -n "$_ex" ] || _ex=$(iface_for_path "$P")
	# ...но путь-фолбэк может указать на интерфейс, СОХРАНЁННЫЙ за ДРУГИМ железом:
	# его модем вытеснили из этого же разъёма, штамп пути на нём остался наш, а
	# modem_stale мы теперь не ставим (в том и смысл - интерфейс ждёт возвращения).
	# Без этой проверки новый модем забрал бы чужой интерфейс вместе с чужим прото
	# и настройками - ровно то наследование, от которого штампы и заводились.
	if [ -n "$_ex" ] && ! iface_owned_by "$_ex" "$P" "$(imei_for_path "$P")"; then
		logger -t 5gmodem "autosetup: $_ex is owned by another modem - not adopting, will create our own"
		_ex=""
	fi
	# Интерфейс, помеченный swap_cleanup как устаревший, НЕ подхватываем: его
	# настройки относятся к прежнему модему на этом же USB-разъёме. Пропускаем
	# подхват - ниже mkiface пересоздаст интерфейс с нуля под текущий модем.
	if [ -n "$_ex" ] && [ "$(uci -q get "network.$_ex.modem_stale")" = "1" ]; then
		logger -t 5gmodem "autosetup: $_ex marked stale - recreating"
		_ex=""
	fi
	if [ -n "$_ex" ]; then
		uci -q set "$CFG.$SEC.network=$_ex"
		[ "$(active_path)" = "$P" ] && uci -q set "$CFG.@5gmodem[0].network=$_ex"
		# Модем вернулся: снимаем «спящее» auto=0, выставленное при вытеснении, и
		# переставляем штамп пути на ТЕКУЩИЙ разъём (IMEI остаётся прежним).
		uci -q delete "network.$_ex.auto" 2>/dev/null
		stamp_iface_owner "$_ex" "$P"
		# reload нужен, только если у интерфейса меняется существенное для netifd
		# (proto/device) или netifd секцию вовсе не знает - сравниваем до/после.
		_fp_was="$(uci -q get "network.$_ex.proto")|$(uci -q get "network.$_ex.device")"
		fix_iface_proto "$_ex"
		# ПОДТЯГИВАЕМ ТОЛЬКО УЖЕ СДЕЛАННЫЙ ВЫБОР, А НЕ СОЗДАЁМ ЕГО.
		# Здесь стояло безусловное `iface_proto=<текущий proto интерфейса>` - и
		# любой прото, выставленный АВТОМАТИКОЙ (запасной путь mm-inhibit,
		# правка fix_iface_proto), при следующем же hotplug превращался в
		# «выбор пользователя». Дальше ветка auto в mkiface читала его первым и
		# больше никогда не применяла ни детект по драйверу, ни вендорные
		# исключения: модем, который обязан идти под ModemManager (413c:81e0,
		# 05c6:90d5), намертво застревал на qmi. Тот же инвариант уже соблюдён в
		# modemswitch.sh - переписываем только kernel-пару, и только если выбор
		# в секции уже есть.
		_pr=$(uci -q get "network.$_ex.proto")
		case "$(uci -q get "$CFG.$SEC.iface_proto")" in
			mbim|qmi)
				case "$_pr" in
					mbim|qmi) uci -q set "$CFG.$SEC.iface_proto=$_pr" ;;
				esac
				;;
		esac
		uci -q commit "$CFG"
		"$RES/ensureports.sh" >/dev/null 2>&1
		# ПОДНЯТЬ ИНТЕРФЕЙС СРАЗУ. Мы только что сняли «спящее» auto=0, но netifd
		# конфиг сам не перечитывает - без побудки интерфейс так и лежал, пока его
		# через минуту не дёргал ifdown/ifup фонового autoapn (живой случай
		# 31.07.2026: возврат Telit на место SIMCOM = 3-4 минуты без IP, из них
		# первая - мёртвое ожидание).
		#
		# ГЛОБАЛЬНЫЙ reload - ТОЛЬКО КОГДА БЕЗ НЕГО НЕЛЬЗЯ. netifd на reload
		# перезапускает КАЖДЫЙ интерфейс, чей uci отличается от загруженного, -
		# у соседей копится «конфиг-долг» (метрики приоритетов пишутся без
		# reload намеренно), и вставка нового модема роняла работающий соседний
		# (живой случай 31.07.2026: Telit воткнули - FM350 передёрнулся на 6 с).
		# Подхваченную секцию netifd уже знает: обычно хватает чистого ifup.
		_fp_now="$(uci -q get "network.$_ex.proto")|$(uci -q get "network.$_ex.device")"
		if [ "$_fp_was" != "$_fp_now" ] \
		   || ! ubus -S call "network.interface.$_ex" status >/dev/null 2>&1; then
			ubus call network reload >/dev/null 2>&1
		fi
		ifup "$_ex" >/dev/null 2>&1
		logger -t 5gmodem "autosetup: $P -> adopted existing $_ex"
		# APN проверяем И ДЛЯ ПОДХВАЧЕННОГО интерфейса. Раньше подбор вызывался
		# только при создании нового, и унаследованный интерфейс навсегда
		# оставался с APN прежней симки - именно так Beeline работал с "tt".
		( "$RES/modemswitch.sh" autoapn "$_ex" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
		return 0
	fi

	# ИМЯ ИНТЕРФЕЙСА ВЫБИРАЕТ mkiface, а не мы. У него для этого есть готовая и
	# более правильная логика: имя закрепляется ЗА СЕКЦИЕЙ МОДЕМА и увеличивается
	# только если занято ДРУГИМ модемом - так два модема гарантированно не делят
	# один интерфейс. Я сперва подбирал имя сам, проверяя network.<имя> в конфиге
	# сети, - это другой вопрос: осиротевший интерфейс от снятого модема выглядел
	# занятым, и в журнал уходило одно имя, а создавалось другое.
	# proto=auto: mkiface определит его по драйверу управляющего узла - надёжнее,
	# чем гадать по vid:pid, и не создаёт нерабочий qmi поверх MBIM.
	# MODEM_PATH: mkiface по умолчанию берёт АКТИВНЫЙ модем, а мы можем настраивать
	# и неактивный. С этой переменной он работает с нужным и не трогает глобальные
	# ключи чужого модема (см. пояснение в mkiface.sh).
	MODEM_PATH="$P" "$RES/mkiface.sh" "" auto >/dev/null 2>&1
	"$RES/ensureports.sh" >/dev/null 2>&1
	# В журнал пишем то, что получилось НА САМОМ ДЕЛЕ.
	_made=$(uci -q get "$CFG.$SEC.network")
	logger -t 5gmodem "autosetup: $P -> ${_made:-failed}"
	# Прежние интерфейсы этого же модема больше не нужны - см. drop_stale_ifaces.
	[ -n "$_made" ] && drop_stale_ifaces "$P" "$_made"
	# APN подбираем В ФОНЕ: команда ждёт до минуты, а hotplug столько держать
	# нельзя. Дескрипторы отвязываем на подоболочке - иначе вызвавший нас
	# процесс будет ждать EOF.
	[ -n "$_made" ] && ( "$RES/modemswitch.sh" autoapn "$_made" ) >/dev/null 2>&1 </dev/null 8>&- 9>&- &
}
