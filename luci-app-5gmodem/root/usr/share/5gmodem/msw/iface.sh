# Сетевые интерфейсы модемов: создание, владение, протокол, сироты.
#
# Часть modemswitch.sh (см. его шапку): сорсится им, самостоятельно НЕ
# запускается. Все функции перенесены 1:1 при распиле большого файла.

# ModemManager must run if ANY modem interface uses the modemmanager proto (they
# need MM). Creating an mbim/qmi/atc interface used to blindly disable MM and
# thereby break the modemmanager modems -> keep MM's state driven by ALL
# interfaces, not just the one being created.
apply_mm_state() {
	command -v mmcli >/dev/null 2>&1 || return 0
	# Автозапуск сервиса - по КОНФИГУ (есть modemmanager-интерфейсы), а вот
	# запуск/остановка ДЕМОНА - через mmneed.sh: он смотрит ещё и на ШИНУ.
	# Раньше здесь MM поднимался ради интерфейса ОТСУТСТВУЮЩЕГО модема, а
	# mmneed на следующем шаге его гасил - качели на каждом хотплаге (ревью,
	# баг №2). Теперь решение одно на всех.
	_ams_net=$(uci show network 2>/dev/null)
	if printf '%s' "$_ams_net" | grep -q "\.proto='modemmanager'"; then
		/etc/init.d/modemmanager enabled >/dev/null 2>&1 || /etc/init.d/modemmanager enable >/dev/null 2>&1
	elif printf '%s' "$_ams_net" | grep -qE "\.proto='(mbim|qmi)'"; then
		/etc/init.d/modemmanager disable >/dev/null 2>&1
	fi
	/usr/share/5gmodem/mmneed.sh apply >/dev/null 2>&1
}

# repair a modem's interface: re-point its device to the current node for THIS
# modem's stable USB path (cdc-wdm / ttyUSB numbers are unstable), then bring it
# up if the device changed or it is not up. This is what auto-recovers the
# connection after a reboot / modem swap when the pinned device went stale.
ensure_iface() {
	# ВСЕ переменные - local. Без этого функция затирала ГЛОБАЛЬНЫЕ SEC/P/IF
	# вызывающего, а resolve зовёт её в цикле по ВСЕМ присутствующим модемам:
	# после цикла SEC указывала на ПОСЛЕДНИЙ модем цикла, а не на активный, и
	# строка "point the app at the active modem's interface" прописывала в
	# @5gmodem[0].network интерфейс ЧУЖОГО модема (at_port/active_modem при этом
	# оставались от активного). Так секция и разъезжалась на каждой загрузке.
	local P="$1" SEC="$2" IF PROTO CUR NEW CHG MET t tt OWNER _dp _dpo
	IF=$(uci -q get "$CFG.$SEC.network")
	[ -n "$IF" ] || return 0
	uci -q get "network.$IF" >/dev/null 2>&1 || return 0

	# ШТАМП ВЛАДЕЛЬЦА (network.<if>.modem_path, ставит mkiface.sh). Если интерфейс
	# создан для ДРУГОГО модема - не трогаем его. Иначе мы бы своими руками
	# перенаправили device чужого интерфейса на этот модем и подняли его с чужими
	# настройками (APN прежнего оператора) - ровно та беда, от которой штамп и
	# заведён. Пустой штамп = интерфейс из старых версий: считаем своим (миграция
	# в uci-defaults проставит штампы существующим).
	# Владение решается по IMEI (см. lib.sh): два разных модема в одном разъёме
	# по пути неразличимы, и раньше мы бы забрали чужой интерфейс себе.
	if ! iface_owned_by "$IF" "$P" "$(imei_for_path "$P")"; then
		OWNER=$(uci -q get "network.$IF.modem_imei")
		[ -n "$OWNER" ] || OWNER=$(uci -q get "network.$IF.modem_path")
		logger -t 5gmodem-resolve "iface $IF belongs to modem $OWNER, not $P - not touching it"
		# ССЫЛКА НА ЧУЖОЙ ИНТЕРФЕЙС - ОТЦЕПЛЯЕМ, а не живём с ней.
		#
		# Секция могла получить чужой network при ошибочной миграции профиля по
		# неверно прочитанному IMEI (см. ensure_section): у пользователя с
		# четырьмя модемами секция MV31-W уехала на интерфейс Compal, а
		# собственный интерфейс MV31-W осиротел - карточка показывала чужой IP,
		# и починить это можно было только руками. Сам интерфейс не трогаем
		# (он чужой), правим ТОЛЬКО ссылку в своей секции: сперва ищем
		# интерфейс, штампованный НАШИМ железом, иначе очищаем поле - mkiface
		# заведёт/подберёт правильный на следующем шаге.
		_ei_mine=""
		_ei_imei=$(imei_for_path "$P")
		for _ei_c in $(uci -q show network 2>/dev/null \
				| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
			[ "$_ei_c" = "$IF" ] && continue
			if iface_owned_by "$_ei_c" "$P" "$_ei_imei"; then _ei_mine="$_ei_c"; break; fi
		done
		if [ -n "$_ei_mine" ]; then
			uci -q set "$CFG.$SEC.network=$_ei_mine"
			uci -q commit "$CFG"
			logger -t 5gmodem-resolve "секция $SEC ссылалась на чужой $IF - переключил на свой $_ei_mine"
			IF="$_ei_mine"
		else
			uci -q delete "$CFG.$SEC.network"
			uci -q commit "$CFG"
			logger -t 5gmodem-resolve "секция $SEC ссылалась на чужой $IF - ссылку снял, интерфейс будет создан заново"
			return 0
		fi
	fi

	# МИГРАЦИЯ старых конфигов: интерфейс наш, но штампа IMEI на нём ещё нет -
	# проставим сейчас, раз IMEI известен. С этого момента владение решается по
	# железу, и подмена модема в этом разъёме его больше не тронет.
	if [ -z "$(uci -q get "network.$IF.modem_imei")" ]; then
		stamp_iface_owner "$IF" "$P"
	fi

	PROTO=$(uci -q get "network.$IF.proto")
	CUR=$(uci -q get "network.$IF.device")
	NEW=""
	case "$PROTO" in
		mbim|qmi|ncm)     NEW=$(wdm_for_path "$P") ;;
		modemmanager)     NEW=$(readlink -f "/sys/bus/usb/devices/$P" 2>/dev/null) ;;
		atc|xmm)
			# atc И xmm ДОЗВАНИВАЮТСЯ ПО AT-ПОРТУ, а не по каналу управления.
			#
			# xmm стоял выше, в одной строке с mbim/qmi/ncm, и получал сюда
			# cdc-wdm - устройство, которого его обработчик не понимает вовсе
			# (он делает basename и ищет узел в /sys/class/tty). На модеме БЕЗ
			# cdc-wdm это давало пусто, а на модеме С ним (напр. L850-GL в
			# композиции 2cb7:0007) - рабочий интерфейс молча переставлялся на
			# /dev/cdc-wdm0 и падал. Переподвязка случается при возвращении
			# модема и при смене активного, отсюда и «переключил модемы - пропал
			# интернет».
			#
			# atc вдобавок держит свой AT-порт открытым ради URC, поэтому порт
			# обязан отличаться от порта метрик (его и помечает data_at_port).
			if [ -n "$(uci -q get "$CFG.$SEC.data_at_port")" ]; then
				MET=$(uci -q get "$CFG.@5gmodem[0].at_port")
				# ПРОБНИК = ИНСТРУМЕНТ ПРОТОКОЛА. Для xmm порт валидируем тем же
				# gcom probeport.gcom, каким его проверит сам xmm.sh: пробы через
				# sms_tool с ним РАСХОДЯТСЯ - у L850 ttyACM2 отвечал на CGMM (и
				# был выбран), а xmm на нём падал «AT port not answer!» по кругу
				# (Cudy TR3000, 03.08.2026). gcom-а нет - прежний atprobe.
				_rp_gcom=""
				[ "$PROTO" = xmm ] && [ -f /etc/gcom/probeport.gcom ] \
					&& command -v gcom >/dev/null 2>&1 && _rp_gcom=1
				# ЖИВОЙ ПОРТ ДОЗВОНА НЕ ПЕРЕПИНОВЫВАЕМ. Выбор ниже зависит от
				# ТЕКУЩЕГО порта метрик, а тот меняется со сменой активного
				# модема - и порт дозвона флипал между tty при событиях на
				# ЧУЖОМ устройстве (телефон сменил композицию -> resolve ->
				# device у FM350 стал другим -> uci commit + network reload ->
				# рабочий модем передёрнуло; живой лог 03.08.2026 07:40).
				# Пока прежний порт существует, принадлежит ЭТОМУ модему и не
				# совпал с портом метрик - оставляем его, и конфиг не меняется.
				_dp_cur=$(uci -q get "$CFG.$SEC.data_at_port")
				if [ -n "$_dp_cur" ] && [ -c "$_dp_cur" ] && [ "$_dp_cur" != "$MET" ]; then
					for t in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
					         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
						[ -e "$t" ] || continue
						[ "/dev/$(basename "$t")" = "$_dp_cur" ] || continue
						# Для xmm «живость» порта решает gcom: существующий, но
						# негодный пин (ttyACM2 у L850) иначе оставался навечно.
						if [ -n "$_rp_gcom" ]; then
							DEVPORT="$_dp_cur" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || break
						fi
						NEW="$_dp_cur"; break
					done
				fi
				# ДВА ПРОХОДА, КАК В detect.sh: сперва НАСТОЯЩИЙ модемный порт
				# (отвечает моделью на AT+CGMM), и только потом любой отвечающий.
				# Голого AT мало - на многопортовых модемах на него отзываются и
				# вспомогательные порты: живой FM350 отдавал так ttyUSB0, после
				# чего дозвон падал с «AT port not answer!» по кругу.
				[ -n "$NEW" ] || for DPMODE in model at; do
					for t in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
					         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
						[ -e "$t" ] || continue
						tt="/dev/$(basename "$t")"
						[ "$tt" = "$MET" ] && continue
						if [ -n "$_rp_gcom" ]; then
							DEVPORT="$tt" gcom -s /etc/gcom/probeport.gcom >/dev/null 2>&1 || continue
						elif [ "$DPMODE" = model ]; then
							/usr/share/5gmodem/atprobe.sh "$tt" model >/dev/null 2>&1 || continue
						else
							/usr/share/5gmodem/atprobe.sh "$tt" >/dev/null 2>&1 || continue
						fi
						NEW="$tt"; break
					done
					[ -n "$NEW" ] && break
				done
				[ -n "$NEW" ] || NEW=$(uci -q get "$CFG.$SEC.at_port")
				[ -n "$NEW" ] && uci -q set "$CFG.$SEC.data_at_port=$NEW"
			else
				NEW=$(uci -q get "$CFG.$SEC.at_port")
			fi
			;;
		3g|wwan|ppp)      NEW=$(uci -q get "$CFG.$SEC.at_port") ;;
		fibocom)          NEW=$(for n in /sys/bus/usb/devices/$P:*/net/*; do [ -e "$n" ] && { basename "$n"; break; }; done) ;;
	esac
	CHG=0
	if [ -n "$NEW" ] && { [ -e "$NEW" ] || [ -d "/sys/class/net/$NEW" ]; } && [ "$NEW" != "$CUR" ]; then
		uci -q set "network.$IF.device=$NEW"; uci -q commit network; CHG=1
	fi
	# ПРИВЯЗКА К ЖЕЛЕЗУ через стабильный путь (см. mkiface.sh ctrl_devpath).
	# Пиннинг device=/dev/cdc-wdmN нестабилен: после ре-энумерации номер узла
	# указывает на ДРУГОЙ модем, qmi/mbim.sh резолвит его netdev = чужой wwan,
	# DHCP-ребёнок садится на wwan соседа и отпускает ЕГО аренду -> у рабочего
	# модема пропадает инет (отчёт ZBT, два 05c6:9025). devpath = sysfs-путь
	# интерфейса-контроллера, из него системный прото при КАЖДОМ setup находит
	# cdc-wdm заново. Досетапливаем/чиним существующим интерфейсам.
	case "$PROTO" in
		mbim|qmi)
			_dp=$(readlink -f "/sys/class/usbmisc/$(basename "$NEW")/device" 2>/dev/null)
			_dpo=$(uci -q get "network.$IF.devpath")
			if [ -n "$_dp" ] && [ -d "$_dp/usbmisc" ] && [ "$_dp" != "$_dpo" ]; then
				uci -q set "network.$IF.devpath=$_dp"; uci -q commit network; CHG=1
			fi
			;;
	esac
	if [ "$CHG" = 1 ] || ! ifstatus "$IF" 2>/dev/null | grep -q '"up": true'; then
		ifup "$IF" >/dev/null 2>&1
	fi
}

# ИНТЕРФЕЙС-СИРОТА для модема $1: указывает на устройство ЭТОГО модема, но создан
# НЕ для него и не принадлежит ни одной секции модема.
#
# Так выглядит подмена модема, которую swap_cleanup не ловит: он срабатывает на
# смену vid:pid по ТОМУ ЖЕ пути, а если модем воткнули в другой разъём (1-1.3.3 ->
# 1-1.3), для программы это просто новый модем. Интерфейс же старого остаётся и
# висит на device-ноде (/dev/cdc-wdm0), которую ядро отдаёт новому модему - и тот
# молча дозванивается с APN прежнего оператора.
# Сам конфиг НЕ ПРАВИМ: интерфейс мог быть настроен пользователем вручную.
# Только помечаем находку, чтобы показать её в интерфейсе.
# Привести proto интерфейса в соответствие ДРАЙВЕРУ его cdc-wdm устройства.
#
# Интерфейс может остаться от другого модема - имя одно, железо разное.
# Наблюдалось вживую: Compal RXM-G1 (cdc_mbim) подхватил интерфейс от Telit
# LM960A18 (qmi_wwan) вместе с proto=qmi. uqmi на MBIM-устройстве висел
# минутами, netifd писал "Request timed out" и клал интерфейс - модем не
# поднимался вообще, а причина ниоткуда не видна.
#
# Вызывается и при первичной настройке, и при переключении модемов: проверка
# только на первой настройке не починила бы уже сломанные конфигурации.
fix_iface_proto() {   # $1 - имя интерфейса
	_fp_if="$1"
	[ -n "$_fp_if" ] || return
	_fp_pr=$(uci -q get "network.$_fp_if.proto")
	_fp_dev=$(uci -q get "network.$_fp_if.device")
	_fp_drv=""
	case "$_fp_dev" in
		/dev/cdc-wdm*)
			_fp_drv=$(basename "$(readlink -f "/sys/class/usbmisc/$(basename "$_fp_dev")/device/driver" 2>/dev/null)" 2>/dev/null)
			;;
	esac
	case "$_fp_drv" in
		cdc_mbim) _fp_want="mbim" ;;
		qmi_wwan) _fp_want="qmi" ;;
		*)        return ;;
	esac
	[ "$_fp_pr" = "$_fp_want" ] && return
	# Правим ТОЛЬКО заведомо несовместимую пару kernel-протоколов. Всё прочее
	# (modemmanager, xmm, atc, ncm...) - осознанный выбор пользователя, и
	# перебивать его мы не вправе, даже если он выглядит непривычно.
	case "$_fp_pr" in
		mbim|qmi) ;;
		*) return ;;
	esac
	logger -t 5gmodem "iface $_fp_if: proto=$_fp_pr не подходит драйверу $_fp_drv - ставим $_fp_want"
	uci -q set "network.$_fp_if.proto=$_fp_want"
	uci -q commit network
}

orphan_iface_for() {
	local P="$1" IF OWNER DEV NODES n claimed
	NODES=" $(wdm_for_path "$P") "
	for n in /sys/bus/usb/devices/$P:*/ttyUSB* /sys/bus/usb/devices/$P:*/tty/ttyUSB* \
	         /sys/bus/usb/devices/$P:*/ttyACM* /sys/bus/usb/devices/$P:*/tty/ttyACM*; do
		[ -e "$n" ] && NODES="$NODES /dev/$(basename "$n") "
	done
	for n in /sys/bus/usb/devices/$P:*/net/*; do
		[ -e "$n" ] && NODES="$NODES $(basename "$n") "
	done
	for IF in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		DEV=$(uci -q get "network.$IF.device")
		[ -n "$DEV" ] || continue
		echo "$NODES" | grep -q " $DEV " || continue
		# Штамп наш - всё честно. Решаем по IMEI (см. lib.sh): интерфейс модема,
		# вытесненного из этого разъёма, тоже носит наш путь, но чужой IMEI.
		iface_owned_by "$IF" "$P" "$(imei_for_path "$P")" && continue
		# держит ли этот интерфейс какая-нибудь секция модема?
		claimed=$(sec_for_iface "$IF")
		[ -n "$claimed" ] && continue
		# IPv6-БЛИЗНЕЦ НЕ ЧУЖОЙ. Прошивки заводят пару "wwan" (dhcp) и "wwan6"
		# (dhcpv6) НА ОДНОМ И ТОМ ЖЕ устройстве. Секция модема держит только
		# первый, второй формально ничей - и попадал сюда как «интерфейс от
		# другого модема», из-за чего на живом LT300 показывалось пугающее
		# предупреждение о чужих настройках и предложение пересоздать интерфейс.
		# Признак близнеца: имя оканчивается на 6, а интерфейс без этой цифры
		# существует и сидит на том же устройстве. Тот же приём уже применён в
		# netpri.sh, где такая пара удваивала аплинк.
		case "$IF" in
			*6)
				_base=${IF%6}
				if [ "$(uci -q get "network.$_base.device")" = "$DEV" ]; then
					continue
				fi
				;;
		esac
		echo "$IF"; return 0
	done
	return 1
}

# Найти интерфейс, который УЖЕ смотрит на этот модем ($1 = USB-путь).
# Нужен, чтобы не плодить дубли: на роутерах, где модем настроен вендором или
# самим пользователем до установки пакета, интерфейс уже есть и работает
# (у Cudy LT300 это "wwan" на usb0). Создав рядом второй, мы получили бы два
# интерфейса на одном устройстве и войну за маршрут по умолчанию.
#
# Ищем по ФАКТИЧЕСКОМУ устройству, а не по имени: network.<iface>.device может
# быть и сетевым узлом (eth2, usb0), и управляющим (/dev/cdc-wdm0), а у части
# протоколов его нет вовсе - тогда смотрим на поднятый l3_device.
iface_for_path() {
	_want="$1"; [ -n "$_want" ] || return 1
	for _if in $(uci show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface\$/\1/p"); do
		case "$_if" in loopback|lan|wan6) continue ;; esac
		_dev=$(uci -q get "network.$_if.device")
		[ -n "$_dev" ] || _dev=$(ifup_state_dev "$_if")
		[ -n "$_dev" ] || continue
		_p=""
		case "$_dev" in
			/dev/cdc-wdm*)
				_p=$(readlink -f "/sys/class/usbmisc/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
			/dev/tty*)
				_p=$(readlink -f "/sys/class/tty/$(basename "$_dev")/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/ttyUSB[0-9]*$||;s|.*/||;s|:.*||') ;;
			*)
				[ -e "/sys/class/net/$_dev" ] || continue
				_p=$(readlink -f "/sys/class/net/$_dev/device" 2>/dev/null)
				_p=$(echo "$_p" | sed 's|/[0-9]*-[0-9.]*:[0-9.]*$||;s|.*/||') ;;
		esac
		[ "$_p" = "$_want" ] && { echo "$_if"; return 0; }
	done
	return 1
}

# l3_device поднятого интерфейса (для тех, у кого device в конфиге не задан)
ifup_state_dev() {
	ubus call network.interface."$1" status 2>/dev/null \
		| jsonfilter -e '@["l3_device"]' 2>/dev/null
}

# Pick the SMS read storage for the active modem. Incoming messages land in
# different places by modem: many USB modems (e.g. SimCom SIM7100) deliver them
# to ME (modem memory), not SM (SIM) - reading SM then shows an empty inbox and
# the UI complains there is no port. Probe both and prefer the one that holds
# messages; default to ME (the common case). Only sets the value when the user
# has not chosen one, so it never overrides a manual SIM/Memory pick.
set_sms_storage() {
	AT="$1"
	[ -n "$AT" ] && [ -e "$AT" ] || return 0
	command -v sms_tool >/dev/null 2>&1 || return 0
	uci -q get 5gmodem.sms >/dev/null 2>&1 || return 0
	[ -z "$(uci -q get 5gmodem.sms.storage)" ] || return 0
	me=$(sms_tool -d "$AT" -s ME status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	sm=$(sms_tool -d "$AT" -s SM status 2>/dev/null | sed -n 's/.*used:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
	if   [ "${me:-0}" -gt 0 ] 2>/dev/null; then STG=ME
	elif [ "${sm:-0}" -gt 0 ] 2>/dev/null; then STG=SM
	elif [ -n "$me" ]; then STG=ME          # ME supported, just empty
	elif [ -n "$sm" ]; then STG=SM          # only SM answered
	else STG=ME
	fi
	uci -q set "5gmodem.sms.storage=$STG"
	uci -q commit 5gmodem
}

# Убрать НАШИ ЖЕ интерфейсы, оставшиеся от прежних подключений этого модема.
#
# Признак строгий: штамп modem_path совпадает с путём модема, а сам интерфейс
# больше не тот, которым модем пользуется сейчас. Такой интерфейс завели мы, он
# указывает на устройство, которого у модема уже нет, и держать его незачем -
# он лишь висит в firewall-зоне и мозолит глаза в «Приоритете интернета».
#
# ЧУЖОЕ НЕ ТРОГАЕМ: без штампа (интерфейс завёл вендор или пользователь) не
# удаляем ничего - именно поэтому штамп и вводился.
drop_stale_ifaces() {   # $1 - usb-путь модема, $2 - интерфейс, который оставляем
	[ -n "$1" ] || return 0
	_ds_imei=$(imei_for_path "$1")
	_ds_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	for _ds_i in $(uci show network 2>/dev/null | grep -F ".modem_path='$1'" \
			| sed -n "s/^network\.\([^.]*\)\.modem_path=.*/\1/p"); do
		[ "$_ds_i" = "$2" ] && continue
		# НЕ ТРОГАЕМ чужое железо. Путь у интерфейса может совпасть просто потому,
		# что в этом разъёме РАНЬШЕ стоял другой модем: его интерфейс теперь
		# сохранён за ним (штамп IMEI) и ждёт возвращения - снести его значило бы
		# вернуть ровно ту потерю настроек, ради которой всё и затевалось.
		iface_owned_by "$_ds_i" "$1" "$_ds_imei" || continue
		ifdown "$_ds_i" >/dev/null 2>&1
		uci -q delete "network.$_ds_i"
		[ -n "$_ds_z" ] && uci -q del_list "firewall.$_ds_z.network=$_ds_i"
		logger -t 5gmodem "убран осиротевший интерфейс $_ds_i (модем $1 теперь на ${2:-?})"
	done
	uci -q commit network
	uci -q commit firewall
}
