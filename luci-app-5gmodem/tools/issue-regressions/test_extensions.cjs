const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const resources = path.resolve(__dirname, '../../htdocs/luci-static/resources');
const read = file => fs.readFileSync(path.join(resources, file), 'utf8');
const identity = value => value;
const baseclass = { extend: identity };
const failure = () => { throw new Error('extension failure'); };
const makeExtensions = new Function('baseclass', 'fs', 'L', 'console', read('5gmodem/ext.js'));
const makeButtons = new Function('view', 'fs', 'ui', 'ext', 'document', 'window', 'L', 'E', '_',
    'Element', 'DocumentFragment', read('view/modem5g/buttons.js'));

class Element {
    constructor(children) {
        this.children = children === undefined ? [] : [].concat(children);
        this.classList = { toggle() {} };
    }

    appendChild(child) {
        assert.ok(child instanceof Element || child instanceof DocumentFragment);
        this.children.push(child);
    }
}

class DocumentFragment {}

async function main() {
    const extraCard = new DocumentFragment();
    const buttonCard = new Element();
    const smsCalls = [];
    const warnings = [];
    const requested = [];
    const modules = {
        'a-sync': failure,
        'b-async': () => Promise.reject(new Error('failed to load')),
        'c-invalid': () => ({
            init: failure,
            buttonCard: () => 'invalid card',
            cards: () => ({ nodeType: 11 }),
            sms: failure,
        }),
        'd-good': () => ({
            init: () => Promise.reject(new Error('failed to initialize')),
            buttonCard: () => buttonCard,
            cards(data, api) {
                assert.deepEqual(data.buttons, []);
                assert.equal(typeof api.statePanel, 'function');
                return extraCard;
            },
            sms(group, section) { smsCalls.push([group, section]); },
        }),
        'e-last': () => ({
            buttonCard: failure,
        }),
    };
    const L = {
        require(name) {
            const module = name.replace(/^5gmodem\.ext\./, '');
            requested.push(module);
            return modules[module]();
        },
        resource: name => '/custom-static/' + name,
        resolveDefault: (promise, fallback) => Promise.resolve(promise).catch(() => fallback),
    };
    const fileList = ['e-last.js', 'c-invalid.js', 'b-async.js', 'a-sync.js', 'd-good.js', 'skip.nested.js']
        .map(name => ({ name, type: 'file' }));
    const ext = makeExtensions(baseclass, { list(directory) {
        assert.equal(directory, '/www/luci-static/resources/5gmodem/ext');
        return Promise.resolve(fileList);
    } }, L, { warn: warning => warnings.push(warning) });
    assert.equal(ext.load(), ext.load());
    await ext.load();
    assert.deepEqual(requested, ['a-sync', 'b-async', 'c-invalid', 'd-good', 'e-last']);

    const smsSection = {};
    ext.call('sms', 'receive', smsSection);
    assert.deepEqual(smsCalls, [['receive', smsSection]]);
    assert.equal(ext.first('buttonCard', result => result instanceof Element), buttonCard);
    assert.equal(warnings.some(warning => warning.includes('e-last')), false);

    const document = {
        getElementById: () => true,
        addEventListener() {},
    };
    const responses = { detect: { buttons: [] }, leds: { leds: [] }, services: { services: [] } };
    const buttons = makeButtons(baseclass, {
        exec: (_file, [type]) => Promise.resolve({ stdout: JSON.stringify(responses[type]) }),
    }, {}, ext, document, {}, L, (_tag, _attrs, children) => new Element(children), identity, Element, DocumentFragment);
    const body = buttons.render();
    assert.equal(body.children.length, 1);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(body.children.length, 2);
    assert.equal(body.children[1], extraCard);
    assert.equal(warnings.filter(warning => warning.includes('(load)')).length, 2);
    assert.equal(warnings.filter(warning => warning.includes('(init)')).length, 2);

    const noExtensions = makeExtensions(baseclass, { list: failure }, L, console);
    await noExtensions.load();
    assert.deepEqual(noExtensions.call('cards'), []);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
