const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const file = path.resolve(__dirname, '../../htdocs/luci-static/resources/sms-tool-5gm/smssettings.js');
const text = fs.readFileSync(file, 'utf8');
const start = text.indexOf('function addUssdOptions(s) {');
const source = text.slice(start, text.indexOf('\n}', start) + 2);
const data = {'@5gmodem[0].active_modem':'1-1', 'm_1_1.at_port':'/dev/ttyUSB0', 'sms.ussdport':'/dev/ttyUSB0', 'sms.readport':'192.168.8.1'};
const options = {};
const uci = {
 get: (_, section, key) => data[section+'.'+key],
 set: (_, section, key, value) => { if (value == null) delete data[section+'.'+key]; else data[section+'.'+key] = value; }
};
const add = vm.runInNewContext('('+source+')', {uci, form:{Value:1,Flag:2,ListValue:3},_:x=>x});
add({option:(_,key)=>options[key]={value(){},depends(){}}});
const selected = options._ussd_port;
assert.equal(selected.cfgvalue(), '');
selected.write('sms','/dev/ttyUSB1');
assert.equal(selected.cfgvalue(), '/dev/ttyUSB1');
assert.equal(data['sms.readport'], '192.168.8.1');
assert.equal(data['sms.ussdport'], '/dev/ttyUSB0');
data['@5gmodem[0].active_modem'] = '2-1';
assert.equal(selected.cfgvalue(), '');
selected.write('sms','/dev/ttyUSB3');
assert.equal(data['m_1_1.ussd_port'], '/dev/ttyUSB1');
assert.equal(data['m_2_1.ussd_port'], '/dev/ttyUSB3');
selected.remove('sms');
assert.equal(selected.cfgvalue(), '');
assert.equal(data['m_1_1.ussd_port'], '/dev/ttyUSB1');
console.log('PASS: USSD port setting is modem-specific, resettable and independent of SMS');
