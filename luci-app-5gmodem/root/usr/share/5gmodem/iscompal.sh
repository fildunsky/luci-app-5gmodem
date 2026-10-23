#!/bin/sh

is_compal() {
	_ic_path="$1"
	_ic_wdm="$2"
	_ic_at="$3"

	if [ -n "$_ic_path" ]; then
		if [ -r "/sys/bus/usb/devices/$_ic_path/product" ]; then
			case "$(cat "/sys/bus/usb/devices/$_ic_path/product" 2>/dev/null)" in
				*VOS_5G*|*RXMG1*|*RXM-G1*|*SG500M2*) return 0 ;;
			esac
			case "$(cat "/sys/bus/usb/devices/$_ic_path/manufacturer" 2>/dev/null)" in
				*Tri\ Cascade*) return 0 ;;
			esac
		fi
	else
		grep -qiE "VOS_5G|RXMG1|RXM-G1|SG500M2" /sys/bus/usb/devices/*/product 2>/dev/null && return 0
		grep -qiE "Product=VOS_5G|Product=Compal RXM-G1|Manufacturer=Tri Cascade" \
			/sys/kernel/debug/usb/devices 2>/dev/null && return 0
	fi

	_ic_wdm_explicit="$_ic_wdm"
	if [ -z "$_ic_wdm" ] && [ -n "$_ic_path" ]; then
		_ic_wdm=$(/usr/share/5gmodem/modemswitch.sh wdm "$_ic_path" 2>/dev/null)
	elif [ -z "$_ic_wdm" ]; then
		_ic_wdm=$(/usr/share/5gmodem/modemswitch.sh wdm 2>/dev/null)
		[ -c "$_ic_wdm" ] || _ic_wdm=/dev/cdc-wdm0
	fi
	if [ -c "$_ic_wdm" ] && command -v qmicli >/dev/null 2>&1; then
		_ic_model=$(qmicli_p "$_ic_wdm" --dms-get-model 2>/dev/null \
			| sed -n "s/.*Model: '\{0,1\}\([^']*\)'\{0,1\}.*/\1/p" | head -1)
		case "$_ic_model" in *SG500M2-X*) return 0 ;; esac
		[ -n "$_ic_wdm_explicit" ] && [ -n "$_ic_model" ] && return 1
	fi

	if command -v mmcli >/dev/null 2>&1; then
		_ic_mi=$(/usr/share/5gmodem/modemswitch.sh mmindex ${_ic_path:+"$_ic_path"} 2>/dev/null)
		[ -n "$_ic_mi" ] || _ic_mi=any
		_ic_mk=$(mmcli -m "$_ic_mi" -K 2>/dev/null)
		if [ -n "$_ic_path" ]; then
			printf '%s\n' "$_ic_mk" | grep -q "modem\.generic\.device .*/$_ic_path\$" || _ic_mk=""
		fi
		printf '%s\n' "$_ic_mk" | grep -qE "RXMG1|RXM-G1|SG500M2-X" && return 0
	fi

	if [ -n "$_ic_at" ] && [ -c "$_ic_at" ]; then
		at_query "$_ic_at" "AT+CGMM" 6 | grep -qE "SG500M2-X|RXM-G1|RXMG1" && return 0
	fi

	return 1
}

case "$0" in
	*iscompal.sh) is_compal "$@" ;;
esac
