#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

PORT="$1"
RESULT="$2"
CABUNDLE="$3"
LIVELOG="$4"
: > "$RESULT"
CH=""

hex2bin() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')" > "$2"; }
bin2hex() { hexdump -v -e '/1 "%02x"' "$1" 2>/dev/null; }

_GNUWGET=""
wget --version 2>/dev/null | head -1 | grep -q "GNU Wget" && _GNUWGET=1
if [ -z "$_GNUWGET" ] && [ -n "$LIVELOG" ]; then
	if command -v curl >/dev/null 2>&1; then
		_wnote="GNU wget (wget-ssl) not found, using curl for HTTP; if SM-DP+ fails over TLS, install wget-ssl"
	else
		_wnote="neither GNU wget (wget-ssl) nor curl found, SM-DP+ is unreachable; install wget-ssl"
	fi
	printf '%s {"type":"httpx","payload":{"note":"%s"}}\n' \
		"$(date '+%H:%M:%S' 2>/dev/null)" "$_wnote" >> "$LIVELOG" 2>/dev/null
fi

_http_go() {
	_hg_b="$1"; _hg_h="$2"; _hg_ins="$3"; shift 3
	_hg_n=$#
	while [ "$_hg_n" -gt 0 ]; do
		if [ -n "$_GNUWGET" ]; then set -- "$@" "--header=$1"; else set -- "$@" -H "$1"; fi
		shift
		_hg_n=$((_hg_n - 1))
	done
	if [ -n "$_GNUWGET" ]; then
		[ -n "$CABUNDLE" ] && set -- "$@" "--ca-certificate=$CABUNDLE"
		[ -n "$_hg_ins" ] && set -- "$@" --no-check-certificate
		[ -s "$_rq" ] && set -- "$@" --method=POST "--body-file=$_rq"
		wget -nv -S -O "$_hg_b" --content-on-error --timeout=60 --tries=1 \
			--no-http-keep-alive --header="Connection: close" \
			"$@" "$url" 2>"$_hg_h"
	else
		[ -n "$CABUNDLE" ] && set -- "$@" --cacert "$CABUNDLE"
		[ -n "$_hg_ins" ] && set -- "$@" -k
		[ -s "$_rq" ] && set -- "$@" --data-binary "@$_rq"
		curl -sS -D "$_hg_h" -o "$_hg_b" --max-time 60 -H "Connection: close" \
			"$@" "$url" 2>>"$_hg_h"
	fi
}

while IFS= read -r line; do
	[ -n "$line" ] || continue
	case "$line" in
		*'"type":"apdu"'*) : ;;
		*'"type":"http"'*)
			url=$(printf '%s' "$line" | jsonfilter -e '@.payload.url' 2>/dev/null)
			tx=$(printf '%s' "$line" | jsonfilter -e '@.payload.tx' 2>/dev/null)
			_rq="/tmp/5gmodem/esim_hreq.$$"
			_rb="/tmp/5gmodem/esim_hbody.$$"
			_rh="/tmp/5gmodem/esim_hhdr.$$"
			set --
			_oldifs="$IFS"; IFS='
'
			for _h in $(printf '%s' "$line" | jsonfilter -e '@.payload.headers[*]' 2>/dev/null); do
				[ -n "$_h" ] && set -- "$@" "$_h"
			done
			IFS="$_oldifs"
			rm -f "$_rq"
			[ -n "$tx" ] && hex2bin "$tx" "$_rq"
			_http_go "$_rb" "$_rh" "" "$@"
			rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			if [ -z "$rcode" ] && grep -qi "certificate\|issuer" "$_rh" 2>/dev/null; then
				_http_go "$_rb" "$_rh" 1 "$@"
				rcode=$(sed -n 's|^ *HTTP/[0-9.]* \([0-9][0-9]*\).*|\1|p' "$_rh" | tail -1)
			fi
			if [ -z "$rcode" ]; then
				_why=$(grep -iE 'failed|error|unable|refused|timed|denied|certificate|resolve' "$_rh" 2>/dev/null \
					| grep -vE '^ *--|^ *-[a-zA-Z], ' \
					| tail -2 | tr '\n' ' ' | tr -d '\r')
				[ -n "$_why" ] || _why="transport did not answer (DNS/TLS/timeout)"
				[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","transport":"failed","why":"%s"}}\n' \
					"$(date '+%H:%M:%S' 2>/dev/null)" "$url" "$(printf '%s' "$_why" | tr '"' "'")" >> "$LIVELOG"
			else
				if [ -s "$_rb" ] && [ "$(hexdump -v -n 2 -e '/1 "%02x"' "$_rb" 2>/dev/null)" = "1f8b" ]; then
					if gzip -dc "$_rb" > "$_rb.un" 2>/dev/null && [ -s "$_rb.un" ]; then
						mv "$_rb.un" "$_rb"
						[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","note":"gzip decoded"}}\n' \
							"$(date '+%H:%M:%S' 2>/dev/null)" "$url" >> "$LIVELOG"
					fi
					rm -f "$_rb.un"
				fi
				_bh=$(hexdump -v -n 16 -e '/1 "%02x"' "$_rb" 2>/dev/null)
				_bj=0; [ "$(cut -c1 "$_rb" 2>/dev/null)" = "{" ] && _bj=1
				_bt=$(tail -c 1 "$_rb" 2>/dev/null)
				_btr=0; [ "$_bj" = 1 ] && [ "$_bt" != "}" ] && _btr=1
				[ -n "$LIVELOG" ] && printf '%s {"type":"httpx","payload":{"url":"%s","rcode":%s,"bytes":%s,"json":%s,"truncated":%s,"head":"%s"}}\n' \
					"$(date '+%H:%M:%S' 2>/dev/null)" "$url" "$rcode" "$(wc -c 2>/dev/null < "$_rb" || echo 0)" "$_bj" "$_btr" "$_bh" >> "$LIVELOG"
			fi
			[ -n "$rcode" ] || rcode=500
			if [ ! -s "$RESULT.es9err" ] && [ -s "$_rb" ] \
			   && grep -q '"statusCodeData"\|"status" *: *"Failed"\|"reasonCode"' "$_rb" 2>/dev/null; then
				cat "$_rb" > "$RESULT.es9err"
			fi
			printf '{"type":"http","payload":{"rcode":%s,"rx":"%s"}}\n' \
				"$rcode" "$(bin2hex "$_rb")"
			rm -f "$_rq" "$_rb" "$_rh"
			continue ;;
		*)
			printf '%s\n' "$line" >> "$RESULT"
			[ -n "$LIVELOG" ] && printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$line" >> "$LIVELOG"
			case "$line" in *'"type":"lpa"'*) exit 0 ;; esac
			continue ;;
	esac
	func=$(printf '%s' "$line" | jsonfilter -e '@.payload.func' 2>/dev/null)
	param=$(printf '%s' "$line" | jsonfilter -e '@.payload.param' 2>/dev/null)
	case "$func" in
	logic_channel_open)
		r=$(sms_tool -d "$PORT" at "AT+CCHO=\"$param\"" 2>/dev/null | tr -d '\r')
		c=$(printf '%s' "$r" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
		[ -n "$c" ] || c=$(printf '%s' "$r" | grep -E '^[0-9]+$' | head -1)
		if [ -z "$c" ]; then
			for _co in 1 2 3 4; do sms_tool -d "$PORT" at "AT+CCHC=$_co" >/dev/null 2>&1; done
			sleep 1
			r=$(sms_tool -d "$PORT" at "AT+CCHO=\"$param\"" 2>/dev/null | tr -d '\r')
			c=$(printf '%s' "$r" | sed -n 's/^+CCHO: *\([0-9][0-9]*\).*/\1/p' | head -1)
			[ -n "$c" ] || c=$(printf '%s' "$r" | grep -E '^[0-9]+$' | head -1)
			[ -n "$LIVELOG" ] && printf '%s TRACE CCHO retry after closing channels -> ch=%s\n' \
				"$(date '+%H:%M:%S' 2>/dev/null)" "${c:--1}" >> "$LIVELOG"
		fi
		CH="$c"
		[ -n "$LIVELOG" ] && printf '%s TRACE CCHO aid=%.40s ch=%s\n' \
			"$(date '+%H:%M:%S' 2>/dev/null)" "$param" "${c:--1}" >> "$LIVELOG"
		printf '{"type":"apdu","payload":{"ecode":%s}}\n' "${c:--1}" ;;
	logic_channel_close)
		cc=$(printf '%d' "0x$param" 2>/dev/null)
		[ -n "$cc" ] && sms_tool -d "$PORT" at "AT+CCHC=$cc" >/dev/null 2>&1
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	transmit)
		# see docs/subsystems/esim.md#cgla-length-is-in-hex-characters
		_cgla_out=$(sms_tool -d "$PORT" at "AT+CGLA=$CH,${#param},\"$param\"" 2>/dev/null | tr -d '\r')
		out=$(printf '%s' "$_cgla_out" | sed -n 's/.*+CGLA: *[0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p' | head -1)
		if [ -z "$out" ]; then
			sleep 1
			_cgla_out=$(sms_tool -d "$PORT" at "AT+CGLA=$CH,${#param},\"$param\"" 2>/dev/null | tr -d '\r')
			out=$(printf '%s' "$_cgla_out" | sed -n 's/.*+CGLA: *[0-9]*,"\([0-9A-Fa-f]*\)".*/\1/p' | head -1)
		fi
		[ -n "$LIVELOG" ] && printf '%s TRACE CGLA ch=%s len=%s apdu_head=%.40s ret=%.40s raw=%s\n' \
			"$(date '+%H:%M:%S' 2>/dev/null)" "$CH" "${#param}" "$param" "$out" \
			"$(printf '%s' "$_cgla_out" | tr '\n' ' ')" >> "$LIVELOG"
		if [ -z "$out" ]; then
			[ -n "$LIVELOG" ] && printf '%s {"type":"apdux","payload":{"note":"chip did not answer APDU (channel %s, %s chars): port busy or modem re-enumerated"}}\n' \
				"$(date '+%H:%M:%S' 2>/dev/null)" "$CH" "${#param}" >> "$LIVELOG"
			printf '{"type":"apdu","payload":{"ecode":-1}}\n'
		else
			printf '{"type":"apdu","payload":{"ecode":0,"data":"%s"}}\n' "$out"
		fi ;;
	connect|disconnect|*)
		printf '{"type":"apdu","payload":{"ecode":0}}\n' ;;
	esac
done
