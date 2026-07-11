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
PKG="luci-app-5gmodem"
I18N="luci-i18n-5gmodem-ru"
TMP=/tmp
STATUS=/tmp/5gmodem_update.json

json_esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pkgman() {
	command -v apk >/dev/null 2>&1 && { echo apk; return; }
	command -v opkg >/dev/null 2>&1 && { echo opkg; return; }
	echo ""
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

# asset_url <basename> <ext>  - browser_download_url of a matching asset
asset_url() {
	api_json | sed -n 's|.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*'"$1"'[^"]*\.'"$2"'\)".*|\1|p' | head -n1
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
	printf '{"success":true,"pm":"%s","current":"%s","latest":"%s","update_available":%s,"release_url":"%s"}\n' \
		"$PM" "$(json_esc "$CUR")" "$(json_esc "$LAT")" "$AVAIL" "$PAGE"
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
			case "$PM" in apk) EXT=apk ;; opkg) EXT=ipk ;; esac

			INSTALLED=""
			for BASE in "$PKG" "$I18N"; do
				URL=$(asset_url "$BASE" "$EXT")
				if [ -z "$URL" ]; then
					# the translation is optional; only the app is mandatory
					[ "$BASE" = "$I18N" ] && continue
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

			rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
			CUR=$(installed_version "$PM")
			printf '{"success":true,"installed":"%s","current":"%s"}\n' "$(json_esc "$(echo $INSTALLED)")" "$(json_esc "$CUR")"
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
