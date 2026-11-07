const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.resolve(__dirname,
    '../../htdocs/luci-static/resources/view/modem5g/bandsui.js'), 'utf8');
let modal;
const E = (tag, attrs, children) => ({ tag, attrs, children });
const translate = s => s;
String.prototype.format = function(value) { return this.replace('%s', value); };
const prompt = new Function('E', '_', 'ui', source.slice(
    source.indexOf('function mtkPackagePrompt()'), source.indexOf('function applyVendorJson(')) +
    '\nreturn mtkPackagePrompt;')(E, translate, {
        showModal: (title, children) => { modal = { title, children }; },
        hideModal: () => {}
    });
const tree = prompt();
const button = tree.children.find(n => n && n.tag === 'button');
let prevented = false;
button.attrs.click({ preventDefault() { prevented = true; } });
assert.equal(prevented, true);
assert.equal(modal.title, '5gmodem-mtk-at');
const links = modal.children[1].children.filter(n => n && n.tag === 'a');
assert.deepEqual(links.map(a => a.attrs.href), ['apk', 'ipk'].map(ext =>
    'https://raw.githubusercontent.com/fildunsky/luci-app-5gmodem/master/dist/5gmodem-mtk-at/5gmodem-mtk-at.' + ext));
assert.match(modal.children[0].children[0], /System → Software/);
console.log('MTK package download dialog: OK');
