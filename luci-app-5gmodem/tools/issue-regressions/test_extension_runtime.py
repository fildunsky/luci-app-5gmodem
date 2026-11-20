import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2] / 'root'


def notification_dispatcher(tmp):
    source = (ROOT / 'usr/share/5gmodem/sessionwatch.sh').read_text()
    dispatcher = re.search(r'^_sms_notify\(\) \(\n.*?^\)$', source, re.M | re.S).group()
    return dispatcher.replace('/tmp/5gmodem', tmp).replace(
        '_sn_mcu=/usr/bin/mcu-switch', '_sn_mcu="$RES/mcu-switch"'
    )


class ExtensionRuntimeTests(unittest.TestCase):
    def test_button_mutations_require_write_access(self):
        acl = json.loads((ROOT / 'usr/share/rpcd/acl.d/luci-app-5gmodem.json').read_text())['luci-app-5gmodem']
        command = '/usr/share/5gmodem/buttons.sh'
        read_commands = {name for name in acl['read']['file'] if name.startswith(command)}
        self.assertEqual(read_commands, {f'{command} {verb}' for verb in ('detect', 'leds', 'services')})
        self.assertIn('exec', acl['write']['file'][command])

    def test_only_installed_executables_run_and_refreshes_do_not_overlap(self):
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

            cmd = ['busybox', 'ash', '-c', notification_dispatcher(tmp) + '\n_sms_notify']
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

    def test_legacy_display_accepts_only_the_exact_default_without_installed_handlers(self):
        legacy = '/usr/bin/mcu-switch sms new'
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            ran = directory / 'ran'
            mcu_switch = directory / 'mcu-switch'
            mcu_switch.write_text('''#!/bin/sh
[ ! -e /proc/$$/fd/9 ] || exit 1
printf '%s:%s:%s\n' "$#" "$1" "$2" >> "$RES/ran"
''')
            mcu_switch.chmod(0o755)
            script = notification_dispatcher(tmp) + '''
uci() {
    [ "$*" = '-q get 5gmodem.sms.newsms_hook' ] || return 1
    printf '%s\n' "$LEGACY"
    return "${UCI_STATUS:-0}"
}
_sms_notify
'''
            cmd = ['busybox', 'ash', '-c', script]
            env = dict(os.environ, RES=tmp, UCI_STATUS='0')
            for value in ('', 'another handler', legacy + ' extra', legacy + '\n', legacy + '\nanother handler'):
                with self.subTest(value=value):
                    subprocess.run(cmd, env=dict(env, LEGACY=value), check=True, timeout=2)
                    self.assertFalse(ran.exists())
            subprocess.run(cmd, env=dict(env, LEGACY=legacy, UCI_STATUS='1'), check=True, timeout=2)
            self.assertFalse(ran.exists())

            handlers = directory / 'sms-notify.d'
            handlers.mkdir()
            handler = handlers / 'gl-e750'
            handler.write_text('#!/bin/sh\nprintf "registered\\n" >> "$RES/ran"\n')
            subprocess.run(cmd, env=dict(env, LEGACY=legacy), check=True, timeout=2)
            self.assertEqual(ran.read_text(), '2:sms:new\n')

            handler.chmod(0o755)
            subprocess.run(cmd, env=dict(env, LEGACY=legacy), check=True, timeout=2)
            self.assertEqual(ran.read_text(), '2:sms:new\nregistered\n')

            handler.unlink()
            mcu_switch.chmod(0o644)
            subprocess.run(cmd, env=dict(env, LEGACY=legacy), check=True, timeout=2)
            self.assertEqual(ran.read_text(), '2:sms:new\nregistered\n')
