'use strict';
'require baseclass';
'require rpc';

var requestLayers = rpc.declare({ object: '5gmodem_maps', method: 'layers',
	params: [ 'kind', 'south', 'west', 'north', 'east', 'zoom', 'operator', 'technology' ], nobatch:true, expect: { '': {} } });
var rpcJobs = [], rpcActive = 0, rpcPoints = 0, rpcLimit = 3;
// Each image must arrive independently rather than wait for a whole LuCI batch.
var requestTiles = rpc.declare({ object:'5gmodem_maps',method:'tiles',params:['tiles','zoom','operator','technology'],nobatch:true,expect:{'':{}} });
var tileJobs=[],tileTimer=null,tileBatchRunning=false;
function drainRequests(){
	while(rpcActive<rpcLimit && rpcJobs.length){
		var index=rpcJobs.findIndex(function(job){return (job.priority!==0 || rpcPoints===0) && rpcActive+Math.min(job.weight,rpcLimit)<=rpcLimit;});
		if(index<0){return;}
		var job=rpcJobs.splice(index,1)[0];
		if(job.active && !job.active()){job.resolve({ok:false,error:'cancelled'});continue;}
		job.cost=Math.min(job.weight,rpcLimit);rpcActive+=job.cost;
		if(job.priority===0){rpcPoints++;}
		(function(job){Promise.resolve().then(job.run).then(function(result){
			// Older routers without shared flock still serialize their account lock.
			if(job.priority!==0 && result.error==='busy' && job.retries++<3){rpcLimit=1;rpcJobs.unshift(job);}
			else{job.resolve(result);}
		},job.reject).finally(function(){rpcActive-=job.cost;if(job.priority===0){rpcPoints--;}drainRequests();});})(job);
	}
}
function enqueueRequest(run,priority,active,weight){
	return new Promise(function(resolve,reject){
		rpcJobs.push({run:run,priority:priority,active:active,resolve:resolve,reject:reject,retries:0,weight:weight||1});
		rpcJobs.sort(function(a,b){return a.priority-b.priority;});drainRequests();
	});
}
function fetchTile(x,y,z,operator,technology,active,ready){
	return new Promise(function(resolve,reject){
		tileJobs.push({pair:String(x)+':'+String(y),zoom:String(z),operator:String(operator),technology:technology,active:active||function(){return true;},ready:ready||function(){return true;},resolve:resolve,reject:reject});
		scheduleTiles();
	});
}
function scheduleTiles(){
	if(tileTimer===null && !tileBatchRunning && tileJobs.length){tileTimer=setTimeout(flushTiles,16);}
}
function flushTiles(){
	tileTimer=null;
	tileJobs=tileJobs.filter(function(job){if(job.active()){return true;}job.resolve({ok:false,error:'cancelled'});return false;});
	if(!tileJobs.length){return;}
	var first=tileJobs.find(function(job){return job.ready();}),batch=[];
	if(!first){scheduleTiles();return;}
	tileJobs=tileJobs.filter(function(job){
		if(batch.length<12 && job.ready() && job.zoom===first.zoom && job.operator===first.operator && job.technology===first.technology){batch.push(job);return false;}return true;
	});
	tileBatchRunning=true;
	// Reserve all three network slots: the backend uses at most three transfers.
	enqueueRequest(function(){
		var visible=batch.filter(function(job){return job.active();});
		if(!visible.length){return {ok:false,error:'cancelled'};}
		var pairs=Array.from(new Set(visible.map(function(job){return job.pair;})));
		return requestTiles(pairs.join(','),first.zoom,first.operator,first.technology);
	},1,function(){return batch.some(function(job){return job.active();});},3).then(function(result){
		batch.forEach(function(job){job.resolve(!job.active()?{ok:false,error:'cancelled'}:!result.ok?result:result.tiles?.[job.pair]||{ok:false,error:'unexpected_response'});});
	},function(error){batch.forEach(function(job){job.reject(error);});}).finally(function(){tileBatchRunning=false;scheduleTiles();});
}
function fetchLayers() {
	var args = Array.prototype.slice.call(arguments);
	args[5] = String(args[5]);
	return enqueueRequest(function(){return requestLayers.apply(null,args);},0);
}
var CREDIT = '<a href="https://speedmetrics.ru/" target="_blank" rel="noopener">Speedmetrics</a> / <a href="https://4cells.ru/" target="_blank" rel="noopener">4Cells</a>';

function providerSuspended(code) {
	return ['rate_limited','access_denied','provider_paused','unexpected_response'].indexOf(code)!==-1;
}

function layerPreference(key, value) {
	try {
		if(value!==undefined){window.localStorage.setItem('5gmodem.gps.external.'+key,String(value));}
		return window.localStorage.getItem('5gmodem.gps.external.'+key);
	}catch(e){return null;}
}

function decode(data) {
	if (Array.isArray(data.data)) { return data.data.map(function(p) { return { lat: p.lat, lon: p.lon, enb: p.num, band: p.bands, locType:p.locType, bsType:p.bsType }; }); }
	if (!Array.isArray(data.cols)) { return Array.isArray(data.items) ? data.items : []; }
	var dicts = data.dicts || {};
	return (data.rows || []).slice(0, 1500).map(function(row) {
		var point = {};
		data.cols.forEach(function(key, i) {
			if ([ 'lat', 'lon', 'dl', 'ul', 'ping', 'operator', 'net', 'band', 'caBw', 'ts' ].indexOf(key) < 0) { return; }
			point[key] = Array.isArray(dicts[key]) ? dicts[key][row[i]] : row[i];
		});
		return point;
	});
}

function towerColor(point) {
	var located=+point.locType>1;
	return +point.bsType===6 ? (located?'#ffff00':'#85855e') : (located?'#00c000':'#f30000');
}

function speedColor(value) {
	return value == null ? '#8c8c8e' : value < 20 ? '#f25660' : value < 50 ? '#f2ac4b' : value < 150 ? '#53b687' : '#00bbff';
}

// Merge overlapping badge-sized rectangles in screen coordinates. Repeat after
// averaging groups, since a group's new center can collide with another badge.
function clusterSpeeds(points, project) {
	var groups = points.map(function(p) { var xy = project([+p.lat, +p.lon]); return { points: [p], x: xy.x, y: xy.y }; });
	while (groups.length > 1) {
		var bins = {}, parent = groups.map(function(_, i) { return i; }), joined = false;
		function root(i) { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; }
		groups.forEach(function(g, i) {
			var bx = Math.floor(g.x / 88), by = Math.floor(g.y / 48);
			for (var dx = -1; dx <= 1; dx++) { for (var dy = -1; dy <= 1; dy++) {
				(bins[(bx + dx) + ':' + (by + dy)] || []).forEach(function(j) {
					if (Math.abs(g.x - groups[j].x) < 88 && Math.abs(g.y - groups[j].y) < 48) {
						var a = root(i), b = root(j); if (a !== b) { parent[a] = b; joined = true; }
					}
				});
			} }
			var key = bx + ':' + by; (bins[key] || (bins[key] = [])).push(i);
		});
		if (!joined) { break; }
		var next = {};
		groups.forEach(function(g, i) {
			var r = root(i), n = g.points.length;
			if (!next[r]) { next[r] = { points: [], x: 0, y: 0 }; }
			next[r].points = next[r].points.concat(g.points); next[r].x += g.x * n; next[r].y += g.y * n;
		});
		groups = Object.keys(next).map(function(k) { var g = next[k]; g.x /= g.points.length; g.y /= g.points.length; return g; });
	}
	return groups;
}

function medianSpeed(points, key) {
	var values = points.map(function(p) { return speedValue(p[key]); }).filter(function(v) { return v !== null; }).sort(function(a,b) { return a-b; });
	if (!values.length) { return null; }
	var middle = Math.floor(values.length / 2);
	return values.length % 2 ? values[middle] : (values[middle-1] + values[middle]) / 2;
}

function speedValue(value) {
	return value != null && Number.isFinite(+value) && +value >= 0 ? +value : null;
}

function speedText(value) {
	return value === null ? '—' : value >= 10 ? String(Math.round(value)) : value.toFixed(1);
}

function serviceIcon(lf, kind, point) {
	var down = speedValue(point.dl), up = speedValue(point.ul), plate;
	if (kind === 'speed') {
		var value = down !== null ? down : up;
		plate = E('div', { 'class': 'tg-gps-speedpill' + (point.count > 1 ? ' tg-gps-speedcluster' : ''), 'style': '--speed-color:' + speedColor(value) }, [
			E('i', { 'aria-hidden': 'true' }),
			E('b', {}, (down !== null ? '↓ ' : up !== null ? '↑ ' : '') + speedText(value))
		]);
		if (point.count > 1) { plate.appendChild(E('em', {}, String(point.count))); }
	} else {
		plate = E('div', { 'class': 'tg-gps-towerplate' + (down === null && up === null ? ' no-measures' : '') }, [
			E('b', {}, String(point.enb == null ? '—' : point.enb).slice(0, 30))
		]);
		if (point.nr === true || +point.nr > 0) { plate.appendChild(E('em', {}, '5G')); }
		if (down !== null || up !== null) {
			var speeds = E('div', { 'class': 'tg-gps-plate-speeds' });
			if (down !== null) { speeds.appendChild(E('span', { 'class': 'dl' }, '↓' + speedText(down))); }
			if (up !== null) { speeds.appendChild(E('span', { 'class': 'ul' }, '↑' + speedText(up))); }
			plate.appendChild(speeds);
		}
	}
	return lf.divIcon({ className: 'tg-gps-map-pin', iconSize: [0, 0], html: plate });
}

return baseclass.extend({
	tile:fetchTile,
	build: function(options) {
		options = options || {};
		var map, lf, timer, running = false, disposed = false, revision = 0, credited = false;
		var enabled = {}, groups = {}, cache = {}, paused = {}, drawn = {}, trailStatus='', speedZoom=null, popupActive=false, labels = { fourcells: _('Towers (4Cells)'), towers: _('Towers (Speedmetrics)'), speed: _('Speed measurements (Speedmetrics)'), trails: _('Measurements (4Cells)') };
		var operatorsReady = false, operatorsLoading = false, operatorTouched = false, operatorGeneration = 0, operatorCodes = [];
		var operatorRetry, operatorAttempts=0, operatorError='';
		var speedPoints = [];
		var pointStatus = [];
		var storedOperator=layerPreference('operator')||'', towerLabels=[];
		operatorTouched=!!storedOperator;
		var operator = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Operator'), 'focus': function(){loadOperators();}, 'change': function() { operatorTouched = true; storedOperator=operator.value;layerPreference('operator',operator.value);invalidate('fourcells'); schedule(); } }, [ E('option', { 'value': '' }, _('Select operator')) ]);
		var technology = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Network type'), 'change': function(){layerPreference('technology',technology.value);invalidate('fourcells');schedule();} },
			[ ['gsm', '2G'], ['wcdma', '3G'], ['lte', '4G'], ['nr', '5G'] ].map(function(p) { return E('option', { 'value': p[0] }, p[1]); }));
		var storedTechnology=layerPreference('technology');
		technology.value = ['gsm','wcdma','lte','nr'].indexOf(storedTechnology)!==-1 ? storedTechnology : 'lte';
		var filters = E('span', { 'style': 'display:none', 'class': 'tg-gps-layerfilters' }, [ operator, technology ]);
		var hint = E('small', { 'role': 'status', 'aria-live': 'polite', 'class': 'tg-gps-layerstatus' });
		var shortLabels = {fourcells: _('Towers'), towers: _('Towers'), speed: _('Speed'),trails:_('Measurements')};
		var checks = {};
		Object.keys(labels).forEach(function(kind) {
			enabled[kind]=layerPreference(kind)==='1';
			var input = E('input', { 'type': 'checkbox', 'aria-label': labels[kind], 'change': function() {
				enabled[kind] = input.checked;
				layerPreference(kind,input.checked?'1':'0');
				invalidate(kind);
				if (kind === 'fourcells' || kind==='trails') { filters.style.display = enabled.fourcells||enabled.trails ? 'inline-flex' : 'none'; if (enabled[kind]) { loadOperators(); } }
				if(kind==='trails' && !enabled.trails){trailStatus='';}
				credit(); schedule();
			} });
			input.checked=enabled[kind];
			checks[kind] = E('label', {}, [ input, ' ', shortLabels[kind] ]);
		});
		filters.style.display=enabled.fourcells||enabled.trails?'inline-flex':'none';
		var node = E('span', { 'class': 'tg-gps-external-layers' }, [
			E('span', { 'class': 'tg-gps-layergroup' }, [ E('b', {}, '4Cells:'), checks.fourcells,checks.trails ]),
			E('span', { 'class': 'tg-gps-layergroup' }, [ E('b', {}, 'Speedmetrics:'), checks.towers, checks.speed ])
		]);
		node.appendChild(filters);
		node.appendChild(E('a', { 'href': L.url('admin/modem/5gmodem/settings') + '#tele' }, _('4Cells login')));
		node.appendChild(hint);
		function active() { return enabled.fourcells || enabled.towers || enabled.speed || enabled.trails; }
		function invalidate(kind){delete drawn[kind];if(kind==='speed'){speedZoom=null;}if(kind==='fourcells'){towerLabels=[];}if(groups[kind]){groups[kind].clearLayers();}}
		function loadOperators() {
			if(disposed || !(enabled.fourcells||enabled.trails)){return;}
			if(paused.fourcells){hint.textContent='4Cells: '+errorText(paused.fourcells);return;}
			if (operatorsReady || operatorsLoading) { return; }
			window.clearTimeout(operatorRetry);
			operatorsLoading = true;operatorAttempts++;operatorError='';
			showStatus();
			fetchLayers('operators', '', '', '', '', 0, '', '').then(function(j) {
				if (!j.ok) { if (providerSuspended(j.error)) { paused.fourcells=j.error; } var error=new Error(errorText(j.error));error.code=j.error;throw error; }
				if (disposed) { return; }
				if(!Array.isArray(j.data) || !j.data.some(function(c){return Array.isArray(c.operators)&&c.operators.length;})){throw new Error(errorText('unexpected_response'));}
				(j.data || []).forEach(function(country) {
					var group = E('optgroup', { 'label': country.englishName || country.name || '' });
					(country.operators || []).forEach(function(op) {
						operatorCodes.push(String(op.internalCode));
						group.appendChild(E('option', { 'value': op.internalCode }, String(op.name || op.visibleCode || op.internalCode)));
					});
					operator.appendChild(group);
				});
				operatorsReady = true;
				if(storedOperator && operatorCodes.indexOf(storedOperator)!==-1){operator.value=storedOperator;schedule();}
				else if(storedOperator){storedOperator='';operatorTouched=false;layerPreference('operator','');}
				selectCurrentOperator();
			}).catch(function(e) {
				if(disposed){return;}
				operatorError=e.message||errorText();
				if(!paused.fourcells && (!e.code||e.code==='busy'||e.code==='network') && operatorAttempts<3){
					operatorRetry=window.setTimeout(loadOperators,operatorAttempts*1500);
				}
			}).finally(function() { operatorsLoading = false;if(!disposed){showStatus();} });
		}
		function selectCurrentOperator() {
			if (!operatorsReady || operatorTouched || !options.getOperator) { return; }
			var generation = ++operatorGeneration;
			Promise.resolve().then(options.getOperator).then(function(j) {
				if (disposed || generation !== operatorGeneration || operatorTouched) { return; }
				var mcc = String(j.operator_mcc || ''), mnc = String(j.operator_mnc || '');
				if (!/^\d{3}$/.test(mcc) || !/^\d{1,3}$/.test(mnc)) { return; }
				var code = mcc + ('000' + mnc).slice(-3);
				if (operatorCodes.indexOf(code) >= 0) { operator.value = code; schedule(); }
			}).catch(function() {});
		}
		function credit() {
			if (!map || !map.attributionControl) { return; }
			if (active() && !credited) { map.attributionControl.addAttribution(CREDIT); credited = true; }
			if (!active() && credited) { map.attributionControl.removeAttribution(CREDIT); credited = false; }
		}
		function schedule() {
			if(options.measurements){options.measurements.configure({enabled:!!enabled.trails,operator:operator.value,technology:technology.value});}
			revision++;
			window.clearTimeout(timer);
			if (!active()) { hint.textContent = ''; return; }
			timer = window.setTimeout(refresh, 150);
		}
		function showStatus() {
			if((enabled.fourcells||enabled.trails)&&!operatorsReady){
				hint.textContent='4Cells: '+(operatorError||_('Loading…'));return;
			}
			var trails = enabled.trails ? [labels.trails + ': ' + (operator.value ? (trailStatus || _('Loading…')) : _('Select operator'))] : [];
			hint.textContent = pointStatus.concat(trails).join(' · ');
		}
		function errorText(code) {
			return ({ zoom_in: _('Zoom in to load external layers.'), sign_in_required: _('Sign in under Settings → Telemetry.'),
				busy: _('An account operation is already running.'), rate_limited: _('Too many requests. Try again later.'),
				access_denied: _('The service denied access. Layer requests are paused.'),
				provider_paused: _('Layer requests are temporarily paused after a service error.'),
				unexpected_response: _('The service returned an unexpected page. Layer requests are paused.'),
				curl_required: _('Install curl to connect to these services.') })[code] || _('Could not load the external layer.');
		}
		function pointDetails(p, kind) {
			var details = [ E('b', {}, String(p.op || p.operator || p.net || '').slice(0, 100)) ];
			if (kind !== 'speed') { details.push(E('div', {}, _('Cell ID') + ': ' + String(p.enb == null ? '—' : p.enb).slice(0, 30))); }
			[ ['dl', '↓', _('Mbit/s')], ['ul', '↑', _('Mbit/s')], ['ping', 'RTT', _('ms')] ].forEach(function(field) {
				var value = speedValue(p[field[0]]);
				if (value !== null) { details.push(E('div', {}, field[1] + ' ' + value.toFixed(1) + ' ' + field[2])); }
			});
			if (p.band) { details.push(E('div', {}, String(p.band).slice(0, 100))); }
			if (kind==='fourcells') {
				var positions={1:_('Calculated position'),2:_('Manually set position'),3:_('Verified position'),4:_('Position inherited from site')};
				if(positions[p.locType]){details.push(E('div',{},positions[p.locType]));}
				if(+p.bsType===6){details.push(E('div',{},_('Position needs clarification')));}
			}
			return E('div', {}, details);
		}
		function clusterPopup(points) {
			var page = 0, size = 25, list = E('div', { 'class': 'tg-gps-measure-list' }), position = E('span');
			var previous = E('button', { 'type': 'button', 'class': 'cbi-button', 'click': function() { page--; paint(); } }, _('Previous'));
			var next = E('button', { 'type': 'button', 'class': 'cbi-button', 'click': function() { page++; paint(); } }, _('Next'));
			function paint() {
				list.replaceChildren.apply(list, points.slice(page*size, (page+1)*size).map(function(p) { return E('div', { 'class': 'tg-gps-measure-row' }, pointDetails(p, 'speed')); }));
				position.textContent = (page*size + 1) + '–' + Math.min((page+1)*size, points.length) + ' / ' + points.length;
				previous.disabled = page === 0; next.disabled = (page+1)*size >= points.length;
			}
			paint();
			return E('div', {}, [ E('b', {}, _('Measurements') + ': ' + points.length), list,
				E('div', { 'class': 'tg-gps-measure-pager' }, [previous, position, next]) ]);
		}
		function drawSpeed(force) {
			if (!map || !groups.speed) { return; }
			if(!force && speedZoom===map.getZoom()){return;}
			speedZoom=map.getZoom();
			groups.speed.clearLayers();
			if (!enabled.speed) { return; }
			clusterSpeeds(speedPoints, function(ll) { return map.latLngToLayerPoint(ll); }).forEach(function(g) {
				var many = g.points.length > 1;
				var point = many ? { dl: medianSpeed(g.points, 'dl'), ul: medianSpeed(g.points, 'ul'), count: g.points.length } : g.points[0];
				var ll = many ? map.layerPointToLatLng({x:g.x, y:g.y}) : [+point.lat, +point.lon];
				var marker = lf.marker(ll, { icon: serviceIcon(lf, 'speed', point), pane: '5gm-external',
					title: many ? _('Measurements') + ': ' + g.points.length : String(point.operator || point.net || '').slice(0,100), alt: labels.speed });
				marker.bindPopup(many ? clusterPopup(g.points) : pointDetails(point, 'speed')).addTo(groups.speed);
				if (many) { marker.on('click', function() {
					if (options.onExplore) { options.onExplore(); }
					if (map.getZoom() < map.getMaxZoom()) {
						map.fitBounds(g.points.map(function(p) { return [+p.lat, +p.lon]; }), {padding:[45,45], maxZoom:Math.min(map.getZoom()+3,map.getMaxZoom())});
					}
				}); }
			});
		}
		function draw(kind, data) {
			if(drawn[kind] && drawn[kind].data===data){return drawn[kind].count;}
			var points = decode(data).slice(0,1500).filter(function(p) {
				return p.lat != null && p.lon != null && Number.isFinite(+p.lat) && Number.isFinite(+p.lon) && Math.abs(+p.lat) <= 85 && Math.abs(+p.lon) <= 180;
			});
			var group = groups[kind];
			if(kind==='fourcells'){towerLabels=[];}
			drawn[kind]={data:data,count:points.length};
			group.clearLayers();
			if (kind === 'speed') { speedPoints = points; drawSpeed(true); return points.length; }
			points.forEach(function(p) {
				var marker = kind === 'fourcells' ? lf.circleMarker([+p.lat,+p.lon], {radius:7,color:'#fff',weight:1,fillColor:towerColor(p),fillOpacity:.9,pane:'5gm-external'}) :
					lf.marker([+p.lat,+p.lon], {icon:serviceIcon(lf,kind,p),pane:'5gm-external',title:String(p.op||'').slice(0,100),alt:labels.towers});
				marker.bindPopup(pointDetails(p, kind)).addTo(group);
				if(kind==='fourcells' && (p.enb!=null || p.band)){
					var caption=E('div',{'class':'tg-gps-fourcells-caption'});
					if(p.enb!=null){caption.appendChild(E('b',{},String(p.enb).slice(0,30)));}
					if(p.band){caption.appendChild(E('span',{},String(p.band).slice(0,80)));}
					marker.bindTooltip(caption,{permanent:true,direction:'bottom',offset:[0,8],className:'tg-gps-fourcells-label',opacity:1,interactive:false});
					towerLabels.push(marker);
				}
			});
			if(kind==='fourcells'){syncTowerLabels();}
			return points.length;
		}
		function syncTowerLabels(){towerLabels.forEach(function(marker){if(map.getZoom()>=15){marker.openTooltip();}else{marker.closeTooltip();}});}
		function onMapMove() { drawSpeed(); syncTowerLabels(); if(!popupActive){schedule();} }
		function onPopupOpen(){popupActive=true;if(options.onExplore){options.onExplore();}}
		function onPopupClose(){popupActive=false;schedule();}

		function refresh() {
			if (disposed || !map || running || popupActive || !active()) { return; }
			var my = revision, b = map.getBounds(), z = Math.floor(map.getZoom());
			var coords = [b.getSouth(), b.getWest(), b.getNorth(), b.getEast()];
			if (z < 4 || coords[0] < -85 || coords[2] > 85 || coords[1] < -180 || coords[3] > 180) {
				Object.keys(groups).forEach(invalidate);
				hint.textContent = errorText('zoom_in'); return;
			}
			coords = coords.map(function(v) { return v.toFixed(5); });
			// A small margin absorbs GPS-follow jitter without refetching the same area.
			var spanLat=+coords[2]-coords[0], spanLon=+coords[3]-coords[1];
			var padLat=spanLat*.15, padLon=spanLon*.15;
			var area=[Math.max(-85,+coords[0]-padLat),Math.max(-180,+coords[1]-padLon),Math.min(85,+coords[2]+padLat),Math.min(180,+coords[3]+padLon)].map(function(v,i){return (i<2?Math.floor(v*1e5):Math.ceil(v*1e5))/1e5;});
			running = true;
			hint.textContent = _('Loading external layers…');
			var counts = [], errors = [], queue = Promise.resolve();
			Object.keys(labels).forEach(function(kind) {
				if(kind==='trails'){return;}
				if (!enabled[kind]) { return; }
				if(kind!=='fourcells' && (z<12 || spanLat>1 || spanLon>1)){
					invalidate(kind);errors.push(labels[kind]+': '+errorText('zoom_in'));return;
				}
				if (kind === 'fourcells' && !operator.value) {
					if(paused.fourcells){errors.push(labels[kind]+': '+errorText(paused.fourcells));}
					else {counts.push(_('Select operator'));}
					return;
				}
				queue = queue.then(function() {
					if (disposed || my !== revision || !enabled[kind] || popupActive) { return; }
					var service=kind==='fourcells'?'fourcells':'speedmetrics';
					if(paused[service]){errors.push(labels[kind]+': '+errorText(paused[service]));return;}
					var requestArea=kind==='fourcells'?area:[Math.max(-85,+coords[0]-Math.min(padLat,(1-spanLat)/2)),Math.max(-180,+coords[1]-Math.min(padLon,(1-spanLon)/2)),Math.min(85,+coords[2]+Math.min(padLat,(1-spanLat)/2)),Math.min(180,+coords[3]+Math.min(padLon,(1-spanLon)/2))].map(function(v){return +v.toFixed(5);});
					var key = z + ',' + (kind==='fourcells'?operator.value+','+technology.value:''), previous = cache[kind];
					var covered=previous && previous.key===key && previous.area[0]<=+coords[0] && previous.area[1]<=+coords[1] && previous.area[2]>=+coords[2] && previous.area[3]>=+coords[3];
					var request = covered && Date.now() - previous.ts < 300000 ? Promise.resolve(previous.data) :
						fetchLayers(kind, requestArea[0], requestArea[1], requestArea[2], requestArea[3], z, operator.value, technology.value).then(function(j) {
							if (!j.ok) { if(providerSuspended(j.error)){paused[service]=j.error;} throw new Error(errorText(j.error)); }
							if (kind === 'fourcells' && !j.data.success) { throw new Error(errorText()); }
							cache[kind] = { key: key, area:requestArea, ts: Date.now(), data: j.data };
							return j.data;
						});
					return request.then(function(data) {
						if (disposed || my !== revision || !enabled[kind] || popupActive) { return; }
						counts.push(labels[kind] + ': ' + draw(kind, data));
					}).catch(function(e) { if (!disposed && my === revision) { errors.push(labels[kind]+': '+(e.message || errorText())); } });
				});
			});
			queue.finally(function() {
				running = false;
				if (disposed) { return; }
				if (my !== revision) { schedule(); return; }
				pointStatus = counts.concat(errors);
				showStatus();
			});
		}
		return { node: node, measurementStatus:function(code){
			trailStatus=code === 'loading' ? _('Loading…') : code ? errorText(code) : '✓';
			if(providerSuspended(code)){paused.fourcells=code;if(options.measurements){options.measurements.pause();}}
			showStatus();
		}, modemChanged: function() { operatorGeneration++; operatorTouched = false; storedOperator='';layerPreference('operator','');operator.value = ''; invalidate('fourcells'); selectCurrentOperator();schedule(); }, attach: function(m, leaflet) {
			map = m; lf = leaflet;
			map.createPane('5gm-external').style.zIndex = '410';
			Object.keys(labels).filter(function(k){return k!=='trails';}).forEach(function(k) { groups[k] = lf.layerGroup().addTo(map); });
			map.on('moveend', onMapMove);
			map.on('popupopen',onPopupOpen);map.on('popupclose',onPopupClose);
			if(enabled.fourcells||enabled.trails){loadOperators();}
			credit(); schedule();
		}, destroy: function() {
			disposed = true; revision++; window.clearTimeout(timer);
			window.clearTimeout(operatorRetry);
			if (map) { map.off('moveend', onMapMove); }
			if (map) { map.off('popupopen',onPopupOpen);map.off('popupclose',onPopupClose); }
			Object.keys(groups).forEach(function(k) { groups[k].clearLayers(); });
		} };
	}
});
