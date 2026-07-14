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
			i=1
			while [ "$i" -le "$N" ]; do
				[ -n "$OUT" ] && OUT="$OUT,"
				OUT="$OUT{\"id\":\"$i\",\"label\":\"SIM$i\"}"
				i=$((i + 1))
			done
		fi
		echo "{\"type\":\"\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
		;;
	esac
	exit 0
fi

# ---- AT-модем ---------------------------------------------------------------
D=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$D" ] || { echo '{"error":"no device"}'; exit 0; }

case "$1" in
set)
	[ -n "$2" ] || { echo '{"error":"no slot"}'; exit 0; }
	O=$(sms_tool -d "$D" at "AT+GTDUALSIM=$2" 2>/dev/null)
	if echo "$O" | grep -q "OK"; then
		echo '{"result":"ok"}'
	else
		echo '{"error":"switch failed"}'
	fi
	;;
*)
	TYPE=""
	T=$(sms_tool -d "$D" at "AT+SIMTYPE?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+SIMTYPE: *\([0-9]\).*/\1/p' | head -1)
	case "$T" in
		0) TYPE="USIM";;
		1) TYPE="eSIM";;
	esac
	# «+GTDUALSIM: (0-1)» или «(0,1)» = у прошивки два слота
	OUT=""
	R=$(sms_tool -d "$D" at "AT+GTDUALSIM=?" 2>/dev/null | tr -d '\r' | grep -i '^+GTDUALSIM' | head -1)
	if echo "$R" | grep -qE '\(0[-,]1\)'; then
		OUT='{"id":"0","label":"SIM1"},{"id":"1","label":"SIM2"}'
	fi
	# активный слот: «+GTDUALSIM : 0, "SUB1", "L"» (пробел перед ':' бывает)
	ACT=$(sms_tool -d "$D" at "AT+GTDUALSIM?" 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+GTDUALSIM *: *\([0-9]\).*/\1/p' | head -1)
	echo "{\"type\":\"$TYPE\",\"slots\":[$OUT],\"active\":\"$ACT\"}"
	;;
esac
exit 0
