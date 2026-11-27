const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/5gsettings.js'), 'utf8');
const start = source.indexOf('function verifyInstalled(');
const install = source.indexOf('function installUpdate(');
const code = source.slice(start, source.indexOf('\n}\n', install) + 2);
const drain = () => new Promise(resolve => setImmediate(resolve));
function fixture(status = {}, installed = '4.0.0') {
 const calls = [], timers = [], events = [];
 const context = vm.createContext({
  Promise, _: s => s, UPDBIN: '/usr/share/5gmodem/update.sh', updTarget: '4.0.0', upd: {},
  L: {resolveDefault: (p,d) => Promise.resolve(p).catch(() => d)},
  fs: {
   exec_direct: (script,args) => {calls.push({script,args});return Promise.resolve(JSON.stringify({current:installed}));},
   read_direct: () => Promise.resolve(status === null ? null : JSON.stringify(status)),
   exec: () => Promise.resolve({stdout:JSON.stringify(status)})
  },
  window: {setTimeout: fn => timers.push(fn)}, byId: () => null,
  finishUpdate: ver => events.push(['finish',ver]),
  updPill: (...args) => events.push(['pill',...args]),
  updLines: (...args) => events.push(['lines',...args]),
  updDetail: text => events.push(['detail',text]),
  btnState: (...args) => events.push(['button',...args]),
  updProgress() {}, updLine() {}, updBarReset() {},
  updErrText: error => error, installLabel: target => 'Retry '+target,
  ui: {addNotification() {}}, E() {}
 });
 vm.runInContext("String.prototype.format = function(...args) { let i=0; return this.replace(/%[ds]/g,()=>String(args[i++])); };",context);
 vm.runInContext(code,context);
 return {context,calls,timers,events};
}
function assertFailed(f) {
 assert.equal(f.calls.length,0,'explicit errors must not be overwritten by app-version verification');
 assert.ok(f.events.some(e=>e[0]==='pill' && e[1]==='bad'));
 assert.ok(f.events.some(e=>e[0]==='button' && e[2]==='install'),'retry button remains available');
 assert.ok(!f.events.some(e=>e[0]==='finish'),'no success, refresh or logout');
}
test('polling preserves helper failure although the app is already at the target version',async()=>{
 const f=fixture({error:'helper_update_failed',detail:'synthetic package manager failure',target:'4.0.0'});
 f.context.pollInstall(0,0);f.timers.shift()();await drain();
 assertFailed(f);
 assert.ok(f.events.some(e=>e[0]==='detail' && e[1].includes('synthetic package manager failure')));
});
test('initial install response also preserves explicit helper failure',async()=>{
 const f=fixture({error:'helper_update_failed'});await f.context.installUpdate();assertFailed(f);
});
test('other explicit package errors are not hidden by an installed app version',async()=>{
 const f=fixture();await f.context.failInstall('package installation failed','details','4.0.0');assertFailed(f);
});
test('timeout still recovers an installation whose success reply was lost',async()=>{
 const f=fixture();await f.context.pollInstall(301,0);
 assert.equal(f.calls.length,1);assert.ok(f.events.some(e=>e[0]==='finish' && e[1]==='4.0.0'));
});
test('lost contact also uses version verification',async()=>{
 const f=fixture(null);f.context.pollInstall(0,30);f.timers.shift()();await drain();
 assert.equal(f.calls.length,1);assert.ok(f.events.some(e=>e[0]==='finish'));
});
test('timeout keeps retry when app version did not change',async()=>{
 const f=fixture({},'3.0.0');await f.context.pollInstall(301,0);
 assert.equal(f.calls.length,1);assert.ok(!f.events.some(e=>e[0]==='finish'));
 assert.ok(f.events.some(e=>e[0]==='button' && e[2]==='install'));
});
