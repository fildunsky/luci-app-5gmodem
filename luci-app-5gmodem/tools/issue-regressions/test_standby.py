import os
import tempfile
import unittest

from test_runtime_audit import function, shell


class Standby(unittest.TestCase):
    def run_shell(self, source):
        with tempfile.TemporaryDirectory() as temp:
            env = {**os.environ, 'RUN_DIR': temp, 'FLAG': f'{temp}/standby'}
            result = shell('standby_active() { [ -e "$FLAG" ]; }\n' + source, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()

    def test_delayed_recovery_checks_standby_after_sleep(self):
        source = '\n'.join([
            function('_stray_redial', 'sessionwatch.sh').replace('/tmp/5gmodem', '$RUN_DIR'),
            function('_restart_interface', 'sessionwatch.sh'),
            function('_heal_cmd', 'health.sh'),
            function('_heal_reconnect', 'health.sh'),
            r'''
sleep() { [ "$PAUSE" != 1 ] || : > "$FLAG"; }
ifdown() { echo "down $1"; }
ifup() { echo "up $1"; }
iface_up() { ifup "$1"; }
PAUSE=1
_stray_redial wan
rm -f "$FLAG"
_restart_interface modem
rm -f "$FLAG"
_heal_reconnect wwan
rm -f "$FLAG"
PAUSE=0
_stray_redial wan
_restart_interface modem
_heal_reconnect wwan
'''])
        self.assertEqual(self.run_shell(source), [
            'down modem', 'down wwan', 'up wan', 'down modem', 'up modem', 'down wwan', 'up wwan',
        ])

    def test_watchdog_checks_before_and_after_probe(self):
        source = '\n'.join([
            function('_heal_cmd', 'health.sh'),
            function('_watchdog_round', 'health.sh'),
            r'''
round() { echo probe; [ "$PAUSE" != 1 ] || : > "$FLAG"; }
enforce() { echo enforce; }
heal() { echo heal; }
: > "$FLAG"
_watchdog_round heal
rm -f "$FLAG"
PAUSE=1
_watchdog_round heal
rm -f "$FLAG"
PAUSE=0
_watchdog_round heal
'''])
        self.assertEqual(self.run_shell(source), ['probe', 'probe', 'enforce', 'heal'])

    def test_queued_standby_cleanup_rechecks_marker_after_lock(self):
        source = function('_off_cleanup', 'health.sh').replace('/tmp/5gmodem', '$RUN_DIR') + r'''
HDIR="$RUN_DIR/state"
mkdir "$HDIR"
flock() {
	if [ "$BUSY" = 1 ]; then
		[ "$1" = -n ] || echo blocking
		return 1
	fi
	[ "$RESUME" != 1 ] || rm -f "$FLAG"
}
_teardown() { echo cleanup; }
uplink_notify() { echo notify; }
: > "$FLAG"
BUSY=1
( _off_cleanup standby )
BUSY=0
RESUME=1
( _off_cleanup standby )
: > "$FLAG"
RESUME=0
( _off_cleanup standby )
'''
        self.assertEqual(self.run_shell(source), ['cleanup', 'notify'])

    def test_detached_healing_drops_watchdog_descriptor(self):
        source = '\n'.join([
            function('_heal_cmd', 'health.sh'),
            function('_heal_start', 'health.sh'),
            r'''
record() { [ ! -e /proc/self/fd/9 ] && echo ran > "$RUN_DIR/result"; }
exec 9>"$RUN_DIR/health.lock"
: > "$FLAG"
_heal_start record
wait
[ ! -e "$RUN_DIR/result" ] || exit 1
rm -f "$FLAG"
_heal_start record
wait
cat "$RUN_DIR/result"
'''])
        self.assertEqual(self.run_shell(source), ['ran'])

    def test_protocol_registration_defers_and_retries_after_resume(self):
        source = function('_start_protoguard', 'sessionwatch.sh').replace('/tmp/5gmodem', '$RUN_DIR') + r'''
sleep() { [ "$PAUSE" != 1 ] || : > "$FLAG"; }
ubus() { :; }
uci() { echo "network.modem.proto='fibocom'"; }
logger() { :; }
RES="$RUN_DIR"
printf '#!/bin/sh\necho registered > "$RUN_DIR/result"\n' > "$RES/register_proto.sh"
chmod +x "$RES/register_proto.sh"
PAUSE=1
_start_protoguard
wait
[ ! -e "$RUN_DIR/protoguard" ] && [ ! -e "$RUN_DIR/result" ] || exit 1
rm -f "$FLAG"
PAUSE=0
_start_protoguard
wait
[ -e "$RUN_DIR/protoguard" ] || exit 1
cat "$RUN_DIR/result"
'''
        self.assertEqual(self.run_shell(source), ['registered'])

    def test_sim_wake_does_not_enable_interface_when_probe_enters_standby(self):
        source = function('simwait_tick_one_locked', 'simwait.sh').replace('/tmp/5gmodem', '$RUN_DIR') + r'''
SIMWAIT_DIR="$RUN_DIR/simwait"
mkdir "$SIMWAIT_DIR"
: > "$SIMWAIT_DIR/modem"
: > "$SIMWAIT_DIR/modem.blocked"
uci() { case "$*" in *5gmodem.*.network) echo modem ;; esac; }
usb_path_present() { return 0; }
ubus() {
	case "$*" in
		*status) echo '{}' ;;
		*notify_proto*) : > "$RUN_DIR/notified" ;;
		*'network.interface up '*) : > "$RUN_DIR/connected" ;;
	esac
}
jsonfilter() {
	cat >/dev/null
	case "$*" in *autostart|*available) echo true ;; *pending|*.up) echo false ;; esac
}
simwait_check_locked() { [ "$PAUSE" != 1 ] || : > "$FLAG"; }
simwait_clear() { rm -f "$SIMWAIT_DIR/modem"; }
uptime_s() { echo 10; }
logger() { :; }
PAUSE=1
simwait_tick_one_locked 1-2 m_1_2 modem fibocom /dev/test ''
[ ! -e "$RUN_DIR/notified" ] && [ ! -e "$RUN_DIR/connected" ] && [ -e "$SIMWAIT_DIR/modem" ] || exit 1
rm -f "$FLAG"
PAUSE=0
simwait_tick_one_locked 1-2 m_1_2 modem fibocom /dev/test ''
[ -e "$RUN_DIR/notified" ] && [ -e "$RUN_DIR/connected" ] && [ ! -e "$SIMWAIT_DIR/modem" ] || exit 1
'''
        self.assertEqual(self.run_shell(source), [])
