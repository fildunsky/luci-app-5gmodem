'use strict';
'require baseclass';
'require form';
'require fs';
'require view';
'require ui';
'require uci';
'require poll';
'require dom';
'require tools.widgets as widgets';

/*
	Copyright 2021-2025 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
	
	Thanks to https://github.com/koshev-msk for the initial progress bar calculation for rssi/rsrp/rsrq/sinnr.
*/


document.head.append(E('style', {'type': 'text/css'},
`
.tginfo-modesw .cbi-button {
  margin: 2px 6px 2px 0;
  padding: 2px 10px;
}

/* Кнопки диапазонов - строго одинаковой ширины (фиксированная, а не
   min-width, иначе 3-символьные шире 2-символьных), стандартной высоты */
#bands-lte .cbi-button,
#bands-nr .cbi-button {
  width: 3.4em;
  padding-left: 0;
  padding-right: 0;
  text-align: center;
  font-variant-numeric: tabular-nums;
  box-sizing: border-box;
}

/* Анти-джиттер: фиксируем раскладку таблиц и размеры иконок, чтобы при
   обновлении данных строки не пересчитывали размер и страница не прыгала.
   Ключевое: иконка сигнала пересоздаётся каждый опрос через innerHTML -
   без явных размеров браузер делал reflow при каждой перерисовке. */
.tginfo .table {
  table-layout: fixed;
  width: 100%;
}
.tginfo .table .td:first-child {
  width: 33%;
}
.tginfo .table .td {
  overflow-wrap: anywhere;
}
#signal img {
  width: 36px;
  height: 36px;
}
#signal medium {
  display: block;
  line-height: 1.2;
}
#simicon {
  width: 36px !important;
  height: 36px !important;
  flex: 0 0 auto;
}

/* Секции без табличных полос и рамок - как на странице статуса LuCI */
.tginfo .table,
.tginfo .table .tr,
.tginfo .table .td {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}
.tginfo .table .tr:nth-child(odd) .td,
.tginfo .table .tr:nth-child(even) .td {
  background: transparent !important;
}
.tginfo h3 {
  margin-top: 0;
}

/* Компактная строка состояния: сигнал | SIM | статус | инфо | температура */
.tginfo-general {
  display: flex;
  align-items: flex-start;
  gap: 1.4em;
  flex-wrap: wrap;
  padding: 4px 0 2px;
}
.tginfo-signal {
  text-align: center;
  min-width: 44px;
  line-height: 1.15;
}
.tginfo-signal medium {
  display: block;
  font-size: 90%;
}
/* Две параллельные колонки с одинаковой межстрочкой -> строки выровнены */
.tginfo-status,
.tginfo-info {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.tginfo-status {
  min-width: 8em;
}
.tginfo-status > *,
.tginfo-info > * {
  line-height: 1.5;
}
/* короткие строки статуса не переносим, длинные - можно */
.tginfo-status > * {
  white-space: nowrap;
}
.tginfo-status .tginfo-reg,
.tginfo-status .tginfo-loc {
  font-size: 88%;
  opacity: 0.75;
}
.tginfo-status .tginfo-op {
  font-weight: 600;
}
.tginfo-info {
  font-size: 92%;
  opacity: 0.9;
  flex: 1 1 16em;
}
.tginfo-info .tginfo-tech {
  font-weight: 600;
  opacity: 1;
  overflow-wrap: anywhere;
}
/* частоты в скобках - без жирного */
.tginfo-info .tginfo-freq {
  font-weight: normal;
}
.tginfo-info .tginfo-ip {
  font-variant-numeric: tabular-nums;
}
/* подписи IPv4:/IPv6: - жирным */
.tginfo-info .tginfo-iplabel {
  font-weight: 600;
  margin-right: 0.35em;
}
.tginfo-temp {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
  margin-left: auto;
  opacity: 0.85;
  white-space: nowrap;
}
.tginfo-temp .tginfo-thermo {
  display: inline-flex;
  align-items: center;
}
`));

function csq_bar(v, m) {
var pg = document.querySelector('#csq')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);
		if (vn >= 20 && vn <= 31 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= 14 && vn <= 19) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= 10 && vn <= 13) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn <= 9 && vn >= 1) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rssi_bar(v, m) {
var pg = document.querySelector('#rssi')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
if (vn > -50) { vn = -50 };
if (vn < -110) { vn = -110 };
var pc =  Math.floor(100*(1-(-50 - vn)/(-50 - mn)));
		if (vn > -70) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= -85 && vn <= -70) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -100 && vn <= -86) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn < -100) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rsrp_bar(v, m) {
var pg = document.querySelector('#rsrp')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
if (vn > -50) { vn = -50 };
if (vn < -140) { vn = -140 };
var pc =  Math.floor(120*(1-(-50 - vn)/(-70 - mn)));
		if (vn >= -80 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= -90 && vn <= -79) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -100 && vn <= -89) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn < -100) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function sinr_bar(v, m) {
var pg = document.querySelector('#sinr')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor(100-(100*(1-((mn - vn)/(mn - 40)))));
		if (vn > 20 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Excellent');
			};
		if (vn >= 13 && vn <= 20)
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn > 0 && vn <= 12) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Mid cell');
			};
		if (vn <= 0) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Cell edge');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rsrq_bar(v, m) {
var pg = document.querySelector('#rsrq')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor(115-(100/mn)*vn);
if (vn > 0) { vn = 0; };
		if (vn >= -10 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Excellent');
			};
		if (vn >= -15 && vn <= -9) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -20 && vn <= -14) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Mid cell');
			};
		if (vn < -20) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Cell edge');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function SIMdata(data) {
	var sdata = {};
	try { sdata = JSON.parse(data) || {}; } catch (e) {}

	var rows = [];
	if (sdata.simslot != null && String(sdata.simslot).length > 0)
		rows.push(_('SIM Slot'), sdata.simslot);
	rows.push(_('SIM IMSI'), sdata.imsi || '-');
	rows.push(_('SIM ICCID'), sdata.iccid || '-');
	rows.push(_('Modem IMEI'), sdata.imei || '-');
	rows.push(_('Hint'), _('CLICK ME TO SEE NEW MENU'));
	return ui.itemlist(E('span'), rows);
}

/* Подсветить кнопку текущего режима (читается из mmcli -K current-modes) */
function updateModeButtons() {
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', 'any', '-K' ]), '').then(function(out) {
		var m = (out || '').match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
		if (!m) { return; }
		var allowed = m[1].split(',').map(function(x) { return x.trim(); }).sort().join('|');
		var pref = m[2].trim();
		if (pref == 'none') { pref = ''; }
		document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
			var ba = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
			var act = (ba == allowed && (b.getAttribute('data-preferred') || '') == pref);
			b.classList.toggle('cbi-button-action', act);
			b.classList.toggle('important', act);
		});
	});
}

/* --- Выбор диапазонов LTE/5G ---
   mmcli --set-current-bands заменяет ВЕСЬ список по всем технологиям
   сразу, поэтому utran/cdma-часть текущего списка сохраняется как есть,
   а заменяются только eutran/ngran (тот же принцип, что в скрипте
   modemband для этого модема). */
var bandsOther = [];

function bandLabel(b) {
	if (b.indexOf('eutran-') == 0) { return 'B' + b.substring(7); }
	if (b.indexOf('ngran-') == 0) { return 'n' + b.substring(6); }
	return b;
}

/* Чистый билдер кнопок диапазонов - возвращает массив <button>, чтобы
   строить их синхронно прямо в дереве render() (без DOM-манипуляций
   после отрисовки, иначе страница дёргается при загрузке). */
function buildBandButtons(supported, current, prefix) {
	var numsort = function(a, b) { return parseInt(a.replace(/\D+/g, ''), 10) - parseInt(b.replace(/\D+/g, ''), 10); };
	return supported.filter(function(b) { return b.indexOf(prefix) == 0; }).sort(numsort).map(function(b) {
		return E('button', {
			'class': 'btn cbi-button' + (current.indexOf(b) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': b,
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, bandLabel(b));
	});
}

function renderBandToggles(contId, bands, current) {
	var cont = document.getElementById(contId);
	if (!cont) { return; }
	cont.innerHTML = '';
	buildBandButtons(bands, current, bands.length && bands[0].indexOf('ngran-') == 0 ? 'ngran-' : 'eutran-').forEach(function(btn) {
		cont.appendChild(btn);
	});
}

function loadBands() {
	return L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', 'any', '-K' ]), '').then(function(out) {
		if (!out) { return; }
		var supported = [], current = [];
		out.split('\n').forEach(function(ln) {
			var m = ln.match(/^modem\.generic\.(supported|current)-bands\.value\[\d+\]\s*:\s*(\S+)/);
			if (m) { (m[1] == 'supported' ? supported : current).push(m[2]); }
		});
		bandsOther = current.filter(function(b) {
			return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0;
		});
		var numsort = function(a, b) { return parseInt(a.replace(/\D+/g, ''), 10) - parseInt(b.replace(/\D+/g, ''), 10); };
		renderBandToggles('bands-lte', supported.filter(function(b) { return b.indexOf('eutran-') == 0; }).sort(numsort), current);
		renderBandToggles('bands-nr', supported.filter(function(b) { return b.indexOf('ngran-') == 0; }).sort(numsort), current);
	});
}

/* ---- Управление диапазонами через modemband (для модемов, у которых mmcli
   не отдаёт бенды: не под ModemManager, или MM их не показывает). Данные и
   применение - вендорными AT-командами через /usr/share/5gmodem/bands.sh. ---- */
var bandSource = 'mmcli';   // 'mmcli' | 'modemband'

function buildBandButtonsNum(supported, enabled, btype) {
	var pfx = (btype == 'lte') ? 'B' : 'n';
	return (supported || []).map(function(n) {
		n = parseInt(n, 10);
		return E('button', {
			'class': 'btn cbi-button' + ((enabled || []).indexOf(n) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': String(n),
			'data-btype': btype,
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, pfx + n);
	});
}

/* Показать блок частот и заполнить кнопки из bands.sh (без mmcli). Режим сети
   (Auto/2G/…) остаётся скрытым - он управляется только через mmcli. */
function loadBandsModemband() {
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ 'json' ]), '').then(function(out) {
		var j = {};
		try { j = JSON.parse(out) || {}; } catch (e) { return; }
		if (j.error || (!j.supported && !j.supported5gnsa && !j.supported5gsa)) { return; }
		bandSource = 'modemband';

		var supLte = (j.supported || []).map(function(o) { return o.band; });
		var supNsa = (j.supported5gnsa || []).map(function(o) { return o.band; });
		var enLte  = j.enabled || [];
		var enNsa  = j.enabled5gnsa || [];

		[ 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var e = document.getElementById(id); if (e) { e.style.display = ''; }
		});

		var lteC = document.getElementById('bands-lte');
		if (lteC) {
			lteC.innerHTML = '';
			if (supLte.length) { buildBandButtonsNum(supLte, enLte, 'lte').forEach(function(b) { lteC.appendChild(b); }); }
			else { lteC.textContent = '-'; }
		}
		var nrRow = document.getElementById('bands5gn');
		var nrC = document.getElementById('bands-nr');
		if (nrC) {
			nrC.innerHTML = '';
			if (supNsa.length) { buildBandButtonsNum(supNsa, enNsa, 'nsa').forEach(function(b) { nrC.appendChild(b); }); }
			else if (nrRow) { nrRow.style.display = 'none'; }   // нет 5G - прячем строку
		}
	});
}

/* Применить/сбросить диапазоны через modemband */
function applyBandsModemband(reset) {
	var lte = [], nsa = [];
	if (!reset) {
		document.querySelectorAll('#bands-lte .cbi-button-action').forEach(function(b) { lte.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-nr .cbi-button-action').forEach(function(b) { nsa.push(b.getAttribute('data-band')); });
		if (!lte.length && !nsa.length) {
			ui.addNotification(null, E('p', _('Select at least one band')), 'error');
			return Promise.resolve();
		}
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying bands...')));
	var hasLte = document.querySelector('#bands-lte .cbi-button') != null;
	var hasNsa = document.querySelector('#bands-nr .cbi-button') != null;
	var p = Promise.resolve();
	if (hasLte) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands', reset ? 'default' : lte.join(' ') ]); }); }
	if (hasNsa) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands5gnsa', reset ? 'default' : nsa.join(' ') ]); }); }
	return p.then(function() {
		ui.hideModal();
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Bands set. The modem will reconnect.')), 5000, 'info');
		} else {
			ui.addNotification(null, E('p', _('Bands set. The modem will reconnect.')), 'info');
		}
		window.setTimeout(loadBandsModemband, 2000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

/* Ссылка на карту вышек 4cells.ru по данным соты. Подтверждено примерами:
     LTE (tech=3): num = eNB = CID >> 8, lac = TAC (или LAC)
     UMTS(tech=2): num = CID, lac = LAC
     GSM (tech=1): num = CID, без параметра lac
   plmn = MCC + MNC (каждое дополняется до 3 цифр). 5G NSA идёт по LTE-якорю
   (tech=3). Для 5G SA формула пока неизвестна - кнопку не показываем. */
function cell4cellsUrl(json) {
	var mcc = parseInt(json.operator_mcc, 10);
	var mnc = parseInt(json.operator_mnc, 10);
	var cid = parseInt(json.cid_dec, 10);
	if (isNaN(mcc) || isNaN(mnc) || isNaN(cid) || cid <= 0) { return null; }

	var lac = parseInt((json.tac_d && String(json.tac_d).length ? json.tac_d : (json.tac_dec || '')), 10);
	if (isNaN(lac)) { lac = parseInt(json.lac_dec || '', 10); }

	var mode = String(json.mode || '').toUpperCase();
	var tech, num, needLac = true;
	if (mode.indexOf('GSM') >= 0 || mode.indexOf('EDGE') >= 0 || mode.indexOf('GPRS') >= 0 || mode.indexOf('2G') >= 0) {
		tech = 1; num = cid; needLac = false;               // GSM - без lac
	} else if (mode.indexOf('WCDMA') >= 0 || mode.indexOf('UMTS') >= 0 || mode.indexOf('HSPA') >= 0 || mode.indexOf('3G') >= 0) {
		tech = 2; num = cid;                                // UMTS
	} else if (mode.indexOf('5G SA') >= 0) {
		return null;                                        // NR SA - формула неизвестна
	} else {                                                // LTE / 5G NSA
		tech = 3; num = Math.floor(cid / 256);
	}

	var p3 = function(x) { x = String(x); while (x.length < 3) { x = '0' + x; } return x; };
	var url = 'https://4cells.ru/?plmn=' + p3(mcc) + p3(mnc) + '&tech=' + tech + '&num=' + num;
	if (needLac) {
		if (isNaN(lac)) { return null; }
		url += '&lac=' + lac;
	}
	return url;
}

/* Подсветить активную кнопку режима сети по выводу mmcli -K */
function refreshModeButtons(mmK) {
	var mm = String(mmK || '').match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
	if (!mm) { return; }
	var allowed = mm[1].split(',').map(function(x) { return x.trim(); }).sort().join('|');
	var pref = (mm[2].trim() == 'none' ? '' : mm[2].trim());
	document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
		var a = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
		var p = b.getAttribute('data-preferred') || '';
		var on = (a == allowed && p == pref);
		b.classList.toggle('cbi-button-action', on);
		b.classList.toggle('important', on);
	});
}

/* Модем мог быть не готов на момент отрисовки: блок управления частотами
   тогда скрыт и пуст. Когда модем появляется, показать строки и заполнить
   кнопки без ручного обновления страницы. Тяжёлый mmcli -K дёргаем только
   пока блок ещё скрыт. */
function revealMgmtWhenReady() {
	var row = document.getElementById('modeswn');
	if (!row || row.style.display != 'none') { return; }
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', 'any', '-K' ]), '').then(function(mmK) {
		if (!/current-modes/.test(mmK)) { return; }
		[ 'modeswn', 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var e = document.getElementById(id);
			if (e) { e.style.display = ''; }
		});
		refreshModeButtons(mmK);
		loadBands();
	});
}

function applyBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(false); }
	var sel = [];
	document.querySelectorAll('#bands-lte .cbi-button-action, #bands-nr .cbi-button-action').forEach(function(b) {
		sel.push(b.getAttribute('data-band'));
	});
	if (!sel.length) {
		ui.addNotification(null, E('p', _('Select at least one band')), 'error');
		return Promise.resolve();
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying bands...')));
	return fs.exec('/usr/bin/mmcli', [ '-m', 'any', '--set-current-bands=' + bandsOther.concat(sel).join('|') ]).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Bands set. The modem will reconnect.')), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Bands set. The modem will reconnect.')), 'info');
			}
			window.setTimeout(loadBands, 1500);
		} else {
			ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + err.message), 'error');
	});
}

function resetBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(true); }
	document.querySelectorAll('#bands-lte .cbi-button, #bands-nr .cbi-button').forEach(function(b) {
		b.classList.add('cbi-button-action', 'important');
	});
	return applyBands();
}

/* «Перезагрузка» модема: reboot_modem.sh перезапускает радио (CFUN=4->1),
   заставляя заново зарегистрироваться в сети. Полный CFUN=1,1 не используем -
   он переэнумерирует USB, из-за чего MM временно теряет MBIM-классификацию и
   на минуты роняет соединение. */
function rebootModem() {
	if (!confirm(_('Restart the modem now? The connection will drop for a while.')))
		return Promise.resolve();
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Restarting the modem...')));
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh').then(function(res) {
		ui.hideModal();
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			ui.addNotification(null, E('p', _('Modem AT port not found')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification)
			ui.addTimeLimitedNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 8000, 'info');
		else
			ui.addNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 'info');
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to restart the modem') + ': ' + (err.message || err)), 'error');
	});
}

/* Зафиксировать TTL/hop-limit на интерфейсе модема через ttl.sh */
function applyTTL(has6) {
	var g = function(id) { var e = document.getElementById(id); return e ? String(e.value).trim() : ''; };
	var vals = [ g('ttl4in'), g('ttl4out'), has6 ? g('ttl6in') : '', has6 ? g('ttl6out') : '' ];
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
				ui.addTimeLimitedNotification(null, E('p', _('TTL applied.')), 4000, 'info');
			} else {
				ui.addNotification(null, E('p', _('TTL applied.')), 'info');
			}
		} else {
			ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + err.message), 'error');
	});
}

/* Иконка SIM по имени оператора (упрощённые фирменные значки) */
function operatorIcon(name) {
	var n = (name || '').toLowerCase();
	if (n.indexOf('t-mobile') >= 0 || n.indexOf('tinkoff') >= 0 || n.indexOf('t-bank') >= 0 || n.indexOf('т-мобайл') >= 0 || n.indexOf('т-банк') >= 0) { return 'op-tbank'; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2' || n.indexOf('t2 ') == 0 || n.indexOf(' t2') >= 0) { return 'op-t2'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	return null;
}

function updateSimIcon(name) {
	var si = document.getElementById('simicon');
	if (!si) { return; }
	var want;
	if (name == null || String(name).length < 1 || String(name) == '-') {
		want = L.resource('icons/op-nosim.png');   // модем ещё грузится / нет SIM
	} else {
		var ic = operatorIcon(name);
		want = ic ? L.resource('icons/' + ic + '.png') : L.resource('icons/op-sim.png');
	}
	if (si.getAttribute('src') != want) { si.setAttribute('src', want); }
}

function setNetMode(allowed, preferred, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	var args = [ '-m', 'any', '--set-allowed-modes=' + allowed ];
	if (preferred) { args.push('--set-preferred-mode=' + preferred); }
	return fs.exec('/usr/bin/mmcli', args).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
			}
			window.setTimeout(updateModeButtons, 1200);
		} else {
			ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

/* Кнопки режимов сети показываются только когда модемом управляет
   ModemManager (иначе mmcli недоступен или модем не его) */
function modesw_show() {
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-L' ]), '').then(function(out) {
		if (!out || out.indexOf('/Modem/') < 0) { return; }
		[ 'modeswn', 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var row = document.getElementById(id);
			if (row) { row.style.display = ''; }
		});
		updateModeButtons();
		loadBands();
	});
}

function active_select() {
	L.resolveDefault(uci.load('modemdefine'), null).then(function() {
		/* Кнопка переключения модемов нужна только когда в modemdefine
		   определён второй модем - с единственным её незачем показывать
		   (раньше она висела полупрозрачной/выключенной). */
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

function formatDuration(sec) {
    if (sec === '-') { return '-'; }
    if (sec === '') { return '-'; }
    var d = Math.floor(sec / 86400),
        h = Math.floor(sec / 3600) % 24,
        m = Math.floor(sec / 60) % 60,
        s = sec % 60;
    var time = d > 0 ? d + 'd ' : '';
    if (time !== '') { time += h + 'h '; } else { time = h > 0 ? h + 'h ' : ''; }
    if (time !== '') { time += m + 'm '; } else { time = m > 0 ? m + 'm ' : ''; }
    time += s + 's';
    return time;
}

function formatDateTime(s) {
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
			var result = result.replace("(undefined)", "");

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('div', { 'class': 'cbi-section' },
						E('p', {},
							E('div', { 'class': 'cbi-value' }, [
							E('p'),
							E('label', { 'class': 'cbi-value-title' }, [ _('Modem') ]),
							E('div', { 'class': 'cbi-value-field' }, [
								E('select', { 'class': 'cbi-input-select',
										'id': 'mselect',
										'style': 'margin:0px 0; width:100%;',
										},
									(result || "").trim().split(/;/).map(function(cmd) {
										var fields = cmd.split(/#/);
										var name = fields[1];
										var code = fields[0];
									return E('option', { 'value': code }, name ) })

								)
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

				var vx = document.getElementById('mselect').value;
				var marr = vx.split('_');

				uci.set('modemdefine', '@general[0]', 'main_modem', marr[0].toString());
				uci.set('modemdefine', '@general[0]', 'main_network', marr[1].toString());


				uci.save();
				uci.apply();

				window.setTimeout(function() {
					if (!poll.active()) poll.start();
					location.reload();
					//ev.target.blur();
				}, 2000).finally();
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
				return this.error(e);
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
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ]));
		},

		render: function(content) {

			var json = JSON.parse(content);

			if (json) {
				if (!json.imei.length > 2) {
					return false,
					       poll.start()
				}
			}


			// Простая таблица label|значение вместо трёх пар в одном
			// .cbi-value (proton2025 стилизует .cbi-value как flex-строку и
			// сжимал поля в кашу). Значения - выделяемый моноширинный текст.
			var simRow = function(label, val) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:35%; white-space:nowrap; padding:8px 12px 8px 0; vertical-align:top; font-weight:600;' }, [ label ]),
					E('td', { 'class': 'td left', 'style': 'padding:8px 0; font-family:monospace; word-break:break-all; user-select:text;' }, [ (val && String(val).length) ? String(val) : '-' ]),
				]);
			};

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('table', { 'class': 'table', 'style': 'width:100%; background:transparent; border:none; box-shadow:none;' }, [
						simRow(_('SIM IMSI'), json.imsi),
						simRow(_('SIM ICCID'), json.iccid),
						simRow(_('Modem IMEI'), json.imei),
					]),
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, this.handleDissmis),
					}, _('Close')),
				]),
			]);
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
				return this.error(e);
			})
		},
	}),


	formdata: { threeginfo: {} },
	
	load: function() {
		// mmcli -K забираем ВМЕСТЕ с основными данными, чтобы строки
		// "Режим сети"/диапазонов рисовались сразу заполненными в render()
		// (раньше они дорисовывались асинхронно после отрисовки и страница
		// подпрыгивала при загрузке).
		return Promise.all([
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ])),
			L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', 'any', '-K' ]), ''),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/ttl.sh', [ 'get' ]), ''),
		]);
	},

	render: function(res) {
		var m, s, o;

		var data = Array.isArray(res) ? res[0] : res;
		var mmK  = Array.isArray(res) ? (res[1] || '') : '';

		// исходный json (для наличия IPv6 и т.п. на этапе построения)
		var initjson = {};
		try { initjson = JSON.parse(data) || {}; } catch (e) {}
		var has6 = (initjson.ipaddr6 != null && String(initjson.ipaddr6).length > 3 && String(initjson.ipaddr6) != '-');
		var ttlv = function(k) { var v = uci.get('5gmodem', '@5gmodem[0]', k); return (v == null) ? '' : v; };

		// системные TTL/hop-limit по умолчанию - подсказка (placeholder) в пустых полях
		var ttlget = {};
		try { ttlget = JSON.parse((Array.isArray(res) ? (res[3] || '') : '') || '{}') || {}; } catch (e) {}
		var def4 = ttlget.def4 || '64';
		var def6 = ttlget.def6 || '64';

		// --- Синхронный разбор mmcli -K для строк режима/диапазонов ---
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
		// bandsOther: не-eutran/ngran диапазоны сохраняем при смене (см. applyBands)
		bandsOther = mmCur.filter(function(b) { return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0; });
		var msStyle = mmHasModem ? null : 'display:none';
		var modeActive = function(allowed, preferred) {
			return mmModes &&
			       mmModes.allowed == allowed.split('|').sort().join('|') &&
			       (mmModes.pref || '') == (preferred || '');
		};

		// Модем не под ModemManager -> пробуем управлять бендами через
		// modemband (вендорные AT-команды). MM-модемы идут по пути mmcli.
		if (!mmHasModem) {
			window.setTimeout(loadBandsModemband, 400);
		}

		active_select();

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

			if(!json.hasOwnProperty('error')){
				
				if (json.registration == 'SIM not inserted' || json.registration == '-') {
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
				if (json.registration == 'SIM PIN2 required') { 
					ui.addNotification(null, E('p', _('SIM PIN2 required')), 'info');
				}
				if (json.registration == 'SIM PUK2 required') { 
					ui.addNotification(null, E('p', _('SIM PUK2 required')), 'info');
				}
				{
					/* Раньше огромный баннер «модем не найден» + вложенный ниже
					   poll.add висели в else и запускались только если при
					   первой отрисовке уже был сигнал. На загрузке без сигнала
					   опрос вообще не стартовал - страница не обновлялась (не
					   появлялись кнопки диапазонов), пока её не обновишь руками.
					   Теперь опрос стартует всегда, а вместо баннера - краткое
					   самоисчезающее уведомление. */
					if (json.connt == '' || json.connt == '-') {
						if (ui.addTimeLimitedNotification)
							ui.addTimeLimitedNotification(null, E('p', _('Waiting for the modem to connect…')), 4000, 'info');
					}


			pollData: poll.add(function() {
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', 'json'))
					.then(function(res) {
					var json = JSON.parse(res);

				// Раньше при signal==0 показывался модал и страница сама
				// перезагружалась каждые 5 c - на модемах, медленно поднимающих
				// сеть, это давало бесконечные перезагрузки. Страница и так
				// открывается с пустыми полями и обновляется по опросу.
				revealMgmtWhenReady();

					var icon, wicon, ticon, t;
					var wicon = L.resource('icons/loading.gif');
					var ticon = L.resource('icons/ctime.svg');

					// Мобильные иконки уровня сигнала (цветные "палочки":
					// красный слабый -> зелёный сильный). Иконки luci
					// signal-*.svg - это WiFi-столбики, для сотовой сети не
					// подходят.
					// json.signal - строка ("-"/""/число); приводим к числу,
					// иначе "-" (нет данных) проваливался в else -> полная
					// зелёная шкала при 0%.
					var p = parseInt(json.signal, 10);
					if (isNaN(p) || p < 0)
						p = 0;
					if (p == 0)
						icon = L.resource('icons/mobile-signal-000-000.svg');
					else if (p < 20)
						icon = L.resource('icons/mobile-signal-000-020.svg');
					else if (p < 40)
						icon = L.resource('icons/mobile-signal-020-040.svg');
					else if (p < 60)
						icon = L.resource('icons/mobile-signal-040-060.svg');
					else if (p < 80)
						icon = L.resource('icons/mobile-signal-060-080.svg');
					else
						icon = L.resource('icons/mobile-signal-080-100.svg');

					if (document.getElementById('signal')) {
						var view = document.getElementById("signal");
						// иконка сверху, проценты под ней
						view.innerHTML = String.format('<img src="%s"/><br/><medium>%d%%</medium>', icon, p);
					}

					if (document.getElementById('connst')) {
						var view = document.getElementById("connst");
						if (json.conn_time == '' || json.conn_time == '-') {
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/>' + ' ' +_('Waiting for connection data...'), wicon, p);
						}
						else {
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/>' + ' ' + formatDuration(json.conn_time_sec) + ' ' + ' | \u25bc\u202f' + json.rx + ' \u25b2\u202f' + json.tx, ticon, t);
						}
					}

					if (document.getElementById('operator')) {
						var view = document.getElementById("operator");
						if (!json.operator_name.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = checkOperatorName(json.operator_name);
						}
						updateSimIcon(json.operator_name);
					}

					if (document.getElementById('location')) {
						var viewloc = document.getElementById("location");
						if (!json.location.length > 2) {
						viewloc.style.display = 'none';
						}
						else {
						viewloc.style.display = '';
						viewloc.textContent = _(json.location);
						}

					}

					if (document.getElementById('sim')) {
						var view = document.getElementById("sim");
						var sv = document.getElementById("simv");
						if (json.registration == '') { 
						view.textContent = '-';
						}
						else {
						sv.style.visibility = "visible";
						view.textContent = json.registration;
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
							view.textContent = _('Registered (roaming)');
						}
						if (json.registration == '6') { 
							view.textContent = _('Registered, only SMS');
						}
						if (json.registration == '7') { 
							view.textContent = _('Registered (roaming), only SMS');
						}
					}
					}

					if (document.getElementById('mode')) {
						var view = document.getElementById("mode");
						if (!json.mode.length > 1) {
						view.textContent = '-';
						}
						else {
						// частоты в скобках -> отдельный span (не жирный)
						var mtext = json.mode.replace(/[&<>]/g, function(c) {
							return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
						});
						view.innerHTML = mtext.replace(/\(([^)]*)\)/g, '<span class="tginfo-freq">($1)</span>');
						}
					}

					if (document.getElementById('modemip')) {
						var ip = json.ipaddr || '';
						var row = document.getElementById('modemipn');
						if (ip && ip != '-') {
						document.getElementById('modemip').textContent = ip;
						if (row) row.style.display = '';
						}
						else if (row) {
						row.style.display = 'none';
						}
					}

					if (document.getElementById('modemip6')) {
						var ip6 = json.ipaddr6 || '';
						var row6 = document.getElementById('modemip6n');
						if (ip6 && ip6 != '-') {
						document.getElementById('modemip6').textContent = ip6;
						if (row6) row6.style.display = '';
						}
						else if (row6) {
						row6.style.display = 'none';
						}
					}

					if (document.getElementById('modem')) {
						var view = document.getElementById("modem");
						if (!json.modem.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.modem;
						}
					}

					if (document.getElementById('fw')) {
						var view = document.getElementById("fw");
						if (!json.firmware.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.firmware;
						}
					}

					if (document.getElementById('cport')) {
						var view = document.getElementById("cport");
						if (!json.cport.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.cport;
						}
					}

					if (document.getElementById('protocol')) {
						var view = document.getElementById("protocol");
						if (!json.protocol.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.protocol;
						}
					}

					if (document.getElementById('temp')) {
						var view = document.getElementById("temp");
						var viewn = document.getElementById("tempn");
						var t = json.mtemp;
						if (t == null || t == '' || t == '-' || (!t.length > 1 && t.includes(' '))) {
						viewn.style.display = 'none';
						}
						else {
						viewn.style.display = '';
						view.textContent = String(t).replace('&deg;', '°').replace(/\s*C\b/, '°C');
						}
					}

					if (document.getElementById('csq')) {
						var view = document.getElementById("csq");
						if (json.signal == 0 || json.signal == '-') {
						view.style.visibility = 'hidden';
						}
						else {
						if (json.csq == '') { 
						view.textContent = '-';
						}
						else {
						csq_bar(json.csq, 31);
						}
						}
					}

					if (document.getElementById('rssi')) {
						var view = document.getElementById("rssi");
						if (json.rssi == '-') { 
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
						if (json.rsrp == '-') { 
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
						if (json.sinr == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.sinr;
							if (z.includes('dB')) { 
							view.textContent = json.sinr;
							}
							else {
							var sinr_min = -21;
							sinr_bar(json.sinr + " dB", sinr_min);
							}
						}
					}

					if (document.getElementById('rsrq')) {
						var view = document.getElementById("rsrq");
						if (json.rsrq == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rsrq;
							if (z.includes('dB')) { 
							view.textContent = json.rsrq;
							}
							else {
							var rsrq_min = -20;
							rsrq_bar(json.rsrq + " dB", rsrq_min);
							}
						}
					}

					if (document.getElementById('mccmnc')) {
						var view = document.getElementById("mccmnc");
						if (json.operator_mcc == '-' & json.operator_mnc == '-') { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.operator_mcc + " " + json.operator_mnc;
						}
					}

					if (document.getElementById('lac')) {
						var view = document.getElementById("lac");
						var viewn = document.getElementById("lacn");
						if (json.lac_dec.length < 2 || json.lac_hex.length < 2) { 
						viewn.style.display = "none";
						}
						else {
							if (json.lac_dec == '' || json.lac_hex == '') { 
							var lc = json.lac_dec   + ' ' + json.lac_hex;
							var ld = lc.split(' ').join('');
							view.textContent = ld;
							}
							else {
							view.innerHTML = json.lac_dec + ' (' + json.lac_hex + ')';
							}
						}
					}

					if (document.getElementById('tac')) {
						var view = document.getElementById("tac");
						var tac_dh, tac_dec_hex, lac_dec_hex;
							if (json.tac_d.length > 1 || json.tac_h.length > 1) {
							var tac_dh =  json.tac_d + ' (' + json.tac_h + ')';
									view.textContent = tac_dh;
							}
							else {
								if (json.tac_dec.length > 1 || json.tac_hex.length > 1) {
									var tac_dh =  json.tac_dec + ' (' + json.tac_hex + ')';
									view.textContent = tac_dh;
								}
								else {
									view.textContent = '-';
								}
							}
					}

					if (document.getElementById('cid')) {
						var view = document.getElementById("cid");
						var cidText;
						if (json.cid_dec == '' || json.cid_hex == '') {
						cidText = (json.cid_hex + ' ' + json.cid_dec).split(' ').join('');
						}
						else {
						cidText = json.cid_dec + ' (' + json.cid_hex + ')';
						}
						// Cell ID -> стандартная кнопка с пином и номером соты,
						// по клику открывает карту вышек 4cells.ru
						var url4 = cell4cellsUrl(json);
						if (url4 && json.cid_dec && json.cid_dec != '-') {
							view.innerHTML = '';
							view.appendChild(E('button', {
								'class': 'cbi-button',
								'style': 'margin:0;',
								'title': _('View the tower on the 4cells.ru map'),
								'click': function() { window.open(url4, '_blank', 'noopener'); }
							}, '\u{1F4CD}' + json.cid_dec));
						}
						else {
							view.textContent = cidText;
						}
					}

					if (document.getElementById('pband')) {
						var view = document.getElementById("pband");
						if (json.pband == '-') { 
						view.textContent = '-';
						}
						else {
							if (json.pci.length > 0 && json.earfcn.length > 0) { 
								view.textContent = json.pband + ' | ' + json.pci + ' ' + json.earfcn;
							}
							else {
								view.textContent = json.pband;
							}
						}
					}

					if (document.getElementById('s1band')) {
						var view = document.getElementById("s1band");
						if (json.s1band == '-') { 
						view.textContent = '-';
						}
						else {
							if (json.s1pci.length > 0 && json.s1earfcn.length > 0) { 
								view.textContent = json.s1band + ' | ' + json.s1pci + ' ' + json.s1earfcn;
							}
							else {
								view.textContent = json.s1band;
							}
						}
					}
					
					if (document.getElementById('s2band')) {
						var view = document.getElementById("s2band");
						if (json.s2band == '-') { 
						view.textContent = '-';
						}
						else {
							if (json.s2pci.length > 0 && json.s2earfcn.length > 0) { 
								view.textContent = json.s2band + ' | ' + json.s2pci + ' ' + json.s2earfcn;
							}
							else {
								view.textContent = json.s2band;
							}
						}
					}
					
					if (document.getElementById('s3band')) {
						var view = document.getElementById("s3band");
						if (json.s3band == '-') { 
						view.textContent = '-';
						}
						else {
							if (json.s3pci.length > 0 && json.s3earfcn.length > 0) { 
								view.textContent = json.s3band + ' | ' + json.s3pci + ' ' + json.s3earfcn;
							}
							else {
								view.textContent = json.s3band;
							}
						}
					}
					
					if (document.getElementById('s4band')) {
						var view = document.getElementById("s4band");
						if (json.s4band == '-') {  
						view.textContent = '-';
						}
						else {
							if (json.s4pci.length > 0 && json.s4earfcn.length > 0) { 
								view.textContent = json.s4band + ' | ' + json.s4pci + ' ' + json.s4earfcn;
							}
							else {
								view.textContent = json.s4band;
							}
						}
					}
					});
				});	

				}
			}	

		} catch (err) {
				ui.addNotification(null, E('p', _('Error: ') + err.message), 'error');
				}
		}		

		var info = _('').format('');
		m = new form.JSONMap(this.formdata, '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		s.render = L.bind(function(view, section_id) {

			return E([], [

			E('div', { 'class': 'cbi-section tginfo' }, [

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

			E('h3', {}, [ _('General Information') ]),

			/* Компактная строка состояния: слева иконка уровня сигнала с
			   процентами, затем иконка SIM, три строки статуса (регистрация /
			   оператор / страна) и температура модема справа. */
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
							'src': L.resource('icons/op-nosim.png'),
							'title': _(''),
							'class': 'middle',
						}),
						E('span', { 'class': 'cbi-tooltip', 'style': 'text-align:left;font-size:80%' }, SIMdata(data)),
					]),
				]),

				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'id': 'sim', 'class': 'tginfo-reg' }, [ '-' ]),
					E('div', { 'id': 'operator', 'class': 'tginfo-op' }, [ '-' ]),
					E('div', { 'id': 'location', 'class': 'tginfo-loc' }, [ '-' ]),
				]),

				/* Параллельная колонка: технология, IP-адрес(а), статистика */
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

				E('div', { 'class': 'tginfo-temp', 'id': 'tempn', 'style': 'display:none' }, [
					E('span', { 'class': 'tginfo-thermo', 'title': _('Modem temperature') }, [
						E('svg', { 'width': '16', 'height': '16', 'viewBox': '0 0 24 24', 'fill': 'none', 'stroke': 'currentColor', 'stroke-width': '2', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, [
							E('path', { 'd': 'M14 14.76V4a2 2 0 0 0-4 0v10.76a4 4 0 1 0 4 0z' })
						])
					]),
					E('span', { 'id': 'temp' }, [ '-' ]),
				]),
			]),
			]),

			/* Второй блок - управление частотами */
			E('div', { 'class': 'cbi-section tginfo' }, [
			E('h3', {}, [ _('Frequency management') ]),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr', 'id': 'modeswn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Network mode')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'modesw-btns' },
						/* Комбинации только из supported-списка этой прошивки:
						   чистых "4g"/"4g,5g" она не умеет - всегда с 2g/3g. */
						[
							[ _('Auto'), '2g|3g|4g|5g', '5g' ],
							[ '2G', '2g', '' ],
							[ '3G', '3g', '' ],
							[ '4G', '3g|4g', '4g' ],
							[ '4G+5G', '3g|4g|5g', '5g' ],
							[ '5G', '3g|5g', '5g' ]
						].map(L.bind(function(mdef) {
							return E('button', {
								'class': 'btn cbi-button' + (modeActive(mdef[1], mdef[2]) ? ' cbi-button-action important' : ''),
								'data-allowed': mdef[1],
								'data-preferred': mdef[2],
								'click': ui.createHandlerFn(this, function() {
									return setNetMode(mdef[1], mdef[2], mdef[0]);
								})
							}, mdef[0]);
						}, this))
					),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('LTE bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-lte' },
						mmHasModem ? buildBandButtons(mmSup, mmCur, 'eutran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bands5gn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('5G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-nr' },
						mmHasModem ? buildBandButtons(mmSup, mmCur, 'ngran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsactn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(this, function() { return applyBands(); })
						}, _('Apply')),
						' ',
						E('button', {
							'class': 'btn cbi-button',
							'data-tooltip': _('Enable all supported bands'),
							'click': ui.createHandlerFn(this, function() { return resetBands(); })
						}, _('All bands')),
						' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'data-tooltip': _('Restart the modem radio (re-register on the network)'),
							'click': ui.createHandlerFn(this, function() { return rebootModem(); })
						}, _('Restart modem'))
					]),
					]),
			]),
			]),

			/* Отдельный блок - фиксация TTL / hop-limit на интерфейсе модема */
			E('div', { 'class': 'cbi-section tginfo' }, [
			E('h3', {}, [ _('TTL fixing') ]),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('TTL IPv4 (in / out)') ]),
					E('td', { 'class': 'td left' }, [
						E('input', { 'id': 'ttl4in', 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:4em;text-align:center', 'placeholder': def4, 'value': ttlv('ttl4in') }),
						' / ',
						E('input', { 'id': 'ttl4out', 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:4em;text-align:center', 'placeholder': def4, 'value': ttlv('ttl4out') }),
					]),
				]),
				has6 ? E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Hop Limit IPv6 (in / out)') ]),
					E('td', { 'class': 'td left' }, [
						E('input', { 'id': 'ttl6in', 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:4em;text-align:center', 'placeholder': def6, 'value': ttlv('ttl6in') }),
						' / ',
						E('input', { 'id': 'ttl6out', 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:4em;text-align:center', 'placeholder': def6, 'value': ttlv('ttl6out') }),
					]),
				]) : '',
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(this, function() { return applyTTL(has6); })
						}, _('Apply')),
					]),
				]),
			]),
			]),

			E('div', { 'class': 'cbi-section tginfo' }, [
			E('h3', {}, [ _('Cell / Signal Information') ]),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('MCC MNC')]),
					E('td', { 'class': 'td left', 'id': 'mccmnc' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Cell ID')]),
					E('td', { 'class': 'td left', 'id': 'cid' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('TAC')]),
					E('td', { 'class': 'td left', 'id': 'tac' }, [ '-' ]),
					]),
				E('tr', { 'id': 'lacn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('LAC')]),
					E('td', { 'class': 'td left', 'id': 'lac' }, [ '-' ]),
					]),

				E('tr', { 'id': 'csqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('CSQ'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Signal Strength)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'csq',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rssin', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSSI'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Received Signal Strength Indicator)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rssi',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rsrpn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSRP'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Reference Signal Receive Power)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rsrp',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'sinrn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('SINR'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Signal to Interference plus Noise Ratio)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'sinr',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rsrqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSRQ'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Reference Signal Received Quality)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rsrq',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Primary band (PCC) | PCI & EARFCN')]),
					E('td', { 'class': 'td left', 'id': 'pband' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('CA band (SCC1)')]),
					E('td', { 'class': 'td left', 'id': 's1band' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('CA band (SCC2)')]),
					E('td', { 'class': 'td left', 'id': 's2band' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('CA band (SCC3)')]),
					E('td', { 'class': 'td left', 'id': 's3band' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('CA band (SCC4)')]),
					E('td', { 'class': 'td left', 'id': 's4band' }, [ '-' ]),
					]),

				])
			])
			]);
		}, o, this);

		return m.render();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
