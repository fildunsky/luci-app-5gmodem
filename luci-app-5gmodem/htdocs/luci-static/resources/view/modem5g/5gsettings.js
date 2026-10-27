'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.healthform as healthform';
'require view.modem5g.extip as extip';
'require fs';
'require ui';
'require uci';
'require rpc';
'require form';
'require dom';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

var uciCommit = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	expect: { '': {} }
});

function commitPending() {
	return uci.changes().then(function(ch) {
		var names = [];
		for (var k in ch) { if ((ch[k] || []).length) { names.push(k); } }
		if (!names.length) { return null; }
		return Promise.all(names.map(function(n) {
			return L.resolveDefault(uciCommit(n), null);
		}));
	}).catch(function() { return null; });
}

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum
	Licensed to the GNU General Public License v3.0.
*/

function updSet(id, txt) { var e = document.getElementById(id); if (e) { e.textContent = txt; } }
function updSetVer(id, label, ver) {
	var e = document.getElementById(id);
	if (!e) { return; }
	e.textContent = '';
	e.appendChild(document.createTextNode(label + ': '));
	e.appendChild(E('strong', {}, [ String(ver == null ? '' : ver) ]));
}
function updShow(id, show) { var e = document.getElementById(id); if (e) { e.style.display = show ? '' : 'none'; } }
function updErrText(e, fb) {
	switch (e) {
	case 'asset_pending':
		return _('The update is still building on the server. Please wait about 15-20 minutes and try again.');
	case 'no_space':
		return _('Not enough free space in /tmp to download the update.');
	case 'download_failed':
		return _('Could not download the update from GitHub. Check the internet connection and try again.');
	case 'download_incomplete':
		return _('The download was interrupted: the file is incomplete. Try again.');
	case 'install_failed':
		return _('The package manager could not install the update.');
	case 'version_mismatch':
		return _('The package was installed, but the version did not change. The release file looks broken.');
	case 'Could not reach GitHub':
		return _('Could not reach GitHub');
	}
	return e || fb;
}

var updTarget = '';

function updNotesText(t) {
	return String(t || '').replace(/\*\*([^*]+)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
}

function renderNotes(b64) {
	var box = document.getElementById('upd-notes');
	if (!box) { return; }
	var txt = '';
	try { txt = decodeURIComponent(escape(atob(b64 || ''))); } catch (e) { txt = ''; }
	box.innerHTML = '';
	var body = E('div', { 'class': 'upd-notes' });
	txt.replace(/\r/g, '').split('\n').forEach(function(line) {
		var l = line.trim();
		if (!l || /^#{1,6}\s/.test(l)) { return; }
		var m = l.match(/^[-*+]\s+(.*)$/);
		body.appendChild(E('div', {}, [ m ? '- ' + updNotesText(m[1]) : updNotesText(l) ]));
	});
	if (!body.childNodes.length) { box.style.display = 'none'; return; }
	box.appendChild(body);
	box.style.display = '';
}

function checkUpdate() {
	updSet('upd-status', _('Checking the latest release…'));
	updShow('upd-install', false);
	updProgress(null);
	var b = document.getElementById('upd-check'); if (b) { b.disabled = true; }
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'check' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		updSet('upd-current', d.current || '—');
		var latest = String(d.latest || '').replace(/^v/i, '');
		updTarget = latest;
		if (d.release_url) { var a = document.getElementById('upd-release'); if (a) { a.href = d.release_url; a.style.display = ''; } }
		if (!d.success) {
			updSet('upd-status', updErrText(d.error, _('Could not check for updates')));
			renderNotes('');
		} else if (d.update_available == 1 || d.update_available === true) {
			updShow('upd-install', true);
			updSetVer('upd-status', _('Update available'), latest || '—');
			renderNotes(d.notes);
		} else {
			updSet('upd-status', _('You have the latest version'));
			renderNotes('');
		}
	}).catch(function(err) {
		updSet('upd-status', _('Could not check for updates') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('upd-check'); if (b) { b.disabled = false; }
	});
}

function updBusy(busy) {
	var bi = document.getElementById('upd-install'), bc = document.getElementById('upd-check');
	if (bi) { bi.disabled = busy; } if (bc) { bc.disabled = busy; }
}

function updKB(n) { return Math.round((+n || 0) / 1024); }

function updProgress(d) {
	var box = document.getElementById('upd-progress'), bar = document.getElementById('upd-bar');
	if (!box || !bar) { return; }
	if (!d) { box.style.display = 'none'; return; }
	box.style.display = '';
	var txt = '';
	if (d.stage === 'download' && +d.total > 0) {
		bar.max = +d.total; bar.value = Math.min(+d.done || 0, +d.total);
		txt = _('Downloading: %d of %d KB').format(updKB(d.done), updKB(d.total));
	} else if (d.stage === 'download') {
		bar.removeAttribute('value');
		txt = _('Downloading: %d KB').format(updKB(d.done));
	} else if (d.stage === 'install') {
		bar.removeAttribute('value');
		txt = _('Installing the package…');
	} else if (d.stage === 'finish') {
		bar.removeAttribute('value');
		txt = _('Finishing: refreshing translations and caches…');
	} else {
		bar.removeAttribute('value');
		txt = _('Preparing: reading the release…');
	}
	updSet('upd-ptext', txt);
}

function updDetail(txt) {
	var e = document.getElementById('upd-detail');
	if (!e) { return; }
	e.textContent = String(txt || '').trim();
	e.style.display = e.textContent ? '' : 'none';
}

var CACHED_RES = [
	'view/modem5g/5gdetail.js', 'view/modem5g/5gdebug.js', 'view/modem5g/5gesim.js',
	'view/modem5g/5gsettings.js', 'view/modem5g/netpri.js', 'view/modem5g/modemtabs.js',
	'view/modem5g/extip.js', 'view/modem5g/mutil.js',
	'view/modem5g/readsms.js', 'view/modem5g/sendsms.js', 'view/modem5g/sendussd.js',
	'view/modem5g/sendat.js',
	'view/modem5g/bandsui.js', 'view/modem5g/healthform.js', 'view/modem5g/buttons.js',
	'view/modem5g/align.js', 'view/modem5g/5gstats.js', 'view/modem5g/modem.css',
	'protocol/fibocom.js', 'protocol/qmiraw.js', 'protocol/mbimp.js'
];

function refreshResources() {
	if (typeof window.fetch !== 'function') { return Promise.resolve(); }
	return Promise.all(CACHED_RES.map(function(r) {
		return fetch(L.resource(r), { cache: 'reload', credentials: 'same-origin' })
			.catch(function() {});
	}));
}

function finishUpdate(ver) {
	updProgress(null);
	updDetail('');
	if (ver) { updSet('upd-current', ver); }
	updShow('upd-install', false);
	updSet('upd-status', _('Update installed. Refreshing resources…'));
	refreshResources().then(function() {
		updSet('upd-status', _('Update installed. Signing out to apply it…'));
		window.setTimeout(function() {
			var u = L.url('admin/logout');
			if (!u) { window.location.reload(); return; }
			if (L.env && L.env.token) { u += '?token=' + encodeURIComponent(L.env.token); }
			window.location.href = u;
		}, 1200);
	});
}

function verifyInstalled(target) {
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/update.sh', [ 'version' ]), '{}').then(function(out) {
		var d = {}; try { d = JSON.parse(out || '{}'); } catch (e) {}
		var cur = String(d.current || '');
		return (target && cur === String(target).replace(/^v/i, '')) ? cur : null;
	});
}

function failInstall(msg, detail, target) {
	return verifyInstalled(target).then(function(cur) {
		if (cur) { finishUpdate(cur); return; }
		updProgress(null);
		updSet('upd-status', msg);
		updDetail(detail);
		updBusy(false);
	});
}

function pollInstall(tries, misses) {
	tries = tries || 0;
	misses = misses || 0;
	if (tries > 300) {
		return failInstall(_('Update is taking too long. Check the connection and try again.'), '', updTarget);
	}
	window.setTimeout(function() {
		L.resolveDefault(fs.read_direct('/tmp/5gmodem/update.json'), null).then(function(txt) {
			if (txt == null) {
				if (misses >= 30) {
					return failInstall(_('Lost contact with the router during the update.'), '', updTarget);
				}
				return pollInstall(tries + 1, misses + 1);
			}
			var d = {}; try { d = JSON.parse(String(txt).trim() || '{}'); } catch (e) { return pollInstall(tries + 1, 0); }
			if (d.target) { updTarget = d.target; }
			if (d.running || (!d.success && !d.error)) {
				updProgress(d);
				return pollInstall(tries + 1, 0);
			}
			if (d.success) {
				finishUpdate(d.current);
				updBusy(false);
				return;
			}
			return failInstall(updErrText(d.error, _('Failed to install the update')), d.detail, d.target || updTarget);
		});
	}, 1000);
}

function installUpdate() {
	if (!confirm(_('Download and install the latest version now?'))) { return Promise.resolve(); }
	updSet('upd-status', _('Installing the update…'));
	updDetail('');
	updProgress({ stage: 'prepare' });
	updBusy(true);
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'install' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.error) {
			return failInstall(updErrText(d.error, _('Failed to install the update')), d.detail, updTarget);
		}
		pollInstall(0, 0);
	}).catch(function() {
		pollInstall(0, 0);
	});
}

var APNBIN = '/usr/share/5gmodem/apn-update.sh';

function updVersion() {
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/update.sh', [ 'version' ]), '{}').then(function(out) {
		var d = {}; try { d = JSON.parse(out || '{}'); } catch (e) {}
		if (d.current) { updSet('upd-current', d.current); }
	});
}

function apnVersion() {
	return L.resolveDefault(fs.exec_direct(APNBIN, [ 'version' ]), '{}').then(function(out) {
		var d = {}; try { d = JSON.parse(out || '{}'); } catch (e) {}
		updSet('apn-current', d.version ? (d.version + ' · ' + (d.count || 0) + ' ' + _('operators')) : '—');
	});
}

function apnCheck() {
	updSet('apn-status', _('Checking the APN database…'));
	updShow('apn-update', false);
	var b = document.getElementById('apn-check'); if (b) { b.disabled = true; }
	return fs.exec(APNBIN, [ 'check' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (!d.ok) {
			updSet('apn-status', _('Could not check the APN database') + (d.error ? (': ' + d.error) : ''));
			return;
		}
		if (String(d.update_available) === '1') {
			updShow('apn-update', true);
			updSetVer('apn-status', _('Update available'),
				(d.available_version || '—') + ' · ' + (d.available || 0) + ' ' + _('operators'));
		} else {
			updSet('apn-status', _('The APN database is up to date'));
		}
	}).catch(function(err) {
		updSet('apn-status', _('Could not check the APN database') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('apn-check'); if (b) { b.disabled = false; }
	});
}

function apnUpdate() {
	updSet('apn-status', _('Updating the APN database…'));
	var b = document.getElementById('apn-update'); if (b) { b.disabled = true; }
	return fs.exec(APNBIN, [ 'update' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.ok) {
			updSet('apn-current', (d.version || '—') + ' · ' + (d.count || 0) + ' ' + _('operators'));
			updShow('apn-update', false);
			updSet('apn-status', _('The APN database has been updated'));
		} else {
			updSet('apn-status', _('Failed to update the APN database') + (d.error ? (': ' + d.error) : ''));
		}
	}).catch(function(err) {
		updSet('apn-status', _('Failed to update the APN database') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('apn-update'); if (b) { b.disabled = false; }
	});
}

var ListDropdown = form.RichListValue || form.ListValue;
var EXTIPBIN = '/usr/share/5gmodem/extip.sh';

return view.extend({
	load: function() {
		var self = this, args = arguments;
		return fresh.check(30901, [ extip, healthform, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/buttons.sh', [ 'services' ]), '{}'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/notmodem.sh', [ 'scan' ]), '[]')
		]);
	},

	render: function(res) {
		modemtabs.attach();
		var services = [];
		try { services = (JSON.parse((res && res[1]) || '{}').services) || []; } catch (e) {}
		var usbDevs = [];
		try { usbDevs = JSON.parse((res && res[2]) || '[]') || []; } catch (e) {}

		var updateBlock = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Application update') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('5G modem')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'id': 'upd-check',
							'click': ui.createHandlerFn(this, function() { return checkUpdate(); })
						}, [ _('Check for updates') ]),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'id': 'upd-install',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, function() { return installUpdate(); })
						}, [ _('Install update') ]),
						E('a', {
							'class': 'cbi-button',
							'id': 'upd-release',
							'href': 'https://github.com/fildunsky/luci-app-5gmodem/releases/latest',
							'target': '_blank', 'rel': 'noopener',
							'style': 'display:none'
						}, [ _('Release page') ]),
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [
							E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'upd-current' }, [ '—' ]) ]),
							E('div', { 'id': 'upd-status', 'style': 'margin-top:4px' }, []),
							E('div', { 'id': 'upd-progress', 'style': 'display:none;margin-top:6px' }, [
								E('progress', { 'id': 'upd-bar', 'max': '100', 'style': 'width:100%;max-width:360px' }),
								E('div', { 'id': 'upd-ptext', 'style': 'font-size:90%;opacity:.85' }, [])
							]),
							E('pre', { 'id': 'upd-detail', 'style': 'display:none;margin-top:6px;white-space:pre-wrap;font-size:85%;max-width:600px' }, []),
							E('div', { 'id': 'upd-notes', 'style': 'display:none;margin-top:8px' }, []),
						]),
					]),
				]),
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('APN database')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'id': 'apn-check',
							'click': ui.createHandlerFn(this, function() { return apnCheck(); })
						}, [ _('Check the APN database') ]),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'id': 'apn-update',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, function() { return apnUpdate(); })
						}, [ _('Update the APN database') ]),
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [
							E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'apn-current' }, [ '—' ]) ]),
							E('div', { 'id': 'apn-status', 'style': 'margin-top:4px' }, []),
						]),
					]),
				]),
			]),
		]);

		var m = new form.Map('5gmodem');
		var o;

		var _gateOpts = [ 'align_enabled', 'show_stats', 'netonly' ];
		var _gateWas = {};
		_gateOpts.forEach(function(k) {
			_gateWas[k] = String(uci.get('5gmodem', sid0(), k) || '');
		});
		function sid0() {
			var ss = uci.sections('5gmodem', '5gmodem');
			return (ss && ss[0]) ? ss[0]['.name'] : '';
		}
		function _gateChanged() {
			return _gateOpts.some(function(k) {
				return String(uci.get('5gmodem', sid0(), k) || '') !== _gateWas[k];
			});
		}
		function _gateAfterAutosave() {
			if (!_gateChanged()) { return; }
			var noWas = _gateWas.netonly;
			_gateOpts.forEach(function(k) {
				_gateWas[k] = String(uci.get('5gmodem', sid0(), k) || '');
			});
			modemtabs.refreshGateTabs();
			if (_gateWas.netonly !== noWas) {
				return L.resolveDefault(fs.exec('/usr/share/5gmodem/setopt.sh', [ 'applyset' ]), null)
					.then(function() { window.location.reload(); });
			}
		}

		var _mSaveOrig = m.save.bind(m);
		m.save = function() {
			return _mSaveOrig.apply(null, arguments).then(function(r) {
				return commitPending().then(function() {
					return L.resolveDefault(fs.exec('/usr/share/5gmodem/setopt.sh', [ 'applyset' ]), null);
				}).then(function() {
					return uci.changes().then(function(ch) {
						var n = 0;
						for (var k in ch) { n += (ch[k] || []).length; }
						if (ui.changes && ui.changes.setIndicator) { ui.changes.setIndicator(n); }
						if (_gateChanged()) {
							_gateOpts.forEach(function(k) {
								_gateWas[k] = String(uci.get('5gmodem', sid0(), k) || '');
							});
							modemtabs.refreshGateTabs();
						}
						return r;
					}).catch(function() { return r; });
				});
			});
		};

		var disp = m.section(form.TypedSection, '5gmodem', _('Main'),
			_('Everyday options of the Network page and modem behaviour'));
		disp.anonymous = true;

		o = disp.option(form.Flag, 'netonly', _('Internet priorities only'),
			_('For a router without a modem: keeps uplink priorities, the internet watchdog, statistics, buttons and the Telegram bot, and turns off everything that serves a modem - polling, SMS, ModemManager control, USB port binding. Modem tabs and settings are hidden.'));
		o.default = '0';
		o.rmempty = false;

		o = disp.option(form.Flag, 'simple_view', _('Simple view of the Network page'),
			_('Show only the essentials: modem name, signal, status lamp and the restart button. Expert blocks (bands, cell info, TTL, interface details) are hidden. Off by default.'));
		o.default = '0';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		o = disp.option(form.Flag, 'mobile_view', _('New mobile view'),
			_('On phones the Network page gets a summary bar, tabs and signal tiles. Turn off to get the previous layout back.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		o = disp.option(form.Flag, 'rat_card', _('Colored modem card'),
			_('Tint the Modem card on the Network page by network technology: purple for 5G, blue for 4G, green for 3G, pink for 2G. Turn off to get the previous plain card back.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		o = disp.option(form.Flag, 'show_stats', _('Collect statistics'),
			_('Collects uplink latency, signal, temperature and monthly traffic, and shows the "Statistics" tab with the charts. Series live in RAM; monthly traffic can be kept across reboots on the tab itself.'));
		o.default = '1';
		o.rmempty = false;

		o = disp.option(form.Flag, 'show_history', _('Show signal history'),
			_('Show the collapsible "History" block on the Network page: RSRP, RSRQ, SINR and RSSI over the last 10 minutes. It is drawn from the data the page already polls and adds no load on the modem.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		o = disp.option(form.Flag, 'save_bands', _('Remember bands after reboot'),
			_('Re-apply your selected bands when the modem reconnects, so a modem that resets its band selection on reboot (e.g. FM350) keeps yours. Only modems that actually lost the selection are touched.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		var wdg = m.section(form.TypedSection, '5gmodem', _('Appearance'),
			_('Cards in the widgets row on the Network page. All are on by default.'));
		wdg.anonymous = true;

		o = wdg.option(form.Flag, 'widget_netpri', _('Internet priority'),
			_('Uplink switch — modems / Wi-Fi / WAN'));
		o.default = '1';
		o.rmempty = false;

		o = wdg.option(ListDropdown, 'netpri_rank', _('Card background'),
			_('Large translucent mark on each uplink card'));
		o.value('0', _('None'));
		o.value('1', _('Priority number'));
		o.value('icon', _('Icons'));
		o.default = '0';
		o.rmempty = false;
		o.depends('widget_netpri', '1');

		var hwArrow = E('span', { 'style': 'display:inline-block;width:1em' }, '▸');
		var hwBody = E('div', { 'style': 'margin-top:.6em' });
		var hwCollapse = E('div', { 'class': 'tg-collapse' }, [
			E('div', { 'class': 'tg-collapse-inner' }, [ hwBody ])
		]);
		var hwWrap = E('div', { 'class': 'cbi-value' }, [
			E('div', {
				'style': 'cursor:pointer;user-select:none;font-weight:600',
				'click': function() {
					var open = !hwCollapse.classList.contains('open');
					hwCollapse.classList.toggle('open', open);
					hwArrow.textContent = open ? '▾' : '▸';
				}
			}, [ hwArrow, _('Internet watchdog') ]),
			hwCollapse
		]);
		var hwNote = E('em', { 'style': 'display:none' }, _('Saved and applied.'));
		var hwNoteT = null;
		healthform.load().then(function(d) {
			var hf = healthform.build(d.conf, d.uplinks, {
				autosave: true,
				onsaved: function() {
					hwNote.style.display = '';
					if (hwNoteT) { window.clearTimeout(hwNoteT); }
					hwNoteT = window.setTimeout(function() {
						hwNote.style.display = 'none';
					}, 2000);
				}
			});
			hwBody.appendChild(hf.node);
			hwBody.appendChild(hwNote);
		});
		o = wdg.option(form.DummyValue, '_health');
		o.render = function() { return hwWrap; };

		o = wdg.option(form.Flag, 'widget_status', _('Ping monitor'),
			_('Ping cards (host with a green/red dot and latency)'));
		o.default = '1';
		o.rmempty = false;

		var psv = wdg.option(form.SectionValue, '__pingcards', form.TableSection, 'pingwidget');
		psv.depends('widget_status', '1');
		var pw = psv.subsection;
		pw.anonymous = true;
		pw.addremove = true;
		pw.addbtntitle = '+';

		var pho = pw.option(form.Value, 'host', _('Host'));
		pho.value('youtube.com');
		pho.value('api.telegram.org', 'Telegram (api.telegram.org)');
		pho.value('github.com');
		pho.value('google.com');
		pho.value('cloudflare.com');
		pho.value('yandex.ru');

		var pmo = pw.option(ListDropdown, 'mode', _('Ping mode'));
		pmo.value('click', _('On click only'));
		pmo.value('10', _('Every 10 s'));
		pmo.value('30', _('Every 30 s'));
		pmo.value('60', _('Every 60 s'));
		pmo.default = 'click';

		o = wdg.option(form.Flag, 'widget_services', _('Service monitor'),
			_('Service status cards (running/stopped)'));
		o.default = '1';
		o.rmempty = false;

		var ssv = wdg.option(form.SectionValue, '__svccards', form.TableSection, 'svcwidget');
		ssv.depends('widget_services', '1');
		var sw = ssv.subsection;
		sw.anonymous = true;
		sw.addremove = true;
		sw.addbtntitle = '+';

		var svo = sw.option(ListDropdown, 'service', _('Service'));
		if (services.length) {
			var _svcNice = { zapret: 'Zapret', zerotier: 'ZeroTier', nikki: 'Nikki',
			                 ssclash: 'SSClash', clash: 'SSClash (4.7)' };
			services.forEach(function(s) { svo.value(s, _svcNice[s] || s); });
			svo.default = [ 'nikki', 'ssclash', 'clash' ].filter(function(s) {
				return services.indexOf(s) >= 0;
			})[0] || services[0];
		} else {
			svo.value('ssclash'); svo.default = 'ssclash';
		}
		svo.rmempty = false;

		var ruo = sw.option(form.Flag, 'restart_on_uplink', _('Restart on uplink'),
			_('Restart the service once the uplink starts carrying traffic.'));
		ruo.default = '0';
		ruo.rmempty = false;

		o = wdg.option(form.Flag, 'widget_speedtest', _('Speed test'), _('Speed-test card'));
		o.default = '1';
		o.rmempty = false;

		var stv = wdg.option(form.SectionValue, '__sttings', form.TypedSection, '5gmodem');
		stv.depends('widget_speedtest', '1');
		var sts = stv.subsection;
		sts.anonymous = true;

		o = sts.option(form.Value, 'speedtest_url', _('Download source'),
			_('Source for the download test. "Internetometer" asks Yandex for the nearest CDN node before each run, which is the best choice over Russian cellular; it also sets the upload endpoint unless you picked one yourself. For a plain URL, a BIGGER file lets the speed ramp up over the ~15-second test. RU-hosted sources (Selectel/Yandex/Tele2) work over Russian cellular; Cloudflare/Hetzner may be blocked there. Approx. size shown.'));
		o.value('internetometer', _('Internetometer (Yandex CDN)'));
		o.value('https://speedtest.selectel.ru/1GB', 'Selectel — RU (~1 ' + _('GB') + ')');
		o.value('http://mirror.yandex.ru/archlinux/iso/latest/archlinux-x86_64.iso', 'Yandex — RU (~1 ' + _('GB') + ')');
		o.value('http://speedtest.tele2.net/1GB.zip', 'Tele2 (~1 ' + _('GB') + ')');
		o.value('https://speed.cloudflare.com/__down?bytes=1000000000', 'Cloudflare (' + _('stream') + ')');
		o.value('https://speed.hetzner.de/1GB.bin', 'Hetzner — EU (~1 ' + _('GB') + ')');
		o.value('http://mirror.yandex.ru/debian/ls-lR.gz', 'Yandex (~16 ' + _('MB') + ', ' + _('economical') + ')');
		o.default = 'internetometer';
		o.rmempty = false;
		o.onchange = function(ev, section_id, value) {
			if (value != 'internetometer')
				return;
			var up = this.map.lookupOption('speedtest_up_url', section_id);
			var el = up ? up[0].getUIElement(section_id) : null;
			if (el && el.getValue() != 'internetometer')
				el.setValue('internetometer');
		};

		o = sts.option(form.Value, 'speedtest_up_url', _('Upload endpoint'),
			_('Endpoint that accepts a POST body, for the upload test. "Internetometer" uses a node from the same probe list as the download source, and can be picked here on its own. Only uploads the server received in full are counted: an endpoint that cuts the transfer off early gives no upload figure at all.'));
		o.value('internetometer', _('Internetometer (Yandex CDN)'));
		o.value('https://speed.cloudflare.com/__up', 'Cloudflare');
		o.value('https://speedtest.rt.ru/backend/empty.php', 'Rostelecom (LibreSpeed)');
		o.value('https://yandex.ru/internet/api/v1/upload', 'Yandex - RU (' + _('works over cellular') + ')');
		o.value('https://librespeed.org/backend/empty.php', 'LibreSpeed (' + _('public demo') + ')');
		o.value('https://www.librespeed.fi/backend/empty.php', 'LibreSpeed - Helsinki (Hetzner)');
		o.default = 'internetometer';
		o.rmempty = false;

		o = sts.option(form.DummyValue, '_extip_hint', _('Public IP service'));
		o.cfgvalue = function() { return ''; };
		o.renderWidget = function() {
			return E('a', {
				'href': '#',
				'click': function(ev) {
					ev.preventDefault();
					var t = document.querySelector('[id$="-extip_url"]');
					if (t) { t.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
				}
			}, _('Shared with "External IP" - set it under "For experts"'));
		};

		var tel = m.section(form.NamedSection, 'tele', 'tele', _('Telemetry'),
			_('A small JSON file with the modem signal, operator, band and traffic for a smart home, an external display or another router. It never contains IMEI, IMSI, ICCID or cell IDs, and the phone number only if you turn it on below.'));
		tel.addremove = false;

		o = tel.option(form.Flag, 'enabled', _('Export telemetry'),
			_('Keep /tmp/5gmodem/tele.json up to date. It is written from the metrics the app already collects and sends no extra requests to the modem.'));
		o.default = '1';
		o.rmempty = false;

		o = tel.option(form.Flag, 'http', _('Publish over HTTP'),
			_('Serve the file at %s. Anyone on the LAN can read it without a password. Another router with this app that gets internet from this one over USB will then show its signal and operator.')
				.format('http://' + window.location.hostname + '/cgi-bin/5gmodem-tele'));
		o.default = '0';
		o.rmempty = false;
		o.depends('enabled', '1');

		o = tel.option(form.Flag, 'publish_ip', _('Include addresses'),
			_('Add the carrier address and the external address to the published file and to MQTT. Off by default: a stream of addresses with timestamps is a log of when the address changed and when the router was on.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('enabled', '1');

		o = tel.option(form.Flag, 'publish_phone', _('Include the phone number'),
			_('Add the SIM phone number to the published file and to MQTT, so that a router getting internet from this one over USB shows it too. Off by default: anyone on the LAN and everyone with access to the broker will see the number.'));
		o.default = '0';
		o.rmempty = false;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'mqtt_host', _('MQTT broker'),
			_('Address of the broker. Leave empty to keep MQTT off. Needs the mosquitto-client package.'));
		o.datatype = 'host';
		o.placeholder = '192.168.1.10';
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'mqtt_port', _('MQTT port'));
		o.datatype = 'port';
		o.placeholder = '1883';
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'mqtt_user', _('MQTT user'));
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'mqtt_pass', _('MQTT password'));
		o.password = true;
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'name', _('Device name'),
			_('Used in the MQTT topic and in Home Assistant. Empty - the router hostname.'));
		o.datatype = 'and(minlength(1),maxlength(32))';
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Value, 'mqtt_topic', _('MQTT topic'),
			_('Empty - 5gmodem/ followed by the device name. The state is published to the topic with /state appended.'));
		o.rmempty = true;
		o.depends('enabled', '1');

		o = tel.option(form.Button, '__tele_disc', _('Home Assistant'),
			_('Announce the sensors to Home Assistant over MQTT discovery. Save the broker settings first.'));
		o.inputtitle = _('Announce sensors');
		o.inputstyle = 'apply';
		o.depends('enabled', '1');
		o.onclick = function(ev) {
			var btn = ev.target;
			var fld = (btn.closest && btn.closest('.cbi-value-field')) || btn.parentNode;
			var box = fld.querySelector('.tele-res');
			if (!box) { box = E('div', { 'class': 'tele-res' }); fld.appendChild(box); }
			btn.disabled = true;
			dom.content(box, E('div', {}, _('Sending…')));
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/telemetry.sh', [ 'status' ]), '{}')
				.then(function(st) {
					var j = {};
					try { j = JSON.parse(st || '{}'); } catch (e) {}
					if (String(j.mqtt_client) !== '1') { return { err: _('mosquitto_pub is not installed: install the mosquitto-client-nossl package.') }; }
					if (String(j.broker) !== '1') { return { err: _('The broker is not saved yet: press Save first.') }; }
					return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/telemetry.sh', [ 'discovery' ]), '')
						.then(function(r) { return (String(r).indexOf('"ok"') >= 0) ? { ok: 1 } : { err: _('The broker did not accept the announcement.') }; });
				}).then(function(r) {
					dom.content(box, E('div', { 'style': r.ok ? '' : 'color:#c0392b' },
						r.ok ? _('Sensors announced. They appear in Home Assistant under MQTT devices.') : r.err));
					btn.disabled = false;
				});
		};

		var exp = m.section(form.TypedSection, '5gmodem', _('For experts'),
			_('Rarely needed options. The defaults are fine for most setups.'));
		exp.anonymous = true;

		o = exp.option(form.Flag, 'show_ttl', _('Show TTL fixing'),
			_('Show the "TTL fixing" block on the Network page.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		o = exp.option(form.Flag, 'align_enabled', _('Alignment'),
			_('Live signal metrics and a tone for aiming an external antenna.'));
		o.default = '0';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

		var exsv = exp.option(form.SectionValue, '__extipsvc', form.TypedSection, '5gmodem');
		var exs = exsv.subsection;
		exs.anonymous = true;
		exs.title = _('External IP');
		exs.description = _('Where the router asks what its address looks like from the outside. The speed-test card uses the same service.');

		o = exs.option(form.Value, 'extip_url', _('IPv4 service'),
			_('Only this service is queried - there are no silent fallbacks. One that also returns the country (like ip-api.com) gets a flag shown next to the address. Foreign services often stay silent over Russian cellular; the Yandex one answers there.'));
		o.value('http://ip-api.com/line/?fields=countryCode,query', 'ip-api.com (IP + ' + _('country') + ')');
		o.value('https://api.ipify.org', 'ipify (api.ipify.org)');
		o.value('https://ifconfig.me/ip', 'ifconfig.me');
		o.value('https://icanhazip.com', 'icanhazip.com');
		o.value('https://ident.me', 'ident.me');
		o.value('https://ipinfo.io/ip', 'ipinfo.io');
		o.value('https://ipv4-internet.yandex.net/api/v0/ip', 'Yandex - RU (' + _('works over cellular') + ')');
		o.default = 'http://ip-api.com/line/?fields=countryCode,query';
		o.placeholder = 'http://ip-api.com/line/?fields=countryCode,query';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_url6', _('IPv6 service'),
			_('Queried only when the router actually has an IPv6 default route - otherwise the request would just sit there until it times out.'));
		o.value('https://api6.ipify.org', 'ipify (api6.ipify.org)');
		o.value('https://v6.ident.me', 'ident.me (v6)');
		o.value('https://ipv6.icanhazip.com', 'icanhazip.com (v6)');
		o.default = 'https://api6.ipify.org';
		o.placeholder = 'https://api6.ipify.org';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_cc_url', _('Country lookup'),
			_('Used only when the service above returns an address but no country: the flag is then resolved by a second request, for the country alone. Use {ip} as the address placeholder.'));
		o.value('http://ip-api.com/line/{ip}?fields=countryCode', 'ip-api.com');
		o.value('https://ipapi.co/{ip}/country/', 'ipapi.co');
		o.placeholder = 'http://ip-api.com/line/{ip}?fields=countryCode';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_ua', _('User-Agent'),
			_('Header sent with the request. Some services answer a console client with plain text and a browser with an HTML page; and a header of your own keeps the router from introducing itself as one. Empty - whatever curl/wget sends by default.'));
		o.value('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', 'Chrome (Windows)');
		o.value('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', 'Safari (macOS)');
		o.value('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1', 'Safari (iPhone)');
		o.value('curl/8.19.0', 'curl');
		o.rmempty = true;

		o = exs.option(form.Button, '__extip_check', _('Check now'),
			_('Query the services above with the current settings and show what they answer.'));
		o.inputtitle = _('Check');
		o.inputstyle = 'apply';
		o.onclick = function(ev, section_id) {
			var btn = ev.target;
			var fld = (btn.closest && btn.closest('.cbi-value-field')) || btn.parentNode;
			var box = fld.querySelector('.extip-res');
			if (!box) { box = E('div', { 'class': 'extip-res' }); fld.appendChild(box); }
			var u4 = this.section.formvalue(section_id, 'extip_url') || 'http://ip-api.com/line/?fields=countryCode,query';
			var u6 = this.section.formvalue(section_id, 'extip_url6') || '';
			var ua = this.section.formvalue(section_id, 'extip_ua') || '';
			var line = function(fam, res) {
				var d = {};
				try { d = JSON.parse(res || '{}'); } catch (e) {}
				if (d.ok == 1) {
					return E('div', {}, [
						E('span', { 'class': 'extip-res-fam' }, fam + ': '),
						E('span', {}, [ extip.withFlag(d.ip, d.cc) ]),
						d.src ? E('span', { 'class': 'extip-res-src' }, [ ' - ' + d.src ]) : ''
					]);
				}
				return E('div', { 'class': 'extip-res-bad' },
					[ fam + ': ' + _('no answer from %s').format(d.src || '?') ]);
			};
			btn.disabled = true;
			dom.content(box, E('div', { 'class': 'extip-res-wait' }, _('Checking…')));
			return L.resolveDefault(fs.exec_direct(EXTIPBIN, [ 'probe', u4, '4', ua ]), '')
				.then(function(r4) {
					var out = [ line('extIPv4', r4) ];
					if (!u6) { return out; }
					return L.resolveDefault(fs.exec_direct(EXTIPBIN, [ 'probe', u6, '6', ua ]), '')
						.then(function(r6) { out.push(line('extIPv6', r6)); return out; });
				}).then(function(out) {
					dom.content(box, out);
					btn.disabled = false;
				});
		};

		o = exp.option(form.Flag, 'extip_enabled', _('Show the external address'),
			_('Show it next to the address the carrier assigned - in the modem card as "IPv4: 10.x.x.x | 1.2.3.4". Behind CGNAT or a tunnel the two differ, and that difference tells you whether the router\'s own traffic goes through the VPN. Off by default: this is a request to a third-party service.'));
		o.default = '0';
		o.rmempty = false;

		var exdv = exp.option(form.SectionValue, '__extipshow', form.TypedSection, '5gmodem');
		exdv.depends('extip_enabled', '1');
		var exd = exdv.subsection;
		exd.anonymous = true;

		o = exd.option(form.Flag, 'extip_in_netpri', _('Show in the priority bar'),
			_('On the card of the uplink that currently carries the traffic, show the external address instead of the one assigned by the carrier.'));
		o.default = '0';
		o.rmempty = false;

		o = exd.option(ListDropdown, 'extip_ttl', _('Refresh interval'),
			_('How often the address is looked up again. A change of uplink refreshes it immediately, without waiting for the interval.'));
		o.value('60', _('Every minute'));
		o.value('300', _('Every 5 minutes'));
		o.value('900', _('Every 15 minutes'));
		o.value('1800', _('Every 30 minutes'));
		o.default = '300';

		o = exp.option(form.Flag, 'mwan3_metrics', _('mwan3-compatible metrics'),
			_('Uplink metrics start at 10 (10, 20, 30...) as mwan3 expects. When off they start at 100 (100, 110, 120...), leaving 1-99 free for tunnels. Takes effect on the next priority change.'));
		o.default = '0';
		o.rmempty = false;

		var bl = usbDevs.filter(function(d) {
			return d.known !== '1' || d.why === 'ignored' || d.why === 'forced' || d.absent === '1';
		});
		var devLabel = function(d) {
			var parts = [];
			if (d.product) { parts.push(d.product); }
			parts.push(d.vidpid);
			var label = parts.join(' — ');
			var ports = (d.ports || []).join(', ');
			if (d.absent === '1') { label += ' (' + _('not on the bus') + ')'; }
			else if (ports) { label += ' — ' + ports; }
			var why = {
				vendor:  _('cellular module vendor'),
				driver:  _('modem driver in the kernel'),
				mbim:    _('MBIM interface'),
				ecm:     _('CDC Ethernet interface'),
				ncm:     _('CDC NCM interface'),
				profile: _('has answered as a modem before'),
				forced:  _('returned to modems by hand'),
				bridge:  _('USB-to-serial adapter'),
				service: _('modem in a flashing or boot mode'),
				ignored: _('excluded by hand'),
				none:    _('no modem driver and no modem network interface')
			}[d.why];
			if (why) { label += ' — ' + why + (d.detail ? ' (' + d.detail + ')' : ''); }
			return label;
		};
		var blBoxes = [];
		var blSeen = {};
		var blItems = [];
		bl.forEach(function(d) {
			if (blSeen[d.vidpid]) { return; }
			blSeen[d.vidpid] = true;
			var w = new ui.Checkbox(d.skip === '1' ? '1' : '0',
				{ id: 'blk-' + d.vidpid.replace(':', '_') });
			blBoxes.push({ dev: d, w: w });
			var wn = w.render();
			blItems.push(E('div', { 'class': 'tg-blitem' }, [ wn, E('span', {
				'style': 'cursor:pointer',
				'click': function() { wn.querySelector('input').click(); }
			}, [ devLabel(d) ]) ]));
		});
		var blBody = E('div', {}, blItems.length ? blItems
			: [ E('em', {}, _('No doubtful devices: everything found on the bus is in the modem database.')) ]);
		var blT = null;
		blBody.addEventListener('widget-change', function() {
			if (blT) { window.clearTimeout(blT); }
			blT = window.setTimeout(function() {
				var ign = [], force = [];
				blBoxes.forEach(function(b) {
					if (b.w.isChecked()) {
						if (b.dev.auto === '1') { ign.push(b.dev.vidpid); }
					} else if (b.dev.auto !== '1') {
						force.push(b.dev.vidpid);
					}
				});
				fs.exec('/usr/share/5gmodem/notmodem.sh',
					[ 'setblack', ign.join(' '), force.join(' ') ])
					.then(function() { window.location.reload(); })
					.catch(function(e) { ui.addNotification(null, E('p', [ String((e && e.message) || e) ]), 'error'); });
			}, 600);
		});
		o = exp.option(form.DummyValue, '_blacklist', _('Device blacklist'),
			_('USB devices the app is not sure about - they are missing from its modem database. Tick one to drop it from the app: no tab, no AT probing, no place in internet priority. Applied immediately.'));
		o.depends({ netonly: '1', '!reverse': true });
		o.render = function(option_index, section_id) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Device blacklist')),
				E('div', { 'class': 'cbi-value-field' }, [ blBody,
					E('div', { 'class': 'cbi-value-description' },
						_('USB devices the app is not sure about - they are missing from its modem database. Tick one to drop it from the app: no tab, no AT probing, no place in internet priority. Applied immediately.')) ])
			]);
		};

		var _asT = null;
		var _asNode = null;
		var _asSig = null;

		var formSig = function() {
			if (!_asNode) { return ''; }
			var parts = [];
			_asNode.querySelectorAll('input, textarea').forEach(function(el) {
				parts.push((el.type === 'checkbox' || el.type === 'radio')
					? (el.checked ? '1' : '0') : String(el.value));
			});
			_asNode.querySelectorAll('.cbi-dropdown').forEach(function(el) {
				var w = dom.findClassInstance(el);
				parts.push(w ? String(w.getValue()) : '');
			});
			return parts.join('\u0001');
		};

		var applyOwn = function() {
			return uci.changes().then(function(ch) {
				var cfgs = Object.keys(ch || {});
				if (cfgs.length !== 1 || cfgs[0] !== '5gmodem') { return; }
				return uci.callApply(0, false).then(function() {
					if (ui.changes && ui.changes.init) { return ui.changes.init(); }
				});
			});
		};

		var autoSave = function(heavy) {
			if (_asT) { window.clearTimeout(_asT); }
			_asT = window.setTimeout(function() {
				if (heavy === true) {
					_asSig = null;
					m.save(null, true).then(function() { _asSig = formSig(); })
						.catch(function() {});
					return;
				}
				var sig = formSig();
				if (_asSig !== null && sig === _asSig) { return; }
				_asSig = sig;
				m.parse()
					.then(function() { return uci.save(); })
					.then(applyOwn)
					.then(_gateAfterAutosave)
					.catch(function() {});
			}, 400);
		};

		return Promise.resolve(m.render()).then(function(formNode) {
			_asNode = formNode;
			_asSig = formSig();
			var onChange = function() { autoSave(false); };
			formNode.addEventListener('change', onChange);
			formNode.addEventListener('widget-change', onChange);
			formNode.addEventListener('cbi-dropdown-change', onChange);
			formNode.addEventListener('click', function(ev) {
				if (ev.target.closest && ev.target.closest('.cbi-button-add, .cbi-button-remove')) { autoSave(true); }
			});
			updVersion();
			apnVersion();
			formNode.querySelectorAll('.cbi-button-add').forEach(function(b) {
				var w = b.closest('[id*="__pingcards"], [id*="__svccards"]');
				if (!w) { return; }
				b.title = (w.id.indexOf('__pingcards') >= 0)
					? _('Add ping card') : _('Add service card');
			});
			return E('div', {}, [
				E('div', { 'class': 'cbi-map' }, [ updateBlock ]),
				E('div', { 'class': 'tg-modem-form' }, [ formNode ])
			]);
		});
	},

	handleSave: null,
	handleReset: null,
	handleSaveApply: function(ev) {
		return this.handleSave_(ev);
	},
	handleSave_: function(ev) {
		var tasks = [];
		document.getElementById('maincontent')
			.querySelectorAll('.cbi-map').forEach(function(map) {
				tasks.push(L.dom.callClassMethod(map, 'save'));
			});
		return Promise.all(tasks).then(function() {
			return uci.changes();
		}).then(function(ch) {
			var n = 0;
			for (var k in ch) { n += (ch[k] || []).length; }
			if (!n) { return; }
			return commitPending().then(function() {
				return uci.changes();
			}).then(function(ch2) {
				var n2 = 0;
				for (var k2 in ch2) { n2 += (ch2[k2] || []).length; }
				if (!n2) {
					if (ui.changes && ui.changes.setIndicator) { ui.changes.setIndicator(0); }
					return;
				}
				return ui.changes.apply(true);
			});
		});
	}
});
