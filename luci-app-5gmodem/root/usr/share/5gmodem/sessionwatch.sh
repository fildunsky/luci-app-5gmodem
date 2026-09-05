#!/bin/sh
#
# СТОРОЖ СЕССИИ ДАННЫХ.
#
# ЗАЧЕМ. netifd поднимает интерфейс один раз и дальше за сессией НЕ следит: если
# сеть её разорвала или пересоздала с другим адресом, интерфейс остаётся «up» со
# старым IP, а трафик уже никуда не идёт. Живой случай: поездка Москва ->
# Владимирская область, смена макрорегиона - оператор выдал адрес из другой сети
# (10.x -> 100.x), связь пропала, а ручной ifup всё чинил.
#
# Правильное лекарство - слушать незапрошенные события модема (+CGEV: NW PDN
# DEACT / NW PDN MODIFY), как это делает штатный протокол atc. Но для этого надо
# ДЕРЖАТЬ AT-порт открытым, а в тот же порт ходят опрос метрик, SMS, USSD и
# управление диапазонами - постоянный читатель либо заблокирует их, либо начнёт
# перехватывать чужие ответы. Поэтому здесь опрос: реже, зато без борьбы за порт.
#
# ЧТО СРАВНИВАЕМ. Адрес, который модем считает выданным (AT+CGPADDR), с адресом,
# который netifd показывает на интерфейсе. Разошлись - сессия пересоздана, и
# интерфейс надо передёрнуть. Заодно ловим погасший контекст (AT+CGACT: 0).
#
# ЧЕГО НЕ ДЕЛАЕМ. Не трогаем модемы под ModemManager: у них за сессией следит
# сам MM, а AT-порт нам не принадлежит (см. detect.sh). И не вмешиваемся, пока
# интерфейс лежит - поднимать его дело autosetup/netifd, а не сторожа.

RES=/usr/share/5gmodem
CFG=5gmodem
INTERVAL="${SESSIONWATCH_INTERVAL:-30}"
# Наши вызовы 5gmodem.sh - фоновые: маркер присутствия страницы они продлевать
# не должны (см. _page_refresh), иначе сбор метрик не остановится никогда.
export SW_BG=1

. "$RES/atlock.sh" 2>/dev/null
. "$RES/lib.sh" 2>/dev/null   # active_path

_log() { logger -t 5gmodem "sessionwatch: $*"; }

# ОГРАНИЧИТЕЛЬ ВРЕМЕНИ ДЛЯ uqmi. На заклиненном канале uqmi ВИСНЕТ НАВЕЧНО,
# игнорируя собственный -t (задокументировано в mkiface, воспроизведено живьём
# 03.08.2026: два зависших --get-data-status держали cdc-wdm, дозвон netifd
# встал за ними в очередь). Сторож - демон: один такой вызов без предохранителя
# повесил бы ВСЕ его проверки разом. Паттерн киллера тот же, что в smsbridge.
_sw_run() {   # $1 - таймаут (с), дальше - команда
	_swr_t="$1"; shift
	"$@" 2>/dev/null &
	_swr_p=$!
	( exec >/dev/null 2>&1; sleep "$_swr_t"; kill "$_swr_p" 2>/dev/null ) </dev/null & _swr_w=$!
	wait "$_swr_p"; _swr_rc=$?
	kill "$_swr_w" 2>/dev/null; wait "$_swr_w" 2>/dev/null
	return $_swr_rc
}

# СНЯТЬ ЗАВИСШИЕ uqmi, ДЕРЖАЩИЕ КАНАЛ ЛЕЖАЧЕГО ИНТЕРФЕЙСА.
#
# uqmi виснет на заклиненном канале НАВЕЧНО, игнорируя собственный -t (то же
# известно про наши вызовы - отсюда _sw_run). Но эти процессы порождает netifd,
# и их не чистит никто: после сдачи протокола («Stopping network») они остаются
# висеть на /dev/cdc-wdm0 и не дают дозвониться ни netifd, ни лечению, ни нам.
# Живой случай 05.08.2026, Quectel EP06 после самосброса под нагрузкой: на
# устройстве висели `--uim-power-off` из цикла power-cycle SIM и `--get-pin-status`,
# интерфейс лежал намертво; хватило снять их - и подъём прошёл с первого раза.
#
# Берём только процессы СТАРШЕ порога: короткоживущий uqmi - это чей-то штатный
# запрос, а свой -t они переживать не должны в принципе. Порог невелик намеренно:
# ВСЕ вызовы uqmi идут с собственным -t (1-10 c), поэтому проживший 15 c - уже
# аномалия, а ждать дольше значит держать дозвон netifd в очереди за мертвецом.
# Тот же приём описан в народном how-to по QMI-модемам: там первый
# `uqmi --get-pin-status` виснет на непрогретом канале, и его убивают через 3 c
# прямо в qmi.sh - без этого «модем подключается через раз» (SimCom, Telit).
# Мы штатный qmi.sh не правим (он обновляется с системой), но лечим тот же
# класс отказа снаружи.
_kill_stuck_uqmi() {   # $1 - устройство (/dev/cdc-wdm*)
	[ -n "$1" ] || return 0
	_ku_up=$(_now)
	for _ku_p in /proc/[0-9]*; do
		# ИМЯ ИСПОЛНЯЕМОГО, А НЕ ПОДСТРОКА В КОМАНДНОЙ СТРОКЕ. По подстроке под
		# нож попадает всё, где рядом встретились «uqmi» и путь устройства:
		# шелл-обёртки, наши же скрипты, grep. Поймано при проверке 05.08.2026 -
		# первым совпадением оказалась сама тестовая команда.
		read -r _ku_cm 2>/dev/null < "$_ku_p/comm" || continue
		[ "$_ku_cm" = uqmi ] || continue
		_ku_cl=$(tr '\0' ' ' 2>/dev/null < "$_ku_p/cmdline") || continue
		case "$_ku_cl" in
			*" $1 "*|*" $1") ;;
			*) continue ;;
		esac
		_ku_st=$(cut -d' ' -f22 "$_ku_p/stat" 2>/dev/null)
		case "$_ku_st" in ''|*[!0-9]*) continue ;; esac
		[ $((_ku_up - _ku_st / 100)) -ge 15 ] || continue
		_ku_pid="${_ku_p#/proc/}"
		_log "killing stuck uqmi $_ku_pid on $1 - it is holding the channel of a down interface"
		kill -9 "$_ku_pid" 2>/dev/null
		_ku_killed=1
	done
	[ -n "$_ku_killed" ] && { _ku_killed=""; sleep 2; }
	return 0
}

# Протоколы, за которыми следим. ModemManager СОЗНАТЕЛЬНО не трогаем: у него
# своё слежение, и AT-порт нам не принадлежит.
#   at-группа  - сессию ведём мы, состояние спрашиваем у модема по AT;
#   qmi/mbim   - сессию ведёт netifd через uqmi/umbim, AT-порт при этом свободен,
#                но спрашивать модем бесполезно: он может считать контекст живым,
#                когда WDS-сессия уже умерла. Для них признак другой - интерфейс
#                «up», а адреса нет (см. check_once).
_watched_proto() {
	case "$1" in
		fibocom|atc|xmm|ncm|3g|wwan) return 0 ;;
		qmi|mbim) return 0 ;;
		*) return 1 ;;
	esac
}
_kernel_proto() {
	case "$1" in qmi|mbim) return 0 ;; *) return 1 ;; esac
}

# Адрес, который netifd держит на интерфейсе.
_iface_ip() {
	ifstatus "$1" 2>/dev/null \
		| sed -n 's/.*"address": *"\([0-9.]\{7,\}\)".*/\1/p' | head -1
}

# Только для проверки «поднят, но без адреса»: чисто-IPv6-сессия (оператор дал
# один v6) - это ЖИВАЯ связь, а v4-проба выше её не видит и сторож рестартил бы
# её по кругу. В сверку с CGPADDR (v4) этот хелпер НЕ подмешивать.
_iface_ip6() {
	ifstatus "$1" 2>/dev/null \
		| sed -n 's/.*"address": *"\([0-9a-fA-F:]*:[0-9a-fA-F:]*\)".*/\1/p' | head -1
}

# Адрес, который выдал модем. Пусто - прочитать не удалось (порт занят и т.п.),
# и это НЕ повод дёргать интерфейс: молчание порта само по себе не значит, что
# сессия умерла.
_modem_ip() {
	_mi_out=$(at_query "$1" "AT+CGPADDR=1" 8)
	printf '%s' "$_mi_out" | sed -n 's/.*+CGPADDR: *1,"\([0-9.]\{7,\}\)".*/\1/p' | head -1
}

# Контекст активен? Пустой ответ трактуем как «не знаем» (см. выше).
_ctx_active() {
	_ca=$(at_query "$1" "AT+CGACT?" 8 \
		| sed -n 's/.*+CGACT: *1, *\([0-9]\).*/\1/p' | head -1)
	[ -z "$_ca" ] && return 0
	[ "$_ca" = "1" ]
}

# --- ОБХОД ВСЕХ МОДЕМОВ ------------------------------------------------------
#
# Раньше сторож смотрел ОДИН модем - тот, что выбран активным. Если в системе
# четыре, у трёх сессия оставалась без присмотра: интерфейс «up», трафика нет, и
# никто не вмешивался, пока пользователь не переключит вкладку. Это не гипотеза:
# на стенде из четырёх секций три интерфейса лежали, а сторож по построению видел
# один.
#
# Почему так было: связка «путь -> секция -> интерфейс + AT-порт» готова только у
# активного, а собирать её для всех было дорого и в каждом месте по-своему.
# Теперь её отдаёт registry.sh - и обход становится дешёвым.
#
# ТРИ ПРАВИЛА, чтобы обход не стал хуже болезни:
#
#   1. МОДЕМЫ ПОД ModemManager НЕ ТРОГАЕМ. У него своё слежение, а AT-порт нам не
#      принадлежит: наш опрос ломал ему подъём соединения (проверено).
#      Владельца канала теперь говорит реестр - `owner`.
#   2. ЗА ЦИКЛ - НЕ БОЛЬШЕ ОДНОЙ AT-ПРОВЕРКИ. qmi/mbim проверяются по интерфейсу
#      и каналу, без AT - их можно смотреть каждый цикл. А вот AT-протоколы
#      делят очередь к портам с опросом метрик, SMS и USSD, и бить в четыре порта
#      разом значит отобрать порт у страницы. Поэтому AT-модемы идут по кругу:
#      один за цикл.
#   3. ПРЕДОХРАНИТЕЛЬ ОТ ЛАВИНЫ. `ifup` одного интерфейса не чаще, чем раз в
#      COOLDOWN секунд. Иначе неподнимающийся модем дёргался бы каждые 30 c
#      бесконечно, мешая и себе, и соседям.
COOLDOWN=180

_now() { cut -d' ' -f1 /proc/uptime | cut -d. -f1; }

# КАРТА В ОТКАЗЕ - ПОДНИМАТЬ ИНТЕРФЕЙС НЕЛЬЗЯ, ЭТО КОРМИТ ПЕТЛЮ.
#
# Получив «illegal» (или пустоту) на состояние карты, qmi.sh уходит в
# бесконечный цикл power-cycle SIM раз в 8 секунд. Модему, которому на
# инициализацию карты нужны минуты (Quectel EP06 - около двух), это не даёт
# подняться никогда. Свой ifup здесь только перезапускал бы петлю, поэтому
# ждём: пока мы молчим, интерфейс висит в gone, и его забирает лестница
# health - у неё есть перезагрузка модуля (AT+CFUN=1,1), а это единственное,
# что такой отказ снимает (живой случай 05.08.2026).
#
# Ждём не вечно: если канал занят и состояние не читается кругами, разрешаем
# подъём как раньше - молчащий uqmi не повод оставлять исправный модем лежать.
#
# ПОЧЕМУ ОДНА ФУНКЦИЯ НА ДВА СТОРОЖА. Проверка была только у ветки залипшей
# WDS-сессии, а ветка прокси-сироты поднимала интерфейс без неё - и на модеме
# с картой в illegal раз в две минуты сбрасывала ошибку интерфейса, из-за чего
# лестница health не накапливала ни одной попытки и не доходила до сброса
# модуля (живой случай Telit FN990A28 на WH3000 Pro, 04.09.2026: петля
# «SIM in illegal state» шла кругами всё время работы роутера).
#
# 0 - поднимать можно, 1 - ждём лестницу.
_sw_sim_ready() {   # $1 - интерфейс
	_ssr_if="$1"
	# Состояние карты читает uqmi, а он говорит только по QMI. Для mbim и
	# прочих прото проверки нет - ведём себя как раньше.
	case "$(uci -q get "network.$_ssr_if.proto" 2>/dev/null)" in
		qmi|qmiraw) : ;;
		*) return 0 ;;
	esac
	_ssr_dev=$(uci -q get "network.$_ssr_if.device" 2>/dev/null)
	case "$_ssr_dev" in /dev/*) : ;; *) return 0 ;; esac
	_ssr_st=$(_sw_run 8 uqmi -s -d "$_ssr_dev" -t 2000 --uim-get-sim-state 2>/dev/null)
	_ssr_bad=""
	case "$_ssr_st" in
		*'"card_application_state"'*)
			case "$_ssr_st" in *'"illegal"'*) _ssr_bad=1 ;; esac ;;
		*) _ssr_bad=1 ;;
	esac
	_ssr_f="/tmp/5gmodem_sw_sim_$_ssr_if"
	if [ -z "$_ssr_bad" ]; then
		rm -f "$_ssr_f" 2>/dev/null
		return 0
	fi
	_ssr_n=$(cat "$_ssr_f" 2>/dev/null)
	case "$_ssr_n" in ''|*[!0-9]*) _ssr_n=0 ;; esac
	[ "$_ssr_n" -lt 6 ] || return 0
	printf '%s' "$((_ssr_n + 1))" > "$_ssr_f" 2>/dev/null
	_log "$_ssr_if: SIM not ready - bring-up postponed, waiting for the recovery ladder ($((_ssr_n + 1))/6)"
	return 1
}

# Переподнять интерфейс, если не дёргали его совсем недавно.
_revive() {   # $1 - интерфейс, $2 - причина для журнала
	_rv_f="/tmp/5gmodem_sw_last_$1"
	_rv_now=$(_now)
	_rv_prev=$(cat "$_rv_f" 2>/dev/null)
	case "$_rv_prev" in
		''|*[!0-9]*) _rv_prev=0 ;;
	esac
	if [ $((_rv_now - _rv_prev)) -lt "$COOLDOWN" ]; then
		_log "$1: $2 - last bring-up was $((_rv_now - _rv_prev))s ago, waiting"
		return 0
	fi
	printf '%s' "$_rv_now" > "$_rv_f" 2>/dev/null
	_log "$1: $2 - restarting"
	iface_up "$1"
}

# Проверка ОДНОГО модема. Все данные пришли из реестра, ничего не досчитываем.
check_one() {   # $1 - путь, $2 - интерфейс, $3 - прото, $4 - AT-порт
	_path="$1"; _if="$2"; _proto="$3"; _port="$4"

	# ЛЕЖАЧИЙ ИНТЕРФЕЙС - ТОЖЕ НАША ЗАБОТА, ЕСЛИ ЕГО НИКТО НЕ ПОДНИМАЕТ.
	#
	# Раньше здесь стоял безусловный выход: считалось, что упавший интерфейс
	# поднимет netifd. Но netifd сдаётся - протокол при ошибке зовёт
	# proto_block_restart, и после этого автоматических попыток БОЛЬШЕ НЕТ.
	# Второй сторож (health) такой интерфейс тоже пропускает: без l3-устройства
	# он помечает его «gone» и лечение не запускает. В итоге модем, у которого
	# дозвон однажды не удался, остаётся лежать до ручного ifup - при живой SIM,
	# регистрации в сети и исправном канале (живой случай 05.08.2026: Quectel
	# EP06, интерфейс не поднимался, в журнале ни одной попытки восстановления).
	# Поднимаем сами: только автозапускаемый интерфейс (намеренно опущенный
	# автозапуск не имеет), только если устройство модема на месте, и не чаще
	# кулдауна - тем же _revive, что и остальные случаи.
	_sw_st=$(ifstatus "$_if" 2>/dev/null)
	case "$_sw_st" in
		*'"up": true'*) : ;;
		*)
			case "$_sw_st" in
				*'"autostart": true'*) : ;;
				*) return 0 ;;    # опущен намеренно - не трогаем
			esac
			# Модема на шине нет - поднимать нечего, этим занимается resolve.
			[ -n "$_path" ] && [ -e "/sys/bus/usb/devices/$_path/idVendor" ] || return 0
			# ЗАВИСШИЕ uqmi СНИМАЕМ ДО ВСЕГО ОСТАЛЬНОГО, включая проверку pending:
			# именно они и держат netifd в бесконечном дозвоне, занимая канал.
			[ "$_proto" = qmi ] && _kill_stuck_uqmi "$(uci -q get "network.$_if.device")"
			# NETIFD УЖЕ РАБОТАЕТ - НЕ МЕШАЕМ. В состоянии pending идёт дозвон, и
			# наш down/up оборвал бы его на полпути: получилась бы гонка двух
			# «подъёмщиков» вместо восстановления.
			case "$_sw_st" in *'"pending": true'*) return 0 ;; esac
			# Двух кругов подряд достаточно: одиночный промах бывает в момент
			# штатного передозвона, а ждать дольше незачем - связи всё равно нет.
			_dflag="/tmp/5gmodem_sw_down_$_if"
			if [ -f "$_dflag" ]; then
				rm -f "$_dflag"
				# ДЕРЕГИСТРИРОВАН КОМАНДОЙ - ДОЗВОН НЕ ПОЛУЧИТСЯ НИКОГДА.
				# +COPS: 2 оставляет оборванный цикл дозвона (скрипты xmm/gcom
				# шлют COPS=2 в начале), и сам модем сеть искать больше не
				# будет: интерфейс лежит, передозвоны крутятся впустую, а тот же
				# модем в другом роутере регистрируется сразу (живой отчёт
				# 09.08.2026: L850, МТС «Not registered»). Возвращаем поиск сети
				# командой AT+COPS=0 - не чаще раза в 5 минут и только при
				# свободном от дозвонщика порте.
				if [ -n "$_port" ] && ! at_dialer_busy "$_port"; then
					case "$_proto" in
						xmm|atc|fibocom|3g|ncm)
							_swcf="/tmp/5gmodem_sw_cops_$_if"
							_swnow=$(_now)
							_swlast=$(cat "$_swcf" 2>/dev/null)
							case "$_swlast" in ''|*[!0-9]*) _swlast=0 ;; esac
							if [ $((_swnow - _swlast)) -ge 300 ]; then
								_swc=$(at_query "$_port" "AT+COPS?" 6 4 2>/dev/null 									| tr -d '\r' \
									| sed -n 's/^+COPS: *\([0-9]*\).*/\1/p' | head -1)
								if [ "$_swc" = "2" ]; then
									_log "modem on $_if was deregistered by command (+COPS: 2) - re-enabling network search"
									at_query "$_port" "AT+COPS=0" 20 4 >/dev/null 2>&1
									printf '%s' "$_swnow" > "$_swcf" 2>/dev/null
								fi
							fi
							;;
					esac
				fi
				# ЗАЛИПШАЯ WDS-СЕССИЯ. Модем отвечает «connected», хотя интерфейс
				# лежит: netifd не довёл прошлый дозвон до конца (таймаут), сессия
				# осталась висеть с чужим client-id, и КАЖДАЯ новая попытка падает
				# - «SIM in illegal state», «Request timed out», «Unknown error».
				# Сам по себе такой узел не рассосётся: ifup будет упираться в него
				# бесконечно (наблюдалось дважды на живом Quectel EP06 05.08.2026,
				# оба раза лечилось руками). Гасим сеть перед подъёмом - это
				# штатная операция uqmi, при свободном канале она безопасна.
				if [ "$_proto" = qmi ]; then
					_swd=$(uci -q get "network.$_if.device")
					case "$_swd" in
						/dev/*)
							# Карта в отказе - подъём откладываем (см. _sw_sim_ready).
							_sw_sim_ready "$_if" || return 0
							if [ "$(_sw_run 8 uqmi -d "$_swd" --get-data-status \
								| tr -d '"' | tr -d '[:space:]')" = "connected" ]; then
								_log "$_if: session stuck \"connected\" while the interface is down - stopping it before bring-up"
								_sw_run 10 uqmi -d "$_swd" --stop-network 0xffffffff --autoconnect >/dev/null 2>&1
								sleep 2
							fi ;;
					esac
				fi
				_revive "$_if" "лежит, а автозапуск включён"
			else
				: > "$_dflag"
			fi
			return 0 ;;
	esac
	rm -f "/tmp/5gmodem_sw_down_$_if" "/tmp/5gmodem_sw_sim_$_if" 2>/dev/null

	if _kernel_proto "$_proto"; then
		# АДРЕС ИЩЕМ И У ДЕТЕЙ. У qmi/mbim родительский интерфейс адреса НЕ
		# получает - его берёт дочерний DHCP-интерфейс (<имя>_4 / <имя>_6).
		# Проверка только по родителю считала рабочее соединение аварийным и
		# передёргивала его каждые две минуты (поймано на живом Telit).
		_iip=$(_iface_ip "$_if")
		[ -n "$_iip" ] || _iip=$(_iface_ip "${_if}_4")
		[ -n "$_iip" ] || _iip=$(_iface_ip "${_if}_6")
		[ -n "$_iip" ] || _iip=$(_iface_ip6 "$_if")
		[ -n "$_iip" ] || _iip=$(_iface_ip6 "${_if}_6")
		# И спрашиваем сам канал: для qmi это дешёвая и честная проверка.
		#
		# СРАВНИВАЕМ ЦЕЛИКОМ, А НЕ ПОДСТРОКОЙ. uqmi отвечает "connected" или
		# "disconnected" - и во втором слове первое содержится целиком. Прежний
		# `grep -q connected` совпадал ВСЕГДА, то есть сторож считал живой любую
		# мёртвую сессию и не переподнимал её ни разу (поймано на Telit LM960:
		# аренда DHCP истекла, uqmi честно говорил "disconnected", интерфейс
		# висел «up» без адреса 20 минут, в логе сторожа - ни строки).
		if [ -z "$_iip" ] && [ "$_proto" = qmi ]; then
			_wdm=$(uci -q get "network.$_if.device")
			case "$_wdm" in
				/dev/*)
					_ds=$(_sw_run 10 uqmi -d "$_wdm" --get-data-status \
						| tr -d '"' | tr -d '[:space:]')
					[ "$_ds" = "connected" ] && _iip="connected" ;;
			esac
			# «СЕССИЯ ЕСТЬ, А АДРЕСА НЕТ» - ЭТО НЕ ЗДОРОВЬЕ, А ЗАВИСШИЙ КАНАЛ.
			#
			# Строка выше признаёт линк живым по одному ответу QMI - и на
			# SIM7100E это ошибка: модем честно говорит "connected", отдаёт по
			# QMI адрес, а канал не несёт ни байта (TX растёт, RX ноль). Ни
			# ifup, ни DHCP, ни статика из QMI не помогают - лечит только
			# переинициализация модема. Поймано дважды, на двух стендах.
			#
			# Ждём три круга подряд: одиночный такой такт бывает в момент
			# нормального дозвона, когда адрес ещё не доехал до netifd.
			if [ "$_iip" = "connected" ]; then
				_qf="/tmp/5gmodem_sw_qmistuck_$_if"
				_qn=$(cat "$_qf" 2>/dev/null); case "$_qn" in ''|*[!0-9]*) _qn=0 ;; esac
				_qn=$((_qn + 1)); printf '%s' "$_qn" > "$_qf" 2>/dev/null
				if [ "$_qn" -ge 3 ]; then
					rm -f "$_qf" 2>/dev/null
					# ФОРМАТ КАДРОВ - НАЗЫВАЕМ ПРИЧИНУ, ЕСЛИ ОНА ВИДНА. У этого
					# отказа есть проверяемый признак: драйвер и прошивка
					# договорились о разном (raw_ip против 802-3), и приём молча
					# отбрасывается. Сброс лечит и так, но в журнале должно быть
					# написано, ЧТО именно было не так - иначе следующий разбор
					# начнётся с нуля.
					_qdev=$(ifstatus "$_if" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
					_qraw=$(cat "/sys/class/net/$_qdev/qmi/raw_ip" 2>/dev/null)
					# Формат читаем ТОЛЬКО через qmicli_p. Голый `qmicli -p` поднимал
					# здесь qmi-proxy, тот оставался жить - и следующий же круг этого
					# сторожа видел его как сироту, убивал и делал ifup. Сторож ловил
					# собственный хвост, а на модеме с картой в illegal этот ifup ещё
					# и сбрасывал ошибку интерфейса, из-за чего лестница health не
					# накапливала попытку (Telit FN990A28, 04.09.2026). У qmicli_p
					# гейт на это есть: при proto=qmi он читает напрямую.
					_qfmt=""
					[ -c "$_wdm" ] && \
						_qfmt=$(qmicli_p "$_wdm" --wda-get-data-format 2>/dev/null \
							| sed -n "s/.*Link layer protocol: *'\([^']*\)'.*/\1/p" | head -1)
					# 802.3 БЕЗ АДРЕСА (SIM7100E): и драйвер, и модем в 802.3
					# согласованно (не рассинхрон!), сессия QMI connected и адрес по
					# QMI есть - а модем DHCP-offer в 802.3 не отдаёт. Штатный qmi.sh
					# на каждом дозвоне упрямо форсит 802.3, поэтому переинициализация
					# не помогает - петля. Перевод в raw-ip (IP берётся статикой из
					# QMI) поднимает адрес без ресета (проверено: SIM7100E 14.08.2026,
					# raw-ip переживает передозвон - uqmi-откат в 802.3 модем игнорит).
					# Пробуем ОДИН раз за эпизод; не помогло - падаем в ресет ниже.
					_qrf="/tmp/5gmodem_sw_rawiptry_$_if"
					if [ ! -f "$_qrf" ] && [ -f /lib/netifd/proto/qmiraw.sh ] \
					   && [ "$(uci -q get "network.$_if.proto")" = qmi ]; then
						: > "$_qrf"
						_log "$_if: QMI connected but no address in 802.3 mode - switching the interface to proto=qmiraw (raw-ip + static from QMI) and redialing"
						uci set "network.$_if.proto=qmiraw"
						uci set "network.$_if.dhcp=0"
						uci commit network
						REGISTER_PROTO_FORCE=1 "$RES/register_proto.sh" >/dev/null 2>&1
						( ifdown "$_if"; sleep 2; iface_up "$_if" ) >/dev/null 2>&1 </dev/null &
					else
						case "$_qraw:$_qfmt" in
							Y:802-3|N:raw-ip)
								_log "$_if: frame format mismatch (driver raw_ip=$_qraw, modem $_qfmt) - inbound traffic is being dropped" ;;
						esac
						_log "$_if: QMI says connected but no address for $_qn cycles - reinitializing the modem"
						"$RES/qmi-recover.sh" reset "$_path" "канал не поднялся ($_if)" >/dev/null 2>&1
					fi
				fi
			fi
		fi
		[ -n "$_iip" ] && [ "$_iip" != "connected" ] && rm -f "/tmp/5gmodem_sw_qmistuck_$_if" "/tmp/5gmodem_sw_rawiptry_$_if" 2>/dev/null
		if [ -z "$_iip" ]; then
			# Второй раз подряд - только тогда действуем: одиночный пропуск
			# бывает в момент нормального передозвона.
			_flag="/tmp/5gmodem_sw_noip_$_if"
			if [ -f "$_flag" ]; then
				rm -f "$_flag"
				_revive "$_if" "поднят ($_proto), но без адреса"
			else
				: > "$_flag"
			fi
		else
			rm -f "/tmp/5gmodem_sw_noip_$_if" 2>/dev/null
		fi
		return 0
	fi

	# AT-ПРОТОКОЛЫ. Порт уже сверен реестром со списком портов этого модема -
	# устаревшая настройка сюда не дойдёт (раньше это проверялось здесь руками, и
	# именно на такой рассинхронизации строились ошибки «не тот модем»).
	[ -n "$_port" ] && [ -c "$_port" ] || return 0

	# В общую очередь к порту: сторож не должен вклиниваться в чужой обмен.
	command -v at_lock >/dev/null 2>&1 && { at_lock "$_port" 10 || return 0; }
	_mip=$(_modem_ip "$_port")
	_act=0; _ctx_active "$_port" && _act=1
	command -v at_unlock >/dev/null 2>&1 && at_unlock 2>/dev/null

	_iip=$(_iface_ip "$_if")

	# Контекст погас - сессии нет, поднимаем заново.
	if [ "$_act" = "0" ]; then
		_revive "$_if" "контекст данных погас (CGACT=0)"
		return 0
	fi

	# Оба адреса известны и РАЗОШЛИСЬ - сеть пересоздала сессию.
	if [ -n "$_mip" ] && [ -n "$_iip" ] && [ "$_mip" != "$_iip" ]; then
		_revive "$_if" "адрес сменился ($_iip -> $_mip)"
		return 0
	fi
	return 0
}

# СНИМОК РЕЕСТРА НА ВЕСЬ ЦИКЛ - ОДИН, И В ПЛОСКОЙ ФОРМЕ.
#
# Было: `registry.sh` (JSON) в check_once + ещё один `registry.sh paths` в
# подогреве, а каждое поле каждого модема доставалось отдельным jsonfilter - до
# восьми запусков на модем. На двух модемах это ~20 подпроцессов и две полных
# сборки реестра за тик, при том что данные одни и те же.
#
# Стало: одна `registry.sh flat` на тик, разбор - `while read` без единого
# подпроцесса. Плоскую форму отдаёт сам реестр (см. глагол flat), поэтому правило
# «связку собирает одно место» не нарушено.
_REG_FLAT=""
_reg_refresh() { _REG_FLAT=$("$RES/registry.sh" flat 2>/dev/null); }

check_once() {
	[ -n "$_REG_FLAT" ] || return 0

	# Чей ход делать AT-проверку в этом цикле. Счётчик в /tmp: он должен
	# переживать отдельные вызовы `once`, но не перезагрузку - после неё порядок
	# заново, и это нормально.
	_turnf=/tmp/5gmodem_sw_turn
	_turn=$(cat "$_turnf" 2>/dev/null)
	case "$_turn" in ''|*[!0-9]*) _turn=0 ;; esac

	# Сначала собираем список AT-модемов, чтобы знать, чей ход.
	_atlist=""
	while read -r _p _sec _i _pr _at _o; do
		[ -n "$_p" ] || continue
		[ "$_o" = "mm" ] && continue
		[ "$_i" = "-" ] && continue
		_watched_proto "$_pr" || continue
		_kernel_proto "$_pr" && continue
		_atlist="$_atlist $_p"
	done <<EOF
$_REG_FLAT
EOF
	_atn=0
	for _x in $_atlist; do _atn=$((_atn + 1)); done
	_atpick=""
	if [ "$_atn" -gt 0 ]; then
		_k=$((_turn % _atn)); _j=0
		for _x in $_atlist; do
			[ "$_j" = "$_k" ] && { _atpick="$_x"; break; }
			_j=$((_j + 1))
		done
		printf '%s' "$(( (_turn + 1) % 1000 ))" > "$_turnf" 2>/dev/null
	fi

	while read -r _p _sec _if _proto _at _own; do
		[ -n "$_p" ] || continue
		# Модем под ModemManager - не наша забота (см. правило 1).
		[ "$_own" = "mm" ] && continue
		[ "$_if" = "-" ] && continue
		_watched_proto "$_proto" || continue
		# AT-протокол проверяем только если сейчас его ход (правило 2).
		if ! _kernel_proto "$_proto" && [ "$_p" != "$_atpick" ]; then
			continue
		fi
		[ "$_at" = "-" ] && _at=""
		check_one "$_p" "$_if" "$_proto" "$_at"
	done <<EOF
$_REG_FLAT
EOF
}

# ПОДОГРЕВ СНИМКОВ НЕАКТИВНЫХ МОДЕМОВ.
#
# ЗАЧЕМ. Снимок метрик есть только у активного модема - его поддерживает открытая
# страница. У остальных файла нет вовсе, и переключение вкладки выглядит так: клик
# -> перезагрузка -> peek отдаёт {} -> ПУСТАЯ карточка -> и лишь через ~1 c полного
# опроса появляются цифры. Замерено на стенде, и это же люди описывают как «второй
# модем мёртвый».
#
# Сторож для этого подходит лучше всего: он уже раз в 30 c обходит ВСЕ модемы по
# реестру, то есть ни нового демона, ни нового таймера не нужно.
#
# ПРАВИЛА, ЧТОБЫ ПОДОГРЕВ НЕ СТАЛ ВРЕДОМ:
#   1) активный не трогаем - им занимается страница;
#   2) один модем за цикл, по кругу: полный опрос AT-модема занимает ~1.3 c и
#      держит его порт, и делать это всем сразу нельзя;
#   3) только если снимок ОТСУТСТВУЕТ или уже протух (порог ниже) - свежий не
#      переопрашиваем;
#   4) AT-порт модема под ModemManager не трогаем - это правило соблюдает сам
#      опрос при пиновке (см. POLL_MODEM в 5gmodem.sh), здесь его дублировать не
#      надо: для MM-модема метрики придут из mmcli и тоже лягут в снимок.
WARM_MAXAGE="${SESSIONWATCH_WARM_MAXAGE:-45}"
warm_snapshots() {
	[ "$WARM_MAXAGE" = "0" ] && return 0          # выключено настройкой
	_wa=$(active_path)
	_wnow=$(uptime_s)
	_wall=""
	while read -r _wp _wrest; do
		[ -n "$_wp" ] && _wall="$_wall $_wp"
	done <<EOF
$_REG_FLAT
EOF
	_wlist=""
	for _wp in $_wall; do
		[ "$_wp" = "$_wa" ] && continue
		# MM-МОДЕМ НЕ ГРЕЕМ ИЗ WARM. Полный опрос неактивного модема лезет в AT, а у
		# MM-модема метрики и так идут из mmcli (при показе карточки). Пока MM его
		# инициализирует (частый флап EM9190 - переэнумерация каждые ~15с), наш AT в
		# warm - лишняя драка за порт: опрос виснет и отдаёт стухший снимок, а модему
		# мешает встать. Активный MM-модем опрашивается штатно; это про НЕактивные.
		_wsec="m_$(printf '%s' "$_wp" | sed 's/[^A-Za-z0-9]/_/g')"
		_wif=$(uci -q get "$CFG.$_wsec.network")
		[ -n "$_wif" ] && [ "$(uci -q get "network.$_wif.proto")" = "modemmanager" ] && continue
		_wk=$(snap_key "$_wp")
		[ -s "/tmp/5gmodem_metrics_$_wk.json" ] || { _wlist="$_wlist $_wp"; continue; }
		_wt=$(cat "/tmp/5gmodem_metrics_$_wk.stamp" 2>/dev/null)
		case "$_wt" in
			''|*[!0-9]*) _wlist="$_wlist $_wp"; continue ;;
		esac
		[ "$(( _wnow - _wt ))" -ge "$WARM_MAXAGE" ] && _wlist="$_wlist $_wp"
	done
	_wn=0
	for _x in $_wlist; do _wn=$((_wn + 1)); done
	[ "$_wn" -gt 0 ] || return 0
	# Свой счётчик, отдельный от AT-хода проверки сессии: там список другой (без
	# MM-модемов), и делить один счётчик значило бы пропускать модемы.
	_wtf=/tmp/5gmodem_sw_warm
	_wt=$(cat "$_wtf" 2>/dev/null)
	case "$_wt" in ''|*[!0-9]*) _wt=0 ;; esac
	_wk=$(( _wt % _wn )); _wj=0; _wpick=""
	for _x in $_wlist; do
		[ "$_wj" = "$_wk" ] && { _wpick="$_x"; break; }
		_wj=$((_wj + 1))
	done
	printf '%s' "$(( (_wt + 1) % 1000 ))" > "$_wtf" 2>/dev/null
	[ -n "$_wpick" ] || return 0
	logger -t 5gmodem "snapshot warm-up: polling inactive modem $_wpick"
	POLL_MODEM="$_wpick" "$RES/5gmodem.sh" json >/dev/null 2>&1
}

# ФОНОВЫЙ СБОРЩИК МЕТРИК ПРИ ОТКРЫТОЙ СТРАНИЦЕ.
#
# Раньше снимок держал свежим сам тик страницы: свежесть 4 c при опросе раз в
# 5 c означала полный сбор (1.3-1.8 c CPU) на КАЖДЫЙ тик - открытая «Сеть»
# постоянно грузила роутер. Теперь страница лишь отмечает присутствие (маркер
# пишет верб cached в 5gmodem.sh), а собираем МЫ - раз в ~5-6 c, единственным
# сборщиком через тот же LOCKDIR. Тик страницы попадает в готовый кэш (~90 мс).
# Закрыли страницу - маркер протухает за 15 c, сбор останавливается сам.
# SW_BG=1 не даёт нашему же вызову продлевать маркер (иначе вечный цикл).
_page_refresh() {
	_pr_t=$(cat /tmp/5gmodem_page_active 2>/dev/null)
	case "$_pr_t" in ''|*[!0-9]*) return 0 ;; esac
	[ $(( $(_now) - _pr_t )) -lt 15 ] || return 0
	_pr_ap=$(active_path)
	[ -n "$_pr_ap" ] || return 0
	# СВЕЖИЙ СНИМОК - НЕ СПАВНИМ ВОВСЕ. «Мгновенный выход» 5gmodem.sh при
	# свежем кэше всё равно стоит полного парса скрипта, lib.sh и похода в
	# реестр - и так 4-6 раз за круг. Стамп хранит секунды аптайма (та же
	# шкала, что _now), прочитать его - одно чтение файла. Формула ключа - как
	# в snap_key (lib.sh): не-алфавитно-цифровое в подчёркивание; printf без
	# перевода строки давал бы ключ без хвостового «_», поэтому echo.
	_pr_k=$(echo "$_pr_ap" | tr -c 'A-Za-z0-9' '_')
	_pr_sm=$(cat "/tmp/5gmodem_metrics_${_pr_k}.stamp" 2>/dev/null)
	case "$_pr_sm" in
		''|*[!0-9]*) ;;
		*) [ $(( $(_now) - _pr_sm )) -lt 7 ] && return 0 ;;
	esac
	_sw_run 25 "$RES/5gmodem.sh" cached 7 "for=$_pr_ap" >/dev/null 2>&1
	return 0
}

# УБОРКА ВРЕМЯНОК, ОСИРОТЕВШИХ ПОСЛЕ УБИЙСТВА ПРОЦЕССА.
#
# Файлы с PID в имени (5gmodem_st.$$.N, atq.$$, qmicli.$$, providers.$$,
# .atprobe.$$, cache.tmp.$$, файлы моста eSIM) убираются только на счастливом
# пути: их создатель либо доработал и стёр их сам, либо был убит - нашим же
# киллером на 25-й секунде или rpcd на 30-й - и тогда rm не выполнился. /tmp
# здесь tmpfs, то есть это утечка ПАМЯТИ: при деградации порта (каждый опрос
# дорабатывает до киллера) файлы копятся с каждым кругом. Живому файлу такого
# вида больше десяти минут быть неоткуда - самый долгий владелец (загрузка
# профиля eSIM) укладывается в минуты, а опрос - в секунды.
_sweep_tmp() {
	find /tmp -maxdepth 1 \( \
		-name '5gmodem_st.[0-9]*' -o -name '5gmodem_atq.[0-9]*' \
		-o -name '5gmodem_qmicli.[0-9]*' -o -name '5gmodem_providers.[0-9]*' \
		-o -name '.atprobe.[0-9]*' -o -name '5gmodem_listmodems.cache.tmp.[0-9]*' \
		-o -name '5gmodem_esim_hreq.[0-9]*' -o -name '5gmodem_esim_hbody.[0-9]*' \
		-o -name '5gmodem_esim_hhdr.[0-9]*' -o -name '5gmodem_esim_res.[0-9]*' \
		-o -name '5gmodem_uim.[0-9]*' -o -name '5gmodem_ttl.[0-9]*.nft' \
		-o -name '5gmodem_metrics_*.p[0-9]*' \
	\) -mmin +10 -exec rm -f {} + 2>/dev/null
}

case "$1" in
	*)
		# ГАРД РЕГИСТРАЦИИ НАШИХ ПРОТО НА СТАРТЕ СТОРОЖА (раз за загрузку).
		# Симптом «наш протокол Fibocom снова неподдерживаемый в LuCI» всплывает
		# после обновлений раз за разом: LuCI берёт список прото у netifd, и если
		# тот по какой-то причине стартовал без нашего обработчика, интерфейс
		# мёртв до ручного рестарта сети. Сторож запускается на каждом буте -
		# проверяем один раз: есть интерфейс на fibocom/qmiraw, а netifd прото
		# не знает -> принудительная регистрация (register_proto сам рестартует
		# сеть только в этом случае, см. его гарды).
		if [ ! -f /tmp/5gmodem_protoguard ]; then
			: > /tmp/5gmodem_protoguard
			( sleep 45
			  _pg_h=$(ubus call network get_proto_handlers 2>/dev/null)
			  for _pg_p in fibocom qmiraw; do
				uci -q show network 2>/dev/null | grep -q "\.proto='$_pg_p'" || continue
				echo "$_pg_h" | grep -q "\"$_pg_p\"" && continue
				logger -t 5gmodem "protoguard: an interface uses $_pg_p but netifd does not know the proto - forcing registration"
				REGISTER_PROTO_FORCE=1 "$RES/register_proto.sh" >/dev/null 2>&1
				break
			  done
			) >/dev/null 2>&1 </dev/null &
		fi
		# НЕ ЧАЩЕ РАЗА В ДВЕ МИНУТЫ. Даже с проверками ниже остаётся окно, где
		# прокси уже поднят, а дозвон ещё не отметился ни процессом, ни
		# pending: тогда мы убивали прокси, netifd начинал заново, поднимал
		# новый прокси - и мы убивали снова. Живой случай 24.08.2026 (T99W175
		# после страницы eSIM): интерфейс перезапускался каждые две секунды и
		# адрес не получал вовсе. Ограничитель разрывает такую петлю: если
		# прокси действительно сирота, следующая попытка всё равно случится.
		_stray_ok() {
			_so_f=/tmp/5gmodem_straykill
			_so_now=$(cut -d. -f1 /proc/uptime)
			_so_last=$(cat "$_so_f" 2>/dev/null)
			case "$_so_last" in ''|*[!0-9]*) _so_last=0 ;; esac
			[ $((_so_now - _so_last)) -ge 120 ] || return 1
			printf '%s\n' "$_so_now" > "$_so_f"
			return 0
		}

		_sweep_n=0
		while :; do
			# ПРОКСИ-СИРОТА НА ПРЯМОМ КАНАЛЕ. Если активный интерфейс на
			# umbim/uqmi (proto mbim/qmi/qmiraw), а в системе живёт
			# mbim-proxy/qmi-proxy БЕЗ ModemManager - прокси лишний и
			# смертельный: он держит cdc-wdm, прямые запросы netifd рушатся, и
			# сессия не поднимается до ребута (живой случай 17.08.2026,
			# ZBT-Z8102AX + MV31-W: «после страницы 5gmodem интернет чинится
			# только перезагрузкой роутера»). Гейт qmi_channel_free новые
			# прокси больше не плодит, а этот чистильщик добивает уже
			# существующих и передозванивает.
			if ! pidof ModemManager >/dev/null 2>&1; then
				_ps_if=$(uci -q get 5gmodem.@5gmodem[0].network)
				case "$(uci -q get "network.$_ps_if.proto" 2>/dev/null)" in
					mbim|qmi|qmiraw)
						if pidof mbim-proxy >/dev/null 2>&1 || pidof qmi-proxy >/dev/null 2>&1; then
							if ubus call "network.interface.$_ps_if" status 2>/dev/null | grep -q '"up": true'; then
								_log "a stray proxy sits on a direct channel ($_ps_if) - killing mbim/qmi-proxy and redialing"
								killall mbim-proxy 2>/dev/null
								killall qmi-proxy 2>/dev/null
								( sleep 2; ifup "$_ps_if" ) >/dev/null 2>&1 </dev/null &
							elif ! pgrep -x lpac >/dev/null 2>&1 \
							   && ! pgrep -x qmicli >/dev/null 2>&1 \
							   && ! pgrep -x mbimcli >/dev/null 2>&1 \
							   && ! pgrep -x umbim >/dev/null 2>&1 \
							   && ! pgrep -x uqmi >/dev/null 2>&1 \
							   && ! pgrep -f "[m]bim\.sh|[q]mi\.sh" >/dev/null 2>&1 \
							   && ! ubus call "network.interface.$_ps_if" status 2>/dev/null | grep -q '"pending": true' \
							   && _stray_ok; then
								# ОПУЩЕННЫЙ интерфейс + прокси БЕЗ ЕДИНОГО КЛИЕНТА -
								# тоже сирота, причём худший: он душит сам дозвон, и
								# «только при поднятом» превращалось во взаимоблок -
								# интерфейс вечно pending («Request timed out» / «SIM
								# in illegal state» по кругу), метла ждала up (Netcore
								# N60 Pro + T99W175, 17.08.2026). Живую операцию
								# eSIM/слотов не заденем: у неё жив lpac/qmicli/mbimcli.
								_log "a stray proxy is blocking the dial ($_ps_if is down) - killing mbim/qmi-proxy"
								killall mbim-proxy 2>/dev/null
								killall qmi-proxy 2>/dev/null
								# Прокси убираем всегда - он душит и наш дозвон, и AT-сброс
								# лестницы. А вот ПОДЪЁМ - только при живой карте: с картой
								# в illegal он лишь запускал петлю qmi.sh заново и обнулял
								# ошибку интерфейса, на которую смотрит health.
								if _sw_sim_ready "$_ps_if"; then
									( sleep 2; ifup "$_ps_if" ) >/dev/null 2>&1 </dev/null &
								fi
							fi
						fi ;;
				esac
			fi
			# Круг нарезан ломтями по 5 c: между обязанностями сторожа успеваем
			# освежать снимок метрик для открытой страницы (см. _page_refresh).
			_sl=0
			while [ "$_sl" -lt "$INTERVAL" ]; do
				sleep 5
				_sl=$((_sl + 5))
				_page_refresh
			done
			# Подметание - раз в ~10 кругов: мусор копится медленно, а find
			# по /tmp на каждом круге был бы платой на ровном месте.
			_sweep_n=$((_sweep_n + 1))
			if [ "$_sweep_n" -ge 10 ]; then _sweep_n=0; _sweep_tmp; fi
			# Реестр собираем ОДИН раз за круг и отдаём обеим задачам: они смотрят
			# на одно и то же состояние, а сборка стоит дороже самих проверок.
			_reg_refresh
			# САМОЛЕЧЕНИЕ РЕГИСТРАЦИИ. Модем есть в реестре, но НЕ заведён нами -
			# карточка без имени и SIM-данных, а recv/метрики бьют по пустой цели.
			# Причины не ловятся штатным триггером на буте (USB-hotplug):
			#  1) autosetup не отработал - на прошивках с ЗАШИТЫМ авто-подъёмом
			#     интерфейса модем поднимает netifd сам, МИМО USB-add, и наш hotplug
			#     не срабатывает (стенд 13.08.2026: SimCom SIM7100E - секции нет,
			#     имя = сырой дескриптор "SimTech, Incorporated", иконки SIM нет);
			#  2) модем настроен мимо autosetup (интерфейс завёл мастер/пользователь).
			# НЕТ СЕКЦИИ - зовём autosetup (он заводит секцию, at_port, модель, active),
			# раз в 2 минуты, чтобы не молотить на неподнимаемом устройстве. Секция
			# ЕСТЬ, но активный не выбран - resolve. Как всё на месте, условие гаснет.
			if [ -n "$_REG_FLAT" ]; then
				_sh_noreg=""
				for _sh_p in $(printf '%s\n' "$_REG_FLAT" | awk 'NF{print $1}'); do
					uci -q get "5gmodem.m_$(printf '%s' "$_sh_p" | sed 's/[^A-Za-z0-9]/_/g')" >/dev/null 2>&1 \
						|| { _sh_noreg=1; break; }
				done
				if [ -n "$_sh_noreg" ]; then
					_sh_f=/tmp/5gmodem_sw_autoreg
					_sh_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
					_sh_last=$(cat "$_sh_f" 2>/dev/null)
					case "$_sh_last" in ''|*[!0-9]*) _sh_last=0 ;; esac
					if [ "$((_sh_now - _sh_last))" -ge 120 ]; then
						printf '%s' "$_sh_now" > "$_sh_f" 2>/dev/null
						"$RES/modemswitch.sh" autosetup >/dev/null 2>&1
					fi
				elif [ -z "$(uci -q get "5gmodem.@5gmodem[0].active_modem")" ]; then
					"$RES/modemswitch.sh" resolve >/dev/null 2>&1
				fi
			fi
			check_once
			# Освежение и МЕЖДУ обязанностями: фаза обязанностей длится 10-20 c,
			# и без этих вызовов снимок успевал протухнуть - половина тиков
			# страницы снова собирала сама (замер 06.08.2026: тики 1.9-2.4 c
			# через один). Сам вызов дешёв: свежий снимок - мгновенный выход.
			_page_refresh
			# Подогрев ПОСЛЕ проверки сессии, а не вместо: восстановление связи
			# важнее тёплой карточки, и порт (если он один) достанется сначала ей.
			warm_snapshots
			_page_refresh
			# Сторож интернета - последним: он ходит в СЕТЬ (ping), а не в порт,
			# и с проверкой сессии за AT-порт не конкурирует. Включён ли он и не
			# рано ли для круга - решает сам (enabled + свой rate-limit).
			"$RES/health.sh" tick >/dev/null 2>&1
			_page_refresh
			# Ряды статистики - следом за сторожем: он только что обновил
			# состояния линков, из которых берётся RTT. Свои пробы не делаем.
			"$RES/stats.sh" tick >/dev/null 2>&1
			# ДИОДЫ УСЛОВНЫХ КНОПОК - ПОД ФАКТИЧЕСКОЕ СОСТОЯНИЕ СЕРВИСА.
			#
			# Их выставляет обработчик нажатия и init при загрузке, но сбить их
			# может кто угодно: системная служба диодов гасит ВСЕ настроенные
			# при любой правке uci system (`led reload`), а сам сервис человек
			# может остановить из LuCI - тогда диод врал бы до следующего
			# нажатия. Живой стенд 07.08.2026: ssclash работает, оба диода
			# тёмные. Круг дешёвый (чтение uci + пара sysfs) и идемпотентный;
			# ветка целиком пропускается, если условных кнопок нет.
			if uci -q show 5gmodem 2>/dev/null | grep -q "\.ct_[a-z]*='conditional'"; then
				_sw_run 10 "$RES/buttons.sh" syncleds >/dev/null 2>&1
			fi
			# СТРАХОВКА МГНОВЕННОГО СОХРАНЕНИЯ: staged-дельта 5gmodem без
			# commit. Страница Настроек стейджит правку мгновенно (и она сразу
			# видна всем - libuci подхватывает дельту из общего /tmp/.uci), а
			# commit уезжает отдельным exec через rpcd - при занятом rpcd он
			# стоит в очереди, и уход со страницы его обрывает. Правка при этом
			# ЖИВЁТ до перезагрузки, а после неё tmpfs-дельта исчезает - «после
			# ребута настройки слетели» (живой случай ZBT-Z8102AX 18.08.2026:
			# хост пинга и сервер спидтеста возвращались к умолчаниям). Дельту,
			# не менявшуюся два круга подряд, дозакоммичиваем здесь: это ровно
			# то состояние, которое пользователь уже видит и считает
			# сохранённым; своих правок 5gmodem сторож не стейджит никогда.
			_ucd_l=$(uci -q changes 5gmodem 2>/dev/null)
			if [ -n "$_ucd_l" ]; then
				_ucd=$(printf '%s' "$_ucd_l" | md5sum | cut -d' ' -f1)
				if [ "$(cat /tmp/5gmodem_ucidelta 2>/dev/null)" = "$_ucd" ]; then
					uci -q commit 5gmodem 2>/dev/null && \
						_log "committed a stale staged 5gmodem delta (the settings page could not finish its own commit)"
					rm -f /tmp/5gmodem_ucidelta
				else
					printf '%s' "$_ucd" > /tmp/5gmodem_ucidelta
				fi
			else
				rm -f /tmp/5gmodem_ucidelta
			fi
			# Пересылка новых SMS в Telegram - последней: она ходит в СЕТЬ и в
			# AT-порт за списком сообщений, поэтому пусть сначала отработают
			# проверка сессии и метрики. Свой предохранитель по времени внутри.
			"$RES/tgnotify.sh" tick >/dev/null 2>&1
			# Зеркало непрочитанных входящих для ВНЕШНИХ программ: один JSON в
			# /tmp, читается кем угодно (уведомления и т.п.). Не push - файл
			# обновляется этим циклом, но НЕ каждый круг: newdump ходит в AT-порт
			# за списком, поэтому не чаще раза в 60 c (мгновенность тут не нужна).
			# Пишем атомарно (.tmp + mv).
			_smw_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
			_smw_prev=$(cat /tmp/5gmodem_sms_new.stamp 2>/dev/null)
			case "$_smw_prev" in ''|*[!0-9]*) _smw_prev=0 ;; esac
			if [ "$((_smw_now - _smw_prev))" -ge 60 ]; then
				printf '%s' "$_smw_now" > /tmp/5gmodem_sms_new.stamp 2>/dev/null
				"$RES/smsbridge.sh" newdump > /tmp/5gmodem_sms_new.json.tmp 2>/dev/null \
					&& mv /tmp/5gmodem_sms_new.json.tmp /tmp/5gmodem_sms_new.json 2>/dev/null
			fi
			# КОМАНДЫ ПО SMS - строго ПОСЛЕ бота и ДО слива. Порядок важен:
			# слив удаляет из модема только то, что уже обработано и ботом, и
			# командами, - иначе сообщение с командой исчезло бы, ни разу не
			# выполнившись. Выключено - выходит на первой строке.
			"$RES/smscmd.sh" run >/dev/null 2>&1
			# СЛИВ В ПАМЯТЬ РОУТЕРА. Здесь же и последний шаг разбора входящих:
			# перенести в архив и освободить слоты модема (у FM350 их всего
			# десять - см. _arch_purge). Выключено - выходит на первой строке.
			"$RES/smsbridge.sh" archive-run >/dev/null 2>&1
			# ОСТАЛЬНЫЕ МОДЕМЫ - ТОЖЕ, но раз в пять минут. Слив ходил только к
			# активному, а сообщения приходят на каждую SIM: у человека с двумя
			# модемами ящик неактивного заполнялся до отказа при включённой
			# галочке. Бот в Telegram обходит все модемы давно (SMS_MODEM=<путь>),
			# слив теперь тоже. Реже, чем активного: каждый обход - это AT-запрос
			# списка сообщений в чужой порт, а круг сторожа тут всего полминуты.
			_ar_now=$(cut -d. -f1 /proc/uptime 2>/dev/null)
			_ar_prev=$(cat /tmp/5gmodem_arch_all.stamp 2>/dev/null)
			case "$_ar_prev" in ''|*[!0-9]*) _ar_prev=0 ;; esac
			if [ "$((_ar_now - _ar_prev))" -ge 300 ]; then
				printf '%s' "$_ar_now" > /tmp/5gmodem_arch_all.stamp 2>/dev/null
				_ar_act=$(uci -q get 5gmodem.@5gmodem[0].active_modem)
				_ar_list=$("$RES/listmodems.sh" 2>/dev/null)
				for _ar_p in $("$RES/registry.sh" paths 2>/dev/null); do
					[ "$_ar_p" = "$_ar_act" ] && continue
					# Нет ни AT-порта, ни канала управления - читать нечем.
					printf '%s' "$_ar_list" \
						| jsonfilter -e "@[@.path=\"$_ar_p\"].tty[0]" \
						             -e "@[@.path=\"$_ar_p\"].wdm[0]" 2>/dev/null \
						| grep -q . || continue
					( export SMS_MODEM="$_ar_p"
					  _sw_run 45 "$RES/smsbridge.sh" archive-run ) >/dev/null 2>&1
				done
			fi
			# Досылка отложенных исходящих: одно сообщение за круг, под общей
			# очередью к порту. Пусто - выходит мгновенно.
			"$RES/smsbridge.sh" queue-run >/dev/null 2>&1
			# Телеметрия для умного дома/внешних дисплеев: плоский JSON из УЖЕ
			# СОБРАННОГО снимка метрик (ни одного запроса к модему) + MQTT,
			# если настроен брокер. Дешёвый шаг, выключается tele.enabled=0.
			"$RES/telemetry.sh" tick >/dev/null 2>&1
		done
		;;
esac
