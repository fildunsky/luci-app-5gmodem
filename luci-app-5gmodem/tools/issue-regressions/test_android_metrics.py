import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from test_runtime_audit import SHARE, shell, function


def fixture(active=5):
    lines = ['__5GM_DEVICE__', 'Xiaomi "test" \\ phone', 'test-model', 'test-build', '__5GM_REGISTRY__']
    for slot, operator, rsrp, pci in [(0, 'First Carrier', -80, 22), (1, 'Second Carrier', -99, 60)]:
        lines += [f'  Phone Id={slot}',
            f'    mServiceState={{mOperatorAlphaLong={operator}, getRilDataRadioTechnology=18(IWLAN), '
            f'mChannelNumber=1892, mNetworkRegistrationInfos=[NetworkRegistrationInfo{{ domain=PS transportType=WWAN '
            f'networkRegistrationState=HOME accessNetworkTechnology=LTE cellIdentity=CellIdentityLte:{{ mMcc=250 mMnc=20 }} }}]}}',
            f'    mSignalStrength=SignalStrength:{{mLte=CellSignalStrengthLte: rssi=-67 rsrp={rsrp} rsrq=-14 rssnr=4 '
            'cqi=2147483647 ta=2147483647 level=3 parametersUseForLevel=0,mNr=invalid}',
            f'    mPhysicalChannelConfigs=[{{mConnectionStatus=PrimaryServing,mCellBandwidthDownlinkKhz=10000,'
            f'mPhysicalCellId={pci},mBand=0}}]', '    mDataConnectionState=2']
    lines += [f'  mActiveDataSubId={active}', '__5GM_SUBS__',
        '  Logical SIM slot 0: subId=1', '  Logical SIM slot 1: subId=5',
        '__5GM_BATTERY__', '  level: 57', '  temperature: 321', '__5GM_THERMAL__',
        'Cached temperatures:', ' Temperature{mValue=99.6, mType=0, mName=CPU0, mStatus=0}',
        'Current temperatures from HAL:',
        ' Temperature{mValue=36.4, mType=0, mName=CPU0, mStatus=0}',
        ' Temperature{mValue=37.2, mType=0, mName=CPU1, mStatus=0}',
        ' Temperature{mValue=31.5, mType=3, mName=skin, mStatus=0}',
        ' Temperature{mValue=4.2, mType=6, mName=vbat, mStatus=0}',
        'Current cooling devices from HAL:', '__5GM_TETHER__',
        '    Current upstream interface(s): [rmnet_data3]', '__5GM_END__']
    return '\n'.join(lines) + '\n'


class AndroidMetrics(unittest.TestCase):
    def parse(self, text, awk=('busybox', 'awk')):
        return subprocess.run([*awk, '-v', 'path=1-2', '-v', 'sampled_at=123',
            '-f', str(SHARE / 'android-metrics.awk')], input=text, text=True, capture_output=True, timeout=5)

    def test_both_sims_active_subscription_units_and_current_temperatures(self):
        for awk in [('busybox', 'awk'), ('awk',)]:
            with self.subTest(awk=awk):
                result = self.parse(fixture(), awk)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(result.stdout)
                self.assertEqual(data['modem'], 'Xiaomi "test" \\ phone')
                self.assertEqual(data['android_slot'], '1')
                self.assertEqual(data['operator_name'], 'Second Carrier')
                self.assertEqual(data['mode'], 'LTE')
                self.assertEqual(data['rsrp'], '-99')
                self.assertEqual(data['sinr'], '4')
                self.assertEqual(data['csq'], '23')
                self.assertEqual(data['csq_source'], 'rssi')
                self.assertEqual(data['bandwidth'], '10')
                self.assertEqual(data['pci'], '60')
                self.assertEqual(data['temps'], 'bat=32.1 cpu=37.2 skin=31.5')
                self.assertEqual(data['battery'], '57')
                self.assertEqual(data['android_upstream'], 'rmnet_data3')
                self.assertEqual(len(data['android_sims']), 2)
                self.assertNotIn('pband', data)
                self.assertNotIn('mtemp', data)
                self.assertNotIn('tac', data)
                self.assertNotIn('cqi', data)

    def test_samsung_dump_hal_names_and_an_empty_slot(self):
        # One SIM in slot 0; the eSIM slot has no operator and Android prints the string "null".
        text = fixture(active=1).replace('mOperatorAlphaLong=Second Carrier,', 'mOperatorAlphaLong=null,')
        # Its HAL names the sensors AP/PA/SKIN and the sysfs thermal zones are not readable by the shell.
        hal = (' Temperature{mValue=36.4, mType=0, mName=CPU0, mStatus=0}\n Temperature{mValue=37.2, mType=0, mName=CPU1, mStatus=0}\n'
               ' Temperature{mValue=31.5, mType=3, mName=skin, mStatus=0}\n')
        self.assertIn(hal, text)
        text = text.replace(hal, ' Temperature{mValue=32.6, mType=0, mName=AP, mStatus=0}\n Temperature{mValue=32.9, mType=5, mName=PA, mStatus=0}\n'
                                 ' Temperature{mValue=31.9, mType=3, mName=SKIN, mStatus=0}\n Temperature{mValue=0.0, mType=2, mName=SUBBAT, mStatus=0}\n')
        for awk in [('busybox', 'awk'), ('awk',)]:
            with self.subTest(awk=awk):
                data = json.loads(self.parse(text, awk).stdout)
                self.assertEqual(data['operator_name'], 'First Carrier')
                self.assertEqual(data['android_sims'][1]['operator_name'], '')
                self.assertEqual(data['temps'], 'bat=32.1 cpu=32.6 skin=31.9 pa=32.9')
        # A readable sysfs power-amplifier sensor still wins over the HAL value.
        with_sysfs = text.replace('__5GM_TETHER__', '__5GM_SENSORS__\npa_therm1 34000\n__5GM_TETHER__')
        self.assertEqual(json.loads(self.parse(with_sysfs).stdout)['temps'], 'bat=32.1 cpu=32.6 skin=31.9 pa=34')

    def test_phone_battery_charging_and_detailed_sensors(self):
        text = fixture().replace('__5GM_BATTERY__', '__5GM_NUMBERS__\n5 +15551234567\n__5GM_BATTERY__\n  status: 2')
        text = text.replace('__5GM_TETHER__', '__5GM_SENSORS__\nmdmss-0 38000\ngpuss-0 37000\nwifi_therm 33000\npa_therm1 34000\nvbat 3995\ninvalid -273000\ncpu-hw-trip-0 95000\npm-bcl-lvl0 0\n__5GM_TETHER__')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual(data['phone'], '+15551234567')
        self.assertEqual(data['simslot'], 'SIM 2')
        self.assertEqual(data['battery_charging'], '1')
        self.assertEqual(data['mtemp'], '38 &deg;C')
        self.assertEqual([s['name'] for s in data['temperature_sensors']], ['mdmss-0', 'gpuss-0', 'wifi_therm', 'pa_therm1'])
        self.assertIn('modem=38', data['temps'])
        self.assertIn('gpu=37', data['temps'])

    def test_secondary_lte_carriers_are_standard_fields(self):
        text = fixture().replace('mOperatorAlphaLong=Second Carrier,', 'mOperatorAlphaLong=Second Carrier, isUsingCarrierAggregation=true,')
        text = text.replace('mPhysicalCellId=60,mBand=0}', 'mPhysicalCellId=60,mBand=0},{mConnectionStatus=SecondaryServing,mNetworkType=LTE,mBand=7,mDownlinkChannelNumber=3000,mPhysicalCellId=70,mCellBandwidthDownlinkKhz=20000}')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual(data['android_ca'], '1')
        self.assertEqual(data['s1band'], 'B7 @20MHz')
        self.assertEqual(data['s1earfcn'], '3000')
        self.assertEqual(data['s1pci'], '70')

    def test_carrier_aggregation_reports_carrier_count_and_total_width(self):
        text = fixture().replace('mOperatorAlphaLong=Second Carrier,', 'mOperatorAlphaLong=Second Carrier, mCellBandwidths=[10000, 20000, 20000], isUsingCarrierAggregation=true,')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual((data['android_ca'], data['android_ca_carriers'], data['android_ca_bandwidth']), ('1', '3', '50'))
        text = fixture().replace('mOperatorAlphaLong=Second Carrier,', 'mOperatorAlphaLong=Second Carrier, mCellBandwidths=[10000, 15000], isUsingCarrierAggregation=true,')
        self.assertEqual(json.loads(self.parse(text).stdout)['android_ca_bandwidth'], '25')
        for widths, ca in [('[10000]', 'true'), ('[10000, 15000]', 'false'), ('[2147483647, 15000]', 'true'), ('[]', 'true')]:
            text = fixture().replace('mOperatorAlphaLong=Second Carrier,', f'mOperatorAlphaLong=Second Carrier, mCellBandwidths={widths}, isUsingCarrierAggregation={ca},')
            self.assertNotIn('android_ca_carriers', json.loads(self.parse(text).stdout), (widths, ca))

    def test_timing_advance_and_cqi_use_valid_values_only(self):
        for awk in [('busybox', 'awk'), ('awk',)]:
            with self.subTest(awk=awk):
                text = fixture().replace('cqi=2147483647 ta=2147483647', 'cqi=11 ta=6')
                data = json.loads(self.parse(text, awk).stdout)
                self.assertEqual((data['ta'], data['bs_distance'], data['cqi']), ('6', '469', '11'))
        text = fixture().replace('cqi=2147483647 ta=2147483647', 'cqi=11 ta=0')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual(data['ta'], '0')
        self.assertNotIn('bs_distance', data)
        data = json.loads(self.parse(fixture().replace('cqi=2147483647 ta=2147483647', 'cqi=99 ta=5000')).stdout)
        self.assertNotIn('ta', data)
        self.assertNotIn('bs_distance', data)
        self.assertNotIn('cqi', data)

    def test_modem_firmware_is_the_baseband_and_the_build_is_kept_separately(self):
        data = json.loads(self.parse(fixture()).stdout)
        self.assertEqual(data['firmware'], 'test-build')
        self.assertNotIn('android_build', data)
        for baseband, expected in [('MPSS.A,MPSS.A', 'MPSS.A'), ('MPSS.A,MPSS.B', 'MPSS.A / MPSS.B'), ('MPSS.A', 'MPSS.A')]:
            data = json.loads(self.parse(fixture().replace('test-build\n', 'test-build\n' + baseband + '\n')).stdout)
            self.assertEqual((data['firmware'], data['android_build']), (expected, 'test-build'))

    def test_battery_voltage_health_and_thermal_status(self):
        text = fixture().replace('  temperature: 321', '  voltage: 4105\n  health: 2\n  temperature: 321').replace('Cached temperatures:', 'Thermal Status: 3\nCached temperatures:')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual((data['battery_voltage'], data['battery_health'], data['thermal_status']), ('4105', '2', '3'))
        text = fixture().replace('  temperature: 321', '  voltage: 9\n  health: 9\n  temperature: 321')
        data = json.loads(self.parse(text).stdout)
        for key in ('battery_voltage', 'battery_health', 'thermal_status'):
            self.assertNotIn(key, data)

    def test_mobile_data_apn_and_pdp_type_belong_to_the_upstream_interface(self):
        lines = ('  NetworkAgentInfo{network{256}  ni{MOBILE[EDGE] CONNECTED extra: m.example} created=2026 lp{{InterfaceName: rmnet_data3 LinkAddresses: [ 10.1.2.3/30, 2001:db8::1/64 ]\n'
                 '  NetworkAgentInfo{network{257}  ni{MOBILE[LTE] CONNECTED extra: IMS} created=2026 lp{{InterfaceName: rmnet_data4 LinkAddresses: [ 11.1.2.3/27 ]\n')
        text = fixture().replace('__5GM_END__', '__5GM_DATA__\n' + lines + '__5GM_END__')
        data = json.loads(self.parse(text).stdout)
        self.assertEqual((data['iface_apn'], data['iface_pdptype']), ('m.example', 'ipv4v6'))
        # IMS is never presented as the internet APN; an interface that is not the upstream is ignored.
        data = json.loads(self.parse(text.replace('[rmnet_data3]', '[rmnet_data4]')).stdout)
        self.assertNotIn('iface_apn', data)
        self.assertEqual(data['iface_pdptype'], 'ipv4')
        data = json.loads(self.parse(text.replace('[rmnet_data3]', '[wlan0]')).stdout)
        self.assertNotIn('iface_apn', data)
        self.assertNotIn('iface_pdptype', data)

    def test_nsa_carrier_becomes_a_standard_secondary_carrier_and_mode(self):
        text = (SHARE / '5gmodem.sh').read_text()
        begin = text.index('\t\t\t# 5G NSA: the NR carrier')
        end = text.index('\t\t\t_tj_ca=$(printf', begin)
        script = r'''
jsonfilter() { python3 -c 'import json,sys; d=json.load(sys.stdin); v=d.get(sys.argv[2][2:], ""); print(v)' "$@"; }
_tj_android=$ANDROID
_tj_bands=B3
''' + text[begin:end] + '\nprintf "%s|%s|%s\\n" "$_tj_nsa" "$_tj_bands" "$_tj_android"\n'
        base = {'s1band': 'B7 @20MHz', 'nr_band': 'n78', 'nr_pci': '300', 'nr_arfcn': '641280', 'nr_rsrp': '-95', 'nr_sinr': '14'}
        result = shell(script, dict(os.environ, ANDROID=json.dumps(base)))
        self.assertEqual(result.returncode, 0, result.stderr)
        nsa, bands, merged = result.stdout.strip().split('|', 2)
        data = json.loads(merged)
        self.assertEqual((nsa, bands), ('1', 'B3 + n78'))
        self.assertEqual((data['s2band'], data['s2pci'], data['s2earfcn'], data['s2rsrp'], data['s2sinr'], data['s2state']),
                         ('n78', '300', '641280', '-95', '14', 'activated'))
        self.assertEqual(data['s1band'], 'B7 @20MHz')
        full = dict(base, s2band='B1', s3band='B2', s4band='B5')
        result = shell(script, dict(os.environ, ANDROID=json.dumps(full)))
        self.assertTrue(result.stdout.startswith('|B3|'), result.stdout)
        result = shell(script, dict(os.environ, ANDROID=json.dumps({'s1band': 'B7'})))
        self.assertTrue(result.stdout.startswith('|B3|'), result.stdout)

    def test_probe_reads_phone_numbers_without_tr_range_loss(self):
        probe = (SHARE / 'android-probe.sh').read_text()
        probe = probe.replace('/sys/class/thermal/thermal_zone*', '/nonexistent-android-test-zone/*')
        source = r'''
getprop() { :; }
dumpsys() {
 case "$1" in isub) echo '  Logical SIM slot 1: subId=5' ;; esac
}
cmd() { [ "$*" = 'phone get-phone-number 5 1' ] && echo +15551234567; }
''' + probe
        result = shell(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('5 +15551234567', result.stdout)
        self.assertIn('__5GM_END__', result.stdout)

    def test_switching_data_sim_and_unknown_subscription(self):
        data = json.loads(self.parse(fixture(1)).stdout)
        self.assertEqual(data['android_slot'], '0')
        self.assertEqual(data['rsrp'], '-80')
        self.assertNotEqual(self.parse(fixture(99)).returncode, 0)

    def test_missing_values_and_incomplete_dump_are_not_measurements(self):
        text = fixture().replace('rssnr=4', 'rssnr=2147483647').replace('level=3 ', '')
        text = text.replace('mPhysicalCellId=60', 'mPhysicalCellId=2147483647')
        data = json.loads(self.parse(text).stdout)
        for key in ('sinr', 'signal', 'pci'):
            self.assertNotIn(key, data)
        self.assertNotEqual(self.parse(fixture().replace('__5GM_END__', '')).returncode, 0)
        self.assertNotEqual(self.parse('Permission Denial\n__5GM_END__\n').returncode, 0)

    def test_nr_is_not_mislabelled_with_lte_measurements(self):
        data = json.loads(self.parse(fixture().replace('accessNetworkTechnology=LTE', 'accessNetworkTechnology=NR')).stdout)
        self.assertEqual(data['mode'], 'NR')
        self.assertNotIn('rsrp', data)
        self.assertNotIn('earfcn', data)

    def test_dispatch_caches_android_and_does_not_intercept_other_tethers(self):
        text = (SHARE / '5gmodem.sh').read_text()
        begin = text.index('\tif [ "$_tj_os" = android ]')
        end = text.index('\tif [ "$_tj_os" = router ]', begin)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'android.sh').write_text("""android_json() { [ "$AUTH" = ready ] || return 1; echo '{"backend":"android","earfcn":"1892"}'; }
""")
            prefix = function('earfcn2band', '5gmodem.sh') + r'''
jsonfilter() { cat >/dev/null; case "$*" in *@.earfcn*) echo 1892 ;; esac; }
json_esc() { printf '%s' "$1"; }
uptime_s() { echo 123; }
_tj_os=$OS
_POLL_AM=1-2
_tj_if=mobile
_tj_ip=10.0.0.2
_tj_nd=usb0
'''
            source = prefix + text[begin:end] + '\necho fallback\n'
            for osname, auth, success in [('android', 'ready', True), ('android', 'unauthorized', False),
                    ('iphone', 'ready', False), ('router', 'ready', False), ('phone', 'ready', False)]:
                cache = root / ('cache-' + osname + auth)
                env = dict(os.environ, OS=osname, AUTH=auth, RES=str(root), CACHE=str(cache), STAMP=str(cache)+'.stamp')
                result = shell(source, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                if success:
                    data = json.loads(result.stdout)
                    self.assertEqual(data['pband'], 'B3')
                    self.assertEqual(json.loads(cache.read_text()), data)
                    self.assertEqual(Path(str(cache)+'.stamp').read_text().strip(), '123')
                else:
                    self.assertEqual(result.stdout.strip(), 'fallback')
                    self.assertFalse(cache.exists())

    def test_device_name_is_the_marketing_name_or_the_model_with_its_maker(self):
        head = '__5GM_DEVICE__\nXiaomi "test" \\ phone\ntest-model\ntest-build\n__5GM_REGISTRY__'
        base = fixture()
        self.assertIn(head, base)

        def name(market, model, brand=None):
            device = '__5GM_DEVICE__\n' + market + '\n' + model + '\ntest-build\nbaseband\n' + ('' if brand is None else brand + '\n')
            data = json.loads(self.parse(base.replace(head, device + '__5GM_REGISTRY__')).stdout)
            return data['modem']

        self.assertEqual(name('Xiaomi 17', '25113PN0EG', 'Xiaomi'), 'Xiaomi 17')
        # Samsung has no marketing name: the maker is put in front of the model code.
        self.assertEqual(name('', 'SM-G991B', 'samsung'), 'Samsung SM-G991B')
        self.assertEqual(name('', 'Pixel 8', 'Google'), 'Google Pixel 8')
        self.assertEqual(name('', 'OPPO Find', 'OPPO'), 'OPPO Find')
        self.assertEqual(name('', 'motorola edge', 'motorola'), 'motorola edge')
        # An older probe without the maker line and an unusable maker leave the model alone.
        self.assertEqual(name('', 'SM-G991B'), 'SM-G991B')
        self.assertEqual(name('', 'SM-G991B', 'sam"sung'), 'SM-G991B')

    def test_the_poll_keeps_the_phone_name_in_its_section_for_the_lists(self):
        text = (SHARE / '5gmodem.sh').read_text()
        begin = text.index('\tif [ "$_tj_os" = android ]')
        end = text.index('\tif [ "$_tj_os" = router ]', begin)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / 'usb/1-2'
            device.mkdir(parents=True)
            (device / 'idVendor').write_text('04e8\n')
            (device / 'idProduct').write_text('6862\n')
            (root / 'android.sh').write_text("""android_json() { echo '{"backend":"android","modem":"Samsung SM-G991B"}'; }\n""")
            prefix = r'''
jsonfilter() { cat >/dev/null; case "$*" in *@.modem*) echo "Samsung SM-G991B" ;; esac; }
uci() { case "$*" in
 "-q get 5gmodem.m_1_2.model") printf '%s' "$OLD_MODEL" ;;
 "-q get 5gmodem.m_1_2.model_vp") printf '%s' "$OLD_VP" ;;
 "-q set "*|"-q commit 5gmodem") echo "$*" >> "$UCILOG" ;;
esac; }
earfcn2band() { :; }
json_esc() { printf '%s' "$1"; }
uptime_s() { echo 1; }
_tj_os=android
_POLL_AM=1-2
_hl_sec=m_1_2
_tj_if=mobile
_tj_nd=usb0
'''
            source = (prefix + text[begin:end] + '\necho fallback\n').replace('/sys/bus/usb/devices/', f'{root}/usb/').replace('/tmp/5gmodem', f'{root}/tmp')
            def run(old_model, old_vp):
                log = root / 'uci.log'
                log.unlink(missing_ok=True)
                env = dict(os.environ, RES=str(root), CACHE=str(root / 'cache'), STAMP=str(root / 'stamp'),
                           OLD_MODEL=old_model, OLD_VP=old_vp, UCILOG=str(log))
                result = shell(source, env)
                self.assertEqual(result.returncode, 0, result.stderr)
                return log.read_text().splitlines() if log.exists() else []
            # The USB descriptor name (or a leftover from the time the phone was taken for a modem) is replaced.
            self.assertEqual(run('SAMSUNG_Android', '04e8:6862'),
                             ['-q set 5gmodem.m_1_2.model=Samsung SM-G991B', '-q set 5gmodem.m_1_2.model_vp=04e8:6862', '-q commit 5gmodem'])
            # Nothing is written while the stored name is current.
            self.assertEqual(run('Samsung SM-G991B', '04e8:6862'), [])
            # A different phone on the same port is renamed even when the name is the same.
            self.assertEqual(len(run('Samsung SM-G991B', '2717:ff88')), 3)

    def test_hung_adb_is_killed_and_failure_is_propagated(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'adb'
            executable.write_text('#!/bin/sh\nexec sleep 60\n')
            executable.chmod(0o755)
            source = function('android_adb', 'android.sh').replace('sleep 8 ', 'sleep 1 ') + '\nandroid_adb devices\n'
            start = time.monotonic()
            result = shell(source, dict(os.environ, PATH=directory+os.pathsep+os.environ['PATH']))
            self.assertNotEqual(result.returncode, 0)
            self.assertLess(time.monotonic()-start, 4)

    def test_reader_targets_usb_serial_and_requires_authorized_adb_interface(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            usb = root / 'usb'
            device = usb / '1-2'
            interface = usb / '1-2:1.2'
            device.mkdir(parents=True)
            interface.mkdir()
            for name, value in [('serial', 'phone-one'), ('idVendor', '2717'), ('idProduct', 'ff88')]:
                (device / name).write_text(value)
            for name, value in [('bInterfaceClass', 'ff'), ('bInterfaceSubClass', '42'), ('bInterfaceProtocol', '01')]:
                (interface / name).write_text(value)
            capture = root / 'capture'
            capture.write_text(fixture())
            source = (SHARE / 'android.sh').read_text().replace('/sys/bus/usb/devices/', str(usb) + '/')
            source += '''
android_adb() {
 printf '%s %s %s\\n' "$1" "$2" "$3" >> "$CALLS"
 case "$*" in
  *get-state) echo "$AUTH" ;;
  *shell*) [ "${#4}" -lt 1024 ] || return 255; cat "$CAPTURE" ;;
 esac
}
android_json 1-2 mobile 10.0.0.2 usb0
'''
            env = dict(os.environ, RES=str(SHARE), CAPTURE=str(capture), CALLS=str(root / 'calls'), AUTH='device')
            result = shell(source, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['vidpid'], '2717:ff88')
            self.assertTrue(all(line.startswith('-s phone-one ') for line in (root / 'calls').read_text().splitlines()))
            result = shell(source, dict(env, AUTH='unauthorized'))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, '')
            (interface / 'bInterfaceSubClass').write_text('00')
            (root / 'calls').unlink()
            self.assertNotEqual(shell(source, env).returncode, 0)
            self.assertFalse((root / 'calls').exists())


if __name__ == '__main__':
    unittest.main()
