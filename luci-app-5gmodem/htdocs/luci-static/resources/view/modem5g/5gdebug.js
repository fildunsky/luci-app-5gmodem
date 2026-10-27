'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require dom';
'require fs';
'require ui';
'require uci';
'require form';
'require tools.widgets as widgets';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/


var profilesView = null;

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
		return fresh.check(30901, [ modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
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
			L.resolveDefault(fs.list('/sys/class/leds'), [])
		]);
	},

	renderProfiles: function() {
				var box = E('div', { 'id': 'mprof-box' }, [
			E('div', { 'id': 'mprof-warn' }),
			E('div', {
				'id': 'mprof-list',
				'style': 'display:flex; flex-wrap:wrap; gap:.6em; margin-bottom:.4em'
			}, [ E('span', { 'style': 'opacity:.6' }, _('Loading…')) ]),
			E('div', { 'id': 'mprof-mm', 'style': 'margin-top:.5em' })
		]);
		profilesView = this;
		this.loadProfiles();
		return E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, _('Saved modem profiles')),
			box
		]);
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
			var mmcol = run ? '#5cb85c' : '#d9534f';
			mmrow.appendChild(E('span', {
				'style': 'display:inline-flex;align-items:center;gap:.45em;'
			}, [
				E('span', {
					'style': 'display:block;width:5px;height:5px;border-radius:50%;' +
						'flex:0 0 auto;box-sizing:border-box;' +
						'border:1px solid ' + mmcol + ';background:' + mmcol + ';' +
						'box-shadow:0 0 4px 1px ' + mmcol + ';'
				}),
				E('span', { 'style': 'opacity:.75; font-size:88%' },
					run ? _('ModemManager is running')
					    : _('ModemManager is stopped — no connected modem needs it'))
			]));
		}
		var warn = document.getElementById('mprof-warn');
		var box = document.getElementById('mprof-list');
		if (!box) { return; }

		if (warn && pw && pw.suspect) {
			warn.innerHTML = '';
			var mA = parseInt(pw.total_ma, 10) || 0;
			warn.appendChild(E('div', {
				'class': 'alert-message warning',
				'style': 'margin-bottom:.6em'
			}, [
				E('div', {}, [
					E('strong', {}, _('Not enough power?') + ' '),
					_('%d modems request %d mA. Such a modem answers AT commands, but its interface stays down — a powered USB hub helps.')
						.format(parseInt(pw.modems, 10) || 0, mA)
				])
			]));
		} else if (warn) { warn.innerHTML = ''; }

		box.innerHTML = '';
		if (!list.length) {
			box.appendChild(E('span', { 'style': 'opacity:.6' }, _('No modems seen yet')));
			return;
		}
		var self = this;

		var marksOf = function(p) {
			var out = [];
			if (p.celllock) {
				var cl = String(p.celllock).split(' ');
				out.push({ txt: cl[0] === 'cell'
					? _('locked to cell %s/%s').format(cl[1], cl[2])
					: _('locked to frequency %s').format(cl[1]), color: '#d9534f' });
			}
			var isMM = mutil.isMMProto(p.proto);
			if (p.mm_exclude === '0' && !isMM && p.proto) {
				out.push({ txt: _('visible to ModemManager'), color: '#e58a00' });
			} else if (p.mm_exclude === '1' && isMM) {
				out.push({ txt: _('hidden from ModemManager'), color: '#e58a00' });
			}
			return out;
		};
		var anyMarks = list.some(function(p) { return marksOf(p).length > 0; });
		var mmRunning = !!(mm && mm.running == 1);
		var lowPower = ' ' + String((pw && pw.paths) || '') + ' ';
		list.forEach(function(p) {
			var st = 'flex:1 1 18em; min-width:16em; text-align:left; padding:.6em .8em; ' +
				'border-radius:8px; cursor:default;';
			if (p.active) { st += 'border-color:var(--proton-accent,#3a7bd5);'; }
			if (!p.present) { st += 'opacity:.6;'; }
			var isLow = lowPower.indexOf(' ' + p.path + ' ') >= 0;

			var head = E('div', {
				'style': 'border-bottom:1px solid currentColor; padding-bottom:.4em;'
			}, [
				E('div', { 'class': 'mprof-head' }, [
					E('div', { 'style': 'min-width:0' }, [
						E('strong', { 'class': 'mprof-name' }, [ p.model || p.path ]),
						p.vidpid ? E('div', {
							'class': 'mprof-name',
							'style': 'font-size:78%; opacity:.55; margin-top:-.15em'
						}, [ p.vidpid ]) : ''
					]),
					E('div', { 'style': 'display:flex; flex-direction:column; align-items:flex-end; gap:.1em; white-space:nowrap' }, [
						E('span', { 'style': 'font-size:85%; opacity:.8' },
							p.present ? _('connected') : _('not connected')),
						(p.kind === 'hilink' && p.webaddr) ? E('a', {
							'href': 'http://' + p.webaddr + '/html/home.html',
							'target': '_blank', 'rel': 'noreferrer',
							'style': 'font-size:78%; opacity:.7'
						}, [ p.webaddr ]) : ''
					])
				])
			]);
			head.style.borderBottomColor = 'rgba(128,128,128,.35)';

			var protoNice = mutil.protoLabel(p.proto) || '—';
			var isHilink = (p.kind === 'hilink');
			if (isHilink) { protoNice = 'HiLink'; }
			var pdpNice = '';
			if (p.pdptype) {
				pdpNice = ({
					'ipv4v6': 'IPv4v6', 'ipv4': 'IPv4', 'ipv6': 'IPv6'
				})[String(p.pdptype).toLowerCase()] || p.pdptype;
			}

			var card = E('div', {
				'class': 'btn cbi-button mprof-card' + (isLow ? ' mprof-lowpower' : ''),
				'title': isLow ? _('the data interface did not come up — not enough power?') : '',
				'style': st
			}, [
				head,
				E('div', { 'class': 'mprof-line', 'style': 'margin-top:.45em' }, [
					E('span', { 'class': 'mprof-if' }, [ p.iface || _('no interface') ]),
					E('span', {}, [
						E('strong', {}, 'APN:'), ' ',
						p.apn || _('default')
					])
				]),
				E('div', { 'class': 'mprof-line' }, [
					E('span', { 'style': 'display:flex; align-items:baseline; gap:.6em; min-width:0' }, [
						E('span', { 'class': 'mprof-proto' }, [
							mmRunning && p.mm_exclude === '1' ? E('img', {
								'src': mutil.icon('icons/5gmodem/cghost.svg'),
								'width': 12, 'height': 12, 'alt': '',
								'title': _('hidden from ModemManager'),
								'style': 'margin-right:.3em; opacity:.75; flex:0 0 auto'
							}) : '',
							protoNice
						]),
						p.esim ? E('span', {
							'style': 'opacity:.8',
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
					E('span', { 'style': 'opacity:.8; flex:0 0 auto' }, [ pdpNice ])
				])
			]);

			var marks = marksOf(p);
			if (marks.length) {
				var mrow = E('div', { 'style': 'font-size:80%; margin-top:.3em' }, []);
				marks.forEach(function(m, i) {
					if (i) { mrow.appendChild(document.createTextNode(' · ')); }
					mrow.appendChild(E('span', { 'style': 'color:' + m.color }, [ m.txt ]));
				});
				card.appendChild(mrow);
			} else if (anyMarks) {
				card.appendChild(E('div', {
					'style': 'font-size:80%; margin-top:.3em; visibility:hidden'
				}, '\u00a0'));
			}

			if (p.iface_shared) {
				card.appendChild(E('div', {
					'style': 'font-size:80%; color:#e58a00; margin-top:.3em'
				}, [ _('shares interface %s with another profile').format(p.iface) ]));
			}

			var savedBands = (function() {
				var parts = [];
				var add = function(list, pfx, label) {
					if (!list) return;
					var bs = String(list).trim().split(/\s+/).filter(function(b) {
						return (/^[0-9]+$/).test(b);
					});
					if (bs.length) {
						parts.push({ label: label, bands: bs.map(function(b) { return pfx + b; }).join(' ') });
					}
				};
				add(p.save_band, 'B', '4G');
				add(p.save_band5gnsa, 'n', '5G NSA');
				add(p.save_band5gsa, 'n', '5G SA');
				return parts;
			})();
			if (savedBands.length) {
				var sbWrap = E('div', {
					'style': 'font-size:72%; opacity:.55; margin:1em 0 .5em; line-height:1.4; word-break:break-word'
				}, [ E('div', {}, E('strong', {}, _('Saved bands') + ':')) ]);
				savedBands.forEach(function(part) {
					sbWrap.appendChild(E('div', {}, [ E('strong', {}, part.label), ' ' + part.bands ]));
				});
				card.appendChild(sbWrap);
			}

			card.appendChild(E('div', { 'class': 'mprof-foot' }, [
				E('div', { 'style': 'font-size:80%; opacity:.6; line-height:1.5' }, [
					p.imei ? ('IMEI ' + p.imei) : _('IMEI unknown'), E('br'),
					p.path
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'style': 'margin-left:0; flex:0 0 auto',
					'click': ui.createHandlerFn(this, function() {
						return self.confirmDelete(p);
					})
				}, _('Delete'))
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
		var statusNode = E('div', { 'class': 'cbi-value-description' }, []);
		var paint = function(s) {
			statusNode.textContent = [
				_('Antenna %d').format(1) + ': ' + chainText(s.chain1) + ', ' + detText(s.detect1),
				_('Antenna %d').format(2) + ': ' + chainText(s.chain2) + ', ' + detText(s.detect2)
			].join(' · ');
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
					statusNode,
					E('div', { 'class': 'cbi-value-description' },
						_('Applies immediately, no Save needed. Automatic modes check the connectors every 3 seconds. The detector only sees antennas that short the connector to ground; a passive antenna may stay undetected while plugged in.'))
				])
			])
		]);
	},

	fillModemInfo: function() {
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '20' ]), {})
			.then(function(r) {
				var j = {};
				try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) { return; }
				var tbl = document.getElementById('dbg-info-table');
				var msg = document.getElementById('dbg-no-modem');
				if (j.error && j.error !== 'busy' && !j.modem) {
					if (tbl) { tbl.style.display = 'none'; }
					if (msg) { msg.style.display = ''; }
					return;
				}
				if (tbl) { tbl.style.display = ''; }
				if (msg) { msg.style.display = 'none'; }
				var put = function(id, v) {
					var el = document.getElementById(id);
					if (el && v != null && String(v) !== '') { el.textContent = String(v); }
				};
				put('dbg-modem', j.modem + modeSuffix(j));
				put('dbg-firmware', j.firmware);
				put('dbg-cport', j.cport);
				put('dbg-protocol', mutil.protoLabel(j.protocol));

				var t = j.mtemp;
				if (t != null && String(t).length > 1 && String(t).indexOf(' ') < 0 && String(t) != '-') {
					put('dbg-mtemp', String(t).replace('&deg;', '°'));
					var row = document.getElementById('dbg-temp-row');
					if (row) { row.style.display = ''; }
				}
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
		var wdmDriver = String(res[res.length - 1] || '').trim();
		if (wdmDriver !== 'cdc_mbim' && uci.get('5gmodem', '@5gmodem[0]', 'iface_proto') !== 'mbimp') {
			protoAvail['mbimp'] = false;
		}

		var m, s, o;
		m = new form.Map('5gmodem', '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		o = s.option(form.Flag, 'auto_port', _('Auto-detect port and interface'),
			_('Automatically find the modem AT port and its network interface (via ModemManager when available). Turn this off to select them manually below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(ListDropdown, 'network', _('Interface'),
			_('Network interface for Internet access'));
		o.depends('auto_port', '0');
		o.rmempty = true;
		/* see docs/subsystems/diagnostics.md#hidden-port-fields-must-survive-save */
		o.remove = function() { return Promise.resolve(); };
		(uci.sections('network', 'interface') || []).forEach(function(iface) {
			var nm = iface['.name'];
			if (nm && nm != 'loopback') { o.value(nm, nm + (iface.proto ? ' (' + mutil.protoLabel(iface.proto) + ')' : '')); }
		});

		o = s.option(form.Value, 'device',
			_('Port for modem communication'),
			_("Port used to read modem/connection info. <br /> <br />Traditional modem: one of the available ttyUSBX ports.<br /> <br />HiLink modem: enter the IP address 192.168.X.X under which the modem is available."));
		devs.sort(function(a, b) { return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0); });
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* see docs/subsystems/diagnostics.md#hidden-port-fields-must-survive-save */
		o.remove = function() { return Promise.resolve(); };

		o = s.option(form.Value, 'at_port',
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
		o = s.option(ListDropdown, 'iface_proto', _('Interface protocol'),
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
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, [ _('Interface “%s” was created for a different modem').format(mForeignIf) ]), ' ',
				_('It is bound to this modem only because the kernel reused the device node, so its settings (APN in particular) may belong to the previous modem and SIM. Create the interface anew below - the APN is filled from the operator detected right now.')
			]), 'warning');
		}

		var mImeiChanged = mSec ? (uci.get('5gmodem', mSec, 'imei_changed') || '') : '';
		if (mImeiChanged === '1') {
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, _('A different modem is now in this USB port')), ' ',
				_('Its IMEI does not match the one seen here before - the modems were probably swapped. The settings of this slot (the interface and its APN in particular) belong to the previous modem and its SIM. Check them below and create the interface anew if needed.')
			]), 'warning');
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ackswap', mSec ]), null);
		}


		o = s.option(ListDropdown, '_apn_mode', _('APN selection'));
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
		o = s.option(form.Value, '_apn', _('APN'),
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

		if (!activeIsHilink) {
		o = s.option(ListDropdown, '_pdpauth', _('Authentication'),
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

		o = s.option(form.Value, '_pdpuser', _('PAP/CHAP username'));
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

		o = s.option(form.Value, '_pdppass', _('PAP/CHAP password'));
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
				&& /^(12d1:|19d2:1557$|19d2:0581$)/.test(String(uci.get('5gmodem', sc, 'vidpid') || '12d1:'));
		})();
		var webPassHl = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();
		if (webPassHl) {
		o = s.option(form.Value, '_web_pass', _('Modem web password'),
			_('The password of the modem\'s own web interface (user admin). With it the router reads signal, battery, SMS and can reboot the modem. Empty means admin, the factory password of most such modems.'));
		o.password = true;
		o.placeholder = 'admin';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			return fs.exec('/usr/share/5gmodem/modemswitch.sh',
				[ 'webpass', String(p), 'set', String(value || '') ]).catch(function() {});
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return ''; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sec, 'web_pass') || '';
		};
		o.remove = function(section_id) { return this.write(section_id, ''); };
		}
		if (atDebugHl) {
		o = s.option(form.Flag, '_at_debug', _('AT ports (debug mode)'),
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

		o = s.option(ListDropdown, '_esim_show', _('eSIM tab'),
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
		o = s.option(form.Flag, '_roaming', _('Allow data roaming'),
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

		if (!activeIsHilink) {
		var nsView = this;
		o = s.option(form.DummyValue, '_netsel', _('Network selection'),
			_('Pick the operator network by hand instead of letting the modem choose. The search takes 1-3 minutes.'));
		o.cfgvalue = function() { return ''; };
		o.write = function() {};
		o.remove = function() {};
		o.renderWidget = function() { return nsView.renderNetsel(); };
		}

		o = s.option(form.Flag, '_mm_exclude', _('Hide from ModemManager'),
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
		o = s.option(form.Flag, '_mm_at', _('AT polling under ModemManager'),
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
		o = s.option(form.Flag, '_no_at', _('No background AT polling'),
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
		o = s.option(ListDropdown, '_pdptype', _('IP type'),
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
		o = s.option(form.Flag, '_dns_fallback', _('Fallback DNS'),
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

		o = s.option(form.Value, '_dns_servers', _('DNS servers'),
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

		if (activeIsHilink) {
		o = s.option(form.Button, '_mkhilink');
		o.title = _('Modem interface');
		o.description = (activeKind === 'tether')
			? _('This phone shares the internet over USB and hands out an address over DHCP. The button creates (or recreates) that DHCP interface - there is no dial-up protocol to choose, and no modem metrics to read.')
			: _('This modem holds the connection itself and hands out an address over DHCP on its own network card. The button creates (or recreates) that DHCP interface - there is no dial-up protocol to choose.');
		o.inputtitle = (activeKind === 'tether')
			? (mIfExists ? _('Recreate interface (USB tethering)') : _('Create interface (USB tethering)'))
			: (mIfExists ? _('Recreate interface (HiLink DHCP)') : _('Create interface (HiLink DHCP)'));
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mkhilink' ]).then(function(res) {
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
		} else {
		o = s.option(form.Button, '_mkiface');
		o.title = _('Modem interface');
		o.description = _('Create (or switch) the modem network interface using the protocol chosen above. Switching to MBIM disables ModemManager; switching to ModemManager enables it (they cannot share the modem).');
		o.inputtitle = mIfExists ? _('Recreate modem interface') : _('Create modem interface');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var sid = null;
			var ss = uci.sections('5gmodem', '5gmodem');
			if (ss && ss[0]) { sid = ss[0]['.name']; }
			var proto = 'auto';
			try {
				var opt = this.map.lookupOption('iface_proto', sid);
				if (opt && opt[0]) { var el = opt[0].getUIElement(sid); if (el) { proto = el.getValue() || 'auto'; } }
			} catch (e) {}
			var apn = '';
			try {
				var aopt = this.map.lookupOption('_apn', sid);
				if (aopt && aopt[0]) { var ael = aopt[0].getUIElement(sid); if (ael) { apn = (ael.getValue() || '').trim(); } }
			} catch (e) {}
			var apnArg = apn || '-';
			var pdp = 'ipv4';
			try {
				var popt = this.map.lookupOption('_pdptype', sid);
				if (popt && popt[0]) { var pel = popt[0].getUIElement(sid); if (pel) { pdp = pel.getValue() || 'ipv4'; } }
			} catch (e) {}
			var mmArg = '-';
			try {
				var mopt = this.map.lookupOption('_mm_exclude', sid);
				if (mopt && mopt[0]) { var mel = mopt[0].getUIElement(sid);
					if (mel) { var mv = String(mel.getValue()); if (mv === '0' || mv === '1') { mmArg = mv; } } }
			} catch (e) {}
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/mkiface.sh', [ 'modem', proto, apnArg, pdp, mmArg, 'user' ]).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.result == 'created') {
					ui.addNotification(null, E('p', [ _('Interface "%s" created (%s), bringing it up…').format(out.iface, mutil.protoLabel(out.proto)) ]), 'info');
					var pb = document.querySelector('.tg-proto-badge');
					if (pb && out.proto) { pb.textContent = mutil.protoLabel(out.proto); }
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
		}

		o = s.option(form.Button, '_forget');
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

		var runCollect = function() {
			var msg = E('p', { 'class': 'spinning' }, _('Collecting logs…'));
			ui.showModal(_('Diagnostic report'), [ msg ]);

			var poll = function(tries) {
				return fs.exec('/usr/share/5gmodem/collect.sh', [ 'status' ]).then(function(res) {
					var st = {}; try { st = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
					if (st.state === 'running') {
						if (tries > 180) { throw new Error(_('Timed out')); }
						msg.textContent = _('Collecting logs…') + ' ' + collectStepText(st.progress);
						return new Promise(function(resolve) {
							window.setTimeout(function() { resolve(poll(tries + 1)); }, 2000);
						});
					}
					if (st.state !== 'done') { throw new Error(_('Collecting logs failed')); }
					return fs.read_direct('/tmp/5gmodem/diag.txt', 'blob');
				});
			};

			return fs.exec('/usr/share/5gmodem/collect.sh', [ 'start' ]).then(function() {
				return poll(0);
			}).then(function(blob) {
				var d = new Date();
				var stamp = d.getFullYear()
					+ ('0' + (d.getMonth() + 1)).slice(-2)
					+ ('0' + d.getDate()).slice(-2)
					+ '-' + ('0' + d.getHours()).slice(-2)
					+ ('0' + d.getMinutes()).slice(-2);
				var url = window.URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': '5gmodem-diag-' + stamp + '.txt' });
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


		function infoVal(v) {
			return (v != null && String(v).length > 0 && String(v) != '-') ? String(v) : '-';
		}
		function inforow(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
				E('td', { 'class': 'td left tg-info-val' }, [ value ]),
			]);
		}
		var infoCell = function(id, inner) {
			return E('span', { 'id': id }, inner !== undefined ? inner : '-');
		};
		var infoRows = [
			inforow(_('Modem type'), infoCell('dbg-modem')),
			inforow(_('Revision / Firmware'), infoCell('dbg-firmware')),
			inforow(_('IP adress / Communication Port'), infoCell('dbg-cport')),
			inforow(_('Protocol'), E('span', { 'class': 'tg-proto-badge' }, infoCell('dbg-protocol'))),
		];
		var tempRow = inforow(_('Chip Temperature'), infoCell('dbg-mtemp'));
		tempRow.style.display = 'none';
		tempRow.id = 'dbg-temp-row';
		infoRows.push(tempRow);

		var modemInfo = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Modem Information') ]),
			E('table', { 'class': 'table tg-info-table', 'id': 'dbg-info-table' }, infoRows),
			E('p', { 'id': 'dbg-no-modem', 'class': 'tg-no-modem', 'style': 'display:none' },
				_('No modem detected. Insert a modem, then reload the page.'))
		]);

		var termBlock = function(cmd) {
			var parts = cmd.split(' ');
			var spans = [ E('span', { 'style': 'color:#34d399;user-select:none;' }, '$ ') ];
			parts.forEach(function(tok, i) {
				var color = (i == 0) ? '#7db2ff' : (tok.charAt(0) == '-' ? '#e6b84c' : '#d6e0ea');
				spans.push(E('span', { 'style': 'color:' + color }, tok + (i < parts.length - 1 ? ' ' : '')));
			});
			return E('div', { 'class': 'tg-code' }, [
				E('div', { 'class': 'tg-code-lang' }, 'bash'),
				E('div', { 'class': 'tg-code-body' }, spans)
			]);
		};

		var table = E('table', { 'class': 'table tg-diag-table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("USB debug information")
						),
						termBlock('cat /sys/kernel/debug/usb/devices'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleUSB')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check availability of ttyX ports")
						),
						termBlock('ls /dev'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleTTY')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check data read by the 5gmodem scripts")
						),
						termBlock('sh -x /usr/share/5gmodem/5gmodem.sh'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleDBG')
							}, [ _('Debug') ])
						])
					]),
				])
			]);


		var diag = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Diagnostics') ]),
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('label', { 'class': 'cbi-value-title', 'style': 'display:block; margin-bottom:.3em' },
					_('Diagnostic report')),
				E('div', { 'class': 'cbi-value-description', 'style': 'margin:0 0 .5em' }, collectDesc),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, runCollect)
				}, [ _('Collect logs') ])
			]),
			table,
			E('div', {}, [
				E('p'),
				E('div', { 'id': 'pre', 'class': 'tg-code', 'style': 'display:none; max-width:none; margin:0;' }, [
					E('div', { 'class': 'tg-code-lang' }, 'bash'),
					E('pre', { 'id': 'preout', 'class': 'tg-code-body', 'style': 'max-height:460px; overflow:auto; margin:0;' }, [])
				]),
				E('p'),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clear',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-apply important',
						'id': 'download',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleDownload')
					}, [ _('Download') ]),
				]),
			])
		]);

		var _instant = { '_web_pass': 1, '_roaming': 1, '_mm_exclude': 1, '_mm_at': 1, '_no_at': 1, '_at_debug': 1, '_esim_show': 1 };
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
		return Promise.resolve(m.render()).then(function(formNode) {
			return E('div', {}, [
				modemInfo,
				self.renderProfiles(),
				E('div', { 'class': 'tg-modem-form' }, [ formNode ]),
				ledsBlock,
				antennaBlock,
				diag
			]);
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
