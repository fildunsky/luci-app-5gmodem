#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null

RES="/usr/share/5gmodem"

ESIM_READONLY=1
export ESIM_READONLY
OUT="/tmp/5gmodem/diag.txt"
LOCK="/tmp/5gmodem/diag.lock"
STEP="/tmp/5gmodem/diag.step"

SESS="/tmp/5gmodem/.diag-sess.$$"
export SESS

run() {
	_t="$1"; _title="$2"; shift 2
	echo ""
	echo "----- $_title -----"
	_tmp="/tmp/5gmodem/.diag.$$"
	( "$@" ) > "$_tmp" 2>&1 &
	_p=$!
	( sleep "$_t"; kill -9 "$_p" 2>/dev/null ) >/dev/null 2>&1 &
	_w=$!
	wait "$_p" 2>/dev/null
	kill "$_w" 2>/dev/null; wait "$_w" 2>/dev/null
	if [ -s "$_tmp" ]; then cat "$_tmp"; else echo "(empty, or timed out after ${_t}s)"; fi
	cat "$_tmp" >> "$SESS" 2>/dev/null
	rm -f "$_tmp"
}

at() {
	[ -n "$1" ] || { echo "(no AT port)"; return; }
	run 12 "AT $2" at_query "$1" "$2" 8
}

proto_pkg() {
	case "$1" in
		mbim) echo "umbim" ;;
		qmi) echo "uqmi" ;;
		modemmanager) echo "modemmanager luci-proto-modemmanager" ;;
		ncm) echo "comgt-ncm" ;;
		3g) echo "comgt" ;;
		xmm) echo "xmm-modem" ;;
		atc) echo "atc" ;;
		quectel) echo "quectel-cm" ;;
		fibocom|mbimp|qmiraw) echo "luci-app-5gmodem (reinstall it - this handler ships with the app)" ;;
		*) echo "$1" ;;
	esac
}
mbim_verdict() {
	echo ""
	echo "----- Why MBIM did not come up (verdict) -----"
	_mv_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_mv_if" ] || { echo "the modem interface is not configured"; return; }
	[ "$(uci -q get "network.$_mv_if.proto")" = mbim ] || {
		echo "the interface does not run mbim - this check does not apply"; return; }
	if [ ! -f /lib/netifd/proto/mbim.sh ]; then
		echo "PROBLEM: the mbim protocol handler is NOT INSTALLED (/lib/netifd/proto/mbim.sh is missing)."
		echo "  netifd cannot dial at all: the interface shows proto 'none' and NO_DEVICE."
		echo "  WHAT TO DO: install the umbim package (opkg install umbim / apk add umbim), then ifup $_mv_if"
		return
	fi
	_mv_dev=$(uci -q get "network.$_mv_if.device")
	case "$_mv_dev" in
		/dev/cdc-wdm*)
			_mv_drv=$(basename "$(readlink -f "/sys/class/usbmisc/${_mv_dev##*/}/device/driver" 2>/dev/null)" 2>/dev/null)
			if [ "$_mv_drv" = "qmi_wwan" ]; then
				echo "PROBLEM: node $_mv_dev was created by the qmi_wwan driver (a QMI channel),"
				echo "  but the interface protocol is mbim. MBIM will never speak here:"
				echo "  you will get an endless 'mbim message timeout'."
				echo "  WHAT TO DO: uci set network.$_mv_if.proto='qmi'; uci commit network; ifup $_mv_if"
				return
			fi ;;
	esac
	_mv_err=$(ubus call network.interface."$_mv_if" status 2>/dev/null \
		| sed -n 's/.*"code": *"\([^"]*\)".*/\1/p' | head -1)
	_mv_log=$(logread 2>/dev/null | grep -c "Failed to attach to network")
	_mv_pin=$(logread 2>/dev/null | grep -oE "required pin: [0-9]+ - [a-z0-9]+" | tail -1)
	if ubus call network.interface."$_mv_if" status 2>/dev/null | grep -q '"up": true'; then
		echo "the interface is up - mbim works on this modem, this check does not apply"
		return
	fi
	[ -n "$_mv_err" ] && echo "interface error: $_mv_err"
	[ -n "$_mv_pin" ] && echo "the modem reports: $_mv_pin"
	case "$_mv_pin" in
		*pin2*) echo "  PIN2 is a service code (FDN, limits); the internet does NOT need it."
		        echo "  But umbim treats it as a blocker and fails the setup with PIN_FAILED." ;;
	esac
	[ "$_mv_log" -gt 0 ] 2>/dev/null && \
		echo "'Failed to attach to network' appears $_mv_log time(s) in the log - umbim cannot bring up the PDP context"
	if [ "$_mv_err" = PIN_FAILED ] || [ "$_mv_log" -gt 0 ] 2>/dev/null; then
		echo "  WHAT TO DO: switch the interface to the ModemManager protocol."
		echo "  On Dell DW5821e / Foxconn T77W968 modems this is the only path that works"
		echo "  (confirmed by several users): mbim and QMI on them either fail to"
		echo "  attach to the network, or give an IP with no traffic."
	else
		echo "no clear signs of either of these two traps"
	fi
}

webstack_verdict() {
	echo "--- processes ---"
	for _wv_p in uhttpd rpcd ubusd; do
		if ps w 2>/dev/null | grep -q "[${_wv_p%"${_wv_p#?}"}]${_wv_p#?}"; then
			echo "$_wv_p: running"
		else
			echo "$_wv_p: NOT RUNNING - that alone explains a dead admin page"
		fi
	done
	echo "--- does ubus answer? ---"
	_wv_t0=$(cut -d. -f1 /proc/uptime)
	if ubus call system board >/dev/null 2>&1; then
		echo "ubus: ok ($(( $(cut -d. -f1 /proc/uptime) - _wv_t0 )) c)"
	else
		echo "ubus: ERROR - rpcd/LuCI do not work without it"
	fi
	echo "--- login page ---"
	_wv_t1=$(cut -d. -f1 /proc/uptime)
	wget -q -O /dev/null -T 8 http://127.0.0.1/cgi-bin/luci/ 2>/dev/null
	_wv_c=$?
	_wv_dt=$(( $(cut -d. -f1 /proc/uptime) - _wv_t1 ))
	case "$_wv_c" in
		0) echo "LuCI answers (HTTP 200 in ${_wv_dt} s)" ;;
		8) echo "LuCI answers (login page, HTTP 403 in ${_wv_dt} s - this is normal)" ;;
		*) echo "LuCI DOES NOT ANSWER (wget rc=$_wv_c in ${_wv_dt} s)" ;;
	esac
}

policyrouting_verdict() {
	echo "--- policy routing rules (ip rule) ---"
	ip rule show 2>/dev/null
	_pr_n=$(ip rule show 2>/dev/null | wc -l)
	if [ "$_pr_n" -gt 3 ] 2>/dev/null; then
		echo "non-standard rules: $((_pr_n - 3)) - policy routing is active (mwan3?)."
		echo "If the admin page is unreachable from the LAN while the internet works, look here:"
		echo "the router's own replies may go to an uplink table that has no route back to the LAN."
		for _pr_t in $(ip rule show 2>/dev/null | sed -n 's/.*lookup \([0-9]\{1,\}\).*/\1/p' | sort -u); do
			echo "  table $_pr_t: $(ip route show table "$_pr_t" 2>/dev/null | head -3 | tr '\n' '; ')"
		done
	else
		echo "policy routing is not in use (stock rules only)"
	fi
	echo "--- mwan3 ---"
	if [ -x /etc/init.d/mwan3 ] || [ -f /etc/config/mwan3 ]; then
		echo "mwan3 is INSTALLED; status: $(mwan3 status 2>/dev/null | head -5 | tr '\n' ' ' || echo 'no answer')"
	else
		echo "mwan3 is not installed"
		ip rule show 2>/dev/null | grep -q "lookup 25[0-9]" \
			&& echo "BUT its tables (25x) are still in ip rule - policy routing is still alive!"
	fi
	echo "--- is lan in the right zone? ---"
	_pr_lz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\(@zone\[[0-9]*\]\)\.name='lan'\$/\1/p" | head -1)
	_pr_wz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	echo "lan zone input: $(uci -q get "firewall.$_pr_lz.input")"
	case " $(uci -q get "firewall.$_pr_wz.network") " in
		*" lan "*) echo "PROBLEM: the lan interface belongs to the WAN zone (input=REJECT) - the firewall cuts off the admin page" ;;
	esac
}

cap() {
	_c_t="$1"; shift
	_c_f="/tmp/5gmodem/.diagcap.$$"
	( "$@" ) > "$_c_f" 2>&1 &
	_c_p=$!
	( sleep "$_c_t"; kill -9 "$_c_p" 2>/dev/null ) >/dev/null 2>&1 &
	_c_w=$!
	wait "$_c_p" 2>/dev/null
	kill "$_c_w" 2>/dev/null; wait "$_c_w" 2>/dev/null
	cat "$_c_f" 2>/dev/null; rm -f "$_c_f"
}

usbmode_verdict() {
	_um_hit=0
	if logread 2>/dev/null | grep -q "usbmode.*sets config #0"; then
		echo "THE LOG HAS A TRACE: usbmode set config #0 on the device."
		echo "That strips the data driver: the log nearby shows 'cdc_mbim ... unregister'."
		_um_hit=1
	fi
	for _um_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].vidpid' 2>/dev/null | sort -u); do
		[ "$(jsonfilter -i /etc/usb-mode.json -e "@.devices[\"$_um_p\"][\"*\"].config" 2>/dev/null)" = "0" ] || continue
		echo "THE RULE IS STILL THERE: $_um_p has 'config: 0' in /etc/usb-mode.json -"
		echo "it will break the composition the next time the modem is plugged in."
		_um_hit=1
	done
	_um_bad=""
	for _um_mp in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_um_mp" in *-*) ;; *) continue ;; esac
		ls /sys/bus/usb/devices/"$_um_mp":*/tty/* >/dev/null 2>&1 \
			|| ls /sys/bus/usb/devices/"$_um_mp":*/*/tty/* >/dev/null 2>&1 || continue
		ls /sys/bus/usb/devices/"$_um_mp":*/net/* >/dev/null 2>&1 && continue
		ls /sys/bus/usb/devices/"$_um_mp":*/usbmisc/cdc-wdm* >/dev/null 2>&1 && continue
		_um_bad="$_um_bad $_um_mp"
	done
	if [ -n "$_um_bad" ] && [ "$_um_hit" = 1 ]; then
		echo "AND THE RESULT IS VISIBLE: the modem has AT ports but NO data channel"
		echo "(no cdc-wdm, no network device):$_um_bad"
		echo "There is nothing left to configure the interface on - that is what the config reset does."
	fi
	if [ "$_um_hit" = 0 ]; then
		echo "no traces - this section does not apply"
		[ -n "$_um_bad" ] && echo "  (the data channel of$_um_bad is lost anyway - see the section 'AT port present, data channel missing')"
		return
	fi
	echo
	echo "WHAT TO DO: the app removes the harmful rule by itself and re-applies the USB"
	echo "configuration so the kernel gives the drivers back. If that did not happen"
	echo "(an older version of the app), update and re-plug the modem."
	echo "Check by hand:  /usr/share/5gmodem/usbmode-fix.sh"
}

modem_subnet_verdict() {
	_ms=$(ip -4 addr show 2>/dev/null \
		| awk '/^[0-9]+: /{d=$2; sub(/:$/,"",d)} /inet 192\.168\.225\./{print "  " d ": " $2}')
	if [ -z "$_ms" ]; then
		echo "no interface holds an address from 192.168.225.0/24 - this section does not apply"
		return
	fi
	echo "AN ADDRESS FROM THE MODEM'S OWN SUBNET 192.168.225.0/24:"
	printf '%s\n' "$_ms"
	echo "That address comes from the modem itself (Quectel RM520N and relatives keep an"
	echo "internal bridge on 192.168.225.1/24), not from the carrier. It means the modem"
	echo "is routing and NAT-ing on its own instead of passing the carrier address through:"
	echo "the router sits behind a second NAT, and that is the usual cause of 'some sites"
	echo "open, some do not' plus broken incoming connections."
	echo "What to do: turn the modem's IP passthrough / bridge mode on (or fix it), or"
	echo "accept the double NAT knowingly. If the router LAN itself uses 192.168.225.x,"
	echo "change it: the address ranges collide."
}

uplink_verdict() {
	_uv_dump=$(ubus call network.interface dump 2>/dev/null)
	_uv_wz=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	_uv_nets=$(uci -q get "firewall.$_uv_wz.network")
	_uv_cfg=$("$RES/health.sh" getconf 2>/dev/null)
	_uv_en=$(printf '%s' "$_uv_cfg" | jsonfilter -e '@.enabled' 2>/dev/null)
	_uv_fo=$(printf '%s' "$_uv_cfg" | jsonfilter -e '@.failover' 2>/dev/null)

	_uv_get() {
		_uvg=$(printf '%s' "$_uv_dump" | jsonfilter -e "@.interface[@.interface=\"$1\"]$2" 2>/dev/null | head -1)
		[ -n "$_uvg" ] || _uvg=$(printf '%s' "$_uv_dump" | jsonfilter -e "@.interface[@.interface=\"${1}_4\"]$2" 2>/dev/null | head -1)
		printf '%s' "$_uvg"
	}
	echo "--- wan zone uplinks by priority ---"
	for _uv_n in $_uv_nets; do
		_uv_m=$(uci -q get "network.$_uv_n.metric"); [ -n "$_uv_m" ] || _uv_m=0
		_uv_d=$(_uv_get "$_uv_n" '.l3_device')
		_uv_ip=$(_uv_get "$_uv_n" '["ipv4-address"][0].address')
		_uv_h="-"
		[ -f "/tmp/5gmodem/health/$_uv_n" ] && read -r _uv_h _ _ _ _ 2>/dev/null < "/tmp/5gmodem/health/$_uv_n"
		_uv_gw=$(_uv_get "$_uv_n" '.route[@.target="0.0.0.0"].nexthop')
		_uv_note=""
		if [ -n "$_uv_d" ] && [ -n "$_uv_ip" ]; then
			ip -4 route show default 2>/dev/null | grep -qE " dev $_uv_d( |$)" \
				|| _uv_note="  NO ROUTE"
			[ -n "$_uv_note" ] && [ -z "$_uv_gw" ] && _uv_note="  NO GATEWAY (DHCP gave no router option)"
		fi
		printf 'metric %-5s %-8s %-10s %-16s watchdog: %s%s\n' \
			"$_uv_m" "$_uv_n" "${_uv_d:--}" "${_uv_ip:-no address}" "$_uv_h" "$_uv_note"
	done | sort -n -k2

	echo "--- who actually carries the default route ---"
	ip -4 route show default 2>/dev/null | sed 's/^/  /'
	_uv_ldev=$(ip -4 route show default 2>/dev/null \
		| awk '{m=0; d=""; for(i=1;i<NF;i++){if($i=="dev")d=$(i+1); if($i=="metric")m=$(i+1)+0} if(d!="")print m, d}' \
		| sort -n | head -1 | cut -d' ' -f2)
	if [ -z "$_uv_ldev" ]; then
		echo "there is NO default route at all - nobody has internet"
		return
	fi
	_uv_lif=""
	for _uv_n in $_uv_nets; do
		[ "$(_uv_get "$_uv_n" '.l3_device')" = "$_uv_ldev" ] && { _uv_lif="$_uv_n"; break; }
	done
	echo "traffic goes through: ${_uv_lif:-?} ($_uv_ldev)"
	for _uv_n in $_uv_nets; do
		_uv_d2=$(_uv_get "$_uv_n" '.l3_device'); [ -n "$_uv_d2" ] || continue
		[ "$_uv_d2" = "$_uv_ldev" ] && continue
		_uv_m2=$(uci -q get "network.$_uv_n.metric"); [ -n "$_uv_m2" ] || _uv_m2=0
		_uv_lm=$(uci -q get "network.${_uv_lif}.metric"); [ -n "$_uv_lm" ] || _uv_lm=0
		[ "$_uv_m2" -lt "$_uv_lm" ] 2>/dev/null || continue
		ip -4 route show default 2>/dev/null | grep -qE " dev $_uv_d2( |$)" && continue
		echo "  NOTE: $_uv_n ($_uv_d2) has a higher priority (metric $_uv_m2),"
		echo "  but it has no default route - there is nothing to switch over to."
		if [ -z "$(_uv_get "$_uv_n" '.route[@.target="0.0.0.0"].nexthop')" ]; then
			echo "  Cause: the network gave no gateway (no DHCP router option)."
			echo "  Fix it on the upstream router, or set the gateway statically."
		fi
	done

	_uv_ok=""
	for _uv_t in 77.88.8.8 1.1.1.1; do
		case "$(cap 6 ping -I "$_uv_ldev" -c 2 -W 2 "$_uv_t")" in
			*" 0% packet loss"*|*"1 packets received"*|*"2 packets received"*) _uv_ok=1; break ;;
		esac
	done
	if [ -n "$_uv_ok" ]; then
		echo "probe via $_uv_ldev: internet IS there"
	else
		echo "probe via $_uv_ldev: NO INTERNET - traffic goes into a hole"
		echo "  (an uplink with an address but no way out looks healthy to the kernel:"
		echo "   the route is there, so nothing will switch away on its own)"
		_uv_act=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
		_uv_endc=""
		[ -n "$_uv_act" ] && command -v mmcli >/dev/null 2>&1 \
			&& mmcli -m "$_uv_act" -K 2>/dev/null \
			| grep -q "access-technologies.value\[2\] *: *5gnr" && _uv_endc=1
		if [ -n "$_uv_endc" ]; then
			echo "  the modem runs LTE with 5G NR added (NSA): a broken NR leg gives exactly this"
			echo "  picture - an address that never carries packets. Try the 4G mode button, or"
			echo "  switch off NR bands one by one on the Frequency management page."
		fi
		if [ "$_uv_en" != "1" ]; then
			echo "  the internet watchdog is OFF - nobody is there to notice"
		elif [ "$_uv_fo" != "1" ]; then
			echo "  the watchdog is on, but 'switch traffic over' is OFF -"
			echo "  it sees the failure and deliberately does nothing"
		else
			echo "  failover is on - see below why the watchdog did not move the traffic"
		fi
	fi

	echo "--- internet watchdog ---"
	echo "settings: ${_uv_cfg:-(no answer)}"
	if [ -d /tmp/5gmodem/health ]; then
		for _uv_f in /tmp/5gmodem/health/*; do
			[ -f "$_uv_f" ] || continue
			case "$_uv_f" in */.t) continue ;; esac
			printf '  %s: %s\n' "${_uv_f##*/}" "$(cat "$_uv_f" 2>/dev/null | head -1)"
		done
	else
		echo "  no state yet - the watchdog has not completed a single round"
	fi
}

dns_verdict() {
	_dv_auto=/tmp/resolv.conf.d/resolv.conf.auto
	echo "--- local resolver (as clients see it) ---"
	cap 8 nslookup ya.ru 127.0.0.1 2>&1 | head -8
	echo "--- upstreams: whose they are and whether they answer ---"
	_dv_static=""
	for _dv_i in $(uci -q show network 2>/dev/null | sed -n 's/^network\.\([^.=]*\)=interface$/\1/p'); do
		for _dv_x in $(uci -q get "network.$_dv_i.dns" 2>/dev/null); do
			_dv_static="$_dv_static $_dv_x:$_dv_i"
		done
	done
	_dv_dead=""
	if [ -s "$_dv_auto" ]; then
		_dv_if="?"
		while read -r _dv_a _dv_b _dv_c; do
			case "$_dv_a" in
				'#') [ "$_dv_b" = "Interface" ] && _dv_if="$_dv_c"; continue ;;
				nameserver) ;;
				*) continue ;;
			esac
			_dv_s="$_dv_b"
			_dv_man=""
			case " $_dv_static " in *" $_dv_s:"*) _dv_man=1 ;; esac
			case "$(cap 6 nslookup ya.ru "$_dv_s" 2>&1)" in
				*"Address"*[0-9]*) _dv_r="answers" ;;
				*)
					if [ -n "$_dv_man" ]; then
						_dv_r="NO ANSWER"
						_dv_dead="$_dv_dead $_dv_s"
					else
						_dv_r="NO ANSWER (did the query leave through the wrong uplink?)"
					fi ;;
			esac
			[ -n "$_dv_man" ] && _dv_r="$_dv_r [set by hand]"
			printf '  %-16s from %-8s - %s\n' "$_dv_s" "$_dv_if" "$_dv_r"
		done < "$_dv_auto"
	else
		echo "  $_dv_auto is empty or missing"
	fi
	_dv_nif=$(grep "^# Interface" "$_dv_auto" 2>/dev/null | sort -u | grep -c .)
	case "$_dv_nif" in ''|*[!0-9]*) _dv_nif=0 ;; esac
	[ "$_dv_nif" -gt 1 ] && {
		echo "  $_dv_nif interfaces supply DNS servers at once - resolvers of DIFFERENT uplinks."
		echo "  A query to a foreign one leaves via another uplink's default route, and that"
		echo "  uplink drops it: to clients it looks like 'sites load every other time'."
	}
	if [ -n "$_dv_dead" ]; then
		echo "  PROBLEM: DNS servers set by hand do not answer:$_dv_dead"
		echo "  They come from the 'dns' option of the interface - the app writes it with"
		echo "  'Fallback DNS' in the modem settings. dnsmasq keeps sending queries to them,"
		echo "  and clients get no answers even though the carrier's own DNS works."
		echo "  When the carrier restricts traffic to a whitelist, foreign resolvers"
		echo "  (8.8.8.8, 1.1.1.1) are blocked. Turn 'Fallback DNS' off, or use"
		echo "  77.88.8.8 77.88.8.1 there."
	fi
	echo "--- DNS rebind protection ---"
	_dv_rb=$(logread 2>/dev/null | grep -i "rebind" | tail -20)
	if [ -n "$_dv_rb" ]; then
		_dv_names=$(printf '%s\n' "$_dv_rb" | sed -n 's/.*[Dd]etected[:,]* *//p' | sort | uniq -c)
		if [ -n "$_dv_names" ]; then
			printf '%s\n' "$_dv_names" | sed 's/^/  /'
		else
			printf '%s\n' "$_dv_rb" | tail -5 | sed 's/^/  | /'
		fi
		echo "  dnsmasq does NOT pass these names to clients: the answer held a private address."
		case "$_dv_rb" in
			*msftncsi*|*msftconnecttest*)
				echo "  ONE OF THEM IS THE WINDOWS CONNECTIVITY PROBE (msftncsi/msftconnecttest):"
				echo "  every Windows client will show 'No internet access'"
				echo "  ALL THE TIME, even while the internet works. Cure - add an exception:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftncsi.com'"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='msftconnecttest.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
		case "$_dv_rb" in
			*gstatic*|*connectivitycheck*)
				echo "  ONE OF THEM IS THE ANDROID CONNECTIVITY PROBE (connectivitycheck.gstatic.com):"
				echo "  phones on Wi-Fi will show 'Connected, no internet'."
				echo "  Cure - add an exception:"
				echo "    uci add_list dhcp.@dnsmasq[0].rebind_domain='connectivitycheck.gstatic.com'"
				echo "    uci commit dhcp && /etc/init.d/dnsmasq restart"
				;;
		esac
	else
		echo "  no hits in the log"
	fi
}

qmi_format_verdict() {
	_qf_any=""
	for _qf_n in /sys/class/net/*/qmi/raw_ip; do
		[ -f "$_qf_n" ] || continue
		_qf_any=1
		_qf_if=$(basename "$(dirname "$(dirname "$_qf_n")")")
		_qf_raw=$(cat "$_qf_n" 2>/dev/null)
		_qf_dev=$(readlink -f "/sys/class/net/$_qf_if/device" 2>/dev/null)
		_qf_wdm=""
		for _qf_w in "$(dirname "$_qf_dev")"/*/usbmisc/cdc-wdm*; do
			[ -e "$_qf_w" ] && { _qf_wdm="/dev/$(basename "$_qf_w")"; break; }
		done
		printf '%s: raw_ip=%s' "$_qf_if" "${_qf_raw:-?}"
		_qf_up=$(ubus call network.interface dump 2>/dev/null \
			| jsonfilter -e "@.interface[@.l3_device=\"$_qf_if\"].up" 2>/dev/null | head -1)
		_qf_fmt=""
		if [ -n "$_qf_wdm" ] && command -v qmicli >/dev/null 2>&1 \
		   && command -v qmi_channel_free >/dev/null 2>&1 && qmi_channel_free; then
			_qf_mb=""
			case "$(readlink -f "/sys/class/usbmisc/${_qf_wdm##*/}/device/driver" 2>/dev/null)" in
				*/cdc_mbim) _qf_mb="--device-open-mbim" ;;
			esac
			_qf_fmt=$(cap 15 qmicli -d "$_qf_wdm" $_qf_mb --wda-get-data-format 2>/dev/null \
				| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
			printf ', modem: %s' "${_qf_fmt:-no answer}"
		fi
		if [ "$_qf_up" = "true" ]; then
			case "$_qf_raw:$_qf_fmt" in
				Y:raw-ip|N:802-3|*:) : ;;
				*) printf ' <- MISMATCH: incoming packets are dropped silently' ;;
			esac
		else
			printf ' | the interface is down - the frame format is set while dialling, nothing to compare'
		fi
		_qf_rx=$(cat "/sys/class/net/$_qf_if/statistics/rx_packets" 2>/dev/null)
		_qf_tx=$(cat "/sys/class/net/$_qf_if/statistics/tx_packets" 2>/dev/null)
		printf ' | packets rx=%s tx=%s' "${_qf_rx:-?}" "${_qf_tx:-?}"
		case "$_qf_rx" in
			0|1|2|3) [ "${_qf_tx:-0}" -gt 50 ] 2>/dev/null && printf ' <- NO TRAFFIC (sent %s, received %s); the usual cause is a frame format mismatch between the driver and the firmware' "$_qf_tx" "$_qf_rx" ;;
		esac
		echo
	done
	[ -n "$_qf_any" ] || echo "no qmi interfaces - this check does not apply"
}

ttl_verdict() {
	_t_in=$(uci -q get 5gmodem.@5gmodem[0].ttl4in)
	_t_out=$(uci -q get 5gmodem.@5gmodem[0].ttl4out)
	_t_in6=$(uci -q get 5gmodem.@5gmodem[0].ttl6in)
	_t_out6=$(uci -q get 5gmodem.@5gmodem[0].ttl6out)
	if [ -z "$_t_in$_t_out$_t_in6$_t_out6" ]; then
		echo "TTL override is disabled in the settings - this section does not apply"
		echo "  (if the carrier throttles tethering, turning it on is worth a try: Network -> Modem -> TTL)"
		return 0
	fi
	echo "in the settings: in=${_t_in:-—} out=${_t_out:-—} (IPv6: in=${_t_in6:-—} out=${_t_out6:-—})"
	if ! command -v nft >/dev/null 2>&1; then
		echo "  nft is not in the image - no way to check the live rules"
		return 0
	fi
	if nft list table inet modem5g_ttl >/dev/null 2>&1; then
		echo "  the inet modem5g_ttl table IS CREATED:"
		nft -a list table inet modem5g_ttl 2>/dev/null | grep -E "ttl set|packets" | head -8
	else
		echo "  there is NO inet modem5g_ttl table - the override is enabled but NOT APPLIED."
		echo "  That is the cause if the carrier blocks tethering: the rules are"
		echo "  created by /usr/share/5gmodem/ttl.sh - check logread for its errors."
	fi
	if nft list table netdev modem5g_ttl_dev >/dev/null 2>&1; then
		echo "  the netdev modem5g_ttl_dev table (covers flow-offloaded connections) IS CREATED:"
		nft list table netdev modem5g_ttl_dev 2>/dev/null | grep -E "hook|packets" | head -8
	elif [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ]; then
		echo "  there is NO netdev modem5g_ttl_dev table while flow offloading is ON:"
		echo "  accelerated connections bypass the rules above and keep the original TTL."
	fi
}

apn_verdict() {
	_av_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	[ -n "$_av_if" ] || { echo "the modem interface is not configured - this check does not apply"; return 0; }
	_av_cur=$(uci -q get "network.$_av_if.apn")
	echo "APN on the interface: ${_av_cur:-(empty)}"
	_av_imsi=$(printf '%s' "$(cat /tmp/5gmodem/snapshot_* 2>/dev/null | head -c 4000)" \
		| sed -n 's/.*"imsi":"\([0-9]\{6,\}\)".*/\1/p' | head -1)
	[ -n "$_av_imsi" ] || _av_imsi=$(uci -q show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.apn_imsi='\([0-9]*\)'$/\1/p" | head -1)
	if [ -z "$_av_imsi" ]; then
		echo "  the IMSI is unknown - nothing to match against the database"
		return 0
	fi
	echo "IMSI: $_av_imsi (PLMN ${_av_imsi%??????????})"
	_av_db=$(awk -F'\t' -v p="${_av_imsi%??????????}" '$1 == p && $7 != "" && $7 != "-" {print $6" -> "$7}' \
		/usr/share/5gmodem/providers.tsv 2>/dev/null | head -3)
	if [ -z "$_av_db" ]; then
		echo "  the database has no entries for this PLMN - nothing to compare"
		return 0
	fi
	echo "  the database knows for this network:"
	printf '%s\n' "$_av_db" | sed 's/^/    /'
	if printf '%s\n' "$_av_db" | grep -q -- "-> *$_av_cur\$"; then
		echo "  MATCHES - the APN comes from the database"
	else
		echo "  DOES NOT MATCH. If there is no internet, start here: set an APN from"
		echo "  the list above (Network -> Modem -> Connection settings) and bring the"
		echo "  interface back up. Auto-selection leaves it alone once the APN was edited by hand."
	fi
}

fw_zone_verdict() {
	_fz=$(uci show firewall 2>/dev/null \
		| sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
	if [ -z "$_fz" ]; then
		echo "there is no wan zone at all - NAT is set up some other way, check it by hand"
		return
	fi
	_fnet=$(uci -q get "firewall.$_fz.network")
	_fmasq=$(uci -q get "firewall.$_fz.masq")
	echo "wan zone networks: $_fnet"
	echo "masq: ${_fmasq:-<not set>}"
	case "$_fnet" in
		*"'"*)
			echo "PROBLEM: a list item with an EMBEDDED space - the string 'wan wan6'"
			echo "went into the list as one piece. No network has that name, so the REAL"
			echo "wan is not in the zone and NAT does not work for it: the router itself"
			echo "reaches the internet, the LAN does not. Cure: reinstall the package (the"
			echo "uci-defaults script unglues it) or fix it by hand in Network > Firewall."
			;;
	esac
	for _fi in $(uci show 5gmodem 2>/dev/null \
		| sed -n "s/^5gmodem\.m_[^.]*\.network='\?\([^']*\)'\?\$/\1/p" | sort -u); do
		[ -n "$_fi" ] || continue
		echo " $_fnet " | grep -q " $_fi " || echo "WARNING: interface $_fi is NOT in the wan zone - no NAT"
	done
}

netifd_crash_verdict() {
	_nc_n=0
	for _nc_f in /tmp/netifd.*.core /tmp/core.netifd* /tmp/netifd.core; do
		[ -f "$_nc_f" ] || continue
		_nc_n=$((_nc_n + 1))
	done
	if [ "$_nc_n" = 0 ]; then
		echo "no netifd crash dumps in /tmp - netifd did not crash since boot (or core dumps are off)"
		return 0
	fi
	echo "PROBLEM: netifd crashed $_nc_n time(s) since boot (core dumps in /tmp):"
	ls -l /tmp/netifd.*.core /tmp/core.netifd* /tmp/netifd.core 2>/dev/null | awk '{ print "  " $6, $7, $8, $9 }'
	echo "  Every crash restarts ALL networking (LAN, Wi-Fi, uplinks). A known trigger on OpenWrt 25.12"
	echo "  (netifd 2026-02-26, fixed upstream in 2026-07) is taking down an interface whose address lives"
	echo "  on a dynamic child <iface>_4/_6 (qmi, mbim): the child is freed while netifd still uses it."
	echo "  Interfaces of this app on mbimp no longer use such children; other protocols still do."
}

usb_flap_verdict() {
	_uf_p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	[ -n "$_uf_p" ] || { echo "no active modem is selected"; return; }
	_uf_d="/sys/bus/usb/devices/$_uf_p"
	_uf_k=$(logread 2>/dev/null)
	_uf_dm=$(dmesg 2>/dev/null)
	[ "$(printf '%s\n' "$_uf_dm" | grep -c 'USB disconnect')" -gt "$(printf '%s\n' "$_uf_k" | grep -c 'USB disconnect')" ] && _uf_k="$_uf_dm"
	_uf_sp=$(cat "$_uf_d/speed" 2>/dev/null)
	_uf_pw=$(cat "$_uf_d/bMaxPower" 2>/dev/null)
	echo "link: ${_uf_sp:-?} Mbit/s, requested current: ${_uf_pw:-?}"
	case "$_uf_sp" in
		480)  echo "this is USB 2.0 High-Speed - the port supplies up to 500 mA" ;;
		5000|10000) echo "this is USB 3.x SuperSpeed - the port supplies up to 900 mA" ;;
	esac
	_uf_n=$(printf '%s\n' "$_uf_k" | grep -c "usb $_uf_p: USB disconnect")
	_uf_if=$(uci -q get "5gmodem.$(secname "$_uf_p").network" 2>/dev/null)
	echo "USB re-connects in the current log: $_uf_n"
	_uf_vp="$(cat "$_uf_d/idVendor" 2>/dev/null):$(cat "$_uf_d/idProduct" 2>/dev/null)"
	case "$_uf_vp" in
		413c:81d7|413c:81e0|0489:e0b4|0489:e0b5)
			if [ "${_uf_n:-0}" -ge 2 ]; then
				echo "NOTE for Snapdragon X20 modules (T77W968 / DW5821e): if the drops come when"
				echo "the carrier adds or removes aggregated carriers, the cause is often edited"
				echo "carrier files (NV 00028874, removed carrier policy) on second-hand modules,"
				echo "not power. Restoring the stock files or reflashing the firmware cures it."
			fi ;;
	esac
	printf '%s\n' "$_uf_k" | sed -n 's/.*usb \([0-9][^:]*\): USB disconnect.*/\1/p' \
		| sort | uniq -c | sort -rn | while read -r _c _d; do
			[ "$_d" = "$_uf_p" ] && continue
			echo "  neighbouring device $_d: $_c re-connects"
			[ "${_c:-0}" -ge 10 ] && echo "  THAT IS A LOT: the device does not stay on the bus - check power, cable and the USB composition"
		done
	_uf_ms=$(printf '%s\n' "$_uf_k" | grep -c "usb-storage $_uf_p:1\.0: USB Mass Storage device detected")
	_uf_msw=""
	if [ "${_uf_ms:-0}" -ge 1 ] && [ "${_uf_ms:-0}" -ge "${_uf_n:-0}" ]; then
		_uf_msw=1
		echo "these re-enumerations are the switch OUT OF MASS-STORAGE mode ($_uf_ms of them):"
		echo "the stick arrives as an installer disk and moves to its modem composition on"
		echo "its own. That is normal usb_modeswitch behaviour, not a power problem -"
		echo "there is nothing to fix in the cable or the power supply."
	fi

	_uf_pl=$(printf '%s\n' "$_uf_k" | grep "usb $_uf_p: New USB device found, idVendor=0e8d, idProduct=2000" \
		| sed -n 's/.*\[ *\([0-9]*\)\.[0-9]*\] usb .*/\1/p')
	_uf_plb=0; _uf_plr=0
	for _t in $_uf_pl; do
		if [ "$_t" -lt 120 ]; then _uf_plb=$((_uf_plb + 1)); else _uf_plr=$((_uf_plr + 1)); fi
	done
	if [ "$_uf_plb" -ge 1 ] && [ -z "$_uf_msw" ]; then
		echo "$_uf_plb of these re-connects are the MediaTek BOOTLOADER stage at router start (MT65xx Preloader, 0e8d:2000):"
		echo "the module passes through it on every power-up. That is normal, not a power problem."
		[ "$_uf_plr" = 0 ] && [ "$_uf_plb" -ge "${_uf_n:-0}" ] && _uf_msw=1
	fi
	if [ "$_uf_plr" -ge 1 ]; then
		echo "PROBLEM: the module REBOOTED ITSELF $_uf_plr time(s) while working (left the bus and came back through MT65xx Preloader):"
		printf '%s\n' "$_uf_k" | grep "usb $_uf_p: New USB device found, idVendor=0e8d, idProduct=2000" \
			| awk '{ if (match($0, /\[ *[0-9]+\./)) { t = substr($0, RSTART + 1, RLENGTH - 2) + 0; if (t >= 120) print "  " $1, $2, $3, $4, $5 } }'
		if logread 2>/dev/null | grep -qE '5gmodem.*(CFUN=1,1|power-cycled|rebooting the module)'; then
			echo "  our healing did reset a module in this log - compare the times above with those lines."
		else
			echo "  nothing of ours sent a reset before it: the module rebooted on its own."
			echo "  Usual causes: power sag under load (use a powered USB hub / separate 5 V),"
			echo "  overheating (add a heatsink or airflow), or a modem firmware crash."
		fi
	fi

	[ -n "$_uf_msw" ] || logread 2>/dev/null | awk -v ap="$_uf_p" -v aif="$_uf_if" '
		function t2s(t,   a) {
			if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return -1
			split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3]
		}
		/healing .*(rebooting the module|power-cycling)/ {
			if (aif == "" || index($0, "healing " aif ":") == 0) next
			s = t2s($4); if (s < 0) next
			hs = s; hhave = 1; next
		}
		/poll of .* is stuck/ {
			s = t2s($4); if (s < 0) next
			st = s; have = 1
			p = $0; sub(/.*poll of /, "", p); sub(/ .*/, "", p)
			port = p; next
		}
		/usb [0-9]+-[0-9.]+: USB disconnect/ {
			now = t2s($4); if (now < 0) next
			d = $0; sub(/.*usb /, "", d); sub(/:.*/, "", d)
			n++
			g = now - st
			hg = now - hs
			if (d == ap && hhave && hg >= 0 && hg <= 30) {
				own++
				line[n] = sprintf("  %s  usb %-8s our watchdog rebooted the module %d s before the drop", $4, d, hg)
			} else if (have && g >= 0 && g <= 120) {
				pre++
				line[n] = sprintf("  %s  usb %-8s polling of %s stalled %d s before the drop", $4, d, port, g)
			} else {
				line[n] = sprintf("  %s  usb %-8s no polling stall before this one", $4, d)
			}
		}
		END {
			if (n == 0) exit
			print "recent drops (time, device, what happened right before):"
			start = n - 7; if (start < 1) start = 1
			for (i = start; i <= n; i++) print line[i]
			if (own == n) {
				print "  EVERY DROP WAS OUR OWN WATCHDOG REBOOTING THE MODULE (healing) - not power or the cable."
				print "  Look at why the connection was considered dead: the section Why the modem does not connect."
			} else if (pre >= 2 && pre * 2 >= n) {
				print "  OUR OWN MODEM POLLING STALLED BEFORE MOST OF THE DROPS."
				print "  Check this before blaming power: the metric AT commands may be what"
				print "  knocks the module over. Experiment: /etc/init.d/5gmodem-sessionwatch stop,"
				print "  close the Network page in the browser (it polls the modem too) and wait an hour."
				print "  If the drops stop, polling is to blame - please file an issue with this observation."
			} else {
				print "  The drops do not line up with modem polling - the cause is outside the app:"
				print "  power, the cable/adapter, or the module firmware itself."
			}
		}'
	_uf_en=$(dmesg 2>/dev/null | grep -cE "unable to enumerate USB device|device not accepting address|device descriptor read.*error")
	if [ "${_uf_en:-0}" -ge 3 ]; then
		echo "  PROBLEM: the device is on the bus but DOES NOT ENUMERATE ($_uf_en errors in dmesg:"
		dmesg 2>/dev/null | grep -E "unable to enumerate|not accepting address|descriptor read.*error" | tail -3 | sed 's/^/    /'
		echo "  ). This is the physical layer - it never gets as far as the drivers or the app."
		echo "  The cure is hardware: a short, good cable with no adapters, a hub with its"
		echo "  own power supply (the router port may not have enough current to start the"
		echo "  modem), and testing the modem on a PC. As soon as dmesg shows the line"
		echo "  'new high-speed USB device', the app will pick the modem up on its own."
	fi
	if printf '%s\n' "$_uf_k" | grep -qE "HC died|Host halt failed|host controller not responding"; then
		echo "PROBLEM: the USB CONTROLLER itself (xHCI) died, not the modem."
		printf '%s\n' "$_uf_k" | grep -oE "(xhci[^:]*): (HC died[^,]*|Host halt failed, -[0-9]+|xHCI host controller not responding[^,]*)" | tail -3
		echo "The sign: ALL devices disappeared AT ONCE and the bus never came back until"
		echo "a reboot. This is NOT a power shortage - a brownout drops a single device"
		echo "and leaves error -71 / device descriptor read in the log."
		printf '%s\n' "$_uf_k" | grep -qE "NETDEV WATCHDOG.*(rndis|cdc|usb)" && {
			echo "Right before the controller died, TRANSMIT hung in the network driver"
			echo "(NETDEV WATCHDOG, transmit queue timed out) - it is the kernel trying to"
			echo "reset the endpoint that finishes the controller off."
		}
		echo "What is worth trying: (1) turn off USB autosuspend -"
		echo "  echo on > /sys/bus/usb/devices/usbN/power/control;"
		echo "(2) bring the bus back without a reboot by reloading the modules"
		echo "  (rmmod/modprobe xhci-mtk and the modem driver);"
		echo "(3) if the board serves every port from one controller (Banana Pi R4 and"
		echo "  relatives), changing the PORT will not help - it is the same controller;"
		echo "  only another controller or another board will."
		echo "Swapping the power supply or the cable makes no sense here - the log shows no brownout."
		return
	fi

	[ -n "$_uf_msw" ] && return
	[ "${_uf_n:-0}" -ge 1 ] || return
	_uf_own=$(logread 2>/dev/null | awk -v ap="$_uf_p" -v aif="$_uf_if" '
		function t2s(t,   a) {
			if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return -1
			split(t, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3]
		}
		aif != "" && index($0, "healing " aif ":") && /rebooting the module|power-cycling/ { hs = t2s($4); next }
		index($0, "usb " ap ": USB disconnect") {
			n++; g = t2s($4) - hs
			if (hs != "" && g >= 0 && g <= 30) own++
		}
		END { print (n > 0 && own == n) ? 1 : 0 }')
	if [ "$_uf_own" = 1 ]; then
		echo "Every re-enumeration follows a module reboot by our own watchdog - this is not a power problem."
		return
	fi
	echo "PROBLEM: the device disappeared from the bus and re-enumerated."
	echo "If this happens SHORTLY AFTER attaching to the network, it is almost certainly"
	echo "a power shortage: the modem draws peak current while transmitting, and the"
	echo "brownout drops the link. Check in order: another USB port (USB 3.0 is better),"
	echo "a short cable with no extensions, an adapter/hub WITH ITS OWN POWER SUPPLY."
	[ "$_uf_sp" = "480" ] && echo "Separately: the link came up as USB 2.0. If the modem supports USB 3.0, the cable or the adapter is to blame - the SuperSpeed contacts are not in use."
}

usb_unconfigured_verdict() {
	_uu_bad=""
	for _uu_d in /sys/bus/usb/devices/*; do
		_uu_b=${_uu_d##*/}
		case "$_uu_b" in *:*|usb*) continue ;; esac
		[ -f "$_uu_d/idVendor" ] || continue
		_uu_cfg=$(cat "$_uu_d/bConfigurationValue" 2>/dev/null)
		case "$_uu_cfg" in ''|0) ;; *) continue ;; esac
		_uu_bad="$_uu_bad $_uu_b"
	done
	if [ -z "$_uu_bad" ]; then
		echo "no unconfigured devices - this section does not apply"
		return
	fi
	for _uu_b in $_uu_bad; do
		_uu_d="/sys/bus/usb/devices/$_uu_b"
		echo "$_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] $(cat "$_uu_d/product" 2>/dev/null)"
		echo "  no configuration is assigned - there are no interfaces and no drivers bound"
	done
	echo "PROBLEM: the device is physically on the bus (lsusb sees it), but the kernel"
	echo "could not configure it. It has no ports, so it is missing from the modem list too."
	_uu_rb=""
	for _uu_b in $_uu_bad; do
		_uu_k=$(printf '%s' "$_uu_b" | tr -c 'A-Za-z0-9' '_')
		{ [ -f "/var/run/5gmodem-mm-inhibit/$_uu_k.rebindfail" ] || \
		  [ -f "/tmp/5gmodem/mmrebind_$_uu_k" ]; } && _uu_rb=1
	done
	if [ -n "$_uu_rb" ]; then
		echo "NOTE: the app RECENTLY re-bound this USB device"
		echo "(mm_recover_missing: ModemManager did not assemble the modem). It looks like"
		echo "unbind/bind did not bring it back - usually that is 'can't set config #1, error -71'."
		echo "CURE: POWER THE ROUTER OFF (pull the power for a few seconds - not a reboot)."
		echo "For such a modem it is worth choosing the QMI protocol instead of ModemManager -"
		echo "then re-binding will never touch it again."
	else
		echo "This is NOT an app bug and NOT a power problem."
	fi
	_uu_why=$(dmesg 2>/dev/null | grep -E "Not enough host controller resources|Not enough bandwidth|can't set config" | tail -4)
	[ -n "$_uu_why" ] && { echo "From the kernel log:"; printf '%s\n' "$_uu_why" | sed 's/^/  /'; }
	if dmesg 2>/dev/null | grep -q "Not enough host controller resources"; then
		echo "The kernel named the cause outright: the CONTROLLER ran out of resources"
		echo "(endpoints). Who took them is visible from the interface count:"
		for _uu_d in /sys/bus/usb/devices/*; do
			_uu_b=${_uu_d##*/}
			case "$_uu_b" in *:*|usb*) continue ;; esac
			[ -f "$_uu_d/idVendor" ] || continue
			_uu_n=0
			for _uu_i in "$_uu_d":*; do [ -d "$_uu_i" ] && _uu_n=$((_uu_n + 1)); done
			echo "  $_uu_b [$(cat "$_uu_d/idVendor" 2>/dev/null):$(cat "$_uu_d/idProduct" 2>/dev/null)] interfaces: $_uu_n"
		done
		echo "Modules with RNDIS and a pile of ttyUSB ports (Fibocom FM350 - 10 interfaces,"
		echo "7 of them serial) cost the most; a modem in MBIM costs 2."
		echo "What is worth trying: (1) remove a spare device from this controller;"
		echo "(2) remember that DIFFERENT HUBS, and even different buses of one controller,"
		echo "  do NOT split the budget - changing the socket alone cures nothing;"
		echo "(3) switch to a leaner USB composition if the module can do it"
		echo "  (on the FM350 both compositions, 40 and 41, are equally hungry)."
	elif dmesg 2>/dev/null | grep -q "Not enough bandwidth"; then
		echo "The kernel blamed bus BANDWIDTH, not controller resources:"
		echo "the device did not get enough periodic bandwidth. What helps is spreading"
		echo "the devices over different controllers, or lowering the link speed."
	fi
}

fastboot_verdict() {
	_fb=""
	_fb_nl='
'
	for _fb_d in /sys/bus/usb/devices/[0-9]*; do
		[ -f "$_fb_d/idVendor" ] || continue
		_fb_id="$(cat "$_fb_d/idVendor" 2>/dev/null):$(cat "$_fb_d/idProduct" 2>/dev/null)"
		case "$_fb_id" in
			413c:81e1|05c6:9008|1199:9070)
				_fb="$_fb  $_fb_id $(cat "$_fb_d/manufacturer" 2>/dev/null) $(cat "$_fb_d/product" 2>/dev/null)$_fb_nl" ;;
			*)
				if [ "$(cat "$_fb_d/bNumInterfaces" 2>/dev/null | tr -d ' ')" = "1" ]; then
					for _fb_i in "$_fb_d":*.0; do
						[ -f "$_fb_i/bInterfaceSubClass" ] || continue
						[ "$(cat "$_fb_i/bInterfaceClass" 2>/dev/null)" = "ff" ] || continue
						[ "$(cat "$_fb_i/bInterfaceSubClass" 2>/dev/null)" = "42" ] || continue
						[ "$(cat "$_fb_i/bInterfaceProtocol" 2>/dev/null)" = "03" ] || continue
						[ -e "$_fb_i/driver" ] && continue
						_fb="$_fb  $_fb_id $(cat "$_fb_d/manufacturer" 2>/dev/null) $(cat "$_fb_d/product" 2>/dev/null) (fastboot composition)$_fb_nl"
					done
				fi ;;
		esac
	done
	if [ -z "$_fb" ]; then
		echo "no modems in bootloader mode"
		return
	fi
	printf '%s' "$_fb"
	echo "PROBLEM: the device exposes a BOOTLOADER composition (fastboot/EDL) instead of"
	echo "a modem - hence no ports, and it never shows up in the modem list."
	echo "On the Huasifei WH3000 Pro board (M.2 slot) the cause is hardware: pin 67 is"
	echo "tied to ground, and the modem enters the bootloader on EVERY boot."
	echo "Since version 2.4.27 the app brings such a modem out of the bootloader BY ITSELF,"
	echo "without the fastboot package (OpenWrt feeds do not carry one): the protocol"
	echo "command is sent over usb-serial (on hotplug, at most once a minute,"
	echo "up to 3 attempts; switch it off with: uci set"
	echo "5gmodem.@5gmodem[0].fastboot_rescue='0'). EDL (05c6:9008) is never"
	echo "touched. The app never puts a modem INTO the bootloader: flashing modes"
	echo "are not our business."
}

power_state_verdict() {
	_ps_at=$(uci -q get 5gmodem.@5gmodem[0].at_port)
	if [ -n "$_ps_at" ] && [ -e "$_ps_at" ] && command -v sms_tool >/dev/null 2>&1; then
		_ps_rf=$(at_query "$_ps_at" "AT+RFPIN_STATUS?" 8 2>/dev/null | tr -d '\r')
		case "$_ps_rf" in
			*RFPIN*|*"RF HW key"*) ;;
			*) _ps_rf=$(at_query "$_ps_at" "AT^RFPIN_STATUS?" 8 2>/dev/null | tr -d '\r') ;;
		esac
		case "$_ps_rf" in
			*"pull down"*)
				echo "PROBLEM (HARDWARE): the modem reports its radio-disable pin is pulled down"
				echo "(AT+RFPIN_STATUS? -> 'RF HW key is pull down'). That is the W_DISABLE# pin on"
				echo "M.2: while it is held, no software can switch the radio on."
				echo "Check:"
				echo "  - the radio-disable switch/jumper on the M.2 adapter;"
				echo "  - power: behind a USB hub the modem shares the port's 500 mA, while its"
				echo "    peak draw is over an amp - a sagging supply makes adapters pull the pin."
				;;
			*"pull up"*) echo "radio-disable pin (W_DISABLE#): released - the hardware allows the radio" ;;
		esac
	fi
	command -v mmcli >/dev/null 2>&1 || { echo "no mmcli - nothing to check with"; return; }
	_ps_i=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
	[ -n "$_ps_i" ] || { echo "the modem is not registered in ModemManager - this check does not apply"; return; }
	_ps_k=$(mmcli -m "$_ps_i" -K 2>/dev/null)
	_ps_p=$(printf '%s\n' "$_ps_k" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
	_ps_s=$(printf '%s\n' "$_ps_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
	echo "power-state: ${_ps_p:-?}   state: ${_ps_s:-?}"
	case "$_ps_p" in
		low|off)
			if logread 2>/dev/null | grep -q "hardware radio switch is OFF"; then
				echo "PROBLEM (HARDWARE): the firmware reports that the radio is switched off"
				echo "by the hardware switch (pin W_DISABLE# on M.2). Software cannot cure"
				echo "this - neither AT, nor qmicli, nor reboots will help."
				echo "Check:"
				echo "  - the radio-disable switch/jumper on the M.2 adapter;"
				echo "  - power: behind a USB hub the modem shares the port's 500 mA, while its"
				echo "    peak draw is over an amp - connect the adapter directly or through a"
				echo "    hub with its own power supply;"
				echo "  - after changing power or port, fully re-plug the modem."
				return
			fi
			echo "PROBLEM: the modem radio is off. While it stays in this state, no protocol"
			echo "will bring the connection up, and the log will show an endless"
			echo "'couldn't enable the modem: Invalid transition' is a consequence, not the cause."
			echo "Cures, from least to most effort:"
			echo "  mmcli -m $_ps_i --set-power-state-on   (then ifup the interface you need)"
			echo "  or over AT on its port:  sms_tool -d <port> at \"AT+CFUN=1\""
			echo "  or cut power to the modem - some firmwares wake up no other way."
			;;
	esac
}

proxy_verdict() {
	echo ""
	echo "----- Fight over the control channel (verdict) -----"
	_pv_p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
	if [ -n "$_pv_p" ]; then
		_pv_nodes=""
		for _pv_n in /sys/bus/usb/devices/"$_pv_p":*/net/* /sys/bus/usb/devices/"$_pv_p":*/usbmisc/*; do
			[ -e "$_pv_n" ] && _pv_nodes="$_pv_nodes ${_pv_n##*/}"
		done
		_pv_ifs=$(uci -q show network 2>/dev/null | awk -F"[.=]" -v p="$_pv_p" -v nodes="$_pv_nodes" -v pre="^($(proto_re modem)|dhcp)\$" '
			BEGIN { n = split(nodes, a, " "); for (i = 1; i <= n; i++) nd[a[i]] = 1 }
			$3 == "proto" { v = $0; sub(/^[^=]*=/, "", v); gsub(/'"'"'/, "", v); proto[$2] = v }
			$3 == "auto" { v = $0; sub(/^[^=]*=/, "", v); gsub(/'"'"'/, "", v); off[$2] = (v == "0") }
			$3 == "devpath" || $3 == "device" || $3 == "modem_path" {
				v = $0; sub(/^[^=]*=/, "", v); gsub(/'"'"'/, "", v)
				if (v == p || v ~ ("/" p "$") || v ~ ("/" p "[:/]")) hit[$2] = 1
				sub(/^\/dev\//, "", v); if (v in nd) hit[$2] = 1
			}
			END {
				for (i in hit) if (!off[i] && proto[i] ~ pre)
					printf "%s(%s) ", i, proto[i]
			}')
		set -- $_pv_ifs
		if [ "$#" -ge 2 ]; then
			echo "PROBLEM: $# interfaces work the SAME modem $_pv_p: $_pv_ifs"
			echo "  Each of them dials and hangs up on its own, so the modem keeps dropping"
			echo "  the session. Keep ONE (the one the app shows) and delete the rest in"
			echo "  Network > Interfaces, or: uci delete network.<name>; uci commit network; /etc/init.d/network reload"
		fi
	fi
	_pv=$(ps w 2>/dev/null | grep -E "mbim-proxy|qmi-proxy" | grep -v grep)
	if [ -z "$_pv" ]; then
		echo "no proxy processes - the channel is free"
		return
	fi
	printf '%s\n' "$_pv"
	_pvproto=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null)
	if proto_in direct "$_pvproto"; then
		echo "WARNING: the interface runs protocol '$_pvproto', which opens"
		echo "  /dev/cdc-wdm* directly, while the proxy above holds the same device."
		echo "  That is what produces 'mbim message timeout'. Cure: killall mbim-proxy qmi-proxy,"
		echo "  then ifup the interface you need."
	else
		echo "(interface protocol '$_pvproto' - a proxy usually does not bother it)"
	fi
}

stick_verdict() {
	echo ""
	echo "----- Is the modem stuck in mass-storage mode? (verdict) -----"
	_sv_found=""
	for _sv_d in /sys/bus/usb/devices/*; do
		case "$_sv_d" in *:*) continue ;; esac
		[ -f "$_sv_d/idVendor" ] || continue
		_sv_v=$(cat "$_sv_d/idVendor" 2>/dev/null)
		case "$_sv_v" in
			12d1|19d2|1bbb|0af0|2001|1c9e|05c6|1e0e|2020) ;;
			*) continue ;;
		esac
		_sv_ok=""
		for _sv_n in "$_sv_d":*/ttyUSB* "$_sv_d":*/tty/ttyUSB* "$_sv_d":*/ttyACM* \
		             "$_sv_d":*/usbmisc/cdc-wdm* "$_sv_d":*/net/*; do
			[ -e "$_sv_n" ] && { _sv_ok=1; break; }
		done
		[ -n "$_sv_ok" ] && continue
		_sv_p=$(basename "$_sv_d")
		if "$RES/listmodems.sh" 2>/dev/null | grep -q "\"path\":\"$_sv_p\""; then
			continue
		fi
		for _sv_i in "$_sv_d":*; do
			[ -f "$_sv_i/bInterfaceClass" ] || continue
			case "$(cat "$_sv_i/bInterfaceClass" 2>/dev/null)" in
				08) _sv_found="$_sv_found
   $(basename "$_sv_d")  $_sv_v:$(cat "$_sv_d/idProduct" 2>/dev/null)" ;;
			esac
		done
	done
	if [ -z "$_sv_found" ]; then
		echo "no - no modem is stuck in mass-storage mode"
		return
	fi
	echo "YES, the device shows up as a USB mass-storage device and has no modem ports:"
	printf '%s\n' "$_sv_found" | sed '/^[[:space:]]*$/d'
	echo "  usb_modeswitch is supposed to switch it. Check:"
	echo "    /etc/init.d/usbmode enable; /etc/init.d/usbmode start"
	echo "  and that usb-modeswitch, kmod-usb-net-cdc-ether,"
	echo "  kmod-usb-serial-option."
}

usbcomp_verdict() {
	echo ""
	echo "----- AT port present, data channel missing? (verdict) -----"
	_uc_found=""
	_uc_stolen=""
	_uc_free=""
	_uc_vids=""
	_uc_newid=""
	for _uc_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
		case "$_uc_p" in *-*) ;; *) continue ;; esac
		_uc_d="/sys/bus/usb/devices/$_uc_p"
		[ -f "$_uc_d/idVendor" ] || continue
		_uc_v=$(cat "$_uc_d/idVendor" 2>/dev/null)
		_uc_i=$(cat "$_uc_d/idProduct" 2>/dev/null)
		_uc_tty=""; _uc_wdm=""; _uc_net=""
		for _uc_n in "$_uc_d":*/ttyUSB* "$_uc_d":*/tty/ttyUSB* "$_uc_d":*/tty/ttyACM*; do
			[ -e "$_uc_n" ] && { _uc_tty=1; break; }
		done
		for _uc_n in "$_uc_d":*/usbmisc/cdc-wdm*; do
			[ -e "$_uc_n" ] && { _uc_wdm=1; break; }
		done
		for _uc_n in "$_uc_d":*/net/*; do
			[ -e "$_uc_n" ] && { _uc_net=1; break; }
		done
		[ -n "$_uc_tty" ] || continue
		[ -z "$_uc_wdm" ] && [ -z "$_uc_net" ] || continue
		_uc_found="$_uc_found
   $_uc_p  $_uc_v:$_uc_i"
		_uc_vids="$_uc_vids $_uc_v"
		for _uc_if in "$_uc_d":*; do
			[ -f "$_uc_if/bInterfaceClass" ] || continue
			[ -e "$_uc_if/driver" ] && continue
			[ "$(cat "$_uc_if/bInterfaceClass")" = "ff" ] || continue
			[ "$(cat "$_uc_if/bNumEndpoints" 2>/dev/null)" = "03" ] || continue
			_uc_free="$_uc_free
   $_uc_p  $_uc_v:$_uc_i  interface ${_uc_if##*.} (vendor class, 3 endpoints) has no driver"
			_uc_newid="$_uc_v $_uc_i"
		done
		_uc_num=$("$RES/usbports.sh" dataif "$_uc_v" "$_uc_i" 2>/dev/null)
		[ -n "$_uc_num" ] || continue
		for _uc_if in "$_uc_d":*."$_uc_num"; do
			[ -f "$_uc_if/bInterfaceNumber" ] || continue
			_uc_drv=$(basename "$(readlink -f "$_uc_if/driver" 2>/dev/null)" 2>/dev/null)
			case "$_uc_drv" in
				option1|usb_serial_generic|usbserial_generic|generic|option)
					_uc_stolen="$_uc_stolen
   $_uc_p  $_uc_v:$_uc_i  interface $_uc_num held by driver $_uc_drv" ;;
			esac
		done
	done
	if [ -z "$_uc_found" ]; then
		echo "no - every modem with an AT port has its data channel"
		return
	fi
	echo "YES, the modem has ttyUSB ports but neither cdc-wdm nor a network device:"
	printf '%s\n' "$_uc_found" | sed '/^[[:space:]]*$/d'
	if [ -n "$_uc_stolen" ]; then
		echo ""
		echo "CAUSE FOUND: the composition DOES have a data channel, but its interface"
		echo "was taken by the serial-port driver: it is handed the whole vendor class"
		echo "and cannot tell the channel from an ordinary port:"
		printf '%s\n' "$_uc_stolen" | sed '/^[[:space:]]*$/d'
		echo "  This happens after the modem re-enumerates while its ports are bound"
		echo "  dynamically (new_id). We never touch a device whose channel is alive,"
		echo "  but the same new_id line is often kept in rc.local by hand, and the"
		echo "  kernel cannot take it back - usb-serial has no remove_id."
		echo "  CURED WITHOUT A REBOOT: the app returns the interface to its native"
		echo "  driver by itself, every time the device appears on the bus."
		echo "  Check by hand:  /usr/share/5gmodem/usbports.sh rescue"
		echo "  If your rc.local carries a port-binding line, better remove it:"
		echo "  the app sets the ports up on its own."
		return
	fi
	if [ -n "$_uc_free" ]; then
		echo ""
		echo "An interface that looks like a data channel is left without a driver:"
		printf '%s\n' "$_uc_free" | sed '/^[[:space:]]*$/d'
		echo "  The kernel does not know this vid:pid. Check by hand, until reboot:"
		echo "    echo \"$_uc_newid\" > /sys/bus/usb/drivers/qmi_wwan/new_id"
		echo "  If cdc-wdm appears but QMI does not answer, the modem itself does not"
		echo "  route data to USB (e.g. firmware set up for PCIe) - see its dmesg."
		return
	fi
	case "$_uc_vids" in
		*2c7c*|*1e0e*) ;;
		*)
			echo "  The USB composition carries no data channel. Switch the modem to a"
			echo "  composition with QMI, MBIM or NCM (a vendor AT command, then power-cycle"
			echo "  the modem). Which commands exist depends on the vendor and the firmware;"
			echo "  do not guess - check AT+CLAC or the modem's documentation."
			return
			;;
	esac
	echo "  The USB composition carries no data channel. The cure is a vendor command"
	echo "  in the AT console, after which the modem must be POWER-CYCLED:"
	echo "    Quectel: AT+QCFG=\"usbnet\"      -> a composition WITH a data channel is needed:"
	echo "             0 (NDIS/QMI) and 2 (MBIM) both carry one, 1 (ECM) and 3 (RNDIS) do not."
	echo "             Set it with AT+QCFG=\"usbnet\",0 (or ,2), then AT+CFUN=1,1 or a power-cycle:"
	echo "             until the module restarts nothing changes at all, not even the port list."
	echo "    SimCom:  AT+CUSBPIDSWITCH?      -> must be 9001, otherwise"
	echo "             AT+CUSBPIDSWITCH=9001,1,1"
}

radio_verdict() {
	echo ""
	echo "----- Radio state (verdict) -----"
	if [ -z "$1" ]; then
		_rvi=$("$RES/modemswitch.sh" mmindex 2>/dev/null)
		if [ -n "$_rvi" ]; then
			_rvk=$(mmcli -m "$_rvi" -K 2>/dev/null)
			_rvp=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
			_rvs=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
			_rvf=$(printf '%s\n' "$_rvk" | sed -n 's/^modem\.generic\.state-failed-reason *: *//p' | head -1)
			echo "No AT port - taking the state from ModemManager."
			case "$_rvp" in
				on)  echo "radio power: on (normal)" ;;
				low) echo "radio power: LOW POWER - the equivalent of CFUN=4, no connection will come up" ;;
				off) echo "radio power: OFF - the radio is switched off" ;;
				*)   echo "radio power: ${_rvp:-unknown}" ;;
			esac
			echo "modem state: ${_rvs:-unknown}"
			case "$_rvf" in
				''|--) ;;
				sim-missing) echo "FAILURE REASON: NO SIM DETECTED - check the card and the tray" ;;
				esim-without-profiles)
					echo "FAILURE REASON: AN EMPTY eSIM SLOT IS ACTIVE - the chip holds no profiles,"
					echo "  and ModemManager refuses to bring the modem up. Cure: switch to the"
					echo "  physical SIM slot (Network page -> SIM/eSIM buttons), or download a"
					echo "  profile onto the chip." ;;
				*) echo "FAILURE REASON: $_rvf" ;;
			esac
			return
		fi
		echo "No AT port and no modem in ModemManager - nothing to check with"
		return
	fi
	_rv=$(at_query "$1" "AT+CFUN?" 6 \
		| sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' | head -1)
	if [ -z "$_rv" ] && [ -s "$SESS" ]; then
		_rv=$(sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' "$SESS" 2>/dev/null | head -1)
		[ -n "$_rv" ] && echo "(the repeated AT+CFUN? got no answer - the port was busy; the value below is the one from the 'AT AT+CFUN?' section above)"
	fi
	case "$_rv" in
		1)  echo "CFUN=1 - the radio is on (normal)" ;;
		0)  echo "CFUN=0 - THE RADIO IS OFF: no protocol will bring the connection up"
		    echo "    Often this is a LEFTOVER of an aborted dial, not somebody's choice: on"
		    echo "    giving up, the protocol turns the radio off while tearing the session"
		    echo "    down. A module reboot turns it back on - AT+CFUN=1,1 or the 'Reboot modem' button." ;;
		4)  echo "CFUN=4 - airplane mode: no connection will come up" ;;
		5)  echo "CFUN=5 - FACTORY TEST MODE (FTM): the radio is not in service, no data will work"
		    echo "    Quectel: AT+QRFTESTMODE? answering 1 confirms it; Foxconn/Dell: AT+FTM? -> 'Device is in: 1, FTM'."
		    echo "    Quectel: AT+CFUN=1 then reboot the module. T77W968/DW5821e: at^nv=2497,1,\"01\" followed by AT+CFUN=1,1"
		    echo "    (alternative: AT^qtuner_enable=0); also remove the Dell firmware updater from the PC - it re-arms FTM."
		    echo "    On late eSIM batches this often does not help; the forum reports only a QPST NV/EFS restore working." ;;
		7)  echo "CFUN=7 - THE FIRMWARE DOES NOT MATCH THE CALIBRATION DATA (EFS/QCN), or the"
		    echo "    power amplifier failed. On Quectel this is what a cross-revision flash"
		    echo "    leaves behind: the image was written, the QCN stayed from another branch."
		    echo "    The radio will not come up in this state and no setting cures it."
		    echo "    The cure is to restore a QCN of the matching firmware version (QFIL ->"
		    echo "    QCN Backup Restore), ideally the backup taken from THIS module."
		    echo "    Foxconn T99W373/MV32-W often arrives in this state: only T99W373_Recovery"
		    echo "    (Full Restore over ADB) cures it, a normal reflash does not." ;;
		'') echo "CFUN could not be read (the port is busy or the modem is silent)" ;;
		*)  echo "CFUN=$_rv - NOT full functionality, CFUN=1 is expected: data may not work" ;;
	esac
}

at_conn_verdict() {
	[ -n "$1" ] || { echo "    No AT port - nothing to ask the modem with, the cause cannot be named"; return; }
	_ac_reg=$(at_query "$1" "AT+CEREG?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
	[ -n "$_ac_reg" ] || _ac_reg=$(at_query "$1" "AT+CREG?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
	_ac_att=$(at_query "$1" "AT+CGATT?" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CGATT: *\([0-9]*\).*/\1/p' | head -1)
	_ac_csq=$(at_query "$1" "AT+CSQ" 8 2>/dev/null | tr -d '\r' \
		| sed -n 's/^+CSQ: *\([0-9]*\).*/\1/p' | head -1)
	_ac_raw_ops=$(at_query "$1" "AT+COPS?" 8 2>/dev/null | tr -d '\r')
	_ac_ops=$(printf '%s\n' "$_ac_raw_ops" \
		| sed -n 's/^+COPS:.*,"\([^"]*\)".*/\1/p' | head -1)
	_ac_copsmode=$(printf '%s\n' "$_ac_raw_ops" \
		| sed -n 's/^+COPS: *\([0-9]*\).*/\1/p' | head -1)

	_ac_dbm=""
	case "$_ac_csq" in
		''|99) ;;
		*[!0-9]*) ;;
		*) _ac_dbm=$((-113 + 2 * _ac_csq)) ;;
	esac
	echo "    signal: ${_ac_csq:-no answer}${_ac_dbm:+ (~${_ac_dbm} dBm)}, operator: ${_ac_ops:-empty}, +CGATT: ${_ac_att:-no answer}"

	_ac_ifn=$(uci -q get 5gmodem.@5gmodem[0].network)
	_ac_ifst=""
	[ -n "$_ac_ifn" ] && _ac_ifst=$(ubus call "network.interface.$_ac_ifn" status 2>/dev/null)
	_ac_ifip=$(printf '%s' "$_ac_ifst" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -n "$_ac_ifip" ] || [ -z "$_ac_ifn" ] || _ac_ifip=$(ubus call "network.interface.${_ac_ifn}_4" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	_ac_ill=""
	if [ -z "$_ac_ifip" ] && [ "$_ac_att" != "1" ]; then
		printf '%s' "$_ac_ifst" | grep -q "SIM_ILLEGAL_STATE" && _ac_ill=1
		if [ -z "$_ac_ill" ]; then
			logread 2>/dev/null | tail -200 | grep -q "SIM in illegal state" && _ac_ill=1
		fi
	fi
	if [ -n "$_ac_ill" ]; then
		echo "    THE CARD IS IN THE illegal STATE - and that is most likely the main cause."
		echo "    On seeing illegal, the qmi protocol power-cycles the slot every ~8 s and"
		echo "    tries again. A card that needs 1-2 minutes to initialise NEVER gets the"
		echo "    chance - and changing the protocol (MBIM or any other) does not cure it."
		echo "    Only a module reboot followed by a wait clears illegal:"
		echo "      sms_tool -d ${1:-<AT port>} at \"AT+CFUN=1,1\"   and WAIT ~2 minutes"
		echo "    The 'Reboot modem' button on the Modem page does the same thing,"
		echo "    and the internet watchdog does it on its own (the 'reboot the module' step)."
		echo "    If the card was moved between slots, check the 'SIM slots' section first:"
		echo "    the active slot must be the one the card sits in."
	fi

	case "$_ac_reg" in
		1|6|9)
			if [ "$_ac_att" = "1" ]; then
				_ac_if="$_ac_ifn"
				_ac_up="$_ac_ifip"
				if [ -n "$_ac_up" ]; then
					_ac_hst=""
					[ -f "/tmp/5gmodem/health/$_ac_if" ] \
						&& read -r _ac_hst _ _ _ _ 2>/dev/null < "/tmp/5gmodem/health/$_ac_if"
					if [ "$_ac_hst" = down ]; then
						echo "    the modem DID connect: address $_ac_up on interface $_ac_if."
						echo "    So the dial-up is not the problem - the packets are lost further on."
						echo "    See the sections 'Who holds the internet' and 'DNS'."
					else
						echo "    the connection works: address $_ac_up on interface $_ac_if - question closed."
					fi
				else
					echo "    registered and attached to the packet network - the radio is fine."
					echo "    Since there is still no address, the cause is further on: APN, PDP type or netifd."
				fi
			else
				echo "    registered, but NOT attached to the packet network (+CGATT: 0)."
				echo "    That is the APN or the PDP type, not the antennas: check the APN with the"
				echo "    carrier and try IPV4V6 - some modules refuse to activate a plain IPV4 context."
			fi ;;
		5|7|10)
			echo "    registered IN ROAMING (stat $_ac_reg). If the roaming switch is off, the"
			echo "    connection is refused on purpose - a guard against a data bill." ;;
		2)
			echo "    NO NETWORK FOUND: the modem is searching (+CEREG stat 2) and cannot register."
			echo "    No APN or PDP type gets around this - a network has to appear first." ;;
		3)
			echo "    THE NETWORK REFUSED REGISTRATION (+CEREG stat 3). This is not the antennas:"
			echo "    that is the answer for an unregistered SIM, an unpaid plan or a blocked"
			echo "    IMEI. Try the same SIM in a phone." ;;
		0|4)
			echo "    NOT REGISTERED (+CEREG stat ${_ac_reg}) and no search is running."
			if [ "$_ac_copsmode" = "2" ]; then
				echo "    CAUSE FOUND: +COPS: 2 - the modem was deregistered BY A COMMAND."
				echo "    Until AT+COPS=0 is issued it will not even start searching."
				echo "    Usually a leftover of an aborted dial loop (xmm)."
				echo "    The app watchdog restores registration by itself; by hand:"
				echo "    sms_tool -d $1 at \"AT+COPS=0\""
			else
				echo "    Check the network mode (locked to an unavailable RAT?), the bands and CFUN."
			fi ;;
		8)
			echo "    emergency calls only (+CEREG stat 8) - there is no normal network for data." ;;
		'')
			echo "    the registration state could not be read - the port is busy or the modem is silent." ;;
		*)
			echo "    +CEREG stat $_ac_reg" ;;
	esac

	case "$_ac_reg" in
		1|5|6|7|9|10) ;;
		*)
			if [ -n "$_ac_dbm" ] && [ "$_ac_dbm" -le -100 ]; then
				echo "    THE SIGNAL IS ON THE FLOOR (~${_ac_dbm} dBm). Antennas first: are they screwed"
				echo "    on, in the right sockets (main/aux, not GNSS), is the pigtail intact."
			fi ;;
	esac
}

mm_fail_verdict() {
	echo ""
	echo "----- Why the modem does not connect (verdict) -----"
	if ! command -v mmcli >/dev/null 2>&1; then
		echo "ModemManager is not installed - working it out over AT:"
		at_conn_verdict "$1"
		return
	fi
	_mf_l=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p')
	[ -n "$_mf_l" ] || { echo "ModemManager has no modems at all - working it out over AT:"; at_conn_verdict "$1"; return; }
	for _mf_i in $_mf_l; do
		_mf_k=$(mmcli -m "$_mf_i" -K 2>/dev/null)
		_mf_d=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.device *: *//p' | head -1)
		_mf_s=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state *: *//p' | head -1)
		_mf_r=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.state-failed-reason *: *//p' | head -1)
		_mf_sim=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.sim *: *//p' | head -1)
		echo "### modem $_mf_i (${_mf_d##*/}): state $_mf_s"
		case "$_mf_s" in
			connected)
				_mf_if=$(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)\.device='\(.*\)'$/\1 \2/p" \
					| while read -r _mf_s1 _mf_d1; do [ "$_mf_d1" = "$_mf_d" ] && echo "$_mf_s1"; done | head -1)
				_mf_ifs=""
				[ -n "$_mf_if" ] && _mf_ifs=$(ifstatus "$_mf_if" 2>/dev/null)
				case "$_mf_ifs" in
					''|*'"up": true'*) echo "    normal - the connection is established" ;;
					*DISCONNECT_FAILED*)
						echo "    PROBLEM: ModemManager says 'connected', but interface $_mf_if is DOWN."
						echo "    A disconnect failed, MM kept a dead bearer and refuses every new connect"
						echo "    ('Operation not allowed while modem is connected'). Only a modem reset clears it:"
						echo "    mmcli -m $_mf_i --reset, wait a minute, then ifup $_mf_if." ;;
					*) echo "    ModemManager says 'connected', but interface $_mf_if is down - see the netifd log below" ;;
				esac ;;
			registered|enabled) echo "    the radio is ready but there is no data session: check the APN and netifd" ;;
			failed)
				case "$_mf_r" in
					sim-missing)
						echo "    NO SIM DETECTED. This is hardware, not settings:"
						echo "    check that the card is there, the right way round and seated in the tray,"
						echo "    and on dual-slot modules - that the active slot is the one holding the card." ;;
					sim-error|sim-wrong) echo "    SIM ERROR ($_mf_r) - the card cannot be read: contacts, or try another card" ;;
					esim-without-profiles)
						echo "    AN EMPTY eSIM SLOT IS ACTIVE: the chip holds no profiles, and MM"
						echo "    refuses to bring the modem up - hence the 'endless network search'."
						echo "    What to do: make the physical SIM slot active again (the SIM/eSIM"
						echo "    buttons on the Network page); to download a profile, first hide the"
						echo "    modem from MM (the 'Hide from ModemManager' checkbox)."
						echo "    The slots and their contents are in the 'SIM slots' section below." ;;
					unknown-capabilities) echo "    MM could not determine the modem capabilities - usually an AT-only assembly (see the cdc-wdm section)" ;;
					''|--) echo "    state failed with no reason given" ;;
					*) echo "    failure reason: $_mf_r" ;;
				esac ;;
			locked) echo "    the modem is locked (PIN/PUK) - see unlock-required in the dump" ;;
			disabled) echo "    the modem is disabled: netifd has not enabled it yet, or it was disabled by hand" ;;
			*) echo "    state: $_mf_s" ;;
		esac
		_mf_pw=$(printf '%s\n' "$_mf_k" | sed -n 's/^modem\.generic\.power-state *: *//p' | head -1)
		if [ "$_mf_pw" = "low" ] && { [ "$_mf_s" = "enabling" ] || [ "$_mf_s" = "disabled" ] || [ "$_mf_s" = "failed" ]; }; then
			_mf_vp=$(printf '%s\n' "$_mf_k" | sed -n 's#^modem\.generic\.device *: .*/\([0-9.-]*\)$#\1#p' | head -1)
			_mf_vid=""; _mf_pid=""
			if [ -n "$_mf_vp" ] && [ -r "/sys/bus/usb/devices/$_mf_vp/idVendor" ]; then
				_mf_vid=$(cat "/sys/bus/usb/devices/$_mf_vp/idVendor")
				_mf_pid=$(cat "/sys/bus/usb/devices/$_mf_vp/idProduct")
			fi
			echo "    LOOKS LIKE AN FCC LOCK: radio power is 'low' and enabling does not go through."
			_mf_av=/usr/share/ModemManager/fcc-unlock.available.d
			_mf_en=/etc/ModemManager/fcc-unlock.d
			if [ -d "$_mf_av" ]; then
				_mf_script=""
				[ -n "$_mf_vid" ] && [ -e "$_mf_av/$_mf_vid:$_mf_pid" ] && _mf_script="$_mf_vid:$_mf_pid"
				[ -z "$_mf_script" ] && [ -n "$_mf_vid" ] && [ -e "$_mf_av/$_mf_vid" ] && _mf_script="$_mf_vid"
				case "$_mf_vid:$_mf_pid" in
					413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4)
						[ -x /usr/share/5gmodem/fcc-unlock.sh ] && { _mf_av=/usr/share/5gmodem; _mf_script=fcc-unlock.sh; } ;;
				esac
				if [ -e "$_mf_en/$_mf_vid:$_mf_pid" ]; then
					echo "    the unlock script is ALREADY enabled - the cause is something else"
				elif [ -n "$_mf_script" ]; then
					echo "    WHAT TO DO (the qmi-utils package is required):"
					echo "      mkdir -p $_mf_en"
					echo "      ln -s $_mf_av/$_mf_script $_mf_en/$_mf_vid:$_mf_pid"
					echo "      ifdown the modem interface, /etc/init.d/modemmanager restart, wait a minute, ifup"
				else
					echo "    there is no ready-made script for $_mf_vid:$_mf_pid in $_mf_av - check a newer ModemManager"
				fi
			fi
		fi
		case "$_mf_sim" in
			''|--) echo "    the modem has no SIM object - there is no card in any slot" ;;
		esac
	done
}

fcclock_verdict() {
	echo ""
	echo "----- FCC lock (verdict) -----"
	[ -n "$1" ] || { echo "no AT port - nothing to check with"; return; }
	_fl_up=$(tty_usbpath "$1" 2>/dev/null)
	_fl_vp=""
	[ -n "$_fl_up" ] && _fl_vp="$(cat "/sys/bus/usb/devices/$_fl_up/idVendor" 2>/dev/null):$(cat "/sys/bus/usb/devices/$_fl_up/idProduct" 2>/dev/null)"
	case "$_fl_vp" in
		413c:81d7|413c:81e0|413c:81e4|413c:81e6|413c:81d8|0489:e0b5|0489:e0b4)
			echo "Dell DW5821e / Foxconn T77W968 ($_fl_vp): this family DOES have an FCC lock, but it"
			echo "cannot be read over AT - it is lifted with the QMI command 'Foxconn set FCC"
			echo "authentication', and a locked module keeps the radio off (CFUN is not 1)."
			_fl_cf=$(sed -n 's/.*+CFUN: *\([0-9]*\).*/\1/p' "$SESS" 2>/dev/null | head -1)
			case "$_fl_cf" in
				1)  echo "CFUN=1 right now - the radio is on, so the lock is not what holds the modem back." ;;
				'') echo "CFUN is unknown in this report - the lock state cannot be judged from here." ;;
				*)  echo "CFUN=$_fl_cf right now - the radio is NOT on; an FCC lock is one of the possible causes." ;;
			esac
			echo "The app sends the unlock by itself (fcc-unlock.sh); its lines in the log:"
			_fl_lg=$(logread 2>/dev/null | grep "5gmodem.*fcc:" | tail -5)
			if [ -n "$_fl_lg" ]; then
				printf '%s\n' "$_fl_lg" | sed 's/^/  /'
			else
				echo "  (none - the unlock was neither needed nor attempted since the log began)"
			fi
			return ;;
	esac
	_fl=$(at_query "$1" "AT+GTFCCLOCKMODE?;+GTFCCLOCKSTATE?;+GTFCCEFFSTATUS?" 8)
	_flm=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKMODE: *\([0-9]*\).*/\1/p' | head -1)
	_fls=$(printf '%s' "$_fl" | sed -n 's/.*+GTFCCLOCKSTATE: *\([0-9]*\).*/\1/p' | head -1)

	if [ -z "$_flm" ]; then
		echo "the modem does not answer about FCC lock - this vendor has no such lock"
		return
	fi
	if [ "$_flm" = "0" ]; then
		echo "FCC lock is off (mode 0) - the modem transmits freely"
		return
	fi

	case "$_flm" in
		1) echo "FCC lock is ON (mode 1: unlocking is needed once)" ;;
		2) echo "FCC lock is ON (mode 2: unlocking is needed at EVERY power-on)" ;;
		*) echo "FCC lock is ON (mode $_flm)" ;;
	esac
	if [ "$_fls" = "1" ]; then
		echo "Right now the modem is UNLOCKED (state 1) - the radio works."
		[ "$_flm" = "2" ] && echo "But with mode 2 the lock comes back after a power-off."
		return
	fi
	echo "AND IT IS NOT UNLOCKED (state 0) - THAT IS THE CAUSE if the modem does not"
	echo "transmit: AT+CFUN=1 answers with an error, no protocol brings the connection"
	echo "up, and it all looks like broken hardware. The hardware is fine."
	echo "Unlocking: AT+GTFCCLOCKGEN gives a challenge, from which a verification"
	echo "code is computed (SHA256 of the challenge + vendor hash), then"
	echo "AT+GTFCCLOCKVER=<code>. To remove it for good - AT+GTFCCLOCKMODE=0 and"
	echo "re-plug the modem. For Lenovo modules the vendor hash is 3df8c719: the code"
	echo "is the first 8 hex digits of SHA256 over the bytes of <challenge as 8 hex"
	echo "digits>3df8c719, written in decimal. Reference: the ModemManager script"
	echo "data/dispatcher-fcc-unlock/14c3 (gitlab.freedesktop.org/mobile-broadband/ModemManager)."
	echo "The app does NOT do this by itself: unlocking is a one-off action by the"
	echo "owner, and we do not want to reach into it from a web UI."
}

sierra_image_verdict() {
	[ -n "$1" ] || return 0
	_si=$(at_query "$1" "AT!IMPREF?" 8)
	case "$_si" in
		*'!IMPREF:'*|*preferred*) ;;
		*) return 0 ;;
	esac
	echo ""
	echo "----- Sierra: firmware image and carrier profile (verdict) -----"
	printf '%s\n' "$_si" | grep -E "version|name|index" | sed 's/^[[:space:]]*/  /'
	if printf '%s' "$_si" | grep -q "mismatch"; then
		echo "MISMATCH: the selected image/profile DOES NOT MATCH the loaded one."
		echo "In this state the modem drops into low power: the radio is silent, there is"
		echo "no registration, and yet no command complains. This is usually how an"
		echo "UNFINISHED firmware update ends - preferred is already switched over while"
		echo "the image itself was never flashed."
		echo "The cure is to point preferred back at the profile that is ACTUALLY in the"
		echo "modem (the current line), for example: AT!IMPREF=\"GENERIC\", and re-plug"
		echo "the power. To list what is flashed: AT!IMAGE?"
	else
		echo "the selected image and profile match the loaded ones - normal"
	fi
}

quectel_fw_verdict() {
	[ -n "$1" ] || return 0
	_qf=$(at_query "$1" "AT+QGMR?" 8 2>/dev/null | tr -d '\r')
	case "$_qf" in
		*ERROR*|"") return 0 ;;
	esac
	_qfb=$(printf '%s\n' "$_qf" | sed -n 's/^+QGMR: *//p' | head -1 | tr -d ' ')
	[ -n "$_qfb" ] || _qfb=$(printf '%s\n' "$_qf" | grep -viE '^(at\+|ok$)' | grep -E '[A-Za-z0-9]' | head -1 | tr -d ' ')
	[ -n "$_qfb" ] || return 0
	echo ""
	echo "----- Quectel: full firmware build (verdict) -----"
	echo "  build: $_qfb"
	case "$_qfb" in
		RM520N*|RM530N*|RG520N*)
			case "$_qfb" in
				*R03*|*_01.2*|*_A0.3*|*A0.30*)
					echo "  THIS BUILD CARRIES THE REGIONAL BLOCK (Russia/Iran): the R03 branch and the"
					echo "  200/201/30x versions refuse to register in those countries. The block sits"
					echo "  in the modem binary itself, so no setting and no QCN edit removes it."
					echo "  'The network is not seen', LIMSRV in AT+COPS?, an endless search with a good"
					echo "  signal - on such a build that is NOT a broken modem and NOT our bug."
					echo "  The known clean build is RM520NGLAAR01A06M4G_01.001.01.001 (branch R01A06)." ;;
				*R01A06*_01.001*)
					echo "  the clean build without the regional block - registration is not limited by firmware" ;;
			esac ;;
	esac
}

STEP_N=0
STEP_TOTAL=9
collect() {
	STEP_N=$((STEP_N + 1))
	echo "$STEP_N/$STEP_TOTAL $1" > "$STEP"
}

_sum_verdict() {
	_sv_if=$(uci -q get 5gmodem.@5gmodem[0].network)
	_sv_ip=""
	[ -n "$_sv_if" ] && _sv_ip=$(ubus call "network.interface.$_sv_if" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -n "$_sv_ip" ] || [ -z "$_sv_if" ] || _sv_ip=$(ubus call "network.interface.${_sv_if}_4" status 2>/dev/null \
		| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	_sv_pend=""; _sv_w=0
	while [ -z "$_sv_ip" ] && [ -n "$_sv_if" ] && [ "$_sv_w" -lt 20 ]; do
		case "$(ubus call "network.interface.$_sv_if" status 2>/dev/null)" in
			*'"pending": true'*) _sv_pend=1 ;;
			*'"up": true'*) [ -n "$_sv_pend" ] || break ;;
			*) break ;;
		esac
		sleep 1; _sv_w=$((_sv_w + 1))
		_sv_ip=$(ubus call "network.interface.$_sv_if" status 2>/dev/null \
			| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
		[ -n "$_sv_ip" ] || _sv_ip=$(ubus call "network.interface.${_sv_if}_4" status 2>/dev/null \
			| jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	done
	_sv_def=$(ip -4 route show default 2>/dev/null | head -1)
	_sv_mod=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[0].model' 2>/dev/null)
	if [ -z "$_sv_mod" ]; then
		_sv_raw=""
		for _sv_d in /sys/bus/usb/devices/*; do
			[ -f "$_sv_d/idVendor" ] || continue
			[ "$(cat "$_sv_d/bDeviceClass" 2>/dev/null)" = "09" ] && continue
			_sv_ff=""; _sv_drv=""
			for _sv_i in "$_sv_d"/"${_sv_d##*/}":*; do
				[ -f "$_sv_i/bInterfaceClass" ] || continue
				[ "$(cat "$_sv_i/bInterfaceClass")" = "ff" ] && _sv_ff=1
				[ -e "$_sv_i/driver" ] || continue
				case "$(basename "$(readlink "$_sv_i/driver")")" in
					usbfs|usb-storage|uas) ;;
					*) _sv_drv=1 ;;
				esac
			done
			[ -n "$_sv_ff" ] && [ -z "$_sv_drv" ] || continue
			_sv_raw="$_sv_raw $(cat "$_sv_d/idVendor"):$(cat "$_sv_d/idProduct") $(cat "$_sv_d/product" 2>/dev/null)
"
		done
		if [ -n "$_sv_raw" ]; then
			echo "A MODEM-LIKE DEVICE IS ON THE USB BUS, BUT NO DRIVER HAS TAKEN IT:"
			printf '%s' "$_sv_raw" | sed '/^$/d; s/^ */    /'
			echo "  It has no AT port and no control channel (cdc-wdm/net), so the app"
			echo "  cannot see it. Usually the modem is in a debug/unknown USB composition;"
			echo "  switch it back to its normal mode. See 'USB devices' below."
			return
		fi
		echo "NO MODEM FOUND on the USB bus. Check the power and the connection;"
		echo "if the modem sits in an M.2 slot, see the 'bootloader mode' section below."
		return
	fi
	if [ -z "$_sv_ip" ]; then
		_sv_bad=""
		for _sv_p in $("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null); do
			case "$_sv_p" in *-*) ;; *) continue ;; esac
			ls /sys/bus/usb/devices/"$_sv_p":*/net/* >/dev/null 2>&1 && continue
			ls /sys/bus/usb/devices/"$_sv_p":*/usbmisc/cdc-wdm* >/dev/null 2>&1 && continue
			_sv_bad="$_sv_bad $_sv_p"
		done
		if [ -n "$_sv_bad" ]; then
			echo "The modem has NO DATA CHANNEL:$_sv_bad - neither cdc-wdm nor a network"
			echo "device. There will be no address until the channel comes back: there is"
			echo "nothing for the protocol to attach to. See 'AT port present, data channel missing'."
			return
		fi
		if [ -n "$_sv_pend" ]; then
			echo "The modem was found; the interface is being dialled RIGHT NOW (netifd: pending)"
			echo "and had no address after ${_sv_w}s of waiting - the report caught it mid-connection."
			echo "If 'Modem interfaces' or 'Routes' below show an address, the dial succeeded later;"
			echo "otherwise see 'Why the modem does not connect' and the netifd log."
			return
		fi
		_sv_pr=$(uci -q get "network.$_sv_if.proto")
		case "$_sv_pr" in
			''|static|none|dhcp) ;;
			*)
				if [ ! -f "/lib/netifd/proto/$_sv_pr.sh" ]; then
					echo "The modem was found, but the interface protocol '$_sv_pr' is NOT INSTALLED -"
					echo "netifd has nothing to dial with. Install: $(proto_pkg "$_sv_pr")"
					return
				fi ;;
		esac
		echo "The modem was found, but it HAS NO ADDRESS - the connection never came up."
		echo "See the sections 'Why the modem does not connect' and 'APN vs. the database'."
		return
	fi
	if [ -z "$_sv_def" ]; then
		echo "The modem has an address ($_sv_ip), but there is NO DEFAULT ROUTE -"
		echo "traffic has nowhere to go. See the section 'Who holds the internet'."
		return
	fi
	_sv_st=""
	[ -n "$_sv_if" ] && [ -f "/tmp/5gmodem/health/$_sv_if" ] \
		&& read -r _sv_st _ _ _ _ 2>/dev/null < "/tmp/5gmodem/health/$_sv_if"
	case "$_sv_st" in
		down) echo "There is an address ($_sv_ip), but the internet through the modem DOES NOT ANSWER probes."
		      echo "See the sections 'Who holds the internet' and 'DNS'." ;;
		up)
			case "$(cap 8 nslookup ya.ru 127.0.0.1 2>&1)" in
				*"Name:"*)
					echo "All good: the modem is online, address $_sv_ip, probes go through." ;;
				*)
					echo "The modem is online (address $_sv_ip, probes by IP go through),"
					echo "but the router's DNS DOES NOT ANSWER - sites will not open."
					_sv_dns=$(uci -q get "network.$_sv_if.dns" 2>/dev/null)
					if [ -n "$_sv_dns" ]; then
						echo "DNS servers set by hand on $_sv_if: $_sv_dns ('Fallback DNS')."
						echo "If they are blocked, turn 'Fallback DNS' off or use 77.88.8.8 77.88.8.1."
					fi
					echo "See the section 'DNS: resolving and rebind'." ;;
			esac ;;
		*)    echo "The modem is online, address $_sv_ip. No watchdog checks yet" \
		      "(monitoring is off, or the router has just booted)." ;;
	esac
}

report() {
	: > "$SESS" 2>/dev/null
	echo "===== luci-app-5gmodem: diagnostic report ====="
	echo "Collected: $(date)"
	echo ""
	echo "WARNING: this report contains modem and SIM identifiers (IMEI, IMSI,"
	echo "ICCID, EID) and the carrier name. Passwords and Wi-Fi keys are NOT included."
	echo "If you would rather not publish the identifiers, send the file privately."
	echo ""
	echo "----- THE SHORT STORY -----"
	echo "Router:    $(cat /tmp/sysinfo/model 2>/dev/null | head -1)"
	echo "Firmware:  $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null | head -1)"
	echo "Package:   $( (apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) \
		| sed -n 's/^\(luci-app-5gmodem[a-z-]*\)[ -]\([0-9][^ ]*\).*/\1 \2/p' | head -1)"
	_sum_m=$("$RES/listmodems.sh" 2>/dev/null)
	echo "Modem:     $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].model' 2>/dev/null) $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].vidpid' 2>/dev/null)"
	echo "Operator:  $(printf '%s' "$_sum_m" | jsonfilter -e '@[0].operator' 2>/dev/null)"
	_ss_pr=$(uci -q get "network.$(uci -q get 5gmodem.@5gmodem[0].network).proto" 2>/dev/null)
	echo "Interface: $(uci -q get 5gmodem.@5gmodem[0].network) ($_ss_pr)"
	echo ""
	echo "VERDICT:"
	_sum_verdict | sed 's/^/  /'
	echo ""
	echo "Below is the detailed diagnostic dump. It is meant for the developer:"
	echo "if everything works, there is no need to read it."

	collect "system"
	run 5  "Installed packages" sh -c "(apk list -I 2>/dev/null || opkg list-installed 2>/dev/null) | grep -iE '5gmodem|sms-tool|modemmanager|lpac|ca-bundle|libcurl|qmi-utils|mbim-utils|libmbim|libqmi|umbim|uqmi|comgt'"
	run 5  "Firmware" cat /etc/openwrt_release
	run 5  "Board model" sh -c "cat /tmp/sysinfo/model 2>/dev/null; cat /proc/device-tree/model 2>/dev/null"
	run 5  "Uptime / memory" sh -c "uptime; free"
	run 5  "Time (matters for eSIM TLS)" sh -c "date; echo 'UTC:'; date -u"

	collect "config"
	run 5  "uci 5gmodem" sh -c "uci -q show 5gmodem | sed -E \"s/^([^=]*(token|secret|pass|psk)[^=]*|[^=]*[._]key)=.*/\\1='<hidden>'/\""
	run 5  "uci 5gmodem (SMS section)" sh -c "uci -q show 5gmodem | grep -E '\.sms\.' | sed -E \"s/^([^=]*(token|secret|pass|psk)[^=]*|[^=]*[._]key)=.*/\\1='<hidden>'/\" || echo '(the sms section is empty)'"
	run 5  "uci lpac" uci -q show lpac
	run 5  "uci network (secrets stripped)" sh -c "uci -q show network | grep -viE 'password|key|passwd|psk|secret|token|pincode|\\.pin=|\\.puk='"
	run 10 "Modem interfaces" sh -c "for i in \$( { uci -q show 5gmodem | sed -n \"s/.*\.network='\(.*\)'/\1/p\"; uci -q show network | sed -n \"s/^network\.\([^.]*\)\.modem_path=.*/\1/p\"; } | sort -u); do for j in \"\$i\" \"\${i}_4\" \"\${i}_6\"; do s=\$(ifstatus \"\$j\" 2>/dev/null | grep -vE '\"(dns-search|route)\"'); [ -n \"\$s\" ] && { echo \"### \$j\"; echo \"\$s\"; }; done; done"

	collect "usb"
	run 10 "USB devices" sh -c "lsusb 2>/dev/null || cat /sys/kernel/debug/usb/devices 2>/dev/null"
	run 10 "Modem list" "$RES/listmodems.sh" --refresh
	run 40 "Port map and IMEI (from sysfs)" "$RES/portmap.sh"
	run 5  "Active modem" "$RES/modemswitch.sh" active
	run 5  "Device blacklist" sh -c '
		_bl=$(uci -q get 5gmodem.@5gmodem[0].ignore_vidpid)
		if [ -z "$_bl" ]; then echo "empty - this section does not apply"; exit 0; fi
		echo "hidden by hand: $_bl"
		for _p in $(/usr/share/5gmodem/registry.sh paths 2>/dev/null); do
			_v=$(cat /sys/bus/usb/devices/"$_p"/idVendor 2>/dev/null)
			_d=$(cat /sys/bus/usb/devices/"$_p"/idProduct 2>/dev/null)
			[ -n "$_v" ] || continue
			for _b in $_bl; do
				[ "$_v:$_d" = "$_b" ] || continue
				echo "WARNING: device $_p ($_b) IS ON THE BUS but is marked"
				echo "  as \"not a modem\". The app does not look for an AT port for it"
				echo "  and shows no metrics - which looks exactly like \"the modem is gone\"."
				echo "  To undo: Settings -> Device blacklist, clear the checkbox."
			done
		done'
	run 5  "AT port (detect.sh)" "$RES/detect.sh"
	run 5 "Ports: dialer vs metrics (verdict)" sh -c '
		P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
		[ -n "$P" ] || { echo "no active modem - this section does not apply"; exit 0; }
		SEC="m_$(echo "$P" | sed "s/[^A-Za-z0-9]/_/g")"
		IF=$(uci -q get "5gmodem.$SEC.network")
		PR=$(uci -q get "network.$IF.proto" 2>/dev/null)
		AT=$(uci -q get 5gmodem.@5gmodem[0].at_port)
		SM=$(uci -q get 5gmodem.sms.readport)
		echo "interface: ${IF:-(none)}  proto: ${PR:-(none)}"
		case "$PR" in
			xmm|atc) ;;
			*) echo "data does not go over a tty with this proto - the roles cannot collide"; exit 0 ;;
		esac
		DL=$(uci -q get "network.$IF.device" 2>/dev/null)
		echo "dialer port:  ${DL:-(none)}"
		echo "metrics port: ${AT:-(none)}"
		echo "SMS port:     ${SM:-(none)}"
		RC=0
		[ -n "$DL" ] && [ "$DL" = "$AT" ] && { echo "PROBLEM: the metrics port IS the dialer port - every poll breaks the data session. The app keeps re-pinning it, which is why a hand-picked port comes back changed."; RC=1; }
		[ -n "$DL" ] && [ "$DL" = "$SM" ] && { echo "PROBLEM: SMS/USSD/AT console sit on the dialer port - every read breaks the data session."; RC=1; }
		[ "$RC" = 0 ] && echo "roles are separate - fine"
		exit 0'
	run 5  "tty/cdc-wdm in the system" sh -c "ls -l /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan* 2>/dev/null"
	run 10 "Who holds the ports" sh -c "for f in /dev/ttyUSB* /dev/cdc-wdm*; do [ -e \"\$f\" ] || continue; u=\$(fuser \"\$f\" 2>/dev/null); [ -n \"\$u\" ] && echo \"\$f: \$u\"; done; echo '--- processes ---'; ps w 2>/dev/null | grep -iE 'ModemManager|uqmi|mbim|sms_tool|lpac|gcom' | grep -v -e grep -e ' sed -E '"

	run 10 "AT port binding (verdict)" sh -c '
		N=0
		for d in /sys/bus/usb/devices/*; do
			[ -f "$d/idVendor" ] || continue
			v=$(cat "$d/idVendor"); p=$(cat "$d/idProduct")
			case "$v:$p" in
				05c6:9025|05c6:90d5|05c6:90d6) ;;
				*) continue ;;
			esac
			N=$((N+1))
			t=""
			for f in "$d":*/ttyUSB* "$d":*/tty/ttyUSB*; do [ -e "$f" ] && t="$t $(basename "$f")"; done
			echo "$(basename "$d") [$v:$p] ports:${t:- NONE}"
		done
		[ "$N" = 0 ] && { echo "no modems that need manual port binding - this section does not apply"; exit 0; }
		echo "--- binding log ---"
		logread 2>/dev/null | grep "5gmodem-usbports" | tail -10 || echo "(no entries - the binding script never ran)"
		if logread 2>/dev/null | grep -q "rescued data interface"; then
			echo "VERDICT: the serial driver DID take the data interface, and the app"
			echo "returned it to its native driver (see \"rescued data interface\" above)."
			echo "If cdc-wdm is still missing, the rescue did not stick - attach this report to the issue."
		elif logread 2>/dev/null | grep -q "already has ports - leaving the binding alone"; then
			echo "VERDICT: the ports were bound by someone else (the kernel table, an rc.local"
			echo "line, or our own earlier pass), so the app left the binding alone."
			echo "That is deliberate: the same composition written into new_id of TWO different"
			echo "drivers makes the kernel hand out interfaces at random, and the ports come out"
			echo "dead (measured on a live Compal: every ttyUSB answered with an I/O error)."
		fi'

	collect "mm"
	run 15 "mmcli -L" sh -c 'command -v mmcli >/dev/null && mmcli -L || echo "mmcli is not installed (the modemmanager package) - normal for a lite build"'
	run 40 "Modems in MM (detailed)" sh -c "mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9]*\).*#\1#p' | while read -r i; do echo \"### modem \$i\"; mmcli -m \"\$i\" -K 2>&1 | grep -viE 'password|\.pin'; done"
	run 5  "MM inhibition (ours)" sh -c "echo '--- active holders ---'; for f in /var/run/5gmodem-mm-inhibit/*.pid; do [ -f \"\$f\" ] || continue; p=\$(cat \"\$f\"); kill -0 \"\$p\" 2>/dev/null && echo \"\$(basename \"\$f\" .pid): pid \$p (alive)\" || echo \"\$(basename \"\$f\" .pid): pid \$p (dead)\"; done; echo '--- mm_exclude flags ---'; uci -q show 5gmodem | grep mm_exclude || echo '(not set)'"
	run 5  "MM autostart" sh -c "[ -x /etc/init.d/modemmanager ] || { echo 'ModemManager is not installed'; exit 0; }; /etc/init.d/modemmanager enabled && echo 'enabled' || echo 'disabled'"

	collect "at"
	P=$("$RES/detect.sh" 2>/dev/null)
	echo ""
	echo "AT port used for polling: ${P:-(not found)}"
	if [ -n "$P" ] && at_dialer_busy "$P" 2>/dev/null; then
		echo ""
		echo "WARNING: the netifd dialer (gcom) is working on this port right now."
		echo "AT polling was skipped: overlapping requests scramble the answers, and"
		echo "false diagnoses follow. The fact itself matters: the interface is in a"
		echo "redial loop - check the netifd log (logread | grep netifd)."
		P=""
	fi
	at "$P" "ATI"
	at "$P" "AT+CGMM"
	at "$P" "AT+CGMR"
	at "$P" "AT+CPIN?"
	at "$P" "AT+CFUN?"
	at "$P" "AT+COPS?"
	at "$P" "AT+CSQ"
	at "$P" "AT+CGDCONT?"
	at "$P" "AT+CEREG?"
	at "$P" "AT+C5GREG?"
	at "$P" "AT+CGATT?"
	radio_verdict "$P"
	mm_fail_verdict "$P"
	fcclock_verdict "$P"
	sierra_image_verdict "$P"
	quectel_fw_verdict "$P"
	proxy_verdict
	stick_verdict
	usbcomp_verdict
	mbim_verdict

	collect "sim"
	run 20 "SIM slots" "$RES/simslot.sh" status
	run 15 "Antenna ports (RSRP/RSRQ)" "$RES/bands.sh" getantports

	run 20 "Band management: path" "$RES/bands.sh" mgmtinfo
	run 25 "Band management: what the app sees" "$RES/bands.sh" getinfo
	run 10 "Current metrics (what the card shows)" sh -c '
		. /usr/share/5gmodem/lib.sh 2>/dev/null
		p=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
		k=$(snap_key "$p")
		f="/tmp/5gmodem/metrics_$k.json"
		[ -s "$f" ] || { echo "no snapshot yet - open the Network page once and collect the report again"; exit 0; }
		t=$(cat "/tmp/5gmodem/metrics_$k.stamp" 2>/dev/null)
		case "$t" in ""|*[!0-9]*) ;; *) echo "snapshot age: $(( $(uptime_s) - t )) s" ;; esac
		sed -e "s/^{//" -e "s/}\$//" -e "s/,\"/\n\"/g" "$f"
		echo
		mt=$(jsonfilter -i "$f" -e "@.mtemp" 2>/dev/null | sed -n "s/^\([0-9][0-9]*\).*/\1/p")
		if [ -n "$mt" ] && [ "$mt" -ge 110 ] 2>/dev/null; then
			echo "TEMPERATURE: the modem reports $mt C. No modem works at that temperature (they shut down near 100 C),"
			echo "  so this is almost certainly a false sensor reading. On Foxconn T99W640 it is a known firmware fault:"
			echo "  the module believes it is overheating and drops its registration every ~20 seconds."
			echo "  Check the modem by touch; if it is only warm, the sensor or its calibration is at fault, not cooling."
		fi
	'
	run 20 "QMI extras (band/signal)" sh -c '
		command -v qmicli >/dev/null 2>&1 || { echo "qmicli is NOT INSTALLED (the qmi-utils package) - nowhere to read the band and RSRP from"; exit 0; }
		_qv_err=$(qmicli --version 2>&1 | grep -m1 "Error relocating")
		if [ -n "$_qv_err" ]; then
			echo "qmicli is BROKEN: it does not match the installed libqmi library"
			echo "  qmi-utils $(apk info -v qmi-utils 2>/dev/null | sed 's/^qmi-utils-//' | head -1), libqmi $(apk info -v libqmi 2>/dev/null | sed 's/^libqmi-//' | head -1)"
			echo "  $_qv_err"
			echo "  every QMI read (band, RSRP, carrier aggregation, SIM slots) fails until both come from the same feed"
			exit 0
		fi
		W=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
		[ -c "$W" ] || { echo "the active modem has no cdc-wdm of its own - no QMI extras"; exit 0; }
		echo "node: $W"
		. /usr/share/5gmodem/lib.sh 2>/dev/null
		if command -v qmi_channel_free >/dev/null 2>&1 && ! qmi_channel_free; then
			echo "the channel is held by netifd (kernel proto qmi/qmiraw/mbim) - polling skipped on purpose, the connection matters more"
			exit 0
		fi
		MB=""
		case "$(readlink -f "/sys/class/usbmisc/${W##*/}/device/driver" 2>/dev/null)" in
			*/cdc_mbim) MB="--device-open-mbim" ;;
		esac
		PX=""
		case "$MB" in
			--device-open-mbim) pidof mbim-proxy >/dev/null 2>&1 && PX="-p" ;;
			*) pidof qmi-proxy >/dev/null 2>&1 && PX="-p" ;;
		esac
		_qi=$(uci -q get "5gmodem.$(secname "$(uci -q get 5gmodem.@5gmodem[0].active_modem)").network" 2>/dev/null)
		[ -n "$_qi" ] || _qi=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
		if [ -z "$PX" ] && command -v proto_in >/dev/null 2>&1 \
		   && proto_in mm "$(uci -q get "network.$_qi.proto" 2>/dev/null)"; then
			echo "the channel belongs to ModemManager and no shared proxy is running - opening it directly would drop the connection, skipped"
			exit 0
		fi
		echo "--- rf-band-info ---"; qmicli -d "$W" $MB $PX --nas-get-rf-band-info 2>&1 | head -20
		echo "--- signal-info ---";  qmicli -d "$W" $MB $PX --nas-get-signal-info 2>&1 | head -20'
	run 20 "HiLink modem: its own web API" sh -c '
		P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
		S="m_$(echo "$P" | sed "s/[^A-Za-z0-9]/_/g")"
		[ "$(uci -q get "5gmodem.$S.kind")" = hilink ] || {
			echo "the active modem is not a web-managed stick - this check does not apply"; exit 0; }
		echo "address of the modem: $(/usr/share/5gmodem/hilink.sh addr "$P" 2>/dev/null)"
		echo "--- probe ---"
		/usr/share/5gmodem/hilink.sh probe "$P" 2>&1 | head -3
		echo "--- metrics ---"
		_m=$(/usr/share/5gmodem/hilink.sh json "$P" 2>&1 | head -c 1200)
		echo "$_m"
		case "$_m" in
			"") echo "EMPTY ANSWER: the web API of the modem did not reply - the card will be blank" ;;
			*'"'"'"rsrp":""'"'"'*|*'"'"'"csq":""'"'"'*)
				echo "the API answers, but the LEVELS ARE EMPTY. On ZTE sticks that means we are"
				echo "not logged in to the web interface: without a session the firmware fills"
				echo "only the public fields (operator, network type, signal bar). The password"
				echo "is taken from 5gmodem.<section>.web_pass, admin by default." ;;
		esac'
	run 5  "Is lpac installed?" sh -c "ls -l /usr/bin/lpac /usr/lib/lpac 2>/dev/null; echo '--- dependencies ---'; ldd /usr/lib/lpac 2>/dev/null"
	run 5  "CA certificates (needed to download a profile)" sh -c "ls -l /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo 'ca-bundle is NOT INSTALLED -> eSIM profile download will not work'"
	run 5  "HTTP backend in lpac" "$RES/esim.sh" httpinfo
	run 15 "Outbound HTTPS check" sh -c "curl -sS -o /dev/null -w 'code=%{http_code} tls=%{ssl_verify_result} time=%{time_total}s\n' https://ya.ru 2>&1 | head -3"
	run 5  "HTTP client for eSIM (wget/curl)" sh -c '
		_w=$(wget --version 2>/dev/null | head -1)
		case "$_w" in
			*"GNU Wget"*) echo "wget: $_w - suitable for downloading a profile" ;;
			*) echo "wget: busybox (no --method/--body-file) - the bridge will use curl"
			   echo "  for the most reliable profile download: apk add wget-ssl" ;;
		esac
		if command -v curl >/dev/null 2>&1; then
			echo "curl: $(curl --version 2>/dev/null | head -1)"
		else
			echo "curl: NOT INSTALLED - if wget is busybox too, a profile download is impossible"
		fi'
	collect "esim"
	run 5  "eSIM: lpac config (AT/uqmi port)" sh -c "uci -q show lpac 2>/dev/null; echo '--- custom AID ---'; uci -q get lpac.global.custom_isd_r_aid 2>/dev/null || echo '(default A0000005591010FFFFFFFF8900000100)'"
	run 10 "eSIM: APDU transport" "$RES/esim.sh" apduinfo
	run 60 "eSIM: hunting for the eUICC port (CCHO over every tty)" sh -c '
		if [ ! -x /usr/bin/lpac ]; then
			echo "lpac is not installed - the port sweep was skipped (eSIM unavailable)"
			exit 0
		fi
		AID=$(uci -q get lpac.global.custom_isd_r_aid 2>/dev/null)
		[ -n "$AID" ] || AID=A0000005591010FFFFFFFF8900000100
		P=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
		VP=$(uci -q get "5gmodem.m_$(echo "$P" | sed "s/[^A-Za-z0-9]/_/g").vidpid" 2>/dev/null)
		case "$VP" in
			1199:*)
				echo "Sierra ($VP): the CCHO probe was skipped - on the EM9190 it wedged the SIM subsystem until the card was re-seated; on Sierra the eUICC lives behind QMI/MBIM, not AT"
				exit 0 ;;
		esac
		SL=$(/usr/share/5gmodem/simslot.sh status 2>/dev/null)
		SLA=$(printf "%s" "$SL" | jsonfilter -e "@.active" 2>/dev/null)
		SLE=$(printf "%s" "$SL" | jsonfilter -e "@.slots[@.label=\"eSIM\"].id" 2>/dev/null | head -1)
		echo "active SIM slot: $(printf "%s" "$SL" | grep -o "\"active\":\"[^\"]*\"")"
		if [ -n "$SLE" ] && [ -n "$SLA" ] && [ "$SLE" != "$SLA" ]; then
			echo "the physical SIM slot ($SLA) is active, eSIM is slot $SLE: the modem has ONE channel to the card, so the eUICC ISD-R is unreachable right now and CCHO will not open on ANY port. This does not mean the chip is missing - switch the slot to eSIM and try again."
			exit 0
		fi
		DSK=""
		DIF=$(uci -q get "5gmodem.m_$(echo "$P" | sed "s/[^A-Za-z0-9]/_/g").network" 2>/dev/null)
		if [ -n "$DIF" ]; then
			case "$(uci -q get "network.$DIF.proto" 2>/dev/null)" in
				xmm|atc) DSK=$(uci -q get "network.$DIF.device" 2>/dev/null) ;;
			esac
		fi
		echo "ports of modem $P:"
		[ -n "$DSK" ] && echo "  $DSK -> skipped: the xmm/atc dialer owns this port (it carries data)"
		for t in $(/usr/share/5gmodem/listmodems.sh 2>/dev/null | jsonfilter -e "@[@.path=\"$P\"].tty[*]" 2>/dev/null); do
			[ -n "$DSK" ] && [ "$t" = "$DSK" ] && continue
			. /usr/share/5gmodem/noatports.sh
			tty_no_at "$t" && { echo "  $t -> skipped: a service port, AT resets this modem"; continue; }
			. /usr/share/5gmodem/atlock.sh
			at_lock "$t" 5 || { echo "  $t -> skipped: the port is busy (metrics poll or an eSIM operation holds it)"; continue; }
			for c in 1 2 3 4; do sms_tool -d "$t" at "AT+CCHC=$c" >/dev/null 2>&1; done
			R=$(sms_tool -d "$t" at "AT+CCHO=\"$AID\"" 2>/dev/null | tr -d "\r" | grep -v "^$" | grep -vi "^at+ccho" | head -1)
			at_unlock
			case "$R" in
				*CCHO:*|[0-9]*) echo "  $t -> CHANNEL OPENED [$R]  <= this is the eUICC port" ;;
				*) echo "  $t -> no ([$R])" ;;
			esac
		done'
	_ES_SKIP=""
	_es_sec="m_$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g')"
	_es_if=$(uci -q get "5gmodem.$_es_sec.network" 2>/dev/null)
	[ -n "$_es_if" ] || _es_if=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
	_es_sl=$("$RES/simslot.sh" status 2>/dev/null)
	_es_act=$(printf '%s' "$_es_sl" | jsonfilter -e '@.active' 2>/dev/null)
	_es_lab=""
	[ -n "$_es_act" ] && _es_lab=$(printf '%s' "$_es_sl" \
		| jsonfilter -e "@.slots[@.id=\"$_es_act\"].label" 2>/dev/null)
	if [ ! -x /usr/bin/lpac ]; then
		_ES_SKIP="lpac is not installed"
	elif [ "$("$RES/esim.sh" apduinfo 2>/dev/null | sed -n 's/^selected APDU backend: //p')" = "at" ] \
	     && [ -z "$("$RES/registry.sh" active 2>/dev/null | jsonfilter -e '@.tty[*]' 2>/dev/null)" ]; then
		_ES_SKIP="APDU transport is at, but the active modem has no tty at all"
	elif [ "$(uci -q get "network.$_es_if.proto" 2>/dev/null)" = "modemmanager" ] \
	     && ifstatus "$_es_if" 2>/dev/null | grep -q '"up": true'; then
		if [ -n "$_es_lab" ] && [ "${_es_lab#*eSIM}" = "$_es_lab" ]; then
			_ES_SKIP="slot $_es_act ($_es_lab) is active, so the eUICC is unreachable anyway, and reading it would take the channel from ModemManager and drop this live connection - switch to the eSIM slot, stop the interface and collect the report again"
		else
			_ES_SKIP="reading the eUICC takes the channel from ModemManager and would drop this live connection - stop the modem interface and collect the report again, or read the chip on the eSIM page"
		fi
	fi
	if [ -n "$_ES_SKIP" ]; then
		run 5 "eSIM: status/profiles/notifications" echo "skipped: $_ES_SKIP"
	else
		run 60 "eSIM: status" "$RES/esim.sh" status-probe
		run 90 "eSIM: profiles and chip" "$RES/esim.sh" dump
		run 60 "eSIM: notifications" "$RES/esim.sh" notifications
	fi

	collect "net"
	run 10 "Routes" sh -c "ip route; echo '--- ipv6 ---'; ip -6 route"
	run 10 "An address from the modem's own subnet (verdict)" modem_subnet_verdict
	run 40 "Who holds the internet (verdict)" uplink_verdict
	run 60 "DNS: resolving and rebind (verdict)" dns_verdict
	run 40 "QMI: frame format and counters (verdict)" qmi_format_verdict
	run 10 "uci firewall (zones)" sh -c "uci show firewall 2>/dev/null | grep -E 'zone|forwarding' | head -40"
	run 10 "The wan zone and NAT (verdict)" fw_zone_verdict
	run 15 "APN vs. the database (verdict)" apn_verdict
	run 15 "TTL override (verdict)" ttl_verdict
	run 15 "Access to the admin page (verdict)" webstack_verdict
	run 15 "Policy routing / mwan3 (verdict)" policyrouting_verdict
	run 10 "Uncommitted uci changes (landmines)" sh -c 'uci changes 2>/dev/null | head -40 | sed -E "s/^([^=]*(token|secret|pass|psk|pincode|\\.pin|\\.puk)[^=]*|[^=]*[._]key\\+?)=.*/\\1='"'"'<hidden>'"'"'/"; [ -z "$(uci changes 2>/dev/null)" ] && echo "(empty - no landmines)"'
	run 10 "netifd crashes (verdict)" netifd_crash_verdict
	run 10 "USB power and stability (verdict)" usb_flap_verdict
	run 10 "On the bus but unconfigured? (verdict)" usb_unconfigured_verdict
	run 15 "Did usb_modeswitch break the composition? (verdict)" usbmode_verdict
	run 10 "Is the modem in bootloader mode? (verdict)" fastboot_verdict
	run 20 "Modem radio power (verdict)" power_state_verdict
	run 10 "Ping 77.88.8.8" ping -c 3 -W 2 77.88.8.8
	run 10 "Ping IPv6 (2a02:6b8::feed:0ff)" sh -c "ping6 -c 3 -W 2 2a02:6b8::feed:0ff 2>/dev/null || ping -6 -c 3 -W 2 2a02:6b8::feed:0ff"
	run 20 "Log: ModemManager" sh -c "logread 2>/dev/null | grep -i modemmanager | tail -80"
	run 20 "Log: netifd/interfaces" sh -c "logread 2>/dev/null | grep -iE 'netifd|wwan|qmi|mbim|fibocom' | tail -80"
	run 20 "Log: kernel (USB)" sh -c "dmesg 2>/dev/null | grep -iE 'usb|option|qmi_wwan|cdc_|reset' | tail -60"
	run 20 "Log: USB devices since boot" sh -c "dmesg 2>/dev/null | grep -E 'usb [0-9]+-[0-9.]+: (new .*USB device|USB disconnect|New USB device found)|generic converter' | head -60"
	run 20 "Log: fastboot rescue and ModemManager start/stop" sh -c "logread 2>/dev/null | grep -E 'fastboot-rescue|ModemManager (started|stopped)' | tail -40"
	run 20 "Log: the whole tail" sh -c "logread 2>/dev/null | tail -120"

	run 10 "+CME ERROR codes seen in this report" sh -c '
		. /usr/share/5gmodem/cme.sh
		_cme_t="/tmp/5gmodem/.diag-cme.$$"
		{ cat "$SESS" 2>/dev/null; logread 2>/dev/null | tail -200; } \
			| grep -oE "CME ERROR: *[0-9]+" | grep -oE "[0-9]+" | sort -un | while read -r c; do
				t=$(cme_text "$c" 2>/dev/null) || t="(not in the reference table)"
				printf "  %-4s %s\n" "$c" "$t"
			done > "$_cme_t" 2>/dev/null
		if [ -s "$_cme_t" ]; then cat "$_cme_t"; else echo "  (no CME errors in this report)"; fi
		rm -f "$_cme_t"
	'

	rm -f "$SESS" 2>/dev/null
	collect "done"
	echo ""
	echo "===== end of report ====="
}

_proto_names() {
	sed -E '/^[A-Za-z0-9_@]+[.][^= ]*=/!{s/(^|[^A-Za-z0-9_])mbimp([^.A-Za-z0-9_-]|$)/\1MBIM+MM\2/g}'
}

case "$1" in
start)
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		echo '{"state":"running"}'; exit 0
	fi
	rm -f "$OUT"; echo "0/9 start" > "$STEP"
	( report 2>&1 | tr -d '\000' | _proto_names > "$OUT"; rm -f "$LOCK" ) >/dev/null 2>&1 </dev/null &
	echo $! > "$LOCK"
	echo '{"state":"running"}'
	# see docs/subsystems/diagnostics.md#background-collection
	sleep 1
	;;
status)
	if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
		printf '{"state":"running","progress":"%s"}\n' "$(cat "$STEP" 2>/dev/null)"
	elif [ -s "$OUT" ]; then
		printf '{"state":"done","size":"%s"}\n' "$(wc -c < "$OUT" | tr -d ' ')"
	else
		echo '{"state":"idle"}'
	fi
	;;
run)
	report | _proto_names
	;;
*)
	echo "usage: collect.sh start|status|run"
	;;
esac
exit 0
