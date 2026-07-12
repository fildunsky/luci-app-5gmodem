'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require rpc';
'require poll';
'require sms-tool-js.smssettings as smssettings';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

var callForwardSMS = rpc.declare({
    object: 'sms_forward',
    method: 'forward',
    params: ['subject', 'message']
});

document.head.append(E('style', {'type': 'text/css'},
`
#smsTable {
  width: 100%;
  border: 1px solid var(--border-color-medium) !important;
}

/* Инфо-таблица над списком (модем, хранилище, ёмкость): без линий между строками */
#sms-info-table td,
#sms-info-table th,
#sms-info-table .td,
#sms-info-table .th {
  border: none !important;
}

th, td {
  padding: 10px;
  text-align: justify !important;
  vertical-align: top !important;
}

td input[type="checkbox"] {
  float: left !important;
  margin: 0 auto !important;
  width: 17px !important;
}

td .sms-row-icon {
  display: inline-block;
  vertical-align: middle;
  margin-left: 10px;
}

td .sms-row-icon img {
  vertical-align: middle;
}

/* Первая ячейка строки = чекбокс + иконка сообщения. Колонка .checker
   узкая (7%), поэтому чекбокс с иконкой не влезали в одну строку и иконку
   переносило вниз («невидимый перенос строки»). Запрещаем перенос и даём
   ячейке минимальную ширину. !important - тема proton2025 задаёт свои
   правила для td. */
#smsTable td:first-child {
  white-space: nowrap !important;
  min-width: 64px;
}

#smsTable tr:nth-child(odd) td{
  background: var(--background-color-medium) !important;
  border-bottom: 1px solid var(--border-color-medium) !important;
  border-top: 1px solid var(--border-color-medium) !important;
}

#smsTable tr:nth-child(even) td{
  border-bottom: 1px solid var(--border-color-medium) !important;
  border-top: 1px solid var(--border-color-medium) !important;
}

#smsTable .checker {
  width: 7% !important;
}

#smsTable .from {
  width: 11% !important;
}

#smsTable .received {
  width: 15% !important;
}

#smsTable .message {
  width: 88% !important;
}

.sms-row-icon {
  position: relative;
  display: inline-block;
}

:root[data-darkmode="true"] .sms-row-icon {
  opacity: 0.5;
}
`));

function msg_bar(v, m) {
var pg = document.querySelector('#msg')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);

pg.firstElementChild.style.width = pc + '%';
pg.setAttribute('title', '%s'.format(v) + ' / ' + '%s'.format(m) + ' ('+ pc + '%)');
}

function popTimeout(a, message, timeout, severity) {
    ui.addTimeLimitedNotification(a, message, timeout, severity);
}


function format_with_modem_index(value) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			// old format
			return value;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			// old format
			return value;
		}
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		
		var modemIndex = -1;
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				modemIndex = i + 1;
				break;
			}
		}
		
		if (modemIndex === -1) {
			// old format
			return value;
		}
		
		return 'dfm' + modemIndex + '_' + value;
		
	}).catch(function() {
		// old format
		return value;
	});
}

function update_sms_count_for_modem(newValue) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			// old format
			return newValue;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			// old format
			return newValue;
		}
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		var currentModemIndex = -1;
		
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				currentModemIndex = i + 1;
				break;
			}
		}
		
		if (currentModemIndex === -1) {
			// old format
			return newValue;
		}
		
		var existingSmsCount = uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_count') || '';
		var parts = existingSmsCount.split(' ').filter(function(p) { return p.trim() !== ''; });
		
		var updated = {};
		parts.forEach(function(part) {
			var match = part.match(/^dfm(\d+)_(\d+)$/);
			if (match) {
				var modemIdx = parseInt(match[1]);
				if (modemIdx > 0 && modemIdx <= serialModems.length) {
					updated[modemIdx] = match[2];
				}
			}
		});
		
		updated[currentModemIndex] = newValue;
		
		var result = [];
		for (var i = 1; i <= serialModems.length; i++) {
			var count = updated[i] || '0';
			result.push('dfm' + i + '_' + count);
		}
		
		return result.join(' ');
		
	}).catch(function() {
		// old format
		return newValue;
	});
}

function save_count() {
	uci.load('sms_tool_js').then(function() {

		var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
		var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));

			L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
					.then(function(res) {
							if (res) {
								var total = res.substring(res.indexOf("total"));
								var t = total.replace ( /[^\d.]/g, '' );
								var used = res.substring(17, res.indexOf("total"));
								var u = used.replace ( /[^\d.]/g, '' );
								
								update_sms_count_for_modem(u).then(function(updatedValue) {
									uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count', updatedValue);
									uci.save();
									uci.apply();
								});
							}
			});
	});
}


/* Binary used for SMS operations: on modems managed by ModemManager
   (MBIM/QMI, e.g. Compal RXM-G1) sms_tool on the AT port never sees
   incoming messages and cannot send - use the mmcli wrapper instead.
   The sms_via_mm option is set by the hotplug script (by VID:PID) or
   by the user. */
function smsToolBin() {
	return uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_via_mm') == '1' ? '/usr/bin/sms_tool_mm' : '/usr/bin/sms_tool';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('sms_tool_js'),
			L.resolveDefault(uci.load('defmodems'))
		]);
	},

	handleModemChange: function(ev) {
		var sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		var serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		var currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		var direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		var newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		var newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			uci.set('sms_tool_js', '@sms_tool_js[0]', 'readport', newModem.comm_port);
			uci.save();
			uci.apply().then(function() {
				var modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					var label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	handleSWarea: function(ev) {
		switch (document.querySelector('input[name="filter_area"]:checked').value) {
		case 'sim':
			uci.set('sms_tool_js', '@sms_tool_js[0]', 'storage', "SM");
			uci.save();
			uci.apply();
			break;
		case 'memory':
			uci.set('sms_tool_js', '@sms_tool_js[0]', 'storage', "ME");
			uci.save();
			uci.apply();
			break;
		}
	},

    handleForward: function(ev) {
	    var checked = document.querySelectorAll('input[name="smsn"]:checked');
	    
	    if (checked.length === 0) {
		    ui.addNotification(null, E('p', _('Please select the message(s) to be forwarded')), 'info');
		    return;
	    }
	    
	    var self = this;
	    
	    uci.load('sms_tool_js').then(function() {
		    var fwdEnabled = uci.get('sms_tool_js', '@sms_tool_js[0]', 'forward_sms_enabled');
		    
		    if (fwdEnabled !== '1') {
			    ui.addNotification(null, E('p', _('SMS forwarding function is not enabled')), 'info');
			    return;
		    }
		    
		    var emailSubject = '';
		    var emailBody = '';

		    if (checked.length === 1) {
			    var row = checked[0].closest('tr');
			    var cells = row.cells;
			    
			    var sender = cells[1].textContent.trim();
			    var timestamp = cells[2].textContent.trim();
			    var message = cells[3].textContent.trim();
			    
			    emailSubject = 'SMS ' + timestamp + ' - ' + sender;
			    emailBody = message;
			    
			    self.showEmailModal(emailSubject, emailBody);
		    } 
		    else {
			    uci.load('system').then(function() {
				    var hostname = uci.get('system', '@system[0]', 'hostname') || _('My Router');
				    
				    var messages = [];
				    checked.forEach(function(checkbox) {
					    var row = checkbox.closest('tr');
					    var cells = row.cells;
					    
					    var timestamp = cells[2].textContent.trim();
					    var sender = cells[1].textContent.trim();
					    var message = cells[3].textContent.trim();
					    
					    messages.push(timestamp + ' - ' + sender + '\n' + message);
				    });
				    
				    var emailBody = messages.join('\n\n');
				    
				    self.showEmailModal(hostname, emailBody);
			    });
		    }
	    });
    },

    showEmailModal: function(defaultSubject, defaultBody) {
	    var self = this;
	    
	    ui.showModal(_('Forward SMS to E-mail'), [
		    E('p', _('Subject:')),
		    E('input', {
			    'type': 'text',
			    'id': 'email-subject',
			    'class': 'cbi-input-text',
			    'style': 'width: 100% !important; margin-bottom: 15px;',
			    'value': defaultSubject
		    }),
		    E('p', _('Message text:')),
		    E('textarea', {
			    'id': 'email-body',
			    'class': 'cbi-input-textarea',
			    'style': 'width: 100% !important; height: 30vh; min-height: 250px;',
			    'wrap': 'off',
			    'spellcheck': 'false'
		    }, defaultBody),
		    E('div', { 'class': 'right' }, [
			    E('button', {
				    'class': 'btn',
				    'click': ui.hideModal
			    }, _('Cancel')), ' ',
			    E('button', {
				    'class': 'cbi-button cbi-button-action important',
				    'click': ui.createHandlerFn(this, 'sendEmailFromModal')
			    }, _('Send'))
		    ])
	    ], 'cbi-modal');
    },

    sendEmailFromModal: function() {
	    var subject = document.getElementById('email-subject').value;
	    var body = document.getElementById('email-body').value;
	    
	    if (!subject || !body) {
		    ui.addNotification(null, E('p', _('Subject and body cannot be empty')), 'error');
		    return;
	    }
	    
	    var self = this;
	    
	    ui.hideModal();
	    
	    var contentArea = document.getElementById('forward-status');
	    contentArea.style.display = 'block';
	    contentArea.innerHTML = '';
	    contentArea.appendChild(E('div', {'class': 'alert alert-info'}, 
		    E('span', {'class': 'spinning'}, _('Sending e-mail...'))
	    ));
	    
	    callForwardSMS(subject, body).then(function(response) {
		    contentArea.innerHTML = '';
		    if (response.success) {
			    popTimeout(null, E('p', _('Message forwarded successfully')), 5000, 'info');
			    setTimeout(function() {
				    if (contentArea) {
					    contentArea.innerHTML = '';
					    contentArea.style.display = 'none';
				    }
			    }, 5000);
		    } else {
			    contentArea.innerHTML = '';
			    contentArea.style.display = 'none';
			    ui.addNotification(null, E('p', _('Failed to forward message: %s').format(response.error || 'Unknown error')), 'error');
		    }
	    }).catch(function(err) {
		    contentArea.innerHTML = '';
		    contentArea.style.display = 'none';
		    ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
	    });
    },

	handleDelete: function(ev) {
		if (document.querySelectorAll('input[name="smsn"]:checked').length == 0){
		ui.addNotification(null, E('p', _('Please select the message(s) to be deleted')), 'info');   
		}
		else {
			if (document.querySelectorAll('input[name="smsn"]:checked').length === document.querySelectorAll('input[name="smsn"]').length) {
					if (confirm(_('Delete all the messages?')))
						{
							var sections = uci.sections('sms_tool_js');
							var portDA = sections[0].readport;
							var storeDA = sections[0].storage;

							fs.exec_direct(smsToolBin(), [ '-d' , portDA , 'delete' , 'all' ]);
							document.getElementById("ch-all").checked = false;

							var rowCount = smsTable.rows.length;
							for (var i = rowCount - 1; i > 0; i--) {
            					smsTable.deleteRow(i);}
    							setTimeout(function() {
								L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeDA , '-d' , portDA , 'status' ]))
									.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var u = "0";
											msg_bar(Math.floor(u), t);
											save_count();
										}
								});
							}, 2000);
						}
			}
			else {

					if (confirm(_('Delete selected message(s)?')))
						{
						uci.load('sms_tool_js').then(function() {

							var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
							var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));

							var array = [];
							var checkb = document.querySelectorAll('input[type=checkbox]:checked');

							for (var i = 0; i < checkb.length; i++) {
								if (checkb[i] != source)
  								array.push(checkb[i].id)
							}

							if (array) {

							var args = [];
							var sections = uci.sections('sms_tool_js');
							var portDEL = sections[0].readport;
							var storeDS = sections[0].storage;

							args.push(array);
							var ax = args.toString();
							ax = ax.replace(/,/g, ' ');
							ax = ax.replace(/-/g, ' ');

							var smsnr = ax.split(" ");

							var smsallchars = smsnr.toString();
							var smsdelcount = 0;
							var smsdeleted = 0;

							var inumber = false;

							for (var i = 0; i < smsallchars.length; i++) {
    							var ch = smsallchars[i];

    							if (ch >= '0' && ch <= '9') {
        							if (!inumber) {
            								smsdelcount++;
            								inumber = true;
        							}
    								} else if (ch === ',') {
        								inumber = false;
    								} else {
        								inumber = false;
    								}
							}
	
							var deletelabel = document.getElementById("deleteinfo");
							deletelabel.style.display = 'block';

								for (var i=0; i < smsnr.length + 2; i++)
									{
									(function(i) {
    									setTimeout(function() { 
    									smsnr[i] = parseInt(smsnr[i], 10);

									if (!Number.isNaN(smsnr[i]))
										{
										fs.exec_direct(smsToolBin(), [ '-d' , portDEL , 'delete' , smsnr[i] ]);
                						smsdeleted++;
										L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});
				
										}
										L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});

										if (smsdelcount == smsdeleted) {
											setTimeout(function() {
											var hidecount = document.getElementById('deleteinfo');
											uci.load('sms_tool_js').then(function() {
												var savedCount = uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_count') || '';
												L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
												.then(function(verifyRes) {
													if (verifyRes) {
														var verifyUsed = verifyRes.substring(17, verifyRes.indexOf("total"));
														var verifyU = verifyUsed.replace( /[^\d.]/g, '' );
														var savedMatch = savedCount.match(/(?:dfm\d+_)?(\d+)(?:\s|$)/);
														var savedNum = savedMatch ? savedMatch[1] : savedCount.replace(/[^\d]/g, '');
														if (savedNum !== verifyU) {
															update_sms_count_for_modem(verifyU).then(function(correctedValue) {
																uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count', correctedValue);
																uci.save();
																uci.apply();
															});
														}
													}
													hidecount.style.display = 'none';
												});
											});
											    save_count();
											}, 7000);
										}
									}, 1500 * i);
								})(i);
										L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});
								}
								var table = document.getElementById("smsTable");
  								var index = 1;
  									while (index < table.rows.length) {
   										var input = table.rows[index].cells[0].children[0];
    										if (input && input.checked) {
      											table.deleteRow(index);
   										}
    										else {
      											index++;
   										}
  									}
								}
							});
						}
			    }
		}
	},
                                                                                                                                              
	handleRefresh: function(ev) {
		// Обновляем только список сообщений, без перезагрузки всей страницы.
		// Фолбэк на reload, если doRefresh ещё не готов (ранний клик).
		if (typeof this._doRefresh == 'function') { return this._doRefresh(false); }
		window.location.reload();
	},

	handleSelect: function(ev) {
		var checkBox = document.getElementById("ch-all");
		var checkBoxes = document.querySelectorAll('input[name="smsn"]');

  		if (checkBox.checked == true){
			for (var i = 0; i < checkBoxes.length; i++)
				checkBoxes[i].checked = true;
  		} else {
			for (var i = 0; i < checkBoxes.length; i++)
				checkBoxes[i].checked = false;
  		}
	},

	render: function(data) {
		var self = this;
		return Promise.resolve(this.renderMain(data)).then(function(main) {
			return smssettings.panel('receive').then(function(panel) {
				return E([], [ main, panel ]);
			});
		});
	},

	renderMain: function(data) {

		var self = this;
		var sections, store;
		var view = document.getElementById("smssarea");
		store = '-';

		uci.load('sms_tool_js').then(function() {
		var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
		var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));
		// mergesms может быть не задан в uci (свежая конфигурация): тогда
		// ни ветка smsM=="1" (склейка), ни smsM=="0" не выполнялись, и
		// сообщения не рендерились (обновлялся только счётчик). Нормализуем
		// к "1"/"0", по умолчанию "0" (без склейки).
		var smsM = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'mergesms')) == '1' ? '1' : '0';
		var algo = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'algorithm'));
		var hide = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'bnumber'));
		var ledn = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'lednotify'));
		var ledt = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'ledtype'));
		var direct = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'direction'));

		if (!portR) {
 			ui.addNotification(null, E('p', _('The package requires user configuration. \
					<br /><br /><b>The following need to be set:</b> \
					<ul><li>1. All ports for communication with the modem.</li><li>2. Additional options specific to the given modem (for handling USSD codes).</li><li> \
					3. Notification LED (optional).</li><li><ul>')), 'info');
		}
		
		var sections = uci.sections('sms_tool_js');
		var led = sections[0].smsled;

		/* Эти radio живут в DOM, который renderMain ещё не вернул и не
		   прикрепил к странице: sms_tool_js уже загружен в load(), поэтому
		   этот .then() выполняется микрозадачей ДО вставки DOM, и
		   querySelector возвращает null. Раньше обращение к .checked на null
		   бросало исключение, промис отклонялся, и цепочка status/recv ниже
		   вообще не запускалась - сообщения не появлялись. Ставим отметку
		   только если элемент уже существует (на автополлинге он есть). */
		var simRadio = document.querySelector('input[name="filter_area"][value="sim"]');
		var memRadio = document.querySelector('input[name="filter_area"][value="memory"]');
		if (storeL == "SM" && simRadio) simRadio.checked = true;
		if (storeL == "ME" && memRadio) memRadio.checked = true;
		if (ledn == "1")
			{
				switch (ledt) {
  					case 'S':
    						fs.exec_direct('/etc/init.d/led', [ 'restart' ]);
    						break;
  					case 'D':
    						fs.write('/sys/class/leds/'+led+'/brightness', '0');
    						break;
  					default:
					}
			}

		/* doRefresh(updateCount): читает статус + входящие и перерисовывает
		   таблицу. Вызывается один раз при заходе и затем по таймеру
		   (poll.add) - новые SMS появляются сами, без ручного «Обновить».
		   updateCount=true только на первом вызове: обновление счётчика
		   sms_count дёргает uci.apply(), которое нельзя гонять каждые N сек. */
		function doRefresh(updateCount) {
		return L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , 'status' ]))
				.then(function(res) {
					if (res) {
							var total = res.substring(res.indexOf("total"));
							var t = total.replace ( /[^\d.]/g, '' );

							var used = res.substring(17, res.indexOf("total"));
							var u = used.replace ( /[^\d.]/g, '' );

						L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeL , '-d' , portR , '-f' , '%Y-%m-%d %H:%M' , '-j' , 'recv' , '2>/dev/null' ]))
							.then(function(res2) {
								if (res2) {

 									var table = document.getElementById('smsTable');
									while (table.rows.length > 1) { table.deleteRow(1); }					

									/* Proper parsing instead of positional slicing:
									   substring(7) relied on the exact byte format
									   of sms_tool ({"msg":[...]}) and broke on any
									   other valid JSON (e.g. from sms_tool_mm/jshn,
									   which prints spaces). */
									var json = JSON.parse(res2).msg || [];

									var aidx = [];

									/* Merging messages */
									if (smsM == "1") {

											var result = [];

											if (algo == "Advanced")
											{
												switch (direct) {
  														case 'Start':
    															var Data = json.sort((a, b) => {
  																if (a.timestamp === b.timestamp && a.sender === b.sender) {
    																	return a.part - b.part;
  																} else if (a.timestamp === b.timestamp) {
    																	return a.sender - b.sender;
  																} else {
    																	return a.timestamp.localeCompare(b.timestamp);
  																}
															});
    															break;
  														case 'End':
    															var Data = json.sort((a, b) => {
  																if (a.timestamp === b.timestamp && a.sender === b.sender) {
    																	return b.part - a.part;
  																} else if (a.timestamp === b.timestamp) {
    																	return a.sender - b.sender;
  																} else {
    																	return a.timestamp.localeCompare(b.timestamp);
  																}
															});
    															break;
  														default:
												}

												var SortedSMS = Data.sort((function (a, b) { return new Date(b.timestamp) - new Date(a.timestamp) }));
												var combinedjson = {};

												for (const parts of SortedSMS) {
  												const { sender, timestamp, total, content, index } = parts;

  												if (total) {
    													const key = `${sender}-${timestamp}-${total}`;
    														if (combinedjson[key]) {
      															combinedjson[key].content += content;
      															combinedjson[key].index += '-' + index;
   														} else {
      															combinedjson[key] = { sender, timestamp, total, content, index };
    														}
  												} else {
    													const newkey = `${sender}-${timestamp}-${index}`;
    													combinedjson[newkey] = { sender, timestamp, total, content, index };
  													}
												}
												var result = Object.values(combinedjson);
											}

											if (algo == "Simple")
											{
												var SortedSMS = json.sort((function (a, b) { return new Date(b.timestamp) - new Date(a.timestamp) }));

												SortedSMS.forEach(function (o) {
    													if (!this[o.sender]) {
        													this[o.sender] = { index: o.index, sender: o.sender, timestamp: o.timestamp, part: o.part, total: o.total, content: o.content };
        													result.push(this[o.sender]);
        													return;
    														}
														if (this[o.sender].total == o.total && this[o.sender].timestamp == o.timestamp && this[o.sender].sender == o.sender && this[o.sender].part > 0) {
    														this[o.sender].index += '-' + o.index;    			
														this[o.sender].content += o.content;}
														else {
															this[o.sender] = { index: o.index, sender: o.sender, timestamp: o.timestamp, part: o.part, total: o.total, content: o.content };
        														result.push(this[o.sender]);
        														return;
															}
												}, Object.create(null));
											}
													if (u){
															var Lres = L.resource('icons/cmessage.svg');

															for (var i = 0; i < result.length; i++) {
            													var row = table.insertRow(-1);
  																var cell1 = row.insertCell(0);
  																var cell2 = row.insertCell(0);
  																var cell3 = row.insertCell(0);
  																var cell4 = row.insertCell(0);
																
																var checkbox = E('input', {
																	'type': 'checkbox',
																	'name': 'smsn',
																	'id': result[i].index + ','
																});
																var icon = E('span', { 'class': 'sms-row-icon' }, [
																	E('img', {
																		'src': Lres,
																		'style': 'width: 24px; height: 24px;'
																	})
																]);
																cell4.appendChild(checkbox);
																cell4.appendChild(icon);
																	if (result[i].sender.includes(hide)) {
																		var removeLast5 = result[i].sender.slice(0, -5);
																		cell3.innerHTML = removeLast5 + '#####';
																	} else {
 				 													cell3.innerHTML = result[i].sender;
																	}
																	
  																cell2.innerHTML = result[i].timestamp;
    															cell1.innerHTML = result[i].content.replace(/\s+/g, ' ').trim();
																aidx.push(result[i].index+'-');
															}

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															if (updateCount) format_with_modem_index(axx).then(function(formattedIndex) {
																update_sms_count_for_modem(u).then(function(updatedCount) {
																	uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count_index', formattedIndex);
																	uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count', updatedCount);
																	uci.save();
																	uci.apply();
																});
															});
											}

										}
									}

									/* No merging messages */
									if (smsM == "0") {
									
										/* Sorting messages by delivery time */
										var sortbyTime = json.sort((function (a, b) { return new Date(b.timestamp) - new Date(a.timestamp) }));

										/* Sorting messages by parts */
										var sortedData = sortbyTime.sort((a, b) => {
    										if (a.timestamp === b.timestamp && a.sender === b.sender && a.total === b.total) {
        											return a.part - b.part;
    										} else {
        											return 0;
    										}
										});

										if (u){

											var Lres = L.resource('icons/cmessage.svg');

											for (var i = 0; i < sortedData.length; i++) {
                                            var row = table.insertRow(-1);
  											var cell1 = row.insertCell(0);
  											var cell2 = row.insertCell(0);
  											var cell3 = row.insertCell(0);
  											var cell4 = row.insertCell(0);
											
											var checkbox = E('input', {
												'type': 'checkbox',
												'name': 'smsn',
												'id': sortedData[i].index + ','
											});
											var icon = E('span', { 'class': 'sms-row-icon' }, [
												E('img', {
													'src': Lres,
													'style': 'width: 24px; height: 24px;'
												})
											]);
											cell4.appendChild(checkbox);
											cell4.appendChild(icon);
												if (sortedData[i].sender.includes(hide)) {
													var removeLast5 = sortedData[i].sender.slice(0, -5);
													cell3.innerHTML = removeLast5 + '#####';
												} else {
 				 									cell3.innerHTML = sortedData[i].sender;
												}
  											cell2.innerHTML = sortedData[i].timestamp;
    										cell1.innerHTML = sortedData[i].content.replace(/\s+/g, ' ').trim();
											aidx.push(sortedData[i].index+'-');
										
											}
											
											var axx = aidx.toString();
											axx = axx.replace(/,/g, ' ');
											axx = axx.replace(/-/g, ' ');

											if (updateCount) format_with_modem_index(axx).then(function(formattedIndex) {
												update_sms_count_for_modem(u).then(function(updatedCount) {
													uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count_index', formattedIndex);
													uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count', updatedCount);
													uci.save();
													uci.apply();
												});
											});
									}

								}
						});

				} else {
					// status вернул пусто (нет порта / модем не ответил).
					// t и u здесь не определены - прежний код обращался к
					// t.lenght (к тому же опечатка) и бросал исключение,
					// которое роняло автополлинг на каждом тике. Просто
					// показываем подсказку, без обращения к t/u.
					ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
				}

			if (document.getElementById('msg') && typeof u !== 'undefined') {
				msg_bar(Math.floor(u), t);
			    }
    		});
		}
		doRefresh(true);
		/* Автообновление входящих: новые SMS появляются сами, без ручного
		   «Обновить». poll снимается автоматически при уходе со страницы. */
		poll.add(function() { return doRefresh(false); }, 15);
		/* Кнопка «Обновить» теперь обновляет только список сообщений
		   (см. handleRefresh), а не перезагружает всю страницу. */
		self._doRefresh = doRefresh;
		});

		var v = E('div', { 'class': 'cbi-section' }, [

			E('table', { 'class': 'table', 'id': 'sms-info-table' }, [
				(function() {
					var sections = uci.sections('defmodems', 'defmodems');
					var serialModems = [];
					
					if (sections && sections.length > 0) {
						serialModems = sections.filter(function(s) {
							return s.modemdata === 'serial';
						});
					}
					
					if (serialModems.length > 0) {
						var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
						var currentModem = serialModems.find(function(s) {
							return s.comm_port === currentPort;
						});
						
						if (!currentModem) currentModem = serialModems[0];
						
						var label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
						
						var buttonsDisabled = (serialModems.length > 1) ? null : true;
						
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', 'width': '33%' }, [ _('Select modem') ]),
							E('td', { 'class': 'td' }, [
								E('div', { 'class': 'controls' }, [
									E('div', { 'class': 'pager center', 'style': 'display: flex; align-items: center; gap: 10px;' }, [
										E('button', { 
											'class': 'btn cbi-button-neutral prev', 
											'aria-label': _('Previous modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'style': 'min-width: 40px;',
											'disabled': buttonsDisabled
										}, [ ' ◄ ' ]),
										E('div', { 'class': 'text modem-display-text', 'style': 'flex: 1; text-align: center;' }, [ label ]),
										E('button', { 
											'class': 'btn cbi-button-neutral next', 
											'aria-label': _('Next modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'style': 'min-width: 40px;',
											'disabled': buttonsDisabled
										}, [ ' ► ' ])
									])
								])
							])
						]);
					} else {
						return E('div', { 'style': 'display: none;' });
					}
				}.bind(this))(),
    				(function() {
					/* In the ModemManager mode (sms_via_mm) the storage
					   selection takes no part in reading - messages live in
					   ModemManager, not in SM/ME. Hide the switch (but keep
					   the radios in the DOM: the refresh logic reads the
					   checked one unconditionally). */
					var cfg = uci.sections('sms_tool_js');
					var viaMM = (cfg && cfg[0] && cfg[0].sms_via_mm == '1');
					return E('tr', { 'class': 'tr', 'style': viaMM ? 'display: none;' : null }, [
        				E('td', { 'class': 'td left', 'width': '33%' }, [ _('Message storage area') ]),
        					E('td', { 'class': 'td' }, [
							E('div', [
							E('label', {
								'style': 'display:inline-flex;align-items:center;gap:6px;vertical-align:middle;',
								'data-tooltip': _('Any change in the area from which SMS messages will be read requires refreshing the messages')
							}, [
							E('input', {
								'type': 'radio',
								'name': 'filter_area',
								'value': 'sim',
								'change': ui.createHandlerFn(this, 'handleSWarea'),
								'checked': true
							}),
							' ',
							_('SIM card')
						]),
						' \u00a0 ',
							E('label', {
								'style': 'display:inline-flex;align-items:center;gap:6px;vertical-align:middle;',
								'data-tooltip': _('Any change in the area from which SMS messages will be read requires refreshing the messages')
							}, [
							E('input', {
								'type': 'radio',
								'name': 'filter_area',
								'value': 'memory',
								'change': ui.createHandlerFn(this, 'handleSWarea')
							}),
							' ',
							_('Modem memory')
							])
						])
						])
    					]);
				}.bind(this))(),
    					E('tr', { 'class': 'tr' }, [
        					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Storage used / Total capacity') ]),
        					E('td', { 'class': 'td' }, [
            				E('div', { 'class': 'right' }, [
		                	E('div', {
                    				'id': 'msg',
                    				'class': 'cbi-progressbar',
                    				'title': '-'
                			}, E('div')),
				            E('div', { 'class': 'right' }, [
                			E('div', {
                    				'style': 'text-align:center;font-size:90%',
                    				'id': 'deleteinfo'
                			}, [ '' ]),
				        ]),
            		]),
        		]),
    		]),
		]),

				E('div', {'id': 'forward-status', 'style': 'margin: 10px 0; display: none;'}),

				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'id': 'forward',
						'click': ui.createHandlerFn(this, 'handleForward')
					}, [ _('Forward SMS') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'execute',
						'click': ui.createHandlerFn(this, 'handleDelete')
					}, [ _('Delete') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-add',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, [ _('Refresh') ]),

			]),

			E('p'),

			E('table', { 'class': 'table' , 'id' : 'smsTable' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th checker' }, 
					E('input', {
						'id': 'ch-all',
						'type': 'checkbox',
						'name': 'checkall',
						'disabled': null,
						'checked': null,
						'click': ui.createHandlerFn(this, 'handleSelect')
					}), '',
					),
					E('th', { 'class': 'th from' }, _('Sender')),
					E('th', { 'class': 'th received' }, _('Received')),
					E('th', { 'class': 'th center message' }, _('Message'))
				])
			]),
		]);
		
		return v;
	},

	popTimeout: function(a, message, timeout, severity) {
		ui.addTimeLimitedNotification(a, message, timeout, severity);
	}
});
