#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / '.github/scripts/mtk-dist.py'


class MtkDistributionTests(unittest.TestCase):
    def test_fingerprint_and_package_integrity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            names = subprocess.check_output(['git', 'ls-files', '-z', '5gmodem-mtk-at'], cwd=ROOT).decode().split('\0')
            names += ['.github/scripts/mtk-dist.py', '.github/scripts/fast-build.sh',
                      '.github/scripts/fetch-sdk.sh', '.github/workflows/build-mtk.yml']
            for name in filter(None, names):
                dest = root / name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, dest)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            dist = root / 'dist/5gmodem-mtk-at'
            dist.mkdir(parents=True)
            for ext in ('apk', 'ipk'):
                (dist / f'5gmodem-mtk-at.{ext}').write_bytes(ext.encode())
            run = lambda mode: subprocess.run(['python3', str(root / '.github/scripts/mtk-dist.py'), mode],
                                               capture_output=True, text=True)
            self.assertEqual(run('check').returncode, 1)
            self.assertEqual(run('write').returncode, 0)
            self.assertEqual(run('check').returncode, 0)
            for name in ('5gmodem-mtk-at/src/usock.c', '5gmodem-mtk-at/root/etc/init.d/5gmodem-mtkat',
                         '.github/scripts/fast-build.sh', '.github/workflows/build-mtk.yml',
                         'dist/5gmodem-mtk-at/5gmodem-mtk-at.apk'):
                p = root / name
                original = p.read_bytes()
                p.write_bytes(original + b'\n')
                self.assertEqual(run('check').returncode, 1, name)
                p.write_bytes(original)
                self.assertEqual(run('check').returncode, 0, name)
            p = root / '5gmodem-mtk-at/build-usock.sh'
            p.chmod(p.stat().st_mode ^ 0o111)
            self.assertEqual(run('check').returncode, 1)

    def test_sdk_builds_only_requested_package(self):
        source = (ROOT / '.github/scripts/fast-build.sh').read_text()
        for requested in (None, '5gmodem-mtk-at'):
            with self.subTest(package=requested), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / 'scripts').mkdir()
                (root / 'tools').mkdir()
                (root / 'bin').mkdir()
                (root / 'package/feeds/modem').mkdir(parents=True)
                (root / 'feeds.conf.default').write_text('src-git base https://git.openwrt.org/openwrt/packages\nsrc-git luci https://git.openwrt.org/project/luci\n')
                (root / '.config').touch()
                for pkg in ('luci-app-5gmodem', '5gmodem-mtk-at'):
                    (root / 'package/feeds/modem' / pkg).symlink_to(root / 'absent')
                for tool in ('scripts/feeds', 'tools/make'):
                    p = root / tool
                    p.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "' + str(root / 'calls') + '"\n')
                    p.chmod(0o755)
                script = source.replace('/builder', str(root)).replace('/sdk/sdk.tar', str(root / 'missing.tar')).replace('/artifacts', str(root / 'artifacts'))
                p = root / 'build.sh'
                p.write_text(script)
                env = dict(os.environ, PATH=str(root / 'tools') + ':' + os.environ['PATH'])
                subprocess.run(['bash', str(p)] + ([requested] if requested else []),
                               env=env, check=True, capture_output=True)
                calls = (root / 'calls').read_text()
                chosen = requested or 'luci-app-5gmodem'
                other = 'luci-app-5gmodem' if requested else '5gmodem-mtk-at'
                self.assertIn('install -p modem -f ' + chosen, calls)
                self.assertIn('package/' + chosen + '/compile', calls)
                self.assertNotIn(other, calls)

    def test_local_prompt_needs_supported_hardware_and_missing_executable(self):
        bands = (ROOT / 'luci-app-5gmodem/root/usr/share/5gmodem/bands.sh').read_text()
        block = bands[bands.index('if [ "$1" = mtk-package-needed ];'):bands.index('\ncase "$1" in')]
        lib = (ROOT / 'luci-app-5gmodem/root/usr/share/5gmodem/lib.sh').read_text()
        detect = lib[lib.index('mtk_soc_modem() {'):lib.index('\nsoc_modem_node() {')]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'ccci').mkdir()
            (root / 'ttyC0').touch()
            helper = root / 'helper'
            detect = detect.replace('/sys/kernel/ccci', str(root / 'ccci')).replace('/dev/socket', str(root / 'socket')).replace('/dev/ttyC0', str(root / 'ttyC0')).replace('[ -c ', '[ -f ')
            block = block.replace('. /usr/share/5gmodem/lib.sh', ':').replace('/usr/share/5gmodem/mtk/usock-armv7', str(helper))
            run = lambda: subprocess.check_output(['busybox', 'ash', '-c', detect + '\n' + block,
                                                   'test', 'mtk-package-needed'], text=True).strip()
            self.assertEqual(run(), '1')
            helper.touch()
            self.assertEqual(run(), '1')
            helper.chmod(0o755)
            self.assertEqual(run(), '0')
            helper.unlink()
            (root / 'ccci').rmdir()
            self.assertEqual(run(), '0')


if __name__ == '__main__':
    unittest.main()
