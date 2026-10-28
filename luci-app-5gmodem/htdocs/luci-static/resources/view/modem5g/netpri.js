'use strict';
'require baseclass';
'require view.modem5g.mutil as mutil';
'require view.modem5g.extip as extip';
'require view.modem5g.healthform as healthform';
'require fs';
'require ui';
'require uci';
'require poll';

var BIN = '/usr/share/5gmodem/netpri.sh';

var _widgets = { netpri: true, status: true, services: true, speedtest: true };
var _netpriRank = '';
var _widgetOrder = [];
var _pingWidgets = [];
var _svcWidgets = [];
function loadWidgetFlags() {
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		function on(k) { return uci.get('5gmodem', '@5gmodem[0]', k) !== '0'; }
		_widgets.netpri    = on('widget_netpri');
		_widgets.status    = on('widget_status');
		_widgets.services  = on('widget_services');
		_widgets.speedtest = on('widget_speedtest');
		var _nrv = uci.get('5gmodem', '@5gmodem[0]', 'netpri_rank');
		_netpriRank = (_nrv === '1') ? 'num' : (_nrv === 'icon') ? 'icon' : '';
		_widgetOrder = String(uci.get('5gmodem', '@5gmodem[0]', 'widget_order') || '').split(/\s+/).filter(Boolean);
		_pingWidgets = (uci.sections('5gmodem', 'pingwidget') || []).map(function(s) {
			return { host: String(s.host || '').trim(), mode: s.mode || 'click' };
		}).filter(function(w) { return !!w.host; });
		_svcWidgets = (uci.sections('5gmodem', 'svcwidget') || []).map(function(s) {
			return String(s.service || '').trim();
		}).filter(function(v) { return !!v; });
	});
}
function effectiveSvcs() { return _svcWidgets; }

var _pingState = {};
try { _pingState = JSON.parse(window.localStorage.getItem('netpri-pingstate') || '{}') || {}; } catch (e) {}
var _svcState = {};

var YT_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true">' +
	'<rect x="2" y="4.5" width="20" height="15" rx="4.2" fill="#FF0000"/>' +
	'<path d="M10 8.5l6 3.5-6 3.5z" fill="#fff"/></svg>';
var PING_PRESETS = {
	'youtube.com':    { name: 'YouTube',    svg: YT_ICON },
	'api.telegram.org': { name: 'Telegram', img: 'tg.svg', plain: true },
	'github.com':     { name: 'GitHub',     img: 'github.svg' },
	'google.com':     { name: 'Google',     color: '#4285F4', glyph: 'G' },
	'cloudflare.com': { name: 'Cloudflare', color: '#F38020', glyph: '☁' },
	'yandex.ru':      { name: 'Yandex',     color: '#FF3B30', glyph: 'Я' }
};
function pingInfo(host) {
	host = String(host || 'youtube.com').trim();
	var p = PING_PRESETS[host.toLowerCase()];
	if (p) { return { host: host, name: p.name, color: p.color, glyph: p.glyph, svg: p.svg, img: p.img, plain: p.plain, custom: false }; }
	return { host: host, name: host, color: null, glyph: '⚡', custom: true };
}

var SPEEDBIN = '/usr/share/5gmodem/speedtest.sh';

var _st = { phase: 'idle', service: '', down: null, up: null, ip: '', cc: '', live: 0, liveUp: 0, secs: 15, phaseStart: 0, hasData: false, elapsed: null, elapsedAt: 0 };

var _stProgTimer = null;
function setStProgress() {
	var cards = document.querySelectorAll('.netpri-st');
	if (!cards.length) { return; }
	if (_st.phase !== 'running' || !_st.secs || !_st.hasData || _st.elapsed == null) {
		cards.forEach(function(c) { c.style.removeProperty('--st-p'); }); return;
	}
	var ms = _st.elapsed * 1000 + (Date.now() - _st.elapsedAt);
	var pct = ms / (_st.secs * 1000) * 100;
	if (pct < 0) { pct = 0; } if (pct > 100) { pct = 100; }
	cards.forEach(function(c) { c.style.setProperty('--st-p', pct.toFixed(1) + '%'); });
}
function stProgStart() { if (!_stProgTimer) { _stProgTimer = window.setInterval(setStProgress, 200); } }
function stProgStop() { if (_stProgTimer) { window.clearInterval(_stProgTimer); _stProgTimer = null; } setStProgress(); }

function stArrow(name) {
	var dir = (name === 'cdown') ? ' st-arrow-dl' : (name === 'cup') ? ' st-arrow-ul' : '';
	return E('img', { 'class': 'netpri-st-arrow' + dir, 'src': mutil.icon('icons/5gmodem/' + name + '.svg'), 'width': 11, 'height': 11, 'alt': '' });
}

function stSpeedContent() {
	var sep = function() { return E('span', { 'style': 'opacity:.4; margin:0 .35em;' }, '|'); };
	var unit = function() { return E('span', { 'class': 'netpri-st-unit' }, _('Mbps')); };
	var num = function(v, dim, live) {
		var cls = 'netpri-st-num' + (dim ? ' dim' : '') + (live ? ' netpri-st-live' : '');
		var txt = live ? (typeof _liveDisplay === 'number' ? _liveDisplay : 0).toFixed(1)
		               : (v != null ? String(v) : '0.0');
		return E('span', { 'class': cls }, txt);
	};
	var pair = function(node, arrow) {
		return E('span', { 'style': 'display:inline-flex; align-items:center; gap:.15em' }, [ node, stArrow(arrow) ]);
	};

	if (_st.phase === 'fail') { return [ E('span', {}, _('Test failed')) ]; }

	var running = (_st.phase === 'running');
	var dlDim, dlNode, ulDim, ulNode;
	if (running && !_st.upPhase) {
		dlNode = num(null, false, true);
		ulNode = num(_st.up, true, false);
	} else if (running && _st.upPhase) {
		dlNode = num(_st.down, _st.down == null, false);
		ulNode = num(null, false, true);
	} else if (_st.phase === 'done') {
		dlNode = num(_st.down, _st.down == null, false);
		ulNode = num(_st.up, _st.up == null, false);
		if (_st.up == null && _st.upErr) {
			ulNode.textContent = '\u2014';
			ulNode.setAttribute('data-tooltip', /^http-/.test(_st.upErr)
				? _('Upload was not measured: the endpoint refused the data (HTTP %s). Pick another upload endpoint in the settings.').format(_st.upErr.substring(5))
				: _('Upload was not measured: the endpoint did not answer. Pick another upload endpoint in the settings.'));
		}
	} else {
		dlNode = num(null, true, false);
		ulNode = num(null, true, false);
	}
	return [ pair(dlNode, 'cdown'), sep(), pair(ulNode, 'cup'), unit() ];
}

function stServiceLabel(s) {
	if (s == 'Internetometer' || s == 'Интернетометр')
		return _('Internetometer');
	return s || _('Speed test');
}

function stCardInner() {
	return [
		E('span', { 'class': 'netpri-sub' }, stServiceLabel(_st.service)),
		E('span', { 'class': 'netpri-name netpri-st-speed' }, stSpeedContent()),
		_st.ip ? E('span', {
			'class': 'netpri-ip',
			'style': _st.ipLocal ? 'opacity:.55;font-style:italic' : null,
			'data-tooltip': _st.ipLocal ? _('Modem address, not external') : null
		}, (function() {
			if (_st.ipLocal) { return _st.ip; }
			var fl = mutil.flagEmoji(_st.cc);
			return fl ? (fl + ' ' + _st.ip) : _st.ip;
		})())
		       : E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***')
	];
}

function stCard() {
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-st',
		'data-wkey': 'speed',
		'data-tooltip': _('Measure the real download/upload speed over the modem - a quick way to see whether carrier aggregation is actually working'),
		'click': function() { if (_npSwallowClick()) { return; } runSpeedtest(); }
	}, stCardInner());
}

function patchStCard() {
	document.querySelectorAll('.netpri-st').forEach(function(card) {
		while (card.firstChild) { card.removeChild(card.firstChild); }
		stCardInner().forEach(function(n) { card.appendChild(n); });
	});
}

var _liveDisplay = 0;
var _liveRaf = null;
function animateLive(target) {
	var els = document.querySelectorAll('.netpri-st .netpri-st-live');
	if (!els.length) { _liveDisplay = target; return; }
	var from = _liveDisplay, to = (target != null ? target : 0), t0 = null, dur = 900;
	if (_liveRaf) { window.cancelAnimationFrame(_liveRaf); }
	var step = function(ts) {
		if (t0 === null) { t0 = ts; }
		var p = Math.min((ts - t0) / dur, 1);
		var v = from + (to - from) * p;
		els.forEach(function(el) { el.textContent = v.toFixed(1); });
		_liveDisplay = v;
		if (p < 1) { _liveRaf = window.requestAnimationFrame(step); }
		else { _liveDisplay = to; _liveRaf = null; }
	};
	_liveRaf = window.requestAnimationFrame(step);
}

var _renderedKey = '';
var _renderedPhase = '';
function refreshStCard() {
	var key = _st.phase + (_st.upPhase ? ':up' : '');
	var full = key + '|' + (_st.ip || '');
	if (full !== _renderedKey) {
		patchStCard();
		_renderedKey = full;
		if (key !== _renderedPhase) {
			if (_st.phase === 'running') { _liveDisplay = 0; _st.phaseStart = Date.now(); }
			_renderedPhase = key;
		}
	}
	document.querySelectorAll('.netpri-st').forEach(function(card) {
		card.classList.toggle('st-dl', _st.phase === 'running' && !_st.upPhase);
		card.classList.toggle('st-ul', _st.phase === 'running' && !!_st.upPhase);
		card.classList.toggle('st-wait', _st.phase === 'running' && !_st.hasData);
	});
	if (_st.phase === 'running') { animateLive(_st.upPhase ? (_st.liveUp || 0) : (_st.live || 0)); }
	setStProgress();
}

function runSpeedtest() {
	if (_st.phase === 'running') {
		_st.stopping = true;
		fs.exec(SPEEDBIN, [ 'stop' ]).catch(function() {});
		return;
	}
	_st.phase = 'running'; _st.live = 0; _st.liveUp = 0; _st.upPhase = false;
	_st.down = null; _st.up = null; _st.ip = ''; _st.ipLocal = false;
	_st.hasData = false; _st.elapsed = null;
	_st.phaseStart = Date.now();
	_renderedKey = ''; _liveDisplay = 0;
	refreshStCard();
	stProgStart();
	_st.staleFinal = _st.lastStatusRaw || '';
	fs.exec(SPEEDBIN, [ 'start' ]).catch(function() {});
	stPoll(true);
}

function stPoll(expectStart) {
	var tries = 0, misses = 0, sawRunning = !expectStart;
	var poll = function() {
		return L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
			if (_st.stopping) {
				_st.stopping = false;
				_st.phase = 'idle';
				_st.down = null; _st.up = null;
				_st.live = 0; _st.liveUp = 0; _st.upPhase = false;
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			if (out) { _st.lastStatusRaw = out; }
			var j = null; try { j = JSON.parse(out || ''); } catch (e) { j = null; }
			if (!sawRunning && j && !j.running && out === _st.staleFinal) {
				if (tries++ < 30) {
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
				_st.phase = 'fail';
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			if (!j || (j.running == null && j.ok == null && !j.cancelled && !j.error)) {
				if (++misses <= 4 && tries++ < 70) {
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
				_st.phase = 'fail';
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			misses = 0;
			if (j.service) { _st.service = j.service; }
			if (j.running) {
				sawRunning = true;
				_st.phase = 'running';
				var wasUp = _st.upPhase;
				_st.upPhase = (j.phase === 'up');
				if (wasUp !== _st.upPhase) { _st.hasData = false; _st.elapsed = null; }
				if (j.live_down != null) { _st.live = j.live_down; }
				if (j.live_up != null) { _st.liveUp = j.live_up; }
					if (j.secs != null) { _st.secs = j.secs; }
				if (j.elapsed != null) { _st.elapsed = +j.elapsed; _st.elapsedAt = Date.now(); }
				if (+(_st.upPhase ? _st.liveUp : _st.live) > 0) { _st.hasData = true; }
				if (j.down_mbps != null) { _st.down = j.down_mbps; }
				if (j.pub_ip) { _st.ip = j.pub_ip; }
					if (j.ip_local != null) { _st.ipLocal = (j.ip_local == 1); }
				if (j.cc) { _st.cc = j.cc; }
				refreshStCard();
				if (tries++ < 70) {
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
			}
			if (_st.stopping || j.cancelled) {
				_st.stopping = false;
				_st.phase = 'idle';
				_st.down = null; _st.up = null;
				_st.live = 0; _st.liveUp = 0; _st.upPhase = false;
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			if (j.ok) { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.upErr = j.up_error || ''; _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; _st.ipLocal = (j.ip_local == 1); }
			else if (j.error === 'no-curl') {
				_st.phase = 'idle';
				ui.addNotification(null, E('p', _('Speed test needs the curl package: install it with "apk add curl" (or "opkg install curl"). It is not bundled - libcurl is noticeable on routers with 8 MB of flash.')), 'warning');
			}
			else { _st.phase = 'fail'; if (j.pub_ip) { _st.ip = j.pub_ip; _st.cc = j.cc || ''; } }
			_renderedKey = ''; stProgStop(); refreshStCard();
		});
	};
	return poll();
}

/* Names (_ssc, ssClashBtn, wkey) are historical and persisted, see docs/subsystems/internet-priority.md#web-panel-cards */
var _sscDefault = {
	go:     { present: false, port: 9091, scheme: 'http', version: '', path: '/'   },
	legacy: { present: false, port: 9090, scheme: 'http', version: '', path: '/ui/' },
	nikki:  { present: false, port: 9090, scheme: 'http', version: '', path: '/ui/' }
};
var _ssc = {};
Object.keys(_sscDefault).forEach(function(k) { _ssc[k] = Object.assign({}, _sscDefault[k]); });
Object.keys(_sscDefault).forEach(function(k) {
	try {
		var s = JSON.parse(window.localStorage.getItem('netpri-ssclash-' + k) || 'null');
		if (s && s.present) { _ssc[k] = s; }
	} catch (e) {}
});
var _svcToKind = { ssclash: 'go', clash: 'legacy', nikki: 'nikki' };
function sscKindForSvc(svc) { return _svcToKind[svc] || null; }

var SSCLASH_ICON = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
	'<path d="M6 7.5c0 3 2.5 4.5 6 4.5s6 1.5 6 4.5M18 16.5c0-3-2.5-4.5-6-4.5S6 10.5 6 7.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' +
	'<circle cx="6" cy="7.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="7.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="6" cy="16.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="16.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/></svg>';
var NIKKI_ICON = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
	'<path d="M8.6 10.7 15.5 6.9M8.6 13.3l6.9 3.8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>' +
	'<circle cx="6" cy="12" r="2.4" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="6" r="2.1" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="18" r="2.1" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/></svg>';

var PANEL_BRAND = {
	go:     { name: 'SSClash', icon: SSCLASH_ICON, wkey: 'ssclash-go', bin: '/usr/share/5gmodem/ssclash.sh' },
	legacy: { name: 'SSClash', icon: SSCLASH_ICON, wkey: 'ssclash',    bin: '/usr/share/5gmodem/ssclash.sh' },
	nikki:  { name: 'Nikki',   icon: NIKKI_ICON,   wkey: 'nikki',      bin: '/usr/share/5gmodem/nikki.sh' }
};

function sscCache(kind) {
	try { window.localStorage.setItem('netpri-ssclash-' + kind,
		JSON.stringify(Object.assign({}, _ssc[kind], { secret: '' }))); } catch (e) {}
}

var _sscProbed = {};
function ssclashInit(kind, redraw) {
	var st = _ssc[kind];
	if (!st || !PANEL_BRAND[kind]) { return; }
	if (st.present) { ssclashStatusInit(kind); }
	if (_sscProbed[kind]) { return; }
	_sscProbed[kind] = true;
	L.resolveDefault(fs.exec_direct(PANEL_BRAND[kind].bin, [ 'detect', kind ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j && j.present) {
			_ssc[kind] = { present: true, port: (j.port || _sscDefault[kind].port),
				scheme: (j.scheme || 'http'), version: (j.version || ''),
				path: (j.path || _sscDefault[kind].path), kind: kind, running: st.running,
				secret: (j.secret || '') };
			sscCache(kind);
			ssclashStatusInit(kind);
			if (typeof redraw === 'function') { loadList().then(function(l) { redraw(l); }); }
		} else {
			var _had = st.present;
			_ssc[kind] = Object.assign({}, _sscDefault[kind]);
			try { window.localStorage.removeItem('netpri-ssclash-' + kind); } catch (e) {}
			if (_had && typeof redraw === 'function') { loadList().then(function(l) { redraw(l); }); }
		}
	});
}

function ssClashBtn(kind) {
	var st = _ssc[kind];
	var br = PANEL_BRAND[kind] || PANEL_BRAND.go;
	var host = window.location.hostname;
	var url = st.scheme + '://' + host + ':' + st.port + (st.path || '/');
	if (kind === 'nikki') {
		url += '?host=' + encodeURIComponent(host) +
			'&hostname=' + encodeURIComponent(host) +
			'&port=' + encodeURIComponent(st.port) +
			'&secret=' + encodeURIComponent(st.secret || '');
	}
	var ic = E('span', { 'class': 'netpri-ssclash-ic' });
	ic.innerHTML = br.icon;
	var dot = E('span', { 'class': 'netpri-svcdot ' + (st.running ? 'on' : 'off'),
		'title': (st.running ? _('%s is running') : _('%s is stopped')).format(br.name) });
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-ssclash',
		'data-ssckind': kind,
		'data-wkey': 's:' + br.wkey,
		'data-tooltip': _('Open the %s admin panel in a new tab').format(br.name),
		'click': function() { if (_npSwallowClick()) { return; } window.open(url, '_blank', 'noopener'); }
	}, [
		svcRankEl(ic),
		E('span', { 'class': 'netpri-sub' }, [ String(st.version || br.name) ]),
		E('span', { 'class': 'netpri-name' }, [ dot, ic, E('span', {}, br.name) ]),
		E('span', { 'class': 'netpri-ip' }, host)
	]);
}

function pingBadge(info) {
	if (info.svg) {
		var ic = E('span', { 'class': 'netpri-pingico' });
		ic.innerHTML = info.svg;
		return ic;
	}
	if (info.img) {
		if (info.plain) {
			return E('span', { 'class': 'netpri-pingico' }, [
				E('img', { 'src': mutil.icon('icons/5gmodem/' + info.img), 'width': 16, 'height': 16,
					'alt': '', 'style': 'display:block;border-radius:4px' })
			]);
		}
		return E('span', { 'class': 'netpri-pingbadge', 'style': 'background:#1b1f23' }, [
			E('img', { 'src': mutil.icon('icons/5gmodem/' + info.img), 'width': 12, 'height': 12,
				'alt': '', 'style': 'display:block' })
		]);
	}
	if (info.custom) { return E('span', { 'class': 'netpri-pingbadge custom' }, info.glyph); }
	return E('span', { 'class': 'netpri-pingbadge', 'style': 'background:' + info.color }, info.glyph);
}
function _pDot(st) { return (st && st.done) ? (st.ok ? 'on' : 'off') : 'unknown'; }
function _pMs(st) {
	if (!(st && st.done)) { return '\u00a0'; }
	return (st.ok && st.ms != null) ? (st.ms + ' ' + _('ms')) : ('— ' + _('ms'));
}
function _pTip(st, info) {
	if (st && st.done && !st.ok && st.why === 'dns') {
		return _('DNS returns a foreign address for %s (%s) - the resolver substitutes it').format(info.name, st.ip || '?');
	}
	return !(st && st.done) ? _('Click to ping %s').format(info.name)
		: (st.ok ? _('%s is reachable').format(info.name) : _('No connection to %s').format(info.name));
}
function pingCard(w) {
	var host = String(w.host || 'youtube.com').trim();
	var info = pingInfo(host);
	var st = _pingState[host];
	var dot = E('span', { 'class': 'netpri-svcdot ' + _pDot(st), 'title': _pTip(st, info) });
	var pic = pingBadge(info);
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-status' + (_pingBusy[host] ? ' ping-busy' : ''), 'data-host': host,
		'data-wkey': 'p:' + host,
		'data-tooltip': _('Click to measure ping to %s over the active uplink').format(info.name),
		'click': function(ev) { ev.preventDefault(); if (_npSwallowClick()) { return; } pingOnce(host); }
	}, [
		svcRankEl(pic),
		E('span', { 'class': 'netpri-sub' }, _('Status')),
		E('span', { 'class': 'netpri-name' }, [ dot, pic, E('span', {}, [ info.name ]) ]),
		E('span', { 'class': 'netpri-ip' }, _pMs(st))
	]);
}
function updatePingCard(host) {
	var st = _pingState[host], info = pingInfo(host);
	var sel = '.netpri-status[data-host="' + _npCssEsc(host) + '"]';
	document.querySelectorAll(sel + ' .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off', 'unknown'); d.classList.add(_pDot(st)); d.title = _pTip(st, info);
	});
	document.querySelectorAll(sel + ' .netpri-ip').forEach(function(el) { el.textContent = _pMs(st); });
	npFitRow();
}
var _pingAnim = {};
function animatePingMs(host, from, to) {
	var sel = '.netpri-status[data-host="' + _npCssEsc(host) + '"] .netpri-ip';
	if (!document.querySelector(sel)) { return; }
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) { return; }
	if (_pingAnim[host]) { window.cancelAnimationFrame(_pingAnim[host]); _pingAnim[host] = null; }
	var t0 = null, dur = 600;
	var step = function(ts) {
		if (t0 === null) { t0 = ts; }
		var p = Math.min((ts - t0) / dur, 1);
		var e = 1 - (1 - p) * (1 - p);
		var v = Math.round(from + (to - from) * e);
		document.querySelectorAll(sel).forEach(function(el) { el.textContent = v + ' ' + _('ms'); });
		if (p < 1) { _pingAnim[host] = window.requestAnimationFrame(step); }
		else { _pingAnim[host] = null; }
	};
	_pingAnim[host] = window.requestAnimationFrame(step);
}
function _npCssEsc(v) {
	v = String(v == null ? '' : v);
	return (window.CSS && CSS.escape) ? CSS.escape(v) : v.replace(/["\\]/g, '\\$&');
}
var _pingBusy = {};
function pingOnce(host) {
	host = String(host).trim();
	if (_pingBusy[host]) { return Promise.resolve(); }
	_pingBusy[host] = true;
	var _hadPrev = (_pingState[host] && _pingState[host].ok && _pingState[host].ms != null);
	document.querySelectorAll('.netpri-status[data-host="' + _npCssEsc(host) + '"]').forEach(function(c) { c.classList.add('ping-busy'); });
	if (!_hadPrev) {
		document.querySelectorAll('.netpri-status[data-host="' + _npCssEsc(host) + '"] .netpri-ip').forEach(function(el) { el.textContent = '…'; });
	}
	return L.resolveDefault(fs.exec_direct(BIN, [ 'ping', host ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		var prev = (_pingState[host] && _pingState[host].ok && _pingState[host].ms != null)
			? _pingState[host].ms : 0;
		_pingState[host] = { done: true, ok: !!j.ok, ms: (j.ms != null ? j.ms : null),
		                     why: j.why || null, ip: j.ip || null };
		try { window.localStorage.setItem('netpri-pingstate', JSON.stringify(_pingState)); } catch (e) {}
		mutil.lsTouch('netpri-pingstate');
		_pingBusy[host] = false;
		document.querySelectorAll('.netpri-status[data-host="' + _npCssEsc(host) + '"]').forEach(function(c) { c.classList.remove('ping-busy'); });
		updatePingCard(host);
		document.querySelectorAll('.netpri-status[data-host="' + _npCssEsc(host) + '"] .netpri-svcdot').forEach(function(d) {
			d.classList.remove('ping-flash');
			void d.offsetWidth;
			d.classList.add('ping-flash');
			window.setTimeout(function() { d.classList.remove('ping-flash'); }, 800);
		});
		if (j.ok && j.ms != null) { animatePingMs(host, prev, j.ms); }
	});
}
var _npExtipSub = null;
var _npPolls = [];
function _npPollAdd(fn, n) { _npPolls.push(fn); poll.add(fn, n); }
function _npPollsStop() {
	_npPolls.forEach(function(fn) { poll.remove(fn); });
	_npPolls = [];
	_svcAgg.started = false;
	_pingPolls = {};
}
var _pingPolls = {};
function pingInit() {
	_pingWidgets.forEach(function(w) {
		var n = parseInt(w.mode, 10);
		if (isNaN(n) || n <= 0 || _pingPolls[w.host]) { return; }
		_pingPolls[w.host] = true;
		pingOnce(w.host);
		(function(h) { _npPollAdd(function() { return pingOnce(h); }, n); })(w.host);
	});
}

var SVC_KNOWN = {
	zapret: { name: 'Zapret', glyph: '☢️', port: 7681 },
	zerotier: { name: 'ZeroTier', img: 'zt.png' }
};
function isDarkUI(el) {
	var c = getComputedStyle(el || document.body).color;
	var m = String(c).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	if (!m) { return false; }
	return (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

function svcRankEl(icon) {
	if (_netpriRank !== 'icon') { return ''; }
	if (!icon || typeof icon.cloneNode !== 'function') { return ''; }
	return E('span', { 'class': 'netpri-rank netpri-rank-bg', 'aria-hidden': 'true' },
		[ icon.cloneNode(true) ]);
}

function svcName(service) { return (SVC_KNOWN[service] && SVC_KNOWN[service].name) || service; }
function svcIcon(service) {
	var k = SVC_KNOWN[service];
	if (k && k.img) {
		return E('img', { 'class': 'netpri-ic', 'src': mutil.icon('icons/5gmodem/' + k.img),
			'width': 16, 'height': 16, 'alt': '' });
	}
	if (k && k.glyph) {
		return E('span', { 'class': 'netpri-pingbadge' + (k.color ? '' : ' custom'),
			'style': k.color ? ('background:' + k.color) : null }, k.glyph);
	}
	return E('span', { 'class': 'netpri-pingbadge custom' }, '🔧');
}
function _sDot(r) { return (r === undefined) ? 'unknown' : (r.running ? 'on' : 'off'); }
function _sTop(r) { return (r && r.version) ? ('v' + r.version) : _('Service'); }
function _sBottom(r) {
	if (r === undefined) { return '—'; }
	if (r.ip) { return r.ip; }
	return r.running ? _('running') : _('stopped');
}
function svcCard(service) {
	var r = _svcState[service];
	var k = SVC_KNOWN[service];
	var dot = E('span', { 'class': 'netpri-svcdot ' + _sDot(r),
		'title': (r === undefined) ? service : (r.running ? _('%s is running').format(service) : _('%s is stopped').format(service)) });
	var attrs = {
		'class': 'btn cbi-button netpri-btn netpri-status', 'data-svc': service,
		'data-wkey': 's:' + service,
		'data-tooltip': (r && r.ip) ? _('%s address of this router: %s').format(svcName(service), r.ip)
			: ((k && k.port) ? _('Open %s').format(svcName(service)) : service)
	};
	if (k && k.port) {
		attrs['click'] = function(ev) {
			ev.preventDefault();
			if (_npSwallowClick()) { return; }
			window.open('//' + window.location.hostname + ':' + k.port + '/', '_blank');
		};
	} else {
		attrs['click'] = function(ev) { ev.preventDefault(); _npSwallowClick(); };
	}
	var sic = svcIcon(service);
	return E('button', attrs, [
		svcRankEl(sic),
		E('span', { 'class': 'netpri-sub' }, [ String(_sTop(r)) ]),
		E('span', { 'class': 'netpri-name' }, [ dot, sic, E('span', {}, [ svcName(service) ]) ]),
		E('span', { 'class': 'netpri-ip' }, [ String(_sBottom(r)) ])
	]);
}
function updateSvcCard(service) {
	var r = _svcState[service], sel = '.netpri-status[data-svc="' + service + '"]';
	document.querySelectorAll(sel + ' .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off', 'unknown'); d.classList.add(_sDot(r));
	});
	document.querySelectorAll(sel + ' .netpri-sub').forEach(function(el) { el.textContent = _sTop(r); });
	document.querySelectorAll(sel + ' .netpri-ip').forEach(function(el) { el.textContent = _sBottom(r); });
	npFitRow();
}
var _svcAgg = { services: [], kinds: [], started: false };
function _svcAggTick() {
	if (!_svcAgg.services.length && !_svcAgg.kinds.length) { return Promise.resolve(); }
	/* '-' = empty list, see docs/subsystems/internet-priority.md#svcall-empty-list */
	return L.resolveDefault(fs.exec_direct(BIN, [ 'svcall', _svcAgg.services.join(',') || '-', _svcAgg.kinds.join(',') || '-' ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		_svcAgg.services.forEach(function(svc) {
			var r = (j.svc || {})[svc] || {};
			_svcState[svc] = { running: !!r.running, version: r.version || '', ip: r.ip || '' };
			updateSvcCard(svc);
		});
		_svcAgg.kinds.forEach(function(kind) {
			var r = (j.ssc || {})[kind] || {};
			_ssc[kind].running = !!r.running;
			sscCache(kind);
			updateSscDot(kind);
		});
	});
}
function _svcAggStart() {
	if (_svcAgg.started) { return; }
	_svcAgg.started = true;
	_npPollAdd(_svcAggTick, 5);
}
function svcStatusInit(services) {
	services = (services || []).filter(function(s) {
		return s && !sscKindForSvc(s) && _svcAgg.services.indexOf(s) < 0;
	});
	if (!services.length) { return; }
	_svcAgg.services = _svcAgg.services.concat(services);
	_svcAggTick();
	_svcAggStart();
}

function updateSscDot(kind) {
	var st = _ssc[kind];
	var nm = (PANEL_BRAND[kind] || PANEL_BRAND.go).name;
	var cls = st.running ? 'on' : 'off';
	var tip = (st.running ? _('%s is running') : _('%s is stopped')).format(nm);
	document.querySelectorAll('.netpri-ssclash[data-ssckind="' + kind + '"] .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off'); d.classList.add(cls); d.title = tip;
	});
}
function ssclashStatusInit(kind) {
	if (_svcAgg.kinds.indexOf(kind) >= 0) { return; }
	_svcAgg.kinds.push(kind);
	_svcAggTick();
	_svcAggStart();
}

function stInit() {
	L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
		if (out) { _st.lastStatusRaw = out; }
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j.service) { _st.service = j.service; }
		if (j.running && _st.phase !== 'running') {
			_st.phase = 'running'; _st.hasData = false; _st.elapsed = null;
			_st.upPhase = (j.phase === 'up');
			_renderedKey = ''; _liveDisplay = 0;
			refreshStCard(); stProgStart();
			stPoll();
			return;
		}
		if (j.ok && _st.phase === 'idle') { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.upErr = j.up_error || ''; _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; }
		patchStCard();
	});
}

var _hfo = null;

var _npEmptyStreak = 0;
var _npRecheck = null;

function loadList() {
	return L.resolveDefault(fs.exec_direct(BIN, [ 'list' ]), '').then(function(out) {
		var arr = [], ok = false;
		try { arr = JSON.parse(out || ''); ok = Array.isArray(arr); } catch (e) {}
		arr = Array.isArray(arr) ? arr : [];
		arr = arr.filter(function(o) {
			if (o && o.event != null) { _hfo = (String(o.failover) === '1'); return false; }
			return true;
		});
		if (arr.length) {
			_npEmptyStreak = 0;
			try { window.localStorage.setItem('netpri-last', JSON.stringify(arr)); } catch (e) {}
		} else if (ok) {
			_npEmptyStreak++;
			if (_npEmptyStreak >= 2) {
				try { window.localStorage.removeItem('netpri-last'); } catch (e) {}
			} else if (_npRecheck) {
				window.setTimeout(_npRecheck, 3000);
			}
		}
		arr._ok = ok;
		return arr;
	});
}

function lastList() {
	try {
		var a = JSON.parse(window.localStorage.getItem('netpri-last') || '[]');
		return Array.isArray(a) ? a : [];
	} catch (e) { return []; }
}

function activeIface(list) {
	var lv = null;
	list.forEach(function(o) { if (o.live) { lv = o.iface; } });
	if (lv) { return lv; }
	var best = null, bm = Infinity, bip = false;
	list.forEach(function(o) {
		var m = parseInt(o.metric, 10); if (isNaN(m)) { m = 0; }
		var hip = !!o.ip;
		if (m < bm || (m === bm && hip && !bip)) { bm = m; best = o.iface; bip = hip; }
	});
	return best;
}

function typeIcon(o) {
	if (o.type === 'modem') {
		var oi = mutil.operatorIcon(o.label);
		return E('img', {
			'class': 'netpri-ic', 'src': mutil.icon('icons/5gmodem/' + (oi ? oi : 'op-sim') + '.svg'),
			'width': 16, 'height': 16, 'alt': ''
		});
	}
	var f = (o.type === 'wifi') ? 'cwifi.svg'
	      : (o.type === 'wan')  ? 'cwan.svg'
	      : null;
	if (!f) { return null; }
	return E('img', {
		'class': 'netpri-ic', 'src': mutil.icon('icons/5gmodem/' + f),
		'width': 16, 'height': 16, 'alt': ''
	});
}

function chevron() {
	var s = E('span', { 'class': 'netpri-chevron' });
	s.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor">' +
		'<path d="M7 10l5 5 5-5z"/></svg>';
	return s;
}

function rankEl(idx, o) {
	if (_netpriRank === 'icon') {
		var src = null;
		if (o && o.type === 'modem') {
			var oi = mutil.operatorIcon(o.label);
			src = mutil.icon('icons/5gmodem/' + (oi ? oi : 'op-sim') + '.svg');
		} else if (o && o.type === 'wifi') {
			src = mutil.icon('icons/5gmodem/cwifi.svg');
		} else if (o && o.type === 'wan') {
			src = mutil.icon('icons/5gmodem/cwan.svg');
		}
		if (!src) { return ''; }
		return E('img', { 'class': 'netpri-rank netpri-rank-ic', 'src': src,
			'alt': '', 'aria-hidden': 'true' });
	}
	if (_netpriRank !== 'num') { return ''; }
	var sp = E('span', { 'class': 'netpri-rank', 'aria-hidden': 'true' }, String(idx + 1));
	_rankFit(sp);
	return sp;
}

function _rankFit(sp) {
	var gaps = function(card) {
		var cs = getComputedStyle(sp);
		var ctx = _rankFit._cv || (_rankFit._cv = document.createElement('canvas').getContext('2d'));
		ctx.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
		var m = ctx.measureText(sp.textContent);
		if (!m || !m.actualBoundingBoxAscent) { return null; }
		var rr = sp.getBoundingClientRect(), cr = card.getBoundingClientRect();
		var baseline = (rr.height - (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent)) / 2
			+ m.fontBoundingBoxAscent;
		return {
			fs: parseFloat(cs.fontSize),
			glyph: m.actualBoundingBoxAscent + m.actualBoundingBoxDescent,
			top: (rr.top - cr.top) + baseline - m.actualBoundingBoxAscent,
			bot: cr.height - ((rr.top - cr.top) + baseline + m.actualBoundingBoxDescent)
		};
	};
	var step2 = function() {
		if (!sp.isConnected) { return; }
		var card = sp.closest('.netpri-btn');
		var g = card && gaps(card);
		if (!g) { return; }
		var want = (g.top + g.bot) / 2;
		sp.style.top = ((parseFloat(getComputedStyle(sp).top) || 0) - (g.top - want)) + 'px';
	};
	var step1 = function() {
		if (!sp.isConnected) { return; }
		var card = sp.closest('.netpri-btn');
		var g = card && gaps(card);
		if (!g) { return; }
		sp.style.lineHeight = '1';
		sp.style.fontSize = (g.fs * card.clientHeight / g.glyph) + 'px';
		window.requestAnimationFrame(step2);
	};
	window.requestAnimationFrame(step1);
	if (document.fonts && document.fonts.ready) { document.fonts.ready.then(function() { window.requestAnimationFrame(step1); }); }
}

function nameEl(o) {
	var txt = o.label || o.iface;
	var ic = typeIcon(o);
	if (ic) { return E('span', { 'class': 'netpri-name' }, [ ic, E('span', {}, [ txt ]) ]); }
	return E('span', { 'class': 'netpri-name' }, [ txt ]);
}

var _npDrag = null;
var _npApplying = false;
var _npJustDragged = false;
function _npSwallowClick() {
	if (_npJustDragged) { _npJustDragged = false; return true; }
	return false;
}

function _npEnsureDragCss() {
	}

function _npCards(row, attr) {
	return Array.prototype.slice.call(row.children).filter(function(c) {
		return c.nodeType === 1 && c.classList.contains('netpri-btn') && c.hasAttribute(attr);
	});
}

function _npIfaceCards(row) { return _npCards(row, 'data-iface'); }
function _npWidgetCards(row) { return _npCards(row, 'data-wkey'); }

function _npDragAttr() { return (_npDrag && _npDrag.attr) ? _npDrag.attr : 'data-iface'; }
function _npDragCards(row) { return _npCards(row, _npDragAttr()); }

function _npMakeSlot(w, h) {
	var s = E('div', { 'class': 'netpri-btn netpri-slot' });
	s.style.width = w + 'px'; s.style.height = h + 'px';
	s.innerHTML = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" ' +
		'stroke="currentColor" stroke-width="2" stroke-linecap="round">' +
		'<path d="M12 5v14M5 12h14"/></svg>';
	return s;
}

function _npLayoutPos(c) {
	var r = c.getBoundingClientRect(), tx = 0, ty = 0;
	var tr = getComputedStyle(c).transform;
	if (tr && tr !== 'none') {
		var m = tr.match(/matrix\(([^)]+)\)/);
		if (m) { var q = m[1].split(','); tx = parseFloat(q[4]) || 0; ty = parseFloat(q[5]) || 0; }
		else { var m3 = tr.match(/matrix3d\(([^)]+)\)/); if (m3) { var w = m3[1].split(','); tx = parseFloat(w[12]) || 0; ty = parseFloat(w[13]) || 0; } }
	}
	return { left: r.left - tx, top: r.top - ty };
}

function _npFlip(cards, before) {
	cards.forEach(function(c) {
		var b = before.get(c); if (!b) { return; }
		var now = _npLayoutPos(c);
		var dx = b.left - now.left, dy = b.top - now.top;
		if (Math.abs(dx) < 1 && Math.abs(dy) < 1) { return; }
		c.style.transition = 'none';
		c.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
		requestAnimationFrame(function() {
			c.style.transition = 'transform .18s ease';
			c.style.transform = '';
		});
	});
}

function _npFixRightStart(row) {
	Array.prototype.slice.call(row.querySelectorAll('.netpri-rightstart'))
		.forEach(function(c) { c.classList.remove('netpri-rightstart'); });
	var slot = (_npDrag && _npDrag.attr === 'data-wkey') ? _npDrag.slot : null;
	var lifted = (_npDrag && _npDrag.active) ? _npDrag.card : null;
	var w = Array.prototype.slice.call(row.children).filter(function(c) {
		if (c.nodeType !== 1 || c === lifted) { return false; }
		return c === slot || (c.classList.contains('netpri-btn') && c.hasAttribute('data-wkey'));
	});
	if (w.length) { w[0].classList.add('netpri-rightstart'); }
}

function _npReposition(clientX, clientY) {
	var d = _npDrag; if (!d || !d.slot) { return; }
	var row = d.row, slot = d.slot;
	var cards = _npDragCards(row).filter(function(c) { return c !== d.card; });
	var idx = cards.length;
	for (var i = 0; i < cards.length; i++) {
		var p = _npLayoutPos(cards[i]), ow = cards[i].offsetWidth, oh = cards[i].offsetHeight;
		if (clientY < p.top) { idx = i; break; }
		if (clientY < p.top + oh && clientX < p.left + ow / 2) { idx = i; break; }
	}
	if (idx === d.lastIndex) { return; }
	d.lastIndex = idx;
	var before = new Map(); cards.forEach(function(c) { before.set(c, _npLayoutPos(c)); });
	var refBefore = cards[idx] || null;
	if (refBefore) { row.insertBefore(slot, refBefore); }
	else if (cards.length) { row.insertBefore(slot, cards[cards.length - 1].nextSibling); }
	else { row.appendChild(slot); }
	_npFlip(cards, before);
	_npFixRightStart(row);
}

function _npBeginDrag() {
	var d = _npDrag, card = d.card;
	var r = card.getBoundingClientRect();
	d.slot = _npMakeSlot(r.width, r.height);
	card.parentNode.insertBefore(d.slot, card);
	card.style.position = 'fixed';
	card.style.left = r.left + 'px'; card.style.top = r.top + 'px';
	card.style.width = r.width + 'px'; card.style.height = r.height + 'px';
	card.style.margin = '0'; card.style.zIndex = '1000'; card.style.pointerEvents = 'none';
	card.classList.add('netpri-lift');
	document.body.style.userSelect = 'none';
	d.active = true;
	_npFixRightStart(d.row);
}

function _npMove(ev) {
	var d = _npDrag; if (!d) { return; }
	var dx = ev.clientX - d.startX, dy = ev.clientY - d.startY;
	if (!d.active) {
		if (Math.abs(dx) < 5 && Math.abs(dy) < 5) { return; }
		_npBeginDrag();
	}
	ev.preventDefault();
	d.card.style.transform = 'translate(' + dx + 'px,' + dy + 'px) scale(1.03)';
	_npReposition(ev.clientX, ev.clientY);
}

function _npTeardown() {
	var d = _npDrag; if (!d) { return null; }
	_npDrag = null;
	document.removeEventListener('pointermove', _npMove, true);
	document.removeEventListener('pointerup', _npEnd, true);
	document.removeEventListener('pointercancel', _npEnd, true);
	try { d.card.releasePointerCapture(d.pid); } catch (e) {}
	document.body.style.userSelect = '';
	if (d.active) {
		var card = d.card;
		card.classList.remove('netpri-lift');
		[ 'position','left','top','width','height','margin','zIndex','pointerEvents','transform' ]
			.forEach(function(k) { card.style[k] = ''; });
		if (d.slot && d.slot.parentNode) { d.slot.parentNode.insertBefore(card, d.slot); d.slot.parentNode.removeChild(d.slot); }
		_npDragCards(d.row).forEach(function(c) { c.style.transition = ''; c.style.transform = ''; });
		_npFixRightStart(d.row);
	}
	return d;
}

function _npEnd() {
	var d = _npDrag; if (!d) { return; }
	var active = d.active, row = d.row, commit = d.commit, attr = d.attr || 'data-iface';
	_npTeardown();
	if (!active) { return; }
	_npJustDragged = true;
	if (attr === 'data-wkey') {
		var wkeys = _npWidgetCards(row).map(function(c) { return c.getAttribute('data-wkey'); });
		_widgetOrder = wkeys.slice();
		try { uci.unload('5gmodem'); } catch (e) {}
		_npApplying = true;
		var _wDone = function() { _npApplying = false; };
		setTimeout(_wDone, 4000);
		L.resolveDefault(fs.exec(BIN, [ 'worder' ].concat(wkeys)), {}).then(_wDone, _wDone);
		return;
	}
	var _cards = _npIfaceCards(row);
	_cards.forEach(function(c) { c.classList.remove('active'); });
	if (_cards[0]) { _cards[0].classList.add('active'); }
	var order = _cards.map(function(c) { return c.getAttribute('data-iface'); });
	_npApplying = true;
	var _npDone = function() { _npApplying = false; };
	setTimeout(_npDone, 4000);
	L.resolveDefault(fs.exec(BIN, [ 'order' ].concat(order)), {}).then(function() {
		loadList().then(function(l2) { if (commit) { commit(l2); } _npDone(); });
	}, _npDone);
}

function _npEnableReorder(row, commit, attr) {
	_npEnsureDragCss();
	var _attr = attr || 'data-iface';
	_npCards(row, _attr).forEach(function(card) {
		card.addEventListener('pointerdown', function(ev) {
			if (ev.button !== 0) { return; }
			if (_npDrag) { _npTeardown(); }
			_npDrag = { card: card, row: row, startX: ev.clientX, startY: ev.clientY,
			            active: false, commit: commit, pid: ev.pointerId, lastIndex: -1,
			            attr: _attr };
			try { card.setPointerCapture(ev.pointerId); } catch (e) {}
			document.addEventListener('pointermove', _npMove, true);
			document.addEventListener('pointerup', _npEnd, true);
			document.addEventListener('pointercancel', _npEnd, true);
		});
		card.addEventListener('lostpointercapture', function() {
			if (_npDrag && _npDrag.card === card) { _npEnd(); }
		});
	});
}

function healthModal() {
	healthform.load().then(function(d) {
		var hf = healthform.build(d.conf, d.uplinks);
		ui.showModal(_('Internet watchdog'), [
			hf.node,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action important', 'click': function() {
					hf.save().then(function() { ui.hideModal(); });
				} }, _('Save'))
			])
		], 'hw-modal');
		var _hwSec = document.querySelector('.netpribar') || document.querySelector('.cbi-section');
		var _hwMd = document.querySelector('#modal_overlay .modal') || document.querySelector('.modal');
		if (_hwSec && _hwMd) {
			var _hwW = Math.round(_hwSec.getBoundingClientRect().width) + 'px';
			_hwMd.style.setProperty('max-width', _hwW, 'important');
			_hwMd.style.setProperty('width', _hwW, 'important');
		}
	});
}

function buildBar(list, redraw) {
	var active = activeIface(list);
	var _sorted = (_widgets.netpri ? list.slice() : []).sort(function(a, b) {
		var da = (a.health === 'down' || a.health === 'gone') ? 1 : 0;
		var db = (b.health === 'down' || b.health === 'gone') ? 1 : 0;
		if (da !== db) { return da - db; }
		var ma = parseInt(a.metric, 10); if (isNaN(ma)) { ma = 999; }
		var mb = parseInt(b.metric, 10); if (isNaN(mb)) { mb = 999; }
		if (ma !== mb) { return ma - mb; }
		return (b.ip ? 1 : 0) - (a.ip ? 1 : 0);
	});
	var btns = _sorted.map(function(o, _rank) {
		var isA = (o.iface === active);
		var isGone = (o.health === 'gone');
		var isOrphan = !!o.nozone;
		return E('button', {
			'class': 'btn cbi-button netpri-btn' + (isGone ? ' netpri-slot netpri-gone' : (isOrphan ? ' netpri-slot' : (isA ? ' active' : ''))),
			'data-iface': o.iface,
			'data-tooltip': isOrphan
				? _('This Wi-Fi uplink is not in the wan firewall zone - click to add it and make it usable')
				: (o.iface + (o.metric != null ? (' · metric ' + o.metric) : '')),
			'click': function(ev) {
				if (_npSwallowClick()) { return; }
				var ifc = ev.currentTarget.getAttribute('data-iface');
				if (isOrphan) {
					_npApplying = true;
					var _azDone = function() { _npApplying = false; };
					setTimeout(_azDone, 4000);
					L.resolveDefault(fs.exec(BIN, [ 'adoptzone', ifc ]), {}).then(function() {
						loadList().then(function(l2) { redraw(l2); _azDone(); }, _azDone);
					}, _azDone);
					return;
				}
				if (ifc === active) { return; }
				var card = ev.currentTarget, row = card.parentNode;
				if (row) { row.querySelectorAll('.netpri-btn.active').forEach(function(b) { b.classList.remove('active'); }); }
				card.classList.add('active');
				var order = [ ifc ].concat(_sorted.filter(function(o) { return o.iface !== ifc; }).map(function(o) { return o.iface; }));
				_npApplying = true;
				var _done = function() { _npApplying = false; };
				setTimeout(_done, 4000);
				L.resolveDefault(fs.exec(BIN, [ 'order' ].concat(order)), {}).then(function() {
					loadList().then(function(l2) { redraw(l2); _done(); });
				}, _done);
			}
		}, (function() {
			if (isGone) {
				return [
					rankEl(_rank, o),
					E('span', { 'class': 'netpri-sub' }, [ o.sub || o.iface ]),
					E('span', { 'class': 'netpri-name' }, [ o.iface ]),
					E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***'),
					E('span', { 'class': 'netpri-skelov' }, [
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:55%' }),
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:85%' }),
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:65%' })
					])
				];
			}
			if (o.health === 'down' && o.healstep) {
				var ladders = {
					wifi: [
						[ _('Reconnecting'),        'ifdown/ifup' ],
						[ _('Reassociating'),       'REASSOCIATE' ],
						[ _('Restarting the radio'), 'wireless down/up' ],
						[ _('Rebuilding the network'), 'network reload' ]
					],
					hilink: [
						[ _('Reconnecting'),  'ifdown/ifup' ],
						[ _('Rebooting'),     _('modem web API') ],
						[ _('USB power cycle'), 'USB power' ]
					],
					modem: [
						[ _('Reconnecting'),  'ifdown/ifup' ],
						[ _('Rebooting'),     'AT+CFUN=1,1' ],
						[ _('USB power cycle'), 'USB power' ]
					]
				};
				var ladder = ladders[o.healkind] || ladders.modem;
				var step = ladder[o.healstep - 1] || ladder[ladder.length - 1];
				var stepName = step[0], stepCmd = step[1];
				var forTxt = null;
				if (o.healfor != null) {
					forTxt = (o.healfor < 90) ? _('%ds').format(o.healfor)
					                          : _('%dm').format(Math.round(o.healfor / 60));
				}
				return [
					E('span', { 'class': 'netpri-sub' }, stepName + ' (' + o.healn + '/' + o.healmax + ')'),
					E('span', { 'class': 'netpri-name' }, [ o.iface ]),
					E('span', { 'class': 'netpri-ip' }, [
						E('span', { 'class': 'netpri-svcdot netpri-health off', 'title': _('No internet on this link') }),
						(forTxt ? forTxt + ' | ' : '') + stepCmd
					])
				];
			}
			return [
			rankEl(_rank, o),
			E('span', { 'class': 'netpri-sub' },
				[ isOrphan ? _('not in wan zone — click to fix') : (o.sub || o.iface) ]),
			nameEl(o),
			(function() {
				var ex = extip.state(o.iface);
				if (!ex.ip && isA) { ex = extip.state(''); }
				var extShown = !!(extip.flags().inNetpri && ex.ip);
				return E('span', {
					'class': 'netpri-ip' + ((o.ip || extShown) ? '' : ' empty'),
					'data-tooltip': extShown
						? _('External address via %s. Interface address: %s')
							.format(ex.src || '?', o.ip || '-')
						: null
				}, [
					o.health ? E('span', {
						'class': 'netpri-svcdot netpri-health ' +
							(o.health === 'up' ? 'on' : (o.health === 'down' || o.health === 'gone' ? 'off' : 'unknown')),
						'title': (o.health === 'up') ? _('Internet is working (%s ms)').format(o.hms)
						       : (o.health === 'down') ? _('No internet on this link')
						       : (o.health === 'gone') ? _('Device is gone')
						       : _('Checking…')
					}) : '',
					extShown ? extip.withFlag(ex.ip, ex.cc) : (o.ip || '***.***.***.***')
				]);
			})()
			];
		})());
	});
	var right = [];
	if (_widgets.status) { _pingWidgets.forEach(function(w) { right.push(pingCard(w)); }); }
	if (_widgets.services) {
		effectiveSvcs().forEach(function(svc) {
			var _sk = sscKindForSvc(svc);
			if (_sk) { right.push(ssClashBtn(_sk)); }
			else { right.push(svcCard(svc)); }
		});
	}
	if (_widgets.speedtest) { right.push(stCard()); }
	if (_widgetOrder.length) {
		right.sort(function(a, b) {
			var ia = _widgetOrder.indexOf(a.getAttribute('data-wkey'));
			var ib = _widgetOrder.indexOf(b.getAttribute('data-wkey'));
			if (ia < 0) { ia = 1e6; }
			if (ib < 0) { ib = 1e6; }
			return ia - ib;
		});
	}
	if (right.length) { right[0].classList.add('netpri-rightstart'); }
	btns = btns.concat(right);
	var kids = [];
	if (_widgets.netpri) {
		kids.push(E('div', { 'class': 'netpribar-title' }, [
			E('span', {
				'class': 'netpri-gear',
				'title': _('Internet watchdog settings'),
				'click': function(ev) { ev.stopPropagation(); healthModal(); }
			}, '⚙'),
			_('Internet priority')
		]));
		var carrier = null;
		list.forEach(function(o) { if (o.iface === active) { carrier = o; } });
		if (_hfo === false && carrier && (carrier.health === 'down' || carrier.health === 'gone')) {
			kids.push(E('div', { 'class': 'netpri-warn' }, [
				E('span', { 'class': 'netpri-warn-ic' }, '⚠'),
				_('Traffic goes through %s, and there is no internet on it. Automatic switching is off - the watchdog sees the failure and does nothing.').format(carrier.sub || carrier.iface),
				' ',
				E('a', {
					'href': '#',
					'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); healthModal(); }
				}, _('Turn switching on'))
			]));
		}
	}
	var rowEl = E('div', { 'class': 'netpri-row' + (_npTwoCol ? ' netpri-2col' : '') }, btns);
	if (_widgets.netpri) { _npEnableReorder(rowEl, redraw); }
	_npEnableReorder(rowEl, null, 'data-wkey');
	kids.push(rowEl);
	var _bar = E('div', { 'class': 'netpribar' }, kids);
	window.setTimeout(npSyncTheme, 0);
	npWatchTheme();
	npWatchFit();
	return _bar;
}

var _npTwoCol = false;
var _npFitHooked = false;
function npFitRow() {
	document.querySelectorAll('.netpribar .netpri-row').forEach(function(row) {
		if (!row.isConnected) { return; }
		row.classList.remove('netpri-2col');
		var two = false;
		if (window.getComputedStyle(row).display === 'grid') {
			row.querySelectorAll('.netpri-btn:not(.netpri-st) .netpri-name, .netpri-btn:not(.netpri-st) .netpri-name > span:last-child, .netpri-btn:not(.netpri-st) .netpri-ip').forEach(function(el) {
				if (el.scrollWidth > el.clientWidth + 1) { two = true; }
			});
		}
		row.classList.toggle('netpri-2col', two);
		_npTwoCol = two;
	});
}
function npWatchFit() {
	window.requestAnimationFrame(npFitRow);
	window.setTimeout(npFitRow, 0);
	if (_npFitHooked) { return; }
	_npFitHooked = true;
	var pend = false;
	window.addEventListener('resize', function() {
		if (pend) { return; }
		pend = true;
		window.requestAnimationFrame(function() { pend = false; npFitRow(); });
	});
	try { document.fonts.ready.then(npFitRow); } catch (e) {}
}

function npSyncTheme() {
	var bar = document.querySelector('.netpribar');
	if (!bar || !bar.isConnected) { return; }
	bar.classList.toggle('netpri-dark', isDarkUI(bar));
}
var _npThemeWatched = false;
function npWatchTheme() {
	if (_npThemeWatched) { return; }
	_npThemeWatched = true;
	try {
		var obs = new MutationObserver(function() { window.setTimeout(npSyncTheme, 0); });
		obs.observe(document.documentElement, { attributes: true,
			attributeFilter: [ 'class', 'style', 'data-theme', 'data-darkmode' ] });
		if (document.body) {
			obs.observe(document.body, { attributes: true, attributeFilter: [ 'class', 'style' ] });
		}
		obs.observe(document.head, { childList: true });
	} catch (e) {}
	try {
		var mq = window.matchMedia('(prefers-color-scheme: dark)');
		if (mq.addEventListener) { mq.addEventListener('change', npSyncTheme); }
		else if (mq.addListener) { mq.addListener(npSyncTheme); }
	} catch (e) {}
}

return baseclass.extend({
	API: 30903,
	mount: function() {
		var wrap = E('div', { 'class': 'netpri-mount' });
		var redraw = function(l2) {
			var fresh = buildBar(l2, redraw);
			if (wrap.firstChild) { wrap.replaceChild(fresh, wrap.firstChild); }
			else { wrap.appendChild(fresh); }
			refreshStCard();
		};
		var apply = function(list) {
			if (_npDrag || _npApplying) { return; }
			if (list && (list.length || (list._ok && _npEmptyStreak >= 2))) { redraw(list); }
		};
		extip.init().then(function(fl) {
			if (!fl.inNetpri) { return; }
			extip.watch('');
			_npExtipSub = function() { if (_npDrag || _npApplying) { return; } redraw(lastList()); };
			extip.subscribe(_npExtipSub);
		});
		loadWidgetFlags().then(function() {
			redraw(lastList());
			_npRecheck = function() { L.resolveDefault(loadList()).then(apply); };
			_npRecheck();
			if (_widgets.speedtest) { stInit(); }
			if (_widgets.status) { pingInit(); }
			if (_widgets.services) {
				var _svcs = effectiveSvcs();
				_svcs.forEach(function(s) {
					var k = sscKindForSvc(s);
					if (k) { ssclashInit(k, redraw); ssclashStatusInit(k); }
				});
				svcStatusInit(_svcs);
			}
		});
		var seen = false;
		var pollFn = function() {
			if (document.body.contains(wrap)) { seen = true; }
			else if (seen) {
				window._npListPoll = false;
				poll.remove(pollFn);
				_npPollsStop();
				if (_npExtipSub) { extip.unsubscribe(_npExtipSub); _npExtipSub = null; }
				return Promise.resolve();
			}
			return loadList().then(apply);
		};
		if (!window._npListPoll) { window._npListPoll = true; poll.add(pollFn, 15); }
		return wrap;
	},

	renderBar: function() {
		var mk = function(list) {
			var wrap = E('div');
			var redraw = function(l2) {
				var fresh = buildBar(l2, redraw);
				if (wrap.firstChild) { wrap.replaceChild(fresh, wrap.firstChild); }
				else { wrap.appendChild(fresh); }
				refreshStCard();
			};
			redraw(list);
			extip.init().then(function(fl) {
				if (!fl.inNetpri) { return; }
				extip.watch('');
				extip.subscribe(function() { if (_npDrag || _npApplying) { return; } redraw(lastList()); });
			});
			if (_widgets.speedtest) { stInit(); }
			if (_widgets.status) { pingInit(); }
			if (_widgets.services) {
				var _svcs = effectiveSvcs();
				_svcs.forEach(function(s) {
					var k = sscKindForSvc(s);
					if (k) { ssclashInit(k, redraw); ssclashStatusInit(k); }
				});
				svcStatusInit(_svcs);
			}
			var pollFn = function() {
				if (!document.body.contains(wrap)) {
					window._npListPoll = false;
					poll.remove(pollFn); return Promise.resolve();
				}
				if (_npDrag || _npApplying) { return Promise.resolve(); }
				return loadList().then(redraw);
			};
			if (!window._npListPoll) { window._npListPoll = true; poll.add(pollFn, 15); }
			return { wrap: wrap, redraw: redraw };
		};
		return loadWidgetFlags().then(function() {
			var extra = _widgets.status || _widgets.services || _widgets.speedtest;
			var cached = lastList();
			if (cached.length || extra) {
				var b = mk(cached);
				loadList().then(function(l) {
					if (l && (l.length || (l._ok && _npEmptyStreak >= 2))) { b.redraw(l); }
				});
				return b.wrap;
			}
			return loadList().then(function(list) {
				if (!list.length && !extra) { return null; }
				return mk(list).wrap;
			});
		});
	},

	attach: function() {
		if (document.querySelector('.netpribar')) { return Promise.resolve(); }
		return this.renderBar().then(function(bar) {
			if (!bar || document.querySelector('.netpribar')) { return; }
			var tries = 0;
			(function place() {
				if (document.querySelector('.netpribar')) { return; }
				var mb = document.querySelector('.modembar');
				if (mb && mb.parentNode) { mb.parentNode.insertBefore(bar, mb.nextSibling); return; }
				var anchor = document.querySelector('#tabmenu')
					|| document.querySelector('ul.cbi-tabmenu')
					|| document.querySelector('.cbi-tabmenu');
				if (anchor && anchor.parentNode) { anchor.parentNode.insertBefore(bar, anchor); return; }
				if (tries++ < 20) { window.setTimeout(place, 150); return; }
				var c = document.querySelector('#maincontent') || document.querySelector('#view') || document.body;
				if (c) { c.insertBefore(bar, c.firstChild); }
			})();
		});
	}
});
