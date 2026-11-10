import json
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


class AndroidSlots(unittest.TestCase):
    def test_actions_validate_before_adb_and_only_clear_own_snapshot_on_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = r'''
android_cells_ready() { echo called >> "$READY"; echo phone-serial; }
android_adb() { printf '%s\n' "$*" >> "$CALLS"; printf '%s\n' "$REPLY"; }
jsonfilter() {
 printf '%s' "$2" | python3 -c 'import json,sys; d=json.load(sys.stdin); k=sys.argv[1]; v=d if k=="@" else d.get(k[2:]); print(json.dumps(v) if isinstance(v,(bool,dict,list)) else "" if v is None else v)' "$4"
}
''' + function('android_slots', 'android.sh').replace('/tmp/5gmodem/', directory+'/') + '\nandroid_slots 1-1 "$ACTION" "$SLOT"\n'
            ready = root / 'ready'
            calls = root / 'calls'
            good = json.dumps({'type': 'android', 'ok': True, 'active': '1'})
            env = dict(os.environ, READY=str(ready), CALLS=str(calls), ACTION='set', SLOT='1', REPLY=good)
            own = root / 'metrics_1_1_.json'
            other = root / 'metrics_2_1_.json'
            for invalid in ('', '0', '9', '-1', '1;reboot'):
                result = shell(source, dict(env, SLOT=invalid))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('error', json.loads(result.stdout))
                self.assertFalse(ready.exists())
                self.assertFalse(calls.exists())
            own.write_text('keep')
            other.write_text('neighbour modem')
            result = shell(source, dict(env, REPLY=json.dumps({'type': 'android', 'ok': False})))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(own.read_text(), 'keep')
            result = shell(source, dict(env, REPLY=json.dumps({'error': 'denied'})))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)['error'], 'denied')
            self.assertEqual(own.read_text(), 'keep')
            result = shell(source, dict(env, ACTION='status'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(own.read_text(), 'keep')
            result = shell(source, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(json.loads(result.stdout)['ok'])
            self.assertFalse(own.exists())
            self.assertEqual(other.read_text(), 'neighbour modem')
            self.assertIn('-s phone-serial shell CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe set-data 1', calls.read_text())

    def test_dispatch_is_android_only_and_precedes_modem_cache_cleanup(self):
        prefix = (SHARE / 'simslot.sh').read_text().split('[ "$1" = "set" ] && rm -f', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'android.sh').write_text('android_slots() { printf \'{"path":"%s","action":"%s","slot":"%s"}\\n\' "$1" "$2" "$3"; }\n')
            source = '''
uci() { case "$*" in *.kind) echo "$KIND" ;; *.tether) echo android ;; esac; }
set -- set 1 for=1-1
''' + prefix.replace('RES=/usr/share/5gmodem', 'RES='+directory) + '\necho legacy\n'
            result = shell(source, dict(os.environ, KIND='tether'))
            self.assertEqual(json.loads(result.stdout), {'path': '1-1', 'action': 'set', 'slot': '1'})
            result = shell(source, dict(os.environ, KIND='modem'))
            self.assertEqual(result.stdout.strip(), 'legacy')


if __name__ == '__main__':
    unittest.main()
