'use strict';
'require baseclass';
'require fs';
'require ui';
'require uci';
'require view.modem5g.mutil as mutil';

/* УПРАВЛЕНИЕ ЧАСТОТАМИ И РЕЖИМОМ СЕТИ - второй шаг распила 5gdetail.js.
   Кластер владеет СВОИМ состоянием (источник данных mmcli/modemband, гейты,
   ретраи, takeover) - оно всё переехало сюда и снаружи больше не видно.
   Наружу торчит узкое API (см. return внизу), а всё, что модулю нужно от
   страницы (плашка занятости, sameRender, индекс MM, флаг MM-прото), приходит
   через init(ctx). Флаг MM-прото остался у страницы (его читает и каденция
   опроса) - модуль ходит через ctx.isMM()/ctx.setMM(). */

var ctx = null;

var _bandsAfterBusy = false;

var _bandsRetry = 0;   // попытки дочитать enabled, если модем ответил не сразу   // после снятия плашки перечитать блок диапазонов

var _bandsRetryMax = 3;

var _has3gMM = false;

var _bandsPollN = 0;   // счётчик для редкого авто-освежения блока диапазонов в опросе

var bandsOther = [];

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
	if (ctx.sameRender(cont, prefix + '|' + bands.join(',') + '|' + current.join(','))) { return; }
	cont.innerHTML = '';
	buildBandButtons(bands, current, prefix).forEach(function(btn) {
		cont.appendChild(btn);
	});
}

function clear3gRow() {
	renderBandToggles('bands-3g', [], [], 'utran-');
	var r3 = document.getElementById('bands3gn');
	if (r3) { r3.style.display = 'none'; }
}

/* ТЁПЛЫЙ РЕНДЕР БЕЗ ОЖИДАНИЯ БЭКЕНДА. После распила блок частот заполнялся
   только по цепочке mgmtinfo -> (json) - два последовательных вызова, и при
   переключении вкладок модемов карточка секунды стояла пустой (поймано
   владельцем). Последний УСПЕШНЫЙ набор данных каждого модема сохраняется в
   localStorage (ключ - USB-путь) и рисуется мгновенно при первом заходе;
   живой ответ затем подтверждает или молча поправляет - рендеры идемпотентны
   (sameRender), идентичные данные не перерисовываются и не мигают. */
/* Путь ВЫБРАННОЙ вкладки для читающих вербов bands.sh: блок частот перестаёт
   зависеть от active_modem, и рассинхрон вкладки с активным модемом больше не
   показывает чужие диапазоны (31.07.2026). */
function _bandsFor() {
	var p = (ctx.pagePath && ctx.pagePath()) || '';
	return p ? [ p ] : [];
}

var _bandsWarmed = false;
function _bandsKey() {
	/* КЛЮЧ ВКЛЮЧАЕТ АКТИВНЫЙ МОДЕМ. Без него тёплый кэш был общим на страницу, и
	   после смены вкладки блок «Управление частотами» рисовал диапазоны ПРЕЖНЕГО
	   модема, пока не придут свежие (живой случай 31.07.2026: карточка Telit
	   показывала бенды Compal). uci уже загружен страницей; при отсутствии
	   значения ведём себя как раньше. */
	var am = '';
	try { am = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''; } catch (e) {}
	/* Суффикс версии обесценивает ОТРАВЛЕННЫЕ записи, сделанные до фикса
	   адресации mmcli (в них под ключом одного модема лежали данные другого).
	   Жёсткая перезагрузка страницы localStorage НЕ чистит, поэтому иначе они
	   продолжали бы рисоваться вечно. */
	return 'bands5g2-' + ((ctx.pagePath && ctx.pagePath()) || '') + (am ? ('-' + am) : '');
}
function warmRenderBands() {
	if (_bandsWarmed) { return; }
	_bandsWarmed = true;
	var c = null;
	try { c = JSON.parse(window.localStorage.getItem(_bandsKey()) || 'null'); } catch (e) {}
	if (!c || !c.j) { return; }
	/* СВЕРКА ХОЗЯИНА. Ключа с путём модема мало: запись могла быть сделана, когда
	   бэкенд ещё отдавал чужие данные под этим путём. Модель модема лежит рядом,
	   и несовпадение - повод выбросить кэш, а не рисовать чужие диапазоны. */
	var mdl = '';
	try {
		var ap = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		mdl = uci.get('5gmodem', 'm_' + ap.replace(/[^A-Za-z0-9]/g, '_'), 'model') || '';
	} catch (e) {}
	if (mdl && c.m && c.m !== mdl) {
		try { window.localStorage.removeItem(_bandsKey()); } catch (e) {}
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
		var ap = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
		mdl = uci.get('5gmodem', 'm_' + ap.replace(/[^A-Za-z0-9]/g, '_'), 'model') || '';
	} catch (e) {}
	try { window.localStorage.setItem(_bandsKey(), JSON.stringify({ t: t, j: j, m: mdl })); } catch (e) {}
	mutil.lsTouch(_bandsKey());
}

function loadBands() {
	// Модульный опрос: пока блок «Управление частотами» свёрнут, НЕ дёргаем
	// бэкенд (это ускоряет загрузку). Данные подтянутся при раскрытии
	// (см. onBlockExpand['freq']).
	if (!ctx.blockExpanded('freq')) { return Promise.resolve(); }
	warmRenderBands();
	/* ЕДИНАЯ ТОЧКА ИСТИНЫ - bands.sh mgmtinfo. Бэкенд сам решает, каким путём
	   управляется модем (mmcli или вендорный), фронт только рисует ответ.
	   Раньше решение принималось здесь: страница парсила mmcli, жонглировала
	   bandSource/bandsGated/reveal-циклами - и любая проверка, промахнувшаяся
	   на переходном состоянии (модем пересоздаётся в MM, mmcli пуст секунду),
	   прятала блок «то есть, то нет» до перезагрузки страницы. Ответы:
	     source=mmcli + списки  - рисуем тумблеры, режим из КОНФИГА;
	     source=mmcli + pending - MM ещё собирает модем: держим последнее
	                              известное, следующий опрос дорисует;
	     source=vendor          - вендорный путь (bands.sh json). */
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ 'mgmtinfo' ].concat(_bandsFor())), '{}').then(function(out) {
		var j = {}; try { j = JSON.parse(out) || {}; } catch (e) {}
		/* ОТВЕТА НЕТ - НИЧЕГО НЕ ТРОГАЕМ. fs.exec_direct отдаёт пустую строку,
		   когда вызов не успел (rpcd занят, mmcli подтормаживает под опросом
		   метрик). Раньше пустой ответ означал "source не mmcli" и страница
		   уходила на ВЕНДОРНЫЙ путь: тот перерисовывал тумблеры своими данными,
		   а на следующем тике mmcli отвечал - и всё возвращалось. Отсюда
		   мигание всего ряда 4G/5G («то все выбраны, то ни одного») и слетающая
		   подсветка режима: до неё в вендорной ветке дело просто не доходило. */
		if (!j.source) { return; }
		if (j.source != 'mmcli') { return loadBandsModemband(); }
		if (j.pending) { return; }
		applyMgmtMM(j);
		_bandsRemember('mm', j);
	});
}

function applyMgmtMM(j) {
		bandSource = 'mmcli';
		bandsReadOnly = false; bandsTakeover = false;
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
		/* Подсветка режима - из КОНФИГА (allowedmode/preferredmode интерфейса),
		   а не из живых current-modes: конфиг не мигает на передозвоне и
		   показывает именно ВЫБОР пользователя. Пустой конфиг = Авто. */
		var am = (j.allowedmode || '').split('|').filter(function(x) { return x; }).sort().join('|') || '2g|3g|4g|5g';
		var pm = j.allowedmode ? (j.preferredmode || '') : '5g';
		document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
			var a = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
			var on = (a == am && (b.getAttribute('data-preferred') || '') == pm);
			b.classList.toggle('tg-current', on);
		});
}

var bandSource = 'mmcli';   // 'mmcli' | 'modemband'

var bandsReadOnly = false;

var bandsTakeover = false;

function buildBandButtonsNum(supported, enabled, btype) {
	// 2G-бенды у Huawei называются по частоте (GSM900/1800), а не "B<n>".
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

function renderCaEnabled(state) {
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
}

function render5gMode(state) {
	var row = document.getElementById('mode5gn');
	var cell = document.getElementById('mode5g-cell');
	if (!row || !cell) { return; }
	if (!state) { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	// Норма - SA и NSA вместе. Тогда строка просто отвечает на вопрос «а 5G-то
	// включён?» и ничего не предлагает: кнопку показываем только когда есть что
	// чинить, иначе она превращается в способ случайно себе навредить.
	var full = (state === 'sa+nsa');
	var txt = ({
		'sa+nsa': _('Enabled (SA + NSA)'),
		'sa':     _('Only SA enabled'),
		'nsa':    _('Only NSA enabled'),
		'off':    _('Disabled in modem')
	})[state] || state;

	cell.appendChild(E('span', {
		'style': full ? 'margin-right:.6em' : 'margin-right:.6em; color:#e58a00'
	}, txt));
	if (full) { return; }

	cell.appendChild(E('span', {
		'style': 'opacity:.65; font-size:90%; margin-right:.6em'
	}, _('5G bands and cell lock have no effect until this is enabled')));

	cell.appendChild(E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'click': ui.createHandlerFn(this, function() {
			ctx.setModemBusy(_('Enabling 5G — the modem is restarting its radio…'));
			_bandsAfterBusy = true;
			fs.exec('/usr/share/5gmodem/bands.sh', [ 'set5gmode', 'full' ]);
		})
	}, _('Enable 5G')));
}

function renderCellLock(state) {
	var row = document.getElementById('celllockn');
	var cell = document.getElementById('celllock-cell');
	if (!row || !cell) { return; }
	if (!state) { row.style.display = 'none'; return; }
	row.style.display = '';
	cell.innerHTML = '';

	var parts = String(state).split(' ');
	var locked = (parts[0] === 'cell' || parts[0] === 'arfcn');
	var txt;
	if (!locked) {
		txt = _('Not locked');
	} else if (parts[0] === 'cell') {
		txt = _('Locked to cell: EARFCN %s, PCI %s').format(parts[1], parts[2]);
	} else {
		txt = _('Locked to frequency: EARFCN %s').format(parts[1]);
	}

	// Профиль умеет ЧИТАТЬ привязку, но не менять её (T99W175: запись через
	// AT^LTE_LOCK переживает перезагрузку и снимается только вручную, поэтому
	// без проверки на живом модеме мы её не даём). Кнопки нет - показываем только
	// состояние и прямо говорим почему: молчаливо неработающая кнопка хуже её отсутствия.
	if (parts[parts.length - 1] === 'readonly') {
		cell.appendChild(E('span', { 'style': 'margin-right:.6em' }, txt));
		if (locked) {
			cell.appendChild(E('span', {
				'style': 'opacity:.65; font-size:90%'
			}, _('Read-only for this modem: the lock can be removed with an AT command only')));
		}
		return;
	}

	var run = function(args, msg) {
		// Плашка поверх блока модема, а не модалка: команда уходит в фон (цикл
		// режима полёта дольше таймаута rpcd), и сколько модем будет возвращаться -
		// заранее неизвестно. Плашка снимается по ФАКТУ возвращения (см.
		// clearModemBusy), тогда как модалка закрывалась по угаданным 20 секундам:
		// вернулся раньше - зря ждали, позже - показывали старое состояние.
		ctx.setModemBusy(msg);
		_bandsAfterBusy = true;
		fs.exec('/usr/share/5gmodem/bands.sh', args);
	};

	// СНАЧАЛА КНОПКА (действие), затем состояние («к чему привязан») - единый порядок
	// для всех модемов.
	if (locked) {
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(this, function() {
				return run([ 'setcelllock', 'off' ],
					_('Removing the lock - the modem restarts, connection drops for a while...'));
			})
		}, [ _('Unlock') ]));
	} else {
		/* Соту берём В МОМЕНТ НАЖАТИЯ, а не при отрисовке. Раньше кнопка читала
		   последний снимок метрик, но эта строка рисуется при раскрытии блока
		   диапазонов - опрос метрик к тому времени мог ещё не пройти, и кнопка
		   оставалась заблокированной без объяснений. Свежий запрос заодно
		   гарантирует, что привязываемся к ТЕКУЩЕЙ соте, а не к устаревшей. */
		cell.appendChild(E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function() {
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ]), '')
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

	// Состояние - ПОСЛЕ кнопки и ТОЛЬКО когда привязан: «Не привязан» не пишем,
	// это и так ясно по кнопке «Привязать к текущей соте».
	if (locked) {
		cell.appendChild(E('span', { 'style': 'margin-left:.6em' }, txt));
	}

	// Привязка есть, но САМ МОДЕМ о ней не сообщает - так ведёт себя FM350 после
	// перезагрузки. Показываем запомненное значение и сразу объясняем расхождение,
	// иначе пользователь увидит «привязана», проверит модем и решит, что мы врём.
	if (parts[parts.length - 1] === 'remembered') {
		cell.appendChild(E('span', {
			'style': 'opacity:.65; font-size:90%; margin-left:.6em'
		}, _('(after modem restart the lock stays in effect, but the modem reports it as off)')));
	}
}

function nrC_hasEnabled(j) {
	return ((j.enabled5gnsa || []).length > 0) || ((j.enabled5gsa || []).length > 0);
}

function loadBandsModemband(force) {
	if (!ctx.blockExpanded('freq')) { return Promise.resolve(); }   // модульный опрос
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ force ? 'jsonrefresh' : 'json' ].concat(_bandsFor())), '').then(function(out) {
		var j = {};
		var note = document.getElementById('bandnote');
		try { j = JSON.parse(out) || {}; } catch (e) { if (note) { note.style.display = ''; } return; }
		applyVendorJson(j);
	});
}

function applyVendorJson(j) {
		var note = document.getElementById('bandnote');
		// Считаем управление доступным, только если список поддерживаемых бендов
		// НЕПУСТ. Раньше проверяли !j.supported, но bands.sh отдаёт пустой массив
		// [] (напр. Compal в mbim: mmcli выключен), а ![] === false, и код шёл
		// рисовать строки бендов с прочерком вместо пояснения.
		render5gMode(j.mode5g);
		renderCaEnabled(j.ca_enabled);
		renderCellLock(j.celllock);
		var hasBands = (j.supported && j.supported.length) ||
		               (j.supported5gnsa && j.supported5gnsa.length) ||
		               (j.supported5gsa && j.supported5gsa.length);
		if (j.error || !hasBands) {
			// Транзитный пустой ответ (bands.sh иногда конкурирует с опросом метрик
			// за AT-порт FM350): если бенды уже загружены по modemband-пути, НЕ
			// сносим блок - иначе строки «Режим сети»/диапазоны моргают на каждый
			// опрос (и re-reveal их снова показывает).
			if (bandSource == 'modemband') { return; }
			// Ни mmcli, ни вендорные AT-команды не дали список диапазонов.
			[ 'modeswn', 'bands2gn', 'bands3gn', 'bandsn', 'bands5gn', 'bandsactn', 'bandwarnn' ].forEach(function(id) {
				var e = document.getElementById(id); if (e) { e.style.display = 'none'; }
			});
			// Пояснение «переключите на ModemManager» показываем ТОЛЬКО если
			// интерфейс НЕ modemmanager. В режиме modemmanager пустой список -
			// это временно (mmcli не готов, модем пересоздаётся), а не «нельзя
			// управлять»: mmcli-путь заполнит бенды сам, ждём следующий опрос.
			if (note) { note.style.display = ctx.isMM() ? 'none' : ''; }
			if (ctx.isMM()) { window.setTimeout(revealMgmtWhenReady, 1500); }
			return;
		}
		/* READ-ONLY: состояние читается, но применить его нельзя без ModemManager.
		   Показываем ПРИВЫЧНЫЕ кнопки с подсветкой текущих диапазонов, только
		   неактивными, и оставляем подсказку с кнопкой переключения. Раньше в
		   этом случае bands.sh отдавал пустые списки и блок подменялся текстом -
		   пользователь не видел даже того, что реально включено в модеме. */
		bandsReadOnly = !!j.readonly;
		bandsTakeover = !!j.takeover;
		if (note) { note.style.display = (bandsReadOnly || bandsTakeover) ? '' : 'none'; }
		bandSource = 'modemband';
		/* Диапазоны 3G у modemband-модемов - ВЫПАДАЮЩИЙ СПИСОК, а не галочки.
		   У LTE прошивка принимает битовую маску (любой набор), а у 3G - номер
		   ГОТОВОЙ КОМБИНАЦИИ из таблицы модема (Telit: 2-е поле #BND). Набрать
		   произвольный набор нельзя, поэтому галочки тут врали бы: пользователь
		   снял бы одну, а модем применил бы совсем другой набор. Бэкенд отдаёт
		   combos3g=[{id,label}] + current3g; профиль без 3G их не отдаёт вовсе -
		   тогда строку прячем, как раньше. */
		var row3g = document.getElementById('bands3gn');
		var c3g = document.getElementById('bands-3g');
		if (c3g && j.supported3g && j.supported3g.length) {
			/* MASK-стиль (FM350): галочки произвольного набора, как LTE/NR -
			   применяются общей кнопкой «Применить», а не по клику. Подписи "B1"
			   (без частоты, как у LTE), «Авто» не нужна: все галочки = без
			   ограничения. */
			if (row3g) { row3g.style.display = ''; }
			var sup3g = j.supported3g.map(function(o) { return o.band; });
			var en3g = j.enabled3g || [];
			if (!ctx.sameRender(c3g, sup3g.join(',') + '|' + en3g.join(','))) {
				c3g.innerHTML = '';
				if (sup3g.length) { buildBandButtonsNum(sup3g, en3g, '3g').forEach(function(b) { c3g.appendChild(b); }); }
			}
		} else if (c3g && j.combos3g && j.combos3g.length) {
			if (row3g) { row3g.style.display = ''; }
			/* Пересобираем ТОЛЬКО при изменении (см. sameRender). Строку при этом
			   показываем всегда - видимость и перерисовка это разные вещи. */
			if (!ctx.sameRender(c3g, String(j.current3g) + '|' + j.combos3g.map(function(o){ return o.id; }).join(','))) {
			c3g.innerHTML = '';
			/* Кнопки как у «Режима сети», а НЕ как у LTE: там переключатели (можно
			   отметить любой набор), а комбинация 3G выбирается РОВНО ОДНА - клик
			   сразу применяет её. Подписи длинные («2100 + 1900 + 850») - это
			   нормально, ряд переносится. */
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
			/* Прячем ТОЛЬКО когда 3G не даёт ни один источник. Если mmcli отдал
			   utran-диапазоны, строка уже наполнена рабочими тумблерами - гасить
			   её из-за того, что у AT-профиля нет своих 3G-комбинаций, нельзя. */
			row3g.style.display = 'none';
		}

		/* 2G (GSM) диапазоны - галочки (mask-стиль), подписи "GSM 900/1800".
		   supported2g/enabled2g отдают HiLink-ветка bands.sh (Huawei E3372) и
		   общий JSON-билдер AT-профилей (первый - Quectel EC21, qcfg="band"). */
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
		// Постоянная подсказка о кратком обрыве при смене диапазонов - только для
		// модемов, чей профиль выставил bandwarn (FM350: GTACT рвёт PDP).
		var warnRow = document.getElementById('bandwarnn');
		if (warnRow) { warnRow.style.display = j.bandwarn ? '' : 'none'; }

		/* ГОНКА НА ТОРМОЗНОМ МОДЕМЕ. loadBandsModemband вызывается по раскрытию
		   блока ОДИН раз. Если модем не успел отдать enabled (старый E3372 отвечает
		   на at^syscfgex? не сразу), supported приходит, а enabled пуст - кнопки
		   рисуются невыделенными и застревают, пока блок не свернуть-развернуть.
		   Есть поддерживаемые, но ни одного включённого - почти наверняка неполный
		   ответ: перечитываем через 1.5 с. Настоящий "все выключено" редок, а
		   лишний перезапрос дёшев. */
		if (supLte.length && !enLte.length && !nrC_hasEnabled(j)) {
			// Не вечно: у модема, где ВСЕ LTE-диапазоны реально выключены, пустой
			// enabled - это правда, а не гонка. Обычный потолок - три попытки; после
			// перевода на ModemManager он временно поднят (см. _bandsRetryMax).
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
			// перерисовка - только при изменении (см. sameRender)
			if (!ctx.sameRender(nrC, supNsa.join(',') + '|' + enNsa.join(','))) {
				nrC.innerHTML = '';
				if (supNsa.length) { buildBandButtonsNum(supNsa, enNsa, 'nsa').forEach(function(b) { nrC.appendChild(b); }); }
			}
			// видимость - отдельно от перерисовки: нет 5G, значит строки нет
			if (!supNsa.length && nrRow) { nrRow.style.display = 'none'; }
		}

		// Режим сети (2G/3G/4G) через AT+CNMP (bands.sh getmode/setmode) - для
		// модемов не под ModemManager, где mmcli-переключатель недоступен.
		var modeRow = document.getElementById('modeswn');
		var modeC = document.getElementById('modesw-btns');
		if (modeC && j.modes && j.modes.length) {
			/* Видимость строки и перерисовка кнопок - РАЗНЫЕ вещи: строку
			   показываем всегда, когда режимы есть, а кнопки пересобираем только
			   при изменении (иначе контейнер пустеет каждый тик и браузер
			   обрезает scrollTop - см. sameRender). */
			if (!ctx.sameRender(modeC, String(j.currentmode) + '|' + j.modes.map(function(m){ return m.id; }).join(','))) {
				modeC.innerHTML = '';
				mutil.sortNetModes(j.modes).forEach(function(m) {
					var on = (String(j.currentmode) === String(m.id));
					modeC.appendChild(E('button', {
						'class': 'btn cbi-button' + (on ? ' tg-current' : ''),
						'data-mode': String(m.id),
						'click': function(ev) { ev.preventDefault(); setNetModeAT(m.id, m.label); }
					}, m.label));
				});
			}
			if (modeRow) { modeRow.style.display = ''; }
		} else if (modeRow) {
			modeRow.style.display = 'none';
		}
		applyBandsReadOnly();
		_bandsRemember('vendor', j);
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
			/* MM поднимается не мгновенно (перезапуск службы + регистрация
			   модема), поэтому не дёргаем bands.sh в ту же секунду - иначе
			   получим пустой список и блок мигнёт «нет диапазонов».
			   Одной отложенной попытки МАЛО: модем появляется в mmcli через
			   десятки секунд, а обычный потолок ретраев (3 x 1.5 c) выходил
			   раньше - кнопки диапазонов так и оставались невыделенными до
			   перезагрузки страницы. Поднимаем потолок на это переключение:
			   20 x 1.5 c ~ 30 c, чего хватает на перечисление модема в MM.
			   Как только диапазоны прочитаны, потолок сам вернётся к трём. */
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
			if (btn) { btn.disabled = false; }
			ui.addNotification(null, E('p', _('Could not switch the modem to XMM') + ' ' + d.error), 'error');
			return;
		}
		window.setTimeout(function() { window.location.reload(); }, 50000);
	}).catch(function(err) {
		ui.hideModal();
		if (btn) { btn.disabled = false; }
		ui.addNotification(null, E('p', _('Could not switch the modem to XMM') + ' ' + (err.message || err)), 'error');
	});
}

function applyBandsReadOnly() {
	var ro = bandsReadOnly;
	[ 'bands-lte', 'bands-nr', 'bands-3g', 'modesw-btns' ].forEach(function(id) {
		var c = document.getElementById(id);
		if (!c) { return; }
		c.querySelectorAll('button').forEach(function(b) {
			b.disabled = ro;
			b.style.opacity = ro ? '.55' : '';
			b.style.cursor = ro ? 'not-allowed' : '';
		});
	});
	var act = document.getElementById('bandsactn');
	if (act && ro) { act.style.display = 'none'; }
}

/* Применить/сбросить диапазоны через modemband */
function applyBandsModemband(reset, confirmed) {
	/* TAKEOVER: запись потребует временно отдать модем ModemManager'у и передёрнуть
	   интерфейс - связь на ~минуту прервётся. Предупреждаем и ждём подтверждения. */
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
		// 3G/2G только в mask-стиле (data-btype): combos/utran применяются иначе.
		document.querySelectorAll('#bands-3g .cbi-button-action[data-btype="3g"]').forEach(function(b) { three.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-2g .cbi-button-action[data-btype="2g"]').forEach(function(b) { two.push(b.getAttribute('data-band')); });
		if (!lte.length && !nsa.length && !three.length && !two.length) {
			ui.addNotification(null, E('p', _('Select at least one band')), 'error');
			return Promise.resolve();
		}
	}
	/* Индикатор ожидания здесь НЕ показываем. Правило общее для всего блока:
	   ждать показываем только там, где перезапуск модема ДЕЙСТВИТЕЛЬНО
	   происходит и его вызываем мы сами (см. applyBands - там reboot_modem.sh).
	   На этих модемах маска применяется живьём, радио не уходит, и плашка просто
	   висела бы положенный минимум в 8 секунд на пустом месте - ровно это и
	   наблюдалось. Модалка была тем же злом, только ещё и блокирующим. */
	var hasLte = document.querySelector('#bands-lte .cbi-button') != null;
	var hasNsa = document.querySelector('#bands-nr .cbi-button') != null;
	// 3G/2G-маска присутствует только когда есть галочные кнопки (data-btype).
	var hasThree = document.querySelector('#bands-3g [data-btype="3g"]') != null;
	var hasTwo = document.querySelector('#bands-2g [data-btype="2g"]') != null;
	var p = Promise.resolve();
	if (hasLte) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands', reset ? 'default' : lte.join(' ') ]); }); }
	if (hasNsa) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands5gnsa', reset ? 'default' : nsa.join(' ') ]); }); }
	// Снятие ВСЕХ 3G/2G-галочек не применяем (пустой набор = no-op у API/GTACT;
	// чтобы выключить RAT целиком - режим сети).
	if (hasThree && (reset || three.length)) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands3g', reset ? 'default' : three.join(' ') ]); }); }
	if (hasTwo && (reset || two.length)) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands2g', reset ? 'default' : two.join(' ') ]); }); }
	// Перезапуск радио модема (CFUN=4->1) ТЕПЕРЬ ДЕЛАЕТ САМ bands.sh - внутри той
	// же фоновой подоболочки, СТРОГО ПОСЛЕ записи маски. Раньше reboot дёргали
	// отсюда, но setbands фоновая и возвращается мгновенно: перезапуск обгонял
	// запись, модем поднимался на старом наборе, и отключённый диапазон
	// оставался активным (воспроизведено на SIM7600: снятый B7 не отключался).
	return p.then(function() {
		/* Читаем МИМО кэша: setbands только что сменил маску, а обычный json
		   отдал бы прежний снимок (кэш живёт 300 c) - именно так таблица и
		   показывала старый набор диапазонов ещё десятки секунд. */
		return loadBandsModemband(true);
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

/* Подсветить активную кнопку режима сети по выводу mmcli -K */

function revealMgmtWhenReady(tries) {
	/* Оставлен как совместимая обёртка: единый loadBands (mgmtinfo) сам решает,
	   показывать ли ряды и каким путём. Прежний reveal-цикл с собственным
	   парсингом mmcli конфликтовал с загрузчиками (показывал/прятал наперегонки). */
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
	/* Плашка вместо модалки - то же поведение, что у modemband-ветки выше и у
	   привязки к соте: страница остаётся рабочей, а ожидание заканчивается по
	   ФАКТУ возвращения модема, а не по угаданным секундам. */
	/* Без цели в MM запись ушла бы в ЧУЖОЙ модем - это опаснее, чем ничего не
	   сделать. */
	if (!ctx.getMmIdx()) {
		ui.addNotification(null, E('p', _('ModemManager does not manage this modem')), 'error');
		return Promise.resolve();
	}
	/* БЕЗ ПЛАШКИ И БЕЗ РЕСТАРТА РАДИО.
	   Здесь ModemManager-путь: mmcli применяет набор ЖИВЬЁМ за ~0.1 c, модем
	   остаётся connected (замерено на Compal - соединение и интерфейс не
	   вздрагивают, модем сам перецепляется на разрешённые частоты). Рестарт
	   радио тут был мёртвым кодом: AT-порт MM-модема нам не принадлежит, и
	   reboot_modem.sh неизменно отвечал «AT port not found». Плашка же честно
	   ждала «возвращения модема», которого не происходило, - отсюда чёрный
	   прямоугольник на полминуты вместо карточки. Просто применяем и
	   перечитываем блок. */
	return fs.exec('/usr/bin/mmcli', [ '-m', ctx.getMmIdx(), '--set-current-bands=' + bandsOther.concat(sel).join('|') ]).then(function(res) {
		if (res.code !== 0) {
			ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (res.stderr || res.stdout || '')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Bands applied, refreshing…')), 4000, 'info');
		}
		/* Мимо кэша: набор только что изменился. Небольшая пауза - модему нужен
		   момент, чтобы отдать новый current-bands. */
		window.setTimeout(loadBands, 1200);
		window.setTimeout(loadBands, 4000);
	}).catch(function(err) {
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

function resetBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(true); }
	document.querySelectorAll('#bands-3g .cbi-button, #bands-lte .cbi-button, #bands-nr .cbi-button').forEach(function(b) {
		b.classList.add('cbi-button-action', 'important');
	});
	return applyBands();
}

function setNetMode(allowed, preferred, label) {
	if (!ctx.getMmIdx()) {   // см. ctx.getMmIdx(): иначе режим уехал бы соседнему модему
		ui.addNotification(null, E('p', _('ModemManager does not manage this modem')), 'error');
		return Promise.resolve();
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	/* Через bands.sh setmodemm, а НЕ голый mmcli: смена режима рвёт регистрацию,
	   netifd передозванивается и сбрасывал бы режимы в «авто» (выбранный 3G
	   слетал через 10 секунд). setmodemm пишет allowedmode/preferredmode в
	   конфиг интерфейса - прото передаёт их при каждом дозвоне, выбор держится.
	   «Авто» = default: опции удаляются, модем возвращается к полному набору. */
	var isAuto = (allowed == '2g|3g|4g|5g' && preferred == '5g');
	var args = isAuto ? [ 'setmodemm', 'default' ]
		: (preferred ? [ 'setmodemm', allowed, preferred ] : [ 'setmodemm', allowed ]);
	return fs.exec('/usr/share/5gmodem/bands.sh', args).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
			}
			/* Смена режима = передёргивание интерфейса (~10-20 c): одного
			   раннего обновления не хватало - mgmtinfo отвечал pending, и
			   подсветка оставалась пустой. Несколько заходов покрывают всё окно. */
			/* updateModeButtons живёт в 5gdetail и здесь не виден (был ReferenceError,
			   ревью №10) - подсветку освежает наш же loadBands */
			[ 2000, 8000, 16000, 25000 ].forEach(function(t) { window.setTimeout(loadBands, t); });
		} else {
			ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

function setNetModeAT(id, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	/* Перезапуск радио (если он вообще нужен этому модему) теперь делает сам
	   bands.sh setmode - после записи и только когда профиль его требует. На
	   SIM7600 AT+CNMP применяется вживую, а CFUN его откатывает, поэтому UI
	   больше не дёргает reboot_modem.sh. */
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setmode', String(id) ]).then(function() {
		ui.hideModal();
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
	// Реконнект (soft) делает САМ bands.sh в фоне после записи - как для setbands.
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands3g', String(id) ]).then(function() {
		ui.hideModal();
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

/* --- ИНТЕГРАЦИОННЫЕ ТОЧКИ (вызываются из 5gdetail) ------------------------- */

/* Модем вернулся из «занят» (clearModemBusy): перечитать блок ТЕМ ЖЕ путём,
   которым он был заполнен, минуя кэш - состояние радио только что менялось. */
function onModemBusyCleared() {
	if (!_bandsAfterBusy) { return; }
	_bandsAfterBusy = false;
	if (bandSource === 'modemband') { loadBandsModemband(true); } else { loadBands(); }
}

/* Тик опроса метрик: освежать блок частот раз в ~3 тика. */
function pollTick() {
	if ((_bandsPollN = (_bandsPollN + 1) % 3) === 0) { loadBands(); }
}

/* Смена ЖЕЛЕЗА в том же разъёме (сигнатура модель+vidpid из снимка метрик):
   всё bands-состояние принадлежит конкретному модему - сбрасываем и перечитываем. */
function hwTick(json) {
	var hw = String(json.modem || '') + '|' + String(json.vidpid || '');
	if (hw !== '|' && window.__hwSig && window.__hwSig !== hw) {
		bandsReadOnly = false; bandsTakeover = false;
		bandSource = 'mmcli';
		_bandsRetry = 0; _bandsRetryMax = 3;
		[ 'bands-3g', 'bands-lte', 'bands-nr', 'bands-2g', 'modesw-btns' ].forEach(function(id) {
			var c = document.getElementById(id);
			if (c) { c.innerHTML = ''; c.removeAttribute('data-sig'); }
		});
		window.setTimeout(loadBands, 300);
	}
	if (hw !== '|') { window.__hwSig = hw; }
}

/* Переход прото в modemmanager (ловит applyMetrics): разбудить mmcli-путь. */
function ungate() {
	window.setTimeout(revealMgmtWhenReady, 500);
}

/* Диапазоны ДРУГИХ RAT из mmcli-ветки рендера: applyBands обязан сохранять их
   при записи (mmcli принимает полный список). */
function setOther(list) { bandsOther = list || []; }

return baseclass.extend({
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
	render5gMode: function(st) { return render5gMode(st); },
	renderCaEnabled: function(st) { return renderCaEnabled(st); },
	onModemBusyCleared: onModemBusyCleared,
	pollTick: pollTick,
	hwTick: hwTick,
	ungate: ungate,
	setOther: setOther,
	isTakeover: function() { return bandsTakeover; },
	isReadOnly: function() { return bandsReadOnly; }
});
