import contextlib
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest

from test_runtime_audit import function, shell


class SmsStorage(unittest.TestCase):
    def run_storage(self, scenario, temp):
        worker = temp / 'sms_tool'
        worker.write_text(r'''#!/bin/sh
printf '%s\n' "$4" >> "$FIXTURE/commands"
if [ "$SCENARIO" = stalled ]; then
    trap '' TERM
    for fd in 5 6 7 8 9 1000; do
        [ ! -e "/proc/$$/fd/$fd" ] || printf '%s\n' "$fd" >> "$FIXTURE/inherited"
    done
    sleep 20 &
    printf '%s\n' "$!" > "$FIXTURE/descendant"
    wait
fi
[ "$4" = SM ] || exit 1
printf '%s\n' 'Storage type: SM, used: 0, total: 20'
''')
        worker.chmod(0o755)
        source = '\n'.join(function(name, 'lib.sh') for name in (
            'sms_storage_capacity', 'set_sms_storage',
        )).replace('/tmp/5gmodem/', str(temp) + '/')
        return shell(source + r'''
hl_web_port() { return 1; }
logger() { :; }
sleep_tick_init() { _SLEEP_TICK=0.05; _TICKS_PER_SEC=1; }
sleep() { [ "$1" = 3 ] || busybox sleep "$1"; }
uci() {
    case "$*" in
        '-q get 5gmodem.sms') echo sms ;;
        '-q get 5gmodem.sms.storage') echo ME ;;
        '-q get 5gmodem.@5gmodem[0].active_modem') echo 2-1 ;;
        '-q get 5gmodem.m_2_1.vidpid') echo 1e0e:9001 ;;
        '-q set 5gmodem.sms.storage='*) printf '%s\n' "$3" >> "$FIXTURE/uci" ;;
    esac
}
sms_apply_cpms() {
    printf '%s\n' "$2" >> "$FIXTURE/apply"
    [ "$2" = SM ] && echo 'SM|SM'
}
exec 5>"$FIXTURE/5" 6>"$FIXTURE/6" 7>"$FIXTURE/7" 8>"$FIXTURE/lock" 9>"$FIXTURE/9" 1000>"$FIXTURE/1000"
flock -n 8 || exit 2
set_sms_storage /dev/null
status=$?
exec 8>&-
exit "$status"
''', dict(os.environ, FIXTURE=str(temp), SCENARIO=scenario,
          PATH=str(temp) + ':' + os.environ['PATH']))

    def test_stalled_status_aborts_pass_and_releases_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            try:
                result = self.run_storage('stalled', temp)
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertEqual((temp / 'commands').read_text().splitlines(), ['ME'])
                self.assertFalse((temp / 'apply').exists())
                self.assertFalse((temp / 'uci').exists())
                self.assertFalse((temp / 'inherited').exists())
                self.assertFalse(list(temp.glob('bounded.*')))

                descendant = int((temp / 'descendant').read_text())
                os.kill(descendant, 0)
                lock = subprocess.run(['flock', '-n', temp / 'lock', 'true'],
                                      capture_output=True, text=True, timeout=2)
                self.assertEqual(lock.returncode, 0, lock.stderr)
            finally:
                if (temp / 'descendant').exists():
                    with contextlib.suppress(ProcessLookupError):
                        os.kill(int((temp / 'descendant').read_text()), signal.SIGKILL)

    def test_completed_unsupported_storage_keeps_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            result = self.run_storage('unsupported', temp)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((temp / 'commands').read_text().splitlines(), ['ME', 'SM', 'ME', 'ME'])
            self.assertEqual((temp / 'apply').read_text().splitlines(), ['ME', 'SM'])
            self.assertEqual((temp / 'uci').read_text(), '5gmodem.sms.storage=SM\n')
