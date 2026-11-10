import json
import os
import subprocess
import unittest

from test_runtime_audit import SHARE


def row(index, sender, body, read=0):
    return (f'Row: 0 _id={index}, sub_id=5, type=1, read={read}, date=1700000000000, '
        f'address_hex={sender.encode().hex()}, body_hex={body.encode().hex()}\n')


class AndroidSms(unittest.TestCase):
    def parse(self, text, count=False, awk=('busybox', 'awk')):
        return subprocess.run([*awk, '-v', f'count_only={int(count)}', '-f', str(SHARE / 'android-sms.awk')],
            input=text, capture_output=True, text=True, timeout=5, env=dict(os.environ, LC_ALL='C', TZ='UTC'))

    def test_hex_projection_preserves_unicode_multiline_text_and_sender(self):
        body = 'Тест, body_hex=00\n"quote" \\ tab\t中文 🛰️\nRow: 7 _id=8'
        for awk in [('busybox', 'awk'), ('awk',)]:
            result = self.parse(row(17, '+15551234567', body)+'__5GM_SMS_END__\n', awk=awk)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.loads(result.stdout)
            self.assertTrue(data['read_only'])
            self.assertEqual(data['msg'][0]['content'], body)
            self.assertEqual(data['msg'][0]['sender'], '+15551234567')
            self.assertEqual(data['msg'][0]['index'], 17)
            self.assertEqual(data['msg'][0]['timestamp'], '2023-11-14 22:13')

    def test_empty_inbox_and_count_only(self):
        result = self.parse('No result found.\n__5GM_SMS_END__\n')
        self.assertEqual(json.loads(result.stdout)['msg'], [])
        result = self.parse('Row: 0 _id=1, read=0\nRow: 1 _id=2, read=1\n__5GM_SMS_END__\n', count=True)
        self.assertEqual(json.loads(result.stdout), {'used': 2, 'unread': 1, 'unseen': 1, 'read_only': True})

    def test_denial_partial_and_invalid_hex_do_not_become_empty_success(self):
        for text in ['Permission Denial\n__5GM_SMS_END__\n', row(1, 'Test', 'x'),
                row(1, 'Test', 'x').replace('body_hex=78', 'body_hex=GZ')+'__5GM_SMS_END__\n',
                row(1, 'Test', 'x')+row(1, 'Test', 'x')+'__5GM_SMS_END__\n']:
            result = self.parse(text)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('error', json.loads(result.stdout))


if __name__ == '__main__':
    unittest.main()
