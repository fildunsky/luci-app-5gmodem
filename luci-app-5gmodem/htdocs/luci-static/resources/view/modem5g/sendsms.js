'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require sms-tool-5gm.editors as editors';
'require sms-tool-5gm.smssettings as smssettings';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

/* Binary used for SMS operations: on modems managed by ModemManager
   (MBIM/QMI, e.g. Compal RXM-G1) sms_tool on the AT port never sees
   incoming messages and cannot send - use the mmcli wrapper instead.
   The sms_via_mm option is set by the hotplug script (by VID:PID) or
   by the user. */
/* Выбор бинаря (sms_tool / sms_tool_mm) переехал в smsbridge.sh: транспорт -
   забота моста, страница про него больше не знает. */

return view.extend({

	isUnicode: function(text) {
		// Chars GSM-7
		const gsm7chars = '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
		const gsm7extended = '^{}\\[~]|€';
		
		for (let i = 0; i < text.length; i++) {
			let char = text.charAt(i);
			if (gsm7chars.indexOf(char) === -1 && gsm7extended.indexOf(char) === -1) {
				return true; // None GSM-7
			}
		}
		return false; // All GSM-7
	},

	getGSM7Length: function(text) {
		const gsm7extended = '^{}\\[~]|€';
		let length = 0;
		
		for (let i = 0; i < text.length; i++) {
			let char = text.charAt(i);
			if (gsm7extended.indexOf(char) !== -1) {
				length += 2;
			} else {
				length += 1;
			}
		}
		return length;
	},

	getUnicodeLength: function(text) {
		let length = 0;
		
		for (let i = 0; i < text.length; i++) {
			let charCode = text.charCodeAt(i);
			
			if (charCode >= 0xD800 && charCode <= 0xDBFF) {
				length += 2;
				i++;
			} else {
				length += 1;
			}
		}
		return length;
	},

	normalizeToGSM7: function(text) {
		return text
			// PL
			.replace(/ą/g, 'a').replace(/Ą/g, 'A')
			.replace(/ć/g, 'c').replace(/Ć/g, 'C')
			.replace(/ę/g, 'e').replace(/Ę/g, 'E')
			.replace(/ł/g, 'l').replace(/Ł/g, 'L')
			.replace(/ń/g, 'n').replace(/Ń/g, 'N')
			.replace(/ó/g, 'o').replace(/Ó/g, 'O')
			.replace(/ś/g, 's').replace(/Ś/g, 'S')
			.replace(/ż/g, 'z').replace(/Ż/g, 'Z')
			.replace(/ź/g, 'z').replace(/Ź/g, 'Z')
			// EU
			.replace(/á/g, 'a').replace(/Á/g, 'A')
			.replace(/â/g, 'a').replace(/Â/g, 'A')
			.replace(/ã/g, 'a').replace(/Ã/g, 'A')
			.replace(/ā/g, 'a').replace(/Ā/g, 'A')
			.replace(/č/g, 'c').replace(/Č/g, 'C')
			.replace(/ď/g, 'd').replace(/Ď/g, 'D')
			.replace(/đ/g, 'd').replace(/Đ/g, 'D')
			.replace(/é/g, 'e').replace(/É/g, 'E')
			.replace(/ě/g, 'e').replace(/Ě/g, 'E')
			.replace(/ë/g, 'e').replace(/Ë/g, 'E')
			.replace(/ê/g, 'e').replace(/Ê/g, 'E')
			.replace(/ē/g, 'e').replace(/Ē/g, 'E')
			.replace(/í/g, 'i').replace(/Í/g, 'I')
			.replace(/î/g, 'i').replace(/Î/g, 'I')
			.replace(/ï/g, 'i').replace(/Ï/g, 'I')
			.replace(/ī/g, 'i').replace(/Ī/g, 'I')
			.replace(/ľ/g, 'l').replace(/Ľ/g, 'L')
			.replace(/ň/g, 'n').replace(/Ň/g, 'N')
			.replace(/ô/g, 'o').replace(/Ô/g, 'O')
			.replace(/õ/g, 'o').replace(/Õ/g, 'O')
			.replace(/ö/g, 'o').replace(/Ö/g, 'O')
			.replace(/ő/g, 'o').replace(/Ő/g, 'O')
			.replace(/ř/g, 'r').replace(/Ř/g, 'R')
			.replace(/š/g, 's').replace(/Š/g, 'S')
			.replace(/ş/g, 's').replace(/Ş/g, 'S')
			.replace(/ť/g, 't').replace(/Ť/g, 'T')
			.replace(/ú/g, 'u').replace(/Ú/g, 'U')
			.replace(/ů/g, 'u').replace(/Ů/g, 'U')
			.replace(/û/g, 'u').replace(/Û/g, 'U')
			.replace(/ü/g, 'u').replace(/Ü/g, 'U')
			.replace(/ű/g, 'u').replace(/Ű/g, 'U')
			.replace(/ý/g, 'y').replace(/Ý/g, 'Y')
			.replace(/ÿ/g, 'y').replace(/Ÿ/g, 'Y')
			.replace(/ž/g, 'z').replace(/Ž/g, 'Z')
			// SPECIAL
			.replace(/–/g, '-').replace(/—/g, '-')
			.replace(/'/g, '\'').replace(/'/g, '\'')
			.replace(/"/g, '"').replace(/"/g, '"')
			.replace(/„/g, '"').replace(/"/g, '"')
			.replace(/«/g, '"').replace(/»/g, '"')
			.replace(/…/g, '...').replace(/·/g, '.')
			.replace(/•/g, '*').replace(/‣/g, '*')
			.replace(/°/g, 'o').replace(/º/g, 'o')
			.replace(/†/g, '+').replace(/‡/g, '+')
			.replace(/¹/g, '1').replace(/²/g, '2').replace(/³/g, '3')
			.replace(/¼/g, '1/4').replace(/½/g, '1/2').replace(/¾/g, '3/4')
			.replace(/×/g, 'x').replace(/÷/g, '/')
			.replace(/±/g, '+/-')
			.replace(/≈/g, '~').replace(/≠/g, '!=')
			.replace(/≤/g, '<=').replace(/≥/g, '>=')
			.replace(/←/g, '<-').replace(/→/g, '->')
			.replace(/↑/g, '^').replace(/↓/g, 'v')
			// Emoji, etc.
			.replace(/[\u{1F600}-\u{1F64F}]/gu, ':)')
			.replace(/[\u{1F300}-\u{1F5FF}]/gu, '')
			.replace(/[\u{1F680}-\u{1F6FF}]/gu, '')
			.replace(/[\u{1F700}-\u{1F77F}]/gu, '')
			.replace(/[\u{1F780}-\u{1F7FF}]/gu, '')
			.replace(/[\u{1F800}-\u{1F8FF}]/gu, '')
			.replace(/[\u{1F900}-\u{1F9FF}]/gu, '')
			.replace(/[\u{1FA00}-\u{1FA6F}]/gu, '')
			.replace(/[\u{1FA70}-\u{1FAFF}]/gu, '')
			.replace(/[\u{2600}-\u{26FF}]/gu, '')
			.replace(/[\u{2700}-\u{27BF}]/gu, '')
			// UNSUPPORTED
			.replace(/[^\x00-\x7F@£$¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ¡¤§¿äöñüà^{}\\[\]~|€]/g, '');
	},

	updateMessageCounter: function() {
		let textarea = document.getElementById('smstext');
		let text = textarea.value;
		let counter = document.getElementById('counter');
		let gsm7Radio = document.querySelector('input[name="encoding_type"][value="gsm7"]');
		let unicodeRadio = document.querySelector('input[name="encoding_type"][value="unicode"]');
		
		if (this.isUnicode(text)) {
			unicodeRadio.checked = true;
			let maxLength = 70;
			let currentLength = this.getUnicodeLength(text);
			counter.innerHTML = (maxLength - currentLength);
			
			if (currentLength > maxLength) {
				let newText = '';
				let length = 0;
				for (let i = 0; i < text.length; i++) {
					let charCode = text.charCodeAt(i);
					let charLength = 1;
					
					if (charCode >= 0xD800 && charCode <= 0xDBFF && i + 1 < text.length) {
						charLength = 2;
						if (length + charLength <= maxLength) {
							newText += text.charAt(i) + text.charAt(i + 1);
							i++;
						} else {
							break;
						}
					} else {
						if (length + charLength <= maxLength) {
							newText += text.charAt(i);
						} else {
							break;
						}
					}
					length += charLength;
				}
				textarea.value = newText;
				counter.innerHTML = (maxLength - length);
			}
		} else {
			gsm7Radio.checked = true;
			let maxLength = 160;
			let currentLength = this.getGSM7Length(text);
			counter.innerHTML = (maxLength - currentLength);
			
			if (currentLength > maxLength) {
				let newText = '';
				let length = 0;
				for (let i = 0; i < text.length; i++) {
					let char = text.charAt(i);
					let charLength = ('^{}\\[~]|€'.indexOf(char) !== -1) ? 2 : 1;
					if (length + charLength <= maxLength) {
						newText += char;
						length += charLength;
					} else {
						break;
					}
				}
				textarea.value = newText;
				counter.innerHTML = (maxLength - length);
			}
		}
	},

	handleEncodingChange: function(ev) {
		let textarea = document.getElementById('smstext');
		let text = textarea.value;
		let encodingType = ev.target.value;
		let counter = document.getElementById('counter');
		
		if (encodingType === 'gsm7') {
			textarea.value = this.normalizeToGSM7(text);
			let currentLength = this.getGSM7Length(textarea.value);
			let maxLength = 160;
			
			if (currentLength > maxLength) {
				let newText = '';
				let length = 0;
				for (let i = 0; i < textarea.value.length; i++) {
					let char = textarea.value.charAt(i);
					let charLength = ('^{}\\[~]|€'.indexOf(char) !== -1) ? 2 : 1;
					if (length + charLength <= maxLength) {
						newText += char;
						length += charLength;
					} else {
						break;
					}
				}
				textarea.value = newText;
				currentLength = this.getGSM7Length(textarea.value);
			}
			counter.innerHTML = (maxLength - currentLength);
		} else {
			let maxLength = 70;
			let currentLength = this.getUnicodeLength(textarea.value);
			
			if (currentLength > maxLength) {
				let newText = '';
				let length = 0;
				for (let i = 0; i < textarea.value.length; i++) {
					let charCode = textarea.value.charCodeAt(i);
					let charLength = 1;
					
					if (charCode >= 0xD800 && charCode <= 0xDBFF && i + 1 < textarea.value.length) {
						charLength = 2;
						if (length + charLength <= maxLength) {
							newText += textarea.value.charAt(i) + textarea.value.charAt(i + 1);
							i++;
						} else {
							break;
						}
					} else {
						if (length + charLength <= maxLength) {
							newText += textarea.value.charAt(i);
						} else {
							break;
						}
					}
					length += charLength;
				}
				textarea.value = newText;
			}
			counter.innerHTML = (maxLength - this.getUnicodeLength(textarea.value));
		}
		this.updateMessageCounter();
	},

	handleCommand: function(exec, args) {
		let buttons = document.querySelectorAll('.cbi-button');

		for (let i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');

		return fs.exec(exec, args).then(function(res) {
			let out = document.querySelector('.smscommand-output');
			out.style.display = '';

			res.stdout = res.stdout?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';
			res.stderr = res.stderr?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';

	 		let cut = res.stdout;
			cut = cut.substr(0, 20);
			if ( cut == "sms sent sucessfully" ) {
        		res.stdout = _('SMS sent sucessfully');
			}

			dom.content(out, [ res.stdout || '', res.stderr || '' ]);
			
		}).catch(function(err) {
			ui.addNotification(null, E('p', [ err ]))
		}).finally(function() {
			for (let i = 0; i < buttons.length; i++)
			buttons[i].removeAttribute('disabled');
		});
	},

	handleGo: function(ev) {
		let phn = document.getElementById('phonenumber').value.trim();
		/* Префикс страны - НА ОТПРАВКЕ и только к 10-значному национальному
		   номеру (9291067196 -> +79291067196). Раньше поле ПРЕДЗАПОЛНЯЛОСЬ
		   префиксом, и сервисный номер уезжал как 7000100: модем честно слал
		   «в никуда», а «SMS отправлено» выглядело ложью (живой случай
		   МегаФон 000100, 20.08.2026). Короткие сервисные номера (любой
		   длины, не равной 10) уходят как есть - как у sms_tool в консоли. */
		if (uci.get('5gmodem', 'sms', 'prefix') == '1' && /^\d{10}$/.test(phn)) {
			let pn = String(uci.get('5gmodem', 'sms', 'pnumber') || '').replace(/[^0-9+]/g, '');
			phn = pn + phn;
		}
		let port = uci.get('5gmodem', 'sms', 'sendport');
		/* Пауза между сообщениями группы. Значения в конфиге может не быть
		   вовсе - тогда без запасного нуля получилось бы NaN, и setTimeout ниже
		   молча выродился бы в нулевую задержку. */
		let dx = (uci.get('5gmodem', 'sms', 'delay') || 0) * 1000;
		let get_smstxt = document.getElementById('smstext').value;

		let elem = document.getElementById('execute');
		let vN = elem.innerText;

		if (vN.includes(_('Send to number')) == true)
		{
				if ( phn.length < 3 )
				{
					ui.addNotification(null, E('p', _('Please enter phone number')), 'info');
					return false;
				}
				else {
					if ( !port )
					{
						ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
						return false;
					}
					else {
						if ( get_smstxt.length < 1 )
						{
						    ui.addNotification(null, E('p', _('Please enter a message text')), 'info');
						    return false;
						}
						else {
						    return this.handleCommand('/usr/share/5gmodem/smsbridge.sh', [ 'send', phn, get_smstxt, port ]);
						}
					}
		        }
				if ( !port )
				{
					ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
					return false;
				}
		}
		else {

			if ( !port )
			{
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
			}
			else {
			if ( get_smstxt.length < 1 )
				{
					ui.addNotification(null, E('p', _('Please enter a message text')), 'info');
					return false;
				}
				else {
				   		let xs = document.getElementById('pb');

    						let phone, i;
						    res.stdout = '';

							for (let i = 0; i < xs.length; i++) {
  								(function(i) {
    								setTimeout(function() { 
		    						phone = xs.options[i].value;

									let out = document.querySelector('.smscommand-output');
									out.style.display = '';

									fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'send', phone, get_smstxt, port ]);

									res.stdout += (i+1)+_('/')+xs.length+' * '+_('[Bot] Message sent to number:') + ' ' + phone +'\n';
									res.stdout = res.stdout.replace(/undefined/g, "");

									dom.content(out, [ res.stdout || '' ]);		
						
									}, dx * i);
								})(i);
							}
				    }
			    }
		    }
	},

	handleClear: function(ev) {
		let out = document.querySelector('.smscommand-output');
		out.style.display = '';
		out.style.display = 'none';

		let ovc = document.getElementById('phonenumber');
		let ov2 = document.getElementById('smstext');
		ov2.value = '';

		document.getElementById('counter').innerHTML = '160';

		// Reset to GSM-7
		let gsm7Radio = document.querySelector('input[name="encoding_type"][value="gsm7"]');
		if (gsm7Radio) gsm7Radio.checked = true;

		ovc.value = '';

		document.getElementById('phonenumber').focus();
	},

	handleCopy: function(ev) {
		let out = document.querySelector('.smscommand-output');
		out.style.display = 'none';

		let ov = document.getElementById('phonenumber');
		ov.value = '';
		let x = document.getElementById('pb').value;
		ov.value = x;
	},

	handleModemChange: function(ev) {
		let sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		let serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		let currentPort = uci.get('5gmodem', 'sms', 'sendport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			uci.set('5gmodem', 'sms', 'sendport', newModem.comm_port);
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
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/phonebook.user'), null),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('defmodems'))
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		var self = this;
		return Promise.resolve(this.renderMain(loadResults)).then(function(main) {
			return smssettings.panel('send').then(function(panel) {
				return E([], [ main, panel ]);
			});
		});
	},

	renderMain: function (loadResults) {

	let group, prefixnum;
	let self = this;

	if ( uci.get('5gmodem', 'sms', 'sendingroup') == '1' )
		{
		group = 1;
	}
	else {
	group = '';
	}
	
	if ( uci.get('5gmodem', 'sms', 'prefix') == '1' ) {	
		prefixnum = uci.get('5gmodem', 'sms', 'pnumber');
	}
	/* Подсказка о формате номера - ВНУТРИ страницы, а не через
	   ui.addNotification. Тот рисует ГЛОБАЛЬНЫЙ баннер поверх всего документа:
	   он перекрывал вкладки модемов и меню приложения и висел там, пока его не
	   закроют. Для постоянной справки по полю это неверный инструмент -
	   уведомления существуют для событий («сообщение отправлено»), а не для
	   текста, который должен просто быть на странице. Показываем так же, как
	   предупреждение о USSD: обычной плашкой в потоке. */
	let showNumberHint = (uci.get('5gmodem', 'sms', 'information') == '1');
	
		let info = _('User interface for sending messages using sms-tool').format('');
		
		let modemSections = uci.sections('defmodems', 'defmodems');
		let serialModems = [];
		
		if (modemSections && modemSections.length > 0) {
			serialModems = modemSections.filter(function(s) {
				return s.modemdata === 'serial';
			});
		}
		
		let currentPort = uci.get('5gmodem', 'sms', 'sendport');
		let currentModem = serialModems.find(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (!currentModem && serialModems.length > 0) currentModem = serialModems[0];
	
		return E('div', { 'class': 'cbi-map', 'id': 'map' }, [
				showNumberHint ? E('div', { 'class': 'alert-message info sms-hint' }, [
					E('p', {}, _("Enter the number as is: a 10-digit national number gets the country prefix from the settings automatically; short service numbers (like 000100) are sent unchanged.")),
					E('div', { 'class': 'sms-hint-actions' }, [
						E('button', {
							'class': 'cbi-button cbi-button-neutral',
							'type': 'button',
							'click': function(ev) {
								/* Закрыли - значит подсказка больше не нужна: гасим её
								   НАВСЕГДА. Плашку убираем сразу, не дожидаясь записи в
								   конфиг: ответ на клик должен быть мгновенным, а если
								   запись почему-то не удастся, подсказка вернётся при
								   следующем заходе - это безопаснее, чем наоборот. */
								let b = ev.currentTarget.closest('.sms-hint');
								if (b && b.parentNode) { b.parentNode.removeChild(b); }
								/* Пишем через скрипт, а НЕ uci.set/uci.save: последний кладёт
								   правку в сессионный стейджинг LuCI, и наверху повисает
								   «непринятые изменения» с кнопкой «Применить». Для закрытия
								   подсказки это неуместно - пользователь ничего не настраивал. */
								fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'hidenumberhint' ]);
							}
						}, [ _('Close') ])
					])
				]) : '',
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
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('User contacts') ]),
							E('div', { 'class': 'cbi-value-field' }, [
								E('select', { 'class': 'cbi-input-select',
										'id': 'pb',
										'class': 'tg-field',
										'change': ui.createHandlerFn(this, 'handleCopy'),
										'mousedown': ui.createHandlerFn(this, 'handleCopy')
									    },
									(loadResults[0] || "").trim().split("\n").map(function(cmd) {
                                        let fields = cmd.split(/;/);
                                        let name = fields[0];
                                        let code = fields[1] || fields[0];
                                    return E('option', { 'value': code }, name );
                                    })
								)
							]) 
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Send to') ]),
							E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'class': 'tg-field',
								'type': 'text',
								'id': 'phonenumber',
								'value': '',
								'placeholder': _('e.g. 9291067196 or a short number like 000100'),
								'oninput': "this.value = this.value.replace(/[^0-9.]/g, '');",
								'data-tooltip': _('Press [Delete] to delete the phone number'),
								'keydown': function(ev) {
									 if (ev.keyCode === 46)  
										{
										let del = document.getElementById('phonenumber');
											if (del) {
												let ovc = document.getElementById('phonenumber');
												ovc.value = '';
												document.getElementById('phonenumber').focus();
											}
										}
								},																													
								}),
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Encoding standard') ]),
							E('div', { 'class': 'cbi-value-field', 'style': 'text-align: left;' }, [
								E('div', { 'style': 'margin: 1px 0; display: inline-block;' }, [
									E('label', {
										'style': 'display:inline-flex !important;align-items:center !important;gap:6px;vertical-align:middle;height:auto !important;min-height:0 !important;line-height:1.4;',
										'data-tooltip': _('GSM-7 encoding (160 characters)')
									}, [
										E('input', {
											'type': 'radio',
											'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
											'name': 'encoding_type',
											'value': 'gsm7',
											'change': ui.createHandlerFn(this, 'handleEncodingChange'),
											'checked': true
										}),
										' ',
										_('GSM-7 (160 characters)')
									]),
									' \u00a0\u00a0\u00a0 ',
									E('label', {
										'style': 'display:inline-flex !important;align-items:center !important;gap:6px;vertical-align:middle;height:auto !important;min-height:0 !important;line-height:1.4;',
										'data-tooltip': _('Unicode encoding (70 characters), does not support sending national characters (in utf8) - only ascii')
									}, [
										E('input', {
											'type': 'radio',
											'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
											'name': 'encoding_type',
											'value': 'unicode',
											'change': ui.createHandlerFn(this, 'handleEncodingChange')
										}),
										' ',
										_('Unicode (70 characters)')
									])
								])
							])
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Message text') ]),
							E('div', { 'class': 'cbi-value-field' }, [
							/* Счётчик лежит ВНУТРИ поля ввода (правый нижний угол), а не строкой
							   под ним: подпись «Осталось символов: 160» занимала целую строку ради
							   числа, которое нужно лишь боковым зрением. Обёртка нужна для
							   позиционирования: внутрь textarea вложить ничего нельзя, поэтому
							   счётчик кладём ПОВЕРХ, а место под него освобождаем нижним отступом
							   самого поля. */
							E('div', { 'class': 'smstext-wrap' }, [
							E('textarea', {
								'id': 'smstext',
								'class': 'cbi-input-textarea',
								'wrap': 'on',
								'rows': '3',
								'placeholder': _(''),
								'data-tooltip': _('Press [Delete] to delete the content of the message'),
								'keydown': function(ev) {
									 if (ev.keyCode === 46)  
										{
										let del = document.getElementById('smstext');
											if (del) {
												let ovtxt = document.getElementById('smstext');
												ovtxt.value = '';
												document.getElementById('counter').innerHTML = '160';
												// Reset to GSM-7
												let gsm7Radio = document.querySelector('input[name="encoding_type"][value="gsm7"]');
												if (gsm7Radio) gsm7Radio.checked = true;
												document.getElementById('smstext').focus();
											}
										}
								},
								'keyup': function(ev) {
									self.updateMessageCounter();
								},
								'input': function(ev) {
									self.updateMessageCounter();
								}
							}),
							E('span', {
								'id': 'counter',
								'class': 'smstext-counter',
								'title': _('Characters remaining:')
							}, [ '160' ])
							])
							]),
						]),

					])
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(this, function() {
							return fs.trimmed('/etc/5gmodem/modem/phonebook.user').then(function(content) {
								new editors.phonebookEditorDialog(_('Edit User Contacts'), content || '').show();
							}).catch(function() {
								new editors.phonebookEditorDialog(_('Edit User Contacts'), '').show();
							});
						})
					}, [ _('Manage contacts') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear form') ]),
					'\xa0\xa0\xa0',
						E('span', { 'class': 'diag-action' }, [
							group ? new ui.ComboButton('send', {
								'send': '%s %s'.format(_('Send'), _('to number')),
								'sendg': '%s %s'.format(_('Send'), _('to group')),
							}, {
								'click': ui.createHandlerFn(this, 'handleGo'),
								'id': 'execute',
								'classes': {'send': 'cbi-button cbi-button-action important',
                                            'sendg': 'cbi-button cbi-button-action important',
                            },
                                'id': 'execute',
                            }).render() : E('button', {
                                'class': 'cbi-button cbi-button-action important',
                                'id': 'execute',
                                'click': ui.createHandlerFn(this, 'handleGo')
                            }, [ _('Send to number') ]),
                        ]),
                    ]),
                E('p', _('Status')),
                    E('pre', { 'class': 'smscommand-output', 'id': 'ans', 'style': 'display:none; border: 1px solid var(--border-color-medium); border-radius: 5px; font-family: monospace' }),
                ]);
            }
});
