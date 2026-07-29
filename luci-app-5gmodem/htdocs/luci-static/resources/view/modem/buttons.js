'use strict';
'require view';
'require fs';
'require ui';

/* ОБЩИЙ CSS ПРИЛОЖЕНИЯ. Дублируется из modemtabs.js НАМЕРЕННО: эта страница
   вкладки модемов не показывает и modemtabs не требует, а без загрузчика
   осталась бы вообще без оформления (проверено - страница «Кнопки» так и
   поехала). Тянуть сюда целый модуль ради одного link'а было бы хуже.
   Ставится ПОСЛЕ директив require: код между ними обрывает их разбор. */
(function() {
	if (document.getElementById('tg-modem-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-modem-css';
	l.rel = 'stylesheet';
	l.type = 'text/css';
	l.href = L.resource('view/modem/modem.css');
	document.head.appendChild(l);
})();

/* Вкладка «Кнопки»: автоопределение железных кнопок (имя из linux,code, тип из
   linux,input-type: EV_SW=переключатель, EV_KEY=кнопка) и привязка команды.
   Кнопка - имя-плашка в тема-стиле; переключатель - тумблер. Команда в
   терминальном поле (стиль AT/USSD) с выпадашкой шаблонов и анимацией печати.
   Debounce гасит дребезг у долгих сервисов. Бэкенд - buttons.sh. */

function detect() {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'detect' ]).then(function(res) {
		var j = {};
		try { j = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		return (j && j.buttons) || [];
	});
}
function detectLeds() {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'leds' ]).then(function(res) {
		var j = {};
		try { j = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		return (j && j.leds) || [];
	});
}
function detectServices() {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'services' ]).then(function(res) {
		var j = {};
		try { j = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		return (j && j.services) || [];
	});
}
function setField(name, field, val) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'set', name, field, val || '' ]);
}
function setLeds(name, action, spec) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'setleds', name, action, spec || '' ]);
}
function previewLeds(spec) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'applyleds', spec || '' ]);
}
function delBinding(name) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'del', name ]);
}

/* Имя цвета светодиода (из label) -> CSS-цвет для точки. Нет цвета в имени -
   нейтральный серо-жёлтый, чтобы точка всё равно читалась как «лампочка». */
var LED_CSS = {
	red:'#e5484d', green:'#2ea043', blue:'#4b8bf5', white:'#e8ecf1', amber:'#f5a623',
	orange:'#fb923c', yellow:'#eab308', cyan:'#22d3ee', purple:'#a855f7',
	violet:'#8b5cf6', pink:'#ec4899', magenta:'#d946ef'
};
function ledColor(c) { return LED_CSS[String(c || '').toLowerCase()] || '#c9c982'; }

/* Разбор сохранённой спецификации "имя=1 имя=0 ..." -> { имя: '1'|'0' }. */
function parseLedSpec(spec) {
	var map = {};
	String(spec || '').trim().split(/\s+/).forEach(function(kv) {
		if (!kv) { return; }
		var i = kv.lastIndexOf('=');
		if (i < 1) { return; }
		var n = kv.slice(0, i), v = kv.slice(i + 1);
		if (v === '0' || v === '1') { map[n] = v; }
	});
	return map;
}

/* Сетка светодиодов для одного состояния кнопки. Каждый диод - чип с цветной
   точкой; клик перебирает три состояния: «не трогать» -> «включить» ->
   «выключить». Возвращает узел и getSpec() -> строка "имя=1 имя=0". */
function ledGrid(leds, savedSpec) {
	var initial = parseLedSpec(savedSpec);
	var chips = [];
	var wrap = E('div', { 'class': 'ledgrid' });

	if (!leds.length) {
		return { node: E('div', { 'class': 'ledgrid-empty' },
			_('No LEDs found on this device')), getSpec: function() { return ''; }, leds: leds };
	}

	var order = [ 'none', '1', '0' ];
	var stLabel = { 'none': '—', '1': _('on'), '0': _('off') };
	leds.forEach(function(led) {
		var st = initial[led.name] || 'none';
		var col = ledColor(led.color);
		var stTxt = E('span', { 'class': 'ledst' }, stLabel[st]);
		var chip = E('span', {
			'class': 'ledchip', 'data-st': st, 'data-name': led.name,
			'title': led.name + (led.color ? (' · ' + led.color) : ''),
			'style': '--ledc:' + col
		}, [
			E('span', { 'class': 'leddot' }),
			E('span', {}, led.name),
			stTxt
		]);
		chip.classList.toggle('on', st !== 'none');
		chip.addEventListener('click', function() {
			var cur = chip.getAttribute('data-st');
			var next = order[(order.indexOf(cur) + 1) % order.length];
			chip.setAttribute('data-st', next);
			chip.classList.toggle('on', next !== 'none');
			stTxt.textContent = stLabel[next];
		});
		chips.push(chip);
		wrap.appendChild(chip);
	});

	function getSpec() {
		return chips.map(function(c) {
			var st = c.getAttribute('data-st');
			return (st === '1' || st === '0') ? (c.getAttribute('data-name') + '=' + st) : '';
		}).filter(Boolean).join(' ');
	}
	return { node: wrap, getSpec: getSpec, leds: leds };
}

/* Пресеты команд. У ПРОСТОЙ моментальной кнопки (type='button') - полный набор,
   включая переключение сервиса одним нажатием. У ПЕРЕКЛЮЧАТЕЛЯ (type='switch')
   каждое положение стабильно, поэтому предлагаем старт (нажато) / стоп (отжато).
   Диоды настраиваются отдельно (LED-сетка). */
var PRESETS_COMMON = [
	{ label: _('Reboot the modem'), cmd: '/usr/share/5gmodem/reboot_modem.sh soft' },
	{ label: _('Switch SIM slot'), cmd: '/usr/share/5gmodem/simslot.sh set 1' }
];
/* Простая команда: одноразовые действия. Переключения сервиса тут НЕТ - оно
   принадлежит условной команде (по решению владельца). */
var PRESETS_SIMPLE = [
	{ label: _('Start service'), cmd: '/usr/share/5gmodem/buttons.sh svc start ssclash' },
	{ label: _('Stop service'),  cmd: '/usr/share/5gmodem/buttons.sh svc stop ssclash' },
	{ label: _('Restart service'), cmd: '/etc/init.d/ssclash restart' }
].concat(PRESETS_COMMON);
/* Условная: терминал - для НЕОБЯЗАТЕЛЬНОЙ доп. команды (сам сервис задаётся
   отдельным полем). Здесь же доступен и toggle - если пользователь хочет
   вписать своё. */
var PRESETS_COND = [
	{ label: _('Toggle service (on/off)'), cmd: '/usr/share/5gmodem/buttons.sh svc toggle ssclash' }
].concat(PRESETS_COMMON);

var _reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

function typewrite(term, input, text) {
	if (_reduce) { input.value = text; input.dispatchEvent(new Event('input')); return; }
	input.value = '';
	term.classList.add('btncursor');
	var i = 0;
	(function step() {
		input.value = text.slice(0, i);
		if (i++ < text.length) { window.setTimeout(step, 12); }
		else { term.classList.remove('btncursor'); input.dispatchEvent(new Event('input')); }
	})();
}

function cmdField(value, presetList) {
	var input = E('input', {
		'type': 'text', 'spellcheck': 'false', 'autocomplete': 'off',
		'placeholder': _('shell command'), 'value': value || ''
	});
	var menu = E('div', { 'class': 'btnmenu' });
	var body = E('div', { 'class': 'btnterm-body' }, [ input ]);
	var term = E('div', { 'class': 'btnterm' }, [ E('div', { 'class': 'btnterm-hd' }, 'sh'), body ]);
	/* Меню пресетов перестраиваемо: при смене типа команды (простая/условная)
	   набор пресетов разный. */
	function fillMenu(list) {
		menu.innerHTML = '';
		(list || []).forEach(function(p) {
			menu.appendChild(E('div', {
				'click': function(ev) { ev.stopPropagation(); menu.classList.remove('open'); typewrite(term, input, p.cmd); input.focus(); }
			}, p.label));
		});
	}
	fillMenu(presetList);
	var caret = E('span', {
		'class': 'btncaret', 'title': _('insert a preset'),
		'click': function(ev) {
			ev.stopPropagation();
			var wasOpen = menu.classList.contains('open');
			document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
			if (!wasOpen) { menu.classList.add('open'); }
		}
	}, '▾');
	body.appendChild(caret);
	return { input: input, node: E('div', { 'class': 'btncmd' }, [ term, menu ]), setPresets: fillMenu };
}

function toggleWidget(on, small) {
	return E('span', { 'class': 'btnsw' + (small ? ' btnsw-sm' : '') + (on ? ' on' : '') });
}

/* Компактный виджет кнопки (mode + код). state - нажата/отжата (вид из CSS
   .hpressed/.hreleased). Кликабельность вешает вызывающий (buttonCard). */
function widget(b, state) {
	var cls = 'btn cbi-button btnhead-card'
		+ (state === 'pressed' ? ' hpressed' : ' hreleased');
	return E('div', { 'class': cls }, [
		E('span', { 'class': 'hname' }, b.label || b.name),
		E('span', { 'class': 'hsub' }, b.name)
	]);
}

/* Стандартный закрываемый информер. Крестик прячет его и запоминает выбор в
   localStorage по ключу - при следующих заходах не мозолит глаза. */
function infoBox(key, text) {
	var box = E('div', { 'class': 'btninfo' }, [
		E('span', {}, text),
		E('button', { 'class': 'btninfo-x', 'type': 'button', 'title': _('Dismiss'),
			'click': function() {
				box.style.display = 'none';
				try { window.localStorage.setItem('btninfo:' + key, '1'); } catch (e) {}
			} }, '×')
	]);
	try { if (window.localStorage.getItem('btninfo:' + key) === '1') { box.style.display = 'none'; } } catch (e) {}
	return box;
}

/* Сегментированный тумблер: [Простая | Условная]. get() -> выбранное. */
function segmented(opts, value, onChange) {
	var wrap = E('div', { 'class': 'btnseg' });
	var btns = [];
	opts.forEach(function(o) {
		var el = E('button', { 'type': 'button' }, o.label);
		if (o.value === value) { el.classList.add('active'); }
		el.addEventListener('click', function() {
			btns.forEach(function(x) { x.classList.remove('active'); });
			el.classList.add('active');
			wrap.setAttribute('data-val', o.value);
			if (onChange) { onChange(o.value); }
		});
		btns.push(el); wrap.appendChild(el);
	});
	wrap.setAttribute('data-val', value);
	return { node: wrap, get: function() { return wrap.getAttribute('data-val'); } };
}

/* Один блок-состояние (нажата / отжата, либо два положения переключателя).
   Самодостаточен: LED-сетка + команда + своя кнопка «Сохранить». debounce у
   кнопки общий - его вход передаётся снаружи, и Save любого блока его пишет. */
/* Блок «Светодиоды в этом состоянии»: подпись + ссылка «проверить» + сетка.
   Ставится ПОД полем команды (см. renderButton). */
function ledsBlock(labelText, grid) {
	var preview = grid.leds && grid.leds.length ? E('span', {
		'class': 'ledprev', 'title': _('Apply this LED combination now to check it'),
		'click': function() { previewLeds(grid.getSpec()); }
	}, _('test on LEDs')) : null;
	return E('div', { 'style': 'margin-top:.9em' }, [
		E('div', { 'class': 'ledgrid-lbl' }, [ E('span', {}, labelText), preview ].filter(Boolean)),
		grid.node
	]);
}

function dbcInput(b) {
	return E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text',
		'value': (b.debounce !== undefined && b.debounce !== '') ? b.debounce : '10' });
}

function saveStatus() { return E('span', { 'style': 'margin-left:.6em; font-size:90%' }, ''); }
function flashSaved(status) { status.textContent = _('Saved'); status.style.color = '#2ea043';
	window.setTimeout(function() { status.textContent = ''; }, 2500); }
function flashCleared(status) { status.textContent = _('Cleared'); status.style.color = '';
	window.setTimeout(function() { status.textContent = ''; }, 2500); }

/* Пресеты условной команды = переключение КАЖДОГО сервиса роутера (сервис
   подставляется прямо в команду терминала - отдельного поля «имя сервиса»
   больше нет, чтобы две сущности не путались). */
function condPresets(services) {
	return (services || []).map(function(s) {
		return { label: _('Toggle service') + ' · ' + s,
			cmd: '/usr/share/5gmodem/buttons.sh svc toggle ' + s };
	}).concat(PRESETS_COMMON);
}

/* Панель настройки ОДНОГО состояния. Тип команды тумблером; терминал виден
   всегда; для простой - статичные диоды, для условной - диоды на «запущен»/
   «остановлен» (сервис задаётся из выпадашки прямо в команде). */
function statePanel(b, leds, state, services) {
	var ct0 = (b['ct_' + state] === 'conditional') ? 'conditional' : 'simple';
	var cPre = condPresets(services);

	var cmd = cmdField(b['cmd_' + state], ct0 === 'conditional' ? cPre : PRESETS_SIMPLE);

	var sGrid = ledGrid(leds, b['leds_' + state]);
	var simpleLeds = ledsBlock(_('LEDs in this state:'), sGrid);

	var onGrid = ledGrid(leds, b['ledson_' + state]);
	var offGrid = ledGrid(leds, b['ledsoff_' + state]);
	var condArea = E('div', {}, [
		infoBox('cond-help',
			_('Pick a service from the command menu above (▾) - it fills the toggle command. Each press flips it; the LEDs below reflect whether it ends up running or stopped.')),
		ledsBlock(_('LEDs when the service is running:'), onGrid),
		ledsBlock(_('LEDs when the service is stopped:'), offGrid)
	]);

	var seg = segmented([
		{ 'value': 'simple', 'label': _('Simple') },
		{ 'value': 'conditional', 'label': _('Conditional') }
	], ct0, function(v) {
		cmd.setPresets(v === 'conditional' ? cPre : PRESETS_SIMPLE);
		simpleLeds.style.display = (v === 'simple') ? '' : 'none';
		condArea.style.display = (v === 'conditional') ? '' : 'none';
	});

	simpleLeds.style.display = (ct0 === 'simple') ? '' : 'none';
	condArea.style.display = (ct0 === 'conditional') ? '' : 'none';

	var node = E('div', { 'style': 'margin-top:.3em' }, [
		E('div', { 'class': 'btncmd-label', 'style': 'margin-bottom:.2em' }, _('Command type:')),
		seg.node,
		/* Терминал ВСЕГДА виден - можно вписать свой скрипт при любом типе. */
		E('label', { 'class': 'btncmd-label', 'style': 'margin-top:.6em' }, _('Command:')),
		cmd.node,
		simpleLeds,
		condArea
	]);

	function getVals() {
		return {
			ct: seg.get(), cmd: cmd.input.value,
			simpleLeds: sGrid.getSpec(),
			onLeds: onGrid.getSpec(), offLeds: offGrid.getSpec()
		};
	}
	return { node: node, getVals: getVals };
}

/* Карточка одной кнопки.
   - Моментальная: один виджет-кнопка, клик листает нажата/отжата (одна панель).
   - Переключатель: ОБА положения сразу (вкл/выкл), у каждого свой тумблер-
     заголовок; дизайн тот же, что у кнопки, только виджет - переключатель.
   Общий debounce, одна кнопка «Сохранить» (оба состояния) и «Удалить». */
function buttonCard(b, leds, services, onDelete) {
	var isSwitch = (b.type === 'switch');
	var card = E('div', { 'class': 'btncard' });
	var dbc = dbcInput(b);
	var status = saveStatus();

	card.appendChild(E('button', { 'class': 'btn cbi-button cbi-button-remove btncard-del',
		'click': ui.createHandlerFn(this, function() {
			return delBinding(b.name).then(function() {
				if (card.parentNode) { card.parentNode.removeChild(card); }
				if (onDelete) { onDelete(b.name); }
			});
		}) }, _('Delete')));

	var pPanel = statePanel(b, leds, 'pressed', services);
	var rPanel = statePanel(b, leds, 'released', services);

	if (isSwitch) {
		/* Оба положения сразу. Подпись - строкой, переключатель под ней (иначе
		   текст наезжал на виджет). */
		card.appendChild(E('div', {}, [
			E('div', { 'class': 'btnstate-lbl' }, _('Switch ON')),
			toggleWidget(true, false) ]));
		card.appendChild(pPanel.node);
		card.appendChild(E('hr', { 'style': 'border:0;border-top:1px solid rgba(127,127,127,.2);margin:1.1em 0' }));
		card.appendChild(E('div', {}, [
			E('div', { 'class': 'btnstate-lbl' }, _('Switch OFF')),
			toggleWidget(false, false) ]));
		card.appendChild(rPanel.node);
	} else {
		/* Моментальная: клик по виджету листает нажата/отжата. */
		var state = 'pressed';
		var widgetWrap = E('div', { 'class': 'btnwidget',
			'title': _('Click the button to switch between its pressed and released state') });
		var lbl = E('span', {});
		card.appendChild(E('div', { 'class': 'btnstate-lbl' }, [ lbl,
			E('span', { 'class': 'hint' }, _('(click the button to switch state)')) ]));
		card.appendChild(widgetWrap);
		card.appendChild(pPanel.node);
		card.appendChild(rPanel.node);
		var renderState = function() {
			widgetWrap.innerHTML = '';
			widgetWrap.appendChild(widget(b, state));
			lbl.textContent = (state === 'pressed') ? _('Pressed') : _('Released');
			pPanel.node.style.display = (state === 'pressed') ? '' : 'none';
			rPanel.node.style.display = (state === 'released') ? '' : 'none';
		};
		widgetWrap.addEventListener('click', function() {
			state = (state === 'pressed') ? 'released' : 'pressed';
			renderState();
		});
		renderState();
	}

	var save = E('button', { 'class': 'btn cbi-button cbi-button-save',
		'click': ui.createHandlerFn(this, function() {
			var ops = [ setField(b.name, 'btntype', isSwitch ? 'switch' : 'button'),
				setField(b.name, 'debounce', dbc.value) ];
			[ [ 'pressed', pPanel ], [ 'released', rPanel ] ].forEach(function(pair) {
				var st = pair[0], v = pair[1].getVals();
				ops.push(setField(b.name, 'ct_' + st, v.ct));
				ops.push(setField(b.name, st, v.cmd));
				if (v.ct === 'conditional') {
					ops.push(setLeds(b.name, 'on_' + st, v.onLeds));
					ops.push(setLeds(b.name, 'off_' + st, v.offLeds));
				} else {
					ops.push(setLeds(b.name, st, v.simpleLeds));
				}
			});
			return Promise.all(ops).then(function() { flashSaved(status); });
		}) }, _('Save'));

	card.appendChild(E('div', { 'class': 'btndbc' }, [
		dbc, E('span', { 'style': 'opacity:.7' }, _('delay between repeats, seconds')) ]));
	card.appendChild(E('div', { 'style': 'margin-top:.9em' }, [ save, status ]));
	return card;
}

function renderButton(b, leds, services, onDelete) { return buttonCard(b, leds, services, onDelete); }

document.addEventListener('click', function() {
	document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
});

return view.extend({
	load: function() { return Promise.all([ detect(), detectLeds(), detectServices() ]); },

	render: function(res) {
		var buttons = (res && res[0]) || [];
		var leds = (res && res[1]) || [];
		var services = (res && res[2]) || [];
		var body = E('div', {}, [
			E('h2', {}, _('Buttons')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Assign actions to this router’s physical buttons. Click a button below to add and configure it.'))
		]);

		var assignable = (buttons || []).filter(function(b) { return !b['default']; });
		if (!assignable.length) {
			body.appendChild(E('div', { 'class': 'alert-message' },
				_('No assignable buttons were detected on this device')));
			return body;
		}

		var list = E('div', {});
		var addWrap = E('div', { 'class': 'btnadd' });
		body.appendChild(list);
		body.appendChild(addWrap);

		/* «Настроена» = задано хоть что-то. Такие показываем сразу, остальные -
		   доступны к добавлению своим чипом «+ имя». */
		var CFG_KEYS = [ 'cmd_pressed', 'cmd_released', 'ct_pressed', 'ct_released',
			'leds_pressed', 'leds_released', 'ledson_pressed', 'ledsoff_pressed',
			'ledson_released', 'ledsoff_released' ];
		function isConfigured(b) {
			return CFG_KEYS.some(function(k) { return b[k] && b[k] !== ''; });
		}

		var shown = {};
		function addCard(b) {
			shown[b.name] = true;
			list.appendChild(renderButton(b, leds, services, function(name) { shown[name] = false; refreshAdd(); }));
			refreshAdd();
		}
		/* По ОТДЕЛЬНОМУ чипу на каждую ненастроенную кнопку: «+ mode», «+ wps»,
		   «+ switch»… - клик добавляет именно её. */
		function refreshAdd() {
			addWrap.innerHTML = '';
			var avail = assignable.filter(function(b) { return !shown[b.name]; });
			if (!avail.length) {
				addWrap.appendChild(E('em', { 'style': 'opacity:.6' },
					_('All buttons of this device have been added')));
				return;
			}
			avail.forEach(function(b) {
				addWrap.appendChild(E('button', {
					'class': 'btn cbi-button cbi-button-add', 'style': 'margin-right:.4em',
					'title': b.name + (b.type === 'switch' ? ' · switch' : ''),
					'click': function() { addCard(b); }
				}, '+ ' + (b.label || b.name)));
			});
		}

		assignable.forEach(function(b) { if (isConfigured(b)) { addCard(b); } });
		refreshAdd();
		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
