#!/bin/sh
# Shared, read-only state interpretation. Safe to source from collectors/watchers.

registration_stat() {
	awk -v domain="$1" '
	$0 ~ "^\\+" domain ":" {
		sub(/^[^:]*:[[:space:]]*/, ""); n=split($0,a,",");
		# Queries have <n>,<stat>; unsolicited reports have <stat>,"<area>".
		v=(n == 1 || a[2] ~ /"/) ? a[1] : a[2];
		gsub(/[[:space:]\r]/,"",v); if (v ~ /^[0-9]+$/) result=v;
	} END { if (result != "") print result }'
}

modem_registration() {
	local reply="$1" domain value
	SIM_STATE=unknown
	case "$reply" in
		*'+CPIN: READY'*) SIM_STATE=ready ;;
		*'+CPIN: SIM PIN'*|*'+CME ERROR: 11'*) SIM_STATE=pin ;;
		*'+CPIN: SIM PUK'*|*'+CME ERROR: 12'*) SIM_STATE=puk ;;
		*'+CME ERROR: 10'*) SIM_STATE=absent ;;
		*'+CME ERROR: 13'*) SIM_STATE=failed ;;
		*'+CME ERROR: 14'*) SIM_STATE=busy ;;
	esac
	REG_CS=$(printf '%s\n' "$reply" | registration_stat CREG)
	REG_DATA=""
	# A successful packet registration wins over CS rejection/SMS-only status.
	for domain in C5GREG CEREG CGREG; do
		value=$(printf '%s\n' "$reply" | registration_stat "$domain")
		[ -n "$REG_DATA" ] || REG_DATA="$value"
		case "$value" in 1|5) REG_DATA="$value"; break ;; esac
	done
	REG=${REG_DATA:-$REG_CS}
	case "$SIM_STATE" in
		absent) REG='SIM not inserted' ;;
		pin) REG='SIM PIN required' ;;
		puk) REG='SIM PUK required' ;;
		failed) REG='SIM failure' ;;
		busy) REG='SIM busy' ;;
	esac
}

iface_config_disabled() {
	[ "$(uci -q get "network.$1.auto")" = 0 ] ||
		[ "$(uci -q get "network.$1.disabled")" = 1 ]
}

iface_runtime_state() {
	local name="$1" state="$2" errors
	[ -n "$name" ] && [ "$(uci -q get "network.$name")" = interface ] || { echo missing; return; }
	iface_config_disabled "$name" && { echo disabled; return; }
	[ -n "$state" ] || state=$(ifstatus "$name" 2>/dev/null)
	[ -n "$state" ] || { echo unavailable; return; }
	[ "$(printf '%s' "$state" | jsonfilter -e '@.up' 2>/dev/null)" = true ] && { echo up; return; }
	[ "$(printf '%s' "$state" | jsonfilter -e '@.pending' 2>/dev/null)" = true ] && { echo pending; return; }
	errors=$(printf '%s' "$state" | jsonfilter -e '@.errors[*].code' 2>/dev/null)
	[ -n "$errors" ] && { echo failed; return; }
	[ "$(printf '%s' "$state" | jsonfilter -e '@.autostart' 2>/dev/null)" = false ] && { echo stopped; return; }
	echo down
}

# UCI commit alone does not update fw4's cached logical zone membership.
firewall_sync_iface() {
	local name="$1" dev zone
	command -v fw4 >/dev/null 2>&1 || return 0
	dev=$(ifstatus "$name" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
	zone=$(fw4 -q network "$name" 2>/dev/null)
	if [ -n "$zone" ]; then
		[ -z "$dev" ] && return 0
		fw4 -q zone "$zone" "$dev" >/dev/null 2>&1 && return 0
	fi
	fw4 -q check >/dev/null 2>&1 && fw4 -q reload >/dev/null 2>&1
}
