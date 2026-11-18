'use strict';
'require view';
'require ui';
'require dom';
'require fs';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

function loadCss() {
	if (!document.getElementById('tg-page-align-css')) {
		var p = document.createElement('link');
		p.id = 'tg-page-align-css'; p.rel = 'stylesheet';
		p.href = L.resource('view/modem5g/page-align.css');
		document.head.appendChild(p);
	}
	if (document.getElementById('tg-modem-css')) return;
	var l = document.createElement('link');
	l.id = 'tg-modem-css'; l.rel = 'stylesheet';
	l.href = L.resource('view/modem5g/modem.css');
	document.head.appendChild(l);
	probeCheckmark();
}

function probeCheckmark() {
	if (document.documentElement.hasAttribute('data-tg-checkprobe')) { return; }
	document.documentElement.setAttribute('data-tg-checkprobe', '1');
	var run = function() {
		var box = document.createElement('input');
		box.type = 'checkbox'; box.checked = true;
		box.style.cssText = 'position:absolute;left:-9999px;top:-9999px';
		document.body.appendChild(box);
		var broken = false;
		try {
			var cs = getComputedStyle(box, '::after');
			var mask = cs.maskImage || cs.webkitMaskImage || 'none';
			var bg = String(cs.backgroundColor || '');
			var transparent = (bg === 'transparent' || /rgba\(0,\s*0,\s*0,\s*0\)/.test(bg) || bg === '');
			broken = (mask !== 'none' && mask !== '' && cs.content !== 'none' && transparent);
		} catch (e) { broken = false; }
		box.remove();
		if (broken) { document.documentElement.classList.add('tg-fixcheck'); }
	};
	if (document.body) { setTimeout(run, 0); }
	else { document.addEventListener('DOMContentLoaded', function() { setTimeout(run, 0); }); }
}

var PHONE_MQ = '(max-width: 700px)';

var _qualRat = 'lte';
function qualSetMode(mode) {
	if (mode != null && mode !== '' && mode !== '-') { _qualRat = mutil.qualRat(mode); }
	return _qualRat;
}
function sinrUnmeasured(sinr, rsrq) {
	var s = String(sinr == null ? '' : sinr).trim(), q = String(rsrq == null ? '' : rsrq).trim();
	if (!/^-?[0-9]+(\.[0-9]+)?( ?dB)?$/.test(s) || parseFloat(s) !== 0) { return false; }
	if (!/^-?[0-9]+(\.[0-9]+)?( ?dB)?$/.test(q)) { return false; }
	return parseFloat(q) >= -14;
}
var QUAL_NAMES = [ 'red', 'orange', 'yellow', 'green' ];
var _QC = mutil.QUAL_COLOR || [], _QG = mutil.QUAL_GRAD || [];
var CA_COLOR = { red: _QC[0], orange: _QC[1], yellow: _QC[2], green: _QC[3] };
var CA_GRAD = { red: _QG[0], orange: _QG[1], yellow: _QG[2], green: _QG[3] };
function caQuality(key, v, rat) {
	var l = mutil.qualLevel(key, v, rat || _qualRat);
	return l == null ? null : QUAL_NAMES[l];
}
function metricPct(key, v, rat) {
	if (caQuality(key, v, rat) == null) { return null; }
	var pc = mutil.qualPct(key, v, rat || _qualRat);
	if (pc == null) { return null; }
	return pc < 4 ? 4 : pc;
}
// Number coloured by the signal quality scale of the Network page (tables, MIMO grid).
function paintMetricCell(el, key, v, text, rat) {
	var has = (v != null && v !== '' && v !== '-' && !isNaN(parseFloat(v)));
	var txt = has ? String(text != null ? text : v) : '-';
	var col = has ? caQuality(key, v, rat) : null;
	if (el.textContent !== txt) { el.textContent = txt; }
	el.style.color = col ? CA_COLOR[col] : '';
	el.classList.toggle('v', has);
}

var ICONS = {
	tower: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="1.3"/><path d="M15.89 4.11a5.5 5.5 0 0 1 0 7.78M8.11 4.11a5.5 5.5 0 0 0 0 7.78M18.36 1.64a9 9 0 0 1 0 12.72M5.64 1.64a9 9 0 0 0 0 12.72"/><path d="M12 9.5 7.5 22M12 9.5 16.5 22M10.2 14.5h3.6M8.8 18.5h6.4M6 22h12"/></g>',
	spk: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h4l5-4v14l-5-4H4Z"/><path d="M17 9a4 4 0 0 1 0 6M19.5 6.5a8 8 0 0 1 0 11"/></g>',
	mute: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h4l5-4v14l-5-4H4Z"/><path d="m17 9.5 5 5M22 9.5l-5 5"/></g>',
	target: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="4"/><circle cx="12" cy="12" r="1" fill="currentColor"/></g>',
	up: '<path d="M12 15V3M7 8l5-5 5 5M4 20.5h16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size) {
	var s = E('span', { 'class': 'tg-align-i' });
	s.innerHTML = svg(name, size);
	return s;
}

function isDarkUI(el) {
	var c = getComputedStyle(el || document.body).color;
	var m = String(c).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	if (!m) { return false; }
	return (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

var LINE_COLORS = [ '#2b8a3e', '#1c7ed6', '#e8590c', '#7048e8', '#c92a2a' ];
function hexToRgba(hex, a) {
	var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
	if (!m) return hex;
	return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' + parseInt(m[3], 16) + ',' + a + ')';
}
function drawChart(canvas, series, opts) {
	opts = opts || {};
	var dpr = window.devicePixelRatio || 1;
	var rect = canvas.getBoundingClientRect();
	if (!(rect.width > 0) || !(rect.height > 0)) return;
	var W = rect.width, H = rect.height;
	canvas.width = Math.floor(W * dpr); canvas.height = Math.floor(H * dpr);
	var ctx = canvas.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	var padL = 46, padR = 12, padT = 12, padB = 22;
	var dark = isDarkUI(canvas);
	var fg = dark ? '#c9ccd1' : '#444', grid = dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)';
	ctx.clearRect(0, 0, W, H);
	var all = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { all.push(p[1]); }); });
	if (!all.length) { ctx.fillStyle = fg; ctx.font = '12px sans-serif'; ctx.textAlign = 'center'; ctx.fillText(_('No data'), W / 2, H / 2); return; }
	var vmin = (opts.min != null) ? opts.min : Math.min.apply(null, all);
	var vmax = (opts.max != null) ? opts.max : Math.max.apply(null, all);
	if (vmax === vmin) vmax = vmin + 1;
	var tAll = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { tAll.push(p[0]); }); });
	var tmin = Math.min.apply(null, tAll), tmax = Math.max.apply(null, tAll);
	if (tmax === tmin) tmax = tmin + 1;
	var innerW = W - padL - padR, innerH = H - padT - padB;
	var x = function(t) { return padL + (t - tmin) / (tmax - tmin) * innerW; };
	var y = function(v) { return padT + (1 - (v - vmin) / (vmax - vmin)) * innerH; };
	ctx.strokeStyle = grid; ctx.fillStyle = fg; ctx.lineWidth = 1; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
	for (var i = 0; i <= 4; i++) {
		var v = vmin + (vmax - vmin) * i / 4, yy = Math.round(y(v)) + 0.5;
		ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(W - padR, yy); ctx.stroke();
		ctx.fillText(opts.fmt ? opts.fmt(v) : Math.round(v), padL - 6, yy + 3);
	}
	series.forEach(function(s, idx) {
		var pts = s.points || [];
		if (!pts.length) return;
		var col = s.color || LINE_COLORS[idx % LINE_COLORS.length];
		var tracePath = function() {
			for (var q = 0; q < pts.length; q++) {
				var qpx = x(pts[q][0]), qpy = y(pts[q][1]);
				if (q === 0) { ctx.moveTo(qpx, qpy); continue; }
				var ppx = x(pts[q - 1][0]), ppy = y(pts[q - 1][1]);
				ctx.quadraticCurveTo(ppx, ppy, (ppx + qpx) / 2, (ppy + qpy) / 2);
			}
			ctx.lineTo(x(pts[pts.length - 1][0]), y(pts[pts.length - 1][1]));
		};
		ctx.beginPath(); tracePath();
		ctx.lineTo(x(pts[pts.length - 1][0]), padT + innerH); ctx.lineTo(x(pts[0][0]), padT + innerH); ctx.closePath();
		var grad = ctx.createLinearGradient(0, padT, 0, padT + innerH);
		grad.addColorStop(0, hexToRgba(col, dark ? 0.38 : 0.28)); grad.addColorStop(1, hexToRgba(col, 0));
		ctx.fillStyle = grad; ctx.fill();
		ctx.strokeStyle = col; ctx.lineWidth = 1.8; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
		ctx.beginPath(); tracePath(); ctx.stroke();
	});
}

function fetchSnapshot(ttl) {
	var t = Math.max(1, Math.round(Number(ttl) || 4));
	var a = [ 'cached', String(t) ];
	if (pageModemPath) { a.push('for=' + pageModemPath); }
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', a), '').then(function(out) {
		var j = null; try { j = JSON.parse(out); } catch (e) {}
		return j;
	});
}
function parseAntports(raw) {
	var rx = [];
	String(raw || '').trim().split(/\s+/).forEach(function(l) {
		var m = /^(\d+):(-?\d+(?:\.\d+)?)?:(-?\d+(?:\.\d+)?)?(?::(-?\d+(?:\.\d+)?)?)?$/.exec(l);
		if (!m) return;
		var idx = parseInt(m[1], 10);
		rx[idx] = { rsrp: m[2], rsrq: m[3], rssi: m[4] };
	});
	return rx;
}

// collapsibleSection() of 5gdetail.js (same storage keys) with a summary on the right.
function collapsible(key, titleText, content, defOpen) {
	var open = defOpen, stored = null;
	try { stored = window.localStorage.getItem('5gm-blk-' + key); } catch (e) {}
	var known = (stored === '0' || stored === '1');
	if (known) { open = stored === '1'; }
	var chev = E('span', { 'class': 'tg-align-chev' });
	chev.innerHTML = svg('chev', 16);
	var sum = E('span', { 'class': 'tg-align-sum' }, '');
	var body = E('div', { 'class': 'tg-collapse' }, [ E('div', { 'class': 'tg-collapse-inner' }, content) ]);
	var title = E('h3', { 'class': 'tg-align-coll', 'role': 'button', 'tabindex': '0' }, [ chev, E('span', {}, titleText), sum ]);
	var blk = { sum: sum, known: known };
	blk.set = function(v, persist) {
		body.classList.toggle('open', v);
		chev.classList.toggle('open', v);
		title.classList.toggle('open', v);
		title.setAttribute('aria-expanded', String(v));
		if (persist) { blk.known = true; try { window.localStorage.setItem('5gm-blk-' + key, v ? '1' : '0'); } catch (e) {} }
	};
	title.addEventListener('click', function() { blk.set(!body.classList.contains('open'), true); });
	title.addEventListener('keydown', function(ev) {
		if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); blk.set(!body.classList.contains('open'), true); }
	});
	blk.set(open, false);
	blk.node = E('div', { 'class': 'cbi-section tg5g', 'data-blk': key }, [ title, body ]);
	return blk;
}

var pageModemPath = '';

return view.extend({
	load: function() { return fresh.check(40008, [ modemtabs, mutil ]); },

	render: function() {
		loadCss();
		try { pageModemPath = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) { pageModemPath = ''; }
		var isPhone = !!(window.matchMedia && window.matchMedia(PHONE_MQ).matches);

		var LS = {
			g: function(k, d) { try { var v = localStorage.getItem('align_' + k); return v === null ? d : v; } catch(e) { return d; } },
			s: function(k, v) { try { localStorage.setItem('align_' + k, v); } catch(e) {} },
			d: function(k) { try { localStorage.removeItem('align_' + k); } catch(e) {} },
			gj: function(k, d) { try { var v = localStorage.getItem('align_' + k); return v ? JSON.parse(v) : d; } catch(e) { return d; } },
			sj: function(k, v) { try { localStorage.setItem('align_' + k, JSON.stringify(v)); } catch(e) {} }
		};
		var st = {
			interval: parseFloat(LS.g('interval', '2')) || 2,
			cells: LS.gj('celllog', []), target: LS.gj('target', null),
			page: 0, pageSize: 15, hist: [], t: 0, lastSinr: null, online: true, timer: null, foreignN: 0
		};
		// A damaged log in localStorage must not break the page (renderTable calls sinr.toFixed).
		st.cells = (Array.isArray(st.cells) ? st.cells : []).filter(function(c) { return c && typeof c.sinr === 'number'; });
		var au = {
			on: LS.g('sndon', '0') === '1', ctx: null, geigerTimer: null, curSinr: 0, tone: null, toneGain: null, customBuf: null,
			vGeiger: parseFloat(LS.g('vGeiger', '0.5')), vTone: parseFloat(LS.g('vTone', '0.4')), vVoice: parseFloat(LS.g('vVoice', '1'))
		};
		function ac() { if (!au.ctx) au.ctx = new (window.AudioContext || window.webkitAudioContext)(); if (au.ctx.state === 'suspended') au.ctx.resume(); return au.ctx; }
		function click() {
			if (!au.on) return;
			var c = ac();
			if (au.customBuf) { var s = c.createBufferSource(), g = c.createGain(); s.buffer = au.customBuf; g.gain.value = au.vGeiger; s.connect(g); g.connect(c.destination); s.start(); return; }
			var o = c.createOscillator(), g = c.createGain(), p = c.createStereoPanner();
			o.type = 'sine'; o.frequency.value = 1800; g.gain.value = au.vGeiger * 0.15; p.pan.value = -0.8;
			o.connect(g); g.connect(p); p.connect(c.destination); o.start();
			setTimeout(function() { try { o.stop(); } catch(e) {} }, 14);
		}
		function stopGeiger() { if (au.geigerTimer) { clearTimeout(au.geigerTimer); au.geigerTimer = null; } }
		function geiger(sinr) {
			au.curSinr = sinr;
			if (!au.on || au.vGeiger === 0 || !st.online) { stopGeiger(); return; }
			if (au.geigerTimer) return;
			(function loop() {
				if (!au.on || au.vGeiger === 0 || !st.online || !root.isConnected) { au.geigerTimer = null; return; }
				click();
				var s = Math.max(0, Math.min(20, au.curSinr || 0));
				au.geigerTimer = setTimeout(loop, 1000 * Math.exp(-s / 8));
			})();
		}
		function stopTone() { if (au.tone) { try { au.tone.stop(); } catch(e) {} au.tone = null; au.toneGain = null; } }
		function tone(rsrp) {
			if (!au.on || au.vTone === 0 || !st.online || isNaN(rsrp) || rsrp >= 0) { stopTone(); return; }
			var c = ac(), f = Math.max(200, Math.min(2000, 200 + ((rsrp + 120) / 70) * 1800));
			if (au.tone) { au.tone.frequency.value = f; au.toneGain.gain.value = au.vTone * 0.12; return; }
			au.tone = c.createOscillator(); au.toneGain = c.createGain();
			var p = c.createStereoPanner(); p.pan.value = 0.8;
			au.tone.type = 'sine'; au.tone.frequency.value = f; au.toneGain.gain.value = au.vTone * 0.12;
			au.tone.connect(au.toneGain); au.toneGain.connect(p); p.connect(c.destination); au.tone.start();
		}
		function stopAudio() { stopGeiger(); stopTone(); }
		function speak(txt) {
			if (!au.on || !window.speechSynthesis || au.vVoice === 0) return;
			speechSynthesis.cancel();
			var m = new SpeechSynthesisUtterance(txt); m.lang = 'ru-RU'; m.volume = au.vVoice; m.rate = 0.85;
			speechSynthesis.speak(m);
		}

		/* ---------- header card ---------- */
		var mkPill = function(cls) { return E('span', { 'class': 'tg-align-pill off' + (cls ? ' ' + cls : ''), 'style': 'visibility:hidden' }, [ E('i'), E('span', {}, '') ]); };
		var hd = {
			mode: E('span', { 'class': 'tg-proto-badge', 'style': 'display:none' }, ''),
			band: E('span', { 'class': 'tg-proto-badge', 'style': 'display:none' }, ''),
			mimo: E('span', { 'class': 'tg-proto-badge', 'style': 'display:none' }, ''),
			pill: mkPill(), pillM: mkPill('tg-align-pillm'),
			ico: E('div', { 'class': 'tginfo-signal tg-align-ico off' }),
			reg: E('div', { 'class': 'tginfo-reg' }, _('Base station')),
			main: E('div', { 'class': 'tginfo-op tg-align-main none' }, ''),
			loc: E('div', { 'class': 'tginfo-loc' }, '')
		};
		hd.ico.innerHTML = svg('tower', 36);

		// How often the page polls the modem for a fresh reading (also the cache TTL of the snapshot).
		if (!(st.interval >= 0.5 && st.interval <= 10)) { st.interval = 2; }
		var ivlSteps = [ 0.5, 1, 2, 3, 5, 10 ];
		if (ivlSteps.indexOf(st.interval) < 0) { ivlSteps.push(st.interval); ivlSteps.sort(function(a, b) { return a - b; }); }
		var intervalSel = E('select', { 'class': 'cbi-input-select tg-align-ival', change: function(ev) {
			var v = parseFloat(ev.target.value);
			if (v >= 0.5 && v <= 10) { st.interval = v; LS.s('interval', v); restart(); paintTarget(); }
		} }, ivlSteps.map(function(v) {
			return E('option', { 'value': String(v) }, _('%s s').format(String(v)));
		}));
		intervalSel.value = String(st.interval);
		var sndBtn = E('button', { class: 'btn cbi-button tg-align-snd', click: function() {
			au.on = !au.on; LS.s('sndon', au.on ? '1' : '0'); paintSndBtn();
			if (au.on) { ac(); speak(_('Sound on')); geiger(au.curSinr || 0); } else { stopAudio(); }
		} });
		function paintSndBtn() {
			dom.content(sndBtn, [ icon(au.on ? 'spk' : 'mute', 16), au.on ? _('Sound: on') : _('Sound: off') ]);
			sndBtn.classList.toggle('cbi-button-positive', au.on);
		}
		paintSndBtn();
		var head = E('div', { 'class': 'cbi-section tg5g tg-pg-head tg-align-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-align-title' }, [ E('span', {}, _('Antenna alignment')), hd.mode, hd.band, hd.mimo, hd.pillM ]),
			E('div', { 'class': 'tginfo-general' }, [
				hd.ico,
				E('div', { 'class': 'tginfo-status' }, [ hd.reg, hd.main, hd.loc ]),
				E('div', { 'class': 'tginfo-right' }, [
					hd.pill,
					E('div', { 'class': 'tg-align-ctl' }, [
						sndBtn,
						E('label', { 'class': 'tg-align-ivl' }, [ _('Refresh every'), intervalSel ])
					])
				])
			])
		]);

		/* ---------- big tiles ---------- */
		function metric(label, hint, key, unit) {
			var t = { key: key, unit: unit, now: E('span', {}, '-'), u: E('small', {}, ''), trend: E('span', { 'class': 'tg-align-trend' }, '') };
			t.val = E('div', { 'class': 'tg-hist-now dash' }, [ t.now, ' ', t.u ]);
			t.fill = E('div', { 'class': 'tg-mbar-fill' });
			t.bar = E('div', { 'class': 'tg-mbar', 'style': 'visibility:hidden' }, E('div', { 'class': 'tg-mbar-t' }, t.fill));
			t.node = E('div', { 'class': 'tg-hist-card' }, [
				E('div', { 'class': 'tg-hist-h' }, [ E('span', { 'class': 'tg-hist-name' }, E('b', {}, label)), t.trend ]),
				t.val, t.bar,
				E('div', { 'class': 'tg-hist-f' }, E('span', {}, hint))
			]);
			return t;
		}
		var QT = mutil.QUAL_T.lte;
		var mSinr = metric('SINR', _('signal-to-noise · good from %d dB').format(QT.sinr[1]), 'sinr', 'dB');
		var mRsrq = metric('RSRQ', _('cell quality · good from %d dB').format(QT.rsrq[1]), 'rsrq', 'dB');
		var mRsrp = metric('RSRP', _('signal power · good from %d dBm').format(QT.rsrp[1]), 'rsrp', 'dBm');
		var mRssi = metric('RSSI', _('overall level'), 'rssi', 'dBm');
		function setMetric(mo, v, trend) {
			var has = (v != null && !isNaN(parseFloat(v)));
			mo.now.textContent = has ? String(v) : '-';
			mo.u.textContent = has ? mo.unit : '';
			mo.val.classList.toggle('dash', !has);
			var col = has ? caQuality(mo.key, v) : null, pc = col ? metricPct(mo.key, v) : null;
			mo.val.style.color = col ? CA_COLOR[col] : '';
			if (pc == null) { mo.bar.style.visibility = 'hidden'; }
			else { mo.bar.style.visibility = ''; mo.fill.style.width = pc + '%'; mo.fill.style.background = CA_GRAD[col] || CA_COLOR[col]; }
			mo.trend.textContent = trend || '';
			mo.trend.className = 'tg-align-trend' + (trend ? (trend.charAt(0) === '▲' ? ' up' : ' down') : '');
			if (mo.key === 'sinr') { mo.node.style.borderColor = col ? CA_COLOR[col] : ''; }
		}
		var bigTiles = E('div', { 'class': 'tg-align-big' }, [ mSinr.node, mRsrq.node, mRsrp.node, mRssi.node ]);

		/* ---------- MIMO ---------- */
		var rxRsrp = [], rxRsrq = [];
		for (var i = 0; i < 4; i++) { rxRsrp.push(E('div', {}, '-')); rxRsrq.push(E('div', {}, '-')); }
		var mimoTitle = E('h3', {}, 'MIMO: --');
		var mimoSpread = E('span', {}, '');
		var mimoBal = E('span', { 'class': 'tg-align-pill off', 'style': 'display:none' }, [ E('i'), E('span', {}, '') ]);
		function rxLine(lbl, arr) { return [ E('div', { class: 'l' }, lbl) ].concat(arr); }
		var mimoSec = E('div', { class: 'cbi-section tg5g' }, [
			mimoTitle,
			E('div', { 'class': 'tg-align-bal' }, [ mimoSpread, mimoBal ]),
			E('div', { class: 'tg-align-rx' }, []
				.concat([ E('div', {}, ''), E('div', { class: 'h' }, 'RX0'), E('div', { class: 'h' }, 'RX1'), E('div', { class: 'h' }, 'RX2'), E('div', { class: 'h' }, 'RX3') ])
				.concat(rxLine('RSRP', rxRsrp)).concat(rxLine('RSRQ', rxRsrq)))
		]);

		/* ---------- best cells ---------- */
		var tbody = E('tbody');
		var pageInfo = E('span', { class: 'grow tg-align-hint' }, '');
		var btnPrev = E('button', { class: 'btn cbi-button', click: function() { if (st.page > 0) { st.page--; renderTable(); } } }, '◀');
		var btnNext = E('button', { class: 'btn cbi-button', click: function() { var tp = Math.ceil(st.cells.length / st.pageSize); if (st.page < tp - 1) { st.page++; renderTable(); } } }, '▶');
		var btnReset = E('button', { class: 'btn cbi-button cbi-button-negative', click: function() { st.cells = []; st.page = 0; st.target = null; LS.d('celllog'); LS.d('target'); renderTable(); paintTarget(); speak(_('Log cleared')); } }, [ icon('trash', 15), _('Clear the log') ]);
		var logSec = E('div', { class: 'cbi-section tg5g' }, [
			E('h3', {}, _('Best cells (by SINR)')),
			E('div', { class: 'cbi-section-descr tg-align-hint', style: 'margin-bottom:6px' }, _('Click a row to set the target cell')),
			E('table', { class: 'tg-align-tbl' }, [
				E('thead', {}, E('tr', {}, [ E('th', {}, '#'), E('th', {}, 'eNB'), E('th', {}, _('Sector')), E('th', {}, 'RSRP'), E('th', {}, 'SINR'), E('th', { 'class': 'hm' }, _('Time')) ])),
				tbody
			]),
			E('div', { 'class': 'tg-align-actions', 'style': 'margin-top:10px' }, [ pageInfo, btnPrev, btnNext, btnReset ])
		]);
		function sortedCells() { return st.cells.slice().sort(function(a, b) { return b.sinr - a.sinr; }); }
		function renderTable() {
			var s = sortedCells(), tp = Math.max(1, Math.ceil(s.length / st.pageSize));
			if (st.page >= tp) st.page = tp - 1; if (st.page < 0) st.page = 0;
			var start = st.page * st.pageSize;
			pageInfo.textContent = s.length ? (_('Page') + ' ' + (st.page + 1) + '/' + tp + ' (' + s.length + ')') : '';
			btnPrev.style.display = btnNext.style.display = (tp > 1) ? '' : 'none';
			btnReset.style.display = s.length ? '' : 'none';
			if (!s.length) {
				dom.content(tbody, E('tr', {}, E('td', { 'colspan': '6', 'class': 'tg-align-hint' }, _('No data yet'))));
				return;
			}
			dom.content(tbody, s.slice(start, start + st.pageSize).map(function(e, i) {
				var isT = st.target && st.target.enb === e.enb && st.target.pci === e.pci;
				var rsrpTd = E('td', {}), sinrTd = E('td', { 'class': 'b' });
				paintMetricCell(rsrpTd, 'rsrp', e.rsrp, e.rsrp + ' dBm');
				paintMetricCell(sinrTd, 'sinr', e.sinr, e.sinr.toFixed(1));
				var num = E('td', {}, String(start + i + 1));
				if (isT) { num.appendChild(icon('target', 13)); }
				return E('tr', { class: 'pick' + (isT ? ' tgt' : ''), click: function() {
					if (isT) { st.target = null; LS.d('target'); speak(_('Target cleared')); }
					else { st.target = { enb: e.enb, pci: e.pci }; LS.sj('target', st.target); speak(_('Target') + ' ' + e.enb + ' ' + _('sector') + ' ' + e.pci); }
					renderTable(); paintTarget();
				} }, [ num, E('td', { 'class': 'mono' }, [ String(e.enb) ]), E('td', {}, [ String(e.pci) ]), rsrpTd, sinrTd, E('td', { class: 'hm tg-align-hint' }, [ String(e.time || '--') ]) ]);
			}));
		}

		/* ---------- chart ---------- */
		var canvas = E('canvas', { 'class': 'tg-align-chart' });
		function draw() {
			var col = CA_COLOR[caQuality('sinr', st.lastSinr)] || null;
			drawChart(canvas, [ { name: 'SINR', points: st.hist, color: col } ], { min: -5, max: 25, fmt: function(v) { return Math.round(v) + ' dB'; } });
		}
		var chartSec = E('div', { class: 'cbi-section tg5g' }, [ E('h3', {}, _('SINR over the last 30 seconds')), canvas ]);
		if (window.ResizeObserver) {
			var rof = 0;
			new ResizeObserver(function() {
				if (rof) return;
				rof = window.requestAnimationFrame(function() { rof = 0; if (canvas.isConnected) draw(); });
			}).observe(canvas);
		} else {
			window.addEventListener('resize', function() { if (canvas.isConnected) draw(); });
		}

		/* ---------- sound ---------- */
		var sndSum = function() {
			return [ [ _('Geiger (SINR)'), au.vGeiger ], [ _('RSRP tone'), au.vTone ], [ _('Voice'), au.vVoice ] ]
				.map(function(p) { return p[0] + ' ' + Math.round(p[1] * 100) + '%'; }).join(' · ');
		};
		var soundBlk = null;
		function sliderRow(label, key, val, onChange) {
			var vEl = E('span', { class: 'tg-align-hint' }, Math.round(val * 100) + '%');
			var inp = E('input', { type: 'range', min: 0, max: 100, value: val * 100, 'aria-label': label, input: function(ev) {
				var v = parseInt(ev.target.value) / 100; vEl.textContent = Math.round(v * 100) + '%'; LS.s(key, v); onChange(v);
				if (soundBlk) soundBlk.sum.textContent = sndSum();
			} });
			return E('div', { class: 'tg-align-sli' }, [ E('label', {}, label), inp, vEl ]);
		}
		function loadCustom(dataUrl) {
			try { var b = atob(dataUrl.split(',')[1]); var buf = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) buf[i] = b.charCodeAt(i); ac().decodeAudioData(buf.buffer, function(d) { au.customBuf = d; }); } catch(e) {}
		}
		var fileInput = E('input', { type: 'file', accept: 'audio/*', style: 'display:none', change: function(ev) {
			var f = ev.target.files[0]; if (!f) return;
			if (f.size > 1500000) { ui.addNotification(null, E('p', _('The file is too big (up to ~1.5 MB)')), 'warning'); return; }
			var r = new FileReader();
			r.onload = function() { LS.s('customsnd', r.result); loadCustom(r.result); ui.addNotification(null, E('p', _('Custom sound loaded')), 'info'); };
			r.readAsDataURL(f);
		} });
		var snd0 = LS.g('customsnd', ''); if (snd0) loadCustom(snd0);
		soundBlk = collapsible('alsnd', _('Sound'), [
			sliderRow(_('Geiger (SINR)'), 'vGeiger', au.vGeiger, function(v) { au.vGeiger = v; }),
			sliderRow(_('RSRP tone'), 'vTone', au.vTone, function(v) { au.vTone = v; }),
			sliderRow(_('Voice'), 'vVoice', au.vVoice, function(v) { au.vVoice = v; }),
			E('div', { 'class': 'tg-align-actions', 'style': 'margin-top:8px' }, [
				E('button', { class: 'btn cbi-button', click: function() { fileInput.click(); } }, [ icon('up', 15), _('Upload a custom sound') ]),
				E('button', { class: 'btn cbi-button', click: function() { var was = au.on; au.on = true; click(); au.on = was; } }, [ icon('spk', 15), _('Preview') ]),
				E('button', { class: 'btn cbi-button', click: function() { au.customBuf = null; LS.d('customsnd'); ui.addNotification(null, E('p', _('Back to the default sound')), 'info'); } }, _('Default sound')),
				fileInput
			])
		], false);
		soundBlk.sum.textContent = sndSum();

		/* ---------- how to use it ---------- */
		var step = function(n, txt) { return [ E('b', {}, String(n)), E('span', {}, txt) ]; };
		var howBlk = collapsible('alhow', _('How to use it'), [
			E('p', { 'class': 'cbi-section-descr', 'style': 'margin:0 0 8px' },
				_('An outdoor or directional antenna works best when it points precisely at a base station. This page shows the signal live, every few seconds, so you can turn the antenna and see at once whether it got better or worse.')),
			E('div', { 'class': 'tg-align-step' }, [].concat(
				step(1, _('Watch SINR first: it decides the speed. RSRP and RSRQ help confirm the direction.')),
				step(2, _('Turn the antenna slowly, a few degrees at a time, and wait for a couple of readings after each step.')),
				step(3, _('Turn on the sound to follow the signal without looking at the screen: the faster the clicks, the better.')),
				step(4, _('The table of best cells remembers where the signal was strongest; click a row to make that cell the target.')),
				step(5, _('When the numbers stop improving, fix the antenna in the best position.'))
			))
		], true);
		// Without a stored choice the instructions stay open until the first reading arrives.
		var howAuto = !howBlk.known;

		/* ---------- live updates ---------- */
		var lastCell = { enb: '', pci: '', earfcn: '' };
		function paintTarget() {
			var parts = [];
			if (st.target) { parts.push(_('Target') + ': ' + _('BS') + ' ' + st.target.enb + ', ' + _('sector') + ' ' + st.target.pci); }
			hd.loc.textContent = parts.join(' · ');
			var isT = st.target && lastCell.enb && st.target.enb === lastCell.enb && st.target.pci === lastCell.pci;
			hd.main.classList.toggle('tgt', !!isT);
		}
		function setPill(kind, text) {
			[ hd.pill, hd.pillM ].forEach(function(p) {
				p.className = 'tg-align-pill ' + kind + (p === hd.pillM ? ' tg-align-pillm' : '');
				p.style.visibility = text ? '' : 'hidden';
				p.lastChild.textContent = text || '';
			});
		}
		function setBadge(el, txt) { el.textContent = txt || ''; el.style.display = txt ? '' : 'none'; }

		function updateRx(rx) {
			var vals = [];
			for (var i = 0; i < 4; i++) {
				var r = rx[i];
				paintMetricCell(rxRsrp[i], 'rsrp', r ? r.rsrp : null, r && r.rsrp != null ? r.rsrp : '-');
				paintMetricCell(rxRsrq[i], 'rsrq', r ? r.rsrq : null, r && r.rsrq != null ? r.rsrq : '-');
				if (r && r.rsrp != null && !isNaN(parseFloat(r.rsrp))) vals.push(parseFloat(r.rsrp));
			}
			var n = vals.length;
			mimoTitle.textContent = 'MIMO: ' + (n ? (n + 'x' + n) : '--');
			setBadge(hd.mimo, n >= 2 ? 'MIMO ' + n + 'x' + n : '');
			if (n >= 2) {
				var d = Math.round((Math.max.apply(null, vals) - Math.min.apply(null, vals)) * 10) / 10;
				var lv = d <= 3 ? 3 : d <= 6 ? 2 : d <= 10 ? 1 : 0;
				var lbl = [ _('poor'), _('fair'), _('good'), _('excellent') ][lv];
				mimoSpread.textContent = _('RX spread') + ': ' + d + ' dB';
				mimoBal.className = 'tg-align-pill ' + (lv >= 2 ? 'ok' : lv === 1 ? 'warn' : 'bad');
				mimoBal.lastChild.textContent = _('balance') + ': ' + lbl;
				mimoBal.style.display = '';
			} else { mimoSpread.textContent = ''; mimoBal.style.display = 'none'; }
		}
		function logCell(enb, pci, rsrp, sinr) {
			if (enb == null || enb === '' || enb === '-' || isNaN(sinr)) return;
			var now = new Date();
			var ts = [ now.getHours(), now.getMinutes(), now.getSeconds() ].map(function(x) { return (x < 10 ? '0' : '') + x; }).join(':');
			for (var i = 0; i < st.cells.length; i++) {
				if (st.cells[i].enb === enb && st.cells[i].pci === pci) {
					if (sinr > st.cells[i].sinr) { st.cells[i].sinr = sinr; st.cells[i].rsrp = rsrp; st.cells[i].time = ts; LS.sj('celllog', st.cells); return true; }
					return false;
				}
			}
			st.cells.push({ enb: enb, pci: pci, rsrp: rsrp, sinr: sinr, time: ts });
			LS.sj('celllog', st.cells);
			return true;
		}
		function showOffline() {
			hd.ico.className = 'tginfo-signal tg-align-ico off';
			hd.reg.textContent = _('Base station');
			hd.main.textContent = _('No data');
			hd.main.classList.add('none');
			hd.loc.textContent = _('Waiting for the active modem. If the selected modem is not the active one, switch to it in the modem bar.');
			setPill('off', '');
			setBadge(hd.mode, ''); setBadge(hd.band, '');
		}

		function apply(j) {
			if (j.error === 'not_active' || (j.path && pageModemPath && String(j.path) !== pageModemPath)) {
				if (++st.foreignN >= 3) { st.foreignN = 0; try { window.sessionStorage.removeItem('5gm-tab'); } catch(e) {} pageModemPath = ''; }
				return;
			}
			st.foreignN = 0;
			qualSetMode(j.mode);
			var sinr = sinrUnmeasured(j.sinr, j.rsrq) ? NaN : parseFloat(j.sinr), rsrp = parseInt(j.rsrp, 10), rsrq = parseInt(j.rsrq, 10);
			var rssiRaw = (j.rssi != null && j.rssi !== '') ? j.rssi : '';
			var online = !isNaN(rsrp) || !isNaN(sinr) || !!(j.modem && j.modem.length > 1);
			st.online = online;
			if (!online) {
				stopAudio();
				[ mSinr, mRsrp, mRsrq, mRssi ].forEach(function(mo) { setMetric(mo, null); });
				updateRx([]);
				showOffline();
				return;
			}
			if (howAuto) { howAuto = false; if (!howBlk.known) howBlk.set(false, false); }
			au.curSinr = sinr;
			var trend = '';
			if (st.lastSinr !== null && !isNaN(sinr)) {
				var d = Math.round((sinr - st.lastSinr) * 10) / 10;
				trend = d > 0.3 ? '▲ ' + d.toFixed(1) : d < -0.3 ? '▼ ' + Math.abs(d).toFixed(1) : '';
			}
			if (!isNaN(sinr)) st.lastSinr = sinr;
			setMetric(mSinr, isNaN(sinr) ? null : sinr.toFixed(1), trend);
			setMetric(mRsrp, isNaN(rsrp) ? null : rsrp);
			setMetric(mRsrq, isNaN(rsrq) ? null : rsrq);
			mutil.qualRssiCap(isNaN(rsrq) ? null : rsrq);
			setMetric(mRssi, (rssiRaw == null || rssiRaw === '') ? null : parseInt(rssiRaw, 10));

			var enb = (j.enbid != null && j.enbid !== '' && j.enbid !== '-') ? String(j.enbid) : '';
			var pci = (j.pci != null && j.pci !== '') ? String(j.pci) : '';
			var earfcn = (j.earfcn != null && j.earfcn !== '' && j.earfcn !== '-') ? String(j.earfcn) : '';
			lastCell = { enb: enb, pci: pci, earfcn: earfcn };
			var lvl = isNaN(sinr) ? null : mutil.qualLevel('sinr', sinr, _qualRat);
			hd.ico.className = 'tginfo-signal tg-align-ico ' + (lvl == null ? 'off' : lvl >= 2 ? 'ok' : lvl === 1 ? 'warn' : 'bad');
			hd.main.classList.remove('none');
			hd.main.textContent = _('BS') + ' ' + (enb || '--') + ' · ' + _('sector') + ' ' + (pci || '--') + ' · EARFCN ' + (earfcn || '--');
			setPill(lvl == null ? 'off' : lvl >= 2 ? 'ok' : lvl === 1 ? 'warn' : 'bad',
				lvl == null ? '' : [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][lvl]);
			setBadge(hd.mode, j.mode ? String(j.mode).split('|')[0].trim() : '');
			var band = '';
			try { band = String(mutil.caSplitBand(j.pband).band || '').replace(/\s*\(.*$/, '').trim(); } catch (e) { band = ''; }
			setBadge(hd.band, band && band !== '-' ? band : '');
			paintTarget();

			updateRx(parseAntports(j.antports));
			// Rebuild the table only when the log changed, not on every tick.
			if (enb && !isNaN(sinr) && logCell(enb, pci, isNaN(rsrp) ? '-' : rsrp, sinr)) { renderTable(); }
			if (!isNaN(sinr)) { st.t += st.interval; st.hist.push([ st.t, sinr ]); if (st.hist.length > 30) st.hist.shift(); draw(); geiger(sinr); tone(rsrp); }
		}

		function tick() {
			if (!root.isConnected) { clearInterval(st.timer); stopAudio(); return; }
			if (document.hidden) return;
			if (st.busy) return;
			st.busy = true;
			fetchSnapshot(st.interval).then(function(j) {
				st.busy = false;
				if (root.isConnected && !document.hidden && j) apply(j);
			}).catch(function() { st.busy = false; });
		}
		function restart() { if (st.timer) clearInterval(st.timer); st.timer = setInterval(tick, st.interval * 1000); }

		window.__5gmInPlaceSwitch = function(path) {
			pageModemPath = String(path || '');
			st.hist = []; st.lastSinr = null; st.foreignN = 0;
			draw(); tick();
		};
		document.addEventListener('visibilitychange', function() { if (document.hidden) stopAudio(); });

		var root = E('div', { 'class': 'tg-align' }, [
			head,
			bigTiles,
			E('div', { 'class': 'tg-align-grid' }, [ chartSec, mimoSec ]),
			logSec,
			soundBlk.node,
			howBlk.node
		]);

		showOffline();
		hd.loc.textContent = _('Waiting for the active modem. If the selected modem is not the active one, switch to it in the modem bar.');
		[ mSinr, mRsrp, mRsrq, mRssi ].forEach(function(mo) { setMetric(mo, null); });
		renderTable();
		modemtabs.attach();
		setTimeout(function() { draw(); tick(); restart(); }, 0);
		return root;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
