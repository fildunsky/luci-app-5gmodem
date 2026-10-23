#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

CACHE="/tmp/5gmodem/speedtest.json"
URL_DEFAULT="internetometer"
UPURL_DEFAULT="internetometer"
URL_FALLBACK="https://speedtest.selectel.ru/1GB"
UPURL_FALLBACK="https://speedtest.rt.ru/backend/empty.php"

YA_PROBES_URL="https://yandex.ru/internet/api/v0/get-probes"
YA_RE_HOST='https://[a-zA-Z0-9.-]+\.cdn\.yandex\.net/[A-Za-z0-9_-]+'
YA_RE_DOWN="$YA_RE_HOST/probes/50mb\?[A-Za-z0-9._~%&=:/-]+"
YA_RE_UP="$YA_RE_HOST/upload\?[A-Za-z0-9._~%&=:/-]+"

_write() {
	echo "$1" > "$CACHE.$$" 2>/dev/null && mv "$CACHE.$$" "$CACHE" 2>/dev/null
}

_service_name() {
	_u="$1"
	[ -n "$_u" ] || _u=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$_u" ] || _u="$URL_DEFAULT"
	[ "$_u" = internetometer ] && { echo "Internetometer"; return; }
	_h=$(echo "$_u" | sed -e 's#^[a-zA-Z]*://##' -e 's#/.*##' -e 's#:.*##')
	case "$_h" in
		*yandex*)     echo "Yandex" ;;
		*cloudflare*) echo "Cloudflare" ;;
		*librespeed*) echo "LibreSpeed" ;;
		*selectel*)   echo "Selectel" ;;
		*hetzner*)    echo "Hetzner" ;;
		*tele2*)      echo "Tele2" ;;
		*thinkbroadband*) echo "ThinkBroadband" ;;
		*)            echo "$_h" ;;
	esac
}

_parse_ip() {
	echo "$1" | grep -oE '(^|[^0-9.])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9.]|$)' \
		| grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
		| awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255 && $1!=0&&$1!=10&&$1!=127&&$1<224 && !($1==169&&$2==254) && !($1==172&&$2>=16&&$2<=31) && !($1==192&&$2==168) && !($1==100&&$2>=64&&$2<=127) {print; exit}'
}

_parse_cc() {
	_g="$1"
	_c=$(echo "$_g" | grep -oE '^[A-Za-z][A-Za-z]$' | head -1)
	[ -n "$_c" ] || _c=$(echo "$_g" \
		| grep -oiE '"country_?code"[ :]*"[A-Za-z][A-Za-z]"' \
		| grep -oE '[A-Za-z][A-Za-z]"$' | tr -d '"' | head -1)
	echo "$_c" | tr 'a-z' 'A-Z'
}

_tobytes() {
	echo "$1" | awk '{
		v=$1; u="";
		if (v ~ /[kKmMgGtT]$/) { u=substr(v,length(v)); v=substr(v,1,length(v)-1) }
		v=v+0; m=1;
		if (u=="k"||u=="K") m=1024;
		else if (u=="m"||u=="M") m=1048576;
		else if (u=="g"||u=="G") m=1073741824;
		else if (u=="t"||u=="T") m=1099511627776;
		printf "%.0f", v*m
	}'
}

_num() { case "$1" in ''|*[!0-9.]*) printf '0' ;; *) printf '%s' "$1" ;; esac; }

_spent() {
	printf '%s' "$1" | awk '{
		n=0; for (i=1;i<=NF;i++) if ($i ~ /^[0-9]+:[0-9]+(:[0-9]+)?$/) t[++n]=$i;
		s=(n>=2)?t[2]:((n==1)?t[1]:"0");
		m=split(s,a,":"); v=0; for (i=1;i<=m;i++) v=v*60+a[i];
		printf "%d", v }'
}

_up_rates() {
	awk 'NF>=5 {
		want=$1+0; got=$2+0; t=$3-$4; c=$5+0
		if (c<=0 || got<want || want<=0 || t<=0) next
		printf "%.0f\n", got/t
	}' "$1" 2>/dev/null
}

_tombps() {
	echo "$1" | awk '{
		v=$1; u="";
		if (v ~ /[kKmMgGtT]$/) { u=substr(v,length(v)); v=substr(v,1,length(v)-1) }
		v=v+0; m=1;
		if (u=="k"||u=="K") m=1024;
		else if (u=="m"||u=="M") m=1048576;
		else if (u=="g"||u=="G") m=1073741824;
		printf "%.1f", (v*m*8)/1000000
	}'
}

_geo() {
	if [ -n "$GEOUA" ]; then curl --max-time "$1" -s -A "$GEOUA" "$2" 2>/dev/null
	else curl --max-time "$1" -s "$2" 2>/dev/null; fi
}

case "$1" in
start)
	if grep -q '"running":1' "$CACHE" 2>/dev/null \
		&& pgrep -f 5gmodem-speedtest >/dev/null 2>&1; then
		cat "$CACHE"
		exit 0
	fi
	if ! command -v curl >/dev/null 2>&1; then
		printf '{"running":0,"ok":0,"error":"no-curl","ts":%s}\n' "$(date +%s 2>/dev/null)" > "$CACHE" 2>/dev/null
		printf '{"running":0,"ok":0,"error":"no-curl"}\n'
		exit 0
	fi
	URL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_url)
	[ -n "$URL" ] || URL="$URL_DEFAULT"
	SECS=$(uci -q get 5gmodem.@5gmodem[0].speedtest_secs)
	case "$SECS" in ''|*[!0-9]*) SECS=15 ;; esac
	UPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_up_url)
	[ -n "$UPURL" ] || UPURL="$UPURL_DEFAULT"
	IPURL=$(uci -q get 5gmodem.@5gmodem[0].extip_url)
	[ -n "$IPURL" ] || IPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ip_url)
	[ -n "$IPURL" ] || IPURL="http://ip-api.com/line/?fields=countryCode,query"
	CCURL=$(uci -q get 5gmodem.@5gmodem[0].extip_cc_url)
	[ -n "$CCURL" ] || CCURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_cc_url)
	[ -n "$CCURL" ] || CCURL="http://ip-api.com/line/{ip}?fields=countryCode"
	GEOUA=$(uci -q get 5gmodem.@5gmodem[0].extip_ua)
	CCFALLBACK="http://ip-api.com/line/?fields=countryCode,query"
	YAIPURL=$(uci -q get 5gmodem.@5gmodem[0].speedtest_ru_ip_url)
	[ "$YAIPURL" = "https://yandex.ru/internet/api/v0/ip" ] && YAIPURL=""
	[ -n "$YAIPURL" ] || YAIPURL="https://ipv4-internet.yandex.net/api/v0/ip"
	SERVICE=$(_service_name)

	rm -f /tmp/5gmodem/st_stop /tmp/5gmodem/st_ip.* /tmp/5gmodem/st_cc.* /tmp/5gmodem/st_loc.* 2>/dev/null
	_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":0}"

	(
		PROG="/tmp/5gmodem/st_prog.$$"
		RESF="/tmp/5gmodem/st_res.$$"
		: > "$PROG"; : > "$RESF"

		GEOIP="/tmp/5gmodem/st_ip.$$"; GEOCC="/tmp/5gmodem/st_cc.$$"
		GEOLOC="/tmp/5gmodem/st_loc.$$"
		: > "$GEOIP"; : > "$GEOCC"; : > "$GEOLOC"
		(
			_fast=$(_parse_ip "$(_geo 3 "$YAIPURL")")
			[ -n "$_fast" ] && printf '%s' "$_fast" > "$GEOIP" 2>/dev/null
			_g=$(_geo 6 "$IPURL")
			_pub=$(_parse_ip "$_g"); _cc=$(_parse_cc "$_g")
			[ -n "$_pub" ] || _pub="$_fast"
			if [ -z "$_pub" ]; then
				_g2=$(_geo 5 "$CCFALLBACK")
				_pub=$(_parse_ip "$_g2")
				[ -n "$_cc" ] || _cc=$(_parse_cc "$_g2")
			fi
			if [ -z "$_pub" ]; then
				_pub=$(_parse_ip "$(_geo 6 "$YAIPURL")")
			fi
			_local=0
			if [ -z "$_pub" ]; then
				_pub=$(/usr/share/5gmodem/5gmodem.sh cached 30 2>/dev/null \
					| jsonfilter -e '@.ipaddr' 2>/dev/null | grep -E '^[0-9.]+$')
				_local=1
			fi
			if [ -z "$_pub" ]; then
				_pub=$(ip route get 77.88.8.8 2>/dev/null \
					| grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)
				_local=1
			fi
			printf '%s' "$_pub" > "$GEOIP" 2>/dev/null
			printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
			printf '%s' "$_local" > "$GEOLOC" 2>/dev/null
			if [ -z "$_cc" ] && [ -n "$_pub" ] && [ "$_local" = 0 ]; then
				_ccu=$(echo "$CCURL" | sed "s|{ip}|$_pub|g")
				_cc=$(_parse_cc "$(_geo 4 "$_ccu")")
				[ -n "$_cc" ] && printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
			fi
			if [ -z "$_cc" ] && [ -n "$_pub" ] && [ "$_local" = 0 ]; then
				_ccu=$(echo "$CCURL" | sed "s|{ip}|$_pub|g")
				_pp=$(sed -n 's/^\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
					/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
				if [ -n "$_pp" ] && [ "$_pp" != "0" ]; then
					if [ -n "$GEOUA" ]; then
						_cc=$(_parse_cc "$(curl --max-time 5 -s -A "$GEOUA" \
							-x "http://127.0.0.1:$_pp" "$_ccu" 2>/dev/null)")
					else
						_cc=$(_parse_cc "$(curl --max-time 5 -s \
							-x "http://127.0.0.1:$_pp" "$_ccu" 2>/dev/null)")
					fi
					[ -n "$_cc" ] && printf '%s' "$_cc" > "$GEOCC" 2>/dev/null
				fi
			fi
		) >/dev/null 2>&1 </dev/null &
		PUB=""; CC=""

		if [ "$URL" = internetometer ] || [ "$UPURL" = internetometer ]; then
			_yp=$(curl -A 5gmodem-speedtest -s --connect-timeout 5 --max-time 8 \
				"$YA_PROBES_URL" 2>/dev/null)
			_yd=$(printf '%s' "$_yp" | grep -oE "$YA_RE_DOWN" | head -1)
			_yu=$(printf '%s' "$_yp" | grep -oE "$YA_RE_UP" | grep -v 'timeout=' | head -1)
			if [ -z "$_yd" ] || [ -z "$_yu" ]; then
				logger -t 5gmodem "speedtest: Internetometer probes unavailable - falling back to $URL_FALLBACK"
				_yd=""; _yu=""
			fi
			if [ "$URL" = internetometer ]; then
				if [ -n "$_yd" ]; then
					URL="$_yd"
				else
					URL="$URL_FALLBACK"
					SERVICE=$(_service_name "$URL")
				fi
			fi
			if [ "$UPURL" = internetometer ]; then
				if [ -n "$_yu" ]; then UPURL="$_yu"; else UPURL="$UPURL_FALLBACK"; fi
			fi
			_yp=""
		fi

		_DL_T0=$(cut -d. -f1 /proc/uptime)
		(
			while :; do
				[ -f /tmp/5gmodem/st_stop ] && break
				_dl_left=$(( SECS - ($(cut -d. -f1 /proc/uptime) - _DL_T0) ))
				[ "$_dl_left" -ge 2 ] || break
				curl -A 5gmodem-speedtest -o /dev/null --max-time "$_dl_left" \
					--connect-timeout 8 -w '%{speed_download} %{http_code}\n' \
					"$URL" 2>>"$PROG" >>"$RESF"
			done
		) </dev/null &
		CPID=$!
		MAXD=0
		_PREVB=0; _PREVS=0; _LASTLIVE=0; _DONEN=0
		while kill -0 "$CPID" 2>/dev/null; do
			sleep 1
			_LINE=$(tr '\r' '\n' 2>/dev/null < "$PROG" | grep -E '^[ ]*[0-9]' | tail -1)
			_RECV=$(printf '%s' "$_LINE" | awk '{print $4}')
			_NDONE=$(wc -l < "$RESF" 2>/dev/null | tr -d ' ')
			case "$_NDONE" in ''|*[!0-9]*) _NDONE="$_DONEN" ;; esac
			_NOWT=$(cut -d. -f1 /proc/uptime)
			LIVE=""
			if [ -n "$_RECV" ]; then
				_NOWB=$(_tobytes "$_RECV")
				_SP=$(_spent "$_LINE")
				case "$_NOWB" in
					''|*[!0-9]*) : ;;
					*) if [ "$_NDONE" != "$_DONEN" ] || [ "$_NOWB" -lt "$_PREVB" ] || [ "$_SP" -lt "$_PREVS" ]; then
						_DONEN="$_NDONE"
						_PREVB="$_NOWB"; _PREVS="$_SP"
						LIVE="$_LASTLIVE"
					   else
						_DS=$(( _SP - _PREVS ))
						if [ "$_DS" -ge 1 ] && [ "$_NOWB" -ge "$_PREVB" ]; then
							LIVE=$(awk "BEGIN{printf \"%.1f\", (($_NOWB-$_PREVB)*8)/1000000/$_DS}")
							_PREVB="$_NOWB"; _PREVS="$_SP"
						else
							LIVE="$_LASTLIVE"
						fi
					   fi ;;
				esac
			fi
			if [ -z "$LIVE" ]; then
				CUR=$(printf '%s' "$_LINE" | awk '{print $NF}')
				[ -n "$CUR" ] || CUR=0
				LIVE=$(_tombps "$CUR")
			fi
			case "$LIVE" in
				0|0.0) [ "$(awk "BEGIN{print ($MAXD+0>0)?1:0}")" = 1 ] && LIVE="$_LASTLIVE" ;;
				*) _LASTLIVE="$LIVE" ;;
			esac
			LIVE=$(_num "$LIVE"); MAXD=$(_num "$MAXD")
			MAXD=$(awk "BEGIN{m=$MAXD+0;v=$LIVE+0;printf \"%.1f\",(v>m)?v:m}")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"live_down\":${LIVE:-0},\"secs\":$SECS,\"elapsed\":$(( _NOWT - _DL_T0 )),\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$CPID" 2>/dev/null
		SPD=$(_num "$(awk '{v=$1+0; if (v>m) m=v} END{printf "%.0f", m+0}' "$RESF")")
		HTTP=$(awk '{c=$2; if (c==200 || c==206) ok=c} END{print (ok!="")?ok:c}' "$RESF")
		AVGD=$(awk "BEGIN{printf \"%.1f\", ($SPD*8)/1000000}")
		AVGD=$(_num "$AVGD"); MAXD=$(_num "$MAXD")
		DMBPS=$(_num "$(awk "BEGIN{printf \"%.1f\", ($MAXD>0)?$MAXD:$AVGD}")")
		rm -f "$PROG" "$RESF"

		if [ -f /tmp/5gmodem/st_stop ]; then
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			rm -f "$GEOIP" "$GEOCC" "$GEOLOC" /tmp/5gmodem/st_stop
			_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ts\":$(date +%s 2>/dev/null)}"
			exit 0
		fi

		UPROG="/tmp/5gmodem/st_uprog.$$"; URES="/tmp/5gmodem/st_ures.$$"
		: > "$UPROG"; : > "$URES"
		(
			_up_t0=$(cut -d. -f1 /proc/uptime)
			_up_sz=262144; _up_n=1
			while :; do
				[ -f /tmp/5gmodem/st_stop ] && break
				_up_now=$(cut -d. -f1 /proc/uptime)
				_up_left=$(( SECS - (_up_now - _up_t0) ))
				[ "$_up_left" -ge 2 ] || break
				set --
				_up_i=0
				while [ "$_up_i" -lt "$_up_n" ]; do
					set -- "$@" -o /dev/null "$UPURL"
					_up_i=$((_up_i + 1))
				done
				head -c "$_up_sz" /dev/zero 2>/dev/null | curl -A 5gmodem-speedtest \
					--max-time "$_up_left" --connect-timeout 6 -H 'Expect:' \
					--data-binary @- \
					-w "$_up_sz"' %{size_upload} %{time_total} %{time_pretransfer} %{http_code}\n' \
					"$@" 2>/dev/null >>"$URES"
				_up_bps=$(_up_rates "$URES" | awk '{v=$1} END{printf "%.0f", v+0}')
				case "$_up_bps" in
					''|0|*[!0-9]*)
						[ "$(wc -l < "$URES" 2>/dev/null | tr -d ' ')" -ge 3 ] 2>/dev/null && break
						sleep 1
						_up_sz=262144; _up_n=1 ;;
					*)
						_up_sz=$(awk "BEGIN{v=$_up_bps*2; if (v<262144) v=262144; if (v>8388608) v=8388608; printf \"%.0f\", v}")
						_up_n=3 ;;
				esac
			done
		) </dev/null &
		UPID=$!
		UPT0=$(cut -d. -f1 /proc/uptime)
		MAXU=0
		LIVEU=0
		while kill -0 "$UPID" 2>/dev/null; do
			sleep 1
			_up_el=$(( $(cut -d. -f1 /proc/uptime) - UPT0 ))
			if [ "$_up_el" -gt $(( SECS + 2 )) ]; then
				kill $(pgrep -f 5gmodem-speedtest) 2>/dev/null
			fi
			_upl=$(_up_rates "$URES" | awk '{v=$1; if (v>m) m=v} END{printf "%.1f %.1f", (v*8)/1000000, (m*8)/1000000}')
			LIVEU=$(_num "${_upl%% *}"); MAXU=$(_num "${_upl##* }")
			[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
			[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
			[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
			_write "{\"running\":1,\"service\":\"$SERVICE\",\"phase\":\"up\",\"down_mbps\":$DMBPS,\"live_up\":${LIVEU:-0},\"secs\":$SECS,\"elapsed\":$_up_el,\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\"}"
		done
		wait "$UPID" 2>/dev/null
		MAXU=$(_num "$(_up_rates "$URES" | awk '{v=$1; if (v>m) m=v} END{printf "%.1f", (m*8)/1000000}')")
		UERR=""
		if [ "$(awk "BEGIN{print ($MAXU>0)?1:0}")" != 1 ]; then
			UERR=$(awk '$5+0>0 {c=$5} END{print (c!="")?"http-" c:"no-answer"}' "$URES" 2>/dev/null)
			[ -n "$UERR" ] || UERR="no-answer"
		fi
		rm -f "$UPROG" "$URES"
		[ -n "$PUB" ] || PUB=$(cat "$GEOIP" 2>/dev/null)
		[ -n "$CC" ]  || CC=$(cat "$GEOCC" 2>/dev/null)
		[ -n "$IPLOC" ] || IPLOC=$(cat "$GEOLOC" 2>/dev/null)
		rm -f "$GEOIP" "$GEOCC" "$GEOLOC"
		UMBPS=""
		[ -z "$UERR" ] && UMBPS="$MAXU"

		case "$HTTP" in
			200|206)
				_write "{\"running\":0,\"ok\":1,\"service\":\"$SERVICE\",\"down_mbps\":$DMBPS,\"up_mbps\":${UMBPS:-null},\"up_error\":\"$UERR\",\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ip_local\":${IPLOC:-0},\"ts\":$(date +%s 2>/dev/null)}"
				;;
			*)
				_write "{\"running\":0,\"ok\":0,\"service\":\"$SERVICE\",\"http\":\"$HTTP\",\"up_mbps\":${UMBPS:-null},\"up_error\":\"$UERR\",\"pub_ip\":\"${PUB}\",\"cc\":\"${CC}\",\"ip_local\":${IPLOC:-0},\"ts\":$(date +%s 2>/dev/null)}"
				;;
		esac
	) >/dev/null 2>&1 </dev/null &

	echo "{\"running\":1,\"service\":\"$SERVICE\"}"
	sleep 1
	;;
status)
	if [ -s "$CACHE" ] && ! jsonfilter -i "$CACHE" -e '@' >/dev/null 2>&1; then
		rm -f "$CACHE" 2>/dev/null
	fi
	if [ -f "$CACHE" ]; then
		cat "$CACHE"
	else
		echo "{\"running\":0,\"ok\":0,\"service\":\"$(_service_name)\"}"
	fi
	;;
stop)
	touch /tmp/5gmodem/st_stop 2>/dev/null
	kill $(pgrep -f 5gmodem-speedtest) 2>/dev/null
	sleep 1
	grep -q '"running":1' "$CACHE" 2>/dev/null && \
		_write "{\"running\":0,\"ok\":0,\"cancelled\":1,\"service\":\"$(_service_name)\",\"ts\":$(date +%s 2>/dev/null)}"
	echo '{"running":0,"cancelled":1}'
	;;
*)
	echo '{"error":"usage: speedtest.sh start|status|stop"}'
	;;
esac
exit 0
