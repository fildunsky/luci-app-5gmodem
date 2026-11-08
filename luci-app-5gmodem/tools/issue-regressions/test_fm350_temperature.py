import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, shell


class Fm350Temperature(unittest.TestCase):
    def temperature(self, thermal, sensor, previous='', polls=1):
        profile = (SHARE/'modem/usb/0e8d7127').read_text()
        source = profile[profile.index('OT=$(sms_tool -d "$DEVICE" at "AT+ETHERMAL?")'):
                         profile.index('\nTTY=$(basename "$DEVICE")')]
        with tempfile.TemporaryDirectory() as temp:
            source = source.replace('/tmp/5gmodem', temp)
            if previous:
                (Path(temp)/'temp_ttyUSB1').write_text(previous)
            result = shell(r'''
sms_tool() {
 printf '%s\n' "$4" >> "$CALLS"
 case "$4" in
  'AT+ETHERMAL?') printf '%s\n' "$THERMAL" ;;
  'AT+GTSENRDTEMP=1') printf '%s\n' "$SENSOR" ;;
 esac
}
cut() { echo 100; }
DEVICE=/dev/ttyUSB1
IFS='
'
''' + '\n'.join('TEMP="-"\n'+source for _ in range(polls)) + '\nprintf "result:%s\\n" "$TEMP"\n',
                dict(os.environ, THERMAL=thermal, SENSOR=sensor, CALLS=temp+'/calls'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, '')
            return result.stdout.strip(), (Path(temp)/'calls').read_text().splitlines()

    def test_4pda_soc_max_millidegrees(self):
        result, calls = self.temperature('', 'AT+GTSENRDTEMP=1\r\n+GTSENRDTEMP: 1,45485\r\nOK')
        self.assertEqual(result, 'result:45.5 &deg;C')
        self.assertEqual(calls, ['AT+ETHERMAL?', 'AT+GTSENRDTEMP=1'])

    def test_existing_thermal_reading_avoids_fallback(self):
        result, calls = self.temperature('+ETHERMAL: 0,53\r\n+ETHERMAL: 1,57', '+GTSENRDTEMP: 1,45485')
        self.assertEqual(result, 'result:57.0 &deg;C')
        self.assertEqual(calls, ['AT+ETHERMAL?'])

    def test_error_or_invalid_thermal_uses_fallback(self):
        for thermal in ('ERROR', '+ETHERMAL: 0,32767', '+ETHERMAL: 0,-127',
                        '+ETHERMAL: 0,', '+ETHERMAL: 0,garbage'):
            with self.subTest(thermal=thermal):
                self.assertEqual(self.temperature(thermal, '+GTSENRDTEMP: 1,45485')[0],
                                 'result:45.5 &deg;C')

    def test_invalid_sensor_does_not_fabricate_temperature(self):
        for sensor in ('', 'ERROR', '+GTSENRDTEMP: 1,', '+GTSENRDTEMP: 1,garbage',
                       '+GTSENRDTEMP: 2,45485', '+GTSENRDTEMP: 1,32767000',
                       '+GTSENRDTEMP: 1,-127000', '+GTSENRDTEMP: 1,45485,123'):
            with self.subTest(sensor=sensor):
                self.assertEqual(self.temperature('', sensor)[0], 'result:-')

    def test_fallback_keeps_jump_confirmation_filter(self):
        for polls, expected in [(1, '60'), (2, '60'), (3, '30.0')]:
            with self.subTest(polls=polls):
                result, _ = self.temperature('', '+GTSENRDTEMP: 1,30000', '60 0 90', polls)
                self.assertEqual(result, 'result:'+expected+' &deg;C')
