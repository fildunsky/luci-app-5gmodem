'use strict';
'require baseclass';
'require view.modem5g.mutil as mutil';

// Explanations for the AT console (sendat.js): a short meaning of a known command and, where the
// reply format is known, a plain-language reading of the reply. Scales follow the pollers in
// root/usr/share/5gmodem (5gmodem.sh, modem/usb/*); quality words come from mutil.qualLevel, so the
// AT page grades a value the same way the Modem page does. Identifiers (IMEI, IMSI, ICCID, the
// own number, GNSS position) are never repeated here, only their length.
// See docs/subsystems/diagnostics.md, "AT console".

function trim(s) { return String(s == null ? '' : s).trim(); }

// Split "1,\"IP\",\"a,b\",0" into fields, keeping commas inside quotes; quotes are dropped.
function fields(s) {
	var out = [], cur = '', q = false, wasQ = false;
	out.q = [];
	s = String(s || '');
	for (var i = 0; i < s.length; i++) {
		var c = s.charAt(i);
		if (c === '"') { q = !q; wasQ = true; continue; }
		if (c === ',' && !q) { out.push(cur.trim()); out.q.push(wasQ); cur = ''; wasQ = false; continue; }
		cur += c;
	}
	out.push(cur.trim());
	out.q.push(wasQ);
	return out;
}

// Reply lines that start with the prefix ("+CSQ"), payload after the colon, split into fields.
function grab(lines, prefix) {
	var re = new RegExp('^' + prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*:\\s*', 'i');
	var out = [];
	lines.forEach(function(l) {
		if (re.test(l)) { out.push(fields(l.replace(re, ''))); }
	});
	return out;
}

function num(v) {
	var s = trim(v).replace(/^"|"$/g, '');
	return /^-?[0-9]+(\.[0-9]+)?$/.test(s) ? parseFloat(s) : null;
}
function intv(v) { var n = num(v); return (n == null || n % 1) ? null : n; }
function fx(n) { return String(Math.round(n * 10) / 10); }

function qual(key, v, rat) {
	var l = (mutil && mutil.qualLevel) ? mutil.qualLevel(key, v, rat || 'lte') : null;
	if (l == null) { return ''; }
	return ' (' + [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][l].toLowerCase() + ')';
}
function lvl(key, label, v, unit, rat) {
	return label + ' ' + fx(v) + ' ' + unit + qual(key, v, rat);
}

var ACT = { 0: 'GSM', 1: 'GSM Compact', 2: '3G (UMTS)', 3: 'EDGE', 4: 'HSDPA', 5: 'HSUPA', 6: 'HSPA',
	7: '4G (LTE)', 8: 'EC-GSM-IoT', 9: 'NB-IoT', 10: '4G (LTE, 5G core)', 11: '5G SA', 12: '5G (NG-RAN)',
	13: '5G NSA (LTE + NR)' };

function actName(v) {
	var n = intv(v);
	return (n != null && ACT[n]) ? ACT[n] : null;
}

function regState(n) {
	switch (n) {
	case 0: return _('not registered, not searching');
	case 1: return _('registered, home network');
	case 2: return _('not registered, searching for a network');
	case 3: return _('registration denied by the network');
	case 4: return _('unknown');
	case 5: return _('registered, roaming');
	case 6: return _('registered for SMS only, home network');
	case 7: return _('registered for SMS only, roaming');
	case 8: return _('emergency calls only');
	}
	return null;
}

function hexDec(h) {
	h = trim(h).replace(/^0x/i, '');
	return /^[0-9A-Fa-f]{1,8}$/.test(h) ? parseInt(h, 16) : null;
}

// "LTE BAND 3" -> B3, "NR5G BAND 78" -> n78, "NR N78" -> n78, "EUTRAN-BAND3" -> B3, "LTE B1" -> B1
function bandName(s) {
	s = trim(s).toUpperCase();
	var m = s.match(/^(?:NR5G[ _-]?BAND|NR[ _-]?N|NR[ _-]?BAND|NGRAN[ _-]?BAND|N)\s*([0-9]+)$/);
	if (m) { return 'n' + m[1]; }
	m = s.match(/^(?:LTE[ _-]?BAND|EUTRAN[ _-]?BAND|LTE[ _-]?B|B)\s*([0-9]+)$/);
	if (m) { return 'B' + m[1]; }
	m = s.match(/^WCDMA[ _-]?(?:BAND)?\s*([0-9]+)$/);
	if (m) { return 'B' + m[1] + ' (3G)'; }
	return null;
}

var LTE_RB = { 6: '1.4', 15: '3', 25: '5', 50: '10', 75: '15', 100: '20' };
var LTE_BWI = { 0: '1.4', 1: '3', 2: '5', 3: '10', 4: '15', 5: '20' };
var NR_BWI = { 0: '5', 1: '10', 2: '15', 3: '20', 4: '25', 5: '30', 6: '40', 7: '50', 8: '60', 9: '70',
	10: '80', 11: '90', 12: '100', 13: '200', 14: '400' };
function withBw(band, mhz) { return mhz ? band + ' @' + mhz + ' MHz' : band; }

function digitsCount(lines, min, max) {
	var re = new RegExp('(?:^|[^0-9A-Fa-f])([0-9A-Fa-f]{' + min + ',' + max + '})(?:$|[^0-9A-Fa-f])');
	for (var i = 0; i < lines.length; i++) {
		if (/^AT/i.test(lines[i])) { continue; }
		var m = lines[i].replace(/"/g, ' ').match(re);
		if (m && /[0-9]{6}/.test(m[1])) { return m[1].length; }
	}
	return null;
}

// UCS2 operator names ("004D0054005300") as 5gmodem.sh decodes them.
function ucs2(s) {
	if (!/^([0-9A-Fa-f]{4})+$/.test(s) || !/^00|^04/.test(s)) { return s; }
	var o = '';
	for (var i = 0; i < s.length; i += 4) { o += String.fromCharCode(parseInt(s.substr(i, 4), 16)); }
	return o;
}

/* ---------- reply parsers: lines -> array of strings ---------- */

function pCsq(L) {
	var r = grab(L, '+CSQ')[0];
	if (!r) { return null; }
	var n = intv(r[0]), b = intv(r[1]), out = [];
	if (n != null && n >= 0 && n <= 31) {
		var dbm = 2 * n - 113;
		out.push(_('Signal level: CSQ %s ≈ %s dBm%s').format(n, dbm, qual('csq', n, 'lte')));
	} else if (n != null && n >= 100 && n <= 191) {
		out.push(_('Signal level: CSQ %s ≈ %s dBm (extended scale)').format(n, n - 216));
	} else if (n === 99) {
		out.push(_('Signal level: unknown (99), the modem has not measured it'));
	}
	if (b === 99 || b == null) { out.push(_('Bit error rate: not reported (normal for LTE and 5G)')); }
	else if (b >= 0 && b <= 7) { out.push(_('Bit error rate: class %s of 7 (0 is best)').format(b)); }
	return out;
}

function pCesq(L) {
	var r = grab(L, '+CESQ')[0];
	if (!r) { return null; }
	var v = r.map(intv), out = [], lte = [];
	if (v[5] != null && v[5] >= 0 && v[5] <= 97) { lte.push(lvl('rsrp', 'RSRP', v[5] - 141, 'dBm')); }
	if (v[4] != null && v[4] >= 0 && v[4] <= 34) { lte.push(lvl('rsrq', 'RSRQ', v[4] * 0.5 - 20, 'dB')); }
	if (lte.length) { out.push('LTE: ' + lte.join(', ')); }
	var um = [];
	if (v[2] != null && v[2] >= 0 && v[2] <= 96) { um.push(lvl('rscp', 'RSCP', v[2] - 121, 'dBm', 'umts')); }
	if (v[3] != null && v[3] >= 0 && v[3] <= 49) { um.push(lvl('ecio', 'Ec/No', v[3] * 0.5 - 24.5, 'dB', 'umts')); }
	if (um.length) { out.push('3G: ' + um.join(', ')); }
	if (v[0] != null && v[0] >= 0 && v[0] <= 63) { out.push('GSM: ' + lvl('rssi', 'RSSI', v[0] - 111, 'dBm', 'gsm')); }
	if (!out.length) { out.push(_('No measurements: 99 and 255 mean no data for that network type')); }
	return out;
}

function pCops(L) {
	var r = grab(L, '+COPS')[0];
	if (!r) { return null; }
	var mode = intv(r[0]), out = [];
	var mn = { 0: _('automatic'), 1: _('manual'), 2: _('deregistered from the network'), 3: _('automatic'), 4: _('manual, automatic if that fails') }[mode];
	if (mn) { out.push(_('Operator selection: %s').format(mn)); }
	if (r.length < 3 || r[2] === '') {
		out.push(_('No operator: the modem is not registered'));
		return out;
	}
	var fmt = intv(r[1]);
	if (fmt === 2) { out.push(_('Network code (MCC MNC): %s %s').format(r[2].substr(0, 3), r[2].substr(3))); }
	else { out.push(_('Operator: %s').format(ucs2(r[2]))); }
	var a = actName(r[3]);
	if (a) { out.push(_('Network type: %s').format(a)); }
	return out;
}

function pReg(prefix) {
	return function(L) {
		var r = grab(L, prefix)[0];
		if (!r) { return null; }
		var out = [], st = intv(r[1]);
		// "+CEREG: 1" is a reply to the set form; a lone number is the stat only when n is absent
		if (r.length === 1) { st = intv(r[0]); }
		var s = regState(st);
		if (s) { out.push(_('State: %s').format(s)); }
		var hex = [], act = null;
		for (var i = 2; i < r.length; i++) {
			if (r.q[i] && /^[0-9A-Fa-f]+$/.test(r[i]) && act == null) { hex.push(r[i]); }
			else if (act == null && intv(r[i]) != null) { act = intv(r[i]); }
		}
		if (hex.length >= 2) {
			var area = hexDec(hex[0]), ci = hexDec(hex[hex.length - 1]);
			if (area != null && area > 0 && area < 0xFFFE) {
				out.push(_('Area code (LAC/TAC): %s, cell ID: %s').format(area, ci));
			} else if (ci) {
				out.push(_('Cell ID: %s').format(ci));
			}
			if (ci && (act === 7 || act === 10 || act === 13) && ci > 0xFFFF) {
				out.push(_('Base station (eNB) %s, sector %s').format(ci >> 8, ci & 255));
			}
		}
		var a = actName(act);
		if (a) { out.push(_('Network type: %s').format(a)); }
		return out;
	};
}

var PDP_TYPE = { 'IP': 'IPv4', 'IPV6': 'IPv6', 'IPV4V6': 'IPv4 + IPv6', 'PPP': 'PPP', 'NON-IP': 'Non-IP' };

function pCgdcont(L) {
	var rr = grab(L, '+CGDCONT');
	if (!rr.length) { return null; }
	var out = [], empty = 0;
	rr.sort(function(a, b) { return (intv(a[0]) || 0) - (intv(b[0]) || 0); });
	rr.forEach(function(r) {
		var t = PDP_TYPE[String(r[1] || '').toUpperCase()] || r[1] || '?';
		if (r[2]) { out.push(_('Profile %s: APN "%s", %s').format(r[0], r[2], t)); }
		else { empty++; }
	});
	if (empty) { out.push(_('Profiles without an APN: %s (the network picks the default one)').format(empty)); }
	return out;
}

function ipKind(a) {
	a = trim(a);
	if (!a) { return null; }
	if (a.indexOf(':') >= 0) { return /^[0:]+$/.test(a) ? null : 'IPv6'; }
	var p = a.split('.');
	if (!p.every(function(x) { return /^[0-9]+$/.test(x); })) { return null; }
	if (p.every(function(x) { return +x === 0; })) { return null; }
	if (p.length === 4) { return 'IPv4'; }
	if (p.length === 16 || p.length === 20) { return 'IPv6'; }
	return null;
}

function pCgpaddr(L) {
	var rr = grab(L, '+CGPADDR');
	if (!rr.length) { return null; }
	var out = [];
	rr.sort(function(a, b) { return (intv(a[0]) || 0) - (intv(b[0]) || 0); });
	rr.forEach(function(r) {
		var k = [];
		r.slice(1).forEach(function(a) { var t = ipKind(a); if (t && k.indexOf(t) < 0) { k.push(t); } });
		if (k.length) { out.push(_('Profile %s has an address: %s').format(r[0], k.join(' + '))); }
	});
	if (!out.length) { out.push(_('No profile has an address yet')); }
	return out;
}

function pCgatt(L) {
	var r = grab(L, '+CGATT')[0];
	if (!r) { return null; }
	var n = intv(r[0]);
	if (n === 1) { return [ _('Attached to the packet service: mobile data is available') ]; }
	if (n === 0) { return [ _('Not attached to the packet service: no mobile data') ]; }
	return [];
}

function pCgact(L) {
	var rr = grab(L, '+CGACT');
	if (!rr.length) { return null; }
	var on = rr.filter(function(r) { return intv(r[1]) === 1; }).map(function(r) { return r[0]; });
	on.sort(function(a, b) { return a - b; });
	return [ on.length ? _('Active profiles: %s').format(on.join(', ')) : _('No profile is active') ];
}

function pCpin(L) {
	var r = grab(L, '+CPIN')[0];
	if (!r) { return null; }
	var v = String(r[0] || '').toUpperCase();
	var m = {
		'READY': _('The SIM is ready, no code is needed'),
		'SIM PIN': _('The SIM waits for the PIN code'),
		'SIM PUK': _('The SIM is blocked: the PUK code is needed'),
		'SIM PIN2': _('The SIM waits for the PIN2 code'),
		'SIM PUK2': _('The SIM waits for the PUK2 code'),
		'PH-NET PIN': _('The modem is locked to another operator (network lock code needed)'),
		'NOT INSERTED': _('SIM not inserted'),
		'NOT READY': _('The SIM is not ready yet')
	}[v];
	return [ m || _('SIM state: %s').format(r[0]) ];
}

function pCclk(L) {
	var r = grab(L, '+CCLK')[0];
	if (!r) { return null; }
	var s = r.join(','), m = s.match(/^(\d{2,4})\/(\d{1,2})\/(\d{1,2}),(\d{1,2}):(\d{2}):(\d{2})([+-]\d{1,2})?/);
	if (!m) { return []; }
	var y = m[1].length === 2 ? '20' + m[1] : m[1], p2 = function(x) { return (x.length < 2 ? '0' : '') + x; };
	var out = [ _('Modem date and time: %s').format(y + '-' + p2(m[2]) + '-' + p2(m[3]) + ' ' + p2(m[4]) + ':' + m[5] + ':' + m[6]) ];
	if (m[7]) {
		var z = parseInt(m[7], 10), h = (Math.abs(z) % 4 === 0 && Math.abs(z) > 0) ? z / 4 : z;
		out.push(_('Time zone: UTC%s').format((h >= 0 ? '+' : '') + h));
	}
	return out;
}

function pCfun(L) {
	var r = grab(L, '+CFUN')[0];
	if (!r) { return null; }
	var n = intv(r[0]);
	var m = {
		0: _('Minimum functionality: the radio is off'),
		1: _('Full functionality: the radio is on'),
		4: _('Flight mode: the transmitter and receiver are off'),
		5: _('Factory test mode'),
		7: _('Offline mode: the radio is off')
	}[n];
	return [ m || _('Mode %s').format(r[0]) ];
}

function pCscon(L) {
	var r = grab(L, '+CSCON')[0];
	if (!r) { return null; }
	var n = intv(r.length > 1 ? r[1] : r[0]);
	if (n === 1) { return [ _('Connected to the cell (RRC connected): data is being exchanged') ]; }
	if (n === 0) { return [ _('Idle (RRC idle): no traffic right now, the connection itself is kept') ]; }
	return [];
}

function pId(min, max, label) {
	return function(L) {
		var n = digitsCount(L, min, max);
		return n ? [ _('%s: %s digits').format(label, n) ] : null;
	};
}

function pCnum(L) {
	var rr = grab(L, '+CNUM');
	var has = rr.some(function(r) { return r.some(function(f) { return /^\+?[0-9]{5,}$/.test(f); }); });
	if (has) { return [ _('A number is stored on the SIM') ]; }
	if (L.some(function(l) { return /^OK$/.test(l); }) || !rr.length) { return [ _('No own number is stored on the SIM') ]; }
	return [];
}

function pAti(L) {
	return L.some(function(l) { return /IMEI\s*:?\s*[0-9]{14}/i.test(l); })
		? [ _('The reply also shows the IMEI') ] : [];
}

/* Quectel */
function pQeng(L) {
	var out = [];
	L.forEach(function(l) {
		var m = l.match(/^\+QENG\s*:\s*(.*)$/i);
		if (!m) { return; }
		var f = fields(m[1]);
		if (/^servingcell$/i.test(f[0])) {
			var st = { 'NOCONN': _('registered, idle'), 'CONNECT': _('connected, data is flowing'),
				'SEARCH': _('searching for a cell'), 'LIMSRV': _('limited service (emergency calls only)') }[String(f[1]).toUpperCase()];
			if (st) { out.push(_('Cell state: %s').format(st)); }
			if (/^LTE$/i.test(f[2])) {
				// servingcell,state,LTE,dup,MCC,MNC,cellID,PCI,EARFCN,band,ULbw,DLbw,TAC,RSRP,RSRQ,RSSI,SINR
				out.push('4G (LTE) ' + withBw('B' + f[9], LTE_BWI[intv(f[11])]) + ', PCI ' + f[7] + ', EARFCN ' + f[8]);
				out.push(sig4(f[13], f[14], f[16], 'lte'));
			} else if (/^NR5G-SA$/i.test(f[2])) {
				// servingcell,state,NR5G-SA,dup,MCC,MNC,cellID,PCI,TAC,ARFCN,band,bw,RSRP,RSRQ,SINR
				out.push('5G SA ' + withBw('n' + f[10], NR_BWI[intv(f[11])]) + ', PCI ' + f[7] + ', ARFCN ' + f[9]);
				out.push(sig4(f[12], f[13], f[14], 'nr'));
			}
		} else if (/^LTE$/i.test(f[0])) {
			// NSA anchor: LTE,dup,MCC,MNC,cellID,PCI,EARFCN,band,ULbw,DLbw,TAC,RSRP,RSRQ,RSSI,SINR
			out.push(_('5G NSA anchor:') + ' 4G (LTE) ' + withBw('B' + f[7], LTE_BWI[intv(f[9])]) + ', PCI ' + f[5]);
			out.push(sig4(f[11], f[12], f[14], 'lte'));
		} else if (/^NR5G-NSA$/i.test(f[0])) {
			// NR5G-NSA,MCC,MNC,PCI,RSRP,SINR,RSRQ,ARFCN,band,bw
			out.push(_('5G NSA carrier:') + ' ' + withBw('n' + f[8], NR_BWI[intv(f[9])]) + ', PCI ' + f[3]);
			out.push(sig4(f[4], f[6], f[5], 'nr'));
		}
	});
	return out.filter(Boolean);
}

function sig4(rsrp, rsrq, sinr, rat) {
	var p = [], a = num(rsrp), q = num(rsrq), s = num(sinr);
	if (a != null && a < 0 && a > -160) { p.push(lvl('rsrp', 'RSRP', a, 'dBm', rat)); }
	if (q != null && q < 0 && q > -45) { p.push(lvl('rsrq', 'RSRQ', q, 'dB', rat)); }
	if (s != null && s >= -30 && s <= 50) { p.push(lvl('sinr', 'SINR', s, 'dB', rat)); }
	return p.join(', ');
}

function pQnwinfo(L) {
	var r = grab(L, '+QNWINFO')[0];
	if (!r) { return null; }
	if (/no service/i.test(r[0])) { return [ _('No service') ]; }
	var b = bandName(r[2]);
	return [ _('Network: %s, band %s, channel %s').format(r[0], b || r[2], r[3] || '-') ];
}

function pQcainfo(L) {
	var rr = grab(L, '+QCAINFO');
	if (!rr.length) { return null; }
	var pcc = [], scc = [];
	rr.forEach(function(r) {
		var b = bandName(r[3]);
		if (!b) { return; }
		var w = (b.charAt(0) === 'B') ? LTE_RB[intv(r[2])] : NR_BWI[intv(r[2])];
		(/^pcc$/i.test(r[0]) ? pcc : scc).push(withBw(b, w));
	});
	var out = [];
	if (pcc.length) { out.push(_('Primary carrier: %s').format(pcc.join(', '))); }
	out.push(scc.length ? _('Added carriers: %s').format(scc.join(', ')) : _('No added carriers: aggregation is not in use'));
	return out;
}

function pQrsrp(L) {
	var r = grab(L, '+QRSRP')[0];
	if (!r) { return null; }
	var v = r.filter(function(x) { return num(x) != null; }).map(num);
	if (!v.length) { return []; }
	var live = v.filter(function(x) { return x > -140; }).length;
	return [ _('Antenna branches: %s dBm; the signal is heard on %s of %s').format(v.join(', '), live, v.length) ];
}

function pQusbnet(L) {
	var r = grab(L, '+QCFG')[0];
	if (!r || !/usbnet/i.test(r[0])) { return null; }
	var m = { 0: 'RmNet / QMI', 1: 'ECM', 2: 'MBIM', 3: 'RNDIS' }[intv(r[1])];
	return m ? [ _('Data interface: %s').format(m) ] : [];
}

function pQnwlock(L) {
	var r = grab(L, '+QNWLOCK')[0];
	if (!r) { return null; }
	return (r.length === 2 && intv(r[1]) === 0) ? [ _('Cell lock is off') ] : [ _('Cell lock is on') ];
}

function pSlot(prefix, base) {
	return function(L) {
		var r = grab(L, prefix)[0];
		if (!r) { return null; }
		var n = intv(r[0]);
		return n == null ? [] : [ _('Active SIM slot: %s').format(n + base) ];
	};
}

function pQsimstat(L) {
	var r = grab(L, '+QSIMSTAT')[0];
	if (!r) { return null; }
	var n = intv(r[1]);
	if (n === 1) { return [ _('A SIM card is inserted') ]; }
	if (n === 0) { return [ _('SIM not inserted') ]; }
	return [];
}

/* Huawei */
function pHcsq(L) {
	var r = grab(L, '^HCSQ')[0];
	if (!r) { return null; }
	var t = String(r[0]).toUpperCase(), v = r.slice(1).map(intv), p = [];
	if (t === 'NOSERVICE') { return [ _('No service') ]; }
	if (t === 'LTE' || t === 'NR') {
		var rat = t === 'NR' ? 'nr' : 'lte';
		if (v[1] != null && v[1] <= 97) { p.push(lvl('rsrp', 'RSRP', v[1] - 141, 'dBm', rat)); }
		if (v[3] != null && v[3] <= 34) { p.push(lvl('rsrq', 'RSRQ', v[3] / 2 - 20, 'dB', rat)); }
		if (v[2] != null && v[2] <= 251) { p.push(lvl('sinr', 'SINR', v[2] / 5 - 20.2, 'dB', rat)); }
	} else if (t === 'WCDMA') {
		if (v[1] != null && v[1] <= 96) { p.push(lvl('rscp', 'RSCP', v[1] - 121, 'dBm', 'umts')); }
		if (v[2] != null && v[2] <= 65) { p.push(lvl('ecio', 'Ec/Io', v[2] / 2 - 32.5, 'dB', 'umts')); }
	} else if (t === 'GSM') {
		if (v[0] != null && v[0] <= 96) { p.push(lvl('rssi', 'RSSI', v[0] - 121, 'dBm', 'gsm')); }
	}
	return p.length ? [ t + ': ' + p.join(', ') ] : [];
}

function pSysinfoex(L) {
	var r = grab(L, '^SYSINFOEX')[0];
	if (!r) { return null; }
	var out = [], srv = intv(r[0]);
	var sv = { 0: _('no service'), 1: _('limited service'), 2: _('normal service'), 3: _('limited regional service'), 4: _('power saving') }[srv];
	if (sv) { out.push(_('Service: %s').format(sv)); }
	if (intv(r[2]) === 1) { out.push(_('Roaming')); }
	if (intv(r[3]) === 255) { out.push(_('SIM not inserted')); }
	var name = r[8] || r[6];
	if (name) { out.push(_('Network type: %s').format(name)); }
	return out;
}

/* ZTE */
function pZrssi(L) {
	var r = grab(L, '+ZRSSI')[0];
	if (!r) { return null; }
	var v = r.map(num), p = [];
	if (r.length < 4) { return []; }
	if (v[0] != null && v[0] <= -44 && v[0] >= -140) { p.push(lvl('rsrp', 'RSRP', v[0], 'dBm')); }
	if (v[1] != null && v[1] <= 0 && v[1] >= -30) { p.push(lvl('rsrq', 'RSRQ', v[1], 'dB')); }
	if (v[2] != null && v[2] <= -20 && v[2] >= -120) { p.push(lvl('rssi', 'RSSI', v[2], 'dBm')); }
	if (v[3] != null && v[3] <= 50 && v[3] >= -20) { p.push(lvl('sinr', 'SINR', v[3], 'dB')); }
	return p.length ? [ p.join(', ') ] : [];
}

function pZpas(L) {
	var r = grab(L, '+ZPAS')[0];
	if (!r) { return null; }
	if (/no service|limited/i.test(r[0])) { return [ _('No service') ]; }
	var d = { 'CS_ONLY': _('calls only'), 'PS_ONLY': _('data only'), 'CS_PS': _('calls and data'), 'CAMPED': _('camped on a cell') }[String(r[1] || '').toUpperCase()];
	return [ _('Network: %s').format(r[0]) + (d ? ', ' + d : '') ];
}

function pZcellinfo(L) {
	var r = grab(L, '+ZCELLINFO')[0];
	if (!r) { return null; }
	var b = bandName(r[2]);
	return [ _('Cell %s, PCI %s, band %s, channel %s').format(r[0], r[1], b || r[2], r[3] || '-') ];
}

function pZcainfo(L) {
	var line = null;
	L.forEach(function(l) { if (/^\+ZCAINFO\s*:/i.test(l)) { line = l.replace(/^\+ZCAINFO\s*:\s*/i, ''); } });
	if (line == null) { return null; }
	var parts = line.split(';').map(trim).filter(Boolean), out = [];
	// PCC: pci, band, tac, earfcn, bw; each SCC: pci, state, band, earfcn, bw (as modem/usb/12864e28)
	var p = parts[0] ? fields(parts[0]) : [];
	if (intv(p[1]) > 0) { out.push(_('Primary carrier: %s').format(withBw('B' + intv(p[1]), num(p[4]) ? fx(num(p[4])) : null))); }
	var s = parts.slice(1).map(fields).filter(function(f) { return intv(f[2]) > 0; })
		.map(function(f) { return withBw('B' + intv(f[2]), num(f[4]) ? fx(num(f[4])) : null); });
	out.push(s.length ? _('Added carriers: %s').format(s.join(', ')) : _('No added carriers: aggregation is not in use'));
	return out;
}

function pQcrsrp(L) {
	var r = null;
	L.forEach(function(l) { if (/^\$QCRSRP\s*:/i.test(l)) { r = fields(l.replace(/^\$QCRSRP\s*:\s*/i, '')); } });
	if (!r) { return null; }
	var cells = [];
	for (var i = 0; i + 2 < r.length; i += 3) {
		var v = num(r[i + 2]);
		if (v != null) { cells.push({ pci: r[i], ch: r[i + 1], v: v }); }
	}
	if (!cells.length) { return []; }
	cells.sort(function(a, b) { return b.v - a.v; });
	return [ _('Cells heard: %s; the strongest is PCI %s on channel %s, RSRP %s dBm').format(cells.length, cells[0].pci, cells[0].ch, fx(cells[0].v)) ];
}

function pZsnt(L) {
	var r = grab(L, '+ZSNT')[0];
	if (!r) { return null; }
	var m = { 0: _('automatic'), 1: '2G', 2: '3G', 6: '4G' }[intv(r[0])];
	return m ? [ _('Network mode: %s').format(m) ] : [];
}

function pOnOff(prefix, idx) {
	return function(L) {
		var r = grab(L, prefix)[0];
		if (!r) { return null; }
		var n = intv(r[idx || 0]);
		return n === 1 ? [ _('Enabled') ] : n === 0 ? [ _('Disabled') ] : [];
	};
}

/* SIMCom */
function pCpsi(L) {
	var r = grab(L, '+CPSI')[0];
	if (!r) { return null; }
	if (/no service/i.test(r[0])) { return [ _('No service') ]; }
	var b = null;
	r.forEach(function(f) { var m = f.match(/BAND\s*([0-9]+)/i); if (m && !b) { b = (/NR/i.test(f) ? 'n' : 'B') + m[1]; } });
	var on = /online/i.test(r[1]) ? _('online') : /offline/i.test(r[1]) ? _('offline') : r[1];
	return [ _('Network: %s').format(r[0].replace(/_/g, ' ')) + ', ' + on + (b ? ', ' + _('band %s').format(b) : '') ];
}

function pCnmp(L) {
	var r = grab(L, '+CNMP')[0];
	if (!r) { return null; }
	var m = { 1: _('automatic'), 2: _('automatic'), 13: '2G', 14: '3G', 38: '4G', 71: '5G', 19: '2G + 3G',
		39: '2G + 3G + 4G', 51: '2G + 4G', 54: '3G + 4G', 109: '4G + 5G' }[intv(r[0])];
	return m ? [ _('Network mode: %s').format(m) ] : [];
}

function pTemp(prefix) {
	return function(L) {
		var r = grab(L, prefix)[0];
		if (!r) { return null; }
		var n = num(r[r.length - 1]);
		return (n != null && n > -40 && n < 150) ? [ _('Temperature: %s °C').format(n) ] : [];
	};
}

/* Telit */
function pQss(L) {
	var r = grab(L, '#QSS')[0];
	if (!r) { return null; }
	var m = { 0: _('SIM not inserted'), 1: _('A SIM card is inserted'), 2: _('The SIM is inserted and unlocked'), 3: _('The SIM is ready') }[intv(r[r.length > 1 ? 1 : 0])];
	return m ? [ m ] : [];
}

/* Fibocom */
function pGtact(L) {
	var r = grab(L, '+GTACT')[0];
	if (!r) { return null; }
	var m = { 1: '3G', 2: '4G', 4: '3G + 4G', 10: _('automatic'), 14: '5G', 16: '4G + 5G', 17: '4G + 5G', 20: _('automatic') }[intv(r[0])];
	var lte = [], nr = [];
	r.slice(3).forEach(function(x) {
		var n = intv(x);
		if (n == null) { return; }
		if (n > 100 && n < 200) { lte.push('B' + (n - 100)); }
		else if (n > 500 && n < 1000) { nr.push('n' + (n - 500)); }
		else if (n > 5000 && n < 6000) { nr.push('n' + (n - 5000)); }
	});
	var out = [];
	if (m) { out.push(_('Network mode: %s').format(m)); }
	if (lte.length) { out.push(_('LTE bands: %s').format(lte.join(', '))); }
	if (nr.length) { out.push(_('5G bands: %s').format(nr.join(', '))); }
	return out;
}

/* ---------- command table ---------- */

var RULES = null;
function rules() {
	if (RULES) { return RULES; }
	var R = function(re, m, p) { return { re: re, m: m, p: p || null }; };
	RULES = [
		/* identity */
		R(/^ATI$/, _('Modem identification: manufacturer, model and firmware version.'), pAti),
		R(/^AT\+CGMI$/, _('Modem manufacturer.')),
		R(/^AT\+CGMM$/, _('Modem model.')),
		R(/^AT\+CGMR$/, _('Firmware version.')),
		R(/^AT\+CGSN(=1)?$/, _('Modem IMEI: the device number in the mobile network.'), pId(14, 17, 'IMEI')),
		R(/^AT\+CIMI$/, _('SIM subscriber identity (IMSI): it identifies the subscription in the operator network.'), pId(14, 16, 'IMSI')),
		R(/^AT(\+ICCID|\+CICCID|\+QCCID|\^ICCID\?)$/, _('Serial number of the SIM card (ICCID), the one printed on the card.'), pId(18, 22, 'ICCID')),
		R(/^AT\+CNUM$/, _('Own phone number stored on the SIM. Many operators do not store it, then the reply has no number.'), pCnum),
		R(/^AT\+CPBS=/, _('Selects the phone book for the next commands ("ON" holds the own numbers of the SIM).')),
		R(/^AT\+CSCS=/, _('Sets the character set for text in commands and replies.')),
		R(/^AT\+CPBW=/, _('Writes an entry to the selected phone book.')),
		R(/^AT\+PRODUCTINFO$/, _('Model, firmware and hardware versions')),
		R(/^AT\+GTPKGVER\?$/, _('Firmware package version')),
		/* signal and network */
		R(/^AT\+CSQ$/, _('Received signal strength (RSSI) and bit error rate: the oldest and roughest signal measure, 0-31.'), pCsq),
		R(/^AT\+CESQ$/, _('Extended signal quality: 2G, 3G and LTE levels in one reply.'), pCesq),
		R(/^AT\+COPS\?$/, _('Current operator and how it was chosen.'), pCops),
		R(/^AT\+CREG\?$/, _('Registration for calls and SMS (circuit-switched network).'), pReg('+CREG')),
		R(/^AT\+CGREG\?$/, _('Registration in the 2G/3G packet (data) network.'), pReg('+CGREG')),
		R(/^AT\+CEREG\?$/, _('Registration in the LTE network.'), pReg('+CEREG')),
		R(/^AT\+C5GREG\?$/, _('Registration in the 5G network (5G core; NSA mode shows up in +CEREG).'), pReg('+C5GREG')),
		R(/^AT\+CSCON\?$/, _('Radio connection state: connected or idle.'), pCscon),
		/* data session */
		R(/^AT\+CGDCONT\?$/, _('Data connection profiles (PDP contexts): number, IP type and APN.'), pCgdcont),
		R(/^AT\+CGPADDR(=[0-9,]*)?$/, _('Addresses the network gave to each data profile.'), pCgpaddr),
		R(/^AT\+CGATT\?$/, _('Attach to the packet service (mobile data).'), pCgatt),
		R(/^AT\+CGACT\?$/, _('Which data profiles are active.'), pCgact),
		R(/^AT\+CGCONTRDP(=[0-9]*)?$/, _('Connection parameters the network gave to the profile: address, gateway, DNS, MTU.')),
		R(/^AT\+GTDNS=/, _('DNS servers of the profile.')),
		/* SIM */
		R(/^AT\+CPIN\?$/, _('SIM state: ready, or waiting for the PIN or PUK code.'), pCpin),
		/* radio control */
		R(/^AT\+CCLK\?$/, _('Modem clock. Most modems take the time from the network.'), pCclk),
		R(/^AT\+CFUN\?$/, _('Radio function mode.'), pCfun),
		R(/^AT\+CFUN=1,1$/, _('Reboots the modem. The connection drops for about a minute.')),
		R(/^AT\+CFUN=4$/, _('Turns the radio off (flight mode). There is no connection until AT+CFUN=1.')),
		R(/^AT\+CFUN=0$/, _('Minimum functionality: the radio and the SIM are off.')),
		R(/^AT\+CFUN=1$/, _('Turns the radio on (full functionality).')),
		/* Quectel */
		R(/^AT\+QENG="SERVINGCELL"$/, _('Serving cell: network type, band, channel and signal levels.'), pQeng),
		R(/^AT\+QENG="NEIGHBOURCELL"$/, _('Neighbour cells the modem hears; the modem picks among them when it changes cells.')),
		R(/^AT\+QNWINFO$/, _('Access technology, operator code, band and channel.'), pQnwinfo),
		R(/^AT\+QCAINFO$/, _('Carrier aggregation: the primary carrier (PCC) and the added ones (SCC).'), pQcainfo),
		R(/^AT\+QRSRP$/, _('RSRP on each antenna branch; -140 and lower means the branch hears nothing.'), pQrsrp),
		R(/^AT\+QTEMP$/, _('Temperatures of the modem sensors, °C.')),
		R(/^AT\+QCFG="USBNET"$/, _('USB data interface mode.'), pQusbnet),
		R(/^AT\+QCFG="BAND"$/, _('Allowed bands as bit masks.')),
		R(/^AT\+QNWLOCK="COMMON\/(4G|5G)"$/, _('Lock to a specific cell: shows whether it is on.'), pQnwlock),
		R(/^AT\+QUIMSLOT\?$/, _('Active SIM slot.'), pSlot('+QUIMSLOT', 0)),
		R(/^AT\+QSIMSTAT\?$/, _('SIM card detection: whether a card is inserted.'), pQsimstat),
		R(/^AT\+QMBNCFG="LIST"$/, _('Operator configuration profiles (MBN) in the modem; the active one is marked with 1.')),
		/* Huawei */
		R(/^AT\^HCSQ\?$/, _('Signal levels of the network in use.'), pHcsq),
		R(/^AT\^SYSINFOEX$/, _('System information: service, roaming, SIM and network type.'), pSysinfoex),
		R(/^AT\^SYSCFGEX\?$/, _('Mode and bands')),
		R(/^AT\^CHIPTEMP\?$/, _('Temperature')),
		R(/^AT\^SETPORT\?$/, _('Port composition')),
		/* ZTE */
		R(/^AT\+ZRSSI$/, _('Signal quality: RSRP, RSRQ, RSSI and SINR.'), pZrssi),
		R(/^AT\+ZCELLINFO\?$/, _('Serving cell: cell ID, PCI, band and channel.'), pZcellinfo),
		R(/^AT\+ZCAINFO\?$/, _('Carrier aggregation: the primary carrier and the added ones.'), pZcainfo),
		R(/^AT\$QCRSRP\?$/, _('Cells the modem hears: PCI, channel and RSRP of each.'), pQcrsrp),
		R(/^AT\+ZPAS\?$/, _('Network type and service domain (calls, data).'), pZpas),
		R(/^AT\+ZSNT\?$/, _('Network mode preference.'), pZsnt),
		R(/^AT\+ZULCA\?$/, _('Uplink carrier aggregation (sending over several carriers).'), pOnOff('+ZULCA')),
		/* Qualcomm-based (Foxconn and others) */
		R(/^AT\^CA_INFO\?$/, _('Carrier aggregation')),
		R(/^AT\^TEMP\?$/, _('Temperature')),
		R(/^AT\^SLMODE\?$/, _('Network mode preference.')),
		R(/^AT\^BAND_PREF\?$/, _('LTE bands')),
		R(/^AT\^SWITCH_SLOT\?$/, _('Active SIM slot.')),
		R(/^AT\^SWITCH_SLOT=0$/, _('Switches to the physical SIM. The modem re-registers on the network.')),
		R(/^AT\^SWITCH_SLOT=1$/, _('Switches to the eSIM. The modem re-registers on the network.')),
		R(/^AT\^USBTYPE\?$/, _('USB speed')),
		R(/^AT\^DEBUG\?$/, _('Engineering information: cell, band and signal levels.')),
		R(/^AT\^CUSTOMER\?$/, _('Vendor customer')),
		R(/^AT\^SLBAND=\?$/, _('Supported bands')),
		R(/^AT\^ULCA\?$/, _('Uplink carrier aggregation (sending over several carriers).')),
		R(/^AT\^NR5G_LOCK\?$/, _('5G cell lock')),
		R(/^AT\^CA_ENABLE\?$/, _('Carrier aggregation enabled')),
		/* SIMCom */
		R(/^AT\+CPSI\?$/, _('Serving cell: network type, state, band and signal.'), pCpsi),
		R(/^AT\+CPMUTEMP$/, _('Modem temperature, °C.'), pTemp('+CPMUTEMP')),
		R(/^AT\+CNMP\?$/, _('Network mode preference.'), pCnmp),
		/* Telit */
		R(/^AT#BND\?$/, _('Bands')),
		R(/^AT#BND=\?$/, _('Supported bands')),
		R(/^AT#RFSTS$/, _('Radio status: cell, channel, signal levels and operator.')),
		R(/^AT#SERVINFO$/, _('Serving cell')),
		R(/^AT#CAINFO\?$/, _('Carrier aggregation')),
		R(/^AT#CACTL\?$/, _('Carrier aggregation enabled')),
		R(/^AT#MONI$/, _('Cell monitor')),
		R(/^AT#CQI$/, _('Channel quality indicator (CQI) reported to the cell: 0-15, higher is better.')),
		R(/^AT#LAPS$/, _('Antenna ports')),
		R(/^AT#4RXDIS\?$/, _('Whether receiving on four antennas is turned off.')),
		R(/^AT#LRXDIV\?$/, _('LTE RX diversity')),
		R(/^AT#LTECAT\?$/, _('LTE category limit')),
		R(/^AT#TEMPSENS=/, _('Temperature sensors')),
		R(/^AT#TMLVL\?$/, _('Thermal mitigation level: how much the modem slows down to cool off.')),
		R(/^AT#SIMDET\?$/, _('SIM slot (0 = slot 1, 1 = slot 2)')),
		R(/^AT#QSS\?$/, _('SIM status'), pQss),
		R(/^AT#USBCFG\?$/, _('USB composition')),
		R(/^AT#FWSWITCH\?$/, _('Firmware image (FN990)')),
		R(/^AT#ACTIVEFW\?$/, _('Active firmware (LM960)')),
		R(/^AT#GETFW$/, _('Firmware images (LM960)')),
		R(/^AT\$GPSP\?$/, _('GNSS power'), pOnOff('$GPSP')),
		R(/^AT\$GPSACP$/, _('Last GNSS position fix. The position itself is not repeated here.')),
		/* Fibocom FM350 and Intel XMM */
		R(/^AT\+GTACT\?$/, _('Network mode and allowed bands.'), pGtact),
		R(/^AT\+(GTACT|XACT)=\?$/, _('Supported modes and bands')),
		R(/^AT\+XACT\?$/, _('Network mode and bands')),
		R(/^AT\+GTCCINFO\?$/, _('Serving cell and neighbours')),
		R(/^AT\+GTCAINFO\?$/, _('Carrier aggregation: carriers, bandwidth, MIMO and modulation.')),
		R(/^AT\+ETHERMAL\?$/, _('Temperature')),
		R(/^AT\+GTSENRDTEMP=/, _('Temperature')),
		R(/^AT\+GTUSBMODE\?$/, _('USB composition')),
		R(/^AT\+GTRXPATHEN\?$/, _('Receive paths in use (main, AUX, MIMO).')),
		R(/^AT\+GTDUALSIM\?$/, _('SIM slots')),
		R(/^AT\+XLEC\?$/, _('Aggregation (CA)')),
		R(/^AT\+XMCI=1$/, _('Serving and neighbour cells')),
		R(/^AT\+XCESQ\?$/, _('Extended signal quality')),
		R(/^AT\+XCCINFO\?$/, _('Serving cell')),
		R(/^AT\+RSRP\?$/, _('RSRP per branch')),
		R(/^AT\+RSRQ\?$/, _('RSRQ per branch')),
		R(/^AT@ERRC:PCELL_SCELL_MEASUREMENT_INFO\(\)$/, _('Antenna branches (first ACM port only)')),
		R(/^AT@NVM:CAL_USBMODE\.NUM\?$/, _('USB composition (NVM)')),
		/* Compal */
		R(/^AT\+BINFO$/, _('Base station and signal')),
		R(/^AT\+LCAINFO$/, _('Aggregation (CA)')),
		R(/^AT\+BNRINFO$/, _('5G cell and signal levels (the reply takes about 3 seconds).')),
		R(/^AT\+NRCAINFO$/, _('Carrier aggregation')),
		R(/^AT\+BCONFIG\?$/, _('Bands and 5G mode (masks)')),
		R(/^AT\+CEITHERM\?$/, _('Thermal sensors')),
		R(/^AT\+CEISWITCHSIM\?$/, _('Active SIM slot.')),
		R(/^AT\+USBCOMP\?$/, _('Current USB composition')),
		R(/^AT\+USBCOMP=/, _('Changes the USB composition: the modem reconnects with other ports and the connection drops.'))
	];
	return RULES;
}

// "AT+CGMI;+CGMM" -> [ "AT+CGMI", "AT+CGMM" ]; case and spaces outside quotes are normalised.
function splitCmd(cmd) {
	var parts = [], cur = '', q = false;
	String(cmd || '').split('').forEach(function(c) {
		if (c === '"') { q = !q; }
		if (c === ';' && !q) { parts.push(cur); cur = ''; return; }
		cur += c;
	});
	parts.push(cur);
	return parts.map(function(p) {
		p = trim(p).replace(/\s+(?=(?:[^"]*"[^"]*")*[^"]*$)/g, '').toUpperCase();
		if (!p) { return ''; }
		return /^AT/.test(p) ? p : 'AT' + p;
	}).filter(Boolean);
}

function findRule(c) {
	var rr = rules();
	for (var i = 0; i < rr.length; i++) { if (rr[i].re.test(c)) { return rr[i]; } }
	return null;
}

// Returns null for an unknown command, otherwise [ { cmd, meaning, lines: [..] } ].
function explain(cmd, stdout) {
	var L = String(stdout || '').split('\n').map(trim).filter(Boolean);
	var parts = splitCmd(cmd), out = [];
	parts.forEach(function(c) {
		var r = findRule(c);
		if (!r) { return; }
		var lines = [];
		if (r.p) {
			var got = null;
			try { got = r.p(L); } catch (e) { got = []; }
			lines = (got == null) ? [ _('The reply has no data in the expected form: this modem may not support the command.') ] : got;
		}
		out.push({ cmd: c, meaning: r.m, lines: lines.filter(Boolean) });
	});
	return out.length ? out : null;
}

return baseclass.extend({
	API: 40008,
	explain: explain,
	splitCmd: splitCmd,
	fields: fields
});
