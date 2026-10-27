#!/bin/sh

MODE="$1"
PORT="$2"
case "$MODE" in
	soft|hard|power|haspower|usbpower|hasusbpower) ;;
	/dev/*)    PORT="$MODE"; MODE="soft" ;;
	*)         MODE="soft" ;;
esac

POWER_GPIOS="modem_power modem_reset 4g 5g1 5g2"
case "$(cat /tmp/sysinfo/board_name 2>/dev/null)" in
	securifi,almond-3s|securifi,almond3s) POWER_GPIOS="modem_power 4g 5g1 5g2" ;;
esac
first_power_gpio() {
	for _g in $POWER_GPIOS; do
		[ -e "/sys/class/gpio/$_g/value" ] && { echo "$_g"; return 0; }
	done
	return 1
}

_usb_port_dir() {
	case "$1" in
		*.*)
			_hub="${1%.*}"
			_pn="${1##*.}"
			echo "/sys/bus/usb/devices/$_hub/$_hub:1.0/$_hub-port$_pn"
			;;
		*-*)
			_bus="${1%%-*}"; _pn="${1##*-}"
			echo "/sys/bus/usb/devices/usb$_bus/$_bus-0:1.0/usb$_bus-port$_pn"
			;;
	esac
}

usb_power_method() {
	_pd=$(_usb_port_dir "$1")
	[ -n "$_pd" ] && [ -w "$_pd/disable" ] && { echo "disable"; return 0; }
	[ -w "/sys/bus/usb/devices/$1/authorized" ] && { echo "authorized"; return 0; }
	[ -w /sys/bus/usb/drivers/usb/unbind ] && [ -e "/sys/bus/usb/devices/$1" ] \
		&& { echo "rebind"; return 0; }
	return 1
}

if [ "$MODE" = hasusbpower ]; then
	_p="$PORT"
	[ -n "$_p" ] || _p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	echo "{\"path\":\"$_p\",\"method\":\"$(usb_power_method "$_p" 2>/dev/null)\"}"
	exit 0
fi

if [ "$MODE" = usbpower ]; then
	_p="$PORT"
	[ -n "$_p" ] || _p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_p" ] || { echo '{"success":false,"error":"no modem path"}'; exit 0; }
	_m=$(usb_power_method "$_p") || { echo '{"success":false,"error":"no usb power control"}'; exit 0; }
	_pd=$(_usb_port_dir "$_p")
	(
		case "$_m" in
			disable)
				_pp=$(readlink -f "$_pd/peer" 2>/dev/null)
				[ -n "$_pp" ] && [ -w "$_pp/disable" ] || _pp=""
				_pfirst="$_pd"; _plast="$_pp"
				if [ -n "$_pp" ]; then
					_pbus=$(basename "$(dirname "$(dirname "$_pd")")")
					case "$_pbus" in usb*) ;; *) _pbus="usb${_pbus%%-*}" ;; esac
					[ "$(cat "/sys/bus/usb/devices/$_pbus/speed" 2>/dev/null)" -ge 5000 ] 2>/dev/null \
						|| { _pfirst="$_pp"; _plast="$_pd"; }
					echo 1 > "$_pp/disable" 2>/dev/null
				fi
				echo 1 > "$_pd/disable" 2>/dev/null
				sleep 6
				echo 0 > "$_pfirst/disable" 2>/dev/null
				if [ -n "$_plast" ]; then
					sleep 2
					echo 0 > "$_plast/disable" 2>/dev/null
				fi
				_up_n=0
				while [ "$_up_n" -lt 40 ] && [ ! -e "/sys/bus/usb/devices/$_p" ]; do
					sleep 1; _up_n=$((_up_n + 1))
				done
				if [ ! -e "/sys/bus/usb/devices/$_p" ]; then
					echo 0 > "$_pd/disable" 2>/dev/null
					[ -n "$_pp" ] && echo 0 > "$_pp/disable" 2>/dev/null
					logger -p daemon.err -t 5gmodem "usbpower: $_p did NOT come back after port disable - disable=$(cat "$_pd/disable" 2>/dev/null); a USB controller reset or reboot may be needed"
				fi
				;;
			authorized)
				echo 0 > "/sys/bus/usb/devices/$_p/authorized" 2>/dev/null
				sleep 6
				echo 1 > "/sys/bus/usb/devices/$_p/authorized" 2>/dev/null
				;;
			rebind)
				echo "$_p" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
				sleep 6
				echo "$_p" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
				;;
		esac
		logger -t 5gmodem "usbpower: $_p power-cycled ($_m)"
		sleep 20
		/usr/share/5gmodem/modemswitch.sh resolve >/dev/null 2>&1
		_ifn=$(uci -q get "5gmodem.m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g').network")
		[ -n "$_ifn" ] || [ "$_p" != "$(uci -q get 5gmodem.@5gmodem[0].active_modem)" ] \
			|| _ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
		if [ -n "$_ifn" ]; then
			sleep 5
			ifdown "$_ifn" >/dev/null 2>&1
			sleep 2
			ifup "$_ifn" >/dev/null 2>&1
		fi
	) >/dev/null 2>&1 </dev/null &
	echo "{\"success\":true,\"mode\":\"usbpower\",\"method\":\"$_m\",\"path\":\"$_p\"}"
	sleep 1
	exit 0
fi

if [ "$MODE" = haspower ]; then
	echo "{\"gpio\":\"$(first_power_gpio)\"}"
	exit 0
fi

if [ "$MODE" = power ]; then
	G="$PORT"; [ -n "$G" ] || G=$(first_power_gpio)
	GP="/sys/class/gpio/$G/value"
	[ -n "$G" ] && [ -e "$GP" ] || { echo '{"success":false,"error":"no modem power gpio"}'; exit 0; }
	_pg_on=$(cat "$GP" 2>/dev/null)
	case "$_pg_on" in 0|1) ;; *) _pg_on=0 ;; esac
	_pg_off=$((1 - _pg_on))
	_pg_path=$(uci -q get 5gmodem.@5gmodem[0].active_modem 2>/dev/null)
	_pg_was=0
	_pg_dn=""
	[ -n "$_pg_path" ] && [ -e "/sys/bus/usb/devices/$_pg_path" ] && {
		_pg_was=1
		_pg_dn=$(cat "/sys/bus/usb/devices/$_pg_path/devnum" 2>/dev/null)
	}
	_pg_back() {
		[ -e "/sys/bus/usb/devices/$_pg_path" ] || return 1
		[ "$(cat "/sys/bus/usb/devices/$_pg_path/devnum" 2>/dev/null)" != "$_pg_dn" ]
	}
	_pg_kick() {
		_pg_pd=$(_usb_port_dir "$_pg_path")
		[ -w "$_pg_pd/disable" ] || return 1
		_pg_pp=$(readlink -f "$_pg_pd/peer" 2>/dev/null)
		[ -n "$_pg_pp" ] && echo 1 > "$_pg_pp/disable" 2>/dev/null
		echo 1 > "$_pg_pd/disable" 2>/dev/null
		sleep 3
		[ -n "$_pg_pp" ] && echo 0 > "$_pg_pp/disable" 2>/dev/null
		sleep 2
		echo 0 > "$_pg_pd/disable" 2>/dev/null
		return 0
	}
	_pg_wait() {
		_pg_w=0
		while [ "$_pg_w" -lt "$1" ]; do
			_pg_back && return 0
			sleep 1; _pg_w=$((_pg_w + 1))
		done
		_pg_back
	}
	(
		echo "$_pg_off" > "$GP" 2>/dev/null
		sleep 5
		_pg_gone=1
		[ "$_pg_was" = 1 ] && [ -e "/sys/bus/usb/devices/$_pg_path" ] \
			&& [ "$(cat "/sys/bus/usb/devices/$_pg_path/devnum" 2>/dev/null)" = "$_pg_dn" ] && _pg_gone=0
		echo "$_pg_on" > "$GP" 2>/dev/null
		[ -n "$_pg_path" ] || exit 0
		if [ "$_pg_was" = 1 ]; then
			if [ "$_pg_gone" = 1 ]; then
				_pg_wait 150 && exit 0
				_pg_why="did not return within 150 s"
			else
				_pg_why="stayed on the bus with $G off, $G does not power it"
			fi
			if _pg_kick; then
				logger -t 5gmodem "power: $_pg_path $_pg_why - reset its USB port"
				if _pg_wait 150; then
					logger -t 5gmodem "power: $_pg_path came back after the USB port reset"
					exit 0
				fi
			elif _pg_wait 120; then
				exit 0
			fi
			logger -t 5gmodem "power: $_pg_path still missing - powering the slot off for 15 s"
			echo "$_pg_off" > "$GP" 2>/dev/null
			sleep 15
			echo "$_pg_on" > "$GP" 2>/dev/null
			sleep 20
			_pg_kick
			if _pg_wait 240; then
				logger -t 5gmodem "power: $_pg_path came back after the long power-off"
				exit 0
			fi
			logger -p daemon.err -t 5gmodem "power: $_pg_path did not come back after the power cycle, USB port resets and a long power-off - reboot the router"
			exit 0
		fi
		_pg_n=0
		while [ "$_pg_n" -lt 120 ] && [ ! -e "/sys/bus/usb/devices/$_pg_path" ]; do
			sleep 1; _pg_n=$((_pg_n + 1))
		done
		[ -e "/sys/bus/usb/devices/$_pg_path" ] && exit 0
		echo "$_pg_off" > "$GP" 2>/dev/null
		_pg_n=0
		while [ "$_pg_n" -lt 120 ] && [ ! -e "/sys/bus/usb/devices/$_pg_path" ]; do
			sleep 1; _pg_n=$((_pg_n + 1))
		done
		if [ -e "/sys/bus/usb/devices/$_pg_path" ]; then
			logger -t 5gmodem "power: $_pg_path came back with $G=$_pg_off - left it at $_pg_off"
			exit 0
		fi
		echo "$_pg_on" > "$GP" 2>/dev/null
		logger -t 5gmodem "power: $_pg_path did not come back with either value of $G - restored $_pg_on"
	) >/dev/null 2>&1 </dev/null &
	echo "{\"success\":true,\"mode\":\"power\",\"gpio\":\"$G\"}"
	sleep 1
	exit 0
fi

_rb_act=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
_rb_am=""
if [ -n "$PORT" ]; then
	_rb_tp=$(readlink -f "/sys/class/tty/${PORT##*/}/device" 2>/dev/null)
	_rb_tp=${_rb_tp%/*}; _rb_tp=${_rb_tp##*/}
	_rb_am=${_rb_tp%%:*}
	case "$_rb_am" in [0-9]*-[0-9]*) ;; *) _rb_am="" ;; esac
fi
[ -n "$_rb_am" ] || _rb_am="$_rb_act"
_rb_if=""
if [ -n "$_rb_am" ]; then
	_rb_if=$(uci -q get "5gmodem.m_$(echo "$_rb_am" | sed 's/[^A-Za-z0-9]/_/g').network")
fi
if [ -z "$_rb_if" ] && [ "$_rb_am" = "$_rb_act" ]; then
	_rb_if=$(uci -q get 5gmodem.@5gmodem[0].network)
fi
if [ -n "$_rb_am" ]; then
	_rb_sec="m_$(echo "$_rb_am" | sed 's/[^A-Za-z0-9]/_/g')"
	if [ "$(uci -q get "5gmodem.$_rb_sec.kind")" = "hilink" ]; then
		( /usr/share/5gmodem/hilink.sh reboot "$_rb_am" ) >/dev/null 2>&1 </dev/null &
		echo '{"success":true,"mode":"hilink-api"}'
		sleep 1
		exit 0
	fi
fi

[ -n "$PORT" ] || PORT=$(/usr/share/5gmodem/detect.sh 2>/dev/null)
[ -n "$PORT" ] || { echo '{"success":false,"error":"AT port not found"}'; exit 0; }

. /usr/share/5gmodem/atlock.sh
. /usr/share/5gmodem/lib.sh 2>/dev/null
at_lock "$PORT" 15 || { echo '{"success":false,"error":"AT port busy"}'; exit 0; }

_rb_sr=""
if [ -c "$PORT" ] && [ "$(cat "/sys/bus/usb/devices/$_rb_am/idVendor" 2>/dev/null)" = 1199 ] \
	&& [ "$(cat "/sys/bus/usb/devices/$_rb_am/idProduct" 2>/dev/null)" != a001 ] \
	&& command -v at_query >/dev/null 2>&1; then
	_rb_cf="/tmp/5gmodem/sierra_cnd_$(echo "${PORT##*/}" | tr -c 'A-Za-z0-9' '_')"
	for _rb_pw in $(cat "$_rb_cf" 2>/dev/null) A710 F710; do
		case "$(at_query "$PORT" "AT!ENTERCND=\"$_rb_pw\"" 3)" in
			*ERROR*) ;;
			*) break ;;
		esac
	done
	if _rb_o=$(at_query "$PORT" 'AT!RESET' 3); then
		case "$_rb_o" in
			*ERROR*) logger -t 5gmodem "sierra: AT!RESET rejected on $PORT - falling back to AT+CFUN" ;;
			*) _rb_sr=1; logger -t 5gmodem "sierra: $_rb_am reset with AT!RESET ($MODE restart)" ;;
		esac
	fi
fi

if [ "$MODE" = "hard" ] || [ -n "$_rb_sr" ]; then
	IF="$_rb_if"
	_AMP="$_rb_am"
	_rb_mi=""
	if [ -n "$_rb_sr" ]; then
		[ "$(uci -q get "network.$IF.proto")" = mbim ] && { _rb_mi="$IF"; IF=""; }
	else
		( sms_tool -d "$PORT" at "AT+CFUN=1,1" ) >/dev/null 2>&1 </dev/null &
	fi
	if [ -n "$IF" ] && [ -n "$_AMP" ]; then
	( eval "exec $AT_LOCK_FD>&-"
	  _n=0
	  while [ "$_n" -lt 40 ] && [ -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  _n=0
	  while [ "$_n" -lt 100 ] && [ ! -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  [ -e "/sys/bus/usb/devices/$_AMP" ] || exit 0
	  sleep 8
	  ubus call "network.interface.$IF" down >/dev/null 2>&1
	  sleep 3
	  _rbd=$(uci -q get "network.$IF.device")
	  proto_in uqmi "$(uci -q get "network.$IF.proto")" || _rbd=""
	  case "$_rbd" in
		/dev/cdc-wdm*)
			_n=0
			while [ "$_n" -lt 24 ]; do
				case "$(uqmi -s -d "$_rbd" -t 3000 --uim-get-sim-state 2>/dev/null)" in
					*'"card_application_state":"ready"'*) break ;;
				esac
				sleep 5; _n=$((_n + 1))
			done ;;
	  esac
	  ubus call "network.interface.$IF" up >/dev/null 2>&1 || ifup "$IF" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
	fi
	if [ -n "$_rb_mi" ] && [ -n "$_AMP" ]; then
	( eval "exec $AT_LOCK_FD>&-"
	  read -r _t0 _ < /proc/uptime
	  _n=0
	  while [ "$_n" -lt 40 ] && [ -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  _n=0
	  while [ "$_n" -lt 100 ] && [ ! -e "/sys/bus/usb/devices/$_AMP" ]; do sleep 1; _n=$((_n+1)); done
	  [ -e "/sys/bus/usb/devices/$_AMP" ] || exit 0
	  sleep 60
	  read -r _t1 _ < /proc/uptime
	  _st=$(ifstatus "$_rb_mi" 2>/dev/null)
	  printf '%s\n' "$_st" | grep -q '"up": true' || exit 0
	  [ "$(printf '%s\n' "$_st" | jsonfilter -e '@.uptime' 2>/dev/null)" -gt $(( ${_t1%.*} - ${_t0%.*} )) ] 2>/dev/null || exit 0
	  logger -t 5gmodem "sierra: $_rb_mi kept its old session after AT!RESET - reconnecting"
	  ubus call "network.interface.$_rb_mi" down >/dev/null 2>&1
	  sleep 3
	  ubus call "network.interface.$_rb_mi" up >/dev/null 2>&1 || ifup "$_rb_mi" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
	fi
elif [ -n "$_rb_if" ] && [ "$(uci -q get "network.$_rb_if.proto")" = ccmni ]; then
	IF="$_rb_if"
	( ubus call "network.interface.$IF" down >/dev/null 2>&1
		sms_tool -d "$PORT" at "AT+CFUN=0" >/dev/null 2>&1
		sleep 2
		sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
		at_unlock
		ubus call "network.interface.$IF" up >/dev/null 2>&1 || ifup "$IF" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
	eval "exec $AT_LOCK_FD>&-"
else
	IF="$_rb_if"
	[ -n "$IF" ] && : > "/tmp/5gmodem/bandrestore_$IF" 2>/dev/null
	( sms_tool -d "$PORT" at "AT+CFUN=4" >/dev/null 2>&1
		sleep 3
		_cf_n=0
		while [ "$_cf_n" -lt 3 ]; do
			_cf_n=$((_cf_n + 1))
			sms_tool -d "$PORT" at "AT+CFUN=1" >/dev/null 2>&1
			sleep 2
			case "$(sms_tool -d "$PORT" at "AT+CFUN?" 2>/dev/null)" in *"+CFUN: 1"*) break ;; esac
		done
		at_unlock
		[ -n "$IF" ] || exit 0
		sleep 6
		ubus call "network.interface.$IF" down >/dev/null 2>&1
		sleep 3
		ubus call "network.interface.$IF" up >/dev/null 2>&1 \
			|| ifup "$IF" >/dev/null 2>&1
	) >/dev/null 2>&1 </dev/null &
fi

echo "{\"success\":true,\"mode\":\"$MODE\"}"
sleep 1
exit 0
