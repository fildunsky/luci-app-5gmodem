#!/usr/bin/env python3
"""Exercise band AT access policy with the real ModemManager permission helper."""
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


class BandsAtAccess(unittest.TestCase):
    def check_access(self, proto='mbimp', up=True, sim_cached=False, fragile=False,
                     dedicated=False, no_at=False, gcom=False, mm_running=True,
                     mm_owns=True, connected=True, port_exists=True):
        source = (SHARE / 'bands.sh').read_text()
        start = source.index('\n_PORT_OK=0\n')
        end = source.index('\nif [ "$_BAND_VIA" = "mmcli" ]; then', start)
        block = source[start:end]
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            quirks = folder / 'quirks.sh'
            quirks.write_text(function('mm_at_allowed', 'quirks.sh'))
            switch = folder / 'modemswitch.sh'
            switch.write_text('#!/bin/sh\nprintf "%s" "$CASE_MM_INDEX"\n')
            switch.chmod(0o755)
            port = folder / 'at'
            if port_exists:
                port.touch()
            alternate = folder / 'dedicated-at'
            alternate.touch()
            if sim_cached:
                (folder / 'mbimp_sim_modem').write_text('ready\n')
            helper = quirks.read_text().replace('/tmp/5gmodem/', str(folder) + '/')
            quirks.write_text(helper)
            block = block.replace('/usr/share/5gmodem/quirks.sh', str(quirks))
            block = block.replace('/usr/share/5gmodem/modemswitch.sh', str(switch))
            block = block.replace('/tmp/5gmodem/', str(folder) + '/')
            prefix = r'''
_DEVICE="$CASE_PORT"
_bs_am=1-1
_bs_sec=m_1_1
uci() {
 case "$*" in
  *5gmodem.m_1_1.no_at) printf '%s' "$CASE_NO_AT" ;;
  *5gmodem.m_1_1.network) echo modem ;;
  *network.modem.proto) printf '%s' "$CASE_PROTO" ;;
 esac
}
pgrep() {
 case "$*" in
  *gcom*) [ "$CASE_GCOM" = 1 ] ;;
  *ModemManager*) [ "$CASE_MM_RUNNING" = 1 ] ;;
  *) return 1 ;;
 esac
}
mm_at_fragile() {
 echo checked >> "$CASE_TRACE"
 [ "$CASE_FRAGILE" = 1 ] && echo fragile
 return 0
}
mm_dedicated_at() {
 [ "$CASE_DEDICATED" = 1 ] && printf '%s' "$CASE_ALTERNATE"
 return 0
}
_mm_index_cached() { echo 0; }
mmcli() { printf 'modem.generic.state : %s\n' "$CASE_MM_STATE"; }
ubus() {
 if [ "$CASE_UP" = 1 ]; then echo '{"up": true}'; else echo '{"up": false}'; fi
}
at_unlock() { echo unlock >> "$CASE_TRACE"; }
at_lock() { printf 'lock %s\n' "$1" >> "$CASE_TRACE"; }
'''
            # A synthetic USB identity enables the helper's fragile-device branch.
            helper = quirks.read_text().replace('/sys/bus/usb/devices/$1/', str(folder) + '/')
            quirks.write_text(helper)
            (folder / 'idVendor').write_text('0000\n')
            (folder / 'idProduct').write_text('0000\n')
            env = dict(os.environ, CASE_PORT=str(port), CASE_ALTERNATE=str(alternate),
                       CASE_TRACE=str(folder / 'trace'), CASE_PROTO=proto,
                       CASE_NO_AT=str(int(no_at)), CASE_GCOM=str(int(gcom)),
                       CASE_MM_RUNNING=str(int(mm_running)), CASE_UP=str(int(up)),
                       CASE_FRAGILE=str(int(fragile)), CASE_DEDICATED=str(int(dedicated)),
                       CASE_MM_INDEX='0' if mm_owns else '',
                       CASE_MM_STATE='connected' if connected else 'registered')
            result = shell(prefix + block + '\nprintf "%s|%s|%s" "$_PORT_OK" '
                           '"${_MM_AT_STATIC:-0}" "$_DEVICE"', env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            ok, static, device = result.stdout.split('|')
            trace = (folder / 'trace').read_text() if (folder / 'trace').exists() else ''
            return ok, static, device == str(alternate), trace

    def test_mbimp_active_connection_allows_at(self):
        ok, static, _, trace = self.check_access()
        self.assertEqual((ok, static), ('1', '0'))
        self.assertIn('checked', trace)

    def test_mbimp_startup_requires_sim_cache(self):
        self.assertEqual(self.check_access(up=False, sim_cached=True)[0], '1')
        self.assertEqual(self.check_access(up=False)[0], '0')

    def test_fragile_modem_stays_blocked_without_dedicated_port(self):
        for proto in ('mbimp', 'modemmanager'):
            with self.subTest(proto=proto):
                self.assertEqual(self.check_access(proto=proto, fragile=True)[:2], ('0', '1'))

    def test_dedicated_at_port_is_selected_and_locked(self):
        for proto in ('mbimp', 'modemmanager'):
            with self.subTest(proto=proto):
                ok, static, alternate, trace = self.check_access(
                    proto=proto, fragile=True, dedicated=True)
                self.assertEqual((ok, static, alternate), ('1', '0', True))
                self.assertIn('unlock\nlock ', trace)
                self.assertTrue(trace.endswith('/dedicated-at\n'))

    def test_modemmanager_connection_policy_unchanged(self):
        self.assertEqual(self.check_access(proto='modemmanager')[0], '1')
        self.assertEqual(self.check_access(proto='modemmanager', connected=False)[0], '0')

    def test_other_protocols_keep_mm_ownership_protection(self):
        for proto in ('qmi', 'qmiraw', 'mbim', 'rndis', 'dhcp'):
            with self.subTest(proto=proto):
                ok, _, _, trace = self.check_access(proto=proto)
                self.assertEqual(ok, '0')
                self.assertEqual(trace, '')
                self.assertEqual(self.check_access(proto=proto, mm_owns=False)[0], '1')
                self.assertEqual(self.check_access(proto=proto, mm_running=False)[0], '1')

    def test_explicit_no_at_and_busy_or_missing_port_remain_blocked(self):
        for proto in ('mbimp', 'modemmanager', 'qmi'):
            for changes in ({'no_at': True}, {'gcom': True}, {'port_exists': False}):
                with self.subTest(proto=proto, changes=changes):
                    ok, _, _, trace = self.check_access(proto=proto, **changes)
                    self.assertEqual(ok, '0')
                    self.assertEqual(trace, '')


if __name__ == '__main__':
    unittest.main()
