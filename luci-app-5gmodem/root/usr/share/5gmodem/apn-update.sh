#!/bin/sh

RES=/usr/share/5gmodem
DB=/etc/5gmodem/providers.tsv
DB_PKG="$RES/providers.tsv"
URL=$(uci -q get 5gmodem.@5gmodem[0].apn_db_url)
[ -n "$URL" ] || URL="https://raw.githubusercontent.com/DarthAnwalt/openwrt-apn-autoconfig/main/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"

_tmp="/tmp/5gmodem/providers.$$"

. /usr/share/5gmodem/lib.sh 2>/dev/null
_fetch() {
	net_fetch 10 "$URL" "$_tmp"
}

_valid() {
	[ -s "$1" ] || return 1
	_n=$(awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$1")
	[ "$_n" -ge 500 ]
}

_count() { awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$1" 2>/dev/null; }

_ver() { sed -n 's/^# *database-version: *//p' "$1" 2>/dev/null | head -1 | tr -d '"\\[:cntrl:]'; }

case "${1:-check}" in
	version)
		_cur_db="$DB"; [ -s "$_cur_db" ] || _cur_db="$DB_PKG"
		printf '{"ok":true,"version":"%s","count":%s}\n' "$(_ver "$_cur_db")" "$(_count "$_cur_db")"
		;;
	check)
		_fetch || { echo '{"ok":false,"error":"no downloader / network"}'; exit 0; }
		if _valid "$_tmp"; then
			_cur_db="$DB"; [ -s "$_cur_db" ] || _cur_db="$DB_PKG"
			_new=$(_count "$_tmp"); _cur=$(_count "$_cur_db")
			_nv=$(_ver "$_tmp");   _cv=$(_ver "$_cur_db")
			_upd=0
			[ -n "$_nv" ] && [ "$_nv" != "$_cv" ] && _upd=1
			[ "$_new" != "$_cur" ] && _upd=1
			printf '{"ok":true,"current":%s,"available":%s,"current_version":"%s","available_version":"%s","update_available":%s}\n' \
				"${_cur:-0}" "$_new" "$_cv" "$_nv" "$_upd"
		else
			echo '{"ok":false,"error":"downloaded file invalid"}'
		fi
		rm -f "$_tmp"
		;;
	update)
		_fetch || { echo '{"ok":false,"error":"download failed"}'; exit 0; }
		if _valid "$_tmp"; then
			mkdir -p /etc/5gmodem 2>/dev/null
			mv "$_tmp" "$DB"
			_n=$(_count "$DB"); _v=$(_ver "$DB")
			logger -t 5gmodem "APN database updated: $_n operators, version ${_v:-?}"
			printf '{"ok":true,"count":%s,"version":"%s"}\n' "$_n" "$_v"
		else
			rm -f "$_tmp"
			echo '{"ok":false,"error":"downloaded file invalid"}'
		fi
		;;
	*)
		echo '{"ok":false,"error":"usage: apn-update.sh version|check|update"}'
		;;
esac
exit 0
