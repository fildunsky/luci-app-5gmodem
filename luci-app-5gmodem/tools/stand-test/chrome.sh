#!/bin/bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
PORT="${CDP_PORT:-9461}"
OUT="$1"; SID="$2"; HOST="$3"; shift 3
CHROME="${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}"
if [ -z "${NODE:-}" ]; then
	for n in $(ls -1d "$HOME"/.nvm/versions/node/v*/bin/node 2>/dev/null | sort -V -r) $(command -v node); do
		[ "$("$n" -e 'console.log(typeof WebSocket)' 2>/dev/null)" = function ] && { NODE="$n"; break; }
	done
fi
[ -n "${NODE:-}" ] || { echo "FAIL	pages	0	no node with global WebSocket (need >= 22)"; exit 1; }
PROF=$(mktemp -d)
"$CHROME" --headless=new --remote-debugging-port="$PORT" --user-data-dir="$PROF" --lang=ru-RU \
	--no-first-run --disable-gpu --hide-scrollbars about:blank >/dev/null 2>&1 &
CP=$!
sleep 2
"$NODE" "$HERE/pages.mjs" "$PORT" "$SID" "$HOST" "$OUT" "$@"
RC=$?
kill "$CP" 2>/dev/null
wait "$CP" 2>/dev/null
sleep 1; rm -rf "$PROF" 2>/dev/null
exit $RC
