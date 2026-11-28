'use strict';
'require baseclass';

// Leaflet tiles are 512 world pixels; the service may return a 256px PNG.
function sourceRow(y,z,elliptical){
 if(!elliptical){return y;}
 var world=256*Math.pow(2,z),merc=Math.PI*(1-2*y/world),f=1/298.257223563,ecc=Math.sqrt(f*(2-f));
 var phi=2*Math.atan(Math.exp(merc))-Math.PI/2;
 for(var i=0;i<8;i++){var s=ecc*Math.sin(phi);phi=2*Math.atan(Math.exp(merc)*Math.pow((1+s)/(1-s),ecc/2))-Math.PI/2;}
 return world*(.5-Math.log(Math.tan(Math.PI/4+phi/2))/(2*Math.PI));
}

return baseclass.extend({
 build:function(options){
  var map,lf,layer,config={enabled:false,operator:'',technology:'lte'},generation=0,stopped=false,zooming=false,cache=new Map();
  function zoomStart(){zooming=true;}
  function zoomEnd(){zooming=false;}
  function load(z,x,y,serial,consumer,subscriptions){
   var n=Math.pow(2,z-1);x=((x%n)+n)%n;
   if(y<0||y>=n){return Promise.resolve(null);}
   var key=config.operator+'/'+config.technology+'/'+z+'/'+x+'/'+y,previous=cache.get(key);
   if(previous && Date.now()-previous.at<300000 && (previous.loaded || previous.active())){
    if(!previous.loaded){subscribe(previous,consumer,subscriptions);}
    cache.delete(key);cache.set(key,previous);return previous.request;
   }
   var entry={at:Date.now(),users:new Set(),loaded:false};
   subscribe(entry,consumer,subscriptions);
   var active=function(){return !!map && !stopped && config.enabled && serial===generation && Array.from(entry.users).some(function(user){return user();});};
   entry.active=active;
   // Wait for the final grid so central and edge tiles can share one HTTPS connection.
   function fetchImage(){
    return options.fetch(x,y,z,config.operator,config.technology,active,function(){return !zooming;})
     .catch(function(){return {ok:false,error:'network'};});
   }
   var request=fetchImage().then(function(j){
    if(active() && !j.ok && (j.error==='network' || j.error==='busy')){return fetchImage();}
    return j;
   }).then(function(j){
    if(!active()){throw new Error('cancelled');}
    if(!j.ok){var e=new Error(j.error||'network');e.retryAfter=j.retry_after;throw e;}
    if(typeof j.image!=='string' || !j.image.startsWith('data:image/png;base64,') || j.image.length>750000){throw new Error('unexpected_response');}
    return new Promise(function(resolve,reject){
     var img=new Image();img.onload=function(){entry.loaded=true;resolve(img);};img.onerror=function(){reject(new Error('unexpected_response'));};img.src=j.image;
    });
   }).finally(function(){entry.users.clear();});
   entry.request=request;cache.set(key,entry);
   while(cache.size>32){cache.delete(cache.keys().next().value);}
   request.catch(function(){if(cache.get(key)?.request===request){cache.delete(key);}});
   return request;
  }
  function subscribe(entry,consumer,subscriptions){
   entry.users.add(consumer);
   subscriptions.push(function(){entry.users.delete(consumer);});
  }
  function remove(){generation++;if(layer&&map){map.removeLayer(layer);}layer=null;}
  function update(){
   if(!map||!lf){return;}
   remove();
   if(stopped || !config.enabled || !config.operator){return;}
   if(options.report){options.report('loading');}
   var serial=generation;
   var Grid=lf.GridLayer.extend({createTile:function(coords,done){
    var canvas=document.createElement('canvas');canvas.width=canvas.height=512;canvas.measurementActive=true;canvas.measurementSubscriptions=[];
    var consumer=function(){return canvas.measurementActive && !!map && (zooming || Math.max(6,Math.min(17,Math.round(map.getZoom())))===coords.z);};
    var ctx=canvas.getContext('2d'),elliptical=map.options.crs===lf.CRS.EPSG3395;
    var rows=[],needed=new Set();
    for(var r=0;r<512;r++){var sy=sourceRow(coords.y*512+r+.5,coords.z,elliptical);rows.push(sy);needed.add(Math.floor(sy/512));}
    var indices=Array.from(needed),images={};
    Promise.allSettled(indices.map(function(y){
     return load(coords.z,coords.x,y,serial,consumer,canvas.measurementSubscriptions).then(function(img){images[y]=img;});
    })).then(function(results){
     canvas.measurementSubscriptions.length=0;
     if(serial!==generation || !map || stopped || !consumer()){done(null,canvas);return;}
     if(!elliptical){var img=images[coords.y];if(img){ctx.drawImage(img,0,0,512,512);}}
     else {rows.forEach(function(sy,dy){var ty=Math.floor(sy/512),img=images[ty];if(img){var scale=img.naturalHeight/512;ctx.drawImage(img,0,(sy-ty*512)*scale,img.naturalWidth,Math.max(scale,.01),0,dy,512,1);}});}
     var errors=results.filter(function(result){return result.status==='rejected' && result.reason.message!=='cancelled';});
     var failure=errors.find(function(result){return ['rate_limited','access_denied','provider_paused'].indexOf(result.reason.message)!==-1;}) || errors[0];
     if(options.report){options.report(failure ? failure.reason.message : null, failure && failure.reason.retryAfter);}
     done(failure ? failure.reason : null,canvas);
    });
    return canvas;
   }});
   // Retain previously loaded neighbours; keepBuffer does not prefetch tiles.
   layer=new Grid({tileSize:512,minZoom:4,maxZoom:22,minNativeZoom:6,maxNativeZoom:17,keepBuffer:2,updateWhenIdle:false,updateInterval:200,updateWhenZooming:false,pane:'5gm-measurements',opacity:1}).addTo(map);
   layer.on('tileunload',function(event){event.tile.measurementActive=false;event.tile.measurementSubscriptions.splice(0).forEach(function(unsubscribe){unsubscribe();});});
  }
  return {
   configure:function(next){var key=JSON.stringify(next);if(key===JSON.stringify(config)){return;}config=next;update();},
   attach:function(m,leaflet){map=m;lf=leaflet;map.on('zoomstart',zoomStart);map.on('zoomend',zoomEnd);map.createPane('5gm-measurements').style.zIndex='390';update();},
   styleChanged:update,
   pause:function(){if(!stopped){stopped=true;generation++;}},
   resume:function(){if(stopped){stopped=false;update();}},
   destroy:function(){remove();if(map){map.off('zoomstart',zoomStart);map.off('zoomend',zoomEnd);}map=null;cache.clear();}
  };
 }
});
