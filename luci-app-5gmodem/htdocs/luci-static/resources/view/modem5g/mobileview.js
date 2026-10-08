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

function tile(key, label, unit, v, rat) {
	var lvl = mutil.qualLevel(key, v, rat);
	var pct = mutil.qualPct(key, v, rat);
	var word = (lvl == null) ? '' : qualWord(lvl);
	var cls = (lvl == null) ? '' : lvlClass(lvl);
	return '<div class="tg-mv-tile ' + cls + '">' +
		'<div class="tg-mv-k"><span>' + label + '</span><span class="tg-mv-w">' + word + '</span></div>' +
		'<div class="tg-mv-v">' + (Math.round(v * 10) / 10) + ' <small>' + unit + '</small></div>' +
		'<div class="tg-mv-meter"><i style="width:' + (pct == null ? 0 : pct) + '%"></i></div>' +
		spark(key, v) + '</div>';
}

function bandPart(s) {
	var b = mutil.caSplitBand(s).band || '';
	return String(b).replace(/\s*\(.*$/, '').trim();
}

function carriers(j) {
	var out = [];
	var p = String(j.pband || '').trim();
	if (p && p !== '-') { out.push({ t: 'PCC', b: p, r: j.rsrp }); }
	for (var i = 1; i <= 4; i++) {
		var s = String(j['s' + i + 'band'] || '').trim();
		if (!s || s === '-') { continue; }
		var stt = String(j['s' + i + 'state'] || '');
		if (/deactiv|inactiv/i.test(stt)) { continue; }
		out.push({ t: /^n\d/.test(bandPart(s)) ? 'NR' : 'SCC', b: s, r: j['s' + i + 'rsrp'] });
	}
	return out;
}

function esc(s) {
	return String(s == null ? '' : s).replace(/[&<>"]/g, function(c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
}

function render(j) {
	var rat = mutil.qualRat(j.mode);
	var cs = carriers(j);
	var defs = (rat === 'umts')
		? [ [ 'rscp', 'RSCP', 'dBm', j.rscp ], [ 'ecio', 'Ec/Io', 'dB', j.ecio ], [ 'rssi', 'RSSI', 'dBm', j.rssi ] ]
		: [ [ 'rsrp', 'RSRP', 'dBm', j.rsrp ], [ 'sinr', 'SINR', 'dB', j.sinr ], [ 'rsrq', 'RSRQ', 'dB', j.rsrq ], [ 'rssi', 'RSSI', 'dBm', j.rssi ] ];
	var html = '';
	defs.forEach(function(d) {
		var v = val(d[3]);
		if (v != null) { html += tile(d[0], d[1], d[2], v, rat); }
	});
	st.tiles.innerHTML = html;
	st.tiles.hidden = !html;

	if (cs.length) {
		var rows = cs.map(function(c) {
			var sp = mutil.caSplitBand(c.b);
			var r = val(c.r);
			var lvl = r == null ? null : mutil.qualLevel('rsrp', r, /^n/.test(bandPart(c.b)) ? 'nr' : rat);
			var cl = lvl == null ? '' : lvlClass(Math.min(3, Math.max(0, lvl)));
			return '<div class="tg-mv-car"><span class="tg-mv-t">' + c.t + '</span><b>' + esc(bandPart(c.b)) +
				(sp.bw ? ' · ' + esc(sp.bw) : '') + '</b><span class="tg-mv-r ' + cl + '">' + (r == null ? '' : Math.round(r)) + '</span></div>';
		}).join('');
		st.cars.innerHTML = '<div class="tg-mv-h"><span>' + esc(_('Carriers')) + '</span><em>' + cs.length + '</em></div>' + rows;
		st.cars.hidden = false;
	} else {
		st.cars.innerHTML = '';
		st.cars.hidden = true;
	}
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
	st.tiles.hidden = true;
	st.cars.innerHTML = '';
	st.cars.hidden = true;
}

return baseclass.extend({
	API: 30206,

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
		var tiles = E('div', { 'class': 'tg-mv-tiles', 'hidden': true });
		var cars = E('div', { 'class': 'tg-mv-cars', 'hidden': true });
		var sigBox = E('div', { 'class': 'tg-mv-sig' }, [ tiles, cars ]);
		host.insertBefore(tabs, host.firstChild);
		host.insertBefore(sigBox, tabs.nextSibling);
		st = { host: host, tabs: tabs, sig: sigBox, tiles: tiles, cars: cars, tabBtn: tabBtn, tab: readTab(), hist: {} };
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
		tagChildren();
	}
});
