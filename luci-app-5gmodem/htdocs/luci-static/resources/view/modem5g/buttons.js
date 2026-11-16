'use strict';
'require view';
'require fs';
'require ui';
'require view.modem5g.modemtabs as modemtabs';

// Router buttons: one card per button, page styles in page-buttons.css (tg-btn-*).
(function() {
	if (document.getElementById('tg-page-buttons-css')) { return; }
	document.head.appendChild(E('link', { 'id': 'tg-page-buttons-css', 'rel': 'stylesheet', 'type': 'text/css',
		'href': L.resource('view/modem5g/page-buttons.css') }));
})();

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
function saveAll(name, fields) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'save', name ].concat(fields)).then(function(res) {
		try { return JSON.parse((res && res.stdout) || 'null'); } catch (e) { return null; }
	});
}
function previewLeds(spec) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'applyleds', spec || '' ]);
}
function delBinding(name) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'del', name ]);
}

var ICONS = {
	power: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="5"/></g>',
	trash: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14M10 11v5M14 11v5"/></g>',
	plus: '<path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
	check: '<path d="m5 12.5 4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
};
function svg(name, size) {
	return '<svg viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true">' + ICONS[name] + '</svg>';
}
function icon(name, size, cls) {
	var s = E('span', { 'class': cls || 'tg-btn-i' });
	s.innerHTML = svg(name, size);
	return s;
}
// Labels are the existing "Command:" style strings; the card shows them without the colon.
function lbl(s) { return String(s).replace(/[:：]\s*$/, ''); }

var LED_CSS = {
	red:'#e5484d', green:'#2ea043', blue:'#4b8bf5', white:'#e8ecf1', amber:'#f5a623',
	orange:'#fb923c', yellow:'#eab308', cyan:'#22d3ee', purple:'#a855f7',
	violet:'#8b5cf6', pink:'#ec4899', magenta:'#d946ef'
};
function ledColor(c) { return LED_CSS[String(c || '').toLowerCase()] || '#c9c982'; }

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

// LED chips: each click cycles "not touched" -> on -> off.
function ledGrid(leds, savedSpec) {
	var initial = parseLedSpec(savedSpec);
	var chips = [];
	var wrap = E('div', { 'class': 'tg-btn-leds' });

	if (!leds.length) {
		return { node: E('div', { 'class': 'tg-btn-ledsempty' },
			_('No LEDs found on this device')), getSpec: function() { return ''; }, leds: leds };
	}

	var order = [ 'none', '1', '0' ];
	var stLabel = { 'none': '—', '1': _('on'), '0': _('off') };
	leds.forEach(function(led) {
		var st = initial[led.name] || 'none';
		var stTxt = E('span', { 'class': 'tg-btn-ledst' }, stLabel[st]);
		var chip = E('button', {
			'type': 'button', 'class': 'tg-btn-led', 'data-st': st, 'data-name': led.name,
			'title': led.name + (led.color ? (' · ' + led.color) : ''),
			'style': '--ledc:' + ledColor(led.color)
		}, [
			E('i'),
			E('span', {}, [ led.name ]),
			stTxt
		]);
		chip.addEventListener('click', function() {
			var cur = chip.getAttribute('data-st');
			var next = order[(order.indexOf(cur) + 1) % order.length];
			chip.setAttribute('data-st', next);
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

var PRESETS_COMMON = [
	{ label: _('Reboot the modem'), cmd: '/usr/share/5gmodem/reboot_modem.sh soft' },
	{ label: _('Switch SIM slot'), cmd: '/usr/share/5gmodem/simslot.sh set 1' }
];
var PRESETS_SIMPLE = [
	{ label: _('Start service'), cmd: '/usr/share/5gmodem/buttons.sh svc start ssclash' },
	{ label: _('Stop service'),  cmd: '/usr/share/5gmodem/buttons.sh svc stop ssclash' },
	{ label: _('Restart service'), cmd: '/etc/init.d/ssclash restart' }
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

// The command "terminal" (btnterm, styled in modem.css) with the preset menu behind the caret.
function cmdField(value, presetList) {
	var input = E('input', {
		'type': 'text', 'spellcheck': 'false', 'autocomplete': 'off',
		'placeholder': _('shell command'), 'value': value || '',
		'aria-label': lbl(_('Command:'))
	});
	var menu = E('div', { 'class': 'btnmenu' });
	var body = E('div', { 'class': 'btnterm-body' }, [ input ]);
	var term = E('div', { 'class': 'btnterm' }, [ E('div', { 'class': 'btnterm-hd' }, 'sh'), body ]);
	function fillMenu(list) {
		menu.innerHTML = '';
		(list || []).forEach(function(p) {
			menu.appendChild(E('div', {
				'click': function(ev) { ev.stopPropagation(); menu.classList.remove('open'); typewrite(term, input, p.cmd); input.focus(); }
			}, [ p.label ]));
		});
	}
	fillMenu(presetList);
	var caret = E('span', {
		'class': 'btncaret', 'title': _('insert a preset'), 'role': 'button', 'tabindex': '0',
		'click': function(ev) {
			ev.stopPropagation();
			var wasOpen = menu.classList.contains('open');
			document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
			if (!wasOpen) { menu.classList.add('open'); }
		},
		'keydown': function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); caret.click(); } }
	}, '▾');
	body.appendChild(caret);
	return { input: input, node: E('div', { 'class': 'btncmd' }, [ term, menu ]), setPresets: fillMenu };
}

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

function segmented(opts, value, onChange) {
	var wrap = E('div', { 'class': 'tg-btn-seg', 'role': 'group' });
	var btns = [];
	opts.forEach(function(o) {
		var el = E('button', { 'type': 'button', 'aria-pressed': String(o.value === value) }, o.label);
		if (o.value === value) { el.classList.add('on'); }
		el.addEventListener('click', function() {
			btns.forEach(function(x) { x.classList.remove('on'); x.setAttribute('aria-pressed', 'false'); });
			el.classList.add('on');
			el.setAttribute('aria-pressed', 'true');
			wrap.setAttribute('data-val', o.value);
			if (onChange) { onChange(o.value); }
		});
		btns.push(el); wrap.appendChild(el);
	});
	wrap.setAttribute('data-val', value);
	return { node: wrap, get: function() { return wrap.getAttribute('data-val'); } };
}

function ledsBlock(labelText, grid) {
	var preview = grid.leds && grid.leds.length ? E('a', {
		'href': '#', 'class': 'tg-btn-test', 'title': _('Apply this LED combination now to check it'),
		'click': function(ev) { ev.preventDefault(); previewLeds(grid.getSpec()); }
	}, _('test on LEDs')) : null;
	return E('div', { 'class': 'tg-btn-ledblk' }, [
		E('div', { 'class': 'tg-btn-lbl' }, [ E('span', {}, lbl(labelText)), preview ].filter(Boolean)),
		grid.node
	]);
}

function dbcInput(b) {
	return E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text tg-btn-dbc',
		'aria-label': _('delay between repeats, seconds'),
		'value': (b.debounce !== undefined && b.debounce !== '') ? b.debounce : '10' });
}

function saveStatus() { return E('span', { 'class': 'tg-btn-status' }, ''); }
function flashSaved(status) {
	status.className = 'tg-btn-status ok';
	status.textContent = '';
	status.appendChild(icon('check', 14));
	status.appendChild(document.createTextNode(_('Saved')));
	window.setTimeout(function() { status.textContent = ''; }, 2500);
}

function condPresets(services) {
	return (services || []).map(function(s) {
		return { label: _('Toggle service') + ' · ' + s,
			cmd: '/usr/share/5gmodem/buttons.sh svc toggle ' + s };
	}).concat(PRESETS_COMMON);
}

// One state (pressed/released, or switch on/off): command on the left, LEDs on the right.
function statePanel(b, leds, state, services) {
	var ct0 = (b['ct_' + state] === 'conditional') ? 'conditional' : 'simple';
	var cPre = condPresets(services);

	var cmd = cmdField(b['cmd_' + state], ct0 === 'conditional' ? cPre : PRESETS_SIMPLE);

	var sGrid = ledGrid(leds, b['leds_' + state]);
	var simpleLeds = ledsBlock(_('LEDs in this state:'), sGrid);

	var onGrid = ledGrid(leds, b['ledson_' + state]);
	var offGrid = ledGrid(leds, b['ledsoff_' + state]);
	var condArea = E('div', { 'class': 'tg-btn-cond' }, [
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

	var node = E('div', { 'class': 'tg-btn-grid' }, [
		E('div', { 'class': 'tg-btn-col' }, [
			E('div', { 'class': 'tg-btn-lbl' }, E('span', {}, lbl(_('Command type:')))),
			seg.node,
			E('div', { 'class': 'tg-btn-lbl tg-btn-lbl2' }, E('span', {}, lbl(_('Command:')))),
			cmd.node
		]),
		E('div', { 'class': 'tg-btn-col' }, [ simpleLeds, condArea ])
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

function buttonCard(b, leds, services, onDelete) {
	var isSwitch = (b.type === 'switch');
	var card = E('div', { 'class': 'cbi-section tg-btn-card', 'data-btn': b.name });
	var dbc = dbcInput(b);
	var status = saveStatus();

	var pPanel = statePanel(b, leds, 'pressed', services);
	var rPanel = statePanel(b, leds, 'released', services);

	// The state picker replaces the old click-on-the-picture; a switch has ON/OFF instead.
	var stateSeg = segmented([
		{ 'value': 'pressed', 'label': isSwitch ? _('Switch ON') : _('Pressed') },
		{ 'value': 'released', 'label': isSwitch ? _('Switch OFF') : _('Released') }
	], 'pressed', function(v) {
		pPanel.node.style.display = (v === 'pressed') ? '' : 'none';
		rPanel.node.style.display = (v === 'released') ? '' : 'none';
	});
	rPanel.node.style.display = 'none';

	var del = E('button', { 'class': 'cbi-button cbi-button-negative tg-btn-ico', 'type': 'button',
		'title': _('Delete'), 'aria-label': _('Delete'),
		'click': ui.createHandlerFn(this, function() {
			return delBinding(b.name).then(function() {
				if (card.parentNode) { card.parentNode.removeChild(card); }
				if (onDelete) { onDelete(b.name); }
			});
		}) });
	del.innerHTML = svg('trash', 15);

	var title = E('h3', { 'class': 'tg-btn-title' }, [
		E('span', {}, [ b.label || b.name ]),
		E('span', { 'class': 'tg-proto-badge', 'title': b.name }, isSwitch ? _('switch') : _('button'))
	]);
	card.appendChild(E('div', { 'class': 'tg-btn-top' }, [ title, E('span', { 'class': 'tg-btn-grow' }), stateSeg.node, del ]));
	card.appendChild(pPanel.node);
	card.appendChild(rPanel.node);

	var save = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button',
		'click': ui.createHandlerFn(this, function() {
			var ops = [ function() { return setField(b.name, 'debounce', dbc.value); } ];
			var fields = [ 'debounce=' + (dbc.value || '') ];
			[ [ 'pressed', pPanel ], [ 'released', rPanel ] ].forEach(function(pair) {
				var st = pair[0], v = pair[1].getVals();
				fields.push('ct_' + st + '=' + (v.ct || ''), st + '=' + (v.cmd || ''));
				ops.push(function() { return setField(b.name, 'ct_' + st, v.ct); });
				ops.push(function() { return setField(b.name, st, v.cmd); });
				if (v.ct === 'conditional') {
					fields.push('leds_on_' + st + '=' + (v.onLeds || ''), 'leds_off_' + st + '=' + (v.offLeds || ''));
					ops.push(function() { return setLeds(b.name, 'on_' + st, v.onLeds); });
					ops.push(function() { return setLeds(b.name, 'off_' + st, v.offLeds); });
				} else {
					fields.push('leds_' + st + '=' + (v.simpleLeds || ''));
					ops.push(function() { return setLeds(b.name, st, v.simpleLeds); });
				}
			});
			// one exec for the whole card; the per-field calls stay only for a buttons.sh without "save"
			return saveAll(b.name, fields).then(function(j) {
				if (j && j.ok) { return; }
				if (j && typeof j.error === 'string' && j.error.indexOf('usage') !== 0) { throw new Error(j.error); }
				return ops.reduce(function(p, mk) { return p.then(mk); }, Promise.resolve());
			}).then(function() { flashSaved(status); }, function(e) {
				status.className = 'tg-btn-status bad';
				status.textContent = String((e && e.message) || e);
			});
		}) }, _('Save'));

	card.appendChild(E('div', { 'class': 'tg-btn-foot' }, [
		dbc, E('span', { 'class': 'tg-btn-muted' }, _('delay between repeats, seconds')),
		E('span', { 'class': 'tg-btn-grow' }), status, save ]));
	return card;
}

function renderButton(b, leds, services, onDelete) { return buttonCard(b, leds, services, onDelete); }

document.addEventListener('click', function() {
	document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
});

return view.extend({
	// the page shows no modem bar, but the menu tabs hidden by settings must stay hidden here too
	// render first: the button, LED and service lists come from the router after the page is drawn
	load: function() { return L.resolveDefault(modemtabs.refreshMenuTabs()); },

	render: function() {

		/* header card in the Network-page layout */
		var hd = {};
		hd.ico = E('div', { 'class': 'tginfo-signal tg-btn-ico' });
		hd.ico.innerHTML = svg('power', 36);
		hd.main = E('div', { 'class': 'tginfo-op tg-btn-main' }, E('span', { 'class': 'tg-skel', 'style': 'width:14em' }));
		hd.add = E('div', { 'class': 'tg-btn-add' }, [ E('span', { 'class': 'tg-skel', 'style': 'width:7em;height:2em' }),
			E('span', { 'class': 'tg-skel', 'style': 'width:7em;height:2em;margin-left:8px' }) ]);
		var head = E('div', { 'class': 'cbi-section tg-pg-head tg-btn-head' }, [
			E('h3', { 'class': 'tg-pg-title tg-btn-title' }, E('span', {}, _('Buttons'))),
			E('div', { 'class': 'tginfo-general' }, [
				hd.ico,
				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'class': 'tginfo-reg' }, _('Physical buttons of this router model, available for assigning functions')),
					hd.main,
					E('div', { 'class': 'tginfo-loc' },
						_('Assign actions to this router’s physical buttons. Click a button below to add and configure it.'))
				]),
				E('div', { 'class': 'tginfo-right' }, [ hd.add ])
			])
		]);
		var body = E('div', { 'class': 'tg-btn' }, [ head ]);
		Promise.all([ L.resolveDefault(detect(), []), L.resolveDefault(detectLeds(), []), L.resolveDefault(detectServices(), []) ])
			.then(function(res) { fill(res[0] || [], res[1] || [], res[2] || []); });
		return body;

		function fill(buttons, leds, services) {
			var assignable = (buttons || []).filter(function(b) { return !b['default']; });
			hd.ico.classList.toggle('off', !assignable.length);
			if (!assignable.length) {
				hd.main.textContent = _('No assignable buttons were detected on this device');
				hd.add.innerHTML = '';
				return;
			}

			var list = E('div', { 'class': 'tg-btn-list' });
			body.appendChild(list);

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
			function refreshAdd() {
				var n = assignable.filter(function(b) { return shown[b.name]; }).length;
				hd.main.textContent = _('%d of %d buttons configured').format(n, assignable.length);
				hd.ico.classList.toggle('off', n === 0);
				hd.add.innerHTML = '';
				var avail = assignable.filter(function(b) { return !shown[b.name]; });
				if (!avail.length) {
					hd.add.appendChild(E('em', { 'class': 'tg-btn-muted' },
						_('All buttons of this device have been added')));
					return;
				}
				avail.forEach(function(b) {
					var btn = E('button', {
						'class': 'cbi-button cbi-button-add', 'type': 'button',
						'title': b.name + (b.type === 'switch' ? ' · ' + _('switch') : ''),
						'click': function() { addCard(b); }
					}, [ icon('plus', 14), E('span', {}, [ b.label || b.name ]) ]);
					hd.add.appendChild(btn);
				});
			}

			assignable.forEach(function(b) { if (isConfigured(b)) { addCard(b); } });
			refreshAdd();
		}
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
