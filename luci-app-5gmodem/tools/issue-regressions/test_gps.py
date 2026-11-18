#!/usr/bin/env python3
# A feature request asked for the GNSS receiver many modems carry: position, speed, satellites,
# on/off and start mode, a map, and the position in exported metrics. gps.sh reads it with AT
# commands (Quectel, SIMCom, Telit, MeiG) or from the NMEA port (Foxconn, Fibocom, Sierra).
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from test_runtime_audit import ROOT, SHARE, shell

GPS = SHARE / 'gps.sh'

# jsonfilter is OpenWrt-only: enough of it for "-e @.a.b[*]", "@.a.b[0]" and "@[@.path='X'].key[0]"
JSONFILTER = r"""#!/usr/bin/env python3
import json, re, sys
expr = sys.argv[sys.argv.index('-e') + 1]
try:
    cur = [json.loads(sys.argv[sys.argv.index('-s') + 1] if '-s' in sys.argv else sys.stdin.read())]
except ValueError:
    sys.exit(1)
for tok in re.findall(r"\.([\w-]+)|\[([^\]]*)\]", expr[1:]):
    key, idx = tok
    nxt = []
    for c in cur:
        if key:
            if isinstance(c, dict) and key in c: nxt.append(c[key])
        elif idx == '*':
            nxt.extend(c if isinstance(c, list) else [])
        elif idx.isdigit():
            if isinstance(c, list) and len(c) > int(idx): nxt.append(c[int(idx)])
        else:
            m = re.match(r"@\.(\w+)=.(.*).$", idx)
            nxt.extend(d for d in (c if isinstance(c, list) else []) if m and str(d.get(m[1])) == m[2])
            if not nxt: nxt = []
    cur = nxt
if not cur: sys.exit(1)
for c in cur:
    print(c if isinstance(c, str) else json.dumps(c))
"""


def stub_bin(t):
    (t / 'bin').mkdir(exist_ok=True)
    (t / 'bin/jsonfilter').write_text(JSONFILTER)
    (t / 'bin/jsonfilter').chmod(0o755)
    return dict(os.environ, PATH=f"{t / 'bin'}:{os.environ['PATH']}")


def parse(action, data, arg=''):
    with tempfile.TemporaryDirectory() as t:
        r = shell(f"sh {GPS} {action} {arg} <<'EOF'\n{data}\nEOF\n", env=stub_bin(Path(t)))
    return dict(l.split('=', 1) for l in r.stdout.split('\n') if '=' in l), r


# mmcli -J output as cli/mmcli-output.c (ModemManager 1.24.0) prints it: one line, keys sorted,
# every value a string ("--" when unknown), NMEA traces as an array of strings
def mm_location_get(nmea=(), lat='--', lon='--', alt='--', utc='--'):
    return json.dumps({'modem': {'location': {
        '3gpp': {'cid': '0000ABCD', 'lac': '0000', 'mcc': '001', 'mnc': '01', 'tac': '00A1B2'},
        'cdma-bs': {'latitude': '--', 'longitude': '--'},
        'gps': {'altitude': alt, 'latitude': lat, 'longitude': lon, 'nmea': list(nmea), 'utc': utc}}}},
        separators=(',', ':'))


def mm_location_status(caps, enabled):
    return json.dumps({'modem': {'location': {
        'capabilities': caps, 'enabled': enabled,
        'gps': {'assistance': ['xtra'], 'assistance-servers': [], 'refresh-rate': '30', 'supl-server': '--'},
        'signals': 'no'}}}, separators=(',', ':'))


NMEA_FIX = [
    '$GNGGA,093357.00,5545.13320,N,03736.93360,E,1,09,0.98,152.4,M,14.2,M,,*7A',
    '$GNRMC,093357.00,A,5545.13320,N,03736.93360,E,22.40,84.4,141126,,,A*7B',
    '$GNGSA,A,3,04,05,09,12,24,,,,,,,,1.6,0.98,1.2*0E',
    '$GPGSV,3,1,11,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45*75',
]


class Parsers(unittest.TestCase):
    def test_nmea_fix(self):
        d, r = parse('parse-nmea', '\n'.join([
            '$GNGGA,093357.00,5545.13320,N,03736.93360,E,1,09,0.98,152.4,M,14.2,M,,*7A',
            '$GNRMC,093357.00,A,5545.13320,N,03736.93360,E,22.40,84.4,141126,,,A*7B',
            '$GNGSA,A,3,04,05,09,12,24,,,,,,,,1.6,0.98,1.2*0E',
            '$GPGSV,3,1,11,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45*75',
            '$GLGSV,1,1,03,65,40,083,46*75',
        ]))
        self.assertEqual(r.stderr, '')
        self.assertEqual(d['fix'], '3')
        self.assertEqual(d['lat'], '55.752220')
        self.assertEqual(d['lon'], '37.615560')
        self.assertEqual(d['speed'], '41.5')      # 22.4 knots
        self.assertEqual(d['sats'], '9')
        self.assertEqual(d['inview'], '14')       # 11 GPS + 3 GLONASS
        self.assertEqual(d['hdop'], '0.98')
        self.assertEqual(d['utc'], '2026-11-14T09:33:57Z')

    def test_nmea_foxconn_t77w968(self):
        # T77W968 (Dell mode, NMEA on ttyUSB2): GP talker only, minutes with 6 decimals,
        # GSA mode 2 with 12 satellites, GSV split over 4 sentences; coordinates are synthetic
        d, r = parse('parse-nmea', '\n'.join([
            '$GPGGA,113700.00,5545.133200,N,03736.933600,E,1,12,0.7,152.4,M,15.0,M,,*6D',
            '$GPVTG,125.8,T,117.0,M,54.0,N,100.1,K,A*1B',
            '$GPRMC,113700.00,A,5545.133200,N,03736.933600,E,54.0,125.8,151126,8.9,E,A*0D',
            '$GPGSA,A,2,01,02,10,12,14,15,17,19,20,22,23,24,1.0,0.7,0.8*36',
            '$GPGSV,4,1,14,01,14,056,49,02,14,030,49,10,14,333,50,12,09,241,51*71',
            '$GPGSV,4,4,14,30,18,119,49,13,02,247,*73',
        ]))
        self.assertEqual(r.stderr, '')
        self.assertEqual((d['fix'], d['lat'], d['lon']), ('2', '55.752220', '37.615560'))
        self.assertEqual((d['sats'], d['inview'], d['hdop'], d['alt']), ('12', '14', '0.7', '152.4'))
        self.assertEqual((d['speed'], d['course']), ('100.0', '125.8'))   # 54 knots
        self.assertEqual(d['utc'], '2026-11-15T11:37:00Z')

    def test_nmea_fm350_urc_stream(self):
        # FM350 (+ELCSNMEA lines unwrapped by _fm_urc_read): GN talker, four systems, fractional
        # SNR in GSV, no GGA in the captured slice: satellites in use and HDOP come from GSA.
        # Shape from a field report; coordinates are synthetic
        d, r = parse('parse-nmea', '\n'.join([
            '$GAGSV,3,1,12,33,64,090,18.3,16,62,283,,31,53,147,33.8,12,41,190,11.2,7*65',
            '$GBGSV,5,1,19,38,69,229,22.8,23,52,232,19.5,34,46,075,25.5,13,44,238,19.0,1*71',
            '$GNRMC,173721.000,A,5545.1332,N,03736.9336,E,0.000,338.18,151126,,,D,V*30',
            '$GNVTG,338.18,T,,M,0.000,N,0.000,K,D*27',
            '$GNACCURACY,1.6,179.9,1.7,10.5*27',
            '$GNGSA,A,3,29,25,05,21,18,26,13,12,,,,,0.67,0.40,0.53,1*04',
            '$GNGSA,A,3,12,03,10,31,23,32,33,25,,,,,0.67,0.40,0.53,3*04',
            '$GPGSV,4,1,16,29,83,257,21.1,42,73,299,39.0,25,45,163,33.9,05,35,114,26.1,1*67',
            '$GLGSV,3,3,10,87,09,232,12.3,70,05,090,27.3,1*71',
            # the next epoch repeats the same satellites: they are not counted twice
            '$GNGSA,A,3,29,25,05,21,18,26,13,12,,,,,0.67,0.40,0.53,1*04',
            '$GNGSA,A,3,12,03,10,31,23,32,33,25,,,,,0.67,0.40,0.53,3*04',
        ]))
        self.assertEqual(r.stderr, '')
        self.assertEqual((d['fix'], d['lat'], d['lon']), ('3', '55.752220', '37.615560'))
        self.assertEqual((d['sats'], d['inview'], d['hdop']), ('16', '57', '0.4'))
        self.assertEqual((d['speed'], d['course']), ('0.0', '338.2'))
        self.assertEqual(d['utc'], '2026-11-15T17:37:21Z')

    def test_nmea_fm350_elcsloc_fallback(self):
        # only the "+ELCSLOC:" line (as "$PELCSLOC,") carries the position; synthetic coordinates
        loc = '$PELCSLOC,55.752220,37.615560,192.00,0.00,338.18,1.60,10.50,1.20,179.90,1794764242000,"2026/11/15,17:37:22",0.67,0.40,0.53'
        d, r = parse('parse-nmea', '$GNGSA,A,3,12,03,10,31,,,,,,,,,0.67,0.40,0.53,3*04\n' + loc)
        self.assertEqual(r.stderr, '')
        self.assertEqual((d['fix'], d['lat'], d['lon'], d['alt']), ('3', '55.752220', '37.615560', '192'))
        self.assertEqual((d['sats'], d['hdop'], d['utc']), ('4', '0.4', '2026-11-15T17:37:22Z'))
        # sentences with a position win over the fallback line
        d, _ = parse('parse-nmea', '$GPGGA,120000,3351.000,S,15112.000,W,1,05,1.2,10,M,,M,,*00\n' + loc)
        self.assertEqual((d['lat'], d['lon'], d['sats']), ('-33.850000', '-151.200000', '5'))
        # an empty or zero position line is not a fix
        d, _ = parse('parse-nmea', '$GNGGA,021819.029,,,,,0,0,,,M,,M,,*5A\n$PELCSLOC,0.000000,0.000000,0.00')
        self.assertEqual(d.get('fix'), '0')
        self.assertNotIn('lat', d)

    def test_nmea_no_fix_and_southwest(self):
        d, _ = parse('parse-nmea', '$GPGGA,,,,,,0,00,99.99,,,,,,*48\n$GPRMC,,V,,,,,,,,,,N*53')
        self.assertEqual(d.get('fix'), '0')
        self.assertNotIn('lat', d)
        d, _ = parse('parse-nmea', '$GPGGA,120000,3351.000,S,15112.000,W,1,05,1.2,10,M,,M,,*00')
        self.assertEqual((d['lat'], d['lon']), ('-33.850000', '-151.200000'))

    def test_at_answers(self):
        d, _ = parse('parse-at', '+QGPSLOC: 093357.000,55.75222,37.61556,1.2,180.3,3,84.40,41.5,22.4,141126,08\r\nOK', 'quectel')
        self.assertEqual((d['fix'], d['lat'], d['lon'], d['sats'], d['speed']), ('3', '55.752220', '37.615560', '8', '41.5'))
        d, _ = parse('parse-at', '+CME ERROR: 516', 'quectel')
        self.assertEqual(d, {'fix': '0'})
        d, _ = parse('parse-at', '$GPSACP: 002518.000,3731.303660N,12655.781816E,0.8,73.1,3,0.0,0.0,0.0,290819,18', 'telit')
        self.assertEqual((d['lat'], d['lon'], d['utc']), ('37.521728', '126.929697', '2019-08-29T00:25:18Z'))
        d, _ = parse('parse-at', '+CGPSINFO: 3113.343286,N,12121.234064,E,250311,072809.3,44.1,10.0,90', 'simcom')
        self.assertEqual((d['lat'], d['lon'], d['speed'], d['alt']), ('31.222388', '121.353901', '18.5', '44.1'))
        d, _ = parse('parse-at', '+CGPSINFO: ,,,,,,,,', 'simcom')
        self.assertEqual(d, {'fix': '0'})
        d, _ = parse('parse-at', '+GpsLoc: 093357.0,5545.1332,N,03736.9336,E,0.9,152.4,3,84.4,10.0,141126,07', 'meig')
        self.assertEqual((d['lat'], d['sats'], d['fix']), ('55.752220', '7', '3'))
        self.assertNotIn('speed', d)
        # the manual's own example: no space after the colon, a status letter in the fix field
        d, _ = parse('parse-at', '+GpsLoc:061636.00,3411.766990,N,10851.859940,E,7.100000,351.400000,A,0.000000,0.000000,261022,7', 'meig')
        self.assertEqual((d['lat'], d['lon'], d['sats'], d['utc']), ('34.196117', '108.864332', '7', '2022-10-26T06:16:36Z'))

    def test_qmi_position_report(self):
        rep = '\n'.join([
            '[position report] status: success',
            '   latitude:  55.752220 degrees',
            '   longitude: 37.615560 degrees',
            '   circular horizontal position uncertainty:            4.000000 meters',
            '   horizontal speed: 11.527778 m/s',
            '   altitude w.r.t. ellipsoid: 166.000000 meters',
            '   altitude w.r.t. mean sea level: 152.400000 meters',
            '   heading: 84.400000 degrees',
            '   horizontal DOP: 0.980000',
            '   UTC timestamp: 1794704037000 ms',
            '   Satellites used: 3,7,9,16,23,26,65,71,72',
            "[/dev/cdc-wdm0] Client ID not released:", "\tService: 'loc'", "\t    CID: '2'"])
        d, _ = parse('parse-qmi', rep)
        self.assertEqual((d['qmi'], d['fix'], d['lat'], d['lon'], d['alt']), ('success', '3', '55.752220', '37.615560', '152.4'))
        self.assertEqual((d['speed'], d['course'], d['sats'], d['hdop'], d['utcms']), ('41.5', '84.4', '9', '1.0', '1794704037000'))
        # no fix yet: the engine answers "in-progress" with n/a coordinates (seen live on a Qualcomm router module)
        d, _ = parse('parse-qmi', '[position report] status: in-progress\n   latitude:  n/a\n   longitude: n/a\n'
                                  '   altitude w.r.t. ellipsoid: 0.000000 meters')
        self.assertEqual((d['qmi'], d['fix']), ('in-progress', '0'))
        # a stale client id: qmicli prints only the "not released" note
        d, _ = parse('parse-qmi', "[/dev/cdc-wdm0] Client ID not released:\n\tService: 'loc'")
        self.assertEqual(d, {'qmi': 'none'})

    def test_qmi_incomplete_cellular_position_is_not_a_fix(self):
        for status, technology in [('in-progress', 'cellular'),
                                   ('success', 'cellular'),
                                   ('in-progress', 'satellite')]:
            with self.subTest(status=status, technology=technology):
                report = ('[position report] status: ' + status + '\n'
                          '   latitude: 45.123456 degrees\n'
                          '   longitude: 12.345678 degrees\n'
                          '   altitude w.r.t. mean sea level: 35.000000 meters\n'
                          '   circular horizontal position uncertainty: 4000000.000 meters\n'
                          '   technology: ' + technology + '\n'
                          '   UTC timestamp: n/a\n'
                          '   time source: invalid\n')
                data, _ = parse('parse-qmi', report)
                self.assertEqual(data['fix'], '0')
                self.assertNotIn('lat', data)
                self.assertNotIn('lon', data)

    def test_mm_location_get(self):
        # gps-nmea and gps-raw enabled: speed, course and satellites come from the NMEA traces
        d, r = parse('parse-mm', mm_location_get(NMEA_FIX, '55.752220', '37.615560', '152.400000', '093357.00'))
        self.assertEqual(r.stderr, '')
        self.assertEqual((d['mm'], d['fix'], d['lat'], d['lon'], d['alt']), ('1', '3', '55.752220', '37.615560', '152.4'))
        self.assertEqual((d['speed'], d['course'], d['sats'], d['inview'], d['hdop']), ('41.5', '84.4', '9', '11', '0.98'))
        self.assertEqual(d['utc'], '2026-11-14T09:33:57Z')
        # only gps-raw: the position without NMEA details
        d, _ = parse('parse-mm', mm_location_get((), '-33.850000', '151.200000', '10.000000', '120000'))
        self.assertEqual((d['fix'], d['lat'], d['lon'], d['alt']), ('3', '-33.850000', '151.200000', '10.0'))
        self.assertNotIn('speed', d)
        # GPS-raw with an unknown altitude is printed as -G_MAXDOUBLE ("%lf"): not an altitude
        d, _ = parse('parse-mm', mm_location_get((), '55.0', '37.0', '%f' % -sys.float_info.max))
        self.assertEqual((d['fix'], d['lat']), ('2', '55.000000'))
        self.assertNotIn('alt', d)
        # enabled, no fix yet: GGA with quality 0, nothing from GPS-raw
        d, _ = parse('parse-mm', mm_location_get(['$GPGGA,,,,,,0,00,99.99,,,,,,*48', '$GPRMC,,V,,,,,,,,,,N*53']))
        self.assertEqual(d, {'mm': '1', 'fix': '0'})
        d, _ = parse('parse-mm', mm_location_get())
        self.assertEqual(d, {'mm': '1', 'fix': '0'})

    def test_mm_location_status(self):
        d, _ = parse('parse-mm-status', mm_location_status(['3gpp-lac-ci', 'gps-raw', 'gps-nmea', 'gps-unmanaged'], ['3gpp-lac-ci']))
        self.assertEqual(d, {'mmsrc': 'gps-nmea gps-raw', 'state': 'off'})
        d, _ = parse('parse-mm-status', mm_location_status(['3gpp-lac-ci', 'gps-nmea'], ['3gpp-lac-ci', 'gps-nmea']))
        self.assertEqual(d, {'mmsrc': 'gps-nmea', 'state': 'on'})
        # no GPS in MM ("none" is filtered out by mmcli, the array stays empty)
        d, _ = parse('parse-mm-status', mm_location_status(['3gpp-lac-ci'], []))
        self.assertEqual(d, {'mmsrc': '', 'state': 'off'})

    def test_quectel_outport(self):
        for ans, want in (('+QGPSCFG: "outport","none"', 'none'), ('+QGPSCFG: "outport","usbnmea"\r', 'usbnmea'),
                          ('+QGPSCFG: "outport","uartdebug"', 'uartdebug'), ('+CME ERROR: 501', '')):
            r = shell(f"printf '%s\\n' '{ans}' 'OK' | sh {GPS} parse-outport")
            self.assertEqual(r.stdout.strip(), want, ans)

    def test_state(self):
        for fam, ans, want in (('quectel', '+QGPS: 1', 'on'), ('simcom', '+CGPS: 0,1', 'off'),
                               ('telit', '$GPSP: 1', 'on'), ('fibocom', '+GTGPSPOWER: 0', 'off'),
                               ('foxconn', 'GPS is Enable, GPS HW Key pull up', 'on'),
                               ('foxconn', 'GPS is Disable', 'off'), ('foxconn', '1', 'on'),
                               ('meig', '+GPSSTATE: 0', 'off'), ('quectel', 'ERROR', ''),
                               ('huawei', '^WPINFO:3', 'on'), ('huawei', '^WPINFO: 0', 'off'), ('huawei', 'ERROR', '')):
            r = shell(f"printf '%s\\n' '{ans}' | sh {GPS} parse-state {fam}")
            self.assertEqual(r.stdout.strip(), want, (fam, ans))


class StatusWithStubs(unittest.TestCase):
    # gps.sh against a fake modem: lib.sh, uci and listmodems.sh are replaced
    def run_gps(self, vidpid, answers, *args, uci='', sysfs=None):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / 'res').mkdir()
            (t / 'bin').mkdir()
            if sysfs:
                sysfs(t / 'sys')
            # an answer given as a tuple (text,) comes without the final OK
            cases = ''.join(f"\t\t'{c}') printf '%s\\n' '{a[0]}' ;;\n" if isinstance(a, tuple)
                            else f"\t\t'{c}') printf '%s\\n' '{a}' 'OK' ;;\n" for c, a in answers.items())
            (t / 'res/lib.sh').write_text(
                'secname() { echo m_1_1; }\nis_devpath() { return 0; }\n'
                'at_query() {\n\techo "$2" >> "$GPS_TMP/sent"\n\tcase "$2" in\n' + cases +
                "\t\t*) echo ERROR ;;\n\tesac\n}\n")
            (t / 'res/listmodems.sh').write_text('#!/bin/sh\necho \'[{"path":"1-1","tty":[]}]\'\n')
            (t / 'res/listmodems.sh').chmod(0o755)
            (t / 'bin/uci').write_text(
                '#!/bin/sh\ncase "$*" in\n'
                '\t*active_modem) echo 1-1 ;;\n'
                f'\t*m_1_1.vidpid) echo {vidpid} ;;\n'
                '\t*m_1_1.at_port) echo /dev/ttyUSB2 ;;\n' + uci + 'esac\n')
            (t / 'bin/uci').chmod(0o755)
            (t / 'bin/ubus').write_text('#!/bin/sh\nexit 1\n')
            (t / 'bin/ubus').chmod(0o755)
            env = dict(stub_bin(t), GPS_RES=str(t / 'res'), GPS_TMP=str(t / 'tmp'), GPS_SYS=str(t / 'sys'))
            r = shell(f'sh {GPS} ' + ' '.join(args), env=env)
            sent = (t / 'tmp/sent').read_text().split('\n') if (t / 'tmp/sent').exists() else []
            return r, [s for s in sent if s]

    def test_qmi_session_kept_by_client_id(self):
        # a Qualcomm modem with the QMI LOC service and no vendor GNSS commands
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / 'res').mkdir(); (t / 'bin').mkdir()
            (t / 'res/lib.sh').write_text(r"""
secname() { echo m_1_1; }
is_devpath() { return 0; }
at_query() { echo ERROR; }
qmicli_p() {
	shift; echo "$*" >> "$GPS_TMP/q"
	case "$*" in
		*--get-service-version-info*) printf '%s\n' '[/dev/cdc-wdm0] Supported versions:' '	loc (2.0)' ;;
		*--loc-get-engine-lock*) echo 'Successfully retrieved engine lock: none' ;;
		*--loc-start*) printf '%s\n' 'Successfully started location tracking (session id 0)' "	    CID: '5'" ;;
		*--client-cid=5*--loc-get-position-report*) printf '%s\n' '[position report] status: success' '   latitude:  55.0 degrees' '   longitude: 37.0 degrees' '   technology: satellite' ;;
		*--loc-stop*) echo 'Successfully stopped' ;;
	esac
}
""")
            (t / 'res/listmodems.sh').write_text('#!/bin/sh\necho \'[{"path":"1-1","tty":[],"wdm":["/dev/cdc-wdm0"]}]\'\n')
            (t / 'res/listmodems.sh').chmod(0o755)
            (t / 'bin/uci').write_text('#!/bin/sh\ncase "$*" in\n\t*active_modem) echo 1-1 ;;\n\t*m_1_1.vidpid) echo 19d2:1485 ;;\n'
                                       '\t"-q set"*gps_on=1) touch "$GPS_TMP/want" ;;\n\t"-q delete"*gps_on) rm -f "$GPS_TMP/want" ;;\n'
                                       '\t*gps_on) [ -f "$GPS_TMP/want" ] && echo 1 ;;\nesac\n')
            (t / 'bin/uci').chmod(0o755)
            (t / 'bin/ubus').write_text('#!/bin/sh\nexit 1\n'); (t / 'bin/ubus').chmod(0o755)
            env = dict(stub_bin(t), GPS_RES=str(t / 'res'), GPS_TMP=str(t / 'tmp'))
            run = lambda *a: json.loads(shell(f'sh {GPS} ' + ' '.join(a), env=env).stdout)
            j = run('status')
            self.assertEqual((j['supported'], j['family'], j['source'], j['state'], j['reboot']), (1, 'qualcomm', 'qmi', 'off', 0))
            self.assertEqual(run('on')['ok'], 1)
            self.assertEqual((t / 'tmp/gnss_qcid_m_1_1').read_text().strip(), '5')
            (t / 'tmp/gnss_last_m_1_1.json').unlink(missing_ok=True)
            j = run('status')
            self.assertEqual((j['state'], j['fix'], j['lat']), ('on', 2, 55.0))
            self.assertEqual(run('off')['ok'], 1)
            self.assertFalse((t / 'tmp/gnss_qcid_m_1_1').exists())
            q = (t / 'tmp/q').read_text()
            self.assertIn('--client-cid=5 --client-no-release-cid --loc-get-position-report', q)
            self.assertIn('--client-cid=5 --loc-stop', q)          # released together with the session

    def test_quectel_position(self):
        r, sent = self.run_gps('2c7c:0800', {
            'AT+QGPS?': '+QGPS: 1',
            'AT+QGPSLOC=2': '+QGPSLOC: 093357.000,55.75222,37.61556,1.2,180.3,3,84.40,41.5,22.4,141126,08'}, 'status')
        j = json.loads(r.stdout)
        self.assertEqual((j['supported'], j['family'], j['state'], j['source']), (1, 'quectel', 'on', 'at'))
        self.assertEqual((j['lat'], j['lon'], j['fix'], j['sats']), (55.75222, 37.61556, 3, 8))
        self.assertEqual(j['modes'], 'cold warm hot')

    def test_receiver_off_asks_no_position(self):
        r, sent = self.run_gps('1e0e:9001', {'AT+CGPS?': '+CGPS: 0,1'}, 'status')
        j = json.loads(r.stdout)
        self.assertEqual((j['state'], j['fix'], j['lat']), ('off', None, None))
        self.assertNotIn('AT+CGPSINFO', sent)

    def test_unknown_vendor_sends_nothing(self):
        r, sent = self.run_gps('19d2:1485', {}, 'status')
        self.assertEqual(json.loads(r.stdout)['supported'], 0)
        self.assertEqual(sent, [])

    def test_dell_ids_split_between_foxconn_and_sierra(self):
        r, sent = self.run_gps('413c:81d7', {'AT+GPS?': 'GPS is Disable'}, 'caps')
        j = json.loads(r.stdout)
        self.assertEqual((j['family'], j['reboot']), ('foxconn', 1))
        r, sent = self.run_gps('413c:81b6', {'AT!GPSSTATUS?': 'Current time: 2026 11 14'}, 'caps')
        self.assertEqual(json.loads(r.stdout)['family'], 'sierra')

    def test_fm350_receiver_switched_back_on(self):
        # field report: FM350 drops the GNSS power by itself; the receiver was switched on here
        ans = {'AT+GTGPSPOWER?': '+GTGPSPOWER: 0', 'AT+GTGPSSWITCH?': '+GTGPSSWITCH: 1', 'AT+GTGPSPOWER=1': 'OK'}
        r, sent = self.run_gps('0e8d:7127', ans, 'status', uci='\t*gps_on) echo 1 ;;\n')
        self.assertEqual(json.loads(r.stdout)['state'], 'on', r.stdout)
        self.assertIn('AT+GTGPSPOWER=1', sent)
        # not switched on by the user: left off
        r, sent = self.run_gps('0e8d:7127', ans, 'status')
        self.assertEqual(json.loads(r.stdout)['state'], 'off')
        self.assertNotIn('AT+GTGPSPOWER=1', sent)
        gps = GPS.read_text() if hasattr(GPS, 'read_text') else open(GPS).read()
        self.assertIn('-mmin +0', gps[gps.index('gnss_fmrevive_'):][:400])  # once a minute at most

    def test_foxconn_power_on_accepts_setting_success_without_ok(self):
        # T77W968 answers "Setting success! Module would reboot..." and may restart before "OK"
        ans = {'AT+GPS?': 'AT+GPS? :  GPS is Disable, GPS HW Key pull up',
               'AT+GPS=1': ('AT+GPS:   Setting success! Module would reboot for setting GPS enable.',)}
        r, sent = self.run_gps('413c:81d7', ans, 'on')
        self.assertEqual(json.loads(r.stdout)['ok'], 1, r.stdout)
        self.assertIn('AT+GPS=1', sent)

    def test_quectel_outport_opened_on_power_on(self):
        ans = {'AT+QGPS?': '+QGPS: 0', 'AT+QGPSCFG="outport"': '+QGPSCFG: "outport","none"',
               'AT+QGPSCFG="outport","usbnmea"': '', 'AT+QGPS=1': ''}
        r, sent = self.run_gps('2c7c:0800', ans, 'caps')
        self.assertEqual(json.loads(r.stdout)['outport'], 'none')
        r, sent = self.run_gps('2c7c:0800', ans, 'on')
        self.assertEqual(json.loads(r.stdout)['ok'], 1)
        self.assertEqual(sent[-2:], ['AT+QGPSCFG="outport","usbnmea"', 'AT+QGPS=1'])
        # already routed: the stored setting is left alone
        ans['AT+QGPSCFG="outport"'] = '+QGPSCFG: "outport","uartdebug"'
        r, sent = self.run_gps('2c7c:0800', ans, 'on')
        self.assertNotIn('AT+QGPSCFG="outport","usbnmea"', sent)

    def test_huawei_wpdgp(self):
        ans = {'AT^WPDOM?': '^WPDOM: 0', 'AT^WPINFO?': '^WPINFO: 0', 'AT^WPDST=1': '',
               'AT^WPDFR=65535,1': '', 'AT^WPDGP': '', 'AT^WPEND': ''}
        r, sent = self.run_gps('12d1:15c1', ans, 'caps')
        j = json.loads(r.stdout)
        self.assertEqual((j['supported'], j['family'], j['modes']), (1, 'huawei', ''))
        r, sent = self.run_gps('12d1:15c1', ans, 'on')
        self.assertEqual(json.loads(r.stdout)['ok'], 1)
        self.assertEqual(sent[-3:], ['AT^WPDST=1', 'AT^WPDFR=65535,1', 'AT^WPDGP'])
        r, sent = self.run_gps('12d1:15c1', ans, 'off')
        self.assertEqual((json.loads(r.stdout)['ok'], sent[-1]), (1, 'AT^WPEND'))
        # a 12d1 stick without the GPS interface: the probe decides
        r, sent = self.run_gps('12d1:1506', {}, 'caps')
        self.assertEqual(json.loads(r.stdout)['supported'], 0)

    def test_hilink_is_skipped(self):
        r, sent = self.run_gps('12d1:14db', {'AT^WPDOM?': '^WPDOM: 0'}, 'status', uci='\t*m_1_1.kind) echo hilink ;;\n')
        j = json.loads(r.stdout)
        self.assertEqual((j['supported'], j['source']), (0, ''))
        self.assertEqual(sent, [])

    @staticmethod
    def ublox_sysfs(pid):
        def make(root):
            dev = root / 'bus/usb/devices'
            (dev / '1-2/1-2:1.0/tty/ttyACM0').mkdir(parents=True)
            (dev / '1-2/idVendor').write_text('1546\n')
            (dev / '1-2/idProduct').write_text(pid + '\n')
            (dev / '1-2:1.0').symlink_to('1-2/1-2:1.0')
        return make

    def test_usb_ublox_found_when_modem_has_none(self):
        r, sent = self.run_gps('19d2:1485', {}, 'status', sysfs=self.ublox_sysfs('01a7'))
        j = json.loads(r.stdout)
        self.assertEqual((j['supported'], j['family'], j['source'], j['port'], j['modes']),
                         (1, 'ublox', 'usbgps', '/dev/ttyACM0', ''))
        # a u-blox cellular module (LISA-U2, 1546:1102) is not a GNSS receiver
        r, sent = self.run_gps('19d2:1485', {}, 'status', sysfs=self.ublox_sysfs('1102'))
        self.assertEqual(json.loads(r.stdout)['supported'], 0)
        # the modem's own receiver stays the source when it has one
        r, sent = self.run_gps('2c7c:0800', {'AT+QGPS?': '+QGPS: 1'}, 'status', sysfs=self.ublox_sysfs('01a7'))
        self.assertEqual(json.loads(r.stdout)['source'], 'at')

    def test_explicit_gps_port_wins(self):
        # /dev/null stands in for the tty (a character device; is_devpath is stubbed)
        r, sent = self.run_gps('2c7c:0800', {'AT+QGPS?': '+QGPS: 1'}, 'status',
                               uci='\t*gps_port) echo /dev/null ;;\n')
        j = json.loads(r.stdout)
        self.assertEqual((j['supported'], j['family'], j['source'], j['port']), (1, 'uart', 'usbgps', '/dev/null'))
        self.assertEqual(sent, [])                                          # the modem is not asked

    def test_modemmanager_location(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            (t / 'res').mkdir(); (t / 'bin').mkdir()
            (t / 'res/lib.sh').write_text('secname() { echo m_1_1; }\nis_devpath() { return 0; }\n'
                                          'mm_owns_path() { return 0; }\n'
                                          'at_query() { echo "$2" >> "$GPS_TMP/sent"; echo ERROR; }\n')
            (t / 'res/modemswitch.sh').write_text('#!/bin/sh\n[ "$1" = mmindex ] && cat "$GPS_TMP/../mmidx"\n')
            (t / 'res/modemswitch.sh').chmod(0o755)
            (t / 'mmidx').write_text('3\n')
            (t / 'status_off').write_text(mm_location_status(['3gpp-lac-ci', 'gps-raw', 'gps-nmea'], ['3gpp-lac-ci']))
            (t / 'status_on').write_text(mm_location_status(['3gpp-lac-ci', 'gps-raw', 'gps-nmea'], ['3gpp-lac-ci', 'gps-raw', 'gps-nmea']))
            (t / 'get').write_text(mm_location_get(NMEA_FIX, '55.752220', '37.615560', '152.400000', '093357.00'))
            (t / 'bin/mmcli').write_text(f'''#!/bin/sh
T={t}
echo "$*" >> "$T/mm"
case "$*" in
	*"-m 3 "*) ;;
	*) echo "error: couldn't find modem" >&2; exit 1 ;;
esac
case "$*" in
	*--location-status*) [ -f "$T/on" ] && cat "$T/status_on" || cat "$T/status_off" ;;
	*--location-enable-gps-nmea*) touch "$T/on"; echo 'successfully setup location gathering' ;;
	*--location-disable-gps-nmea*) rm -f "$T/on"; echo 'successfully setup location gathering' ;;
	*--location-get*) cat "$T/get" ;;
esac
''')
            (t / 'bin/mmcli').chmod(0o755)
            (t / 'bin/uci').write_text('#!/bin/sh\ncase "$*" in\n\t*active_modem) echo 1-1 ;;\n\t*m_1_1.vidpid) echo 2c7c:0800 ;;\n'
                                       '\t*m_1_1.at_port) echo /dev/ttyUSB2 ;;\n\t*m_1_1.network) echo wwan ;;\n'
                                       '\t*network.wwan.proto) echo modemmanager ;;\n'
                                       '\t"-q set"*gps_on=1) touch "$GPS_TMP/want" ;;\n\t"-q delete"*gps_on) rm -f "$GPS_TMP/want" ;;\n'
                                       '\t*gps_on) [ -f "$GPS_TMP/want" ] && echo 1 ;;\nesac\n')
            (t / 'bin/uci').chmod(0o755)
            (t / 'bin/ubus').write_text('#!/bin/sh\nexit 1\n'); (t / 'bin/ubus').chmod(0o755)
            env = dict(stub_bin(t), GPS_RES=str(t / 'res'), GPS_TMP=str(t / 'tmp'), GPS_SYS=str(t / 'sys'))
            last = t / 'tmp/gnss_last_m_1_1.json'
            run = lambda *a: json.loads(shell(f'sh {GPS} ' + ' '.join(a), env=env).stdout)
            j = run('status')
            self.assertEqual((j['supported'], j['family'], j['source'], j['state'], j['modes'], j['fix']),
                             (1, 'quectel', 'mm', 'off', '', None))
            self.assertEqual(run('on')['ok'], 1)
            self.assertTrue((t / 'tmp/want').exists())
            j = run('status')
            self.assertEqual((j['state'], j['fix'], j['lat'], j['lon'], j['speed'], j['sats']), ('on', 3, 55.75222, 37.61556, 41.5, 9))
            # MM restarted: the setup is gone and the index changed; the stored choice enables it again
            (t / 'on').unlink(); (t / 'mmidx').write_text('4\n'); last.unlink()
            (t / 'bin/mmcli').write_text((t / 'bin/mmcli').read_text().replace('-m 3 ', '-m 4 '))
            j = run('status')
            self.assertEqual((j['source'], j['state'], j['fix']), ('mm', 'on', 3))
            self.assertEqual(run('off')['ok'], 1)
            self.assertFalse((t / 'on').exists())
            mm = (t / 'mm').read_text()
            for a in ('--timeout=15 -m 3 -J --location-status', '-m 3 --location-enable-gps-nmea --location-enable-gps-raw',
                      '-m 3 -J --location-get', '-m 4 --location-enable-gps-nmea', '-m 4 --location-disable-gps-nmea --location-disable-gps-raw'):
                self.assertIn(a, mm)
            self.assertFalse((t / 'tmp/sent').exists())                    # no AT on a port MM holds

    def test_quectel_cold_start_order(self):
        r, sent = self.run_gps('2c7c:0800', {'AT+QGPS?': '+QGPS: 1', 'AT+QGPSEND': '',
                                             'AT+QGPSDEL=0': '', 'AT+QGPS=1': ''}, 'start', 'cold')
        self.assertEqual(json.loads(r.stdout)['ok'], 1)
        self.assertEqual(sent[-3:], ['AT+QGPSEND', 'AT+QGPSDEL=0', 'AT+QGPS=1'])


class AndroidPhone(unittest.TestCase):
    # CellProbe gnss output from a phone (android-cells.dex), coordinates synthetic
    def run_parse(self, payload):
        with tempfile.TemporaryDirectory() as t:
            env = stub_bin(Path(t))
            r = shell(f"sh {GPS} parse-android <<'EOF'\n{json.dumps(payload)}\nEOF\n", env=env)
            return dict(l.split('=', 1) for l in r.stdout.split('\n') if '=' in l)

    def test_fresh_fix(self):
        d = self.run_parse({'fix': {'lat': 55.7522, 'lon': 37.6156, 'alt': 340.0, 'msl_alt': 320.55, 'speed_ms': 2.5,
                                    'bearing': 116.0, 'accuracy_m': 7.9, 'time_ms': 1794714031091, 'age_s': 0},
                            'last': {}, 'inview': 49, 'used': 16})
        self.assertEqual((d['fix'], d['lat'], d['lon'], d['alt'], d['speed'], d['course']),
                         ('3', '55.752200', '37.615600', '320.6', '9.0', '116.0'))
        self.assertEqual((d['sats'], d['inview'], d['utcms']), ('16', '49', '1794714031091'))

    def test_stale_last_fix_is_not_a_position(self):
        d = self.run_parse({'fix': {}, 'last': {'lat': 55.7, 'lon': 37.6, 'age_s': 492}})
        self.assertEqual(d.get('fix'), '0'); self.assertNotIn('lat', d)
        d = self.run_parse({'fix': {}, 'last': {'lat': 55.7, 'lon': 37.6, 'age_s': 12}})
        self.assertEqual((d['fix'], d['lat']), ('2', '55.700000'))

    def test_whitelist_keeps_other_packages(self):
        src = (SHARE / 'gps.sh').read_text()
        self.assertIn('location_background_throttle_package_whitelist', src)
        self.assertIn('$0 != "com.android.shell"', src)
        self.assertIn('settings delete global $_aw_k', src)


class Wiring(unittest.TestCase):
    def test_tab_menu_acl_settings(self):
        menu = json.loads((ROOT / 'root/usr/share/luci/menu.d/luci-app-5gmodem.json').read_text())
        self.assertEqual(menu['admin/modem/5gmodem/gps']['action']['path'], 'modem5g/gps')
        acl = (ROOT / 'root/usr/share/rpcd/acl.d/luci-app-5gmodem.json').read_text()
        self.assertEqual(acl.count('"/usr/share/5gmodem/gps.sh": [ "exec" ]'), 2)
        tabs = (ROOT / 'htdocs/luci-static/resources/view/modem5g/modemtabs.js').read_text()
        self.assertIn("'align', 'gps', 'sms'", tabs)                  # hidden with "netonly"
        self.assertIn("gateHideRule('gpsopt-tab-hide', 'gps', gp === '0');", tabs)
        self.assertIn('applyGpsTabVisibility();', tabs)
        # Settings keeps only the tab switch and the telemetry opt-in; the map style is picked
        # under the map and the rest of the GPS options sit on the GPS tab itself
        st = (ROOT / 'htdocs/luci-static/resources/view/modem5g/5gsettings.js').read_text()
        for opt in ("'show_gps'", "'publish_gps'"):
            self.assertIn(opt, st)
        gp = (ROOT / 'htdocs/luci-static/resources/view/modem5g/gps.js').read_text()
        for opt in ("'gps_tiles'", "'gps_map_auto'", "collapsibleSection('gpsset'"):
            self.assertIn(opt, gp)

    def test_leaflet_does_not_replace_luci(self):
        js = (ROOT / 'htdocs/luci-static/resources/view/modem5g/gps.js').read_text()
        self.assertIn("new Function('exports', 'module', src", js)
        self.assertIn('exp.noConflict()', js)
        self.assertIn('window.L = luci;', js)
        lf = (ROOT / 'htdocs/luci-static/resources/5gmodem/leaflet.js').read_text()
        self.assertIn('Leaflet 1.9.4', lf[:300])
        self.assertTrue((SHARE / 'licenses/Leaflet-BSD-2.txt').exists())

    def test_telemetry_position_is_opt_in(self):
        tele = (SHARE / 'telemetry.sh').read_text()
        self.assertIn('if [ "$(_g publish_gps)" = "1" ] && [ -x /usr/share/5gmodem/gps.sh ]; then', tele)
        self.assertIn('_disc gps_lat', tele)
        doc = (ROOT.parent / 'docs/telemetry.md').read_text()
        self.assertIn('`gps_fix`', doc)


if __name__ == '__main__':
    unittest.main()
