"""The SMS-command security code must not be the same word on every router,
and diagnostic bundles must not carry webhook URLs or headers."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2] / "root"
MIGRATION = ROOT / "etc/uci-defaults/54-5gmodem-smscmd-secret.sh"
PRESETS = ROOT / "etc/uci-defaults/42-5gmodem-smscmd-presets.sh"
COLLECT = ROOT / "usr/share/5gmodem/collect.sh"

UCI_STUB = """#!/bin/sh
[ "$1" = -q ] && shift
case "$1" in
get) case "$2" in *cmd_secret) cat "$ST/secret" ;; *cmd_enabled) cat "$ST/en" ;; esac ;;
set) printf '%s' "${2#*=}" > "$ST/secret" ;;
esac
exit 0
"""


class Migration(unittest.TestCase):
    def run_with(self, secret, enabled):
        with tempfile.TemporaryDirectory() as d:
            b = pathlib.Path(d, "bin")
            b.mkdir()
            (b / "uci").write_text(UCI_STUB)
            (b / "uci").chmod(0o755)
            pathlib.Path(d, "secret").write_text(secret)
            pathlib.Path(d, "en").write_text(enabled)
            env = dict(os.environ, ST=d, PATH=f"{b}:{os.environ['PATH']}")
            subprocess.run(["sh", str(MIGRATION)], env=env, check=True)
            return pathlib.Path(d, "secret").read_text()

    def test_old_default_replaced_while_off(self):
        new = self.run_with("Secret", "0")
        self.assertRegex(new, r"^[0-9a-f]{8}$")

    def test_old_default_kept_while_on(self):
        self.assertEqual(self.run_with("secret", "1"), "secret")

    def test_own_code_untouched(self):
        self.assertEqual(self.run_with("mine", "0"), "mine")

    def test_presets_do_not_seed_a_fixed_word(self):
        self.assertNotIn("cmd_secret='secret'", PRESETS.read_text())


class Redaction(unittest.TestCase):
    def test_webhook_options_hidden(self):
        lines = [l for l in COLLECT.read_text().splitlines() if "token|secret|pass|psk" in l]
        self.assertEqual(len(lines), 3)
        for l in lines:
            self.assertIn("hook_url|hook_header", l)


if __name__ == "__main__":
    unittest.main()
