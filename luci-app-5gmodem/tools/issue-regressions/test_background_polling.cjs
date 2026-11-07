const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../../htdocs/luci-static/resources/view/modem5g');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');

async function checkToggle(make) {
    const document = { hidden: true };
    let calls = 0;
    const hit = () => { calls++; return Promise.resolve('{}'); };
    const tick = make(document, hit);
    await tick();
    assert.equal(calls, 0);
    document.hidden = false;
    await tick();
    assert.equal(calls, 1);
}

async function main() {
    await checkToggle((document, hit) => {
        const source = read('5gdetail.js');
        const start = source.indexOf('pollTickFn = function() {') + 'pollTickFn = '.length;
        const end = source.indexOf('\n\t\t\t\t};', start) + '\n\t\t\t\t}'.length;
        const create = new Function('document', 'L', 'fs', 'ifaceProtoIsMM', 'pageModemPath',
            'applyMetrics', 'return ' + source.slice(start, end));
        return create(document, { resolveDefault: p => Promise.resolve(p) },
            { exec_direct: hit }, false, '1-1', () => {});
    });

    await checkToggle((document, hit) => {
        const match = read('readsms.js').match(/poll\.add\((function\(\) \{ return .*?doRefresh\(false\); \}), 15\);/);
        assert.ok(match);
        return new Function('document', 'doRefresh', 'return ' + match[1])(document, hit);
    });

    await checkToggle((document, hit) => {
        const match = read('5gstats.js').match(/poll\.add\((function\(\) \{\n[\s\S]*?\n\t\t\}), 10\);/);
        assert.ok(match);
        return new Function('document', 'callStats', 'refresh', 'return ' + match[1])(document, hit, () => {});
    });

    await checkToggle((document, hit) => {
        const match = read('netpri.js').match(/function _npPollAdd\(fn, n\) \{\n[\s\S]*?\n\}/);
        assert.ok(match);
        let tick;
        const tracked = [];
        new Function('document', '_npPolls', 'poll', match[0] + '\n_npPollAdd(arguments[3], 5);')(
            document, tracked, { add: fn => { tick = fn; } }, hit);
        assert.equal(tracked[0], tick);
        return tick;
    });

    const document = { hidden: true };
    let calls = 0, tick;
    const api = new Function('baseclass', 'fs', 'uci', 'poll', 'mutil', 'L', 'document', read('extip.js'))(
        { extend: x => x }, { exec_direct: () => { calls++; return Promise.resolve('{}'); } },
        { load: () => Promise.resolve(), get: () => '1' }, { add: fn => { tick = fn; } }, {},
        { resolveDefault: p => Promise.resolve(p) }, document);
    await api.init();
    api.watch('wan');
    await tick();
    assert.equal(calls, 0);
    document.hidden = false;
    await tick();
    assert.equal(calls, 1);
    console.log('PASS: hidden tabs skip metrics, SMS, statistics, widgets and external-IP polling; visible tabs resume');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
