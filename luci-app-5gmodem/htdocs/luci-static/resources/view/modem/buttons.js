'use strict';
'require view';
'require fs';
'require ui';

/* Вкладка «Кнопки»: автоопределение железных кнопок (имя из linux,code, тип из
   linux,input-type: EV_SW=переключатель, EV_KEY=кнопка) и привязка команды.
   Кнопка - имя-плашка в тема-стиле; переключатель - тумблер. Команда в
   терминальном поле (стиль AT/USSD) с выпадашкой шаблонов и анимацией печати.
   Debounce гасит дребезг у долгих сервисов. Бэкенд - buttons.sh. */

document.head.append(E('style', { 'type': 'text/css' }, `
.btncard { border:1px solid rgba(127,127,127,.28); border-radius:12px;
  padding:1em 1.1em 1.1em; margin-bottom:1.3em; background:rgba(127,127,127,.03); }
/* Заголовок-карточка в рамке, как кнопки «Приоритета интернета» (класс
   btn cbi-button даёт тема-рамку/фон/скругление; column-раскладку возвращаем
   явно - на proton2025 .btn центрирует детей). */
.btnhead-card { display:flex !important; flex-direction:column !important;
  align-items:flex-start !important; justify-content:center !important;
  flex:1 1 auto; gap:.15em; cursor:default; text-align:left; line-height:1.25; padding:.5em .95em; }
/* Как заголовок+подпись в карточках сохранённых профилей модемов (mprof-name):
   моноширинные, имя жирным, код мельче и приглушён, без плашки, слева. */
.btnhead-card .hname { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  font-weight:700; font-size:1em; display:flex; align-items:center; gap:.5em; }
.btnhead-card .hsub { font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  font-size:78%; opacity:.55; margin-top:-.1em; }
/* display:inline-block ОБЯЗАТЕЛЕН: у inline-span ширина/высота игнорируются,
   и от переключателя оставался только круглый knob (::after) - «большая точка».
   Вкл - акцентный цвет темы, выкл - нейтральный серый. */
.btnsw { display:inline-block; width:42px; height:23px; border-radius:12px;
  background:rgba(127,127,127,.4); position:relative; flex:0 0 auto; vertical-align:middle; }
.btnsw::after { content:''; position:absolute; top:2px; left:2px; width:19px; height:19px;
  border-radius:50%; background:#fff; box-shadow:0 1px 2px rgba(0,0,0,.35); transition:left .2s; }
.btnsw.on { background:var(--proton-accent, #0095ff); } .btnsw.on::after { left:21px; }
.btnsw-sm { width:34px; height:19px; border-radius:10px; }
.btnsw-sm::after { width:15px; height:15px; }
.btnsw-sm.on::after { left:17px; }
.btnfields { display:flex; gap:1.2em; flex-wrap:wrap; margin-top:.5em; align-items:stretch; }
.btnfield { min-width:0; display:flex; flex-direction:column; }
.btnfield-head { flex:0 1 auto; }
.btnfield-cmd { flex-shrink:1; flex-basis:0; min-width:12em; }  /* flex-grow задаёт JS по длине команды */
.btncmd-label { display:flex; align-items:center; gap:.5em; min-height:1.7em;
  font-size:.88em; opacity:.85; margin-bottom:.25em; }
.btncmd { position:relative; }
.btnterm { background:#161c26; border:1px solid rgba(255,255,255,.08); border-radius:8px; }
.btnterm-hd { font-size:10px; color:#8b95a7; letter-spacing:.06em; padding:4px 12px;
  border-bottom:1px solid rgba(255,255,255,.06); background:rgba(255,255,255,.04);
  border-radius:8px 8px 0 0; }
.btnterm-body { position:relative; }
.btnterm input { width:100%; box-sizing:border-box; background:transparent; border:0;
  outline:none; color:#d6e0ea; font-family:monospace; font-size:12px; line-height:1.5;
  padding:9px 36px 9px 12px; }
.btnterm input::placeholder { color:#5b6675; }
.btncaret { position:absolute; right:5px; top:50%; transform:translateY(-50%); width:26px;
  height:24px; display:flex; align-items:center; justify-content:center; cursor:pointer;
  color:#8b95a7; border-radius:5px; user-select:none; font-size:11px; }
.btncaret:hover { background:rgba(255,255,255,.08); color:#d6e0ea; }
.btnmenu { position:absolute; right:0; top:calc(100% + 4px); z-index:20; min-width:17em;
  max-width:100%; background:#1c2430; border:1px solid rgba(255,255,255,.12);
  border-radius:8px; box-shadow:0 8px 24px rgba(0,0,0,.45); overflow:hidden; display:none; }
.btnmenu.open { display:block; }
.btnmenu div { padding:.5em .85em; font-size:.86em; color:#d6e0ea; cursor:pointer; }
.btnmenu div:hover { background:rgba(255,255,255,.09); }
.btncursor::after { content:'▋'; color:#d6e0ea; animation:btncur 1.05s step-end infinite; }
@keyframes btncur { 0%,50%{opacity:.75;} 50.01%,100%{opacity:0;} }
.btndbc { margin-top:1em; display:flex; align-items:center; gap:.5em; flex-wrap:wrap; font-size:.9em; }
.btndbc input { width:5em; }
.btndemo .btnnamebtn, .btndemo .btnname-sw { opacity:.9; }
@media (prefers-reduced-motion: reduce){ .btncursor::after{ animation:none; opacity:.75; } }

/* Два блока-состояния (нажата / отжата) в ряд. */
.btnstates { display:flex; gap:1em; flex-wrap:wrap; margin-top:.4em; }
.btnstate { flex:1 1 20em; min-width:16em; border:1px solid rgba(127,127,127,.28);
  border-radius:12px; padding:.85em .95em 1em; }
.btnstate-ttl { display:flex; align-items:center; gap:.5em; font-weight:700; font-size:.92em;
  margin-bottom:.7em; }
.btnstate-ttl .dotmark { width:.55em; height:.55em; border-radius:50%; flex:0 0 auto; }
/* Нажатый/отжатый вид - на самом виджете кнопки (mode/BTN-0), внутри блока. */
.btnhead-card { width:100%; box-sizing:border-box; transition:box-shadow .12s, transform .12s; }
/* «Нажата» - вдавленная клавиша: внутренняя тень, темнее, сдвинута вниз. */
.btnhead-card.hpressed { box-shadow:inset 0 3px 8px rgba(0,0,0,.32); transform:translateY(2px);
  background:rgba(127,127,127,.14); border-color:rgba(127,127,127,.45); }
/* «Отжата» - приподнятая: светлее сверху, тень-«бортик» снизу. */
.btnhead-card.hreleased { box-shadow:0 3px 0 rgba(0,0,0,.16), inset 0 1px 0 rgba(255,255,255,.14);
  background:linear-gradient(180deg, rgba(127,127,127,.06), rgba(127,127,127,.01)); }
@media (prefers-reduced-motion: reduce){ .btnhead-card.hpressed { transform:none; } }
/* Подсказка о тумблерном поведении моментальной кнопки. */
.btnhint { font-size:.85em; opacity:.8; margin:.1em 0 .9em; padding:.5em .75em;
  border-left:3px solid rgba(127,127,127,.45); background:rgba(127,127,127,.05);
  border-radius:0 6px 6px 0; }

/* Сетка светодиодов: точки-чипы с именем, кликом меняется состояние. */
.ledgrid-lbl { font-size:.84em; opacity:.8; margin:.2em 0 .45em; display:flex;
  align-items:center; gap:.5em; flex-wrap:wrap; }
.ledgrid { display:flex; flex-wrap:wrap; gap:.4em .5em; margin-bottom:.7em; }
.ledchip { display:inline-flex; align-items:center; gap:.45em; padding:.28em .6em .28em .5em;
  border:1px solid rgba(127,127,127,.3); border-radius:999px; cursor:pointer; font-size:.82em;
  font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; user-select:none;
  transition:border-color .15s, background .15s; }
.ledchip:hover { border-color:rgba(127,127,127,.6); }
.ledchip.on { border-color:rgba(127,127,127,.55); background:rgba(127,127,127,.08); }
.ledchip .leddot { width:5px; height:5px; border-radius:50%; flex:0 0 auto;
  border:1px solid var(--ledc, #8a8a8a); box-sizing:border-box; transition:box-shadow .15s, background .15s; }
/* Не задействован: только контур (кнопка этот диод не трогает). */
.ledchip[data-st="none"] .leddot { background:transparent; opacity:.5; }
.ledchip[data-st="none"] { opacity:.72; }
/* Выключить: залитая тусклым серым (диод погаснет). */
.ledchip[data-st="0"] .leddot { background:rgba(127,127,127,.5); border-color:rgba(127,127,127,.5); }
/* Включить: залита цветом диода со свечением (диод зажжётся). */
.ledchip[data-st="1"] .leddot { background:var(--ledc, #cfcf5a);
  box-shadow:0 0 4px 1px var(--ledc, #cfcf5a); }
.ledchip .ledst { font-size:.78em; opacity:.6; min-width:2.6em; }
.ledgrid-empty { font-size:.84em; opacity:.6; margin-bottom:.7em; }
.ledprev { font-size:.8em; opacity:.75; cursor:pointer; text-decoration:underline dotted;
  user-select:none; }
.ledprev:hover { opacity:1; }
`));

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

document.head.append(E('style', { 'type': 'text/css' }, `
/* Компактный виджет-кнопка: НЕ на всю ширину, кликом переключает состояние. */
.btnwidget { display:inline-block; cursor:pointer; }
.btnwidget .btnhead-card { width:auto; min-width:9em; max-width:16em; }
.btnstate-lbl { font-weight:700; font-size:.95em; margin:.2em 0 .45em; }
.btnstate-lbl .hint { font-weight:400; opacity:.6; font-size:.85em; margin-left:.5em; }
/* Сегментированный переключатель типа команды (кнопки, не выпадашка). */
.btnseg { display:inline-flex; border:1px solid rgba(127,127,127,.4); border-radius:8px;
  overflow:hidden; margin:.1em 0 .3em; }
/* !important гасит стиль темы: proton2025 задаёт <button> своё скругление, поля
   и тень - от этого рамка сегмента и кнопки внутри не совпадали по радиусу.
   Внутренние кнопки делаем прямоугольными без полей/теней, а скругление даёт
   контейнер (overflow:hidden обрезает фон активной кнопки по его радиусу). */
.btnseg button { border:0 !important; border-radius:0 !important; margin:0 !important;
  box-shadow:none !important; min-width:0 !important; background:transparent;
  padding:.45em 1.1em; cursor:pointer; font:inherit; color:inherit; opacity:.6; }
.btnseg button.active { background:rgba(127,127,127,.20); opacity:1; font-weight:600; }
.btnseg button + button { border-left:1px solid rgba(127,127,127,.3) !important; }
/* Закрываемый информер (условная команда). */
.btninfo { position:relative; padding:.7em 2.3em .7em .85em; margin:.2em 0 .9em;
  border-radius:8px; font-size:.86em; line-height:1.4;
  background:rgba(90,150,255,.10); border:1px solid rgba(90,150,255,.28); }
.btninfo-x { position:absolute; top:.3em; right:.4em; width:1.5em; height:1.5em;
  border:0; background:transparent; color:inherit; opacity:.55; cursor:pointer;
  font-size:1.15em; line-height:1; border-radius:5px; }
.btninfo-x:hover { opacity:1; background:rgba(127,127,127,.15); }
.btnadd { margin:.6em 0 1em; }
.btncard-del { float:right; }
`));

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
