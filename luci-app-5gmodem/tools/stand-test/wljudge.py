#!/usr/bin/env python3
import re
import sys


def out(r, n, t, d):
    print('%s\t%s\t%s\t%s' % (r, n, t, d))


def main():
    mode = sys.argv[1]
    lines = open(sys.argv[2], encoding='utf-8', errors='replace').read().splitlines()
    if len(sys.argv) > 3:
        r = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in lines if l.startswith('R ')]
        r = r[-1] if r else {}
        ok = r.get('health') == 'up' and r.get('dns_listed', '0') != '0'
        return out('PASS' if ok else 'FAIL', 'wl.%s.recovery' % mode, 0,
                   'after rollback: health=%s, modem DNS listed=%s' % (r.get('health'), r.get('dns_listed')))
    O = [l for l in lines if l.startswith('O ')]
    L = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in lines if l.startswith('L ')]
    G = [l[2:] for l in lines if l.startswith('G ')]
    n = 'wl.%s' % mode
    if not O:
        return out('FAIL', n + '.observe', 0, 'no observations')
    t0 = int(re.search(r't=(\d+)', O[0]).group(1))
    t1 = int(re.search(r't=(\d+)', O[-1]).group(1))
    dur = t1 - t0
    states = [re.search(r'health=\[(\S*)', l).group(1) for l in O]
    ifups = [int(m.group(1)) for m in (re.search(r'ifup=(\d+)', l) for l in O) if m]
    metrics = [m.group(1) for m in (re.search(r'metric=(\d+)', l) for l in O) if m]
    dns = [m.group(1) for m in (re.search(r'dns_listed=(\d+)', l) for l in O) if m]
    drops = [m.group(1) for m in (re.search(r'dropped=(\d+)', l) for l in O) if m]
    probe = re.search(r'(ping77=\S+ ping1111=\S+ https_ya=\S+ https_google=\S+ dns_modem=\S+)', O[len(O) // 2])
    out('INFO', n + '.reachability', dur, (probe.group(1) if probe else '-') + ' dropped_pkts=' + (drops[-1] if drops else '-'))
    down = [s for s in states if s not in ('up', '')]
    if mode == 'block':
        seen = 'down' in states or any('went down' in g for g in G)
        out('PASS' if seen else 'FAIL', n + '.outage-detected', dur, 'states seen: %s' % ','.join(sorted(set(states))))
        for g in G[-5:]:
            out('INFO', n + '.log', 0, g[:250])
        return
    out('PASS' if not down else 'FAIL', n + '.health-state', dur,
        'states seen: %s' % ','.join(sorted(set(states))))
    resets = sum(1 for a, b in zip(ifups, ifups[1:]) if b < a)
    l = L[-1] if L else {}
    downs = int(l.get('downs', 0))
    heal = [g for g in G if re.search(r'one reconnect|healing stopped|healing:|reboot_modem|CFUN|usbpower|power-cycl|reassociat|went down|steering traffic|dropped DNS', g, re.I)]
    out('PASS' if resets == 0 and downs == 0 else 'FAIL', n + '.no-restart', dur,
        'iface uptime resets %d, "is now down" %d' % (resets, downs))
    out('PASS' if not heal else 'FAIL', n + '.no-heal', dur, (' | '.join(heal[-4:]) or 'no healing actions')[:300])
    base = metrics[0] if metrics else '-'
    moved = sorted(set(metrics) - {base})
    dnsgone = bool(dns) and dns[0] != '0' and '0' in dns
    out('PASS' if not moved and not dnsgone else 'FAIL', n + '.no-failover', dur,
        'metric %s%s, modem DNS listed %s' % (base, (' -> ' + ','.join(moved)) if moved else '', ','.join(sorted(set(dns)))))
    ev = [g for g in G if 'health' in g][-3:]
    if ev:
        out('INFO', n + '.log', 0, ' | '.join(ev)[:300])


if __name__ == '__main__':
    main()
