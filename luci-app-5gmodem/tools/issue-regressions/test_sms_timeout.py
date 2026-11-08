import os
from pathlib import Path
import tempfile
import time
import unittest

from test_runtime_audit import function, shell


class SmsTimeout(unittest.TestCase):
    def run_worker(self, worker, timeout=1):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            program = base/'worker'
            program.write_text('#!/bin/sh\n'+worker)
            program.chmod(0o755)
            source = function('_sms_run', 'smsbridge.sh').replace('/tmp/5gmodem-smsrun.', temp+'/smsrun.')
            source += r'''
PORT=/dev/null
_via_mm() { return 1; }
at_long_busy() { return 1; }
exec 8>"$LOCK"
exec 9>"$HOTPLUG_LOCK"
result=$(_sms_run "$LIMIT" "$WORKER")
rc=$?
printf '%s\n' "$result"
exit "$rc"
'''
            started = time.monotonic()
            result = shell(source, dict(os.environ, LOCK=temp+'/lock', HOTPLUG_LOCK=temp+'/hotplug',
                                        WORKER=str(program), LIMIT=str(timeout)))
            elapsed = time.monotonic()-started
            self.assertFalse(list(base.glob('smsrun.*')))
            return result, elapsed

    def test_success_preserves_output_and_exit_code(self):
        result, _ = self.run_worker('printf "received\\n"\nexit 7\n')
        self.assertEqual(result.stdout, 'received\n')
        self.assertEqual(result.returncode, 7)

    def test_child_cannot_inherit_at_or_hotplug_locks(self):
        result, _ = self.run_worker('''
for fd in 8 9; do
 if [ -e /proc/self/fd/$fd ]; then echo inherited; else echo closed; fi
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'closed\nclosed\n')

    def test_ignoring_term_cannot_hold_command_substitution_open(self):
        result, elapsed = self.run_worker('''
trap '' TERM
printf 'partial\\n'
while :; do :; done
''')
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual(result.stdout, 'partial\n')
        self.assertLess(elapsed, 4)
