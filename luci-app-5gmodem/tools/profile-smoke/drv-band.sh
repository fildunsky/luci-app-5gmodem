PROFILE="$1"
. "$SMOKE_HERE/prelude.sh"
. "$SMOKE_WORK/fw_band.sh"
. "$SMOKE_SHARE/lib.sh"
RES="$SMOKE_SHARE/modemband"
_AMP="9-9"
_bs_am="9-9"
_bs_sec="m_9_9"
_SIFS="$IFS"
. "$PROFILE"
IFS="$_SIFS"
_DEVICE="$SMOKE_DEV"
echo "@@SMOKE_MARK@@ load"
_run() {
	_fn="$1"
	echo "@@SMOKE_CALL@@ $*"
	echo "@@SMOKE_CALL@@ $*" >&2
	[ -n "$SMOKE_LOG" ] && echo "CALL $*" >> "$SMOKE_LOG"
	_o=$( "$@" )
	printf '%s=%s\n' "$(echo "$*" | tr ' ' '_')" "$(printf '%s' "$_o" | tr '\n' '|')" >> "$SMOKE_VARS"
	echo "@@SMOKE_MARK@@ $*"
}
for _g in getinfo getsupportedbands getsupportedbandsext getbands getbandsext \
	getsupportedbands5gnsa getsupportedbandsext5gnsa getbands5gnsa getbandsext5gnsa \
	getsupportedbands5gsa getsupportedbandsext5gsa getbands5gsa getbandsext5gsa \
	getsupportedmodes getmode getsupportedbands3g getbands3g getsupportedbands2g getbands2g \
	getcelllock getcelllock5g get5gmode getcaenabled get256qam getulca getantports; do
	_run "$_g"
done
_pick() {
	_p=$("$1" 2>/dev/null | tr ' ' '\n' | sed 's/:.*//' | grep -E '^[0-9]+$' | head -n 2 | tr '\n' ' ')
	_p="${_p% }"
	[ -n "$_p" ] || _p="$2"
	printf '%s' "$_p"
}
_run setbands "$(_pick getsupportedbands '1 3')"
_run setbands default
_run setbands5gnsa "$(_pick getsupportedbands5gnsa '78')"
_run setbands5gnsa default
_run setbands5gsa "$(_pick getsupportedbands5gsa '78')"
_run setbands5gsa default
_run setbands3g "$(_pick getsupportedbands3g '1')"
_run setbands2g "$(_pick getsupportedbands2g '3')"
_m=$(_pick getsupportedmodes 1); _m="${_m%% *}"
_run setmode "$_m"
_run setcelllock off
_run setcelllock arfcn 1300
_run setcelllock cell 1300 100
_run setcelllock5g off
_run setcelllock5g cell 630000 100 30 78
_run set5gmode 1
_run set256qam 1
_run set256qam 0
_run setulca 1
_run setulca 0
echo "@@SMOKE_DONE@@"
