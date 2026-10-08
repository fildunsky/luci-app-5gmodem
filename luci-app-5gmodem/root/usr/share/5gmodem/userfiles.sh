#!/bin/sh
[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

BASE=/etc/5gmodem/modem

die() { echo "$1" >&2; exit 1; }

case "$2" in
	atcmmds|ussdcodes) KIND="$2" ;;
	*) die "bad kind" ;;
esac
DIR="$BASE/$KIND"

check_name() {
	case "$1" in
		''|.*|*/*|*'
'*) die "bad name" ;;
		*.user) ;;
		*) die "bad name" ;;
	esac
}

case "$1" in
list)
	for f in "$DIR"/*.user; do
		[ -f "$f" ] && [ ! -L "$f" ] && echo "$f"
	done
	exit 0
	;;
mkdir)
	mkdir -p "$DIR"
	;;
chmod)
	check_name "$3"
	[ -f "$DIR/$3" ] && [ ! -L "$DIR/$3" ] || die "no such file"
	chmod 644 -- "$DIR/$3"
	;;
rm)
	check_name "$3"
	rm -f -- "$DIR/$3"
	;;
rmall)
	rm -f -- "$DIR"/*.user
	;;
import)
	SRC="/tmp/5gmodem/${KIND}_upload.tar.gz"
	[ -f "$SRC" ] || die "no archive"
	T=$(mktemp -d /tmp/5gmodem/userfiles.XXXXXX) || die "no tmp"
	if ! tar -xzf "$SRC" -C "$T"; then
		rm -rf "$T"
		die "Failed to extract archive"
	fi
	mkdir -p "$DIR"
	for f in "$T"/*.user; do
		[ -f "$f" ] && [ ! -L "$f" ] || continue
		n=${f##*/}
		case "$n" in .*|*'
'*) continue ;; esac
		cat "$f" > "$DIR/$n.tmp.$$" && chmod 644 "$DIR/$n.tmp.$$" \
			&& mv -f "$DIR/$n.tmp.$$" "$DIR/$n"
	done
	rm -rf "$T"
	;;
export)
	mkdir -p "$DIR"
	tar -czf "/tmp/5gmodem/$KIND.tar.gz" -C "$DIR" .
	;;
*)
	die "usage: userfiles.sh list|mkdir|chmod|rm|rmall|import|export <atcmmds|ussdcodes> [name]"
	;;
esac
