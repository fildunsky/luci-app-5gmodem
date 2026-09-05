'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.healthform as healthform';
'require view.modem5g.extip as extip';
'require fs';
'require ui';
'require uci';
'require rpc';
'require form';
'require dom';

/* КОММИТ ЧЕРЕЗ СЕССИЮ БРАУЗЕРА, А НЕ ВНЕШНИМ СКРИПТОМ.
   Отложенные правки LuCI живут В СЕССИИ rpcd, а НЕ в общем /tmp/.uci - там
   лежит пустой файл-пустышка, из-за которого мы годами думали обратное.
   Проверено на стенде 25.08.2026: после `ubus uci set` с сессией обычный
   `uci changes` пуст, `uci commit` не пишет ничего, а дельта сессии жива.
   Отсюда и жалоба владельца: настройки «сохранялись», индикатор непринятых
   изменений висел, а после перезагрузки роутера сессия умирала вместе с
   правкой - и возвращался прежний источник спидтеста.
   Коммитим тем же путём, которым правка и создавалась. Это НЕ uci.apply():
   у того есть откат по таймауту подтверждения, и он сам по себе умеет
   вернуть настройки назад. */
var uciCommit = rpc.declare({
	object: 'uci',
	method: 'commit',
	params: [ 'config' ],
	expect: { '': {} }
});

/* Коммитим ВСЕ конфиги, у которых есть непринятые правки, а не только
   «5gmodem»: страница правит и соседние (сети, фаервол - через вложенные
   формы), и оставить их висеть значило бы воспроизвести ту же беду в
   другом файле. Список берём у сервера - он знает про сессию. */
function commitPending() {
	return uci.changes().then(function(ch) {
		var names = [];
		for (var k in ch) { if ((ch[k] || []).length) { names.push(k); } }
		if (!names.length) { return null; }
		return Promise.all(names.map(function(n) {
			return L.resolveDefault(uciCommit(n), null);
		}));
	}).catch(function() { return null; });
}

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum
	Licensed to the GNU General Public License v3.0.

	Вкладка «Настройки»: обновление приложения и настройки теста скорости.
	Вынесены со страницы «Модем», чтобы там осталось только про сам модем.
*/

/* --- Проверка/установка обновления с GitHub (app + перевод) --- */
function updSet(id, txt) { var e = document.getElementById(id); if (e) { e.textContent = txt; } }
/* Статус с ЖИРНЫМ номером версии - тем же <strong>, что у «Текущая версия». */
function updSetVer(id, label, ver) {
	var e = document.getElementById(id);
	if (!e) { return; }
	e.textContent = '';
	e.appendChild(document.createTextNode(label + ': '));
	e.appendChild(E('strong', {}, ver));
}
function updShow(id, show) { var e = document.getElementById(id); if (e) { e.style.display = show ? '' : 'none'; } }
/* Локализация кодов ошибок обновления. Спец-случай asset_pending: тег релиза уже
   выпущен, а .apk ещё собирается на сервере (CI) - показываем понятную подсказку
   вместо технической «Release asset … not found». */
function updErrText(e, fb) {
	if (e === 'asset_pending')
		return _('The update is still building on the server. Please wait about 15-20 minutes and try again.');
	return e || fb;
}

function checkUpdate() {
	updSet('upd-status', _('Checking the latest release…'));
	updShow('upd-install', false);
	var b = document.getElementById('upd-check'); if (b) { b.disabled = true; }
	return fs.exec('/usr/share/5gmodem/update.sh', [ 'check' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		updSet('upd-current', d.current || '—');
		/* Версию показываем БЕЗ префикса тега: человек сравнивает её с текущей,
		   а «v» - служебная часть имени тега на GitHub. */
		var latest = String(d.latest || '').replace(/^v/i, '');
		if (d.release_url) { var a = document.getElementById('upd-release'); if (a) { a.href = d.release_url; a.style.display = ''; } }
		if (!d.success) {
			updSet('upd-status', updErrText(d.error, _('Could not check for updates')));
		} else if (d.update_available == 1 || d.update_available === true) {
			updShow('upd-install', true);
			updSetVer('upd-status', _('Update available'), latest || '—');
		} else {
			updSet('upd-status', _('You have the latest version'));
		}
	}).catch(function(err) {
		updSet('upd-status', _('Could not check for updates') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('upd-check'); if (b) { b.disabled = false; }
	});
}

function updBusy(busy) {
	var bi = document.getElementById('upd-install'), bc = document.getElementById('upd-check');
	if (bi) { bi.disabled = busy; } if (bc) { bc.disabled = busy; }
}

/* Ресурсы приложения, которые браузер кэширует и которые меняются с релизом. */
var CACHED_RES = [
	'view/modem5g/5gdetail.js', 'view/modem5g/5gdebug.js', 'view/modem5g/5gesim.js',
	'view/modem5g/5gsettings.js', 'view/modem5g/netpri.js', 'view/modem5g/modemtabs.js',
	'view/modem5g/extip.js', 'view/modem5g/mutil.js',
	'view/modem5g/readsms.js', 'view/modem5g/sendsms.js', 'view/modem5g/sendussd.js',
	'view/modem5g/sendat.js', 'protocol/fibocom.js'
];

/* Принудительно перетянуть наши ресурсы МИМО кэша браузера (fetch cache:reload). */
function refreshResources() {
	if (typeof window.fetch !== 'function') { return Promise.resolve(); }
	return Promise.all(CACHED_RES.map(function(r) {
		return fetch(L.resource(r), { cache: 'reload', credentials: 'same-origin' })
			.catch(function() { /* нет файла/оффлайн - не мешаем остальным */ });
	}));
}

/* Завершение обновления: свежий JS + свежие ACL (logout переоформляет права). */
function finishUpdate() {
	updSet('upd-status', _('Update installed. Refreshing resources…'));
	refreshResources().then(function() {
		updSet('upd-status', _('Update installed. Signing out to apply it…'));
		window.setTimeout(function() {
			var u = L.url('admin/logout');
			if (!u) { window.location.reload(); return; }
			if (L.env && L.env.token) { u += '?token=' + encodeURIComponent(L.env.token); }
			window.location.href = u;
		}, 1200);
	});
}

/* Установка идёт в фоне; опрашиваем ФАЙЛ результата, а не update.sh (он подменится). */
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
			if (!txt) { pollInstall(tries + 1); return; }
			var d = {}; try { d = JSON.parse(txt); } catch (e) { pollInstall(tries + 1); return; }
			if (d.running) { pollInstall(tries + 1); return; }
			if (d.success) {
				updSet('upd-current', d.current || '—');
				updShow('upd-install', false);
				finishUpdate();
			} else {
				updSet('upd-status', updErrText(d.error, _('Failed to install the update')));
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
		updSet('upd-status', updErrText(d.error, _('Failed to install the update')));
		updBusy(false);
	}).catch(function(err) {
		updSet('upd-status', _('Failed to install the update') + ' ' + (err.message || err));
		updBusy(false);
	});
}

/* --- База APN (providers.tsv): версия, проверка и обновление из апстрима ---
   Обновляется ОТДЕЛЬНО от приложения и вручную: данные живут своей жизнью
   (новые MVNO появляются между релизами), а автопроверка по расписанию тут
   не нужна - файл лежит в пакете, и к релизу мы подтягиваем свежий сами. */
var APNBIN = '/usr/share/5gmodem/apn-update.sh';

function apnVersion() {
	return L.resolveDefault(fs.exec_direct(APNBIN, [ 'version' ]), '{}').then(function(out) {
		var d = {}; try { d = JSON.parse(out || '{}'); } catch (e) {}
		updSet('apn-current', d.version ? (d.version + ' · ' + (d.count || 0) + ' ' + _('operators')) : '—');
	});
}

function apnCheck() {
	updSet('apn-status', _('Checking the APN database…'));
	updShow('apn-update', false);
	var b = document.getElementById('apn-check'); if (b) { b.disabled = true; }
	return fs.exec(APNBIN, [ 'check' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (!d.ok) {
			updSet('apn-status', _('Could not check the APN database') + (d.error ? (': ' + d.error) : ''));
			return;
		}
		if (String(d.update_available) === '1') {
			updShow('apn-update', true);
			updSetVer('apn-status', _('Update available'),
				(d.available_version || '—') + ' · ' + (d.available || 0) + ' ' + _('operators'));
		} else {
			updSet('apn-status', _('The APN database is up to date'));
		}
	}).catch(function(err) {
		updSet('apn-status', _('Could not check the APN database') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('apn-check'); if (b) { b.disabled = false; }
	});
}

function apnUpdate() {
	updSet('apn-status', _('Updating the APN database…'));
	var b = document.getElementById('apn-update'); if (b) { b.disabled = true; }
	return fs.exec(APNBIN, [ 'update' ]).then(function(res) {
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.ok) {
			updSet('apn-current', (d.version || '—') + ' · ' + (d.count || 0) + ' ' + _('operators'));
			updShow('apn-update', false);
			updSet('apn-status', _('The APN database has been updated'));
		} else {
			updSet('apn-status', _('Failed to update the APN database') + (d.error ? (': ' + d.error) : ''));
		}
	}).catch(function(err) {
		updSet('apn-status', _('Failed to update the APN database') + ' ' + (err.message || err));
	}).finally(function() {
		var b = document.getElementById('apn-update'); if (b) { b.disabled = false; }
	});
}

/* ВЫПАДАЮЩИЕ СПИСКИ - ОДНИМ ВИДОМ НА ВСЮ ПРОГРАММУ (решение владельца 03.09.2026).
   form.ListValue рисует нативный <select>, а form.Value со списком подсказок -
   ui.Dropdown; выглядят они по-разному (отступ текста, стрелка), и в программе
   встречались оба. Берём везде дропдаун: RichListValue - штатный класс LuCI,
   отличающийся от ListValue ровно виджетом. На старых сборках LuCI его может не
   быть - тогда молча падаем обратно на ListValue, чтобы страница не рухнула. */
var ListDropdown = form.RichListValue || form.ListValue;
var EXTIPBIN = '/usr/share/5gmodem/extip.sh';

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/buttons.sh', [ 'services' ]), '{}'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/notmodem.sh', [ 'scan' ]), '[]')
		]);
	},

	render: function(res) {
		modemtabs.attach();
		var services = [];
		try { services = (JSON.parse((res && res[1]) || '{}').services) || []; } catch (e) {}
		/* Устройства на шине для чёрного списка - см. notmodem.sh scan. */
		var usbDevs = [];
		try { usbDevs = JSON.parse((res && res[2]) || '[]') || []; } catch (e) {}

		/* Блок обновления (без Save/Apply - действие немедленное). */
		var updateBlock = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Application update') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('5G modem')),
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
					/* Одна КОЛОНКА внутри описания: тема кладёт описание флексом в
					   строку (значок-вопросик слева), поэтому наши строки живут в
					   общем столбике справа от значка, а не под ним. */
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [
							E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'upd-current' }, [ '—' ]) ]),
							E('div', { 'id': 'upd-status', 'style': 'margin-top:4px' }, []),
						]),
					]),
				]),
			]),
			/* База APN - своя строка в том же блоке: обновляется независимо от
			   приложения, и путать её с версией пакета нельзя. */
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('APN database')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('div', { 'style': 'display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:8px' }, [
						E('button', {
							'class': 'cbi-button cbi-button-action',
							'id': 'apn-check',
							'click': ui.createHandlerFn(this, function() { return apnCheck(); })
						}, [ _('Check the APN database') ]),
						E('button', {
							'class': 'cbi-button cbi-button-positive',
							'id': 'apn-update',
							'style': 'display:none',
							'click': ui.createHandlerFn(this, function() { return apnUpdate(); })
						}, [ _('Update the APN database') ]),
					]),
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [
							E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'apn-current' }, [ '—' ]) ]),
							E('div', { 'id': 'apn-status', 'style': 'margin-top:4px' }, []),
						]),
					]),
				]),
			]),
		]);

		/* Настройки теста скорости (кнопка теста - в «Приоритете интернета» на
		   странице «Сеть»; тут только эндпойнты). */
		var m = new form.Map('5gmodem');
		var o;

		/* Вкладки, которые гейтятся через menu.d depends.uci (align_enabled -
		   «Юстировка»), не появляются/не исчезают сразу после сохранения: дерево
		   меню LuCI кэшируется по mtime файлов меню, а не по uci, и смену галочки
		   не подхватывает (вкладка держится до ребута). Поэтому после КАЖДОГО
		   сохранения сбрасываем кэш меню - дёшево (rm файла), а menu перечитается
		   на ближайшей навигации. Оборачиваем save, чтобы сброс шёл ПОСЛЕ commit. */
		/* ГАЛОЧКИ, КОТОРЫЕ ГЕЙТЯТ ВКЛАДКИ, ТРЕБУЮТ ПЕРЕЗАГРУЗКИ СТРАНИЦЫ.
		   Бэкенд отрабатывает верно: значение сохраняется, кэш дерева меню
		   сбрасывается (см. applyset), и следующий запрос уже отдаёт вкладку.
		   Но ОТКРЫТАЯ страница получила меню один раз при загрузке - и полоса
		   вкладок остаётся прежней. Со стороны это выглядит как «включил
		   Юстировку, а вкладки нет» (отчёт пользователя 25.08.2026).
		   Поэтому запоминаем исходные значения и после сохранения
		   перезагружаем страницу, если хоть одно изменилось. */
		var _gateOpts = [ 'align_enabled', 'show_stats' ];
		var _gateWas = {};
		_gateOpts.forEach(function(k) {
			_gateWas[k] = String(uci.get('5gmodem', sid0(), k) || '');
		});
		function sid0() {
			var ss = uci.sections('5gmodem', '5gmodem');
			return (ss && ss[0]) ? ss[0]['.name'] : '';
		}
		function _gateChanged() {
			return _gateOpts.some(function(k) {
				return String(uci.get('5gmodem', sid0(), k) || '') !== _gateWas[k];
			});
		}

		var _mSaveOrig = m.save.bind(m);
		m.save = function() {
			return _mSaveOrig.apply(null, arguments).then(function(r) {
				/* Мгновенное применение: staged-дельты rpcd лежат в ОБЩЕМ
				   /tmp/.uci (uci -c не песочница), поэтому granted-скрипт
				   коммитит их обычным `uci commit` и сбрасывает кэш меню
				   (гейт вкладки Юстировки). Никакого uci.apply с rollback. */
				/* КОММИТ - ПЕРВЫМ ДЕЛОМ И ПО СВОЕЙ СЕССИИ (см. uciCommit выше).
				   Внешний скрипт сюда не годится в принципе: он не видит
				   сессионную дельту. Он остаётся только ради сброса кэша меню
				   и как страховка на случай, если правка всё же осела в общем
				   /tmp/.uci (туда пишут наши же скрипты). */
				return commitPending().then(function() {
					return L.resolveDefault(fs.exec('/usr/share/5gmodem/setopt.sh', [ 'applyset' ]), null);
				}).then(function() {
					/* Коммит прошёл МИМО LuCI - её индикатор «непримененных
					   изменений» сам об этом не узнает и продолжает висеть.
					   Перечитываем staged-список с сервера (после commit он
					   пуст) и выставляем счётчик индикатора по факту. */
					return uci.changes().then(function(ch) {
						var n = 0;
						for (var k in ch) { n += (ch[k] || []).length; }
						if (ui.changes && ui.changes.setIndicator) { ui.changes.setIndicator(n); }
						/* Вкладки «Юстировка» и «Статистика» прячутся стилем
						   (см. modemtabs.applyGateTabs), поэтому появляются на
						   месте - ни перезагрузки страницы, ни сброса кэша меню
						   не нужно. */
						if (_gateChanged()) {
							_gateOpts.forEach(function(k) {
								_gateWas[k] = String(uci.get('5gmodem', sid0(), k) || '');
							});
							modemtabs.refreshGateTabs();
						}
						return r;
					}).catch(function() { return r; });
				});
			});
		};

		/* Отображение блоков на странице «Сеть». Тумблеры включены по умолчанию;
		   страница «Сеть» скрывает блок, только когда значение явно '0'. */
		var disp = m.section(form.TypedSection, '5gmodem', _('Main'),
			_('Everyday options of the Network page and modem behaviour'));
		disp.anonymous = true;

		o = disp.option(form.Flag, 'simple_view', _('Simple view of the Network page'),
			_('Show only the essentials: modem name, signal, status lamp and the restart button. Expert blocks (bands, cell info, TTL, interface details) are hidden. Off by default.'));
		o.default = '0';
		o.rmempty = false;

		o = disp.option(form.Flag, 'show_stats', _('Collect statistics'),
			_('Collects uplink latency, signal, temperature and monthly traffic, and shows the "Statistics" tab with the charts. Series live in RAM; monthly traffic can be kept across reboots on the tab itself.'));
		o.default = '1';
		o.rmempty = false;

		o = disp.option(form.Flag, 'save_bands', _('Remember bands after reboot'),
			_('Re-apply your selected bands when the modem reconnects, so a modem that resets its band selection on reboot (e.g. FM350) keeps yours. Only modems that actually lost the selection are touched.'));
		o.default = '1';
		o.rmempty = false;

		/* Вкладка «Юстировка» ВЫКЛЮЧЕНА по умолчанию - нужна не всем. Пункт меню
		   появляется/исчезает по этому ключу (menu.d, depends.uci), как у
		   «Статистики»; после сохранения нужна перезагрузка страницы, чтобы LuCI
		   перечитал дерево меню. */
		var wdg = m.section(form.TypedSection, '5gmodem', _('Appearance'),
			_('Cards in the widgets row on the Network page. All are on by default.'));
		wdg.anonymous = true;

		o = wdg.option(form.Flag, 'widget_netpri', _('Internet priority'),
			_('Uplink switch — modems / Wi-Fi / WAN'));
		o.default = '1';
		o.rmempty = false;

		/* Фон карточек аплинков. По умолчанию ВЫКЛЮЧЕН: порядок и так читается
		   слева направо, а крупный знак - вкусовщина. Три режима: ничего, номер
		   приоритета, иконка интерфейса (у модема - логотип оператора SIM, у
		   Wi-Fi и кабеля - их значки; та же картинка, что в шапке карточки).
		   Значение '1' оставлено за номером - у ранних установок оно уже в
		   конфиге от прежней галочки «Отображать цифры».
		   Зависимость от widget_netpri: без самой панели опция бессмысленна. */
		o = wdg.option(ListDropdown, 'netpri_rank', _('Card background'),
			_('Large translucent mark on each uplink card'));
		o.value('0', _('None'));
		o.value('1', _('Priority number'));
		o.value('icon', _('Icons'));
		o.default = '0';
		o.rmempty = false;
		o.depends('widget_netpri', '1');

		/* Слежение за интернетом - СВОРАЧИВАЕМЫЙ блок прямо под приоритетом
		   (решение владельца, issue #12): по смыслу настройки сторожа живут
		   рядом с приоритетом, но развёрнутая форма отодвигала бы остальные
		   виджеты - свёрнутая занимает одну строку. Сохранение своё и
		   немедленное (setconf, как у модалки на панели) - Save/Apply страницы
		   этот блок не трогает. Без depends: сторож работает и при выключенном
		   виджете, ради этого блок сюда и добавлен. */
		/* Разворачивается с той же анимацией, что блоки на вкладке «Сеть»
		   (.tg-collapse в modem.css: дорожка сетки 0fr -> 1fr, работает с
		   любой высотой содержимого без пересчётов в JS). */
		var hwArrow = E('span', { 'style': 'display:inline-block;width:1em' }, '▸');
		var hwBody = E('div', { 'style': 'margin-top:.6em' });
		var hwCollapse = E('div', { 'class': 'tg-collapse' }, [
			E('div', { 'class': 'tg-collapse-inner' }, [ hwBody ])
		]);
		var hwWrap = E('div', { 'class': 'cbi-value' }, [
			E('div', {
				'style': 'cursor:pointer;user-select:none;font-weight:600',
				'click': function() {
					var open = !hwCollapse.classList.contains('open');
					hwCollapse.classList.toggle('open', open);
					hwArrow.textContent = open ? '▾' : '▸';
				}
			}, [ hwArrow, _('Internet watchdog') ]),
			hwCollapse
		]);
		/* Без кнопки: каждое изменение применяется само (autosave в
		   healthform.js), плашка коротко подтверждает. */
		var hwNote = E('em', { 'style': 'display:none' }, _('Saved and applied.'));
		var hwNoteT = null;
		healthform.load().then(function(d) {
			var hf = healthform.build(d.conf, d.uplinks, {
				autosave: true,
				onsaved: function() {
					hwNote.style.display = '';
					if (hwNoteT) { window.clearTimeout(hwNoteT); }
					hwNoteT = window.setTimeout(function() {
						hwNote.style.display = 'none';
					}, 2000);
				}
			});
			hwBody.appendChild(hf.node);
			hwBody.appendChild(hwNote);
		});
		o = wdg.option(form.DummyValue, '_health');
		o.render = function() { return hwWrap; };

		/* --- Пинг (внутри «Виджеты»): галочка + вложенная таблица карточек. --- */
		o = wdg.option(form.Flag, 'widget_status', _('Ping monitor'),
			_('Ping cards (host with a green/red dot and latency)'));
		o.default = '1';
		o.rmempty = false;

		/* form.TableSection: карточки строками-таблицей (хост | режим | удалить)
		   в ОДНУ строку при достаточной ширине; без пояснения-описания. */
		var psv = wdg.option(form.SectionValue, '__pingcards', form.TableSection, 'pingwidget');
		psv.depends('widget_status', '1');
		var pw = psv.subsection;
		pw.anonymous = true;
		pw.addremove = true;
		/* Просто «+» (решение владельца): подпись «Добавить карточку пинга»
		   растягивала кнопку, а смысл ясен из таблицы над ней. Полное название
		   остаётся в подсказке (title ставится после рендера). */
		pw.addbtntitle = '+';

		var pho = pw.option(form.Value, 'host', _('Host'));
		/* Пресеты-подсказки для поля host (просто варианты в выпадашке). Дефолтную
		   карточку (youtube.com) заводит СИД-конфиг (uci-defaults/seed_widgets.sh) -
		   стандартным путём, а не хардкодом здесь. Раньше тут стояли ещё
		   pho.default/pho.placeholder='youtube.com': placeholder уходил в
		   select_placeholder комбобокса и рисовался ОТДЕЛЬНЫМ пунктом сверху -
		   youtube.com двоился в списке. Убрали - остаётся один вариант. */
		pho.value('youtube.com');
		/* Telegram проверяется не пингом, а по официальному списку сетей плюс
		   403/404 от api.telegram.org - см. netpri.sh ping. */
		pho.value('api.telegram.org', 'Telegram (api.telegram.org)');
		pho.value('github.com');
		pho.value('google.com');
		pho.value('cloudflare.com');
		pho.value('yandex.ru');

		var pmo = pw.option(ListDropdown, 'mode', _('Ping mode'));
		pmo.value('click', _('On click only'));
		pmo.value('10', _('Every 10 s'));
		pmo.value('30', _('Every 30 s'));
		pmo.value('60', _('Every 60 s'));
		pmo.default = 'click';

		/* --- Службы (внутри «Виджеты»): галочка + вложенная таблица сервисов. --- */
		o = wdg.option(form.Flag, 'widget_services', _('Service monitor'),
			_('Service status cards (running/stopped)'));
		o.default = '1';
		o.rmempty = false;

		var ssv = wdg.option(form.SectionValue, '__svccards', form.TableSection, 'svcwidget');
		ssv.depends('widget_services', '1');
		var sw = ssv.subsection;
		sw.anonymous = true;
		sw.addremove = true;
		sw.addbtntitle = '+';

		/* ВЫПАДАЮЩИЙ СПИСОК, а не свободный ввод. form.Value с placeholder='ssclash'
		   не имел реального значения: при «Добавить» поле пустое, плейсхолдер лишь
		   подсказка, и Save записывал секцию svcwidget БЕЗ service - карточка не
		   появлялась (config-driven, см. netpri.js). ListValue всегда пишет
		   ВЫБРАННОЕ значение и имеет дефолт, поэтому пустых карточек не бывает. */
		var svo = sw.option(ListDropdown, 'service', _('Service'));
		if (services.length) {
			/* известным сервисам - человеческое имя в списке (карточка тоже
			   покажет его, см. SVC_KNOWN в netpri.js) */
			var _svcNice = { zapret: 'Zapret', zerotier: 'ZeroTier' };
			services.forEach(function(s) { svo.value(s, _svcNice[s] || s); });
			svo.default = (services.indexOf('ssclash') >= 0) ? 'ssclash'
			            : (services.indexOf('clash') >= 0)   ? 'clash'
			            : services[0];
		} else {
			svo.value('ssclash'); svo.default = 'ssclash';
		}
		svo.rmempty = false;   // пишем даже значение, равное дефолту

		/* ПЕРЕЗАПУСК ПОСЛЕ ПОДЪЁМА ИНТЕРНЕТА. Туннели и обходилки стартуют по
		   procd раньше, чем поднялся аплинк, и инициализируются без сети:
		   подписка не скачалась, DNS не поднялся. Галочка отдаёт сервис
		   hotplug-у 70-5gmodem-svcrestart - он перезапустит его в момент, когда
		   через аплинк реально пошли пакеты. Аплинк ЛЮБОЙ из «Приоритета
		   интернета», не только модем: Wi-Fi STA и WAN по DHCP поднимаются так
		   же поздно. */
		var ruo = sw.option(form.Flag, 'restart_on_uplink', _('Restart on uplink'),
			_('Restart the service once the uplink starts carrying traffic.'));
		ruo.default = '0';
		ruo.rmempty = false;

		/* --- Тест скорости (внутри «Виджеты»): галочка + ВЛОЖЕННЫЙ блок настроек
		   (form.SectionValue, как у карточек), видимый только при вкл. --- */
		o = wdg.option(form.Flag, 'widget_speedtest', _('Speed test'), _('Speed-test card'));
		o.default = '1';
		o.rmempty = false;

		var stv = wdg.option(form.SectionValue, '__sttings', form.TypedSection, '5gmodem');
		stv.depends('widget_speedtest', '1');
		var sts = stv.subsection;
		sts.anonymous = true;

		o = sts.option(form.Value, 'speedtest_url', _('Download source'),
			_('URL for the download test. A BIGGER file lets the speed ramp up over the ~15-second test; a small one finishes early and reads low. RU-hosted sources (Selectel/Yandex/Tele2) work over Russian cellular; Cloudflare/Hetzner may be blocked there. Approx. size shown.'));
		o.value('https://speedtest.selectel.ru/1GB', 'Selectel — RU (~1 ' + _('GB') + ')');
		o.value('http://mirror.yandex.ru/archlinux/iso/latest/archlinux-x86_64.iso', 'Yandex — RU (~1 ' + _('GB') + ')');
		o.value('http://speedtest.tele2.net/1GB.zip', 'Tele2 (~1 ' + _('GB') + ')');
		o.value('https://speed.cloudflare.com/__down?bytes=1000000000', 'Cloudflare (' + _('stream') + ')');
		o.value('https://speed.hetzner.de/1GB.bin', 'Hetzner — EU (~1 ' + _('GB') + ')');
		o.value('http://mirror.yandex.ru/debian/ls-lR.gz', 'Yandex (~16 ' + _('MB') + ', ' + _('economical') + ')');
		o.default = 'http://speedtest.tele2.net/1GB.zip';
		o.placeholder = 'http://speedtest.tele2.net/1GB.zip';
		o.rmempty = true;

		o = sts.option(form.Value, 'speedtest_up_url', _('Upload endpoint'),
			_('Endpoint that accepts a POST body, for the upload test. RU-hosted endpoints (Rostelecom/Yandex) work over Russian cellular; the server reads the body even when it answers 404/403, so the speed is still measured.'));
		o.value('https://speedtest.rt.ru/backend/empty.php', 'Rostelecom (LibreSpeed)');
		o.value('https://yandex.ru/internet/api/v1/upload', 'Yandex (RU, works over cellular)');
		o.value('https://speed.cloudflare.com/__up', 'Cloudflare');
		o.value('https://librespeed.org/backend/empty.php', 'LibreSpeed (public demo)');
		o.default = 'https://speedtest.rt.ru/backend/empty.php';
		o.placeholder = 'https://speedtest.rt.ru/backend/empty.php';
		o.rmempty = true;

		/* СЕРВИС ОПРЕДЕЛЕНИЯ АДРЕСА ЗДЕСЬ БОЛЬШЕ НЕ СПРАШИВАЕМ. Он один и тот
		   же для карточки теста и для «Внешнего IP» - две настройки об одном
		   и том же расходились и путали. Настройка переехала в «Для экспертов»,
		   здесь - только ссылка на неё. */
		o = sts.option(form.DummyValue, '_extip_hint', _('Public IP service'));
		o.cfgvalue = function() { return ''; };
		o.renderWidget = function() {
			return E('a', {
				'href': '#',
				'click': function(ev) {
					ev.preventDefault();
					var t = document.querySelector('[id$="-extip_url"]');
					if (t) { t.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
				}
			}, _('Shared with "External IP" - set it under "For experts"'));
		};


		/* «Для экспертов» - НАМЕРЕННО ПОСЛЕДНЯЯ секция (UX-аудит, P6): редкие
		   и тонкие опции не должны стоять вперемешку с ежедневными - пользователь
		   не отличал «сломает интернет» от «поменяет цвет карточки». */
		var exp = m.section(form.TypedSection, '5gmodem', _('For experts'),
			_('Rarely needed options. The defaults are fine for most setups.'));
		exp.anonymous = true;

		o = exp.option(form.Flag, 'show_ttl', _('Show TTL fixing'),
			_('Show the "TTL fixing" block on the Network page.'));
		o.default = '1';
		o.rmempty = false;

		/* ОДИН ключ на всё: и сбор рядов, и вкладку. Два отдельных выключателя
		   («собирать» на странице + «показывать» здесь) давали бессмысленное
		   состояние «вкладка есть, данных нет». Пункт меню появляется/исчезает
		   по этому же ключу (см. menu.d), поэтому после сохранения нужна
		   перезагрузка страницы - LuCI перечитает дерево меню. */

		o = exp.option(form.Flag, 'align_enabled', _('Alignment'),
			_('Live signal metrics and a tone for aiming an external antenna.'));
		o.default = '0';
		o.rmempty = false;

		/* ВНЕШНИЙ АДРЕС. Адрес на интерфейсе и адрес, с которого роутер виден
		   интернету, совпадают далеко не всегда: у сотовой это CGNAT оператора,
		   за туннелем - адрес выходного узла. Разница между ними и отвечает на
		   вопрос «ходит ли сам роутер через VPN».
		   СНАЧАЛА «ЧЕМ УЗНАЁМ», ПОТОМ «ПОКАЗЫВАТЬ ЛИ». Сервис общий с тестом
		   скорости, поэтому он виден всегда - даже когда показ выключен;
		   выключатель ниже управляет только строками в карточках.
		   Фолбэков у адреса намеренно нет - спрашиваем ровно то, что задано:
		   кому показывать свой адрес, человек решает сам. */
		var exsv = exp.option(form.SectionValue, '__extipsvc', form.TypedSection, '5gmodem');
		var exs = exsv.subsection;
		exs.anonymous = true;
		exs.title = _('External IP');
		exs.description = _('Where the router asks what its address looks like from the outside. The speed-test card uses the same service.');

		o = exs.option(form.Value, 'extip_url', _('IPv4 service'),
			_('Only this service is queried - there are no silent fallbacks. One that also returns the country (like ip-api.com) gets a flag shown next to the address. Foreign services often stay silent over Russian cellular; the Yandex one answers there.'));
		o.value('http://ip-api.com/line/?fields=countryCode,query', 'ip-api.com (IP + ' + _('country') + ')');
		o.value('https://api.ipify.org', 'ipify (api.ipify.org)');
		o.value('https://ifconfig.me/ip', 'ifconfig.me');
		o.value('https://icanhazip.com', 'icanhazip.com');
		o.value('https://ident.me', 'ident.me');
		o.value('https://ipinfo.io/ip', 'ipinfo.io');
		o.value('https://yandex.ru/internet/api/v0/ip', 'Yandex - RU (' + _('works over cellular') + ')');
		o.default = 'http://ip-api.com/line/?fields=countryCode,query';
		o.placeholder = 'http://ip-api.com/line/?fields=countryCode,query';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_url6', _('IPv6 service'),
			_('Queried only when the router actually has an IPv6 default route - otherwise the request would just sit there until it times out.'));
		o.value('https://api6.ipify.org', 'ipify (api6.ipify.org)');
		o.value('https://v6.ident.me', 'ident.me (v6)');
		o.value('https://ipv6.icanhazip.com', 'icanhazip.com (v6)');
		o.default = 'https://api6.ipify.org';
		o.placeholder = 'https://api6.ipify.org';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_cc_url', _('Country lookup'),
			_('Used only when the service above returns an address but no country: the flag is then resolved by a second request, for the country alone. Use {ip} as the address placeholder.'));
		o.value('http://ip-api.com/line/{ip}?fields=countryCode', 'ip-api.com');
		o.value('https://ipapi.co/{ip}/country/', 'ipapi.co');
		o.placeholder = 'http://ip-api.com/line/{ip}?fields=countryCode';
		o.rmempty = true;

		o = exs.option(form.Value, 'extip_ua', _('User-Agent'),
			_('Header sent with the request. Some services answer a console client with plain text and a browser with an HTML page; and a header of your own keeps the router from introducing itself as one. Empty - whatever curl/wget sends by default.'));
		o.value('Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36', 'Chrome (Windows)');
		o.value('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15', 'Safari (macOS)');
		o.value('Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1', 'Safari (iPhone)');
		o.value('curl/8.19.0', 'curl');
		o.rmempty = true;

		/* ПРОВЕРКА ПРЯМО ИЗ НАСТРОЕК. Выбрать сервис вслепую нельзя: половина
		   из них с сотовой в РФ молчит, и без ответа тут же на месте человек
		   узнал бы об этом только по пустой строке в карточке. Кнопка спрашивает
		   ИМЕННО ТО, ЧТО СЕЙЧАС В ПОЛЯХ, - до сохранения. */
		o = exs.option(form.Button, '__extip_check', _('Check now'),
			_('Query the services above with the current settings and show what they answer.'));
		o.inputtitle = _('Check');
		o.inputstyle = 'apply';
		/* ОТВЕТ - ПОД КНОПКОЙ, А НЕ ВСПЛЫВАШКОЙ. Уведомление LuCI показывается
		   в самом верху страницы, а «Для экспертов» - в самом низу: нажавший
		   кнопку не увидел бы своего же ответа, не пролистав вверх. */
		o.onclick = function(ev, section_id) {
			var btn = ev.target;
			var fld = (btn.closest && btn.closest('.cbi-value-field')) || btn.parentNode;
			var box = fld.querySelector('.extip-res');
			if (!box) { box = E('div', { 'class': 'extip-res' }); fld.appendChild(box); }
			var u4 = this.section.formvalue(section_id, 'extip_url') || 'http://ip-api.com/line/?fields=countryCode,query';
			var u6 = this.section.formvalue(section_id, 'extip_url6') || '';
			var ua = this.section.formvalue(section_id, 'extip_ua') || '';
			/* Флаг вместо кода страны - как в карточке модема и в «Приоритете
			   интернета»: одна и та же вещь везде выглядит одинаково. */
			var line = function(fam, res) {
				var d = {};
				try { d = JSON.parse(res || '{}'); } catch (e) {}
				if (d.ok == 1) {
					return E('div', {}, [
						E('span', { 'class': 'extip-res-fam' }, fam + ': '),
						E('span', {}, extip.withFlag(d.ip, d.cc)),
						d.src ? E('span', { 'class': 'extip-res-src' }, ' - ' + d.src) : ''
					]);
				}
				return E('div', { 'class': 'extip-res-bad' },
					fam + ': ' + _('no answer from %s').format(d.src || '?'));
			};
			btn.disabled = true;
			dom.content(box, E('div', { 'class': 'extip-res-wait' }, _('Checking…')));
			return L.resolveDefault(fs.exec_direct(EXTIPBIN, [ 'probe', u4, '4', ua ]), '')
				.then(function(r4) {
					var out = [ line('extIPv4', r4) ];
					if (!u6) { return out; }
					return L.resolveDefault(fs.exec_direct(EXTIPBIN, [ 'probe', u6, '6', ua ]), '')
						.then(function(r6) { out.push(line('extIPv6', r6)); return out; });
				}).then(function(out) {
					dom.content(box, out);
					btn.disabled = false;
				});
		};

		o = exp.option(form.Flag, 'extip_enabled', _('Show the external address'),
			_('Show it next to the address the carrier assigned - in the modem card as "IPv4: 10.x.x.x | 1.2.3.4". Behind CGNAT or a tunnel the two differ, and that difference tells you whether the router\'s own traffic goes through the VPN. Off by default: this is a request to a third-party service.'));
		o.default = '0';
		o.rmempty = false;

		var exdv = exp.option(form.SectionValue, '__extipshow', form.TypedSection, '5gmodem');
		exdv.depends('extip_enabled', '1');
		var exd = exdv.subsection;
		exd.anonymous = true;

		o = exd.option(form.Flag, 'extip_in_netpri', _('Show in the priority bar'),
			_('On the card of the uplink that currently carries the traffic, show the external address instead of the one assigned by the carrier.'));
		o.default = '0';
		o.rmempty = false;

		o = exd.option(ListDropdown, 'extip_ttl', _('Refresh interval'),
			_('How often the address is looked up again. A change of uplink refreshes it immediately, without waiting for the interval.'));
		o.value('60', _('Every minute'));
		o.value('300', _('Every 5 minutes'));
		o.value('900', _('Every 15 minutes'));
		o.value('1800', _('Every 30 minutes'));
		o.default = '300';

		/* База метрик аплинков (issue #12). По умолчанию 100, 110, 120... -
		   туннелям (wireguard, zerotier) остаётся весь диапазон 1-99. Галочка
		   возвращает прежние 10, 20, 30... - соглашение mwan3. Читают её
		   netpri.sh (_metric_base) и mkiface.sh (метрика нового интерфейса).
		   Без depends: метрики аплинков существуют и при выключенном виджете. */
		o = exp.option(form.Flag, 'mwan3_metrics', _('mwan3-compatible metrics'),
			_('Uplink metrics start at 10 (10, 20, 30...) as mwan3 expects. When off they start at 100 (100, 110, 120...), leaving 1-99 free for tunnels. Takes effect on the next priority change.'));
		o.default = '0';
		o.rmempty = false;

		/* ЧЁРНЫЙ СПИСОК УСТРОЙСТВ.
		   Модем опознаётся по драйверам и классам интерфейсов (notmodem.sh), но
		   эвристика конечна: воткнутая в роутер железка с ttyUSB может получить
		   вкладку и опрос AT-командами (живой случай 01.09.2026, CH340 1a86:7523).
		   Здесь человек говорит последнее слово - но говорить его нужно только
		   про СОМНИТЕЛЬНЫЕ устройства.

		   ЧТО В СПИСКЕ. Всё, чего НЕТ в базе модемов (modem/usb/<vidpid>, поле
		   known): про эти устройства программа не уверена. Известные модемы (тот
		   же FM350) в список не попадают - раньше они висели там с галочкой «это
		   модем», и человек читал это как вопрос, на который уже ответили
		   (замечание владельца 03.09.2026). Исключение - устройство, про которое
		   ручка в конфиге уже стоит: спрятать его строку значило бы потерять
		   настройку.

		   ГАЛОЧКА = ИСКЛЮЧИТЬ. Одна на две ручки конфига: поставили на устройстве,
		   которое считается модемом само по себе (auto), - оно уезжает в
		   ignore_vidpid; сняли с того, что модемом не считается, - в modem_vidpid
		   (отладочная плата, где сотовый модуль подключён через мост USB-UART).

		   ПИШЕМ ВЕРБОМ, А НЕ ФОРМОЙ. Обычная запись через uci копится в сессии
		   LuCI до кнопки «Применить», а галочка должна срабатывать сразу: верб
		   setblack ставит обе ручки и коммитит, после чего страница перечитывается
		   - вкладка исключённого устройства исчезает тут же. */
		var bl = usbDevs.filter(function(d) {
			return d.known !== '1' || d.why === 'ignored' || d.why === 'forced' || d.absent === '1';
		});
		/* Подпись устройства: имя, vid:pid, порты и - одним словом в конце - чем
		   программа считает его сейчас. Без этого галочка у чужого свистка
		   выглядит произволом. Бэкенд присылает код, фразу собираем здесь: она
		   переводимая. */
		var devLabel = function(d) {
			var parts = [];
			if (d.product) { parts.push(d.product); }
			parts.push(d.vidpid);
			var label = parts.join(' — ');
			var ports = (d.ports || []).join(', ');
			if (d.absent === '1') { label += ' (' + _('not on the bus') + ')'; }
			else if (ports) { label += ' — ' + ports; }
			var why = {
				vendor:  _('cellular module vendor'),
				driver:  _('modem driver in the kernel'),
				mbim:    _('MBIM interface'),
				ecm:     _('CDC Ethernet interface'),
				ncm:     _('CDC NCM interface'),
				profile: _('has answered as a modem before'),
				forced:  _('returned to modems by hand'),
				bridge:  _('USB-to-serial adapter'),
				ignored: _('excluded by hand'),
				none:    _('no modem driver and no modem network interface')
			}[d.why];
			if (why) { label += ' — ' + why + (d.detail ? ' (' + d.detail + ')' : ''); }
			return label;
		};
		var blBoxes = [];
		var blSeen = {};
		var blItems = [];
		bl.forEach(function(d) {
			if (blSeen[d.vidpid]) { return; }
			blSeen[d.vidpid] = true;
			/* Отмечено = сейчас НЕ показывается как модем. Итог уже посчитан
			   бэкендом (skip), с учётом обеих ручек - повторять их разбор в
			   браузере значило бы держать две копии одного правила. */
			var w = new ui.Checkbox(d.skip === '1' ? '1' : '0',
				{ id: 'blk-' + d.vidpid.replace(':', '_') });
			blBoxes.push({ dev: d, w: w });
			var wn = w.render();
			blItems.push(E('div', { 'class': 'tg-blitem' }, [ wn, E('span', {
				'style': 'cursor:pointer',
				'click': function() { wn.querySelector('input').click(); }
			}, devLabel(d)) ]));
		});
		var blBody = E('div', {}, blItems.length ? blItems
			: [ E('em', {}, _('No doubtful devices: everything found on the bus is in the modem database.')) ]);
		/* Пауза перед записью склеивает серию галочек в одно применение - иначе
		   страница перечитывалась бы после каждой. */
		var blT = null;
		blBody.addEventListener('widget-change', function() {
			if (blT) { window.clearTimeout(blT); }
			blT = window.setTimeout(function() {
				var ign = [], force = [];
				blBoxes.forEach(function(b) {
					/* auto - каким устройство было бы БЕЗ обеих ручек. Ручку ставим
					   только там, где галочка расходится с этим: иначе конфиг
					   зарастал бы записями, ничего не меняющими. */
					if (b.w.isChecked()) {
						if (b.dev.auto === '1') { ign.push(b.dev.vidpid); }
					} else if (b.dev.auto !== '1') {
						force.push(b.dev.vidpid);
					}
				});
				fs.exec('/usr/share/5gmodem/notmodem.sh',
					[ 'setblack', ign.join(' '), force.join(' ') ])
					.then(function() { window.location.reload(); });
			}, 600);
		});
		o = exp.option(form.DummyValue, '_blacklist', _('Device blacklist'),
			_('USB devices the app is not sure about - they are missing from its modem database. Tick one to drop it from the app: no tab, no AT probing, no place in internet priority. Applied immediately.'));
		o.render = function(option_index, section_id) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Device blacklist')),
				E('div', { 'class': 'cbi-value-field' }, [ blBody,
					E('div', { 'class': 'cbi-value-description' },
						_('USB devices the app is not sure about - they are missing from its modem database. Tick one to drop it from the app: no tab, no AT probing, no place in internet priority. Applied immediately.')) ])
			]);
		};

		/* МГНОВЕННОЕ ПРИМЕНЕНИЕ (решение владельца): любое изменение на
		   странице сохраняется и применяется само - кнопки Сохранить/Применить
		   внизу убраны (handle* = null ниже). Слушаем change (инпуты, галки,
		   списки) и клики по «+»/«удалить» вложенных таблиц; сохранение
		   дебаунсится, чтобы серия правок ушла одним commit. */
		var _asT = null;
		var _asNode = null;
		var _asSig = null;

		/* СНИМОК ЗНАЧЕНИЙ ФОРМЫ. Нужен, чтобы отличить настоящую правку от
		   пустого события: ui.Dropdown шлёт cbi-dropdown-change и когда список
		   просто закрыли, не выбрав ничего, - без этой проверки каждый промах
		   мимо списка уходил бы в сохранение. */
		var formSig = function() {
			if (!_asNode) { return ''; }
			var parts = [];
			_asNode.querySelectorAll('input, textarea').forEach(function(el) {
				parts.push((el.type === 'checkbox' || el.type === 'radio')
					? (el.checked ? '1' : '0') : String(el.value));
			});
			_asNode.querySelectorAll('.cbi-dropdown').forEach(function(el) {
				var w = dom.findClassInstance(el);
				parts.push(w ? String(w.getValue()) : '');
			});
			return parts.join('\u0001');
		};

		/* ПРИМЕНЯЕМ СРАЗУ - НО ТОЛЬКО СВОЙ КОНФИГ (просьба владельца 03.09.2026).
		   uci.save() лишь складывает правки в сессию LuCI: до нажатия «Применить»
		   на роутере ничего не меняется, и внизу висит «не принятые изменения».
		   Для страницы с автосохранением это бессмысленно, поэтому применяем сами.

		   ДВА ПРЕДОХРАНИТЕЛЯ, без которых так делать нельзя:

		   1. ЧУЖИЕ ПРАВКИ НЕ ТРОГАЕМ. uci apply применяет ВСЁ, что скопилось в
		      сессии, а не только наше. Человек мог отредактировать сеть на другой
		      странице и не применить - молча применить это за него значило бы
		      уронить ему связь. Поэтому применяем, лишь когда в очереди ровно один
		      конфиг и он наш; иначе оставляем всё как есть, и человек нажимает
		      «Применить» сам, видя полный список.
		   2. БЕЗ ОТКАТА. Штатный uci.apply() применяет с таймером отката и потом
		      подтверждает вызовом confirm: не дошло подтверждение - роутер вернёт
		      конфиг назад (у нас так уже терялись настройки). Этот танец нужен
		      сетевым конфигам, где можно отрезать себе доступ. Наш 5gmodem -
		      настройки самой программы: ни сети, ни фаервола он не трогает, и
		      откатывать нечего. Зовём apply с rollback=false - применяется сразу
		      и насовсем. По триггерам procd перечитывают конфиг только 5gmodem-leds
		      и 5gmodem-sms-notify - ровно те, кому новые настройки и нужны. */
		var applyOwn = function() {
			return uci.changes().then(function(ch) {
				var cfgs = Object.keys(ch || {});
				if (cfgs.length !== 1 || cfgs[0] !== '5gmodem') { return; }
				return uci.callApply(0, false).then(function() {
					/* плашка «не принятые изменения» должна погаснуть */
					if (ui.changes && ui.changes.init) { return ui.changes.init(); }
				});
			});
		};

		/* СОХРАНЯЕМ БЕЗ ПЕРЕРИСОВКИ СТРАНИЦЫ. m.save() в LuCI заканчивается
		   renderContents() - карта пересобирается целиком, и на автосохранении
		   это выглядит как моргание всей страницы после каждого выбора в списке
		   (замечено владельцем 03.09.2026). Нам нужен только разбор формы и
		   запись: parse() кладёт значения в uci, uci.save() отправляет их.
		   Видимость зависимых полей от этого не страдает - её пересчитывает сам
		   form.js по widget-change. */
		var autoSave = function(heavy) {
			if (_asT) { window.clearTimeout(_asT); }
			_asT = window.setTimeout(function() {
				if (heavy === true) {
					/* добавление/удаление строки во вложенной таблице - там
					   перерисовка нужна: строки появляются и исчезают */
					_asSig = null;
					m.save(null, true).then(function() { _asSig = formSig(); })
						.catch(function() {});
					return;
				}
				var sig = formSig();
				if (_asSig !== null && sig === _asSig) { return; }
				_asSig = sig;
				m.parse()
					.then(function() { return uci.save(); })
					.then(applyOwn)
					.catch(function() {});
			}, 400);
		};

		return Promise.resolve(m.render()).then(function(formNode) {
			/* ВСЕ пути изменения значения, а не только нативный change:
			   кастомные виджеты LuCI (выпадающие списки ListValue - сервис,
			   фон карточек, режим пинга) нативного change НЕ шлют - они
			   диспатчат свои widget-change/cbi-dropdown-change. Без этих
			   двух подписок выбор в списках не сохранялся вовсе (живой отчёт
			   владельца 16.08.2026: «виджеты и сервисы не применяются»). */
			_asNode = formNode;
			_asSig = formSig();
			var onChange = function() { autoSave(false); };
			formNode.addEventListener('change', onChange);
			formNode.addEventListener('widget-change', onChange);
			formNode.addEventListener('cbi-dropdown-change', onChange);
			formNode.addEventListener('click', function(ev) {
				if (ev.target.closest && ev.target.closest('.cbi-button-add, .cbi-button-remove')) { autoSave(true); }
			});
			/* Версию установленной базы APN показываем СРАЗУ (чтение файла, без
			   сети) - «Проверить» ходит наружу и остаётся действием пользователя. */
			apnVersion();
			/* Кнопкам «+» - полное название в подсказку: сами они лаконичны
			   намеренно, но при наведении должно быть ясно, что добавляется. */
			formNode.querySelectorAll('.cbi-button-add').forEach(function(b) {
				var w = b.closest('[id*="__pingcards"], [id*="__svccards"]');
				if (!w) { return; }
				b.title = (w.id.indexOf('__pingcards') >= 0)
					? _('Add ping card') : _('Add service card');
			});
			return E('div', {}, [
				/* Тот же контейнер, что у формы: темы рисуют «карточку» секции по
				   селектору .cbi-map .cbi-section, и собранный вручную блок вне
				   формы оставался без плашки (замечено владельцем 07.08.2026). */
				E('div', { 'class': 'cbi-map' }, [ updateBlock ]),
				/* Карточки виджетов (пинг/сервисы): обе темы рендерят настоящую
				   <table class="cbi-section-table">, но по умолчанию она тянется
				   на 100% ширины и колонки расползаются по-разному. Сжимаем
				   таблицу и колонки по содержимому - одинаково в bootstrap и proton. */
				E('div', { 'class': 'tg-modem-form' }, [ formNode ])
			]);
		});
	},

	/* КНОПКА «Сохранить и применить» - СТРАХОВОЧНАЯ СЕТЬ НАД МГНОВЕННЫМ
	   СОХРАНЕНИЕМ, а не возврат к старому порядку.
	   Мгновенное применение (autoSave выше) остаётся: обычно нажимать нечего.
	   Но у него есть пути отказа, и без кнопки они превращались в тупик:
	   правка застревала в staged-дельте uci, LuCI показывала «непринятые
	   изменения», а применить их на странице было НЕЧЕМ (отчёт владельца
	   23.08.2026 - список из десятка uci set висел непринятым). Отказать
	   мгновенное сохранение может как минимум когда:
	     - установлен старый setopt.sh без верба applyset (обновили только
	       htdocs, бэкенд прежний) - commit не делает никто;
	     - вызов бэкенда не прошёл (ACL, занятый rpcd, таймаут) - ошибку
	       глотал resolveDefault.
	   Поэтому: одна кнопка «Сохранить и применить». Reset скрыт намеренно -
	   при мгновенном сохранении откатывать уже нечего. */
	handleSave: null,
	handleReset: null,
	handleSaveApply: function(ev) {
		return this.handleSave_(ev);
	},
	/* Своя реализация вместо унаследованной: та зовёт save() у всех .cbi-map
	   на странице, а нам после сохранения нужно ПРОВЕРИТЬ, что дельта
	   действительно применилась, и если нет - доприменить штатным способом
	   LuCI (ui.changes.apply). Проверка дешёвая (одно чтение списка). */
	handleSave_: function(ev) {
		var tasks = [];
		document.getElementById('maincontent')
			.querySelectorAll('.cbi-map').forEach(function(map) {
				tasks.push(L.dom.callClassMethod(map, 'save'));
			});
		return Promise.all(tasks).then(function() {
			return uci.changes();
		}).then(function(ch) {
			var n = 0;
			for (var k in ch) { n += (ch[k] || []).length; }
			/* Наш быстрый путь справился - применять больше нечего. */
			if (!n) { return; }
			/* Не справился - коммитим сами, по своей сессии: правка живёт
			   именно там. ui.changes.apply оставлен последним рубежом, но
			   идти в него не хочется - у него откат по таймауту
			   подтверждения, а он и сам умеет вернуть настройки назад. */
			return commitPending().then(function() {
				return uci.changes();
			}).then(function(ch2) {
				var n2 = 0;
				for (var k2 in ch2) { n2 += (ch2[k2] || []).length; }
				if (!n2) {
					if (ui.changes && ui.changes.setIndicator) { ui.changes.setIndicator(0); }
					return;
				}
				return ui.changes.apply(true);
			});
		});
	}
});
