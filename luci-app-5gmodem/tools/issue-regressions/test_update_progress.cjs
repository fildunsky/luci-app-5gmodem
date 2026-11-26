const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/5gsettings.js'), 'utf8');
const start = source.indexOf('function updProgress(d) {');
const end = source.indexOf('\n}\n', start) + 2;
function fixture() {
 const state = { pos: 0, floor: 0, cap: 0, text: '', timer: 1 };
 const context = vm.createContext({
  updBar: state, byId: () => ({ classList: { add() {}, remove() {} } }),
  _: text => text, updKB: n => Math.round((+n || 0) / 1024),
  updBarPaint() {}, updBarTick() {}, updBarStop() {},
  window: { setInterval: () => 1 }
 });
 vm.runInContext("String.prototype.format = function(...args) { let i = 0; return this.replace(/%[ds]/g, () => String(args[i++])); };", context);
 vm.runInContext(source.slice(start, end), context);
 return { state, progress: d => context.updProgress(d) };
}

test('combined download moves forward and identifies the helper without restarting the bar', () => {
 const f = fixture();
 const total = 1536 * 1024;
 const samples = [
  { done: 512 * 1024, step: '' },
  { done: 1024 * 1024, step: '' },
  { done: 1280 * 1024, step: 'mtk' },
  { done: total, step: 'mtk' }
 ];
 let previous = 0;
 for (const sample of samples) {
  f.progress({ stage: 'download', total, ...sample });
  assert.ok(f.state.floor >= previous);
  assert.equal(f.state.floor, 5 + 20 * sample.done / total);
  assert.ok(f.state.text.includes(`${sample.done / 1024} of 1536 KB`));
  assert.equal(f.state.text.includes('5gmodem-mtk-at'), sample.step === 'mtk');
  previous = f.state.floor;
 }
 f.progress({ stage: 'install', done: total, total });
 assert.equal(f.state.floor, 25);
 assert.equal(f.state.text, 'Unpacking the package…');
});

test('no helper keeps existing download progress and labels', () => {
 const f = fixture();
 f.progress({ stage: 'download', done: 512 * 1024, total: 1024 * 1024 });
 assert.equal(f.state.floor, 15);
 assert.equal(f.state.text, 'Downloading: 512 of 1024 KB');
});

test('unknown total still shows cumulative helper bytes without invalid percentages', () => {
 const f = fixture();
 f.progress({ stage: 'download', step: 'mtk', done: 1280 * 1024, total: 0 });
 assert.equal(f.state.floor, 5);
 assert.equal(f.state.cap, 24);
 assert.equal(f.state.text, '5gmodem-mtk-at · Downloading: 1280 KB');
});
