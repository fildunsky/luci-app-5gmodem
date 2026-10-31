'use strict';
'require baseclass';
'require uci';
'require view.modem5g.mutil as mutil';

var LS_TAB = '5gm-mvtab';
var TAB_KEYS = [ 'sig', 'freq', 'cell', 'more' ];
var BLK_TAB = { reboot: 'freq', freq: 'freq', cell: 'cell', ttl: 'more', hist: 'more' };
var SPARK_N = 60;

var st = null;

function tabTitles() {
	return { sig: _('Signal'), freq: _('Bands'), cell: _('Cell'), more: _('More') };
}

function enabled() {
	return uci.get('5gmodem', '@5gmodem[0]', 'mobile_view') !== '0';
}

function val(v) {
	var s = String(v == null ? '' : v).trim();
	if (s === '' || s === '-') { return null; }
	var n = parseFloat(s);
	return isNaN(n) ? null : n;
}

function qualWord(lvl) {
	return [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][lvl];
}

function lvlClass(lvl) {
	return [ 'tg-mv-bad', 'tg-mv-warn', 'tg-mv-ok', 'tg-mv-good' ][lvl] || '';
}

function readTab() {
	var t = null;
	try { t = window.localStorage.getItem(LS_TAB); } catch (e) {}
	return TAB_KEYS.indexOf(t) >= 0 ? t : 'sig';
}

function setTab(t) {
	if (!st) { return; }
	st.tab = t;
	document.body.setAttribute('data-mvtab', t);
	TAB_KEYS.forEach(function(k) {
		var b = st.tabBtn[k];
		if (!b) { return; }
		b.classList.toggle('on', k === t);
		b.setAttribute('aria-selected', k === t ? 'true' : 'false');
	});
	try { window.localStorage.setItem(LS_TAB, t); } catch (e) {}
}

function tagChildren() {
	var h = st.host;
	Array.prototype.forEach.call(h.children, function(n) {
		if (n === st.tabs) { return; }
		var t = 'top';
		var blk = n.getAttribute('data-blk');
		if (blk && BLK_TAB[blk]) { t = BLK_TAB[blk]; }
		else if (n === st.sig) { t = 'sig'; }
		if (n.getAttribute('data-mv') !== t) { n.setAttribute('data-mv', t); }
	});
	TAB_KEYS.forEach(function(k) {
		var has = Array.prototype.some.call(h.children, function(n) {
			return n.getAttribute('data-mv') === k && !n.classList.contains('tg-arr-off')
				&& !n.classList.contains('tg-arr-strip') && n.style.display !== 'none';
		});
		if (st.tabBtn[k]) { st.tabBtn[k].hidden = !has; }
	});
	if (st.tabBtn[st.tab] && st.tabBtn[st.tab].hidden) { setTab('sig'); }
}

function spark(key, v) {
	var a = st.hist[key] || (st.hist[key] = []);
	if (v != null) { a.push(v); if (a.length > SPARK_N) { a.shift(); } }
	if (a.length < 3) { return '<svg class="tg-mv-spark" aria-hidden="true"></svg>'; }
	var mn = Math.min.apply(null, a), mx = Math.max.apply(null, a);
	if (mx - mn < 1) { mx = mn + 1; }
	var pts = a.map(function(x, i) {
		return (i * 100 / (a.length - 1)).toFixed(1) + ',' + (16 - 14 * (x - mn) / (mx - mn)).toFixed(1);
	}).join(' ');
	return '<svg class="tg-mv-spark" viewBox="0 0 100 18" preserveAspectRatio="none" aria-hidden="true"><polyline points="' + pts + '"/></svg>';
}

function tile(key, label, unit, v, rat, hk) {
	var lvl = mutil.qualLevel(key, v, rat);
	var pct = mutil.qualPct(key, v, rat);
	var word = (lvl == null) ? '' : qualWord(lvl);
	var cls = (lvl == null) ? '' : lvlClass(lvl);
	return '<div class="tg-mv-tile ' + cls + '">' +
		'<div class="tg-mv-k"><span>' + label + '</span><span class="tg-mv-w">' + word + '</span></div>' +
		'<div class="tg-mv-v">' + (Math.round(v * 10) / 10) + ' <small>' + unit + '</small></div>' +
		'<div class="tg-mv-meter"><i style="width:' + (pct == null ? 0 : pct) + '%"></i></div>' +
		spark(hk || key, v) + '</div>';
}

function freqPart(s) {
	var m = /\(([^)]*)\)/.exec(mutil.caSplitBand(s).band || '');
	return m ? m[1] : '';
}

function bandPart(s) {
	var b = mutil.caSplitBand(s).band || '';
	return String(b).replace(/\s*\(.*$/, '').trim();
}

function carriers(j) {
	var out = [];
	var p = String(j.pband || '').trim();
	if (p && p !== '-') { out.push({ t: 'PCC', b: p, r: j.rsrp, q: j.rsrq, s: j.sinr, bw: j.bandwidth }); }
	for (var i = 1; i <= 4; i++) {
		var s = String(j['s' + i + 'band'] || '').trim();
		if (!s || s === '-') { continue; }
		var stt = String(j['s' + i + 'state'] || '');
		if (/deactiv|inactiv/i.test(stt)) { continue; }
		out.push({ t: /^n\d/.test(bandPart(s)) ? 'NR' : 'SCC' + i, b: s, r: j['s' + i + 'rsrp'], q: j['s' + i + 'rsrq'], s: j['s' + i + 'sinr'] });
	}
	return out;
}

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"]/g, function(c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
}

function ccHead(c) {
	var sp = mutil.caSplitBand(c.b);
	var bw = sp.bw || c.bw || '';
	var f = freqPart(c.b);
	var tail = [ f, bw ].filter(function(x) { return !!x; }).join(' · ');
	var nr = /^n/.test(bandPart(c.b));
	return '<div class="tg-mv-cch"><span class="tg-mv-t">' + esc(c.t) + '</span>' +
		'<span class="tg-mv-bp' + (nr ? ' tg-mv-bp-nr' : '') + '">' + esc(bandPart(c.b)) + '</span>' +
		(tail ? '<span class="tg-mv-cct">' + esc(tail) + '</span>' : '') + '</div>';
}

function lvlSpan(key, v, rat) {
	var n = val(v);
	if (n == null) { return '<span class="tg-mv-r">—</span>'; }
	var lvl = mutil.qualLevel(key, n, rat);
	var cl = lvl == null ? '' : lvlClass(Math.min(3, Math.max(0, lvl)));
	return '<span class="tg-mv-r ' + cl + '">' + (Math.round(n * 10) / 10) + '</span>';
}

function techBadge(j, cs) {
	var m = String(j.mode || '').trim();
	var k = mutil.ratFill ? mutil.ratFill(m) : 'none';
	var big = { sa: '5G', nsa: '5G', lte: '4G', umts: '3G', gsm: '2G' }[k] || '—';
	var sub = '';
	if (k === 'sa') { sub = 'SA'; }
	else if (k === 'nsa') { sub = 'NSA'; }
	else if (k === 'lte') { sub = /lte-a|4g\+/i.test(m) || cs.length > 1 ? 'LTE-A' : 'LTE'; }
	else if (k === 'umts') { sub = (/hspa\+?|hsdpa|hsupa/i.exec(m) || [ 'WCDMA' ])[0].toUpperCase(); }
	else if (k === 'gsm') { sub = /edge/i.test(m) ? 'EDGE' : 'GSM'; }
	if ((k === 'nsa' || k === 'lte' || k === 'sa') && cs.length > 1) { sub += '\n' + cs.length + 'CA'; }
	st.badge.firstChild.textContent = big;
	st.badge.lastChild.textContent = sub;
	st.badge.hidden = false;
}

function render(j) {
	var rat = mutil.qualRat(j.mode);
	mutil.qualRssiCap(j.rsrq);
	var cs = carriers(j);
	techBadge(j, cs);
	var defs = (rat === 'umts')
		? [ [ 'rscp', 'RSCP', 'dBm', j.rscp ], [ 'ecio', 'Ec/Io', 'dB', j.ecio ], [ 'rssi', 'RSSI', 'dBm', j.rssi ] ]
		: [ [ 'rssi', 'RSSI', 'dBm', j.rssi ], [ 'rsrp', 'RSRP', 'dBm', j.rsrp ], [ 'rsrq', 'RSRQ', 'dB', j.rsrq ], [ 'sinr', 'SINR', 'dB', j.sinr ] ];
	var html = '';
	defs.forEach(function(d) {
		var v = val(d[3]);
		if (v != null) { html += tile(d[0], d[1], d[2], v, rat); }
	});
	var pcc = cs.length && cs[0].t === 'PCC' ? cs[0] : null;
	st.pccHead.innerHTML = pcc ? ccHead(pcc) : '';
	st.tiles.innerHTML = html;
	st.pcc.hidden = !html;

	var nrc = null;
	cs.forEach(function(c) { if (!nrc && c.t === 'NR') { nrc = c; } });
	var nh = '';
	if (nrc) {
		[ [ 'rsrp', 'RSRP', 'dBm', nrc.r ], [ 'rsrq', 'RSRQ', 'dB', nrc.q ], [ 'sinr', 'SINR', 'dB', nrc.s ] ].forEach(function(d) {
			var v = val(d[3]);
			if (v != null) { nh += tile(d[0], d[1], d[2], v, 'nr', 'nr' + d[0]); }
		});
	}
	st.nrHead.innerHTML = nrc ? ccHead(nrc) : '';
	st.nrTiles.innerHTML = nh;
	st.nr.hidden = !nrc || !nh;

	var rows = cs.filter(function(c) { return c.t !== 'PCC' && c !== nrc; }).map(function(c) {
		var r = /^n/.test(bandPart(c.b)) ? 'nr' : rat;
		return '<div class="tg-mv-car">' + ccHead(c) +
			'<span class="tg-mv-cv">RSRP ' + lvlSpan('rsrp', c.r, r) + '</span>' +
			'<span class="tg-mv-cv">SINR ' + lvlSpan('sinr', c.s, r) + '</span></div>';
	}).join('');
	st.cars.innerHTML = rows;
	st.cars.hidden = !rows;
	st.carsTitle.hidden = !(html || nh || rows);
}

function syncSim() {
	var box = document.getElementById('simslotn');
	if (!st || !st.sim || !box) { return; }
	var mob = window.matchMedia && window.matchMedia('(max-width: 700px)').matches;
	if (!st.simHome && box.parentNode !== st.simBody) { st.simHome = box.parentNode; }
	var dst = mob ? st.simBody : st.simHome;
	if (dst && box.parentNode !== dst) { dst.appendChild(box); }
	st.sim.hidden = !mob || box.style.display === 'none' || !box.children.length;
}

function markMhz() {
	if (!st || !st.host.isConnected) { return; }
	Array.prototype.forEach.call(st.host.querySelectorAll('#mode .tginfo-freq:not(.tg-mv-mhz)'), function(n) {
		if (/^\s*\(/.test(n.textContent)) { n.classList.add('tg-mv-mhz'); }
	});
}

function clearSig() {
	if (!st) { return; }
	st.hist = {};
	st.tiles.innerHTML = '';
	st.pcc.hidden = true;
	st.nrTiles.innerHTML = '';
	st.nr.hidden = true;
	st.cars.innerHTML = '';
	st.cars.hidden = true;
	st.carsTitle.hidden = true;
	st.badge.hidden = true;
}

return baseclass.extend({
	API: 309092,

	prepare: function(root) {
		st = null;
		document.body.classList.toggle('tg-mv', enabled());
		if (!enabled()) { return; }
		var mib = root.querySelector('#modem-info-block');
		if (!mib || !mib.parentNode) { return; }
		var host = mib.parentNode;
		var titles = tabTitles();
		var tabBtn = {};
		var tabs = E('div', { 'class': 'tg-mv-tabs', 'role': 'tablist' }, TAB_KEYS.map(function(k) {
			var b = E('button', {
				'type': 'button',
				'role': 'tab',
				'class': 'tg-mv-tab',
				'click': function(ev) { ev.preventDefault(); setTab(k); }
			}, titles[k]);
			tabBtn[k] = b;
			return b;
		}));
		var tiles = E('div', { 'class': 'tg-mv-tiles' });
		var pccHead = E('div');
		var pcc = E('div', { 'class': 'tg-mv-cc', 'hidden': true }, [ pccHead, tiles ]);
		var nrTiles = E('div', { 'class': 'tg-mv-tiles tg-mv-tiles3' });
		var nrHead = E('div');
		var nr = E('div', { 'class': 'tg-mv-cc', 'hidden': true }, [ nrHead, nrTiles ]);
		var cars = E('div', { 'class': 'tg-mv-cars', 'hidden': true });
		var carsTitle = E('div', { 'class': 'tg-mv-sect', 'hidden': true }, _('Carriers'));
		var sigBox = E('div', { 'class': 'tg-mv-sig' }, [ carsTitle, pcc, nr, cars ]);
		var badge = E('div', { 'class': 'tg-mv-badge', 'hidden': true }, [ E('b', {}, ''), E('small', {}, '') ]);
		var gen = mib.querySelector('.tginfo-general');
		if (gen) { gen.insertBefore(badge, gen.firstChild); }
		var simBody = E('div', { 'class': 'tg-mv-simbody' });
		var sim = E('div', { 'class': 'tg-mv-simcard', 'hidden': true }, [
			E('div', { 'class': 'tg-mv-sect' }, _('SIM card')), simBody
		]);
		host.insertBefore(tabs, host.firstChild);
		host.insertBefore(sigBox, tabs.nextSibling);
		host.insertBefore(sim, mib.nextSibling);
		st = { host: host, tabs: tabs, sig: sigBox, tiles: tiles, pcc: pcc, pccHead: pccHead, nr: nr, nrHead: nrHead, nrTiles: nrTiles,
			cars: cars, carsTitle: carsTitle, badge: badge, sim: sim, simBody: simBody,
			tabBtn: tabBtn, tab: readTab(), hist: {} };
		syncSim();
		if (window.matchMedia) {
			var mq = window.matchMedia('(max-width: 700px)');
			var onMq = function() { syncSim(); tagChildren(); };
			if (mq.addEventListener) { mq.addEventListener('change', onMq); } else if (mq.addListener) { mq.addListener(onMq); }
		}
		setTab(st.tab);
		tagChildren();
	},

	reset: function() {
		if (st && st.host.isConnected) { clearSig(); tagChildren(); }
	},

	tick: function(json) {
		if (st && st.host.isConnected) { markMhz(); window.setTimeout(markMhz, 0); }
		if (!st || !st.host.isConnected || !json || json.error) {
			if (st && st.host.isConnected) {
				if (json && json.error && json.error !== 'busy' && !json.modem) { clearSig(); }
				tagChildren();
			}
			return;
		}
		render(json);
		syncSim();
		tagChildren();
	}
});
