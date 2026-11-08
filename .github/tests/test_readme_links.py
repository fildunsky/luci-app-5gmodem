import importlib.util
from pathlib import Path
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-readme-links.py'
SPEC = importlib.util.spec_from_file_location('readme_links', SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
TAG = 'v3.9.31'
URL = MODULE.PREFIX + TAG + '/luci-app-5gmodem-3.9.31-r1.apk'


class ReadmeLinks(unittest.TestCase):
    def release(self, **changes):
        release = {'tagName': TAG, 'isDraft': False,
                   'assets': [{'url': URL, 'state': 'uploaded', 'size': 907312}]}
        release.update(changes)
        return release

    def test_exact_published_url_is_accepted_and_deduplicated(self):
        self.assertEqual(MODULE.validate_links(self.release(), TAG, [URL, URL]), [URL])

    def test_missing_asset_or_wrong_filename_is_rejected(self):
        for url in (URL.replace('.apk', '.ipk'), URL.replace('-r1', '-r2')):
            with self.subTest(url=url), self.assertRaises(ValueError):
                MODULE.validate_links(self.release(), TAG, [url])

    def test_stale_readme_version_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.validate_links(self.release(), TAG, [URL.replace('3.9.31', '3.9.30')])

    def test_draft_or_wrong_release_is_rejected(self):
        for changes in ({'isDraft': True}, {'tagName': 'v3.9.30'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                MODULE.validate_links(self.release(**changes), TAG, [URL])

    def test_empty_or_incomplete_upload_is_rejected(self):
        for state, size in [('uploaded', 0), ('new', 907312)]:
            release = self.release(assets=[{'url': URL, 'state': state, 'size': size}])
            with self.subTest(state=state, size=size), self.assertRaises(ValueError):
                MODULE.validate_links(release, TAG, [URL])

    def test_no_download_links_is_rejected(self):
        with self.assertRaises(ValueError):
            MODULE.validate_links(self.release(), TAG, ['No install links'])


if __name__ == '__main__':
    unittest.main()
