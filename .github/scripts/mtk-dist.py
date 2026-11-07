#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DIST = ROOT / 'dist/5gmodem-mtk-at'
MANIFEST = DIST / 'manifest.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inputs():
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', '5gmodem-mtk-at'], cwd=ROOT).decode().split('\0')
    names += ['.github/workflows/build-mtk.yml', '.github/scripts/fast-build.sh',
              '.github/scripts/fetch-sdk.sh', '.github/scripts/mtk-dist.py']
    result = hashlib.sha256()
    for name in sorted(filter(None, names)):
        path = ROOT / name
        result.update(name.encode() + b'\0' + path.read_bytes() + b'\0')
        result.update(str(path.stat().st_mode & 0o111).encode() + b'\0')
    return result.hexdigest()


def snapshot():
    return {'inputs_sha256': inputs(), 'packages': {
        f'5gmodem-mtk-at.{ext}': digest(DIST / f'5gmodem-mtk-at.{ext}')
        for ext in ('apk', 'ipk')}}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('check', 'write'):
        raise SystemExit('usage: mtk-dist.py check|write')
    if sys.argv[1] == 'write':
        MANIFEST.write_text(json.dumps(snapshot(), indent=2) + '\n')
        return
    try:
        current = json.loads(MANIFEST.read_text()) == snapshot()
    except (OSError, ValueError):
        current = False
    print('current' if current else 'rebuild')
    raise SystemExit(0 if current else 1)


if __name__ == '__main__':
    main()
