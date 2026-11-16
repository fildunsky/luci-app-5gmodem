"""Unisoc-based Fibocom modules in ECM mode: dial with AT+GTRNDIS, address from the module's DHCP."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROTO = ROOT / 'root/lib/netifd/proto/fibocom.sh'
WATCH = ROOT / 'root/usr/share/5gmodem/sessionwatch.sh'


def fn(name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}$', PROTO.read_text(), re.M | re.S)
    if not match:
        raise ValueError(name)
    return match[0] + '\n'


MOCK = '''
LOG="$T/at.log"; : > "$LOG"
sms_tool() {
	echo "$4" >> "$LOG"
	case "$4" in
		"AT+GTRNDIS?") if [ -f "$T/up" ]; then printf '+GTRNDIS: 1,1,"10.0.0.2","1.1.1.1","2.2.2.2"\\r\\nOK\\r\\n'; else printf '+GTRNDIS: 0\\r\\nOK\\r\\n'; fi ;;
		"AT+GTRNDIS=1,1") [ -n "$NOCALL" ] || : > "$T/up" ;;
		"AT+GTRNDIS=0,1") rm -f "$T/up" ;;
		"AT+GTIPPASS?") [ -n "$NOPASS" ] || printf '+GTIPPASS: %s\\r\\nOK\\r\\n' "${CURPASS:-0}" ;;
		"AT+CGDCONT?") printf '+CGDCONT: 1,"IP","%s","0.0.0.0",0,0\\r\\nOK\\r\\n' "$CURAPN" ;;
	esac
}
_fibocom_auth() { :; }
sleep() { :; }
'''


def run(env_extra, pre=''):
    with tempfile.TemporaryDirectory() as temp:
        env = dict(os.environ, T=temp, **env_extra)
        src = MOCK + fn('_uni_state') + fn('_uni_dial') + pre + '''
_uni_dial /dev/ttyUSB0 IP ctnet "$COLD" "$PASS" >/dev/null; echo "rc=$?"
cat "$LOG"
'''
        return subprocess.run(['busybox', 'ash', '-c', src], text=True, capture_output=True,
                              timeout=20, env=env)


UP = ': > "$T/up"\n'


class FibocomUnisoc(unittest.TestCase):
    def test_cold_dial_uses_gtrndis(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '0', 'PASS': ''})
        self.assertIn('rc=0', r.stdout)
        self.assertIn('AT+GTRNDIS=1,1', r.stdout)
        self.assertNotIn('CGACT', r.stdout)
        self.assertNotIn('GTIPPASS', r.stdout)

    def test_live_call_is_reused(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '0', 'PASS': ''}, pre=UP)
        self.assertIn('rc=0', r.stdout)
        self.assertNotIn('AT+GTRNDIS=0,1', r.stdout)
        self.assertNotIn('AT+GTRNDIS=1,1', r.stdout)

    def test_other_apn_redials(self):
        r = run({'CURAPN': 'old', 'COLD': '0', 'PASS': ''}, pre=UP)
        self.assertIn('AT+GTRNDIS=0,1', r.stdout)
        self.assertIn('AT+CGDCONT=1,"IP","ctnet"', r.stdout)
        self.assertIn('AT+GTRNDIS=1,1', r.stdout)

    def test_no_call_fails(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '1', 'PASS': '', 'NOCALL': '1'})
        self.assertIn('rc=1', r.stdout)

    def test_bridge_change_is_written_before_the_call(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '0', 'PASS': '1', 'CURPASS': '0'}, pre=UP)
        out = r.stdout
        self.assertIn('AT+GTIPPASS=1', out)
        self.assertLess(out.index('AT+GTIPPASS=1'), out.index('AT+GTRNDIS=1,1'))
        self.assertIn('rc=0', out)

    def test_bridge_already_set_keeps_the_call(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '0', 'PASS': '1', 'CURPASS': '1'}, pre=UP)
        self.assertNotIn('AT+GTIPPASS=1', r.stdout)
        self.assertNotIn('AT+GTRNDIS=1,1', r.stdout)

    def test_bridge_unsupported_still_dials(self):
        r = run({'CURAPN': 'ctnet', 'COLD': '0', 'PASS': '1', 'NOPASS': '1'})
        self.assertNotIn('AT+GTIPPASS=1', r.stdout)
        self.assertIn('rc=0', r.stdout)

    def test_setup_watcher_and_page_know_the_family(self):
        proto = PROTO.read_text()
        self.assertIn('2cb7:0a04|2cb7:0a05|2cb7:0a06|2cb7:0a07) IS_UNI=1', proto)
        # no_device=1: netifd rejects dhcp.script updates without an ifname, so the netdev is
        # handed over first and a dhcp child interface takes the lease
        self.assertNotIn('udhcpc -p', proto)
        uni = proto[proto.index('if [ "$IS_UNI" = 1 ]; then\n\t\tif ! _uni_dial'):]
        uni = uni[:uni.index('return 0')]
        self.assertLess(uni.index('proto_init_update "$netdev" 1'), uni.index('proto_send_update "$interface"'))
        self.assertLess(uni.index('proto_send_update "$interface"'), uni.index('json_add_string name "${interface}_4"'))
        self.assertIn('json_add_string ifname "@$interface"', uni)
        self.assertIn('json_add_string proto "dhcp"', uni)
        self.assertIn('ubus call network add_dynamic', uni)
        self.assertIn('proto_config_add_string "ippass"', proto)
        # dual stack: the same dhcpv6 child interface as the other modems of this proto
        self.assertIn('_fibocom_v6 "$interface" "$uni_ctx" "$sourcefilter"', proto)
        self.assertIn('_fibocom_v6 "$interface" "$ctx_pdp" "$sourcefilter"', proto)
        watch = WATCH.read_text()
        self.assertLess(watch.index('AT+GTRNDIS?'), watch.index('_mip=$(_modem_ip "$_port")'))
        self.assertIn('network.$_ifn.ippass=', (ROOT / 'root/usr/share/5gmodem/setopt.sh').read_text())
        page = (ROOT / 'htdocs/luci-static/resources/view/modem5g/5gdebug.js').read_text()
        self.assertIn("[ 'ippass', String(p), v ]", page)
        self.assertIn("roamProto === 'fibocom' && !uniMod", page)


if __name__ == '__main__':
    unittest.main()
