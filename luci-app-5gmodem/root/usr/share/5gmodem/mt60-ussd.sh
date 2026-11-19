# Loaded by ussd.sh for the native MT60 only.
_mt60_ussd_finish() {
	_st done "" ',"native":"mt60","out":"'"$(_b64 "$1")"'","err":"'"$(_b64 "$2")"'","continue":'"$3"
}

_mt60_ussd_request() (
	umask 077
	jar=""
	trap '[ -z "$jar" ] || rm -f "$jar"; rmdir "$LOCK.mt60"' EXIT
	trap 'exit 143' INT TERM HUP
	jar=$(mktemp /tmp/mt60-ussd.XXXXXX) || { _mt60_ussd_finish "" 'USSD session unavailable' false; return 1; }
	mode=$1
	if ! mt60_login "$jar"; then
		_mt60_ussd_finish "" 'Modem web login failed' false; return 1
	fi
	case "$1" in
	send) set -- --data USSD_operator=ussd_send --data-urlencode "USSD_send_number=$2" ;;
	reply) set -- --data USSD_operator=ussd_reply --data-urlencode "USSD_reply_number=$2" ;;
	cancel) set -- --data USSD_operator=ussd_cancel ;;
	esac
	result=$(mt60_web_post "$jar" --data goformId=USSD_PROCESS "$@")
	if [ "$(jsonfilter -s "$result" -e '@.result')" != success ]; then
		_mt60_ussd_finish "" 'Modem rejected the USSD request' false; return 1
	fi
	if [ "$mode" = cancel ]; then
		_st idle ""
		return
	fi
	end=$(( $(uptime_s) + USSD_WAIT ))
	while [ "$(uptime_s)" -lt "$end" ]; do
		status=$(mt60_web_get ussd_write_flag -b "$jar" 2>/dev/null)
		case "$(jsonfilter -s "$status" -e '@.ussd_write_flag')" in
		16)
			info=$(mt60_web_get ussd_data_info -b "$jar" 2>/dev/null)
			if [ -n "$info" ]; then
				body=$(jsonfilter -s "$info" -e '@.ussd_data')
				more=false
				case "$(jsonfilter -s "$info" -e '@.ussd_action')" in ''|0) ;; *) more=true ;; esac
				_mt60_ussd_finish "$body" "" "$more"
				return
			fi ;;
		1|4|10|98|99)
			_mt60_ussd_finish "" 'No response from the network' false; return 1 ;;
		esac
		sleep 1
	done
	_mt60_ussd_finish "" 'USSD timed out' false
)

mt60_ussd_dispatch() {
	case "$1" in
	send|reply)
		case "$2" in ''|*[!0-9*#+]*) echo '{"error":"bad code"}'; return 2 ;; esac
		[ "${#2}" -le 64 ] || { echo '{"error":"bad code"}'; return 2; } ;;
	cancel) ;;
	esac
	mkdir "$LOCK.mt60" 2>/dev/null || { echo '{"error":"busy"}'; return 2; }
	_st running sending
	_mt60_ussd_request "$@" >/dev/null 2>&1 </dev/null &
	echo '{"status":"running","stage":"sending"}'
}
