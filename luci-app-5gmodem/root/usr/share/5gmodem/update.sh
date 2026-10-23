#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null

REPO="fildunsky/luci-app-5gmodem"
API="https://api.github.com/repos/$REPO/releases/latest"
PAGE="https://github.com/$REPO/releases/latest"
PKG_FULL="luci-app-5gmodem"
PKG_LITE="luci-app-5gmodem-lite"
PKG="$PKG_FULL"
I18N="luci-i18n-5gmodem-ru"
TMP=/tmp/5gmodem
STATUS=/tmp/5gmodem/update.json
LOCK=/tmp/5gmodem/update.pid

json_esc() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pkgman() {
	command -v apk >/dev/null 2>&1 && { echo apk; return; }
	command -v opkg >/dev/null 2>&1 && { echo opkg; return; }
	echo ""
}

detect_pkg() {
	case "$1" in
	apk)
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

api_json() { net_fetch 15 "$API"; }

latest_tag() {
	api_json | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

asset_url() {
	api_json | sed -n 's|.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*/'"$1"'[-_][0-9][^"]*\.'"$2"'\)".*|\1|p' | head -n1
}

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
version)
	PM=$(pkgman)
	PKG=$(detect_pkg "$PM")
	printf '{"current":"%s"}\n' "$(json_esc "$(installed_version "$PM")")"
	;;

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
	printf '{"success":true,"pm":"%s","package":"%s","variant":"%s","current":"%s","latest":"%s","update_available":%s,"release_url":"%s"}\n' \
		"$PM" "$PKG" "$([ "$PKG" = "$PKG_LITE" ] && echo lite || echo full)" \
		"$(json_esc "$CUR")" "$(json_esc "$LAT")" "$AVAIL" "$PAGE"
	;;

install)
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		echo '{"started":true,"already":true}'
		exit 0
	fi
	rm -f "$STATUS" "$STATUS.tmp"
	echo '{"running":true}' > "$STATUS"
	echo '{"started":true}'
	(
		do_install() {
			PM=$(pkgman)
			[ -n "$PM" ] || { echo '{"success":false,"error":"No package manager found"}'; return; }
			PKG=$(detect_pkg "$PM")
			case "$PM" in apk) EXT=apk ;; opkg) EXT=ipk ;; esac

			PREV=$(installed_version "$PM")

			INSTALLED=""
			for BASE in "$PKG"; do
				URL=$(asset_url "$BASE" "$EXT")
				if [ -z "$URL" ]; then
					echo '{"success":false,"error":"asset_pending"}'; return
				fi
				F="$TMP/$BASE.$EXT"
				rm -f "$F"
				if ! net_fetch 90 "$URL" "$F"; then
					echo '{"success":false,"error":"Download failed for '"$BASE"'"}'; return
				fi
				_want=$(basename "$URL" | sed -n 's/^.*[-_]\([0-9][0-9.]*\)-r[0-9][0-9]*[._].*$/\1/p')
				if [ "$PM" = apk ]; then
					apk add --allow-untrusted "$F" >/dev/null 2>&1; _rc=$?
				else
					opkg install --force-reinstall "$F" >/dev/null 2>&1; _rc=$?
				fi
				if [ "$_rc" != 0 ]; then
					if [ -n "$_want" ] && [ "$(installed_version "$PM")" = "$_want" ]; then
						logger -t 5gmodem "update: $PM returned $_rc, but $BASE $_want is installed - treating as success"
					else
						rm -f "$F"; echo '{"success":false,"error":"Install failed for '"$BASE"'"}'; return
					fi
				fi
				rm -f "$F"
				INSTALLED="$INSTALLED $BASE"
			done

			case "$PM" in
				apk)  apk del "$I18N" >/dev/null 2>&1 ;;
				opkg) opkg remove "$I18N" >/dev/null 2>&1 ;;
			esac
			for _lmo in /usr/share/5gmodem/i18n/5gmodem.*.lmo; do
				[ -f "$_lmo" ] && cp "$_lmo" /usr/lib/lua/luci/i18n/ 2>/dev/null
			done

			rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
			CUR=$(installed_version "$PM")
			if [ -n "$PREV" ] && [ "$CUR" = "$PREV" ]; then
				_up_lat=$(latest_tag); _up_lat=${_up_lat#v}
				if [ -n "$_up_lat" ] && [ "$_up_lat" = "$CUR" ]; then
					printf '{"success":true,"installed":"%s","current":"%s","reinstalled":1}\n' \
						"$(json_esc "$(echo $INSTALLED)")" "$(json_esc "$CUR")"
					return
				fi
				printf '{"success":false,"current":"%s","error":"Reinstalled but version stayed %s - the release asset looks mispackaged (rebuild/reupload it)"}\n' "$(json_esc "$CUR")" "$(json_esc "$CUR")"
			else
				printf '{"success":true,"installed":"%s","current":"%s"}\n' "$(json_esc "$(echo $INSTALLED)")" "$(json_esc "$CUR")"
			fi
		}
		# $$ is the parent here, see docs/subsystems/misc.md#updatesh
		read -r _upid _ < /proc/self/stat 2>/dev/null
		echo "$_upid" > "$LOCK" 2>/dev/null
		do_install > "$STATUS.tmp" 2>/dev/null
		mv "$STATUS.tmp" "$STATUS"
		rm -f "$LOCK"
	) >/dev/null 2>&1 </dev/null &
	# see docs/subsystems/misc.md#updatesh (rpcd loses fast exit with a background child)
	sleep 1
	exit 0
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
