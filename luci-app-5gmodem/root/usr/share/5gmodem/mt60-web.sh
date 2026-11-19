# Stock web API shared by the native MT60 bands and USSD integrations.
mt60_native() {
	[ -d /sys/class/net/ccmni0 ] &&
		[ "$(uci -q get 5gmodem.m_mt60.vidpid)" = '0e8d:2004' ]
}

MT60_ORIGIN=http://192.168.42.1

mt60_web() {
	curl --noproxy '*' -fsS --max-time 6 \
		-H "Referer: $MT60_ORIGIN/index.html" -H 'X-Requested-With: XMLHttpRequest' "$@"
}

mt60_web_get() {
	local command="$1"
	shift
	mt60_web "$@" "${MT60_ORIGIN}/goform/goform_get_cmd_process?isTest=false&cmd=$command"
}

mt60_web_post() {
	local jar="$1"; shift
	mt60_web -b "$jar" -c "$jar" --data 'isTest=false' "$@" "$MT60_ORIGIN/goform/goform_set_cmd_process"
}

mt60_login() {
	local user pass encoded result
	user=$(uci -q get 5gmodem.m_mt60.web_user)
	pass=$(uci -q get 5gmodem.m_mt60.web_pass)
	if [ "$(uci -q get 5gmodem.m_mt60.web_pass_empty)" = 1 ]; then
		pass=""
	else
		pass="${pass:-admin}"
	fi
	command -v _b64 >/dev/null 2>&1 || . /usr/share/5gmodem/lib.sh
	encoded=$(_b64 "${user:-admin}
$pass")
	[ -n "$encoded" ] || return 1
	result=$(mt60_web_post "$1" --data 'goformId=LOGIN' --data-urlencode "password=$encoded") || return 1
	case "$(jsonfilter -s "$result" -e '@.result')" in 0|4) return 0 ;; *) return 1 ;; esac
}
