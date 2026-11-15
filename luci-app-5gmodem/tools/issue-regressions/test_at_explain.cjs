// AT console explanations (view/modem5g/atexplain.js): replies are decoded on the same scales as
// the pollers, quality words come from mutil, identifiers are reduced to their length.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../htdocs/luci-static/resources/view/modem5g');

String.prototype.format = function() {
	const a = arguments; let i = 0;
	return this.replace(/%[sd]/g, () => String(a[i++]));
};
const _ = s => s;
const baseclass = { extend: o => o };
function load(file, deps) {
	const src = fs.readFileSync(path.join(root, file), 'utf8');
	const names = Object.keys(deps);
	const fn = vm.runInThisContext('(function(' + names.join(',') + ') {' + src + '\n})', { filename: file });
	return fn.apply(null, names.map(n => deps[n]));
}
const mutil = load('mutil.js', { baseclass, icons: { url: () => '' }, _ });
const ax = load('atexplain.js', { baseclass, mutil, _ });

function lines(cmd, out) {
	const r = ax.explain(cmd, out);
	assert.ok(r, 'known command ' + cmd);
	return r.map(x => x.lines.join(' | ')).join(' || ');
}
function has(cmd, out, ...want) {
	const s = lines(cmd, out);
	for (const w of want) { assert.ok(s.includes(w), cmd + ': "' + w + '" not in "' + s + '"'); }
	return s;
}

// splitting and normalisation
assert.deepEqual(ax.splitCmd('at+cgmi;+CGMM; +cgmr'), [ 'AT+CGMI', 'AT+CGMM', 'AT+CGMR' ]);
assert.deepEqual(ax.splitCmd('AT+CPBS="ON";+CNUM'), [ 'AT+CPBS="ON"', 'AT+CNUM' ]);
assert.equal(ax.explain('AT+UNKNOWNCMD', 'OK'), null);
assert.equal(ax.explain('AT+CGMI;+CGMM;+CGMR', 'X').length, 3);

// CSQ: 2n-113 dBm, the grade follows mutil (csq 20 = -73 dBm, good)
has('AT+CSQ', 'AT+CSQ\n+CSQ: 20,99\nOK', 'CSQ 20 ≈ -73 dBm (good)', 'not reported');
has('AT+CSQ', '+CSQ: 99,99', 'unknown (99)');
has('AT+CSQ', '+CSQ: 165,99,17', '-51 dBm (extended');
has('AT+CSQ', '+CSQ: 10,3', 'class 3 of 7');

// CESQ: rsrp n-141, rsrq n/2-20
has('AT+CESQ', '+CESQ: 99,99,255,255,27,65', 'RSRP -76 dBm (excellent)', 'RSRQ -6.5 dB');
has('AT+CESQ', '+CESQ: 99,99,255,255,255,255', 'No measurements');

// COPS / registration
has('AT+COPS?', '+COPS: 0,2,"25099",7', 'automatic', '250 99', '4G (LTE)');
has('AT+COPS?', '+COPS: 0,0,"004D00540053",7', 'Operator: MTS');
has('AT+COPS?', '+COPS: 0', 'not registered');
has('AT+COPS?', '+COPS: 1,0,"Operator",13', 'manual', '5G NSA');
let s = has('AT+CEREG?', '+CEREG: 2,1,"FD37","9C","3994766",7', 'registered, home network', '64823', '60376934', 'eNB) 235847, sector 102', '4G (LTE)');
s = has('AT+CREG?', '+CREG: 2,1,"FFFE","3994766",7', 'Cell ID: 60376934');
assert.ok(!s.includes('65534'), 'LAC FFFE is not a real area');
has('AT+CREG?', '+CREG: 1,5', 'roaming');
has('AT+C5GREG?', '+C5GREG: 2,1,"00A1B2","0000000012345",11', '5G SA');
has('AT+CEREG?', '+CEREG: 0,3', 'denied');

// data profiles
s = has('AT+CGDCONT?', '+CGDCONT: 1,"IP","internet","0.0.0.0",0,0\n+CGDCONT: 2,"IPV4V6","ims","0.0.0.0",0,0\n+CGDCONT: 10,"IPV6","","",0,0',
	'Profile 1: APN "internet", IPv4', 'Profile 2: APN "ims", IPv4 + IPv6', 'Profiles without an APN: 1');
has('AT+CGPADDR', '+CGPADDR: 1,10.1.2.3\n+CGPADDR: 2,10.1.2.4,32.1.0.0.0.0.0.0.0.0.0.0.0.0.0.1\n+CGPADDR: 5,0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0',
	'Profile 1 has an address: IPv4', 'Profile 2 has an address: IPv4 + IPv6');
assert.ok(!lines('AT+CGPADDR', '+CGPADDR: 1,10.1.2.3').includes('10.1.2.3'), 'addresses are not repeated');
has('AT+CGPADDR', '+CGPADDR: 1,0.0.0.0', 'No profile has an address');
has('AT+CGATT?', '+CGATT: 1', 'mobile data is available');
has('AT+CGACT?', '+CGACT: 1,1\n+CGACT: 10,0\n+CGACT: 2,1', 'Active profiles: 1, 2');

// SIM and radio
has('AT+CPIN?', '+CPIN: READY', 'ready');
has('AT+CPIN?', '+CPIN: SIM PUK', 'PUK');
has('AT+CFUN?', '+CFUN: 1', 'radio is on');
has('AT+CFUN?', '+CFUN: 4', 'Flight mode');
has('AT+CCLK?', '+CCLK: "26/11/15,11:46:42+12"', '2026-11-15 11:46:42', 'UTC+3');
has('AT+CCLK?', '+CCLK: "2026/11/15,11:46:19+03"', '2026-11-15', 'UTC+3');
has('AT+CSCON?', '+CSCON: 0,1', 'RRC connected');

// identifiers: only the length, never the value
const IMEI = '123456789012345', ICC = '89000000000000000000';
s = lines('AT+CGSN', 'AT+CGSN\n' + IMEI + '\nOK');
assert.ok(s.includes('IMEI: 15 digits') && !s.includes(IMEI), s);
s = lines('AT+CIMI', '000000000000000');
assert.ok(s.includes('IMSI: 15 digits') && !s.includes('000000000000000'), s);
s = lines('AT+ICCID', '+ICCID: ' + ICC);
assert.ok(s.includes('ICCID: 20 digits') && !s.includes(ICC), s);
s = lines('AT+CPBS="ON";+CNUM', '+CNUM: "","+70000000000",145');
assert.ok(s.includes('A number is stored') && !s.includes('70000000000'), s);
has('AT+CPBS="ON";+CNUM', '', 'No own number');
s = lines('ATI', 'Manufacturer: X\nIMEI: ' + IMEI);
assert.ok(s.includes('also shows the IMEI') && !s.includes(IMEI), s);

// Quectel
has('AT+QENG="servingcell"', '+QENG: "servingcell","NOCONN","LTE","FDD",250,01,1A2B3C4,123,1300,3,5,5,ABCD,-95,-10,-65,12,10,20,-',
	'registered, idle', 'B3 @20 MHz', 'PCI 123', 'RSRP -95 dBm (good)', 'RSRQ -10 dB (excellent)', 'SINR 12 dB (good)');
has('at+qeng="servingcell"', '+QENG: "servingcell","NOCONN","NR5G-SA","TDD",250,01,1A2B3C4D,500,ABCDEF,627264,78,12,-101,-11,8,1,-',
	'5G SA n78 @100 MHz', 'RSRP -101 dBm (good)');
has('AT+QENG="servingcell"', '+QENG: "servingcell","CONNECT"\n+QENG: "LTE","FDD",250,01,1A2B3C4,123,1300,3,5,5,ABCD,-90,-9,-60,15,10,20\n+QENG: "NR5G-NSA",250,01,500,-100,10,-11,627264,78,12',
	'connected', 'NSA anchor: 4G (LTE) B3 @20 MHz', 'NSA carrier: n78 @100 MHz', 'RSRP -100 dBm');
has('AT+QNWINFO', '+QNWINFO: "FDD LTE","25001","LTE BAND 3",1300', 'FDD LTE, band B3, channel 1300');
has('AT+QCAINFO', '+QCAINFO: "PCC",1300,100,"LTE BAND 3",1,123,-90,-9,-60,15\n+QCAINFO: "SCC",3000,75,"LTE BAND 7",1,321,-95,-10,-62,10,0,-,-',
	'Primary carrier: B3 @20 MHz', 'Added carriers: B7 @15 MHz');
has('AT+QCAINFO', '+QCAINFO: "PCC",1300,100,"LTE BAND 3",1,123,-90,-9,-60,15', 'aggregation is not in use');
has('AT+QRSRP', '+QRSRP: -90,-95,-140,-140,LTE', 'signal is heard on 2 of 4');
has('AT+QCFG="usbnet"', '+QCFG: "usbnet",2', 'MBIM');

// Huawei
has('AT^HCSQ?', '^HCSQ: "LTE",60,45,150,30', 'RSRP -96 dBm', 'SINR 9.8 dB', 'RSRQ -5 dB');
has('AT^SYSINFOEX', '^SYSINFOEX: 2,3,0,1,,6,"LTE",101,"LTE"', 'normal service', 'LTE');

// ZTE (field order as modem/usb/12864e28 and 2cd20004)
has('AT+ZRSSI', '+ZRSSI: -99,-8,-74,11.2', 'RSRP -99 dBm (good)', 'RSRQ -8 dB', 'RSSI -74 dBm', 'SINR 11.2 dB (good)');
has('AT+ZCAINFO?', '+ZCAINFO: 364, 1, 64823, 525, 15.0;          313, 1, 3, 1275, 15.0;', 'Primary carrier: B1 @15 MHz', 'Added carriers: B3 @15 MHz');
has('AT+ZCELLINFO?', '+ZCELLINFO: 60376934, 364, LTE B1, 525', 'band B1, channel 525');
has('AT$QCRSRP?', '$QCRSRP: 364,525,"-097.40",313,1275,"-087.40"', 'Cells heard: 2', 'PCI 313 on channel 1275, RSRP -87.4');
has('AT+ZPAS?', '+ZPAS: "LTE","CS_PS"', 'LTE, calls and data');
has('AT+ZSNT?', '+ZSNT: 0,0,0', 'automatic');
has('AT+ZULCA?', '+ZULCA: 1', 'Enabled');

// SIMCom / Telit / Fibocom
has('AT+CPSI?', '+CPSI: LTE,Online,250-01,0x1A2B,123456,77,EUTRAN-BAND3,1300,5,5,-90,-1000,-700,15', 'LTE, online, band B3');
has('AT+CNMP?', '+CNMP: 38', '4G');
has('AT#QSS?', '#QSS: 0,3', 'ready');
has('AT+GTACT?', '+GTACT: 20,6,3,101,103,107,5078', 'automatic', 'B1, B3, B7', 'n78');

// a decodable command without the expected reply says so; meaning-only commands do not
has('AT+CESQ', 'AT+CESQ', 'may not support');
assert.deepEqual(ax.explain('AT+QTEMP', '+QTEMP: "x",40')[0].lines, []);
assert.ok(ax.explain('AT+CFUN=1,1', '')[0].meaning.includes('Reboots'));

// every preset in the shipped template files has an explanation
const tdir = path.resolve(__dirname, '../../root/etc/5gmodem/modem/atcmmds');
let n = 0;
for (const f of fs.readdirSync(tdir)) {
	for (const raw of fs.readFileSync(path.join(tdir, f), 'utf8').split('\n')) {
		const l = raw.trim();
		if (!l || l[0] === '#') { continue; }
		for (const c of ax.splitCmd(l)) {
			n++;
			assert.ok(ax.explain(c, ''), f + ': no explanation for ' + c);
		}
	}
}
console.log('AT explanations: decoders agree with the pollers, ' + n + ' preset commands covered');
