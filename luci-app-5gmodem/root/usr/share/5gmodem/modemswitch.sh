#!/bin/sh
#
# Multi-modem control. A modem is identified by its stable USB topology PATH
# (e.g. "1-1.3"), so it survives reboots and is unique even for two identical
# VID:PID modems. This script makes one modem "active" - the app then reads
# metrics / SMS / USSD from that modem's ports and interface.
#
# Storage in the 5gmodem config:
#   5gmodem.@5gmodem[0].active_modem = <usb path>
#   config modem 'm_<path>'  { path, product, at_port, network, iface_proto }
# The per-modem section remembers each modem's chosen AT port and interface, so
# switching back and forth restores its settings.
#
# Usage:
#   modemswitch.sh active            - print the active USB path
#   modemswitch.sh switch <path>     - make <path> active (detect ports, apply)
#   modemswitch.sh save <path>       - persist the current working config into
#                                      the given modem's section (before switch)
#

RES=/usr/share/5gmodem
CFG=5gmodem

[ -r "$RES/quirks.sh" ] && . "$RES/quirks.sh"

. /usr/share/5gmodem/lib.sh   # secname / sec_for_iface / active_path
. /usr/share/5gmodem/atlock.sh   # at_lock/at_unlock - чтение IMEI не должно
                                 # сталкиваться с опросом метрик в том же порту

active_path() { uci -q get "$CFG.@5gmodem[0].active_modem"; }

# ОДНА ЗАПИСЬ РЕЕСТРА НА МОДЕМ ВМЕСТО ТРЁХ РАЗБОРОВ listmodems.
#
# Порты, дескриптор и vidpid спрашивались тремя отдельными вызовами, каждый со
# своим разбором JSON. Ответ на все три - одна запись реестра, и она вдобавок
# сверяет сохранённый at_port со списком портов ЭТОГО модема (см. registry.sh).
#
# МЕМО САМОИНВАЛИДИРУЕТСЯ ПО ШТАМПУ listmodems, а не живёт до конца процесса.
# Это не украшение: modemswitch ЖДЁТ появления портов после смены режима
# (try_at_debug, setup_one_modem) и в цикле сбрасывает кэш перечисления. Мемо,
# привязанное к процессу, в таком цикле навсегда отдавало бы «портов нет» - то
# есть ровно тот класс ошибки, от которого мы уходим. Штамп меняется при любом
# пересборе перечисления, включая ручное удаление файла кэша.
# Запись одна (не таблица): циклы обрабатывают модемы по одному, и все три поля
# читаются подряд у одного и того же пути.
_RR_STAMP=""
_RR_PATH1=""; _RR_REC1=""
_RR_PATH2=""; _RR_REC2=""
_reg_rec() {   # $1 - usb-путь
	[ -n "$1" ] || return 0
	_rr_s=$(cat /tmp/5gmodem_listmodems.stamp 2>/dev/null)
	# Штамп сменился - вся память недействительна.
	if [ "$_rr_s" != "$_RR_STAMP" ]; then
		_RR_STAMP="$_rr_s"; _RR_PATH1=""; _RR_REC1=""; _RR_PATH2=""; _RR_REC2=""
	fi
	[ "$1" = "$_RR_PATH1" ] && [ -n "$_RR_REC1" ] && { printf '%s' "$_RR_REC1"; return 0; }
	[ "$1" = "$_RR_PATH2" ] && [ -n "$_RR_REC2" ] && { printf '%s' "$_RR_REC2"; return 0; }
	# ДВЕ ЗАПИСИ, А НЕ ОДНА. Переключение вкладки работает РОВНО с двумя модемами -
	# старым и новым (save_to старого, потом ensure_section нового), и на одной
	# ячейке они вытесняли друг друга: каждый вызов заново платил за реестр.
	# Вторая ячейка убирает это без всякой сложности; больше двух не нужно, циклы
	# по всем модемам идут по одному пути за итерацию.
	_RR_PATH2="$_RR_PATH1"; _RR_REC2="$_RR_REC1"
	_RR_PATH1="$1"; _RR_REC1=$("$RES/registry.sh" path "$1" 2>/dev/null)
	printf '%s' "$_RR_REC1"
}

# ports (tty) of the modem at a given usb path
modem_ttys() {
	_reg_rec "$1" | jsonfilter -e '@.tty[*]' 2>/dev/null
}
modem_product() {
	_reg_rec "$1" | jsonfilter -e '@.product' 2>/dev/null | head -1
}
modem_vidpid() {
	_reg_rec "$1" | jsonfilter -e '@.vidpid' 2>/dev/null | head -1
}

# --- ТЕМАТИЧЕСКИЕ БИБЛИОТЕКИ ------------------------------------------------
#
# Файл был 2500 строк с 25 вербами и сорока функциями вперемешку - функции
# разъехались по темам в msw/ (распил из docs/AUDIT-2026-07-30.md, раздел 4.1).
# Это ЧИСТЫЙ перенос: тела не менялись, всё сорсится в один шелл до исполнения
# вербов, поэтому перекрёстные вызовы работают как раньше. Диспетчер вербов и
# мелкие общие помощники (_reg_rec, at_probe, detect_at, mm_index_for_path)
# остались здесь.
. "$RES/msw/identity.sh"
. "$RES/msw/iface.sh"
. "$RES/msw/apn.sh"
. "$RES/msw/hilink.sh"
. "$RES/msw/setup.sh"




# AT probe of ONE port, time-bounded to ~4s. sms_tool has no timeout option and
# blocks ~35s on a silent DIAG port with no reply, which made switching modems
# take half a minute (the UI "Switching…" spinner hung). Run it in the
# background and kill it if it does not answer quickly.
at_probe() {
	# 8>&- 9>&- обязательны: вызывающий может держать at_lock (fd 8) и замок
	# хотплага (fd 9) - фоновый sms_tool унаследовал бы их OFD и держал локи
	# дольше владельца (ревью, баг №6; тот же класс, что в atprobe.sh/lib.sh).
	sms_tool -d "$1" at "AT" >/dev/null 2>&1 8>&- 9>&- &
	_p=$!
	_n=0
	while kill -0 "$_p" 2>/dev/null; do
		_n=$((_n + 1))
		if [ "$_n" -ge 4 ]; then
			kill "$_p" 2>/dev/null
			sleep 1
			# D-state (вис в драйвере tty): сигналы не доходят, wait висел бы
			# вечно и rpcd падал по 30с - XHR error на странице (T99W175
			# 05c6:9025 с немыми портами, 17.08.2026). Бросаем сироту: ядро
			# дореапит его само, когда драйвер отпустит I/O.
			kill -0 "$_p" 2>/dev/null && return 1
			wait "$_p" 2>/dev/null
			return 1
		fi
		sleep 1
	done
	wait "$_p" 2>/dev/null   # sms_tool exit code: 0 when the port answered AT
	return $?
}

# first tty that answers "AT" = the modem's AT port
detect_at() {
	for t in "$@"; do
		[ -e "$t" ] || continue
		case "$t" in /dev/ttyUSB*|/dev/ttyACM*) ;; *) continue ;; esac
		if at_probe "$t"; then echo "$t"; return 0; fi
	done
	return 1
}

# ModemManager modem index whose USB device path matches a usb topology path
mm_index_for_path() {
	[ -n "$1" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	for m in $(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | grep -oE '[0-9]+$'); do
		d=$(mmcli -m "$m" -K 2>/dev/null | sed -n 's/^modem\.generic\.device *: *//p' | xargs)
		case "$d" in */"$1") echo "$m"; return 0 ;; esac
	done
	return 1
}

# cdc-wdm control node of the modem at a usb path
wdm_for_path() {
	_reg_rec "$1" | jsonfilter -e '@.wdm[0]' 2>/dev/null
}

# ОБРАТНОЕ к wdm_for_path: чьё это устройство (USB-путь модема) сейчас. Считаем по
# sysfs (не по кэшу listmodems): поднимаемся от cdc-wdm-узла к usb_device (idVendor)
# и берём basename пути (1-1.3). Пусто - узла нет или это не USB.
path_for_wdm() {
	local d
	d=$(readlink -f "/sys/class/usbmisc/$(basename "${1:-x}")/device" 2>/dev/null)
	while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -f "$d/idVendor" ]; do d=$(dirname "$d"); done
	[ -f "$d/idVendor" ] && basename "$d"
}





# AT port of the modem at a usb path: fast via ModemManager, else probe its ttys
at_for_path() {
	mi=$(mm_index_for_path "$1")
	if [ -n "$mi" ]; then
		p=$(mmcli -m "$mi" 2>/dev/null | grep -oE '(ttyUSB[0-9]+|ttyACM[0-9]+) \(at\)' | sed 's/ (at)//' | head -1)
		[ -n "$p" ] && [ -e "/dev/$p" ] && { echo "/dev/$p"; return 0; }
	fi
	# xmm/atc держат СВОЙ порт (device) под ДАННЫЕ (M-RAW_IP): AT-проба на нём
	# рвёт data-сессию, и интерфейс флапает. Метрики должны идти по ДРУГОМУ AT-порту,
	# поэтому dial-порт таких прото исключаем из перебора (у L850/L860 остаётся
	# ttyACM2). Для прочих прото (mbim/qmi/…) данные идут не по tty - исключать нечего.
	# Мемоизация на процесс: resolve зовёт at_for_path до 6 раз подряд для ОДНОГО
	# пути (ретраи ожидания порта), а dial-порт прото за это время не меняется -
	# пересчитывать iface_for_path + 2×uci get на каждый ретрай незачем.
	if [ "$_AFP_SKIP_P" = "$1" ]; then
		_afp_skip="$_AFP_SKIP_V"
	else
		_afp_skip=""
		_afp_if=$(iface_for_path "$1")
		if [ -n "$_afp_if" ]; then
			case "$(uci -q get "network.$_afp_if.proto")" in
				xmm|atc) _afp_skip=$(uci -q get "network.$_afp_if.device") ;;
			esac
		fi
		_AFP_SKIP_P="$1"
		_AFP_SKIP_V="$_afp_skip"
	fi
	# ИЗВЕСТНЫЙ AT-ПОРТ ПРОБУЕМ ПЕРВЫМ.
	#
	# Перебор идёт пробой AT с потолком 4 c на порт (см. at_probe), а у модема их
	# бывает семь - то есть до полуминуты на молчащих DIAG-портах. Реестр отдаёт
	# сохранённый at_port УЖЕ сверенным со списком портов этого модема (устаревшую
	# настройку он гасит сам), поэтому поставить его в начало и дёшево, и
	# безопасно: если он не ответит, перебор пойдёт как раньше. Раньше здесь
	# сохранённый порт не учитывался вовсе, и каждый вызов начинал с нуля.
	_afp_at=$(_reg_rec "$1" | jsonfilter -e '@.at_port' 2>/dev/null)
	_afp_list=""
	[ -n "$_afp_at" ] && [ "$_afp_at" != "$_afp_skip" ] && _afp_list="$_afp_at"
	for _afp_t in $(modem_ttys "$1"); do
		[ "$_afp_t" = "$_afp_skip" ] && continue
		[ "$_afp_t" = "$_afp_at" ] && continue
		_afp_list="$_afp_list $_afp_t"
	done
	detect_at $_afp_list
}














# snapshot the current AT port into a modem section. NOTE: we deliberately do
# NOT copy 'network'/'iface_proto' here - those belong to the interface and are
# owned by mkiface.sh (which assigns a UNIQUE interface per modem). Copying the
# working 'network' here used to propagate a shared "modem" into every modem's
# section, so two modems ended up on one interface (shared IP).
save_to() {
	# ИМЯ СЕКЦИИ - ЧИСТАЯ ФУНКЦИЯ ОТ ПУТИ, РАЗБОР ЛИЧНОСТИ ЗДЕСЬ НЕ НУЖЕН.
	#
	# Здесь стоял ensure_section - ради одного лишь имени секции. А он делает
	# полный разбор личности модема: запрос реестра, swap_cleanup, штамп serial,
	# чтение IMEI, два обхода конфига в sec_by_serial/sec_by_imei. Замер
	# переключения вкладки (профиль внутри switch): 640 мс из 1260 уходило РОВНО
	# сюда - на модем, который мы ПОКИДАЕМ и про который всё давно известно.
	#
	# save_to зовётся из switch для АКТИВНОГО модема: его секция существует по
	# определению (он активен - значит был настроен). Страховка на случай
	# рассинхрона оставлена: нет секции - идём длинным путём, как раньше.
	SEC=$(secname "$1")
	uci -q get "$CFG.$SEC" >/dev/null 2>&1 || SEC=$(ensure_section "$1")
	uci -q set "$CFG.$SEC.at_port=$(uci -q get "$CFG.@5gmodem[0].at_port")"
	uci -q commit "$CFG"
}


# Настроить ОДИН модем по usb-пути. Вынесено из autosetup ради цикла по всем
# найденным: тело одинаковое, разница только в том, чей это модем.
# Это HiLink-модем (управляется своим IP-стеком, интерфейс DHCP)? Свойство
# ЖЕЛЕЗА, а не текущей композиции: в режиме debug у него появляются AT-порты, но
# интернет он всё равно держит сам. Смотрим на запомненный kind ИЛИ на наличие
# сетевой карты - НЕ на отсутствие портов.
# Известные HiLink-модемы - ПОШТУЧНО, по vid:pid.
#
# Эвристики тут были ошибкой. Сначала признаком считалась сетевая карта, но она
# есть и у обычного модема: qmi_wwan создаёт wwan0. Telit LM960 (1bc7:1040)
# из-за этого объявлялся HiLink и переставал настраиваться вовсе - подпись
# "(Debug)", настройка через несуществующий веб-API, модем "не определяется".
# Цена ошибки несимметрична: лишний модем в списке ломает ему всю настройку, а
# недостающий - всего лишь не даст автопереключения в debug.
#
# 12d1:14dc - Huawei E3372 в режиме "только веб-интерфейс". В 12d1:1566 он уже
# с AT-портами, и там срабатывает запомненный kind из секции.
# Проверенные HiLink-композиции. Список НЕ исчерпывающий: у Huawei их много и
# ребренды операторов (МТС 8211F, Мегафон) добавляют свои - остальные ловит
# структурный признак в is_hilink (сетевая карта без AT-порта и cdc-wdm).
# 1f01 сюда НЕ входит намеренно: это режим CD-ROM до usb_modeswitch, сети у него
# ещё нет.
HILINK_IDS="12d1:14dc 12d1:14db"








# Как определилась eSIM у профиля - ДЛЯ ПОКАЗА В КАРТОЧКЕ. Читаем только УЖЕ
# ГОТОВЫЕ данные: uci (ручное переопределение) и кэш автоопределения. В порт не
# ходим ни при каких условиях - список профилей рисуется на каждом открытии
# страницы, и проба CCHO по каждому модему стоила бы секунд.
#   yes/no       - определили сами;
#   forced-yes/no - пользователь переопределил;
#   ""            - ещё не проверяли.
_esim_state() {   # $1 - секция, $2 - USB-путь
	_ee=$(uci -q get "$CFG.$1.esim_show")
	case "$_ee" in
		1) echo "forced-yes"; return ;;
		0) echo "forced-no";  return ;;
	esac
	_ec="/tmp/5gmodem_esimstat_$2"
	[ -s "$_ec" ] || return 0
	if grep -q '"available":1' "$_ec" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

case "$1" in
active)
	active_path
	;;

# Поддерживает ли АКТИВНЫЙ модем USSD. Отвечает по базе проверенных модемов
# (quirks.sh), сам модем не трогает: запрос к data-only модулю как раз и
# подвешивает порт на минуту - ровно то, от чего мы хотим избавить пользователя.
#   {"supported":0} - проверено, что не работает
#   {"supported":1} - про этот модем ничего плохого не знаем (не гарантия)
# Записать опции sms_tool_js СРАЗУ в конфиг (set + commit), в обход стейджинга.
#
# Страницы SMS пишут служебные значения сами: счётчик сообщений, порт при смене
# модема, автовключение склейки. Если делать это через uci.set/uci.save в
# браузере, правка ложится в СЕССИОННЫЙ стейджинг LuCI и наверху появляется
# «непринятые изменения» с кнопкой «Применить» - при том, что пользователь
# ничего не настраивал, а просто открыл вкладку и пришло новое сообщение.
# Пишем только известные ключи: команда доступна из веб-интерфейса.
#
# Usage: modemswitch.sh smsopt key=value [key=value ...]
smsopt)
	shift
	_ch=0
	for _kv in "$@"; do
		_k=${_kv%%=*}; _v=${_kv#*=}
		case "$_k" in
			sms_count|sms_count_index|readport|sendport|ussdport|atport|\
			information|mergesms|mergesms_auto|storage) ;;
			*) continue ;;
		esac
		_cur=$(uci -q get "5gmodem.sms.$_k")
		[ "$_cur" = "$_v" ] && continue
		uci -q set "5gmodem.sms.$_k=$_v"
		_ch=1
	done
	[ "$_ch" = 1 ] && uci -q commit 5gmodem
	printf '{"changed":%s}\n' "$_ch"
	;;

# Спрятать подсказку о формате номера на вкладке «Исходящие» (кнопка «Закрыть»).
# Пишем и КОММИТИМ здесь, а не через uci.set/uci.save в браузере: тот кладёт
# правку в сессионный стейджинг LuCI, и наверху появляется «непринятые
# изменения», которые пользователь должен применять руками. Для нажатия
# «Закрыть» это неуместно - человек закрыл подсказку, а не менял настройки сети.
# Пользователь увидел предупреждение о перестановке модемов - снимаем метку,
# чтобы оно не повторялось на каждом заходе. Решение (пересоздавать интерфейс
# или нет) остаётся за ним.
ackswap)
	[ -n "$2" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q delete "$CFG.$2.imei_changed" 2>/dev/null
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;

hidenumberhint)
	uci -q set "5gmodem.sms.information=0"
	uci -q commit 5gmodem
	echo '{"result":"ok"}'
	;;

ussdsupport)
	_p=$(active_path)
	_s=$(secname "$_p")
	# Модем без AT-порта: USSD - услуга AT-канала, отправлять её некуда.
	# Отвечаем ДО опроса базы: иначе страница предлагала бы то, чего нет.
	_us_at=$(uci -q get "$CFG.$_s.at_port")
	if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
	   && ! { [ -n "$_us_at" ] && [ -c "$_us_at" ]; }; then
		printf '{"supported":0,"reason":"no_at_port","model":"%s"}\n' \
			"$(uci -q get "$CFG.$_s.model")"
		exit 0
	fi
	_v=""
	command -v ussd_supported_for >/dev/null 2>&1 && _v=$(ussd_supported_for \
		"$(uci -q get "$CFG.$_s.model")" "$(uci -q get "$CFG.$_s.vidpid")")

	# ВТОРАЯ ПРИЧИНА, ПОМИМО ПРОШИВКИ: РЕГИСТРАЦИЯ «ТОЛЬКО SMS».
	#
	# База выше отвечает на вопрос «умеет ли модем» - это свойство железа и
	# прошивки, оно не меняется. Но USSD может не работать и у вполне
	# способного модема: это услуга голосового домена, и если сеть
	# зарегистрировала абонента как "SMS only", канала для неё нет.
	# Наблюдалось живьём на MeigLink SLM770A-R: AT+CUSD=? отвечает "(0-2)",
	# то есть поддержка заявлена, а любой запрос молчит - при AT+CREG? = 2,6.
	#
	# Коды CREG/CGREG (3GPP 27.007): 1 - дома, 5 - роуминг (оба нормальные),
	# 6 - "SMS only" дома, 7 - "SMS only" в роуминге. Шестёрка и семёрка и
	# означают отсутствие голосового домена.
	#
	# Читаем СНИМОК, а не лезем в порт: страница может открываться при занятом
	# порту, и ещё один опрос ради подсказки - плохой обмен.
	# Берём registration_cs - статус ГОЛОСОВОГО домена. Поле registration для
	# этого не годится: там "SMS only" НАМЕРЕННО подменён статусом данных,
	# чтобы не пугать пользователя при живом интернете (см. 5gmodem.sh).
	_snap=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_reg=$(printf '%s' "$_snap" | jsonfilter -e '@.registration_cs' 2>/dev/null)
	_smsonly=0
	case "$_reg" in
		6|7) _smsonly=1 ;;
	esac

	# ТРЕТЬЯ ПРИЧИНА: модем умеет, сеть даёт, но модем СЕЙЧАС в LTE/5G.
	# USSD - услуга канала CS, в LTE её нет, и модем идёт на CSFB: уходит в 3G,
	# делает транзакцию, возвращается. Замерено на живом Telit LM960 (МегаФон):
	# CSFB занял 30 с, по дороге регистрация слетала в "denied" и "searching", а
	# ответ пришёл в виде `+CUSD: 4` - «operation not supported». То есть ждать
	# дольше нечего, это отказ, а не таймаут. Тот же код в 3G (AT+WS46=22)
	# отдаёт баланс за несколько секунд. Поэтому предупреждаем ДО отправки:
	# запрос не только не сработает, но и на полминуты оставит без сети.
	_rat=$(printf '%s' "$_snap" | jsonfilter -e '@.mode' 2>/dev/null)

	printf '{"supported":%s,"sms_only":%s,"registration":"%s","rat":"%s","model":"%s"}\n' \
		"${_v:-1}" "$_smsonly" "$_reg" "$_rat" "$(uci -q get "$CFG.$_s.model")"
	;;

save)
	[ -n "$2" ] || { echo '{"error":"no path"}'; exit 1; }
	save_to "$2"
	echo '{"result":"saved"}'
	;;

switch)
	note_foreign_uci network "modemswitch switch"
	P="$2"
	# АКТИВНЫМ МОЖНО СДЕЛАТЬ ТОЛЬКО МОДЕМ.
	#
	# Ветка пишет путь и в active_modem, и в preferred_modem, а preferred потом
	# УДЕРЖИВАЕТ активность за собой (см. resolve ниже). Если туда попадёт
	# устройство, которое модемом не является, программа пришпиливается к нему
	# намертво: метрик нет, вкладки для него тоже нет (в списке модемов его нет),
	# а resolve активность не переиграет - об исчезновении не-модема наш
	# hotplug-обработчик даже не узнаёт. Живой случай 03.08.2026: телефон в режиме
	# USB-модема сделали активным, выдернули - страница залипла на пустой карточке,
	# и переключиться назад было нечем.
	# ЗАПРЕТ ОТКАЗЫВАЕТ ТОЛЬКО ПО ФАКТУ, А НЕ ПО МОЛЧАНИЮ.
	#
	# Пустой список - это НЕ «такого модема нет»: listmodems мог сорваться,
	# сбрасывать кэш посреди hotplug-бури или ответить пусто на секунду
	# переэнумерации. Отказывать в такой момент значило бы запереть человека без
	# возможности переключиться вообще - ровно та беда, от которой мы тут
	# защищаемся. Поэтому судим, только когда список НЕПУСТ.
	_sw_list=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null)
	if [ -n "$P" ] && [ -n "$_sw_list" ] && ! printf '%s\n' "$_sw_list" | grep -qxF "$P"; then
		logger -t 5gmodem "switch: \"$P\" is not a modem (not in the list) - not making it active"
		printf '{"error":"not a modem","path":"%s"}\n' "$P"
		exit 0
	fi
	[ -n "$P" ] || { echo '{"error":"no path"}'; exit 1; }

	# remember the currently-active modem's settings first (if any)
	CUR=$(active_path)
	[ -n "$CUR" ] && [ "$CUR" != "$P" ] && save_to "$CUR"

	SEC=$(ensure_section "$P")

	# AT port: prefer the port already saved for THIS modem when it is still
	# valid (present AND still one of this modem's own ports). ttyUSB numbers
	# only change on re-enumeration (unplug / reboot), which the resolve hotplug
	# fixes - so a plain tab switch needs no slow AT re-probe. Fall back to a
	# full detect only when the saved port is gone or now belongs elsewhere.
	SAVED=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$SAVED" ] && [ -e "$SAVED" ] && modem_ttys "$P" | grep -qxF "$SAVED"; then
		ATP="$SAVED"
	else
		ATP=$(at_for_path "$P")
	fi

	# apply to the working config. detect.sh (and thus 5gmodem.sh) resolves the
	# modem port from 5gmodem.device FIRST - so we pin BOTH device and at_port
	# to this modem's AT port, otherwise detect.sh falls through to
	# "mmcli -m any" and reads a different modem.
	# ИНВАРИАНТ: active_modem, at_port/device и network в @5gmodem[0] обязаны
	# описывать ОДИН И ТОТ ЖЕ модем. Раньше at_port обновлялся только при непустом
	# $ATP, а active_modem/network - всегда: если порт нового модема в этот момент
	# не разрешался (он как раз переэнумерируется после CFUN=1,1 / загрузки), то
	# at_port ОСТАВАЛСЯ от ПРЕДЫДУЩЕГО модема. Секция описывала два разных модема,
	# и все потребители at_port (основной опрос, netpri, sms_tool) читали ЧУЖОЙ:
	# оператор соседа попадал в кэш этого интерфейса - отсюда «Beeline у обоих».
	# Пустой at_port безопаснее чужого: его потребители трактуют как «порта нет»,
	# а resolve/hotplug проставит верный, когда модем вернётся на шину.
	uci -q set "$CFG.@5gmodem[0].active_modem=$P"
	# Явный выбор пользователя: resolve вернёт активность сюда, когда модем
	# переживёт переперечисление USB (напр. после AT+CFUN=1,1) - см. ветку resolve.
	uci -q set "$CFG.@5gmodem[0].preferred_modem=$P"

	# Снимок метрик теперь ПО МОДЕМУ (5gmodem.sh: файл назван путём модема).
	# Переключение НЕ трогает кэш: новый модем читает СВОЙ снимок - у него он
	# либо свежий (опрашивали недавно), либо отсутствует и будет опрошен. Чужого
	# не прочитаешь, инвалидация не нужна.
	if [ -n "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
	else
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi
	# Тот же инвариант, что и для at_port: network обязан описывать АКТИВНЫЙ модем.
	# У свежевоткнутого модема интерфейса ещё нет - и раньше network оставался от
	# ПРЕДЫДУЩЕГО модема. Основной опрос читает IP/статистику именно по network,
	# поэтому в карточке нового модема показывался IP соседа. Пусто честнее чужого:
	# метрики просто не покажут IP, пока интерфейс не создан.
	NET=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$NET" ]; then
		# Интерфейс мог достаться от другого модема - сверяем proto с драйвером.
		fix_iface_proto "$NET"
		# И подтягиваем запись модема под РЕАЛЬНЫЙ proto интерфейса: иначе в
		# секции останется прежнее значение, глобальный ключ унаследует его, и
		# настройки покажут "QMI" там, где интерфейс уже работает по MBIM.
		# Переписываем только kernel-протоколы - выбор пользователя не трогаем.
		_np=$(uci -q get "network.$NET.proto")
		case "$(uci -q get "$CFG.$SEC.iface_proto")" in
			mbim|qmi)
				case "$_np" in
					mbim|qmi) uci -q set "$CFG.$SEC.iface_proto=$_np" ;;
				esac
				;;
		esac
		uci -q set "$CFG.@5gmodem[0].network=$NET"
	else
		uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
	fi
	# Как и network выше: пусто честнее чужого. Раньше значение только
	# копировалось при непустом - и у модема, которому протокол ещё не назначен,
	# в глобальной секции оставался протокол ПРЕДЫДУЩЕГО модема. В настройках
	# это выглядело так, будто программа спутала модемы: у Compal значился
	# "Fibocom (AT-dial, FM350)".
	PRO=$(uci -q get "$CFG.$SEC.iface_proto")
	if [ -n "$PRO" ]; then
		uci -q set "$CFG.@5gmodem[0].iface_proto=$PRO"
	else
		uci -q delete "$CFG.@5gmodem[0].iface_proto" 2>/dev/null
	fi
	uci -q commit "$CFG"

	# SMS/USSD ports follow the AT port
	if [ -n "$ATP" ] && uci -q get 5gmodem.sms >/dev/null 2>&1; then
		for k in readport sendport ussdport atport; do
			uci -q set "5gmodem.sms.$k=$ATP"
		done
		apply_ussd_quirk "$SEC"
		uci -q commit 5gmodem
		set_sms_storage "$ATP"
	elif [ -z "$ATP" ] && uci -q get 5gmodem.sms >/dev/null 2>&1; then
		# У модема НЕТ AT-порта (HiLink). Раньше порты просто оставались от
		# предыдущего модема - и страница SMS показывала ЕГО сообщения, выдавая
		# их за сообщения выбранного модема. Чужая переписка под чужим именем
		# хуже пустого экрана, поэтому чистим.
		for k in readport sendport ussdport atport; do
			uci -q delete "5gmodem.sms.$k" 2>/dev/null
		done
		uci -q commit 5gmodem
	fi

	# drop the cached AT port so detect.sh re-resolves for the new modem
	rm -f /tmp/modem

	# PRE-WARM. Страница после переключения тянет метрики,
	# слоты, диапазоны и оператора - у НОВОГО модема их кэши холодные, и первое
	# открытие платит за полный опрос (~5 c). Прогреваем их В ФОНЕ, детачем: на
	# ответ switch не влияет, а к моменту перезагрузки вьюхи кэши уже тёплые и
	# страница открывается из них (~1 c). Порт один - at_lock сериализует прогрев
	# между собой и с опросом страницы, гонки нет. Последовательно, а не парал-
	# лельно: всё равно упираемся в один порт, а так меньше толкотни на локе.
	# Греем ТОЛЬКО слоты и диапазоны: они кэшируются надёжно и живут до действия
	# пользователя, поэтому веер страницы после переключения упрётся лишь в опрос
	# метрик. Метрики НЕ греем - снимок протухает за секунды (cached 4), да и
	# cached-путь под чужим локом вернул бы "busy" вместо опроса; оператора тоже
	# нет - netpri-проба ходит по ВСЕМ интерфейсам, дороже пользы. Страница добьёт
	# их сама одним опросом.
	#
	# setsid ОБЯЗАТЕЛЕН: своя сессия даёт прогреву пережить выход switch (иначе
	# SIGHUP при закрытии сессии rpcd/ssh убивал его на середине). Перед стартом
	# УБИВАЕМ предыдущий прогрев по ГРУППЕ (kill -- -PID; setsid-потомок - лидер
	# группы): частые переключения иначе копят фоновые опросы, и они душат порт
	# (наблюдалось: несколько прогревов разом -> опрос метрик 20+ c).
	# Три гонки прежней схемы (ревью, баг №5): pid писал РЕБЁНОК (два быстрых
	# переключения читали пустой файл), завершающийся старый прогрев rm-ил уже
	# НОВЫЙ pid-файл, а kill по протухшему pid мог попасть в чужую группу.
	# Теперь: pid пишет РОДИТЕЛЬ сразу ($! = setsid-лидер группы), убийство -
	# только если группа жива И это наш прогрев (маркер в cmdline), уборку
	# файла делает ребёнок ТОЛЬКО если файл всё ещё про него.
	_pw=/tmp/5gmodem_prewarm.pid
	_pwold=$(cat "$_pw" 2>/dev/null)
	case "$_pwold" in *[!0-9]*|'') ;; *)
		if kill -0 "$_pwold" 2>/dev/null \
		   && grep -q 5gmodem_prewarm "/proc/$_pwold/cmdline" 2>/dev/null; then
			kill -- "-$_pwold" 2>/dev/null
		fi ;;
	esac
	setsid sh -c '
	  # 5gmodem_prewarm - маркер для проверки перед kill
	  /usr/share/5gmodem/simslot.sh status >/dev/null 2>&1
	  /usr/share/5gmodem/bands.sh   json   >/dev/null 2>&1
	  [ "$(cat /tmp/5gmodem_prewarm.pid 2>/dev/null)" = "$$" ] && rm -f /tmp/5gmodem_prewarm.pid
	' 5gmodem_prewarm >/dev/null 2>&1 </dev/null &
	echo $! > "$_pw" 

	printf '{"result":"ok","path":"%s","at_port":"%s","network":"%s"}\n' "$P" "$ATP" "$NET"
	;;

# ПОДБОР APN, если связь не поднялась сама.
#
# Порядок именно такой: сперва пробуем подняться БЕЗ APN (у многих операторов
# так и работает), и только если адреса нет - читаем оператора и подставляем APN
# из таблицы. Наоборот нельзя: чтобы узнать оператора, модем должен
# зарегистрироваться в сети, а до регистрации мы не знаем, чей APN ставить.
#
# Рабочую настройку НЕ ТРОГАЕМ никогда: есть адрес - выходим сразу.
# Какой APN мы бы подставили - БЕЗ каких-либо изменений. Нужен интерфейсу
# настроек: раньше он считал APN сам, своей копией таблицы в JavaScript, знавшей
# только имена операторов. Для MVNO это давало APN хост-сети (Т-Мобайл -> Tele2),
# и значение прыгало между заходами на страницу.
# Список профилей модемов - всё, что программа когда-либо видела.
#
# Секции 5gmodem.m_* переживают отключение модема НАМЕРЕННО: в них настройки
# (порт, интерфейс, протокол, привязка соты, IMEI). Но до сих пор их не было
# ВИДНО, и это стоило дорого: секция вынутого Telit продолжала claim'ить имя
# интерфейса, из-за чего Compal подхватил чужой proto=qmi к своему MBIM-железу и
# не поднимался; в 5gtop висели три вкладки при одном модеме. Всё это
# пользователь находил глазами, а не интерфейсом.
#
# Здесь только ЧТЕНИЕ. Отдаём JSON-массив.
# Создать DHCP-интерфейс для модема без портов (кнопка в карточке профиля).
mkhilink)
	note_foreign_uci network "modemswitch mkhilink"
	note_foreign_uci firewall "modemswitch mkhilink"
	_p="$2"
	[ -n "$_p" ] || _p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	# Кнопку показывают ТОЛЬКО для модема, уже опознанного как HiLink
	# (kind=hilink или наш whitelist vid:pid), поэтому строгий автодетект
	# hilink_net здесь не годится: он падает, если модем сейчас в AT-debug и
	# засветил tty. Авторитет - is_hilink; карту берём по USB-пути.
	is_hilink "$_p" || { echo '{"error":"not a hilink modem"}'; exit 0; }
	_d=$(hilink_netdev "$_p") || { echo '{"error":"no network card"}'; exit 0; }
	_r=$(setup_hilink "$_p" "$_d")
	printf '{"success":true,"iface":"%s","netdev":"%s"}\n' "$_r" "$_d"
	exit 0
	;;

profiles)
	_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
	_act=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	# ОДИН ДАМП КОНФИГА НА ВЕСЬ ГЛАГОЛ. По нему берутся и список секций, и
	# перечень занятых интерфейсов: подсчёт «сколько профилей делят интерфейс»
	# делался отдельным `uci show | grep -c` НА КАЖДУЮ секцию, то есть по два
	# процесса на карточку.
	_dump=$(uci -q show "$CFG" 2>/dev/null)
	_ifaces=" $(printf '%s\n' "$_dump" | sed -n "s/^$CFG\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | tr '\n' ' ') "
	printf '['
	_first=1
	_bf=""
	# Перечисляем секции по ЗАГОЛОВКУ (=modem), а не по ключу path: секцию мог
	# создать path-less писатель, и по .path её было не найти - модем «пропадал».
	for _sec in $(printf '%s\n' "$_dump" | sed -n 's/^'"$CFG"'\.\(m_[^.]*\)=modem$/\1/p'); do
		# Холдинг-секции припаркованных профилей (m_park_<imei>) - не модемы, у
		# них намеренно нет пути; карточкой их показывать нельзя.
		case "$_sec" in m_park_*) continue ;; esac
		# СНИМОК ОДНОЙ СЕКЦИИ: её четырнадцать ключей ниже читаются подстановками
		# оболочки (0.8 мс), а не четырнадцатью запусками uci (3 мс каждый).
		_ss=$(uci_sec_snap "$CFG" "$_sec")
		_pg() { uci_sec_val "$_ss" "$CFG.$_sec" "$1"; }
		[ "$(_pg parked)" = "1" ] && continue
		_p=$(_pg path)
		# BACKFILL пути для уже сломанных секций: имя однозначно кодирует путь
		# (m_1_1_3 -> 1-1.3: первый разделитель - дефис шины, дальше точки хаба).
		# Закрепляем, чтобы и остальные циклы по m_* снова видели модем.
		if [ -z "$_p" ]; then
			_p=$(echo "${_sec#m_}" | sed 's/_/-/;s/_/./g')
			[ -n "$_p" ] && { uci -q set "$CFG.$_sec.path=$_p"; _bf=1; }
		fi
		[ -n "$_p" ] || continue
		_if=$(_pg network)
		_proto=""; _apn=""; _pdp=""
		if [ -n "$_if" ]; then
			_ns=$(uci_sec_snap network "$_if")
			_proto=$(uci_sec_val "$_ns" "network.$_if" proto)
			_apn=$(uci_sec_val "$_ns" "network.$_if" apn)
			_pdp=$(uci_sec_val "$_ns" "network.$_if" pdptype)
		fi
		# Протокол, запомненный в секции, если интерфейса ещё нет.
		[ -n "$_proto" ] || _proto=$(_pg iface_proto)
		_on=0
		case " $_present " in *" $_p "*) _on=1 ;; esac
		# Интерфейс делят несколько профилей - это ровно та беда, что была с
		# Telit и Compal. Помечаем, чтобы удаление не срезало чужое.
		_shared=0
		if [ -n "$_if" ]; then
			# Только секции m_* : глобальный @5gmodem[0].network - это
			# указатель на активный интерфейс, а не второй владелец (список
			# _ifaces собран ровно по ним, одним дампом выше).
			_n=0
			for _x in $_ifaces; do
				[ "$_x" = "$_if" ] && _n=$((_n + 1))
			done
			[ "$_n" -gt 1 ] && _shared=1
		fi
		[ "$_first" = 1 ] || printf ','
		_first=0
		_kind=$(_pg kind)
		printf '{"sec":"%s","path":"%s","model":"%s","imei":"%s","iface":"%s","proto":"%s","apn":"%s","pdptype":"%s","present":%d,"active":%d,"iface_shared":%d,"celllock":"%s","mm_exclude":"%s","vidpid":"%s","kind":"%s","netdev":"%s","webaddr":"%s","esim":"%s","save_band":"%s","save_band5gnsa":"%s","save_band5gsa":"%s"}' \
			"$_sec" "$_p" \
			"$(_pg model)" \
			"$(_pg imei)" \
			"$_if" "$_proto" "$_apn" "$_pdp" "$_on" \
			"$([ "$_p" = "$_act" ] && echo 1 || echo 0)" "$_shared" \
			"$(_pg celllock)" \
			"$(_pg mm_exclude)" \
			"$(_pg vidpid)" \
			"$_kind" \
			"$(_pg netdev)" \
			"$([ "$_kind" = "hilink" ] && "$RES/hilink.sh" addr "$_p" 2>/dev/null)" \
			"$(_esim_state "$_sec" "$_p")" \
			"$(_pg save_band)" \
			"$(_pg save_band5gnsa)" \
			"$(_pg save_band5gsa)"
	done
	printf ']\n'
	[ -n "$_bf" ] && uci -q commit "$CFG"
	exit 0
	;;
# Удалить профиль ЦЕЛИКОМ - и секцию, и её сетевой интерфейс.
#
# Интерфейс убираем вместе с секцией сознательно: осиротевший интерфейс от
# вынутого модема - не безобидный мусор. Именно такой (от Telit) дрался с Compal
# за /dev/cdc-wdm0 и мешал ему подняться.
# ИСКЛЮЧЕНИЕ: если тем же интерфейсом пользуется другой профиль, интерфейс НЕ
# трогаем - иначе удаление одного модема оборвало бы связь у другого.
delprofile)
	note_foreign_uci network "modemswitch delprofile"
	_sec="$2"
	[ -n "$_sec" ] || { echo '{"error":"no section"}'; exit 0; }
	uci -q get "$CFG.$_sec" >/dev/null 2>&1 || { echo '{"error":"not found"}'; exit 0; }
	_p=$(uci -q get "$CFG.$_sec.path")
	_if=$(uci -q get "$CFG.$_sec.network")
	_killed=""
	if [ -n "$_if" ]; then
		_n=$(uci -q show "$CFG" 2>/dev/null | grep -c "^$CFG\.m_[^.]*\.network='\?$_if'\?\$")
		if [ "${_n:-0}" -le 1 ]; then
			ifdown "$_if" >/dev/null 2>&1
			uci -q delete "network.$_if"
			uci -q commit network
			_killed="$_if"
		fi
	fi
	uci -q delete "$CFG.$_sec"
	# УДАЛИЛИ АКТИВНЫЙ ПРОФИЛЬ.
	#
	# Раньше здесь просто ОЧИЩАЛСЯ active_modem - и модем «пропадал»: кнопка
	# «создать интерфейс» зовёт mkiface без пути, mkiface берёт путь из
	# active_modem, а он пуст -> секция пишется в мусорную "m_", интерфейс
	# оставался без имени/протокола. Именно так пересозданный Quectel выходил
	# «без названия».
	#
	# Правильно: удаляем НАСТРОЙКИ (секцию), но если модем ЕЩЁ НА ШИНЕ - он
	# остаётся управляемым. Оставляем его активным (секцию НЕ пересоздаём -
	# удаление видимо срабатывает, безымянного профиля нет). Создание интерфейса
	# затем заведёт секцию заново и свяжет её правильно. Модема нет - выбираем
	# другой присутствующий, иначе снимаем указатель.
	if [ "$(uci -q get "$CFG.@5gmodem[0].active_modem")" = "$_p" ]; then
		_present=" $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
		uci -q delete "$CFG.@5gmodem[0].preferred_modem" 2>/dev/null
		case "$_present" in
			*" $_p "*)
				# удалённый модем ещё воткнут - оставляем его активным
				logger -t 5gmodem "profile $_sec deleted, modem $_p still on the bus - keeping it active"
				;;
			*)
				# модема нет - берём первый другой присутствующий (или пусто)
				_other=""
				for _pp in $_present; do [ -n "$_pp" ] && { _other="$_pp"; break; }; done
				if [ -n "$_other" ]; then
					uci -q set "$CFG.@5gmodem[0].active_modem=$_other"
				else
					uci -q delete "$CFG.@5gmodem[0].active_modem" 2>/dev/null
				fi
				;;
		esac
	fi
	uci -q commit "$CFG"
	[ -n "$_killed" ] && /etc/init.d/network reload >/dev/null 2>&1
	logger -t 5gmodem "profile $_sec ($_p) deleted${_killed:+, interface $_killed too}"
	printf '{"success":true,"iface_removed":"%s"}\n' "$_killed"
	exit 0
	;;
apnfor)
	_j=$("$RES/5gmodem.sh" cached 30 2>/dev/null)
	_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)
	# Метрики отдают ПРОЧЕРК, а не пустоту, когда код сети неизвестен. Без этой
	# нормализации в apn_plmn попадало "---", а сравнение с настоящим PLMN
	# никогда не совпадало.
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"
	_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		for _c in "${_imsi%${_imsi#??????}}" "${_imsi%${_imsi#?????}}"; do
			_sim_plmns="$_sim_plmns ${_c%${_c#???}}-${_c#???}"
		done
	fi
	# В роуминге APN из таблицы не годится - см. пояснение в autoapn.
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	[ "$_reg" = "5" ] && exit 0
	_iccid=$(printf '%s' "$_j" | jsonfilter -e '@.iccid' 2>/dev/null | tr -cd '0-9')
	apn_pick "$_op" "$_plmn" "$_sim_plmns" "$_imsi" "$_iccid"
	exit 0
	;;
autoapn)
	note_foreign_uci network "modemswitch autoapn"
	IFACE="${2:-$(uci -q get "$CFG.@5gmodem[0].network")}"
	[ -n "$IFACE" ] || exit 0

	# РУЧНОЙ РЕЖИМ: APN распоряжается пользователь. Он его уже выбрал, и его
	# выбор хранится в самом интерфейсе - переписать значит потерять. Подсказку
	# с найденным APN страница показывает и так, применить её - одна кнопка.
	_am_sec=$(sec_for_iface "$IFACE")
	if [ "$(uci -q get "$CFG.$_am_sec.apn_mode")" = "manual" ]; then
		logger -t 5gmodem "autoapn: $IFACE is in manual mode, leaving the APN alone"
		exit 0
	fi

	# МЕТКА «СДАЛСЯ» - ТОРМОЗ ДЛЯ ТРИГГЕРА СМЕНЫ SIM.
	#
	# Триггер в 5gmodem.sh сравнивает IMSI симки с apn_imsi в секции и зовёт нас,
	# пока они расходятся. Все выходы «не смог» этот ключ не пишут - и вызов
	# повторялся раз в минуту ВЕЧНО (живой лог zbt: «смена SIM (IMSI) на modem»
	# каждые 2.5 минуты сутками, с AT-запросами на каждый круг). Метку ставим при
	# сдаче, снимаем при успехе; триггер по ней ждёт полчаса вместо минуты.
	# Файл в /tmp намеренно: после перезагрузки попытка честно повторяется.
	_am_gv="/tmp/5gmodem_autoapn_${_am_sec}.gaveup"
	_apn_giveup() { [ -n "$_am_sec" ] && : > "$_am_gv" 2>/dev/null; }
	_apn_done()   { [ -n "$_am_sec" ] && rm -f "$_am_gv" 2>/dev/null; }
	# ОПРАШИВАЕМ МОДЕМА-ХОЗЯИНА этого интерфейса, а не активного. Без POLL_MODEM
	# `cached` отдаёт снимок АКТИВНОГО модема: при настройке соседа autoapn
	# читал ЧУЖУЮ симку и ставил её APN (живой случай 31.07.2026: вернувшийся
	# Telit с Мегафоном получил «tt» по T-Mobile-симке активного Compal, лишний
	# передозвон). Пустой путь (legacy-конфиг) = прежнее поведение.
	_am_path=$(uci -q get "$CFG.$_am_sec.path")

	# IMSI, ПЕРЕДАННЫЙ ВЫЗЫВАЮЩИМ - САМЫЙ БЫСТРЫЙ ПУТЬ.
	#
	# Смену симки замечает опрос метрик, СРАВНИВАЯ прочитанный IMSI с
	# запомненным, - то есть новый IMSI у него уже в руках. Раньше он его не
	# передавал, и autoapn выяснял то же самое заново: сперва до 60 c ждал
	# появления адреса, потом до 40 c переспрашивал модем. На горячей замене
	# симки адреса заведомо нет (модем только регистрируется), поэтому первая
	# минута сгорала впустую - замерено на живой замене Мегафон -> Билайн:
	# 15:13:58 «смена SIM», 15:14:59 выбран APN.
	#
	# Ключ подбора - код сети из IMSI, больше ничего не нужно.
	_imsi_hint=$(printf '%s' "$3" | tr -cd '0-9')

	# Ждём адрес: регистрация и первый дозвон занимают десятки секунд. РАНЬШЕ
	# появление адреса было поводом выйти совсем - APN считался «раз связь есть,
	# значит подходящий». На деле оператор нередко пускает с любым APN, и в
	# интерфейсе годами оставался чужой: у Beeline-симки стоял "tt" от прежней
	# T-Mobile. Поэтому адрес больше не повод молчать - решает СРАВНЕНИЕ APN
	# ниже, а сам факт связи лишь избавляет от ожидания.
	#
	# И ЖДЁМ ТОЛЬКО ЕСЛИ IMSI НЕИЗВЕСТЕН: с ним ожидание адреса не даёт ничего.
	_w=0; _ip=""
	if [ ${#_imsi_hint} -lt 6 ]; then
		while [ "$_w" -lt 60 ]; do
			_ip=$(ubus call network.interface."$IFACE" status 2>/dev/null \
				| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
			[ -n "$_ip" ] && break
			sleep 5; _w=$((_w + 5))
		done
	fi

	# Узнаём, в чьей мы сети - С ПОВТОРАМИ, пока не прочитается хоть что-то.
	#
	# Ключ подбора - это IMSI (свой код сети симки), и он доступен, как только
	# SIM читается, ещё до соединения. РАНЬШЕ брался кэшированный снимок (cached
	# 30), а при первой настройке в нём ни оператора, ни IMSI не было - модем
	# только регистрировался. autoapn сдавался с "APN для «-» не найден", и APN
	# оставался дефолтным. Живой случай: SIM7600E с T-Mobile получил "internet"
	# вместо "tt", и QMI-контекст не активировался (нет IP).
	#
	# Теперь опрашиваем СВЕЖО и повторяем: IMSI появляется быстро, ждать его
	# дешевле, чем ошибиться с APN.
	_j=""; _op=""; _mcc=""; _mnc=""; _imsi=""; _apn_w=0
	if [ ${#_imsi_hint} -ge 6 ]; then
		# Подсказку берём как есть и в модем не идём вовсе.
		_imsi="$_imsi_hint"
	else
	# ШАГ ОЖИДАНИЯ АДАПТИВНЫЙ. Пять секунд на круг - это до восьми пропущенных
	# секунд там, где IMSI появляется на второй; тот же урок уже выучен в
	# _wait_reg (аудит 30.07): часто в начале, редко потом.
	while [ "$_apn_w" -lt 40 ]; do
		_j=$(POLL_MODEM="$_am_path" "$RES/5gmodem.sh" cached 5 2>/dev/null)
		_op=$(printf '%s' "$_j" | jsonfilter -e '@.operator_name' 2>/dev/null)
		_imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
		# Достаточно ЛИБО оператора, ЛИБО IMSI - оба дают ключ к APN.
		{ [ -n "$_op" ] && [ "$_op" != "-" ]; } || [ ${#_imsi} -ge 6 ] && break
		if [ "$_apn_w" -lt 6 ]; then sleep 1; _apn_w=$((_apn_w + 1))
		else sleep 5; _apn_w=$((_apn_w + 5)); fi
	done
	fi
	_mcc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mcc' 2>/dev/null)
	_mnc=$(printf '%s' "$_j" | jsonfilter -e '@.operator_mnc' 2>/dev/null)

	# ЗАПАСНОЙ ПУТЬ - СПРОСИТЬ ModemManager НАПРЯМУЮ.
	#
	# Ключ подбора APN - IMSI, а читаем мы его по AT. У модема под управлением MM
	# AT-порта может не быть ВОВСЕ (живой случай: Compal RXM-G1 в заводской
	# композиции 05c6:9063 - только cdc-wdm и wwan). Тогда цикл выше уходил
	# впустую: ни оператора, ни IMSI, autoapn сдавался, и в интерфейсе оставался
	# APN от ПРЕДЫДУЩЕЙ симки. У пользователя после замены Tele2 на Мегафон так и
	# остался чужой APN, а сессия данных не поднималась.
	#
	# ModemManager знает и IMSI (объект SIM), и код сети - берём у него. Только
	# когда своих данных нет: у AT-модема наш разбор точнее (UCS2, mccmnc.dat,
	# бренд MVNO поверх хост-сети).
	if [ ${#_imsi} -lt 6 ] || [ -z "$_mcc" ] || [ "$_mcc" = "-" ]; then
		if command -v mmcli >/dev/null 2>&1; then
			_aa_p=$(uci -q get "$CFG.$(sec_for_iface "$IFACE" 2>/dev/null).path" 2>/dev/null)
			[ -n "$_aa_p" ] || _aa_p=$(active_path)
			_aa_i=$(mm_index_for_path "$_aa_p" 2>/dev/null)
			if [ -n "$_aa_i" ]; then
				_aa_k=$(mmcli -m "$_aa_i" -K 2>/dev/null)
				# Код сети MM отдаёт слитно (25002), таблице APN нужны MCC и MNC
				# порознь: первые три цифры - страна, остальное - сеть.
				if [ -z "$_mcc" ] || [ "$_mcc" = "-" ]; then
					_aa_oc=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.3gpp\.operator-code *: *//p' | tr -cd '0-9')
					case "${#_aa_oc}" in
						5|6) _mcc=$(printf '%s' "$_aa_oc" | cut -c1-3)
						     _mnc=$(printf '%s' "$_aa_oc" | cut -c4-) ;;
					esac
				fi
				if [ -z "$_op" ] || [ "$_op" = "-" ]; then
					_op=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.3gpp\.operator-name *: *//p' | head -1)
				fi
				if [ ${#_imsi} -lt 6 ]; then
					_aa_sim=$(printf '%s\n' "$_aa_k" | sed -n 's/^modem\.generic\.sim *: *//p' | head -1)
					case "$_aa_sim" in
						*/SIM/*) _imsi=$(mmcli -i "${_aa_sim##*/}" -K 2>/dev/null \
							| sed -n 's/^sim\.properties\.imsi *: *//p' | tr -cd '0-9') ;;
					esac
				fi
				logger -t 5gmodem "autoapn: details fetched from ModemManager - operator \"${_op:--}\", network ${_mcc:--}-${_mnc:--}, IMSI ${#_imsi} digits"
			fi
		fi
	fi
	# Метрики отдают ПРОЧЕРК, а не пустоту, когда код сети неизвестен. Без этой
	# нормализации в apn_plmn попадало "---", а сравнение с настоящим PLMN
	# никогда не совпадало.
	[ "$_mcc" = "-" ] && _mcc=""
	[ "$_mnc" = "-" ] && _mnc=""
	_plmn=""
	[ -n "$_mcc" ] && [ -n "$_mnc" ] && _plmn="$_mcc-$_mnc"

	# КЛЮЧ ОТ САМОЙ SIM. У MVNO код зарегистрированной сети принадлежит ХОСТУ
	# (Т-Мобайл виден как 250-20 Tele2), а в IMSI записан СВОЙ код - 250-62.
	# Наблюдалось вживую: Compal получил APN "internet" от Tele2 вместо своего.
	# Имя оператора тут не спасает - этот модем отдаёт вместо него мусор
	# ("00540030"), а имя с SIM (EF_SPN) читается только если AT-порт в этот
	# момент отвечает, чего после перетасовки портов не случилось.
	# Длину MNC заранее не знаем (2 или 3 цифры), поэтому пробуем оба варианта.
	# НЕ затирать IMSI, добранный выше из ModemManager: в снимке _j его нет
	# (модем без AT-порта), и безусловное перечтение теряло добытое (ревью).
	[ ${#_imsi} -ge 6 ] || _imsi=$(printf '%s' "$_j" | jsonfilter -e '@.imsi' 2>/dev/null | tr -cd '0-9')
	_sim_plmns=""
	if [ ${#_imsi} -ge 6 ]; then
		_sim_plmns="${_imsi%${_imsi#??????}} ${_imsi%${_imsi#?????}}"
		# приводим к виду MCC-MNC
		_tmp=""
		for _c in $_sim_plmns; do _tmp="$_tmp ${_c%${_c#???}}-${_c#???}"; done
		_sim_plmns="$_tmp"
	fi
	# ПУСТОЙ ОПЕРАТОР - ЕЩЁ НЕ ПОВОД СДАВАТЬСЯ, ЕСЛИ ЕСТЬ IMSI.
	#
	# Быстрый путь (IMSI передал вызывающий) в модем НЕ ХОДИТ вовсе - у него ни
	# имени сети, ни PLMN нет по определению, и это норма: ключ подбора - код
	# сети из самого IMSI, apn_pick умеет искать по нему и по мировой базе. А
	# прежний guard требовал именно оператора и обрывал КАЖДЫЙ такой вызов: у
	# FM350 (mm_exclude, добрать из MM неоткуда) APN не подбирался никогда, зато
	# триггер смены SIM крутился по кругу - см. метку «сдался» выше.
	if [ -z "$_op$_plmn" ] && [ ${#_imsi} -lt 6 ]; then
		logger -t 5gmodem "autoapn: neither operator nor IMSI - skipping"
		_apn_giveup
		exit 0
	fi

	# РОУМИНГ: APN из таблицы НЕ ПОДХОДИТ. В роуминге модем зарегистрирован в
	# ЧУЖОЙ сети, и её APN симке не годится - нужен домашний, которого мы знать
	# не можем: и имя, и код сети принадлежат гостевой стороне. Для travel-eSIM
	# и большинства роуминговых профилей правильное значение - ПУСТО: оператор
	# выдаёт настройки сам. Подставив APN гостевой сети, мы бы сломали связь,
	# которая иначе поднялась бы без нашего участия.
	# Признак роуминга - код регистрации 5 (registered, roaming) против 1 (home).
	_reg=$(printf '%s' "$_j" | jsonfilter -e '@.registration' 2>/dev/null)
	if [ "$_reg" = "5" ]; then
		logger -t 5gmodem "autoapn: roaming (network \"$_op\", $_plmn) - leaving the APN empty"
		_apn_giveup
		exit 0
	fi

	_iccid=$(printf '%s' "$_j" | jsonfilter -e '@.iccid' 2>/dev/null | tr -cd '0-9')
	_apn=$(apn_pick "$_op" "$_plmn" "$_sim_plmns" "$_imsi" "$_iccid") || {
		logger -t 5gmodem "autoapn: no APN found for \"$_op\" ($_plmn, SIM$_sim_plmns)"
		_apn_giveup
		exit 0
	}
	# Пустой PLMN на быстром пути - это НЕ «код сети пропал», а «в модем не
	# ходили». Записать его поверх сохранённого значило бы стереть верный.
	_apn_stamp_sec() {
		[ -n "$_am_sec" ] || return 0
		[ -n "$_plmn" ] && uci -q set "$CFG.$_am_sec.apn_plmn=$_plmn"
		[ -n "$_imsi" ] && uci -q set "$CFG.$_am_sec.apn_imsi=$_imsi"
		uci -q commit "$CFG"
	}
	_cur=$(uci -q get "network.$IFACE.apn")
	if [ "$_cur" = "$_apn" ]; then
		logger -t 5gmodem "autoapn: APN is already set to $_apn"
		# Помечаем СИМКУ обработанной (её IMSI) - персистентно, в секции. По этому
		# ключу опрос метрик понимает, что для ЭТОЙ симки APN уже подобран, и не
		# дёргает autoapn на каждом опросе. Переживает перезагрузку и очистку /tmp.
		_apn_stamp_sec
		_apn_done
		exit 0
	fi

	uci -q set "network.$IFACE.apn=$_apn"
	uci -q commit network
	# Помним, ДЛЯ КАКОЙ сети подобран APN: по этой записи видно в отладке, что
	# значение относится к нынешней симке, а не осталось от прежней.
	_apn_stamp_sec
	_apn_done
	logger -t 5gmodem "autoapn: $IFACE -> APN $_apn (was \"${_cur:-empty}\", operator \"$_op\", $_plmn)"
	ifdown "$IFACE" >/dev/null 2>&1
	sleep 3
	# ПЕРЕД ДОЗВОНОМ ЖДЁМ ГОТОВНОСТИ МОДЕМА - НО ПО ФАКТУ, А НЕ ВСЛЕПУЮ.
	#
	# Быстрый путь по IMSI ставит APN уже через секунды после того, как симку
	# вынули и вставили, - а модем в этот момент ещё переинициализируется (у MM
	# это «SIM hot swap setup», секунд десять-пятнадцать). Дозвон в такую минуту
	# просто не удаётся, и связь появляется потом, по кругу восстановления -
	# ровно та пауза, которую видно в журнале живой замены: APN выбран в
	# 15:14:59, соединение поднялось в 15:15:51.
	#
	# Поэтому спрашиваем ModemManager, зарегистрирован ли модем, шагом в секунду
	# и не дольше 30 c. Модем не под MM или mmcli нет - ждать нечего, идём как
	# раньше.
	_aa_mi=""
	command -v mmcli >/dev/null 2>&1 && _aa_mi=$(mm_index_for_path "$_am_path" 2>/dev/null)
	if [ -n "$_aa_mi" ]; then
		_aa_w=0
		while [ "$_aa_w" -lt 30 ]; do
			case "$(mmcli -m "$_aa_mi" -K 2>/dev/null \
				| sed -n 's/^modem\.generic\.state *: *//p')" in
				registered|connected|connecting|disconnecting) break ;;
			esac
			sleep 1; _aa_w=$((_aa_w + 1))
		done
		[ "$_aa_w" -gt 0 ] && logger -t 5gmodem "autoapn: waited ${_aa_w}s for the modem to become ready"
	else
		# БЕЗ ModemManager ЖДЁМ ПО AT - РАНЬШЕ НЕ ЖДАЛИ ВОВСЕ.
		#
		# Ожидание выше спрашивает MM, и на сборке без него (наш fibocom, atc,
		# xmm) мы поднимали интерфейс ЧЕРЕЗ ТРИ СЕКУНДЫ после ifdown - в модем,
		# который ещё грузится. Живой отчёт (WH3000 Pro, 02.08.2026): модем
		# перечислился в 21:55:43, autoapn дёрнул интерфейс в 21:55:46, дальше
		# три круга «setting up - disconnected» подряд, каждый заново отсчитывал
		# 30-секундную паузу прото, и первая настоящая попытка дозвона случилась
		# только в 21:57:14 - через полторы минуты.
		#
		# Ждём того же, чего ждала бы MM-ветка: регистрации в сети. Шаг 2 c,
		# потолок 30 c. Не дождались - всё равно поднимаем: APN уже сменён, и
		# оставить интерфейс лежать хуже, чем попробовать.
		_aa_p=$(uci -q get "$CFG.$_am_sec.at_port")
		[ -n "$_aa_p" ] || _aa_p=$("$RES/detect.sh" 2>/dev/null)
		if [ -n "$_aa_p" ] && [ -c "$_aa_p" ]; then
			_aa_w=0
			while [ "$_aa_w" -lt 30 ]; do
				case "$(at_query "$_aa_p" "AT+CEREG?" 5 2>/dev/null | tr -d '\r' \
					| sed -n 's/^+CEREG: *[0-9]*,\([0-9]*\).*/\1/p' | head -1)" in
					1|5|6|7|9|10) break ;;
				esac
				sleep 2; _aa_w=$((_aa_w + 2))
			done
			[ "$_aa_w" -gt 0 ] && logger -t 5gmodem "autoapn: waited ${_aa_w}s for network registration (no MM)"
		fi
	fi
	ifup "$IFACE" >/dev/null 2>&1
	# Авто-подбор типа PDP ОТКЛЮЧЁН намеренно: дефолт теперь IPV4 (на нём модемы
	# получают адрес сразу; см. set_pdp_opt в mkiface.sh), а перебор ipv4v6/ipv4
	# рвал связь и на практике ни разу не срабатывал успешно (мёртвая ветка
	# autopdp удалена при чистке 31.07.2026).
	;;


# АВТОНАСТРОЙКА НОВОГО МОДЕМА (plug-and-play).
#
# Задача: воткнул модем - получил интернет, без хождения по вкладкам. Но делать
# это безоглядно нельзя: mkiface настраивает АКТИВНЫЙ модем, и на роутере с уже
# работающим модемом второй воткнутый перехватил бы конфигурацию. Поэтому
# автонастройка срабатывает ТОЛЬКО когда рабочего интерфейса ещё нет - то есть
# ровно в том случае, ради которого затевалась: первый запуск или первый модем.
#
# Выключается: uci set 5gmodem.@5gmodem[0].auto_setup=0
autosetup)
	note_foreign_uci network "modemswitch autosetup"
	note_foreign_uci firewall "modemswitch autosetup"
	[ "$(uci -q get "$CFG.@5gmodem[0].auto_setup")" = "0" ] && exit 0

	# ЦЕЛЬ - ПРИСУТСТВУЮЩИЙ МОДЕМ БЕЗ РАБОЧЕГО ИНТЕРФЕЙСА.
	#
	# Раньше здесь стоял ГЛОБАЛЬНЫЙ гард: если хоть у одного модема есть живая
	# сеть, autosetup выходил целиком. На роутере с одним настроенным модемом это
	# означало, что второй, только что воткнутый, не настраивался НИКОГДА. Ровно
	# этот случай и наблюдался: ветка обработки замены модема на том же USB-пути
	# пишет в лог "rerun setup to rebuild", гасит устаревший интерфейс и ждёт,
	# что setup отработает заново, - а он выходил на первом же гарде.
	# Проверяем теперь ПОМОДЕМНО: модем с живой сетью пропускаем (его не трогаем,
	# ради чего гард и был), берём первый без неё.
	# ВСЕ модемы без рабочей сети, а не первый попавшийся.
	#
	# Раньше здесь стоял `break`: за один заход настраивался ровно один модем.
	# При установке пакета на роутер с ДВУМЯ воткнутыми модемами второй так и
	# оставался без секции и интерфейса - до собственного hotplug-события или
	# ручного переключения. На странице профилей это выглядело как «программа нашла только один модем».
	TARGETS="$2"
	if [ -z "$TARGETS" ]; then
		for _p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			# HiLink-модем без AT-портов - ЦЕЛЬ, даже если интерфейс уже есть.
			# Режим debug слетает при каждом переподключении модема, а интерфейс
			# при этом остаётся на месте - и проверка «интерфейс есть, значит
			# настроен» пропускала модем, оставляя его в чистом HiLink: ни TAC, ни
			# диапазонов, ни USSD. Наблюдалось ровно так после перетыкания.
			if [ "$(uci -q get "$CFG.$_s.kind")" = "hilink" ] \
			   && [ "$(uci -q get "$CFG.$_s.at_debug")" != "0" ] \
			   && [ -z "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_p\"].tty[0]" 2>/dev/null)" ]; then
				TARGETS="$TARGETS $_p"
				continue
			fi
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && continue
			TARGETS="$TARGETS $_p"
		done
	fi
	[ -n "$TARGETS" ] || exit 0

	for P in $TARGETS; do
		setup_one_modem "$P"
	done
	exit 0
	;;


resolve)
	# ТРАНЗАКЦИЯ: resolve пишет секции 5gmodem до ~12 с, а detect.sh/switch
	# коммитят тот же общий стейджинг /tmp/.uci - полусобранное состояние
	# уезжало в конфиг (ревью, баг №7). Замок сериализует resolve'ы между
	# собой, а сторонние писатели (detect) при занятом замке пропускают ход.
	exec 7>/tmp/5gmodem_ucitx.lock
	flock 7
	note_foreign_uci network "modemswitch resolve"
	note_foreign_uci firewall "modemswitch resolve"
	# Re-resolve ports/devices for all PRESENT modems by their STABLE USB path.
	# ttyUSB numbering shifts when a modem is added/removed or on reboot, so a
	# pinned ttyUSB goes stale ("Bad file descriptor", no data). Run on boot
	# (coldplug) and on USB hotplug add/remove -> the app self-heals, no manual
	# re-creation needed.
	PRESENT=$("$RES/listmodems.sh" | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')

	# СХЛОПЫВАНИЕ ДУБЛЕЙ ПРОФИЛЕЙ ПО IMEI. ensure_section мигрирует профиль в
	# момент появления модема, но если тогда IMEI прочитать не удалось (AT-порт
	# занят - например, интерфейс-двойник как раз душит модем), два профиля с
	# одним IMEI остаются жить параллельно: старый путь «не подключён» + новый
	# живой (отчёт 03.08.2026: L850 переехал 1-1.4 -> 1-1.2, в UI два
	# одинаковых модема). Добиваем миграцию здесь по СОХРАНЁННЫМ значениям:
	# присутствующая секция - приёмник, отсутствующая - источник. Гварды те же,
	# что в ensure_section: старый путь занят - не трогаем (IMEI прочитан у
	# чужого); серийники есть у обоих и разные - это разные аппараты.
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		case "$SEC" in m_park_*) continue ;; esac
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		_dd_imei=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
		[ -n "$_dd_imei" ] || continue
		_dd_old=$(sec_by_imei "$_dd_imei" "$SEC")
		[ -n "$_dd_old" ] || continue
		case "$_dd_old" in m_park_*) continue ;; esac
		_dd_op=$(uci -q get "$CFG.$_dd_old.path")
		[ -n "$_dd_op" ] && [ -e "/sys/bus/usb/devices/$_dd_op" ] && continue
		_dd_os=$(uci -q get "$CFG.$_dd_old.serial")
		_dd_ns=$(uci -q get "$CFG.$SEC.serial")
		[ -n "$_dd_os" ] && [ -n "$_dd_ns" ] && [ "$_dd_os" != "$_dd_ns" ] && continue
		logger -t 5gmodem "resolve: duplicate profile by IMEI $_dd_imei ($_dd_old, path ${_dd_op:-?} is gone) - moving into $SEC"
		migrate_profile "$_dd_old" "$SEC"
	done

	# НОДА-КОЛЛИЗИЯ: интерфейс ОТСУТСТВУЮЩЕГО модема, чья абсолютная нода
	# (/dev/tty*) сейчас принадлежит другому живому модему. Нумерация нод
	# сдвигается при каждой переэнумерации, и netifd продолжает дозваниваться
	# по старой ноде В ЧУЖОЙ модем: держит его AT-порт, мешает штатному дозвону
	# (из отчёта: modem4 пути 2-1 с device=/dev/ttyACM0 живого L850). Интерфейс
	# НЕ удаляем - отсутствие модема часто временное, настройки ценные, - а
	# выключаем (auto=0) с нашей меткой; вернулся модем на путь - метку и
	# запрет снимаем здесь же.
	_nc_changed=""
	for _nc_if in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
		_nc_p=$(uci -q get "network.$_nc_if.modem_path")
		if echo " $PRESENT " | grep -q " $_nc_p "; then
			if [ "$(uci -q get "network.$_nc_if.modem_parked")" = "1" ]; then
				uci -q delete "network.$_nc_if.auto"
				uci -q delete "network.$_nc_if.modem_parked"
				_nc_changed=1
				logger -t 5gmodem "resolve: modem $_nc_p is back - interface $_nc_if re-enabled"
			fi
			continue
		fi
		[ "$(uci -q get "network.$_nc_if.modem_parked")" = "1" ] && continue
		_nc_dev=$(uci -q get "network.$_nc_if.device")
		case "$_nc_dev" in /dev/tty*) : ;; *) continue ;; esac
		[ -e "$_nc_dev" ] || continue
		_nc_own=""
		for _nc_pp in $PRESENT; do
			modem_ttys "$_nc_pp" 2>/dev/null | grep -qxF "$_nc_dev" && { _nc_own="$_nc_pp"; break; }
		done
		[ -n "$_nc_own" ] || continue
		logger -t 5gmodem "resolve: interface $_nc_if has no modem (path $_nc_p) and its node $_nc_dev belongs to live $_nc_own - disabling until the modem returns"
		ifdown "$_nc_if" 2>/dev/null
		uci -q set "network.$_nc_if.auto=0"
		uci -q set "network.$_nc_if.modem_parked=1"
		_nc_changed=1
	done
	[ -n "$_nc_changed" ] && { uci -q commit network; ubus call network reload >/dev/null 2>&1; }

	# refresh at_port for every present, configured modem
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo " $PRESENT " | grep -q " $P " || continue
		# модем на этом пути мог смениться на другой - тогда всё запомненное о
		# прежнем недействительно (см. swap_cleanup)
		swap_cleanup "$P" "$SEC"
		# ШТАМП SERIAL - ЗДЕСЬ, А НЕ ТОЛЬКО В ensure_section.
		#
		# resolve выполняется на ЗАГРУЗКЕ и на каждом событии USB, и идёт по уже
		# настроенным секциям напрямую - ensure_section он не зовёт. Без этой строки
		# серийник появлялся бы в секции только при переустановке модема, то есть
		# ровно тогда, когда он уже не нужен. Стоит он ноль: реестр всё равно
		# запрошен рядом (modem_ttys/at_for_path), а sysfs-чтение AT не трогает.
		# ВАЖНО: строго ПОСЛЕ swap_cleanup - тот удаляет серийник прежнего аппарата.
		_rs_ser=$(modem_serial "$P")
		[ -n "$_rs_ser" ] && uci -q set "$CFG.$SEC.serial=$_rs_ser"
		# Порты появляются НЕ мгновенно: после hotplug-add ядро заводит ttyUSB*
		# ещё несколько секунд (FM350 отдаёт 7 штук), а hotplug ждёт всего 5с.
		# Ждём порт, но не бесконечно (resolve всегда вызывается из фона).
		# ПРИВЯЗКА К СЛОТУ. Найденный ранее порт закреплён за секцией модема, а
		# секция - за стабильным USB-путём. Если порт всё ещё принадлежит ЭТОМУ
		# пути и отвечает на AT, перебирать заново незачем.
		# Замерено: resolve занимал 4.4 c и выполняется на КАЖДОМ событии USB и при
		# загрузке, а проверка закреплённого порта укладывается в сотые доли.
		# Перебор остаётся запасным путём - нумерация tty после переподключения
		# сдвигается, и тогда закрепление протухает.
		A=""
		_pin=$(uci -q get "$CFG.$SEC.at_port")
		if [ -n "$_pin" ] && [ -e "$_pin" ] && modem_ttys "$P" | grep -qxF "$_pin"; then
			"$RES/atprobe.sh" "$_pin" >/dev/null 2>&1 && A="$_pin"
		fi
		_try=0
		while [ -z "$A" ] && [ "$_try" -lt 6 ]; do
			A=$(at_for_path "$P")
			[ -n "$A" ] && break
			_try=$((_try + 1)); sleep 2
		done
		if [ -n "$A" ]; then
			uci -q set "$CFG.$SEC.at_port=$A"
		else
			# Порт не отдался. Раньше СТАРОЕ значение молча оставалось в конфиге -
			# а после «включили роутер без модема, воткнули позже» нумерация ttyUSB
			# другая, и там лежал порт от прошлой загрузки, часто уже принадлежащий
			# СОСЕДНЕМУ модему: метрики читали чужой tty (0% сигнала, ни uptime, ни
			# rx/tx - до ручного переключения модема в UI, которое всё чинило).
			# Сохранённый оставляем, ТОЛЬКО если он ещё существует и принадлежит
			# ЭТОМУ модему (значит, AT-проба просто столкнулась за порт); иначе
			# чистим - пусто честнее чужого (см. инвариант в ветке switch).
			SAVED=$(uci -q get "$CFG.$SEC.at_port")
			if [ -n "$SAVED" ] && { [ ! -e "$SAVED" ] || ! modem_ttys "$P" | grep -qxF "$SAVED"; }; then
				uci -q delete "$CFG.$SEC.at_port" 2>/dev/null
			fi
		fi
		# ИМЯ МОДЕЛИ НЕАКТИВНОМУ МОДЕМУ. Основной опрос (5gmodem.sh) ходит только
		# по АКТИВНОМУ модему, поэтому сосед оставался в списке безымянным до
		# переключения на него - наблюдалось на SimCom 1e0e:9001 (в UI пусто, хотя
		# AT+CGMM отвечает "SIMCOM_SIM7600E-H"). Спрашиваем РОВНО ОДИН раз: когда
		# модели ещё нет, а порт уже найден. Дальше значение лежит в секции, и
		# лишних AT-хождений на каждом resolve не будет.
		# АППАРАТ В ПОРТУ МОГЛИ ЗАМЕНИТЬ НА ДРУГОЙ С ТЕМ ЖЕ VID:PID.
		#
		# swap_cleanup выше ловит подмену по vidpid и молча выходит, когда тот
		# не изменился, - а L850 и L860-GL-16 оба 8087:095a (и это не
		# единственное такое семейство). Производные прежнего аппарата тогда
		# оставались навсегда: модель перечитывается только когда она пуста, и
		# в профиле у пользователя значился L850 при физически стоящем L860.
		# Сверяем IMEI одной командой (порт уже найден и ниже всё равно
		# опрашивается) и при расхождении обнуляем производное - модель
		# перечитает блок ниже, порты уже переизбраны выше.
		if [ -n "$A" ] && [ -n "$(uci -q get "$CFG.$SEC.model")" ]; then
			_rs_imei=$(sms_tool -d "$A" at "AT+CGSN" 2>/dev/null | tr -d '\r' \
				| grep -oE '^[0-9]{14,16}$' | head -1)
			_rs_prev=$(uci -q get "$CFG.$SEC.imei" | tr -cd '0-9')
			if [ -n "$_rs_imei" ] && [ -n "$_rs_prev" ] && [ "$_rs_imei" != "$_rs_prev" ]; then
				logger -t 5gmodem "resolve: a different unit in port $P with the same vid:pid (IMEI $_rs_prev -> $_rs_imei) - re-reading the model"
				uci -q delete "$CFG.$SEC.model" 2>/dev/null
				uci -q delete "$CFG.$SEC.model_vp" 2>/dev/null
				uci -q set "$CFG.$SEC.imei=$_rs_imei"
				uci -q commit "$CFG"
				purge_path_caches "$P"
			fi
		fi
		if [ -n "$A" ] && [ -z "$(uci -q get "$CFG.$SEC.model")" ]; then
			_rm=$(sms_tool -d "$A" at "AT+CGMM" 2>/dev/null | tr -d '\r' \
				| grep -vE '^[[:space:]]*$|^OK$|^AT' | head -1)
			# Часть прошивок отвечает "+CGMM: <модель>" и/или в кавычках.
			_rm=$(printf '%s' "$_rm" \
				| sed -e 's/^+\{0,1\}CGMM:[[:space:]]*//' -e 's/^"//' -e 's/"$//' \
				      -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			# Те же проверки, что у основного опроса (см. lib.sh): не эхо/не ошибка
			# и вендор в имени не противоречит vid:pid - иначе в секцию попадал бы
			# ответ чужой команды или имя соседнего модема с общего порта.
			if [ -n "$_rm" ] && _model_sane "$_rm" \
			   && _model_vendor_ok "$_rm" "$(uci -q get "$CFG.$SEC.vidpid")"; then
				# Через model_alias, как основной опрос и listmodems: иначе сырое
				# AT+CGMM ("SIMCOM SIM7100E") затирало нормализованное имя из опроса.
				uci -q set "$CFG.$SEC.model=$(model_alias "$_rm")"
				# ШТАМП ЖЕЛЕЗА РЯДОМ С ИМЕНЕМ. Модель принадлежит КОНКРЕТНОМУ
				# vid:pid, с которого её прочитали. Без штампа имя переживало
				# смену устройства в том же разъёме и приписывалось новому
				# (живой случай: телефон Samsung в порту SIM7100E показывался
				# как «SIMCOM SIM7100E»). Читатель сверяет штамп - см. listmodems.
				uci -q set "$CFG.$SEC.model_vp=$(uci -q get "$CFG.$SEC.vidpid")"
				logger -t 5gmodem-resolve "model for $SEC identified: $_rm"
			fi
		fi
	done
	uci -q commit "$CFG"

	# ПРОБУЖДЕНИЕ интерфейса вернувшегося модема.
	#
	# Усыплял его swap_cleanup (auto=0), когда модем вытеснили из разъёма. Модем
	# на месте - снимаем сон, иначе интерфейс так и не поднимется.
	#
	# УСЫПЛЯТЬ ЗДЕСЬ НЕЛЬЗЯ. Пробовал гасить автозапуск всем отсутствующим (чтобы
	# netifd не долбился в device-ноду, доставшуюся другому модему) - и получил
	# регрессию: модем ПРОПАДАЕТ С ШИНЫ на секунды-минуты штатно (AT+CFUN=1,1,
	# смена композиции, перепривязка драйвера), и свежесозданный интерфейс Compal
	# уснул прямо во время собственной переэнумерации. Отсутствие модема в этот
	# миг - НЕ признак того, что он ушёл насовсем. Сон ставим только по факту
	# подмены (swap_cleanup), где это достоверно.
	_sl_chg=0
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		_sl_if=$(uci -q get "$CFG.$SEC.network")
		[ -n "$_sl_if" ] || continue
		uci -q get "network.$_sl_if" >/dev/null 2>&1 || continue
		_sl_p=$(uci -q get "$CFG.$SEC.path")
		[ -n "$_sl_p" ] && echo " $PRESENT " | grep -q " $_sl_p " || continue
		[ "$(uci -q get "network.$_sl_if.auto")" = "0" ] || continue
		uci -q delete "network.$_sl_if.auto"; _sl_chg=1
		# ПРИВЯЗКУ К ЖЕЛЕЗУ ОСВЕЖАЕМ ПРИ ПРОБУЖДЕНИИ.
		#
		# Интерфейс проснувшегося модема мы намеренно не пересоздаём (в нём
		# настройки пользователя), но узел /dev/cdc-wdmN за время сна мог
		# достаться ДРУГОМУ модему - и qmi/mbim пошли бы дозваниваться в чужой
		# канал. Лечится штампом devpath: он привязан к топологии USB (путь +
		# номер интерфейса) и переживает переэнумерацию, а qmi.sh при каждом
		# setup находит по нему актуальный cdc-wdm. Ставим/обновляем ровно тут -
		# при пересоздании это делает mkiface, а разбуженный интерфейс мимо него
		# проходит (живой случай: парковка Telit с device=/dev/cdc-wdm0).
		case "$(uci -q get "network.$_sl_if.proto")" in
			qmi|mbim)
				for _sl_w in /sys/bus/usb/devices/"$_sl_p":*/usbmisc/cdc-wdm* \
				             /sys/bus/usb/devices/"$_sl_p":*/usbmisc/wdm*; do
					[ -e "$_sl_w" ] || continue
					_sl_dp=$(dirname "$(dirname "$_sl_w")")
					uci -q set "network.$_sl_if.device=/dev/$(basename "$_sl_w")"
					uci -q set "network.$_sl_if.devpath=$_sl_dp"
					logger -t 5gmodem-resolve "interface $_sl_if: control channel re-bound to $_sl_dp"
					break
				done ;;
		esac
		logger -t 5gmodem-resolve "interface $_sl_if woken up: modem $_sl_p is back"
	done
	[ "$_sl_chg" = 1 ] && { uci -q commit network; ubus call network reload >/dev/null 2>&1; }

	# Активный модем. preferred_modem - ЯВНЫЙ выбор пользователя (ставится веткой
	# switch). Модем может пропасть с шины НЕНАДОЛГО: AT+CFUN=1,1 (перезагрузка
	# модема, в т.ч. наша - после добавления eSIM-профиля) переперечисляет USB на
	# десятки секунд. Раньше resolve в этот момент НАВСЕГДА переставлял активность
	# на соседа, и после возвращения модема она к нему не возвращалась - выбор
	# пользователя молча терялся. Теперь: вернулся предпочтительный - отдаём
	# активность ему; нет - временно берём первый присутствующий, НЕ трогая
	# preferred_modem, чтобы следующий resolve всё вернул на место.
	AMP=$(active_path)
	PREF=$(uci -q get "$CFG.@5gmodem[0].preferred_modem")
	# ПРЕДПОЧТИТЕЛЬНЫЙ, КОТОРЫЙ НЕ МОДЕМ, - НЕ ПРЕДПОЧТИТЕЛЬНЫЙ.
	#
	# Это ЯВНЫЙ выбор пользователя, и мы его бережём: модем мог отвалиться на
	# минуту (CFUN=1,1, переэнумерация), и активность к нему потом возвращается.
	# Но если в поле лежит устройство, которого в списке модемов нет ВООБЩЕ и
	# которое там появиться не может (телефон в режиме USB-модема), ждать нечего:
	# запись будет вечно перетягивать активность на пустое место. Секции таких
	# устройств у нас есть (у телефона она заводится под интерфейс), поэтому
	# судим именно по списку модемов, а не по наличию секции.
	if [ -n "$PREF" ] && [ -n "$PRESENT" ] \
	   && ! echo " $PRESENT " | grep -q " $PREF " \
	   && [ ! -e "/sys/bus/usb/devices/$PREF" ]; then
		: # устройства нет на шине - это обычное временное отсутствие, не трогаем
	elif [ -n "$PREF" ] && [ -n "$PRESENT" ] && ! echo " $PRESENT " | grep -q " $PREF " \
	     && [ -e "/sys/bus/usb/devices/$PREF" ]; then
		logger -t 5gmodem-resolve "preferred \"$PREF\" is on the bus but is not a modem - clearing the mark"
		uci -q delete "$CFG.@5gmodem[0].preferred_modem"; uci -q commit "$CFG"
		PREF=""
	fi
	if [ -n "$PREF" ] && echo " $PRESENT " | grep -q " $PREF " && [ "$AMP" != "$PREF" ]; then
		AMP="$PREF"
		uci -q set "$CFG.@5gmodem[0].active_modem=$AMP"
		uci -q commit "$CFG"
	elif [ -z "$AMP" ] || ! echo " $PRESENT " | grep -q " $AMP "; then
		# Активный пропал с шины. Кого брать вместо него - НЕ «первого в списке».
		# У FM350 есть штатный флап переэнумерации (см. quirks), и ровно в эту
		# секунду рядом может оказаться только что воткнутый НЕНАСТРОЕННЫЙ модем.
		# Тогда активность уезжала на него, а следом - и ГЛОБАЛЬНЫЕ порты
		# sms_tool_js (ниже по ветке): открытая страница прежнего модема начинала
		# показывать чужой сигнал, чужую SIM и чужой номер, ничего не сообщая.
		# Предпочитаем модем с РАБОЧИМ интерфейсом: он почти наверняка и есть тот,
		# что работал до сих пор.
		_cand=""
		for _p in $PRESENT; do
			_s=$(secname "$_p")
			_n=$(uci -q get "$CFG.$_s.network")
			[ -n "$_n" ] && uci -q get "network.$_n" >/dev/null 2>&1 && { _cand="$_p"; break; }
		done
		[ -n "$_cand" ] || _cand=$(echo "$PRESENT" | awk '{print $1}')
		AMP="$_cand"
		[ -n "$AMP" ] && uci -q set "$CFG.@5gmodem[0].active_modem=$AMP" && uci -q commit "$CFG"
	fi
	[ -n "$AMP" ] || { echo '{"result":"no-modems"}'; exit 0; }

	# apply the active modem's fresh AT port to the working config + SMS ports
	SEC=$(secname "$AMP")
	ATP=$(uci -q get "$CFG.$SEC.at_port")
	if [ -n "$ATP" ] && [ -e "$ATP" ]; then
		uci -q set "$CFG.@5gmodem[0].at_port=$ATP"
		uci -q set "$CFG.@5gmodem[0].device=$ATP"
		if uci -q get 5gmodem.sms >/dev/null 2>&1; then
			for k in readport sendport ussdport atport; do uci -q set "5gmodem.sms.$k=$ATP"; done
			uci -q commit 5gmodem
			set_sms_storage "$ATP"
			# ...и СРАЗУ развести обратно. Строкой выше все порты SMS/USSD/AT
			# приравнены к порту метрик - это правильная отправная точка (порт
			# заведомо рабочий), но оставлять их так нельзя: sms_tool открывает
			# порт на каждый вызов, и чтение, попавшее на опрос метрик,
			# возвращает пустоту. Живой случай: после resolve USSD на MeigLink
			# отвечал "No response from modem", пока ussdport совпадал с at_port.
			# ensureports.sh сам найдёт свободный AT-порт, если модем его даёт,
			# и ничего не сделает, если порт единственный.
			"$RES/ensureports.sh" >/dev/null 2>&1
		fi
	else
		# см. инвариант в ветке switch: лучше пусто, чем порт ЧУЖОГО модема
		# (active_modem/network ниже переезжают на $AMP в любом случае).
		uci -q delete "$CFG.@5gmodem[0].at_port" 2>/dev/null
		uci -q delete "$CFG.@5gmodem[0].device" 2>/dev/null
	fi

	# --- recover the connections ---
	# 0) refresh the ModemManager ignore rules from the current per-modem protos,
	#    so MM keeps its hands off modems we drive via a kernel proto (qmi/mbim/
	#    atc/fibocom/...). Runs on boot (coldplug) and every hotplug.
	# 1) put ModemManager in the state the modem mix needs (creating an atc/mbim
	#    interface had disabled MM and taken the modemmanager modems down).
	apply_mm_state
	# 1.5) ПАРКОВКА интерфейса ОТСУТСТВУЮЩЕГО модема, чей device перехвачен
	#      ПРИСУТСТВУЮЩИМ. Пиннинг device=/dev/cdc-wdmN у секции вынутого модема
	#      протухает: узел теперь принадлежит ДРУГОМУ (present) модему, netifd
	#      поднимал бы такой интерфейс на ЕГО wwan, и DHCP-ребёнок рвал бы аренду
	#      рабочего модема - у того пропадал интернет (отчёт ZBT; воспроизведено на
	#      стенде WH3000: modem2 вынутого SIMCOM сидел на wwan0 Compal). Опускаем
	#      его и снимаем протухший device, чтобы netifd не мог поднять его на чужом
	#      устройстве. Вернётся владелец - ensure_iface впишет device+devpath и поднимет.
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " && continue   # владелец на месте - им займётся ensure_iface
		ifa=$(uci -q get "$CFG.$s.network"); [ -n "$ifa" ] || continue
		case "$(uci -q get "network.$ifa.proto")" in qmi|mbim) ;; *) continue ;; esac
		deva=$(uci -q get "network.$ifa.device"); [ -n "$deva" ] || continue
		owp=$(path_for_wdm "$deva")
		if [ -n "$owp" ] && [ "$owp" != "$p" ]; then
			ifdown "$ifa" >/dev/null 2>&1
			uci -q delete "network.$ifa.device"; uci -q delete "network.$ifa.devpath"; uci -q commit network
			logger -t 5gmodem-resolve "iface $ifa: owner $p absent, device $deva now belongs to $owp - parked to free its wwan"
		fi
	done
	# 2) repair EVERY present modem's interface device (stale after renumbering)
	#    and bring it up if it is down - so all modems reconnect automatically.
	for s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		p=$(uci -q get "$CFG.$s.path")
		[ -n "$p" ] || continue
		echo " $PRESENT " | grep -q " $p " || continue
		ensure_iface "$p" "$s"
		# Пометить чужой интерфейс, прилипший к этому модему через
		# переиспользованную device-ноду (см. orphan_iface_for). Метку читает
		# страница настроек модема и предупреждает пользователя.
		fi_=$(orphan_iface_for "$p")
		if [ -n "$fi_" ]; then
			uci -q set "$CFG.$s.foreign_iface=$fi_"
			logger -t 5gmodem-resolve "modem $p: iface '$fi_' was made for another modem (stale APN/settings)"
		else
			uci -q delete "$CFG.$s.foreign_iface" 2>/dev/null
		fi
	done

	# point the app at the active modem's interface. SEC пересчитываем от $AMP
	# заново (а не полагаемся на значение до цикла ensure_iface выше) - страховка
	# на случай, если какой-нибудь хелпер снова начнёт трогать глобальные имена.
	SEC=$(secname "$AMP")
	# ТОТ ЖЕ ИНВАРИАНТ, ЧТО И В switch (см. выше): network обязан описывать
	# АКТИВНЫЙ модем. Раньше здесь стоял `[ -n "$IF" ] && set`, и у только что
	# воткнутого модема (интерфейса у него ещё нет) network ОСТАВАЛСЯ ОТ ПРЕДЫДУЩЕГО.
	# Живой случай: active_modem=1-1.3 (Telit), а network=modem2 - интерфейс Compal.
	# Основной опрос читает по network IP и статистику, и страница показывала бы
	# сигнал Telit вперемешку с адресом и трафиком Compal. Пусто безопаснее чужого.
	IF=$(uci -q get "$CFG.$SEC.network")
	if [ -n "$IF" ]; then
		uci -q set "$CFG.@5gmodem[0].network=$IF"
	else
		# У АКТИВНОГО МОДЕМА НЕТ СЕКЦИИ (или она без network) - НЕ СНОСИМ РАБОЧУЮ
		# MM-ПРИВЯЗКУ. MM-модем ведёт ModemManager, своей секции-привязки у него
		# часто нет (интерфейс proto=modemmanager завёл мастер/пользователь мимо
		# нашего autosetup). Сносить тут глобальный network значило ломать _via_mm -
		# и SMS/USSD активного MM-модема переставали читаться (живой случай 12.08.2026:
		# SIM7100E, resolve затирал network=modem). Оставляем ТОЛЬКО когда MM-интерфейс
		# ровно один - тогда он однозначно принадлежит активному MM-модему; при
		# нескольких сносим как раньше (чужой опаснее пустого).
		_cur=$(uci -q get "$CFG.@5gmodem[0].network")
		_mmn=$(uci -q show network 2>/dev/null | grep -c "\.proto='modemmanager'")
		if [ -n "$_cur" ] && [ "$_mmn" = "1" ] \
		   && [ "$(uci -q get "network.$_cur.proto")" = "modemmanager" ]; then
			: # единственный MM-интерфейс = интерфейс активного MM-модема, сохраняем
		else
			uci -q delete "$CFG.@5gmodem[0].network" 2>/dev/null
		fi
	fi
	uci -q commit "$CFG"
	rm -f /tmp/modem
	# УБОРКА - ФОНОМ И ПОСЛЕ ВСЕГО. Правила у неё строгие (интерфейс без хозяина
	# либо парковка старше park_ttl_days, по умолчанию 30 дней), но трогает она
	# конфиг, поэтому идёт последней и не задерживает ответ hotplug'у. Выключается
	# одним ключом: 5gmodem.@5gmodem[0].park_ttl_days=0.
	( "$0" cleanup apply >/dev/null 2>&1 & ) >/dev/null 2>&1 </dev/null &
	printf '{"result":"resolved","active":"%s","at_port":"%s"}\n' "$AMP" "$ATP"
	;;

setalias)
	# setalias <usb-путь> [имя] - своё имя модема. Пустое имя (или отсутствие
	# аргумента) снимает его и возвращает автоматическое.
	#
	# ПРИВЯЗКА - К IMEI, ХРАНЕНИЕ - В СЕКЦИИ ПУТИ. Рядом с именем кладём IMEI, с
	# которым его задали: имя ездит вместе с железкой, а не остаётся у разъёма
	# (решение владельца 07.08.2026). Если IMEI не читается или одинаков у всей
	# партии, привязка не сработает - тогда имя останется у секции пути, и это
	# ровно то поведение, которое и нужно в таком случае.
	_sa_p="$2"
	[ -n "$_sa_p" ] || { echo '{"error":"no path"}'; exit 0; }
	_sa_sec="m_$(echo "$_sa_p" | sed 's/[^A-Za-z0-9]/_/g')"
	uci -q get "$CFG.$_sa_sec" >/dev/null 2>&1 || { echo '{"error":"no section"}'; exit 0; }
	shift 2
	_sa_name=$(printf '%s' "$*" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	# ДЛИНУ ОГРАНИЧИВАЕМ: имя рисуется во вкладке и в карточках приоритета, и
	# «поэма» там растянула бы весь ряд. Режем молча - это подпись, а не данные.
	_sa_name=$(printf '%s' "$_sa_name" | cut -c1-32)
	if [ -z "$_sa_name" ]; then
		uci -q delete "$CFG.$_sa_sec.alias" 2>/dev/null
		uci -q delete "$CFG.$_sa_sec.alias_imei" 2>/dev/null
	else
		uci -q set "$CFG.$_sa_sec.alias=$_sa_name"
		_sa_im=$(uci -q get "$CFG.$_sa_sec.imei" 2>/dev/null)
		if [ -n "$_sa_im" ]; then
			uci -q set "$CFG.$_sa_sec.alias_imei=$_sa_im"
		else
			uci -q delete "$CFG.$_sa_sec.alias_imei" 2>/dev/null
		fi
	fi
	uci -q commit "$CFG"
	# Список модемов кэшируется - сбрасываем, иначе вкладка покажет старое имя.
	rm -f /tmp/5gmodem_listmodems.cache 2>/dev/null
	printf '{"ok":1,"alias":"%s"}\n' "$_sa_name"
	;;

mmindex)
	# ModemManager index. Без аргумента - АКТИВНОГО модема (управление
	# диапазонами/режимом всегда о нём), с аргументом - модема по USB-пути.
	#
	# Аргумент появился не для удобства: без него любой вызывающий, который
	# работает НЕ с активным модемом, молча получал чужой индекс. Живой случай -
	# netpri.sh: он опрашивает имя оператора ПОИНТЕРФЕЙСНО, брал индекс активного
	# и складывал ответ в кэш опрошенного. У человека с двумя T99W175 (30.07)
	# из-за этого модем БЕЗ SIM показывал в «Приоритете интернета» оператора
	# соседа - и держал его 30 минут, пока жив кэш.
	mm_index_for_path "${2:-$(active_path)}"
	;;

wdm)
	# cdc-wdm узел модема: с аргументом - ПО ПУТИ, без - активного. Безадресный
	# вызов в адресном опросе метрик писал QMI-дополнения (агрегация, диапазон,
	# соседи, сигнал) ЧУЖОГО модема в липкие файлы /tmp/5gmodem_qmi_<ключ>
	# опрашиваемого - и они раздавались каждым снимком («карточка Telit
	# показывала агрегации Compal», 31.07.2026).
	wdm_for_path "${2:-$(active_path)}"
	;;

forget)
	note_foreign_uci network "modemswitch forget"
	# «Забыть отключённые модемы»: удалить секции модемов, которых нет на шине.
	# ЯВНОЕ действие пользователя - автоматически по отключению так делать нельзя:
	# модем штатно пропадает на минуту при AT+CFUN=1,1 (в т.ч. по нашей команде),
	# и настройки бы терялись на ровном месте.
	# Секцию АКТИВНОГО модема не трогаем: он может как раз перезагружаться.
	# --refresh ОБЯЗАТЕЛЕН: обычный вызов может отдать кэш (до 8 c), а мы по этому
	# списку УДАЛЯЕМ настройки. Устаревший кэш = присутствующий модем сочтётся
	# отсутствующим, и его секция будет стёрта вместе с network/iface_proto/
	# mm_exclude. Цена ошибки несимметрична: лишний раз не забыть - безобидно,
	# забыть работающий модем - потеря настроек.
	PRESENT=" $("$RES/listmodems.sh" --refresh | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ') "
	# Пустой список - это почти наверняка сбой перечисления, а не «модемов нет».
	# Ничего не удаляем: иначе одна осечка стёрла бы настройки ВСЕХ модемов.
	case "$PRESENT" in
		*[!\ ]*) ;;
		*) printf '{"result":"ok","forgotten":0,"note":"no modems enumerated - nothing removed"}\n'; exit 0 ;;
	esac
	AMP=$(active_path)
	N=0
	for SEC in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_[^.=]*\)=modem\$/\1/p"); do
		P=$(uci -q get "$CFG.$SEC.path")
		[ -n "$P" ] || continue
		echo "$PRESENT" | grep -q " $P " && continue
		[ "$P" = "$AMP" ] && continue
		# Страховка: интерфейс этого модема сейчас ПОДНЯТ - значит модем живой, а
		# в перечислении его нет по случайности (переэнумерация/сбой). Забывать
		# рабочий модем нельзя: вместе с секцией уйдут network/iface_proto/
		# mm_exclude, и он потеряется в UI. Именно так эта кнопка однажды стёрла
		# настройки присутствующего модема.
		_if=$(uci -q get "$CFG.$SEC.network")
		if [ -n "$_if" ] && ifstatus "$_if" 2>/dev/null | grep -q '"up": true'; then
			continue
		fi
		# интерфейс модема оставляем в network/firewall: он мог быть настроен
		# вручную, а модем ещё вернётся. Забываем только НАШУ привязку.
		uci -q delete "$CFG.$SEC"
		N=$((N + 1))
	done
	[ "$N" -gt 0 ] && uci -q commit "$CFG"
	printf '{"result":"ok","forgotten":%s}\n' "$N"
	;;

xmm)
	# Перевести АКТИВНЫЙ модем (Fibocom L850/L860, Intel XMM) в режим XMM/NCM:
	# сменить USB-композицию (AT+GTUSBMODE=0) и ребутнуть модем (AT+CFUN=15). Модем
	# переэнумерируется ~40 c в Intel-композицию (8087:095a), после чего поднимаем
	# xmm-прото. В MBIM управление бендами недоступно, в XMM - работает (XACT).
	#
	# proto=xmm помечаем ЗАРАНЕЕ (fix_iface_proto его уважает) - чтобы autosetup при
	# переэнумерации не поставил драйверный fibocom. Финалайзер в фоне досоздаёт
	# интерфейс уже в NCM (mkiface сам выберет ttyACM как dial-port) и поднимает.
	P=$(active_path)
	A=$(uci -q get "$CFG.@5gmodem[0].at_port")
	[ -n "$P" ] && [ -n "$A" ] || { echo '{"error":"no active modem"}'; exit 0; }
	MSEC="m_$(echo "$P" | sed 's/[^A-Za-z0-9]/_/g')"
	# МАРКЕР для autosetup: после переэнумерации в NCM он должен поставить xmm, а НЕ
	# драйверный fibocom (см. want_proto в setup_one_modem). Надёжнее фонового
	# финалайзера: autosetup крутится в procd и не умирает по SIGHUP. Маркер в
	# секции модема переживает переэнумерацию (usb-путь тот же).
	uci -q set "$CFG.$MSEC.want_proto=xmm"; uci -q commit "$CFG"
	# Сменить USB-композицию в NCM и ребутнуть модем. Порт на ребуте отвалится
	# ("I/O error" на tcsetattr) - это норма, ответа не ждём.
	sms_tool -d "$A" at "AT+GTUSBMODE=0" >/dev/null 2>&1
	sms_tool -d "$A" at "AT+CFUN=15" >/dev/null 2>&1
	printf '{"ok":1}\n'
	;;

cleanup)
	# УБОРКА ОСИРОТЕВШИХ ИНТЕРФЕЙСОВ.
	#
	#   cleanup        - только показать, что считается мусором (JSON)
	#   cleanup apply  - снести показанное
	#
	# ЧТО СЧИТАЕТСЯ МУСОРОМ. Интерфейс с НАШИМ штампом (modem_path/modem_imei),
	# у которого НЕТ ХОЗЯИНА: ни одна секция модема - ни живая, ни парковочная -
	# не числит его своим (network=<имя>). Такие остаются после того, как модем
	# в разъёме сменили несколько раз подряд: секция каждый раз заводит новый
	# интерфейс, а прежний повисает в конфиге и в зоне firewall.
	#
	# ЧТО МУСОРОМ НЕ СЧИТАЕТСЯ - и почему список ниже такой строгий:
	#   - интерфейс парковочной секции. Парковка - это «модем вынули, настройки
	#     ждут его возвращения» (park_profile). Снести его = потерять APN, бэнды
	#     и mm_exclude ровно того модема, который человек собирается вернуть;
	#   - интерфейс БЕЗ нашего штампа. Он мог быть создан руками, и трогать чужое
	#     мы не имеем права;
	#   - поднятый интерфейс или интерфейс с адресом. Если он работает, значит у
	#     него есть хозяин, которого мы просто не распознали, - лучше оставить
	#     мусор, чем оборвать связь.
	_cl_apply=""; [ "$2" = apply ] && _cl_apply=1
	_cl_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	# Все интерфейсы, которые числит за собой хоть одна секция (в т.ч. парковка).
	_cl_owned=" $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | tr '\n' ' ') "
	_cl_first=1
	printf '{"orphans":['
	for _cl_i in $(uci show network 2>/dev/null \
			| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p" | sort -u); do
		[ -n "$_cl_i" ] || continue
		case "$_cl_owned" in *" $_cl_i "*) continue ;; esac
		# Живой интерфейс не трогаем ни при каких условиях.
		_cl_up=$(ifstatus "$_cl_i" 2>/dev/null | grep -c '"up": true')
		_cl_ip=$(ifstatus "$_cl_i" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
		[ "$_cl_up" != 0 ] && [ -n "$_cl_ip" ] && continue
		_cl_p=$(uci -q get "network.$_cl_i.modem_path")
		_cl_m=$(uci -q get "network.$_cl_i.modem_imei")
		[ "$_cl_first" = 1 ] || printf ','
		_cl_first=0
		printf '{"iface":"%s","path":"%s","imei":"%s","proto":"%s"}' \
			"$_cl_i" "$_cl_p" "$_cl_m" "$(uci -q get "network.$_cl_i.proto")"
		[ -n "$_cl_apply" ] || continue
		ifdown "$_cl_i" >/dev/null 2>&1
		uci -q delete "network.$_cl_i"
		[ -n "$_cl_z" ] && uci -q del_list "firewall.$_cl_z.network=$_cl_i"
		logger -t 5gmodem "cleanup: removed orphan interface $_cl_i (path ${_cl_p:-?}, IMEI ${_cl_m:-?}) - no owner among modems or parked profiles"
	done
	printf '],"parked":['
	# ПАРКОВКИ, КОТОРЫЕ УЖЕ НИКОГО НЕ ЖДУТ.
	#
	# Осиротевших интерфейсов в реальной жизни почти не бывает - у каждого есть
	# хозяин. Копится другое: на каждый модем, побывавший в разъёме, остаётся
	# парковочный профиль, и он ДЕРЖИТ ЗА СОБОЙ ИНТЕРФЕЙС. Три замены модема в
	# одном порту - три лишних интерфейса в конфиге и в зоне firewall навсегда.
	#
	# Держать их вечно - крайность в одну сторону, чистить сразу - в другую
	# (человек вынул модем на неделю, вернул - настройки на месте, это и есть
	# смысл парковки). Поэтому срок: по умолчанию 30 дней с момента парковки
	# (parked_at пишется при вытеснении), настраивается ключом
	# 5gmodem.@5gmodem[0].park_ttl_days; 0 - не чистить никогда.
	_cl_ttl=$(uci -q get "$CFG.@5gmodem[0].park_ttl_days")
	case "$_cl_ttl" in ''|*[!0-9]*) _cl_ttl=30 ;; esac
	_cl_now=$(date +%s 2>/dev/null); case "$_cl_now" in ''|*[!0-9]*) _cl_now=0 ;; esac
	_cl_pfirst=1
	if [ "$_cl_ttl" != 0 ] && [ "$_cl_now" != 0 ]; then
		for _cl_s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^$CFG\.\(m_park_[^.]*\)=modem\$/\1/p"); do
			_cl_at=$(uci -q get "$CFG.$_cl_s.parked_at")
			case "$_cl_at" in ''|*[!0-9]*) continue ;; esac
			_cl_age=$(( (_cl_now - _cl_at) / 86400 ))
			[ "$_cl_age" -ge "$_cl_ttl" ] || continue
			_cl_pif=$(uci -q get "$CFG.$_cl_s.network")
			_cl_pimei=$(uci -q get "$CFG.$_cl_s.imei")
			[ "$_cl_pfirst" = 1 ] || printf ','
			_cl_pfirst=0
			printf '{"section":"%s","iface":"%s","imei":"%s","days":%s}' \
				"$_cl_s" "$_cl_pif" "$_cl_pimei" "$_cl_age"
			[ -n "$_cl_apply" ] || continue
			# Интерфейс сносим, только если он НАШ и сейчас не работает: за
			# время простоя человек мог настроить его руками под что-то другое.
			if [ -n "$_cl_pif" ] && [ -n "$(uci -q get "network.$_cl_pif.modem_imei")" ] \
			   && [ "$(ifstatus "$_cl_pif" 2>/dev/null | grep -c '"up": true')" = 0 ]; then
				ifdown "$_cl_pif" >/dev/null 2>&1
				uci -q delete "network.$_cl_pif"
				[ -n "$_cl_z" ] && uci -q del_list "firewall.$_cl_z.network=$_cl_pif"
			fi
			uci -q delete "$CFG.$_cl_s"
			# IMEI берём ДО удаления секции - иначе в журнале пустое место.
			logger -t 5gmodem "cleanup: parked profile $_cl_s (IMEI ${_cl_pimei:-?}, $_cl_age days) and its interface ${_cl_pif:-none} removed"
		done
	fi
	printf ']'
	if [ -n "$_cl_apply" ]; then
		uci -q commit "$CFG"
		note_foreign_uci network "modemswitch cleanup"
		uci -q commit network
		uci -q commit firewall
		printf ',"applied":true'
	else
		printf ',"applied":false'
	fi
	printf '}\n'
	;;

*)
	echo "usage: $0 active|switch <path>|save <path>|resolve|forget|cleanup [apply]|mmindex|wdm|xmm" >&2
	exit 1
	;;
esac
