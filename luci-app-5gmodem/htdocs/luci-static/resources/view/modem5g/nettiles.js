'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';

var BIN = '/usr/share/5gmodem/setopt.sh';
var KEYS = [ 'net', 'conn', 'restart', 'sig', 'cell', 'hist', 'ttl', 'ca', 'freq' ];
var WIDE = { net: 1, conn: 1, restart: 1, ca: 1, freq: 1 };
var SIG_ROWS = [ 'csqn', 'rssin', 'rsrpn', 'sinrn', 'rsrqn', 'rscpn', 'ection' ];
var _drag = null;

function opt(k) {
	return String(uci.get('5gmodem', '@5gmodem[0]', k) || '');
}

function titles() {
	return {
		net: _('Internet priority'),
		conn: _('Modem'),
		restart: _('Restart modem'),
		sig: _('Signal'),
		cell: _('Cell information'),
		hist: _('History'),
		ttl: _('TTL fixing'),
		ca: _('Carriers and neighbours'),
		freq: _('Frequency management')
	};
}

function savedOrder() {
	var seen = {};
	var out = opt('tiles_order').split(/\s+/).filter(function(k) {
		if (KEYS.indexOf(k) < 0 || seen[k]) { return false; }
		seen[k] = true;
		return true;
	});
	KEYS.forEach(function(k) { if (!seen[k]) { out.push(k); } });
	return out;
}

function savedHidden() {
	var h = {};
	opt('tiles_hidden').split(/\s+/).forEach(function(k) {
		if (KEYS.indexOf(k) >= 0) { h[k] = true; }
	});
	return h;
}

function tilesOf(grid) {
	return Array.prototype.filter.call(grid.children, function(c) {
		return c.classList && c.classList.contains('tgt-tile');
	});
}

function hid(el) {
	return !el || el.style.display === 'none';
}

function gripSvg() {
	var s = E('span', { 'class': 'tgt-grip' });
	s.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor"><circle cx="9" cy="6" r="1.6"/><circle cx="15" cy="6" r="1.6"/><circle cx="9" cy="12" r="1.6"/><circle cx="15" cy="12" r="1.6"/><circle cx="9" cy="18" r="1.6"/><circle cx="15" cy="18" r="1.6"/></svg>';
	return s;
}

function save(st) {
	var dom = tilesOf(st.grid).map(function(t) { return t.getAttribute('data-tile'); });
	st.order = dom.concat(st.order.filter(function(k) { return dom.indexOf(k) < 0; }));
	var args = [ 'tiles' ].concat(st.order.map(function(k) { return st.hidden[k] ? '-' + k : k; }));
	return fs.exec(BIN, args).catch(function(e) {
		ui.addNotification(null, E('p', _('Could not save the layout') + ': ' + (e.message || e)), 'error');
	});
}

function sync(st) {
	st.timer = null;
	tilesOf(st.grid).forEach(function(t) {
		var k = t.getAttribute('data-tile');
		var fn = st.empty[k];
		t.classList.toggle('tgt-empty', !!(fn && fn()));
		t.classList.toggle('tgt-off', !!st.hidden[k]);
		var b = t.querySelector('.tgt-vis');
		if (b) { b.textContent = st.hidden[k] ? _('Show') : _('Hide'); }
		var s = t.querySelector('.tgt-state');
		if (s) { s.textContent = st.hidden[k] ? _('Hidden') : ''; }
	});
}

function schedule(st) {
	if (!st.timer) { st.timer = window.setTimeout(function() { sync(st); }, 0); }
}

function setEdit(st, on) {
	st.edit = !!on;
	st.grid.classList.toggle('tgt-edit', st.edit);
	st.tools.classList.toggle('tgt-editing', st.edit);
	st.editBtn.textContent = st.edit ? _('Done') : _('Edit layout');
	st.editBtn.classList.toggle('cbi-button-action', st.edit);
	sync(st);
}

function placeTiles(st) {
	st.order.forEach(function(k) {
		var t = st.tiles[k];
		if (t) { st.grid.appendChild(t); }
	});
}

function resetLayout(st) {
	st.order = KEYS.slice();
	st.hidden = {};
	placeTiles(st);
	sync(st);
	return fs.exec(BIN, [ 'tiles' ]).catch(function(e) {
		ui.addNotification(null, E('p', _('Could not save the layout') + ': ' + (e.message || e)), 'error');
	});
}

function dragPlace(x, y) {
	var d = _drag, slot = d.slot, grid = slot.parentNode;
	var sr = slot.getBoundingClientRect();
	if (x >= sr.left && x <= sr.right && y >= sr.top && y <= sr.bottom) { return; }
	var cards = tilesOf(grid).filter(function(c) { return c !== d.tile && c.getClientRects().length; });
	var ref = null;
	for (var i = 0; i < cards.length; i++) {
		var r = cards[i].getBoundingClientRect();
		if (y < r.top) { ref = cards[i]; break; }
		if (y <= r.bottom && x < r.left + r.width / 2) { ref = cards[i]; break; }
	}
	var next = slot.nextSibling;
	if (next === d.tile) { next = next.nextSibling; }
	if (ref === next) { return; }
	if (ref) { grid.insertBefore(slot, ref); }
	else { grid.appendChild(slot); }
}

function dragBegin() {
	var d = _drag, t = d.tile, r = t.getBoundingClientRect();
	d.slot = E('div', { 'class': 'tgt-slot' + (t.classList.contains('tgt-wide') ? ' tgt-wide' : '') });
	d.slot.style.height = r.height + 'px';
	t.parentNode.insertBefore(d.slot, t);
	d.ox = d.x0 - r.left;
	d.oy = d.y0 - r.top;
	t.style.left = r.left + 'px';
	t.style.top = r.top + 'px';
	t.style.width = r.width + 'px';
	t.classList.add('tgt-lift');
	document.body.style.userSelect = 'none';
	d.active = true;
}

function dragMove(ev) {
	var d = _drag;
	if (!d) { return; }
	if (!d.active) {
		if (Math.abs(ev.clientX - d.x0) < 5 && Math.abs(ev.clientY - d.y0) < 5) { return; }
		dragBegin();
	}
	ev.preventDefault();
	d.tile.style.left = (ev.clientX - d.ox) + 'px';
	d.tile.style.top = (ev.clientY - d.oy) + 'px';
	dragPlace(ev.clientX, ev.clientY);
	var h = window.innerHeight || 0;
	if (ev.clientY < 48) { window.scrollBy(0, -14); }
	else if (h && ev.clientY > h - 48) { window.scrollBy(0, 14); }
}

function dragEnd() {
	var d = _drag;
	if (!d) { return; }
	_drag = null;
	document.removeEventListener('pointermove', dragMove, true);
	document.removeEventListener('pointerup', dragEnd, true);
	document.removeEventListener('pointercancel', dragEnd, true);
	try { d.handle.releasePointerCapture(d.pid); } catch (e) {}
	document.body.style.userSelect = '';
	if (!d.active) { return; }
	var t = d.tile;
	t.classList.remove('tgt-lift');
	[ 'left', 'top', 'width' ].forEach(function(k) { t.style[k] = ''; });
	if (d.slot && d.slot.parentNode) {
		d.slot.parentNode.insertBefore(t, d.slot);
		d.slot.parentNode.removeChild(d.slot);
	}
	save(d.st);
}

function dragStart(ev, st, tile, handle) {
	if (!st.edit || ev.button !== 0) { return; }
	if (ev.target.closest && ev.target.closest('button')) { return; }
	if (_drag) { dragEnd(); }
	_drag = { st: st, tile: tile, handle: handle, x0: ev.clientX, y0: ev.clientY, active: false, pid: ev.pointerId };
	try { handle.setPointerCapture(ev.pointerId); } catch (e) {}
	document.addEventListener('pointermove', dragMove, true);
	document.addEventListener('pointerup', dragEnd, true);
	document.addEventListener('pointercancel', dragEnd, true);
}

function makeTile(st, key, title, members) {
	var vis = E('button', {
		'class': 'btn cbi-button tgt-vis',
		'click': function(ev) {
			ev.preventDefault();
			st.hidden[key] = !st.hidden[key];
			sync(st);
			save(st);
		}
	}, _('Hide'));
	var bar = E('div', { 'class': 'tgt-bar' }, [
		gripSvg(),
		E('span', { 'class': 'tgt-title' }, title),
		E('span', { 'class': 'tgt-state' }, ''),
		vis
	]);
	var tile = E('div', { 'class': 'tgt-tile' + (WIDE[key] ? ' tgt-wide' : ''), 'data-tile': key }, [
		bar,
		E('div', { 'class': 'tgt-body' }, members),
		E('div', { 'class': 'tgt-note' }, _('No data right now'))
	]);
	bar.addEventListener('pointerdown', function(ev) { dragStart(ev, st, tile, bar); });
	bar.addEventListener('lostpointercapture', function() {
		if (_drag && _drag.tile === tile) { dragEnd(); }
	});
	return tile;
}

return baseclass.extend({
	API: 30001,

	enabled: function() {
		return opt('net_layout') === 'tiles';
	},

	build: function(root, ctx) {
		var q = function(s) { return root.querySelector(s); };
		var mib = q('#modem-info-block');
		if (!mib || !mib.parentNode) { return; }
		var host = mib.parentNode;
		var anchor = q('.netpri-mount') || mib;
		if (anchor.parentNode !== host) { anchor = mib; }
		var T = titles();
		var cell = q('[data-blk="cell"]');
		var rbb = q('#modem-reboot-block');
		var freq = q('[data-blk="freq"]');
		var ttl = q('[data-blk="ttl"]');
		var hist = q('[data-blk="hist"]');
		var net = q('.netpri-mount');
		var caComp = q('#ca-comp'), nbComp = q('#nb-comp'), antB = q('#antports-block');
		var sig = null, ca = null;
		if (cell) {
			var rows = SIG_ROWS.map(function(id) { return q('#' + id); }).filter(Boolean);
			if (rows.length) {
				var tb = E('table', { 'class': 'table' });
				rows.forEach(function(r) { tb.appendChild(r); });
				sig = ctx.collapsibleSection('sig', T.sig, [ tb ]);
			}
			var parts = [ caComp, nbComp, antB ].filter(Boolean);
			if (parts.length) { ca = ctx.collapsibleSection('ca', T.ca, parts); }
			var ct = cell.querySelector('h3 > span:last-child');
			if (ct) { ct.textContent = T.cell; }
		}
		var src = { net: net, conn: mib, restart: rbb, sig: sig, cell: cell, hist: hist, ttl: ttl, ca: ca, freq: freq };
		var grid = E('div', { 'class': 'tgt-grid' });
		var st = {
			grid: grid, edit: false, timer: null, tiles: {},
			order: savedOrder(), hidden: savedHidden(),
			empty: {
				net: function() { return !net || !net.querySelector('.netpri-btn, .netpribar-title'); },
				restart: function() { return hid(rbb); },
				sig: function() { return hid(cell); },
				cell: function() { return hid(cell); },
				ca: function() { return hid(cell) || (hid(caComp) && hid(nbComp) && hid(antB)); },
				freq: function() { return hid(freq); },
				ttl: function() { return hid(ttl); },
				hist: function() { return hid(hist); }
			}
		};
		st.editBtn = E('button', {
			'class': 'btn cbi-button tgt-editbtn',
			'click': function(ev) { ev.preventDefault(); setEdit(st, !st.edit); }
		}, _('Edit layout'));
		st.tools = E('div', { 'class': 'tgt-tools' }, [
			E('span', { 'class': 'tgt-hint' }, _('Drag tiles by their header to reorder them. Hidden tiles stay here as outlines.')),
			E('button', {
				'class': 'btn cbi-button cbi-button-reset tgt-resetbtn',
				'click': function(ev) { ev.preventDefault(); resetLayout(st); }
			}, _('Reset layout')),
			st.editBtn
		]);
		host.insertBefore(st.tools, anchor);
		host.insertBefore(grid, anchor);
		KEYS.forEach(function(k) {
			if (src[k]) { st.tiles[k] = makeTile(st, k, T[k], [ src[k] ]); }
		});
		placeTiles(st);
		try {
			var mo = new MutationObserver(function() { schedule(st); });
			[ rbb, cell, caComp, nbComp, antB, freq, ttl, hist ].forEach(function(el) {
				if (el) { mo.observe(el, { attributes: true, attributeFilter: [ 'style' ] }); }
			});
			if (net) { mo.observe(net, { childList: true }); }
		} catch (e) {}
		sync(st);
		return grid;
	}
});
