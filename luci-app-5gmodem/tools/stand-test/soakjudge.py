#!/usr/bin/env python3
import re
import sys
from collections import Counter


def kv(line):
    return dict(re.findall(r'(\w+)=(\S+)', line))


def out(r, n, t, d):
    print('%s\t%s\t%s\t%s' % (r, n, t, d))


def main():
    lines = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
    S = [kv(l) for l in lines if l.startswith('S ')]
    L = [kv(l) for l in lines if l.startswith('L ')]
    G = [l[2:] for l in lines if l.startswith('G ')]
    if len(S) < 2:
        return out('FAIL', 'soak.samples', 0, 'only %d samples' % len(S))
    dur = int(S[-1]['t']) - int(S[0]['t'])
    ups = [s.get('up') for s in S]
    ifup = [int(s['ifup']) if s.get('ifup', '').isdigit() else -1 for s in S]
    flaps = sum(1 for a, b in zip(ifup, ifup[1:]) if b < a)
    out('PASS' if all(u == 'true' for u in ups) and flaps == 0 else 'FAIL', 'soak.no-flap', dur,
        'up in %d/%d samples, uptime resets %d' % (ups.count('true'), len(ups), flaps))
    m0, m1 = int(S[0]['memavail']), int(S[-1]['memavail'])
    mmin = min(int(s['memavail']) for s in S)
    drift = m1 - m0
    out('PASS' if drift > -8192 else 'WARN', 'soak.memory', dur, 'MemAvailable %d -> %d kB (min %d, drift %+d kB)' % (m0, m1, mmin, drift))
    zs = [int(s['zombies']) for s in S]
    z = max(zs)
    persist = any(a > 0 and b > 0 for a, b in zip(zs, zs[1:]))
    out('FAIL' if persist else ('WARN' if z else 'PASS'), 'soak.zombies', dur,
        'max zombies %d (%s)' % (z, 'persistent' if persist else ('transient, one sample' if z else 'none')))
    old = max(int(s['sms_tool_old']) for s in S)
    st = max(int(s['sms_tool']) for s in S)
    out('PASS' if old == 0 else 'FAIL', 'soak.sms_tool-hung', dur, 'max sms_tool %d, older than 60 s: %d' % (st, old))
    p0, p1 = int(S[0]['procs']), int(S[-1]['procs'])
    pmax = max(int(s['procs']) for s in S)
    out('PASS' if p1 - p0 < 15 else 'WARN', 'soak.processes', dur, 'procs %d -> %d (max %d)' % (p0, p1, pmax))
    r0, r1 = int(S[0]['rpcd_rss']), int(S[-1]['rpcd_rss'])
    out('PASS' if r1 - r0 < 2048 else 'WARN', 'soak.rpcd-rss', dur, 'rpcd RSS %d -> %d kB' % (r0, r1))
    t0, t1 = int(S[0]['tmpfiles']), int(S[-1]['tmpfiles'])
    u0, u1 = int(S[0]['tmpused']), int(S[-1]['tmpused'])
    out('PASS' if t1 <= t0 + 2 and u1 - u0 < 4096 else 'WARN', 'soak.tmp', dur, 'temp files %d -> %d, /tmp used %d -> %d kB' % (t0, t1, u0, u1))
    if L:
        l = L[-1]
        bad = int(l.get('downs', 0)) + int(l.get('usbdisc', 0))
        out('PASS' if bad == 0 and int(l.get('heal', 0)) == 0 else 'FAIL', 'soak.log', dur,
            'iface downs %s, heal/CFUN lines %s, USB disconnects %s, log lines %s' % (l.get('downs'), l.get('heal'), l.get('usbdisc'), l.get('lines')))
        if G:
            out('INFO', 'soak.log-tail', 0, ' | '.join(G[-6:])[:300])
    calls = Counter()
    for f in sys.argv[2:]:
        for c in open(f, encoding='utf-8', errors='replace').read().splitlines():
            if c.strip():
                calls[re.sub(r' for=\S+| \d+-[\d.]+$', '', c)[:60]] += 1
    if calls:
        tot = sum(calls.values())
        top = ', '.join('%s x%d' % kv_ for kv_ in calls.most_common(5))
        out('INFO', 'soak.page-calls', dur, '%d backend calls (%.1f/min): %s' % (tot, tot * 60.0 / max(dur, 1), top))


if __name__ == '__main__':
    main()
