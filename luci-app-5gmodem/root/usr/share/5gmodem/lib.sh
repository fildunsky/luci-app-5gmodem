[ -d /tmp/5gmodem ] || mkdir -p /tmp/5gmodem 2>/dev/null

_proto_cls() {
	case "$1" in
		wdm)     _PCL="mbim|mbimp|qmi|qmiraw" ;;
		wdmdev)  _PCL="mbim|mbimp|qmi|qmiraw|ncm" ;;
		direct)  _PCL="qmi|qmiraw|mbim" ;;
		uqmi)    _PCL="qmi|qmiraw" ;;
		proxy)   _PCL="mbimp" ;;
		mm)      _PCL="modemmanager|mbimp" ;;
		nomm)    _PCL="qmi|qmiraw|mbim|xmm|ncm|atc|3g|wwan|ppp|fibocom" ;;
		at)      _PCL="fibocom|atc|xmm|ncm|3g|wwan" ;;
		serial)  _PCL="xmm|ncm|atc|3g|wwan|ppp" ;;
		dialtty) _PCL="xmm|atc" ;;
		own)     _PCL="fibocom|qmiraw|mbimp" ;;
		modem)   _PCL="mbim|mbimp|qmi|qmiraw|modemmanager|fibocom|atc|xmm|ncm|3g|wwan|ppp" ;;
		*)       _PCL="" ;;
	esac
}

proto_in() {
	[ -n "$2" ] || return 1
	_proto_cls "$1"
	case "|$_PCL|" in
		*"|$2|"*) return 0 ;;
	esac
	return 1
}

proto_re() {
	_proto_cls "$1"
	printf '%s\n' "$_PCL"
}

serial_valid() {
	_sv="$1"
	[ -n "$_sv" ] || return 1
	case "$_sv" in
		-|0|none|None|N/A) return 1 ;;
		0123456789ABCDEF|0123456789abcdef|2e6172c9) return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
	esac
	[ "${#_sv}" -ge 6 ] || return 1
	_sv1=$(printf '%s' "$_sv" | cut -c1)
	case "$_sv" in
		*[!"$_sv1"]*) ;;
		*) return 1 ;;
	esac
	return 0
}

stub_serial_known() {
	[ -n "$1" ] || return 1
	case " $(uci -q get "5gmodem.@5gmodem[0].stub_serials" 2>/dev/null) " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

stub_serial_add() {
	[ -n "$1" ] || return 0
	stub_serial_known "$1" && return 0
	_ssa_l=$(uci -q get "5gmodem.@5gmodem[0].stub_serials" 2>/dev/null)
	uci -q set "5gmodem.@5gmodem[0].stub_serials=${_ssa_l:+$_ssa_l }$1"
	uci -q show 5gmodem 2>/dev/null | grep -F ".serial='$1'" \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.serial=.*/\1/p" \
		| while read -r _ssa_s; do
			[ -n "$_ssa_s" ] && uci -q delete "5gmodem.$_ssa_s.serial"
		done
	uci -q commit 5gmodem
	logger -t 5gmodem "serial $1 is a batch value (seen on two devices) - no longer used as a modem identity"
	return 0
}

serial_of() {
	_so_s=$(cat "$1/serial" 2>/dev/null | tr -d '\r\n')
	serial_valid "$_so_s" || { printf ''; return 1; }
	stub_serial_known "$_so_s" && { printf ''; return 1; }
	_so_n=0
	for _so_d in /sys/bus/usb/devices/*; do
		[ -f "$_so_d/serial" ] || continue
		[ "$(cat "$_so_d/serial" 2>/dev/null | tr -d '\r\n')" = "$_so_s" ] && _so_n=$((_so_n + 1))
	done
	[ "$_so_n" = 1 ] || { stub_serial_add "$_so_s"; printf ''; return 1; }
	printf '%s' "$_so_s"
}

usb_path_present() {
	[ -n "$1" ] || return 1
	[ -e "/sys/bus/usb/devices/$1" ] || [ -e "/sys/bus/pci/devices/${1##*/}" ] || soc_modem_node "$1" >/dev/null
}

mtk_soc_modem() {
	[ -d /sys/kernel/ccci ] || return 1
	[ -S /dev/socket/rild-atci ] || { [ ! -d /dev/socket ] && [ -c /dev/ttyC0 ]; }
}

soc_modem_node() {
	if [ "$1" = ccci ]; then
		mtk_soc_modem || return 1
		echo /sys/kernel/ccci
		return 0
	fi
	_smn_d="/sys/bus/platform/devices/${1##*/}"
	[ -n "$1" ] && [ -d "$_smn_d/remoteproc" ] || return 1
	readlink -f "$_smn_d"
}

soc_modem_vidpid() {
	if mtk_soc_modem; then
		_smv_m=$(tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null | sed -n 's/^mediatek,[mM][tT]\([0-9]\{4\}\)$/\1/p' | head -1)
		[ -n "$_smv_m" ] || _smv_m=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null | tr -cd '0-9' | cut -c1-4)
		[ -n "$_smv_m" ] || _smv_m=$(sed -n 's/^Hardware[^:]*: *[A-Za-z]*//p' /proc/cpuinfo 2>/dev/null | tr -cd '0-9' | cut -c1-4)
		printf '0e8d:%s\n' "${_smv_m:-0000}"
		return
	fi
	_smv_m=$(tr -cd '0-9' < /sys/devices/soc0/machine 2>/dev/null | cut -c1-4)
	printf '05c6:%s\n' "${_smv_m:-0000}"
}

soc_modem_model() {
	if mtk_soc_modem; then
		_smm_m=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null)
		[ -n "$_smm_m" ] || _smm_m=$(sed -n 's/^Hardware[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -1)
		printf 'MediaTek %s\n' "${_smm_m:-SoC}"
		return
	fi
	_smm_m=$(tr -d '\000' < /proc/device-tree/model 2>/dev/null | sed 's/ *4G Modem Stick$//; s/ *Modem Stick$//; s/ *4G Pocket Router$//')
	[ -n "$_smm_m" ] || _smm_m=$(cat /sys/devices/soc0/machine 2>/dev/null)
	printf '%s\n' "$_smm_m"
}

is_iphone() {
	_ii_d="/sys/bus/usb/devices/$1"
	[ -n "$1" ] && [ -f "$_ii_d/idVendor" ] || return 1
	read -r _ii_v < "$_ii_d/idVendor"
	[ "$_ii_v" = 05ac ] || return 1
	_ii_p=""
	[ -f "$_ii_d/idProduct" ] && read -r _ii_p < "$_ii_d/idProduct"
	case "$_ii_p" in 129[0-9a-f]|12a[0-9a-f]) return 0 ;; esac
	for _ii_i in "$_ii_d"/*:*/driver; do
		[ -e "$_ii_i" ] || continue
		case "$(readlink "$_ii_i" 2>/dev/null)" in */ipheth) return 0 ;; esac
	done
	return 1
}

iphone_netdev() {
	_in_f=""
	for _in_n in /sys/bus/usb/devices/"$1":*/net/*; do
		[ -e "$_in_n" ] || continue
		case "$(readlink "${_in_n%/net/*}/driver" 2>/dev/null)" in
			*/ipheth) echo "${_in_n##*/}"; return 0 ;;
		esac
		[ -n "$_in_f" ] || _in_f="${_in_n##*/}"
	done
	[ -n "$_in_f" ] || return 1
	echo "$_in_f"
}

usbmuxd_installed() {
	[ -x /usr/sbin/usbmuxd ] || command -v usbmuxd >/dev/null 2>&1
}

ipheth_available() {
	[ -d /sys/module/ipheth ] && return 0
	for _ia_k in /lib/modules/*/ipheth.ko; do
		[ -e "$_ia_k" ] && return 0
	done
	return 1
}

usbmuxd_ensure() {
	usbmuxd_installed || return 1
	pidof usbmuxd >/dev/null 2>&1 && return 0
	if [ -x /etc/init.d/usbmuxd ]; then
		/etc/init.d/usbmuxd start >/dev/null 2>&1
	else
		( exec 1000>&- 6>&- 7>&- 8>&- 9>&-; usbmuxd >/dev/null 2>&1 ) </dev/null &
	fi
	logger -t 5gmodem "iphone: usbmuxd was not running - started"
	return 0
}

iphone_paired() {
	[ -f "/sys/bus/usb/devices/$1/serial" ] || return 1
	read -r _ipp_s < "/sys/bus/usb/devices/$1/serial"
	for _ipp_f in /etc/lockdown/*.plist /var/lib/lockdown/*.plist; do
		[ -e "$_ipp_f" ] || continue
		_ipp_b="${_ipp_f##*/}"; _ipp_b="${_ipp_b%.plist}"
		[ "$(echo "$_ipp_b" | tr -d '-' | tr 'a-f' 'A-F')" = "$(echo "$_ipp_s" | tr -d '-' | tr 'a-f' 'A-F')" ] && return 0
	done
	return 1
}

iphone_state() {
	usbmuxd_installed || { echo no_usbmuxd; return 0; }
	ipheth_available || { echo no_driver; return 0; }
	_is_n=$(iphone_netdev "$1")
	_is_c=""
	if [ -n "$_is_n" ]; then
		_is_c=$(cat "/sys/class/net/$_is_n/carrier" 2>/dev/null)
		[ "$_is_c" = 1 ] && { echo ready; return 0; }
	fi
	iphone_paired "$1" || { echo need_trust; return 0; }
	echo no_hotspot
}

android_vid() {
	case "$1" in
		04e8|18d1|2717|22d9|2a70|2d95|0bb4|1004|22b8|17ef|0b05|0fce|054c|2a45|2ae5|2e04|2e17|\
		1ebf|2b4c|2b0e|2a96|1bbb|109b|0482|04dd|2970|1d9c|2a47|3360|271d|2c3f|10a9|1f53|2116|\
		24e3|2340|201e|1949|2a48|0502|339b|0a9d|04b7) return 0 ;;
	esac
	return 1
}

known_modem_path() {
	_km_d="/sys/bus/usb/devices/$1"
	[ -n "$1" ] && [ -f "$_km_d/idVendor" ] || return 1
	read -r _km_v < "$_km_d/idVendor"
	_km_p=""
	[ -f "$_km_d/idProduct" ] && read -r _km_p < "$_km_d/idProduct"
	[ -e "/usr/share/5gmodem/modem/usb/$_km_v$_km_p" ] && return 0
	case "$_km_v" in
		1e0e|2c7c|2cb7|1508|1bc7|1199|0f3d|413c|03f0|0489|105b|8087|1e2d|2dee|216f|2cd2|1286|1690|2020|33f8|1410|0af0|1c9e) return 0 ;;
	esac
	return 1
}

usb_gadget_vid() {
	case "$1" in 0525|1d6b) return 0 ;; esac
	return 1
}

tether_cdc_vid() {
	usb_gadget_vid "$1" && return 0
	case "$1" in 17ef|0b05|0502|1949|04b7) return 1 ;; esac
	android_vid "$1"
}

tether_os() {
	if is_iphone "$1"; then echo iphone; return 0; fi
	if [ -n "$1" ] && [ -f "/sys/bus/usb/devices/$1/idVendor" ]; then
		read -r _to_v < "/sys/bus/usb/devices/$1/idVendor"
		if usb_gadget_vid "$_to_v"; then echo router
		elif android_vid "$_to_v"; then echo android; else echo phone; fi
		return 0
	fi
	_to_s=$(uci -q get "5gmodem.$(secname "$1").tether")
	[ -n "$_to_s" ] && { echo "$_to_s"; return 0; }
	echo phone
}

purge_path_caches() {
	[ -n "$1" ] || return 0
	_ppc_k=$(snap_key "$1" 2>/dev/null)
	_ppc_k2=$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')
	rm -f "/tmp/5gmodem/slots_$1" "/tmp/5gmodem/slots_$1.t" \
	      "/tmp/5gmodem/bands_$1" "/tmp/5gmodem/bands_$1.t" "/tmp/5gmodem/bands_$1.p" \
	      "/tmp/5gmodem/qmirecover_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)" \
	      "/tmp/5gmodem/autoapn_m_$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"* \
	      "/tmp/5gmodem/portok_$(snap_key "$1" 2>/dev/null)" 2>/dev/null
	[ -n "$_ppc_k" ] && rm -f \
		"/tmp/5gmodem/metrics_$_ppc_k.json" "/tmp/5gmodem/metrics_$_ppc_k.stamp" \
		"/tmp/5gmodem/hist_$_ppc_k" "/tmp/5gmodem/ambr_$_ppc_k" \
		"/tmp/5gmodem/slot_$_ppc_k" "/tmp/5gmodem/slot_$_ppc_k.t" \
		"/tmp/5gmodem/imei_none_$_ppc_k" \
		"/tmp/5gmodem/static_$_ppc_k"* "/tmp/5gmodem/qmi_$_ppc_k".* \
		"/tmp/5gmodem/atca_$_ppc_k" "/tmp/5gmodem/atca_$_ppc_k".* \
		"/tmp/5gmodem/hilink_metrics_$_ppc_k" "/tmp/5gmodem/hilink_metrics_$_ppc_k".* \
		"/tmp/5gmodem/atport_$_ppc_k" "/tmp/5gmodem/atport_$_ppc_k".neg 2>/dev/null
	[ -n "$_ppc_k2" ] && rm -f "/tmp/5gmodem/mmowns_$_ppc_k2" "/tmp/5gmodem/mmports_$_ppc_k2" 2>/dev/null
	[ -n "$_ppc_k2" ] && rm -f \
		"/tmp/5gmodem/metrics_$_ppc_k2.json" "/tmp/5gmodem/metrics_$_ppc_k2.stamp" \
		"/tmp/5gmodem/slot_$_ppc_k2" "/tmp/5gmodem/slot_$_ppc_k2.t" \
		"/tmp/5gmodem/imei_none_$_ppc_k2" \
		"/tmp/5gmodem/static_$_ppc_k2"* "/tmp/5gmodem/qmi_$_ppc_k2".* 2>/dev/null
	logger -t 5gmodem "caches for path $1 purged (a different modem is in the port)"
	return 0
}

utf8_fix() {
	LC_ALL=C awk '
		BEGIN { for (n = 1; n < 256; n++) o[sprintf("%c", n)] = n
			MK = sprintf("%c%cffff", 195, 191)     # junk marker: ÿ + "ffff"
			MKJ = sprintf("%cu00ffffff", 92) }     # same, JSON-escaped
		function cont(str, i,   b) { b = o[substr(str, i, 1)]; return (b >= 128 && b < 192) }
		function hx(s,   i, c, v, d) {
			v = 0
			for (i = 1; i <= length(s); i++) {
				d = index("0123456789abcdef", tolower(substr(s, i, 1))) - 1
				if (d < 0) return -1
				v = v * 16 + d
			}
			return v
		}
		{
			out = ""; i = 1; n = length($0)
			while (i <= n) {
				b = o[substr($0, i, 1)]
				if (b < 128)                       { out = out substr($0, i, 1); i += 1 }
				else if (b >= 194 && b <= 223 && i + 1 <= n && cont($0, i + 1)) { out = out substr($0, i, 2); i += 2 }
				else if (b >= 224 && b <= 239 && i + 2 <= n && cont($0, i + 1) && cont($0, i + 2)) { out = out substr($0, i, 3); i += 3 }
				else if (b >= 240 && b <= 244 && i + 3 <= n && cont($0, i + 1) && cont($0, i + 2) && cont($0, i + 3)) { out = out substr($0, i, 4); i += 4 }
				else { out = out sprintf("%c%c", 192 + int(b / 64), 128 + (b % 64)); i += 1 }
			}
			st = 1; p = index(substr(out, st), MK)
			while (p > 0) {
				ap = st + p - 1
				code = hx(substr(out, ap + 6, 2))
				if (code >= 128 && code <= 255) {
					out = substr(out, 1, ap - 1) sprintf("%c%c", 192 + int(code / 64), 128 + (code % 64)) substr(out, ap + 8)
					st = 1
				} else {
					st = ap + 6
				}
				p = index(substr(out, st), MK)
			}
			st = 1; p = index(substr(out, st), MKJ)
			while (p > 0) {
				ap = st + p - 1
				code = hx(substr(out, ap + 10, 2))
				if (code >= 128 && code <= 255) {
					out = substr(out, 1, ap - 1) sprintf("%cu00%02x", 92, code) substr(out, ap + 12)
					st = 1
				} else {
					st = ap + 10
				}
				p = index(substr(out, st), MKJ)
			}
			print out
		}
	'
}

note_foreign_uci() {
	_nf=$(uci changes "$1" 2>/dev/null | head -20)
	[ -n "$_nf" ] || return 0
	_nf_s="/tmp/5gmodem/foreign_uci.$1"
	_nf_h=$(printf '%s' "$_nf" | md5sum | cut -c1-32)
	[ "$(cat "$_nf_s" 2>/dev/null)" = "$_nf_h" ] && return 0
	mkdir -p /tmp/5gmodem 2>/dev/null
	printf '%s' "$_nf_h" > "$_nf_s" 2>/dev/null
	logger -t 5gmodem "$2: FOREIGN staged uci changes in $1 - committing them along: $(printf '%s' "$_nf" | tr '\n' '; ' | head -c 400)"
}

snap_key() {
	_sk=$(printf '%s\n' "$1" | tr -c 'A-Za-z0-9' '_')
	[ -n "$_sk" ] || _sk="none"
	printf '%s' "$_sk"
}

sms_fwd_info() {
	_sfh_s=m_$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')
	SFI_MODEL=$(uci -q get "5gmodem.$_sfh_s.model")
	[ -n "$SFI_MODEL" ] || SFI_MODEL=$(uci -q get "5gmodem.$_sfh_s.product")
	_sfh_j="/tmp/5gmodem/metrics_$(snap_key "$1").json"
	SFI_PHONE=$(jsonfilter -e '@.phone' 2>/dev/null < "$_sfh_j")
	SFI_OP=$(jsonfilter -e '@.operator_name' 2>/dev/null < "$_sfh_j")
	case "$SFI_OP" in -|--) SFI_OP="" ;; esac
	case "$SFI_PHONE" in +[0-9]*|[0-9]*) ;; *) SFI_PHONE="" ;; esac
	SFI_HOST=$(uci -q get system.@system[0].hostname)
}

sms_fwd_head() {
	sms_fwd_info "$1"
	_sfh_o="SMS"
	[ -n "$2" ] && _sfh_o="$_sfh_o $2"
	_sfh_t="$SFI_OP${SFI_OP:+${SFI_PHONE:+ }}$SFI_PHONE"
	if [ -n "$_sfh_t" ]; then
		[ -n "$2" ] && _sfh_o="$_sfh_o →"
		_sfh_o="$_sfh_o $_sfh_t"
	fi
	[ -n "$SFI_HOST" ] && _sfh_o="$_sfh_o · $SFI_HOST"
	[ -n "$SFI_MODEL" ] && _sfh_o="$_sfh_o ($SFI_MODEL)"
	printf '%s' "$_sfh_o"
}

uptime_s() {
	IFS=' ' read -r _us _ < /proc/uptime
	printf '%s\n' "${_us%%.*}"
}

bg_at_off() {
	_bao_p="${1:-$(uci -q get 5gmodem.@5gmodem[0].active_modem)}"
	[ -n "$_bao_p" ] || return 1
	[ "$(uci -q get "5gmodem.$(secname "$_bao_p").no_at" 2>/dev/null)" = "1" ]
}

_SN_IN=""; _SN_OUT=""
secname() {
	if [ -n "$1" ] && [ "$1" = "$_SN_IN" ]; then
		printf '%s\n' "$_SN_OUT"
		return
	fi
	_SN_IN="$1"
	_sn_rest="$1"; _sn_acc=""
	while [ -n "$_sn_rest" ]; do
		_sn_tail="${_sn_rest#?}"
		_sn_ch="${_sn_rest%"$_sn_tail"}"
		case "$_sn_ch" in
			[A-Za-z0-9]) _sn_acc="$_sn_acc$_sn_ch" ;;
			*) _sn_acc="${_sn_acc}_" ;;
		esac
		_sn_rest="$_sn_tail"
	done
	_SN_OUT="m_$_sn_acc"
	printf '%s\n' "$_SN_OUT"
}

_UCI_NL='
'

_uci_snap_get() {
	case "$1" in
		*"$_UCI_NL$2="*)
			_usv="${1#*"$_UCI_NL$2="}"
			_usv="${_usv%%"$_UCI_NL"*}"
			_usv="${_usv#\'}"
			printf '%s' "${_usv%\'}" ;;
	esac
}

_UCI5G_SNAP=""
uci5g_snapshot() { _UCI5G_SNAP="$_UCI_NL$(uci -q show 5gmodem 2>/dev/null)"; }
_uci5g_dump() {
	[ -n "$_UCI5G_SNAP" ] && { printf '%s\n' "$_UCI5G_SNAP"; return; }
	uci -q show 5gmodem 2>/dev/null
}
uci5g_get() {
	if [ -n "$_UCI5G_SNAP" ]; then
		_uci_snap_get "$_UCI5G_SNAP" "5gmodem.$1.$2"
		return
	fi
	uci -q get "5gmodem.$1.$2" 2>/dev/null
}

uci_sec_snap() {
	printf '%s%s' "$_UCI_NL" "$(uci -q show "$1.$2" 2>/dev/null)"
}
uci_sec_val() {
	_usv_p="$_UCI_NL$2.$3="
	case "$1" in
		*"$_usv_p"*)
			_usv_v="${1##*"$_usv_p"}"
			_usv_v="${_usv_v%%"$_UCI_NL"*}"
			_usv_v="${_usv_v#\'}"
			printf '%s' "${_usv_v%\'}" ;;
	esac
}

_USEC_SEC=""; _USEC_SNAP=""
uci5g_sec_snapshot() {
	_USEC_SEC="$1"
	_USEC_SNAP=$(uci_sec_snap 5gmodem "$1")
}
uci5g_sec_get() {
	uci_sec_val "$_USEC_SNAP" "5gmodem.$_USEC_SEC" "$1"
}

_UCINET_SNAP=""
ucinet_snapshot() { _UCINET_SNAP="$_UCI_NL$(uci -q show network 2>/dev/null)"; }
ucinet_get() {
	if [ -n "$_UCINET_SNAP" ]; then
		_uci_snap_get "$_UCINET_SNAP" "network.$1.$2"
		return
	fi
	uci -q get "network.$1.$2" 2>/dev/null
}
ucinet_has() {
	if [ -n "$_UCINET_SNAP" ]; then
		case "$_UCINET_SNAP" in
			*"$_UCI_NL"network."$1"=*) return 0 ;;
			*) return 1 ;;
		esac
	fi
	uci -q get "network.$1" >/dev/null 2>&1
}

sec_for_iface() {
	[ -n "$1" ] || return 1
	_uci5g_dump \
		| sed -n "s/^5gmodem\.\(m_[^.]*\)\.network='\?$1'\?\$/\1/p" \
		| head -1
}

imei_for_path() {
	[ -n "$1" ] || return 1
	uci -q get "5gmodem.$(secname "$1").imei"
}

iface_for_imei() {
	[ -n "$1" ] || return 1
	uci -q show network 2>/dev/null | grep -F ".modem_imei='$1'" \
		| sed -n "s/^network\.\([^.]*\)\.modem_imei=.*/\1/p" \
		| head -1
}

iface_owned_by() {
	[ -n "$1" ] || return 1
	_ow_i=$(uci -q get "network.$1.modem_imei")
	if [ -n "$_ow_i" ]; then
		if [ -n "$3" ] && [ "$_ow_i" = "$3" ]; then
			:
		else
			_ow_m=$(uci -q get "network.$1.modem_mac")
			case "$_ow_m" in
				''|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) return 1 ;;
			esac
			_ow_cm=$(iface_hw_mac "$2")
			[ -n "$_ow_cm" ] && [ "$_ow_m" = "$_ow_cm" ] || return 1
			[ -n "$3" ] && uci -q set "network.$1.modem_imei=$3" && uci -q commit network
			logger -t 5gmodem "iface $1: IMEI changed ($_ow_i -> $3) but the network card is the same ($_ow_m) - keeping the interface"
		fi
		_ow_p=$(uci -q get "network.$1.modem_path")
		if [ -n "$_ow_p" ] && [ "$_ow_p" != "$2" ] && [ -e "/sys/bus/usb/devices/$_ow_p" ]; then
			return 1
		fi
		return 0
	fi
	_ow_p=$(uci -q get "network.$1.modem_path")
	[ -n "$_ow_p" ] || return 0
	[ "$_ow_p" = "$2" ]
}

stamp_iface_owner() {
	[ -n "$1" ] && [ -n "$2" ] || return 0
	note_foreign_uci network "stamp_iface_owner"
	uci -q set "network.$1.modem_path=$2"
	_si_u=$(uci -q get "network.$1.usbpath")
	[ -n "$_si_u" ] && [ "$_si_u" != "$2" ] && uci -q set "network.$1.usbpath=$2"
	_si_i="$3"
	[ -n "$_si_i" ] || _si_i=$(imei_for_path "$2")
	[ -n "$_si_i" ] && uci -q set "network.$1.modem_imei=$_si_i"
	_si_m=$(iface_hw_mac "$2")
	[ -n "$_si_m" ] && uci -q set "network.$1.modem_mac=$_si_m"
	uci -q commit network
}

iface_hw_mac() {
	[ -n "$1" ] || return 1
	for _hm in /sys/bus/usb/devices/"$1":*/net/*/address; do
		[ -f "$_hm" ] || continue
		_hm_v=$(cat "$_hm" 2>/dev/null | tr -d " \t\n")
		case "$_hm_v" in
			''|00:00:00:00:00:00|ff:ff:ff:ff:ff:ff) continue ;;
		esac
		printf '%s' "$_hm_v"
		return 0
	done
	return 1
}

iface_up() {
	[ -n "$1" ] || return 1
	printf '%s' "$(date +%s 2>/dev/null)" > "/tmp/5gmodem/fibo_cold_$1" 2>/dev/null
	ubus call network.interface down "{\"interface\":\"$1\"}" >/dev/null 2>&1
	sleep 2
	ubus call network.interface up "{\"interface\":\"$1\"}" >/dev/null 2>&1
	case "$(ubus call "network.interface.$1" status 2>/dev/null)" in
		*'"autostart": true'*) ;;
		*)
			sleep 3
			ubus call network.interface up "{\"interface\":\"$1\"}" >/dev/null 2>&1 ;;
	esac
	return 0
}

remote_tele() {
	case "$1" in *[!0-9.]*|'') return 1 ;; esac
	_rt_f="/tmp/5gmodem/rtele_$(echo "$1" | tr -c '0-9' '_')"
	_rt_now=$(uptime_s)
	_rt_t=$(cat "$_rt_f.t" 2>/dev/null)
	case "$_rt_t" in ''|*[!0-9]*) _rt_t=0 ;; esac
	_rt_ttl=10
	[ -s "$_rt_f" ] || _rt_ttl=60
	if [ "$_rt_t" -gt 0 ] && [ "$_rt_now" -ge "$_rt_t" ] && [ $((_rt_now - _rt_t)) -lt "$_rt_ttl" ]; then
		cat "$_rt_f" 2>/dev/null
		return 0
	fi
	mkdir -p /tmp/5gmodem
	if command -v curl >/dev/null 2>&1; then
		_rt_b=$(curl -s -f --max-time 3 "http://$1/cgi-bin/5gmodem-tele" 2>/dev/null)
	else
		_rt_b=$(wget -q -T 3 -O - "http://$1/cgi-bin/5gmodem-tele" 2>/dev/null)
	fi
	case "$_rt_b" in
		'{'*'}') printf '%s' "$_rt_b" | jsonfilter -e '@' >/dev/null 2>&1 || _rt_b="" ;;
		*) _rt_b="" ;;
	esac
	printf '%s' "$_rt_b" > "$_rt_f.tmp" && mv "$_rt_f.tmp" "$_rt_f"
	printf '%s\n' "$_rt_now" > "$_rt_f.t"
	printf '%s' "$_rt_b"
}

mm_ghost_bearer() {
	[ -n "$1" ] && [ -n "$2" ] || return 1
	command -v mmcli >/dev/null 2>&1 || return 1
	_gb_st=$(ifstatus "$1" 2>/dev/null) || return 1
	case "$_gb_st" in *'"up": true'*|*'"pending": true'*) return 1 ;; esac
	case "$_gb_st" in *'"DISCONNECT_FAILED"'*) ;; *) return 1 ;; esac
	[ "$(mmcli -m "$2" -K 2>/dev/null | sed -n 's/^modem\.generic\.state *: *//p' | head -1)" = connected ] || return 1
	_gb_f="/tmp/5gmodem/mmghost.$1"
	_gb_now=$(uptime_s)
	_gb_t=$(cat "$_gb_f" 2>/dev/null)
	case "$_gb_t" in ''|*[!0-9]*) _gb_t=0 ;; esac
	[ "$_gb_t" -gt 0 ] && [ "$_gb_now" -ge "$_gb_t" ] && [ $((_gb_now - _gb_t)) -lt 600 ] && return 2
	mkdir -p /tmp/5gmodem
	printf '%s\n' "$_gb_now" > "$_gb_f"
	_gb_at=$(uci -q get "5gmodem.$(sec_for_iface "$1").at_port")
	logger -t 5gmodem "$1: ModemManager is stuck in 'connected' with a bearer the modem refuses to disconnect - resetting the modem"
	(
		mmcli -m "$2" --reset >/dev/null 2>&1 & _gb_p=$!
		( sleep 40; kill "$_gb_p" 2>/dev/null ) >/dev/null 2>&1 & _gb_w=$!
		wait "$_gb_p"; _gb_rc=$?
		kill "$_gb_w" 2>/dev/null
		if [ "$_gb_rc" != 0 ] && [ -n "$_gb_at" ] && [ -c "$_gb_at" ]; then
			logger -t 5gmodem "$1: mmcli --reset failed - rebooting the module over AT"
			/usr/share/5gmodem/reboot_modem.sh hard "$_gb_at"
		fi
	) >/dev/null 2>&1 </dev/null 9>&- &
	return 0
}

active_path() {
	uci5g_get "@5gmodem[0]" active_modem
}

active_sec() {
	_ap=$(active_path)
	[ -n "$_ap" ] || return 1
	secname "$_ap"
}

operator_clean() {
	case "$1" in
		*' '[Rr][Uu][Ss]) _oc=${1% *}; [ -n "$_oc" ] && printf '%s' "$_oc" || printf '%s' "$1" ;;
		*) printf '%s' "$1" ;;
	esac
}

opname_pretty() {
	_op_num=$(printf '%s' "$1" | tr -cd '0-9')
	_op_raw=$(printf '%s' "$2" | sed 's/^ *//;s/ *$//')
	[ -n "$_op_raw" ] && { operator_clean "$_op_raw"; return; }
	[ -n "$_op_num" ] || return
	awk -F';' '/^'"$_op_num"';/ {print $3}' /usr/share/5gmodem/mccmnc.dat 2>/dev/null \
		| head -1 | tr -d '\r' | sed 's/^ *//;s/ *$//'
}

opname_brand() {
	_ob_imsi=$(echo "$1" | tr -cd '0-9')
	[ "${#_ob_imsi}" -ge 5 ] || return 1
	_ob_f="/usr/share/5gmodem/apn.list"
	[ -f "$_ob_f" ] || return 1
	for _ob_len in 6 5; do
		_ob_p=$(printf '%s' "$_ob_imsi" | cut -c1-"$_ob_len")
		[ "${#_ob_p}" -eq "$_ob_len" ] || continue
		_ob_key="${_ob_p%${_ob_p#???}}-${_ob_p#???}"
		while IFS=: read -r _t _pat _val; do
			[ "$_t" = "opname" ] || continue
			[ "$_pat" = "$_ob_key" ] && [ -n "$_val" ] && { echo "$_val"; return 0; }
		done < "$_ob_f"
	done
	return 1
}

opname_by_apn() {
	_oa_a=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	[ -n "$_oa_a" ] || return 1
	_oa_f="/usr/share/5gmodem/apn.list"
	[ -f "$_oa_f" ] || return 1
	while IFS=: read -r _t _pat _val; do
		[ "$_t" = "opapn" ] && [ -n "$_pat" ] && [ -n "$_val" ] || continue
		case "$_oa_a" in $_pat) echo "$_val"; return 0 ;; esac
	done < "$_oa_f"
	return 1
}

_model_sane() {
	case "$1" in
		AT+*|AT^*|AT$*|at+*|at^*) return 1 ;;
		AT|AT[\ 0-9]*|at|at[\ 0-9]*) return 1 ;;
		*ERROR*|*error*) return 1 ;;
		*'?'*|*'='*|*'"'*) return 1 ;;
		*'#'*|*': '*) return 1 ;;
		+[A-Z]*|*' +'[A-Z]*) return 1 ;;
		'') return 1 ;;
	esac
	[ "${#1}" -ge 3 ] && [ "${#1}" -le 40 ] || return 1
	[ -z "$(printf '%s' "$1" | tr -d 'A-Za-z0-9 ._+/()-')" ] || return 1
	case "$1" in *[A-Za-z]*) return 0 ;; esac
	return 1
}
_vendor_by_vid() {
	case "$1" in
		0e8d:712*|2cb7:*) echo fibocom ;;
		12d1:*)        echo huawei ;;
		1bc7:*)        echo telit ;;
		2c7c:*)        echo quectel ;;
		19d2:*)        echo zte ;;
		# see docs/subsystems/device-detection.md#_vendor_by_vid-_model_vendor_ok
		1e2d:00b7) ;;
		1e2d:*)        echo cinterion ;;
		2dee:*)        echo meiglink ;;
		1e0e:*)        echo simcom ;;
	esac
}
_model_vendor_ok() {
	_mv_want=$(_vendor_by_vid "$2")
	[ -n "$_mv_want" ] || return 0
	_mv_syn="$_mv_want"
	case "$_mv_want" in
		cinterion) _mv_syn="cinterion thales gemalto" ;;
	esac
	_mv_low=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	for _mv_a in $_mv_syn; do
		case "$_mv_low" in *"$_mv_a"*) return 0 ;; esac
	done
	for _mv_other in fibocom huawei telit quectel zte cinterion meiglink simcom \
	                 compal foxconn thales dell; do
		case " $_mv_syn " in *" $_mv_other "*) continue ;; esac
		case "$_mv_low" in *"$_mv_other"*) return 1 ;; esac
	done
	return 0
}

sig_percent() {
	awk -v mode="$1" -v rsrp="$2" -v rsrq="$3" -v sinr="$4" \
	    -v rscp="$5" -v ecio="$6" -v rssi="$7" '
	function isnum(v) { return (v ~ /^-?[0-9]+(\.[0-9]+)?$/) }
	function pctof(v, t0, t1, t2, t3,   l, lo, hi, f) {
		if      (v >= t3) { l = 4; lo = t3; hi = t3 + (t3 - t2) }
		else if (v >= t2) { l = 3; lo = t2; hi = t3 }
		else if (v >= t1) { l = 2; lo = t1; hi = t2 }
		else if (v >= t0) { l = 1; lo = t0; hi = t1 }
		else              { l = 0; lo = t0 - (t1 - t0); hi = t0 }
		f = (v - lo) / (hi - lo)
		if (f < 0) f = 0
		if (f > 1) f = 1
		return l * 20 + f * 20
	}
	function take(v, t0, t1, t2, t3,   p) {
		if (!isnum(v)) return
		p = pctof(v + 0, t0, t1, t2, t3)
		if (p < 1) p = 1
		if (best < 0 || p < best) best = p
	}
	BEGIN {
		best = -1
		m = tolower(mode)
		if      (m ~ /nsa/)                  rat = "lte"
		else if (m ~ /5g|nr/)                rat = "nr"
		else if (m ~ /lte|4g/)               rat = "lte"
		else if (m ~ /umts|hspa|wcdma|3g/)   rat = "umts"
		else if (m ~ /gsm|edge|gprs|2g/)     rat = "gsm"
		else                                 rat = "lte"
		if (sinr + 0 == 0 && isnum(rsrq) && rsrq + 0 >= -14) sinr = ""
		if (rat == "nr") {
			take(rsrp, -110, -90, -80, -65)
			take(rsrq,  -31, -19, -17, -14)
			take(sinr,   -5,   5,  15,  30)
		} else if (rat == "umts") {
			take(rscp, -115, -105, -95, -85)
			take(ecio,  -24,  -14,  -6,   1)
			if (best < 0) take(rssi, -107, -103, -97, -89)
		} else if (rat == "gsm") {
			take(rssi, -107, -103, -97, -89)
		} else {
			take(rsrp, -128, -118, -108, -98)
			take(rsrq,  -20,  -17,  -14, -11)
			take(sinr,   -3,    1,    5,  13)
		}
		if (best >= 0) printf "%d", best + 0.5
	}' 2>/dev/null
}

at_dialer_busy() {
	[ -n "$1" ] || return 1
	pgrep -f "gcom .*-d *$1" >/dev/null 2>&1 && return 0
	pgrep -f "gcom -d *$1" >/dev/null 2>&1
}

dial_port_for_path() {
	[ -n "$1" ] || return 1
	if [ "$_DPP_IN" = "$1" ]; then
		printf '%s\n' "$_DPP_OUT"
		return 0
	fi
	_dpp_sec=$(secname "$1")
	_dpp_out=""
	_dpp_if=$(uci -q get "5gmodem.$_dpp_sec.network")
	if [ -n "$_dpp_if" ]; then
		proto_in dialtty "$(uci -q get "network.$_dpp_if.proto" 2>/dev/null)" \
			&& _dpp_out=$(uci -q get "network.$_dpp_if.device" 2>/dev/null)
	fi
	case "$_dpp_out" in /dev/*) : ;; *) _dpp_out="" ;; esac
	_DPP_IN="$1"; _DPP_OUT="$_dpp_out"
	printf '%s\n' "$_dpp_out"
}

tty_send_if() {
	_tpu_d=$(readlink -f "/sys/class/tty/${1##*/}/device" 2>/dev/null)
	[ -n "$_tpu_d" ] || return 1
	[ -f "$_tpu_d/bInterfaceNumber" ] || _tpu_d=${_tpu_d%/*}
	[ -f "$_tpu_d/bInterfaceNumber" ] || return 1
	_tpu_u=${_tpu_d%/*}
	case "$(cat "$_tpu_u/idVendor" 2>/dev/null):$(cat "$_tpu_u/idProduct" 2>/dev/null):$(cat "$_tpu_d/bInterfaceNumber" 2>/dev/null)" in
		0e8d:7127:06) _TPU_P=${_tpu_u##*/}; return 0 ;;
	esac
	return 1
}

tty_poll_unsafe() {
	tty_send_if "$1" || return 1
	_tpu_s=$(secname "$_TPU_P")
	[ "$(uci -q get "5gmodem.$_tpu_s.poll_send_ok")" = 1 ] && return 1
	[ -f "/tmp/5gmodem/pollsend_$_tpu_s" ] && return 1
	return 0
}

poll_send_mark() {
	_psm_s=$(secname "$1")
	[ "$(uci -q get "5gmodem.$_psm_s.poll_send_ok")" = 1 ] && return 0
	[ -f "/tmp/5gmodem/pollsend_$_psm_s" ] && return 0
	cut -d. -f1 /proc/uptime > "/tmp/5gmodem/pollsend_$_psm_s" 2>/dev/null
}

poll_send_settle() {
	tty_send_if "$2" || return 1
	_pss_f="/tmp/5gmodem/pollsend_$(secname "$1")"
	[ -f "$_pss_f" ] || return 1
	_pss_a=$(cat "$_pss_f" 2>/dev/null); _pss_n=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$_pss_a" in ''|*[!0-9]*) _pss_a=0 ;; esac
	case "$_pss_n" in ''|*[!0-9]*) return 1 ;; esac
	[ $((_pss_n - _pss_a)) -ge 120 ] || return 1
	for _pss_t in $(drop_dial_port "$1" $(/usr/share/5gmodem/listmodems.sh 2>/dev/null \
			| jsonfilter -e "@[@.path=\"$1\"].tty[*]" 2>/dev/null)); do
		tty_send_if "$_pss_t" && continue
		/usr/share/5gmodem/atprobe.sh "$_pss_t" model || continue
		rm -f "$_pss_f"
		return 0
	done
	if exec 6>/tmp/5gmodem/ucitx.lock 2>/dev/null && flock -n 6; then
		uci -q set "5gmodem.$(secname "$1").poll_send_ok=1"
		uci -q delete "5gmodem.$(secname "$1").poll_send_port"
		uci -q commit 5gmodem 2>/dev/null
		flock -u 6
		rm -f "$_pss_f"
	fi
	return 1
}

drop_dial_port() {
	_ddp_p="$1"; shift
	_ddp_skip=$(dial_port_for_path "$_ddp_p")
	_ddp_out=""
	for _ddp_t in "$@"; do
		[ -n "$_ddp_skip" ] && [ "$_ddp_t" = "$_ddp_skip" ] && continue
		tty_poll_unsafe "$_ddp_t" && continue
		_ddp_out="$_ddp_out $_ddp_t"
	done
	[ -n "$_ddp_out" ] || { printf '%s\n' "$*"; return 0; }
	printf '%s\n' "${_ddp_out# }"
}

mm_owns_path() {
	[ -n "$1" ] || return 1
	pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1 || return 1
	_mo_c="/tmp/5gmodem/mmowns_$(echo "$1" | sed 's/[^A-Za-z0-9]/_/g')"
	_mo_v=""
	if [ -s "$_mo_c" ] && [ -n "$(find "$_mo_c" -mmin -1 2>/dev/null)" ]; then
		read -r _mo_v 2>/dev/null < "$_mo_c"
	else
		_mo_old=$(cat "$_mo_c" 2>/dev/null)
		_mo_v=$(/usr/share/5gmodem/modemswitch.sh mmindex "$1" 2>/dev/null)
		_mo_v="${_mo_v:-none}"
		printf '%s\n' "$_mo_v" > "$_mo_c" 2>/dev/null
		if [ "$_mo_v" != "$_mo_old" ] && [ "$_mo_v" != "none" ]; then
			logger -t 5gmodem "modem $1 is registered in ModemManager (index $_mo_v) - leaving AT and the channel alone"
		fi
	fi
	[ -n "$_mo_v" ] && [ "$_mo_v" != "none" ]
}

alias_for_path() {
	[ -n "$1" ] || return 0
	_af_sec=$(secname "$1")
	_af_snap=$(uci -q show 5gmodem 2>/dev/null)
	case "$_af_snap" in *".alias="*) : ;; *) return 0 ;; esac
	_af_im=$(printf '%s\n' "$_af_snap" \
		| sed -n "s/^5gmodem\.$_af_sec\.imei='\(.*\)'\$/\1/p" | head -1)
	if [ -n "$_af_im" ]; then
		_af_a=$(printf '%s\n' "$_af_snap" | awk -F"[.=]" -v im="$_af_im" '
			/\.alias_imei=/ { v = $NF; gsub(/^.|.$/, "", v); imei[$2] = v; next }
			/\.alias=/ { line = $0; sub(/^[^=]*=/, "", line); gsub(/^.|.$/, "", line); nm[$2] = line }
			END { for (s in nm) if (imei[s] == im && nm[s] != "") { print nm[s]; exit } }')
		[ -n "$_af_a" ] && { printf '%s\n' "$_af_a"; return 0; }
	fi
	_af_sa=$(printf '%s\n' "$_af_snap" \
		| sed -n "s/^5gmodem\.$_af_sec\.alias='\(.*\)'\$/\1/p" | head -1)
	[ -n "$_af_sa" ] || return 0
	_af_sm=$(printf '%s\n' "$_af_snap" \
		| sed -n "s/^5gmodem\.$_af_sec\.alias_imei='\(.*\)'\$/\1/p" | head -1)
	if [ -z "$_af_sm" ] || [ "$_af_sm" = "$_af_im" ]; then
		printf '%s\n' "$_af_sa"
	fi
}

tty_usbpath() {
	[ -n "$1" ] || return 1
	case "${1##*/}" in ttyMTK*) echo ccci; return 0 ;; esac
	_tp=$(readlink -f "/sys/class/wwan/$(basename "$1")/device" 2>/dev/null)
	if [ -n "$_tp" ]; then
		while [ -n "$_tp" ] && [ "$_tp" != /sys ]; do
			if [ -d "$_tp/remoteproc" ] || [ -e "/sys/bus/pci/devices/${_tp##*/}" ]; then
				echo "${_tp##*/}"; return 0
			fi
			[ -f "$_tp/idVendor" ] && break
			_tp=${_tp%/*}
		done
	fi
	_tp=$(readlink -f "/sys/class/tty/$(basename "$1")/device" 2>/dev/null) || return 1
	[ -n "$_tp" ] || return 1
	_tp=${_tp%/*}
	_tp=${_tp##*/}
	echo "${_tp%%:*}"
}

digits_of() {
	printf '%s' "$1" | tr -c '0-9' '\n' \
		| awk -v a="${2:-14}" -v b="${3:-20}" 'length($0) >= a && length($0) <= b { print; exit }'
}

at_strip_ok() {
	printf '%s' "$1" | sed \
		-e 's/[[:space:]][[:space:]]*OK[[:space:]]*$//' \
		-e 's/[[:space:]][[:space:]]*ERROR[[:space:]]*$//' \
		-e 's/^OK[[:space:]][[:space:]]*//' \
		-e 's/[[:space:]][[:space:]]*OK[[:space:]][[:space:]]*/ /g' \
		-e 's/^OK$//' \
		-e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

strip_ok_var() {
	eval "_so_v=\$$1"
	case "$_so_v" in
		*OK*) eval "$1=\$(at_strip_ok \"\$_so_v\")" ;;
	esac
}

model_alias() {
	set -- "$(at_strip_ok "$1")"
	case "$1" in
		*VOS_5G*|*RXMG1*|*SG500M2*) echo "Compal RXM-G1" ;;
		SIMCOM_*) echo "SIMCom ${1#SIMCOM_}" ;;
		SIMCOM\ *) echo "SIMCom ${1#SIMCOM }" ;;
		*DW5821e*[Ee][Ss][Ii][Mm]*) echo "Dell DW5821e eSIM" ;;
		*DW5821e*) echo "Dell DW5821e" ;;
		L8[0-9]0*" LTE Module") echo "Fibocom ${1% LTE Module}" ;;
		*" LTE Module") echo "${1% LTE Module}" ;;
		*" Technologies Co.,Ltd. "*) echo "${1%% Technologies Co.,Ltd. *} ${1#* Technologies Co.,Ltd. }" ;;
		*) echo "$1" ;;
	esac
}

model_refine() {
	_mr_m="$1"; _mr_p="$2"
	[ -n "$_mr_m" ] || { printf '%s' "$_mr_m"; return 0; }
	[ -n "$_mr_p" ] || { printf '%s' "$_mr_m"; return 0; }
	_mr_last="${_mr_m##* }"
	[ -n "$_mr_last" ] || { printf '%s' "$_mr_m"; return 0; }
	case "$_mr_p" in
		"$_mr_last"[-_]*)
			_mr_suf="${_mr_p#$_mr_last}"
			case "$_mr_suf" in
				[-_][A-Za-z0-9]|[-_][A-Za-z0-9][A-Za-z0-9]|[-_][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9])
					printf '%s%s' "$_mr_m" "$_mr_suf"; return 0 ;;
			esac ;;
	esac
	printf '%s' "$_mr_m"
	return 0
}

_qmi_target_iface() {
	_qti=""
	[ -n "$QMI_TARGET_PATH" ] && _qti=$(uci -q get "5gmodem.$(secname "$QMI_TARGET_PATH").network" 2>/dev/null)
	[ -n "$_qti" ] || _qti=$(uci -q get "5gmodem.$(active_sec 2>/dev/null).network" 2>/dev/null)
	[ -n "$_qti" ] || _qti=$(uci -q get 5gmodem.@5gmodem[0].network 2>/dev/null)
	printf '%s' "$_qti"
}

qmi_channel_free() {
	_qcf_if=$(_qmi_target_iface)
	[ -n "$_qcf_if" ] || return 0
	proto_in direct "$(uci -q get "network.$_qcf_if.proto" 2>/dev/null)" || return 0
	_qcf_st=$(ubus call "network.interface.$_qcf_if" status 2>/dev/null)
	case "$_qcf_st" in
		*'"up": true'*) return 1 ;;
		*'"pending": true'*) return 1 ;;
	esac
	_qcf_dev=$(uci -q get "network.$_qcf_if.device" 2>/dev/null)
	pgrep -f "uqmi .*$_qcf_dev" >/dev/null 2>&1 && return 1
	pgrep -f "umbim .*$_qcf_dev" >/dev/null 2>&1 && return 1
	return 0
}

qmicli_p() {
	command -v qmicli >/dev/null 2>&1 || return 1
	command -v qmi_channel_free >/dev/null 2>&1 || return 1
	qmi_channel_free || return 1
	_qp_dev="$1"; shift
	[ -c "$_qp_dev" ] || return 1
	_qp_mb=""
	case "$(readlink -f "/sys/class/usbmisc/${_qp_dev##*/}/device/driver" 2>/dev/null)" in
		*/cdc_mbim) _qp_mb="--device-open-mbim" ;;
	esac
	_qp_if=$(_qmi_target_iface)
	_qp_proto=$(uci -q get "network.$_qp_if.proto" 2>/dev/null)
	_qp_direct=""
	if proto_in proxy "$_qp_proto"; then
		:
	elif [ "$_qp_proto" = "qmi" ]; then
		_qp_direct=1
	elif ! pgrep -f '/usr/sbin/ModemManager' >/dev/null 2>&1; then
		if [ -z "$_qp_if" ] || ! ubus call "network.interface.$_qp_if" status 2>/dev/null \
			| grep -q '"up": true'; then
			_qp_direct=1
		fi
	fi
	_qp_lk="/var/lock/5gmodem_qmi_${_qp_dev##*/}.lock"
	{ exec 9>"$_qp_lk"; } 2>/dev/null
	_qp_i=0
	while [ "$_qp_i" -lt 15 ]; do
		flock -n 9 2>/dev/null && break
		sleep 1
		_qp_i=$((_qp_i + 1))
	done
	if [ "$_qp_i" -gt 0 ] && ! qmi_channel_free; then
		{ exec 9>&-; } 2>/dev/null
		return 1
	fi
	_qp_bad="/tmp/5gmodem/qmiproxy_bad.${_qp_dev##*/}"
	_qp_now=$(cut -d. -f1 /proc/uptime)
	_qp_skip=""
	if [ -n "$_qp_direct" ] && [ -f "$_qp_bad" ]; then
		_qp_when=$(cat "$_qp_bad" 2>/dev/null)
		case "$_qp_when" in
			''|*[!0-9]*) rm -f "$_qp_bad" ;;
			*) [ $((_qp_now - _qp_when)) -lt 120 ] && _qp_skip=1 || rm -f "$_qp_bad" ;;
		esac
	fi
	_qp_o=$(mktemp /tmp/5gmodem/qmicli.XXXXXX 2>/dev/null) || _qp_o="/tmp/5gmodem/qmicli.$$.$(date +%s)"
	[ "$_qp_proto" = "qmi" ] && _qp_skip=1
	proto_in direct "$_qp_proto" && [ -n "$_qp_direct" ] && _qp_skip=1
	if [ -z "$_qp_skip" ]; then
		_qp_w=20; [ -n "$_qp_direct" ] && _qp_w=6
		qmicli -d "$_qp_dev" -p $_qp_mb "$@" > "$_qp_o" 2>/dev/null 7>&- 8>&- 9>&- &
		_qp_pid=$!
		( exec >/dev/null 2>&1 7>&- 8>&- 9>&-; sleep "$_qp_w"; kill -9 "$_qp_pid" 2>/dev/null ) </dev/null &
		_qp_k=$!
		sleep_tick_init
		_qp_i=0; _qp_max=$(( (_qp_w + 1) * _TICKS_PER_SEC ))
		while kill -0 "$_qp_pid" 2>/dev/null && [ "$_qp_i" -lt "$_qp_max" ]; do
			_qp_i=$((_qp_i + 1)); sleep "$_SLEEP_TICK"
		done
		if kill -0 "$_qp_pid" 2>/dev/null; then _qp_rc=1; else wait "$_qp_pid" 2>/dev/null; _qp_rc=$?; fi
		kill "$_qp_k" 2>/dev/null; wait "$_qp_k" 2>/dev/null
		if [ -s "$_qp_o" ]; then
			rm -f "$_qp_bad"
		elif [ -n "$_qp_direct" ]; then
			printf '%s\n' "$_qp_now" > "$_qp_bad"
		fi
	fi
	if [ ! -s "$_qp_o" ] && [ -n "$_qp_direct" ] && qmi_channel_free; then
		qmicli -d "$_qp_dev" $_qp_mb "$@" > "$_qp_o" 2>/dev/null 7>&- 8>&- 9>&- &
		_qp_pid=$!
		( exec >/dev/null 2>&1 7>&- 8>&- 9>&-; sleep 20; kill -9 "$_qp_pid" 2>/dev/null ) </dev/null &
		_qp_k=$!
		sleep_tick_init
		_qp_i=0; _qp_max2=$(( 21 * _TICKS_PER_SEC ))
		while kill -0 "$_qp_pid" 2>/dev/null && [ "$_qp_i" -lt "$_qp_max2" ]; do
			_qp_i=$((_qp_i + 1)); sleep "$_SLEEP_TICK"
		done
		if kill -0 "$_qp_pid" 2>/dev/null; then _qp_rc=1; else wait "$_qp_pid" 2>/dev/null; _qp_rc=$?; fi
		kill "$_qp_k" 2>/dev/null; wait "$_qp_k" 2>/dev/null
		[ -s "$_qp_o" ] && logger -t 5gmodem "qmi: proxy not responding - read directly from $_qp_dev"
	fi
	cat "$_qp_o" 2>/dev/null; rm -f "$_qp_o"
	{ exec 9>&-; } 2>/dev/null
	return "${_qp_rc:-0}"
}

is_num() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

is_numlist() {
	[ -n "$1" ] || return 1
	case "$1" in
		*[!0-9\ ]*) return 1 ;;
	esac
	case "$1" in
		*[0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

is_devpath() {
	case "$1" in
		*..*|*[!A-Za-z0-9/._-]*) return 1 ;;
		/dev/ttyUSB[0-9]*|/dev/ttyACM[0-9]*|/dev/cdc-wdm[0-9]*|/dev/wwan[0-9]*|/dev/ttyMTK[0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

json_esc() {
	case "$1" in
		*\\*|*\"*|*[[:cntrl:]]*)
			printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*) printf '%s' "$1" ;;
	esac
}

is_atcmd() {
	[ -n "$1" ] || return 1
	case "$1" in
		*'
'*) return 1 ;;
	esac
	case "$1" in
		*"$(printf '\r')"*) return 1 ;;
	esac
	[ -z "$(printf '%s' "$1" | tr -d 'A-Za-z0-9+?=",:;*#._ /()^$!%&@[]{}<>~|'"'"'-')" ]
}

_SLEEP_TICK=""
_TICKS_PER_SEC=1
sleep_tick_init() {
	[ -n "$_SLEEP_TICK" ] && return 0
	if (sleep 0.0) 2>/dev/null; then
		_SLEEP_TICK="0.1"; _TICKS_PER_SEC=10
	else
		_SLEEP_TICK="1"; _TICKS_PER_SEC=1
	fi
}

at_query() {
	_aq_p="$1"; _aq_c="$2"; _aq_t="${3:-8}"
	[ -n "$_aq_p" ] && [ -c "$_aq_p" ] || return 1
	case "${_aq_p##*/}" in
		wwan*at*)
			command -v tty_no_at >/dev/null 2>&1 || . /usr/share/5gmodem/noatports.sh
			tty_no_at "$_aq_p" && return 1 ;;
	esac
	command -v sms_tool >/dev/null 2>&1 || return 1
	if command -v is_atcmd >/dev/null 2>&1 && ! is_atcmd "$_aq_c"; then
		logger -t 5gmodem "at_query: command rejected by validation"
		return 1
	fi
	[ -n "$AT_LOCK_FD" ] || . /usr/share/5gmodem/atlock.sh 2>/dev/null

	_aq_mine=0
	if command -v at_lock >/dev/null 2>&1 \
	   && [ "$_AT_LOCK_HELD" != "$(basename "$_aq_p")" ]; then
		if at_lock "$_aq_p" "${4:-10}" 2>/dev/null; then
			_aq_mine=1
		else
			return 2
		fi
	fi

	_aq_o=$(mktemp /tmp/5gmodem/atq.XXXXXX 2>/dev/null) || _aq_o="/tmp/5gmodem/atq.$$.$(date +%s)"
	sleep_tick_init
	if [ "$_TICKS_PER_SEC" = 1 ]; then
		{
			( sleep "$_aq_t" </dev/null & _aq_x=$!; trap 'kill $_aq_x; exit' TERM; wait $_aq_x; echo t ) &
			echo $! > "$_aq_o.s"
			( sms_tool -d "$_aq_p" at "$_aq_c" > "$_aq_o" 2>/dev/null </dev/null & _aq_x=$!
			  trap 'kill $_aq_x; exit' TERM; wait $_aq_x; echo d ) &
			echo $! > "$_aq_o.p"
		} 2>/dev/null 7>&- 8>&- 9>&- | read -r _aq_r
		kill "$(cat "$_aq_o.s" 2>/dev/null)" 2>/dev/null
		_aq_pid=$(cat "$_aq_o.p" 2>/dev/null)
		[ -n "$_aq_pid" ] && kill -0 "$_aq_pid" 2>/dev/null && kill "$_aq_pid" 2>/dev/null
		rm -f "$_aq_o.s" "$_aq_o.p"
	else
		sms_tool -d "$_aq_p" at "$_aq_c" > "$_aq_o" 2>/dev/null 7>&- 8>&- 9>&- &
		_aq_pid=$!
		( exec >/dev/null 2>&1 8>&- 9>&-; sleep "$_aq_t"; kill "$_aq_pid" 2>/dev/null ) </dev/null & _aq_w=$!
		_aq_i=0; _aq_max=$(( (${_aq_t:-8} + 1) * _TICKS_PER_SEC ))
		while kill -0 "$_aq_pid" 2>/dev/null && [ "$_aq_i" -lt "$_aq_max" ]; do
			_aq_i=$((_aq_i + 1)); sleep "$_SLEEP_TICK"
		done
		kill -0 "$_aq_pid" 2>/dev/null || wait "$_aq_pid" 2>/dev/null
		kill "$_aq_w" 2>/dev/null; wait "$_aq_w" 2>/dev/null
	fi

	[ "$_aq_mine" = 1 ] && at_unlock 2>/dev/null
	tr -d '\r' 2>/dev/null < "$_aq_o"
	rm -f "$_aq_o"
	return 0
}

sms_cmd_key() {
	printf '%s|%s|%s' "$1" "$2" "$3" | md5sum | cut -c1-16
}

sms_card_id() {
	_sci=$(jsonfilter -e '@.iccid' < "/tmp/5gmodem/metrics_$(snap_key "$1").json" 2>/dev/null \
		| tr -cd '0-9')
	[ ${#_sci} -ge 10 ] || return 1
	printf '%s' "$_sci"
}

sms_cmd_done_file() {
	_scc=$(sms_card_id "$1" 2>/dev/null)
	[ -n "$_scc" ] && { echo "/etc/5gmodem/sms_cmd.sim$_scc"; return; }
	_scd=$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')
	[ -n "$_scd" ] && echo "/etc/5gmodem/sms_cmd.$_scd" || echo "/etc/5gmodem/sms_cmd"
}

sms_cmd_cool_file() {
	printf '%s.cool' "$(sms_cmd_done_file "$1")"
}

sms_cpms_state() {
	_cs_r=$(at_query "$1" "AT+CPMS?" 8) || return 1
	_cs_l=$(printf '%s' "$_cs_r" | sed -n 's/.*+CPMS:[[:space:]]*//p' | head -1)
	_cs_1=$(printf '%s' "$_cs_l" | awk -F, '{print $1}' | tr -d ' "')
	_cs_2=$(printf '%s' "$_cs_l" | awk -F, '{print $4}' | tr -d ' "')
	_cs_3=$(printf '%s' "$_cs_l" | awk -F, '{print $7}' | tr -d ' "')
	[ -n "$_cs_1" ] || return 1
	printf '%s|%s|%s\n' "$_cs_1" "$_cs_2" "$_cs_3"
}

sms_apply_cpms() {
	hl_web_port "$1" && return 1
	_cp_p="$1"; _cp_s="$2"
	[ -n "$_cp_p" ] && [ -c "$_cp_p" ] || return 1
	case "$_cp_s" in ''|*[!A-Za-z]*) return 1 ;; esac

	_cp_o=$(at_query "$_cp_p" "AT+CPMS=\"$_cp_s\",\"$_cp_s\",\"$_cp_s\"" 8)
	case "$_cp_o" in
		*ERROR*)
			at_query "$_cp_p" "AT+CPMS=\"$_cp_s\"" 8 >/dev/null ;;
	esac

	_cp_st=$(sms_cpms_state "$_cp_p") || return 1
	_cp_m1=${_cp_st%%|*}; _cp_m3=${_cp_st##*|}
	if [ "$_cp_m1" != "$_cp_s" ]; then
		logger -t 5gmodem "sms: modem rejected storage $_cp_s (still $_cp_st)"
		return 1
	fi
	if [ "$_cp_m3" != "$_cp_s" ]; then
		logger -t 5gmodem \
			"sms: reading switched to $_cp_s, but the modem stores incoming in $_cp_m3"
	else
		logger -t 5gmodem "sms: storage $_cp_s applied to the modem (read and receive)"
	fi
	printf '%s|%s\n' "$_cp_m1" "$_cp_m3"
}

set_sms_storage() {
	_ss_at="$1"
	[ -n "$_ss_at" ] && [ -e "$_ss_at" ] || return 0
	hl_web_port "$_ss_at" && return 0
	command -v sms_tool >/dev/null 2>&1 || return 0
	uci -q get 5gmodem.sms >/dev/null 2>&1 || return 0

	_ss_stg=$(uci -q get 5gmodem.sms.storage)
	_ss_alt=""

	if [ "$(uci -q get 5gmodem.sms.storage_touched)" != 1 ]; then
		_ss_me=$(sms_tool -d "$_ss_at" -s ME status 2>/dev/null | sed -n 's/.*total:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
		_ss_sm=$(sms_tool -d "$_ss_at" -s SM status 2>/dev/null | sed -n 's/.*total:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
		_ss_try=0
		while [ -n "$_ss_stg" ] && [ "$_ss_try" -lt 2 ] && { [ -z "$_ss_me" ] || [ -z "$_ss_sm" ]; } && [ -n "$_ss_me$_ss_sm" ]; do
			_ss_try=$((_ss_try + 1))
			sleep 3
			[ -n "$_ss_me" ] || _ss_me=$(sms_tool -d "$_ss_at" -s ME status 2>/dev/null | sed -n 's/.*total:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
			[ -n "$_ss_sm" ] || _ss_sm=$(sms_tool -d "$_ss_at" -s SM status 2>/dev/null | sed -n 's/.*total:[ ]*\([0-9]\{1,\}\).*/\1/p' | head -1)
		done
		_ss_vp=$(uci -q get "5gmodem.m_$(uci -q get 5gmodem.@5gmodem[0].active_modem | sed 's/[^A-Za-z0-9]/_/g').vidpid")
		[ "$_ss_vp" = "19d2:1485" ] || case "$_ss_stg" in
			ME) [ -z "$_ss_me" ] && [ -n "$_ss_sm" ] && _ss_alt=SM ;;
			SM) [ -z "$_ss_sm" ] && [ -n "$_ss_me" ] && _ss_alt=ME ;;
		esac
		if   [ "$_ss_vp" = "19d2:1485" ]; then _ss_new=MT
		elif [ -n "$_ss_alt" ]; then _ss_new="$_ss_stg"
		elif [ "${_ss_me:-0}" -gt "${_ss_sm:-0}" ] 2>/dev/null; then _ss_new=ME
		elif [ "${_ss_sm:-0}" -gt "${_ss_me:-0}" ] 2>/dev/null; then _ss_new=SM
		elif [ -n "$_ss_me" ]; then _ss_new=ME
		elif [ -n "$_ss_sm" ]; then _ss_new=SM
		else _ss_new=""
		fi
		if [ -n "$_ss_new" ] && [ "$_ss_new" != "$_ss_stg" ]; then
			uci -q set "5gmodem.sms.storage=$_ss_new"
			uci -q commit 5gmodem
			logger -t 5gmodem \
				"sms: storage auto-selected: $_ss_new (ME=${_ss_me:-?}, SM=${_ss_sm:-?})"
			_ss_stg="$_ss_new"
		fi
	fi

	[ -n "$_ss_stg" ] || return 0
	if ! _ss_st=$(sms_apply_cpms "$_ss_at" "$_ss_stg"); then
		[ -n "$_ss_alt" ] || return 1
		_ss_st=$(sms_apply_cpms "$_ss_at" "$_ss_alt") || return 1
		uci -q set "5gmodem.sms.storage=$_ss_alt"
		uci -q commit 5gmodem
		logger -t 5gmodem \
			"sms: storage auto-selected: $_ss_alt ($_ss_stg did not answer and was rejected by the modem)"
		_ss_stg="$_ss_alt"
	fi
	_ss_m3=${_ss_st##*|}
	if [ -n "$_ss_m3" ] && [ "$_ss_m3" != "$_ss_stg" ]; then
		uci -q set "5gmodem.sms.storage=$_ss_m3"
		uci -q commit 5gmodem
		logger -t 5gmodem \
			"sms: storage corrected to $_ss_m3: the modem cannot receive into $_ss_stg"
		sms_apply_cpms "$_ss_at" "$_ss_m3" >/dev/null 2>&1
	fi
	return 0
}

net_proxy_port() {
	_np_p=$(sed -n 's/^\(mixed-port\|port\) *: *\([0-9]*\).*/\2/p' \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	case "$_np_p" in ''|0) ;; *) printf '%s' "$_np_p"; return 0 ;; esac
	command -v curl >/dev/null 2>&1 || return 1
	_np_s=$(sed -n "s/^ *secret *: *[\"']*\([^\"' ]*\).*/\1/p" \
		/opt/clash/config.yaml /etc/clash/config.yaml 2>/dev/null | head -1)
	_np_capi() {
		if [ -n "$_np_s" ]; then
			curl -s -m 3 -H "Authorization: Bearer $_np_s" "$@" 2>/dev/null
		else
			curl -s -m 3 "$@" 2>/dev/null
		fi
	}
	_np_r=$(_np_capi "http://127.0.0.1:9090/configs" | jsonfilter -e '@["mixed-port"]' 2>/dev/null)
	case "$_np_r" in ''|*[!0-9]*) return 1 ;; esac
	if [ "$_np_r" = "0" ]; then
		_np_capi -X PATCH "http://127.0.0.1:9090/configs" -d '{"mixed-port":7895}' -o /dev/null || return 1
		_np_r=7895
		logger -t 5gmodem "net: direct path is blocked - opened clash mixed-port 7895 (local API, 127.0.0.1 only)"
	fi
	printf '%s' "$_np_r"
}

net_fetch() {
	_nf_t="$1"; _nf_u="$2"; _nf_o="$3"
	if [ -n "$_nf_o" ]; then
		wget -qO "$_nf_o" --timeout="$_nf_t" "$_nf_u" 2>/dev/null && [ -s "$_nf_o" ] && return 0
		rm -f "$_nf_o" 2>/dev/null
	else
		_nf_b=$(wget -qO- --timeout="$_nf_t" "$_nf_u" 2>/dev/null)
		[ -n "$_nf_b" ] && { printf '%s' "$_nf_b"; return 0; }
	fi
	_nf_p=$(net_proxy_port) || return 1
	[ -n "$_nf_p" ] || return 1
	logger -t 5gmodem "net: direct fetch failed - retrying via local proxy 127.0.0.1:$_nf_p"
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_nf_o" ]; then
			curl -fsSL -m "$_nf_t" -x "http://127.0.0.1:$_nf_p" -o "$_nf_o" "$_nf_u" 2>/dev/null \
				&& [ -s "$_nf_o" ] && return 0
			rm -f "$_nf_o" 2>/dev/null; return 1
		fi
		_nf_b=$(curl -fsSL -m "$_nf_t" -x "http://127.0.0.1:$_nf_p" "$_nf_u" 2>/dev/null)
		[ -n "$_nf_b" ] && { printf '%s' "$_nf_b"; return 0; }
		return 1
	fi
	if [ -n "$_nf_o" ]; then
		http_proxy="http://127.0.0.1:$_nf_p" https_proxy="http://127.0.0.1:$_nf_p" \
			wget -qO "$_nf_o" --timeout="$_nf_t" "$_nf_u" 2>/dev/null && [ -s "$_nf_o" ] && return 0
		rm -f "$_nf_o" 2>/dev/null; return 1
	fi
	_nf_b=$(http_proxy="http://127.0.0.1:$_nf_p" https_proxy="http://127.0.0.1:$_nf_p" \
		wget -qO- --timeout="$_nf_t" "$_nf_u" 2>/dev/null)
	[ -n "$_nf_b" ] && { printf '%s' "$_nf_b"; return 0; }
	return 1
}

is_p2p_dev() {
	[ -n "$1" ] || return 1
	read -r _p2p 2>/dev/null < "/sys/class/net/$1/flags" || return 1
	case "$_p2p" in 0x*) ;; *) return 1 ;; esac
	[ $(( _p2p & 16 )) -ne 0 ]
}

svc_running() {
	[ -n "$1" ] && [ -x "/etc/init.d/$1" ] || return 1
	ubus -S call service list "{\"name\":\"$1\"}" 2>/dev/null | grep -q '"running": *true' && return 0
	if grep -qE "^status\(\)|^status_service\(\)" "/etc/init.d/$1" 2>/dev/null; then
		/etc/init.d/"$1" status >/dev/null 2>&1
		return $?
	fi
	grep -qE "^[[:space:]]*USE_PROCD=" "/etc/init.d/$1" 2>/dev/null && return 1
	for _sr in /etc/rc.d/S??"$1"; do
		[ -e "$_sr" ] && return 0
	done
	return 1
}

route_add_default() {
	_rad_f="$1"; _rad_d="$2"; _rad_m="$3"; _rad_gw="$4"; _rad_t="$5"
	RAD_METRIC=""
	[ "$_rad_f" = "-4" ] && [ -n "$_rad_gw" ] && \
		ip -4 route add "$_rad_gw" dev "$_rad_d" $_rad_t 2>/dev/null
	_rad_i=0
	while [ "$_rad_i" -lt 9 ]; do
		_rad_mx=$((_rad_m + _rad_i))
		if [ -n "$_rad_gw" ]; then
			_rad_e=$(ip "$_rad_f" route add default via "$_rad_gw" dev "$_rad_d" \
				metric "$_rad_mx" $_rad_t 2>&1) && { RAD_METRIC=$_rad_mx; return 0; }
		else
			_rad_e=$(ip "$_rad_f" route add default dev "$_rad_d" \
				metric "$_rad_mx" scope link $_rad_t 2>&1) && { RAD_METRIC=$_rad_mx; return 0; }
		fi
		case "$_rad_e" in *"File exists"*) ;; *) break ;; esac
		_rad_x=$(ip "$_rad_f" route show default $_rad_t 2>/dev/null \
			| grep -v '^default from ' \
			| grep -E " dev $_rad_d( |$)" \
			| grep -E " metric $_rad_mx( |$)")
		if [ -n "$_rad_gw" ]; then
			printf '%s\n' "$_rad_x" | grep -Fq " via $_rad_gw " && { RAD_METRIC=$_rad_mx; return 0; }
		else
			printf '%s\n' "$_rad_x" | grep -q '^default ' \
				&& ! printf '%s\n' "$_rad_x" | grep -q ' via ' && { RAD_METRIC=$_rad_mx; return 0; }
		fi
		_rad_i=$((_rad_i + 1))
		logger -t 5gmodem "route: metric $((_rad_m + _rad_i - 1)) is taken by another device, trying $((_rad_m + _rad_i)) for $_rad_d"
	done
	logger -t 5gmodem "route: cannot add default ${_rad_gw:+via $_rad_gw }dev $_rad_d metric $_rad_m: $_rad_e"
	return 1
}

extra_uplink_nets() {
	_eu_wan=" $1 "
	_eu_dump=$(ubus call network.interface dump 2>/dev/null)
	[ -n "$_eu_dump" ] || return 0
	ip -4 route show default 2>/dev/null \
		| sed -n 's/.* dev \([^ ]*\).*/\1/p' | sort -u | while read -r _eu_dev; do
		case "$_eu_dev" in
			tun*|tap*|wg*|zt*|vti*|xfrm*|gre*|tailscale*) continue ;;
		esac
		_eu_if=$(printf '%s' "$_eu_dump" \
			| jsonfilter -e "@.interface[@.l3_device=\"$_eu_dev\"].interface" 2>/dev/null | head -1)
		[ -n "$_eu_if" ] || continue
		case "$_eu_if" in loopback) continue ;; esac
		case "$_eu_wan" in *" $_eu_if "*) continue ;; esac
		printf '%s\n' "$_eu_if"
	done
}

cmd_allowed() {
	[ -x /usr/libexec/5gmodem/cmd-policy ] || return 0
	/usr/libexec/5gmodem/cmd-policy "$1" >/dev/null 2>&1 && return 0
	logger -t 5gmodem "command refused by policy: $(printf '%s' "$1" | head -c 120)"
	return 1
}

hl_brovi() {
	case "$(uci -q get "5gmodem.$1.model")" in
		*E33[0-9][0-9]*-325*|*E33[0-9][0-9]s-325*) return 0 ;;
	esac
	return 1
}

hl_web_metrics() {
	case "$(uci -q get "5gmodem.$1.vidpid")" in
		19d2:0581) return 0 ;;
	esac
	hl_brovi "$1"
}

hl_web_port() {
	[ -n "$1" ] || return 1
	for _hwp_s in $(uci -q show 5gmodem 2>/dev/null | grep -F ".at_port='$1'" | cut -d. -f2); do
		hl_web_metrics "$_hwp_s" && return 0
	done
	return 1
}
