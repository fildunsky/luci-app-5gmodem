#!/bin/bash
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
HOST="${STAND_HOST:-192.168.11.1}"
OUT=""
PAGES=1
WIDTHS="390,1280"
ONLY_PAGES=""
LIMITED=1
SOAK=0
DESTRUCTIVE=0
WL=""
WL_MIN=12
FUNC=1

usage() {
	cat <<EOF
Usage: STAND_PASS=... $0 [options]
  -H host            stand address (default $HOST)
  -o dir             output dir (default ./out-<date>)
  --no-func          skip functional checks on the stand
  --no-pages         skip headless page checks
  --pages list       only these pages (detail,readsms,...)
  --widths list      page widths (default $WIDTHS)
  --no-limited       skip the restricted rpcd user (ACL check)
  --soak MIN         keep the Network page open MIN minutes and sample the stand
  --destructive      band change + restore, soft radio restart
  --whitelist MODES  whitelist-only operator simulation, MODES = open,tcp,dnsonly (block = full outage, healing expected)
  --wl-min MIN       minutes per whitelist mode (default $WL_MIN)
EOF
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		-H) HOST="$2"; shift ;;
		-o) OUT="$2"; shift ;;
		--no-func) FUNC=0 ;;
		--no-pages) PAGES=0 ;;
		--pages) ONLY_PAGES="$2"; shift ;;
		--widths) WIDTHS="$2"; shift ;;
		--no-limited) LIMITED=0 ;;
		--soak) SOAK="$2"; shift ;;
		--destructive) DESTRUCTIVE=1 ;;
		--whitelist) WL="$2"; shift ;;
		--wl-min) WL_MIN="$2"; shift ;;
		*) usage ;;
	esac
	shift
done

[ -n "${STAND_PASS:-}" ] || { echo "STAND_PASS is not set"; exit 2; }
OUT="${OUT:-$PWD/out-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
REPORT="$OUT/report.tsv"
: > "$REPORT"

AP=$(mktemp)
printf '#!/bin/sh\necho "%s"\n' "$STAND_PASS" > "$AP"
chmod 700 "$AP"
trap 'rm -f "$AP"; [ -n "${LIM_SID:-}" ] && ssh_ "uci -q delete rpcd.standtest; uci commit rpcd" >/dev/null 2>&1' EXIT

ssh_() {
	SSH_ASKPASS="$AP" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
		setsid -w timeout "${T:-120}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=10 -o LogLevel=ERROR "root@$HOST" "$@"
}

rep() { tee -a "$REPORT"; }
note() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${3:-0}" "${4:-}" | rep; }

login() {
	ssh_ "ubus call session login '{\"username\":\"$1\",\"password\":\"$STAND_PASS\",\"timeout\":7200}'" \
		| python3 -c 'import json,sys; print(json.load(sys.stdin)["ubus_rpc_session"])' 2>/dev/null
}

T=20 ssh_ true || { note FAIL ssh.reach 0 "stand $HOST does not answer over ssh (check the host network profile first)"; exit 1; }
BAK=$(T=30 ssh_ 'd=/tmp/stand-test-bak; mkdir -p $d; cp /etc/config/5gmodem /etc/config/network /etc/config/firewall /etc/config/rpcd $d/; uci show > $d/uci-all; md5sum $d/uci-all | cut -c1-32')
note INFO backup 0 "configs copied to /tmp/stand-test-bak on the stand (uci md5 $BAK)"

SID=$(login root)
[ -n "$SID" ] || { note FAIL session.root 0 "ubus session login failed"; exit 1; }
T=20 ssh_ "ubus call session set '{\"ubus_rpc_session\":\"$SID\",\"values\":{\"token\":\"$(head -c16 /dev/urandom | md5sum | cut -c1-32)\"}}'"

if [ "$FUNC" = 1 ]; then
	NONCE="st$RANDOM$RANDOM"
	T=900 ssh_ "NONCE=$NONCE USSDCODE='${USSDCODE:-}' sh -s" < "$HERE/stand/checks.sh" > "$OUT/func.raw"
	python3 "$HERE/judge.py" "$OUT/func.raw" "$NONCE" | rep
	python3 "$HERE/rpc.py" "$HOST" "$SID" root | rep
fi

LIM_SID=""
if [ "$LIMITED" = 1 ]; then
	T=30 ssh_ 'uci -q delete rpcd.standtest; uci set rpcd.standtest=login; uci set rpcd.standtest.username=standtest; uci set rpcd.standtest.password="\$p\$root"; for g in luci-base unauthenticated luci-app-5gmodem luci-theme-proton2025; do uci add_list rpcd.standtest.read=$g; uci add_list rpcd.standtest.write=$g; done; uci commit rpcd'
	LIM_SID=$(login standtest)
	if [ -n "$LIM_SID" ]; then
		T=20 ssh_ "ubus call session set '{\"ubus_rpc_session\":\"$LIM_SID\",\"values\":{\"token\":\"$(head -c16 /dev/urandom | md5sum | cut -c1-32)\"}}'"
		[ "$FUNC" = 1 ] && python3 "$HERE/rpc.py" "$HOST" "$LIM_SID" limited | rep
	else
		note FAIL session.limited 0 "login of the restricted user failed"
	fi
fi

if [ "$PAGES" = 1 ]; then
	mkdir -p "$OUT/pages"
	"$HERE/chrome.sh" "$OUT/pages" "$SID" "$HOST" "$WIDTHS" "$ONLY_PAGES" | rep
	if [ -n "$LIM_SID" ]; then
		mkdir -p "$OUT/pages-limited"
		CDP_PORT=9462 "$HERE/chrome.sh" "$OUT/pages-limited" "$LIM_SID" "$HOST" 1280 "${ONLY_PAGES:-app}" \
			| sed 's/\tpage\./\tpage-limited./' | rep
	fi
fi

if [ "$SOAK" != 0 ]; then
	DUR=$((SOAK * 60))
	mkdir -p "$OUT/soak"
	PAGE_WAIT=$((DUR * 1000)) CDP_PORT=9463 "$HERE/chrome.sh" "$OUT/soak" "$SID" "$HOST" 1280 detail \
		| sed 's/\tpage\.detail\.1280/\tsoak.page-errors/; /doctor-check/d' > "$OUT/soak/page.tsv" &
	CPID=$!
	T=$((DUR + 120)) ssh_ "DUR=$DUR STEP=30 sh -s" < "$HERE/stand/soak.sh" > "$OUT/soak/samples.txt"
	wait "$CPID"
	cat "$OUT/soak/page.tsv" | rep
	python3 "$HERE/soakjudge.py" "$OUT/soak/samples.txt" "$OUT/soak"/*.calls.txt | rep
fi

if [ "$DESTRUCTIVE" = 1 ]; then
	T=1500 ssh_ "sh -s" < "$HERE/stand/destructive.sh" | rep
fi

if [ -n "$WL" ]; then
	mkdir -p "$OUT/whitelist"
	T=40 ssh_ "sh -s selftest" < "$HERE/stand/whitelist.sh" | rep
	if grep -q "^PASS	wl.rollback-selftest" "$REPORT"; then
		for mode in $(echo "$WL" | tr ',' ' '); do
			secs=$((WL_MIN * 60))
			T=60 ssh_ "sh -s arm $mode $((secs + 300))" < "$HERE/stand/whitelist.sh" | rep
			tail -n 1 "$REPORT" | grep -q '^INFO	wl.arm' || continue
			T=$((secs + 180)) ssh_ "sh -s observe $secs 30" < "$HERE/stand/whitelist.sh" > "$OUT/whitelist/$mode.txt"
			T=60 ssh_ "sh -s disarm" < "$HERE/stand/whitelist.sh" | rep
			python3 "$HERE/wljudge.py" "$mode" "$OUT/whitelist/$mode.txt" | rep
			T=400 ssh_ 'i=0; while [ $i -lt 60 ]; do s=$(cut -d" " -f1 /tmp/5gmodem/health/$(uci -q get 5gmodem.@5gmodem[0].network) 2>/dev/null); [ "$s" = up ] && break; sleep 5; i=$((i+1)); done; sleep 35; echo "R health=$s dns_listed=$(grep -c "^# Interface $(uci -q get 5gmodem.@5gmodem[0].network)" /tmp/resolv.conf.d/resolv.conf.auto)"' >> "$OUT/whitelist/$mode.txt"
			python3 "$HERE/wljudge.py" "$mode" "$OUT/whitelist/$mode.txt" recovery | rep
		done
	else
		note FAIL wl.skipped 0 "rollback self-test failed - whitelist scenario not run"
	fi
fi

T=30 ssh_ 'uci -q delete rpcd.standtest; uci commit rpcd; uci show > /tmp/stand-test-bak/uci-after'
T=30 ssh_ 'cat /tmp/stand-test-bak/uci-all' > "$OUT/uci-before.txt"
T=30 ssh_ 'cat /tmp/stand-test-bak/uci-after' > "$OUT/uci-after.txt"
AFTER=$(diff "$OUT/uci-before.txt" "$OUT/uci-after.txt" | grep '^[<>] [a-z]' | grep -vE 'sms_count|\.stamp|_seen|conn_since' | head -n 20)
LIM_SID=""
if [ -n "$AFTER" ]; then note WARN config.unchanged 0 "uci differs from the start: $(echo "$AFTER" | tr '\n' ' ')"
else note PASS config.unchanged 0 "uci identical to the start"; fi

P=$(grep -c '^PASS' "$REPORT"); F=$(grep -c '^FAIL' "$REPORT"); W=$(grep -c '^WARN' "$REPORT"); S=$(grep -c '^SKIP' "$REPORT")
echo "== PASS $P  FAIL $F  WARN $W  SKIP $S  -> $REPORT"
[ "$F" = 0 ]
