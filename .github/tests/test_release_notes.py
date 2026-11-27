import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/check-release-notes.py'
spec = importlib.util.spec_from_file_location('release_notes', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def complete():
    return {'body': '- Improved modem support.', 'assets': [
        {'name': f'notes-{lang}.txt', 'state': 'uploaded', 'size': 150}
        for lang in module.LANGUAGES]}


class ReleaseNotesTests(unittest.TestCase):
    def test_all_translations_required(self):
        self.assertEqual(module.validate(complete()), [])
        for language in module.LANGUAGES:
            with self.subTest(language=language):
                release = complete()
                release['assets'] = [a for a in release['assets'] if a['name'] != f'notes-{language}.txt']
                errors = module.validate(release)
                self.assertEqual(len(errors), 1)
                self.assertIn(language, errors[0])

    def test_english_only_is_rejected(self):
        errors = module.validate({'body': '- Improved modem support.', 'assets': []})
        self.assertEqual(len(errors), 6)

    def test_empty_english_body_is_rejected(self):
        for body in ('', ' \n', None):
            release = complete()
            release['body'] = body
            self.assertTrue(module.validate(release))

    def test_empty_oversized_and_pending_assets_are_rejected(self):
        for changes in ({'size': 0}, {'size': 8193}, {'size': None}, {'state': 'new'}):
            release = complete()
            release['assets'][0].update(changes)
            self.assertEqual(len(module.validate(release)), 1)

    def test_cli_failure_blocks_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / 'gh'
            gh.write_text('#!/bin/sh\ncat "$FIXTURE"\n')
            gh.chmod(0o755)
            fixture = root / 'release.json'
            env = dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'], FIXTURE=str(fixture))
            for assets, code in ((complete()['assets'], 0), ([], 1)):
                fixture.write_text(json.dumps({'body': '- Improved modem support.', 'assets': assets}))
                result = subprocess.run(['python3', str(SCRIPT), 'v0.0.1'], env=env,
                                        text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stderr)

    def test_gate_runs_before_publication(self):
        source = (SCRIPT.parents[1] / 'workflows/build.yml').read_text()
        self.assertLess(source.index('python3 .github/scripts/check-release-notes.py'),
                        source.index('gh release edit "$TAG" --draft=false'))


if __name__ == '__main__':
    unittest.main()
