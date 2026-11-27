const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../htdocs/luci-static/resources/view/modem5g/maplayers.js'),'utf8');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const batchTick=()=>new Promise(resolve=>setTimeout(resolve,25));
function fixture(){
 const calls=[];let active=0,maximum=0;
 const rpc={declare:({method,nobatch})=>{
  assert.equal(nobatch,true,'slow map requests must not share a LuCI transport batch');
  return (...args)=>new Promise((resolve,reject)=>{
   const cost=method==='tiles'?3:1;active+=cost;maximum=Math.max(maximum,active);
   calls.push({method,args,finish:(result)=>{active-=cost;resolve(result||{ok:true,tiles:Object.fromEntries(args[0].split(',').map(pair=>[pair,{ok:true,image:'image-'+pair}]))});},fail:()=>{active-=cost;reject(new Error('network'));}});
  });
 }};
 const api=new Function('rpc',source.slice(0,source.indexOf('var CREDIT'))+'return {fetchTile,fetchLayers};')(rpc);
 return {api,calls,maximum:()=>maximum};
}
async function main(){
 let f=fixture(),visible=true;
 const images=Array.from({length:14},(_,x)=>f.api.fetchTile(x,1,15,'001001','lte',x===3?()=>visible:undefined));
 const point=f.api.fetchLayers('operators','','','','',0,'','');
 visible=false;await batchTick();assert.equal(f.calls.length,1);assert.equal(f.calls[0].method,'layers','handbook has priority');
 f.calls[0].finish({ok:true,data:[]});await tick();
 assert.equal(f.calls[1].method,'tiles');assert.equal(f.calls[1].args[0].split(',').length,12,'viewport requests have a bounded batch size');
 assert.ok(!f.calls[1].args[0].split(',').includes('3:1'),'invisible tile never reaches backend');
 const point2=f.api.fetchLayers('fourcells','1','2','1.1','2.1',15,'001001','lte');await tick();
 assert.equal(f.calls.length,2,'batch reserves the three upstream transfer slots');
 f.calls[1].finish();await tick();assert.equal(f.calls[2].method,'layers','tower request outranks remaining images');
 f.calls[2].finish({ok:true,data:{}});await batchTick();assert.equal(f.calls[3].args[0],'13:1','remaining viewport tiles use the next shared client');
 f.calls[3].finish();const results=await Promise.all(images);await Promise.all([point,point2]);
 assert.equal(results[3].error,'cancelled');assert.equal(results[4].image,'image-4:1','response mapping is by coordinate, not completion order');assert.equal(f.maximum(),3);
 f=fixture();visible=true;const hold=f.api.fetchLayers('operators','','','','',0,'','');
 const abandoned=f.api.fetchTile(1,2,15,'001001','lte',()=>visible);await batchTick();visible=false;
 f.calls[0].finish({ok:true,data:[]});await hold;assert.equal((await abandoned).error,'cancelled');assert.equal(f.calls.length,1,'batch cancelled while waiting sends no RPC');
 f=fixture();const lte=f.api.fetchTile(1,2,15,'001001','lte'),nr=f.api.fetchTile(1,2,15,'001001','nr');
 await batchTick();assert.equal(f.calls[0].args[3],'lte');f.calls[0].finish();await lte;await batchTick();assert.equal(f.calls[1].args[3],'nr','different technologies cannot mix');f.calls[1].finish();await nr;
 f=fixture();const failed=f.api.fetchTile(1,2,15,'001001','lte');await batchTick();f.calls[0].finish({ok:false,error:'rate_limited'});
 assert.equal((await failed).error,'rate_limited');await batchTick();assert.equal(f.calls.length,1,'no automatic quota retries');
 const next=f.api.fetchTile(2,2,15,'001001','lte');await batchTick();f.calls[1].finish();assert.equal((await next).ok,true);
 f=fixture();let settled=false;
 const zoomJobs=[0,1].map(x=>f.api.fetchTile(x,1,15,'001001','lte',()=>true,()=>settled));
 await batchTick();assert.equal(f.calls.length,0,'zoom animation must not start a small central batch');
 for(let x=2;x<9;x++){zoomJobs.push(f.api.fetchTile(x,1,15,'001001','lte',()=>true,()=>settled));}
 settled=true;await batchTick();assert.equal(f.calls.length,1);assert.equal(f.calls[0].args[0].split(',').length,9,'central and outer zoom tiles share one connection');
 f.calls[0].finish();await Promise.all(zoomJobs);
 console.log('PASS: shared HTTPS batches, network budget, point priority, cancellation, grouping and quota errors');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
