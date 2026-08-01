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
# КУДА ПИШЕМ СКАЧАННОЕ - В /etc, А НЕ ПОВЕРХ ПАКЕТНОГО ФАЙЛА. /usr/share
# принадлежит менеджеру пакетов: обновление приложения вернуло бы туда снимок
# на день сборки, и свежая база, которую человек скачал кнопкой, молча пропала
# бы (та же ловушка, что с путём для статистики и списком сетей Telegram).
# Читатели (apn_pick в msw/apn.sh) предпочитают /etc, если он есть.
DB=/etc/5gmodem/providers.tsv
DB_PKG="$RES/providers.tsv"
URL=$(uci -q get 5gmodem.@5gmodem[0].apn_db_url)
# Владелец репозитория переименовался (Dark-Sky-Ranger -> DarthAnwalt), и старый
# адрес отдаёт 404: обновление базы молча не работало у ВСЕХ - скрипт честно
# писал «download failed», но зовут его только руками, и увидеть это было негде.
[ -n "$URL" ] || URL="https://raw.githubusercontent.com/DarthAnwalt/openwrt-apn-autoconfig/main/apn-autoconfig-providers/files/usr/share/apn-autoconfig/providers.tsv"

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

_count() { awk -F '\t' '!/^[[:space:]]*#/ && NF>=8 {c++} END {print c+0}' "$1" 2>/dev/null; }

# Дата сборки базы - строкой в её шапке («# database-version: 2026.07.27»).
# Число операторов между версиями меняется на единицы, и сравнивать по нему
# бессмысленно: свежая база с тем же счётом выглядела бы как «обновлений нет».
_ver() { sed -n 's/^# *database-version: *//p' "$1" 2>/dev/null | head -1; }

# Число само по себе ни о чём не говорит - его показывает только версия.
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
			logger -t 5gmodem "база APN обновлена: $_n операторов, версия ${_v:-?}"
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
