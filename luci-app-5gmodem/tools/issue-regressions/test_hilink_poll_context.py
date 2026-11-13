#!/usr/bin/env python3
# Web-API helpers (ZTE, Tenda, Yota) must reach the polled modem through its own interface, not the active one's.
import os
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


def one_liner(name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{.*\}$', (SHARE / 'hilink.sh').read_text(), re.M)
    if not match:
        raise ValueError(name)
    return match[0]


class HilinkPollContext(unittest.TestCase):
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
