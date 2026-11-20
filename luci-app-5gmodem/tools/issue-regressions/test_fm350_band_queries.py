import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, shell


class Fm350BandQueries(unittest.TestCase):
    def run_profile(self, body, scenario):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            commands = temp / 'commands'
            profiles = SHARE / 'modemband'
            for name in ('0e8d7127', '_fibocom_fm350_common'):
                (temp / name).write_text(
                    (profiles / name).read_text().replace('/tmp/5gmodem/', str(temp) + '/'),
                )
            result = shell(r'''
sms_tool() { echo "unbounded sms_tool: $*" >&2; return 1; }
logger() { :; }
at_query() {
    [ "$1" = /dev/ttyUSB3 ] || return 1
    printf '%s\n' "$2" >> "$COMMANDS"
    case "$2" in
        *\?) [ -z "$AT_QUERY_RAW" ] || return 1 ;;
        *) [ "$AT_QUERY_RAW" = 1 ] || return 1 ;;
    esac
    case "$2" in
        'AT+GTACT?')
            if [ ! -f "$WRITTEN" ]; then
                echo '+GTACT: 20,6,3,101'
            elif [ "$SCENARIO" != stalled ]; then
                echo '+GTACT: 20,6,3,103'
            fi ;;
        'AT+GTACT=20,6,3,103')
            if [ "$SCENARIO" = fallback ]; then
                printf 'ERROR\r\n'
            else
                : > "$WRITTEN"
                printf 'OK\r\n'
            fi ;;
        'AT+GTACT=,,,103')
            : > "$WRITTEN"
            printf 'OK\r\n' ;;
        'AT+GTACT=2'|'AT+GTACT=20,6,3,0')
            printf '%s\r\n' "$2"
            case "$SCENARIO" in
                rejected) printf 'OK\r\n+CME ERROR: 100\r\n' ;;
                timeout) : ;;
                acknowledged) printf ' OK \r\n\r\n \r\n' ;;
            esac ;;
    esac
    return 0
}
. "$RES/0e8d7127"
_DEVICE=/dev/ttyUSB3
''' + body, dict(
                os.environ, RES=str(temp), SCENARIO=scenario, AT_QUERY_RAW='',
                COMMANDS=str(commands), WRITTEN=str(temp / 'written'),
            ))
            return result, commands.read_text().splitlines()

    def test_band_read_uses_bounded_at_transport(self):
        result, commands = self.run_profile('getbands\n', 'read')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), '1')
        self.assertEqual(commands, ['AT+GTACT?'])

    def test_band_write_reports_success_after_readback(self):
        result, commands = self.run_profile(
            "_fm350_gtact_set 103 '^1[0-9][0-9]$' 6p\n", 'changed',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ['AT+GTACT?', 'AT+GTACT=20,6,3,103', 'AT+GTACT?'])

    def test_band_write_retries_after_rejected_first_form(self):
        result, commands = self.run_profile(
            "_fm350_gtact_set 103 '^1[0-9][0-9]$' 6p\n", 'fallback',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, [
            'AT+GTACT?', 'AT+GTACT=20,6,3,103', 'AT+GTACT?',
            'AT+GTACT=,,,103', 'AT+GTACT?',
        ])

    def test_setmode_requires_terminal_ok(self):
        for scenario, status in [('rejected', 1), ('timeout', 1), ('acknowledged', 0)]:
            with self.subTest(scenario=scenario):
                result, commands = self.run_profile('setmode 2\n', scenario)
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(commands, ['AT+GTACT=2'])

    def test_band_reset_without_capabilities_requires_terminal_ok(self):
        for scenario, status in [('rejected', 1), ('acknowledged', 0)]:
            with self.subTest(scenario=scenario):
                result, commands = self.run_profile(
                    "_fm350_gtact_set 0 '^1[0-9][0-9]$' 6p\n", scenario,
                )
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertEqual(commands, ['AT+GTACT?', 'AT+GTACT=?', 'AT+GTACT=20,6,3,0'])

    def test_missing_readback_stops_additional_writes(self):
        result, commands = self.run_profile(
            "_fm350_gtact_set 103 '^1[0-9][0-9]$' 6p\n", 'stalled',
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(commands, ['AT+GTACT?', 'AT+GTACT=20,6,3,103', 'AT+GTACT?'])
