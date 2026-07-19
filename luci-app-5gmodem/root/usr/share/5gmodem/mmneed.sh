#!/bin/sh
#
# Нужен ли сейчас ModemManager - и привести службу в соответствие.
#
# ЗАЧЕМ. Раньше решение принималось ТОЛЬКО по конфигу: есть интерфейс с
# proto=modemmanager - значит MM нужен. Про то, подключён ли сам модем, никто не
# спрашивал. В итоге MM работал ради модема, которого нет на шине.
#
# Это не безобидно. MM при старте хватает ВСЕ модемы подряд, включая те, что
# помечены mm_exclude=1: наблюдалось вживую - MM поднялся ради отключённого
# Compal и по дороге выключил работающий FM350 ("disabled modem"), связь
# пропала, а причина ниоткуда не видна. Запрет (mm-inhibit.sh) ложится следом,
# но окно между стартом MM и запретом остаётся.
#
# Поэтому: MM работает, только если ХОТЯ БЫ ОДИН ПРИСУТСТВУЮЩИЙ модем им
# управляется. Ушёл последний такой модем - службу останавливаем; вернулся -
# поднимаем обратно.
#
# Профиль отсутствующего модема при этом НЕ ТРОГАЕМ: в нём лежит осознанный
# выбор пользователя (протокол, APN), и стирать его из-за того, что модем вынули
# на день, нельзя.

RES=/usr/share/5gmodem
CFG=5gmodem

# Путь модема, которому принадлежит интерфейс $1 (по профилям). Пусто - неизвестно.
_path_for_iface() {
	uci -q show "$CFG" 2>/dev/null \
		| sed -n "s/^$CFG\.\(m_[^.]*\)\.network='\?$1'\?\$/\1/p" \
		| while read -r _s; do uci -q get "$CFG.$_s.path"; done | head -1
}

# 0 - MM нужен, 1 - не нужен.
mm_needed() {
	_present=$("$RES/listmodems.sh" 2>/dev/null | jsonfilter -e '@[*].path' 2>/dev/null | tr '\n' ' ')
	for _if in $(uci -q show network 2>/dev/null \
			| sed -n "s/^network\.\([^.]*\)\.proto='\?modemmanager'\?\$/\1/p"); do
		# 1) Прямой признак - устройство интерфейса на месте. У proto=modemmanager
		#    это sysfs-путь модема, так что проверка точная и не зависит от того,
		#    заведён ли профиль.
		_dev=$(uci -q get "network.$_if.device")
		case "$_dev" in
			/sys/*) [ -e "$_dev" ] && return 0; continue ;;
		esac
		# 2) Устройство задано иначе (или не задано) - спрашиваем профиль.
		_p=$(_path_for_iface "$_if")
		if [ -n "$_p" ]; then
			case " $_present " in *" $_p "*) return 0 ;; esac
			continue
		fi
		# 3) Сопоставить не удалось. Считаем, что нужен: молча выключить MM у
		#    интерфейса, про который мы ничего не знаем, - худший из вариантов.
		return 0
	done
	return 1
}

_running() { [ "$(ps w 2>/dev/null | grep -c '[M]odemManager --')" -gt 0 ]; }

case "$1" in
	check)
		_n=0; mm_needed && _n=1
		_r=0; _running && _r=1
		printf '{"needed":%d,"running":%d}\n' "$_n" "$_r"
		;;
	apply|"")
		if mm_needed; then
			# Запускаем, но НЕ перезапускаем работающий: restart роняет MM на
			# минуту-две (гонка за имя в D-Bus) и рвёт связь у тех, кем он правит.
			if ! _running; then
				/etc/init.d/modemmanager enable >/dev/null 2>&1
				/etc/init.d/modemmanager start >/dev/null 2>&1
				logger -t 5gmodem "ModemManager запущен: им управляется подключённый модем"
			fi
		else
			if _running; then
				/etc/init.d/modemmanager stop >/dev/null 2>&1
				/etc/init.d/modemmanager disable >/dev/null 2>&1
				logger -t 5gmodem "ModemManager остановлен: ни один подключённый модем им не управляется"
			fi
		fi
		;;
esac
exit 0
