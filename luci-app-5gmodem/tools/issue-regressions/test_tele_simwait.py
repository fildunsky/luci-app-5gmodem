import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SHARE = Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem'


class TeleSimWaitTests(unittest.TestCase):
    def run_export(self, age, actions):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / 'runtime'
            runtime.mkdir()
            binary = root / 'jsonfilter'
            binary.write_text('''#!/usr/bin/env python3
import json,sys
try:
 a=sys.argv
 value=json.loads(a[a.index('-s')+1]) if '-s' in a else json.load(open(a[a.index('-i')+1])) if '-i' in a else json.load(sys.stdin)
 for key in a[a.index('-e')+1].removeprefix('@.').split('.'): value=value[key]
 print(str(value).lower() if isinstance(value,bool) else value)
except (ValueError,KeyError,IndexError,TypeError,OSError): pass
''')
            binary.chmod(0o755)
            policy = root / 'simwait.sh'
            policy.write_text('#!/bin/sh\ncat "' + str(root / 'sim.json') + '"\n')
            policy.chmod(0o755)
            source = (SHARE / 'telemetry.sh').read_text().rsplit('\ncase "$1" in', 1)[0]
            source = source.replace('/tmp/5gmodem', str(runtime)).replace('/usr/share/5gmodem/simwait.sh', str(policy))
            source = source.replace('/sys/bus', str(root / 'sys')).replace('/proc/uptime', str(root / 'uptime'))
            (root / 'sys/usb/devices/test').mkdir(parents=True)
            (root / 'uptime').write_text('1000.0 1000.0\n')
            functions = root / 'tele-functions.sh'
            functions.write_text(source)
            (runtime / 'metrics_test_.json').write_text('{"signal":"50","rsrp":"-90","pci":"123","iface":"modem"}')
            (runtime / 'metrics_test_.stamp').write_text(str(1000 - age))
            script = f'''
uci() {{ case "$*" in *active_modem) echo test;; *network) echo modem;; *) return 1;; esac; }}
ubus() {{ echo '{{}}'; }}
. '{functions}'
EXTIP=/nonexistent
fixture='{root}'
simstate() {{ printf '{{"sim_state":"%s","waiting_sim":%s}}\n' "$1" "$2" > "$fixture/sim.json"; }}
uptime_at() {{ printf '%s.0 1000.0\n' "$1" > "$fixture/uptime"; }}
export_state() {{ tele_write; cat "$TELE" "$TELE_CELL"; }}
{actions}
'''
            result = subprocess.run(['busybox', 'sh', '-c', script], text=True, capture_output=True,
                                    env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']})
            self.assertEqual(result.returncode, 0, result.stderr)
            return [json.loads(line) for line in result.stdout.splitlines()]

    def test_live_state_is_exported_outside_radio_snapshot_cache(self):
        for fresh in (True, False):
            with self.subTest(fresh=fresh):
                before, cell_before, after, cell_after = self.run_export(0 if fresh else 130, '''
simstate absent true
export_state
simstate ready false
export_state
''')
                for data in before, cell_before:
                    self.assertEqual(data['sim_state'], 'absent')
                    self.assertIs(data['waiting_sim'], True)
                for data in after, cell_after:
                    self.assertEqual(data['sim_state'], 'ready')
                    self.assertIs(data['waiting_sim'], False)
                self.assertEqual('rsrp' in before, fresh)

    def test_skipped_refresh_keeps_recent_export_until_new_measurement(self):
        before, cell_before, held, cell_held, after, cell_after = self.run_export(110, '''
simstate ready false
export_state
# The poll could not take the AT lock. No new snapshot was written.
uptime_at 1020
simstate unknown false
touch -d "@$(($(date +%s) - 30))" "$TELE" "$TELE_CELL"
tele_stamp=$(date -r "$TELE" +%s)
cell_stamp=$(date -r "$TELE_CELL" +%s)
export_state
[ "$(date -r "$TELE" +%s)" = "$tele_stamp" ] || exit 1
[ "$(date -r "$TELE_CELL" +%s)" = "$cell_stamp" ] || exit 1
_mqtt_args() { echo unexpected-mqtt; return 1; }
tele_publish
printf '%s\n' 1020 > "${_SNAP%.json}.stamp"
printf '%s\n' '{"signal":"60","rsrp":"-80","pci":"125","iface":"modem"}' > "$_SNAP"
simstate ready false
export_state
''')
        self.assertEqual((held, cell_held), (before, cell_before))
        self.assertEqual((after['rsrp'], cell_after['pci']), (-80, 125))

    def test_does_not_keep_an_expired_snapshot_after_disconnect_or_sim_change(self):
        events = (
            'simstate absent true',
            'simstate locked false',
            'simstate unknown true',
            'rm "${_SNAP%.json}.stamp"',
            'mv "$fixture/sys/usb/devices/test" "$fixture/removed"',
            'mv "$fixture/sys/usb/devices/test" "$fixture/removed"; mkdir "$fixture/sys/usb/devices/test"',
            'touch -d "@$(($(date +%s) - 91))" "$TELE" "$TELE_CELL"',
        )
        for event in events:
            with self.subTest(event=event):
                before, cell_before, after, cell_after = self.run_export(110, f'''
simstate ready false
export_state
uptime_at 1020
{event}
export_state
''')
                self.assertEqual((before['rsrp'], cell_before['pci']), (-90, 123))
                self.assertNotIn('rsrp', after)
                self.assertNotIn('pci', cell_after)


if __name__ == '__main__':
    unittest.main()
