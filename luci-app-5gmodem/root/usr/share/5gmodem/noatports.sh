noat_iface() {
	case "$1:$2:$3" in
		2cd2:0001:02) return 0 ;;
		1286:4e31:*) return 0 ;;
	esac
	return 1
}

tty_no_at() {
	case "${1##*/}" in
		wwan*at*)
			_na_w=$(readlink -f "/sys/class/wwan/${1##*/}" 2>/dev/null)
			case "$_na_w" in */*.remoteproc/*) ;; *) return 1 ;; esac
			_na_w=${_na_w%%.remoteproc/*}.remoteproc
			[ "$(uci -q get "5gmodem.m_$(echo "${_na_w##*/}" | sed 's/[^A-Za-z0-9]/_/g').mm_at" 2>/dev/null)" = 1 ] && return 1
			pidof ModemManager >/dev/null 2>&1
			return $? ;;
	esac
	_na_p=$(readlink -f "/sys/class/tty/${1##*/}/device" 2>/dev/null) || return 1
	[ -r "$_na_p/bInterfaceNumber" ] || _na_p=${_na_p%/*}
	[ -r "$_na_p/bInterfaceNumber" ] || return 1
	_na_d=${_na_p%/*}
	# read, not cat: this runs before every AT probe
	_na_v=""; _na_pr=""; _na_n=""; _na_pt=""
	read -r _na_v 2>/dev/null < "$_na_d/idVendor"
	read -r _na_pr 2>/dev/null < "$_na_d/idProduct"
	if [ "$_na_v:$_na_pr" = 3466:3301 ]; then
		read -r _na_pt 2>/dev/null < "$_na_p/bInterfaceProtocol"
		[ "$_na_pt" != 12 ] && return 0
	fi
	read -r _na_n 2>/dev/null < "$_na_p/bInterfaceNumber"
	noat_iface "$_na_v" "$_na_pr" "$_na_n"
}

noat_unbind_iface() {
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
