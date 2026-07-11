'use strict';
'require view';
'require dom';
'require fs';
'require ui';
'require uci';
'require form';
'require tools.widgets as widgets';

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/

/* --- Проверка/установка обновления с GitHub (app + перевод) --- */
function updSet(id, txt) { var e = document.getElementById(id); if (e) { e.textContent = txt; } }
function updShow(id, show) { var e = document.getElementById(id); if (e) { e.style.display = show ? '' : 'none'; } }

function checkUpdate() {
	updSet('upd-status', _('Checking the latest release…'));
	updShow('upd-install', false);
	var b = document.getElementById('upd-check'); if (b) { b.disabled = true; }
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'check' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		updSet('upd-current', d.current || '—');
		updSet('upd-latest', d.latest || '—');
		if (d.release_url) { var a = document.getElementById('upd-release'); if (a) { a.href = d.release_url; a.style.display = ''; } }
		if (!d.success) {
			updSet('upd-status', d.error || _('Could not check for updates.'));
		} else if (d.update_available == 1 || d.update_available === true) {
			updShow('upd-install', true);
			updSet('upd-status', _('A new version is available.'));
		} else {
			updSet('upd-status', _('You have the latest version.'));
		}
	}).catch(function(err) {
		updSet('upd-status', _('Could not check for updates.') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('upd-check'); if (b) { b.disabled = false; }
	});
}

function installUpdate() {
	if (!confirm(_('Download and install the latest version now?'))) { return Promise.resolve(); }
	updSet('upd-status', _('Installing the update…'));
	var bi = document.getElementById('upd-install'), bc = document.getElementById('upd-check');
	if (bi) { bi.disabled = true; } if (bc) { bc.disabled = true; }
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'install' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (!d.success) { updSet('upd-status', d.error || _('Failed to install the update.')); return; }
		updSet('upd-current', d.current || '—');
		updShow('upd-install', false);
		updSet('upd-status', _('Update installed. Reload the page to see the changes.'));
	}).catch(function(err) {
		updSet('upd-status', _('Failed to install the update.') + ' ' + (err.message || err));
	}).finally(function() {
		var bi = document.getElementById('upd-install'), bc = document.getElementById('upd-check');
		if (bi) { bi.disabled = false; } if (bc) { bc.disabled = false; }
	});
}

return view.extend({
	handleCommand: function(exec, args) {
		var buttons = document.querySelectorAll('.diag-action > .cbi-button');

		for (var i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');

		return fs.exec(exec, args).then(function(res) {
			var out = document.getElementById('pre');
			out.style.display = '';

			/* Та же тёмная табличка, что у блоков команд. Лёгкая подсветка:
			   строки трассировки "sh -x" (+ команда) - голубым, stderr - красным. */
			var lines = ((res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')).split('\n');
			var spans = lines.map(function(ln) {
				var color = '#d6e0ea';
				if (/^\++ /.test(ln)) { color = '#7db2ff'; }
				return E('div', { 'style': 'color:' + color }, ln.length ? ln : ' ');
			});
			dom.content(document.getElementById('preout'), spans);
			fs.write('/tmp/debug_result.txt', [ res.stdout || '' ]);
		}).catch(function(err) {
			ui.addNotification(null, E('p', [ err ]))
		}).finally(function() {
			var viewbc = document.getElementById('clear');
			viewbc.style.display = '';
			var viewbd = document.getElementById('download');
			viewbd.style.display = '';

			for (var i = 0; i < buttons.length; i++)
				buttons[i].removeAttribute('disabled');
		});
	},

	handleUSB: function(ev, cmd) {
		return this.handleCommand('/bin/cat', ['/sys/kernel/debug/usb/devices']);
	},

	handleTTY: function(ev, cmd) {
		return this.handleCommand('/bin/ls', ['/dev']);
	},

	handleDBG: function(ev, cmd) {
		return this.handleCommand('/bin/sh', ['-x', '/usr/share/5gmodem/5gmodem.sh']);
	},

	handleClear: function(ev) {
		var out = document.getElementById('pre');
		out.style.display = 'none';
		dom.content(document.getElementById('preout'), []);
		var viewbc = document.getElementById('clear');
		viewbc.style.display = 'none';
		var viewbd = document.getElementById('download');
		viewbd.style.display = 'none';
		fs.write('/tmp/debug_result.txt', '');
	},

	handleDownload: function(ev) {
		return L.resolveDefault(fs.read_direct('/tmp/debug_result.txt'), null).then(function (res) {
				if (res) {
					var link = E('a', {
						'download': 'debug_result.txt',
						'href': URL.createObjectURL(
							new Blob([ res ], { type: 'text/plain' })),
					});
					link.click();
					URL.revokeObjectURL(link.href);
				}
			}).catch(() => {
				ui.addNotification(null, E('p', {}, _('Download error') + ': ' + err.message));
		});

	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ]), ''),
			fs.list('/dev').then(function(devs) {
				return devs.filter(function(dev) {
					return dev.name.match(/^ttyUSB/) || dev.name.match(/^cdc-wdm/) || dev.name.match(/^ttyACM/) || dev.name.match(/^mhi_/) || dev.name.match(/^wwan/);
				});
			}),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('sms_tool_js'))
		]);
	},

	render: function(res) {
		var json = {};
		try { json = JSON.parse(res[0] || '{}'); } catch (e) {}
		if (!json || typeof json != 'object') json = {};
		var devs = res[1] || [];

		/* ---------------- Настройки модема (бывшая вкладка Modem Settings) --- */
		var m, s, o;
		m = new form.Map('5gmodem', '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		o = s.option(form.Flag, 'auto_port', _('Auto-detect port and interface'),
			_('Automatically find the modem AT port and its network interface (via ModemManager when available). Turn this off to select them manually below.'));
		o.default = '1';
		o.rmempty = false;

		o = s.option(widgets.NetworkSelect, 'network', _('Interface'),
			_('Network interface for Internet access.'));
		o.exclude = s.section;
		o.nocreate = true;
		o.rmempty = true;
		o.depends('auto_port', '0');

		o = s.option(form.Value, 'device',
			_('Port for modem communication'),
			_("Port used to read modem/connection info. <br /> \
				<br />Traditional modem: one of the available ttyUSBX ports.<br /> \
				<br />HiLink modem: enter the IP address 192.168.X.X under which the modem is available."));
		devs.sort((a, b) => a.name > b.name);
		devs.forEach(dev => o.value('/dev/' + dev.name));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');

		o = s.option(form.Value, 'at_port',
			_('Port for AT / SMS / USSD'),
			_('AT command port used for SMS, USSD and AT commands. On most modems it is the same as the modem communication port.'));
		devs.forEach(dev => o.value('/dev/' + dev.name));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* Синхронизируем единый AT-порт в 4 отдельных поля sms_tool_js,
		   которые читают вьюхи приёма/отправки SMS, USSD и AT (их код не
		   меняем). uci.save() формы сбрасывает и sms_tool_js. */
		o.write = function(section_id, value) {
			uci.set('5gmodem', section_id, 'at_port', value);
			var ss = uci.sections('sms_tool_js', 'sms_tool_js');
			var sid = (ss && ss[0]) ? ss[0]['.name'] : null;
			if (sid) {
				[ 'readport', 'sendport', 'ussdport', 'atport' ].forEach(function(k) {
					uci.set('sms_tool_js', sid, k, value);
				});
			}
		};
		o.remove = function(section_id) {
			uci.unset('5gmodem', section_id, 'at_port');
		};

		/* Кнопка: создать сетевой интерфейс модема автоматически. */
		o = s.option(form.Button, '_mkiface');
		o.title = _('Modem interface');
		o.description = _('Create a network interface for the modem automatically (the control protocol is detected). If it already exists, it is just brought up.');
		o.inputtitle = _('Create modem interface');
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/mkiface.sh').then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.result == 'created') {
					ui.addNotification(null, E('p', _('Interface "%s" created (%s), bringing it up…').format(out.iface, out.proto)), 'info');
				} else if (out.result == 'exists') {
					ui.addNotification(null, E('p', _('Interface "%s" already exists — bringing it up.').format(out.iface)), 'info');
				} else {
					ui.addNotification(null, E('p', _('No modem found to create an interface for.')), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to create the modem interface') + ': ' + (err.message || err)), 'error');
			});
		};

		/* ---------------- Информация о модеме (перенесена со страницы Сеть) -- */
		function infoVal(v) {
			return (v != null && String(v).length > 0 && String(v) != '-') ? String(v) : '-';
		}
		function inforow(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
				E('td', { 'class': 'td left tg-info-val' }, [ value ]),
			]);
		}
		var infoRows = [
			inforow(_('Modem type'), infoVal(json.modem)),
			inforow(_('Revision / Firmware'), infoVal(json.firmware)),
			inforow(_('IP adress / Communication Port'), infoVal(json.cport)),
			inforow(_('Protocol'), infoVal(json.protocol)),
		];
		var t = json.mtemp;
		if (t != null && String(t).length > 1 && String(t).indexOf(' ') < 0 && String(t) != '-') {
			infoRows.push(inforow(_('Chip Temperature'), String(t).replace('&deg;', '°')));
		}

		var modemInfo = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Modem Information') ]),
			E('table', { 'class': 'table tg-info-table' }, infoRows)
		]);

		/* ---------------- Диагностика (как было) ---------------------------- */
		var termBlock = function(cmd) {
			var parts = cmd.split(' ');
			var spans = [ E('span', { 'style': 'color:#34d399;user-select:none;' }, '$ ') ];
			parts.forEach(function(tok, i) {
				var color = (i == 0) ? '#7db2ff' : (tok.charAt(0) == '-' ? '#e6b84c' : '#d6e0ea');
				spans.push(E('span', { 'style': 'color:' + color }, tok + (i < parts.length - 1 ? ' ' : '')));
			});
			return E('div', { 'class': 'tg-code' }, [
				E('div', { 'class': 'tg-code-lang' }, 'bash'),
				E('div', { 'class': 'tg-code-body' }, spans)
			]);
		};

		var table = E('table', { 'class': 'table tg-diag-table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("USB debug information")
						),
						termBlock('cat /sys/kernel/debug/usb/devices'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleUSB')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check availability of ttyX ports")
						),
						termBlock('ls /dev'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleTTY')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check data read by the 5gmodem scripts")
						),
						termBlock('sh -x /usr/share/5gmodem/5gmodem.sh'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleDBG')
							}, [ _('Debug') ])
						])
					]),
				])
			]);

		document.head.append(E('style', {'type': 'text/css'},
`
.tg-code {
  background: #161c26;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  margin: 10px 12px 12px 0;
  overflow: hidden;
  font-family: monospace;
  max-width: 420px;
}
.tg-code-lang {
  font-size: 10px;
  color: #8b95a7;
  padding: 4px 12px;
  background: rgba(255, 255, 255, 0.04);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  letter-spacing: 0.06em;
}
.tg-code-body {
  padding: 9px 12px;
  font-size: 12px;
  line-height: 1.5;
  white-space: pre;
  overflow-x: auto;
}

/* Заголовки колонок: резервируем две строки, чтобы блоки кода и
   кнопки во всех трёх колонках были на одном уровне независимо от
   того, переносится заголовок или нет (в proton2025 русские
   заголовки длиннее и переносятся). */
.tg-diag-table .td {
  vertical-align: top;
}
.tg-diag-table .td > .cbi-value-title {
  display: block;
  min-height: 2.9em;
  line-height: 1.4;
}

/* Таблицы-раскладки без линий и фонов тем */
.tg-diag-table,
.tg-diag-table .tr,
.tg-diag-table .td,
.tg-info-table,
.tg-info-table .tr,
.tg-info-table .td {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}
.tg5g h3 {
  margin-top: 0;
}

/* Лишняя разделительная полоса под флагом «Автоопределение …»: когда
   ручные поля скрыты (depends), в proton2025 они остаются в DOM как
   display:none и не дают флагу стать :last-child, из-за чего видна его
   нижняя граница. Убираем границу у последнего ВИДИМОГО ряда формы. */
.tg-modem-form .cbi-value:not([style*="none"]):not(:has(~ .cbi-value:not([style*="none"]))) {
  border-bottom: none;
}

/* Вторая колонка «Информация о модеме» - моноширинным, как терминал */
.tg-info-table .tg-info-val {
  font-family: var(--font-monospace, monospace);
}

/* На узких/мобильных экранах три колонки диагностики складываются в
   столбик, иначе третья («Проверка данных скриптами 5gmodem») уезжает
   за край и не переносится. */
@media (max-width: 640px) {
  .tg-diag-table,
  .tg-diag-table .tr,
  .tg-diag-table .td {
    display: block;
    width: 100% !important;
  }
  .tg-diag-table .td {
    padding-left: 0;
    padding-right: 0;
  }
  .tg-diag-table .td > .cbi-value-title {
    min-height: 0;
  }
}
`));

		/* Блок проверки/установки обновления (над Диагностикой) */
		var updateBlock = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Update') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('luci-app-5gmodem')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'id': 'upd-check',
							'click': ui.createHandlerFn(this, function() { return checkUpdate(); })
						}, [ _('Check for updates') ]),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'id': 'upd-install',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, function() { return installUpdate(); })
						}, [ _('Install update') ]),
						E('a', {
							'class': 'cbi-button',
							'id': 'upd-release',
							'href': 'https://github.com/fildunsky/luci-app-5gmodem/releases/latest',
							'target': '_blank', 'rel': 'noopener',
							'style': 'display:none'
						}, [ _('Release page') ]),
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'upd-current' }, [ '—' ]) ]),
						E('div', {}, [ _('Latest version') + ': ', E('strong', { 'id': 'upd-latest' }, [ '—' ]) ]),
						E('div', { 'id': 'upd-status', 'style': 'margin-top:4px' }, [ _('It also installs the translation if available.') ]),
					]),
				]),
			]),
		]);

		var diag = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Diagnostics') ]),
			table,
			E('div', {}, [
				E('p'),
				E('div', { 'id': 'pre', 'class': 'tg-code', 'style': 'display:none; max-width:none; margin:0;' }, [
					E('div', { 'class': 'tg-code-lang' }, 'bash'),
					E('pre', { 'id': 'preout', 'class': 'tg-code-body', 'style': 'max-height:460px; overflow:auto; margin:0;' }, [])
				]),
				E('p'),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clear',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-apply important',
						'id': 'download',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleDownload')
					}, [ _('Download') ]),
				]),
			])
		]);

		/* Форма настроек рендерится асинхронно; собираем страницу целиком:
		   Информация о модеме -> Настройки -> Диагностика. Save/Apply внизу
		   применяется к form.Map (единственный .cbi-map на странице). */
		return Promise.resolve(m.render()).then(function(formNode) {
			return E('div', {}, [
				modemInfo,
				E('div', { 'class': 'tg-modem-form' }, [ formNode ]),
				updateBlock,
				diag
			]);
		});
	}
});
