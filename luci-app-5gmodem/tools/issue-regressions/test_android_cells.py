import json
import hashlib
import os
import tempfile
from pathlib import Path
import struct
import zlib
import subprocess
import unittest

from test_runtime_audit import SHARE, function, shell


def cell(registered, age=1, pci=60, earfcn=1892, ci=12345678, tac=12345):
    stamp = int((1000000 - age * 1000) * 1000000)
    return f'CELL|{str(registered).lower()}|{stamp}|CellIdentityLte|{ci}||{tac}||{pci}|{earfcn}|3|-67|-99|-14|4\n'


def nr_cell(registered=True, age=1, pci=300, arfcn=641280, band=78, status=0, rsrp=-95, rsrq=-11, sinr=14):
    stamp = int((1000000 - age * 1000) * 1000000)
    return (f'CELL|{str(registered).lower()}|{stamp}|CellIdentityNr||||{""}|{pci}||{band}|||||{arfcn}|1234567890123|{rsrp}|{rsrq}|{sinr}|{status}\n')


def service(pci=60, earfcn=1892):
    return f'SERVICE|CellIdentityLte|12345678||12345||{pci}|{earfcn}\n'


class AndroidCells(unittest.TestCase):
    def parse(self, text):
        return subprocess.run(['busybox', 'awk', '-f', str(SHARE / 'android-cells.awk')],
            input=text, text=True, capture_output=True, timeout=5)

    def test_packaged_dex_is_valid(self):
        data = (SHARE / 'android-cells.dex').read_bytes()
        self.assertEqual(data[:4], b'dex\n')
        self.assertEqual(data[12:32], hashlib.sha1(data[32:]).digest())
        self.assertEqual(struct.unpack('<I', data[8:12])[0], zlib.adler32(data[12:]) & 0xffffffff)

    def test_native_sim_identifiers_and_switch_capability(self):
        text = 'META|1000000|60|1892\nIDENTITY|310260123456789|8901260123456789012|123456789012345\nCAPABILITY|true\n'+service()
        data = json.loads(self.parse(text).stdout)
        self.assertEqual(data['imsi'], '310260123456789')
        self.assertEqual(data['iccid'], '8901260123456789012')
        self.assertEqual(data['imei'], '123456789012345')
        self.assertEqual(data['android_sim_switch'], '1')
        data = json.loads(self.parse(text.replace(service(), service(pci=70))).stdout)
        self.assertEqual(data['android_cell_source'], 'identity_api')
        self.assertNotIn('cid_dec', data)
        self.assertEqual(data['neighbors'], [])

    def test_standard_identity_and_fresh_neighbour_fields(self):
        result = self.parse('META|1000000|60|1892\n'+service()+cell(True)+cell(False, pci=61))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data['cid_dec'], '12345678')
        self.assertEqual(data['cid_hex'], format(12345678, 'X'))
        self.assertEqual(data['enbid'], str(12345678//256))
        self.assertEqual(data['tac_dec'], '12345')
        self.assertNotIn('lac_dec', data)
        self.assertEqual(len(data['neighbors']), 2)
        self.assertEqual(data['neighbors'][1]['serving'], '0')
        self.assertEqual(data['neighbors'][1]['pci'], '61')
        self.assertEqual(data['neighbors'][1]['rsrp'], '-99')

    def test_old_future_and_unknown_cells_are_not_displayed(self):
        text = 'META|1000000|60|1892\n'+service()+cell(False, age=31)+cell(False, age=-1)
        text += cell(False, pci=2147483647)
        result = self.parse(text)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)['neighbors'], [])

    def test_handover_mismatch_does_not_mix_serving_cells(self):
        result = self.parse('META|1000000|60|1892\n'+service(pci=70)+cell(True, pci=70))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_callback_unavailable_identity_does_not_overwrite_valid_service_state(self):
        result = self.parse('META|1000000|60|1892\n'+service()+cell(True, ci=2147483647, tac=2147483647))
        data = json.loads(result.stdout)
        self.assertEqual(data['cid_dec'], '12345678')
        self.assertEqual(data['tac_dec'], '12345')

    def test_umts_lac_is_separate_from_lte_tac(self):
        result = self.parse('META|1000000||\nSERVICE|CellIdentityWcdma||123456||4567||\n')
        data = json.loads(result.stdout)
        self.assertEqual(data['lac_dec'], '4567')
        self.assertEqual(data['cid_dec'], '123456')
        self.assertNotIn('tac_dec', data)
        self.assertNotIn('enbid', data)

    def test_ims_availability_is_reported_per_subscription(self):
        data = json.loads(self.parse('META|1000000|60|1892\nIMS|true|false\n' + service()).stdout)
        self.assertEqual((data['volte'], data['android_wfc']), ('1', '0'))
        data = json.loads(self.parse('META|1000000|60|1892\nIMS|false|\n' + service()).stdout)
        self.assertEqual(data['volte'], '0')
        self.assertNotIn('android_wfc', data)
        self.assertNotIn('volte', json.loads(self.parse('META|1000000|60|1892\nIMS||\n' + service()).stdout))

    def test_fresh_nr_cell_is_published_as_nr_fields_and_not_as_lte_neighbour(self):
        data = json.loads(self.parse('META|1000000|60|1892\n' + service() + cell(True) + nr_cell()).stdout)
        self.assertEqual((data['nr_band'], data['nr_arfcn'], data['nr_pci']), ('n78', '641280', '300'))
        self.assertEqual((data['nr_rsrp'], data['nr_rsrq'], data['nr_sinr']), ('-95', '-11', '14'))
        self.assertEqual(len(data['neighbors']), 1)
        self.assertEqual(data['neighbors'][0]['pci'], '60')

    def test_nr_cell_needs_registration_or_serving_status_and_a_fresh_valid_record(self):
        base = 'META|1000000|60|1892\n' + service() + cell(True)
        accepted = [nr_cell(False, status=2), nr_cell(False, status=1), nr_cell(True)]
        rejected = [nr_cell(False, status=0), nr_cell(True, age=31), nr_cell(True, age=-1), nr_cell(True, pci=2000),
                    nr_cell(True, arfcn=9999999), nr_cell(True, rsrp=-200)]
        for record in accepted:
            self.assertIn('nr_pci', json.loads(self.parse(base + record).stdout), record)
        for record in rejected[:5]:
            self.assertNotIn('nr_pci', json.loads(self.parse(base + record).stdout), record)
        data = json.loads(self.parse(base + rejected[5]).stdout)
        self.assertNotIn('nr_rsrp', data)
        self.assertEqual(data['nr_pci'], '300')


    def test_android_cells_passes_ims_and_nr_columns_in_the_order_the_parser_expects(self):
        helper_json = {'can_switch_data': True, 'elapsed_ms': 1000000, 'subscriptions': [{
            'sub_id': 5, 'imsi': '250200000000001', 'volte': False, 'wfc': True, 'registrations': [],
            'cells': [
                {'registered': True, 'timestamp_ns': 999000000000, 'status': 1,
                 'identity': {'type': 'CellIdentityLte', 'ci': 12345678, 'tac': 12345, 'pci': 60, 'earfcn': 1892, 'bands': [3]},
                 'rssi': -67, 'rsrp': -99, 'rsrq': -14, 'sinr': 4},
                {'registered': False, 'timestamp_ns': 999000000000, 'status': 2,
                 'identity': {'type': 'CellIdentityNr', 'pci': 300, 'nrarfcn': 641280, 'bands': [78], 'nci': 1234567890123},
                 'ss_rsrp': -95, 'ss_rsrq': -11, 'ss_sinr': 14}]}]}
        pathscript = r'''
jsonfilter() {
 python3 - "$2" "$4" <<'PY'
import json, re, sys
data = json.loads(sys.argv[1]); path = sys.argv[2][2:]
for part in re.findall(r'[^.\[\]]+|\[\d+\]', path):
    try:
        data = data[int(part[1:-1])] if part.startswith('[') else data[part]
    except (KeyError, IndexError, TypeError):
        data = None; break
print('' if data is None else (str(data).lower() if isinstance(data, bool) else data))
PY
}
android_cells_ready() { echo phone-serial; }
android_adb() { printf '%s' "$HELPER"; }
'''
        base = json.dumps({'android_data_subscription': '5', 'pci': '60', 'earfcn': '1892'})
        source = pathscript + function('android_cell_fields', 'android.sh') + '\n' + function('android_cells', 'android.sh').replace('/tmp/5gmodem/', '/nonexistent-5gm/') \
            + '\nRES=' + str(SHARE) + '\nandroid_cells 1-1 \'' + base + '\'\n'
        result = shell(source, dict(os.environ, HELPER=json.dumps(helper_json)))
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual((data['volte'], data['android_wfc']), ('0', '1'))
        self.assertEqual((data['nr_band'], data['nr_arfcn'], data['nr_pci'], data['nr_rsrp'], data['nr_sinr']), ('n78', '641280', '300', '-95', '14'))
        self.assertEqual(data['cid_dec'], '12345678')
        self.assertEqual(len(data['neighbors']), 1)


if __name__ == '__main__':
    unittest.main()
