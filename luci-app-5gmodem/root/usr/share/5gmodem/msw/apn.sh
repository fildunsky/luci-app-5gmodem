# busybox tr is byte-wise and breaks UTF-8 Cyrillic; see docs/subsystems/autosetup.md#apn-selection
_tolower() {
	printf '%s' "$1" | tr 'A-Z' 'a-z' | sed \
		-e 's/А/а/g;s/Б/б/g;s/В/в/g;s/Г/г/g;s/Д/д/g;s/Е/е/g;s/Ё/ё/g' \
		-e 's/Ж/ж/g;s/З/з/g;s/И/и/g;s/Й/й/g;s/К/к/g;s/Л/л/g;s/М/м/g' \
		-e 's/Н/н/g;s/О/о/g;s/П/п/g;s/Р/р/g;s/С/с/g;s/Т/т/g;s/У/у/g' \
		-e 's/Ф/ф/g;s/Х/х/g;s/Ц/ц/g;s/Ч/ч/g;s/Ш/ш/g;s/Щ/щ/g;s/Ъ/ъ/g' \
		-e 's/Ы/ы/g;s/Ь/ь/g;s/Э/э/g;s/Ю/ю/g;s/Я/я/g'
}

apn_pick() {
	for _sp in $3; do
		_a=$(apn_lookup "" "$_sp") && { echo "$_a"; return 0; }
	done
	_a=$(apn_db_lookup "$4" "$5") && { echo "$_a"; return 0; }
	apn_lookup "$1" "$2"
}

# providers.tsv format and scoring follow apn-autoconfig; data from GNOME MBPI + AOSP, see licenses/PROVIDERS-NOTICE.txt
apn_db_lookup() {
	_db=/etc/5gmodem/providers.tsv
	[ -s "$_db" ] || _db="$RES/providers.tsv"
	[ -f "$_db" ] || return 1
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	_dbapn=$(awk -F '\t' -v imsi="$1" -v iccid="$2" '
		function wildcard(v) { return v == "-" || v == "*" || v == "" }
		function starts(s, p) { return substr(s, 1, length(p)) == p }
		function dmatch(value, pattern,   i, e, a) {
			if (length(value) < length(pattern)) return 0
			for (i = 1; i <= length(pattern); i++) {
				e = substr(pattern, i, 1); a = substr(value, i, 1)
				if (e != "x" && e != a) return 0
			}
			return 1
		}
		/^[[:space:]]*#/ || NF < 8 { next }
		{
			mccmnc=$1; imsi_p=$2; iccid_p=$3; apn=$7; priority=$8
			if (apn ~ /[";\\]/ || apn ~ /[[:cntrl:]]/) next
			if (mccmnc == "44011" && apn ~ /^mopera\./) next
			if (!wildcard(mccmnc) && !starts(imsi, mccmnc)) next
			if (!wildcard(imsi_p) && !dmatch(imsi, imsi_p)) next
			if (!wildcard(iccid_p) && iccid != "" && !dmatch(iccid, iccid_p)) next
			s=0
			if (!wildcard(mccmnc)) s += 100 + length(mccmnc)
			if (!wildcard(imsi_p)) s += 200 + length(imsi_p)
			if (!wildcard(iccid_p)) s += 200 + length(iccid_p)
			if (priority !~ /^[0-9]+$/) priority=100
			printf "%06d\t%06d\t%s\n", 999999 - s, priority, apn
		}
	' "$_db" | sort | head -1 | cut -f3)
	[ -n "$_dbapn" ] && { echo "$_dbapn"; return 0; }
	return 1
}

apn_lookup() {
	_n=$(_tolower "$1")
	_p="$2"
	[ -f "$RES/apn.list" ] || return 1
	if [ -n "$_n" ]; then
		while IFS=: read -r _t _pat _apn; do
			case "$_t" in name) : ;; *) continue ;; esac
			[ -n "$_pat" ] || continue
			case "$_n" in *"$_pat"*) echo "$_apn"; return 0 ;; esac
		done < "$RES/apn.list"
	fi
	if [ -n "$_p" ]; then
		while IFS=: read -r _t _pat _apn; do
			case "$_t" in plmn) : ;; *) continue ;; esac
			[ "$_pat" = "$_p" ] && { echo "$_apn"; return 0; }
		done < "$RES/apn.list"
	fi
	return 1
}
