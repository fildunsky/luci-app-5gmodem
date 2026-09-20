#!/bin/sh
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=$(cd "$HERE/../.." && pwd)
SRC="$PKG/root/usr/share/5gmodem"
MODES="ok err cme empty hollow junk alpha"
VERBOSE=0
KEEP=0
ONLY=""
KIND="modem band"

usage() {
	echo "usage: run.sh [-v] [-k] [-m 'ok err ...'] [-t modem|band] [profile ...]"
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		-v) VERBOSE=1 ;;
		-k) KEEP=1 ;;
		-m) shift; MODES="$1" ;;
		-t) shift; KIND="$1" ;;
		-h|--help) usage ;;
		-*) usage ;;
		*) ONLY="$ONLY $1" ;;
	esac
	shift
done

BB=$(command -v busybox) || { echo "busybox is required"; exit 2; }
[ -d "$SRC/modem" ] || { echo "no profile tree at $SRC"; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/profile-smoke.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] && echo "workdir kept: $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

SHARE="$WORK/share"
BIN="$WORK/bin"
mkdir -p "$SHARE" "$BIN" "$WORK/tmp" "$WORK/dev" "$WORK/out"
cp -r "$SRC/." "$SHARE/"
ln -s /dev/null "$WORK/dev/ttyUSB2"
ln -s /dev/null "$WORK/dev/wwan0at0"

find "$SHARE" -type f | while read -r f; do
	case "$f" in
		*.lmo|*.dat|*.tsv|*.list|*.txt|*/certs/*|*/licenses/*) continue ;;
	esac
	sed -i -e "s,/tmp/,$WORK/tmp/,g" -e "s,/usr/share/5gmodem,$SHARE,g" \
		-e "s,/var/lock/,$WORK/tmp/,g" "$f"
done

for a in $("$BB" --list); do
	ln -s "$BB" "$BIN/$a" 2>/dev/null
done
for s in "$HERE"/stubs/*; do
	n=${s##*/}
	rm -f "$BIN/$n"
	{ echo "#!$BB sh"; sed 1d "$s"; } > "$BIN/$n"
	chmod +x "$BIN/$n"
done
cp "$BIN/modemswitch.sh" "$SHARE/modemswitch.sh"

extract() {
	src="$1"; shift
	for fn in "$@"; do
		awk -v fn="$fn" '
			!on && $0 ~ ("^" fn "\\(\\)[ \t]*\\{") { on = 1 }
			on { print }
			on && /^\}/ { exit }' "$src"
	done
}
extract "$SRC/5gmodem.sh" band3g earfcn2band band4g band5g getdevicevendorproduct \
	_st_ident_cmd _st_drop_ok getpath at_static > "$WORK/fw_modem.sh"
extract "$SRC/bands.sh" $(grep -o '^[A-Za-z_0-9]*()' "$SRC/bands.sh" | tr -d '()') > "$WORK/fw_band.sh"
sed -i -e "s,/tmp/,$WORK/tmp/,g" -e "s,/usr/share/5gmodem,$SHARE,g" \
	-e "s,/var/lock/,$WORK/tmp/,g" "$WORK/fw_modem.sh" "$WORK/fw_band.sh"
for f in "$WORK/fw_modem.sh" "$WORK/fw_band.sh"; do
	"$BB" sh -n "$f" || { echo "framework extract is broken: $f"; exit 2; }
done

FATAL='arithmetic|bad number|not found|unknown operand|syntax error|unterminated|unmatched|bad substitution|unexpected|division by zero|parameter not set|[Ii]llegal|invalid number|out of range'
FATAL_SYNTH='arithmetic|not found|unknown operand|syntax error|unterminated|unmatched|bad substitution|unexpected|division by zero|parameter not set|[Ii]llegal'
NOISE='Math support is not compiled in'
NUMVARS="RSRP RSRQ SINR RSSI RSCP ECIO PCI EARFCN S1PCI S2PCI S3PCI S4PCI S1EARFCN S2EARFCN S3EARFCN S4EARFCN S1RSRP S2RSRP S3RSRP S4RSRP S1RSRQ S2RSRQ S3RSRQ S4RSRQ S1SINR S2SINR S3SINR S4SINR S1RSSI S2RSSI S3RSSI S4RSSI TAC_DEC T_DEC LAC_DEC CID_DEC TXPOWER PATHLOSS CQI ENBID"
GARBAGE='ERROR|NaN|zz|0xZZ|\(\(\(|%d|\$%|: : :'

TOTAL=0
FAILED=0
FAILLOG="$WORK/failures.txt"
: > "$FAILLOG"

want() {
	[ -z "$ONLY" ] && return 0
	for o in $ONLY; do [ "$o" = "$1" ] && return 0; done
	return 1
}

one_run() {
	kind="$1"; prof="$2"; name="$3"; mode="$4"; fix="$5"; tag="$6"
	out="$WORK/out/$kind.$name.$tag"
	rm -rf "$WORK/tmp"; mkdir -p "$WORK/tmp"
	: > "$out.vars"; : > "$out.log"
	dev="$WORK/dev/ttyUSB2"
	case "$prof" in */pci/*) dev="$WORK/dev/wwan0at0" ;; esac
	[ "$mode" = ok ] && m=ok || m="$mode"
	( ulimit -v 1500000 2>/dev/null; cd "$WORK/tmp" && env -i PATH="$BIN" HOME="$WORK/tmp" SMOKE_MODE="$m" SMOKE_FIX="$fix" \
		SMOKE_LOG="$out.log" SMOKE_VARS="$out.vars" SMOKE_WORK="$WORK" SMOKE_SHARE="$SHARE" \
		SMOKE_BIN="$BIN" SMOKE_DEV="$dev" SMOKE_HERE="$HERE" \
		"$BIN/timeout" 60 "$BB" sh "$HERE/drv-$kind.sh" "$prof" < /dev/null > "$out.stdout" 2> "$out.stderr" )
	why=""
	if [ "$kind" = modem ]; then
		grep -q '^@@SMOKE_MARK@@' "$out.stdout" || why="$why; poll aborted (no marker after profile)"
		grep -v '^@@SMOKE_' "$out.stdout" | grep -q . && why="$why; profile writes to stdout: $(grep -v '^@@SMOKE_' "$out.stdout" | head -n 1 | cut -c1-80)"
	else
		grep -q '^@@SMOKE_MARK@@ load' "$out.stdout" || why="$why; profile aborted while loading"
		grep -q '^@@SMOKE_DONE@@' "$out.stdout" || why="$why; contract run aborted"
	fi
	pat="$FATAL"
	case "$mode" in junk|alpha) pat="$FATAL_SYNTH" ;; esac
	err=$(grep -vE "$NOISE" "$out.stderr" | grep -v '^@@SMOKE_' | grep -E "$pat" | head -n 3 | tr '\n' '~')
	if [ -n "$err" ]; then
		if [ "$kind" = band ]; then
			where=$(awk -v pat="$pat" '/^@@SMOKE_CALL@@/ { c = $0; sub(/^@@SMOKE_CALL@@ /, "", c) } $0 ~ pat && $0 !~ /Math support/ { print c; exit }' "$out.stderr")
			why="$why; stderr in [$where]: $err"
		else
			why="$why; stderr: $err"
		fi
	fi
	cr=""; [ "$kind" = band ] && cr=$(grep -l "$(printf '\r')" "$out.vars" >/dev/null 2>&1 && grep -v '^set' "$out.vars" | grep "$(printf '\r')" | head -n 3 | cut -d= -f1 | tr '\n' ' ')
	[ -n "$cr" ] && why="$why; raw CR inside values: $cr"
	if [ "$mode" != ok ] || [ -z "$fix" ]; then
		if [ "$mode" != ok ] && [ "$mode" != junk ] && [ "$mode" != alpha ]; then
			if [ "$kind" = modem ]; then
				bad=$(grep -vE '^(MODEL|FW|PROTO|NR_IMEI|NR_IMSI)=' "$out.vars" | grep -E "=.*($GARBAGE)" | head -n 3 | tr '\n' '~')
				[ -n "$bad" ] && why="$why; garbage in values: $bad"
				for v in $NUMVARS; do
					val=$(sed -n "s/^$v=//p" "$out.vars" | head -n 1)
					case "$val" in
						''|-) : ;;
						*) printf '%s' "$val" | grep -qE '^-?[0-9]+(\.[0-9]+)?$' || why="$why; $v is not a number: '$val'" ;;
					esac
				done
			else
				bad=$(grep -E '^get' "$out.vars" | grep -vE '^(getinfo|getsupported)' | grep -E "=.*($GARBAGE)" | head -n 3 | tr '\n' '~')
				[ -n "$bad" ] && why="$why; garbage in get* output: $bad"
			fi
		fi
	fi
	if [ "$mode" = ok ] && [ -n "$fix" ] && [ -f "$fix/expect.$kind" ]; then
		while IFS= read -r line; do
			case "$line" in ''|'##'*) continue ;; esac
			k=${line%%=*}; exp=${line#*=}
			got=$(sed -n "s/^$k=//p" "$out.vars" | head -n 1 | tr -d '\r')
			[ "$got" = "$exp" ] || why="$why; $k: expected '$exp', got '$got'"
		done < "$fix/expect.$kind"
	fi
	TOTAL=$((TOTAL + 1))
	if [ -n "$why" ]; then
		FAILED=$((FAILED + 1))
		printf '%s %s [%s]%s\n' "$kind" "$name" "$tag" "$why" >> "$FAILLOG"
		return 1
	fi
	return 0
}

run_profile() {
	kind="$1"; prof="$2"; name="$3"
	row=$(printf '%-6s %-26s' "$kind" "$name")
	for mode in $MODES; do
		cell=PASS
		if [ "$mode" = ok ]; then
			n=0
			for sc in "$HERE/fixtures/$name"/*/; do
				[ -d "$sc" ] || continue
				[ -f "$sc/expect.$kind" ] || continue
				n=$((n + 1))
				one_run "$kind" "$prof" "$name" ok "${sc%/}" "ok:$(basename "$sc")" || cell=FAIL
			done
			if [ "$n" = 0 ]; then
				one_run "$kind" "$prof" "$name" ok "" ok || cell=FAIL
			else
				[ "$cell" = PASS ] && cell="PASS*$n"
			fi
		else
			one_run "$kind" "$prof" "$name" "$mode" "" "$mode" || cell=FAIL
		fi
		row="$row $(printf '%-7s' "$cell")"
	done
	echo "$row"
}

printf '%-6s %-26s' kind profile
for mode in $MODES; do printf ' %-7s' "$mode"; done
echo

for k in $KIND; do
	if [ "$k" = modem ]; then
		for prof in "$SHARE"/modem/usb/* "$SHARE"/modem/pci/* "$SHARE"/modem/_*; do
			[ -f "$prof" ] || continue
			name=${prof##*/}
			want "$name" || continue
			run_profile modem "$prof" "$name"
		done
	else
		for prof in "$SHARE"/modemband/*; do
			[ -f "$prof" ] || continue
			name=${prof##*/}
			want "$name" || continue
			run_profile band "$prof" "$name"
		done
	fi
done

echo
echo "runs: $TOTAL, failed: $FAILED  (PASS*n = n fixture scenarios with value checks)"
if [ "$FAILED" -gt 0 ]; then
	echo
	echo "FAILURES:"
	if [ "$VERBOSE" = 1 ]; then cat "$FAILLOG"; else cut -c1-300 "$FAILLOG"; fi
	exit 1
fi
exit 0
