#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
src=${1:-$here/../root/usr/share/5gmodem/userfiles.sh}
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sed "s#^BASE=/etc/5gmodem/modem#BASE=$work/modem#" "$src" > "$work/uf.sh"
uf() { sh "$work/uf.sh" "$@"; }
fail=0
ok()   { if uf "$@"; then echo "ok   $*"; else echo "FAIL (ждали успех) $*"; fail=1; fi; }
deny() { if uf "$@" 2>/dev/null; then echo "FAIL (ждали отказ) $*"; fail=1; else echo "ok   отказ $*"; fi; }

ok mkdir ussdcodes
ok list ussdcodes
echo hi > "$work/modem/ussdcodes/a.user"
ok chmod ussdcodes a.user
ok rm ussdcodes a.user
ok export ussdcodes
deny list /etc
deny list ../../etc
deny chmod ussdcodes ../../../etc/passwd
deny rm ussdcodes ../x.user
deny chmod ussdcodes .hidden.user
deny rm ussdcodes "a.user
rm -rf /"
ln -s /etc/crontabs/root "$work/evil.user" 2>/dev/null
( cd "$work" && tar -czhf /tmp/ussdcodes_upload.tar.gz evil.user 2>/dev/null ) || \
	( cd "$work" && tar -czf /tmp/ussdcodes_upload.tar.gz evil.user )
uf import ussdcodes >/dev/null 2>&1
if [ -L "$work/modem/ussdcodes/evil.user" ]; then echo "FAIL import оставил симлинк"; fail=1; else echo "ok   import не оставил симлинк"; fi
rm -f /tmp/ussdcodes_upload.tar.gz

[ "$fail" = 0 ] && echo "PASS userfiles" || { echo "FAILED userfiles"; exit 1; }
