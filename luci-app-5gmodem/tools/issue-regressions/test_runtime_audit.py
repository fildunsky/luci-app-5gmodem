#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SHARE = ROOT / 'root/usr/share/5gmodem'


def function(name, filename):
    source = (SHARE / filename).read_text()
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}', source, re.M | re.S)
    if not match:
        raise ValueError(name)
    return match[0]


def shell(source, env=None):
    return subprocess.run(['busybox', 'ash', '-c', source], text=True,
                          capture_output=True, timeout=15, env=env)


class RuntimeAudit(unittest.TestCase):
    def test_manual_network_hook_accepts_quoted_uci_output(self):
        hook = ROOT / 'root/etc/hotplug.d/iface/32-5gmodem-netsel'
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            worker = temp / 'netsel.sh'
            worker.write_text('#!/bin/sh\nprintf "%s" "$*" > "$RESULT"\n')
            worker.chmod(0o755)
            source = hook.read_text().replace('/usr/share/5gmodem/netsel.sh', shlex.quote(str(worker)))
            prefix = '''
sleep() { :; }
uci() {
 case "$*" in
  *show*) printf '%s\\n' "$CONFIG_LINE" ;;
  *m_1_1.network) echo modem ;;
  *m_1_1.path) echo 1-1 ;;
 esac
}
'''
            for value in ("'manual'", 'manual'):
                result_file = temp / 'result'
                result_file.unlink(missing_ok=True)
                result = shell(prefix + source, dict(os.environ, ACTION='ifup', INTERFACE='modem',
                    CONFIG_LINE='5gmodem.m_1_1.netsel=' + value, RESULT=str(result_file)))
                self.assertEqual(result.returncode, 0, result.stderr)
                deadline = time.monotonic() + 5
                while not result_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertEqual(result_file.read_text(), 'reapply 1-1')

    def test_detached_operator_refresh_drops_inherited_locks(self):
        line = next(line for line in (SHARE / 'netpri.sh').read_text().splitlines()
                    if '/netpri.sh refresh &' in line)
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            worker = temp / 'refresh.sh'
            worker.write_text('''#!/bin/sh
printf '%s ' "${_AT_LOCK_HELD-unset}" > "$RESULT"
if [ -e /proc/self/fd/9 ]; then echo open; else echo closed; fi >> "$RESULT"
''')
            worker.chmod(0o755)
            source = 'exec 9>"$LOCK"\nexport _AT_LOCK_HELD=test\n' + line.replace(
                '/usr/share/5gmodem/netpri.sh', shlex.quote(str(worker)))
            result = shell(source, dict(os.environ, LOCK=str(temp / 'lock'), RESULT=str(temp / 'result')))
            self.assertEqual(result.returncode, 0, result.stderr)
            deadline = time.monotonic() + 5
            while not (temp / 'result').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual((temp / 'result').read_text(), 'unset closed\n')

    def test_sms_read_yields_to_long_operation(self):
        result = shell(function('_sms_run', 'smsbridge.sh') + '''
_via_mm() { return 1; }
PORT=/dev/test
at_long_busy() { return 0; }
read_sms() { echo unexpected-read; }
_sms_run 1 read_sms
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_telemetry_strings_stay_on_one_json_line(self):
        value = 'Operator "A"\\B\n\t\r'
        result = shell(function('_str', 'telemetry.sh') + '\n_str oper "$VALUE"\nprintf "{%s}" "$_J"',
                       dict(os.environ, VALUE=value))
        self.assertEqual(result.stderr, '')
        self.assertEqual(json.loads(result.stdout), {'oper': 'Operator "A"\\B'})
        self.assertNotIn('\n', result.stdout)

    def test_plain_telemetry_strings_avoid_sed(self):
        result = shell(function('_str', 'telemetry.sh') + '''
sed() { echo unexpected-sed >&2; return 1; }
_str model 'Huawei E5573'
printf '{%s}' "$_J"
''')
        self.assertEqual(result.stderr, '')
        self.assertEqual(json.loads(result.stdout), {'model': 'Huawei E5573'})

    def test_pdu_send_does_not_touch_busy_port(self):
        result = shell(function('_send_pdu', 'smsbridge.sh') + '''
_port_is_mm() { return 1; }
at_lock() { return 1; }
_send_pdu /dev/null +123 test
''')
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_sms_read_keeps_intentional_lock_timeout_fallback(self):
        result = shell(function('_sms_run', 'smsbridge.sh') + '''
_via_mm() { return 1; }
_AT_LOCKED=1
PORT=/dev/test
at_long_busy() { return 1; }
read_sms() { echo sms-read; }
_sms_run 1 read_sms
''')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, 'sms-read\n')
        self.assertEqual(result.stderr, '')

    def test_stats_loads_interface_labels_once(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            (temp / 'health').mkdir()
            (temp / 'stats').mkdir()
            for iface in ('modem', 'wan'):
                (temp / 'health' / iface).write_text('up 0 1 10 0\n')
            (temp / 'netpri.sh').write_text('#!/bin/sh\necho call >> "$RES/calls"\necho "[]"\n')
            (temp / 'netpri.sh').chmod(0o755)
            source = '\n'.join(function(name, 'stats.sh') for name in ('_collect_ping', '_iface_label'))
            source = source.replace('/tmp/5gmodem', str(temp))
            source += '''
_push() { :; }
uci5g_get() { :; }
sec_for_iface() { :; }
jsonfilter() { :; }
_label() { printf '%s' "$2" > "$DIR/$1.label"; }
_collect_ping
'''
            result = shell(source, dict(os.environ, RES=str(temp), DIR=str(temp / 'stats')))
            self.assertEqual(result.stderr, '')
            self.assertEqual((temp / 'calls').read_text().splitlines(), ['call'])
            self.assertEqual((temp / 'stats/ping.wan.label').read_text(), 'wan')

    def test_ussd_cancel_does_not_touch_busy_port(self):
        with tempfile.TemporaryDirectory() as temp:
            source = (SHARE / 'ussd.sh').read_text().replace('/tmp/5gmodem', temp)
            source = source.replace('. "$RES/lib.sh" 2>/dev/null', ':')
            source = source.replace('. "$RES/atlock.sh" 2>/dev/null', ':')
            overrides = '''
_port() { echo /dev/test; }
at_lock() { return 1; }
sms_tool() { echo unexpected-AT >&2; }
at_unlock() { echo unexpected-unlock >&2; }
'''
            source = source.replace('case "$1" in\nstatus)', overrides + '\ncase "$1" in\nstatus)')
            result = shell('set -- cancel\n' + source)
            self.assertEqual(json.loads(result.stdout), {'error': 'port busy'})
            self.assertEqual(result.stderr, '')
            self.assertEqual(result.returncode, 2)
            self.assertFalse((Path(temp) / 'ussd.json').exists())

    def test_simslot_busy_read_uses_cache_but_set_fails(self):
        source = (SHARE / 'simslot.sh').read_text()
        source = source[source.index('D=""\n[ -n "$_SLOT_NOAT" ]'):source.index('\nat_has_gtdualsim()')]
        source = source.replace('. /usr/share/5gmodem/atlock.sh', ':')
        with tempfile.TemporaryDirectory() as temp:
            source = source.replace('/tmp/5gmodem', temp)
            prefix = '''
_AP=test
live_port() { echo /dev/test; }
at_lock() { return 1; }
'''
            for verb, cached, expected in [
                    ('get', False, {'error': 'port busy'}),
                    ('get', True, {'active': '1'}),
                    ('set', True, {'error': 'port busy'})]:
                with self.subTest(verb=verb, cached=cached):
                    if cached:
                        (Path(temp) / 'slots_test').write_text('{"active":"1"}')
                    result = shell('set -- ' + verb + '\n' + prefix + source + '\necho unexpected-AT')
                    self.assertEqual(json.loads(result.stdout), expected)
                    self.assertEqual(result.stderr, '')

    def test_integer_conversion(self):
        values = {'0': '0', '-0': '0', '0007': '7', '-0007': '-7',
                  '68719476735': '68719476735', '-105': '-105',
                  '1.5': '2', '-1.5': '-2', '1.49': '1', '-1.49': '-1',
                  '': '', '--': '', '---': '', '-': '', '1-2': '',
                  '+1': '', 'NaN': '', '1;echo bad': ''}
        for value, expected in values.items():
            with self.subTest(value=value):
                env = dict(os.environ, VALUE=value)
                result = shell(function('_int', 'telemetry.sh') + '\n_int "$VALUE"', env)
                self.assertEqual(result.stdout, expected, result.stderr)

    def test_integer_conversion_avoids_awk(self):
        result = shell(function('_int', 'telemetry.sh') + '''
awk() { echo unexpected-awk >&2; return 1; }
for value in 0 70 -105 68719476735; do _int "$value"; done
''')
        self.assertEqual(result.stderr, '')
        self.assertEqual(result.stdout, '070-10568719476735')

    def test_telemetry_cache_is_modem_specific(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            state = temp / 'state'
            state.mkdir()
            (temp / 'uci').write_text('''#!/bin/sh
case "$*" in
 *active_modem) printf '%s' "$TEST_MODEM" ;;
 *publish_ip|*publish_phone) printf '1' ;;
esac
''')
            (temp / 'ubus').write_text('#!/bin/sh\nexit 0\n')
            (temp / 'jsonfilter').write_text('''#!/usr/bin/env python3
import json, sys
args = sys.argv[1:]
try:
    if '-i' in args:
        with open(args[args.index('-i') + 1]) as f: obj = json.load(f)
    else: obj = json.loads(args[args.index('-s') + 1] if '-s' in args else sys.stdin.read())
    value = obj.get(args[args.index('-e') + 1][2:])
    if value is not None: print(value)
except (OSError, ValueError, IndexError): pass
''')
            for executable in ('uci', 'ubus', 'jsonfilter'):
                (temp / executable).chmod(0o755)
            source = (SHARE / 'telemetry.sh').read_text().replace('/tmp/5gmodem', str(state))
            script = temp / 'telemetry.sh'
            script.write_text(source)
            stamp = int(float(Path('/proc/uptime').read_text().split()[0]))
            for path, model, signal in [('1-1', 'First', '31'), ('1-2', 'Second', '82')]:
                key = path.replace('-', '_') + '_'
                (state / f'metrics_{key}.json').write_text(json.dumps({
                    'modem': model, 'operator_name': model, 'signal': signal,
                    'rsrp': '-105', 'cid_dec': '68719476735',
                    'ipaddr': '10.0.0.2', 'phone': '+123456789'}))
                (state / f'metrics_{key}.stamp').write_text(str(stamp))
            env = dict(os.environ, PATH=str(temp) + ':' + os.environ['PATH'])

            def run(path):
                result = subprocess.run(['busybox', 'ash', str(script), 'write'],
                                        env=dict(env, TEST_MODEM=path), capture_output=True,
                                        text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr)
                return json.loads((state / 'tele.json').read_text())

            self.assertEqual(run('1-1')['model'], 'First')
            second = run('1-2')
            self.assertEqual(second['model'], 'Second')
            self.assertEqual(second['sig'], 82)
            self.assertEqual(json.loads((state / 'tele_cell.json').read_text())['cid'], 68719476735)
            self.assertEqual(run('1-2'), second)
            (state / 'metrics_1_2_.stamp').write_text(str(stamp + 3600))
            stale = run('1-2')
            self.assertNotIn('model', stale)
            self.assertNotIn('wan_ip', stale)
            self.assertNotIn('phone', stale)

    def test_stats_checks_mount_before_creating_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'unmounted' / 'stats'
            result = shell(function('_dir_live', 'stats.sh') + '''
_mounted() { return 1; }
_dir_live "$TARGET" 1
''', dict(os.environ, TARGET=str(target)))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(target.exists())

    def test_stats_serializes_collectors(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            source = (SHARE / 'stats.sh').read_text()
            source = source.replace('/tmp/5gmodem', str(temp))
            source = source.replace('. "$RES/lib.sh" 2>/dev/null', ':')
            overrides = '''
_enabled() { return 0; }
_restore() { touch "$DIR/started"; sleep 0.3; }
_mdm_init() { :; }
_mdm_reconcile() { :; }
_collect_ping() { :; }
_collect_signal() { :; }
_collect_traffic() {
 value=0
 [ ! -f "$DIR/total" ] || read -r value < "$DIR/total"
 sleep 0.1
 echo "$((value + 1))" > "$DIR/total"
}
_flush() { :; }
'''
            source = source.replace('case "$1" in\ntick)', overrides + '\ncase "$1" in\ntick)')
            script = temp / 'stats.sh'
            script.write_text(source)
            args = ['busybox', 'ash', str(script), 'tick']
            first = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while not (temp / 'stats/started').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((temp / 'stats/started').exists())
                second = subprocess.run(args, capture_output=True, timeout=5)
                self.assertEqual(second.returncode, 0, second.stderr)
                _, err = first.communicate(timeout=5)
                self.assertEqual(first.returncode, 0, err)
                self.assertEqual((temp / 'stats/total').read_text().strip(), '1')
                subprocess.run(args, check=True, capture_output=True, timeout=5)
                self.assertEqual((temp / 'stats/total').read_text().strip(), '2')
            finally:
                if first.poll() is None:
                    first.kill()
                    first.communicate()

    def test_esim_does_not_touch_busy_port(self):
        source = function('run_lpac', 'esim.sh') + '''
apdu_backend() { echo at; }
at_lock() { return 1; }
at_bounded() { echo unexpected-AT >&2; }
err() { printf '%s' "$1"; }
PORT=/dev/test
run_lpac 1 chip info
'''
        result = shell(source)
        self.assertEqual(result.stdout, 'port busy')
        self.assertEqual(result.stderr, '')
        self.assertEqual(result.returncode, 1)


if __name__ == '__main__':
    unittest.main()
