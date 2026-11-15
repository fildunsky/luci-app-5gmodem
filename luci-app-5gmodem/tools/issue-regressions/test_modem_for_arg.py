#!/usr/bin/env python3
# The Network page shows one modem while the write scripts acted on uci active_modem. With several
# modems the two can differ (another browser tab, a switch still running), and "Apply bands",
# "Restart modem" or "reconnect" then hit the wrong modem. The page now sends for=<usb path> with
# every write; bands.sh, reboot_modem.sh and "setopt.sh reconnect" take the modem from it.
import os
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import ROOT, SHARE, function, shell

VIEW = ROOT / 'htdocs/luci-static/resources/view/modem5g'

# Two modems: 1-1 is uci active_modem, 2-1 is the other one.
UCI = r'''
uci() {
	case "$*" in
		*'@5gmodem[0].active_modem') echo 1-1 ;;
		*'@5gmodem[0].network') echo wan_a ;;
		*'@5gmodem[0].at_port') echo /dev/ttyACT ;;
		*5gmodem.m_1_1.network) echo wan_a ;;
		*5gmodem.m_2_1.network) echo wan_b ;;
		*5gmodem.m_2_1.at_port) echo /dev/ttyOTHER ;;
	esac
}
'''


def for_block(name):
    text = (SHARE / name).read_text()
    begin = text.index('for _fa in "$@"; do')
    return text[begin:text.index('\ndone\n', begin) + 6]


class BandsForArg(unittest.TestCase):
    def parse(self, args):
        r = shell(f'set -- {args}\n' + for_block('bands.sh') + 'echo "$BANDS_ACTIVE_MODEM|$*"')
        return r.stdout.strip()

    def test_for_is_taken_from_any_position_and_removed(self):
        self.assertEqual(self.parse('setall lte=1,3 for=2-1 mode=2'), '2-1|setall lte=1,3 mode=2')
        self.assertEqual(self.parse('for=2-1.4:1.0 setmode 3'), '2-1.4:1.0|setmode 3')
        self.assertEqual(self.parse('setbands "1 3 7" for=ccci'), 'ccci|setbands 1 3 7')

    def test_bad_or_empty_path_is_dropped(self):
        self.assertEqual(self.parse('setmode 3 "for=2-1;reboot"'), '|setmode 3')
        self.assertEqual(self.parse('setmode 3 for=../x'), '|setmode 3')
        self.assertEqual(self.parse('setmode 3 for='), '|setmode 3')

    def test_nothing_changes_without_for(self):
        self.assertEqual(self.parse('setall lte=1,3 mode=2'), '|setall lte=1,3 mode=2')
        self.assertEqual(self.parse(''), '|')

    def test_block_runs_before_any_verb_is_looked_at(self):
        text = (SHARE / 'bands.sh').read_text()
        self.assertLess(text.index('for _fa in "$@"; do'), text.index('case "$1" in\n\tjson|jsonrefresh'))
        self.assertLess(text.index('for _fa in "$@"; do'), text.index('if [ "$1" = "mmsetbands" ]'))

    def test_global_options_are_not_borrowed_for_another_modem(self):
        src = UCI + function('active_modem', 'bands.sh') + '\n' + function('_sel_is_active', 'bands.sh') \
            + '\n' + function('_global_opt', 'bands.sh') + '\n'
        run = lambda pre: shell(src + pre + 'echo "$(active_modem)|$(_global_opt network)|$(_global_opt at_port)"').stdout.strip()
        self.assertEqual(run(''), '1-1|wan_a|/dev/ttyACT')
        self.assertEqual(run('BANDS_ACTIVE_MODEM=1-1\n'), '1-1|wan_a|/dev/ttyACT')
        self.assertEqual(run('BANDS_ACTIVE_MODEM=2-1\n'), '2-1||')

    def test_soft_restart_after_a_write_names_the_modem(self):
        text = (SHARE / 'bands.sh').read_text()
        self.assertIn('reboot_modem.sh soft ${BANDS_ACTIVE_MODEM:+"for=$BANDS_ACTIVE_MODEM"}', text)
        self.assertNotIn('@5gmodem[0].network', text)


class RebootForArg(unittest.TestCase):
    def head(self, args, detect='/dev/ttyDETECT'):
        # Everything up to taking the AT lock, with detect.sh and the helpers replaced.
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            (d / 'detect.sh').write_text(f'#!/bin/sh\necho {detect}\n')
            (d / 'detect.sh').chmod(0o755)
            (d / 'lib.sh').write_text('proto_in() { return 1; }\n')
            text = (SHARE / 'reboot_modem.sh').read_text()
            text = text[:text.index('. /usr/share/5gmodem/atlock.sh')].replace('/usr/share/5gmodem', str(d))
            r = shell(UCI + 'readlink() { :; }\nrm() { :; }\n' + f'set -- {args}\n' + text
                      + 'echo "$MODE|$PORT|$_rb_am|$_rb_if"')
            return r.stdout.strip()

    def test_without_for_the_active_modem_is_restarted(self):
        self.assertEqual(self.head('soft'), 'soft|/dev/ttyDETECT|1-1|wan_a')
        self.assertEqual(self.head(''), 'soft|/dev/ttyDETECT|1-1|wan_a')

    def test_for_selects_port_and_interface_of_that_modem(self):
        self.assertEqual(self.head('soft for=2-1'), 'soft|/dev/ttyOTHER|2-1|wan_b')
        self.assertEqual(self.head('for=2-1 hard'), 'hard|/dev/ttyOTHER|2-1|wan_b')

    def test_for_the_active_modem_keeps_the_usual_port_detection(self):
        self.assertEqual(self.head('soft for=1-1'), 'soft|/dev/ttyDETECT|1-1|wan_a')

    def test_another_modem_without_a_saved_port_is_refused(self):
        # 3-1 has no section: the active modem's port from detect.sh must not be used for it
        out = self.head('soft for=3-1')
        self.assertIn('"success":false', out)
        self.assertNotIn('ttyDETECT', out)

    def test_usb_power_query_names_the_modem(self):
        text = (SHARE / 'reboot_modem.sh').read_text()
        run = lambda args: shell(UCI + 'rm() { :; }\nusb_power_method() { :; }\n' + f'set -- {args}\n'
                                 + text.replace('usb_power_method() {', '_unused_upm() {', 1)).stdout.strip()
        self.assertEqual(run('hasusbpower'), '{"path":"1-1","method":""}')
        self.assertEqual(run('hasusbpower for=2-1'), '{"path":"2-1","method":""}')
        self.assertEqual(run('hasusbpower 4-1 for=2-1'), '{"path":"4-1","method":""}')
        self.assertEqual(run('hasusbpower "for=2-1 x"'), '{"path":"1-1","method":""}')

    def test_fallbacks_from_power_keep_the_modem(self):
        text = (SHARE / 'reboot_modem.sh').read_text()
        self.assertIn('exec "$0" usbpower $FORARG', text)
        self.assertIn('exec "$0" hard $FORARG', text)
        self.assertIn('_pg_path=$(_sel_modem 2>/dev/null)', text)


class ReconnectForArg(unittest.TestCase):
    def iface(self, args):
        with tempfile.TemporaryDirectory() as d:
            log = Path(d) / 'log'
            src = UCI + f'ifdown() {{ echo "$1" > {log}; }}\nifup() {{ :; }}\nsleep() {{ :; }}\n' \
                + f'set -- {args}\n' + (SHARE / 'setopt.sh').read_text().replace('&\n\tsleep 1\n', '\n', 1)
            shell(src.replace('. /usr/share/5gmodem/lib.sh', ': #'), dict(os.environ))
            return log.read_text().strip() if log.exists() else ''

    def test_reconnect_restarts_the_named_modems_interface(self):
        self.assertEqual(self.iface('reconnect'), 'wan_a')
        self.assertEqual(self.iface('reconnect for=2-1'), 'wan_b')
        self.assertEqual(self.iface('reconnect for=1-1'), 'wan_a')

    def test_bad_path_falls_back_to_the_global_interface(self):
        self.assertEqual(self.iface('reconnect "for=2-1;x"'), 'wan_a')
        self.assertEqual(self.iface('reconnect for='), 'wan_a')


class PageSendsFor(unittest.TestCase):
    def test_write_helpers_append_the_page_modem(self):
        bands = (VIEW / 'bandsui.js').read_text()
        detail = (VIEW / '5gdetail.js').read_text()
        self.assertIn("(args || []).concat([ 'for=' + path ])", bands)
        self.assertIn("(args || []).concat([ 'for=' + pageModemPath ])", detail)
        # no write to these scripts goes around execW
        for js in (bands, detail):
            for line in js.split('\n'):
                if 'fs.exec(' in line and 'function execW' not in line and 'return p.then' not in line:
                    self.assertNotIn('bands.sh', line)
                    self.assertNotIn('reboot_modem.sh', line)
        self.assertIn("forArgs([ 'haspower' ])", detail)
        self.assertEqual(detail.count("forArgs([ 'hasusbpower' ])"), 2)
        self.assertIn("execW('/usr/share/5gmodem/setopt.sh', [ 'reconnect' ])", detail)


if __name__ == '__main__':
    unittest.main()
