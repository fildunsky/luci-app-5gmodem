#!/bin/sh

[ $# -ge 2 ] || { echo "usage: golden.sh <old tree> <new tree> [run.sh args]"; exit 2; }
OLD=$(cd "$1" && pwd) || exit 2
NEW=$(cd "$2" && pwd) || exit 2
shift 2

keep_run() {
	_kr_d="$1"; shift
	( cd "$_kr_d" && ulimit -v 2000000 2>/dev/null; timeout 1200 sh tools/profile-smoke/run.sh -k "$@" 2>&1 ) \
		| sed -n 's/^workdir kept: //p' | tail -n 1
}

WO=$(keep_run "$OLD" "$@")
WN=$(keep_run "$NEW" "$@")
[ -d "$WO/out" ] && [ -d "$WN/out" ] || { echo "golden: a run did not complete (old=$WO new=$WN)"; exit 2; }

norm() {
	sed -e "s#$2#@W@#g" -e 's/\r$//' -e '/^EXT sleep /d' "$1" 2>/dev/null | sort
}

diffs=0
for f in "$WO"/out/*.vars "$WO"/out/*.log; do
	b=${f##*/}
	if [ ! -f "$WN/out/$b" ]; then
		echo "only in old: $b"; diffs=$((diffs + 1)); continue
	fi
	if ! norm "$f" "$WO" > "$WO/.a" || ! norm "$WN/out/$b" "$WN" > "$WN/.b"; then continue; fi
	if ! cmp -s "$WO/.a" "$WN/.b"; then
		diffs=$((diffs + 1))
		echo "=== $b"
		diff "$WO/.a" "$WN/.b" | grep '^[<>]' | head -n 12
	fi
done
for f in "$WN"/out/*.vars "$WN"/out/*.log; do
	[ -f "$WO/out/${f##*/}" ] || { echo "only in new: ${f##*/}"; diffs=$((diffs + 1)); }
done
rm -rf "$WO" "$WN"
echo "golden: $diffs differing runs"
[ "$diffs" = 0 ]
