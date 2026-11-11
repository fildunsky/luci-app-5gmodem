import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell

LTE = '1 2 3 4 5 7 8 12 13 17 18 19 20 25 26 28 32 38 39 40 41 42 48 66 71'
NR = '1 2 3 5 7 8 12 20 25 26 28 38 40 41 48 66 71 75 77 78'
CAPS = f'1:8 10 12 13;2:1 2 4 5 8 19 26;3:{LTE};6:{NR}'
AWK = str(SHARE / 'android-radio.awk')


def radio(allowed=381831, writable=1, rat=13, lte=LTE, gsm='8 10 12 13', umts='1 2 4 5 8 19 26', nr=NR, end=True, error=None, data=2, enabled=1):
    lines = ['SUB|5', f'WRITABLE|{writable}', f'ALLOWED|{allowed}', f'RAT|{rat}', f'DATA|{data}', f'DATA_ENABLED|{enabled}',
             f'BANDS|1|{gsm}', f'BANDS|2|{umts}', f'BANDS|3|{lte}', f'BANDS|6|{nr}']
    if error:
        lines.append('ERROR|' + error)
    if end:
        lines.append('__5GM_RADIO_END__')
    return '\n'.join(lines) + '\n'


def radio_without_bands(allowed=906119, writable=1, rat=13):
    # The modem does not answer the band API (Samsung Exynos): the network mode is still readable.
    return '\n'.join(['SUB|11', f'WRITABLE|{writable}', f'ALLOWED|{allowed}', f'RAT|{rat}', 'DATA|2', 'DATA_ENABLED|1',
                      'BANDS_UNSUPPORTED|1', '__5GM_RADIO_END__']) + '\n'


def awk(text, *assign, engine=('busybox', 'awk')):
    args = [*engine]
    for item in assign:
        args += ['-v', item]
    return subprocess.run([*args, '-f', AWK], input=text, text=True, capture_output=True, timeout=5)


class AndroidRadioParser(unittest.TestCase):
    engines = [('busybox', 'awk'), ('awk',)]

    def test_json_lists_modes_supported_bands_and_the_current_selection(self):
        for engine in self.engines:
            with self.subTest(engine=engine):
                result = awk(radio(), f'caps={CAPS}', 'model=Phone', engine=engine)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(result.stdout)
                self.assertEqual(data['currentmode'], '1')
                self.assertEqual([m['id'] for m in data['modes']], ['1', '8', '2', '4', '20'])
                self.assertEqual([b['band'] for b in data['supported']], [int(b) for b in LTE.split()])
                self.assertEqual(data['enabled'], [int(b) for b in LTE.split()])
                self.assertEqual([b['band'] for b in data['supported2g']], [850, 900, 1800, 1900])
                self.assertEqual([b['band'] for b in data['supported3g']], [1, 2, 4, 5, 8, 19, 26])
                self.assertEqual(data['enabled5gnsa'][-1], 78)
                self.assertEqual(data['readonly'], 0)
                self.assertEqual(data['modem'], 'Phone')

    def test_locked_selection_keeps_the_modem_list_as_supported(self):
        text = radio(lte='3', gsm='10 12')
        data = json.loads(awk(text, f'caps={CAPS}').stdout)
        self.assertEqual(len(data['supported']), len(LTE.split()))
        self.assertEqual(data['enabled'], [3])
        self.assertEqual(data['enabled2g'], [900, 1800])
        # A band outside the modem list is never offered as enabled.
        data = json.loads(awk(radio(lte='3 106'), f'caps={CAPS}').stdout)
        self.assertEqual(data['enabled'], [3])

    def test_without_a_cached_list_the_live_list_is_used_and_readonly_is_reported(self):
        data = json.loads(awk(radio(writable=0, lte='1 3')).stdout)
        self.assertEqual([b['band'] for b in data['supported']], [1, 3])
        self.assertEqual(data['readonly'], 1)

    def test_current_mode_is_derived_from_the_allowed_types(self):
        for mask, expected in [(906119, '1'), (381831, '1'), (266240, '4'), (790528, '20'),
                               (32771, '8'), (82820, '2'), (4096 + 32768, '')]:
            with self.subTest(mask=mask):
                data = json.loads(awk(radio(allowed=mask), f'caps={CAPS}').stdout)
                self.assertEqual(data['currentmode'], expected)

    def test_incomplete_or_failed_output_is_not_a_result(self):
        self.assertNotEqual(awk(radio(end=False), f'caps={CAPS}').returncode, 0)
        self.assertNotEqual(awk(radio(error='SecurityException: denied'), f'caps={CAPS}').returncode, 0)
        self.assertNotEqual(awk('', f'caps={CAPS}').returncode, 0)
        self.assertNotEqual(awk('', 'mode=caps').returncode, 0)

    def test_caps_mode_is_the_modem_list_of_a_reset_readback(self):
        result = awk(radio(), 'mode=caps')
        self.assertEqual(result.stdout.strip(), CAPS)

    def test_mask_for_every_mode_and_capability(self):
        for want, mask in [(1, 906119), (8, 32771), (2, 82820), (4, 266240), (20, 790528)]:
            for engine in self.engines:
                with self.subTest(want=want, engine=engine):
                    self.assertEqual(awk('', 'mode=mask', f'want={want}', f'caps={CAPS}', engine=engine).stdout.strip(), str(mask))
        no_nr = CAPS.rsplit(';6:', 1)[0]
        self.assertEqual(awk('', 'mode=mask', 'want=1', f'caps={no_nr}').stdout.strip(), '381831')
        self.assertNotEqual(awk('', 'mode=mask', 'want=20', f'caps={no_nr}').returncode, 0)
        self.assertNotEqual(awk('', 'mode=mask', 'want=3', f'caps={CAPS}').returncode, 0)

    def test_a_phone_without_the_band_api_gets_only_the_network_modes(self):
        for engine in self.engines:
            with self.subTest(engine=engine):
                data = json.loads(awk(radio_without_bands(), 'model=Phone', engine=engine).stdout)
                self.assertEqual(data['nobandctl'], 1)
                self.assertEqual(data['supported'], [])
                self.assertEqual(data['enabled'], [])
                for key in ('supported2g', 'supported3g', 'supported5gnsa'):
                    self.assertNotIn(key, data)
                self.assertEqual(data['currentmode'], '1')
                # Android drops the bits the hardware lacks, so every mode is offered.
                self.assertEqual([m['id'] for m in data['modes']], ['1', '8', '2', '4', '20'])
                self.assertEqual(awk(radio_without_bands(), 'mode=caps', engine=engine).stdout.strip(), '0:nobands')
                # The stored marker alone is enough for later reads and for choosing a mode.
                self.assertEqual(json.loads(awk(radio_without_bands(allowed=266240), 'caps=0:nobands', engine=engine).stdout)['currentmode'], '4')
                for want, mask in [(1, 906119), (8, 32771), (2, 82820), (4, 266240), (20, 790528)]:
                    self.assertEqual(awk('', 'mode=mask', f'want={want}', 'caps=0:nobands', engine=engine).stdout.strip(), str(mask))
                # There is no list to select bands from.
                self.assertEqual(awk('', 'mode=bands', 'caps=0:nobands', 'sel_lte=3', engine=engine).returncode, 2)

    def test_band_listing_still_works_for_phones_that_have_the_api(self):
        data = json.loads(awk(radio(), f'caps={CAPS}').stdout)
        self.assertNotIn('nobandctl', data)

    def test_band_arguments_are_checked_against_the_modem_list(self):
        for engine in self.engines:
            with self.subTest(engine=engine):
                ok = awk('', 'mode=bands', f'caps={CAPS}', 'sel_lte=3 1', 'sel_nsa=78', 'sel_3g=1 8', 'sel_2g=900 1800', engine=engine)
                self.assertEqual(ok.stdout.strip(), '3=1,3 6=78 2=1,8 1=10,12')
                for bad in ['sel_lte=3 106', 'sel_nsa=79', 'sel_3g=3', 'sel_2g=1234', 'sel_lte=3;reboot']:
                    self.assertEqual(awk('', 'mode=bands', f'caps={CAPS}', bad, engine=engine).returncode, 2, bad)

    def test_selecting_every_modem_band_asks_for_a_reset(self):
        everything = ['sel_lte=' + LTE, 'sel_nsa=' + NR, 'sel_3g=1 2 4 5 8 19 26', 'sel_2g=850 900 1800 1900']
        self.assertEqual(awk('', 'mode=bands', f'caps={CAPS}', *everything).stdout.strip(), 'RESET')
        # A partial request is never mistaken for a reset, even when the lists it names are complete.
        self.assertEqual(awk('', 'mode=bands', f'caps={CAPS}', everything[0]).stdout.strip(),
                         '3=' + ','.join(LTE.split()))
        self.assertNotEqual(awk('', 'mode=bands', f'caps={CAPS}', *everything[:3], 'sel_2g=900').stdout.strip(), 'RESET')


STUB = r'''
RES=%(res)s
android_cells_ready() { echo "ready" >> "$READY"; echo phone-serial; }
android_usb_serial() { echo phone-serial; }
android_adb() { printf '%%s\n' "$*" >> "$CALLS"; printf '%%s' "$REPLY"; }
uci() {
 case "$1" in
  -q) shift ;;
 esac
 case "$1" in
  get) case "$2" in *android_caps_for) printf '%%s' "${CAPS_FOR-phone-serial}" ;; *) printf '%%s' "$CAPS" ;; esac ;;
  set) printf '%%s\n' "$2" >> "$STORED" ;;
  commit) echo committed >> "$STORED" ;;
 esac
}
sleep() { :; }
logger() { :; }
'''


class AndroidRadioShell(unittest.TestCase):
    def run_shell(self, body, reply='', caps='', functions=('android_sec', 'android_caps', 'android_caps_store', 'android_radio',
                  'android_radio_json', 'android_radio_ok', 'android_mode_settle', 'android_mode_recover', 'android_set_mode', 'android_set_bands')):
        directory = tempfile.mkdtemp()
        root = Path(directory)
        source = STUB % {'res': str(SHARE)} + '\n'.join(function(name, 'android.sh').replace('/tmp/5gmodem/', directory + '/') for name in functions) + '\n' + body
        env = dict(os.environ, READY=str(root / 'ready'), CALLS=str(root / 'calls'), STORED=str(root / 'stored'),
                   REPLY=reply, CAPS=caps)
        result = shell(source, env)
        calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
        stored = (root / 'stored').read_text().splitlines() if (root / 'stored').exists() else []
        return result, calls, stored

    def test_invalid_requests_never_reach_adb(self):
        for action in ['set-mode x', 'set-mode ""', 'set-mode "1;reboot"', 'set-bands', 'set-bands "3=1;reboot"',
                       'set-bands 9=1', 'set-bands "3=,1"', 'set-bands "3=1,,2"', 'set-bands 3=', 'bogus']:
            with self.subTest(action=action):
                result, calls, _ = self.run_shell(f'android_radio 1-1 {action}')
                self.assertTrue(result.stdout.startswith('ERROR|'), result.stdout)
                self.assertEqual(calls, [])

    def test_commands_target_the_active_data_subscription_and_output_is_filtered(self):
        noisy = 'junk line\nSUB|5\nBANDS|3|1 3\n$(reboot)\n__5GM_RADIO_END__\n'
        for action, expected in [('info', 'radio active'), ('reset-bands', 'reset-bands active'),
                                 ('set-mode 266240', 'set-mode active 266240'),
                                 ('set-bands 3=1,3 6=78', 'set-bands active 3=1,3 6=78')]:
            with self.subTest(action=action):
                result, calls, _ = self.run_shell(f'android_radio 1-1 {action}', reply=noisy)
                self.assertEqual(result.stdout, 'SUB|5\nBANDS|3|1 3\n__5GM_RADIO_END__\n')
                self.assertEqual(calls, [f'-s phone-serial shell CLASSPATH=/data/local/tmp/5gmodem-cells.dex app_process /system/bin CellProbe {expected}'])

    def test_first_read_learns_the_modem_band_list_and_later_reads_do_not_write(self):
        result, calls, stored = self.run_shell('android_radio_json 1-1 Phone', reply=radio())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CellProbe reset-bands active', calls[0])
        self.assertEqual(len(calls), 1)
        self.assertEqual(stored[0], f'5gmodem.m_1_1.android_caps={CAPS}')
        self.assertEqual(json.loads(result.stdout)['currentmode'], '1')
        result, calls, stored = self.run_shell('android_radio_json 1-1 Phone', reply=radio(lte='3'), caps=CAPS)
        self.assertEqual(len(calls), 1)
        self.assertIn('CellProbe radio active', calls[0])
        self.assertEqual(stored, [])
        self.assertEqual(json.loads(result.stdout)['enabled'], [3])

    def test_the_learned_list_belongs_to_one_phone(self):
        # Another phone on the same USB port (the section is named after the port) must not use the first one's bands.
        result, calls, stored = self.run_shell('CAPS_FOR=other-phone; export CAPS_FOR\nandroid_radio_json 1-1 Phone', reply=radio(lte='1 3 7'), caps=CAPS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CellProbe reset-bands active', calls[0])
        self.assertEqual(stored[0], '5gmodem.m_1_1.android_caps=1:8 10 12 13;2:1 2 4 5 8 19 26;3:1 3 7;6:' + NR)
        self.assertEqual(stored[1], '5gmodem.m_1_1.android_caps_for=phone-serial')
        self.assertEqual([b['band'] for b in json.loads(result.stdout)['supported']], [1, 3, 7])
        # A list stored by an older version carries no serial and is learnt again.
        result, calls, stored = self.run_shell('CAPS_FOR=; export CAPS_FOR\nandroid_radio_json 1-1 Phone', reply=radio(), caps=CAPS)
        self.assertIn('CellProbe reset-bands active', calls[0])

    def test_a_phone_without_the_band_api_is_not_written_and_offers_only_modes(self):
        result, calls, stored = self.run_shell('android_radio_json 1-1 Phone', reply=radio_without_bands())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stored[:2], ['5gmodem.m_1_1.android_caps=0:nobands', '5gmodem.m_1_1.android_caps_for=phone-serial'])
        data = json.loads(result.stdout)
        self.assertEqual(data['nobandctl'], 1)
        self.assertEqual(data['supported'], [])
        # Choosing a mode uses the stored marker, so NR is offered without a band list.
        out = radio_without_bands(allowed=790528)
        result, calls, _ = self.run_shell('android_mode_recover() { :; }\nandroid_set_mode 1-1 20; wait', reply=out, caps='0:nobands')
        self.assertEqual(json.loads(result.stdout), {'ok': True, 'allowed_types': '790528'})
        self.assertIn('CellProbe set-mode active 790528', calls[0])
        # Band requests are refused before the phone is touched.
        result, calls, _ = self.run_shell('android_set_bands 1-1 3 "" "" ""; echo rc=$?', reply=out, caps='0:nobands')
        self.assertIn('rc=2', result.stdout)
        self.assertEqual(calls, [])

    def test_a_failed_reset_falls_back_to_a_plain_read(self):
        script = 'android_adb() { printf "%s\\n" "$*" >> "$CALLS"; case "$*" in *reset-bands*) echo "ERROR|SecurityException: no" ;; *) printf "%s" "$REPLY" ;; esac; }\nandroid_radio_json 1-1 Phone'
        result, calls, stored = self.run_shell(script, reply=radio(writable=0))
        self.assertEqual(len(calls), 2)
        self.assertEqual(stored, [])
        self.assertEqual(json.loads(result.stdout)['readonly'], 1)

    def test_mode_is_computed_from_the_modem_list_and_refused_for_unknown_ids(self):
        out = radio(allowed=266240)
        result, calls, _ = self.run_shell('android_mode_recover() { echo recover "$@" >> "$CALLS"; }\nandroid_set_mode 1-1 4; wait', reply=out, caps=CAPS)
        self.assertEqual(json.loads(result.stdout), {'ok': True, 'allowed_types': '266240'})
        self.assertIn('CellProbe set-mode active 266240', calls[0])
        self.assertEqual(calls[1], 'recover 1-1')
        result, calls, _ = self.run_shell('android_set_mode 1-1 3', reply=out, caps=CAPS)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('error', json.loads(result.stdout))
        self.assertEqual(calls, [])
        result, calls, _ = self.run_shell('android_set_mode 1-1 4', reply='ERROR|SecurityException: denied\n', caps=CAPS)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['error'], 'SecurityException: denied')
        self.assertEqual(len(calls), 1)

    def settle(self, replies, wanted='381831', fail_first_disable=False, locked=False):
        """replies: one radio readback per round; the last one repeats."""
        root = Path(tempfile.mkdtemp())
        for index, text in enumerate(replies):
            (root / f'reply{index}').write_text(text)
        body = ('android_usb_serial() { echo phone-serial; }\n'
                'android_radio() { n=$(cat "$ROUNDS" 2>/dev/null || echo 0); [ -f "$REPLIES/reply$n" ] || n=$((n - 1)); '
                'echo $((n + 1)) > "$ROUNDS"; cat "$REPLIES/reply$n"; }\n'
                'android_adb() { printf "%s\\n" "$*" >> "$CALLS"; '
                + ('case "$*" in *airplane-mode\\ disable) [ -f "$CALLS.once" ] || { : > "$CALLS.once"; return 1; } ;; esac; ' if fail_first_disable else '')
                + '}\n'
                + ('mkdir -p /tmp/5gmodem; ' if False else '')
                + 'android_mode_recover 1-1\n')
        directory = tempfile.mkdtemp()
        source = STUB % {'res': str(SHARE)} + function('android_sec', 'android.sh') + '\n' + function('android_radio_ok', 'android.sh') + '\n' \
            + function('android_mode_settle', 'android.sh') + '\n' + function('android_mode_recover', 'android.sh').replace('/tmp/5gmodem/', directory + '/') + '\n'
        if locked:
            stamp = '$(cut -d. -f1 /proc/uptime)' if locked == 'fresh' else '0'
            source += f'mkdir -p {directory}/android_recover_m_1_1; echo {stamp} > {directory}/android_recover_m_1_1/t\n'
        source += body.replace('mkdir -p /tmp/5gmodem; ', '')
        env = dict(os.environ, READY=str(root / 'ready'), CALLS=str(root / 'calls'), STORED=str(root / 'stored'), CAPS='',
                   REPLIES=str(root), ROUNDS=str(root / 'rounds'))
        result = shell(source, env)
        calls = [c.rsplit(' ', 2)[-2] + ' ' + c.rsplit(' ', 1)[-1] if 'airplane' in c else c.split('shell ', 1)[-1]
                 for c in ((root / 'calls').read_text().splitlines() if (root / 'calls').exists() else [])]
        return result, calls, Path(directory)

    def test_a_modem_stuck_on_2g_is_reselected_and_a_dead_data_bearer_is_restarted(self):
        stuck = radio(rat=2, data=0)
        dead = radio(rat=13, data=0)
        healthy = radio(rat=13, data=2)
        result, calls, directory = self.settle([stuck, dead, healthy])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable', 'cmd phone data disable', 'cmd phone data enable'])
        self.assertFalse((directory / 'android_recover_m_1_1').exists(), 'the run lock is released')

    def test_2g_with_a_connected_bearer_still_counts_as_stuck_but_is_reselected_only_once(self):
        # Android reports the bearer as connected on EDGE although it carries nothing.
        result, calls, _ = self.settle([radio(rat=2, data=2), radio(rat=13, data=2), radio(rat=13, data=2)])
        # After the reselection the bearer is restarted once, whatever its reported state.
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable', 'cmd phone data disable', 'cmd phone data enable'])
        result, calls, _ = self.settle([radio(rat=2, data=2)])
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable'])
        # The modem may sit on 2G for a moment right after the reselection: it is given time before the bearer is restarted.
        result, calls, _ = self.settle([radio(rat=2, data=2), radio(rat=2, data=2), radio(rat=13, data=2), radio(rat=13, data=2)])
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable', 'cmd phone data disable', 'cmd phone data enable'])

    def test_nothing_is_touched_when_the_link_is_fine_or_the_state_is_intended(self):
        cases = {
            'connected': ([radio(rat=13, data=2)], '381831'),
            '2G only on purpose': ([radio(rat=2, data=0, allowed=32771)], '32771'),
            'data switched off by the user': ([radio(rat=13, data=0, enabled=0)], '381831'),
            'still searching': ([radio(rat=0, data=0)], '381831'),
            'failed readback': ([radio(rat=2, data=0, error='x')], '381831'),
            'no answer': ([''], '381831'),
        }
        for name, (replies, wanted) in cases.items():
            with self.subTest(name):
                result, calls, _ = self.settle(replies, wanted)
                self.assertEqual(calls, [])

    def test_the_decision_uses_the_state_read_back_and_a_running_check_is_not_doubled(self):
        # Android may filter a requested mask (no NR for this SIM): the recovery must not give up because of it.
        result, calls, _ = self.settle([radio(rat=16, data=0, allowed=381831), radio(rat=13, data=2)], wanted='906119')
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable', 'cmd phone data disable', 'cmd phone data enable'])
        # A change while a check is running only asks it to start over; a dead run's lock does not block for ever.
        result, calls, directory = self.settle([radio(rat=16, data=0)], locked='fresh')
        self.assertEqual(calls, [])
        self.assertTrue((directory / 'android_recover_m_1_1' / 'again').exists())
        result, calls, directory = self.settle([radio(rat=16, data=0), radio(rat=13, data=2)], locked='stale')
        self.assertEqual(calls[:2], ['airplane-mode enable', 'airplane-mode disable'])
        self.assertFalse((directory / 'android_recover_m_1_1').exists())

    def test_a_restart_request_resets_the_run_and_data_restarts_are_limited_and_spaced(self):
        lock = tempfile.mkdtemp()
        Path(lock, 'again').write_text('')
        body = ('android_usb_serial() { echo phone-serial; }\nandroid_radio() { printf "%s" "$REPLY"; }\n'
                'android_adb() { printf "%s\\n" "$*" >> "$CALLS"; }\n'
                'sleep() { echo "sleep $1" >> "$CALLS"; }\n'
                f'android_mode_settle 1-1 {lock}')
        result, calls, _ = self.run_shell(body, reply=radio(rat=13, data=2))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(lock, 'again').exists(), 'the restart request is consumed')
        # A bearer that never comes back is restarted at most twice, each time followed by a long pause.
        result, calls, _ = self.run_shell(body.replace(f'{lock}', lock + 'x'), reply=radio(rat=13, data=0))
        restarts = [c for c in calls if c.endswith('cmd phone data disable')]
        self.assertEqual(len(restarts), 2)
        self.assertEqual([c for c in calls if c == 'sleep 40'], ['sleep 40', 'sleep 40'])

    def test_airplane_mode_is_always_switched_off_again(self):
        result, calls, _ = self.settle([radio(rat=16, data=0), radio(rat=13, data=2)], fail_first_disable=True)
        self.assertEqual(calls, ['airplane-mode enable', 'airplane-mode disable', 'airplane-mode disable',
                                 'cmd phone data disable', 'cmd phone data enable'])

    def test_band_changes_reset_or_write_only_what_was_asked(self):
        ok = radio()
        stub = 'android_mode_recover() { echo "recover $*" >> "$CALLS"; }\n'
        result, calls, _ = self.run_shell(stub + 'android_set_bands 1-1 "3 1" "" "" ""; wait', reply=ok, caps=CAPS)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(calls[0].endswith('CellProbe set-bands active 3=1,3'))
        self.assertEqual(calls[1:], ['recover 1-1'])
        everything = ['"%s"' % LTE, '"%s"' % NR, '"1 2 4 5 8 19 26"', '"850 900 1800 1900"']
        result, calls, _ = self.run_shell(stub + 'android_set_bands 1-1 ' + ' '.join(everything) + '; wait', reply=ok, caps=CAPS)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(calls[0].endswith('CellProbe reset-bands active'))
        self.assertEqual(calls[1:], ['recover 1-1'])
        result, calls, _ = self.run_shell(stub + 'android_set_bands 1-1 default "" "" ""; wait', reply=ok, caps=CAPS)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(calls[0].endswith('CellProbe reset-bands active'))
        self.assertEqual(calls[1:], ['recover 1-1'])
        result, calls, _ = self.run_shell(stub + 'android_set_bands 1-1 "3 1 106" "" "" ""; rc=$?; wait; exit $rc', reply=ok, caps=CAPS)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(calls, [])
        result, calls, _ = self.run_shell(stub + 'android_set_bands 1-1 3 "" "" ""; rc=$?; wait; exit $rc', reply='ERROR|denied\n', caps=CAPS)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(calls), 1)


class AndroidBandsDispatch(unittest.TestCase):
    def block(self):
        text = (SHARE / 'bands.sh').read_text()
        begin = text.index('if [ -n "$_bs_am" ] && [ "$(uci -q get "5gmodem.$_bs_sec.kind")" = tether ]')
        end = text.index('if [ "$_bs_am" = ccci ]; then', begin)
        return text[begin:end]

    def run_block(self, directory, args, kind='tether', tether='android', **extra):
        root = Path(directory)
        (root / 'android.sh').write_text(r'''
android_radio_json() { printf '{"path":"%s","model":"%s"}\n' "$1" "$2"; }
android_set_mode() { [ "$2" = 4 ] && { echo '{"ok":true}'; return 0; }; echo '{"error":"unsupported network mode"}'; return 1; }
android_set_bands() { echo "bands $*" >> "$LOG"; case "$2" in *106*) return 2 ;; *bad*) return 1 ;; esac; return 0; }
''')
        (root / 'lib.sh').write_text(function('android_tether_path', 'lib.sh') + '\ntether_os() { echo "${LIVE_OS:-phone}"; }\n')
        source = r'''
uci() { case "$*" in *.kind) echo "$KIND" ;; *.tether) echo "$TETHER" ;; *.model) echo 'Test "Phone"' ;; esac; }
jsonfilter() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(sys.argv[2][2:], ""))' "$@"; }
_bands_flush() { echo flush >> "$LOG"; }
_sa_resfile() { echo "$RESDIR/result"; }
''' + function('_sa_fail_add', 'bands.sh') + '\n' + function('_sa_res_write', 'bands.sh').replace('/tmp/5gmodem/', directory + '/') + '\n' + r'''
_bs_am=1-1
_bs_sec=m_1_1
_SA_OKJ=""; _SA_FAILJ=""; _SA_TAKEOVER=0; _SA_ID=7
_SA_MODE=${SA_MODE:-}; _SA_LTE=${SA_LTE:-}; _SA_NSA=""; _SA_SA=${SA_SA:-}; _SA_3G=""; _SA_2G=""
set -- ''' + args + '\n' + self.block().replace('/usr/share/5gmodem', directory) + '\necho legacy\n'
        env = dict(os.environ, KIND=kind, TETHER=tether, LOG=str(root / 'log'), RESDIR=directory, **extra)
        return shell(source, env)

    def test_only_android_tethers_are_handled_and_other_modems_fall_through(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(json.loads(self.run_block(directory, 'json').stdout), {'path': '1-1', 'model': 'Test Phone'})
            self.assertEqual(json.loads(self.run_block(directory, 'mgmtinfo').stdout), {'source': 'vendor'})
            self.assertEqual(self.run_block(directory, 'getsupportedmodes').stdout.strip(), '1:Auto 8:2G 2:3G 4:4G 20:4G/5G')
            self.assertEqual(self.run_block(directory, 'getmode').stdout.strip(), '')
            for kind, tether in [('modem', 'android'), ('tether', 'ios'), ('tether', '')]:
                self.assertEqual(self.run_block(directory, 'json', kind=kind, tether=tether).stdout.strip(), 'legacy')
            # The key is gone after a product id change: the live vendor still selects the Android handling.
            self.assertEqual(json.loads(self.run_block(directory, 'json', tether='', LIVE_OS='android').stdout),
                             {'path': '1-1', 'model': 'Test Phone'})

    def test_set_mode_reports_success_and_failure_through_the_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            ok = self.run_block(directory, 'setmode 4')
            self.assertEqual((ok.returncode, ok.stdout.strip()), (0, 'ok'))
            bad = self.run_block(directory, 'setmode 3')
            self.assertEqual((bad.returncode, bad.stdout.strip()), (1, 'unsupported network mode'))
            for invalid in ['setmode', 'setmode x', 'setmode "1;reboot"']:
                result = self.run_block(directory, invalid)
                self.assertEqual((result.returncode, result.stdout.strip()), (2, 'bad mode'), invalid)

    def test_setall_reports_each_requested_part(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_block(directory, 'setall', SA_MODE='4', SA_LTE='3 1', SA_SA='1')
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertEqual(data['state'], 'done')
            self.assertEqual(data['applied'], ['lte', 'mode'])
            self.assertEqual([(f['what'], f['why']) for f in data['failed']], [('sa', 'unsupported')])
            result = self.run_block(directory, 'setall', SA_MODE='3', SA_LTE='3 106')
            data = json.loads(result.stdout)
            self.assertEqual(data['applied'], [])
            self.assertEqual([(f['what'], f['why']) for f in data['failed']], [('lte', 'badband'), ('mode', 'rejected')])


if __name__ == '__main__':
    unittest.main()
