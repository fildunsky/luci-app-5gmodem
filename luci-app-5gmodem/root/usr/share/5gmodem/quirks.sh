#!/bin/sh
#
# База проверенных особенностей модемов (quirks).
#
# Сюда попадает ТОЛЬКО то, что подтверждено на живом железе - не догадки и не
# даташиты. Каждая запись обязана иметь комментарий: какой командой проверено и
# что именно наблюдалось. Пустой ответ = «не проверяли», и тогда приложение
# ничего не навязывает и оставляет текущую настройку.
#
# Файл подключается через `. /usr/share/5gmodem/quirks.sh`.

# --- USSD: слать код обычным текстом (ключ sms_tool -R) ----------------------
#
# sms_tool по умолчанию УПАКОВЫВАЕТ код в GSM7 ("*100#" -> "AA180C3602").
# Часть модемов это не принимает и отвечает ошибкой, хотя с сырой строкой
# работает штатно. Значение подставляется в 5gmodem.sms.ussd при
# переключении модема (см. modemswitch.sh).
#
#   1 - слать сырым текстом (-R)
#   0 - слать упакованным (поведение sms_tool по умолчанию)
#   "" - НЕ ПРОВЕРЯЛИ: настройку не трогаем
#
# $1 = модель (AT+CGMM, напр. "SIMCOM SIM7600E-H"), $2 = vidpid ("1e0e:9001")
ussd_raw_for() {
	case "$1" in
		# SIMCOM SIM7600E-H (1e0e:9001, ревизия LE11B11SIM7600M22).
		# Проверено на живом модеме:
		#   AT+CUSD=1,"AA180C3602",15 (упакованный) -> error: retry operation
		#   AT+CUSD=1,"*100#",15      (сырой)       -> +CUSD: 0,"0412...",72 (UCS2,
		#                                              текст баланса) - работает
		*SIM7600*) echo 1; return ;;
		# SIM7100E - тот же командный набор (CNBP/CNMP), но USSD на нём НЕ
		# проверяли. Оставляем как есть, чтобы не сломать рабочую настройку.
	esac

	case "$2" in
		# Fibocom FM350-GL (0e8d:7127): USSD не работает НИКАК - прошивка
		# заявляет +CUSD (AT+CUSD=? -> (0-2)), но на AT+CUSD=1,... не отвечает ни
		# OK, ни ERROR, ни URC - ни упакованным, ни сырым, ни на одном из двух
		# AT-портов. Причина не в кодировании: модем data-only, SS в прошивке
		# отсутствует. Настройку не трогаем - менять её здесь бессмысленно.
		0e8d:7127|0e8d:7126) return ;;
		# Telit LM960A18 (1bc7:1040) - USSD РАБОТАЕТ, сырой формой. Здесь была
		# обратная запись («SS/voice нет, как у FM350»), и она оказалась неверной:
		# тот замер делался в LTE, где ответ и не мог прийти. `+CREG: 2,1,...,7`
		# тогда прочитали как «CS есть», но 7 - это AcT E-UTRAN, а не домен;
		# голосового канала в LTE нет, пока не сработает CSFB. Отсюда же и
		# «порт залипает»: модем уходит на CSFB в 3G и не успевает ответить за
		# отведённое sms_tool время.
		# Проверено на живом модуле (МегаФон, AT+WS46=22 - UTRAN-only):
		#   AT+CUSD=1,"AA180C3602",15 (упакованный) -> НИЧЕГО
		#   AT+CUSD=1,"*100#",15      (сырой)       -> +CUSD: 2,"3500...",72
		#                                              = «54.76 р. ...» - работает
		#   в LTE тот же сырой запрос -> +CME ERROR: 30 (no network service)
		1bc7:1040) echo 1; return ;;
	esac

	# неизвестный модем - ничего не навязываем
	return
}

# --- USSD: поддерживается ли ВООБЩЕ ------------------------------------------
#
# Отдельно от ussd_raw_for: там вопрос «как слать», здесь - «есть ли смысл».
# Часть модулей data-only: прошивка заявляет +CUSD (AT+CUSD=? -> (0-2)), но на
# сам запрос не отвечает ничем - ни OK, ни ERROR, ни URC. Для пользователя это
# выглядит как зависшая страница, и он винит приложение. Честнее сказать прямо.
#
#   0  - ПОДТВЕРЖДЕНО, что не работает (обоснование - в комментарии записи)
#   "" - не проверяли: ничего не утверждаем, вкладка работает как обычно
#
# Подтверждения см. в ussd_raw_for выше - там записано, чем и как проверяли.
# $1 = модель (AT+CGMM), $2 = vidpid
# --- USSD: нужен ли уход в 3G ------------------------------------------------
#
# USSD ходит по каналу CS, которого в LTE нет. Часть модемов справляется сама
# (CSFB отрабатывает, ответ приходит), и трогать их НЕЛЬЗЯ: уход в 3G и обратно
# стоит около двадцати секунд без связи. Другим CSFB не помогает - им нужен
# честный 3G, иначе ответа не будет никогда.
#
# Отличить заранее нельзя, поэтому здесь только ПРОВЕРЕННОЕ, а по умолчанию
# приложение работает как раньше - обычным запросом, ничего не переключая.
#
#   1  - проверено, что без 3G не отвечает
#   "" - не проверяли: ведём себя обычно
ussd_needs_3g_for() {
	case "$2" in
		# Telit LM960A18: в LTE отдаёт либо +CME ERROR: 30, либо уходит на CSFB и
		# через 30 с возвращает +CUSD: 4 («operation not supported»), теряя по
		# дороге регистрацию. После AT+WS46=22 тот же код отдаёт баланс за
		# секунды - проверено на живом модуле (МегаФон, *100# -> «54.76 р.»).
		1bc7:1040) echo 1; return ;;
	esac
	return
}

ussd_supported_for() {
	case "$2" in
		# Fibocom FM350-GL: перебрана вся матрица (dcs 15/0/без; текст,
		# упакованный GSM7, UCS2-хекс; наборы TE IRA/GSM/UCS2; LTE и 3G с живым
		# CS; слушатель на всех семи портах и sms_tool -D единственным
		# читателем) - всегда OK и тишина. Не сеть и не SIM: с тех же карт на
		# Compal USSD читается. Обхода нет и в железе - композиций у модуля
		# только две, обе RNDIS (AT+GTUSBMODE=? -> (40,41)), MBIM/QMI нет, то
		# есть путь «MBIM под ModemManager» недоступен.
		0e8d:7127|0e8d:7126) echo 0; return ;;
		# Quectel EP06-E / EG06-E: USSD не поддерживается прошивкой - AT+CUSD
		# отвечает OK, ответа сети не бывает, обхода на форуме нет (тема
		# «Агрегация - дорого?», #1055, #11614, #11626; сводка kb/quectel-ep06.md).
		# Только европейская ревизия: за EP06-A свидетельств нет, и vid:pid у
		# них общий - различаем по модели.
		2c7c:0306)
			case "$1" in *EP06-E*|*EG06-E*) echo 0; return ;; esac
			return ;;
		# Telit LM960A18 ЗДЕСЬ БОЛЬШЕ НЕ ЧИСЛИТСЯ: у него USSD работает, см.
		# разбор в ussd_raw_for выше. Плашка «не работает» на его странице была
		# ложной.
	esac
	return
}

# --- SIM-слоты: каким способом их читать/переключать -------------------------
#
# Раньше simslot.sh слал ВСЕМ AT-модемам подряд фибокомовские AT+SIMTYPE? и
# AT+GTDUALSIM (имя SIMTYPE обманчиво: это Fibocom, а не SimCom). Лишние запросы
# в общий AT-порт не бесплатны: они конкурируют с опросом метрик, и ответы
# перепутывались - эхо "AT+SIMTYPE?" однажды попало в имя модема.
#
#   gtdualsim - Fibocom: AT+SIMTYPE? (тип SIM) + AT+GTDUALSIM (слоты 0/1)
#   ceiswitchsim - Compal/SG500M2-X: AT+CEISWITCHSIM (физ. слоты 1/2 + CD-пин)
#   qmi - слоты живут в QMI UIM (qmicli --uim-get-slot-status/--uim-switch-slot),
#         а по AT прошивка их не отдаёт
#   none - слотов нет/не умеет: не спрашивать НИЧЕГО
#   "" - не знаем: прежнее поведение (пробуем по очереди)
#
# $1 = модель (AT+CGMM), $2 = vidpid
sim_slots_via() {
	case "$2" in
		# Telit LM960A18 (1bc7:1040) - Dual SIM Single Standby по даташиту.
		# AT-путь ТУПИКОВЫЙ, проверено живьём: #SIMSELECT/#DUALSIM/#SIMSWITCH -
		# ERROR, а #SIMINCFG (отдаёт "1,0" и "2,0") - это конфигурация пина SIMIN
		# через GPIO, а не выбор слота. Зато QMI UIM отдаёт правду:
		#   qmicli --uim-get-slot-status -> "2 physical slots found",
		#   слот 1 present/active (ICCID виден), слот 2 absent/inactive.
		1bc7:1040) echo simdet; return ;;
		# Telit FN990 (1bc7:1070) - тот же вендор и тот же QMI, слотов два.
		# AT-команд выбора слота у Telit нет (см. выше про LM960), а по AT
		# приложение ничего и не получало: раздел «Слоты SIM» приходил пустым,
		# кнопок не было, и человек, переключивший слот сторонней утилитой,
		# не мог ни увидеть этого, ни вернуть обратно (живой отчёт 05.09.2026,
		# WH3000 Pro: карта исправна, а модем её «не видит»).
		1bc7:1070|1bc7:1077|1bc7:1080) echo qmi; return ;;
		# Fibocom FM350-GL: проверено - AT+GTDUALSIM отдаёт (0-1), AT+SIMTYPE?
		# различает USIM/eSIM. Именно на нём это и писалось.
		0e8d:7127|0e8d:7126) echo gtdualsim; return ;;
		# Sierra EM9190: слоты через AT!UIMS (0=UIM1, 1=UIM2/eSIM), без пароля и
		# без ресета, персистентно (референс 41113480 r14; фидбек Dmitry
		# Korotkov 18.08.2026 - фибокомовских GTDUALSIM/SIMTYPE у Sierra нет,
		# и слоты не читались вовсе).
		# 90d3 - общий PID EM9190/EM9191 (в ядре так и подписан EM9191);
		# 90e3 - EM9291, то же семейство, живьём не проверен.
		1199:90d3|1199:90e3) echo uims; return ;;
		# Compal RXM-G1 (SG500M2-X): ни AT+SIMTYPE?, ни AT+GTDUALSIM не отвечают
		# (проверено); слоты живут за AT+CEISWITCHSIM.
		05c6:90d6) echo ceiswitchsim; return ;;
		# СЕМЕЙСТВО SDX55 (Foxconn T99W175, Thales MV31-W, Dell DW5821e и
		# родня): AT-команд выбора слота у прошивки нет вовсе, а QMI UIM
		# отдаёт всё - проверено 04.08.2026 на живом MV31-W (WH3000 Pro):
		#   2 physical slots found
		#     Physical slot 1: Card status absent,  Slot status active
		#     Physical slot 2: Card status present, Is eUICC: yes, EID 8903...
		# Без этой записи _VIA оставался пустым, разбор уходил в AT-ветку и
		# возвращал пусто: у модема со ВСТРОЕННЫМ eUICC ни слотов, ни кнопки
		# переключения на eSIM не показывалось вовсе.
		# 05c6:90d5 делит идентификатор с ранним прототипом Compal - его
		# отличаем по МОДЕЛИ (тот же признак, что в iscompal.sh) и оставляем
		# ему проверенный ceiswitchsim.
		05c6:90d5)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo ceiswitchsim; return ;;
			esac
			echo qmi; return ;;
		05c6:9025|413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911) echo qmi; return ;;
		# Thales-композиции того же T99W175/MV31-W (AT^CUSTOMER=14/16/33): без
		# записи слоты и кнопка eSIM у них не показывались вовсе (ревью 12.09.2026).
		# 1e2d:00b7 делит с прототипом Compal - отличаем по модели, как 05c6:90d5.
		1e2d:00b7)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo ceiswitchsim; return ;;
			esac
			echo qmi; return ;;
		1e2d:00b3|1e2d:00b8|1e2d:00b9) echo qmi; return ;;
		# Foxconn T99W373 / Thales MV32-W (SDX62). Слоты у модуля есть - паспорт
		# обещает «Dual SIM support with DSSS» и переключение между внешней SIM
		# и встроенным eUICC. AT-команда тоже есть (AT+SWITCH_SLOT, раздел 15.38
		# руководства), и simslot.sh пробует её первой; qmi здесь - тот же
		# запасной путь, что у всего семейства, и он же единственный, который
		# отдаёт СПИСОК слотов с признаком eUICC.
		0489:e0f0) echo qmi; return ;;
		# Quectel EP06-E: AT+QUIMSLOT=? не отвечает (это команда линейки EM12/M.2; по
		# форуму у EC25/EP06 слоты переключает AT+QDSIM - живьём не проверено), но
		# слоты у модуля ЕСТЬ - и QMI их отдаёт («2 physical slots found»,
		# слот 1 с картой, слот 2 пустой), и ModemManager видит два. Проверено на
		# живом модеме 05.08.2026. Поэтому путь именно qmi: под ModemManager
		# сработает mmcli-ветка (она выбирается раньше, по протоколу интерфейса),
		# а в QMI-режиме слоты прочитает qmicli. Объявить «none» было бы неверно
		# вдвойне - слоты есть, просто AT-командой их не спросить.
		2c7c:0306) echo qmi; return ;;
		# Quectel RM520N-GL (2c7c:0801) и родня по набору команд: слоты живут за
		# AT+QUIMSLOT. Чтение «AT+QUIMSLOT?» -> «+QUIMSLOT: 1», запись
		# «AT+QUIMSLOT=1»/«=2» -> OK (форум: живой обмен, плюс переключение
		# туда-обратно лечит отваливающуюся регистрацию у одного из операторов).
		# Без записи simslot.sh перебирал чужие команды - AT^switch_slot,
		# AT+GTDUALSIM, AT!UIMS, AT+CEISWITCHSIM: ни одну из них прошивка не
		# знает, и слоты не читались вовсе, хотя профиль метрик активный слот
		# показывал. (ревью RM520N 13.09.2026, форум 4pda)
		# 2c7c:0800 (RM500Q/RM502Q) и 2c7c:0900 (RG500Q) - та же команда: их
		# профили метрик уже читают AT+QUIMSLOT?, значит у прошивки она есть.
		# EP06 (2c7c:0306) сюда НЕ входит - см. запись выше: у него QUIMSLOT нет.
		2c7c:0800|2c7c:0801|2c7c:0900) echo quimslot; return ;;
	esac
	case "$1" in
		# SIMCOM SIM7600E-H: один SIM-слот. AT+SIMTYPE? молчит (это команда
		# Fibocom), AT+GTDUALSIM тоже - спрашивать нечего, кнопок быть не должно.
		*SIM7600*) echo none; return ;;
	esac
	return
}

# НУЖЕН ЛИ СБРОС МОДЕМА ПОСЛЕ ВКЛЮЧЕНИЯ/ВЫКЛЮЧЕНИЯ ПРОФИЛЯ eSIM.
#
# По SGP.22 eUICC после смены активного профиля выдаёт проактивную команду
# REFRESH, и модем обязан перечитать карту сам. Часть прошивок этого не делает:
# в eUICC профиль уже enabled, а модем продолжает работать со старым - человек
# видит «переключил, но ничего не изменилось». Лечится полным сбросом
# (AT+CFUN=1,1), после которого модем перечитывает профиль с нуля.
#
# Включаем АДРЕСНО, а не всем подряд: сброс стоит модему переэнумерации на USB и
# ~минуты без сети, а там, где REFRESH отрабатывает штатно (FM350-GL - проверено,
# eSIM на нём работает без сброса), это чистый регресс.
#
# Семейство SDX55 (Foxconn T99W175, Thales MV31-W, Dell DW5821e): по чужому
# рабочему стенду на этом же модеме (luci-app-epm) сброс задан ШТАТНЫМ шагом -
# «Reboot Method: AT Command, AT+CFUN=1,1, /dev/ttyUSB2». Повторяем.
# Аргументы те же, что у sim_slots_via: $1 - модель, $2 - vid:pid.
esim_reset_after_switch() {
	case "$2" in
		05c6:90d5)
			# тот же идентификатор носит ранний прототип Compal - его отличаем
			# по модели, как и в sim_slots_via, и сброс ему не навязываем
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo 0; return ;;
			esac
			echo 1; return ;;
		05c6:9025|413c:81d7|413c:81e0|413c:81e4|0489:e0b5) echo 1; return ;;
		1e2d:00b7)
			case "$1" in
				*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*) echo 0; return ;;
			esac
			echo 1; return ;;
		1e2d:00b3|1e2d:00b8|1e2d:00b9) echo 1; return ;;
		# T99W373 / MV32-W: живьём не проверялось, ставим по семейству. Цена
		# ошибки несимметрична: лишний сброс стоит минуты без сети, а нехватка
		# сброса выглядит как «переключил профиль, и ничего не изменилось» -
		# ровно та жалоба, из-за которой запись и появилась.
		0489:e0f0) echo 1; return ;;
	esac
	echo 0
}

# AT-ПОРТ МОДЕМА, КОТОРЫМ ВЛАДЕЕТ ModemManager: ОТДАВАТЬ ЛИ ЕГО НАШЕМУ ОПРОСУ.
#
# Прошивки, у которых чужой AT-обмен параллельно MM роняет сессию данных:
# Foxconn T77W968 = Dell DW5821e / DW5821e-eSIM. Две независимые жалобы с
# одинаковой картиной «связь работает часами, открываю вкладку - линк
# перезапускается»: issue #13 (10.08.2026, проверка владения по факту закрыла
# только случай прото≠modemmanager) и отчёт 12.09.2026 уже на 2.4.68 - там
# интерфейс штатный modemmanager, и адресный опрос страницы (for=<путь>) брал
# AT-порт из реестра без единых ворот. У таких модемов AT под MM выключен,
# карточку наполняет mmcli; температура и несущие возвращаются явным
# mm_at=1 в секции модема (галка «AT-опрос под ModemManager» на вкладке Модем).
# Аргумент - vid:pid.
mm_at_fragile() {
	case "$1" in
		413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4|1bc7:1911) echo 1 ;;
	esac
}

# Индекс модема в ModemManager по usb-пути, минутный кэш общий с mm_owns_path.
_mm_index_cached() {
	_mic_c="/tmp/5gmodem_mmowns_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	_mic_i=""
	if [ -s "$_mic_c" ] && [ -n "$(find "$_mic_c" -mmin -1 2>/dev/null)" ]; then
		read -r _mic_i < "$_mic_c" 2>/dev/null
	else
		_mic_i=$(/usr/share/5gmodem/modemswitch.sh mmindex "$1" 2>/dev/null)
		printf '%s\n' "${_mic_i:-none}" > "$_mic_c" 2>/dev/null
	fi
	[ "$_mic_i" = "none" ] && _mic_i=""
	echo "$_mic_i"
}

# ВЫДЕЛЕННЫЙ AT-ПОРТ ХРУПКОГО МОДЕМА ПОД ModemManager.
#
# У DW5821e два AT-порта, и MM забирает оба. Наш опрос в любой из них
# перебивает команды MM, и тот рвёт сессию - поэтому AT таким модемам под MM
# был запрещён. Находка владельца DW5821e 413c:81e0 (17.09.2026): если один из
# двух портов скрыть от MM, опрос в нём сессию не трогает, и температура с
# несущими возвращаются без риска.
#
# Как это устроено:
#   1. Пока порт не выбран, смотрим список портов модема у MM. Если MM сам
#      признал AT-портами ДВА и больше tty, запоминаем номер USB-интерфейса
#      последнего (mm_at_if) и vid:pid (mm_at_vp) в секции модема. Сейчас
#      ничего не трогаем - сессия не рвётся.
#   2. При следующем появлении портов на шине (перезагрузка, переподключение)
#      hotplug tty/26-5gmodem-mmreserve сразу после события MM отзывает этот
#      порт: MM 1.24 выбрасывает порт, который ещё ждёт опроса или опрашивается,
#      без пересборки модема.
#   3. Порт отдаём опросу, только пока MM его ДЕЙСТВИТЕЛЬНО не держит (нет в
#      его списке портов модема).
# Модем с одним AT-портом, любой другой модем и модем не под MM не затронуты.
# $1 - usb-путь, $2 - секция, $3 - vid:pid. Печатает /dev/tty... или ничего.
_mm_ports_cached() {   # $1 - usb-путь, $2 - индекс MM
	_mpc_c="/tmp/5gmodem_mmports_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ -s "$_mpc_c" ] && [ -n "$(find "$_mpc_c" -mmin -1 2>/dev/null)" ]; then
		cat "$_mpc_c" 2>/dev/null
		return 0
	fi
	mmcli -m "$2" -K 2>/dev/null \
		| sed -n 's/^modem\.generic\.ports\.value\[[0-9]*\] *: *\([^ ]*\) *(\(.*\))$/\1 \2/p' > "$_mpc_c.$$"
	mv -f "$_mpc_c.$$" "$_mpc_c" 2>/dev/null
	cat "$_mpc_c" 2>/dev/null
}

_tty_ifnum() {   # $1 - имя tty; печатает "<usb-путь> <bInterfaceNumber>"
	_ti_d=$(readlink -f "/sys/class/tty/$1/device" 2>/dev/null)
	[ -n "$_ti_d" ] || return 1
	[ -f "$_ti_d/bInterfaceNumber" ] || _ti_d=${_ti_d%/*}
	[ -f "$_ti_d/bInterfaceNumber" ] || return 1
	_ti_p=${_ti_d##*/}; _ti_p=${_ti_p%%:*}
	echo "$_ti_p $(cat "$_ti_d/bInterfaceNumber" 2>/dev/null)"
}

mm_dedicated_at() {
	[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] || return 0
	[ "$(uci -q get "5gmodem.$2.no_at" 2>/dev/null)" = "1" ] && return 0
	_mda_nif=$(uci -q get "5gmodem.$2.network")
	[ "$(uci -q get "network.$_mda_nif.proto" 2>/dev/null)" = "modemmanager" ] || return 0
	command -v mmcli >/dev/null 2>&1 || return 0
	_mda_i=$(_mm_index_cached "$1")
	[ -n "$_mda_i" ] || return 0
	_mda_ports=$(_mm_ports_cached "$1" "$_mda_i")
	[ -n "$_mda_ports" ] || return 0
	_mda_if=$(uci -q get "5gmodem.$2.mm_at_if")
	if [ -z "$_mda_if" ] || [ "$(uci -q get "5gmodem.$2.mm_at_vp")" != "$3" ]; then
		_mda_at=$(echo "$_mda_ports" | awk '$2 == "at" && $1 ~ /^tty/ { print $1 }')
		[ "$(echo "$_mda_at" | grep -c .)" -ge 2 ] || return 0
		_mda_t=$(echo "$_mda_at" | tail -n 1)
		set -- "$1" "$2" "$3" $(_tty_ifnum "$_mda_t")
		[ "$4" = "$1" ] && [ -n "$5" ] || return 0
		if exec 6>/tmp/5gmodem_ucitx.lock 2>/dev/null && flock -n 6; then
			uci -q set "5gmodem.$2.mm_at_if=$5"
			uci -q set "5gmodem.$2.mm_at_vp=$3"
			uci -q commit 5gmodem 2>/dev/null
			flock -u 6
			logger -t 5gmodem "mm-at: $1 has two AT ports under ModemManager - $_mda_t (interface $5) will be kept for metrics from the next reconnect" >/dev/null 2>&1
		fi
		return 0
	fi
	for _mda_d in /sys/bus/usb/devices/"$1":*; do
		[ "$(cat "$_mda_d/bInterfaceNumber" 2>/dev/null)" = "$_mda_if" ] || continue
		for _mda_n in "$_mda_d"/ttyUSB* "$_mda_d"/tty/tty*; do
			[ -e "$_mda_n" ] || continue
			_mda_n=${_mda_n##*/}
			[ -c "/dev/$_mda_n" ] || continue
			echo "$_mda_ports" | awk -v t="$_mda_n" '$1 == t { f = 1 } END { exit !f }' && return 0
			echo "/dev/$_mda_n"
			return 0
		done
	done
	return 0
}

# Этот tty надо прятать от ModemManager? $1 - имя tty. Код 0 = да.
# Зовут hotplug-обработчик и повторные репорты портов в mm-inhibit.sh.
mm_tty_reserved() {
	set -- "$1" $(_tty_ifnum "$1")
	[ -n "$3" ] || return 1
	_mtr_s="m_$(echo "$2" | sed 's/[^A-Za-z0-9]/_/g')"
	_mtr_if=$(uci -q get "5gmodem.$_mtr_s.mm_at_if")
	[ -n "$_mtr_if" ] && [ "$_mtr_if" = "$3" ] || return 1
	[ -f "/sys/bus/usb/devices/$2/idVendor" ] || return 1
	_mtr_vp="$(cat "/sys/bus/usb/devices/$2/idVendor"):$(cat "/sys/bus/usb/devices/$2/idProduct")"
	[ "$(uci -q get "5gmodem.$_mtr_s.mm_at_vp")" = "$_mtr_vp" ] || return 1
	[ -n "$(mm_at_fragile "$_mtr_vp")" ] || return 1
	[ "$(uci -q get "5gmodem.$_mtr_s.no_at" 2>/dev/null)" = "1" ] && return 1
	_mtr_nif=$(uci -q get "5gmodem.$_mtr_s.network")
	[ "$(uci -q get "network.$_mtr_nif.proto" 2>/dev/null)" = "modemmanager" ]
}

# $1 - usb-путь, $2 - секция. Код 0 = AT-порт брать можно, 1 = нельзя (MM ещё
# поднимает сессию), 2 = нельзя из-за хрупкой прошивки (постоянно, не состояние).
#   mm_at=1 в секции      - можно всегда: воля владельца, любая прошивка;
#   хрупкая прошивка      - нельзя (см. mm_at_fragile);
#   остальные             - только при УЖЕ установленной сессии: срывается
#                           именно enable/connect (см. detect.sh), а без порта
#                           пропадают метрики, которых у mmcli нет (температура,
#                           несущие, антенны) - ради них профили MBIM/QMI и писались.
# Самодостаточна нарочно: bands.sh зовёт её ДО подключения lib.sh. Индекс MM
# берётся из того же минутного кэша, что у mm_owns_path (lib.sh) и bands.sh.
#
# При коде 0 переменная MM_AT_PORT может содержать ВЫДЕЛЕННЫЙ порт (см.
# mm_dedicated_at) - вызывающий обязан взять его вместо порта из реестра.
mm_at_allowed() {
	MM_AT_PORT=""
	_maa_vp=""
	[ -n "$1" ] && [ -f "/sys/bus/usb/devices/$1/idVendor" ] && \
		_maa_vp="$(cat "/sys/bus/usb/devices/$1/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$1/idProduct" 2>/dev/null)"
	if [ -n "$(mm_at_fragile "$_maa_vp")" ]; then
		MM_AT_PORT=$(mm_dedicated_at "$1" "$2" "$_maa_vp")
		[ -n "$MM_AT_PORT" ] && return 0
	fi
	[ "$(uci -q get "5gmodem.$2.mm_at" 2>/dev/null)" = "1" ] && return 0
	[ -n "$(mm_at_fragile "$_maa_vp")" ] && return 2
	_maa_if=$(uci -q get "5gmodem.$2.network" 2>/dev/null)
	case "$(uci -q get "network.$_maa_if.proto" 2>/dev/null)" in
		mbimp)
			ubus call "network.interface.$_maa_if" status 2>/dev/null | grep -q '"up": true'
			return $? ;;
	esac
	command -v mmcli >/dev/null 2>&1 || return 1
	_maa_i=$(_mm_index_cached "$1")
	[ -n "$_maa_i" ] || return 1
	[ "$(mmcli -m "$_maa_i" -K 2>/dev/null \
		| sed -n 's/^modem\.generic\.state *: *//p' | head -1)" = "connected" ]
}
