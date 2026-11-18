'use strict';
'require view';
'require ui';
'require fs';
'require uci';
'require rpc';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

// GNSS receiver of the modem, see docs/subsystems/gps.md
var BIN = '/usr/share/5gmodem/gps.sh';
// settings on this tab are saved like the Settings page does: uci save + commit of 5gmodem
var uciCommit = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	expect: { '': {} }
});

var OSM_TILES = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
var OSM_ATT = '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>';
// Ready map styles. u: tile address; z: deepest zoom; nz: deepest zoom the server has tiles for
// (deeper ones are the last level stretched: OpenTopoMap draws 16+ on demand and often times out); inv: a light map, darkened by a CSS filter
// in a dark interface; crs 3395: Yandex tiles are cut in the elliptical Mercator projection, on
// the usual one the position would sit hundreds of metres off.
var MAPS = [
	{ k: 'osm', n: 'OpenStreetMap', u: OSM_TILES, z: 19, inv: 1, a: OSM_ATT },
	{ k: 'osm-hot', n: 'OpenStreetMap HOT', u: 'https://a.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png', z: 19, inv: 1, a: OSM_ATT + ', HOT' },
	{ k: 'topo', n: 'OpenTopoMap', u: 'https://a.tile.opentopomap.org/{z}/{x}/{y}.png', z: 19, nz: 15, inv: 1, a: OSM_ATT + ', SRTM | &copy; OpenTopoMap (CC-BY-SA)' },
	{ k: 'esri-street', n: 'Esri Streets', u: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}', z: 19, inv: 1, a: 'Tiles &copy; Esri' },
	{ k: 'esri-sat', n: 'Esri Satellite', u: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', z: 19, a: 'Tiles &copy; Esri, Maxar, Earthstar Geographics' },
	{ k: 'yandex', n: 'Yandex', u: 'https://core-renderer-tiles.maps.yandex.net/tiles?l=map&x={x}&y={y}&z={z}&scale=1&lang=ru_RU', z: 19, inv: 1, crs: 3395, a: '&copy; Yandex' },
	{ k: 'yandex-dark', n: 'Yandex Dark', u: 'https://core-renderer-tiles.maps.yandex.net/tiles?l=map&theme=dark&x={x}&y={y}&z={z}&scale=1&lang=ru_RU', z: 19, crs: 3395, a: '&copy; Yandex' },
	{ k: 'yandex-sat', n: 'Yandex Satellite', u: 'https://core-sat.maps.yandex.net/tiles?l=sat&x={x}&y={y}&z={z}&scale=1&lang=ru_RU', z: 19, crs: 3395, a: '&copy; Yandex' }
];
function mapByKey(k) {
	for (var i = 0; i < MAPS.length; i++) { if (MAPS[i].k === k) { return MAPS[i]; } }
	return null;
}
var POLL_MS = 5000;
var TRACK_MAX = 2000;
var PHONE_MQ = '(max-width: 700px)';

var pageModemPath = '';

function args(a) {
	a = a.slice();
	if (pageModemPath) { a.push('for=' + pageModemPath); }
	return a;
}

function run(a) {
	return L.resolveDefault(fs.exec_direct(BIN, args(a)), '').then(function(out) {
		try { return JSON.parse(out || '{}'); } catch (e) { return {}; }
	});
}

// Leaflet assigns window.L, which is LuCI itself: evaluate it synchronously and hand LuCI's L
// back with noConflict() before any other code can run.
var _leaflet = null;
function loadLeaflet() {
	if (_leaflet) { return _leaflet; }
	if (!document.getElementById('gps-leaflet-css')) {
		document.head.appendChild(E('link', { 'id': 'gps-leaflet-css', 'rel': 'stylesheet',
			'href': L.resource('5gmodem/leaflet.css') }));
	}
	_leaflet = window.fetch(L.resource('5gmodem/leaflet.js')).then(function(r) {
		if (!r.ok) { throw new Error('HTTP ' + r.status); }
		return r.text();
	}).then(function(src) {
		var luci = window.L, exp = {};
		try {
			(new Function('exports', 'module', src + '\n//# sourceURL=leaflet.js'))(exp, { exports: exp });
		} finally {
			if (typeof exp.noConflict === 'function') { exp.noConflict(); }
			window.L = luci;
		}
		if (typeof exp.map !== 'function') { throw new Error('leaflet'); }
		return exp;
	}).catch(function(e) { _leaflet = null; throw e; });
	return _leaflet;
}

function num(v, digits) {
	if (v === null || v === undefined || v === '' || isNaN(+v)) { return null; }
	return (+v).toFixed(digits);
}

// Unit part of a translated "%s m" / "%s km/h", so the tiles reuse the existing strings.
function unitOf(fmt) { return fmt.format('').trim(); }

var ICONS = {
	pin: '<g fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21.5s-6.5-6-6.5-11.5a6.5 6.5 0 0 1 13 0c0 5.5-6.5 11.5-6.5 11.5Z"/><circle cx="12" cy="10" r="2.4"/></g>',
	sat: '<g fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M13 7 9 3 5 7l4 4"/><path d="m17 11 4 4-4 4-4-4"/><path d="m8 12 4 4 6-6-4-4Z"/><path d="m16 8 3-3"/><path d="M9 21a6 6 0 0 0-6-6"/></g>',
	copy: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></g>',
	center: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3"/></g>',
	erase: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 18c3-6 6-1 9-6s5-4 7-3"/><path d="m15 19 5-5M15 14l5 5"/></g>',
	eye: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/></g>',
	arrow: '<path d="M12 2 19 21 12 17 5 21Z" fill="currentColor"/>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size, cls) {
	var s = E('span', { 'class': cls || 'tg-gps-i' });
	s.innerHTML = svg(name, size);
	return s;
}

// Same idea as isDarkUI in netpri.js: light text on the page means a dark theme, whatever the
// theme calls its dark mode.
function isDarkUI(el) {
	var c = getComputedStyle(el || document.body).color;
	var m = String(c).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	if (!m) { return false; }
	return (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

// collapsibleSection() of 5gdetail.js with the same classes and storage key scheme; the default
// state can differ (the receiver block starts collapsed on phones).
function collapsibleSection(key, titleText, content, defOpen) {
	var expanded = defOpen;
	try { var v = localStorage.getItem('5gm-blk-' + key); if (v === '0' || v === '1') { expanded = v === '1'; } } catch (e) {}
	var chev = E('span', { 'style': 'display:inline-flex;transition:transform .15s ease;transform:rotate(' + (expanded ? '180' : '0') + 'deg)' });
	chev.innerHTML = svg('chev', 16);
	var body = E('div', { 'class': 'tg-collapse' + (expanded ? ' open' : '') }, [ E('div', { 'class': 'tg-collapse-inner' }, content) ]);
	var toggle = function() {
		var exp = !body.classList.contains('open');
		body.classList.toggle('open', exp);
		title.style.marginBottom = exp ? '.5em' : '0';
		title.setAttribute('aria-expanded', String(exp));
		chev.style.transform = 'rotate(' + (exp ? '180' : '0') + 'deg)';
		try { localStorage.setItem('5gm-blk-' + key, exp ? '1' : '0'); } catch (e) {}
	};
	var title = E('h3', {
		'role': 'button', 'tabindex': '0', 'aria-expanded': String(expanded),
		'style': 'display:flex;align-items:center;gap:.35em;cursor:pointer;user-select:none;margin-bottom:' + (expanded ? '.5em' : '0'),
		'click': toggle,
		'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); toggle(); } }
	}, [ chev, E('span', {}, titleText) ]);
	return E('div', { 'class': 'cbi-section tginfo', 'data-blk': key }, [ title, body ]);
}

function compass(deg) {
	var n = [ _('N'), _('NE'), _('E'), _('SE'), _('S'), _('SW'), _('W'), _('NW') ];
	return n[Math.round(((+deg % 360) + 360) % 360 / 45) % 8];
}

function hdopLevel(h) { return h <= 2 ? 3 : h <= 5 ? 2 : h <= 10 ? 1 : 0; }

var SRC_CHIP = { at: 'AT', nmea: 'NMEA', qmi: 'QMI', ugps: 'ugps', mm: 'MM', usbgps: 'USB', android: 'Android' };

return view.extend({
	load: function() {
		return fresh.check(40008, [ modemtabs, mutil ]).then(function() {
			return L.resolveDefault(uci.load('5gmodem'));
		});
	},

	render: function() {
		try { pageModemPath = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) { pageModemPath = ''; }
		var sid = (uci.sections('5gmodem', '5gmodem')[0] || {})['.name'];
		var cfg = function(k, d) { var v = sid ? uci.get('5gmodem', sid, k) : null; return (v === null || v === undefined || v === '') ? d : String(v); };
		// gps_tiles: a style key from MAPS, or an https address template of your own (the older form)
		var tilesCfg = cfg('gps_tiles', 'osm');
		var customMap = null;
		if (!mapByKey(tilesCfg)) {
			if (/^https:\/\/[^\s"'<>]+\{z\}[^\s"'<>]*$/.test(tilesCfg) && tilesCfg !== OSM_TILES) {
				customMap = { k: 'custom', n: (tilesCfg.match(/^https:\/\/([^\/:]+)/) || [ '', tilesCfg ])[1], u: tilesCfg, z: 19, inv: 1, a: '' };
			}
			tilesCfg = customMap ? 'custom' : 'osm';
		}
		var styleOf = function(k) { return (k === 'custom' && customMap) ? customMap : (mapByKey(k) || MAPS[0]); };
		// the style picked on the map is remembered in this browser and wins over the setting
		var mapKey = tilesCfg;
		try { var _mk = window.localStorage.getItem('5gmodem.gps.map'); if (_mk && (mapByKey(_mk) || (_mk === 'custom' && customMap))) { mapKey = _mk; } } catch (e) {}
		var mapAuto = cfg('gps_map_auto', '1') !== '0';
		var isPhone = !!(window.matchMedia && window.matchMedia(PHONE_MQ).matches);

		var st = { last: null, track: [], timer: null, ageTimer: null, busy: false, seenAt: 0,
			map: null, marker: null, ring: null, line: null, lf: null, follow: true, followBtn: null,
			mapWanted: mapAuto, mapState: '', mode: '' };

		/* ---------- header card ---------- */
		var hd = {};
		hd.chip = E('span', { 'class': 'tg-proto-badge', 'title': _('Source'), 'style': 'display:none' }, '');
		hd.pillM = E('span', { 'class': 'tg-gps-pill tg-gps-pillm off', 'style': 'visibility:hidden' }, [ E('i'), E('span', {}, '') ]);
		hd.ico = E('div', { 'class': 'tginfo-signal tg-gps-ico off' });
		hd.ico.innerHTML = svg('pin', 36);
		hd.badge = E('medium', {}, '-');
		hd.ico.appendChild(hd.badge);
		hd.reg = E('div', { 'class': 'tginfo-reg' }, '');
		hd.coordTxt = E('span', {}, '');
		hd.copy = E('button', { 'class': 'cbi-button tg-gps-copy', 'title': _('Copy coordinates'),
			'aria-label': _('Copy coordinates'), 'style': 'display:none' });
		hd.copy.innerHTML = svg('copy', 14);
		hd.coord = E('div', { 'class': 'tginfo-op tg-gps-coord none' }, [ hd.coordTxt, hd.copy ]);
		hd.loc = E('div', { 'class': 'tginfo-loc' }, '');
		hd.pill = E('span', { 'class': 'tg-gps-pill off', 'style': 'visibility:hidden' }, [ E('i'), E('span', {}, '') ]);
		hd.power = E('button', { 'class': 'cbi-button cbi-button-action tg-gps-pw', 'style': 'display:none' }, _('Turn GNSS on'));
		hd.powerM = E('button', { 'class': 'cbi-button cbi-button-action tg-gps-pw' }, _('Turn GNSS on'));
		hd.powerMRow = E('div', { 'class': 'tg-gps-headm', 'style': 'display:none' }, [ hd.powerM ]);
		var head = E('div', { 'class': 'cbi-section tg-pg-head tg-gps-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-gps-title' }, [ E('span', {}, _('GPS')), hd.chip, hd.pillM ]),
			E('div', { 'class': 'tginfo-general' }, [
				hd.ico,
				E('div', { 'class': 'tginfo-status' }, [ hd.reg, hd.coord, hd.loc ]),
				E('div', { 'class': 'tginfo-right' }, [ hd.pill, hd.power ])
			]),
			hd.powerMRow
		]);

		/* ---------- map ---------- */
		var mp = {};
		mp.lf = E('div', { 'class': 'tg-gps-lf', 'style': 'display:none' });
		mp.msgIco = E('span', { 'class': 'tg-gps-i' });
		mp.msgB = E('b', {}, '');
		mp.msgT = E('span', {}, '');
		mp.load = E('button', { 'class': 'cbi-button cbi-button-action', 'style': 'display:none' }, _('Load the map'));
		mp.msg = E('div', { 'class': 'tg-gps-mapmsg' }, E('div', {}, [ mp.msgIco, mp.msgB, mp.msgT, mp.load ]));
		mp.box = E('div', { 'class': 'tg-gps-map empty' }, [ mp.lf, mp.msg ]);
		mp.links = {};
		var linkEl = function(k, label) {
			mp.links[k] = E('a', { 'target': '_blank', 'rel': 'noopener noreferrer' }, label);
			return mp.links[k];
		};
		mp.open = E('div', { 'class': 'tg-gps-open dim' }, [
			E('span', {}, _('Open in')),
			linkEl('ya', _('Yandex Maps')), linkEl('g', _('Google Maps')), linkEl('2gis', _('2GIS')), linkEl('osm', 'OSM')
		]);
		mp.style = E('select', { 'class': 'cbi-input-select', 'aria-label': _('Map style'), 'change': function() { setMapStyle(mp.style.value, true); } },
			(customMap ? [ customMap ] : []).concat(MAPS).map(function(m) { return E('option', { 'value': m.k }, [ m.n ]); }));
		mp.style.value = mapKey;
		mp.styleBox = E('label', { 'class': 'tg-gps-style' }, [ E('span', {}, _('Map')), mp.style ]);
		var mapSec = E('div', { 'class': 'cbi-section tg-gps-mapsec' }, [ mp.box, E('div', { 'class': 'tg-gps-mapfoot' }, [ mp.open, mp.styleBox ]) ]);

		// Paints the chosen style: tile layer, projection, the dark-interface filter.
		function setMapStyle(k, remember) {
			var m = styleOf(k);
			mapKey = m.k;
			if (remember) { try { window.localStorage.setItem('5gmodem.gps.map', m.k); } catch (e) {} }
			mapSec.classList.toggle('tg-gps-dark', !!m.inv && isDarkUI(mapSec));
			if (!st.map || !st.lf) { return; }
			var lf = st.lf, c = st.map.getCenter(), z = Math.min(st.map.getZoom(), m.z);
			if (st.tiles) { st.map.removeLayer(st.tiles); st.tiles = null; }
			var crs = (m.crs === 3395) ? lf.CRS.EPSG3395 : lf.CRS.EPSG3857;
			var crsChanged = st.map.options.crs !== crs;
			st.map.options.crs = crs;
			st.map.setMaxZoom(m.z);
			st.tiles = lf.tileLayer(m.u, { 'maxZoom': m.z, 'maxNativeZoom': m.nz || m.z, 'attribution': m.a || '' }).addTo(st.map);
			st.tiles.bringToBack();
			// another projection: every layer is laid out again around the same point
			if (crsChanged) { if (st.map._resetView) { st.map._resetView(c, z); } else { st.map.setView(c, z, { 'animate': false }); } }
		}
		setMapStyle(mapKey, false);

		/* ---------- readings ---------- */
		var tl = {};
		var tile = function(key, name, foot, bar) {
			var t = { now: E('span', {}, '-'), unit: E('small', {}, '') };
			t.val = E('div', { 'class': 'tg-hist-now dash' }, [ t.now, ' ', t.unit ]);
			var kids = [ E('div', { 'class': 'tg-hist-h' }, E('span', { 'class': 'tg-hist-name' }, E('b', {}, name))), t.val ];
			if (bar) {
				t.fill = E('div', { 'class': 'tg-mbar-fill' });
				t.bar = E('div', { 'class': 'tg-mbar', 'style': 'visibility:hidden' }, E('div', { 'class': 'tg-mbar-t' }, t.fill));
				kids.push(t.bar);
			}
			t.foot = E('span', {}, foot || '');
			t.footRow = E('div', { 'class': 'tg-hist-f', 'style': foot ? '' : 'display:none' }, t.foot);
			kids.push(t.footRow);
			tl[key] = t;
			return E('div', { 'class': 'tg-hist-card tg-gps-tile' }, kids);
		};
		var arrow = E('span', { 'class': 'tg-gps-arrow', 'style': 'display:none' });
		arrow.innerHTML = svg('arrow', 14);
		var readings = E('div', { 'class': 'cbi-section tg-gps-read' }, [
			E('h3', {}, _('Readings')),
			E('div', { 'class': 'tg-gps-tilegrid' }, [
				tile('alt', _('Altitude'), _('above sea level')),
				tile('speed', _('Speed'), ''),
				tile('course', _('Course'), ''),
				tile('sats', _('Satellites'), _('used / in view'), true),
				tile('hdop', 'HDOP', _('lower is more accurate'), true),
				tile('utc', _('Time (UTC)'), '')
			])
		]);
		tl.course.val.insertBefore(arrow, tl.course.now);

		var setTile = function(t, v, unit, foot) {
			t.now.textContent = (v === null || v === undefined) ? '-' : v;
			t.unit.textContent = (v === null || v === undefined) ? '' : (unit || '');
			t.val.classList.toggle('dash', v === null || v === undefined);
			if (foot !== undefined) {
				t.foot.textContent = foot;
				t.footRow.style.display = foot ? '' : 'none';
			}
		};
		var setBar = function(t, pct, fill) {
			if (pct === null) { t.bar.style.visibility = 'hidden'; return; }
			t.bar.style.visibility = '';
			t.fill.style.width = Math.max(3, Math.min(100, pct)) + '%';
			t.fill.style.background = fill;
		};

		/* ---------- receiver ---------- */
		var rx = {};
		rx.src = E('span', {}, '-');
		rx.seg = {};
		var segBtn = function(m, label) {
			rx.seg[m] = E('button', { 'class': 'cbi-button', 'data-m': m, 'click': function() { st.mode = m; paintSeg(); } }, label);
			return rx.seg[m];
		};
		rx.modes = E('div', { 'style': 'display:none' }, [
			E('span', { 'class': 'lbl' }, _('Start mode')),
			E('div', { 'class': 'tg-gps-seg' }, [ segBtn('hot', _('Hot')), segBtn('warm', _('Warm')), segBtn('cold', _('Cold')) ]),
			E('div', { 'class': 'tg-gps-rxnote', 'style': 'margin-top:6px' }, _('A cold start takes several minutes under open sky.'))
		]);
		rx.restart = E('button', { 'class': 'cbi-button', 'style': 'display:none' }, _('Restart the search'));
		rx.power = E('button', { 'class': 'cbi-button tg-gps-pw', 'style': 'display:none' }, _('Turn GNSS on'));
		rx.rebootNote = E('div', { 'class': 'tg-gps-rxnote', 'style': 'display:none' },
			_('On this modem the GNSS setting is stored in the modem and applied by its restart: the connection drops for about a minute.'));
		// Telit: the connector the receiver listens on (gps.sh antport); hidden for other modems
		var ANT_LABEL = {
			'2': _('GNSS connector, passive antenna'),
			'3': _('GNSS connector, active antenna (power on the connector)'),
			'4': _('GNSS connector, active antenna, high gain'),
			'1': _('AUX (diversity) connector, passive antenna')
		};
		rx.antSel = E('select', { 'class': 'cbi-input-select', 'change': function() {
			var v = rx.antSel.value;
			act([ 'antport', v ], _('GNSS antenna connector changed. The search starts over.')).then(loadAnt);
		} });
		rx.ant = E('div', { 'style': 'display:none' }, [
			E('span', { 'class': 'lbl' }, _('GNSS antenna')),
			rx.antSel,
			E('div', { 'class': 'tg-gps-rxnote', 'style': 'margin-top:6px' },
				_('The connector the receiver listens on, stored in the modem. No satellites at all usually means the antenna sits on the other connector.'))
		]);
		function loadAnt() {
			var forPath = pageModemPath;
			return run([ 'antport' ]).then(function(a) {
				if (forPath !== pageModemPath) { return; }
				if (!a || +a.supported !== 1) { rx.ant.style.display = 'none'; return; }
				while (rx.antSel.firstChild) { rx.antSel.removeChild(rx.antSel.firstChild); }
				[ '2', '3', '4', '1' ].forEach(function(k) {
					if (+k > +(a.max || 3)) { return; }
					rx.antSel.appendChild(E('option', { 'value': k }, [ ANT_LABEL[k] ]));
				});
				if (String(a.value) === '0') { rx.antSel.insertBefore(E('option', { 'value': '0', 'disabled': '' }, [ _('off') ]), rx.antSel.firstChild); }
				rx.antSel.value = String(a.value);
				rx.ant.style.display = '';
			});
		}
		var rxManaged = collapsibleSection('gpsrx', _('Receiver'), [
			E('div', { 'class': 'tg-gps-rx' }, [
				E('div', {}, [ E('span', { 'class': 'lbl' }, _('Source')), rx.src ]),
				rx.modes,
				rx.ant,
				E('div', { 'class': 'tg-gps-rxact' }, [ rx.restart, rx.power ]),
				rx.rebootNote
			])
		], !isPhone);
		rx.note = E('div', { 'class': 'tg-gps-rxnote' }, '');
		var rxPassive = E('div', { 'class': 'cbi-section', 'style': 'display:none' }, [ E('h3', {}, _('Receiver')), rx.note ]);

		function paintSeg() {
			Object.keys(rx.seg).forEach(function(m) { rx.seg[m].classList.toggle('tg-current', m === st.mode); });
		}

		var side = E('div', { 'class': 'tg-gps-side' }, [ readings, rxManaged, rxPassive ]);
		// drawn at once with dashes and placeholders (as the Network page); hidden only when the
		// first answer says the modem has no receiver
		var main = E('div', {}, [ E('div', { 'class': 'tg-gps-grid' }, [ mapSec, side ]) ]);

		/* ---------- unsupported ---------- */
		var unsIco = E('div', { 'class': 'tginfo-signal tg-gps-ico off' });
		unsIco.innerHTML = svg('pin', 36);
		unsIco.appendChild(E('medium', {}, _('no')));
		var unsup = E('div', { 'class': 'cbi-section', 'style': 'display:none' }, [
			E('h3', { 'class': 'tg-pg-title tg-gps-title' }, _('GPS')),
			E('div', { 'class': 'tginfo-general' }, [ unsIco, E('div', { 'style': 'min-width:0;flex:1 1 0' }, [
				E('b', {}, _('This modem has no GNSS receiver that the app can read')),
				E('div', { 'class': 'cbi-section-descr', 'style': 'margin-top:4px' },
					_('No GNSS receiver was found on this modem. Supported: Qualcomm modems with the QMI location service (also in MBIM mode), Quectel, SIMCom, Telit, MeiG, Fibocom (FM350 and Qualcomm-based), Foxconn/Dell (T77W968, T99W175, T99W373) and Sierra modems with a GNSS port. A receiver handled by ugps is shown too.'))
			]) ])
		]);

		/* ---------- actions ---------- */
		var powerBtns = [ hd.power, hd.powerM, rx.power ];
		function setBusy(on) {
			st.busy = on;
			powerBtns.concat([ rx.restart, rx.antSel ]).forEach(function(b) { b.disabled = on; });
		}

		function act(a, okMsg) {
			setBusy(true);
			return run(a).then(function(r) {
				if (r && r.ok) {
					if (okMsg) { ui.addNotification(null, E('p', okMsg), 'info'); }
				} else {
					ui.addNotification(null, E('p', _('The modem did not accept the command.') + (r && r.msg ? ' (' + r.msg + ')' : '')), 'warning');
				}
			}).finally(function() { setBusy(false); tick(); });
		}

		function confirmReboot(on) {
			return new Promise(function(resolve) {
				ui.showModal(on ? _('Turn GNSS on') : _('Turn GNSS off'), [
					E('p', {}, _('On this modem the GNSS setting is stored in the modem and applied by its restart: the connection drops for about a minute.')),
					on ? '' : E('p', {}, _('Field reports: on some firmware the modem kept restarting in a loop after GNSS was turned off while it sat in a router. Turn it off only if you can reach the modem from a computer.')),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); resolve(false); } }, _('Cancel')),
						' ',
						E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { ui.hideModal(); resolve(true); } }, _('Restart the modem'))
					])
				]);
			});
		}

		powerBtns.forEach(function(b) {
			b.addEventListener('click', function() {
				var j = st.last || {};
				var on = j.state !== 'on';
				var go = (+j.reboot === 1) ? confirmReboot(on) : Promise.resolve(true);
				go.then(function(yes) {
					if (!yes) { return; }
					act([ on ? 'on' : 'off' ], (+j.reboot === 1) ? _('The modem restarts to apply the setting.') : null);
				});
			});
		});
		rx.restart.addEventListener('click', function() {
			if (!st.mode) { return; }
			act([ 'start', st.mode ], _('The receiver is searching for satellites again. A cold start can take several minutes under open sky.'));
		});
		hd.copy.addEventListener('click', function() {
			var j = st.last || {};
			if (j.lat === null || j.lat === undefined) { return; }
			var t = (+j.lat).toFixed(6) + ', ' + (+j.lon).toFixed(6);
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(t).then(function() {
					ui.addNotification(null, E('p', _('Copied: %s').format(t)), 'info');
				}, function() { window.prompt('', t); });
			} else { window.prompt('', t); }
		});
		mp.load.addEventListener('click', function() { st.mapWanted = true; openMap(); });

		/* ---------- map logic ---------- */
		function mapMsg(kind) {
			if (st.mapState === kind) { return; }
			st.mapState = kind;
			var m = {
				ask: [ 'sat', _('Asking the modem…'), '' ],
				wait: [ 'sat', _('Waiting for the first fix'), _('The map opens at the modem position as soon as coordinates appear.') ],
				off: [ 'sat', _('Receiver is off'), _('The map appears after the receiver is turned on and gets a fix.') ],
				manual: [ 'eye', _('The map is not loaded'), _('The map service learns the area where the router is.') ],
				loading: [ 'sat', _('Loading the map…'), '' ],
				fail: [ 'eye', _('Could not load the map component.'), '' ]
			}[kind];
			mp.msg.style.display = m ? '' : 'none';
			mp.box.classList.toggle('empty', !!m);
			mp.load.style.display = (kind === 'manual' || kind === 'fail') ? '' : 'none';
			if (!m) { return; }
			mp.msgIco.innerHTML = svg(m[0], 28);
			mp.msgB.textContent = m[1];
			mp.msgT.textContent = m[2];
			mp.msgT.style.display = m[2] ? '' : 'none';
		}

		function ctlButton(lf, parent, name, title, fn) {
			var a = lf.DomUtil.create('a', '', parent);
			a.href = '#';
			a.title = title;
			a.setAttribute('role', 'button');
			a.setAttribute('aria-label', title);
			a.innerHTML = svg(name, 18);
			lf.DomEvent.on(a, 'click', function(ev) { lf.DomEvent.preventDefault(ev); fn(); });
			return a;
		}

		function setFollow(on) {
			st.follow = on;
			if (st.followBtn) {
				st.followBtn.classList.toggle('on', on);
				st.followBtn.setAttribute('aria-pressed', String(on));
			}
			if (on) { drawMap(); }
		}

		function openMap() {
			if (st.map || st.mapState === 'loading') { return; }
			mapMsg('loading');
			return loadLeaflet().then(function(lf) {
				st.lf = lf;
				mp.lf.style.display = '';
				var j = st.last || {};
				var has = j.lat !== null && j.lat !== undefined && j.lat !== '';
				st.map = lf.map(mp.lf, { 'zoomControl': true, 'crs': styleOf(mapKey).crs === 3395 ? lf.CRS.EPSG3395 : lf.CRS.EPSG3857 })
					.setView(has ? [ +j.lat, +j.lon ] : [ 20, 0 ], has ? 16 : 2);
				st.centered = has;
				// no "Leaflet" link and flag in the corner; the tile provider credit stays
				if (st.map.attributionControl) { st.map.attributionControl.setPrefix(false); }
				setMapStyle(mapKey, false);
				st.line = lf.polyline(st.track, { 'color': '#1e88e5', 'weight': 3 }).addTo(st.map);
				var Ctl = lf.Control.extend({
					options: { position: 'topright' },
					onAdd: function() {
						var div = lf.DomUtil.create('div', 'leaflet-bar tg-gps-ctl');
						st.followBtn = ctlButton(lf, div, 'center', _('Keep the position in the center'), function() { setFollow(!st.follow); });
						ctlButton(lf, div, 'erase', _('Clear track'), function() {
							var last = st.track.length ? st.track[st.track.length - 1] : null;
							st.track = last ? [ last ] : [];
							if (st.line) { st.line.setLatLngs(st.track); }
						});
						lf.DomEvent.disableClickPropagation(div);
						return div;
					}
				});
				st.map.addControl(new Ctl());
				setFollow(st.follow);
				st.map.on('dragstart', function() { setFollow(false); });
				if (window.ResizeObserver) {
					new ResizeObserver(function() { if (st.map) { st.map.invalidateSize(); } }).observe(mp.box);
				}
				mapMsg('');
				drawMap();
			}).catch(function() {
				st.map = null;
				mp.lf.style.display = 'none';
				mapMsg('fail');
			});
		}

		function drawMap() {
			var j = st.last || {};
			if (!st.map || j.lat === null || j.lat === undefined || !(+j.fix > 0)) { return; }
			var lf = st.lf, ll = [ +j.lat, +j.lon ];
			var h = num(j.hdop, 1);
			if (h !== null && +h > 0) {
				if (!st.ring) {
					st.ring = lf.circle(ll, { 'radius': +h * 5, 'color': '#1e88e5', 'weight': 1, 'opacity': 0.35,
						'fillColor': '#1e88e5', 'fillOpacity': 0.13, 'interactive': false }).addTo(st.map);
				} else { st.ring.setLatLng(ll); st.ring.setRadius(+h * 5); }
			} else if (st.ring) { st.map.removeLayer(st.ring); st.ring = null; }
			if (st.line) { st.line.setLatLngs(st.track); }
			if (!st.marker) {
				st.marker = lf.circleMarker(ll, { 'radius': 8, 'color': '#fff', 'weight': 2, 'fillColor': '#e53935', 'fillOpacity': 1 }).addTo(st.map);
			} else { st.marker.setLatLng(ll); st.marker.bringToFront(); }
			// opened before the fix at the world view: the first fix zooms in once
			if (!st.centered) { st.centered = true; st.map.setView(ll, 16); }
			else if (st.follow) { st.map.panTo(ll); }
		}

		/* ---------- rendering ---------- */
		function setPill(el, cls, text) {
			el.className = el.className.replace(/\b(ok|search|off)\b/g, '').trim() + ' ' + cls;
			el.lastChild.textContent = text;
			el.style.visibility = '';
		}

		function ageText() {
			var j = st.last || {};
			if (!(+j.fix > 0) || j.lat === null || j.lat === undefined) { return null; }
			var now = Date.now() / 1000, age = now - (+j.ts || 0);
			// Router and browser clocks can differ: fall back to the time the answer arrived.
			if (!(+j.ts > 0) || age < -5 || age > 86400) { age = now - st.seenAt / 1000; }
			return _('updated %s s ago').format(Math.max(0, Math.round(age)));
		}

		function paintAge() {
			var t = ageText();
			if (t !== null) { hd.loc.textContent = t; }
		}

		function show(j) {
			st.last = j;
			st.seenAt = Date.now();
			var src = j.source || '';
			var sup = +j.supported === 1 || src === 'ugps' || src === 'usbgps';
			unsup.style.display = sup ? 'none' : '';
			head.style.display = sup ? '' : 'none';
			main.style.display = sup ? '' : 'none';
			gpsSet.style.display = sup ? '' : 'none';
			if (!sup) { return; }

			mapSec.classList.toggle('tg-gps-dark', !!styleOf(mapKey).inv && isDarkUI(mapSec));
			var passive = src === 'ugps' || src === 'usbgps';
			var managed = !passive && +j.supported === 1;
			// asked once per modem, and only where the command exists
			var antKey = (managed && j.family === 'telit') ? ('t:' + pageModemPath) : '';
			if (antKey !== st.antKey) { st.antKey = antKey; if (antKey) { loadAnt(); } else { rx.ant.style.display = 'none'; } }
			var fixed = +j.fix > 0 && j.lat !== null && j.lat !== undefined && j.lat !== '';
			var off = !passive && (j.state === 'off' || j.state === 'locked');
			var su = num(j.sats, 0), iv = num(j.inview, 0);

			/* header */
			hd.chip.textContent = SRC_CHIP[src] || src;
			hd.chip.style.display = SRC_CHIP[src] || src ? '' : 'none';
			var stCls = fixed ? 'ok' : off ? 'off' : 'search';
			hd.ico.className = 'tginfo-signal tg-gps-ico ' + (fixed ? '' : stCls);
			var pillTxt = fixed ? _('Fix %s').format((+j.fix >= 3) ? _('3D') : _('2D')) : off ? _('Receiver is off') : _('Searching for satellites');
			setPill(hd.pill, stCls, pillTxt);
			setPill(hd.pillM, stCls, pillTxt);
			if (fixed) {
				hd.badge.textContent = (+j.fix >= 3) ? _('3D') : _('2D');
				hd.reg.textContent = _('Latitude, longitude');
				hd.coordTxt.textContent = num(j.lat, 6) + ', ' + num(j.lon, 6);
				hd.coord.classList.remove('none');
				hd.copy.style.display = '';
				paintAge();
			} else {
				hd.copy.style.display = 'none';
				hd.coord.classList.add('none');
				if (off) {
					hd.badge.textContent = _('off');
					hd.reg.textContent = _('GNSS receiver');
					hd.coordTxt.textContent = _('No coordinates');
					hd.loc.textContent = j.state === 'locked' ? _('blocked in the modem (GTGPSSWITCH=0)') : _('Turn the receiver on to get coordinates.');
				} else {
					hd.badge.textContent = (su !== null && iv !== null) ? (su + '/' + iv) : '-';
					hd.reg.textContent = (su !== null && iv !== null) ? _('Satellites in view: %s, used: %s').format(iv, su) : _('GNSS receiver');
					hd.coordTxt.textContent = _('Coordinates are not determined yet');
					hd.loc.textContent = _('Under open sky the first fix takes from 30 s to several minutes.');
				}
			}
			var showPower = managed && off;
			hd.power.style.display = showPower ? '' : 'none';
			hd.powerMRow.style.display = showPower ? '' : 'none';

			/* map */
			['ya', 'g', '2gis', 'osm'].forEach(function(k) {
				var a = mp.links[k];
				if (!fixed) { a.removeAttribute('href'); return; }
				var la = (+j.lat).toFixed(6), lo = (+j.lon).toFixed(6);
				a.href = {
					ya: 'https://yandex.ru/maps/?pt=' + lo + ',' + la + '&z=16&l=map',
					g: 'https://www.google.com/maps?q=' + la + ',' + lo,
					'2gis': 'https://2gis.ru/geo/' + lo + ',' + la,
					osm: 'https://www.openstreetmap.org/?mlat=' + la + '&mlon=' + lo + '#map=16/' + la + '/' + lo
				}[k];
			});
			mp.open.classList.toggle('dim', !fixed);
			if (fixed) {
				var p = [ +j.lat, +j.lon ], prev = st.track[st.track.length - 1];
				if (!prev || prev[0] !== p[0] || prev[1] !== p[1]) {
					st.track.push(p);
					if (st.track.length > TRACK_MAX) { st.track.splice(0, st.track.length - TRACK_MAX); }
				}
			}
			// "Load the map automatically" opens it with the page (the world view tells the tile
			// server nothing); otherwise no tile requests until the button. After a failed load
			// only the button retries.
			if (!st.map && st.mapState !== 'loading' && st.mapState !== 'fail') {
				if (st.mapWanted) { openMap(); }
				else { mapMsg(fixed ? 'manual' : off ? 'off' : 'wait'); }
			}
			drawMap();

			/* readings */
			setTile(tl.alt, fixed ? num(j.alt, 0) : null, unitOf(_('%s m')));
			setTile(tl.speed, fixed ? num(j.speed, 1) : null, unitOf(_('%s km/h')));
			var crs = fixed ? num(j.course, 0) : null;
			setTile(tl.course, crs !== null ? crs + '°' : null, crs !== null ? compass(crs) : '');
			arrow.style.display = crs !== null ? '' : 'none';
			if (crs !== null) { arrow.style.transform = 'rotate(' + crs + 'deg)'; }
			setTile(tl.sats, (off || su === null) ? null : su, iv !== null ? '/ ' + iv : '');
			setBar(tl.sats, (off || su === null || !(+iv > 0)) ? null : 100 * su / iv, mutil.QUAL_GRAD[fixed ? 3 : 1] || '');
			var h = fixed ? num(j.hdop, 1) : null, lvl = h !== null ? hdopLevel(+h) : null;
			setTile(tl.hdop, h, lvl !== null ? [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][lvl] : '');
			setBar(tl.hdop, h === null ? null : 100 * (1 - Math.log(Math.max(+h, 1)) / Math.log(20)), mutil.QUAL_GRAD[lvl] || '');
			var um = (!off && j.utc) ? String(j.utc).match(/^(\d{4}-\d\d-\d\d)T(\d\d:\d\d:\d\d)/) : null;
			setTile(tl.utc, um ? um[2] : null, '', um ? um[1] : '');

			/* receiver */
			rxManaged.style.display = passive ? 'none' : '';
			rxPassive.style.display = passive ? '' : 'none';
			if (passive) {
				rx.note.textContent = src === 'ugps'
					? _('The receiver is managed by the ugps service; this page only shows its data.')
					: _('The external USB receiver on %s needs no control; this page only shows its data.').format(j.port || '-');
				return;
			}
			rx.src.textContent = src === 'nmea' ? _('NMEA port %s').format(j.port || '') : src === 'at' ? _('AT commands')
				: src === 'qmi' ? _('QMI location service') : src === 'mm' ? 'ModemManager' : src === 'android' ? _('Phone location service (Android)') : (src || '-');
			var modes = String(j.modes || '').split(' ').filter(Boolean);
			Object.keys(rx.seg).forEach(function(m) { rx.seg[m].style.display = modes.indexOf(m) < 0 ? 'none' : ''; });
			if (modes.indexOf(st.mode) < 0) { st.mode = modes.indexOf('hot') >= 0 ? 'hot' : (modes[0] || ''); }
			paintSeg();
			var showModes = managed && modes.length > 0 && j.state === 'on';
			rx.modes.style.display = showModes ? '' : 'none';
			rx.restart.style.display = showModes ? '' : 'none';
			rx.power.style.display = managed ? '' : 'none';
			rx.power.textContent = j.state === 'on' ? _('Turn GNSS off') : _('Turn GNSS on');
			rx.power.className = 'cbi-button tg-gps-pw ' + (j.state === 'on' ? 'cbi-button-negative' : 'cbi-button-action');
			rx.rebootNote.style.display = (managed && +j.reboot === 1) ? '' : 'none';
		}

		function tick() {
			if (st.timer) { window.clearTimeout(st.timer); st.timer = null; }
			if (!document.body.contains(root)) {
				if (st.ageTimer) { window.clearInterval(st.ageTimer); st.ageTimer = null; }
				return;
			}
			var next = function() { st.timer = window.setTimeout(tick, POLL_MS); };
			if (document.hidden || st.busy) { next(); return; }
			// an answer for the modem shown before an in-place switch must not paint over the new one
			var forPath = pageModemPath;
			run([ 'status' ]).then(function(j) { if (forPath === pageModemPath) { return show(j); } }).finally(next);
		}

		window.__5gmInPlaceSwitch = function(path) {
			pageModemPath = String(path || '');
			st.track = []; st.last = null; st.centered = false;
			if (st.map) {
				if (st.marker) { st.map.removeLayer(st.marker); st.marker = null; }
				if (st.ring) { st.map.removeLayer(st.ring); st.ring = null; }
			}
			if (st.line) { st.line.setLatLngs([]); }
			tick();
		};

		/* ---------- settings (moved here from the Settings page) ---------- */
		var gs = {};
		var gsVal = function(k) { return cfg(k, ''); };
		gs.time = E('input', { 'type': 'checkbox', 'id': 'gps-set-time' });
		gs.time.checked = gsVal('gps_time') === '1';
		var gsText = function(k, ph) {
			return E('input', { 'type': 'text', 'class': 'cbi-input-text', 'value': gsVal(k), 'placeholder': ph || '' });
		};
		gs.url = gsText('gps_traccar_url', 'http://192.168.1.10:5055');
		gs.id = gsText('gps_traccar_id', '');
		gs.iv = gsText('gps_traccar_interval', '60');
		gs.port = gsText('gps_nmea_port', '10110');
		var gsRow = function(title, widget, descr) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ title ]),
				E('div', { 'class': 'cbi-value-field' }, [ widget, E('div', { 'class': 'cbi-value-description' }, [ descr ]) ])
			]);
		};
		gs.rowId = gsRow(_('Traccar device ID'), gs.id, _('The identifier of this device on the Traccar server.'));
		gs.rowIv = gsRow(_('Traccar interval'), gs.iv, _('Seconds between positions. The shortest is 30.'));
		var gsDeps = function() {
			var on = gs.url.value.trim() !== '';
			gs.rowId.style.display = on ? '' : 'none';
			gs.rowIv.style.display = on ? '' : 'none';
		};
		gs.url.addEventListener('input', gsDeps);
		gsDeps();
		// one Save for the whole block, at the bottom right
		var gsSave = function() {
			var url = gs.url.value.trim(), id = gs.id.value.trim(), iv = gs.iv.value.trim(), port = gs.port.value.trim();
			var bad = null;
			if (url && !/^https?:\/\/([A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\])(:[0-9]{1,5})?(\/[A-Za-z0-9._~\/-]*)?$/.test(url)) {
				bad = _('Traccar server') + ': ' + _('An http:// or https:// address without a query');
			} else if (url && id && !/^[A-Za-z0-9._-]{1,64}$/.test(id)) {
				bad = _('Traccar device ID') + ': ' + _('Letters, digits, dot, dash and underscore, up to 64');
			} else if (url && iv && !(/^[0-9]+$/.test(iv) && +iv >= 30 && +iv <= 86400)) {
				bad = _('Traccar interval') + ': ' + _('Seconds between positions. The shortest is 30.');
			} else if (port && !(/^[0-9]+$/.test(port) && +port >= 1 && +port <= 65535)) {
				bad = _('NMEA over the network') + ': 1-65535';
			}
			if (bad) { ui.addNotification(null, E('p', {}, [ bad ]), 'warning'); return Promise.resolve(); }
			if (!sid) { return Promise.resolve(); }
			var put = function(k, v) { if (v === '') { uci.unset('5gmodem', sid, k); } else { uci.set('5gmodem', sid, k, v); } };
			uci.set('5gmodem', sid, 'gps_time', gs.time.checked ? '1' : '0');
			put('gps_traccar_url', url);
			// switched off: the ID and the interval go with it
			put('gps_traccar_id', url ? id : '');
			put('gps_traccar_interval', url ? iv : '');
			put('gps_nmea_port', port);
			return uci.save().then(function() { return uciCommit('5gmodem'); }).then(function() {
				ui.addNotification(null, E('p', {}, [ _('Saved and applied.') ]), 'info');
			}).catch(function() {
				ui.addNotification(null, E('p', {}, [ _('Could not save the settings.') ]), 'error');
			});
		};
		var gpsSet = collapsibleSection('gpsset', _('Settings'), [
			E('div', { 'class': 'tg-gps-set' }, [
				gsRow(_('Clock from GNSS'), gs.time, _('Set the router clock from the GNSS receiver when there is no NTP sync, for example with no internet after a boot. Never changes a clock that NTP has synced.')),
				gsRow(_('Traccar server'), gs.url, _('Send the position to a Traccar server over the OsmAnd protocol, for example http://192.168.1.10:5055. Empty - off. The position leaves the router: everyone with access to that server sees where the router is. Nothing is sent without a fix.')),
				gs.rowId, gs.rowIv,
				gsRow(_('NMEA over the network'), gs.port, _('TCP port that streams the position as NMEA (GGA and RMC once a second) to gpsd, navigation apps or a car head unit, for example 10110. Empty - off. It listens on the LAN address only, without a password. Needs the socat or ncat package.')),
				E('div', { 'class': 'tg-gps-setact' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, gsSave) }, [ _('Save') ])
				])
			])
		], false);
		gpsSet.classList.add('tg-gps-setsec');

		var root = E('div', { 'class': 'tg-gps' }, [ head, main, unsup, gpsSet ]);
		hd.reg.textContent = _('Asking the modem…');
		hd.coordTxt.textContent = '-';

		st.ageTimer = window.setInterval(function() {
			if (!document.hidden && document.body.contains(root)) { paintAge(); }
		}, 1000);
		modemtabs.attach();
		if (st.mapWanted) { window.setTimeout(openMap, 0); } else { mapMsg('ask'); }
		window.setTimeout(tick, 0);
		return root;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
