import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-readme-links.sh'
PREFIX = 'https://github.com/fildunsky/luci-app-5gmodem/releases/download/'


class ReadmeLinks(unittest.TestCase):
    def run_check(self, responses, links):
        requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_HEAD(self):
                requests.append(self.path)
                choices = responses[self.path]
                response = choices.pop(0) if len(choices) > 1 else choices[0]
                self.send_response(response)
                if response == 302:
                    self.send_header('Location', '/asset')
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                prefix = 'http://127.0.0.1:%d/' % server.server_port
                script = SCRIPT.read_text().replace(PREFIX, prefix)
                for filename in ('README.md', 'README.ru.md'):
                    (base/filename).write_text('\n'.join(prefix+link for link in links))
                result = subprocess.run(['sh', '-c', script], cwd=base, text=True,
                                        capture_output=True, timeout=20)
                return result, requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_gateway_failures_retry_and_duplicate_links_are_checked_once(self):
        result, requests = self.run_check({'/package.apk': [504, 504, 200]}, ['package.apk'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/package.apk']*3)
        self.assertTrue(result.stdout.startswith('200 '), result.stdout)

    def test_missing_asset_fails_without_retry_and_checks_remaining_links(self):
        result, requests = self.run_check({'/bad.ipk': [404], '/good.apk': [200]},
                                          ['bad.ipk', 'good.apk'])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(requests, ['/bad.ipk', '/good.apk'])
        self.assertIn('not committing', result.stderr)

    def test_release_redirect_is_followed(self):
        result, requests = self.run_check({'/download.apk': [302], '/asset': [200]}, ['download.apk'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/download.apk', '/asset'])


if __name__ == '__main__':
    unittest.main()
