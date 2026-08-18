#!/bin/sh

# ЦЕЛЕВОЙ МОДЕМ. У каждого модема СВОИ слоты, поэтому показывать и переключать
# надо слоты ИМЕННО той вкладки, что открыл пользователь, а не «активного»
# аплинка (на многомодемном роутере это РАЗНЫЕ модемы). UI передаёт usb-путь
# вкладки аргументом for=<путь>; без него берём активный модем (совместимость с
# вызовами из скриптов и кроном). Путь вырезаем из аргументов, чтобы дальше
# $1=верб (status|set|refresh), $2=номер слота - как раньше.
_TGT=""; _args=""
for _a in "$@"; do
	case "$_a" in
		for=*) _TGT="${_a#for=}" ;;
		*)     _args="$_args $_a" ;;
	esac
done
# usb-путь и верб/номер - простые токены без пробелов, поэтому пересборка
# позиционных через словоделение безопасна.
# shellcheck disable=SC2086
set -- $_args
[ -n "$_TGT" ] || _TGT=$(uci -q get 5gmodem.@5gmodem[0].active_modem)

# У модема без AT-портов слотами управлять нечем: команды переключения - AT.
# Без этой проверки страница показывала «SIM / eSIM» у односимочного Huawei,
# потому что в секции оставались slot_type_* от прежнего модема на том же порту.
# Переключаем слот - СБРАСЫВАЕМ КЭШ активного слота у опроса метрик
# (5gmodem.sh держит ответ минуту, чтобы не звать qmicli на каждом тике).
# Делаем это ДО всех развилок: веток "set" в скрипте три - по одной на транспорт
# (AT, QMI/UIM и путь для модемов без слотов), и вставка в одну из них покрывала
# бы только часть модемов. Проверено: правка только в AT-ветке кэш не сбрасывала.
# Смена слота меняет и кэш метрик (5gmodem_slot_*), и наш кэш СПИСКА слотов
# (5gmodem_slots_* - у него меняется поле active). Глоб slot_* НЕ ловит slots_*
# (после slot идёт 's', а не '_'), поэтому чистим оба явно.
#
# И band-МАРКЕРЫ: смена SIM = переэнумерация модема по USB, а FM350 при этом
# сбрасывает маску диапазонов на все, как при перезагрузке. Прото применяет
# сохранённые бенды РАЗ за загрузку (маркер bandsprep), поэтому без сброса он бы
# пропустил переприменение, и новая SIM поднялась бы на всех диапазонах. Чистим -
# следующий подъём после переэнумерации применит сохранённый набор (как на ребуте).
[ "$1" = "set" ] && rm -f /tmp/5gmodem_slot_* /tmp/5gmodem_slots_* \
	/tmp/5gmodem_bandsprep_* /tmp/5gmodem_bandrestore_* \
	/tmp/5gmodem_metrics_* 2>/dev/null
# Снапшот-кэш метрик ключуется по USB-пути модема, а НЕ по SIM: при eSIM<->SIM путь
# тот же, и cache-first fast-path отдавал бы СТАРЫЙ снимок (оператор, сота, ID
# базовой станции от прежней SIM), пока не пройдёт полный опрос - у пользователя
# «ID базовой станции не появлялся, пока вручную не перезагрузил страницу». Чистим
# метрики вместе со слот-кэшами, чтобы следующий опрос собрал соту новой SIM.

# 'refresh' = 'status', выполненный РАДИ ОБНОВЛЕНИЯ КЭША в фоне (вывод отбрасывает
# вызвавший). Ремапим в status, чтобы обслужили те же ветки; флаг _REFRESH не даёт
# cache-first fast-path'у ниже снова уйти в кэш и зациклить фоновые обновления.
# УЗЛОМ ВЛАДЕЕТ ЖИВОЙ umbim? Штатный прото mbim открывает /dev/cdc-wdmN НАПРЯМУЮ,
# без прокси, и второго хозяина не переживает: наш mbimcli (хоть прямой, хоть -p,
# поднимающий mbim-proxy) отбирает канал, umbim получает «mbim message timeout»,
# и связь у человека рвётся. Тот же гейт давно стоит в esim.sh - здесь его не
# было, а слоты опрашиваются при каждом показе карточки.
# Смотрим И proto, И то, что интерфейс реально поднят: на опущенном узел свободен.
_umbim_owns_wdm() {   # $1 - узел /dev/cdc-wdmN
	[ -n "$1" ] || return 1
	for _uo in $(uci show network 2>/dev/null | sed -n "s|^network\.\([^.]*\)\.device='$1'\$|\1|p"); do
		[ "$(uci -q get "network.$_uo.proto")" = "mbim" ] || continue
		ubus call "network.interface.$_uo" status 2>/dev/null \
			| grep -q '"up": true' && return 0
	done
	return 1
}

_REFRESH=""
[ "$1" = "refresh" ] && { _REFRESH=1; set -- status; }

_ss_am="$_TGT"
# У модемов этого класса слот ФИЗИЧЕСКИ ОДИН - независимо от того, открыты у
# него AT-порты или нет. Ответ на AT-пробу у них при этом бывает вводящим в
# заблуждение: E3372 отвечает так, будто у него есть и SIM1, и eSIM.
_ss_sec="m_$(echo "$_ss_am" | sed 's/[^A-Za-z0-9]/_/g')"
if [ -n "$_ss_am" ] && [ "$(uci -q get "5gmodem.$_ss_sec.kind")" = "hilink" ]; then
	echo '{"slots":[],"active":""}'
	exit 0
fi

# CACHE-FIRST для status. Слоты меняются ТОЛЬКО при
# физической замене SIM или через ветку set (она чистит кэш), поэтому свежий кэш
# отдаём МГНОВЕННО - без mmindex, без порта, без очереди at_lock. Это и убирает
# синхронное ожидание порта при холодном открытии страницы. Фонового обновления
# НЕ делаем: данные не «протухают» сами по себе (только по действию пользователя,
# а оно чистит кэш), а обновление на каждый показ грузило бы порт впустую. Ключ
# кэша - тот же сырой путь модема, что у веток ниже.
if [ "$1" = "status" ] && [ -z "$_REFRESH" ]; then
	_SF="/tmp/5gmodem_slots_$_ss_am"
	_SFT=$(cat "$_SF.t" 2>/dev/null)
	_SNOW=$(cut -d. -f1 /proc/uptime)
	_SFRESH=""
	case "$_SFT" in
		''|*[!0-9]*) : ;;
		*) [ -s "$_SF" ] && [ "$(( _SNOW - _SFT ))" -lt 300 ] && _SFRESH=1 ;;
	esac
	if [ -n "$_SFRESH" ]; then
		cat "$_SF"
		exit 0
	fi
	# КЭША НЕТ ИЛИ ОН ПРОТУХ - ОБНОВЛЯЕМ ФОНОМ, А ОТВЕЧАЕМ СРАЗУ.
	#
	# Синхронное чтение здесь стоило до 20 c и чаще всего возвращало ПУСТО:
	# канал модема занимает опрос метрик (он идёт раз в ~5 c), и qmicli просто
	# не пролезает. Снаружи это выглядело хуже всего: страница «Сеть» вязла на
	# старте, кнопки SIM/eSIM не появлялись, а обновление страницы попадало в тот
	# же цикл - метрики опять заняли канал (живой случай 04.08.2026, MV31-W без
	# карты). Отдаём что есть немедленно, а свежее подтянет следующий тик: он
	# идёт каждые несколько секунд и увидит уже готовый кэш.
	# Гард по времени - чтобы тики не наплодили обновлений: одно в 60 c.
	# Дескрипторы отвязываем НА САМОМ subshell, иначе rpcd будет ждать
	# унаследованный stdout все те же 20 c, и вся затея теряет смысл.
	_SLK="$_SF.upd"
	_SLKT=$(cat "$_SLK" 2>/dev/null)
	_SRUN=1
	case "$_SLKT" in
		''|*[!0-9]*) : ;;
		*) [ "$(( _SNOW - _SLKT ))" -lt 60 ] && _SRUN="" ;;
	esac
	if [ -n "$_SRUN" ]; then
		printf '%s\n' "$_SNOW" > "$_SLK"
		# Фоновое обновление ТОГО ЖЕ модема: без for= дочерний вызов взял бы
		# активный, и кэш чужой вкладки не обновился бы никогда.
		( /usr/share/5gmodem/simslot.sh refresh for="$_ss_am" ) >/dev/null 2>&1 </dev/null &
	fi
	if [ -s "$_SF" ]; then
		cat "$_SF"
		exit 0
	fi
	printf '{"type":"","slots":[],"active":""}\n'
	exit 0
fi
#
# Тип SIM и слоты активного модема (для окна «Меню SIM-карты»).
#
#   simslot.sh status      -> {"type":"USIM|eSIM|","slots":[{"id":..,"label":..}...],"active":"<id>"}
#   simslot.sh set <id>    -> переключить активный слот
#
# Два источника:
#  - модем под ModemManager: mmcli primary-sim-slot / sim-slots (слоты 1..N),
#    переключение mmcli --set-primary-sim-slot;
#  - AT-модем (напр. Fibocom FM350): AT+GTDUALSIM (слоты 0/1) и AT+SIMTYPE
#    (0 USIM / 1 eSIM, мануал 3.15). Числовые метки берём 0-based (SIM0/SIM1) -
#    как id слота и как строка «SIM Slot» в метриках (@.active), чтобы кнопки и
#    попап показывали ОДНУ нумерацию. (Мануал FM350 4.3 зовёт их SIM1/SIM2, но
#    физически первый слот у прошивки - 0, и рассинхрон путал.)
# Кнопки показываются, только если слотов >= 2.

MI=$(/usr/share/5gmodem/modemswitch.sh mmindex "$_TGT" 2>/dev/null)

# mmcli-путь выбираем по ПРОТОКОЛУ интерфейса активного модема, а не по
# наличию модема в MM: kernel-proto модем (напр. FM350/fibocom) MM успевает
# заново зарегистрировать после каждого USB-переперечисления (пока mm-inhibit
# его не отпустит), и слепой mmindex уводил запрос к полумёртвому MM-объекту.
_AP="$_TGT"

# СВЕЖИЙ ОТВЕТ ОТДАЁМ ИЗ КЭША.
#
# Кэш тут был, но служил только запасным вариантом при неудачном опросе -
# успешный путь каждый раз шёл в порт. А стоит он дорого: замер на стенде -
# 5 секунд, из них 2 с только ожидание очереди к AT-порту, занятому опросом
# метрик.
#
# Состав слотов и активный слот меняются лишь когда их переключает пользователь
# (ветка set сама чистит кэш) или когда меняется модем (ключ кэша - его
# USB-путь). Держать ответ полминуты безопасно, а страница перестаёт ждать.
if [ "$1" != "set" ] && [ -n "$_AP" ] && [ -s "/tmp/5gmodem_slots_$_AP" ]; then
	_sc_t=$(cat "/tmp/5gmodem_slots_$_AP.t" 2>/dev/null)
	case "$_sc_t" in
		''|*[!0-9]*) : ;;
		*) _sc_age=$(( $(cut -d. -f1 /proc/uptime) - _sc_t ))
		   if [ "$_sc_age" -ge 0 ] && [ "$_sc_age" -lt 30 ]; then
			cat "/tmp/5gmodem_slots_$_AP"; exit 0
		   fi ;;
	esac
fi

_SEC=$(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.]*\)\.path='$_AP'\$/\1/p" | head -1)
_NET=$(uci -q get "5gmodem.$_SEC.network")
_PROTO=$(uci -q get "network.$_NET.proto")
case "$_PROTO" in
	modemmanager) ;;                    # MM-модем -> mmcli-путь ниже
	"") [ -n "$MI" ] || MI="" ;;        # конфиг не найден -> прежняя эвристика
	*) MI="" ;;                         # kernel-proto -> только AT-путь
esac

# Compal RXM-G1 (SG500M2-X) - ИСКЛЮЧЕНИЕ: даже под ModemManager слоты берём по AT.
# У этой прошивки MM отдаёт НЕВЕРНУЮ картину слотов (залипает на SIM2, показывает
# активной пустую), а +CEISWITCHSIM даёт правду - включая факт наличия карты по
# CD-пину. Управление слотами через mmcli на ней тоже не работает, так что
# mmcli-путь здесь бесполезен в обе стороны.
_AVIDPID=""; _APROD=""
if [ -n "$_AP" ]; then
	_AJ=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null)
	_AVIDPID=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].vidpid" 2>/dev/null)
	_APROD=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].product" 2>/dev/null)
fi

# ОДНОСИМОЧНЫЙ МОДЕМ - НЕТ КНОПОК СЛОТОВ НИ ПРИ КАКОМ ПРОТОКОЛЕ.
#
# Проверка sim_slots_via=none стояла ТОЛЬКО в QMI-ветке, а под ModemManager
# показывались слоты, которые рапортует сам MM. Прошивка SIM7600E-H отдаёт в
# QMI/MM ДВА физических слота, хотя рабочий один - и пользователь, переключившись
# на пустой слот 2, терял сеть. Гейт должен быть общим: если модель заведомо
# односимочная, слотов нет и под MM.
# qmi_channel_free - см. lib.sh (канал cdc-wdm может принадлежать netifd).
. /usr/share/5gmodem/lib.sh 2>/dev/null
. /usr/share/5gmodem/quirks.sh
if [ "$1" != "set" ] \
   && [ "$(sim_slots_via "$(uci -q get "5gmodem.$_SEC.model") $_APROD" "$_AVIDPID")" = none ]; then
	echo '{"type":"","slots":[],"active":""}'; exit 0
fi
# Раньше здесь стоял СПИСОК VID:PID (только 05c6:90d6 и 05c6:90d5). Этого не
# хватало: тот же модем в композиции QMI приходит как 1e2d:00b7 или 05c6:9025,
# в списке их не было - и слоты снова читались из MM, т.е. неверно. Плюс для
# 05c6:9025 проверка по дескриптору бесполезна (там generic "HSUSB Device").
# Теперь признак один на все композиции - см. iscompal.sh.
. /usr/share/5gmodem/iscompal.sh
if is_compal "$_AP" "" "$(uci -q get "5gmodem.$_SEC.at_port")"; then
	MI=""
fi

# ---- ModemManager-модем -----------------------------------------------------
if [ -n "$MI" ]; then
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		if mmcli -m "$MI" --set-primary-sim-slot="$2" >/dev/null 2>&1; then
			echo '{"result":"ok"}'
			exit 0
		fi
		# Переключить через MM не вышло - НЕ сдаёмся: ниже есть вендорный путь
		# (AT^switch_slot) и QMI, они работают там, где mmcli отказывает.
		# Раньше здесь общий exit заканчивал работу отказом.
		logger -t 5gmodem "slots: ModemManager did not switch the slot - trying directly"
		;;
	*)
		K=$(mmcli -m "$MI" -K 2>/dev/null)
		N=$(echo "$K" | sed -n 's/^modem\.generic\.sim-slots\.length *: *//p' | tr -dc 0-9)
		ACT=$(echo "$K" | sed -n 's/^modem\.generic\.primary-sim-slot *: *//p' | tr -dc 0-9)
		OUT=""
		# ОДИН СЛОТ - ЭТО ОТВЕТ, А НЕ ОТКАЗ.
		#
		# Список ниже строится только при двух и более слотах, а иначе мы уходили в
		# фолбэк «спрашиваю модем напрямую» - то есть лезли в канал, которым владеет
		# MM, ради данных, которые MM уже дал. У модема с единственным слотом
		# переключать нечего, поэтому честно отдаём его и выходим: меньше лишних
		# заходов в занятый канал - меньше поводов для гонок.
		#
		# Замечено при разборе отчёта 06.08.2026 (DW5821e под ModemManager): MM
		# видел ОДИН слот, а мы считали это неудачей и шли к модему. Что именно
		# сломало там связь, на нашем железе воспроизвести НЕ удалось (EP06,
		# переведённый в MBIM под MM, три раза подряд пережил такой запрос без
		# последствий - при контрольной серии без запросов результат тот же).
		if [ -n "$N" ] && [ "$N" = 1 ] 2>/dev/null; then
			_SP1=$(echo "$K" | sed -n 's/^modem\.generic\.sim-slots\.value\[1\] *: *//p')
			_PR1=1; case "$_SP1" in ''|'/'|'--') _PR1=0 ;; esac
			printf '{"type":"","slots":[{"id":"1","label":"SIM1","present":"%s"}],"active":"1"}\n' "$_PR1" \
				> "/tmp/5gmodem_slots_$_ss_am"
			cut -d. -f1 /proc/uptime > "/tmp/5gmodem_slots_$_ss_am.t"
			cat "/tmp/5gmodem_slots_$_ss_am"
			exit 0
		fi
		if [ -n "$N" ] && [ "$N" -ge 2 ] 2>/dev/null; then
			L_ALL=""; P_ALL=""
			i=1
			while [ "$i" -le "$N" ]; do
				# тип слота напрямую из SIM-объекта (MM >= 1.20: sim-type
				# physical/esim); для пустого слота ("/") тип неизвестен
				LBL="SIM$i"
				SP=$(echo "$K" | sed -n "s/^modem\.generic\.sim-slots\.value\[$i\] *: *//p")
				# ПУСТОЙ СЛОТ MM ОБОЗНАЧАЕТ ПУТЁМ "/" - И ЭТО НАДО ОТДАВАТЬ НАРУЖУ.
				#
				# Поле present страница уже умеет читать (гасит кнопку пустого
				# слота, чтобы переключение не оставило модем без SIM), но
				# заполняла его только QMI-ветка. Под ModemManager обе кнопки
				# выглядели одинаково рабочими.
				#
				# Живой отчёт (два T99W175 на ZBT, 30.07): у модема без карты MM
				# отдал sim-slots.length=2, primary-sim-slot=1 и ОБА пути "/",
				# то есть «два слота, оба пустые». Мы печатали
				# {"id":"1","label":"SIM1"},{"id":"2","label":"SIM2"} без признака
				# пустоты, и человек читал это как показ чужой, вставленной SIM.
				_PR=0
				case "$SP" in
					/org/*)
						_PR=1
						ST=$(mmcli --sim "$SP" -K 2>/dev/null \
							| sed -n 's/^sim\.properties\.sim-type *: *//p' | tr -d ' ')
						case "$ST" in
							esim)     LBL="eSIM";;
							physical) LBL="SIM";;
						esac
						;;
				esac
				L_ALL="$L_ALL $LBL"
				P_ALL="$P_ALL $_PR"
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$i\",\"label\":\"$LBL\",\"present\":\"$_PR\"}"
				i=$((i + 1))
			done
			# одинаковые метки (напр. две физические SIM) - вернуть номерные
			if [ "$(echo $L_ALL | tr ' ' '\n' | sort | uniq -d)" != "" ]; then
				OUT=""
				i=1
				for _pr in $P_ALL; do
					[ -n "$OUT" ] && OUT="$OUT,"
					OUT="$OUT{\"id\":\"$i\",\"label\":\"SIM$i\",\"present\":\"$_pr\"}"
					i=$((i + 1))
				done
			fi
		fi
		# MM НЕ ЗНАЕТ ПРО СЛОТЫ - ЭТО ЕЩЁ НЕ «СЛОТОВ НЕТ».
		#
		# mmcli отдаёт sim-slots не для всякого модема: у части прошивок (в том
		# числе Thales MV31-W в MBIM) поле пустое или length<2, и мы печатали
		# пустой список, а страница прячет переключатель - под ModemManager
		# кнопки SIM/eSIM не показывались вовсе. Между тем сам модем слоты
		# отдаёт, просто спрашивать надо не MM, а его самого. Поэтому при пустом
		# ответе НЕ выходим, а проваливаемся ниже - в MBIM/QMI-путь; он ходит
		# через тот же прокси, что и MM, поэтому канал не отбирает.
		# MM НЕ ВСЕГДА ЗНАЕТ, ЧТО СЛОТ - eSIM. Тип он берёт из SIM-объекта
		# (sim.properties.sim-type), а тот заполнен не у всякой прошивки: у
		# Thales MV31-W под MM оба слота приезжают безымянными, и человек видит
		# «SIM1 / SIM2» там, где на деле физический слот и eUICC. Сам модем это
		# знает - спрашиваем его напрямую по MBIM и уточняем подпись. Через
		# прокси (-p), потому что канал сейчас у MM; лишних вызовов не делаем -
		# только когда MM не дал ни одной метки eSIM.
		case "$OUT" in
			*'"label":"eSIM"'*) : ;;
			?*)
				_UW=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].wdm[0]" 2>/dev/null)
				case "$(readlink -f "/sys/class/usbmisc/${_UW##*/}/device/driver" 2>/dev/null)" in
					*/cdc_mbim)
						command -v mbimcli >/dev/null 2>&1 && {
							_ui=0
							while [ "$_ui" -lt 4 ]; do
								_us=$(mbimcli -p -d "$_UW" --ms-query-slot-info-status="$_ui" 2>/dev/null \
									| sed -n "s/.*Slot '$_ui': '\([a-z0-9-]*\)'.*/\1/p" | head -1)
								[ -n "$_us" ] || break
								case "$_us" in
									*esim*) OUT=$(printf '%s' "$OUT" | sed "s/{\"id\":\"$((_ui + 1))\",\"label\":\"[^\"]*\"/{\"id\":\"$((_ui + 1))\",\"label\":\"eSIM\"/") ;;
								esac
								_ui=$((_ui + 1))
							done
						} ;;
				esac ;;
		esac
		if [ -n "$OUT" ]; then
			# КЭШ ПИШЕМ И ЗДЕСЬ. Раньше его заполняли только QMI/MBIM-ветки, а
			# путь ModemManager отдавал ответ мимо кэша. Пока status ходил в
			# модем на каждый запрос, это было незаметно; теперь он отвечает
			# ИЗ КЭША (чтобы не ждать канал по 20 c), и под MM кэш оставался
			# пустым навсегда - вкладка получала пустой список и прятала кнопки
			# слотов, хотя refresh руками отрабатывал верно.
			_MMC="/tmp/5gmodem_slots_$_ss_am"
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$OUT" "$ACT" > "$_MMC"
			cut -d. -f1 /proc/uptime > "$_MMC.t"
			cat "$_MMC"
			exit 0
		fi
		logger -t 5gmodem "slots: ModemManager did not report them - asking the modem directly"
		;;
	esac
fi

# ---- AT-модем ---------------------------------------------------------------
# Способ чтения слотов берём из базы проверенных модемов, а не перебором: лишние
# команды в общий AT-порт конкурируют с опросом метрик, и ответы перепутываются
# (эхо "AT+SIMTYPE?" однажды прилетело на чтение AT+CGMM и осело в имени модема).
_VIA=$(sim_slots_via "$(uci -q get "5gmodem.$_SEC.model")" "$_AVIDPID")
if [ "$_VIA" = none ] && [ "$1" != set ]; then
	# Модем с единственным слотом (SIM7600E-H): спрашивать нечего, кнопок нет.
	echo '{"type":"","slots":[],"active":""}'; exit 0
fi

# ---- QMI-модем: слоты через UIM ---------------------------------------------
# Третий путь помимо mmcli и AT. Нужен там, где прошивка НЕ отдаёт слоты по AT,
# а QMI отдаёт: Telit LM960A18 - dual SIM single standby, но #SIMSELECT у него
# нет вовсе (см. quirks.sh). qmicli --uim-get-slot-status печатает:
#   2 physical slots found:
#     Physical slot 1:
#        Card status: present
#        Slot status: active
#             ICCID: 89701620...
#          Is eUICC: no
# id слота = ФИЗИЧЕСКИЙ номер (1..N), активен тот, у кого "Slot status: active".
if [ "$_VIA" = qmi ]; then
	# КАНАЛ МОЖЕТ БЫТЬ ЗАНЯТ netifd. При proto=qmi устройством владеет uqmi, и
	# наш qmicli -p (через qmi-proxy) становится вторым хозяином того же канала -
	# ответы путаются, подъём соединения виснет (см. qmi_channel_free в lib.sh).
	# Слоты подождут: связь дороже.
	if command -v qmi_channel_free >/dev/null 2>&1 && ! qmi_channel_free; then
		echo '{"error":"qmi busy"}'; exit 0
	fi
	_WDM=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].wdm[0]" 2>/dev/null)
	[ -n "$_WDM" ] && [ -e "$_WDM" ] || { echo '{"error":"no qmi device"}'; exit 0; }
	# qmicli без ограничения по времени виснет на занятом/мёртвом канале, а нас
	# зовёт rpcd со своим 30-секундным таймаутом. Поэтому ниже ждём его с kill -9.
	# ВАЖНО: ходим ТОЛЬКО через qmi-proxy (-p). Прямой qmicli, убитый по kill -9,
	# НЕ освобождает выделенный на модеме QMI client-ID - утечка. Копясь, они
	# исчерпывают пул ('QMI protocol error (5): ClientIdsExhausted'), и тогда
	# ModemManager перестаёт инициализировать модем ('unknown-capabilities'):
	# у Compal это ломало и данные, и управление диапазонами. С -p клиент держит
	# ПРОКСИ, а не наш процесс: убийство qmicli пул не трогает.
	_q() {
		_qo="/tmp/5gmodem_uim.$$"
		qmicli_p "$_WDM" "$@" > "$_qo" 2>&1 &
		_qp=$!
		( sleep 20; kill -9 "$_qp" 2>/dev/null ) >/dev/null 2>&1 &
		_qw=$!
		wait "$_qp" 2>/dev/null; kill "$_qw" 2>/dev/null; wait "$_qw" 2>/dev/null
		cat "$_qo"; rm -f "$_qo"
	}
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		# СНАЧАЛА ВЕНДОРНАЯ AT-КОМАНДА, ПОТОМ QMI.
		#
		# AT^switch_slot (Foxconn T99W175 / Thales MV31-W и родня) идёт по tty и
		# НЕ ЗАВИСИТ от состояния QMI-канала - а тот регулярно занят или залипает
		# вместе с mbim-proxy, и тогда переключение через --uim-switch-slot молча
		# не доезжает до модема: человек жмёт «SIM1», ничего не происходит, и
		# понять причину нельзя (живой случай 04.08.2026 - по AT слот переключился
		# с первого раза, когда QMI-путь не отвечал вовсе).
		# Нумерация у команды 0-based (0 = SIM1, 1 = eSIM), у нас слоты 1..N.
		# Команды нет - ответ пустой, просто идём дальше на QMI.
		# Пакет конфигурации ПИШЕМ ЯВНО: в этом файле нет переменной $CFG (она есть
		# в lib.sh, который сюда не подключается), и с ней путь uci собирался как
		# ".m_2_1_4.at_port" - пустой ответ, AT-ветка молча пропускалась, а QMI
		# на этом модеме не переключает вовсе. Снаружи это выглядело как «кнопка
		# не работает» без единой строки в журнале.
		_ss_at=$(uci -q get "5gmodem.$_ss_sec.at_port")
		if [ -n "$_ss_at" ] && [ -e "$_ss_at" ]; then
			if sms_tool -d "$_ss_at" at "AT^switch_slot?" 2>/dev/null | grep -qi "SIM"; then
				sms_tool -d "$_ss_at" at "AT^switch_slot=$(($2 - 1))" >/dev/null 2>&1
				# Ждём ПОДТВЕРЖДЕНИЯ, а не фиксированную паузу: модем перекидывает
				# слот за 3-6 с, и одного sleep 3 хватало не всегда - переключение
				# было выполнено, но мы успевали объявить его неудачей и уйти на
				# заведомо нерабочий QMI.
				_ss_ok=0
				for _ss_i in 1 2 3 4 5 6; do
					sleep 2
					sms_tool -d "$_ss_at" at "AT^switch_slot?" 2>/dev/null \
						| grep -qi "SIM$2 ENABLE" && { _ss_ok=1; break; }
				done
				if [ "$_ss_ok" = 1 ]; then
					logger -t 5gmodem "SIM slot switched to $2 via AT^switch_slot"
					rm -f "/tmp/5gmodem_slots_$_AP" "/tmp/5gmodem_slots_$_AP.t"
					( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
					  _IF=$(uci -q get "5gmodem.$_ss_sec.network")
					  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
					) >/dev/null 2>&1 </dev/null &
					echo '{"result":"ok"}'
					exit 0
				fi
			fi
		fi
		if _q --uim-switch-slot="$2" 2>/dev/null | grep -qi "success"; then
			rm -f "/tmp/5gmodem_slots_$_AP" "/tmp/5gmodem_slots_$_AP.t"
			# смена слота = другая SIM: интерфейс надо переподнять (см. slot_redial)
			( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
			  _IF=$(uci -q get "5gmodem.$_ss_sec.network")
			  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
			) >/dev/null 2>&1 </dev/null &
			echo '{"result":"ok"}'
		else
			echo '{"error":"switch failed"}'
		fi
		;;
	*)
		# СНАЧАЛА НАТИВНЫЙ MBIM, ПОТОМ QMI.
		#
		# На модеме под cdc_mbim QMI - это туннель поверх MBIM, и он отваливается
		# первым: пока netifd в цикле переподнимает интерфейс (без SIM это
		# навсегда, раз в 15 c), qmicli не может открыть устройство вовсе -
		# «couldn't open the QmiDevice: device is closed». Слоты при этом
		# читаются НАТИВНЫМИ запросами MBIM без единой заминки - проверено на
		# Thales MV31-W 04.08.2026, когда QMI не отвечал ни напрямую, ни через
		# прокси. Поэтому для cdc_mbim спрашиваем mbimcli, а QMI оставляем
		# запасным путём (он же единственный на qmi_wwan).
		#
		# Формат ответов:
		#   --ms-query-device-slot-mappings -> "Executor '0': slot '<N>'"
		#   --ms-query-slot-info-status=<N> -> "Slot '<N>': '<состояние>'"
		# Нумерация у MBIM с НУЛЯ, у нас слоты 1..N - сдвигаем. Состояния:
		# state-empty (карты нет), state-active-esim* (eUICC), остальные значат
		# «карта есть». Признак eSIM берём из состояния - отдельного поля нет.
		_S=""
		_MBS=""
		case "$(readlink -f "/sys/class/usbmisc/${_WDM##*/}/device/driver" 2>/dev/null)" in
			*/cdc_mbim)
				# КАНАЛ У UMBIM (proto=mbim, живая сессия) - mbimcli не пускаем:
				# и прямой, и -p (поднимающий вечный mbim-proxy) отбирают канал,
				# umbim ловит message timeout и сессия умирает (живой случай
				# 17.08.2026: открытие страницы роняло интернет на MV31-W).
				# Слоты в этот момент отдаст липкий кэш.
				if command -v mbimcli >/dev/null 2>&1 && qmi_channel_free; then
					# Замок ТОТ ЖЕ, что у qmicli (см. qmicli_p в lib.sh): устройство
					# одно, и второй хозяин ломает обоих. Ждём недолго - не
					# дождались, просто идём дальше на QMI.
					_MLK="/var/lock/5gmodem_qmi_${_WDM##*/}.lock"
					exec 8>"$_MLK" 2>/dev/null
					_mi=0
					while [ "$_mi" -lt 10 ]; do
						flock -n 8 2>/dev/null && break
						sleep 1
						_mi=$((_mi + 1))
					done
					# ПОД ЖИВЫМ MM - ТОЛЬКО ЧЕРЕЗ ПРОКСИ. MM держит устройство
					# сам и ходит через mbim-proxy; прямой заход отобрал бы у него
					# канал (ровно тот случай, из-за которого у людей «отваливался
					# инет при открытии страницы»). С -p мы становимся вторым
					# клиентом прокси, а не вторым хозяином устройства.
					# ИМЯ ОТДЕЛЬНОЕ: _MP ниже в цикле означает «карта в слоте»
					# (0/1). Совпадение имён отправляло во второй запрос мусорный
					# аргумент («mbimcli 1 -d ...»), и слот читался неверно.
					_MPX=""
					pgrep -f 'sbin/ModemManager$' >/dev/null 2>&1 && _MPX="-p"
					# ПОД ЖИВЫМ umbim К УЗЛУ НЕ ПОДХОДИМ ВООБЩЕ.
					#
					# Третий владелец канала, кроме нас и MM, - штатный протокол
					# mbim: netifd поднимает сессию через umbim, открывая устройство
					# НАПРЯМУЮ, без прокси. Здесь -p не спасает, а вредит: mbimcli с
					# прокси поднимет mbim-proxy, тот захватит /dev/cdc-wdm0, и umbim
					# получит «mbim message timeout» - связь рвётся. Это ровно та
					# жалоба «открываю модуль 5gmodem - отваливается инет», из-за
					# которой в esim.sh появился гейт _wdm_owned_by_umbim; здесь его
					# не было, а код слотов ходит к устройству при каждом опросе
					# карточки. Слоты в этом случае оставляем QMI-пути ниже.
					_umbim_owns_wdm "$_WDM" && _MPX="SKIP"
					if [ "$_MPX" = "SKIP" ]; then
						_MMAP=""
					else
					_MMAP=$(mbimcli $_MPX -d "$_WDM" --ms-query-device-slot-mappings 2>/dev/null)
					_MACT=$(printf '%s' "$_MMAP" | sed -n "s/.*Executor '0': slot '\([0-9]*\)'.*/\1/p" | head -1)
					if [ -n "$_MACT" ]; then
						_mn=0
						while [ "$_mn" -lt 4 ]; do
							# ДВЕ ПОПЫТКИ НА СЛОТ. Одиночный запрос иногда срывается
							# (канал занят, модем отвечает Failure), и цикл обрывался
							# на первой же осечке - в списке оставался ОДИН слот, а
							# кнопки в карточке пропадали целиком (живой случай
							# 04.08.2026: слот 0 прочитался, слот 1 сорвался).
							_MST=""
							for _mt in 1 2; do
								_MI=$(mbimcli $_MPX -d "$_WDM" --ms-query-slot-info-status="$_mn" 2>/dev/null)
								_MST=$(printf '%s' "$_MI" | sed -n "s/.*Slot '$_mn': '\([a-z0-9-]*\)'.*/\1/p" | head -1)
								[ -n "$_MST" ] && break
								sleep 1
							done
							[ -n "$_MST" ] || break
							case "$_MST" in
								*empty*) _MP=0 ;;
								*)       _MP=1 ;;
							esac
							case "$_MST" in
								*esim*) _ML="eSIM" ;;
								*)      _ML="SIM$((_mn + 1))" ;;
							esac
							[ -n "$_MBS" ] && _MBS="$_MBS,"
							_MBS="$_MBS{\"id\":\"$((_mn + 1))\",\"label\":\"$_ML\",\"present\":\"$_MP\"}"
							_mn=$((_mn + 1))
						done
						[ -n "$_MBS" ] && _MACT=$((_MACT + 1))
					fi
					fi
					exec 8>&- 2>/dev/null
				fi
				;;
		esac
		# АКТИВНЫЙ СЛОТ ОБЯЗАН БЫТЬ В СПИСКЕ. Если его там нет, чтение прошло
		# наполовину (часть запросов сорвалась), и такой ответ нельзя ни отдавать,
		# ни тем более кэшировать: фронт показывает кнопки только при двух и более
		# слотах, поэтому противоречивый список = молча пропавший переключатель.
		# Обнуляем - ниже отработает обычный путь с прежним кэшем.
		case ",$(printf '%s' "$_MBS" | sed 's/[^0-9,]*"id":"\([0-9]*\)"[^0-9,]*/\1,/g')" in
			*",$_MACT,"*) : ;;
			*) [ -n "$_MBS" ] && logger -t 5gmodem "slots: active $_MACT missing from the list - incomplete read, using the cache"
			   _MBS="" ;;
		esac
		if [ -n "$_MBS" ]; then
			_CACHE="/tmp/5gmodem_slots_$_AP"
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$_MBS" "$_MACT" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"
			cat "$_CACHE"
			exit 0
		fi
		_S=$(_q --uim-get-slot-status 2>/dev/null)
		_OUT=""; _ACT=""
		_N=$(echo "$_S" | sed -n 's/^ *Physical slot \([0-9]*\):.*/\1/p')
		for _i in $_N; do
			# блок слота: от его заголовка до следующего "Physical slot"
			_B=$(echo "$_S" | sed -n "/^ *Physical slot $_i:/,/^ *Physical slot [0-9]*:/p" \
				| grep -v "^ *Physical slot $((_i + 1)):")
			echo "$_B" | grep -qi "Card status: *present" && _P=1 || _P=0
			echo "$_B" | grep -qi "Slot status: *active" && _ACT="$_i"
			# eUICC-слот подписываем как eSIM - у нас для него отдельная вкладка
			if echo "$_B" | grep -qi "Is eUICC: *yes"; then _L="eSIM"; else _L="SIM$_i"; fi
			[ -n "$_OUT" ] && _OUT="$_OUT,"
			_OUT="$_OUT{\"id\":\"$_i\",\"label\":\"$_L\",\"present\":\"$_P\"}"
		done
		_CACHE="/tmp/5gmodem_slots_$_AP"
		if [ -n "$_OUT" ] && [ -n "$_ACT" ]; then
			printf '{"type":"","slots":[%s],"active":"%s"}\n' "$_OUT" "$_ACT" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"   # метка для cache-first fast-path
			cat "$_CACHE"
		elif [ -s "$_CACHE" ]; then
			cat "$_CACHE"
		else
			# ПУСТОЙ ОТВЕТ НЕ КЭШИРУЕМ.
			#
			# Считалось, что у qmicli свой канал и он ни с кем не конкурирует, а
			# значит пустота = «слотов правда нет». Практика обратная: пустой
			# ответ почти всегда означает занятый или зависший канал (mbim-proxy
			# после переэнумерации модема отвечает таймаутом на всё). Закэшировав
			# такую пустоту, мы на пять минут ПРЯТАЛИ кнопки слотов, и обновление
			# страницы не помогало - человек видел, что переключатель SIM/eSIM
			# исчез, и не понимал, переключился модем или нет (живой случай
			# 04.08.2026). Отдаём пустоту разово: следующий вызов попробует снова.
			printf '{"type":"","slots":[],"active":""}\n'
		fi
		;;
	esac
	exit 0
fi

# Живой AT-порт: сразу после USB-переперечисления detect.sh может отдавать
# устаревший tty (команда уходит в никуда, а «успех без ответа» ложно
# засчитывался). Проверяем порт bounded-пробой; при провале берём первый
# отвечающий tty АКТИВНОГО модема (не всех - иначе можно попасть в другой).
# ТОЛЬКО ПОРТЫ ЭТОГО МОДЕМА. Оговорка «не всех - иначе можно попасть в другой»
# стояла здесь и раньше, но защищала лишь ВТОРУЮ ветку: ответ detect.sh
# принимался сразу, как только отвечал на AT, а он при путанице отдаёт порт
# чужого модема. Ставка тут выше, чем где-либо: AT+GTDUALSIM=<n> /
# AT+CEISWITCHSIM=<n> ФИЗИЧЕСКИ переключат слот SIM у соседа, и человек получит
# не ту карту в не том модеме.
# Список портов даёт реестр; ответ detect.sh пробуем первым, лишь если он
# принадлежит этому модему (так дешёвый путь сохраняется).
live_port() {
	# ПОРТЫ ИМЕННО ЦЕЛЕВОГО МОДЕМА (по usb-пути), а не активного: AT+GTDUALSIM= /
	# AT+CEISWITCHSIM= физически переключают слот, и уход в порт соседа переключил
	# бы не ту SIM в не том модеме.
	_LPT=$(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
		| jsonfilter -e "@[@.path=\"$_TGT\"].tty[*]" 2>/dev/null | tr '\n' ' ')
	[ -n "$_LPT" ] || return 1
	# Порт из detect.sh (он про АКТИВНЫЙ модем) пробуем первым, лишь если он реально
	# принадлежит целевому - тогда дешёвый путь сохраняется, иначе он отбрасывается.
	_D=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	case " $_LPT " in
		*" $_D "*) _LPT="$_D $_LPT" ;;
	esac
	for _t in $_LPT; do
		[ -e "$_t" ] || continue
		/usr/share/5gmodem/atprobe.sh "$_t" >/dev/null 2>&1 && { echo "$_t"; return 0; }
	done
	return 1
}

D=$(live_port)
# Опрос SIM-слотов делит порт с опросом метрик: без очереди AT+GTDUALSIM?
# возвращал ответ чужой команды, и слот определялся неверно.
. /usr/share/5gmodem/atlock.sh
# _LOCKED=0 - очередь к порту НАША: пока держим at_lock, ответ украсть нельзя,
# значит пустой список слотов - это ГЕНУИННО одна SIM, а не коллизия (старое
# «не кэшировать пусто» появилось ДО сериализатора и теперь избыточно строгое).
# _LOCKED!=0 - не дождались очереди, поллим без гарантий -> пусто НЕ кэшируем.
_LOCKED=1
[ -n "$D" ] && { at_lock "$D" 10; _LOCKED=$?; }
if [ -z "$D" ]; then
	# Ни один tty модема не отвечает: он переперечисляется после смены слота/CFUN
	# или порт занят метриками. Для status это НЕ «слотов нет» - отдаём последний
	# валидный ответ, иначе кнопки SIM/eSIM просто исчезают на ровном месте
	# (этот ранний выход стоял ДО кэша и обходил его). Для set - честная ошибка.
	if [ "$1" != "set" ] && [ -s "/tmp/5gmodem_slots_$_AP" ]; then
		cat "/tmp/5gmodem_slots_$_AP"; exit 0
	fi
	echo '{"error":"no device"}'; exit 0
fi

# Фибокомовский AT+GTDUALSIM есть далеко не у всех: у Compal RXM-G1 (SG500M2-X)
# его НЕТ, поэтому AT-ветка отдавала пустой список слотов и в mbim-режиме кнопок
# переключения не было вовсе. Там слоты живут за +CEISWITCHSIM (см. ниже).
at_has_gtdualsim() {
	at_query "$D" "AT+GTDUALSIM=?" 6 | grep -qE '\(0[-,]1\)'
}

# Переподнять интерфейс активного модема ПОСЛЕ смены слота.
# Без этого netifd продолжает держать адрес, выданный СТАРОЙ SIM: слот
# переключён, а IP (и трафик) остаются от прежней карты до ручного ifdown/ifup.
# Работаем в фоне: модем после смены слота ресетится и переперечисляется на USB
# (у FM350 - десятки секунд), а HTTP-запрос из UI столько не живёт.
slot_redial() {
	# Ждём возврата ЦЕЛЕВОГО модема на шину (ресет+переэнумерация после смены
	# слота, у FM350 - десятки секунд), затем переподнимаем ИМЕННО его интерфейс.
	_n=0
	while [ "$_n" -lt 120 ]; do
		sleep 3; _n=$((_n + 3))
		[ -n "$_TGT" ] || break
		/usr/share/5gmodem/listmodems.sh 2>/dev/null | grep -q "\"$_TGT\"" && break
	done
	# resolve перепривязывает device после переперечисления (ttyUSB/cdc-wdm поехали)
	# и возвращает активность предпочтительному модему.
	/usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
	_IF=$(uci -q get "5gmodem.$_ss_sec.network")
	[ -n "$_IF" ] || return 0
	ifdown "$_IF" >/dev/null 2>&1
	sleep 2
	ifup "$_IF" >/dev/null 2>&1
}


case "$1" in
set)
	[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
	# Номер слота уходит прямо в AT-команду (AT+GTDUALSIM=$2 / AT+CEISWITCHSIM=$2),
	# поэтому проверяем до использования: в AT-канале возврат каретки внутри
	# значения превращает одну команду в две. Предикат - в lib.sh.
	if command -v is_num >/dev/null 2>&1 && ! is_num "$2"; then
		logger -t 5gmodem "simslot: invalid slot number - rejected"
		echo '{"error":"bad slot"}'; exit 0
	fi
	if at_has_gtdualsim; then
		O=$(at_query "$D" "AT+GTDUALSIM=$2" 8)
	else
		# Compal: id - номер ФИЗИЧЕСКОГО слота (1/2). Команда переназначает этот
		# слот на интерфейс SIM1 модема (AT+CEISWITCHSIM=? -> "1:Set physical SIM
		# SLOT 1 to SIM1, 2:Set physical SIM SLOT 2 to SIM1").
		O=$(at_query "$D" "AT+CEISWITCHSIM=$2" 8)
	fi
	# Ошибка - только явный ERROR. Пустой ответ = успех: модем (FM350) после
	# смены слота мгновенно ресетится/переперечисляется и не успевает ответить
	# "OK" - слот при этом фактически переключён (проверено живьём).
	if echo "$O" | grep -q "ERROR"; then
		echo '{"error":"switch failed"}'
	else
		rm -f "/tmp/5gmodem_slots_$_AP" "/tmp/5gmodem_slots_$_AP.t"   # активный слот изменился - кэш недействителен
		# fds отвязаны ОТ ПОДОБОЛОЧКИ: иначе она держит пайпы rpcd все ~120 с
		# ожидания модема, и XHR из UI упадёт по таймауту (см. reboot_modem.sh).
		( slot_redial ) >/dev/null 2>&1 </dev/null &
		echo '{"result":"ok"}'
	fi
	;;
*)
	TYPE=""; ACT=""
	# Fibocom-команды шлём только тем, у кого они есть (или кого ещё не знаем).
	if [ "$_VIA" != ceiswitchsim ]; then
		T=$(at_query "$D" "AT+SIMTYPE?" 6 \
			| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
		case "$T" in
			0) TYPE="USIM";;
			1) TYPE="eSIM";;
		esac
		# активный слот: «+GTDUALSIM : 0, "SUB1", "L"» (пробел перед ':' бывает)
		ACT=$(at_query "$D" "AT+GTDUALSIM?" 6 \
			| sed -n 's/^+GTDUALSIM *: *\([0-9]\).*/\1/p' | head -1)
	fi
	# ЗАПОМНИТЬ тип активного слота (SIMTYPE читает только текущий, поэтому
	# тип другого слота узнаём, лишь побывав на нём; сохранённое - в uci,
	# переживает перезагрузку). По типам подписываем кнопки: SIM / eSIM.
	if [ -n "$_SEC" ] && [ -n "$ACT" ] && [ -n "$TYPE" ]; then
		if [ "$(uci -q get "5gmodem.$_SEC.slot_type_$ACT")" != "$TYPE" ]; then
			uci -q set "5gmodem.$_SEC.slot_type_$ACT=$TYPE"
			uci -q commit 5gmodem
		fi
	fi
	slot_label() {   # <id> <fallback>
		case "$(uci -q get "5gmodem.$_SEC.slot_type_$1")" in
			eSIM) echo "eSIM";;
			USIM) echo "SIM";;
			*)    echo "$2";;
		esac
	}
	# «+GTDUALSIM: (0-1)» или «(0,1)» = у прошивки два слота
	OUT=""
	R=$(at_query "$D" "AT+GTDUALSIM=?" 6 | grep -i '^+GTDUALSIM' | head -1)
	if echo "$R" | grep -qE '\(0[-,]1\)'; then
		L0=$(slot_label 0 SIM0)
		L1=$(slot_label 1 SIM1)
		# СВЕЖИЙ eSIM: SIMTYPE читается только у активного слота, поэтому тип
		# ни разу не активированного eSIM неизвестен -> он подписывался «SIM2».
		# Доопределяем: если eUICC доступен (esim.sh закэшировал available=1), а
		# ОДИН слот - известная физическая USIM («SIM»), то ДРУГОЙ (с числовым
		# фолбэком) и есть eSIM (eUICC на нём). Ключ кэша - как в esim.sh (сырой
		# active_modem).
		_ESAV=$(sed -n 's/.*"available": *\([0-9]\).*/\1/p' \
			"/tmp/5gmodem_esimstat_$_TGT" 2>/dev/null)
		if [ "$_ESAV" = 1 ]; then
			[ "$L0" = SIM ] && case "$L1" in SIM0|SIM1) L1="eSIM";; esac
			[ "$L1" = SIM ] && case "$L0" in SIM0|SIM1) L0="eSIM";; esac
		fi
		# оба слота одного типа (две физические SIM) - вернуть номерные метки
		[ "$L0" = "$L1" ] && { L0="SIM0"; L1="SIM1"; }
		OUT='{"id":"0","label":"'$L0'"},{"id":"1","label":"'$L1'"}'
	fi

	# --- Compal RXM-G1 (SG500M2-X): слоты через +CEISWITCHSIM ----------------
	# Прошивка не знает ни AT+SIMTYPE, ни AT+GTDUALSIM (выше оба дали пусто), и
	# в mbim-режиме кнопок слотов не появлялось. Формат ответа:
	#   AT+CEISWITCHSIM? -> "Physical SIM SLOT 1 maps to SIM1,SIM inserted 1, ..."
	#                       "Physical SIM SLOT 2 maps to SIM2,SIM inserted 0, ..."
	# id = номер ФИЗИЧЕСКОГО слота (1/2); активен тот, который сейчас maps to SIM1.
	if [ -z "$OUT" ]; then
		CEI=$(sms_tool -d "$D" at "AT+CEISWITCHSIM?" 2>/dev/null | tr -d '\r')
		if echo "$CEI" | grep -q "^Physical SIM SLOT"; then
			ACT=$(echo "$CEI" | sed -n 's/^Physical SIM SLOT \([0-9]\) maps to SIM1,.*/\1/p' | head -1)
			OUT=""
			for _i in 1 2; do
				# «SIM inserted» в строке ДВА раза (второй - про CD-пин), поэтому
				# якорим первое вхождение, а не берём жадное .*
				_ins=$(echo "$CEI" | sed -n "s/^Physical SIM SLOT $_i maps to SIM[0-9],SIM inserted \([0-9]\).*/\1/p" | head -1)
				[ -n "$_ins" ] || continue
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$_i\",\"label\":\"SIM$_i\",\"present\":\"$_ins\"}"
			done
		fi
	fi
	# Кэш последнего ХОРОШЕГО ответа (в /tmp, ключ - стабильный USB-путь модема).
	# AT-порт делят метрики, esim.sh и мы: при коллизии любой из запросов выше
	# отдаёт пусто, и раньше это летело прямо в UI - отсюда «неконсистентность»:
	# то нет кнопок слотов совсем (пустой slots), то кнопки есть, но ни одна не
	# подсвечена (пустой active, когда GTDUALSIM? не ответил, а GTDUALSIM=? успел).
	# Пустой ответ теперь заменяем последним валидным; кэш сбрасывает ветка set.
	_CACHE="/tmp/5gmodem_slots_$_AP"
	_SJSON="{\"type\":\"$TYPE\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
	if [ -n "$OUT" ] && [ -n "$ACT" ]; then
		printf '%s\n' "$_SJSON" > "$_CACHE"
		cut -d. -f1 /proc/uptime > "$_CACHE.t"
		cat "$_CACHE"
	elif [ -s "$_CACHE" ]; then
		cat "$_CACHE"
	else
		# Пусто. Кэшируем ТОЛЬКО если очередь к порту была наша (_LOCKED=0): тогда
		# это генуинно одна SIM, и кэш избавляет от 5-10 c опроса на КАЖДОМ открытии
		# страницы. Без лока (коллизия/порт занят) - отдаём пусто, но НЕ кэшируем.
		if [ "$_LOCKED" = 0 ]; then
			printf '%s\n' "$_SJSON" > "$_CACHE"
			cut -d. -f1 /proc/uptime > "$_CACHE.t"
		fi
		printf '%s\n' "$_SJSON"
	fi
	;;
esac
exit 0
