"""Small fixes taken from fork reviews: sender matching, healing of switched-off interfaces."""
import re
import subprocess
import unittest
from pathlib import Path

SHARE = Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem'


class ForkFindings(unittest.TestCase):
    def same(self, a, b):
        src = re.search(r'^_num_same\(\) \{\n.*?^\}$', (SHARE / 'smscmd.sh').read_text(), re.M | re.S)[0]
        return subprocess.run(['busybox', 'ash', '-c', src + f'\n_num_same "{a}" "{b}"'],
                              timeout=10).returncode == 0

    def test_sender_matches_by_tail(self):
        self.assertTrue(self.same('79001234567', '89001234567'))    # trunk prefix, 10-digit plan
        self.assertTrue(self.same('79001234567', '9001234567'))
        self.assertTrue(self.same('36301234567', '301234567'))      # 9-digit national number
        self.assertTrue(self.same('36301234567', '06301234567'))
        self.assertFalse(self.same('79001234567', '79001234568'))
        self.assertFalse(self.same('', '79001234567'))

    def test_short_codes_match_exactly(self):
        self.assertTrue(self.same('900', '900'))
        self.assertFalse(self.same('900', '1900'))
        self.assertFalse(self.same('123456', '99123456'))

    def test_healing_skips_an_interface_missing_from_the_dump(self):
        text = (SHARE / 'health.sh').read_text()
        block = text[text.index('if [ -z "$_h_auto" ]; then'):text.index('if [ "$_h_auto" = "false" ]; then')]
        self.assertIn('.auto")" = "0" ] && continue', block)
        self.assertIn('.disabled")" = "1" ] && continue', block)


if __name__ == '__main__':
    unittest.main()
