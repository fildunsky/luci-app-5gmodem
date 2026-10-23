#!/bin/sh
set -eu

V="$1"
R="$2"
case "$V" in ''|*[!0-9.]*) echo "bad version: $V" >&2; exit 2 ;; esac
case "$R" in ''|*[!0-9]*) echo "bad release: $R" >&2; exit 2 ;; esac

URL='https://github.com/fildunsky/luci-app-5gmodem/releases/download'
for f in README.md README.ru.md README.zh-CN.md README.ja.md README.vi.md README.id.md; do
	[ -f "$f" ] || continue
	sed -i \
		-e "s|$URL/v[0-9][0-9.]*/|$URL/v$V/|g" \
		-e "s|\\($URL/v$V/luci-app-5gmodem\\(-lite\\)\\{0,1\\}\\)-[0-9][0-9.]*-r[0-9][0-9]*\\.apk|\\1-$V-r$R.apk|g" \
		-e "s|\\($URL/v$V/luci-app-5gmodem\\(-lite\\)\\{0,1\\}\\)_[0-9][0-9.]*-r[0-9][0-9]*_all\\.ipk|\\1_$V-r${R}_all.ipk|g" \
		"$f"
done
