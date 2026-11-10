const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/5gdetail.js'), 'utf8');
const nodes = new Map();
function element(tag, attributes, text) {
  attributes = Object.fromEntries(Object.entries(attributes || {}).filter(([, value]) => value != null).map(([key, value]) => [key, typeof value === 'function' ? value : String(value)]));
  const node = { tag, attributes, style: {}, children: [], value: '', classes: new Set(),
    appendChild(child) { if (typeof child === 'string') child = { textContent: child }; child.parentNode = this; this.children.push(child); },
    get childNodes() { return this.children; },
    get innerHTML() { return this.html || ''; },
    set innerHTML(value) { this.html = value; this.children = []; this.value = ''; },
    get textContent() { return this.value + this.children.map(child => child.textContent).join(''); },
    set textContent(value) { this.value = value; this.children = []; },
    setAttribute(key, value) { this.attributes[key] = value; },
    getAttribute(key) { return this.attributes[key]; },
    removeAttribute(key) { delete this.attributes[key]; },
    querySelector(selector) { return this.children.find(child => '.' + child.attributes.class === selector); },
    remove() { this.parentNode.children = this.parentNode.children.filter(child => child !== this); }
  };
  node.classList = { add: key => node.classes.add(key), remove: key => node.classes.delete(key) };
  if (typeof text === 'string') node.textContent = text;
  if (Array.isArray(text)) text.forEach(child => node.appendChild(child));
  if (node.attributes.id) nodes.set(node.attributes.id, node);
  return node;
}
['simslotn', 'battn', 'tempsn', 'tempn'].forEach(id => element('div', { id }));
const context = { document: { getElementById: id => nodes.get(id), querySelector: () => null }, E: element, _: value => value,
  simSlotsSeen: false,
  sameRender(node, key) { const same = node.key === key; node.key = key; return same; } };
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function renderSimSlots('), source.indexOf('var slotsInflight =')), context);
vm.runInContext(source.slice(source.indexOf('var TEMP_SENSORS ='), source.indexOf('function tempsOpen()')), context);
vm.runInContext(source.slice(source.indexOf('function renderBattery(json)'), source.indexOf('function chipBox(')), context);
context.renderAndroidSlots({ backend: 'android', android_slot: '1', android_sims: [{ slot: '0', subscription_id: '1' }, { slot: '1', subscription_id: '5' }] });
const box = nodes.get('simslotn');
assert.equal(box.children.length, 2);
assert.equal(box.textContent, 'SIM 1SIM 2');
assert.ok(box.children.every(child => child.attributes.disabled));
assert.match(box.children[1].attributes.class, /tg-current/);
assert.doesNotMatch(box.children[0].attributes.class, /tg-current/);
context.renderAndroidSlots({ backend: 'android', android_slot: '0', android_sims: [{ slot: '0', subscription_id: '1' }, { slot: '1', subscription_id: '5' }] });
assert.match(box.children[0].attributes.class, /tg-current/);
context.renderAndroidSlots({ backend: 'android', android_slot: '0', android_sim_switch: '1', android_sims: [{ slot: '0', subscription_id: '1' }, { slot: '1', subscription_id: '5' }] });
assert.ok(box.children.every(child => !Object.hasOwn(child.attributes, 'disabled')));
context.renderBattery({ backend: 'android', battery: '57', battery_charging: '1' });
assert.match(nodes.get('battn').innerHTML, /57%/);
assert.match(nodes.get('battn').title, /charging/);
context.renderTemps({ temps: 'modem=38 cpu=39 bat=32', temperature_sensors: [{ name: 'mdmss-0', value: 38 }, { name: '<sensor>', value: 39 }] });
const main = nodes.get('tempn');
assert.ok(main.classes.has('tg-texp'));
const popup = main.querySelector('.tg-tpop');
assert.ok(popup);
assert.match(popup.textContent, /Processor.*39.0 °C/);
assert.match(popup.textContent, /Battery.*32.0 °C/);
assert.doesNotMatch(popup.textContent, /mdmss|<sensor>/);
assert.equal(popup.style.overflowY, undefined);
assert.equal(nodes.get('tempsn').children.length, 3);
assert.equal(nodes.has('android-info'), false);
console.log('PASS: Android uses standard SIM buttons, battery indicator and temperature disclosure');
