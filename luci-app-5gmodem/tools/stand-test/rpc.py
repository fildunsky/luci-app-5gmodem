#!/usr/bin/env python3
import json
import sys
import time
import urllib.parse
import urllib.request

R = '/usr/share/5gmodem/'

ALLOW_UBUS = [
    ('5gmodem.sh', ['peek']),
    ('5gmodem.sh', ['cached', '20']),
    ('listmodems.sh', []),
    ('detect.sh', []),
    ('bands.sh', ['json']),
    ('bands.sh', ['mgmtinfo']),
    ('simslot.sh', ['status']),
    ('smsbridge.sh', ['newcount']),
    ('stats.sh', ['list']),
    ('stats.sh', ['traffic']),
    ('ttl.sh', ['get']),
    ('netpri.sh', ['list']),
    ('netpri.sh', ['status']),
    ('extip.sh', ['get']),
    ('health.sh', ['getconf']),
    ('ussd.sh', ['status']),
    ('modemswitch.sh', ['ussdsupport']),
    ('modemswitch.sh', ['active']),
    ('modemswitch.sh', ['mmindex']),
    ('modemswitch.sh', ['profiles']),
    ('esim.sh', ['status']),
    ('antenna.sh', ['status']),
    ('reboot_modem.sh', ['hasusbpower']),
    ('reboot_modem.sh', ['haspower']),
    ('buttons.sh', ['services']),
    ('speedtest.sh', ['status']),
    ('apn-update.sh', ['version']),
    ('mmneed.sh', ['check']),
    ('collect.sh', ['status']),
]

ALLOW_CGI = [
    ('5gmodem.sh', ['peek']),
    ('listmodems.sh', []),
    ('bands.sh', ['mgmtinfo']),
    ('netpri.sh', ['list']),
    ('stats.sh', ['list']),
    ('modemswitch.sh', ['active']),
]

DENY_UBUS = [
    ('/bin/busybox', ['true']),
    ('/usr/bin/id', []),
    ('/bin/uname', ['-a']),
]

ALLOW_UCI = ['5gmodem', 'network', 'firewall', 'system']
ALLOW_READ = ['/etc/5gmodem']
ALLOW_LIST = ['/dev', '/sys/class/leds']


class Rpc:
    def __init__(self, host, sid):
        self.host = host
        self.sid = sid
        self.n = 0

    def call(self, obj, meth, args, timeout=40):
        self.n += 1
        body = json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': 'call',
                           'params': [self.sid, obj, meth, args]}).encode()
        req = urllib.request.Request('http://%s/ubus' % self.host, data=body,
                                     headers={'Content-Type': 'application/json'})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=timeout) as r:
            d = json.load(r)
        return d, time.time() - t0

    def cgi_exec(self, argv, timeout=40):
        esc = [a.replace('\\', '\\\\').replace(' ', '\\ ') for a in argv]
        data = urllib.parse.urlencode({'sessionid': self.sid, 'command': ' '.join(esc)}).encode()
        req = urllib.request.Request('http://%s/cgi-bin/cgi-exec' % self.host, data=data)
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode('utf-8', 'replace'), time.time() - t0
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode('utf-8', 'replace'), time.time() - t0


def verdict(d):
    if 'error' in d:
        return 'rpcerr', d['error'].get('message', '')
    res = d.get('result') or []
    code = res[0] if res else -1
    return code, (res[1] if len(res) > 1 else None)


def out(res, name, secs, detail=''):
    print('%s\t%s\t%.2f\t%s' % (res, name, secs, str(detail).replace('\n', ' ')[:300]))
    sys.stdout.flush()


def main():
    host, sid, label = sys.argv[1], sys.argv[2], sys.argv[3]
    rpc = Rpc(host, sid)
    for scr, args in ALLOW_UBUS:
        name = 'rpc.%s.exec %s %s' % (label, scr, ' '.join(args))
        try:
            d, dt = rpc.call('file', 'exec', {'command': R + scr, 'params': args})
        except Exception as e:
            out('FAIL', name, 0, e)
            continue
        code, payload = verdict(d)
        if code == 6:
            out('FAIL', name, dt, 'access denied')
        elif code == 0:
            rc = (payload or {}).get('code', 0)
            out('PASS', name, dt, 'rc=%s' % rc)
        elif code == 7:
            out('WARN', name, dt, 'rpcd timeout (30 s)')
        else:
            out('FAIL', name, dt, 'ubus code %s' % code)
    for scr, args in ALLOW_CGI:
        name = 'rpc.%s.cgi-exec %s %s' % (label, scr, ' '.join(args))
        st, body, dt = rpc.cgi_exec([R + scr] + args)
        out('PASS' if st == 200 and body.strip() else 'FAIL', name, dt, 'http=%s len=%d' % (st, len(body)))
    for cmd, args in DENY_UBUS:
        name = 'rpc.%s.deny %s' % (label, cmd)
        d, dt = rpc.call('file', 'exec', {'command': cmd, 'params': args})
        code, _ = verdict(d)
        if label == 'root':
            out('INFO', name, dt, 'root session: code %s (root has *)' % code)
        else:
            out('PASS' if code == 6 else 'FAIL', name, dt, 'ubus code %s' % code)
    for cfg in ALLOW_UCI:
        name = 'rpc.%s.uci get %s' % (label, cfg)
        d, dt = rpc.call('uci', 'get', {'config': cfg})
        code, _ = verdict(d)
        out('PASS' if code == 0 else 'FAIL', name, dt, 'ubus code %s' % code)
    for p in ALLOW_READ:
        name = 'rpc.%s.file list %s' % (label, p)
        d, dt = rpc.call('file', 'list', {'path': p})
        code, _ = verdict(d)
        out('PASS' if code == 0 else 'FAIL', name, dt, 'ubus code %s' % code)
    for p in ALLOW_LIST:
        name = 'rpc.%s.file list %s' % (label, p)
        d, dt = rpc.call('file', 'list', {'path': p})
        code, _ = verdict(d)
        out('PASS' if code == 0 else 'FAIL', name, dt, 'ubus code %s' % code)


if __name__ == '__main__':
    main()
