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
  function load(z,x,y,serial,consumer){
   var n=Math.pow(2,z-1);x=((x%n)+n)%n;
   if(y<0||y>=n){return Promise.resolve(null);}
   var key=config.operator+'/'+config.technology+'/'+z+'/'+x+'/'+y,previous=cache.get(key);
   if(previous && Date.now()-previous.at<300000 && (previous.loaded || previous.active())){previous.users.add(consumer);cache.delete(key);cache.set(key,previous);return previous.request;}
   var entry={at:Date.now(),users:new Set([consumer]),loaded:false};
   var active=function(){return !!map && !stopped && config.enabled && serial===generation && Array.from(entry.users).some(function(user){return user();});};
   entry.active=active;
   // Leaflet first asks for central tiles during zoom animation, then the edges.
   // Wait for the final grid so both groups can reuse one HTTPS connection.
   var request=options.fetch(x,y,z,config.operator,config.technology,active,function(){return !zooming;}).then(function(j){
    if(!active()){throw new Error('cancelled');}
    if(!j.ok){var e=new Error(j.error||'network');e.code=j.error;throw e;}
    if(typeof j.image!=='string' || !j.image.startsWith('data:image/png;base64,') || j.image.length>750000){throw new Error('unexpected_response');}
    return new Promise(function(resolve,reject){
     var img=new Image();img.onload=function(){entry.loaded=true;resolve(img);};img.onerror=function(){reject(new Error('unexpected_response'));};img.src=j.image;
    });
   });
   entry.request=request;cache.set(key,entry);
   while(cache.size>32){cache.delete(cache.keys().next().value);}
   request.catch(function(){if(cache.get(key)?.request===request){cache.delete(key);}});
   return request;
  }
  function remove(){generation++;if(layer&&map){map.removeLayer(layer);}layer=null;}
  function update(){
   if(!map||!lf){return;}
   remove();stopped=false;
   if(!config.enabled || !config.operator){return;}
   if(options.report){options.report('loading');}
   var serial=generation;
   var Grid=lf.GridLayer.extend({createTile:function(coords,done){
    var canvas=document.createElement('canvas');canvas.width=canvas.height=512;canvas.measurementActive=true;
    var consumer=function(){return canvas.measurementActive && !!map && (zooming || Math.max(6,Math.min(17,Math.round(map.getZoom())))===coords.z);};
    var ctx=canvas.getContext('2d'),elliptical=map.options.crs===lf.CRS.EPSG3395;
    var rows=[],needed=new Set();
    for(var r=0;r<512;r++){var sy=sourceRow(coords.y*512+r+.5,coords.z,elliptical);rows.push(sy);needed.add(Math.floor(sy/512));}
    var indices=Array.from(needed),images={};
    Promise.all(indices.map(function(y){return load(coords.z,coords.x,y,serial,consumer).then(function(img){images[y]=img;});})).then(function(){
     if(serial!==generation || !map || stopped || !consumer()){done(null,canvas);return;}
     if(!elliptical){var img=images[coords.y];if(img){ctx.drawImage(img,0,0,512,512);}}
     else {rows.forEach(function(sy,dy){var ty=Math.floor(sy/512),img=images[ty];if(img){var scale=img.naturalHeight/512;ctx.drawImage(img,0,(sy-ty*512)*scale,img.naturalWidth,Math.max(scale,.01),0,dy,512,1);}});}
     if(options.report){options.report(null);}done(null,canvas);
    }).catch(function(e){if(serial===generation && map && consumer() && e.message!=='cancelled'){if(options.report){options.report(e.code||e.message);}}done(null,canvas);});
    return canvas;
   }});
   // Retain previously loaded neighbours; keepBuffer does not prefetch tiles.
   layer=new Grid({tileSize:512,minZoom:4,maxZoom:22,minNativeZoom:6,maxNativeZoom:17,keepBuffer:2,updateWhenIdle:false,updateInterval:200,updateWhenZooming:false,pane:'5gm-measurements',opacity:1}).addTo(map);
   layer.on('tileunload',function(event){event.tile.measurementActive=false;});
  }
  return {
   configure:function(next){var key=JSON.stringify(next);if(key===JSON.stringify(config)){return;}config=next;update();},
   attach:function(m,leaflet){map=m;lf=leaflet;map.on('zoomstart',zoomStart);map.on('zoomend',zoomEnd);map.createPane('5gm-measurements').style.zIndex='390';update();},
   styleChanged:update,
   pause:function(){stopped=true;generation++;},
   destroy:function(){remove();if(map){map.off('zoomstart',zoomStart);map.off('zoomend',zoomEnd);}map=null;cache.clear();}
  };
 }
});
