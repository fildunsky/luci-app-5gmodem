# Подбор APN по оператору/PLMN/IMSI/ICCID.
#
# Часть modemswitch.sh (см. его шапку): сорсится им, самостоятельно НЕ
# запускается. Все функции перенесены 1:1 при распиле большого файла.

# Подобрать APN по оператору. $1 - имя оператора, $2 - код сети (MCC-MNC).
# Сперва по ИМЕНИ: у MVNO оно своё, а код принадлежит хосту сети (SIM Сбера
# работает на Tele2 и отдаёт её PLMN, но APN нужен сберовский).
# Понижение регистра, пригодное для кириллицы.
#
# tr 'A-ZА-Я' 'a-zа-я' НЕ РАБОТАЕТ: busybox tr обрабатывает БАЙТЫ, а кириллица в
# UTF-8 двухбайтовая. Проверено на роутере - "Тинькофф" превращался в
# "\xd0\xa2инь\xd0\xbaофф"-подобный мусор, и все кириллические образцы в
# apn.list (т-мобайл, тинькоф, сбер, газпром) не могли совпасть НИКОГДА.
# sed работает с UTF-8 последовательностями как с литералами, поэтому годится.
_tolower() {
	printf '%s' "$1" | tr 'A-Z' 'a-z' | sed \
		-e 's/А/а/g;s/Б/б/g;s/В/в/g;s/Г/г/g;s/Д/д/g;s/Е/е/g;s/Ё/ё/g' \
		-e 's/Ж/ж/g;s/З/з/g;s/И/и/g;s/Й/й/g;s/К/к/g;s/Л/л/g;s/М/м/g' \
		-e 's/Н/н/g;s/О/о/g;s/П/п/g;s/Р/р/g;s/С/с/g;s/Т/т/g;s/У/у/g' \
		-e 's/Ф/ф/g;s/Х/х/g;s/Ц/ц/g;s/Ч/ч/g;s/Ш/ш/g;s/Щ/щ/g;s/Ъ/ъ/g' \
		-e 's/Ы/ы/g;s/Ь/ь/g;s/Э/э/g;s/Ю/ю/g;s/Я/я/g'
}

# Порядок поиска APN. Сперва код ИЗ SIM (у MVNO он собственный), затем имя,
# затем код зарегистрированной сети. Так MVNO получает свой APN, а обычная
# симка - прежний результат: её код в IMSI и в сети совпадает.
# ПОДБОР APN. Три слоя, от точного к широкому:
#   1) наши переопределения (apn.list) по коду сети из SIM - для РФ-MVNO,
#      которые мы выверили руками (T-Mobile -> tt и т.п.);
#   2) МИРОВАЯ база providers.tsv по IMSI/ICCID со скорингом специфичности -
#      1459 операторов, покрывает почти любую симку, включая MVNO;
#   3) наши по имени оператора - последний резерв.
apn_pick() {   # $1 - имя, $2 - PLMN сети, $3 - список PLMN из IMSI, $4 - IMSI, $5 - ICCID
	for _sp in $3; do
		_a=$(apn_lookup "" "$_sp") && { echo "$_a"; return 0; }
	done
	_a=$(apn_db_lookup "$4" "$5") && { echo "$_a"; return 0; }
	apn_lookup "$1" "$2"
}

# Подбор из мировой базы providers.tsv (формат и метод скоринга взяты из проекта
# apn-autoconfig, данные - GNOME MBPI + AOSP, см. licenses/PROVIDERS-NOTICE.txt).
# Матч по MCC-MNC (из префикса IMSI), маске IMSI и маске ICCID; выигрывает самая
# специфичная строка. operator_id пуст - сопоставляем по префиксу IMSI, чтобы у
# MVNO подобрать APN его ДОМАШНЕГО кода, а не гостевой сети.
apn_db_lookup() {   # $1 - IMSI, $2 - ICCID
	_db="$RES/providers.tsv"
	[ -f "$_db" ] || return 1
	case "$1" in ''|*[!0-9]*) return 1 ;; esac
	_dbapn=$(awk -F '\t' -v imsi="$1" -v iccid="$2" '
		function wildcard(v) { return v == "-" || v == "*" || v == "" }
		function starts(s, p) { return substr(s, 1, length(p)) == p }
		# Маска: цифры сверяем, "x" - любой символ.
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
			if (!wildcard(mccmnc) && !starts(imsi, mccmnc)) next
			if (!wildcard(imsi_p) && !dmatch(imsi, imsi_p)) next
			if (!wildcard(iccid_p) && iccid != "" && !dmatch(iccid, iccid_p)) next
			s=0
			if (!wildcard(mccmnc)) s += 100 + length(mccmnc)
			if (!wildcard(imsi_p)) s += 200 + length(imsi_p)
			if (!wildcard(iccid_p)) s += 200 + length(iccid_p)
			if (priority !~ /^[0-9]+$/) priority=100
			# Инверсный счёт фиксированной ширины: сортировка переносима на любом
			# busybox, самый специфичный (и с меньшим priority) окажется первым.
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
