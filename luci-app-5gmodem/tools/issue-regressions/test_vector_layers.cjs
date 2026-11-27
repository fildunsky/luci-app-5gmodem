const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../htdocs/luci-static/resources/view/modem5g/vectorlayers.js'),'utf8');
const storage=new Map();
function fixture(layers,loaded=true){
 const controls=[];
 function E(tag,attrs={},children=[]){if(Array.isArray(children))assert.ok(children.every(x=>!Array.isArray(x)),'LuCI children must be flat');const e={tag,...attrs,children,style:{}};if(tag==='input')controls.push(e);return e;}
 const widget=new Function('baseclass','window','E','_',source)({extend:x=>x},{localStorage:{getItem:k=>storage.get(k)??null,setItem:(k,v)=>storage.set(k,v)}},E,x=>x).build();
 const listeners=new Map(),paint=[],layout=[];
 const gl={layers:structuredClone(layers),on:(event,fn)=>listeners.set(event,fn),off:(event,fn)=>{if(listeners.get(event)===fn)listeners.delete(event);},isStyleLoaded:()=>loaded,getStyle(){return {layers:this.layers};},addLayer(l,before){const i=this.layers.findIndex(x=>x.id===before);this.layers.splice(i<0?this.layers.length:i,0,l);},setLayoutProperty(id,k,v){assert.ok(this.layers.some(l=>l.id===id));layout.push([id,k,v]);},setPaintProperty:(id,k,v)=>paint.push([id,k,v])};
 const toggle=(i,on)=>{controls[i].checked=on;controls[i].change();};
 const visible=id=>layout.findLast(x=>x[0]===id)?.[2];
 return {widget,gl,controls,listeners,toggle,visible,paint};
}
const base=[
 {id:'water',type:'fill','source-layer':'water'},
 {id:'build',type:'fill',source:'tiles','source-layer':'building',paint:{'fill-color':'#ddd'}},
 {id:'extruded',type:'fill-extrusion',source:'tiles','source-layer':'building',paint:{'fill-extrusion-height':['get','render_height'],'fill-extrusion-base':['get','render_min_height']}},
 {id:'road',type:'line','source-layer':'transportation'},
 {id:'arrow',type:'symbol','source-layer':'transportation',layout:{'icon-image':'arrow'}},
 {id:'street',type:'symbol','source-layer':'transportation_name',layout:{'text-field':['get','name']}},
 {id:'city',type:'symbol','source-layer':'place',layout:{'text-field':['get','name']}},
 {id:'poi',type:'symbol','source-layer':'poi',layout:{'text-field':['get','name']}},
 {id:'hidden',type:'symbol','source-layer':'place',layout:{visibility:'none','text-field':['get','name']}}
];
let f=fixture(base,false);f.widget.select(true);f.widget.attach(f.gl);
assert.ok(f.controls.every(x=>x.disabled),'disabled while style loads');
f.listeners.get('style.load')();
assert.ok(f.controls.every(x=>!x.disabled));
assert.equal(f.visible('water'),undefined,'unrelated layers untouched');
assert.equal(f.visible('hidden'),'none','preserve style-hidden layers');
assert.equal(f.paint.findLast(x=>x[1]==='fill-extrusion-height')[2],0,'flat by default');
f.toggle(0,false);assert.equal(f.visible('build'),'none');assert.equal(f.visible('extruded'),'none');
f.toggle(0,true);f.toggle(4,true);assert.deepEqual(f.paint.findLast(x=>x[1]==='fill-extrusion-height')[2],['get','render_height']);
f.toggle(1,false);assert.equal(f.visible('street'),'none');assert.equal(f.visible('city'),'none');assert.equal(f.visible('arrow'),'visible');assert.equal(f.visible('poi'),'visible','POI independent of map labels');
f.toggle(1,true);f.toggle(3,false);assert.equal(f.visible('street'),'none');assert.equal(f.visible('road'),'none');assert.equal(f.visible('arrow'),'none');assert.equal(f.visible('city'),'visible');
f.toggle(2,false);assert.equal(f.visible('poi'),'none');
f.widget.select(false);assert.equal(f.widget.node.style.display,'none');assert.equal(f.listeners.size,0,'old map listeners detached on style switch');
const oldPaint=f.paint.length;f.toggle(0,false);assert.equal(f.paint.length,oldPaint,'detached maps must not be updated');
f=fixture(base.filter(l=>!['extruded','poi'].includes(l.id)));f.widget.select(true);f.widget.attach(f.gl);
assert.equal(f.controls[2].disabled,true,'styles without POI do not offer ineffective controls');
assert.equal(f.controls[3].checked,false,'preferences persist across styles');
const added=f.gl.layers.find(l=>l.id==='5gmodem-buildings-3d');assert.equal(added.source,'tiles');assert.ok(JSON.stringify(added.filter).includes('render_height'));assert.equal(f.gl.layers.filter(l=>l.id===added.id).length,1);
f.toggle(0,true);f.toggle(4,true);assert.equal(f.visible(added.id),'visible');
f.widget.destroy();assert.equal(f.listeners.size,0);
console.log('PASS: vector visibility groups, 3D heights, preferences, style readiness and cleanup');
