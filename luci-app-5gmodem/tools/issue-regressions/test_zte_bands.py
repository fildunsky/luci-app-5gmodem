#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


class ZteBandRouting(unittest.TestCase):
    def classify(self, configured='', kind='hilink', vidpid='19d2:1405', detected='zte', at=''):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            probe = folder / 'probe'
            probe.write_text('#!/bin/sh\necho "$*" >> "$TEST_TRACE"\nprintf "%s" "$TEST_DETECTED"\n')
            probe.chmod(0o755)
            source = function('_bands_hilink_api', 'bands.sh').replace(
                '/usr/share/5gmodem/hilink.sh', str(probe))
            prefix = '''
_bs_sec=m_1_2
_bs_am=1-2
_bs_at="$TEST_AT"
uci() {
 case "$*" in
  *hl_api) printf '%s' "$TEST_CONFIGURED" ;;
  *kind) printf '%s' "$TEST_KIND" ;;
  *vidpid) printf '%s' "$TEST_VIDPID" ;;
 esac
}
jsonfilter() { cat; }
'''
            env = dict(os.environ, TEST_TRACE=str(folder / 'trace'), TEST_AT=at,
                       TEST_CONFIGURED=configured, TEST_KIND=kind,
                       TEST_VIDPID=vidpid, TEST_DETECTED=detected)
            result = shell(prefix + source + '\n_bands_hilink_api', env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            trace = (folder / 'trace').read_text() if (folder / 'trace').exists() else ''
            return result.stdout, trace

    def test_missing_zte_classification_is_detected_read_only(self):
        self.assertEqual(self.classify(), ('zte', 'probe 1-2\n'))

    def test_existing_classification_does_not_probe(self):
        self.assertEqual(self.classify(configured='zte'), ('zte', ''))
        self.assertEqual(self.classify(configured='tenda'), ('tenda', ''))

    def test_other_devices_and_at_ports_do_not_probe(self):
        for changes in ({'kind': 'modem'}, {'vidpid': '0000:0000'}, {'at': '/dev/null'}):
            with self.subTest(changes=changes):
                self.assertEqual(self.classify(**changes), ('', ''))

    def test_non_zte_response_is_not_promoted_to_zte(self):
        self.assertEqual(self.classify(detected='tenda')[0], 'tenda')
        self.assertEqual(self.classify(detected='')[0], '')

    def test_debug_compositions_read_real_supported_and_enabled_bands(self):
        for profile in ('19d21602', '19d21603'):
            with self.subTest(profile=profile):
                source = '''
RES="$TEST_SHARE/modemband"
. "$RES/$TEST_PROFILE"
_DEVICE=/dev/null
awk() { /usr/bin/awk "$@"; }
sms_tool() {
 case "$*" in
  *at+zlteamtband?) echo '+ZLTEAMTBAND:197,0,8,0,160,0,192,0' ;;
  *at+zlteband?) echo '+ZLTEBAND:69,0,0,0,0,0,0,0' ;;
  *) echo unexpected-write >&2; return 1 ;;
 esac
}
getsupportedbands
getbands
'''
                result = shell(source, dict(os.environ, TEST_SHARE=str(SHARE), TEST_PROFILE=profile))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, '')
                self.assertEqual(result.stdout.splitlines(), ['1 3 7 8 20 38 40', '1 3 7'])


if __name__ == '__main__':
    unittest.main()
