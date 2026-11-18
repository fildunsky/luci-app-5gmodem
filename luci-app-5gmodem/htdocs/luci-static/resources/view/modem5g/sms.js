'use strict';
'require dom';
'require fs';
'require ui';
'require uci';
'require view';
'require rpc';
'require poll';
'require view.modem5g.modemtabs as modemtabs';
'require sms-tool-5gm.editors as editors';
'require sms-tool-5gm.smssettings as smssettings';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.

	SMS tab: the former Inbox (readsms.js) and Outbox (sendsms.js) on one page.
	See docs/subsystems/sms.md#sms-page-smsjs.
*/

(function() {
	if (document.getElementById('tg-sms-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-sms-css';
	l.rel = 'stylesheet';
	l.type = 'text/css';
	l.href = L.resource('view/modem5g/page-sms.css');
	document.head.appendChild(l);
})();

var BRIDGE = '/usr/share/5gmodem/smsbridge.sh';
var PHONE_MQ = '(max-width: 700px)';

var callForwardSMS = rpc.declare({
	object: '5gmodem_sms_forward',
	method: 'forward',
	params: ['subject', 'message']
});

var smsReadOnly = false;
// what the backend actually read: a web-API stick keeps SMS in its own memory whatever
// sms.storage says (that choice is for AT modems), so its store comes from the status line
var smsWeb = false, smsStoreSeen = null;
var smsBook = [];

var ICONS = {
	msg: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></g>',
	send: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4Z"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	check: '<path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
	checks: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m1.5 12.5 4.5 4.5 9-10"/><path d="m11.5 16.5.5.5 9.5-10"/></g>',
	refresh: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 13a8.5 8.5 0 1 1-2.6-7.2L20.5 8"/><path d="M20.5 3v5h-5"/></g>',
	search: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></g>',
	pen: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4L19 9l-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/></g>',
	back: '<path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
	copy: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/></g>',
	fwd: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m15 5 6 6-6 6"/><path d="M21 11H10a6 6 0 0 0-6 6v2"/></g>',
	book: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12a1 1 0 0 1 1 1v16a1 1 0 0 1-1 1H6Z"/><path d="M4 7h3M4 12h3M4 17h3"/><circle cx="12.5" cy="10" r="2.3"/><path d="M9 16.5a3.5 3.5 0 0 1 7 0"/></g>',
	clock: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></g>',
	warn: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5 2.5 20h19Z"/><path d="M12 10v4.5M12 17.2v.3"/></g>',
	info: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.3"/></g>',
	selbox: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="17" height="17" rx="3"/><path d="m8 12 3 3 5-6"/></g>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size, cls) {
	var s = E('span', { 'class': cls || 'tg-sms-i', 'style': 'display:inline-flex' });
	s.innerHTML = svg(name, size);
	return s;
}
// A button with an icon; the label is always passed as a text node.
function ibtn(name, label, cls, attrs) {
	var a = { 'class': 'cbi-button ' + (cls || ''), 'type': 'button' };
	for (var k in (attrs || {})) { a[k] = attrs[k]; }
	var kids = [ icon(name, 15) ];
	if (label) { kids.push(E('span', { 'class': 'lbl' }, [ label ])); }
	return E('button', a, kids);
}

// The header card paints the memory bar; set by renderMain.
var smsPaintMem = null;
var smsPaintStore = null;
function msg_bar(v, m) {
	if (smsPaintMem) { smsPaintMem(v, m); }
}

// Say whose memory the bar counts: with the router archive on (always on over ModemManager)
// the numbers are the archive's, otherwise the SIM's or the modem's, as picked above the bar.
function sms_mem_label(v, m) {
	if (uci.get('5gmodem', 'sms', 'archive') == '1' || uci.get('5gmodem', 'sms', 'sms_via_mm') == '1') {
		return _('Router memory: %s/%s').format(v, m);
	}
	if ((smsStoreSeen || uci.get('5gmodem', 'sms', 'storage') || 'ME') === 'SM') {
		return _('SIM memory: %s/%s').format(v, m);
	}
	return _('Modem memory: %s/%s').format(v, m);
}

function sms_parse_status(res) {
	smsReadOnly = /read-only:\s*1/i.test(String(res || ''));
	var wasWeb = smsWeb;
	smsWeb = /web:\s*1/i.test(String(res || ''));
	var sm = String(res || '').match(/Storage type:\s*([A-Z]{2})/);
	smsStoreSeen = smsWeb && sm ? (sm[1] === 'SM' ? 'SM' : 'ME') : null;
	if (smsWeb !== wasWeb && smsPaintStore) { smsPaintStore(); }
	var u = String(res || '').match(/used:\s*(\d+)/i);
	var t = String(res || '').match(/total:\s*(\d+)/i);
	return { u: u ? u[1] : null, t: t ? t[1] : null };
}

function sms_cache_key() {
	var s = uci.get('5gmodem', 'sms', 'storage') || 'ME';
	var p = uci.get('5gmodem', 'sms', 'readport') || '';
	return 'sms-last:' + s + ':' + p + ':' + (uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
}
function sms_cache_save(list, u, t) {
	try {
		window.localStorage.setItem(sms_cache_key(),
			JSON.stringify({ list: list, u: u, t: t, read_only: smsReadOnly }));
	} catch (e) {}
}
function sms_cache_load() {
	try { return JSON.parse(window.localStorage.getItem(sms_cache_key()) || 'null'); }
	catch (e) { return null; }
}

function sms_ts_num(ts) {
	var s = String(ts || '');
	var n = Date.parse(s);
	if (isNaN(n)) { n = Date.parse(s.replace(' ', 'T')); }
	return isNaN(n) ? 0 : n;
}

function sms_localtime(ts, tz) {
	var off = /^[+-]\d{1,4}$/.test(String(tz == null ? '' : tz)) ? parseInt(tz, 10) : null;
	if (off === null) { return String(ts || ''); }
	var m = String(ts || '').match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/);
	if (!m) { return ts; }
	var d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) - off * 60000);
	if (isNaN(d.getTime())) { return ts; }
	var p = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
		' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function sms_pad(n) { return (n < 10 ? '0' : '') + n; }
function sms_daystr(off) {
	var d = new Date(Date.now() - off * 86400000);
	return d.getFullYear() + '-' + sms_pad(d.getMonth() + 1) + '-' + sms_pad(d.getDate());
}
function sms_parts_of(local) {
	return String(local || '').match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?/);
}
// List time: today HH:MM, yesterday, otherwise DD.MM.
function sms_short_time(local) {
	var m = sms_parts_of(local);
	if (!m) { return String(local || ''); }
	var day = m[1] + '-' + m[2] + '-' + m[3];
	if (day === sms_daystr(0)) { return m[4] ? m[4] + ':' + m[5] : ''; }
	if (day === sms_daystr(1)) { return _('yesterday'); }
	return m[3] + '.' + m[2];
}
function sms_day_label(local) {
	var m = sms_parts_of(local);
	if (!m) { return ''; }
	var day = m[1] + '-' + m[2] + '-' + m[3];
	if (day === sms_daystr(0)) { return _('today'); }
	if (day === sms_daystr(1)) { return _('yesterday'); }
	return m[3] + '.' + m[2] + '.' + m[1];
}
function sms_hm(local) {
	var m = sms_parts_of(local);
	return (m && m[4]) ? m[4] + ':' + m[5] : String(local || '');
}
function sms_local_now() {
	var d = new Date();
	return sms_daystr(0) + ' ' + sms_pad(d.getHours()) + ':' + sms_pad(d.getMinutes());
}

var SMS_URL_RE = /(https?:\/\/[^\s]+|(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,24}(?:\/[^\s]*)?)/gi;
function sms_linkify(text) {
	var out = [], last = 0, m;
	SMS_URL_RE.lastIndex = 0;
	while ((m = SMS_URL_RE.exec(text)) !== null) {
		var url = m[0].replace(/[).,;:!?\]]+$/, '');
		if (!/^https?:/i.test(url)) {
			if (m.index > 0 && text.charAt(m.index - 1) === '@') { continue; }
		}
		if (m.index > last) { out.push(document.createTextNode(text.slice(last, m.index))); }
		var href = /^https?:/i.test(url) ? url : ('http://' + url);
		out.push(E('a', {
			'href': href, 'target': '_blank', 'rel': 'noopener',
			'class': 'sms-link',
			'click': function(ev) {
				ev.stopPropagation();
				ev.preventDefault();
				window.open(ev.currentTarget.href, '_blank', 'noopener');
			}
		}, [ url ]));
		last = m.index + url.length;
	}
	if (last < text.length) { out.push(document.createTextNode(text.slice(last))); }
	return out;
}

var SMS_CODE_HINT = /код|code|парол|password|pin|otp|kod|验证码|mã/i;
var SMS_CODE_RE = /(^|[A-Za-z]-|[^0-9A-Za-z+.,:\/])(\d{3}[ -]\d{3}|\d{4,8})(?![0-9]|[.,:\/-][0-9]|\s?(?:руб|р\.|₽|rub|usd|eur|%))/gi;

function sms_copy_legacy(text) {
	var ta = E('textarea', { 'readonly': '', 'style': 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;font-size:16px' });
	ta.value = text;
	document.body.appendChild(ta);
	ta.focus();
	ta.select();
	ta.setSelectionRange(0, text.length);
	var ok = false;
	try { ok = document.execCommand('copy'); } catch (e) {}
	document.body.removeChild(ta);
	return ok;
}

function sms_copy_manual(text) {
	var inp = E('input', { 'type': 'text', 'readonly': '', 'value': text, 'class': 'cbi-input-text', 'style': 'width:100%;font-size:1.4em;text-align:center' });
	ui.showModal(_('Copy the code'), [
		E('p', {}, [ _('The browser did not allow copying. Select the code and copy it:') ]),
		inp,
		E('div', { 'class': 'right' }, [ E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Close') ]) ])
	]);
	inp.focus();
	inp.select();
}

function sms_copy_code(el) {
	var code = el.getAttribute('data-code');
	var done = function() {
		el.classList.add('copied');
		window.setTimeout(function() { el.classList.remove('copied'); }, 1500);
	};
	var legacy = function() { sms_copy_legacy(code) ? done() : sms_copy_manual(code); };
	if (navigator.clipboard && window.isSecureContext) {
		navigator.clipboard.writeText(code).then(done, legacy);
	} else {
		legacy();
	}
}

function sms_codify(nodes, text) {
	if (!SMS_CODE_HINT.test(text)) { return nodes; }
	var out = [];
	nodes.forEach(function(n) {
		if (n.nodeType !== 3) { out.push(n); return; }
		var s = n.nodeValue, last = 0, m;
		SMS_CODE_RE.lastIndex = 0;
		while ((m = SMS_CODE_RE.exec(s)) !== null) {
			var at = m.index + m[1].length;
			if (at > last) { out.push(document.createTextNode(s.slice(last, at))); }
			out.push(E('span', {
				'class': 'sms-code tg-sms-code',
				'role': 'button',
				'tabindex': '0',
				'title': _('Click to copy the code'),
				'data-code': m[2].replace(/[ -]/g, '')
			}, [ m[2], icon('copy', 12) ]));
			last = at + m[2].length;
		}
		if (last < s.length) { out.push(document.createTextNode(s.slice(last))); }
	});
	return out;
}

// Message text with links and copyable codes, always as text nodes.
/* see docs/subsystems/sms.md#xss-text-nodes */
function sms_rich(text) { return sms_codify(sms_linkify(text), text); }

var smsSeen = null;
var smsSeenFirst = false;

function sms_msg_old(item) {
	if (item && typeof item.okey === 'string' && item.okey) { return item.okey; }
	return [
		String(item.sender || ''),
		String(item.timestamp || '')
	].join('|').replace(/[\x00-\x1f]/g, ' ');
}

function sms_msg_key(item) {
	if (item && typeof item.key === 'string' && item.key) { return item.key; }
	return sms_msg_old(item);
}

function sms_msg_pairs(item) {
	if (item && Array.isArray(item.kp) && item.kp.length) { return item.kp; }
	if (item && Array.isArray(item.keys) && item.keys.length) {
		return item.keys.map(function(k) { return [ k, k ]; });
	}
	return [ [ sms_msg_key(item), sms_msg_old(item) ] ];
}

function sms_keys_apply(list, side) {
	var map = {};
	(Array.isArray(side) ? side : []).forEach(function(e) {
		if (e && e.index != null && typeof e.key === 'string') { map[String(e.index)] = e; }
	});
	list.forEach(function(o) {
		var e = o ? map[String(o.index)] : null;
		if (e) {
			o.key = e.key;
			o.okey = (typeof e.old === 'string') ? e.old : '';
		}
	});
}

function sms_msg_keys(item) {
	var out = [];
	sms_msg_pairs(item).forEach(function(p) {
		if (out.indexOf(p[0]) < 0) { out.push(p[0]); }
	});
	return out;
}

var smsPortMapP = null;

function sms_port_map() {
	if (!smsPortMapP) {
		smsPortMapP = L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh'), '[]')
			.then(function(out) {
				var map = {};
				try {
					(JSON.parse(out || '[]') || []).forEach(function(m) {
						(m && m.tty || []).forEach(function(t) { map[t] = m.path; });
					});
				} catch (e) {}
				return map;
			});
	}
	return smsPortMapP;
}

// The seen file belongs to the modem whose list is on screen, see sms.md#readunread-memory.
function sms_seen_exec(args) {
	var port = uci.get('5gmodem', 'sms', 'readport') || '';
	var direct = function() {
		return L.resolveDefault(fs.exec_direct(BRIDGE, args), '');
	};
	if (!port) { return direct(); }
	return sms_port_map().then(function(map) {
		var path = map[port] || '';
		var active = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		if (!path || path === active) { return direct(); }
		return fs.exec(BRIDGE, args, { SMS_MODEM: path })
			.then(function(r) { return (r && r.stdout) || ''; }, direct);
	});
}

function sms_seen_load() {
	return sms_seen_exec([ 'seen' ])
		.then(function(res) {
			smsSeen = new Set();
			smsSeenFirst = false;
			try {
				var d = JSON.parse(res || '{}');
				smsSeenFirst = (d.first == 1);
				(d.keys || []).forEach(function(k) { smsSeen.add(k); });
			} catch (e) {}
		});
}

function sms_seen_add(keys) {
	if (!keys || !keys.length) { return Promise.resolve(); }
	if (smsSeen) { keys.forEach(function(k) { smsSeen.add(k); }); }
	return sms_seen_exec([ 'seen-add' ].concat(keys));
}

// indexes: storage indices of merged messages ("3-4-7"); the bridge marks them read where the
// transport knows read flags (HiLink).
function sms_modem_markread(indexes) {
	var ids = [];
	indexes.forEach(function(x) {
		String(x || '').split('-').forEach(function(i) {
			if (/^\d+$/.test(i)) { ids.push(i); }
		});
	});
	if (!ids.length) { return Promise.resolve(); }
	return sms_seen_exec([ 'markread' ].concat(ids));
}

function sms_seen_sync(list) {
	if (!smsSeen || !smsSeenFirst || !list || !list.length) { return; }
	smsSeenFirst = false;
	var keys = [];
	list.forEach(function(m) { sms_msg_keys(m).forEach(function(k) { keys.push(k); }); });
	sms_seen_add(keys);
}

function sms_fmt_sender(s) {
	if (!s || s.indexOf('#') >= 0) { return s; }
	var digits = s.replace(/\D/g, '');
	var n = '';
	if (/^[78]\d{10}$/.test(digits)) { n = digits.slice(1); }
	else if (/^\d{10}$/.test(digits)) { n = digits; }
	else { return s; }
	return '+7 (' + n.slice(0, 3) + ') ' + n.slice(3, 6) + '-' + n.slice(6, 8) + '-' + n.slice(8, 10);
}

function sms_android_read(parts) {
	if (!parts.every(function(p) { return p.android_read != null; })) { return undefined; }
	return parts.every(function(p) { return String(p.android_read) === '1'; }) ? 1 : 0;
}

function sms_android_new(parts) {
	if (!parts.every(function(p) { return p.android_read != null; })) { return undefined; }
	return parts.some(function(p) { return String(p.android_read) === '0' && String(p.android_seen) !== '1'; }) ? 1 : 0;
}

function sms_item_new(item) {
	if (item && item.android_new != null) { return String(item.android_new) === '1'; }
	if (item && item.android_read != null) { return String(item.android_read) === '0' && String(item.android_seen) !== '1'; }
	return !!(smsSeen && !smsSeenFirst && sms_msg_pairs(item).some(function(p) {
		return !smsSeen.has(p[0]) && !smsSeen.has(p[1]);
	}));
}

// One message as the page keeps it: raw item plus what the views need.
function sms_make_card(item, hide) {
	var sender = String(item.sender || '');
	var shown = sender;
	if (hide && sender.includes(hide)) { shown = sender.slice(0, -5) + '#####'; }
	var local = sms_localtime(item.timestamp, item.tz);
	return {
		item: item,
		index: String(item.index),
		raw: sender,
		shown: shown,
		local: local,
		epoch: sms_ts_num(local),
		text: String(item.content || '').replace(/\s+/g, ' ').trim(),
		keys: sms_msg_keys(item),
		parts: parseInt(item.total, 10) || 1,
		isNew: sms_item_new(item)
	};
}

// Parts of one long SMS share sender, the 8-bit UDH reference and the part
// count. The reference wraps, so one sender reuses it: a part joins a group only
// within SMS_GROUP_WINDOW of the group's first part and only into a free part
// slot. A byte-identical copy of a stored part rides along so deleting the card
// frees its slot too; any other part with a taken number starts its own group.
// 24 h: parts carry the SMSC time stamp, so they are seconds apart however late
// they arrive. Keep in step with _kb_build in smsbridge.sh.
var SMS_GROUP_WINDOW = 24 * 3600 * 1000;
function sms_merge_parts(json) {
	var groups = [], open = {};
	json.forEach(function(o) {
		var total = parseInt(o.total, 10), pn = parseInt(o.part, 10);
		if (o.reference == null || !(total > 1) || isNaN(pn)) {
			groups.push({ parts: [ o ], all: [ o ] });
			return;
		}
		var base = [ o.sender, o.reference, total ].join('#');
		var ts = sms_ts_num(o.timestamp);
		var list = open[base] = open[base] || [];
		var g = null, dup = false;
		for (var i = 0; i < list.length && !g; i++) {
			var c = list[i];
			if (ts && c.ts && Math.abs(ts - c.ts) > SMS_GROUP_WINDOW) { continue; }
			var have = c.byPart[pn];
			if (have === undefined) { g = c; }
			else if (String(have.content) === String(o.content)) { g = c; dup = true; }
		}
		if (!g) {
			g = { ts: ts, byPart: {}, parts: [], all: [] };
			list.push(g);
			groups.push(g);
		}
		if (!dup) { g.byPart[pn] = o; g.parts.push(o); }
		else if (String(o.timestamp || '') >= String(g.byPart[pn].timestamp || '')) {
			// a resent segment: the later copy gives the time, as before
			g.parts[g.parts.indexOf(g.byPart[pn])] = o;
			g.byPart[pn] = o;
		}
		g.all.push(o);
	});
	return groups.map(function(g) {
		var parts = g.parts.slice().sort(function(a, b) { return (a.part || 0) - (b.part || 0); });
		var first = parts[0];
		var text = parts.map(function(p) { return p.content; }).join('');
		var want = first.total || 0;
		if (want > 1 && parts.length < want) {
			text += ' [' + parts.length + '/' + want + ']';
		}
		var pkeys = [], pkp = [];
		g.all.forEach(function(p) {
			var pk = sms_msg_key(p), po = sms_msg_old(p);
			if (pkeys.indexOf(pk) < 0) { pkeys.push(pk); }
			if (!pkp.some(function(x) { return x[0] === pk && x[1] === po; })) {
				pkp.push([ pk, po ]);
			}
		});
		var idx = parts.map(function(p) { return p.index; });
		g.all.forEach(function(p) { if (parts.indexOf(p) < 0) { idx.push(p.index); } });
		return {
			android_new: sms_android_new(parts),
			android_read: sms_android_read(parts),
			sender: first.sender,
			timestamp: first.timestamp,
			tz: first.tz,
			total: first.total,
			index: idx.join('-'),
			content: text,
			keys: pkeys,
			kp: pkp
		};
	});
}

function sms_persist(values) {
	var args = [ 'smsopt' ];
	for (var k in values) {
		var cur = uci.get('5gmodem', 'sms', k);
		var val = (values[k] == null) ? '' : String(values[k]);
		if (String(cur == null ? '' : cur) === val) { continue; }
		uci.set('5gmodem', 'sms', k, val);
		args.push(k + '=' + val);
	}
	if (args.length < 2) { return Promise.resolve(); }
	return fs.exec('/usr/share/5gmodem/modemswitch.sh', args);
}

function popTimeout(a, message, timeout, severity) {
	return ui.addTimeLimitedNotification(a, message, timeout, severity);
}

function serial_modems() {
	var sections = uci.sections('defmodems', 'defmodems') || [];
	return sections.filter(function(s) { return s.modemdata === 'serial'; });
}

function format_with_modem_index(value) {
	return uci.load('defmodems').then(function() {
		var serialModems = serial_modems();
		if (!serialModems.length) { return value; }
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) { return 'dfm' + (i + 1) + '_' + value; }
		}
		return value;
	}).catch(function() {
		return value;
	});
}

function update_sms_count_for_modem(newValue) {
	return uci.load('defmodems').then(function() {
		var serialModems = serial_modems();
		if (!serialModems.length) { return newValue; }
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		var currentModemIndex = -1;
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) { currentModemIndex = i + 1; break; }
		}
		if (currentModemIndex === -1) { return newValue; }

		var existingSmsCount = uci.get('5gmodem', 'sms', 'sms_count') || '';
		var updated = {};
		existingSmsCount.split(' ').filter(function(p) { return p.trim() !== ''; }).forEach(function(part) {
			var match = part.match(/^dfm(\d+)_(\d+)$/);
			if (match) {
				var modemIdx = parseInt(match[1]);
				if (modemIdx > 0 && modemIdx <= serialModems.length) { updated[modemIdx] = match[2]; }
			}
		});
		updated[currentModemIndex] = newValue;
		var result = [];
		for (var j = 1; j <= serialModems.length; j++) {
			result.push('dfm' + j + '_' + (updated[j] || '0'));
		}
		return result.join(' ');
	}).catch(function() {
		return newValue;
	});
}

function isPortlessSmsModem() {
	var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
	if (!p) { return false; }
	var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	var kind = uci.get('5gmodem', sec, 'kind');
	return kind === 'hilink' || (kind === 'tether' && uci.get('5gmodem', sec, 'tether') === 'android');
}

// Short transport label for the header badge.
function sms_transport() {
	var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
	var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	var kind = uci.get('5gmodem', sec, 'kind');
	if (kind === 'tether' && uci.get('5gmodem', sec, 'tether') === 'android') { return 'Android'; }
	if (kind === 'hilink') { return 'HiLink'; }
	if (uci.get('5gmodem', 'sms', 'sms_via_mm') == '1') { return 'ModemManager'; }
	var port = uci.get('5gmodem', 'sms', 'readport') || '';
	return 'sms_tool' + (port ? ' · ' + port : '');
}

// Conversation key: numbers by their last ten digits (+7..., 8..., 7... are one person),
// alphanumeric senders by name.
function sms_is_number(s) {
	s = String(s || '').trim();
	return /^\+?[\d\s()-]+$/.test(s) && s.replace(/\D/g, '').length >= 3;
}
function sms_dlg_key(s) {
	s = String(s || '').trim();
	if (sms_is_number(s)) {
		var d = s.replace(/\D/g, '');
		return 'n:' + (d.length >= 10 ? d.slice(-10) : d);
	}
	return 'a:' + s.toLowerCase();
}

/* ---------- encoding (from the former Outbox page) ---------- */
var GSM7_CHARS = '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
var GSM7_EXT = '^{}\\[~]|€';

function isUnicode(text) {
	for (var i = 0; i < text.length; i++) {
		var ch = text.charAt(i);
		if (GSM7_CHARS.indexOf(ch) === -1 && GSM7_EXT.indexOf(ch) === -1) { return true; }
	}
	return false;
}
function getGSM7Length(text) {
	var length = 0;
	for (var i = 0; i < text.length; i++) { length += GSM7_EXT.indexOf(text.charAt(i)) !== -1 ? 2 : 1; }
	return length;
}
function getUnicodeLength(text) {
	var length = 0;
	for (var i = 0; i < text.length; i++) {
		var c = text.charCodeAt(i);
		if (c >= 0xD800 && c <= 0xDBFF) { length += 2; i++; } else { length += 1; }
	}
	return length;
}
function normalizeToGSM7(text) {
	return text
		.replace(/ą/g, 'a').replace(/Ą/g, 'A')
		.replace(/ć/g, 'c').replace(/Ć/g, 'C')
		.replace(/ę/g, 'e').replace(/Ę/g, 'E')
		.replace(/ł/g, 'l').replace(/Ł/g, 'L')
		.replace(/ń/g, 'n').replace(/Ń/g, 'N')
		.replace(/ó/g, 'o').replace(/Ó/g, 'O')
		.replace(/ś/g, 's').replace(/Ś/g, 'S')
		.replace(/ż/g, 'z').replace(/Ż/g, 'Z')
		.replace(/ź/g, 'z').replace(/Ź/g, 'Z')
		.replace(/á/g, 'a').replace(/Á/g, 'A')
		.replace(/â/g, 'a').replace(/Â/g, 'A')
		.replace(/ã/g, 'a').replace(/Ã/g, 'A')
		.replace(/ā/g, 'a').replace(/Ā/g, 'A')
		.replace(/č/g, 'c').replace(/Č/g, 'C')
		.replace(/ď/g, 'd').replace(/Ď/g, 'D')
		.replace(/đ/g, 'd').replace(/Đ/g, 'D')
		.replace(/é/g, 'e').replace(/É/g, 'E')
		.replace(/ě/g, 'e').replace(/Ě/g, 'E')
		.replace(/ë/g, 'e').replace(/Ë/g, 'E')
		.replace(/ê/g, 'e').replace(/Ê/g, 'E')
		.replace(/ē/g, 'e').replace(/Ē/g, 'E')
		.replace(/í/g, 'i').replace(/Í/g, 'I')
		.replace(/î/g, 'i').replace(/Î/g, 'I')
		.replace(/ï/g, 'i').replace(/Ï/g, 'I')
		.replace(/ī/g, 'i').replace(/Ī/g, 'I')
		.replace(/ľ/g, 'l').replace(/Ľ/g, 'L')
		.replace(/ň/g, 'n').replace(/Ň/g, 'N')
		.replace(/ô/g, 'o').replace(/Ô/g, 'O')
		.replace(/õ/g, 'o').replace(/Õ/g, 'O')
		.replace(/ö/g, 'o').replace(/Ö/g, 'O')
		.replace(/ő/g, 'o').replace(/Ő/g, 'O')
		.replace(/ř/g, 'r').replace(/Ř/g, 'R')
		.replace(/š/g, 's').replace(/Š/g, 'S')
		.replace(/ş/g, 's').replace(/Ş/g, 'S')
		.replace(/ť/g, 't').replace(/Ť/g, 'T')
		.replace(/ú/g, 'u').replace(/Ú/g, 'U')
		.replace(/ů/g, 'u').replace(/Ů/g, 'U')
		.replace(/û/g, 'u').replace(/Û/g, 'U')
		.replace(/ü/g, 'u').replace(/Ü/g, 'U')
		.replace(/ű/g, 'u').replace(/Ű/g, 'U')
		.replace(/ý/g, 'y').replace(/Ý/g, 'Y')
		.replace(/ÿ/g, 'y').replace(/Ÿ/g, 'Y')
		.replace(/ž/g, 'z').replace(/Ž/g, 'Z')
		.replace(/–/g, '-').replace(/—/g, '-')
		.replace(/‘/g, '\'').replace(/’/g, '\'')
		.replace(/“/g, '"').replace(/”/g, '"')
		.replace(/„/g, '"').replace(/‟/g, '"')
		.replace(/«/g, '"').replace(/»/g, '"')
		.replace(/…/g, '...').replace(/·/g, '.')
		.replace(/•/g, '*').replace(/‣/g, '*')
		.replace(/°/g, 'o').replace(/º/g, 'o')
		.replace(/†/g, '+').replace(/‡/g, '+')
		.replace(/¹/g, '1').replace(/²/g, '2').replace(/³/g, '3')
		.replace(/¼/g, '1/4').replace(/½/g, '1/2').replace(/¾/g, '3/4')
		.replace(/×/g, 'x').replace(/÷/g, '/')
		.replace(/±/g, '+/-')
		.replace(/≈/g, '~').replace(/≠/g, '!=')
		.replace(/≤/g, '<=').replace(/≥/g, '>=')
		.replace(/←/g, '<-').replace(/→/g, '->')
		.replace(/↑/g, '^').replace(/↓/g, 'v')
		.replace(/[\u{1F600}-\u{1F64F}]/gu, ':)')
		.replace(/[\u{1F300}-\u{1F5FF}]/gu, '')
		.replace(/[\u{1F680}-\u{1F6FF}]/gu, '')
		.replace(/[\u{1F700}-\u{1F77F}]/gu, '')
		.replace(/[\u{1F780}-\u{1F7FF}]/gu, '')
		.replace(/[\u{1F800}-\u{1F8FF}]/gu, '')
		.replace(/[\u{1F900}-\u{1F9FF}]/gu, '')
		.replace(/[\u{1FA00}-\u{1FA6F}]/gu, '')
		.replace(/[\u{1FA70}-\u{1FAFF}]/gu, '')
		.replace(/[\u{2600}-\u{26FF}]/gu, '')
		.replace(/[\u{2700}-\u{27BF}]/gu, '')
		.replace(/[^\x00-\x7F@£$¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ¡¤§¿äöñüà^{}\\[\]~|€]/g, '');
}
// { uni, len, single, parts }
function smsCount(text) {
	var uni = isUnicode(text);
	var len = uni ? getUnicodeLength(text) : getGSM7Length(text);
	var single = uni ? 70 : 160, per = uni ? 67 : 153;
	return { uni: uni, len: len, single: single, parts: len <= single ? 1 : Math.ceil(len / per) };
}

function lsGet(k, d) { try { var v = window.localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } }
function lsSet(k, v) { try { window.localStorage.setItem(k, v); } catch (e) {} }

return view.extend({
	load: function() {
		var self = this, args = arguments;
		return fresh.check(40008, [ editors, smssettings, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		// render first: only the settings are waited for; the read marks and the phone book
		// arrive while the page is already drawn (the list waits for the marks, see renderMain)
		this._seenP = L.resolveDefault(sms_seen_load(), null);
		this._bookP = L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/phonebook.user'), null);
		return Promise.all([
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('defmodems'))
		]);
	},

	render: function(data) {
		var self = this;
		var main = this.renderMain(data);
		// the settings form loads its own lists from the router: the block is drawn at once with
		// placeholders and the form goes in when ready, so it never holds the page back
		var holder = E('div', {}, [ E('span', { 'class': 'tg-skel blk', 'style': 'width:60%;margin:10px 0' }),
			E('span', { 'class': 'tg-skel blk', 'style': 'width:40%;margin:10px 0' }) ]);
		var sec = self.renderSettings(holder);
		smssettings.tabbedPanel().then(function(panel) {
			while (holder.firstChild) { holder.removeChild(holder.firstChild); }
			holder.appendChild(panel);
		}, function() {
			var blk = holder.closest ? holder.closest('.tg-sms-set') : null;
			if (blk && blk.parentNode) { blk.parentNode.removeChild(blk); }
		});
		return E([], [ main, sec ]);
	},

	/* ---------- settings: one collapsible block with LuCI form tabs ---------- */
	renderSettings: function(mapNode) {
		var key = '5gm-blk-smsset';
		var open = lsGet(key, '0') === '1';
		var g = function(k) { return uci.get('5gmodem', 'sms', k) == '1'; };
		var fwd = [];
		if (g('forward_sms_enabled')) { fwd.push('E-mail'); }
		if (g('tg_enabled')) { fwd.push('Telegram'); }
		if (g('ntfy_enabled')) { fwd.push('ntfy'); }
		if (g('hook_enabled')) { fwd.push('Webhook'); }
		var sum = _('Forwarding') + ': ' + (fwd.length ? fwd.join(', ') : _('off')) +
			' · ' + _('Run commands from SMS') + ': ' + (g('cmd_enabled') ? _('on') : _('off'));
		var chev = E('span', { 'class': 'tg-sms-chev' + (open ? ' open' : '') });
		chev.innerHTML = svg('chev', 16);
		var body = E('div', { 'class': 'tg-collapse' + (open ? ' open' : '') }, [ E('div', { 'class': 'tg-collapse-inner' }, [ mapNode ]) ]);
		var title;
		var toggle = function() {
			var exp = !body.classList.contains('open');
			body.classList.toggle('open', exp);
			chev.classList.toggle('open', exp);
			title.setAttribute('aria-expanded', String(exp));
			lsSet(key, exp ? '1' : '0');
		};
		title = E('h3', {
			'class': 'tg-sms-coll', 'role': 'button', 'tabindex': '0', 'aria-expanded': String(open),
			'click': toggle,
			'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); toggle(); } }
		}, [ chev, E('span', {}, [ _('SMS Settings') ]), E('span', { 'class': 'tg-sms-collsum' }, [ sum ]) ]);
		var sec = E('div', { 'class': 'cbi-section tg-sms-set tg-sms-hidem' }, [ title, body ]);
		if (this._root) { this._root.appendChild(sec); return E([]); }
		return sec;
	},

	renderMain: function(data) {
		var self = this;
		var isPhone = function() { return !!(window.matchMedia && window.matchMedia(PHONE_MQ).matches); };

		/* contacts */
		var loadBook = function(text) {
			smsBook = [];
			String(text || '').trim().split('\n').forEach(function(line) {
				var f = line.split(/;/);
				var name = f[0], code = f[1] || f[0];
				if (!code) { return; }
				smsBook.push({ name: name, code: code });
			});
		};
		loadBook(null);
		Promise.resolve(self._bookP).then(function(text) { if (text) { loadBook(text); renderAll(); } });
		var bookName = function(raw) {
			if (!sms_is_number(raw)) { return ''; }
			var k = sms_dlg_key(raw);
			for (var i = 0; i < smsBook.length; i++) {
				if (smsBook[i].name && smsBook[i].name !== smsBook[i].code && sms_dlg_key(smsBook[i].code) === k) { return smsBook[i].name; }
			}
			return '';
		};

		var S = {
			msgs: [], u: null, t: null, loading: true, error: false,
			view: 'dlg',
			screen: isPhone() ? 'list' : 'thread',
			open: null, autoOpen: true, selMode: false, sel: new Set(), filter: '',
			sent: {}, deleting: false, pushed: false, listY: null
		};
		self._S = S;

		/* ---------- header card ---------- */
		var serialModems = serial_modems();
		var curModem = null;
		if (serialModems.length) {
			var cp = uci.get('5gmodem', 'sms', 'readport');
			curModem = serialModems.filter(function(s) { return s.comm_port === cp; })[0] || serialModems[0];
		}
		var modemLabel = function(m) { return m ? m.modem + (m.user_desc ? ' (' + m.user_desc + ')' : '') : ''; };

		var hd = {};
		hd.badge = E('span', { 'class': 'tg-proto-badge', 'title': _('How the app talks to the modem') }, [ sms_transport() ]);
		hd.pillM = E('span', { 'class': 'tg-sms-pill' }, [ E('i'), E('span', {}, '') ]);
		hd.ico = E('div', { 'class': 'tginfo-signal tg-sms-ico off' });
		hd.ico.innerHTML = svg('msg', 36);
		hd.icoN = E('medium', {}, '0');
		hd.ico.appendChild(hd.icoN);
		hd.reg = E('div', { 'class': 'tginfo-reg' }, [ _('Inbox') + (curModem ? ' · ' + modemLabel(curModem) : '') ]);
		hd.main = E('div', { 'class': 'tginfo-op tg-sms-main' }, [ _('Loading messages…') ]);
		hd.memTxt = E('span', {}, '');
		hd.memFill = E('div', { 'class': 'tg-mbar-fill' });
		hd.memBar = E('div', { 'class': 'tg-mbar' }, E('div', { 'class': 'tg-mbar-t' }, hd.memFill));
		hd.mem = E('div', { 'class': 'tg-sms-mem', 'id': 'msg', 'style': 'display:none' }, [ hd.memTxt, hd.memBar ]);

		var viaMM = (uci.get('5gmodem', 'sms', 'sms_via_mm') == '1');
		var stores = [];
		var storeSeg = function() {
			var stg = uci.get('5gmodem', 'sms', 'storage') || 'ME';
			var mk = function(val, label) {
				return E('button', { 'type': 'button', 'data-v': val, 'class': (val === 'SM') === (stg === 'SM') ? 'on' : '',
					'title': _('Any change in the area from which SMS messages will be read requires refreshing the messages'),
					'click': function() { self.handleSWarea(val); } }, [ label ]);
			};
			var el = E('div', { 'class': 'tg-sms-seg', 'role': 'group', 'style': viaMM ? 'display:none' : null },
				[ mk('SM', _('SIM card')), mk('ME', _('Modem memory')) ]);
			stores.push(el);
			return el;
		};
		self._paintStore = function() {
			var stg = uci.get('5gmodem', 'sms', 'storage') || 'ME';
			stores.forEach(function(el) {
				el.style.display = (viaMM || smsWeb) ? 'none' : '';
				Array.prototype.forEach.call(el.children, function(b) {
					b.classList.toggle('on', (b.getAttribute('data-v') === 'SM') === (stg === 'SM'));
				});
			});
		};

		// Conversations / Feed: in the header card, so it stays in one place whatever the mode
		var viewSegs = [];
		var viewSeg = function() {
			var mk = function(v, label) {
				return E('button', { 'type': 'button', 'data-v': v, 'class': S.view === v ? 'on' : '',
					'click': function() { setView(v); } }, [ label ]);
			};
			var el = E('div', { 'class': 'tg-sms-seg tg-sms-viewseg', 'role': 'group' }, [ mk('dlg', _('Conversations')), mk('feed', _('Feed')) ]);
			viewSegs.push(el);
			return el;
		};

		var refreshBtns = [];
		var mkRefresh = function() {
			var b = ibtn('refresh', '', 'tg-sms-ico', { 'title': _('Refresh'), 'aria-label': _('Refresh'),
				'click': function() { self.handleRefresh(); } });
			refreshBtns.push(b);
			return b;
		};
		var markBtns = [];
		var mkMark = function() {
			var b = ibtn('checks', '', 'tg-sms-ico', { 'title': _('Mark read'), 'aria-label': _('Mark read'), 'disabled': true,
				'click': function() { markRead(S.msgs); } });
			markBtns.push(b);
			return b;
		};
		var writeBtns = [];
		var mkWrite = function(cls, label) {
			var b = ibtn('pen', label, 'cbi-button-action ' + (cls || ''), { 'title': _('New SMS'), 'aria-label': _('New SMS'),
				'click': function() { openNew(); } });
			writeBtns.push(b);
			return b;
		};

		var pager = '';
		if (serialModems.length) {
			var dis = serialModems.length > 1 ? null : true;
			pager = E('span', { 'class': 'tg-sms-pager' }, [
				E('button', { 'class': 'cbi-button prev', 'type': 'button', 'aria-label': _('Previous modem'), 'disabled': dis,
					'data-tooltip': _('Changing a modem requires refreshing the messages'),
					'click': function(ev) { self.handleModemChange(ev); } }, [ '◄' ]),
				E('span', { 'class': 'modem-display-text' }, [ modemLabel(curModem) ]),
				E('button', { 'class': 'cbi-button next', 'type': 'button', 'aria-label': _('Next modem'), 'disabled': dis,
					'data-tooltip': _('Changing a modem requires refreshing the messages'),
					'click': function(ev) { self.handleModemChange(ev); } }, [ '►' ])
			]);
		}

		var head = E('div', { 'class': 'cbi-section tg-pg-head tg-sms-head tg-sms-hidem' }, [
			E('h3', { 'class': 'tg-pg-title tg-sms-title' }, [ E('span', {}, [ 'SMS' ]), hd.badge, hd.pillM ]),
			E('div', { 'class': 'tginfo-general' }, [
				hd.ico,
				E('div', { 'class': 'tginfo-status' }, [ hd.reg, hd.main, hd.mem ]),
				E('div', { 'class': 'tginfo-right' }, [
					pager,
					E('div', { 'class': 'tg-sms-actions' }, [ viewSeg(), storeSeg(), mkMark(), mkRefresh() ])
				])
			]),
			E('div', { 'class': 'tg-sms-headm' }, [ viewSeg(), storeSeg(), E('span', { 'class': 'grow' }), pager ? pager.cloneNode(true) : '', mkMark(), mkRefresh() ])
		]);
		// the cloned phone pager needs its own handlers
		head.querySelectorAll('.tg-sms-headm .tg-sms-pager .cbi-button').forEach(function(b) {
			b.addEventListener('click', function(ev) { self.handleModemChange(ev); });
		});

		function paintMem(v, m) {
			if (v == null) { hd.mem.style.display = 'none'; return; }
			hd.mem.style.display = '';
			if (smsReadOnly) {
				hd.memTxt.textContent = _('Phone storage: %s messages').format(v);
				hd.memBar.style.display = 'none';
				return;
			}
			hd.memBar.style.display = '';
			var vn = parseInt(v) || 0, mn = parseInt(m) || 100;
			var pc = Math.max(0, Math.min(100, Math.floor((100 / mn) * vn)));
			hd.memTxt.textContent = sms_mem_label(v, m);
			hd.mem.setAttribute('title', sms_mem_label(v, m));
			hd.memFill.style.width = Math.max(pc, vn ? 3 : 0) + '%';
			hd.memFill.style.background = pc >= 90 ? 'var(--tg-sms-bad)' : pc >= 70 ? 'var(--tg-sms-warn)' : 'var(--tg-sms-ok)';
		}
		self._paintMem = paintMem;
		smsPaintMem = paintMem;
		smsPaintStore = function() { self._paintStore(); };

		/* ---------- alerts ---------- */
		var alertBox = function(kind, name, text) {
			return E('div', { 'class': 'tg-sms-alert tg-sms-hidem ' + kind, 'style': 'display:none' }, [ icon(name, 17), E('div', {}, [ text ]) ]);
		};
		var errAlert = alertBox('warn', 'warn', _('Could not read messages - will retry on the next refresh'));
		var roAlert = alertBox('info', 'info', _('Android SMS storage is read-only.'));

		/* ---------- list pane ---------- */
		var lp = {};
		lp.search = E('input', { 'type': 'search', 'class': 'cbi-input-text', 'placeholder': _('Search by sender and text'),
			'aria-label': _('Search'),
			'input': function() { S.filter = lp.search.value.trim().toLowerCase(); renderList(); } });
		lp.selBtn = ibtn('selbox', '', 'tg-sms-ico', { 'title': _('Select several'), 'aria-label': _('Select several'),
			'click': function() { setSelMode(!S.selMode); } });
		lp.selN = E('b', {}, '');
		lp.bRead = ibtn('checks', _('Read'), '', { 'click': function() { markRead(selectedMsgs()); } });
		lp.bFwd = ibtn('fwd', _('To e-mail'), '', { 'title': _('Forward SMS to E-mail'), 'id': 'forward', 'click': function() { self.handleForward(selectedMsgs()); } });
		lp.bDel = ibtn('trash', _('Delete'), 'cbi-button-negative', { 'id': 'execute', 'click': function() { self.handleDelete(selectedMsgs()); } });
		lp.selbar = E('div', { 'class': 'tg-sms-selbar', 'style': 'display:none' }, [ lp.selN, lp.bRead, lp.bFwd, lp.bDel ]);
		lp.progTxt = E('span', { 'class': 'spinning' }, '');
		lp.progFill = E('div', { 'class': 'tg-mbar-fill', 'style': 'background:var(--tg-accent)' });
		lp.prog = E('div', { 'class': 'tg-sms-prog', 'id': 'deleteinfo', 'style': 'display:none' }, [ lp.progTxt,
			E('div', { 'class': 'tg-mbar' }, E('div', { 'class': 'tg-mbar-t' }, lp.progFill)) ]);
		lp.items = E('div', { 'class': 'tg-sms-items', 'id': 'smsList' });
		// new message: a compact pen next to search (on a phone the round button at the bottom does it)
		lp.newBtn = ibtn('pen', '', 'tg-sms-ico tg-sms-newbtn', { 'title': _('New SMS'), 'aria-label': _('New SMS'),
			'click': function() { openNew(); } });
		writeBtns.push(lp.newBtn);
		var listSec = E('div', { 'class': 'cbi-section tg-sms-pane tg-sms-listsec' }, [
			E('div', { 'class': 'tg-sms-tool' }, [
				E('div', { 'class': 'tg-sms-search' }, [ icon('search', 15, 'x'), lp.search ]),
				lp.selBtn, lp.newBtn
			]),
			lp.selbar, lp.prog, lp.items
		]);

		/* ---------- composer ---------- */
		function makeComposer(opts) {
			var c = { busy: false };
			c.status = E('div', { 'class': 'tg-sms-stbox' });
			c.ta = E('textarea', { 'class': 'cbi-input-textarea', 'rows': String(opts.rows || 1), 'wrap': 'on',
				'placeholder': _('Message'), 'id': opts.id || null });
			c.cnt = E('span', { 'class': 'tg-sms-cnt2', 'title': _('Characters remaining:') }, '160');
			c.segG = E('button', { 'type': 'button', 'title': _('GSM-7 encoding (160 characters)'), 'class': 'on' }, [ 'GSM-7' ]);
			c.segU = E('button', { 'type': 'button', 'title': _('Unicode encoding (70 characters), does not support sending national characters (in utf8) - only ascii') }, [ 'Unicode' ]);
			c.note = E('span', { 'class': 'tg-sms-note' }, '');
			c.send = ibtn('send', opts.sendLabel, 'cbi-button-action', { 'click': function() { opts.onSend(c, 'send'); } });
			c.update = function() {
				var r = smsCount(c.ta.value);
				c.segU.classList.toggle('on', r.uni);
				c.segG.classList.toggle('on', !r.uni);
				dom.content(c.cnt, r.len <= r.single ? [ String(r.single - r.len) ] : [ r.len + ' · ', E('b', {}, [ r.parts + ' SMS' ]) ]);
				c.note.textContent = r.uni ? _('Unicode: 70 characters per SMS, 67 per part') : _('GSM-7: 160 characters per SMS, 153 per part');
			};
			c.segG.addEventListener('click', function() { c.ta.value = normalizeToGSM7(c.ta.value); c.update(); });
			c.segU.addEventListener('click', function() { c.update(); });
			c.ta.addEventListener('input', c.update);
			c.ta.addEventListener('keyup', c.update);
			if (opts.deleteKey) {
				// Delete clears the whole text, as on the former Outbox page
				c.ta.setAttribute('data-tooltip', _('Press [Delete] to delete the content of the message'));
				c.ta.addEventListener('keydown', function(ev) {
					if (ev.keyCode === 46) { c.ta.value = ''; c.update(); c.ta.focus(); }
				});
			}
			var row = [ E('span', { 'class': 'grow' }, [ E('span', { 'class': 'tg-sms-seg', 'role': 'group' }, [ c.segU, c.segG ]), ' ', c.note ]) ];
			(opts.extra || []).forEach(function(x) { row.push(x); });
			row.push(c.send);
			c.row = E('div', { 'class': 'tg-sms-crow' }, row);
			c.note2 = E('div', { 'class': 'tg-sms-note', 'style': 'display:none' }, '');
			c.el = E('div', { 'class': 'tg-sms-comp' }, [ c.status, c.note2,
				E('div', { 'class': 'wrap' }, [ c.ta, c.cnt ]), c.row ]);
			c.setBusy = function(on) {
				c.busy = on;
				c.el.querySelectorAll('button').forEach(function(b) { b.disabled = on; });
			};
			// replace the whole input with a note (alphanumeric sender, read-only phone)
			c.lock = function(text) {
				c.note2.style.display = text ? '' : 'none';
				dom.content(c.note2, text ? [ icon('info', 13), ' ', text ] : []);
				c.el.querySelector('.wrap').style.display = text ? 'none' : '';
				c.row.style.display = text ? 'none' : '';
				if (text) { c.status.innerHTML = ''; }
			};
			c.update();
			return c;
		}

		function showStatus(c, state, text, retry) {
			var kids;
			if (state === 'ok') {
				kids = [ icon('check', 15), E('div', {}, [ _('SMS sent sucessfully') ]) ];
			} else if (state === 'q') {
				var qn = E('span', {}, '');
				kids = [ icon('clock', 15), E('div', {}, [ E('b', {}, [ _('The message is queued.') ]), E('br'),
					E('span', { 'class': 'tg-sms-note' }, [ _('It is sent in the background when the modem is free; you can close the page.'), ' ', qn ]) ]) ];
				L.resolveDefault(fs.exec_direct(BRIDGE, [ 'queue-list' ]), '').then(function(out) {
					try {
						var n = (JSON.parse(out || '{}').queued || []).filter(function(q) { return q.state === 'queued'; }).length;
						if (n) { qn.textContent = _('In queue: %d').format(n); }
					} catch (e) {}
				});
			} else {
				kids = [ icon('warn', 15), E('div', {}, [ E('b', {}, [ _('Not sent') ]), E('pre', {}, [ text || _('Error') ]) ]) ];
				if (retry && !/unknown/i.test(text || '')) {
					kids.push(E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function() { c.status.innerHTML = ''; retry(); } }, [ _('Retry') ]));
				}
			}
			dom.content(c.status, E('div', { 'class': 'tg-sms-st ' + (state === 'ok' ? 'ok' : state === 'q' ? 'q' : 'bad') }, kids));
		}

		/* ---------- thread pane ---------- */
		var th = {};
		th.av = E('span', { 'class': 'tg-sms-av' }, '');
		th.name = E('b', {}, '');
		th.sub = E('span', {}, '');
		th.back = ibtn('back', '', 'tg-sms-ico tg-sms-back', { 'aria-label': _('Back'), 'title': _('Back'), 'click': function() { goBack(); } });
		th.fwd = ibtn('fwd', _('To e-mail'), '', { 'title': _('Forward SMS to E-mail'),
			'click': function() { var d = openDlg(); if (d) { self.handleForward(d.msgs); } } });
		th.del = ibtn('trash', _('Delete'), 'cbi-button-negative', { 'title': _('Delete the conversation'),
			'click': function() {
				var d = openDlg();
				if (!d || !d.msgs.length) { return; }
				if (!window.confirm(_('Delete the conversation (%d messages)?').format(d.msgs.length))) { return; }
				self.handleDelete(d.msgs);
			} });
		th.body = E('div', { 'class': 'tg-sms-body' });
		var reply = makeComposer({ rows: 1, sendLabel: _('Send SMS'), onSend: function(c) {
			var d = openDlg();
			if (d) { sendTo(c, d.raw, c.ta.value); }
		} });
		th.ph = E('div', { 'class': 'tg-sms-ph tg-sms-empty' }, E('div', {}, [ icon('msg', 28), E('span', {}, [ _('Select a conversation on the left') ]) ]));
		var threadSec = E('div', { 'class': 'cbi-section tg-sms-pane tg-sms-thsec none' }, [
			E('div', { 'class': 'tg-sms-th' }, [ th.back, th.av, E('div', { 'class': 'tg-sms-who' }, [ th.name, th.sub ]),
				E('div', { 'class': 'tg-sms-thact' }, [ th.fwd, th.del ]) ]),
			th.body, reply.el, th.ph
		]);

		/* ---------- new message ---------- */
		var nw = {};
		nw.num = E('input', {
			'type': 'text', 'id': 'phonenumber', 'class': 'cbi-input-text', 'inputmode': 'tel',
			'placeholder': _('e.g. 9291067196 or a short number like 000100'),
			'data-tooltip': _('Press [Delete] to delete the phone number'),
			'input': function() { nw.num.value = nw.num.value.replace(/[^0-9+]/g, ''); paintChips(); },
			'keydown': function(ev) { if (ev.keyCode === 46) { nw.num.value = ''; paintChips(); nw.num.focus(); } }
		});
		nw.bookBtn = ibtn('book', _('User contacts'), '', { 'click': function() {
			var on = nw.chips.style.display === 'none';
			nw.chips.style.display = on ? '' : 'none';
			lsSet('5gm-sms-chips', on ? '1' : '0');
		} });
		nw.chips = E('div', { 'class': 'tg-sms-chips', 'style': lsGet('5gm-sms-chips', '1') === '1' ? '' : 'display:none' });
		var groupOn = uci.get('5gmodem', 'sms', 'sendingroup') == '1';
		nw.menu = E('div', { 'class': 'tg-sms-menu', 'style': 'display:none' }, [
			E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() {
				nw.menu.style.display = 'none';
				sendGroup(nw.comp, nw.comp.ta.value);
			} }, [ '%s %s'.format(_('Send'), _('to group')) ])
		]);
		var extra = [ E('button', { 'class': 'cbi-button cbi-button-negative', 'type': 'button', 'id': 'clr', 'click': function() { self.handleClear(); } }, [ _('Clear form') ]) ];
		if (groupOn) {
			extra.push(E('button', { 'class': 'cbi-button', 'type': 'button', 'title': '%s %s'.format(_('Send'), _('to group')),
				'aria-label': '%s %s'.format(_('Send'), _('to group')),
				'click': function(ev) { ev.stopPropagation(); nw.menu.style.display = nw.menu.style.display === 'none' ? '' : 'none'; } }, [ '▾' ]));
			extra.push(nw.menu);
			document.addEventListener('click', function(ev) { if (!nw.menu.contains(ev.target)) { nw.menu.style.display = 'none'; } });
		}
		nw.comp = makeComposer({ rows: isPhone() ? 6 : 4, id: 'smstext', deleteKey: true, sendLabel: _('Send to number'), extra: extra,
			onSend: function(c) { sendTo(c, nw.num.value, c.ta.value, true); } });
		nw.comp.ta.addEventListener('input', function() { nw.comp.ta.dataset.edited = '1'; });
		var hint = '';
		if (uci.get('5gmodem', 'sms', 'information') == '1') {
			hint = E('div', { 'class': 'tg-sms-alert info', 'style': 'margin:0' }, [ icon('info', 16),
				E('div', {}, [ _("Enter the number as is: a 10-digit national number gets the country prefix from the settings automatically; short service numbers (like 000100) are sent unchanged.") ]),
				E('button', { 'class': 'cbi-button', 'type': 'button', 'click': function(ev) {
					var b = ev.currentTarget.parentNode;
					if (b && b.parentNode) { b.parentNode.removeChild(b); }
					fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'hidenumberhint' ]);
				} }, [ _('Hide') ])
			]);
		}
		nw.sub = E('span', {}, [ curModem ? _('from modem %s').format(modemLabel(curModem)) : '' ]);
		var newSec = E('div', { 'class': 'cbi-section tg-sms-pane tg-sms-newsec' }, [
			E('div', { 'class': 'tg-sms-th' }, [
				ibtn('back', '', 'tg-sms-ico tg-sms-back', { 'aria-label': _('Back'), 'title': _('Back'), 'click': function() { goBack(); } }),
				E('span', { 'class': 'tg-sms-av op' }, [ icon('pen', 16) ]),
				E('div', { 'class': 'tg-sms-who' }, [ E('b', {}, [ _('New SMS') ]), nw.sub ])
			]),
			E('div', { 'class': 'tg-sms-to' }, [ E('label', { 'for': 'phonenumber' }, [ _('Send to') ]), nw.num, nw.bookBtn ]),
			nw.chips,
			E('div', { 'class': 'tg-sms-body' }, [ hint ]),
			nw.comp.el
		]);

		function paintChips() {
			var cur = nw.num.value;
			var kids = smsBook.map(function(b) {
				return E('button', { 'type': 'button', 'class': 'tg-sms-chip' + (b.code === cur ? ' on' : ''),
					'click': function() { self.handleCopy(b); paintChips(); } },
					[ (b.name && b.name !== b.code) ? b.name + ' · ' + b.code : b.code ]);
			});
			kids.push(E('button', { 'type': 'button', 'class': 'tg-sms-chip', 'click': function() { self.handleContacts(); } },
				[ icon('pen', 11), _('Manage contacts') ]));
			dom.content(nw.chips, kids);
		}
		self._paintChips = paintChips;
		self._nw = nw;
		self._loadBook = loadBook;
		paintChips();

		var fab = mkWrite('tg-sms-fab', '');

		/* ---------- root ---------- */
		var grid = E('div', { 'class': 'tg-sms-grid' }, [ listSec, threadSec, newSec ]);
		var root = E('div', { 'class': 'tg-sms', 'data-view': S.view, 'data-screen': S.screen }, [ head, errAlert, roAlert, grid, fab ]);
		self._root = root;

		/* ---------- state helpers ---------- */
		function setScreen(s) {
			S.screen = s;
			root.setAttribute('data-screen', s);
			paintOpen();
			// back on the phone list: return to the conversation the user came from, not to the top
			if (s === 'list' && isPhone() && S.listY != null) { window.scrollTo(0, S.listY); }
		}
		function goScreen(s) {
			if (isPhone() && S.screen === 'list' && s !== 'list') {
				S.listY = window.pageYOffset;
				try { window.history.pushState({ tgsms: s }, ''); S.pushed = true; } catch (e) {}
			}
			setScreen(s);
			// a conversation is placed by renderThread(true); a new message starts at the top
			if (isPhone() && s === 'new') { window.scrollTo(0, 0); }
		}
		// On the phone the thread pane grows with the page (no inner scroll), so th.body.scrollTop does
		// nothing: scroll the page instead, to the newest messages and the composer under them.
		function phoneShowThread() {
			var r = threadSec.getBoundingClientRect();
			var y = r.height > window.innerHeight ? r.bottom - window.innerHeight : r.top;
			window.scrollTo(0, Math.max(0, window.pageYOffset + y));
		}
		function goBack() {
			if (S.pushed) { S.pushed = false; try { window.history.back(); return; } catch (e) {} }
			setScreen(isPhone() ? 'list' : 'thread');
		}
		window.addEventListener('popstate', function() {
			S.pushed = false;
			if (S.screen !== 'list' && isPhone()) { setScreen('list'); }
			else if (S.screen === 'new') { setScreen('thread'); }
		});
		function openNew() {
			goScreen('new');
			paintChips();
			window.setTimeout(function() { (nw.num.value ? nw.comp.ta : nw.num).focus(); }, 0);
		}
		self._openNew = openNew;
		function setView(v) {
			S.view = v;
			if (lp.items) { lp.items.scrollTop = 0; }
			root.setAttribute('data-view', v);
			viewSegs.forEach(function(seg) {
				Array.prototype.forEach.call(seg.children, function(b) { b.classList.toggle('on', b.getAttribute('data-v') === v); });
			});
			S.sel.clear();
			setSelMode(false);
		}
		function setSelMode(on) {
			S.selMode = on;
			if (!on) { S.sel.clear(); }
			lp.selBtn.classList.toggle('on', on);
			renderList();
		}

		/* ---------- conversations ---------- */
		function buildDialogs() {
			var map = {}, out = [];
			var get = function(k, raw, shown) {
				if (!map[k]) { map[k] = { key: k, raw: raw, shown: shown, msgs: [], out: [] }; out.push(map[k]); }
				return map[k];
			};
			S.msgs.forEach(function(m) { get(sms_dlg_key(m.raw), m.raw, m.shown).msgs.push(m); });
			Object.keys(S.sent).forEach(function(k) {
				var o = S.sent[k];
				if (o.length) { get(k, o[0].to, o[0].to).out = o; }
			});
			out.forEach(function(d) {
				d.msgs.sort(function(a, b) { return a.epoch - b.epoch; });
				d.newCount = d.msgs.filter(function(m) { return m.isNew; }).length;
				var lastIn = d.msgs[d.msgs.length - 1], lastOut = d.out[d.out.length - 1];
				d.last = (!lastIn || (lastOut && lastOut.epoch >= lastIn.epoch)) ? lastOut : lastIn;
				d.epoch = d.last ? d.last.epoch : 0;
				d.name = bookName(d.raw);
				d.alpha = !sms_is_number(d.raw);
			});
			out.sort(function(a, b) { return b.epoch - a.epoch; });
			return out;
		}
		function openDlg() {
			if (!S.open) { return null; }
			return buildDialogs().filter(function(d) { return d.key === S.open; })[0] || null;
		}
		function dlgTitle(d) { return d.name || sms_fmt_sender(d.shown); }
		function avatar(d, sel) {
			var t;
			if (sel) { return E('span', { 'class': 'tg-sms-av' }, [ icon('check', 18) ]); }
			if (d.name) { t = d.name.charAt(0).toUpperCase(); }
			else if (!d.alpha) { var dg = d.shown.replace(/\D/g, ''); t = dg.slice(-2); }
			else { t = String(d.shown).charAt(0).toUpperCase(); }
			return E('span', { 'class': 'tg-sms-av' + (d.alpha ? ' op' : '') }, [ t ]);
		}
		function matches(text) { return !S.filter || String(text || '').toLowerCase().indexOf(S.filter) >= 0; }
		function dlgMatches(d) {
			if (!S.filter) { return true; }
			return matches(d.shown) || matches(d.name) || matches(sms_fmt_sender(d.shown)) ||
				d.msgs.some(function(m) { return matches(m.text); }) || d.out.some(function(m) { return matches(m.text); });
		}

		function selectedMsgs() {
			if (S.view === 'feed') { return S.msgs.filter(function(m) { return S.sel.has(m.index); }); }
			var out = [];
			buildDialogs().forEach(function(d) { if (S.sel.has(d.key)) { out = out.concat(d.msgs); } });
			return out;
		}

		function markRead(msgs) {
			if (smsReadOnly) { return; }
			var keys = [], idx = [];
			msgs.forEach(function(m) {
				if (!m.isNew) { return; }
				m.isNew = false;
				m.keys.forEach(function(k) { if (k) { keys.push(k); } });
				idx.push(m.index);
			});
			if (!keys.length) { return; }
			sms_modem_markread(idx);
			sms_seen_add(keys);
			renderAll();
		}
		self._markRead = markRead;

		function emptyBox(kind) {
			if (kind === 'loading') {
				// placeholder rows in the shape of the list, not a spinner in an empty box
				var rows = [ 0, 1, 2, 3, 4 ].map(function(i) {
					return E('div', { 'class': 'tg-sms-item tg-sms-skel', 'aria-hidden': 'true' }, [
						E('div', { 'class': 'tg-sms-av tg-skel' }),
						E('span', { 'class': 'tg-skel', 'style': 'width:' + [ 42, 55, 35, 48, 60 ][i] + '%' }),
						E('span', { 'class': 'tg-skel', 'style': 'width:2.6em' }),
						E('span', { 'class': 'tg-skel', 'style': 'grid-column:2 / span 2;width:' + [ 80, 65, 72, 58, 76 ][i] + '%' })
					]);
				});
				return E('div', { 'id': 'smsEmpty', 'data-state': 'loading', 'role': 'status', 'aria-label': _('Loading messages…') }, rows);
			}
			if (kind === 'error') {
				return E('div', { 'class': 'tg-sms-empty', 'id': 'smsEmpty', 'data-state': 'error' }, E('div', {}, [ icon('warn', 28),
					E('span', {}, [ _('Could not read messages - will retry on the next refresh') ]) ]));
			}
			if (kind === 'nomatch') {
				return E('div', { 'class': 'tg-sms-empty' }, E('div', {}, [ icon('search', 28), E('span', {}, [ _('Nothing found') ]) ]));
			}
			return E('div', { 'class': 'tg-sms-empty', 'id': 'smsEmpty', 'data-state': 'empty' }, E('div', {}, [
				icon('msg', 30), E('b', {}, [ _('No messages') ]),
				E('span', {}, [ _('New SMS appear here on their own: the page checks the modem every 15 seconds.') ]),
				smsReadOnly ? '' : ibtn('pen', _('New SMS'), 'cbi-button-action', { 'click': function() { openNew(); } })
			]));
		}

		function renderList() {
			var nodes = [];
			var nSel = 0;
			if (S.view === 'feed') {
				lp.items.className = 'tg-sms-items tg-sms-feed';
				var alive = new Set();
				S.msgs.forEach(function(m) { alive.add(m.index); });
				S.sel.forEach(function(k) { if (!alive.has(k)) { S.sel.delete(k); } });
				S.msgs.filter(function(m) { return matches(m.text) || matches(m.shown) || matches(sms_fmt_sender(m.shown)); }).forEach(function(m) {
					var sel = S.sel.has(m.index);
					var card = E('button', { 'type': 'button', 'class': 'cbi-button tg-sms-card' + (m.isNew ? ' new' : '') + (sel ? ' sel' : ''),
						'aria-pressed': sel ? 'true' : 'false', 'data-index': m.index }, [
						E('div', { 'class': 'h' }, [ E('span', {}, [ sms_fmt_sender(m.shown) ]), E('small', {}, [ m.local ]) ]),
						E('div', { 'class': 't' }, sms_rich(m.text))
					]);
					card.addEventListener('click', function(ev) {
						var codeEl = ev.target.closest ? ev.target.closest('.tg-sms-code') : null;
						if (codeEl) { sms_copy_code(codeEl); }
						if (m.isNew) { markRead([ m ]); }
						if (codeEl) { return; }
						if (S.sel.has(m.index)) { S.sel.delete(m.index); } else { S.sel.add(m.index); }
						S.selMode = S.sel.size > 0;
						lp.selBtn.classList.toggle('on', S.selMode);
						renderList();
					});
					nodes.push(card);
				});
				nSel = S.sel.size;
			} else {
				lp.items.className = 'tg-sms-items';
				var dl = buildDialogs();
				var keys = new Set(dl.map(function(d) { return d.key; }));
				S.sel.forEach(function(k) { if (!keys.has(k)) { S.sel.delete(k); } });
				dl.filter(dlgMatches).forEach(function(d) {
					var sel = S.sel.has(d.key);
					var last = d.last || {};
					var it = E('div', { 'class': 'tg-sms-item' + (d.newCount ? ' new' : '') + (d.key === S.open && S.screen !== 'new' ? ' on' : '') + (sel ? ' sel' : ''),
						'role': 'button', 'tabindex': '0', 'data-key': d.key, 'aria-pressed': S.selMode ? String(sel) : null }, [
						avatar(d, sel),
						E('span', { 'class': 'tg-sms-from' }, [ dlgTitle(d) ]),
						E('span', { 'class': 'tg-sms-time' }, [ sms_short_time(last.local) ]),
						E('span', { 'class': 'tg-sms-snip' }, [ String(last.text || '') ]),
						E('span', { 'class': 'tg-sms-cnt' }, [ String(d.newCount || (d.msgs.length + d.out.length)) ])
					]);
					var act = function() {
						if (S.selMode) {
							if (sel) { S.sel.delete(d.key); } else { S.sel.add(d.key); }
							renderList();
							return;
						}
						openDialog(d.key, true);
					};
					it.addEventListener('click', act);
					it.addEventListener('keydown', function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); act(); } });
					nodes.push(it);
				});
				nSel = S.sel.size;
			}
			if (!nodes.length) {
				var any = S.view === 'feed' ? S.msgs.length : buildDialogs().length;
				nodes.push(emptyBox(any ? 'nomatch' : S.loading ? 'loading' : S.error ? 'error' : 'empty'));
			}
			// The list scrolls inside .tg-sms-items; replacing its children collapses it and the
			// browser resets scrollTop to 0, so a click on a dialog lower down jumped to the top.
			var keepY = lp.items.scrollTop;
			dom.content(lp.items, nodes);
			if (keepY) { lp.items.scrollTop = keepY; }
			lp.selbar.style.display = (S.selMode || nSel) ? '' : 'none';
			lp.selN.textContent = _('selected: %d').format(nSel);
			[ lp.bRead, lp.bFwd ].forEach(function(b) { b.disabled = !nSel || S.deleting; });
			lp.bRead.style.display = smsReadOnly ? 'none' : '';
			lp.bDel.style.display = smsReadOnly ? 'none' : '';
			lp.bDel.disabled = !nSel || S.deleting || smsReadOnly;
		}

		function openDialog(key, user) {
			S.open = key;
			S.autoOpen = false;
			var d = openDlg();
			if (user && d) { markRead(d.msgs); }
			if (S.screen !== 'thread') { goScreen('thread'); }
			else if (user && isPhone()) { goScreen('thread'); }
			if (user) { reply.status.innerHTML = ''; }
			renderList();
			renderThread(true);
		}
		self._openDialog = openDialog;

		// On a wide screen the newest conversation opens by itself until the user picks one; pick it
		// before the list is drawn, so the list shows it as the open one.
		function autoPick() {
			if (openDlg() || !S.autoOpen || isPhone()) { return; }
			var first = buildDialogs()[0];
			if (first) { S.open = first.key; }
		}
		function paintOpen() {
			var on = S.screen !== 'new' && S.view !== 'feed' && openDlg() ? S.open : null;
			Array.prototype.forEach.call(lp.items.querySelectorAll('.tg-sms-item'), function(it) {
				it.classList.toggle('on', on !== null && it.getAttribute('data-key') === on);
			});
		}

		var lastThreadSig = '';
		function renderThread(scroll) {
			autoPick();
			var d = openDlg();
			paintOpen();
			threadSec.classList.toggle('none', !d);
			if (!d) {
				lastThreadSig = '';
				if (isPhone() && S.screen === 'thread') { goBack(); }
				return;
			}
			var av = avatar(d);
			dom.content(th.av, Array.prototype.slice.call(av.childNodes));
			th.av.className = av.className;
			th.name.textContent = dlgTitle(d);
			var sub = [];
			if (d.name) { sub.push(sms_fmt_sender(d.shown)); }
			if (d.alpha) { sub.push(_('alphanumeric sender')); }
			else if (d.shown.replace(/\D/g, '').length <= 6) { sub.push(_('short number')); }
			sub.push(_('messages: %d').format(d.msgs.length + d.out.length));
			th.sub.textContent = sub.join(' · ');
			th.fwd.disabled = !d.msgs.length;
			th.del.disabled = !d.msgs.length || S.deleting;
			th.del.style.display = smsReadOnly ? 'none' : '';

			var all = d.msgs.map(function(m) { return { m: m, epoch: m.epoch }; })
				.concat(d.out.map(function(o) { return { o: o, epoch: o.epoch }; }))
				.sort(function(a, b) { return a.epoch - b.epoch; });
			var sig = d.key + '\u0001' + all.map(function(x) {
				return x.m ? x.m.index + (x.m.isNew ? '*' : '') + x.m.text.length : 'o' + x.o.id + x.o.state;
			}).join(',');
			if (sig !== lastThreadSig) {
				var atBottom = th.body.scrollHeight - th.body.scrollTop - th.body.clientHeight < 40;
				lastThreadSig = sig;
				var nodes = [], lastDay = '', hadOut = false;
				all.forEach(function(x) {
					var local = x.m ? x.m.local : x.o.local;
					var day = sms_day_label(local);
					if (day && day !== lastDay) { nodes.push(E('div', { 'class': 'tg-sms-day' }, [ day ])); lastDay = day; }
					if (x.m) {
						var m = x.m;
						var meta = [];
						if (m.parts > 1) { meta.push(E('span', { 'class': 'tg-sms-parts' }, [ _('%d parts').format(m.parts) ])); }
						meta.push(sms_hm(m.local));
						var b = E('div', { 'class': 'tg-sms-bub' + (m.isNew ? ' new' : ''), 'data-index': m.index },
							sms_rich(m.text).concat([ E('div', { 'class': 'tg-sms-meta' }, meta) ]));
						b.addEventListener('click', function(ev) {
							var codeEl = ev.target.closest ? ev.target.closest('.tg-sms-code') : null;
							if (codeEl) { sms_copy_code(codeEl); }
							if (m.isNew) { markRead([ m ]); }
						});
						nodes.push(b);
					} else {
						var o = x.o;
						hadOut = true;
						var st = o.state === 'ok' ? icon('check', 13) : o.state === 'q' ? icon('clock', 12) : icon('warn', 12);
						nodes.push(E('div', { 'class': 'tg-sms-bub out' + (o.state === 'err' ? ' err' : '') }, [ o.text,
							E('div', { 'class': 'tg-sms-meta' }, [ sms_hm(o.local), st ]) ]));
					}
				});
				if (hadOut) { nodes.push(E('div', { 'class': 'tg-sms-outnote' }, [ _('sent from this page') ])); }
				dom.content(th.body, nodes);
				if (scroll || atBottom) { th.body.scrollTop = th.body.scrollHeight; }
			}
			if (scroll && isPhone() && S.screen === 'thread') { phoneShowThread(); }
			if (smsReadOnly) { reply.lock(_('Android SMS storage is read-only.')); }
			else if (d.alpha) { reply.lock(_('The sender is alphanumeric, you cannot reply to it. To write to a number, use "New SMS".')); }
			else { reply.lock(''); }
		}

		function renderHead() {
			var n = S.msgs.filter(function(m) { return m.isNew; }).length;
			var dn = buildDialogs().length;
			hd.icoN.textContent = String(n);
			hd.ico.classList.toggle('off', !n);
			hd.pillM.classList.toggle('has', !!n);
			hd.pillM.lastChild.textContent = _('New') + ': ' + n;
			hd.main.textContent = S.loading && !S.msgs.length ? _('Loading messages…')
				: n ? _('New') + ': ' + n + ' · ' + _('Conversations') + ': ' + dn
				: _('No new messages');
			hd.badge.textContent = sms_transport();
			// stays in place (disabled without new messages), so the buttons next to it do not jump
			markBtns.forEach(function(b) { b.style.display = smsReadOnly ? 'none' : ''; b.disabled = !n; });
			writeBtns.forEach(function(b) { b.style.display = smsReadOnly ? 'none' : ''; });
			errAlert.style.display = (S.error && S.msgs.length) ? '' : 'none';
			roAlert.style.display = smsReadOnly ? '' : 'none';
		}

		function renderAll() {
			renderHead();
			autoPick();
			renderList();
			renderThread(false);
		}
		self._renderAll = renderAll;

		function setMessages(list) {
			var hide = uci.get('5gmodem', 'sms', 'bnumber');
			S.msgs = list.map(function(item) { return sms_make_card(item, hide); });
		}

		/* ---------- sending (former Outbox) ---------- */
		var sentId = 0;
		function addSent(to, text, state) {
			var k = sms_dlg_key(to);
			var o = { id: ++sentId, to: to, text: text, state: state, local: sms_local_now(), epoch: Date.now() };
			(S.sent[k] = S.sent[k] || []).push(o);
			return k;
		}

		function sendTo(c, number, text, fromNew) {
			if (c.busy) { return; }
			uci.unload('5gmodem');
			return uci.load('5gmodem').then(function() {
				var phn = String(number || '').trim();
				if (uci.get('5gmodem', 'sms', 'prefix') == '1' && /^\d{10}$/.test(phn)) {
					var pn = String(uci.get('5gmodem', 'sms', 'pnumber') || '').replace(/[^0-9+]/g, '');
					phn = pn + phn;
				}
				var port = uci.get('5gmodem', 'sms', 'sendport');
				if (phn.length < 3) { ui.addNotification(null, E('p', _('Please enter phone number')), 'info'); return; }
				if (!port) { ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info'); return; }
				if (text.length < 1) { ui.addNotification(null, E('p', _('Please enter a message text')), 'info'); return; }
				c.setBusy(true);
				c.status.innerHTML = '';
				dom.content(c.status, E('div', { 'class': 'tg-sms-st q' }, [ E('span', { 'class': 'spinning' }, [ _('Sending…') ]) ]));
				return fs.exec(BRIDGE, [ 'send', phn, text, port ]).then(function(res) {
					var out = String((res && res.stdout) || '').trim(), err = String((res && res.stderr) || '').trim();
					var state = /sms sent sucessfully/i.test(out) ? 'ok' : /^sms queued/im.test(out) ? 'q' : 'err';
					var key = addSent(phn, text, state);
					var retry = function() { sendTo(c, number, text, fromNew); };
					if (state !== 'err') {
						c.ta.value = '';
						c.update();
						if (fromNew) {
							nw.num.value = '';
							paintChips();
							c.status.innerHTML = '';
							openDialog(key, false);
							showStatus(reply, state, '', null);
						} else {
							showStatus(c, state, '', null);
						}
					} else {
						showStatus(c, 'err', [ out, err ].filter(Boolean).join('\n'), retry);
					}
					renderAll();
				}).catch(function(e) {
					showStatus(c, 'err', String(e && e.message || e), function() { sendTo(c, number, text, fromNew); });
				}).finally(function() { c.setBusy(false); });
			});
		}

		function sendGroup(c, text) {
			if (c.busy) { return; }
			uci.unload('5gmodem');
			return uci.load('5gmodem').then(function() {
				var port = uci.get('5gmodem', 'sms', 'sendport');
				var dx = (uci.get('5gmodem', 'sms', 'delay') || 0) * 1000;
				if (!port) { ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info'); return; }
				if (text.length < 1) { ui.addNotification(null, E('p', _('Please enter a message text')), 'info'); return; }
				var xs = smsBook.slice(), log = '';
				var pre = E('pre', { 'class': 'tg-sms-log' }, '');
				dom.content(c.status, E('div', {}, [
					E('div', { 'class': 'tg-sms-note', 'style': 'margin-bottom:4px' }, [ _('Sending to contacts: %d, delay %s s').format(xs.length, String(dx / 1000)) ]),
					pre ]));
				c.setBusy(true);
				var chain = Promise.resolve();
				xs.forEach(function(ent, i) {
					chain = chain.then(function() {
						return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'send', ent.code, text, port ]), null).then(function(r) {
							var t = String(r == null ? '' : r).trim();
							var ok = /^sms sent sucessfully/.test(t);
							var line = ok ? _('[Bot] Message sent to number:') + ' ' + ent.code : ent.code + ': ' + (t || _('Error'));
							addSent(ent.code, text, ok ? 'ok' : /^sms queued/.test(t) ? 'q' : 'err');
							log += (i + 1) + '/' + xs.length + ' * ' + line + '\n';
							pre.textContent = log;
							if (dx > 0 && i < xs.length - 1) {
								return new Promise(function(resolve) { setTimeout(resolve, dx); });
							}
						});
					});
				});
				return chain.finally(function() { c.setBusy(false); renderAll(); });
			});
		}

		self._clearNew = function() {
			nw.comp.status.innerHTML = '';
			nw.comp.ta.value = '';
			nw.comp.update();
			nw.num.value = '';
			paintChips();
			nw.num.focus();
		};

		/* ---------- reading (former Inbox) ---------- */
		var portR0 = uci.get('5gmodem', 'sms', 'readport');
		var ledn = uci.get('5gmodem', 'sms', 'lednotify');
		var ledt = uci.get('5gmodem', 'sms', 'ledtype');
		var led = uci.get('5gmodem', 'sms', 'smsled');

		if (!portR0 && !isPortlessSmsModem() && uci.get('5gmodem', 'sms', 'sms_via_mm') != '1' && !window._smsPortNagged && (window._smsPortNagged = true)) {
			ui.addNotification(null, E('p', _('The package requires user configuration. <br /><br /><b>The following need to be set:</b> <ol><li>All ports for communication with the modem.</li><li>Additional options specific to the given modem (for handling USSD codes).</li><li>Notification LED (optional).</li></ol>')), 'info');
		}
		if (ledn == '1') {
			if (ledt === 'S') { L.resolveDefault(fs.exec_direct('/etc/init.d/led', [ 'restart' ]), null); }
			else if (ledt === 'D' && led) { L.resolveDefault(fs.write('/sys/class/leds/' + led + '/brightness', '0'), null); }
		}

		function doRefresh(updateCount, busy) {
			if (busy) { window._smsForceRender = true; if (!S.msgs.length) { S.loading = true; renderAll(); } }
			var p = doRefreshInner(updateCount);
			var done = function() { if (S.loading) { S.loading = false; renderAll(); } };
			if (!p || typeof p.then != 'function') { done(); return Promise.resolve(); }
			return p.then(function(r) { done(); return r; }, function(e) { done(); throw e; });
		}

		function doRefreshInner(updateCount) {
			var storeL = uci.get('5gmodem', 'sms', 'storage') || 'ME';
			var portR = uci.get('5gmodem', 'sms', 'readport');
			var _mv = uci.get('5gmodem', 'sms', 'mergesms');
			var smsM = (_mv == null || _mv === '') ? '1' : (_mv == '1' ? '1' : '0');
			var algo = uci.get('5gmodem', 'sms', 'algorithm');
			var hide = uci.get('5gmodem', 'sms', 'bnumber');
			var direct = uci.get('5gmodem', 'sms', 'direction');
			if (!portR && !isPortlessSmsModem() && uci.get('5gmodem', 'sms', 'sms_via_mm') != '1') {
				if (!window._smsPortNagged) {
					window._smsPortNagged = true;
					ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
				}
				return Promise.resolve();
			}
			return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'status', storeL, portR ])).then(function(res) {
				if (!res) { return; }
				var st = sms_parse_status(res);
				var t = st.t, u = st.u;
				S.u = u; S.t = t;
				if (u != null) { msg_bar(Math.floor(u), t); }
				return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'recv', storeL, portR ])).then(function(res2) {
					if (!res2) { return; }
					res2 = res2.replace(/\\u([0-9a-fA-F]{2})f{6}([0-9a-fA-F]{2})/g, '\\u$1$2');
					res2 = res2.replace(/[\u0000-\u001F]+/g, ' ');
					var json;
					try {
						var parsed = JSON.parse(res2);
						if (parsed.error) { throw new Error(parsed.error); }
						json = parsed.msg || [];
						sms_keys_apply(json, parsed.keys);
					} catch (e) {
						// keep the list already shown, see sms.md#reading-notes
						S.error = true;
						S.loading = false;
						renderAll();
						return;
					}
					if (!json.length && u > 0 && S.msgs.length) { return; }
					var _sig = [ storeL, portR, smsM, hide, direct, algo, smsReadOnly, res2 ].join('\u0001');
					var wasErr = S.error;
					S.error = false;
					if (!window._smsForceRender && _sig === window._smsLastSig && S.msgs.length) {
						if (wasErr) { renderHead(); }
						return;
					}
					window._smsForceRender = false;
					window._smsLastSig = _sig;

					json.forEach(function(o) {
						if (o && typeof o.content === 'string') { o.content = o.content.replace(/�/g, ' '); }
						if (o && typeof o.sender === 'string') { o.sender = o.sender.replace(/\s+$/, ''); }
					});

					if (smsM != '1' &&
					    uci.get('5gmodem', 'sms', 'mergesms_auto') != '1' &&
					    json.some(function(o) { return (o.total || 0) > 1; })) {
						smsM = '1';
						sms_persist({ 'mergesms': '1', 'mergesms_auto': '1' });
						ui.addNotification(null, E('p',
							_('Multipart messages found - merging enabled automatically. You can turn it off in SMS settings.')), 'info');
					}

					var result;
					if (smsM == '1') {
						result = sms_merge_parts(json);
						result.forEach(function(o) { o._ts = sms_ts_num(o.timestamp); });
						result.sort(function(a, b) { return b._ts - a._ts; });
						result.forEach(function(o) { delete o._ts; });
					} else {
						json.forEach(function(o) { o._ts = sms_ts_num(o.timestamp); });
						result = json.sort(function(a, b) {
							if (a._ts !== b._ts) { return b._ts - a._ts; }
							var sa = String(a.sender || ''), sb = String(b.sender || '');
							if (sa !== sb) { return sa < sb ? -1 : 1; }
							return (a.part || 0) - (b.part || 0);
						});
						json.forEach(function(o) { delete o._ts; });
					}

					S.loading = false;
					setMessages(result);
					sms_seen_sync(result);
					sms_cache_save(result, u, t);
					renderAll();

					if (updateCount && u != null) {
						var axx = result.map(function(o) { return o.index + '-'; }).join(' ').replace(/-/g, ' ');
						format_with_modem_index(axx).then(function(formattedIndex) {
							update_sms_count_for_modem(u).then(function(updatedCount) {
								sms_persist({ 'sms_count_index': formattedIndex, 'sms_count': updatedCount });
							});
						});
					}
				});
			});
		}

		function warmRender() {
			var c = sms_cache_load();
			if (!c || !c.list || !c.list.length || S.msgs.length) { return; }
			smsReadOnly = c.read_only === true;
			setMessages(c.list);
			sms_seen_sync(c.list);
			if (c.u != null) { msg_bar(Math.floor(c.u), c.t); }
			renderAll();
		}

		self._doRefresh = doRefresh;
		self._listProgress = function(done, total) {
			if (done == null) { lp.prog.style.display = 'none'; return; }
			lp.prog.style.display = '';
			lp.progTxt.textContent = _('Please wait... deleted') + ' ' + done + ' ' + _('of') + ' ' + total + ' ' + _('selected messages');
			lp.progFill.style.width = Math.max(3, Math.round(100 * done / Math.max(1, total))) + '%';
		};
		self._removeMsgs = function(indexes) {
			var gone = new Set(indexes);
			S.msgs = S.msgs.filter(function(m) { return !gone.has(m.index); });
			gone.forEach(function(k) { S.sel.delete(k); });
			if (S.view === 'dlg') {
				var keys = new Set(buildDialogs().map(function(d) { return d.key; }));
				S.sel.forEach(function(k) { if (!keys.has(k)) { S.sel.delete(k); } });
			}
			if (!S.sel.size) { S.selMode = false; lp.selBtn.classList.remove('on'); }
			renderAll();
		};
		self._setDeleting = function(on) { S.deleting = on; renderAll(); };

		renderAll();
		warmRender();
		if (window.location.hash === '#new') {
			try { window.history.replaceState(null, '', window.location.pathname + window.location.search); } catch (e) {}
			window.setTimeout(openNew, 0);
		}
		modemtabs.attach();
		// the list needs the read marks to tell new messages apart; the placeholders show meanwhile
		S.loading = true; renderAll();
		Promise.resolve(self._seenP).then(function() { doRefresh(true, true); });
		// not while a deletion runs: a stick busy deleting answers the list with nothing, and the
		// page showed "No messages" until the job ended; finish() refreshes anyway
		poll.add(function() { return (document.hidden || S.deleting) ? Promise.resolve() : doRefresh(false); }, 15);

		return root;
	},

	/* ---------- actions ---------- */
	handleModemChange: function(ev) {
		var self = this;
		var serialModems = serial_modems();
		if (!serialModems.length) { return; }
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		var currentIndex = serialModems.findIndex(function(s) { return s.comm_port === currentPort; });
		if (currentIndex === -1) { currentIndex = 0; }
		var direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		var newModem = serialModems[(currentIndex + direction + serialModems.length) % serialModems.length];
		if (!newModem || !newModem.comm_port) { return; }
		// one pager for reading and sending: replies go out from the modem on screen
		sms_persist({ 'readport': newModem.comm_port, 'sendport': newModem.comm_port }).then(function() {
			var label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
			document.querySelectorAll('.tg-sms .modem-display-text').forEach(function(el) { el.textContent = label; });
			self._S.msgs = [];
			self._S.open = null;
			self._S.autoOpen = true;
			return sms_seen_load().then(function() {
				window._smsForceRender = true;
				return self._doRefresh(false, true);
			});
		});
	},

	handleSWarea: function(stg) {
		var self = this;
		return sms_persist({ 'storage': stg }).then(function() {
			self._paintStore();
			if (typeof self._doRefresh == 'function') { self._doRefresh(false, true); }
		});
	},

	handleRefresh: function() {
		if (typeof this._doRefresh == 'function') { return this._doRefresh(false, true); }
		window.location.reload();
	},

	handleClear: function() {
		this._clearNew();
	},

	// Contact chip: fills the number; a thank-you text for the author's contact, as before.
	handleCopy: function(pick) {
		var nw = this._nw;
		nw.num.value = String(pick.code || '');
		var tx = nw.comp.ta;
		var thanks = _('Hi! I really like your app. How can I thank you?');
		var isAuthor = /^t\.me\/openwrt_fun$/i.test(String(pick.name || '').trim());
		var cur = tx.value;
		if (isAuthor && cur.trim() === '') { tx.value = thanks; }
		else if (!isAuthor && cur === thanks) { tx.value = ''; }
		else { return; }
		nw.comp.update();
	},

	handleContacts: function() {
		var self = this;
		var reload = function() {
			// the editor has no close callback: re-read the phonebook when its modal is gone
			var t = window.setInterval(function() {
				if (document.body.classList.contains('modal-overlay-active')) { return; }
				window.clearInterval(t);
				L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/phonebook.user'), '').then(function(text) {
					self._loadBook(text);
					self._paintChips();
					self._renderAll();
				});
			}, 700);
		};
		return fs.trimmed('/etc/5gmodem/modem/phonebook.user').then(function(content) {
			new editors.phonebookEditorDialog(_('Edit User Contacts'), content || '').show();
		}).catch(function() {
			new editors.phonebookEditorDialog(_('Edit User Contacts'), '').show();
		}).then(reload);
	},

	handleForward: function(msgs) {
		var self = this;
		if (!msgs || !msgs.length) {
			ui.addNotification(null, E('p', _('Please select the message(s) to be forwarded')), 'info');
			return;
		}
		var items = msgs.map(function(m) { return { timestamp: m.local, sender: m.shown, message: m.text }; });
		uci.load('5gmodem').then(function() {
			if (uci.get('5gmodem', 'sms', 'forward_sms_enabled') !== '1') {
				ui.addNotification(null, E('p', _('SMS forwarding function is not enabled')), 'info');
				return;
			}
			var withHost = uci.get('5gmodem', 'sms', 'forward_sms_mail_hostname') === '1';
			if (withHost) {
				var parts = items.map(function(d) {
					return (d.timestamp || '').trim() + (items.length > 1 ? ' - ' + (d.sender || '').trim() : '') + '\n' + (d.message || '').trim();
				});
				var sender = items.length === 1 ? (items[0].sender || '').trim() : '';
				return sms_seen_exec([ 'fwdhead', sender ]).then(function(out) {
					var h = String(out || '').trim();
					self.showEmailModal(h || ('SMS ' + sender).trim(), parts.join('\n\n'));
				});
			}
			if (items.length === 1) {
				var d = items[0];
				self.showEmailModal('SMS ' + (d.timestamp || '').trim() + ' - ' + (d.sender || '').trim(), (d.message || '').trim());
				return;
			}
			return uci.load('system').then(function() {
				var hostname = uci.get('system', '@system[0]', 'hostname') || _('My Router');
				self.showEmailModal(hostname, items.map(function(d) {
					return (d.timestamp || '').trim() + ' - ' + (d.sender || '').trim() + '\n' + (d.message || '').trim();
				}).join('\n\n'));
			});
		});
	},

	showEmailModal: function(defaultSubject, defaultBody) {
		ui.showModal(_('Forward SMS to E-mail'), [
			E('p', _('Subject:')),
			E('input', { 'type': 'text', 'id': 'email-subject', 'class': 'cbi-input-text',
				'style': 'width: 100% !important; margin-bottom: 15px;', 'value': defaultSubject }),
			E('p', _('Message text:')),
			E('textarea', { 'id': 'email-body', 'class': 'cbi-input-textarea',
				'style': 'width: 100% !important; height: 30vh; min-height: 250px;', 'wrap': 'off', 'spellcheck': 'false' }, [ defaultBody ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-action important',
					'click': ui.createHandlerFn(this, 'sendEmailFromModal') }, _('Send'))
			])
		], 'cbi-modal');
	},

	sendEmailFromModal: function() {
		var subject = document.getElementById('email-subject').value;
		var body = document.getElementById('email-body').value;
		if (!subject || !body) {
			ui.addNotification(null, E('p', _('Subject and body cannot be empty')), 'error');
			return;
		}
		ui.hideModal();
		var note = ui.addNotification(null, E('p', {}, [ E('span', { 'class': 'spinning' }, [ _('Sending e-mail...') ]) ]), 'info');
		var drop = function() { try { if (note && note.parentNode) { note.parentNode.removeChild(note); } } catch (e) {} };
		return callForwardSMS(subject, body).then(function(response) {
			drop();
			if (response.success) {
				popTimeout(null, E('p', _('Message forwarded successfully')), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', [ _('Failed to forward message: %s').format(response.error || 'Unknown error') ]), 'error');
			}
		}).catch(function(err) {
			drop();
			ui.addNotification(null, E('p', [ _('Error: %s').format(err && err.message) ]), 'error');
		});
	},

	handleDelete: function(msgs) {
		if (smsReadOnly) { ui.addNotification(null, E('p', _('Android SMS storage is read-only.')), 'info'); return; }
		var self = this;
		if (!msgs || !msgs.length) {
			ui.addNotification(null, E('p', _('Please select the message(s) to be deleted')), 'info');
			return;
		}
		if (this._S.deleting) { return; }
		return uci.load('5gmodem').then(function() {
			var storeL = uci.get('5gmodem', 'sms', 'storage') || 'ME';
			var portR = uci.get('5gmodem', 'sms', 'readport') || '';

			var picked = [], idx = [];
			msgs.forEach(function(m) {
				var own = [];
				String(m.index || '').split(/[^0-9]+/).forEach(function(n) {
					n = parseInt(n, 10);
					if (!Number.isNaN(n)) { own.push(n); }
				});
				if (own.length) {
					picked.push({ key: String(m.index), idx: own });
					idx = idx.concat(own);
				}
			});
			if (!idx.length) { return; }

			var showProgress = function(done) { self._listProgress(done, idx.length); };
			var hideProgress = function() { self._listProgress(null); self._setDeleting(false); };
			var parse = function(out) {
				try { return JSON.parse(out || '{}') || {}; } catch (e) { return {}; }
			};
			var whyText = function(f) {
				switch (f.why) {
					case 'busy': return _('the modem port is busy with another operation, try again in a minute');
					case 'noanswer': return _('the modem did not confirm the deletion');
					case 'refused': return f.arg
						? _('the modem refused to delete the message (error %s)').format(f.arg)
						: _('the modem refused to delete the message');
					case 'archive': return _('could not remove the message from the router memory');
					case 'noport': return _('the modem has no AT port');
				}
				return _('the deletion stopped unexpectedly');
			};
			var fail = function(text) {
				hideProgress();
				ui.addNotification(null, E('p', text), 'error');
				self._doRefresh(false, true);
			};
			var finish = function(job) {
				var ok = {}, reasons = [];
				(job.ok || []).forEach(function(n) { ok[n] = true; });
				(job.fail || []).forEach(function(f) {
					var t = whyText(f);
					if (reasons.indexOf(t) < 0) { reasons.push(t); }
				});
				var gone = [], kept = 0;
				picked.forEach(function(p) {
					if (p.idx.every(function(n) { return ok[n]; })) { gone.push(p.key); } else { kept++; }
				});
				if (kept && !reasons.length) { reasons.push(whyText({})); }
				try { window.localStorage.removeItem(sms_cache_key()); } catch (e) {}
				hideProgress();
				self._removeMsgs(gone);
				if (kept) {
					ui.addNotification(null, E('p', [ _('Deleted: %d, not deleted: %d').format(gone.length, kept) +
						' - ' + reasons.join('; ') ]), 'error');
					self._doRefresh(false, true);
					return;
				}
				return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'status', storeL, portR ]), '').then(function(res) {
					var st = sms_parse_status(res);
					if (st.u != null) {
						self._paintMem(Math.floor(st.u), st.t);
						update_sms_count_for_modem(st.u).then(function(v) { sms_persist({ 'sms_count': v }); });
					}
				});
			};
			var started = Date.now();
			var pollJob = function() {
				return new Promise(function(resolve) { window.setTimeout(resolve, 1500); }).then(function() {
					return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'delete-status' ]), '');
				}).then(function(out) {
					var job = parse(out);
					if (job.state === 'running' || (!job.state && Date.now() - started < 300000)) {
						if (job.done != null) { showProgress(job.done); }
						return pollJob();
					}
					if (job.state === 'done' || job.state === 'dead') { return finish(job); }
					fail(_('Could not delete messages'));
				});
			};

			self._setDeleting(true);
			showProgress(0);
			return L.resolveDefault(fs.exec_direct(BRIDGE, [ 'delete-start', idx.join(','), storeL, portR ]), '')
				.then(function(out) {
					var job = parse(out);
					if (job.state === 'busy') { fail(_('The previous deletion is still running, try again in a minute')); return; }
					if (job.state !== 'running') { fail(_('Could not delete messages')); return; }
					return pollJob();
				});
		});
	},

	popTimeout: function(a, message, timeout, severity) {
		ui.addTimeLimitedNotification(a, message, timeout, severity);
	}
});
