#!/bin/sh

. /usr/share/5gmodem/lib.sh 2>/dev/null

ssc_present() {
	case "$1" in
		go)     [ -x /opt/clash/bin/ssclash ] || [ -f /etc/init.d/ssclash ] ;;
		legacy) [ -f /etc/init.d/clash ] && [ -x /opt/clash/bin/clash ] ;;
		*)      return 1 ;;
	esac
}

ssc_service() { [ "$1" = legacy ] && echo clash || echo ssclash; }

ssc_router_profile() {
	awk '
		{ sub(/\r$/, "") }
		/^[[:space:]]*(#|$)/ { next }
		/^[^[:space:]]/ {
			section = ""
			if ($0 ~ /^dns:[[:space:]]*(#.*)?$/) section = "dns"
			if ($0 ~ /^tproxy-port:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/) tproxy = 1
			if ($0 ~ /^proxy-groups:[[:space:]]*(#.*)?$/) groups = 1
			if ($0 ~ /^rules:[[:space:]]*(#.*)?$/) rules = 1
			if ($0 ~ /^(proxies|proxy-providers):[[:space:]]*(#.*)?$/) proxies = 1
			next
		}
		section == "dns" && /^[[:space:]]+enable:[[:space:]]*true[[:space:]]*(#.*)?$/ { dns = 1 }
		section == "dns" && /^[[:space:]]+listen:[[:space:]]*[^[:space:]#]/ { listen = 1 }
		END { exit !(tproxy && dns && listen && groups && rules && proxies) }
	' "$1"
}

ssc_interface_mode() {
	awk '
		/^[^[:space:]#]/ { dns = ($0 ~ /^dns:[[:space:]]*(#.*)?$/) }
		dns && /^[[:space:]]+fake-ip-filter-mode[[:space:]]*:/ {
			value = $0
			sub(/^[^:]*:[[:space:]]*/, "", value)
			sub(/[[:space:]]*#.*/, "", value)
			gsub(/["\047[:space:]]/, "", value)
			if (value == "whitelist") whitelist = 1
		}
		END { print whitelist ? "explicit" : "exclude" }
	' "$1"
}

ssc_profile_matches() {
	cmp -s "$1" "$2" && return 0
	awk '
		/^(#[[:space:]]*)?secret[[:space:]]*:/ { next }
		FILENAME == ARGV[1] { lines[++count] = $0; next }
		{ if (++position > count || lines[position] != $0) different = 1 }
		END { exit (different || position != count) }
	' "$1" "$2"
}

ssc_saved_name() {
	SAVED=
	[ -f /opt/clash/.5gmodem-profile ] || return 0
	IFS= read -r SAVED < /opt/clash/.5gmodem-profile
	case "$SAVED" in */*) SAVED= ;; esac
	return 0
}

ssc_profile_name() {
	ACTIVE=config.yaml
	ssc_saved_name
	case "$SAVED" in ''|config.yaml) return ;; esac
	if [ -f "/opt/clash/$SAVED" ] && ssc_profile_matches "/opt/clash/$SAVED" /opt/clash/config.yaml; then
		ACTIVE=$SAVED
	fi
}

ssc_go_active() {
	GO_ACTIVE=
	[ -f /opt/clash/.ssclash/active-profile ] || return 0
	IFS= read -r GO_ACTIVE < /opt/clash/.ssclash/active-profile
	case "$GO_ACTIVE" in */*|.*) GO_ACTIVE= ;; esac
	return 0
}

ssc_valid_name() {
	case "$2" in ''|*/*|.*) return 1 ;; esac
	[ "$1" != legacy ] && return 0
	case "$2" in *.yaml) return 0 ;; esac
	return 1
}

ssc_source() {
	if [ "$1" = go ]; then
		echo "/opt/clash/configs/$2.yaml"
	elif [ "$2" = config.yaml ]; then
		echo /opt/clash/config.yaml-backup
	else
		echo "/opt/clash/$2"
	fi
}

ssc_settings_file() {
	[ "$1" = go ] && echo /opt/clash/.ssclash/settings || echo /opt/clash/settings
}

ssc_settings_mode() {
	awk -F= '/^[[:space:]]*INTERFACE_MODE=/ { mode = $2 } END { print (mode == "explicit") ? "explicit" : "exclude" }' "$1"
}

ssc_core_stable() {
	WAIT=0
	while ! svc_running "$1" && [ "$WAIT" -lt 30 ]; do
		sleep 1; WAIT=$((WAIT + 1))
	done
	svc_running "$1" || return 1
	[ "$2" = 1 ] || return 0
	WAIT=0
	SEEN=
	STREAK=0
	while [ "$WAIT" -lt 30 ]; do
		NOW=$(pidof clash)
		KEPT=
		for PID in $SEEN; do
			case " $NOW " in *" $PID "*) KEPT="$KEPT $PID" ;; esac
		done
		if [ -n "$KEPT" ]; then
			SEEN=$KEPT
			STREAK=$((STREAK + 1))
			[ "$STREAK" -lt 3 ] || return 0
		else
			SEEN=$NOW
			STREAK=0
		fi
		sleep 1; WAIT=$((WAIT + 1))
	done
	return 1
}

case "$1" in
profiles)
	. /usr/share/libubox/jshn.sh
	json_init
	if [ "$2" = go ]; then
		ssc_go_active
		json_add_string active "$GO_ACTIVE"
		json_add_array profiles
		for PROFILE in /opt/clash/configs/*.yaml; do
			[ -f "$PROFILE" ] || continue
			PROFILE=${PROFILE##*/}
			json_add_string "" "${PROFILE%.yaml}"
		done
	else
		ssc_profile_name
		json_add_string active "$ACTIVE"
		json_add_array profiles
		[ ! -f /opt/clash/config.yaml-backup ] || json_add_string "" config.yaml
		for PROFILE in /opt/clash/*.yaml; do
			[ -f "$PROFILE" ] && [ "$PROFILE" != /opt/clash/config.yaml ] || continue
			ssc_router_profile "$PROFILE" || continue
			json_add_string "" "${PROFILE##*/}"
		done
	fi
	json_close_array
	json_dump
	;;
apply-profile)
	ssc_present "$2" || { echo '{"error":"not_installed"}'; exit 1; }
	ssc_valid_name "$2" "$3" || { echo '{"error":"invalid_profile"}'; exit 1; }
	mkdir /tmp/5gmodem-profile-lock 2>/dev/null || { echo '{"error":"busy"}'; exit 1; }
	rm -f /tmp/5gmodem-profile-result.json
	if command -v setsid >/dev/null 2>&1; then
		setsid /bin/sh "$0" _profile-job "$2" "$3" >/dev/null 2>&1 </dev/null &
	else
		/bin/sh "$0" _profile-job "$2" "$3" >/dev/null 2>&1 </dev/null &
	fi
	echo '{"ok":true,"pending":true}'
	sleep 1
	;;
_profile-job)
	trap 'rmdir /tmp/5gmodem-profile-lock 2>/dev/null' EXIT
	trap 'exit 1' HUP INT TERM
	RESULT=$("$0" _apply-profile "$2" "$3")
	[ -n "$RESULT" ] || RESULT='{"error":"apply_failed"}'
	printf '%s\n' "$RESULT" > /tmp/5gmodem-profile-result.json.new
	mv -f /tmp/5gmodem-profile-result.json.new /tmp/5gmodem-profile-result.json
	;;
_apply-profile)
	KIND=$2
	PROFILE=$3
	ssc_present "$KIND" || { echo '{"error":"not_installed"}'; exit 1; }
	ssc_valid_name "$KIND" "$PROFILE" || { echo '{"error":"invalid_profile"}'; exit 1; }
	SOURCE=$(ssc_source "$KIND" "$PROFILE")
	SETTINGS=$(ssc_settings_file "$KIND")
	[ -f "$SOURCE" ] || { echo '{"error":"missing_profile"}'; exit 1; }
	WORK=$(mktemp -d /opt/clash/.5gmodem-switch.XXXXXX) || exit 1
	trap 'rm -rf "$WORK"' EXIT
	trap 'exit 1' HUP INT TERM
	cp "$SOURCE" "$WORK/new.yaml" || exit 1
	if [ "$KIND" = legacy ] && [ "$PROFILE" != config.yaml ] && ! ssc_router_profile "$WORK/new.yaml"; then
		echo '{"error":"invalid_profile"}'; exit 1
	fi
	/opt/clash/bin/clash -t -d /opt/clash -f "$WORK/new.yaml" > "$WORK/check.log" 2>&1 || {
		echo '{"error":"validation_failed"}'; exit 1;
	}
	if [ "$KIND" = go ]; then
		ssc_go_active
		CURRENT=$GO_ACTIVE
		KEEPER=$(ssc_source go "$GO_ACTIVE")
	else
		ssc_saved_name
		CURRENT=${SAVED:-config.yaml}
		KEEPER=$(ssc_source legacy "$CURRENT")
	fi
	HAD_CONFIG=0
	if [ -e /opt/clash/config.yaml ]; then
		cp -p /opt/clash/config.yaml "$WORK/old.yaml" || exit 1
		HAD_CONFIG=1
		if [ "$KIND" = legacy ] && [ "$CURRENT" = config.yaml ] && [ "$PROFILE" != config.yaml ]; then
			cp -p "$WORK/old.yaml" "$WORK/backup.yaml" && chmod 600 "$WORK/backup.yaml" &&
				mv -f "$WORK/backup.yaml" /opt/clash/config.yaml-backup || {
				echo '{"error":"backup_failed"}'; exit 1;
			}
		elif [ ! -f "$KEEPER" ] || ! ssc_profile_matches "$KEEPER" "$WORK/old.yaml"; then
			cp -p "$WORK/old.yaml" "$WORK/edited.yaml" && chmod 600 "$WORK/edited.yaml" &&
				mv -f "$WORK/edited.yaml" /opt/clash/config.yaml-edited || {
				echo '{"error":"backup_failed"}'; exit 1;
			}
		fi
	fi
	HAD_SETTINGS=0
	if [ -e "$SETTINGS" ]; then
		cp -p "$SETTINGS" "$WORK/old.settings" || exit 1
		HAD_SETTINGS=1
	else
		: > "$WORK/old.settings"
	fi
	OLD_MODE=$(ssc_settings_mode "$WORK/old.settings")
	if [ "$CURRENT" = "$PROFILE" ]; then
		MODE=$OLD_MODE
	else
		MODE=
		[ ! -f "/opt/clash/.5gmodem-mode.$PROFILE" ] || IFS= read -r MODE < "/opt/clash/.5gmodem-mode.$PROFILE"
		case "$MODE" in explicit|exclude) ;; *) MODE=$(ssc_interface_mode "$WORK/new.yaml") ;; esac
	fi
	cp -p "$WORK/old.settings" "$WORK/new.settings" || exit 1
	awk -v mode="$MODE" '
		/^[[:space:]]*INTERFACE_MODE=/ {
			if (!written++) print "INTERFACE_MODE=" mode
			next
		}
		{ print }
		END { if (!written) print "INTERFACE_MODE=" mode }
	' "$WORK/old.settings" > "$WORK/new.settings" || exit 1
	chmod 600 "$WORK/new.yaml"
	mv -f "$WORK/new.yaml" /opt/clash/config.yaml || exit 1
	if ! mv -f "$WORK/new.settings" "$SETTINGS"; then
		if [ "$HAD_CONFIG" = 1 ]; then
			mv -f "$WORK/old.yaml" /opt/clash/config.yaml
		else
			rm -f /opt/clash/config.yaml
		fi
		exit 1
	fi
	if [ "$KIND" = go ]; then
		printf '%s' "$PROFILE" > "$WORK/selected"
		mv -f "$WORK/selected" /opt/clash/.ssclash/active-profile
	fi
	SVC=$(ssc_service "$KIND")
	ACTION=restart
	NEED_CORE=1
	if [ "$KIND" = legacy ]; then
		ACTION=reload
	else
		[ "$(cat /opt/clash/.ssclash/enabled 2>/dev/null)" = 1 ] || NEED_CORE=0
	fi
	/etc/init.d/"$SVC" "$ACTION" > "$WORK/restart.log" 2>&1 && ssc_core_stable "$SVC" "$NEED_CORE"
	if [ "$?" != 0 ]; then
		if [ "$HAD_SETTINGS" = 1 ]; then
			mv -f "$WORK/old.settings" "$SETTINGS"
		else
			rm -f "$SETTINGS"
		fi
		[ "$KIND" != go ] || printf '%s' "$CURRENT" > /opt/clash/.ssclash/active-profile
		if [ "$HAD_CONFIG" = 1 ]; then
			mv -f "$WORK/old.yaml" /opt/clash/config.yaml
			/etc/init.d/"$SVC" restart > /dev/null 2>&1
		else
			rm -f /opt/clash/config.yaml
		fi
		echo '{"error":"restart_failed"}'; exit 1
	fi
	if [ "$CURRENT" != "$PROFILE" ]; then
		if [ -e "$WORK/old.yaml" ] && [ "$OLD_MODE" != "$(ssc_interface_mode "$WORK/old.yaml")" ]; then
			printf '%s\n' "$OLD_MODE" > "/opt/clash/.5gmodem-mode.$CURRENT"
		else
			rm -f "/opt/clash/.5gmodem-mode.$CURRENT"
		fi
	fi
	if [ "$KIND" = legacy ]; then
		printf '%s\n' "$PROFILE" > "$WORK/selected"
		mv -f "$WORK/selected" /opt/clash/.5gmodem-profile || { echo '{"error":"save_failed"}'; exit 1; }
	fi
	echo '{"ok":true}'
	;;
detect)
	KIND="$2"
	ssc_present "$KIND" || { echo '{"present":0}'; exit 0; }

	if [ "$KIND" = go ]; then
		PORT=$( { ss -tlnp 2>/dev/null; netstat -tlnp 2>/dev/null; } \
			| awk '/ssclash/{print $4}' | grep -oE '[0-9]+$' | head -1)
		if [ -z "$PORT" ]; then
			PORT=$(sed -n "s/^[[:space:]]*procd_set_param env SSCLASH_ADDR=[\"']*[^:]*:\([0-9]*\).*/\1/p" \
				/etc/init.d/ssclash 2>/dev/null | head -1)
		fi
		case "$PORT" in ''|*[!0-9]*) PORT=9091 ;; esac
		SCHEME=http
		grep -qE "^[[:space:]]*procd_set_param env SSCLASH_TLS_CERT" /etc/init.d/ssclash 2>/dev/null && SCHEME=https
		UPATH="/"
		VER=""
		[ -x /opt/clash/bin/ssclash ] && VER=$(/opt/clash/bin/ssclash version 2>/dev/null \
			| grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
		case "$VER" in v*) ;; ?*) VER="v$VER" ;; esac
	else
		PORT=$(sed -n "s/^[[:space:]]*external-controller:[[:space:]]*['\"]*[^:]*:\([0-9]*\).*/\1/p" \
			/opt/clash/config.yaml 2>/dev/null | head -1)
		case "$PORT" in ''|*[!0-9]*) PORT=9090 ;; esac
		SCHEME=http
		UPATH="/ui/"
		VER=$( { opkg list-installed luci-app-ssclash 2>/dev/null; \
			apk list -I luci-app-ssclash 2>/dev/null; } \
			| grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		[ -n "$VER" ] || VER=$(/opt/clash/bin/clash -v 2>/dev/null \
			| grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		case "$VER" in v*) ;; ?*) VER="v$VER" ;; esac
	fi

	printf '{"present":1,"kind":"%s","port":%s,"scheme":"%s","path":"%s","version":"%s"}\n' \
		"$KIND" "$PORT" "$SCHEME" "$UPATH" "$VER"
	;;
status)
	SVC=$(ssc_service "$2")
	R=0
	svc_running "$SVC" && R=1
	SWITCHING=0
	[ ! -d /tmp/5gmodem-profile-lock ] || SWITCHING=1
	RESULT='{}'
	[ ! -f /tmp/5gmodem-profile-result.json ] || RESULT=$(cat /tmp/5gmodem-profile-result.json)
	printf '{"running":%s,"switching":%s,"result":%s}\n' "$R" "$SWITCHING" "$RESULT"
	;;
*)
	echo '{"present":0}'
	;;
esac
