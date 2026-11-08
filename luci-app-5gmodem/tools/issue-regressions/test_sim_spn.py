import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


class SimSpn(unittest.TestCase):
    def decode(self, value):
        result = subprocess.run(['busybox', 'awk', '-f', str(SHARE/'sim-spn.awk')],
                                input=value+'\n', capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_chinese_ucs2_names(self):
        for name in ('中国电信', '中国移动', '中国联通', '中國電信'):
            value = '0080'+name.encode('utf-16-be').hex()+'FF'*7
            self.assertEqual(self.decode(value), name)
        raw = bytes.fromhex('804E2D56FD75354FE1')
        self.assertEqual(''.join(chr(b) for b in raw if 32 <= b < 127), 'N-Vu5O')

    def test_gsm_default_and_extended_alphabet(self):
        self.assertEqual(self.decode('00596F7461FFFFFFFFFFFFFFFFFFFFFFFFFF'), 'Yota')
        self.assertEqual(self.decode('0004657374201B65FF'), 'èest €')
        self.assertEqual(self.decode('004F32204445FF'), 'O2 DE')

    def test_compressed_ucs2(self):
        self.assertEqual(self.decode('00810308909192FFFFFFFF'), 'АБВ')
        self.assertEqual(self.decode('0082030410808182FFFFFF'), 'АБВ')

    def test_invalid_or_empty_data_is_not_a_partial_name(self):
        for value in ('', '00', '00FF', '0080FFFF', '001B', '0081', '0081050890',
                      '0080D800', '00804E2', '004G', '00904E2D'):
            with self.subTest(value=value):
                self.assertEqual(self.decode(value), '')

    def test_old_ascii_only_cache_is_not_reused(self):
        source = (SHARE/'5gmodem.sh').read_text()
        source = source[source.index('SPNCACHE='):source.index('\nSPN_NAME=""')]
        with tempfile.TemporaryDirectory() as temp:
            Path(temp+'/spn_460110000000000').write_text('N-Vu5O')
            result = shell(function('sim_spn_decode', 'lib.sh')+'\n'+r'''
SIMID=460110000000000
sms_tool() { echo '+CRSM: 144,0,"00804E2D56FD75354FE1FFFFFFFFFFFFFFFF"'; }
'''+source.replace('/tmp/5gmodem',temp)+'\nprintf "%s" "$SPN"\n', dict(os.environ,RES=str(SHARE)))
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,'中国电信')
            self.assertEqual(Path(temp+'/spn_v2_460110000000000').read_text(),'中国电信\n')
