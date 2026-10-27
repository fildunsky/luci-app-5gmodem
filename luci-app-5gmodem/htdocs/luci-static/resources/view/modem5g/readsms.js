'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require rpc';
'require poll';
'require sms-tool-5gm.smssettings as smssettings';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

var callForwardSMS = rpc.declare({
    object: '5gmodem_sms_forward',
    method: 'forward',
    params: ['subject', 'message']
});

function msg_bar(v, m) {
var pg = document.querySelector('#msg')
if (!pg || !pg.firstElementChild) { return; }
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);

pg.firstElementChild.style.width = pc + '%';
pg.setAttribute('title', _('Memory: %s/%s').format(v, m));
}

function sms_parse_status(res) {
	var u = String(res || '').match(/used:\s*(\d+)/i);
	var t = String(res || '').match(/total:\s*(\d+)/i);
	return { u: u ? u[1] : null, t: t ? t[1] : null };
}

var SMS_ROW = 4;
function smsMasonry(list) {
	if (!list) { return; }
	var cs = getComputedStyle(list);
	var wide = cs.display === 'grid';
	var gap = wide ? (parseFloat(cs.columnGap) || 0) : 0;
	var kids = Array.prototype.slice.call(list.children);
	if (!wide) { kids.forEach(function(el) { el.style.gridRowEnd = ''; }); return; }
	var hs = kids.map(function(el) { return el.getBoundingClientRect().height; });
	kids.forEach(function(el, i) {
		el.style.gridRowEnd = 'span ' + Math.max(1, Math.ceil((hs[i] + gap) / SMS_ROW));
	});
}
function smsMasonryWatch(list) {
	var queued = false;
	var run = function() {
		if (queued) { return; }
		queued = true;
		window.setTimeout(function() { queued = false; smsMasonry(list); }, 0);
	};
	var ro = window.ResizeObserver ? new ResizeObserver(run) : null;
	if (ro) { ro.observe(list); }
	var watchKids = function() {
		if (!ro) { return; }
		Array.prototype.forEach.call(list.children, function(el) { ro.observe(el); });
	};
	if (window.MutationObserver) {
		new MutationObserver(function(recs) {
			if (ro) {
				recs.forEach(function(r) {
					Array.prototype.forEach.call(r.removedNodes, function(n) { if (n.nodeType === 1) { ro.unobserve(n); } });
				});
			}
			watchKids();
			run();
		}).observe(list, { childList: true });
	}
	window.addEventListener('resize', run);
	watchKids();
	run();
	return list;
}

function smsSetState(state, opts) {
	var list = document.getElementById('smsList');
	if (!list) { return null; }
	opts = opts || {};
	var hasCards = !!list.querySelector('.sms-card');

	if (state === 'error') {
		smsNote(hasCards ? (opts.note || _('Could not read messages')) : null);
		if (!hasCards) { smsPlaceholder('error'); }
		return null;
	}
	if (state === 'loading') {
		if (hasCards) { smsNote(_('Loading messages…')); return null; }
		smsPlaceholder('loading');
		return null;
	}
	smsNote(null);
	if (state === 'empty') { smsPlaceholder('empty'); return null; }
	smsKeepSelection(list);
	list.innerHTML = '';
	return list;
}

var _smsSel = [];
function smsKeepSelection(list) {
	_smsSel = [];
	(list || document).querySelectorAll('.sms-card.selected').forEach(function(c) {
		var i = c.getAttribute('data-index');
		if (i) { _smsSel.push(i); }
	});
}
function smsRestoreSelection() {
	if (!_smsSel.length) { return; }
	var alive = [];
	_smsSel.forEach(function(i) {
		var c = document.querySelector('.sms-card[data-index="' + i + '"]');
		if (c) { sms_set_selected(c, true); alive.push(i); }
	});
	_smsSel = alive;
	sms_update_selcount();
}

function smsNote(text) {
	var old = document.getElementById('sms-updating');
	if (old && old.parentNode) { old.parentNode.removeChild(old); }
	if (!text) { return; }
	var list = document.getElementById('smsList');
	if (!list || !list.parentNode) { return; }
	list.parentNode.insertBefore(E('em', {
		'id': 'sms-updating', 'class': 'spinning',
		'style': 'font-size:92%;opacity:.7;margin:2px 0 6px;display:inline-block'
	}, text), list);
}

function smsPlaceholder(state) {
	var list = document.getElementById('smsList');
	if (!list) { return; }
	list.innerHTML = '';
	list.appendChild(E('div', { 'class': 'sms-empty', 'id': 'smsEmpty',
		'data-state': state === 'loading' ? 'loading' : (state === 'error' ? 'error' : 'empty') }, [
		state === 'loading'
			? E('span', { 'class': 'spinning' }, _('Loading messages…'))
			: (state === 'error'
				? E('span', {}, _('Could not read messages - will retry on the next refresh'))
				: E('span', {}, _('No messages')))
	]));
}

function sms_placeholder(state) { return smsPlaceholder(state); }

function sms_selected_cards() {
	return document.querySelectorAll('.sms-card.selected');
}

function sms_set_selected(card, on) {
	if (on) { card.classList.add('selected'); } else { card.classList.remove('selected'); }
	card.setAttribute('aria-pressed', on ? 'true' : 'false');
}

function sms_update_selcount() {
	var n = sms_selected_cards().length;

	var el = document.getElementById('sms-selcount');
	if (el) { el.textContent = n ? _('selected: %d').format(n) : ''; }

	['forward', 'execute'].forEach(function(id) {
		var b = document.getElementById(id);
		if (b) { b.style.display = n ? '' : 'none'; }
	});
}

function sms_cache_key() {
	var s = uci.get('5gmodem', 'sms', 'storage') || 'ME';
	var p = uci.get('5gmodem', 'sms', 'readport') || '';
	return 'sms-last:' + s + ':' + p;
}
function sms_cache_save(list, u, t) {
	try {
		window.localStorage.setItem(sms_cache_key(),
			JSON.stringify({ list: list, u: u, t: t }));
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
				'class': 'sms-code',
				'role': 'button',
				'title': _('Click to copy the code'),
				'data-code': m[2].replace(/[ -]/g, '')
			}, [ m[2] ]));
			last = at + m[2].length;
		}
		if (last < s.length) { out.push(document.createTextNode(s.slice(last))); }
	});
	return out;
}

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

function sms_seen_exec(args) {
	var port = uci.get('5gmodem', 'sms', 'readport') || '';
	var direct = function() {
		return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', args), '');
	};
	if (!port) { return direct(); }
	return sms_port_map().then(function(map) {
		var path = map[port] || '';
		var active = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		if (!path || path === active) { return direct(); }
		return fs.exec('/usr/share/5gmodem/smsbridge.sh', args, { SMS_MODEM: path })
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

function sms_modem_markread(cards) {
	var ids = [];
	cards.forEach(function(c) {
		String(c.getAttribute('data-index') || '').split('-').forEach(function(i) {
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

function sms_update_newcount() {
	var n = document.querySelectorAll('.sms-card.sms-new').length;
	var badge = document.getElementById('sms-newcount');
	var btn = document.getElementById('sms-markread');
	if (badge) {
		badge.textContent = n ? (_('New') + ': ' + n) : '';
		badge.style.display = n ? '' : 'none';
	}
	if (btn) { btn.style.display = n ? '' : 'none'; }
}

function sms_mark_all_read() {
	var keys = [];
	var cards = Array.prototype.slice.call(document.querySelectorAll('.sms-card.sms-new'));
	sms_modem_markread(cards);
	cards.forEach(function(c) {
		(c.dataset.keys ? c.dataset.keys.split('\n') : [ c.dataset.key ])
			.forEach(function(k) { if (k) { keys.push(k); } });
		c.classList.remove('sms-new');
	});
	sms_update_newcount();
	return sms_seen_add(keys);
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

function sms_make_card(item, iconSrc, hide) {
	var sender = String(item.sender || '');
	if (hide && sender.includes(hide)) { sender = sender.slice(0, -5) + '#####'; }
	var text = String(item.content || '').replace(/\s+/g, ' ').trim();
	var when = sms_localtime(item.timestamp, item.tz);

	var keys = sms_msg_keys(item);
	var key = keys[0];
	var isNew = !!(smsSeen && !smsSeenFirst && sms_msg_pairs(item).some(function(p) {
		return !smsSeen.has(p[0]) && !smsSeen.has(p[1]);
	}));

	var card = E('button', {
		'type': 'button',
		'class': 'btn cbi-button sms-card' + (isNew ? ' sms-new' : ''),
		'data-key': key,
		'data-keys': keys.join('\n'),
		'aria-pressed': 'false',
		'data-index': String(item.index),
		'data-sender': sender,
		'data-timestamp': when,
		'data-message': text
	}, [
		E('div', { 'class': 'sms-card-head' }, [
			E('span', { 'class': 'sms-card-from' }, [
				E('span', { 'class': 'sms-row-icon' }, [
					E('img', { 'src': iconSrc })
				]),
				/* see docs/subsystems/sms.md#xss-text-nodes */
				E('span', {}, [ sms_fmt_sender(sender) ])
			]),
			E('span', { 'class': 'sms-card-time' }, [ when ])
		]),
		E('div', { 'class': 'sms-card-text' }, sms_codify(sms_linkify(text), text))
	]);

	card.addEventListener('click', function(ev) {
		var codeEl = ev.target.closest ? ev.target.closest('.sms-code') : null;
		if (codeEl) { sms_copy_code(codeEl); }
		if (card.classList.contains('sms-new')) {
			card.classList.remove('sms-new');
			sms_seen_add(keys);
			sms_modem_markread([ card ]);
			sms_update_newcount();
		}
		if (codeEl) { return; }
		sms_set_selected(card, !card.classList.contains('selected'));
		sms_update_selcount();
	});
	return card;
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
    ui.addTimeLimitedNotification(a, message, timeout, severity);
}

function format_with_modem_index(value) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			return value;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			return value;
		}
		
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		
		var modemIndex = -1;
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				modemIndex = i + 1;
				break;
			}
		}
		
		if (modemIndex === -1) {
			return value;
		}
		
		return 'dfm' + modemIndex + '_' + value;
		
	}).catch(function() {
		return value;
	});
}

function update_sms_count_for_modem(newValue) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			return newValue;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			return newValue;
		}
		
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		var currentModemIndex = -1;
		
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				currentModemIndex = i + 1;
				break;
			}
		}
		
		if (currentModemIndex === -1) {
			return newValue;
		}
		
		var existingSmsCount = uci.get('5gmodem', 'sms', 'sms_count') || '';
		var parts = existingSmsCount.split(' ').filter(function(p) { return p.trim() !== ''; });
		
		var updated = {};
		parts.forEach(function(part) {
			var match = part.match(/^dfm(\d+)_(\d+)$/);
			if (match) {
				var modemIdx = parseInt(match[1]);
				if (modemIdx > 0 && modemIdx <= serialModems.length) {
					updated[modemIdx] = match[2];
				}
			}
		});
		
		updated[currentModemIndex] = newValue;
		
		var result = [];
		for (var i = 1; i <= serialModems.length; i++) {
			var count = updated[i] || '0';
			result.push('dfm' + i + '_' + count);
		}
		
		return result.join(' ');
		
	}).catch(function() {
		return newValue;
	});
}

function save_count() {
	uci.load('5gmodem').then(function() {

		var storeL = (uci.get('5gmodem', 'sms', 'storage'));
		var portR = (uci.get('5gmodem', 'sms', 'readport'));

			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
					.then(function(res) {
							if (res) {
								var _st = sms_parse_status(res);
								if (_st.u == null) { return; }
								update_sms_count_for_modem(_st.u).then(function(updatedValue) {
									sms_persist({ 'sms_count': updatedValue });
								});
							}
			});
	});
}

function isHilinkModem() {
	var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
	if (!p) { return false; }
	var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	return uci.get('5gmodem', sec, 'kind') === 'hilink';
}

return view.extend({
	load: function() {
		var self = this, args = arguments;
		return fresh.check(30901, [ smssettings, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('defmodems')),
			sms_seen_load()
		]);
	},

	handleModemChange: function(ev) {
		var sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		var serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		var currentPort = uci.get('5gmodem', 'sms', 'readport');
		var currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		var direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		var newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		var newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			sms_persist({ 'readport': newModem.comm_port }).then(function() {
				sms_seen_load().then(function() { window._smsForceRender = true; });
				var modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					var label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	handleSWarea: function(ev) {
		var self = this;
		var val = document.querySelector('input[name="filter_area"]:checked').value;
		var stg = (val === 'sim') ? 'SM' : 'ME';
		return sms_persist({ 'storage': stg }).then(function() {
			if (typeof self._doRefresh == 'function') { self._doRefresh(false, true); }
		});
	},

    handleForward: function(ev) {
	    var checked = sms_selected_cards();
	    
	    if (checked.length === 0) {
		    ui.addNotification(null, E('p', _('Please select the message(s) to be forwarded')), 'info');
		    return;
	    }
	    
	    var self = this;
	    
	    uci.load('5gmodem').then(function() {
		    var fwdEnabled = uci.get('5gmodem', 'sms', 'forward_sms_enabled');
		    
		    if (fwdEnabled !== '1') {
			    ui.addNotification(null, E('p', _('SMS forwarding function is not enabled')), 'info');
			    return;
		    }
		    
		    var emailSubject = '';
		    var emailBody = '';
		    var withHost = uci.get('5gmodem', 'sms', 'forward_sms_mail_hostname') === '1';
		    var head = function(sender) {
			    return sms_seen_exec([ 'fwdhead', sender ]).then(function(out) {
				    return String(out || '').trim();
			    });
		    };

		    if (withHost) {
			    var parts = checked.map(function(card) {
				    var d = card.dataset;
				    return (d.timestamp || '').trim() + (checked.length > 1 ? ' - ' + (d.sender || '').trim() : '') + '\n' + (d.message || '').trim();
			    });
			    var sender = checked.length === 1 ? (checked[0].dataset.sender || '').trim() : '';
			    return head(sender).then(function(h) {
				    self.showEmailModal(h || ('SMS ' + sender).trim(), parts.join('\n\n'));
			    });
		    }

		    if (checked.length === 1) {
			    var d = checked[0].dataset;

			    var sender = (d.sender || '').trim();
			    var timestamp = (d.timestamp || '').trim();
			    var message = (d.message || '').trim();

			    emailSubject = 'SMS ' + timestamp + ' - ' + sender;
			    emailBody = message;
			    
			    self.showEmailModal(emailSubject, emailBody);
		    } 
		    else {
			    uci.load('system').then(function() {
				    var hostname = uci.get('system', '@system[0]', 'hostname') || _('My Router');
				    
				    var messages = [];
				    checked.forEach(function(card) {
					    var d = card.dataset;

					    var timestamp = (d.timestamp || '').trim();
					    var sender = (d.sender || '').trim();
					    var message = (d.message || '').trim();

					    messages.push(timestamp + ' - ' + sender + '\n' + message);
				    });
				    
				    var emailBody = messages.join('\n\n');
				    
				    self.showEmailModal(hostname, emailBody);
			    });
		    }
	    });
    },

    showEmailModal: function(defaultSubject, defaultBody) {
	    var self = this;
	    
	    ui.showModal(_('Forward SMS to E-mail'), [
		    E('p', _('Subject:')),
		    E('input', {
			    'type': 'text',
			    'id': 'email-subject',
			    'class': 'cbi-input-text',
			    'style': 'width: 100% !important; margin-bottom: 15px;',
			    'value': defaultSubject
		    }),
		    E('p', _('Message text:')),
		    E('textarea', {
			    'id': 'email-body',
			    'class': 'cbi-input-textarea',
			    'style': 'width: 100% !important; height: 30vh; min-height: 250px;',
			    'wrap': 'off',
			    'spellcheck': 'false'
		    }, [ defaultBody ]),
		    E('div', { 'class': 'right' }, [
			    E('button', {
				    'class': 'btn',
				    'click': ui.hideModal
			    }, _('Cancel')), ' ',
			    E('button', {
				    'class': 'cbi-button cbi-button-action important',
				    'click': ui.createHandlerFn(this, 'sendEmailFromModal')
			    }, _('Send'))
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
	    
	    var self = this;
	    
	    ui.hideModal();
	    
	    var contentArea = document.getElementById('forward-status');
	    contentArea.style.display = 'block';
	    contentArea.innerHTML = '';
	    contentArea.appendChild(E('div', {'class': 'alert alert-info'}, 
		    E('span', {'class': 'spinning'}, _('Sending e-mail...'))
	    ));
	    
	    callForwardSMS(subject, body).then(function(response) {
		    contentArea.innerHTML = '';
		    if (response.success) {
			    popTimeout(null, E('p', _('Message forwarded successfully')), 5000, 'info');
			    setTimeout(function() {
				    if (contentArea) {
					    contentArea.innerHTML = '';
					    contentArea.style.display = 'none';
				    }
			    }, 5000);
		    } else {
			    contentArea.innerHTML = '';
			    contentArea.style.display = 'none';
			    ui.addNotification(null, E('p', [ _('Failed to forward message: %s').format(response.error || 'Unknown error') ]), 'error');
		    }
	    }).catch(function(err) {
		    contentArea.innerHTML = '';
		    contentArea.style.display = 'none';
		    ui.addNotification(null, E('p', [ _('Error: %s').format(err && err.message) ]), 'error');
	    });
    },

	handleDelete: function(ev) {
		var viewSelf = this;
		if (sms_selected_cards().length == 0) {
			ui.addNotification(null, E('p', _('Please select the message(s) to be deleted')), 'info');
			return;
		}
		return uci.load('5gmodem').then(function() {
			var storeL = uci.get('5gmodem', 'sms', 'storage') || 'ME';
			var portR = uci.get('5gmodem', 'sms', 'readport') || '';
			var bridge = '/usr/share/5gmodem/smsbridge.sh';

			var picked = [], idx = [];
			sms_selected_cards().forEach(function(card) {
				var own = [];
				String(card.dataset.index || '').split(/[^0-9]+/).forEach(function(n) {
					n = parseInt(n, 10);
					if (!Number.isNaN(n)) { own.push(n); }
				});
				if (own.length) {
					picked.push({ key: String(card.dataset.index), idx: own });
					idx = idx.concat(own);
				}
			});
			if (!idx.length) { return; }

			var deletelabel = document.getElementById('deleteinfo');
			var showProgress = function(done) {
				if (!deletelabel) { return; }
				deletelabel.style.display = 'block';
				deletelabel.innerHTML = '';
				deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'},
					_('Please wait... deleted')+' '+done+' '+_('of')+' '+idx.length+' '+_('selected messages')));
			};
			var hideProgress = function() {
				if (deletelabel) { deletelabel.style.display = 'none'; deletelabel.innerHTML = ''; }
			};
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
				if (typeof viewSelf._doRefresh == 'function') { viewSelf._doRefresh(false, true); }
			};
			var finish = function(job) {
				var ok = {}, bad = {}, reasons = [];
				(job.ok || []).forEach(function(n) { ok[n] = true; });
				(job.fail || []).forEach(function(f) {
					bad[f.index] = true;
					var t = whyText(f);
					if (reasons.indexOf(t) < 0) { reasons.push(t); }
				});
				var gone = 0, kept = 0;
				picked.forEach(function(p) {
					var all = p.idx.every(function(n) { return ok[n]; });
					if (!all) { kept++; return; }
					gone++;
					var card = document.querySelector('.sms-card[data-index="' + p.key + '"]');
					if (card && card.parentNode) { card.parentNode.removeChild(card); }
				});
				if (kept && !reasons.length) { reasons.push(whyText({})); }
				sms_update_selcount();
				try { window.localStorage.removeItem(sms_cache_key()); } catch (e) {}
				hideProgress();
				if (!document.querySelector('.sms-card')) { smsSetState('empty'); }
				if (kept) {
					ui.addNotification(null, E('p', [ _('Deleted: %d, not deleted: %d').format(gone, kept) +
						' - ' + reasons.join('; ') ]), 'error');
					if (typeof viewSelf._doRefresh == 'function') { viewSelf._doRefresh(false, true); return; }
				}
				return L.resolveDefault(fs.exec_direct(bridge, [ 'status', storeL, portR ]), '')
					.then(function(res) {
						var st = sms_parse_status(res);
						if (st.u != null) {
							msg_bar(Math.floor(st.u), st.t);
							update_sms_count_for_modem(st.u).then(function(v) {
								sms_persist({ 'sms_count': v });
							});
						}
					});
			};
			var started = Date.now();
			var poll = function() {
				return new Promise(function(resolve) { window.setTimeout(resolve, 1500); }).then(function() {
					return L.resolveDefault(fs.exec_direct(bridge, [ 'delete-status' ]), '');
				}).then(function(out) {
					var job = parse(out);
					if (job.state === 'running' || (!job.state && Date.now() - started < 300000)) {
						if (job.done != null) { showProgress(job.done); }
						return poll();
					}
					if (job.state === 'done' || job.state === 'dead') { return finish(job); }
					fail(_('Could not delete messages'));
				});
			};

			showProgress(0);
			return L.resolveDefault(fs.exec_direct(bridge, [ 'delete-start', idx.join(','), storeL, portR ]), '')
				.then(function(out) {
					var job = parse(out);
					if (job.state === 'busy') {
						fail(_('The previous deletion is still running, try again in a minute'));
						return;
					}
					if (job.state !== 'running') {
						fail(_('Could not delete messages'));
						return;
					}
					return poll();
				});
		});
	},

                                                                                                                                              
	handleRefresh: function(ev) {
		if (typeof this._doRefresh == 'function') { return this._doRefresh(false, true); }
		window.location.reload();
	},

	render: function(data) {
		modemtabs.attach();
		var self = this;
		return Promise.resolve(this.renderMain(data)).then(function(main) {
			return smssettings.panel('receive').then(function(panel) {
				return E([], [ main, panel ]);
			});
		});
	},

	renderMain: function(data) {

		var self = this;
		var sections, store;
		var view = document.getElementById("smssarea");
		store = '-';

		uci.load('5gmodem').then(function() {
		var storeL = (uci.get('5gmodem', 'sms', 'storage'));
		var portR = (uci.get('5gmodem', 'sms', 'readport'));
		var _mv = uci.get('5gmodem', 'sms', 'mergesms');
		var smsM = (_mv == null || _mv === '') ? '1' : (_mv == '1' ? '1' : '0');
		var algo = (uci.get('5gmodem', 'sms', 'algorithm'));
		var hide = (uci.get('5gmodem', 'sms', 'bnumber'));
		var ledn = (uci.get('5gmodem', 'sms', 'lednotify'));
		var ledt = (uci.get('5gmodem', 'sms', 'ledtype'));
		var direct = (uci.get('5gmodem', 'sms', 'direction'));

		if (!portR && !isHilinkModem() && uci.get('5gmodem', 'sms', 'sms_via_mm') != '1' && !window._smsPortNagged && (window._smsPortNagged = true)) {
 			ui.addNotification(null, E('p', _('The package requires user configuration. <br /><br /><b>The following need to be set:</b> <ol><li>All ports for communication with the modem.</li><li>Additional options specific to the given modem (for handling USSD codes).</li><li>Notification LED (optional).</li></ol>')), 'info');
		}
		
		var led = uci.get('5gmodem', 'sms', 'smsled');

		var simRadio = document.querySelector('input[name="filter_area"][value="sim"]');
		var memRadio = document.querySelector('input[name="filter_area"][value="memory"]');
		if (storeL == "SM" && simRadio) simRadio.checked = true;
		if (storeL == "ME" && memRadio) memRadio.checked = true;
		if (ledn == "1")
			{
				switch (ledt) {
  					case 'S':
    						L.resolveDefault(fs.exec_direct('/etc/init.d/led', [ 'restart' ]), null);
    						break;
  					case 'D':
    						if (led) { L.resolveDefault(fs.write('/sys/class/leds/'+led+'/brightness', '0'), null); }
    						break;
  					default:
					}
			}

		function showLoading() { smsSetState('loading'); }

		function hideLoading() {
			var l = document.getElementById('smsList');
			var ph = l ? l.querySelector('#smsEmpty') : null;
			if (ph && ph.getAttribute('data-state') === 'error') { return; }
			smsNote(null);
			if (l && !l.firstChild) { smsSetState('empty'); }
		}

		function doRefresh(updateCount, busy) {
			if (busy) { showLoading(); window._smsForceRender = true; }
			var p = doRefreshInner(updateCount);
			if (!p || typeof p.then != 'function') { hideLoading(); return Promise.resolve(); }
			return p.then(function(r) { hideLoading(); return r; },
			              function(e) { hideLoading(); throw e; });
		}

		function doRefreshInner(updateCount) {
		var storeL = uci.get('5gmodem', 'sms', 'storage') || 'ME';
		var portR = uci.get('5gmodem', 'sms', 'readport');
		if (!portR && !isHilinkModem() && uci.get('5gmodem', 'sms', 'sms_via_mm') != '1') {
			if (!window._smsPortNagged) {
				window._smsPortNagged = true;
				ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			}
			return Promise.resolve();
		}
		return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
				.then(function(res) {
					if (res) {
							var _st = sms_parse_status(res);
							var t = _st.t, u = _st.u;

							if (u != null) { msg_bar(Math.floor(u), t); }

						return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'recv' , storeL , portR ]))
							.then(function(res2) {
								if (res2) {

 									var table = document.getElementById('smsList');
									if (!table) { hideLoading(); return; }

									res2 = res2.replace(/\\u([0-9a-fA-F]{2})f{6}([0-9a-fA-F]{2})/g, '\\u$1$2');

									res2 = res2.replace(/[\u0000-\u001F]+/g, ' ');

									var json;
									try {
										var parsed = JSON.parse(res2);
										json = parsed.msg || [];
										sms_keys_apply(json, parsed.keys);
									} catch (e) {
										smsSetState('error');
										return;
									}
									if (!json.length && u > 0 && document.querySelector('#smsList .sms-card')) { return; }
									var _sig = [ storeL, portR, smsM, hide, direct, algo, res2 ].join('\u0001');
									if (!window._smsForceRender && _sig === window._smsLastSig
									    && document.querySelector('#smsList .sms-card')) { return; }
									window._smsForceRender = false;
									window._smsLastSig = _sig;
									table = smsSetState('list');
									if (!table) { return; }

									json.forEach(function(o) {
										if (o && typeof o.content === 'string') {
											o.content = o.content.replace(/\uFFFD/g, ' ');
										}
										if (o && typeof o.sender === 'string') {
											o.sender = o.sender.replace(/\s+$/, '');
										}
									});

									var aidx = [];

									if (smsM != "1" &&
									    uci.get('5gmodem', 'sms', 'mergesms_auto') != '1' &&
									    json.some(function(o) { return (o.total || 0) > 1; })) {
										smsM = "1";
										sms_persist({ 'mergesms': '1', 'mergesms_auto': '1' });
										ui.addNotification(null, E('p',
											_('Multipart messages found - merging enabled automatically. You can turn it off in SMS settings.')), 'info');
									}

									if (smsM == "1") {

											var groups = {};
											json.forEach(function(o) {
												var key = (o.reference != null && o.total > 1)
													? o.sender + '#ref#' + o.reference + '#' + o.total
													: o.sender + '#one#' + o.timestamp + '#' + o.index;
												(groups[key] = groups[key] || []).push(o);
											});
											var result = Object.keys(groups).map(function(k) {
												var parts = groups[k].sort(function(a, b) { return (a.part || 0) - (b.part || 0); });
												var byPart = {}, dedup = [];
												parts.forEach(function(p) {
													var pn = (p.part == null) ? ('i' + p.index) : String(p.part);
													var prev = byPart[pn];
													if (prev === undefined) { byPart[pn] = dedup.push(p) - 1; return; }
													if (String(p.timestamp || '') >= String(dedup[prev].timestamp || '')) {
														dedup[prev] = p;
													}
												});
												parts = dedup;
												var first = parts[0];
												var text = parts.map(function(p) { return p.content; }).join('');
												var want = first.total || 0;
												if (want > 1 && parts.length < want) {
													text += ' [' + parts.length + '/' + want + ']';
												}
												var pkeys = [], pkp = [];
												groups[k].forEach(function(p) {
													var pk = sms_msg_key(p), po = sms_msg_old(p);
													if (pkeys.indexOf(pk) < 0) { pkeys.push(pk); }
													if (!pkp.some(function(x) { return x[0] === pk && x[1] === po; })) {
														pkp.push([ pk, po ]);
													}
												});
												return {
													sender: first.sender,
													timestamp: first.timestamp,
													tz: first.tz,
													total: first.total,
													index: parts.map(function(p) { return p.index; }).join('-'),
													content: text,
													keys: pkeys,
													kp: pkp
												};
											});
											result.forEach(function(o) { o._ts = sms_ts_num(o.timestamp); });
											result.sort(function(a, b) { return b._ts - a._ts; });
											result.forEach(function(o) { delete o._ts; });
													if (true) {
															var Lres = mutil.icon('icons/5gmodem/cmessage.svg');

															for (var i = 0; i < result.length; i++) {
																table.appendChild(sms_make_card(result[i], Lres, hide));
																aidx.push(result[i].index+'-');
															}
															smsRestoreSelection();
															sms_seen_sync(result);
															sms_update_newcount();
															sms_update_selcount();
															sms_cache_save(result, u, t);

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															if (updateCount && u != null) format_with_modem_index(axx).then(function(formattedIndex) {
																update_sms_count_for_modem(u).then(function(updatedCount) {
																	sms_persist({ 'sms_count_index': formattedIndex, 'sms_count': updatedCount });
																});
															});
											}

										}
									}

									if (smsM == "0") {
									
										json.forEach(function(o) { o._ts = sms_ts_num(o.timestamp); });
										var sortedData = json.sort(function(a, b) {
											if (a._ts !== b._ts) { return b._ts - a._ts; }
											var sa = String(a.sender || ''), sb = String(b.sender || '');
											if (sa !== sb) { return sa < sb ? -1 : 1; }
											return (a.part || 0) - (b.part || 0);
										});
										json.forEach(function(o) { delete o._ts; });

										if (true) {

											var Lres = mutil.icon('icons/5gmodem/cmessage.svg');

											for (var i = 0; i < sortedData.length; i++) {
												table.appendChild(sms_make_card(sortedData[i], Lres, hide));
												aidx.push(sortedData[i].index+'-');
											}
											smsRestoreSelection();
											sms_seen_sync(sortedData);
											sms_update_newcount();
											sms_update_selcount();
											sms_cache_save(sortedData, u, t);
											
											var axx = aidx.toString();
											axx = axx.replace(/,/g, ' ');
											axx = axx.replace(/-/g, ' ');

											if (updateCount && u != null) format_with_modem_index(axx).then(function(formattedIndex) {
												update_sms_count_for_modem(u).then(function(updatedCount) {
													sms_persist({ 'sms_count_index': formattedIndex, 'sms_count': updatedCount });
												});
											});
									}

								}
						});

				} else {
				}

			if (document.getElementById('msg') && typeof u !== 'undefined') {
				msg_bar(Math.floor(u), t);
			    }
    		});
		}
		function warmRender() {
			var c = sms_cache_load();
			var table = document.getElementById('smsList');
			if (!c || !c.list || !c.list.length || !table) { return; }
			if (table.querySelector('.sms-card')) { return; }
			table = smsSetState('list') || table;
			var Lres = mutil.icon('icons/5gmodem/cmessage.svg');
			for (var i = 0; i < c.list.length; i++) {
				table.appendChild(sms_make_card(c.list[i], Lres, hide));
			}
			smsRestoreSelection();
			sms_seen_sync(c.list);
			sms_update_newcount();
			sms_update_selcount();
			if (document.getElementById('msg') && c.u != null) { msg_bar(Math.floor(c.u), c.t); }
		}
		(function waitTable(n) {
			if (document.getElementById('smsList')) { warmRender(); doRefresh(true, true); return; }
			if (n > 50) { return; }
			window.setTimeout(function() { waitTable(n + 1); }, 100);
		}(0));
		poll.add(function() { return doRefresh(false); }, 15);
		self._doRefresh = doRefresh;
		});

		var actions = E('div', { 'class': 'sms-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, [ _('Refresh') ]),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'forward',
						'style': 'display: none;',
						'click': ui.createHandlerFn(this, 'handleForward')
					}, [ _('Forward SMS') ]),
					E('span', { 'id': 'sms-newcount', 'class': 'sms-newcount', 'style': 'display: none;' }, ''),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'sms-markread',
						'style': 'display: none;',
						'click': function() { sms_mark_all_read(); }
					}, [ _('Mark read') ]),
					E('span', { 'id': 'sms-selcount', 'class': 'sms-selcount' }, ''),
					E('button', {
						'class': 'cbi-button cbi-button-remove sms-act-del',
						'id': 'execute',
						'style': 'display: none;',
						'click': ui.createHandlerFn(this, 'handleDelete')
					}, [ _('Delete') ])
		]);

		var v = E('div', { 'class': 'cbi-section tgpage' }, [

			E('table', { 'class': 'table', 'id': 'sms-info-table' }, [
				(function() {
					var sections = uci.sections('defmodems', 'defmodems');
					var serialModems = [];
					
					if (sections && sections.length > 0) {
						serialModems = sections.filter(function(s) {
							return s.modemdata === 'serial';
						});
					}
					
					if (serialModems.length > 0) {
						var currentPort = uci.get('5gmodem', 'sms', 'readport');
						var currentModem = serialModems.find(function(s) {
							return s.comm_port === currentPort;
						});
						
						if (!currentModem) currentModem = serialModems[0];
						
						var label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
						
						var buttonsDisabled = (serialModems.length > 1) ? null : true;
						
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', 'width': '33%' }, [ _('Select modem') ]),
							E('td', { 'class': 'td' }, [
								E('div', { 'class': 'controls' }, [
									E('div', { 'class': 'pager center tg-row' }, [
										E('button', { 
											'class': 'btn cbi-button-neutral tg-col-narrow prev',
											'aria-label': _('Previous modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'disabled': buttonsDisabled
										}, [ ' ◄ ' ]),
										E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
										E('button', { 
											'class': 'btn cbi-button-neutral tg-col-narrow next',
											'aria-label': _('Next modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'disabled': buttonsDisabled
										}, [ ' ► ' ])
									])
								])
							])
						]);
					} else {
						return E('div', { 'style': 'display: none;' });
					}
				}.bind(this))(),
    				(function() {
					var viaMM = (uci.get('5gmodem', 'sms', 'sms_via_mm') == '1');
					var areaTip = _('Any change in the area from which SMS messages will be read requires refreshing the messages');
					var areaOpt = (function(value, label, checked) {
						return E('label', {
							'style': 'display:inline-flex !important;align-items:center !important;gap:6px;height:auto !important;min-height:0 !important;line-height:1.4;',
							'data-tooltip': areaTip
						}, [
							E('input', {
								'type': 'radio',
								'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
								'name': 'filter_area',
								'value': value,
								'change': ui.createHandlerFn(this, 'handleSWarea'),
								'checked': checked ? true : null
							}),
							' ',
							label
						]);
					}).bind(this);

					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'colspan': '2' }, [
							E('div', { 'class': 'sms-storage-row' }, [
								E('div', {
									'class': 'sms-storage-opts',
									'style': viaMM ? 'display: none;' : null
								}, [
									(function() {
										var _stg = uci.get('5gmodem', 'sms', 'storage') || 'ME';
										return E([], [
											areaOpt('sim', _('SIM card'), _stg === 'SM'),
											areaOpt('memory', _('Modem memory'), _stg !== 'SM')
										]);
									})()
								]),
								E('div', {
									'id': 'msg',
									'class': 'cbi-progressbar',
									'title': '-'
								}, E('div')),
								actions
							]),
							E('div', {
								'style': 'text-align:center;font-size:90%',
								'id': 'deleteinfo'
							}, [ '' ])
						])
					]);
				}.bind(this))(),
		]),

				E('div', {'id': 'forward-status', 'style': 'margin: 10px 0; display: none;'}),

			smsMasonryWatch(E('div', { 'id': 'smsList' })),
		]);

		return E([], [ v ]);
	},

	popTimeout: function(a, message, timeout, severity) {
		ui.addTimeLimitedNotification(a, message, timeout, severity);
	}
});
