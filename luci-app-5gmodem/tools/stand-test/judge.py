#!/usr/bin/env python3
import json
import re
import sys

LIMITS = {'peek': 2, 'cached': 12, 'json': 25, 'listmodems': 3, 'detect': 5, 'bands_json': 10,
          'bands_mgmtinfo': 10, 'simslot': 10, 'netpri_list': 5, 'sms_recv': 30, 'at_ati': 10}


def parse(raw, nonce):
    blocks = {}
    cur = None
    buf = []
    b = re.compile(r'^@@%s BEGIN (\S+) (\d+) ([\d.]+)$' % re.escape(nonce))
    e = re.compile(r'^@@%s END (\S+)$' % re.escape(nonce))
    for ln in raw.splitlines():
        m = b.match(ln)
        if m:
            cur = (m.group(1), int(m.group(2)), float(m.group(3)))
            buf = []
            continue
        m = e.match(ln)
        if m and cur:
            blocks[cur[0]] = {'rc': cur[1], 't': cur[2], 'out': '\n'.join(buf).strip()}
            cur = None
            continue
        if cur:
            buf.append(ln)
    return blocks


def js(s):
    try:
        return json.loads(s), None
    except Exception as ex:
        return None, str(ex)[:120]


def num(v):
    try:
        float(str(v))
        return True
    except Exception:
        return False


def dash(v):
    return v in (None, '', '-', '--')


RESULTS = []


def res(r, name, t, detail=''):
    RESULTS.append('%s\t%s\t%.2f\t%s' % (r, name, t, str(detail).replace('\n', ' ')[:300]))


def check_metrics(name, b):
    d, err = js(b['out'])
    if d is None:
        return res('FAIL', 'metrics.' + name, b['t'], 'invalid JSON: %s | %s' % (err, b['out'][:80]))
    miss = [k for k in ('modem', 'imei', 'registration', 'rsrp', 'mode', 'ipaddr') if dash(d.get(k))]
    bad = []
    if not dash(d.get('rsrp')) and not num(d.get('rsrp')):
        bad.append('rsrp=%r' % d.get('rsrp'))
    if str(d.get('registration')) not in ('1', '5'):
        bad.append('registration=%r' % d.get('registration'))
    age = d.get('age')
    slow = b['t'] > LIMITS.get(name, 10)
    if miss or bad:
        res('FAIL', 'metrics.' + name, b['t'], 'empty: %s %s' % (','.join(miss), ' '.join(bad)))
    elif slow:
        res('WARN', 'metrics.' + name, b['t'], 'slow (> %ss)' % LIMITS.get(name))
    else:
        res('PASS', 'metrics.' + name, b['t'], 'reg=%s rsrp=%s mode=%s ip=%s age=%s' % (
            d.get('registration'), d.get('rsrp'), d.get('mode'), d.get('ipaddr'), age))
    return d


def jcheck(blocks, key, name, pred=None, desc=''):
    b = blocks.get(key)
    if not b:
        return res('FAIL', name, 0, 'no output block')
    d, err = js(b['out'])
    if d is None:
        return res('FAIL', name, b['t'], 'invalid JSON: %s | %s' % (err, b['out'][:100]))
    ok = True
    why = ''
    if pred:
        try:
            ok = bool(pred(d))
        except Exception as ex:
            ok, why = False, str(ex)
    lim = LIMITS.get(key)
    if not ok:
        res('FAIL', name, b['t'], (desc or 'predicate failed') + ' ' + why + ' | ' + b['out'][:160])
    elif lim and b['t'] > lim:
        res('WARN', name, b['t'], 'slow (> %ss)' % lim)
    else:
        res('PASS', name, b['t'], b['out'][:120])
    return d


def main():
    raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
    nonce = sys.argv[2]
    bl = parse(raw, nonce)
    env = bl.get('env', {}).get('out', '')
    res('INFO', 'env', 0, env)
    peek = None
    for k in ('peek', 'cached', 'json'):
        if k in bl:
            d = check_metrics(k, bl[k])
            if k == 'peek':
                peek = d
    if peek:
        reg = str(peek.get('registration', ''))
        ip = not dash(peek.get('ipaddr'))
        ok = (reg in ('1', '5') and ip) or (str(peek.get('no_at')) == '1' and dash(reg) and ip)
        res('PASS' if ok else 'FAIL', 'doctor.check-only', 0,
            'doctorOk=%s (reg=%s ip=%s)' % (ok, reg, peek.get('ipaddr')))
    act = bl.get('active', {}).get('out', '').strip()
    jcheck(bl, 'listmodems', 'modems.listmodems', lambda d: isinstance(d, list) and any(m.get('path') == act for m in d), 'active modem not listed')
    b = bl.get('detect')
    if b:
        res('PASS' if re.match(r'^/dev/tty\w+$', b['out'].strip()) else 'FAIL', 'modems.detect', b['t'], b['out'][:60])
    jcheck(bl, 'resolve', 'modems.resolve', lambda d: d.get('result') in ('resolved', 'ok', 'unchanged') and d.get('active') == act)
    jcheck(bl, 'bands_json', 'bands.json', lambda d: len(d.get('supported') or []) > 0 and len(d.get('modes') or []) > 0 and d.get('currentmode') not in (None, ''))
    jcheck(bl, 'bands_mgmtinfo', 'bands.mgmtinfo', lambda d: isinstance(d, dict))
    jcheck(bl, 'simslot', 'sim.slot', lambda d: len(d.get('slots') or []) > 0 and d.get('active') not in (None, ''))
    b = bl.get('sms_status')
    if b:
        ok = b['rc'] == 0 and re.search(r'used:\s*\d+', b['out'])
        res('PASS' if ok else 'FAIL', 'sms.status', b['t'], b['out'][:100])
    jcheck(bl, 'sms_recv', 'sms.recv', lambda d: isinstance(d.get('msg'), list), 'no msg[]')
    b = bl.get('sms_newcount')
    if b:
        res('PASS' if re.match(r'^\d+$', b['out'].strip()) else 'FAIL', 'sms.newcount', b['t'], b['out'][:40])
    b = bl.get('at_ati')
    if b:
        ok = re.search(r'Model|Manufacturer|Revision|IMEI', b['out'], re.I) and 'ERROR' not in b['out']
        res('PASS' if ok else 'FAIL', 'at.ATI', b['t'], b['out'].replace('\n', ' ')[:120])
    b = bl.get('at_csq')
    if b:
        res('PASS' if '+CSQ:' in b['out'] else 'FAIL', 'at.CSQ', b['t'], b['out'].replace('\n', ' ')[:80])
    b = bl.get('at_foreign')
    if b:
        res('PASS' if b['rc'] != 0 else 'FAIL', 'at.foreign-port-refused', b['t'], 'rc=%s %s' % (b['rc'], b['out'][:60]))
    jcheck(bl, 'stats_list', 'stats.list', lambda d: 'enabled' in d)
    jcheck(bl, 'stats_traffic', 'stats.traffic', lambda d: isinstance(d, (dict, list)))
    jcheck(bl, 'ttl_get', 'ttl.get', lambda d: d.get('iface') and d.get('def4'))
    jcheck(bl, 'netpri_list', 'netpri.list', lambda d: isinstance(d, list) and any(x.get('type') == 'modem' and x.get('health') == 'up' for x in d), 'modem uplink not health=up')
    jcheck(bl, 'netpri_status', 'netpri.status', lambda d: 'active' in d)
    jcheck(bl, 'netpri_ping', 'netpri.ping', lambda d: str(d.get('ok')) == '1')
    jcheck(bl, 'extip_get', 'extip.get', lambda d: isinstance(d, dict))
    jcheck(bl, 'health_conf', 'health.getconf', lambda d: 'enabled' in d and 'targets' in d)
    sup = jcheck(bl, 'ussd_support', 'ussd.support', lambda d: 'supported' in d)
    jcheck(bl, 'ussd_status', 'ussd.status', lambda d: 'status' in d)
    b = bl.get('ussd_send')
    if b:
        res('PASS' if b['rc'] == 0 and b['out'] else 'FAIL', 'ussd.send', b['t'], b['out'][:160])
    else:
        why = 'modem reports USSD unsupported' if sup and str(sup.get('supported')) == '0' else 'no USSDCODE given'
        res('SKIP', 'ussd.send', 0, why)
    jcheck(bl, 'esim_status', 'esim.status', lambda d: 'available' in d)
    jcheck(bl, 'antenna', 'antenna.status', lambda d: 'available' in d)
    jcheck(bl, 'usbpower', 'reboot.hasusbpower', lambda d: isinstance(d, dict))
    b = bl.get('sw_daemon')
    if b:
        res('PASS' if b['out'].startswith('running') else 'FAIL', 'sessionwatch.daemon', b['t'], b['out'].replace('\n', ' '))
    jcheck(bl, 'iface_status', 'iface.up', lambda d: d.get('up') is True and len(d.get('ipv4-address') or []) > 0)
    b = bl.get('procs')
    if b:
        z = re.search(r'zombies=(\d+)', b['out'])
        s = re.search(r'sms_tool=(\d+)', b['out'])
        zz, ss = int(z.group(1)) if z else -1, int(s.group(1)) if s else -1
        r = 'PASS' if zz == 0 and 0 <= ss <= 1 else ('WARN' if zz == 0 else 'FAIL')
        res(r, 'procs.snapshot', b['t'], b['out'].replace('\n', ' '))
    b = bl.get('log_errors')
    if b:
        res('INFO', 'log.recent', b['t'], b['out'].replace('\n', ' | ')[:300])
    print('\n'.join(RESULTS))


if __name__ == '__main__':
    main()
