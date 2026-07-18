#!/bin/sh
#
# Тип SIM и слоты активного модема (для окна «Меню SIM-карты»).
#
#   simslot.sh status      -> {"type":"USIM|eSIM|","slots":[{"id":..,"label":..}...],"active":"<id>"}
#   simslot.sh set <id>    -> переключить активный слот
#
# Два источника:
#  - модем под ModemManager: mmcli primary-sim-slot / sim-slots (слоты 1..N),
#    переключение mmcli --set-primary-sim-slot;
#  - AT-модем (напр. Fibocom FM350): AT+GTDUALSIM (слоты 0/1 -> SIM1/SIM2,
#    мануал FM350 4.3) и AT+SIMTYPE (0 USIM / 1 eSIM, мануал 3.15).
# Кнопки показываются, только если слотов >= 2.

MI=$(/usr/share/5gmodem/modemswitch.sh mmindex 2>/dev/null)

# mmcli-путь выбираем по ПРОТОКОЛУ интерфейса активного модема, а не по
# наличию модема в MM: kernel-proto модем (напр. FM350/fibocom) MM успевает
# заново зарегистрировать после каждого USB-переперечисления (пока mm-inhibit
# его не отпустит), и слепой mmindex уводил запрос к полумёртвому MM-объекту.
_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
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
case "$_AVIDPID" in
	05c6:90d6) MI="" ;;
	# 05c6:90d5 делят Compal и Foxconn T99W175 / Thales MV31-W - у последних
	# слоты через MM работают штатно, поэтому здесь смотрим на дескриптор
	# (как это делает modemband/05c690d5), а не на один VID:PID.
	05c6:90d5)
		case "$_APROD" in VOS_5G*|RXMG1*|*Tri\ Cascade*) MI="" ;; esac
		;;
esac

# ---- ModemManager-модем -----------------------------------------------------
if [ -n "$MI" ]; then
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		if mmcli -m "$MI" --set-primary-sim-slot="$2" >/dev/null 2>&1; then
			echo '{"result":"ok"}'
		else
			echo '{"error":"switch failed"}'
		fi
		;;
	*)
		K=$(mmcli -m "$MI" -K 2>/dev/null)
		N=$(echo "$K" | sed -n 's/^modem\.generic\.sim-slots\.length *: *//p' | tr -dc 0-9)
		ACT=$(echo "$K" | sed -n 's/^modem\.generic\.primary-sim-slot *: *//p' | tr -dc 0-9)
		OUT=""
		if [ -n "$N" ] && [ "$N" -ge 2 ] 2>/dev/null; then
			L_ALL=""
			i=1
			while [ "$i" -le "$N" ]; do
				# тип слота напрямую из SIM-объекта (MM >= 1.20: sim-type
				# physical/esim); для пустого слота ("/") тип неизвестен
				LBL="SIM$i"
				SP=$(echo "$K" | sed -n "s/^modem\.generic\.sim-slots\.value\[$i\] *: *//p")
				case "$SP" in
					/org/*)
						ST=$(mmcli --sim "$SP" -K 2>/dev/null \
							| sed -n 's/^sim\.properties\.sim-type *: *//p' | tr -d ' ')
						case "$ST" in
							esim)     LBL="eSIM";;
							physical) LBL="SIM";;
						esac
						;;
				esac
				L_ALL="$L_ALL $LBL"
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$i\",\"label\":\"$LBL\"}"
				i=$((i + 1))
			done
			# одинаковые метки (напр. две физические SIM) - вернуть номерные
			if [ "$(echo $L_ALL | tr ' ' '\n' | sort | uniq -d)" != "" ]; then
				OUT=""
				i=1
				while [ "$i" -le "$N" ]; do
					[ -n "$OUT" ] && OUT="$OUT,"
					OUT="$OUT{\"id\":\"$i\",\"label\":\"SIM$i\"}"
					i=$((i + 1))
				done
			fi
		fi
		echo "{\"type\":\"\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
		;;
	esac
	exit 0
fi

# ---- AT-модем ---------------------------------------------------------------
# Способ чтения слотов берём из базы проверенных модемов, а не перебором: лишние
# команды в общий AT-порт конкурируют с опросом метрик, и ответы перепутываются
# (эхо "AT+SIMTYPE?" однажды прилетело на чтение AT+CGMM и осело в имени модема).
. /usr/share/5gmodem/quirks.sh
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
	_WDM=$(echo "$_AJ" | jsonfilter -e "@[@.path=\"$_AP\"].wdm[0]" 2>/dev/null)
	[ -n "$_WDM" ] && [ -e "$_WDM" ] || { echo '{"error":"no qmi device"}'; exit 0; }
	# qmicli без ограничения по времени виснет на занятом/мёртвом канале, а нас
	# зовёт rpcd со своим 30-секундным таймаутом.
	_q() {
		_qo="/tmp/5gmodem_uim.$$"
		qmicli -d "$_WDM" "$@" > "$_qo" 2>&1 &
		_qp=$!
		( sleep 20; kill -9 "$_qp" 2>/dev/null ) >/dev/null 2>&1 &
		_qw=$!
		wait "$_qp" 2>/dev/null; kill "$_qw" 2>/dev/null; wait "$_qw" 2>/dev/null
		cat "$_qo"; rm -f "$_qo"
	}
	case "$1" in
	set)
		[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
		if _q --uim-switch-slot="$2" 2>/dev/null | grep -qi "success"; then
			rm -f "/tmp/5gmodem_slots_$_AP"
			# смена слота = другая SIM: интерфейс надо переподнять (см. slot_redial)
			( sleep 5; /usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
			  _IF=$(uci -q get 5gmodem.@5gmodem[0].network)
			  [ -n "$_IF" ] && { ifdown "$_IF"; sleep 2; ifup "$_IF"; }
			) >/dev/null 2>&1 </dev/null &
			echo '{"result":"ok"}'
		else
			echo '{"error":"switch failed"}'
		fi
		;;
	*)
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
			cat "$_CACHE"
		elif [ -s "$_CACHE" ]; then
			cat "$_CACHE"
		else
			echo '{"type":"","slots":[],"active":""}'
		fi
		;;
	esac
	exit 0
fi

# Живой AT-порт: сразу после USB-переперечисления detect.sh может отдавать
# устаревший tty (команда уходит в никуда, а «успех без ответа» ложно
# засчитывался). Проверяем порт bounded-пробой; при провале берём первый
# отвечающий tty АКТИВНОГО модема (не всех - иначе можно попасть в другой).
live_port() {
	_D=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
	[ -n "$_D" ] && /usr/share/5gmodem/atprobe.sh "$_D" >/dev/null 2>&1 && { echo "$_D"; return 0; }
	_P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_P" ] || return 1
	for _t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$_P\"].tty[*]" 2>/dev/null); do
		[ -e "$_t" ] || continue
		/usr/share/5gmodem/atprobe.sh "$_t" >/dev/null 2>&1 && { echo "$_t"; return 0; }
	done
	return 1
}

D=$(live_port)
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
	sms_tool -d "$D" at "AT+GTDUALSIM=?" 2>/dev/null | tr -d '\r' | grep -qE '\(0[-,]1\)'
}

# Переподнять интерфейс активного модема ПОСЛЕ смены слота.
# Без этого netifd продолжает держать адрес, выданный СТАРОЙ SIM: слот
# переключён, а IP (и трафик) остаются от прежней карты до ручного ifdown/ifup.
# Работаем в фоне: модем после смены слота ресетится и переперечисляется на USB
# (у FM350 - десятки секунд), а HTTP-запрос из UI столько не живёт.
slot_redial() {
	_AP=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	_n=0
	while [ "$_n" -lt 120 ]; do
		sleep 3; _n=$((_n + 3))
		[ -n "$_AP" ] || break
		/usr/share/5gmodem/listmodems.sh 2>/dev/null | grep -q "\"$_AP\"" && break
	done
	# resolve перепривязывает device после переперечисления (ttyUSB/cdc-wdm поехали)
	# и возвращает активность предпочтительному модему.
	/usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
	_IF=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_IF" ] || return 0
	ifdown "$_IF" >/dev/null 2>&1
	sleep 2
	ifup "$_IF" >/dev/null 2>&1
}

case "$1" in
set)
	[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
	if at_has_gtdualsim; then
		O=$(sms_tool -d "$D" at "AT+GTDUALSIM=$2" 2>/dev/null)
	else
		# Compal: id - номер ФИЗИЧЕСКОГО слота (1/2). Команда переназначает этот
		# слот на интерфейс SIM1 модема (AT+CEISWITCHSIM=? -> "1:Set physical SIM
		# SLOT 1 to SIM1, 2:Set physical SIM SLOT 2 to SIM1").
		O=$(sms_tool -d "$D" at "AT+CEISWITCHSIM=$2" 2>/dev/null)
	fi
	# Ошибка - только явный ERROR. Пустой ответ = успех: модем (FM350) после
	# смены слота мгновенно ресетится/переперечисляется и не успевает ответить
	# "OK" - слот при этом фактически переключён (проверено живьём).
	if echo "$O" | grep -q "ERROR"; then
		echo '{"error":"switch failed"}'
	else
		rm -f "/tmp/5gmodem_slots_$_AP"   # активный слот изменился - кэш недействителен
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
		T=$(sms_tool -d "$D" at "AT+SIMTYPE?" 2>/dev/null | tr -d '\r' \
			| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
		case "$T" in
			0) TYPE="USIM";;
			1) TYPE="eSIM";;
		esac
		# активный слот: «+GTDUALSIM : 0, "SUB1", "L"» (пробел перед ':' бывает)
		ACT=$(sms_tool -d "$D" at "AT+GTDUALSIM?" 2>/dev/null | tr -d '\r' \
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
	R=$(sms_tool -d "$D" at "AT+GTDUALSIM=?" 2>/dev/null | tr -d '\r' | grep -i '^+GTDUALSIM' | head -1)
	if echo "$R" | grep -qE '\(0[-,]1\)'; then
		L0=$(slot_label 0 SIM1)
		L1=$(slot_label 1 SIM2)
		# СВЕЖИЙ eSIM: SIMTYPE читается только у активного слота, поэтому тип
		# ни разу не активированного eSIM неизвестен -> он подписывался «SIM2».
		# Доопределяем: если eUICC доступен (esim.sh закэшировал available=1), а
		# ОДИН слот - известная физическая USIM («SIM»), то ДРУГОЙ (с числовым
		# фолбэком) и есть eSIM (eUICC на нём). Ключ кэша - как в esim.sh (сырой
		# active_modem).
		_ESAV=$(sed -n 's/.*"available": *\([0-9]\).*/\1/p' \
			"/tmp/5gmodem_esimstat_$(uci -q get 5gmodem.@5gmodem[0].active_modem)" 2>/dev/null)
		if [ "$_ESAV" = 1 ]; then
			[ "$L0" = SIM ] && case "$L1" in SIM1|SIM2) L1="eSIM";; esac
			[ "$L1" = SIM ] && case "$L0" in SIM1|SIM2) L0="eSIM";; esac
		fi
		# оба слота одного типа (две физические SIM) - вернуть номерные метки
		[ "$L0" = "$L1" ] && { L0="SIM1"; L1="SIM2"; }
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
	if [ -n "$OUT" ] && [ -n "$ACT" ]; then
		printf '{"type":"%s","slots":[%s],"active":"%s"}\n' "$TYPE" "$OUT" "$ACT" > "$_CACHE"
		cat "$_CACHE"
	elif [ -s "$_CACHE" ]; then
		cat "$_CACHE"
	else
		echo "{\"type\":\"$TYPE\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
	fi
	;;
esac
exit 0
