'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require sms-tool-5gm.editors as editors';
'require sms-tool-5gm.smssettings as smssettings';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/

function ussdCtrlScore(s) {
	var n = 0;
	for (var i = 0; i < s.length; i++) {
		var c = s.charCodeAt(i);
		if (c === 0xFFFD || (c < 0x20 && c !== 0x0A && c !== 0x0D && c !== 0x09)) { n++; }
	}
	return n;
}

function ussdUcs2(bytes, little) {
	var s = '';
	for (var i = 0; i + 1 < bytes.length; i += 2) {
		s += String.fromCharCode(little ? (bytes[i] | (bytes[i + 1] << 8))
		                                : ((bytes[i] << 8) | bytes[i + 1]));
	}
	return s;
}

function ussdGsm7(bytes) {
	var s = '', carry = 0, bits = 0;
	for (var i = 0; i < bytes.length; i++) {
		carry |= bytes[i] << bits;
		bits += 8;
		while (bits >= 7) {
			var c = carry & 0x7F;
			carry >>= 7; bits -= 7;
			if (!(c === 0 && bits < 7 && i === bytes.length - 1)) { s += String.fromCharCode(c); }
		}
	}
	return s;
}

function ussdDecodeHex(hex, dcs) {
	hex = String(hex || '').replace(/\s+/g, '');
	if (!hex.length || (hex.length % 2) || !/^[0-9A-Fa-f]+$/.test(hex)) { return null; }
	var b = [];
	for (var i = 0; i < hex.length; i += 2) { b.push(parseInt(hex.substr(i, 2), 16)); }

	var evenLen = (b.length % 2) === 0;
	var hiEven = 0, hiOdd = 0;
	for (var i = 0; i < b.length; i++) {
		if (b[i] <= 0x07) { if (i % 2) { hiOdd++; } else { hiEven++; } }
	}
	var half = b.length / 2;
	var little = hiOdd > hiEven;
	var ucs2ByDcs = (dcs != null) && ((dcs & 0x0C) === 0x08);
	var gsm7ByDcs = (dcs != null) && ((dcs & 0x0C) !== 0x08);
	var ucs2ByShape = evenLen && (Math.max(hiEven, hiOdd) >= Math.ceil(half * 0.8));

	if (evenLen && (ucs2ByDcs || (dcs == null && ucs2ByShape))) {
		return ussdUcs2(b, little);
	}
	if (gsm7ByDcs) {
		var g = ussdGsm7(b);
		var a = String.fromCharCode.apply(null, b);
		return (ussdCtrlScore(g) <= ussdCtrlScore(a)) ? g : a;
	}
	return String.fromCharCode.apply(null, b);
}

function ussdReadReply(stdout) {
	var txt = String(stdout || '');
	var m = txt.match(/\+CUSD:\s*(\d+)\s*,\s*"([^"]*)"\s*,\s*(\d+)/);
	if (m) {
		var d = ussdDecodeHex(m[2], parseInt(m[3], 10));
		return (d != null) ? d : m[2];
	}
	var only = txt.replace(/^\s*debug:.*$/gm, '').replace(/\s+/g, '');
	if (only.length >= 8 && !(only.length % 2) && /^[0-9A-Fa-f]+$/.test(only)) {
		var d = ussdDecodeHex(only, null);
		if (d != null && d.length && ussdCtrlScore(d) === 0) { return d; }
	}
	return null;
}

// Page layout: header card like the Network page, the exchange with the network as a chat on the
// left, code lists on the right, USSD settings folded below. See docs/subsystems/ussd.md.
var CSS_ID = 'tg-page-ussd-css';
function loadPageCss() {
	if (document.getElementById(CSS_ID)) { return; }
	document.head.appendChild(E('link', { 'id': CSS_ID, 'rel': 'stylesheet', 'type': 'text/css',
		'href': L.resource('view/modem5g/page-ussd.css') }));
}

var ICONS = {
	hash: '<path d="M5 9h14M5 15h14M10 4 8 20M16 4l-2 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>',
	send: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4Z"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	check: '<path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
	pen: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4L19 9l-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/></g>',
	warn: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5 2.5 20h19Z"/><path d="M12 10v4.5M12 17.2v.3"/></g>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size, cls) {
	var s = E('span', { 'class': cls || 'tg-ussd-i' });
	s.innerHTML = svg(name, size);
	return s;
}
function pill(kind, text, cls) {
	return E('span', { 'class': 'tg-ussd-pill ' + kind + (cls ? ' ' + cls : '') }, [ E('i'), E('span', {}, text) ]);
}
function iconButton(name, label, cls, attrs) {
	var b = E('button', Object.assign({ 'type': 'button', 'class': 'cbi-button ' + (cls || '') }, attrs || {}));
	b.innerHTML = svg(name, 15);
	if (label) { b.appendChild(E('span', {}, label)); }
	return b;
}

// collapsibleSection() of 5gdetail.js (same classes and storage key scheme) with a summary on the
// right of the title.
function collapsibleSection(key, titleText, content, summary) {
	var expanded = false;
	try { var v = localStorage.getItem('5gm-blk-' + key); if (v === '0' || v === '1') { expanded = v === '1'; } } catch (e) {}
	var chev = E('span', { 'class': 'tg-ussd-chev', 'style': 'transform:rotate(' + (expanded ? '180' : '0') + 'deg)' });
	chev.innerHTML = svg('chev', 16);
	var body = E('div', { 'class': 'tg-collapse' + (expanded ? ' open' : '') }, [ E('div', { 'class': 'tg-collapse-inner' }, content) ]);
	var toggle = function() {
		var exp = !body.classList.contains('open');
		body.classList.toggle('open', exp);
		title.style.marginBottom = exp ? '.5em' : '0';
		title.setAttribute('aria-expanded', String(exp));
		chev.style.transform = 'rotate(' + (exp ? '180' : '0') + 'deg)';
		try { localStorage.setItem('5gm-blk-' + key, exp ? '1' : '0'); } catch (e) {}
	};
	var title = E('h3', {
		'class': 'tg-ussd-coll', 'role': 'button', 'tabindex': '0', 'aria-expanded': String(expanded),
		'style': 'margin-bottom:' + (expanded ? '.5em' : '0'),
		'click': toggle,
		'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); toggle(); } }
	}, [ chev, E('span', {}, titleText), summary ? E('span', { 'class': 'tg-ussd-coll-sum' }, summary) : '' ]);
	return E('div', { 'class': 'cbi-section tginfo', 'data-blk': key }, [ title, body ]);
}

function decB64(b) {
	var r;
	try { r = b ? atob(b) : ''; } catch (e) { return ''; }
	try { return decodeURIComponent(escape(r)); } catch (e) { return r; }
}

function cleanOut(s) {
	return (s || '').replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, '');
}

function hhmm() {
	var d = new Date(), p = function(n) { return (n < 10 ? '0' : '') + n; };
	return p(d.getHours()) + ':' + p(d.getMinutes());
}

// Code file line: "Name;code" or just "code".
function parseCodes(content) {
	var out = [];
	String(content || '').trim().split('\n').forEach(function(line) {
		if (!line.trim()) { return; }
		var f = line.split(';');
		var code = String(f[1] || f[0] || '').trim();
		if (!code) { return; }
		out.push({ name: String(f[0] || '').trim() || code, code: code });
	});
	return out;
}

function codeFilePath(name) {
	return (name === '__user__') ? '/etc/5gmodem/modem/ussdcodes.user' : '/etc/5gmodem/modem/ussdcodes/' + name;
}

// Numbered items of an operator menu ("1. Balance", "2) Services"): at least two make a menu.
function menuItems(text) {
	var items = [];
	String(text || '').split('\n').forEach(function(l) {
		var m = l.match(/^\s*(\d{1,3})\s*[.):\-]\s*[^\d\s]/);
		if (m && items.indexOf(m[1]) < 0) { items.push(m[1]); }
	});
	return (items.length >= 2) ? items.slice(0, 12) : [];
}

function cmeText(n) {
	switch (n) {
	case 0: return _('Phone/Modem failure');
	case 1: return _('No connection to phone');
	case 2: return _('Phone/Modem adapter link reserved');
	case 3: return _('Operation not allowed');
	case 4: return _('Operation not supported');
	case 5: return _('PH_SIM PIN required');
	case 6: return _('PH_FSIM PIN required');
	case 7: return _('PH_FSIM PUK required');
	case 10: return _('SIM not inserted');
	case 11: return _('SIM PIN required');
	case 12: return _('SIM PUK required');
	case 13: return _('SIM failure');
	case 14: return _('SIM busy');
	case 15: return _('SIM wrong');
	case 16: return _('Incorrect password');
	case 17: return _('SIM PIN2 required');
	case 18: return _('SIM PUK2 required');
	case 20: return _('Memory full');
	case 21: return _('Invalid index');
	case 22: return _('Not found');
	case 23: return _('Memory failure');
	case 24: return _('Text string too long');
	case 25: return _('Invalid characters in text string');
	case 26: return _('Dial string too long');
	case 27: return _('Invalid characters in dial string');
	case 30: return _('No network service') + '\n' +
		_('USSD works over the circuit-switched channel. If the modem is registered in LTE only, switch it to 3G on the frequency-management page and repeat the request.');
	case 31: return _('Network timeout');
	case 32: return _('Network not allowed, emergency calls only');
	case 40: return _('Network personalization PIN required');
	case 41: return _('Network personalization PUK required');
	case 42: return _('Network subset personalization PIN required');
	case 43: return _('Network subset personalization PUK required');
	case 44: return _('Service provider personalization PIN required');
	case 45: return _('Service provider personalization PUK required');
	case 46: return _('Corporate personalization PIN required');
	case 47: return _('Corporate personalization PUK required');
	case 48: return _('PH-SIM PUK required');
	case 100: return _('Unknown error');
	case 103: return _('Illegal MS');
	case 106: return _('Illegal ME');
	case 107: return _('GPRS services not allowed');
	case 111: return _('PLMN not allowed');
	case 112: return _('Location area not allowed');
	case 113: return _('Roaming not allowed in this location area');
	case 126: return _('Operation temporary not allowed');
	case 132: return _('Service operation not supported');
	case 133: return _('Requested service option not subscribed');
	case 134: return _('Service option temporary out of order');
	case 148: return _('Unspecified GPRS error');
	case 149: return _('PDP authentication failure');
	case 150: return _('Invalid mobile class');
	case 256: return _('Operation temporarily not allowed');
	case 257: return _('Call barred');
	case 258: return _('Phone/Modem is busy');
	case 259: return _('User abort');
	case 260: return _('Invalid dial string');
	case 261: return _('SS not executed');
	case 262: return _('SIM Blocked');
	case 263: return _('Invalid block');
	case 527: return _('Please wait, and retry your selection later (Specific Modem Sierra)');
	case 528: return _('Location update failure – emergency calls only (Specific Modem Sierra)');
	case 529: return _('Selection failure – emergency calls only (Specific Modem Sierra)');
	case 772: return _('SIM powered down');
	}
	return '';
}

function typewrite(el, text, done) {
	if (el._twTimer) { clearInterval(el._twTimer); el._twTimer = null; }
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
		el.textContent = text;
		if (done) { done(); }
		return;
	}
	el.textContent = '';
	var i = 0, n = text.length;
	var step = Math.max(1, Math.ceil(n / 90));
	el._twTimer = setInterval(function() {
		if (i >= n) { clearInterval(el._twTimer); el._twTimer = null; if (done) { done(); } return; }
		el.textContent += text.slice(i, i + step);
		i += step;
	}, 28);
}

return view.extend({
	viewName: 'sendussd',

	restoreSettingsFromLocalStorage: function() {
		try {
			return localStorage.getItem('luci-app-' + this.viewName + '-selectedFile');
		} catch(e) {
			return null;
		}
	},

	saveSettingsToLocalStorage: function(fileName) {
		try {
			localStorage.setItem('luci-app-' + this.viewName + '-selectedFile', fileName);
		} catch(e) {}
	},

	/* ---------- chat ---------- */

	scrollChat: function(el) {
		var c = this._c;
		if (!c) { return; }
		var rev = c.keep.checked && c.rev.checked;
		if (rev) { c.body.scrollTop = 0; }
		else { c.body.scrollTop = c.body.scrollHeight; }
	},

	chatEmpty: function() {
		var c = this._c;
		c.body.innerHTML = '';
		c.body.appendChild(E('div', { 'class': 'tg-ussd-empty' }, _('Pick a code from the list or type one below.')));
	},

	startExchange: function(code) {
		var self = this, c = this._c;
		var keep = c.keep.checked, rev = keep && c.rev.checked;
		if (!keep) { c.body.innerHTML = ''; }
		var empty = c.body.querySelector('.tg-ussd-empty');
		if (empty) { empty.remove(); }
		c.body.querySelectorAll('.tg-ussd-menu').forEach(function(m) { m.remove(); });

		var stages = E('div', { 'class': 'tg-ussd-stages' });
		var x = E('div', { 'class': 'tg-ussd-x' }, [ E('div', { 'class': 'tg-ussd-req' }, [ code ]), stages ]);
		if (rev && c.body.firstChild) { c.body.insertBefore(x, c.body.firstChild); }
		else { c.body.appendChild(x); }

		var ex = { cur: null, count: 0, meta: null };
		var markDone = function(row) {
			row.classList.add('done');
			var sp = row.querySelector('.tg-ussd-spin');
			if (sp) { sp.replaceWith(icon('check', 15)); }
		};
		ex.stage = function(text) {
			if (ex.cur && ex.cur._t === text) { return; }
			if (ex.cur) { markDone(ex.cur); }
			var row = E('div', { 'class': 'tg-ussd-stage' }, [ E('span', { 'class': 'tg-ussd-spin' }), E('span', {}, text) ]);
			row._t = text;
			stages.appendChild(row);
			ex.cur = row;
			ex.count++;
			self.scrollChat();
		};
		ex.answer = function(r) {
			if (ex.count <= 1) { stages.remove(); }
			else if (ex.cur) { markDone(ex.cur); }
			ex.cur = null;
			r = r || { text: _('No response from modem'), err: true };
			var txt = E('div', { 'class': 'tg-ussd-txt' });
			ex.meta = E('div', { 'class': 'tg-ussd-meta' }, hhmm());
			var kids = [ txt ];
			if (r.raw) { kids.push(E('div', { 'class': 'tg-ussd-raw' }, [ r.raw ])); }
			if (r.sms) {
				kids.push(E('div', { 'class': 'tg-ussd-meta' }, E('a', {
					'href': L.url('admin', 'modem', '5gmodem', 'readsms') }, _('Inbox') + ' →')));
			}
			kids.push(ex.meta);
			x.appendChild(E('div', { 'class': 'tg-ussd-ans' + (r.err ? ' err' : '') }, kids));
			var items = r.err ? [] : menuItems(r.text);
			typewrite(txt, r.text, function() {
				if (items.length && x.parentNode) {
					x.appendChild(E('div', { 'class': 'tg-ussd-menu' }, items.map(function(n) {
						return E('button', { 'type': 'button', 'class': 'cbi-button', 'click': function() { self.sendReply(n); } }, n);
					})));
				}
				self.scrollChat();
			});
			self.scrollChat();
		};
		ex.waiting = function() {
			if (ex.meta) { ex.meta.textContent = hhmm() + ' · ' + _('waiting for a reply'); }
		};
		self.scrollChat();
		return ex;
	},

	setSession: function(on) {
		this.ussdSessionActive = !!on;
		if (this._c) { this._c.sess.style.display = on ? '' : 'none'; }
	},

	setBusy: function(on) {
		this._busy = !!on;
		var c = this._c;
		if (!c) { return; }
		c.send.disabled = !!on;
		c.root.querySelectorAll('.tg-ussd-menu .cbi-button').forEach(function(b) { b.disabled = !!on; });
	},

	sendReply: function(n) {
		if (this._busy || !this._c) { return; }
		this._c.input.value = n;
		return this.handleGo();
	},

	// stdout/stderr of sms_tool or mmcli -> what the chat shows.
	formatReply: function(exec, res) {
		var out = cleanOut(res && res.stdout), err = cleanOut(res && res.stderr);

		if (exec == 'mmcli' || exec == '/usr/bin/mmcli') {
			var mm = out.match(/(?:reply|request) from network:\s*'([\s\S]+)'/) ||
				out.match(/(?:reply from network|response)[^']*'([\s\S]+)'/) ||
				out.match(/'([\s\S]+)'/);
			if (mm && mm[1]) {
				out = mm[1];
				err = '';
			}
		}

		if (exec == 'sms_tool' && uci.get('5gmodem', 'sms', 'pdu') != '1') {
			var dec = ussdReadReply(out);
			if (dec != null && dec.trim())
				out = dec;
			else
				out = out.replace(/^\s*debug:.*$/gm, '').trim();
		}

		if (out.includes('undefined') || err.includes('undefined')) {
			return { text: _('No response from modem'), err: true };
		}
		if (err.length > 2) {
			var friendly = '', sms = false;
			if (err.includes('USSD terminated by network')) {
				friendly = _('The network closed the USSD session without a text reply. Some operators send the answer by SMS: check the incoming messages.');
				sms = true;
			}
			var m = err.match(/error:\s*(\d+)/);
			if (m && cmeText(+m[1])) { friendly = cmeText(+m[1]); sms = false; }
			if (friendly) { return { text: friendly, err: true, raw: err, sms: sms }; }
			if (out.trim()) { return { text: out, err: false, raw: err }; }
			return { text: err, err: true };
		}
		if (!out.trim()) { return { text: _('No response from modem'), err: true }; }
		return { text: out, err: false };
	},

	handleUssdScript: function(code, ex) {
		var self = this;
		var STAGES = {
			starting: _('Preparing the request…'),
			switching: _('Switching the modem to 3G - USSD needs the circuit-switched channel'),
			sending:   _('Sending the request'),
			retrying:  _('The network dropped the request, trying again'),
			restoring: _('Restoring the previous network mode')
		};

		self.setBusy(true);
		ex.stage(STAGES.starting);

		return fs.exec('/usr/share/5gmodem/ussd.sh', [ 'send', code ]).then(function(r) {
			var j = {};
			try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			if (j.error) {
				self.setBusy(false);
				ex.answer({ text: _('The request was rejected: %s').format(String(j.error)), err: true });
				return null;
			}
			return new Promise(function(resolve) {
				var left = 60, timer = null;
				var inflight = false;
				var tick = function() {
					if (inflight) { return; }
					inflight = true;
					L.resolveDefault(fs.exec('/usr/share/5gmodem/ussd.sh', [ 'status' ]), {}).then(function(r) {
						inflight = false;
						var st = {};
						try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
						if (st.status === 'running' || !st.status) {
							if (STAGES[st.stage]) { ex.stage(STAGES[st.stage]); }
							if (--left > 0) { return; }
						}
						if (timer) { clearInterval(timer); timer = null; }
						self._ussdTimer = null;
						resolve(st);
					});
				};
				timer = setInterval(tick, 2000);
				self._ussdTimer = timer;
				tick();
			});
		}).then(function(st) {
			if (!st) { return; }
			self.setBusy(false);
			if (st.status === 'done') {
				var body = decB64(st.out);
				if (!body.trim()) {
					if (st.unsupported) {
						ex.answer({ text: _('This modem does not answer USSD requests: its firmware has no SS support. Verified on real hardware.'), err: true });
						return;
					}
					if (st.noswitch === 'not_active') {
						ex.answer({ text: _('No reply. The request went to a modem that is not the active one, so it was not switched to 3G - and USSD needs the circuit-switched channel. Select this modem and repeat.'), err: true });
						return;
					}
				}
				ex.answer(self.formatReply('sms_tool', { stdout: body, stderr: decB64(st.err) }));
				return;
			}
			ex.answer({ text: (st.status === 'error' && st.reason === 'no_3g')
				? _('Could not switch the modem to 3G, so the request was not sent: USSD needs the circuit-switched channel.')
				: _('No response from modem'), err: true });
		}).catch(function(err) {
			self.setBusy(false);
			ex.answer({ text: String(err), err: true });
		});
	},

	handleFileChange: function(fileName) {
		var self = this;
		if (!fileName) { return; }
		this.saveSettingsToLocalStorage(fileName);
		this.paintSeg(fileName);
		return fs.read_direct(codeFilePath(fileName)).then(function(content) {
			self.fillCodes(parseCodes(content));
		}).catch(function(err) {
			self.fillCodes([]);
			ui.addNotification(null, E('p', [ _('Error loading USSD codes file:') + ' ' + fileName ]), 'error');
		});
	},

	paintSeg: function(fileName) {
		if (!this._c || !this._c.seg) { return; }
		this._c.seg.querySelectorAll('button').forEach(function(b) {
			var on = b.getAttribute('data-file') === fileName;
			b.classList.toggle('on', on);
			b.setAttribute('aria-pressed', String(on));
		});
	},

	fillCodes: function(list) {
		var self = this, host = this._c && this._c.codes;
		if (!host) { return; }
		host.innerHTML = '';
		if (!list.length) {
			host.appendChild(E('div', { 'class': 'tg-ussd-none' }, _('No USSD codes available')));
			return;
		}
		list.forEach(function(it) {
			host.appendChild(E('div', {
				'class': 'tg-ussd-code', 'role': 'button', 'tabindex': '0', 'title': it.code,
				'click': function() { self.handleCopy(it.code); },
				'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); self.handleCopy(it.code); } }
			}, [ E('span', {}, [ it.name ]), E('code', {}, [ it.code ]) ]));
		});
	},

	handleCopy: function(code) {
		var ov = document.getElementById('cmdvalue');
		if (!ov) { return; }
		ov.value = String(code || '');
		ov.focus();
	},

	getMMModemNumber: function() {
		return fs.exec('/usr/bin/mmcli', [ '--timeout=8', '-L' ]).then(function(res) {
			let out = ((res.stdout || '') + '\n' + (res.stderr || '')).trim();
			let ids = [], re = /\/Modem\/(\d+)/g, mm;
			while ((mm = re.exec(out)) !== null) { ids.push(mm[1]); }
			if (!ids.length)
				return Promise.reject(_('No modems found by ModemManager (mmcli -L)'));
			if (ids.length === 1)
				return ids[0];
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), {}).then(function(ar) {
				var act = ((ar && ar.stdout) || '').trim();
				if (ids.indexOf(act) >= 0)
					return act;
				var rank = { connected: 4, registered: 3, searching: 2, enabled: 1 };
				return Promise.all(ids.map(function(id) {
					return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', id, '--timeout=8', '-K' ]), {}).then(function(r) {
						var s = (((r && r.stdout) || '').match(/generic\.state\s*:\s*(\S+)/) || [])[1] || '';
						return { id: id, r: (rank[s] || 0) };
					});
				})).then(function(list) {
					list.sort(function(a, b) { return b.r - a.r; });
					return list[0].id;
				});
			});
		});
	},

	getProxyModemNumber: function() {
		var ready = { enabled: 1, searching: 1, registered: 1, connecting: 1, connected: 1, disconnecting: 1 };
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), {}).then(function(res) {
			var id = ((res && res.stdout) || '').trim();
			if (!/^\d+$/.test(id))
				return null;
			return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', id, '--timeout=8', '-K' ]), {}).then(function(r) {
				var s = (((r && r.stdout) || '').match(/generic\.state\s*:\s*(\S+)/) || [])[1] || '';
				return ready[s] ? id : null;
			});
		});
	},

	mmUssd: function(modemNum, mode, code) {
		var self = this;
		return fs.exec('/usr/share/5gmodem/ussd.sh', [ 'mm', modemNum, mode, code ]).then(function(r) {
			var j = {};
			try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			if (j.error)
				return { stdout: '', stderr: _('The request was rejected: %s').format(String(j.error)) };
			return new Promise(function(resolve) {
				var left = 60, inflight = false, timer = null;
				var tick = function() {
					if (inflight) { return; }
					inflight = true;
					L.resolveDefault(fs.exec('/usr/share/5gmodem/ussd.sh', [ 'status' ]), {}).then(function(r) {
						inflight = false;
						var st = {};
						try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
						if (st.status === 'running' && --left > 0) { return; }
						if (timer) { clearInterval(timer); timer = null; }
						self._ussdTimer = null;
						resolve(st.status === 'done' ? { stdout: decB64(st.out), stderr: decB64(st.err) } : { stdout: '', stderr: '' });
					});
				};
				timer = setInterval(tick, 2000);
				self._ussdTimer = timer;
				tick();
			});
		});
	},

	// Transport of the active modem: the ModemManager path when ussd_via_mm is set and the active
	// interface is managed by ModemManager (or by a shared proxy), otherwise the AT path.
	ussdTransport: function() {
		var amp = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		var ams = 'm_' + amp.replace(/[^A-Za-z0-9]/g, '_');
		var port = uci.get('5gmodem', ams, 'ussd_port') || uci.get('5gmodem', 'sms', 'ussdport');
		var mm = uci.get('5gmodem', 'sms', 'ussd_via_mm') == '1';
		var proxy = false;
		if (mm) {
			var amif = uci.get('5gmodem', ams, 'network') || uci.get('5gmodem', '@5gmodem[0]', 'network');
			var ampr = amif ? uci.get('network', amif, 'proto') : null;
			if (mutil.isSharedProxyProto(ampr)) { proxy = true; }
			else if (amif && !mutil.isMMProto(ampr)) { mm = false; }
		}
		return { port: port, mm: mm, proxy: proxy, section: ams };
	},

	handleGo: function(ev) {
		var self = this;
		if (this._busy) { return false; }
		var input = document.getElementById('cmdvalue');
		var ussd = String((input && input.value) || '').trim();
		var tp = this.ussdTransport();
		var keep = this._c && this._c.keep.checked;

		if (ussd.length < 1) {
			ui.addNotification(null, E('p', _('Please specify the code to send')), 'info');
			return false;
		}
		var begin = function() {
			if (keep && input) { input.value = ''; input.focus(); }
			return self.startExchange(ussd);
		};

		if (tp.mm) {
			self.setBusy(true);
			return (tp.proxy ? this.getProxyModemNumber() : this.getMMModemNumber())
				.then(function(modemNum) {
					if (modemNum == null) {
						self.setBusy(false);
						if (!tp.port) {
							ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
							return false;
						}
						return self.handleUssdScript(ussd, begin());
					}
					var ex = begin();
					ex.stage(_('Sending the request'));
					var mode = self.ussdSessionActive ? 'respond' : 'initiate';
					return (!self.ussdSessionActive
							? L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', modemNum, '--timeout=10', '--3gpp-ussd-cancel' ]), {})
							: Promise.resolve())
						.then(function() { return self.mmUssd(String(modemNum), mode, ussd); })
						.then(function(res) {
							self._ussdFailed = !!(res && res.stderr && !res.stdout);
							ex.answer(self.formatReply('/usr/bin/mmcli', res));
							return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', modemNum, '--timeout=10', '--3gpp-ussd-status' ]), {});
						})
						.then(function(r) {
							self.ussdModemNum = modemNum;
							self.setSession(!self._ussdFailed && /status:\s*(?:user-response|active)/.test((r && r.stdout) || ''));
							if (self.ussdSessionActive) { ex.waiting(); }
						})
						.catch(function(err) {
							ex.answer({ text: String(err), err: true });
						})
						.finally(function() { self.setBusy(false); });
				})
				.catch(function(err) {
					self.setBusy(false);
					ui.addNotification(null, E('p', [ _('Failed to detect modem:') + ' ' + String(err) ]), 'danger');
				});
		}

		if (!tp.port) {
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
		}

		return this.handleUssdScript(ussd, begin());
	},

	handleClear: function(ev) {
		if (this._c) { this.chatEmpty(); }
		var ov = document.getElementById('cmdvalue');
		if (ov) { ov.value = ''; }

		if (this.ussdSessionActive && this.ussdModemNum != null) {
			L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', this.ussdModemNum, '--timeout=8', '--3gpp-ussd-cancel' ]));
		}
		this.setSession(false);
		if (ov) { ov.focus(); }
	},

	handleHistoryToggle: function(ev) {
		var rev = document.getElementById('reverse-replies');
		if (!rev) { return; }
		if (ev.target.checked) {
			rev.disabled = false;
		} else {
			rev.disabled = true;
			rev.checked = false;
		}
	},

	handleModemChange: function(ev) {
		let sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;

		let serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});

		if (serialModems.length === 0) return;

		let currentPort = uci.get('5gmodem', 'sms', 'ussdport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});

		if (currentIndex === -1) currentIndex = 0;

		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];

		if (newModem && newModem.comm_port) {
			uci.set('5gmodem', 'sms', 'ussdport', newModem.comm_port);
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'smsopt', 'ussdport=' + newModem.comm_port ]), null).then(function() {
				let modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					let label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	load: function() {
		var self = this, args = arguments;
		return fresh.check(40008, [ editors, smssettings, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {

		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/ussdcodes.user'), null),
			L.resolveDefault(fs.list('/etc/5gmodem/modem/ussdcodes'), []),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('network')),
			L.resolveDefault(uci.load('defmodems')),
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ussdsupport' ]), null)
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();
		loadPageCss();
		var self = this;
		var main = this.renderMain(loadResults);
		// The settings block is drawn at once with placeholders; the form (it loads port lists from
		// the router) goes in when ready, so it never holds the page back. The panel is a <details>
		// around the settings form; the form goes into a folding block like on the Network page.
		var tp = self.ussdTransport();
		var on3g = uci.get('5gmodem', tp.section, 'ussd_3g') || uci.get('5gmodem', 'sms', 'ussd_3g');
		var sum = [ '3G: ' + ((on3g == '1') ? _('on') : _('off')) ];
		if (tp.mm) { sum.push('ModemManager'); }
		var holder = E('div', {}, [ E('span', { 'class': 'tg-skel blk', 'style': 'width:60%;margin:10px 0' }),
			E('span', { 'class': 'tg-skel blk', 'style': 'width:40%;margin:10px 0' }) ]);
		var sec = collapsibleSection('ussdset', _('USSD settings'), [ holder ], sum.join(' · '));
		main.appendChild(sec);
		smssettings.panel('ussd').then(function(panel) {
			var form = (panel && panel.tagName === 'DETAILS') ? panel.lastElementChild : panel;
			if (form && form.nodeType === 1) {
				while (holder.firstChild) { holder.removeChild(holder.firstChild); }
				holder.appendChild(form);
			} else if (sec.parentNode) { sec.parentNode.removeChild(sec); }
		}, function() { if (sec.parentNode) { sec.parentNode.removeChild(sec); } });
		return main;
	},

	renderHead: function(st, tp) {
		var model = String(st.model || '');
		var rat = String(st.rat || '').split('|')[0].trim();
		var notSupported = (String(st.supported) === '0');
		var noAtPort = notSupported && st.reason === 'no_at_port';
		var smsOnly = !notSupported && (String(st.sms_only) === '1');
		var csfb = !notSupported && !smsOnly && /^(LTE|5G)/i.test(rat);
		var via3g = (uci.get('5gmodem', tp.section, 'ussd_3g') == '1');

		var kind = 'ok', pillText = _('USSD works'), main = _('Ready to send USSD codes'), loc = '', isub = rat, alert = '';
		if (noAtPort) {
			kind = 'warn'; pillText = _('USSD unavailable'); main = _('Modem AT port not found'); isub = '!';
		} else if (notSupported) {
			kind = 'warn'; pillText = _('USSD unavailable'); isub = '!';
			main = _('The modem does not answer USSD');
			loc = _('The request can be sent, but most likely there will be no reply.');
			alert = _('USSD does not work on this modem: it is a data-only module without SS support in the firmware. Verified on real hardware - the modem does not answer USSD requests at all.');
		} else if (smsOnly) {
			kind = 'warn'; pillText = _('SMS only'); isub = '!';
			main = _('The network registered this SIM for SMS only');
			alert = _('The network registered this SIM for SMS only, so USSD is unavailable right now: it is a voice-domain service. The modem itself supports USSD - requests will simply stay unanswered until the registration changes.');
		} else if (csfb && via3g) {
			pillText = rat + ' · ' + _('via 3G');
			main = _('The request goes through 3G and returns to %s').format(rat);
			loc = _('The modem is registered in %s now, and USSD runs over the circuit-switched channel. The request will therefore switch the modem to 3G and switch it back - the connection drops for about twenty seconds.').format(rat);
		} else if (csfb) {
			pillText = rat;
			main = _('The modem is in %s: USSD needs the voice channel').format(rat);
			loc = _('The modem is registered in %s now, and USSD runs over the circuit-switched channel, which LTE does not have. Many modems still answer; if this one stays silent, enable "Switch the modem to 3G for USSD" in the settings below.').format(rat);
		}

		var badge = tp.mm ? 'ModemManager' : ('sms_tool' + (tp.port ? ' · ' + tp.port : ''));
		var ico = E('div', { 'class': 'tginfo-signal tg-ussd-ico' + (kind === 'warn' ? ' warn' : '') });
		ico.innerHTML = svg('hash', 36);
		ico.appendChild(E('medium', {}, isub || 'USSD'));


		var head = E('div', { 'class': 'cbi-section tg-pg-head tg-ussd-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-ussd-title' }, [
				E('span', {}, 'USSD'),
				E('span', { 'class': 'tg-proto-badge' }, badge),
				pill(kind, pillText, 'tg-ussd-pillm')
			]),
			E('div', { 'class': 'tginfo-general' }, [
				ico,
				E('div', { 'class': 'tginfo-status' }, [
					model ? E('div', { 'class': 'tginfo-reg' }, _('Modem') + ' ' + model) : '',
					E('div', { 'class': 'tginfo-op tg-ussd-main' }, main),
					loc ? E('div', { 'class': 'tginfo-loc' }, loc) : ''
				]),
				E('div', { 'class': 'tginfo-right' }, [ pill(kind, pillText) ])
			])
		]);
		return { head: head, alert: alert ? E('div', { 'class': 'alert-message warning tg-ussd-alert' }, [
			icon('warn', 17), E('div', {}, alert) ]) : '' };
	},

	renderModemPager: function() {
		let sections = uci.sections('defmodems', 'defmodems') || [];
		let serialModems = sections.filter(function(s) { return s.modemdata === 'serial'; });
		if (!serialModems.length) { return ''; }
		let currentPort = uci.get('5gmodem', 'sms', 'ussdport');
		let currentModem = serialModems.find(function(s) { return s.comm_port === currentPort; }) || serialModems[0];
		let label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
		let buttonsDisabled = (serialModems.length > 1) ? null : true;
		return E('div', { 'class': 'tg-ussd-pager' }, [
			E('span', { 'class': 'tg-ussd-lbl' }, _('Select modem')),
			E('div', { 'class': 'pager center tg-row' }, [
				E('button', { 'class': 'btn cbi-button-neutral tg-col-narrow prev', 'aria-label': _('Previous modem'),
					'click': ui.createHandlerFn(this, 'handleModemChange'), 'disabled': buttonsDisabled }, [ ' ◄ ' ]),
				E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
				E('button', { 'class': 'btn cbi-button-neutral tg-col-narrow next', 'aria-label': _('Next modem'),
					'click': ui.createHandlerFn(this, 'handleModemChange'), 'disabled': buttonsDisabled }, [ ' ► ' ])
			])
		]);
	},

	renderMain: function (loadResults) {
		var self = this;
		var st = (function() {
			try {
				let r = loadResults && loadResults[5];
				return JSON.parse((r && (r.stdout || r)) || '{}') || {};
			} catch (e) { return {}; }
		})();
		var tp = this.ussdTransport();
		var hd = this.renderHead(st, tp);

		/* ---------- chat ---------- */
		var c = this._c = {};
		c.body = E('div', { 'class': 'tg-ussd-body', 'aria-live': 'polite' });
		c.sess = E('div', { 'class': 'tg-ussd-sess', 'style': 'display:none' }, [
			pill('acc', _('Session open')),
			E('span', {}, _('USSD session is active — type your reply and press Send'))
		]);
		c.input = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'id': 'cmdvalue',
			'inputmode': 'tel',
			'autocomplete': 'off',
			'placeholder': _('Code to send'),
			'aria-label': _('Code to send'),
			'data-tooltip': _('Press [Enter] to send the code, press [Ctrl+Delete] to clear the field'),
			'keydown': function(ev) {
				if (ev.keyCode === 13) {
					ev.preventDefault();
					self.handleGo(ev);
				}
				if (ev.keyCode === 46 && (ev.ctrlKey || ev.shiftKey)) {
					ev.preventDefault();
					c.input.value = '';
					c.input.focus();
				}
			}
		});
		c.send = iconButton('send', _('Send code'), 'cbi-button-action important', {
			'id': 'execute', 'click': function(ev) { self.handleGo(ev); } });
		var clr = iconButton('trash', '', 'cbi-button-remove tg-ussd-ico-btn', {
			'id': 'clr', 'title': _('Clear form'), 'aria-label': _('Clear form'),
			'click': function(ev) { self.handleClear(ev); } });
		c.keep = E('input', {
			'id': 'history-full', 'type': 'checkbox', 'name': 'showhistory',
			'data-tooltip': _('Check this option if you need to use the menu built on USSD codes'),
			'change': function(ev) { self.handleHistoryToggle(ev); }
		});
		c.rev = E('input', {
			'id': 'reverse-replies', 'type': 'checkbox', 'name': 'reversereplies',
			'data-tooltip': _('View new reply from top'), 'disabled': true
		});
		var chat = E('div', { 'class': 'cbi-section tg-ussd-chat' }, [
			c.body,
			c.sess,
			E('div', { 'class': 'tg-ussd-in' }, [ c.input, c.send, clr ]),
			E('div', { 'class': 'tg-ussd-opts' }, [
				E('label', {}, [ c.keep, E('span', {}, _('Keep the previous reply when sending a new USSD')) ]),
				E('label', {}, [ c.rev, E('span', {}, _('Newest replies first')) ])
			])
		]);
		this.chatEmpty();

		/* ---------- code lists ---------- */
		var files = (loadResults[1] || []).filter(function(f) {
			return f.type === 'file' && f.name && /\.user$/.test(f.name);
		}).map(function(f) { return f.name; });
		var userContent = loadResults[0];
		if (userContent && String(userContent).trim()) { files.push('__user__'); }

		c.codes = E('div', { 'class': 'tg-ussd-codes' });
		c.seg = null;
		var start = null;
		if (files.length) {
			var saved = this.restoreSettingsFromLocalStorage();
			start = (saved && files.indexOf(saved) >= 0) ? saved : files[0];
			if (files.length > 1) {
				c.seg = E('div', { 'class': 'tg-ussd-seg', 'role': 'group', 'aria-label': _('Defined USSD code files') },
					files.map(function(name) {
						return E('button', {
							'type': 'button', 'data-file': name,
							'title': _('Select file with USSD codes to load'),
							'click': function() { self.handleFileChange(name); }
						}, (name === '__user__') ? _('My codes') : name.replace(/\.user$/, '').toUpperCase());
					}));
			}
		}
		var codesSec = E('div', { 'class': 'cbi-section tg-ussd-codesec' }, [
			E('h3', {}, _('USSD codes')),
			this.renderModemPager(),
			c.seg || '',
			c.codes,
			E('div', { 'class': 'tg-ussd-actions' }, [
				iconButton('pen', _('USSD templates'), '', { 'click': function() {
					new editors.ussdCodesManagerDialog(_('USSD templates')).show();
				} })
			])
		]);
		if (start) {
			this.paintSeg(start);
			c.codes.appendChild(E('div', { 'class': 'tg-ussd-none' }, E('span', { 'class': 'tg-ussd-spin' })));
			L.resolveDefault(fs.read_direct(codeFilePath(start)), '').then(function(content) {
				self.fillCodes(parseCodes(content));
			});
		} else {
			this.fillCodes([]);
		}

		c.root = E('div', { 'class': 'tg-ussd' }, [
			hd.head,
			hd.alert,
			E('div', { 'class': 'tg-ussd-grid' }, [ chat, E('div', { 'class': 'tg-ussd-side' }, [ codesSec ]) ])
		]);
		return c.root;
	},

	leave: function() {
		if (this._ussdTimer) { clearInterval(this._ussdTimer); this._ussdTimer = null; }
	}
});
