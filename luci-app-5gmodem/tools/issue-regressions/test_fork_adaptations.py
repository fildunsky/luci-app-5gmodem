#!/usr/bin/env python3
import json
import os
from pathlib import Path
import tempfile
import unittest
from test_runtime_audit import function, shell


class ForkAdaptations(unittest.TestCase):
    def run_mock(self, source, state, extra=''):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            config = temp / 'state'
            config.write_text(json.dumps(state))
            uci = temp / 'uci'
            uci.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p=Path(os.environ['STATE']); s=json.loads(p.read_text())
a=[x for x in sys.argv[1:] if x != '-q']; op=a[0]
if op == 'get':
 v=s.get(a[1]); print(v if v is not None else '', end='')
 sys.exit(0 if v is not None else 1)
if op == 'set':
 k,v=a[1].split('=',1); s[k]=v
elif op == 'delete': s.pop(a[1],None)
elif op == 'commit' and os.environ.get('FAIL_COMMIT'): sys.exit(1)
elif op == 'changes': print(os.environ.get('PENDING',''),end='')
elif op not in ('commit','revert'): sys.exit(1)
p.write_text(json.dumps(s))
''')
            uci.chmod(0o755)
            result = shell(extra + '\n' + source, dict(os.environ, STATE=str(config),
                PATH=str(temp)+':'+os.environ['PATH']))
            return result, json.loads(config.read_text())

    def test_recreate_keeps_custom_options_and_list_types(self):
        state = {'network.modem': 'interface', 'network.modem.proto': 'modemmanager',
                 'network.modem.dns': ['1.1.1.1', '2001:4860:4860::8888'],
                 'network.modem.mtu': '1420', 'network.modem.ip4table': '100',
                 'network.modem.custom': "spaces and 'quotes'", 'network.modem.device': '/dev/old',
                 'network.modem.init_apn': 'old', 'network.modem.modes': 'lte'}
        result, got = self.run_mock(function('_mk_reset_transport', 'mkiface.sh') +
                                   '\n_mk_reset_transport modem qmi', state)
        self.assertEqual(result.returncode, 0, result.stderr)
        for key in ('dns', 'mtu', 'ip4table', 'custom'):
            self.assertEqual(got['network.modem.'+key], state['network.modem.'+key])
        for key in ('device', 'init_apn', 'modes', 'proto'):
            self.assertNotIn('network.modem.'+key, got)

    def test_same_qmi_retains_mode_and_fresh_interface_works(self):
        for state in ({}, {'network.modem.proto': 'qmi', 'network.modem.modes': 'lte,5gnr'}):
            result, got = self.run_mock(function('_mk_reset_transport', 'mkiface.sh') +
                                       '\n_mk_reset_transport modem qmi', state)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(got['network.modem'], 'interface')
            self.assertEqual(got.get('network.modem.modes'), state.get('network.modem.modes'))

    def qmi(self, mode='3', proto='qmi', path='1-1', extra='', action='mode setmode'):
        setup = '''
_AVIDPID=2c7c0801; _APROD=RM520N-GL; _AMP=1-1; _bs_am=1-1; _bs_sec=m_1_1
uqmi() { echo 'Available modes: all umts lte 5gnr'; }
ubus() { echo "ubus:$*" >> "$STATE.trace"; }
_persist_mode() { echo "persist:$1" >> "$STATE.trace"; }
_bands_flush() { :; }
at_unlock() { :; }
'''
        return self.run_mock(function('_bands_qmi_mode','bands.sh') +
            f'\n_bands_qmi_mode {action} {mode}; rc=$?; cat "$STATE.trace" 2>/dev/null; exit "$rc"', {
                '5gmodem.m_1_1.network':'modem', 'network.modem.proto':proto,
                'network.modem.modem_path':path}, setup + extra)

    def test_all_mode_mappings(self):
        for mode, value in enumerate(('all', 'umts', 'lte', 'lte,5gnr', '5gnr')):
            result, got = self.qmi(str(mode))
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(got['network.modem.modes'],value)
            self.assertIn(f'persist:{mode}',result.stdout)
            self.assertLess(result.stdout.index('persist:'),result.stdout.index('ubus:'))

    def test_other_targets_and_live_commands_use_existing_path(self):
        for kwargs in ({'proto':'mbim'}, {'path':'2-1'}, {'extra':'_APROD=RM521F-GL'},
                       {'extra':'uqmi() { echo "Available modes: all lte"; }'},
                       {'action':'after setmode'}, {'extra':'_AMP=2-1'}):
            result, got = self.qmi(**kwargs)
            self.assertEqual(result.returncode,2,result.stderr)
            self.assertNotIn('network.modem.modes',got)

    def test_pending_changes_and_invalid_modes_are_rejected(self):
        for kwargs in ({'extra':'export PENDING=network.lan.mtu=1400'}, {'mode':'9'}):
            result, got = self.qmi(**kwargs)
            self.assertEqual(result.returncode,1)
            self.assertNotIn('network.modem.modes',got)
            self.assertNotIn('persist:',result.stdout)

    def test_reapplying_same_mode_cycles_only_bound_interface(self):
        result, got = self.qmi(extra='uci set network.modem.modes=lte,5gnr')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ubus:call network.interface.modem down', result.stdout)
        self.assertIn('ubus:call network.interface.modem up', result.stdout)
        self.assertNotIn('network.interface.lan', result.stdout)

    def test_commit_failure_does_not_reload_or_persist(self):
        result, got = self.qmi(extra='export FAIL_COMMIT=1')
        self.assertEqual(result.returncode, 1)
        self.assertIn('Failed to save QMI mode', result.stdout)
        self.assertNotIn('ubus:', result.stdout)
        self.assertNotIn('persist:', result.stdout)

    def test_reload_failure_is_reported(self):
        result, got = self.qmi(extra='ubus() { return 1; }')
        self.assertEqual(result.returncode,1)
        self.assertIn('Failed to reload',result.stdout)
        self.assertEqual(got['network.modem.modes'],'lte,5gnr')


if __name__ == '__main__':
    unittest.main()
