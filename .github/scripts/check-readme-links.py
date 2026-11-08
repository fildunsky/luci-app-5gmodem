#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
import sys


PREFIX = 'https://github.com/fildunsky/luci-app-5gmodem/releases/download/'


def validate_links(release, tag, texts):
    if release.get('isDraft') or release.get('tagName') != tag:
        raise ValueError('release must be published with the requested tag')
    assets = {asset['url']: asset for asset in release['assets']}
    urls = set()
    for text in texts:
        urls.update(re.findall(re.escape(PREFIX) + r'[^\s)<>"\x27]+', text))
    if not urls:
        raise ValueError('no README download links found')
    for url in sorted(urls):
        asset = assets.get(url)
        if not url.startswith(PREFIX + tag + '/') or not asset:
            raise ValueError('README URL is not an asset of the published release: ' + url)
        if asset.get('state') != 'uploaded' or asset.get('size', 0) <= 0:
            raise ValueError('README asset upload is incomplete: ' + url)
    return sorted(urls)


def main():
    tag = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('TAG', '')
    if not re.fullmatch(r'v[0-9]+(?:\.[0-9]+)+', tag):
        raise ValueError('a release tag such as v3.9.31 is required')
    release = json.loads(subprocess.check_output(
        ['gh', 'release', 'view', tag, '--json', 'assets,isDraft,tagName'], text=True))
    urls = validate_links(release, tag, [p.read_text() for p in Path('.').glob('README*.md')])
    for url in urls:
        print('ok ' + url)
    print('Verified %d README links against published release assets' % len(urls))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('::error::%s - not committing' % error, file=sys.stderr)
        sys.exit(1)
