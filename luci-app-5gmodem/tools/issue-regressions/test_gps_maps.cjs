const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/gps.js'), 'utf8');
const maps = source.slice(source.indexOf('var OSM_TILES ='), source.indexOf('var POLL_MS ='));
const start = source.indexOf('function setMapStyle(k, remember) {');
const change = source.slice(start, source.indexOf('\n\t\tsetMapStyle(mapKey, false);', start));
const build = new Function('st', 'mp', 'mapSec', 'window', 'loadMapLibre', 'isDarkUI', 'ui', 'E', '_',
 maps + 'var mapKey="osm"; function styleOf(k){return mapByKey(k)||MAPS[0];}\n' + change +
 '\nreturn {set:setMapStyle,key:()=>mapKey,maps:MAPS};');
function deferred() { let resolve, reject; const promise = new Promise((yes,no)=>{resolve=yes;reject=no;}); return {promise,resolve,reject}; }
function fixture(loader) {
 const layers = new Set(), disposed = [], messages = [], stored = new Map();
 const overlays = [{kind:'marker'}, {kind:'track'}, {kind:'accuracy'}];
 overlays.forEach(x=>layers.add(x));
 const lf = {CRS:{EPSG3857:{code:3857},EPSG3395:{code:3395}}};
 const map = {options:{crs:lf.CRS.EPSG3857}, center:{lat:0,lng:0},zoom:16,
  getCenter(){return this.center;},getZoom(){return this.zoom;},
  setMaxZoom(v){this.options.maxZoom=v;},setMinZoom(v){this.options.minZoom=v;},
  setMaxBounds(v){this.options.maxBounds=v;},_resetView(c,z){this.center=c;this.zoom=z;},
  removeLayer(layer){if(layer.onRemove)layer.onRemove(this);if(layers.delete(layer))disposed.push(layer);}};
 const layer = (kind,url,options)=>({kind,url,options,addTo(){layers.add(this);},bringToBack(){}});
 lf.tileLayer=(url,options)=>layer('raster',url,options);
 const adapter={maplibreGL:options=>layer('vector',options.style,options)};
 let loads=0;
 const st={lf,map,tiles:null},mp={style:{}},dark=[];
 const view=build(st,mp,{classList:{toggle:(_name,on)=>dark.push(on)}},
  {localStorage:{setItem:(k,v)=>stored.set(k,v)}},()=>{loads++;return loader?loader(adapter):Promise.resolve(adapter);},
  ()=>true,{addNotification:()=>messages.push('warning')},()=>({}),s=>s);
 return {view,st,mp,map,lf,layers,overlays,disposed,messages,stored,dark,loads:()=>loads};
}
async function main() {
 let f=fixture();
 await f.view.set('osm',false);
 assert.equal(f.loads(),0,'raster maps must not load the vector engine');
 for(const key of ['ofm-liberty','ofm-positron','ofm-bright','ofm-dark']) {
  await f.view.set(key,true);
  assert.equal(f.st.tiles.kind,'vector');
  assert.equal(f.mp.style.value,key);
  assert.equal(f.stored.get('5gmodem.gps.map'),key);
  assert.equal(f.map.options.crs,f.lf.CRS.EPSG3857);
  assert.equal(f.dark.at(-1),false,'vector styles must not be colour-inverted');
  assert.ok(f.st.tiles.options.attributionControl.customAttribution.includes('OpenStreetMap'));
 }
 const vector=f.st.tiles;
 await f.view.set('yandex',false);
 assert.equal(f.st.tiles.kind,'raster');
 assert.ok(f.disposed.includes(vector),'switching must release the WebGL layer');
 assert.equal(f.map.options.crs,f.lf.CRS.EPSG3395);
 await f.view.set('ofm-dark',false);
 assert.equal(f.map.options.crs,f.lf.CRS.EPSG3857);
 await f.view.set('osm',false);
 assert.equal(f.map.options.minZoom,0);
 assert.equal(f.map.options.maxBounds,null);
 assert.ok(f.overlays.every(x=>f.layers.has(x)),'GPS overlays survive every switch');
 assert.deepEqual(f.map.center,{lat:0,lng:0});

 const pending=deferred(); f=fixture(()=>pending.promise);
 await f.view.set('osm',false); const original=f.st.tiles;
 const obsolete=f.view.set('ofm-liberty',true);
 assert.equal(f.st.tiles,original,'keep current map during loading');
 await f.view.set('yandex',true);
 pending.resolve({maplibreGL:()=>{throw Error('obsolete selection applied');}});
 await obsolete;
 assert.equal(f.view.key(),'yandex'); assert.equal(f.messages.length,0);

 f=fixture(()=>Promise.reject(Error('WebGL or network unavailable')));
 await f.view.set('ofm-liberty',true);
 assert.equal(f.view.key(),'osm'); assert.equal(f.st.tiles.kind,'raster');
 assert.equal(f.messages.length,1); assert.ok(f.overlays.every(x=>f.layers.has(x)));

 let removedPartial=false;
 f=fixture(()=>Promise.resolve({maplibreGL:()=>({
  _container:{remove(){removedPartial=true;}},getMaplibreMap(){return null;},
  onRemove(){throw Error('missing GL map');},
  addTo(){f.layers.add(this);throw Error('WebGL constructor failed');}
 })}));
 await f.view.set('ofm-liberty',false);
 assert.equal(f.view.key(),'osm'); assert.equal(f.layers.size,4);
 assert.ok(removedPartial,'failed WebGL initialization must not leak its container');

 const afterLeave=deferred(); f=fixture(()=>afterLeave.promise);
 const late=f.view.set('ofm-liberty',false); f.st.map=null;
 afterLeave.resolve({maplibreGL:()=>{throw Error('map created after leaving');}}); await late;
 assert.equal(f.messages.length,0);

 const loaderSource=source.slice(source.indexOf('var MAPLIBRE_ASSETS ='),source.indexOf('function num(v, digits)'));
 let requests=[],css=[],fail=true;
 const luci={name:'luci'},win={L:luci,setTimeout,clearTimeout,fetch:async(url,options)=>{
  requests.push({url,options}); assert.match(options.integrity,/^sha384-/);
  assert.equal(options.credentials,'omit');
  if(url.includes('/dist/maplibre-gl.js')) {
   if(fail)throw Error('temporary download failure');
   return {ok:true,text:async()=> 'module.exports={Map:function(){}};'};
  }
  return {ok:true,text:async()=> 'exports.maplibreGL=function(){return require("leaflet");};'};
 }};
 const doc={head:{appendChild:el=>{css.push(el);queueMicrotask(()=>el.onload());}}};
 const load=new Function('window','document','E','AbortController',loaderSource+'return loadMapLibre;')
  (win,doc,(_tag,attrs)=>({...attrs,remove(){}}),AbortController);
 const leaflet={name:'leaflet'};
 await assert.rejects(load(leaflet)); fail=false;
 const [a,b]=await Promise.all([load(leaflet),load(leaflet)]);
 assert.equal(a,b); assert.equal(a.maplibreGL(),leaflet);
 assert.equal(requests.length,4,'one failed load and one shared retry');
 assert.equal(css.length,1,'reuse loaded stylesheet');
 assert.match(css[0].integrity,/^sha384-/); assert.equal(css[0].crossorigin,'anonymous');
 assert.equal(win.L,luci,'never overwrite the LuCI global');
 console.log('PASS: optional GPS basemaps, races, fallback, overlays and isolated loader');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
