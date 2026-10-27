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
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

var smsBook = [];
var smsBookW = null;

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

return view.extend({

	isUnicode: function(text) {
		const gsm7chars = '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
		const gsm7extended = '^{}\\[~]|€';
		
		for (let i = 0; i < text.length; i++) {
			let char = text.charAt(i);
			if (gsm7chars.indexOf(char) === -1 && gsm7extended.indexOf(char) === -1) {
				return true;
			}
		}
		return false;
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
			.replace(/ą/g, 'a').replace(/Ą/g, 'A')
			.replace(/ć/g, 'c').replace(/Ć/g, 'C')
			.replace(/ę/g, 'e').replace(/Ę/g, 'E')
			.replace(/ł/g, 'l').replace(/Ł/g, 'L')
			.replace(/ń/g, 'n').replace(/Ń/g, 'N')
			.replace(/ó/g, 'o').replace(/Ó/g, 'O')
			.replace(/ś/g, 's').replace(/Ś/g, 'S')
			.replace(/ż/g, 'z').replace(/Ż/g, 'Z')
			.replace(/ź/g, 'z').replace(/Ź/g, 'Z')
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
			.replace(/–/g, '-').replace(/—/g, '-')
			.replace(/\u2018/g, '\'').replace(/\u2019/g, '\'')
			.replace(/\u201C/g, '"').replace(/\u201D/g, '"')
			.replace(/„/g, '"').replace(/\u201F/g, '"')
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
			.replace(/[^\x00-\x7F@£$¥èéùìòÇØøÅåΔΦΓΛΩΠΨΣΘΞÆæßÉ¡¤§¿äöñüà^{}\\[\]~|€]/g, '');
	},

	counterText: function(text) {
		let uni = this.isUnicode(text);
		let len = uni ? this.getUnicodeLength(text) : this.getGSM7Length(text);
		let single = uni ? 70 : 160;
		let per = uni ? 67 : 153;

		if (len <= single) { return String(single - len); }
		return len + ' · ' + Math.ceil(len / per);
	},

	updateMessageCounter: function() {
		let textarea = document.getElementById('smstext');
		let text = textarea.value;
		let counter = document.getElementById('counter');
		let gsm7Radio = document.querySelector('input[name="encoding_type"][value="gsm7"]');
		let unicodeRadio = document.querySelector('input[name="encoding_type"][value="unicode"]');

		if (this.isUnicode(text)) {
			unicodeRadio.checked = true;
		} else {
			gsm7Radio.checked = true;
		}
		counter.textContent = this.counterText(text);
	},

	handleEncodingChange: function(ev) {
		let textarea = document.getElementById('smstext');
		let text = textarea.value;
		let encodingType = ev.target.value;
		let counter = document.getElementById('counter');
		
		if (encodingType === 'gsm7') {
			textarea.value = this.normalizeToGSM7(text);
		}
		counter.textContent = this.counterText(textarea.value);
		this.updateMessageCounter();
	},

	handleCommand: function(exec, args) {
		let buttons = document.querySelectorAll('.cbi-button');
		let wasDisabled = [];

		for (let i = 0; i < buttons.length; i++) {
			wasDisabled[i] = buttons[i].hasAttribute('disabled');
			buttons[i].setAttribute('disabled', 'true');
		}

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
				if (!wasDisabled[i]) { buttons[i].removeAttribute('disabled'); }
		});
	},

	handleGo: function(ev, cbval) {
		var self = this;
		uci.unload('5gmodem');
		return uci.load('5gmodem').then(function() { return self.handleGoNow(ev, cbval); });
	},

	handleGoNow: function(ev, cbval) {
		let phn = document.getElementById('phonenumber').value.trim();
		if (uci.get('5gmodem', 'sms', 'prefix') == '1' && /^\d{10}$/.test(phn)) {
			let pn = String(uci.get('5gmodem', 'sms', 'pnumber') || '').replace(/[^0-9+]/g, '');
			phn = pn + phn;
		}
		let port = uci.get('5gmodem', 'sms', 'sendport');
		let dx = (uci.get('5gmodem', 'sms', 'delay') || 0) * 1000;
		let get_smstxt = document.getElementById('smstext').value;

		if (cbval !== 'sendg')
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
				   		let xs = smsBook;

    						let log = '';
							let out = document.querySelector('.smscommand-output');
							out.style.display = '';
							let chain = Promise.resolve();

							xs.forEach(function(ent, i) {
								chain = chain.then(function() {
									return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'send', ent.code, get_smstxt, port ]), null)
										.then(function(r) {
											let t = String(r == null ? '' : r).trim();
											let line = /^sms sent sucessfully/.test(t)
												? _('[Bot] Message sent to number:') + ' ' + ent.code
												: ent.code + ': ' + (t || _('Error'));
											log += (i+1)+'/'+xs.length+' * '+ line +'\n';
											dom.content(out, [ log ]);
											if (dx > 0 && i < xs.length - 1) {
												return new Promise(function(resolve) { setTimeout(resolve, dx); });
											}
										});
								});
							});
							return chain;
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
		ov.value = smsBookW ? String(smsBookW.getValue() || '') : '';

		let tx = document.getElementById('smstext');
		if (!tx) { return; }
		let thanks = _('Hi! I really like your app. How can I thank you?');
		let pick = smsBook.filter(function(b) { return b.code === ov.value; })[0];
		let isAuthor = pick && /^t\.me\/openwrt_fun$/i.test(String(pick.name || '').trim());
		let cur = tx.value;
		if (isAuthor && cur.trim() === '') {
			tx.value = thanks;
		} else if (!isAuthor && cur === thanks) {
			tx.value = '';
		} else {
			return;
		}
		tx.dispatchEvent(new Event('input', { bubbles: true }));
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
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'smsopt', 'sendport=' + newModem.comm_port ]), null).then(function() {
				let modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					let label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	load: function() {
		var self = this, args = arguments;
		return fresh.check(30900, [ editors, smssettings, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/phonebook.user'), null),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('defmodems'))
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();
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
								let b = ev.currentTarget.closest('.sms-hint');
								if (b && b.parentNode) { b.parentNode.removeChild(b); }
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
													'class': 'btn cbi-button-neutral tg-col-narrow prev',
													'aria-label': _('Previous modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'disabled': buttonsDisabled
												}, [ ' ◄ ' ]),
												E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
												E('button', { 
													'class': 'btn cbi-button-neutral tg-col-narrow next',
													'aria-label': _('Next modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
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
								(function(self) {
									smsBook = [];
									var ch = {}, order = [];
									(loadResults[0] || "").trim().split("\n").forEach(function(cmd) {
										var fields = cmd.split(/;/);
										var name = fields[0];
										var code = fields[1] || fields[0];
										if (!code) { return; }
										smsBook.push({ name: name, code: code });
										ch[code] = name || code;
										order.push(code);
									});
									smsBookW = new ui.Dropdown(order[0] || '', ch,
										{ id: 'pb', sort: order });
									var n = smsBookW.render();
									n.classList.add('tg-field');
									n.addEventListener('cbi-dropdown-change',
										ui.createHandlerFn(self, 'handleCopy'));
									return n;
								})(this)
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
				E('div', { 'class': 'right tg-actrow' }, [
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
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear form') ]),
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
