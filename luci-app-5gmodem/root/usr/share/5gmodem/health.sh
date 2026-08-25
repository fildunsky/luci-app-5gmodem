#!/bin/sh
# Сторож интернета для «Приоритета интернета» (этап 1: только наблюдение).
#
# Зачем: ядро переключает трафик лишь когда линк ТЕРЯЕТ маршрут (ifdown, отвал
# USB, конец аренды). Модем с живым IP, которого оператор перестал выпускать в
# сеть, для ядра здоров - и трафик льётся в дыру. Единственный способ это
# увидеть - активная проверка через КОНКРЕТНЫЙ интерфейс.
#
# Как: раз в interval секунд каждый аплинк wan-зоны пингуется с привязкой к его
# устройству (ping -I <dev> - так же трекает mwan3: SO_BINDTODEVICE гонит пакет
# через устройство даже когда default смотрит в другой линк). Вердикт - с
# гистерезисом: «упал» после fail_n провалов ПОДРЯД, «ожил» после ok_n успехов
# ПОДРЯД. Без гистерезиса на сотовой связи вердикт флапал бы на каждой потере
# пакета.
#
# Этап 1 намеренно ничего НЕ переключает и НЕ лечит - только копит состояние
# для точек здоровья на карточках. Переключение штрафным маршрутом и лестница
# лечения - следующие этапы, поверх этого же состояния.
#
# Состояние: /tmp/5gmodem_health/<iface> = "state fails oks ms since"
#   state - up|down|unknown, since - uptime_s последней СМЕНЫ state,
#   ms - время последнего успешного пинга. Файлы переживают выключение слежения
#   (протухшие точки честнее прятать в status, а не терять историю).
#
# Вызовы: tick (из цикла sessionwatch), status (JSON для страницы), once
# (принудительный круг без rate-limit, для отладки), event <iface> (внеочередной
# круг по hotplug-событию ifup/ifdown аплинка), setconf k=v... (настройки).

RES="/usr/share/5gmodem"
. "$RES/lib.sh"

HDIR=/tmp/5gmodem_health
CFG=5gmodem

# ОДИННАДЦАТЬ НАСТРОЕК ЧИТАЮТСЯ ИЗ ОДНОЙ СЕКЦИИ - БЕРЁМ ЕЁ ОДНИМ СНИМКОМ.
# Замер на стенде: `uci get` - 3 мс на ключ (33 мс на все), снимок секции - один
# спавн 4 мс плюс 0.8 мс на чтение. Полный дамп конфига здесь пробовался и
# ЗАМЕДЛИЛ вызов на 30 мс - почему, записано в lib.sh над _uci_snap_get.
# Писатели (setconf/setheal) ходят в uci напрямую и уже после всех чтений.
uci5g_sec_snapshot health

conf() { uci5g_sec_get "$1"; }

H_EN=$(conf enabled)
# ВЫКЛЮЧЕННЫЙ ВИДЖЕТ «ПРИОРИТЕТ ИНТЕРНЕТА» ВЫКЛЮЧАЕТ И СТОРОЖ ЦЕЛИКОМ.
# Иначе панель скрыта (widget_netpri=0), а сторож продолжает невидимо пинговать,
# уводить трафик штрафами и лечить модемы - и шестерёнка, которой его выключить,
# спрятана вместе с панелью. Правило: нет виджета = нет функции, без остатка.
[ "$(uci -q get "$CFG.@5gmodem[0].widget_netpri")" = "0" ] && H_EN=0
H_INT=$(conf interval);  case "$H_INT" in ''|*[!0-9]*) H_INT=30 ;; esac
H_TGT=$(conf targets);   [ -n "$H_TGT" ] || H_TGT="77.88.8.8 1.1.1.1"
H_FAILN=$(conf fail_n);  case "$H_FAILN" in ''|*[!0-9]*) H_FAILN=3 ;; esac
H_OKN=$(conf ok_n);      case "$H_OKN" in ''|*[!0-9]*) H_OKN=5 ;; esac
H_FO=$(conf failover)
# Что делать с ожившим линком: restore - вернуть его приоритет (по умолчанию),
# demote - оставить В КОНЦЕ (упавший считается ненадёжным, пока пользователь
# сам не вернёт его перетаскиванием/кликом - netpri set/order снимают метку).
H_FB=$(conf failback); [ "$H_FB" = "demote" ] || H_FB="restore"
# Линки «только вручную» (список имён через пробел): такой линк не получает
# трафик автоматически - его default держится со штрафной метрикой, пока
# пользователь сам не сделает его первым (клик/перетаскивание в ряду
# приоритетов снимают штраф, потому что первым становится его порядок).
# Кейс владельца пожелания: резервный STA-аплинк к смартфону - точки давно
# нет в эфире, а «резерв» перехватывал трафик.
H_MAN=$(conf manual)
is_manual() { case " $H_MAN " in *" $1 "*) return 0 ;; esac; return 1; }
# Гард «пробы блокированы фаерволом»: все прямые пробы легли, но через
# локальный прокси (clash) интернет есть - значит, минимум один линк жив, а
# прямой выход режет killswitch VPN. Лечить железо в этой ситуации нельзя.
H_PG=$(conf proxy_guard); [ "$H_PG" = "0" ] || H_PG=1
# Мастер-выключатель лечения: потолки на модемах - ЧТО можно делать, эта
# настройка - можно ли ВООБЩЕ (галка блока «Лечить модем» в модалке).
# ПО УМОЛЧАНИЮ ВКЛЮЧЕНО (решение владельца 19.08.2026): выключенное лечение
# оставляло типовые самолечимые отказы (SIM illegal у EP06, MM-disabled)
# лежать до ручного вмешательства, а включить его в этот момент было нечем -
# упавший интерфейс исчезает из списка аплинков вместе с настройкой. Явное
# «0» пользователя уважается.
H_HEAL=$(conf healing); [ "$H_HEAL" = "0" ] || H_HEAL=1
# Лечение Wi-Fi-аплинка (галка под модемами): у него своя короткая лестница -
# переподключить интерфейс, затем пересобрать сеть (network reload + wifi up).
# Вторая ступень лечит живой класс отказа: netifd расцепляет интерфейс с
# радио при шторме энумерации USB (NO_DEVICE при ассоциированном радио) -
# ifup такое не берёт, только reload.
# ПО УМОЛЧАНИЮ ВКЛЮЧЕНО (24.08.2026), как и лечение модемов. Живой класс
# отказа: STA теряет маяки, netifd держит интерфейс up со старой арендой, и
# без переассоциации она висит мёртвой до вмешательства руками - ровно в тот
# момент, когда человек ушёл из зоны своей точки и рассчитывает на модем.
# Явное «0» пользователя уважается (миграция снимает только тот '0', что
# записала сама модалка).
H_HEALWIFI=$(conf heal_wifi); [ "$H_HEALWIFI" = "0" ] || H_HEALWIFI=1

# Состав wan-зоны за круг не меняется, а спрашивают его трижды (round дважды,
# event один раз) - и каждый раз это два процесса. Считаем один раз.
_WANNETS=""; _WANNETS_DONE=""
wan_nets() {
	if [ -z "$_WANNETS_DONE" ]; then
		_WANNETS_DONE=1
		_z=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.name='wan'\$/\1/p" | head -1)
		[ -n "$_z" ] && _WANNETS=$(uci -q get "firewall.$_z.network")
		# плюс аплинки вне зоны wan (LAN-DHCP на однопортовых роутерах,
		# см. extra_uplink_nets в lib.sh): сторож обязан видеть и их -
		# иначе линк, реально несущий default, живёт без проб и штрафов
		_WANNETS="$_WANNETS $(extra_uplink_nets "$_WANNETS" | tr '\n' ' ')"
	fi
	printf '%s\n' "$_WANNETS"
}

# Событие для строки под панелью приоритета + журнал. Одно текущее событие,
# а не свой журнал: полная история и так в logread по тегу.
_ev() {
	logger -t 5gmodem "watchdog: $1"
	mkdir -p "$HDIR"
	printf '%s %s\n' "$(date '+%H:%M')" "$1" > "$HDIR/.last_event"
}

# Секция модема, владеющего интерфейсом: по network= и непустому path (парковки
# и осиротевшие секции без path не годятся - лечить нечего).
sec_for_iface_h() {
	for _sfs in $(uci show "$CFG" 2>/dev/null | sed -n "s/^5gmodem\.\([^.]*\)=modem\$/\1/p"); do
		[ "$(uci -q get "$CFG.$_sfs.network")" = "$1" ] || continue
		[ -n "$(uci -q get "$CFG.$_sfs.path")" ] || continue
		printf '%s\n' "$_sfs"
		return 0
	done
	return 1
}

# Wi-Fi-аплинк? Судим по КОНФИГУ беспроводки (wifi-iface с network=<имя>),
# а не по живому устройству: в состоянии gone устройства как раз нет.
_WLDUMP=""; _WLDUMP_DONE=""
is_wifi_iface() {
	if [ -z "$_WLDUMP_DONE" ]; then
		_WLDUMP_DONE=1
		_WLDUMP=$(uci show wireless 2>/dev/null)
	fi
	case "$_WLDUMP" in
		*".network='$1'"*) return 0 ;;
		*) return 1 ;;
	esac
}

# Радио (radio0/radio1), на котором живёт станция этого интерфейса. Нужно, чтобы
# лечить ТОЧЕЧНО: пересобрать одно радио, а не всю сеть роутера.
wifi_radio_for() {   # $1 - интерфейс
	is_wifi_iface "$1" || return 1
	_wr_s=$(printf '%s\n' "$_WLDUMP" | sed -n "s/^wireless\.\([^.]*\)\.network='\?$1'\?\$/\1/p" | head -1)
	[ -n "$_wr_s" ] || return 1
	printf '%s\n' "$_WLDUMP" | sed -n "s/^wireless\.$_wr_s\.device='\?\([^']*\)'\?\$/\1/p" | head -1
}

# Устройство аплинка: l3_device родителя, иначе - динамического ребёнка
# "<имя>_4" (qmi/dhcp-модемы держат адрес на нём, родитель стоит без IP).
iface_dev() {
	printf '%s' "$_HDUMP" | jsonfilter -e "@.interface[@.interface=\"$1\"].l3_device" 2>/dev/null | head -1
}

# Один пинг через устройство. Успех - хотя бы один адрес ответил; время (мс)
# отдаём в H_MS. Таймауты - средствами самого ping (-W): busybox timeout не
# имеет, и внешний сторож тут не нужен.
probe_dev() {
	_pd_dev="$1"; H_MS=""
	for _pd_t in $H_TGT; do
		_pd_o=$(ping -I "$_pd_dev" -c 1 -W 2 "$_pd_t" 2>/dev/null)
		# FAKE-IP (clash/ssclash, 198.18.0.0/15): доменная цель разрешилась в
		# фиктивный адрес - такой пинг меряет НЕ линк, а туннель или локальный
		# ответчик clash, и врёт в ОБЕ стороны (мгновенный «успех» при мёртвом
		# WAN либо гарантированный провал мимо туннеля). Цель пропускаем;
		# дефолтные ЦИФРОВЫЕ адреса сюда не попадают никогда.
		case "$_pd_o" in
			*"(198.18."*|*"(198.19."*) continue ;;
		esac
		case "$_pd_o" in
			*" 0% packet loss"*|*"1 packets received"*)
				H_MS=$(printf '%s\n' "$_pd_o" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1)
				H_MS="${H_MS%%.*}"
				return 0 ;;
		esac
	done
	# ВТОРОЕ МНЕНИЕ - TCP-КОННЕКТ. Часть операторов режет ICMP целиком: линк
	# жив, а пинг молчит - вердикт down был бы ложным, и за ним пошло бы ложное
	# ЛЕЧЕНИЕ здорового модема. Пробуем TCP на 443 к тем же целям с той же
	# привязкой к устройству (мимо туннелей, как и ICMP). Только ЦИФРОВЫЕ
	# адреса: домен под fake-ip разрешится в фикцию, честно через устройство
	# его не померить. Успех = TCP-рукопожатие (time_connect > 0), ответ
	# HTTP/TLS не важен - нам нужен факт прохождения пакетов по линку.
	command -v curl >/dev/null 2>&1 || return 1
	for _pd_t in $H_TGT; do
		case "$_pd_t" in *[A-Za-z]*) continue ;; esac
		_pd_tc=$(curl -s -m 3 --interface "$_pd_dev" -o /dev/null -w '%{time_connect}' "https://$_pd_t/" 2>/dev/null)
		case "$_pd_tc" in
			''|0|0.000000) ;;
			*)
				H_MS=$(printf '%s' "$_pd_tc" | awk '{printf "%d", $1 * 1000}')
				return 0 ;;
		esac
	done
	return 1
}

# Интернет через локальный прокси (clash)? Отвечает на вопрос «есть ли инет
# ВООБЩЕ», а не «жив ли линк»: прокси не привязан к устройству. Успех при
# провале всех прямых проб доказывает, что пробы режет фаервол: путь прокси
# сам идёт через один из наших линков. -k осознанно: нужна достижимость цели,
# а не подлинность сертификата на голом IP.
probe_proxy() {
	command -v curl >/dev/null 2>&1 || return 1
	_pp_p=$(net_proxy_port) || return 1
	for _pp_t in $H_TGT; do
		case "$_pp_t" in *[A-Za-z]*) continue ;; esac
		curl -sk -m 5 -x "http://127.0.0.1:$_pp_p" -o /dev/null "https://$_pp_t/" 2>/dev/null && return 0
	done
	return 1
}

# Гистерезис одного линка. Читаем прежнее состояние, применяем результат пробы,
# пишем новое. Смена state логируется - строка событий в UI и доверие к
# автоматике строятся на этом.
judge() {
	_j_if="$1"; _j_ok="$2"; _j_ms="$3"
	_j_st=unknown; _j_f=0; _j_o=0; _j_lms=""; _j_since=$(uptime_s)
	[ -f "$HDIR/$_j_if" ] && read -r _j_st _j_f _j_o _j_lms _j_since < "$HDIR/$_j_if"
	_j_new="$_j_st"
	if [ "$_j_ok" = 1 ]; then
		_j_f=0; _j_o=$((_j_o + 1)); _j_lms="$_j_ms"
		# из unknown/gone поднимаемся с первого же успеха: наказывать свежий
		# (или вернувшийся на шину) линк полным ok_n незачем, гистерезис нужен
		# против ФЛАПА, а не старта
		case "$_j_st" in unknown|gone) _j_new=up ;; esac
		[ "$_j_st" = down ] && [ "$_j_o" -ge "$H_OKN" ] && _j_new=up
	else
		_j_o=0; _j_f=$((_j_f + 1))
		[ "$_j_st" != down ] && [ "$_j_f" -ge "$H_FAILN" ] && _j_new=down
	fi
	if [ "$_j_new" != "$_j_st" ]; then
		_j_since=$(uptime_s)
		if [ "$_j_new" = up ]; then
			# «Ожил после ПАДЕНИЯ» - это и down->up, и gone->up с активной
			# лестницей (перезагрузка модуля лестницей проходит через gone,
			# память о падении несёт heal-файл). Свежий линк (unknown->up,
			# первое подключение) падением не считается - его не понижаем.
			_j_wasdown=""
			[ "$_j_st" = down ] && _j_wasdown=1
			[ "$_j_st" = gone ] && [ -f "$HDIR/$_j_if.heal" ] && _j_wasdown=1
			# ожил - лестница лечения начинается с нуля при следующем падении
			rm -f "$HDIR/$_j_if.heal" "$HDIR/$_j_if.nosim" "$HDIR/$_j_if.nodata" "$HDIR/$_j_if.mmoff"
			if [ "$H_FB" = "demote" ] && [ -n "$_j_wasdown" ]; then
				: > "$HDIR/$_j_if.demoted"
				_ev "link $_j_if is back - kept at the end (per settings)"
			else
				_ev "link $_j_if is back"
			fi
		else
			_ev "link $_j_if went down (missed $_j_f/$H_FAILN pings)"
		fi
	fi
	printf '%s %s %s %s %s\n' "$_j_new" "$_j_f" "$_j_o" "${_j_lms:-0}" "$_j_since" > "$HDIR/$_j_if.tmp" \
		&& mv "$HDIR/$_j_if.tmp" "$HDIR/$_j_if"
}

round() {
	mkdir -p "$HDIR"
	# штамп круга - здесь, а не только в tick: age в status обязан отражать
	# ЛЮБОЙ круг (once с страницы - тоже круг), иначе точки выглядят протухшими
	uptime_s > "$HDIR/.t"
	_HDUMP=$(ubus call network.interface dump 2>/dev/null)
	for _r_n in $(wan_nets); do
		# IPv6-спутники не проверяем: приоритет и здоровье - свойства линка,
		# а не семейства адресов (правило то же, что в netpri.sh list)
		case "$_r_n" in
			*6) _r_p=$(uci -q get "network.$_r_n.proto")
			    case "$_r_p" in dhcpv6|6in4|6to4|6rd) continue ;; esac ;;
		esac
		_r_dev=$(iface_dev "$_r_n")
		[ -n "$_r_dev" ] || _r_dev=$(iface_dev "${_r_n}_4")
		if [ -z "$_r_dev" ]; then
			# Устройства нет - это отдельное состояние «gone», а не удаление
			# следа: карточка на странице обязана ПЕРЕЖИТЬ переэнумерацию
			# (перезагрузка модуля лестницей - это десятки секунд без
			# устройства), прятать её решает list по грейс-периоду от since.
			#
			# НО только для линка С ИСТОРИЕЙ в этой загрузке: припаркованный
			# интерфейс (секция есть, железа нет и не было) файла состояния не
			# имеет - и не получает, иначе после включения слежения парковки
			# висели бы пунктирными слотами весь грейс-период.
			if [ -f "$HDIR/$_r_n" ]; then
				read -r _r_ost _ _ _ _r_osince < "$HDIR/$_r_n"
				_r_gs=$(uptime_s)
				[ "$_r_ost" = gone ] && _r_gs="$_r_osince"
				printf 'gone 0 0 0 %s\n' "$_r_gs" > "$HDIR/$_r_n.tmp" \
					&& mv "$HDIR/$_r_n.tmp" "$HDIR/$_r_n"
			else
				# НЕТ УСТРОЙСТВА И НЕТ ИСТОРИИ, НО ЖЕЛЕЗО НА ШИНЕ - ЭТО НЕ ПАРКОВКА,
				# А МОДЕМ, НЕ СУМЕВШИЙ ПОДНЯТЬСЯ. После ребута роутера QMI-модем с
				# картой в illegal так и не отдаёт l3-устройство (netifd крутит
				# power-cycle SIM, потом сдаётся с autostart=false), а следа в этой
				# загрузке у него ещё нет - и без файла состояния лестница не видит
				# его НИКОГДА: связь не вернётся до вмешательства руками (ровно
				# случай Telit LM960 на стенде 12.08.2026). Заводим след gone
				# только когда секция модема реально присутствует на шине и
				# интерфейс не выключен человеком - тогда его берёт лестница (у неё
				# своя выдержка gone, проверка SIM и путь). Настоящую парковку
				# (секции/пути нет или железа нет на шине) это не трогает, слот
				# пунктиром не повиснет.
				_r_sec=$(sec_for_iface_h "$_r_n")
				if [ -n "$_r_sec" ]; then
					_r_pth=$(uci -q get "$CFG.$_r_sec.path")
					if [ -n "$_r_pth" ] && [ -e "/sys/bus/usb/devices/$_r_pth" ] \
					   && [ "$(uci -q get "network.$_r_n.auto")" != "0" ] \
					   && [ "$(uci -q get "network.$_r_n.disabled")" != "1" ]; then
						printf 'gone 0 0 0 %s\n' "$(uptime_s)" > "$HDIR/$_r_n.tmp" \
							&& mv "$HDIR/$_r_n.tmp" "$HDIR/$_r_n"
					fi
				fi
			fi
			continue
		fi
		if probe_dev "$_r_dev"; then judge "$_r_n" 1 "$H_MS"; else judge "$_r_n" 0 ""; fi
	done
	# ПОДЧИСТКА ПРИЗРАКОВ. Интерфейс мог исчезнуть из wan-зоны насовсем
	# (hilink при смене композиции пересоздаёт его под ДРУГИМ именем - живой
	# случай: modem5 -> modem4). Его файл состояния иначе жил бы вечно со
	# статусом «up» и ломал гварды «легли все»: призрачный anyup разрешал бы
	# штрафы и лечение при общей аварии.
	_r_zone=" $(wan_nets | tr '\n' ' ') "
	for _r_f in "$HDIR"/*; do
		[ -f "$_r_f" ] || continue
		case "$_r_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata) continue ;; esac
		_r_bn="${_r_f##*/}"
		case "$_r_zone" in
			*" $_r_bn "*) ;;
			*) rm -f "$_r_f" "$_r_f.heal" "$_r_f.demoted" "$_r_f.nosim" "$_r_f.nodata" "$_r_f.mmoff" ;;
		esac
	done
}

# ===== ЭТАП 2: ПЕРЕКЛЮЧЕНИЕ ШТРАФНЫМ МАРШРУТОМ =====
#
# Принцип: uci-метрики - это ПОРЯДОК ПОЛЬЗОВАТЕЛЯ, сторож их не трогает никогда
# (каждый commit network - это ещё и детонация чужих uci-дельт). Мёртвый линк
# наказывается ТОЛЬКО в живой таблице маршрутов: его default переставляется на
# метрику base+1000, и трафик сам уходит на следующий по порядку живой линк.
# Ожил - метрика возвращается, трафик приходит обратно (failback автоматом).
#
# Устойчивость к netifd: он в любой момент может переустановить маршрут с
# родной метрикой (передозвон, аренда). Мы не ловим его события - enforce
# просто ПЕРЕУТВЕРЖДАЕТ штрафы после каждого круга; окно неправильного
# маршрута ограничено интервалом проверки.
#
# ifdown мёртвого линка не делаем принципиально: проба ходит с привязкой к
# устройству и default ей не нужен, а вот PDP-сессия модема должна жить,
# иначе выздоровление нечем увидеть.

PEN=1000

# метрика линка по конфигу пользователя (его порядок); пусто = 0
base_metric() {
	_bm=$(uci -q get "network.$1.metric"); case "$_bm" in ''|*[!0-9]*) _bm=0 ;; esac
	printf '%s' "$_bm"
}

# Аргумент `table X` для v4-маршрутов интерфейса со своей таблицей (опция
# ip4table); пусто = main. Как в netpri.sh: default такого интерфейса живёт в
# его таблице, и правка main его не касалась (issue #12).
_rt4_args() {
	_r4=$(uci -q get "network.$1.ip4table" 2>/dev/null)
	[ -n "$_r4" ] && printf 'table %s' "$_r4"
}

# Переставить default-маршруты УСТРОЙСТВА на нужную метрику (обе семьи).
# Повторяем форму исходной строки: via сохраняем, on-link остаётся on-link.
# Смотрим и в main, и в свою таблицу интерфейса (у v6 таблица бывает у
# спутника "<имя>6"/"<имя>_6") - маршрут двигается там, где лежит.
_move_defaults() {   # $1 - dev, $2 - желаемая метрика, $3 - имя сети
	for _fam in -4 -6; do
		if [ "$_fam" = "-4" ]; then
			_mt_l="$(uci -q get "network.$3.ip4table" 2>/dev/null)"
		else
			_mt_l="$(uci -q get "network.$3.ip6table" 2>/dev/null) $(uci -q get "network.${3}6.ip6table" 2>/dev/null) $(uci -q get "network.${3}_6.ip6table" 2>/dev/null)"
		fi
		_mt_seen=""
		for _mt in "" $_mt_l; do
			case " $_mt_seen " in *" ${_mt:-main} "*) continue ;; esac
			_mt_seen="$_mt_seen ${_mt:-main}"
			_mt_a=""; [ -n "$_mt" ] && _mt_a="table $_mt"
			ip "$_fam" route show default $_mt_a 2>/dev/null | grep -E " dev $1( |$)" | while read -r _ln; do
				_cm=$(printf '%s' "$_ln" | sed -n 's/.*metric \([0-9]*\).*/\1/p'); _cm="${_cm:-0}"
				[ "$_cm" = "$2" ] && continue
				_gw=$(printf '%s' "$_ln" | sed -n 's/.*via \([^ ]*\).*/\1/p')
				# ПОРЯДОК ДОБАВИТЬ-ПОТОМ-УДАЛИТЬ. Метрика default-маршрута
				# уникальна в таблице целиком, и добавление СРЫВАЕТСЯ, если
				# нужную метрику уже занял ДРУГОЙ интерфейс. Удалив первым, мы
				# в этом случае оставляли линк вовсе без default - зелёный, но
				# без интернета до ребута. Теперь старый маршрут держится, пока
				# новый не встал; про сорвавшееся добавление route_add_default
				# пишет в журнал (метрики разные, конфликта между ними нет).
				route_add_default "$_fam" "$1" "$2" "$_gw" "$_mt_a" || continue
				ip "$_fam" route del default dev "$1" metric "$_cm" $_mt_a 2>/dev/null
			done
		done
	done
}

# ПРОПАВШИЙ DEFAULT-МАРШРУТ - ВЕРНУТЬ.
#
# ЖИВОЙ СЛУЧАЙ (Almond_13, 25.08.2026): пользователь переставил аплинк на
# модем, интерфейс поднят и с адресом, обе карточки зелёные - а default-
# маршрута у модема в таблице НЕТ вообще, трафик так и шёл по Wi-Fi. Пробы
# ходят с привязкой к устройству (`ping -I`), маршрут им не нужен - потому
# сторож и не видел беды, а _move_defaults переставляет только СУЩЕСТВУЮЩИЕ
# маршруты: нечего двигать - ничего и не делает. Дыра затягивалась ребутом.
#
# Маршрут не выдумываем: берём то, что знает netifd - у самой сети или у её
# динамического ребёнка ("<имя>_4"/"<имя>_6", туда qmi и mbim кладут адрес со
# шлюзом). netifd не знает default - значит его тут и не должно быть.
_nd_gw() {   # $1 - сеть, $2 - цель ("0.0.0.0"/"::"), $3 - суффикс ребёнка
	for _ng_n in "$1" "${1}$3"; do
		_ng_v=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_ng_n\"].route[@.target=\"$2\"].nexthop" 2>/dev/null | head -1)
		[ -n "$_ng_v" ] && { printf '%s' "$_ng_v"; return 0; }
	done
	return 1
}

_rt6_args() {
	for _r6 in "$(uci -q get "network.$1.ip6table" 2>/dev/null)" \
			"$(uci -q get "network.${1}6.ip6table" 2>/dev/null)" \
			"$(uci -q get "network.${1}_6.ip6table" 2>/dev/null)"; do
		[ -n "$_r6" ] && { printf 'table %s' "$_r6"; return 0; }
	done
}

_ensure_defaults() {   # $1 - dev, $2 - желаемая метрика, $3 - имя сети
	_ed_a=$(_rt4_args "$3")
	if ! ip -4 route show default $_ed_a 2>/dev/null | grep -qE " dev $1( |$)"; then
		if _ed_gw=$(_nd_gw "$3" "0.0.0.0" _4); then
			[ "$_ed_gw" = "0.0.0.0" ] && _ed_gw=""
			route_add_default -4 "$1" "$2" "$_ed_gw" "$_ed_a" && \
				_ev "$3 had no default route - restored (metric $2)"
		fi
	fi
	_ed_a6=$(_rt6_args "$3")
	if ! ip -6 route show default $_ed_a6 2>/dev/null | grep -qE " dev $1( |$)"; then
		if _ed_gw6=$(_nd_gw "$3" "::" _6); then
			[ "$_ed_gw6" = "::" ] && _ed_gw6=""
			[ -n "$_ed_gw6" ] && route_add_default -6 "$1" "$2" "$_ed_gw6" "$_ed_a6" && \
				_ev "$3 had no IPv6 default route - restored (metric $2)"
		fi
	fi
}

# РЕЗОЛВЕРЫ МЁРТВОГО ЛИНКА - УБРАТЬ ИЗ ОБЩЕГО СПИСКА.
#
# ЗАЧЕМ. Мы переключаем МАРШРУТ, но dnsmasq берёт апстримы из
# /tmp/resolv.conf.d/resolv.conf.auto, а его пишет netifd - и там серверы
# упавшего линка остаются, причём часто ПЕРВЫМИ. Живой класс отказа (STA
# ушедшего из дома роутера): станция потеряла маяки, netifd держит интерфейс
# up со старой арендой, наш штраф увёл трафик на модем - а каждое разрешение
# имени по-прежнему уходит на домашний 192.168.8.1, которого больше нет.
# Снаружи это «интернета нет», хотя пинг по IP работает; лечилось ребутом
# (пересборка resolv.conf.auto). С VPN поверх (clash со своим кэшем DNS)
# залипание тянется ещё дольше.
#
# Правила, все выстраданные:
#   - фильтруем ПЕРЕСБОРКОЙ файла на каждом круге: netifd в любой момент
#     пишет его заново, спорить с ним бессмысленно - проще привести к нужному
#     виду ещё раз (операция идемпотентна и стоит одно чтение файла);
#   - НИКОГДА не оставляем список пустым: если легли все линки, стухшие
#     серверы лучше, чем ни одного (иначе dnsmasq не ответит вообще);
#   - блок динамического ребёнка ("<имя>_4"/"_6") принадлежит тому же линку;
#   - dnsmasq перечитывает файл по SIGHUP - без рестарта службы.
_dns_demote() {   # $1 - имена мёртвых линков через пробел
	_dd_f=/tmp/resolv.conf.d/resolv.conf.auto
	[ -n "$1" ] || return 0
	[ -f "$_dd_f" ] || return 0
	_dd_out="$_dd_f.5gmodem"
	awk -v dead=" $1 " '
		/^# Interface / {
			ifc = $3
			sub(/_[46]$/, "", ifc)
			skip = (index(dead, " " ifc " ") > 0)
			if (skip) next
		}
		skip && /^nameserver /  { next }
		skip && /^# Interface / { }
		{ print }
	' "$_dd_f" > "$_dd_out" 2>/dev/null || { rm -f "$_dd_out"; return 0; }
	# страховка «не оставить систему без резолверов»
	if ! grep -q '^nameserver ' "$_dd_out" 2>/dev/null; then
		rm -f "$_dd_out"; return 0
	fi
	if cmp -s "$_dd_out" "$_dd_f"; then rm -f "$_dd_out"; return 0; fi
	cat "$_dd_out" > "$_dd_f" 2>/dev/null
	rm -f "$_dd_out"
	killall -HUP dnsmasq 2>/dev/null
	_ev "dropped DNS servers of the dead link(s):$1 - the resolver list follows the traffic now"
}

# Применить/снять штрафы по текущим вердиктам. Вызывается после каждого круга.
enforce() {
	_e_anyup=""; _e_cnt=0; _e_min=""; _e_dead=""
	for _e_f in "$HDIR"/*; do
		[ -f "$_e_f" ] || continue; case "$_e_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata) continue ;; esac
		read -r _e_st _ _ _ _ < "$_e_f" || continue
		_e_cnt=$((_e_cnt + 1))
		[ "$_e_st" = up ] && _e_anyup=1
		# минимальная метрика конфига - «первый по порядку пользователя»;
		# нужна ветке manual: первый = выбран вручную, штраф не действует
		_e_mm=$(base_metric "${_e_f##*/}")
		if [ -z "$_e_min" ] || [ "$_e_mm" -lt "$_e_min" ]; then _e_min="$_e_mm"; fi
	done
	for _e_f in "$HDIR"/*; do
		[ -f "$_e_f" ] || continue; case "$_e_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata) continue ;; esac
		_e_if="${_e_f##*/}"
		read -r _e_st _ _ _ _ < "$_e_f" || continue
		_e_dev=$(iface_dev "$_e_if"); [ -n "$_e_dev" ] || _e_dev=$(iface_dev "${_e_if}_4")
		[ -n "$_e_dev" ] || continue
		_e_base=$(base_metric "$_e_if")
		if [ "$_e_st" = down ] && [ -n "$_e_anyup" ] && [ "$H_FO" = "1" ]; then
			# ШТРАФУЕМ только когда есть живая альтернатива: если легли ВСЕ,
			# лучший исход - оставить порядок пользователя как есть
			_e_want=$((_e_base + PEN))
			# «УЖЕ ОШТРАФОВАН?» - СРАВНИВАЕМ ПОЛЕ, А НЕ ХВОСТ СТРОКИ.
			#
			# Здесь стоял grep по "metric N$", но `ip route show` печатает строку
			# С ПРОБЕЛОМ НА КОНЦЕ, и якорь конца строки не срабатывал НИКОГДА.
			# Трафик уводился правильно, а вот событие «без интернета - увожу
			# трафик» писалось на КАЖДОМ круге: в журнале одна и та же строка
			# каждые 30 c, и под панелью приоритета она же мигала как свежая
			# (живой стенд 07.08.2026, Wi-Fi-аплинк wwan). Разбираем поле metric
			# у маршрута этого устройства и сравниваем числа.
			_e_ta=$(_rt4_args "$_e_if")
			_e_cur=$(ip -4 route show default $_e_ta 2>/dev/null | awk -v d="$_e_dev" '
				$0 ~ (" dev " d " ") || $0 ~ (" dev " d "$") {
					m = 0
					for (i = 1; i <= NF; i++) if ($i == "metric") m = $(i + 1)
					print m; exit
				}')
			[ -n "$_e_cur" ] || _e_cur=0
			if [ "$_e_cur" != "$_e_want" ]; then
				_ev "$_e_if has no internet - steering traffic away (metric $_e_base -> $_e_want)"
			fi
			_e_dead="$_e_dead $_e_if"
			_e_target=$_e_want
		elif [ "$_e_st" = up ] && [ "$H_FO" = "1" ] && [ "$_e_cnt" -gt 1 ] \
		     && { [ -f "$_e_f.demoted" ] || { is_manual "$_e_if" && [ "$_e_base" -gt "$_e_min" ]; }; }; then
			# ожил, но по настройке остаётся В КОНЦЕ: держим штрафную метрику,
			# пока пользователь сам не вернёт (netpri set/order снимают метку).
			# С ЕДИНСТВЕННЫМ линком понижать некуда - метка не действует (иначе
			# его default навсегда висел бы со штрафной метрикой без смысла).
			# Линк «только вручную» держится здесь же ПОСТОЯННО, а не после
			# падения: трафик он получает лишь когда пользователь сам сделал
			# его первым (тогда его метрика минимальна и штраф не ставится).
			_e_target=$((_e_base + PEN))
		else
			# живой (или штрафовать нельзя/выключено) - вернуть родную метрику
			# ( |$): `ip route show` печатает пробел на конце строки, голый
			# якорь $ тут не срабатывал никогда (см. разбор выше у _e_cur).
			if ip -4 route show default $(_rt4_args "$_e_if") 2>/dev/null | grep -E " dev $_e_dev( |$)" | grep -qE "metric $((_e_base + PEN))( |$)"; then
				_ev "$_e_if - restoring priority (metric $_e_base)"
			fi
			_e_target=$_e_base
		fi
		# Маршрут мог ПРОПАСТЬ совсем (сорвавшееся добавление у соседа по
		# метрике, чужая правка таблицы) - двигать тогда нечего, сперва вернём.
		_ensure_defaults "$_e_dev" "$_e_target" "$_e_if"
		_move_defaults "$_e_dev" "$_e_target" "$_e_if"
	done
	# DNS ходит за трафиком: серверы оштрафованных линков убираем из общего
	# списка (см. _dns_demote выше). Только когда есть куда переключаться -
	# при общей аварии список не трогаем.
	[ -n "$_e_anyup" ] && _dns_demote "$_e_dead"
}

# ===== ЭТАП 3: ЛЕСТНИЦА ЛЕЧЕНИЯ МОДЕМА =====
#
# Отдельная ось от переключения трафика: увести трафик - секунды и обратимо,
# лечить модем - минуты и вмешательство в железо. Пользователь на модем задаёт
# ПОТОЛОК (uci 5gmodem.<sec>.heal): ifup - только переподключить интерфейс;
# reboot - плюс перезагрузка модуля (AT+CFUN=1,1); power - плюс передёрнуть
# USB-порт по питанию. Система идёт по ступеням снизу вверх: не помогло за
# кулдаун - следующая ступень; выше потолка не лезет, верхнюю повторяет.
#
# Предохранители (все - выстраданные, см. память проекта):
#   - кулдаун между попытками: перезагрузка модуля - это десятки секунд
#     переэнумерации, дёргать чаще - самому создавать флап;
#   - лимит попыток: после HEAL_MAX лечение останавливается («лежит, ждёт
#     человека») - бесконечная лестница на мёртвой SIM жгла бы модем зря;
#   - модема нет на шине - НЕ лечим и попытку НЕ считаем: отсутствие часто
#     временное (переэнумерация после нашей же перезагрузки);
#   - ожил - лестница сбрасывается (см. judge), следующее падение с нуля.
#
# Состояние: /tmp/5gmodem_health/<iface>.heal = "step last_uptime attempts"

HEAL_COOLDOWN=$(conf heal_cooldown); case "$HEAL_COOLDOWN" in ''|*[!0-9]*) HEAL_COOLDOWN=300 ;; esac
HEAL_MAX=6

# Сколько модем должен провисеть в gone, прежде чем лестница сочтёт это отказом.
# Обычный дозвон укладывается в минуту, переэнумерация после нашей же
# перезагрузки модуля - в полторы; берём с запасом, чтобы не влезть в них.
GONE_HEAL_MIN=180

# Сколько уважать ЛЕЖАЧИЙ интерфейс с autostart=false, не записанным в конфиг.
# Ручная остановка из интерфейса столько не живёт, а незавершённый ifdown - живёт
# вечно, и без этого срока модем из него не выбирается (см. лечение ниже).
STUCK_DOWN_MIN=900

# Потолок по умолчанию (опция не задана) - reboot: переподключение и
# перезагрузка модуля обратимы и безопасны, а именно они закрывают главные
# самолечимые классы (SIM illegal, залипший дозвон). Питание USB-порта -
# по-прежнему только явным выбором. Явное «не лечить» - значение none
# (пустая опция теперь означает «по умолчанию», см. setheal).
heal_cap() { case "$1" in none) echo 0 ;; ifup) echo 1 ;; power) echo 3 ;; *) echo 2 ;; esac }

# SIM ТОЧНО ОТСУТСТВУЕТ? Модем без карты перезагружать бессмысленно - лестница
# сожгла бы все попытки впустую. Проверяем перед КАЖДОЙ попыткой (раз в
# кулдаун): вставили карту - лечение само продолжится. Ответ 0 только при
# УВЕРЕННОМ «карты нет»; молчание/занятый порт лечению не мешают.
sim_absent() {   # $1 - секция, $2 - usb-путь
	# HiLink: статус SIM отдаёт его API (SimStatus: 1 - карта на месте,
	# 255/0 - нет/не читается). AT и MM у него не спрашиваем вовсе.
	if [ "$(uci -q get "$CFG.$1.kind")" = "hilink" ]; then
		_sa_ss=$("$RES/hilink.sh" json "$2" 2>/dev/null \
			| jsonfilter -e '@.sim_status' 2>/dev/null)
		case "$_sa_ss" in 0|255) return 0 ;; esac
		return 1
	fi
	# MM-модем: причина отказа в паспорте модема, канал MM всегда доступен
	_sa_idx=$("$RES/modemswitch.sh" mmindex "$2" 2>/dev/null)
	if [ -n "$_sa_idx" ] && command -v mmcli >/dev/null 2>&1; then
		mmcli -m "$_sa_idx" -K 2>/dev/null \
			| grep -q "state-failed-reason *: *sim-missing" && return 0
		return 1
	fi
	# AT-модем: короткий CPIN через общую очередь к порту
	_sa_at=$(uci -q get "$CFG.$1.at_port")
	[ -n "$_sa_at" ] && [ -e "$_sa_at" ] || return 1
	_sa_o=$(at_query "$_sa_at" "AT+CPIN?" 3 2>/dev/null)
	case "$_sa_o" in
		*"not inserted"*|*"CME ERROR: 10"*|*"SIM failure"*|*"SIM_ABSENT"*) return 0 ;;
	esac
	return 1
}

heal() {
	# Модемная лестница (healing) и Wi-Fi (heal_wifi) - НЕЗАВИСИМЫЕ галки:
	# ниже каждая ветка проверяет свою; сюда не заходим, только если выключены обе.
	[ "$H_HEAL" = "1" ] || [ "$H_HEALWIFI" = "1" ] || return 0
	# ОБЩАЯ ПРИЧИНА - НЕ ЛЕЧИМ ЖЕЛЕЗО. Если наблюдаемых линков несколько и
	# упали ВСЕ разом, дело почти наверняка не в модемах: умерли адреса
	# проверки, лёг вышестоящий роутер, оператор региона. Перезагружать каждый
	# модем в такой ситуации - вредительство. Единственный линк лечим всегда:
	# сравнивать не с чем, а самовосстановление - главная ценность для
	# однмодемного роутера.
	_h_cnt=0; _h_anyup=""
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata) continue ;; esac
		read -r _h_st _ _ _ _ < "$_h_f" || continue
		_h_cnt=$((_h_cnt + 1))
		[ "$_h_st" = up ] && _h_anyup=1
	done
	# ПРОБЫ БЛОКИРОВАНЫ - НЕ ЛЕЧИМ ДАЖЕ ЕДИНСТВЕННЫЙ ЛИНК. Гвард «легли все»
	# ниже единственный линк лечит всегда - и при killswitch VPN (прямой выход
	# запрещён фаерволом) одномодемный роутер гонял бы лестницу до CFUN=1,1 по
	# здоровому модему с живым интернетом. Проверка через прокси дорогая
	# (curl), поэтому только на редком пути «ни одного живого вердикта».
	if [ -z "$_h_anyup" ] && [ "$_h_cnt" -ge 1 ] && [ "$H_PG" = "1" ] && probe_proxy; then
		_pg_last=$(cat /tmp/5gmodem_health.fwguard 2>/dev/null)
		case "$_pg_last" in ''|*[!0-9]*) _pg_last=0 ;; esac
		_pg_now=$(uptime_s)
		if [ $((_pg_now - _pg_last)) -ge 1800 ] || [ "$_pg_now" -lt "$_pg_last" ]; then
			uptime_s > /tmp/5gmodem_health.fwguard
			_ev "all links fail direct probes, but the internet works via the local proxy - probes look firewall-blocked, healing suspended"
		fi
		return 0
	fi
	[ "$_h_cnt" -gt 1 ] && [ -z "$_h_anyup" ] && return 0
	for _h_f in "$HDIR"/*; do
		[ -f "$_h_f" ] || continue; case "$_h_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata) continue ;; esac
		_h_if="${_h_f##*/}"
		read -r _h_st _ _ _ _h_since < "$_h_f" || continue
		# WI-FI-АПЛИНК - своя короткая лестница, и она берёт в работу ещё и
		# состояние gone: живой класс отказа - netifd расцепил интерфейс с
		# радио (NO_DEVICE при ассоциированной станции), и лечится он только
		# пересборкой (network reload), а не ifup. Модемные лестницы gone
		# по-прежнему пропускают (их железо реально отсутствует на шине).
		if [ "$H_HEALWIFI" = "1" ] && is_wifi_iface "$_h_if"; then
			case "$_h_st" in down|gone) ;; *) continue ;; esac
			# РУЧНОЙ ifdown НЕ ЛЕЧИМ: административно выключенный интерфейс
			# netifd помечает autostart=false - это выбор человека, а не отказ.
			# Поймано вживую: тестовый ifdown wwan через кулдаун получил
			# network reload от лестницы. «Расцепление» (наш целевой случай)
			# оставляет autostart=true.
			_h_auto=$(printf '%s' "$_HDUMP" | jsonfilter \
				-e "@.interface[@.interface=\"$_h_if\"].autostart" 2>/dev/null)
			[ "$_h_auto" = "false" ] && continue
			# СТАНЦИЯ С IP, НО БЕЗ ИНТЕРНЕТА - НЕ ЛЕЧИМ: связь с точкой доступа
			# исправна, интернета нет У НЕЁ (вышестоящий роутер) - переподключение
			# Wi-Fi тут бессмысленно, трафик уводит failover. Лечим только
			# технические отказы самого линка: down БЕЗ адреса (ассоциация/DHCP
			# сломались) и gone (netifd расцепил интерфейс с радио).
			# АДРЕС НИЧЕГО НЕ ДОКАЗЫВАЕТ БЕЗ ЖИВОЙ АССОЦИАЦИИ. После потери
			# маяков (CTRL-EVENT-BEACON-LOSS) netifd держит интерфейс up со
			# СТАРОЙ DHCP-арендой: адрес на месте, станция давно отвязана.
			# Живой случай 03.08.2026: STA стенда отвязалась в 21:02, сторож
			# 25 минут видел красный линк и «не лечил» из-за IP - поднял только
			# ручной передёрг. Пропускаем лечение лишь когда ассоциация ЖИВА
			# (iw link Connected) - тогда это действительно беда вышестоящего.
			if [ "$_h_st" = down ]; then
				_h_wip=$(printf '%s' "$_HDUMP" | jsonfilter \
					-e "@.interface[@.interface=\"$_h_if\"]['ipv4-address'][0].address" 2>/dev/null)
				if [ -n "$_h_wip" ]; then
					_h_wdev=$(printf '%s' "$_HDUMP" | jsonfilter \
						-e "@.interface[@.interface=\"$_h_if\"].device" 2>/dev/null | head -1)
					if [ -n "$_h_wdev" ] && iw dev "$_h_wdev" link 2>/dev/null | grep -q "^Connected"; then
						continue
					fi
				fi
			fi
			_h_step=0; _h_last=0; _h_n=0
			[ -f "$HDIR/$_h_if.heal" ] && read -r _h_step _h_last _h_n < "$HDIR/$_h_if.heal"
			[ "$_h_n" -lt "$HEAL_MAX" ] || continue
			_h_now=$(uptime_s)
			[ $((_h_now - _h_last)) -ge "$HEAL_COOLDOWN" ] || continue
			_h_n=$((_h_n + 1))
			if [ "$_h_step" -lt 1 ] && [ "$_h_st" = down ]; then
				# радио на месте, адреса нет - сначала мягко
				_h_next=1
				_ev "healing $_h_if: reconnecting Wi-Fi ($_h_n/$HEAL_MAX)"
				( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
			elif [ "$_h_step" -lt 2 ]; then
				# ПЕРЕПОДКЛЮЧАЕМ ТОЛЬКО СТАНЦИЮ - ТОЧКА ДОСТУПА РАБОТАЕТ ДАЛЬШЕ.
				#
				# Станция и AP роутера живут на ОДНОМ радио, поэтому пересборка
				# радио (не говоря о `network reload`) гасит и точку доступа: у
				# hostapd «Remove interface», AP-DISABLED, все клиенты роутера
				# отваливаются. Ради поднятия аплинка это несоразмерно.
				#
				# wpa_supplicant умеет ровно нужное: REASSOCIATE по своему
				# управляющему каналу (ubus-объект wpa_supplicant.<станция>;
				# отдельный wpa_cli на OpenWrt может быть не установлен - на
				# стенде его нет). Замерено: цикл deauth -> auth -> assoc ->
				# CONNECTED занял 1.5 c, hostapd не перезапускался вовсе, у AP
				# только субсекундный bounce порта моста, клиенты остались.
				# Запасной путь - `iw dev <станция> disconnect`: wpa_supplicant
				# сам восстановит соединение по своей конфигурации.
				_h_next=2
				_h_sta=$(printf '%s' "$_HDUMP" | jsonfilter \
					-e "@.interface[@.interface=\"$_h_if\"].device" 2>/dev/null | head -1)
				if [ -n "$_h_sta" ]; then
					_ev "healing $_h_if: reconnecting station $_h_sta ($_h_n/$HEAL_MAX)"
					( ubus call "wpa_supplicant.$_h_sta" control '{"command":"REASSOCIATE"}' \
					    || iw dev "$_h_sta" disconnect
					  sleep 6; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: station unknown, reconnecting the interface ($_h_n/$HEAL_MAX)"
					( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
			elif [ "$_h_step" -lt 3 ] || [ -n "$_h_anyup" ]; then
				# ПЕРЕСБОРКА СВОЕГО РАДИО - здесь точка доступа на нём ПОГАСНЕТ на
				# несколько секунд, поэтому ступень идёт только после того, как
				# мягкое переподключение станции не помогло. Лечит другой класс
				# отказа: netifd расцепил интерфейс с радио (NO_DEVICE при
				# ассоциированной станции) - REASSOCIATE такое не берёт.
				#
				# `wifi up <radio>` не годится: /sbin/wifi внутри сам зовёт
				# `ubus call network reload` (см. wifi_updown), то есть тянет за
				# собой ВСЕ интерфейсы. Ходим напрямую в network.wireless.
				_h_next=3
				_h_radio=$(wifi_radio_for "$_h_if")
				if [ -n "$_h_radio" ]; then
					_ev "healing $_h_if: rebuilding radio $_h_radio ($_h_n/$HEAL_MAX)"
					( ubus call network.wireless down "{\"device\":\"$_h_radio\"}"
					  sleep 2
					  ubus call network.wireless up "{\"device\":\"$_h_radio\"}"
					  sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: radio unknown, reconnecting the interface ($_h_n/$HEAL_MAX)"
					( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
			else
				# ПОСЛЕДНЯЯ СТУПЕНЬ - ГЛОБАЛЬНАЯ ПЕРЕСБОРКА, и только когда терять
				# нечего: сюда попадаем, если пересборка радио не помогла И ни один
				# другой аплинк не жив. Пока жив хоть один линк, ронять ради Wi-Fi
				# всю сеть нельзя - на нём сейчас работает пользователь. Именно эта
				# строка (в прежней редакции - вторая ступень) роняла работающий
				# модем при падении Wi-Fi: «modem stopping network» в журнале.
				_h_next=4
				_ev "healing $_h_if: rebuilding the whole network, network reload ($_h_n/$HEAL_MAX)"
				( ubus call network reload; sleep 2; wifi up >/dev/null 2>&1; sleep 3; ifup "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
			fi
			printf '%s %s %s\n' "$_h_next" "$_h_now" "$_h_n" > "$HDIR/$_h_if.heal"
			[ "$_h_n" -ge "$HEAL_MAX" ] && _ev "healing $_h_if: attempts exhausted - manual intervention needed"
			continue
		fi
		# GONE ПРИ ЖИВОМ ЖЕЛЕЗЕ - ЭТО ОТКАЗ, А НЕ ОТСУТСТВИЕ МОДЕМА.
		#
		# Раньше модемные лестницы брали только down: считалось, что gone бывает
		# лишь когда модуля нет на шине. Это неверно для класса отказов, где
		# netifd ЗАСТРЯЛ в дозвоне: l3-устройства ещё нет, поэтому состояние
		# gone, а лечить надо срочно. Живой случай 05.08.2026, Quectel EP06 в
		# qmi: uqmi отдал «illegal» на состояние SIM, и протокол ушёл в вечный
		# цикл `--uim-power-off/--uim-power-on` каждые 8 секунд (в qmi.sh он
		# ограничен таймаутом, а тот по умолчанию 0 - то есть бесконечен). Этому
		# модему после сброса нужно около двух минут на инициализацию карты, а
		# ему режут ей питание раз в восемь секунд - SIM не успевает подняться
		# НИКОГДА, петля кормит сама себя. Оба сторожа при этом стояли в
		# стороне: sessionwatch не мешает netifd в pending, health списывал в
		# gone. Связь не возвращалась до вмешательства руками.
		#
		# Настоящее отсутствие модема отсекает проверка usb-пути ниже, а выдержка
		# GONE_HEAL_MIN - обычный дозвон и нашу же переэнумерацию.
		case "$_h_st" in
			down) ;;
			gone)
				case "$_h_since" in ''|*[!0-9]*) continue ;; esac
				[ $(( $(uptime_s) - _h_since )) -ge "$GONE_HEAL_MIN" ] || continue ;;
			*) continue ;;
		esac
		[ "$H_HEAL" = "1" ] || continue
		# ВЫКЛЮЧЕННЫЙ ИНТЕРФЕЙС НЕ ЛЕЧИМ - НО РАЗЛИЧАЕМ ВОЛЮ И АВАРИЮ.
		#
		# autostart=false бывает двух совершенно разных природ:
		#   - воля человека, записанная в конфиг (auto='0' / disabled='1') -
		#     её уважаем всегда, иначе выключенный модем не просто поднимут, а
		#     дойдут до перезагрузки модуля;
		#   - следствие ЧУЖОГО (и нашего же) незавершённого ifdown - состояние
		#     временное, в конфиге его нет, и после перезагрузки роутера
		#     интерфейс поднялся бы сам.
		#
		# Второе нельзя уважать вечно: первая ступень лестницы сама делает
		# `ifdown` + `iface_up`, и если подъём не довёлся (модем в этот момент
		# переэнумерировался), интерфейс остаётся опущенным - а дальше и
		# лестница, и sessionwatch обходят его стороной как «выключенный
		# намеренно». Модем висит вечно при исправном железе и готовой SIM:
		# ровно это и случилось на стенде 05.08.2026 через час после включения
		# лечения. Поэтому runtime-ifdown уважаем ограниченное время, а дальше
		# считаем аварией и поднимаем.
		_h_auto=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"].autostart" 2>/dev/null)
		if [ "$_h_auto" = "false" ]; then
			[ "$(uci -q get "network.$_h_if.auto")" = "0" ] && continue
			[ "$(uci -q get "network.$_h_if.disabled")" = "1" ] && continue
			# ОШИБКА ПРОТОКОЛА - ЭТО НЕ ВОЛЯ ЧЕЛОВЕКА, ЛЕЧИМ СРАЗУ.
			#
			# Сдавшись, протокол зовёт proto_block_restart, и netifd СНИМАЕТ
			# autostart - внешне неотличимо от ручной остановки. Отличает их
			# список errors: у ручного ifdown он пуст, а здесь лежит причина
			# отказа (живой случай 05.08.2026, Quectel EP06: `{"subsystem":
			# "qmi","code":"SIM_ILLEGAL_STATE"}` после самосброса модуля).
			# Ждать выдержку в этом случае незачем - интерфейс уже мёртв, и
			# сам netifd к нему больше не вернётся.
			if [ -z "$(printf '%s' "$_HDUMP" | jsonfilter \
				-e "@.interface[@.interface=\"$_h_if\"].errors[0].code" 2>/dev/null)" ]; then
				case "$_h_since" in ''|*[!0-9]*) continue ;; esac
				[ $(( $(uptime_s) - _h_since )) -ge "$STUCK_DOWN_MIN" ] || continue
			fi
		fi
		_h_sec=$(sec_for_iface_h "$_h_if") || continue
		_h_cap=$(heal_cap "$(uci -q get "$CFG.$_h_sec.heal")")
		[ "$_h_cap" -ge 1 ] || continue
		# SIM В «illegal» ЛЕЧИТ ТОЛЬКО ПЕРЕЗАГРУЗКА МОДУЛЯ - ПОДНИМАЕМ ПОЛ ДО reboot.
		#
		# После ребута роутера QMI-модем (Telit LM960, Quectel EP06) нередко встаёт
		# с картой в состоянии illegal: netifd упирается в SIM_ILLEGAL_STATE, зовёт
		# proto_block_restart, интерфейс ложится с autostart=false. ifup здесь
		# бесполезен по определению - он лишь перезапускает тот же отказ (а на qmi.sh
		# ещё и вечную петлю power-cycle SIM раз в 8 c). Снимает illegal единственное
		# - AT+CFUN=1,1 (проверено на стенде 12.08.2026: illegal->ready за один
		# сброс, следом ifup поднял IP). Поэтому при этой ошибке берём пол уровня
		# reboot, даже если пользователь оставил heal=ifup: sessionwatch как раз
		# откладывает подъём «в ожидании лестницы» (сам дозвон кормил бы петлю), и
		# без этого пола лестнице нечем ответить - оба сторожа ждут друг друга.
		_h_illegal=""
		case "$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"].errors[0].code" 2>/dev/null)" in
			SIM_ILLEGAL_STATE) _h_illegal=1; [ "$_h_cap" -lt 2 ] && _h_cap=2 ;;
		esac
		_h_path=$(uci -q get "$CFG.$_h_sec.path")
		[ -n "$_h_path" ] || continue
		# МОДЕМА НЕТ НА ШИНЕ. Обычно это временная переэнумерация (в т.ч. наша
		# же перезагрузка модуля) - не лечим и попытку не считаем. ИСКЛЮЧЕНИЕ:
		# потолок power и интерфейс давно в gone (выдержка GONE_HEAL_MIN уже
		# пройдена веткой выше). Это класс «палка не села на шину с холодного
		# старта»: Android-палка грузится дольше роутера и при одновременном
		# включении может вообще не энумерироваться (живой случай Cudy TR3000,
		# 18.08.2026 - на шине пусто, dmesg без единой энумерации). Лечится
		# ТОЛЬКО передёргиванием питания порта, а управление портом живёт на
		# ХАБЕ и работает без устройства (_usb_port_dir строит путь из строки).
		_h_absent=""
		if ! [ -e "/sys/bus/usb/devices/$_h_path" ]; then
			[ "$_h_cap" -ge 3 ] && [ "$_h_st" = gone ] || continue
			_h_absent=1
		fi
		_h_step=0; _h_last=0; _h_n=0
		[ -f "$HDIR/$_h_if.heal" ] && read -r _h_step _h_last _h_n < "$HDIR/$_h_if.heal"
		[ "$_h_n" -lt "$HEAL_MAX" ] || continue
		_h_now=$(uptime_s)
		[ $((_h_now - _h_last)) -ge "$HEAL_COOLDOWN" ] || continue
		if [ -z "$_h_absent" ] && sim_absent "$_h_sec" "$_h_path"; then
			# карты нет - не лечим и попытку НЕ считаем; событие один раз на
			# эпизод (маркер стирается при выздоровлении вместе с лестницей)
			if [ ! -f "$HDIR/$_h_if.nosim" ]; then
				: > "$HDIR/$_h_if.nosim"
				_ev "healing $_h_if: no SIM inserted - healing postponed"
			fi
			continue
		fi
		rm -f "$HDIR/$_h_if.nosim"
		# ТРАФИК КОНЧИЛСЯ - ЭТО НЕ ПОЛОМКА МОДЕМА, И ЛЕЧИТЬ ТУТ НЕЧЕГО.
		#
		# Когда у интерфейса ЕСТЬ адрес, сессия установлена: SIM жива, модем
		# зарегистрирован, канал поднят. Значит трафик режет ОПЕРАТОР - исчерпан
		# пакет, нулевой баланс, блокировка. Ни перезагрузка модуля, ни передёрг
		# USB, ни ifup такое не лечат: после переподключения модем упирается в
		# тот же лимит. Замечание владельца 05.08.2026: сперва лестница трижды
		# перезагрузила исправный EP06, а когда осталась только первая ступень -
		# продолжила жечь попытки, показывая на карточке «Переподключение (3/6)».
		#
		# Поэтому останавливаемся совсем, как при отсутствующей SIM: попытку НЕ
		# считаем, лестницу сбрасываем (иначе карточка держит счётчик прошлого
		# эпизода), событие пишем один раз. Пропал адрес - маркер снимается, и
		# лестница едет с нуля как обычно. Залипшую сессию, где адрес тоже на
		# месте, продолжает лечить sessionwatch - он сверяет адрес с модемом.
		_h_lip=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"$_h_if\"]['ipv4-address'][0].address" 2>/dev/null)
		[ -n "$_h_lip" ] || _h_lip=$(printf '%s' "$_HDUMP" | jsonfilter \
			-e "@.interface[@.interface=\"${_h_if}_4\"]['ipv4-address'][0].address" 2>/dev/null)
		if [ -n "$_h_lip" ]; then
			# ИСКЛЮЧЕНИЕ: МОДЕМ СВАЛИЛСЯ В 2G. «Адрес есть, трафика нет» на
			# GSM/EDGE - это не лимит оператора, а радио-отказ: LTE ушёл, модем
			# перескочил на 2G, где данных фактически нет, и прежний вердикт
			# останавливал лечение навсегда (живой случай 20.08.2026, SIM7100E
			# ночью залип на EGSM 900 с «B-86» в карточке). Перезагрузка модуля
			# возвращает LTE - лестница должна работать. Режим берём из свежего
			# снимка метрик; протухший снимок решения не меняет.
			_h_2g=""
			_h_mk=$(echo "$_h_path" | tr -c 'A-Za-z0-9' '_')
			_h_ms="/tmp/5gmodem_metrics_${_h_mk}.json"
			if [ -s "$_h_ms" ]; then
				_h_mst=$(cat "/tmp/5gmodem_metrics_${_h_mk}.stamp" 2>/dev/null)
				case "$_h_mst" in
					''|*[!0-9]*) ;;
					*) if [ $(( $(uptime_s) - _h_mst )) -le 300 ]; then
						case "$(jsonfilter -i "$_h_ms" -e '@.mode' 2>/dev/null)" in
							*GSM*|*EDGE*|*GPRS*|2G*) _h_2g=1 ;;
						esac
					   fi ;;
				esac
			fi
			if [ -n "$_h_2g" ]; then
				if [ ! -f "$HDIR/$_h_if.on2g" ]; then
					: > "$HDIR/$_h_if.on2g"
					_ev "$_h_if: modem dropped to 2G and data is dead - treating as a failure, healing continues"
				fi
			else
				rm -f "$HDIR/$_h_if.on2g"
				if [ ! -f "$HDIR/$_h_if.nodata" ]; then
					: > "$HDIR/$_h_if.nodata"
					rm -f "$HDIR/$_h_if.heal"
					_ev "$_h_if: has an address ($_h_lip) but no traffic - looks like a carrier restriction, healing stopped"
				fi
				continue
			fi
		fi
		rm -f "$HDIR/$_h_if.nodata"
		# МОДЕМ ПОД ModemManager ПРОСТО ВЫКЛЮЧЕН - ВКЛЮЧАЕМ, А НЕ ЛЕЧИМ.
		#
		# MM держит модем в состоянии disabled после части событий (живой случай
		# 06.08.2026: EP06 после смены USB-композиции остался disabled/registered
		# и поднялся только руками через `mmcli --enable`). Для netifd такой
		# модем «есть, но соединения нет», и лестница честно шла ступенями:
		# ifup впустую (включать нечего), затем AT+CFUN=1,1 с переэнумерацией
		# на полминуты, затем передёрг USB по питанию - тремя тяжёлыми шагами
		# ради одной команды.
		#
		# Поэтому ПЕРЕД лестницей: если модем виден MM и выключен - включаем и
		# ждём подъёма своим чередом (netifd сам поднимет интерфейс, когда
		# появится модем; форсировать ifup здесь не надо - MM объявляет модем
		# доступным не мгновенно).
		#
		# Попытку НЕ считаем и лестницу НЕ двигаем: это не лечение аварии, а
		# доведение до состояния, с которого лечение вообще имеет смысл. Если
		# `--enable` не помог, следующий круг придёт сюда снова и увидит модем
		# уже не disabled - тогда поедет обычная лестница.
		# Событие пишем один раз на эпизод (маркер снимается при выздоровлении).
		if command -v mmcli >/dev/null 2>&1; then
			_h_mmi=$("$RES/modemswitch.sh" mmindex "$_h_path" 2>/dev/null)
			if [ -n "$_h_mmi" ]; then
				_h_mms=$(mmcli -m "$_h_mmi" -K 2>/dev/null \
					| sed -n 's/^modem\.generic\.state *: *//p' | head -1)
				case "$_h_mms" in
					disabled|locked)
						if [ ! -f "$HDIR/$_h_if.mmoff" ]; then
							: > "$HDIR/$_h_if.mmoff"
							_ev "healing $_h_if: modem disabled in ModemManager ($_h_mms) - enabling"
						fi
						# ОДИН enable ЗА РАЗ И С ТАЙМАУТОМ. Команда уходит в фон,
						# и на заклинившем MM она не завершается - без гарда каждый
						# круг сторожа плодил бы ещё один висящий mmcli (утечка
						# процессов, по одному в ~30 c). Пока прошлый жив - не
						# запускаем новый; сам он ограничен 30 секундами.
						if ! pgrep -f "mmcli -m $_h_mmi --enable" >/dev/null 2>&1; then
							( mmcli -m "$_h_mmi" --enable >/dev/null 2>&1 & _h_mep=$!
							  ( sleep 30; kill "$_h_mep" 2>/dev/null ) >/dev/null 2>&1 & _h_mew=$!
							  wait "$_h_mep" 2>/dev/null
							  kill "$_h_mew" 2>/dev/null ) >/dev/null 2>&1 </dev/null 9>&- &
						fi
						continue ;;
				esac
			fi
		fi
		rm -f "$HDIR/$_h_if.mmoff"
		_h_next=$((_h_step + 1))
		[ "$_h_next" -gt "$_h_cap" ] && _h_next="$_h_cap"
		# illegal лечит только перезагрузка - ступень ifup жгла бы попытку впустую,
		# идём сразу на неё (ниже сработает та же проверка at_port, что и обычно).
		[ -n "$_h_illegal" ] && [ "$_h_next" -lt 2 ] && _h_next=2
		# Устройства нет на шине: ifup поднимать нечего, AT-порта нет - имеет
		# смысл только питание порта, идём сразу на него.
		[ -n "$_h_absent" ] && _h_next=3
		# Ступень 2 у HiLink - ЕГО API (device/control), не AT: AT+CFUN=1,1
		# выбил бы Huawei из debug-композиции (проверено на диапазонах - см.
		# bands.sh), а API перезагружает модуль в любой композиции, лишь бы
		# его адрес отвечал. Без AT-порта у прочих: с разрешением на power
		# идём сразу на USB, без него - остаёмся на переподключении.
		_h_hilink=""
		[ "$(uci -q get "$CFG.$_h_sec.kind")" = "hilink" ] && _h_hilink=1
		# AT-порт нужен и ступени 2 (CFUN), и гварду поиска ниже - берём один
		# раз; переменная цикла, без сброса тащила бы порт ПРОШЛОГО модема.
		_h_at=$(uci -q get "$CFG.$_h_sec.at_port")
		if [ "$_h_next" = 2 ] && [ -z "$_h_hilink" ]; then
			if [ -z "$_h_at" ] || [ ! -e "$_h_at" ]; then
				if [ "$_h_cap" -ge 3 ]; then _h_next=3; else _h_next=1; fi
			fi
		fi
		# МОДЕМ В АКТИВНОМ ПОИСКЕ СЕТИ - НЕ МЕШАЕМ. Перезагрузка модуля посреди
		# сканирования отбрасывает регистрацию в начало: на слабом сигнале скан
		# занимает дольше кулдауна, и лестница сама не давала модему
		# зарегистрироваться (живой случай 20.08.2026: SIM7100E после смены
		# режима сети, попытки 3/6 и 4/6 рвали каждый скан). CREG/CEREG stat=2 =
		# «ищу сеть»: попытку НЕ считаем и ничего не делаем этот круг. Потолок -
		# 12 минут непрерывного поиска (маркер .srch), дальше лечим как обычно:
		# вечный поиск - сам по себе отказ. Проверка только перед ТЯЖЁЛЫМИ
		# ступенями (reboot/power) и только при живом AT-порте.
		if [ "$_h_next" -ge 2 ] && [ -z "$_h_hilink" ] && [ -n "$_h_at" ] && [ -e "$_h_at" ]; then
			_h_reg=$(at_query "$_h_at" "AT+CEREG?" 5 3 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CEREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
			[ -n "$_h_reg" ] || _h_reg=$(at_query "$_h_at" "AT+CREG?" 5 3 2>/dev/null | tr -d '\r' \
				| sed -n 's/.*+CREG: *[0-9]*, *\([0-9]*\).*/\1/p' | head -1)
			if [ "$_h_reg" = "2" ]; then
				_h_ss=$(cat "$HDIR/$_h_if.srch" 2>/dev/null)
				case "$_h_ss" in ''|*[!0-9]*) _h_ss=$(uptime_s); printf '%s' "$_h_ss" > "$HDIR/$_h_if.srch" ;; esac
				if [ $(( $(uptime_s) - _h_ss )) -lt 720 ]; then
					_ev "healing $_h_if: modem is searching for a network - postponing the attempt"
					continue
				fi
			else
				rm -f "$HDIR/$_h_if.srch"
			fi
		fi
		_h_n=$((_h_n + 1))
		case "$_h_next" in
			1)
				_ev "healing $_h_if: reconnecting the interface ($_h_n/$HEAL_MAX)"
				( ifdown "$_h_if"; sleep 3; iface_up "$_h_if" ) >/dev/null 2>&1 </dev/null 9>&- &
				;;
			2)
				if [ -n "$_h_hilink" ]; then
					_ev "healing $_h_if: rebooting the module via API ($_h_n/$HEAL_MAX)"
					( "$RES/hilink.sh" reboot "$_h_path" ) >/dev/null 2>&1 </dev/null 9>&- &
				else
					_ev "healing $_h_if: rebooting the module, AT+CFUN=1,1 ($_h_n/$HEAL_MAX)"
					( "$RES/reboot_modem.sh" hard "$_h_at" ) >/dev/null 2>&1 </dev/null 9>&- &
				fi
				;;
			3)
				_ev "healing $_h_if: power-cycling the USB port ($_h_n/$HEAL_MAX)"
				( "$RES/reboot_modem.sh" usbpower "$_h_path" ) >/dev/null 2>&1 </dev/null 9>&- &
				;;
		esac
		printf '%s %s %s\n' "$_h_next" "$_h_now" "$_h_n" > "$HDIR/$_h_if.heal"
		[ "$_h_n" -ge "$HEAL_MAX" ] && _ev "healing $_h_if: attempts exhausted - manual intervention needed"
	done
}

# ПОЛНАЯ УБОРКА ЗА СОБОЙ при выключении функции (галкой слежения или виджетом).
# Раньше выключение просто останавливало тики, а УЖЕ наложенные штрафные метрики
# (+1000) и файлы состояния оставались висеть - трафик мог навсегда остаться
# «уведённым» с линка, который давно ожил. Теперь: каждому известному линку
# возвращается родная метрика из uci (ровно то, что netifd сделал бы сам при
# следующем событии), состояние удаляется целиком. uci-метрики (10/20/30) НЕ
# трогаем - это обычный конфиг netifd, пассивный failover по метрикам остаётся.
# Начатые фоновые шаги лечения атомарны (ifdown; sleep; ifup в одной
# подоболочке) - они доработают сами, новых не будет. Вызывать ПОД замком.
_teardown() {
	# iface_dev читает из снимка _HDUMP - в обычном круге его наполняет round(),
	# но сюда приходят МИМО round (пролог tick/once). Без снимка каждый линк
	# давал бы пустое устройство, и штрафные метрики оставались бы висеть.
	_HDUMP=$(ubus call network.interface dump 2>/dev/null)
	for _td_f in "$HDIR"/*; do
		[ -f "$_td_f" ] || continue
		case "$_td_f" in */.t|*.heal|*.demoted|*.nosim|*.nodata|*.last_event) continue ;; esac
		_td_if="${_td_f##*/}"
		_td_dev=$(iface_dev "$_td_if"); [ -n "$_td_dev" ] || _td_dev=$(iface_dev "${_td_if}_4")
		[ -n "$_td_dev" ] || continue
		_move_defaults "$_td_dev" "$(base_metric "$_td_if")" "$_td_if"
	done
	rm -rf "$HDIR"
	logger -t 5gmodem "watchdog disabled: penalties lifted, metrics restored from uci, state cleared"
}

# Общий пролог tick/once: функция выключена, но состояние осталось - прибраться
# один раз (rm -rf HDIR делает последующие заходы мгновенными no-op).
_off_cleanup() {
	[ -d "$HDIR" ] || exit 0
	exec 9>"/tmp/5gmodem_health.lock"
	flock 9
	_teardown
	exit 0
}

case "$1" in
tick)
	[ "$H_EN" = "1" ] || _off_cleanup
	# rate-limit внутри: цикл sessionwatch ходит со своим шагом, а интервал
	# слежения - настройка пользователя; -2с допуска, чтобы не пропускать круг
	# из-за дрожания шага цикла
	mkdir -p "$HDIR"
	_t_last=$(cat "$HDIR/.t" 2>/dev/null); case "$_t_last" in ''|*[!0-9]*) _t_last=0 ;; esac
	_t_now=$(uptime_s)
	[ $((_t_now - _t_last)) -ge $((H_INT - 2)) ] || exit 0
	# ОДИН КРУГ ЗА РАЗ. Фоновый tick и once со страницы могут пересечься, и
	# тогда штрафы одного круга перетирают восстановление другого (поймано
	# вживую при обкатке). tick при занятом замке просто пропускает ход.
	exec 9>"/tmp/5gmodem_health.lock"
	flock -n 9 || exit 0
	round
	enforce
	heal
	;;
once)
	# страница зовёт once сразу после сохранения настроек модалки: если слежение
	# только что выключили - немедленно прибраться (штрафы снять), а не ждать тика
	[ "$H_EN" = "1" ] || _off_cleanup
	mkdir -p "$HDIR"
	# once ждёт замок (блокирующе): его зовут руками/со страницы - ответ нужен
	exec 9>"/tmp/5gmodem_health.lock"
	flock 9
	round
	enforce
	heal
	;;
event)
	# Внеочередной круг ПО СОБЫТИЮ ifup/ifdown аплинка (hotplug.d/iface).
	# Без него вердикт живёт только 30-секундными кругами цикла, и карточка
	# поднявшегося модема до минуты висела пунктирным слотом при уже живом IP.
	# Только для интерфейсов wan-зоны; лечение НЕ дёргаем: его кулдауны
	# сами разберутся на штатном круге.
	[ "$H_EN" = "1" ] || exit 0
	case " $(wan_nets) " in *" $2 "*) ;; *) exit 0 ;; esac
	mkdir -p "$HDIR"
	exec 9>"/tmp/5gmodem_health.lock"
	flock 9
	round
	enforce
	;;
getconf)
	# heal-карта: интерфейс -> потолок лечения, для селектов в модалке
	_gc_heal=""
	for _gc_s in $(uci show "$CFG" 2>/dev/null | sed -n "s/^5gmodem\.\([^.]*\)=modem\$/\1/p"); do
		_gc_n=$(uci -q get "$CFG.$_gc_s.network"); [ -n "$_gc_n" ] || continue
		[ -n "$(uci -q get "$CFG.$_gc_s.path")" ] || continue
		_gc_heal="$_gc_heal,\"$_gc_n\":\"$(uci -q get "$CFG.$_gc_s.heal")\""
	done
	printf '{"enabled":%s,"interval":%s,"targets":"%s","fail_n":%s,"ok_n":%s,"failover":%s,"failback":"%s","healing":%s,"heal_wifi":%s,"manual":"%s","proxy_guard":%s,"heal":{%s}}\n' \
		"${H_EN:-0}" "$H_INT" "$H_TGT" "$H_FAILN" "$H_OKN" "${H_FO:-0}" "$H_FB" "${H_HEAL:-0}" "${H_HEALWIFI:-0}" "$H_MAN" "$H_PG" "${_gc_heal#,}"
	;;
setheal)
	# setheal <iface> <''|none|ifup|reboot|power> - потолок лечения модема
	# ('' = сброс на умолчание reboot, none = явное «не лечить»)
	case "$3" in ''|none|ifup|reboot|power) ;; *) echo '{"error":"bad level"}'; exit 1 ;; esac
	_sh_sec=$(sec_for_iface_h "$2") || { echo '{"error":"no modem for iface"}'; exit 1; }
	if [ -n "$3" ]; then
		uci -q set "$CFG.$_sh_sec.heal=$3"
	else
		uci -q delete "$CFG.$_sh_sec.heal"
	fi
	uci -q commit "$CFG"
	echo '{"result":"ok"}'
	;;
setconf)
	# настройки из модалки страницы: setconf enabled=1 interval=30 ...
	# Ключи - строго из белого списка: строка приходит из браузера.
	shift
	uci -q get "$CFG.health" >/dev/null 2>&1 || uci -q set "$CFG.health=health"
	for _sc in "$@"; do
		_sc_k="${_sc%%=*}"; _sc_v="${_sc#*=}"
		case "$_sc_k" in
			enabled|interval|targets|fail_n|ok_n|failover|failback|healing|heal_wifi|heal_cooldown|manual|proxy_guard) uci -q set "$CFG.health.$_sc_k=$_sc_v" ;;
		esac
	done
	uci -q commit "$CFG"
	# выключили - следующий status сам скажет enabled:0, точки погаснут
	echo '{"result":"ok"}'
	;;
*)
	echo "usage: $0 tick|once|status|setconf k=v..." >&2
	exit 1
	;;
esac
