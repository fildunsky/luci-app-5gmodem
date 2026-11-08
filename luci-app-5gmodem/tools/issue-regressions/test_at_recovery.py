import os
from pathlib import Path
import tempfile
import time
import unittest

from test_runtime_audit import SHARE, shell, function


class AtRecovery(unittest.TestCase):
    def fixture(self, temp, vid='0e8d', number='06', state='D', proto='fibocom'):
        base=Path(temp)
        usb=base/'usb/2-1.4'; iface=usb/'2-1.4:1.6'; iface.mkdir(parents=True)
        for key,value in [('idVendor',vid),('idProduct','7127'),('devnum','3')]: (usb/key).write_text(value)
        (iface/'bInterfaceNumber').write_text(number)
        driver=base/'drivers/option';driver.mkdir(parents=True)
        for name in ('bind','unbind'):(driver/name).touch()
        (iface/'driver').symlink_to(driver,target_is_directory=True)
        tty=base/'tty/ttyUSB3';tty.mkdir(parents=True);(tty/'device').symlink_to(iface,target_is_directory=True)
        proc=base/'proc/10875';proc.mkdir(parents=True)
        (proc/'comm').write_text('sms_tool\n')
        (proc/'stat').write_text(' '.join(['10875','(sms_tool)',state]+['0']*18+['100']))
        (proc/'cmdline').write_bytes(b'sms_tool\0-d\0/dev/ttyUSB3\0at\0AT+CGACT?\0')
        (base/'proc/uptime').write_text('100.00 50.00')
        (base/'atlock.sh').write_text('at_long_busy() { [ "$LONG" = 1 ]; }\n')
        source=(SHARE/'at-recover.sh').read_text().replace('RES=/usr/share/5gmodem','RES='+temp)
        source=source.replace('RUN=/tmp/5gmodem','RUN='+temp+'/run').replace('/sys/class/tty',temp+'/tty').replace('/proc/',temp+'/proc/')
        source='''
uci() { case "$*" in *5gmodem.*.network) echo modem ;; *network.modem.proto) echo "$PROTOCOL" ;; esac; }
logger() { echo "$*" >> "$LOG"; }
sleep() { :; }
'''+source
        env=dict(os.environ,PROTOCOL=proto,LOG=temp+'/log')
        return base,driver,source,env

    def run_helper(self, source,env):
        result=shell('set -- /dev/ttyUSB3\n'+source,env)
        self.assertEqual(result.returncode,0,result.stderr)
        return result

    def test_confirmed_stall_rebinds_only_serial_interface_with_cooldown_and_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')
            (base/'proc/uptime').write_text('131.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'2-1.4:1.6')
            self.assertEqual((driver/'bind').read_text(),'2-1.4:1.6')
            count=(base/'log').read_text().count('attempt')
            (base/'proc/uptime').write_text('140.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((base/'log').read_text().count('attempt'),count)
            (base/'run/atrecover_m_2_1_4.attempt').write_text('3 140 3\n')
            (base/'proc/uptime').write_text('1000.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((base/'log').read_text().count('attempt'),count)

    def test_other_modems_interfaces_normal_workers_and_mm_are_untouched(self):
        for kwargs in ({'vid':'1234'},{'number':'03'},{'state':'S'},{'proto':'modemmanager'}):
            with self.subTest(kwargs=kwargs),tempfile.TemporaryDirectory() as temp:
                base,driver,source,env=self.fixture(temp,**kwargs)
                self.run_helper(source,env)
                (base/'proc/uptime').write_text('140.00 50.00')
                self.run_helper(source,env)
                self.assertEqual((driver/'unbind').read_text(),'')

    def test_long_at_operation_prevents_rebinding(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            self.run_helper(source,env)
            (base/'proc/uptime').write_text('140.00 50.00')
            env['LONG']='1'
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_changed_usb_incarnation_needs_new_confirmation(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            self.run_helper(source,env)
            (base/'proc/uptime').write_text('140.00 50.00')
            (base/'usb/2-1.4/devnum').write_text('4')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_worker_on_another_port_cannot_trigger_rebind(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            (base/'proc/10875/cmdline').write_bytes(b'sms_tool\0-d\0/dev/ttyUSB1\0at\0AT+CGACT?\0')
            self.run_helper(source,env)
            (base/'proc/uptime').write_text('140.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_reused_pid_must_earn_a_new_confirmation_window(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            self.run_helper(source,env)
            (base/'proc/10875/stat').write_text(' '.join(['10875','(sms_tool)','D']+['0']*18+['200']))
            (base/'proc/uptime').write_text('140.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_background_recovery_inherits_no_lock_descriptors(self):
        with tempfile.TemporaryDirectory() as temp:
            program=Path(temp)/'at-recover.sh'
            program.write_text('''#!/bin/sh
printf '%s\\n' "${_AT_LOCK_HELD-unset}" > "$RESULT"
for fd in 7 8 9; do
 if [ -e /proc/self/fd/$fd ]; then echo inherited; else echo closed; fi >> "$RESULT"
done
''')
            program.chmod(0o755)
            result=shell(function('_at_recover','atlock.sh')+r'''
exec 7>"$LOCK"; exec 8>"$LOCK"; exec 9>"$LOCK"
export _AT_LOCK_HELD=ttyUSB3
_at_recover /dev/ttyUSB3
''',dict(os.environ,RES=temp,LOCK=temp+'/lock',RESULT=temp+'/result'))
            self.assertEqual(result.returncode,0,result.stderr)
            deadline=time.monotonic()+2
            expected='unset\nclosed\nclosed\nclosed\n'
            output=Path(temp)/'result'
            while time.monotonic()<deadline:
                if output.exists() and output.read_text()==expected:break
                time.sleep(0.01)
            self.assertEqual(output.read_text(),expected)

    def test_nested_tty_layout_resolves_the_usb_interface(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            tty=base/'tty/ttyUSB3/device'
            tty.unlink()
            nested=base/'usb/2-1.4/2-1.4:1.6/tty/ttyUSB3'
            nested.mkdir(parents=True)
            tty.symlink_to(nested,target_is_directory=True)
            self.run_helper(source,env)
            (base/'proc/uptime').write_text('140.00 50.00')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'2-1.4:1.6')
