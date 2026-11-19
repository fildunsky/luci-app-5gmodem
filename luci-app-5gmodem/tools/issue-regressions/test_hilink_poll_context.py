#!/usr/bin/env python3
# Web-API helpers (ZTE, Tenda, Yota) must reach the polled modem through its own interface, not the active one's.
import json
import os
from pathlib import Path
import re
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


STUBS = r'''
CFG=5gmodem
UA=5gmodem
RES=/nonexistent
uci() {
 case "$*" in
  *.active_modem) echo 1-1 ;;
  *m_1_1.netdev) echo eth1 ;;
  *m_1_2.netdev) echo eth2 ;;
  *web_pass|*web_user) echo admin ;;
 esac
}
ip() {
 case "$*" in
  *"addr show dev eth1") echo '    inet 192.168.8.100/24 brd 192.168.8.255 scope global eth1' ;;
  *"addr show dev eth2") echo '    inet 192.168.0.100/24 brd 192.168.0.255 scope global eth2' ;;
  *"route show dev eth1") echo 'default via 192.168.8.1 proto static' ;;
  *"route show dev eth2") echo 'default via 192.168.0.1 proto static' ;;
 esac
}
curl() { _i=""; while [ $# -gt 0 ]; do [ "$1" = --interface ] && _i="$2"; shift; done; echo "if=${_i:-none}"; }
_zte_getpath() { echo goform/goform_get_cmd_process; }
_zte_setpath() { echo goform/goform_set_cmd_process; }
_zte_b64() { printf '%s' "$1"; }
logger() { :; }
'''

HELPERS = ('_netdev_for', '_srcip_for', '_addr_for', '_hl_ctx', '_hl_src',
           '_web_opt', '_zte_get', '_zte_set', '_zte_login',
           '_tenda_raw', '_tenda_post', '_yota_get')
ONE_LINERS = ('_hl_path', '_web_pass', '_zte_pass', '_tk')
MSM_CONFIG = {'reply': 'ok', 'simnum': 2, 'simhaspwd': False}


def one_liner(name, filename='hilink.sh'):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{.*\}$', (SHARE / filename).read_text(), re.M)
    if not match:
        raise ValueError(name)
    return match[0]


class HilinkPollContext(unittest.TestCase):
    def test_web_password_default_empty_and_custom(self):
        command = (SHARE / 'modemswitch.sh').read_text().split('\nwebpass)\n', 1)[1].split('\n\t;;', 1)[0]
        command = command.replace('/tmp/5gmodem/', '"$CACHE_DIR"/')
        helpers = '\n'.join([one_liner('_hl_path'), one_liner('_web_pass'), one_liner('_web_user'),
                             function('_web_opt', 'hilink.sh'), function('_web_set', 'hilink.sh')])
        stub = '''
CFG=5gmodem
uci() {
    shift
    case "$1:$2" in
        get:5gmodem.@5gmodem\\[0\\].active_modem) echo 1-1 ;;
        get:5gmodem.m_1_1) echo modem ;;
        get:*) cat "$CACHE_DIR/$2" 2>/dev/null ;;
        set:*) printf '%s' "${2#*=}" > "$CACHE_DIR/${2%%=*}" ;;
        delete:*) rm -f "$CACHE_DIR/$2" ;;
        commit:*) : ;;
    esac
}
'''
        actions = '''
read_auth() {
    printf '<%s>|<%s> ' "$(_web_user)" "$(_web_pass)"
    if _web_set; then echo configured; else echo factory; fi
}
touch "$CACHE_DIR"/tendaauth_192_168_8_1_1_1.fail "$CACHE_DIR"/tendaauth_192_168_8_1_1_2.fail
touch "$CACHE_DIR"/hilink_192_0_2_1_1_1.msmweb "$CACHE_DIR"/hilink_192_0_2_1_1_1.msmweb.fail
touch "$CACHE_DIR"/hilink_192_0_2_1_1_2.msmweb.fail
read_auth
webpass webpass 1-1 empty
test ! -e "$CACHE_DIR"/tendaauth_192_168_8_1_1_1.fail || exit 1
test -e "$CACHE_DIR"/tendaauth_192_168_8_1_1_2.fail || exit 1
test ! -e "$CACHE_DIR"/hilink_192_0_2_1_1_1.msmweb || exit 1
test ! -e "$CACHE_DIR"/hilink_192_0_2_1_1_1.msmweb.fail || exit 1
test -e "$CACHE_DIR"/hilink_192_0_2_1_1_2.msmweb.fail || exit 1
(webpass webpass 1-1 get)
read_auth
webpass webpass 1-1 set 'synthetic password'
read_auth
webpass webpass 1-1 set ''
read_auth
'''
        with tempfile.TemporaryDirectory() as cache:
            script = stub + helpers + '\nwebpass() {\n' + command + '\n}\n' + actions
            result = shell(script, dict(os.environ, CACHE_DIR=cache))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            '<admin>|<admin> factory', '{"ok":1}', '{"set":1}', '<admin>|<> configured',
            '{"ok":1}', '<admin>|<synthetic password> configured', '{"ok":1}',
            '<admin>|<admin> factory',
        ])

    def test_msm_web_session_retry_keeps_credentials_on_stdin(self):
        output, requests = self.run_msm_web(
            'msm_web setmode 1-2 4 && [ "$(cat "$CACHE_DIR/session.msmweb")" = renewed.test ]',
            [MSM_CONFIG, {'reply': 'SessionOut'}, {'session': 'renewed.test'}, {'reply': 'ok'}],
            token='expired.test',
        )
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertEqual([request['data'] for request in requests], [
            {'cmdid': 'getconfig', 'sessionId': None},
            {'cmdid': 'setnetworkmode', 'sessionId': 'expired.test', 'params': {'netmode': '1'}},
            {'cmdid': 'login', 'sessionId': None, 'username': 'fixture user', 'password': 'fixture "pass" \\ word'},
            {'cmdid': 'setnetworkmode', 'sessionId': 'renewed.test', 'params': {'netmode': '1'}},
        ])
        self.assertEqual([request['authorization'] for request in requests], [
            'Authorization: null', 'Authorization: expired.test',
            'Authorization: null', 'Authorization: renewed.test',
        ])
        for request in requests:
            argv = request['argv']
            self.assertEqual(argv[argv.index('-K') + 1], '-')
            self.assertEqual(argv[argv.index('--interface') + 1], 'test-netdev')
            self.assertEqual(argv[-1], 'http://192.0.2.1/himiapi/json')
            for value in ('expired.test', 'renewed.test', 'fixture', 'sessionId'):
                self.assertNotIn(value, ' '.join(argv))

    def test_msm_web_retries_an_expired_session_only_once(self):
        output, requests = self.run_msm_web(
            'msm_web setmode 1-2 4',
            [MSM_CONFIG, {'reply': 'SessionOut'}, {'session': 'renewed.test'}, {'reply': 'SessionOut'}],
            token='expired.test',
        )
        self.assertNotEqual(output.returncode, 0)
        self.assertEqual([request['data']['cmdid'] for request in requests], [
            'getconfig', 'setnetworkmode', 'login', 'setnetworkmode',
        ])

    def test_msm_web_rejects_unidentified_device_before_using_web_api(self):
        output, requests = self.run_msm_web('msm_web reboot 1-2', [], identified=False)
        self.assertNotEqual(output.returncode, 0)
        self.assertEqual(requests, [])

    def test_msm_web_rejects_netdev_from_another_usb_device(self):
        output, requests = self.run_msm_web('msm_web reboot 1-2', [], matching_netdev=False)
        self.assertNotEqual(output.returncode, 0)
        self.assertEqual(requests, [])

    def test_msm_web_checks_firmware_before_using_credentials_or_cached_token(self):
        for config in ({'reply': 'ok'}, dict(MSM_CONFIG, simnum=8), dict(MSM_CONFIG, simhaspwd=None)):
            with self.subTest(config=config):
                output, requests = self.run_msm_web('msm_web reboot 1-2', [config], token='cached.test')
                self.assertNotEqual(output.returncode, 0)
                self.assertEqual([request['data'] for request in requests], [
                    {'cmdid': 'getconfig', 'sessionId': None},
                ])
                self.assertEqual(requests[0]['authorization'], 'Authorization: null')

    def test_msm_web_identify_is_read_only(self):
        output, requests = self.run_msm_web('msm_web identify 1-2', [MSM_CONFIG])
        self.assertEqual(output.returncode, 0, output.stderr)
        self.assertEqual(json.loads(output.stdout), {'msm_web': True})
        self.assertEqual([request['data'] for request in requests], [
            {'cmdid': 'getconfig', 'sessionId': None},
        ])

    def run_msm_web(self, action, replies, token='', identified=True, matching_netdev=True):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp)
            (path / 'replies').write_text(json.dumps(replies))
            (path / 'session.msmweb').write_text(token)
            (path / 'curl.py').write_text(r'''
import json
import os
from pathlib import Path
import sys

directory = Path(os.environ['CACHE_DIR'])
log = directory / 'requests'
outstanding = json.loads((directory / 'replies').read_text())
index = len(log.read_text().splitlines()) if log.exists() else 0
config = dict((key, json.loads(value)) for key, value in
              (line.rstrip('\n').split(' = ', 1) for line in sys.stdin))
with log.open('a') as requests:
    requests.write(json.dumps({'argv': sys.argv[1:], 'authorization': config['header'],
                               'data': json.loads(config['data-binary'])}) + '\n')
if index >= len(outstanding):
    sys.exit(1)
print(json.dumps(outstanding[index]))
''')
            (path / 'jshn.sh').write_text(r'''
json_init() { :; }
json_add_string() {
	case "$1" in cmdid) cmdid="$2" ;; username) username="$2" ;; password) password="$2" ;; esac
}
json_add_null() { :; }
json_dump() {
	printf '%s\0%s\0%s' "$cmdid" "$username" "$password" |
		python3 -c 'import json, sys; command, user, password = sys.stdin.read().split("\0"); print(json.dumps(dict(cmdid=command, username=user, password=password, sessionId=None)))'
}
''')
            stubs = r'''
curl() { python3 "$CACHE_DIR/curl.py" "$@"; }
legacy_android_usb() { [ "$IDENTIFIED" = yes ] && [ "$1" = 1-2 ]; }
_hl_ctx() { _HC_A=192.0.2.1; _HC_D=test-netdev; }
_msm_web_netdev_matches() { [ "$MATCHING_NETDEV" = yes ] && [ "$_msm_dev" = test-netdev ]; }
_sess_file() { printf '%s/session\n' "$CACHE_DIR"; }
_web_user() { printf '%s' 'fixture user'; }
_web_pass() { printf '%s' 'fixture "pass" \ word'; }
jsonfilter() {
	python3 -c 'import json, sys; v=json.load(sys.stdin).get(sys.argv[1][2:], ""); print(str(v).lower() if isinstance(v, bool) else v)' "$2"
}
'''
            helpers = [function(name, 'hilink.sh') for name in (
                '_msm_web_post', '_msm_web_config', '_msm_web_login', '_msm_web_request', 'msm_web',
            )]
            script = '\n'.join([stubs, one_liner('curl_kq', 'lib.sh'), *helpers, action])
            script = script.replace('/usr/share/libubox/jshn.sh', '"$CACHE_DIR/jshn.sh"')
            result = shell(script, dict(
                os.environ, CACHE_DIR=temp, IDENTIFIED='yes' if identified else 'no',
                MATCHING_NETDEV='yes' if matching_netdev else 'no',
            ))
            log = path / 'requests'
            return result, [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def run_sh(self, body):
        with tempfile.TemporaryDirectory() as cache:
            source = STUBS + '\n'.join([one_liner(n) for n in ONE_LINERS]
                                        + [function(n, 'hilink.sh') for n in HELPERS]) + '\n' + body
            result = shell(source, dict(os.environ, CACHE_DIR=cache))
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.split()

    def test_requests_use_the_polled_modem(self):
        out = self.run_sh('''
_zte_get 192.168.0.1 modem_main_state 1-2
_zte_set 192.168.0.1 goformId=X "" 1-2
_tenda_raw 192.168.0.1 deviceInfo 1-2
_tenda_post 192.168.0.1 sendSms '{}' 1-2
_yota_get 192.168.0.1 1-2
_zte_login 192.168.0.1 1-2 >/dev/null; rm -f "$CACHE_DIR"/ztestok_*; echo "if=$_zl_src"
''')
        self.assertEqual(out, ['if=192.168.0.100'] * 6)

    def test_cached_context_is_used(self):
        out = self.run_sh('''
_hl_ctx 1-2 && ip() { echo unexpected >&2; }
_zte_get "$_HC_A" modem_main_state 1-2
_yota_get "$_HC_A" 1-2
''')
        self.assertEqual(out, ['if=192.168.0.100'] * 2)

    def test_without_path_the_active_modem_decides_as_before(self):
        out = self.run_sh('''
_zte_get 192.168.0.1 modem_main_state
_tenda_raw 192.168.0.1 deviceInfo
_yota_get 192.168.0.1
_zte_get 192.168.8.1 modem_main_state
''')
        self.assertEqual(out, ['if=none', 'if=none', 'if=none', 'if=192.168.8.100'])

    def test_metrics_and_sms_pass_the_path_down(self):
        source = (SHARE / 'hilink.sh').read_text()
        self.assertNotIn('_srcip_for "" ', source)
        for name in ('zte_metrics_json', 'tenda_metrics_json', 'yota_metrics_json'):
            body = function(name, 'hilink.sh')
            for call in re.findall(r'(?:_zte_get|_tenda_on|_tenda_get|_yota_get|_zte_login) "\$_a"[^)\n;>]*', body):
                self.assertTrue(call.rstrip().endswith('"$_HLP"'), (name, call))

    def test_legacy_address_scripts_are_gone(self):
        self.assertFalse((SHARE / 'modem/hilink').exists())
        self.assertNotIn('modem/hilink/', (SHARE / '5gmodem.sh').read_text())


if __name__ == '__main__':
    unittest.main()
