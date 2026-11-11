import json
from pathlib import Path
import re
import tempfile
import unittest

from test_runtime_audit import SHARE, function, shell


def rewrite(text, root):
    """Point a script at a fake /sys, /dev and share directory."""
    text = text.replace('/sys/', f'{root}/sys/')
    text = re.sub(r'/dev/(tty|cdc-wdm|wwan)', rf'{root}/dev/\1', text)
    return text.replace('/tmp/5gmodem', f'{root}/tmp').replace('/usr/share/5gmodem', f'{root}/share')


class Stand:
    """A USB device 1-1 on a fake sysfs, in the shape Linux exposes it."""

    def __init__(self, root, vendor='04e8', product='6862'):
        self.root = Path(root)
        self.usb = self.root / 'sys/devices/pci0/usb1/1-1'
        self.usb.mkdir(parents=True)
        for name, value in (('idVendor', vendor), ('idProduct', product), ('product', 'SAMSUNG_Android'), ('serial', 'R5CTEST0001')):
            (self.usb / name).write_text(value + '\n')
        for sub in ('sys/bus/usb/devices', 'sys/class/net', 'sys/class/tty', 'dev', 'tmp', 'share', 'drivers'):
            (self.root / sub).mkdir(parents=True, exist_ok=True)
        (self.root / 'sys/bus/usb/devices/1-1').symlink_to(self.usb)

    def interface(self, number, klass, sub, proto, driver=None):
        path = self.usb / f'1-1:1.{number}'
        path.mkdir()
        for name, value in (('bInterfaceClass', klass), ('bInterfaceSubClass', sub), ('bInterfaceProtocol', proto)):
            (path / name).write_text(value + '\n')
        (self.root / f'sys/bus/usb/devices/1-1:1.{number}').symlink_to(path)
        if driver:
            target = self.root / 'drivers' / driver
            target.mkdir(exist_ok=True)
            (path / 'driver').symlink_to(target)
        return path

    def rndis(self):
        path = self.interface(0, 'e0', '01', '03', 'rndis_host')
        net = path / 'net/usb0'
        net.mkdir(parents=True)
        (net / 'device').symlink_to(path)
        (self.root / 'sys/class/net/usb0').symlink_to(net)

    def acm(self):
        path = self.interface(2, '02', '02', '01', 'cdc_acm')
        tty = path / 'tty/ttyACM0'
        tty.mkdir(parents=True)
        (tty / 'device').symlink_to(path)
        (self.root / 'sys/class/tty/ttyACM0').symlink_to(tty)
        (self.root / 'dev/ttyACM0').write_text('')

    def serial(self):
        path = self.interface(3, 'ff', 'ff', 'ff', 'option')
        tty = path / 'ttyUSB0'
        tty.mkdir()
        (tty / 'device').symlink_to(path)
        (self.root / 'sys/class/tty/ttyUSB0').symlink_to(tty)
        (self.root / 'dev/ttyUSB0').write_text('')

    def adb(self):
        self.interface(5, 'ff', '42', '01')

    def samsung(self):
        self.rndis()
        self.interface(1, '0a', '00', '00', 'rndis_host')
        self.acm()
        self.adb()

    def listmodems(self, uci_show=''):
        for name in ('lib.sh', 'notmodem.sh'):
            (self.root / 'share' / name).write_text(rewrite((SHARE / name).read_text(), self.root))
        script = rewrite((SHARE / 'listmodems.sh').read_text(), self.root)
        result = shell("uci() { case \"$*\" in '-q show 5gmodem') printf '%s' \"$UCI_SHOW\" ;; esac; }\n" + script,
                       {'UCI_SHOW': uci_show, 'PATH': '/usr/bin:/bin'})
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    def run(self, body, *functions):
        names = [(n, f) for f, names in functions for n in names]
        source = '\n'.join(function(n, f).replace('/sys/bus/usb/devices', f'{self.root}/sys/bus/usb/devices') for n, f in names)
        return shell(source + '\n' + body)


LIB = ('lib.sh', ('android_vid', 'known_modem_path', 'android_phone_path', 'usb_gadget_vid', 'tether_cdc_vid'))
HILINK = ('msw/hilink.sh', ('is_tether', 'tether_def_metric'))
IS_TETHER = ('is_iphone() { return 1; }\nsecname() { echo m_1_1; }\nhilink_netdev() { echo usb0; }\nCFG=5gmodem\nuci() { :; }\n')


class SamsungComposition(unittest.TestCase):
    """A Samsung phone shares USB tethering and a CDC-ACM service port; it is a phone, not an AT modem."""

    def stand(self, **kwargs):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        return Stand(temp.name, **kwargs)

    def test_a_phone_with_an_acm_port_is_still_listed_as_a_tether_with_its_network_device(self):
        stand = self.stand()
        stand.samsung()
        records = stand.listmodems()
        self.assertEqual(len(records), 1, records)
        self.assertEqual(records[0]['path'], '1-1')
        self.assertEqual(records[0]['net'], ['usb0'])
        self.assertEqual(records[0]['tty'], [], 'the ACM port is not an AT port of a modem')

    def test_the_same_phone_is_marked_as_an_android_tether_once_it_has_a_section(self):
        stand = self.stand()
        stand.samsung()
        records = stand.listmodems("5gmodem.m_1_1=modem\n5gmodem.m_1_1.kind='tether'\n")
        self.assertEqual(records[0]['tether'], 'android')
        self.assertEqual(records[0]['tether_state'], 'ready')

    def test_a_modem_with_the_same_interfaces_keeps_its_ports(self):
        # Not an Android vendor: the ACM port is its AT port.
        stand = self.stand(vendor='1234', product='0001')
        stand.samsung()
        records = stand.listmodems()
        self.assertEqual(records[0]['tty'], [f'{stand.root}/dev/ttyACM0'])
        # An Android vendor with a real serial (option) port is a baseband, not a plain phone.
        stand = self.stand()
        stand.rndis()
        stand.serial()
        records = stand.listmodems()
        self.assertEqual(records[0]['tty'], [f'{stand.root}/dev/ttyUSB0'])

    def test_phone_detection_needs_android_vendor_tethering_and_no_serial_ports(self):
        stand = self.stand()
        stand.samsung()
        self.assertEqual(stand.run('android_phone_path 1-1', LIB).returncode, 0)
        self.assertNotEqual(stand.run('android_phone_path 1-2', LIB).returncode, 0)
        other = self.stand(vendor='1234')
        other.samsung()
        self.assertNotEqual(other.run('android_phone_path 1-1', LIB).returncode, 0)
        known = self.stand(vendor='2c7c', product='0801')
        known.samsung()
        self.assertNotEqual(known.run('android_phone_path 1-1', LIB).returncode, 0)
        serial = self.stand()
        serial.rndis()
        serial.serial()
        self.assertNotEqual(serial.run('android_phone_path 1-1', LIB).returncode, 0)
        mtp = self.stand()
        mtp.interface(0, '06', '01', '01')
        mtp.acm()
        self.assertNotEqual(mtp.run('android_phone_path 1-1', LIB).returncode, 0, 'no tethering function')

    def test_setup_treats_the_phone_as_a_tether_although_it_has_an_acm_port(self):
        stand = self.stand()
        stand.samsung()
        self.assertEqual(stand.run(IS_TETHER + 'is_tether 1-1', LIB, HILINK).returncode, 0)
        other = self.stand(vendor='1234', product='0001')
        other.samsung()
        self.assertNotEqual(other.run(IS_TETHER + 'is_tether 1-1', LIB, HILINK).returncode, 0)


class PhoneModeChange(unittest.TestCase):
    """A phone changes its product id with its USB mode (MTP, tethering, debugging); it stays an Android tether."""

    def swap(self, keys, new='04e8:6864', live_os='android'):
        with tempfile.TemporaryDirectory() as store:
            for key, value in keys.items():
                Path(store, f'5gmodem.m_1_1.{key}').write_text(value)
            source = ('CFG=5gmodem\n'
                      'uci() { [ "$1" = -q ] && shift; case "$1" in\n'
                      '  get) cat "$ST/$2" 2>/dev/null ;;\n'
                      '  set) printf "%s" "${2#*=}" > "$ST/${2%%=*}" ;;\n'
                      '  delete) rm -f "$ST/$2" ;;\n'
                      'esac; }\n'
                      'modem_vidpid() { echo "$NEW"; }\nmodem_product() { echo SAMSUNG_Android; }\n'
                      'purge_path_caches() { :; }\nlogger() { :; }\ntether_os() { echo "$LIVE_OS"; }\n'
                      + function('swap_cleanup', 'msw/identity.sh') + '\nswap_cleanup 1-1 m_1_1\n')
            result = shell(source, {'ST': store, 'NEW': new, 'LIVE_OS': live_os, 'PATH': '/usr/bin:/bin'})
            self.assertEqual(result.returncode, 0, result.stderr)
            return {p.name.split('.')[-1]: p.read_text() for p in Path(store).iterdir()}

    def test_a_tether_keeps_its_kind_netdev_and_android_key_when_its_product_id_changes(self):
        for tether in ('android', ''):
            with self.subTest(tether=tether):
                keys = {'vidpid': '04e8:6862', 'kind': 'tether', 'netdev': 'usb0', 'at_port': '/dev/ttyACM0'}
                if tether:
                    keys['tether'] = tether
                after = self.swap(keys)
                self.assertEqual(after['vidpid'], '04e8:6864')
                self.assertEqual(after['kind'], 'tether')
                self.assertEqual(after['tether'], 'android')
                self.assertEqual(after['netdev'], 'usb0')
                self.assertNotIn('at_port', after)

    def test_other_same_vendor_mode_changes_drop_the_tether_properties_as_before(self):
        after = self.swap({'vidpid': '2c7c:0800', 'kind': 'hilink', 'tether': 'phone', 'netdev': 'eth1'}, new='2c7c:0801')
        self.assertEqual(after['vidpid'], '2c7c:0801')
        self.assertNotIn('tether', after)
        self.assertNotIn('netdev', after)


class TetherMetric(unittest.TestCase):
    """A new phone interface goes after the uplinks the router already has, so it never takes the default route."""

    def metric(self, interface, networks, metrics):
        stub = ('uci() { case "$*" in\n'
                "  '-q show firewall') echo \"firewall.cfg1.name='wan'\" ;;\n"
                "  '-q get firewall.cfg1.network') echo \"$NETWORKS\" ;;\n"
                "  '-q get network.'*.metric) n=${*#-q get network.}; n=${n%.metric}; eval \"echo \\\"\\$M_$n\\\"\" ;;\n"
                'esac; }\n')
        env = {'NETWORKS': ' '.join(networks), 'PATH': '/usr/bin:/bin'}
        env.update({f'M_{k}': str(v) for k, v in metrics.items()})
        result = shell(stub + function('tether_def_metric', 'msw/hilink.sh') + f'\ntether_def_metric {interface}', env)
        return result.stdout.strip()

    def test_the_phone_is_placed_after_the_last_uplink(self):
        self.assertEqual(self.metric('modem2', ['wan', 'wan6', 'modem'], {'wan': 100, 'wan6': 120, 'modem': 110}), '130')
        self.assertEqual(self.metric('modem', ['wan', 'wan6', 'modem'], {'wan': 100, 'wan6': 120, 'modem': 110}), '130')

    def test_without_other_metrics_the_historical_value_is_kept(self):
        self.assertEqual(self.metric('modem', ['wan', 'modem'], {}), '20')
        self.assertEqual(self.metric('modem', ['wan', 'modem'], {'wan': 0}), '20')
        self.assertEqual(self.metric('modem', [], {}), '20')


if __name__ == '__main__':
    unittest.main()
