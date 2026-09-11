# ПОРТЫ, В КОТОРЫЕ AT СЛАТЬ НЕЛЬЗЯ.
#
# У части модемов среди tty есть служебный канал, который не просто молчит на
# AT, а падает от него вместе с модемом. Перебор портов («кто ответит на AT»)
# для такого модема смертелен: каждая проба перезагружает модуль, после
# переэнумерации проба повторяется - и так по кругу.
#
# MikroTik R11e-LTE (2cd2:0001, Marvell PXA1802): ttyACM0 (интерфейс 02) -
# двоичный журнал прошивки, AT-порт - ttyACM1 (интерфейс 04). Живой отчёт
# 11.09.2026: прото дозвона выбирал ttyACM0 (он первый и не совпадает с портом
# метрик), и модем уходил в перезагрузку через ~25 c после каждого подъёма
# интерфейса; с остановленным интерфейсом - ни одного отвала за две минуты.
#
# Ключ - vid:pid:номер интерфейса, а не имя узла: нумерация ttyACM сдвигается,
# когда модемов несколько.
noat_iface() {   # $1 - vid, $2 - pid, $3 - bInterfaceNumber; 0 = запретный
	case "$1:$2:$3" in
		2cd2:0001:02) return 0 ;;
	esac
	return 1
}

tty_no_at() {   # $1 - /dev/ttyX или ttyX; 0 = порт запретный
	_na_p=$(readlink -f "/sys/class/tty/${1##*/}/device" 2>/dev/null) || return 1
	[ -r "$_na_p/bInterfaceNumber" ] || _na_p=${_na_p%/*}
	[ -r "$_na_p/bInterfaceNumber" ] || return 1
	_na_d=${_na_p%/*}
	noat_iface "$(cat "$_na_d/idVendor" 2>/dev/null)" "$(cat "$_na_d/idProduct" 2>/dev/null)" \
		"$(cat "$_na_p/bInterfaceNumber" 2>/dev/null)"
}

# ОТВЯЗАТЬ ДРАЙВЕР ОТ ЗАПРЕТНОГО ИНТЕРФЕЙСА. Сторожа в наших пробах закрывают
# только наш код, а в тот же порт ходят и посторонние пакеты (3ginfo-lite,
# modemband, sms-tool-js): каждый из них так же перебирает ttyACM* и так же
# роняет модем. Без драйвера узла /dev/ttyACMx нет вовсе - писать некуда никому.
# Модему это ничем не грозит: журнал, который никто не читает, он и так
# отбрасывает (стенд пользователя простоял с закрытым ttyACM0 без единого отвала).
noat_unbind_iface() {   # $1 - каталог интерфейса в sysfs (или порта usb-serial внутри него)
	_nu_i=$1
	[ -r "$_nu_i/bInterfaceNumber" ] || _nu_i=${_nu_i%/*}
	[ -e "$_nu_i/driver" ] && [ -r "$_nu_i/bInterfaceNumber" ] || return 0
	_nu_d=${_nu_i%/*}
	[ -r "$_nu_d/idVendor" ] || return 0
	noat_iface "$(cat "$_nu_d/idVendor" 2>/dev/null)" "$(cat "$_nu_d/idProduct" 2>/dev/null)" \
		"$(cat "$_nu_i/bInterfaceNumber" 2>/dev/null)" || return 0
	echo "${_nu_i##*/}" > "$_nu_i/driver/unbind" 2>/dev/null \
		&& logger -t 5gmodem "noat: driver unbound from ${_nu_i##*/} - a service port, AT resets this modem"
	return 0
}

noat_unbind() {
	for _nu_t in /sys/class/tty/ttyACM* /sys/class/tty/ttyUSB*; do
		[ -e "$_nu_t" ] || continue
		noat_unbind_iface "$(readlink -f "$_nu_t/device" 2>/dev/null)"
	done
}
