#!/bin/sh
RES=/usr/share/5gmodem
CFG=5gmodem
CACHE_DIR=/tmp/5gmodem
UA="5gmodem"
. "$RES/lib.sh"

_hl_path() { [ -n "$1" ] && echo "$1" || uci -q get "$CFG.@5gmodem[0].active_modem"; }

_netdev_for() {
	_p=$(_hl_path "$1")
	[ -n "$_p" ] || return 1
	_s="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_d=$(uci -q get "$CFG.$_s.netdev")
	[ -n "$_d" ] && { echo "$_d"; return 0; }
	"$RES/listmodems.sh" 2>/dev/null | jsonfilter -e "@[@.path=\"$_p\"].net[0]" 2>/dev/null
}

_srcip_for() {
	_dev=$(_netdev_for "$1") || return 1
	_net="${2%.*}."
	ip -4 addr show dev "$_dev" 2>/dev/null \
		| sed -n 's|.*inet \([0-9.]*\)/.*|\1|p' \
		| grep "^$_net" | head -1
}

_addr_for() {
	_dev=$(_netdev_for "$1") || return 1
	[ -n "$_dev" ] || return 1
	_gw=$(ip route show dev "$_dev" 2>/dev/null \
		| sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
	if [ -z "$_gw" ]; then
		_ip=$(ip -4 addr show dev "$_dev" 2>/dev/null \
			| sed -n 's|.*inet \([0-9.]*\)/.*|\1|p' | head -1)
		[ -n "$_ip" ] && _gw="${_ip%.*}.1"
	fi
	[ -n "$_gw" ] || return 1
	echo "$_gw"
}

_sess_file() { echo "$CACHE_DIR/hilink_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"; }

_sess_new() {
	_a="$1"; _d="$2"
	_src=$(_srcip_for "$3" "$_a"); [ -n "$_src" ] || _src="$_d"
	_r=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
		"http://$_a/api/webserver/SesTokInfo" 2>/dev/null)
	_sid=$(echo "$_r" | sed -n 's|.*<SesInfo>\(.*\)</SesInfo>.*|\1|p')
	_tok=$(echo "$_r" | sed -n 's|.*<TokInfo>\(.*\)</TokInfo>.*|\1|p')
	[ -n "$_sid" ] && [ -n "$_tok" ] || return 1
	printf '%s\t%s\n' "$_sid" "$_tok" > "$(_sess_file "$_a")"
	printf '%s\t%s\n' "$_sid" "$_tok"
}

_sess_get() {
	_f=$(_sess_file "$1")
	if [ -s "$_f" ] && [ -z "$(find "$_f" -mmin +1 2>/dev/null)" ]; then
		cat "$_f"
		return 0
	fi
	_sess_new "$1" "$2" "$3"
}

api_get() {
	_ep="$1"
	_a=$(_addr_for "$2") || return 1
	_d=$(_netdev_for "$2") || return 1
	_s=$(_sess_get "$_a" "$_d" "$2") || return 1
	_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
	_src=$(_srcip_for "$2" "$_a"); [ -n "$_src" ] || _src="$_d"
	_out=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		"http://$_a$_ep" 2>/dev/null)
	case "$_out" in
		''|*'<code>125002</code>'*|*'<code>125003</code>'*|*'<code>125001</code>'*)
			_s=$(_sess_new "$_a" "$_d" "$2") || return 1
			_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
			_out=$(curl -s --max-time 6 --interface "$_src" -A "$UA" \
				-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
				"http://$_a$_ep" 2>/dev/null)
			;;
	esac
	printf '%s' "$_out"
}

api_post() {
	_ep="$1"; _body="$2"
	_a=$(_addr_for "$3") || return 1
	_d=$(_netdev_for "$3") || return 1
	_s=$(_sess_new "$_a" "$_d" "$3") || return 1
	_sid=$(printf '%s' "$_s" | cut -f1); _tok=$(printf '%s' "$_s" | cut -f2)
	_src=$(_srcip_for "$3" "$_a"); [ -n "$_src" ] || _src="$_d"
	curl -s --max-time 10 --interface "$_src" -A "$UA" \
		-H "Cookie: $_sid" -H "__RequestVerificationToken: $_tok" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data "<?xml version=\"1.0\" encoding=\"UTF-8\"?><request>$_body</request>" \
		"http://$_a$_ep" 2>/dev/null
}

xval() {
	tr -d '\r' | sed 's|<|\
<|g' | sed -n "s|^<$1>\(.*\)\$|\1|p" | head -1
}

jsafe() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

_xesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

hl_getroaming() {
	_gr=$(api_get /api/dialup/connection "$1" 2>/dev/null | xval RoamAutoConnectEnable)
	case "$_gr" in 1) echo 1 ;; *) echo 0 ;; esac
}

hl_setroaming() {
	case "$2" in 0|1) : ;; *) echo '{"error":"value must be 0 or 1"}'; return 0 ;; esac
	_sr_cur=$(api_get /api/dialup/connection "$1" 2>/dev/null)
	_sr_idle=$(printf '%s' "$_sr_cur" | xval MaxIdelTime);   [ -n "$_sr_idle" ] || _sr_idle=0
	_sr_cm=$(printf '%s' "$_sr_cur"   | xval ConnectMode);   [ -n "$_sr_cm" ]   || _sr_cm=0
	_sr_mtu=$(printf '%s' "$_sr_cur"  | xval MTU);           [ -n "$_sr_mtu" ]  || _sr_mtu=1500
	_sr_ads=$(printf '%s' "$_sr_cur"  | xval auto_dial_switch); [ -n "$_sr_ads" ] || _sr_ads=1
	_sr_pao=$(printf '%s' "$_sr_cur"  | xval pdp_always_on);    [ -n "$_sr_pao" ] || _sr_pao=1
	_sr_r=$(api_post /api/dialup/connection \
		"<RoamAutoConnectEnable>$2</RoamAutoConnectEnable><MaxIdelTime>$_sr_idle</MaxIdelTime><ConnectMode>$_sr_cm</ConnectMode><MTU>$_sr_mtu</MTU><auto_dial_switch>$_sr_ads</auto_dial_switch><pdp_always_on>$_sr_pao</pdp_always_on>" \
		"$1")
	case "$_sr_r" in
		*'<response>OK</response>'*) printf '{"success":true,"allow_roaming":"%s"}\n' "$2" ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_sr_r" | xval code)" ;;
	esac
}

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

_human() {
	_b="$1"
	case "$_b" in ''|*[!0-9]*) echo "-"; return ;; esac
	if   [ "$_b" -ge 1073741824 ]; then
		printf '%d.%d GiB\n' $(( _b / 1073741824 )) $(( _b % 1073741824 * 10 / 1073741824 ))
	elif [ "$_b" -ge 1048576 ]; then
		printf '%d.%d MiB\n' $(( _b / 1048576 )) $(( _b % 1048576 * 10 / 1048576 ))
	elif [ "$_b" -ge 1024 ]; then
		printf '%d.%d KiB\n' $(( _b / 1024 )) $(( _b % 1024 * 10 / 1024 ))
	else
		printf '%d B\n' "$_b"
	fi
}

conn_up() { [ "$1" = "901" ]; }

_web_pass() {
	uci -q get "$CFG.m_$(echo "${1:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}" \
		| sed 's/[^A-Za-z0-9]/_/g').web_pass"
}

_zte_pass() {
	_zp=$(_web_pass "$1")
	[ -n "$_zp" ] && { printf '%s' "$_zp"; return; }
	printf 'admin'
}

_zte_b64() {
	if command -v base64 >/dev/null 2>&1; then printf '%s' "$1" | base64 | tr -d '\n'; return; fi
	if command -v openssl >/dev/null 2>&1; then printf '%s' "$1" | openssl base64 | tr -d '\n'; return; fi
	printf '%s' "$1"
}

_zte_login() {
	_zl_f="$CACHE_DIR/ztestok_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"
	if [ -s "$_zl_f" ] && [ -z "$(find "$_zl_f" -mmin +5 2>/dev/null)" ]; then
		cat "$_zl_f"; return 0
	fi
	_zl_bad="$_zl_f.fail"
	if [ -f "$_zl_bad" ] && [ -z "$(find "$_zl_bad" -mmin +15 2>/dev/null)" ]; then
		return 1
	fi
	_zl_src=$(_srcip_for "" "$1")
	_zl_h=$(curl -s -i --max-time 8 ${_zl_src:+--interface "$_zl_src"} -A "$UA" \
		-H "Referer: http://$1/index.html" \
		-H "X-Requested-With: XMLHttpRequest" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "isTest=false&goformId=LOGIN&password=$(_zte_b64 "$(_zte_pass)")" \
		"http://$1/$(_zte_setpath "$1")" 2>/dev/null)
	_zl_t=$(printf '%s' "$_zl_h" | sed -n 's/.*[Ss]et-[Cc]ookie: *stok=\([^;[:space:]]*\).*/\1/p' | head -1)
	if [ -n "$_zl_t" ]; then
		rm -f "$_zl_bad"
		printf '%s' "$_zl_t" > "$_zl_f"
		printf '%s' "$_zl_t"
		return 0
	fi
	[ -f "$_zl_bad" ] || logger -t 5gmodem "hilink(zte): login to $1 failed - not retrying for 15 minutes so the stick does not lock its web login; set the web password in the modem section (web_pass)"
	: > "$_zl_bad"
	return 1
}

_zte_paths() {
	_zp_f="$CACHE_DIR/ztepath_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"
	if [ -s "$_zp_f" ] && [ -z "$(find "$_zp_f" -mmin +30 2>/dev/null)" ]; then
		cat "$_zp_f"; return 0
	fi
	_zp_src=$(_srcip_for "" "$1")
	for _zp_b in "goform/goform_get_cmd_process goform/goform_set_cmd_process" "reqproc/proc_get reqproc/proc_post"; do
		_zp_r=$(curl -s --max-time 5 ${_zp_src:+--interface "$_zp_src"} -A "$UA" \
			-H "Referer: http://$1/index.html" \
			-H "X-Requested-With: XMLHttpRequest" \
			"http://$1/${_zp_b%% *}?isTest=false&multi_data=1&cmd=modem_main_state" 2>/dev/null)
		case "$_zp_r" in
			*'"modem_main_state"'*) printf '%s' "$_zp_b" > "$_zp_f"; printf '%s' "$_zp_b"; return 0 ;;
		esac
	done
	printf 'goform/goform_get_cmd_process goform/goform_set_cmd_process'
}

_zte_getpath() { _zgp=$(_zte_paths "$1"); printf '%s' "${_zgp%% *}"; }
_zte_setpath() { _zsp=$(_zte_paths "$1"); printf '%s' "${_zsp##* }"; }

_zte_get() {
	_zg_src=$(_srcip_for "" "$1")
	_zg_tok=$(cat "$CACHE_DIR/ztestok_$(echo "$1" | tr -c 'A-Za-z0-9' '_')" 2>/dev/null)
	curl -s --max-time 6 ${_zg_src:+--interface "$_zg_src"} -A "$UA" \
		-H "Referer: http://$1/index.html" \
		-H "X-Requested-With: XMLHttpRequest" \
		${_zg_tok:+-b "stok=$_zg_tok"} \
		"http://$1/$(_zte_getpath "$1")?isTest=false&multi_data=1&cmd=$2" 2>/dev/null
}

_zte_set() {
	_zs_src=$(_srcip_for "" "$1")
	curl -s --max-time 8 ${_zs_src:+--interface "$_zs_src"} -A "$UA" \
		${3:+-b "$3" -c "$3"} \
		-H "Referer: http://$1/index.html" \
		-H "X-Requested-With: XMLHttpRequest" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "isTest=false&$2" \
		"http://$1/$(_zte_setpath "$1")" 2>/dev/null
}

_zj() { printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null; }

_vidpid_for() {
	_vf_p="$1"
	[ -n "$_vf_p" ] || _vf_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	uci -q get "$CFG.m_$(echo "$_vf_p" | sed 's/[^A-Za-z0-9]/_/g').vidpid"
}

_api_vid() {
	_av_p="$1"
	[ -n "$_av_p" ] || _av_p=$(uci -q get "$CFG.@5gmodem[0].active_modem")
	if [ "$(uci -q get "$CFG.m_$(echo "$_av_p" | sed 's/[^A-Za-z0-9]/_/g').hl_api")" = zte ]; then
		echo "19d2:web"; return 0
	fi
	_vidpid_for "$_av_p"
}

_tk() { echo "$1" | tr -c 'A-Za-z0-9' '_'; }

_tenda_raw() {
	_tr_src=$(_srcip_for "" "$1")
	_tr_c=$(cat "$CACHE_DIR/tendaauth_$(_tk "$1")" 2>/dev/null)
	curl -s --max-time 6 ${_tr_src:+--interface "$_tr_src"} -A "$UA" \
		${_tr_c:+-b "password=$_tr_c"} \
		"http://$1/goform/getModules?modules=$2" 2>/dev/null
}

_tenda_on() {
	_to_f="$CACHE_DIR/tendaapi_$(_tk "$1")"
	if [ -f "$_to_f" ] && [ -z "$(find "$_to_f" -mmin +10 2>/dev/null)" ]; then
		[ "$(cat "$_to_f")" = 1 ] && return 0
		return 1
	fi
	_to_r=$(_tenda_raw "$1" deviceInfo)
	case "$_to_r" in
		'') return 2 ;;
		*'"deviceInfo"'*|*'"errCode":1000'*|*'"errCode":"1000"'*) printf '1' > "$_to_f"; return 0 ;;
	esac
	printf '0' > "$_to_f"
	return 1
}

_tenda_login() {
	_tl_f="$CACHE_DIR/tendaauth_$(_tk "$1")"
	_tl_bad="$_tl_f.fail"
	if [ -f "$_tl_bad" ] && [ -z "$(find "$_tl_bad" -mmin +15 2>/dev/null)" ]; then
		return 1
	fi
	_tl_p=$(_web_pass "$2")
	if [ -n "$_tl_p" ]; then
		_tl_src=$(_srcip_for "" "$1")
		_tl_r=$(curl -s -i --max-time 8 ${_tl_src:+--interface "$_tl_src"} -A "$UA" \
			-H "Content-Type: application/json; charset=UTF-8" \
			-d "{\"userName\":\"admin\",\"password\":\"$(printf '%s' "$_tl_p" | md5sum | cut -d' ' -f1)\"}" \
			"http://$1/login/Auth" 2>/dev/null | tr -d '\r')
		case "$_tl_r" in *'"errCode"'*) ;; *) return 2 ;; esac
		case "$_tl_r" in
			*'"errCode":0'*|*'"errCode":"0"'*)
				_tl_c=$(printf '%s\n' "$_tl_r" | sed -n 's/^[Ss]et-[Cc]ookie: *password=\([^;[:space:]]*\).*/\1/p' | head -1)
				if [ -n "$_tl_c" ]; then
					rm -f "$_tl_bad"
					printf '%s' "$_tl_c" > "$_tl_f"
					printf '%s' "$_tl_c"
					return 0
				fi ;;
		esac
	fi
	if [ ! -f "$_tl_bad" ]; then
		if [ -n "$_tl_p" ]; then
			logger -t 5gmodem "hilink(tenda): login to $1 failed - wrong web password? Not retrying for 15 minutes so the stick does not lock its web login"
		else
			logger -t 5gmodem "hilink(tenda): $1 asks for its web password - set it on the Network page (key button in the modem card)"
		fi
	fi
	: > "$_tl_bad"
	return 1
}

_tenda_denied() {
	case "$1" in *'"errCode":1000'*|*'"errCode":"1000"'*) return 0 ;; esac
	return 1
}

_tenda_get() {
	_tg_r=$(_tenda_raw "$1" "$2")
	if _tenda_denied "$_tg_r"; then
		rm -f "$CACHE_DIR/tendaauth_$(_tk "$1")"
		_tenda_login "$1" "$3" >/dev/null && _tg_r=$(_tenda_raw "$1" "$2")
	fi
	printf '%s' "$_tg_r"
}

_tenda_post() {
	_tp_src=$(_srcip_for "" "$1")
	_tp_c=$(cat "$CACHE_DIR/tendaauth_$(_tk "$1")" 2>/dev/null)
	curl -s --max-time 8 ${_tp_src:+--interface "$_tp_src"} -A "$UA" \
		${_tp_c:+-b "password=$_tp_c"} \
		-H "Content-Type: application/json; charset=UTF-8" \
		-d "$3" "http://$1/goform/setModules?modules=$2" 2>/dev/null
}

_tenda_set() {
	_ts_r=$(_tenda_post "$1" "$2" "$3")
	case "$_ts_r" in *'"errCode"'*) ;; *) _ts_r="" ;; esac
	if [ -z "$_ts_r" ] || _tenda_denied "$_ts_r"; then
		rm -f "$CACHE_DIR/tendaauth_$(_tk "$1")"
		_tenda_login "$1" "$4" >/dev/null && _ts_r=$(_tenda_post "$1" "$2" "$3")
	fi
	printf '%s' "$_ts_r"
}

_tenda_ok() {
	case "$1" in *'"errCode":0'*|*'"errCode":"0"'*) return 0 ;; esac
	return 1
}

_is_tenda() {
	_it_a=$(_addr_for "$(_hl_path "$1")") || return 1
	_tenda_on "$_it_a"
}

tenda_metrics_json() {
	_HLP=$(_hl_path "$1")
	_a=$(_addr_for "$_HLP") || return 2
	_tenda_on "$_a"
	case $? in 1) return 1 ;; 2) return 2 ;; esac
	_r=$(_tenda_get "$_a" "deviceInfo,connectStatus,batteryInfo,networkConfig" "$_HLP")
	[ -n "$_r" ] || return 2
	if _tenda_denied "$_r"; then
		[ -f "$CACHE_DIR/tendaauth_$(_tk "$_a").fail" ] || return 2
		printf '{"backend":"hilink","cport":"%s","protocol":"HiLink (web API)",' "$_a"
		printf '"modem":"Tenda","web_auth":"fail","registration":"","signal":"","conn_status":""}\n'
		return 0
	fi
	case "$_r" in *'"deviceInfo"'*) ;; *) return 2 ;; esac
	_tj() { printf '%s' "$_r" | jsonfilter -e "@.deviceInfo.$1" 2>/dev/null; }
	_net=$(_tj mobileNetwork)
	case "$_net" in
		4G*|LTE*) _ntype="LTE" ;;
		5G*) _ntype="5G" ;;
		3G*) _ntype="UMTS" ;;
		2G*) _ntype="GSM" ;;
		*) _ntype="$_net" ;;
	esac
	_rsrp=$(_tj RSRP | tr -cd '0-9-')
	_sinr=$(_tj SINR | tr -cd '0-9.-')
	_rssi=$(_tj RSSI | tr -cd '0-9-')
	_bars=$(_tj signalStrength | tr -cd '0-9')
	_pct=""; [ -n "$_bars" ] && _pct=$(( _bars * 20 )) && [ "$_pct" -gt 100 ] && _pct=100
	_sp=$(sig_percent "$_ntype" "$_rsrp" "" "$_sinr" "" "" "$_rssi")
	[ -n "$_sp" ] && _pct="$_sp"
	_tb=$(_tj networkFrequencyBand | sed -n 's/.*[Bb]and *\([0-9][0-9]*\).*/\1/p')
	_tpband=""; [ -n "$_tb" ] && _tpband="B$_tb"
	_reg=0
	[ "$(printf '%s' "$_r" | jsonfilter -e '@.connectStatus.status' 2>/dev/null)" = "1" ] && _reg=1
	_csq=""
	if [ -n "$_rssi" ]; then
		_csq=$(( ( _rssi + 113 ) / 2 ))
		[ "$_csq" -lt 0 ] && _csq=0; [ "$_csq" -gt 31 ] && _csq=31
	fi
	_bat=$(printf '%s' "$_r" | jsonfilter -e '@.batteryInfo.battery' 2>/dev/null | tr -cd '0-9')
	_chg=$(printf '%s' "$_r" | jsonfilter -e '@.batteryInfo.isCharge' 2>/dev/null)
	[ "$_chg" = true ] && _chg=1 || _chg=0
	_ctime=$(printf '%s' "$_r" | jsonfilter -e '@.networkConfig.networkInfo.connectTime' 2>/dev/null | tr -cd '0-9')
	[ "$_reg" = 1 ] || _ctime=""
	_ct_str="-"
	if [ -n "$_ctime" ]; then
		_ct_str=$(printf "%dd, %02d:%02d:%02d" \
			$(( _ctime / 86400 )) $(( _ctime / 3600 % 24 )) \
			$(( _ctime / 60 % 60 )) $(( _ctime % 60 )))
	fi
	_model="Tenda $(_tj productName)"
	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s",' "$_a"
	printf '"protocol":"HiLink (web API)","vidpid":"%s",' "$(_vidpid_for "$_HLP")"
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"web_auth":"%s",' "$([ -s "$CACHE_DIR/tendaauth_$(_tk "$_a")" ] && echo ok || echo open)"
	printf '"imei":"%s","imsi":"%s","iccid":"%s",' "$(_tj IMEI)" "$(_tj IMSI)" "$(_tj ICCID)"
	printf '"firmware":"%s","phone":"",' "$(jsafe "$(_tj softwareVersion)")"
	printf '"operator_name":"%s",' "$(jsafe "$(_tj profileName)")"
	printf '"operator_mcc":"","operator_mnc":"",'
	printf '"registration":"%s",' "$_reg"
	_tmode="$_ntype"
	[ "$_ntype" = LTE ] && [ -n "$_tpband" ] && _tmode="LTE $_tpband"
	printf '"mode":"%s",' "$(jsafe "$_tmode")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"","sinr":"%s","rssi":"%s",' "$_rsrp" "$_sinr" "$_rssi"
	printf '"cid_dec":"","cid_hex":"","lac_hex":"",'
	printf '"pci":"","pband":"%s","enbid":"",' "$_tpband"
	printf '"ipaddr":"%s",' "$(_tj wanIp)"
	printf '"battery":"%s","battery_charging":"%s",' "$_bat" "$_chg"
	[ -n "$_ctime" ] && printf '"conn_time":"%s","conn_time_sec":"%s",' "$_ct_str" "$_ctime"
	printf '"csq":"%s",' "$_csq"
	printf '"conn_status":"%s"' "$([ "$_reg" = 1 ] && echo connected || echo disconnected)"
	printf '}\n'
}

zte_metrics_json() {
	_HLP=$(_hl_path "$1")
	_a=$(_addr_for "$_HLP") || return 1
	_zm_cmd="modem_main_state,ppp_status,network_type,network_provider,network_provider_fullname,signalbar,lte_rsrp,lte_rsrq,lte_rssi,lte_snr,rssi,rscp,ecio,cell_id,lac_code,rmcc,rmnc,hmcc,hmnc,wan_ipaddr,imei,msisdn,sim_imsi,iccid,wa_inner_version,lte_pci,lte_band,wan_active_band,hardware_version,battery_vol_percent,battery_charging,realtime_time,realtime_rx_bytes,realtime_tx_bytes"
	_r=$(_zte_get "$_a" "$_zm_cmd")
	case "$_r" in
		*'"modem_main_state"'*|*'"ppp_status"'*) ;;
		*)
		    _zm_m="/tmp/5gmodem/zteapi_$(echo "$_a" | tr -c 'A-Za-z0-9' '_')"
		    if [ ! -f "$_zm_m" ]; then
			: > "$_zm_m"
			logger -t 5gmodem "hilink(zte): $_a did not answer $(_zte_getpath "$_a") (first 120 chars: $(printf '%s' "$_r" | tr '\n' ' ' | head -c 120))"
		    fi
		    return 1 ;;
	esac
	case "$(_zj "$_r" lte_rsrp)$(_zj "$_r" rssi)" in
		'') if _zte_login "$_a" >/dev/null 2>&1; then
			_r2=$(_zte_get "$_a" "$_zm_cmd")
			case "$_r2" in *'"modem_main_state"'*|*'"ppp_status"'*) _r="$_r2" ;; esac
		   fi ;;
	esac
	_model="ZTE"
	case "$(_vidpid_for "$_HLP")" in 19d2:*|"") ;; *) _model="" ;; esac
	_ntype=$(_zj "$_r" network_type)
	_op=$(_zj "$_r" network_provider_fullname)
	[ -n "$_op" ] || _op=$(_zj "$_r" network_provider)
	_bars=$(_zj "$_r" signalbar | tr -cd '0-9')
	_pct=""; [ -n "$_bars" ] && _pct=$(( _bars * 20 )) && [ "$_pct" -gt 100 ] && _pct=100
	_rsrp=$(_zj "$_r" lte_rsrp | tr -cd '0-9-')
	_rsrq=$(_zj "$_r" lte_rsrq | tr -cd '0-9.-')
	_sinr=$(_zj "$_r" lte_snr | tr -cd '0-9.-')
	_rssi=$(_zj "$_r" lte_rssi | grep -oE -- '-?[0-9]+' | head -1)
	[ -n "$_rssi" ] && [ "$_rssi" = "$_rsrp" ] && _rssi=""
	_sp=$(sig_percent "$_ntype" "$_rsrp" "$_rsrq" "$_sinr" "" "" "$_rssi")
	[ -n "$_sp" ] && _pct="$_sp"
	[ -n "$_rssi" ] || _rssi=$(_zj "$_r" rssi | grep -oE -- '-?[0-9]+' | head -1)
	[ -n "$_rssi" ] && [ "$_rssi" = "$_rsrp" ] && _rssi=""
	_cid_hex=$(_zj "$_r" cell_id)
	_cid=""; [ -n "$_cid_hex" ] && _cid=$(printf '%d' "0x$_cid_hex" 2>/dev/null)
	_lac=$(_zj "$_r" lac_code)
	_zenb=""
	case "$_ntype" in *LTE*) [ -n "$_cid" ] && _zenb=$(( _cid >> 8 )) ;; esac
	_zpci=$(_zj "$_r" lte_pci | tr -cd '0-9')
	_zband=$(_zj "$_r" lte_band | tr -cd '0-9')
	[ -n "$_zband" ] || _zband=$(_zj "$_r" wan_active_band | sed -n 's/^LTE[^0-9]*\([0-9][0-9]*\).*/\1/p')
	_zpband=""; [ -n "$_zband" ] && _zpband="B$_zband"
	_mcc=$(_zj "$_r" rmcc); [ -n "$_mcc" ] || _mcc=$(_zj "$_r" hmcc)
	_mnc=$(_zj "$_r" rmnc); [ -n "$_mnc" ] || _mnc=$(_zj "$_r" hmnc)
	_wanip=$(_zj "$_r" wan_ipaddr)
	_imei=$(_zj "$_r" imei)
	_imsi=$(_zj "$_r" sim_imsi)
	_iccid=$(_zj "$_r" iccid)
	_fw=$(_zj "$_r" wa_inner_version)
	_phone=$(_zj "$_r" msisdn)
	_mfm=$(printf '%s' "$_fw" | grep -oE 'MF[0-9]+[A-Za-z]*' | head -1 | sed 's/V$//')
	[ -n "$_mfm" ] || _mfm=$(_zj "$_r" hardware_version | grep -oE 'MF[0-9]+[A-Za-z]*' | head -1 | sed 's/V$//')
	[ -n "$_mfm" ] && _model="${_model:+$_model }$_mfm"
	_zbat=$(_zj "$_r" battery_vol_percent | tr -cd '0-9')
	_zchg=$(_zj "$_r" battery_charging | tr -cd '0-9')
	_zat_ok=""
	case "$(_vidpid_for "$_HLP")" in
		0e8d:2004|0e8d:2008)
			_zat=$(mtk_cell "$_a" "$_HLP")
			_zes=$(printf '%s\n' "$_zat" | sed -n 's/^+ECSQ: *//p' | head -1)
			if [ -n "$_zes" ]; then
				_zat_ok=1
				read -r _zq1 _zq2 _zq3 <<ZQ_EOF
$(printf '%s' "$_zes" | awk -F, '{
					q=$6; p=$7; n=$9
					printf "%s %s %s", (q<=0 && q>-200 ? sprintf("%.1f", q/4) : "-"), (p<0 && p>-700 ? sprintf("%.0f", p/4) : "-"), (n!=32767 && n>-200 && n<400 ? sprintf("%.1f", n/4) : "-") }')
ZQ_EOF
				[ "$_zq1" != "-" ] && _rsrq="$_zq1"
				[ "$_zq2" != "-" ] && _rsrp="$_zq2"
				[ "$_zq3" != "-" ] && _sinr="$_zq3"
				_zcs=$(printf '%s\n' "$_zat" | sed -n 's/^+CSQ: *\([0-9]*\).*/\1/p' | head -1)
				[ -n "$_zcs" ] && [ "$_zcs" -lt 99 ] && _rssi=$(( _zcs * 2 - 113 ))
				_zec=$(printf '%s\n' "$_zat" | sed -n 's/^+ECELL: *//p' | head -1 | tr -d '"')
				if [ -n "$_zec" ]; then
					read -r _zc1 _zc2 _zc3 _zc4 _zc5 <<ZC_EOF
$(printf '%s' "$_zec" | awk -F, '{ print $3, $4, $7, $5, $6 }')
ZC_EOF
					case "$_zc1" in ''|*[!0-9A-Fa-f]*|0FFFFFFF) ;; *)
						_cid_hex="$_zc1"; _cid=$(printf '%d' "0x$_zc1" 2>/dev/null); _zenb=$(( _cid >> 8 )) ;;
					esac
					case "$_zc2" in ''|*[!0-9A-Fa-f]*|FFFF) ;; *) _lac="$_zc2" ;; esac
					case "$_zc3" in ''|*[!0-9]*) ;; *) [ "$_zc3" -lt 504 ] && _zpci="$_zc3" ;; esac
					case "$_zc4" in [0-9][0-9][0-9]) [ -n "$_mcc" ] || _mcc="$_zc4" ;; esac
					case "$_zc5" in [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
						[ -n "$_mnc" ] || _mnc=$(printf '%02d' "$_zc5") ;; esac
				fi
				_sp=$(sig_percent "$_ntype" "$_rsrp" "$_rsrq" "$_sinr" "" "" "$_rssi")
				[ -n "$_sp" ] && _pct="$_sp"
			fi ;;
	esac
	_pps=$(_zj "$_r" ppp_status)
	_reg=0
	if [ "$_pps" = "ppp_connected" ]; then
		if [ -n "$_mcc" ] && [ "$_mcc" = "$(_zj "$_r" hmcc)" ]; then _reg=1; else _reg=5; fi
		[ -z "$(_zj "$_r" hmcc)" ] && _reg=1
	fi
	_csq=""
	if [ -n "$_rssi" ]; then
		_csq=$(( ( _rssi + 113 ) / 2 ))
		[ "$_csq" -lt 0 ] && _csq=0; [ "$_csq" -gt 31 ] && _csq=31
	fi
	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s",' "$_a"
	printf '"protocol":"HiLink (web API)","vidpid":"%s",' "$(_vidpid_for "$_HLP")"
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s","imsi":"%s","iccid":"%s",' "$_imei" "$_imsi" "$_iccid"
	printf '"firmware":"%s","phone":"%s",' "$(jsafe "$_fw")" "$(jsafe "$_phone")"
	printf '"operator_name":"%s",' "$(jsafe "$_op")"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	_zmode="$_ntype"
	case "$_ntype" in *LTE*) [ -n "$_zpband" ] && _zmode="$_ntype $_zpband" ;; esac
	printf '"mode":"%s",' "$(jsafe "$_zmode")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"cid_dec":"%s","cid_hex":"%s","lac_hex":"%s",' "$_cid" "$_cid_hex" "$_lac"
	printf '"pci":"%s","pband":"%s","enbid":"%s",' "$_zpci" "$_zpband" "$_zenb"
	printf '"ipaddr":"%s",' "$_wanip"
	printf '"csq":"%s",' "$_csq"
	printf '"battery":"%s","battery_charging":"%s","hl_modes":"1",' "$_zbat" "$_zchg"
	case "$(_vidpid_for "$_HLP")" in
		0e8d:2004|0e8d:2008)
			[ -n "$_zat_ok" ] || printf '"na":"csq rssi sinr rsrq pband",'
			_ztm=$(mtk_temps "$_a" "$_HLP")
			[ -n "$_ztm" ] && printf '"temps":"%s",' "$_ztm" ;;
	esac
	_zct=$(_zj "$_r" realtime_time | tr -cd '0-9')
	if [ -n "$_zct" ] && [ "$_pps" = ppp_connected ]; then
		printf '"conn_time":"%s","conn_time_sec":"%s",' "$(printf "%dd, %02d:%02d:%02d" \
			$(( _zct / 86400 )) $(( _zct / 3600 % 24 )) $(( _zct / 60 % 60 )) $(( _zct % 60 )))" "$_zct"
	fi
	_zrx=$(_zj "$_r" realtime_rx_bytes | tr -cd '0-9')
	_ztx=$(_zj "$_r" realtime_tx_bytes | tr -cd '0-9')
	[ -n "$_zrx$_ztx" ] && printf '"rx":"%s","tx":"%s",' "$(_human "$_zrx")" "$(_human "$_ztx")"
	printf '"conn_status":"%s"' "$_pps"
	printf '}\n'
}

_yota_get() {
	_yg_src=$(_srcip_for "" "$1")
	curl -s --max-time 6 ${_yg_src:+--interface "$_yg_src"} -A "$UA" "http://$1/status" 2>/dev/null | tr -d '\r'
}

_yv() { printf '%s\n' "$1" | sed -n "s|^$2[[:space:]]*=[[:space:]]*||p" | head -1; }

yota_metrics_json() {
	_HLP=$(_hl_path "$1")
	_a=$(_addr_for "$_HLP") || return 1
	_r=$(_yota_get "$_a")
	case "$_r" in *InterfaceType*=*) ;; *) return 1 ;; esac
	_model=$(_yv "$_r" DeviceName)
	_fw=$(_yv "$_r" FirmwareVersion)
	_state=$(_yv "$_r" State)
	_itype=$(_yv "$_r" InterfaceType)
	_imei=$(_yv "$_r" 3GPP.IMEI | tr -cd '0-9')
	_imsi=$(_yv "$_r" 3GPP.IMSI | tr -cd '0-9')
	_phone=$(_yv "$_r" 3GPP.MSISDN)
	_rsrp=$(_yv "$_r" 3GPP.RSRP | tr -cd '0-9.-')
	_rsrq=$(_yv "$_r" 3GPP.RSRQ | tr -cd '0-9.-')
	_sinr=$(_yv "$_r" 3GPP.SINR | tr -cd '0-9.-')
	_rssi=$(_yv "$_r" 3GPP.RSSI | tr -cd '0-9.-')
	_mcc=$(_yv "$_r" 3GPP.MCC | tr -cd '0-9')
	_mnc=$(_yv "$_r" 3GPP.MNC | tr -cd '0-9')
	_cid_hex=$(_yv "$_r" 3GPP.CI | tr -cd '0-9A-Fa-f')
	_lac=$(_yv "$_r" 3GPP.LAC | tr -cd '0-9A-Fa-f')
	_roam=$(_yv "$_r" 3GPP.RoamingStatus)
	_op=$(_yv "$_r" 3GPP.SPN)
	_cid=""; _enb=""
	if [ -n "$_cid_hex" ]; then
		_cid=$(printf '%d' "0x$_cid_hex" 2>/dev/null)
		[ -n "$_cid" ] && _enb=$(( _cid >> 8 ))
	fi
	_num="$_mcc$_mnc"
	if [ ${#_num} -ge 5 ]; then
		_dbop=$(awk -F';' -v k="$_num" '$1 == k { print $3 }' "$RES/mccmnc.dat" 2>/dev/null \
			| head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
		[ -n "$_dbop" ] && _op="$_dbop"
	fi
	_obr=$(opname_brand "$_imsi") && _op="$_obr"
	_mode=""
	case "$_itype" in lte|LTE) _mode="LTE" ;; esac
	_pct=$(sig_percent "$_mode" "$_rsrp" "$_rsrq" "$_sinr" "" "" "$_rssi")
	_reg=0
	case "$_state" in
		Connected|"Подключено"*) _reg=1 ;;
		Disconnected*|"Отключено"*|"") ;;
		*) [ -n "$_rsrp" ] && _reg=1 ;;
	esac
	[ "$_reg" = 1 ] && [ "$_roam" = "1" ] && _reg=5
	_csq=""
	case "$_rssi" in
		-[0-9]*)
			_ri=${_rssi%%.*}
			_csq=$(( ( _ri + 113 ) / 2 ))
			[ "$_csq" -lt 0 ] && _csq=0
			[ "$_csq" -gt 31 ] && _csq=31
			;;
	esac
	case "$_model" in *[Yy][Oo][Tt][Aa]*|"") ;; *) _model="Yota $_model" ;; esac
	[ -n "$_model" ] || _model="Yota"
	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s",' "$_a"
	printf '"protocol":"HiLink (web API)","vidpid":"%s",' "$(_vidpid_for "$_HLP")"
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s","imsi":"%s","iccid":"",' "$_imei" "$_imsi"
	printf '"firmware":"%s","phone":"%s",' "$(jsafe "$_fw")" "$(jsafe "$_phone")"
	printf '"operator_name":"%s",' "$(jsafe "$_op")"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	printf '"mode":"%s",' "$_mode"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"cid_dec":"%s","cid_hex":"%s","lac_hex":"%s",' "$_cid" "$_cid_hex" "$_lac"
	printf '"enbid":"%s",' "$_enb"
	printf '"csq":"%s",' "$_csq"
	printf '"conn_status":"%s"' "$(jsafe "$_state")"
	printf '}\n'
}

_ng_at() {
	command -v nc >/dev/null 2>&1 || return 1
	{ printf 'ATE0\r\n%s\r\n' "$2"; sleep 2; } | timeout 6 nc "$1" 5510 2>/dev/null | tr -d '\r'
}

netgear_metrics_json() {
	_HLP=$(_hl_path "$1")
	_a=$(_addr_for "$_HLP") || return 1
	_ng_g=$(_ng_at "$_a" 'AT!GSTATUS?')
	case "$_ng_g" in *GSTATUS*) ;; *) return 1 ;; esac
	_ng_i=$(_ng_at "$_a" 'ATI')
	_ng_kv=$(printf '%s\n' "$_ng_g" | awk '
		function val(lbl,   p, s) {
			p = index($0, lbl); if (p == 0) return ""
			s = substr($0, p + length(lbl))
			sub(/^[ \t]*:[ \t]*/, "", s); sub(/[ \t]+[A-Z][A-Za-z ]*:.*$/, "", s); sub(/[ \t]+$/, "", s)
			return (s == "---" || s == "--") ? "" : s
		}
		/^PCC:/      { sec = "P"; next }
		/^SCC[0-9]:/ { sec = "S" substr($0, 4, 1); next }
		/^System mode:/ { print "SYSMODE=" val("System mode") }
		/^Mode:|[ \t]Mode:/ { print "STATE=" val("Mode") }
		sec != "" && /^LTE band:/         { print sec "BAND=" val("LTE band") }
		sec != "" && /^LTE bw:/           { v = val("LTE bw"); sub(/[ \t]*MHz.*/, "", v); print sec "BW=" v }
		sec != "" && /^LTE Rx chan:/      { print sec "EARFCN=" val("LTE Rx chan") }
		sec != "" && /^RSSI \(dBm\):/     { print sec "RSSI=" val("RSSI (dBm)") }
		sec != "" && /^RSRP \(dBm\):/     { print sec "RSRP=" val("RSRP (dBm)") }
		sec != "" && /^RSRQ \(dB\):/      { print sec "RSRQ=" val("RSRQ (dB)") }
		sec != "" && /^RSSNR \(dB\):/     { print sec "SINR=" val("RSSNR (dB)") }
		sec != "" && /^Tx Power \(dBm\):/ { print sec "TXPWR=" val("Tx Power (dBm)") }
		sec != "" && /^LTE Cell ID:/      { print sec "CID=" val("LTE Cell ID") }
		sec != "" && /^Physical Cell ID:/ { print sec "PCI=" val("Physical Cell ID") }
		sec != "" && /^TAC:/              { print sec "TAC=" val("TAC") }
	')
	_ngv() { printf '%s\n' "$_ng_kv" | sed -n "s|^$1=||p" | head -1; }
	_ngn() { printf '%s' "$1" | sed -n 's/^\(-\{0,1\}[0-9][0-9]*\(\.[0-9]*\)\{0,1\}\).*/\1/p'; }
	_ngb() { _b=$(printf '%s' "$1" | tr -cd '0-9'); [ -n "$_b" ] || return 0; [ -n "$2" ] && echo "B$_b @$2 MHz" || echo "B$_b"; }
	_rsrp=$(_ngn "$(_ngv PRSRP)"); _rsrq=$(_ngn "$(_ngv PRSRQ)")
	_sinr=$(_ngn "$(_ngv PSINR)"); _rssi=$(_ngn "$(_ngv PRSSI)")
	_pbw=$(_ngn "$(_ngv PBW)")
	_pband=$(_ngb "$(_ngv PBAND)" "$_pbw")
	_earfcn=$(_ngn "$(_ngv PEARFCN)"); _pci=$(_ngn "$(_ngv PPCI)")
	_cid=$(_ngn "$(_ngv PCID)"); _cid_hex=""; _enb=""
	[ -n "$_cid" ] && { _cid_hex=$(printf '%X' "$_cid" 2>/dev/null); _enb=$(( _cid >> 8 )); }
	_tac=$(_ngn "$(_ngv PTAC)"); _tac_hex=""
	[ -n "$_tac" ] && _tac_hex=$(printf '%X' "$_tac" 2>/dev/null)
	_tx=$(_ngn "$(_ngv PTXPWR)")
	_mode=""; [ "$(_ngv SYSMODE)" = "LTE" ] && _mode="LTE"
	_sc=""
	for _n in 1 2 3 4; do
		_sb=$(_ngb "$(_ngv S${_n}BAND)" "$(_ngn "$(_ngv S${_n}BW)")")
		[ -n "$_sb" ] || continue
		_mode="LTE-A"
		_sc="$_sc\"s${_n}band\":\"$_sb\",\"s${_n}earfcn\":\"$(_ngn "$(_ngv S${_n}EARFCN)")\",\"s${_n}pci\":\"$(_ngn "$(_ngv S${_n}PCI)")\",\"s${_n}rsrp\":\"$(_ngn "$(_ngv S${_n}RSRP)")\",\"s${_n}rsrq\":\"$(_ngn "$(_ngv S${_n}RSRQ)")\",\"s${_n}rssi\":\"$(_ngn "$(_ngv S${_n}RSSI)")\","
	done
	_model=$(printf '%s\n' "$_ng_i" | sed -n 's/^Model:[[:space:]]*//p' | head -1)
	_fw=$(printf '%s\n' "$_ng_i" | sed -n 's/^Revision:[[:space:]]*//p' | head -1)
	_imei=$(printf '%s\n' "$_ng_i" | sed -n 's/^IMEI:[[:space:]]*//p' | head -1 | tr -cd '0-9')
	case "$_model" in [Nn][Ee][Tt][Gg][Ee][Aa][Rr]*|"") ;; *) _model="Netgear $_model" ;; esac
	[ -n "$_model" ] || _model="Netgear"
	_pct=$(sig_percent "LTE" "$_rsrp" "$_rsrq" "$_sinr" "" "" "$_rssi")
	_reg=0; [ "$(_ngv STATE)" = "ONLINE" ] && [ -n "$_mode" ] && _reg=1
	_csq=""
	case "$_rssi" in
		-[0-9]*) _ri=${_rssi%%.*}; _csq=$(( ( _ri + 113 ) / 2 ))
		         [ "$_csq" -lt 0 ] && _csq=0; [ "$_csq" -gt 31 ] && _csq=31 ;;
	esac
	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s:5510",' "$_a"
	printf '"protocol":"AT over TCP (Netgear)",'
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s","imsi":"","iccid":"",' "$_imei"
	printf '"firmware":"%s","phone":"",' "$(jsafe "$_fw")"
	printf '"registration":"%s",' "$_reg"
	printf '"mode":"%s",' "$_mode"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' "$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"pci":"%s","pband":"%s","earfcn":"%s",' "$_pci" "$_pband" "$_earfcn"
	printf '"bandwidth":"%s",' "${_pbw:+$_pbw MHz}"
	printf '"cid_dec":"%s","cid_hex":"%s","enbid":"%s",' "$_cid" "$_cid_hex" "$_enb"
	printf '"tac_dec":"%s","tac_hex":"%s",' "$_tac" "$_tac_hex"
	printf '"txpower":"%s",' "${_tx:+$_tx dBm}"
	printf '%s' "$_sc"
	printf '"csq":"%s",' "$_csq"
	printf '"conn_status":"%s"' "$(jsafe "$(_ngv STATE)")"
	printf '}\n'
}

metrics_json() {
	_HLP=$(_hl_path "$1")
	case "$(_api_vid "$_HLP")" in
		19d2:0565) yota_metrics_json "$_HLP" || zte_metrics_json "$_HLP"; return $? ;;
		19d2:*)
			tenda_metrics_json "$_HLP"
			case $? in 0) return 0 ;; 2) return 1 ;; esac
			zte_metrics_json "$_HLP"; return $? ;;
		15a9:*|1076:8002) yota_metrics_json "$_HLP"; return $? ;;
		0846:68e1) netgear_metrics_json "$_HLP"; return $? ;;
	esac
	_inf=$(api_get /api/device/information "$_HLP")
	[ -n "$_inf" ] || return 1
	_st=$(api_get /api/monitoring/status "$_HLP")
	_sig=$(api_get /api/device/signal "$_HLP")
	_tr=$(api_get /api/monitoring/traffic-statistics "$_HLP")
	_plmn=$(api_get /api/net/current-plmn "$_HLP")

	_model=$(printf '%s' "$_inf" | xval DeviceName)
	_vid=$(uci -q get "$CFG.m_$(echo "${_HLP:-$(uci -q get "$CFG.@5gmodem[0].active_modem")}" \
		| sed 's/[^A-Za-z0-9]/_/g').vidpid" | cut -d: -f1)
	case "$_vid" in
		12d1) _vend="Huawei" ;;
		19d2) _vend="ZTE" ;;
		1bbb) _vend="Alcatel" ;;
		2001) _vend="D-Link" ;;
		*)    _vend="" ;;
	esac
	case "$_model" in
		"$_vend"*|"") ;;
		*) [ -n "$_vend" ] && _model="$_vend $_model" ;;
	esac
	_imei=$(printf '%s' "$_inf" | xval Imei)
	_imsi=$(printf '%s' "$_inf" | xval Imsi)
	_iccid=$(printf '%s' "$_inf" | xval Iccid)
	_fw=$(printf '%s' "$_inf" | xval SoftwareVersion)
	_phone=$(printf '%s' "$_inf" | xval Msisdn)

	_cs=$(printf '%s' "$_st" | xval ConnectionStatus)
	_sigbars=$(printf '%s' "$_st" | xval SignalStrength)
	[ -n "$_sigbars" ] || _sigbars=$(printf '%s' "$_st" | xval SignalIcon)
	_maxbars=$(printf '%s' "$_st" | xval maxsignal)
	_ntype=$(printf '%s' "$_st" | xval CurrentNetworkType)
	_wanip=$(printf '%s' "$_st" | xval WanIPAddress)
	_sim=$(printf '%s' "$_st" | xval SimStatus)
	_roam=$(printf '%s' "$_st" | xval cellroam)
	_roamset=$(printf '%s' "$_st" | xval RoamingStatus)

	_rsrp=$(printf '%s' "$_sig" | xval rsrp | tr -cd '0-9-')
	_rsrq=$(printf '%s' "$_sig" | xval rsrq | tr -cd '0-9.-')
	_sinr=$(printf '%s' "$_sig" | xval sinr | tr -cd '0-9.-')
	_rssi=$(printf '%s' "$_sig" | xval rssi | tr -cd '0-9-')
	_pci=$(printf '%s' "$_sig" | xval pci)
	_cid=$(printf '%s' "$_sig" | xval cell_id | tr -cd '0-9')
	_cid_hex=""; _enb=""; _sect=""
	if [ -n "$_cid" ]; then
		_cid_hex=$(printf '%X' "$_cid" 2>/dev/null)
		_enb=$(( _cid >> 8 ))
		_sect=$(( _cid & 255 ))
	fi

	_lband=$(printf '%s' "$_sig" | xval band | tr -cd '0-9')
	_learfcn=$(printf '%s' "$_sig" | xval earfcn | sed -n 's/^[^0-9]*\([0-9][0-9]*\).*/\1/p')
	_ldlbw=$(printf '%s' "$_sig" | xval dlbandwidth | tr -cd '0-9.')
	_lpband=""; _lbw=""
	if [ -n "$_lband" ]; then
		_lpband="B$_lband"
		if [ -n "$_ldlbw" ]; then
			_lbw="$_ldlbw MHz"
			_lpband="$_lpband @$_lbw"
		fi
	fi

	_up=$(printf '%s' "$_tr" | xval CurrentUpload)
	_down=$(printf '%s' "$_tr" | xval CurrentDownload)
	_ctime=$(printf '%s' "$_tr" | xval CurrentConnectTime)

	_op=$(printf '%s' "$_plmn" | xval FullName)
	[ -n "$_op" ] || _op=$(printf '%s' "$_plmn" | xval ShortName)
	_mcc=""; _mnc=""
	_num=$(printf '%s' "$_plmn" | xval Numeric | tr -cd '0-9')
	if [ ${#_num} -ge 5 ]; then _mcc=${_num%${_num#???}}; _mnc=${_num#???}; fi
	if [ -n "$_num" ]; then
		_dbop=$(awk -F';' -v k="$_num" '$1 == k { print $3 }' "$RES/mccmnc.dat" 2>/dev/null \
			| head -1 | tr -d '\r' | sed 's/[[:space:]]*$//')
		[ -n "$_dbop" ] && _op="$_dbop"
	fi
	_obr=$(opname_brand "$_imsi") && _op="$_obr"

	_pct=$(sig_percent "$(nettype_name "$_ntype")" "$_rsrp" "$_rsrq" "$_sinr" "" "" "$_rssi")
	if [ -z "$_pct" ] && [ -n "$_rssi" ]; then
		_pct=$(( ( _rssi + 113 ) * 100 / 62 ))
		[ "$_pct" -gt 100 ] && _pct=100
		[ "$_pct" -lt 0 ] && _pct=0
	fi
	if [ -z "$_pct" ] && [ -n "$_sigbars" ] && [ -n "$_maxbars" ] && [ "$_maxbars" -gt 0 ] 2>/dev/null; then
		_pct=$(( _sigbars * 100 / _maxbars ))
	fi

	if [ -n "$_imei" ] || [ -n "$_model" ]; then
		_hsec="m_$(echo "$_HLP" | sed 's/[^A-Za-z0-9]/_/g')"
		_ch=0
		_hlwr=1
		[ "$(uci -q get "$CFG.$_hsec.kind")" = "hilink" ] || {
			logger -t 5gmodem "hilink: $_hsec is not a HiLink modem - not writing model/IMEI from the web API"
			_hlwr=0
		}
		[ "$_hlwr" = 1 ] && [ -n "$_model" ] && [ "$(uci -q get "$CFG.$_hsec.model")" != "$_model" ] && {
			uci -q set "$CFG.$_hsec.model=$_model"
			uci -q set "$CFG.$_hsec.model_vp=$(uci -q get "$CFG.$_hsec.vidpid")"; _ch=1; }
		[ "$_hlwr" = 1 ] && [ -n "$_imei" ] && [ "$(uci -q get "$CFG.$_hsec.imei")" != "$_imei" ] && {
			uci -q set "$CFG.$_hsec.imei=$_imei"; _ch=1; }
		[ "$_ch" = "1" ] && uci -q commit "$CFG"
	fi

	_reg=0
	if conn_up "$_cs"; then
		[ "$_roam" = "1" ] && _reg=5 || _reg=1
	fi

	printf '{'
	printf '"backend":"hilink",'
	printf '"cport":"%s",' "$(_addr_for "$_HLP" 2>/dev/null)"
	printf '"protocol":"HiLink (web API)","vidpid":"%s",' "$(_vidpid_for "$_HLP")"
	printf '"modem":"%s",' "$(jsafe "$_model")"
	printf '"imei":"%s",' "$_imei"
	printf '"imsi":"%s",' "$_imsi"
	printf '"iccid":"%s",' "$_iccid"
	printf '"firmware":"%s",' "$(jsafe "$_fw")"
	printf '"phone":"%s",' "$(jsafe "$_phone")"
	printf '"operator_name":"%s",' "$(jsafe "$_op")"
	printf '"operator_mcc":"%s","operator_mnc":"%s",' "$_mcc" "$_mnc"
	printf '"registration":"%s",' "$_reg"
	printf '"allow_roaming":"%s",' "$([ "$_roamset" = "1" ] && echo 1 || echo 0)"
	printf '"mode":"%s",' "$(nettype_name "$_ntype")"
	printf '"signal":"%s",' "$_pct"
	printf '"rsrp":"%s","rsrq":"%s","sinr":"%s","rssi":"%s",' \
		"$_rsrp" "$_rsrq" "$_sinr" "$_rssi"
	printf '"pci":"%s",' "$_pci"
	printf '"pband":"%s","earfcn":"%s","bandwidth":"%s",' "$_lpband" "$_learfcn" "$_lbw"
	printf '"cid_dec":"%s","cid_hex":"%s",' "$_cid" "$_cid_hex"
	printf '"enbid":"%s","sector":"%s",' "$_enb" "$_sect"
	printf '"ipaddr":"%s",' "$_wanip"
	_ct_str="-"
	if [ -n "$_ctime" ] && [ "$_ctime" -ge 0 ] 2>/dev/null; then
		_ct_str=$(printf "%dd, %02d:%02d:%02d" \
			$(( _ctime / 86400 )) $(( _ctime / 3600 % 24 )) \
			$(( _ctime / 60 % 60 )) $(( _ctime % 60 )))
	fi
	printf '"conn_time":"%s","conn_time_sec":"%s",' "$_ct_str" "${_ctime:-0}"
	printf '"rx":"%s","tx":"%s",' "$(_human "$_down")" "$(_human "$_up")"
	_csq=""
	if [ -n "$_rssi" ]; then
		_csq=$(( ( _rssi + 113 ) / 2 ))
		[ "$_csq" -lt 0 ] && _csq=0
		[ "$_csq" -gt 31 ] && _csq=31
	fi
	printf '"csq":"%s",' "$_csq"
	printf '"sim_status":"%s","conn_status":"%s"' "$_sim" "$_cs"
	printf '}\n'
}

sms_list() {
	case "$1" in out) _box=2 ;; *) _box=1 ;; esac
	_r=$(api_post /api/sms/sms-list \
		"<PageIndex>1</PageIndex><ReadCount>50</ReadCount><BoxType>$_box</BoxType>\
<SortType>0</SortType><Ascending>0</Ascending><UnreadPreferred>0</UnreadPreferred>" "$2")
	printf '%s' "$_r" | tr -d '\r' | awk '
		BEGIN { printf "{\"msg\":["; first = 1; inc = 0 }
		function esc(v,   o, i, c) {
			o = ""
			for (i = 1; i <= length(v); i++) {
				c = substr(v, i, 1)
				if (c == "\\") o = o "\\\\"
				else if (c == "\"") o = o "\\\""
				else o = o c
			}
			v = o
			gsub(/\t/, " ", v); gsub(/\n/, " ", v)
			return v
		}
		function xdec(v) {
			gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v)
			gsub(/&quot;/, "\"", v); gsub(/&apos;|&#39;/, "\047", v)
			gsub(/&amp;/, "\\&", v)
			return v
		}
		/<Message>/  { idx=""; ph=""; txt=""; dt=""; inc=0 }
		/<Index>/    { v=$0; sub(/.*<Index>/, "", v); sub(/<\/Index>.*/, "", v); idx=v }
		/<Phone>/    { v=$0; sub(/.*<Phone>/, "", v); sub(/<\/Phone>.*/, "", v); ph=v }
		/<Date>/     { v=$0; sub(/.*<Date>/, "", v); sub(/<\/Date>.*/, "", v); dt=v }
		/<Content>/  {
			v=$0; sub(/.*<Content>/, "", v)
			if (v ~ /<\/Content>/) { sub(/<\/Content>.*/, "", v); txt=v }
			else { txt=v; inc=1 }
			next
		}
		inc == 1 {
			if ($0 ~ /<\/Content>/) { v=$0; sub(/<\/Content>.*/, "", v); txt=txt " " v; inc=0 }
			else { txt=txt " " $0 }
			next
		}
		/<\/Message>/ {
			if (idx == "" || idx ~ /[^0-9]/) next
			if (!first) printf ",\n"; first = 0
			printf "{\"index\":%s,\"sender\":\"%s\",\"timestamp\":\"%s\",\"reference\":0,\"part\":1,\"total\":1,\"content\":\"%s\"}", idx, esc(xdec(ph)), esc(dt), esc(xdec(txt))
		}
		END { print "]}" }'
}

sms_send() {
	_n="$1"; _t="$2"
	[ -n "$_n" ] && [ -n "$_t" ] || { echo '{"error":"no number or text"}'; return 1; }
	_d=$(date '+%Y-%m-%d %H:%M:%S')
	_r=$(api_post /api/sms/send-sms \
		"<Index>-1</Index><Phones><Phone>$(_xesc "$_n")</Phone></Phones><Sca></Sca>\
<Content>$(_xesc "$_t")</Content><Length>${#_t}</Length><Reserved>1</Reserved><Date>$_d</Date>" "$3")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

sms_delete() {
	_r=$(api_post /api/sms/delete-sms "<Index>$1</Index>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

_zte_sms_fetch() {
	_zte_get "$1" "sms_data_total&page=0&data_per_page=100&mem_store=$2&tags=10&order_by=order%20by%20id%20desc"
}

_zte_sms_parse() {
	awk -v box="$1" '
		BEGIN { printf "{\"msg\":["; first = 1 }
		function hv(s,   i, d, v) {
			v = 0
			for (i = 1; i <= length(s); i++) {
				d = index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
				if (d < 0) return -1
				v = v * 16 + d
			}
			return v
		}
		function jesc(v,   o, i, c) {
			o = ""
			for (i = 1; i <= length(v); i++) {
				c = substr(v, i, 1)
				if (c == "\\") o = o "\\\\"
				else if (c == "\"") o = o "\\\""
				else o = o c
			}
			v = o
			gsub(/\t/, " ", v); gsub(/\n/, " ", v); gsub(/\r/, "", v)
			return v
		}
		function ucs2(h,   i, u, out) {
			if (h == "" || length(h) % 4 != 0 || h ~ /[^0-9A-Fa-f]/) return jesc(h)
			out = ""
			for (i = 1; i <= length(h); i += 4) {
				u = hv(substr(h, i, 4))
				if (u < 0) return jesc(h)
				if (u == 0) continue
				if (u == 34) out = out "\\\""
				else if (u == 92) out = out "\\\\"
				else if (u >= 32 && u < 127) out = out sprintf("%c", u)
				else out = out sprintf("\\u%04x", u)
			}
			return out
		}
		function ucs2num(h) {
			if (h ~ /^(00[0-9A-Fa-f][0-9A-Fa-f])+$/ && length(h) >= 8) return ucs2(h)
			return jesc(h)
		}
		function fld(r, k,   v) {
			if (!match(r, "\"" k "\":\"[^\"]*\"")) return ""
			v = substr(r, RSTART, RLENGTH)
			sub("^\"" k "\":\"", "", v); sub("\"$", "", v)
			return v
		}
		function zdate(d,   p, n) {
			n = split(d, p, ",")
			if (n < 6) return d
			return sprintf("20%02d-%02d-%02d %02d:%02d:%02d", p[1], p[2], p[3], p[4], p[5], p[6])
		}
		{
			p = index($0, "\"messages\":")
			if (p == 0) next
			s = substr($0, p)
			n = split(s, rec, /\},[ ]*\{/)
			for (k = 1; k <= n; k++) {
				id = fld(rec[k], "id")
				if (id == "" || id ~ /[^0-9]/) continue
				tag = fld(rec[k], "tag") + 0
				if (box == "out") { if (tag != 2 && tag != 3) continue }
				else              { if (tag != 0 && tag != 1) continue }
				if (!first) printf ",\n"; first = 0
				printf "{\"index\":%s,\"sender\":\"%s\",\"timestamp\":\"%s\",\"reference\":0,\"part\":1,\"total\":1,\"content\":\"%s\"}", \
					id, ucs2num(fld(rec[k], "number")), jesc(zdate(fld(rec[k], "date"))), \
					ucs2(fld(rec[k], "content"))
			}
		}
		END { print "]}" }'
}

zte_sms_list() {
	_zs_p=$(_hl_path "$2")
	_zs_a=$(_addr_for "$_zs_p") || { echo '{"msg":[]}'; return 1; }
	_zs_r=$(_zte_sms_fetch "$_zs_a" 1)
	case "$_zs_r" in
		*'"messages"'*) ;;
		*) _zte_login "$_zs_a" >/dev/null 2>&1 && _zs_r=$(_zte_sms_fetch "$_zs_a" 1) ;;
	esac
	case "$_zs_r" in
		*'"messages":[]'*|*'"messages": []'*|'') _zs_r=$(_zte_sms_fetch "$_zs_a" 0) ;;
	esac
	printf '%s' "$_zs_r" | tr -d '\r\n' | _zte_sms_parse "${1:-in}"
}

zte_sms_count() {
	_zc_a=$(_addr_for "$(_hl_path "$1")") || return 1
	_zc_r=$(_zte_get "$_zc_a" "sms_capacity_info")
	_zc_u=$(_zj "$_zc_r" sms_nv_rev_total)
	_zc_m=$(_zj "$_zc_r" sms_nv_total)
	printf '<LocalInbox>%s</LocalInbox><LocalMaxInbox>%s</LocalMaxInbox>\n' \
		"${_zc_u:-0}" "${_zc_m:-100}"
}

_zte_ucs2hex() {
	printf '%s' "$1" | LC_ALL=C awk '
		BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i; body = ""; nl = 0 }
		{ body = (nl++ ? body "\n" $0 : $0) }
		END {
			n = length(body); i = 1; out = ""
			while (i <= n) {
				c = ord[substr(body, i, 1)]
				if (c < 0x80) { cp = c; i += 1 }
				else if (c >= 0xC0 && c < 0xE0) {
					cp = (c - 0xC0) * 64 + (ord[substr(body, i + 1, 1)] - 0x80); i += 2
				}
				else if (c >= 0xE0 && c < 0xF0) {
					cp = (c - 0xE0) * 4096 + (ord[substr(body, i + 1, 1)] - 0x80) * 64 \
					     + (ord[substr(body, i + 2, 1)] - 0x80); i += 3
				}
				else if (c >= 0xF0) {
					cp = (c - 0xF0) * 262144 + (ord[substr(body, i + 1, 1)] - 0x80) * 4096 \
					     + (ord[substr(body, i + 2, 1)] - 0x80) * 64 \
					     + (ord[substr(body, i + 3, 1)] - 0x80); i += 4
				}
				else { i += 1; continue }
				if (cp > 0xFFFF) {
					cp -= 0x10000
					out = out sprintf("%04X%04X", 0xD800 + int(cp / 1024), 0xDC00 + (cp % 1024))
				} else out = out sprintf("%04X", cp)
			}
			print out
		}'
}

_zte_smstime() {
	_zt_z=$(date +%z 2>/dev/null)
	_zt_s="+"; _zt_q=0
	case "$_zt_z" in
		[+-][0-9][0-9][0-9][0-9])
			_zt_s=$(printf '%s' "$_zt_z" | cut -c1)
			_zt_h=$(printf '%s' "$_zt_z" | cut -c2-3 | sed 's/^0*//')
			_zt_m=$(printf '%s' "$_zt_z" | cut -c4-5 | sed 's/^0*//')
			_zt_q=$(( ${_zt_h:-0} * 4 + ${_zt_m:-0} / 15 ))
			;;
	esac
	printf '%s;%s%s' "$(date '+%y;%m;%d;%H;%M;%S')" "$_zt_s" "$_zt_q"
}

zte_sms_send() {
	[ -n "$1" ] && [ -n "$2" ] || { echo '{"error":"no number or text"}'; return 1; }
	_zd_a=$(_addr_for "$(_hl_path "$3")") || { echo '{"success":false}'; return 1; }
	_zte_login "$_zd_a" >/dev/null 2>&1
	_zd_n=$(printf '%s' "$1" | sed 's/+/%2B/g')
	_zd_b=$(_zte_ucs2hex "$2")
	_zd_r=$(_zte_set "$_zd_a" \
		"goformId=SEND_SMS&notCallback=true&Number=$_zd_n&sms_time=$(_zte_smstime)&MessageBody=$_zd_b&ID=-1&encode_type=UNICODE")
	case "$_zd_r" in
		*success*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(_zj "$_zd_r" result)" ;;
	esac
}

zte_sms_delete() {
	_zx_a=$(_addr_for "$(_hl_path "$2")") || { echo '{"success":false}'; return 1; }
	_zte_login "$_zx_a" >/dev/null 2>&1
	_zx_r=$(_zte_set "$_zx_a" "goformId=DELETE_SMS&msg_id=$1;&notCallback=true")
	case "$_zx_r" in
		*success*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(_zj "$_zx_r" result)" ;;
	esac
}
_tenda_sms_conv() {
	awk '
		function fld(r, k,   v) {
			if (match(r, "\"" k "\":\"[^\"]*\"")) {
				v = substr(r, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v
			}
			if (match(r, "\"" k "\":[a-z0-9]+")) {
				v = substr(r, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v
			}
			return ""
		}
		{
			n = split($0, rec, "{")
			printf "{\"messages\":["
			first = 1; ph = ""
			for (k = 1; k <= n; k++) {
				if (rec[k] ~ /"list":/) { ph = fld(rec[k], "phone"); continue }
				id = fld(rec[k], "id")
				if (id == "" || id ~ /[^0-9]/) continue
				if (fld(rec[k], "isSend") == "true") tag = (fld(rec[k], "status") == "false") ? 3 : 2
				else tag = (fld(rec[k], "isRead") == "true") ? 1 : 0
				t = fld(rec[k], "time") + 0
				if (!first) printf ","; first = 0
				printf "{\"id\":\"%s\",\"number\":\"%s\",\"tag\":\"%d\",\"date\":\"%s\",\"content\":\"%s\"}", \
					id, ph, tag, strftime("%y,%m,%d,%H,%M,%S", t), fld(rec[k], "content")
			}
			print "]}"
		}'
}

tenda_sms_list() {
	_ts_p=$(_hl_path "$2")
	_ts_a=$(_addr_for "$_ts_p") || { echo '{"msg":[]}'; return 1; }
	_ts_r=$(_tenda_get "$_ts_a" smsList "$_ts_p")
	case "$_ts_r" in
		*'"smsList"'*) ;;
		*) echo '{"msg":[]}'; return 1 ;;
	esac
	printf '%s' "$_ts_r" | tr -d '\r\n' | _tenda_sms_conv | _zte_sms_parse "${1:-in}"
}

tenda_sms_count() {
	_tc_n=$(tenda_sms_list in "$1" | jsonfilter -e '@.msg[*].index' 2>/dev/null | wc -l)
	printf '<LocalInbox>%s</LocalInbox><LocalMaxInbox>100</LocalMaxInbox>\n' "${_tc_n:-0}"
}

tenda_sms_send() {
	[ -n "$1" ] && [ -n "$2" ] || { echo '{"error":"no number or text"}'; return 1; }
	_td_p=$(_hl_path "$3")
	_td_a=$(_addr_for "$_td_p") || { echo '{"success":false}'; return 1; }
	_td_n=$(printf '%s' "$1" | tr -cd '0-9+')
	_td_e=UNICODE
	printf '%s' "$2" | grep -q '[^ -~]' || _td_e=GSM7_default
	_td_r=$(_tenda_set "$_td_a" sendSms \
		"{\"sendSms\":{\"phone\":\"$_td_n\",\"content\":\"$(_zte_ucs2hex "$2")\",\"encode_type\":\"$_td_e\",\"id\":\"-1\",\"time\":\"$(date +%s)\"}}" "$_td_p")
	if _tenda_ok "$_td_r"; then echo '{"success":true}'; else
		printf '{"success":false,"code":"%s"}\n' "$(_zj "$_td_r" errCode)"; fi
}

tenda_sms_markread() {
	_tr_p=$(_hl_path "$2")
	_tr_a=$(_addr_for "$_tr_p") || { echo '{"success":false}'; return 1; }
	_tr_ids=$(printf '%s' "$1" | tr -c '0-9' ' ' | awk '{ for (i = 1; i <= NF; i++) printf "%s\"%s\"", (i > 1 ? "," : ""), $i }')
	[ -n "$_tr_ids" ] || { echo '{"success":true}'; return 0; }
	_tr_r=$(_tenda_set "$_tr_a" viewSms "{\"viewSms\":{\"id\":[$_tr_ids]}}" "$_tr_p")
	if _tenda_ok "$_tr_r"; then echo '{"success":true}'; else
		printf '{"success":false,"code":"%s"}\n' "$(_zj "$_tr_r" errCode)"; fi
}

tenda_sms_delete() {
	_tx_p=$(_hl_path "$2")
	_tx_a=$(_addr_for "$_tx_p") || { echo '{"success":false}'; return 1; }
	_tx_r=$(_tenda_set "$_tx_a" delSmsList "{\"delSmsList\":{\"idList\":[\"$(printf '%s' "$1" | tr -cd '0-9')\"]}}" "$_tx_p")
	if _tenda_ok "$_tx_r"; then echo '{"success":true}'; else
		printf '{"success":false,"code":"%s"}\n' "$(_zj "$_tx_r" errCode)"; fi
}

hl_ussd() {
	_code="$1"
	[ -n "$_code" ] || { echo '{"error":"no code"}'; return 1; }

	api_post /api/ussd/release "" "$2" >/dev/null 2>&1

	_r=$(api_post /api/ussd/send \
		"<content>$(_xesc "$_code")</content><codeType>CodeType</codeType><timeout></timeout>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)"; return 1 ;;
	esac

	_n=0
	while [ "$_n" -lt 30 ]; do
		sleep 1
		_g=$(api_get /api/ussd/get "$2")
		_c=$(printf '%s' "$_g" | xval content)
		if [ -n "$_c" ]; then
			api_post /api/ussd/release "" "$2" >/dev/null 2>&1
			_c=$(printf '%s' "$_c" | tr -d '\r' | tr '\n' ' ' \
				| sed 's/\\/\\\\/g; s/"/\\"/g')
			printf '{"success":true,"content":"%s"}\n' "$_c"
			return 0
		fi
		_n=$(( _n + 1 ))
	done
	api_post /api/ussd/release "" "$2" >/dev/null 2>&1
	echo '{"success":false,"error":"timeout"}'
	return 1
}

_hl_hexsplit() {
	_hx=$(printf '%s' "$1" | tr -d '\r\n')
	case "$_hx" in 0[xX]*) _hx=${_hx#??} ;; esac
	case "$_hx" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
	while [ "${#_hx}" -gt 1 ]; do
		case "$_hx" in 0*) _hx=${_hx#0} ;; *) break ;; esac
	done
	[ "${#_hx}" -le 16 ] || return 1
	if [ "${#_hx}" -gt 8 ]; then
		_hx_hi=${_hx%????????}; _hx_lo=${_hx#"$_hx_hi"}
	else
		_hx_hi=0; _hx_lo=$_hx
	fi
	_hx_hi=$(( 0x$_hx_hi )); _hx_lo=$(( 0x$_hx_lo ))
}

_hl_lte_all() {
	_la=$(printf '%s' "$1" | tr -d '\r\n')
	case "$_la" in 0[xX]*) _la=${_la#??} ;; esac
	case "$_la" in ''|*[!0-9A-Fa-f]*) return 1 ;; esac
	while [ "${#_la}" -gt 1 ]; do
		case "$_la" in 0*) _la=${_la#0} ;; *) break ;; esac
	done
	[ "${#_la}" -ge 8 ] || return 1
	case "${_la#?}" in *[!Ff]*) return 1 ;; esac
	return 0
}

_mask_to_bands() {
	_hl_hexsplit "$1" || return 1
	_i=0; _out=""
	while [ "$_i" -lt 32 ]; do
		if [ $(( (_hx_lo >> _i) & 1 )) -eq 1 ]; then _out="$_out $(( _i + 1 ))"; fi
		_i=$(( _i + 1 ))
	done
	_i=0
	while [ "$_i" -lt 32 ]; do
		if [ $(( (_hx_hi >> _i) & 1 )) -eq 1 ]; then _out="$_out $(( _i + 33 ))"; fi
		_i=$(( _i + 1 ))
	done
	echo "$_out" | xargs
}

_bands_to_mask() {
	_mlo=0; _mhi=0
	for _b in $1; do
		case "$_b" in ''|*[!0-9]*) continue ;; esac
		while [ "${#_b}" -gt 1 ]; do
			case "$_b" in 0*) _b=${_b#0} ;; *) break ;; esac
		done
		[ "${#_b}" -le 2 ] && [ "$_b" -ge 1 ] && [ "$_b" -le 64 ] || return 1
		if [ "$_b" -le 32 ]; then
			_mlo=$(( _mlo | (1 << (_b - 1)) ))
		else
			_mhi=$(( _mhi | (1 << (_b - 33)) ))
		fi
	done
	if [ "$_mhi" -gt 0 ]; then
		printf '%X%08X\n' "$_mhi" "$_mlo"
	else
		printf '%X\n' "$_mlo"
	fi
}

_hl_lte_fallback="1 2 3 4 5 7 8 20 28 32 38 40 41"

_hl_ltelist() {
	api_get /api/net/net-mode-list "$1" 2>/dev/null | tr -d '\r\n' \
		| sed -n 's/.*<LTEBandList>\(.*\)<\/LTEBandList>.*/\1/p'
}

hl_supbands() {
	_sl=$(_hl_ltelist "$1")
	[ -n "$_sl" ] || return 1
	{
		printf '%s' "$_sl" | grep -oE 'LTE BC[0-9]+' | sed 's/LTE BC//'
		for _sv in $(printf '%s' "$_sl" | grep -oE '<Value>[0-9A-Fa-f]+</Value>' | sed 's/<[^>]*>//g'); do
			_hl_lte_all "$_sv" && continue
			_mask_to_bands "$_sv" | tr ' ' '\n'
		done
	} | grep -E '^[0-9]+$' | sort -nu | xargs
}

_hl_lte_allval() {
	for _sv in $(_hl_ltelist "$1" | grep -oE '<Value>[0-9A-Fa-f]+</Value>' | sed 's/<[^>]*>//g'); do
		_hl_lte_all "$_sv" && { echo "$_sv"; return 0; }
	done
	echo "7FFFFFFFFFFFFFFF"
}

hl_getbands() {
	_r=$(api_get /api/net/net-mode "$1")
	_lte=$(printf '%s' "$_r" | xval LTEBand)
	[ -n "$_lte" ] || return 1
	if _hl_lte_all "$_lte"; then
		_gb=$(hl_supbands "$1")
		[ -n "$_gb" ] || _gb=$(uci -q get "$CFG.m_$(echo "$(_hl_path "$1")" | sed 's/[^A-Za-z0-9]/_/g').band_full" \
			| tr -c '0-9\n' ' ' | xargs)
		[ -n "$_gb" ] || _gb="$_hl_lte_fallback"
		echo "$_gb"
		return 0
	fi
	_mask_to_bands "$_lte"
}

hl_setbands() {
	_cur=$(api_get /api/net/net-mode "$2")
	_nm=$(printf '%s' "$_cur" | xval NetworkMode)
	[ -n "$_nm" ] || _nm="03"
	if [ "$1" = "default" ] || [ -z "$1" ]; then
		_lte=$(_hl_lte_allval "$2"); _nb="3FFFFFFF"
	else
		_lte=$(_bands_to_mask "$1") || { echo '{"success":false,"error":"bad band"}'; return 1; }
		_nb="3FFFFFFF"
		[ "$_lte" = "0" ] && return 1
	fi
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_nb</NetworkBand><LTEBand>$_lte</LTEBand>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

_hl_nb_all() { [ $(( ($1 & 0x3FFFFFFF) == 0x3FFFFFFF )) -eq 1 ]; }

_umts_bit() {
	case "$1" in
		1) echo 400000 ;;
		2) echo 800000 ;;
		5) echo 4000000 ;;
		8) echo 2000000000000 ;;
		*) echo "" ;;
	esac
}
_gsm_bit() {
	case "$1" in
		900)  echo 300 ;;
		1800) echo 80 ;;
		850)  echo 80000 ;;
		1900) echo 200000 ;;
		*) echo "" ;;
	esac
}
_hl_bandbit() { [ "$1" = 3g ] && _umts_bit "$2" || _gsm_bit "$2"; }

_umts_roman() {
	case "$1" in
		I) echo 1 ;; II) echo 2 ;; IV) echo 4 ;; V) echo 5 ;;
		VI) echo 6 ;; VIII) echo 8 ;; *) echo "" ;;
	esac
}

hl_supbands3g() {
	api_get /api/net/net-mode-list "$1" 2>/dev/null | grep -oE 'WCDMA BC[IVX]+' | sed 's/WCDMA BC//' \
		| while read -r _rn; do _n=$(_umts_roman "$_rn"); [ -n "$_n" ] && echo "$_n"; done | sort -nu | xargs
}
hl_supbands2g() {
	api_get /api/net/net-mode-list "$1" 2>/dev/null | grep -oE 'GSM[0-9]+' | sed 's/GSM//' | sort -nu | xargs
}

hl_supmask3g() {
	_mm=0
	for _x in $(api_get /api/net/net-mode-list "$1" 2>/dev/null | sed 's/<LTEBandList>.*//' \
			| grep -oE '<Value>[0-9A-Fa-f]+</Value>' | sed 's/<[^>]*>//g'); do
		_mm=$(( _mm | $(printf '%d' "0x$_x") ))
	done
	echo "$_mm"
}

_hl_ratmask() {
	_rm=0; _rt="$1"; shift
	for _b in "$@"; do
		case "$_b" in ''|*[!0-9]*) continue ;; esac
		_bit=$(_hl_bandbit "$_rt" "$_b"); [ -n "$_bit" ] && _rm=$(( _rm | $(printf '%d' "0x$_bit") ))
	done
	echo "$_rm"
}

_hl_getbands() {
	_rt="$1"; _p="$2"
	_nb=$(api_get /api/net/net-mode "$_p" | xval NetworkBand)
	[ -n "$_nb" ] || return 1
	_m=$(printf '%d' "0x$_nb" 2>/dev/null) || return 1
	[ "$_rt" = 3g ] && _sup=$(hl_supbands3g "$_p") || _sup=$(hl_supbands2g "$_p")
	_hl_nb_all "$_m" && { echo $_sup | xargs; return; }
	for _b in $_sup; do
		_bit=$(_hl_bandbit "$_rt" "$_b"); [ -n "$_bit" ] || continue
		[ $(( (_m & $(printf '%d' "0x$_bit")) != 0 )) -eq 1 ] && printf '%s ' "$_b"
	done
	echo ""
}
hl_getbands3g() { _hl_getbands 3g "$1"; }
hl_getbands2g() { _hl_getbands 2g "$1"; }

_hl_setbands() {
	_rt="$1"; _selarg="$2"; _p="$3"
	_cur=$(api_get /api/net/net-mode "$_p")
	_nm=$(printf '%s' "$_cur" | xval NetworkMode); [ -n "$_nm" ] || _nm="00"
	_lte=$(printf '%s' "$_cur" | xval LTEBand);    [ -n "$_lte" ] || _lte="7FFFFFFFFFFFFFFF"
	_nb=$(printf '%s' "$_cur" | xval NetworkBand); [ -n "$_nb" ] || _nb="3FFFFFFF"
	_m=$(printf '%d' "0x$_nb")
	[ "$_rt" = 3g ] && _sup=$(hl_supbands3g "$_p") || _sup=$(hl_supbands2g "$_p")
	_allsup=$(hl_supmask3g "$_p")
	_thismask=$(_hl_ratmask "$_rt" $_sup)
	_othermask=$(( _allsup & ~_thismask ))
	if _hl_nb_all "$_m"; then _keep=$_othermask; else _keep=$(( _m & _othermask )); fi
	[ "$_selarg" = "default" ] || [ -z "$_selarg" ] && _sel="$_sup" || _sel="$_selarg"
	_new=$(( _keep | $(_hl_ratmask "$_rt" $_sel) ))
	_newnb=$(printf '%X' "$_new")
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_newnb</NetworkBand><LTEBand>$_lte</LTEBand>" "$_p")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}
hl_setbands3g() { _hl_setbands 3g "$1" "$2"; }
hl_setbands2g() { _hl_setbands 2g "$1" "$2"; }

_zte_login_jar() {
	_zlj_p=$(_zte_pass "$2")
	if [ "$3" = 1 ]; then
		_zlj_u=$(uci -q get "$CFG.m_$(echo "$2" | sed 's/[^A-Za-z0-9]/_/g').web_user")
		_zlj_p="${_zlj_u:-admin}
$_zlj_p"
	fi
	case "$(_zte_set "$1" "goformId=LOGIN&password=$(_zte_b64 "$_zlj_p" | sed 's/+/%2B/g; s/\//%2F/g; s/=/%3D/g')" \
		"$CACHE_DIR/ztejar_$(_tk "$1")")" in
		*'"result":"0"'*|*'"result":"4"'*) return 0 ;;
	esac
	return 1
}

_zte_post_auth() {
	_zpa_j="$CACHE_DIR/ztejar_$(_tk "$1")"
	_zpa_r=$(_zte_set "$1" "$2" "$_zpa_j")
	case "$_zpa_r" in *'"success"'*) printf '%s' "$_zpa_r"; return 0 ;; esac
	_zpa_jt=0; [ -z "$_zpa_r" ] && _zpa_jt=1
	_zte_login_jar "$1" "$3" "$_zpa_jt" || return 1
	_zpa_r=$(_zte_set "$1" "$2" "$_zpa_j")
	printf '%s' "$_zpa_r"
	case "$_zpa_r" in *'"success"'*) return 0 ;; esac
	return 1
}

_adb_to() {
	_at_t="$1"; shift
	_5GM_ADB=1 adb "$@" 2>/dev/null &
	_at_p=$!
	( sleep "$_at_t"; kill "$_at_p" 2>/dev/null ) </dev/null >/dev/null 2>&1 &
	_at_w=$!
	wait "$_at_p" 2>/dev/null
	kill "$_at_w" 2>/dev/null
}

_adb_foreign() {
	for _af_p in $(pgrep -x adb 2>/dev/null); do
		tr '\0' ' ' < "/proc/$_af_p/cmdline" 2>/dev/null | grep -q -- "$1" || continue
		tr '\0' '\n' < "/proc/$_af_p/environ" 2>/dev/null | grep -qx '_5GM_ADB=1' && continue
		return 0
	done
	return 1
}

_mtk_adb_on() {
	_ma_s="$1:5555"
	_adb_foreign "$_ma_s" && return 1
	case "$(_adb_to 4 devices)" in
		*"$_ma_s	device"*) return 0 ;;
		*"$_ma_s	"*) return 1 ;;
	esac
	_ma_r=$(_adb_to 6 connect "$_ma_s")
	case "$_ma_r" in
		*"connected to"*)
			sleep 1
			case "$(_adb_to 4 devices)" in *"$_ma_s	device"*) return 0 ;; esac
			return 1 ;;
		*refused*|*"unable to connect"*|*"failed to connect"*) ;;
		*) return 1 ;;
	esac
	[ "$(uci -q get "$CFG.m_$(echo "$2" | sed 's/[^A-Za-z0-9]/_/g').hl_adb")" = 0 ] && return 1
	_ma_f="$CACHE_DIR/mtkadb_$(_tk "$1")"
	[ -f "$_ma_f" ] && [ -z "$(find "$_ma_f" -mmin +10 2>/dev/null)" ] && return 1
	: > "$_ma_f"
	_zte_login_jar "$1" "$2" 1 || return 1
	_ma_j="$CACHE_DIR/ztejar_$(_tk "$1")"
	_ma_src=$(_srcip_for "" "$1")
	case "$(curl -s --max-time 8 ${_ma_src:+--interface "$_ma_src"} -A "$UA" -b "$_ma_j" -c "$_ma_j" \
		-H "Referer: http://$1/index.html" "http://$1/adbWifiDebugForm.do?adb=1" 2>/dev/null)" in
		*enabled*) logger -t 5gmodem "hilink(mtk): ADB over network enabled on $1 for temperatures" ;;
		*) return 1 ;;
	esac
	sleep 2
	case "$(_adb_to 6 connect "$_ma_s")" in *"connected to"*) ;; *) return 1 ;; esac
	sleep 1
	case "$(_adb_to 4 devices)" in *"$_ma_s	device"*) return 0 ;; esac
	return 1
}

_mtk_usock() {
	_mu_s="$1:5555"; _mu_b=/usr/share/5gmodem/mtk/usock-armv7
	[ -f "$_mu_b" ] || return 1
	_mu_n=$(wc -c < "$_mu_b" | tr -cd '0-9')
	[ "$(_adb_to 5 -s "$_mu_s" shell "toybox wc -c < /data/local/tmp/5gm-usock 2>/dev/null" | tr -cd '0-9')" = "$_mu_n" ] && return 0
	_adb_to 8 -s "$_mu_s" push "$_mu_b" /data/local/tmp/5gm-usock >/dev/null
	_adb_to 5 -s "$_mu_s" shell "chmod 755 /data/local/tmp/5gm-usock" >/dev/null
	[ "$(_adb_to 5 -s "$_mu_s" shell "toybox wc -c < /data/local/tmp/5gm-usock 2>/dev/null" | tr -cd '0-9')" = "$_mu_n" ]
}

mtk_at() {
	_ma_a="$1"; _ma_p="$2"; shift 2
	command -v adb >/dev/null 2>&1 || return 1
	_mtk_adb_on "$_ma_a" "$_ma_p" || return 1
	_mtk_usock "$_ma_a" || return 1
	_ma_c=""
	for _ma_x in "$@"; do
		_ma_c="$_ma_c/data/local/tmp/5gm-usock /dev/socket/rild-atci '$_ma_x' 3000;"
	done
	_adb_to 12 -s "$_ma_a:5555" shell "$_ma_c" | tr -d '\r' | grep -v '^$'
}

mtk_cell() {
	_mc_f="$CACHE_DIR/mtkcell_$(_tk "$1")"
	if [ -s "$_mc_f" ] && [ $(( $(date +%s) - $(date -r "$_mc_f" +%s 2>/dev/null || echo 0) )) -lt 8 ]; then
		cat "$_mc_f"; return 0
	fi
	_mc_o=$(mtk_at "$1" "$2" AT+ECSQ AT+ECELL AT+CSQ)
	case "$_mc_o" in
		*+ECSQ:*) printf '%s\n' "$_mc_o" > "$_mc_f" ;;
		*) [ -s "$_mc_f" ] && [ -z "$(find "$_mc_f" -mmin +10 2>/dev/null)" ] && _mc_o=$(cat "$_mc_f") ;;
	esac
	printf '%s\n' "$_mc_o"
}

_mtk_pbse() {
	mtk_at "$1" "$2" "AT+EPBSE?" | sed -n 's/^+EPBSE: *//p' | head -1 | tr -d ' '
}

_mtk_lte_bands() {
	awk -v f="$1" -v t="$2" 'BEGIN { o=""
		for (i=0; i<32; i++) if (int(f/2^i)%2) o=o (o?" ":"") (i+1)
		for (i=0; i<32; i++) if (int(t/2^i)%2) o=o (o?" ":"") (i+33)
		print o }'
}

mtk_bandcap() {
	_mb_s="$CFG.m_$(echo "$2" | sed 's/[^A-Za-z0-9]/_/g')"
	_mb_c=$(uci -q get "$_mb_s.mtk_bandcap")
	_mb_v=$(_mtk_pbse "$1" "$2")
	[ -n "$_mb_v" ] || return 1
	if [ -z "$_mb_c" ]; then
		uci -q set "$_mb_s.mtk_bandcap=$_mb_v"; uci -q commit "$CFG"; _mb_c="$_mb_v"
	else
		_mb_n=$(printf '%s|%s' "$_mb_c" "$_mb_v" | awk -F'[|,]' '{ printf "%d,%d,%d,%d", or($1,$5), or($2,$6), or($3,$7), or($4,$8) }' 2>/dev/null)
		if [ -n "$_mb_n" ] && [ "$_mb_n" != "$_mb_c" ]; then
			uci -q set "$_mb_s.mtk_bandcap=$_mb_n"; uci -q commit "$CFG"; _mb_c="$_mb_n"
		fi
	fi
	printf '%s|%s' "$_mb_c" "$_mb_v"
}

mtk_setbands() {
	_a=$(_addr_for "$2") || { echo '{"success":false}'; return 1; }
	_ms_cv=$(mtk_bandcap "$_a" "$2")
	_ms_cap=${_ms_cv%%|*}; _ms_cur=${_ms_cv#*|}
	[ -n "$_ms_cap" ] && [ -n "$_ms_cur" ] || { echo '{"success":false}'; return 1; }
	_ms_g=$(echo "$_ms_cur" | cut -d, -f1); _ms_u=$(echo "$_ms_cur" | cut -d, -f2)
	if [ "$1" = default ] || [ -z "$1" ]; then
		_ms_f=$(echo "$_ms_cap" | cut -d, -f3); _ms_t=$(echo "$_ms_cap" | cut -d, -f4)
	else
		_ms_f=0; _ms_t=0
		for _b in $(echo "$1" | tr ',' ' '); do
			case "$_b" in ''|*[!0-9]*) continue ;; esac
			if [ "$_b" -ge 1 ] && [ "$_b" -le 32 ]; then _ms_f=$(( _ms_f | (1 << (_b - 1)) ))
			elif [ "$_b" -ge 33 ] && [ "$_b" -le 64 ]; then _ms_t=$(( _ms_t | (1 << (_b - 33)) )); fi
		done
		_ms_f=$(( _ms_f & $(echo "$_ms_cap" | cut -d, -f3) ))
		_ms_t=$(( _ms_t & $(echo "$_ms_cap" | cut -d, -f4) ))
		[ $(( _ms_f | _ms_t )) -gt 0 ] || { echo '{"success":false,"error":"no supported band"}'; return 1; }
	fi
	case "$(mtk_at "$_a" "$2" "AT+EPBSE=$_ms_g,$_ms_u,$_ms_f,$_ms_t")" in
		*OK*) rm -f "$CACHE_DIR/mtkcell_$(_tk "$_a")"; echo '{"success":true}' ;;
		*) echo '{"success":false}' ;;
	esac
}

mtk_bands_json() {
	_a=$(_addr_for "$1") || return 1
	_mj_cv=$(mtk_bandcap "$_a" "$1")
	_mj_cap=${_mj_cv%%|*}; _mj_cur=${_mj_cv#*|}
	[ -n "$_mj_cap" ] || return 1
	printf '%s|%s\n' "$(_mtk_lte_bands "$(echo "$_mj_cap" | cut -d, -f3)" "$(echo "$_mj_cap" | cut -d, -f4)")" \
		"$(_mtk_lte_bands "$(echo "$_mj_cur" | cut -d, -f3)" "$(echo "$_mj_cur" | cut -d, -f4)")"
}

mtk_temps() {
	_mt_f="$CACHE_DIR/mtktemps_$(_tk "$1")"
	if [ -f "$_mt_f" ] && [ -z "$(find "$_mt_f" -mmin +1 2>/dev/null)" ]; then
		cat "$_mt_f"; return 0
	fi
	command -v adb >/dev/null 2>&1 || return 1
	_mt_o=""
	_mtk_adb_on "$1" "$2" && _mt_o=$(_adb_to 6 -s "$1:5555" shell \
		'for z in /sys/class/thermal/thermal_zone*; do echo "$(cat $z/type) $(cat $z/temp)"; done' | tr -d '\r' \
		| awk '{ k=""
			if ($1=="mtktspa") k="pa"; else if ($1=="mtktscpu") k="cpu"; else if ($1=="mtktswmt") k="wifi"
			else if ($1=="mtktspmic") k="pmic"; else if ($1=="mtktsbattery") k="bat"; else if ($1=="mtktsAP") k="board"
			if (k != "" && $2 ~ /^-?[0-9]+$/ && $2 > 0) printf "%s%s=%.1f", (n++ ? " " : ""), k, $2/1000 }')
	if [ -n "$_mt_o" ]; then
		printf '%s' "$_mt_o" > "$_mt_f"
	elif [ -s "$_mt_f" ] && [ -z "$(find "$_mt_f" -mmin +10 2>/dev/null)" ]; then
		_mt_o=$(cat "$_mt_f")
	fi
	printf '%s' "$_mt_o"
}

zte_getmode() {
	_a=$(_addr_for "$1") || return 1
	case "$(_zj "$(_zte_get "$_a" net_select)" net_select)" in
		Only_LTE) echo 4 ;;
		Only_WCDMA) echo 2 ;;
		Only_GSM) echo 8 ;;
		*) echo 1 ;;
	esac
}

zte_setmode() {
	case "$1" in
		1) _zsm=NETWORK_auto ;;
		8) _zsm=Only_GSM ;;
		2) _zsm=Only_WCDMA ;;
		4) _zsm=Only_LTE ;;
		*) echo '{"error":"bad mode"}'; return 1 ;;
	esac
	_a=$(_addr_for "$2") || { echo '{"error":"no address"}'; return 1; }
	_zsp=$(_zj "$(_zte_get "$_a" net_priority)" net_priority)
	if _zte_post_auth "$_a" "goformId=SET_BEARER_PREFERENCE&BearerPreference=$_zsm%0A${_zsp:-LTE_preferred}" "$2" >/dev/null; then
		echo '{"success":true}'
	else
		echo '{"success":false}'
	fi
}

hl_getmode() {
	_nm=$(api_get /api/net/net-mode "$1" | xval NetworkMode)
	case "$_nm" in
		03) echo 4 ;;
		02) echo 2 ;;
		01) echo 8 ;;
		00|"") echo 1 ;;
		*) echo 1 ;;
	esac
}

hl_setmode() {
	case "$1" in
		1) _nm="00" ;;
		8) _nm="01" ;;
		2) _nm="02" ;;
		4) _nm="03" ;;
		*) echo '{"error":"bad mode"}'; return 1 ;;
	esac
	_cur=$(api_get /api/net/net-mode "$2")
	_nb=$(printf '%s' "$_cur" | xval NetworkBand); [ -n "$_nb" ] || _nb="3FFFFFFF"
	_lte=$(printf '%s' "$_cur" | xval LTEBand); [ -n "$_lte" ] || _lte="7FFFFFFFFFFFFFFF"
	_r=$(api_post /api/net/net-mode \
		"<NetworkMode>$_nm</NetworkMode><NetworkBand>$_nb</NetworkBand><LTEBand>$_lte</LTEBand>" "$2")
	case "$_r" in
		*'<response>OK</response>'*) echo '{"success":true}' ;;
		*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
	esac
}

case "$1" in
	probe)
		_a=$(_addr_for "$2") || { echo '{"hilink":0}'; exit 0; }
		_pv=$(_vidpid_for "$2")
		[ -n "$_pv" ] || _pv="$(cat "/sys/bus/usb/devices/$2/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$2/idProduct" 2>/dev/null)"
		if [ "$_pv" = "0846:68e1" ]; then
			case "$(_ng_at "$_a" ATI)" in
				*OK*) printf '{"hilink":1,"addr":"%s","classify":"netgear"}\n' "$_a" ;;
				*) printf '{"hilink":0,"addr":"%s"}\n' "$_a" ;;
			esac
			exit 0
		fi
		_r=$(api_get /api/device/basic_information "$2")
		case "$_r" in
			*'<classify>'*) printf '{"hilink":1,"addr":"%s","classify":"%s"}\n' \
				"$_a" "$(printf '%s' "$_r" | xval classify)" ; exit 0 ;;
		esac
		_r=$(_zte_get "$_a" modem_main_state)
		case "$_r" in
			*'"modem_main_state"'*) printf '{"hilink":1,"addr":"%s","classify":"zte"}\n' "$_a"; exit 0 ;;
		esac
		case "$(_yota_get "$_a")" in
			*InterfaceType*=*) printf '{"hilink":1,"addr":"%s","classify":"yota"}\n' "$_a" ;;
			*) printf '{"hilink":0,"addr":"%s"}\n' "$_a" ;;
		esac
		;;
	json|metrics) metrics_json "$2" ;;
	addr)        _addr_for "$2" ;;
	get)         api_get "$2" "$3" ;;
	connect)
		case "$(_api_vid "$2")" in
			19d2:*) _a=$(_addr_for "$2") && _zte_post_auth "$_a" "goformId=CONNECT_NETWORK" "$2" >/dev/null ;;
			*) api_post /api/dialup/mobile-dataswitch "<dataswitch>1</dataswitch>" "$2" ;;
		esac ;;
	disconnect)
		case "$(_api_vid "$2")" in
			19d2:*) _a=$(_addr_for "$2") && _zte_post_auth "$_a" "goformId=DISCONNECT_NETWORK" "$2" >/dev/null ;;
			*) api_post /api/dialup/mobile-dataswitch "<dataswitch>0</dataswitch>" "$2" ;;
		esac ;;
	reboot)
		case "$(_api_vid "$2")" in
			19d2:*)
				_a=$(_addr_for "$2") || exit 0
				if _tenda_on "$_a"; then
					_tenda_set "$_a" deviceAction '{"deviceAction":{"action":"0"}}' "$2" >/dev/null
				else
					_zte_post_auth "$_a" "goformId=REBOOT_DEVICE" "$2" >/dev/null
				fi ;;
			*) api_post /api/device/control "<Control>1</Control>" "$2" ;;
		esac ;;
	mode)
		case "$2" in
			debug|1) _m=1 ;;
			normal|0) _m=0 ;;
			*) echo '{"error":"mode must be debug or normal"}'; exit 0 ;;
		esac
		case "$(_api_vid "$3")" in
			19d2:*)
				_a=$(_addr_for "$(_hl_path "$3")") || { echo '{"success":false,"code":"noaddr"}'; exit 0; }
				_r=$(_zte_set "$_a" "goformId=SET_DEVICE_MODE&debug_enable=$_m")
				case "$_r" in
					*successfully*)
						if _tenda_on "$_a"; then
							_tenda_set "$_a" deviceAction '{"deviceAction":{"action":"0"}}' "$3" >/dev/null
						else
							_zte_set "$_a" "goformId=REBOOT_DEVICE" >/dev/null
						fi
						printf '{"success":true,"mode":"%s","reboot":1}\n' "$2" ;;
					*) printf '{"success":false,"code":"%s"}\n' "$(_zj "$_r" result)" ;;
				esac
				exit 0 ;;
		esac
		_r=$(api_post /api/device/mode "<mode>$_m</mode>" "$3")
		case "$_r" in
			*'<response>OK</response>'*) printf '{"success":true,"mode":"%s"}\n' "$2" ;;
			*) printf '{"success":false,"code":"%s"}\n' "$(printf '%s' "$_r" | xval code)" ;;
		esac
		;;
	smsread)     case "$(_api_vid "$3")" in
			19d2:*) if _is_tenda "$3"; then tenda_sms_list "${2:-in}" "$3"; else zte_sms_list "${2:-in}" "$3"; fi ;;
			*) sms_list "${2:-in}" "$3" ;;
		esac ;;
	smscount)    case "$(_api_vid "$2")" in
			19d2:*) if _is_tenda "$2"; then tenda_sms_count "$2"; else zte_sms_count "$2"; fi ;;
			*) api_get /api/sms/sms-count "$2" ;;
		esac ;;
	smssend)     case "$(_api_vid "$4")" in
			19d2:*) if _is_tenda "$4"; then tenda_sms_send "$2" "$3" "$4"; else zte_sms_send "$2" "$3" "$4"; fi ;;
			*) sms_send "$2" "$3" "$4" ;;
		esac ;;
	smsdel)      case "$(_api_vid "$3")" in
			19d2:*) if _is_tenda "$3"; then tenda_sms_delete "$2" "$3"; else zte_sms_delete "$2" "$3"; fi ;;
			*) sms_delete "$2" "$3" ;;
		esac ;;
	smsmarkread) case "$(_api_vid "$3")" in
			19d2:*) if _is_tenda "$3"; then tenda_sms_markread "$2" "$3"; else echo '{"success":true}'; fi ;;
			*) echo '{"success":true}' ;;
		esac ;;
	ussd)        hl_ussd "$2" "$3" ;;
	getbands)    hl_getbands "$2" ;;
	setbands)    hl_setbands "$2" "$3" ;;
	supbands)    hl_supbands "$2" ;;
	getbands3g)  hl_getbands3g "$2" ;;
	setbands3g)  hl_setbands3g "$2" "$3" ;;
	supbands3g)  hl_supbands3g "$2" ;;
	getbands2g)  hl_getbands2g "$2" ;;
	setbands2g)  hl_setbands2g "$2" "$3" ;;
	supbands2g)  hl_supbands2g "$2" ;;
	getmode)     hl_getmode "$2" ;;
	zgetmode)    zte_getmode "$2" ;;
	mtkbands)    mtk_bands_json "$2" ;;
	mtksetbands) mtk_setbands "$2" "$3" ;;
	zsetmode)    zte_setmode "$2" "$3" ;;
	setmode)     hl_setmode "$2" "$3" ;;
	getroaming)  hl_getroaming "$2" ;;
	setroaming)  hl_setroaming "$2" "$3" ;;
	*)
		echo "usage: hilink.sh {probe|json|addr|get <ep>|connect|disconnect|reboot} [usb-path]" >&2
		exit 1
		;;
esac
exit 0
