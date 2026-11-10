import os
from pathlib import Path
import tempfile
import unittest

from test_runtime_audit import function, shell

FUNCTIONS = ('huawei_ncm_module', 'vendor_ncm_ifaces', 'usbcomp_verdict', '_sum_verdict')


class Sysfs:
    def __init__(self, root):
        self.root = Path(root)
        self.usb = self.root / 'usb'
        self.res = self.root / 'res'
        self.usb.mkdir()
        self.res.mkdir()
        (self.res / 'listmodems.sh').write_text('#!/bin/sh\necho \'[{"path":"1-8","model":"TD Tech MT5700M-CN"}]\'\n')
        (self.res / 'usbports.sh').write_text('#!/bin/sh\nexit 0\n')
        for script in self.res.iterdir():
            script.chmod(0o755)
        (self.root / 'drivers').mkdir()

    def write(self, relative, text=''):
        path = self.usb / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def modem(self, vendor_ncm=True, driver=None, net=False):
        self.write('1-8/idVendor', '3466\n')
        self.write('1-8/idProduct', '3301\n')
        self.write('1-8:2.2/ttyUSB2/dev')
        if vendor_ncm:
            self.write('1-8:2.0/bInterfaceClass', 'ff\n')
            self.write('1-8:2.0/bInterfaceSubClass', '02\n')
            self.write('1-8:2.0/bInterfaceProtocol', '16\n')
            self.write('1-8:2.0/bNumEndpoints', '01\n')
            if driver:
                target = self.root / 'drivers' / driver
                target.mkdir(exist_ok=True)
                (self.usb / '1-8:2.0/driver').symlink_to(target)
        else:
            self.write('1-8:2.0/bInterfaceClass', 'ff\n')
            self.write('1-8:2.0/bInterfaceSubClass', '06\n')
            self.write('1-8:2.0/bInterfaceProtocol', '13\n')
            self.write('1-8:2.0/bNumEndpoints', '02\n')
        if net:
            self.write('1-8:2.0/net/eth4/address', '02:00:00:00:00:01\n')

    def module(self):
        path = self.root / 'modules/6.12.112/huawei_cdc_ncm.ko'
        path.parent.mkdir(parents=True)
        path.write_text('')

    def run(self, command):
        body = '\n'.join(function(name, 'collect.sh') for name in FUNCTIONS)
        body = (body.replace('/sys/bus/usb/devices', str(self.usb))
                .replace('/sys/module/huawei_cdc_ncm', str(self.root / 'nomod'))
                .replace('/sys/bus/usb/drivers/huawei_cdc_ncm', str(self.root / 'nodrv'))
                .replace('/lib/modules/*/huawei_cdc_ncm.ko*', str(self.root / 'modules/*/huawei_cdc_ncm.ko*')))
        source = f'''
RES={self.res}
uci() {{ :; }}
ubus() {{ :; }}
ip() {{ :; }}
sleep() {{ :; }}
jsonfilter() {{ case "$*" in *model*) echo 'TD Tech MT5700M-CN' ;; *) echo 1-8 ;; esac; }}
{body}
{command}
'''
        result = shell(source)
        self.last = result
        return result.stdout + result.stderr


class CollectNcmVerdict(unittest.TestCase):
    def check(self, **kwargs):
        run = kwargs.pop('run', 'usbcomp_verdict')
        module = kwargs.pop('module', False)
        with tempfile.TemporaryDirectory() as temp:
            sysfs = Sysfs(temp)
            sysfs.modem(**kwargs)
            if module:
                sysfs.module()
            output = sysfs.run(run)
            self.assertEqual(sysfs.last.returncode, 0, output)
            return output

    def test_vendor_ncm_without_the_kernel_module_names_the_package(self):
        output = self.check()
        self.assertIn('CAUSE FOUND', output)
        self.assertIn('interface 0 (vendor NCM, class ff/02/16): no driver', output)
        self.assertIn('huawei_cdc_ncm, is NOT installed', output)
        self.assertIn('apk add kmod-usb-net-huawei-cdc-ncm', output)
        self.assertIn('opkg install kmod-usb-net-huawei-cdc-ncm', output)
        self.assertNotIn('Switch the modem to a', output)

    def test_installed_module_that_did_not_bind_points_to_rescue_instead(self):
        output = self.check(module=True)
        self.assertIn('CAUSE FOUND', output)
        self.assertIn('is installed, so it did not bind', output)
        self.assertIn('usbports.sh rescue', output)
        self.assertNotIn('NOT installed', output)
        self.assertNotIn('Switch the modem to a', output)

    def test_interface_held_by_a_serial_driver_is_reported_as_such(self):
        output = self.check(driver='option')
        self.assertIn('held by serial driver option', output)
        self.assertIn('NOT installed', output)

    def test_other_compositions_keep_the_generic_advice(self):
        output = self.check(vendor_ncm=False)
        self.assertNotIn('CAUSE FOUND', output)
        self.assertNotIn('huawei_cdc_ncm', output)
        self.assertIn('Switch the modem to a', output)

    def test_modem_with_a_network_device_is_not_flagged(self):
        output = self.check(net=True)
        self.assertIn('no - every modem with an AT port has its data channel', output)
        self.assertNotIn('huawei_cdc_ncm', output)

    def test_summary_at_the_top_of_the_report_names_the_missing_module(self):
        output = self.check(run='_sum_verdict')
        self.assertIn('NO DATA CHANNEL: 1-8', output)
        self.assertIn('module huawei_cdc_ncm is not installed', output)
        self.assertIn('apk add kmod-usb-net-huawei-cdc-ncm', output)

    def test_summary_keeps_the_generic_text_when_the_module_exists_or_there_is_no_vendor_ncm(self):
        for kwargs in ({'module': True}, {'vendor_ncm': False}):
            with self.subTest(kwargs=kwargs):
                output = self.check(run='_sum_verdict', **kwargs)
                self.assertIn('NO DATA CHANNEL: 1-8 - neither cdc-wdm nor a network', output)
                self.assertNotIn('is not installed', output)


if __name__ == '__main__':
    unittest.main()
