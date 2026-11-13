AT_LOCK_FD=8

at_lock() {
	[ -n "$1" ] || return 0
	_al_key="${1##*/}"
	[ "$_AT_LOCK_HELD" = "$_al_key" ] && return 0
	if [ -n "$_AT_LOCK_HELD" ]; then
		logger -t 5gmodem "at_lock: refused - already holding '$_AT_LOCK_HELD', requested '$_al_key' (at_unlock first)"
		return 1
	fi
	_al_d=/var/lock
	[ -d "$_al_d" ] || _al_d=/tmp
	_al_f="$_al_d/5gmodem-at-$_al_key.lock"
	eval "exec $AT_LOCK_FD>\"\$_al_f\"" 2>/dev/null || return 0
	_al_max="${2:-10}"
	if flock -n "$AT_LOCK_FD" 2>/dev/null; then
		_AT_LOCK_HELD="$_al_key"; export _AT_LOCK_HELD
		return 0
	fi
	( flock "$AT_LOCK_FD" ) 2>/dev/null & _al_p=$!
	# the sleep dies with the watchdog; a bare "sleep; kill" kept it (and the caller's other fds) for the whole wait
	( eval "exec $AT_LOCK_FD>&-"; sleep "$_al_max" & _al_s=$!
	  trap 'kill $_al_s 2>/dev/null; exit' TERM; wait $_al_s; kill "$_al_p" 2>/dev/null ) \
		>/dev/null 2>&1 </dev/null & _al_w=$!
	if wait "$_al_p" 2>/dev/null; then
		kill "$_al_w" 2>/dev/null; wait "$_al_w" 2>/dev/null
		_AT_LOCK_HELD="$_al_key"; export _AT_LOCK_HELD
		return 0
	fi
	kill "$_al_w" 2>/dev/null; wait "$_al_w" 2>/dev/null
	flock -u "$AT_LOCK_FD" 2>/dev/null
	eval "exec $AT_LOCK_FD>&-" 2>/dev/null
	logger -t 5gmodem "at_lock: port $1 busy for over ${_al_max}s"
	command -v _at_recover >/dev/null 2>&1 && _at_recover "$1"
	return 1
}

at_unlock() {
	flock -u "$AT_LOCK_FD" 2>/dev/null
	eval "exec $AT_LOCK_FD>&-" 2>/dev/null
	unset _AT_LOCK_HELD
	return 0
}

at_long_begin() {
	_alb_f="/tmp/5gmodem/atlong_${1##*/}"
	mkdir -p /tmp/5gmodem 2>/dev/null
	read -r _alb_pid _ < /proc/self/stat
	printf '%s\n' "$_alb_pid" > "$_alb_f" 2>/dev/null
}

at_long_end() {
	rm -f "/tmp/5gmodem/atlong_${1##*/}" 2>/dev/null
}

at_long_busy() {
	[ -n "$1" ] || return 1
	_alw_f="/tmp/5gmodem/atlong_${1##*/}"
	[ -f "$_alw_f" ] || return 1
	read -r _alw_pid < "$_alw_f" 2>/dev/null
	if [ -n "$_alw_pid" ] && kill -0 "$_alw_pid" 2>/dev/null \
	   && [ -n "$(find "$_alw_f" -mmin -6 2>/dev/null)" ]; then
		return 0
	fi
	rm -f "$_alw_f" 2>/dev/null
	return 1
}

_at_recover() {
	[ -x "${RES:-/usr/share/5gmodem}/at-recover.sh" ] || return 0
	( unset _AT_LOCK_HELD; exec 7>&- 8>&- 9>&-;
	  exec "${RES:-/usr/share/5gmodem}/at-recover.sh" "$1" ) >/dev/null 2>&1 </dev/null &
}
