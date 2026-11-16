#!/usr/bin/env python3
# A field report: the operator blocked GitHub, so the in-app update could not download. The owner
# can pick a device (a VPN, a second uplink) in 5gmodem.@5gmodem[0].fetch_dev; net_fetch binds curl
# to it first and falls back to the default route when that fails or curl is missing.
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE, function, shell

STUBS = r'''
uci() { [ -n "$DEV" ] && echo "$DEV"; }
logger() { echo "LOG $*" >> "$D/log"; }
wget() { echo "wget" >> "$D/log"; [ "$WGET" = ok ] && echo direct; }
curl() {
	echo "curl $*" >> "$D/log"
	case "$*" in *"--interface lo"*) [ "$BOUND" = ok ] && echo bound ;; esac
}
command() { [ "$2" = curl ] && [ "$CURL" = 1 ]; }
net_alt_paths() { :; }
net_proxy_port() { return 1; }
'''


class FetchDev(unittest.TestCase):
    def run_fetch(self, dev='lo', bound='ok', wget='ok', curl='1'):
        with tempfile.TemporaryDirectory() as d:
            src = (f'D={d}; DEV="{dev}"; BOUND={bound}; WGET={wget}; CURL={curl}\n' + STUBS +
                   function('_nf_wget', 'lib.sh') + '\n' + function('net_fetch', 'lib.sh') + '\nnet_fetch 5 https://example.invalid/x\n')
            r = shell(src)
            log = (Path(d) / 'log').read_text() if (Path(d) / 'log').exists() else ''
            return r.stdout, log

    def test_picked_device_goes_first(self):
        out, log = self.run_fetch()
        self.assertEqual(out, 'bound')
        self.assertTrue(log.startswith('curl ') and '--interface lo' in log)
        self.assertNotIn('wget', log)

    def test_falls_back_to_the_default_route(self):
        out, log = self.run_fetch(bound='no')
        self.assertEqual(out, 'direct')
        self.assertIn('fetch through lo failed', log)

    def test_unset_bad_or_missing_device_and_no_curl_leave_wget_alone(self):
        for kw in ({'dev': ''}, {'dev': 'lo;reboot'}, {'dev': 'nosuchdev0'}, {'curl': '0'}):
            out, log = self.run_fetch(**kw)
            self.assertEqual(out, 'direct', kw)
            self.assertEqual(log, 'wget\n', kw)


if __name__ == '__main__':
    unittest.main()
