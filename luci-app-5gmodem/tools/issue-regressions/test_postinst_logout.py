import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'root/usr/share/5gmodem/postinst-logout.sh'
SESSION = '12345678901234567890123456789012'


class PostInstallLogout(unittest.TestCase):
    def run_logout(self, *, updating=False, offline=False, sessions=True, installer=False,
                   update_during_wait=False, stale_update=False):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            proc = folder / 'proc'
            (proc / '42').mkdir(parents=True)
            (proc / '42/comm').write_text('apk\n')
            script = SCRIPT.read_text().replace('/tmp/5gmodem/update.pid', str(folder / 'update.pid'))
            script = script.replace('/proc/$parent/', str(proc) + '/$parent/')
            script = script.replace('kill -0 "$installer"', '[ -e "' + str(proc) + '/$installer/comm" ]')
            (folder / 'logout.sh').write_text(script)
            if updating:
                (folder / 'update.pid').write_text(str(os.getpid()) + '\n')
            if stale_update:
                (folder / 'update.pid').write_text('invalid\n')
            data = [{'ubus_rpc_session': '0' * 32, 'data': {}},
                    {'ubus_rpc_session': '9' * 32, 'data': {'username': 'root'}}]
            if sessions:
                data.append({'ubus_rpc_session': SESSION, 'data': {'token': 'synthetic'}})
            (folder / 'sessions.json').write_text(json.dumps(data))
            commands = {
                'ubus': '''#!/bin/sh
if [ "$5" = list ]; then cat "$TEST_DIR/sessions.json"; else
    [ ! -e "$TEST_DIR/proc/42/comm" ] || exit 1
    printf '%s\\n' "$6" >> "$TEST_DIR/destroyed"
fi
''',
                'jsonfilter': '''#!/usr/bin/env python3
import json, sys
assert sys.argv[1:] == ['-a', '-e', '@[@.data.token].ubus_rpc_session']
for session in json.load(sys.stdin):
    if session.get('data', {}).get('token'):
        print(session['ubus_rpc_session'])
''',
                'sleep': '''#!/bin/sh
printf '%s\\n' "$1" >> "$TEST_DIR/sleeps"
rm -f "$TEST_DIR/proc/42/comm"
[ -z "$START_UPDATE_PID" ] || printf '%s\\n' "$START_UPDATE_PID" > "$TEST_DIR/update.pid"
# A new login after installation must survive the deferred logout.
printf '[]' > "$TEST_DIR/sessions.json"
''',
            }
            for name, content in commands.items():
                path = folder / name
                path.write_text(content)
                path.chmod(0o755)
            if not installer:
                (proc / '42/comm').unlink()
            env = {**os.environ, 'TEST_DIR': directory,
                   'PATH': directory + ':' + os.environ['PATH'],
                   'START_UPDATE_PID': str(os.getpid()) if update_during_wait else '',
                   'IPKG_INSTROOT': '/offline' if offline else ''}
            result = subprocess.run(['sh', str(folder / 'logout.sh'), '42'], env=env,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            destroyed = folder / 'destroyed'
            sleeps = folder / 'sleeps'
            return ([json.loads(line) for line in destroyed.read_text().splitlines()] if destroyed.exists() else [],
                    sleeps.read_text().splitlines() if sleeps.exists() else [])

    def test_waits_for_installer_and_expires_only_original_luci_sessions(self):
        destroyed, sleeps = self.run_logout(installer=True)
        self.assertEqual(destroyed, [{'ubus_rpc_session': SESSION}])
        self.assertEqual(sleeps, ['1', '5'])

    def test_updater_retains_its_session_and_progress(self):
        self.assertEqual(self.run_logout(updating=True), ([], []))

    def test_image_build_does_not_touch_sessions(self):
        self.assertEqual(self.run_logout(offline=True), ([], []))

    def test_no_luci_sessions_needs_no_background_wait(self):
        self.assertEqual(self.run_logout(sessions=False), ([], []))

    def test_missing_installer_still_defers_logout(self):
        destroyed, sleeps = self.run_logout()
        self.assertEqual(destroyed, [{'ubus_rpc_session': SESSION}])
        self.assertEqual(sleeps, ['5'])

    def test_updater_starting_during_wait_cancels_logout(self):
        destroyed, sleeps = self.run_logout(update_during_wait=True)
        self.assertEqual(destroyed, [])
        self.assertEqual(sleeps, ['5'])

    def test_stale_update_marker_does_not_prevent_logout(self):
        destroyed, sleeps = self.run_logout(stale_update=True)
        self.assertEqual(destroyed, [{'ubus_rpc_session': SESSION}])
