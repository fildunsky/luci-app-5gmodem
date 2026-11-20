import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_runtime_audit import SHARE


class Fg360Controls(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)
        self.trace = self.root / 'trace'
        self.cache = self.root / 'cache'
        self.cache.mkdir()
        self.trace.touch()
        (self.root / 'current').write_text('20,3,6,1,5,8,101,103,501,5078\n')
        (self.root / 'mode').write_text('20,3,6\n')
        (self.root / 'architecture').write_text('7\n')
        (self.root / 'cell').write_text('0\n')
        (self.root / 'power').write_text('(78,79),(184,208)\n')
        self.install('mock-lib.sh', 'fg360_native_iface() { echo wan; }\nfg360_native() { test "$1" = ccci; }\n')
        self.install('uci', 'exit 1\n')
        self.install('sleep', 'exit 0\n')
        self.install('vendor/fg360_modem_lock.sh', r'''
case "$1 $2 $3" in "--priority high --"|"--priority low --") ;; *) exit 2 ;; esac
shift 3
touch "$FIXTURE/locked"
"$@"
status=$?
rm -f "$FIXTURE/locked"
exit "$status"
''')
        self.install('vendor/fg360_at_debug.sh', r'''
[ "$1" = 127.0.0.1:17171 ] && [ -f "$FIXTURE/locked" ] || exit 2
printf '%s\n' "$2" >> "$FIXTURE/trace"
case "$2" in
    'AT+GTACT?') printf '+GTACT: %s\n' "$(cat "$FIXTURE/current")" ;;
    'AT+GTACT=?') echo '+GTACT: (10,14,17,20),(3,6),(3,6),(),(1,5,8),(101,103,107),(),(),(501,503,5078)' ;;
    AT+GTACT=*) [ "$BEHAVIOR" != reject ] || { echo ERROR; exit 0; }
                [ "$BEHAVIOR" = mismatch ] || echo "${2#*=}" > "$FIXTURE/current" ;;
    'AT+GTRAT?') printf '+GTRAT: %s\n' "$(cat "$FIXTURE/mode")" ;;
    AT+GTRAT=*) echo "${2#*=}" > "$FIXTURE/mode" ;;
    'AT+E5GOPT?') printf '+E5GOPT: %s\n' "$(cat "$FIXTURE/architecture")" ;;
    AT+E5GOPT=*) echo "${2#*=}" > "$FIXTURE/architecture" ;;
    'AT+EMMCHLCK?') printf '+EMMCHLCK: %s\n' "$(cat "$FIXTURE/cell")" ;;
    'AT+EFMAXPWR?')
        printf '+EFMAXPWR: 1,(),()\n+EFMAXPWR: 7,%s\n+EFMAXPWR: 4,(),()\n' "$(cat "$FIXTURE/power")" ;;
    'AT+EFMAXPWR=7,2,78,79,232,208,1')
        [ "$BEHAVIOR" = mismatch ] || echo '(78,79),(232,208)' > "$FIXTURE/power" ;;
    'AT+GTCAINFO?')
        [ "$BEHAVIOR" = lte ] || printf 'PCC:5078,1,640000,400\nSCC1:1,1,5041,1,500000,500\nSCC2:2,1,5079,1,700000,500\n' ;;
    'AT+GTCCINFO?') : ;;
    *) exit 2 ;;
esac
printf '\rOK\r\n'
''')
        self.install('vendor/fg360_control.sh', r'''
[ "$2" = 127.0.0.1:17171 ] || exit 2
case "$1" in
    apply-cell)
        [ -f "$FIXTURE/locked" ] || exit 2
        printf '%s\n' "$3" >> "$FIXTURE/trace"
        echo "${3#*=}" > "$FIXTURE/cell" ;;
    reconnect-data)
        [ ! -e "$FIXTURE/locked" ] && [ "$3" = wan ] || exit 2
        echo reconnect >> "$FIXTURE/trace" ;;
    *) exit 2 ;;
esac
''')
        self.driver = self.root / 'fg360-bands.sh'
        self.driver.write_text((SHARE / 'fg360-bands.sh').read_text()
                               .replace('/usr/share/fg360-modem', str(self.root / 'vendor'))
                               .replace('/usr/share/5gmodem/lib.sh', str(self.root / 'mock-lib.sh'))
                               .replace('/tmp/fg360-status-cache', str(self.cache))
                               .replace('/data/fg360-traffic/active', str(self.root / 'quota')))
        self.entry = self.root / 'bands.sh'
        self.entry.write_text((SHARE / 'bands.sh').read_text()
                              .replace('/usr/share/5gmodem/fg360-bands.sh', str(self.driver))
                              .replace('/usr/share/5gmodem/lib.sh', str(self.root / 'mock-lib.sh'))
                              .replace('/tmp/5gmodem', str(self.root / '5gmodem')))

    def install(self, name, content):
        target = self.root / name
        target.parent.mkdir(exist_ok=True)
        target.write_text('#!/bin/sh\n' + content)
        target.chmod(0o755)

    def run_control(self, *args, behavior=''):
        return subprocess.run(['busybox', 'ash', str(self.entry), *args, 'for=ccci'],
                              capture_output=True, text=True, timeout=5,
                              env=dict(os.environ, FIXTURE=str(self.root), BEHAVIOR=behavior,
                                       PATH=str(self.root) + ':' + os.environ['PATH']))

    def commands(self):
        return self.trace.read_text().splitlines()

    def wait_reconnects(self, count):
        deadline = time.monotonic() + 1
        while self.commands().count('reconnect') < count and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertEqual(self.commands().count('reconnect'), count)

    def test_combined_command_preserves_prefix_and_other_groups(self):
        result = self.run_control('setall', 'lte=3 7', 'nsa=78 3', 'sa=3 78')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['applied'], ['lte', 'nsa', 'sa'])
        self.assertEqual(self.commands()[:4], ['AT+GTACT?', 'AT+GTACT=?',
                         'AT+GTACT=20,3,6,1,5,8,103,107,503,5078', 'AT+GTACT?'])
        self.wait_reconnects(1)
        self.assertIn('+GTACT: 20,3,6,1,5,8,103,107,503,5078', (self.cache / 'gtact').read_text())

    def test_lte_only_preserves_original_nr_encoding(self):
        result = self.run_control('setbands', '3')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('AT+GTACT=20,3,6,1,5,8,501,5078,103', self.commands())
        self.wait_reconnects(1)

    def test_incompatible_masks_and_unsupported_groups_are_rejected_before_write(self):
        result = self.run_control('setall', 'lte=3', 'nsa=1', 'sa=78')
        report = json.loads(result.stdout)
        self.assertEqual(report['applied'], [])
        self.assertEqual([entry['what'] for entry in report['failed']], ['lte', 'nsa', 'sa'])
        self.assertNotEqual(self.run_control('setall', 'lte=3', '3g=1').returncode, 0)
        self.assertEqual(self.commands(), ['AT+GTACT?', 'AT+GTACT=?'])

    def test_acknowledgement_and_readback_are_required(self):
        for mode in ('reject', 'mismatch'):
            with self.subTest(mode=mode):
                result = self.run_control('setbands', '3', behavior=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('reconnect', self.commands())

    def test_modes_and_cell_lock(self):
        self.assertEqual(self.run_control('setmode', '17').returncode, 0)
        self.wait_reconnects(1)
        self.assertIn('AT+GTRAT=17,3,6', self.commands())
        self.assertNotEqual(self.run_control('setmode', '14').returncode, 0)
        self.assertEqual(self.run_control('set5gmode', 'sa').returncode, 0)
        self.wait_reconnects(2)
        self.assertEqual(self.run_control('get5gmode').stdout.strip(), 'sa')
        self.assertIn('AT+E5GOPT=3', self.commands())
        self.assertNotEqual(self.run_control('setcelllock', 'cell', '1300', '504').returncode, 0)
        self.assertEqual(self.run_control('setcelllock', 'cell', '1300', '0').returncode, 0)
        self.wait_reconnects(3)
        self.assertEqual(self.run_control('getcelllock').stdout.strip(), 'cell 1300 0')
        self.assertEqual(self.run_control('setcelllock5g', 'cell', '640000', '1007').returncode, 0)
        self.wait_reconnects(4)
        self.assertEqual(self.run_control('getcelllock5g').stdout.strip(), 'cell 640000 1007')
        self.assertEqual(self.run_control('setcelllock5g', 'off').returncode, 0)
        self.wait_reconnects(5)
        self.assertEqual(self.run_control('getcelllock5g').stdout.strip(), 'off')

    def test_power_validates_a_live_band_and_preserves_the_other_limit(self):
        state = json.loads(self.run_control('txpowerjson').stdout)
        self.assertEqual(state['current_nr_bands'], [78, 79])
        self.assertEqual(state['groups']['nr'], [dict(band=78, dbm=23), dict(band=79, dbm=26)])
        self.assertNotEqual(self.run_control('settxpower', '41', '29').returncode, 0)
        self.assertNotEqual(self.run_control('settxpower', '78', '25').returncode, 0)
        self.assertFalse(any(command.startswith('AT+EFMAXPWR=') for command in self.commands()))
        self.assertNotEqual(self.run_control('settxpower', '78', '29', behavior='mismatch').returncode, 0)
        self.assertEqual(self.run_control('settxpower', '78', '29').returncode, 0)
        self.assertIn('AT+EFMAXPWR=7,2,78,79,232,208,1', self.commands())
        self.assertNotIn('reconnect', self.commands())

    def test_lte_and_empty_power_tables_allow_read_only(self):
        (self.root / 'power').write_text('(),()\n')
        state = json.loads(self.run_control('txpowerjson', behavior='lte').stdout)
        self.assertEqual(state['current_nr_bands'], [])
        self.assertEqual(state['groups'], dict(lte=[], nr=[], wcdma=[]))
        self.assertNotEqual(self.run_control('settxpower', '78', '29', behavior='lte').returncode, 0)
        self.assertFalse(any(command.startswith('AT+EFMAXPWR=') for command in self.commands()))
