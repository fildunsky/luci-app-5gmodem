'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require sms-tool-5gm.editors as editors';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';
'require view.modem5g.atexplain as atexplain';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

function atChain(cmds) {
	return cmds.map(function(c, i) {
		c = String(c).trim();
		return (i === 0) ? c : c.replace(/^at(?=[+^$*#])/i, '');
	}).join(';');
}

function isAtLine(s) { return (/^at/i).test(String(s || '').trim()); }

function parseLegacyLine(s) {
	var m = s.match(/^(.*?)\s*(?:➜|→|->)\s*(.*)$/);
	if (m) {
		var name = m[1].trim();
		var parts = m[2].split(';');
		if (parts.length > 1 && parts[0].trim() === parts[1].trim()) { parts.shift(); }
		var code = atChain(parts);
		return code ? { name: (name || code), code: code } : null;
	}
	if (s.indexOf(';') >= 0 && !isAtLine(s)) {
		var f = s.split(';');
		var c2 = atChain(f.slice(1));
		if (c2) { return { name: f[0].trim() || c2, code: c2 }; }
	}
	return null;
}

var DANGEROUS_AT = [
	/\+QPCIE\s*=\s*"adb"/i,
	/\+QCFG\s*=\s*"usbcfg"\s*,/i,
	/\+QCFG\s*=\s*"data_interface"\s*,/i,
	/\+QCFG\s*=\s*"pcie\/mode"\s*,/i,
	/\+QFASTBOOT/i,
	/\+QPRTPARA\s*=\s*3/i
];

function isDangerousAt(cmd) {
	var s = String(cmd || '');
	return DANGEROUS_AT.some(function(re) { return re.test(s); });
}

function tr(s) { return s ? _(s) : s; }

function parseTemplates(content) {
	var out = [], desc = null;
	String(content || '').split('\n').forEach(function(raw) {
		var s = raw.trim();
		if (s === '') { desc = null; return; }
		if (s.slice(0, 2) === '##') {
			out.push({ type: 'section',
				name: tr(s.replace(/^#+/, '').replace(/[═=─\-\s]+$/, '').trim()) });
			desc = null; return;
		}
		if (s.charAt(0) === '#') { desc = s.replace(/^#+\s?/, '').trim(); return; }
		var legacy = parseLegacyLine(s);
		if (legacy) { out.push({ type: 'cmd', name: tr(legacy.name), code: legacy.code }); desc = null; return; }
		var code = atChain(s.split(';'));
		if (code) { out.push({ type: 'cmd', name: desc ? tr(desc) : code, code: code }); }
		desc = null;
	});
	return out;
}

function atFamilyFor(vp, model) {
	vp = String(vp || '').toLowerCase();
	var m = String(model || '').toLowerCase();
	if (/compal|vos_5g|rxm|sg500/.test(m)) { return 'compal'; }
	if (/fm350/.test(m) || vp.indexOf('0e8d:712') === 0) { return 'fm350'; }
	if (/l850|l860/.test(m) || vp === '8087:095a' || vp === '413c:81d9') { return 'xmm'; }
	if (vp === '1199:a001' || /em7345/.test(m)) { return 'xmm7160'; }
	if (vp === '05c6:90d6') { return 'compal'; }
	if (vp === '1bc7:1910' || vp === '1bc7:1911') { return 'qualcomm'; }
	if (vp.indexOf('1bc7:') === 0 || /telit|lm9/.test(m)) { return 'telit'; }
	if (vp.indexOf('2c7c:') === 0 || /quectel|^e[gmp]\d|^r[gm]5/.test(m)) { return 'quectel'; }
	if (vp.indexOf('1e0e:') === 0 || /simcom|sim7/.test(m)) { return 'simcom'; }
	if (vp.indexOf('12d1:') === 0 || /huawei/.test(m)) { return 'huawei'; }
	if (vp === '19d2:1485' || vp === '19d2:1432' || vp === '19d2:1489' || vp === '19d2:1275' || /mf28/.test(m)) { return 'zte'; }
	if (vp === '413c:81d7' || vp === '413c:81e0' || vp === '413c:81e4' || vp === '413c:81e6' || vp === '413c:81d8' || vp === '0489:e0b5' || vp === '0489:e0b4' || vp === '05c6:9025'
		|| vp === '05c6:90d5' || vp.indexOf('1e2d:00b') === 0 || /t99w|t77w|dw58|mv31/.test(m)) { return 'qualcomm'; }
	return null;
}

function atFilePath(name) {
	return (name === '__user__') ? '/etc/5gmodem/modem/atcmmds.user'
	                             : '/etc/5gmodem/modem/atcmmds/' + name;
}

// Page layout: header card like the Network page, a terminal with the session's commands on the
// left, templates on the right. See docs/subsystems/diagnostics.md, "AT console".
var AT_TIMEOUT = 8;
var CSS_ID = 'tg-page-at-css';
function loadPageCss() {
	if (document.getElementById(CSS_ID)) { return; }
	document.head.appendChild(E('link', { 'id': CSS_ID, 'rel': 'stylesheet', 'type': 'text/css',
		'href': L.resource('view/modem5g/page-at.css') }));
}

var ICONS = {
	term: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/></g>',
	send: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4Z"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	pen: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 20h4L19 9l-4-4L4 16Z"/><path d="m13.5 6.5 4 4"/></g>',
	warn: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5 2.5 20h19Z"/><path d="M12 10v4.5M12 17.2v.3"/></g>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size, cls) {
	var s = E('span', { 'class': cls || 'tg-at-i' });
	s.innerHTML = svg(name, size);
	return s;
}
function pill(kind, text, cls) {
	return E('span', { 'class': 'tg-at-pill ' + kind + (cls ? ' ' + cls : '') }, [ E('i'), E('span', {}, text) ]);
}
function iconButton(name, label, cls, attrs) {
	var b = E('button', Object.assign({ 'type': 'button', 'class': 'cbi-button ' + (cls || '') }, attrs || {}));
	b.innerHTML = svg(name, 15);
	if (label) { b.appendChild(E('span', {}, label)); }
	return b;
}

function hms() {
	var d = new Date(), p = function(n) { return (n < 10 ? '0' : '') + n; };
	return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
}

function atPort() {
	var port = uci.get('5gmodem', 'sms', 'atport');
	if (!port) {
		var ap = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '').replace(/[^A-Za-z0-9]/g, '_');
		if (ap) { port = uci.get('5gmodem', 'm_' + ap, 'at_port') || ''; }
	}
	return port || window._sendatLmPort || '';
}

return view.extend({
	viewName: 'sendat',

	restoreSettingsFromLocalStorage: function() {
		try {
			return localStorage.getItem('luci-app-' + this.viewName
				+ '-selectedFile:' + (window._sendatLmVp || ''));
		} catch(e) {
			return null;
		}
	},

	saveSettingsToLocalStorage: function(fileName) {
		try {
			localStorage.setItem('luci-app-' + this.viewName
				+ '-selectedFile:' + (window._sendatLmVp || ''), fileName);
		} catch(e) {}
	},

	/* ---------- terminal ---------- */

	termEmpty: function() {
		var t = this._t;
		t.term.innerHTML = '';
		t.term.appendChild(E('div', { 'class': 'tg-at-empty' }, _('Pick a template or type a command below.')));
	},

	addEntry: function(cmd) {
		var t = this._t;
		var empty = t.term.querySelector('.tg-at-empty');
		if (empty) { empty.remove(); }
		var out = E('div', { 'class': 'tg-at-out' }, [ E('span', { 'class': 'tg-at-spin' }) ]);
		var el = E('div', { 'class': 'tg-at-entry' }, [
			E('div', { 'class': 'tg-at-cmdline' }, [
				E('span', { 'class': 't' }, hms()), ' ',
				E('span', { 'class': 'p' }, '›'), ' ',
				E('span', { 'class': 'c' }, cmd)
			]),
			out
		]);
		t.term.appendChild(el);
		t.term.scrollTop = t.term.scrollHeight;
		return { el: el, out: out, cmd: cmd };
	},

	fillEntry: function(entry, stdout, stderr) {
		var out = entry.out;
		out.innerHTML = '';
		var lines = [];
		String(stdout || '').split('\n').forEach(function(l) { if (l !== '') { lines.push([ l, false ]); } });
		String(stderr || '').split('\n').forEach(function(l) { if (l !== '') { lines.push([ l, true ]); } });
		if (!lines.length) { lines.push([ _('No response from modem'), true ]); }
		lines.forEach(function(it) {
			var l = it[0], cls = '';
			if (it[1] || /^(\+CM[ES] )?ERROR\b/.test(l.trim())) { cls = 'e'; }
			else if (/^OK$/.test(l.trim())) { cls = 'ok'; }
			out.appendChild(E('div', cls ? { 'class': cls } : {}, l));
		});
		this.explainEntry(entry, stdout);
		if (this._t) { this._t.term.scrollTop = this._t.term.scrollHeight; }
	},

	// Our own reading of a known command and its reply, under the raw answer (atexplain.js).
	explainEntry: function(entry, stdout) {
		var ex = null;
		try { ex = atexplain.explain(entry.cmd, stdout); } catch (e) {}
		if (!ex) { return; }
		var many = ex.length > 1;
		var box = E('div', { 'class': 'tg-at-expl' }, [ E('div', { 'class': 'tg-at-expl-h' }, _('Explanation')) ]);
		ex.forEach(function(it) {
			box.appendChild(E('div', { 'class': 'tg-at-expl-m' }, [
				many ? E('code', {}, [ it.cmd ]) : '', many ? ' ' : '', it.meaning ]));
			if (it.lines.length) {
				box.appendChild(E('ul', { 'class': 'tg-at-expl-l' }, it.lines.map(function(l) { return E('li', {}, [ l ]); })));
			}
		});
		entry.el.appendChild(box);
	},

	setBusy: function(on) {
		this._busy = !!on;
		if (this._t) { this._t.send.disabled = !!on; }
	},

	handleCommand: function(exec, args, cmd) {
		var self = this;
		var entry = this.addEntry(cmd);
		this.setBusy(true);
		return fs.exec(exec, args).then(function(res) {
			var so = (res && res.stdout || '').replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, '');
			var se = (res && res.stderr || '').replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, '');
			self.fillEntry(entry, so, se);
		}).catch(function(err) {
			self.fillEntry(entry, '', String(err));
		}).finally(function() {
			self.setBusy(false);
		});
	},

	handleGo: function(ev, confirmed) {
		if (this._busy) { return false; }
		var input = document.getElementById('cmdvalue');
		var atcmd = String((input && input.value) || '').trim();
		var port = atPort();

		if (atcmd.length < 2) {
			ui.addNotification(null, E('p', _('Please specify the command to send')), 'info');
			return false;
		}
		if (!port) {
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
		}
		if (!confirmed && isDangerousAt(atcmd)) {
			var self = this;
			var m = ui.showModal(_('Dangerous AT command'), [
				E('div', { 'class': 'tg-at-warnrow' }, [ icon('warn', 18),
					E('p', {}, _('This command can change the modem composition or disable its ports for good. On some modules it removes all USB ports, and only reflashing over EDL brings them back.')) ]),
				E('pre', { 'class': 'tg-at-danger-cmd' }, atcmd),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, [ _('Cancel') ]),
					' ',
					E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() {
						ui.hideModal();
						self.handleGo(ev, true);
					} }, [ _('Send anyway') ])
				])
			]);
			if (m && m.classList) { m.classList.add('tg-at-modal'); }
			return false;
		}

		var h = this._hist;
		if (h[h.length - 1] !== atcmd) { h.push(atcmd); if (h.length > 50) { h.shift(); } }
		this._histPos = null;
		return this.handleCommand('/usr/share/5gmodem/atcmd.sh', [ port, atcmd, String(AT_TIMEOUT) ], atcmd);
	},

	handleClear: function(ev) {
		if (this._t) { this.termEmpty(); }
		var ov = document.getElementById('cmdvalue');
		if (ov) { ov.value = ''; ov.focus(); }
	},

	handleCopy: function(code) {
		var ov = document.getElementById('cmdvalue');
		if (!ov || !code) { return; }
		ov.value = code;
		ov.focus();
	},

	recall: function(dir) {
		var h = this._hist, ov = document.getElementById('cmdvalue');
		if (!h.length || !ov) { return; }
		var pos = (this._histPos == null) ? h.length : this._histPos;
		pos += dir;
		if (pos < 0) { pos = 0; }
		if (pos >= h.length) { this._histPos = null; ov.value = ''; return; }
		this._histPos = pos;
		ov.value = h[pos];
	},

	handleFileChange: function(fileName) {
		var self = this;
		if (!fileName) { return; }
		this.saveSettingsToLocalStorage(fileName);
		return fs.read_direct(atFilePath(fileName)).then(function(content) {
			self.fillList(parseTemplates(content));
		}).catch(function(err) {
			self.fillList([]);
			ui.addNotification(null, E('p', [ _('Error loading AT commands file:') + ' ' + fileName ]), 'error');
		});
	},

	fillList: function(items) {
		var self = this, host = this._t && this._t.list;
		if (!host) { return; }
		host.innerHTML = '';
		if (!items.some(function(it) { return it.type === 'cmd'; })) {
			host.appendChild(E('div', { 'class': 'tg-at-none' }, _('No AT commands available')));
			return;
		}
		items.forEach(function(it) {
			if (it.type === 'section') {
				host.appendChild(E('div', { 'class': 'tg-at-grp' }, [ it.name ]));
				return;
			}
			var same = (it.name === it.code);
			host.appendChild(E('div', {
				'class': 'tg-at-row' + (same ? ' same' : ''), 'role': 'button', 'tabindex': '0', 'title': it.code,
				'click': function() { self.handleCopy(it.code); },
				'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); self.handleCopy(it.code); } }
			}, same ? [ E('code', {}, [ it.code ]) ] : [ E('span', {}, [ it.name ]), E('code', {}, [ it.code ]) ]));
		});
	},

	handleModemChange: function(ev) {
		let sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;

		let serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});

		if (serialModems.length === 0) return;

		let currentPort = uci.get('5gmodem', 'sms', 'atport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});

		if (currentIndex === -1) currentIndex = 0;

		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];

		if (newModem && newModem.comm_port) {
			uci.set('5gmodem', 'sms', 'atport', newModem.comm_port);
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'smsopt', 'atport=' + newModem.comm_port ]), null).then(function() {
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
		return fresh.check(40008, [ editors, modemtabs, mutil, atexplain ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		window._sendatLmPort = '';
		// one round to the router: the modem list is asked together with the files, not after them
		var lmP = L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh', []), '[]');
		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/atcmmds.user'), null),
			L.resolveDefault(fs.list('/etc/5gmodem/modem/atcmmds'), []),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('defmodems'))
		]).then(function(res) {
			return lmP.then(function(out) {
				try {
					var act = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
					(JSON.parse(out) || []).forEach(function(m) {
						if (m.path === act && m.tty && m.tty.length) {
							window._sendatLmPort = m.tty[0];
						}
						if (m.path === act) {
							window._sendatLmVp = String(m.vidpid || '').toLowerCase();
							window._sendatLmModel = String(m.model || '');
						}
					});
				} catch (e) {}
				return res;
			});
		});
	},

	renderHead: function() {
		var port = atPort();
		var model = String(window._sendatLmModel || '');
		var ico = E('div', { 'class': 'tginfo-signal tg-at-ico' + (port ? '' : ' bad') });
		ico.innerHTML = svg('term', 36);
		ico.appendChild(E('medium', {}, 'AT'));
		var kind = port ? 'ok' : 'bad';
		var text = port ? _('AT port') : _('Modem AT port not found');
		return E('div', { 'class': 'cbi-section tg-pg-head tg-at-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-at-title' }, [
				E('span', {}, 'AT'),
				port ? E('span', { 'class': 'tg-proto-badge' }, port) : '',
				pill(kind, text, 'tg-at-pillm')
			]),
			E('div', { 'class': 'tginfo-general' }, [
				ico,
				E('div', { 'class': 'tginfo-status' }, [
					model ? E('div', { 'class': 'tginfo-reg' }, _('Modem') + ' ' + model) : '',
					E('div', { 'class': 'tginfo-op tg-at-main' }, _('AT command console')),
					E('div', { 'class': 'tginfo-loc' }, _('Commands go through atcmd.sh: the port and the command form are checked on the router. The reply is awaited up to %d seconds.').format(AT_TIMEOUT))
				]),
				E('div', { 'class': 'tginfo-right' }, [ pill(kind, text) ])
			])
		]);
	},

	renderModemPager: function() {
		let sections = uci.sections('defmodems', 'defmodems') || [];
		let serialModems = sections.filter(function(s) { return s.modemdata === 'serial'; });
		if (!serialModems.length) { return ''; }
		let currentPort = uci.get('5gmodem', 'sms', 'atport');
		let currentModem = serialModems.find(function(s) { return s.comm_port === currentPort; }) || serialModems[0];
		let label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
		let buttonsDisabled = (serialModems.length > 1) ? null : true;
		return E('div', { 'class': 'tg-at-pager' }, [
			E('span', { 'class': 'tg-at-lbl' }, _('Select modem')),
			E('div', { 'class': 'pager center tg-row' }, [
				E('button', { 'class': 'btn cbi-button-neutral tg-col-narrow prev', 'aria-label': _('Previous modem'),
					'click': ui.createHandlerFn(this, 'handleModemChange'), 'disabled': buttonsDisabled }, [ ' ◄ ' ]),
				E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
				E('button', { 'class': 'btn cbi-button-neutral tg-col-narrow next', 'aria-label': _('Next modem'),
					'click': ui.createHandlerFn(this, 'handleModemChange'), 'disabled': buttonsDisabled }, [ ' ► ' ])
			])
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();
		loadPageCss();
		var self = this;
		this._hist = [];
		this._histPos = null;

		/* ---------- terminal ---------- */
		var t = this._t = {};
		t.term = E('div', { 'class': 'tg-at-term', 'aria-live': 'polite' });
		t.input = E('input', {
			'class': 'cbi-input-text',
			'type': 'text',
			'id': 'cmdvalue',
			'autocomplete': 'off',
			'autocapitalize': 'characters',
			'spellcheck': 'false',
			'placeholder': _('Command to send'),
			'aria-label': _('Command to send'),
			'data-tooltip': _('Press [Enter] to send the command, press [Ctrl+Delete] to clear the field'),
			'keydown': function(ev) {
				if (ev.keyCode === 13) {
					ev.preventDefault();
					self.handleGo(ev);
				}
				else if (ev.keyCode === 46 && (ev.ctrlKey || ev.shiftKey)) {
					ev.preventDefault();
					t.input.value = '';
					t.input.focus();
				}
				else if (ev.key === 'ArrowUp' || ev.key === 'ArrowDown') {
					ev.preventDefault();
					self.recall(ev.key === 'ArrowUp' ? -1 : 1);
				}
			}
		});
		t.send = iconButton('send', _('Send command'), 'cbi-button-action important', {
			'id': 'execute', 'click': function(ev) { self.handleGo(ev); } });
		var clr = iconButton('trash', '', 'tg-at-ico-btn', {
			'id': 'clr', 'title': _('Clear form'), 'aria-label': _('Clear form'),
			'click': function(ev) { self.handleClear(ev); } });
		var console_ = E('div', { 'class': 'cbi-section tg-at-console' }, [
			E('div', { 'class': 'tg-at-bar' }, [
				E('span', {}, _('Reply')),
				E('span', { 'class': 'tg-at-hint' }, _('History is kept until the page is closed · ↑ recalls the previous command'))
			]),
			t.term,
			E('div', { 'class': 'tg-at-in' }, [ t.input, t.send, clr ])
		]);
		this.termEmpty();

		/* ---------- templates ---------- */
		let atFiles = loadResults[1] || [];
		let userFiles = atFiles.filter(function(file) {
			return file.type === 'file' && file.name && file.name.match(/\.user$/);
		});
		userFiles.sort(function(a, b) {
			var ga = (a.name === 'generic.user') ? 0 : 1;
			var gb = (b.name === 'generic.user') ? 0 : 1;
			return (ga - gb) || a.name.localeCompare(b.name);
		});
		if (loadResults[0]) { userFiles.push({ type: 'file', name: '__user__' }); }

		var fam = atFamilyFor(window._sendatLmVp, window._sendatLmModel);
		var famFile = fam ? fam + '.user' : null;
		var start = null;
		if (userFiles.length) {
			var saved = this.restoreSettingsFromLocalStorage();
			start = userFiles[0].name;
			[ saved, famFile, 'generic.user' ].some(function(want) {
				if (!want) { return false; }
				if (userFiles.some(function(f) { return f.name === want; })) { start = want; return true; }
				return false;
			});
		}

		t.list = E('div', { 'class': 'tg-at-list' });
		var fileSel = '';
		if (userFiles.length) {
			fileSel = E('select', {
				'class': 'cbi-input-select tg-at-file',
				'aria-label': _('Defined AT command files'),
				'title': _('Select file with AT commands to load'),
				'change': function(ev) { self.handleFileChange(ev.target.value); }
			}, userFiles.map(function(f) {
				var label = (f.name === '__user__') ? _('My commands') : f.name.replace(/\.user$/, '').toUpperCase();
				if (f.name === famFile) { label = _('%s (by modem)').format(label); }
				return E('option', { 'value': f.name, 'selected': (f.name === start) ? true : null }, label);
			}));
		}
		var tplSec = E('div', { 'class': 'cbi-section tg-at-tplsec' }, [
			E('h3', {}, _('AT commands')),
			this.renderModemPager(),
			fileSel,
			t.list,
			E('div', { 'class': 'tg-at-actions' }, [
				iconButton('pen', _('AT templates'), '', { 'click': function() {
					new editors.atCommandsManagerDialog(_('AT templates')).show();
				} })
			])
		]);
		if (start) {
			t.list.appendChild(E('div', { 'class': 'tg-at-none' }, E('span', { 'class': 'tg-at-spin' })));
			L.resolveDefault(fs.read_direct(atFilePath(start)), '').then(function(content) {
				self.fillList(parseTemplates(content));
			});
		} else {
			this.fillList([]);
		}

		return E('div', { 'class': 'tg-at' }, [
			this.renderHead(),
			E('div', { 'class': 'tg-at-grid' }, [ console_, E('div', { 'class': 'tg-at-side' }, [ tplSec ]) ])
		]);
	}
});
