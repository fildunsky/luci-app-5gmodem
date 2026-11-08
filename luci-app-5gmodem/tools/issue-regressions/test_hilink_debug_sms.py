import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


PREFIX = r'''
CFG=5gmodem
active_path() { echo 1-1; }
secname() { echo m_1_1; }
uci() {
 case "$*" in
  *m_1_1.kind) echo "${KIND:-hilink}" ;;
  *m_1_1.vidpid) echo "${VIDPID:-12d1:1566}" ;;
  *m_1_1.at_port) echo "${ATPORT:-/dev/null}" ;;
  *m_1_1.ussd_port) echo "$SELECTED" ;;
  *sms.ussdport) echo /dev/zero ;;
  *sms.readport|*sms.sendport) echo "$SMSPORT" ;;
 esac
}
'''


class HilinkDebugSms(unittest.TestCase):
    def decision(self, **env):
        source = PREFIX + function('hl_sms_web', 'lib.sh') + r'''
hl_web_metrics() { return 1; }
hl_sms_web m_1_1 "$SMSPORT"
'''
        return shell(source, dict(os.environ, **env)).returncode

    def test_huawei_sms_uses_web_with_or_without_debug_port(self):
        for vidpid, port in [('12d1:1566', '/dev/null'), ('12d1:14db', '')]:
            self.assertEqual(self.decision(VIDPID=vidpid, ATPORT=port), 0)

    def test_explicit_web_sms_selection_works_while_at_remains_available(self):
        self.assertEqual(self.decision(VIDPID='19d2:1405', SMSPORT='192.168.8.1'), 0)
        self.assertEqual(self.decision(VIDPID='19d2:1405', SMSPORT='hilink'), 0)

    def test_non_hilink_and_other_debug_transports_keep_at(self):
        self.assertEqual(self.decision(KIND='at', VIDPID='12d1:1566'), 1)
        self.assertEqual(self.decision(VIDPID='19d2:1405', SMSPORT='/dev/null'), 1)

    def test_sms_actions_reach_web_api_with_debug_metrics(self):
        source = (SHARE / 'smsbridge.sh').read_text()
        start = source.index('if [ -z "$PORT" ]; then', source.index('delete-start)'))
        stop = source.index('\n[ -n "$PORT" ] || PORT=', start)
        branch = source[start:stop]
        with tempfile.TemporaryDirectory() as temp:
            worker = Path(temp) / 'hilink.sh'
            worker.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\n')
            worker.chmod(0o755)
            for action, expected in [('recv', 'smsread in 1-1'), ('sent', 'smsread out 1-1'),
                                     ('send', 'smssend 123 hello 1-1'), ('delete', 'smsdel 7 1-1')]:
                program = PREFIX + function('hl_sms_web', 'lib.sh') + r'''
RES="$WORKDIR"; _TGT_SEC=m_1_1; _TGT_PATH=1-1
PORT=""; SND_TO=123; SND_TXT=hello; DEL=7
hl_web_metrics() { return 1; }
_kb_out() { printf '%s\n' "$1"; }
''' + branch + '\necho wrong-at-transport\n'
                result = shell(program, dict(os.environ, WORKDIR=temp, BOX=action, SMSPORT='/dev/null'))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_ussd_override_is_independent_and_bound_to_its_modem(self):
        source = PREFIX + function('_port', 'ussd.sh') + r'''
tty_usbpath() { echo "$OWNER"; }
_port
'''
        for selected, owner, expected in [('/dev/null', '1-1', '/dev/null'),
                                          ('/dev/null', '2-1', '/dev/zero'),
                                          ('/dev/missing', '1-1', '/dev/zero')]:
            result = shell(source, dict(os.environ, SELECTED=selected, OWNER=owner))
            self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_saved_sms_ports_allow_hilink_only_for_hilink_modems(self):
        source = PREFIX + function('is_devpath', 'lib.sh') + '\n' + function('is_smsport', 'lib.sh') + '\nis_smsport "$VALUE"\n'
        for value, kind, expected in [('192.168.8.1', 'hilink', 0), ('hilink', 'hilink', 0),
                                     ('192.168.8.1', 'at', 1), ('999.1.1.1', 'hilink', 1),
                                     ('/dev/ttyUSB0', 'at', 0), ('/dev/ttyUSB0;reboot', 'hilink', 1)]:
            result = shell(source, dict(os.environ, VALUE=value, KIND=kind))
            self.assertEqual(result.returncode, expected, value)
