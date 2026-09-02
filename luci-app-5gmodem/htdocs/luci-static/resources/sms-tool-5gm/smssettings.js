'use strict';
'require baseclass';
'require form';
'require fs';
'require uci';
'require ui';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.

	Shared settings panels for the SMS views. Each view (Inbox / Send /
	USSD / AT) can embed the settings relevant to it behind a checkbox,
	so the dedicated "SMS Settings" tab is no longer needed.
*/

function update_sms_count_for_modem_sync(newValue, currentPort) {
	return uci.load('defmodems').then(function() {
		let defmodemSections = uci.sections('defmodems', 'defmodems');
		if (!defmodemSections || defmodemSections.length === 0)
			return newValue;

		let serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		if (serialModems.length === 0)
			return newValue;

		let currentModemIndex = -1;
		for (let i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				currentModemIndex = i + 1;
				break;
			}
		}
		if (currentModemIndex === -1)
			return newValue;

		let existingSmsCount = uci.get('5gmodem', 'sms', 'sms_count') || '';
		let parts = existingSmsCount.split(' ').filter(function(p) { return p.trim() !== ''; });

		let updated = {};
		parts.forEach(function(part) {
			let match = part.match(/^dfm(\d+)_(\d+)$/);
			if (match)
				updated[match[1]] = match[2];
		});
		updated[currentModemIndex] = newValue;

		let result = [];
		for (let key in updated)
			if (updated.hasOwnProperty(key))
				result.push('dfm' + key + '_' + updated[key]);

		return result.join(' ');
	}).catch(function() {
		return newValue;
	});
}

var pkg = {
	get Name() { return 'mailsend'; },
	bestPkgMgrURI: function () {
		return L.resolveDefault(
			fs.stat('/www/luci-static/resources/view/system/package-manager.js'), null
		).then(function (st) {
			if (st && st.type === 'file')
				return 'admin/system/package-manager';
			return L.resolveDefault(fs.stat('/usr/libexec/package-manager-call'), null)
				.then(function (st2) {
					return st2 ? 'admin/system/package-manager' : 'admin/system/opkg';
				});
		}).catch(function () { return 'admin/system/opkg'; });
	},
	openInstallerSearch: function (query) {
		let self = this;
		return self.bestPkgMgrURI().then(function (uri) {
			let q = query ? ('?query=' + encodeURIComponent(query)) : '';
			window.open(L.url(uri) + q, '_blank', 'noopener');
		});
	},
	/* Менеджер пакетов ищем ПРОВЕРКОЙ НАЛИЧИЯ файла, а не попыткой запуска.
	   Прежний вариант дёргал три пути подряд, полагаясь на .catch. На прошивках
	   с apk первых двух нет, и каждый заход на страницу писал в консоль браузера
	   по два «POST /cgi-bin/cgi-exec 404 (Executable not found)». Работать это не
	   мешало (срабатывал третий путь), но пугало и маскировало настоящие ошибки:
	   отменить уже отправленный XHR из JS нельзя, консоль пишет их сама.
	   fs.stat отвечает обычным RPC-ответом и следа в консоли не оставляет. */
	checkPackages: function() {
		var candidates = [
			'/usr/libexec/package-manager-call',  /* apk и свежие сборки */
			'/usr/bin/opkg',                      /* классический opkg */
			'/usr/libexec/opkg-call'
		];

		function findBin(i) {
			if (i >= candidates.length) { return Promise.resolve(null); }
			return L.resolveDefault(fs.stat(candidates[i]), null).then(function(st) {
				return st ? candidates[i] : findBin(i + 1);
			});
		}

		return findBin(0).then(function(bin) {
			if (!bin) { return ''; }
			return fs.exec_direct(bin, ['list-installed'], 'text').catch(function() { return ''; });
		}).then(function (data) {
			data = (data || '').trim();
			return data ? data.split('\n') : [];
		});
	},
	_isPackageInstalled: function(pkgName) {
		return this.checkPackages().then(function(installedPackages) {
			return installedPackages.some(function(pkg) {
				return pkg.includes(pkgName);
			});
		});
	}
};

var emailProviders = {
	'custom':     { name: _('user define'),               smtp: '',                     port: '',    security: 'tls' },
	'gmail':      { name: 'Gmail',                         smtp: 'smtp.gmail.com',       port: '587', security: 'tls' },
	'outlook':    { name: 'Outlook.com / Hotmail',         smtp: 'smtp-mail.outlook.com',port: '587', security: 'tls' },
	'yahoo':      { name: 'Yahoo Mail',                    smtp: 'smtp.mail.yahoo.com',  port: '587', security: 'tls' },
	'icloud':     { name: 'iCloud Mail',                   smtp: 'smtp.mail.me.com',     port: '587', security: 'tls' },
	'aol':        { name: 'AOL Mail',                      smtp: 'smtp.aol.com',         port: '587', security: 'tls' },
	'zoho':       { name: 'Zoho Mail',                     smtp: 'smtp.zoho.com',        port: '587', security: 'tls' },
	'mailru':     { name: 'Mail.ru',                       smtp: 'smtp.mail.ru',         port: '465', security: 'ssl' },
	'yandex':     { name: 'Yandex.Mail',                   smtp: 'smtp.yandex.com',      port: '465', security: 'ssl' },
	'gmx':        { name: 'GMX Mail',                      smtp: 'smtp.gmx.com',         port: '587', security: 'tls' },
	'mailcom':    { name: 'Mail.com',                      smtp: 'smtp.mail.com',        port: '587', security: 'tls' },
	'fastmail':   { name: 'FastMail',                      smtp: 'smtp.fastmail.com',    port: '587', security: 'tls' },
	'sina':       { name: 'Sina Mail',                     smtp: 'smtp.sina.com',        port: '587', security: 'tls' },
	'mailboxorg': { name: 'Mailbox.org',                   smtp: 'smtp.mailbox.org',     port: '587', security: 'tls' },
	'o2pl':       { name: 'o2.pl',                         smtp: 'poczta.o2.pl',         port: '465', security: 'ssl' },
	'wppl':       { name: 'wp.pl',                         smtp: 'smtp.wp.pl',           port: '465', security: 'ssl' },
	'interia':    { name: 'interia.pl',                    smtp: 'poczta.interia.pl',    port: '465', security: 'ssl' }
};

/* ---- option builders per group -------------------------------------- */

function addReceiveIncoming(s) {
	var o;

	o = s.option(form.Flag, 'sms_via_mm', _('Read and send SMS via ModemManager (mmcli)'),
		_('For modems managed by ModemManager over MBIM/QMI (e.g. Compal RXM-G1 / Tri Cascade VOS_5G): incoming messages are captured by ModemManager and never appear in AT storages, so sms_tool cannot see them. In this mode port and storage settings are not used. Requires the modemmanager package.'));
	o.rmempty = false;

	o = s.option(form.ListValue, 'storage', _('Message storage area'),
		_('Both reading and receiving: the modem is told to put new incoming messages here as well. A modem that cannot receive into the chosen storage keeps its own, and this setting is corrected to match - the list always shows the box the messages actually land in. SIM cards hold only two or three dozen messages - once full, the operator stops delivering. Until you pick a value here, the app selects the larger storage of the two on its own.'));
	o.value('SM', _('SIM card'));
	o.value('ME', _('Modem memory'));
	o.default = 'SM';
	o.rmempty = false;
	/* РУЧНОЙ ВЫБОР ВЫШЕ АВТОМАТИЧЕСКОГО. Автовыбор хранилища (set_sms_storage
	   в msw/iface.sh) отступает, увидев этот флаг: иначе он переставлял бы
	   значение при каждом переключении модема, и выбор человека не жил бы до
	   следующей перезагрузки. Пишется ТОЛЬКО при изменении - LuCI зовёт write()
	   лишь когда значение формы разошлось с конфигом. */
	o.write = function(section_id, value) {
		uci.set('5gmodem', 'sms', 'storage_touched', '1');
		return form.ListValue.prototype.write.apply(this, [section_id, value]);
	};

	/* --- Перенос входящих в память роутера ---------------------------------
	   Память для входящих у модема крошечная, а у части модемов её нет вовсе:
	   FM350 на AT+CPMS=? отвечает ("SM"),("SM"),("SM") - только SIM, десять
	   слотов. Заполнились - оператор больше ничего не доставит. Перенос к себе
	   снимает потолок совсем. */
	o = s.option(form.Flag, 'archive', _('Keep messages in router memory'),
		_('Copy incoming messages to the router and show them from there. Modem storage is tiny - some modems have no memory of their own at all and can only use the SIM card, where a couple of dozen slots fill up and the operator stops delivering. Messages are kept on flash and survive a reboot.'));
	o.default = '0';
	o.rmempty = false;

	o = s.option(form.Flag, 'archive_purge', _('Free modem slots'),
		_('Delete a message from the modem once it is in the router memory. This is what removes the limit. A message is only deleted after it has been stored AND, if enabled, forwarded to Telegram and offered to the SMS commands - so nothing is lost when the network is down.'));
	o.default = '1';
	o.rmempty = false;
	o.depends('archive', '1');

	o = s.option(form.ListValue, 'archive_limit', _('Keep at most'),
		_('Older messages are dropped when the limit is reached.'));
	[ '50', '100', '200', '500', '1000', '2000' ].forEach(function(v) {
		o.value(v, _('%s messages').format(v));
	});
	o.default = '200';
	o.depends('archive', '1');

	o = s.option(form.Flag, 'mergesms', _('Merge split messages'),
		_('Checking this option will make it easier to read the messages, but it will cause a discrepancy in the number of messages shown and received'));
	o.rmempty = false;

	o = s.option(form.ListValue, 'algorithm', _('Merge algorithm'));
	o.value('Simple', _('Simple (merge without sorting)'));
	o.value('Advanced', _('Advanced (merge with sorting)'));
	o.depends('mergesms', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };
	o.default = 'Simple';
	o.rmempty = false;
	o.write = function(section_id, value) {
		if (value != 'Simple' && value != 'Advanced')
			value = this.default;
		return form.ListValue.prototype.write.apply(this, [section_id, value]);
	};

	o = s.option(form.ListValue, 'direction', _('Direction of message merging'));
	o.value('Start', _('From beginning to end'));
	o.value('End', _('From end to beginning'));
	o.depends('algorithm', 'Advanced');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };
	o.default = 'Start';
	o.rmempty = false;

	o = s.option(form.Value, 'bnumber', _('Phone number to be blurred'),
		_('The last 5 digits of this number will be blurred'));
	o.password = true;

	o = s.option(form.Button, '_fsave');
	o.title = _('Save messages to a text file');
	o.description = _('This option allows to backup SMS messages or, for example, save messages that are not supported by the sms-tool');
	o.inputtitle = _('Save as .txt file');
	o.onclick = function() {
		return uci.load('5gmodem').then(function() {
			let portES = uci.get('5gmodem', 'sms', 'readport');
			/* Через smsbridge.sh, а не бинарь sms_tool: в ACL больше нет exec на
			   /usr/bin/sms_tool, потому что через него из браузера уходили любые
			   аргументы. Заодно ушёл и мусор - строка '2>/dev/null' раньше
			   передавалась sms_tool КАК АРГУМЕНТ (это не шелл, перенаправление
			   тут не работает). */
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'dump', '', portES ]))
				.then(function(res) {
					if (!res) return;
					fs.write('/tmp/mysms.txt', res.trim().replace(/\r\n/g, '\n') + '\n');
					fs.stat('/tmp/mysms.txt').then(function () {
						if (confirm(_('Save sms to txt file?'))) {
							L.resolveDefault(fs.read_direct('/tmp/mysms.txt'), null).then(function (restxt) {
								if (restxt) {
									L.ui.showModal(_('Saving...'), [
										E('p', { 'class': 'spinning' }, _('Please wait, saving the SMS messages to a text file'))
									]);
									let link = E('a', {
										'download': 'mysms.txt',
										'href': URL.createObjectURL(new Blob([ restxt ], { type: 'text/plain' })),
									});
									window.setTimeout(function() {
										link.click();
										URL.revokeObjectURL(link.href);
										L.hideModal();
									}, 2000).finally();
								} else {
									ui.addNotification(null, E('p', {}, _('Saving the SMS messages to a file failed. Please try again.')));
								}
							});
						}
					});
				});
		});
	};

	o = s.option(form.Button, '_fdelete');
	o.title = _('Delete all messages');
	o.description = _("This option deletes all SMS messages, including ones not visible on the Inbox tab");
	o.inputtitle = _('Delete all');
	o.onclick = function() {
		if (confirm(_('Delete all the messages?'))) {
			return uci.load('5gmodem').then(function() {
				let portFD = uci.get('5gmodem', 'sms', 'readport');
				/* smsbridge.sh знает про транспорт (AT или ModemManager) и берёт
				   очередь к порту - в отличие от прямого вызова бинаря. */
				fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'delete', 'all', '', portFD ]);
			});
		}
	};
}

function addNotifications(s) {
	var o;

	o = s.option(form.Flag, 'lednotify', _('Notify about new messages'),
		_('The LED signals a new message. Before enabling this, configure and save the SMS reading port, the inbox check interval and the notification LED.'));
	o.rmempty = false;
	o.default = true;
	o.write = function(section_id, value) {
		return uci.load('5gmodem').then(function() {
			let storeL = uci.get('5gmodem', 'sms', 'storage');
			let portR  = uci.get('5gmodem', 'sms', 'readport');
			let dsled  = uci.get('5gmodem', 'sms', 'ledtype');

			if (!portR) {
				ui.addNotification(null, E('p', {}, _('Please configure the SMS reading port first')), 'info');
				return form.Flag.prototype.write.apply(this, [section_id, value]);
			}

			/* Формат вывода тот же (строка «Storage type: …, used: N, total: M»),
			   её и разбирает код ниже - smsbridge.sh отдаёт её без изменений. */
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status', storeL, portR ]))
				.then(function(res) {
					if (!res) return;
					let total = res.substring(res.indexOf('total'));
					let t = total.replace(/[^\d.]/g, '');
					let used = res.substring(17, res.indexOf('total'));
					let u = used.replace(/[^\d.]/g, '');

					if (value == '1') {
						return update_sms_count_for_modem_sync(u, portR).then(function(updatedValue) {
							uci.set('5gmodem', 'sms', 'sms_count', updatedValue);
							uci.set('5gmodem', 'sms', 'lednotify', '1');
							let PTR = uci.get('5gmodem', 'sms', 'prestart');
							/* Через smscron.sh. Раньше страница читала /etc/crontabs/root
							   целиком, фильтровала строки и записывала обратно - для этого
							   в ACL было право `write` на crontab, то есть возможность
							   положить туда любую команду от root. Скрипт трогает ТОЛЬКО
							   нашу строку, проверяет интервал и сам перезапускает cron и
							   уведомитель. */
							return uci.save().then(function() {
								return fs.exec_direct('/usr/share/5gmodem/smscron.sh', [ 'on', String(PTR) ]);
							});
						});
					}

					if (value == '0') {
						uci.set('5gmodem', 'sms', 'lednotify', '0');
						/* см. выше: снятие расписания тоже через smscron.sh - он уберёт
						   только нашу строку и остановит уведомитель. */
						return uci.save().then(function() {
							return fs.exec_direct('/usr/share/5gmodem/smscron.sh', [ 'off' ]);
						}).then(function() {
							if (dsled == 'D') {
								let led = uci.get('5gmodem', 'sms', 'smsled');
								if (led)
									return fs.write('/sys/class/leds/' + led + '/brightness', '0');
							}
						});
					}
				}.bind(this));
		}.bind(this)).then(function() {
			return form.Flag.prototype.write.apply(this, [section_id, value]);
		}.bind(this));
	};

	o = s.option(form.Flag, 'ontopsms', _('Show notification icon'),
		_('Show the new-message notification icon on the status overview page'));
	o.rmempty = false;

	o = s.option(form.Value, 'checktime', _('Check the inbox every, minutes'),
		_('How often (in minutes) the inbox is checked'));
	o.default = '10';
	o.rmempty = false;
	o.validate = function(section_id, value) {
		if (value.match(/^[0-9]+(?:\.[0-9]+)?$/) && +value >= 5 && +value < 60)
			return true;
		return _('Enter a number between 5 and 59');
	};
	o.datatype = 'range(5, 59)';

	o = s.option(form.ListValue, 'prestart', _('Restart the inbox-checking process every'),
		_('The process restarts at the chosen interval, which removes any delay in checking the inbox'));
	o.value('4', _('4h'));
	o.value('6', _('6h'));
	o.value('8', _('8h'));
	o.value('12', _('12h'));
	o.default = '6';
	o.rmempty = false;

	o = s.option(form.ListValue, 'ledtype',
		_('LED is dedicated only to these notifications'),
		_("Select 'No' if the router has a single LED or the LED serves several purposes. This option needs an LED defined in the system to work reliably when the LED is shared."));
	o.value('S', _('No'));
	o.value('D', _('Yes'));
	o.default = 'D';
	o.rmempty = false;

	o = s.option(form.ListValue, 'smsled', _('<abbr title="Light Emitting Diode">LED</abbr> name'),
		_('Select the notification LED'));
	o.load = function(section_id) {
		return L.resolveDefault(fs.list('/sys/class/leds'), []).then(L.bind(function(leds) {
			if (leds.length > 0) {
				leds.sort((a, b) => a.name > b.name);
				leds.forEach(e => o.value(e.name));
			}
			return this.super('load', [section_id]);
		}, this));
	};
	o.nocreate = true;
	o.optional = true;
	o.rmempty = true;
}

function addEmailForwarding(s) {
	var o;

	o = s.option(form.Flag, 'forward_sms_enabled', _('Enable message forwarding'));
	o.rmempty = false;
	o.write = function(section_id, value) {
		if (value === '1') {
			return pkg._isPackageInstalled('mailsend').then(function(isInstalled) {
				if (!isInstalled) {
					ui.addNotification(null, E('p', {}, _('The mailsend package is not installed. Install it first using the Install… button below.')), 'info');
					return form.Flag.prototype.write.apply(this, [section_id, '0']);
				}
				return form.Flag.prototype.write.apply(this, [section_id, value]);
			}.bind(this));
		}
		return form.Flag.prototype.write.apply(this, [section_id, value]);
	};

	o = s.option(form.ListValue, 'emailprovider', _('E-mail settings'),
		_('Pick a predefined e-mail provider or enter the settings manually'));
	for (var key in emailProviders)
		o.value(key, emailProviders[key].name);
	o.default = 'custom';
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };
	o.onchange = function(ev, section_id, value) {
		var provider = emailProviders[value] || emailProviders['custom'];
		var map = this.map;
		var f;
		f = map.lookupOption('forward_sms_mail_smtp', section_id);
		if (f && f[0]) f[0].getUIElement(section_id).setValue(provider.smtp);
		f = map.lookupOption('forward_sms_mail_smtp_port', section_id);
		if (f && f[0]) f[0].getUIElement(section_id).setValue(provider.port);
		f = map.lookupOption('forward_sms_mail_security', section_id);
		if (f && f[0]) f[0].getUIElement(section_id).setValue(provider.security);
	};

	o = s.option(form.Value, 'forward_sms_mail_recipient', _('Recipient'));
	o.description = _('E-mail address of the recipient');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_sender', _('Sender'));
	o.description = _('E-mail address of the sender');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_user', _('User'));
	o.description = _('Username for SMTP authentication');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_password', _('Password'));
	o.description = _('App password / password for SMTP authentication');
	o.password = true;
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_smtp', _('SMTP server'));
	o.description = _('Hostname or IP address of the SMTP server');
	o.datatype = 'host';
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_smtp_port', _('SMTP server port'));
	o.datatype = 'port';
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.ListValue, 'forward_sms_mail_security', _('Security'));
	o.description = '%s<br />%s'.format(
		_('TLS: use STARTTLS if the server supports it'),
		_('SSL: SMTP over SSL'));
	o.value('tls', 'TLS');
	o.value('ssl', 'SSL');
	o.default = 'tls';
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.DummyValue, '_mailsend_status', _('mailsend package'));
	o.rawhtml = true;
	o.cfgvalue = function() { return ''; };
	o.render = function() {
		return pkg._isPackageInstalled('mailsend').then(function(isInstalled) {
			var content = isInstalled
				? E('span', { 'class': 'cbi-value-field', 'style': 'font-style: italic;' }, _('Installed'))
				: E('button', { 'class': 'cbi-button cbi-button-action', 'click': function() { pkg.openInstallerSearch('mailsend'); } }, _('Install…'));
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('mailsend')),
				E('div', { 'class': 'cbi-value-field' }, content)
			]);
		});
	};
}

/* ПЕРЕСЫЛКА ВХОДЯЩИХ В TELEGRAM.
   Работает поверх той же отметки «виденное», что подсвечивает страницу
   «Входящие» (smsbridge.sh seen), поэтому бот и страница не спорят о том, что
   человек уже читал. Доставку делает tgnotify.sh из цикла сторожа. */
function addTelegramForwarding(s) {
	var o;

	o = s.option(form.Flag, 'tg_enabled', _('Telegram bot'),
		_('One bot for both directions: it forwards every new incoming SMS to the chosen chat and, if allowed below, sends SMS by the /sms command from that chat. Works with the ACTIVE modem: messages from the SIM of the other modem are not forwarded until you switch to it. The very first run only remembers the current messages and sends nothing. Settings live here only - the outgoing page just points at them.'));
	o.rmempty = false;

	o = s.option(form.Value, 'tg_token', _('Bot token'),
		_('Token issued by @BotFather, e.g. 123456789:AA...'));
	o.password = true;
	o.depends('tg_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ - как и в почтовой пересылке: LuCI удаляет
	   опции со скрытыми зависимостями, и токен пропадал бы при каждом
	   временном выключении. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'tg_chat', _('Chat ID'),
		_('Numeric chat or channel ID. Write any message to the bot first, then press the button below - it will find the ID for you.'));
	o.depends('tg_enabled', '1');
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Button, '_tgchatid', _('Find Chat ID'),
		_('Uses the SAVED token: write to the bot first, then save the form and press this.'));
	o.inputtitle = _('Find');
	o.inputstyle = 'apply';
	o.depends('tg_enabled', '1');
	o.onclick = function(ev, section_id) {
		var self = this;
		/* Любой сбой обязан быть ВИДЕН: молчащая кнопка неотличима от сломанной. */
		return fs.exec_direct('/usr/share/5gmodem/tgnotify.sh', [ 'chatid' ]).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Could not query Telegram: %s').format(e && e.message || e)), 'error');
			return '';
		}).then(function(out) {
			if (!out) { return; }
			var j = {};
			try { j = JSON.parse(out || '{}'); } catch (e) {}
			if (!j.ok) {
				/* «noreply» - сеть молчит на прямом пути И через прокси: у
				   операторов РФ прямой доступ к Telegram закрыт, и без
				   работающего SSClash (или VPN-аплинка) роутеру туда не
				   попасть. Без расшифровки человек шёл проверять токен,
				   который тут ни при чём. */
				var msg = (j.error === 'noreply')
					? _('Telegram is not reachable from the router: the direct path is blocked by the carrier and no working proxy tunnel was found. Start SSClash (or route the router through a VPN) and try again.')
					: _('Could not query Telegram: %s').format(j.error || _('check the token and the router internet connection'));
				ui.addNotification(null, E('p', {}, msg), 'error');
				return;
			}
			/* Имена Telegram отдаёт в \uXXXX - без раскодирования в уведомлении
			   вместо «Фил» показывалось бы «\u0424\u0438\u043b». */
			var unesc = function(v) {
				return String(v || '').replace(/\\u([0-9a-fA-F]{4})/g, function(m, h) {
					return String.fromCharCode(parseInt(h, 16));
				});
			};
			var chats = (j.chats || []).map(function(c) {
				return { id: c.id, name: unesc(c.name), type: c.type };
			});
			if (!chats.length) {
				ui.addNotification(null, E('p', {},
					_('Telegram returned no chats. Write any message to the bot and press the button again.')), 'info');
				return;
			}
			/* Один чат - подставляем сразу, несколько - даём выбрать: у человека
			   бывает и личный чат, и канал, и по одному ID их не различить. */
			/* Подставляем в поле И СРАЗУ ПИШЕМ В КОНФИГ. Одна подстановка живёт
			   до первого «Сохранить», и после «Найти» конфиг оставался пустым -
			   ровно то, что сбивает с толку. */
			var fill = function(id, name) {
				var f = self.map.lookupOption('tg_chat', section_id);
				if (f && f[0]) { f[0].getUIElement(section_id).setValue(id); }
				return fs.exec_direct('/usr/share/5gmodem/tgnotify.sh', [ 'setchat', String(id) ])
					.then(function(o) {
						var r = {};
						try { r = JSON.parse(o || '{}'); } catch (e) {}
						ui.addNotification(null, E('p', {}, r.ok
							? _('Chat ID found and saved: %s (%s)').format(id, name || '')
							: _('Chat ID found: %s - but saving failed, press Save manually').format(id)),
							r.ok ? 'info' : 'warning');
					});
			};
			if (chats.length === 1) {
				return fill(chats[0].id, chats[0].name || chats[0].type);
			}
			ui.showModal(_('Find Chat ID'), [
				E('p', {}, _('Pick the chat the messages should go to:')),
				E('div', {}, chats.map(function(c) {
					return E('div', { 'style': 'margin:.4em 0' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-apply',
							'click': function() { ui.hideModal(); fill(c.id, c.name || c.type); }
						}, [ '%s — %s (%s)'.format(c.id, c.name || '?', c.type) ])
					]);
				})),
				E('div', { 'class': 'right' }, [
					E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ])
				])
			]);
		});
	};

	o = s.option(form.ListValue, 'tg_interval', _('Check for new messages every'));
	o.value('60', _('1 min'));
	o.value('300', _('5 min'));
	o.value('900', _('15 min'));
	o.default = '60';
	o.depends('tg_enabled', '1');
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Flag, 'tg_commands', _('Allow sending SMS from the chat'),
		_('The bot accepts commands from the chat above: /sms &lt;number&gt; &lt;text&gt; sends an SMS, /status shows the modem state. Commands are accepted ONLY from the configured Chat ID - the bot itself is reachable by anyone who knows its name.'));
	o.depends('tg_enabled', '1');
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Button, '_tgtest', _('Test delivery'),
		_('Sends a test message with the SAVED settings - save the form first.'));
	o.inputtitle = _('Send test message');
	o.inputstyle = 'apply';
	o.onclick = function() {
		return fs.exec_direct('/usr/share/5gmodem/tgnotify.sh', [ 'test' ]).then(function(out) {
			var j = {};
			try { j = JSON.parse(out || '{}'); } catch (e) {}
			if (j.ok) {
				ui.addNotification(null, E('p', {}, _('Test message sent')), 'info');
			} else {
				ui.addNotification(null, E('p', {},
					_('Failed to send: %s').format(j.error || _('check the token, chat ID and the router internet connection'))), 'error');
			}
		});
	};
}

function addSendOptions(s) {
	var o;

	/* ПОДСКАЗКА ПРО БОТА - БЕЗ ДУБЛИРОВАНИЯ НАСТРОЕК.
	   Бот один, токен один, чат один, поэтому форма живёт только во «Входящих».
	   Здесь - строка состояния: человек узнаёт о возможности ровно там, где
	   собрался отправлять сообщение, но настраивает в одном месте. */
	o = s.option(form.DummyValue, '_tginfo', _('Telegram bot'));
	o.rawhtml = true;
	o.cfgvalue = function() {
		var en = uci.get('5gmodem', 'sms', 'tg_enabled');
		var tok = uci.get('5gmodem', 'sms', 'tg_token');
		var chat = uci.get('5gmodem', 'sms', 'tg_chat');
		var cmd = uci.get('5gmodem', 'sms', 'tg_commands');
		if (en !== '1' || !tok || !chat) {
			return '<span style="opacity:.7">%s</span>'.format(
				_('SMS can also be sent from a Telegram chat - set the bot up on the Inbox settings page.'));
		}
		if (cmd !== '1') {
			return '<span style="opacity:.7">%s</span>'.format(
				_('The bot is connected for incoming messages. To send SMS from the chat, tick "Allow sending SMS from the chat" on the Inbox settings page.'));
		}
		return '%s <code>/sms &lt;%s&gt; &lt;%s&gt;</code>'.format(
			_('Sending from the chat is on - write to the bot:'), _('number'), _('text'));
	};

	o = s.option(form.Value, 'pnumber', _('Prefix number'),
		_("The phone number should start with the country prefix in international format, with the '+' (for example +7 for Russia). Without the '+' the network treats the number as national and may refuse to send. Numbers of 3, 4 or 5 digits are treated as 'short' and must not get a country prefix."));
	o.default = '+7';
	o.validate = function(section_id, value) {
		if (value.match(/^\+?[0-9]+$/))
			return true;
		return _('Enter a country prefix, for example +7');
	};

	o = s.option(form.Flag, 'prefix', _('Add prefix to the phone number'),
		_('Automatically add the prefix to the phone-number field'));
	o.rmempty = false;

	o = s.option(form.Flag, 'sendingroup', _('Enable group messaging'),
		_('Send one message to every contact in the contact list'));
	o.rmempty = false;
	o.default = false;

	o = s.option(form.Value, 'delay', _('Message-sending delay'),
		_('3–59 seconds. Important: messages are sent without delivery verification or confirmation, so there is a risk they are not delivered.'));
	o.default = '3';
	o.rmempty = false;
	o.validate = function(section_id, value) {
		if (value.match(/^[0-9]+(?:\.[0-9]+)?$/) && +value >= 3 && +value < 60)
			return true;
		return _('Enter a number between 3 and 59');
	};
	o.depends('sendingroup', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };
	o.datatype = 'range(3, 59)';

	/* Галка «показывать подсказку о формате номера» убрана: подсказка нужна
	   один раз, и отдельная настройка ради неё - лишняя сущность. Теперь ею
	   управляет кнопка «Закрыть» на самой подсказке (см. sendsms.js): закрыл -
	   больше не появляется. Опция information в конфиге остаётся тем же
	   признаком, просто выставляется кнопкой, а не здесь. */
}

function addUssdOptions(s) {
	var o;

	o = s.option(form.Flag, 'ussd', _('Send the USSD code as plain text'),
		_('Send the USSD code as plain text; the command is not encoded into a PDU'));
	o.rmempty = false;

	o = s.option(form.Flag, 'pdu', _('Receive the reply without PDU decoding'),
		_('Receive and display the reply without decoding it as a PDU'));
	o.rmempty = false;

	o = s.option(form.Flag, 'ussd_3g', _('Switch the modem to 3G for USSD'),
		_('USSD runs over the circuit-switched channel, which LTE does not have. Some modems handle this themselves; others answer nothing until the modem is actually in 3G. With this option the request switches the modem to 3G and switches it back - about twenty seconds without a connection. It is enabled automatically for modems already known to need it.'));
	o.rmempty = false;
	/* ЗАПОМИНАЕМ ВЫБОР У МОДЕМА, а не только в общей настройке. Галка одна на
	   приложение, а нужна она не всем: при переключении модема modemswitch.sh
	   выставляет её по базе проверенных, и без этой записи выбор пользователя
	   терялся бы на первом же переключении. Секция модема главнее базы. */
	o.write = function(section_id, value) {
		uci.set('5gmodem', section_id, 'ussd_3g', value);
		var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
		if (p) { uci.set('5gmodem', 'm_' + p.replace(/[^A-Za-z0-9]/g, '_'), 'ussd_3g', value); }
	};

	o = s.option(form.ListValue, 'coding', _('PDU decoding scheme'));
	o.value('auto', _('Autodetect'));
	o.value('0', _('7-bit'));
	o.value('2', _('UCS2'));
	o.default = 'auto';

	o = s.option(form.Flag, 'ussd_via_mm', _('Send USSD via ModemManager (mmcli)'),
		_('Use ModemManager instead of sms_tool to send USSD codes, for modems managed by ModemManager that do not handle +CUSD on the AT port properly (e.g. Compal RXM-G1 / Tri Cascade VOS_5G). Requires the modemmanager package. The USSD port setting is not used in this mode.'));
	o.rmempty = false;
}

/* ---- команды по SMS --------------------------------------------------------
   Последний работающий канал управления, когда сети нет: канал лёг, адрес
   сменился, туннель не поднялся - а SMS доходит. Поэтому выключено по
   умолчанию и с белым списком номеров: команду присылает кто угодно, кто знает
   номер симки. Текст в командную строку НЕ подставляется, хвост после
   ключевого слова уходит в переменную окружения SMS_ARGS (см. smscmd.sh). */
function addSmsCommands(s) {
	var o;

	o = s.option(form.Flag, 'cmd_enabled', _('Run commands from SMS'),
		_('Send an SMS that starts with the word of a command below - the router runs it. Useful when the router is unreachable over the network: SMS still gets through. The message text is never pasted into the command line, whatever follows the word is passed as the SMS_ARGS environment variable.'));
	o.default = '0';
	o.rmempty = false;

	o = s.option(form.Flag, 'cmd_whitelist_only', _('Trusted numbers only'),
		_('Run commands only from the numbers listed below. With this on and the list empty, nothing runs at all. Turning it off lets anyone who knows the SIM number run your commands.'));
	o.default = '1';
	o.rmempty = false;
	o.depends('cmd_enabled', '1');

	o = s.option(form.DynamicList, 'cmd_phone', _('Trusted numbers'),
		_('Compared by the last ten digits, so +7…, 8… and 7… are the same number.'));
	o.placeholder = '+79001234567';
	o.depends('cmd_whitelist_only', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ - как у остальных зависимых полей на этой
	   странице: выключил белый список на минуту, включил - список номеров
	   пришлось бы набирать заново. */
	o.remove = function() { return Promise.resolve(); };

	/* ЗАЩИТНЫЙ КОД - ОТДЕЛЬНО ОТ СЛОВА КОМАНДЫ. Их постоянно путают: слово
	   («reboot») говорит, ЧТО сделать, и секретом быть не может - оно записано
	   в настройках и очевидно с первого взгляда. Кода по умолчанию нет: пока
	   защита - только доверенные номера, а номер отправителя подделывается. */
	o = s.option(form.Value, 'cmd_secret', _('Security code'),
		_('The FIRST word of the message, before the command word: "%s" runs the command named "reboot" below. Change it to a word only you know - the default is the same for everyone. Empty means no code at all, and then the only protection is the list of trusted numbers - a sender number can be forged.').format('secret reboot'));
	o.placeholder = _('empty - no code');
	o.depends('cmd_enabled', '1');
	o.remove = function() { return Promise.resolve(); };

	var cv = s.option(form.SectionValue, '__smscmds', form.TableSection, 'smscmd');
	cv.depends('cmd_enabled', '1');
	var cs = cv.subsection;
	cs.anonymous = true;
	cs.addremove = true;
	cs.addbtntitle = '+';
	/* ПОДПИСИ КОЛОНОК - ОДНОЙ СТРОКОЙ НАД ТАБЛИЦЕЙ. В таблице описание каждой
	   опции рисуется отдельной строкой под заголовками и занимает больше места,
	   чем сами поля (проверено на стенде: пять абзацев над пустым списком). */
	cs.nodescriptions = true;
	cs.description = _('Send the word from the first column in an SMS - the router runs what is in the second. The word is matched without case, anything after it reaches the command as SMS_ARGS. A command that kills the connection (reboot, modem power cycle) needs a delay: the reply is then sent BEFORE the command runs, which is the only way it can be sent at all.');

	o = cs.option(form.Value, 'keyword', _('Word in the SMS'));
	o.placeholder = 'reboot';
	o.rmempty = false;

	o = cs.option(form.Value, 'exec', _('What to run'),
		_('A shell command, exactly as you would type it over SSH.'));
	o.placeholder = 'reboot';
	o.rmempty = false;

	o = cs.option(form.Flag, 'answer', _('Reply'));
	o.default = '0';

	o = cs.option(form.Value, 'answer_text', _('Reply text'));
	o.depends('answer', '1');

	o = cs.option(form.Value, 'delay', _('Delay, s'));
	o.placeholder = '0';
	o.datatype = 'range(0,300)';
}

var GROUPS = {
	receive: function(s) { addReceiveIncoming(s); addNotifications(s); addEmailForwarding(s); addTelegramForwarding(s); addSmsCommands(s); },
	send:    addSendOptions,
	ussd:    addUssdOptions
};

var styleInjected = false;
function injectStyle() {
	if (styleInjected) return;
	styleInjected = true;
	document.head.append(E('style', { 'type': 'text/css' }, `
		.sms-settings-panel { margin-top: 1em; }
		.sms-settings-panel > summary {
			cursor: pointer;
			font-weight: 600;
			padding: .4em 0;
			list-style: none;
			display: flex;
			align-items: center;
			gap: .4em;
			user-select: none;
		}
		.sms-settings-panel > summary::-webkit-details-marker { display: none; }
		.sms-settings-panel > summary::before {
			content: "";
			width: 0; height: 0;
			border-left: .4em solid currentColor;
			border-top: .32em solid transparent;
			border-bottom: .32em solid transparent;
			transition: transform .15s ease;
			opacity: .8;
		}
		.sms-settings-panel[open] > summary::before { transform: rotate(90deg); }
	`));
}

return baseclass.extend({
	/*
		Build a collapsible settings panel for a group as a native
		<details>/<summary> disclosure (arrow indicates it expands).
		Returns a Promise resolving to the DOM node.
	*/
	panel: function(group) {
		var build = GROUPS[group];
		if (!build)
			return Promise.resolve(E([]));

		injectStyle();

		var m = new form.Map('5gmodem');
		var s = m.section(form.NamedSection, 'sms', 'sms', '', null);
		s.addremove = false;
		build(s);

		var storeKey = '5gmodem_settings_' + group;
		var open = false;
		try { open = localStorage.getItem(storeKey) === '1'; } catch (e) {}

		return m.render().then(function(mapNode) {
			var attrs = { 'class': 'cbi-section tgpage sms-settings-panel' };
			if (open) attrs.open = '';
			var det = E('details', attrs, [
				E('summary', {}, _('Settings')),
				mapNode
			]);
			det.addEventListener('toggle', function() {
				try { localStorage.setItem(storeKey, det.open ? '1' : '0'); } catch (e) {}
			});
			return det;
		});
	}
});
