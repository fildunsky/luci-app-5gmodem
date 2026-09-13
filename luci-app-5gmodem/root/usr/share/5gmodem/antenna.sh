#!/bin/sh
#
# Переключатель антенн корпуса Notion R281 / Yota C300-1 (MT7621).
#
# Логика взята из стокового драйвера antenna-gpio.ko (OpenWrt 15, ядро 3.10):
# он пишет прямо в регистры GPIO банка 0, а мы делаем то же через sysfs.
#   GPIO11 - цепь 1: 1 = внешняя антенна, 0 = внутренняя
#   GPIO9  - цепь 2: 0 = внешняя антенна, 1 = внутренняя
#   GPIO14 - датчик цепи 1, GPIO12 - датчик цепи 2: 0 = антенна подключена
# Режимы драйвера: internal, external, auto (каждая цепь на внешнюю, если её
# датчик видит антенну), mix (цепь 1 как в auto, цепь 2 всегда внутренняя).
# Драйвер пересчитывал auto/mix по таймеру - здесь это цикл run.
#
# Датчик срабатывает только от антенны, замыкающей разъём на землю по
# постоянному току; пассивная антенна без такой цепи остаётся «не видна».
#
# ТОЛЬКО ЭТА ПЛАТА. На любой другой те же номера ножек - что угодно, от
# светодиода до сброса модема, поэтому без точного board_name и метки
# контроллера скрипт GPIO не трогает вовсе.
#
# Usage: antenna.sh detect|status|set <mode>|apply|run

CFG=5gmodem
INTERVAL=3
SYSGPIO="${ANT_SYSGPIO:-/sys/class/gpio}"
BOARD_FILE="${ANT_BOARD_FILE:-/tmp/sysinfo/board_name}"

board_ok() {
	case "$(cat "$BOARD_FILE" 2>/dev/null)" in
		notion,r281) return 0 ;;
	esac
	return 1
}

# Номер ножки считаем от базы банка, а не зашиваем 521: база зависит от ядра
# и порядка регистрации контроллеров.
gpio_base() {
	for _gb_c in "$SYSGPIO"/gpiochip*; do
		[ -r "$_gb_c/label" ] || continue
		case "$(cat "$_gb_c/label" 2>/dev/null)" in
			1e000600.gpio-bank0)
				_gb_b=$(cat "$_gb_c/base" 2>/dev/null)
				case "$_gb_b" in ''|*[!0-9]*) return 1 ;; esac
				echo "$_gb_b"
				return 0 ;;
		esac
	done
	return 1
}

available() {
	board_ok || return 1
	BASE=$(gpio_base) || return 1
	G_C1=$((BASE + 11)); G_C2=$((BASE + 9))
	G_D1=$((BASE + 14)); G_D2=$((BASE + 12))
	return 0
}

gpio_export() {
	[ -d "$SYSGPIO/gpio$1" ] || echo "$1" > "$SYSGPIO/export" 2>/dev/null
	[ -d "$SYSGPIO/gpio$1" ]
}

# Выход ставим записью high/low в direction: так уровень и направление
# меняются одной операцией, без короткого нуля на ножке.
gpio_out() {
	gpio_export "$1" || return 1
	if [ "$(cat "$SYSGPIO/gpio$1/direction" 2>/dev/null)" = "out" ]; then
		[ "$(cat "$SYSGPIO/gpio$1/value" 2>/dev/null)" = "$2" ] && return 0
		echo "$2" > "$SYSGPIO/gpio$1/value" 2>/dev/null
	else
		[ "$2" = 1 ] && _go_l=high || _go_l=low
		echo "$_go_l" > "$SYSGPIO/gpio$1/direction" 2>/dev/null
	fi
}

gpio_get() {
	cat "$SYSGPIO/gpio$1/value" 2>/dev/null
}

# Датчик: 0 - антенна есть, 1 - нет, пусто - прочитать нельзя (ножка занята
# или не переведена в GPIO в DTS этой сборки).
detect_read() {
	gpio_export "$1" || return 0
	[ "$(cat "$SYSGPIO/gpio$1/direction" 2>/dev/null)" = "in" ] \
		|| echo in > "$SYSGPIO/gpio$1/direction" 2>/dev/null
	[ "$(cat "$SYSGPIO/gpio$1/direction" 2>/dev/null)" = "in" ] || return 0
	case "$(gpio_get "$1")" in
		0) echo 0 ;;
		1) echo 1 ;;
	esac
}

cur_mode() {
	_cm=$(uci -q get "$CFG.@5gmodem[0].antenna_mode")
	case "$_cm" in internal|external|auto|mix) echo "$_cm" ;; *) echo internal ;; esac
}

apply_mode() {
	_am_c1=0; _am_c2=1
	case "$1" in
		external) _am_c1=1; _am_c2=0 ;;
		auto)
			[ "$(detect_read "$G_D1")" = 0 ] && _am_c1=1
			[ "$(detect_read "$G_D2")" = 0 ] && _am_c2=0 ;;
		mix)
			[ "$(detect_read "$G_D1")" = 0 ] && _am_c1=1 ;;
	esac
	_am_o1=$(gpio_get "$G_C1"); _am_o2=$(gpio_get "$G_C2")
	gpio_out "$G_C1" "$_am_c1"
	gpio_out "$G_C2" "$_am_c2"
	if [ "$_am_o1" != "$_am_c1" ] || [ "$_am_o2" != "$_am_c2" ]; then
		logger -t 5gmodem "antenna: mode $1, chain 1 $(chain_name 1 "$_am_c1"), chain 2 $(chain_name 2 "$_am_c2")"
	fi
}

chain_name() {
	case "$1:$2" in
		1:1|2:0) echo external ;;
		1:0|2:1) echo internal ;;
		*) echo unknown ;;
	esac
}

det_name() {
	case "$1" in
		0) echo connected ;;
		1) echo absent ;;
		*) echo unknown ;;
	esac
}

status_json() {
	printf '{"available":1,"mode":"%s","chain1":"%s","chain2":"%s","detect1":"%s","detect2":"%s"}\n' \
		"$(cur_mode)" \
		"$(chain_name 1 "$(gpio_get "$G_C1")")" "$(chain_name 2 "$(gpio_get "$G_C2")")" \
		"$(det_name "$(detect_read "$G_D1")")" "$(det_name "$(detect_read "$G_D2")")"
}

case "$1" in
detect)
	if available; then
		printf '{"available":1}\n'
	else
		printf '{"available":0}\n'
	fi
	;;
status)
	available || { printf '{"available":0}\n'; exit 0; }
	status_json
	;;
set)
	available || { printf '{"available":0}\n'; exit 0; }
	case "$2" in
		internal|external|auto|mix) ;;
		*) printf '{"error":"bad mode"}\n'; exit 0 ;;
	esac
	uci -q set "$CFG.@5gmodem[0].antenna_mode=$2"
	uci -q commit "$CFG"
	/etc/init.d/5gmodem-antenna enable >/dev/null 2>&1
	/etc/init.d/5gmodem-antenna restart >/dev/null 2>&1
	available && apply_mode "$2"
	status_json
	;;
apply)
	available || exit 0
	apply_mode "$(cur_mode)"
	;;
run)
	available || exit 0
	_r_mode=$(cur_mode)
	case "$_r_mode" in auto|mix) ;; *) apply_mode "$_r_mode"; exit 0 ;; esac
	while :; do
		apply_mode "$_r_mode"
		sleep "$INTERVAL"
	done
	;;
*)
	echo "usage: $0 detect|status|set internal|external|auto|mix|apply|run" >&2
	exit 1
	;;
esac
exit 0
