#!/usr/bin/env python3
"""Batch backend calls: `stats.sh bundle` answers a whole Statistics refresh in one
exec, `buttons.sh save` writes a whole button card in one exec. Both must give the
same result as the old per-item subcommands, which stay for older pages."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SHARE = ROOT / 'root/usr/share/5gmodem'

# flat-file uci: "<key>=<value>" lines, one file per config; commits are counted
UCI_STUB = r'''#!/usr/bin/env python3
import os, sys
st = os.environ['UCI_ST']
a = [x for x in sys.argv[1:] if x != '-q']
def path(cfg): return os.path.join(st, cfg)
def load(cfg):
    d = {}
    try:
        for line in open(path(cfg)):
            k, _, v = line.rstrip('\n').partition('=')
            d[k] = v
    except FileNotFoundError:
        pass
    return d
def save(cfg, d):
    with open(path(cfg), 'w') as f:
        for k, v in d.items():
            f.write(k + '=' + v + '\n')
if not a:
    sys.exit(1)
cmd = a[0]
if cmd == 'get':
    cfg = a[1].split('.')[0]
    d = load(cfg)
    if a[1] in d:
        print(d[a[1]]); sys.exit(0)
    sys.exit(1)
if cmd == 'set':
    k, _, v = a[1].partition('=')
    cfg = k.split('.')[0]
    d = load(cfg); d[k] = v; save(cfg, d); sys.exit(0)
if cmd == 'delete':
    cfg = a[1].split('.')[0]
    d = load(cfg)
    for k in [k for k in d if k == a[1] or k.startswith(a[1] + '.')]:
        del d[k]
    save(cfg, d); sys.exit(0)
if cmd == 'add':
    d = load(a[1])
    n = sum(1 for k in d if k.count('.') == 1)
    name = 'cfg%02d' % n
    d[a[1] + '.' + name] = a[2]; save(a[1], d); print(name); sys.exit(0)
if cmd == 'show':
    for k, v in load(a[1]).items():
        print("%s=%s" % (k, v) if k.count('.') == 1 else "%s='%s'" % (k, v))
    sys.exit(0)
if cmd == 'commit':
    with open(os.path.join(st, 'commits'), 'a') as f:
        f.write((a[1] if len(a) > 1 else '') + '\n')
    sys.exit(0)
sys.exit(0)
'''


def run(args, **kw):
    return subprocess.run(['busybox', 'ash'] + args, text=True, capture_output=True, timeout=60, **kw)


class StatsBundle(unittest.TestCase):
    def make(self, temp, overrides=''):
        source = (SHARE / 'stats.sh').read_text()
        source = source.replace('/tmp/5gmodem', str(temp))
        source = source.replace('. "$RES/lib.sh" 2>/dev/null', 'uci() { return 1; }')
        source = source.replace('case "$1" in\ntick)', overrides + '\ncase "$1" in\ntick)')
        script = temp / 'stats.sh'
        script.write_text(source)
        d = temp / 'stats'
        d.mkdir()
        (d / 'ping.wan').write_text('100 20\n110 25\n')
        (d / 'ping.wan.label').write_text('WAN "uplink"\n')
        (d / 'signal.m_1_1').write_text('100 70\nbad x\n130 -71.5\n')
        (d / 'signal.m_1_1.label').write_text('Modem\n')
        (d / 'rsrp.m_1_1').write_text('100 -95\n')
        (d / 'traffic.sim-000000000000000.2026-11').write_text('10 20\n')
        (d / 'traffic.wan.2026-10').write_text('5 6\n')
        return script

    def test_bundle_matches_old_subcommands(self):
        with tempfile.TemporaryDirectory() as temp:
            script = str(self.make(Path(temp)))
            bundle = run([script, 'bundle'])
            self.assertEqual(bundle.returncode, 0, bundle.stderr)
            b = json.loads(bundle.stdout)
            self.assertEqual(b['list'], json.loads(run([script, 'list']).stdout))
            self.assertEqual(b['traffic'], json.loads(run([script, 'traffic']).stdout))
            names = []
            for kind in ('ping', 'signal', 'temp', 'rsrp', 'sinr'):
                names += [kind + '.' + n for n in b['list'][kind]]
            self.assertEqual(sorted(b['series']), sorted(names))
            for n in names:
                old = json.loads(run([script, 'series', n]).stdout)
                self.assertEqual(b['series'][n], old['series'], n)
            self.assertEqual(b['series']['signal.m_1_1'], [[100, 70], [130, -71.5]])

    def test_bundle_tick_collects_first(self):
        overrides = '''
_enabled() { return 0; }
_restore() { :; }
_mdm_init() { :; }
_mdm_reconcile() { :; }
_collect_ping() { printf '200 30\\n' >> "$DIR/ping.wan"; }
_collect_signal() { :; }
_collect_traffic() { :; }
_flush() { :; }
'''
        with tempfile.TemporaryDirectory() as temp:
            script = str(self.make(Path(temp), overrides))
            plain = json.loads(run([script, 'bundle']).stdout)
            self.assertEqual(len(plain['series']['ping.wan']), 2)
            ticked = run([script, 'bundle', 'tick'])
            self.assertEqual(ticked.returncode, 0, ticked.stderr)
            self.assertEqual(json.loads(ticked.stdout)['series']['ping.wan'][-1], [200, 30])
            # old tick still works on its own
            self.assertEqual(run([script, 'tick']).returncode, 0)


class ButtonsSave(unittest.TestCase):
    def env(self, temp):
        b = temp / 'bin'
        b.mkdir()
        (b / 'uci').write_text(UCI_STUB)
        (b / 'uci').chmod(0o755)
        st = temp / 'uci'
        st.mkdir()
        leds = temp / 'leds'
        for n in ('green:wan', 'red:sys'):
            (leds / n).mkdir(parents=True)
            (leds / n / 'brightness').write_text('0')
        source = (SHARE / 'buttons.sh').read_text().replace(
            '. /usr/share/5gmodem/lib.sh 2>/dev/null',
            'note_foreign_uci() { :; }\nsvc_running() { return 1; }')
        script = temp / 'buttons.sh'
        script.write_text(source)
        env = dict(os.environ, PATH=str(b) + ':' + os.environ['PATH'], UCI_ST=str(st),
                   LEDS_DIR=str(leds))
        return str(script), st, env

    def fields(self, temp):
        marker = temp / 'pwned'
        return [
            'debounce=5',
            'ct_pressed=simple', 'pressed=logger "x=1; $(touch %s)"' % marker,
            'leds_pressed=green:wan=1 red:sys=0',
            'ct_released=conditional', 'released=/usr/share/5gmodem/buttons.sh svc toggle dropbear',
            'leds_on_released=green:wan=1', 'leds_off_released=',
        ], marker

    def test_save_equals_sequential_calls(self):
        with tempfile.TemporaryDirectory() as t1, tempfile.TemporaryDirectory() as t2:
            t1, t2 = Path(t1), Path(t2)
            s1, st1, env1 = self.env(t1)
            fields, marker = self.fields(t1)
            r = run([s1, 'save', 'BTN_0'] + fields, env=env1)
            self.assertEqual(json.loads(r.stdout), {'ok': 1}, r.stderr)
            self.assertFalse(marker.exists())
            self.assertEqual((st1 / 'commits').read_text().split().count('5gmodem'), 1)

            s2, st2, env2 = self.env(t2)
            fields2, _ = self.fields(t1)
            for kv in fields2:
                k, _, v = kv.partition('=')
                if k.startswith('leds_'):
                    run([s2, 'setleds', 'BTN_0', k[5:], v], env=env2)
                else:
                    run([s2, 'set', 'BTN_0', k, v], env=env2)
            self.assertEqual((st1 / '5gmodem').read_text(), (st2 / '5gmodem').read_text())
            self.assertEqual((st1 / 'system').read_text(), (st2 / 'system').read_text())
            cfg = (st1 / '5gmodem').read_text()
            self.assertIn('5gmodem.btn_BTN_0.pressed=logger "x=1; $(touch %s)"' % marker, cfg)
            self.assertNotIn('leds_off_released', cfg)
            self.assertIn("system.cfg00.trigger=none", (st1 / 'system').read_text())

    def test_save_rejects_bad_fields_before_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            script, st, env = self.env(temp)
            for bad in (['debounce=1', 'name=evil'], ['pressed'], ['leds_x=1'], ['ct_pressed.x=1']):
                r = run([script, 'save', 'BTN_0'] + bad, env=env)
                self.assertEqual(json.loads(r.stdout), {'error': 'bad field'}, bad)
            self.assertFalse((st / '5gmodem').exists())
            r = run([script, 'save'], env=env)
            self.assertEqual(json.loads(r.stdout), {'error': 'no button'})

    def test_led_spec_is_not_globbed(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            script, st, env = self.env(temp)
            r = run([script, 'save', 'BTN_0', 'leds_pressed=*'], env=env, cwd=str(temp / 'leds'))
            self.assertEqual(json.loads(r.stdout), {'ok': 1}, r.stderr)
            self.assertFalse((st / 'system').exists())


if __name__ == '__main__':
    unittest.main()
