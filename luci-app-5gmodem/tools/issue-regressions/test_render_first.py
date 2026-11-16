"""Pages draw their layout first: load() does not wait for router work (field report: 15-20 s
of "Loading view" on a busy router)."""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VIEW = ROOT / 'htdocs/luci-static/resources/view/modem5g'
UPD = ROOT / 'root/usr/share/5gmodem/update.sh'
BTN = ROOT / 'root/usr/share/5gmodem/buttons.sh'


def load_body(js):
    src = (VIEW / js).read_text()
    # the page's own loader: _load5g when load() is only the API check wrapper
    for name in ('_load5g', 'load'):
        m = re.search(r'\n\t' + name + r': function\(\) \{\n(.*?)\n\t\},\n', src, re.S)
        if m:
            return m.group(1)
    return ''


class RenderFirst(unittest.TestCase):
    def test_sms_load_waits_only_for_settings(self):
        body = load_body('sms.js')
        waited = body[body.index('return Promise.all('):]
        self.assertNotIn('sms_seen_load', waited)
        self.assertNotIn('phonebook', waited)
        src = (VIEW / 'sms.js').read_text()
        self.assertIn("'tg-sms-item tg-sms-skel'", src)
        self.assertNotIn('return smssettings.tabbedPanel().then', src)

    def test_ussd_settings_form_does_not_hold_the_page(self):
        self.assertNotIn("return smssettings.panel('ussd').then", (VIEW / 'sendussd.js').read_text())

    def test_buttons_lists_come_after_render(self):
        src = (VIEW / 'buttons.js').read_text()
        load = re.search(r'\tload: function\(\) \{(.*?)\},\n', src).group(1)
        for f in ('detect()', 'detectLeds()', 'detectServices()'):
            self.assertNotIn(f, load)

    def test_gps_layout_is_not_hidden_before_the_first_answer(self):
        src = (VIEW / 'gps.js').read_text()
        self.assertIn("var main = E('div', {}, [", src)

    def test_settings_versions_after_render(self):
        body = load_body('5gsettings.js')
        for w in ("'version'", "'services'", "'scan'", "'webreq'"):
            self.assertNotIn(w, body)
        src = (VIEW / '5gsettings.js').read_text()
        # late values move the autosave signature only while the form is unchanged
        self.assertIn('var clean = _asSig === formSig();', src)
        self.assertIn('.tg-skel', (VIEW / 'modem.css').read_text())

    def test_fast_version_reads_the_package_database(self):
        fn = re.search(r'^fast_version\(\) \{.*?^\}', UPD.read_text(), re.S | re.M).group(0)
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / 'apk').write_text('P:other\nV:1.0-r1\n\nP:luci-app-5gmodem\nV:4.0.3-r1\nA:noarch\n')
            (t / 'opkg').write_text('Package: luci-app-5gmodem-lite\nVersion: 3.9.1-r2\n\n')
            pre = 'PKG_FULL=luci-app-5gmodem; PKG_LITE=luci-app-5gmodem-lite\n' + fn + '\n'
            run = lambda env: subprocess.run(['sh', '-c', pre + env + ' fast_version'], capture_output=True, text=True).stdout.strip()
            self.assertEqual(run(f'UPD_APK_DB={t}/apk'), '4.0.3')
            self.assertEqual(run(f'UPD_APK_DB=/nonexistent UPD_OPKG_DB={t}/opkg'), '3.9.1')
            self.assertEqual(run('UPD_APK_DB=/nonexistent UPD_OPKG_DB=/nonexistent'), '')

    def test_services_list_without_subshells(self):
        src = BTN.read_text()
        blk = src[src.index('services)'):src.index('set)')]
        self.assertNotIn('$(basename', blk)
        self.assertNotIn('_json_esc', blk)


if __name__ == '__main__':
    unittest.main()
