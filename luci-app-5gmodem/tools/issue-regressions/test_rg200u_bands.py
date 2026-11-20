#!/usr/bin/env python3
"""Offline band management checks for the RG200U-CN product profile."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROFILES = Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem/modemband'
CAPABILITIES = '\r\n'.join([
    'AT+QNWPREFCFG=?',
    '+QNWPREFCFG: "mode_pref",AUTO:WCDMA:LTE:NR5G:NR5G-SA:NR5G-NSA',
    '+QNWPREFCFG: "gw_band",1:8',
    '+QNWPREFCFG: "lte_band",1:3:5:8:34:38:39:40:41',
    '+QNWPREFCFG: "nr5g_band",1:5:8:28:41:77:78:79',
    '+QNWPREFCFG: "all_band_reset"',
    'OK',
])
MODEM = r'''
at_query() {
    local key tail
    [ "$1" = /dev/null ] || return 1
    case "$2" in
        'AT+QNWPREFCFG=?') printf '%s\n' "$CAPABILITIES" ;;
        AT+QNWPREFCFG=*)
            tail=${2#AT+QNWPREFCFG=}
            key=${tail%%,*}
            key=${key//\"/}
            case "$tail" in
                *,*)
                    printf '%s\n' "$2" >> "$STATE/writes"
                    [ "$IGNORE_WRITE" = 1 ] || printf '%s\n' "${tail#*,}" > "$STATE/$key"
                    ;;
                *) printf '+QNWPREFCFG: "%s",%s\r\nOK\r\n' "$key" "$(cat "$STATE/$key")" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
. "$RES/2c7c0900RG200U-CN"
_DEVICE=/dev/null
'''


class RG200UBandsTests(unittest.TestCase):
    def run_profile(self, body, bands='0', capabilities=CAPABILITIES, ignore_write=False):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            for key in ('gw_band', 'lte_band', 'nr5g_band'):
                (state / key).write_text(bands)
            env = dict(os.environ, RES=str(PROFILES), STATE=tmp, CAPABILITIES=capabilities,
                       IGNORE_WRITE='1' if ignore_write else '0')
            result = subprocess.run(['busybox', 'ash', '-ec', MODEM + body],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            writes = state / 'writes'
            return result.stdout.splitlines(), writes.read_text().splitlines() if writes.exists() else []

    def test_read_supported_and_automatic_bands_for_each_radio(self):
        output, writes = self.run_profile('''
getinfo
bands3g_style
getsupportedbands3g
getbands3g
getsupportedbands
getbands
getsupportedbands5gnsa
getbands5gnsa
getsupportedbands5gsa
''')
        self.assertEqual(output, [
            'Quectel RG200U-CN', 'mask', '1 8', '1 8',
            '1 3 5 8 34 38 39 40 41', '1 3 5 8 34 38 39 40 41',
            '1 5 8 28 41 77 78 79', '1 5 8 28 41 77 78 79', 'Unsupported',
        ])
        self.assertEqual(writes, [])

    def test_each_rat_has_its_own_write_and_reset(self):
        output, writes = self.run_profile('''
setbands3g '8 1'
setbands '41 3 41'
setbands5gnsa '78 41'
getbands3g
getbands
getbands5gnsa
setbands3g default
setbands default
setbands5gnsa default
''')
        self.assertEqual(output, ['1 8', '3 41', '41 78'])
        self.assertEqual(writes, [
            'AT+QNWPREFCFG="gw_band",1:8',
            'AT+QNWPREFCFG="lte_band",3:41',
            'AT+QNWPREFCFG="nr5g_band",41:78',
            'AT+QNWPREFCFG="gw_band",0',
            'AT+QNWPREFCFG="lte_band",0',
            'AT+QNWPREFCFG="nr5g_band",0',
        ])

    def test_unlisted_bands_are_rejected_before_writing(self):
        output, writes = self.run_profile('''
if setbands '1 2'; then exit 1; fi
if setbands3g '5'; then exit 1; fi
if setbands5gnsa '2'; then exit 1; fi
if setbands '0'; then exit 1; fi
if setbands '1:3'; then exit 1; fi
''')
        self.assertEqual(output, [])
        self.assertEqual(writes, [])

    def test_incomplete_capabilities_do_not_allow_writes(self):
        output, writes = self.run_profile('''
if getsupportedbands; then exit 1; fi
if setbands '3'; then exit 1; fi
''', capabilities=CAPABILITIES.replace('1:3:5:8:34:38:39:40:41', '1:3:513'))
        self.assertEqual(output, [])
        self.assertEqual(writes, [])

    def test_write_with_unchanged_readback_is_rejected(self):
        output, writes = self.run_profile('''
if setbands5gnsa 78; then exit 1; fi
''', bands='41', ignore_write=True)
        self.assertEqual(output, [])
        self.assertEqual(writes, ['AT+QNWPREFCFG="nr5g_band",78'])


if __name__ == '__main__':
    unittest.main()
