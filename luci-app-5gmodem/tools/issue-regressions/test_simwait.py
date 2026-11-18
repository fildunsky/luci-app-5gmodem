import json
import os
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'root/usr/share/5gmodem/simwait.sh'


class SimWaitTests(unittest.TestCase):
    def run_shell(self, body, mock_state=True):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            jsonfilter = folder / 'jsonfilter'
            jsonfilter.write_text('''#!/usr/bin/env python3
import json,sys
try:
 value=json.load(sys.stdin)
 for key in sys.argv[-1].removeprefix('@.').replace('[0]', '.0').split('.'):
  value=value[int(key)] if isinstance(value,list) else value[key]
 print(str(value).lower() if isinstance(value,bool) else value)
except (ValueError,KeyError,IndexError,TypeError): pass
''')
            jsonfilter.chmod(0o755)
            functions = folder / 'functions.sh'
            functions.write_text(SCRIPT.read_text().replace('/usr/share/5gmodem/', directory + '/').replace('/tmp/5gmodem/', directory + '/runtime/'))
            for name, content in {'hilink.sh': 'printf "%s" "$HILINK"',
                                  'modemswitch.sh': 'echo 0'}.items():
                helper = folder / name
                helper.write_text('#!/bin/sh\n' + content + '\n')
                helper.chmod(0o755)
            setup = f'''
. '{functions}'
SIMWAIT_DIR='{directory}/wait'
TRACE='{directory}/trace'
RUNTIME='{directory}/runtime'
mkdir -p "$SIMWAIT_DIR"
STATE=unknown
AUTO=1
DISABLED=0
UP=false
AVAILABLE=true
PENDING=false
AUTOSTART=true
ERROR=
uptime_s() {{ echo 200; }}
logger() {{ :; }}
usb_path_present() {{ return 0; }}
uci() {{
 case "$*" in
  *network.modem.auto) echo "$AUTO" ;;
  *network.modem.disabled) echo "$DISABLED" ;;
  *network.modem.device) echo /dev/cdc-wdm0 ;;
  *network.modem.proto) echo "${{PROTO:-qmi}}" ;;
  *kind) echo "${{KIND:-usb}}" ;;
  *5gmodem.m_test.network) echo modem ;;
  *vidpid) echo 0000:0000 ;;
  *imei) echo 000000000000000 ;;
 esac
}}
ubus() {{
 case "$*" in
  *status) printf '{{"up":%s,"pending":%s,"autostart":%s,"available":%s,"errors":[{{"code":"%s"}}]}}' "$UP" "$PENDING" "$AUTOSTART" "$AVAILABLE" "$ERROR" ;;
  *) printf '%s\\n' "$*" >> "$TRACE" ;;
 esac
}}

check() {{ simwait_check modem m_test test /dev/test ''; }}
tick() {{ simwait_tick_one test m_test modem fibocom /dev/test ''; }}
'''
            if mock_state:
                setup += '\nsimwait_state() { echo "$STATE"; }\n'
            result = subprocess.run(['sh', '-c', setup + '\n' + body],
                                    env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']},
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

    def test_absent_blocks_and_ready_resumes_once(self):
        self.run_shell('''
STATE=absent; tick
[ -f "$SIMWAIT_DIR/modem" ]
[ "$(grep -c 'notify_proto' "$TRACE")" = 2 ]
tick
[ "$(grep -c 'notify_proto' "$TRACE")" = 2 ]
STATE=unknown; tick
! grep -q 'interface up' "$TRACE"
STATE=ready; AUTOSTART=false; ERROR=SIM_MISSING; tick
[ ! -f "$SIMWAIT_DIR/modem" ]
[ "$(grep -c 'interface up' "$TRACE")" = 1 ]
tick
[ "$(grep -c 'interface up' "$TRACE")" = 1 ]
''')

    def test_check_works_with_busybox_flock(self):
        output = self.run_shell('''
flock() {
    [ "$1" = -n ] || return 2
    command flock "$@"
}
STATE=absent
check && exit 1
simwait_status modem
''')
        self.assertEqual(json.loads(output), {'sim_state': 'absent', 'waiting_sim': True})

    def test_unknown_does_not_create_wait(self):
        self.run_shell('STATE=unknown; check; [ ! -f "$SIMWAIT_DIR/modem" ]')

    def test_locked_after_absence_keeps_waiting(self):
        self.run_shell('STATE=absent; check && exit 1; STATE=locked; check && exit 1; exit 0')

    def test_initial_locked_does_not_block_native_pin_handling(self):
        self.run_shell('STATE=locked; check; [ ! -f "$SIMWAIT_DIR/modem" ]')

    def test_configured_pin_resumes_native_unlock(self):
        self.run_shell('''
STATE=absent; check && exit 1
uci() { case "$*" in *pincode) echo 0000 ;; *vidpid) echo 0000:0000 ;; *imei) echo 000000000000000 ;; esac; }
STATE=pin; check
''')

    def test_manual_stop_cancels_wait(self):
        self.run_shell('''
STATE=absent; check && exit 1
STATE=ready; AUTOSTART=false; ERROR=; tick
[ ! -f "$SIMWAIT_DIR/modem" ]
[ ! -f "$TRACE" ]
''')

    def test_disabled_interface_never_resumes(self):
        for option in ('AUTO=0', 'DISABLED=1'):
            with self.subTest(option=option):
                self.run_shell('STATE=absent; check && exit 1; ' + option + '; STATE=ready; tick; [ ! -f "$TRACE" ]')

    def test_replaced_modem_does_not_inherit_wait(self):
        self.run_shell('''
STATE=absent; check && exit 1
STATE=unknown
simwait_identity() { echo different; }
check
[ ! -f "$SIMWAIT_DIR/modem" ]
''')

    def test_ready_resets_exhausted_recovery(self):
        self.run_shell('''
mkdir -p "$RUNTIME/health"
echo '2 100 6' > "$RUNTIME/health/modem.heal"
echo other > "$RUNTIME/health/other.heal"
STATE=absent; tick
[ -f "$RUNTIME/health/modem.heal" ]
STATE=ready; tick
[ ! -f "$RUNTIME/health/modem.heal" ]
[ -f "$RUNTIME/health/other.heal" ]
''')

    def test_identity_completion_preserves_wait(self):
        self.run_shell('''
simwait_identity() { echo 'test|0000:0000|'; }
STATE=absent; check && exit 1
simwait_identity() { echo 'test|0000:0000|000000000000000'; }
STATE=unknown
check && exit 1
[ -f "$SIMWAIT_DIR/modem" ]
''')

    def test_other_interface_marker_untouched(self):
        self.run_shell('''
echo other > "$SIMWAIT_DIR/other"
STATE=absent; tick
STATE=ready; tick
[ "$(cat "$SIMWAIT_DIR/other")" = other ]
''')

    def test_pending_connection_is_not_restarted(self):
        self.run_shell('''
STATE=absent; tick
STATE=ready; PENDING=true; tick
! grep -q 'interface up' "$TRACE"
PENDING=false; tick
! grep -q 'interface up' "$TRACE"
''')

    def test_initial_status_is_unknown(self):
        result = self.run_shell('simwait_status modem')
        self.assertEqual(json.loads(result), {'sim_state': 'unknown', 'waiting_sim': False})

    def test_stale_status_is_unknown(self):
        result = self.run_shell('echo "ready 1" > "$SIMWAIT_DIR/modem.status"; simwait_status modem')
        self.assertEqual(json.loads(result)['sim_state'], 'unknown')

    def test_wait_guard_allows_ready_during_native_setup(self):
        self.run_shell('''
STATE=absent; check && exit 1
simwait_blocked modem
STATE=ready; check
if simwait_blocked modem; then exit 1; fi
''')

    def test_native_missing_sim_error_establishes_wait(self):
        self.run_shell('''
STATE=unknown; AUTOSTART=false; ERROR=SIM_NOT_PRESENT; tick
[ -f "$SIMWAIT_DIR/modem" ]
STATE=ready; tick
[ "$(grep -c 'interface up' "$TRACE")" = 1 ]
''')

    def test_ready_active_interface_is_never_interrupted(self):
        self.run_shell('UP=true; STATE=ready; tick; [ ! -f "$TRACE" ]; [ ! -f "$SIMWAIT_DIR/modem" ]')

    def test_hot_removal_stops_stale_up_interface(self):
        self.run_shell('''
UP=true; STATE=absent; tick
[ -f "$SIMWAIT_DIR/modem" ]
grep -q '\"available\":false' "$TRACE"
''')

    def test_available_transition_resumes_without_duplicate_ifup(self):
        self.run_shell('''
STATE=absent; tick
AVAILABLE=false; STATE=ready; tick
! grep -q 'interface up' "$TRACE"
grep -q '\"available\":true' "$TRACE"
[ ! -f "$SIMWAIT_DIR/modem" ]
''')

    def test_status_is_valid_json(self):
        output = self.run_shell('STATE=absent; check || :; simwait_status modem')
        self.assertEqual(json.loads(output), {'sim_state': 'absent', 'waiting_sim': True})

    def test_failed_resume_is_retried(self):
        self.run_shell('''
STATE=absent; check && exit 1
STATE=ready
ubus() { case "$*" in *status) echo '{"up":false,"pending":false,"autostart":true}';; *) return 1;; esac; }
tick || :
[ -f "$SIMWAIT_DIR/modem" ]
''')

    def test_at_backend_never_uses_another_modem_port(self):
        result = self.run_shell('''
tty_usbpath() { echo other; }
at_query() { echo '+CPIN: READY'; }
readlink() { echo /sys/devices/other/device; }
simwait_state m_test test /dev/ttyUSB0 us
''', mock_state=False)
        self.assertEqual(result.strip(), 'unknown')

    def test_at_backend(self):
        result = self.run_shell('''
tty_usbpath() { echo test; }
at_query() { echo '+CPIN: READY'; }
simwait_state m_test test /dev/ttyUSB0 us
''', mock_state=False)
        self.assertEqual(result.strip(), 'ready')

    def test_hilink_backend(self):
        for status, expected in [('0', 'absent'), ('1', 'ready'), ('255', 'absent'), ('garbage', 'unknown')]:
            with self.subTest(status=status):
                result = self.run_shell('KIND=hilink; HILINK=\'{"sim_status":"' + status + '"}\'; export HILINK; simwait_state m_test test - us', mock_state=False)
                self.assertEqual(result.strip(), expected)

    def test_qmi_backend(self):
        for reply, expected in [('{"card_state":"absent"}', 'absent'),
                                ('{"card_application_state":"ready"}', 'ready'),
                                ('{"card_application_state":"illegal"}', 'unknown'),
                                ('{"card_application_state":"pin-required"}', 'pin'),
                                ('{"card_application_state":"puk-required"}', 'locked'),
                                ('', 'unknown')]:
            with self.subTest(reply=reply):
                result = self.run_shell('''
readlink() { echo /sys/devices/test/test:1.0/usbmisc/cdc-wdm0; }
pgrep() { return 1; }
uqmi() { printf '%s' ''' + shlex.quote(reply) + '''; }
simwait_state m_test test - us
''', mock_state=False)
                self.assertEqual(result.strip(), expected)

    def test_qmi_absence_requires_explicit_card_status(self):
        for reply, expected in [("Card state: 'absent'", 'absent'),
                                ("Card state: 'absent'\nCard state: 'present'", 'unknown'),
                                ("Card state: 'error'", 'unknown'),
                                ('', 'unknown')]:
            with self.subTest(reply=reply):
                result = self.run_shell('''
readlink() { echo /sys/devices/test/test:1.0/usbmisc/cdc-wdm0; }
pgrep() { return 1; }
uqmi() { echo '{}'; }
qmicli() { printf '%s' ''' + shlex.quote(reply) + '''; }
simwait_state m_test test - us
''', mock_state=False)
                self.assertEqual(result.strip(), expected)

    def test_busy_control_channel_is_not_queried(self):
        result = self.run_shell('''
readlink() { echo /sys/devices/test/test:1.0/usbmisc/cdc-wdm0; }
pgrep() { [ "$2" = uqmi ]; }
uqmi() { echo called > "$TRACE"; }
simwait_state m_test test - us
[ ! -f "$TRACE" ]
''', mock_state=False)
        self.assertEqual(result.strip(), 'unknown')

    def test_mbim_backend(self):
        for proto, reply, expected in [
            ('mbim', 'readystate: 3 (sim-not-inserted)', 'absent'),
            ('mbim', 'readystate: 1 (initialized)', 'ready'),
            ('mbim', 'readystate: 6 (device-locked)', 'locked'),
            ('mbim', 'readystate: 2 (not-initialized)', 'unknown'),
            ('mbimp', "Ready state: 'sim-not-inserted'", 'absent'),
            ('mbimp', "Ready state: 'initialized'", 'ready'),
            ('mbimp', '', 'unknown')]:
            with self.subTest(proto=proto, reply=reply):
                result = self.run_shell('''
readlink() { echo /sys/devices/test/test:1.0/usbmisc/cdc-wdm0; }
pgrep() { return 1; }
PROTO=''' + proto + '''
umbim() { printf '%s' ''' + shlex.quote(reply) + '''; }
mbimcli() { printf '%s' ''' + shlex.quote(reply) + '''; }
simwait_state m_test test - us
''', mock_state=False)
                self.assertEqual(result.strip(), expected)

    def test_mm_backend(self):
        for reply, expected in [('modem.generic.state-failed-reason : sim-missing', 'absent'),
                                ('modem.generic.unlock-required : sim-pin', 'pin'),
                                ('modem.generic.unlock-required : none\nmodem.generic.sim : /org/freedesktop/ModemManager1/SIM/0', 'ready'),
                                ('', 'unknown')]:
            with self.subTest(reply=reply):
                result = self.run_shell("mmcli() { printf '%s' " + shlex.quote(reply) + "; }; simwait_state m_test test - mm", mock_state=False)
                self.assertEqual(result.strip(), expected)

    def test_resume_grace_prevents_recovery_race(self):
        self.run_shell('''
STATE=absent; tick
STATE=ready; tick
simwait_recovering modem
uptime_s() { echo 321; }
if simwait_recovering modem; then exit 1; fi
''')

    def test_new_absence_cancels_resume_grace(self):
        self.run_shell('''
STATE=absent; tick
STATE=ready; tick
STATE=absent; tick
if simwait_recovering modem; then exit 1; fi
''')

    def test_cpin_parser(self):
        cases = {'+CPIN: READY': 'ready', '+CPIN: SIM PIN': 'pin',
                 '+CPIN: SIM PUK': 'locked', '+CME ERROR: 10': 'absent',
                 '+CME ERROR: SIM not inserted': 'absent', '': 'unknown',
                 'ERROR': 'unknown', '+CME ERROR: 13': 'unknown',
                 '+CPIN: SIM PIN2': 'ready'}
        for reply, expected in cases.items():
            with self.subTest(reply=reply):
                output = self.run_shell('at_query() { printf "%s\\n" ' + repr(reply) + '; }; simwait_at_state /dev/test')
                self.assertEqual(output.strip(), expected)


if __name__ == '__main__':
    unittest.main()
