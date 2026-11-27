#!/usr/bin/env python3
"""Block publication when the English body or a required translation is missing."""
import json
import subprocess
import sys

LANGUAGES = ('ru', 'id', 'ja', 'vi', 'zh_Hans', 'zh_Hant')


def validate(release):
    errors = []
    if not (release.get('body') or '').strip():
        errors.append('English release notes are empty')
    assets = {asset['name']: asset for asset in release.get('assets', [])}
    for language in LANGUAGES:
        name = f'notes-{language}.txt'
        asset = assets.get(name)
        if asset is None:
            errors.append(f'Missing release notes: {name}')
        elif asset.get('state') != 'uploaded':
            errors.append(f'Release notes upload is incomplete: {name}')
        elif not isinstance(asset.get('size'), int) or not 0 < asset['size'] <= 8192:
            errors.append(f'Release notes must contain 1–8192 bytes: {name}')
    return errors


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: check-release-notes.py <tag>')
    release = json.loads(subprocess.check_output(
        ['gh', 'release', 'view', sys.argv[1], '--json', 'body,assets'], text=True))
    errors = validate(release)
    for error in errors:
        print(f'::error::{error}', file=sys.stderr)
    if errors:
        return 1
    print('English release notes and all six translations are ready')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
