'use strict';
'require baseclass';

/* ОБЩИЕ УТИЛИТЫ БЕЗ СОСТОЯНИЯ - первый шаг распила 5gdetail.js (4180 строк).
   Сюда выносится только то, что не трогает ни DOM-состояние страницы, ни
   модульные переменные: таблицы частот, лейблы, форматтеры. У operatorIcon до
   этого было ТРИ копии (5gdetail, netpri, dashboard) - теперь источник один.
   Всё остальное (диапазоны, метрики) переезжает отдельными шагами - у них
   общее состояние, и их нельзя вырезать механически. */

function ratLabel(mv) {
	if (!mv) { return mv; }
	var reps = [
		[/^5G[ \-]?SA\b/i,  '5G'],
		[/^5G[ \-]?NSA\b/i, '5G'],
		[/^5G\b/i,          '5G'],
		[/^LTE-A\b/i,       '4G+'],
		[/^LTE\b/i,         '4G'],
		[/^HSPA\+/i,        'H+'],
		[/^HSPA\b/i,        'H+'],
		[/^HSDPA\b/i,       'H'],
		[/^HSUPA\b/i,       'H'],
		[/^UMTS\b/i,        '3G'],
		[/^WCDMA\b/i,       '3G'],
		[/^EDGE\b/i,        'E'],
		[/^GPRS\b/i,        '2G'],
		[/^GSM\b/i,         '2G']
	];
	for (var i = 0; i < reps.length; i++) {
		if (reps[i][0].test(mv)) { return mv.replace(reps[i][0], reps[i][1]); }
	}
	return mv;
}

var BAND_MHZ_4G = {1:2100,2:1900,3:1800,4:1700,5:850,7:2600,8:900,11:1500,12:700,13:700,14:700,17:700,18:850,19:850,20:800,21:1500,24:1600,25:1900,26:850,28:700,29:700,30:2300,31:450,32:1500,34:2000,37:1900,38:2600,39:1900,40:2300,41:2500,42:3500,43:3700,46:5200,47:5900,48:3500,50:1500,51:1500,53:2400,54:1600,65:2100,66:1700,67:700,69:2600,70:1700,71:600,72:450,73:450,74:1500,75:1500,76:1500,85:700,87:410,88:410,103:700,106:900};

var BAND_MHZ_5G = {1:2100,2:1900,3:1800,5:850,7:2600,8:900,12:700,13:700,14:700,18:850,20:800,24:1600,25:1900,26:850,28:700,29:700,30:2300,34:2000,38:2600,39:1900,40:2300,41:2500,46:5200,47:5900,48:3500,50:1500,51:1500,53:2400,54:1600,65:2100,66:2100,67:700,70:2000,71:600,74:1500,75:1500,76:1500,77:3700,78:3500,79:4700,80:1800,81:900,82:800,83:700,84:2100,85:700,86:1700,89:850,90:2500,95:2100,96:6000,97:2300,98:1900,99:1600,100:900,101:1900,102:6200,104:6700,105:600,106:900};

/* ДИАПАЗОНЫ ТОЛЬКО НА ПРИЁМ. У них нет uplink, поэтому работать «в одиночку»
   они не могут - только вторыми несущими в агрегации. Оставить включённым один
   такой диапазон = остаться без сети, а по кнопке «B46» этого не видно никак.
   4G: 29/32/67/69/75/76 - SDL (Supplemental Downlink), 46 - LAA (Licensed
   Assisted Access, 5 ГГц), у T99W175/MV31-W он прямо помечен в даташите как
   «B46 (DL only)». 5G: n29/n75/n76 - SDL, n46 - NR-U. */
var BAND_DL_ONLY_4G = { 29: 'SDL', 32: 'SDL', 46: 'LAA', 67: 'SDL', 69: 'SDL', 75: 'SDL', 76: 'SDL' };
var BAND_DL_ONLY_5G = { 29: 'SDL', 46: 'NR-U', 75: 'SDL', 76: 'SDL' };

/* Подсказка для кнопки диапазона: частота плюс предупреждение для DL-only.
   Именно ПОДСКАЗКА, а не подпись: подписи кнопок держим короткими («B46»),
   иначе ряд диапазонов расползается, а на узком экране разъезжается совсем. */
function bandTitle(n, is5g) {
	n = parseInt(n, 10);
	var mhz = is5g ? BAND_MHZ_5G[n] : BAND_MHZ_4G[n];
	var dl = is5g ? BAND_DL_ONLY_5G[n] : BAND_DL_ONLY_4G[n];
	var parts = [];
	if (mhz) { parts.push(mhz + ' MHz'); }
	if (dl) { parts.push(_('%s - receive only, works only as an aggregation carrier').format(dl)); }
	return parts.join(' - ');
}

function formatModeDisplay(mv) {
	if (!mv) { return mv; }
	var t = ratLabel(mv);
	var m = t.match(/^(5G|4G\+|4G|H\+|H|3G|2G|E)(\b|\s|$)/);
	if (!m) { return t; }                       // нераспознанная технология - как есть
	var label = m[1];
	var rest = t.slice(m[1].length).replace(/^\s*\|?\s*/, '');   // убрать ведущие пробелы/палку
	if (!rest) { return label; }                // технология без диапазонов (H+, 3G, ...)
	// Дописать частоту к «голым» диапазонам (LTE B<n> / NR n<n>), у которых её ещё нет
	rest = rest.replace(/\bB(\d+)\b(?!\s*\()/g, function(s, n) {
		return BAND_MHZ_4G[n] ? ('B' + n + ' (' + BAND_MHZ_4G[n] + ' MHz)') : s;
	}).replace(/\bn(\d+)\b(?!\s*\()/g, function(s, n) {
		return BAND_MHZ_5G[n] ? ('n' + n + ' (' + BAND_MHZ_5G[n] + ' MHz)') : s;
	});
	return label + ' | ' + rest;
}

function cellVal(v) {
	v = (v == null) ? '' : String(v);
	return (v === '' || v === '-') ? '' : v;
}

function decHexPair(d, h) {
	d = cellVal(d); h = cellVal(h);
	return (d && h) ? (d + ' (' + h + ')') : (d || h);
}

/* Разбить строку диапазона "B7 (2600 MHz) @20 MHz" на {band, bw}. */
function caSplitBand(s) {
	s = String(s || '');
	var p = s.split(' @');
	return { band: (p[0] || '').trim(), bw: (p[1] || '').trim() };
}

function bandLabel(b) {
	if (b.indexOf('eutran-') == 0) { return 'B' + b.substring(7); }
	if (b.indexOf('ngran-') == 0) { return 'n' + b.substring(6); }
	if (b.indexOf('utran-') == 0) { return 'B' + b.substring(6); }
	return b;
}

function netModeRank(label) {
	var s = String(label || '');
	/* И КИРИЛЛИЦЕЙ ТОЖЕ. Метки режимов приходят от бэкенда уже переведёнными
	   («Авто»), а латинское /auto/ их не ловило: режим получал ранг «неизвестно»
	   (999) и уезжал в КОНЕЦ ряда - у HiLink-модемов кнопки шли 2G, 3G, 4G,
	   Авто. Ожидаемый порядок - Авто первым, затем по поколениям. */
	if (/auto|авто/i.test(s)) { return -1; }
	var gens = (s.match(/([0-9])\s*G/gi) || []).map(function(x) { return parseInt(x, 10); });
	if (!gens.length) { return 999; }
	var mn = Math.min.apply(null, gens), mx = Math.max.apply(null, gens);
	return mn * 10 + (mx - mn);
}

function sortNetModes(modes) {
	return (modes || []).slice().sort(function(a, b) {
		return netModeRank(a.label) - netModeRank(b.label);
	});
}

function protoLabel(v) {
	return ({
		'qmi': 'QMI', 'qmiraw': 'QMI raw-ip', 'mbim': 'MBIM', 'mbimp': 'MBIM+MM', 'ncm': 'NCM', 'xmm': 'XMM', 'atc': 'ATC',
		'ppp': 'PPP', 'wwan': 'WWAN', '3g': '3G', 'modemmanager': 'ModemManager',
		'fibocom': 'Fibocom', 'dhcp': 'DHCP', 'ecm': 'ECM', 'rndis': 'RNDIS', 'sierra': 'Sierra'
	})[String(v || '').toLowerCase()] || (v || '');
}

var MM_PROTOS = [ 'modemmanager', 'mbimp' ];
var SHARED_PROXY_PROTOS = [ 'mbimp' ];

function protoKey(p) {
	return String(p == null ? '' : p).toLowerCase();
}

function isMMProto(p) {
	return MM_PROTOS.indexOf(protoKey(p)) >= 0;
}

function isSharedProxyProto(p) {
	return SHARED_PROXY_PROTOS.indexOf(protoKey(p)) >= 0;
}

function pdpLabel(v) {
	return ({ 'ipv4v6': 'IPv4v6', 'ipv4': 'IPv4', 'ipv6': 'IPv6' })[String(v || '').toLowerCase()] || (v || '');
}

/* Иконка SIM по имени оператора (упрощённые фирменные значки) */
function operatorIcon(name) {
	var n = (name || '').toLowerCase();
	/* ГРАНИЦА СЛОВА, А НЕ ПРОСТО ВХОЖДЕНИЕ: «RT-Mobile» (Ростелеком) содержит
	   «t-mobile», а «РТ-Мобайл» - «т-мобайл», и оба уезжали к Т-Банку. */
	if (/(^|[^0-9a-zа-яё])(t-mobile|tinkoff|t-bank|т-мобайл|т-банк|тинькофф)/.test(n)) { return 'op-tbank'; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2' || n.indexOf('t2 ') == 0 || n.indexOf(' t2') >= 0) { return 'op-t2'; }
	if (n.indexOf('just esim') >= 0 || n.indexOf('justesim') >= 0 || n.indexOf('just-esim') >= 0) { return 'op-justesim'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	if (n.indexOf('gigsky') >= 0) { return 'op-gigsky'; }
	if (n.indexOf('eskimo') >= 0) { return 'op-eskimo'; }
	/* РФ-операторы/MVNO по имени. Мотив (Екатеринбург-2000), Таттелеком (бренд
	   Летай), Вайнах Телеком (Чечня), СберМобайл (MVNO), Ростелеком. Кодов в
	   APN-базе нет - ловим по собственному имени и русским написаниям.
	   Ростелеком ТОЛЬКО так и опознаётся: его нет ни в providers.tsv, ни в
	   mccmnc.dat, а мобильная связь у него живёт на сети Tele2 - по PLMN
	   отличить бренд нельзя, только по имени, которое отдаёт симка. */
	if (n.indexOf('motiv') >= 0 || n.indexOf('мотив') >= 0 || n.indexOf('ekaterinburg') >= 0 || n.indexOf('екатеринбург') >= 0) { return 'op-motiv'; }
	if (n.indexOf('sbermobile') >= 0 || n.indexOf('sber mobile') >= 0 || n.indexOf('sber') >= 0 || n.indexOf('сбер') >= 0) { return 'op-sbermobile'; }
	if (n.indexOf('tattelecom') >= 0 || n.indexOf('таттелеком') >= 0 || n.indexOf('letai') >= 0 || n.indexOf('летай') >= 0) { return 'op-tattelecom'; }
	if (n.indexOf('vainah') >= 0 || n.indexOf('vainakh') >= 0 || n.indexOf('вайнах') >= 0) { return 'op-vainah'; }
	if (n.indexOf('rostelecom') >= 0 || n.indexOf('ростелеком') >= 0 ||
	    n.indexOf('rt-mobile') >= 0 || n.indexOf('rtmobile') >= 0 || n.indexOf('рт-мобайл') >= 0 ||
	    n.trim() == 'rtk' || n.trim() == 'ртк' || n.indexOf('rtk ') == 0 || n.indexOf(' rtk') >= 0) { return 'op-rostelecom'; }
	/* KT (Korea Telecom, бренд olleh, MCC 450). Имя приходит коротким «KT» -
	   матчим как отдельный токен, чтобы не ловить «kt» внутри других слов. */
	if (n.trim() == 'kt' || n.indexOf('olleh') >= 0 || n.indexOf('kt ') == 0 || n.indexOf(' kt') >= 0 || n.indexOf('ktf') >= 0 || n.indexOf('korea telecom') >= 0) { return 'op-kt'; }
	return null;
}

function localizeBytes(v) {
	var t = String(v == null ? '' : v);
	return t.replace(/\b(KiB|MiB|GiB|TiB)\b/g, function(u) {
		return { 'KiB': _('KiB'), 'MiB': _('MiB'), 'GiB': _('GiB'), 'TiB': _('TiB') }[u] || u;
	/* Голый «B» (байты, без приставки) тоже переводим - иначе рядом с «КиБ»
	   висел непереведённый латинский «B» («322.0 B  2.2 КиБ»). Приставки заменены
	   выше, поэтому одиночный латинский B здесь - это именно единица «байт». */
	}).replace(/\bB\b/g, _('B'));
}

function formatPhone(raw) {
    var s = String(raw || '').trim();
    if (!s) { return s; }
    var d = s.replace(/[^\d]/g, '');
    if (d.length === 11 && d.charAt(0) === '8') { d = '7' + d.slice(1); }
    if (d.length === 11 && d.charAt(0) === '7') {
        return '+7 (' + d.slice(1, 4) + ') ' + d.slice(4, 7) + '-' + d.slice(7, 9) + '-' + d.slice(9, 11);
    }
    return s;
}

function formatDuration(sec) {
    if (sec === '-' || sec === '') { return '-'; }
    sec = parseInt(sec, 10);
    if (isNaN(sec)) { return '-'; }
    var d = Math.floor(sec / 86400),
        h = Math.floor(sec / 3600) % 24,
        m = Math.floor(sec / 60) % 60,
        s = sec % 60;
    var pad = function(n) { return (n < 10 ? '0' : '') + n; };
    // Часы:минуты:секунды в формате «24:59» (мин:сек) или «1:24:59» (час:мин:сек);
    // дни выносим отдельно: «2d 1:05:09».
    var out = (h > 0 || d > 0) ? (h + ':' + pad(m) + ':' + pad(s)) : (m + ':' + pad(s));
    if (d > 0) { out = d + 'd ' + out; }
    return out;
}

function formatDateTime(s) {
	if (s == null || !String(s).length) { return ''; }
	if (s.length == 14) {
		return s.replace(/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/, "$1-$2-$3 $4:$5:$6");
	} else if (s.length == 12) {
		return s.replace(/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/, "$1-$2-$3 $4:$5");
	} else if (s.length == 8) {
		return s.replace(/(\d{4})(\d{2})(\d{2})/, "$1-$2-$3");
	} else if (s.length == 6) {
		return s.replace(/(\d{4})(\d{2})/, "$1-$2");
	}
	return s;
}

/* ЧИСТКА localStorage ПО ВОЗРАСТУ.
   Наши тёплые кэши (bands5g2-<путь>, память вкладок eSIM/USSD по модему,
   состояние пингов) заводятся ПОД КЛЮЧ модема или хоста и никогда не удалялись:
   каждый новый USB-путь, каждая переставленная симка и каждый удалённый хост
   оставляли запись навсегда, а bands-кэш - ещё и с килобайтами JSON.
   Возраста у ключей нет, поэтому ведём отдельный индекс «когда последний раз
   трогали»: незнакомый ключ получает отсчёт с текущего захода, а тот, к
   которому никто не обращался дольше срока, удаляется вместе со своей записью
   в индексе. Скачок часов роутера назад индекс не ломает - отсчёт начинается
   заново. */
var LS_IDX = '5gmodem.lsidx';

function lsIdxRead() {
	try { return JSON.parse(window.localStorage.getItem(LS_IDX) || '{}') || {}; } catch (e) { return {}; }
}
function lsIdxWrite(o) {
	try { window.localStorage.setItem(LS_IDX, JSON.stringify(o)); } catch (e) {}
}
function lsTouch(key) {
	if (!key) { return; }
	var idx = lsIdxRead();
	idx[key] = Math.floor(Date.now() / 1000);
	lsIdxWrite(idx);
}
function lsSweep(prefixes, maxAgeDays) {
	if (!prefixes || !prefixes.length) { return; }
	var now = Math.floor(Date.now() / 1000);
	var ttl = (maxAgeDays || 30) * 86400;
	var keys = [], idx = lsIdxRead(), seen = {}, i, j, k;
	try {
		for (i = 0; i < window.localStorage.length; i++) { keys.push(window.localStorage.key(i)); }
	} catch (e) { return; }
	for (i = 0; i < keys.length; i++) {
		k = keys[i];
		if (!k || k === LS_IDX) { continue; }
		var mine = false;
		for (j = 0; j < prefixes.length; j++) {
			if (k.indexOf(prefixes[j]) === 0) { mine = true; break; }
		}
		if (!mine) { continue; }
		seen[k] = true;
		if (idx[k] == null || idx[k] > now) { idx[k] = now; continue; }
		if (now - idx[k] > ttl) {
			try { window.localStorage.removeItem(k); } catch (e) {}
			delete idx[k];
			delete seen[k];
		}
	}
	for (k in idx) { if (!seen[k]) { delete idx[k]; } }
	lsIdxWrite(idx);
}

var QUAL_T = {
	lte:  { rsrp: [ -100, -90, -80 ], rsrq: [ -20, -15, -10 ], sinr: [ 0, 13, 20 ], rssi: [ -85, -75, -65 ] },
	nr:   { rsrp: [ -100, -90, -80 ], rsrq: [ -15, -13, -10 ], sinr: [ 0, 13, 20 ], rssi: [ -85, -75, -65 ] },
	umts: { rscp: [ -105, -95, -85 ], ecio: [ -15, -10, -6 ], rssi: [ -103, -97, -89 ] },
	gsm:  { rssi: [ -103, -97, -89 ] }
};
var QUAL_WIN = {
	rsrp: [ -120, -70 ], rsrq: [ -20, -3 ], sinr: [ -5, 30 ], rssi: [ -100, -50 ],
	csq: [ 0, 31 ], rscp: [ -120, -75 ], ecio: [ -24, 0 ]
};
function qualRat(mode) {
	var m = String(mode == null ? '' : mode).toLowerCase();
	if (/nsa/.test(m)) { return 'lte'; }
	if (/5g|nr/.test(m)) { return 'nr'; }
	if (/lte|4g/.test(m)) { return 'lte'; }
	if (/umts|hspa|wcdma|3g/.test(m)) { return 'umts'; }
	if (/gsm|edge|gprs|2g/.test(m)) { return 'gsm'; }
	return 'lte';
}
function qualThresholds(key, rat) {
	var tab = QUAL_T[rat] || QUAL_T.lte;
	if (key === 'csq') {
		var r = tab.rssi || QUAL_T.lte.rssi;
		return r.map(function(x) { return (x + 113) / 2; });
	}
	return tab[key] || QUAL_T.lte[key] || QUAL_T.umts[key] || null;
}
function qualLevel(key, v, rat) {
	var t = qualThresholds(key, rat), n = parseFloat(v);
	if (!t || isNaN(n)) { return null; }
	var l = 0;
	for (var i = 0; i < t.length; i++) { if (n >= t[i]) { l = i + 1; } }
	return l;
}
function qualPct(key, v, rat) {
	var w = QUAL_WIN[key], n = parseFloat(v);
	if (!w || isNaN(n)) { return null; }
	var pc = Math.round(100 * (n - w[0]) / (w[1] - w[0]));
	return pc < 0 ? 0 : (pc > 100 ? 100 : pc);
}

var BAND_CC_SRC = '2026-09';
var BAND_CC = {
	RU: { lte: [ 1, 3, 7, 8, 20, 31, 38, 40, 41 ], nr: [ 1, 7, 40, 79 ], umts: [ 1, 8 ], gsm: [ 900, 1800 ] },
	US: { lte: [ 2, 4, 5, 12, 13, 14, 17, 25, 26, 29, 30, 41, 46, 48, 66, 71 ], nr: [ 2, 5, 25, 41, 66, 70, 71, 77, 258, 260, 261 ] },
	CA: { lte: [ 2, 4, 5, 7, 12, 13, 17, 29, 66, 71 ], nr: [ 66, 71, 77, 78 ] },
	MX: { lte: [ 2, 4, 5, 7, 28, 66 ], nr: [ 7, 78 ] },
	BR: { lte: [ 1, 3, 5, 7, 28, 38, 40 ], nr: [ 1, 3, 7, 28, 78 ] },
	AR: { lte: [ 2, 4, 5, 7, 28, 66 ], nr: [ 78 ] },
	CL: { lte: [ 2, 4, 5, 7, 28, 66 ], nr: [ 28, 66, 78 ] },
	CO: { lte: [ 2, 4, 5, 7, 28, 66 ], nr: [ 78 ] },
	PE: { lte: [ 2, 4, 5, 7, 8, 28, 66 ], nr: [ 78 ] },
	CN: { lte: [ 1, 3, 5, 8, 34, 38, 39, 40, 41 ], nr: [ 1, 5, 8, 28, 41, 78, 79 ] },
	HK: { lte: [ 1, 3, 7, 8, 40 ], nr: [ 1, 78, 79 ] },
	TW: { lte: [ 1, 3, 7, 8, 28 ], nr: [ 1, 78 ] },
	JP: { lte: [ 1, 3, 8, 11, 18, 19, 21, 26, 28, 41, 42 ], nr: [ 3, 28, 77, 78, 79, 257 ] },
	KR: { lte: [ 1, 3, 5, 7, 8 ], nr: [ 78 ] },
	IN: { lte: [ 1, 3, 5, 8, 28, 40, 41 ], nr: [ 28, 78, 258 ] },
	ID: { lte: [ 1, 3, 5, 8, 40 ], nr: [ 1, 3, 40 ] },
	TH: { lte: [ 1, 3, 8, 28, 40, 41 ], nr: [ 1, 28, 41, 258 ] },
	VN: { lte: [ 1, 3, 8, 28 ], nr: [ 41, 78 ] },
	PH: { lte: [ 1, 3, 5, 7, 28, 40, 41 ], nr: [ 28, 41, 78 ] },
	MY: { lte: [ 1, 3, 7, 8, 28, 38, 40 ], nr: [ 28, 78 ] },
	SG: { lte: [ 1, 3, 7, 8, 28, 38, 40 ], nr: [ 1, 3, 28, 78, 258 ] },
	AU: { lte: [ 1, 3, 5, 7, 8, 28, 40 ], nr: [ 1, 3, 5, 28, 40, 78, 258 ] },
	NZ: { lte: [ 1, 3, 7, 8, 28, 40 ], nr: [ 40, 78 ] },
	PK: { lte: [ 1, 3, 5, 8 ], nr: [ 41, 78 ] },
	BD: { lte: [ 1, 3, 8, 40, 41 ], nr: [ 41 ] },
	GB: { lte: [ 1, 3, 7, 8, 20, 28, 32, 38, 40 ], nr: [ 1, 3, 28, 78 ] },
	DE: { lte: [ 1, 3, 7, 8, 20, 28, 32 ], nr: [ 1, 3, 28, 78 ] },
	FR: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 1, 3, 28, 78 ] },
	IT: { lte: [ 1, 3, 7, 8, 20, 28, 32 ], nr: [ 28, 78, 258 ] },
	ES: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	PT: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 28, 78 ] },
	NL: { lte: [ 1, 3, 7, 8, 20, 28, 32, 38 ], nr: [ 1, 28, 78 ] },
	BE: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	CH: { lte: [ 1, 3, 7, 8, 20, 28, 32, 38, 75 ], nr: [ 1, 28, 78 ] },
	AT: { lte: [ 1, 3, 7, 8, 20, 28, 32, 38 ], nr: [ 28, 78 ] },
	PL: { lte: [ 1, 3, 7, 8, 20, 40 ], nr: [ 1, 28, 38, 78 ] },
	CZ: { lte: [ 1, 3, 7, 8, 20, 38 ], nr: [ 1, 28, 78 ] },
	SK: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	HU: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 28, 78 ] },
	RO: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 78 ] },
	BG: { lte: [ 1, 3, 8, 20 ], nr: [ 1, 78 ] },
	GR: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	SE: { lte: [ 1, 3, 7, 8, 20, 28, 38 ], nr: [ 28, 78 ] },
	NO: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 28, 78 ] },
	FI: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 28, 78 ] },
	DK: { lte: [ 1, 3, 7, 8, 20, 28, 32, 38 ], nr: [ 28, 78 ] },
	IE: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 28, 78 ] },
	EE: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 78 ] },
	LV: { lte: [ 3, 7, 20, 28 ], nr: [ 78 ] },
	LT: { lte: [ 1, 3, 7, 8, 20, 28 ], nr: [ 78 ] },
	RS: { lte: [ 1, 3, 8, 20 ], nr: [ 28, 78 ] },
	HR: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	TR: { lte: [ 1, 3, 7, 8, 20 ], nr: [ 28, 78 ] },
	UA: { lte: [ 1, 3, 7, 8 ], nr: [ 28, 78 ] },
	BY: { lte: [ 3, 7, 20 ], nr: [ 78 ] },
	KZ: { lte: [ 3, 7, 8, 20 ], nr: [ 78 ] },
	UZ: { lte: [ 3, 7, 20 ], nr: [ 78 ] },
	KG: { lte: [ 3, 7, 20 ], nr: [ 78 ] },
	TJ: { lte: [ 3, 20 ], nr: [ 78 ] },
	AM: { lte: [ 3, 7, 20 ], nr: [ 20 ] },
	GE: { lte: [ 3, 7, 20 ], nr: [ 78 ] },
	AZ: { lte: [ 3, 7 ], nr: [  ] },
	MD: { lte: [ 3, 7, 8, 20 ], nr: [ 78 ] },
	IL: { lte: [ 1, 3, 7, 28 ], nr: [ 28, 78 ] },
	AE: { lte: [ 1, 3, 7, 20 ], nr: [ 41, 78 ] },
	SA: { lte: [ 1, 3, 8, 20, 38, 40, 41 ], nr: [ 41, 78 ] },
	QA: { lte: [ 3, 7, 20 ], nr: [ 78 ] },
	EG: { lte: [ 3 ], nr: [ 41 ] },
	IR: { lte: [ 3, 7, 42 ], nr: [ 78 ] },
	ZA: { lte: [ 1, 3, 7, 8, 20, 28, 38, 40 ], nr: [ 78 ] },
	NG: { lte: [ 3, 7, 8, 20, 28 ], nr: [ 78 ] },
	KE: { lte: [ 1, 3, 8, 20, 28 ], nr: [ 78 ] },
	MA: { lte: [ 3, 7, 20 ], nr: [ 28, 78 ] }
};
var BAND_MCC = {
	'250': 'RU', '310': 'US', '311': 'US', '312': 'US', '313': 'US', '314': 'US', '315': 'US', '316': 'US',
	'302': 'CA', '334': 'MX', '724': 'BR', '722': 'AR', '730': 'CL', '732': 'CO', '716': 'PE', '460': 'CN',
	'454': 'HK', '466': 'TW', '440': 'JP', '441': 'JP', '450': 'KR', '404': 'IN', '405': 'IN', '406': 'IN',
	'510': 'ID', '520': 'TH', '452': 'VN', '515': 'PH', '502': 'MY', '525': 'SG', '505': 'AU', '530': 'NZ',
	'410': 'PK', '470': 'BD', '234': 'GB', '235': 'GB', '262': 'DE', '208': 'FR', '222': 'IT', '214': 'ES',
	'268': 'PT', '204': 'NL', '206': 'BE', '228': 'CH', '232': 'AT', '260': 'PL', '230': 'CZ', '231': 'SK',
	'216': 'HU', '226': 'RO', '284': 'BG', '202': 'GR', '240': 'SE', '242': 'NO', '244': 'FI', '238': 'DK',
	'272': 'IE', '248': 'EE', '247': 'LV', '246': 'LT', '220': 'RS', '219': 'HR', '286': 'TR', '255': 'UA',
	'257': 'BY', '401': 'KZ', '434': 'UZ', '437': 'KG', '436': 'TJ', '283': 'AM', '282': 'GE', '400': 'AZ',
	'259': 'MD', '425': 'IL', '424': 'AE', '430': 'AE', '431': 'AE', '420': 'SA', '427': 'QA', '602': 'EG',
	'432': 'IR', '655': 'ZA', '621': 'NG', '639': 'KE', '604': 'MA'
};
function bandRegion(json) {
	var j = json || {};
	var pick = function(v) { var s = String(v == null ? '' : v).trim(); return (/^\d{3}$/).test(s) ? s : ''; };
	var cands = [ pick(j.operator_mcc) ];
	if (!cands[0]) {
		cands = [ pick(j.home_mcc) ];
		var im = String(j.imsi == null ? '' : j.imsi).trim();
		if (/^\d{6,}$/.test(im)) { cands.push(im.slice(0, 3)); }
	}
	for (var i = 0; i < cands.length; i++) {
		var cc = cands[i] && BAND_MCC[cands[i]];
		if (cc && BAND_CC[cc]) { return { mcc: cands[i], cc: cc, src: BAND_CC_SRC, bands: BAND_CC[cc] }; }
	}
	return null;
}

/* Emoji-флаг из 2-буквенного кода страны (RU -> 🇷🇺): две regional indicator
   буквы. Пусто, если код не 2 латинские буквы. */
function flagEmoji(cc) {
	cc = String(cc || '').toUpperCase();
	if (!/^[A-Z]{2}$/.test(cc)) { return ''; }
	return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65);
}

return baseclass.extend({
	API: 30206,
	QUAL_T: QUAL_T,
	qualRat: qualRat,
	qualThresholds: qualThresholds,
	qualLevel: qualLevel,
	qualPct: qualPct,
	bandRegion: bandRegion,
	flagEmoji: flagEmoji,
	ratLabel: ratLabel,
	formatModeDisplay: formatModeDisplay,
	cellVal: cellVal,
	decHexPair: decHexPair,
	caSplitBand: caSplitBand,
	bandLabel: bandLabel,
	netModeRank: netModeRank,
	sortNetModes: sortNetModes,
	protoLabel: protoLabel,
	isMMProto: isMMProto,
	isSharedProxyProto: isSharedProxyProto,
	pdpLabel: pdpLabel,
	operatorIcon: operatorIcon,
	localizeBytes: localizeBytes,
	formatPhone: formatPhone,
	formatDuration: formatDuration,
	formatDateTime: formatDateTime,
	lsTouch: lsTouch,
	lsSweep: lsSweep,
	bandTitle: bandTitle,
	BAND_DL_ONLY_4G: BAND_DL_ONLY_4G,
	BAND_DL_ONLY_5G: BAND_DL_ONLY_5G,
	BAND_MHZ_4G: BAND_MHZ_4G,
	BAND_MHZ_5G: BAND_MHZ_5G
});
