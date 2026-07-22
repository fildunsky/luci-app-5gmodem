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
.btnsw { width:42px; height:23px; border-radius:12px; background:rgba(127,127,127,.4);
  position:relative; flex:0 0 auto; }
.btnsw::after { content:''; position:absolute; top:2px; left:2px; width:19px; height:19px;
  border-radius:50%; background:#fff; box-shadow:0 1px 2px rgba(0,0,0,.35); transition:left .2s; }
.btnsw.on { background:#2ea043; } .btnsw.on::after { left:21px; }
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
`));

function detect() {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'detect' ]).then(function(res) {
		var j = {};
		try { j = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		return (j && j.buttons) || [];
	});
}
function setField(name, field, val) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'set', name, field, val || '' ]);
}
function delBinding(name) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'del', name ]);
}

/* Пресеты зависят от типа и положения: у переключателя одно положение включает,
   другое выключает сервис (toggle не нужен); у кнопки - toggle/restart. */
function presets(type, on) {
	var common = [
		{ label: _('Reboot the modem'), cmd: '/usr/share/5gmodem/reboot_modem.sh soft' },
		{ label: _('Switch SIM slot'), cmd: '/usr/share/5gmodem/simslot.sh set 1' }
	];
	if (type === 'switch') {
		return [ on
			? { label: _('Start service'), cmd: '/usr/share/5gmodem/buttons.sh svc start ssclash' }
			: { label: _('Stop service'),  cmd: '/usr/share/5gmodem/buttons.sh svc stop ssclash' }
		].concat(common);
	}
	return [
		{ label: _('Toggle service (on/off)'), cmd: '/usr/share/5gmodem/buttons.sh svc toggle ssclash' },
		{ label: _('Restart service'), cmd: '/etc/init.d/ssclash restart' }
	].concat(common);
}

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

function cmdField(value, type, on) {
	var input = E('input', {
		'type': 'text', 'spellcheck': 'false', 'autocomplete': 'off',
		'placeholder': _('shell command'), 'value': value || ''
	});
	var menu = E('div', { 'class': 'btnmenu' });
	var body = E('div', { 'class': 'btnterm-body' }, [ input ]);
	var term = E('div', { 'class': 'btnterm' }, [ E('div', { 'class': 'btnterm-hd' }, 'sh'), body ]);
	presets(type, on).forEach(function(p) {
		menu.appendChild(E('div', {
			'click': function(ev) { ev.stopPropagation(); menu.classList.remove('open'); typewrite(term, input, p.cmd); input.focus(); }
		}, p.label));
	});
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
	return { input: input, node: E('div', { 'class': 'btncmd' }, [ term, menu ]) };
}

function toggleWidget(on, small) {
	return E('span', { 'class': 'btnsw' + (small ? ' btnsw-sm' : '') + (on ? ' on' : '') });
}

/* Подпись поля: у кнопки - текст Нажата/Отжата, у переключателя - тумблер в
   соответствующем положении (одно/другое). */
function fieldLabel(isSwitch, on) {
	if (!isSwitch) { return E('label', { 'class': 'btncmd-label' }, on ? _('Pressed') : _('Released')); }
	return E('label', {
		'class': 'btncmd-label',
		'title': on ? _('one position') : _('the other position')
	}, [ toggleWidget(on, true) ]);
}

/* Заголовок = карточка в рамке, как кнопки «Приоритета интернета» (btn cbi-button
   + column-раскладка): сверху имя (у переключателя с тумблером), снизу слово типа
   и моноширинный код кнопки. */
function header(b, type) {
	var name = b.label || b.name;
	var nameLine = (type === 'switch')
		? E('span', { 'class': 'hname' }, [ toggleWidget(false, false), name ])
		: E('span', { 'class': 'hname' }, name);
	return E('div', { 'class': 'btn cbi-button btnhead-card' }, [
		nameLine,
		E('span', { 'class': 'hsub' }, b.name)
	]);
}

function renderButton(b, demo) {
	var type = (b.type === 'switch') ? 'switch' : 'button';
	var isSwitch = (type === 'switch');
	var card = E('div', { 'class': 'btncard' + (demo ? ' btndemo' : '') });

	var fP = cmdField(b.pressed, type, true);
	var fR = cmdField(b.released, type, false);
	/* Оба терминала равнозначны без текста (делят место поровну). С текстом ширина
	   колонки пропорциональна длине команды - длинная вытесняет короткую; удалил
	   текст - поле возвращается к равной ширине. Обе длинные и не влезают - вторая
	   переносится вниз (flex-wrap). Вес - по длине value через flex-grow. */
	var colP = E('div', { 'class': 'btnfield btnfield-cmd' }, [ fieldLabel(isSwitch, true), fP.node ]);
	var colR = E('div', { 'class': 'btnfield btnfield-cmd' }, [ fieldLabel(isSwitch, false), fR.node ]);
	function resizeCols() {
		colP.style.flexGrow = Math.max(fP.input.value.length, 8);
		colR.style.flexGrow = Math.max(fR.input.value.length, 8);
	}
	fP.input.addEventListener('input', resizeCols);
	fR.input.addEventListener('input', resizeCols);
	resizeCols();
	card.appendChild(E('div', { 'class': 'btnfields' }, [
		/* Заголовок-карточка - первой колонкой, вровень с полями (спейсер вместо
		   подписи держит её на уровне терминалов). Три в ряд, если помещается. */
		E('div', { 'class': 'btnfield btnfield-head' }, [
			E('div', { 'class': 'btncmd-label' }, isSwitch ? _('switch') : _('button')),
			header(b, type)
		]),
		colP,
		colR
	]));

	var dbc = E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text',
		'value': (b.debounce !== undefined && b.debounce !== '') ? b.debounce : '10' });
	card.appendChild(E('div', { 'class': 'btndbc' }, [
		dbc, E('span', { 'style': 'opacity:.7' }, _('delay between repeats, seconds'))
	]));

	var status = E('span', { 'style': 'margin-left:.6em; font-size:90%' }, '');

	var save = E('button', {
		'class': 'btn cbi-button cbi-button-save', 'disabled': demo ? '' : null,
		'click': demo ? null : ui.createHandlerFn(this, function() {
			return Promise.all([
				setField(b.name, 'pressed', fP.input.value),
				setField(b.name, 'released', fR.input.value),
				setField(b.name, 'debounce', dbc.value)
			]).then(function() {
				status.textContent = _('Saved'); status.style.color = '#2ea043';
				window.setTimeout(function() { status.textContent = ''; }, 2500);
			});
		})
	}, _('Save'));

	var clear = E('button', {
		'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-left:.4em',
		'disabled': demo ? '' : null,
		'click': demo ? null : ui.createHandlerFn(this, function() {
			fP.input.value = ''; fR.input.value = '';
			return delBinding(b.name).then(function() {
				status.textContent = _('Cleared'); status.style.color = '';
				window.setTimeout(function() { status.textContent = ''; }, 2500);
			});
		})
	}, _('Clear'));

	card.appendChild(E('div', { 'style': 'margin-top:.9em' }, [ save, clear, status ]));
	return card;
}

document.addEventListener('click', function() {
	document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
});

return view.extend({
	load: function() { return detect(); },

	render: function(buttons) {
		var body = E('div', {}, [
			E('h2', {}, _('Buttons')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Physical buttons of this router model, available for assigning functions'))
		]);

		var free = (buttons || []).filter(function(b) { return !b['default']; });

		if (!free.length) {
			body.appendChild(E('div', { 'class': 'alert-message' },
				_('No assignable buttons were detected on this device.')));
		} else {
			free.forEach(function(b) { body.appendChild(renderButton(b, false)); });
		}

		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
