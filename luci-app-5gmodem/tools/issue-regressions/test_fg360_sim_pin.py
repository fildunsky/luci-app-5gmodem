import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[2]
SCRIPT = PACKAGE / 'root/usr/share/5gmodem/fg360-sim.sh'
ACL = PACKAGE / 'root/usr/share/rpcd/acl.d/luci-app-5gmodem.json'


class Fg360SimPinTests(unittest.TestCase):
    def run_pin(self, *args, response='OK', status=0, active='ccci'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / 'lib.sh'
            library.write_text('''
uci() { printf '%s\\n' "$MOCK_ACTIVE"; }
fg360_native() { [ "$1" = ccci ]; }
fg360_at() {
    printf '%s|%s\\n' "$1" "$2" >> "$MOCK_LOG"
    printf '%s\\r\\n%s\\r\\n' "$1" "$MOCK_RESPONSE"
    return "$MOCK_STATUS"
}
''')
            script = root / 'fg360-sim.sh'
            script.write_text(SCRIPT.read_text().replace('/usr/share/5gmodem/lib.sh', str(library)))
            log = root / 'calls'
            env = dict(os.environ, MOCK_ACTIVE=active, MOCK_LOG=str(log),
                       MOCK_RESPONSE=response, MOCK_STATUS=str(status))
            result = subprocess.run(['sh', '-x', str(script), *args], env=env,
                                    text=True, capture_output=True, check=False)
            commands = log.read_text().splitlines() if log.exists() else []
            return json.loads(result.stdout), result, commands

    def test_status_only_queries_cpin(self):
        for response, return_code, state in [
            ('+CPIN: READY  \nOK', 0, 'ready'), ('+CPIN: SIM PIN\nOK', 0, 'pin'),
            ('+CPIN: SIM PUK\nOK', 0, 'puk'), ('+CME ERROR: 10', 1, 'missing'),
        ]:
            with self.subTest(state=state):
                data, result, commands = self.run_pin('status', 'ccci', response=response, status=return_code)
                self.assertEqual((data, result.returncode, commands),
                                 ({'ok': True, 'state': state}, 0, ['AT+CPIN?|normal']))

    def test_writes_are_typed_and_pin_echo_is_redacted(self):
        operations = {
            'enter': (['0000'], 'AT+CPIN="0000"'),
            'enable': (['0000'], 'AT+CLCK="SC",1,"0000"'),
            'disable': (['0000'], 'AT+CLCK="SC",0,"0000"'),
            'change': (['0000', '1111'], 'AT+CPWD="SC","0000","1111"'),
        }
        for operation, (pins, command) in operations.items():
            with self.subTest(operation=operation):
                data, result, commands = self.run_pin(operation, 'ccci', *pins)
                self.assertEqual((data, result.returncode, commands),
                                 ({'ok': True}, 0, [command + '|high']))
                for pin in pins:
                    self.assertNotIn(pin, result.stdout + result.stderr)

    def test_invalid_arguments_never_reach_modem(self):
        for args, active in [
            (('status', '2-1'), 'ccci'), (('status', 'ccci'), '2-1'),
            (('enter', 'ccci', '000;'), 'ccci'), (('enable', 'ccci', '0000', 'extra'), 'ccci'),
            (('change', 'ccci', '0000', '000'), 'ccci'), (('unknown', 'ccci', '0000'), 'ccci'),
        ]:
            with self.subTest(args=args):
                data, result, commands = self.run_pin(*args, active=active)
                self.assertFalse(data['ok'])
                self.assertEqual((result.returncode, commands), (1, []))

    def test_incorrect_pin_is_reported_once_without_code_echo(self):
        data, result, commands = self.run_pin('enter', 'ccci', '0000', response='+CME ERROR: 16', status=1)
        self.assertEqual((data, result.returncode, commands),
                         ({'ok': False, 'error': 'incorrect_pin'}, 1, ['AT+CPIN="0000"|high']))
        self.assertNotIn('0000', result.stdout + result.stderr)

    def test_only_status_is_granted_for_read_access(self):
        rule = json.loads(ACL.read_text())['luci-app-5gmodem']
        read = [line for line in rule['read']['file'] if 'fg360-sim' in line]
        writes = [line for line in rule['write']['file'] if 'fg360-sim' in line]
        self.assertEqual(read, ['/usr/share/5gmodem/fg360-sim.sh status ccci'])
        self.assertEqual(set(writes), {'/usr/share/5gmodem/fg360-sim.sh ' + command for command in (
            'enter ccci *', 'enable ccci *', 'disable ccci *', 'change ccci * *',
        )})


if __name__ == '__main__':
    unittest.main()
