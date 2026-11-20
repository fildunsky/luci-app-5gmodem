import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2] / 'root'


class ExtensionRuntimeTests(unittest.TestCase):
    def test_button_mutations_require_write_access(self):
        acl = json.loads((ROOT / 'usr/share/rpcd/acl.d/luci-app-5gmodem.json').read_text())['luci-app-5gmodem']
        command = '/usr/share/5gmodem/buttons.sh'
        read_commands = {name for name in acl['read']['file'] if name.startswith(command)}
        self.assertEqual(read_commands, {f'{command} {verb}' for verb in ('detect', 'leds', 'services')})
        self.assertIn('exec', acl['write']['file'][command])

    def test_only_installed_executables_run_and_refreshes_do_not_overlap(self):
        source = (ROOT / 'usr/share/5gmodem/sessionwatch.sh').read_text()
        self.assertNotIn('newsms_hook', source)
        dispatcher = re.search(r'^_sms_notify\(\) \(\n.*?^\)$', source, re.M | re.S).group()
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / 'sms-notify.d'
            directory.mkdir()
            slow = directory / '10-screen'
            slow.write_text('''#!/bin/sh
[ ! -e /proc/$$/fd/9 ] || exit 1
printf 'screen\n' >> "$RES/ran"
until [ -e "$RES/finish" ]; do sleep 0.05; done
exit 1
''')
            slow.chmod(0o755)
            (directory / '15-disabled').write_text('not executable\n')
            led = directory / '20-led'
            led.write_text('''#!/bin/sh
printf 'led\n' >> "$RES/ran"
''')
            led.chmod(0o755)

            cmd = ['busybox', 'ash', '-c', dispatcher.replace('/tmp/5gmodem', tmp) + '\n_sms_notify']
            env = dict(os.environ, RES=tmp)
            first = subprocess.Popen(cmd, env=env)
            ran = Path(tmp) / 'ran'
            try:
                deadline = time.monotonic() + 3
                while not ran.exists() and first.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertEqual(ran.read_text(), 'screen\n')
                subprocess.run(cmd, env=env, check=True, timeout=2)
                self.assertEqual(ran.read_text(), 'screen\n')
            finally:
                (Path(tmp) / 'finish').touch()
                first.wait(timeout=3)
            self.assertEqual(first.returncode, 0)
            self.assertEqual(ran.read_text(), 'screen\nled\n')
