'use strict';
'require baseclass';
'require fs';
'require uci';
'require ui';

var BIN = '/usr/share/5gmodem/setopt.sh';
var KEYS = [ 'net', 'conn', 'freq', 'ttl', 'restart', 'cell', 'hist' ];
var FIXED = { conn: true };
var BLK = { restart: 'reboot', cell: 'cell', freq: 'freq', ttl: 'ttl', hist: 'hist' };
var SVG_GRIP = '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" aria-hidden="true"><circle cx="9" cy="6" r="1.6"/><circle cx="15" cy="6" r="1.6"/><circle cx="9" cy="12" r="1.6"/><circle cx="15" cy="12" r="1.6"/><circle cx="9" cy="18" r="1.6"/><circle cx="15" cy="18" r="1.6"/></svg>';
var SVG_ARRANGE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M8 19V5M4 9l4-4 4 4M16 5v14M12 15l4 4 4-4"/></svg>';
var SVG_EYE = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>';
var SVG_EYE_OFF = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/><path d="M3 3l18 18"/></svg>';

var st = null;

function opt(k) {
	return String(uci.get('5gmodem', '@5gmodem[0]', k) || '');
}

function merge(base, keep) {
	var out = keep.slice();
	base.forEach(function(k, i) {
		if (out.indexOf(k) >= 0) { return; }
		var at = 0;
		for (var j = i - 1; j >= 0; j--) {
			var p = out.indexOf(base[j]);
			if (p >= 0) { at = p + 1; break; }
		}
		out.splice(at, 0, k);
	});
	return out;
}

function savedOrder() {
	var seen = {};
	var got = opt('net_order').split(/\s+/).filter(function(k) {
		if (KEYS.indexOf(k) < 0 || seen[k]) { return false; }
		seen[k] = true;
		return true;
	});
	return merge(KEYS, got);
}

function savedHidden() {
	var h = {};
	opt('net_hidden').split(/\s+/).forEach(function(k) {
		if (KEYS.indexOf(k) >= 0 && !FIXED[k]) { h[k] = true; }
	});
	return h;
}

function titles() {
	return { net: _('Internet priority'), conn: _('Modem') };
}

function nodes(k) {
	var h = st.host, out = [];
	var add = function(n) { if (n && n.parentNode === h) { out.push(n); } };
	add(st.strip[k]);
	if (k === 'conn') {
		add(h.querySelector('#modem-none-block'));
		add(st.el.conn);
		add(h.querySelector('.tg-simple-toggle'));
	} else {
		add(st.el[k]);
	}
	return out;
}

function present() {
	return st.full.filter(function(k) { return st.el[k] && st.el[k].parentNode === st.host; });
}

function placeAll() {
	present().forEach(function(k) {
		nodes(k).forEach(function(n) { st.host.insertBefore(n, st.end); });
	});
}

function paintHidden() {
	KEYS.forEach(function(k) {
		var off = !!st.hidden[k];
		[ st.el[k], st.strip[k] ].forEach(function(n) { if (n) { n.classList.toggle('tg-arr-off', off); } });
		var b = st.eye[k];
		if (b) {
			b.innerHTML = off ? SVG_EYE_OFF : SVG_EYE;
			b.appendChild(E('span', {}, off ? _('Show') : _('Hide')));
			b.setAttribute('aria-pressed', off ? 'true' : 'false');
		}
	});
}

function save() {
	if (st.timer) { window.clearTimeout(st.timer); }
	st.timer = window.setTimeout(function() {
		st.timer = null;
		st.full = merge(st.full, present());
		var args = [ 'netblocks' ].concat(st.full.map(function(k) { return st.hidden[k] ? '-' + k : k; }));
		fs.exec(BIN, args).then(function(r) {
			if (r && r.code) { throw new Error(r.stderr || r.code); }
		}).catch(function(e) {
			ui.addNotification(null, E('p', _('Could not save the block order') + ': ' + (e.message || e)), 'error');
		});
	}, 300);
}

function moveUnit(k, dir) {
	var list = present(), i = list.indexOf(k), j = i + dir;
	if (i < 0 || j < 0 || j >= list.length) { return false; }
	list.splice(i, 1);
	list.splice(j, 0, k);
	st.full = merge(st.full, list);
	var nx = list[j + 1];
	var ref = nx ? nodes(nx)[0] : st.end;
	nodes(k).forEach(function(n) { st.host.insertBefore(n, ref); });
	return true;
}

function unitRect(k) {
	var top = Infinity, bottom = -Infinity;
	nodes(k).forEach(function(n) {
		var r = n.getBoundingClientRect();
		if (!r.height) { return; }
		if (r.top < top) { top = r.top; }
		if (r.bottom > bottom) { bottom = r.bottom; }
	});
	return top === Infinity ? null : { top: top, bottom: bottom, mid: (top + bottom) / 2 };
}

function lifted(k) {
	return st.strip[k] || st.el[k];
}

function onDragMove(ev) {
	var d = st && st.drag;
	if (!d) { return; }
	ev.preventDefault();
	var y = ev.clientY, list = present(), i = list.indexOf(d.key);
	var prev = i > 0 ? unitRect(list[i - 1]) : null;
	var next = i >= 0 && i < list.length - 1 ? unitRect(list[i + 1]) : null;
	if (prev && y < prev.mid) { moveUnit(d.key, -1); d.moved = true; }
	else if (next && y > next.mid) { moveUnit(d.key, 1); d.moved = true; }
	var h = window.innerHeight || 0;
	if (y < 48) { window.scrollBy(0, -12); }
	else if (h && y > h - 48) { window.scrollBy(0, 12); }
}

function onDragEnd() {
	var d = st && st.drag;
	if (!d) { return; }
	st.drag = null;
	document.removeEventListener('pointermove', onDragMove, true);
	document.removeEventListener('pointerup', onDragEnd, true);
	document.removeEventListener('pointercancel', onDragEnd, true);
	try { d.grip.releasePointerCapture(d.pid); } catch (e) {}
	st.host.classList.remove('tg-arr-dragging');
	var l = lifted(d.key);
	if (l) { l.classList.remove('tg-arr-lift'); }
	if (d.moved) { save(); }
}

function onDragStart(ev, k, grip) {
	if (!st.edit || (ev.pointerType === 'mouse' && ev.button !== 0)) { return; }
	ev.preventDefault();
	if (st.drag) { onDragEnd(); }
	st.drag = { key: k, grip: grip, pid: ev.pointerId, moved: false };
	try { grip.setPointerCapture(ev.pointerId); } catch (e) {}
	st.host.classList.add('tg-arr-dragging');
	var l = lifted(k);
	if (l) { l.classList.add('tg-arr-lift'); }
	document.addEventListener('pointermove', onDragMove, true);
	document.addEventListener('pointerup', onDragEnd, true);
	document.addEventListener('pointercancel', onDragEnd, true);
}

function makeGrip(k) {
	var g = E('button', {
		'type': 'button',
		'class': 'tg-arr-ctl tg-arr-b tg-arr-grip',
		'title': _('Drag to move, or use the arrow keys'),
		'aria-label': _('Drag to move, or use the arrow keys')
	});
	g.innerHTML = SVG_GRIP;
	g.addEventListener('pointerdown', function(ev) { onDragStart(ev, k, g); });
	g.addEventListener('click', function(ev) { ev.preventDefault(); ev.stopPropagation(); });
	g.addEventListener('keydown', function(ev) {
		var dir = (ev.key === 'ArrowUp') ? -1 : (ev.key === 'ArrowDown') ? 1 : 0;
		if (!dir || !st.edit) { return; }
		ev.preventDefault();
		if (moveUnit(k, dir)) {
			g.focus();
			try { g.scrollIntoView({ block: 'nearest' }); } catch (e) {}
			save();
		}
	});
	return g;
}

function makeEye(k) {
	var b = E('button', {
		'type': 'button',
		'class': 'tg-arr-ctl tg-arr-b tg-arr-eye',
		'click': function(ev) {
			ev.preventDefault();
			ev.stopPropagation();
			st.hidden[k] = !st.hidden[k];
			paintHidden();
			save();
		}
	});
	st.eye[k] = b;
	return b;
}

function decorate(k) {
	var el = st.el[k];
	if (!el) { return; }
	if (BLK[k]) {
		var h3 = el.querySelector('h3');
		if (!h3) { return; }
		h3.insertBefore(makeGrip(k), h3.firstChild);
		h3.appendChild(makeEye(k));
		return;
	}
	var head = E('h3', { 'class': 'tg-arr-head' }, [ makeGrip(k), E('span', { 'class': 'tg-arr-sp' }), E('span', {}, titles()[k]) ]);
	if (!FIXED[k]) { head.appendChild(makeEye(k)); }
	var strip = E('div', { 'class': 'cbi-section tg-arr-strip' }, [ head ]);
	st.strip[k] = strip;
	var first = nodes(k)[0];
	if (first) { st.host.insertBefore(strip, first); }
}

function setEdit(on) {
	on = !!on && !document.body.classList.contains('sc-simple');
	if (st.drag) { onDragEnd(); }
	st.edit = on;
	st.host.classList.toggle('tg-arr-edit', on);
	if (on) {
		var d = st.tools.querySelector('.tg-arr-done');
		if (d) { d.focus(); }
	} else if (st.open && st.open.isConnected) {
		st.open.focus();
	}
}

function resetAll() {
	st.full = KEYS.slice();
	st.hidden = {};
	placeAll();
	paintHidden();
	if (st.timer) { window.clearTimeout(st.timer); st.timer = null; }
	fs.exec(BIN, [ 'netblocks' ]).catch(function(e) {
		ui.addNotification(null, E('p', _('Could not save the block order') + ': ' + (e.message || e)), 'error');
	});
}

function toolBtn(cls, label, fn) {
	return E('button', {
		'type': 'button',
		'class': 'tg-arr-b ' + cls,
		'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); fn(); }
	}, label);
}

return baseclass.extend({
	API: 30206,

	prepare: function(root) {
		var mib = root.querySelector('#modem-info-block');
		if (!mib || !mib.parentNode) { return; }
		var host = mib.parentNode;
		var el = { conn: mib };
		var mount = root.querySelector('.netpri-mount');
		if (mount && mount.parentNode === host) { el.net = mount; }
		Object.keys(BLK).forEach(function(k) {
			var s = root.querySelector('[data-blk="' + BLK[k] + '"]');
			if (s && s.parentNode === host) { el[k] = s; s.classList.add('tg-arr-sec'); }
		});
		var last = null;
		Array.prototype.forEach.call(host.childNodes, function(n) {
			for (var k in el) { if (el[k] === n) { last = n; } }
		});
		var end = document.createComment('');
		host.insertBefore(end, last ? last.nextSibling : null);
		host.classList.add('tg-arr-host');
		st = { host: host, el: el, end: end, strip: {}, eye: {}, full: savedOrder(), hidden: savedHidden(),
			edit: false, drag: null, timer: null, tools: null, open: null };
		placeAll();
		paintHidden();
	},

	attach: function() {
		if (!st || !st.host.isConnected || st.tools) { return; }
		var row = st.host.querySelector('.tg-simple-toggle');
		if (!row) { return; }
		KEYS.forEach(decorate);
		paintHidden();
		st.open = E('button', {
			'type': 'button',
			'class': 'tg-arr-b tg-arr-icon tg-arr-open',
			'title': _('Arrange blocks'),
			'aria-label': _('Arrange blocks'),
			'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); setEdit(true); }
		});
		st.open.innerHTML = SVG_ARRANGE;
		st.tools = E('span', { 'class': 'tg-arr-tools' }, [
			st.open,
			toolBtn('tg-arr-reset', _('Reset order'), resetAll),
			toolBtn('tg-arr-done', _('Done'), function() { setEdit(false); })
		]);
		row.insertBefore(st.tools, row.firstChild);
		st.host.addEventListener('click', function(ev) {
			if (!st.edit) { return; }
			var t = ev.target;
			if (!t.closest || t.closest('.tg-arr-b')) { return; }
			if (t.closest('.tg-arr-sec > h3') || t.closest('.tg-simple-toggle')) {
				ev.preventDefault();
				ev.stopPropagation();
			}
		}, true);
		document.addEventListener('keydown', function(ev) {
			if (st.edit && ev.key === 'Escape' && !document.body.classList.contains('modal-overlay-active')) { setEdit(false); }
		});
	},

	simple: function(on) {
		if (on && st && st.edit) { setEdit(false); }
	}
});
