#!/usr/bin/env python3
"""Offline regression checks; no modem, network or router configuration needed."""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = (Path(__file__).resolve().parents[2] / 'root/usr/share/5gmodem/hilink.sh').read_text()
FUNCTIONS = SOURCE[SOURCE.index('_sess_file()'):SOURCE.index('\nnettype_name()')]
SMS = SOURCE[SOURCE.index('sms_list() {'):SOURCE.index('\nsms_send() {')]


class HuaweiTests(unittest.TestCase):
    def test_same_address_sessions_are_modem_specific(self):
        output = self.run_shell(r'''
_srcip_for() { echo "$1"; }
curl() {
    while [ "$#" -gt 0 ]; do
        case "$1" in --interface) src="$2"; shift ;; esac
        shift
    done
    printf '<response><SesInfo>SessionID=%s</SesInfo><TokInfo>token-%s</TokInfo></response>' "$src" "$src"
}
_sess_new 192.168.8.1 usb0 first >/dev/null
_sess_new 192.168.8.1 usb1 second >/dev/null
_sess_get 192.168.8.1 usb0 first
_sess_get 192.168.8.1 usb1 second
''')
        self.assertEqual(output.splitlines(), ['SessionID=first\ttoken-first', 'SessionID=second\ttoken-second'])

    def test_post_lock_recovers_after_killed_owner(self):
        with tempfile.TemporaryDirectory() as cache:
            prefix = 'CACHE_DIR="$1"; UA=test\n' + FUNCTIONS + r'''
_addr_for() { echo 192.168.8.1; }
_netdev_for() { echo usb0; }
_sess_new() { :; }
_hl_post_once() { echo '<response>OK</response>'; }
'''
            blocking = prefix + r'''
_hl_post_once() { touch "$CACHE_DIR/ready"; sleep 10; }
api_post /api/sms/sms-list '' path
'''
            owner = subprocess.Popen(['busybox', 'ash', '-c', blocking, 'test', cache],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     start_new_session=True)
            try:
                deadline = time.monotonic() + 5
                while not (Path(cache) / 'ready').exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((Path(cache) / 'ready').exists())
                command = ['busybox', 'ash', '-c', prefix + "\napi_post /api/sms/sms-list '' path", 'test', cache]
                busy = subprocess.run(command, capture_output=True, text=True, timeout=5)
                self.assertIn('<code>busy</code>', busy.stdout)
                os.killpg(owner.pid, signal.SIGKILL)
                owner.communicate(timeout=5)
                recovered = subprocess.run(command, capture_output=True, text=True, timeout=5)
                self.assertEqual(recovered.stdout, '<response>OK</response>')
                self.assertEqual(recovered.stderr, '')
            finally:
                if owner.poll() is None:
                    os.killpg(owner.pid, signal.SIGKILL)
                    owner.communicate()

    def run_shell(self, body):
        with tempfile.TemporaryDirectory() as cache:
            p = subprocess.run(['busybox', 'ash', '-c',
                'CACHE_DIR="$1"; UA=test\n' + FUNCTIONS + '\n' + body,
                'test', cache], text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stderr)
            return p.stdout

    def parse(self, xml):
        return json.loads(self.run_shell(
            'api_post() { cat <<\'XML\'\n' + xml + '\nXML\n}\n' + SMS + '\nsms_list in'))

    def test_sms_layouts(self):
        msg = '<Message><Smstat>0</Smstat><Index>1</Index><Phone>A&amp;B</Phone><Content>Привет &lt;test&gt; "ok"\\end\nsecond line</Content><Date>2026-11-07 12:00:00</Date></Message>'
        compact = '<response><Messages>' + msg + msg.replace('<Index>1', '<Index>2') + '</Messages></response>'
        for xml in (compact, compact.replace('><', '>\r\n<')):
            data = self.parse(xml)['msg']
            self.assertEqual([m['index'] for m in data], [1, 2])
            self.assertEqual(data[0]['sender'], 'A&B')
            self.assertEqual(data[0]['content'], 'Привет <test> "ok"\\end second line')

    def test_sms_errors_and_empty(self):
        for xml in ('', '<html>Login</html>', '<response><Messages>', '<error><code>100003</code></error>'):
            self.assertIn('error', self.parse(xml))
        self.assertEqual(self.parse('<response><Messages></Messages></response>'), {'msg': []})

    def test_e5573_report_numeric_entities(self):
        xml = '''<?xml version="1.0" encoding="utf-8"?>
<response>
 <Count>3</Count>
 <Messages>
  <Message><Smstat>0</Smstat><Index>40005</Index><Phone>RSCHS</Phone><Content>Текст сообщения.</Content><Date>2026-11-07 12:41:12</Date><SaveType>4</SaveType><SmsType>2</SmsType></Message>
  <Message><Smstat>1</Smstat><Index>40004</Index><Phone>MTC</Phone><Content>текст

&#x2F;&#x2F; сообщения&#x2F;мес, </Content><Date>2026-11-07 10:50:39</Date><SaveType>4</SaveType><SmsType>2</SmsType></Message>
  <Message><Smstat>1</Smstat><Index>40003</Index><Phone>MTC</Phone><Content>текст сообщения&#x2F;0yKOQ6 </Content><Date>2026-11-07 09:23:40</Date><SaveType>4</SaveType><SmsType>2</SmsType></Message>
 </Messages>
</response>'''
        messages = self.parse(xml)['msg']
        self.assertEqual([m['index'] for m in messages], [40005, 40004, 40003])
        self.assertEqual(messages[1]['content'], 'текст  // сообщения/мес, ')
        self.assertEqual(messages[2]['content'], 'текст сообщения/0yKOQ6 ')

    def test_xml_entities_decode_once(self):
        text = '&#47; &#x2f; &#1046; &#x1F600; &amp;#47; &#38;lt; &#0; &#xD800;'
        xml = '<response><Messages><Message><Index>1</Index><Content>' + text + '</Content></Message></Messages></response>'
        self.assertEqual(self.parse(xml)['msg'][0]['content'], '/ / Ж 😀 &#47; &lt; &#0; &#xD800;')

    def test_login_and_session(self):
        for kind in ('3', '4'):
            password = 'pa$$word<&'
            enc = base64.b64encode(password.encode()).decode()
            if kind == '4':
                inner = base64.b64encode(hashlib.sha256(password.encode()).hexdigest().encode()).decode()
                enc = base64.b64encode(hashlib.sha256(('admin' + inner + 'guest-token').encode()).hexdigest().encode()).decode()
            body = r'''
_addr_for() { echo 192.168.8.1; }
_netdev_for() { echo usb0; }
_srcip_for() { echo 192.168.8.2; }
_web_user() { echo admin; }
_web_pass() { printf '%s' 'pa$$word<&'; }
logger() { :; }
curl() {
    hdr=; payload=; cookie=; token=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -D) hdr="$2"; shift ;;
            --data) payload="$2"; shift ;;
            -H) case "$2" in 'Cookie: '*) cookie="$2" ;; '__RequestVerificationToken: '*) token="$2" ;; esac; shift ;;
        esac
        url="$1"; shift
    done
    case "$url" in
        */SesTokInfo)
            if [ -f "$CACHE_DIR/logged" ]; then
                [ "$cookie" = 'Cookie: SessionID=logged' ] || return 9
                echo '<response><SesInfo>SessionID=logged</SesInfo><TokInfo>fresh-token</TokInfo></response>'
            else
                echo '<response><SesInfo>SessionID=guest</SesInfo><TokInfo>guest-token</TokInfo></response>'
            fi ;;
        */state-login) echo '<response><State>-1</State><password_type>KIND</password_type></response>' ;;
        */user/login)
            [ "$payload" = '<?xml version="1.0" encoding="UTF-8"?><request><Username>admin</Username><Password>ENC</Password><password_type>KIND</password_type></request>' ] || return 8
            echo x >> "$CACHE_DIR/login-count"
            if [ "$FAIL_LOGIN" = 1 ]; then
                echo '<error><code>108002</code></error>'
            else
                touch "$CACHE_DIR/logged"
                printf 'Set-Cookie: SessionID=logged; path=/\r\n__RequestVerificationTokenone: first-token\r\n__RequestVerificationTokentwo: next-token\r\n' > "$hdr"
                echo '<response>OK</response>'
            fi ;;
        */sms-list)
            if [ -f "$CACHE_DIR/logged" ]; then
                [ "$cookie" = 'Cookie: SessionID=logged' ] || return 7
                case "$token" in '__RequestVerificationToken: next-token'|'__RequestVerificationToken: fresh-token') ;; *) return 5 ;; esac
                echo '<response><Messages></Messages></response>'
            else
                echo '<error><code>100003</code></error>'
            fi ;;
    esac
}
api_post /api/sms/sms-list '<PageIndex>1</PageIndex>' path
api_post /api/sms/sms-list '<PageIndex>1</PageIndex>' path
[ "$(wc -l < "$CACHE_DIR/login-count")" = 1 ] || exit 6
'''.replace('KIND', kind).replace('ENC', enc)
            self.assertEqual(self.run_shell(body).count('<response><Messages>'), 2)
            self.assertEqual(self.run_shell('FAIL_LOGIN=1\n' + body).count('<code>108002</code>'), 2)


if __name__ == '__main__':
    unittest.main()
