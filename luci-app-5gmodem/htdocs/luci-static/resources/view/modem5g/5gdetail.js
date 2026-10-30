'use strict';
'require baseclass';
'require form';
'require fs';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.netpri as netpri';
'require view.modem5g.extip as extip';
'require view.modem5g.mutil as mutil';
'require view.modem5g.bandsui as bandsui';
'require ui';
'require uci';
'require poll';
'require dom';
'require tools.widgets as widgets';
'require view.modem5g.healthform as healthform';
'require view.modem5g.fresh as fresh';
'require view.modem5g.netarrange as netarrange';
'require view.modem5g.mobileview as mobileview';

/*
	Copyright 2021-2025 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
	
	Thanks to https://github.com/koshev-msk for the initial progress bar calculation for rssi/rsrp/rsrq/sinnr.
*/

var _qualRat = 'lte';
var qualRat = mutil.qualRat;
function qualSetMode(mode) {
	if (mode != null && mode !== '' && mode !== '-') { _qualRat = qualRat(mode); }
	return _qualRat;
}
function qualBandRat(band) {
	return (/^\s*n\d/).test(String(band == null ? '' : band)) ? 'nr' : _qualRat;
}
function sinrUnmeasured(sinr, rsrq) {
	var s = String(sinr == null ? '' : sinr).trim(), q = String(rsrq == null ? '' : rsrq).trim();
	if (!/^-?[0-9]+(\.[0-9]+)?( ?dB)?$/.test(s) || parseFloat(s) !== 0) { return false; }
	if (!/^-?[0-9]+(\.[0-9]+)?( ?dB)?$/.test(q)) { return false; }
	return parseFloat(q) >= -14;
}
var QUAL_NAMES = [ 'red', 'orange', 'yellow', 'green' ];
var _QC = mutil.QUAL_COLOR || [], _QG = mutil.QUAL_GRAD || [];
var CA_COLOR = { red: _QC[0], orange: _QC[1], yellow: _QC[2], green: _QC[3] };
var CA_GRAD = { red: _QG[0], orange: _QG[1], yellow: _QG[2], green: _QG[3] };
function caQuality(key, v, rat, cap) {
	var l = mutil.qualLevel(key, v, rat || _qualRat, cap);
	return l == null ? null : QUAL_NAMES[l];
}
function metricPct(key, v, rat) {
	if (caQuality(key, v, rat) == null) { return null; }
	var pc = mutil.qualPct(key, v, rat || _qualRat);
	if (pc == null) { return null; }
	return pc < 4 ? 4 : pc;
}
var _QUAL_BG = _QG;
function _qualLabel(lvl) {
	return [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][lvl];
}
function metricBarEl(id) {
	if (IS_PROTON) {
		return E('div', { 'id': id, 'class': 'cbi-progressbar', 'title': '-' }, E('div'));
	}
	return E('div', { 'id': id, 'class': 'tg-mbar', 'title': '-' }, [
		E('div', { 'class': 'tg-mbar-t' }, E('div', { 'class': 'tg-mbar-fill' })),
		E('div', { 'class': 'tg-mbar-v' }, '-')
	]);
}
function metricBar(id, rawVal, unit, key, rat) {
	var pg = document.querySelector('#' + id);
	if (!pg || !pg.firstElementChild) { return; }
	var pf = pg.querySelector('.tg-mbar-fill') || pg.firstElementChild;
	var tv = pg.querySelector('.tg-mbar-v');
	if (!tv) { pg.style.width = '100%'; }

	var vn = parseFloat(rawVal);
	if (rawVal == null || rawVal === '' || rawVal === '-' || isNaN(vn)) {
		pf.style.width = '0%';
		pf.style.background = 'rgba(128,128,128,.35)';
		pg.setAttribute('title', '—');
		if (tv) { tv.textContent = '—'; }
		return;
	}

	var r = rat || _qualRat;
	var lvl = mutil.qualLevel(key, vn, r), pc = mutil.qualPct(key, vn, r);
	if (pc == null) { pc = 0; }
	pf.style.width = (pc < 3 ? 3 : pc) + '%';
	pf.style.background = (lvl == null) ? 'rgba(128,128,128,.45)' : _QUAL_BG[lvl];
	var vt = vn + (unit ? (' ' + unit) : '');
	pg.setAttribute('title', (lvl == null) ? vt : (vt + ' | ' + _qualLabel(lvl)));
	if (tv) {
		tv.textContent = '';
		tv.appendChild(document.createTextNode(vt));
		if (lvl != null) {
			tv.appendChild(E('small', { 'style': 'color:' + CA_COLOR[QUAL_NAMES[lvl]] }, _qualLabel(lvl)));
		}
	}
}

function csq_bar(v)  { metricBar('csq',  v, '',    'csq');  }
function rssi_bar(v) { metricBar('rssi', v, 'dBm', 'rssi'); }
function rsrp_bar(v) { metricBar('rsrp', v, 'dBm', 'rsrp'); }
function rsrq_bar(v) { metricBar('rsrq', v, 'dB',  'rsrq'); }
function sinr_bar(v) { metricBar('sinr', v, 'dB',  'sinr'); }
function rscp_bar(v) { metricBar('rscp', v, 'dBm', 'rscp', 'umts'); }
function ecio_bar(v) { metricBar('ecio', v, 'dB',  'ecio', 'umts'); }

var _modemBusyTimer = null;
var _modemBusySince = 0;
var MODEM_BUSY_MIN_MS = 8000;
var _modemBusyBarTimer = null;
function setModemBusy(msg, progressSec) {
	var block = document.getElementById('modem-info-block') || document.querySelector('.cbi-section.tginfo');
	if (!block) { return; }
	var txt = msg || _('The modem is restarting…');
	var txtCls = progressSec ? '' : 'spinning';
	var ov = document.getElementById('modem-busy-ov');
	if (!ov) {
		block.style.position = 'relative';
		ov = E('div', { 'id': 'modem-busy-ov' }, [
			E('span', { 'id': 'modem-busy-txt', 'class': txtCls, 'style': 'font-weight:600;' }, txt)
		]);
		block.appendChild(ov);
	} else {
		ov.style.display = 'flex';
		var s = ov.querySelector('#modem-busy-txt') || ov.querySelector('.spinning');
		if (s) { s.textContent = txt; s.className = txtCls; }
	}
	var bar = document.getElementById('modem-busy-bar');
	if (_modemBusyBarTimer) { window.clearInterval(_modemBusyBarTimer); _modemBusyBarTimer = null; }
	if (progressSec) {
		if (!bar) {
			bar = E('div', { 'id': 'modem-busy-bar', 'class': 'cbi-progressbar',
				'title': '', 'style': 'width:70%;max-width:24em;margin-top:10px' }, E('div'));
			ov.appendChild(bar);
		}
		var t0 = Date.now(), inner = bar.firstElementChild;
		if (inner) {
			inner.style.width = '0%';
			_modemBusyBarTimer = window.setInterval(function() {
				var pc = Math.min(97, Math.round((Date.now() - t0) / (progressSec * 10)));
				inner.style.width = pc + '%';
			}, 500);
		}
	} else if (bar) {
		bar.remove();
	}
	_modemBusySince = Date.now();
	if (_modemBusyTimer) { window.clearTimeout(_modemBusyTimer); }
	_modemBusyTimer = window.setTimeout(function() { clearModemBusy(true); }, 120000);
}
function clearModemBusy(force) {
	if (!force && _modemBusySince && (Date.now() - _modemBusySince) < MODEM_BUSY_MIN_MS) { return; }
	var ov = document.getElementById('modem-busy-ov');
	if (_modemBusyBarTimer) { window.clearInterval(_modemBusyBarTimer); _modemBusyBarTimer = null; }
	if (ov) {
		var inner = ov.querySelector('#modem-busy-bar > div');
		if (inner) {
			inner.style.width = '100%';
			window.setTimeout(function() { ov.style.display = 'none'; }, 350);
		} else {
			ov.style.display = 'none';
		}
	}
	_modemBusySince = 0;
	if (_modemBusyTimer) { window.clearTimeout(_modemBusyTimer); _modemBusyTimer = null; }
	bandsui.onModemBusyCleared();
}
function modemBusyActive() {
	var ov = document.getElementById('modem-busy-ov');
	return !!(ov && ov.style.display !== 'none');
}

var _afpQueue = [];
var _afpDone = false;
function runAfterFirstPoll() {
	if (_afpDone) { return; }
	_afpDone = true;
	_afpQueue.splice(0).forEach(function(fn) { try { fn(); } catch (e) {} });
}
function afterFirstPoll(fn) {
	if (_afpDone) { fn(); return; }
	_afpQueue.push(fn);
	window.setTimeout(runAfterFirstPoll, 1500);
}

var simSlotsSeen = false;
var simSlotsTries = 0;

var slotImsiSeen = null;
var slotIdleTicks = 0;
var SLOT_IDLE_TICKS = 12;
function refreshSlotsIfChanged(json) {
	if (!simSlotsSeen) {
		if (++slotIdleTicks >= 2) { slotIdleTicks = 0; loadSimSlots(); }
		return;
	}
	var imsi = String((json && json.imsi) || '');
	var fresh = (imsi && imsi !== '-');
	var changed = (fresh && slotImsiSeen !== null && imsi !== slotImsiSeen);
	if (fresh) { slotImsiSeen = imsi; }
	if (changed || ++slotIdleTicks >= SLOT_IDLE_TICKS) {
		slotIdleTicks = 0;
		loadSimSlots();
	}
}
function pollSlotUntilSwitched(wantId, delays) {
	if (!delays.length) { return; }
	var ms = delays.shift();
	window.setTimeout(function() {
		loadSimSlots(function(st) {
			if (st && String(st.active) === String(wantId)) { return; }
			pollSlotUntilSwitched(wantId, delays);
		});
	}, ms);
}

function updateSmsEnvelope() {
	if (!document.getElementById('smsenv')) { return; }
	var _args = [ 'newcount' ];
	if (pageModemPath) { _args.push('for=' + pageModemPath); }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', _args), '').then(forPage(function(out) {
		var n = parseInt((out || '').replace(/[^0-9]/g, ''), 10);
		var env = document.getElementById('smsenv');
		if (!env) { return; }
		env.style.display = (n > 0) ? '' : 'none';
	}));
}

var slotsInflight = false;
function loadSimSlots(cb) {
	if (slotsInflight) { if (cb) { cb(null); } return; }
	slotsInflight = true;
	var _slArgs = [ 'status' ];
	if (pageModemPath) { _slArgs.push('for=' + pageModemPath); }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', _slArgs), '').then(forPage(function(out) {
		slotsInflight = false;
		var st = {};
		try { st = JSON.parse(out) || {}; } catch (e) { if (cb) { cb(null); } return; }
		var box = document.getElementById('simslotn');
		if (!box) { if (cb) { cb(null); } return; }
		if (!st.slots || st.slots.length < 2) {
			if (!simSlotsSeen) {
				box.style.display = 'none';
			}
			if (cb) { cb(null); }
			return;
		}
		simSlotsSeen = true;
		if (cb) { cb(st); }
		if (sameRender(box, JSON.stringify(st))) { return; }
		box.innerHTML = '';
		st.slots.forEach(function(s) {
			var on = (String(st.active) === String(s.id));
			var noCard = (s.present !== undefined && String(s.present) === '0');
			var empty = (noCard && !on);
			box.appendChild(E('button', {
				'class': 'btn cbi-button' + (on ? ' tg-current' : '') + (empty ? ' tg-slot-empty' : ''),
				'title': noCard ? _('Slot is empty (no SIM inserted)') : null,
				'click': function(ev) {
					ev.preventDefault();
					if (on) { return; }
					ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching SIM slot...')));
					var _stArgs = [ 'set', String(s.id) ];
					if (pageModemPath) { _stArgs.push('for=' + pageModemPath); }
					fs.exec('/usr/share/5gmodem/simslot.sh', _stArgs).then(function(res) {
						ui.hideModal();
						var ok = res && res.stdout && res.stdout.indexOf('"ok"') >= 0;
						if (ok) { setModemBusy(_('The modem is restarting after the SIM switch…')); }
						if (ui.addTimeLimitedNotification) {
							ui.addTimeLimitedNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), 6000, ok ? 'info' : 'error');
						} else {
							ui.addNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), ok ? 'info' : 'error');
						}
						pollSlotUntilSwitched(s.id, [ 3000, 8000, 15000, 25000, 40000, 60000, 90000 ]);
					}).catch(function() { ui.hideModal(); });
				}
			}, [ s.label ]));
		});
		box.style.display = '';
	}, function() { if (cb) { cb(null); } })).catch(function(e) {
		slotsInflight = false;
		if (cb) { cb(null); }
	});
}

var _extScope = '';
var _ipLast = { v4: '', v6: '' };

function paintIpRow(kind) {
	var v4 = (kind === 'v4');
	var row = document.getElementById(v4 ? 'modemipn' : 'modemip6n');
	var val = document.getElementById(v4 ? 'modemip' : 'modemip6');
	if (!row || !val) { return; }
	var local = _ipLast[kind];
	if (!local) { row.style.display = 'none'; return; }
	var st = extip.state(_extScope);
	var ext = v4 ? st.ip : st.ip6;
	var src = v4 ? st.src : st.src6;
	var srcTxt = src ? (' (' + src + ')') : '';
	var same = !!(ext && ext === local);
	var extEl = function(tip) {
		return E('span', { 'class': 'tginfo-extip', 'data-tooltip': tip },
			extip.withFlag(ext, st.cc));
	};
	var kids;
	if (!ext) {
		kids = [ E('span', { 'class': 'tginfo-locip' }, local) ];
	} else if (same) {
		kids = [ extEl(_('The address is public: the interface has exactly what the internet sees%s').format(srcTxt)) ];
	} else {
		kids = [
			E('span', { 'class': 'tginfo-locip' }, local),
			E('span', { 'class': 'tginfo-extsep' }, '|'),
			extEl(_('External address as seen from the internet%s').format(srcTxt))
		];
	}
	val.classList.toggle('has-ext', !!(ext && !same));
	dom.content(val, kids);
	row.style.display = '';
}

function applyExtIp() { paintIpRow('v4'); paintIpRow('v6'); }

function SIMdata(data) {
	var sdata = {};
	if (data && typeof data === 'object') { sdata = data; }
	else { try { sdata = JSON.parse(data) || {}; } catch (e) {} }

	var rows = [];
	if (sdata.simslot != null && String(sdata.simslot).length > 0 && sdata.simslot != '-')
		rows.push(_('SIM Slot'), sdata.simslot);
	rows.push(_('SIM IMSI'), sdata.imsi || '-');
	rows.push(_('SIM ICCID'), sdata.iccid || '-');
	rows.push(_('Modem IMEI'), sdata.imei || '-');
	return ui.itemlist(E('span'), rows);
}

var _GLOSS = null;
function gl(term) {
	if (!_GLOSS) {
		var QT = mutil.QUAL_T;
		_GLOSS = {
			'RSRP': _('Signal strength received from the cell tower. On LTE and 5G %d dBm or better is excellent, below %d dBm is poor.').format(QT.lte.rsrp[2], QT.lte.rsrp[0]),
			'RSRQ': _('Signal quality. On LTE %d dB or better is excellent, below %d dB is poor; on 5G below %d dB is poor.').format(QT.lte.rsrq[2], QT.lte.rsrq[0], QT.nr.rsrq[0]),
			'SINR': _('Signal-to-noise ratio. On LTE and 5G %d dB or better is excellent, below %d dB is poor.').format(QT.lte.sinr[2], QT.lte.sinr[0]),
			'RSSI': _('Total power received in the channel, including noise and interference. On LTE %d dBm or better is excellent, below %d dBm is poor.').format(QT.lte.rssi[2], QT.lte.rssi[0]),
			'CSQ': _('Signal quality index reported by the modem: 0-31, higher is better.'),
			'TAC': _('Tracking area code: a group of cells of the operator network.'),
			'LAC': _('Location area code in 2G/3G networks.'),
			'Cell ID': _('Identifier of the cell the modem is connected to.'),
			'eNB ID': _('Number of the base station. Used to find it on coverage maps.'),
			'MCC MNC': _('Country code and operator code.'),
			'PCI': _('Physical cell identity on the radio interface.'),
			'EARFCN': _('Number of the LTE radio channel (frequency).'),
			'Path loss': _('How much the signal weakens on its way from the tower.'),
			'TX power': _('Transmit power of the modem right now.'),
			'CQI': _('Channel quality estimated by the modem: 0-15, higher is better.'),
			'RI': _('Transmission rank: how many parallel data streams the network is really sending. 1 means SISO, 2 means MIMO 2x2.'),
			'UE category': _('LTE speed category of the modem.'),
			'Max speed': _('What the modem itself can do. Not the speed of the current connection.'),
			'Operator limit': _('Speed ceiling the operator set for this connection (AMBR) and its QoS class (QCI). A low value explains a slow connection with a good signal.'),
			'VoLTE': _('Voice calls over the LTE network, without falling back to 3G.'),
			'Band': _('LTE frequency band.'),
			'BW': _('Channel bandwidth: wider is faster.'),
			'MIMO': _('Number of parallel data streams.'),
			'Mod': _('Modulation: higher QAM means faster data.'),
			'CC': _('Component carrier: PCC is the main one, SCC are added by carrier aggregation.')
		};
	}
	var t = _GLOSS[term];
	var lbl = _(term);
	return t ? E('span', { 'class': 'tg-gloss', 'title': t }, lbl) : lbl;
}

var CELL_ROWS = [
	{ id: 'mccmnc', text: function(j) {
		var m = mutil.cellVal(j.operator_mcc), n = mutil.cellVal(j.operator_mnc);
		return (m && n) ? (m + ' ' + n) : ''; } },
	{ id: 'lac', text: function(j) { return mutil.decHexPair(j.lac_dec, j.lac_hex); } },
	{ id: 'tac', text: function(j) {
		return mutil.decHexPair(j.tac_d, j.tac_h) || mutil.decHexPair(j.tac_dec, j.tac_hex); } },
	{ id: 'pathloss', text: function(j) { return mutil.cellVal(j.pathloss); } },
	{ id: 'txpower',  text: function(j) { return mutil.cellVal(j.txpower); } },
	{ id: 'cqi',      text: function(j) { return mutil.cellVal(j.cqi); } },
	{ id: 'ri',       text: function(j) { return mutil.cellVal(j.ri); } },
	{ id: 'uecat',    text: function(j) { return mutil.cellVal(j.uecat); } },
	{ id: 'maxrate',  text: function(j) {
		var d = mutil.cellVal(j.maxdl), u = mutil.cellVal(j.maxul);
		return (d && u) ? (d + ' / ' + u + ' ' + _('Mbps')) : ''; } },
	{ id: 'ambr',     text: function(j) {
		var d = mutil.cellVal(j.ambrdl), u = mutil.cellVal(j.ambrul), q = mutil.cellVal(j.qci);
		return (d && u) ? (d + ' / ' + u + ' ' + _('Mbps') + (q ? ' · QCI ' + q : '')) : ''; } },
	{ id: 'volte',    text: function(j) { return mutil.cellVal(j.volte); } },
	{ id: 'pband', always: true, text: function(j) {
		var b = mutil.cellVal(j.pband);
		var p = mutil.cellVal(j.pci), e = mutil.cellVal(j.earfcn);
		if (!b) { return p ? ('- | ' + p + (e ? ' ' + e : '')) : '-'; }
		return (p && e) ? (b + ' | ' + p + ' ' + e) : b; } },
	{ id: 'enbid', render: function(j, el, c4) {
		var val = mutil.cellVal(j.enbid);
		if (!val && c4 && c4.tech === 3) { val = String(c4.num); }
		setRowVisible(el, !!val);
		if (!val) { el.textContent = '-'; return; }
		if (c4 && c4.tech === 3) {
			if (!sameRender(el, 'enb|' + val + '|' + c4.url)) {
				el.innerHTML = '';
				el.appendChild(mapPinButton(c4, val));
			}
		} else if (!sameRender(el, 'plain|' + val)) {
			el.textContent = val;
		} } },
	{ id: 'cid', render: function(j, el, c4) {
		var t = mutil.decHexPair(j.cid_dec, j.cid_hex);
		setRowVisible(el, !!t);
		var url4 = (c4 && c4.tech !== 3 && mutil.cellVal(j.cid_dec)) ? c4.url : null;
		if (url4) {
			if (!sameRender(el, 'cid|' + j.cid_dec + '|' + url4)) {
				el.innerHTML = '';
				el.appendChild(mapPinButton(c4, j.cid_dec));
			}
		} else if (!sameRender(el, 'plain|' + (t || '-'))) {
			el.textContent = t || '-';
		} } }
];
function renderCellRows(json) {
	var c4 = cell4cellsUrl(json);
	CELL_ROWS.forEach(function(r) {
		var el = document.getElementById(r.id);
		if (!el) { return; }
		if (r.render) { r.render(json, el, c4); return; }
		var t = '';
		try { t = r.text(json) || ''; } catch (e) { t = ''; }
		el.textContent = t || '-';
		if (!r.always) { setRowVisible(el, !!t); }
	});
}

function setRowVisible(view, hasData) {
	var tr = view && view.parentNode;
	if (!tr) { return; }
	if (hasData) {
		tr.style.display = '';
		tr.removeAttribute('data-empty');
		tr.setAttribute('data-hadata', '1');
		return;
	}
	if (tr.getAttribute('data-hadata') === '1') { return; }
	var n = (parseInt(tr.getAttribute('data-empty'), 10) || 0) + 1;
	tr.setAttribute('data-empty', String(n));
	if (n >= 3) { tr.style.display = 'none'; }
}

var IS_PROTON = (function() {
	var base = String((window.L && L.env && L.env.mediaurlbase) || '');
	if (/proton2025/.test(base)) { return true; }
	return !!document.querySelector('link[href*="proton2025"]');
})();

function paintMetricCell(td, key, v, text, rat, cap) {
	var has = (v != null && v !== '' && v !== '-');
	var txt = has ? String(text != null ? text : v) : '-';
	var col = has ? caQuality(key, v, rat, cap) : null;
	var pc  = col ? metricPct(key, v, rat) : null;

	if (IS_PROTON) {
		if (pc != null) {
			var pb = td.querySelector('.cbi-progressbar');
			if (!pb) {
				td.textContent = '';
				pb = E('div', { 'class': 'cbi-progressbar' }, [ E('div', { 'style': 'box-shadow:none' }) ]);
				td.appendChild(pb);
			}
			pb.setAttribute('title', txt);
			var pf = pb.firstElementChild;
			pf.style.width = pc + '%';
			pf.style.background = CA_GRAD[col] || CA_COLOR[col];
			return;
		}
		td.textContent = txt;
		return;
	}

	var tn = td.firstChild;
	if (!tn || tn.nodeType !== 3) { td.textContent = ''; tn = document.createTextNode(''); td.appendChild(tn); }
	tn.nodeValue = txt;
	td.style.color = col ? CA_COLOR[col] : '';
	td.style.fontWeight = col ? '600' : '';

	var bar = td.querySelector('.metric-bar');
	if (pc != null) {
		if (!bar) { bar = E('div', { 'class': 'metric-bar' }, [ E('div', {}) ]); td.appendChild(bar); }
		var bf = bar.firstElementChild;
		bf.style.width = pc + '%';
		bf.style.background = CA_GRAD[col] || CA_COLOR[col];
	} else if (bar) {
		bar.parentNode.removeChild(bar);
	}
}

function renderNeighbors(json) {
	var wrap = document.getElementById('nb-comp');
	var tbl = document.getElementById('nb-table');
	if (!wrap || !tbl) { return; }
	var list = (json && Array.isArray(json.neighbors)) ? json.neighbors : [];
	if (!list.length) {
		if (wrap.getAttribute('data-hadata') !== '1') { wrap.style.display = 'none'; }
		return;
	}
	wrap.style.display = '';
	wrap.setAttribute('data-hadata', '1');
	var dash = function(v) { return (v === undefined || v === null || v === '') ? '-' : String(v); };

	var have = tbl.querySelectorAll('.nb-row').length;
	var need = Math.max(list.length, have);
	var k;
	for (k = have; k < need; k++) {
		tbl.appendChild(E('tr', { 'class': 'tr nb-row' }, [
			E('td', { 'class': 'td left' }, []),
			E('td', { 'class': 'td left', 'data-l': 'Band' }, []),
			E('td', { 'class': 'td', 'data-l': 'PCI' }, []),
			E('td', { 'class': 'td', 'data-l': 'EARFCN' }, []),
			E('td', { 'class': 'td', 'data-l': 'RSRP', 'data-m': 'rsrp' }, []),
			E('td', { 'class': 'td', 'data-l': 'RSRQ', 'data-m': 'rsrq' }, []),
			E('td', { 'class': 'td', 'data-l': 'RSSI', 'data-m': 'rssi' }, []),
			E('td', { 'class': 'td nb-lock' }, [])
		]));
	}
	var rows = tbl.querySelectorAll('.nb-row');
	for (k = 0; k < list.length && k < rows.length; k++) {
		var row = rows[k];
		var td = row.querySelectorAll('td');
		var c = list[k];
		var serving = (String(c.serving) === '1' || c.serving === true);
		row.className = 'tr nb-row' + (serving ? ' nb-serving' : '');
		td[0].textContent = serving ? _('serving') : _('neighbour');
		td[1].textContent = c.band ? ('B' + c.band) : '-';
		td[2].textContent = dash(c.pci);
		td[3].textContent = dash(c.earfcn);
		paintMetricCell(td[4], 'rsrp', c.rsrp);
		paintMetricCell(td[5], 'rsrq', c.rsrq);
		paintMetricCell(td[6], 'rssi', c.rssi, null, undefined, c.rsrq);
		if (td[7]) { nbLockCell(td[7], c, serving); }
	}
}

function nbLockCell(td, c, serving) {
	var ear = c.earfcn, pci = c.pci;
	var can = bandsui.cellLockWritable && bandsui.cellLockWritable()
		&& !serving && ear && ear !== '-' && pci != null && pci !== '' && pci !== '-';
	if (!can) {
		if (td.getAttribute('data-lk')) { td.removeAttribute('data-lk'); dom.content(td, ''); }
		return;
	}
	var key = ear + ':' + pci;
	if (td.getAttribute('data-lk') === key) { return; }
	td.setAttribute('data-lk', key);
	var btn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'style': 'padding:1px 9px;display:inline-flex;align-items:center;justify-content:center',
		'title': _('Lock to this cell (EARFCN %s, PCI %s)').format(ear, pci),
		'click': function(ev) { ev.preventDefault(); bandsui.lockCell(ear, pci); }
	});
	btn.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:block"><rect x="5" y="11" width="14" height="10" rx="1"></rect><path d="M8 11V7a4 4 0 0 1 8 0v4M12 15v2"></path></svg>';
	dom.content(td, btn);
}

function caSummary(json) {
	var n = 0, bw = 0;
	var mhz = function(v) { var m = String(v || '').match(/(\d+(?:\.\d+)?)\s*MHz/i); return m ? parseFloat(m[1]) : 0; };
	var p = String(json.pband || '').trim();
	if (p && p !== '-') { n++; bw += mhz(mutil.caSplitBand(p).bw) || mhz(json.bandwidth); }
	for (var i = 1; i <= 4; i++) {
		var b = String(json['s' + i + 'band'] || '').trim();
		if (!b || b === '-' || /deactiv|inactiv/i.test(String(json['s' + i + 'state'] || ''))) { continue; }
		n++;
		bw += mhz(mutil.caSplitBand(b).bw);
	}
	return { n: n, bw: Math.round(bw) };
}

function caTip(ca) {
	return ca.bw ? _('Carrier aggregation: %d carriers combined, %d MHz in total').format(ca.n, ca.bw)
		: _('Carrier aggregation: %d carriers combined').format(ca.n);
}

function renderCaTable(json) {
	var tbl = document.getElementById('ca-table');
	var sec = document.getElementById('ca-comp');
	if (!tbl) { return; }
	var data = {};
	var hasPcc = json.pband && json.pband != '-';
	var caSum = document.getElementById('ca-sum');
	if (caSum) {
		var ca = caSummary(json);
		var caTxt = ca.n > 1 ? ca.n + 'CA' + (ca.bw ? ' · ' + ca.bw + ' MHz' : '') : '';
		if (caSum.textContent !== caTxt) { caSum.textContent = caTxt; caSum.title = ca.n > 1 ? caTip(ca) : ''; }
		caSum.style.display = caTxt ? '' : 'none';
	}
	if (hasPcc) {
		var p = mutil.caSplitBand(json.pband);
		data['PCC'] = { band: p.band, bw: p.bw || json.bandwidth, pci: json.pci, earfcn: json.earfcn,
			rsrp: json.rsrp, rsrq: json.rsrq, rssi: json.rssi,
			sinr: sinrUnmeasured(json.sinr, json.rsrq) ? '-' : json.sinr,
			mimo: json.pmimo, mod: json.pmod,
			state: _('activated') };
	}
	[ '1', '2', '3', '4' ].forEach(function(i) {
		var b = json['s' + i + 'band'];
		if (b && b != '-') {
			var sb = mutil.caSplitBand(b);
			var st = String(json['s' + i + 'state'] || '');
			data['SCC' + i] = { band: sb.band, bw: sb.bw,
				pci: json['s' + i + 'pci'], earfcn: json['s' + i + 'earfcn'],
				rsrp: json['s' + i + 'rsrp'], rsrq: json['s' + i + 'rsrq'],
				rssi: json['s' + i + 'rssi'], sinr: json['s' + i + 'sinr'],
				mimo: json['s' + i + 'mimo'], mod: json['s' + i + 'mod'],
				state: (st === 'activated') ? _('activated')
					: (st === 'deactivated') ? _('deactivated') : '' };
		}
	});
	if (sec) {
		if (hasPcc) {
			sec.style.display = '';
			sec.removeAttribute('data-empty');
			sec.setAttribute('data-hadata', '1');
		} else if (sec.getAttribute('data-hadata') !== '1') {
			var n = (parseInt(sec.getAttribute('data-empty'), 10) || 0) + 1;
			sec.setAttribute('data-empty', String(n));
			if (n >= 3) { sec.style.display = 'none'; }
		}
	}
	var txt = function(v) { return (v != null && v !== '' && v !== '-') ? String(v) : '-'; };
	var isMetric = { rsrp: 1, rsrq: 1, rssi: 1, sinr: 1 };
	function paintCell(td, key, c) {
		if (isMetric[key]) { paintMetricCell(td, key, c[key], null, qualBandRat(c.band), c.rsrq); return; }
		td.textContent = txt(c[key]);
		td.style.color = '';
		td.style.fontWeight = '';
	}
	var cols = [ 'band', 'bw', 'pci', 'earfcn', 'rsrp', 'rsrq', 'rssi', 'sinr', 'mimo', 'mod', 'state' ];
	tbl.querySelectorAll('tr.ca-row').forEach(function(row) {
		var cc = row.getAttribute('data-cc');
		var c = data[cc] || {};
		var tds = row.querySelectorAll('td');
		cols.forEach(function(k, j) { if (tds[j + 1]) { paintCell(tds[j + 1], k, c); } });

		if (cc === 'PCC') { return; }
		var has = !!data[cc];
		if (has) {
			row.style.display = '';
			row.setAttribute('data-hadata', '1');
		} else if (row.getAttribute('data-hadata') !== '1') {
			row.style.display = 'none';
		}
	});
}

function detectBoxedHeading() {
	if (document.documentElement.hasAttribute('data-tg-h3')) { return; }
	document.documentElement.setAttribute('data-tg-h3', '1');
	var probe = E('div', { 'class': 'cbi-section tginfo',
		'style': 'position:absolute;left:-9999px;top:0;visibility:hidden' }, [ E('h3', {}, 'x') ]);
	document.body.appendChild(probe);
	var pad = parseFloat(getComputedStyle(probe.firstChild).paddingLeft) || 0;
	document.body.removeChild(probe);
	if (pad >= 8) { document.documentElement.classList.add('tg-boxed-h3'); }
}
if (document.body) { detectBoxedHeading(); }
else { document.addEventListener('DOMContentLoaded', detectBoxedHeading); }

function sameRender(el, sig) {
	if (!el) { return false; }
	if (el.getAttribute('data-sig') === sig) { return true; }
	el.setAttribute('data-sig', sig);
	return false;
}

var mmIdx = '';
var ifaceProtoIsMM = false;
var ledsAvail = false;
var pageModemPath = '';
var pollTickFn = null;

function resetStickyForModem() {
	_qualRat = 'lte';
	var drop = function(el) {
		if (!el) { return; }
		[ 'data-hadata', 'data-empty', 'data-sig' ].forEach(function(a) { el.removeAttribute(a); });
	};
	CELL_ROWS.forEach(function(r) {
		var el = document.getElementById(r.id);
		if (!el) { return; }
		drop(el); drop(el.parentNode);
		el.textContent = '-';
	});
	var t = document.getElementById('temp');
	if (t) {
		drop(t); drop(t.parentNode);
		t.textContent = '-';
		t.removeAttribute('title');
		if (t.parentNode) { t.parentNode.style.display = 'none'; }
	}
	var pv = document.getElementById('phone');
	if (pv) {
		pv.removeAttribute('data-hadata');
		pv.removeAttribute('data-imsi');
		pv.textContent = '';
		pv.style.display = 'none';
	}
	var mv = document.getElementById('mode');
	if (mv) { mv.textContent = '-'; mv.removeAttribute('data-mh'); }
	var _mibR = document.getElementById('modem-info-block');
	if (_mibR) { _mibR.removeAttribute('data-rat'); }
	var nbw = document.getElementById('nb-comp');
	if (nbw) {
		drop(nbw);
		nbw.style.display = 'none';
		nbw.querySelectorAll('.nb-row').forEach(function(r) { r.parentNode.removeChild(r); });
	}
	var apb = document.getElementById('antports-block');
	var apt = document.getElementById('antports-table');
	if (apb) { drop(apb); apb.style.display = 'none'; }
	if (apt) { drop(apt); apt.innerHTML = ''; }
	var rxl = document.getElementById('rxdiv-line');
	if (rxl) { drop(rxl); rxl.textContent = ''; rxl.style.display = 'none'; }
	var cas = document.getElementById('ca-comp');
	if (cas) {
		drop(cas);
		cas.style.display = 'none';
		cas.querySelectorAll('tr.ca-row').forEach(function(r) {
			drop(r);
			if (r.getAttribute('data-cc') !== 'PCC') { r.style.display = 'none'; }
		});
	}
	_c4Last = null;
	_connBase = null;
	_advSticky = false;
	_lastJson = null;
}

function switchModemInPlace(path) {
	if (!path || path === pageModemPath) { return; }
	pageModemPath = String(path);
	_histSeedAt = 0;
	try { window.sessionStorage.setItem('5gm-tab', pageModemPath); } catch (e) {}
	ifaceProtoIsMM = false;
	mmIdx = '';
	_inPlaceAt = Date.now();
	foreignTicks = 0;
	simSlotsSeen = false;
	slotImsiSeen = null;
	slotIdleTicks = 1;
	slotsInflight = false;
	var _ssb = document.getElementById('simslotn');
	if (_ssb) { _ssb.style.display = 'none'; _ssb.innerHTML = ''; _ssb.removeAttribute('data-sig'); }
	resetStickyForModem();
	histDraw(null);
	if (typeof bandsui.resetForModem === 'function') { bandsui.resetForModem(); }
	if (typeof mobileview.reset === 'function') { try { mobileview.reset(); } catch (e) {} }
	loadMmIdx();
	if (modemtabs.refreshEsimTab) { modemtabs.refreshEsimTab(); }
	if (modemtabs.refreshUssdTab) { modemtabs.refreshUssdTab(); }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'peek', pageModemPath ]), '{}')
		.then(function(out) {
			var j = null; try { j = JSON.parse(out); } catch (e) {}
			if (j && (j.modem || j.signal)) { applyMetrics(j); }
			else { setModemBusy(_('Switching to the modem…')); }
		});
	if (typeof pollTickFn === 'function') {
		pollTickFn();
		window.setTimeout(function() { if (pollTickFn) { pollTickFn(); } }, 900);
		window.setTimeout(function() { if (pollTickFn) { pollTickFn(); } }, 2200);
	}
}
var foreignTicks = 0;
var _inPlaceAt = 0;
var _mmIdxAt = 0;

function forPage(fn, onStale) {
	var p = pageModemPath;
	return function(v) {
		if (p !== pageModemPath) { return onStale ? onStale(v) : undefined; }
		return fn(v);
	};
}

function loadMmIdx() {
	var args = [ 'mmindex' ];
	if (pageModemPath) { args.push(pageModemPath); }
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', args), '')
		.then(forPage(function(idx) { mmIdx = String(idx || '').trim(); }));
}

var onBlockExpand = {};
function blockExpanded(key) {
	try { return localStorage.getItem('5gm-blk-' + key) !== '0'; } catch (e) { return true; }
}
function collapsibleSection(key, titleText, content, extraAttrs) {
	var expanded = blockExpanded(key);
	var chev = E('span', { 'style': 'display:inline-flex;transition:transform .15s ease;transform:rotate(' + (expanded ? '180' : '0') + 'deg)' });
	chev.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg>';
	var inner = E('div', { 'class': 'tg-collapse-inner' }, content);
	var body = E('div', { 'class': 'tg-collapse' + (expanded ? ' open' : '') }, [ inner ]);
	var title = E('h3', {
		'style': 'display:flex;align-items:center;gap:.35em;cursor:pointer;user-select:none;margin-bottom:' + (expanded ? '.5em' : '0'),
		'click': function() {
			var exp = !body.classList.contains('open');
			body.classList.toggle('open', exp);
			title.style.marginBottom = exp ? '.5em' : '0';
			chev.style.transform = 'rotate(' + (exp ? '180' : '0') + 'deg)';
			try { localStorage.setItem('5gm-blk-' + key, exp ? '1' : '0'); } catch (e) {}
			if (exp && typeof onBlockExpand[key] === 'function') { onBlockExpand[key](); }
		}
	}, [ chev, E('span', {}, titleText) ]);
	var attrs = { 'class': 'cbi-section tginfo', 'data-blk': key };
	if (extraAttrs) { for (var k in extraAttrs) { attrs[k] = extraAttrs[k]; } }
	return E('div', attrs, [ title, body ]);
}
onBlockExpand['freq'] = function() {
	if (typeof bandsui.loadBands === 'function') { bandsui.loadBands(); }
};

var HIST_SPAN = 600, HIST_MIN_SPAN = 120, HIST_CAP = 240, HIST_GAP = 20, HIST_W = 300, HIST_H = 64;
var HIST_KEYS = [ [ 'rsrp', 'RSRP', 'dBm' ], [ 'rsrq', 'RSRQ', 'dB' ], [ 'sinr', 'SINR', 'dB' ], [ 'rssi', 'RSSI', 'dBm' ] ];
var _histOn = true, _hist = null, _histUi = null;
function histNum(v) {
	var n = parseFloat(v);
	return (v == null || v === '' || v === '-' || isNaN(n)) ? null : n;
}
function histId(v) {
	var s = String(v == null ? '' : v).trim();
	return (s === '' || s === '-') ? '' : s;
}
function histStore() {
	if (_hist) { return _hist; }
	_hist = {};
	try {
		var o = JSON.parse(window.sessionStorage.getItem('5gm-hist') || '{}') || {};
		var now = Date.now() / 1000;
		Object.keys(o).forEach(function(k) {
			var h = o[k];
			if (!h || !Array.isArray(h.p)) { return; }
			_hist[k] = { c: String(h.c || ''), p: h.p.filter(function(p) {
				return Array.isArray(p) && typeof p[0] === 'number' && p[0] > now - HIST_SPAN && p[0] < now + 5;
			}).slice(-HIST_CAP) };
		});
	} catch (e) { _hist = {}; }
	return _hist;
}
function histKey(json) {
	return String(pageModemPath || (json && json.path) || '-');
}
function histPush(json) {
	if (!_histOn || !json) { return; }
	if (json.rsrp == null && json.rsrq == null && json.sinr == null && json.rssi == null) { return; }
	if (parseInt(json.age, 10) >= 30) { return; }
	var st = histStore(), key = histKey(json);
	var h = st[key] || (st[key] = { c: '', p: [] });
	var now = Math.round(Date.now() / 100) / 10;
	if (h.p.length && now - h.p[h.p.length - 1][0] < 3) { return; }
	var pt = [ now, histNum(json.rsrp), histNum(json.rsrq),
		sinrUnmeasured(json.sinr, json.rsrq) ? null : histNum(json.sinr), histNum(json.rssi), '' ];
	var pci = histId(json.pci), ear = histId(json.earfcn);
	if (pci && ear) {
		var ck = pci + '/' + ear;
		if (h.c && h.c !== ck) {
			var band = histId(mutil.caSplitBand(json.pband).band).replace(/\s*\(.*$/, '');
			pt[5] = (band || ('EARFCN ' + ear)) + ' · PCI ' + pci;
		}
		h.c = ck;
	}
	h.p.push(pt);
	while (h.p.length > HIST_CAP || (h.p.length && h.p[0][0] < now - HIST_SPAN)) { h.p.shift(); }
	try { window.sessionStorage.setItem('5gm-hist', JSON.stringify(st)); } catch (e) {}
}
var _histSeedAt = 0;
function histSeed() {
	if (!_histOn) { return Promise.resolve(); }
	_histSeedAt = Date.now();
	var key = String(pageModemPath || '-');
	var args = [ 'hist' ];
	if (pageModemPath) { args.push(pageModemPath); }
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', args), '[]').then(function(out) {
		var arr = [];
		try { arr = JSON.parse(out || '[]') || []; } catch (e) {}
		if (!Array.isArray(arr) || !arr.length || key !== String(pageModemPath || '-')) { return; }
		var st = histStore(), h = st[key] || (st[key] = { c: '', p: [] });
		var now = Date.now() / 1000, ck = '', pts = [];
		arr.forEach(function(r) {
			if (!Array.isArray(r) || typeof r[0] !== 'number') { return; }
			var pt = [ Math.round((now - r[0]) * 10) / 10, histNum(r[1]), histNum(r[2]),
				sinrUnmeasured(r[3], r[2]) ? null : histNum(r[3]), histNum(r[4]), '' ];
			var pci = histId(r[5]), ear = histId(r[6]);
			if (pci && ear) {
				var k2 = pci + '/' + ear;
				if (ck && ck !== k2) {
					var band = histId(mutil.caSplitBand(r[7]).band).replace(/\s*\(.*$/, '');
					pt[5] = (band || ('EARFCN ' + ear)) + ' · PCI ' + pci;
				}
				ck = k2;
			}
			pts.push(pt);
		});
		var merged = pts.concat(h.p).sort(function(a, b) { return a[0] - b[0]; }), res = [];
		merged.forEach(function(p) {
			var l = res[res.length - 1];
			if (l && p[0] - l[0] < 3) { if (!l[5] && p[5]) { l[5] = p[5]; } return; }
			res.push(p);
		});
		h.p = res.filter(function(p) { return p[0] > now - HIST_SPAN; }).slice(-HIST_CAP);
		if (!h.c && ck) { h.c = ck; }
		try { window.sessionStorage.setItem('5gm-hist', JSON.stringify(st)); } catch (e) {}
		histDraw(window._lastJson || null);
	});
}
function histSvg(tag, attrs) {
	var el = document.createElementNS('http://www.w3.org/2000/svg', tag);
	for (var k in attrs) { el.setAttribute(k, attrs[k]); }
	return el;
}
function histClock(sec) {
	sec = Math.max(0, Math.round(sec));
	var s = sec % 60;
	return _('%s ago').format(Math.floor(sec / 60) + ':' + (s < 10 ? '0' : '') + s);
}
function histFmt(v) {
	return String(Math.round(v * 10) / 10);
}
function histBuild() {
	var ui = { cards: {}, t0: 0, span: HIST_SPAN, pts: [], hover: null };
	var nodes = HIST_KEYS.map(function(m) {
		var c = { key: m[0], idx: HIST_KEYS.indexOf(m) + 1, unit: m[2] };
		c.avg = histSvg('line', { 'class': 'tg-hist-avg', x1: 0, x2: HIST_W, y1: 0, y2: 0, 'vector-effect': 'non-scaling-stroke', visibility: 'hidden' });
		c.area = histSvg('path', { 'class': 'tg-hist-area', d: '' });
		c.line = histSvg('path', { 'class': 'tg-hist-line', d: '', 'vector-effect': 'non-scaling-stroke' });
		c.marks = histSvg('path', { 'class': 'tg-hist-mark', d: '', 'vector-effect': 'non-scaling-stroke' });
		c.cur = histSvg('line', { 'class': 'tg-hist-cur', x1: 0, x2: 0, y1: 0, y2: HIST_H, 'vector-effect': 'non-scaling-stroke', visibility: 'hidden' });
		c.svg = histSvg('svg', { viewBox: '0 0 ' + HIST_W + ' ' + HIST_H, preserveAspectRatio: 'none', role: 'img', 'aria-label': m[1] });
		[ c.avg, c.area, c.line, c.marks, c.cur ].forEach(function(n) { c.svg.appendChild(n); });
		c.dot = E('span', { 'class': 'tg-hist-dot', 'style': 'display:none' });
		c.hdot = E('span', { 'class': 'tg-hist-dot tg-hist-hdot', 'style': 'display:none' });
		c.tip = E('span', { 'class': 'tg-hist-tip', 'style': 'display:none' });
		c.empty = E('span', { 'class': 'tg-hist-empty' }, _('No data yet'));
		c.plot = E('div', { 'class': 'tg-hist-plot' }, [ c.svg, c.dot, c.hdot, c.tip, c.empty ]);
		c.lvDot = E('i', {});
		c.lvTxt = E('span', {}, '');
		c.now = E('span', { 'class': 'tg-hist-now' }, '-');
		c.left = E('span', {}, histClock(HIST_SPAN));
		c.stat = E('div', { 'class': 'tg-hist-s' }, '');
		c.root = E('div', { 'class': 'tg-hist-card', 'data-k': m[0] }, [
			E('div', { 'class': 'tg-hist-h' }, [
				E('span', { 'class': 'tg-hist-name' }, [ E('b', {}, m[1]), E('span', { 'class': 'tg-hist-lv' }, [ c.lvDot, c.lvTxt ]) ]),
				c.now
			]),
			c.stat,
			c.plot,
			E('div', { 'class': 'tg-hist-f' }, [ c.left, E('span', {}, _('now')) ])
		]);
		var move = function(ev) {
			var r = c.svg.getBoundingClientRect();
			if (!r.width) { return; }
			ui.hover = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
			histHover();
		};
		var leave = function() { ui.hover = null; histHover(); };
		c.plot.addEventListener('pointermove', move);
		c.plot.addEventListener('pointerdown', move);
		c.plot.addEventListener('pointerleave', leave);
		c.plot.addEventListener('pointercancel', leave);
		ui.cards[m[0]] = c;
		return c.root;
	});
	_histUi = ui;
	return E('div', {}, [
		E('div', { 'class': 'tg-hist-grid' }, nodes),
		E('div', { 'class': 'tg-hist-note' }, _('Each metric has its own scale. The dashed line is the average; a thin vertical line marks a cell or band change. Point at a chart to read the value.'))
	]);
}
function histHover() {
	var ui = _histUi;
	if (!ui) { return; }
	Object.keys(ui.cards).forEach(function(k) {
		var c = ui.cards[k], best = null, bd = HIST_GAP;
		if (ui.hover != null) {
			var t = ui.t0 + ui.hover * ui.span;
			ui.pts.forEach(function(p) {
				var d = Math.abs(p[0] - t);
				if (p[c.idx] != null && d <= bd) { bd = d; best = p; }
			});
		}
		if (!best) {
			c.cur.setAttribute('visibility', 'hidden');
			c.tip.style.display = 'none';
			c.hdot.style.display = 'none';
			return;
		}
		var f = (best[0] - ui.t0) / ui.span, x = f * HIST_W;
		c.cur.setAttribute('x1', x); c.cur.setAttribute('x2', x);
		c.cur.setAttribute('visibility', 'visible');
		c.hdot.style.display = '';
		c.hdot.style.left = (f * 100).toFixed(2) + '%';
		c.hdot.style.top = c.y(best[c.idx]).toFixed(1) + 'px';
		var mark = '';
		ui.pts.forEach(function(p) { if (p[5] && Math.abs(p[0] - best[0]) <= HIST_GAP / 2) { mark = p[5]; } });
		c.tip.textContent = histFmt(best[c.idx]) + ' ' + c.unit + ' · ' + histClock(ui.t0 + ui.span - best[0]) + (mark ? ' · ' + mark : '');
		c.tip.style.display = '';
		var w = c.plot.clientWidth || 1, half = c.tip.offsetWidth / 2 + 2;
		c.tip.style.left = Math.max(half, Math.min(w - half, f * w)) + 'px';
	});
}
function histDraw(json) {
	var ui = _histUi;
	if (!ui || !_histOn) { return; }
	var body = document.querySelector('[data-blk="hist"] .tg-collapse');
	if (!body || !body.classList.contains('open')) { return; }
	var h = histStore()[histKey(json)] || { p: [] };
	var now = Date.now() / 1000;
	var pts = h.p.filter(function(p) { return p[0] >= now - HIST_SPAN; });
	var span = pts.length ? Math.max(HIST_MIN_SPAN, Math.min(HIST_SPAN, now - pts[0][0])) : HIST_SPAN;
	var t0 = now - span;
	ui.t0 = t0; ui.span = span; ui.pts = pts;
	var X = function(t) { return (t - t0) / span * HIST_W; };
	var marks = '';
	pts.forEach(function(p) { if (p[5]) { var mx = X(p[0]).toFixed(1); marks += 'M' + mx + ' 0V' + HIST_H; } });
	Object.keys(ui.cards).forEach(function(k) {
		var c = ui.cards[k], i = c.idx, vals = [];
		pts.forEach(function(p) { if (p[i] != null) { vals.push(p[i]); } });
		if (k === 'rssi') { c.root.style.display = vals.length ? '' : 'none'; }
		c.left.textContent = histClock(span);
		c.marks.setAttribute('d', marks);
		if (!vals.length) {
			c.line.setAttribute('d', ''); c.area.setAttribute('d', '');
			c.avg.setAttribute('visibility', 'hidden');
			c.dot.style.display = 'none'; c.empty.style.display = '';
			c.now.textContent = '-'; c.stat.innerHTML = ''; c.stat.appendChild(E('span', {}, '\u00a0')); c.lvTxt.textContent = ''; c.lvDot.style.background = 'transparent';
			return;
		}
		c.empty.style.display = 'none';
		var lo = Math.min.apply(null, vals), hi = Math.max.apply(null, vals), sum = 0;
		vals.forEach(function(v) { sum += v; });
		var avg = sum / vals.length;
		var a = lo, b = hi;
		if (b - a < 6) { var mid = (a + b) / 2; a = mid - 3; b = mid + 3; }
		var pad = (b - a) * 0.15;
		a -= pad; b += pad;
		var Y = function(v) { return HIST_H - 4 - (v - a) / (b - a) * (HIST_H - 8); };
		c.y = Y;
		var line = '', area = '', seg = [], prevT = null;
		var flush = function() {
			if (!seg.length) { return; }
			var d = '';
			seg.forEach(function(q, n) { d += (n ? 'L' : 'M') + q[0].toFixed(1) + ' ' + q[1].toFixed(1); });
			if (seg.length === 1) { d += 'h0.01'; }
			line += d;
			if (seg.length > 1) { area += d + 'L' + seg[seg.length - 1][0].toFixed(1) + ' ' + HIST_H + 'L' + seg[0][0].toFixed(1) + ' ' + HIST_H + 'Z'; }
			seg = [];
		};
		pts.forEach(function(p) {
			if (p[i] == null || (prevT != null && p[0] - prevT > HIST_GAP)) { flush(); }
			if (p[i] != null) { seg.push([ X(p[0]), Y(p[i]) ]); }
			prevT = p[0];
		});
		flush();
		c.line.setAttribute('d', line);
		c.area.setAttribute('d', area);
		c.avg.setAttribute('y1', Y(avg).toFixed(1)); c.avg.setAttribute('y2', Y(avg).toFixed(1));
		c.avg.setAttribute('visibility', 'visible');
		var last = pts[pts.length - 1], cur = last[i];
		if (cur != null && now - last[0] <= HIST_GAP) {
			c.dot.style.display = '';
			c.dot.style.left = (X(last[0]) / HIST_W * 100).toFixed(2) + '%';
			c.dot.style.top = Y(cur).toFixed(1) + 'px';
			c.now.textContent = '';
			c.now.appendChild(document.createTextNode(histFmt(cur) + ' '));
			c.now.appendChild(E('small', {}, c.unit));
			var q = caQuality(k, cur);
			c.lvDot.style.background = q ? CA_COLOR[q] : 'transparent';
			c.lvTxt.textContent = q ? _qualLabel(QUAL_NAMES.indexOf(q)) : '';
		} else {
			c.dot.style.display = 'none';
			c.now.textContent = '-'; c.lvTxt.textContent = ''; c.lvDot.style.background = 'transparent';
		}
		c.stat.innerHTML = '';
		[ [ 'min', lo ], [ 'avg', avg ], [ 'max', hi ] ].forEach(function(p) {
			c.stat.appendChild(E('span', {}, _(p[0]) + ' ' + histFmt(p[1])));
		});
	});
	histHover();
}
function histShow(on) {
	var el = document.querySelector('[data-blk="hist"]');
	if (el) { el.style.display = on ? '' : 'none'; }
}
onBlockExpand['hist'] = function() { histDraw(_lastJson); };

function renderDebugBtn(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var btn = document.getElementById('dbgmode-btn');
	if (json.backend !== 'hilink' || !hilinkHasDebug(json) || HL_DEBUG_ON[String(json.vidpid || '')]) { if (btn) { btn.remove(); } return; }
	if (btn) { return; }
	head.appendChild(E('button', {
		'id': 'dbgmode-btn',
		'class': 'btn cbi-button',
		'style': 'float:right; font-size:70%; padding:.15em .6em; margin-left:.8em;',
		'title': _('Switch the modem into the mode with AT ports: TAC, bands, EARFCN, USSD and the AT console become available. The mode resets when the modem reboots.'),
		'click': ui.createHandlerFn(this, function() {
			setModemBusy(_('Switching the modem into the mode with AT ports…'));
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autosetup',
				(pageModemPath || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '') ]), {});
			reloadWhenDebugReady();
		})
	}, _('debug')));
}

var HL_DEBUG_ON = { '19d2:0581': 1, '19d2:0536': 1 };
var HL_DEBUG_CAN = { '19d2:1557': 1, '19d2:0581': 1, '19d2:0558': 1, '19d2:0536': 1 };

function hilinkHasDebug(json) {
	var vp = String(json.vidpid || '');
	return !vp || vp.indexOf('12d1:') === 0 || !!HL_DEBUG_CAN[vp];
}

function renderWebPassHint(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var el = document.getElementById('webpass-hint');
	if (json.backend !== 'hilink' || json.web_auth !== 'fail') { if (el) { el.remove(); } return; }
	if (el) { return; }
	head.appendChild(E('a', {
		'id': 'webpass-hint',
		'class': 'webpass-hint',
		'href': L.url('admin/modem/5gmodem/diagnostics'),
		'title': _('The modem asks for its web password - enter it on the Modem page')
	}, _('Password needed')));
}

var TEMP_SENSORS = [
	[ 'pa', _('Radio amplifier'), '<path d="M12 11v10M8.5 21h7"/><circle cx="12" cy="9" r="1.6"/><path d="M8.6 5.6a4.8 4.8 0 0 0 0 6.8M15.4 5.6a4.8 4.8 0 0 1 0 6.8M5.8 2.8a8.8 8.8 0 0 0 0 12.4M18.2 2.8a8.8 8.8 0 0 1 0 12.4"/>' ],
	[ 'cpu', _('Processor'), '<rect x="6" y="6" width="12" height="12" rx="1.5"/><rect x="9.5" y="9.5" width="5" height="5" rx=".6"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>' ],
	[ 'wifi', _('Wi-Fi'), '<path d="M2.5 9a14 14 0 0 1 19 0M5.8 12.4a9.2 9.2 0 0 1 12.4 0M9.1 15.8a4.4 4.4 0 0 1 5.8 0"/><circle cx="12" cy="19" r="1.2"/>' ],
	[ 'pmic', _('Power controller'), '<path d="M13 2 5 13.5h6L10 22l8-11.5h-6z"/>' ],
	[ 'bat', _('Battery'), '<rect x="7" y="4" width="10" height="17" rx="2"/><path d="M10 2h4M10 9h4M10 13h4M10 17h4"/>' ],
	[ 'charger', _('Charger'), '<path d="M9 2v5M15 2v5M6.5 7h11v4a5.5 5.5 0 0 1-11 0zM12 16.5V22"/>' ],
	[ 'board', _('Board'), '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 8h4v4M17 8v4h-4M7 16h10"/><circle cx="7" cy="8" r=".8"/><circle cx="17" cy="8" r=".8"/><circle cx="7" cy="16" r=".8"/>' ]
];

function renderTemps(json) {
	var box = document.getElementById('tempsn');
	if (!box) { return; }
	var raw = String(json.temps || '').trim();
	if (!raw || raw === '-') { box.style.display = 'none'; return; }
	box.style.display = '';
	if (box.getAttribute('data-k') === raw) { return; }
	box.setAttribute('data-k', raw);
	var v = {};
	raw.split(/\s+/).forEach(function(p) { var kv = p.split('='); if (kv.length === 2) { v[kv[0]] = kv[1]; } });
	box.innerHTML = '';
	TEMP_SENSORS.forEach(function(s) {
		if (v[s[0]] == null) { return; }
		var t = parseFloat(v[s[0]]);
		var chip = E('span', { 'class': 'tg-tchip', 'title': s[1] + ': ' + v[s[0]] + ' °C' });
		chip.innerHTML = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">' + s[2] + '</svg>';
		chip.appendChild(E('span', { 'class': 'tg-tval' }, Math.round(t) + '°'));
		box.appendChild(chip);
	});
}

function renderNa(json) {
	var na = ' ' + String(json.na || '') + ' ';
	var off = function(k) { return na.indexOf(' ' + k + ' ') >= 0; };
	[ [ 'csq', 'csqn' ], [ 'rssi', 'rssin' ], [ 'sinr', 'sinrn' ], [ 'rsrq', 'rsrqn' ] ].forEach(function(r) {
		var el = document.getElementById(r[1]);
		if (el) { el.style.display = off(r[0]) ? 'none' : ''; }
	});
	var pb = document.getElementById('pband');
	if (pb && pb.parentNode) { pb.parentNode.style.display = off('pband') ? 'none' : ''; }
	document.querySelectorAll('.tg-hist-card[data-k]').forEach(function(c) {
		c.style.display = off(c.getAttribute('data-k')) ? 'none' : '';
	});
}

function renderBattery(json) {
	var box = document.getElementById('battn');
	if (!box) { return; }
	var b = parseInt(json.battery, 10);
	if (isNaN(b) || b < 0 || b > 100) { box.style.display = 'none'; return; }
	var chg = json.battery_charging === '1';
	var key = b + ':' + (chg ? 1 : 0);
	box.title = chg ? _('Modem battery, charging') : _('Modem battery');
	box.style.display = '';
	if (box.getAttribute('data-k') === key) { return; }
	box.setAttribute('data-k', key);
	var w = Math.max(1, Math.round(15 * b / 100));
	var col = chg ? '#2fb344' : (b <= 15 ? '#d9534f' : 'currentColor');
	var svg = '<svg class="tg-batt-ico" viewBox="0 0 24 14" width="24" height="14" fill="none">'
		+ '<rect x="1" y="1" width="19" height="12" rx="2.5" stroke="currentColor" stroke-width="1.6"></rect>'
		+ '<rect x="21.2" y="4.5" width="1.8" height="5" rx=".8" fill="currentColor"></rect>'
		+ '<rect x="3" y="3" width="' + w + '" height="8" rx="1.2" fill="' + col + '"></rect>'
		+ (chg ? '<path d="M11.6 2.2 8 7.6h2.9L9.9 11.8l3.9-5.6h-2.9z" fill="#fff" stroke="#1d7a2f" stroke-width=".5" stroke-linejoin="round"></path>' : '')
		+ '</svg>';
	box.innerHTML = '<span class="tg-batt-wrap">' + svg + '</span><span id="batt">' + b + '%</span>';
}

function chipBox(head) {
	var box = document.getElementById('modemchips');
	if (!box) {
		box = E('span', { 'id': 'modemchips' });
		head.appendChild(box);
	}
	return box;
}

function alignToChips(el, top) {
	var cb = document.getElementById('modemchips');
	var h = cb ? cb.offsetHeight : 0;
	el.style.top = h ? getComputedStyle(cb).top : top;
	el.style.height = h ? h + 'px' : '';
}

function renderVidPid(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var el = document.getElementById('modemvidpid');
	var vp = String(json.vidpid || '').trim();
	if (!vp || vp === ':') { if (el) { el.remove(); } return; }
	if (!el) {
		el = E('span', {
			'id': 'modemvidpid',
			'class': 'tginfo-vidpid',
			'title': _('USB vendor and product ID')
		}, '');
		var box = chipBox(head);
		box.insertBefore(el, box.firstChild);
	}
	if (el.textContent !== vp) { el.textContent = vp; }
}

function renderProtoChip(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var chip = document.getElementById('proto-chip');
	var txt = (json.backend === 'hilink') ? 'HiLink'
		: mutil.protoLabel(json.iface_proto || json.protocol);
	var adm = document.getElementById('router-admin-link');
	var gw = String(json.gateway || '');
	if (json.tether === 'router' && /^\d{1,3}(\.\d{1,3}){3}$/.test(gw)) {
		if (!adm) {
			adm = routerAdminIcon(gw);
			adm.id = 'router-admin-link';
			head.insertBefore(adm, document.getElementById('modemname-text') || head.firstChild);
		}
		adm.href = 'http://' + gw + '/';
		adm.title = _('Open its admin page (%s)').format(gw);
	} else if (adm) { adm.remove(); }
	if (!txt) { if (chip) { chip.remove(); } return; }
	if (!chip) {
		chip = E('span', {
			'id': 'proto-chip',
			'style': 'display:inline-block; line-height:1.4;'
				+ 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;'
				+ 'font-size:.72rem; border:1px solid rgba(128,128,128,.35); border-radius:5px;'
				+ 'background:rgba(128,128,128,.1); padding:.05em .45em;'
				+ 'opacity:.7; white-space:nowrap; font-weight:normal;',
			'title': _('Current interface protocol')
		}, '');
		chip._ghost = E('img', {
			'src': mutil.icon('icons/5gmodem/cghost.svg'), 'alt': '',
			'title': _('hidden from ModemManager'),
			'style': 'width:11px; height:11px; margin-right:.3em; opacity:.8;'
				+ 'vertical-align:-1px; display:none; pointer-events:none;'
		});
		chip._label = E('span', {}, '');
		chip.appendChild(chip._ghost);
		chip.appendChild(chip._label);
		chipBox(head).appendChild(chip);
	}
	if (chip._label.textContent !== txt) { chip._label.textContent = txt; }
	var hidden = (String(json.mm_running) === '1' && String(json.mm_hidden) === '1');
	chip._ghost.style.display = hidden ? 'inline-block' : 'none';
}

function renderApnLine(json) {
	var el = document.getElementById('apnline');
	if (!el) { return; }
	var apn = String(json.iface_apn || '').trim();
	if (apn === '-') { apn = ''; }
	var pdp = mutil.pdpLabel(json.iface_pdptype);
	if (pdp === '-') { pdp = ''; }
	if (json.backend === 'hilink' || json.at_debug === '1' || (!apn && !pdp)) { el.style.display = 'none'; return; }
	el.style.display = '';
	el.innerHTML = '';
	var mono = 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;';
	var row = [
		E('strong', {}, 'APN: '),
		E('span', { 'style': mono }, [ apn || _('default') ])
	];
	if (pdp) {
		row.push(E('span', { 'style': 'opacity:.6; margin:0 .4em;' }, '|'));
		row.push(E('span', { 'style': mono }, [ pdp ]));
	}
	el.appendChild(E('div', {}, row));
}

function switchToDebug(btn) {
	if (btn) { btn.disabled = true; }
	setModemBusy(_('Switching the modem into the mode with AT ports…'));
	L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autosetup',
		(pageModemPath || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '') ]), {});
	reloadWhenDebugReady();
}

function reloadWhenDebugReady(tries) {
	tries = tries || 0;
	var _rdArgs = [ 'cached', '4' ];
	if (pageModemPath) { _rdArgs.push('for=' + pageModemPath); }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', _rdArgs), '').then(function(out) {
		var ready = false;
		try { var j = JSON.parse(out || '{}'); ready = ((String(j.backend || '').toLowerCase() !== 'hilink') && (j.at_debug === '1')) || !!HL_DEBUG_ON[String(j.vidpid || '')]; } catch (e) {}
		if (ready || tries >= 18) { window.location.reload(); }
		else { window.setTimeout(function() { reloadWhenDebugReady(tries + 1); }, 3000); }
	});
}

var _c4Last = null;
function cell4cellsUrl(json) {
	var mcc = parseInt(json.operator_mcc, 10);
	var mnc = parseInt(json.operator_mnc, 10);
	var cid = parseInt(json.cid_dec, 10);
	if ((isNaN(mcc) || isNaN(mnc)) && _c4Last && _c4Last.cid === cid && cid > 0) {
		return _c4Last.res;
	}
	if (isNaN(mcc) || isNaN(mnc) || isNaN(cid) || cid <= 0) { return null; }

	var lac = parseInt((json.tac_d && String(json.tac_d).length ? json.tac_d : (json.tac_dec || '')), 10);
	if (isNaN(lac)) { lac = parseInt(json.lac_dec || '', 10); }

	var mode = String(json.mode || '').toUpperCase();
	var lteFact = !!(mutil.cellVal(json.earfcn) || mutil.cellVal(json.pband) || mutil.cellVal(json.enbid));
	var tech, num, needLac = true;
	if (lteFact) { mode = 'LTE'; }
	if (mode.indexOf('GSM') >= 0 || mode.indexOf('EDGE') >= 0 || mode.indexOf('GPRS') >= 0 || mode.indexOf('2G') >= 0) {
		tech = 1; num = cid; needLac = false;
	} else if (mode.indexOf('WCDMA') >= 0 || mode.indexOf('UMTS') >= 0 || mode.indexOf('HSPA') >= 0 || mode.indexOf('3G') >= 0) {
		tech = 2; num = (cid % 65536);
		var lac3 = parseInt(json.lac_dec, 10);
		if (!isNaN(lac3) && lac3 > 0) { lac = lac3; }
	} else if (mode.indexOf('5G SA') >= 0) {
		return null;
	} else {
		tech = 3; num = Math.floor(cid / 256);
		needLac = false;
	}

	var p3 = function(x) { x = String(x); while (x.length < 3) { x = '0' + x; } return x; };
	var url = 'https://4cells.ru/?plmn=' + p3(mcc) + p3(mnc) + '&tech=' + tech + '&num=' + num;
	if (needLac) {
		if (isNaN(lac)) { return null; }
		url += '&lac=' + lac;
	}
	var _c4res = { url: url, tech: tech, num: num };
	_c4Last = { cid: cid, res: _c4res };
	return _c4res;
}

function mapPinButton(c4, label) {
	return E('button', {
		'class': 'cbi-button',
		'style': 'margin:0;',
		'title': _('View the tower on the 4cells.ru map'),
		'click': function() { window.open(c4.url, '_blank', 'noopener'); }
	}, [ '\u{1F4CD}' + label ]);
}

function rebootModem(hard) {
	if (hard) { setModemBusy(_('The modem is restarting…'), 90); }
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ hard ? 'hard' : 'soft' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			if (hard) { clearModemBusy(true); }
			ui.addNotification(null, E('p', d.error === 'AT port busy' ? _('The modem AT port is busy, try again') : _('Modem AT port not found')), 'error');
			return;
		}
		if (!hard) {
			if (ui.addTimeLimitedNotification)
				ui.addTimeLimitedNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 8000, 'info');
			else
				ui.addNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 'info');
		}
	}).catch(function(err) {
		if (hard) { clearModemBusy(true); }
		ui.addNotification(null, E('p', _('Failed to restart the modem') + ': ' + (err.message || err)), 'error');
	});
}

var _powerRebootMode = 'power';
function rebootModemPower() {
	setModemBusy(_('The modem is restarting…'), 120);
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ _powerRebootMode ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			clearModemBusy(true);
			ui.addNotification(null, E('p', _('No modem power GPIO on this board')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification)
			ui.addTimeLimitedNotification(null, E('p', _('The modem is power-cycling. This can take up to 3 minutes; if it does not come back, the app retries by itself.')), 8000, 'info');
		else
			ui.addNotification(null, E('p', _('The modem is power-cycling. This can take up to 3 minutes; if it does not come back, the app retries by itself.')), 'info');
	}).catch(function(err) {
		clearModemBusy(true);
		ui.addNotification(null, E('p', _('Failed to power-cycle the modem') + ': ' + (err.message || err)), 'error');
	});
}

function initPowerBtn() {
	var b = document.getElementById('btn-power-reboot');
	if (!b) { return; }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/reboot_modem.sh', [ 'haspower' ]), '').then(function(out) {
		var g = ''; try { g = (JSON.parse(out || '{}').gpio) || ''; } catch (e) {}
		if (g) { _powerRebootMode = 'power'; b.style.display = ''; return; }
		return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/reboot_modem.sh', [ 'hasusbpower' ]), '').then(function(out2) {
			var m = ''; try { m = (JSON.parse(out2 || '{}').method) || ''; } catch (e) {}
			if (m) { _powerRebootMode = 'usbpower'; b.style.display = ''; }
		});
	});
}

function applyTTL(has6) {
	var g = function(id) { var e = document.getElementById(id); return e ? String(e.value).trim() : ''; };
	var cfg = function(k) { var v = uci.get('5gmodem', '@5gmodem[0]', k); return (v == null) ? '' : String(v); };
	var vals = [ g('ttl4in'), g('ttl4out'), has6 ? g('ttl6in') : cfg('ttl6in'), has6 ? g('ttl6out') : cfg('ttl6out') ];
	for (var i = 0; i < vals.length; i++) {
		if (vals[i] !== '' && (!/^\d+$/.test(vals[i]) || +vals[i] < 1 || +vals[i] > 255)) {
			ui.addNotification(null, E('p', _('TTL must be a number between 1 and 255, or empty to disable')), 'error');
			return Promise.resolve();
		}
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying TTL...')));
	return fs.exec('/usr/share/5gmodem/ttl.sh', [ 'set' ].concat(vals)).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('TTL applied')), 4000, 'info');
			} else {
				ui.addNotification(null, E('p', _('TTL applied')), 'info');
			}
		} else {
			ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + err.message), 'error');
	});
}

function connStageText(json) {
	var reg = String(json.registration || '').trim();
	var sig = String(json.signal || '').trim();
	var cs  = String(json.conn_status || '').toLowerCase();
	var hasSig = sig && sig != '-' && sig != '0';
	var tail = '';
	var en = parseInt(json.usb_enum, 10);
	if (en > 1) { tail = ' ' + _('(#%d)').format(en); }
	if (/roaming.*not allowed|roaming_not_allowed/.test(cs)) { return _('Data roaming is off'); }
	if (reg == '3') { return _('Registration denied'); }
	if (json.no_at == '1' && (reg == '' || reg == '-')) { return _('Establishing connection…') + tail; }
	if (reg != '1' && reg != '5') {
		return (hasSig ? _('Searching for network…') : _('Initialising modem…')) + tail;
	}
	if (/no ip|retry|connected|cgpaddr|address|адрес/.test(cs)) { return _('Obtaining IP…') + tail; }
	return _('Establishing connection…') + tail;
}

function updateUsbFlapWarn(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var w = document.getElementById('usbflap-warn');
	var n = parseInt(json.usb_flaps, 10);
	if (!(n >= 3)) {
		if (w) { w.remove(); }
		return;
	}
	var txt = _('The modem keeps reconnecting over USB (%d times in 10 minutes) - usually not enough power: try another port, a shorter cable or a powered hub.').format(n);
	if (!w) {
		w = E('span', {
			'id': 'usbflap-warn', 'title': txt,
			'style': 'float:right;opacity:.85;display:inline-flex;align-items:center;' +
			         'position:relative;top:.25rem;margin-left:.8em'
		}, [
			E('img', {
				'src': mutil.icon('icons/5gmodem/cwarn.svg'), 'title': txt, 'alt': '⚠',
				'style': 'width:13px;height:13px'
			})
		]);
		head.appendChild(w);
	} else {
		w.title = txt;
		var wi = w.querySelector('img');
		if (wi) { wi.title = txt; }
	}
	var vp = document.getElementById('modemchips');
	if (vp && w.previousElementSibling !== vp) {
		head.insertBefore(w, vp.nextSibling);
	}
	alignToChips(w, '.25rem');
}

function updateSimIcon(name) {
	var si = document.getElementById('simicon');
	if (!si) { return; }
	var want;
	if (name == null || String(name).length < 1 || String(name) == '-') {
		want = mutil.icon('icons/5gmodem/op-nosim.svg');
	} else {
		var ic = mutil.operatorIcon(name);
		want = ic ? mutil.icon('icons/5gmodem/' + ic + '.svg') : mutil.icon('icons/5gmodem/op-sim.svg');
	}
	if (si.getAttribute('src') != want) { si.setAttribute('src', want); }
}

function fillAntPorts(raw, rxdiv) {
	var block = document.getElementById('antports-block');
	var tbl = document.getElementById('antports-table');
	if (!block || !tbl) { return; }

	var rxl = document.getElementById('rxdiv-line');
	if (rxl) {
		var txt = null, red = false;
		if (rxdiv === '4rx')      { txt = _('Receive diversity: on, 4 receivers (4RX)'); }
		else if (rxdiv === '2rx') { txt = _('Receive diversity: on (2RX)'); }
		else if (rxdiv === 'off') { txt = _('Receive diversity: off - the second antenna is not used'); red = true; }
		else if (rxdiv === 'noant') { txt = _('Receive diversity: on, but the second antenna is not connected'); red = true; }
		if (txt) {
			rxl.style.display = '';
			rxl.style.color = red ? '#c00' : '';
			rxl.textContent = txt;
		} else if (rxl.getAttribute('data-hadata') !== '1') {
			rxl.style.display = 'none';
		}
		if (txt) { rxl.setAttribute('data-hadata', '1'); }
	}
	var rows = String(raw || '').trim().split(/\s+/).filter(function(l) {
		return (/^\d+:(-?\d+(\.\d+)?)?:(-?\d+(\.\d+)?)?(:(-?\d+(\.\d+)?)?)?$/).test(l)
			&& /:-?\d/.test(l);
	});
	var hasRssi = rows.some(function(l) { return (/^[^:]*:[^:]*:[^:]*:-?\d/).test(l); });
	if (!rows.length) {
		if (block.getAttribute('data-hadata') !== '1') { block.style.display = 'none'; }
		return;
	}
	block.style.display = '';
	block.setAttribute('data-hadata', '1');

	var ports = rows.map(function(l) { return l.split(':')[0]; }).join(',') + (hasRssi ? '+rssi' : '');
	if (!sameRender(tbl, ports)) {
		tbl.innerHTML = '';
		tbl.appendChild(E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th left' }, _('Antenna port')),
			E('th', { 'class': 'th left' }, [ gl('RSRP') ]),
			E('th', { 'class': 'th left' }, [ gl('RSRQ') ]),
		].concat(hasRssi ? [ E('th', { 'class': 'th left' }, [ gl('RSSI') ]) ] : []).concat([
			E('th', { 'class': 'th left' }, _('State'))
		])));
		rows.forEach(function(l) {
			tbl.appendChild(E('tr', { 'class': 'tr ant-row' }, [
				E('td', { 'class': 'td left ant-port' }, _('Port %d').format(parseInt(l.split(':')[0], 10))),
				E('td', { 'class': 'td left', 'data-l': _('RSRP') }, '-'),
				E('td', { 'class': 'td left', 'data-l': _('RSRQ') }, '-'),
			].concat(hasRssi ? [ E('td', { 'class': 'td left', 'data-l': _('RSSI') }, '-') ] : []).concat([
				E('td', { 'class': 'td left', 'data-l': _('State') }, '-')
			])));
		});
	}

	var trs = tbl.querySelectorAll('tr.ant-row');
	rows.forEach(function(l, i) {
		var tr = trs[i];
		if (!tr) { return; }
		var td = tr.querySelectorAll('td');
		var p = l.split(':');
		var rsrp = parseInt(p[1], 10);
		var st, col;
		if (isNaN(rsrp)) {
			st = '-'; col = null;
		} else if (rsrp <= -130) {
			st = _('antenna not connected'); col = 'red';
		} else {
			col = caQuality('rsrp', rsrp);
			st = (col === 'green' || col === 'yellow') ? _('antenna: normal')
			   : (col === 'orange') ? _('antenna: weak signal')
			   : _('antenna: poor signal');
		}
		var paint = function(cell, key, v, text, cap) {
			paintMetricCell(cell, key, v, text, undefined, cap);
		};
		if (td[1]) { paint(td[1], 'rsrp', p[1], p[1] + ' dBm'); }
		if (td[2]) { paint(td[2], 'rsrq', p[2], p[2] + ' dB'); }
		var stCell = 3;
		if (hasRssi) { if (td[3]) { paint(td[3], 'rssi', p[3], p[3] + ' dBm', p[2]); } stCell = 4; }
		if (td[stCell]) {
			td[stCell].textContent = st;
			td[stCell].style.color = col ? CA_COLOR[col] : '';
			td[stCell].style.fontWeight = col ? '600' : '';
		}
	});
}

function active_select() {
	L.resolveDefault(uci.load('modemdefine'), null).then(function() {
		var modemz = (uci.get('modemdefine', '@modemdefine[1]', 'comm_port'));
		var btn = document.getElementById("modc");
		if (!btn) { return; }
		if (!modemz) {
			btn.style.display = 'none';
		}
		else {
			btn.style.display = 'block';
			btn.disabled = false;
		}
	});
}

var _connBase = null;
function connTick() {
	if (!_connBase) { return; }
	var el = document.getElementById('conndur');
	if (!el) { return; }
	var sec = _connBase.sec + Math.floor((Date.now() - _connBase.at) / 1000);
	el.textContent = mutil.formatDuration(sec);
}
window.setInterval(connTick, 1000);

function checkOperatorName(t) {
    var w = t.split(" ");
    var f = {};

    for (var i = 0; i < w.length; i++) {
        var wo = w[i].toLowerCase(); 
        if (!f.hasOwnProperty(wo)) {
            f[wo] = i;
        }
    }

    var u = Object.keys(f).map(function(wo) {
        return w[f[wo]];
    });

    var r = u.join(" ");
    return r;
}

function buildNoModemBlock() {
	return E('div', { 'class': 'cbi-section tginfo', 'id': 'modem-none-block' }, [
		E('h3', { 'style': 'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; display:flow-root;' }, _('Modem')),
		E('div', { 'class': 'tgm-nomodem', 'id': 'modem-none-text' }, [
			E('span', {}, [
				_('No modem connected'),
				E('div', { 'style': 'font-size:85%; opacity:.75; margin-top:.4em; font-weight:normal' },
					_('Plug the modem into USB — setup is automatic'))
			])
		])
	]);
}

function noModemRemember(yes) {
	try {
		if (yes) { window.localStorage.setItem('tgm-nomodem', '1'); }
		else { window.localStorage.removeItem('tgm-nomodem'); }
	} catch (e) {}
}
function noModemRemembered() {
	try { return window.localStorage.getItem('tgm-nomodem') === '1'; } catch (e) { return false; }
}

var _simpleOverride = null;
var _advSticky = false;
var _lastJson = null;
var _docRun = false;
function netOnlyOn() {
	return uci.get('5gmodem', '@5gmodem[0]', 'netonly') === '1';
}
function simpleOn() {
	if (_simpleOverride !== null) { return _simpleOverride; }
	return uci.get('5gmodem', '@5gmodem[0]', 'simple_view') === '1';
}
function applySimpleVis() {
	var on = simpleOn();
	document.body.classList.toggle('sc-simple', on);
	netarrange.simple(on);
	var cb = document.getElementById('sc-switch');
	if (cb) { cb.classList.toggle('on', on); }
}
function buildSimpleUI() {
	if (document.getElementById('sc-style')) { applySimpleVis(); return; }
	var mib = document.getElementById('modem-info-block');
	if (!mib || !mib.parentNode) { return; }
	document.head.appendChild(E('style', { 'id': 'sc-style' },
		'body.sc-simple [data-blk="cell"], body.sc-simple [data-blk="freq"],' +
		'body.sc-simple [data-blk="ttl"], body.sc-simple [data-blk="hist"] { display:none !important; }' +
		'body.sc-simple #modem-info-block table.table tr { display:none !important; }' +
		'body.sc-simple #modem-info-block table.table tr#rebootn { display:table-row !important; }' +
		'body:not(.sc-simple) #doctorn, body:not(.sc-simple) #doctorlogn { display:none !important; }' +
		'body.sc-simple #modem-reboot-block table.table tr#doctorlogn:has(#doctor-log[style*="display:none"]),' +
		'body.sc-simple #modem-reboot-block table.table tr#doctorlogn:has(#doctor-log[style*="display: none"]) { display:none !important; }' +
		'body.sc-simple #modem-info-block table.table tr#doctorn { display:table-row !important; }' +
		'body.sc-simple #modem-reboot-block table.table tr#doctorn { display:table-row !important; }' +
		'body.sc-simple #modemchips,' +
		'body.sc-simple #apnline { display:none !important; }' +
		'body.sc-simple #modemname > #stale-mark { font-size:.78rem; line-height:1.4; height:1.4em; top:.35em !important; }' +
		'body.sc-simple #modem-info-block[data-rat] #stale-mark { height:calc(1.4em + 4px); }' +
		'body.sc-simple #mode .tginfo-freq:not(.tginfo-dist) { display:none !important; }' +
		'body.sc-simple #modemname { border-bottom:none !important; box-shadow:none !important; }' +
		'#sc-line { display:none; }' +
		'body.sc-simple #sc-line { display:inline-flex; }' +
		'body:not(.sc-simple) #sc-advice { display:none !important; }' +
		'#view { transition: opacity .18s ease; }' +
		'#view.sc-fading { opacity: 0; }' +
		'@media (prefers-reduced-motion: reduce) { #view { transition: none; } }'));
	var head = document.getElementById('modemname');
	if (head) {
		head.appendChild(E('span', { 'id': 'sc-line',
			'style': 'float:right; align-items:center; gap:.45em; font-size:.78rem;'
				+ 'font-weight:normal; font-family:-apple-system,system-ui,sans-serif;'
				+ 'line-height:1.4; position:relative; top:.35em; margin-left:.8em;' }, [
			E('span', { 'id': 'sc-lamp', 'class': 'netpri-svcdot unknown' }),
			E('span', { 'id': 'sc-text' }, _('Checking the modem…'))
		]));
	}
	var rb = document.getElementById('rebootn');
	if (rb && rb.parentNode && !document.getElementById('doctorn')) {
		var drow = E('tr', { 'id': 'doctorn', 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%', 'style': 'vertical-align:middle' }, [ _('Internet not working?') ]),
			E('td', { 'class': 'td left tginfo-modesw', 'style': 'vertical-align:middle' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { runDoctor(ev.target); } }, _('Check and fix'))
			])
		]);
		rb.parentNode.insertBefore(drow, rb.nextSibling);
		rb.parentNode.insertBefore(E('tr', { 'id': 'doctorlogn', 'class': 'tr' }, [
			E('td', { 'class': 'td left tg-rb-pad', 'width': '33%' }, []),
			E('td', { 'class': 'td left' }, [
				E('div', { 'id': 'doctor-log',
					'style': 'display:none; font-size:92%; line-height:1.75; opacity:.9' })
			])
		]), drow.nextSibling);
	}
	var gen = mib.querySelector('.tginfo-general');
	if (gen) {
		gen.parentNode.insertBefore(E('div', { 'id': 'sc-advice',
			'style': 'display:none; font-size:90%; opacity:.8; margin:.5em 0 .2em' }), gen.nextSibling);
	}
	mib.parentNode.insertBefore(E('div', {
		'class': 'tg-simple-toggle',
		'style': 'display:flex; justify-content:flex-end; align-items:center; gap:.5em;'
			+ 'font-size:90%; opacity:.85; cursor:pointer; user-select:none',
		'click': function(ev) {
			if (ev && ev.target && ev.target.closest && ev.target.closest('.tg-updbar')) { return; }
			_simpleOverride = !simpleOn();
			fs.exec('/usr/share/5gmodem/setopt.sh',
				[ 'simpleview', _simpleOverride ? '1' : '0' ]).catch(function() {});
			var host = document.getElementById('view') || document.body;
			host.classList.add('sc-fading');
			window.setTimeout(function() {
				applySimpleVis();
				window.setTimeout(function() { host.classList.remove('sc-fading'); }, 30);
			}, 180);
		}
	}, [
		E('span', { 'id': 'sc-switch', 'class': 'btnsw btnsw-sm' }),
		E('span', {}, _('Simple view'))
	]), mib.nextSibling);
	buildUpdBar(mib.nextSibling);
	applySimpleVis();
}

var _upd = null;
function updSec() {
	return parseInt(L.env.pollinterval, 10) || 5;
}
function buildUpdBar(row) {
	if (!row || document.getElementById('tg-updbar')) { return; }
	var time = E('b', {}, '');
	var bar = E('i');
	var box = E('span', { 'id': 'tg-updbar', 'class': 'tg-updbar', 'hidden': true,
		'title': _('Time of the latest modem data; the bar runs until the next update') }, [
		E('span', {}, _('Updated')), time,
		E('span', { 'class': 'tg-upd-cd' }, bar)
	]);
	row.insertBefore(box, row.firstChild);
	_upd = { box: box, time: time, bar: bar };
}
function updBarTick(json) {
	if (!_upd || !_upd.box.isConnected || !json || json.error) { return; }
	var age = parseInt(json.age, 10) || 0;
	var at = Date.now() - age * 1000;
	if (_upd.at && Math.abs(at - _upd.at) < 2500) { return; }
	if (_upd.at) {
		var gap = (at - _upd.at) / 1000;
		if (gap > 1 && gap < 60) { _upd.period = _upd.period ? (_upd.period * 0.6 + gap * 0.4) : gap; }
	}
	_upd.at = at;
	var d = new Date(at);
	var p2 = function(n) { return (n < 10 ? '0' : '') + n; };
	_upd.time.textContent = p2(d.getHours()) + ':' + p2(d.getMinutes()) + ':' + p2(d.getSeconds());
	_upd.box.hidden = false;
	var left = Math.max(0.3, (_upd.period || updSec()) - age);
	var b = _upd.bar;
	b.style.transition = 'none';
	b.style.width = '100%';
	void b.offsetWidth;
	b.style.transition = 'width ' + left.toFixed(1) + 's linear';
	b.style.width = '0%';
}
function tetherText(json) {
	if (json.tether === 'router') {
		if (json.tether_state === 'ready') {
			return _('A router shares internet over USB.') + (json.ipaddr ? ' ' + _('This router got the address %s from it.').format(json.ipaddr) : '')
				+ ' ' + _('Signal, operator and SMS are managed on that router.');
		}
		return _('A router is connected over USB but has not given an address yet.');
	}
	if (json.tether !== 'iphone') {
		var nm = (json.tether_name && json.tether_name !== '-') ? json.tether_name : _('Phone');
		if (json.tether_state === 'ready') {
			return _('%s shares internet over USB.').format(nm) + (json.ipaddr ? ' ' + _('Address: %s.').format(json.ipaddr) : '')
				+ ' ' + _('Signal, operator and SMS are not available from a phone.');
		}
		return _('%s is connected but does not share internet. Turn on USB tethering on the phone.').format(nm);
	}
	switch (json.tether_state) {
	case 'ready':
		return _('iPhone shares internet over USB.') + (json.ipaddr ? ' ' + _('Address: %s.').format(json.ipaddr) : '')
			+ ' ' + _('Signal, operator and SMS are not available from an iPhone.');
	case 'no_hotspot':
		return _('iPhone is connected but does not share internet. Turn on Personal Hotspot on the iPhone.');
	case 'no_usbmuxd':
	case 'no_driver':
		return _('iPhone is connected. To use it as a USB modem, install the usbmuxd and kmod-usb-net-ipheth packages.');
	default:
		return _('iPhone is connected. Unlock it, tap Trust on the iPhone and turn on Personal Hotspot.');
	}
}

function routerAdminIcon(gw) {
	var a = E('a', { 'href': 'http://' + gw + '/', 'target': '_blank', 'rel': 'noopener',
		'title': _('Open its admin page (%s)').format(gw),
		'style': 'display:inline-block; width:1.05em; height:1.05em; margin-right:.4em; vertical-align:-.12em; color:inherit;' });
	a.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="100%" height="100%" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 13 5 5"/><path d="M17 13l2-8"/><circle cx="7.5" cy="16.5" r=".6" fill="currentColor"/><circle cx="10.5" cy="16.5" r=".6" fill="currentColor"/><path d="M14 16.5h3.5"/></svg>';
	return a;
}

function tetherAdminLink(el, json) {
	var gw = String(json.gateway || '');
	if (json.tether !== 'router' || json.tether_state !== 'ready' || !/^\d{1,3}(\.\d{1,3}){3}$/.test(gw)) { return; }
	el.insertBefore(routerAdminIcon(gw), el.firstChild);
}

function updateSimpleLine(json) {
	var lamp = document.getElementById('sc-lamp');
	var text = document.getElementById('sc-text');
	if (!lamp || !text || !simpleOn()) { return; }
	var reg = String(json.registration || '');
	var regOk = (reg === '1' || reg === '5');
	var hasIp = !!(json.ipaddr && json.ipaddr !== '-');
	var st, txt;
	if (regOk && hasIp)   { st = 'on';      txt = _('Internet is working'); }
	else if (regOk)       { st = 'unknown'; txt = _('Registered on the network, connecting…'); }
	else if (reg === '7') { st = 'unknown'; txt = _('SMS only — no data connection'); }
	else if (json.tether) { st = (json.tether_state === 'ready') ? 'on' : 'unknown'; txt = tetherText(json); }
	else if (!json.modem || json.modem === '-') { st = 'off'; txt = _('No modem found') + ' — ' + _('Plug the modem into USB — setup is automatic'); }
	else { st = 'off'; txt = _('No network') + ' — ' + _('Check the SIM card and the antennas'); }
	if (json.no_at == '1' && (reg === '' || reg === '-') && json.modem && json.modem !== '-') {
		if (hasIp) { st = 'on'; txt = _('Internet is working'); }
		else { st = 'unknown'; txt = _('Metrics are not polled: background AT polling is off'); }
	}
	if (json.error === 'busy' && !regOk && !hasIp) {
		st = 'unknown'; txt = _('Collecting data from the modem…');
	}
	lamp.className = 'netpri-svcdot ' + st;
	text.textContent = txt;
	if (json.tether) { tetherAdminLink(text, json); }
	var adv = document.getElementById('sc-advice');
	if (adv) {
		var _rs = parseFloat(json.rsrp);
		var _pc = parseInt(json.signal, 10);
		var _bad  = !isNaN(_pc) ? (_pc <= 35) : (!isNaN(_rs) && _rs <= -110);
		var _good = !isNaN(_pc) ? (_pc >= 45) : (isNaN(_rs) || _rs >= -106);
		if (regOk && _bad) { _advSticky = true; }
		else if (!regOk || _good) { _advSticky = false; }
		if (_advSticky) {
			if (!adv.firstChild) {
				adv.appendChild(document.createTextNode(
					_('Weak signal — try moving the router closer to a window or connecting an external antenna') + ' '));
				if (uci.get('5gmodem', '@5gmodem[0]', 'align_enabled') === '1') {
					adv.appendChild(E('a', { 'href': L.url('admin/modem/5gmodem/align') }, _('Antenna alignment')));
				}
			}
			adv.style.display = '';
		} else {
			adv.style.display = 'none';
		}
	}
}

function doctorOk() {
	var j = _lastJson || {};
	var reg = String(j.registration || '');
	var hasIp = !!(j.ipaddr && j.ipaddr !== '-');
	if (j.no_at == '1' && (reg === '' || reg === '-')) { return hasIp; }
	return (reg === '1' || reg === '5') && hasIp;
}
function doctorWait(secs) {
	return new Promise(function(res) {
		var t0 = Date.now();
		var iv = window.setInterval(function() {
			if (doctorOk()) { window.clearInterval(iv); res(true); }
			else if (Date.now() - t0 > secs * 1000) { window.clearInterval(iv); res(false); }
		}, 1500);
	});
}
function runDoctor(btn) {
	if (_docRun) { return; }
	_docRun = true; btn.disabled = true;
	var log = document.getElementById('doctor-log');
	log.innerHTML = ''; log.style.display = '';
	var line = function(t) { var el = E('div', {}, t); log.appendChild(el); return el; };
	var mark = function(el, ok, t) { el.textContent = (ok ? '\u2713 ' : '\u2717 ') + t; };
	var finish = function() { _docRun = false; btn.disabled = false; };
	var giveup = function() {
		line(_('Automatic fixes did not help — check the SIM card, the antennas and the balance'));
		finish();
	};
	var l1 = line(_('Checking the connection…'));
	window.setTimeout(function() {
	if (doctorOk()) {
		mark(l1, true, _('The connection is fine'));
		line(_('If sites still do not open, check the SIM balance and tariff'));
		finish(); return;
	}
	mark(l1, false, _('No connection'));
	var l2 = line(_('Reconnecting…'));
	fs.exec('/usr/share/5gmodem/setopt.sh', [ 'reconnect' ]).then(function() {
		return doctorWait(35);
	}).then(function(ok) {
		if (ok) { mark(l2, true, _('Done — the internet is back')); finish(); return; }
		mark(l2, false, _('Did not help'));
		var l3 = line(_('Restarting the modem…'));
		return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'soft' ]).then(function() {
			return doctorWait(80);
		}).then(function(ok2) {
			if (ok2) { mark(l3, true, _('Done — the internet is back')); finish(); return; }
			mark(l3, false, _('Did not help'));
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/reboot_modem.sh', [ 'hasusbpower' ]), '').then(function(out) {
				var m = ''; try { m = (JSON.parse(out || '{}').method) || ''; } catch (e) {}
				if (!m) { giveup(); return; }
				var l4 = line(_('Power-cycling the modem over USB…'));
				return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'usbpower' ]).then(function() {
					return doctorWait(120);
				}).then(function(ok3) {
					if (ok3) { mark(l4, true, _('Done — the internet is back')); finish(); }
					else { mark(l4, false, _('Did not help')); giveup(); }
				});
			});
		});
	}).catch(finish);
	}, 400);
}

function _escTxt(v) {
	return String(v == null ? '' : v).replace(/[&<>"]/g, function(c) {
		return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
	});
}

function applyMetrics(json) {
					var foreign = !!(json && (json.error === 'not_active'
						|| (json.path && pageModemPath && json.path !== pageModemPath)));
					if (foreign) {
						if (Date.now() - _inPlaceAt < 20000) { return; }
						if (++foreignTicks >= 3) {
							foreignTicks = 0;
							try { window.sessionStorage.removeItem('5gm-tab'); } catch (e) {}
							window.location.reload();
						}
						return;
					}
					foreignTicks = 0;
					_lastJson = json;
					updateSimpleLine(json);
					try { mobileview.tick(json); } catch (e) {}
					updBarTick(json);
					qualSetMode(json.mode);

					runAfterFirstPoll();
					refreshSlotsIfChanged(json);
					updateSmsEnvelope();

					var _age = parseInt(json.age, 10);
					var _stale = (!isNaN(_age) && _age >= 30);
					var _present = (String(json.onbus) === '1') || !!json.modem;
					var _noModem = (json.error && json.error !== 'busy' && !json.modem) || (_stale && !_present);
					var _onbus = (String(json.onbus) === '1');
					var _mib = document.getElementById('modem-info-block');
					var _none = document.getElementById('modem-none-block');
					var _cell = document.querySelector('[data-blk="cell"]');
					var _freq = document.querySelector('[data-blk="freq"]');
					var _ttl = document.querySelector('[data-blk="ttl"]');
					var _rbb = document.getElementById('modem-reboot-block');
					noModemRemember(_noModem && !_onbus);
					if (_noModem) {
						if (_mib) { _mib.style.display = 'none'; }
						if (_cell) { _cell.style.display = 'none'; }
						if (_ttl) { _ttl.style.display = 'none'; }
						histShow(false);
						var _ctl = _onbus && !json.tether;
						if (_freq) { _freq.style.display = _ctl ? '' : 'none'; }
						if (_rbb) { _rbb.style.display = _ctl ? '' : 'none'; }
						if (!_none && _mib && _mib.parentNode) {
							_none = buildNoModemBlock();
							_mib.parentNode.insertBefore(_none, _mib);
						}
						var _nt = document.getElementById('modem-none-text');
						if (_nt) {
							_nt.classList.toggle('tgm-nomodem-note', !!_onbus);
							var _ns = _nt.firstElementChild || _nt;
							_ns.textContent = !_onbus ? _('No modem connected')
								: json.tether ? tetherText(json)
								: (String(json.hasports) === '1')
									? _('The modem is on the USB bus, but its AT port is not answering: it is busy or the modem is stuck. If this lasts, restart the modem with the Restart modem buttons below.')
									: _('A device is present on the USB bus, but it does not respond to AT commands. It looks like a mobile phone. It can share internet, but signal, operator and SMS management are unavailable.');
							if (_onbus && json.tether) { tetherAdminLink(_ns, json); }
						}
						if (_none) { _none.style.display = ''; }
						return;
					}
					if (_none) { _none.style.display = 'none'; }
					if (_mib) { _mib.style.display = ''; }
					var _remote = (json.backend === 'router');
					if (_cell) { _cell.style.display = _remote ? 'none' : ''; }
					if (_freq) { _freq.style.display = _remote ? 'none' : ''; }
					if (_rbb) { _rbb.style.display = _remote ? 'none' : ''; }
					if (_ttl) { _ttl.style.display = ''; }
					histShow(!_remote);
					if (!_remote) {
						histPush(json);
						histDraw(json);
						if (Date.now() - _histSeedAt > 30000) { histSeed(); }
					}

					if (json.backend === 'hilink') {
						[ 'tacn', 'lacn', 'ca-comp' ].forEach(function(id) {
							var el = document.getElementById(id);
							if (el) { el.style.display = 'none'; }
						});
					}

					if (modemBusyActive()) {
						var _reg = String(json.registration || '');
						var _sig = parseInt(json.signal, 10);
						var _noAtUp = (json.no_at == '1' && (_reg === '' || _reg === '-') && !!(json.ipaddr && json.ipaddr !== '-'));
						if (_reg === '1' || (!isNaN(_sig) && _sig > 0) || _noAtUp) { clearModemBusy(); }
					}

			bandsui.pollTick();
				fillAntPorts(json.antports, json.rxdiv);

					var wicon, ticon, t;
					var wicon = mutil.icon('icons/5gmodem/cloading.svg');
					var ticon = '<svg width="12" height="12" viewBox="0 0 128 128" style="vertical-align:-1px" aria-hidden="true"><path fill="#B0BEC5" d="M64,0C28.656,0,0,28.656,0,64s28.656,64,64,64s64-28.656,64-64S99.344,0,64,0z M64,120C33.125,120,8,94.875,8,64S33.125,8,64,8s56,25.125,56,56S94.875,120,64,120z"/><path fill="#03A9F4" d="M92.281,80.969L72,60.688V40c0-4.422-3.578-8-8-8s-8,3.578-8,8v27.313l24.969,24.969c3.125,3.133,8.188,3.133,11.313,0C95.414,89.156,95.414,84.092,92.281,80.969z"/></svg>';
					var dicon = '<svg width="11" height="11" viewBox="0 0 52 52" style="vertical-align:-1px" aria-hidden="true"><path fill="#009955" d="M8.3,14h35.4c1,0,1.7,1.3,0.9,2.2L27.3,37.4c-0.6,0.8-1.9,0.8-2.5,0L7.3,16.2C6.6,15.3,7.2,14,8.3,14z"/></svg>';
					var uicon = '<svg width="11" height="11" viewBox="0 0 52 52" style="vertical-align:-1px" aria-hidden="true"><path fill="#0099ff" d="M43.7,38H8.3c-1,0-1.7-1.3-0.9-2.2l17.3-21.2c0.6-0.8,1.9-0.8,2.5,0l17.5,21.2C45.4,36.7,44.8,38,43.7,38z"/></svg>';

					var p = parseInt(json.signal, 10);
					if (isNaN(p) || p < 0)
						p = 0;

					var sgv = document.getElementById('signal');
					if (sgv) {
						var sgi = sgv.querySelector('svg.tg-sig');
						if (!sgi) {
							sgv.textContent = '';
							sgv.appendChild(mutil.signalSvg(p));
							sgv.appendChild(E('br'));
							sgv.appendChild(E('medium', {}, p + '%'));
						} else {
							mutil.signalSet(sgi, p);
							var sgm = sgv.querySelector('medium');
							if (sgm) { sgm.textContent = p + '%'; }
						}
					}

					if (document.getElementById('connst')) {
						var view = document.getElementById("connst");
						var _ctCand = (parseInt(json.conn_time_sec, 10) || 0) + (parseInt(json.age, 10) || 0);
						var _ctExp = _connBase ? _connBase.sec + Math.floor((Date.now() - _connBase.at) / 1000) : null;
						if (_ctExp === null || Math.abs(_ctCand - _ctExp) > 3) {
							_connBase = { sec: _ctCand, at: Date.now() };
						}
						if (json.conn_time == '' || json.conn_time == '-') {
							_connBase = null;
						var _msg = connStageText(json);
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/> ', wicon)
							+ '<span class="tginfo-connstatus">' + _msg + '</span>';
						}
						else {
						view.innerHTML = ticon + ' ' + '<span id="conndur" style="font-variant-numeric:tabular-nums">' + mutil.formatDuration(_connBase ? _connBase.sec + Math.floor((Date.now() - _connBase.at) / 1000) : json.conn_time_sec) + '</span> | ' + dicon + '\u202f' + _escTxt(mutil.localizeBytes(json.rx)) + ' ' + uicon + '\u202f' + _escTxt(mutil.localizeBytes(json.tx));
						}
					}

					updateUsbFlapWarn(json);

					if (document.getElementById('operator')) {
						var view = document.getElementById("operator");
						var _visited = String(json.operator_name || '');
						var _home = String(json.home_operator || '');
						var _roam = (json.roaming == '1') || json.registration == '5' || json.registration == '7';
						var _iconName = _visited;
						var _simProb = {
							'SIM not inserted': _('SIM not detected: reinsert the card'),
							'SIM PIN required': _('SIM PIN required'),
							'SIM PUK required': _('SIM PUK required'),
							'SIM failure': _('SIM failure'),
							'SIM busy': _('SIM busy'),
							'SIM wrong': _('SIM wrong'),
							'eSIM has no profile': _('The active eSIM has no profile: switch to the physical SIM or download a profile'),
							'Network personalization PIN required': _('Network personalization PIN required')
						}[String(json.registration || '')];
						if (_visited.length <= 1) {
							view.textContent = _simProb || '-';
						} else if (_roam && _home.length > 1 &&
						           checkOperatorName(_home).toLowerCase() !== checkOperatorName(_visited).toLowerCase()) {
							view.textContent = checkOperatorName(_home) + ' | ' + checkOperatorName(_visited);
							_iconName = _home;
						} else {
							view.textContent = checkOperatorName(_visited);
						}
						if (_visited.length > 1 && json.path && uci.get('5gmodem',
							'm_' + String(json.path).replace(/[^A-Za-z0-9]/g, '_'), 'netsel') === 'manual') {
							view.appendChild(E('span', { 'class': 'tg-netsel',
								'title': _('The network is selected manually on the Modem tab') }, _('manual')));
						}
						updateSimIcon(_iconName);
						var _st = document.getElementById('simtip');
						if (_st && !sameRender(_st, [ json.simslot, json.imsi,
						                             json.iccid, json.imei ].join('|'))) {
							_st.innerHTML = '';
							_st.appendChild(SIMdata(json));
						}
					}

					var _hasPhone = (json.phone && String(json.phone).length > 3 && json.phone != '-');
					if (document.getElementById('phone')) {
						var pv = document.getElementById('phone');
						var _imsiNow = String(json.imsi || '');
						if (_imsiNow && _imsiNow !== '-' && pv.getAttribute('data-imsi') !== _imsiNow) {
							if (pv.getAttribute('data-imsi') != null) { pv.removeAttribute('data-hadata'); }
							pv.setAttribute('data-imsi', _imsiNow);
						}
						if (_hasPhone) {
							pv.textContent = mutil.formatPhone(json.phone);
							pv.style.display = '';
							pv.setAttribute('data-hadata', '1');
						} else if (pv.getAttribute('data-hadata') !== '1') {
							pv.style.display = 'none';
						}
						_hasPhone = _hasPhone || pv.getAttribute('data-hadata') === '1';
					}

					if (document.getElementById('location')) {
						var viewloc = document.getElementById("location");
						var _loc = String(json.location || '');
						if (!_hasPhone && _loc.length > 1 && _loc != '-') {
							viewloc.style.display = '';
							viewloc.textContent = _(_loc);
						} else {
							viewloc.style.display = 'none';
						}
					}

					if (document.getElementById('sim')) {
						var view = document.getElementById("sim");
						var sv = document.getElementById("simv");
						if (json.no_at == '1' && (json.registration == '' || json.registration == '-')) {
						view.textContent = _('Metrics are not polled: background AT polling is off');
						}
						else if (json.registration == '') { 
						view.textContent = '-';
						}
						else {
						sv.style.visibility = "visible";
						view.textContent = ({
							'SIM not inserted': _('SIM not inserted'),
							'SIM PIN required': _('SIM PIN required'),
							'SIM PUK required': _('SIM PUK required'),
							'SIM failure': _('SIM failure'),
							'SIM busy': _('SIM busy'),
							'SIM wrong': _('SIM wrong'),
							'eSIM has no profile': _('The active eSIM has no profile: switch to the physical SIM or download a profile'),
							'Network personalization PIN required': _('Network personalization PIN required')
						})[String(json.registration)] || json.registration;
						if (json.registration == '0') { 
							view.textContent = _('Not registered');
						}
						if (json.registration == '1') { 
							view.textContent = _('Registered');
						}
						if (json.registration == '2') { 
							view.textContent = _('Searching..');
						}
						if (json.registration == '3') { 
							view.textContent = _('Registering denied');
						}
						if (json.registration == '5') {
							view.innerHTML = '<span class="tginfo-roam" title="' + _('Roaming') + '">®</span>';
							view.appendChild(document.createTextNode(_('Online')));
						}
						if (json.registration == '6') {
							view.textContent = _('Registered, only SMS');
						}
						if (json.registration == '7') {
							view.innerHTML = '<span class="tginfo-roam" title="' + _('Roaming') + '">®</span>';
							view.appendChild(document.createTextNode(_('Online, only SMS')));
						}
					}
					}

					if (document.getElementById('mode')) {
						var view = document.getElementById("mode");
						var mv = String(json.mode || '').trim();
						var _mibR = document.getElementById('modem-info-block');
						if (_mibR && mutil.ratFill) {
							if (uci.get('5gmodem', '@5gmodem[0]', 'rat_card') === '0') { _mibR.removeAttribute('data-rat'); }
							else { _mibR.setAttribute('data-rat', mutil.ratFill(mv)); }
						}
						if (mv && mv != '-') {
							var mtext = mutil.formatModeDisplay(mv).replace(/[&<>]/g, function(c) {
								return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
							});
							var _mh = mtext
								.replace(/\b([Bn])(\d+)\b/g, function(_m, _bl, _bn) {
									return '<span class="btn cbi-button cbi-button-action important tginfo-band' + (_bl === 'n' ? ' tginfo-band-nr' : '') + '" title="' +
										_('Active carrier: this band is carrying your data right now') + '">' + _bl + _bn + '</span>';
								})
								.replace(/\(([^)]*)\)/g, '<span class="tginfo-freq">($1)</span>')
								.replace(/\|/g, '<span style="font-weight:normal;opacity:.65">|</span>');
								var _bsd = parseInt(json.bs_distance, 10);
								if (_bsd > 0) {
									var _bskm = (_bsd >= 1000) ? ('~' + (_bsd / 1000).toFixed(1) + 'km')
									                           : ('~' + _bsd + 'm');
									_mh += ' <span class="tginfo-freq tginfo-dist">' + _bskm + '</span>';
								}
							var _inact = [];
							for (var _ci = 1; _ci <= 4; _ci++) {
								if (String(json['s' + _ci + 'state'] || '') !== 'deactivated') { continue; }
								var _cbm = String(json['s' + _ci + 'band'] || '').match(/[Bn]\d+/);
								if (!_cbm) { continue; }
								_inact.push(_cbm[0]);
							}
							if (_inact.length) {
								_mh += _inact.map(function(b) {
									return ' <span style="font-weight:normal;opacity:.65">+</span>' +
										'<span class="btn cbi-button tginfo-band tginfo-band-idle"' +
										' title="' + _('Standby carrier: the network has assembled this band into the aggregation but it is idle now - it activates when traffic grows') + '">' + b + '</span>';
								}).join('');
							}
							var _mimoTxt = '', _mimoTip = '';
							var _pm = parseInt(json.pmimo, 10);
							if (_pm >= 1 && _pm <= 4) {
								_mimoTxt = 'MIMO ' + _pm + '×' + _pm;
								_mimoTip = _('Transmission rank: the network is sending %d parallel data streams right now').format(_pm);
							} else if (json.rxdiv === 'noant') {
								_mimoTxt = 'RX 1';
								_mimoTip = _('Receive diversity: on, but the second antenna is not connected');
							} else if (json.rxdiv === '4rx' || json.rxdiv === '2rx' || json.rxdiv === 'off') {
								_mimoTxt = (json.rxdiv === '4rx') ? 'RX 4' : (json.rxdiv === '2rx') ? 'RX 2' : 'RX 1';
								_mimoTip = (json.rxdiv === '4rx') ? _('Receive diversity: on, 4 receivers (4RX)')
								         : (json.rxdiv === '2rx') ? _('Receive diversity: on (2RX)')
								         : _('Receive diversity: off - the second antenna is not used');
							} else {
								var _apRows = String(json.antports || '').trim().split(/\s+/).filter(function(l) { return (/:-?\d/).test(l); });
								if (_apRows.length) {
									var _apOn = _apRows.filter(function(l) {
										var m = l.match(/^\d+:(-?\d+)/);
										return m && parseInt(m[1], 10) > -130;
									}).length;
									_mimoTxt = 'RX ' + _apOn + '/' + _apRows.length;
									_mimoTip = _('Receive chains: %d of %d antenna ports hear the network (details in the Antenna ports table)').format(_apOn, _apRows.length);
								}
							}
							var _ca = caSummary(json);
							if (_ca.n > 1) {
								_mh += ' <span class="tginfo-ca" title="' + caTip(_ca) + '">' + _ca.n + 'CA</span>';
							}
							if (_mimoTxt) {
								_mh += ' <span class="tginfo-freq" style="cursor:help" title="' + _mimoTip + '">' + _mimoTxt + '</span>';
							}
							if (view.getAttribute('data-mh') !== _mh) {
								view.innerHTML = _mh;
								view.setAttribute('data-mh', _mh);
							}
						}
						else if (!view.textContent || !view.textContent.trim()) {
							view.textContent = '-';
						}
					}

					if (json.iface) {
						if (json.iface !== _extScope) {
							extip.unwatch(_extScope);
							_extScope = json.iface;
						}
						extip.watch(_extScope);
					}
					_ipLast.v4 = (json.ipaddr  && json.ipaddr  != '-') ? json.ipaddr  : '';
					_ipLast.v6 = (json.ipaddr6 && json.ipaddr6 != '-') ? json.ipaddr6 : '';
					paintIpRow('v4');
					paintIpRow('v6');

					if (document.getElementById('modem')) {
						var view = document.getElementById("modem");
						if (!json.modem || json.modem.length <= 1) {
						view.textContent = '-';
						}
						else {
						view.textContent = json.modem;
						}
					}

					if (document.getElementById('modemname')) {
						var _al = (json.alias && json.alias !== '-') ? String(json.alias).trim() : '';
						var _nm = _al ? _al
							: ((json.modem && json.modem.length > 1) ? json.modem : _('Modem'));
						if (json.backend === 'hilink') { _nm += ' (HiLink)'; }
						else if (json.at_debug === '1' && json.at_native !== '1') { _nm += ' (Debug)'; }
						var _nt = document.getElementById('modemname-text');
						if (_nt && _nt.textContent !== _nm) { _nt.textContent = _nm; }
						renderDebugBtn(json);
						renderWebPassHint(json);
						renderBattery(json);
						renderNa(json);
						renderTemps(json);
						var _rr = document.getElementById('rb-radio-btn');
						if (_rr) { _rr.style.display = (json.backend === 'hilink') ? 'none' : ''; }
						renderProtoChip(json);
						renderVidPid(json);
						renderApnLine(json);
					}

					if (document.getElementById('fw')) {
						var view = document.getElementById("fw");
						if (!json.firmware || json.firmware.length <= 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.firmware;
						}
					}

					if (document.getElementById('cport')) {
						var view = document.getElementById("cport");
						if (!json.cport || json.cport.length <= 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.cport;
						}
					}

					if (document.getElementById('protocol')) {
						var view = document.getElementById("protocol");
						if (!json.protocol || json.protocol.length <= 1) {
						view.textContent = '-';
						}
						else {
						view.textContent = mutil.protoLabel(json.protocol);
						}
					}

					bandsui.hwTick(json);

					if (json.iface_proto && json.iface_proto != '-') {
						var _liveMM = mutil.isMMProto(json.iface_proto);
						if (_liveMM && !ifaceProtoIsMM) {
							ifaceProtoIsMM = true;
							bandsui.ungate();
						} else if (!_liveMM) {
							ifaceProtoIsMM = false;
						}
						if (_liveMM && !mmIdx && Date.now() - _mmIdxAt > 15000) {
							_mmIdxAt = Date.now();
							loadMmIdx();
						}
					}

					if (document.getElementById('bandnote-text') && json.protocol && json.protocol != '-' && !bandsui.isStaticNote()) {
						var xmmCap = (json.xmm_capable === '1');
						var isXmm = (String(json.iface_proto || '').toLowerCase() === 'xmm');
						var isHilink = (String(json.backend || '').toLowerCase() === 'hilink');
						var mmBtn = document.getElementById('bandnote-mm-btn');
						var xmmBtn = document.getElementById('bandnote-xmm-btn');
						var dbgBtn = document.getElementById('bandnote-dbg-btn');
						var freqBlk = document.querySelector('[data-blk="freq"]');
						if (freqBlk) { freqBlk.style.display = (json.backend === 'router' || (isHilink && !hilinkHasDebug(json) && json.hl_modes !== '1')) ? 'none' : ''; }
						if (bandsui.isTakeover()) {
							document.getElementById('bandnote-text').textContent =
								_('Changing bands briefly interrupts the connection: the app hands the modem to ModemManager, applies the change and reconnects (up to a minute).');
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						} else if (isHilink) {
							document.getElementById('bandnote-text').textContent =
								_('Band and network-mode management is not available in HiLink (web API) mode. Switch the modem to Debug mode (button below): it exposes AT ports for bands, network mode and USSD while keeping the connection.');
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = hilinkHasDebug(json) ? '' : 'none'; }
						} else if (xmmCap && !isXmm) {
							document.getElementById('bandnote-text').textContent =
								_('Band and network-mode management is not available in %s mode. Switch this modem to XMM mode (button below) to manage bands.').format(mutil.protoLabel(json.protocol));
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = ''; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						} else if (!json.modem && !json.imei && String(json.protocol || '') === 'dhcp') {
							document.getElementById('bandnote-text').textContent =
								_('This is a plain USB network device (phone tethering or similar), not a modem: it has no AT port and no control channel. Bands, network mode and other cellular settings are managed on the device itself.');
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						} else {
							var _mbimpWait = mutil.isSharedProxyProto(json.iface_proto);
							document.getElementById('bandnote-text').textContent = _mbimpWait
								? _('ModemManager is still picking up the modem: bands and network mode unlock by themselves in a minute or two, the connection is not affected.')
								: bandsui.isReadOnly()
								? _('Bands and network mode are shown read-only: in %s mode they can be read but not changed. Switch the interface to ModemManager to manage them.').format(mutil.protoLabel(json.protocol))
								: _('Band and network-mode management is not available in %s mode. Switch the interface to ModemManager (in the modem settings) to manage bands.').format(mutil.protoLabel(json.protocol));
							if (mmBtn) { mmBtn.style.display = _mbimpWait ? 'none' : ''; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						}
					}

					(function() {
						var head = document.getElementById('modemname');
						if (!head) { return; }
						var age = parseInt(json.age, 10);
						var mark = document.getElementById('stale-mark');
						if (isNaN(age) || age <= 10) { if (mark) { mark.remove(); } return; }
						var txt = (age < 120)
							? _('Data has not been updated for %d s (shown from the last snapshot)').format(age)
							: _('Data has not been updated for %d min (shown from the last snapshot)').format(Math.round(age / 60));
						if (mark) {
							if (mark.nextElementSibling) { head.appendChild(mark); }
							mark.title = txt;
							var mi = mark.querySelector('img');
							if (mi) { mi.title = txt; }
							alignToChips(mark, '.25rem');
							return;
						}
						mark = head.appendChild(E('span', {
							'id': 'stale-mark', 'title': txt,
							'style': 'float:right;opacity:.55;display:inline-flex;align-items:center;' +
							         'position:relative;top:.25rem;margin-left:.8em'
						}, [
							E('img', {
								'src': mutil.icon('icons/5gmodem/cloading.svg'), 'title': txt, 'alt': '⌛',
								'style': 'width:12px;height:12px'
							})
						]));
						alignToChips(mark, '.25rem');
					}());

					if (document.getElementById('temp')) {
						var view = document.getElementById("temp");
						var viewn = document.getElementById("tempn");
						var t = json.mtemp;
						if (t == null || t == '' || t == '-' || (String(t).length <= 1 && String(t).indexOf(' ') >= 0)) {
						var lv = parseInt(json.mtherm, 10);
						if (!isNaN(lv) && lv >= 0 && lv <= 3) {
							var lbl = [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv];
							view.textContent = lbl;
							view.title = _('Modem thermal throttling level: %d of 3').format(lv);
							setRowVisible(view, true);
						} else {
							setRowVisible(view, false);
						}
						}
						else {
						setRowVisible(view, true);
						var raw = String(t).replace('&deg;', '°');
						var m = raw.match(/-?\d+(?:\.\d+)?/);
						var num = m ? m[0] : raw.replace(/\s*°?\s*C\s*$/, '');
						var txt = m ? (m[0] + ' °C') : raw;
						var lv2 = parseInt(json.mtherm, 10);
						var thermSuffix = '';
						if (!isNaN(lv2) && lv2 >= 1 && lv2 <= 3) {
							thermSuffix = ', ' + [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv2];
							view.title = _('Modem thermal throttling level: %d of 3').format(lv2);
						}
						if (!sameRender(view, num + '|' + thermSuffix)) {
							view.innerHTML = '';
							view.appendChild(document.createTextNode(num + '°'));
							view.appendChild(E('span', { 'class': 'deg-unit' }, 'C'));
							if (thermSuffix) { view.appendChild(document.createTextNode(thermSuffix)); }
						}
						}
					}

					if (document.getElementById('csq')) {
						var view = document.getElementById("csq");
						if (json.signal == 0 || json.signal == '-') {
						view.style.visibility = 'hidden';
						}
						else {
						view.style.visibility = 'visible';
						csq_bar(json.csq, 31);
						}
					}

					mutil.qualRssiCap(json.rsrq);
					if (document.getElementById('rssi')) {
						var view = document.getElementById("rssi");
						if (json.rssi == null) { }
						else if (json.rssi == '-') {
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rssi;
							if (z.includes('dBm')) { 
							var rssi_min = -110;
							rssi_bar(json.rssi, rssi_min);	
							}
							else {
							var rssi_min = -110;
							rssi_bar(json.rssi + " dBm", rssi_min);
							}
						}
					}

					if (document.getElementById('rsrp')) {
						var view = document.getElementById('rsrp');
						if (json.rsrp == null) { }
						else if (json.rsrp == '-') {
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rsrp;
							if (z.includes('dBm')) { 
							var rsrp_min = -140;
							rsrp_bar(json.rsrp, rsrp_min);

							}
							else {
							var rsrp_min = -140;
							rsrp_bar(json.rsrp + " dBm", rsrp_min);
							}
						}
					}

					if (document.getElementById('sinr')) {
						var view = document.getElementById("sinr");
						if (json.sinr == null) { }
						else if (json.sinr == '-') {
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.sinr;
							var sinr_min = -21;
							sinr_bar(sinrUnmeasured(z, json.rsrq) ? '-' : (z.includes('dB') ? z : (z + " dB")), sinr_min);
						}
					}

					if (document.getElementById('rsrq')) {
						var view = document.getElementById("rsrq");
						if (json.rsrq == null) { }
						else if (json.rsrq == '-') {
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rsrq;
							var rsrq_min = -20;
							rsrq_bar(z.includes('dB') ? z : (z + " dB"), rsrq_min);
						}
					}

					if (document.getElementById('rscpn')) {
						var row = document.getElementById('rscpn');
						if (json.rscp && json.rscp != '-' && json.rscp != '') {
							row.style.display = '';
							var z = String(json.rscp);
							rscp_bar(z.includes('dBm') ? z : (z + ' dBm'), -121);
						} else {
							row.style.display = 'none';
						}
					}
					if (document.getElementById('ection')) {
						var row = document.getElementById('ection');
						if (json.ecio && json.ecio != '-' && json.ecio != '') {
							row.style.display = '';
							var z = String(json.ecio);
							ecio_bar(z.includes('dB') ? z : (z + ' dB'), -24);
						} else {
							row.style.display = 'none';
						}
					}

					renderCellRows(json);

					renderCaTable(json);
					renderNeighbors(json);
}

return view.extend({

modemDialog: baseclass.extend({
		__init__: function(title, description, callback) {
			this.title       = title;
			this.description = description;
			this.callback    = callback;
		},

		load: function() {
			return uci.load('modemdefine');
		},

		render: function(content) {

			var sections = uci.sections('modemdefine');
			var portM = sections.length;

    			var result = "";
    			for (var i = 1; i < portM; i++) {
       			       	result += sections[i].comm_port + '_' + sections[i].network + '#' + sections[i].comm_port + ' - ' + sections[i].modem + ' (' + sections[i].user_desc + ');';
    			}
			var result = result.slice(0, -1);
			var result = result.replace(/\(undefined\)/g, "");

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('div', { 'class': 'cbi-section' },
						E('p', {},
							E('div', { 'class': 'cbi-value' }, [
							E('p'),
							E('label', { 'class': 'cbi-value-title' }, [ _('Modem') ]),
							E('div', { 'class': 'cbi-value-field' }, [
								(function() {
									var ch = {}; var order = [];
									(result || "").trim().split(/;/).forEach(function(cmd) {
										var fields = cmd.split(/#/);
										if (!fields[0]) { return; }
										ch[fields[0]] = fields[1] || fields[0];
										order.push(fields[0]);
									});
									var w = new ui.Dropdown(order[0] || '', ch,
										{ id: 'mselect', sort: order });
									var n = w.render();
									n.style.width = '100%';
									return n;
								})()
							]) 
						]),
						)
					),
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, this.handleDissmis),
					}, _('Cancel')),

					' ',
					E('button', {
						'id': 'btn_save',
						'class': 'btn cbi-button-positive important',
						'click': ui.createHandlerFn(this, this.handleSave),
					}, _('Save')),

				]),
			]);
		},

		handleSave: function(ev) {

			return uci.load('modemdefine').then(function() {

				var _msn = document.getElementById('mselect');
				var _msw = _msn ? dom.findClassInstance(_msn) : null;
				var vx = _msw ? String(_msw.getValue() || '') : '';
				var marr = vx.split('_');

				uci.set('modemdefine', '@general[0]', 'main_modem', marr[0].toString());
				uci.set('modemdefine', '@general[0]', 'main_network', marr[1].toString());

				uci.save();
				uci.apply();

				window.setTimeout(function() {
					if (!poll.active()) poll.start();
					location.reload();
				}, 2000);
			});

		},

		handleDissmis: function(ev) {
				ui.hideModal();
				if (!poll.active()) poll.start();
		},

		show: function() {
			ui.showModal(null,
				E('p', { 'class': 'spinning' }, _('Loading'))
			);
			poll.stop();
			this.load().then(content => {
				ui.hideModal();
				return this.render(content);
			}).catch(e => {
				ui.hideModal();
				if (!poll.active()) poll.start();
				ui.addNotification(null, E('p', {}, _('Failed to read modem data') + ': ' + (e.message || e)), 'error');
			})
		},
	}),

simDialog: baseclass.extend({
		__init__: function(title, description, callback) {
			this.title       = title;
			this.description = description;
			this.callback    = callback;
		},

		load: function() {
			var _sArgs = [ 'cached', '10' ];
			if (pageModemPath) { _sArgs.push('for=' + pageModemPath); }
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', _sArgs), '{}');
		},

		render: function(content) {

			var json = {};
			try { json = JSON.parse(content) || {}; } catch (e) {}

			if (!json.imei || String(json.imei).length < 3) {
				if (!poll.active()) poll.start();
				ui.addNotification(null, E('p', {}, _('The modem port is busy, try again in a few seconds')), 'warning');
				return;
			}

			var simRow = function(label, val) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:35%; white-space:nowrap; padding:8px 12px 8px 0; vertical-align:top; font-weight:600;' }, [ label ]),
					E('td', { 'class': 'td left', 'style': 'padding:8px 0; font-family:monospace; word-break:break-all; user-select:text;' }, [ (val && String(val).length) ? String(val) : '-' ]),
				]);
			};

			var typeRow = E('tr', { 'class': 'tr', 'style': 'display:none' }, [
				E('td', { 'class': 'td left', 'style': 'width:35%; white-space:nowrap; padding:8px 12px 8px 0; vertical-align:top; font-weight:600;' }, [ _('SIM type') ]),
				E('td', { 'class': 'td left', 'style': 'padding:8px 0; font-family:monospace; user-select:text;', 'id': 'simslot-type' }, [ '-' ]),
			]);

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('table', { 'class': 'table', 'style': 'width:100%; background:transparent; border:none; box-shadow:none;' }, [
						simRow(_('SIM IMSI'), json.imsi),
						simRow(_('SIM ICCID'), json.iccid),
						simRow(_('Modem IMEI'), json.imei),
						typeRow,
					]),
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, this.handleDissmis),
					}, _('Close')),
				]),
			]);

			var _stArgs = [ 'status' ];
			if (pageModemPath) { _stArgs.push('for=' + pageModemPath); }
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', _stArgs), '').then(function(out) {
				var st = {};
				try { st = JSON.parse(out) || {}; } catch (e) { return; }
				if (st.type) {
					var tc = document.getElementById('simslot-type');
					if (tc) { tc.textContent = st.type; typeRow.style.display = ''; }
				}
			});
		},

		handleDissmis: function(ev) {
				ui.hideModal();
				if (!poll.active()) poll.start();
		},

		show: function() {
			ui.showModal(null,
				E('p', { 'class': 'spinning' }, _('Loading'))
			);
			poll.stop();
			this.load().then(content => {
				ui.hideModal();
				return this.render(content);
			}).catch(e => {
				ui.hideModal();
				if (!poll.active()) poll.start();
				ui.addNotification(null, E('p', {}, _('Failed to read modem data') + ': ' + (e.message || e)), 'error');
			})
		},
	}),

	formdata: { threeginfo: {} },
	
	load: function() {
		var self = this, args = arguments;
		return fresh.check(30909, [ bandsui, extip, modemtabs, mutil, netpri, healthform, netarrange, mobileview ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		mutil.lsSweep([ 'bands5g2-', 'bands5g-', '5gmodem.esim.active', '5gmodem.ussd.supported',
		                'netpri-pingstate', 'netpri-ssclash-', 'btninfo:' ], 30);
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(fs.list('/sys/class/leds'), []),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'peek' ]), '{}'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh'), '[]')
		]).then(function(res) {
			var _lmPaths = [];
			try {
				_lmPaths = (JSON.parse(res[res.length - 1] || '[]') || []).map(function(m) { return m.path; });
			} catch (e) {}
			var _pk = {};
			try { _pk = JSON.parse(res[res.length - 2] || '{}') || {}; } catch (e) {}
			var _tabSel = '';
			try { _tabSel = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) {}
			if (_tabSel) {
				var _tabSec = 'm_' + _tabSel.replace(/[^A-Za-z0-9]/g, '_');
				if ((uci.get('5gmodem', _tabSec, 'path') || '') !== _tabSel
				    || (_lmPaths.length && _lmPaths.indexOf(_tabSel) < 0)) {
					_tabSel = '';
					try { window.sessionStorage.removeItem('5gm-tab'); } catch (e) {}
				}
			}
			pageModemPath = String(_tabSel || _pk.path || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
			loadMmIdx();
			bandsui.init({
				setModemBusy: setModemBusy,
				clearModemBusy: clearModemBusy,
				sameRender: sameRender,
				blockExpanded: blockExpanded,
				pagePath: function() { return pageModemPath; },
				forPage: forPage,
				getMmIdx: function() { return mmIdx; },
				isMM: function() { return ifaceProtoIsMM; },
				setMM: function(v) { ifaceProtoIsMM = !!v; }
			});
			try {
				var names = (res[1] || []).map(function(e) { return e.name; });
				ledsAvail = [ 'white:signal1', 'white:signal2', 'white:signal3' ]
					.every(function(n) { return names.indexOf(n) >= 0; });
			} catch (e) {}
			return [ String(res[2] || '{}'), '', null, '{}' ];
		});
	},

	render: function(res) {
		modemtabs.attach();
		var _netOnly = netOnlyOn();
		document.body.classList.toggle('sc-netonly', _netOnly);
		if (!_netOnly && noModemRemembered()) {
			var _nmTry = 0;
			var _nmTick = function() {
				var _mib = document.getElementById('modem-info-block');
				if (!_mib) {
					if (++_nmTry < 40) { window.setTimeout(_nmTick, 50); }
					return;
				}
				if (document.getElementById('modem-none-block')) { return; }
				_mib.style.display = 'none';
				[ '[data-blk="cell"]', '[data-blk="freq"]', '[data-blk="ttl"]', '[data-blk="hist"]', '#modem-reboot-block' ].forEach(function(sel) {
					var el = document.querySelector(sel);
					if (el) { el.style.display = 'none'; }
				});
				_mib.parentNode.insertBefore(buildNoModemBlock(), _mib);
			};
			window.setTimeout(_nmTick, 0);
		}
		var m, s, o;

		var showTtl = (uci.get('5gmodem', '@5gmodem[0]', 'show_ttl') !== '0');
		_histOn = (uci.get('5gmodem', '@5gmodem[0]', 'show_history') !== '0');

		var data = Array.isArray(res) ? res[0] : res;
		var mmK  = Array.isArray(res) ? (res[1] || '') : '';

		var initjson = {};
		try { initjson = JSON.parse(data) || {}; } catch (e) {}
		var has6 = (initjson.ipaddr6 != null && String(initjson.ipaddr6).length > 3 && String(initjson.ipaddr6) != '-');
		var ttlv = function(k) { var v = uci.get('5gmodem', '@5gmodem[0]', k); return (v == null) ? '' : v; };

		var ttlget = {};
		try { ttlget = JSON.parse((Array.isArray(res) ? (res[3] || '') : '') || '{}') || {}; } catch (e) {}
		var def4 = ttlget.def4 || '64';
		var def6 = ttlget.def6 || '64';

		ifaceProtoIsMM = mutil.isMMProto(initjson.iface_proto || initjson.protocol);

		var mmHasModem = /current-modes/.test(mmK);
		var mmModes = (function() {
			var mm = mmK.match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
			if (!mm) { return null; }
			return {
				allowed: mm[1].split(',').map(function(x) { return x.trim(); }).sort().join('|'),
				pref: (mm[2].trim() == 'none' ? '' : mm[2].trim())
			};
		})();
		var mmSup = [], mmCur = [];
		mmK.split('\n').forEach(function(ln) {
			var b = ln.match(/^modem\.generic\.(supported|current)-bands\.value\[\d+\]\s*:\s*(\S+)/);
			if (b) { (b[1] == 'supported' ? mmSup : mmCur).push(b[2]); }
		});
		bandsui.setOther(mmCur.filter(function(b) { return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0 && b.indexOf('utran-') != 0; }));
		var msStyle = mmHasModem ? null : 'display:none';
		var has3g = mmHasModem && mmSup.some(function(b) { return b.indexOf('utran-') == 0; });
		var modeActive = function(allowed, preferred) {
			return mmModes &&
			       mmModes.allowed == allowed.split('|').sort().join('|') &&
			       (mmModes.pref || '') == (preferred || '');
		};

		afterFirstPoll(bandsui.loadBands);

		active_select();
		afterFirstPoll(loadSimSlots);

		var upModemDialog = new this.modemDialog(
			_('Defined modems'),
			_('Interface for selecting user defined modems'),
		);

		var upSIMDialog = new this.simDialog(
			_('SIM card menu'),
			_('Information read from the SIM card and device'),
		);

		if (data != null){
		try {

		var json = JSON.parse(data);

		window._lastJson = json;

			if(!json.hasOwnProperty('error')){
				
				if (json.no_at != '1' && (json.registration == 'SIM not inserted' || json.registration == '-')) {
					if (ui.addTimeLimitedNotification)
						ui.addTimeLimitedNotification(null, E('p', _('Problem with registering to the network, check the SIM card')), 5000, 'info');
					else
						ui.addNotification(null, E('p', _('Problem with registering to the network, check the SIM card')), 'info');
				}
				if (json.registration == 'SIM PIN required') { 
					ui.addNotification(null, E('p', _('SIM PIN required')), 'info');
				}
				if (json.registration == 'SIM PUK required') { 
					ui.addNotification(null, E('p', _('SIM PUK required')), 'info');
				}
				if (json.registration == 'SIM failure') { 
					ui.addNotification(null, E('p', _('SIM failure')), 'info');
				}
				if (json.registration == 'SIM busy') { 
					ui.addNotification(null, E('p', _('SIM busy')), 'info');
				}
				if (json.registration == 'SIM wrong') { 
					ui.addNotification(null, E('p', _('SIM wrong')), 'info');
				}
				if (json.registration == 'Network personalization PIN required') {
					ui.addNotification(null, E('p', _('Network personalization PIN required')), 'info');
				}
				if (json.registration == 'SIM PIN2 required') { 
					ui.addNotification(null, E('p', _('SIM PIN2 required')), 'info');
				}
				if (json.registration == 'SIM PUK2 required') { 
					ui.addNotification(null, E('p', _('SIM PUK2 required')), 'info');
				}
				{
					if (json.connt == '' || json.connt == '-') {
						if (ui.addTimeLimitedNotification)
							ui.addTimeLimitedNotification(null, E('p', _('Waiting for the modem to connect…')), 4000, 'info');
					}

			}
			}

			pollTickFn = function() {
				var _mArgs = [ 'cached', ifaceProtoIsMM ? '6' : '10' ];
				if (pageModemPath) { _mArgs.push('for=' + pageModemPath); }
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', _mArgs), '')
					.then(function(res) {
						var _mj = null;
						try { _mj = JSON.parse(res); } catch (e) {}
						if (_mj) { applyMetrics(_mj); }
					});
				};
				if (!_netOnly) { poll.add(pollTickFn); }
				window.__5gmInPlaceSwitch = function(p) { switchModemInPlace(p); };

		} catch (err) {
				ui.addNotification(null, E('p', _('Error:') + ' ' + err.message), 'error');
				}
		}

		if (!_netOnly && initjson && (initjson.modem || initjson.signal)) {
			window.setTimeout(function() { applyMetrics(initjson); }, 0);
		}

		extip.init().then(function(fl) {
			if (fl.enabled) { extip.subscribe(applyExtIp); }
		});

		var info = _('').format('');
		m = new form.JSONMap(this.formdata, '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		s.render = L.bind(function(view, section_id) {

			return E([], [

			netpri.mount(),

			E('div', { 'class': 'cbi-section tginfo', 'id': 'modem-info-block' }, [

			E('div', { 'class': 'right' }, [
				E('button', {
					'id': 'modc',
					'style': 'position:relative; display:none; margin:0 !important; margin-top:-3% !important; left:95%; top:',
 					'disabled': 'true',
					'data-tooltip': _('Modem selection menu'),
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
							return upModemDialog.show();
					}),
				}, _('☰')),
			]),

			E('h3', { 'id': 'modemname', 'style': 'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; display:flow-root;' }, [
				E('span', { 'id': 'modemname-text' }, _('Modem'))
			]),

			E('div', { 'class': 'tginfo-general' }, [
				E('div', { 'class': 'tginfo-signal', 'id': 'signal' }, [ '-' ]),

				E('span', {
					'title': null,
					'id': 'simv',
					'style': 'visibility: hidden; display:inline-flex; align-items:center; cursor:pointer; vertical-align:middle;',
					'click': ui.createHandlerFn(this, function() {
							return upSIMDialog.show();
					}),
				}, [
					E('div', { 'class': 'cbi-tooltip-container' }, [
						E('img', {
							'id': 'simicon',
							'src': mutil.icon('icons/5gmodem/op-nosim.svg'),
							'title': _(''),
							'class': 'middle',
						}),
						E('span', { 'id': 'simtip', 'class': 'cbi-tooltip', 'style': 'text-align:left;font-size:80%' }, SIMdata(data)),
					]),
				]),

				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'id': 'sim', 'class': 'tginfo-reg' }, [ '-' ]),
					E('div', { 'id': 'operator', 'class': 'tginfo-op' }, [ '-' ]),
					E('div', { 'id': 'phone', 'class': 'tginfo-phone', 'style': 'display:none' }, [ '' ]),
					E('div', { 'id': 'location', 'class': 'tginfo-loc' }, [ '-' ]),
				]),

				E('div', { 'class': 'tginfo-info' }, [
					E('div', { 'id': 'mode', 'class': 'tginfo-tech' }, [ '-' ]),
					E('div', { 'class': 'tginfo-ip', 'id': 'modemipn', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-iplabel' }, 'IPv4:'),
						E('span', { 'id': 'modemip' }, [ '' ]),
					]),
					E('div', { 'class': 'tginfo-ip', 'id': 'modemip6n', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-iplabel' }, 'IPv6:'),
						E('span', { 'id': 'modemip6' }, [ '' ]),
					]),
					E('div', { 'id': 'connst', 'class': 'tginfo-conn' }, [ '-' ]),
				]),

				E('div', { 'class': 'tginfo-right' }, [
					E('div', { 'class': 'tginfo-simslot-row' }, [
						(function() {
							var _env = E('a', { 'id': 'smsenv', 'class': 'tg-smsenv',
								'href': L.url('admin/modem/5gmodem/readsms'),
								'title': _('Unread SMS — open Incoming'),
								'style': 'display:none' }, []);
							_env.innerHTML = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"></rect><path d="m3 7 9 6 9-6"></path></svg>';
							return _env;
						})(),
						E('div', { 'class': 'tginfo-simslot', 'id': 'simslotn', 'style': 'display:none' }, [ '' ]),
					]),
					E('div', { 'class': 'tginfo-envrow' }, [
						E('div', { 'class': 'tginfo-temp tginfo-batt', 'id': 'battn', 'style': 'display:none' }, []),
						E('div', { 'class': 'tginfo-temp tginfo-temps', 'id': 'tempsn', 'style': 'display:none' }, []),
						E('div', { 'class': 'tginfo-temp', 'id': 'tempn', 'style': 'display:none' }, [
							E('span', { 'class': 'tginfo-thermo', 'title': _('Modem temperature') }, [
								E('img', { 'src': mutil.icon('icons/5gmodem/ctemp.svg'), 'width': '16', 'height': '16', 'alt': _('Modem temperature') })
							]),
							E('span', { 'id': 'temp' }, [ '-' ]),
						]),
					]),
					E('div', { 'id': 'apnline',
						'style': 'text-align:right; font-size:85%; opacity:.8; margin-top:auto; display:none;' }, []),
				]),
			]),
			]),

			collapsibleSection('reboot', _('Restart modem'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr', 'id': 'rebootn' }, [
					E('td', { 'class': 'td left tg-rb-pad', 'width': '33%' }, []),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
							'id': 'rb-radio-btn',
							'class': 'btn cbi-button cbi-button-remove',
							'data-tooltip': _('Radio restart (CFUN=4→1): quickly re-registers on the network without re-enumerating USB. Try this first.'),
							'click': ui.createHandlerFn(this, function() { return rebootModem(false); })
						}, _('Restart radio')),
						' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'data-tooltip': _('Full restart (CFUN=1,1): the modem reboots and re-enumerates on USB. Slower, connection drops ~1 min; use when the radio restart did not help.'),
							'click': ui.createHandlerFn(this, function() { return rebootModem(true); })
						}, _('Full restart')),
						' ',
						E('button', {
							'id': 'btn-power-reboot',
							'class': 'btn cbi-button cbi-button-negative',
							'style': 'display:none',
							'data-tooltip': _('Cuts power to the modem slot for a few seconds - as if you unplugged it. The modem comes back in ~1 min. Use when a full restart did not help.'),
							'click': ui.createHandlerFn(this, function() { return rebootModemPower(); })
						}, _('Power restart'))
					]),
					]),
			]),
			], { 'id': 'modem-reboot-block' }),

			collapsibleSection('cell', _('Cell / Signal Information'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('MCC MNC') ]),
					E('td', { 'class': 'td left', 'id': 'mccmnc' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'cidn' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('Cell ID') ]),
					E('td', { 'class': 'td left', 'id': 'cid' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'tacn' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('TAC') ]),
					E('td', { 'class': 'td left', 'id': 'tac' }, [ '-' ]),
					]),
				E('tr', { 'id': 'lacn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('LAC') ]),
					E('td', { 'class': 'td left', 'id': 'lac' }, [ '-' ]),
					]),
				E('tr', { 'id': 'enbidn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						gl('eNB ID'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(base station)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'enbid' }, [ '-' ]),
					]),
				E('tr', { 'id': 'pathlossn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						gl('Path loss'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(signal attenuation)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'pathloss' }, [ '-' ]),
					]),
				E('tr', { 'id': 'txpowern', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						gl('TX power'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(modem transmit level)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'txpower' }, [ '-' ]),
					]),
				E('tr', { 'id': 'cqin', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('CQI') ]),
					E('td', { 'class': 'td left', 'id': 'cqi' }, [ '-' ]),
					]),
				E('tr', { 'id': 'rin', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						gl('RI'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(transmission rank)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'ri' }, [ '-' ]),
					]),
				E('tr', { 'id': 'uecatn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('UE category') ]),
					E('td', { 'class': 'td left', 'id': 'uecat' }, [ '-' ]),
					]),
				E('tr', { 'id': 'maxraten', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('Max speed') ]),
					E('td', { 'class': 'td left', 'id': 'maxrate' }, [ '-' ]),
					]),
				E('tr', { 'id': 'ambrn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('Operator limit') ]),
					E('td', { 'class': 'td left', 'id': 'ambr' }, [ '-' ]),
					]),
				E('tr', { 'id': 'volten', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ gl('VoLTE') ]),
					E('td', { 'class': 'td left', 'id': 'volte' }, [ '-' ]),
					]),

				E('tr', { 'id': 'csqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					gl('CSQ'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Signal Strength)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('csq'))
					]),
				E('tr', { 'id': 'rssin', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					gl('RSSI'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Received Signal Strength Indicator)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('rssi'))
					]),
				E('tr', { 'id': 'rsrpn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					gl('RSRP'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Reference Signal Receive Power)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('rsrp'))
					]),
				E('tr', { 'id': 'sinrn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					gl('SINR'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Signal to Interference plus Noise Ratio)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('sinr'))
					]),
				E('tr', { 'id': 'rsrqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					gl('RSRQ'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Reference Signal Received Quality)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('rsrq'))
					]),
				E('tr', { 'id': 'rscpn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSCP'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Received Signal Code Power, 3G)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('rscp'))
					]),
				E('tr', { 'id': 'ection', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('Ec/No'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(chip energy to noise ratio, 3G)') ]),
					]),
					E('td', { 'class': 'td' }, metricBarEl('ecio'))
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Primary band (PCC) | PCI & EARFCN')]),
					E('td', { 'class': 'td left', 'id': 'pband' }, [ '-' ]),
					]),

				]),
				E('div', { 'id': 'ca-comp', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, [ _('Carrier aggregation (per component)'), E('span', { 'class': 'tginfo-ca', 'id': 'ca-sum', 'style': 'display:none' }, []) ]),
					E('table', { 'class': 'table', 'id': 'ca-table' }, [
					E('tr', { 'class': 'tr table-titles ca-head' }, [
						E('th', { 'class': 'th left' }, [ gl('CC') ]),
						E('th', { 'class': 'th left' }, [ gl('Band') ]),
						E('th', { 'class': 'th' }, [ gl('BW') ]),
						E('th', { 'class': 'th' }, [ gl('PCI') ]),
						E('th', { 'class': 'th' }, [ gl('EARFCN') ]),
						E('th', { 'class': 'th' }, [ gl('RSRP') ]),
						E('th', { 'class': 'th' }, [ gl('RSRQ') ]),
						E('th', { 'class': 'th' }, [ gl('RSSI') ]),
						E('th', { 'class': 'th' }, [ gl('SINR') ]),
						E('th', { 'class': 'th' }, [ gl('MIMO') ]),
						E('th', { 'class': 'th' }, [ gl('Mod') ]),
						E('th', { 'class': 'th' }, [ _('State') ]),
					]),
				].concat([ 'PCC', 'SCC1', 'SCC2', 'SCC3', 'SCC4' ].map(function(cc) {
					return E('tr', { 'class': 'tr ca-row', 'data-cc': cc }, [
						E('td', { 'class': 'td left ca-cc' }, [ cc ]),
						E('td', { 'class': 'td left', 'data-l': 'Band' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'BW' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'PCI' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'EARFCN' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRP' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRQ' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSSI' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'SINR' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'MIMO' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'Mod' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': _('State') }, [ '-' ]),
					]);
				})))
				]),
				E('div', { 'id': 'nb-comp', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Neighbour cells')),
					E('table', { 'class': 'table', 'id': 'nb-table' }, [
						E('tr', { 'class': 'tr table-titles nb-head' }, [
							E('th', { 'class': 'th left' }, [ _('Cell') ]),
							E('th', { 'class': 'th left' }, [ gl('Band') ]),
							E('th', { 'class': 'th' }, [ gl('PCI') ]),
							E('th', { 'class': 'th' }, [ gl('EARFCN') ]),
							E('th', { 'class': 'th' }, [ gl('RSRP') ]),
							E('th', { 'class': 'th' }, [ gl('RSRQ') ]),
							E('th', { 'class': 'th' }, [ gl('RSSI') ]),
							E('th', { 'class': 'th' }, [ '' ]),
						])
					])
				]),

				E('div', { 'id': 'antports-block', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Antenna ports')),
					E('table', { 'class': 'table', 'id': 'antports-table' }, []),
					E('div', { 'id': 'rxdiv-line',
						'style': 'display:none;font-size:90%;padding:.4em 0 0 0' }, '')
				])
			]),

			collapsibleSection('freq', _('Frequency management'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr', 'id': 'modeswn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Network mode')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'modesw-btns' },
						[
							[ _('Auto'), '2g|3g|4g|5g', '5g' ],
							[ '2G', '2g', '' ],
							[ '3G', '3g', '' ],
							[ '4G', '3g|4g', '4g', '4g' ],
							[ '4G+5G', '3g|4g|5g', '5g' ],
							[ '5G', '3g|5g', '5g', '5g' ]
						].map(L.bind(function(mdef) {
							return E('button', {
								'class': 'btn cbi-button' + (modeActive(mdef[1], mdef[2]) ? ' tg-current' : ''),
								'data-allowed': mdef[1],
								'data-preferred': mdef[2],
								'data-pure': mdef[3] || '',
								'click': ui.createHandlerFn(this, function(ev) {
									var b = ev.currentTarget;
									return bandsui.setNetMode(b.getAttribute('data-allowed'), b.getAttribute('data-preferred'), mdef[0]);
								})
							}, mdef[0]);
						}, this))
					),
					]),
				E('tr', { 'class': 'tr', 'id': 'bands2gn', 'style': 'display:none' }, [
						E('td', { 'class': 'td left', 'width': '33%' }, [ _('2G bands')]),
						E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-2g' }, [ '-' ]),
						]),
				E('tr', { 'class': 'tr', 'id': 'bands3gn', 'style': has3g ? msStyle : 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('3G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-3g' },
						mmHasModem ? bandsui.buildBandButtons(mmSup, mmCur, 'utran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('4G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-lte' },
						mmHasModem ? bandsui.buildBandButtons(mmSup, mmCur, 'eutran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bands5gn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('5G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-nr' },
						mmHasModem ? bandsui.buildBandButtons(mmSup, mmCur, 'ngran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'caenn', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Carrier aggregation')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'caen-cell' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'mode5gn', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('5G in modem')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'mode5g-cell' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'celllockn', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Cell lock')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'celllock-cell' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandwarnn', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('div', { 'class': 'cbi-value-description' }, _('Changing bands briefly drops the connection: the IP disappears for ~15–20 seconds and comes back automatically. This is normal for this modem.'))
					]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsactn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(this, function() { return bandsui.applyBands(); })
						}, _('Apply')),
						' ',
						E('button', {
							'class': 'btn cbi-button',
							'data-tooltip': _('Enable all supported bands'),
							'click': ui.createHandlerFn(this, function() { return bandsui.resetBands(); })
						}, _('All bands'))
					]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandnote', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, ' '),
					E('td', { 'class': 'td left' }, [
						E('div', { 'class': 'alert-message info' }, [
							E('p', { 'id': 'bandnote-text', 'style': 'margin:0' },
								_('Band and network-mode switching is unavailable for this modem in the current interface mode. Switch the interface to ModemManager (in the modem settings) to manage bands.')),
							E('div', { 'style': 'margin-top:.6em' }, [
								E('button', {
									'id': 'bandnote-mm-btn',
									'class': 'btn cbi-button cbi-button-action',
									'click': function(ev) {
										ev.preventDefault();
										bandsui.switchToModemManager(ev.target);
									}
								}, _('Switch to ModemManager')),
								E('button', {
									'id': 'bandnote-xmm-btn',
									'class': 'btn cbi-button cbi-button-action',
									'style': 'display:none',
									'click': function(ev) {
										ev.preventDefault();
										bandsui.switchToXmm(ev.target);
									}
								}, _('Switch to XMM')),
								E('button', {
									'id': 'bandnote-dbg-btn',
									'class': 'btn cbi-button cbi-button-action',
									'style': 'display:none',
									'click': function(ev) {
										ev.preventDefault();
										switchToDebug(ev.target);
									}
								}, _('Switch to Debug mode'))
							])
						])
					]),
					]),
			]),
			]),

			showTtl ? collapsibleSection('ttl', _('TTL fixing'), [
				(function() {
					var mkin = function(id, ph) { return E('input', { 'id': id, 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:3.5em;text-align:center', 'placeholder': ph, 'value': ttlv(id) }); };
					return E('div', { 'style': 'display:flex;flex-wrap:wrap;align-items:center;gap:.35em .9em;padding:.2em 0' }, [
						E('span', { 'style': 'display:inline-flex;align-items:center;gap:.35em' }, [
							E('span', { 'style': 'opacity:.8' }, _('TTL IPv4 (in / out)')),
							mkin('ttl4in', def4), ' / ', mkin('ttl4out', def4)
						]),
						has6 ? E('span', { 'style': 'display:inline-flex;align-items:center;gap:.35em' }, [
							E('span', { 'style': 'opacity:.8' }, _('Hop Limit IPv6 (in / out)')),
							mkin('ttl6in', def6), ' / ', mkin('ttl6out', def6)
						]) : '',
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'style': 'white-space:nowrap',
							'click': ui.createHandlerFn(this, function() { return applyTTL(has6); })
						}, _('Apply'))
					]);
				}).call(this)
			]) : '',

			_histOn ? collapsibleSection('hist', _('History'), [ histBuild() ]) : ''
		]);
		}, o, this);

		return m.render().then(function(node) {
			try { netarrange.prepare(node); } catch (e) {}
			if (!netOnlyOn()) { try { mobileview.prepare(node); } catch (e) {} }
			window.setTimeout(initPowerBtn, 0);
			window.setTimeout(buildSimpleUI, 0);
			window.setTimeout(function() { try { netarrange.attach(); } catch (e) {} }, 0);
			return node;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
