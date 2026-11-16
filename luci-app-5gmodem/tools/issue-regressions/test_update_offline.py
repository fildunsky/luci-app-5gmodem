#!/usr/bin/env python3
# A field report: on a whitelist link where only a VPN core gets out, the in-app update hung at
# "unpacking": apk add fetched every package list over the default route first, and uclient-fetch
# never gave up on a connection that did not open. The file is now installed without the network
# when its dependencies are present; lists, when needed, go through the "Download through" device
# with a hard limit on the plain wget.
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE

SRC = (SHARE / 'update.sh').read_text()


def shim():
    return re.search(r"<<'SHIM'\n(.*?)\nSHIM\n", SRC, re.S).group(1)


class UpdateOffline(unittest.TestCase):
    def test_offline_install_first_then_lists(self):
        body = re.search(r'apk_install\(\) \{(.*?)\n\t\t\}', SRC, re.S).group(1)
        lines = [l.strip() for l in body.splitlines() if l.strip().startswith(('apk', 'echo deps'))]
        self.assertTrue(lines[0].startswith('apk add --no-network --allow-untrusted'), lines)
        self.assertEqual(lines[1], 'echo deps > "$STEP"')
        self.assertTrue(all(l.startswith(('apk_net', 'echo')) for l in lines[1:]), lines)

    def run_shim(self, dev, curl_ok, out='-'):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'bin').mkdir()
            (d / 'net' / 'tun0').mkdir(parents=True)
            (d / 'shim').write_text(shim().replace('/sys/class/net/', str(d / 'net') + '/'))
            (d / 'bin' / 'curl').write_text(
                '#!/bin/sh\necho "curl $*" >> "$LOGF"\n'
                + ('o=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done; echo BOUND > "$o"\n'
                   if curl_ok else 'exit 7\n'))
            (d / 'bin' / 'wget').write_text('#!/bin/sh\necho "wget $*" >> "$LOGF"\necho DIRECT\n')
            (d / 'bin' / 'logger').write_text('#!/bin/sh\n')
            for f in ('curl', 'wget', 'logger'):
                os.chmod(d / 'bin' / f, 0o755)
            env = dict(os.environ, PATH=f'{d / "bin"}:{os.environ["PATH"]}', LOGF=str(d / 'log'),
                       PM_FETCH_DEV=dev, PM_REAL_WGET=str(d / 'bin' / 'wget'), TMPDIR=str(d))
            r = subprocess.run(['sh', str(d / 'shim'), '-q', '-T', '60', 'https://x/packages.adb', '-O', out],
                               env=env, capture_output=True, text=True, timeout=30)
            return r.returncode, r.stdout, (d / 'log').read_text()

    def test_lists_go_through_the_picked_device(self):
        rc, out, log = self.run_shim('tun0', True)
        self.assertEqual((rc, out), (0, 'BOUND\n'))
        self.assertIn('--interface tun0', log)
        self.assertNotIn('wget', log)

    def test_falls_back_to_plain_wget(self):
        for dev, ok in (('tun0', False), ('', True), ('nosuch0', True)):
            rc, out, log = self.run_shim(dev, ok)
            self.assertEqual((rc, out), (0, 'DIRECT\n'), dev)
            self.assertIn('wget -q -T 60 -O - https://x/packages.adb', log)


if __name__ == '__main__':
    unittest.main()
