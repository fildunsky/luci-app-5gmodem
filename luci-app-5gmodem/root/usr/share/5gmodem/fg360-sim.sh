#!/bin/sh

# Do not expose a SIM PIN or an echoed modem command in the response or trace.
set +x
umask 077
. /usr/share/5gmodem/lib.sh

failure() {
	printf '{"ok":false,"error":"%s"}\n' "$1"
	exit 1
}

valid_pin() {
	case "$1" in ''|*[!0123456789]*) return 1 ;; esac
	[ "${#1}" -ge 4 ] && [ "${#1}" -le 8 ]
}

operation="$1"
[ "$2" = ccci ] && [ "$(uci -q get '5gmodem.@5gmodem[0].active_modem')" = ccci ] \
	&& fg360_native "$2" || failure unavailable

case "$operation" in
	status)
		[ "$#" -eq 2 ] || failure invalid_request
		output=$(fg360_at 'AT+CPIN?' normal 5 2 2>/dev/null); result=$?
		case "$result" in 75) failure busy ;; esac
		value=$(printf '%s\n' "$output" | tr -d '\r' | sed -n 's/[[:space:]]*$//; s/^+CPIN:[[:space:]]*//p' | head -1)
		case "$value" in
			READY) state=ready ;;
			'SIM PIN') state=pin ;;
			'SIM PUK') state=puk ;;
			'')
				if printf '%s\n' "$output" | tr -d '\r' | grep -Eiq '^\+CME ERROR:[[:space:]]*(10|SIM not inserted)[[:space:]]*$'; then
					state=missing
				else
					failure unavailable
				fi ;;
			*) state=locked ;;
		esac
		printf '{"ok":true,"state":"%s"}\n' "$state"
		exit 0 ;;
	enter|enable|disable|change) ;;
	*) failure invalid_request ;;
esac

valid_pin "$3" || failure invalid_pin
case "$operation" in
	change)
		[ "$#" -eq 4 ] || failure invalid_request
		valid_pin "$4" || failure invalid_pin
		command="AT+CPWD=\"SC\",\"$3\",\"$4\"" ;;
	*)
		[ "$#" -eq 3 ] || failure invalid_request
		case "$operation" in
			enter) command="AT+CPIN=\"$3\"" ;;
			enable) command="AT+CLCK=\"SC\",1,\"$3\"" ;;
			disable) command="AT+CLCK=\"SC\",0,\"$3\"" ;;
		esac ;;
esac

output=$(fg360_at "$command" high 8 5 2>/dev/null); result=$?
case "$result" in 75) failure busy ;; esac
if [ "$result" -eq 0 ] && printf '%s\n' "$output" | tr -d '\r' | grep -qx OK; then
	printf '{"ok":true}\n'
	exit 0
fi
if printf '%s\n' "$output" | tr -d '\r' | grep -Eiq '^\+CME ERROR:[[:space:]]*(16|incorrect password)[[:space:]]*$'; then
	failure incorrect_pin
fi
if printf '%s\n' "$output" | tr -d '\r' | grep -Eiq '^\+CME ERROR:[[:space:]]*(12|SIM PUK required)[[:space:]]*$'; then
	failure puk_required
fi
failure unconfirmed
