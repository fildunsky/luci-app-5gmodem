#!/usr/bin/env python3
# Services fed by the modem GNSS receiver (gpsfeed.sh): the clock from GNSS without NTP, the
# position to a Traccar server (OsmAnd protocol), and NMEA over TCP for gpsd or a car head unit.
# Every one is opt-in; with all of them off the sessionwatch tick must not touch the modem.
import calendar
import functools
import os
import tempfile
import time
import unittest
from pathlib import Path

from test_runtime_audit import ROOT, SHARE, shell

FEED = SHARE / 'gpsfeed.sh'
FIX = ('{"supported":1,"family":"quectel","state":"on","source":"at","port":"","modes":"","reboot":0,'
       '"fix":3,"lat":55.75222,"lon":37.61556,"alt":152.4,"speed":41.5,"course":84.4,"sats":9,'
       '"inview":null,"hdop":0.98,"utc":"2026-11-14T09:33:57Z","ts":%d}')


def run(args, stdin=''):
    # CR made visible: text-mode pipes would turn CRLF into LF
    return shell(f"sh {FEED} {args} <<'EOF' | tr '\\r' '~'\n{stdin}\nEOF\n")


def nmea_ok(line):
    body, cs = line[1:].split('*')
    return line[0] == '$' and '%02X' % functools.reduce(lambda a, c: a ^ ord(c), body, 0) == cs


class Generators(unittest.TestCase):
    def test_gga_rmc_with_fix(self):
        r = run('nmea', FIX % 0)
        self.assertEqual(r.stderr, '')
        self.assertTrue(r.stdout.endswith('~\n'))
        gga, rmc = r.stdout.split('~\n')[:2]
        self.assertTrue(nmea_ok(gga) and nmea_ok(rmc), r.stdout)
        self.assertEqual(gga.split('*')[0], '$GPGGA,093357.00,5545.13320,N,03736.93360,E,1,09,1.0,152.4,M,,M,,')
        f = rmc.split('*')[0].split(',')
        self.assertEqual(f[2], 'A')
        self.assertEqual(f[7], '22.4')            # 41.5 km/h in knots
        self.assertEqual(f[9], '141126')
        self.assertEqual(len(f), 13)

    def test_no_fix_and_southwest(self):
        r = run('nmea 2026-01-02T03:04:05Z', '{"fix":0,"lat":null,"lon":null,"utc":""}')
        gga, rmc = r.stdout.split('~\n')[:2]
        self.assertTrue(nmea_ok(gga) and nmea_ok(rmc))
        self.assertEqual(gga.split('*')[0], '$GPGGA,030405.00,,,,,0,,,,M,,M,,')
        self.assertEqual(rmc.split(',')[2], 'V')
        r = run('nmea 2026-01-02T03:04:05Z', '{"fix":2,"lat":-33.85,"lon":-151.2}')
        gga = r.stdout.split('~\n')[0]
        self.assertIn(',3351.00000,S,15112.00000,W,1,', gga)
        # minutes that round to 60 carry into the degrees
        r = run('nmea 2026-01-02T03:04:05Z', '{"fix":2,"lat":59.99999999,"lon":0.00000001}')
        self.assertIn(',6000.00000,N,00000.00000,E,', r.stdout)

    def test_osmand_query(self):
        r = run('osmand car-1 1', FIX % 0)
        self.assertEqual(r.returncode, 0)
        q = dict(p.split('=') for p in r.stdout.strip().split('&'))
        self.assertEqual(q['id'], 'car-1')
        self.assertEqual(q['timestamp'], str(calendar.timegm((2026, 11, 14, 9, 33, 57))))
        self.assertEqual((q['lat'], q['lon'], q['speed'], q['bearing']), ('55.75222', '37.61556', '22.4', '84.4'))
        self.assertEqual((q['altitude'], q['hdop'], q['sat']), ('152.4', '0.98', '9'))
        r = shell(f"echo '{{\"fix\":0,\"lat\":null}}' | sh {FEED} osmand car-1 1")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(r.stdout, '')
        r = run('osmand car-1 1700000000', '{"fix":2,"lat":1.5,"lon":2.5,"utc":""}')
        self.assertIn('timestamp=1700000000', r.stdout)

    def test_epoch_both_ways(self):
        for t in ((2024, 2, 29, 23, 59, 59), (2026, 11, 14, 9, 33, 57), (2000, 3, 1, 0, 0, 0), (2099, 12, 31, 12, 0, 1)):
            e = calendar.timegm(t + (0, 0, 0))
            u = '%04d-%02d-%02dT%02d:%02d:%02dZ' % t
            self.assertEqual(shell(f'sh {FEED} utc-epoch {u}').stdout.strip(), str(e))
            self.assertEqual(shell(f'sh {FEED} epoch-utc {e}').stdout.strip(), u[:-1].replace('T', ' '))
        self.assertEqual(shell(f'sh {FEED} utc-epoch 2026-11-14').stdout.strip(), '')

    def test_url_and_id_validation(self):
        for u in ('http://192.168.1.10:5055', 'https://traccar.example.org', 'http://h.example/osmand/', 'http://[fd00::1]:5055'):
            self.assertEqual(shell(f"sh {FEED} url-ok '{u}'").returncode, 0, u)
        for u in ('ftp://h', 'http://h/?id=1', 'http://h;reboot', "http://h'x", 'http://h:5055 x', 'http://', 'h:5055'):
            self.assertNotEqual(shell(f"sh {FEED} url-ok \"{u}\"").returncode, 0, u)
        self.assertEqual(shell(f'sh {FEED} id-ok 4242').returncode, 0)
        for i in ('', 'a b', 'a&b=1', 'x' * 65):
            self.assertNotEqual(shell(f"sh {FEED} id-ok '{i}'").returncode, 0, i)


class Tick(unittest.TestCase):
    def tick(self, cfg, status='', ntp=None, now=None, keep=None):
        t = keep or Path(tempfile.mkdtemp())
        for d in ('res', 'bin', 'tmp'):
            (t / d).mkdir(exist_ok=True)
        stubs = {
            'res/gps.sh': f'echo call >> "{t}/gpscalls"\nprintf \'%s\\n\' \'{status}\'',
            'bin/uci': 'printf "%s\\n" "$FAKE_UCI"',
            'bin/logger': f'echo "$*" >> "{t}/log"',
            'bin/curl': f'echo "$@" >> "{t}/curl"',
            'bin/init': f'echo "$1" >> "{t}/init"',
            'bin/date': f'case "$*" in "+%s") echo "$FAKE_NOW" ;; "-u -s "*) echo "$3" >> "{t}/dateset" ;; *) /bin/date "$@" ;; esac',
        }
        for p, body in stubs.items():
            (t / p).write_text('#!/bin/sh\n' + body + '\n')
            (t / p).chmod(0o755)
        if ntp is not None:
            (t / 'tmp/ntp_state').write_text(ntp + '\n')
        uci = '\n'.join(f"5gmodem.cfg01.{k}='{v}'" for k, v in cfg.items())
        env = dict(os.environ, GPSFEED_RES=str(t / 'res'), GPSFEED_TMP=str(t / 'tmp'), GPSFEED_INIT=str(t / 'bin/init'),
                   FAKE_UCI=uci, FAKE_NOW=str(now or int(time.time())), PATH=f"{t / 'bin'}:{os.environ['PATH']}")
        # /bin/sh, not the busybox one: busybox prefers its own date and logger applets to the stubs
        r = shell(f'/bin/sh {FEED} tick', env=env)
        self.assertEqual(r.returncode, 0, r.stderr)
        read = lambda n: (t / n).read_text().split('\n')[:-1] if (t / n).exists() else []
        return t, {n: read(n) for n in ('gpscalls', 'log', 'curl', 'init', 'dateset')}

    def test_all_off_costs_nothing(self):
        t, o = self.tick({'show_gps': '1', 'gps_map_auto': '0'}, FIX % 0)
        self.assertEqual(o, {'gpscalls': [], 'log': [], 'curl': [], 'init': [], 'dateset': []})
        self.assertEqual(list((t / 'tmp').iterdir()), [])
        # gps_time=0 is "off" as well
        t, o = self.tick({'gps_time': '0'}, FIX % 0)
        self.assertEqual(o['gpscalls'], [])

    def test_hidden_gps_or_netonly_turns_everything_off(self):
        for extra in ({'show_gps': '0'}, {'netonly': '1'}):
            cfg = dict(gps_time='1', gps_traccar_url='http://192.168.1.10:5055', gps_traccar_id='car', **extra)
            t, o = self.tick(cfg, FIX % 0)
            self.assertEqual((o['gpscalls'], o['curl'], o['dateset']), ([], [], []), extra)

    def test_clock_from_gnss_without_ntp(self):
        gnss = calendar.timegm((2026, 11, 14, 9, 33, 57))
        st = FIX % (gnss - 3600)          # the status was produced when the clock said 08:33:57
        t, o = self.tick({'gps_time': '1'}, st, now=gnss - 3600)
        self.assertEqual(o['dateset'], ['2026-11-14 09:33:57'])
        self.assertEqual(len(o['log']), 1)
        self.assertIn('clock set from GNSS', o['log'][0])
        # set once: the next tick within 10 minutes does not even ask the receiver
        t, o = self.tick({'gps_time': '1'}, st, now=gnss - 3600, keep=t)
        self.assertEqual((o['gpscalls'], o['dateset']), (['call'], ['2026-11-14 09:33:57']))

    def test_cache_age_is_added(self):
        gnss = calendar.timegm((2026, 11, 14, 9, 33, 57))
        t, o = self.tick({'gps_time': '1'}, FIX % (gnss - 100), now=gnss - 98)
        self.assertEqual(o['dateset'], ['2026-11-14 09:33:59'])

    def test_ntp_sync_wins(self):
        gnss = calendar.timegm((2026, 11, 14, 9, 33, 57))
        t, o = self.tick({'gps_time': '1'}, FIX % 0, ntp='periodic 2 120', now=gnss - 3600)
        self.assertEqual((o['gpscalls'], o['dateset']), ([], []))
        # stratum 16 or "unsync" is no sync
        t, o = self.tick({'gps_time': '1'}, FIX % (gnss - 3600), ntp='unsync 2 120', now=gnss - 3600)
        self.assertEqual(o['dateset'], ['2026-11-14 09:33:57'])
        t, o = self.tick({'gps_time': '1'}, FIX % (gnss - 3600), ntp='stratum 16 120', now=gnss - 3600)
        self.assertEqual(o['dateset'], ['2026-11-14 09:33:57'])

    def test_bad_gnss_time_is_ignored(self):
        gnss = calendar.timegm((2026, 11, 14, 9, 33, 57))
        # a receiver after a GPS week rollover: 1024 weeks back
        old = (FIX % gnss).replace('2026-11-14', '2007-03-31')
        t, o = self.tick({'gps_time': '1'}, old, now=gnss)
        self.assertEqual(o['dateset'], [])
        # no fix: no clock either
        t, o = self.tick({'gps_time': '1'}, (FIX % gnss).replace('"fix":3', '"fix":0'), now=gnss - 3600)
        self.assertEqual(o['dateset'], [])
        # a clock that is right already is left alone
        t, o = self.tick({'gps_time': '1'}, FIX % gnss, now=gnss + 2)
        self.assertEqual(o['dateset'], [])

    def test_traccar_send_and_interval(self):
        cfg = {'gps_traccar_url': 'http://192.168.1.10:5055', 'gps_traccar_id': 'tracker-42', 'gps_traccar_interval': '60'}
        t, o = self.tick(cfg, FIX % 0)
        self.assertEqual(len(o['curl']), 1)
        url = o['curl'][0].split()[-1]
        self.assertTrue(url.startswith('http://192.168.1.10:5055/?id=tracker-42&lat=55.75222&lon=37.61556&timestamp='), url)
        self.assertIn('&speed=22.4&bearing=84.4', url)
        self.assertIn('--connect-timeout', o['curl'][0])
        t, o = self.tick(cfg, FIX % 0, keep=t)
        self.assertEqual(len(o['curl']), 1)       # not again before the interval
        # a path on the server keeps its own slash
        t, o = self.tick(dict(cfg, gps_traccar_url='https://h.example/osmand'), FIX % 0)
        self.assertTrue(o['curl'][0].split()[-1].startswith('https://h.example/osmand?id='))

    def test_traccar_no_fix_or_bad_settings(self):
        cfg = {'gps_traccar_url': 'http://192.168.1.10:5055', 'gps_traccar_id': 'car'}
        t, o = self.tick(cfg, (FIX % 0).replace('"fix":3', '"fix":0'))
        self.assertEqual(o['curl'], [])
        t, o = self.tick(dict(cfg, gps_traccar_id='a&b'), FIX % 0)
        self.assertEqual((o['curl'], o['gpscalls'], len(o['log'])), ([], [], 1))
        t, o = self.tick(dict(cfg, gps_traccar_id='a&b'), FIX % 0, keep=t)
        self.assertEqual(len(o['log']), 1)        # said once, not every tick

    def test_one_receiver_query_per_tick(self):
        gnss = calendar.timegm((2026, 11, 14, 9, 33, 57))
        cfg = {'gps_time': '1', 'gps_traccar_url': 'http://192.168.1.10:5055', 'gps_traccar_id': 'car'}
        t, o = self.tick(cfg, FIX % (gnss - 3600), now=gnss - 3600)
        self.assertEqual((len(o['gpscalls']), len(o['curl']), len(o['dateset'])), (1, 1, 1))

    def test_nmea_server_follows_the_port(self):
        t, o = self.tick({'gps_nmea_port': '1'})
        self.assertEqual(o['init'], ['restart'])
        self.assertEqual(o['gpscalls'], [])
        t, o = self.tick({'gps_nmea_port': '1'}, keep=t)
        self.assertEqual(o['init'], ['restart'])   # retried after 5 minutes, not every tick
        t, o = self.tick({}, keep=t)
        self.assertEqual(o['init'], ['restart', 'stop'])
        t, o = self.tick({}, keep=t)
        self.assertEqual(o['init'], ['restart', 'stop'])


class Wiring(unittest.TestCase):
    def test_loop_init_settings_docs(self):
        sw = (SHARE / 'sessionwatch.sh').read_text()
        self.assertIn('"$RES/telemetry.sh" tick >/dev/null 2>&1\n\t\t\t"$RES/gpsfeed.sh" tick >/dev/null 2>&1', sw)
        init = ROOT / 'root/etc/init.d/5gmodem-gpsfeed'
        self.assertTrue(os.access(init, os.X_OK))
        self.assertIn('gpsfeed.sh nmea-ready || return 0', init.read_text())
        self.assertIn('5gmodem-gpsfeed', (ROOT / 'Makefile').read_text())
        self.assertIn('_pb_svc 5gmodem-gpsfeed restart', (SHARE / 'postinst-bg.sh').read_text())
        hp = (ROOT / 'root/etc/hotplug.d/ntp/30-5gmodem-ntp').read_text()
        self.assertIn('/tmp/5gmodem/ntp_state', hp)
        # these options are edited on the GPS tab (its Settings block), not on the Settings page
        st = (ROOT / 'htdocs/luci-static/resources/view/modem5g/gps.js').read_text()
        for opt in ('gps_time', 'gps_traccar_url', 'gps_traccar_id', 'gps_traccar_interval', 'gps_nmea_port'):
            self.assertIn(f"'{opt}'", st)
        self.assertIn('subsystems/gps-feed.md', (ROOT.parent / 'docs/README.md').read_text())

    def test_ntp_hotplug_records_the_state(self):
        hp = ROOT / 'root/etc/hotplug.d/ntp/30-5gmodem-ntp'
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / 'hp').write_text(hp.read_text().replace('/tmp/5gmodem', t))
            r = shell(f"ACTION=stratum stratum=3 sh {t}/hp")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((Path(t) / 'ntp_state').read_text().startswith('stratum 3 '))


if __name__ == '__main__':
    unittest.main()
