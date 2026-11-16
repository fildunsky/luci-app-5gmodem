"""PCIe modems on generic MHI: protocol by the bound data endpoint, control port of the same type."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'root/usr/share/5gmodem/lib.sh').read_text()


def fn(name):
    match = re.search(r'^' + re.escape(name) + r'\(\) \{\n.*?^\}$', LIB, re.M | re.S)
    return match[0] + '\n'


FUNCS = ''.join(fn(n) for n in ('_pci_root', 'pci_data_netdev', 'pci_data_proto', 'pci_ctl_node'))
PCI = '0000:05:00.0'


class Sysfs:
    def __init__(self, root):
        self.root = Path(root)
        self.dev = self.root / 'devices/pci0000:00' / PCI
        self.dev.mkdir(parents=True)
        (self.root / 'bus/pci/devices').mkdir(parents=True)
        os.symlink(self.dev, self.root / 'bus/pci/devices' / PCI)
        (self.root / 'class/net').mkdir(parents=True)
        (self.root / 'class/wwan').mkdir(parents=True)
        (self.root / 'drivers').mkdir()

    def driver(self, name):
        d = self.root / 'drivers' / name
        d.mkdir(exist_ok=True)
        return d

    def channel(self, name, driver=None, netdev=None):
        ch = self.dev / 'mhi0' / ('mhi0_' + name)
        ch.mkdir(parents=True)
        if driver:
            os.symlink(self.driver(driver), ch / 'driver')
        if netdev:
            (ch / 'net' / netdev).mkdir(parents=True)
            os.symlink(ch, ch / 'net' / netdev / 'device')
            os.symlink(ch / 'net' / netdev, self.root / 'class/net' / netdev)
        return ch

    def port(self, name, ptype, parent=None):
        base = (parent or self.dev / 'mhi0') / 'wwan' / 'wwan0'
        (base / name).mkdir(parents=True)
        (base / name / 'type').write_text(ptype + '\n')
        os.symlink(base, base / name / 'device')
        os.symlink(base / name, self.root / 'class/wwan' / name)


def run(root, script):
    return subprocess.run(['busybox', 'ash', '-c', FUNCS + script], text=True, capture_output=True,
                          timeout=15, env=dict(os.environ, PCI_SYSFS=str(root))).stdout.strip()


class PciMhi(unittest.TestCase):
    def test_qmi_path_skips_the_software_channel(self):
        with tempfile.TemporaryDirectory() as temp:
            s = Sysfs(temp)
            s.channel('IP_HW0', 'mhi_net', 'mhi_hwip0')
            s.channel('IP_SW0', 'mhi_net', 'mhi_swip0')
            s.port('wwan0mbim0', 'MBIM')
            s.port('wwan0qmi0', 'QMI')
            s.port('wwan0qcdm0', 'QCDM')
            self.assertEqual(run(temp, f'pci_data_netdev {PCI}'), 'mhi_hwip0')
            self.assertEqual(run(temp, f'pci_data_proto {PCI}'), 'qmi')
            # an MBIM control port exists and sorts first, the data path still decides
            self.assertEqual(run(temp, f'pci_ctl_node {PCI} qmi'), '/dev/wwan0qmi0')

    def test_native_mbim_link(self):
        with tempfile.TemporaryDirectory() as temp:
            s = Sysfs(temp)
            s.channel('IP_HW0_MBIM', 'mhi_wwan_mbim', 'wwan0')
            s.port('wwan0mbim0', 'MBIM')
            s.port('wwan0at0', 'AT')
            self.assertEqual(run(temp, f'pci_data_proto {PCI}'), 'mbim')
            self.assertEqual(run(temp, f'pci_ctl_node {PCI} mbim'), '/dev/wwan0mbim0')
            self.assertEqual(run(temp, f'pci_ctl_node {PCI} at'), '/dev/wwan0at0')

    def test_mbim_channel_without_its_own_netdev(self):
        with tempfile.TemporaryDirectory() as temp:
            s = Sysfs(temp)
            s.channel('IP_HW0_MBIM', 'mhi_wwan_mbim')
            self.assertEqual(run(temp, f'pci_data_proto {PCI}'), 'mbim')

    def test_two_endpoints_or_none_are_not_guessed(self):
        with tempfile.TemporaryDirectory() as temp:
            s = Sysfs(temp)
            self.assertEqual(run(temp, f'pci_data_proto {PCI}; echo rc=$?'), 'rc=1')
            s.channel('IP_HW0', 'mhi_net', 'mhi_hwip0')
            s.channel('IP_HW1', 'mhi_net', 'mhi_hwip1')
            self.assertEqual(run(temp, f'pci_data_netdev {PCI}; echo rc=$?'), 'rc=1')

    def test_port_of_another_device_is_ignored(self):
        with tempfile.TemporaryDirectory() as temp:
            s = Sysfs(temp)
            other = s.root / 'devices/pci0000:00/0000:06:00.0/mhi1'
            s.port('wwan1qmi0', 'QMI', other)
            self.assertEqual(run(temp, f'pci_ctl_node {PCI} qmi; echo rc=$?'), 'rc=1')

    def test_wiring(self):
        share = ROOT / 'root/usr/share/5gmodem'
        mk = (share / 'mkiface.sh').read_text()
        self.assertIn('MKI_PCI_PROTO=$(pci_data_proto "$AMP")', mk)
        self.assertIn('[ -f /lib/netifd/proto/qmiraw.sh ] && PROTO="qmiraw"', mk)
        self.assertIn('ifname=$(pci_data_netdev "$mhi_pci")', (ROOT / 'root/lib/netifd/proto/qmiraw.sh').read_text())
        lm = (share / 'listmodems.sh').read_text()
        self.assertIn('MBIM:*|QMI:*|:*)', lm)
        self.assertIn('pci_data_netdev "${_pnode##*/}"', lm)
        self.assertIn('assoc_usb', (share / 'registry.sh').read_text())


if __name__ == '__main__':
    unittest.main()
