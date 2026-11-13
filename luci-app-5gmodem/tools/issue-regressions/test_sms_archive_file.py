#!/usr/bin/env python3
# The router-side SMS archive is one file per modem (it was a file per message: ~4 KB of flash
# each on ubifs). Checks the record format round trip, the one-time migration of the old
# directory, merge without duplicates, the trim, deletes and a record cut short by power loss.
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import SHARE, function, shell

JSONFILTER = r'''#!/usr/bin/env python3
import json, re, shlex, sys
args = sys.argv[1:]
data = None
exprs = []
while args:
    a = args.pop(0)
    if a == '-e': exprs.append(args.pop(0))
    elif a == '-i': data = json.load(open(args.pop(0)))
if data is None: data = json.loads(sys.stdin.read() or 'null')
def get(path):
    m = re.fullmatch(r'@\.(\w+)\[(\*|\d+)\](?:\.(\w+))?', path)
    if not m: return []
    arr = data.get(m[1]) or []
    if m[2] != '*':
        i = int(m[2]); arr = arr[i:i + 1]
    return [o.get(m[3]) for o in arr if m[3] in o] if m[3] else arr
for e in exprs:
    var, path = e.split('=', 1) if re.match(r'^\w+=@', e) else ('', e)
    vals = get(path)
    if var:
        if vals: print('%s=%s;' % (var, shlex.quote(str(vals[0]))))
    else:
        for v in vals: print(v)
'''

FUNCS = ('_nl_trim', '_arch_key', '_arch_dir', '_arch_lock', '_arch_unlock', '_arch_rec', '_arch_ready',
         '_arch_each', '_arch_drop', '_arch_next', '_arch_files', '_arch_read', '_arch_trim', '_arch_merge',
         '_arch_index', '_arch_text_one', '_arch_text', '_arch_count', '_arch_del_index', '_arch_wipe',
         '_arch_del_live')


def until_end(name):
    # _arch_read has a line that starts with "}" inside a string, so the generic helper stops too early
    text = (SHARE / 'smsbridge.sh').read_text()
    m = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?\n\t\} < "\$1"\n\}\n', text, re.M | re.S)
    if not m:
        raise ValueError(name)
    return m[0]


def one_liner(name):
    m = re.search(r'^' + re.escape(name) + r'\(\) \{.*\}$', (SHARE / 'smsbridge.sh').read_text(), re.M)
    if not m:
        raise ValueError(name)
    return m[0]


class ArchiveFile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        (self.d / 'bin').mkdir()
        jf = self.d / 'bin' / 'jsonfilter'
        jf.write_text(JSONFILTER.replace('/usr/bin/env python3', sys.executable))
        jf.chmod(0o755)
        (self.d / 'etc').mkdir()
        self.env = dict(os.environ, PATH=f'{self.d / "bin"}:{os.environ["PATH"]}')
        self.db = self.d / 'etc' / 'sms_arch.1_2.db'
        self.old = self.d / 'etc' / 'sms_arch.1_2'

    def tearDown(self):
        self.tmp.cleanup()

    def run_sh(self, body, arch_max=500):
        src = '\n'.join([
            f'SEEN_DIR={self.d / "etc"}', '_TGT_PATH=1-2', 'ARCH_BASE=100000', f'ARCH_MAX={arch_max}',
            '_LIVE_MAP=" "', 'logger() { :; }',
            # print every record as JSON-ish lines for the test to parse
            '_dump_one() { printf "%s\\037%s\\037%s\\037%s\\037%s\\037%s\\037%s\\037%s\\037%s\\036" '
            '"$_A_IDX0" "$_A_KEY" "$_A_TS" "$_A_FROM" "$_A_TEXT" "$_A_PART" "$_A_TOTAL" "$_A_REF" "$_A_TZ"; }',
            one_liner('_arch_file'),
        ] + [until_end(n) if n == '_arch_read' else function(n, 'smsbridge.sh') for n in FUNCS] + [body])
        r = shell(src, self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def records(self):
        out = self.run_sh('_arch_each _dump_one')
        recs = []
        for rec in out.split('\x1e'):
            if rec:
                f = rec.split('\x1f')
                recs.append(dict(zip(('idx', 'key', 'ts', 'from', 'text', 'part', 'total', 'ref', 'tz'), f)))
        return recs

    def merge(self, msgs, arch_max=500):
        (self.d / 'live.json').write_text(json.dumps({'msg': msgs}))
        return self.run_sh(f'_arch_merge "$(cat {self.d / "live.json"})"', arch_max)

    def test_round_trip_keeps_any_text(self):
        tricky = '@not a header\nTnot a time\nFnot a sender\n leading space\n\nlast'
        self.merge([
            {'index': 3, 'sender': 'Bank\r', 'timestamp': '2026-10-01 10:00', 'content': tricky, 'tz': '+180'},
            {'index': 4, 'sender': 'Op', 'timestamp': '2026-10-02 11:00', 'content': 'part one',
             'part': 1, 'total': 2, 'reference': 7},
            {'index': 5, 'sender': 'Op', 'timestamp': '2026-10-02 11:00', 'content': 'part two',
             'part': 2, 'total': 2, 'reference': 7, 'tz': 'local'},
        ])
        r = self.records()
        self.assertEqual([x['idx'] for x in r], ['100000', '100001', '100002'])
        self.assertEqual(r[0]['text'], tricky)
        self.assertEqual(r[0]['from'], 'Bank')
        self.assertEqual(r[0]['tz'], '+180')
        self.assertEqual((r[1]['part'], r[1]['total'], r[1]['ref']), ('1', '2', '7'))
        self.assertEqual(r[2]['tz'], 'local')
        self.assertFalse(self.old.exists())
        # merging the same live list again adds nothing
        self.merge([{'index': 3, 'sender': 'Bank\r', 'timestamp': '2026-10-01 10:00', 'content': tricky, 'tz': '+180'}])
        self.assertEqual(len(self.records()), 3)
        self.assertEqual(self.run_sh('_arch_count').strip(), '3')

    def test_old_directory_is_migrated_once(self):
        self.old.mkdir()
        (self.old / '100000.aaaaaaaaaaaaaaaa').write_text('#tz=local\n2026-10-01 10:00\nRSCHS\r\nline one\n@second')
        (self.old / '100002.bbbbbbbbbbbbbbbb').write_text('#p=1/2/9\n2026-10-03 12:00\nBank\npart')
        (self.old / '100001.cccccccccccccccc').write_text('2026-10-02 11:00\nX\n')
        os.utime(self.old / '100000.aaaaaaaaaaaaaaaa', (1700000000, 1700000000))
        r = self.records()
        self.assertEqual(r, [])  # _arch_each alone does not migrate
        out = self.run_sh('_arch_text')
        self.assertFalse(self.old.exists())
        r = self.records()
        self.assertEqual([x['idx'] for x in r], ['100000', '100001', '100002'])
        self.assertEqual([x['key'] for x in r], ['aaaaaaaaaaaaaaaa', 'cccccccccccccccc', 'bbbbbbbbbbbbbbbb'])
        self.assertEqual(r[0]['text'], 'line one\n@second')
        self.assertEqual(r[0]['from'], 'RSCHS')
        self.assertEqual(r[0]['tz'], 'local')
        self.assertEqual((r[2]['part'], r[2]['total'], r[2]['ref']), ('1', '2', '9'))
        self.assertIn('@100000|aaaaaaaaaaaaaaaa|1700000000|', self.db.read_text())
        self.assertIn('MSG: 100000', out)
        # the next stored message continues after the migrated indexes
        self.merge([{'index': 1, 'sender': 'New', 'timestamp': '2026-11-01 10:00', 'content': 'hi'}])
        self.assertEqual(self.records()[-1]['idx'], '100003')

    def test_trim_keeps_the_newest(self):
        self.merge([{'index': i, 'sender': 'S', 'timestamp': f'2026-10-0{i} 10:00', 'content': f'm{i}'}
                    for i in range(1, 6)], arch_max=3)
        self.assertEqual([x['text'] for x in self.records()], ['m3', 'm4', 'm5'])

    def test_deletes_and_wipe(self):
        msgs = [{'index': i, 'sender': 'S', 'timestamp': f'2026-10-0{i} 10:00', 'content': f'm{i}'} for i in range(1, 5)]
        self.merge(msgs)
        self.run_sh('_arch_del_index 100001')
        self.assertEqual([x['text'] for x in self.records()], ['m1', 'm3', 'm4'])
        (self.d / 'live.json').write_text(json.dumps({'msg': msgs}))
        self.run_sh(f'_arch_del_live 3 "$(cat {self.d / "live.json"})"')
        self.assertEqual([x['text'] for x in self.records()], ['m1', 'm4'])
        self.run_sh('_arch_wipe')
        self.assertFalse(self.db.exists())
        self.assertEqual(self.run_sh('_arch_count').strip(), '0')

    def test_record_cut_short_is_skipped(self):
        self.merge([{'index': 1, 'sender': 'S', 'timestamp': '2026-10-01 10:00', 'content': 'whole'}])
        with open(self.db, 'a') as f:
            f.write('@100001|dddddddddddddddd|0||\nT2026-10-02')
        self.assertEqual([x['text'] for x in self.records()], ['whole'])


if __name__ == '__main__':
    unittest.main()
