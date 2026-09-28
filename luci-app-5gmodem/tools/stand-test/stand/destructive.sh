#!/bin/sh
R=/usr/share/5gmodem
IFACE=$(uci -q get 5gmodem.@5gmodem[0].network)
SEC=$(uci -q show 5gmodem | sed -n "s/^5gmodem\.\([^.]*\)\.path='$(uci -q get 5gmodem.@5gmodem[0].active_modem)'$/\1/p" | head -n 1)
PING="${PING_TARGET:-77.88.8.8}"

now() { cut -d. -f1 /proc/uptime; }
res() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

online() {
	_d=$(ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	ifstatus "$IFACE" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' >/dev/null 2>&1 || return 1
	_rg=$($R/5gmodem.sh peek 2>/dev/null | jsonfilter -e '@.registration' 2>/dev/null)
	case "$_rg" in 1|5) ;; *) return 1 ;; esac
	[ -n "$_d" ] && ping -I "$_d" -c 1 -W 3 "$PING" >/dev/null 2>&1
}

wait_online() {
	_t0=$(now); _lim="$1"
	sleep 5
	while [ $(( $(now) - _t0 )) -lt "$_lim" ]; do
		online && { echo $(( $(now) - _t0 )); return 0; }
		sleep 5
	done
	echo "$_lim"; return 1
}

at_alive() {
	_ap=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	rm -f /tmp/stand-test.ati
	( $R/atcmd.sh "$_ap" ATI 8 > /tmp/stand-test.ati 2>&1 ) </dev/null &
	_apid=$!
	_i=0
	while [ $_i -lt 25 ]; do
		grep -qiE 'Model|Manufacturer|IMEI' /tmp/stand-test.ati 2>/dev/null && { rm -f /tmp/stand-test.ati; return 0; }
		sleep 1; _i=$((_i + 1))
	done
	kill "$_apid" 2>/dev/null
	rm -f /tmp/stand-test.ati
	return 1
}

check_at() {
	if at_alive; then res PASS "$1" 0 "AT port answers ATI"
	else res FAIL "$1" 15 "AT port $(uci -q get 5gmodem.@5gmodem[0].at_port) does not answer ATI (wedged), sms_tool procs: $(ps w | grep -c '[s]ms_tool')"; fi
}

enabled_lte() { $R/bands.sh jsonrefresh 2>/dev/null | jsonfilter -e '@.enabled[*]' 2>/dev/null | sort -n | tr '\n' ' ' | sed 's/ $//'; }

wait_apply() {
	_id="$1"; _t0=$(now)
	while [ $(( $(now) - _t0 )) -lt 150 ]; do
		_st=$($R/bands.sh applyresult 2>/dev/null | jsonfilter -e '@.state' 2>/dev/null)
		case "$_st" in done|none) echo "$_st"; return 0 ;; esac
		sleep 3
	done
	echo "timeout"; return 1
}

apply_lte() {
	_o=$($R/bands.sh setall "lte=$1" 2>&1)
	_i=$(printf '%s' "$_o" | jsonfilter -e '@.id' 2>/dev/null)
	[ -n "$_i" ] || { echo "no-id:$_o"; return 1; }
	wait_apply "$_i"
}

online || { res FAIL destructive.precondition 0 "modem is not online before destructive tests - nothing touched"; exit 1; }
at_alive || { res FAIL destructive.precondition 0 "AT port does not answer before destructive tests - nothing touched"; exit 1; }

ORIG=$(enabled_lte)
SAVED=$(uci -q get "5gmodem.$SEC.save_band")
[ -n "$ORIG" ] || { res FAIL bands.read 0 "no enabled LTE bands"; exit 1; }
USED=$($R/5gmodem.sh peek | jsonfilter -e '@.pband' -e '@.s1band' -e '@.s2band' -e '@.s3band' -e '@.s4band' 2>/dev/null | sed -n 's/^B\([0-9]*\).*/\1/p' | tr '\n' ' ')
DROP=""
for b in $ORIG; do
	case " $USED " in *" $b "*) ;; *) DROP="$b" ;; esac
done
[ -n "$DROP" ] || { res SKIP bands.change 0 "every enabled band is in use"; DROP=""; }

if [ -n "$DROP" ]; then
	NEW=$(for b in $ORIG; do [ "$b" = "$DROP" ] || printf '%s ' "$b"; done | sed 's/ $//')
	t0=$(now)
	st=$(apply_lte "$NEW")
	GOT=$(enabled_lte)
	if [ "$GOT" = "$NEW" ]; then res PASS bands.change $(( $(now) - t0 )) "dropped B$DROP, apply=$st"
	else res FAIL bands.change $(( $(now) - t0 )) "apply=$st want [$NEW] got [$GOT]"; fi
	w=$(wait_online 240) && res PASS bands.change.online "$w" "back online" || res FAIL bands.change.online "$w" "not online after band change"
	check_at bands.change.at-port
	t0=$(now)
	st=$(apply_lte "$ORIG")
	GOT=$(enabled_lte)
	if [ "$GOT" = "$ORIG" ]; then res PASS bands.restore $(( $(now) - t0 )) "apply=$st [$GOT]"
	else res FAIL bands.restore $(( $(now) - t0 )) "apply=$st want [$ORIG] got [$GOT]"; fi
	w=$(wait_online 240) && res PASS bands.restore.online "$w" "back online" || res FAIL bands.restore.online "$w" "not online after restore"
	check_at bands.restore.at-port
	NOWSAVED=$(uci -q get "5gmodem.$SEC.save_band")
	if [ "$NOWSAVED" != "$SAVED" ]; then
		if [ -n "$SAVED" ]; then uci set "5gmodem.$SEC.save_band=$SAVED"; else uci -q delete "5gmodem.$SEC.save_band"; fi
		uci commit 5gmodem
		res WARN bands.saved-uci 0 "save_band differed after restore ([$NOWSAVED] vs [$SAVED]) - put back"
	else
		res PASS bands.saved-uci 0 "save_band unchanged"
	fi
fi

t0=$(now)
o=$($R/reboot_modem.sh soft 2>&1)
w=$(wait_online 240) && res PASS radio.restart "$w" "soft CFUN cycle: back online ($o)" || res FAIL radio.restart "$w" "not online after soft restart ($o)"
check_at radio.restart.at-port
