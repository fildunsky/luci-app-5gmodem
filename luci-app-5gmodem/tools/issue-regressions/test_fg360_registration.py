import json
import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import SHARE, shell


class Fg360Registration(unittest.TestCase):
    def setUp(self):
        fixture = tempfile.TemporaryDirectory()
        self.addCleanup(fixture.cleanup)
        self.root = Path(fixture.name)

        (self.root / 'sys/kernel/ccci').mkdir(parents=True)
        (self.root / 'sys/class/net/ccmni3').mkdir(parents=True)
        self.write('/usr/bin/mipc_wan_cli', executable=True)
        self.write('/lib/netifd/proto/mipc.sh')
        self.api = self.write('/usr/libexec/fg360-mea-webui/fg360_api.lua', 'FG360_STATUS_LIBRARY')

        for name in ('lib.sh', 'listmodems.sh', 'msw/setup.sh', 'msw/iface.sh', 'mkiface.sh'):
            source = (SHARE / name).read_text()
            source = source.replace('/dev/null', '@DEV_NULL@')
            for path in ('/usr/share/5gmodem', '/usr/libexec/fg360-mea-webui', '/usr/bin/mipc_wan_cli',
                         '/lib/netifd/proto/mipc.sh', '/tmp/5gmodem', '/sys', '/dev'):
                source = source.replace(path, str(self.root) + path)
            self.write('/usr/share/5gmodem/' + name, source.replace('@DEV_NULL@', '/dev/null'))

    def write(self, path, content='', executable=False):
        target = self.root / path.lstrip('/')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        if executable:
            target.chmod(0o755)
        return target

    def run_device(self, script, link='up', proto='mipc', **env):
        mock = r'''
CFG=5gmodem
RES="$FAKE/usr/share/5gmodem"
uci() {
    case "$*" in
        "-q get network.wan.proto") printf '%s\n' "$WAN_PROTO" ;;
        "-q get 5gmodem.@5gmodem[0].active_modem") : ;;
        "-q show network") printf '%s\n' "network.wan6.proto='mipc'" "network.mobile.proto='mipc'" ;;
        "-q set "*|"-q delete "*|"-q commit "*) printf '%s\n' "$*" >> "$FAKE/writes" ;;
        *) return 1 ;;
    esac
}
ubus() {
    case "$*" in
        "call network.interface.wan status")
            [ "$LINK" = up ] && echo '{"l3_device":"ccmni3"}' || echo '{"up":false}' ;;
        *) printf 'unexpected ubus: %s\n' "$*" >> "$FAKE/writes"; return 9 ;;
    esac
}
jsonfilter() { sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p'; }
ifup() { printf 'unexpected ifup: %s\n' "$*" >> "$FAKE/writes"; return 9; }
at_for_path() { printf 'unexpected AT probe: %s\n' "$*" >> "$FAKE/writes"; return 9; }
'''
        return shell(mock + script, dict(os.environ, FAKE=str(self.root), LINK=link,
                                        WAN_PROTO=proto, **env))

    def test_list_without_tty_and_when_vendor_link_is_down(self):
        for link in ('up', 'down'):
            with self.subTest(link=link):
                result = self.run_device('\nset -- --refresh; . "$RES/listmodems.sh"', link)
                self.assertEqual(result.returncode, 0, result.stderr)
                modem, = json.loads(result.stdout)
                self.assertEqual(modem['path'], 'ccci')
                self.assertEqual(modem['model'], 'Fibocom FG360')
                self.assertEqual(modem['vidpid'], '')
                self.assertEqual(modem['tty'], [])
                self.assertEqual(modem['net'], ['ccmni3'] if link == 'up' else [])

        self.api.write_text('unrelated vendor')
        self.assertEqual(json.loads(self.run_device('\nset -- --refresh; . "$RES/listmodems.sh"').stdout), [])

    def test_setup_references_the_configured_protocol_without_dialling(self):
        result = self.run_device('''
. "$RES/lib.sh"
. "$RES/msw/setup.sh"
. "$RES/msw/iface.sh"
setup_one_modem ccci && ensure_iface ccci m_ccci && iface_for_path ccci
''', link='down', proto='dhcp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'mobile')
        commands = (self.root / 'writes').read_text().splitlines()
        self.assertIn('-q set 5gmodem.m_ccci.network=mobile', commands)
        self.assertIn('-q set 5gmodem.m_ccci.iface_proto=mipc', commands)
        self.assertIn('-q delete 5gmodem.m_ccci.at_port', commands)
        self.assertTrue(all(line.startswith(('-q set 5gmodem.', '-q delete 5gmodem.', '-q commit 5gmodem'))
                            for line in commands), commands)

    def test_mkiface_leaves_mipc_untouched(self):
        result = self.run_device('\nset -- modem auto; . "$RES/mkiface.sh"', MODEM_PATH='ccci')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout),
                         dict(result='existing', iface='wan', proto='mipc', device='ccmni3'))
        self.assertFalse((self.root / 'writes').exists())
