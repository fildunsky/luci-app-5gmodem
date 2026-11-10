const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/5gdetail.js'), 'utf8');
const calls = [], busy = [], polls = [], bars = [];
let reply = '{"ok":true}';
const box = { style: {}, children: [], set innerHTML(value) { this.children = []; }, appendChild(node) { this.children.push(node); } };
const context = { document: { getElementById: () => box }, _: s => s, simSlotsSeen: false,
  E: (tag, attributes, children) => ({ tag, attributes: Object.fromEntries(Object.entries(attributes || {}).filter(([, value]) => value != null).map(([key, value]) => [key, typeof value === 'function' ? value : String(value)])), children }), sameRender: () => false,
  pageModemPath: '1-1', fs: { exec: (script, args) => { calls.push({script, args}); return Promise.resolve({ stdout: reply }); } },
  ui: { showModal() {}, hideModal() {}, addNotification() {} },
  _androidSwitchSlot: null, clearModemBusy() { context._androidSwitchSlot = null; },
  setModemBusy: (message, seconds) => { busy.push(message); bars.push(seconds); }, pollSlotUntilSwitched: id => polls.push(id)
};
vm.createContext(context);
vm.runInContext('String.prototype.format = function(value) { return this.replace("%s", value); };', context);
vm.runInContext(source.slice(source.indexOf('function finishAndroidSwitch('), source.indexOf('var slotsInflight =')), context);
async function main() {
  const event = { preventDefault() {} };
  context.renderSimSlots({ type: 'android', active: '2', writable: true, slots: [ { id: '1', label: 'SIM 1', present: '1' }, { id: '2', label: 'SIM 2', present: '1' } ] });
  assert.ok(box.children.every(button => !Object.hasOwn(button.attributes, 'disabled')));
  await box.children[0].attributes.click(event);
  assert.equal(calls[0].script, '/usr/share/5gmodem/simslot.sh');
  assert.equal(Array.from(calls[0].args).join('|'), 'set|1|for=1-1');
  assert.equal(polls[0], '1');
  assert.equal(busy.length, 1);
  assert.equal(bars[0], 15);
  context.finishAndroidSwitch({ backend: 'android', android_slot: '1', data_state: '2' });
  assert.equal(context._androidSwitchSlot, '1');
  context.finishAndroidSwitch({ backend: 'android', android_slot: '0', data_state: '1' });
  assert.equal(context._androidSwitchSlot, '1');
  context.finishAndroidSwitch({ backend: 'android', android_slot: '0', data_state: '2' });
  assert.equal(context._androidSwitchSlot, null);
  const count = calls.length;
  await box.children[1].attributes.click(event);
  assert.equal(calls.length, count);
  reply = '{"ok":false}';
  await context.switchSimSlot('1', 'SIM 1', 'android', event);
  assert.equal(busy.length, 2);
  assert.equal(context._androidSwitchSlot, null);
  reply = '{"result":"ok"}';
  await context.switchSimSlot('1', 'SIM 1', 'usb', event);
  assert.match(busy[2], /restarting/);
  context.renderSimSlots({ type: 'android', active: '2', writable: false, slots: [ { id: '1', label: 'SIM 1' }, { id: '2', label: 'SIM 2' } ] });
  assert.ok(box.children.every(button => button.attributes.disabled));
  const before = calls.length;
  await box.children[0].attributes.click(event);
  assert.equal(calls.length, before);
  console.log('PASS: Android data-SIM buttons use the standard controller without modem restart; legacy switching is preserved');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
