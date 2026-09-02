# HiLink-модемы (веб-API вместо AT): опознание, настройка, перевод в debug.
#
# Часть modemswitch.sh (см. его шапку): сорсится им, самостоятельно НЕ
# запускается. Все функции перенесены 1:1 при распиле большого файла.

is_hilink() {   # $1 - usb-путь
	_ih_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ih_sec.kind")" = "hilink" ] && return 0
	_ih_id=$(modem_vidpid "$1")
	[ -n "$_ih_id" ] || return 1
	for _ih_k in $HILINK_IDS; do
		[ "$_ih_id" = "$_ih_k" ] && return 0
	done
	# СТРУКТУРНЫЙ ПРИЗНАК: модем отдаёт СЕТЕВУЮ КАРТУ, но ни одного AT-порта и
	# ни одного cdc-wdm - управлять им нечем, значит он держит IP-стек сам,
	# т.е. HiLink. Список ID за всеми композициями не поспевает: у 12d1:14db
	# (E8372 / МТС 8211F) его не было, и модем уезжал в обычную ветку -
	# получал proto=fibocom на eth2 и падал с NO_DEVICE, вместо dhcp.
	# Ограничено перечисленными вендорами/устройствами: у прочих «сеть без
	# портов» означает другое (напр. модуль в RNDIS, которым мы всё же
	# управляем по AT).
	# 05c6:90b4 - Android-палки на Qualcomm MDM9600/9610 (PIXLINK/UV310 и
	# клоны): в RNDIS-режиме это роутер со своим NAT (192.168.100.1), без tty
	# и cdc-wdm - HiLink-класс, связь по dhcp на usb0, метрик нет (веб-API не
	# хуавеевский). ВАЖНО: у той же палки есть режим «только модем» (в её
	# веб-морде выключить раздачу WiFi и USB) - тогда она приходит С cdc-wdm
	# (qmi_wwan) под тем же vid:pid, и структурная проверка ниже корректно
	# отправит её НЕ сюда, а обычным путём (QMI). Поэтому именно структура, а
	# не безусловный whitelist (Cudy TR3000, 17-18.08.2026).
	# 19d2:* - ZTE-стики (MF79 и родня): в RNDIS-композиции это сетевая карта
	# со своим NAT (192.168.0.1) без tty и cdc-wdm - HiLink-класс, метрики по
	# goform (hilink.sh, ветка zte). В debug-композиции у них появляются AT-
	# порты, и структурная проверка корректно уводит их обычным путём.
	case "$_ih_id" in
		12d1:*|05c6:90b4|19d2:*)
			_ih_j=$("$RES/listmodems.sh" 2>/dev/null)
			_ih_tty=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null)
			_ih_wdm=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].wdm[*]" 2>/dev/null)
			_ih_net=$(printf '%s' "$_ih_j" | jsonfilter -e "@[@.path=\"$1\"].net[*]" 2>/dev/null)
			[ -z "$_ih_tty" ] && [ -z "$_ih_wdm" ] && [ -n "$_ih_net" ] && return 0
			;;
	esac
	return 1
}

# Сетевая карта HiLink-модема (eth*/usb* через cdc_ether), если есть.
hilink_netdev() {   # $1 - usb-путь
	for _hd in /sys/bus/usb/devices/"$1":*/net/*; do
		[ -e "$_hd" ] || continue
		basename "$_hd"; return 0
	done
	return 1
}

# Интерфейс для модема без портов. Никакого mkiface: у HiLink нет ни AT, ни
# cdc-wdm, дозваниваться некуда - модем держит соединение сам и раздаёт адрес
# по DHCP. Роутеру остаётся обычный dhcp-клиент на его сетевой карте.
setup_hilink() {   # $1 - usb-путь, $2 - сетевое имя (eth3)
	_hp="$1"; _hd="$2"
	_hsec=$(ensure_section "$_hp")
	uci -q set "$CFG.$_hsec.kind=hilink"
	uci -q set "$CFG.$_hsec.netdev=$_hd"
	_hif=$(uci -q get "$CFG.$_hsec.network")
	# ВОЗВРАТ МОДЕМА. Секцию мог очистить swap_cleanup (его вытеснили из порта),
	# но интерфейс при этом СОХРАНЁН за железом по IMEI. Находим свой - и модем
	# поднимается на своём же интерфейсе, без пересоздания и без нового имени
	# (иначе на роутере копились modem/modem2/modem3 от одного и того же модема).
	[ -n "$_hif" ] || _hif=$(iface_for_imei "$(imei_for_path "$_hp")")
	if [ -z "$_hif" ]; then
		# имя по образцу остальных: modem, modem2, ...
		_hn=1; _hif="modem"
		while uci -q get "network.$_hif" >/dev/null 2>&1; do
			_hn=$((_hn + 1)); _hif="modem$_hn"
		done
	fi
	uci -q set "network.$_hif=interface"
	uci -q set "network.$_hif.proto=dhcp"
	uci -q set "network.$_hif.device=$_hd"
	# ОСТАТКИ ЧУЖОГО ПРОТОКОЛА. Интерфейс мог быть создан обычной веткой, пока
	# модем не опознавался как HiLink (см. is_hilink): там лежали apn/pdptype/
	# usbpath от fibocom/qmi. Для dhcp они бессмысленны, а в UI показывались как
	# настройки соединения, которых у HiLink нет - APN задаётся в веб-морде
	# самого модема.
	for _hk in apn pdptype usbpath auth username password devpath allow_roaming; do
		uci -q delete "network.$_hif.$_hk" 2>/dev/null
	done
	# ВТОРИЧНЫЙ АПЛИНК ПО УМОЛЧАНИЮ. Без метрики DHCP-интерфейс получает metric 0 и
	# конкурирует с WAN/WiFi за маршрут по умолчанию (наблюдалось на E3372: интерфейс
	# поднялся с metric 0, трафик не шёл, пока не переключили приоритеты). Ставим 20,
	# как mkiface для обычных модемов; но ТОЛЬКО если метрики ещё нет - иначе на каждом
	# переподключении затирали бы выбор пользователя (см. «Приоритет интернета»).
	[ -n "$(uci -q get "network.$_hif.metric")" ] || uci -q set "network.$_hif.metric=20"
	# Модем вернулся: снимаем «спящее» состояние, выставленное при вытеснении
	# (auto=0), и метку пересоздания от старых конфигов.
	uci -q delete "network.$_hif.auto" 2>/dev/null
	uci -q delete "network.$_hif.modem_stale" 2>/dev/null
	# ШТАМП ВЛАДЕЛЬЦА. mkiface его ставит, а мы идём мимо mkiface (у HiLink нет
	# ни AT-порта, ни cdc-wdm - дозваниваться некуда), и интерфейс оставался
	# ничьим. Из-за этого его нельзя было опознать как свой при следующем
	# подключении, и модем каждый раз получал НОВЫЙ интерфейс: на стенде их
	# накопилось три (modem, modem4, modem5), и все висели в приоритетах.
	# Штампуем И IMEI: по одному лишь пути два разных модема в одном разъёме
	# неразличимы (см. lib.sh). HiLink в переходных композициях IMEI может не
	# отдать - тогда останется только путь, как раньше.
	stamp_iface_owner "$_hif" "$_hp"
	# ЗОНА ФАЕРВОЛА. Без неё интерфейс остаётся «серым»: не в wan, значит нет ни
	# NAT, ни разрешающих правил - клиенты в интернет не выходят, хотя у самого
	# роутера связь есть. Добавляем в ту же зону, где остальные модемы.
	_hz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	if [ -n "$_hz" ]; then
		case " $(uci -q get "firewall.$_hz.network") " in
			*" $_hif "*) ;;
			*) uci -q add_list "firewall.$_hz.network=$_hif"
			   uci -q commit firewall
			   logger -t 5gmodem "hilink: $_hif added to the wan zone" ;;
		esac
	fi
	uci -q set "$CFG.$_hsec.network=$_hif"
	drop_stale_ifaces "$_hp" "$_hif"
	uci -q set "$CFG.$_hsec.iface_proto=dhcp"
	uci -q commit "$CFG"
	ifup "$_hif" >/dev/null 2>&1
	logger -t 5gmodem "hilink: $_hp ($_hd) -> interface $_hif (dhcp)"
	echo "$_hif"
}

# Перевести HiLink-модем в режим с AT-портами (у Huawei это «debug mode»).
#
# ЗАЧЕМ. В обычном режиме такой модем отдаёт только веб-API, где нет ни TAC, ни
# диапазона, ни EARFCN, ни USSD. В режиме debug он показывает ещё и шесть
# последовательных портов, СОХРАНЯЯ при этом сетевую карту и рабочий интернет
# (проверено на E3372: ping и HTTP через него проходят, счётчики трафика растут).
# Тогда модем ведётся обычным путём, наравне с остальными.
#
# Режим НЕ переживает перезагрузку модема, поэтому переключаем при каждом его
# появлении на шине. Управляется галкой at_debug в настройках модема; по
# умолчанию включено, но выключить можно - у кого-то модем настроен под свой
# веб-интерфейс, и менять поведение железа молча нельзя.
# Есть ли у устройства последовательный порт ПРЯМО СЕЙЧАС - по sysfs, без
# процессов и без пересборки общего перечисления. Две формы: ttyUSB* лежит прямо
# в интерфейсе (usb-serial), ttyACM* - в подкаталоге tty (cdc-acm).
_ad_hastty() {   # $1 - usb-путь
	for _ht in /sys/bus/usb/devices/"$1":*/ttyUSB* /sys/bus/usb/devices/"$1":*/tty/tty*; do
		[ -e "$_ht" ] && return 0
	done
	return 1
}

try_at_debug() {   # $1 - usb-путь
	_ad_sec=$(secname "$1")
	[ "$(uci -q get "$CFG.$_ad_sec.at_debug")" = "0" ] && return 1
	# Уже с портами - ничего не делаем.
	[ -n "$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$1\"].tty[0]" 2>/dev/null)" ] && return 1
	# ЖДЁМ ГОТОВНОСТИ ВЕБ-API. Сразу после подключения (cdrom -> HiLink) веб-сервер
	# модема поднимается не мгновенно - секунд 30-40, и вызванный раньше времени
	# mode debug молча не срабатывает. Именно это и ловил хотплаг: модем оставался
	# в HiLink. Ждём, пока probe вернёт hilink:1, и только тогда переключаем.
	_ad_w=0
	while [ "$_ad_w" -lt 25 ]; do
		"$RES/hilink.sh" probe "$1" 2>/dev/null | grep -q '"hilink":1' && break
		sleep 3
		_ad_w=$((_ad_w + 1))
	done
	# Пробуем переключить, до трёх раз: первая команда иногда теряется, пока
	# прошивка достартовывает свои службы.
	_ad_ok=""
	_ad_t=0
	while [ "$_ad_t" -lt 3 ]; do
		"$RES/hilink.sh" mode debug "$1" 2>/dev/null | grep -q '"success":true' && { _ad_ok=1; break; }
		sleep 4
		_ad_t=$((_ad_t + 1))
	done
	[ -n "$_ad_ok" ] || return 1
	logger -t 5gmodem "hilink: $1 switched to debug mode (AT ports exposed)"
	# Порты появляются не мгновенно.
	#
	# ЖДЁМ ПО sysfs, А НЕ ПЕРЕСБОРКОЙ ПЕРЕЧИСЛЕНИЯ. Прежний цикл на каждом шаге
	# СТИРАЛ кэш listmodems и строил его заново: двадцать полных обходов sysfs
	# (по 170 мс) плюс - что хуже - двадцать инвалидаций ОБЩЕГО кэша, из-за
	# которых каждый параллельный читатель (страница, netpri, реестр) платил за
	# пересборку, а мемо в самом modemswitch отдавало «портов нет».
	# Вопрос-то простой: появился ли у ЭТОГО устройства последовательный порт.
	# sysfs отвечает на него глобом, без единого процесса.
	_ad_n=0
	while [ "$_ad_n" -lt 40 ]; do
		sleep 1
		_ad_hastty "$1" && break
		_ad_n=$((_ad_n + 1))
	done
	# Порты есть - вот теперь пересобрать общий список ОДИН раз, чтобы остальные
	# увидели их сразу, а не по истечении TTL.
	"$RES/listmodems.sh" --refresh >/dev/null 2>&1
	# После смены режима передача данных сама не поднимается - включаем.
	"$RES/hilink.sh" connect "$1" >/dev/null 2>&1
	return 0
}
