#!/usr/bin/env python3
# In-app updates sat at 5% and 0 bytes while a manual download worked. github.com answers the
# browser_download_url with a Content-Security-Policy line over 4 KB, and uclient-fetch (wget on
# OpenWrt) waits for the end of a header line longer than its 4 KB buffer until the timeout.
# The updater must fetch the package and the release notes through the asset API address with
# "Accept: application/octet-stream", and net_fetch must pass that header on every path.
import os
import re
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE, function, shell

LOG_ARGS = '''#!/bin/sh
printf '%s\\n' "$(basename "$0") $*" >> "$LOG"
o=""
while [ $# -gt 0 ]; do
	case "$1" in -qO|-o) o="$2"; shift ;; esac
	shift
done
[ "$(basename "$0")" = wget ] && [ "$MODE" = direct_fails ] && exit 4
[ "$o" = /dev/null ] && exit 0
if [ -n "$o" ] && [ "$o" != - ]; then printf 'pkg' > "$o"; else printf 'pkg'; fi
'''


class UpdateAssetUrl(unittest.TestCase):
    def test_updater_uses_api_asset_address(self):
        src = (SHARE / 'update.sh').read_text()
        self.assertIn("jsonfilter -e \"@.assets[@.name='$NAME'].url\"", src)
        self.assertIn('ACC="Accept: application/octet-stream"', src)
        self.assertIn('net_fetch 120 "$URL" "$F" "$ACC"', src)
        self.assertRegex(src, r"notes-\$2\.txt'\]\.url\"")
        self.assertIn('net_fetch 10 "$_nl_url" "" "Accept: application/octet-stream"', src)

    def run_fetch(self, mode, out, header='Accept: application/octet-stream'):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'bin').mkdir()
            for name in ('wget', 'curl'):
                f = d / 'bin' / name
                f.write_text(LOG_ARGS)
                f.chmod(0o755)
            env = dict(os.environ, PATH=f'{d / "bin"}:{os.environ["PATH"]}', LOG=str(d / 'log'), MODE=mode)
            target = str(d / 'out') if out else ''
            src = '\n'.join([
                'logger() { :; }',
                f'wget() {{ {d / "bin" / "wget"} "$@"; }}',  # busybox ash prefers its own wget applet
                'net_proxy_port() { echo 7890; }',
                'net_alt_paths() { echo "-x http://127.0.0.1:7890"; }',
                function('net_fetch', 'lib.sh'),
                f'net_fetch 120 https://api.example/assets/1 "{target}" {'"' + header + '"' if header else ''}; echo "rc=$?"',
            ])
            r = shell(src, env)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout, (d / 'log').read_text().splitlines()

    def test_header_on_direct_path(self):
        for out in (True, False):
            stdout, log = self.run_fetch('ok', out)
            self.assertIn('rc=0', stdout)
            self.assertEqual(len(log), 1, log)
            self.assertIn('--header=Accept: application/octet-stream', log[0])

    def test_header_on_fallback_paths(self):
        for out in (True, False):
            stdout, log = self.run_fetch('direct_fails', out)
            self.assertIn('rc=0', stdout)
            curls = [l for l in log if l.startswith('curl ')]
            self.assertEqual(len(curls), 2, log)  # probe and download
            for l in curls:
                self.assertIn('-H Accept: application/octet-stream', l)

    def test_no_header_by_default(self):
        for mode in ('ok', 'direct_fails'):
            stdout, log = self.run_fetch(mode, True, header='')
            self.assertIn('rc=0', stdout)
            for l in log:
                self.assertNotIn('--header', l)
                self.assertNotIn(' -H ', l)
                self.assertNotIn('  ', l)  # an empty argument shows as a double space
                self.assertFalse(l.endswith(' '), l)

if __name__ == '__main__':
    unittest.main()
