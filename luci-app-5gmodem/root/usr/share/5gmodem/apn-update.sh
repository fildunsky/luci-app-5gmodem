#!/bin/sh
#
# Обновление мировой базы APN (providers.tsv) из первоисточника.
#
#   apn-update.sh check   -> сравнить версию с сетевой, ничего не менять
#   apn-update.sh update  -> скачать свежую базу, проверить и заменить
#
# База генерируется из GNOME MBPI + AOSP (см. licenses/PROVIDERS-NOTICE.txt) и
# публикуется готовым TSV. Скачиваем ТОЛЬКО валидный файл и подменяем атомарно:
# оборванная закачка не должна оставить пользователя без работающей базы.
#
# URL настраивается: uci get 5gmodem.@5gmodem[0].apn_db_url. На роутерах с белым
# списком (только доверенные хосты) сюда можно вписать своё зеркало.

RES=/usr/share/5gmodem
DB="$RES/providers.tsv"
URL=$(uci -q get 5gmodem.@5gmodem[0].apn_db_url)
[ -n "$URL" ] || URL="https://raw.githubusercontent.com/Dark-Sky-Ranger/openwrt-apn-autoconfig/main/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"

_tmp="/tmp/5gmodem_providers.$$"

_fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 60 "$URL" -o "$_tmp" 2>/dev/null
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 60 -O "$_tmp" "$URL" 2>/dev/null
	else
		return 1
	fi
}

# Формально валидная база: есть строки-данные с >=8 TAB-полей и правдоподобным
# числом операторов. Так мусор (HTML-страница ошибки, обрезок) не подменит базу.
_valid() {
	[ -s "$1" ] || return 1
	_n=$(awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$1")
	[ "$_n" -ge 500 ]
}

case "${1:-check}" in
	check)
		_fetch || { echo '{"ok":false,"error":"no downloader / network"}'; exit 0; }
		if _valid "$_tmp"; then
			_new=$(awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$_tmp")
			_cur=$(awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$DB" 2>/dev/null)
			printf '{"ok":true,"current":%s,"available":%s}\n' "${_cur:-0}" "$_new"
		else
			echo '{"ok":false,"error":"downloaded file invalid"}'
		fi
		rm -f "$_tmp"
		;;
	update)
		_fetch || { echo '{"ok":false,"error":"download failed"}'; exit 0; }
		if _valid "$_tmp"; then
			mv "$_tmp" "$DB"
			_n=$(awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$DB")
			logger -t 5gmodem "база APN обновлена: $_n операторов"
			printf '{"ok":true,"count":%s}\n' "$_n"
		else
			rm -f "$_tmp"
			echo '{"ok":false,"error":"downloaded file invalid"}'
		fi
		;;
	*)
		echo '{"ok":false,"error":"usage: apn-update.sh check|update"}'
		;;
esac
exit 0
