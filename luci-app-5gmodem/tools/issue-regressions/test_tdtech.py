import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_runtime_audit import ROOT, SHARE, function, shell


def proto_function(name):
    source = (ROOT / 'root/lib/netifd/proto/fibocom.sh').read_text()
    if name.startswith('_td_'):
        source = (SHARE/'tdtech.sh').read_text()
    return re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)[0]


class TdTech(unittest.TestCase):
    def test_ndis_cid_is_not_connection_state(self):
        for reply, expected in [
            ('^NDISSTATQRY: 1,1,,,"IPV4",0,,,"IPV6"', 0),
            ('^NDISSTATQRY: 1,0,,,"IPV4",1,,,"IPV6"', 1),
            ('^NDISSTATQRY: 2,1,,,"IPV4"', 1),
            ('^NDISSTATQRY: 1,2,,,"IPV4"', 1),
            ('^NDISSTATQRY: 1', 1), ('ERROR', 1),
        ]:
            with self.subTest(reply=reply):
                result = shell(proto_function('_td_up') + '''
_td_at() { printf '%s\r\n' "$REPLY"; }
_td_up /dev/null
''', dict(os.environ, REPLY=reply))
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_autodial_spelling_and_short_reply(self):
        for reply, expected in [('^SETAUTODIAL: 1,2,"IP"', '1 2\n'),
                                ('^SETAUTODAIL: 1,1', '1 1\n'),
                                ('^SETAUTODIAL: 1', '1 \n'),
                                ('^SETAUTODIAL: 0,1', '0 1\n'), ('ERROR', '')]:
            result = shell(proto_function('_td_autodial') + '''
_td_at() { printf '%s\r\n' "$REPLY"; }
_td_autodial /dev/null
''', dict(os.environ, REPLY=reply))
            self.assertEqual(result.stdout, expected)

    def test_autodial_usb_alignment_is_verified(self):
        for verify, expected in [('1 1', 0), ('1 2', 1), ('', 1)]:
            with tempfile.TemporaryDirectory() as temp:
                result = shell(proto_function('_td_enable_autodial') + '\n' + proto_function('_td_ok') + '''
_td_autodial() { if [ -f "$STATE" ]; then echo "$VERIFY"; else echo '1 2'; fi; }
_td_at() {
 printf '%s\n' "$*" >> "$CALLS"
 case "$*" in
  *SETAUTODIAL=1,1) touch "$STATE"; echo OK ;;
  *CGPADDR*) echo '+CGPADDR: 1,"10.0.0.2"' ;;
 esac
}
_td_up() { return 0; }
ip() { :; }; udhcpc() { :; }; sleep() { :; }
_td_enable_autodial /dev/null
'''.replace('/tmp/5gmodem/ndis_', temp + '/ndis_'),
                    dict(os.environ, STATE=temp+'/state', CALLS=temp+'/calls', VERIFY=verify))
                self.assertEqual(result.returncode, expected, result.stderr)
                commands = Path(temp+'/calls').read_text()
                self.assertIn('AT^SETAUTODIAL=1,1', commands)
                self.assertNotIn('AT+CGDCONT=', commands)

    def test_bootstrap_enables_before_netdev_and_retries(self):
        for failures in (0, 1):
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                dev = base/'usb/devices/1-8'
                dev.mkdir(parents=True)
                (dev/'idVendor').write_text('3466')
                (dev/'idProduct').write_text('3301')
                source = proto_function('_td_bootstrap')
                source = source.replace('/sys/bus/usb', str(base/'usb'))
                source = source.replace('/sys/class/net', str(base/'net'))
                source = source.replace('/usr/share/5gmodem/usbports.sh bind 3466 3301', ':')
                result = shell(source + r'''
sleep() { :; }
_td_pcui() { echo /dev/ttyUSB3; }
_td_registration() { echo 1; }
_td_restore_bands() { return 0; }
_td_enable_autodial() {
 echo enable >> "$CALLS"
 n=$((n+1))
 [ "$n" -gt "$FAILURES" ] || return 1
 mkdir -p "$NET/eth9"
}
_fibocom_netdev() { echo netdev >> "$CALLS"; echo eth9; }
_td_data_ready() { return 0; }
n=0
_td_bootstrap 1-8
rc=$?
echo "result:$rc:$_td_netdev:$_td_port"
exit "$rc"
''', dict(os.environ, CALLS=temp+'/calls', NET=temp+'/net', FAILURES=str(failures)))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('result:0:eth9:/dev/ttyUSB3', result.stdout)
                self.assertEqual((base/'calls').read_text().splitlines(),
                                 ['enable']*(failures+1)+['netdev'])

    def test_autodial_off_programs_context_then_enables_usb(self):
        with tempfile.TemporaryDirectory() as temp:
            source = '\n'.join(proto_function(n) for n in ('_td_enable_autodial', '_td_ok', '_td_autodial'))
            result = shell(source + r'''
_td_at() {
 echo "$2" >> "$CALLS"
 case "$2" in
  'AT^SETAUTODIAL?') if [ -e "$STATE" ]; then echo '^SETAUTODIAL: 1,1'; else echo '^SETAUTODIAL: 0'; fi ;;
  'AT+CGDCONT?') echo '+CGDCONT: 1,"IP","old"' ;;
  'AT^SETAUTODIAL=1,1') touch "$STATE"; echo OK ;;
  *) echo OK ;;
 esac
}
apn=ctnet; pdptype=IPV4V6; auth=none
_td_enable_autodial /dev/null
''', dict(os.environ, CALLS=temp+'/calls', STATE=temp+'/state'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(temp+'/calls').read_text().splitlines(), [
                'AT^SETAUTODIAL?', 'AT+CGDCONT?', 'AT+CGDCONT=1,"IPV4V6","ctnet"',
                'AT^SETAUTODIAL=1,1', 'AT^SETAUTODIAL?'])

    def test_data_readiness_uses_data_cid_and_tolerates_unknown(self):
        for response, expected in [('+CGACT: 1,0\n+CGACT: 2,1', 1),
                                   ('+CGACT: 1,1', 0), ('ERROR', 0)]:
            result = shell(proto_function('_td_data_ready') + r'''
_td_up() { return 1; }
_td_at() { printf '%s\n' "$REPLY"; }
_td_data_ready /dev/null
''', dict(os.environ, REPLY=response))
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_at_busy_never_sends_and_timeout_unlocks(self):
        for busy, expected in [('1', 'lock\n'), ('0', 'lock\nunlock\n')]:
            result = shell(proto_function('_td_at') + r'''
at_lock() { echo lock >&2; [ "$BUSY" = 0 ]; }
at_unlock() { echo unlock >&2; }
timeout() { echo send >&2; return 124; }
_td_at /dev/null AT
''', dict(os.environ, BUSY=busy))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stderr, expected)

    def test_dhcp_children_and_creation_failure(self):
        for protocol, rc in [('dhcp', 0), ('dhcpv6', 0), ('dhcp', 1)]:
            result = shell(proto_function('_td_add_child') + r'''
json_init() { :; }
json_add_string() { echo "string:$*" >&2; }
json_add_boolean() { echo "bool:$*" >&2; }
json_add_int() { echo "int:$*" >&2; }
proto_add_dynamic_defaults() { echo defaults >&2; }
json_dump() { echo '{}'; }
ubus() { return "$UBUS_RC"; }
sourcefilter=0; delegate=1; mtu=1500
_td_add_child modem 6 "$PROTOCOL" wan
''', dict(os.environ, PROTOCOL=protocol, UBUS_RC=str(rc)))
            self.assertEqual(result.returncode, rc)
            self.assertIn('string:ifname @modem', result.stderr)
            self.assertIn('string:zone wan', result.stderr)
            self.assertIn('defaults', result.stderr)
            if protocol == 'dhcpv6':
                self.assertIn('bool:extendprefix 1', result.stderr)
                self.assertIn('string:reqaddress try', result.stderr)

    def test_missing_vendor_netdev_is_bounded_and_roaming_is_blocked(self):
        for roaming in (False, True):
            with tempfile.TemporaryDirectory() as temp:
                base = Path(temp)
                dev = base/'usb/devices/1-8'
                dev.mkdir(parents=True)
                for name, value in [('idVendor', '3466'), ('idProduct', '3301')]:
                    (dev/name).write_text(value)
                iface = base/'usb/devices/1-8:2.0'
                iface.mkdir()
                for name, value in [('bInterfaceClass', 'ff'), ('bInterfaceSubClass', '02'),
                                    ('bInterfaceProtocol', '16')]:
                    (iface/name).write_text(value)
                source = proto_function('_td_bootstrap').replace('/sys/bus/usb', str(base/'usb'))
                source = source.replace('/usr/share/5gmodem/usbports.sh bind 3466 3301', ':')
                result = shell(source + r'''
sleep() { :; }
_td_pcui() { echo /dev/ttyUSB7; }
_td_registration() { echo "$REGISTRATION"; }
_td_restore_bands() { return 0; }
_td_enable_autodial() { echo enable >> "$CALLS"; }
_fibocom_netdev() { return 1; }
allow_roaming=0
_td_bootstrap 1-8
rc=$?
echo "error:$_td_error"
exit "$rc"
''', dict(os.environ, CALLS=temp+'/calls', REGISTRATION='5' if roaming else '1'))
                self.assertEqual(result.returncode, 1, result.stderr)
                if roaming:
                    self.assertIn('error:ROAMING_NOT_ALLOWED', result.stdout)
                    self.assertFalse((base/'calls').exists())
                else:
                    self.assertIn('error:TDTECH_VENDOR_NCM', result.stdout)
                    self.assertEqual((base/'calls').read_text().splitlines(), ['enable']*6)

    def test_setup_uses_live_pdp_for_persistent_dhcp_children(self):
        for pdp, children in [('IP', ['4 dhcp']), ('IPV6', ['6 dhcpv6']),
                              ('IPV4V6', ['4 dhcp', '6 dhcpv6'])]:
            source = proto_function('_td_setup').replace('. /usr/share/5gmodem/atlock.sh', ':')
            result = shell(source + r'''
json_get_vars() { :; }
_td_bootstrap() { _td_port=/dev/ttyUSB7; _td_netdev=eth9; }
_td_at() { printf '+CGDCONT: 1,"%s","ctnet"\n' "$LIVE_PDP"; }
_fibocom_fwzone() { echo wan; }
proto_init_update() { echo "link:$*"; }
proto_send_update() { echo "parent:$*"; }
_td_add_child() { echo "child:$*"; }
_td_setup modem 1-8
''', dict(os.environ, LIVE_PDP=pdp))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('link:eth9 1', result.stdout)
            self.assertEqual([line for line in result.stdout.splitlines() if line.startswith('child:')],
                             ['child:modem '+child+' wan' for child in children])
            self.assertLess(result.stdout.index('parent:modem'), result.stdout.index('child:'))

    def test_replaced_interface_cannot_dial(self):
        result = shell(proto_function('proto_fibocom_setup') + '''
uci() { case "$*" in *modem_swapped) echo 1 ;; esac; }
proto_notify_error() { echo "error:$*"; }
proto_block_restart() { echo "blocked:$*"; }
json_get_vars() { echo should-not-reach >&2; }
proto_fibocom_setup modem
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('error:modem MODEM_SWAPPED', result.stdout)
        self.assertEqual(result.stderr, '')

    def test_netdev_hook_only_starts_enabled_owner(self):
        source = (ROOT / 'root/etc/hotplug.d/net/30-5gmodem-netdev').read_text()
        source = source.replace('. /lib/netifd/netifd-proto.sh;', ':;')
        with tempfile.TemporaryDirectory() as temp:
            source = source.replace('/tmp/5gmodem', temp)
            prefix = '''
uci() {
 case "$*" in
  *'show network') printf "network.modem.proto='fibocom'\\nnetwork.modem2.proto='fibocom'\\n" ;;
  *network.modem.auto) echo 0 ;;
  *network.modem.modem_swapped) echo 1 ;;
  *network.*.device) echo eth4 ;;
 esac
}
ubus() { echo '{}'; }; jsonfilter() { case "$*" in *pending*) echo "$PENDING" ;; esac; }; logger() { :; }
proto_set_available() { :; }
ifup() { echo "$1" >> "$RESULT"; }
'''
            result = shell(prefix+source, dict(os.environ, ACTION='add', INTERFACE='eth4',
                                               RESULT=temp+'/started'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(Path(temp+'/started').read_text(), 'modem2\n')
            Path(temp+'/started').unlink()
            result = shell(prefix+source, dict(os.environ, ACTION='add', INTERFACE='eth4',
                                               RESULT=temp+'/started', PENDING='true'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(Path(temp+'/started').exists())

    def test_usb_configuration_and_live_link_preservation(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            dev = base/'usb/devices/1-8'
            dev.mkdir(parents=True)
            for name, value in {'idVendor':'3466', 'idProduct':'3301',
                                'bConfigurationValue':'1', 'bNumConfigurations':'2', 'devnum':'2'}.items():
                (dev/name).write_text(value)
            source = (SHARE/'usbports.sh').read_text().rsplit('\ncase "$1" in', 1)[0]
            source = source.replace('/sys/bus/usb', str(base/'usb')).replace('/tmp/5gmodem', str(base/'tmp'))
            prefix = 'modprobe() { :; }; logger() { :; }\n'
            result = shell(prefix+source+'\n_td_prepare_usb\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((dev/'bConfigurationValue').read_text().strip(), '2')
            (dev/'bConfigurationValue').write_text('1')
            net = base/'usb/devices/1-8:1.0/net/eth4'
            net.mkdir(parents=True)
            result = shell(prefix+source+'\n_td_prepare_usb\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((dev/'bConfigurationValue').read_text(), '1')

    def test_band_read_requires_complete_response(self):
        source = (SHARE/'modemband/34663301').read_text()
        for reply, expected in [('^LTEFREQLOCK: 0\nOK', '1 3 5 8 34 38 39 40 41\n'),
                                ('^LTEFREQLOCK: 3\n1,2\n3\n41\nOK', '3 41\n'),
                                ('^LTEFREQLOCK: 3\n1,2\n3\nOK', '\n'),
                                ('^LTEFREQLOCK: 3\n1,1\n3', '\n'), ('ERROR', '\n')]:
            result = shell(source + '''
sms_tool() { printf '%s\r\n' "$REPLY"; }
getbands
''', dict(os.environ, REPLY=reply))
            self.assertEqual(result.stdout, expected, result.stderr)

    def test_usb_rescue_does_not_release_configuration_one_serial(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            dev = base/'usb/devices/1-8'
            dev.mkdir(parents=True)
            for key, value in {'idVendor':'3466', 'idProduct':'3301', 'bConfigurationValue':'1'}.items():
                (dev/key).write_text(value)
            driver = base/'usb/drivers/option'
            driver.mkdir(parents=True)
            (driver/'unbind').touch()
            (driver/'remove_id').touch()
            for suffix in ('1.0', '2.0', '2.1', '2.3'):
                iface = base/('usb/devices/1-8:'+suffix)
                iface.mkdir()
                (iface/'bInterfaceClass').write_text('ff')
                (iface/'driver').symlink_to(driver, target_is_directory=True)
            source = (SHARE/'usbports.sh').read_text().rsplit('\ncase "$1" in', 1)[0]
            source = source.replace('/sys/bus/usb', str(base/'usb')).replace('/tmp/5gmodem', str(base/'tmp'))
            result = shell('logger() { :; }\n'+source+'\n_td_rescue_data\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((driver/'unbind').read_text(), '')
            (dev/'bConfigurationValue').write_text('2')
            result = shell('logger() { :; }\n'+source+'\n_td_rescue_data\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((driver/'unbind').read_text().strip(), '1-8:2.1')
            self.assertEqual((driver/'remove_id').read_text().strip(), '3466 3301')

    def test_vendor_ncm_is_offered_to_huawei_driver_with_reference_id(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            dev = base/'usb/devices/1-8'
            dev.mkdir(parents=True)
            for key, value in {'idVendor':'3466', 'idProduct':'3301', 'bConfigurationValue':'2'}.items():
                (dev/key).write_text(value)
            iface = base/'usb/devices/1-8:2.0'
            iface.mkdir()
            for key, value in {'bInterfaceClass':'ff', 'bInterfaceSubClass':'02', 'bInterfaceProtocol':'16'}.items():
                (iface/key).write_text(value)
            driver = base/'usb/drivers/huawei_cdc_ncm'
            driver.mkdir(parents=True)
            (driver/'bind').touch()
            (driver/'new_id').touch()
            source = (SHARE/'usbports.sh').read_text().rsplit('\ncase "$1" in', 1)[0]
            source = source.replace('/sys/bus/usb', str(base/'usb')).replace('/tmp/5gmodem', str(base/'tmp'))
            result = shell('modprobe() { :; }; logger() { echo "$*" >&2; }\n'+source+'\n_td_bind_ncm '+str(iface)+'\n')
            self.assertEqual(result.returncode, 1)
            self.assertEqual((driver/'new_id').read_text().strip(), '3466 3301 ff 12d1 0')
            self.assertEqual((driver/'bind').read_text().strip(), '1-8:2.0')
            self.assertIn('did not bind', result.stderr)
            (iface/'bInterfaceSubClass').write_text('06')
            (driver/'new_id').write_text('')
            result = shell('modprobe() { :; }; logger() { :; }\n'+source+'\n_td_bind_ncm '+str(iface)+'\n')
            self.assertEqual(result.returncode, 1)
            self.assertEqual((driver/'new_id').read_text(), '')

    def test_band_write_validates_and_formats_lists(self):
        source = (SHARE/'modemband/34663301').read_text()
        for bands, expected in [('3 41', 'AT^LTEFREQLOCK=3,1,2,"3,41"'),
                                ('default', 'AT^LTEFREQLOCK=0'), ('3;reboot', None), ('', None)]:
            with tempfile.TemporaryDirectory() as temp:
                result = shell(source + '''
sms_tool() { printf '%s\n' "$4" > "$CALL"; echo OK; }
setbands "$BANDS"
''', dict(os.environ, BANDS=bands, CALL=temp+'/call'))
                if expected:
                    self.assertEqual(Path(temp+'/call').read_text().strip(), expected)
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertFalse(Path(temp+'/call').exists())
                    self.assertNotEqual(result.returncode, 0)

    def test_nr_lock_and_mode_preserve_other_settings(self):
        source = (SHARE/'modemband/34663301').read_text()
        with tempfile.TemporaryDirectory() as temp:
            result = shell(source + '''
sms_tool() {
 printf '%s\n' "$4" >> "$CALLS"
 case "$4" in
  'AT^SYSCFGEX?') printf '^SYSCFGEX: "080302",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,\r\nOK\r\n' ;;
  *) echo OK ;;
 esac
}
setbands5gnsa '41 78'
setmode 4
''', dict(os.environ, CALLS=temp+'/calls'))
            self.assertEqual(result.returncode, 0, result.stderr)
            calls = Path(temp+'/calls').read_text()
            self.assertIn('AT^NRFREQLOCK=3,1,2,"41,78"', calls)
            self.assertIn('AT^SYSCFGEX="03",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,', calls)

    def test_nr_neighbors_use_hex_pci_and_filter_sentinels(self):
        result = subprocess.run(['busybox', 'awk', '-F[:,]', '-v', 'kind=neighbors',
                                 '-f', str(SHARE/'tdtech-cells.awk')], text=True, capture_output=True,
                                input='^MONNC: LTE,1300,25,-98,-10,-72\n'
                                      '^MONNC: NR,504990,1F3,-1256,-348,-188\n')
        got = json.loads('['+result.stdout+']')
        self.assertEqual(got[0]['pci'], '25')
        self.assertEqual(got[1]['pci'], '499')
        self.assertEqual(got[1]['rsrp'], '')
        self.assertEqual(got[1]['sinr'], '')

    def test_sms_uses_literal_separator_and_requires_acknowledgment(self):
        for response, expected in [('+CMGS: 17\r\nOK', 0), ('+CMS ERROR: 500', 1), ('', 4)]:
            with tempfile.TemporaryDirectory() as temp:
                result = shell(function('_td_sms_submit', 'smsbridge.sh') + '''
_smstool_at() { echo sms_tool; }
_sms_run() {
 printf '%s\n' "$*" >> "$CALLS"
 case "$*" in *CMGF*) echo OK ;; *) printf '%s\n' "$REPLY" ;; esac
}
_td_sms_submit "$PORT" 19 00110000
''', dict(os.environ, CALLS=temp+'/calls', PORT=temp+'/port', REPLY=response))
                self.assertEqual(result.returncode, expected, result.stderr)
                sent = Path(temp+'/calls').read_bytes()
                self.assertIn(b'AT+CMGS=19\\r00110000', sent)
                self.assertNotIn(b'\x1a', sent)

    def test_ambiguous_sms_cannot_fall_back_to_generic_send(self):
        result = shell(function('_send_one', 'smsbridge.sh') + '''
_port_is_mm() { return 1; }; _port_proxy_mm() { return 1; }
_send_pdu() { return 4; }; _sms_tdtech() { return 0; }
_sms_run() { echo unexpected-send >&2; }
_send_one /dev/null +123 test
''')
        self.assertEqual(result.returncode, 4)
        self.assertEqual(result.stderr, '')

    def test_queued_unknown_is_preserved_without_retry(self):
        source = (SHARE/'smsbridge.sh').read_text()
        source = source[source.index('_q_send_one() {'):source.index('\n_send_pdu() {')]
        with tempfile.TemporaryDirectory() as temp:
            entry = Path(temp)/'test.sms'
            entry.write_text('to=+123\nport=/dev/null\ntries=0\nborn=0\ntext:\nhello\n')
            result = shell(source + '''
_norm_num() { echo "$1"; }; _send_one() { return 4; }; logger() { :; }
SMSQ_MAX_TRIES=10; SMSQ_MAX_AGE=86400
_q_send_one "$ENTRY"
''', dict(os.environ, ENTRY=str(entry)))
            self.assertEqual(result.returncode, 4, result.stderr)
            self.assertFalse(entry.exists())
            self.assertIn('hello', entry.with_suffix('.unknown').read_text())

    def test_partial_multipart_is_not_restarted(self):
        with tempfile.TemporaryDirectory() as temp:
            encoder = Path(temp)/'smspdu.sh'
            encoder.write_text('#!/bin/sh\nprintf "19 00110000\\n19 00110001\\n"\n')
            encoder.chmod(0o755)
            result = shell(function('_send_pdu', 'smsbridge.sh') + '''
_port_is_mm() { return 1; }; at_lock() { return 0; }
_sms_tdtech() { return 0; }
_td_sms_submit() { n=$((n+1)); [ "$n" = 1 ]; }
n=0
_send_pdu /dev/null +123 text
''', dict(os.environ, RES=temp))
            self.assertEqual(result.returncode, 4, result.stderr)


if __name__ == '__main__':
    unittest.main()
