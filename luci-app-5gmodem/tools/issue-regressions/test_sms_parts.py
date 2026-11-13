"""Long SMS parts are grouped by sender + 8-bit UDH reference + part count.
The reference wraps, so a sender reuses it: an old message must not hide or
absorb a new one with the same reference, a duplicate part number starts a new
group, and a byte-identical copy of a stored part stays with its group so it is
deleted together with it. Also: the Android newcount answer is cached briefly."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell

BRIDGE = (SHARE / 'smsbridge.sh').read_text()


def kb_run(parts):
    """Feed (index, sender, time, text, part, total, ref) rows to _kb_build and
    return {index: (key, members, lead text)}."""
    src = 'KB_WINDOW=' + re.search(r'^KB_WINDOW=(\d+)$', BRIDGE, re.M)[1] + '\n'
    for name in ('_kb_norm', '_kb_put', '_kb_min', '_kb_build'):
        src += function(name, 'smsbridge.sh') + '\n'
    src += '_kb_n=0\n'
    for p in parts:
        src += '_kb_put ' + ' '.join("'%s'" % str(v) for v in p) + " ''\n"
    src += r'''_kb_build
i=1
while [ "$i" -le "$_kb_n" ]; do
	eval "printf '%s\t%s\t%s\t%s\n' \"\$_kb_x$i\" \"\$_kb_k$i\" \"\$_kb_gm$i\" \"\$_kb_gt$i\""
	i=$((i + 1))
done
'''
    result = shell(src)
    assert result.returncode == 0, result.stderr
    out = {}
    for line in result.stdout.splitlines():
        x, k, m, t = line.split('\t')
        out[int(x)] = (k, m.split(), t)
    return out


class BridgeGroups(unittest.TestCase):
    def test_minutes_match_python(self):
        src = function('_kb_min', 'smsbridge.sh') + '''
for t in "1970-01-01 00:00" "2000-03-01 00:00" "2024-02-29 08:09" "2026-12-31 23:59:58" "26/01/01 10:00" ""; do
	_kb_min "$t"; echo "$_KB_M"
done
'''
        got = shell(src).stdout.splitlines()
        want = [str(int(datetime.datetime(*t, tzinfo=datetime.timezone.utc).timestamp()) // 60)
            for t in ((1970, 1, 1), (2000, 3, 1), (2024, 2, 29, 8, 9), (2026, 12, 31, 23, 59))]
        self.assertEqual(got, want + ['', ''])

    def test_reused_reference_months_apart_stays_two_messages(self):
        g = kb_run([
            (1, 'Bank', '2026-01-05 10:00', 'old one ', 1, 2, 7),
            (2, 'Bank', '2026-01-05 10:00', 'old two', 2, 2, 7),
            (3, 'Bank', '2026-06-01 09:00', 'new one ', 1, 2, 7),
            (4, 'Bank', '2026-06-01 09:00', 'new two', 2, 2, 7),
        ])
        self.assertEqual(g[1][1], ['1', '2'])
        self.assertEqual(g[1][2], 'old one old two')
        self.assertEqual(g[3][1], ['3', '4'])
        self.assertEqual(g[3][2], 'new one new two')
        self.assertNotEqual(g[1][0], g[3][0])

    def test_new_message_in_lower_slots_is_not_hidden(self):
        # freed slots are reused: the new message sits before the old one
        g = kb_run([
            (0, 'Bank', '2026-06-01 09:00', 'new one ', 1, 2, 7),
            (1, 'Bank', '2026-06-01 09:00', 'new two', 2, 2, 7),
            (5, 'Bank', '2026-01-05 10:00', 'old one ', 1, 2, 7),
        ])
        self.assertEqual(g[0][2], 'new one new two')
        self.assertEqual(g[5][1], ['3'])
        self.assertEqual(g[5][2], 'old one ')

    def test_taken_part_number_starts_a_new_group(self):
        g = kb_run([
            (1, 'Bank', '2026-06-01 09:00', 'first ', 1, 2, 9),
            (2, 'Bank', '2026-06-01 09:05', 'second ', 1, 2, 9),
            (3, 'Bank', '2026-06-01 09:00', 'tail', 2, 2, 9),
        ])
        self.assertEqual(g[1][1], ['1', '3'])
        self.assertEqual(g[1][2], 'first tail')
        self.assertEqual(g[2][1], ['2'])

    def test_identical_copy_of_a_part_stays_with_its_group(self):
        g = kb_run([
            (1, 'Bank', '2026-06-01 09:00', 'a ', 1, 2, 3),
            (2, 'Bank', '2026-06-01 09:00', 'a ', 1, 2, 3),
            (3, 'Bank', '2026-06-01 09:00', 'b', 2, 2, 3),
        ])
        self.assertEqual(g[1][1], ['1', '2', '3'])
        self.assertEqual(g[1][2], 'a b')
        self.assertEqual(g[1][0], g[2][0])

    def test_resent_segment_keeps_the_later_time(self):
        g = kb_run([
            (1, 'Bank', '2026-09-06 15:09', 'a ', 1, 2, 8),
            (2, 'Bank', '2026-09-06 15:10', 'a ', 1, 2, 8),
            (3, 'Bank', '2026-09-06 15:10', 'b', 2, 2, 8),
        ])
        self.assertEqual(g[1][1], ['1', '2', '3'])
        self.assertTrue(g[1][0].startswith('Bank|2026-09-06 15:10|'))

    def test_window_is_one_day_and_bad_time_keeps_old_joining(self):
        g = kb_run([
            (1, 'Bank', '2026-06-01 09:00', 'x ', 1, 2, 4),
            (2, 'Bank', '2026-06-02 08:59', 'y', 2, 2, 4),
            (3, 'Shop', 'garbage', 'p ', 1, 2, 4),
            (4, 'Shop', '2026-06-01 09:00', 'q', 2, 2, 4),
        ])
        self.assertEqual(g[1][1], ['1', '2'])
        self.assertEqual(g[3][1], ['3', '4'])
        g = kb_run([
            (1, 'Bank', '2026-06-01 09:00', 'x ', 1, 2, 4),
            (2, 'Bank', '2026-06-02 09:01', 'y', 2, 2, 4),
        ])
        self.assertEqual(g[1][1], ['1'])
        self.assertEqual(g[2][1], ['2'])

    def test_single_messages_keep_their_key_format(self):
        g = kb_run([(1, 'Bank', '2026-06-01 09:00', 'hello', 1, 1, 0)])
        self.assertRegex(g[1][0], r'^Bank\|2026-06-01 09:00\|[0-9a-f]{16}$')


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
    m = re.fullmatch(r'@\.(\w+)\[(\*|@\.index=(\d+))\](?:\.(\w+))?', path)
    if not m:
        m2 = re.fullmatch(r'@\.(\w+)', path)
        return [data.get(m2[1])] if m2 and isinstance(data, dict) and m2[1] in data else []
    arr = data.get(m[1]) or []
    if m[3] is not None: arr = [o for o in arr if str(o.get('index')) == m[3]]
    return [o.get(m[4]) for o in arr if m[4] in o] if m[4] else arr
for e in exprs:
    var, path = e.split('=', 1) if re.match(r'^\w+=@', e) else ('', e)
    vals = get(path)
    if var:
        if vals: print('%s=%s;' % (var, shlex.quote(str(vals[0]))))
    else:
        for v in vals: print(v)
'''


class Tools(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / 'bin'
        self.bin.mkdir()
        (self.bin / 'jsonfilter').write_text(JSONFILTER.replace('/usr/bin/env python3', sys.executable))
        (self.bin / 'jsonfilter').chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', D=str(self.dir))

    def tearDown(self):
        self.tmp.cleanup()

    def test_sms_commands_follow_bridge_groups(self):
        msgs = {'msg': [
            {'index': 1, 'sender': '+10000000000', 'timestamp': '2026-01-05 10:00', 'content': 'status ', 'part': 1, 'total': 2, 'reference': 7},
            {'index': 2, 'sender': '+10000000000', 'timestamp': '2026-01-05 10:00', 'content': 'old', 'part': 2, 'total': 2, 'reference': 7},
            {'index': 3, 'sender': '+10000000000', 'timestamp': '2026-06-01 09:00', 'content': 'reboot ', 'part': 1, 'total': 2, 'reference': 7},
            {'index': 4, 'sender': '+10000000000', 'timestamp': '2026-06-01 09:00', 'content': 'now', 'part': 2, 'total': 2, 'reference': 7},
        ], 'keys': [
            {'index': 1, 'key': 'A'}, {'index': 2, 'key': 'A'},
            {'index': 3, 'key': 'B'}, {'index': 4, 'key': 'B'},
        ]}
        res = self.dir / 'res'
        res.mkdir()
        (res / 'smsbridge.sh').write_text("#!/bin/sh\ncat \"$D/msgs.json\"\n")
        (res / 'smsbridge.sh').chmod(0o755)
        (self.dir / 'msgs.json').write_text(json.dumps(msgs))
        (self.dir / 'done').write_text('')
        src = f'''
RES={res}
DONE_MAX=300
CMD_SECRET=""
_cfg() {{ :; }}
uci() {{ :; }}
_log() {{ :; }}
sync() {{ :; }}
sms_cmd_done_file() {{ echo "$D/done"; }}
sms_cmd_key() {{ printf '%s|%s|%s' "$1" "$2" "$3" | md5sum | cut -c1-16; }}
_fresh_cmd() {{ return 0; }}
_find_cmd() {{ printf '%s\\n' "$_o_text" >> "$D/texts"; return 1; }}
''' + function('_o_nltrim', 'smscmd.sh') + '\n' + function('_one', 'smscmd.sh') + '\n_one 1-1\n'
        result = shell(src, self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted((self.dir / 'texts').read_text().splitlines()), ['reboot now', 'status old'])

    def newcount_script(self):
        block = re.search(r'^\tnewcount\)\n.*?^\t\texit 0 ;;\n', BRIDGE, re.M | re.S)[0]
        block = block.replace('/tmp/5gmodem', '$D/run')
        res = self.dir / 'res'
        res.mkdir(exist_ok=True)
        (res / 'android.sh').write_text('android_sms() { echo x >> "$D/calls"; echo \'{"unseen":3}\'; }\n')
        return (f'RES={res}\n_TGT_PATH=1-1.2\nSEEN_DIR=$D\n'
            + re.search(r'^NC_TTL=\d+$', BRIDGE, re.M)[0] + '\n'
            + function('_nc_cache', 'smsbridge.sh').replace('/tmp/5gmodem', '$D/run') + '\n'
            + function('_nc_drop', 'smsbridge.sh') + '\n'
            + '_active_is_android() { return 0; }\n'
            + 'if [ "$DROP" = 1 ]; then _nc_drop; exit 0; fi\n'
            + 'set -- newcount\ncase "$1" in\n' + block + 'esac\n')

    def test_android_newcount_is_cached_and_dropped(self):
        src = self.newcount_script()
        calls = self.dir / 'calls'
        for _ in range(3):
            result = shell(src, self.env)
            self.assertEqual(result.stdout.strip(), '3', result.stderr)
        self.assertEqual(calls.read_text().count('x'), 1)
        shell(src, dict(self.env, DROP='1'))
        self.assertEqual(shell(src, self.env).stdout.strip(), '3')
        self.assertEqual(calls.read_text().count('x'), 2)
        cache = next((self.dir / 'run').glob('smsnc_*'))
        self.assertEqual(cache.name, 'smsnc_1_1_2')
        n, t = cache.read_text().split()
        cache.write_text(f'{n} {int(t) - 3600}\n')
        shell(src, self.env)
        self.assertEqual(calls.read_text().count('x'), 3)

    def test_cache_dropped_on_read_delete_and_seen(self):
        for cmd in ('seen-add', 'markread', 'seen-reset'):
            body = re.search(r'^\t' + cmd + r'\)\n(.*?)^\t\texit 0 ;;', BRIDGE, re.M | re.S)[1]
            self.assertIn('_nc_drop', body, cmd)
        self.assertRegex(BRIDGE, r'case "\$BOX" in delete\|delete-start\|delete-run\) _nc_drop[;a-z_ ]*;; esac')


if __name__ == '__main__':
    unittest.main()
