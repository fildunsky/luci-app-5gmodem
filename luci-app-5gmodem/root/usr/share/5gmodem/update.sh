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
APIC=/tmp/5gmodem/update-api.json
LOG=/tmp/5gmodem/update.log
STEP=/tmp/5gmodem/update.step

mkdir -p "$TMP" 2>/dev/null

run_install() {
	if command -v nice >/dev/null 2>&1; then
		nice -n 5 "$@"
	else
		"$@"
	fi
}

# apk downloads package lists with an external "wget" found through PATH. This stand-in sends
# them through the device chosen under "Download through" (curl --interface) and puts a hard
# limit on uclient-fetch, whose -T covers reads only: a connection that never opens hangs it.
apk_net() {
	_an_d="$TMP/pmfetch"
	mkdir -p "$_an_d" 2>/dev/null
	cat > "$_an_d/wget" <<'SHIM'
#!/bin/sh
# apk asks: wget -q -T <sec> <url> -O <file|->
t=60; o=-; u=""
while [ $# -gt 0 ]; do
	case "$1" in
		-T) t="$2"; shift ;;
		-O) o="$2"; shift ;;
		-*) ;;
		*) u="$1" ;;
	esac
	shift
done
case "$t" in ''|*[!0-9]*) t=60 ;; esac
[ -n "$u" ] || exit 1
if [ -n "$PM_FETCH_DEV" ] && [ -d "/sys/class/net/$PM_FETCH_DEV" ] && command -v curl >/dev/null 2>&1; then
	f="${TMPDIR:-/tmp}/pmfetch.$$"
	if curl -fsSL --connect-timeout 8 -m $((t * 5)) --interface "$PM_FETCH_DEV" -o "$f" "$u" 2>/dev/null; then
		if [ "$o" = - ]; then cat "$f"; rc=$?; rm -f "$f"; else mv -f "$f" "$o"; rc=$?; fi
		exit $rc
	fi
	rm -f "$f"
	logger -t 5gmodem "update: package list through $PM_FETCH_DEV failed - trying the default route"
fi
[ -n "$PM_REAL_WGET" ] || exit 1
"$PM_REAL_WGET" -q -T "$t" -O "$o" "$u" &
p=$!
( sleep $((t + 30)); kill "$p" ) >/dev/null 2>&1 </dev/null &
k=$!
wait "$p"; rc=$?
kill "$k" 2>/dev/null
exit $rc
SHIM
	chmod 755 "$_an_d/wget"
	_an_dev=$(uci -q get 5gmodem.@5gmodem[0].fetch_dev)
	case "$_an_dev" in *[!A-Za-z0-9._@-]*) _an_dev="" ;; esac
	_an_run=command
	[ "$1" = add ] && _an_run=run_install
	PM_REAL_WGET=$(command -v wget) PM_FETCH_DEV="$_an_dev" PATH="$_an_d:$PATH" "$_an_run" apk "$@"
}

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r' | tr '\n\t' '  '; }

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
	opkg) opkg list-installed "$PKG" 2>/dev/null | sed -n "s/^$PKG - \([0-9][0-9.]*\).*/\1/p" | head -n1 ;;
	esac
}

# version of the installed full or lite package straight from the apk/opkg database ("" if none)
fast_version() {
	_fv_db=""
	for _fv_db in "${UPD_APK_DB:-/lib/apk/db/installed}" "${UPD_OPKG_DB:-/usr/lib/opkg/status}"; do
		[ -r "$_fv_db" ] || continue
		awk -v a="$PKG_FULL" -v b="$PKG_LITE" '
			/^(P:|Package: )/ { sub(/^(P:|Package: )/, ""); p = $0; next }
			/^(V:|Version: )/ && (p == a || p == b) {
				sub(/^(V:|Version: )/, ""); sub(/-r[0-9]+$/, ""); sub(/-[0-9]+$/, "")
				if ($0 ~ /^[0-9][0-9.]*$/) { print; exit }
			}
			/^$/ { p = "" }' "$_fv_db"
		return
	done
}

api_json() {
	if [ "$1" != fresh ] && [ -s "$APIC" ] && [ -n "$(find "$APIC" -mmin -5 2>/dev/null)" ]; then
		cat "$APIC"; return 0
	fi
	if [ "$1" = fresh ]; then
		_aj=$(net_fetch 10 "$API" "" "" check) || return 1
	else
		_aj=$(net_fetch 15 "$API") || return 1
	fi
	printf '%s' "$_aj" | jsonfilter -e '@.tag_name' >/dev/null 2>&1 || return 1
	printf '%s' "$_aj" > "$APIC.tmp" && mv "$APIC.tmp" "$APIC"
	printf '%s' "$_aj"
}

asset_name() {
	printf '%s' "$1" | jsonfilter -e '@.assets[*].name' 2>/dev/null \
		| grep -E "^$2[-_][0-9][0-9.]*-r[0-9]+([-_.][a-z_]+)?\.$3\$" | head -n1
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

# Optional companions join the existing transaction only when already installed.
mtk_helper_version() {
	local packages
	case "$1" in
		apk)
			packages=$(apk info -v 2>/dev/null) || return 1
			printf '%s\n' "$packages" | sed -n 's/^5gmodem-mtk-at-\([0-9].*\)$/\1/p' | head -n1 ;;
		opkg)
			packages=$(opkg list-installed 2>/dev/null) || return 1
			printf '%s\n' "$packages" | sed -n 's/^5gmodem-mtk-at - \(.*\)$/\1/p' | head -n1 ;;
	esac
}

mtk_helper_newer() {
	awk -v target="$1" -v current="$2" 'BEGIN {
		split(target, t, "-r"); split(current, c, "-r")
		n=split(t[1], a, "."); m=split(c[1], b, ".")
		for (i=1; i<=n || i<=m; i++) {
			if (a[i]+0 > b[i]+0) exit 0
			if (a[i]+0 < b[i]+0) exit 1
		}
		exit !(t[2]+0 > c[2]+0)
	}'
}

mtk_helper_prepare() {
	local current manifest target sum size base
	MTK_FILE=""; MTK_TARGET=""; MTK_SIZE=0; MTK_SUM=""; MTK_URL=""
	current=$(mtk_helper_version "$PM") || {
		echo 'Could not read installed MediaTek helper status' >> "$LOG"; return 1
	}
	[ -n "$current" ] || return 0
	base="https://raw.githubusercontent.com/$REPO/master/dist/5gmodem-mtk-at"
	manifest=$(net_fetch 15 "$base/manifest.json") || {
		echo 'Could not fetch the MediaTek helper manifest' >> "$LOG"; return 1
	}
	target=$(printf '%s' "$manifest" | jsonfilter -e '@.version' 2>/dev/null)
	printf '%s\n' "$target" "$current" | grep -Eqv '^[0-9]+([.][0-9]+)*-r[0-9]+$' && {
		echo 'Invalid MediaTek helper version metadata' >> "$LOG"; return 1
	}
	mtk_helper_newer "$target" "$current" || return 0
	sum=$(printf '%s' "$manifest" | jsonfilter -e "@.packages[\"5gmodem-mtk-at.$EXT\"]" 2>/dev/null)
	printf '%s\n' "$sum" | grep -Eq '^[0-9a-f]{64}$' || {
		echo 'Missing MediaTek helper checksum' >> "$LOG"; return 1
	}
	size=$(printf '%s' "$manifest" | jsonfilter -e "@.sizes[\"5gmodem-mtk-at.$EXT\"]" 2>/dev/null)
	case "$size" in ''|*[!0-9]*)
		echo 'Missing MediaTek helper download size' >> "$LOG"; return 1 ;;
	esac
	[ "$size" -gt 0 ] || { echo 'Invalid MediaTek helper download size' >> "$LOG"; return 1; }
	MTK_FILE="$TMP/5gmodem-mtk-at.$EXT"; MTK_TARGET="$target"
	MTK_SIZE="$size"; MTK_SUM="$sum"; MTK_URL="$base/5gmodem-mtk-at.$EXT"
	logger -t 5gmodem "update: including installed MediaTek helper update $current -> $target"
}

mtk_helper_download() {
	local offset="$1" total="$2" pid actual
	[ -n "$MTK_FILE" ] || return 0
	rm -f "$MTK_FILE" "$MTK_FILE.ok"
	st download "$offset" "$total" mtk
	( net_fetch 60 "$MTK_URL" "$MTK_FILE" && : > "$MTK_FILE.ok" ) >/dev/null 2>&1 </dev/null &
	pid=$!
	while kill -0 "$pid" 2>/dev/null; do
		st download "$((offset + $(fsize "$MTK_FILE")))" "$total" mtk
		sleep 1
	done
	wait "$pid" 2>/dev/null
	if [ ! -f "$MTK_FILE.ok" ] || [ "$(fsize "$MTK_FILE")" != "$MTK_SIZE" ]; then
		rm -f "$MTK_FILE" "$MTK_FILE.ok"
		echo 'MediaTek helper download failed or is incomplete' >> "$LOG"; return 1
	fi
	rm -f "$MTK_FILE.ok"
	actual=$(sha256sum "$MTK_FILE" 2>/dev/null | cut -c1-64)
	[ "$actual" = "$MTK_SUM" ] || {
		rm -f "$MTK_FILE"; echo 'MediaTek helper checksum mismatch' >> "$LOG"; return 1
	}
	st download "$((offset + MTK_SIZE))" "$total" mtk
}

st() {
	printf '{"running":true,"stage":"%s","done":%s,"total":%s,"target":"%s","step":"%s"}\n' \
		"$1" "${2:-0}" "${3:-0}" "$(json_esc "$TARGET")" "$(json_esc "$4")" > "$STATUS.tmp" && mv "$STATUS.tmp" "$STATUS"
}

fsize() { [ -f "$1" ] && wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

case "$1" in
version)
	# asked by the Settings page on every open: the package database is read directly (two apk
	# runs took ~4 s on a busy MIPS router); the package manager is the fallback
	CUR=$(fast_version)
	if [ -z "$CUR" ]; then
		PM=$(pkgman)
		PKG=$(detect_pkg "$PM")
		CUR=$(installed_version "$PM")
	fi
	printf '{"current":"%s"}\n' "$(json_esc "$CUR")"
	;;

check)
	PM=$(pkgman)
	PKG=$(detect_pkg "$PM")
	CUR=$(installed_version "$PM")
	J=$(api_json fresh)
	LAT=$(printf '%s' "$J" | jsonfilter -e '@.tag_name' 2>/dev/null)
	if [ -z "$LAT" ]; then
		printf '{"success":false,"error":"Could not reach GitHub","pm":"%s","current":"%s"}\n' "$PM" "$(json_esc "$CUR")"
		exit 0
	fi
	LATV=${LAT#v}
	AVAIL=0
	if [ -n "$CUR" ]; then
		AVAIL=$(version_gt "$LATV" "$CUR")
	else
		AVAIL=1
	fi
	NOTES=$(printf '%s' "$J" | jsonfilter -e '@.body' 2>/dev/null)
	case "$2" in
		ru|id|ja|vi|zh_Hans|zh_Hant)
			# API address for the same reason as the package below (long headers on github.com)
			_nl_url=$(printf '%s' "$J" | jsonfilter -e "@.assets[@.name='notes-$2.txt'].url" 2>/dev/null)
			if [ -n "$_nl_url" ]; then
				_nl_txt=$(net_fetch 4 "$_nl_url" "" "Accept: application/octet-stream" check | head -c 8192)
				[ -n "$_nl_txt" ] && NOTES="$_nl_txt"
			fi
			;;
	esac
	PUB=$(printf '%s' "$J" | jsonfilter -e '@.published_at' 2>/dev/null)
	printf '{"success":true,"pm":"%s","package":"%s","variant":"%s","current":"%s","latest":"%s","update_available":%s,"release_url":"%s","published":"%s","notes":"%s"}\n' \
		"$PM" "$PKG" "$([ "$PKG" = "$PKG_LITE" ] && echo lite || echo full)" \
		"$(json_esc "$CUR")" "$(json_esc "$LAT")" "$AVAIL" "$PAGE" "$(json_esc "$PUB")" "$(_b64 "$NOTES")"
	;;

install)
	# mkdir is the atomic part: two calls at the same moment used to pass the pid test both and
	# write the same package file. A directory left by a killed worker is taken over.
	if ! mkdir "$LOCK.d" 2>/dev/null; then
		if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
			echo '{"started":true,"already":true}'
			exit 0
		fi
	fi
	echo "$$" > "$LOCK" 2>/dev/null
	rm -f "$STATUS" "$STATUS.tmp" "$LOG"
	echo '{"running":true,"stage":"prepare"}' > "$STATUS"
	echo '{"started":true}'
	(
		fail() {
			printf '{"success":false,"error":"%s","detail":"%s","current":"%s","target":"%s","pkgs":"%s"}\n' \
				"$(json_esc "$1")" "$(json_esc "$(tail -n 4 "$LOG" 2>/dev/null)")" \
				"$(json_esc "$(installed_version "$PM")")" "$(json_esc "$TARGET")" "$(json_esc "$2")"
		}
		apk_world_blockers() {
			awk '/^  [^ ].* \(no such package\):/ { n = $1; next }
				n != "" && /required by: world\[/ { print n; n = ""; next }
				/^  [^ ]/ { n = "" }' "$LOG" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//'
		}
		apk_install() {
			set -- "$F"
			[ -z "$MTK_FILE" ] || set -- "$@" "$MTK_FILE"
			# The file alone is enough when its dependencies are installed: no package lists, so
			# no network. Without this apk fetched every list first, and on a link where only a
			# VPN gets out the install hung at "unpacking" for minutes.
			run_install apk add --no-network --allow-untrusted "$@" >"$LOG" 2>&1 && return 0
			grep -q 'unable to select packages' "$LOG" 2>/dev/null || return 1
			logger -t 5gmodem "update: the package needs something not installed - fetching package lists"
			echo deps > "$STEP"
			apk_net add --allow-untrusted "$@" >"$LOG" 2>&1 && return 0
			grep -q 'unable to select packages' "$LOG" 2>/dev/null || return 1
			[ -z "$(apk_world_blockers)" ] || return 1
			apk_net update >/dev/null 2>&1
			apk_net add --allow-untrusted "$@" >"$LOG" 2>&1
		}
		do_install() {
			TARGET=""; MTK_FILE=""; MTK_TARGET=""; MTK_SIZE=0; MTK_SUM=""; MTK_URL=""
			PM=$(pkgman)
			[ -n "$PM" ] || { fail "No package manager found"; return; }
			PKG=$(detect_pkg "$PM")
			case "$PM" in apk) EXT=apk ;; opkg) EXT=ipk ;; esac
			PREV=$(installed_version "$PM")

			st prepare
			J=$(api_json) || { fail "Could not reach GitHub"; return; }
			NAME=$(asset_name "$J" "$PKG" "$EXT")
			[ -n "$NAME" ] || { fail "asset_pending"; return; }
			TARGET=$(printf '%s' "$NAME" | sed -n 's/^.*[-_]\([0-9][0-9.]*\)-r[0-9][0-9]*[-_.].*$/\1/p')
			# The API address of the asset, not browser_download_url: github.com answers the latter
			# with a Content-Security-Policy line over 4 KB, and uclient-fetch (wget on OpenWrt) waits
			# for the end of a header line longer than its 4 KB buffer until the timeout. The API
			# redirects straight to the file server with short headers.
			URL=$(printf '%s' "$J" | jsonfilter -e "@.assets[@.name='$NAME'].url" 2>/dev/null)
			ACC="Accept: application/octet-stream"
			if [ -z "$URL" ]; then
				URL=$(printf '%s' "$J" | jsonfilter -e "@.assets[@.name='$NAME'].browser_download_url" 2>/dev/null)
				ACC=""
			fi
			TOTAL=$(printf '%s' "$J" | jsonfilter -e "@.assets[@.name='$NAME'].size" 2>/dev/null)
			# "sha256:<hex>" published by GitHub for the asset; older releases have none
			SUM=$(printf '%s' "$J" | jsonfilter -e "@.assets[@.name='$NAME'].digest" 2>/dev/null \
				| sed -n 's/^sha256:\([0-9a-fA-F]\{64\}\)$/\1/p' | tr 'A-F' 'a-f')
			case "$TOTAL" in ''|*[!0-9]*) TOTAL=0 ;; esac
			[ -n "$URL" ] || { fail "asset_pending"; return; }

			mtk_helper_prepare || { fail "helper_update_failed"; return; }
			DOWNLOAD_TOTAL=0
			[ "$TOTAL" -eq 0 ] || DOWNLOAD_TOTAL=$((TOTAL + MTK_SIZE))

			_free=$(df -k "$TMP" 2>/dev/null | awk 'NR==2 {print $4}')
			case "$_free" in ''|*[!0-9]*) _free=0 ;; esac
			if [ "$TOTAL" -gt 0 ] && [ "$_free" -gt 0 ] && [ $((_free * 1024)) -lt $(((TOTAL + MTK_SIZE) * 2)) ]; then
				fail "no_space"; return
			fi

			F="$TMP/$PKG.$EXT"
			rm -f "$F" "$F.ok"
			st download 0 "$DOWNLOAD_TOTAL"
			( net_fetch 120 "$URL" "$F" "$ACC" && : > "$F.ok" ) >/dev/null 2>&1 </dev/null &
			_dp=$!
			while kill -0 "$_dp" 2>/dev/null; do
				st download "$(fsize "$F")" "$DOWNLOAD_TOTAL"
				sleep 1
			done
			wait "$_dp" 2>/dev/null
			if [ ! -f "$F.ok" ] || [ ! -s "$F" ]; then
				rm -f "$F" "$F.ok"; fail "download_failed"; return
			fi
			rm -f "$F.ok"
			_got=$(fsize "$F")
			if [ "$TOTAL" -gt 0 ] && [ "$_got" != "$TOTAL" ]; then
				rm -f "$F"; fail "download_incomplete"; return
			fi
			if [ -n "$SUM" ] && command -v sha256sum >/dev/null 2>&1; then
				_sum=$(sha256sum "$F" 2>/dev/null | cut -c1-64)
				if [ "$_sum" != "$SUM" ]; then
					logger -t 5gmodem "update: checksum mismatch for $NAME - the file is not installed"
					rm -f "$F"; fail "download_incomplete"; return
				fi
			fi

			mtk_helper_download "$_got" "$DOWNLOAD_TOTAL" || {
				rm -f "$F"; fail "helper_update_failed"; return
			}
			_downloaded=$((_got + MTK_SIZE))
			rm -f "$STEP" "$F.rc"
			st install "$_downloaded" "$DOWNLOAD_TOTAL"
			(
				if [ "$PM" = apk ]; then
					apk_install
				else
					set -- "$F"
					[ -z "$MTK_FILE" ] || set -- "$@" "$MTK_FILE"
					run_install opkg install --force-reinstall "$@" >"$LOG" 2>&1
				fi
				echo $? > "$F.rc"
			) >/dev/null 2>&1 </dev/null &
			_ip=$!
			while kill -0 "$_ip" 2>/dev/null; do
				st install "$_downloaded" "$DOWNLOAD_TOTAL" "$(cat "$STEP" 2>/dev/null)"
				sleep 1
			done
			wait "$_ip" 2>/dev/null
			_rc=$(cat "$F.rc" 2>/dev/null)
			[ -n "$_rc" ] || _rc=1
			rm -f "$F" "$F.rc" "$STEP"

			st finish "$_downloaded" "$DOWNLOAD_TOTAL"
			case "$PM" in
				apk)  apk del "$I18N" >/dev/null 2>&1 ;;
				opkg) opkg remove "$I18N" >/dev/null 2>&1 ;;
			esac
			for _lmo in /usr/share/5gmodem/i18n/5gmodem.*.lmo; do
				[ -f "$_lmo" ] && cp "$_lmo" /usr/lib/lua/luci/i18n/ 2>/dev/null
			done
			rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null

			CUR=$(installed_version "$PM")
			if [ -n "$TARGET" ] && [ "$CUR" = "$TARGET" ]; then
				if [ -n "$MTK_TARGET" ] && [ "$(mtk_helper_version "$PM")" != "$MTK_TARGET" ]; then
					echo "MediaTek helper $MTK_TARGET was not installed" >> "$LOG"
					fail "helper_update_failed"; return
				fi
				[ "$_rc" = 0 ] || logger -t 5gmodem "update: $PM returned $_rc, but $PKG $TARGET is installed - treating as success"
				printf '{"success":true,"current":"%s","previous":"%s","target":"%s"%s}\n' \
					"$(json_esc "$CUR")" "$(json_esc "$PREV")" "$(json_esc "$TARGET")" \
					"$([ "$PREV" = "$CUR" ] && echo ',"reinstalled":1')"
				return
			fi
			if [ "$_rc" != 0 ]; then
				if [ "$PM" = apk ]; then
					_wb=$(apk_world_blockers)
					if [ -n "$_wb" ]; then
						logger -t 5gmodem "update: apk refuses any install - /etc/apk/world lists packages it cannot find: $_wb"
						fail "world_broken" "$_wb"; return
					fi
				fi
				fail "install_failed"; return
			fi
			fail "version_mismatch"
		}
		do_install > "$STATUS.res" 2>/dev/null
		[ -z "$MTK_FILE" ] || rm -f "$MTK_FILE" "$MTK_FILE.ok"
		mv "$STATUS.res" "$STATUS"
		rm -f "$LOCK"; rmdir "$LOCK.d" 2>/dev/null
	) >/dev/null 2>&1 </dev/null &
	echo "$!" > "$LOCK" 2>/dev/null
	sleep 1
	exit 0
	;;

devs)
	# devices a download can be bound to: up, not loopback, not a bridge port; curl:0 means the choice has no effect
	_dv=""
	for _dn in /sys/class/net/*; do
		_dn=${_dn##*/}
		case "$_dn" in lo|*[!A-Za-z0-9._@-]*) continue ;; esac
		[ $(( $(cat "/sys/class/net/$_dn/flags" 2>/dev/null || echo 0) & 1 )) -ne 0 ] || continue
		# a bridge port (LAN Wi-Fi, switch port) carries no route of its own
		[ -e "/sys/class/net/$_dn/master" ] && continue
		_dv="$_dv${_dv:+,}\"$_dn\""
	done
	_dd=$(ip -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
	printf '{"curl":%s,"default":"%s","devs":[%s]}\n' \
		"$(command -v curl >/dev/null 2>&1 && echo 1 || echo 0)" "$(json_esc "$_dd")" "$_dv"
	;;

status)
	if [ -s "$STATUS" ] && grep -q '"running":true' "$STATUS" 2>/dev/null \
	   && ! { [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; }; then
		# the worker is gone (killed, out of memory) without writing a result
		sleep 1
		if grep -q '"running":true' "$STATUS" 2>/dev/null; then
			echo '{"success":false,"error":"install_failed","detail":"the update worker stopped without a result"}'
			rm -f "$LOCK"; rmdir "$LOCK.d" 2>/dev/null
		else
			cat "$STATUS"
		fi
	elif [ -s "$STATUS" ]; then
		cat "$STATUS"
	elif [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		echo '{"running":true}'
	else
		echo '{"idle":true}'
	fi
	;;

*)
	echo '{"success":false,"error":"usage: update.sh version|check|install|status|devs"}'
	exit 1
	;;
esac
