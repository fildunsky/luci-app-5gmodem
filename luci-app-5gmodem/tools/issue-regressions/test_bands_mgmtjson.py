import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_runtime_audit import ROOT, SHARE, function

HOTPLUG = ROOT / 'root/etc/hotplug.d/iface/62-5gmodem-uplink'
BANDS = {'modem': 'Test', 'currentmode': '1', 'supported': [{'band': 3}], 'enabled': [3]}


class BandsMgmtJson(unittest.TestCase):
    # The page polls "mgmtjson" once per tick instead of mgmtinfo + json.
    def block(self):
        text = (SHARE / 'bands.sh').read_text()
        begin = text.index('if [ "$1" = "mgmtjson" ]; then')
        end = text.index('_BJ_REFRESH=""; _BJ_FORCE=""', begin)
        return text[begin:end]

    def run_block(self, directory, proto, mgmt='', out=None, mmcli=True):
        root = Path(directory)
        bindir = root / 'bin'
        bindir.mkdir(exist_ok=True)
        # Only busybox applets on PATH: the host may have its own mmcli.
        for tool in ('sed', 'cat'):
            if not (bindir / tool).exists():
                (bindir / tool).symlink_to(shutil.which('busybox'))
        if mmcli:
            (bindir / 'mmcli').write_text('#!/bin/sh\nexit 0\n')
            (bindir / 'mmcli').chmod(0o755)
        script = root / 'bands.sh'
        # Child runs of "$0" answer mgmtinfo/json from the environment and log their arguments.
        script.write_text('#!/bin/sh\n' + r'''
case "$1" in
	mgmtinfo) echo "$*" >> "$LOG"; printf '%s\n' "$MGMT"; exit 0 ;;
	json) echo "$*" >> "$LOG"; printf '%s\n' "$JSON"; exit 0 ;;
esac
uci() { case "$*" in *5gmodem.m_1_1.network) echo wan_m ;; *network.wan_m.proto) echo "$PROTO" ;; esac; }
BANDS_ACTIVE_MODEM="$2"
''' + function('active_modem', 'bands.sh') + '\n' + self.block() + 'echo fallthrough\n')
        script.chmod(0o755)
        env = dict(os.environ, PATH=str(bindir), LOG=str(root / 'log'), PROTO=proto, MGMT=mgmt,
                   JSON=json.dumps(BANDS) if out is None else out)
        result = subprocess.run([shutil.which('busybox'), 'ash', str(script), 'mgmtjson', '1-1'], text=True,
                                              capture_output=True, timeout=15, env=env)
        log = (root / 'log').read_text().split('\n') if (root / 'log').exists() else []
        return result.stdout.strip(), [x for x in log if x]

    def test_vendor_modem_gets_band_data_through_the_cached_json_verb(self):
        with tempfile.TemporaryDirectory() as d:
            out, calls = self.run_block(d, 'qmi')
            self.assertEqual(json.loads(out), {'source': 'vendor', 'bands': BANDS})
            # Only the cached "json" verb, never jsonrefresh; no mgmtinfo run when the proto is not MM.
            self.assertEqual(calls, ['json 1-1'])

    def test_mm_answer_passes_through_without_band_json(self):
        with tempfile.TemporaryDirectory() as d:
            mm = '{"source":"mmcli","nrat":0,"sup4g":["eutran-3"]}'
            out, calls = self.run_block(d, 'modemmanager', mgmt=mm)
            self.assertEqual(out, mm)
            self.assertEqual(calls, ['mgmtinfo 1-1'])
            out, calls = self.run_block(d, 'modemmanager', mgmt='{"source":"mmcli","pending":1}')
            self.assertEqual(json.loads(out), {'source': 'mmcli', 'pending': 1})

    def test_mm_modem_without_bands_falls_back_to_vendor_data(self):
        with tempfile.TemporaryDirectory() as d:
            out, calls = self.run_block(d, 'modemmanager', mgmt='{"source":"vendor"}')
            self.assertEqual(json.loads(out)['bands'], BANDS)
            self.assertEqual(calls, ['mgmtinfo 1-1', 'json 1-1'])

    def test_mm_proto_without_mmcli_is_vendor(self):
        with tempfile.TemporaryDirectory() as d:
            out, calls = self.run_block(d, 'modemmanager', mmcli=False)
            self.assertEqual(json.loads(out)['source'], 'vendor')
            self.assertEqual(calls, ['json 1-1'])

    def test_non_json_band_answer_leaves_bands_out(self):
        with tempfile.TemporaryDirectory() as d:
            out, _ = self.run_block(d, 'qmi', out='AT port /dev/ttyUSB2 is busy')
            self.assertEqual(json.loads(out), {'source': 'vendor'})

    def test_old_verbs_stay_addressable(self):
        text = (SHARE / 'bands.sh').read_text()
        self.assertIn('json|jsonrefresh|mgmtinfo|mgmtjson|nratjson', text)
        self.assertIn('\t"mgmtinfo")\n', text)

    def test_page_uses_the_combined_verb(self):
        js = (ROOT / 'htdocs/luci-static/resources/view/modem5g/bandsui.js').read_text()
        self.assertIn("[ 'mgmtjson' ]", js)
        self.assertIn('applyVendorJson(j.bands)', js)


class UplinkNotifyStandalone(unittest.TestCase):
    def test_hotplug_loads_only_the_small_file(self):
        text = HOTPLUG.read_text()
        self.assertIn('. /usr/share/5gmodem/uplink.sh', text)
        self.assertNotIn('lib.sh', text.replace('not lib.sh', ''))

    def test_uplink_sh_defines_uplink_notify_alone_and_lib_sh_sources_it(self):
        uplink = (SHARE / 'uplink.sh').read_text()
        lib = (SHARE / 'lib.sh').read_text()
        self.assertIn('uplink_notify() {', uplink)
        self.assertNotIn('uplink_notify() {', lib)
        self.assertIn('. /usr/share/5gmodem/uplink.sh', lib)
        result = subprocess.run(['busybox', 'ash', '-c', '. "$0"; command -v uplink_notify', str(SHARE / 'uplink.sh')],
                                              text=True, capture_output=True, timeout=15)
        self.assertEqual(result.stdout.strip(), 'uplink_notify')

    def test_irrelevant_events_exit_without_background_work(self):
        for env in ({'ACTION': 'ifup', 'INTERFACE': 'loopback'}, {'ACTION': 'free', 'INTERFACE': 'wan'}):
            result = subprocess.run(['busybox', 'ash', '-x', str(HOTPLUG)], text=True, capture_output=True,
                                                  timeout=15, env=dict(os.environ, **env))
            self.assertEqual(result.returncode, 0)
            self.assertNotIn('sleep', result.stderr)


if __name__ == '__main__':
    unittest.main()
