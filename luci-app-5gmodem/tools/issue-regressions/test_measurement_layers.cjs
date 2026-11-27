const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../htdocs/luci-static/resources/view/modem5g/measurementlayers.js'),'utf8');
const row=new Function(source.slice(source.indexOf('function sourceRow'),source.indexOf('return baseclass.extend'))+'return sourceRow;')();
assert.equal(row(123,15,false),123);
const phi=Math.PI/4,f=1/298.257223563,e=Math.sqrt(f*(2-f)),world=256*2**15;
const wm=Math.log(Math.tan(Math.PI/4+phi/2)),ym=wm-e/2*Math.log((1+e*Math.sin(phi))/(1-e*Math.sin(phi)));
assert.ok(Math.abs(row(world*(.5-ym/(2*Math.PI)),15,true)-world*(.5-wm/(2*Math.PI)))<1e-6);
function fixture(fetcher){
 const calls=[],reports=[],canvases=[],removed=[];let current;
 const lf={CRS:{EPSG3857:{},EPSG3395:{}},GridLayer:{extend(def){return class{
  constructor(opts){this.options=opts;this.createTile=def.createTile;this.events={};}addTo(){current=this;return this;}on(name,fn){this.events[name]=fn;return this;}
 };}}};
 const events={};const map={events,zoom:15,getZoom(){return this.zoom;},options:{crs:lf.CRS.EPSG3857},on:(e,f)=>events[e]=f,off:e=>delete events[e],createPane:()=>({style:{}}),removeLayer:l=>removed.push(l)};
 const document={createElement(){const draw=[],ctx={drawImage:(...args)=>draw.push(args)};const c={getContext:()=>ctx,draw};canvases.push(c);return c;}};
 class MockImage{constructor(){this.naturalWidth=this.naturalHeight=256;}set src(value){queueMicrotask(()=>this.onload());}}
 const mod=new Function('baseclass','document','Image',source)({extend:x=>x},document,MockImage);
 const widget=mod.build({fetch:(...args)=>{calls.push(args);return fetcher?fetcher(...args):Promise.resolve({ok:true,image:'data:image/png;base64,AA=='});},report:code=>reports.push(code)});
 const tile=(coords={z:15,x:100,y:6000})=>new Promise(resolve=>current.createTile(coords,(_err,c)=>resolve(c)));
 return {widget,lf,map,calls,reports,removed,tile,options:()=>current.options,unload:c=>current.events.tileunload({tile:c}),canvases};
}
async function main(){
 const config={enabled:true,operator:'001001',technology:'lte'};
 let f=fixture();f.widget.attach(f.map,f.lf);assert.equal(f.calls.length,0,'off by default');
 f.widget.configure(config);let c=await f.tile();assert.equal(f.calls.length,1);assert.equal(c.draw.length,1);assert.equal(c.draw[0].at(-1),512,'256px PNG scales to native 512px tile');
 assert.equal(f.options().minZoom,4);assert.equal(f.options().minNativeZoom,6,'overview uses the same tile scales as the website');
 assert.equal(f.options().keepBuffer,2,'keep recently displayed neighbours without prefetch');
 assert.equal(f.options().updateWhenIdle,false,'panning starts loading without waiting for drag end');
 assert.equal(f.options().updateInterval,200,'live pan updates remain throttled');
 f.map.events.zoomstart();assert.equal(f.calls[0][6](),false,'central zoom tiles wait for the full final grid');f.map.events.zoomend();assert.equal(f.calls[0][6](),true);
 await f.tile();assert.equal(f.calls.length,1,'decoded tiles are reused');
 f.map.options.crs=f.lf.CRS.EPSG3395;f.widget.styleChanged();c=await f.tile();assert.equal(c.draw.length,512,'Yandex tiles reproject source rows');assert.ok(f.calls.length<=3,'adjacent rows reuse source tiles');
 f.widget.configure({...config,enabled:false});assert.ok(f.removed.length);f.widget.destroy();
 let release;f=fixture(()=>new Promise(resolve=>release=resolve));f.widget.attach(f.map,f.lf);f.widget.configure(config);const pending=f.tile();
 f.widget.configure({...config,enabled:false});release({ok:true,image:'data:image/png;base64,AA=='});await pending;
 assert.deepEqual(f.reports,['loading'],'disabled layer ignores late replies');
 f.widget.configure(config);const second=f.tile();release({ok:true,image:'data:image/png;base64,AA=='});await second;
 assert.equal(f.calls.length,2,'cancelled image must not poison the cache');
 f=fixture(()=>Promise.resolve({ok:false,error:'rate_limited'}));f.widget.attach(f.map,f.lf);f.widget.configure(config);await f.tile();assert.deepEqual(f.reports,['loading','rate_limited']);
 f=fixture(()=>new Promise(resolve=>release=resolve));f.widget.attach(f.map,f.lf);f.widget.configure(config);
 const oldTile=f.tile();f.unload(f.canvases[0]);assert.equal(f.calls[0][5](),false,'queued image becomes inactive when Leaflet unloads its tile');
 release({ok:true,image:'data:image/png;base64,AA=='});await oldTile;assert.deepEqual(f.reports,['loading']);
 const newTile=f.tile();assert.equal(f.calls.length,2,'a cancelled tile can be fetched again on return');
 release({ok:true,image:'data:image/png;base64,AA=='});await newTile;
 f=fixture(()=>new Promise(resolve=>release=resolve));f.widget.attach(f.map,f.lf);f.widget.configure(config);
 const a=f.tile(),b=f.tile();f.unload(f.canvases[0]);assert.equal(f.calls.length,1);
 assert.equal(f.calls[0][5](),true,'another visible tile keeps its shared source request alive');
 release({ok:true,image:'data:image/png;base64,AA=='});await Promise.all([a,b]);assert.equal(f.canvases[1].draw.length,1);
 f=fixture(()=>new Promise(resolve=>release=resolve));f.widget.attach(f.map,f.lf);f.widget.configure(config);
 const staleZoom=f.tile();f.map.events.zoomstart();f.map.zoom=14;f.map.events.zoomend();
 assert.equal(f.calls[0][5](),false,'retained old zoom levels cannot keep queued HTTP jobs alive');
 release({ok:true,image:'data:image/png;base64,AA=='});await staleZoom;
 console.log('PASS: measurement PNG tiles, projection, lazy loading, cache and cancellation');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
