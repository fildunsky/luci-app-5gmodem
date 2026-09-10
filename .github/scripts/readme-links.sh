#!/bin/sh
# Point every install link in the three READMEs at release <version>-r<release>.
#
# Called by the publish job of build.yml ONLY after all packages are attached
# and the draft release is published - until then the links keep pointing at
# the previous release, which is still downloadable. Bumping them by hand in
# the release commit left a 15-20 minute window in which the README install
# command returned 404.
#
# Usage: readme-links.sh <version> <pkg_release>     e.g. readme-links.sh 2.4.65 1
set -eu

V="$1"
R="$2"
case "$V" in ''|*[!0-9.]*) echo "bad version: $V" >&2; exit 2 ;; esac
case "$R" in ''|*[!0-9]*) echo "bad release: $R" >&2; exit 2 ;; esac

URL='https://github.com/fildunsky/luci-app-5gmodem/releases/download'
for f in README.md README.ru.md README.zh-CN.md; do
	[ -f "$f" ] || continue
	sed -i \
		-e "s|$URL/v[0-9][0-9.]*/|$URL/v$V/|g" \
		-e "s|\\($URL/v$V/luci-app-5gmodem\\(-lite\\)\\{0,1\\}\\)-[0-9][0-9.]*-r[0-9][0-9]*\\.apk|\\1-$V-r$R.apk|g" \
		-e "s|\\($URL/v$V/luci-app-5gmodem\\(-lite\\)\\{0,1\\}\\)_[0-9][0-9.]*-r[0-9][0-9]*_all\\.ipk|\\1_$V-r${R}_all.ipk|g" \
		"$f"
done
