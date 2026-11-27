'use strict';
'require baseclass';

var DEM_URL = 'https://elevation-tiles-prod.s3.amazonaws.com/terrarium/';
var CREDIT = '<a href="https://github.com/tilezen/joerd/blob/master/docs/attribution.md" target="_blank" rel="noopener">Terrain Tiles: Mapzen / USGS / NASA</a>';

function elevation(r, g, b, alpha) {
	var h = r * 256 + g + b / 256 - 32768;
	return alpha && h >= -11000 && h <= 9000 ? h : NaN;
}

// Convert a Leaflet world-pixel row into the DEM's spherical Mercator row.
function demRow(y, zoom, elliptical) {
	if (!elliptical) { return y; }
	var world = 256 * Math.pow(2, zoom), merc = Math.PI * (1 - 2*y/world), f = 1 / 298.257223563, e = Math.sqrt(f * (2 - f));
	var phi = 2*Math.atan(Math.exp(merc)) - Math.PI/2;
	for (var i=0; i<8; i++) { var s=e*Math.sin(phi); phi=2*Math.atan(Math.exp(merc)*Math.pow((1+s)/(1-s),e/2))-Math.PI/2; }
	return world*(.5-Math.log(Math.tan(Math.PI/4+phi/2))/(2*Math.PI));
}

function contourSegments(values, level) {
	if (values.some(function(v) { return !Number.isFinite(v); })) { return []; }
	var corners=[[0,0],[1,0],[1,1],[0,1]], hits=[];
	for (var i=0; i<4; i++) {
		var j=(i+1)%4, a=values[i], b=values[j];
		if ((a<level && b>=level) || (b<level && a>=level)) {
			var t=(level-a)/(b-a); hits.push([corners[i][0]+t*(corners[j][0]-corners[i][0]),corners[i][1]+t*(corners[j][1]-corners[i][1])]);
		}
	}
	if (hits.length===2) { return [[hits[0],hits[1]]]; }
	if (hits.length===4) {
		var center=values.reduce(function(a,b) {return a+b;},0)/4;
		return (center>=level)===(values[0]>=level) ? [[hits[0],hits[1]],[hits[2],hits[3]]] : [[hits[0],hits[3]],[hits[1],hits[2]]];
	}
	return [];
}

function contourInterval(z) { return z<10 ? 200 : z<12 ? 100 : z<14 ? 50 : z<16 ? 20 : 10; }

return baseclass.extend({
	build: function() {
		var map, lf, layer, generation=0, enabled={shade:false,contours:false}, cache=new Map();
		Object.keys(enabled).forEach(function(key){try{enabled[key]=window.localStorage.getItem('5gmodem.gps.terrain.'+key)==='1';}catch(e){}});
		var hint=E('small', {'class':'tg-gps-layerstatus','role':'status'});
		var node=E('span', {'class':'tg-gps-layergroup'}, [
			E('b',{},_('Terrain')),
			E('label',{},[checkbox('shade'), ' ', _('Hillshade')]),
			E('label',{},[checkbox('contours'), ' ', _('Contour lines')]), hint
		]);
		function checkbox(key) {
			var input=E('input',{'type':'checkbox','change':function(){enabled[key]=input.checked;try{window.localStorage.setItem('5gmodem.gps.terrain.'+key,input.checked?'1':'0');}catch(e){}update();}});
			input.checked=enabled[key];
			return input;
		}
		function loadDem(z,x,y) {
			var n=Math.pow(2,z); x=((x%n)+n)%n; y=Math.max(0,Math.min(n-1,y));
			var key=z+'/'+x+'/'+y;
			if(cache.has(key)){var existing=cache.get(key);cache.delete(key);cache.set(key,existing);return existing;}
			var request=new Promise(function(resolve,reject){
				var img=new Image(), timeout=window.setTimeout(function(){img.src='';reject(new Error('timeout'));},15000);
				img.crossOrigin='anonymous';
				img.onerror=function(){window.clearTimeout(timeout);reject(new Error('DEM'));};
				img.onload=function(){
					window.clearTimeout(timeout);
					try {
						var canvas=document.createElement('canvas');canvas.width=canvas.height=256;
						var ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(img,0,0,256,256);
						var rgba=ctx.getImageData(0,0,256,256).data, data=new Float32Array(256*256);
						for(var i=0;i<data.length;i++){data[i]=elevation(rgba[4*i],rgba[4*i+1],rgba[4*i+2],rgba[4*i+3]);}
						resolve(data);
					}catch(e){reject(e);}
				};
				img.src=DEM_URL+key+'.png';
			}).catch(function(e){if(cache.get(key)===request){cache.delete(key);}throw e;});
			cache.set(key,request);
			while(cache.size>48){cache.delete(cache.keys().next().value);}
			return request;
		}
		function paint(canvas,coords,done,serial) {
			var z=coords.z, nativeZ=Math.min(z,14), scale=Math.pow(2,z-nativeZ), world=256*Math.pow(2,nativeZ);
			var elliptical=map.options.crs===lf.CRS.EPSG3395, rows=[];
			for(var y=-1;y<=257;y++){rows.push(demRow(coords.y*256+y,z,elliptical)/scale);}
			var left=(coords.x*256-1)/scale-1, right=(coords.x*256+257)/scale+1;
			var top=Math.max(0,rows[0]-1), bottom=Math.min(world-1,rows[rows.length-1]+1);
			var tiles={}, requests=[];
			for(var tx=Math.floor(left/256);tx<=Math.floor((right+1)/256);tx++){
				for(var ty=Math.floor(top/256);ty<=Math.floor((bottom+1)/256);ty++){
					(function(x,y){requests.push(loadDem(nativeZ,x,y).then(function(data){tiles[x+':'+y]=data;}));})(tx,ty);
				}
			}
			Promise.all(requests).then(function(){
				if(serial!==generation || !map){done(null,canvas);return;}
				function pixel(x,y){
					y=Math.max(0,Math.min(world-1,y));var tile=tiles[Math.floor(x/256)+':'+Math.floor(y/256)];
					return tile ? tile[(y%256)*256+((x%256)+256)%256] : NaN;
				}
				function interpolate(sx,sy){
					var ix=Math.floor(sx), iy=Math.floor(sy), fx=sx-ix, fy=sy-iy;
					var a=pixel(ix,iy),b=pixel(ix+1,iy),c=pixel(ix,iy+1),d=pixel(ix+1,iy+1);
					return (a*(1-fx)+b*fx)*(1-fy)+(c*(1-fx)+d*fx)*fy;
				}
				function sample(x,y){return interpolate((coords.x*256+x)/scale,rows[y+1]);}
				var heights=new Float32Array(259*259);
				for(var y=-1;y<=257;y++){for(var x=-1;x<=257;x++){heights[(y+1)*259+x+1]=sample(x,y);}}
				function h(x,y){return heights[(y+1)*259+x+1];}
				var ctx=canvas.getContext('2d'), image=ctx.createImageData(256,256);
				if(enabled.shade){
					var centerY=demRow(coords.y*256+128,z,elliptical)/(256*Math.pow(2,z));
					var lat=2*Math.atan(Math.exp(Math.PI*(1-2*centerY)))-Math.PI/2;
					var metres=40075016.686*Math.cos(lat)/(256*Math.pow(2,nativeZ));
					for(var y=0;y<256;y++){for(var x=0;x<256;x++){
						var sx=(coords.x*256+x)/scale,sy=rows[y+1];
						var dx=(interpolate(sx+1,sy)-interpolate(sx-1,sy))/(2*metres), dy=(interpolate(sx,sy-1)-interpolate(sx,sy+1))/(2*metres);
						if(!Number.isFinite(dx)||!Number.isFinite(dy)){continue;}
						var light=(dx*.5-dy*.5+Math.SQRT1_2)/Math.sqrt(dx*dx+dy*dy+1), delta=light-Math.SQRT1_2, i=4*(y*256+x);
						image.data[i]=image.data[i+1]=image.data[i+2]=delta>0?255:0;
						image.data[i+3]=Math.min(120,Math.abs(delta)*170);
					}}
					ctx.putImageData(image,0,0);
				}
				if(enabled.contours){
					var interval=contourInterval(z), used=[];ctx.font='11px sans-serif';
					for(var y=0;y<256;y+=4){for(var x=0;x<256;x+=4){
						var v=[h(x,y),h(x+4,y),h(x+4,y+4),h(x,y+4)];
						if(v.some(function(a){return !Number.isFinite(a);})){continue;}
						var lo=Math.min.apply(Math,v),hi=Math.max.apply(Math,v);
						for(var level=Math.ceil(lo/interval)*interval;level<=hi && level<=lo+64*interval;level+=interval){
							contourSegments(v,level).forEach(function(segment){
								var major=level%(5*interval)===0, a=segment[0],b=segment[1];
								ctx.beginPath();ctx.moveTo(x+4*a[0],y+4*a[1]);ctx.lineTo(x+4*b[0],y+4*b[1]);
								ctx.strokeStyle=major?'rgba(120,77,42,.85)':'rgba(140,100,62,.55)';ctx.lineWidth=major?1.2:.65;ctx.stroke();
								var px=x+2*(a[0]+b[0]),py=y+2*(a[1]+b[1]);
								if(major && px>30 && px<215 && py>20 && py<235 && !used.some(function(p){return Math.abs(p[0]-px)<64&&Math.abs(p[1]-py)<24;})){
									used.push([px,py]);ctx.lineWidth=3;ctx.strokeStyle='rgba(255,255,255,.9)';ctx.strokeText(String(level)+' m',px,py);
									ctx.fillStyle='#704a2b';ctx.fillText(String(level)+' m',px,py);
								}
							});
						}
					}}
				}
				hint.textContent='';done(null,canvas);
			}).catch(function(e){if(serial===generation){hint.textContent=_('Could not load elevation data.');}done(e,canvas);});
		}
		function update(){
			generation++;hint.textContent='';
			if(!map){return;}
			if(!enabled.shade && !enabled.contours){if(layer){map.removeLayer(layer);layer=null;}return;}
			if(layer){layer.redraw();return;}
			var Terrain=lf.GridLayer.extend({createTile:function(coords,done){
				var canvas=document.createElement('canvas');canvas.width=canvas.height=256;
				paint(canvas,coords,done,generation);return canvas;
			}});
			layer=new Terrain({pane:'5gm-terrain',attribution:CREDIT,maxZoom:20,keepBuffer:1,updateWhenZooming:false}).addTo(map);
		}
		return {node:node,attach:function(m,leaflet){map=m;lf=leaflet;map.createPane('5gm-terrain').style.zIndex='300';update();},
			styleChanged:update,destroy:function(){generation++;if(layer&&map){map.removeLayer(layer);}layer=null;map=null;cache.clear();}};
	}
});
