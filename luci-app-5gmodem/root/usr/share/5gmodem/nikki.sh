#!/bin/sh
# Детект nikki (mihomo) для карточки-ссылки на веб-панель в блоке «Приоритет
# интернета». Контракт вербов и формат JSON - ТОТ ЖЕ, что у ssclash.sh, чтобы
# фронт дёргал оба одинаково:
#
#   nikki.sh detect | nikki.sh status
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ТРЕТЬЯ ВЕТКА В ssclash.sh. Там две ветки ОДНОГО
# проекта (SSClash 4.7.x и 5.x): общий каталог /opt/clash, общее ядро. nikki -
# другой проект целиком (nikkinikki-org/OpenWrt-nikki): свой сервис, свои пути,
# свой формат конфига. Под именем ssclash.sh он врал бы именем файла.
#
# УСТРОЙСТВО NIKKI (сверено с исходниками апстрима):
#   сервис - /etc/init.d/nikki (procd), ядро - /usr/bin/mihomo;
#   рабочий конфиг - /etc/nikki/run/config.yaml. Он ГЕНЕРИТСЯ из uci при старте
#     сервиса (files/ucode/mixin.uc), поэтому именно он, а не uci, - правда о
#     том, что реально слушает процесс: человек мог поправить mixin и не
#     перезапустить сервис. До первого старта файла нет вовсе - тогда читаем
#     uci-секцию mixin, иначе карточка не появилась бы никогда.
#   панель отдаёт САМ mihomo через external-ui (своего веб-сервера у nikki нет -
#     как у ветки legacy в ssclash.sh). Путь - "/ui/", а при заданном
#     external-ui-name - "/ui/<имя>/": так строит ссылку сам luci-app-nikki
#     (tools/nikki.js, openDashboard), и расходиться с ним нельзя.
#   ключи uci в секции mixin: api_listen -> external-controller,
#     api_tls_listen -> external-controller-tls, ui_name -> external-ui-name,
#     api_secret -> secret.

RUN_CFG=/etc/nikki/run/config.yaml
CORE=/usr/bin/mihomo

. /usr/share/5gmodem/lib.sh 2>/dev/null

# Экранирование для JSON. Секрет и имя UI задаёт человек - там бывает всё.
n_esc() {
	case "$1" in
		*\\*|*\"*) printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*)         printf '%s' "$1" ;;
	esac
}

# Значение ключа ВЕРХНЕГО УРОВНЯ из config.yaml. Кавычки снимаем: yq пишет
# строки то в них, то без, и '[::]:9090' в кавычках - обычное дело.
yml_get() {
	[ -f "$RUN_CFG" ] || return 1
	sed -n "s/^$1:[[:space:]]*//p" "$RUN_CFG" 2>/dev/null | head -1 \
		| sed "s/[[:space:]]*$//; s/^['\"]//; s/['\"]$//"
}

uci_get() { uci -q get "nikki.mixin.$1" 2>/dev/null; }

# Порт из адреса вида "[::]:9090", "0.0.0.0:9090", ":9090" или голого "9090".
#
# БЕРЁМ ХВОСТ ПОСЛЕ ПОСЛЕДНЕГО ДВОЕТОЧИЯ, а не «всё до первого - хост», как
# разбирают ветки ssclash: у nikki умолчание api_listen это '[::]:9090', и
# разбор через [^:]* на нём даёт мусор вместо порта.
addr_port() {
	_ap="$1"
	case "$_ap" in *:*) _ap="${_ap##*:}" ;; esac
	case "$_ap" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s' "$_ap"
}

# Установлен ли nikki. Init-скрипт обязателен (без него в карточке нечего
# показывать), ядро ИЛИ каталог конфига - подтверждение, что это правда nikki.
nikki_present() {
	[ -f /etc/init.d/nikki ] || return 1
	[ -x "$CORE" ] || [ -f "$RUN_CFG" ] || [ -d /etc/nikki ] || return 1
	return 0
}

case "$1" in
detect)
	nikki_present || { echo '{"present":0}'; exit 0; }

	# TLS ИМЕЕТ ПРИОРИТЕТ: если api слушает по https, ссылка на http просто не
	# откроется. Пустой api_tls_listen - обычный случай.
	TLSA=$(yml_get 'external-controller-tls'); [ -n "$TLSA" ] || TLSA=$(uci_get api_tls_listen)
	PORT=$(addr_port "$TLSA") && SCHEME=https
	if [ -z "$PORT" ]; then
		ADDR=$(yml_get 'external-controller'); [ -n "$ADDR" ] || ADDR=$(uci_get api_listen)
		PORT=$(addr_port "$ADDR")
		SCHEME=http
	fi
	# Умолчание апстрима - '[::]:9090'. Дошли сюда без порта - конфига ещё нет и
	# uci пуст; показать карточку с рабочим умолчанием честнее, чем спрятать её.
	case "$PORT" in ''|*[!0-9]*) PORT=9090; SCHEME=http ;; esac

	# Имя UI - подкаталог панели. Пусто - панель лежит прямо в /ui/.
	UINAME=$(yml_get 'external-ui-name'); [ -n "$UINAME" ] || UINAME=$(uci_get ui_name)
	case "$UINAME" in
		''|null) UPATH="/ui/" ;;
		*)       UPATH="/ui/$UINAME/" ;;
	esac

	# Секрет api. Без него панель встретит формой ввода пароля - luci-app-nikki
	# по той же причине подставляет его в ссылку query-параметром.
	SECRET=$(yml_get 'secret'); [ -n "$SECRET" ] || SECRET=$(uci_get api_secret)
	case "$SECRET" in null) SECRET="" ;; esac

	# ВЕРСИЯ - ПАКЕТА nikki, а не ядра: карточка про nikki, и апгрейдят люди
	# именно пакет (нумерация там датой: 2026.04.08). Фолбэк - ядро mihomo: у
	# кого стоит только оно, пусть в карточке будет хоть что-то.
	VER=$( { opkg list-installed nikki 2>/dev/null; apk list -I nikki 2>/dev/null; } \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
	[ -n "$VER" ] || VER=$([ -x "$CORE" ] && "$CORE" -v 2>/dev/null \
		| grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
	# «v» ставим САМИ - ровно как в ssclash.sh: пакетный менеджер отдаёт голое
	# «1.2.3», ядро печатает «v1.19.2», а вид у карточек должен быть один.
	case "$VER" in v*) ;; ?*) VER="v$VER" ;; esac

	printf '{"present":1,"kind":"nikki","port":%s,"scheme":"%s","path":"%s","version":"%s","secret":"%s"}\n' \
		"$PORT" "$SCHEME" "$(n_esc "$UPATH")" "$(n_esc "$VER")" "$(n_esc "$SECRET")"
	;;
status)
	# Запущен ли сервис - для «живой» точки в карточке. Спрашиваем ОБЩИМ
	# svc_running (lib.sh), а не самодельной парой ubus + `status`: у procd
	# `status` на остановленном сервисе печатает «active with no instances» и
	# выходит с нулём, и точка горела зелёной при мёртвом nikki. Замерено на
	# стенде 09.09.2026 - см. комментарий у svc_running.
	R=0
	svc_running nikki && R=1
	printf '{"running":%s}\n' "$R"
	;;
*)
	echo '{"present":0}'
	;;
esac
