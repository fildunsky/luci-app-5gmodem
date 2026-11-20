const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const tabs = fs.readFileSync(path.resolve(__dirname,
    '../../htdocs/luci-static/resources/view/modem5g/modemtabs.js'), 'utf8');
const seen = tabs.slice(tabs.indexOf('var GPS_SEEN_BASE'), tabs.indexOf('var USSD_SEEN_BASE'));
const apply = tabs.slice(tabs.indexOf('function applyGpsTabVisibility()'), tabs.indexOf('function ghostBar()'));
const make = new Function('uci', 'localStorage', 'gateHideRule', 'L', 'fs', 'mutil',
    seen + apply + 'return applyGpsTabVisibility;');

async function main() {
    const prefix = '5gmodem.gps.supported';
    const storage = new Map();
    let active = '1-1';
    const originalKey = prefix + '.1-1';
    let hidden, response, pendingResponse;
    const refresh = make(
        { load: () => Promise.resolve(), get: (_config, _section, option) => option === 'active_modem' ? active : '1' },
        { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value) },
        (_id, _tab, hide) => { hidden = hide; },
        { resolveDefault: (p, fallback) => Promise.resolve(p).catch(() => fallback) },
        { exec: (_bin, args) => {
            assert.deepEqual(args, ['caps']);
            return pendingResponse || Promise.resolve(response);
        } },
        { lsTouch: () => {} },
    );

    response = { code: 0, stdout: '{"supported":1}' };
    await refresh();
    assert.equal(hidden, false);
    assert.equal(storage.get(originalKey), '1');

    for (response of [
        null, { code: 1, stdout: '{"supported":0}' },
        { code: 0, stdout: '' }, { code: 0, stdout: '{}' },
        { code: 0, stdout: 'null' }, { code: 0, stdout: '[' },
        { code: 0, stdout: '{"supported":0,"pending":true}' },
        { code: 0, stdout: '{"supported":0,"busy":1}' },
    ]) {
        await refresh();
        assert.equal(hidden, false, JSON.stringify(response));
        assert.equal(storage.get(originalKey), '1');
    }

    active = '1-2';
    await refresh();
    assert.equal(hidden, true, 'pending on another path must not reuse the result');
    assert.equal(storage.has(prefix + '.1-2'), false);

    active = '1-1';
    let resolveResponse;
    pendingResponse = new Promise(resolve => { resolveResponse = resolve; });
    const inflight = refresh();
    await new Promise(resolve => setImmediate(resolve));
    active = '1-2';
    resolveResponse({ code: 0, stdout: '{"supported":0}' });
    pendingResponse = null;
    await inflight;
    assert.equal(storage.get(originalKey), '1');
    assert.equal(storage.has(prefix + '.1-2'), false);

    active = '1-1';
    response = { code: 0, stdout: '{"supported":0}' };
    await refresh();
    assert.equal(hidden, true);
    assert.equal(storage.get(originalKey), '0');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
