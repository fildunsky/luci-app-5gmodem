'use strict';
'require baseclass';
'require fs';
'require ui';
'require uci';
'require view.modem5g.mutil as mutil';

var ctx = null;

var _bandsAfterBusy = false;

var _bandsRetry = 0;

var _bandsRetryMax = 3;

var _has3gMM = false;

var _bandsPollN = 0;

var _revealTries = 0;

var _revealTriesMax = 10;

var bandsOther = [];

var bandsStaticNote = false;

var _bandsOpAt = 0;

function _bandsOpActive() {
	return _bandsAfterBusy && (Date.now() - _bandsOpAt) < 120000;
}

function _bandsOpStart(args, msg) {
	if (_bandsOpActive()) { return; }
	ctx.setModemBusy(msg);
	_bandsAfterBusy = true;
	_bandsOpAt = Date.now();
	L.resolveDefault(fs.exec('/usr/share/5gmodem/bands.sh', args), {}).then(function(res) {
		if (!res || typeof res.code !== 'number' || res.code === 0) { return; }
		_bandsAfterBusy = false;
		ctx.clearModemBusy(true);
		var why = String(res.stdout || res.stderr || '').trim();
		ui.addNotification(null, E('p', [ _('Failed to set network mode') + (why ? ': ' + why : '') ]), 'error');
	});
}

var BAND_KIND = { 'bands-lte': 'lte', 'bands-nr': 'nr', 'bands-3g': 'umts', 'bands-2g': 'gsm' };
var _bandReg = null;
var _bandAct = null;
var _bandFilterSig = '';

function _bandNum(b) {
	return parseInt(String(b == null ? '' : b).replace(/\D+/g, ''), 10);
}

function _bandActive(j) {
	var out = { lte: {}, nr: {} };
	[ 'mode', 'pband', 's1band', 's2band', 's3band', 's4band' ].forEach(function(k) {
		var v = String((j || {})[k] == null ? '' : j[k]), re = /(?:^|[^A-Za-z0-9])([Bn])(\d+)(?![0-9])/g, m;
		while ((m = re.exec(v))) { (m[1] === 'n' ? out.nr : out.lte)[m[2]] = true; }
	});
	return out;
}

var _bandMoreMem = {};
function _bandMoreOpen(id) {
	if (_bandMoreMem[id] != null) { return _bandMoreMem[id]; }
	try { return window.localStorage.getItem('5gm-bandsmore-' + id) === '1'; } catch (e) { return false; }
}

function bandFilter(id) {
	var cont = document.getElementById(id);
	if (!cont) { return; }
	var chip = cont.querySelector('.tg-bandmore');
	var btns = Array.prototype.slice.call(cont.querySelectorAll('button[data-band]'));
	btns.forEach(function(b) {
		if (!b.hasAttribute('data-on0')) { b.setAttribute('data-on0', b.classList.contains('cbi-button-action') ? '1' : '0'); }
	});
	var reg = _bandReg || mutil.bandRegion(window._lastJson);
	var rel = reg ? reg.bands[BAND_KIND[id]] : null;
	var extra = [];
	if (rel && rel.length && btns.length) {
		var aa = _bandAct || _bandActive(window._lastJson);
		var act = (id === 'bands-nr') ? aa.nr : (id === 'bands-lte') ? aa.lte : {};
		var on0 = btns.filter(function(b) { return b.getAttribute('data-on0') === '1'; }).length;
		var wide = on0 >= Math.ceil(btns.length * 0.8);
		extra = btns.filter(function(b) {
			var n = _bandNum(b.getAttribute('data-band'));
			if (isNaN(n) || rel.indexOf(n) >= 0 || act[n]) { return false; }
			return wide || (b.getAttribute('data-on0') !== '1' && !b.classList.contains('cbi-button-action'));
		});
	}
	var open = _bandMoreOpen(id);
	btns.forEach(function(b) { b.classList.toggle('tg-band-hidden', !open && extra.indexOf(b) >= 0); });
	var onHidden = extra.filter(function(b) { return b.classList.contains('cbi-button-action'); }).length;
	var sig = extra.length ? ((open ? 'o' : 'c') + '|' + extra.length + '|' + onHidden) : '';
	if (chip && chip.getAttribute('data-sig') === sig && cont.lastElementChild === chip) { return; }
	if (chip) { chip.parentNode.removeChild(chip); }
	if (!sig) { return; }
	var toggle = function(ev) {
		ev.preventDefault();
		_bandMoreMem[id] = !_bandMoreOpen(id);
		try { window.localStorage.setItem('5gm-bandsmore-' + id, _bandMoreMem[id] ? '1' : '0'); } catch (e) {}
		bandFilter(id);
	};
	cont.appendChild(E('button', {
		'class': 'btn cbi-button tg-bandmore' + (open ? ' open' : ''),
		'type': 'button',
		'data-sig': sig,
		'aria-expanded': open ? 'true' : 'false',
		'title': open ? _('Hide bands not used by operators in this country')
			: _('%d more bands supported by the modem, %d of them enabled').format(extra.length, onHidden),
		'click': toggle
	}, open ? [ _('Show fewer') ]
		: [ '+' + extra.length, onHidden ? E('small', {}, _('(%d enabled)').format(onHidden)) : '' ]));
}

function bandFilterAll() {
	Object.keys(BAND_KIND).forEach(bandFilter);
}

function bandFilterTick(json) {
	if (!json || typeof json !== 'object' || json.error || !json.modem) { return; }
	var hasMcc = [ json.home_mcc, json.operator_mcc ].some(function(v) { return (/^\d{3}$/).test(String(v == null ? '' : v).trim()); })
		|| /^\d{6,}$/.test(String(json.imsi == null ? '' : json.imsi).trim());
	if (hasMcc) { _bandReg = mutil.bandRegion(json); }
	var a = _bandActive(json);
	if (Object.keys(a.lte).length || Object.keys(a.nr).length || !_bandAct) { _bandAct = a; }
	var sig = (_bandReg ? _bandReg.mcc : '') + '|' + Object.keys(_bandAct.lte).sort().join(',') + '|' + Object.keys(_bandAct.nr).sort().join(',');
	if (sig === _bandFilterSig) { return; }
	_bandFilterSig = sig;
	bandFilterAll();
}

function buildBandButtons(supported, current, prefix) {
	var numsort = function(a, b) { return parseInt(a.replace(/\D+/g, ''), 10) - parseInt(b.replace(/\D+/g, ''), 10); };
	return supported.filter(function(b) { return b.indexOf(prefix) == 0; }).sort(numsort).map(function(b) {
		return E('button', {
			'class': 'btn cbi-button' + (current.indexOf(b) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': b,
			'title': (b.indexOf('utran-') == 0) ? ''
				: mutil.bandTitle(b.replace(/\D+/g, ''), b.indexOf('ngran-') == 0),
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, mutil.bandLabel(b));
	});
}

function renderBandToggles(contId, bands, current, prefix) {
	var cont = document.getElementById(contId);
	if (!cont) { return; }
	if (ctx.sameRender(cont, prefix + '|' + bands.join(',') + '|' + current.join(','))) { bandFilter(contId); return; }
	cont.innerHTML = '';
	buildBandButtons(bands, current, prefix).forEach(function(btn) {
		cont.appendChild(btn);
	});
	bandFilter(contId);
}

function clear3gRow() {
	renderBandToggles('bands-3g', [], [], 'utran-');
	var r3 = document.getElementById('bands3gn');
	if (r3) { r3.style.display = 'none'; }
}

function _bandsFor() {
	var p = (ctx.pagePath && ctx.pagePath()) || '';
	return p ? [ p ] : [];
}

var _bandsWarmed = false;
function _bandsKey() {
	var am = '';
	try { am = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''; } catch (e) {}
	return 'bands5g2-' + ((ctx.pagePath && ctx.pagePath()) || '') + (am ? ('-' + am) : '');
}
function warmRenderBands() {
	if (_bandsWarmed) { return; }
	_bandsWarmed = true;
	var c = null;
	try { c = JSON.parse(window.localStorage.getItem(_bandsKey()) || 'null'); } catch (e) {}
	if (!c || !c.j) { return; }
	var mdl = '';
	try {
		var ap = (ctx.pagePath && ctx.pagePath()) || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		mdl = uci.get('5gmodem', 'm_' + ap.replace(/[^A-Za-z0-9]/g, '_'), 'model') || '';
	} catch (e) {}
	if (!mdl || !c.m || c.m !== mdl) {
		if (mdl && c.m && c.m !== mdl) {
			try { window.localStorage.removeItem(_bandsKey()); } catch (e) {}
		}
		return;
	}
	try {
		if (c.t === 'mm') { applyMgmtMM(c.j); }
		else if (c.t === 'vendor') { applyVendorJson(c.j); }
	} catch (e) {}
}
function _bandsRemember(t, j) {
	var mdl = '';
	try {
		var ap = (ctx.pagePath && ctx.pagePath()) || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		mdl = uci.get('5gmodem', 'm_' + ap.replace(/[^A-Za-z0-9]/g, '_'), 'model') || '';
	} catch (e) {}
	try { window.localStorage.setItem(_bandsKey(), JSON.stringify({ t: t, j: j, m: mdl })); } catch (e) {}
	mutil.lsTouch(_bandsKey());
}

function loadBands() {
	if (!ctx.blockExpanded('freq')) { return Promise.resolve(); }
	warmRenderBands();
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ 'mgmtinfo' ].concat(_bandsFor())), '{}').then(ctx.forPage(function(out) {
		var j = {}; try { j = JSON.parse(out) || {}; } catch (e) {}
		if (!j.source) { return; }
		if (j.source != 'mmcli') { return loadBandsModemband(); }
		if (j.pending) { return; }
		applyMgmtMM(j);
		_bandsRemember('mm', j);
	}));
}

function ensureMmModeButtons() {
	var c = document.getElementById('modesw-btns');
	if (!c || c.querySelector('button[data-allowed]')) { return; }
	c.innerHTML = '';
	c.removeAttribute('data-sig');
	[
		[ _('Auto'), '2g|3g|4g|5g', '5g' ],
		[ '2G', '2g', '' ],
		[ '3G', '3g', '' ],
		[ '4G', '3g|4g', '4g', '4g' ],
		[ '4G+5G', '3g|4g|5g', '5g' ],
		[ '5G', '3g|5g', '5g', '5g' ]
	].forEach(function(mdef) {
		c.appendChild(E('button', {
			'class': 'btn cbi-button',
			'data-allowed': mdef[1],
			'data-preferred': mdef[2],
			'data-pure': mdef[3] || '',
			'click': ui.createHandlerFn(this, function(ev) {
				var b = ev.currentTarget;
				return setNetMode(b.getAttribute('data-allowed'), b.getAttribute('data-preferred'), mdef[0]);
			})
		}, mdef[0]));
	});
}

function applyPureModes(modes) {
	var pure = {};
	(modes || []).forEach(function(m) {
		var a = String(m).split(':')[0];
		if (a && a.indexOf('|') < 0) { pure[a] = 1; }
	});
	document.querySelectorAll('#modesw-btns .cbi-button[data-pure]').forEach(function(b) {
		var t = b.getAttribute('data-pure');
		if (!t || !pure[t]) { return; }
		b.setAttribute('data-allowed', t);
		b.setAttribute('data-preferred', '');
	});
}

function applyMgmtMM(j) {
		bandSource = 'mmcli';
		bandsReadOnly = false; bandsTakeover = false;
		bandsStaticNote = false;
		_revealTries = 0;
		var note = document.getElementById('bandnote');
		if (note) { note.style.display = 'none'; }
		var sup3 = j.sup3g || [], sup4 = j.sup4g || [], sup5 = j.sup5g || [];
		var cur = (j.cur3g || []).concat(j.cur4g || [], j.cur5g || []);
		bandsOther = j.other || [];
		_has3gMM = sup3.length > 0;
		renderBandToggles('bands-3g', sup3, cur, 'utran-');
		renderBandToggles('bands-lte', sup4, cur, 'eutran-');
		renderBandToggles('bands-nr', sup5, cur, 'ngran-');
		var show = function(id, on) { var e = document.getElementById(id); if (e) { e.style.display = on ? '' : 'none'; } };
		show('modeswn', true); show('bands3gn', sup3.length); show('bandsn', sup4.length);
		show('bands5gn', sup5.length); show('bandsactn', true);
		render5gMode(null);
		renderCaEnabled(null);
		renderCellLock(null);
		renderCellLock5g(null);
		render256qam(null);
		renderUlca(null);
		ensureMmModeButtons();
		applyPureModes(j.modes);
		var has2 = bandsOther.some(function(b) { return /^(egsm|dcs|pcs|g850|g450|g480|g750|g380|g410|g710|g810)$/.test(b); });
		var techOk = { '2g': has2, '3g': sup3.length > 0, '4g': sup4.length > 0, '5g': sup5.length > 0 };
		document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
			var al = (b.getAttribute('data-allowed') || '').split('|');
			var isAuto = (al.length == 4 && b.getAttribute('data-preferred') == '5g');
			var main = al.length == 1 ? al : al.slice(1);
			var ok = isAuto || main.every(function(t) { return techOk[t] !== false; });
			b.style.display = ok ? '' : 'none';
		});
		var am = (j.allowedmode || '').split('|').filter(function(x) { return x; }).sort().join('|') || '2g|3g|4g|5g';
		var pm = j.allowedmode ? (j.preferredmode || '') : '5g';
		document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
			var a = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
			var on = (a == am && (pm == 'none' || (b.getAttribute('data-preferred') || '') == pm));
			b.classList.toggle('tg-current', on);
		});
}

var bandSource = 'mmcli';

var bandsReadOnly = false;

var bandsTakeover = false;

function buildBandButtonsNum(supported, enabled, btype) {
	var pfx = (btype == '2g') ? 'GSM ' : ((btype == 'lte' || btype == '3g') ? 'B' : 'n');
	return (supported || []).map(function(n) {
		n = parseInt(n, 10);
		return E('button', {
			'class': 'btn cbi-button' + ((enabled || []).indexOf(n) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': String(n),
			'data-btype': btype,
			'title': (btype == '2g' || btype == '3g') ? '' : mutil.bandTitle(n, btype != 'lte'),
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, pfx + n);
	});
}

function renderCaEnabled(state, canSwitch) {
	var row = document.getElementById('caenn');
	var cell = document.getElementById('caen-cell');
	if (!row || !cell) { return; }
	if (state !== 'off') { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';
	cell.appendChild(E('span', { 'style': 'color:#e58a00; margin-right:.6em' },
		_('Disabled in modem')));
	cell.appendChild(E('span', { 'style': 'opacity:.65; font-size:90%' },
		_('The modem works without carrier aggregation, as if it were cat4')));
	if (canSwitch) {
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-apply',
			'style': 'margin-left:.6em',
			'click': ui.createHandlerFn(this, function() {
				_runBands([ 'setcaenabled', '1' ],
					_('Turning carrier aggregation on — the modem is rebooting (1-2 min)…'));
			})
		}, _('Turn on')));
	}
}

function _ensureRow(id, cellId, label, afterId) {
	var row = document.getElementById(id);
	if (row) { return row; }
	var anchor = document.getElementById(afterId);
	if (!anchor || !anchor.parentNode) { return null; }
	row = E('tr', { 'class': 'tr', 'id': id, 'style': 'display:none' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
		E('td', { 'class': 'td left tginfo-modesw', 'id': cellId }, [ '-' ])
	]);
	anchor.parentNode.insertBefore(row, anchor.nextSibling);
	return row;
}

function render256qam(state) {
	var row = _ensureRow('qam256n', 'qam256-cell', _('256QAM (download)'), 'caenn');
	var cell = document.getElementById('qam256-cell');
	if (!row || !cell) { return; }
	if (state !== 'on' && state !== 'off') { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	var on = (state === 'on');
	cell.appendChild(E('button', {
		'class': 'btn cbi-button ' + (on ? 'cbi-button-reset' : 'cbi-button-apply'),
		'click': ui.createHandlerFn(this, function() {
			_runBands([ 'set256qam', on ? '0' : '1' ],
				on ? _('Turning 256QAM off — the modem is restarting its radio…')
				   : _('Turning 256QAM on — the modem is restarting its radio…'));
		})
	}, on ? _('Turn off') : _('Turn on')));
	cell.appendChild(E('span', { 'style': 'margin-left:.6em' },
		on ? _('Enabled') : _('Disabled')));
	if (!on) {
		cell.appendChild(E('span', { 'style': 'opacity:.65; font-size:90%; margin-left:.6em' },
			_('Helps only with a strong signal and a base station that supports it')));
	}
}

function renderUlca(state) {
	var row = _ensureRow('ulcan', 'ulca-cell', _('Uplink aggregation'), 'caenn');
	var cell = document.getElementById('ulca-cell');
	if (!row || !cell) { return; }
	if (state !== 'on' && state !== 'off') { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	if (state === 'on') {
		cell.appendChild(E('span', {}, _('Enabled')));
		return;
	}
	cell.appendChild(E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': ui.createHandlerFn(this, function() {
			_runBands([ 'setulca', 'on' ],
				_('Enabling uplink aggregation — the modem is restarting its radio…'));
		})
	}, _('Enable')));
	cell.appendChild(E('span', { 'style': 'margin-left:.6em; color:#e58a00' },
		_('Disabled in modem')));
	cell.appendChild(E('span', { 'style': 'opacity:.65; font-size:90%; margin-left:.6em' },
		_('Upload often sits at 1-2 Mbit/s until this is on')));
}

function render5gMode(state) {
	var row = document.getElementById('mode5gn');
	var cell = document.getElementById('mode5g-cell');
	if (!row || !cell) { return; }
	if (!state) { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	var full = (state === 'sa+nsa');
	var txt = ({
		'sa+nsa': _('Enabled (SA + NSA)'),
		'sa':     _('Only SA enabled'),
		'nsa':    _('Only NSA enabled'),
		'off':    _('Disabled in modem')
	})[state] || state;

	cell.appendChild(E('span', {
		'style': full ? 'margin-right:.6em' : 'margin-right:.6em; color:#e58a00'
	}, [ txt ]));
	if (full) { return; }

	cell.appendChild(E('span', {
		'style': 'opacity:.65; font-size:90%; margin-right:.6em'
	}, _('5G bands and cell lock have no effect until this is enabled')));

	cell.appendChild(E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': ui.createHandlerFn(this, function() {
			_bandsOpStart([ 'set5gmode', 'full' ], _('Enabling 5G — the modem is restarting its radio…'));
		})
	}, _('Enable 5G')));
}

var _cellLockWritable = false;

function _runBands(args, msg) {
	_bandsOpStart(args, msg);
}

function lockCell(ear, pci) {
	if (!ear || ear === '-' || pci == null || pci === '' || pci === '-') {
		ui.addNotification(null, E('p', _('Cell EARFCN/PCI unknown yet - try again in a few seconds')), 'warning');
		return;
	}
	_runBands([ 'setcelllock', 'cell', String(ear), String(pci) ],
		_('Locking to cell EARFCN %s, PCI %s - the modem re-registers...').format(ear, pci));
}

function renderCellLock(state) {
	var _clp = String(state || '').split(' ');
	_cellLockWritable = !!state && state !== 'Unsupported' && _clp[_clp.length - 1] !== 'readonly';
	var row = document.getElementById('celllockn');
	var cell = document.getElementById('celllock-cell');
	if (!row || !cell) { return; }
	if (!state) { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	var parts = String(state).split(' ');
	var locked = (parts[0] === 'cell' || parts[0] === 'arfcn');
	var unlockable = (parts[parts.length - 1] === 'unlockable');
	var txt;
	if (!locked) {
		txt = unlockable ? _('Lock state unknown - this modem does not report it')
		                 : _('Not locked');
	} else if (parts[0] === 'cell') {
		txt = _('Locked to cell: EARFCN %s, PCI %s').format(parts[1], parts[2]);
	} else {
		txt = _('Locked to frequency: EARFCN %s').format(parts[1]);
	}

	if (parts[parts.length - 1] === 'readonly') {
		cell.appendChild(E('span', { 'style': 'margin-right:.6em' }, [ txt ]));
		if (locked) {
			cell.appendChild(E('span', {
				'style': 'opacity:.65; font-size:90%'
			}, _('Read-only for this modem: the lock can be removed with an AT command only')));
		}
		return;
	}

	var run = _runBands;

	if (locked || unlockable) {
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(this, function() {
				return run([ 'setcelllock', 'off' ],
					_('Removing the lock - the modem restarts, connection drops for a while...'));
			})
		}, [ (locked ? _('Unlock') : _('Reset cell lock')) ]));
	}
	if (!locked) {
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function() {
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ].concat(_bandsFor().map(function(p) { return 'for=' + p; }))), '')
					.then(function(out) {
						var m = {}; try { m = JSON.parse(out) || {}; } catch (e) {}
						var ear = m.earfcn, pci = m.pci;
						if (!ear || ear === '-' || !pci || pci === '-') {
							ui.addNotification(null, E('p',
								_('Serving cell is unknown yet - try again in a few seconds')), 'warning');
							return;
						}
						return run([ 'setcelllock', 'cell', String(ear), String(pci) ],
							_('Locking to cell EARFCN %s, PCI %s - the modem re-registers...').format(ear, pci));
					});
			})
		}, [ _('Lock to current cell') ]));
	}

	if (locked) {
		cell.appendChild(E('span', { 'style': 'margin-left:.6em' }, [ txt ]));
	} else if (unlockable) {
		cell.appendChild(E('span', {
			'style': 'opacity:.65; font-size:90%; margin-left:.6em'
		}, [ txt ]));
	}

	if (parts[parts.length - 1] === 'remembered') {
		cell.appendChild(E('span', {
			'style': 'opacity:.65; font-size:90%; margin-left:.6em'
		}, _('(after modem restart the lock stays in effect, but the modem reports it as off)')));
	}
	cell.appendChild(_cellLockCaNote());
}

function _cellLockCaNote() {
	return E('div', {
		'style': 'opacity:.65; font-size:90%; margin-top:.3em'
	}, _('While locked to one cell the modem usually stops carrier aggregation, so the speed may drop.'));
}

function renderCellLock5g(state) {
	var row = _ensureRow('celllock5gn', 'celllock5g-cell', _('5G cell lock'), 'celllockn');
	var cell = document.getElementById('celllock5g-cell');
	if (!row || !cell) { return; }
	if (!state || state === 'Unsupported') { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	var parts = String(state).split(' ');
	var locked = (parts[0] === 'cell');

	if (locked) {
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(this, function() {
				return _runBands([ 'setcelllock5g', 'off' ],
					_('Removing the lock - the modem restarts, connection drops for a while...'));
			})
		}, [ _('Unlock') ]));
		cell.appendChild(E('span', { 'style': 'margin-left:.6em' },
			[ _('Locked to cell: ARFCN %s, PCI %s').format(parts[1], parts[2]) ]));
		cell.appendChild(_cellLockCaNote());
		return;
	}

	cell.appendChild(E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function() {
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ].concat(_bandsFor().map(function(p) { return 'for=' + p; }))), '')
				.then(function(out) {
					var m = {}; try { m = JSON.parse(out) || {}; } catch (e) {}
					var ear = null, pci = null;
					for (var i = 1; i <= 4; i++) {
						if (!/^n[0-9]/.test(String(m['s' + i + 'band'] || ''))) { continue; }
						var e1 = m['s' + i + 'earfcn'], p1 = m['s' + i + 'pci'];
						if (!e1 || e1 === '-' || !p1 || p1 === '-') { continue; }
						ear = e1; pci = p1; break;
					}
					if (!ear) {
						ui.addNotification(null, E('p',
							_('No 5G carrier right now - the lock needs its ARFCN and PCI')), 'warning');
						return;
					}
					return _runBands([ 'setcelllock5g', 'cell', String(ear), String(pci) ],
						_('Locking to cell ARFCN %s, PCI %s - the modem re-registers...').format(ear, pci));
				});
		})
	}, [ _('Lock to current 5G cell') ]));
	cell.appendChild(_cellLockCaNote());
}

function nrC_hasEnabled(j) {
	return ((j.enabled5gnsa || []).length > 0) || ((j.enabled5gsa || []).length > 0);
}

function loadBandsModemband(force) {
	if (!ctx.blockExpanded('freq')) { return Promise.resolve(); }
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ force ? 'jsonrefresh' : 'json' ].concat(_bandsFor())), '').then(ctx.forPage(function(out) {
		var j = {};
		var note = document.getElementById('bandnote');
		try { j = JSON.parse(out) || {}; } catch (e) { if (note) { note.style.display = ''; } return; }
		applyVendorJson(j);
	}));
}

function applyVendorJson(j) {
		var note = document.getElementById('bandnote');
		render5gMode(j.mode5g);
		renderCaEnabled(j.ca_enabled, j.ca_switch);
		renderCellLock(j.celllock);
		renderCellLock5g(j.celllock5g);
		render256qam(j.qam256);
		renderUlca(j.ulca);
		var hasBands = (j.supported && j.supported.length) ||
		               (j.supported5gnsa && j.supported5gnsa.length) ||
		               (j.supported5gsa && j.supported5gsa.length);
		if (j.error || !hasBands) {
			if (bandSource == 'modemband') { return; }
			[ 'modeswn', 'bands2gn', 'bands3gn', 'bandsn', 'bands5gn', 'bandsactn', 'bandwarnn' ].forEach(function(id) {
				var e = document.getElementById(id); if (e) { e.style.display = 'none'; }
			});
			if (note) { note.style.display = ctx.isMM() ? 'none' : ''; }
			bandsStaticNote = !!j.nobandctl;
			if (note && j.nobandctl) {
				var nt3 = document.getElementById('bandnote-text');
				var nb3 = document.getElementById('bandnote-mm-btn');
				var modesOnly = !j.error && renderNetModes(j);
				if (nt3) { nt3.textContent = modesOnly ? _('This modem does not let the router change bands. Only the network mode can be switched.') : _('This modem does not let the router change bands or network mode.'); }
				if (nt3 && j.needpkg) { nt3.textContent = _('Install the %s package to switch bands and see RSRQ, SINR and the cell on this modem.').format(j.needpkg); }
				if (nb3) { nb3.style.display = 'none'; }
				note.style.display = '';
				if (modesOnly) { bandsReadOnly = false; applyBandsReadOnly(); }
				return;
			}
			if (ctx.isMM() && _revealTries < _revealTriesMax) {
				_revealTries++;
				window.setTimeout(revealMgmtWhenReady, 1500);
			}
			return;
		}
		_revealTries = 0;
		bandsReadOnly = !!j.readonly;
		bandsTakeover = !!j.takeover;
		bandsStaticNote = !!(j.mm_at_static || j.noat_static);
		if (note) { note.style.display = (bandsReadOnly || bandsTakeover) ? '' : 'none'; }
		if (note && j.mm_at_static) {
			var nt = document.getElementById('bandnote-text');
			var nb = document.getElementById('bandnote-mm-btn');
			if (nt) { nt.textContent = _('AT polling under ModemManager is off for this firmware (it drops the data session), so the current band selection is not read. Applying bands and mode still works; to see the current selection, enable "AT polling under ModemManager" in the modem settings.'); }
			if (nb) { nb.style.display = 'none'; }
			note.style.display = '';
		}
		if (note && j.noat_static) {
			var nt2 = document.getElementById('bandnote-text');
			var nb2 = document.getElementById('bandnote-mm-btn');
			if (nt2) { nt2.textContent = _('Background AT polling is off for this modem, so the current band selection is not read. Applying bands and mode still works.'); }
			if (nb2) { nb2.style.display = 'none'; }
			note.style.display = '';
		}
		bandSource = 'modemband';
		var row3g = document.getElementById('bands3gn');
		var c3g = document.getElementById('bands-3g');
		if (c3g && j.supported3g && j.supported3g.length) {
			if (row3g) { row3g.style.display = ''; }
			var sup3g = j.supported3g.map(function(o) { return o.band; });
			var en3g = j.enabled3g || [];
			if (!ctx.sameRender(c3g, sup3g.join(',') + '|' + en3g.join(','))) {
				c3g.innerHTML = '';
				if (sup3g.length) { buildBandButtonsNum(sup3g, en3g, '3g').forEach(function(b) { c3g.appendChild(b); }); }
			}
		} else if (c3g && j.combos3g && j.combos3g.length) {
			if (row3g) { row3g.style.display = ''; }
			if (!ctx.sameRender(c3g, String(j.current3g) + '|' + j.combos3g.map(function(o){ return o.id; }).join(','))) {
			c3g.innerHTML = '';
			j.combos3g.forEach(function(o) {
				var on = (String(j.current3g) === String(o.id));
				c3g.appendChild(E('button', {
					'class': 'btn cbi-button combo3g' + (on ? ' cbi-button-action important' : ''),
					'data-combo3g': String(o.id),
					'click': function(ev) { ev.preventDefault(); setBands3gAT(o.id, o.label); }
				}, o.label));
			});
			}
		} else if (row3g && !_has3gMM) {
			row3g.style.display = 'none';
		}

		var row2g = document.getElementById('bands2gn');
		var c2g = document.getElementById('bands-2g');
		if (c2g && j.supported2g && j.supported2g.length) {
			if (row2g) { row2g.style.display = ''; }
			var sup2g = j.supported2g.map(function(o) { return o.band; });
			var en2g = j.enabled2g || [];
			if (!ctx.sameRender(c2g, sup2g.join(',') + '|' + en2g.join(','))) {
				c2g.innerHTML = '';
				if (sup2g.length) { buildBandButtonsNum(sup2g, en2g, '2g').forEach(function(b) { c2g.appendChild(b); }); }
			}
		} else if (row2g) {
			row2g.style.display = 'none';
		}

		var supLte = (j.supported || []).map(function(o) { return o.band; });
		var supNsa = (j.supported5gnsa || []).map(function(o) { return o.band; });
		var enLte  = j.enabled || [];
		var enNsa  = j.enabled5gnsa || [];

		[ 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var e = document.getElementById(id); if (e) { e.style.display = ''; }
		});
		var warnRow = document.getElementById('bandwarnn');
		if (warnRow) { warnRow.style.display = j.bandwarn ? '' : 'none'; }

		if (supLte.length && !enLte.length && !nrC_hasEnabled(j)) {
			if ((_bandsRetry = (_bandsRetry || 0) + 1) <= _bandsRetryMax) {
				window.setTimeout(loadBandsModemband, 1500);
			}
		} else { _bandsRetry = 0; _bandsRetryMax = 3; }

		var lteC = document.getElementById('bands-lte');
		if (lteC && !ctx.sameRender(lteC, supLte.join(',') + '|' + enLte.join(','))) {
			lteC.innerHTML = '';
			if (supLte.length) { buildBandButtonsNum(supLte, enLte, 'lte').forEach(function(b) { lteC.appendChild(b); }); }
			else { lteC.textContent = '-'; }
		}
		var nrRow = document.getElementById('bands5gn');
		var nrC = document.getElementById('bands-nr');
		if (nrC) {
			if (!ctx.sameRender(nrC, supNsa.join(',') + '|' + enNsa.join(','))) {
				nrC.innerHTML = '';
				if (supNsa.length) { buildBandButtonsNum(supNsa, enNsa, 'nsa').forEach(function(b) { nrC.appendChild(b); }); }
			}
			if (!supNsa.length && nrRow) { nrRow.style.display = 'none'; }
		}

		renderNetModes(j);
		applyBandsReadOnly();
		bandFilterAll();
		_bandsRemember('vendor', j);
}

function renderNetModes(j) {
	var modeRow = document.getElementById('modeswn');
	var modeC = document.getElementById('modesw-btns');
	if (modeC && j.modes && j.modes.length) {
		if (!ctx.sameRender(modeC, String(j.currentmode) + '|' + j.modes.map(function(m){ return m.id; }).join(','))) {
			modeC.innerHTML = '';
			mutil.sortNetModes(j.modes).forEach(function(m) {
				var on = (String(j.currentmode) === String(m.id));
				modeC.appendChild(E('button', {
					'class': 'btn cbi-button' + (on ? ' tg-current' : ''),
					'data-mode': String(m.id),
					'click': function(ev) { ev.preventDefault(); setNetModeAT(m.id, _(m.label)); }
				}, [ _(m.label) ]));
			});
		}
		if (modeRow) { modeRow.style.display = ''; }
	} else if (modeRow) {
		modeRow.style.display = 'none';
	}
	return !!(j.modes && j.modes.length);
}

function switchToModemManager(btn) {
	if (btn) { btn.disabled = true; }
	return fs.exec('/usr/share/5gmodem/mkiface.sh', [ 'modem', 'modemmanager' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (String(d.proto) === 'modemmanager') {
			ui.addNotification(null, E('p', _('Interface switched to ModemManager')), 'info');
			ctx.setMM(true);
			bandsReadOnly = false;
			bandsTakeover = false;
			_bandsRetry = 0;
			_bandsRetryMax = 20;
			window.setTimeout(loadBandsModemband, 3000);
		} else {
			ui.addNotification(null, E('p', _('Could not switch the interface to ModemManager')), 'error');
		}
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Could not switch the interface to ModemManager') + ' ' + (err.message || err)), 'error');
	}).finally(function() {
		if (btn) { btn.disabled = false; }
	});
}

function switchToXmm(btn) {
	if (btn) { btn.disabled = true; }
	ctx.setModemBusy(_('Switching the modem to XMM — it is rebooting and re-enumerating (~40 s)…'));
	return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'xmm' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.error) {
			ui.hideModal();
			ctx.clearModemBusy(true);
			if (btn) { btn.disabled = false; }
			ui.addNotification(null, E('p', _('Could not switch the modem to XMM') + ' ' + d.error), 'error');
			return;
		}
		window.setTimeout(function() { window.location.reload(); }, 50000);
	}).catch(function(err) {
		ui.hideModal();
		ctx.clearModemBusy(true);
		if (btn) { btn.disabled = false; }
		ui.addNotification(null, E('p', _('Could not switch the modem to XMM') + ' ' + (err.message || err)), 'error');
	});
}

function applyBandsReadOnly() {
	var ro = bandsReadOnly;
	[ 'bands-lte', 'bands-nr', 'bands-3g', 'bands-2g', 'modesw-btns' ].forEach(function(id) {
		var c = document.getElementById(id);
		if (!c) { return; }
		c.querySelectorAll('button:not(.tg-bandmore)').forEach(function(b) {
			b.disabled = ro;
			b.style.opacity = ro ? '.55' : '';
			b.style.cursor = ro ? 'not-allowed' : '';
		});
	});
	var act = document.getElementById('bandsactn');
	if (act && ro) { act.style.display = 'none'; }
}

var _applyBusy = null;

function _applyKeyNow() {
	return (ctx.pagePath && ctx.pagePath()) || '';
}

function _applyReport(d) {
	var names = { mode: _('Network mode'), lte: 'LTE', nsa: '5G NSA', sa: '5G SA', '3g': '3G', '2g': '2G' };
	var parts = (d.failed || []).map(function(f) {
		var why;
		switch (String(f.why)) {
		case 'badband': why = _('band %s is not supported by the modem').format(String(f.arg || '')); break;
		case 'unsupported': why = _('not supported by this modem'); break;
		case 'mmtimeout': why = _('ModemManager did not pick up the modem in time'); break;
		default: why = _('the modem did not accept it') + (f.arg ? ' (' + String(f.arg) + ')' : '');
		}
		return (names[String(f.what)] || String(f.what)) + ' - ' + why;
	});
	if (!parts.length) { return; }
	ui.addNotification(null, E('p', _('Not applied: %s').format(parts.join('; '))), 'error');
}

function _applyWatch(w) {
	window.setTimeout(function() {
		if (_applyKeyNow() !== w.key) { return; }
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ 'applyresult' ].concat(_bandsFor())), '').then(function(out) {
			var d = null;
			try { d = JSON.parse(String(out || '').trim()); } catch (e) { d = null; }
			if (d && (d.state === 'none' || (d.id && String(d.id) !== w.id))) {
				if (_applyBusy && _applyBusy.key === w.key) { _applyBusy = null; }
				return;
			}
			var st = (d && d.id) ? String(d.state) : '';
			if ((st === 'settling' || st === 'done') && !w.told) { w.told = true; _applyReport(d); }
			if (st === 'done' || --w.left <= 0) {
				if (_applyBusy && _applyBusy.key === w.key) { _applyBusy = null; }
				if (st === 'done' && _applyKeyNow() === w.key) { loadBandsModemband(true); }
				return;
			}
			_applyWatch(w);
		});
	}, 3000);
}

function applyBandsModemband(reset, confirmed) {
	if (_applyBusy && _applyBusy.key === _applyKeyNow() && Date.now() < _applyBusy.until) {
		ui.addNotification(null, E('p', _('The previous band change is still being applied - wait until the modem reconnects.')), 'info');
		return Promise.resolve();
	}
	if (bandsTakeover && !confirmed) {
		ui.showModal(_('Change bands'), [
			E('p', {}, _('To change bands the app briefly hands this modem to ModemManager, applies the change and reconnects. The connection will drop for up to a minute.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button-action important', 'click': function() {
					ui.hideModal();
					ui.addNotification(null, E('p', _('Applying bands — the connection will briefly drop, then reconnect.')), 'info');
					applyBandsModemband(reset, true);
				} }, _('Apply'))
			])
		]);
		return Promise.resolve();
	}
	var lte = [], nsa = [], three = [], two = [];
	if (!reset) {
		document.querySelectorAll('#bands-lte .cbi-button-action').forEach(function(b) { lte.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-nr .cbi-button-action').forEach(function(b) { nsa.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-3g .cbi-button-action[data-btype="3g"]').forEach(function(b) { three.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-2g .cbi-button-action[data-btype="2g"]').forEach(function(b) { two.push(b.getAttribute('data-band')); });
		if (!lte.length && !nsa.length && !three.length && !two.length) {
			ui.addNotification(null, E('p', _('Select at least one band')), 'error');
			return Promise.resolve();
		}
	}
	var hasLte = document.querySelector('#bands-lte .cbi-button') != null;
	var hasNsa = document.querySelector('#bands-nr .cbi-button') != null;
	var hasThree = document.querySelector('#bands-3g [data-btype="3g"]') != null;
	var hasTwo = document.querySelector('#bands-2g [data-btype="2g"]') != null;
	var args = [ 'setall' ];
	if (hasLte && (reset || lte.length)) { args.push('lte=' + (reset ? 'default' : lte.join(' '))); }
	if (hasNsa && (reset || nsa.length)) { args.push('nsa=' + (reset ? 'default' : nsa.join(' '))); }
	if (hasThree && (reset || three.length)) { args.push('3g=' + (reset ? 'default' : three.join(' '))); }
	if (hasTwo && (reset || two.length)) { args.push('2g=' + (reset ? 'default' : two.join(' '))); }
	if (args.length < 2) { return Promise.resolve(); }
	var key = _applyKeyNow();
	return fs.exec('/usr/share/5gmodem/bands.sh', args).then(function(res) {
		var d = null;
		try { d = JSON.parse(String((res && res.stdout) || '').trim()); } catch (e) { d = null; }
		if (!d || !d.id) {
			var why = String((res && (res.stdout || res.stderr)) || '').trim();
			ui.addNotification(null, E('p', [ _('Failed to set bands') + (why ? ': ' + why : '') ]), 'error');
			return;
		}
		if (d.state === 'done') {
			_applyReport(d);
		} else {
			_applyBusy = d.takeover ? { key: key, until: Date.now() + 300000 } : null;
			_applyWatch({ id: String(d.id), key: key, left: d.takeover ? 100 : 40, told: false });
		}
		return loadBandsModemband(true);
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

function revealMgmtWhenReady(tries) {
	return loadBands();
}

function applyBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(false); }
	var sel = [];
	document.querySelectorAll('#bands-3g .cbi-button-action, #bands-lte .cbi-button-action, #bands-nr .cbi-button-action').forEach(function(b) {
		sel.push(b.getAttribute('data-band'));
	});
	if (!sel.length) {
		ui.addNotification(null, E('p', _('Select at least one band')), 'error');
		return Promise.resolve();
	}
	if (!ctx.getMmIdx()) {
		ui.addNotification(null, E('p', _('ModemManager does not manage this modem')), 'error');
		return Promise.resolve();
	}
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'mmsetbands', bandsOther.concat(sel).filter(Boolean).join('|'), String(ctx.getMmIdx()) ]).then(function(res) {
		if (res.code !== 0) {
			ui.addNotification(null, E('p', [ _('Failed to set bands') + ': ' + (res.stderr || res.stdout || '') ]), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Bands applied, refreshing…')), 4000, 'info');
		}
		window.setTimeout(loadBands, 1200);
		window.setTimeout(loadBands, 4000);
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

function resetBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(true); }
	document.querySelectorAll('#bands-3g button[data-band], #bands-lte button[data-band], #bands-nr button[data-band]').forEach(function(b) {
		b.classList.add('cbi-button-action', 'important');
	});
	return applyBands();
}

function setNetMode(allowed, preferred, label, confirmed) {
	if (!ctx.getMmIdx()) {
		ui.addNotification(null, E('p', _('ModemManager does not manage this modem')), 'error');
		return Promise.resolve();
	}
	var _cur = String((window._lastJson || {}).mode || '');
	var _need = /NR|5G/i.test(_cur) ? '5g'
		: /LTE|4G/i.test(_cur) ? '4g'
		: /WCDMA|UMTS|HSPA|3G/i.test(_cur) ? '3g' : '';
	if (!confirmed && _need && String(allowed || '').split('|').indexOf(_need) < 0) {
		ui.showModal(_('Change network mode'), [
			E('p', {}, [ _('The modem is on %s right now, and mode "%s" does not include it. If the network has nothing else here, the connection will drop.').format(_cur, label) ]),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button-action important', 'click': function() {
					ui.hideModal();
					setNetMode(allowed, preferred, label, true);
				} }, _('Apply'))
			])
		]);
		return Promise.resolve();
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	var isAuto = (allowed == '2g|3g|4g|5g' && preferred == '5g');
	var args = isAuto ? [ 'setmodemm', 'default' ]
		: (preferred ? [ 'setmodemm', allowed, preferred ] : [ 'setmodemm', allowed ]);
	return fs.exec('/usr/share/5gmodem/bands.sh', args).then(function(res) {
		ui.hideModal();
		if (res.code === 0 && /"error"/.test(String(res.stdout || ''))) { res.code = 1; }
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
			}
			[ 2000, 8000, 16000, 25000 ].forEach(function(t) { window.setTimeout(loadBands, t); });
		} else {
			ui.addNotification(null, E('p', [ _('Failed to set network mode') + ': ' + (res.stderr || res.stdout || '') ]), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

function setNetModeAT(id, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setmode', String(id) ]).then(function(res) {
		ui.hideModal();
		if (res && typeof res.code === 'number' && res.code !== 0) {
			ui.addNotification(null, E('p', [ _('Failed to set network mode') + ': ' + String(res.stdout || res.stderr || '').trim() ]), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
		} else {
			ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
		}
		window.setTimeout(loadBandsModemband, 4000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

function setBands3gAT(id, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying 3G bands...')));
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands3g', String(id) ]).then(function(res) {
		ui.hideModal();
		if (res && typeof res.code === 'number' && res.code !== 0) {
			ui.addNotification(null, E('p', [ _('Failed to set 3G bands') + ': ' + String(res.stdout || res.stderr || '').trim() ]), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('3G bands set: %s').format(label)), 5000, 'info');
		} else {
			ui.addNotification(null, E('p', _('3G bands set: %s').format(label)), 'info');
		}
		window.setTimeout(loadBandsModemband, 4000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set 3G bands') + ': ' + err.message), 'error');
	});
}

function onModemBusyCleared() {
	if (!_bandsAfterBusy) { return; }
	_bandsAfterBusy = false;
	if (bandSource === 'modemband') { loadBandsModemband(true); } else { loadBands(); }
}

var _bandsPollBusy = false;
function pollTick() {
	if ((_bandsPollN = (_bandsPollN + 1) % 3) !== 0 || _bandsPollBusy) { return; }
	_bandsPollBusy = true;
	Promise.resolve(loadBands()).catch(function() {}).then(function() { _bandsPollBusy = false; });
}

function hwTick(json) {
	bandFilterTick(json);
	var hw = String(json.modem || '') + '|' + String(json.vidpid || '');
	if (hw !== '|' && window.__hwSig && window.__hwSig !== hw) {
		bandsReadOnly = false; bandsTakeover = false;
		bandsStaticNote = false;
		bandSource = 'mmcli';
		_bandsRetry = 0; _bandsRetryMax = 3; _revealTries = 0;
		[ 'bands-3g', 'bands-lte', 'bands-nr', 'bands-2g', 'modesw-btns' ].forEach(function(id) {
			var c = document.getElementById(id);
			if (c) { c.innerHTML = ''; c.removeAttribute('data-sig'); }
		});
		window.setTimeout(loadBands, 300);
	}
	if (hw !== '|') { window.__hwSig = hw; }
}

function ungate() {
	_revealTries = 0;
	window.setTimeout(revealMgmtWhenReady, 500);
}

function setOther(list) { bandsOther = list || []; }

return baseclass.extend({
	API: 30905,
	init: function(c) { ctx = c; },
	loadBands: function() { return loadBands(); },
	loadBandsModemband: function(force) { return loadBandsModemband(force); },
	revealMgmtWhenReady: function() { return revealMgmtWhenReady(); },
	applyBands: function() { return applyBands(); },
	resetBands: function() { return resetBands(); },
	setNetMode: function(a, p, l) { return setNetMode(a, p, l); },
	switchToModemManager: function(b) { return switchToModemManager(b); },
	switchToXmm: function(b) { return switchToXmm(b); },
	buildBandButtons: function(s, c, p) { return buildBandButtons(s, c, p); },
	renderCellLock: function(st) { return renderCellLock(st); },
	cellLockWritable: function() { return _cellLockWritable; },
	lockCell: function(e, p) { return lockCell(e, p); },
	render5gMode: function(st) { return render5gMode(st); },
	renderCaEnabled: function(st) { return renderCaEnabled(st); },
	onModemBusyCleared: onModemBusyCleared,
	pollTick: pollTick,
	hwTick: hwTick,
	ungate: ungate,
	setOther: setOther,
	isTakeover: function() { return bandsTakeover; },
	isReadOnly: function() { return bandsReadOnly; },
	isStaticNote: function() { return bandsStaticNote; },
	resetForModem: function() {
		_bandsWarmed = false; _bandsPollN = 0; _bandsRetry = 0;
		_bandReg = null; _bandAct = null; _bandFilterSig = '';
		_bandsAfterBusy = false; _has3gMM = false;
		bandsReadOnly = false; bandsTakeover = false;
		bandsStaticNote = false;
		bandSource = 'mmcli';
		_revealTries = 0; _bandsRetryMax = 3;
		bandsOther = [];
		[ 'bands-3g', 'bands-lte', 'bands-nr', 'bands-2g', 'modesw-btns' ].forEach(function(id) {
			var c = document.getElementById(id);
			if (c) { c.innerHTML = ''; c.removeAttribute('data-sig'); }
		});
		window.__hwSig = null;
		window.setTimeout(loadBands, 300);
		render5gMode(null); renderCaEnabled(null); renderCellLock(null);
	}
});
