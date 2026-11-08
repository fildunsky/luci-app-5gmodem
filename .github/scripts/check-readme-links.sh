#!/bin/sh
set -eu

FAILED=0
for URL in $(grep -hoE 'https://github.com/fildunsky/luci-app-5gmodem/releases/download/[^ )<>"]+' README*.md | sort -u); do
	if CODE=$(curl --fail --silent --show-error --head --location \
		--retry 4 --retry-delay 3 --retry-max-time 120 --retry-connrefused \
		--connect-timeout 10 --max-time 30 --output /dev/null --write-out '%{http_code}' "$URL"); then
		[ "$CODE" = 200 ] || FAILED=1
	else
		FAILED=1
	fi
	printf '%s %s\n' "$CODE" "$URL"
done
[ "$FAILED" = 0 ] || { echo '::error::a README link does not resolve after retries - not committing' >&2; exit 1; }
