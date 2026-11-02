'use strict';
'require view';
'require fs';
'require ui';

// duplicated from modemtabs.js on purpose, see docs/subsystems/ui.md#shared-css-and-theme-probes
(function() {
	if (document.getElementById('tg-modem-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-modem-css';
	l.rel = 'stylesheet';
	l.type = 'text/css';
	l.href = L.resource('view/modem5g/modem.css');
	document.head.appendChild(l);
})();

(function() {
	function run() {
		var de = document.documentElement;
		if (de.hasAttribute('data-tg-sec')) { return; }
		de.setAttribute('data-tg-sec', '1');
		var host = document.getElementById('view') || document.getElementById('maincontent') || document.body;
		if (!host) { return; }
		var p = document.createElement('div');
		p.className = 'cbi-section';
		p.style.cssText = 'position:absolute;left:-9999px;top:0;visibility:hidden';
		host.appendChild(p);
		var cs = getComputedStyle(p);
		var bg = cs.backgroundColor || '';
		var framed = (parseFloat(cs.borderTopWidth) > 0 && cs.borderTopStyle !== 'none')
			|| (cs.boxShadow && cs.boxShadow !== 'none')
			|| (bg !== '' && bg !== 'transparent' && !/rgba\([^)]*,\s*0\)$/.test(bg));
		host.removeChild(p);
		if (framed) { de.classList.add('tg-boxed-sec'); }
	}
	if (document.body) { run(); }
	else { document.addEventListener('DOMContentLoaded', run); }
})();

function detect() {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'detect' ]).then(function(res) {
		var j = {};
		try { j = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		return j || {};
	});
}
function setSmsMode(input, action) {
	return fs.exec('/usr/share/5gmodem/buttons.sh', [ 'smsmode', input, action ]);
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

var PRESETS_COMMON = [
	{ label: _('Reboot the modem'), cmd: '/usr/share/5gmodem/reboot_modem.sh soft' },
	{ label: _('Switch SIM slot'), cmd: '/usr/share/5gmodem/simslot.sh set 1' }
];
var PRESETS_SIMPLE = [
	{ label: _('Start service'), cmd: '/usr/share/5gmodem/buttons.sh svc start ssclash' },
	{ label: _('Stop service'),  cmd: '/usr/share/5gmodem/buttons.sh svc stop ssclash' },
	{ label: _('Restart service'), cmd: '/etc/init.d/ssclash restart' }
].concat(PRESETS_COMMON);

// GL-E750/v2 display (mcu-switch); PW/AWG presets only when the service is installed
var MCU = '/usr/bin/mcu-switch';
var PW_ON = "uci set passwall2.@global[0].enabled='1'; uci commit passwall2; /etc/init.d/passwall2 restart";
var PW_OFF = "uci set passwall2.@global[0].enabled='0'; uci commit passwall2; /etc/init.d/passwall2 stop";
function simplePresets(services, mcu) {
	var has = function(s) { return (services || []).indexOf(s) >= 0; };
	var l = [];
	if (has('awg-control')) {
		l.push({ label: _('Start AmneziaWG'), cmd: mcu ? MCU + ' awg on' : '/usr/bin/awg-control on' });
		l.push({ label: _('Stop AmneziaWG'), cmd: mcu ? MCU + ' awg off' : '/usr/bin/awg-control off' });
	}
	if (has('passwall2')) {
		l.push({ label: _('Start Passwall2'), cmd: mcu ? MCU + ' pw on' : PW_ON });
		l.push({ label: _('Stop Passwall2'), cmd: mcu ? MCU + ' pw off' : PW_OFF });
	}
	if (mcu) {
		l.push({ label: _('Show SMS'), cmd: MCU + ' sms',
			help: _('Show SMS on GL-E750 display. Additional settings in "Inbox"') });
		l.push({ label: _('Show Metrics'), cmd: MCU + ' meters',
			help: _('Output system metrics on GL-E750 display: bandwidth via WAN interface, number of connections, load, CPU usage, memory available') });
	}
	return l.concat(PRESETS_SIMPLE);
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

function cmdField(value, presetList) {
	var help = E('div', { 'class': 'cbi-value-description', 'style': 'display:none' });
	var cur = presetList;
	function syncHelp() {
		var h = '';
		(cur || []).forEach(function(p) { if (p.help && p.cmd === input.value.trim()) { h = p.help; } });
		help.textContent = h;
		help.style.display = h ? '' : 'none';
	}
	var input = E('input', {
		'type': 'text', 'spellcheck': 'false', 'autocomplete': 'off',
		'placeholder': _('shell command'), 'value': value || ''
	});
	var menu = E('div', { 'class': 'btnmenu' });
	var body = E('div', { 'class': 'btnterm-body' }, [ input ]);
	var term = E('div', { 'class': 'btnterm' }, [ E('div', { 'class': 'btnterm-hd' }, 'sh'), body ]);
	input.addEventListener('input', syncHelp);
	function fillMenu(list) {
		cur = list;
		syncHelp();
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
	return { input: input, node: E('div', { 'class': 'btncmd' }, [ term, menu, help ]), setPresets: fillMenu };
}

function toggleWidget(on, small) {
	return E('span', { 'class': 'btnsw' + (small ? ' btnsw-sm' : '') + (on ? ' on' : '') });
}

function widget(b, state) {
	var cls = 'btn cbi-button btnhead-card'
		+ (state === 'pressed' ? ' hpressed' : ' hreleased');
	return E('div', { 'class': cls }, [
		E('span', { 'class': 'hname' }, b.label || b.name),
		E('span', { 'class': 'hsub' }, b.name)
	]);
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

function dbcInput(b, mcu) {
	return E('input', { 'type': 'number', 'min': '0', 'class': 'cbi-input-text',
		'value': (b.debounce !== undefined && b.debounce !== '') ? b.debounce : (mcu ? '0' : '10') });
}

function saveStatus() { return E('span', { 'style': 'margin-left:.6em; font-size:90%' }, ''); }
function flashSaved(status) { status.textContent = _('Saved'); status.style.color = '#2ea043';
	window.setTimeout(function() { status.textContent = ''; }, 2500); }
function flashCleared(status) { status.textContent = _('Cleared'); status.style.color = '';
	window.setTimeout(function() { status.textContent = ''; }, 2500); }

function condPresets(services, mcu) {
	return (mcu ? [ { label: _('Toggle Standby mode'), cmd: MCU + ' standby' } ] : []).concat(
		(services || []).map(function(s) {
			return { label: _('Toggle service') + ' · ' + s,
				cmd: '/usr/share/5gmodem/buttons.sh svc toggle ' + s };
		}), PRESETS_COMMON);
}

function statePanel(b, leds, state, services, mcu) {
	var ct0 = (b['ct_' + state] === 'conditional') ? 'conditional' : 'simple';
	var cPre = condPresets(services, mcu);
	var sPre = simplePresets(services, mcu);

	var cmd = cmdField(b['cmd_' + state], ct0 === 'conditional' ? cPre : sPre);

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
		cmd.setPresets(v === 'conditional' ? cPre : sPre);
		simpleLeds.style.display = (v === 'simple') ? '' : 'none';
		condArea.style.display = (v === 'conditional') ? '' : 'none';
	});

	simpleLeds.style.display = (ct0 === 'simple') ? '' : 'none';
	condArea.style.display = (ct0 === 'conditional') ? '' : 'none';

	var node = E('div', { 'style': 'margin-top:.3em' }, [
		E('div', { 'class': 'btncmd-label', 'style': 'margin-bottom:.2em' }, _('Command type:')),
		seg.node,
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

function stateHead(label, help, sw) {
	return E('div', {}, [
		E('div', { 'class': 'btnstate-lbl' }, label),
		help ? E('div', { 'class': 'cbi-value-description', 'style': 'margin:-.3em 0 .45em' }, help) : '',
		sw === undefined ? '' : toggleWidget(sw, false) ]);
}
function sep() { return E('hr', { 'style': 'border:0;border-top:1px solid rgba(127,127,127,.2);margin:1.1em 0' }); }

function buttonCard(b, leds, services, onDelete, mcu) {
	var isSwitch = (b.type === 'switch');
	var isLong = !!mcu && b.name === 'power';
	var card = E('div', { 'class': 'btncard' });
	var dbc = dbcInput(b, mcu);
	var status = saveStatus();

	card.appendChild(E('button', { 'class': 'btn cbi-button cbi-button-remove btncard-del',
		'click': ui.createHandlerFn(this, function() {
			return delBinding(b.name).then(function() {
				if (card.parentNode) { card.parentNode.removeChild(card); }
				if (onDelete) { onDelete(b.name); }
			});
		}) }, _('Delete')));

	var pPanel = statePanel(b, leds, 'pressed', services, mcu);
	var rPanel = statePanel(b, leds, 'released', services, mcu);
	var dPanel = (isSwitch && mcu) ? statePanel(b, leds, 'double', services, mcu) : null;
	var panels = [ [ 'pressed', pPanel ] ];

	if (isLong) {
		card.appendChild(stateHead(_('Long press'), _('Hold right button for 3 s.')));
		card.appendChild(pPanel.node);
	} else if (isSwitch) {
		panels.push([ 'released', rPanel ]);
		card.appendChild(stateHead(_('Switch ON'), '', true));
		card.appendChild(pPanel.node);
		card.appendChild(sep());
		card.appendChild(stateHead(_('Switch OFF'), '', false));
		card.appendChild(rPanel.node);
		if (dPanel) {
			panels.push([ 'double', dPanel ]);
			card.appendChild(sep());
			card.appendChild(stateHead(_('Double flip'), _('Flip switch and back to original position within 2 s.')));
			card.appendChild(dPanel.node);
		}
	} else {
		panels.push([ 'released', rPanel ]);
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
			var ops = [ function() { return setField(b.name, 'debounce', dbc.value); } ];
			panels.forEach(function(pair) {
				var st = pair[0], v = pair[1].getVals();
				ops.push(function() { return setField(b.name, 'ct_' + st, v.ct); });
				ops.push(function() { return setField(b.name, st, v.cmd); });
				if (v.ct === 'conditional') {
					ops.push(function() { return setLeds(b.name, 'on_' + st, v.onLeds); });
					ops.push(function() { return setLeds(b.name, 'off_' + st, v.offLeds); });
				} else {
					ops.push(function() { return setLeds(b.name, st, v.simpleLeds); });
				}
			});
			return ops.reduce(function(p, mk) { return p.then(mk); }, Promise.resolve())
				.then(function() { flashSaved(status); });
		}) }, _('Save'));

	card.appendChild(E('div', { 'class': 'btndbc' }, [
		dbc, E('span', { 'style': 'opacity:.7' }, _('delay between repeats, seconds')) ]));
	card.appendChild(E('div', { 'style': 'margin-top:.9em' }, [ save, status ]));
	return card;
}

function renderButton(b, leds, services, onDelete, mcu) { return buttonCard(b, leds, services, onDelete, mcu); }

function smsModeCard(mcu) {
	var acts = [
		[ 'page', _('Next page') ], [ 'next', _('Next message') ], [ 'prev', _('Previous message') ],
		[ 'replay', _('Replay message') ], [ 'read', _('Mark all read and exit') ], [ 'exit', _('Exit') ]
	];
	var rows = [ [ 'flip', _('Switch flip'), 'page' ], [ 'double', _('Double flip'), 'read' ], [ 'long', _('Long press'), 'exit' ] ];
	var status = saveStatus();
	var sels = rows.map(function(r) {
		var sel = E('select', { 'class': 'cbi-input-select' }, acts.map(function(a) {
			return E('option', { 'value': a[0], 'selected': (mcu[r[0]] || r[2]) === a[0] ? '' : null }, a[1]);
		}));
		return [ r[0], r[1], sel ];
	});
	return E('div', { 'class': 'btncard' }, [
		E('div', { 'class': 'btnstate-lbl' }, _('Show SMS mode')),
		E('div', { 'class': 'cbi-value-description', 'style': 'margin:-.3em 0 .6em' },
			_("Show SMS mode activates if configured in 'Inbox'. Button actions below apply only to this mode.")),
		E('div', {}, sels.map(function(s) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, s[1]),
				E('div', { 'class': 'cbi-value-field' }, s[2]) ]);
		})),
		E('div', { 'style': 'margin-top:.9em' }, [
			E('button', { 'class': 'btn cbi-button cbi-button-save',
				'click': ui.createHandlerFn(this, function() {
					return sels.reduce(function(p, s) {
						return p.then(function() { return setSmsMode(s[0], s[2].value); });
					}, Promise.resolve()).then(function() { flashSaved(status); });
				}) }, _('Save')), status ])
	]);
}

document.addEventListener('click', function() {
	document.querySelectorAll('.btnmenu.open').forEach(function(m) { m.classList.remove('open'); });
});

return view.extend({
	load: function() { return Promise.all([ detect(), detectLeds(), detectServices() ]); },

	render: function(res) {
		var mcu = (res && res[0] && res[0].mcu) || null;
		var buttons = (res && res[0] && res[0].buttons) || [];
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

		var CFG_KEYS = [ 'cmd_pressed', 'cmd_released', 'cmd_double', 'ct_pressed', 'ct_released', 'ct_double',
			'leds_double', 'ledson_double', 'ledsoff_double',
			'leds_pressed', 'leds_released', 'ledson_pressed', 'ledsoff_pressed',
			'ledson_released', 'ledsoff_released' ];
		function isConfigured(b) {
			return CFG_KEYS.some(function(k) { return b[k] && b[k] !== ''; });
		}

		var shown = {};
		function addCard(b) {
			shown[b.name] = true;
			list.appendChild(renderButton(b, leds, services, function(name) { shown[name] = false; refreshAdd(); }, mcu));
			refreshAdd();
		}
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
				}, '+ ' + ((mcu && b.name === 'power') ? _('Long press') : (b.label || b.name))));
			});
		}

		assignable.forEach(function(b) { if (isConfigured(b)) { addCard(b); } });
		refreshAdd();
		if (mcu) { body.appendChild(smsModeCard(mcu)); }
		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
