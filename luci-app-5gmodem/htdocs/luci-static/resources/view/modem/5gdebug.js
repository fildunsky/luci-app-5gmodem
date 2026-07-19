'use strict';
'require view';
'require view.modem.modemtabs as modemtabs';
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

function updBusy(busy) {
	var bi = document.getElementById('upd-install'), bc = document.getElementById('upd-check');
	if (bi) { bi.disabled = busy; } if (bc) { bc.disabled = busy; }
}

/* Ресурсы приложения, которые браузер кэширует и которые меняются с релизом.
   Держим списком, а не угадыванием: L.resource() даёт правильный префикс. */
var CACHED_RES = [
	'view/modem/5gdetail.js', 'view/modem/5gdebug.js', 'view/modem/5gesim.js',
	'view/modem/netpri.js', 'view/modem/modemtabs.js', 'view/modem/readsms.js',
	'view/modem/sendsms.js', 'view/modem/sendussd.js', 'view/modem/sendat.js',
	'protocol/fibocom.js'
];

/* Принудительно перетянуть наши ресурсы МИМО кэша браузера.
   Очистить кэш из JS нельзя (такого API нет ни в одном браузере), но
   fetch(cache:'reload') обязан сходить в сеть и ПЕРЕЗАПИСАТЬ кэш-запись - это
   ровно то, что делает ручной hard-refresh, только точечно и в один клик.
   Зачем это вообще: uhttpd отдаёт статику без Cache-Control/Expires, а пакет
   до недавнего ставил файлы с датой 1970 -> браузер по эвристике (RFC 9111,
   ~10% возраста) считал их свежими НА ГОДЫ и не перепроверял. postinst теперь
   делает touch, но на устройствах со старым кэшем это надо пробить один раз. */
function refreshResources() {
	if (typeof window.fetch !== 'function') { return Promise.resolve(); }
	return Promise.all(CACHED_RES.map(function(r) {
		return fetch(L.resource(r), { cache: 'reload', credentials: 'same-origin' })
			.catch(function() { /* нет файла/оффлайн - не мешаем остальным */ });
	}));
}

/* Завершение обновления: свежий JS + свежие ACL.
   Логаут тут НЕ ради красоты: наш acl.d перечисляет пути ПОИМЁННО, а rpcd
   выдаёт права сессии в момент ЛОГИНА. Новый скрипт в пакете (так появлялись
   esim.sh/simslot.sh/netpri.sh) для уже залогиненной сессии = молчаливый
   "Access denied", пока не перезайдёшь; rpcd reload сессии не переоформляет.
   Сам по себе логаут кэш браузера НЕ трогает - поэтому сначала refreshResources. */
function finishUpdate() {
	updSet('upd-status', _('Update installed. Refreshing resources…'));
	refreshResources().then(function() {
		updSet('upd-status', _('Update installed. Signing out to apply it…'));
		window.setTimeout(function() {
			var u = L.url('admin/logout');
			if (!u) { window.location.reload(); return; }
			// Токен добавляем на всякий случай: часть сборок LuCI защищает
			// действия от CSRF и без него отдаёт 403, а лишний параметр там,
			// где он не нужен, просто игнорируется.
			if (L.env && L.env.token) { u += '?token=' + encodeURIComponent(L.env.token); }
			window.location.href = u;
		}, 1200);
	});
}

/* Установка идёт в фоне (update.sh install), результат пишется в
   /tmp/5gmodem_update.json. Опрашиваем сам ФАЙЛ, а не update.sh: во время
   установки update.sh подменяется на версию из нового пакета, и её набор
   команд может отличаться - чтение файла от этого не зависит. */
function pollInstall(tries) {
	tries = tries || 0;
	if (tries > 75) {   // ~5 минут
		updSet('upd-status', _('Update is taking too long. Check the connection and try again.'));
		updBusy(false);
		return;
	}
	window.setTimeout(function() {
		L.resolveDefault(fs.read_direct('/tmp/5gmodem_update.json'), '').then(function(txt) {
			txt = String(txt || '').trim();
			if (!txt) { pollInstall(tries + 1); return; }   // файла ещё нет -> идёт установка
			var d = {}; try { d = JSON.parse(txt); } catch (e) { pollInstall(tries + 1); return; }
			if (d.running) { pollInstall(tries + 1); return; }
			if (d.success) {
				updSet('upd-current', d.current || '—');
				updShow('upd-install', false);
				finishUpdate();
			} else {
				updSet('upd-status', d.error || _('Failed to install the update.'));
			}
			updBusy(false);
		});
	}, 4000);
}

function installUpdate() {
	if (!confirm(_('Download and install the latest version now?'))) { return Promise.resolve(); }
	updSet('upd-status', _('Installing the update…'));
	updBusy(true);
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'install' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.started) { pollInstall(0); return; }
		// synchronous error (no package manager etc.)
		updSet('upd-status', d.error || _('Failed to install the update.'));
		updBusy(false);
	}).catch(function(err) {
		updSet('upd-status', _('Failed to install the update.') + ' ' + (err.message || err));
		updBusy(false);
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
			/* НЕ ЖДЁМ ОПРОС МОДЕМА. Раньше здесь стоял '5gmodem.sh json' -
			   полный проход по AT-командам, 8 секунд на живом LT300, и всё это
			   время страница не отрисовывалась вовсе. Информацию о модеме
			   заполняем ПОСЛЕ отрисовки (см. fillModemInfo), как это давно
			   сделано на странице «Сеть». */
			Promise.resolve(''),
			fs.list('/dev').then(function(devs) {
				return devs.filter(function(dev) {
					return dev.name.match(/^ttyUSB/) || dev.name.match(/^cdc-wdm/) || dev.name.match(/^ttyACM/) || dev.name.match(/^mhi_/) || dev.name.match(/^wwan/);
				});
			}),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('sms_tool_js')),
			L.resolveDefault(uci.load('network')),
			// установленные обработчики протоколов (luci-proto-*): по ним строим
			// список доступных типов интерфейса для кнопки создания
			L.resolveDefault(fs.list('/www/luci-static/resources/protocol'), []),
			// карта портов -> модем (vid:pid, модель), чтобы подписать выпадашки
			// портов: какой /dev/ttyUSB* какому модему принадлежит
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listports.sh'), '{}'),
			/* Светодиоды уровня сигнала: есть ли они на этом устройстве.
			   Читаем каталог, а не запускаем скрипт - путь /sys/class/leds
			   разрешён в ACL, и лишнего процесса на открытие страницы нет. */
			L.resolveDefault(fs.list('/sys/class/leds'), [])
		]);
	},

	/* ИНДИКАТОР НА СВЕТОДИОДАХ - ОТДЕЛЬНЫМ БЛОКОМ, ВНЕ form.Map.
	   Внутри формы он требовал бы нажать «Сохранить», а сохранение ЭТОЙ страницы
	   переписывает поля портов (они скрыты при автоопределении) - именно так
	   однажды и пропали метрики. Настройка светодиодов не должна тянуть за собой
	   такой риск, поэтому применяем её сразу, своим вызовом. */
	renderLeds: function(ledsAvail) {
		if (!ledsAvail) { return ''; }

		var cur = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds');
		var metric = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds_metric') || 'rsrp';
		var metrics = [
			[ 'rsrp',   _('RSRP (signal level, default)') ],
			[ 'rsrq',   _('RSRQ (signal quality)') ],
			[ 'sinr',   _('SINR (signal to noise)') ],
			[ 'signal', _('Percent (modem scale)') ]
		];

		var sel = E('select', { 'class': 'cbi-input-select', 'id': 'leds-metric' },
			metrics.map(function(m) {
				return E('option', { 'value': m[0], 'selected': (m[0] === metric) ? '' : null }, m[1]);
			}));
		sel.addEventListener('change', function(ev) {
			fs.exec('/usr/share/5gmodem/signal-leds.sh', [ 'metric', ev.currentTarget.value ]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Signal level indicator')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Show on the case LEDs')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'type': 'checkbox',
						'checked': (cur == '0') ? null : '',
						'change': function(ev) {
							fs.exec('/usr/share/5gmodem/signal-leds.sh',
								[ ev.currentTarget.checked ? 'enable' : 'disable' ]);
						}
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Reads the same snapshot as the pages - the modem is not polled separately. Applies immediately, no Save needed.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('LED metric')),
				E('div', { 'class': 'cbi-value-field' }, [
					sel,
					E('div', { 'class': 'cbi-value-description' },
						_('Thresholds match the colours used on the Network page, so three LEDs and a green value mean the same thing.'))
				])
			])
		]);
	},

	/* Заполнить «Информацию о модеме» из СНИМКА метрик.
	   cached, а не полный опрос: снимок поддерживают страница «Сеть» и 5gtop, и
	   если он свежий, обращения к модему не будет вовсе. Зовём после отрисовки,
	   поэтому страница открывается мгновенно. */
	fillModemInfo: function() {
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '20' ]), {})
			.then(function(r) {
				var j = {};
				try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) { return; }
				var put = function(id, v) {
					var el = document.getElementById(id);
					if (el && v != null && String(v) !== '') { el.textContent = String(v); }
				};
				put('dbg-modem', j.modem);
				put('dbg-firmware', j.firmware);
				put('dbg-cport', j.cport);
				put('dbg-protocol', j.protocol);

				var t = j.mtemp;
				if (t != null && String(t).length > 1 && String(t).indexOf(' ') < 0 && String(t) != '-') {
					put('dbg-mtemp', String(t).replace('&deg;', '°'));
					var row = document.getElementById('dbg-temp-row');
					if (row) { row.style.display = ''; }
				}
			});
	},

	render: function(res) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		var json = {};
		try { json = JSON.parse(res[0] || '{}'); } catch (e) {}
		if (!json || typeof json != 'object') json = {};
		var devs = res[1] || [];
		/* Есть ли на корпусе все три светодиода уровня (Cudy LT300 и совместимые).
		   Индекс 7 - последний элемент списка в load(). При одном индикаторе
		   настройка «уровень тремя лампочками» бессмысленна, поэтому нужны все. */
		var ledsAvail = (function() {
			var names = (res[7] || []).map(function(e) { return e.name; });
			return [ 'white:signal1', 'white:signal2', 'white:signal3' ]
				.every(function(n) { return names.indexOf(n) >= 0; });
		})();

		/* карта порт -> {vidpid, product} для подписи выпадашек портов */
		var portInfo = {};
		try { portInfo = JSON.parse(res[6] || '{}') || {}; } catch (e) {}
		function portLabel(name) {
			var full = '/dev/' + name;
			var i = portInfo[full];
			if (i && i.product) { return full + ' — ' + i.product + (i.vidpid ? ' (' + i.vidpid + ')' : ''); }
			if (i && i.vidpid && i.vidpid != ':') { return full + ' — ' + i.vidpid; }
			return full;
		}

		/* Список установленных на роутере обработчиков протоколов (имена файлов
		   protocol/<name>.js). По нему динамически строим выбор типа интерфейса,
		   чтобы показывать только реально доступные протоколы (у кого-то стоит
		   luci-proto-xmm/atc для Fibocom, у кого-то нет). */
		var protoAvail = {};
		(res[5] || []).forEach(function(f) {
			var m = (f.name || '').match(/^([a-z0-9]+)\.js$/);
			if (m) { protoAvail[m[1]] = true; }
		});

		/* ---------------- Настройки модема (бывшая вкладка Modem Settings) --- */
		var m, s, o;
		m = new form.Map('5gmodem', '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		o = s.option(form.Flag, 'auto_port', _('Auto-detect port and interface'),
			_('Automatically find the modem AT port and its network interface (via ModemManager when available). Turn this off to select them manually below.'));
		o.default = '1';
		o.rmempty = false;

		/* Раньше здесь был widgets.NetworkSelect. Он через
		   network.getNetworks() тянет обработчики протоколов всех
		   интерфейсов (L.require('protocol.<name>')). Если в netifd есть
		   proto 3g/wwan, а их luci-обработчик не установлен, require даёт
		   404, промис отклоняется и ВСЯ страница настроек модема перестаёт
		   открываться. Заменили на простой список имён интерфейсов из uci -
		   он самодостаточен и ничего не подгружает. */
		o = s.option(form.ListValue, 'network', _('Interface'),
			_('Network interface for Internet access.'));
		o.depends('auto_port', '0');
		o.rmempty = true;
		/* НЕ УДАЛЯТЬ ПРИ СОХРАНЕНИИ - та же ловушка, что у device и at_port.
		   Поле скрыто, пока включено автоопределение, а LuCI выбрасывает из
		   конфига опции с невыполненными зависимостями. Здесь цена выше: в
		   network лежит ИМЯ ИНТЕРФЕЙСА, которым управляет приложение, и без него
		   теряется связь модема с его подключением (проверено на живом роутере -
		   после сохранения страницы ключ исчезал вместе с device). */
		o.remove = function() { return Promise.resolve(); };
		(uci.sections('network', 'interface') || []).forEach(function(iface) {
			var nm = iface['.name'];
			if (nm && nm != 'loopback') { o.value(nm, nm + (iface.proto ? ' (' + iface.proto + ')' : '')); }
		});

		o = s.option(form.Value, 'device',
			_('Port for modem communication'),
			_("Port used to read modem/connection info. <br /> \
				<br />Traditional modem: one of the available ttyUSBX ports.<br /> \
				<br />HiLink modem: enter the IP address 192.168.X.X under which the modem is available."));
		devs.sort((a, b) => a.name > b.name);
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* НЕ УДАЛЯТЬ ПРИ СОХРАНЕНИИ. Поле скрыто, пока включено
		   автоопределение, а LuCI удаляет из конфига опции, чьи зависимости не
		   выполнены. Живой случай: сохранение этой страницы с включённым
		   автоопределением стёрло device и переписало at_port на первый порт из
		   списка (ttyUSB0, он не отвечает на AT) - метрики пропали полностью.
		   Значение проставляет resolve по факту опроса, и терять его нельзя. */
		o.remove = function() { return Promise.resolve(); };

		o = s.option(form.Value, 'at_port',
			_('Port for AT / SMS / USSD'),
			_('AT command port used for SMS, USSD and AT commands. On most modems it is the same as the modem communication port.'));
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* То же, что у device: при автоопределении поле скрыто, и сохранение
		   формы не должно его трогать. */
		o.remove = function() { return Promise.resolve(); };
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

		/* Выбор протокола + кнопка создания интерфейса модема. Список типов
		   строится по установленным на роутере обработчикам протоколов, так
		   что для Fibocom с luci-proto-xmm/atc появятся XMM/ATC и т.д. */
		o = s.option(form.ListValue, 'iface_proto', _('Interface protocol'),
			_('Protocol for the "Create modem interface" button. "Auto" picks it from the modem driver (recommended). Only the protocols whose handler is installed on the router are shown. Any non-ModemManager protocol disables ModemManager (they cannot share the modem).'));
		o.value('auto', _('Auto (detect)'));
		/* человекочитаемые подписи известных модемных протоколов */
		var protoLabels = {
			'fibocom': 'Fibocom (AT-dial, FM350)',
			'mbim': 'MBIM (umbim)',
			'qmi': 'QMI (uqmi)',
			'ncm': 'NCM',
			'xmm': 'XMM (Fibocom / Intel)',
			'atc': 'AT (atc)',
			'wwan': 'WWAN (auto)',
			'3g': '3G / PPP',
			'modemmanager': 'ModemManager'
		};
		/* Порядок вывода; показываем только те, чей обработчик установлен.
		   'fibocom' - наш прото (шипим и luci-proto, и netifd-обработчик), им
		   поднимается FM350: у него нет cdc-wdm, поэтому mbim/qmi/ModemManager с
		   ним не работают. В protoAvail он был всегда, но отсутствовал в ЭТОМ
		   списке и в protoLabels - поэтому в выпадашку и не попадал. */
		[ 'fibocom', 'mbim', 'qmi', 'ncm', 'xmm', 'atc', 'wwan', '3g', 'modemmanager' ].forEach(function(p) {
			if (protoAvail[p]) { o.value(p, protoLabels[p]); }
		});
		/* если вдруг ни одного модемного обработчика не нашли - оставим базовые,
		   чтобы список не был пустым */
		if (!protoAvail['mbim'] && !protoAvail['modemmanager']) {
			o.value('mbim', protoLabels['mbim']);
			o.value('modemmanager', protoLabels['modemmanager']);
		}
		o.default = 'auto';
		o.rmempty = false;
		/* Выбрали ModemManager - сразу снимаем «Скрыть от ModemManager»: держать
		   обе настройки одновременно бессмысленно (инхибиция прячет модем от MM,
		   а протокол требует, чтобы MM им управлял - интерфейс останется без IP).
		   mkiface.sh выставляет mm_exclude=0 и сам, но уже ПОСЛЕ применения, и
		   галка до перезагрузки страницы показывала неправду. Обратного действия
		   НЕ делаем: возврат на kernel-прото не обязан включать инхибицию молча -
		   у пользователя может быть причина оставить модем видимым для MM. */
		o.onchange = function(ev, section_id, value) {
			if (value !== 'modemmanager') { return; }
			var f = this.map.lookupOption('_mm_exclude', section_id);
			var el = f && f[0] && f[0].getUIElement(section_id);
			if (el && el.getValue() === '1') {
				el.setValue('0');
				ui.addNotification(null, E('p',
					_('“Hide from ModemManager” has been turned off: the ModemManager protocol needs MM to manage this modem.')), 'info');
			}
		};

		/* Имя интерфейса модема и признак его существования - для подписи
		   кнопки (создать/пересоздать) и для встроенной вьюхи ниже. */
		var mIfName = uci.get('5gmodem', '@5gmodem[0]', 'network') || 'modem';
		var mIfExists = !!uci.get('network', mIfName);

		/* Секция АКТИВНОГО модема (m_<usb-путь> с заменой не-буквенно-цифровых на
		   '_') - в ней живут пер-модемные настройки, напр. mm_exclude. */
		var mSec = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			return p ? ('m_' + String(p).replace(/[^A-Za-z0-9]/g, '_')) : '';
		})();

		/* Чужой интерфейс, прилипший к этому модему через переиспользованную
		   device-ноду (нашёл modemswitch.sh resolve, см. orphan_iface_for).
		   Показываем предупреждение: сам конфиг мы не правим - интерфейс мог быть
		   настроен вручную, решение за пользователем. */
		var mForeignIf = mSec ? (uci.get('5gmodem', mSec, 'foreign_iface') || '') : '';
		if (mForeignIf) {
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, _('Interface “%s” was created for a different modem.').format(mForeignIf)), ' ',
				_('It is bound to this modem only because the kernel reused the device node, so its settings (APN in particular) may belong to the previous modem and SIM. Create the interface anew below - the APN is filled from the operator detected right now.')
			]), 'warning');
		}

		/* ПЕРЕСТАВИЛИ ОДИНАКОВЫЕ МОДЕМЫ МЕСТАМИ.
		   Замену обычно ловит сравнение vid:pid на USB-пути, но два одинаковых
		   модуля так не различить. Опрос сверяет IMEI (он уникален) и ставит эту
		   метку. Сам он ничего не удаляет намеренно: тихо снести чужой APN и
		   интерфейс - именно тот неочевидный сюрприз, которого быть не должно.
		   Поэтому решение за пользователем: показываем, что произошло, и чем это
		   грозит. Метку снимаем сразу, чтобы предупреждение не повторялось. */
		var mImeiChanged = mSec ? (uci.get('5gmodem', mSec, 'imei_changed') || '') : '';
		if (mImeiChanged === '1') {
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, _('A different modem is now in this USB port.')), ' ',
				_('Its IMEI does not match the one seen here before - the modems were probably swapped. The settings of this slot (the interface and its APN in particular) belong to the previous modem and its SIM. Check them below and create the interface anew if needed.')
			]), 'warning');
			fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ackswap', mSec ]);
		}

		/* Оператор -> APN российских операторов (и MVNO). Пусто = неизвестен. */
		function apnForOperator(name) {
			var n = (name || '').toLowerCase();
			if (n.indexOf('t-mobile') >= 0 || n.indexOf('т-мобайл') >= 0 || n.indexOf('t-mob') >= 0) { return 'tt'; }
			if (n.indexOf('sber') >= 0 || n.indexOf('сбер') >= 0) { return 'sberbank'; }
			if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'internet.beeline.ru'; }
			if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'internet.mts.ru'; }
			if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'internet'; }
			if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2') { return 'internet.tele2.ru'; }
			if (n.indexOf('yota') >= 0) { return 'internet.yota'; }
			return '';
		}

		/* Поле APN над кнопкой создания. Если интерфейс уже есть - берём его
		   текущий APN; иначе автоподстановка по оператору (можно исправить,
		   пусто = провайдерский по умолчанию). Чистое UI-поле, в uci не пишется. */
		o = s.option(form.Value, '_apn', _('APN'),
			_('APN for the modem interface. Auto-filled from the detected operator; you can change it. Leave empty for the provider default.'));
		o.placeholder = 'internet';
		o.rmempty = true;
		o.write = function() {};
		o.remove = function() {};
		o.load = function(section_id) {
			/* APN определяем по ОПЕРАТОРУ при каждом открытии страницы, СВЕЖИМ
			   опросом. Раньше здесь было два слоя устаревания, и после смены SIM
			   поле показывало APN прежнего оператора:
			     1) если APN уже прописан в интерфейсе - оператора не спрашивали
			        вовсе и возвращали старое значение;
			     2) netpri.sh op отдавал operator_cached - файл в /tmp, живущий
			        30 минут.
			   Теперь: 'fresh' сбрасывает кэш и опрашивает модем заново. */
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/netpri.sh',
					[ 'op', mIfName, 'fresh' ]), '')
				.then(function(op) {
					op = (op || '').trim();
					if (!op) {
						/* Оператора прочитать НЕ УДАЛОСЬ (порт занят, модем ещё
						   поднимается) - это НЕ то же самое, что «оператора нет в
						   базе». Показываем текущий APN интерфейса: предложить
						   стереть рабочий APN из-за неудачной пробы нельзя. */
						return uci.get('network', mIfName, 'apn') || '';
					}
					/* Оператор известен: его APN, либо пусто - если в базе его нет
					   (тогда кнопка применит «без APN», см. sentinel '-' ниже). */
					return apnForOperator(op);
				});
		};

		/* Тип PDP для создаваемого интерфейса. Чистое UI-поле (в uci не пишется):
		   применяет его mkiface.sh 4-м аргументом. По умолчанию IPv4 - dual-stack
		   ломает дозвон на части модемов (Quectel EC21 проверен живьём: поднялся
		   только после смены на IPv4), а IPv6 у сотовых операторов РФ чаще нет,
		   чем есть. Существующий интерфейс сохраняет свой тип, пока его не
		   пересоздадут этой кнопкой. */
		/* Прятать ЭТОТ модем от ModemManager (mm-inhibit.sh держит инхибицию).
		   Пишем в секцию модема, а не в общую: у каждого модема свой режим.
		   Значение читается/пишется вручную - form.Map тут привязан к @5gmodem[0]. */
		o = s.option(form.Flag, '_mm_exclude', _('Hide from ModemManager'),
			_('ModemManager and a kernel protocol (QMI/MBIM) cannot share one modem: MM grabs the control channel and the interface gets no IP. Enabled by default for such protocols. Turn it off to hand the modem to ModemManager (its band/mode control is richer on some modems) - then use the ModemManager protocol for it.'));
		o.default = '1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			if (!mSec) { return Promise.resolve(); }
			return fs.exec('/usr/share/5gmodem/mm-inhibit.sh',
				[ 'set-exclude', mSec, String(value) === '1' ? '1' : '0' ]);
		};
		o.remove = function() { return Promise.resolve(); };
		o.load = function(section_id) {
			if (!mSec) { return '1'; }
			var v = uci.get('5gmodem', mSec, 'mm_exclude');
			if (v === '0' || v === '1') { return v; }
			// умолчание совпадает с логикой mm-inhibit.sh: прячем kernel-прото
			var p = String(uci.get('network', mIfName, 'proto') || '');
			return (p && p !== 'modemmanager') ? '1' : '0';
		};

		o = s.option(form.ListValue, '_pdptype', _('IP type'),
			_('IP type for the modem interface. IPv4/IPv6 is the safe default - on an IPv4-only network the modem just negotiates IPv4, while some networks (e.g. Tele2 on the FM350) will not activate the data context at all under IPv4-only. Switch to "IPv4 only" only if a modem has trouble with dual-stack.'));
		o.value('ipv4v6', _('IPv4 and IPv6 (recommended)'));
		o.value('ipv4', _('IPv4 only'));
		o.write = function() {};
		o.remove = function() {};
		o.load = function(section_id) {
			// показываем то, что стоит у существующего интерфейса (имя опции
			// зависит от прото: modemmanager - iptype, остальные - pdptype/pdp)
			var v = uci.get('network', mIfName, 'pdptype')
				|| uci.get('network', mIfName, 'iptype')
				|| uci.get('network', mIfName, 'pdp') || '';
			return (String(v).toLowerCase() === 'ipv4') ? 'ipv4' : 'ipv4v6';
		};

		o = s.option(form.Button, '_mkiface');
		o.title = _('Modem interface');
		o.description = _('Create (or switch) the modem network interface using the protocol chosen above. Switching to MBIM disables ModemManager; switching to ModemManager enables it (they cannot share the modem).');
		o.inputtitle = mIfExists ? _('Recreate modem interface') : _('Create modem interface');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var sid = null;
			var ss = uci.sections('5gmodem', '5gmodem');
			if (ss && ss[0]) { sid = ss[0]['.name']; }
			var proto = 'auto';
			try {
				var opt = this.map.lookupOption('iface_proto', sid);
				if (opt && opt[0]) { var el = opt[0].getUIElement(sid); if (el) { proto = el.getValue() || 'auto'; } }
			} catch (e) {}
			var apn = '';
			try {
				var aopt = this.map.lookupOption('_apn', sid);
				if (aopt && aopt[0]) { var ael = aopt[0].getUIElement(sid); if (ael) { apn = (ael.getValue() || '').trim(); } }
			} catch (e) {}
			// Пустое поле = ЯВНО без APN (оператор опознан, но его нет в базе, либо
			// пользователь стёр сам). Передаём sentinel '-', иначе mkiface.sh не
			// отличит это от «аргумент не передан» и молча сохранит ПРЕЖНИЙ APN -
			// стереть его было бы невозможно.
			var apnArg = apn || '-';
			var pdp = 'ipv4v6';
			try {
				var popt = this.map.lookupOption('_pdptype', sid);
				if (popt && popt[0]) { var pel = popt[0].getUIElement(sid); if (pel) { pdp = pel.getValue() || 'ipv4v6'; } }
			} catch (e) {}
			// Выбор протокола запоминает сам mkiface.sh (uci commit на
			// роутере), поэтому здесь НЕ вызываем uci.save() - иначе LuCI
			// поднимал баннер «не сохранено» и требовал нажать «Применить».
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/mkiface.sh', [ 'modem', proto, apnArg, pdp ]).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.result == 'created') {
					ui.addNotification(null, E('p', _('Interface "%s" created (%s), bringing it up…').format(out.iface, out.proto)), 'info');
					// The Modem Information block is rendered once and not polled, so
					// its protocol badge would keep showing the OLD protocol (e.g. mbim)
					// until a manual page reload. Update it to the new protocol now.
					var pb = document.querySelector('.tg-proto-badge');
					if (pb && out.proto) { pb.textContent = out.proto; }
				} else {
					ui.addNotification(null, E('p', _('No modem found to create an interface for.')), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to create the modem interface') + ': ' + (err.message || err)), 'error');
			});
		};

		/* Забыть модемы, которых больше нет на шине.
		   ЯВНОЕ действие: автоматически по отключению так делать нельзя - модем
		   штатно пропадает на минуту при AT+CFUN=1,1 (в т.ч. по нашей же команде
		   после добавления eSIM-профиля), и настройки терялись бы на ровном месте.
		   Подмену модема на том же USB-порту приложение чистит само (см.
		   swap_cleanup в modemswitch.sh) - эта кнопка для случая «модем убрали
		   насовсем». Сама привязка модема и удаляется; интерфейс в network/firewall
		   остаётся: он мог быть настроен вручную. */
		o = s.option(form.Button, '_forget');
		o.title = _('Disconnected modems');
		o.description = _('Remove settings remembered for modems that are no longer connected (AT port, interface, SIM slot types). A stale entry can hide a working modem from Internet priority if both claim the same interface name.');
		o.inputtitle = _('Forget disconnected modems');
		o.inputstyle = 'remove';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Removing…')));
			return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'forget' ]).then(function(res) {
				ui.hideModal();
				var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				var n = parseInt(d.forgotten, 10) || 0;
				ui.addNotification(null, E('p', n
					? _('Forgotten modems: %d').format(n)
					: _('Nothing to forget: every remembered modem is connected.')), 'info');
				if (n) { window.setTimeout(function() { window.location.reload(); }, 1200); }
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to forget disconnected modems') + ': ' + (err.message || err)), 'error');
			});
		};

		/* Отчёт для разработчиков. Сбор идёт в фоне (collect.sh start) и занимает
		   от секунд до пары минут - синхронный вызов не пережил бы 30-секундный
		   таймаут rpcd. Поэтому опрашиваем collect.sh status и показываем шаг,
		   а готовый файл отдаём браузеру как обычное скачивание (Blob). */
		o = s.option(form.Button, '_collect');
		o.title = _('Diagnostic report');
		o.description = _('Collects settings, modem ports, AT command output, ModemManager and eSIM state, and system logs into one text file and downloads it. Attach it to a bug report. The file contains modem and SIM identifiers (IMEI, IMSI, ICCID, EID) and the operator name; it does not contain passwords or Wi-Fi keys.');
		o.inputtitle = _('Collect logs');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var msg = E('p', { 'class': 'spinning' }, _('Collecting logs…'));
			ui.showModal(_('Diagnostic report'), [ msg ]);

			var poll = function(tries) {
				return fs.exec('/usr/share/5gmodem/collect.sh', [ 'status' ]).then(function(res) {
					var st = {}; try { st = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
					if (st.state === 'running') {
						// сбор не бесконечен: 180 попыток по 2 c = 6 минут потолок
						if (tries > 180) { throw new Error(_('Timed out')); }
						msg.textContent = _('Collecting logs…') + ' ' + (st.progress || '');
						return new Promise(function(resolve) {
							window.setTimeout(function() { resolve(poll(tries + 1)); }, 2000);
						});
					}
					if (st.state !== 'done') { throw new Error(_('Collecting logs failed')); }
					return fs.read_direct('/tmp/5gmodem-diag.txt', 'blob');
				});
			};

			return fs.exec('/usr/share/5gmodem/collect.sh', [ 'start' ]).then(function() {
				return poll(0);
			}).then(function(blob) {
				var d = new Date();
				var stamp = d.getFullYear()
					+ ('0' + (d.getMonth() + 1)).slice(-2)
					+ ('0' + d.getDate()).slice(-2)
					+ '-' + ('0' + d.getHours()).slice(-2)
					+ ('0' + d.getMinutes()).slice(-2);
				var url = window.URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': '5gmodem-diag-' + stamp + '.txt' });
				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);
				window.setTimeout(function() { window.URL.revokeObjectURL(url); }, 5000);
				ui.hideModal();
				ui.addNotification(null, E('p', _('The report has been downloaded. Attach it to your bug report.')), 'info');
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Collecting logs failed') + ': ' + (err.message || err)), 'error');
			});
		};

		/* --- Тест скорости - ОТДЕЛЬНОЙ секцией (стандартный разделитель-заголовок),
		   ниже «Забыть модемы»/«Собрать логи» и выше блока «Обновление». Секция
		   маппится на ту же анонимную секцию 5gmodem, что и выше, - LuCI рисует её
		   отдельной плашкой с заголовком. Кнопка теста - в блоке «Приоритет
		   интернета» на странице «Сеть»; тут только настройки эндпойнтов. */
		var st = m.section(form.TypedSection, '5gmodem', _('Speed test'),
			_('Settings for the speed-test button in the "Internet priority" block on the Network page. The test runs from the router over the active uplink.'));
		st.anonymous = true;

		o = st.option(form.Value, 'speedtest_url', _('Download source'),
			_('Large-file URL for the download test. Pick a preset or enter your own. The default uses ~16 MB per run.'));
		o.value('http://mirror.yandex.ru/debian/ls-lR.gz', 'Yandex (mirror.yandex.ru)');
		o.value('https://speed.cloudflare.com/__down?bytes=100000000', 'Cloudflare');
		o.placeholder = 'http://mirror.yandex.ru/debian/ls-lR.gz';
		o.rmempty = true;

		o = st.option(form.Value, 'speedtest_up_url', _('Upload endpoint'),
			_('Endpoint that accepts a POST body, for the upload test. The default (Yandex) is the one reachable over Russian cellular both directly and via a proxy - it answers 404/403 but reads the body, so the speed is still measured. Cloudflare/Rostelecom work on unrestricted networks.'));
		o.value('https://yandex.ru/internet/api/v1/upload', 'Yandex (RU, works over cellular)');
		o.value('https://speedtest.rt.ru/backend/empty.php', 'Rostelecom (LibreSpeed)');
		o.value('https://speed.cloudflare.com/__up', 'Cloudflare');
		o.value('https://librespeed.org/backend/empty.php', 'LibreSpeed (public demo)');
		o.rmempty = true;

		o = st.option(form.Value, 'speedtest_ip_url', _('Public IP service'),
			_('Service that returns your public IP. The default (ip-api.com) also returns the country, shown as a flag next to the IP. Pick a preset or enter your own; if it fails, a backup service is queried, and only then the local uplink address is shown (without a flag).'));
		o.value('http://ip-api.com/line/?fields=countryCode,query', 'ip-api.com (IP + country flag)');
		o.value('http://api.ipify.org', 'ipify (api.ipify.org)');
		o.value('https://ip.wtf', 'ip.wtf');
		o.value('http://ifconfig.me/ip', 'ifconfig.me');
		o.value('https://icanhazip.com', 'icanhazip.com');
		o.value('https://2ip.ru', '2ip.ru');
		o.value('https://whoer.net', 'whoer.net');
		o.rmempty = true;

		o = st.option(form.Value, 'speedtest_cc_url', _('Country lookup'),
			_('Used only when the service above returns an IP but no country: the flag is then resolved by a second request. Use {ip} as the address placeholder.'));
		o.value('http://ip-api.com/line/{ip}?fields=countryCode', 'ip-api.com');
		o.value('https://ipapi.co/{ip}/country/', 'ipapi.co');
		o.placeholder = 'http://ip-api.com/line/{ip}?fields=countryCode';
		o.rmempty = true;

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
		/* Значения приходят позже - ставим прочерки и метим ячейки, чтобы было
		   куда их положить. Строку температуры держим скрытой: у части модемов
		   её нет вовсе, и пустая строка в таблице только мешает. */
		var infoCell = function(id, inner) {
			return E('span', { 'id': id }, inner !== undefined ? inner : '-');
		};
		var infoRows = [
			inforow(_('Modem type'), infoCell('dbg-modem')),
			inforow(_('Revision / Firmware'), infoCell('dbg-firmware')),
			inforow(_('IP adress / Communication Port'), infoCell('dbg-cport')),
			inforow(_('Protocol'), E('span', { 'class': 'tg-proto-badge' }, infoCell('dbg-protocol'))),
		];
		var tempRow = inforow(_('Chip Temperature'), infoCell('dbg-mtemp'));
		tempRow.style.display = 'none';
		tempRow.id = 'dbg-temp-row';
		infoRows.push(tempRow);

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
.tg-proto-badge {
  display: inline-block;
  padding: 1px 9px;
  border: 1px solid rgba(127, 127, 127, 0.4);
  border-radius: 6px;
  background: rgba(127, 127, 127, 0.12);
  font-weight: 600;
  font-size: 0.9em;
  line-height: 1.6;
  text-transform: uppercase;
  letter-spacing: 0.02em;
}
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
		var ledsBlock = this.renderLeds(ledsAvail);
		var self = this;
		return Promise.resolve(m.render()).then(function(formNode) {
			return E('div', {}, [
				modemInfo,
				E('div', { 'class': 'tg-modem-form' }, [ formNode ]),
				/* Блок светодиодов ПОСЛЕ формы, но вне её: он применяется сразу
				   и не должен подписываться под Save/Apply формы. */
				ledsBlock,
				updateBlock,
				diag
			]);
		}).then(function(node) {
			/* Значения подставляем ПОСЛЕ того, как узел готов: до вставки в
			   документ getElementById их не найдёт. Промис не возвращаем -
			   страница не должна ждать эти данные, ради чего всё и делалось. */
			window.setTimeout(function() { self.fillModemInfo(); }, 0);
			return node;
		});
	}
});
