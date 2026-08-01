'use strict';
'require baseclass';
'require form';
'require fs';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.netpri as netpri';
'require view.modem5g.mutil as mutil';
'require view.modem5g.bandsui as bandsui';
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


/* ЕДИНАЯ шкала для всех основных метрик (CSQ/RSSI/RSRP/RSRQ/SINR).
   Раньше у каждого бара была СВОЯ формула ширины и СВОИ пороги цвета, никак не
   связанные между собой: RSRQ, например, считал ширину как 115-vn (при -19 это
   134% - переполнение), а цвет брал по другим порогам - заливка и цвет
   «разъезжались» (полоса у начала, но оранжевая, хотя должна быть красной).
   Плюс термины были разные и путали (Very good / Mid cell / Cell edge).

   Теперь И заливка, И цвет, И подпись считаются от ОДНИХ порогов: у каждой
   метрики четыре уровня качества, каждый занимает свою четверть шкалы. Значит
   низкая заливка ВСЕГДА красная, высокая ВСЕГДА зелёная - согласованно. Термины
   общие для всех метрик: Слабый / Средний / Хороший / Отличный.

   edges = [худшее, гр1, гр2, гр3, лучшее] по возрастанию качества; отрезки
   [худшее..гр1]=Слабый(0-25%), [гр1..гр2]=Средний(25-50%), [гр2..гр3]=Хороший
   (50-75%), [гр3..лучшее]=Отличный(75-100%). Значение больше = лучше у всех
   метрик (RSRP/RSRQ/RSSI отрицательные - ближе к нулю лучше). */
var _QUAL_BG = [
	'linear-gradient(90deg, #d95c5c, #f87171)',   /* 0 Слабый  - красный */
	'linear-gradient(90deg, #d97a3c, #fb923c)',   /* 1 Средний - оранжевый */
	'linear-gradient(90deg, #c99a3f, #e6b84c)',   /* 2 Хороший - жёлтый */
	'linear-gradient(90deg, #2fb885, #34d399)'    /* 3 Отличный - зелёный */
];
function _qualLabel(lvl) {
	return [ _('Poor'), _('Fair'), _('Good'), _('Excellent') ][lvl];
}
/* Единица метрики - в подпись, чтобы «-19.0» читалось однозначно. */
function metricBar(id, rawVal, unit, edges) {
	var pg = document.querySelector('#' + id);
	if (!pg || !pg.firstElementChild) { return; }
	var pf = pg.firstElementChild;
	pg.style.width = '100%';   /* длину ограничивает CSS max-width (.tginfo) */

	var vn = parseFloat(rawVal);
	if (rawVal == null || rawVal === '' || rawVal === '-' || isNaN(vn)) {
		pf.style.width = '0%';
		pf.style.background = 'rgba(128,128,128,.35)';
		pg.setAttribute('title', '—');
		return;
	}

	/* Уровень (0..3) и ширина: кусочно-линейно по четвертям. */
	var pc, lvl;
	if (vn <= edges[0]) { pc = 0; lvl = 0; }
	else if (vn >= edges[4]) { pc = 100; lvl = 3; }
	else {
		lvl = 0; pc = 100;
		for (var i = 0; i < 4; i++) {
			if (vn <= edges[i + 1]) {
				lvl = i;
				pc = Math.round(25 * i + 25 * (vn - edges[i]) / (edges[i + 1] - edges[i]));
				break;
			}
		}
	}
	pf.style.width = pc + '%';
	pf.style.background = _QUAL_BG[lvl];
	/* Единицу берём из vn (число), НЕ из rawVal: вызыватели передают значение уже
	   с единицей ("-97 dBm"), и добавление unit к rawVal давало "-97 dBm dBm". */
	pg.setAttribute('title', vn + (unit ? (' ' + unit) : '') + ' | ' + _qualLabel(lvl));
}

/* Пороги по общепринятым уровням сигнала LTE (те же, что подсвечивают значения
   в CA-таблице - см. caQuality). Крайние edges - разумные пределы шкалы. */
function csq_bar(v)  { metricBar('csq',  v, '',    [ 0,   10,  15,  20,  31  ]); }
function rssi_bar(v) { metricBar('rssi', v, 'dBm', [ -113, -100, -85, -70, -55 ]); }
function rsrp_bar(v) { metricBar('rsrp', v, 'dBm', [ -125, -100, -90, -80, -70 ]); }
function rsrq_bar(v) { metricBar('rsrq', v, 'dB',  [ -23,  -20, -15, -10, -3  ]); }
function sinr_bar(v) { metricBar('sinr', v, 'dB',  [ -10,  0,   13,  20,  30  ]); }
/* 3G: RSCP (сила кода, dBm) и Ec/No (качество, dB). Пороги по общепринятым
   уровням UMTS: RSCP хуже -105 = плохо, лучше -75 = отлично; Ec/No хуже -16 =
   плохо, лучше -6 = отлично. */
function rscp_bar(v) { metricBar('rscp', v, 'dBm', [ -115, -105, -95, -85, -75 ]); }
function ecio_bar(v) { metricBar('ecio', v, 'dB',  [ -20,  -16, -10, -6,  0  ]); }

/* Телефонный ярлык технологии: LTE->4G, LTE-A->4G+, HSPA->H+, HSDPA/HSUPA->H,
   UMTS/WCDMA->3G, EDGE->E, GPRS/GSM->2G, 5G остаётся 5G. Меняем ТОЛЬКО ведущий
   токен, суффикс с диапазонами ("| B1 + B40 / B7") сохраняем как есть. Правим
   лишь ОТОБРАЖЕНИЕ: сырой json.mode не трогаем - от него зависят и разбор
   диапазонов, и ссылка на карту вышек (там ищутся 'LTE'/'HSPA'/'UMTS'). */

/* Частоты диапазонов (МГц). Источник истины - band4g/band5g в 5gmodem.sh (те же
   данные Wikipedia LTE/NR frequency bands); держим копию здесь, чтобы дописать
   частоту к диапазону, даже если конкретный модем/путь backend её не проставил.
   Значения статичны (определения диапазонов не меняются). */

/* Как в телефоне: технология телефонным ярлыком, затем " | ", затем диапазоны с
   частотой - ЕДИНООБРАЗНО и для агрегации, и для одиночной несущей ("4G | B1
   (2100 MHz)"). Идемпотентна: уже готовые CA-строки ("4G+ | B1 (2100 MHz) + B40
   (2300 MHz)") не портит. Меняет ТОЛЬКО отображение; сырой json.mode не трогаем. */

/* «Модем перезагружается…» - оверлей со спиннером ПОВЕРХ блока информации модема.
   Смена SIM-слота = полный ребут FM350 с переэнумерацией USB (десятки секунд); без
   этого блок показывал устаревшие/пустые данные, будто всё сломалось. Снимаем, как
   только модем вернулся (pollData видит регистрацию/сигнал) или по таймауту. */
var _modemBusyTimer = null;
/* Потолок этих попыток. Обычно хватает трёх (тормозной ответ модема), но СРАЗУ
   ПОСЛЕ перевода интерфейса на ModemManager его поднимают заново, и модем
   появляется в mmcli только через десятки секунд - за 3 попытки (4.5 с) мы не
   дожидались и оставляли кнопки диапазонов невыделенными до перезагрузки
   страницы. Поэтому на время такого переключения потолок поднимается. */
/* Модем отдаёт 3G-диапазоны через ModemManager (mmcli: utran-*)? Ставится при
   отрисовке. Нужен, чтобы modemband-путь (AT-профиль) НЕ гасил строку 3G, которую
   mmcli уже правомерно наполнил тумблерами: у Huawei E3372 3G-комбинаций в
   AT-профиле нет (их вообще определяет один Telit), и ветка else прятала рабочую
   строку - она успевала мелькнуть и исчезала. */
var _modemBusySince = 0;
/* Сколько плашка держится в любом случае. Признак «модем вернулся» - регистрация
   или сигнал, но сразу после нажатия модем ЕЩЁ НЕ УСПЕЛ уйти в перезагрузку и
   выглядит живым: ближайший опрос снял бы плашку через секунду, пользователь
   решил бы, что всё готово, и увидел старое состояние. Выдержка покрывает
   провал между командой и реальным падением радио. */
var MODEM_BUSY_MIN_MS = 8000;
/* Плотный НЕПРОЗРАЧНЫЙ фон оверлея, зависящий от темы: иначе текст под ним
   просвечивал (proton2025), а на bootstrap полупрозрачной плашки не было видно
   вовсе. Тёмную/светлую тему ловим и по prefers-color-scheme, и по data-theme
   (proton2025 штампует его на <html> и должен побеждать). */
/* setModemBusy(msg[, progressSec]) - плашка на блоке «Модем». progressSec
   включает прогрессбар в стиле полосок метрик (как на eSIM): заполняется по
   ожидаемому времени, упирается в 97% и ждёт настоящего возвращения модема -
   pollData снимает плашку, когда регистрация/сигнал снова видны. С
   прогрессбаром спиннер не показываем - ход видно по полосе. */
var _modemBusyBarTimer = null;
function setModemBusy(msg, progressSec) {
	var block = document.querySelector('.cbi-section.tginfo');
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
	// страховка: снимаем принудительно, даже если модем так и не отозвался
	_modemBusyTimer = window.setTimeout(function() { clearModemBusy(true); }, 120000);
}
function clearModemBusy(force) {
	if (!force && _modemBusySince && (Date.now() - _modemBusySince) < MODEM_BUSY_MIN_MS) { return; }
	var ov = document.getElementById('modem-busy-ov');
	if (_modemBusyBarTimer) { window.clearInterval(_modemBusyBarTimer); _modemBusyBarTimer = null; }
	if (ov) {
		var inner = ov.querySelector('#modem-busy-bar > div');
		if (inner) {
			/* полоса добегает до конца - завершение видно глазом */
			inner.style.width = '100%';
			window.setTimeout(function() { ov.style.display = 'none'; }, 350);
		} else {
			ov.style.display = 'none';
		}
	}
	_modemBusySince = 0;
	if (_modemBusyTimer) { window.clearTimeout(_modemBusyTimer); _modemBusyTimer = null; }
	// Операции над радио (привязка к соте, включение 5G) меняют то, что
	// показывает блок диапазонов. Перечитываем ЗДЕСЬ, а не по таймеру у кнопки:
	// момент «модем вернулся» известен только тут, и это единственная точка,
	// где новое состояние уже можно прочитать.
	bandsui.onModemBusyCleared();
}
function modemBusyActive() {
	var ov = document.getElementById('modem-busy-ov');
	return !!(ov && ov.style.display !== 'none');
}

/* ОТЛОЖЕННЫЙ ЗАПУСК ДО ПЕРВОГО ТИКА МЕТРИК. simslot.sh и bands.sh лезут в тот
   же AT-порт, что и опрос метрик; по старым таймерам (400/600 мс) они попадали
   ровно в момент, когда первый полный опрос держит at_lock, - выстраивались в
   очередь и растягивали и себя, и опрос. Теперь стартуют после первого
   успешного тика pollData (порт свободен). Страховочный таймер - на случай
   молчащего/отсутствующего модема: поведение прежнее, просто позже. */
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
	/* 1.5 c, не больше: на тёплом роутере первый тик успевает раньше и
	   запускает очередь сам; страховка нужна лишь молчащему модему, а
	   слишком поздний запуск выглядел «рывками» - блоки SIM/частот
	   появлялись заметно позже остальной страницы. */
	window.setTimeout(runAfterFirstPoll, 1500);
}

/* Переключатель SIM-слотов в шапке (над температурой). Кнопки появляются,
   только если у активного модема >= 2 слотов: AT+GTDUALSIM (Fibocom) или
   mmcli sim-slots (ModemManager). Тип SIM (USIM/eSIM) - подписью слева. */
var simSlotsSeen = false;   // список слотов хоть раз пришёл нормальным
var simSlotsTries = 0;
/* ЖДЁМ ВОЗВРАЩЕНИЯ МОДЕМА ПОСЛЕ СМЕНЫ СЛОТА - И ПЕРЕСТАЁМ, КАК ТОЛЬКО ОН ВЕРНУЛСЯ.
   Раньше здесь стояли семь безусловных таймеров (3..90 c), и все семь ходили в
   AT-порт даже когда слот переключился с первой попытки: до тринадцати заходов
   в порт вместе с ретраями самого loadSimSlots. Теперь цепочка обрывается на
   первом ответе, где активен ИМЕННО запрошенный слот. */
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

function loadSimSlots(cb) {
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', [ 'status' ]), '').then(function(out) {
		var st = {};
		try { st = JSON.parse(out) || {}; } catch (e) { if (cb) { cb(null); } return; }
		var box = document.getElementById('simslotn');
		if (!box) { if (cb) { cb(null); } return; }
		if (!st.slots || st.slots.length < 2) {
			/* Транзитная пустота: сразу после смены слота модем ресетится и
			   переперечисляется на USB (у FM350 - десятки секунд), simslot.sh
			   отдаёт {"error":"no device"}. Раньше кнопки в этот момент ПРОПАДАЛИ
			   и не возвращались до ручного обновления страницы. Если список уже
			   был - оставляем последний хороший и ждём следующего опроса. */
			if (!simSlotsSeen) {
				box.style.display = 'none';
				/* Первое открытие после ПЕРЕЗАГРУЗКИ РОУТЕРА: кэша в /tmp ещё нет
				   (его чистит загрузка), а первая проба сталкивается за AT-порт с
				   опросом метрик и возвращает пусто. Липкий кэш тут не спасает -
				   спасать ещё нечем. Раньше кнопки в этот момент прятались до
				   ручного F5; теперь просто повторяем, пока порт не освободится. */
				if (simSlotsTries < 6) {
					simSlotsTries++;
					window.setTimeout(loadSimSlots, 3000);
				}
			}
			if (cb) { cb(null); }
			return;
		}
		simSlotsSeen = true;
		if (cb) { cb(st); }
		/* Тоже через sameRender: слоты опрашиваются по таймеру, а меняются лишь
		   при переключении SIM. Безусловный innerHTML='' ронял высоту блока на
		   каждом опросе (см. подробности у sameRender). */
		if (sameRender(box, JSON.stringify(st))) { return; }
		box.innerHTML = '';
		if (st.type) {
			box.appendChild(E('span', { 'class': 'tginfo-simslot-type', 'title': _('SIM type') }, [ st.type ]));
		}
		st.slots.forEach(function(s) {
			var on = (String(st.active) === String(s.id));
			/* present приходит там, где прошивка умеет сказать, есть ли в слоте
			   карта (Compal, +CEISWITCHSIM: "SIM inserted 0/1"). Переключение на
			   ПУСТОЙ слот оставит модем без SIM и уронит связь - гасим кнопку.
			   Где present не сообщают (FM350), поведение прежнее. */
			var noCard = (s.present !== undefined && String(s.present) === '0');
			var empty = (noCard && !on);
			box.appendChild(E('button', {
				'class': 'btn cbi-button' + (on ? ' tg-current' : '') + (empty ? ' cbi-button-disabled' : ''),
				'disabled': empty ? '' : null,
				/* Пустым помечаем и АКТИВНЫЙ слот. Гасить его нельзя (на активный
				   слот не переключаются), но и молчать нельзя: у модема без карты
				   MM отдаёт активным слот 1, и подсвеченная кнопка «SIM1» читается
				   как «карта на месте». Именно так выглядел отчёт с двумя T99W175,
				   где во втором модеме SIM физически не было. */
				'title': noCard ? _('Slot is empty (no SIM inserted)') : null,
				'click': function(ev) {
					ev.preventDefault();
					if (on || empty) { return; }
					ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching SIM slot...')));
					fs.exec('/usr/share/5gmodem/simslot.sh', [ 'set', String(s.id) ]).then(function(res) {
						ui.hideModal();
						var ok = res && res.stdout && res.stdout.indexOf('"ok"') >= 0;
						/* Слот переключён -> модем в ребут (переэнумерация USB, десятки
						   секунд). Накрываем блок «Модем» спиннером, чтобы старые данные
						   не выглядели как поломка; снимется, когда модем вернётся
						   (pollData) или по таймауту. */
						if (ok) { setModemBusy(_('The modem is restarting after the SIM switch…')); }
						if (ui.addTimeLimitedNotification) {
							ui.addTimeLimitedNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), 6000, ok ? 'info' : 'error');
						} else {
							ui.addNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), ok ? 'info' : 'error');
						}
						/* Перечитать активный слот, КОГДА модем вернётся. Разового
						   опроса через 4 с не хватало: FM350 после смены слота
						   уходит на переперечисление USB на десятки секунд, ответ
						   был «нет устройства», и подсветка активной кнопки
						   оставалась старой до ручного F5. Опрашиваем с запасом -
						   лишние опросы дёшевы, а simslot.sh «липкий» (см. выше).
						   Интерфейс переподнимает бэкенд (simslot.sh slot_redial),
						   чтобы IP не остался от прежней SIM даже если уйти со
						   страницы. */
						pollSlotUntilSwitched(s.id, [ 3000, 8000, 15000, 25000, 40000, 60000, 90000 ]);
					}).catch(function() { ui.hideModal(); });
				}
			}, [ s.label ]));
		});
		box.style.display = '';
	});
}

function SIMdata(data) {
	var sdata = {};
	/* Принимаем И строку (первая отрисовка), И готовый объект (обновление из
	   опроса): подсказка перерисовывается на каждом тике, а разбирать JSON
	   заново только ради неё незачем. */
	if (data && typeof data === 'object') { sdata = data; }
	else { try { sdata = JSON.parse(data) || {}; } catch (e) {} }

	var rows = [];
	// «-» значит «слот неизвестен» - строку в подсказке не показываем вовсе
	if (sdata.simslot != null && String(sdata.simslot).length > 0 && sdata.simslot != '-')
		rows.push(_('SIM Slot'), sdata.simslot);
	rows.push(_('SIM IMSI'), sdata.imsi || '-');
	rows.push(_('SIM ICCID'), sdata.iccid || '-');
	rows.push(_('Modem IMEI'), sdata.imei || '-');
	return ui.itemlist(E('span'), rows);
}

/* Подсветить кнопку текущего режима. Единый путь bandsui.loadBands (mgmtinfo): режим
   берётся из КОНФИГА интерфейса, а не из живых current-modes, которые модем
   сбрасывает на каждом передозвоне - от них подсветка мигала «Авто». */
/* ==== «Информация о соте»: ДЕКЛАРАТИВНЫЙ РЕЕСТР СТРОК =======================
   Одно правило вместо россыпи стилей. Раньше у каждой строки был свой механизм
   (setRowVisible / голый display / visibility:hidden / безусловный показ) и
   свои проверки: `json.lac_dec.length` падал, когда поля нет в снимке (HiLink
   часть полей не отдаёт), а в mccmnc стояло побитовое `&` вместо `&&`. Теперь:
   строка = {id, text(json)} либо {id, render(json, el, c4)} для спец-случаев
   (кнопки 4cells), видимость - единым правилом setRowVisible («показанное не
   прячем» - защита от прыжков высоты, см. комментарий там). */
var CELL_ROWS = [
	{ id: 'mccmnc', text: function(j) {
		var m = mutil.cellVal(j.operator_mcc), n = mutil.cellVal(j.operator_mnc);
		return (m && n) ? (m + ' ' + n) : ''; } },
	{ id: 'lac', text: function(j) { return mutil.decHexPair(j.lac_dec, j.lac_hex); } },
	/* TAC: пара из atdebug-профиля (tac_d/tac_h) главнее общего разбора. */
	{ id: 'tac', text: function(j) {
		return mutil.decHexPair(j.tac_d, j.tac_h) || mutil.decHexPair(j.tac_dec, j.tac_hex); } },
	{ id: 'pathloss', text: function(j) { return mutil.cellVal(j.pathloss); } },
	{ id: 'txpower',  text: function(j) { return mutil.cellVal(j.txpower); } },
	{ id: 'cqi',      text: function(j) { return mutil.cellVal(j.cqi); } },
	{ id: 'uecat',    text: function(j) { return mutil.cellVal(j.uecat); } },
	{ id: 'volte',    text: function(j) { return mutil.cellVal(j.volte); } },
	/* pband всегда видим (базовая строка таблицы): только текст. */
	{ id: 'pband', always: true, text: function(j) {
		var b = mutil.cellVal(j.pband);
		if (!b) { return '-'; }
		var p = mutil.cellVal(j.pci), e = mutil.cellVal(j.earfcn);
		return (p && e) ? (b + ' | ' + p + ' ' + e) : b; } },
	/* eNB ID: на LTE/5G-NSA здесь кнопка 4cells (в ссылку уходит именно eNB).
	   sameRender - чтобы не пересобирать кнопку на каждом тике (скролл-баг). */
	{ id: 'enbid', render: function(j, el, c4) {
		var val = mutil.cellVal(j.enbid);
		/* На LTE/NSA номер БС выводится из CID (eNB = CID>>8, он уже посчитан в
		   c4.num) - профиль метрик мог не отдать enbid на этом тике, а кнопка
		   4cells обязана стабильно жить в ЭТОЙ строке у всех модемов. */
		if (!val && c4 && c4.tech === 3) { val = String(c4.num); }
		setRowVisible(el, !!val);
		if (!val) { el.textContent = '-'; return; }
		if (c4 && c4.tech === 3) {
			if (!sameRender(el, 'enb|' + val + '|' + c4.url)) {
				el.innerHTML = '';
				el.appendChild(mapPinButton(c4, val));
			}
		} else if (!sameRender(el, 'plain|' + val)) {
			/* ЧЕРЕЗ sameRender, а НЕ голым textContent. data-sig живёт на самом
			   элементе: если уйти отсюда текстом, старая подпись кнопки на нём
			   останется, и при возврате тех же данных sameRender скажет «то же
			   самое» - кнопку не пересоберут, останутся голые цифры до F5.
			   Так и было: mcc/mnc на тик пропадают (порт занят - оператор из
			   кэша), c4 становится null, кнопка гаснет НАВСЕГДА. */
			el.textContent = val;
		} } },
	/* Cell ID: кнопка 4cells только на 3G/2G (там ссылка строится по CID). */
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
			el.textContent = t || '-';   /* см. пояснение в строке enbid */
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

/* --- Выбор диапазонов LTE/5G ---
   mmcli --set-current-bands заменяет ВЕСЬ список по всем технологиям
   сразу, поэтому utran/cdma-часть текущего списка сохраняется как есть,
   а заменяются только eutran/ngran (тот же принцип, что в скрипте
   modemband для этого модема). */

/* Показать/скрыть строку-контейнер значения БЕЗ дёрганья высоты страницы при
   мигании данных. Показываем сразу, как появились данные; прячем только после
   нескольких подряд пустых опросов. Иначе кратковременный '-' (парсинг у FM350
   иногда моргает) менял высоту на каждый опрос -> браузер сам скроллил страницу. */
function setRowVisible(view, hasData) {
	var tr = view && view.parentNode;
	if (!tr) { return; }
	if (hasData) {
		tr.style.display = '';
		tr.removeAttribute('data-empty');
		tr.setAttribute('data-hadata', '1');   // данные у строки БЫЛИ
		return;
	}
	/* СТРОКУ, У КОТОРОЙ ДАННЫЕ УЖЕ БЫЛИ, НЕ ПРЯЧЕМ НИКОГДА.
	   Пустой ответ почти всегда означает не «параметра нет», а коллизию на
	   AT-порту: опрос метрик делит tty с SMS, слотами и профилями, и при
	   наложении двух опросчиков поля разом становятся пустыми (замерено).
	   Раньше строка пряталась после 3 пустых подряд - высота страницы
	   уменьшалась, и если пользователь домотал до низа, вьюпорт полз вверх
	   на строку за тик (баг на proton2025: страница «уезжала» до блока
	   «Информация о соте»). Дебаунс тут не спасал: разные строки достигали
	   порога на разных тиках, отсюда и движение по одной строке.
	   Значение при этом сохраняется прежнее (см. вызывающий код) - показать
	   последнее известное честнее, чем мигать прочерком. */
	if (tr.getAttribute('data-hadata') === '1') { return; }
	/* Данных не было НИ РАЗУ - строку можно спрятать: параметра у модема нет. */
	var n = (parseInt(tr.getAttribute('data-empty'), 10) || 0) + 1;
	tr.setAttribute('data-empty', String(n));
	if (n >= 3) { tr.style.display = 'none'; }
}

/* Цвет оценки метрики CA-компонента (пороги как в modemdata). CA_COLOR - для
   ТЕКСТА значения; заливка полосок - градиентом (CA_GRAD), теми же парами
   цветов, что у основных баров CSQ/RSRP/... - единый вид всех шкал. */
var CA_COLOR = { green: '#2fb885', orange: '#c99a3f', red: '#d95c5c' };
var CA_GRAD = {
	green:  'linear-gradient(90deg, #2fb885, #34d399)',
	orange: 'linear-gradient(90deg, #c99a3f, #e6b84c)',
	red:    'linear-gradient(90deg, #d95c5c, #f87171)'
};
function caQuality(key, v) {
	v = parseFloat(v);
	if (isNaN(v)) { return null; }
	switch (key) {
		case 'rsrp': return v >= -80 ? 'green' : (v >= -100 ? 'orange' : 'red');
		case 'rsrq': return v >= -10 ? 'green' : (v >= -15 ? 'orange' : 'red');
		case 'sinr': return v >= 20 ? 'green' : (v >= 0 ? 'orange' : 'red');
		case 'rssi': return v >= -65 ? 'green' : (v >= -85 ? 'orange' : 'red');
	}
	return null;
}

/* Границы шкалы для ДЛИНЫ полоски. Взяты по краям реально встречающихся
   значений, а не по теоретически возможным: с теоретическими полоска почти
   всегда стояла бы у одного края и ничего бы не показывала. */
var METRIC_RANGE = {
	rsrp: [ -125, -70 ],
	rsrq: [ -20, -5 ],
	rssi: [ -100, -60 ],
	sinr: [ -5, 25 ]
};

/* Короткая полоска под значением метрики в таблицах (CA и соседние соты).
   Цвет берёт из caQuality - ТОЙ ЖЕ функции, что красит само число, поэтому в
   ячейке всегда одна оценка, а не две слегка разные. Полоска добавляет то, чего
   у числа нет: насколько значение близко к границе диапазона.
   Большие полоски основных метрик (rsrp_bar и родня) сюда не годятся - они
   привязаны к элементу по id, т.е. синглтоны, а не компонент; и шкала у них
   четырёхуровневая, что разошлось бы с трёхуровневым цветом числа.
   Полоска - БЛОК на всю ширину ячейки: при table-layout:fixed она физически не
   может расширить колонку, поэтому ширина таблицы не едет, а высота прибавляется
   одинаково у всех строк - тех самых прыжков вёрстки не будет. */
/* proton2025 стилизует ШТАТНЫЙ компонент .cbi-progressbar: толстая пилюля 24px
   с подписью ВНУТРИ (::after { content: attr(title) }) - ровно так там выглядят
   основные метрики. В bootstrap тот же класс выглядит иначе: полоска 8px, а
   подпись ::before ВЫШЕ неё с отступом 1.4em - в плотной таблице это разъезжается.
   Поэтому компонент темы берём только на proton2025, а на остальных остаётся
   своя тонкая полоска под числом. */
var IS_PROTON = (function() {
	var base = String((window.L && L.env && L.env.mediaurlbase) || '');
	if (/proton2025/.test(base)) { return true; }
	/* Фолбэк, если mediaurlbase недоступен: ищем подключённую таблицу стилей. */
	return !!document.querySelector('link[href*="proton2025"]');
})();

/* Доля шкалы для ДЛИНЫ полоски (0..100), или null, если значения/оценки нет. */
function metricPct(key, v) {
	var r = METRIC_RANGE[key];
	var n = parseFloat(v);
	if (!r || isNaN(n)) { return null; }
	var pc = Math.round(100 * (n - r[0]) / (r[1] - r[0]));
	if (pc < 4) { pc = 4; }       /* нулевую полоску не видно вовсе */
	if (pc > 100) { pc = 100; }
	return pc;
}

/* Заполнить ячейку метрики числом и полоской. КЛЮЧЕВОЕ: обновляем СУЩЕСТВУЮЩИЕ
   узлы, а не пересоздаём. Только так CSS transition на ширине полоски плавно
   доводит её до нового значения - как у основных метрик. Пересоздание (прежний
   вариант) рисовало новый элемент сразу в финальной ширине, и анимации не было:
   ровно поэтому доп. таблицы «прыгали».
   $4 (text) - необязательная подпись: у антенных портов значение с единицами
   ("-114 dBm"), у CA и соседей - голое число. Оценку и длину считаем по САМОМУ
   значению ($3), не по подписи. IS_PROTON постоянен в сессии, режим не мешаем. */
function paintMetricCell(td, key, v, text) {
	var has = (v != null && v !== '' && v !== '-');
	var txt = has ? String(text != null ? text : v) : '-';
	var col = has ? caQuality(key, v) : null;
	var pc  = col ? metricPct(key, v) : null;

	if (IS_PROTON) {
		/* proton: число ВНУТРИ толстой полоски (тема рисует его из title). */
		if (pc != null) {
			var pb = td.querySelector('.cbi-progressbar');
			if (!pb) {
				td.textContent = '';
				/* box-shadow темы - свечение цветом акцента, под красной/зелёной
				   заливкой чужеродно; гасим точечно. */
				pb = E('div', { 'class': 'cbi-progressbar' }, [ E('div', { 'style': 'box-shadow:none' }) ]);
				td.appendChild(pb);
			}
			pb.setAttribute('title', txt);
			var pf = pb.firstElementChild;
			pf.style.width = pc + '%';
			pf.style.background = CA_GRAD[col] || CA_COLOR[col];
			return;
		}
		td.textContent = txt;   /* нет значения - просто «-» */
		return;
	}

	/* остальные темы: число текстом + тонкая полоска под ним. */
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


/* Построить таблицу «CA по компонентам» из уже имеющихся полей json (pband/sNband
   + метрики serving для PCC). Пер-SCC RSRP/RSRQ/SINR появятся, когда бэкенд начнёт
   их отдавать (jsonполя sNrsrp/...). Блок прячется, если компонентов нет. */
/* Таблица соседних сот. Массив neighbors приходит из опроса метрик - профиль
   собирает его из QMI cell-location-info (intra- и inter-частотные соседи).
   Служебную соту показываем В ТОМ ЖЕ списке, но помечаем: иначе она выглядела бы
   просто самым сильным соседом, и понять, на какой соте мы сидим, было бы нельзя.
   Число соседей меняется само по себе, поэтому строки создаются динамически. */
function renderNeighbors(json) {
	var wrap = document.getElementById('nb-comp');
	var tbl = document.getElementById('nb-table');
	if (!wrap || !tbl) { return; }
	var list = (json && Array.isArray(json.neighbors)) ? json.neighbors : [];
	/* Нет данных - прячем блок целиком: у большинства модемов таких сведений
	   нет вовсе, и пустая таблица только занимала бы место. */
	if (!list.length) {
		/* Пустой опрос почти всегда - коллизия на AT-порту (или мерцание соседей
		   по XMCI), а НЕ исчезновение сот: уже показанный блок НЕ прячем и строки
		   НЕ трогаем, иначе высота документа прыгает и proton2025 (домотанный до
		   низа) обрезает scrollTop - страницу уводит вверх. Правило то же, что в
		   fillAntPorts и setRowVisible: показанное раз - больше не прячем. */
		if (wrap.getAttribute('data-hadata') !== '1') { wrap.style.display = 'none'; }
		return;
	}
	wrap.style.display = '';
	wrap.setAttribute('data-hadata', '1');
	var dash = function(v) { return (v === undefined || v === null || v === '') ? '-' : String(v); };

	/* ЧИСЛО СТРОК НЕ СЖИМАЕМ. У XMM-модемов (L850/L860) XMCI отдаёт то 1, то 2, то
	   0 соседей в соседних опросах (радиообстановка): если пересобирать таблицу под
	   текущее число, высота документа скачет и proton2025 (домотанный до низа)
	   обрезает scrollTop - страницу уводит вверх. Поэтому держим столько строк,
	   сколько было МАКСИМУМ (растёт монотонно), лишние показываем прочерками, а
	   идентичность и уровни каждой строки обновляем НА МЕСТЕ - структура DOM не
	   трогается, высота постоянна. Число соседей мало, «пустых» строк почти нет. */
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
			E('td', { 'class': 'td', 'data-l': 'RSSI', 'data-m': 'rssi' }, [])
		]));
	}
	/* Обновляем ТОЛЬКО реально присутствующих соседей (первые list.length строк).
	   Лишние слоты (сейчас соседей меньше виденного максимума) НЕ трогаем: они
	   держат прогресс-бары и последние значения. Заменять их на текстовый прочерк
	   НЕЛЬЗЯ - ячейка с полоской ВЫШЕ текстовой, строка бы сжималась, а с ней и вся
	   высота документа, и proton2025 (домотанный вниз) обрезал бы scrollTop, уводя
	   страницу вверх. Мерцание XMCI (1<->2<->0 соседей) транзиентно - последнее
	   известное значение честнее скачущей высоты (как при пустом опросе). */
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
		/* Уровни - через общую точку: полоски/цвета/пороги как в CA и антеннах. */
		paintMetricCell(td[4], 'rsrp', c.rsrp);
		paintMetricCell(td[5], 'rsrq', c.rsrq);
		paintMetricCell(td[6], 'rssi', c.rssi);
	}
}

function renderCaTable(json) {
	var tbl = document.getElementById('ca-table');
	var sec = document.getElementById('ca-comp');
	if (!tbl) { return; }
	// Данные по компонентам, разложенные по ключу CC (PCC/SCC1..4).
	var data = {};
	var hasPcc = json.pband && json.pband != '-';
	if (hasPcc) {
		var p = mutil.caSplitBand(json.pband);
		/* Полосу большинство модемов пишет прямо в строку диапазона, и mutil.caSplitBand
		   её оттуда достаёт. Но часть модулей отдаёт её ОТДЕЛЬНОЙ метрикой
		   (json.bandwidth) - раньше это значение вычислялось профилем и молча
		   выбрасывалось вместе с мёртвой переменной ADDON. Используем как запасной
		   источник, когда в строке диапазона полосы нет. */
		data['PCC'] = { band: p.band, bw: p.bw || json.bandwidth, pci: json.pci, earfcn: json.earfcn,
			rsrp: json.rsrp, rsrq: json.rsrq, sinr: json.sinr,
			mimo: json.pmimo, mod: json.pmod };
	}
	[ '1', '2', '3', '4' ].forEach(function(i) {
		var b = json['s' + i + 'band'];
		if (b && b != '-') {
			var sb = mutil.caSplitBand(b);
			data['SCC' + i] = { band: sb.band, bw: sb.bw,
				pci: json['s' + i + 'pci'], earfcn: json['s' + i + 'earfcn'],
				rsrp: json['s' + i + 'rsrp'], rsrq: json['s' + i + 'rsrq'], sinr: json['s' + i + 'sinr'],
				mimo: json['s' + i + 'mimo'], mod: json['s' + i + 'mod'] };
		}
	});
	// Видимость блока привязана к ПОДКЛЮЧЕНИЮ (наличию pband), а НЕ к числу
	// компонентов: переселение соты «одиночная <-> агрегация» блок не трогает,
	// поэтому высота на опрос не меняется. Прячем только при реальном обрыве
	// (pband пуст несколько опросов подряд - дебаунс).
	if (sec) {
		if (hasPcc) {
			sec.style.display = '';
			sec.removeAttribute('data-empty');
			sec.setAttribute('data-hadata', '1');
		} else if (sec.getAttribute('data-hadata') !== '1') {
			// блок ни разу не наполнялся - можно прятать (см. setRowVisible)
			var n = (parseInt(sec.getAttribute('data-empty'), 10) || 0) + 1;
			sec.setAttribute('data-empty', String(n));
			if (n >= 3) { sec.style.display = 'none'; }
		}
	}
	var txt = function(v) { return (v != null && v !== '' && v !== '-') ? String(v) : '-'; };
	var isMetric = { rsrp: 1, rsrq: 1, sinr: 1 };
	function paintCell(td, key, c) {
		/* Метрики - через общую точку: там же решается, как их показывать в
		   текущей теме (см. paintMetricCell). */
		if (isMetric[key]) { paintMetricCell(td, key, c[key]); return; }
		td.textContent = txt(c[key]);
		td.style.color = '';
		td.style.fontWeight = '';
	}
	// Заполняем ЗАРАНЕЕ нарисованные строки (см. разметку). Строки не создаются
	// и не удаляются - только их ячейки. Первая ячейка (метка CC) статична.
	var cols = [ 'band', 'bw', 'pci', 'earfcn', 'rsrp', 'rsrq', 'sinr', 'mimo', 'mod' ];
	tbl.querySelectorAll('tr.ca-row').forEach(function(row) {
		var cc = row.getAttribute('data-cc');
		var c = data[cc] || {};
		var tds = row.querySelectorAll('td');
		cols.forEach(function(k, j) { if (tds[j + 1]) { paintCell(tds[j + 1], k, c); } });

		/* Скрываем строки SCC, по которым данных НЕ БЫЛО НИ РАЗУ - иначе таблица
		   состоит в основном из прочерков. Правило то же, что в setRowVisible, и
		   оно же решает проблему прыгающей вёрстки: строку, у которой данные
		   когда-либо появлялись, НЕ ПРЯЧЕМ БОЛЬШЕ НИКОГДА. Агрегация приходит и
		   уходит (и метрики иногда пустеют из-за коллизий на AT-порту), поэтому
		   прятать по факту текущей пустоты - значит менять высоту на каждом
		   опросе; при этом появление НОВОГО компонента показывается сразу, без
		   задержки. PCC не трогаем: это первичный компонент, он всегда на месте. */
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


/* Чистый билдер кнопок диапазонов - возвращает массив <button>, чтобы
   строить их синхронно прямо в дереве render() (без DOM-манипуляций
   после отрисовки, иначе страница дёргается при загрузке). */

/* Перерисовывать контейнер ТОЛЬКО при реальном изменении данных.
   ЗАЧЕМ. Блок частот перестраивался на КАЖДОМ тике опроса, даже когда диапазоны
   не менялись: renderBandToggles делал innerHTML='' и набивал контейнер заново.
   На долю мгновения контейнер пуст -> высота документа проваливается -> браузер
   ОБРЕЗАЕТ scrollTop до нового максимума -> кнопки возвращаются, высота тоже, а
   прокрутка остаётся обрезанной. Страница уезжала вверх ровно на высоту этих
   контейнеров, на каждый тик.
   Почему это так долго не находилось: замер высоты видит её неизменной (провал
   живёт доли миллисекунды), перехват scrollTop молчит (двигает не JS, а сам
   браузер), а overflow-anchor:none не помогает - это не анкоринг, а клампинг.
   На bootstrap не проявлялось: другая вёрстка скроллера.
   Возвращает true, если данные те же и трогать DOM не нужно. */
/* Рисует ли тема из h3 «шапку» со своими боковыми отступами? Проверяем НАСТОЯЩИМ
   элементом (значения у тем разные, гадать по имени темы - хрупко), один раз и
   до отрисовки страницы, поэтому ничего не мигает. */
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


/* СНЯТЬ строку 3G целиком - и содержимое, и видимость.
   Чистим ЧЕРЕЗ renderBandToggles с пустым списком, а не innerHTML='': он заодно
   обновит подпись кэша (data-sig), иначе следующая НАСТОЯЩАЯ перерисовка была бы
   пропущена как «уже отрисовано». Нужно потому, что путь модема без 3G контейнер
   вообще не трогает, и там оставались тумблеры ПРЕДЫДУЩЕГО модема: на FM350
   показывались диапазоны 3G от Huawei E3372. */


/* ---- Управление диапазонами через modemband (для модемов, у которых mmcli
   не отдаёт бенды: не под ModemManager, или MM их не показывает). Данные и
   применение - вендорными AT-командами через /usr/share/5gmodem/bands.sh. ---- */
/* true, когда bands.sh сказал, что управление диапазонами/режимом СЕЙЧАС
   невозможно (профиль объявил _BAND_VIA=mmcli, а интерфейс на kernel-прото
   mbim/qmi -> модем скрыт от ModemManager). Это авторитетный ответ бэкенда, и
   он ЗАПРЕЩАЕТ mmcli-путь: без флага bandsui.loadBandsModemband() рисовал надпись
   «переключите на ModemManager», а bandsui.revealMgmtWhenReady() тут же дёргал
   mmcli -m any -K, попадал в ЧУЖОЙ модем (FM350 виден MM как failed) и показывал
   его «Режимы сети» с кнопками и пустые «Диапазоны» - блок мигал на каждый опрос.
   (bandSource для этого не годится: в запрещённой ветке он остаётся 'mmcli'.) */
/* true once mmcli has returned a non-empty band list for the active modem; used
   to tell a real "no mmcli bands" modem (FM350) from a transient empty (Compal
   re-registering) so the band block does not flicker. Resets on modem switch
   because the view fully reloads. */
/* Индекс ACTIVE модема в ModemManager (для управления бендами/режимом при
   нескольких модемах). Ставится в load().

   ПУСТО = ModemManager ЭТОТ модем НЕ ведёт (mm_index_for_path сверяет sysfs-путь,
   так что пустой ответ авторитетен). Раньше здесь стоял фолбэк 'any', и mmcli
   молча попадал в ЧУЖОЙ модем: у FM350 (вне MM) рисовались 3G/4G диапазоны от
   E3372, а запись бэндов/режима ушла бы в соседний модем. Все вызовы mmcli ниже
   обязаны проверять mmIdx. */
var mmIdx = '';
/* Протокол интерфейса модема (из json.protocol). В режиме modemmanager бендами
   управляют через mmcli, поэтому пояснение «переключите на ModemManager» там НЕ
   показываем - если mmcli временно не готов (напр. модем пересоздают), это
   транзитное состояние, а не «нельзя управлять». */
var ifaceProtoIsMM = false;
/* READ-ONLY диапазоны: bands.sh отдаёт readonly=1, когда состояние ПРОЧИТАТЬ
   можно (профиль умеет qmicli напрямую по QMI), а ПРИМЕНИТЬ нельзя - для записи
   нужен ModemManager, а на kernel-протоколе его прячет mm-inhibit.sh. */
/* TAKEOVER: bands.sh отдаёт takeover=1, когда диапазоны можно применить, но для
   этого приложение ВРЕМЕННО передаёт модем ModemManager'у (kernel-прото + mmcli-
   профиль, напр. Compal RXM-G1 в MBIM). Кнопки активны, но перед записью
   предупреждаем: связь на минуту прервётся. */
/* Есть ли на устройстве светодиоды уровня сигнала (см. load). */
var ledsAvail = false;
/* USB-путь модема, который показывает ЭТА страница (см. load и applyMetrics).
   Пусто - модемов нет вовсе или конфиг ещё не прочитан: тогда сверять нечего и
   снимки применяются как раньше. */
var pageModemPath = '';
/* Сколько тиков подряд пришли данные ЧУЖОГО модема. Один-два - переключение
   вкладки ещё коммитится, ждём. Больше - активный модем сменился не нами
   (modemswitch.sh resolve при переподключении, второй браузер), и страница
   показывает не тот модем: перезагружаемся, как при клике по вкладке. Без этого
   счётчика страница молча замерла бы навсегда. */
var foreignTicks = 0;


/* ---- Сворачиваемые блоки страницы «Сеть» -------------------------------
   Все блоки, кроме шапки (модем/SIM/сеть/соединение), сворачиваемы и свёрнуты
   по умолчанию. Состояние — в localStorage. Модульный опрос: данные блока
   обновляются/запрашиваются только когда он раскрыт (см. blockExpanded и
   реестр onBlockExpand). */
var onBlockExpand = {};
function blockExpanded(key) {
	try { return localStorage.getItem('5gm-blk-' + key) === '1'; } catch (e) { return false; }
}
function collapsibleSection(key, titleText, content, extraAttrs) {
	var expanded = blockExpanded(key);   // по умолчанию свёрнут
	var chev = E('span', { 'style': 'display:inline-flex;transition:transform .15s ease;transform:rotate(' + (expanded ? '180' : '0') + 'deg)' });
	chev.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg>';
	var body = E('div', { 'style': 'display:' + (expanded ? 'block' : 'none') }, content);
	var title = E('h3', {
		'style': 'display:flex;align-items:center;gap:.35em;cursor:pointer;user-select:none;margin-bottom:' + (expanded ? '.5em' : '0'),
		'click': function() {
			var exp = (body.style.display === 'none');
			body.style.display = exp ? 'block' : 'none';
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
// При раскрытии блока «Управление частотами» подтягиваем данные (пока свёрнут -
// band-функции возвращают сразу, mmcli/bands.sh не дёргаются). bandsui.loadBands/
// bandsui.loadBandsModemband - function declarations, поэтому доступны здесь.
onBlockExpand['freq'] = function() {
	/* Один вход: bandsui.loadBands (mgmtinfo) сам решит, mmcli это или вендорный путь.
	   Раньше дёргались ОБА загрузчика сразу - на MM-модеме вендорный забегал в
	   пустую ветку и прятал ряды, которые mmcli-путь тут же показывал: мигание
	   и «то есть, то нет». */
	if (typeof bandsui.loadBands === 'function') { bandsui.loadBands(); }
};

/* Единая сортировка режимов сети для ВСЕХ модемов: Auto, затем по поколению с
   комбинациями сразу после младшего поколения:
   Auto | 2G | 2G+3G | 3G | 3G+4G | 4G | 4G+5G | 5G.
   Ранг = min_gen*10 + (max_gen-min_gen). Метки в профилях латиницей ("2G"). */

/* Показать блок частот и заполнить кнопки из bands.sh (без mmcli). Режим сети
   (Auto/2G/…) остаётся скрытым - он управляется только через mmcli. */
/* Привязка к соте. Показываем состояние и две операции: привязать к ТЕКУЩЕЙ соте
   (EARFCN и PCI у нас уже есть из метрик - вручную их переписывать никто не станет)
   и снять привязку. Модем при этом уходит в режим полёта и обратно - иначе, по
   мануалу, привязка LTE может не примениться; снятие вступает в силу после
   перезапуска модема, поэтому предупреждаем об обрыве связи. */
/* Агрегация, выключенная в самом модеме: он работает как cat4, и никакая
   настройка диапазонов этого не объясняет. Строку показываем ТОЛЬКО когда
   выключено - когда всё в порядке, лишний ряд ничего не добавляет. */


/* Кнопка «debug» справа в заголовке модема.
 *
 * Нужна только модему, который СЕЙЧАС ведётся своим веб-API (backend=hilink):
 * у него нет AT-портов, а значит нет ни TAC, ни диапазонов, ни USSD. Одно
 * нажатие переводит его в режим с портами. Как только это случилось, кнопка
 * пропадает сама - нажимать её больше не на что, а висящая кнопка «сделай то,
 * что уже сделано» только сбивает с толку.
 */
function renderDebugBtn(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var btn = document.getElementById('dbgmode-btn');
	if (json.backend !== 'hilink') { if (btn) { btn.remove(); } return; }
	if (btn) { return; }
	head.appendChild(E('button', {
		'id': 'dbgmode-btn',
		'class': 'btn cbi-button',
		'style': 'float:right; font-size:70%; padding:.15em .6em; margin-left:.8em;',
		'title': _('Switch the modem into the mode with AT ports: TAC, bands, EARFCN, USSD and the AT console become available. The mode resets when the modem reboots.'),
		'click': ui.createHandlerFn(this, function() {
			setModemBusy(_('Switching the modem into the mode with AT ports…'));
			/* Через autosetup, а не напрямую: он и переключит, и дождётся портов,
			   и восстановит интерфейс - тот же путь, что при подключении модема. */
			fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autosetup',
				(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '') ]);
			/* Перезагрузка, КОГДА debug реально включился (не по слепому таймеру -
			   иначе ловим ещё HiLink посреди свитча). */
			reloadWhenDebugReady();
		})
	}, _('debug')));
}

/* ЧИП ТЕКУЩЕГО ПРОТОКОЛА в правом краю заголовка «Модем». Нужен для тестов:
   с одного взгляда видно, в каком режиме сейчас поднят интерфейс (qmi/mbim/
   modemmanager/fibocom/…), не открывая настройки. Тот же вид «в рамочке», что у
   протокола в карточках профилей. */
/* vid:pid В ЗАГОЛОВКЕ, СЛЕВА ОТ ЧИПА ПРОТОКОЛА.
   Скромным видом, как в карточках «Сохранённых профилей»: мелко и приглушённо -
   это опознание железа, а не заголовок.
   ПОРЯДОК ВСТАВКИ ВАЖЕН: элементы справа - float:right, а они укладываются
   справа налево В ПОРЯДКЕ следования в DOM. Значит наш span нужно добавлять
   ПОСЛЕ чипа - тогда он встанет левее него. Поэтому функция и вызывается
   последней, после renderDebugBtn/renderProtoChip.
   Вертикальную поправку берём ту же, что у чипа: у заголовка большой
   line-height, и без неё строка висела бы выше. */
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
		head.appendChild(el);
	}
	if (el.textContent !== vp) { el.textContent = vp; }
}

function renderProtoChip(json) {
	var head = document.getElementById('modemname');
	if (!head) { return; }
	var chip = document.getElementById('proto-chip');
	/* У HiLink интерфейс всегда dhcp - показываем «HiLink», как в карточке:
	   важно не КАК поднят интерфейс, а что модемом правит его веб-API. */
	var txt = (json.backend === 'hilink') ? 'HiLink'
		: mutil.protoLabel(json.iface_proto || json.protocol);
	if (!txt) { if (chip) { chip.remove(); } return; }
	if (!chip) {
		chip = E('span', {
			'id': 'proto-chip',
			/* Приглушённый: тонкая серая рамка вместо currentColor (та давала
			   жирный тёмный бокс), лёгкий фон, мельче. Это метка, а не кнопка. */
			/* КОМПАКТНЫЙ. float наследовал большой line-height заголовка и бокс
			   растягивался на всю строку - задаём СВОЙ маленький line-height и
			   фикс-размер (.72rem), как у чипа в «Сохранённых профилях». */
			'style': 'float:right; display:inline-block; line-height:1.4;'
				+ 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;'
				+ 'font-size:.72rem; border:1px solid rgba(128,128,128,.35); border-radius:5px;'
				+ 'background:rgba(128,128,128,.1); padding:.05em .45em; margin-left:.8em;'
				+ 'opacity:.7; white-space:nowrap; font-weight:normal;'
				+ 'position:relative; top:.25em;',
			'title': _('Current interface protocol')
		}, '');
		/* Призрак «спрятан от ModemManager» - ВНУТРИ рамки чипа, слева от типа, как в
		   карточках профилей. Держим постоянный узел и лишь переключаем display, а
		   текст протокола - в отдельном узле (обновляем только его). Фикс-размер под
		   line-height чипа, чтобы появление иконки не растягивало строку. */
		chip._ghost = E('img', {
			'src': L.resource('icons/5gmodem/cghost.svg'), 'alt': '',
			'title': _('hidden from ModemManager'),
			'style': 'width:11px; height:11px; margin-right:.3em; opacity:.8;'
				+ 'vertical-align:-1px; display:none; pointer-events:none;'
		});
		chip._label = E('span', {}, '');
		chip.appendChild(chip._ghost);
		chip.appendChild(chip._label);
		head.appendChild(chip);
	}
	if (chip._label.textContent !== txt) { chip._label.textContent = txt; }
	/* Только когда MM работает (иначе прятаться не от кого) и модем реально скрыт
	   (mm_hidden=1: kernel-прото с mm_exclude, а не modemmanager). */
	var hidden = (String(json.mm_running) === '1' && String(json.mm_hidden) === '1');
	chip._ghost.style.display = hidden ? 'inline-block' : 'none';
}

/* APN и тип адреса в правом НИЖНЕМ углу блока «Модем» - тоже для тестов:
   видно, с каким APN и в каком режиме (IPv4/IPv4v6) поднят интерфейс. */
function renderApnLine(json) {
	var el = document.getElementById('apnline');
	if (!el) { return; }
	var apn = String(json.iface_apn || '').trim();
	if (apn === '-') { apn = ''; }
	var pdp = mutil.pdpLabel(json.iface_pdptype);
	if (pdp === '-') { pdp = ''; }
	/* У HiLink APN/тип живут в САМОМ модеме, а не в конфиге dhcp-интерфейса -
	   показывать «-|-» бессмысленно и вводит в заблуждение. at_debug=1 = это
	   HiLink-модем (в т.ч. переведённый в debug): одного backend==='hilink' мало,
	   ведь после закрепления AT-порта backend становится 'dhcp'. Плюс общий
	   случай «оба поля пусты» (в т.ч. пришли как «-»). */
	if (json.backend === 'hilink' || json.at_debug === '1' || (!apn && !pdp)) { el.style.display = 'none'; return; }
	el.style.display = '';
	el.innerHTML = '';
	var mono = 'font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;';
	var row = [
		E('strong', {}, 'APN: '),
		E('span', { 'style': mono }, apn || _('default'))
	];
	/* APN и тип адреса - в ОДНУ строку через разделитель. */
	if (pdp) {
		row.push(E('span', { 'style': 'opacity:.6; margin:0 .4em;' }, '|'));
		row.push(E('span', { 'style': mono }, pdp));
	}
	el.appendChild(E('div', {}, row));
}


/* Есть ли у модема ХОТЬ ОДИН включённый диапазон в любой из полос. Нужно, чтобы
   перезапрос из-за пустого LTE-enabled не молотил вечно у модема, где LTE и нет
   вовсе, а есть только 5G. */

/* force=true - читать МИМО кэша (режим jsonrefresh в bands.sh). Нужен сразу
   после применения маски: обычный json отдаёт кэш со сроком 300 c, и таблица
   ещё десятки секунд показывала бы прежний набор диапазонов. */

/* Переключить интерфейс на ModemManager ПРЯМО из подсказки.
   APN сознательно НЕ передаём: пустой аргумент у mkiface.sh означает «сохранить
   прежний» (см. шапку скрипта), а передать его мимо - значит молча затереть
   настройки. Протокол меняется пересозданием интерфейса, поэтому после успеха
   перечитываем диапазоны: readonly зависит именно от протокола. */
/* Перевести HiLink-модем в режим с AT-портами (Debug) прямо из подсказки блока
   диапазонов. Через autosetup - тот же надёжный путь, что и кнопка «debug» в
   шапке модема и обработка подключения: поднимет DHCP-интерфейс, дождётся
   готовности web-API, переключит в debug, дождётся портов, восстановит
   интерфейс. Соединение при этом сохраняется (сетевая карта та же). */
function switchToDebug(btn) {
	if (btn) { btn.disabled = true; }
	setModemBusy(_('Switching the modem into the mode with AT ports…'));
	fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autosetup',
		(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '') ]);
	reloadWhenDebugReady();
}

/* Перезагрузить страницу, КОГДА debug реально включился, а не по слепому таймеру.
   Раньше стоял фиксированный reload ~25 c, но переключение 14dc->1566 + подъём
   портов + закрепление at_port занимает ~34 c - reload срабатывал ПОСРЕДИ, ловил
   ещё backend=hilink, и карточка «застревала» на HiLink до ручного обновления.
   Опрашиваем cached (тот же путь, что и живой опрос страницы): как только метрики
   пошли по AT (backend != hilink при at_debug=1) - значит debug готов, грузимся.
   Крышка ~55 c на случай, если что-то пошло не так. */
function reloadWhenDebugReady(tries) {
	tries = tries || 0;
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '4' ]), '').then(function(out) {
		var ready = false;
		try { var j = JSON.parse(out || '{}'); ready = (String(j.backend || '').toLowerCase() !== 'hilink') && (j.at_debug === '1'); } catch (e) {}
		if (ready || tries >= 18) { window.location.reload(); }
		else { window.setTimeout(function() { reloadWhenDebugReady(tries + 1); }, 3000); }
	});
}


/* Перевести Fibocom L850/L860 в режим XMM (NCM). Держим на будущее: сейчас у этих
   модемов бенды управляются нативно и в MBIM (свой modemband-профиль), поэтому
   подсказка со сменой режима им не показывается (bandnote скрыт, когда бенды
   читаются). Оставлено для случаев, где родной режим бенды не отдаёт.
   Модем РЕБУТИТСЯ и переэнумерируется (~40 c): бэкенд (modemswitch.sh xmm) шлёт
   GTUSBMODE=0 + CFUN=15, autosetup по маркеру поднимает xmm. */

/* Гасим управление в read-only режиме. Вариант «просто disabled»: кнопка,
   которая молча ничего не делает, хуже её отсутствия, но видеть ТЕКУЩИЙ выбор
   всё равно нужно - поэтому кнопки остаются на месте с подсветкой активных.
   Строку «Применить/Сбросить» прячем целиком: применять нечего.
   Вызывается после каждой перерисовки - sameRender пересобирает кнопки только
   при изменении, а видимость/активность надо восстанавливать всегда. */


/* Ссылка на карту вышек 4cells.ru по данным соты. Подтверждено примерами:
     LTE (tech=3): num = eNB = CID >> 8, lac = TAC (или LAC)
     UMTS(tech=2): num = CID, lac = LAC
     GSM (tech=1): num = CID, без параметра lac
   plmn = MCC + MNC (каждое дополняется до 3 цифр). 5G NSA идёт по LTE-якорю
   (tech=3). Для 5G SA формула пока неизвестна - кнопку не показываем. */
var _c4Last = null;   /* последний ПОЛНЫЙ расчёт: {cid, res} - от дребезга снимков */
function cell4cellsUrl(json) {
	var mcc = parseInt(json.operator_mcc, 10);
	var mnc = parseInt(json.operator_mnc, 10);
	var cid = parseInt(json.cid_dec, 10);
	/* ДРЕБЕЗГ СНИМКОВ: mcc/mnc пропадают на тик (порт занят - оператор из
	   кэша), и кнопка исчезала/прыгала между строками каждые 5 секунд
	   (поймано владельцем на Compal). Сота та же - отдаём прошлый расчёт. */
	if ((isNaN(mcc) || isNaN(mnc)) && _c4Last && _c4Last.cid === cid && cid > 0) {
		return _c4Last.res;
	}
	if (isNaN(mcc) || isNaN(mnc) || isNaN(cid) || cid <= 0) { return null; }

	var lac = parseInt((json.tac_d && String(json.tac_d).length ? json.tac_d : (json.tac_dec || '')), 10);
	if (isNaN(lac)) { lac = parseInt(json.lac_dec || '', 10); }

	var mode = String(json.mode || '').toUpperCase();
	/* Технологию решает ФАКТ, а не только строка mode: она у части модемов
	   моргает («-», пусто, сырой RAT), и кнопка прыгала на строку «ID соты»
	   как для 3G. Живые LTE-признаки в том же снимке (EARFCN/диапазон/eNB)
	   надёжнее моргающей подписи. */
	var lteFact = !!(mutil.cellVal(json.earfcn) || mutil.cellVal(json.pband) || mutil.cellVal(json.enbid));
	var tech, num, needLac = true;
	/* Признак сильнее подписи БЕЗУСЛОВНО: честный 3G-снимок EARFCN/eNB не несёт
	   (профиль чистит их при уходе в 3G), а смешанный «WCDMA + earfcn» - это
	   всегда дребезг соседних тиков. */
	if (lteFact) { mode = 'LTE'; }
	if (mode.indexOf('GSM') >= 0 || mode.indexOf('EDGE') >= 0 || mode.indexOf('GPRS') >= 0 || mode.indexOf('2G') >= 0) {
		tech = 1; num = cid; needLac = false;               // GSM - без lac
	} else if (mode.indexOf('WCDMA') >= 0 || mode.indexOf('UMTS') >= 0 || mode.indexOf('HSPA') >= 0 || mode.indexOf('3G') >= 0) {
		/* UMTS: короткий CID (младшие 16 бит полного 28-битного) + живой LAC из
		   lac_dec (tac_dec в 3G нулевой и давал lac=0). Идеальной формулы для
		   3G НЕТ, два варианта проверены на живой базе и ОТКЛОНЕНЫ (28.07):
		   - «номер площадки» (short без цифры сектора, num=3765): запись в базе
		     есть, но ТОЛЬКО с ЕЁ lac=29600, а живой LAC модема был 29613
		     (граница LA) - совпадение не гарантировано;
		   - без lac вовсе (как у LTE): для tech=2 карта не ищет совсем.
		   Оставлено short-CID + живой lac: хотя бы честные данные модема. */
		tech = 2; num = (cid % 65536);
		var lac3 = parseInt(json.lac_dec, 10);
		if (!isNaN(lac3) && lac3 > 0) { lac = lac3; }
	} else if (mode.indexOf('5G SA') >= 0) {
		return null;                                        // NR SA - формула неизвестна
	} else {                                                // LTE / 5G NSA
		tech = 3; num = Math.floor(cid / 256);
		/* LAC для LTE НЕ передаём. num (eNB) + plmn и так центрируют карту в
		   нужном месте, а точную подсветку даёт lac - но подобрать его нельзя:
		   в базе 4cells он у вышек непоследователен (сота 362058 требует 13600,
		   соседняя 368577 - 136, при одном TAC=136 у сети), а часть модемов
		   (SIMCOM SIM7600) вместо LAC отдаёт сентинель 0xFFFE = «недоступно».
		   Любой lac, что мы пошлём, для многих вышек будет неверным и подсветку
		   не даст - зато верный отсутствующий lac карту не сместит. Поэтому
		   отдаём только num: вышка оказывается на экране, рядом, кликом.
		   У 3G/2G LAC осмысленный и остаётся (см. ветки выше). */
		needLac = false;
	}

	var p3 = function(x) { x = String(x); while (x.length < 3) { x = '0' + x; } return x; };
	var url = 'https://4cells.ru/?plmn=' + p3(mcc) + p3(mnc) + '&tech=' + tech + '&num=' + num;
	if (needLac) {
		if (isNaN(lac)) { return null; }
		url += '&lac=' + lac;
	}
	/* Возвращаем НЕ только ссылку, но и tech с num: кнопку надо повесить на ту
	   строку, чей номер реально уходит в ссылку. На LTE это eNB (cid/256), на
	   3G/2G - сам Cell ID. Иначе кнопка подписана одним числом, а открывает
	   страницу про другое - ровно так и было, пока eNB нигде не показывался. */
	var _c4res = { url: url, tech: tech, num: num };
	_c4Last = { cid: cid, res: _c4res };
	return _c4res;
}

/* Кнопка с пином на карту вышек. Подпись - ТО ЖЕ число, что уходит в ссылку,
   поэтому её ставит на свою строку тот, чей номер использован (см. cell4cellsUrl). */
function mapPinButton(c4, label) {
	return E('button', {
		'class': 'cbi-button',
		'style': 'margin:0;',
		'title': _('View the tower on the 4cells.ru map'),
		'click': function() { window.open(c4.url, '_blank', 'noopener'); }
	}, '\u{1F4CD}' + label);
}


/* Модем мог быть не готов на момент отрисовки: блок управления частотами
   тогда скрыт и пуст. Когда модем появляется, показать строки и заполнить
   кнопки без ручного обновления страницы. Тяжёлый mmcli -K дёргаем только
   пока блок ещё скрыт. */



/* Перезагрузка модема, два режима:
   - soft (CFUN=4->1): перезапуск только радио, без переэнумерации USB. Быстрое
     переподключение к сети, MM сохраняет MBIM-классификацию.
   - hard (CFUN=1,1): полная перезагрузка модема с переинициализацией USB.
     Дольше; на MM-модемах порт может кратко переклассифицироваться. Для случаев,
     когда мягкий рестарт не помог. */
function rebootModem(hard) {
	/* Без confirm и без попапа (решение владельца). Обратная связь:
	   - soft: спиннер на самой кнопке (ui.createHandlerFn держит его, пока
	     команда не ушла) + краткое уведомление;
	   - hard: модем сейчас ПРОПАДЁТ с шины - сразу накрываем блок «Модем»
	     плашкой с прогрессбаром (как на eSIM при смене профиля); pollData сам
	     снимет её, когда модем вернётся в сеть. */
	// Полный цикл: ребут+переэнумерация (~40с) + форс down/up передозвона (~30с),
	// поэтому потолок 90с, иначе прогрессбар «застывал у конца» до передозвона.
	if (hard) { setModemBusy(_('The modem is restarting…'), 90); }
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ hard ? 'hard' : 'soft' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			if (hard) { clearModemBusy(true); }
			ui.addNotification(null, E('p', _('Modem AT port not found')), 'error');
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

/* Аппаратная перезагрузка модема по питанию (GPIO modem_power и т.п.). Кнопка
   показывается только если у платы есть такой GPIO (см. reboot_modem.sh haspower). */
function rebootModemPower() {
	/* Без confirm и без попапа - модем сейчас пропадёт по питанию: сразу
	   плашка с прогрессбаром на блоке «Модем», pollData снимет по возвращении. */
	setModemBusy(_('The modem is restarting…'), 75);
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'power' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			clearModemBusy(true);
			ui.addNotification(null, E('p', _('No modem power GPIO on this board')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification)
			ui.addTimeLimitedNotification(null, E('p', _('The modem is power-cycling. This can take a minute.')), 8000, 'info');
		else
			ui.addNotification(null, E('p', _('The modem is power-cycling. This can take a minute.')), 'info');
	}).catch(function(err) {
		clearModemBusy(true);
		ui.addNotification(null, E('p', _('Failed to power-cycle the modem') + ': ' + (err.message || err)), 'error');
	});
}

/* Показать кнопку «Перезагрузка по питанию», только если у платы есть GPIO
   питания модема. Дёшево: один exec reboot_modem.sh haspower при загрузке. */
function initPowerBtn() {
	var b = document.getElementById('btn-power-reboot');
	if (!b) { return; }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/reboot_modem.sh', [ 'haspower' ]), '').then(function(out) {
		var g = ''; try { g = (JSON.parse(out || '{}').gpio) || ''; } catch (e) {}
		if (g) { b.style.display = ''; }
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


/* ЕДИНИЦЫ ОБЪЁМА ТРАФИКА - НА ЯЗЫК ИНТЕРФЕЙСА.
   Значение приходит УЖЕ СТРОКОЙ ("96.5 MiB"): у обычных модемов её печатает
   ifconfig, у HiLink - hilink.sh. Разбирать и пересобирать число незачем -
   подменяем только суффикс. Двоичные приставки по ГОСТ 8.417: КиБ, МиБ, ГиБ. */

/* Короткая ОСМЫСЛЕННАЯ стадия подключения, пока у модема нет IP - вместо сырых
   строк лога (они длинные, пугающие и на разных языках). Выбираем по состоянию
   модема (регистрация/сигнал) + лёгкая подсказка из conn_status (уже очищенного
   от шума netifd на бэкенде): дозвон -> получение IP. */
function connStageText(json) {
	var reg = String(json.registration || '').trim();
	var sig = String(json.signal || '').trim();
	var cs  = String(json.conn_status || '').toLowerCase();
	var hasSig = sig && sig != '-' && sig != '0';
	if (/roaming.*not allowed|roaming_not_allowed/.test(cs)) { return _('Data roaming is off'); }
	if (reg == '3') { return _('Registration denied'); }
	if (reg != '1' && reg != '5') {                 // ещё не зарегистрирован
		return hasSig ? _('Searching for network…') : _('Initialising modem…');
	}
	// зарегистрирован, но IP ещё нет: дозвон -> получение адреса
	if (/no ip|retry|connected|cgpaddr|address|адрес/.test(cs)) { return _('Obtaining IP…'); }
	return _('Establishing connection…');
}

function updateSimIcon(name) {
	var si = document.getElementById('simicon');
	if (!si) { return; }
	var want;
	if (name == null || String(name).length < 1 || String(name) == '-') {
		want = L.resource('icons/5gmodem/op-nosim.png');   // модем ещё грузится / нет SIM
	} else {
		var ic = mutil.operatorIcon(name);
		want = ic ? L.resource('icons/5gmodem/' + ic + '.png') : L.resource('icons/5gmodem/op-sim.png');
	}
	if (si.getAttribute('src') != want) { si.setAttribute('src', want); }
}


/* Смена режима сети (2G/3G/4G) для modemband-модемов - через вендорную
   AT-команду (bands.sh setmode -> AT+CNMP), не через mmcli. Затем мягкий
   рестарт радио, чтобы модем перерегистрировался в выбранном режиме. */

/* Таблица «Антенные порты». Данные приходят ОБЫЧНЫМ опросом метрик (поле
   antports: "порт:rsrp:rsrq ..."), потому что профиль добирает #LAPS той же
   AT-цепочкой, что и всё остальное - лишних запросов к порту ноль. Раньше здесь
   был отдельный вызов bands.sh + кнопка «Обновить»: и порт дёргали зря (даже
   когда блок свёрнут), и антенну крутить было неудобно - значения не живые.
   Блок показываем только если модем реально ответил: команда вендорная. */
function fillAntPorts(raw, rxdiv) {
	var block = document.getElementById('antports-block');
	var tbl = document.getElementById('antports-table');
	if (!block || !tbl) { return; }

	/* Разнесённый приём: 4rx | 2rx | off. Поле вендорное (Telit #LRXDIV/#4RXDIS),
	   у большинства модемов его нет - тогда строку просто не показываем, а не
	   пишем «неизвестно»: пустое место честнее ложной определённости. */
	var rxl = document.getElementById('rxdiv-line');
	if (rxl) {
		var txt = null, red = false;
		if (rxdiv === '4rx')      { txt = _('Receive diversity: on, 4 receivers (4RX)'); }
		else if (rxdiv === '2rx') { txt = _('Receive diversity: on (2RX)'); }
		else if (rxdiv === 'off') { txt = _('Receive diversity: off - the second antenna is not used'); red = true; }
		if (txt) {
			rxl.style.display = '';
			/* Именно color, а не cssText: опрос идёт раз в несколько секунд, и
			   дописывание в cssText разрасталось бы с каждым тиком. */
			rxl.style.color = red ? '#c00' : '';
			rxl.textContent = txt;
		} else if (rxl.getAttribute('data-hadata') !== '1') {
			/* Показанную строку не убираем: поле вендорное и при коллизии на
			   порту приходит пустым, а исчезающая строка меняет высоту блока. */
			rxl.style.display = 'none';
		}
		if (txt) { rxl.setAttribute('data-hadata', '1'); }
	}
	var rows = String(raw || '').trim().split(/\s+/).filter(function(l) {
		return /^\d+:-?\d+:-?\d+$/.test(l);
	});
	/* Блок, который УЖЕ показывали, не прячем: пустой antports почти всегда
	   означает коллизию на порту, а не исчезновение антенн. Правило то же, что
	   в setRowVisible - иначе целая секция схлопывается и уводит прокрутку. */
	if (!rows.length) {
		if (block.getAttribute('data-hadata') !== '1') { block.style.display = 'none'; }
		return;
	}
	block.style.display = '';
	block.setAttribute('data-hadata', '1');

	/* КАРКАС СТРОИМ ОДИН РАЗ, ДАЛЬШЕ ТОЛЬКО ОБНОВЛЯЕМ ЯЧЕЙКИ.
	   Здесь стояло sameRender по строке значений - и не срабатывало НИКОГДА:
	   в подпись входили сами уровни, а они живые и меняются на каждом опросе
	   (-114 -> -115). Таблица пересобиралась каждый тик через innerHTML='', на
	   долю мгновения становясь пустой: высота документа проваливалась, браузер
	   обрезал scrollTop, и страница уезжала вверх (proton2025, домотано до низа).
	   Подпись каркаса - только НОМЕРА ПОРТОВ: они постоянны, поэтому DOM
	   перестраивается лишь когда портов реально стало больше или меньше. */
	var ports = rows.map(function(l) { return l.split(':')[0]; }).join(',');
	if (!sameRender(tbl, ports)) {
		tbl.innerHTML = '';
		tbl.appendChild(E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th left' }, _('Antenna port')),
			E('th', { 'class': 'th left' }, _('RSRP')),
			E('th', { 'class': 'th left' }, _('RSRQ')),
			E('th', { 'class': 'th left' }, _('State'))
		]));
		rows.forEach(function(l) {
			tbl.appendChild(E('tr', { 'class': 'tr ant-row' }, [
				/* Номер порта - тот, что дал модем. Подписи пигтейлов (PRI/DIV)
				   у каждой платы свои, соответствие не выдумываем. */
				E('td', { 'class': 'td left' }, _('Port %d').format(parseInt(l.split(':')[0], 10))),
				E('td', { 'class': 'td left' }, '-'),
				E('td', { 'class': 'td left' }, '-'),
				E('td', { 'class': 'td left' }, '-')
			]));
		});
	}

	var trs = tbl.querySelectorAll('tr.ant-row');
	rows.forEach(function(l, i) {
		var tr = trs[i];
		if (!tr) { return; }
		var td = tr.querySelectorAll('td');
		var p = l.split(':');
		var rsrp = parseInt(p[1], 10);
		/* Цвета и пороги - ОБЩИЕ с «Агрегацией несущих» (CA_COLOR/caQuality),
		   чтобы -100 dBm означало одно и то же в обеих таблицах. */
		var st, col;
		if (isNaN(rsrp)) {
			st = '-'; col = null;
		} else if (rsrp <= -130) {
			/* Шкала LTE: -44 (отлично) … -140 (ничего). Около -130 и ниже антенны
			   фактически нет - так выглядит неподключённый пигтейл (проверено на
			   LM960: порт без антенны давал -134). Это НЕ «плохой сигнал», а
			   отсутствие антенны - отдельный случай, порогов caQuality тут мало. */
			st = _('antenna: none'); col = 'red';
		} else {
			/* Подпись СЛЕДУЕТ за цветом: зелёный - норма, жёлтый - слабо,
			   красный - плохо. Иначе -102 dBm красился бы красным, а
			   подписывался «слабый сигнал» - две правды в одной строке. */
			col = caQuality('rsrp', rsrp);
			st = (col === 'green') ? _('antenna: normal')
			   : (col === 'orange') ? _('antenna: weak signal')
			   : _('antenna: poor signal');
		}
		/* Через ОБЩУЮ точку (paintMetricCell) - ту же, что у CA и соседних сот:
		   к цвету добавляется полоска, а на proton2025 значение уезжает внутрь
		   неё. Иначе три таблицы с одинаковыми по смыслу уровнями выглядели бы
		   по-разному на одной странице. */
		var paint = function(cell, key, v, text) {
			paintMetricCell(cell, key, v, text);
		};
		if (td[1]) { paint(td[1], 'rsrp', p[1], p[1] + ' dBm'); }
		if (td[2]) { paint(td[2], 'rsrq', p[2], p[2] + ' dB'); }
		if (td[3]) {
			td[3].textContent = st;
			td[3].style.color = col ? CA_COLOR[col] : '';
			td[3].style.fontWeight = col ? '600' : '';
		}
	});
}

/* Выбор комбинации диапазонов 3G (одна из; см. combos3g в bands.sh).
   Как и смена режима сети, требует перезапуска модема - #BND у Telit
   сохраняется в NVRAM и подхватывается при старте. */

/* Кнопки режимов сети показываются только когда модемом управляет
   ModemManager (иначе mmcli недоступен или модем не его) */

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

/* Телефон в вид «+7 (900) 000-00-00» для 11-значных РФ-номеров (7… или 8…).
   Иностранные/непонятные форматы отдаём как есть. */

/* Плавное время соединения: база с модема + локальный досчёт раз в секунду. */
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

/* Блок «нет модема»: СТАТИЧНАЯ карточка с пунктирной рамкой и надписью, БЕЗ
   анимации (решение владельца). Скелетон - обещание «данные едут», а пустой
   ответ listmodems - ФАКТ: на роутере без модемов анимация врала бы вечно.
   Кнопок тут НЕТ намеренно - плашка стабильного размера; ребуты живут во
   вкладке управления частотами. Строится ОДИН раз, дальше показ/скрытие. */
function buildNoModemBlock() {
	return E('div', { 'class': 'cbi-section tginfo', 'id': 'modem-none-block' }, [
		/* Тот же моноширинный заголовок, что и у реальной карточки (#modemname). */
		E('h3', { 'style': 'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; display:flow-root;' }, _('Modem')),
		E('div', { 'class': 'tgm-nomodem' }, _('No modem connected'))
	]);
}

/* Память «модемов нет»: роутер, живущий без модемов, при следующем заходе
   рисует пунктирную карточку СРАЗУ - без секунды скелетона до первого тика
   метрик. Появился модем - флаг снимается тем же тиком. */
function noModemRemember(yes) {
	try {
		if (yes) { window.localStorage.setItem('tgm-nomodem', '1'); }
		else { window.localStorage.removeItem('tgm-nomodem'); }
	} catch (e) {}
}
function noModemRemembered() {
	try { return window.localStorage.getItem('tgm-nomodem') === '1'; } catch (e) { return false; }
}

function applyMetrics(json) {
					/* СНИМОК ЧУЖОГО МОДЕМА НЕ ПРИМЕНЯЕМ.
					   Метрики отдаёт активный модем из конфига, а страница
					   показывает конкретный. Пока переключение вкладки не
					   докоммитилось (или его сделал другой браузер / другая
					   страница), ответ принадлежит СОСЕДУ - и раньше он молча
					   рисовался как свой. Живой отчёт с двумя T99W175 (30.07):
					   у активного модема не было SIM, и человек видел в его
					   карточке данные соседней. Пропускаем тик: следующий придёт
					   через секунды, а показ чужих цифр ничем не исправляется.
					   not_active - явный ответ бэкенда на адресный запрос (for=). */
					var foreign = !!(json && (json.error === 'not_active'
						|| (json.path && pageModemPath && json.path !== pageModemPath)));
					if (foreign) {
						if (++foreignTicks >= 3) {
							foreignTicks = 0;
							/* Перед перезагрузкой СБРАСЫВАЕМ запомненную вкладку:
							   иначе новая страница берёт тот же мёртвый путь и
							   цикл «not_active -> reload» не кончается никогда. */
							try { window.sessionStorage.removeItem('5gm-tab'); } catch (e) {}
							window.location.reload();
						}
						return;
					}
					foreignTicks = 0;

					/* Тик пришёл - порт свободен: запускаем отложенные
					   simslot/bands (см. afterFirstPoll). */
					runAfterFirstPoll();

					/* МОДЕМА НА ШИНЕ НЕТ ВОВСЕ. Метрики отдают error "Device not
					   found" (при хотя бы одном модеме скрипт сам его находит,
					   поэтому пустой active_modem сюда НЕ ведёт). Прячем весь блок
					   «Модем» со всеми метриками и вместо него показываем осмысленную
					   надпись - таблица прочерков смысла не несёт. Ошибку "busy" не
					   трогаем: она преходящая (порт занят другим опросом), мигать
					   «модема нет» на ней нельзя. */
					/* ПРОТУХШИЙ СНИМОК = МОДЕМА НЕТ/НЕ ОТВЕЧАЕТ. При удалении модема
					   cached отдаёт СТАРЫЙ снимок с честным большим age (свежий взять
					   неоткуда) - без этой проверки старые метрики висели бы часами как
					   живые. Порог 30 c безопасен: опрос раз в 5 c со свежестью 4 c
					   держит age присутствующего модема в пределах ~4 c; большой age
					   бывает только когда чтение раз за разом не удаётся. */
					var _age = parseInt(json.age, 10);
					var _stale = (!isNaN(_age) && _age >= 30);
					/* «Модем не подключен» - ТОЛЬКО про отсутствующее железо.
					   Протухший снимок (age>=30) сам по себе - не доказательство:
					   при двух модемах опрос вкладки может встать из-за очереди к
					   порту, age растёт, а модем живой - и карточка врала «не
					   подключен» до ручного обновления (поймано владельцем).
					   Протухание считается отсутствием только когда в снимке нет
					   самого модема и шина его не подтверждает; иначе остаётся
					   живая карточка с песочными часами «данные не обновлялись». */
					var _present = (String(json.onbus) === '1') || !!json.modem;
					var _noModem = (json.error && json.error !== 'busy' && !json.modem) || (_stale && !_present);
					/* onbus=1: модем ЕСТЬ на шине, но не отвечает (залип). onbus=0:
					   убран совсем. Бэкенд кладёт это в ответ «модема нет». */
					var _onbus = (String(json.onbus) === '1');
					var _mib = document.getElementById('modem-info-block');
					var _none = document.getElementById('modem-none-block');
					var _cell = document.querySelector('[data-blk="cell"]');
					var _freq = document.querySelector('[data-blk="freq"]');
					var _ttl = document.querySelector('[data-blk="ttl"]');
					noModemRemember(_noModem && !_onbus);
					if (_noModem) {
						if (_mib) { _mib.style.display = 'none'; }
						/* Сота и TTL без модема пусты - прячем всегда. */
						if (_cell) { _cell.style.display = 'none'; }
						if (_ttl) { _ttl.style.display = 'none'; }
						/* ЗАЛИП (на шине, не отвечает) - оставляем «Управление частотами»:
						   там кнопка ребута по питанию, которой его можно оживить. УБРАН
						   совсем - прячем и его (ребутить нечего), остаётся чистый скелет. */
						if (_freq) { _freq.style.display = _onbus ? '' : 'none'; }
						if (!_none && _mib && _mib.parentNode) {
							_none = buildNoModemBlock();
							_mib.parentNode.insertBefore(_none, _mib);
						}
						if (_none) { _none.style.display = ''; }
						return;   /* метрики не заполняем - заполнять нечем */
					}
					if (_none) { _none.style.display = 'none'; }
					if (_mib) { _mib.style.display = ''; }
					if (_cell) { _cell.style.display = ''; }
					if (_freq) { _freq.style.display = ''; }
					if (_ttl) { _ttl.style.display = ''; }

					/* Строки, которых у ЭТОГО КЛАССА МОДЕМОВ не бывает, убираем
					   совсем. У модемов без AT-портов (HiLink) веб-API не отдаёт
					   ни TAC/LAC, ни состав несущих - это не «данные ещё не
					   пришли», а их отсутствие навсегда, и прочерк заставляет
					   ждать впустую.
					   ДЕЛАТЬ ЭТО НАДО ЗДЕСЬ, а не в render: строки заполняет и
					   показывает именно этот цикл, и однократное скрытие при
					   отрисовке он тут же отменял. */
					if (json.backend === 'hilink') {
						[ 'tacn', 'lacn', 'ca-comp' ].forEach(function(id) {
							var el = document.getElementById(id);
							if (el) { el.style.display = 'none'; }
						});
					}

					// Модем вернулся после ребута (смена слота) -> снимаем оверлей
					// «Модем перезагружается»: признак живого модема - регистрация в
					// сети или ненулевой сигнал.
					if (modemBusyActive()) {
						var _reg = String(json.registration || '');
						var _sig = parseInt(json.signal, 10);
						if (_reg === '1' || (!isNaN(_sig) && _sig > 0)) { clearModemBusy(); }
					}

				/* ЗДЕСЬ БЫЛ «анти-скачок скролла»: если пользователь у низа страницы,
				   после правок DOM вернуть его к низу (scrollTop = scrollHeight).
				   УДАЛЁН - он и был причиной бага на proton2025, а не лекарством.
				   Замер в браузере (MutationObserver + перехват scrollTop) показал:
				     страница 2538→2538 | блок частот 638→638 | скролл 1228→1786
				   то есть высота НЕ менялась вообще, а прокрутку двигал ровно этот
				   код - определение «был у низа» на proton срабатывало ложно, он
				   швырял страницу вниз, и дальше она уезжала рывками.
				   Причину, ради которой он писался (схлопывание строк при пустом
				   опросе), убрали honestly в setRowVisible: строка, у которой данные
				   уже были, больше не прячется, и высота не скачет. Трогать скролл
				   пользователя нам теперь незачем - пусть этим занимается браузер. */

				// Раньше при signal==0 показывался модал и страница сама
				// перезагружалась каждые 5 c - на модемах, медленно поднимающих
				// сеть, это давало бесконечные перезагрузки. Страница и так
				// открывается с пустыми полями и обновляется по опросу.
				/* revealMgmtWhenReady из тика убран (ревью FE#5): он дублировал
				   pollTick и давал два параллельных mgmtinfo с гонкой перерисовки */
				/* Освежаем блок диапазонов раз в ~3 опроса (≈15 c): смена бендов В
				   ФОНЕ (восстановление после ребута, автоприменение в прото) НЕ
				   уведомляет открытую страницу, и подсветка выбранных бендов
				   застревала до ручного F5. bandsui.loadBandsModemband идемпотентен
				   (sameRender не перестраивает при совпадении) и сам работает, только
				   когда блок частот раскрыт; в порт ходит лишь при cache-miss - т.е.
				   как раз после реальной смены, когда bands.sh сбросил кэш, а между
				   сменами отдаёт снимок из кэша. */
				/* ЧЕРЕЗ ЕДИНЫЙ bandsui.loadBands, а не напрямую вендорным загрузчиком: на
			   mmcli-модеме прямой вызов перерисовывал блок ЧУЖИМИ данными -
			   кнопки режимов пересобирались вендорной веткой (другой набор
			   атрибутов), и подсветка активного режима слетала «через
			   несколько тиков», а тумблеры диапазонов моргали пустыми на
			   первом же обновлении. bandsui.loadBands сам маршрутизирует
			   (mgmtinfo: mmcli / vendor / pending). */
			bandsui.pollTick();
				// Антенные порты: данные уже в json, лишних запросов нет.
				fillAntPorts(json.antports, json.rxdiv);

					var icon, wicon, ticon, t;
					var wicon = L.resource('icons/5gmodem/cloading.svg');
					var ticon = L.resource('icons/5gmodem/ctime.svg');
					var dicon = L.resource('icons/5gmodem/cdown.svg');   // скачивание (rx)
					var uicon = L.resource('icons/5gmodem/cup.svg');     // загрузка (tx)

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
						icon = L.resource('icons/5gmodem/mobile-signal-000-000.svg');
					else if (p < 20)
						icon = L.resource('icons/5gmodem/mobile-signal-000-020.svg');
					else if (p < 40)
						icon = L.resource('icons/5gmodem/mobile-signal-020-040.svg');
					else if (p < 60)
						icon = L.resource('icons/5gmodem/mobile-signal-040-060.svg');
					else if (p < 80)
						icon = L.resource('icons/5gmodem/mobile-signal-060-080.svg');
					else
						icon = L.resource('icons/5gmodem/mobile-signal-080-100.svg');

					if (document.getElementById('signal')) {
						var view = document.getElementById("signal");
						// иконка сверху, проценты под ней
						view.innerHTML = String.format('<img src="%s"/><br/><medium>%d%%</medium>', icon, p);
					}

					if (document.getElementById('connst')) {
						var view = document.getElementById("connst");
						/* Опрос идёт раз в 5 c, поэтому счётчик прыгал через 5 секунд.
						   Запоминаем точку отсчёта, а между опросами досчитываем время
						   локально - раз в секунду (см. connTick ниже). Значение с
						   модема остаётся источником истины: каждый опрос переустанавливает
						   базу, так что локальный счёт не может «уехать». */
						_connBase = { sec: parseInt(json.conn_time_sec, 10) || 0, at: Date.now() };
						if (json.conn_time == '' || json.conn_time == '-') {
							_connBase = null;
						/* Пока нет IP - показываем короткую ОСМЫСЛЕННУЮ стадию (по
						   состоянию модема), а не сырую строку лога. connStageText
						   возвращает уже локализованный текст без спецсимволов. */
						var _msg = connStageText(json);
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/> ', wicon)
							+ '<span class="tginfo-connstatus">' + _msg + '</span>';
						}
						else {
						view.innerHTML = String.format('<img style="width: 12px; height: 12px; vertical-align: -1px;" src="%s"/>', ticon) + ' ' + '<span id="conndur" style="font-variant-numeric:tabular-nums">' + mutil.formatDuration(json.conn_time_sec) + '</span> | ' + '<img style="width:11px;height:11px;vertical-align:-1px" src="' + dicon + '"/>\u202f' + mutil.localizeBytes(json.rx) + ' <img style="width:11px;height:11px;vertical-align:-1px" src="' + uicon + '"/>\u202f' + mutil.localizeBytes(json.tx);
						}
					}

					if (document.getElementById('operator')) {
						var view = document.getElementById("operator");
						var _visited = String(json.operator_name || '');
						var _home = String(json.home_operator || '');
						// Роуминг: домашний оператор (симки/eSIM-профиля) отличается от
						// гостевой сети. Показываем "Домашний | Гостевой" (напр.
						// "GigSky | Tele2"), а иконку рисуем от ДОМАШНЕГО оператора.
						var _roam = (json.roaming == '1') || json.registration == '5' || json.registration == '7';
						var _iconName = _visited;
						if (_visited.length <= 1) {
							view.textContent = '-';
						} else if (_roam && _home.length > 1 &&
						           checkOperatorName(_home).toLowerCase() !== checkOperatorName(_visited).toLowerCase()) {
							view.textContent = checkOperatorName(_home) + ' | ' + checkOperatorName(_visited);
							_iconName = _home;
						} else {
							view.textContent = checkOperatorName(_visited);
						}
						updateSimIcon(_iconName);
						/* Подсказка на иконке симки - вместе с самой иконкой, но
						   ТОЛЬКО при изменении: пересборка на каждом тике роняла
						   высоту и уводила прокрутку (см. sameRender). Значения
						   тут меняются раз в жизни модема. */
						var _st = document.getElementById('simtip');
						if (_st && !sameRender(_st, [ json.simslot, json.imsi,
						                             json.iccid, json.imei ].join('|'))) {
							_st.innerHTML = '';
							_st.appendChild(SIMdata(json));
						}
					}

					// Номер приоритетнее: если он есть - показываем номер и прячем
					// «Страну»; если номера нет - вместо него показываем «Страну».
					var _hasPhone = (json.phone && String(json.phone).length > 3 && json.phone != '-');
					if (document.getElementById('phone')) {
						var pv = document.getElementById('phone');
						/* СМЕНА SIM/eSIM-ПРОФИЛЯ: липкость номера сбрасываем.
						   Номер «прилипал» намеренно (пустой CNUM - чаще коллизия
						   порта), но после смены IMSI старый номер уже ЧУЖОЙ: у
						   нового профиля его может не быть вовсе, и липкость
						   вечно показывала бы номер прежнего оператора. */
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
						/* Номер, КОТОРЫЙ УЖЕ ПОКАЗЫВАЛИ, не убираем: он берётся с
						   SIM и сам по себе не пропадает, а пустой ответ - это
						   почти всегда коллизия на порту. Иначе номер подменялся
						   «Страной» и обратно на каждом таком опросе (то же
						   правило, что в setRowVisible). */
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
							// роуминг: показываем как обычную сеть («В сети»), а факт
							// роуминга - иконкой croaming.svg перед текстом.
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
						if (mv && mv != '-') {
							// валидный режим -> показать (частоты в скобках отдельным span).
							// Телефонный ярлык + единый вид "4G | B1 (2100 MHz)".
							var mtext = mutil.formatModeDisplay(mv).replace(/[&<>]/g, function(c) {
								return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
							});
							/* Диапазоны (B3, B40, n78 ...) показываем «кнопкой» - тем же
							   видом, что и переключатели бендов (активный стиль). Частоты
							   «(1800 MHz)», разделители «+»/«/» и ярлык «4G |» остаются
							   ОБЫЧНЫМ текстом СНАРУЖИ кнопки. Оборачиваем бенды ДО частот,
							   чтобы regex частот не задел сгенерированные span'ы. */
							view.innerHTML = mtext
								.replace(/\b([Bn])(\d+)\b/g,
									'<span class="btn cbi-button cbi-button-action important tginfo-band">$1$2</span>')
								.replace(/\(([^)]*)\)/g, '<span class="tginfo-freq">($1)</span>');
						}
						else if (!view.textContent || !view.textContent.trim()) {
							// ещё не было валидного значения -> стабильный placeholder,
							// а НЕ пустая строка (пустой div схлопывался -> шапка меняла
							// высоту и дёргала страницу внизу при флапе модема).
							view.textContent = '-';
						}
						// иначе: пустой/«-» опрос при переподключении модема ИГНОРИРУЕМ и
						// оставляем последнее валидное значение (строка «липкая», высота
						// шапки постоянна -> нет мигания и скачков скролла).
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
						if (!json.modem || json.modem.length <= 1) {
						view.textContent = '-';
						}
						else {
						view.textContent = json.modem;
						}
					}

					// Заголовок блока = полное имя активного модема (моноширинный).
					// Класс дописываем ЗДЕСЬ, а не в само имя: имя расходится по
					// вкладкам и карточкам профилей, где пометка была бы шумом.
					if (document.getElementById('modemname')) {
						var _nm = (json.modem && json.modem.length > 1) ? json.modem : _('Modem');
						if (json.backend === 'hilink') { _nm += ' (HiLink)'; }
						else if (json.at_debug === '1') { _nm += ' (Debug)'; }
						/* Обновляем ТОЛЬКО текстовый span - правые элементы
						   (чип, кнопка debug) при этом не трогаются. */
						var _nt = document.getElementById('modemname-text');
						if (_nt && _nt.textContent !== _nm) { _nt.textContent = _nm; }
						renderDebugBtn(json);
						renderProtoChip(json);
						/* ПОСЛЕ чипа - иначе окажется правее него (см. renderVidPid). */
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
						view.textContent = json.protocol;
						}
					}

					/* МОДЕМ В РАЗЪЁМЕ ПОМЕНЯЛИ - СБРОСИТЬ БЛОК ЧАСТОТ.
					   Состояние блока (какой путь управления, что уже загружено,
					   запрещено ли управление) копится за время жизни страницы и
					   принадлежит КОНКРЕТНОМУ модему. При горячей замене (вынули
					   Telit, воткнули Huawei в тот же разъём) оно оставалось от
					   прежнего: сначала показывались его диапазоны, потом - «в
					   режиме dhcp менять нельзя, переключитесь на ModemManager».
					   Помогала только перезагрузка страницы. Ключ - железо
					   (модель+vid:pid), а не путь: путь при замене тот же. */
					bandsui.hwTick(json);

					/* Флаг MM-прото - ЖИВЬЁМ с каждого тика: на загрузке peek мог
					   не знать iface_proto (или вкладку переключили на другой
					   модем), и false намертво гасил блок частот. Переход
					   false->true снимает гейт и будит reveal mmcli-пути. */
					if (json.iface_proto && json.iface_proto != '-') {
						var _liveMM = (String(json.iface_proto).toLowerCase() === 'modemmanager');
						if (_liveMM && !ifaceProtoIsMM) {
							ifaceProtoIsMM = true;
							bandsui.ungate();
						} else if (!_liveMM) {
							ifaceProtoIsMM = false;
						}
					}

					/* Пояснение в «Управление частотами»: показываем реальный
					   протокол интерфейса (mbim/qmi), чтобы было «Управление
					   невозможно в режиме mbim», а не абстрактный текст. */
					if (document.getElementById('bandnote-text') && json.protocol && json.protocol != '-') {
						/* Fibocom L850/L860 (Intel XMM) - на будущее: если родной режим
						   бенды не отдал, ведём в XMM, а не в ModemManager. У нас сейчас
						   L850 отдаёт бенды и в MBIM (свой modemband-профиль), так что
						   этот note им вообще не показывается - ветка тут для запаса. */
						var xmmCap = (json.xmm_capable === '1');
						var isXmm = (String(json.iface_proto || '').toLowerCase() === 'xmm');
						var isHilink = (String(json.backend || '').toLowerCase() === 'hilink');
						var mmBtn = document.getElementById('bandnote-mm-btn');
						var xmmBtn = document.getElementById('bandnote-xmm-btn');
						var dbgBtn = document.getElementById('bandnote-dbg-btn');
						if (bandsui.isTakeover()) {
							/* Kernel-прото + mmcli-профиль (Compal в MBIM): менять
							   диапазоны МОЖНО - приложение само временно захватит MM.
							   Кнопки переключения протокола не нужны, только предупреждаем. */
							document.getElementById('bandnote-text').textContent =
								_('Changing bands briefly interrupts the connection: the app hands the modem to ModemManager, applies the change and reconnects (up to a minute).');
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						} else if (isHilink) {
							/* HiLink: не «переключите на ModemManager» (это неверно - MM
							   HiLink-модемом не управляет), а «переключите в Debug». Debug
							   даёт AT-порты для диапазонов/режима/USSD, сохраняя связь.
							   Обычно это делает автопереключение при подключении; кнопка -
							   на случай, когда оно не сработало. */
							document.getElementById('bandnote-text').textContent =
								_('Band and network-mode management is not available in HiLink (web API) mode. Switch the modem to Debug mode (button below): it exposes AT ports for bands, network mode and USSD while keeping the connection.');
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = ''; }
						} else if (xmmCap && !isXmm) {
							document.getElementById('bandnote-text').textContent =
								_('Band and network-mode management is not available in %s mode. Switch this modem to XMM mode (button below) to manage bands.').format(json.protocol);
							if (mmBtn) { mmBtn.style.display = 'none'; }
							if (xmmBtn) { xmmBtn.style.display = ''; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						} else {
							/* Два разных случая, и путать их нельзя. Если списки
							   прочитаны (readonly) - честно говорим «показаны, но не
							   меняются»: кнопки на экране есть, и текст «недоступно»
							   противоречил бы им. Если не прочитаны вовсе - прежняя
							   формулировка про недоступность. */
							document.getElementById('bandnote-text').textContent = bandsui.isReadOnly()
								? _('Bands and network mode are shown read-only: in %s mode they can be read but not changed. Switch the interface to ModemManager to manage them.').format(json.protocol)
								: _('Band and network-mode management is not available in %s mode. Switch the interface to ModemManager (in the modem settings) to manage bands.').format(json.protocol);
							if (mmBtn) { mmBtn.style.display = ''; }
							if (xmmBtn) { xmmBtn.style.display = 'none'; }
							if (dbgBtn) { dbgBtn.style.display = 'none'; }
						}
					}

					/* ИНДИКАТОР УСТАРЕВШИХ ДАННЫХ - в правом углу заголовка блока.
					   Метрики читаются из общего снимка (в модем ходит один процесс),
					   поэтому страница может показывать данные чуть старше своего
					   интервала: когда опрос затянулся или его ведёт другой
					   потребитель. Молча показывать старые цифры нельзя - выглядят
					   как живые. Порог 10 c при опросе раз в 5: иначе значок мигал
					   бы на каждом обновлении.
					   В заголовке он ничего не сдвигает: строка существует всегда,
					   а сам значок уходит вправо - высота страницы не меняется и
					   скролл не уезжает. */
					(function() {
						var head = document.getElementById('modemname');
						if (!head) { return; }
						var age = parseInt(json.age, 10);
						var mark = document.getElementById('stale-mark');
						if (isNaN(age) || age <= 10) { if (mark) { mark.remove(); } return; }
						/* ТОЛЬКО ЗНАЧОК, без текста и без возраста (решение владельца):
						   подпись «данные не обновлялись N мин» занимала место в
						   заголовке, а само число ничего не решает - несвежесть либо
						   есть, либо нет. Пояснение остаётся в title при наведении. */
						var txt = _('Data is stale (shown from the last snapshot)');
						if (mark) { return; }
						head.appendChild(E('span', {
							'id': 'stale-mark', 'title': txt,
							/* Та же вертикальная поправка, что у чипа vid:pid
							   (.tginfo-vidpid): заголовок задаёт крупный
							   интерлиньяж, и без top значок висел ВЫШЕ соседних
							   чипов (замечено пользователем). Значение общее с
							   ними, чтобы середины совпадали. */
							'style': 'float:right;opacity:.55;display:inline-flex;align-items:center;' +
							         'position:relative;top:.38rem;margin-left:.8em'
						}, [
							E('img', {
								'src': L.resource('icons/5gmodem/cloading.svg'), 'title': txt, 'alt': '⌛',
								'style': 'width:12px;height:12px'
							})
						]));
					}());

					if (document.getElementById('temp')) {
						var view = document.getElementById("temp");
						var viewn = document.getElementById("tempn");
						var t = json.mtemp;
						if (t == null || t == '' || t == '-' || (!t.length > 1 && t.includes(' '))) {
						/* Градусов нет. У части прошивок (Compal RXM-G1) их не отдаёт
						   НИ ОДНА AT-команда: единственная тепловая - +CEITHERM, и та
						   даёт уровень троттлинга 0-3. Показываем его словом: выдавать
						   уровень за °C нельзя, но и молчать про перегрев не стоит. */
						var lv = parseInt(json.mtherm, 10);
						if (!isNaN(lv) && lv >= 0 && lv <= 3) {
							var lbl = [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv];
							view.textContent = lbl;
							view.title = _('Modem thermal throttling level: %d of 3').format(lv);
							setRowVisible(view, true);
						} else {
							/* Через setRowVisible, а НЕ display='none' напрямую: при
							   коллизии на AT-порту mtemp и mtherm пустеют разом, строка
							   исчезала и высота страницы прыгала (см. setRowVisible).
							   Строку, где температура уже была, он больше не прячет. */
							setRowVisible(view, false);
						}
						}
						else {
						setRowVisible(view, true);
						/* Значение приходит как "32 &deg;C". Нормализуем к
						   ровно одному градусу: раньше два .replace давали
						   "32 °°C" (первый ставил °, второй добавлял ещё один
						   перед C). Берём число и приписываем " °C". */
						var raw = String(t).replace('&deg;', '°');
						var m = raw.match(/-?\d+(?:\.\d+)?/);
						var num = m ? m[0] : raw.replace(/\s*°?\s*C\s*$/, '');
						var txt = m ? (m[0] + ' °C') : raw;   /* для title */
						/* Есть И градусы, И уровень троттлинга (Telit LM960 отдаёт оба:
						   #TEMPSENS=2 -> °C, #TMLVL? -> 0..3) - показываем через запятую.
						   Уровень 0 («норма») не пишем: строка «28 °C, норма» только
						   шумит, а вот «28 °C, перегрев» - важное предупреждение. */
						var lv2 = parseInt(json.mtherm, 10);
						var thermSuffix = '';
						if (!isNaN(lv2) && lv2 >= 1 && lv2 <= 3) {
							thermSuffix = ', ' + [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv2];
							view.title = _('Modem thermal throttling level: %d of 3').format(lv2);
						}
						/* Собираем узлами, а не строкой: букву C надо поднять и
						   уменьшить отдельным элементом.
						   ЧЕРЕЗ sameRender - ОБЯЗАТЕЛЬНО. innerHTML='' на каждом
						   тике опроса обваливает высоту контейнера на доли
						   мгновения, браузер обрезает scrollTop до нового максимума
						   и страница уезжает вверх (proton2025, домотано до низа).
						   Ровно этот баг уже чинили для блока частот - см. sameRender. */
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
						/* Видимость ОБЯЗАТЕЛЬНО возвращаем: раньше её только снимали,
						   и один-единственный опрос с пустым signal (транзиентный
						   провал при занятом AT-порту) прятал шкалу CSQ НАВСЕГДА -
						   до перезагрузки страницы. Выглядело как "было и пропало". */
						view.style.visibility = 'visible';
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

					// 3G-метрики: строки RSCP/Ec-No СПРЯТАНЫ по умолчанию (display:none)
					// и появляются, только когда модем реально на UMTS/HSPA и отдал
					// значение. На LTE/5G остаются скрытыми, чтобы не показывать «-».
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

					/* Строки соты - декларативным реестром CELL_ROWS (см. его
					   определение): единое правило видимости и форматов вместо
					   индивидуальных блоков с разными механизмами. */
					renderCellRows(json);

					/* Строки SCC1..4 в «Информации о соте» убраны — их показывает
					   отдельная CA-таблица ниже (стабильнее, без скачков высоты). */
					/* CA-таблица по компонентам (PCC + активные SCC) */
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
			/* При открытии берём снимок: страница отрисуется сразу, а не через
			   несколько секунд ожидания модема. Если снимок протух, cached сам
			   сделает полный опрос.
			   АДРЕСНО (for=): окно «Меню SIM-карты» показывает IMSI/ICCID/IMEI, и
			   чужой снимок здесь - это в точности жалоба «второй модем показывает
			   симку первого» (отчёт с двумя T99W175, 30.07). */
			var _sArgs = [ 'cached', '10' ];
			if (pageModemPath) { _sArgs.push('for=' + pageModemPath); }
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', _sArgs));
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

			// Тип SIM (USIM/eSIM) - строка скрыта и заполняется асинхронно из
			// simslot.sh. Переключатель СЛОТОВ живёт в шапке страницы (над
			// температурой, см. loadSimSlots), здесь его не дублируем.
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

			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', [ 'status' ]), '').then(function(out) {
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
				return this.error(e);
			})
		},
	}),


	formdata: { threeginfo: {} },
	
	/* render-first: НИЧЕГО не ждём перед отрисовкой.
	   Раньше здесь блокировались: modemswitch.sh mmindex (~0.09 c), затем
	   Promise.all(5gmodem.sh json ~0.58 c, mmcli -K, uci, ttl.sh) - и всё это
	   время страница была ПУСТОЙ. Теперь отдаём пустые данные: render() рисует
	   скелет с прочерками сразу, а значения подставляет первый тик poll (он и
	   так опрашивает всё это каждые 5 c). Тяжёлые вызовы никуда не делись - они
	   ушли с критического пути.
	   mmIdx получаем в фоне: он нужен только кнопкам режимов/бендов, а блок
	   частот ленивый (свёрнут по умолчанию) - к его раскрытию индекс уже есть. */
	load: function() {
		/* Тёплые кэши в localStorage заводятся под ключ модема и раньше жили
		   вечно (см. mutil.lsSweep): чистим то, к чему не обращались месяц. */
		mutil.lsSweep([ 'bands5g2-', 'bands5g-', '5gmodem.esim.active', '5gmodem.ussd.supported',
		                'netpri-pingstate', 'netpri-ssclash-', 'btninfo:' ], 30);
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), '')
			.then(function(idx) { mmIdx = String(idx || '').trim(); });
		/* Есть ли у корпуса светодиоды уровня сигнала. Спрашиваем СКРИПТ, а не
		   сверяем имя платы: у совместимых устройств те же светодиоды бывают под
		   другим board_name, а на LT300 иной ревизии их может не быть - и тогда
		   галочка только вводила бы в заблуждение.
		   ЖДЁМ ответа, а не пускаем запрос «на отвал»: ledsAvail читается прямо
		   в render(), и без ожидания он всегда оказывался ещё false - блок с
		   галочкой не появлялся вообще никогда. (Запрос mmindex выше ждать не
		   нужно: его результат используется позже, на тиках опроса.) */
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			/* ЧИТАЕМ КАТАЛОГ, А НЕ ЗАПУСКАЕМ СКРИПТ.
			   Через запуск это не заработало дважды: fs.exec_direct ходит в
			   /cgi-bin/cgi-exec (тот самый хелпер, что уже отвечал "404
			   Executable not found" в checkPackages), а fs.exec упирается в то,
			   что разрешение на запуск может не примениться. fs.list идёт через
			   ubus file.list, и путь /sys/class/leds разрешён в нашем ACL
			   отдельной строкой ("list") - это самый короткий и надёжный путь.
			   Заодно исчезает запуск процесса на каждое открытие страницы. */
			L.resolveDefault(fs.list('/sys/class/leds'), []),
			/* ТЁПЛЫЙ СТАРТ: последний снимок метрик ЛЮБОГО возраста (peek не
			   трогает ни порт, ни замок - ~10 мс). Повторное открытие рисует
			   последние известные цифры сразу, а не прочерки до первого тика.
			   Модем/порт не задерживают render ни на миллисекунду. */
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'peek' ]), '{}')
		]).then(function(res) {
			/* ЧЕЙ МОДЕМ ПОКАЗЫВАЕТ ЭТА СТРАНИЦА. Вкладка модема = активный модем
			   в конфиге (клик по вкладке делает switch и перезагружает страницу),
			   поэтому путь фиксируем ОДИН раз на жизнь страницы и дальше сверяем
			   с ним каждый снимок - см. applyMetrics. Без этого страница не могла
			   даже заметить, что ей ответили данными соседнего модема. */
			/* ПУТЬ БЕРЁМ ИЗ ОТВЕТА СЕРВЕРА (peek), а не из uci-кэша страницы.
			   uci.js держит СВОЙ снимок конфига: после переключения вкладки
			   (switch меняет active_modem на роутере) он мог остаться прежним, и
			   страница адресовала запросы ПРЕЖНЕМУ модему - обе вкладки рисовали
			   один и тот же модем при верных ответах бэкенда (31.07.2026).
			   peek читает конфиг на роутере и отдаёт path вместе со снимком. */
			var _pk = {};
			try { _pk = JSON.parse(res[res.length - 1] || '{}') || {}; } catch (e) {}
			/* Порядок источников: КЛИКНУТАЯ ВКЛАДКА (sessionStorage, пишет
			   modemtabs перед reload) -> peek с роутера -> uci-кэш. Вывод пути
			   из active делал обе вкладки близнецами: каждая страница честно
			   адресовала запросы активному модему, чей бы таб ни был выбран. */
			var _tabSel = '';
			try { _tabSel = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) {}
			/* ВКЛАДКА ОБЯЗАНА СУЩЕСТВОВАТЬ. Запомненный путь переживал сам модем:
			   вытащили Telit - страница продолжала адресовать ему запросы,
			   получала not_active и перезагружалась по кругу (мигание, прочерки,
			   обрывки кэша; 31.07.2026). Секция вынутого модема паркуется и
			   теряет path - по этому и проверяем. */
			if (_tabSel) {
				var _tabSec = 'm_' + _tabSel.replace(/[^A-Za-z0-9]/g, '_');
				if ((uci.get('5gmodem', _tabSec, 'path') || '') !== _tabSel) {
					_tabSel = '';
					try { window.sessionStorage.removeItem('5gm-tab'); } catch (e) {}
				}
			}
			pageModemPath = String(_tabSel || _pk.path || uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
			/* Контекст для модуля диапазонов: всё, что ему нужно от страницы,
			   передаётся явно - см. шапку bandsui.js. */
			bandsui.init({
				setModemBusy: setModemBusy,
				clearModemBusy: clearModemBusy,
				sameRender: sameRender,
				blockExpanded: blockExpanded,
				/* ключ тёплого кэша блока частот - USB-путь модема страницы */
				pagePath: function() { return pageModemPath; },
				getMmIdx: function() { return mmIdx; },
				isMM: function() { return ifaceProtoIsMM; },
				setMM: function(v) { ifaceProtoIsMM = !!v; }
			});
			try {
				var names = (res[1] || []).map(function(e) { return e.name; });
				/* Нужны все три: на устройстве с одним индикатором показывать
				   настройку «уровень тремя лампочками» бессмысленно. */
				ledsAvail = [ 'white:signal1', 'white:signal2', 'white:signal3' ]
					.every(function(n) { return names.indexOf(n) >= 0; });
			} catch (e) {}
			return [ String(res[2] || '{}'), '', null, '{}' ];
		});
	},

	render: function(res) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		/* Роутер, живущий без модемов (память tgm-nomodem): пунктирную карточку
		   ставим СРАЗУ, не дожидаясь первого тика метрик - иначе при каждом
		   заходе секунду-другую мигал бы обычный блок с прочерками. Ждём
		   появления блока в DOM коротким циклом: render отдаёт дерево, а
		   вставляет его LuCI чуть позже. Ошиблись (модем всё же есть) - первый
		   же тик applyMetrics вернёт всё на место и снимет флаг. */
		if (noModemRemembered()) {
			var _nmTry = 0;
			var _nmTick = function() {
				var _mib = document.getElementById('modem-info-block');
				if (!_mib) {
					if (++_nmTry < 40) { window.setTimeout(_nmTick, 50); }
					return;
				}
				if (document.getElementById('modem-none-block')) { return; }
				_mib.style.display = 'none';
				[ '[data-blk="cell"]', '[data-blk="freq"]', '[data-blk="ttl"]' ].forEach(function(sel) {
					var el = document.querySelector(sel);
					if (el) { el.style.display = 'none'; }
				});
				_mib.parentNode.insertBefore(buildNoModemBlock(), _mib);
			};
			window.setTimeout(_nmTick, 0);
		}
		/* «Приоритет интернета» рисуется ВНУТРИ контента (netpri.mount() ниже),
		   а не вставкой над вкладками - см. mount(). */
		var m, s, o;

		/* Настройка «Отображать Фиксацию TTL» (вкладка «Настройки» - блок «Сеть»).
		   Включена по умолчанию: показываем блок, ПОКА значение явно не '0'. */
		var showTtl = (uci.get('5gmodem', '@5gmodem[0]', 'show_ttl') !== '0');

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

		// протокол интерфейса (modemmanager/mbim/qmi/...) - для логики
		// доступности управления бендами
		/* Именно iface_proto (протокол ИНТЕРФЕЙСА): в protocol лежит канальный
		   протокол данных, и у Compal под ModemManager там 'mbim' - флаг ложно
		   оставался false, и блок частот прятался навсегда с подсказкой
		   «переключите на MM» (хотя интерфейс уже на MM). */
		ifaceProtoIsMM = (String(initjson.iface_proto || initjson.protocol || '').toLowerCase() === 'modemmanager');

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
		// bandsOther: при смене сохраняем только НЕ-управляемые диапазоны (cdma и
		// т.п.); utran теперь управляется своими тумблерами (см. bandsui.applyBands/bandsui.loadBands)
		bandsui.setOther(mmCur.filter(function(b) { return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0 && b.indexOf('utran-') != 0; }));
		var msStyle = mmHasModem ? null : 'display:none';
		// 3G (UTRAN) row is shown only when the modem actually exposes utran bands
		var has3g = mmHasModem && mmSup.some(function(b) { return b.indexOf('utran-') == 0; });
		var modeActive = function(allowed, preferred) {
			return mmModes &&
			       mmModes.allowed == allowed.split('|').sort().join('|') &&
			       (mmModes.pref || '') == (preferred || '');
		};

		// Наполнение блока частот - ЕДИНЫМ путём bandsui.loadBands (bands.sh mgmtinfo):
		// бэкенд сам решает mmcli/вендор. Прежний выбор здесь (по mmK рендера,
		// который при render-first всегда пуст) уводил MM-модем в вендорную
		// ветку с «переключите на MM» и прятал блок навсегда.
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

		/* Последний снимок метрик держим глобально: из него берутся EARFCN и PCI
		   для кнопки «привязать к текущей соте» - переписывать их руками никто
		   не станет, а другого источника этих значений в UI нет. */
		window._lastJson = json;

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


			}
			} /* конец веток по peek-снимку - опрос ниже регистрируем ВСЕГДА */

			/* ОПРОС РЕГИСТРИРУЕТСЯ БЕЗУСЛОВНО. Раньше poll.add жил ВНУТРИ
			   if(!json.error) по peek-снимку: модем занят/не найден в момент
			   открытия страницы - и опрос не регистрировался вовсе, страница
			   навсегда замирала с прочерками до ручного F5 (находка ревью). */
			poll.add(function() {
				/* ЧИТАЕМ СНИМОК, а не опрашиваем модем. В порт ходит ровно один
				   процесс (блокировка в 5gmodem.sh), остальные берут готовые
				   данные - иначе открытая страница, второй браузер и 5gtop
				   конкурируют за AT-порт, и опрос вместо 3.8 c занимает 13.4 c
				   (замерено). Свежесть 4 c при опросе раз в 5 c означает, что
				   обновление всё равно делаем мы, но без второй ходки, если
				   кто-то уже опрашивает. Заполнение - в applyMetrics: оно ОБЩЕЕ
				   с мгновенным применением peek-снимка при открытии страницы. */
				/* TTL по типу модема. У modemmanager-модема опрос дешёвый (mmcli/
				   qmicli, AT-порта нет вовсе) и занимает ~2 c: с ttl=4 тик (раз в
				   5 c) через раз попадал в «снимку 3 c, ещё свежий» - строка
				   агрегации (LTE -> LTE-A под нагрузкой) обновлялась раз в ~10 c
				   вместо каждого тика. ttl=2 даёт честный полный опрос каждый тик.
				   AT-модемам оставляем 4: их опрос ходит в порт, чаще - вреднее
				   (сериализатор и так узкое место). */
				/* for=<путь> - адресный запрос: «метрики ИМЕННО этого модема».
				   Не совпало с активным - бэкенд отвечает not_active мгновенно, не
				   тратя ход в порт на данные, которые страница всё равно не имеет
				   права показать (см. applyMetrics). */
				var _mArgs = [ 'cached', ifaceProtoIsMM ? '2' : '4' ];
				if (pageModemPath) { _mArgs.push('for=' + pageModemPath); }
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', _mArgs), '')
					.then(function(res) {
						/* Пустой ответ (rpcd занят) и битый JSON - штатные
						   транзиенты: тик пропускаем, следующий догонит. Раньше
						   JSON.parse без защиты ронял тик с необработанным
						   исключением (находка ревью). */
						var _mj = null;
						try { _mj = JSON.parse(res); } catch (e) {}
						if (_mj) { applyMetrics(_mj); }
						/* Блок частот освежает ОДИН планировщик - _bandsPollN выше
						   (раз в ~3 опроса). Второй тикающий вызов отсюда только
						   удваивал запросы и гонки перерисовки. */
					});
				});

		} catch (err) {
				ui.addNotification(null, E('p', _('Error: ') + err.message), 'error');
				}
		}

		/* МГНОВЕННОЕ ЗАПОЛНЕНИЕ последним известным снимком (peek из load()).
		   render строит DOM, которого ЕЩЁ НЕТ в документе - getElementById в
		   applyMetrics ничего бы не нашёл, поэтому откладываем на макротаск:
		   к его выполнению LuCI уже вставил вью. Страница открывается сразу
		   заполненной (значения, иконки, соты, CA), первый тик лишь освежит.
		   Пустой peek ({} - модем ни разу не опрашивался) не применяем:
		   затирать скелет нулями хуже честных прочерков. */
		if (initjson && (initjson.modem || initjson.signal)) {
			window.setTimeout(function() { applyMetrics(initjson); }, 0);
		}

		var info = _('').format('');
		m = new form.JSONMap(this.formdata, '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		s.render = L.bind(function(view, section_id) {

			return E([], [

			/* «Приоритет интернета» - первым в контенте страницы (под под-вкладками),
			   виден на всех темах и на мобильном. */
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

			/* display:flow-root СОДЕРЖИТ float:right чип протокола ВНУТРИ заголовка.
			   Без него незакрытый float «протекал» в строку состояния ниже, и
			   правый блок (SIM1/eSIM + температура) обтекал его, уезжая влево на
			   ширину чипа. На proton2025 это не проявлялось, на bootstrap - да. */
			E('h3', { 'id': 'modemname', 'style': 'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; display:flow-root;' }, [
				/* Имя - в ОТДЕЛЬНОМ span, чтобы обновление текста не стирало
				   правые элементы заголовка (чип протокола, кнопка debug). */
				E('span', { 'id': 'modemname-text' }, _('Modem'))
			]),


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
							'src': L.resource('icons/5gmodem/op-nosim.png'),
							'title': _(''),
							'class': 'middle',
						}),
						/* id ОБЯЗАТЕЛЕН: раньше подсказка строилась ровно один раз,
						   при отрисовке страницы, и навсегда оставалась с теми
						   значениями, что были известны в тот момент - то есть с
						   прочерками, ведь IMEI/IMSI/ICCID приходят позже. */
						E('span', { 'id': 'simtip', 'class': 'cbi-tooltip', 'style': 'text-align:left;font-size:80%' }, SIMdata(data)),
					]),
				]),

				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'id': 'sim', 'class': 'tginfo-reg' }, [ '-' ]),
					E('div', { 'id': 'operator', 'class': 'tginfo-op' }, [ '-' ]),
					E('div', { 'id': 'phone', 'class': 'tginfo-phone', 'style': 'display:none' }, [ '' ]),
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

				/* Правая колонка: переключатель SIM-слотов (если их >= 2) НАД
				   температурой. Заполняется асинхронно из simslot.sh. */
				E('div', { 'class': 'tginfo-right' }, [
					E('div', { 'class': 'tginfo-simslot', 'id': 'simslotn', 'style': 'display:none' }, [ '' ]),
					E('div', { 'class': 'tginfo-temp', 'id': 'tempn', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-thermo', 'title': _('Modem temperature') }, [
							E('img', { 'src': L.resource('icons/5gmodem/ctemp.svg'), 'width': '16', 'height': '16', 'alt': _('Modem temperature') })
						]),
						E('span', { 'id': 'temp' }, [ '-' ]),
					]),
				]),
			]),

			/* Правый нижний угол блока: APN и тип адреса интерфейса. Заполняется
			   опросом (renderApnLine), скрыто пока данных нет. */
			E('div', { 'id': 'apnline',
				'style': 'text-align:right; font-size:85%; opacity:.8; margin-top:.35em; display:none;' }, []),
			]),

			/* Второй блок - управление частотами (сворачиваемый) */
			collapsibleSection('freq', _('Frequency management'), [
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
								'class': 'btn cbi-button' + (modeActive(mdef[1], mdef[2]) ? ' tg-current' : ''),
								'data-allowed': mdef[1],
								'data-preferred': mdef[2],
								'click': ui.createHandlerFn(this, function() {
									return bandsui.setNetMode(mdef[1], mdef[2], mdef[0]);
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
				/* Привязка к соте - ниже диапазонов намеренно: тот же механизм
				   чтения-записи через профиль, и порядок получается от общего к
				   частному (сначала диапазон, потом конкретная сота внутри него).
				   Строка скрыта, пока bands.sh не сообщит, что модем это умеет. */
				/* Режим 5G в модеме - ВЫШЕ диапазонов и привязки намеренно: это
				   предусловие для них. Если 5G выключен в прошивке, выбор
				   диапазонов n-й и привязка к соте бесполезны, а причина ничем
				   себя не выдаёт. Строка скрыта, пока профиль не сообщит, что
				   модем умеет этим управлять. */
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
				/* Постоянная подсказка над «Применить» для модемов, у которых смена
				   диапазонов кратко разрывает соединение (FM350: GTACT рвёт PDP,
				   proto переподнимает - IP пропадает на ~15-20 c). Флаг bandwarn
				   приходит из bands.sh (задан в профиле _fibocom_fm350_common);
				   строку показывает bandsui.loadBandsModemband(). */
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
				/* Пояснение, когда управление диапазонами недоступно (напр.
				   Compal RXM-G1 в режиме umbim/uqmi: у прошивки нет AT-команд
				   бенд-лока, а mmcli выключен). Показывается из
				   bandsui.loadBandsModemband(), когда ни mmcli, ни modemband не дали
				   списка бендов. */
				E('tr', { 'class': 'tr', 'id': 'bandnote', 'style': 'display:none' }, [
					/* Первая колонка пустая: подсказка относится ко всему блоку, а
					   не к отдельному параметру, но вёрстку таблицы ломать нельзя -
					   плашка должна стоять во ВТОРОЙ колонке, как значения строк. */
					E('td', { 'class': 'td left', 'width': '33%' }, ' '),
					E('td', { 'class': 'td left' }, [
						/* Стандартная информационная плашка LuCI, а не курсивный
						   текст: это статусное сообщение, и выглядеть оно должно
						   так же, как остальные сообщения интерфейса. */
						E('div', { 'class': 'alert-message info' }, [
							E('p', { 'id': 'bandnote-text', 'style': 'margin:0' },
								_('Band and network-mode switching is unavailable for this modem in the current interface mode. Switch the interface to ModemManager (in the modem settings) to manage bands.')),
							/* Кнопка ПЕРЕКЛЮЧАЕТ САМА, а не ведёт на вкладку «Модем»:
							   отправлять человека делать это руками - лишний шаг. */
							E('div', { 'style': 'margin-top:.6em' }, [
								E('button', {
									'id': 'bandnote-mm-btn',
									'class': 'btn cbi-button cbi-button-action',
									'click': function(ev) {
										ev.preventDefault();
										bandsui.switchToModemManager(ev.target);
									}
								}, _('Switch to ModemManager')),
								/* Альтернатива для Fibocom L850/L860 (Intel XMM). Держим на
								   будущее: у них бенды работают нативно (и в MBIM), поэтому
								   в норме bandnote вообще не показывается. Кнопка всплывёт
								   лишь если родной режим бенды не отдал (xmm_capable=1 и
								   интерфейс не xmm). */
								E('button', {
									'id': 'bandnote-xmm-btn',
									'class': 'btn cbi-button cbi-button-action',
									'style': 'display:none',
									'click': function(ev) {
										ev.preventDefault();
										bandsui.switchToXmm(ev.target);
									}
								}, _('Switch to XMM')),
								/* HiLink-модему НЕ нужен ModemManager - ему нужен режим
								   Debug (AT-порты). Показываем эту кнопку вместо MM, когда
								   backend=hilink: она через autosetup переключает в debug,
								   сохраняя соединение. */
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
				/* Перезагрузка модема - доступна ВСЕГДА (и в mbim, и в
				   modemmanager), независимо от доступности управления бендами. */
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Restart modem') ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
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
						/* Аппаратная перезагрузка по питанию - только на платах с GPIO
						   питания модема (WH3000 Pro и т.п.). Скрыта, показывается из
						   initPowerBtn() после проверки reboot_modem.sh haspower. */
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
			]),

			/* Блок фиксации TTL / hop-limit - на такой же плашке (collapsibleSection),
			   как остальные блоки страницы; по умолчанию свёрнут. Скрывается
			   настройкой «Отображать Фиксацию TTL» (см. showTtl). */
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

			collapsibleSection('cell', _('Cell / Signal Information'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('MCC MNC')]),
					E('td', { 'class': 'td left', 'id': 'mccmnc' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'cidn' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Cell ID')]),
					E('td', { 'class': 'td left', 'id': 'cid' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'tacn' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('TAC')]),
					E('td', { 'class': 'td left', 'id': 'tac' }, [ '-' ]),
					]),
				E('tr', { 'id': 'lacn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('LAC')]),
					E('td', { 'class': 'td left', 'id': 'lac' }, [ '-' ]),
					]),
				/* Расширенные поля соты. Приходят не от всех модемов (у Meig - из
				   AT+SGCELLINFOEX), поэтому строки скрыты, пока значения пустые:
				   на модеме, который их не отдаёт, таблица не обрастает прочерками.
				   Прячем по тому же правилу, что и остальные - строка, у которой
				   данные когда-либо были, больше не скрывается (см. setRowVisible). */
				E('tr', { 'id': 'enbidn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						_('eNB ID'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(base station)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'enbid' }, [ '-' ]),
					]),
				E('tr', { 'id': 'pathlossn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						_('Path loss'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(signal attenuation)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'pathloss' }, [ '-' ]),
					]),
				E('tr', { 'id': 'txpowern', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
						_('TX power'),
						E('div', { 'class': 'tg-sublabel' }, [ _('(modem transmit level)') ]),
					]),
					E('td', { 'class': 'td left', 'id': 'txpower' }, [ '-' ]),
					]),
				E('tr', { 'id': 'cqin', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('CQI')]),
					E('td', { 'class': 'td left', 'id': 'cqi' }, [ '-' ]),
					]),
				E('tr', { 'id': 'uecatn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('UE category')]),
					E('td', { 'class': 'td left', 'id': 'uecat' }, [ '-' ]),
					]),
				E('tr', { 'id': 'volten', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('VoLTE')]),
					E('td', { 'class': 'td left', 'id': 'volte' }, [ '-' ]),
					]),

				E('tr', { 'id': 'csqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('CSQ'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Signal Strength)') ]),
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
					E('div', { 'class': 'tg-sublabel' }, [ _('(Received Signal Strength Indicator)') ]),
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
					E('div', { 'class': 'tg-sublabel' }, [ _('(Reference Signal Receive Power)') ]),
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
					E('div', { 'class': 'tg-sublabel' }, [ _('(Signal to Interference plus Noise Ratio)') ]),
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
					E('div', { 'class': 'tg-sublabel' }, [ _('(Reference Signal Received Quality)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rsrq',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				// 3G-метрики. Спрятаны по умолчанию; показываются только на UMTS/HSPA
				// (строку включает наличие json.rscp / json.ecio в рендере выше).
				E('tr', { 'id': 'rscpn', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSCP'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(Received Signal Code Power, 3G)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rscp',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'ection', 'class': 'tr', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('Ec/No'),
					E('div', { 'class': 'tg-sublabel' }, [ _('(chip energy to noise ratio, 3G)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'ecio',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Primary band (PCC) | PCI & EARFCN')]),
					E('td', { 'class': 'td left', 'id': 'pband' }, [ '-' ]),
					]),
				// Строки «Диапазон CA (SCC1..4)» убраны намеренно: их полностью и
				// стабильнее показывает отдельная CA-таблица ниже (#ca-table).
				// Раньше эти строки появлялись/прятались при (де)агрегации и меняли
				// высоту страницы -> при просмотре снизу её дёргало вверх.

				]),
				/* Детали агрегации несущих (CA) - в ТОМ ЖЕ сворачиваемом блоке, что и
				   метрики. Обёртка #ca-comp прячется, когда нет подключения (см.
				   renderCaTable), скрывая только CA-таблицу внутри блока. */
				E('div', { 'id': 'ca-comp', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Carrier aggregation (per component)')),
					E('table', { 'class': 'table', 'id': 'ca-table' }, [
					E('tr', { 'class': 'tr table-titles ca-head' }, [
						E('th', { 'class': 'th left' }, [ 'CC' ]),
						E('th', { 'class': 'th left' }, [ 'Band' ]),
						E('th', { 'class': 'th' }, [ 'BW' ]),
						E('th', { 'class': 'th' }, [ 'PCI' ]),
						E('th', { 'class': 'th' }, [ 'EARFCN' ]),
						E('th', { 'class': 'th' }, [ 'RSRP' ]),
						E('th', { 'class': 'th' }, [ 'RSRQ' ]),
						E('th', { 'class': 'th' }, [ 'SINR' ]),
						E('th', { 'class': 'th' }, [ 'MIMO' ]),
						E('th', { 'class': 'th' }, [ 'Mod' ]),
					]),
				].concat([ 'PCC', 'SCC1', 'SCC2', 'SCC3', 'SCC4' ].map(function(cc) {
					// Строки рисуются ЗАРАНЕЕ и с прочерками, а опрос лишь заполняет
					// ячейки. Строки НИКОГДА не добавляются/не удаляются, поэтому
					// высота таблицы постоянна и страницу внизу не дёргает при
					// переселении соты (единичная <-> агрегация). Как в 3ginfo-lite.
					// data-l: подпись колонки для мобильной «карточной» раскладки
					// (в @media узкого экрана показывается через ::before).
					return E('tr', { 'class': 'tr ca-row', 'data-cc': cc }, [
						E('td', { 'class': 'td left ca-cc' }, [ cc ]),
						E('td', { 'class': 'td left', 'data-l': 'Band' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'BW' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'PCI' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'EARFCN' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRP' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRQ' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'SINR' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'MIMO' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'Mod' }, [ '-' ]),
					]);
				})))
				]),
				/* Соседние соты - в ТОМ ЖЕ сворачиваемом блоке, что метрики и CA.
				   Обёртка скрыта, пока модем не отдал ни одной соты (см.
				   renderNeighbors): такие данные есть далеко не у каждого модема,
				   и пустая таблица только занимала бы место.
				   В отличие от CA-таблицы строки здесь НЕ создаются заранее:
				   число соседей меняется по обстановке, фиксированного набора
				   (PCC/SCC1..4) тут просто нет. */
				E('div', { 'id': 'nb-comp', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Neighbour cells')),
					E('table', { 'class': 'table', 'id': 'nb-table' }, [
						E('tr', { 'class': 'tr table-titles nb-head' }, [
							E('th', { 'class': 'th left' }, [ _('Cell') ]),
							E('th', { 'class': 'th left' }, [ 'Band' ]),
							E('th', { 'class': 'th' }, [ 'PCI' ]),
							E('th', { 'class': 'th' }, [ 'EARFCN' ]),
							E('th', { 'class': 'th' }, [ 'RSRP' ]),
							E('th', { 'class': 'th' }, [ 'RSRQ' ]),
							E('th', { 'class': 'th' }, [ 'RSSI' ]),
						])
					])
				]),

				/* Сигнал по антенным портам (AT#LAPS у Telit). Есть не у всех
				   модемов: скрыт, пока fillAntPorts() не получит данные. Живёт
				   ВНУТРИ «Информации о соте» тем же под-блоком, что CA и соседи
				   (решение владельца) - отдельная сворачиваемая секция убрана. */
				E('div', { 'id': 'antports-block', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Antenna ports')),
					E('table', { 'class': 'table', 'id': 'antports-table' }, []),
					/* Состояние разнесённого приёма. Стоит ИМЕННО ЗДЕСЬ, потому
					   что без него таблица выше неполна: одинаковые уровни на
					   портах означают «обе антенны работают» только если
					   разнесение включено, иначе второй приёмник просто не
					   задействован. */
					E('div', { 'id': 'rxdiv-line',
						'style': 'display:none;font-size:90%;padding:.4em 0 0 0' }, ''),
					E('div', { 'style': 'font-size:85%;opacity:.75;padding:.4em 0 0 0' },
						_('RSRP/RSRQ measured separately on each LTE antenna port. A port with RSRP near -140 dBm has no antenna connected (or the cable is bad). LTE only: in 3G the table stays empty.'))
				])
			])
		]);
		}, o, this);

		return m.render().then(function(node) {
			// после вставки DOM показать кнопку перезагрузки по питанию, если у
			// платы есть соответствующий GPIO (setTimeout - дать LuCI прикрепить узел)
			window.setTimeout(initPowerBtn, 0);
			return node;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
