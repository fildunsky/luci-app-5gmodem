import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SHARE = Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem'


class TeleSimWaitTests(unittest.TestCase):
    def run_export(self, fresh):
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
            functions = root / 'tele-functions.sh'
            functions.write_text(source)
            stamp = int(float(Path('/proc/uptime').read_text().split()[0])) if fresh else 0
            (runtime / 'metrics_test_.json').write_text('{"signal":"50","rsrp":"-90","iface":"modem"}')
            (runtime / 'metrics_test_.stamp').write_text(str(stamp))
            script = f'''
uci() {{ case "$*" in *active_modem) echo test;; *network) echo modem;; esac; }}
ubus() {{ echo '{{}}'; }}
. '{functions}'
EXTIP=/nonexistent
printf '%s' '{{"sim_state":"absent","waiting_sim":true}}' > '{root / 'sim.json'}'
tele_write
cat "$TELE"
cat "$TELE_CELL"
printf '%s' '{{"sim_state":"ready","waiting_sim":false}}' > '{root / 'sim.json'}'
tele_write
cat "$TELE"
cat "$TELE_CELL"
'''
            result = subprocess.run(['busybox', 'sh', '-c', script], text=True, capture_output=True,
                                    env={**os.environ, 'PATH': directory + ':' + os.environ['PATH']})
            self.assertEqual(result.returncode, 0, result.stderr)
            return [json.loads(line) for line in result.stdout.splitlines()]

    def test_live_state_is_exported_outside_radio_snapshot_cache(self):
        for fresh in (True, False):
            with self.subTest(fresh=fresh):
                before, cell_before, after, cell_after = self.run_export(fresh)
                for data in before, cell_before:
                    self.assertEqual(data['sim_state'], 'absent')
                    self.assertIs(data['waiting_sim'], True)
                for data in after, cell_after:
                    self.assertEqual(data['sim_state'], 'ready')
                    self.assertIs(data['waiting_sim'], False)
                self.assertEqual('rsrp' in before, fresh)


if __name__ == '__main__':
    unittest.main()
