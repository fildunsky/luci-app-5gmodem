#!/bin/sh

_NUM="$2"
_TXT="$3"

needucs2() {
	printf '%s' "$1" | LC_ALL=C awk '
		BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i; rc = 1 }
		{ line = $0
		  for (i = 1; i <= length(line); i++) {
			c = ord[substr(line, i, 1)]
			if (c >= 128) { rc = 0 }
		  }
		}
		END { exit rc }
	'
}

_num_pdu() {
	printf '%s' "$1" | awk '
		{
			n = $0
			gsub(/[^0-9+]/, "", n)
			toa = "81"
			if (substr(n, 1, 1) == "+") { toa = "91"; n = substr(n, 2) }
			else if (substr(n, 1, 2) == "00" && length(n) >= 11) { toa = "91"; n = substr(n, 3) }
			gsub(/[^0-9]/, "", n)
			if (toa == "81" && length(n) >= 11 \
			    && substr(n, 1, 1) != "8" && substr(n, 1, 1) != "0") toa = "91"
			len = length(n)
			if (len % 2) n = n "F"
			out = ""
			for (i = 1; i <= length(n); i += 2) out = out substr(n, i + 1, 1) substr(n, i, 1)
			printf "%d %s %s", len, toa, out
		}
	'
}

encode() {
	_e_num="$1"; _e_txt="$2"
	[ -n "$_e_num" ] || return 1

	set -- $(_num_pdu "$_e_num")
	_e_dlen="$1"; _e_toa="$2"; _e_digits="$3"
	[ -n "$_e_dlen" ] && [ "$_e_dlen" -gt 0 ] || return 1

	IFS=' ' read -r _e_up _ < /proc/uptime
	_e_ref=$(( ${_e_up%%.*} % 256 ))

	printf '%s' "$_e_txt" | LC_ALL=C awk -v dlen="$_e_dlen" -v toa="$_e_toa" -v digits="$_e_digits" -v ref="$_e_ref" '
		BEGIN {
			for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
			body = ""
			nl = 0
		}
		{ body = (nl++ ? body "\n" $0 : $0) }
		END {
			n = length(body)
			nu = 0
			i = 1
			while (i <= n) {
				c = ord[substr(body, i, 1)]
				if (c < 0x80) { cp = c; i += 1 }
				else if (c >= 0xC0 && c < 0xE0 && i + 1 <= n) {
					cp = (c - 0xC0) * 64 + (ord[substr(body, i + 1, 1)] - 0x80); i += 2
				}
				else if (c >= 0xE0 && c < 0xF0 && i + 2 <= n) {
					cp = (c - 0xE0) * 4096 + (ord[substr(body, i + 1, 1)] - 0x80) * 64 \
					     + (ord[substr(body, i + 2, 1)] - 0x80); i += 3
				}
				else if (c >= 0xF0 && i + 3 <= n) {
					cp = (c - 0xF0) * 262144 + (ord[substr(body, i + 1, 1)] - 0x80) * 4096 \
					     + (ord[substr(body, i + 2, 1)] - 0x80) * 64 \
					     + (ord[substr(body, i + 3, 1)] - 0x80); i += 4
				}
				else { i += 1; continue }
				if (cp > 0xFFFF) {
					cp -= 0x10000
					units[++nu] = sprintf("%04X", 0xD800 + int(cp / 1024))
					pair[nu] = 1
					units[++nu] = sprintf("%04X", 0xDC00 + (cp % 1024))
					pair[nu] = 2
				} else {
					units[++nu] = sprintf("%04X", cp)
					pair[nu] = 0
				}
			}

			if (nu <= 70) { total = 1; per = 70 } else {
				per = 67; total = 0; u = 1
				while (u <= nu) {
					cnt = 0
					while (u <= nu && cnt < per) {
						if (pair[u] == 1 && cnt + 2 > per) break
						u++; cnt++
					}
					total++
				}
			}

			u = 1
			for (p = 1; p <= total; p++) {
				cnt = 0; ud = ""
				while (u <= nu && cnt < per) {
					if (pair[u] == 1 && cnt + 2 > per) break
					ud = ud units[u]; u++; cnt++
				}
				udlen = cnt * 2                      # payload octets
				if (total > 1) {
					udh = sprintf("050003%02X%02X%02X", ref, total, p)
					fo = "51"                        # SMS-SUBMIT + VP + UDHI
					udl = udlen + 6
					ud = udh ud
				} else {
					fo = "11"
					udl = udlen
				}
				pdu = sprintf("00%s00%02X%s%s0008AA%02X%s", fo, dlen, toa, digits, udl, ud)
				printf "%d %s\n", (length(pdu) / 2) - 1, pdu
			}
		}
	'
}

case "$1" in
	needucs2) needucs2 "$2"; exit $? ;;
	encode)   encode "$_NUM" "$_TXT"; exit $? ;;
	*) echo "usage: $0 needucs2 <text> | encode <number> <text>" >&2; exit 2 ;;
esac
