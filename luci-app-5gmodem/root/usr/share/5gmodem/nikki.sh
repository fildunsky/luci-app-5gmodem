#!/bin/sh

RUN_CFG=/etc/nikki/run/config.yaml
CORE=/usr/bin/mihomo

. /usr/share/5gmodem/lib.sh 2>/dev/null

n_esc() {
	case "$1" in
		*\\*|*\"*) printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*)         printf '%s' "$1" ;;
	esac
}

yml_get() {
	[ -f "$RUN_CFG" ] || return 1
	sed -n "s/^$1:[[:space:]]*//p" "$RUN_CFG" 2>/dev/null | head -1 \
		| sed "s/[[:space:]]*$//; s/^['\"]//; s/['\"]$//"
}

uci_get() { uci -q get "nikki.mixin.$1" 2>/dev/null; }

addr_port() {
	_ap="$1"
	case "$_ap" in *:*) _ap="${_ap##*:}" ;; esac
	case "$_ap" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$_ap"
}

nikki_present() {
	[ -f /etc/init.d/nikki ] || return 1
	[ -x "$CORE" ] || [ -f "$RUN_CFG" ] || [ -d /etc/nikki ] || return 1
	return 0
}

case "$1" in
detect)
	nikki_present || { echo '{"present":0}'; exit 0; }

	TLSA=$(yml_get 'external-controller-tls'); [ -n "$TLSA" ] || TLSA=$(uci_get api_tls_listen)
	PORT=$(addr_port "$TLSA") && SCHEME=https
	if [ -z "$PORT" ]; then
		ADDR=$(yml_get 'external-controller'); [ -n "$ADDR" ] || ADDR=$(uci_get api_listen)
		PORT=$(addr_port "$ADDR")
		SCHEME=http
	fi
	case "$PORT" in ''|*[!0-9]*) PORT=9090; SCHEME=http ;; esac

	UINAME=$(yml_get 'external-ui-name'); [ -n "$UINAME" ] || UINAME=$(uci_get ui_name)
	case "$UINAME" in
		''|null) UPATH="/ui/" ;;
		*)       UPATH="/ui/$UINAME/" ;;
	esac

	SECRET=$(yml_get 'secret'); [ -n "$SECRET" ] || SECRET=$(uci_get api_secret)
	case "$SECRET" in null) SECRET="" ;; esac

	VER=$( { opkg list-installed nikki 2>/dev/null; apk list -I nikki 2>/dev/null; } \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	[ -n "$VER" ] || VER=$([ -x "$CORE" ] && "$CORE" -v 2>/dev/null \
		| grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
	case "$VER" in v*) ;; ?*) VER="v$VER" ;; esac

	printf '{"present":1,"kind":"nikki","port":%s,"scheme":"%s","path":"%s","version":"%s","secret":"%s"}\n' \
		"$PORT" "$SCHEME" "$(n_esc "$UPATH")" "$(n_esc "$VER")" "$(n_esc "$SECRET")"
	;;
status)
	R=0
	svc_running nikki && R=1
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"present":0}'
	;;
esac
