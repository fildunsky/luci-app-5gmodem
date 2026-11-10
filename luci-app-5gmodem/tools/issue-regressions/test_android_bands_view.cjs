const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const dir = path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/');
const detail = fs.readFileSync(path.join(dir, '5gdetail.js'), 'utf8');
const bands = fs.readFileSync(path.join(dir, 'bandsui.js'), 'utf8');

// The frequency block and its polling are no longer switched off for Android phones.
assert.match(detail, /_freq\.style\.display = _remote \? 'none' : ''/);
assert.doesNotMatch(detail, /if \(json\.backend !== 'android'\) \{ bandsui\.pollTick\(\); \}/);
assert.match(detail, /freqBlk\.style\.display = \(json\.backend === 'router' \|\|/);
// The phone has no modem restart: that block stays hidden.
assert.match(detail, /_rbb\.style\.display = \(_remote \|\| json\.backend === 'android'\) \? 'none' : ''/);

const nodes = new Map();
const element = (tag, attributes, children) => {
  const node = { tag, attributes: attributes || {}, style: {}, children: [], title: '', innerHTML: '',
    setAttribute(key, value) { this.attributes[key] = value; }, getAttribute(key) { return this.attributes[key]; } };
  if (Array.isArray(children)) node.children = children; else if (children != null) node.text = children;
  return node;
};
['battn'].forEach(id => nodes.set(id, element('div', { id })));
const context = { document: { getElementById: id => nodes.get(id) }, E: element, _: value => value,
  mutil: { caSplitBand(value) { const p = String(value || '').split(' @'); return { band: p[0].trim(), bw: (p[1] || '').trim() }; },
    cellVal(value) { return value == null || value === '' || value === '-' ? '' : String(value); } } };
vm.createContext(context);
vm.runInContext(detail.slice(detail.indexOf('function renderBattery(json)'), detail.indexOf('function chipBox(')), context);
vm.runInContext(detail.slice(detail.indexOf('function caSummary(json)'), detail.indexOf('function caTip(')), context);
const start = detail.indexOf("{ id: 'volte',");
const volte = vm.runInContext('(' + detail.slice(start, detail.indexOf('\t{ id: \'pband\'', start)).trim().replace(/,$/, '') + ')', context);

// Battery details come from Android only and never break the plain tooltip.
const battery = nodes.get('battn');
context.renderBattery({ backend: 'android', battery: '57', battery_charging: '1', battery_voltage: '4105', battery_health: '2', thermal_status: '3' });
assert.equal(battery.title, 'Modem battery, charging · Voltage: 4.11 V · Health: good · Thermal throttling: 3/6');
context.renderBattery({ backend: 'android', battery: '57', battery_charging: '0', battery_health: '1', thermal_status: '0' });
assert.equal(battery.title, 'Modem battery');
context.renderBattery({ backend: 'qmi', battery: '57', battery_voltage: '4105', battery_health: '2' });
assert.equal(battery.title, 'Modem battery');

// Carrier aggregation reported by the phone without per-carrier bands.
assert.deepEqual(JSON.parse(JSON.stringify(context.caSummary({ backend: 'android', pband: 'B3 @10MHz', android_ca_carriers: '3', android_ca_bandwidth: '50' }))), { n: 3, bw: 50 });
assert.deepEqual(JSON.parse(JSON.stringify(context.caSummary({ backend: 'android', pband: 'B3 @10MHz', s1band: 'B7 @20MHz', s2band: 'B1 @15MHz', android_ca_carriers: '2', android_ca_bandwidth: '30' }))), { n: 3, bw: 45 });
assert.deepEqual(JSON.parse(JSON.stringify(context.caSummary({ backend: 'qmi', pband: 'B3 @10MHz', android_ca_carriers: '3', android_ca_bandwidth: '50' }))), { n: 1, bw: 10 });

// VoLTE: Android reports a flag, other modems keep their own text.
assert.equal(volte.text({ backend: 'android', volte: '1' }), 'Yes');
assert.equal(volte.text({ backend: 'android', volte: '0' }), 'No');
assert.equal(volte.text({ backend: 'android' }), '');
assert.equal(volte.text({ backend: 'qmi', volte: 'on' }), 'on');

// Choosing LTE only on a SIM without VoLTE asks first; every other change goes straight through.
const modals = [];
const executed = [];
const seen = () => JSON.parse(JSON.stringify(executed));
const bandsContext = { _: value => value, E: element, window: { setTimeout() {} },
  ui: { showModal(title, body) { modals.push({ title, body }); }, hideModal() { modals.push('hide'); }, addNotification() {}, addTimeLimitedNotification() {} },
  fs: { exec(command, args) { executed.push(args); return Promise.resolve({ code: 0, stdout: 'ok' }); } },
  loadBandsModemband() {}, _lastPoll: null };
vm.createContext(bandsContext);
vm.runInContext(bands.slice(bands.indexOf('var _lastPoll = null;'), bands.indexOf('function setBands3gAT(')), bandsContext);
const apply = async (poll, id) => { bandsContext._lastPoll = poll; modals.length = 0; executed.length = 0; await bandsContext.setNetModeAT(id, 'label'); };
(async () => {
  await apply({ backend: 'android', volte: '0' }, '4');
  assert.equal(modals.length, 1);
  assert.equal(executed.length, 0);
  assert.match(String(modals[0].body[0].text), /no VoLTE/);
  const confirm = modals[0].body[1].children[2];
  await confirm.attributes.click();
  assert.deepEqual(seen(), [['setmode', '4']]);
  for (const [poll, id] of [[{ backend: 'android', volte: '1' }, '4'], [{ backend: 'android', volte: '0' }, '1'],
    [{ backend: 'android', volte: '0' }, '8'], [{ backend: 'qmi', volte: '0' }, '4'], [null, '4']]) {
    await apply(poll, id);
    assert.deepEqual(seen(), [['setmode', id]], JSON.stringify([poll, id]));
    assert.ok(modals.every(modal => modal === 'hide' || !modal.title), 'no confirmation expected');
  }
  console.log('PASS: Android band and mode controls, battery details, carrier aggregation and VoLTE rows');
})().catch(error => { console.error(error); process.exit(1); });
