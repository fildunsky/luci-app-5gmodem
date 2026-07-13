'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem.modemtabs as modemtabs';
'require sms-tool-js.editors as editors';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/


/* Вывод в стиле блока кода современных md-редакторов - как на странице
   диагностики 5gmodem. Цвета фиксированные, одинаковы в любой теме.
   Шапка с меткой делается через ::before, чтобы не менять логику
   показа/скрытия самого <pre>. */
document.head.append(E('style', {'type': 'text/css'},
`
pre.atcommand-output {
  background: #161c26;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  color: #d6e0ea;
  font-family: monospace;
  font-size: 12px;
  line-height: 1.5;
  padding: 9px 12px;
  overflow: auto;
  white-space: pre-wrap;
}
pre.atcommand-output::before {
  content: 'at';
  display: block;
  font-size: 10px;
  color: #8b95a7;
  letter-spacing: 0.06em;
  background: rgba(255, 255, 255, 0.04);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  margin: -9px -12px 9px;
  padding: 4px 12px;
}
`));

return view.extend({
	viewName: 'sendat',
	
	restoreSettingsFromLocalStorage: function() {
		try {
			let selectedFile = localStorage.getItem('luci-app-' + this.viewName + '-selectedFile');
			return selectedFile;
		} catch(e) {
			console.error('localStorage not available:', e);
			return null;
		}
	},
	
	saveSettingsToLocalStorage: function(fileName) {
		try {
			localStorage.setItem('luci-app-' + this.viewName + '-selectedFile', fileName);
		} catch(e) {
			console.error('localStorage not available:', e);
		}
	},
	
	handleCommand: function(exec, args) {
		let buttons = document.querySelectorAll('.cbi-button');

		for (let i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');
			
		return fs.exec(exec, args).then(function(res) {
			let out = document.querySelector('.atcommand-output');
			out.style.display = '';

			res.stdout = res.stdout?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';
			res.stderr = res.stderr?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';
			
			if (res.stdout === undefined || res.stderr === undefined || res.stderr.includes('undefined') || res.stdout.includes('undefined')) {
				return;
			}
			else {
				dom.content(out, [ res.stdout || '', res.stderr || '' ]);
			}
			
		}).catch(function(err) {
			if (res.stdout === undefined || res.stderr === undefined || res.stderr.includes('undefined') || res.stdout.includes('undefined')) {
				return;
			}
			else {
				ui.addNotification(null, E('p', [ err ]));
			}
		}).finally(function() {
			for (let i = 0; i < buttons.length; i++)
			buttons[i].removeAttribute('disabled');

		});
	},

	handleGo: function(ev) {
		let atcmd = document.getElementById('cmdvalue').value;
		let sections = uci.sections('sms_tool_js');
		let port = sections[0].atport;

		if ( atcmd.length < 2 )
		{
			ui.addNotification(null, E('p', _('Please specify the command to send')), 'info');
			return false;
		}
		else {
		if ( !port )
			{
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
			}
			else {
			//sms_tool -d /dev/ttyUSB1 at "ati"
			return this.handleCommand('sms_tool', [ '-d' , port , 'at' , atcmd ]);
			}
		}
		if ( !port )
		{
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
		}
	},

	handleClear: function(ev) {
		let out = document.querySelector('.atcommand-output');
		out.style.display = 'none';

		let ov = document.getElementById('cmdvalue');
		ov.value = '';

		document.getElementById('cmdvalue').focus();
	},

	handleCopy: function(ev) {
		let out = document.querySelector('.atcommand-output');
		out.style.display = 'none';

		let ov = document.getElementById('cmdvalue');
		ov.value = '';
		let x = document.getElementById('tk').value;
		ov.value = x;
	},

	handleFileChange: function(ev) {
		let selectedFile = ev.target.value;
		let selectElement = document.getElementById('tk');
		
		if (!selectElement || !selectedFile) return;
		
		this.saveSettingsToLocalStorage(selectedFile);
		
		return fs.read_direct('/etc/modem/atcmmds/' + selectedFile).then(function(content) {
			selectElement.innerHTML = '';
			// Плейсхолдер первым пунктом: иначе первая реальная команда (AT)
			// уже "выбрана" и повторный клик по ней не даёт события change,
			// то есть её нельзя применить. С плейсхолдером выбор любой
			// команды, включая первую, всегда генерирует change.
			let ph = document.createElement('option');
			ph.value = ''; ph.textContent = '—'; ph.disabled = true; ph.selected = true;
			selectElement.appendChild(ph);

			let commands = (content || '').trim().split('\n');
			commands.forEach(function(cmd) {
				if (cmd.trim()) {
					let fields = cmd.split(/;/);
					let name = fields[0];
					let code = fields.slice(1).join(";") || fields[0];
					let option = document.createElement('option');
					option.value = code;
					option.textContent = name;
					selectElement.appendChild(option);
				}
			});

			let cmdInput = document.getElementById('cmdvalue');
			if (cmdInput) cmdInput.value = '';
		}).catch(function(err) {
			console.error('Error loading AT commands file:', err);
			ui.addNotification(null, E('p', _('Error loading AT commands file: ') + selectedFile), 'error');
		});
	},

	handleModemChange: function(ev) {
		let sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		let serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		let currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'atport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			uci.set('sms_tool_js', '@sms_tool_js[0]', 'atport', newModem.comm_port);
			uci.save();
			uci.apply().then(function() {
				let modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					let label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	load: function() {
		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/modem/atcmmds.user'), null),
			L.resolveDefault(fs.list('/etc/modem/atcmmds'), []),
			uci.load('sms_tool_js'),
			L.resolveDefault(uci.load('defmodems'))
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */

	let info = _('User interface for sending AT commands using sms-tool.').format('');
	
		let sections = uci.sections('defmodems', 'defmodems');
		let serialModems = [];
		
		if (sections && sections.length > 0) {
			serialModems = sections.filter(function(s) {
				return s.modemdata === 'serial';
			});
		}
		
		let currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'atport');
		let currentModem = serialModems.find(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (!currentModem && serialModems.length > 0) currentModem = serialModems[0];
		
		let atFiles = loadResults[1] || [];
		let userFiles = atFiles.filter(function(file) {
			return file.type === 'file' && file.name && file.name.match(/\.user$/);
		});
	
		return E('div', { 'class': 'cbi-map', 'id': 'map' }, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-node' }, [
						(function() {
							if (serialModems.length > 0) {
								let label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
								let buttonsDisabled = (serialModems.length > 1) ? null : true;
								
								return E('div', { 'class': 'cbi-value' }, [
									E('label', { 'class': 'cbi-value-title' }, [ _('Select modem') ]),
									E('div', { 'class': 'cbi-value-field' }, [
										E('div', { 'class': 'controls' }, [
											E('div', { 'class': 'pager center', 'style': 'display: flex; align-items: center; gap: 10px;' }, [
												E('button', { 
													'class': 'btn cbi-button-neutral prev', 
													'aria-label': _('Previous modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'style': 'min-width: 40px;',
													'disabled': buttonsDisabled
												}, [ ' ◄ ' ]),
												E('div', { 'class': 'text modem-display-text', 'style': 'flex: 1; text-align: center;' }, [ label ]),
												E('button', { 
													'class': 'btn cbi-button-neutral next', 
													'aria-label': _('Next modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'style': 'min-width: 40px;',
													'disabled': buttonsDisabled
												}, [ ' ► ' ])
											])
										])
									])
								]);
							} else {
								return E('div');
							}
						}.bind(this))(),
						(function() {
							if (userFiles.length > 0) {
								let savedFile = this.restoreSettingsFromLocalStorage();
								let fileToLoad = userFiles[0].name;
								let checkedIndex = 0;
								
								if (savedFile) {
									let foundIndex = userFiles.findIndex(function(f) {
										return f.name === savedFile;
									});
									if (foundIndex !== -1) {
										fileToLoad = savedFile;
										checkedIndex = foundIndex;
									}
								}
								
								setTimeout(function() {
									L.resolveDefault(fs.read_direct('/etc/modem/atcmmds/' + fileToLoad), '').then(function(content) {
										let selectElement = document.getElementById('tk');
										if (!selectElement) return;

										selectElement.innerHTML = '';
										// плейсхолдер первым пунктом (см. handleFileChange)
										let ph = document.createElement('option');
										ph.value = ''; ph.textContent = '—'; ph.disabled = true; ph.selected = true;
										selectElement.appendChild(ph);

										let commands = (content || '').trim().split('\n');
										commands.forEach(function(cmd) {
											if (cmd.trim()) {
												let fields = cmd.split(/;/);
												let name = fields[0];
												let code = fields.slice(1).join(";") || fields[0];
												let option = document.createElement('option');
												option.value = code;
												option.textContent = name;
												selectElement.appendChild(option);
											}
										});
									}).catch(function(err) {
										console.error('Error loading initial AT commands file:', err);
									});
								}, 100);
								
								return E('div', { 'class': 'cbi-value' }, [
									E('label', { 'class': 'cbi-value-title' }, [ _('Defined AT command files') ]),
									E('div', { 'class': 'cbi-value-field' }, 
										E('div', {}, 
											userFiles.map(function(file, index) {
												let fileName = file.name;
												let displayName = fileName.replace(/\.user$/, '').toUpperCase();
												
												return E('label', {
													'style': 'margin-right: 15px; display:inline-flex;align-items:center;gap:6px;vertical-align:middle;',
													'data-tooltip': _('Select file with AT commands to load')
												}, [
													E('input', {
														'type': 'radio',
														'name': 'at_file',
														'value': fileName,
														'change': ui.createHandlerFn(this, 'handleFileChange'),
														'checked': index === checkedIndex ? true : null
													}),
													' ',
													displayName
												]);
											}.bind(this))
										)
									)
								]);
							} else {
								return E('div');
							}
						}.bind(this))(),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('User AT commands') ]),
							E('div', { 'class': 'cbi-value-field' }, [
								E('select', { 'class': 'cbi-input-select',
										'id': 'tk',
										'style': 'margin:5px 0; width:100%;',
										'change': ui.createHandlerFn(this, 'handleCopy'),
										'mousedown': ui.createHandlerFn(this, 'handleCopy')
									    },
									(function() {
										let content = '';
										if (userFiles.length === 0 && loadResults[0]) {
											content = loadResults[0];
										}
										
										if (!content || !content.trim()) {
											return [E('option', { 'value': '' }, _('No AT commands available'))];
										}
										
										return content.trim().split("\n").map(function(cmd) {
											if (!cmd.trim()) return null;
											let fields = cmd.split(/;/);
											let name = fields[0];
											let code = fields.slice(1).join(";") || fields[0];
											return E('option', { 'value': code }, name );
										}).filter(function(opt) { return opt !== null; });
									})()
								)
							]) 
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Command to send') ]),
							E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'style': 'margin:5px 0; width:100%;',
								'type': 'text',
								'id': 'cmdvalue',
								'data-tooltip': _('Press [Enter] to send the command, press [Delete] to delete the command'),
								'keydown': function(ev) {
									 if (ev.keyCode === 13)  
										{
										let execBtn = document.getElementById('execute');
											if (execBtn) {
												execBtn.click();
											}
										}
									 if (ev.keyCode === 46)  
										{
										let del = document.getElementById('cmdvalue');
											if (del) {
												let ov = document.getElementById('cmdvalue');
												ov.value = '';
												document.getElementById('cmdvalue').focus();
											}
										}
								    }																														
								}),
							])
						]),
					])
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(this, function() {
							new editors.atCommandsManagerDialog(_('AT templates')).show();
						})
					}, [ _('AT templates') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear form') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-action important',
						'id': 'execute',
						'click': ui.createHandlerFn(this, 'handleGo')
					}, [ _('Send command') ]),
				]),
				E('p', _('Reply')),
				E('pre', { 'class': 'atcommand-output', 'style': 'display:none' }),

			]);
	}
});
