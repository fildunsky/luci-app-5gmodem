#!/bin/sh
#
# Check for / install the latest luci-app-5gmodem release from GitHub.
# Installs BOTH the app and its translation package (if a matching asset
# exists). Prints a small JSON object.
#
# Usage:
#   update.sh check     - compare installed vs latest release
#   update.sh install   - download + install app (+ translation)
#

REPO="fildunsky/luci-app-5gmodem"
API="https://api.github.com/repos/$REPO/releases/latest"
PAGE="https://github.com/$REPO/releases/latest"
PKG_FULL="luci-app-5gmodem"
PKG_LITE="luci-app-5gmodem-lite"
# Имя выбирается по факту установки (см. detect_pkg). Значение по умолчанию
# нужно на случай, когда пакет не установлен вовсе.
PKG="$PKG_FULL"
I18N="luci-i18n-5gmodem-ru"
TMP=/tmp
STATUS=/tmp/5gmodem_update.json

json_esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pkgman() {
	command -v apk >/dev/null 2>&1 && { echo apk; return; }
	command -v opkg >/dev/null 2>&1 && { echo opkg; return; }
	echo ""
}

# КАКОЙ ВАРИАНТ УСТАНОВЛЕН.
#
# Пакетов два: полный и облегчённый (см. Makefile). Обновлять нужно ТЕМ ЖЕ
# вариантом, и это не косметика:
#   - полный на роутер с 8 МБ флеша просто не поместится;
#   - облегчённый на роутер с работающим QMI/MBIM-модемом снесёт qmi-utils и
#     modemmanager как осиротевшие, и связь пропадёт.
# Поэтому имя пакета определяем, а не предполагаем.
detect_pkg() {
	case "$1" in
	apk)
		# apk info печатает ЧИСТЫЕ имена, по одному на строку
		apk info 2>/dev/null | grep -qx "$PKG_LITE" && { echo "$PKG_LITE"; return; }
		;;
	opkg)
		opkg list-installed 2>/dev/null | grep -q "^$PKG_LITE " && { echo "$PKG_LITE"; return; }
		;;
	esac
	echo "$PKG_FULL"
}

installed_version() {
	case "$1" in
	apk)  apk info -v 2>/dev/null | sed -n "s/^$PKG-\([0-9][0-9.]*\)-r[0-9].*/\1/p" | head -n1 ;;
	opkg) opkg list-installed "$PKG" 2>/dev/null | sed -n "s/^$PKG - //p" | head -n1 ;;
	esac
}

api_json() { wget -qO- --timeout=15 "$API" 2>/dev/null; }

latest_tag() {
	api_json | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# asset_url <basename> <ext>  - browser_download_url of a matching asset.
# ВАЖНО: якоримся на ИМЯ ФАЙЛА ассета ('/<basename>-<цифра версии>...ext'), а НЕ
# на подстроку в любом месте URL. Иначе имя репозитория в пути
# (github.com/<user>/luci-app-5gmodem/releases/...) совпадает у КАЖДОГО ассета, и
# жадный .* в sed выбирал ПОСЛЕДНИЙ .apk (i18n-пакет, напр. zh-tw). Установка
# i18n не меняла версию главного пакета -> ложное «версия осталась 1.2.3».
asset_url() {
	# разделитель имя-версия: apk = '-' (luci-app-5gmodem-1.2.5), ipk = '_'
	# (luci-app-5gmodem_1.2.5) -> допускаем оба через [-_].
	api_json | sed -n 's|.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*/'"$1"'[-_][0-9][^"]*\.'"$2"'\)".*|\1|p' | head -n1
}

# version_gt <a> <b>  - prints 1 if a > b else 0 (numeric, dot-separated)
version_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN{
		n=split(a,x,"."); m=split(b,y,".");
		k=(n>m)?n:m;
		for(i=1;i<=k;i++){ai=(i<=n)?x[i]+0:0; bi=(i<=m)?y[i]+0:0;
			if(ai>bi){print 1; exit} if(ai<bi){print 0; exit}}
		print 0
	}'
}

case "$1" in
check)
	PM=$(pkgman)
	PKG=$(detect_pkg "$PM")
	CUR=$(installed_version "$PM")
	LAT=$(latest_tag)
	LATV=${LAT#v}
	AVAIL=0
	if [ -n "$LATV" ] && [ -n "$CUR" ]; then
		AVAIL=$(version_gt "$LATV" "$CUR")
	elif [ -n "$LATV" ] && [ -z "$CUR" ]; then
		AVAIL=1
	fi
	if [ -z "$LAT" ]; then
		printf '{"success":false,"error":"Could not reach GitHub","pm":"%s","current":"%s"}\n' "$PM" "$(json_esc "$CUR")"
		exit 0
	fi
	# variant отдаём наружу: интерфейс показывает, какой пакет стоит, и человек
	# видит, ЧЕМ именно он обновится.
	printf '{"success":true,"pm":"%s","package":"%s","variant":"%s","current":"%s","latest":"%s","update_available":%s,"release_url":"%s"}\n' \
		"$PM" "$PKG" "$([ "$PKG" = "$PKG_LITE" ] && echo lite || echo full)" \
		"$(json_esc "$CUR")" "$(json_esc "$LAT")" "$AVAIL" "$PAGE"
	;;

install)
	# The download + install of two packages over a modem link can take longer
	# than the LuCI RPC/XHR timeout, so we run it in the background, write the
	# result to a status file, and let the UI poll 'update.sh status'.
	rm -f "$STATUS" "$STATUS.tmp"
	echo '{"started":true}'
	(
		do_install() {
			PM=$(pkgman)
			[ -n "$PM" ] || { echo '{"success":false,"error":"No package manager found"}'; return; }
			# Тот же вариант, что уже стоит: подмена полного на облегчённый (и
			# наоборот) сломала бы роутер - см. detect_pkg.
			PKG=$(detect_pkg "$PM")
			case "$PM" in apk) EXT=apk ;; opkg) EXT=ipk ;; esac

			PREV=$(installed_version "$PM")

			# The Russian translation is now BUNDLED into the main package (its .lmo
			# is deployed by the package's postinst), so it is no longer downloaded
			# here. Other languages stay as separate packages, unaffected.
			INSTALLED=""
			for BASE in "$PKG"; do
				URL=$(asset_url "$BASE" "$EXT")
				if [ -z "$URL" ]; then
					echo '{"success":false,"error":"Release asset for '"$BASE"' not found"}'; return
				fi
				F="$TMP/$BASE.$EXT"
				rm -f "$F"
				if ! wget -qO "$F" --timeout=90 "$URL" 2>/dev/null; then
					echo '{"success":false,"error":"Download failed for '"$BASE"'"}'; return
				fi
				if [ "$PM" = apk ]; then
					apk add --allow-untrusted "$F" >/dev/null 2>&1 || { rm -f "$F"; echo '{"success":false,"error":"Install failed for '"$BASE"'"}'; return; }
				else
					opkg install --force-reinstall "$F" >/dev/null 2>&1 || { rm -f "$F"; echo '{"success":false,"error":"Install failed for '"$BASE"'"}'; return; }
				fi
				rm -f "$F"
				INSTALLED="$INSTALLED $BASE"
			done

			# Retire the obsolete standalone luci-i18n-5gmodem-ru left over from
			# older installs (the app now carries the Russian .lmo itself). Best
			# effort - a no-op if it isn't installed. Removing it also deletes the
			# .lmo it used to own, so re-deploy the bundled copy right after.
			case "$PM" in
				apk)  apk del "$I18N" >/dev/null 2>&1 ;;
				opkg) opkg remove "$I18N" >/dev/null 2>&1 ;;
			esac
			[ -f /usr/share/5gmodem/i18n/5gmodem.ru.lmo ] && \
				cp /usr/share/5gmodem/i18n/5gmodem.ru.lmo \
					/usr/lib/lua/luci/i18n/5gmodem.ru.lmo 2>/dev/null

			rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
			CUR=$(installed_version "$PM")
			# Verify the version actually changed. opkg/apk return 0 even when the
			# downloaded package has the SAME version as installed (e.g. a release
			# whose asset was built/labelled with an OLD version) - which used to
			# report a silent "success" while nothing changed. Surface that.
			if [ -n "$PREV" ] && [ "$CUR" = "$PREV" ]; then
				printf '{"success":false,"current":"%s","error":"Reinstalled but version stayed %s - the release asset looks mispackaged (rebuild/reupload it)"}\n' "$(json_esc "$CUR")" "$(json_esc "$CUR")"
			else
				printf '{"success":true,"installed":"%s","current":"%s"}\n' "$(json_esc "$(echo $INSTALLED)")" "$(json_esc "$CUR")"
			fi
		}
		# write to a temp file and move into place only when done, so
		# 'status' can tell "running" (no final file yet) from "finished"
		do_install > "$STATUS.tmp" 2>/dev/null
		mv "$STATUS.tmp" "$STATUS"
	) >/dev/null 2>&1 &
	;;

status)
	if [ -s "$STATUS" ]; then
		cat "$STATUS"
	else
		echo '{"running":true}'
	fi
	;;

*)
	echo '{"success":false,"error":"usage: update.sh check|install|status"}'
	exit 1
	;;
esac
