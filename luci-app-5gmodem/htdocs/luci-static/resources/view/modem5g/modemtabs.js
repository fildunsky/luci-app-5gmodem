'use strict';
'require baseclass';
'require fs';
'require uci';
'require poll';
'require ui';
'require view.modem5g.mutil as mutil';

(function() {
	if (/\/argon\//.test(document.querySelector('link[href*="cascade.css"]') ? document.querySelector('link[href*="cascade.css"]').href : '')) {
		document.documentElement.classList.add('tg-theme-argon');
	}
	if (/\/cyberpunk\//.test(document.querySelector('link[href*="cascade.css"]') ? document.querySelector('link[href*="cascade.css"]').href : '')) {
		document.documentElement.classList.add('tg-theme-cyberpunk');
	}
	if (document.getElementById('tg-modem-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-modem-css';
	l.rel = 'stylesheet';
	l.type = 'text/css';
	l.href = L.resource('view/modem5g/modem.css');
	document.head.appendChild(l);
})();

(function() {
	function run() {
		var de = document.documentElement;
		if (de.hasAttribute('data-tg-sec')) { return; }
		de.setAttribute('data-tg-sec', '1');
		var host = document.getElementById('view') || document.getElementById('maincontent') || document.body;
		if (!host) { return; }
		var p = document.createElement('div');
		p.className = 'cbi-section';
		p.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden';
		host.appendChild(p);
		var cs = getComputedStyle(p);
		var bg = cs.backgroundColor || '';
		var framed = (parseFloat(cs.borderTopWidth) > 0 && cs.borderTopStyle !== 'none')
			|| (cs.boxShadow && cs.boxShadow !== 'none')
			|| (bg !== '' && bg !== 'transparent' && !/rgba\([^)]*,\s*0\)$/.test(bg));
		host.removeChild(p);
		if (framed) { de.classList.add('tg-boxed-sec'); }
	}
	if (document.body) { run(); }
	else { document.addEventListener('DOMContentLoaded', run); }
})();

function vendor(m) {
	var pr = String((m && m.product) || '');
	if (/VOS_5G|RXMG1/i.test(pr)) { return 'Compal'; }
	var vid = String((m && m.vidpid) || '').split(':')[0].toLowerCase();
	if (vid === '0e8d' && !/^0e8d:712/i.test(String(m.vidpid))) { return ''; }
	// 05c6 is deliberately absent, see docs/subsystems/ui.md#modem-tab-labels
	var map = {
		'1bc7': 'Telit', '2c7c': 'Quectel', '2cb7': 'Fibocom',
		'0e8d': 'Fibocom', '1e2d': 'Cinterion', '12d1': 'Huawei', '19d2': 'ZTE',
		'2dee': 'MeigLink', '0489': 'Foxconn', '413c': 'Dell',
		'1e0e': 'SIMCom'
	};
	return map[vid] || '';
}

var MODEL_BY_VIDPID = {
	'2c7c:0121': 'EC21',    '2c7c:0125': 'EC25',   '2c7c:0296': 'BG96',
	'2c7c:0306': 'EP06',    '2c7c:0512': 'EG12',   '2c7c:0620': 'EM160R',
	'2c7c:0800': 'RM500Q',  '2c7c:0801': 'RM520N', '2c7c:0900': 'RM500U',
	'2c7c:0901': 'EC200U',  '2c7c:0700': 'BG95',   '2c7c:0203': 'BG95-M3'
};

function modelName(m) {
	if (m && m.model) { return String(m.model).trim(); }
	var id = String((m && m.vidpid) || '').toLowerCase();
	if (MODEL_BY_VIDPID[id]) { return MODEL_BY_VIDPID[id]; }
	var p = (m && m.product) ? String(m.product).trim() : '';
	if (/^(VOS_5G|RXMG1|RXM-G1)$/i.test(p)) { return 'RXM-G1'; }
	return p;
}

function dedupLabels(modems) {
	var seen = {}, out = modems.map(function(m, i) { return label(m, i); });
	out.forEach(function(l) { seen[l] = (seen[l] || 0) + 1; });
	return out.map(function(l, i) {
		if (modems[i] && modems[i].alias) { return l; }
		return (seen[l] > 1) ? (l + ' (' + (modems[i].path || (i + 1)) + ')') : l;
	});
}

function label(m, i) {
	if (m && m.alias) { return String(m.alias).trim(); }
	var p = modelName(m);
	var v = vendor(m);
	var generic = (!p || /^android$/i.test(p) || /^usb/i.test(p) || /^simtech/i.test(p)
		|| (/modem/i.test(p) && p.length < 6));
	if (generic) { return v ? (v + ' ' + _('modem')) : _('Modem %d').format(i + 1); }
	if (v && p.toLowerCase().indexOf(v.toLowerCase()) < 0) { return v + ' ' + p; }
	return p;
}

function loadModems() {
	return Promise.all([
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh'), '[]'),
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'active' ]), '')
	]).then(function(res) {
		var modems = [];
		try { modems = JSON.parse(res[0] || '[]') || []; } catch (e) {}
		if (!Array.isArray(modems)) { modems = []; }
		var active = String(res[1] || '').trim();
		var _sel = '';
		try { _sel = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) {}
		if (_sel && modems.some(function(m) { return m.path === _sel; })) {
			active = _sel;
		}
		if (!modems.some(function(m) { return m.path === active; })) {
			active = modems.length ? modems[0].path : '';
		}
		return { modems: modems, active: active };
	});
}

var ESIM_SEEN_BASE = '5gmodem.esim.active';
function esimSeenKey() {
	var p = '';
	try { p = (uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''); } catch (e) {}
	return p ? (ESIM_SEEN_BASE + '.' + p) : ESIM_SEEN_BASE;
}

function esimHideRule(on) {
	var st = document.getElementById('esim-tab-hide');
	if (on) {
		if (!st) {
			st = E('style', { 'id': 'esim-tab-hide', 'type': 'text/css' },
				'a[href*="5gmodem/esim"], li:has(> a[href*="5gmodem/esim"]) { display: none !important; }');
			document.head.appendChild(st);
		}
	} else if (st && st.parentNode) {
		st.parentNode.removeChild(st);
	}
}

(function() {
	var was = '0', keyed = false;
	try {
		var k = esimSeenKey();
		keyed = (k !== ESIM_SEEN_BASE);
		was = localStorage.getItem(k) || '0';
	} catch (e) {}
	esimHideRule(!(keyed && was === '1'));
})();

var USSD_SEEN_BASE = '5gmodem.ussd.supported';
function ussdSeenKey() {
	var p = '';
	try { p = (uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''); } catch (e) {}
	return p ? (USSD_SEEN_BASE + '.' + p) : USSD_SEEN_BASE;
}

function ussdHideRule(on) {
	var st = document.getElementById('ussd-tab-hide');
	if (on) {
		if (!st) {
			st = E('style', { 'id': 'ussd-tab-hide', 'type': 'text/css' },
				'a[href*="5gmodem/sendussd"], li:has(> a[href*="5gmodem/sendussd"]) { display: none !important; }');
			document.head.appendChild(st);
		}
	} else if (st && st.parentNode) {
		st.parentNode.removeChild(st);
	}
}

(function() {
	try {
		var k = ussdSeenKey();
		if (k !== USSD_SEEN_BASE && localStorage.getItem(k) === '0') { ussdHideRule(true); }
	} catch (e) {}
})();

function gateHideRule(id, sub, on) {
	var st = document.getElementById(id);
	if (on) {
		if (!st) {
			st = E('style', { 'id': id, 'type': 'text/css' },
				'a[href*="5gmodem/' + sub + '"], li:has(> a[href*="5gmodem/' + sub + '"]) { display: none !important; }');
			document.head.appendChild(st);
		}
	} else if (st && st.parentNode) {
		st.parentNode.removeChild(st);
	}
}

var NETONLY_TABS = [ 'esim', 'diagnostics', 'align', 'readsms', 'sendsms', 'sendussd', 'sendat' ];

function netonlyHideTabs(on) {
	NETONLY_TABS.forEach(function(sub) {
		gateHideRule('netonly-' + sub + '-hide', sub, on);
	});
}

function applyGateTabs() {
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		var ss = uci.sections('5gmodem', '5gmodem');
		var sid = (ss && ss[0]) ? ss[0]['.name'] : null;
		var al = sid ? String(uci.get('5gmodem', sid, 'align_enabled') || '') : '';
		var stt = sid ? String(uci.get('5gmodem', sid, 'show_stats') || '') : '';
		var no = sid ? String(uci.get('5gmodem', sid, 'netonly') || '') : '';
		gateHideRule('align-tab-hide', 'align', al !== '1' || no === '1');
		gateHideRule('stats-tab-hide', 'stats', stt === '0');
		netonlyHideTabs(no === '1');
		try {
			localStorage.setItem('5gmodem.gate.align', al === '1' ? '1' : '0');
			localStorage.setItem('5gmodem.gate.stats', stt === '0' ? '0' : '1');
			localStorage.setItem('5gmodem.gate.netonly', no === '1' ? '1' : '0');
		} catch (e) {}
	});
}

(function() {
	try {
		if (localStorage.getItem('5gmodem.gate.align') !== '1') { gateHideRule('align-tab-hide', 'align', true); }
		if (localStorage.getItem('5gmodem.gate.stats') === '0') { gateHideRule('stats-tab-hide', 'stats', true); }
		if (localStorage.getItem('5gmodem.gate.netonly') === '1') { netonlyHideTabs(true); }
	} catch (e) {}
})();

function applyUssdTabVisibility() {
	return L.resolveDefault(uci.load('5gmodem'))
		.then(function() {
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ussdsupport' ]), {});
		})
		.then(function(r) {
			var st = {};
			try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			var bad = (String(st.supported) === '0');
			ussdHideRule(bad);
			try { localStorage.setItem(ussdSeenKey(), bad ? '0' : '1'); } catch (e) {}
			mutil.lsTouch(ussdSeenKey());
		});
}

function applyEsimTabVisibility(tries) {
	return L.resolveDefault(uci.load('5gmodem'))
		.then(function() {
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/esim.sh', [ 'status' ]), {});
		})
		.then(function(r) {
			var st = {};
			try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			if (st && st.pending) {
				var t = (typeof tries === 'number') ? tries : 0;
				if (t < 2) { window.setTimeout(function() { applyEsimTabVisibility(t + 1); }, 2000); }
				return;
			}
			var have = !!(st && st.available);
			esimHideRule(!have);
			try { localStorage.setItem(esimSeenKey(), have ? '1' : '0'); } catch (e) {}
			mutil.lsTouch(esimSeenKey());
		});
}

function ghostBar() {
	var items = tabsCacheLoad() || [ { label: null, active: true } ];

	return E('div', { 'class': 'modemtabs-bar' }, items.map(function(it) {
		return E('button', {
			'class': 'btn cbi-button modemtab modemtab-ghost'
				+ (it.label ? '' : ' modemtab-blank')
				+ (it.active ? ' active' : '')
		}, [
			E('img', {
				'class': 'modemtab-ic',
				'src': it.op ? mutil.icon('icons/5gmodem/' + it.op + '.svg')
				             : mutil.icon(it.usb ? 'icons/5gmodem/cusb.svg' : 'icons/5gmodem/cmodem.svg'),
				'width': 16, 'height': 16, 'alt': ''
			}),
			E('span', {}, [ it.label || _('Modem') ])
		]);
	}));
}

function placeBar(el) {
	var tries = 0;
	(function place() {
		if (el.parentNode) { return; }
		var anchor = document.querySelector('#tabmenu')
			|| document.querySelector('ul.cbi-tabmenu')
			|| document.querySelector('.cbi-tabmenu');
		if (anchor && anchor.parentNode) { anchor.parentNode.insertBefore(el, anchor); return; }
		if (tries++ < 20) { window.setTimeout(place, 150); return; }
		var c = document.querySelector('#maincontent') || document.querySelector('#view') || document.body;
		if (c) { c.insertBefore(el, c.firstChild); }
	})();
}

var TABS_CACHE = '5gmodem.modemtabs';

function isUsbStick(m) {
	return (/^12d1:/i).test((m && m.vidpid) || '');
}

function operatorTabIcon(name) {
	var n = String(name || '').toLowerCase();
	if (!n) { return null; }
	if (n.indexOf('ekomobile') >= 0 || n.indexOf('eko mobile') >= 0 || n.indexOf('экомобайл') >= 0 || n.indexOf('эко мобайл') >= 0) { return 'op-ekomobile'; }
	if (n.indexOf('dobrosim') >= 0 || n.indexOf('dobro sim') >= 0 || n.indexOf('dobrosvyaz') >= 0 || n.indexOf('добросим') >= 0 || n.indexOf('добросвязь') >= 0) { return 'op-dobrosim'; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2') { return 'op-t2'; }
	if (/(^|[^0-9a-zа-яё])(t-mobile|tinkoff|t-bank|т-мобайл|т-банк|тинькофф)/.test(n)) { return 'op-tbank'; }
	if (n.indexOf('just esim') >= 0 || n.indexOf('justesim') >= 0 || n.indexOf('just-esim') >= 0) { return 'op-justesim'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	if (n.indexOf('motiv') >= 0 || n.indexOf('мотив') >= 0) { return 'op-motiv'; }
	if (n.indexOf('sber') >= 0 || n.indexOf('сбер') >= 0) { return 'op-sbermobile'; }
	if (n.indexOf('tattelecom') >= 0 || n.indexOf('таттелеком') >= 0 || n.indexOf('летай') >= 0) { return 'op-tattelecom'; }
	if (n.indexOf('rostelecom') >= 0 || n.indexOf('ростелеком') >= 0 ||
	    n.indexOf('rt-mobile') >= 0 || n.indexOf('rtmobile') >= 0 || n.indexOf('рт-мобайл') >= 0 ||
	    n.trim() == 'rtk' || n.trim() == 'ртк' || n.indexOf('rtk ') == 0 || n.indexOf(' rtk') >= 0) { return 'op-rostelecom'; }
	if (n.indexOf('gigsky') >= 0) { return 'op-gigsky'; }
	if (n.indexOf('eskimo') >= 0) { return 'op-eskimo'; }
	return null;
}
function tabIconSrc(m, opIcon) {
	if (!opIcon && m && m.tether) { opIcon = 'op-sim'; }
	if (opIcon) { return mutil.icon('icons/5gmodem/' + opIcon + '.svg'); }
	return mutil.icon(isUsbStick(m) ? 'icons/5gmodem/cusb.svg' : 'icons/5gmodem/cmodem.svg');
}

function tabsCacheSave(modems, active) {
	try {
		var lbl = dedupLabels(modems);
		window.localStorage.setItem(TABS_CACHE, JSON.stringify(modems.map(function(m, i) {
			return { label: lbl[i], active: (m.path === active), usb: isUsbStick(m),
			         op: operatorTabIcon(m.operator) || (m.tether ? 'op-sim' : null) };
		})));
	} catch (e) {}
}

function tabsCacheLoad() {
	try {
		var a = JSON.parse(window.localStorage.getItem(TABS_CACHE) || 'null');
		return (Array.isArray(a) && a.length) ? a : null;
	} catch (e) { return null; }
}

var LIST_CACHE = '/tmp/5gmodem/listmodems.cache';

function pathsSig(list) {
	return list.map(function(m) {
		return [ m.path, m.vidpid || '', m.model || '', m.operator || '' ].join('|');
	}).sort().join(',');
}

function watchModems(bar, sig) {
	if (bar._watched) { return; }
	bar._watched = true;
	poll.add(function() {
		return L.resolveDefault(fs.read(LIST_CACHE), '').then(function(txt) {
			var list = [];
			try { list = JSON.parse(txt || '[]') || []; } catch (e) { return; }
			if (!Array.isArray(list) || !list.length) { return; }

			var now = pathsSig(list);
			if (now === sig) { return; }
			if (bar.querySelector('.modemtab-input')) { return; }
			sig = now;

			return loadModems().then(function(st) {
				var fresh = tabsBar(st.modems, st.active);
				if (bar.firstChild) { bar.replaceChild(fresh, bar.firstChild); }
				else { bar.appendChild(fresh); }
			});
		});
	}, 10);
}

function endRename(tab) {
	if (!tab) { return; }
	if (tab._renameOutside) {
		document.removeEventListener('mousedown', tab._renameOutside, true);
		tab._renameOutside = null;
	}
	tab.querySelectorAll('.modemtab-input, .modemtab-editctl').forEach(function(e) {
		e.parentNode && e.parentNode.removeChild(e);
	});
	var nameEl = tab.querySelector('.modemtab-name');
	var pen = tab.querySelector('.modemtab-edit');
	if (nameEl) { nameEl.style.display = ''; }
	if (pen) { pen.style.display = ''; }
}

function startRename(tab, m, current) {
	if (!tab || tab.querySelector('.modemtab-input')) { return; }
	var bar = tab.parentNode;
	if (bar) {
		bar.querySelectorAll('.modemtab').forEach(function(other) {
			if (other !== tab) { endRename(other); }
		});
	}
	var nameEl = tab.querySelector('.modemtab-name');
	var pen = tab.querySelector('.modemtab-edit');
	if (!nameEl) { return; }
	var inp = E('input', {
		'type': 'text',
		'class': 'modemtab-input',
		'value': (m && m.alias) ? String(m.alias) : String(current || ''),
		'placeholder': current,
		'maxlength': 32,
		'click': function(ev) { ev.stopPropagation(); },
		'keydown': function(ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); save(); }
			if (ev.key === 'Escape') { ev.preventDefault(); endRename(tab); }
		}
	});
	var ok = E('span', { 'class': 'modemtab-edit modemtab-editctl', 'title': _('Save'),
		'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); save(); } }, '✓');
	function save() {
		var v = String(inp.value || '').trim();
		inp.disabled = true;
		L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh',
			[ 'setalias', m.path, v ]), {}).then(function() {
			window.location.reload();
		});
	}
	nameEl.style.display = 'none';
	if (pen) { pen.style.display = 'none'; }
	tab.appendChild(inp);
	tab.appendChild(ok);
	tab._renameOutside = function(ev) {
		if (!tab.contains(ev.target)) { endRename(tab); }
	};
	document.addEventListener('mousedown', tab._renameOutside, true);
	inp.focus();
	inp.select();
}

function switchFailure(res) {
	if (!res || typeof res.code !== 'number') { return _('Could not switch the modem'); }
	var d = {};
	try { d = JSON.parse(String(res.stdout || '').trim() || '{}') || {}; } catch (e) {}
	if (d.error) {
		if (d.error === 'not a modem') { return _('The selected device is not a modem'); }
		if (d.error === 'no path') { return _('No modem selected'); }
		return _('Could not switch the modem') + ': ' + d.error;
	}
	if (res.code !== 0) {
		var t = String(res.stderr || '').trim();
		return _('Could not switch the modem') + (t ? ': ' + t : '');
	}
	return null;
}

function revertTabSwitch(row, prevPath) {
	try {
		if (prevPath) { window.sessionStorage.setItem('5gm-tab', prevPath); }
		else { window.sessionStorage.removeItem('5gm-tab'); }
	} catch (e) {}
	if (!row) { return; }
	row.querySelectorAll('.modemtab').forEach(function(b) {
		b.style.pointerEvents = '';
		if (b.getAttribute('data-path') === prevPath) { b.classList.add('active'); }
		else { b.classList.remove('active'); }
	});
}

function tabsBar(modems, active) {
	tabsCacheSave(modems, active);
	var labels = dedupLabels(modems);
	var tabs = modems.map(function(m, i) {
		var isActive = (m.path === active);
		return E('button', {
			'class': 'btn cbi-button modemtab' + (isActive ? ' active' : ''),
			'data-path': m.path,
			'data-tooltip': (m.vidpid || '') + ' @ ' + (m.path || ''),
			'click': function(ev) {
				var path = ev.currentTarget.getAttribute('data-path');
				var card = ev.currentTarget, row = card.parentNode;
				var curActive = active;
				if (row) {
					var _a = row.querySelector('.modemtab.active');
					if (_a) { curActive = _a.getAttribute('data-path'); }
				}
				if (path === curActive) { return; }
				if (row) {
					row.querySelectorAll('.modemtab.active').forEach(function(b) { b.classList.remove('active'); });
					row.querySelectorAll('.modemtab').forEach(function(b) { b.style.pointerEvents = 'none'; });
				}
				card.classList.add('active');
				try { window.sessionStorage.setItem('5gm-tab', path); } catch (e) {}
				var _inplace = window.__5gmInPlaceSwitch;
				if (typeof _inplace === 'function' && document.getElementById('modemname')) {
					try { _inplace(path); }
					catch (e) { pageLeaveThenReload(); return; }
					if (row) { row.querySelectorAll('.modemtab').forEach(function(b) { b.style.pointerEvents = ''; }); }
					L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]), {})
						.then(function(res) {
							var err = switchFailure(res);
							if (!err) { return; }
							revertTabSwitch(row, curActive);
							if (curActive) { try { _inplace(curActive); } catch (e) {} }
							ui.addNotification(null, E('p', err), 'error');
						});
				} else {
					var guard = window.setTimeout(function() { pageLeaveThenReload(); }, 12000);
					L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]), {})
						.then(function(res) {
							var err = switchFailure(res);
							if (!err) { pageLeaveThenReload(); return; }
							window.clearTimeout(guard);
							revertTabSwitch(row, curActive);
							ui.addNotification(null, E('p', err), 'error');
						});
				}
			}
		}, [
			E('img', {
				'class': 'modemtab-ic',
				'src': tabIconSrc(m, operatorTabIcon(m.operator)),
				'width': 16, 'height': 16, 'alt': '',
				'title': m.operator || ''
			}),
			E('span', { 'class': 'modemtab-name' }, [ labels[i] ]),
			E('span', {
				'class': 'modemtab-edit',
				'title': _('Rename'),
				'click': function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					startRename(ev.currentTarget.parentNode, m, labels[i]);
				}
			}, '✎')
		]);
	});
	return E('div', { 'class': 'modemtabs-bar' }, tabs);
}

var _pageLeaving = false;
function pageLeaveThenReload() {
	if (_pageLeaving) { return; }
	_pageLeaving = true;
	var el = document.getElementById('view') || document.querySelector('.cbi-map, #maincontent');
	if (el) {
		el.classList.add('tgpage-leave');
		window.setTimeout(function() { el.classList.remove('tgpage-leave'); }, 1200);
	}
	window.setTimeout(function() { window.location.reload(); }, el ? 160 : 0);
}

function pageFadeIn() {
	var el = document.getElementById('view') || document.querySelector('.cbi-map, #maincontent');
	if (!el || el.classList.contains('tgpage-in')) { return; }
	el.classList.add('tgpage-in');
	window.setTimeout(function() { el.classList.remove('tgpage-in'); }, 400);
}

return baseclass.extend({
	API: 30906,
	renderBar: function() {
		pageFadeIn();
		return loadModems().then(function(st) {
			return E('div', { 'class': 'modembar' }, [ tabsBar(st.modems, st.active) ]);
		});
	},

	render: function() {
		return loadModems().then(function(st) {
			if (st.modems.length <= 1) { return null; }
			return E('div', { 'class': 'modembar' }, [ tabsBar(st.modems, st.active) ]);
		});
	},

	refreshEsimTab: function() { applyEsimTabVisibility(0); },
	refreshUssdTab: function() { applyUssdTabVisibility(); },
	refreshGateTabs: function() { return applyGateTabs(); },

	attach: function() {
		window.setTimeout(function() {
			applyEsimTabVisibility(0);
			applyUssdTabVisibility();
		}, 1000);
		applyGateTabs();

		var bar = document.querySelector('.modembar');
		if (bar && !bar.classList.contains('modembar-loading')) { return Promise.resolve(); }

		if (!bar) {
			bar = E('div', { 'class': 'modembar modembar-loading' }, [ ghostBar() ]);
			placeBar(bar);
		}

		return loadModems().then(function(st) {
			bar.classList.remove('modembar-loading');
			var fresh = tabsBar(st.modems, st.active);
			if (bar.firstChild) { bar.replaceChild(fresh, bar.firstChild); }
			else { bar.appendChild(fresh); }
			watchModems(bar, pathsSig(st.modems));
		});
	},

	// kept empty for existing callers, see docs/subsystems/ui.md#busy-overlay
	_busyCss: function() {},

	setBusy: function(sel, msg, safetyMs, progressSec) {
		var block = document.querySelector(sel);
		if (!block) { return; }
		this._busyCss();
		var txt = msg || _('The modem is restarting…');
		var ov = document.getElementById('modem-busy-ov');
		var txtCls = progressSec ? '' : 'spinning';
		if (!ov) {
			block.style.position = 'relative';
			ov = E('div', { 'id': 'modem-busy-ov' }, [
				E('span', { 'id': 'modem-busy-txt', 'class': txtCls, 'style': 'font-weight:600;' }, txt)
			]);
			block.appendChild(ov);
		} else {
			ov.style.display = 'flex';
			var sp = ov.querySelector('#modem-busy-txt');
			if (sp) { sp.textContent = txt; sp.className = txtCls; }
		}
		var bar = document.getElementById('modem-busy-bar');
		if (this._busyBarTimer) { window.clearInterval(this._busyBarTimer); this._busyBarTimer = null; }
		if (progressSec) {
			if (!bar) {
				bar = E('div', { 'id': 'modem-busy-bar', 'class': 'cbi-progressbar',
					'title': '', 'style': 'width:70%;max-width:24em;margin-top:10px' }, E('div'));
				ov.appendChild(bar);
			}
			var t0 = Date.now(), inner = bar.firstElementChild;
			if (inner) {
				inner.style.width = '0%';
				this._busyBarTimer = window.setInterval(function() {
					var pc = Math.min(97, Math.round((Date.now() - t0) / (progressSec * 10)));
					inner.style.width = pc + '%';
				}, 500);
			}
		} else if (bar) {
			bar.remove();
		}
		if (this._busyTimer) { window.clearTimeout(this._busyTimer); }
		var self = this;
		this._busyTimer = window.setTimeout(function() { self.clearBusy(); }, safetyMs || 120000);
	},

	clearBusy: function() {
		if (this._busyTimer) { window.clearTimeout(this._busyTimer); this._busyTimer = null; }
		if (this._busyBarTimer) { window.clearInterval(this._busyBarTimer); this._busyBarTimer = null; }
		var ov = document.getElementById('modem-busy-ov');
		if (!ov) { return; }
		var inner = ov.querySelector('#modem-busy-bar > div');
		if (inner) {
			inner.style.width = '100%';
			window.setTimeout(function() { ov.remove(); }, 350);
		} else {
			ov.remove();
		}
	},
});
