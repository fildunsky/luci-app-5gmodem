const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/maplayers.js'), 'utf8');
function element(tag, attrs = {}, children = []) {
 const e = { tag, ...attrs, attributes: attrs, style: {}, children: Array.isArray(children) ? children : [children], value: '',
  appendChild(c) { this.children.push(c); }, replaceChildren(...kids) { this.children = kids; } };
 return e;
}
const settle = () => new Promise(resolve => setImmediate(resolve));
function fixture(response, options, stored = {}) {
 const calls = [], timers = new Map(), cooldowns = new Map(), markers = [], groups = [], listeners = {}, credits = new Set();
 let serial = 0; const storage = new Map(Object.entries(stored));
 const win = { localStorage: {getItem:k=>storage.get(k)??null,setItem:(k,v)=>storage.set(k,String(v))}, clearTimeout: id => {timers.delete(id); cooldowns.delete(id);}, setTimeout: (fn, delay) => { (delay > 5000 ? cooldowns : timers).set(++serial, {fn,delay}); return serial; } };
 const widget = new Function('baseclass', 'rpc', 'window', 'E', 'L', '_', source)(
  {extend: x => x}, {declare: () => (...args) => { calls.push(args); return Promise.resolve(response(...args)); }},
  win, element, {url: x => '/' + x}, s => s).build(options);
 const map = {zoom: 14, bounds: [1, 2, 1.1, 2.1], getZoom() {return this.zoom;}, getMaxZoom(){return 20;}, fitBounds(b,o){this.fitted={b,o};},
  latLngToLayerPoint(ll){const k=100000*2**(this.zoom-14);return {x:ll[1]*k,y:ll[0]*k};},
  layerPointToLatLng(p){const k=100000*2**(this.zoom-14);return {lat:p.y/k,lng:p.x/k};},
  getBounds() {const b = this.bounds; return {getSouth: () => b[0], getWest: () => b[1], getNorth: () => b[2], getEast: () => b[3]};},
  createPane: () => ({style:{}}), on: (name, fn) => {listeners[name] = fn;}, off: name => delete listeners[name],
  attributionControl: {addAttribution: s => credits.add(s), removeAttribution: s => credits.delete(s)} };
 const lf = {layerGroup() { const g = {points: [], addTo() {return this;}, clearLayers() {this.points = [];}}; groups.push(g); return g;},
  divIcon(opts) {return opts;}, marker(ll, opts) {return this.circleMarker(ll, opts);},
  circleMarker(ll, opts) {const m = {ll, opts, on(event, fn){(this.events||(this.events={}))[event]=fn;return this;}, bindTooltip(p,opts){this.tooltip=p;this.tooltipOptions=opts;return this;},openTooltip(){this.tooltipOpen=true;return this;},closeTooltip(){this.tooltipOpen=false;return this;},bindPopup(p) {this.popup = p; return this;}, addTo(g) {g.points.push(this); markers.push(this); return this;}}; return m;} };
 const allChecks = widget.node.children.filter(c=>c.class==='tg-gps-layergroup').flatMap(c=>c.children.filter(x=>x.tag==='label')).map(c=>c.children[0]);
 const checks=['Towers (4Cells)','Towers (Speedmetrics)','Speed measurements (Speedmetrics)','Measurements (4Cells)'].map(label=>allChecks.find(c=>c['aria-label']===label));
 const filters = widget.node.children.find(c => c.class === 'tg-gps-layerfilters');
 const hint = widget.node.children.find(c => c.tag === 'small');
 return {widget, calls, map, markers, groups, credits, filters, hint, listeners, storage,
  enable(i, on = true) {checks[i].checked = on; checks[i].change();},
  async flush() {const jobs = [...timers.values()]; timers.clear(); jobs.forEach(job => job.fn()); for (let i=0;i<8;i++) await settle();},
  resumeAfter(delay) {for(const [key, job] of cooldowns){if(job.delay===delay){cooldowns.delete(key);job.fn();}}},
  attach() {widget.attach(map, lf);} };
}
async function main() {
 const compact = {cols:['lat','lon','dl','operator','unexpected'], dicts:{operator:['<img src=x onerror=alert(1)>']}, rows:[[1.05,2.05,80,0,'discard']]};
 let f = fixture(() => ({ok:true, data:compact}));
 f.attach(); await f.flush(); assert.equal(f.calls.length,0,'off by default means no external request');
 f.enable(2); await f.flush();
 assert.equal(f.calls[0][0],'speed'); assert.equal(f.markers.length,1);
 assert.deepEqual(f.markers[0].ll,[1.05,2.05]); assert.match(f.markers[0].opts.icon.html.attributes.style,/#53b687/);
 assert.equal(f.markers[0].opts.icon.html.children[1].children[0],'↓ 80');
 assert.equal(f.markers[0].popup.children[0].children[0],'<img src=x onerror=alert(1)>','untrusted labels stay text nodes');
 assert.ok(f.credits.size); f.enable(2,false); await f.flush(); assert.equal(f.groups[2].points.length,0); assert.equal(f.credits.size,0);

 f = fixture(kind => ({ok:true, data:kind === 'operators' ? [{englishName:'Example',operators:[{internalCode:'001001',name:'Example network'}]}] : {success:true,data:[{lat:1.01,lon:2.01,num:123,bands:'B3'}]}}));
 f.attach(); f.enable(0); await f.flush(); assert.equal(f.calls.length,1); assert.equal(f.calls[0][0],'operators');
 const [operator, technology] = f.filters.children; operator.value='001001'; technology.value='lte'; operator.change(); await f.flush();
 assert.equal(f.calls.at(-1)[0],'fourcells'); assert.equal(f.calls.at(-1)[6],'001001'); assert.equal(f.calls.at(-1)[7],'lte');
 assert.equal(f.groups[0].points.length,1);
 f.map.zoom=3; f.listeners.moveend(); await f.flush(); assert.equal(f.calls.length,2,'do not fetch below overview scale'); assert.equal(f.groups[0].points.length,0);


 f = fixture(() => ({ok:true, data:{items:[{lat:1.01,lon:2.01,enb:123,dl:80,ul:12,nr:true}]}}));
 f.attach(); f.enable(1); await f.flush();
 assert.equal(f.markers[0].opts.icon.html.class,'tg-gps-towerplate');
 assert.equal(f.markers[0].opts.icon.html.children[0].children[0],'123');
 assert.equal(f.markers[0].opts.icon.html.children[1].children[0],'5G');

 for (const [dl,ul,label] of [[null,20,'↑ 20'],[null,null,'—'],[0,20,'↓ 0.0']]) {
  f = fixture(() => ({ok:true,data:{items:[{lat:1.01,lon:2.01,dl,ul}]}}));
  f.attach(); f.enable(2); await f.flush();
  assert.equal(f.markers[0].opts.icon.html.children[1].children[0],label);
 }

 let release; f = fixture(() => new Promise(resolve => {release=resolve;}));
 f.attach(); f.enable(2); await f.flush(); f.enable(2,false);
 release({ok:true,data:compact}); await f.flush(); assert.equal(f.markers.length,0,'disabled layer cannot reappear after a late reply');

 let late; f = fixture(() => new Promise(resolve => {late=resolve;}));
 f.attach(); f.enable(2); await f.flush(); f.widget.destroy();
 late({ok:true,data:compact}); await f.flush(); assert.equal(f.markers.length,0,'leaving the page cannot paint a late reply');

 f = fixture(() => ({ok:false,error:'sign_in_required'})); f.attach(); f.enable(1); await f.flush();
 assert.match(f.hint.textContent,/Sign in/); assert.equal(f.markers.length,0);

 const helpers = new Function('E', source.slice(source.indexOf('function towerColor'), source.indexOf('return baseclass.extend'))+'return {clusterSpeeds,medianSpeed,speedColor,towerColor};')(element);
 assert.deepEqual([0,1,2,3,4].map(locType=>helpers.towerColor({locType,bsType:0})),['#f30000','#f30000','#00c000','#00c000','#00c000']);
 assert.equal(helpers.towerColor({locType:1,bsType:6}),'#85855e');assert.equal(helpers.towerColor({locType:3,bsType:6}),'#ffff00');
 assert.deepEqual([19,20,49,50,149,150,null].map(helpers.speedColor),['#f25660','#f2ac4b','#f2ac4b','#53b687','#53b687','#00bbff','#8c8c8e']);
 const close=[{lat:1,lon:2,dl:10},{lat:1,lon:2.0002,dl:30},{lat:1,lon:2.0004,dl:200}];
 assert.equal(helpers.clusterSpeeds(close,ll=>({x:ll[1]*100000,y:ll[0]*100000})).length,1);
 assert.equal(helpers.clusterSpeeds(close,ll=>({x:ll[1]*1000000,y:ll[0]*1000000})).length,3);
 assert.equal(helpers.medianSpeed(close,'dl'),30);
 assert.equal(helpers.medianSpeed([{dl:null},{dl:0},{dl:20}],'dl'),10,'real zero is distinct from missing data');
 const original=JSON.stringify(close);helpers.clusterSpeeds(close,()=>({x:0,y:0}));assert.equal(JSON.stringify(close),original);
 f=fixture(()=>({ok:true,data:{items:close}}));f.attach();f.enable(2);await f.flush();
 assert.equal(f.groups[2].points.length,1);let cluster=f.groups[2].points[0];
 assert.match(cluster.opts.icon.html.class,/speedcluster/);assert.equal(cluster.opts.icon.html.children[2].children[0],'3');
 cluster.events.click();assert.equal(f.map.fitted.o.maxZoom,17);
 f.map.zoom=18;f.listeners.moveend();assert.equal(f.groups[2].points.length,3,'zoom redraws cached points without waiting for the network');

 f=fixture(kind=>({ok:true,data:kind==='operators'?[{operators:[{internalCode:'001001',name:'Example'}]}]:{success:true,data:[]}}),
  {getOperator:()=>Promise.resolve({operator_mcc:'001',operator_mnc:'01'})});
 f.attach();f.enable(0);await f.flush();await f.flush();
 assert.equal(f.filters.children[0].value,'001001');assert.equal(f.calls.at(-1)[6],'001001');
 let operatorReply;
 f=fixture(()=>({ok:true,data:[{operators:[{internalCode:'001001',name:'A'},{internalCode:'001002',name:'B'}]}]}),
  {getOperator:()=>new Promise(resolve=>{operatorReply=resolve;})});
 f.attach();f.enable(0);await f.flush();f.filters.children[0].value='001002';f.filters.children[0].change();
 operatorReply({operator_mcc:'001',operator_mnc:'01'});await settle();
 assert.equal(f.filters.children[0].value,'001002','late operator detection must not overwrite a manual choice');

 f=fixture(()=>({ok:true,data:compact}));f.attach();f.enable(2);await f.flush();
 const initial=f.calls.length;
 for(let i=0;i<5;i++){f.map.bounds=f.map.bounds.map(v=>v+.00001);f.listeners.moveend();await f.flush();}
 assert.equal(f.calls.length,initial,'GPS jitter stays inside the buffered cache');
 f.enable(2,false);f.map.bounds=[3,4,3.1,4.1];f.listeners.moveend();await f.flush();
 assert.equal(f.calls.length,initial,'disabled layers never schedule new external requests');
 f=fixture(()=>({ok:false,error:'rate_limited'}));f.attach();f.enable(2);await f.flush();
 f.map.bounds=[3,4,3.1,4.1];f.listeners.moveend();await f.flush();f.enable(2,false);f.enable(2);await f.flush();
 assert.equal(f.calls.length,1,'rate limiting pauses the provider until the cooldown expires');
 f=fixture(()=>({ok:false,error:'rate_limited'}));f.attach();f.enable(0);await f.flush();
 f.enable(0,false);f.enable(0);await f.flush();assert.equal(f.calls.length,1,'operator loading also respects provider suspension');

 let resumed=0, paused=0;
 f=fixture(kind=>kind==='operators'?{ok:true,data:[{operators:[{internalCode:'001001',name:'Example'}]}]}:{ok:true,data:{success:true,data:[]}},
  {measurements:{configure(){},pause(){paused++;},resume(){resumed++;}}});
 f.attach();f.enable(0);f.enable(3);await f.flush();
 f.filters.children[0].value='001001';f.filters.children[0].change();await f.flush();
 const beforePause=f.calls.length;
 f.widget.measurementStatus('provider_paused',7);
 f.map.bounds=[3,4,3.1,4.1];f.listeners.moveend();await f.flush();
 assert.equal(f.calls.length,beforePause,'towers and measurements share the 4Cells cooldown');
 assert.equal(paused,1);
 f.resumeAfter(7000);await f.flush();
 assert.equal(resumed,1,'measurement tiles resume even without a map move');
 assert.equal(f.calls.length,beforePause+1,'towers automatically reload when the server cooldown ends');
 f.widget.measurementStatus('provider_paused',7);
 f.widget.destroy();f.resumeAfter(7000);await f.flush();
 assert.equal(resumed,1,'a closed view never restarts external layers');

 let fourRequests=0;
 f=fixture(kind=>{
  if(kind==='operators')return {ok:true,data:[{operators:[{internalCode:'001001',name:'Example'}]}]};
  if(kind==='fourcells'){
   if(++fourRequests===1)return {ok:false,error:'busy'};
   return {ok:true,data:{success:true,data:Array.from({length:61},(_,i)=>({lat:1.01+i*.00001,lon:2.01,num:i}))}};
  }
  return {ok:true,data:{items:kind==='towers'?[]:Array.from({length:5},(_,i)=>({lat:1.02+i*.002,lon:2.02,dl:i+10}))}};
 });
 f.attach();f.enable(0);await f.flush();f.filters.children[0].value='001001';f.filters.children[0].change();await f.flush();
 assert.match(f.hint.textContent,/Towers \(4Cells\): An account operation/);
 f.enable(1);f.enable(2);await f.flush();
 assert.match(f.hint.textContent,/Towers \(4Cells\): 61/);
 assert.match(f.hint.textContent,/Towers \(Speedmetrics\): 0/);
 assert.match(f.hint.textContent,/Speed measurements \(Speedmetrics\): 5/);
 assert.equal(f.groups[0].points.length,61);assert.equal(f.groups[1].points.length,0);

 f=fixture(kind=>kind==='operators'?{ok:true,data:[{operators:[{internalCode:'001001',name:'Example'}]}]}:
  kind==='fourcells'?{ok:false,error:'access_denied'}:{ok:true,data:{items:[{lat:1.02,lon:2.02,dl:50}]}});
 f.attach();f.enable(0);await f.flush();f.filters.children[0].value='001001';f.filters.children[0].change();f.enable(2);await f.flush();
 assert.match(f.hint.textContent,/Towers \(4Cells\): The service denied access/);
 assert.match(f.hint.textContent,/Speed measurements \(Speedmetrics\): 1/,'healthy service counts survive another provider failure');
 assert.equal(f.groups[0].points.length,0);

 // Popup auto-pan and GPS-follow movement must not replace its source marker.
 let explored=0, failTowers=false;
 const towerReply={success:true,data:[{lat:1.01,lon:2.01,num:123}]};
 f=fixture(kind=>kind==='operators'?{ok:true,data:[{operators:[{internalCode:'001001',name:'Example'}]}]}:
  kind==='fourcells'?(failTowers?{ok:false,error:'busy'}:{ok:true,data:towerReply}):{ok:true,data:compact},
  {onExplore:()=>explored++});
 f.attach();f.enable(0);await f.flush();f.filters.children[0].value='001001';f.filters.children[0].change();f.enable(2);await f.flush();
 const towerMarker=f.groups[0].points[0], speedMarker=f.groups[2].points[0], requestCount=f.calls.length;
 f.listeners.moveend();assert.equal(f.groups[2].points[0],speedMarker,'pan must preserve the popup source marker');await f.flush();
 assert.equal(f.groups[0].points[0],towerMarker,'cached refresh must preserve tower markers');
 assert.equal(f.groups[2].points[0],speedMarker,'cached refresh must preserve speed markers');
 f.listeners.popupopen();assert.equal(explored,1,'opening any provider popup disables GPS-follow recentering');
 f.map.bounds=[3,4,3.1,4.1];f.listeners.moveend();await f.flush();
 assert.equal(f.calls.length,requestCount,'popup auto-pan must not trigger new provider requests');
 assert.equal(f.groups[0].points[0],towerMarker);assert.equal(f.groups[2].points[0],speedMarker);
 failTowers=true;f.listeners.popupclose();await f.flush();
 assert.equal(f.groups[0].points[0],towerMarker,'transient refresh errors keep previously displayed towers');
 f.filters.children[1].value='nr';f.filters.children[1].change();await f.flush();
 assert.equal(f.groups[0].points.length,0,'filter changes still discard mismatching old towers');
 f.widget.destroy();assert.equal(f.listeners.popupopen,undefined);assert.equal(f.listeners.popupclose,undefined);

 f=fixture(kind=>({ok:true,data:kind==='operators'?[{operators:[{internalCode:'001001',name:'Example'}]}]:{success:true,data:[{lat:1.01,lon:2.01,num:123,bands:'B3+B7'}]}}),{},
  {'5gmodem.gps.external.fourcells':'1','5gmodem.gps.external.operator':'001001','5gmodem.gps.external.technology':'nr'});
 f.attach();await f.flush();await f.flush();
 assert.equal(f.filters.children[0].value,'001001','manual operator restored after options load');
 assert.equal(f.filters.children[1].value,'nr','network type survives reload');
 assert.equal(f.groups[0].points.length,1,'saved provider layer restores on attachment');
 const captionMarker=f.groups[0].points[0];
 assert.equal(captionMarker.tooltip.children[0].children[0],'123');
 assert.equal(captionMarker.tooltip.children[1].children[0],'B3+B7');
 assert.equal(captionMarker.tooltipOpen,false,'labels stay out of distant views');
 f.map.zoom=15;f.listeners.moveend();assert.equal(captionMarker.tooltipOpen,true);
 f.enable(0,false);assert.equal(f.storage.get('5gmodem.gps.external.fourcells'),'0');
 f.filters.children[1].value='lte';f.filters.children[1].change();assert.equal(f.storage.get('5gmodem.gps.external.technology'),'lte');
 f.enable(2);assert.equal(f.storage.get('5gmodem.gps.external.speed'),'1');

 f=fixture(kind=>({ok:true,data:kind==='operators'?[{operators:[{internalCode:'001001',name:'Example'}]}]:{success:true,data:[{lat:1.01,lon:2.01,num:123}]}}));
 f.attach();f.enable(0);await f.flush();f.filters.children[0].value='001001';
 f.map.zoom=9;f.map.bounds=[1,2,3,4];f.filters.children[0].change();await f.flush();
 assert.equal(f.calls.at(-1)[0],'fourcells','overview requests 4Cells towers across a wider area');
 assert.equal(f.groups[0].points.length,1);
 f.enable(2);await f.flush();assert.match(f.hint.textContent,/Speed measurements \(Speedmetrics\): Zoom in/,'Speedmetrics retains its own scale limit');
 f.map.bounds=[10,20,12,22];f.listeners.moveend();await f.flush();
 assert.ok(Math.abs(+f.calls.at(-1)[1]-9.7)<.00002,'panning to another city requests new bounds');

 const configurations=[];
 f=fixture(kind=>({ok:true,data:kind==='operators'?[{operators:[{internalCode:'001001',name:'Example'}]}]:[]}),{measurements:{configure:c=>configurations.push(c),pause:()=>{}}});
 f.attach();f.enable(3);await f.flush();
 assert.match(f.hint.textContent,/Measurements \(4Cells\): Select operator/,'measurement-only status is never blank');
 f.filters.children[0].value='001001';f.filters.children[0].change();
 assert.equal(configurations.at(-1).enabled,true);
 assert.equal(configurations.at(-1).operator,'001001');
 f.widget.measurementStatus('loading');assert.match(f.hint.textContent,/Measurements \(4Cells\): Loading/);
 f.widget.measurementStatus(null);await f.flush();assert.match(f.hint.textContent,/Measurements \(4Cells\): ✓/,'point refresh preserves loaded raster status');
 f.enable(2);await f.flush();
 assert.match(f.hint.textContent,/Speed measurements \(Speedmetrics\): 0/);
 assert.match(f.hint.textContent,/Measurements \(4Cells\): ✓/,'both kinds keep their own status');
 f.widget.measurementStatus('rate_limited');assert.match(f.hint.textContent,/Too many requests/);
 assert.match(f.hint.textContent,/Speed measurements \(Speedmetrics\): 0/,'tile error preserves point counts');

 let operatorRequests=0;
 f=fixture(()=>++operatorRequests===1?{ok:false,error:'busy'}:{ok:true,data:[{operators:[{internalCode:'001001',name:'Example'}]}]});
 f.attach();f.enable(3);await f.flush();
 assert.match(f.hint.textContent,/account operation/,'operator failure stays visible after map refresh');
 await f.flush();assert.equal(operatorRequests,2,'temporary operator failure gets a bounded retry');
 assert.equal(f.filters.children[0].children.length,2,'retry populates the selector');
 f=fixture(()=>({ok:false,error:'network'}));f.attach();f.enable(3);
 for(let i=0;i<6;i++){await f.flush();}
 assert.equal(f.calls.length,3,'network retry does not loop forever');
 f.filters.children[0].focus();await f.flush();assert.equal(f.calls.length,4,'opening empty selector can retry explicitly');
 f=fixture(()=>({ok:false,error:'rate_limited'}));f.attach();f.enable(3);
 for(let i=0;i<5;i++){await f.flush();}
 assert.equal(f.calls.length,1,'provider cooldown never causes repeated handbook requests');
 assert.match(f.hint.textContent,/Too many requests/,'provider error cannot be overwritten by Select operator');
 f=fixture(()=>({ok:false,error:'network'}));f.attach();f.enable(3);await f.flush();f.widget.destroy();await f.flush();
 assert.equal(f.calls.length,1,'leaving the page cancels operator retry');

 console.log('PASS: external map layers, compact data, authorization errors, bounds, races and cleanup');
}
main().catch(e => {console.error(e); process.exitCode=1;});
