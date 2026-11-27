import json
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE, shell


class NativeSlotSwitch(unittest.TestCase):
    def switch(self, vidpid, fragile, mm_success=True):
        source = (SHARE / 'simslot.sh').read_text()
        block = source.split('if [ -n "$MI" ]; then\n', 1)[1].split('\n\t*)\n\t\tK=', 1)[0]
        with tempfile.TemporaryDirectory() as td:
            result = Path(td) / 'calls'
            prefix = '''
mmcli() { echo "mmcli $*" >> "$RESULT"; return "$MM_EXIT"; }
logger() { :; }
_slot_at_mm() { echo fixture-port; }
_at_slot_set() { echo "at $*" >> "$RESULT"; echo '{"result":"ok"}'; return 0; }
uci() { :; }
set -- set 1
'''
            r = shell(prefix + 'case "$1" in\n' + block.split('case "$1" in\n', 1)[1] + '\nesac', env={
                'MI': '7', '_FRAG': '1' if fragile else '', '_AVIDPID': vidpid,
                'RESULT': str(result), 'MM_EXIT': '0' if mm_success else '1',
            })
            self.assertEqual(r.returncode, 0, r.stderr)
            calls = result.read_text().splitlines() if result.exists() else []
            return calls, r.stdout

    def test_dw5829e_uses_native_switch_before_at(self):
        calls, output = self.switch('413c:81e4', True)
        self.assertEqual(calls, ['mmcli -m 7 --set-primary-sim-slot=1'])
        self.assertEqual(json.loads(output), {'result': 'ok'})

    def test_dw5829e_retains_at_fallback(self):
        calls, output = self.switch('413c:81e4', True, False)
        self.assertEqual(calls, ['mmcli -m 7 --set-primary-sim-slot=1', 'at 1'])
        self.assertEqual(json.loads(output), {'result': 'ok'})

    def test_other_fragile_profiles_keep_at_path(self):
        calls, _ = self.switch('413c:81d7', True)
        self.assertEqual(calls, ['at 1'])

    def test_regular_mm_profile_keeps_native_switch(self):
        calls, output = self.switch('0000:0000', False)
        self.assertEqual(calls, ['mmcli -m 7 --set-primary-sim-slot=1'])
        self.assertEqual(json.loads(output), {'result': 'ok'})


if __name__ == '__main__':
    unittest.main()
