#!/bin/sh

# Native OLAX profile. Android owns the radio; use its stock management endpoint.
. /usr/share/5gmodem/mt60-web.sh
mt60_native || exit 1

band_numbers() {
	jsonfilter -s "$1" -e "@.$2[*].band_key" 2>/dev/null |
		sed -n 's/^Band\([1-9][0-9]\{0,2\}\)$/\1/p' | sort -nu | xargs
}

read_bands() {
	reply=$(mt60_web_get band_list) || return 1
	supported=$(band_numbers "$reply" band_list)
	[ -n "$supported" ] || return 1
	actual=$(band_numbers "$reply" current_band_list)
	[ -n "$actual" ] || return 1
	enabled=""
	for band in $supported; do
		case " $actual " in *" $band "*) enabled="${enabled:+$enabled }$band" ;; esac
	done
	[ -n "$enabled" ]
}

legacy_bridge_ready() {
	local snapshot="$1/metrics.json" now="$2" app stamp
	[ -s "$snapshot" ] || return 1
	app=$(jsonfilter -i "$snapshot" -e '@.app' 2>/dev/null)
	# The fallback Android app writes basic telemetry but does not serve band requests.
	case "$app" in ''|false) ;; *) return 1 ;; esac
	stamp=$(jsonfilter -i "$snapshot" -e '@.sampled_uptime' 2>/dev/null) || return 1
	case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
	case "$now" in ''|*[!0-9]*) return 1 ;; esac
	[ "$stamp" -le "$now" ] && [ "$((now - stamp))" -lt 12 ]
}

legacy_bands() (
	dir=/tmp/mt60-radio
	read -r uptime _ < /proc/uptime || return 1
	now=${uptime%%.*}
	if ! legacy_bridge_ready "$dir" "$now"; then
		echo '{"error":"radio_unavailable"}'
		return 1
	fi
	umask 077
	mkdir "$dir/bands.lock" 2>/dev/null || return 1
	trap 'rm -f "$dir/bands.request" "$dir/bands.tmp"; rmdir "$dir/bands.lock"' EXIT
	trap 'exit 143' INT TERM HUP
	id=$$
	rm -f "$dir/bands.reply"
	printf '%s|%s|%s|%s\n' "$id" "$now" "$1" "$2" > "$dir/bands.tmp" &&
		mv -f "$dir/bands.tmp" "$dir/bands.request" || return 1
	for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
		if [ -s "$dir/bands.reply" ]; then
			answer=$(cat "$dir/bands.reply")
			if [ "$(jsonfilter -s "$answer" -e '@.id')" = "$id" ]; then
				printf '%s\n' "$answer"
				[ "$(jsonfilter -s "$answer" -e '@.ok')" = true ]
				return
			fi
		fi
		sleep 1
	done
	return 1
)

legacy_json() {
	legacy=$(legacy_bands '' '') || return 0
	for rat in 2g 3g; do
		bands=$(jsonfilter -s "$legacy" -e "@.supported$rat[*]")
		[ -n "$bands" ] || continue
		json_add_array "supported$rat"
		for band in $bands; do
			json_add_object ''
			json_add_int band "$band"
			json_close_object
		done
		json_close_array
		json_add_array "enabled$rat"
		for band in $(jsonfilter -s "$legacy" -e "@.enabled$rat[*]"); do
			json_add_int '' "$band"
		done
		json_close_array
	done
}

json_bands() (
	. /usr/share/libubox/jshn.sh
	json_init
	json_add_string modem 'OLAX MT60'
	json_add_boolean bandwarn 1
	json_add_array supported
	for band in $supported; do
		json_add_object ''
		json_add_int band "$band"
		json_add_string txt "B$band"
		json_close_object
	done
	json_close_array
	json_add_array enabled
	for band in $enabled; do json_add_int '' "$band"; done
	json_close_array
	legacy_json
	json_dump
)

set_bands() (
	wanted="$1"
	[ "$wanted" != default ] || wanted="$supported"
	case "$wanted" in ''|*[!0-9\ ]*) return 1 ;; esac
	wanted=$(printf '%s\n' $wanted | sort -nu | xargs)
	[ -n "$wanted" ] || return 1
	[ "$wanted" != "$enabled" ] || return 0
	payload=""
	for band in $wanted; do
		case " $supported " in *" $band "*) ;; *) return 1 ;; esac
		payload="${payload:+$payload,}\"Band$band\""
	done
	sim=$(jsonfilter -s "$reply" -e '@.simId')
	case "$sim" in ''|*[!0-9]*) return 1 ;; esac

	umask 077
	jar=$(mktemp /tmp/mt60-band-cookies.XXXXXX) || return 1
	trap 'rm -f "$jar"' EXIT
	mt60_login "$jar" || return 1
	result=$(mt60_web_post "$jar" --data "goformId=SET_BAND&simId=$sim" \
		--data-urlencode "band_list=[$payload]") || return 1
	[ "$(jsonfilter -s "$result" -e '@.result')" = success ] || return 1
	for delay in 0 1 1; do
		[ "$delay" = 0 ] || sleep "$delay"
		if read_bands && [ "$enabled" = "$wanted" ]; then return 0; fi
	done
	return 1
)

case "$1" in
	json)
		if read_bands; then json_bands; else echo '{"modem":"OLAX MT60","nobandctl":1}'; fi ;;
	getbands) read_bands && printf '%s\n' "$enabled" ;;
	getsupportedbands) read_bands && printf '%s\n' "$supported" ;;
	setbands) read_bands && set_bands "$2" ;;
	legacy) legacy_bands "$2" "$3" ;;
	getbands2g|getbands3g|getsupportedbands2g|getsupportedbands3g)
		rat=${1#*bands}
		case "$1" in getsupported*) field=supported ;; *) field=enabled ;; esac
		result=$(legacy_bands '' '') || exit 1
		jsonfilter -s "$result" -e "@.$field$rat[*]" | xargs ;;
	setbands2g) legacy_bands "$2" '' ;;
	setbands3g) legacy_bands '' "$2" ;;
	*) exit 1 ;;
esac
