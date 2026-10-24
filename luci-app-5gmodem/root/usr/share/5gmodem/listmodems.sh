#!/bin/sh

CACHE=/tmp/5gmodem/listmodems.cache
STAMP=/tmp/5gmodem/listmodems.stamp
TTL=8

uptime_s() {
	IFS=' ' read -r _us _ < /proc/uptime
	printf '%s\n' "${_us%%.*}"
}

if [ "$1" = "--refresh" ]; then
	rm -f "$CACHE" "$STAMP"
elif [ -s "$CACHE" ]; then
	IFS=' ' read -r _now _ < /proc/uptime; _now="${_now%%.*}"
	_then=""; read -r _then 2>/dev/null < "$STAMP"
	case "$_then" in ''|*[!0-9]*) _then="" ;; esac
	if [ -n "$_then" ] && [ "$((_now - _then))" -ge 0 ] && [ "$((_now - _then))" -lt "$TTL" ]; then
		cat "$CACHE"
		exit 0
	fi
fi

esc() {
	case "$1" in
		*\\*|*\"*) echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ;;
		*) echo "$1" ;;
	esac
}

[ -r /usr/share/5gmodem/lib.sh ] && . /usr/share/5gmodem/lib.sh
[ -r /usr/share/5gmodem/notmodem.sh ] && . /usr/share/5gmodem/notmodem.sh

owner_node() {
	b=$(basename "$1")
	p=$(readlink -f "/sys/class/tty/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/usbmisc/$b/device" 2>/dev/null)
	[ -n "$p" ] || p=$(readlink -f "/sys/class/net/$b/device" 2>/dev/null)
	while [ -n "$p" ] && [ "$p" != "/" ] && [ ! -f "$p/idVendor" ]; do p="${p%/*}"; done
	[ -f "$p/idVendor" ] && echo "$p"
}

NODES=""
NCNT=0
NL='
'
PORTREC=""
SKIPNODES=""
for t in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/wwan*; do
	[ -e "$t" ] || continue
	n=$(owner_node "$t")
	[ -n "$n" ] || continue

	idx=""
	i=1
	for known in $NODES; do
		[ "$known" = "$n" ] && { idx=$i; break; }
		i=$((i + 1))
	done
	if [ -z "$idx" ]; then
		case " $SKIPNODES " in *" $n "*) continue ;; esac
		if command -v usb_is_modem >/dev/null 2>&1 && ! usb_is_modem "$n"; then
			SKIPNODES="$SKIPNODES $n"
			continue
		fi
		NCNT=$((NCNT + 1)); idx=$NCNT
		NODES="$NODES $n"
	fi

	case "$t" in
		/dev/ttyUSB*|/dev/ttyACM*) PORTREC="${PORTREC}${idx} tty ${t}${NL}" ;;
		*)                         PORTREC="${PORTREC}${idx} wdm ${t}${NL}" ;;
	esac
done

for _wpt in /sys/class/wwan/*; do
	[ -e "$_wpt/device" ] || continue
	_wnode="/dev/${_wpt##*/}"
	[ -c "$_wnode" ] || continue
	_wdev=$(readlink -f "$_wpt/device" 2>/dev/null)
	_wpci=""
	while [ -n "$_wdev" ] && [ "$_wdev" != "/" ] && [ "$_wdev" != "/sys" ]; do
		[ -f "$_wdev/idVendor" ] && break
		if [ -e "/sys/bus/pci/devices/${_wdev##*/}" ]; then _wpci="$_wdev"; break; fi
		if [ -d "$_wdev/remoteproc" ]; then _wpci="$_wdev"; break; fi
		_wdev="${_wdev%/*}"
	done
	[ -n "$_wpci" ] || continue

	idx=""
	i=1
	for known in $NODES; do
		[ "$known" = "$_wpci" ] && { idx=$i; break; }
		i=$((i + 1))
	done
	if [ -z "$idx" ]; then
		NCNT=$((NCNT + 1)); idx=$NCNT
		NODES="$NODES $_wpci"
	fi
	case "${_wpt##*/}" in
		*at*) PORTREC="${PORTREC}${idx} tty ${_wnode}${NL}" ;;
		*)    PORTREC="${PORTREC}${idx} wdm ${_wnode}${NL}" ;;
	esac
done

if [ -e /dev/ttyMTK0 ] && command -v soc_modem_node >/dev/null 2>&1 && soc_modem_node ccci >/dev/null; then
	NCNT=$((NCNT + 1))
	NODES="$NODES /sys/kernel/ccci"
	PORTREC="${PORTREC}${NCNT} tty /dev/ttyMTK0${NL}"
	[ -d /sys/class/net/ccmni0 ] && PORTREC="${PORTREC}${NCNT} net ccmni0${NL}"
fi

_HILINK_VENDORS="12d1 19d2 1bbb 2001 0421 1546 2020 05c6 1076 0846"
for _nd in /sys/class/net/*; do
	[ -e "$_nd/device" ] || continue
	_dev=$(readlink -f "$_nd/device" 2>/dev/null)
	while [ -n "$_dev" ] && [ "$_dev" != "/" ] && [ ! -f "$_dev/idVendor" ]; do _dev="${_dev%/*}"; done
	[ -f "$_dev/idVendor" ] || continue
	_v=$(cat "$_dev/idVendor" 2>/dev/null)
	case " $_HILINK_VENDORS " in *" $_v "*) ;; *) continue ;; esac
	case " $NODES " in *" $_dev "*) continue ;; esac
	_hasff=0
	for _if in "$_dev"/*:*; do
		[ -f "$_if/bInterfaceClass" ] || continue
		[ "$(cat "$_if/bInterfaceClass" 2>/dev/null)" = "ff" ] && { _hasff=1; break; }
	done
	[ "$_hasff" = "1" ] && continue
	NCNT=$((NCNT + 1))
	NODES="$NODES $_dev"
	PORTREC="${PORTREC}${NCNT} net $(basename "$_nd")${NL}"
done

for _nd in /sys/class/net/*; do
	[ -e "$_nd/device" ] || continue
	_dev=$(readlink -f "$_nd/device" 2>/dev/null)
	while [ -n "$_dev" ] && [ -n "${_dev%/}" ] && [ "$_dev" != "/" ] && [ ! -f "$_dev/idVendor" ]; do _dev="${_dev%/*}"; done
	[ -f "$_dev/idVendor" ] || continue
	case " $NODES " in *" $_dev "*) continue ;; esac
	_tskip=0
	for _tp in "$_dev"/*:*/ttyUSB* "$_dev"/*:*/tty/tty* "$_dev"/*:*/usbmisc/*; do
		[ -e "$_tp" ] && { _tskip=1; break; }
	done
	[ "$_tskip" = 1 ] && continue
	_tkm=0
	command -v known_modem_path >/dev/null 2>&1 && known_modem_path "${_dev##*/}" && _tkm=1
	_trndis=0
	for _if in "$_dev"/*:*; do
		[ -f "$_if/bInterfaceClass" ] || continue
		case "$(cat "$_if/bInterfaceClass" 2>/dev/null)/$(cat "$_if/bInterfaceSubClass" 2>/dev/null)/$(cat "$_if/bInterfaceProtocol" 2>/dev/null)" in
			ef/04/01|e0/01/03) _trndis=1; break ;;
			02/0d/*|02/06/*) _trndis=2 ;;
		esac
	done
	if [ "$_trndis" = 2 ]; then
		_trndis=$_tkm
		read -r _tcv < "$_dev/idVendor"
		command -v tether_cdc_vid >/dev/null 2>&1 && tether_cdc_vid "$_tcv" && _trndis=1
	fi
	[ "$_trndis" = 1 ] || continue
	NCNT=$((NCNT + 1))
	NODES="$NODES $_dev"
	PORTREC="${PORTREC}${NCNT} net $(basename "$_nd")${NL}"
done

command -v is_iphone >/dev/null 2>&1 && for _ad in /sys/bus/usb/devices/*; do
	case "${_ad##*/}" in *:*|usb*) continue ;; esac
	[ -f "$_ad/idVendor" ] || continue
	read -r _adv < "$_ad/idVendor"
	[ "$_adv" = 05ac ] || continue
	is_iphone "${_ad##*/}" || continue
	_adr=$(readlink -f "$_ad" 2>/dev/null)
	[ -n "$_adr" ] || continue
	case " $NODES " in *" $_adr "*) continue ;; esac
	NCNT=$((NCNT + 1))
	NODES="$NODES $_adr"
	_adn=$(iphone_netdev "${_ad##*/}")
	[ -n "$_adn" ] && PORTREC="${PORTREC}${NCNT} net ${_adn}${NL}"
done

for _ts in $(uci -q show 5gmodem 2>/dev/null | sed -n "s/^5gmodem\.\(m_[^.=]*\)=modem\$/\1/p"); do
	_tp=$(uci -q get "5gmodem.$_ts.path")
	case "$_tp" in *-*) ;; *) continue ;; esac
	_td=$(readlink -f "/sys/bus/usb/devices/$_tp" 2>/dev/null)
	[ -n "$_td" ] && [ -f "$_td/idVendor" ] || continue
	case " $NODES " in *" $_td "*) continue ;; esac
	_tsv=$(uci -q get "5gmodem.$_ts.vidpid"); _tsv="${_tsv%%:*}"
	[ -n "$_tsv" ] && [ "$(cat "$_td/idVendor" 2>/dev/null)" = "$_tsv" ] || continue
	_tn=""
	for _ti in /sys/bus/usb/devices/"$_tp":*/net/*; do
		[ -e "$_ti" ] && { _tn=$(basename "$_ti"); break; }
	done
	[ -n "$_tn" ] || continue
	NCNT=$((NCNT + 1))
	NODES="$NODES $_td"
	PORTREC="${PORTREC}${NCNT} net ${_tn}${NL}"
done

_UCISNAP=$(uci -q show 5gmodem 2>/dev/null)
_ALIASMAP=$(printf '%s\n' "$_UCISNAP" | awk -F"[.=]" '
	/\.alias_imei=/ { gsub(/^.|.$/, "", $NF); imei[$2] = $NF; next }
	/\.alias=/       { line = $0; sub(/^[^=]*=/, "", line); gsub(/^.|.$/, "", line); nm[$2] = line }
	END { for (s in nm) if (nm[s] != "" && imei[s] != "") printf "%s\t%s\n", imei[s], nm[s] }')
_IMEIS_PRESENT=""
for _n in $NODES; do
	_p=$(basename "$_n")
	_s="m_$(echo "$_p" | sed 's/[^A-Za-z0-9]/_/g')"
	_im=$(printf '%s\n' "$_UCISNAP" | sed -n "s/^5gmodem\.$_s\.imei='\(.*\)'\$/\1/p" | head -1)
	[ -n "$_im" ] && _IMEIS_PRESENT="$_IMEIS_PRESENT$_im
"
done

OUT=""
i=0
for n in $NODES; do
	i=$((i + 1))
	path=$(basename "$n")
	vid=$(cat "$n/idVendor" 2>/dev/null)
	pid=$(cat "$n/idProduct" 2>/dev/null)
	if [ -z "$vid" ] && [ -f "$n/vendor" ] && [ -f "$n/device" ]; then
		vid=$(cat "$n/vendor" 2>/dev/null); vid="${vid#0x}"
		pid=$(cat "$n/device" 2>/dev/null); pid="${pid#0x}"
	fi
	_soc=""
	if [ -z "$vid" ] && { [ -d "$n/remoteproc" ] || [ "$n" = /sys/kernel/ccci ]; } && command -v soc_modem_vidpid >/dev/null 2>&1; then
		_soc=1
		vid=$(soc_modem_vidpid); pid="${vid#*:}"; vid="${vid%%:*}"
	fi
	prod=$(esc "$(cat "$n/product" 2>/dev/null)")
	[ -n "$_soc" ] && prod=$(esc "$(soc_modem_model)")
	ttys=""; wdms=""; nets=""
	while read -r _ri _rt _rp; do
		[ "$_ri" = "$i" ] || continue
		case "$_rt" in
			tty) ttys="${ttys}${ttys:+,}\"$_rp\"" ;;
			wdm) wdms="${wdms}${wdms:+,}\"$_rp\"" ;;
			net) nets="${nets}${nets:+,}\"$_rp\"" ;;
		esac
	done <<PORTREC_EOF
$PORTREC
PORTREC_EOF
	_sec="m_$(echo "$path" | sed 's/[^A-Za-z0-9]/_/g')"
	model=$(uci -q get "5gmodem.$_sec.model" 2>/dev/null)
	case "$model" in
		*OK*) command -v at_strip_ok >/dev/null 2>&1 && model=$(at_strip_ok "$model") ;;
	esac
	[ -n "$model" ] && model=$(model_alias "$model")
	if [ -n "$model" ] && command -v _model_vendor_ok >/dev/null 2>&1 \
	   && ! _model_vendor_ok "$model" "$vid:$pid"; then
		model=""
	fi
	_mv=$(uci -q get "5gmodem.$_sec.model_vp" 2>/dev/null)
	[ -n "$_mv" ] && [ "$_mv" != "$vid:$pid" ] && model=""
	if [ -z "$model" ]; then
		_prodraw=$(cat "$n/product" 2>/dev/null)
		model=$(model_alias "$_prodraw")
		case "$model" in
			*\ Snapdragon\ *) model=$(printf '%s' "$model" | sed 's/ Snapdragon .*$//') ;;
		esac

		case "$_prodraw" in
			*Generic\ Mobile\ Broadband*|*HSUSB\ Device*|*Mobile\ Broadband\ Adapter*)
				case "$vid:$pid" in
					05c6:90d5|05c6:9025|1e2d:00b7|1e2d:00b8) model="T99W175" ;;
					*) model="$vid:$pid" ;;
				esac
				;;
		esac
	fi
	[ -z "$model" ] && [ -n "$_soc" ] && model="$prod"
	[ -z "$model" ] && [ -n "$vid" ] && [ ! -f "$n/product" ] && model="$vid:$pid"
	model=$(esc "$model")
	_opname=""
	_opif=$(uci -q get "5gmodem.$_sec.network" 2>/dev/null)
	[ -n "$_opif" ] && [ -s "/tmp/5gmodem/op_$_opif" ] && \
		_opname=$(esc "$(cat "/tmp/5gmodem/op_$_opif" 2>/dev/null | tr -d '\n')")
	[ -z "$_opname" ] && [ -n "$_opif" ] && [ -s "/tmp/5gmodem/netpri_op_$_opif" ] && \
		_opname=$(esc "$(cat "/tmp/5gmodem/netpri_op_$_opif" 2>/dev/null | tr -d '\n')")
	[ -n "$OUT" ] && OUT="$OUT,"
	_alias=""
	_myimei=$(uci -q get "5gmodem.$_sec.imei" 2>/dev/null)
	if [ -n "$_myimei" ] && [ "$(printf '%s\n' "$_IMEIS_PRESENT" | grep -c "^$_myimei\$")" = 1 ]; then
		_alias=$(printf '%s\n' "$_ALIASMAP" | sed -n "s/^$_myimei	//p" | head -1)
	fi
	if [ -z "$_alias" ]; then
		_seca=$(printf '%s\n' "$_UCISNAP" | sed -n "s/^5gmodem\.$_sec\.alias='\(.*\)'\$/\1/p" | head -1)
		if [ -n "$_seca" ]; then
			_secam=$(printf '%s\n' "$_UCISNAP" | sed -n "s/^5gmodem\.$_sec\.alias_imei='\(.*\)'\$/\1/p" | head -1)
			if [ -z "$_secam" ] || [ "$_secam" = "$_myimei" ]; then
				_alias="$_seca"
			fi
		fi
	fi
	_alias=$(esc "$_alias")
	_tx=""
	if [ "$vid" = 05ac ] && command -v is_iphone >/dev/null 2>&1 && is_iphone "$path"; then
		_tx=",\"tether\":\"iphone\",\"tether_state\":\"$(iphone_state "$path")\""
	else
		case "$_UCISNAP" in
			*"5gmodem.$_sec.kind='tether'"*)
				if ! { command -v known_modem_path >/dev/null 2>&1 && known_modem_path "$path"; }; then
					_txs=ready; [ -n "$nets" ] || _txs=no_netdev
					_txo=phone; command -v tether_os >/dev/null 2>&1 && _txo=$(tether_os "$path")
					_tx=",\"tether\":\"$_txo\",\"tether_state\":\"$_txs\""
				fi ;;
		esac
	fi
	OUT="$OUT{\"path\":\"$path\",\"vidpid\":\"$vid:$pid\",\"product\":\"$prod\",\"model\":\"$model\",\"alias\":\"$_alias\",\"serial\":\"$(esc "$(serial_of "$n")")\",\"operator\":\"$_opname\",\"tty\":[$ttys],\"wdm\":[$wdms],\"net\":[$nets]$_tx}"
done
OUT="[$OUT]"

printf '%s\n' "$OUT" > "$CACHE.tmp.$$" 2>/dev/null && mv "$CACHE.tmp.$$" "$CACHE" 2>/dev/null
uptime_s > "$STAMP" 2>/dev/null

printf '%s\n' "$OUT"
