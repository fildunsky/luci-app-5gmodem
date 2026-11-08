const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../htdocs/luci-static/resources/view/modem5g');
function extract(file, name) {
 const text = fs.readFileSync(path.join(root, file), 'utf8');
 const start = text.indexOf('function '+name+'(');
 return text.slice(start, text.indexOf('\n}', start)+2);
}
const icon = vm.runInNewContext('('+extract('mutil.js','operatorIcon')+')');
const tabIcon = vm.runInNewContext('('+extract('modemtabs.js','operatorTabIcon')+')',{mutil:{operatorIcon:icon}});
const cases = [
 ['CBN','op-china-broadnet'],['China Broadnet','op-china-broadnet'],['China Broadcasting Network','op-china-broadnet'],['中国广电','op-china-broadnet'],['中國廣電','op-china-broadnet'],['CHN-CBN','op-china-broadnet'],
 ['CHINA TELECOM','op-china-telecom'],['中国电信','op-china-telecom'],['中國電信','op-china-telecom'],['CHN-CT','op-china-telecom'],
 ['China Mobile','op-china-mobile'],['中国移动','op-china-mobile'],['中國移動','op-china-mobile'],['CMCC','op-china-mobile'],
 ['CHINA UNICOM','op-china-unicom'],['中国联通','op-china-unicom'],['中國聯通','op-china-unicom'],['CUCC','op-china-unicom'],
 ["TELKOMSEL", "op-telkomsel"],["TSEL", "op-telkomsel"],["IDN-TSEL", "op-telkomsel"],["Simpati", "op-telkomsel"],["Kartu Halo", "op-telkomsel"],
 ["INDOSAT", "op-im3"],["IM3", "op-im3"],["Indosat Ooredoo Hutchison", "op-im3"],
 ["3", "op-tri"],["3 ID", "op-tri"],["Tri Indonesia", "op-tri"],["THREE", "op-tri"],
 ["XL", "op-xl"],["XL Axiata", "op-xl"],["XLSMART", "op-xl"],["XL Prioritas", "op-xl"],
 ["AXIS", "op-axis"],["IDN AXIS", "op-axis"],
 ["Smartfren", "op-smartfren"],["SMARTFREN 4G", "op-smartfren"],
 ["SK Telecom", "op-sk-telecom"],["SKT", "op-sk-telecom"],["SK텔레콤", "op-sk-telecom"],["에스케이텔레콤", "op-sk-telecom"],
 ["LG U+", "op-lg-uplus"],["LG Uplus", "op-lg-uplus"],["LGT", "op-lg-uplus"],["LG유플러스", "op-lg-uplus"],["엘지유플러스", "op-lg-uplus"],
 ["KOR KT", "op-kt"],["케이티", "op-kt"],["한국통신", "op-kt"],
 ["VIETTEL", "op-viettel"],["VN VIETTEL", "op-viettel"],
 ["VinaPhone", "op-vinaphone"],["VN VINAPHONE", "op-vinaphone"],["VNP", "op-vinaphone"],
 ["MobiFone", "op-mobifone"],["VN MOBIFONE", "op-mobifone"],["VMS", "op-mobifone"],
 ['Austria',null],['Axis Bank',null],['Three UK',null],['XL Energy',null],
 ['N-Vu5O',null],['RT-Mobile','op-rostelecom'],['KT','op-kt'],['Yota','op-yota']
];
for (const [name, expected] of cases) {
 assert.equal(icon(name),expected,name);
 if (expected) assert.ok(fs.existsSync(path.resolve(root, '../../icons/5gmodem', expected+'.svg')), expected+' asset');
 assert.equal(tabIcon(name),expected,name+' tab');
}
console.log('Operator icons: '+cases.length+' names match on cards and tabs');
