#!/bin/sh
# Детект SSClash для карточек-ссылок на веб-админку в блоке «Приоритет интернета».
# Две НЕЗАВИСИМЫЕ ветки одного проекта - могут стоять ОБЕ сразу (5.x нередко
# ставят поверх 4.7), у каждой СВОЯ карточка. Ветку задаёт вызывающий ($2):
#
#   go     - SSClash-Go 5.x: бинарь /opt/clash/bin/ssclash, сервис `ssclash`.
#     Веб-админка процесса `ssclash serve` на :9091 (env SSCLASH_ADDR в
#     /etc/init.d/ssclash), путь "/". Версия: `ssclash version` -> v5.x.
#
#   legacy - SSClash 4.7.x: пакет luci-app-ssclash, сервис `clash`, бинарь
#     /opt/clash/bin/clash (mihomo). Своего веб-сервера нет: дашборд отдаёт САМ
#     clash через external-controller (config.yaml :9090) + external-ui, путь
#     "/ui/". Версия - из пакета luci-app-ssclash (не ядра clash/mihomo).
#
# Использование: ssclash.sh detect <go|legacy> | ssclash.sh status <go|legacy>

# Присутствует ли ветка $1 (go|legacy)? Ветки проверяются НЕЗАВИСИМО.
ssc_present() {
	case "$1" in
		go)     [ -x /opt/clash/bin/ssclash ] || [ -f /etc/init.d/ssclash ] ;;
		legacy) [ -f /etc/init.d/clash ] && [ -x /opt/clash/bin/clash ] ;;
		*)      return 1 ;;
	esac
}

# Имя init-сервиса ветки.
ssc_service() { [ "$1" = legacy ] && echo clash || echo ssclash; }

case "$1" in
detect)
	KIND="$2"
	ssc_present "$KIND" || { echo '{"present":0}'; exit 0; }

	if [ "$KIND" = go ]; then
		# Порт - РЕАЛЬНО слушающий процесс ssclash (переживает смену SSCLASH_ADDR).
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
	else
		# legacy: порт дашборда = external-controller самого clash (config.yaml).
		PORT=$(sed -n "s/^[[:space:]]*external-controller:[[:space:]]*['\"]*[^:]*:\([0-9]*\).*/\1/p" \
			/opt/clash/config.yaml 2>/dev/null | head -1)
		case "$PORT" in ''|*[!0-9]*) PORT=9090 ;; esac
		SCHEME=http
		UPATH="/ui/"
		# Версия САМОГО SSClash - из пакета luci-app-ssclash. ACL уже разрешает
		# opkg/package-manager-call list-installed. Фолбэк - ядро clash.
		VER=$( { opkg list-installed luci-app-ssclash 2>/dev/null; \
			apk list -I luci-app-ssclash 2>/dev/null; } \
			| grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		[ -n "$VER" ] || VER=$(/opt/clash/bin/clash -v 2>/dev/null \
			| grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		# Префикс "v" для единообразия с go ("v5.x"); пакет отдаёт голое "4.7.0".
		case "$VER" in v*) ;; ?*) VER="v$VER" ;; esac
	fi

	printf '{"present":1,"kind":"%s","port":%s,"scheme":"%s","path":"%s","version":"%s"}\n' \
		"$KIND" "$PORT" "$SCHEME" "$UPATH" "$VER"
	;;
status)
	# Запущен ли сервис указанной ветки - для «живой» точки в карточке.
	SVC=$(ssc_service "$2")
	R=0
	if ubus -S call service list "{\"name\":\"$SVC\"}" 2>/dev/null | grep -q '"running": *true'; then
		R=1
	elif [ -x "/etc/init.d/$SVC" ] && "/etc/init.d/$SVC" status >/dev/null 2>&1; then
		R=1
	fi
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"present":0}'
	;;
esac
