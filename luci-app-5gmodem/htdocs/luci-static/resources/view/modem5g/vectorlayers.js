'use strict';
'require baseclass';

// OpenMapTiles source layers, shared by the four OpenFreeMap styles.
function categories(layer) {
	var src=layer['source-layer'], keys=[];
	if(src==='building'){keys.push('buildings');}
	if(src==='poi' || src==='aerodrome_label'){return ['poi'];}
	if(src==='transportation' || src==='transportation_name' || src==='aeroway'){keys.push('roads');}
	if(layer.type==='symbol' && layer.layout && layer.layout['text-field']){keys.push('labels');}
	return keys;
}

return baseclass.extend({
	build:function(){
		var gl=null, entries=[], enabled={}, inputs={}, ready=false;
		var choices=[['buildings',_('Buildings')],['labels',_('Labels')],['poi',_('Points of interest')],['roads',_('Roads')],['extrusion',_('3D buildings')]];
		var node=E('span',{'class':'tg-gps-layergroup','style':'display:none'},[
			E('b',{},'OpenFreeMap')].concat(choices.map(function(choice){
				var key=choice[0], value=null;
				try{value=window.localStorage.getItem('5gmodem.gps.vector.'+key);}catch(e){}
				enabled[key]=value===null ? key!=='extrusion' : value==='1';
				var input=E('input',{'type':'checkbox','disabled':'','change':function(){
					enabled[key]=input.checked;
					try{window.localStorage.setItem('5gmodem.gps.vector.'+key, input.checked?'1':'0');}catch(e){}
					apply();
				}});
				input.checked=enabled[key];inputs[key]=input;
				return E('label',{},[input,' ',choice[1]]);
			})));
		function apply(){
			if(!gl || !ready){return;}
			entries.forEach(function(entry){
				var layer=entry.layer, visible=entry.visibility!=='none' && entry.keys.every(function(k){return enabled[k];});
				if(layer.id==='5gmodem-buildings-3d'){visible=visible && enabled.extrusion;}
				gl.setLayoutProperty(layer.id,'visibility',visible?'visible':'none');
				if(layer.type==='fill-extrusion' && layer['source-layer']==='building' && layer.id!=='5gmodem-buildings-3d'){
					// Keep native footprints (including Liberty's zoom 14+ buildings)
					// when 3D is off, rather than leaving holes at high zoom.
					gl.setPaintProperty(layer.id,'fill-extrusion-height',enabled.extrusion?entry.height:0);
					gl.setPaintProperty(layer.id,'fill-extrusion-base',enabled.extrusion?entry.base:0);
				}
			});
		}
		function loaded(){
			if(!gl || ready){return;}
			var style=gl.getStyle(), layers=style && style.layers || [];
			var buildings=layers.find(function(l){return l['source-layer']==='building' && l.type==='fill';});
			if(buildings && !layers.some(function(l){return l['source-layer']==='building' && l.type==='fill-extrusion';})){
				// Use supplied heights only; unknown heights stay as flat footprints.
				var added={id:'5gmodem-buildings-3d',type:'fill-extrusion',source:buildings.source,'source-layer':'building',minzoom:14,
					filter:['all',['!', ['has','hide_3d']],['>', ['coalesce',['get','render_height'],0],0]],
					layout:{visibility:'none'},paint:{'fill-extrusion-height':['coalesce',['get','render_height'],0],
						'fill-extrusion-base':['coalesce',['get','render_min_height'],0],
						'fill-extrusion-color':(buildings.paint||{})['fill-color']||'#b8b8b8','fill-extrusion-opacity':.85}};
				var firstSymbol=layers.find(function(l){return l.type==='symbol';});
				gl.addLayer(added,firstSymbol && firstSymbol.id);layers=gl.getStyle().layers;
			}
			entries=layers.map(function(l){return {layer:l,keys:categories(l),visibility:l.id==='5gmodem-buildings-3d'?'visible':(l.layout||{}).visibility,
				height:(l.paint||{})['fill-extrusion-height'] || 0,base:(l.paint||{})['fill-extrusion-base'] || 0};}).filter(function(e){return e.keys.length;});
			ready=true;
			choices.forEach(function(c){inputs[c[0]].disabled=!entries.some(function(e){return c[0]==='extrusion'?e.layer.type==='fill-extrusion':e.keys.indexOf(c[0])!==-1;});});
			apply();
		}
		function detach(){if(gl){gl.off('style.load',loaded);}gl=null;entries=[];ready=false;choices.forEach(function(c){inputs[c[0]].disabled=true;});}
		return {node:node,
			select:function(vector){detach();node.style.display=vector?'':'none';},
			attach:function(map){detach();gl=map;if(gl){gl.on('style.load',loaded);if(gl.isStyleLoaded()){loaded();}}},
			destroy:detach
		};
	}
});
