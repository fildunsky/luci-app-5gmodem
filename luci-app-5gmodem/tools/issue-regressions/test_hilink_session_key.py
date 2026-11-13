#!/usr/bin/env python3
# Two ZTE/Tenda/ASR sticks on the same default address behind different interfaces must not share a login token.
import tempfile
import unittest
from pathlib import Path

import re

from test_runtime_audit import SHARE, function, shell


def one_liner(name):
    m = re.search(r'^' + re.escape(name) + r'\(\) \{.*\}$', (SHARE / 'hilink.sh').read_text(), re.M)
    if not m:
        raise ValueError(name)
    return m[0]


class SessionKey(unittest.TestCase):
    def test_token_files_are_per_modem(self):
        with tempfile.TemporaryDirectory() as d:
            src = '\n'.join([
                f'CACHE_DIR={d}',
                'CFG=5gmodem',
                'uci() { [ -n "$ACTIVE" ] && echo "$ACTIVE"; }',
                one_liner('_hl_path'),
                '_hl_src() { :; }',
                'curl() { :; }',
                one_liner('_sk'),
                function('_tenda_raw', 'hilink.sh'),
                'printf A > "$CACHE_DIR/tendaauth_$(_sk 192.168.0.1 1-1)"',
                'printf B > "$CACHE_DIR/tendaauth_$(_sk 192.168.0.1 1-2)"',
                'printf C > "$CACHE_DIR/tendaauth_$(_sk 192.168.0.1)"',
                'curl() { while [ $# -gt 0 ]; do [ "$1" = -b ] && echo "$2"; shift; done; }',
                '_tenda_raw 192.168.0.1 deviceInfo 1-1',
                '_tenda_raw 192.168.0.1 deviceInfo 1-2',
                '_tenda_raw 192.168.0.1 deviceInfo',
                # with an active modem an empty path means that modem: same file as the explicit path
                'ACTIVE=1-2 _tenda_raw 192.168.0.1 deviceInfo',
                one_liner('_asr_ck'),
                '[ "$(_asr_ck 192.168.0.1 1-1)" != "$(_asr_ck 192.168.0.1 1-2)" ] && echo asr-split',
            ])
            r = shell(src, None)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.split(), ['password=A', 'password=B', 'password=C', 'password=B', 'asr-split'])
            # Without a path the file name is the one older versions used.
            self.assertTrue((Path(d) / 'tendaauth_192_168_0_1').exists())


if __name__ == '__main__':
    unittest.main()
