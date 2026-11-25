#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import function, shell


class HpQmiNeighbors(unittest.TestCase):
    def run_sample(self, vidpid='usb/03f09d1d', pci='123', earfcn='1300',
                   neighbors='AT fallback', cached=True):
        qmi = ('{"band":"3","earfcn":"1300","pci":"123","rsrp":"-95.3",'
               '"rsrq":"-10.4","rssi":"-65.8","serving":1},'
               '{"band":"3","earfcn":"1300","pci":"124","rsrp":"-105.2",'
               '"rsrq":"-12.1","rssi":"-85.3","serving":0}')
        with tempfile.TemporaryDirectory() as directory:
            prefix = str(Path(directory) / 'qmi')
            if cached:
                Path(prefix + '.nb').write_text(qmi)
            env = dict(os.environ, _QS_P=prefix, VIDPID=vidpid, PCI=pci,
                       EARFCN=earfcn, NEIGHBORS=neighbors)
            result = shell(function('_qmi_neighbors', '5gmodem.sh') +
                           '\n_qmi_neighbors\nprintf "%s" "$NEIGHBORS"', env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            return result.stdout, qmi

    def test_hp_gets_real_neighbor_rssi(self):
        result, qmi = self.run_sample()
        self.assertEqual(result, qmi)

    def test_cell_change_keeps_current_at_neighbors(self):
        for changes in ({'pci': '125'}, {'earfcn': '1400'}, {'pci': ''}):
            with self.subTest(changes=changes):
                result, _ = self.run_sample(**changes)
                self.assertEqual(result, 'AT fallback')

    def test_missing_qmi_keeps_at_fallback(self):
        result, _ = self.run_sample(cached=False)
        self.assertEqual(result, 'AT fallback')

    def test_other_profiles_keep_their_neighbors(self):
        result, _ = self.run_sample(vidpid='usb/00000000')
        self.assertEqual(result, 'AT fallback')

    def test_generic_empty_neighbors_still_use_qmi(self):
        result, qmi = self.run_sample(vidpid='usb/00000000', neighbors='')
        self.assertEqual(result, qmi)


if __name__ == '__main__':
    unittest.main()
