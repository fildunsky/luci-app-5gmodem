import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem/esim.sh'


class EsimQmiTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        self.calls = root / 'calls'
        self.show = root / 'visibility'
        self.runtime = root / 'runtime'
        lpac = root / 'lpac'
        drivers = lpac / 'driver'
        drivers.mkdir(parents=True)
        self.uqmi_plugin = drivers / 'driver_apdu_uqmi.so'
        self.uqmi_plugin.touch()
        binary = lpac / 'lpac'
        binary.write_text('''#!/bin/sh
printf '%s %s %s\\n' "$LPAC_APDU" "$LPAC_APDU_QMI_DEVICE" "$*" >> "$TEST_CALLS"
printf '{"type":"lpa","payload":{"code":%s,"data":{"eidValue":"00000000000000000000000000000000"}}}\\n' "$TEST_CODE"
''')
        binary.chmod(0o755)
        (root / 'esim-apdu-bridge.sh').write_text('cat > "$2"\n')
        listmodems = root / 'listmodems.sh'
        listmodems.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_PRODUCT"\n')
        listmodems.chmod(0o755)
        shutil.copyfile(SCRIPT.with_name('esimcaps.sh'), root / 'esimcaps.sh')
        (root / 'atlock.sh').write_text(r'''
uci() {
    [ "$1" != -q ] || shift
    case "$1:$2" in
        get:5gmodem.*.esim_apdu) printf '%s\n' "$TEST_MANUAL" ;;
        get:5gmodem.*.active_modem) echo "$TEST_ACTIVE" ;;
        get:5gmodem.m_*.esim_show) cat "$TEST_SHOW" 2>/dev/null ;;
        get:5gmodem.m_*.vidpid) echo "$TEST_VIDPID" ;;
        get:5gmodem.m_usb0) echo modem ;;
        get:5gmodem.m_usb0.network) echo "$TEST_INTERFACE" ;;
        set:5gmodem.m_*.esim_show=*) printf '%s\n' "${2##*=}" > "$TEST_SHOW" ;;
        delete:5gmodem.m_*.esim_show) rm -f "$TEST_SHOW" ;;
        commit:5gmodem) : ;;
        get:network.wan.proto) echo "$TEST_PROTO" ;;
        get:network.other.proto) echo modemmanager ;;
        get:lpac.mbim.slot) echo 1 ;;
        show:network)
            printf "network.wan.device='/dev/null'\nnetwork.other.device='/dev/zero'\n" ;;
        *) return 1 ;;
    esac
}
jsonfilter() { case "$2" in *.product) cat ;; *) return 1 ;; esac; }
ubus() { printf '{"%s": true}\n' "$TEST_LINK"; }
logger() { :; }
uqmi() { :; }
qmicli() { printf 'qmicli %s\n' "$*" >> "$TEST_CALLS"; }
ifdown() { printf 'ifdown %s\n' "$*" >> "$TEST_CALLS"; }
ifup() { printf 'ifup %s\n' "$*" >> "$TEST_CALLS"; }
killall() { :; }
sleep() { command sleep 0.02; }
''')
        script = SCRIPT.read_text().replace('/tmp/5gmodem', str(self.runtime))
        script = script.replace('/usr/lib/lpac', str(lpac)).replace('/usr/share/5gmodem', str(root))
        # Feed the detected device/driver at the same boundary as the real modem registry and sysfs.
        markers = 'case "$1" in\nreapply)'
        script = script.replace(markers, '''
esim_wdm() { printf '%s\\n' "$TEST_NODE"; }
_wdm_driver() { printf '%s\\n' "$TEST_DRIVER"; }

''' + markers)
        self.script = root / 'esim.sh'
        self.script.write_text(script)

    def run_esim(self, action, *args, **overrides):
        env = dict(os.environ, TEST_CALLS=str(self.calls), TEST_INTERFACE='wan',
                   TEST_PROTO='qmi', TEST_LINK='up', TEST_NODE='/dev/null',
                   TEST_DRIVER='qmi_wwan', TEST_MANUAL='', TEST_CODE='0', ESIM_READONLY='1',
                   TEST_SHOW=str(self.show), TEST_ACTIVE='usb0', TEST_VIDPID='2c7c:030b', TEST_PRODUCT='')
        env.update(overrides)
        self.calls.unlink(missing_ok=True)
        result = subprocess.run(['sh', str(self.script), action, *args], env=env, text=True,
                                capture_output=True, check=True, timeout=10)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result.stdout, calls

    def test_same_node_direct_qmi_uses_uqmi(self):
        for proto in ('qmi', 'qmiraw'):
            for state in ('up', 'pending', 'down'):
                with self.subTest(proto=proto, state=state):
                    output, calls = self.run_esim('apduinfo', TEST_PROTO=proto, TEST_LINK=state)
                    self.assertIn('selected APDU backend: uqmi\n', output)
                    self.assertEqual(calls, [])
        for manual in ('qmi', 'uqmi'):
            output, _ = self.run_esim('apduinfo', TEST_MANUAL=manual)
            self.assertIn('selected APDU backend: uqmi\n', output)
        output, _ = self.run_esim('apduinfo', TEST_MANUAL='mbim', TEST_DRIVER='')
        self.assertIn('selected APDU backend: uqmi\n', output)

    def test_uses_at_bridge_when_uqmi_plugin_is_missing(self):
        self.uqmi_plugin.unlink()
        output, _ = self.run_esim('apduinfo')
        self.assertIn('selected APDU backend: bridge\n', output)

    def test_other_modem_and_mbim_keep_their_transport(self):
        output, _ = self.run_esim('apduinfo', TEST_INTERFACE='other', TEST_NODE='/dev/zero')
        self.assertIn('selected APDU backend: qmi\n', output)
        output, _ = self.run_esim('apduinfo', TEST_PROTO='mbim', TEST_DRIVER='cdc_mbim')
        self.assertIn('selected APDU backend: bridge\n', output)
        output, _ = self.run_esim('apduinfo', TEST_PROTO='mbim', TEST_DRIVER='cdc_mbim', TEST_LINK='down')
        self.assertIn('selected APDU backend: mbim\n', output)

    def test_probe_and_refresh_use_uqmi_without_proxy_even_on_retry(self):
        result, calls = self.run_esim('status-probe')
        self.assertEqual(json.loads(result), {'available': 1, 'active': 1})
        self.assertEqual(calls, ['uqmi /dev/null chip info'])

        for code in (0, 1):
            with self.subTest(code=code):
                result, calls = self.run_esim('dump', TEST_CODE=str(code))
                self.assertEqual(json.loads(result)['profiles']['payload']['code'], code)
                self.assertEqual(calls, ['uqmi /dev/null chip info'] * (code + 1)
                                 + ['uqmi /dev/null profile list'] * (code + 1))

    def test_auto_visibility_reuses_successful_probe_without_opening_channel(self):
        result, calls = self.run_esim('status')
        self.assertEqual(json.loads(result)['available'], 0)
        self.assertEqual(calls, [])

        result, calls = self.run_esim('status-probe')
        self.assertEqual(json.loads(result), {'available': 1, 'active': 1})
        self.assertEqual(calls, ['uqmi /dev/null chip info'])
        (self.runtime / 'esimdump_usb0').write_text('{"profiles":[]}\n')

        for mode, available in [('0', 0), ('1', 1), ('auto', 1)]:
            with self.subTest(mode=mode):
                result, calls = self.run_esim('setshow', mode)
                self.assertEqual(json.loads(result), {'result': 'ok'})
                self.assertEqual(calls, [])
                result, calls = self.run_esim('status')
                self.assertEqual(json.loads(result)['available'], available)
                self.assertEqual(calls, [])
        result, _ = self.run_esim('status-cached')
        self.assertEqual(json.loads(result), {'available': 1, 'active': 1})
        result, _ = self.run_esim('dump-cached')
        self.assertEqual(json.loads(result), {'profiles': []})
        result, calls = self.run_esim('status', TEST_ACTIVE='usb1')
        self.assertEqual(json.loads(result)['available'], 0)
        self.assertEqual(calls, [])

    def test_em060k_visibility_is_specific_to_the_model_and_usb_id(self):
        for model, vidpid, available in [
            ('EM060K-GL', '2c7c:030b', 1), ('EM06', '2c7c:030b', 0),
            ('EM060K-GL', '0000:0000', 0), ('RM520N-GL', '2c7c:0801', 1),
        ]:
            with self.subTest(model=model, vidpid=vidpid):
                result, calls = self.run_esim('status', TEST_PRODUCT=model, TEST_VIDPID=vidpid)
                self.assertEqual(json.loads(result)['available'], available)
                self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
