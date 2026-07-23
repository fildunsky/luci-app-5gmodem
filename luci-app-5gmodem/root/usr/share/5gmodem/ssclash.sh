#!/bin/sh
# Детект SSClash-Go для быстрой ссылки на его веб-админку в блоке «Приоритет
# интернета». SSClash-Go 5.x - однобинарник (/opt/clash/bin/ssclash), веб-админка
# процесса `ssclash serve` по умолчанию на :9091 (порт задаётся env SSCLASH_ADDR
# в /etc/init.d/ssclash; API самого clash - это ДРУГОЙ порт, external-controller,
# нам он не нужен).

case "$1" in
detect)
	# Наличие: бинарь или init-сервис.
	if [ ! -x /opt/clash/bin/ssclash ] && [ ! -f /etc/init.d/ssclash ]; then
		echo '{"present":0}'; exit 0
	fi

	# Порт. Приоритет - РЕАЛЬНО слушающий процесс ssclash (переживает смену
	# конфига и SSCLASH_ADDR). $4 = локальный адрес ("*:9091"/":::9091"), берём
	# хвостовое число. netstat и ss дают совместимый формат - пробуем оба.
	PORT=$( { ss -tlnp 2>/dev/null; netstat -tlnp 2>/dev/null; } \
		| awk '/ssclash/{print $4}' | grep -oE '[0-9]+$' | head -1)
	# Фолбэк 1: SSCLASH_ADDR из init.d (если сервис остановлен).
	if [ -z "$PORT" ]; then
		PORT=$(sed -n "s/^[[:space:]]*procd_set_param env SSCLASH_ADDR=[\"']*[^:]*:\([0-9]*\).*/\1/p" \
			/etc/init.d/ssclash 2>/dev/null | head -1)
	fi
	# Фолбэк 2: документированный дефолт.
	case "$PORT" in ''|*[!0-9]*) PORT=9091 ;; esac

	# Схема: https, только если TLS-cert РАСКОММЕНТИРОВАН в init.d (по дефолту нет).
	SCHEME=http
	grep -qE "^[[:space:]]*procd_set_param env SSCLASH_TLS_CERT" /etc/init.d/ssclash 2>/dev/null && SCHEME=https

	# Версия: `ssclash version` -> "ssclash v5.1.1". Пусто, если бинаря нет/молчит.
	VER=""
	[ -x /opt/clash/bin/ssclash ] && VER=$(/opt/clash/bin/ssclash version 2>/dev/null \
		| grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)

	printf '{"present":1,"port":%s,"scheme":"%s","version":"%s"}\n' "$PORT" "$SCHEME" "$VER"
	;;
status)
	# Запущен ли сервис - для «живой» точки в карточке «Приоритета интернета».
	# procd (service list running:true) надёжнее текста init.d status.
	R=0
	if ubus -S call service list '{"name":"ssclash"}' 2>/dev/null | grep -q '"running": *true'; then
		R=1
	elif [ -x /etc/init.d/ssclash ] && /etc/init.d/ssclash status >/dev/null 2>&1; then
		R=1
	fi
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"present":0}'
	;;
esac
