'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require dom';
'require fs';
'require ui';
'require uci';
'require form';
'require rpc';
'require tools.widgets as widgets';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/


var profilesView = null;

var uciCommit = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	expect: { '': {} }
});

function savePending(map) {
	return Promise.resolve(map.save(null, true)).then(function() {
		return uci.changes();
	}).then(function(ch) {
		var names = [];
		for (var k in ch) { if ((ch[k] || []).length) { names.push(k); } }
		return Promise.all(names.map(function(n) { return L.resolveDefault(uciCommit(n), null); }));
	}).then(function() {
		if (ui.changes && ui.changes.setIndicator) { ui.changes.setIndicator(0); }
		return uci.unload([ 'network', '5gmodem' ]);
	}).catch(function() {});
}

function modeSuffix(j) {
	if (j.backend === 'hilink') { return ' (HiLink)'; }
	if (j.at_debug === '1' && j.at_native !== '1') { return ' (Debug)'; }
	return '';
}

function detectBoxedHeading() {
	if (document.documentElement.hasAttribute('data-tg-h3')) { return; }
	document.documentElement.setAttribute('data-tg-h3', '1');
	var probe = E('div', { 'class': 'cbi-section tg5g',
		'style': 'position:absolute;left:-9999px;top:0;visibility:hidden' }, [ E('h3', {}, 'x') ]);
	document.body.appendChild(probe);
	var pad = parseFloat(getComputedStyle(probe.firstChild).paddingLeft) || 0;
	document.body.removeChild(probe);
	if (pad >= 8) { document.documentElement.classList.add('tg-boxed-h3'); }
}
if (document.body) { detectBoxedHeading(); }
else { document.addEventListener('DOMContentLoaded', detectBoxedHeading); }

var ListDropdown = form.RichListValue || form.ListValue;

(function() {
	if (document.getElementById('tg-page-modem-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-page-modem-css';
	l.rel = 'stylesheet';
	l.href = L.resource('view/modem5g/page-modem.css');
	document.head.appendChild(l);
})();

var PHONE_MQ = '(max-width: 700px)';

var ICONS = {
	chip: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx=".5"/><path d="M9 2.5V6M15 2.5V6M9 18v3.5M15 18v3.5M2.5 9H6M2.5 15H6M18 9h3.5M18 15h3.5"/></g>',
	refresh: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 13a8.5 8.5 0 1 1-2.6-7.2L20.5 8"/><path d="M20.5 3v5h-5"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	file: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h8l5 5v13H6Z"/><path d="M14 3v5h5M9 13h6M9 17h6"/></g>',
	down: '<path d="M12 3v12M7 10l5 5 5-5M4 20.5h16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
	info: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7.5v.3"/></g>',
	warn: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3.5 2.5 20h19Z"/><path d="M12 10v4.5M12 17.2v.3"/></g>',
	chev: '<path d="M7 10l5 5 5-5z" fill="currentColor"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size) {
	var s = E('span', { 'class': 'tg-modem-i' });
	s.innerHTML = svg(name, size);
	return s;
}
function pill(kind, text) {
	return E('span', { 'class': 'tg-modem-pill ' + kind }, [ E('i'), E('span', {}, text || '') ]);
}
function ucfirst(s) { s = String(s || ''); return s.charAt(0).toUpperCase() + s.slice(1); }
function maskImei(v) {
	v = String(v || '');
	return v.length > 6 ? '••••' + v.slice(-4) : v;
}

// collapsibleSection() of 5gdetail.js (same storage keys) with a summary on the right.
function collapsible(key, titleText, content, defOpen, attrs) {
	var open = defOpen, stored = null;
	try { stored = window.localStorage.getItem('5gm-blk-' + key); } catch (e) {}
	if (stored === '0' || stored === '1') { open = stored === '1'; }
	var chev = E('span', { 'class': 'tg-modem-chev' });
	chev.innerHTML = svg('chev', 16);
	var sum = E('span', { 'class': 'tg-modem-sum' }, '');
	var body = E('div', { 'class': 'tg-collapse' }, [ E('div', { 'class': 'tg-collapse-inner' }, content) ]);
	var title = E('h3', { 'class': 'tg-modem-coll', 'role': 'button', 'tabindex': '0' }, [ chev, E('span', {}, titleText), sum ]);
	var set = function(v, persist) {
		body.classList.toggle('open', v);
		chev.classList.toggle('open', v);
		title.classList.toggle('open', v);
		title.setAttribute('aria-expanded', String(v));
		if (persist) { try { window.localStorage.setItem('5gm-blk-' + key, v ? '1' : '0'); } catch (e) {} }
	};
	title.addEventListener('click', function() { set(!body.classList.contains('open'), true); });
	title.addEventListener('keydown', function(ev) {
		if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); set(!body.classList.contains('open'), true); }
	});
	set(open, false);
	var a = { 'class': 'cbi-section tg5g', 'data-blk': key };
	if (attrs) { for (var k in attrs) { a[k] = attrs[k]; } }
	return { node: E('div', a, [ title, body ]), sum: sum };
}

function tileEl(name, bar) {
	var t = { now: E('span', {}, '-'), unit: E('small', {}, '') };
	t.val = E('div', { 'class': 'tg-hist-now dash' }, [ t.now, ' ', t.unit ]);
	var kids = [ E('div', { 'class': 'tg-hist-h' }, E('span', { 'class': 'tg-hist-name' }, E('b', {}, name))), t.val ];
	if (bar) {
		t.fill = E('div', { 'class': 'tg-mbar-fill' });
		t.bar = E('div', { 'class': 'tg-mbar', 'style': 'visibility:hidden' }, E('div', { 'class': 'tg-mbar-t' }, t.fill));
		kids.push(t.bar);
	}
	t.foot = E('span', {}, '');
	t.footRow = E('div', { 'class': 'tg-hist-f', 'style': 'display:none' }, t.foot);
	kids.push(t.footRow);
	t.card = E('div', { 'class': 'tg-hist-card' }, kids);
	return t;
}
function setTile(t, val, unit, foot, mono) {
	var none = (val === null || val === undefined || val === '' || val === '-');
	t.now.textContent = none ? '-' : String(val);
	t.now.className = (!none && mono) ? 'tg-modem-mono' : '';
	t.unit.textContent = none ? '' : (unit || '');
	t.val.classList.toggle('dash', none);
	t.foot.textContent = foot || '';
	t.footRow.style.display = foot ? '' : 'none';
}

// Header card handles; filled from the snapshot (fillModemInfo) and the profile list (fillProfiles).
var _hd = null;

// Interface line of the header card: the modem interface name (the protocol is the chip in the title).
function setHeadTech() {
	if (!_hd) { return; }
	var t = _hd.tech;
	t.innerHTML = '';
	t.appendChild(E('span', { 'class': 'tginfo-iplabel' }, _('Interface') + ':'));
	if (!_hd.ifName) {
		t.appendChild(E('span', { 'class': 'tg-modem-sub' }, _('no interface')));
		return;
	}
	t.appendChild(E('span', { 'class': 'tg-modem-mono' }, _hd.ifName));
}


return view.extend({
	handleCommand: function(exec, args) {
		var buttons = document.querySelectorAll('.diag-action > .cbi-button');

		for (var i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');

		return fs.exec(exec, args).then(function(res) {
			var out = document.getElementById('pre');
			out.style.display = '';

			var lines = ((res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')).split('\n');
			var spans = lines.map(function(ln) {
				var color = '#d6e0ea';
				if (/^\++ /.test(ln)) { color = '#7db2ff'; }
				return E('div', { 'style': 'color:' + color }, [ ln.length ? ln : ' ' ]);
			});
			dom.content(document.getElementById('preout'), spans);
			fs.write('/tmp/5gmodem/debug_result.txt', [ res.stdout || '' ]);
		}).catch(function(err) {
			ui.addNotification(null, E('p', [ err ]))
		}).finally(function() {
			var viewbc = document.getElementById('clear');
			viewbc.style.display = '';
			var viewbd = document.getElementById('download');
			viewbd.style.display = '';

			for (var i = 0; i < buttons.length; i++)
				buttons[i].removeAttribute('disabled');
		});
	},

	handleUSB: function(ev, cmd) {
		return this.handleCommand('/bin/cat', ['/sys/kernel/debug/usb/devices']);
	},

	handleTTY: function(ev, cmd) {
		return this.handleCommand('/bin/ls', ['/dev']);
	},

	handleDBG: function(ev, cmd) {
		return this.handleCommand('/bin/sh', ['-x', '/usr/share/5gmodem/5gmodem.sh']);
	},

	handleClear: function(ev) {
		var out = document.getElementById('pre');
		out.style.display = 'none';
		dom.content(document.getElementById('preout'), []);
		var viewbc = document.getElementById('clear');
		viewbc.style.display = 'none';
		var viewbd = document.getElementById('download');
		viewbd.style.display = 'none';
		fs.write('/tmp/5gmodem/debug_result.txt', '');
	},

	handleDownload: function(ev) {
		return L.resolveDefault(fs.read_direct('/tmp/5gmodem/debug_result.txt'), null).then(function (res) {
				if (res) {
					var link = E('a', {
						'download': 'debug_result.txt',
						'href': URL.createObjectURL(
							new Blob([ res ], { type: 'text/plain' })),
					});
					link.click();
					URL.revokeObjectURL(link.href);
				}
			}).catch(function(err) {
				ui.addNotification(null, E('p', {}, [ _('Download error') + ': ' + ((err && err.message) || err) ]));
		});

	},

	load: function() {
		var self = this, args = arguments;
		return fresh.check(40008, [ modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([
			Promise.resolve(''),
			fs.list('/dev').then(function(devs) {
				return devs.filter(function(dev) {
					return dev.name.match(/^ttyUSB/) || dev.name.match(/^cdc-wdm/) || dev.name.match(/^ttyACM/) || dev.name.match(/^mhi_/) || dev.name.match(/^wwan/);
				});
			}),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('network')),
			L.resolveDefault(fs.list('/www/luci-static/resources/protocol'), []),
			L.resolveDefault(fs.list('/sys/class/leds'), []),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'wdmdrv' ]), '')
		]);
	},

	renderProfiles: function() {
		var box = E('div', { 'id': 'mprof-box' }, [
			E('div', { 'id': 'mprof-warn' }),
			E('div', { 'id': 'mprof-list', 'class': 'tg-modem-prof' }, [
				E('span', { 'class': 'tg-modem-muted' }, _('Loading…'))
			]),
			E('div', { 'id': 'mprof-mm', 'class': 'tg-modem-mm' })
		]);
		profilesView = this;
		var isPhone = !!(window.matchMedia && window.matchMedia(PHONE_MQ).matches);
		var blk = collapsible('mprof', _('Saved modem profiles'), [ box ], !isPhone);
		this._profSum = blk.sum;
		// fillProfiles() looks its targets up by id: load once the page is in the document.
		var self = this;
		window.setTimeout(function() { self.loadProfiles(); }, 0);
		return blk.node;
	},

	loadProfiles: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'profiles' ]), '[]'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/powercheck.sh'), '{}'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/mmneed.sh', [ 'check' ]), '{}')
		]).then(function(res) {
			var list = [], pw = {}, mm = {};
			try { list = JSON.parse(res[0]) || []; } catch (e) {}
			try { pw = JSON.parse(res[1]) || {}; } catch (e) {}
			try { mm = JSON.parse(res[2]) || {}; } catch (e) {}
			self.fillProfiles(list, pw, mm);
		});
	},

	fillProfiles: function(list, pw, mm) {
		var mmrow = document.getElementById('mprof-mm');
		if (mmrow) {
			var run = mm && mm.running == 1;
			mmrow.innerHTML = '';
			mmrow.appendChild(E('span', { 'class': 'tg-modem-dot' + (run ? ' on' : '') }));
			mmrow.appendChild(E('span', {}, run ? _('ModemManager is running')
				: _('ModemManager is stopped — no connected modem needs it')));
		}
		var warn = document.getElementById('mprof-warn');
		var box = document.getElementById('mprof-list');
		if (!box) { return; }
		if (this._profSum) { this._profSum.textContent = list.length ? _('Profiles: %d').format(list.length) : ''; }

		if (warn && pw && pw.suspect) {
			warn.innerHTML = '';
			var mA = parseInt(pw.total_ma, 10) || 0;
			warn.appendChild(E('div', { 'class': 'alert-message warning tg-modem-alert' }, [
				icon('warn', 17),
				E('div', {}, [
					E('strong', {}, _('Not enough power?') + ' '),
					_('%d modems request %d mA. Such a modem answers AT commands, but its interface stays down — a powered USB hub helps.')
						.format(parseInt(pw.modems, 10) || 0, mA)
				])
			]));
		} else if (warn) { warn.innerHTML = ''; }

		box.innerHTML = '';
		if (!list.length) {
			box.appendChild(E('span', { 'class': 'tg-modem-muted' }, _('No modems seen yet')));
			return;
		}
		var self = this;

		var marksOf = function(p) {
			var out = [];
			if (p.celllock) {
				var cl = String(p.celllock).split(' ');
				out.push({ txt: cl[0] === 'cell'
					? _('locked to cell %s/%s').format(cl[1], cl[2])
					: _('locked to frequency %s').format(cl[1]), cls: 'bad' });
			}
			var isMM = mutil.isMMProto(p.proto);
			if (p.mm_exclude === '0' && !isMM && p.proto) {
				out.push({ txt: _('visible to ModemManager'), cls: 'warn' });
			} else if (p.mm_exclude === '1' && isMM) {
				out.push({ txt: _('hidden from ModemManager'), cls: 'warn' });
			}
			return out;
		};
		var mmRunning = !!(mm && mm.running == 1);
		var lowPower = ' ' + String((pw && pw.paths) || '') + ' ';
		list.forEach(function(p) {
			var isLow = lowPower.indexOf(' ' + p.path + ' ') >= 0;
			var protoNice = mutil.protoLabel(p.proto) || '—';
			var isHilink = (p.kind === 'hilink');
			if (isHilink) { protoNice = 'HiLink'; }
			var pdpNice = '';
			if (p.pdptype) {
				pdpNice = ({
					'ipv4v6': 'IPv4v6', 'ipv4': 'IPv4', 'ipv6': 'IPv6'
				})[String(p.pdptype).toLowerCase()] || p.pdptype;
			}

			if (p.active && _hd && !_hd.root.classList.contains('none')) {
				if (p.vidpid) { _hd.vidpid.textContent = p.vidpid; _hd.vidpid.style.display = ''; }
				_hd.usb.textContent = 'USB ' + p.path;
				if (_hd.hilink) {
					// a HiLink modem has no AT snapshot: the profile is all the header has
					_hd.reg.textContent = 'HiLink';
					_hd.main.textContent = p.webaddr || '-';
					_hd.main.classList.toggle('none', !p.webaddr);
					_hd.ico.className = 'tginfo-signal tg-modem-ico ' + (p.present ? 'ok' : 'off');
				}
				if (!_hd.haveName && (p.model || p.path)) { _hd.name.textContent = p.model || p.path; }
			}

			// Card layout (as before the redesign): name and VID:PID with the state on the right, a rule,
			// then two-sided lines (interface | APN, protocol and eSIM | PDP type), marks, saved bands,
			// and the IMEI / USB path with the Delete button at the bottom.
			var card = E('div', {
				'class': 'tg-hist-card tg-modem-pcard' + (p.active ? ' cur' : '') + (p.present ? '' : ' gone') + (isLow ? ' tg-modem-warncard' : ''),
				'title': isLow ? _('the data interface did not come up — not enough power?') : ''
			}, [
				E('div', { 'class': 'tg-modem-phead' }, [
					E('div', { 'class': 'tg-modem-pid' }, [
						E('b', { 'class': 'tg-modem-mono tg-modem-pname' }, [ p.model || p.path ]),
						p.vidpid ? E('span', { 'class': 'tg-modem-mono tg-modem-pvid', 'title': _('USB vendor and product ID') }, [ p.vidpid ]) : ''
					]),
					E('div', { 'class': 'tg-modem-pst' }, [
						pill(p.present ? 'ok' : 'off', p.present ? _('connected') : _('not connected')),
						(isHilink && p.webaddr) ? E('a', {
							'href': 'http://' + p.webaddr + '/html/home.html',
							'target': '_blank', 'rel': 'noreferrer'
						}, [ p.webaddr ]) : ''
					])
				]),
				E('div', { 'class': 'tg-modem-pline' }, [
					E('span', { 'class': 'tg-modem-mono tg-modem-pif' }, [ p.iface || _('no interface') ]),
					E('span', { 'class': 'tg-modem-papn' }, [ 'APN: ', p.apn ? E('span', { 'class': 'tg-modem-mono' }, [ p.apn ]) : _('default') ])
				]),
				E('div', { 'class': 'tg-modem-pline' }, [
					E('span', { 'class': 'tg-modem-pproto' }, [
						E('span', { 'class': 'tg-proto-badge' }, [
							mmRunning && p.mm_exclude === '1' ? E('img', {
								'src': mutil.icon('icons/5gmodem/cghost.svg'),
								'width': 12, 'height': 12, 'alt': '',
								'title': _('hidden from ModemManager')
							}) : '',
							protoNice
						]),
						p.esim ? E('span', {
							'title': (p.esim === 'forced-yes' || p.esim === 'forced-no')
								? _('set manually in the modem settings')
								: _('detected by probing the modem')
						}, [
							'eSIM: ',
							p.esim === 'yes'        ? _('yes') :
							p.esim === 'no'         ? _('no')  :
							p.esim === 'forced-yes' ? _('yes (manually)') :
							                          _('no (manually)')
						]) : ''
					]),
					E('span', {}, [ pdpNice ])
				])
			]);

			var marks = marksOf(p);
			if (marks.length) {
				card.appendChild(E('div', { 'class': 'pf' }, marks.map(function(m) {
					return E('span', { 'class': 'tg-modem-mark ' + m.cls }, [ m.txt ]);
				})));
			}
			if (p.iface_shared) {
				card.appendChild(E('div', { 'class': 'pf' }, [ E('span', { 'class': 'tg-modem-mark warn' },
					[ _('shares interface %s with another profile').format(p.iface) ]) ]));
			}
			if (isLow) {
				card.appendChild(E('div', { 'class': 'pf tg-modem-lowtxt' },
					[ ucfirst(_('the data interface did not come up — not enough power?')) ]));
			}

			var savedBands = (function() {
				var parts = [];
				var add = function(list, pfx, label) {
					if (!list) return;
					var bs = String(list).trim().split(/\s+/).filter(function(b) {
						return (/^[0-9]+$/).test(b);
					});
					if (bs.length) {
						parts.push({ label: label, bands: bs.map(function(b) { return pfx + b; }) });
					}
				};
				add(p.save_band, 'B', '4G');
				add(p.save_band5gnsa, 'n', '5G NSA');
				add(p.save_band5gsa, 'n', '5G SA');
				return parts;
			})();
			if (savedBands.length) {
				var sb = E('div', { 'class': 'tg-modem-psb' }, [ E('div', { 'class': 'pf' }, [ _('Saved bands') + ':' ]) ]);
				savedBands.forEach(function(part) {
					sb.appendChild(E('div', { 'class': 'bands' }, [ E('b', {}, part.label) ].concat(
						part.bands.map(function(b) { return E('span', {}, b); }))));
				});
				card.appendChild(sb);
			}

			card.appendChild(E('div', { 'class': 'tg-modem-pfoot' }, [
				E('div', { 'class': 'pf' }, [
					E('div', { 'title': p.imei ? 'IMEI ' + p.imei : '' }, [ p.imei ? ('IMEI ' + maskImei(p.imei)) : _('IMEI unknown') ]),
					E('div', {}, [ 'USB ' + p.path ])
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function() {
						return self.confirmDelete(p);
					})
				}, [ icon('trash', 15), _('Delete') ])
			]));
			box.appendChild(card);
		});
	},

	confirmDelete: function(p) {
		var self = this;
		var lines = [ E('p', {}, [ _('Delete the profile of %s?').format(p.model || p.path) ]) ];
		if (p.iface && !p.iface_shared) {
			lines.push(E('p', {}, [ _('Its network interface "%s" will be removed too.').format(p.iface) ]));
		} else if (p.iface_shared) {
			lines.push(E('p', {}, [ _('The interface "%s" stays: another profile uses it.').format(p.iface) ]));
		}
		if (p.present) {
			lines.push(E('p', { 'style': 'color:#e58a00' },
				_('This modem is connected right now. It will be set up again from scratch.')));
		}
		ui.showModal(_('Delete profile'), lines.concat([
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return fs.exec('/usr/share/5gmodem/modemswitch.sh',
								[ 'delprofile', p.sec ]).then(function() {
							ui.hideModal();
							window.location.reload();
						});
					})
				}, _('Delete'))
			])
		]));
	},

	renderNetsel: function() {
		var p = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
		var NS = '/usr/share/5gmodem/netsel.sh';
		var st = { mode: 'auto', plmn: '', act: '', fallback: '1', backend: '', name: '' };
		var nets = [];
		var polling = false;
		var parse = function(out) {
			try { return JSON.parse(String(out || '').trim() || '{}'); } catch (e) { return {}; }
		};
		var modeSel = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'auto' }, _('Automatic')),
			E('option', { 'value': 'manual' }, _('Manual'))
		]);
		var netSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:auto; flex:0 1 auto; min-width:0; max-width:100%' });
		var scanBtn = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button' }, _('Find networks'));
		var fbChk = E('input', { 'type': 'checkbox', 'style': 'margin:0 .5em 0 0' });
		var fbLbl = E('label', { 'style': 'display:inline-flex; align-items:center; gap:.4em' },
			[ fbChk, _('Return to automatic if this network is lost') ]);
		var stat = E('div', { 'style': 'margin-top:4px' });
		var manualBox = E('div', { 'style': 'display:none; flex-direction:column; align-items:flex-start; gap:.5em; margin-top:.5em' }, [
			E('div', { 'style': 'display:flex; flex-wrap:wrap; gap:.5em; align-items:center' }, [ netSel, scanBtn ]),
			fbLbl, stat
		]);
		var root = E('div', {}, [ modeSel, manualBox ]);
		var row = function() { return root.closest ? root.closest('.cbi-value') : null; };
		var label = function(n) {
			var t = (n.name || n.plmn) + ' (' + n.plmn + ')';
			if (n.tech) { t += ' ' + n.tech; }
			if (n.stat === 'current') { t += ' - ' + _('current'); }
			else if (n.stat === 'forbidden') { t += ' - ' + _('forbidden'); }
			return t;
		};
		var fillNets = function() {
			var want = st.plmn ? st.plmn + '|' + (st.act || '') : '';
			var opts = [ E('option', { 'value': '' }, nets.length ? _('Choose a network') : _('No networks yet - press "Find networks"')) ];
			var seen = false;
			nets.forEach(function(n) {
				var v = n.plmn + '|' + (n.act || '');
				if (v === want) { seen = true; }
				opts.push(E('option', { 'value': v }, label(n)));
			});
			if (want && !seen) {
				opts.splice(1, 0, E('option', { 'value': want }, label({ plmn: st.plmn, name: st.name,
					tech: '', stat: '' })));
			}
			dom.content(netSel, opts);
			netSel.value = want;
		};
		var show = function() {
			modeSel.value = st.mode;
			manualBox.style.display = (st.mode === 'manual') ? 'flex' : 'none';
			fbChk.checked = (st.fallback !== '0');
			fbLbl.style.display = (st.backend === 'mm') ? 'none' : '';
			fillNets();
		};
		var apply = function() {
			var args;
			if (modeSel.value === 'auto') { args = [ 'set', p, 'auto' ]; }
			else {
				var v = String(netSel.value || '');
				if (!v) { return Promise.resolve(); }
				var pa = v.split('|');
				st.plmn = pa[0]; st.act = pa[1] || '';
				args = [ 'set', p, 'manual', st.plmn, st.act || '-', fbChk.checked ? '1' : '0' ];
			}
			st.mode = modeSel.value;
			stat.textContent = _('Saved. The modem is switching networks, this can take up to a minute.');
			return fs.exec(NS, args).catch(function() {
				stat.textContent = _('Could not apply the network selection');
			});
		};
		var poll = function(started) {
			polling = true;
			scanBtn.disabled = true;
			return L.resolveDefault(fs.exec_direct(NS, [ 'result', p ]), '').then(function(out) {
				var r = parse(out);
				if (r.state === 'running') {
					var sec = Math.max(0, Math.round((Date.now() - started) / 1000));
					stat.textContent = _('Searching for networks (%d s). The connection may drop meanwhile.').format(sec);
					window.setTimeout(function() { poll(started); }, 3000);
					return;
				}
				polling = false;
				scanBtn.disabled = false;
				if (r.state === 'done') {
					nets = Array.isArray(r.networks) ? r.networks : [];
					stat.textContent = nets.length ? '' : _('The modem found no networks');
					fillNets();
				} else if (r.state === 'error') {
					stat.textContent = (r.error === 'busy') ? _('The modem port is busy, try again in a minute')
						: _('The search failed') + (r.error && r.error !== 'timeout' ? ': ' + r.error : '');
				}
			});
		};
		var scan = function() {
			if (polling) { return; }
			// Claim the slot now: the result poll starts only 3 s later, and a mode
			// toggle in between would otherwise start a second scan and poll chain.
			polling = true;
			var started = Date.now();
			stat.textContent = _('Searching for networks (%d s). The connection may drop meanwhile.').format(0);
			scanBtn.disabled = true;
			return L.resolveDefault(fs.exec_direct(NS, [ 'scan', p ]), '').then(function() {
				window.setTimeout(function() { poll(started); }, 3000);
			});
		};
		modeSel.addEventListener('change', function() {
			if (modeSel.value === 'auto') {
				manualBox.style.display = 'none';
				apply();
				return;
			}
			manualBox.style.display = 'flex';
			if (st.plmn) { apply(); }
			else if (!nets.length) { scan(); }
		});
		netSel.addEventListener('change', apply);
		fbChk.addEventListener('change', function() { if (netSel.value) { apply(); } });
		scanBtn.addEventListener('click', function(ev) { ev.preventDefault(); scan(); });
		window.setTimeout(function() {
			var r0 = row();
			if (r0) { r0.style.display = 'none'; }
		}, 0);
		window.setTimeout(function() {
			if (!p) { return; }
			Promise.all([
				L.resolveDefault(fs.exec_direct(NS, [ 'get', p ]), ''),
				L.resolveDefault(fs.exec_direct(NS, [ 'result', p ]), '')
			]).then(function(res) {
				var g = parse(res[0]), r = parse(res[1]);
				if (!g.backend || g.backend === 'none') { return; }
				st.backend = g.backend;
				st.mode = (g.mode === 'manual') ? 'manual' : 'auto';
				st.plmn = g.plmn || '';
				st.act = g.act || '';
				st.fallback = g.fallback || '1';
				st.name = g.name || '';
				if (r.state === 'done' && Array.isArray(r.networks)) { nets = r.networks; }
				show();
				var r1 = row();
				if (r1) { r1.style.display = ''; }
				if (r.state === 'running') { poll(Date.now()); }
			});
		}, 1200);
		return root;
	},

	renderLeds: function(ledsAvail) {
		if (!ledsAvail) { return ''; }

		var cur = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds');
		var metric = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds_metric') || 'rsrp';
		var metrics = [
			[ 'rsrp',   _('RSRP (signal level, default)') ],
			[ 'rsrq',   _('RSRQ (signal quality)') ],
			[ 'sinr',   _('SINR (signal to noise)') ],
			[ 'signal', _('Overall level (percent)') ]
		];

		var ch = {}; var order = [];
		metrics.forEach(function(m) { ch[m[0]] = m[1]; order.push(m[0]); });
		var selW = new ui.Dropdown(metric, ch, { id: 'leds-metric', sort: order });
		var sel = selW.render();
		sel.addEventListener('cbi-dropdown-change', function() {
			L.resolveDefault(fs.exec('/usr/share/5gmodem/signal-leds.sh', [ 'metric', selW.getValue() ]), {});
		});

		var rgb = ledsAvail === 'rgb';

		return E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, rgb ? _('Modem status LED') : _('Signal level indicator')),
			E('div', { 'class': 'cbi-value tg-flag' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Show on the case LEDs')),
				E('div', { 'class': 'cbi-value-field' }, [
					(function() {
						var w = new ui.Checkbox(cur == '0' ? '0' : '1', { id: 'leds-on' });
						var n = w.render();
						n.addEventListener('widget-change', function() {
							L.resolveDefault(fs.exec('/usr/share/5gmodem/signal-leds.sh',
								[ w.isChecked() ? 'enable' : 'disable' ]), {});
						});
						return n;
					})(),
					E('div', { 'class': 'cbi-value-description' },
						rgb ? _('Blue: LTE and the connection is up. Green: registered on 3G or 2G. Blinking red: no service or no connection. Applies immediately, no Save needed.')
							: _('Reads the same snapshot as the pages - the modem is not polled separately. Applies immediately, no Save needed.'))
				])
			]),
			rgb ? '' : E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('LED metric')),
				E('div', { 'class': 'cbi-value-field' }, [
					sel,
					E('div', { 'class': 'cbi-value-description' },
						_('Thresholds match the colours used on the Network page, so three LEDs and a green value mean the same thing'))
				])
			])
		]);
	},

	fillPortLabels: function() {
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listports.sh'), '{}').then(function(out) {
			var info = {};
			try { info = JSON.parse(out || '{}') || {}; } catch (e) { return; }
			document.querySelectorAll('.cbi-dropdown li[data-value^="/dev/"], select option[value^="/dev/"]').forEach(function(el) {
				var full = el.getAttribute('data-value') || el.getAttribute('value');
				var i = info[full];
				var label = full;
				if (i && i.product) { label = full + ' — ' + i.product + (i.vidpid ? ' (' + i.vidpid + ')' : ''); }
				else if (i && i.vidpid && i.vidpid != ':') { label = full + ' — ' + i.vidpid; }
				if (el.textContent !== label) { el.textContent = label; }
			});
		});
	},

	fillAntenna: function() {
		var self = this;
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/antenna.sh', [ 'status' ]), '').then(function(raw) {
			var slot = document.getElementById('antenna-slot');
			var blk = self.renderAntenna(raw);
			if (slot && blk) { slot.appendChild(blk); }
		});
	},

	renderAntenna: function(raw) {
		var st = {};
		try { st = JSON.parse(raw || '{}') || {}; } catch (e) { st = {}; }
		if (st.available != 1) { return ''; }

		var modes = [
			[ 'internal', _('Internal antennas') ],
			[ 'external', _('External antennas') ],
			[ 'auto',     _('Automatic: external where an antenna is detected') ],
			[ 'mix',      _('Mixed: antenna 1 automatic, antenna 2 internal') ]
		];
		var ch = {}; var order = [];
		modes.forEach(function(m) { ch[m[0]] = m[1]; order.push(m[0]); });

		var chainText = function(v) {
			return v === 'external' ? _('external') : (v === 'internal' ? _('internal') : '-');
		};
		var detText = function(v) {
			return v === 'connected' ? _('antenna detected') : (v === 'absent' ? _('no antenna detected') : _('detector unavailable'));
		};
		var a1 = tileEl(_('Antenna %d').format(1)), a2 = tileEl(_('Antenna %d').format(2));
		var paint = function(s) {
			setTile(a1, s.chain1 ? chainText(s.chain1) : null, '', detText(s.detect1));
			setTile(a2, s.chain2 ? chainText(s.chain2) : null, '', detText(s.detect2));
			a1.card.classList.toggle('tg-modem-on', s.detect1 === 'connected');
			a2.card.classList.toggle('tg-modem-on', s.detect2 === 'connected');
		};
		paint(st);

		var selW = new ui.Dropdown(st.mode || 'internal', ch, { id: 'antenna-mode', sort: order });
		var sel = selW.render();
		sel.addEventListener('cbi-dropdown-change', function() {
			L.resolveDefault(fs.exec('/usr/share/5gmodem/antenna.sh', [ 'set', selW.getValue() ]), {})
				.then(function(r) {
					var ns = {};
					try { ns = JSON.parse((r && r.stdout) || '{}') || {}; } catch (e) { return; }
					if (ns.available == 1) { paint(ns); }
				});
		});

		return E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, _('Antennas')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Antenna mode')),
				E('div', { 'class': 'cbi-value-field' }, [
					sel,
					E('div', { 'class': 'cbi-value-description' },
						_('Applies immediately, no Save needed. Automatic modes check the connectors every 3 seconds. The detector only sees antennas that short the connector to ground; a passive antenna may stay undetected while plugged in.'))
				])
			]),
			E('div', { 'class': 'tg-modem-ant' }, [ a1.card, a2.card ])
		]);
	},

	fillModemInfo: function() {
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '20' ]), {})
			.then(function(r) {
				var j = {};
				try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) { return; }
				if (!_hd) { return; }
				if (j.error && j.error !== 'busy' && !j.modem) {
					// a HiLink modem has no AT snapshot: fillProfiles() fills the header from its profile
					if (_hd.hilink) { return; }
					_hd.root.classList.add('none');
					_hd.title.textContent = _('Modem');
					_hd.ico.className = 'tginfo-signal tg-modem-ico off';
					_hd.temp.textContent = '';
					_hd.reg.textContent = '';
					_hd.main.textContent = _('No modem detected. Insert a modem, then reload the page.');
					_hd.main.classList.add('none');
					_hd.usb.textContent = '';
					_hd.vidpid.style.display = 'none';
					return;
				}
				if (j.error === 'busy' && !j.modem) { return; }
				_hd.root.classList.remove('none');
				if (j.modem) { _hd.name.textContent = j.modem + modeSuffix(j); _hd.haveName = true; }
				if (j.protocol) { _hd.proto.textContent = mutil.protoLabel(j.protocol); _hd.proto.style.display = ''; }
				if (j.vidpid && j.vidpid !== '-' && j.vidpid !== ':') { _hd.vidpid.textContent = j.vidpid; _hd.vidpid.style.display = ''; }
				if (j.path && j.path !== '-') { _hd.usb.textContent = 'USB ' + j.path; }
				_hd.ico.className = 'tginfo-signal tg-modem-ico ok';
				var fw = (j.firmware != null && String(j.firmware) !== '' && String(j.firmware) !== '-') ? String(j.firmware) : '';
				if (fw || !_hd.hilink) {
					_hd.reg.textContent = _('Firmware');
					_hd.main.textContent = fw || '-';
					_hd.main.classList.toggle('none', !fw);
				}
				var cport = (j.cport != null && String(j.cport) !== '' && String(j.cport) !== '-') ? String(j.cport) : '';
				_hd.port.textContent = cport || '-';
				// HiLink reports the web address as its port; the status column shows it already
				_hd.portRow.style.display = _hd.hilink ? 'none' : '';
				var atp = _hd.atPort && _hd.atPort !== cport ? _hd.atPort : '';
				_hd.at.textContent = atp;
				_hd.atRow.style.display = atp ? '' : 'none';

				// mtemp arrives as "38°C", "38 &deg;C" or "-"
				var tn = (j.mtemp != null) ? parseFloat(String(j.mtemp)) : NaN;
				var lvl = isNaN(tn) ? -1 : (tn < 60 ? 0 : tn < 70 ? 1 : 2);
				_hd.temp.textContent = isNaN(tn) ? '' : Math.round(tn) + '°C';
				_hd.temp.className = [ 'ok', 'warn', 'bad' ][lvl] || '';
				_hd.temp.title = isNaN(tn) ? '' : _('Temperature');
			});
	},

	render: function(res) {
		modemtabs.attach();
		var json = {};
		try { json = JSON.parse(res[0] || '{}'); } catch (e) {}
		if (!json || typeof json != 'object') json = {};
		var devs = res[1] || [];
		var ledsAvail = (function() {
			var names = (res[6] || []).map(function(e) { return e.name; });
			var has = function(l) { return l.every(function(n) { return names.indexOf(n) >= 0; }); };
			if (has([ 'white:signal1', 'white:signal2', 'white:signal3' ])) { return 'bars'; }
			if (has([ 'red', 'green', 'blue' ])) { return 'rgb'; }
			return false;
		})();

		function portLabel(name) {
			return '/dev/' + name;
		}

		var protoAvail = {};
		(res[5] || []).forEach(function(f) {
			var m = (f.name || '').match(/^([a-z0-9]+)\.js$/);
			if (m) { protoAvail[m[1]] = true; }
		});
		var wdmDriver = String(res[7] || '').trim();
		if (wdmDriver !== 'cdc_mbim' && uci.get('5gmodem', '@5gmodem[0]', 'iface_proto') !== 'mbimp') {
			protoAvail['mbimp'] = false;
		}

		var m, s, o;
		m = new form.Map('5gmodem', '', '');

		var pageAlerts = [];

		/* One TypedSection must remain: savePending(), lookupOption() and the instant toggles
		   below work on its options. The groups are native section tabs. */
		s = m.section(form.TypedSection, '5gmodem', _('Connection'), null);
		s.anonymous = true;
		s.tab('ports', _('Ports and interface'));
		s.tab('apn', _('APN'));
		s.tab('net', _('Network'));
		s.tab('expert', _('For experts'));

		o = s.taboption('ports', form.Flag, 'auto_port', _('Auto-detect port and interface'),
			_('Automatically find the modem AT port and its network interface (via ModemManager when available). Turn this off to select them manually below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('ports', ListDropdown, 'network', _('Interface'),
			_('Network interface for Internet access'));
		o.depends('auto_port', '0');
		o.rmempty = true;
		/* see docs/subsystems/diagnostics.md#hidden-port-fields-must-survive-save */
		o.remove = function() { return Promise.resolve(); };
		(uci.sections('network', 'interface') || []).forEach(function(iface) {
			var nm = iface['.name'];
			if (nm && nm != 'loopback') { o.value(nm, nm + (iface.proto ? ' (' + mutil.protoLabel(iface.proto) + ')' : '')); }
		});

		o = s.taboption('ports', form.Value, 'device',
			_('Port for modem communication'),
			_("Port used to read modem/connection info: one of the available ttyUSBX ports.<br /> <br />HiLink and other modems with a web interface are found automatically and need no port."));
		devs.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* see docs/subsystems/diagnostics.md#hidden-port-fields-must-survive-save */
		o.remove = function() { return Promise.resolve(); };

		o = s.taboption('ports', form.Value, 'at_port',
			_('Port for AT / SMS / USSD'),
			_('AT command port used for SMS, USSD and AT commands. On most modems it is the same as the modem communication port.'));
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* see docs/subsystems/diagnostics.md#hidden-port-fields-must-survive-save */
		o.remove = function() { return Promise.resolve(); };
		o.write = function(section_id, value) {
			uci.set('5gmodem', section_id, 'at_port', value);
			[ 'readport', 'sendport', 'ussdport', 'atport' ].forEach(function(k) {
				uci.set('5gmodem', 'sms', k, value);
			});
		};

		var activeKind = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return ''; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') || '';
		})();
		var activeIsHilink = (activeKind === 'hilink' || activeKind === 'tether');

		if (!activeIsHilink) {
		o = s.taboption('ports', ListDropdown, 'iface_proto', _('Interface protocol'),
			_('Protocol for the "Create modem interface" button. "Auto" picks it from the modem driver (recommended). Only the protocols whose handler is installed on the router are shown. Any non-ModemManager protocol disables ModemManager (they cannot share the modem).'));
		o.value('auto', _('Auto (detect)'));
		var protoLabels = {
			'fibocom': 'Fibocom (AT-dial, FM350)',
			'mbim': 'MBIM (umbim)',
			'mbimp': 'MBIM+MM (mbimcli + ModemManager, shared proxy)',
			'qmi': 'QMI (uqmi)',
			'qmiraw': 'QMI raw-ip (uqmi, static IP from QMI)',
			'ncm': 'NCM',
			'xmm': 'XMM (Fibocom / Intel)',
			'atc': 'AT (atc)',
			'wwan': 'WWAN (auto)',
			'3g': '3G / PPP',
			'modemmanager': 'ModemManager'
		};
		[ 'fibocom', 'mbim', 'mbimp', 'qmi', 'qmiraw', 'ncm', 'xmm', 'atc', 'wwan', '3g', 'modemmanager' ].forEach(function(p) {
			if (protoAvail[p]) { o.value(p, protoLabels[p]); }
		});
		if (!protoAvail['mbim'] && !protoAvail['modemmanager']) {
			o.value('mbim', protoLabels['mbim']);
			o.value('modemmanager', protoLabels['modemmanager']);
		}
		o.default = 'auto';
		o.rmempty = false;
		o.onchange = function(ev, section_id, value) {
			if (!mutil.isMMProto(value)) { return; }
			var f = this.map.lookupOption('_mm_exclude', section_id);
			var el = f && f[0] && f[0].getUIElement(section_id);
			if (el && el.getValue() === '1') {
				el.setValue('0');
				ui.addNotification(null, E('p',
					_('“Hide from ModemManager” has been turned off: the ModemManager protocol needs MM to manage this modem')), 'info');
			}
		};
		}

		var mIfName = uci.get('5gmodem', '@5gmodem[0]', 'network') || 'modem';
		var mIfExists = !!uci.get('network', mIfName);

		var mSec = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			return p ? ('m_' + String(p).replace(/[^A-Za-z0-9]/g, '_')) : '';
		})();

		var mForeignIf = mSec ? (uci.get('5gmodem', mSec, 'foreign_iface') || '') : '';
		if (mForeignIf) {
			pageAlerts.push([
				E('strong', {}, [ _('Interface “%s” was created for a different modem').format(mForeignIf) ]), ' ',
				_('It is bound to this modem only because the kernel reused the device node, so its settings (APN in particular) may belong to the previous modem and SIM. Create the interface anew below - the APN is filled from the operator detected right now.')
			]);
		}

		var mImeiChanged = mSec ? (uci.get('5gmodem', mSec, 'imei_changed') || '') : '';
		if (mImeiChanged === '1') {
			pageAlerts.push([
				E('strong', {}, _('A different modem is now in this USB port')), ' ',
				_('Its IMEI does not match the one seen here before - the modems were probably swapped. The settings of this slot (the interface and its APN in particular) belong to the previous modem and its SIM. Check them below and create the interface anew if needed.')
			]);
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ackswap', mSec ]), null);
		}


		o = s.taboption('apn', ListDropdown, '_apn_mode', _('APN selection'));
		o.value('auto', _('Automatic (by operator)'));
		o.value('manual', _('Manual'));
		o.default = 'auto';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			if (uci.get('5gmodem', sec) == null) { uci.add('5gmodem', 'modem', sec); }
			uci.set('5gmodem', sec, 'apn_mode', value === 'manual' ? 'manual' : 'auto');
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return 'auto'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return (uci.get('5gmodem', sec, 'apn_mode') === 'manual') ? 'manual' : 'auto';
		};
		o.remove = function() {};

		var apnIsManual = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sec, 'apn_mode') === 'manual';
		};
		o = s.taboption('apn', form.Value, '_apn', _('APN'),
			_('APN for the modem interface. Auto-filled from the detected operator; you can change it. Leave empty for the provider default.'));
		o.placeholder = 'internet';
		o.rmempty = true;
		o.write = function(section_id, value) {
			if (!apnIsManual() || !mIfExists) { return; }
			var v = String(value || '').trim();
			if (v === (uci.get('network', mIfName, 'apn') || '')) { return; }
			if (v) { uci.set('network', mIfName, 'apn', v); }
			else { uci.unset('network', mIfName, 'apn'); }
		};
		o.remove = function() {
			if (!apnIsManual() || !mIfExists) { return; }
			if (uci.get('network', mIfName, 'apn') != null) {
				uci.unset('network', mIfName, 'apn');
			}
		};
		o.load = function(section_id) {
			var self = this;
			window.setTimeout(function() {
				L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/netpri.sh',
						[ 'op', mIfName, 'fresh' ]), '')
					.then(function(op) {
						op = (op || '').trim();
						if (!op) { return ''; }
						return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh',
								[ 'apnfor' ]), '').then(function(a) { return (a || '').trim(); });
					})
					.then(function(want) {
						if (!want) { return; }
						if (apnIsManual()) { return; }
						var el = self.getUIElement(section_id);
						if (!el || el.isChanged && el.isChanged()) { return; }
						var cur = (el.getValue() || '').trim();
						if (cur === want) { return; }
						el.setValue(want);
					});
			}, 0);
			return uci.get('network', mIfName, 'apn') || '';
		};

		// A ZTE web-API stick keeps its APN in its own profiles, not in the router interface
		// (that is plain DHCP): the APN tab reads and writes the stick instead (hilink.sh zteapn).
		var activePath = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
		var activeVp = activePath ? String(uci.get('5gmodem', 'm_' + activePath.replace(/[^A-Za-z0-9]/g, '_'), 'vidpid') || '') : '';
		if (activeKind === 'hilink' && /^19d2:/.test(activeVp)) {
			s.children = s.children.filter(function(c) { return c.option !== '_apn_mode' && c.option !== '_apn'; });
			o = s.taboption('apn', form.DummyValue, '_zte_apn', _('APN in the modem'),
				_('The stick keeps the APN in its own memory. "Write" saves it as the "5gmodem" profile, makes it the default and reconnects the stick; the connection drops for a few seconds.'));
			o.cfgvalue = function() { return ''; };
			o.write = function() {};
			o.remove = function() {};
			o.renderWidget = function() {
				var cur = E('div', { 'class': 'tg-modem-zapn-cur' }, [ _('Reading…') ]);
				var inp = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'internet', 'spellcheck': 'false' });
				var pdp = E('select', { 'class': 'cbi-input-select' }, [
					E('option', { 'value': 'IP' }, [ 'IPv4' ]), E('option', { 'value': 'IPv4v6' }, [ 'IPv4 + IPv6' ]) ]);
				var st = E('div', { 'class': 'tg-modem-zapn-st' }, '');
				var btnW = E('button', { 'type': 'button', 'class': 'cbi-button cbi-button-action' }, [ _('Write to the modem') ]);
				var btnA = E('button', { 'type': 'button', 'class': 'cbi-button' }, [ _("Stick's own choice") ]);
				var busy = function(on) { btnW.disabled = btnA.disabled = inp.disabled = pdp.disabled = on; };
				var want = '';
				var paint = function(d) {
					if (!d || d.mode == null) { dom.content(cur, [ _('The stick did not return its APN settings.') ]); return; }
					var auto = d.mode === 'auto';
					var shown = auto ? (d.auto_apn || '') : (d.apn || '');
					dom.content(cur, [ _('Now:') + ' ', E('b', { 'class': 'tg-modem-mono' }, [ shown || _('empty') ]),
						' · ', auto ? _("the stick's own choice") : _('profile %s').format(d.profile || '-'),
						want && want !== shown ? E('span', { 'class': 'tg-modem-zapn-hint' }, [ ' · ' + _('for this operator: %s').format(want) ]) : '' ]);
					if (!inp.value) { inp.value = want || shown || ''; }
					if (d.pdp === 'IPv4v6') { pdp.value = 'IPv4v6'; }
				};
				var reload = function() {
					return Promise.all([
						L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/hilink.sh', [ 'zteapn', 'get', activePath ]), '{}'),
						L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'apnfor' ]), '')
					]).then(function(r) {
						var d = {}; try { d = JSON.parse(r[0] || '{}'); } catch (e) {}
						want = String(r[1] || '').trim();
						paint(d);
					});
				};
				var write = function(apn) {
					busy(true);
					st.className = 'tg-modem-zapn-st';
					st.textContent = _('Writing and reconnecting the stick…');
					return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/hilink.sh', [ 'zteapn', 'set', apn, pdp.value, activePath ]), '{}').then(function(out) {
						var d = {}; try { d = JSON.parse(out || '{}'); } catch (e) {}
						st.className = 'tg-modem-zapn-st ' + (d.success ? 'ok' : 'bad');
						st.textContent = d.success ? _('Saved. The stick is reconnecting.') : _('The stick refused the APN (%s)').format(d.error || '?');
						return reload();
					}).then(function() { busy(false); }, function() { busy(false); });
				};
				btnW.addEventListener('click', function() {
					var v = String(inp.value || '').trim();
					if (!/^[A-Za-z0-9._-]+$/.test(v)) { st.className = 'tg-modem-zapn-st bad'; st.textContent = _('APN: Latin letters, digits, dots, hyphens'); return; }
					write(v);
				});
				btnA.addEventListener('click', function() { write(''); });
				window.setTimeout(reload, 0);
				return E('div', { 'class': 'tg-modem-zapn' }, [
					cur,
					E('div', { 'class': 'tg-modem-zapn-row' }, [ inp, pdp, btnW, btnA ]),
					st
				]);
			};
		}

		if (!activeIsHilink) {
		o = s.taboption('apn', ListDropdown, '_pdpauth', _('Authentication'),
			_('Needed by some virtual operators (MVNO): APN together with a login and password. Leave NONE if the operator did not give you credentials.'));
		o.value('none', 'NONE');
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.write = function(section_id, value) {
			if (!mIfExists) { return; }
			var isMM = String(uci.get('network', mIfName, 'proto') || '') === 'modemmanager';
			if (value === 'none') {
				uci.unset('network', mIfName, 'auth');
				uci.unset('network', mIfName, 'allowedauth');
			} else {
				uci.set('network', mIfName, isMM ? 'allowedauth' : 'auth', value);
			}
		};
		o.remove = function() {};
		o.load = function() {
			var v = uci.get('network', mIfName, 'auth')
				|| uci.get('network', mIfName, 'allowedauth') || '';
			v = String(v).split(/\s+/)[0].toLowerCase();
			return (v === 'pap' || v === 'chap') ? v : 'none';
		};

		o = s.taboption('apn', form.Value, '_pdpuser', _('PAP/CHAP username'));
		o.depends('_pdpauth', 'pap');
		o.depends('_pdpauth', 'chap');
		o.write = function(section_id, value) {
			if (!mIfExists) { return; }
			var v = String(value || '').trim();
			if (v) { uci.set('network', mIfName, 'username', v); }
			else { uci.unset('network', mIfName, 'username'); }
		};
		o.remove = function() { if (mIfExists) { uci.unset('network', mIfName, 'username'); } };
		o.load = function() { return uci.get('network', mIfName, 'username') || ''; };

		o = s.taboption('apn', form.Value, '_pdppass', _('PAP/CHAP password'));
		o.password = true;
		o.depends('_pdpauth', 'pap');
		o.depends('_pdpauth', 'chap');
		o.write = function(section_id, value) {
			if (!mIfExists) { return; }
			var v = String(value || '');
			if (v) { uci.set('network', mIfName, 'password', v); }
			else { uci.unset('network', mIfName, 'password'); }
		};
		o.remove = function() { if (mIfExists) { uci.unset('network', mIfName, 'password'); } };
		o.load = function() { return uci.get('network', mIfName, 'password') || ''; };
		}

		var atDebugHl = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink'
				&& /^(12d1:|19d2:1557$|19d2:0581$|19d2:0558$|19d2:0536$)/.test(String(uci.get('5gmodem', sc, 'vidpid') || '12d1:'));
		})();
		var webPassHl = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();
		if (webPassHl) {
			var webPassSection = 'm_' + activePath.replace(/[^A-Za-z0-9]/g, '_');
			var webPass = uci.get('5gmodem', webPassSection, 'web_pass_empty') === '1'
				? '' : (uci.get('5gmodem', webPassSection, 'web_pass') || undefined);
			var saveWebPass = function(action, value) {
				return fs.exec_direct('/usr/share/5gmodem/modemswitch.sh',
					[ 'webpass', activePath, action, value == null ? '' : value ]).then(function(out) {
					if (!JSON.parse(out || '{}').ok) { throw new Error(_('Could not save the modem web password.')); }
					webPass = action === 'empty' ? '' : (value || undefined);
				});
			};
			o = s.taboption('ports', ListDropdown, '_web_pass_mode', _('Modem web password'));
			o.value('default', _('Factory password'));
			o.value('empty', _('Empty password'));
			o.value('custom', _('Custom password'));
			o.rmempty = false;
			o.load = function() {
				return webPass == null ? 'default' : (webPass === '' ? 'empty' : 'custom');
			};
			o.write = function(section_id, value) {
				if (value === 'default') { return saveWebPass('set', ''); }
				if (value === 'empty') { return saveWebPass('empty'); }
			};
			o.remove = function() {};

			o = s.taboption('ports', form.Value, '_web_pass', _('Custom password'));
			o.depends('_web_pass_mode', 'custom');
			o.password = true;
			o.rmempty = false;
			o.load = function() { return webPass || ''; };
			o.write = function(section_id, value) { return saveWebPass('set', value); };
			o.remove = function() {};
		}
		if (atDebugHl) {
		o = s.taboption('expert', form.Flag, '_at_debug', _('AT ports (debug mode)'),
			_('Such a modem normally exposes only its web interface: no TAC, no band, no EARFCN, no USSD. In this mode it also shows serial ports and is driven like any other modem, keeping its network card and internet. The mode is reset when the modem reboots, so it is applied again every time the modem appears.'));
		o.default = '1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var v = value === '1' ? '1' : '0';
			if (uci.get('5gmodem', sec) == null) {
				uci.add('5gmodem', 'modem', sec);
			}
			uci.set('5gmodem', sec, 'at_debug', v);
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'atdebug', String(p), v ]).catch(function() {});
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return '1'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var v = uci.get('5gmodem', sec, 'at_debug');
			return (v === '0') ? '0' : '1';
		};
		o.remove = function() {};
		}

		o = s.taboption('expert', ListDropdown, '_esim_show', _('eSIM tab'),
			_('Detected automatically by probing the modem for an eUICC. If the probe is wrong, force the tab on or off here.'));
		o.value('auto', _('Automatically'));
		o.value('1', _('Always show'));
		o.value('0', _('Always hide'));
		o.default = 'auto';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var v = (value === '1' || value === '0') ? value : 'auto';
			return fs.exec('/usr/share/5gmodem/esim.sh', [ 'setshow', v ])
				.then(function() { return fs.exec('/usr/share/5gmodem/esim.sh', [ 'recheck' ]); })
				.catch(function() {});
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return 'auto'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var v = uci.get('5gmodem', sec, 'esim_show');
			return (v === '1' || v === '0') ? v : 'auto';
		};
		o.remove = function() {};

		var roamProto = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return ''; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			return ifn ? (uci.get('network', ifn, 'proto') || '') : '';
		})();
		var roamHilink = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();
		if (roamHilink || mutil.isMMProto(roamProto) || roamProto === 'mbim' || roamProto === 'fibocom') {
		o = s.taboption('net', form.Flag, '_roaming', _('Allow data roaming'),
			_('When off, the modem registers on the network but the data connection is not established while roaming - so no traffic is billed at roaming rates. SMS and calls are not affected.'));
		o.default = '0';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var v = (value === '1') ? '1' : '0';
			if (roamHilink) {
				return fs.exec('/usr/share/5gmodem/hilink.sh',
					[ 'setroaming', String(p), v ]).catch(function() {});
			}
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			if (!ifn) { return; }
			uci.set('network', ifn, 'allow_roaming', v);
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'roaming', String(p), v ]).catch(function() {});
		};
		o.load = function(section_id) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return '0'; }
			if (roamHilink) {
				var self = this;
				window.setTimeout(function() {
					L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/hilink.sh',
							[ 'getroaming', String(p) ]), '0')
						.then(function(out) {
							var v = String(out).trim() === '1' ? '1' : '0';
							var el = self.getUIElement(section_id);
							if (el && !(el.isChanged && el.isChanged())) { el.setValue(v); _instLast['_roaming'] = v; }
						});
				}, 0);
				return '0';
			}
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			return (ifn && uci.get('network', ifn, 'allow_roaming') === '1') ? '1' : '0';
		};
		o.remove = function() {};
		}

		var ipwIf = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			var sc = p ? 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_') : '';
			return (sc && uci.get('5gmodem', sc, 'network'))
			       || uci.get('5gmodem', '@5gmodem[0]', 'network') || '';
		})();
		// Unisoc-based Fibocom modules: the module routes by itself, so the address watcher does not
		// apply; instead they can hand the operator address straight to the router (bridge)
		var uniMod = /^2cb7:0a0[4-7]$/.test(activeVp);
		if (ipwIf && roamProto === 'fibocom' && uniMod) {
		o = s.taboption('net', form.Flag, '_ippass', _('Bridge mode (IP pass-through)'),
			_('The modem gives the router the operator address instead of its own private one, so there is no double NAT. The setting is stored in the modem; the connection is re-established when it changes.'));
		o.default = '0';
		o.rmempty = false;
		o.load = function() {
			return uci.get('network', ipwIf, 'ippass') === '1' ? '1' : '0';
		};
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var v = (value === '1') ? '1' : '0';
			var cur = uci.get('network', ipwIf, 'ippass');
			// never ticked and still off: leave the modem's own setting alone
			if (cur === v || (cur == null && v === '0')) { return; }
			uci.set('network', ipwIf, 'ippass', v);
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'ippass', String(p), v ]).catch(function() {});
		};
		o.remove = function() {};
		}

		if (ipwIf && roamProto === 'fibocom' && !uniMod) {
		o = s.taboption('net', form.Flag, '_ipwatch', _('Follow network address changes'),
			_('Checks the data session every few seconds. When the operator drops the session or assigns a new address (for example, a forced reconnect every few hours), the interface reconnects and takes the new address.'));
		o.default = '0';
		o.rmempty = false;
		o.load = function() {
			return uci.get('network', ipwIf, 'ipwatch') === '1' ? '1' : '0';
		};
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var v = (value === '1') ? '1' : '0';
			if (v === '1') { uci.set('network', ipwIf, 'ipwatch', '1'); }
			else { uci.unset('network', ipwIf, 'ipwatch'); }
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'ipwatch', String(p), v ]).catch(function() {});
		};
		o.remove = function() {};
		}

		if (!activeIsHilink) {
		var nsView = this;
		o = s.taboption('net', form.DummyValue, '_netsel', _('Network selection'),
			_('Pick the operator network by hand instead of letting the modem choose. The search takes 1-3 minutes.'));
		o.cfgvalue = function() { return ''; };
		o.write = function() {};
		o.remove = function() {};
		o.renderWidget = function() { return nsView.renderNetsel(); };
		}

		o = s.taboption('expert', form.Flag, '_mm_exclude', _('Hide from ModemManager'),
			_('ModemManager and a kernel protocol (QMI/MBIM) cannot share one modem: MM grabs the control channel and the interface gets no IP. Enabled by default for such protocols. Turn it off to hand the modem to ModemManager (its band/mode control is richer on some modems) - then use the ModemManager protocol for it.'));
		o.default = '1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			if (!mSec) { return Promise.resolve(); }
			return fs.exec('/usr/share/5gmodem/mm-inhibit.sh',
				[ 'set-exclude', mSec, String(value) === '1' ? '1' : '0' ]);
		};
		o.remove = function() { return Promise.resolve(); };
		o.load = function(section_id) {
			if (!mSec) { return '1'; }
			var v = uci.get('5gmodem', mSec, 'mm_exclude');
			if (v === '0' || v === '1') { return v; }
			var p = String(uci.get('network', mIfName, 'proto') || '');
			return (p && !mutil.isMMProto(p)) ? '1' : '0';
		};

		if (mutil.isMMProto(uci.get('network', mIfName, 'proto'))) {
		o = s.taboption('expert', form.Flag, '_mm_at', _('AT polling under ModemManager'),
			_('Read temperature, carrier aggregation and other vendor metrics over the AT port while ModemManager drives the modem. Off by default for firmware known to drop the data session on a parallel AT exchange (Dell DW5821e / Foxconn T77W968); other modems are polled only while the session is up. A DW5821e with two AT ports does not need this switch: after a reboot its second port is kept away from ModemManager and polled automatically. Enable only if the link stays stable with the page open.'));
		o.default = '0';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return Promise.resolve(); }
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'mmat', String(p), String(value) === '1' ? '1' : '0' ]);
		};
		o.remove = function() { return Promise.resolve(); };
		o.load = function(section_id) {
			if (!mSec) { return '0'; }
			return uci.get('5gmodem', mSec, 'mm_at') === '1' ? '1' : '0';
		};
		}

		if (!activeIsHilink) {
		o = s.taboption('expert', form.Flag, '_no_at', _('No background AT polling'),
			_('Stop all automatic AT exchange with this modem: metrics polling, the periodic SMS check, Telegram forwarding, SMS commands and archiving. Temperature, carrier aggregation and automatic SMS reception are lost; reading and sending SMS, USSD and the AT console still work when you use them. For firmware whose data session freezes more often while it is polled over AT (e.g. Quectel RM551E-GL).'));
		o.default = '0';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return Promise.resolve(); }
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'noat', String(p), String(value) === '1' ? '1' : '0' ]);
		};
		o.remove = function() { return Promise.resolve(); };
		o.load = function(section_id) {
			if (!mSec) { return '0'; }
			return uci.get('5gmodem', mSec, 'no_at') === '1' ? '1' : '0';
		};
		}

		if (!activeIsHilink) {
		o = s.taboption('apn', ListDropdown, '_pdptype', _('IP type'),
			_('IP type for the modem interface. IPv4 is the default: on most networks/modems a dual-stack (IPv4/IPv6) context registers but never gets an address, while IPv4 gets one immediately. Switch to "IPv4 and IPv6" only if you need IPv6 and the modem supports it.'));
		o.value('ipv4', _('IPv4 only (recommended)'));
		o.value('ipv4v6', _('IPv4 and IPv6'));
		o.write = function(section_id, value) {
			if (!mIfExists) { return; }
			var proto = String(uci.get('network', mIfName, 'proto') || '');
			var v6 = (String(value) === 'ipv4v6');
			var opt, val;
			if (proto === 'xmm' || proto === 'atc') { opt = 'pdp'; val = v6 ? 'IPV4V6' : 'IP'; }
			else if (proto === 'modemmanager') { opt = 'iptype'; val = v6 ? 'ipv4v6' : 'ipv4'; }
			else if (proto === 'fibocom') { opt = 'pdptype'; val = v6 ? 'IPV4V6' : 'IPV4'; }
			else { opt = 'pdptype'; val = v6 ? 'ipv4v6' : 'ipv4'; }
			var _socmm = /^qcom-soc$|\.remoteproc$/.test(String(uci.get('network', mIfName, 'device') || ''))
				|| /\.remoteproc$/.test(String(uci.get('network', mIfName, 'modem_path') || ''));
			if (proto === 'modemmanager' && v6 && !_socmm && !uci.get('network', mIfName, 'init_epsbearer')) {
				uci.set('network', mIfName, 'init_epsbearer', 'default');
			}
			if ((uci.get('network', mIfName, opt) || '') === val) { return; }
			uci.set('network', mIfName, opt, val);
		};
		o.remove = function() {};
		o.load = function(section_id) {
			var v = uci.get('network', mIfName, 'pdptype')
				|| uci.get('network', mIfName, 'iptype')
				|| uci.get('network', mIfName, 'pdp') || '';
			return (String(v).toLowerCase() === 'ipv4v6') ? 'ipv4v6' : 'ipv4';
		};
		}

		if (!activeIsHilink) {
		o = s.taboption('apn', form.Flag, '_dns_fallback', _('Fallback DNS'),
			_('Some operators/modems bring the modem up without DNS servers: you get an IP but sites do not open. Turn this on and enter the DNS servers below to add them to the modem interface, on top of the operator DNS if it was provided. Off by default. When the carrier restricts traffic to a whitelist, foreign DNS servers (8.8.8.8, 1.1.1.1) are blocked and nothing resolves - use 77.88.8.8 77.88.8.1.'));
		o.default = '0';
		o.rmempty = false;
		var dnsApplied = null;
		var dnsCur = function() {
			if (dnsApplied != null) { return dnsApplied; }
			var d = mIfName ? uci.get('network', mIfName, 'dns') : null;
			if (Array.isArray(d)) { d = d.join(' '); }
			return String(d || '').trim().replace(/\s+/g, ' ');
		};
		var dnsApply = function(p, on, srv) {
			var target = (on && srv) ? srv.replace(/\s+/g, ' ') : '';
			if (target === dnsCur()) { return Promise.resolve(); }
			var prev = dnsApplied;
			dnsApplied = target;
			return fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'dnsfb', String(p), target ? '1' : '0', target ]).catch(function() { dnsApplied = prev; });
		};
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var on = (value === '1');
			var so = this.map.lookupOption('_dns_servers', section_id);
			var srv = (on && so) ? String(so[0].formvalue(section_id) || '').trim() : '';
			return dnsApply(p, on, srv);
		};
		o.load = function(section_id) {
			return (dnsCur() !== '') ? '1' : '0';
		};
		o.remove = function() {};

		o = s.taboption('apn', form.Value, '_dns_servers', _('DNS servers'),
			_('Space-separated, e.g. "77.88.8.8 77.88.8.1".'));
		o.depends('_dns_fallback', '1');
		o.placeholder = '77.88.8.8 77.88.8.1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var fo = this.map.lookupOption('_dns_fallback', section_id);
			var on = fo ? (String(fo[0].formvalue(section_id)) === '1') : false;
			var srv = on ? String(value || '').trim() : '';
			return dnsApply(p, on, srv);
		};
		o.load = function(section_id) {
			return dnsCur();
		};
		o.remove = function() {};
		}

		/* The interface button is not a form option: a TypedSection with tabs renders only options
		   that sit in a tab, and the action belongs under the tabs and in the header card. */
		var mkLabel = activeIsHilink
			? ((activeKind === 'tether')
				? (mIfExists ? _('Recreate interface (USB tethering)') : _('Create interface (USB tethering)'))
				: (mIfExists ? _('Recreate interface (HiLink DHCP)') : _('Create interface (HiLink DHCP)')))
			: (mIfExists ? _('Recreate modem interface') : _('Create modem interface'));
		var mkDesc = activeIsHilink
			? ((activeKind === 'tether')
				? _('This phone shares the internet over USB and hands out an address over DHCP. The button creates (or recreates) that DHCP interface - there is no dial-up protocol to choose, and no modem metrics to read.')
				: _('This modem holds the connection itself and hands out an address over DHCP on its own network card. The button creates (or recreates) that DHCP interface - there is no dial-up protocol to choose.'))
			: _('Create (or switch) the modem network interface using the protocol chosen above. Switching to MBIM disables ModemManager; switching to ModemManager enables it (they cannot share the modem).');
		var mkHilink = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return savePending(m).then(function() {
				return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mkhilink' ]);
			}).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.success) {
					ui.addNotification(null, E('p', [ _('Interface "%s" created (DHCP on %s), bringing it up…').format(out.iface, out.netdev) ]), 'info');
					if (profilesView) { profilesView.loadProfiles(); }
				} else {
					ui.addNotification(null, E('p', _('No HiLink network card found to create an interface for')), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', [ _('Failed to create the modem interface') + ': ' + (err.message || err) ]), 'error');
			});
		};
		var mkIface = function() {
			var sid = null;
			var ss = uci.sections('5gmodem', '5gmodem');
			if (ss && ss[0]) { sid = ss[0]['.name']; }
			var proto = 'auto';
			try {
				var opt = m.lookupOption('iface_proto', sid);
				if (opt && opt[0]) { var el = opt[0].getUIElement(sid); if (el) { proto = el.getValue() || 'auto'; } }
			} catch (e) {}
			var apn = '';
			try {
				var aopt = m.lookupOption('_apn', sid);
				if (aopt && aopt[0]) { var ael = aopt[0].getUIElement(sid); if (ael) { apn = (ael.getValue() || '').trim(); } }
			} catch (e) {}
			var apnArg = apn || '-';
			var pdp = 'ipv4';
			try {
				var popt = m.lookupOption('_pdptype', sid);
				if (popt && popt[0]) { var pel = popt[0].getUIElement(sid); if (pel) { pdp = pel.getValue() || 'ipv4'; } }
			} catch (e) {}
			var mmArg = '-';
			try {
				var mopt = m.lookupOption('_mm_exclude', sid);
				if (mopt && mopt[0]) { var mel = mopt[0].getUIElement(sid);
					if (mel) { var mv = String(mel.getValue()); if (mv === '0' || mv === '1') { mmArg = mv; } } }
			} catch (e) {}
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return savePending(m).then(function() {
				return fs.exec('/usr/share/5gmodem/mkiface.sh', [ 'modem', proto, apnArg, pdp, mmArg, 'user' ]);
			}).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.result == 'created') {
					ui.addNotification(null, E('p', [ _('Interface "%s" created (%s), bringing it up…').format(out.iface, mutil.protoLabel(out.proto)) ]), 'info');
					if (_hd && out.proto) { _hd.proto.textContent = mutil.protoLabel(out.proto); _hd.proto.style.display = ''; }
					if (_hd && out.iface) { _hd.ifName = out.iface; setHeadTech(); }
					if (profilesView) { profilesView.loadProfiles(); }
				} else {
					var _mkWhy = (out.result && out.result !== 'created')
						? _('backend said "%s" for protocol "%s"').format(out.result, mutil.protoLabel(out.proto) || '?')
						: ((res && res.stderr) ? String(res.stderr).slice(0, 200) : _('empty backend reply'));
					ui.addNotification(null, E('p', [ _('Failed to create the modem interface') + ': ' + _mkWhy + '. ' +
						_('Details are in the system log (logread, tag 5gmodem).') ]), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', [ _('Failed to create the modem interface') + ': ' + (err.message || err) ]), 'error');
			});
		};
		var doMkIface = function() { return activeIsHilink ? mkHilink() : mkIface(); };
		var mkBtn = function() {
			return E('button', {
				'class': 'cbi-button cbi-button-action',
				'click': ui.createHandlerFn(this, doMkIface)
			}, [ icon('refresh', 15), mkLabel ]);
		};

		o = s.taboption('expert', form.Button, '_forget');
		o.title = _('Disconnected modems');
		o.description = _('Remove settings and interfaces remembered for modems that are no longer connected, including modems replaced in the same slot. The next modem then gets the lowest free interface name.');
		o.inputtitle = _('Forget disconnected modems');
		o.inputstyle = 'remove';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Removing…')));
			return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'forget' ]).then(function(res) {
				ui.hideModal();
				var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				var n = parseInt(d.forgotten, 10) || 0;
				ui.addNotification(null, E('p', n
					? _('Forgotten modems: %d').format(n)
					: _('Nothing to forget: every remembered modem is connected')), 'info');
				if (n) { window.setTimeout(function() { window.location.reload(); }, 1200); }
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', [ _('Failed to forget disconnected modems') + ': ' + (err.message || err) ]), 'error');
			});
		};

		var collectDesc = _('Collects settings, modem ports, AT command output, ModemManager and eSIM state, and system logs into one text file and downloads it. Attach it to a bug report. The file contains modem and SIM identifiers (IMEI, IMSI, ICCID, EID) and the operator name; it does not contain passwords or Wi-Fi keys.');
		var COLLECT_STEPS = {
			start:  _('starting'),
			system: _('system'),
			config: _('configuration'),
			usb:    _('USB and ports'),
			mm:     _('ModemManager'),
			at:     _('AT query'),
			sim:    _('SIM'),
			esim:   _('eSIM (may take a minute)'),
			net:    _('network and logs'),
			done:   _('done')
		};
		var collectStepText = function(raw) {
			raw = String(raw || '').trim();
			if (!raw) { return ''; }
			var m = raw.match(/^(\d+)\/(\d+)\s+(\S+)$/);
			if (!m) { return COLLECT_STEPS[raw] || raw; }
			var name = COLLECT_STEPS[m[3]] || m[3];
			return '(' + m[1] + '/' + m[2] + ') ' + name;
		};

		// "Anonymous": collect.sh masks the identifiers in the finished report; the choice is remembered
		var anonBox = E('input', { 'type': 'checkbox', 'id': 'diag-anon', 'change': function() {
			try { window.localStorage.setItem('5gmodem.diag.anon', anonBox.checked ? '1' : '0'); } catch (e) {}
		} });
		try { anonBox.checked = window.localStorage.getItem('5gmodem.diag.anon') === '1'; } catch (e) {}
		var runCollect = function() {
			var msg = E('p', { 'class': 'spinning' }, _('Collecting logs…'));
			var barFill = E('div', { 'class': 'tg-mbar-fill', 'style': 'width:3%;background:var(--tg-accent)' });
			ui.showModal(_('Diagnostic report'), [ msg,
				E('div', { 'class': 'tg-mbar tg-modem-progress' }, E('div', { 'class': 'tg-mbar-t' }, barFill)) ]);

			var poll = function(tries) {
				return fs.exec('/usr/share/5gmodem/collect.sh', [ 'status' ]).then(function(res) {
					var st = {}; try { st = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
					if (st.state === 'running') {
						if (tries > 180) { throw new Error(_('Timed out')); }
						msg.textContent = _('Collecting logs…') + ' ' + collectStepText(st.progress);
						var pm = String(st.progress || '').match(/^(\d+)\/(\d+)/);
						if (pm && +pm[2] > 0) { barFill.style.width = Math.max(3, Math.round(100 * pm[1] / pm[2])) + '%'; }
						return new Promise(function(resolve) {
							window.setTimeout(function() { resolve(poll(tries + 1)); }, 2000);
						});
					}
					if (st.state !== 'done') { throw new Error(_('Collecting logs failed')); }
					return fs.read_direct('/tmp/5gmodem/diag.txt', 'blob');
				});
			};

			return fs.exec('/usr/share/5gmodem/collect.sh', anonBox.checked ? [ 'start', 'anon' ] : [ 'start' ]).then(function() {
				return poll(0);
			}).then(function(blob) {
				var d = new Date();
				var stamp = d.getFullYear()
					+ ('0' + (d.getMonth() + 1)).slice(-2)
					+ ('0' + d.getDate()).slice(-2)
					+ '-' + ('0' + d.getHours()).slice(-2)
					+ ('0' + d.getMinutes()).slice(-2);
				var url = window.URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': '5gmodem-diag-' + stamp + (anonBox.checked ? '-anon' : '') + '.txt' });
				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);
				window.setTimeout(function() { window.URL.revokeObjectURL(url); }, 5000);
				ui.hideModal();
				ui.addNotification(null, E('p', _('The report has been downloaded. Attach it to your bug report.')), 'info');
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', [ _('Collecting logs failed') + ': ' + (err.message || err) ]), 'error');
			});
		};

		/* ---------- header card (filled by fillModemInfo and fillProfiles) ---------- */
		var view = this;
		var activeModel = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return ''; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'model') || '';
		})();
		_hd = {
			name: E('span', {}, activeModel || _('Modem')),
			vidpid: E('span', { 'class': 'tginfo-vidpid', 'title': _('USB vendor and product ID'), 'style': 'display:none' }, ''),
			proto: E('span', { 'class': 'tg-proto-badge', 'title': _('Protocol'), 'style': 'display:none' }, ''),
			ico: E('div', { 'class': 'tginfo-signal tg-modem-ico off' }),
			temp: E('medium', {}, ''),
			reg: E('div', { 'class': 'tginfo-reg' }, _('Firmware')),
			main: E('div', { 'class': 'tginfo-op tg-modem-main none' }, _('Loading…')),
			usb: E('div', { 'class': 'tginfo-loc' }, ''),
			tech: E('div', { 'class': 'tginfo-tech' }, ''),
			port: E('span', { 'class': 'tg-modem-mono' }, '-'),
			at: E('span', { 'class': 'tg-modem-mono' }, ''),
			apn: E('span', { 'class': 'tg-modem-mono' }, ''),
			apnMode: E('span', { 'class': 'tg-modem-sub' }, ''),
			hilink: activeIsHilink,
			ifName: mIfExists ? mIfName : '',
			atPort: uci.get('5gmodem', '@5gmodem[0]', 'at_port') || '',
			haveName: false
		};
		_hd.ico.innerHTML = svg('chip', 36);
		_hd.ico.appendChild(_hd.temp);
		_hd.portRow = E('div', { 'class': 'tginfo-ip' }, [ E('span', { 'class': 'tginfo-iplabel' }, _('Port') + ':'), _hd.port ]);
		_hd.atRow = E('div', { 'class': 'tginfo-ip', 'title': _('Port for AT / SMS / USSD'), 'style': 'display:none' },
			[ E('span', { 'class': 'tginfo-iplabel' }, 'AT:'), _hd.at ]);
		_hd.apnRow = E('div', { 'class': 'tginfo-ip' }, [ E('span', { 'class': 'tginfo-iplabel' }, 'APN:'), _hd.apn, ' ', _hd.apnMode ]);
		_hd.portRow.style.display = activeIsHilink ? 'none' : '';
		if (mIfExists) {
			var apnSet = uci.get('network', mIfName, 'apn') || '';
			_hd.apn.textContent = apnSet || _('default');
			_hd.apn.className = apnSet ? 'tg-modem-mono' : '';
			_hd.apnMode.textContent = '· ' + (apnIsManual() ? _('Manual') : _('Automatic (by operator)')).toLowerCase();
		}
		_hd.apnRow.style.display = (mIfExists && !activeIsHilink) ? '' : 'none';
		setHeadTech();
		_hd.title = _hd.name;
		var head = E('div', { 'class': 'cbi-section tg5g tg-pg-head tg-modem-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-modem-title' }, [ _hd.name, _hd.vidpid, _hd.proto ]),
			E('div', { 'class': 'tginfo-general' }, [
				_hd.ico,
				E('div', { 'class': 'tginfo-status' }, [ _hd.reg, _hd.main, _hd.usb ]),
				E('div', { 'class': 'tginfo-info' }, [ _hd.tech, _hd.portRow, _hd.atRow, _hd.apnRow ])
			])
		]);
		_hd.root = head;

		var alertBox = function(parts) {
			return E('div', { 'class': 'alert-message warning tg-modem-alert' }, [
				icon('warn', 17),
				E('div', {}, parts),
				E('div', { 'class': 'tg-modem-alertact' }, [ mkBtn() ])
			]);
		};
		var alerts = pageAlerts.map(alertBox);

		/* ---------- diagnostics ---------- */
		var tool = function(label, cmd, btnLabel, handler) {
			return E('div', { 'class': 'tg-hist-card' }, [
				E('div', { 'class': 'tg-hist-h' }, E('span', { 'class': 'tg-hist-name' }, E('b', {}, label))),
				E('code', { 'class': 'tg-modem-cmd' }, '$ ' + cmd),
				E('span', { 'class': 'diag-action' }, [
					E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(view, handler) }, [ btnLabel ])
				])
			]);
		};
		var diagBlk = collapsible('mdiag', _('Diagnostics'), [
			E('div', { 'class': 'tg-modem-report' }, [
				icon('file', 22),
				E('div', {}, [ E('b', {}, _('Diagnostic report')), E('span', {}, collectDesc) ]),
				E('div', { 'class': 'tg-modem-reportact' }, [
					E('label', { 'for': 'diag-anon', 'title': _('Masks IMEI, IMSI, ICCID, EID, serial and phone numbers, the public IP and MAC addresses of the router and coordinates. The first digits stay: they name the modem model and the operator.') },
						[ anonBox, E('span', {}, [ _('Anonymous') ]) ]),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, runCollect)
					}, [ icon('down', 15), _('Collect logs') ])
				])
			]),
			E('div', { 'class': 'tg-modem-tools' }, [
				tool(_('USB debug information'), 'cat /sys/kernel/debug/usb/devices', _('Show devices'), 'handleUSB'),
				tool(_('Check availability of ttyX ports'), 'ls /dev', _('Show devices'), 'handleTTY'),
				tool(_('Check data read by the 5gmodem scripts'), 'sh -x /usr/share/5gmodem/5gmodem.sh', _('Debug'), 'handleDBG')
			]),
			E('div', { 'id': 'pre', 'class': 'tg-code tg-modem-out', 'style': 'display:none' }, [
				E('div', { 'class': 'tg-code-lang' }, [
					E('span', {}, 'bash'),
					E('span', { 'class': 'tg-modem-outact' }, [
						E('button', {
							'class': 'cbi-button',
							'id': 'clear',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, 'handleClear')
						}, [ _('Clear') ]),
						E('button', {
							'class': 'cbi-button',
							'id': 'download',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, 'handleDownload')
						}, [ icon('down', 14), _('Download') ])
					])
				]),
				E('pre', { 'id': 'preout', 'class': 'tg-code-body' }, [])
			])
		], !(window.matchMedia && window.matchMedia(PHONE_MQ).matches));
		var _instant = { '_roaming': 1, '_ipwatch': 1, '_ippass': 1, '_mm_exclude': 1, '_mm_at': 1, '_no_at': 1, '_at_debug': 1, '_esim_show': 1 };
		var _instLast = {};
		(s.children || []).forEach(function(o) {
			if (!o || !_instant[o.option]) { return; }
			var name = o.option, rawWrite = o.write, rawLoad = o.load;
			o.load = function(section_id) {
				if (_instLast[name] != null) { return _instLast[name]; }
				return rawLoad.call(this, section_id);
			};
			o.write = function(section_id, value) {
				var v = String(value);
				var known = (_instLast[name] != null) ? _instLast[name] : this.cfgvalue(section_id);
				if (known != null && String(known) === v) { return Promise.resolve(); }
				return Promise.resolve(rawWrite.call(this, section_id, value)).then(function(r) {
					_instLast[name] = v;
					return r;
				});
			};
			var prev = o.onchange;
			o.onchange = function(ev, section_id, value) {
				var opt = this;
				var chain = prev ? Promise.resolve(prev.call(opt, ev, section_id, value))
				                 : Promise.resolve();
				return chain
					.then(function() { return opt.write(section_id, opt.formvalue(section_id)); })
					.catch(function() {});
			};
		});

		var ledsBlock = this.renderLeds(ledsAvail);
		var antennaBlock = E('div', { 'id': 'antenna-slot' });
		var self = this;

		// The action row sits inside the form card, under the tabs. Map.save() re-renders the map
		// (renderContents), so the row is put back after every render.
		var formAct = E('div', { 'class': 'tg-modem-formact' }, [ mkBtn(), E('span', { 'class': 'cbi-section-descr' }, mkDesc) ]);
		var placeFormAct = function(node) {
			var sec = node && node.querySelector ? node.querySelector('.cbi-section') : null;
			if (sec && formAct.parentNode !== sec) { sec.appendChild(formAct); }
			return node;
		};
		var rawRC = m.renderContents;
		if (typeof rawRC === 'function') {
			m.renderContents = function() {
				return Promise.resolve(rawRC.apply(this, arguments)).then(placeFormAct);
			};
		}

		return Promise.resolve(m.render()).then(function(formNode) {
			placeFormAct(formNode);
			if (!formAct.parentNode) { formNode.appendChild(formAct); }
			return E('div', { 'class': 'tg-modem' }, [
				head
			].concat(alerts).concat([
				self.renderProfiles(),
				E('div', { 'class': 'tg-modem-form' }, [ formNode ]),
				E('div', { 'class': 'tg-modem-pair' }, [ ledsBlock, antennaBlock ]),
				diagBlk.node
			]));
		}).then(function(node) {
			window.setTimeout(function() {
				self.fillModemInfo();
				self.fillPortLabels();
				self.fillAntenna();
			}, 0);
			return node;
		});
	}
});
