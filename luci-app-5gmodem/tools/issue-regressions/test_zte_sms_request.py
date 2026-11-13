import os
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

from test_runtime_audit import function, shell


class ZteSmsRequest(unittest.TestCase):
    def test_sms_list_and_other_reads_on_both_api_paths(self):
        with tempfile.TemporaryDirectory() as cache:
            source = r'''
_srcip_for() { echo 192.168.100.2; }
_zte_getpath() { echo "$API_PATH"; }
curl() { printf '%s\n' "$@"; }
UA=5gmodem
''' + function('_hl_src', 'hilink.sh') + '\n' + function('_zte_get', 'hilink.sh') + '\n' + function('_zte_sms_fetch', 'hilink.sh') + r'''
case "$COMMAND" in
 fetch) _zte_sms_fetch 192.168.100.1 "$STORE" ;;
 *) _zte_get 192.168.100.1 "$COMMAND" ;;
esac
'''
            for path in ('reqproc/proc_get', 'goform/goform_get_cmd_process'):
                for command in ('fetch', 'sms_data_total', 'sms_capacity_info',
                                'modem_main_state,lte_rsrp', 'sms_data_total_extra'):
                    for store in ('0', '1'):
                        with self.subTest(path=path, command=command, store=store):
                            result = shell(source, dict(os.environ, CACHE_DIR=cache,
                                API_PATH=path, COMMAND=command, STORE=store))
                            self.assertEqual(result.returncode, 0, result.stderr)
                            args = result.stdout.splitlines()
                            url = urlsplit(args[-1])
                            query = parse_qs(url.query)
                            self.assertEqual(url.path, '/' + path)
                            self.assertEqual(query['isTest'], ['false'])
                            self.assertIn('Referer: http://192.168.100.1/index.html', args)
                            self.assertIn('X-Requested-With: XMLHttpRequest', args)
                            self.assertEqual(args[args.index('--interface') + 1], '192.168.100.2')
                            is_sms = command in ('fetch', 'sms_data_total')
                            self.assertEqual('multi_data' in query, not is_sms)
                            if not is_sms:
                                self.assertEqual(query['multi_data'], ['1'])
                            self.assertEqual(query['cmd'], ['sms_data_total' if command == 'fetch' else command])
                            if command == 'fetch':
                                self.assertEqual(query['mem_store'], [store])
                                self.assertEqual(query['page'], ['0'])
                                self.assertEqual(query['data_per_page'], ['100'])
                                self.assertEqual(query['tags'], ['10'])
                                self.assertEqual(query['order_by'], ['order by id desc'])


if __name__ == '__main__':
    unittest.main()
