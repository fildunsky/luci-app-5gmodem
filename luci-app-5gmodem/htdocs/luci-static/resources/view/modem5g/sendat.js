'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require sms-tool-5gm.editors as editors';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

/* Строка шаблона AT: "подпись;команда[;команда...]" - разделитель ';' служит и
   для отделения подписи, и для перечисления команд. Собирая команды обратно,
   их надо СКЛЕИТЬ В ОДНУ AT-строку по правилам V.250/27.007: префикс "AT"
   допустим РОВНО ОДИН РАЗ, в самом начале; последующие команды идут без него.
   Раньше склейка сохраняла "AT" у каждой, и модем получал
   AT+CPBS="ON";AT+CNUM - проверено на живом модеме: "No response from modem." /
   "NO CARRIER". Правильный вид AT+CPBS="ON";+CNUM отвечает нормально. Из-за
   этого не работали ровно те строки шаблона, где команд больше одной.
   Снимаем "AT" только у РАСШИРЕННЫХ команд, т.е. начинающихся с + ^ $ * или #:
   у базовых (ATI, ATZ) обрезка префикса сломала бы саму команду. */
function atChain(cmds) {
	return cmds.map(function(c, i) {
		c = String(c).trim();
		return (i === 0) ? c : c.replace(/^at(?=[+^$*#])/i, '');
	}).join(';');
}

/* РАЗБОР СТРОКИ ШАБЛОНА - ОДИН НА ВСЕ ТРИ МЕСТА, ГДЕ ОН БЫЛ СКОПИРОВАН.
   ФОРМАТ, КОТОРЫЙ ХОЧЕТСЯ ПИСАТЬ:
       Название ➜ AT-команда
   Одна строка, одна команда. Цепочку пишем как обычно, через точку с запятой:
       Оператор ➜ AT+COPS=3,0;+COPS?
   Стрелка любая: «➜», «→» или «->».

   СТАРЫЙ ФОРМАТ ТОЖЕ ЖИВ, иначе у людей разом перестали бы работать их
   собственные файлы. Он выглядел так:
       Название ➜ ATI;ATI
   то есть слева от точки с запятой была ПОДПИСЬ (в неё для наглядности вписывали
   команду), а справа - сама команда, из-за чего команду приходилось писать
   дважды. Отличаем по простому признаку: если первая часть в точности равна
   второй, это дубль из старого формата - отбрасываем его. Ни одна настоящая
   цепочка не начинается с двух одинаковых команд подряд.

   Без стрелки строка читается по-старому: «имя;команда;команда». */
function parseTemplateLine(line) {
	var s = String(line || '').trim();
	if (!s) { return null; }
	var m = s.match(/^(.*?)\s*(?:➜|→|->)\s*(.*)$/);
	if (m) {
		var name = m[1].trim();
		var parts = m[2].split(';');
		if (parts.length > 1 && parts[0].trim() === parts[1].trim()) { parts.shift(); }
		var code = atChain(parts);
		if (!code) { return null; }
		return { name: (name || code), code: code };
	}
	var f = s.split(';');
	return { name: f[0].trim(), code: atChain(f.slice(1)) || f[0].trim() };
}

/* Подпись в выпадающем списке: имя и сама команда - чтобы было видно, что
   именно уйдёт в модем, и при этом не приходилось дублировать её в файле. */
function templateLabel(t) {
	return (t.name === t.code) ? t.code : (t.name + ' → ' + t.code);
}

/* СЕМЕЙНЫЙ ФАЙЛ AT-ШАБЛОНОВ ПО АКТИВНОМУ МОДЕМУ (запрос владельца): раньше
   один смешанный шаблон предлагал вендорные команды всем подряд - новичок жал
   команду не своего модема, получал ERROR и думал, что сломана программа.
   Ключуем как профили modem/usb: точный vid:pid, затем вендор, затем модель.
   05c6:90d5/9025 двусмысленны (Foxconn T99W175 или прототип Compal - один ID)
   - различаем по модели, тем же признаком, что iscompal.sh. Нет уверенного
   совпадения - null, останется generic. */
function atFamilyFor(vp, model) {
	vp = String(vp || '').toLowerCase();
	var m = String(model || '').toLowerCase();
	if (/compal|vos_5g|rxm|sg500/.test(m)) { return 'compal'; }
	if (/fm350/.test(m) || vp.indexOf('0e8d:') === 0) { return 'fm350'; }
	if (/l850|l860/.test(m) || vp === '8087:095a') { return 'xmm'; }
	if (vp === '1e2d:00b3' || vp === '1e2d:00b7' || vp === '1e2d:00b8'
		|| vp === '1e2d:00b9' || vp === '05c6:90d6') { return 'compal'; }
	if (vp.indexOf('1bc7:') === 0 || /telit|lm9/.test(m)) { return 'telit'; }
	if (vp.indexOf('2c7c:') === 0 || /quectel|^e[gmp]\d|^r[gm]5/.test(m)) { return 'quectel'; }
	if (vp.indexOf('1e0e:') === 0 || /simcom|sim7/.test(m)) { return 'simcom'; }
	if (vp.indexOf('12d1:') === 0 || /huawei/.test(m)) { return 'huawei'; }
	if (vp === '413c:81d7' || vp === '0489:e0b5' || vp === '05c6:9025'
		|| vp === '05c6:90d5' || /t99w|t77w|dw58|mv31/.test(m)) { return 'qualcomm'; }
	return null;
}

/* Путь к файлу шаблона: семейные лежат в atcmmds/, личный («Мои команды») -
   легаси-файл atcmmds.user в корне, в списке он представлен именем "__user__". */
function atFilePath(name) {
	return (name === '__user__') ? '/etc/5gmodem/modem/atcmmds.user'
	                             : '/etc/5gmodem/modem/atcmmds/' + name;
}


/* Вывод в стиле блока кода современных md-редакторов - как на странице
   диагностики 5gmodem. Цвета фиксированные, одинаковы в любой теме.
   Шапка с меткой делается через ::before, чтобы не менять логику
   показа/скрытия самого <pre>. */
/* «Печатающийся терминал»: выводим ответ ПОСИМВОЛЬНО, с мигающим курсором в
   конце. Уважаем prefers-reduced-motion (там сразу целиком). Скорость подгоняем
   под длину - длинный дамп не должен печататься минуту. Предыдущую анимацию
   отменяем, если пришёл новый ответ. */
function typewrite(el, text) {
	el.classList.add('has-output');
	if (el._twTimer) { clearInterval(el._twTimer); el._twTimer = null; }
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
		el.textContent = text;
		return;
	}
	el.textContent = '';
	var i = 0, n = text.length;
	var step = Math.max(1, Math.ceil(n / 90));   // весь вывод ~ за 1.3 c
	el._twTimer = setInterval(function() {
		if (i >= n) { clearInterval(el._twTimer); el._twTimer = null; return; }
		el.textContent += text.slice(i, i + step);
		i += step;
		el.scrollTop = el.scrollHeight;
	}, 28);
}

return view.extend({
	viewName: 'sendat',
	
	/* Выбор файла запоминается ПО МОДЕМУ (vid:pid), а не глобально: иначе выбор
	   для FM350 «прилипал» бы к L850 после смены вкладки, и автоподбор по
	   семейству никогда не срабатывал бы. */
	restoreSettingsFromLocalStorage: function() {
		try {
			let selectedFile = localStorage.getItem('luci-app-' + this.viewName
				+ '-selectedFile:' + (window._sendatLmVp || ''));
			return selectedFile;
		} catch(e) {
			console.error('localStorage not available:', e);
			return null;
		}
	},

	saveSettingsToLocalStorage: function(fileName) {
		try {
			localStorage.setItem('luci-app-' + this.viewName
				+ '-selectedFile:' + (window._sendatLmVp || ''), fileName);
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
				var _text = (res.stdout || '') +
					((res.stderr && res.stdout) ? '\n' : '') + (res.stderr || '');
				/* Модем промолчал (sms_tool отдал пусто - порт занят/подвис/убит по
				   таймауту): показываем сообщение, а не пустой мигающий курсор. */
				typewrite(out, _text.trim() ? _text : _('No response from modem'));
			}

		}).catch(function(err) {
			/* res здесь недоступен - он в области then выше. Прежняя проверка на
			   него ссылалась, из-за чего исключение внутри then превращалось в
			   ReferenceError и настоящая ошибка терялась молча. */
			ui.addNotification(null, E('p', [ err ]));
		}).finally(function() {
			for (let i = 0; i < buttons.length; i++)
			buttons[i].removeAttribute('disabled');

		});
	},

	handleGo: function(ev) {
		let atcmd = document.getElementById('cmdvalue').value;
		let port = uci.get('5gmodem', 'sms', 'atport');
		/* Фолбэк - AT-порт секции АКТИВНОГО модема: у MM-модема (Compal) легаси
		   sms.atport пуст, а рабочий порт в его секции есть - консоль писала
		   «укажите порт» при живом ttyUSB (поймано владельцем). */
		if (!port) {
			var _ap = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '').replace(/[^A-Za-z0-9]/g, '_');
			if (_ap) { port = uci.get('5gmodem', 'm_' + _ap, 'at_port') || ''; }
		}
		if (!port) { port = window._sendatLmPort || ''; }

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
			/* Через atcmd.sh, а не бинарь sms_tool напрямую. Раньше в ACL был
			   разрешён exec на /usr/bin/sms_tool, то есть из браузера уходили
			   ЛЮБЫЕ аргументы - и `send`, и `delete all`, и чужой /dev/*.
			   Проверить их на роутере в таком виде нельзя: фильтр был бы в
			   странице, а страница выполняется у пользователя. Теперь порт,
			   форма команды и принадлежность порта модему проверяются на
			   роутере. Произвольная команда при этом остаётся - консоль AT для
			   этого и нужна. */
			return this.handleCommand('/usr/share/5gmodem/atcmd.sh', [ port, atcmd ]);
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

		return fs.read_direct(atFilePath(selectedFile)).then(function(content) {
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
				let t = parseTemplateLine(cmd);
				if (t) {
					let option = document.createElement('option');
					option.value = t.code;
					option.textContent = templateLabel(t);
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
		
		let currentPort = uci.get('5gmodem', 'sms', 'atport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			uci.set('5gmodem', 'sms', 'atport', newModem.comm_port);
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
		/* Фолбэк-порт для MM-модема: его секция БЕЗ at_port намеренно (порт
		   принадлежит ModemManager), но физические tty есть - берём ВТОРОЙ
		   AT-порт активного модема из listmodems (первый обычно занят MM).
		   atcmd.sh на роутере всё равно сверит принадлежность порта модему. */
		window._sendatLmPort = '';
		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/atcmmds.user'), null),
			L.resolveDefault(fs.list('/etc/5gmodem/modem/atcmmds'), []),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('defmodems'))
		]).then(function(res) {
			/* СТРОГО ПОСЛЕ uci.load: active_modem иначе читался до загрузки
			   конфига (undefined) и фолбэк не наполнялся никогда */
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh', []), '[]').then(function(out) {
				try {
					var act = String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '');
					(JSON.parse(out) || []).forEach(function(m) {
						if (m.path === act && m.tty && m.tty.length) {
							window._sendatLmPort = m.tty[0];
						}
						/* vid:pid и модель активного модема - для автовыбора
						   семейного файла AT-шаблонов (см. atFamilyFor). */
						if (m.path === act) {
							window._sendatLmVp = String(m.vidpid || '').toLowerCase();
							window._sendatLmModel = String(m.model || '');
						}
					});
				} catch (e) {}
				return res;
			});
		});
	},

	render: function (loadResults) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */

	let info = _('User interface for sending AT commands using sms-tool').format('');
	
		let sections = uci.sections('defmodems', 'defmodems');
		let serialModems = [];
		
		if (sections && sections.length > 0) {
			serialModems = sections.filter(function(s) {
				return s.modemdata === 'serial';
			});
		}
		
		let currentPort = uci.get('5gmodem', 'sms', 'atport');
		let currentModem = serialModems.find(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (!currentModem && serialModems.length > 0) currentModem = serialModems[0];
		
		let atFiles = loadResults[1] || [];
		let userFiles = atFiles.filter(function(file) {
			return file.type === 'file' && file.name && file.name.match(/\.user$/);
		});
		/* Порядок кнопок: GENERIC первым (нужен всем), дальше семейные по
		   алфавиту, личный «Мои команды» - последним отдельным пунктом. */
		userFiles.sort(function(a, b) {
			var ga = (a.name === 'generic.user') ? 0 : 1;
			var gb = (b.name === 'generic.user') ? 0 : 1;
			return (ga - gb) || a.name.localeCompare(b.name);
		});
		if (loadResults[0]) { userFiles.push({ type: 'file', name: '__user__' }); }
	
		return E('div', { 'class': 'cbi-map', 'id': 'map' }, [
				E('div', { 'class': 'cbi-section tgpage' }, [
					E('div', { 'class': 'cbi-section-node' }, [
						(function() {
							if (serialModems.length > 0) {
								let label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
								let buttonsDisabled = (serialModems.length > 1) ? null : true;
								
								return E('div', { 'class': 'cbi-value' }, [
									E('label', { 'class': 'cbi-value-title' }, [ _('Select modem') ]),
									E('div', { 'class': 'cbi-value-field' }, [
										E('div', { 'class': 'controls' }, [
											E('div', { 'class': 'pager center tg-row' }, [
												E('button', { 
													'class': 'btn cbi-button-neutral prev', 
													'aria-label': _('Previous modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'class': 'tg-col-narrow',
													'disabled': buttonsDisabled
												}, [ ' ◄ ' ]),
												E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
												E('button', { 
													'class': 'btn cbi-button-neutral next', 
													'aria-label': _('Next modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'class': 'tg-col-narrow',
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
								/* Приоритет выбора файла: явный выбор пользователя ДЛЯ
								   ЭТОГО модема (localStorage по vid:pid) -> семейный
								   файл активного модема -> generic -> первый в списке. */
								let savedFile = this.restoreSettingsFromLocalStorage();
								let fam = atFamilyFor(window._sendatLmVp, window._sendatLmModel);
								let fileToLoad = userFiles[0].name;
								let checkedIndex = 0;
								[savedFile, (fam ? fam + '.user' : null), 'generic.user'].some(function(want) {
									if (!want) { return false; }
									let idx = userFiles.findIndex(function(f) { return f.name === want; });
									if (idx !== -1) { fileToLoad = want; checkedIndex = idx; return true; }
									return false;
								});

								setTimeout(function() {
									L.resolveDefault(fs.read_direct(atFilePath(fileToLoad)), '').then(function(content) {
										let selectElement = document.getElementById('tk');
										if (!selectElement) return;

										selectElement.innerHTML = '';
										// плейсхолдер первым пунктом (см. handleFileChange)
										let ph = document.createElement('option');
										ph.value = ''; ph.textContent = '—'; ph.disabled = true; ph.selected = true;
										selectElement.appendChild(ph);

										let commands = (content || '').trim().split('\n');
										commands.forEach(function(cmd) {
											let t = parseTemplateLine(cmd);
											if (t) {
												let option = document.createElement('option');
												option.value = t.code;
												option.textContent = templateLabel(t);
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
												let displayName = (fileName === '__user__')
													? _('My commands')
													: fileName.replace(/\.user$/, '').toUpperCase();
												
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
										'class': 'tg-field',
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
											let t = parseTemplateLine(cmd);
											if (!t) return null;
											return E('option', { 'value': t.code }, templateLabel(t));
										}).filter(function(opt) { return opt !== null; });
									})()
								)
							]) 
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Command to send') ]),
							E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'class': 'tg-field',
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
