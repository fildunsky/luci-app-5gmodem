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

		let existingSmsCount = uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_count') || '';
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
		_('Messages are stored in a specific location (for example, on the SIM card or modem memory), but other areas may also be available depending on the type of device.'));
	o.value('SM', _('SIM card'));
	o.value('ME', _('Modem memory'));
	o.default = 'SM';
	o.rmempty = false;

	o = s.option(form.Flag, 'mergesms', _('Merge split messages'),
		_('Checking this option will make it easier to read the messages, but it will cause a discrepancy in the number of messages shown and received.'));
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
		_('The last 5 digits of this number will be blurred.'));
	o.password = true;

	o = s.option(form.Button, '_fsave');
	o.title = _('Save messages to a text file');
	o.description = _('This option allows to backup SMS messages or, for example, save messages that are not supported by the sms-tool.');
	o.inputtitle = _('Save as .txt file');
	o.onclick = function() {
		return uci.load('sms_tool_js').then(function() {
			let portES = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
			L.resolveDefault(fs.exec_direct('/usr/bin/sms_tool', [ '-d', portES, '-f', '%Y-%m-%d %H:%M', 'recv', '2>/dev/null']))
				.then(function(res) {
					if (!res) return;
					fs.write('/tmp/mysms.txt', res.trim().replace(/\r\n/g, '\n') + '\n');
					fs.stat('/tmp/mysms.txt').then(function () {
						if (confirm(_('Save sms to txt file?'))) {
							L.resolveDefault(fs.read_direct('/tmp/mysms.txt'), null).then(function (restxt) {
								if (restxt) {
									L.ui.showModal(_('Saving...'), [
										E('p', { 'class': 'spinning' }, _('Please wait, saving the SMS messages to a text file.'))
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
	o.description = _("This option deletes all SMS messages, including ones not visible on the Inbox tab.");
	o.inputtitle = _('Delete all');
	o.onclick = function() {
		if (confirm(_('Delete all the messages?'))) {
			return uci.load('sms_tool_js').then(function() {
				let portFD = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
				fs.exec_direct('/usr/bin/sms_tool', [ '-d', portFD, 'delete', 'all' ]);
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
		return uci.load('sms_tool_js').then(function() {
			let storeL = uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage');
			let portR  = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
			let dsled  = uci.get('sms_tool_js', '@sms_tool_js[0]', 'ledtype');

			if (!portR) {
				ui.addNotification(null, E('p', {}, _('Please configure the SMS reading port first')), 'info');
				return form.Flag.prototype.write.apply(this, [section_id, value]);
			}

			return L.resolveDefault(fs.exec_direct('/usr/bin/sms_tool', ['-s', storeL, '-d', portR, 'status']))
				.then(function(res) {
					if (!res) return;
					let total = res.substring(res.indexOf('total'));
					let t = total.replace(/[^\d.]/g, '');
					let used = res.substring(17, res.indexOf('total'));
					let u = used.replace(/[^\d.]/g, '');

					if (value == '1') {
						return update_sms_count_for_modem_sync(u, portR).then(function(updatedValue) {
							uci.set('sms_tool_js', '@sms_tool_js[0]', 'sms_count', updatedValue);
							uci.set('sms_tool_js', '@sms_tool_js[0]', 'lednotify', '1');
							let PTR = uci.get('sms_tool_js', '@sms_tool_js[0]', 'prestart');
							return uci.save().then(function() {
								return L.resolveDefault(fs.read('/etc/crontabs/root'), '');
							}).then(function(crontab) {
								let lines = (crontab || '').trim().replace(/\r\n/g, '\n').split('\n');
								let filteredLines = lines.filter(function(line) {
									return line.trim() !== '' && !line.includes('my_new_sms');
								});
								filteredLines.push('1 */' + PTR + ' * * * /etc/init.d/my_new_sms enable && /etc/init.d/my_new_sms restart');
								return fs.write('/etc/crontabs/root', filteredLines.join('\n') + '\n');
							}).then(function() {
								return fs.exec_direct('/etc/init.d/cron', ['restart']);
							}).then(function() {
								return fs.exec_direct('/etc/init.d/my_new_sms', ['enable']);
							}).then(function() {
								return fs.exec_direct('/etc/init.d/my_new_sms', ['start']);
							});
						});
					}

					if (value == '0') {
						uci.set('sms_tool_js', '@sms_tool_js[0]', 'lednotify', '0');
						return uci.save().then(function() {
							return L.resolveDefault(fs.read('/etc/crontabs/root'), '');
						}).then(function(crontab) {
							let lines = (crontab || '').trim().replace(/\r\n/g, '\n').split('\n');
							let filteredLines = lines.filter(function(line) {
								return line.trim() !== '' && !line.includes('my_new_sms');
							});
							return fs.write('/etc/crontabs/root', filteredLines.join('\n') + '\n');
						}).then(function() {
							return fs.exec_direct('/etc/init.d/cron', ['restart']);
						}).then(function() {
							return fs.exec_direct('/etc/init.d/my_new_sms', ['stop']);
						}).then(function() {
							return fs.exec_direct('/etc/init.d/my_new_sms', ['disable']);
						}).then(function() {
							if (dsled == 'D') {
								let led = uci.get('sms_tool_js', '@sms_tool_js[0]', 'smsled');
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
		_('Show the new-message notification icon on the status overview page.'));
	o.rmempty = false;

	o = s.option(form.Value, 'checktime', _('Check the inbox every, minutes'),
		_('How often (in minutes) the inbox is checked.'));
	o.default = '10';
	o.rmempty = false;
	o.validate = function(section_id, value) {
		if (value.match(/^[0-9]+(?:\.[0-9]+)?$/) && +value >= 5 && +value < 60)
			return true;
		return _('Enter a number between 5 and 59');
	};
	o.datatype = 'range(5, 59)';

	o = s.option(form.ListValue, 'prestart', _('Restart the inbox-checking process every'),
		_('The process restarts at the chosen interval, which removes any delay in checking the inbox.'));
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
		_('Select the notification LED.'));
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
		_('Pick a predefined e-mail provider or enter the settings manually.'));
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
	o.description = _('E-mail address of the recipient.');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_sender', _('Sender'));
	o.description = _('E-mail address of the sender.');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_user', _('User'));
	o.description = _('Username for SMTP authentication.');
	o.depends('forward_sms_enabled', '1');
	/* НЕ СТИРАТЬ ПРИ ВЫКЛЮЧЕНИИ. Поле скрыто, пока выключен родительский
	   переключатель, а LuCI удаляет из конфига опции с невыполненными
	   зависимостями - введённое пользователем пропадало молча. Особенно неприятно
	   с доступом к почте: выключил пересылку на минуту, включил - вводи пароль,
	   сервер и порт заново. Значения сохраняем; поведение становится
	   предсказуемым - настройка живёт, пока её не изменили. */
	o.remove = function() { return Promise.resolve(); };

	o = s.option(form.Value, 'forward_sms_mail_password', _('Password'));
	o.description = _('App password / password for SMTP authentication.');
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
	o.description = _('Hostname or IP address of the SMTP server.');
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
		_('TLS: use STARTTLS if the server supports it.'),
		_('SSL: SMTP over SSL.'));
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

function addSendOptions(s) {
	var o;

	o = s.option(form.Value, 'pnumber', _('Prefix number'),
		_("The phone number should start with the country prefix (for example 7 for Russia, without the '+'). Numbers of 3, 4 or 5 digits are treated as 'short' and must not get a country prefix."));
	o.default = '7';
	o.validate = function(section_id, value) {
		if (value.match(/^[0-9]+(?:\.[0-9]+)?$/))
			return true;
		return _('Enter a decimal value');
	};

	o = s.option(form.Flag, 'prefix', _('Add prefix to the phone number'),
		_('Automatically add the prefix to the phone-number field.'));
	o.rmempty = false;

	o = s.option(form.Flag, 'sendingroup', _('Enable group messaging'),
		_('Send one message to every contact in the contact list.'));
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
		_('Send the USSD code as plain text; the command is not encoded into a PDU.'));
	o.rmempty = false;

	o = s.option(form.Flag, 'pdu', _('Receive the reply without PDU decoding'),
		_('Receive and display the reply without decoding it as a PDU.'));
	o.rmempty = false;

	o = s.option(form.ListValue, 'coding', _('PDU decoding scheme'));
	o.value('auto', _('Autodetect'));
	o.value('0', _('7-bit'));
	o.value('2', _('UCS2'));
	o.default = 'auto';

	o = s.option(form.Flag, 'ussd_via_mm', _('Send USSD via ModemManager (mmcli)'),
		_('Use ModemManager instead of sms_tool to send USSD codes, for modems managed by ModemManager that do not handle +CUSD on the AT port properly (e.g. Compal RXM-G1 / Tri Cascade VOS_5G). Requires the modemmanager package. The USSD port setting is not used in this mode.'));
	o.rmempty = false;
}

var GROUPS = {
	receive: function(s) { addReceiveIncoming(s); addNotifications(s); addEmailForwarding(s); },
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

		var m = new form.Map('sms_tool_js');
		var s = m.section(form.TypedSection, 'sms_tool_js', '', null);
		s.anonymous = true;
		s.addremove = false;
		build(s);

		var storeKey = '5gmodem_settings_' + group;
		var open = false;
		try { open = localStorage.getItem(storeKey) === '1'; } catch (e) {}

		return m.render().then(function(mapNode) {
			var attrs = { 'class': 'cbi-section sms-settings-panel' };
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
