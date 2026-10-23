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

case "$1" in
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
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"present":0}'
	;;
esac
