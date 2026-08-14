'use strict';
'require view';
'require ui';
'require dom';
'require fs';
'require view.modem5g.modemtabs as modemtabs';

function loadCss() {
	if (document.getElementById('tg-modem-css')) return;
	var l = document.createElement('link');
	l.id = 'tg-modem-css'; l.rel = 'stylesheet';
	l.href = L.resource('view/modem5g/modem.css');
	document.head.appendChild(l);
}

var IS_PROTON = (function() {
	var base = String((window.L && L.env && L.env.mediaurlbase) || '');
	if (/proton2025/.test(base)) return true;
	return !!document.querySelector('link[href*="proton2025"]');
})();

var CA_COLOR = { green: '#2fb885', orange: '#c99a3f', red: '#d95c5c' };
var CA_GRAD = {
	green:  'linear-gradient(90deg, #2fb885, #34d399)',
	orange: 'linear-gradient(90deg, #c99a3f, #e6b84c)',
	red:    'linear-gradient(90deg, #d95c5c, #f87171)'
};
var METRIC_RANGE = { rsrp: [ -125, -70 ], rsrq: [ -20, -5 ], rssi: [ -100, -60 ], sinr: [ -5, 25 ] };

function caQuality(key, v) {
	v = parseFloat(v);
	if (isNaN(v)) return null;
	switch (key) {
		case 'rsrp': return v >= -80 ? 'green' : (v >= -100 ? 'orange' : 'red');
		case 'rsrq': return v >= -10 ? 'green' : (v >= -15 ? 'orange' : 'red');
		case 'sinr': return v >= 20 ? 'green' : (v >= 0 ? 'orange' : 'red');
		case 'rssi': return v >= -65 ? 'green' : (v >= -85 ? 'orange' : 'red');
	}
	return null;
}
function metricPct(key, v) {
	var r = METRIC_RANGE[key], n = parseFloat(v);
	if (!r || isNaN(n)) return null;
	var pc = Math.round(100 * (n - r[0]) / (r[1] - r[0]));
	if (pc < 4) pc = 4;
	if (pc > 100) pc = 100;
	return pc;
}
function paintMetricCell(td, key, v, text) {
	var has = (v != null && v !== '' && v !== '-');
	var txt = has ? String(text != null ? text : v) : '-';
	var col = has ? caQuality(key, v) : null;
	var pc  = col ? metricPct(key, v) : null;
	if (IS_PROTON) {
		if (pc != null) {
			var pb = td.querySelector('.cbi-progressbar');
			if (!pb) { td.textContent = ''; pb = E('div', { 'class': 'cbi-progressbar' }, [ E('div', { 'style': 'box-shadow:none' }) ]); td.appendChild(pb); }
			pb.setAttribute('title', txt);
			var pf = pb.firstElementChild;
			pf.style.width = pc + '%'; pf.style.background = CA_GRAD[col] || CA_COLOR[col];
			return;
		}
		td.textContent = txt;
		return;
	}
	var tn = td.firstChild;
	if (!tn || tn.nodeType !== 3) { td.textContent = ''; tn = document.createTextNode(''); td.appendChild(tn); }
	tn.nodeValue = txt;
	td.style.color = col ? CA_COLOR[col] : '';
	td.style.fontWeight = col ? '600' : '';
	var bar = td.querySelector('.metric-bar');
	if (pc != null) {
		if (!bar) { bar = E('div', { 'class': 'metric-bar' }, [ E('div', {}) ]); td.appendChild(bar); }
		var bf = bar.firstElementChild;
		bf.style.width = pc + '%'; bf.style.background = CA_GRAD[col] || CA_COLOR[col];
	} else if (bar) { bar.parentNode.removeChild(bar); }
}

var LINE_COLORS = [ '#1c7ed6', '#2b8a3e', '#e8590c', '#7048e8', '#c92a2a' ];
function hexToRgba(hex, a) {
	var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
	if (!m) return hex;
	return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' + parseInt(m[3], 16) + ',' + a + ')';
}
function drawChart(canvas, series, opts) {
	opts = opts || {};
	var dpr = window.devicePixelRatio || 1;
	var rect = canvas.getBoundingClientRect();
	var W = Math.max(1, rect.width || canvas.clientWidth || 600), H = Math.max(1, rect.height || 190);
	canvas.width = Math.floor(W * dpr); canvas.height = Math.floor(H * dpr);
	var ctx = canvas.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	var padL = 46, padR = 12, padT = 12, padB = 22;
	var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
	var fg = dark ? '#c9ccd1' : '#444', grid = dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)';
	ctx.clearRect(0, 0, W, H);
	var all = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { all.push(p[1]); }); });
	if (!all.length) { ctx.fillStyle = fg; ctx.font = '12px sans-serif'; ctx.textAlign = 'center'; ctx.fillText(_('Нет данных'), W / 2, H / 2); return; }
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
		var col = LINE_COLORS[idx % LINE_COLORS.length];
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

function fetchSnapshot() {
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '4' ]), '').then(function(out) {
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

var pageModemPath = '';

return view.extend({
	load: function() { return Promise.resolve(); },

	render: function() {
		loadCss();
		try { pageModemPath = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) { pageModemPath = ''; }

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
			page: 0, pageSize: 5, hist: [], t: 0, lastSinr: null, online: true, timer: null, foreignN: 0
		};
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

		var css = '' +
			'.al-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px 26px}' +
			'.al-head{display:flex;flex-wrap:wrap;gap:4px 22px;font-size:15px;font-weight:600;margin-bottom:12px}' +
			'.al-lbl{font-size:11px;letter-spacing:.04em;text-transform:uppercase;opacity:.65;font-weight:600}' +
			'.al-cell{margin-top:6px;font-size:18px;font-weight:700}' +
			'.al-hint{font-size:11px;opacity:.6;margin-top:1px}' +
			'.al-rx{display:grid;grid-template-columns:60px repeat(4,1fr);gap:5px 8px;font-size:13px;text-align:center;align-items:center}' +
			'.al-rx .l{text-align:left;opacity:.65;font-weight:600}' +
			'.al-rx .h{opacity:.55;font-size:11px}' +
			'.al-tbl{width:100%;border-collapse:collapse;font-size:13px}' +
			'.al-tbl th{opacity:.6;font-weight:600;font-size:11px;text-align:left;padding:4px 6px}' +
			'.al-tbl td{padding:5px 6px;border-top:1px solid rgba(128,128,128,.18)}' +
			'.al-tbl tr.pick{cursor:pointer}.al-tbl tr.tgt td{font-weight:700}' +
			'.al-sli{display:flex;align-items:center;gap:10px;margin:6px 0}' +
			'.al-sli label{min-width:180px;font-weight:600;font-size:14px}' +
			'.al-sli input[type=range]{flex:1;max-width:240px}' +
			'.al-sndbtn{font-size:15px;font-weight:700;padding:8px 16px}';
		var style = E('style', { type: 'text/css' }, css);

		var bs = E('span'), sec = E('span'), earfcn = E('span'), mode = E('span');
		var head = E('div', { class: 'al-head' }, [ bs, sec, earfcn, mode ]);

		function metric(label, hint, key, unit) {
			var cell = E('div', { class: 'al-cell' });
			var node = E('div', {}, [ E('div', { class: 'al-lbl' }, label), cell, E('div', { class: 'al-hint' }, hint) ]);
			return { node: node, cell: cell, key: key, unit: unit };
		}
		var mSinr = metric('SINR', _('сигнал/шум · желательно >10 dB'), 'sinr', ' dB');
		var mRsrp = metric('RSRP', _('мощность LTE · лучше -95 dBm'), 'rsrp', ' dBm');
		var mRsrq = metric('RSRQ', _('качество соты · лучше -10 dB'), 'rsrq', ' dB');
		var mRssi = metric('RSSI', _('общий уровень'), 'rssi', ' dBm');
		function setMetric(mo, v, arrow) {
			var has = (v != null && !isNaN(parseFloat(v)));
			paintMetricCell(mo.cell, mo.key, has ? v : null, has ? (v + mo.unit + (arrow || '')) : '-');
		}
		var metricSec = E('div', { class: 'cbi-section' }, [ head, E('div', { class: 'al-grid' }, [ mSinr.node, mRsrq.node, mRsrp.node, mRssi.node ]) ]);

		var rxRsrp = [], rxRsrq = [];
		for (var i = 0; i < 4; i++) { rxRsrp.push(E('div', {}, '-')); rxRsrq.push(E('div', {}, '-')); }
		var mimoTitle = E('h3', {}, 'MIMO: --');
		var mimoBal = E('div', { class: 'al-hint', style: 'margin-bottom:8px' }, '');
		function rxLine(lbl, arr) { return [ E('div', { class: 'l' }, lbl) ].concat(arr); }
		var mimoSec = E('div', { class: 'cbi-section' }, [
			mimoTitle, mimoBal,
			E('div', { class: 'al-rx' }, []
				.concat([ E('div', {}, ''), E('div', { class: 'h' }, 'RX0'), E('div', { class: 'h' }, 'RX1'), E('div', { class: 'h' }, 'RX2'), E('div', { class: 'h' }, 'RX3') ])
				.concat(rxLine('RSRP', rxRsrp)).concat(rxLine('RSRQ', rxRsrq)))
		]);

		var tbody = E('tbody');
		var pageInfo = E('span', { class: 'al-hint' }, '');
		var btnPrev = E('button', { class: 'btn cbi-button', click: function() { if (st.page > 0) { st.page--; renderTable(); } } }, '◀');
		var btnNext = E('button', { class: 'btn cbi-button', click: function() { var tp = Math.ceil(st.cells.length / st.pageSize); if (st.page < tp - 1) { st.page++; renderTable(); } } }, '▶');
		var btnReset = E('button', { class: 'btn cbi-button cbi-button-negative', click: function() { st.cells = []; st.page = 0; st.target = null; LS.d('celllog'); LS.d('target'); renderTable(); speak('Лог сброшен'); } }, _('Сбросить лог'));
		var logSec = E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('Лучшие соты (по SINR)')),
			E('div', { class: 'al-hint', style: 'margin-bottom:8px;font-style:italic' }, _('Клик по строке — выбрать целевую соту')),
			E('table', { class: 'al-tbl' }, [
				E('thead', {}, E('tr', {}, [ E('th', {}, '#'), E('th', {}, 'eNB'), E('th', {}, _('Сектор')), E('th', {}, 'RSRP'), E('th', {}, 'SINR'), E('th', {}, _('Время')) ])),
				tbody
			]),
			E('div', { style: 'display:flex;gap:8px;align-items:center;justify-content:center;margin-top:8px' }, [ btnPrev, pageInfo, btnNext ]),
			E('div', { style: 'margin-top:8px' }, [ btnReset ])
		]);
		function sortedCells() { return st.cells.slice().sort(function(a, b) { return b.sinr - a.sinr; }); }
		function renderTable() {
			var s = sortedCells(), tp = Math.max(1, Math.ceil(s.length / st.pageSize));
			if (st.page >= tp) st.page = tp - 1; if (st.page < 0) st.page = 0;
			var start = st.page * st.pageSize;
			pageInfo.textContent = _('Стр.') + ' ' + (st.page + 1) + '/' + tp + ' (' + s.length + ')';
			btnPrev.style.display = btnNext.style.display = (tp > 1) ? '' : 'none';
			dom.content(tbody, s.slice(start, start + st.pageSize).map(function(e, i) {
				var isT = st.target && st.target.enb === e.enb && st.target.pci === e.pci;
				var rsrpTd = E('td', {}), sinrTd = E('td', {});
				paintMetricCell(rsrpTd, 'rsrp', e.rsrp, e.rsrp + ' dBm');
				paintMetricCell(sinrTd, 'sinr', e.sinr, e.sinr.toFixed(1));
				return E('tr', { class: 'pick' + (isT ? ' tgt' : ''), click: function() {
					if (isT) { st.target = null; LS.d('target'); speak('Цель сброшена'); }
					else { st.target = { enb: e.enb, pci: e.pci }; LS.sj('target', st.target); speak('Цель ' + e.enb + ' сектор ' + e.pci); }
					renderTable();
				} }, [ E('td', {}, String(start + i + 1)), E('td', {}, String(e.enb)), E('td', {}, String(e.pci)), rsrpTd, sinrTd, E('td', { class: 'al-hint' }, e.time || '--') ]);
			}));
		}

		var canvas = E('canvas', { style: 'width:100%;height:190px;display:block' });
		function draw() { drawChart(canvas, [ { name: 'SINR', points: st.hist } ], { min: -5, max: 25, fmt: function(v) { return Math.round(v) + ' dB'; } }); }
		var chartSec = E('div', { class: 'cbi-section tg5g' }, [ E('h3', {}, _('SINR за 30 секунд')), canvas ]);

		function sliderRow(label, key, val, onChange) {
			var vEl = E('span', { class: 'al-hint', style: 'min-width:34px' }, Math.round(val * 100) + '%');
			var inp = E('input', { type: 'range', min: 0, max: 100, value: val * 100, input: function(ev) { var v = parseInt(ev.target.value) / 100; vEl.textContent = Math.round(v * 100) + '%'; LS.s(key, v); onChange(v); } });
			return E('div', { class: 'al-sli' }, [ E('label', {}, label), inp, vEl ]);
		}
		function loadCustom(dataUrl) {
			try { var b = atob(dataUrl.split(',')[1]); var buf = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) buf[i] = b.charCodeAt(i); ac().decodeAudioData(buf.buffer, function(d) { au.customBuf = d; }); } catch(e) {}
		}
		var fileInput = E('input', { type: 'file', accept: 'audio/*', style: 'display:none', change: function(ev) {
			var f = ev.target.files[0]; if (!f) return;
			if (f.size > 1500000) { ui.addNotification(null, E('p', _('Файл великоват (до ~1.5 МБ)')), 'warning'); return; }
			var r = new FileReader();
			r.onload = function() { LS.s('customsnd', r.result); loadCustom(r.result); ui.addNotification(null, E('p', _('Свой звук загружен')), 'info'); };
			r.readAsDataURL(f);
		} });
		var snd0 = LS.g('customsnd', ''); if (snd0) loadCustom(snd0);
		var soundSec = E('div', { class: 'cbi-section' }, [
			E('h3', {}, _('Звук')),
			sliderRow(_('Гейгер (SINR)'), 'vGeiger', au.vGeiger, function(v) { au.vGeiger = v; }),
			sliderRow(_('Тон RSRP'), 'vTone', au.vTone, function(v) { au.vTone = v; }),
			sliderRow(_('Голос'), 'vVoice', au.vVoice, function(v) { au.vVoice = v; }),
			E('div', { style: 'display:flex;gap:8px;flex-wrap:wrap;margin-top:8px' }, [
				E('button', { class: 'btn cbi-button', click: function() { fileInput.click(); } }, _('Загрузить свой звук')),
				E('button', { class: 'btn cbi-button', click: function() { var was = au.on; au.on = true; click(); au.on = was; } }, _('Проба')),
				E('button', { class: 'btn cbi-button', click: function() { au.customBuf = null; LS.d('customsnd'); ui.addNotification(null, E('p', _('Возврат к звуку по умолчанию')), 'info'); } }, _('Звук по умолчанию')),
				fileInput
			])
		]);

		var intervalInput = E('input', { type: 'number', min: 0.5, max: 10, step: 0.5, value: st.interval, style: 'width:64px', change: function(ev) {
			var v = parseFloat(ev.target.value);
			if (v >= 0.5 && v <= 10) { st.interval = v; LS.s('interval', v); restart(); } else ev.target.value = st.interval;
		} });
		var sndBtn = E('button', { class: 'btn cbi-button al-sndbtn', click: function() {
			au.on = !au.on; LS.s('sndon', au.on ? '1' : '0'); paintSndBtn();
			if (au.on) { ac(); speak('Звук включён'); geiger(st.curSinr || 0); } else { stopAudio(); }
		} });
		function paintSndBtn() { dom.content(sndBtn, au.on ? [ '🔊 ', _('Звук: вкл') ] : [ '🔇 ', _('Звук: выкл') ]); sndBtn.classList.toggle('cbi-button-positive', au.on); }
		paintSndBtn();
		var topBar = E('div', { class: 'cbi-section', style: 'display:flex;flex-wrap:wrap;gap:14px;align-items:center' }, [
			sndBtn, E('div', { style: 'display:flex;align-items:center;gap:8px' }, [ E('span', { class: 'al-hint' }, _('Интервал, с')), intervalInput ])
		]);

		function updateRx(rx) {
			var vals = [];
			for (var i = 0; i < 4; i++) {
				var r = rx[i];
				paintMetricCell(rxRsrp[i], 'rsrp', r ? r.rsrp : null, r && r.rsrp != null ? r.rsrp : '-');
				paintMetricCell(rxRsrq[i], 'rsrq', r ? r.rsrq : null, r && r.rsrq != null ? r.rsrq : '-');
				if (r && r.rsrp != null && !isNaN(parseFloat(r.rsrp))) vals.push(parseFloat(r.rsrp));
			}
			var n = vals.length;
			mimoTitle.textContent = 'MIMO: ' + n + 'x' + n;
			if (n >= 2) {
				var d = Math.round((Math.max.apply(null, vals) - Math.min.apply(null, vals)) * 10) / 10;
				var lbl = d <= 3 ? _('отлично') : d <= 6 ? _('хорошо') : d <= 10 ? _('средне') : _('плохо');
				mimoBal.textContent = _('Разброс RX') + ': ' + d + ' dB · ' + _('баланс') + ': ' + lbl;
			} else mimoBal.textContent = '';
		}
		function logCell(enb, pci, rsrp, sinr) {
			if (enb == null || enb === '' || enb === '-' || isNaN(sinr)) return;
			var now = new Date();
			var ts = [ now.getHours(), now.getMinutes(), now.getSeconds() ].map(function(x) { return (x < 10 ? '0' : '') + x; }).join(':');
			for (var i = 0; i < st.cells.length; i++) {
				if (st.cells[i].enb === enb && st.cells[i].pci === pci) {
					if (sinr > st.cells[i].sinr) { st.cells[i].sinr = sinr; st.cells[i].rsrp = rsrp; st.cells[i].time = ts; LS.sj('celllog', st.cells); }
					return;
				}
			}
			st.cells.push({ enb: enb, pci: pci, rsrp: rsrp, sinr: sinr, time: ts });
			LS.sj('celllog', st.cells);
		}

		function apply(j) {
			if (j.error === 'not_active' || (j.path && pageModemPath && String(j.path) !== pageModemPath)) {
				if (++st.foreignN >= 3) { st.foreignN = 0; try { window.sessionStorage.removeItem('5gm-tab'); } catch(e) {} pageModemPath = ''; }
				return;
			}
			st.foreignN = 0;
			var sinr = parseFloat(j.sinr), rsrp = parseInt(j.rsrp, 10), rsrq = parseInt(j.rsrq, 10);
			var rssiRaw = (j.rssi != null && j.rssi !== '') ? j.rssi : j.signal;
			var online = !isNaN(rsrp) || !isNaN(sinr) || !!(j.modem && j.modem.length > 1);
			st.online = online;
			if (!online) {
				stopAudio();
				[ mSinr, mRsrp, mRsrq, mRssi ].forEach(function(mo) { setMetric(mo, null); });
				bs.textContent = 'БС: --'; sec.textContent = _('Сектор') + ': --'; earfcn.textContent = 'EARFCN: --'; mode.textContent = '';
				updateRx([]);
				return;
			}
			au.curSinr = sinr;
			var arrow = '';
			if (st.lastSinr !== null && !isNaN(sinr)) { var d = sinr - st.lastSinr; arrow = d > 0.3 ? ' ↑' : d < -0.3 ? ' ↓' : ''; }
			if (!isNaN(sinr)) st.lastSinr = sinr;
			setMetric(mSinr, isNaN(sinr) ? null : sinr.toFixed(1), arrow);
			setMetric(mRsrp, isNaN(rsrp) ? null : rsrp);
			setMetric(mRsrq, isNaN(rsrq) ? null : rsrq);
			setMetric(mRssi, (rssiRaw == null || rssiRaw === '') ? null : parseInt(rssiRaw, 10));

			var enb = (j.enbid != null && j.enbid !== '' && j.enbid !== '-') ? String(j.enbid) : '';
			var pci = (j.pci != null && j.pci !== '') ? String(j.pci) : '';
			var isT = st.target && st.target.enb === enb && st.target.pci === pci;
			bs.textContent = 'БС: ' + (enb || '--') + (isT ? ' 🎯' : '');
			sec.textContent = _('Сектор') + ': ' + (pci || '--');
			earfcn.textContent = 'EARFCN: ' + (j.earfcn || '--');
			mode.textContent = j.mode ? String(j.mode).split('|')[0].trim() : '';

			updateRx(parseAntports(j.antports));
			if (enb && !isNaN(sinr)) { logCell(enb, pci, isNaN(rsrp) ? '-' : rsrp, sinr); renderTable(); }
			if (!isNaN(sinr)) { st.t += st.interval; st.hist.push([ st.t, sinr ]); if (st.hist.length > 30) st.hist.shift(); draw(); geiger(sinr); tone(rsrp); }
		}

		function tick() {
			if (!root.isConnected) { clearInterval(st.timer); stopAudio(); return; }
			if (document.hidden) return;
			fetchSnapshot().then(function(j) { if (root.isConnected && !document.hidden && j) apply(j); });
		}
		function restart() { if (st.timer) clearInterval(st.timer); st.timer = setInterval(tick, st.interval * 1000); }

		window.__5gmInPlaceSwitch = function(path) {
			pageModemPath = String(path || '');
			st.hist = []; st.lastSinr = null; st.foreignN = 0;
			draw(); tick();
		};
		document.addEventListener('visibilitychange', function() { if (document.hidden) stopAudio(); });

		var root = E('div', {}, [ style, E('h2', {}, _('Юстировка антенны')), topBar, metricSec, mimoSec, logSec, chartSec, soundSec ]);

		renderTable();
		modemtabs.attach();
		setTimeout(function() { draw(); tick(); restart(); }, 0);
		return root;
	},

	handleSaveApply: null, handleSave: null, handleReset: null
});
