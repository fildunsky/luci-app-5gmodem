import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

from test_runtime_audit import SHARE

SOURCE = (SHARE / 'update.sh').read_text()


class HelperUpdateTests(unittest.TestCase):
    def update(self, pm, installed=None, target='1.4-r1', failure='', lite=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'bin'
            binary.mkdir()
            tmp = root / 'tmp'
            tmp.mkdir()
            main = 'luci-app-5gmodem-lite' if lite else 'luci-app-5gmodem'
            (root / 'main_version').write_text('98.0-r1')
            (root / 'helper_version').write_text(installed or '')
            (root / 'main_package').write_bytes(b'main-package')
            (root / 'helper_package').write_bytes(b'helper-package')
            digest = hashlib.sha256(b'helper-package').hexdigest()
            manifest = {'version': target, 'packages': {
                '5gmodem-mtk-at.apk': digest, '5gmodem-mtk-at.ipk': digest}, 'sizes': {
                '5gmodem-mtk-at.apk': len(b'helper-package'),
                '5gmodem-mtk-at.ipk': len(b'helper-package')}}
            if failure == 'checksum':
                manifest['packages'] = {k: '0' * 64 for k in manifest['packages']}
            if failure == 'size':
                manifest['sizes'] = {k: v + 1 for k, v in manifest['sizes'].items()}
            if failure == 'metadata':
                del manifest['version']
            (root / 'manifest').write_text(json.dumps(manifest))
            ext = 'apk' if pm == 'apk' else 'ipk'
            asset = f'{main}-99.0-r1.apk' if pm == 'apk' else f'{main}_99.0-r1_all.ipk'
            (root / 'release').write_text(json.dumps({'tag_name': 'v99.0', 'assets': [{
                'name': asset, 'url': 'https://api.example/main', 'size': len(b'main-package')}]}))
            manager = r'''#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >> "$ROOT/calls"
case "$1" in
 info)
  if [ "$FAILURE" = read ] && [ "$2" = -v ]; then exit 1; fi
  if [ "$2" = -v ]; then
   echo "$MAIN-$(cat "$ROOT/main_version")"
   h=$(cat "$ROOT/helper_version"); [ -z "$h" ] || echo "5gmodem-mtk-at-$h"
  else echo "$MAIN"; fi ;;
 list-installed)
  [ "$FAILURE" != read ] || exit 1
  echo "$MAIN - $(cat "$ROOT/main_version")"
  h=$(cat "$ROOT/helper_version"); [ -z "$h" ] || echo "5gmodem-mtk-at - $h" ;;
 add|install)
  /bin/sleep 0.04
  [ "$FAILURE" != main ] || exit 1
  case " $* " in
   *' --no-network '*)
    if [ "$FAILURE" = deps ]; then echo 'unable to select packages'; exit 1; fi ;;
  esac
  for arg in "$@"; do
   case "$arg" in
    */5gmodem-mtk-at.*)
     if [ "$FAILURE" != install ]; then echo "$HELPER_TARGET" > "$ROOT/helper_version"; fi ;;
    */luci-app-5gmodem.*|*/luci-app-5gmodem-lite.*) echo 99.0-r1 > "$ROOT/main_version" ;;
   esac
  done
  case "$FAILURE" in install|postinst) exit 1 ;; esac ;;
 del|remove) : ;;
 *) exit 1 ;;
esac
exit 0
'''
            for tool in ('apk', 'opkg'):
                (binary / tool).write_text(manager)
                (binary / tool).chmod(0o755)
            (binary / 'jsonfilter').write_text(r'''#!/usr/bin/env python3
import json,re,sys
try:
 data=json.load(sys.stdin); expr=sys.argv[2]
 if expr=='@.assets[*].name':
  print('\n'.join(a['name'] for a in data['assets']))
 elif expr.startswith('@.assets[@.name='):
  name,field=re.fullmatch(r"@\.assets\[@\.name='([^']+)'\]\.([a-z_]+)",expr).groups()
  for a in data['assets']:
   if a['name']==name and field in a: print(a[field])
 elif expr.startswith(('@.packages[', '@.sizes[')):
  field,key=expr[2:].split('[',1); print(data[field][json.loads(key[:-1])])
 elif expr[2:] in data: print(data[expr[2:]])
except (KeyError,ValueError,AttributeError): pass
''')
            (binary / 'jsonfilter').chmod(0o755)
            (root / 'lib.sh').write_text(r'''
net_fetch() {
 echo "$2" >> "$ROOT/fetches"
 case "$2" in
  *releases/latest) cat "$ROOT/release" ;;
  */manifest.json)
   [ "$FAILURE" != manifest ] || return 1
   cat "$ROOT/manifest" ;;
  */5gmodem-mtk-at.*)
   [ "$FAILURE" != download ] || return 1
   head -c 6 "$ROOT/helper_package" > "$3"
   /bin/sleep 0.06
   tail -c +7 "$ROOT/helper_package" >> "$3" ;;
  https://api.example/main) /bin/sleep 0.04; cp "$ROOT/main_package" "$3" ;;
  *) return 1 ;;
 esac
}
logger() { :; }
sleep() { /bin/sleep 0.01; }
''')
            source = SOURCE.replace('. /usr/share/5gmodem/lib.sh 2>/dev/null', f'. "{root}/lib.sh"')
            source = source.replace('/tmp/5gmodem', str(tmp))
            source = source.replace('/tmp/luci-', str(root / 'luci-'))
            source = source.replace('/usr/share/5gmodem/i18n/', str(root / 'i18n') + '/')
            source = source.replace('/usr/lib/lua/luci/i18n/', str(root / 'luci-i18n') + '/')
            source = re.sub(r'^pkgman\(\) \{\n.*?^\}', f'pkgman() {{ echo {pm}; }}', source, flags=re.S | re.M)
            updater = root / 'update.sh'
            updater.write_text(source)
            env = dict(os.environ, PATH=f'{binary}:{os.environ["PATH"]}', ROOT=str(root),
                       MAIN=main, FAILURE=failure, HELPER_TARGET=target)
            result = subprocess.run(['busybox', 'ash', str(updater), 'install'], env=env,
                                    text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            status = {}
            self.last_stages = set()
            self.last_progress = []
            for _ in range(300):
                try:
                    status = json.loads((tmp / 'update.json').read_text())
                    if 'stage' in status:
                        self.last_stages.add(status['stage'])
                        if not self.last_progress or status != self.last_progress[-1]:
                            self.last_progress.append(status.copy())
                    if 'success' in status:
                        break
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(0.01)
            self.assertIn('success', status, status)
            calls = (root / 'calls').read_text().splitlines()
            fetches = (root / 'fetches').read_text().splitlines()
            leftover = (tmp / f'5gmodem-mtk-at.{ext}').exists()
            return status, calls, fetches, (root / 'helper_version').read_text().strip(), leftover

    def test_absent_helper_is_not_fetched_or_installed(self):
        for pm in ('apk', 'opkg'):
            for lite in (False, True):
                with self.subTest(pm=pm, lite=lite):
                    status, calls, fetches, version, leftover = self.update(pm, lite=lite)
                    self.assertTrue(status['success'], status)
                    self.assertFalse(any('dist/5gmodem-mtk-at' in url for url in fetches), fetches)
                    self.assertFalse(any('/5gmodem-mtk-at.' in call for call in calls), calls)
                    self.assertEqual(version, '')
                    self.assertFalse(leftover)

    def test_installed_helper_joins_one_transaction(self):
        for pm in ('apk', 'opkg'):
            for lite in (False, True):
                with self.subTest(pm=pm, lite=lite):
                    status, calls, fetches, version, leftover = self.update(pm, '1.3-r1', lite=lite)
                    self.assertTrue(status['success'], status)
                    installs = [c for c in calls if c.startswith(('apk add ', 'opkg install '))]
                    self.assertEqual(len(installs), 1, calls)
                    self.assertIn('/5gmodem-mtk-at.', installs[0])
                    if pm == 'apk':
                        self.assertIn('--no-network', installs[0])
                    self.assertEqual(version, '1.4-r1')
                    self.assertFalse(leftover)

    def test_same_or_newer_helper_is_preserved(self):
        for pm in ('apk', 'opkg'):
            for installed in ('1.4-r1', '1.4-r2', '1.5-r1', '1.4.1-r0'):
                with self.subTest(pm=pm, installed=installed):
                    status, calls, fetches, version, _ = self.update(pm, installed)
                    self.assertTrue(status['success'], status)
                    self.assertFalse(any(url.endswith(('.apk', '.ipk')) for url in fetches))
                    self.assertEqual(version, installed)

    def test_revision_only_upgrade(self):
        for pm in ('apk', 'opkg'):
            status, _, _, version, _ = self.update(pm, '1.4-r1', target='1.4-r2')
            self.assertTrue(status['success'], status)
            self.assertEqual(version, '1.4-r2')

    def test_failure_never_reports_a_successful_combined_update(self):
        for pm in ('apk', 'opkg'):
            for failure in ('read', 'manifest', 'metadata', 'checksum', 'download', 'size', 'install'):
                with self.subTest(pm=pm, failure=failure):
                    status, calls, _, version, leftover = self.update(pm, '1.3-r1', failure=failure)
                    self.assertFalse(status['success'], status)
                    self.assertEqual(status['error'], 'helper_update_failed')
                    if failure != 'install':
                        self.assertFalse(any(c.startswith(('apk add ', 'opkg install ')) for c in calls), calls)
                    self.assertEqual(version, '1.3-r1')
                    self.assertFalse(leftover)

    def test_install_progress_and_postinstall_verification(self):
        for pm in ('apk', 'opkg'):
            with self.subTest(pm=pm):
                status, _, _, version, _ = self.update(pm, '1.3-r1', failure='postinst')
                self.assertTrue(status['success'], status)
                self.assertEqual(version, '1.4-r1')
                self.assertEqual(status['previous'], '98.0')
                self.assertEqual(status['target'], '99.0')
                self.assertTrue({'download', 'install'} <= self.last_stages, self.last_stages)

    def test_main_failure_cleans_helper_download(self):
        for pm in ('apk', 'opkg'):
            status, _, _, version, leftover = self.update(pm, '1.3-r1', failure='main')
            self.assertFalse(status['success'], status)
            self.assertEqual(status['error'], 'install_failed')
            self.assertEqual(version, '1.3-r1')
            self.assertFalse(leftover)

    def test_apk_dependency_fallback_keeps_both_packages(self):
        status, calls, _, version, leftover = self.update('apk', '1.3-r1', failure='deps')
        self.assertTrue(status['success'], status)
        installs = [c for c in calls if c.startswith('apk add ')]
        self.assertEqual(len(installs), 2, calls)
        self.assertTrue(all('/5gmodem-mtk-at.apk' in c for c in installs), calls)
        self.assertEqual(version, '1.4-r1')
        self.assertFalse(leftover)

    def test_cumulative_download_progress_includes_helper_bytes(self):
        for pm in ('apk', 'opkg'):
            for installed in (None, '1.3-r1'):
                with self.subTest(pm=pm, installed=installed):
                    status, _, _, _, _ = self.update(pm, installed)
                    self.assertTrue(status['success'], status)
                    total = len(b'main-package') + (len(b'helper-package') if installed else 0)
                    downloads = [p for p in self.last_progress if p['stage'] == 'download']
                    self.assertTrue(downloads, self.last_progress)
                    self.assertTrue(all(p['total'] == total for p in downloads), downloads)
                    done = [p['done'] for p in downloads]
                    self.assertEqual(done, sorted(done), downloads)
                    helpers = [p for p in downloads if p['step'] == 'mtk']
                    if installed:
                        self.assertTrue(any(len(b'main-package') < p['done'] < total for p in helpers), helpers)
                    else:
                        self.assertFalse(helpers, downloads)
                    installs = [p for p in self.last_progress if p['stage'] == 'install']
                    self.assertTrue(installs, self.last_progress)
                    self.assertTrue(all((p['done'], p['total']) == (total, total) for p in installs), installs)
