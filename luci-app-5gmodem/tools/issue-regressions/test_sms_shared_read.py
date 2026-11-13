#!/usr/bin/env python3
# Background SMS readers (bot, SMS commands, archive) share one SIM read per pass; pages read live; deletes drop it.
import re
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE, function, shell


def one_liner(name):
    m = re.search(r'^' + re.escape(name) + r'\(\) \{.*\}$', (SHARE / 'smsbridge.sh').read_text(), re.M)
    if not m:
        raise ValueError(name)
    return m[0]


class SharedRead(unittest.TestCase):
    def run_case(self, steps):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / 'reads'
            src = '\n'.join([
                'mkdir -p /tmp/5gmodem',
                f'PORT=/dev/ttyTEST{abs(hash(d)) % 100000}',
                '_LIVE_TTL=20',
                '_smstool() { echo sms_tool; }',
                'utf8_fix() { cat; }',
                '_tz_tag() { printf "%s" "$1"; }',
                f'_sms_run() {{ echo "$STORE" >> {log}; printf \'{{"msg":[{{"index":1,"store":"%s"}}]}}\' "$STORE"; }}',
                one_liner('_live_file'), one_liner('_live_drop'),
                function('_live_bg', 'smsbridge.sh'), function('_live_fresh', 'smsbridge.sh'),
                function('_live_json', 'smsbridge.sh'),
                '_live_drop',
            ] + steps + ['_live_drop'])
            r = shell(src)
            self.assertEqual(r.returncode, 0, r.stderr)
            return (log.read_text().split() if log.exists() else []), r.stdout

    def test_background_readers_share_one_read(self):
        reads, out = self.run_case([
            'BOX=unseen STORE=SM; _live_json >/dev/null',
            'BOX=recv SMS_BG=1 STORE=SM; _live_json >/dev/null',
            'BOX=archive-run SMS_BG= STORE=SM; _live_json',
        ])
        self.assertEqual(reads, ['SM'])
        self.assertIn('"store":"SM"', out)

    def test_pages_read_live_and_storages_do_not_mix(self):
        reads, out = self.run_case([
            'BOX=recv SMS_BG= STORE=SM; _live_json >/dev/null',
            'BOX=recv SMS_BG= STORE=SM; _live_json >/dev/null',
            'BOX=unseen STORE=SM; _live_json >/dev/null',
            'BOX=unseen STORE=ME; _live_json',
        ])
        self.assertEqual(reads, ['SM', 'SM', 'ME'])
        self.assertIn('"store":"ME"', out)

    def test_delete_drops_the_shared_read(self):
        reads, _ = self.run_case([
            'BOX=unseen STORE=SM; _live_json >/dev/null',
            '_live_drop',
            'BOX=unseen STORE=SM; _live_json >/dev/null',
        ])
        self.assertEqual(reads, ['SM', 'SM'])

    def test_helpers_are_defined_before_the_top_level_code_uses_them(self):
        # smsbridge.sh runs top to bottom: the pre-lock check and the delete-time drop run before
        # most functions are defined, so the shared-read helpers must sit above them.
        text = (SHARE / 'smsbridge.sh').read_text()
        def at(pattern):
            m = re.search(pattern, text, re.M)
            self.assertIsNotNone(m, pattern)
            return m.start()
        for fn in ('_live_file', '_live_drop', '_live_bg', '_live_fresh', '_live_json'):
            self.assertLess(at('^' + fn + r'\(\) \{'), at(r'^_LIVE_HIT=""'), fn)
        self.assertLess(at(r'^_live_drop\(\) \{'), at(r'_nc_drop; _live_drop ;; esac'))

    def test_fresh_copy_skips_lock_and_storage_pick(self):
        text = (SHARE / 'smsbridge.sh').read_text()
        self.assertRegex(text, r'elif \[ -n "\$_LIVE_HIT" \]; then _AT_LOCKED=0')
        self.assertRegex(text, r'\[ -n "\$_LIVE_HIT" \] \|\| \{ _store_pick; _cnmi_fix; \}')


if __name__ == '__main__':
    unittest.main()
