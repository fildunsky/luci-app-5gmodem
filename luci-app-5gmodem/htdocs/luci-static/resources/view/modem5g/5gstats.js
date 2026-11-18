'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';
'require rpc';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

(function() {
	if (document.getElementById('tg-page-stats-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-page-stats-css';
	l.rel = 'stylesheet';
	l.href = L.resource('view/modem5g/page-stats.css');
	document.head.appendChild(l);
})();

var BIN = '/usr/share/5gmodem/stats.sh';

// The "Collection" switch is the show_stats flag of Settings: saved the same way
// (uci save + commit of the 5gmodem config), then the menu tab gate is refreshed.
var uciCommit = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	expect: { '': {} }
});

function mainSid() {
	var ss = uci.sections('5gmodem', '5gmodem');
	return (ss && ss[0]) ? ss[0]['.name'] : null;
}

var _state = { list: null, series: {}, traffic: null };
var _ui = null;

function callStats(args) {
	return L.resolveDefault(fs.exec_direct(BIN, args), '').then(function(out) {
		try { return JSON.parse(out || 'null'); } catch (e) { return null; }
	});
}

var LINE_COLORS = [ '#2b8a3e', '#1c7ed6', '#e8590c', '#7048e8', '#c92a2a' ];

var ICONS = {
	chart: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 3v18h18"/><path d="m7 15 4-5 4 3 5-7"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size) {
	var s = E('span', { 'class': 'tg-stats-i' });
	s.innerHTML = svg(name, size);
	return s;
}

// Light text on the page means a dark theme, whatever the theme calls its dark mode (gps.js).
function isDarkUI(el) {
	var c = getComputedStyle(el || document.body).color;
	var m = String(c).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	if (!m) { return false; }
	return (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

function hexToRgba(hex, a) {
	var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
	if (!m) { return hex; }
	return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' + parseInt(m[3], 16) + ',' + a + ')';
}

// A canvas inside a hidden card or a collapsed block has no width: it is not drawn then,
// the arguments are kept on the element and the resize observer draws it once it gets a size.
var _ro = null;
function watchSize(canvas) {
	if (!_ro && window.ResizeObserver) {
		var pending = [];
		_ro = new ResizeObserver(function(entries) {
			entries.forEach(function(en) { if (pending.indexOf(en.target) < 0) { pending.push(en.target); } });
			window.requestAnimationFrame(function() {
				var list = pending; pending = [];
				list.forEach(function(c) { if (c.__args && c.isConnected) { drawChart(c, c.__args[0], c.__args[1]); } });
			});
		});
	}
	if (_ro) { _ro.observe(canvas); }
}
if (!window.ResizeObserver) {
	window.addEventListener('resize', function() {
		document.querySelectorAll('canvas.tg-stats-chart').forEach(function(c) {
			if (c.__args) { drawChart(c, c.__args[0], c.__args[1]); }
		});
	});
}

function drawChart(canvas, series, opts) {
	opts = opts || {};
	canvas.__args = [ series, opts ];
	var dpr = window.devicePixelRatio || 1;
	var rect = canvas.getBoundingClientRect();
	if (!(rect.width > 0) || !(rect.height > 0)) { return; }
	var W = rect.width, H = rect.height;
	canvas.width = Math.floor(W * dpr);
	canvas.height = Math.floor(H * dpr);
	var ctx = canvas.getContext('2d');
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

	var padL = 52, padR = 12, padT = 12, padB = 24;
	var dark = isDarkUI(canvas);
	var fg = dark ? '#c9ccd1' : '#444';
	var grid = dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)';

	ctx.clearRect(0, 0, W, H);
	var all = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { all.push(p[1]); }); });
	if (!all.length) {
		ctx.fillStyle = fg; ctx.font = '12px sans-serif'; ctx.textAlign = 'center';
		ctx.fillText(_('No data yet'), W / 2, H / 2);
		canvas.__chart = null;
		return;
	}
	var vmax = Math.max.apply(null, all), vmin = Math.min.apply(null, all);
	if (opts.zeroBase) { vmin = 0; }
	if (vmax === vmin) { vmax = vmin + 1; }
	var pad = (vmax - vmin) * 0.12;
	vmax += pad; if (!opts.zeroBase) { vmin -= pad; }
	if (opts.min != null) { vmin = opts.min; }
	if (opts.max != null) { vmax = opts.max; }

	var tAll = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { tAll.push(p[0]); }); });
	var tmin = Math.min.apply(null, tAll), tmax = Math.max.apply(null, tAll);
	if (tmax === tmin) { tmax = tmin + 1; }

	var innerW = W - padL - padR, innerH = H - padT - padB;
	var x = function(t) { return padL + (t - tmin) / (tmax - tmin) * innerW; };
	var y = function(v) { return padT + (1 - (v - vmin) / (vmax - vmin)) * innerH; };

	ctx.strokeStyle = grid; ctx.fillStyle = fg;
	ctx.lineWidth = 1; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
	for (var i = 0; i <= 4; i++) {
		var v = vmin + (vmax - vmin) * i / 4, yy = Math.round(y(v)) + 0.5;
		ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(W - padR, yy); ctx.stroke();
		ctx.fillText(opts.fmt ? opts.fmt(v) : Math.round(v), padL - 6, yy + 3);
	}
	ctx.textAlign = 'left';
	ctx.fillText(_('%d min ago').format(Math.round((tmax - tmin) / 60)), padL, H - 7);
	ctx.textAlign = 'right';
	ctx.fillText(_('now'), W - padR, H - 7);

	series.forEach(function(s, idx) {
		var pts = s.points || [];
		if (!pts.length) { return; }
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

		ctx.beginPath();
		tracePath();
		ctx.lineTo(x(pts[pts.length - 1][0]), padT + innerH);
		ctx.lineTo(x(pts[0][0]), padT + innerH);
		ctx.closePath();
		var grad = ctx.createLinearGradient(0, padT, 0, padT + innerH);
		var a0 = (series.length > 1) ? (dark ? 0.20 : 0.14) : (dark ? 0.38 : 0.28);
		grad.addColorStop(0, hexToRgba(col, a0));
		grad.addColorStop(1, hexToRgba(col, 0));
		ctx.fillStyle = grad;
		ctx.fill();

		ctx.strokeStyle = col;
		ctx.lineWidth = 1.6;
		ctx.lineJoin = 'round'; ctx.lineCap = 'round';
		ctx.beginPath();
		tracePath();
		ctx.stroke();
	});

	canvas.__chart = { series: series, tmin: tmin, tmax: tmax, vmin: vmin, vmax: vmax,
		padL: padL, padT: padT, innerW: innerW, innerH: innerH, W: W, H: H,
		fmt: opts.fmt, opts: opts, dark: dark };

	if (canvas.__hoverX != null) {
		var hx = canvas.__hoverX;
		if (hx >= padL && hx <= W - padR) {
			ctx.strokeStyle = dark ? 'rgba(255,255,255,.35)' : 'rgba(0,0,0,.30)';
			ctx.setLineDash([ 3, 3 ]); ctx.lineWidth = 1;
			ctx.beginPath(); ctx.moveTo(hx, padT); ctx.lineTo(hx, padT + innerH); ctx.stroke();
			ctx.setLineDash([]);
			var t = tmin + (hx - padL) / innerW * (tmax - tmin);
			var lines = [];
			series.forEach(function(s, idx) {
				var pts = s.points || [];
				if (!pts.length) { return; }
				var best = pts[0], bd = Math.abs(pts[0][0] - t);
				pts.forEach(function(p) { var d = Math.abs(p[0] - t); if (d < bd) { bd = d; best = p; } });
				lines.push({ c: LINE_COLORS[idx % LINE_COLORS.length], n: s.name,
					v: opts.fmt ? opts.fmt(best[1]) : String(best[1]) });
			});
			if (lines.length) {
				ctx.font = '11px sans-serif';
				var bw = 0;
				lines.forEach(function(l) { bw = Math.max(bw, ctx.measureText(l.n + '  ' + l.v).width); });
				bw += 22;
				var bh = lines.length * 15 + 8;
				var bx = (hx + bw + 10 < W) ? hx + 8 : hx - bw - 8;
				var by = padT + 4;
				ctx.fillStyle = dark ? 'rgba(20,22,26,.92)' : 'rgba(255,255,255,.94)';
				ctx.strokeStyle = grid;
				ctx.beginPath(); ctx.rect(bx, by, bw, bh); ctx.fill(); ctx.stroke();
				lines.forEach(function(l, i) {
					var ly = by + 15 * i + 14;
					ctx.fillStyle = l.c;
					ctx.fillRect(bx + 6, ly - 7, 8, 3);
					ctx.fillStyle = fg; ctx.textAlign = 'left';
					ctx.fillText(l.n + '  ' + l.v, bx + 18, ly);
				});
			}
		}
	}
}

function chartCanvas(id, cls) {
	var c = E('canvas', { 'id': id, 'class': 'tg-stats-chart' + (cls ? ' ' + cls : ''),
		'mousemove': function(ev) {
			var r = ev.target.getBoundingClientRect();
			ev.target.__hoverX = ev.clientX - r.left;
			if (ev.target.__chart) { drawChart(ev.target, ev.target.__chart.series,
				ev.target.__chart.opts); }
		},
		'mouseleave': function(ev) {
			ev.target.__hoverX = null;
			if (ev.target.__chart) { drawChart(ev.target, ev.target.__chart.series,
				ev.target.__chart.opts); }
		}
	});
	watchSize(c);
	return c;
}

function chartCard(title, id, cardId, hidden) {
	return E('div', { 'class': 'cbi-section tg5g', 'id': cardId || null, 'style': hidden ? 'display:none' : null }, [
		E('h3', {}, [ title ]),
		chartCanvas(id),
		E('div', { 'id': id + '-legend', 'class': 'tg-stats-leg' }, [])
	]);
}

function legendItem(name, idx, value) {
	return E('span', {}, [
		E('i', { 'style': 'background:' + LINE_COLORS[idx % LINE_COLORS.length] }),
		name + (value ? ' · ' + value : '')
	]);
}

function lastVal(pts) { return (pts && pts.length) ? pts[pts.length - 1][1] : null; }

function fillLegend(id, list, fmt) {
	var el = document.getElementById(id);
	if (!el) { return; }
	var parts = list.map(function(s, i) {
		var v = lastVal(s.points);
		return { n: s.name, i: i, v: v == null ? '' : fmt(v) };
	});
	var sig = JSON.stringify(parts);
	if (el.getAttribute('data-sig') === sig) { return; }
	el.setAttribute('data-sig', sig);
	el.innerHTML = '';
	parts.forEach(function(p) { el.appendChild(legendItem(p.n, p.i, p.v)); });
}

function fmtBytes(n) {
	n = Number(n) || 0;
	var units = [ _('B'), _('KB'), _('MB'), _('GB'), _('TB') ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	var d = (i === 0) ? 0 : (n < 10 ? 2 : (n < 100 ? 1 : 0));
	return n.toFixed(d) + ' ' + units[i];
}

// month names follow the LuCI interface language (<html lang>), not the browser's own locale:
// an English browser showed "November, 2026" on a Russian interface. In a sentence the name keeps
// the language's own case ("Трафик за ноябрь 2026"), as a label it starts with a capital.
function fmtMonth(ym, inSentence) {
	var m = /^(\d{4})-(\d{2})$/.exec(String(ym || ''));
	if (!m) { return String(ym || ''); }
	var name = ym, lang = (document.documentElement.getAttribute('lang') || '').replace('_', '-') || undefined;
	try {
		name = new Date(+m[1], +m[2] - 1, 1).toLocaleString(lang, { month: 'long' });
		if (!inSentence) { name = name.charAt(0).toUpperCase() + name.slice(1); }
	} catch (e) { return String(ym); }
	return /^\d/.test(name) ? m[1] + ' ' + name : name + ' ' + m[1];
}

function curMonth() {
	var d = new Date();
	return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2);
}

function trafficIcon(key, label, opName) {
	var f;
	if (/^sim-/.test(String(key || ''))) {
		f = mutil.operatorIcon(opName || '') || mutil.operatorIcon(label) || 'op-sim';
		f = 'icons/5gmodem/' + f + '.svg';
	} else if (/^(wwan|wlan|phy|wifi)/i.test(String(key || ''))) {
		f = 'icons/5gmodem/cwifi.svg';
	} else if (/^(wan|eth|lan)/i.test(String(key || ''))) {
		f = 'icons/5gmodem/cwan.svg';
	} else {
		f = 'icons/5gmodem/op-sim.svg';
	}
	return E('img', { 'src': mutil.icon(f), 'width': 18, 'height': 18, 'alt': '',
		'style': 'display:block; flex:none' });
}

function prettyTrafficLabel(label) {
	var s = String(label || '');
	var m = s.match(/^sim-(\d{6,})$/);
	if (m) { return 'ICCID: ' + m[1]; }
	if (/ICCID:/.test(s)) { return s; }
	return s.replace(/\+?\d[\d\s()-]{9,}\d/, function(m2) { return mutil.formatPhone(m2); });
}

// Monthly traffic as cards (one per SIM or interface and month), newest month first.
function trafficTable(data, labels) {
	labels = labels || {};
	var keys = Object.keys(data || {}).sort(function(a, b) {
		var ma = a.split('|')[1] || '', mb = b.split('|')[1] || '';
		if (ma !== mb) { return ma < mb ? 1 : -1; }
		return a < b ? -1 : (a > b ? 1 : 0);
	});
	if (!keys.length) {
		return E('div', { 'class': 'cbi-section-descr' }, [ _('No data yet') ]);
	}
	return E('div', { 'class': 'tg-stats-tr' }, keys.map(function(k) {
		var parts = k.split('|'), v = data[k] || {};
		var rx = parseInt(v.rx, 10) || 0, tx = parseInt(v.tx, 10) || 0;
		var lab = labels[parts[0]] || labels['ping.' + parts[0]] || parts[0];
		var tot = fmtBytes(rx + tx), sp = tot.lastIndexOf(' ');
		var pRx = (rx + tx) > 0 ? Math.round(100 * rx / (rx + tx)) : 0;
		var del = E('button', {
			'class': 'cbi-button tg-trdel tg-stats-del',
			'title': _('Delete this row'),
			'aria-label': _('Delete this row'),
			'click': function(ev) { forgetTrafficRow(ev.currentTarget, parts[0], parts[1]); }
		});
		del.innerHTML = svg('trash', 14);
		return E('div', { 'class': 'tg-hist-card' }, [
			E('div', { 'class': 'tg-hist-h' }, [
				E('span', { 'class': 'tg-stats-trname' }, [
					trafficIcon(parts[0], lab, labels['op.' + parts[0]]),
					E('b', { 'title': prettyTrafficLabel(lab) }, [ prettyTrafficLabel(lab) ])
				]),
				del
			]),
			E('div', { 'class': 'tg-hist-now' }, [ tot.slice(0, sp), ' ', E('small', {}, [ tot.slice(sp + 1) + ' · ' + fmtMonth(parts[1]) ]) ]),
			E('div', { 'class': 'tg-stats-split', 'title': _('Received') + ' ' + pRx + '%' }, [
				E('span', { 'class': 'rx', 'style': 'width:' + pRx + '%' }),
				E('span', { 'class': 'tx', 'style': 'width:' + ((rx + tx) > 0 ? 100 - pRx : 0) + '%' })
			]),
			E('div', { 'class': 'tg-hist-f' }, [
				E('span', {}, [ '↓ ' + _('Received') + ' ' + fmtBytes(rx) ]),
				E('span', {}, [ '↑ ' + _('Sent') + ' ' + fmtBytes(tx) ])
			])
		]);
	}));
}

function paintTraffic(force) {
	var tt = document.getElementById('traffic-table');
	if (!tt) { return; }
	var lab = (_state.list || {}).labels || {};
	var sig = JSON.stringify([ _state.traffic || {}, lab ]);
	if (!force && tt.getAttribute('data-sig') === sig) { return; }
	tt.setAttribute('data-sig', sig);
	tt.innerHTML = '';
	tt.appendChild(trafficTable(_state.traffic, lab));
}

function forgetTrafficRow(btn, key, month) {
	if (!confirm(_('Delete this traffic row? This cannot be undone.'))) { return; }
	btn.disabled = true;
	callStats([ 'forget', key, month ]).then(function() {
		return callStats([ 'traffic' ]);
	}).then(function(t) {
		_state.traffic = t || {};
		paintTraffic(true);
		paintHead();
	});
}

function monthTotals() {
	var cm = curMonth(), rx = 0, tx = 0, any = false;
	Object.keys(_state.traffic || {}).forEach(function(k) {
		if (k.split('|')[1] !== cm) { return; }
		var v = _state.traffic[k] || {};
		rx += parseInt(v.rx, 10) || 0; tx += parseInt(v.tx, 10) || 0; any = true;
	});
	return any ? { rx: rx, tx: tx } : null;
}

function driveMissing(lst) {
	lst = lst || {};
	return !!(lst.persist && lst.path && lst.path_now && lst.path_now !== lst.path);
}

function statsOn(lst) {
	return !lst || lst.enabled == null || String(lst.enabled) !== '0';
}

// A switch is left alone while its own save is in flight: the 10 s refresh would flip it back.
function setSwitch(b, on) {
	if (!b || b.disabled) { return; }
	b.setAttribute('aria-checked', String(!!on));
	b.classList.toggle('on', !!on);
}

function setSeg(seg, v) {
	if (!seg || seg.getAttribute('data-busy')) { return; }
	Array.prototype.forEach.call(seg.querySelectorAll('button'), function(b) {
		var on = b.getAttribute('data-v') === v;
		b.classList.toggle('on', on);
		b.setAttribute('aria-pressed', String(on));
	});
}

// the arrows of the Network page's traffic line (5gdetail.js), so both pages read the same
var ARR_DN = '<svg width="11" height="11" viewBox="0 0 52 52" style="vertical-align:-1px" aria-hidden="true"><path fill="#009955" d="M8.3,14h35.4c1,0,1.7,1.3,0.9,2.2L27.3,37.4c-0.6,0.8-1.9,0.8-2.5,0L7.3,16.2C6.6,15.3,7.2,14,8.3,14z"/></svg>';
var ARR_UP = '<svg width="11" height="11" viewBox="0 0 52 52" style="vertical-align:-1px" aria-hidden="true"><path fill="#0099ff" d="M43.7,38H8.3c-1,0-1.7-1.3-0.9-2.2l17.3-21.2c0.6-0.8,1.9-0.8,2.5,0l17.5,21.2C45.4,36.7,44.8,38,43.7,38z"/></svg>';

function paintHead() {
	if (!_ui) { return; }
	var lst = _state.list || {}, on = statsOn(lst), warn = on && driveMissing(lst);
	var pillKind = !on ? 'off' : warn ? 'warn' : 'ok';
	var pillText = !on ? _('Paused') : warn ? _('Drive not mounted') : _('Collecting');
	[ _ui.pill, _ui.pillM ].forEach(function(p) {
		p.className = 'tg-stats-pill ' + pillKind + (p === _ui.pillM ? ' tg-stats-pillm' : '');
		p.lastChild.textContent = pillText;
	});
	_ui.ico.className = 'tginfo-signal tg-stats-ico ' + pillKind;
	var mt = monthTotals();
	_ui.month.textContent = _('Traffic for %s').format(fmtMonth(curMonth(), true));
	_ui.main.textContent = mt ? fmtBytes(mt.rx + mt.tx) : _('No data yet');
	_ui.main.classList.toggle('none', !mt);
	// the Network page's traffic line: the same down/up arrows
	_ui.split.innerHTML = mt ? ARR_DN + '\u202f' + fmtBytes(mt.rx) + ' &nbsp;' + ARR_UP + '\u202f' + fmtBytes(mt.tx) : '';
	_ui.split.style.display = mt ? '' : 'none';
	var pnow = pathNowText(lst);
	var bad = !!lst.persist && (driveMissing(lst) || !lst.path_now);
	_ui.warn.textContent = bad ? pnow : '';
	_ui.warn.style.display = bad ? '' : 'none';
	setSwitch(_ui.swOn, on);
	setSwitch(_ui.swPersist, !!lst.persist);
	_ui.swPersist.title = _('Monthly totals are written to flash about once an hour. Ping series are never written there.') + '\n' + pnow;
	setSeg(_ui.segBg, String(lst.bgpoll || 0));
	if (_ui.pathWrap) { _ui.pathWrap.style.display = lst.persist ? '' : 'none'; }
}

var QG = function(l) { return (mutil.QUAL_GRAD || [])[l] || (mutil.QUAL_COLOR || [])[l] || ''; };

function setTile(t, val, unit, foot, pct, lvl) {
	var none = (val === null || val === undefined || val === '');
	t.now.textContent = none ? '-' : String(val);
	t.unit.textContent = none ? '' : (unit || '');
	t.val.classList.toggle('dash', none);
	t.foot.textContent = none ? '' : (foot || '');
	t.footRow.style.display = (!none && foot) ? '' : 'none';
	if (t.bar) {
		if (none || pct == null) { t.bar.style.visibility = 'hidden'; }
		else {
			t.bar.style.visibility = '';
			t.fill.style.width = Math.max(3, Math.min(100, pct)) + '%';
			t.fill.style.background = QG(lvl);
		}
	}
}

function firstWithPoints(list) {
	for (var i = 0; i < list.length; i++) { if ((list[i].points || []).length) { return list[i]; } }
	return null;
}

function paintTiles(ping, sig, rsrp, sinr, temp) {
	if (!_ui) { return; }
	var t = _ui.tiles;
	var p = firstWithPoints(ping);
	if (p) {
		var vals = p.points.map(function(q) { return q[1]; }).filter(function(v) { return v > 0; });
		var lv = lastVal(p.points), avg = vals.length ? vals.reduce(function(a, b) { return a + b; }, 0) / vals.length : null;
		var mx = vals.length ? Math.max.apply(null, vals) : null;
		var lvl = lv <= 0 ? 0 : lv <= 60 ? 3 : lv <= 120 ? 2 : lv <= 250 ? 1 : 0;
		setTile(t.ping, lv > 0 ? Math.round(lv) : null, 'ms',
			avg != null ? _('avg') + ' ' + Math.round(avg) + ' · ' + _('max') + ' ' + Math.round(mx) : '',
			lv > 0 ? 100 - Math.min(96, lv / 4) : null, lvl);
	} else { setTile(t.ping, null); }

	var s = firstWithPoints(sig);
	if (s) {
		var sv = lastVal(s.points), sa = s.points.reduce(function(a, q) { return a + q[1]; }, 0) / s.points.length;
		setTile(t.signal, Math.round(sv), '%', _('avg') + ' ' + Math.round(sa) + '%', sv,
			sv >= 75 ? 3 : sv >= 50 ? 2 : sv >= 25 ? 1 : 0);
	} else { setTile(t.signal, null); }

	var r = firstWithPoints(rsrp), n = firstWithPoints(sinr);
	t.rsrp.card.style.display = (rsrp.length || sinr.length) ? '' : 'none';
	// same shape as the other tiles: RSRP is the value and the bar, SINR goes to the footer
	if (r || n) {
		var nv = n ? Math.round(lastVal(n.points) * 10) / 10 : null;
		var sinrFoot = nv != null ? 'SINR ' + nv + ' dB' : '';
		if (r) {
			var rv = Math.round(lastVal(r.points));
			t.rsrp.name.textContent = 'RSRP';
			setTile(t.rsrp, rv, 'dBm', sinrFoot, mutil.qualPct('rsrp', rv), mutil.qualLevel('rsrp', rv));
		} else {
			t.rsrp.name.textContent = 'SINR';
			setTile(t.rsrp, nv, 'dB', '', mutil.qualPct('sinr', nv), mutil.qualLevel('sinr', nv));
		}
	} else { setTile(t.rsrp, null); }

	var tp = firstWithPoints(temp);
	t.temp.card.style.display = temp.length ? '' : 'none';
	if (tp) {
		var tv = lastVal(tp.points), tm = Math.max.apply(null, tp.points.map(function(q) { return q[1]; }));
		setTile(t.temp, Math.round(tv), '°C', _('max') + ' ' + Math.round(tm) + ' °C', tv,
			tv < 60 ? 3 : tv < 70 ? 2 : tv < 80 ? 1 : 0);
	} else { setTile(t.temp, null); }
}

function redraw() {
	var lst = _state.list || {};
	var lab = lst.labels || {};
	var pingSeries = (lst.ping || []).map(function(n) {
		return { name: lab['ping.' + n] || n, points: (_state.series['ping.' + n] || []) };
	});
	var sigSeries = (lst.signal || []).map(function(n) {
		return { name: lab['signal.' + n] || n.replace(/_/g, ' '), points: (_state.series['signal.' + n] || []) };
	});
	var rawNames = (lst.rsrp || []).slice();
	(lst.sinr || []).forEach(function(n) { if (rawNames.indexOf(n) < 0) { rawNames.push(n); } });
	var rawSeries = function(kind) {
		return rawNames.map(function(n) {
			return { name: lab[kind + '.' + n] || lab['signal.' + n] || n.replace(/_/g, ' '), points: (_state.series[kind + '.' + n] || []) };
		});
	};
	var rsrpSeries = rawSeries('rsrp'), sinrSeries = rawSeries('sinr');
	var tempSeries = (lst.temp || []).map(function(n) {
		return { name: lab['temp.' + n] || n.replace(/_/g, ' '), points: (_state.series['temp.' + n] || []) };
	});

	// Nothing collected yet: one empty-state card instead of four empty charts.
	var any = [ pingSeries, sigSeries, rsrpSeries, sinrSeries, tempSeries ].some(function(l) { return !!firstWithPoints(l); });
	var grid = document.getElementById('stats-charts'), empty = document.getElementById('stats-empty');
	if (grid) { grid.style.display = any ? '' : 'none'; }
	if (empty) { empty.style.display = any ? 'none' : ''; }

	// Card visibility first: a canvas drawn while hidden has no width (see drawChart).
	[ 'card-rsrp', 'card-sinr' ].forEach(function(id) {
		var el = document.getElementById(id);
		if (el) { el.style.display = rawNames.length ? '' : 'none'; }
	});
	var tc = document.getElementById('card-temp');
	if (tc) { tc.style.display = tempSeries.length ? '' : 'none'; }
	// an odd card out spans the whole row, so no card is left with a hole next to it
	if (grid) {
		var vis = Array.prototype.filter.call(grid.children, function(c) { return c.style.display !== 'none'; });
		vis.forEach(function(c, i) { c.classList.toggle('tg-stats-wide', i === vis.length - 1 && vis.length % 2 === 1); });
	}

	var msFmt = function(v) { return Math.round(v) + ' ms'; };
	var pctFmt = function(v) { return Math.round(v) + '%'; };
	var dbmFmt = function(v) { return Math.round(v) + ' dBm'; };
	var dbFmt = function(v) { return (Math.round(v * 10) / 10) + ' dB'; };
	var cFmt = function(v) { return Math.round(v) + ' °C'; };

	var c1 = document.getElementById('chart-ping');
	if (c1) { drawChart(c1, pingSeries, { zeroBase: true, fmt: msFmt }); }
	fillLegend('chart-ping-legend', pingSeries, msFmt);

	var c2 = document.getElementById('chart-signal');
	if (c2) { drawChart(c2, sigSeries, { min: 0, max: 100, fmt: pctFmt }); }
	fillLegend('chart-signal-legend', sigSeries, pctFmt);

	var c4 = document.getElementById('chart-rsrp'), c5 = document.getElementById('chart-sinr');
	if (rawNames.length) {
		if (c4) { drawChart(c4, rsrpSeries, { fmt: dbmFmt }); }
		if (c5) { drawChart(c5, sinrSeries, { fmt: dbFmt }); }
	}
	fillLegend('chart-rsrp-legend', rsrpSeries, dbmFmt);
	fillLegend('chart-sinr-legend', sinrSeries, dbFmt);

	var c3 = document.getElementById('chart-temp');
	if (c3) { drawChart(c3, tempSeries, { fmt: cFmt }); }
	fillLegend('chart-temp-legend', tempSeries, cFmt);

	paintTiles(pingSeries, sigSeries, rsrpSeries, sinrSeries, tempSeries);
	paintTraffic(false);
	paintHead();
}

function pathNowText(lst) {
	lst = lst || {};
	if (!lst.persist) { return _('Storing is off - data lives in RAM until the next reboot.'); }
	if (lst.path && lst.path_now && lst.path_now !== lst.path) {
		return _('The drive is not mounted - writing to %s for now, and merging back when it returns.').format(lst.path_now);
	}
	return lst.path_now ? _('Writing to %s').format(lst.path_now) : _('Nowhere to write - check the path.');
}

function legacyRefresh(have) {
	return (have ? Promise.resolve(have) : callStats([ 'list' ])).then(function(lst) {
		_state.list = lst || {};
		var names = [];
		(lst && lst.ping || []).forEach(function(n) { names.push('ping.' + n); });
		(lst && lst.signal || []).forEach(function(n) { names.push('signal.' + n); });
		(lst && lst.temp || []).forEach(function(n) { names.push('temp.' + n); });
		(lst && lst.rsrp || []).forEach(function(n) { names.push('rsrp.' + n); });
		(lst && lst.sinr || []).forEach(function(n) { names.push('sinr.' + n); });
		return Promise.all(names.map(function(n) {
			return callStats([ 'series', n ]).then(function(r) {
				_state.series[n] = (r && r.series) || [];
			});
		})).then(function() {
			return callStats([ 'traffic' ]).then(function(t) { _state.traffic = t || {}; });
		});
	});
}

function isBundle(b) { return !!(b && b.list && b.series && b.traffic); }

function applyBundle(b) {
	_state.list = b.list || {};
	_state.series = b.series || {};
	_state.traffic = b.traffic || {};
}

// one exec per refresh ("bundle", with "tick" it collects first). Only a usage
// error proves an older stats.sh without it; a failed exec is retried next time.
var _noBundle = false;
function callBundle(tick) {
	if (_noBundle) { return Promise.resolve(null); }
	return L.resolveDefault(fs.exec(BIN, tick ? [ 'bundle', 'tick' ] : [ 'bundle' ]), null).then(function(res) {
		var j = null;
		try { j = JSON.parse((res && res.stdout) || 'null'); } catch (e) {}
		if (j && typeof j.error === 'string' && j.error.indexOf('usage') === 0) { _noBundle = true; }
		return j;
	});
}

function refresh(have, tick) {
	if (isBundle(have)) { applyBundle(have); redraw(); return Promise.resolve(); }
	return callBundle(tick).then(function(b) {
		if (isBundle(b)) { applyBundle(b); return; }
		return (tick ? callStats([ 'tick' ]) : Promise.resolve()).then(function() {
			return legacyRefresh(have && have.ping ? have : null);
		});
	}).then(redraw);
}

function tileEl(name, foot, bar) {
	var t = { now: E('span', {}, '-'), unit: E('small', {}, ''), name: E('b', {}, name) };
	t.val = E('div', { 'class': 'tg-hist-now dash' }, [ t.now, ' ', t.unit ]);
	var kids = [ E('div', { 'class': 'tg-hist-h' }, E('span', { 'class': 'tg-hist-name' }, t.name)), t.val ];
	if (bar) {
		t.fill = E('div', { 'class': 'tg-mbar-fill' });
		t.bar = E('div', { 'class': 'tg-mbar', 'style': 'visibility:hidden' }, E('div', { 'class': 'tg-mbar-t' }, t.fill));
		kids.push(t.bar);
	}
	t.foot = E('span', {}, foot || '');
	t.footRow = E('div', { 'class': 'tg-hist-f', 'style': 'display:none' }, t.foot);
	kids.push(t.footRow);
	t.card = E('div', { 'class': 'tg-hist-card' }, kids);
	return t;
}

return view.extend({
	load: function() {
		var self = this, args = arguments;
		return fresh.check(40008, [ modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([
			uci.load('5gmodem'),
			callBundle(false).then(function(b) {
				return isBundle(b) ? b : callStats([ 'list' ]);
			})
		]);
	},

	render: function(res) {
		var first = res && res[1];
		var lst = (isBundle(first) ? first.list : first) || {};
		_state.list = lst;

		/* ---------- header card ---------- */
		var listAgain = function() {
			return callStats([ 'list' ]).then(function(lst2) {
				if (lst2) { _state.list = lst2; }
			});
		};
		var mkPill = function(cls) { return E('span', { 'class': 'tg-stats-pill ok' + (cls ? ' ' + cls : '') }, [ E('i'), E('span', {}, '') ]); };
		_ui = { tiles: {} };
		_ui.pill = mkPill();
		_ui.pillM = mkPill('tg-stats-pillm');
		_ui.ico = E('div', { 'class': 'tginfo-signal tg-stats-ico ok', 'title': _('Collected every 10 s while this page is open') });
		_ui.ico.innerHTML = svg('chart', 36);
		_ui.ico.appendChild(E('medium', {}, _('%d s').format(10)));
		// the Network page's modem card: small line, bold main line, small line; then an info column
		_ui.month = E('div', { 'class': 'tginfo-reg' }, '');
		_ui.main = E('div', { 'class': 'tginfo-op tg-stats-main' }, '');
		_ui.split = E('div', { 'class': 'tginfo-loc tg-stats-trf' }, '');
		_ui.warn = E('div', { 'class': 'tginfo-loc tg-stats-warn', 'style': 'display:none' }, '');

		// a switch shows the new state at once and goes back if the save fails
		var mkSwitch = function(label, title, save) {
			var b = E('button', { 'type': 'button', 'class': 'tg-stats-sw', 'role': 'switch',
				'aria-checked': 'false', 'title': title }, [ E('i'), E('span', {}, label) ]);
			b.addEventListener('click', function() {
				if (b.disabled) { return; }
				var v = b.getAttribute('aria-checked') !== 'true';
				setSwitch(b, v);
				b.disabled = true;
				Promise.resolve().then(function() { return save(v); }).catch(function() {
					b.disabled = false;
					setSwitch(b, !v);
				}).then(function() {
					b.disabled = false;
					paintHead();
				});
			});
			return b;
		};
		_ui.swOn = mkSwitch(_('Collection'), _('Collects uplink latency, signal, temperature and monthly traffic, and shows the "Statistics" tab with the charts. Series live in RAM; monthly traffic can be kept across reboots on the tab itself.'), function(v) {
			var sid = mainSid();
			if (!sid) { throw new Error('no section'); }
			uci.set('5gmodem', sid, 'show_stats', v ? '1' : '0');
			return uci.save().then(function() {
				return uciCommit('5gmodem');
			}).then(function() {
				if (_state.list) { _state.list.enabled = v ? 1 : 0; }
				return L.resolveDefault(modemtabs.refreshGateTabs(), null);
			}).then(listAgain);
		});
		_ui.swPersist = mkSwitch(_('Keep after reboot'), '', function(v) {
			return callStats([ 'setconf', 'persist=' + (v ? '1' : '0') ]).then(function(r) {
				if (!r || r.error) { throw new Error('setconf'); }
				return listAgain();
			});
		});
		_ui.segBg = E('div', { 'class': 'tg-stats-seg', 'role': 'group', 'aria-label': _('Collect in background'),
			'title': _('With the page closed the modem is not polled, so the signal charts stop. This polls the active modem on a timer to keep them going. Modems with background AT polling switched off are skipped.') },
			[ [ '0', _('Off') ], [ '300', _('every 5 minutes') ], [ '60', _('every minute') ] ].map(function(o) {
				return E('button', { 'type': 'button', 'data-v': o[0], 'aria-pressed': 'false',
					'click': function() {
						var seg = _ui.segBg, was = String((_state.list || {}).bgpoll || 0);
						if (seg.getAttribute('data-busy') || was === o[0]) { return; }
						setSeg(seg, o[0]);
						seg.setAttribute('data-busy', '1');
						callStats([ 'setconf', 'bgpoll=' + o[0] ]).then(function(r) {
							seg.removeAttribute('data-busy');
							if (!r || r.error) { setSeg(seg, was); return; }
							if (_state.list) { _state.list.bgpoll = o[0]; }
							paintHead();
						});
					} }, o[1]);
			}));

		// where to store and reset: one compact row under the switches
		_ui.path = E('input', {
			'type': 'text', 'class': 'cbi-input-text tg-stats-path', 'id': 'st-path',
			'value': lst.path || '', 'placeholder': lst.path_default || '/etc/5gmodem/stats',
			'aria-label': _('Where to store'),
			'title': _('Empty - the router\'s own memory (%s). A path on a USB drive also gets the chart series, not just monthly totals.').format(lst.path_default || '/etc/5gmodem/stats'),
			'change': function(ev) {
				callStats([ 'setconf', 'path=' + String(ev.target.value || '').trim() ]).then(function(r) {
					if (r && r.error) {
						_ui.warn.textContent = _('Path rejected: %s').format(r.error);
						_ui.warn.style.display = '';
						return;
					}
					return listAgain().then(paintHead);
				});
			}
		});
		_ui.reset = E('button', { 'type': 'button', 'class': 'tg-stats-sw tg-stats-reset', 'title': _('Deletes all collected charts and monthly traffic') }, [ E('span', { 'class': 'tg-stats-ri' }), E('span', {}, _('Reset')) ]);
		_ui.reset.firstChild.innerHTML = svg('trash', 14);
		_ui.reset.addEventListener('click', function() {
			if (_ui.reset.disabled) { return; }
			_ui.reset.disabled = true;
			callStats([ 'reset' ]).then(function() {
				_state.series = {}; _state.traffic = {};
				return refresh();
			}).catch(function() {}).then(function() { _ui.reset.disabled = false; });
		});

		var head = E('div', { 'class': 'cbi-section tg5g tg-pg-head tg-stats-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-stats-title' }, [ E('span', {}, _('Statistics')), _ui.pillM ]),
			E('div', { 'class': 'tginfo-general' }, [
				_ui.ico,
				E('div', { 'class': 'tginfo-status' }, [ _ui.month, _ui.main, _ui.split, _ui.warn ]),
				E('div', { 'class': 'tginfo-right' }, [ _ui.pill ])
			]),
			// every control in one bar of one height: switches, the background segment, the path, reset
			E('div', { 'class': 'tg-stats-ctl' }, [
				_ui.swOn, _ui.swPersist,
				E('span', { 'class': 'tg-stats-bg tg-stats-poll' }, [ E('span', { 'class': 'tg-stats-lbl' }, _('Collect in background:')), _ui.segBg ]),
				_ui.pathWrap = E('span', { 'class': 'tg-stats-bg tg-stats-store' }, [ E('span', { 'class': 'tg-stats-lbl' }, _('Store in:')), _ui.path ]),
				_ui.reset
			])
		]);

		/* ---------- current values ---------- */
		var T = _ui.tiles;
		T.ping = tileEl(_('Uplink latency'), '', true);
		T.signal = tileEl(_('Signal'), '', true);
		T.rsrp = tileEl('RSRP', '', true);
		T.temp = tileEl(_('Temperature'), '', true);
		// this month's traffic is the main line of the header card, so it has no tile of its own
		var tiles = E('div', { 'class': 'tg-stats-tiles' }, [ T.ping.card, T.signal.card, T.rsrp.card, T.temp.card ]);

		/* ---------- charts ---------- */
		var emptyIco = E('span', { 'class': 'tg-stats-i' });
		emptyIco.innerHTML = svg('chart', 30);
		var empty = E('div', { 'class': 'cbi-section tg5g', 'id': 'stats-empty', 'style': 'display:none' }, [
			E('div', { 'class': 'tg-stats-empty' }, E('div', {}, [ emptyIco, E('b', {}, _('No data yet')),
				E('span', {}, _('The first points appear within 10-20 seconds. With the page closed, the signal is collected only when background collection is on.')) ]))
		]);
		var charts = E('div', { 'class': 'tg-stats-charts', 'id': 'stats-charts' }, [
			chartCard(_('Uplink latency'), 'chart-ping'),
			chartCard(_('Signal level'), 'chart-signal'),
			chartCard('RSRP', 'chart-rsrp', 'card-rsrp', true),
			chartCard('SINR', 'chart-sinr', 'card-sinr', true),
			chartCard(_('Modem temperature'), 'chart-temp', 'card-temp', true)
		]);

		/* ---------- monthly traffic ---------- */
		var traffic = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Monthly traffic') ]),
			E('div', { 'id': 'traffic-table' }, [])
		]);

		var body = E('div', { 'class': 'tg-stats' }, [
			head,
			tiles,
			empty,
			charts,
			traffic
		]);

		paintHead();
		// redraw() looks its targets up by id: the first one runs once LuCI has put the page in.
		window.setTimeout(function() { refresh(first); }, 0);
		poll.add(function() {
			if (document.hidden) { return Promise.resolve(); }
			return refresh(null, true);
		}, 10);
		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
