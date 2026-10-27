#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

CFG=5gmodem
EXTIP=/usr/share/5gmodem/extip.sh
TELE=/tmp/5gmodem/tele.json
TSNAP=/tmp/5gmodem/tele.snapcache
TELE_CELL=/tmp/5gmodem/tele_cell.json
PREV=/tmp/5gmodem/tele.prev

_g() { uci -q get "$CFG.tele.$1"; }

tele_enabled() { [ "$(_g enabled)" != "0" ]; }

_AM=$(uci -q get "$CFG.@5gmodem[0].active_modem")
_KEY=$(echo "$_AM" | tr -c 'A-Za-z0-9' '_')
_SNAP="/tmp/5gmodem/metrics_${_KEY}.json"

_jf() { jsonfilter -i "$_SNAP" -e "@.$1" 2>/dev/null; }

_int() {
	case "$1" in ''|-|--|---) return ;; esac
	printf '%s' "$1" | awk '/^-?[0-9]+(\.[0-9]+)?$/ {
		_v = ($1 < 0 ? $1 - 0.5 : $1 + 0.5); printf "%.0f", int(_v) }'
}

_J=""
_num() { [ -n "$2" ] && _J="$_J${_J:+,}\"$1\":$2"; }
_str() {
	[ -n "$2" ] || return 0
	_s=$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')
	_J="$_J${_J:+,}\"$1\":\"$_s\""
}

tele_write() {
	_fresh=""
	if [ -n "$_AM" ] && [ -s "$_SNAP" ]; then
		_st=$(cat "${_SNAP%.json}.stamp" 2>/dev/null)
		case "$_st" in
			''|*[!0-9]*) ;;
			*) [ $(( $(cut -d. -f1 /proc/uptime) - _st )) -le 120 ] && _fresh=1 ;;
		esac
	fi

	_tc_hit=""
	if [ -n "$_fresh" ] && [ -s "$TSNAP" ] && [ "$(sed -n 1p "$TSNAP")" = "$_st" ]; then
		_tc_hit=1
		_J=$(sed -n 2p "$TSNAP")
	elif [ -n "$_fresh" ]; then
	_num sig  "$(_int "$(_jf signal)")"
	_str oper "$(_jf operator_name | sed 's/^-$//')"
	_str model "$(_jf modem | sed 's/^-$//')"
	_num rsrp "$(_int "$(_jf rsrp)")"
	_num rsrq "$(_int "$(_jf rsrq)")"
	_num sinr "$(_int "$(_jf sinr)")"
	_num temp "$(_int "$(_jf mtemp | sed 's/ *&deg;C//')")"
	_num bat  "$(_int "$(_jf battery)")"
	_num chg  "$(_int "$(_jf battery_charging)")"
	_num dist "$(_int "$(_jf bs_distance)")"
	_num tz   "$(_int "$(cat "/tmp/5gmodem/qmi_${_KEY}.ntz" 2>/dev/null)")"

	_pb=$(_jf pband | grep -oE '^[Bn][0-9]+' | head -1)
	_str band "$_pb"
	_ca="$_pb"
	for _i in 1 2 3 4; do
		[ "$(_jf "s${_i}state")" = "activated" ] || continue
		_sb=$(_jf "s${_i}band" | grep -oE '^[Bn][0-9]+' | head -1)
		[ -n "$_sb" ] && _ca="$_ca+$_sb"
	done
	case "$_ca" in *+*) _str ca "$_ca" ;; esac

	_md=$(_jf mode | sed 's/ *|.*//; s/ B[0-9].*//')
	case "$_md" in
		LTE-A*) _md="4G+" ;;
		LTE*)   _md="4G" ;;
		*5G\ NSA*|*NSA*) _md="5G NSA" ;;
		*5G\ SA*|NR5G*|5G\ NR*|5GNR*)  _md="5G SA" ;;
		WCDMA*|UMTS*|HSPA*|HSDPA*|HSUPA*|3G*) _md="3G" ;;
		GSM*|EDGE*|GPRS*|2G*) _md="2G" ;;
		''|-) _md="" ;;
	esac
	_str mode "$_md"

	_tc_main="$_J"
	fi

	_net=""
	[ -n "$_fresh" ] && _net=$(_jf iface)
	[ -n "$_net" ] || _net=$(uci -q get "$CFG.@5gmodem[0].network")
	if [ -n "$_net" ] && [ -f "/tmp/5gmodem/health/$_net" ]; then
		read -r _hs _hf _ho _hms _hsince < "/tmp/5gmodem/health/$_net"
		[ "$_hs" = "up" ] && _num ping "$(_int "$_hms")"
	fi

	_dev=""
	[ -n "$_net" ] && _dev=$(ubus call network.interface."$_net" status 2>/dev/null \
		| jsonfilter -e '@.l3_device' 2>/dev/null)
	if [ -n "$_dev" ] && [ -d "/sys/class/net/$_dev" ]; then
		_now=$(cut -d. -f1 /proc/uptime)
		_rxb=$(cat "/sys/class/net/$_dev/statistics/rx_bytes" 2>/dev/null)
		_txb=$(cat "/sys/class/net/$_dev/statistics/tx_bytes" 2>/dev/null)
		if [ -s "$PREV" ]; then
			read -r _pt _prx _ptx _pdev < "$PREV"
			_dt=$((_now - _pt))
			if [ "$_pdev" = "$_dev" ] && [ "$_dt" -gt 0 ] && [ "$_dt" -lt 3600 ] \
				&& [ "$_rxb" -ge "$_prx" ] && [ "$_txb" -ge "$_ptx" ]; then
				_num rx $(( (_rxb - _prx) / _dt ))
				_num tx $(( (_txb - _ptx) / _dt ))
			fi
		fi
		printf '%s %s %s %s\n' "$_now" "$_rxb" "$_txb" "$_dev" > "$PREV.tmp" \
			&& mv "$PREV.tmp" "$PREV"
	fi

	_sc=$(jsonfilter -i /tmp/5gmodem/sms_new.json -e '@.count' 2>/dev/null)
	_num sms "$(_int "$_sc")"

	_te_x=""
	[ -n "$_net" ] && [ -x "$EXTIP" ] && _te_x=$("$EXTIP" get "$_net" 2>/dev/null)
	_te_xip=""; _te_xip6=""; _te_cc=""
	if [ -n "$_te_x" ]; then
		_te_xip=$(jsonfilter -s "$_te_x" -e '@.ip' 2>/dev/null)
		_te_xip6=$(jsonfilter -s "$_te_x" -e '@.ip6' 2>/dev/null)
		_te_cc=$(jsonfilter -s "$_te_x" -e '@.cc' 2>/dev/null)
	fi
	_str cc "$_te_cc"
	if [ "$(_g publish_ip)" = "1" ]; then
		_str wan_ip  "$(_jf ipaddr | sed 's/^-$//')"
		_str ext_ip  "$_te_xip"
		_str ext_ip6 "$_te_xip6"
	fi
	[ -n "$_fresh" ] && [ "$(_g publish_phone)" = "1" ] && _str phone "$(_jf phone | tr -cd '+0-9')"

	if [ -n "$_fresh" ]; then
		case "$_J" in
			*'"sig"'*|*'"rsrp"'*|*'"oper"'*) ;;
			*)
				_tw_age=$(( $(date +%s) - $(date -r "$TELE" +%s 2>/dev/null || echo 0) ))
				if [ "$_tw_age" -lt 120 ]; then
					case "$(cat "$TELE" 2>/dev/null)" in
						*'"sig"'*|*'"rsrp"'*|*'"oper"'*) return 0 ;;
					esac
				fi ;;
		esac
	fi

	printf '{%s}\n' "$_J" > "$TELE.tmp" && mv "$TELE.tmp" "$TELE"

	_J=""
	if [ -n "$_tc_hit" ]; then
		_J=$(sed -n 3p "$TSNAP")
	elif [ -n "$_fresh" ]; then
		_num pci    "$(_int "$(_jf pci)")"
		_num earfcn "$(_int "$(_jf earfcn)")"
		_num enb    "$(_int "$(_jf enbid)")"
		_num cid    "$(_int "$(_jf cid_dec)")"
		_num tac    "$(_int "$(_jf tac_dec)")"
		_str apn    "$(_jf iface_apn | sed 's/^-$//')"
		_str wan_ip "$(_jf ipaddr | sed 's/^-$//')"
		_str modem  "$(_jf modem | sed 's/^-$//')"
		_num mcc      "$(_int "$(_jf operator_mcc)")"
		_str mnc      "$(_jf operator_mnc | grep -E '^[0-9]+$')"
		_num lac      "$(_int "$(_jf lac_dec)")"
		_str cid_hex  "$(_jf cid_hex | sed 's/^-$//')"
		_str bandwidth "$(_jf bandwidth | sed 's/^-$//')"
		_num pathloss "$(_int "$(_jf pathloss)")"
		_str txpower  "$(_jf txpower | sed 's/^-$//')"
		_num cqi      "$(_int "$(_jf cqi)")"
		_str uecat    "$(_jf uecat | sed 's/^-$//')"
		_str volte    "$(_jf volte | sed 's/^-$//')"
		_str mimo     "$(_jf pmimo | sed 's/^-$//')"
		_str rxdiv    "$(_jf rxdiv | sed 's/^-$//')"
		_str antports "$(_jf antports | sed 's/^-$//')"
		_num csq      "$(_int "$(_jf csq)")"
		_num rssi     "$(_int "$(_jf rssi)")"
		_num conn_time "$(_int "$(_jf conn_time_sec)")"
		_str therm    "$(_jf mtherm | sed 's/^-$//')"
		_num simslot  "$(_int "$(_jf simslot)")"
		_num roaming  "$(_int "$(_jf roaming)")"
		_str fw       "$(_jf firmware | sed 's/^-$//')"
		_str phone    "$(_jf phone | sed 's/^-$//')"
		_nca=0
		for _i in 1 2 3 4; do
			_sb=$(_jf "s${_i}band" | sed 's/^-$//')
			[ -n "$_sb" ] || continue
			_str "s${_i}band"   "$_sb"
			_num "s${_i}pci"    "$(_int "$(_jf "s${_i}pci")")"
			_num "s${_i}earfcn" "$(_int "$(_jf "s${_i}earfcn")")"
			_num "s${_i}rsrp"   "$(_int "$(_jf "s${_i}rsrp")")"
			_num "s${_i}rsrq"   "$(_int "$(_jf "s${_i}rsrq")")"
			_num "s${_i}sinr"   "$(_int "$(_jf "s${_i}sinr")")"
			_ss=$(_jf "s${_i}state")
			_str "s${_i}state" "$_ss"
			[ "$_ss" = "activated" ] && _nca=$((_nca + 1))
		done
		_num nca "$_nca"
		_nb=$(grep -o '"neighbors":\[[^]]*\]' "$_SNAP" 2>/dev/null | head -1)
		_nb=${_nb#\"neighbors\":}
		case "$_nb" in \[*\]) [ "$_nb" != "[]" ] && _J="$_J${_J:+,}\"nbrs\":$_nb" ;; esac
		printf '%s\n%s\n%s\n' "$_st" "$_tc_main" "$_J" > "$TSNAP.tmp" && mv "$TSNAP.tmp" "$TSNAP"
	fi
	if [ -n "$_fresh" ]; then
		_str ext_ip  "$_te_xip"
		_str ext_ip6 "$_te_xip6"
	fi
	printf '{%s}\n' "$_J" > "$TELE_CELL.tmp" && mv "$TELE_CELL.tmp" "$TELE_CELL"
}

_mqtt_args() {
	_h=$(_g mqtt_host); [ -n "$_h" ] || return 1
	command -v mosquitto_pub >/dev/null 2>&1 || return 1
	_p=$(_g mqtt_port); _u=$(_g mqtt_user); _w=$(_g mqtt_pass)
	_dn=$(_g name); [ -n "$_dn" ] || _dn=$(cat /proc/sys/kernel/hostname 2>/dev/null)
	TOPIC=$(_g mqtt_topic); [ -n "$TOPIC" ] || TOPIC="5gmodem/$_dn"
	DEVNAME="$_dn"
	DEVID=$(printf '%s' "$_dn" | tr -c 'A-Za-z0-9_-' '_')
	return 0
}

_mpub() {
	if [ -n "$_u" ] && [ -n "$_w" ]; then
		mosquitto_pub -h "$_h" -p "${_p:-1883}" -u "$_u" -P "$_w" "$@"
	elif [ -n "$_u" ]; then
		mosquitto_pub -h "$_h" -p "${_p:-1883}" -u "$_u" "$@"
	else
		mosquitto_pub -h "$_h" -p "${_p:-1883}" "$@"
	fi
}

tele_publish() {
	tele_write
	_mqtt_args || return 0
	[ -s "$TELE" ] || return 0
	_mpub -t "$TOPIC/state" -f "$TELE" 2>/dev/null \
		&& _mpub -t "$TOPIC/available" -m online 2>/dev/null
}

tele_discovery() {
	_mqtt_args || { echo '{"error":"no broker configured or mosquitto_pub missing"}'; return 1; }
	_disc() {
		[ -z "$_disc_fail" ] || return 0
		_cfg="{\"name\":\"$2\",\"state_topic\":\"$TOPIC/state\",\"value_template\":\"{{ value_json.$1 }}\""
		[ -n "$3" ] && _cfg="$_cfg,\"unit_of_measurement\":\"$3\""
		[ -n "$4" ] && _cfg="$_cfg,\"device_class\":\"$4\""
		_cfg="$_cfg,\"availability_topic\":\"$TOPIC/available\",\"unique_id\":\"${DEVNAME}_$1\""
		_cfg="$_cfg,\"device\":{\"identifiers\":[\"$DEVNAME\"],\"model\":\"luci-app-5gmodem\",\"manufacturer\":\"OpenWrt\"}}"
		_mpub -r -t "homeassistant/sensor/${DEVID}_$1/config" -m "$_cfg" 2>/dev/null || _disc_fail=1
	}
	_disc_fail=""
	_disc sig  "Signal"        "%"    signal_strength
	_disc rsrp "RSRP"          "dBm"  signal_strength
	_disc rsrq "RSRQ"          "dB"   ""
	_disc sinr "SINR"          "dB"   ""
	_disc temp "Modem temperature" "°C" temperature
	_disc oper "Operator"      ""     ""
	_disc mode "Network mode"  ""     ""
	_disc band "Band"          ""     ""
	_disc ca   "Carrier aggregation" "" ""
	_disc ping "Ping"          "ms"   duration
	_disc rx   "Download rate" "B/s"  data_rate
	_disc tx   "Upload rate"   "B/s"  data_rate
	_disc sms  "Unread SMS"    ""     ""
	_disc cc   "Exit country"  ""     ""
	if [ "$(_g publish_ip)" = "1" ]; then
		_disc wan_ip  "Carrier address"  "" ""
		_disc ext_ip  "External address" "" ""
		_disc ext_ip6 "External IPv6"    "" ""
	fi
	[ "$(_g publish_phone)" = "1" ] && _disc phone "Phone number" "" ""
	if [ -n "$_disc_fail" ]; then
		echo '{"error":"broker rejected the publish"}'
		return 1
	fi
	echo '{"result":"ok"}'
}

_refresh_snap() {
	_rf=$(_g refresh); case "$_rf" in ''|*[!0-9]*) _rf=120 ;; esac
	[ "$_rf" = "0" ] && return 0
	[ -n "$_AM" ] || return 0
	[ -e "/sys/bus/usb/devices/$_AM" ] || [ -e "/sys/bus/pci/devices/${_AM##*/}" ] || [ -d "/sys/bus/platform/devices/${_AM##*/}/remoteproc" ] || return 0
	_rs_st=$(cat "${_SNAP%.json}.stamp" 2>/dev/null)
	case "$_rs_st" in
		*[!0-9]*) _rs_st=0 ;;
		'') _rs_st=0 ;;
	esac
	[ $(( $(cut -d. -f1 /proc/uptime) - _rs_st )) -ge "$_rf" ] || return 0
	SW_BG=1 "$(dirname "$0")/5gmodem.sh" cached 60 "for=$_AM" >/dev/null 2>&1 &
	_rs_p=$!
	( sleep 25; kill "$_rs_p" 2>/dev/null ) >/dev/null 2>&1 &
	_rs_w=$!
	wait "$_rs_p" 2>/dev/null
	kill "$_rs_w" 2>/dev/null; wait "$_rs_w" 2>/dev/null
	return 0
}

case "$1" in
	tick)      tele_enabled || exit 0
	           [ -n "$_AM" ] || exit 0
	           [ -e "/sys/bus/usb/devices/$_AM" ] || [ -e "/sys/bus/pci/devices/${_AM##*/}" ] || [ -d "/sys/bus/platform/devices/${_AM##*/}/remoteproc" ] || exit 0
	           _refresh_snap
	           if _mqtt_args >/dev/null 2>&1; then tele_publish; else tele_write; fi ;;
	write)     tele_enabled && tele_write ;;
	publish)   tele_enabled && tele_publish ;;
	discovery) tele_discovery ;;
	show)      cat "$TELE" 2>/dev/null ;;
	status)    _st_cl=0; command -v mosquitto_pub >/dev/null 2>&1 && _st_cl=1
	           _st_br=0; [ -n "$(_g mqtt_host)" ] && _st_br=1
	           _st_age=""
	           if [ -s "$TELE" ]; then
	               _st_m=$(date -r "$TELE" +%s 2>/dev/null)
	               [ -n "$_st_m" ] && _st_age=$(( $(date +%s) - _st_m ))
	           fi
	           printf '{"mqtt_client":%s,"broker":%s,"file_age":"%s"}\n' "$_st_cl" "$_st_br" "$_st_age" ;;
	*) echo "usage: $0 {write|publish|discovery|show|status}" >&2; exit 1 ;;
esac
exit 0
