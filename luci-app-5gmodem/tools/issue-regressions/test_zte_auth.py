#!/usr/bin/env python3
import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import function, shell
from test_hilink_poll_context import one_liner


class ZteAuth(unittest.TestCase):
    def run_action(self, action, replies, password='synthetic password', metrics=False):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / 'replies').write_text(json.dumps(replies))
            curl = folder / 'curl'
            curl.write_text(r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse
root = Path(os.environ['CACHE_DIR'])
args = sys.argv[1:]
log = root / 'requests'
index = len(log.read_text().splitlines()) if log.exists() else 0
request = {'url': args[-1], 'query': parse_qs(urlparse(args[-1]).query),
           'data': parse_qs(args[args.index('-d')+1], keep_blank_values=True) if '-d' in args else {},
           'source': args[args.index('--interface')+1] if '--interface' in args else '',
           'cookie': args[args.index('-b')+1] if '-b' in args else ''}
with log.open('a') as stream: stream.write(json.dumps(request)+'\n')
replies = json.loads((root / 'replies').read_text())
if index >= len(replies): sys.exit(7)
reply = replies[index]
if reply.get('error'): sys.exit(7)
headers = reply.get('headers', [])
if '-c' in args and headers:
 Path(args[args.index('-c')+1]).write_text('synthetic session cookie\n')
if '-i' in args:
 sys.stdout.write('HTTP/1.1 200 OK\r\n'+'\r\n'.join(headers)+'\r\n\r\n')
body = reply.get('body', {})
sys.stdout.write(json.dumps(body) if isinstance(body, dict) else body)
''')
            curl.chmod(0o755)
            query = folder / 'jsonfilter'
            query.write_text('''#!/usr/bin/env python3
import json,sys
try:
 value=json.load(sys.stdin)
 for key in sys.argv[sys.argv.index('-e')+1].removeprefix('@.').split('.'): value=value[key]
 if value is not None: print(str(value).lower() if isinstance(value,bool) else value)
except (ValueError,KeyError,IndexError,TypeError): pass
''')
            query.chmod(0o755)
            prefix = r'''
CFG=5gmodem
UA=5gmodem
uci() { return 1; }
_hl_path() { echo "${1:-1-1}"; }
_hl_src() { echo "source-$2"; }
_zte_pass() { printf '%s' "$TEST_PASSWORD"; }
_zte_getpath() { echo goform/goform_get_cmd_process; }
_zte_setpath() { echo goform/goform_set_cmd_process; }
logger() { :; }
'''
            names = ('_zte_b64', '_zte_login_secret', '_zte_login', '_zte_get',
                     '_zte_ad', '_zte_set', '_zte_login_jar', '_zte_post_auth')
            source = prefix + '\n'.join([one_liner('_sk'), one_liner('_zj')] +
                                       [function(name, 'hilink.sh') for name in names])
            if metrics:
                source += r'''
_hl_ctx() { _HC_A=192.0.2.1; return 0; }
_vidpid_for() { echo 19d2:1405; }
olax_mt60_usb() { return 1; }
sig_percent() { echo 70; }
jsafe() { printf '%s' "$1"; }
_human() { printf '%s bytes' "$1"; }
zx_battery() { return 1; }
'''
                source += function('zte_metrics_json', 'hilink.sh')
            env = dict(os.environ, CACHE_DIR=directory, TEST_PASSWORD=password,
                       PATH=directory+':'+os.environ['PATH'])
            result = shell(source+'\n'+action, env)
            self.assertEqual(result.stderr, '', result.stderr)
            requests = folder / 'requests'
            return result, [json.loads(line) for line in requests.read_text().splitlines()] if requests.exists() else [], {
                p.name: p.read_text() for p in folder.glob('ztestok_*')}

    @staticmethod
    def challenge(nonce='0123456789ABCDEF'):
        return {'body': {'LD': nonce}}

    @staticmethod
    def success():
        return {'body': {'result': '0'}, 'headers': ['Set-Cookie: stok=synthetic-token; Path=/']}

    def test_sha256_challenge_response(self):
        result, requests, files = self.run_action('_zte_login 192.0.2.1 1-2',
                                                [self.challenge(), self.success()])
        expected = hashlib.sha256((hashlib.sha256(b'synthetic password').hexdigest().upper()+
                                   '0123456789ABCDEF').encode()).hexdigest().upper()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests[0]['query']['cmd'], ['LD'])
        self.assertNotIn('multi_data', requests[0]['query'])
        self.assertEqual(requests[1]['data']['password'], [expected])
        self.assertTrue(any(name.endswith('.sha256') for name in files))
        self.assertTrue(all(req['source'] == 'source-1-2' for req in requests))

    def test_legacy_base64_password_remains_supported(self):
        password = 'synthetic ? password'
        result, requests, files = self.run_action('_zte_login 192.0.2.1 1-2',
                                                [{'body': {}}, self.success()], password=password)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests[1]['data']['password'], [base64.b64encode(password.encode()).decode()])
        self.assertFalse(any(name.endswith('.sha256') for name in files))

    def test_empty_password_uses_the_selected_auth_scheme(self):
        for challenge in (self.challenge(), {'body': {}}):
            with self.subTest(challenge=challenge):
                result, requests, _ = self.run_action('_zte_login 192.0.2.1 1-2',
                                                     [challenge, self.success()], password='')
                self.assertEqual(result.returncode, 0)
                self.assertEqual(len(requests), 2)
                self.assertNotEqual(requests[1]['data']['password'], [base64.b64encode(b'admin').decode()])

    def test_failed_login_does_not_cycle_through_password_formats(self):
        for headers in ([], ['Set-Cookie: stok=rejected; Path=/']):
            with self.subTest(headers=headers):
                result, requests, files = self.run_action(
                    '_zte_login 192.0.2.1 1-2; _zte_login 192.0.2.1 1-2',
                    [self.challenge(), {'body': {'result': '3'}, 'headers': headers}])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(requests), 2)
                self.assertTrue(any(name.endswith('.fail') for name in files))
                self.assertFalse(any(name.endswith('.sha256') for name in files))

    def test_malformed_challenge_never_sends_password(self):
        result, requests, _ = self.run_action('_zte_login 192.0.2.1 1-2', [self.challenge('bad nonce')])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]['data'], {})

    def test_sessions_are_cached_and_separated_by_modem_path(self):
        result, requests, _ = self.run_action(
            '_zte_login 192.0.2.1 1-1; _zte_login 192.0.2.1 1-1; _zte_login 192.0.2.1 1-2',
            [self.challenge(), self.success(), self.challenge(), self.success()])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 4)
        self.assertEqual([req['source'] for req in requests], ['source-1-1']*2+['source-1-2']*2)

    def test_authenticated_control_uses_cookie_and_fresh_ad(self):
        rd = {'wa_inner_version': 'TEST_INTERNAL', 'cr_version': 'TEST_RELEASE', 'RD': 'ABCDEF01'}
        result, requests, _ = self.run_action(
            '_zte_login 192.0.2.1 1-2 >/dev/null; _zte_set 192.0.2.1 goformId=REBOOT_DEVICE "" 1-2',
            [self.challenge(), self.success(), {'body': rd}, {'body': {'result': 'success'}}])
        self.assertEqual(result.returncode, 0)
        token = hashlib.md5(b'TEST_INTERNALTEST_RELEASE').hexdigest()
        expected = hashlib.md5((token+'ABCDEF01').encode()).hexdigest()
        self.assertEqual(requests[-1]['data']['AD'], [expected])
        self.assertTrue(requests[-1]['cookie'].endswith('ztejar_192_0_2_1_1_2'))

    def test_missing_ad_data_does_not_send_control(self):
        result, requests, _ = self.run_action(
            '_zte_login 192.0.2.1 1-2 >/dev/null; _zte_set 192.0.2.1 goformId=REBOOT_DEVICE "" 1-2',
            [self.challenge(), self.success(), {'body': {}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(requests), 3)
        self.assertFalse(any(req['data'].get('goformId') == ['REBOOT_DEVICE'] for req in requests))

    def test_legacy_control_keeps_its_request_format(self):
        result, requests, _ = self.run_action(
            '_zte_set 192.0.2.1 goformId=REBOOT_DEVICE "" 1-2',
            [{'body': {'result': 'success'}}])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 1)
        self.assertNotIn('AD', requests[0]['data'])

    def test_expired_session_is_reauthenticated_once(self):
        rd = {'wa_inner_version': 'TEST_INTERNAL', 'cr_version': 'TEST_RELEASE', 'RD': 'ABCDEF01'}
        result, requests, _ = self.run_action(
            '_zte_login 192.0.2.1 1-2 >/dev/null; _zte_post_auth 192.0.2.1 goformId=REBOOT_DEVICE 1-2',
            [self.challenge(), self.success(), {'body': {}}, self.challenge('1234ABCD'),
             self.success(), {'body': rd}, {'body': {'result': 'success'}}])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(requests), 7)
        self.assertEqual(sum(req['data'].get('goformId') == ['LOGIN'] for req in requests), 2)
        self.assertEqual(sum(req['data'].get('goformId') == ['REBOOT_DEVICE'] for req in requests), 1)

    def test_known_sha256_device_does_not_fall_back_after_nonce_error(self):
        result, requests, _ = self.run_action(
            '_zte_login 192.0.2.1 1-2 >/dev/null; _zte_login_jar 192.0.2.1 1-2 0',
            [self.challenge(), self.success(), {'body': {}}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(requests), 3)

    def test_legacy_username_password_login_is_preserved(self):
        result, requests, _ = self.run_action('_zte_login_jar 192.0.2.1 1-2 1',
            [{'body': {}}, {'body': {'result': '0'}}])
        self.assertEqual(result.returncode, 0)
        self.assertEqual(requests[1]['data']['password'],
                         [base64.b64encode(b'admin\nsynthetic password').decode()])

    def test_login_restores_band_signal_and_connection_duration(self):
        public = {'ppp_status': 'ppp_connected', 'network_type': 'LTE', 'signalbar': '3'}
        private = dict(public, hardware_version='MF79N-TEST', lte_rsrp='-95.5 dBm',
                       rsrq='-10.5', Z_SINR='16.2', lte_band='B3', realtime_time='000128')
        result, requests, _ = self.run_action('zte_metrics_json 1-2',
            [{'body': public}, self.challenge(), self.success(), {'body': private}], metrics=True)
        self.assertEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertEqual([data['rsrp'], data['rsrq'], data['sinr'], data['pband']],
                         ['-95.5', '-10.5', '16.2', 'B3'])
        self.assertEqual(data['conn_time_sec'], '128')
        self.assertEqual(data['conn_time'], '0d, 00:02:08')
        self.assertEqual(len(requests), 4)


if __name__ == '__main__':
    unittest.main()
