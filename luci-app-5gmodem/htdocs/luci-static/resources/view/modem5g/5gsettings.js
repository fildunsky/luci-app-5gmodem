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

// Page styles (tg-set-*): update card in the Network-page layout, tabs over the form sections.
(function() {
	if (document.getElementById('tg-page-settings-css')) { return; }
	document.head.appendChild(E('link', { 'id': 'tg-page-settings-css', 'rel': 'stylesheet', 'type': 'text/css',
		'href': L.resource('view/modem5g/page-settings.css') }));
})();

var ICONS = {
	gear: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M9.15 4.95 L9.71 2.06 L14.29 2.06 L14.85 4.95 L16.68 6.01 L19.46 5.04 L21.75 9.02 L19.53 10.94 L19.53 13.06 L21.75 14.98 L19.46 18.96 L16.68 17.99 L14.85 19.05 L14.29 21.94 L9.71 21.94 L9.15 19.05 L7.32 17.99 L4.54 18.96 L2.25 14.98 L4.47 13.06 L4.47 10.94 L2.25 9.02 L4.54 5.04 L7.32 6.01Z"/><circle cx="12" cy="12" r="3.2"/></g>',
	refresh: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 13a8.5 8.5 0 1 1-2.6-7.2L20.5 8"/><path d="M20.5 3v5h-5"/></g>',
	down: '<path d="M12 3v12M7 10l5 5 5-5M4 20.5h16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>',
	check: '<path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
	spin: '<g fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="8" opacity=".25"/><path d="M20 12a8 8 0 0 0-8-8"/></g>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size) {
	var s = E('span', { 'class': 'tg-set-i' });
	s.innerHTML = svg(name, size);
	return s;
}

// The card is built before it is put in the page: look it up there until then.
var updRoot = null;
function byId(id) {
	return document.getElementById(id) || (updRoot ? updRoot.querySelector('#' + id) : null);
}

// A button that keeps its place and size in every state: all its labels share one grid cell,
// so it is as wide as the longest one, and a state change only swaps which label is visible.
// Plain click handler, not ui.createHandlerFn: that one adds the theme's "spinning" class,
// which widens the button; the button shows its own spinner instead.
function slotBtn(id, labels, onclick) {
	var stack = E('span', { 'class': 'tg-set-stack' });
	Object.keys(labels).forEach(function(k) {
		stack.appendChild(E('span', { 'data-k': k }, [ labels[k] ]));
	});
	return E('button', { 'class': 'cbi-button tg-set-btn', 'id': id, 'type': 'button', 'click': onclick },
		[ icon('refresh', 15), stack ]);
}
function btnState(id, key, ico, o) {
	var b = byId(id);
	if (!b) { return; }
	o = o || {};
	b.querySelectorAll('.tg-set-stack > span').forEach(function(s) {
		var on = s.getAttribute('data-k') === key;
		if (on && o.text) { s.textContent = o.text; }
		s.classList.toggle('on', on);
	});
	b.firstChild.innerHTML = svg(ico, 15);
	b.firstChild.classList.toggle('spin', ico === 'spin');
	b.classList.toggle('cbi-button-action', !!o.primary);
	b.disabled = !!o.busy;
	b.setAttribute('data-k', key);
}

// Status pill of the update card (desktop: right column, phone: in the title row). Always
// shown, so the first state change does not make anything appear.
function updPill(kind, text, spin) {
	[ 'upd-pill', 'upd-pillm' ].forEach(function(id) {
		var p = byId(id);
		if (!p) { return; }
		p.className = 'tg-set-pill ' + (kind || 'off') + (id === 'upd-pillm' ? ' tg-set-pillm' : '');
		p.lastChild.textContent = text || '';
	});
	var ico = byId('upd-ico');
	// the gear turns while something runs: the check and the installation
	if (ico) { ico.classList.toggle('busy', !!spin); }
}

function updSet(id, txt) { var e = byId(id); if (e) { e.textContent = txt; } }
// Text of a one-line slot; the full text also goes to the tooltip, since a long one is cut.
// txt may also be an array of strings and nodes (a line with the version link in it).
function updLine(id, txt) {
	var e = byId(id);
	if (!e) { return; }
	if (Array.isArray(txt)) { dom.content(e, txt); }
	else { e.textContent = txt || ''; }
	e.title = e.textContent;
}
// Release page of a version: the tag page, or the URL the update check returned.
var updRelUrl = {};
function relHref(ver) {
	ver = String(ver || '').replace(/^v/i, '');
	if (!ver || ver === '—') { return REL_LATEST; }
	return updRelUrl[ver] || REL_LATEST.replace(/\/latest$/, '/tag/v' + ver);
}
// A translated "... %s ..." with the version in it as a link to its release page.
function verLine(fmt, ver) {
	var parts = String(fmt).split('%s');
	if (parts.length !== 2) { return fmt.format(ver || '—'); }
	var v = String(ver || '');
	var a = v ? E('a', { 'class': 'tg-set-ver', 'href': relHref(v), 'target': '_blank', 'rel': 'noopener',
		'title': _('Release page') }, [ v ]) : '—';
	return [ parts[0], a, parts[1] ];
}
// The card's two text lines: bold main line and the small line under it.
function updLines(main, sub) {
	updLine('upd-status', main);
	updLine('upd-subt', sub);
}

function updErrText(e, fb, pk) {
	switch (e) {
	case 'world_broken':
		return _('The package manager refuses to install anything: /etc/apk/world lists %s, which apk cannot find (usually a package installed from a file). If that package is no longer installed, delete its line from /etc/apk/world; otherwise install it again from its file. Then try the update again.').format(pk || '?');
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
var REL_LATEST = 'https://github.com/fildunsky/luci-app-5gmodem/releases/latest';
// What the card knows: installed version, the newest release, whether it is newer.
var upd = { cur: '', avail: false };

function updNotesText(t) {
	return String(t || '').replace(/\*\*([^*]+)\*\*/g, '$1').replace(/`([^`]+)`/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1');
}

// Release notes sit at the bottom of the card, under the footer row, so showing them moves
// nothing above.
function renderNotes(b64, ver) {
	var box = byId('upd-notes');
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
	box.appendChild(E('div', { 'class': 'tg-set-lbl' }, [ _('What\'s new in %s').format(ver || '') ]));
	box.appendChild(body);
	box.style.display = '';
}

function updNotesLang() {
	var l = String(document.documentElement.lang || '').toLowerCase().replace('_', '-');
	if (!l) {
		var m = String(document.body.className || '').match(/(?:^|\s)lang_(\S+)/);
		l = m ? m[1].toLowerCase().replace('_', '-') : '';
	}
	if (/^zh-(tw|hk|mo|hant)/.test(l)) { return 'zh_Hant'; }
	if (/^zh/.test(l)) { return 'zh_Hans'; }
	l = l.split('-')[0];
	return [ 'ru', 'id', 'ja', 'vi' ].indexOf(l) >= 0 ? l : '';
}

// Dates and times in the language of the page, not of the browser: ru gives 15.11.2026.
function pageLang() {
	return String(document.documentElement.lang || (L.env && L.env.lang) || '').replace(/_/g, '-') || undefined;
}
function fmtDate(d) {
	try { return d.toLocaleDateString(pageLang(), { day: '2-digit', month: '2-digit', year: 'numeric' }); }
	catch (e) { return d.toLocaleDateString(); }
}
function updDate(s) {
	var d = s ? new Date(s) : null;
	return (d && !isNaN(d.getTime())) ? fmtDate(d) : '';
}
function updTime() {
	var o = { hour: '2-digit', minute: '2-digit' };
	try { return new Date().toLocaleTimeString(pageLang(), o); }
	catch (e) { return new Date().toLocaleTimeString([], o); }
}
// The APN database version is its date (2026.09.21): shown as a date of the page language.
function apnVer(v) {
	var m = String(v || '').match(/^(\d{4})[.-](\d{2})[.-](\d{2})$/);
	return m ? fmtDate(new Date(+m[1], +m[2] - 1, +m[3])) : String(v || '');
}
function installLabel(v) {
	return v ? _('Install %s').format(v) : _('Install update');
}

// Card states. Every state fills the same slots: pill, main line, small line, action button.
// One check covers both the app (update.sh) and the APN database (apn-update.sh); one button
// installs whatever is available, the APN database first (quick, no sign-out), then the app.
var apn = { cur: '', count: 0, ok: false, avail: false, next: '', err: '' };
var UPDBIN = '/usr/share/5gmodem/update.sh';
var APNBIN = '/usr/share/5gmodem/apn-update.sh';

// A translated string with %s placeholders filled with strings or nodes, in order.
function fmtNodes(fmt, args) {
	var parts = String(fmt).split('%s'), out = [];
	parts.forEach(function(p, i) {
		if (p) { out.push(p); }
		if (i < parts.length - 1) { out.push(args[i] == null ? '' : args[i]); }
	});
	return out;
}
function verLink(v) {
	v = String(v || '');
	return v ? E('a', { 'class': 'tg-set-ver', 'href': relHref(v), 'target': '_blank', 'rel': 'noopener',
		'title': _('Release page') }, [ v ]) : '—';
}

function updIdle() {
	updPill('off', _('Not checked'));
	// render first: the installed versions are still on their way
	if (upd.loading) {
		updLines([ E('span', { 'class': 'tg-skel', 'style': 'width:9em' }) ], [ E('span', { 'class': 'tg-skel', 'style': 'width:14em' }) ]);
		btnState('upd-act', 'check', 'refresh');
		return;
	}
	// the APN database date sits next to the version: the card has no separate APN line
	updLines([].concat(verLine(_('Version %s'), upd.cur), apn.cur ? [ ' · ' + _('APN database %s').format(apnVer(apn.cur)) ] : []),
		_('Updates have not been checked yet'));
	btnState('upd-act', 'check', 'refresh');
}

function updCheckFail(err) {
	updProgress(null);
	upd.avail = false;
	// a check that ran out of time (the RPC timeout) means GitHub did not answer either
	if (err === 'Could not reach GitHub' || /timed out/i.test(String(err || '')) || navigator.onLine === false) {
		updPill('bad', _('Offline'));
		updLines(_('GitHub is not reachable'), _('Check the internet connection or pick another interface in "Download through" below.'));
	} else {
		var msg = updErrText(err, _('Could not check for updates'));
		updPill('bad', _('Error'));
		updLines(_('Could not check for updates'), msg);
		if (msg.length > 70) { updDetail(msg); }
	}
	btnState('upd-act', 'retry', 'refresh');
}

function execJson(bin, args, errKey) {
	return fs.exec(bin, args).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}') || {}; } catch (e) {}
		return d;
	}).catch(function(err) {
		var d = {}; d[errKey] = false; d.error = String((err && err.message) || err); return d;
	});
}

function apnErrNote() {
	return _('APN database: could not check') + (apn.err ? ' (' + apn.err + ')' : '');
}

// What the check found, in the card: app and APN database together.
function showChecked(notes) {
	var latest = updTarget;
	if (!upd.ok && !apn.avail) { return updCheckFail(upd.err); }
	var installed = _('Installed: %s').format(upd.cur || '—') + (upd.pub ? ' · ' + _('released %s').format(upd.pub) : '');
	if (upd.avail && apn.avail) {
		updPill('acc', _('Update available'));
		updLines(fmtNodes(_('Available: 5gmodem %s and APN database %s'), [ verLink(latest), apnVer(apn.next) ]), installed);
		btnState('upd-act', 'installall', 'down', { primary: true });
	} else if (upd.avail) {
		updPill('acc', _('Update available'));
		updLines(verLine(_('Version %s is available'), latest), apn.ok ? installed : installed + ' · ' + apnErrNote());
		btnState('upd-act', 'install', 'down', { primary: true, text: installLabel(latest) });
	} else if (apn.avail) {
		updPill('acc', _('Update available'));
		var sub = upd.ok
			? [].concat(verLine(_('Version %s is up to date'), upd.cur), [ ' · ' + _('checked at %s').format(updTime()) ])
			: _('Could not check the app: %s').format(updErrText(upd.err, _('Could not check for updates')));
		updLines(_('APN database %s is available').format(apnVer(apn.next)), sub);
		btnState('upd-act', 'installapn', 'down', { primary: true });
	} else {
		updPill('ok', _('Up to date'));
		updLines(apn.ok ? _('Everything is up to date') : _('You have the latest version'),
			[].concat(verLine(_('Version %s'), upd.cur), [ ' · ' + (apn.ok ? _('APN database %s').format(apnVer(apn.cur)) : apnErrNote())
				+ ' · ' + _('checked at %s').format(updTime()) ]));
		btnState('upd-act', 'again', 'refresh');
	}
	if (upd.avail) { renderNotes(notes, latest); }
}

function checkUpdate() {
	updDetail('');
	renderNotes('');
	updProgress(null);
	upd.avail = false;
	apn.avail = false;
	upd.apnNote = '';
	updPill('acc', _('Checking…'), true);
	updLines(_('Checking for updates…'), _('Asking GitHub for the latest release'));
	btnState('upd-act', 'checking', 'spin', { busy: true });
	return Promise.all([
		execJson(UPDBIN, [ 'check', updNotesLang() ], 'success'),
		execJson(APNBIN, [ 'check' ], 'ok')
	]).then(function(r) {
		var d = r[0], a = r[1];
		if (d.current) { upd.cur = d.current; }
		var latest = String(d.latest || '').replace(/^v/i, '');
		updTarget = latest;
		if (latest && d.release_url) { updRelUrl[latest] = d.release_url; }
		upd.ok = !!d.success;
		upd.err = d.error || '';
		upd.avail = upd.ok && (d.update_available == 1 || d.update_available === true);
		upd.pub = updDate(d.published);
		apn.ok = !!a.ok;
		apn.err = a.ok ? '' : String(a.error || '');
		apn.avail = apn.ok && String(a.update_available) === '1';
		apn.next = String(a.available_version || '');
		apn.nextCount = a.available || 0;
		if (a.current_version) { apn.cur = String(a.current_version); }
		showChecked(d.notes);
	});
}

// The APN database part of an install. Resolves to '' when done, or to the error text.
function apnInstall() {
	updPill('acc', _('Installing'), true);
	updLines(_('Updating the APN database…'), apnText(apn.next, apn.nextCount));
	btnState('upd-act', 'installing', 'spin', { busy: true });
	return execJson(APNBIN, [ 'update' ], 'ok').then(function(d) {
		if (!d.ok) { return String(d.error || _('Failed to update the APN database')); }
		apn.cur = String(d.version || apn.next || '');
		apn.count = d.count || apn.count;
		apn.avail = false;
		return '';
	});
}

function installAll() {
	updDetail('');
	upd.apnNote = '';
	var first = apn.avail ? apnInstall() : Promise.resolve('');
	return first.then(function(apnErr) {
		if (apnErr) { upd.apnNote = _('The APN database was not updated: %s').format(apnErr); }
		if (upd.avail) { return installUpdate(); }
		if (apnErr) {
			updPill('bad', _('Error'));
			updLines(_('Failed to update the APN database'), apnErr);
			btnState('upd-act', 'installapn', 'down', { primary: true });
			return;
		}
		updPill('ok', _('Installed'));
		updLines(_('APN database %s installed').format(apnVer(apn.cur)),
			upd.ok ? verLine(_('Version %s is up to date'), upd.cur)
				: _('Could not check the app: %s').format(updErrText(upd.err, _('Could not check for updates'))));
		btnState('upd-act', 'again', 'refresh');
	});
}

// One action button for the whole flow: what it does depends on the state it shows.
function updAct() {
	var b = byId('upd-act');
	var k = b ? b.getAttribute('data-k') : 'check';
	return (k === 'install' || k === 'installall' || k === 'installapn') ? installAll() : checkUpdate();
}

function updKB(n) { return Math.round((+n || 0) / 1024); }

var updBar = { pos: 0, floor: 0, cap: 0, text: '', timer: null };

function updBarPaint() {
	var fill = byId('upd-fill');
	if (!fill) { return false; }
	fill.style.width = updBar.pos.toFixed(1) + '%';
	updLine('upd-ptext', Math.round(updBar.pos) + '%' + (updBar.text ? ' · ' + updBar.text : ''));
	return true;
}

function updBarStop() {
	if (updBar.timer) { window.clearInterval(updBar.timer); updBar.timer = null; }
}

function updBarTick() {
	if (updBar.pos < updBar.floor) {
		updBar.pos = Math.min(updBar.floor, updBar.pos + Math.max((updBar.floor - updBar.pos) * 0.2, 0.4));
	} else if (updBar.pos < updBar.cap) {
		updBar.pos += (updBar.cap - updBar.pos) * 0.02;
	}
	if (!updBarPaint()) { updBarStop(); }
}

function updBarReset() {
	updBarStop();
	updBar.pos = updBar.floor = updBar.cap = 0;
	updBar.text = '';
}

// The progress bar takes the place of the small line (same slot, same height).
function updProgress(d) {
	var box = byId('upd-sub');
	if (!box) { return; }
	if (!d) { updBarStop(); box.classList.remove('prog'); return; }
	box.classList.add('prog');
	var steps = [
		[ '', 25, _('Unpacking the package…') ],
		[ 'deps', 30, _('Refreshing package lists…') ],
		[ 'services', 35, _('Restarting background services…') ],
		[ 'system', 45, _('Applying system settings…') ],
		[ 'network', 55, _('Reloading network settings…') ],
		[ 'modems', 62, _('Checking modems and ports…') ],
		[ 'protos', 80, _('Registering connection protocols…') ],
		[ 'leds', 84, _('Starting LEDs and antenna control…') ],
		[ 'cache', 90, _('Refreshing the page cache…') ]
	];
	var floor = 2, cap = 5, txt = _('Preparing: reading the release…');
	if (d.stage === 'download' && +d.total > 0) {
		floor = cap = 5 + 20 * Math.min(+d.done || 0, +d.total) / +d.total;
		txt = _('Downloading: %d of %d KB').format(updKB(d.done), updKB(d.total));
	} else if (d.stage === 'download') {
		floor = 5; cap = 24;
		txt = _('Downloading: %d KB').format(updKB(d.done));
	} else if (d.stage === 'install') {
		var i = steps.length - 1;
		while (i > 0 && steps[i][0] !== (d.step || '')) { i--; }
		floor = steps[i][1];
		cap = (i + 1 < steps.length ? steps[i + 1][1] : 95) - 1;
		txt = steps[i][2];
	} else if (d.stage === 'finish') {
		floor = 95; cap = 99;
		txt = _('Finishing: refreshing translations and caches…');
	}
	updBar.floor = Math.max(updBar.floor, floor);
	updBar.cap = Math.max(updBar.cap, cap);
	updBar.text = txt;
	if (!updBar.timer) { updBar.timer = window.setInterval(updBarTick, 200); }
	updBarPaint();
}

// Long explanations and the package manager output, at the bottom of the card.
function updDetail(txt) {
	var e = byId('upd-detail');
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
	'view/modem5g/atexplain.js',
	'view/modem5g/bandsui.js', 'view/modem5g/healthform.js', 'view/modem5g/buttons.js',
	'view/modem5g/align.js', 'view/modem5g/5gstats.js', 'view/modem5g/modem.css',
	'view/modem5g/fresh.js', 'view/modem5g/icons.js', 'view/modem5g/netarrange.js',
	'view/modem5g/mobileview.js', 'view/modem5g/page-buttons.css', 'view/modem5g/page-esim.css',
	'view/modem5g/page-settings.css', 'view/modem5g/sms.js', 'view/modem5g/page-sms.css',
	'view/modem5g/gps.js', 'view/modem5g/page-ussd.css', 'view/modem5g/page-at.css',
	'view/modem5g/page-modem.css', 'view/modem5g/page-align.css', 'view/modem5g/page-stats.css',
	'5gmodem/leaflet.js', '5gmodem/leaflet.css', 'sms-tool-5gm/smssettings.js',
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
	var fill = byId('upd-fill');
	updBarStop();
	updBar.pos = updBar.floor = updBar.cap = 100;
	updBar.text = '';
	updBarPaint();
	if (fill) { fill.classList.add('done'); }
	updDetail('');
	if (ver) { upd.cur = ver; }
	upd.avail = false;
	updProgress(null);
	updPill('ok', _('Installed'));
	updLines(verLine(_('Version %s installed'), upd.cur), _('Refreshing resources…'));
	btnState('upd-act', 'done', 'check', { busy: true });
	refreshResources().then(function() {
		updLine('upd-subt', _('Signing out to apply it…'));
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
		updPill('bad', _('Error'));
		// a long reason goes to the standard notification at the top of the page, not under the
		// card's footer where it was easy to miss
		var long = msg.length > 70;
		updLines(_('Update failed'), long ? '' : msg);
		if (long) { ui.addNotification(null, E('p', [ msg ]), 'warning'); }
		updDetail([ upd.apnNote || '', detail || '' ].filter(function(s) { return s; }).join('\n\n'));
		btnState('upd-act', 'install', 'down', { primary: true, text: installLabel(String(target || updTarget).replace(/^v/i, '')) });
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
				return;
			}
			return failInstall(updErrText(d.error, _('Failed to install the update'), d.pkgs), d.detail, d.target || updTarget);
		});
	}, 1000);
}

function installUpdate() {
	updDetail(upd.apnNote || '');
	updPill('acc', _('Installing'), true);
	updLine('upd-status', updTarget ? _('Installing %s…').format(updTarget) : _('Installing the update…'));
	var fill = byId('upd-fill');
	if (fill) { fill.style.width = '0'; fill.classList.remove('done'); }
	updBarReset();
	updProgress({ stage: 'prepare' });
	btnState('upd-act', 'installing', 'spin', { busy: true });
	return fs.exec(UPDBIN, [ 'install' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.error) {
			return failInstall(updErrText(d.error, _('Failed to install the update')), d.detail, updTarget);
		}
		pollInstall(0, 0);
	}).catch(function() {
		pollInstall(0, 0);
	});
}

// Where updates and the APN database are downloaded from: the default route, or a device the
// owner picks when GitHub is blocked on it (a VPN, a second uplink). Saved at once, no form.
function fetchDevCell() {
	var sid = (uci.sections('5gmodem', '5gmodem')[0] || {})['.name'];
	var cur = sid ? String(uci.get('5gmodem', sid, 'fetch_dev') || '') : '';
	var sel = E('select', { 'class': 'cbi-input-select', 'id': 'upd-dev', 'disabled': true }, [
		E('option', { 'value': '' }, [ _('Automatic (default route)') ])
	]);
	// the explanation is the tooltip; only a missing curl adds a short warning after the list
	sel.title = _('Pick a VPN or another uplink if GitHub is not reachable through the main one. If the download through it fails, the default route is tried.');
	var hint = E('span', { 'class': 'tg-set-hint warn', 'style': 'display:none' }, '');
	if (cur) { sel.appendChild(E('option', { 'value': cur, 'selected': true }, [ cur ])); }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/update.sh', [ 'devs' ]), '{}').then(function(out) {
		var d = {};
		try { d = JSON.parse(out || '{}') || {}; } catch (e) {}
		(d.devs || []).forEach(function(n) {
			if (n === cur) { return; }
			sel.appendChild(E('option', { 'value': n }, [ n + (n === d.default ? ' (' + _('default route') + ')' : '') ]));
		});
		sel.disabled = !sid;
		// the warning replaces the hint instead of adding a line under it
		if (String(d.curl) === '0') {
			hint.textContent = _('Needs the curl package: without it the download always goes through the default route.');
			hint.style.display = '';
		}
	});
	sel.addEventListener('change', function() {
		if (!sid) { return; }
		if (sel.value) { uci.set('5gmodem', sid, 'fetch_dev', sel.value); }
		else { uci.unset('5gmodem', sid, 'fetch_dev'); }
		// committed at once: nothing waits for "Save & Apply", and the header counter is refreshed
		// so it does not suggest otherwise
		uci.save().then(commitPending).then(function() {
			if (ui.changes && ui.changes.init) { return ui.changes.init(); }
		}).then(function() {
			if (hint.style.display === '' && hint.textContent && hint.getAttribute('data-ok') !== '1') { return; }
			hint.setAttribute('data-ok', '1');
			hint.className = 'tg-set-hint';
			hint.textContent = _('Saved');
			hint.style.display = '';
			window.setTimeout(function() { if (hint.getAttribute('data-ok') === '1') { hint.style.display = 'none'; } }, 2500);
		}).catch(function() {});
	});
	return E('div', { 'class': 'tg-set-cell tg-set-inline' }, [
		E('label', { 'class': 'tg-set-lbl', 'for': 'upd-dev' }, _('Download through')),
		sel, hint
	]);
}

function apnText(ver, n) {
	return ver ? (apnVer(ver) + ' · ' + (n || 0) + ' ' + _('operators')) : '—';
}

var ListDropdown = form.RichListValue || form.ListValue;
var EXTIPBIN = '/usr/share/5gmodem/extip.sh';

/* Appearance tab: a small copy of each widget as the Network page draws it (netpri.js), built
   from the same classes with sample data, so the switch shows what it turns on. The copies
   follow the "card background" choice live. */
var ARROW_DOWN = '<svg class="tg-wl-arrow" width="11" height="11" viewBox="0 0 52 52" aria-hidden="true"><path fill="#009955" d="M8.3,14h35.4c1,0,1.7,1.3,0.9,2.2L27.3,37.4c-0.6,0.8-1.9,0.8-2.5,0L7.3,16.2C6.6,15.3,7.2,14,8.3,14z"/></svg>';
var ARROW_UP = '<svg class="tg-wl-arrow" width="11" height="11" viewBox="0 0 52 52" aria-hidden="true"><path fill="#0099ff" d="M43.7,38H8.3c-1,0-1.7-1.3-0.9-2.2l17.3-21.2c0.6-0.8,1.9-0.8,2.5,0l17.5,21.2C45.4,36.7,44.8,38,43.7,38z"/></svg>';
var YT_SVG = '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="2" y="4.5" width="20" height="15" rx="4.2" fill="#FF0000"/><path d="M10 8.5l6 3.5-6 3.5z" fill="#fff"/></svg>';
var CLASH_SVG = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M6 7.5c0 3 2.5 4.5 6 4.5s6 1.5 6 4.5M18 16.5c0-3-2.5-4.5-6-4.5S6 10.5 6 7.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' +
	[ '6" cy="7.5', '18" cy="7.5', '6" cy="16.5', '18" cy="16.5' ].map(function(c) {
		return '<circle cx="' + c + '" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>';
	}).join('') + '</svg>';

function pvHtml(cls, html) { var s = E('span', { 'class': cls }); s.innerHTML = html; return s; }
function pvImg(name, cls) {
	return E('img', { 'class': cls || 'netpri-ic', 'src': mutil.icon('icons/5gmodem/' + name), 'width': 16, 'height': 16, 'alt': '' });
}
function pvCard(cls, kids) {
	return E('span', { 'class': 'btn cbi-button netpri-btn ' + cls, 'aria-hidden': 'true' }, kids);
}
// the big translucent mark of netpri.js: a number on uplink cards, the icon on every card
function pvRank(rank, n, icoNode, isUplink, img) {
	if (rank === 'num' && isUplink) { return E('span', { 'class': 'netpri-rank' }, String(n)); }
	if (rank !== 'icon') { return ''; }
	if (isUplink) { return pvImg(img, 'netpri-rank netpri-rank-ic'); }
	return E('span', { 'class': 'netpri-rank netpri-rank-bg' }, [ icoNode.cloneNode(true) ]);
}
function pvDot(cls) { return E('span', { 'class': 'netpri-svcdot ' + (cls || 'on') }); }

/* Sample state of the previews. animTick() moves it along (see the animator in render());
   with reduced motion it stays as it is here. */
var PV = {
	first: 'wan',                                   // the active uplink, drawn first
	ping: { yt: { ms: 42 }, tg: { ms: 61 } },
	ssc: 'on',                                      // on | restarting
	zap: 'on',                                      // on | off
	st: { phase: 'done', p: 0, down: 48.2, up: 12.6, live: 0, wait: false }
};

function pvUplink(which, n, rank) {
	var wan = (which === 'wan');
	return pvCard(PV.first === which ? 'active' : '', [ pvRank(rank, n, null, true, wan ? 'cwan.svg' : 'cwifi.svg'),
		E('span', { 'class': 'netpri-sub' }, wan ? 'wan' : 'wwan'),
		E('span', { 'class': 'netpri-name' }, [ pvImg(wan ? 'cwan.svg' : 'cwifi.svg'), E('span', {}, wan ? 'WAN' : 'Wi-Fi') ]),
		E('span', { 'class': 'netpri-ip' }, [ pvDot(), wan ? '198.51.100.7' : '192.168.0.20' ]) ]);
}
function pvPing(key, rank) {
	var s = PV.ping[key];
	var ico = (key === 'yt') ? pvHtml('netpri-pingico', YT_SVG)
		: E('span', { 'class': 'netpri-pingico' }, [ E('img', { 'src': mutil.icon('icons/5gmodem/tg.svg'),
			'width': 16, 'height': 16, 'alt': '', 'style': 'display:block;border-radius:4px' }) ]);
	return pvCard('netpri-status' + (s.busy ? ' ping-busy' : ''), [ pvRank(rank, 0, ico),
		E('span', { 'class': 'netpri-sub' }, _('Status')),
		E('span', { 'class': 'netpri-name' }, [ pvDot('on' + (s.flash ? ' ping-flash' : '')), ico,
			E('span', {}, key === 'yt' ? 'YouTube' : 'Telegram') ]),
		E('span', { 'class': 'netpri-ip' }, s.ms + ' ' + _('ms')) ]);
}
function pvSsclash(rank) {
	var ic = pvHtml('netpri-ssclash-ic', CLASH_SVG);
	var dot = pvDot('on');
	if (PV.ssc === 'restarting') {
		// sscPaintDot() in netpri.js: an amber breathing dot while the service restarts
		dot.style.background = '#d29922';
		dot.style.boxShadow = '0 0 5px 1px rgba(210,153,34,.85)';
		dot.style.animation = 'dot-breathe 1.1s ease-in-out infinite';
	}
	return pvCard('netpri-ssclash', [ pvRank(rank, 0, ic),
		E('span', { 'class': 'netpri-sub' }, 'v3.0.2'),
		E('span', { 'class': 'netpri-name' }, [ dot, ic, E('span', {}, 'SSClash') ]),
		E('span', { 'class': 'netpri-ip' }, PV.ssc === 'restarting' ? _('Restarting…') : 'config.yaml') ]);
}
function pvZapret(rank) {
	var zp = E('span', { 'class': 'netpri-pingbadge custom' }, '☢️');
	var on = (PV.zap === 'on');
	return pvCard('netpri-status', [ pvRank(rank, 0, zp),
		E('span', { 'class': 'netpri-sub' }, _('Service')),
		E('span', { 'class': 'netpri-name' }, [ pvDot(on ? 'on' : 'off'), zp, E('span', {}, 'Zapret') ]),
		E('span', { 'class': 'netpri-ip' }, on ? _('running') : _('stopped')) ]);
}
// the speed-test card is built once and then updated in place (stApply), so its progress
// fill keeps its transition the way the real card does
function pvSpeed() {
	var num = function(cls, ico, dir) {
		return E('span', { 'style': 'display:inline-flex;align-items:center;gap:.15em' }, [
			E('span', { 'class': 'netpri-st-num ' + cls }), pvImg(ico, 'netpri-st-arrow ' + dir) ]);
	};
	var card = pvCard('netpri-st', [
		E('span', { 'class': 'netpri-sub' }, _('Internetometer')),
		E('span', { 'class': 'netpri-name netpri-st-speed' }, [ num('tg-pv-dl', 'cdown.svg', 'st-arrow-dl'),
			E('span', { 'style': 'opacity:.4;margin:0 .35em' }, '|'), num('tg-pv-ul', 'cup.svg', 'st-arrow-ul'),
			E('span', { 'class': 'netpri-st-unit' }, _('Mbps')) ]),
		E('span', { 'class': 'netpri-ip' }, '203.0.113.10') ]);
	stApply(card);
	return card;
}
function stApply(card) {
	var s = PV.st, dl = card.querySelector('.tg-pv-dl'), ul = card.querySelector('.tg-pv-ul');
	var run = (s.phase === 'dl' || s.phase === 'ul');
	card.classList.toggle('st-dl', s.phase === 'dl');
	card.classList.toggle('st-ul', s.phase === 'ul');
	card.classList.toggle('st-wait', run && s.wait);
	if (run && !s.wait) { card.style.setProperty('--st-p', s.p.toFixed(1) + '%'); }
	else { card.style.removeProperty('--st-p'); }
	var put = function(el, v, dim) { el.textContent = (v != null ? v : 0).toFixed(1); el.classList.toggle('dim', !!dim); };
	if (s.phase === 'dl') { put(dl, s.live, false); put(ul, null, true); }
	else if (s.phase === 'ul') { put(dl, s.down, false); put(ul, s.live, false); }
	else { put(dl, s.down, false); put(ul, s.up, false); }
}

function widgetPreview(kind, rank) {
	var cards;
	if (kind === 'netpri') {
		cards = (PV.first === 'wan') ? [ pvUplink('wan', 1, rank), pvUplink('wifi', 2, rank) ]
			: [ pvUplink('wifi', 1, rank), pvUplink('wan', 2, rank) ];
	} else if (kind === 'status') {
		cards = [ pvPing('yt', rank), pvPing('tg', rank) ];
	} else if (kind === 'services') {
		cards = [ pvSsclash(rank), pvZapret(rank) ];
	} else {
		cards = [ pvSpeed() ];
	}
	return E('div', { 'class': 'netpri-row' }, cards);
}

/* One step of the fake activity, every 250 ms. Returns the preview kinds to redraw;
   the speed test is updated in place. Period: ping 3 s per host, services 16 s, uplinks
   18 s, speed test 12 s (download 3.5 s, upload 3 s, then the result). */
var ANIM_MS = 250;
function animTick(t) {
	var dirty = {};
	var sec = t * ANIM_MS / 1000;
	// ping: each host in turn, a short "busy" breath, then a new value with a flash
	[ [ 'yt', 0, 38, 14 ], [ 'tg', 1.5, 55, 25 ] ].forEach(function(h) {
		var s = PV.ping[h[0]], ph = (sec + 3 - h[1]) % 3;
		var busy = ph < 0.75, flash = ph >= 0.75 && ph < 1.0;
		if (busy !== !!s.busy || flash !== !!s.flash) {
			if (s.busy && !busy) { s.ms = Math.round(h[2] + Math.random() * h[3]); }
			s.busy = busy; s.flash = flash; dirty.status = true;
		}
	});
	var sv = sec % 16;
	var ssc = (sv >= 6 && sv < 9) ? 'restarting' : 'on';
	var zap = (sv >= 12 && sv < 13.5) ? 'off' : 'on';
	if (ssc !== PV.ssc || zap !== PV.zap) { PV.ssc = ssc; PV.zap = zap; dirty.services = true; }
	var first = (sec % 36 < 18) ? 'wan' : 'wifi';
	if (first !== PV.first) { PV.first = first; dirty.netpri = true; }
	var c = sec % 12, s = PV.st;
	if (c < 3.5) {
		if (s.phase !== 'dl') { s.phase = 'dl'; s.target = 40 + Math.random() * 50; s.tUp = 8 + Math.random() * 18; s.live = 0; }
		s.wait = c < 0.5;
		s.p = Math.min(100, Math.max(0, (c - 0.5) / 3 * 100));
		if (!s.wait) { s.live = s.target * (1 - Math.exp(-(c - 0.5) * 1.6)) * (0.97 + Math.random() * 0.06); }
	} else if (c < 6.5) {
		if (s.phase !== 'ul') { s.phase = 'ul'; s.down = +s.target.toFixed(1); s.live = 0; }
		s.wait = false;
		s.p = Math.min(100, (c - 3.5) / 3 * 100);
		s.live = s.tUp * (1 - Math.exp(-(c - 3.5) * 1.8)) * (0.96 + Math.random() * 0.08);
	} else if (s.phase !== 'done') {
		s.phase = 'done'; s.up = +s.tUp.toFixed(1); s.wait = false;
	}
	return dirty;
}
function uiIsDark() {
	var m = String(getComputedStyle(document.body).color).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	return !!m && (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

/* Ping and service cards: a compact list editor over the pingwidget / svcwidget sections.
   The rows are the source of truth; sync() writes them into uci right before a save, so an
   edit made while a save is running is picked up by the next one. New rows get their
   section name after the save, in order. */
var PING_HOSTS = [
	[ 'youtube.com', 'YouTube' ], [ 'api.telegram.org', 'Telegram' ], [ 'github.com', 'GitHub' ],
	[ 'google.com', 'Google' ], [ 'cloudflare.com', 'Cloudflare' ], [ 'yandex.ru', 'Yandex' ]
];
var SVC_NICE = { zapret: 'Zapret', zerotier: 'ZeroTier', nikki: 'Nikki', ssclash: 'SSClash', clash: 'SSClash (4.7)' };

function pingIcon(host) {
	host = String(host || '').trim().toLowerCase();
	if (host === 'youtube.com') { return pvHtml('tg-wl-ico', YT_SVG); }
	if (host === 'api.telegram.org') { return E('span', { 'class': 'tg-wl-ico' }, [ pvImg('tg.svg') ]); }
	if (host === 'github.com') { return E('span', { 'class': 'tg-wl-ico tg-wl-badge', 'style': 'background:#1b1f23' }, [ pvImg('github.svg', 'tg-wl-sm') ]); }
	var g = { 'google.com': [ '#4285F4', 'G' ], 'cloudflare.com': [ '#F38020', '☁' ], 'yandex.ru': [ '#FF3B30', 'Я' ] }[host];
	if (g) { return E('span', { 'class': 'tg-wl-ico tg-wl-badge', 'style': 'background:' + g[0] }, g[1]); }
	return E('span', { 'class': 'tg-wl-ico tg-wl-glyph' }, '⚡');
}
// host field of a ping row: free input plus a menu of the preset hosts with their icons
var _wlMenu = null;
function wlCloseMenu() {
	if (!_wlMenu) { return; }
	_wlMenu.hidden = true;
	if (_wlMenu.parentNode) { _wlMenu.parentNode.classList.remove('open'); }
	_wlMenu = null;
}
document.addEventListener('pointerdown', function(ev) {
	if (_wlMenu && !(_wlMenu.parentNode && _wlMenu.parentNode.contains(ev.target))) { wlCloseMenu(); }
});
document.addEventListener('keydown', function(ev) { if (ev.key === 'Escape') { wlCloseMenu(); } });
// the first fully opaque background up the tree (theme cards are often translucent)
function solidBg(el) {
	for (var n = el; n && n.nodeType === 1; n = n.parentNode) {
		var c = getComputedStyle(n).backgroundColor, m = String(c).match(/rgba?\(([^)]+)\)/);
		if (m) {
			var p = m[1].split(/[,\s/]+/).filter(Boolean);
			if (p.length < 4 || +p[3] >= 1) { return c; }
		}
	}
	return uiIsDark() ? '#1f2328' : '#ffffff';
}
function hostCombo(input, onPick) {
	var tip = _('Pick a preset or type any host / domain');
	var opts = PING_HOSTS.map(function(h) {
		return E('button', { 'type': 'button', 'class': 'tg-wl-opt', 'role': 'option', 'data-host': h[0],
			'click': function() {
				input.value = h[0];
				wlCloseMenu();
				onPick();
			} }, [ pingIcon(h[0]), E('span', { 'class': 'tg-wl-optn' }, h[1]), E('span', { 'class': 'tg-wl-opth' }, h[0]) ]);
	});
	var menu = E('div', { 'class': 'tg-wl-menu', 'role': 'listbox', 'aria-label': tip }, opts);
	menu.hidden = true;
	var wrap;
	var open = function() {
		wlCloseMenu();
		var cur = String(input.value || '').trim().toLowerCase();
		opts.forEach(function(o) { o.classList.toggle('sel', o.getAttribute('data-host') === cur); });
		menu.style.background = solidBg(wrap);
		menu.hidden = false;
		wrap.classList.add('open');
		_wlMenu = menu;
	};
	var btn = E('button', { 'type': 'button', 'class': 'cbi-button tg-wl-pick', 'title': tip, 'aria-label': tip,
		'aria-haspopup': 'listbox', 'click': function() { if (_wlMenu === menu) { wlCloseMenu(); } else { open(); } } });
	btn.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path d="M7 10l5 5 5-5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
	// an empty field offers the presets as soon as it gets the focus
	input.addEventListener('focus', function() { if (!String(input.value || '').trim()) { open(); } });
	input.addEventListener('input', function() { if (_wlMenu === menu) { wlCloseMenu(); } });
	wrap = E('div', { 'class': 'tg-wl-combo' }, [ input, btn, menu ]);
	wrap.open = open;
	return wrap;
}
function svcIconEl(svc) {
	if (svc === 'zapret') { return E('span', { 'class': 'tg-wl-ico tg-wl-glyph' }, '☢️'); }
	if (svc === 'zerotier') { return E('span', { 'class': 'tg-wl-ico' }, [ pvImg('zt.png') ]); }
	if (svc === 'ssclash' || svc === 'clash' || svc === 'nikki') { return pvHtml('tg-wl-ico tg-wl-clash', CLASH_SVG); }
	return E('span', { 'class': 'tg-wl-ico tg-wl-glyph' }, '🔧');
}
function wlRemoveBtn(onclick) {
	var b = E('button', { 'type': 'button', 'class': 'cbi-button tg-wl-rm', 'title': _('Remove'), 'aria-label': _('Remove'), 'click': onclick });
	b.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
	return b;
}
function wlAddBtn(label, tip, onclick) {
	var b = E('button', { 'type': 'button', 'class': 'cbi-button tg-wl-add', 'title': tip, 'click': onclick });
	b.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" aria-hidden="true"><path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
	b.appendChild(E('span', {}, label));
	return b;
}
function wlSelect(opts, val, label) {
	var s = E('select', { 'class': 'cbi-input-select tg-wl-sel', 'aria-label': label });
	opts.forEach(function(o) { s.appendChild(E('option', { 'value': o[0] }, o[1])); });
	s.value = val;
	return s;
}

// One list: cfg = { type, values(row) -> {k: v} or null (row not ready), build(row, data) }
function wlList(cfg, persist) {
	var L = { rows: [], removed: [], created: [], node: E('div', { 'class': 'tg-wl-rows' }) };
	L.addRow = function(sid, data, focus) {
		var row = { sid: sid, pending: null };
		row.el = E('div', { 'class': 'tg-wl-row' });
		cfg.build(row, data || {});
		row.el.appendChild(wlRemoveBtn(function() {
			if (row.sid) { L.removed.push(row.sid); }
			if (row.pending) { row.dead = true; }
			L.rows.splice(L.rows.indexOf(row), 1);
			row.el.parentNode.removeChild(row.el);
			persist();
		}));
		L.rows.push(row);
		L.node.appendChild(row.el);
		if (focus && row.focus) { row.focus.focus(); }
		return row;
	};
	L.sync = function() {
		var have = {};
		(uci.sections('5gmodem', cfg.type) || []).forEach(function(s) { have[s['.name']] = s; });
		L.removed.forEach(function(sid) { if (have[sid]) { uci.remove('5gmodem', sid); } });
		L.removed = [];
		L.rows.forEach(function(r) {
			var v = cfg.values(r);
			if (!v) {
				if (r.sid && have[r.sid]) { uci.remove('5gmodem', r.sid); }
				r.sid = null;
				return;
			}
			if (r.sid && have[r.sid]) {
				Object.keys(v).forEach(function(k) {
					if (String(have[r.sid][k] == null ? '' : have[r.sid][k]) !== v[k]) { uci.set('5gmodem', r.sid, k, v[k]); }
				});
			} else if (!r.sid && !r.pending) {
				var nsid = uci.add('5gmodem', cfg.type);
				Object.keys(v).forEach(function(k) { uci.set('5gmodem', nsid, k, v[k]); });
				r.pending = true;
				L.created.push(r);
			}
		});
	};
	// after the save: rows that were created get the new section names, in creation order
	// (new sections come last); a row removed while its save ran is removed now. True when
	// that needs one more save.
	L.claim = function() {
		var used = {}, again = false;
		L.rows.forEach(function(r) { if (r.sid) { used[r.sid] = true; } });
		var free = (uci.sections('5gmodem', cfg.type) || []).map(function(s) { return s['.name']; })
			.filter(function(n) { return !used[n] && L.removed.indexOf(n) < 0; });
		L.created.forEach(function(r) {
			r.sid = free.shift() || null;
			r.pending = null;
			if (r.dead && r.sid) { L.removed.push(r.sid); again = true; }
		});
		L.created = [];
		return again;
	};
	(uci.sections('5gmodem', cfg.type) || []).forEach(function(s) { L.addRow(s['.name'], s); });
	return L;
}

return view.extend({
	load: function() {
		var self = this, args = arguments;
		return fresh.check(40008, [ extip, healthform, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		// render first: only the settings are waited for; the installed versions, the service list,
		// the USB device list and the web server setting fill the drawn page (lateData in render)
		return L.resolveDefault(uci.load('5gmodem'));
	},

	render: function(res) {
		modemtabs.attach();
		// filled after render (lateData): until then the lists show what the config already names
		var services = [];

		// Update card in the Network-page layout: icon, three fixed lines (caption / state / detail)
		// with the one action button under them, the pill on the right; release notes under the
		// status; "download through" and the APN database version in the foot row; long errors
		// at the very bottom. Every state fills the same
		// slots, so nothing moves while checking or installing.
		upd.loading = true;
		Promise.all([ L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/update.sh', [ 'version' ]), '{}'),
		              L.resolveDefault(fs.exec_direct(APNBIN, [ 'version' ]), '{}') ]).then(function(v) {
			var verOut = {}, apnOut = {};
			try { verOut = JSON.parse(v[0] || '{}') || {}; } catch (e) {}
			try { apnOut = JSON.parse(v[1] || '{}') || {}; } catch (e) {}
			upd.loading = false;
			// a check or an install started meanwhile owns the card and its versions
			var b = byId('upd-act');
			var idle = !b || (b.getAttribute('data-k') || 'check') === 'check';
			if (!upd.cur) { upd.cur = String(verOut.current || ''); }
			if (!apn.cur) { apn.cur = String(apnOut.version || ''); apn.count = apnOut.count || 0; }
			if (idle) { updIdle(); }
		});
		// the gear turns inside its own fixed square, so it spins around its centre
		var updGear = E('span', { 'class': 'tg-set-gear' });
		updGear.innerHTML = svg('gear', 36);
		var updIco = E('div', { 'class': 'tginfo-signal tg-set-ico', 'id': 'upd-ico' }, [ updGear ]);
		var pill = function(id) {
			return E('span', { 'id': id, 'class': 'tg-set-pill off' + (id === 'upd-pillm' ? ' tg-set-pillm' : '') },
				[ E('i'), E('span', {}, '') ]);
		};
		var updBtn = slotBtn('upd-act', {
			check: _('Check for updates'), checking: _('Checking…'), again: _('Check again'),
			retry: _('Try again'), install: installLabel('3.10.100'), installall: _('Install updates'),
			installapn: _('Update the APN database'), installing: _('Installing…'), done: _('Installed')
		}, function() { updAct(); });
		var updateBlock = E('div', { 'class': 'cbi-section tg-pg-head tg-set-head', 'id': 'upd-card' }, [
			E('h3', { 'class': 'tg-pg-title tg-set-title' }, [
				E('span', {}, _('Settings')),
				pill('upd-pillm')
			]),
			E('div', { 'class': 'tginfo-general' }, [
				updIco,
				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'class': 'tginfo-reg' }, _('Updates of the app and the APN database')),
					E('div', { 'class': 'tginfo-op tg-set-main', 'id': 'upd-status' }, []),
					E('div', { 'class': 'tginfo-loc tg-set-sub', 'id': 'upd-sub' }, [
						E('span', { 'class': 'tg-set-subt', 'id': 'upd-subt' }, []),
						E('span', { 'class': 'tg-set-prog' }, [
							E('span', { 'class': 'tg-updprog' }, [ E('span', { 'id': 'upd-fill', 'class': 'tg-updfill' }) ]),
							E('span', { 'id': 'upd-ptext', 'class': 'tg-set-pt' }, [])
						])
					]),
					// the one action button, under the status lines: fixed rows above it, so it
					// never moves, and away from the pill so the two do not merge
					E('div', { 'class': 'tg-set-act' }, [ updBtn ])
				]),
				E('div', { 'class': 'tginfo-right' }, [
					pill('upd-pill')
				])
			]),
			// release notes right under the status, above the foot row; they only add below
			E('div', { 'id': 'upd-notes', 'class': 'tg-set-notes', 'style': 'display:none' }, []),
			E('div', { 'class': 'tg-set-foot' }, [
				// the APN database version is in the status lines above, so it has no cell of its own
				fetchDevCell()
			]),
			E('pre', { 'id': 'upd-detail', 'class': 'tg-set-detail', 'style': 'display:none' }, [])
		]);
		updRoot = updateBlock;
		updIdle();

		var m = new form.Map('5gmodem');
		var o;

		// Options that show or hide menu tabs, compared by their effective value: an option
		// absent from the config counts as its default, the way modemtabs.applyGateTabs()
		// reads it. Comparing raw strings made the first autosave on a config without
		// "netonly" (the form writes the default '0') look like a netonly change.
		var _gateDef = { align_enabled: '0', show_stats: '1', netonly: '0', show_gps: '1' };
		var _gateOpts = Object.keys(_gateDef);
		var _gateWas = {};
		function sid0() {
			var ss = uci.sections('5gmodem', '5gmodem');
			return (ss && ss[0]) ? ss[0]['.name'] : '';
		}
		function _gateVal(k) {
			var v = String(uci.get('5gmodem', sid0(), k) || '');
			return (v === '0' || v === '1') ? v : _gateDef[k];
		}
		_gateOpts.forEach(function(k) { _gateWas[k] = _gateVal(k); });
		function _gateChanged() {
			return _gateOpts.some(function(k) { return _gateVal(k) !== _gateWas[k]; });
		}
		// Menu tabs follow the gate options in place, without reloading the page; the
		// "Internet priorities only" switch also needs the backend part (netonly.sh, menu cache).
		function _gateAfterAutosave() {
			if (!_gateChanged()) { return; }
			var noWas = _gateWas.netonly;
			_gateOpts.forEach(function(k) { _gateWas[k] = _gateVal(k); });
			modemtabs.refreshGateTabs();
			if (_gateWas.netonly !== noWas) {
				return L.resolveDefault(fs.exec('/usr/share/5gmodem/setopt.sh', [ 'applyset' ]), null);
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

		o = disp.option(form.Flag, 'show_stats', _('Collect statistics'),
			_('Collects uplink latency, signal, temperature and monthly traffic, and shows the "Statistics" tab with the charts. Series live in RAM; monthly traffic can be kept across reboots on the tab itself.'));
		o.default = '1';
		o.rmempty = false;

		// the rest of the GPS settings (clock, Traccar, NMEA port) sits on the GPS tab itself
		o = disp.option(form.Flag, 'show_gps', _('GPS tab'),
			_('The "GPS" tab: position from the GNSS receiver of the modem and a map. It appears only for a modem with a receiver the app knows how to read.'));
		o.default = '1';
		o.rmempty = false;
		o.depends({ netonly: '1', '!reverse': true });

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

		var _saveQ = Promise.resolve();
		var wdg = m.section(form.TypedSection, '5gmodem', _('Appearance'),
			_('Cards in the widgets row on the Network page. All are on by default.'));
		wdg.anonymous = true;

		// one save at a time: the form autosave and the card lists both end in uci.save(),
		// which reloads the config and would drop changes staged by the other one meanwhile
		function queueSave(fn) {
			_saveQ = _saveQ.then(fn).catch(function() {});
			return _saveQ;
		}

		// the four widget switches as tiles, each with a copy of its widget
		var wFlags = {}, rankOpt = null;
		function curRank() {
			var v = rankOpt ? rankOpt.formvalue(sid0()) : null;
			if (v == null) { v = uci.get('5gmodem', sid0(), 'netpri_rank'); }
			return (v === '1') ? 'num' : (v === 'icon') ? 'icon' : '';
		}
		function refreshPreviews() {
			var rank = curRank(), dark = uiIsDark();
			document.querySelectorAll('.tg-wprev').forEach(function(pv) {
				var kind = pv.getAttribute('data-wprev');
				pv.classList.toggle('netpri-dark', dark);
				dom.content(pv, widgetPreview(kind, rank));
				var f = wFlags[kind], v = f ? f.formvalue(sid0()) : null;
				var tile = pv.closest('.cbi-value');
				if (tile && v != null) { tile.classList.toggle('tg-wtile-off', v !== '1'); }
			});
		}
		// the previews live: a fake ping, service restarts and speed test (animTick), only
		// while the Appearance tab is on screen; the timer ends with the page
		var anim = { timer: null, t: 0, root: null };
		var reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
		function animShown() {
			if (document.hidden || !anim.root || !anim.root.isConnected) { return false; }
			var sec = anim.root.querySelector('[data-tgset="look"]');
			return !!sec && sec.style.display !== 'none';
		}
		function animStop() {
			if (anim.timer) { window.clearTimeout(anim.timer); }
			anim.timer = null;
			document.removeEventListener('visibilitychange', animKick);
		}
		function animStep() {
			anim.timer = null;
			if (!anim.root || !anim.root.isConnected) { animStop(); return; }
			if (!animShown()) { return; }
			var dirty = animTick(++anim.t), rank = curRank();
			anim.root.querySelectorAll('.tg-wprev').forEach(function(pv) {
				var kind = pv.getAttribute('data-wprev');
				if (kind === 'speedtest') {
					var c = pv.querySelector('.netpri-st');
					if (c) { stApply(c); }
				} else if (dirty[kind]) {
					dom.content(pv, widgetPreview(kind, rank));
				}
			});
			anim.timer = window.setTimeout(animStep, ANIM_MS);
		}
		function animKick() {
			if (anim.root && !anim.root.isConnected) { animStop(); return; }
			if (reduceMotion || anim.timer || !animShown()) { return; }
			anim.timer = window.setTimeout(animStep, ANIM_MS);
		}
		document.addEventListener('visibilitychange', animKick);

		function tileFlag(name, kind, title, tip) {
			var opt = wdg.option(form.Flag, name, title);
			opt.default = '1';
			opt.rmempty = false;
			wFlags[kind] = opt;
			var orig = opt.renderWidget;
			opt.renderWidget = function(section_id) {
				var w = orig.apply(this, arguments);
				var pv = E('div', { 'class': 'netpribar tg-wprev', 'data-wprev': kind, 'title': tip,
					'click': function(ev) {
						var cb = ev.currentTarget.parentNode.querySelector('input[type="checkbox"]');
						if (cb) { cb.click(); }
					} }, [ widgetPreview(kind, curRank()) ]);
				if ((uci.get('5gmodem', section_id, name) || '1') === '0') {
					window.requestAnimationFrame(function() {
						var t = pv.closest('.cbi-value');
						if (t) { t.classList.add('tg-wtile-off'); }
					});
				}
				var frag = document.createDocumentFragment();
				frag.appendChild(w);
				frag.appendChild(pv);
				return frag;
			};
			return opt;
		}
		tileFlag('widget_netpri', 'netpri', _('Internet priority'), _('Uplink switch — modems / Wi-Fi / WAN'));
		tileFlag('widget_status', 'status', _('Ping monitor'), _('Ping cards (host with a green/red dot and latency)'));
		tileFlag('widget_services', 'services', _('Service monitor'), _('Service status cards (running/stopped)'));
		tileFlag('widget_speedtest', 'speedtest', _('Speed test'), _('Speed-test card'));

		o = wdg.option(ListDropdown, 'netpri_rank', _('Card background'));
		o.value('0', _('None'));
		o.value('1', _('Priority number'));
		o.value('icon', _('Icons'));
		o.default = '0';
		o.rmempty = false;
		o.depends('widget_netpri', '1');
		rankOpt = o;

		// ping and service cards: rows with inline edit and remove, an add button under them
		var wLists = [], _wlT = null;
		function wlPersist() {
			if (_wlT) { window.clearTimeout(_wlT); }
			_wlT = window.setTimeout(function() {
				_wlT = null;
				queueSave(function() {
					wLists.forEach(function(l) { l.sync(); });
					return uci.save().then(function() {
						var again = false;
						wLists.forEach(function(l) { if (l.claim()) { again = true; } });
						if (again) { wlPersist(); }
						return applyOwn();
					}, function(e) {
						wLists.forEach(function(l) {
							l.created.forEach(function(r) { r.pending = null; });
							l.created = [];
						});
						ui.addNotification(null, E('p', [ String((e && e.message) || e) ]), 'error');
					});
				});
			}, 300);
		}
		function wlOption(name, title, makeList) {
			var opt = wdg.option(form.DummyValue, name, title);
			opt.cfgvalue = function() { return ''; };
			opt.renderWidget = function() {
				var l = makeList();
				// the map re-renders on a heavy save: the fresh list replaces the old one
				wLists = wLists.filter(function(x) { return x.type !== l.type; });
				wLists.push(l);
				return l.box;
			};
			return opt;
		}

		var pingModes = [ [ 'click', _('On click only') ], [ '10', _('Every 10 s') ],
			[ '30', _('Every 30 s') ], [ '60', _('Every 60 s') ] ];
		o = wlOption('_pinglist', _('Ping monitor'), function() {
			var l = wlList({
				type: 'pingwidget',
				values: function(r) {
					var h = String(r.host.value || '').trim();
					return h ? { host: h, mode: r.mode.value } : null;
				},
				build: function(r, d) {
					r.host = E('input', { 'type': 'text', 'class': 'cbi-input-text tg-wl-host', 'autocomplete': 'off',
						'value': d.host || '', 'placeholder': _('Host or IP address'), 'aria-label': _('Host'),
						'spellcheck': 'false', 'autocapitalize': 'off' });
					r.mode = wlSelect(pingModes, d.mode || 'click', _('Ping mode'));
					var ico = E('span', { 'class': 'tg-wl-icobox' }, [ pingIcon(d.host) ]);
					r.host.addEventListener('input', function() { dom.content(ico, pingIcon(r.host.value)); });
					r.host.addEventListener('change', wlPersist);
					r.mode.addEventListener('change', wlPersist);
					var combo = hostCombo(r.host, function() {
						dom.content(ico, pingIcon(r.host.value));
						wlPersist();
					});
					r.focus = r.host;
					[ ico, combo, r.mode ].forEach(function(n) { r.el.appendChild(n); });
				}
			}, wlPersist);
			l.type = 'pingwidget';
			l.box = E('div', { 'class': 'tg-wl' }, [ l.node,
				wlAddBtn(_('Add host'), _('Add ping card'), function() { l.addRow(null, {}, true); }) ]);
			return l;
		});
		o.depends('widget_status', '1');

		var svcOpts = [];
		var svcSet = function(list) {
			svcOpts.length = 0;
			(list.length ? list : [ 'ssclash' ]).forEach(function(s) { svcOpts.push([ s, SVC_NICE[s] || s ]); });
		};
		svcSet((uci.sections('5gmodem', 'svcwidget') || []).map(function(x) { return x.service; }).filter(Boolean));
		var svcList = null;
		o = wlOption('_svclist', _('Service monitor'), function() {
			var l, addBtn;
			var freeSvc = function() {
				var used = l.rows.map(function(r) { return r.svc.value; });
				return svcOpts.filter(function(s) { return used.indexOf(s[0]) < 0; });
			};
			var updAdd = function() { addBtn.disabled = !freeSvc().length; };
			l = wlList({
				type: 'svcwidget',
				values: function(r) {
					return { service: r.svc.value, restart_on_uplink: r.ru.checked ? '1' : '0' };
				},
				build: function(r, d) {
					var opts = svcOpts.slice();
					if (d.service && !opts.some(function(s) { return s[0] === d.service; })) {
						opts.push([ d.service, SVC_NICE[d.service] || d.service ]);
					}
					var ico = E('span', { 'class': 'tg-wl-icobox' }, [ svcIconEl(d.service) ]);
					r.svc = wlSelect(opts, d.service || opts[0][0], _('Service'));
					r.ru = E('input', { 'type': 'checkbox' });
					r.ru.checked = String(d.restart_on_uplink) === '1';
					r.svc.addEventListener('change', function() {
						dom.content(ico, svcIconEl(r.svc.value));
						if (addBtn) { updAdd(); }
						wlPersist();
					});
					r.ru.addEventListener('change', wlPersist);
					r.focus = r.svc;
					[ ico, r.svc, E('label', { 'class': 'tg-wl-chk', 'title': _('Restart the service once the uplink starts carrying traffic.') },
						[ r.ru, E('span', {}, _('Restart on uplink')) ]) ].forEach(function(n) { r.el.appendChild(n); });
				}
			}, wlPersist);
			l.type = 'svcwidget';
			addBtn = wlAddBtn(_('Add service'), _('Add service card'), function() {
				var f = freeSvc();
				if (!f.length) { return; }
				var pick = [ 'nikki', 'ssclash', 'clash', 'zapret', 'zerotier' ].filter(function(k) {
					return f.some(function(x) { return x[0] === k; });
				})[0] || f[0][0];
				l.addRow(null, { service: pick, restart_on_uplink: '0' }, true);
				updAdd();
				wlPersist();
			});
			// removing a row frees its service for the add button
			l.node.addEventListener('click', function(ev) {
				if (ev.target.closest && ev.target.closest('.tg-wl-rm')) { window.setTimeout(updAdd, 0); }
			});
			updAdd();
			l.box = E('div', { 'class': 'tg-wl' }, [ l.node, addBtn ]);
			// the full service list arrives after render: open selects get the missing entries
			l.refreshOpts = function() {
				l.rows.forEach(function(r) {
					if (!r.svc) { return; }
					var have = {};
					Array.prototype.forEach.call(r.svc.options, function(op) { have[op.value] = true; });
					svcOpts.forEach(function(o2) {
						if (!have[o2[0]]) { r.svc.appendChild(E('option', { 'value': o2[0] }, o2[1])); }
					});
				});
				updAdd();
			};
			svcList = l;
			return l;
		});
		o.depends('widget_services', '1');

		var stv = wdg.option(form.SectionValue, '__sttings', form.TypedSection, '5gmodem');
		stv.depends('widget_speedtest', '1');
		var sts = stv.subsection;
		sts.anonymous = true;
		sts.title = _('Speed test');

		o = sts.option(form.Value, 'speedtest_url', ARROW_DOWN + ' ' + _('Download source'),
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

		o = sts.option(form.Value, 'speedtest_up_url', ARROW_UP + ' ' + _('Upload endpoint'),
			_('Endpoint that accepts a POST body, for the upload test. "Internetometer" uses a node from the same probe list as the download source, and can be picked here on its own. Only uploads the server received in full are counted: an endpoint that cuts the transfer off early gives no upload figure at all.'));
		o.value('internetometer', _('Internetometer (Yandex CDN)'));
		o.value('https://speed.cloudflare.com/__up', 'Cloudflare');
		o.value('https://speedtest.rt.ru/backend/empty.php', 'Rostelecom (LibreSpeed)');
		o.value('https://yandex.ru/internet/api/v1/upload', 'Yandex - RU (' + _('mobile') + ')');
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
					selectTab('extip');
					var t = document.querySelector('[data-name="extip_url"] .cbi-dropdown');
					if (t) { t.focus(); }
				}
			}, _('Shared with "External IP" - set it in the "External IP" section'));
		};

		var hws = m.section(form.TypedSection, '5gmodem', _('Internet watchdog'));
		hws.anonymous = true;
		var hwBody = E('div', {});
		var hwWrap = E('div', { 'class': 'tg-set-hw' }, [ hwBody ]);
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
			schedTabs();
		});
		o = hws.option(form.DummyValue, '_health');
		o.render = function() { return hwWrap; };

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

		o = tel.option(form.Flag, 'publish_gps', _('Include the position'),
			_('Add the GNSS position, speed and satellites of the modem to the published file and to MQTT. Off by default: a stream of coordinates is a log of where the router has been. Each update asks the modem for the position.'));
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

		var ext = m.section(form.TypedSection, '5gmodem', _('External IP'),
			_('Where the router asks what its address looks like from the outside. The speed-test card uses the same service.'));
		ext.anonymous = true;

		o = ext.option(form.Flag, 'extip_enabled', _('Show the external address'),
			_('Show it next to the address the carrier assigned - in the modem card as "IPv4: 10.x.x.x | 1.2.3.4". Behind CGNAT or a tunnel the two differ, and that difference tells you whether the router\'s own traffic goes through the VPN. It is a request to a third-party service.'));
		// unset means off: upgraded configs keep it off, new installs get 1 from uci-defaults
		o.default = '0';
		o.rmempty = false;

		var exdv = ext.option(form.SectionValue, '__extipshow', form.TypedSection, '5gmodem');
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

		o = ext.option(form.Value, 'extip_url', _('IPv4 service'),
			_('Only this service is queried - there are no silent fallbacks. One that also returns the country (like ip-api.com) gets a flag shown next to the address. Foreign services often stay silent over Russian cellular; the Yandex one answers there.'));
		o.value('http://ip-api.com/line/?fields=countryCode,query', 'ip-api.com (IP + ' + _('country') + ')');
		o.value('https://api.ipify.org', 'ipify (api.ipify.org)');
		o.value('https://ifconfig.me/ip', 'ifconfig.me');
		o.value('https://icanhazip.com', 'icanhazip.com');
		o.value('https://ident.me', 'ident.me');
		o.value('https://ipinfo.io/ip', 'ipinfo.io');
		o.value('https://ipv4-internet.yandex.net/api/v0/ip', 'Yandex - RU (' + _('mobile') + ')');
		o.value('https://ip.beget.ru', 'Beget - RU (' + _('mobile') + ')');
		o.default = 'http://ip-api.com/line/?fields=countryCode,query';
		o.placeholder = 'http://ip-api.com/line/?fields=countryCode,query';
		o.rmempty = true;

		o = ext.option(form.Value, 'extip_url6', _('IPv6 service'),
			_('Queried only when the router actually has an IPv6 default route - otherwise the request would just sit there until it times out.'));
		o.value('https://api6.ipify.org', 'ipify (api6.ipify.org)');
		o.value('https://v6.ident.me', 'ident.me (v6)');
		o.value('https://ipv6.icanhazip.com', 'icanhazip.com (v6)');
		o.default = 'https://api6.ipify.org';
		o.placeholder = 'https://api6.ipify.org';
		o.rmempty = true;

		o = ext.option(form.Value, 'extip_cc_url', _('Country lookup'),
			_('Used only when the service above returns an address but no country: the flag is then resolved by a second request, for the country alone. Use {ip} as the address placeholder.'));
		o.value('http://ip-api.com/line/{ip}?fields=countryCode', 'ip-api.com');
		o.value('https://ipapi.co/{ip}/country/', 'ipapi.co');
		o.placeholder = 'http://ip-api.com/line/{ip}?fields=countryCode';
		o.rmempty = true;

		o = ext.option(form.Value, 'extip_ua', _('User-Agent'),
			_('Header sent with the request. Some services answer a console client with plain text and a browser with an HTML page; and a header of your own keeps the router from introducing itself as one. Empty - whatever curl/wget sends by default.'));
		o.value('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', 'Chrome (Windows)');
		o.value('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', 'Safari (macOS)');
		o.value('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1', 'Safari (iPhone)');
		o.value('curl/8.19.0', 'curl');
		o.rmempty = true;

		o = ext.option(form.Button, '__extip_check', _('Check now'),
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

		// uhttpd max_requests lives in /etc/config/uhttpd, not in 5gmodem: read and written through setopt.sh
		// asked after render (lateData): the row waits hidden and is dropped when uhttpd is not used
		var webReq = {};
		var webReqText = function(mb) {
			return _('How many requests the router web server (uhttpd) handles at once. OpenWrt ships 3. If pages load slowly, buttons or data appear late or freeze, set 10: it is safe on routers with 128 MB of RAM or more. This router has %d MB. The web server restarts after saving.').format(mb || 0);
		};
		var webReqOpt;
		{
			o = webReqOpt = exp.option(form.Value, '_webreq', _('Web server: parallel requests'), webReqText(0));
			o.datatype = 'and(uinteger,range(1,50))';
			o.placeholder = '3';
			o.rmempty = false;
			o.cfgvalue = function() { return webReq.value ? String(webReq.value) : ''; };
			var webReqSet = function(v) {
				v = String(v);
				if (!webReq.value || v === String(webReq.value)) { return; }
				return fs.exec('/usr/share/5gmodem/setopt.sh', [ 'webreq', v ]).then(function(res) {
					if (res && res.code === 0) { webReq.value = v; return; }
					ui.addNotification(null, E('p', {}, _('Could not change the web server setting.')), 'error');
				});
			};
			o.write = function(sid, v) { return webReqSet(v); };
			o.remove = function() { return webReqSet('3'); };
			// once the answer says uhttpd is not used, a re-render of the map leaves the row out
			o.render = function() {
				if (webReq.done && !webReq.value) { return E([]); }
				return form.Value.prototype.render.apply(this, arguments);
			};
		}

		o = exp.option(form.Flag, 'mwan3_metrics', _('mwan3-compatible metrics'),
			_('Uplink metrics start at 10 (10, 20, 30...) as mwan3 expects. When off they start at 100 (100, 110, 120...), leaving 1-99 free for tunnels. Takes effect on the next priority change.'));
		o.default = '0';
		o.rmempty = false;

		var blFilter = function(usbDevs) { return usbDevs.filter(function(d) {
			return d.known !== '1' || d.why === 'ignored' || d.why === 'forced' || d.absent === '1';
		}); };
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
		var blBody = E('div', {}, [ E('span', { 'class': 'tg-skel blk', 'style': 'width:70%;margin:6px 0' }),
			E('span', { 'class': 'tg-skel blk', 'style': 'width:50%;margin:6px 0' }) ]);
		var blFill = function(usbDevs) {
		blFilter(usbDevs).forEach(function(d) {
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
		dom.content(blBody, blItems.length ? blItems
			: [ E('em', {}, _('No doubtful devices: everything found on the bus is in the modem database.')) ]);
		};
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
					// re-read the list in place: the next tick is computed from fresh auto/skip flags
					.then(function() {
						return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/notmodem.sh', [ 'scan' ]), '[]');
					})
					.then(function(out) {
						var fresh = [];
						try { fresh = JSON.parse(out || '[]') || []; } catch (e) {}
						var byVp = {};
						fresh.forEach(function(d) { if (d && d.vidpid && !byVp[d.vidpid]) { byVp[d.vidpid] = d; } });
						blBoxes.forEach(function(b) { if (byVp[b.dev.vidpid]) { b.dev = byVp[b.dev.vidpid]; } });
					})
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

		/* Tabs: each form section is one tab, the tab menu sits above the form and only the
		   active section is shown. The map is rebuilt by a heavy save (add/remove a card), so the
		   sections are tagged at render time and showTabs() runs after every renderContents(). */
		var SECS = [
			[ disp, 'main', _('Main') ],
			[ wdg, 'look', _('Appearance') ],
			[ hws, 'hw', _('Internet watchdog') ],
			[ tel, 'tele', _('Telemetry') ],
			[ ext, 'extip', _('External IP') ],
			[ exp, 'exp', _('For experts') ]
		];
		SECS.forEach(function(d) {
			var orig = d[0].renderContents;
			d[0].renderContents = function() {
				var tag = function(el) { if (el && el.setAttribute) { el.setAttribute('data-tgset', d[1]); } return el; };
				var el = orig.apply(this, arguments);
				return (el && typeof el.then === 'function') ? el.then(tag) : tag(el);
			};
		});
		var isKey = function(k) { return SECS.some(function(d) { return d[1] === k; }); };

		function secNode(key) { return m.root ? m.root.querySelector('[data-tgset="' + key + '"]') : null; }
		// the last tab is remembered; a link to the page may name one in its hash (#extip, #tg-set-extip)
		var curTab = (function() {
			var h = String(window.location.hash || '').replace(/^#(tg-set-)?/, '');
			if (isKey(h)) { return h; }
			try { var v = window.localStorage.getItem('5gm-set-tab'); if (isKey(v)) { return v; } } catch (e) {}
			return 'main';
		})();

		var tabLis = {};
		var tabMenu = E('ul', { 'class': 'cbi-tabmenu tg-set-tabs', 'role': 'tablist' }, SECS.map(function(d) {
			tabLis[d[1]] = E('li', { 'class': 'cbi-tab-disabled', 'data-tab': d[1] }, [
				E('a', {
					'href': '#',
					'role': 'tab',
					'click': function(ev) { ev.preventDefault(); selectTab(d[1]); }
				}, d[2])
			]);
			return tabLis[d[1]];
		}));

		function selectTab(key) {
			curTab = key;
			try { window.localStorage.setItem('5gm-set-tab', key); } catch (e) {}
			showTabs();
		}
		// a section whose every option is hidden by its dependencies (GPS with "Internet
		// priorities only") loses its tab; the active tab then falls back to the first one shown
		function showTabs() {
			var vis = {};
			SECS.forEach(function(d) {
				var sec = secNode(d[1]);
				vis[d[1]] = !!sec && (d[1] === 'hw' || Array.prototype.some.call(sec.querySelectorAll('.cbi-value'),
					function(row) { return !row.closest('.hidden'); }));
			});
			var act = vis[curTab] ? curTab : (SECS.filter(function(d) { return vis[d[1]]; })[0] || [])[1];
			SECS.forEach(function(d) {
				var sec = secNode(d[1]);
				var on = d[1] === act;
				if (sec) {
					sec.classList.add('tg-set-sec');
					sec.style.display = on ? '' : 'none';
				}
				var li = tabLis[d[1]];
				li.style.display = vis[d[1]] ? '' : 'none';
				li.className = on ? 'cbi-tab' : 'cbi-tab-disabled';
				li.firstChild.setAttribute('aria-selected', String(on));
			});
			animKick();
		}
		var _tabT = null;
		function schedTabs() {
			if (_tabT) { window.clearTimeout(_tabT); }
			_tabT = window.setTimeout(showTabs, 80);
		}

		var _mRender = m.renderContents;
		m.renderContents = function() {
			return _mRender.apply(this, arguments).then(function(el) { showTabs(); window.setTimeout(refreshPreviews, 0); return el; });
		};

		var _asT = null;
		var _asNode = null;
		var _asSig = null;

		var formSig = function() {
			if (!_asNode) { return ''; }
			var parts = [];
			_asNode.querySelectorAll('input, textarea').forEach(function(el) {
				if (el.closest('.tg-wl')) { return; }
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
					queueSave(function() {
						return m.save(null, true).then(function() { _asSig = formSig(); });
					});
					return;
				}
				var sig = formSig();
				if (_asSig !== null && sig === _asSig) { return; }
				_asSig = sig;
				queueSave(function() {
					return m.parse()
						.then(function() { return uci.save(); })
						// refresh the form's cached config values: parse() writes only what differs
						// from them, so without this a switch turned back to its first value
						// (on, off, on) was never saved
						.then(function() { return m.load(); })
						.then(applyOwn)
						.then(_gateAfterAutosave);
				});
			}, 400);
		};

		return Promise.resolve(m.render()).then(function(formNode) {
			_asNode = formNode;
			_asSig = formSig();
			// the watchdog form saves itself through health.sh; its events must not
			// trigger a map save (a heavy one runs setopt.sh applyset)
			var inHw = function(ev) { return !!(ev.target && ev.target.closest && ev.target.closest('.hw-form')); };
			// the card lists save themselves (wlPersist), the previews follow every change
			var inList = function(ev) { return !!(ev.target && ev.target.closest && ev.target.closest('.tg-wl')); };
			var onChange = function(ev) {
				if (inHw(ev) || inList(ev)) { return; }
				autoSave(false);
				window.setTimeout(refreshPreviews, 0);
			};
			formNode.addEventListener('change', onChange);
			formNode.addEventListener('widget-change', onChange);
			formNode.addEventListener('cbi-dropdown-change', onChange);
			[ 'change', 'widget-change', 'cbi-dropdown-change', 'input' ].forEach(function(t) {
				formNode.addEventListener(t, schedTabs);
			});
			formNode.addEventListener('click', function(ev) {
				if (inHw(ev)) { return; }
				if (ev.target.closest && ev.target.closest('.cbi-button-add, .cbi-button-remove')) { autoSave(true); }
			});
			window.setTimeout(refreshPreviews, 0);

			// render first: the router-side lists fill the drawn form. A value that arrives late is
			// not a user edit, so the autosave signature is moved along with it while the form is
			// unchanged.
			var webRow = formNode.querySelector('[id$="-_webreq"]');
			if (webRow) { webRow.style.display = 'none'; }
			var lateFill = function(fn) {
				var clean = _asSig === formSig();
				fn();
				if (clean) { _asSig = formSig(); }
			};
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/buttons.sh', [ 'services' ]), '{}').then(function(out) {
				var list = [];
				try { list = (JSON.parse(out || '{}').services) || []; } catch (e) {}
				if (!list.length) { return; }
				lateFill(function() { svcSet(list); if (svcList && svcList.refreshOpts) { svcList.refreshOpts(); } });
			});
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/notmodem.sh', [ 'scan' ]), '[]').then(function(out) {
				var devs = [];
				try { devs = JSON.parse(out || '[]') || []; } catch (e) {}
				lateFill(function() { blFill(devs); });
			});
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/setopt.sh', [ 'webreq' ]), '{}').then(function(out) {
				var w = {};
				try { w = JSON.parse(out || '{}') || {}; } catch (e) {}
				webReq.value = w.value; webReq.mem_mb = w.mem_mb; webReq.done = true;
				webReqOpt.description = webReqText(w.mem_mb);
				var row = formNode.querySelector('[id$="-_webreq"]');
				if (!row || !w.value) { return; }
				lateFill(function() {
					var inp = row.querySelector('input');
					if (inp && !inp.value) { inp.value = String(w.value); }
					var d = row.querySelector('.cbi-value-description');
					if (d) { d.textContent = webReqText(w.mem_mb); }
					row.style.display = '';
				});
			});

			anim.root = E('div', { 'class': 'tg-set' }, [
				E('div', { 'class': 'cbi-map' }, [ updateBlock ]),
				tabMenu,
				E('div', { 'class': 'tg-modem-form tg-set-form' }, [ formNode ])
			]);
			// the page is put in the document after render() returns
			window.setTimeout(animKick, 300);
			return anim.root;
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
