#!/usr/bin/env python3
import json
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


class Mt60(unittest.TestCase):
    def test_native_metrics_use_radio_provider_only_for_native_path(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'lib.sh').touch()
            (base / 'mt60-web.sh').write_text(
                'mt60_native() { [ "$NATIVE" = 1 ]; }\n'
                'MT60_ORIGIN=http://192.168.42.1\n'
            )
            ubus = base / 'ubus'
            ubus.write_text('#!/bin/sh\n[ "$*" = "-t 4 call mt60 radio" ] || exit 2\n'
                            '[ "$AVAILABLE" = 1 ] || exit 1\n'
                            'echo \'{"modem":"OLAX MT60","mode":"LTE-A B3"}\'\n')
            ubus.chmod(0o755)
            source = (SHARE / 'hilink.sh').read_text().replace('RES=/usr/share/5gmodem', f'RES={base}', 1)
            source = source.replace('case "$1" in\n\tmsmweb)', 'metrics_json() { echo generic; }\n\n'
                                    'case "$1" in\n\tmsmweb)', 1)
            env = dict(os.environ, PATH=f'{base}:{os.environ["PATH"]}')
            for path, native, available, output, status in (
                ('mt60', '1', '1', '{"modem":"OLAX MT60","mode":"LTE-A B3"}', 0),
                ('mt60', '1', '0', '', 1),
                ('mt60', '0', '1', 'generic', 0),
                ('1-2', '1', '1', 'generic', 0),
            ):
                with self.subTest(path=path, native=native, available=available):
                    result = shell(f'set -- json {path}\n' + source,
                                   dict(env, NATIVE=native, AVAILABLE=available))
                    self.assertEqual(result.returncode, status, result.stderr)
                    self.assertEqual(result.stdout.strip(), output)

    def test_usb_metrics_ignore_cached_band_registration(self):
        stubs = r'''
_hl_path() { echo "$1"; }
_hl_ctx() { _HC_A=192.0.2.1; }
_vidpid_for() { echo 0e8d:2004; }
olax_mt60_usb() { return 0; }
_zte_get() {
    case ",$2," in *,band_reg,*) return 1 ;; esac
    printf '%s\n' '{"ppp_status":"ppp_connected"}'
}
_zte_login() { exit 1; }
_zj() {
    case "$2" in
        ppp_status) echo ppp_connected ;;
        network_type) echo LTE_CA ;;
        hardware_version) echo LR673-V4.0 ;;
        battery_vol_percent) echo 78 ;;
        show_band_reg) echo 1 ;;
        band_reg) echo Band3 ;;
        rsrp) echo -87 ;;
        rsrq) echo -9 ;;
        sinr) echo 150 ;;
    esac
}
sig_percent() { echo 70; }
jsafe() { printf '%s' "$1"; }
'''
        result = shell(stubs + function('zte_metrics_json', 'hilink.sh') + '\nzte_metrics_json 1-2\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['mode'], 'LTE_CA')
        self.assertEqual(data['pband'], '')
        self.assertNotIn('earfcn', data)
        self.assertNotIn('s1band', data)
        self.assertEqual([data['rsrp'], data['rsrq'], data['sinr']], ['-87', '-9', '15'])

    def test_external_lte_band_write_requires_k62_login_and_supported_bands(self):
        stubs = r'''
mt60_band_data() { echo reply; }
mt60_band_numbers() { echo '1 3 20'; }
_zj() {
    case "$2" in
        simId) echo 0 ;;
        result) echo "$1" ;;
    esac
}
_hl_ctx() { _HC_A=192.0.2.1; }
_sk() { echo synthetic; }
_zte_login_jar() {
    [ "$1" = 192.0.2.1 ] && [ "$2" = 1-2 ] && [ "$3" = 1 ] || return 1
}
_zte_set() {
    printf '%s\n' "$2" "$4" >> "$CACHE_DIR/request"
    echo "$RESULT"
}
'''
        exercise = r'''
RESULT=success mt60_setbands '3 20' 1-2 || exit 1
RESULT=success mt60_setbands '3 7' 1-2 && exit 1
RESULT=fail mt60_setbands '3' 1-2 && exit 1
cat "$CACHE_DIR/request"
'''
        with tempfile.TemporaryDirectory() as cache:
            result = shell(stubs + function('mt60_setbands', 'hilink.sh') + '\n' + exercise,
                           dict(os.environ, CACHE_DIR=cache))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            '{"success":true}',
            'goformId=SET_BAND&band_list=%5B%22Band3%22%2C%22Band20%22%5D&simId=0',
            '1-2',
            'goformId=SET_BAND&band_list=%5B%22Band3%22%5D&simId=0',
            '1-2',
        ])

    def test_legacy_band_bridge_requires_fresh_non_fallback_snapshot(self):
        jsonfilter = r'''
jsonfilter() {
    python3 - "$2" "$4" <<'PYTHON'
import json
import sys
with open(sys.argv[1]) as snapshot:
    value = json.load(snapshot)[sys.argv[2][2:]]
print(str(value).lower() if isinstance(value, bool) else value)
PYTHON
}
'''
        stub = jsonfilter + function('legacy_bridge_ready', 'mt60-bands.sh') + '\n'
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / 'metrics.json'
            for content, status in (
                (None, 1),
                ({'sampled_uptime': 99, 'app': True}, 1),
                ({'sampled_uptime': 99, 'app': False}, 0),
                ({'sampled_uptime': 89}, 0),
                ({'sampled_uptime': 88}, 1),
                ({'sampled_uptime': 101}, 1),
                ({'sampled_uptime': 'unavailable'}, 1),
            ):
                with self.subTest(snapshot=content):
                    if content is not None:
                        snapshot.write_text(json.dumps(content))
                    result = shell(stub + 'legacy_bridge_ready "$TEST_DIR" 100\n',
                                   dict(os.environ, TEST_DIR=directory))
                    self.assertEqual(result.returncode, status, result.stderr)

            snapshot.write_text(json.dumps({'sampled_uptime': 99, 'app': True}))
            script = (SHARE / 'mt60-bands.sh').read_text()
            legacy_bands = 'legacy_bands() (' + script.split('legacy_bands() (', 1)[1].split('\nlegacy_json()', 1)[0]
            legacy_bands = legacy_bands.replace('dir=/tmp/mt60-radio', 'dir="$TEST_DIR"')
            result = shell(stub + legacy_bands + '\nsleep() { echo slept; }\nlegacy_bands "" ""\n',
                           dict(os.environ, TEST_DIR=directory))
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout), {'error': 'radio_unavailable'})
            self.assertFalse((Path(directory) / 'bands.request').exists())


if __name__ == '__main__':
    unittest.main()
