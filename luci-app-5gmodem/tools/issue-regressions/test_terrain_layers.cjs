const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../htdocs/luci-static/resources/view/modem5g/terrainlayers.js'),'utf8');
const helpers=new Function(source.slice(source.indexOf('function elevation'),source.indexOf('return baseclass.extend'))+'return {elevation,demRow,contourSegments,contourInterval};')();
assert.equal(helpers.elevation(128,0,0,255),0);
assert.equal(helpers.elevation(129,0,128,255),256.5);
assert.ok(Number.isNaN(helpers.elevation(0,0,0,255)));
assert.ok(Number.isNaN(helpers.elevation(128,0,0,0)));
const phi=Math.PI/4,f=1/298.257223563,e=Math.sqrt(f*(2-f)),world=256*2**14;
const web=Math.log(Math.tan(Math.PI/4+phi/2)),elliptic=web-e/2*Math.log((1+e*Math.sin(phi))/(1-e*Math.sin(phi)));
assert.ok(Math.abs(helpers.demRow(world*(.5-elliptic/(2*Math.PI)),14,true)-world*(.5-web/(2*Math.PI)))<1e-6,'reproject Yandex rows into DEM coordinates');
assert.equal(helpers.demRow(123,14,false),123);
assert.deepEqual(helpers.contourSegments([0,10,10,0],5),[[[.5,0],[.5,1]]]);
assert.deepEqual(helpers.contourSegments([5,5,5,5],5),[],'flat ground has no fictitious contours');
assert.deepEqual(helpers.contourSegments([NaN,10,10,0],5),[]);
assert.equal(helpers.contourSegments([0,10,0,10],5).length,2,'saddles yield two segments');
assert.deepEqual([8,10,12,14,16].map(helpers.contourInterval),[200,100,50,20,10]);

const requests=[],canvases=[],controls=[];
function E(tag,attrs={},children=[]){const el={tag,...attrs,children:Array.isArray(children)?children:[children],style:{}};if(tag==='input')controls.push(el);return el;}
function canvas(){
 const ctx={strokes:0,drawImage(image){this.image=image;},getImageData(){
  const rgba=new Uint8ClampedArray(256*256*4),m=this.image.url.match(/\/(\d+)\/(\d+)\/(\d+)\.png$/),tx=+m[2],ty=+m[3];
  for(let y=0;y<256;y++)for(let x=0;x<256;x++){
   const h=32768+5+(tx*256+x)*2+(ty*256+y)*.5,i=4*(y*256+x);
   rgba[i]=Math.floor(h/256);rgba[i+1]=Math.floor(h%256);rgba[i+2]=Math.round((h%1)*256);rgba[i+3]=255;
  }
  return {data:rgba};
 },createImageData(){return {data:new Uint8ClampedArray(256*256*4)};},putImageData(image){this.painted=image;},beginPath(){},moveTo(){},lineTo(){},stroke(){this.strokes++;},strokeText(){},fillText(){}};
 const c={getContext:()=>ctx,ctx};canvases.push(c);return c;
}
class ImageMock{
 set src(url){this.url=url;if(url){requests.push({url,crossOrigin:this.crossOrigin});queueMicrotask(()=>this.onload());}}
}
let currentLayer;
const lf={CRS:{EPSG3395:{},EPSG3857:{}},GridLayer:{extend(def){return class{
 constructor(opts){this.options=opts;this.createTile=def.createTile;}
 addTo(){currentLayer=this;return this;}redraw(){this.redraws=(this.redraws||0)+1;}
 };}}};
const map={options:{crs:lf.CRS.EPSG3857},removed:[],createPane:()=>({style:{}}),removeLayer(l){this.removed.push(l);}};
const widget=new Function('baseclass','window','document','Image','E','_',source)(
 {extend:v=>v},{setTimeout,clearTimeout},{createElement:canvas},ImageMock,E,x=>x).build();
async function tile(){return new Promise((resolve,reject)=>currentLayer.createTile({z:14,x:1,y:1},(err,c)=>err?reject(err):resolve(c)));}
async function main(){
 widget.attach(map,lf);assert.equal(requests.length,0,'off by default requests no DEM');
 controls[0].checked=true;controls[0].change();
 let c=await tile();assert.ok(c.ctx.painted.data.some((v,i)=>i%4===3&&v>0),'a sloped surface produces relief');
 assert.ok(requests.every(r=>r.crossOrigin==='anonymous'&&r.url.startsWith('https://elevation-tiles-prod.s3.amazonaws.com/terrarium/')));
 const n=requests.length;
 controls[1].checked=true;controls[1].change();c=await tile();assert.ok(c.ctx.strokes>0,'contours are drawn');
 assert.equal(requests.length,n,'switching layers reuses decoded DEM tiles');
 map.options.crs=lf.CRS.EPSG3395;widget.styleChanged();assert.ok(currentLayer.redraws>=2);
 controls[0].checked=false;controls[0].change();controls[1].checked=false;controls[1].change();assert.ok(map.removed.length);
 widget.destroy();
 const stored=new Map(), prefInputs=[];
 const prefE=(tag,attrs={},children=[])=>{const e={...attrs,style:{}};if(tag==='input')prefInputs.push(e);return e;};
 const preferenceModule=new Function('baseclass','window','document','Image','E','_',source)(
  {extend:v=>v},{setTimeout,clearTimeout,localStorage:{getItem:k=>stored.get(k)??null,setItem:(k,v)=>stored.set(k,v)}},{},ImageMock,prefE,x=>x);
 preferenceModule.build();prefInputs[0].checked=true;prefInputs[0].change();
 assert.equal(stored.get('5gmodem.gps.terrain.shade'),'1');
 preferenceModule.build();assert.equal(prefInputs[2].checked,true,'terrain choice survives rebuilding the page');
 assert.equal(prefInputs[3].checked,false,'unselected contours stay off');
 console.log('PASS: elevation decoding, contour geometry, Yandex reprojection, relief, cache and layer lifecycle');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
