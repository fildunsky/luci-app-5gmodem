#!/usr/bin/env python3
"""Offline SDX55 BAND_PREF regression checks for issue #67."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

PROFILE = (Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem/modemband/_qualcomm_sdx55_common').read_text()
EN = '1,2,3,5,7,8,12,20,25,28,38,40,41,66,77,78,79'
OFF = '48,71'


class BandPrefTests(unittest.TestCase):
    def run_profile(self, reply):
        with tempfile.TemporaryDirectory() as tmp:
            script = PROFILE.replace('/tmp/5gmodem/', tmp + '/') + '''
_DEVICE=/dev/fake
sms_tool() { printf '%s' "$REPLY"; }
printf 'enabled=%s\\n' "$(getbands5gnsa)"
printf 'supported=%s\\n' "$(getsupportedbands5gnsa)"
'''
            p = subprocess.run(['busybox', 'ash', '-c', script],
                env={**os.environ, 'REPLY': reply}, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return dict(line.split('=', 1) for line in p.stdout.splitlines())

    def test_reply_layouts(self):
        lines = ['AT^BAND_PREF?', 'LTE,Enable Bands :1,3,7',
                 'NR5G,Enable Bands :' + EN, 'NR5G,Disable Bands:' + OFF, 'OK']
        cases = {
            'reported': '\r\n'.join(lines),
            'wrapped': '\r\n'.join(lines).replace('Bands :' + EN, 'Bands :1,\r\n' + EN[2:]),
            'cr_only': '\r'.join(lines),
            'prefixed': '\n'.join('^BAND_PREF: ' + line if ',Enable' in line or ',Disable' in line else line for line in lines),
            'joined_sections': '\n'.join([lines[0], ' '.join(lines[1:4]), lines[4]]),
        }
        enabled = EN.replace(',', ' ')
        supported = ' '.join(str(n) for n in sorted(map(int, (EN + ',' + OFF).split(','))))
        for name, reply in cases.items():
            with self.subTest(name=name):
                d = self.run_profile(reply)
                self.assertEqual(d['enabled'], enabled)
                self.assertEqual(d['supported'], supported)


if __name__ == '__main__':
    unittest.main()
