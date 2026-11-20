import os
from pathlib import Path
import subprocess
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
ls() { busybox ls "$@"; }
sleep() {
	[ "$1" = 30 ] || return 0
	: > "$FIXTURE/checking"
	if [ -e "$FIXTURE/hold" ]; then
		while [ ! -e "$FIXTURE/resume" ]; do busybox sleep 0.01; done
	fi
	awk '{printf "%.2f %s", $1 + 30, $2}' "$FIXTURE/proc/uptime" > "$FIXTURE/uptime"
	mv "$FIXTURE/uptime" "$FIXTURE/proc/uptime"
	if [ -f "$FIXTURE/during-wait.sh" ]; then . "$FIXTURE/during-wait.sh"; fi
}
'''+source
        env=dict(os.environ,PROTOCOL=proto,LOG=temp+'/log',FIXTURE=temp)
        return base,driver,source,env

    def run_helper(self, source,env,returncode=0):
        result=shell('set -- /dev/ttyUSB3\n'+source,env)
        self.assertEqual(result.returncode,returncode,result.stderr)
        return result

    def test_confirmed_stall_rebinds_only_serial_interface_with_cooldown_and_limit(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'2-1.4:1.6')
            self.assertEqual((driver/'bind').read_text(),'2-1.4:1.6')
            self.assertIn('checking again in 30s',(base/'log').read_text())
            self.assertEqual((base/'run/atrecover_m_2_1_4.attempt').read_text(),'3 130 1\n')
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
                self.assertEqual((driver/'unbind').read_text(),'')
                self.assertFalse((base/'checking').exists())

    def test_long_at_operation_prevents_rebinding(self):
        for hook in (None, 'LONG=1\n'):
            with self.subTest(hook=hook),tempfile.TemporaryDirectory() as temp:
                base,driver,source,env=self.fixture(temp)
                if hook is None:
                    env['LONG']='1'
                else:
                    (base/'during-wait.sh').write_text(hook)
                self.run_helper(source,env)
                self.assertEqual((driver/'unbind').read_text(),'')

    def test_protocol_changes_while_waiting(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            (base/'during-wait.sh').write_text('PROTOCOL=modemmanager\n')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_changed_usb_incarnation_cancels_recovery(self):
        for hook in ('echo 4 > "$FIXTURE/usb/2-1.4/devnum"\n', '''
mv "$FIXTURE/usb/2-1.4" "$FIXTURE/usb/previous"
cp -R "$FIXTURE/usb/previous" "$FIXTURE/usb/2-1.4"
'''):
            with self.subTest(hook=hook),tempfile.TemporaryDirectory() as temp:
                base,driver,source,env=self.fixture(temp)
                (base/'during-wait.sh').write_text(hook)
                self.run_helper(source,env)
                self.assertEqual((driver/'unbind').read_text(),'')

    def test_worker_on_another_port_cannot_trigger_rebind(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            (base/'proc/10875/cmdline').write_bytes(b'sms_tool\0-d\0/dev/ttyUSB1\0at\0AT+CGACT?\0')
            self.run_helper(source,env)
            self.assertEqual((driver/'unbind').read_text(),'')

    def test_reused_pid_or_completed_operation_cancels_recovery(self):
        for state,started in (('D','200'),('S','100')):
            with self.subTest(state=state,started=started),tempfile.TemporaryDirectory() as temp:
                base,driver,source,env=self.fixture(temp)
                stat=' '.join(['10875','(sms_tool)',state]+['0']*18+[started])
                (base/'during-wait.sh').write_text(f'echo "{stat}" > "$FIXTURE/proc/10875/stat"\n')
                self.run_helper(source,env)
                self.assertEqual((driver/'unbind').read_text(),'')

    def test_only_one_worker_can_confirm_a_stall(self):
        with tempfile.TemporaryDirectory() as temp:
            base,driver,source,env=self.fixture(temp)
            (base/'hold').touch()
            with subprocess.Popen(['busybox','ash','-c','set -- /dev/ttyUSB3\n'+source],
                                  env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL) as worker:
                try:
                    deadline=time.monotonic()+2
                    while not (base/'checking').exists() and time.monotonic()<deadline:
                        time.sleep(0.01)
                    self.assertTrue((base/'checking').exists())
                    self.assertEqual((driver/'unbind').read_text(),'')
                    self.run_helper(source,env)
                    self.assertEqual((base/'log').read_text().count('checking again'),1)
                finally:
                    (base/'resume').touch()
                    self.assertEqual(worker.wait(timeout=2),0)
            self.assertEqual((driver/'unbind').read_text(),'2-1.4:1.6')

    def test_failed_sysfs_writes_are_logged(self):
        for action in ('bind','unbind'):
            with self.subTest(action=action),tempfile.TemporaryDirectory() as temp:
                base,driver,source,env=self.fixture(temp)
                path=f'"$FIXTURE/drivers/option/{action}"'
                (base/'during-wait.sh').write_text(f'rm {path}; mkdir {path}\n')
                self.run_helper(source,env,returncode=1)
                self.assertIn(f'could not {action} serial interface',(base/'log').read_text())

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
            launcher=function('_at_recover','atlock.sh').replace('/usr/share/5gmodem',temp)
            caller=r'''
exec 7>"$LOCK"; exec 8>"$LOCK"; exec 9>"$LOCK"
export _AT_LOCK_HELD=ttyUSB3
_at_recover /dev/ttyUSB3
'''
            expected='unset\nclosed\nclosed\nclosed\n'
            for resource in (temp,temp+'/modemband'):
                with self.subTest(resource=resource):
                    output=Path(temp)/('direct-result' if resource==temp else 'fallback-result')
                    result=shell(launcher+caller,dict(os.environ,RES=resource,LOCK=temp+'/lock',RESULT=str(output)))
                    self.assertEqual(result.returncode,0,result.stderr)
                    deadline=time.monotonic()+2
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
            self.assertEqual((driver/'unbind').read_text(),'2-1.4:1.6')
