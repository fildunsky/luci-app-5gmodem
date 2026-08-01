'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require fs';
'require ui';
'require uci';
'require form';

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum
	Licensed to the GNU General Public License v3.0.

	Вкладка «Настройки»: обновление приложения и настройки теста скорости.
	Вынесены со страницы «Модем», чтобы там осталось только про сам модем.
*/

/* --- Проверка/установка обновления с GitHub (app + перевод) --- */
function updSet(id, txt) { var e = document.getElementById(id); if (e) { e.textContent = txt; } }
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
		updSet('upd-latest', d.latest || '—');
		if (d.release_url) { var a = document.getElementById('upd-release'); if (a) { a.href = d.release_url; a.style.display = ''; } }
		if (!d.success) {
			updSet('upd-status', updErrText(d.error, _('Could not check for updates')));
		} else if (d.update_available == 1 || d.update_available === true) {
			updShow('upd-install', true);
			updSet('upd-status', _('A new version is available'));
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

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/buttons.sh', [ 'services' ]), '{}')
		]);
	},

	render: function(res) {
		modemtabs.attach();
		var services = [];
		try { services = (JSON.parse((res && res[1]) || '{}').services) || []; } catch (e) {}

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
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [ _('Current version') + ': ', E('strong', { 'id': 'upd-current' }, [ '—' ]) ]),
						E('div', {}, [ _('Latest version') + ': ', E('strong', { 'id': 'upd-latest' }, [ '—' ]) ]),
						E('div', { 'id': 'upd-status', 'style': 'margin-top:4px' }, []),
					]),
				]),
			]),
		]);

		/* Настройки теста скорости (кнопка теста - в «Приоритете интернета» на
		   странице «Сеть»; тут только эндпойнты). */
		var m = new form.Map('5gmodem');
		var o;

		/* Отображение блоков на странице «Сеть». Тумблеры включены по умолчанию;
		   страница «Сеть» скрывает блок, только когда значение явно '0'. */
		var disp = m.section(form.TypedSection, '5gmodem', _('Network'),
			_('Options for the Network page and modem behaviour'));
		disp.anonymous = true;

		o = disp.option(form.Flag, 'show_ttl', _('Show TTL fixing'),
			_('Show the "TTL fixing" block on the Network page.'));
		o.default = '1';
		o.rmempty = false;

		/* ОДИН ключ на всё: и сбор рядов, и вкладку. Два отдельных выключателя
		   («собирать» на странице + «показывать» здесь) давали бессмысленное
		   состояние «вкладка есть, данных нет». Пункт меню появляется/исчезает
		   по этому же ключу (см. menu.d), поэтому после сохранения нужна
		   перезагрузка страницы - LuCI перечитает дерево меню. */
		o = disp.option(form.Flag, 'show_stats', _('Collect statistics'),
			_('Collects uplink latency, signal, temperature and monthly traffic, and shows the "Statistics" tab with the charts. Series live in RAM; monthly traffic can be kept across reboots on the tab itself.'));
		o.default = '1';
		o.rmempty = false;

		o = disp.option(form.Flag, 'save_bands', _('Remember bands after reboot'),
			_('Re-apply your selected bands when the modem reconnects, so a modem that resets its band selection on reboot (e.g. FM350) keeps yours. Only modems that actually lost the selection are touched.'));
		o.default = '1';
		o.rmempty = false;

		/* ОДНА секция «Виджеты» - всё внутри неё: Приоритет интернета, Пинг,
		   Службы, Тест скорости. У Пинга/Служб карточки вложены ещё глубже
		   (form.SectionValue), настройки видны только при включённой галочке. */
		var wdg = m.section(form.TypedSection, '5gmodem', _('Widgets'),
			_('Show or hide the cards in the widgets row on the Network page. All are on by default.'));
		wdg.anonymous = true;

		o = wdg.option(form.Flag, 'widget_netpri', _('Internet priority'),
			_('Uplink switch — modems / Wi-Fi / WAN'));
		o.default = '1';
		o.rmempty = false;

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
		pw.addbtntitle = _('Add ping card');

		var pho = pw.option(form.Value, 'host', _('Host'));
		/* Пресеты-подсказки для поля host (просто варианты в выпадашке). Дефолтную
		   карточку (youtube.com) заводит СИД-конфиг (uci-defaults/seed_widgets.sh) -
		   стандартным путём, а не хардкодом здесь. Раньше тут стояли ещё
		   pho.default/pho.placeholder='youtube.com': placeholder уходил в
		   select_placeholder комбобокса и рисовался ОТДЕЛЬНЫМ пунктом сверху -
		   youtube.com двоился в списке. Убрали - остаётся один вариант. */
		pho.value('youtube.com');
		pho.value('github.com');
		pho.value('google.com');
		pho.value('cloudflare.com');
		pho.value('yandex.ru');

		var pmo = pw.option(form.ListValue, 'mode', _('Ping mode'));
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
		sw.addbtntitle = _('Add service card');

		/* ВЫПАДАЮЩИЙ СПИСОК, а не свободный ввод. form.Value с placeholder='ssclash'
		   не имел реального значения: при «Добавить» поле пустое, плейсхолдер лишь
		   подсказка, и Save записывал секцию svcwidget БЕЗ service - карточка не
		   появлялась (config-driven, см. netpri.js). ListValue всегда пишет
		   ВЫБРАННОЕ значение и имеет дефолт, поэтому пустых карточек не бывает. */
		var svo = sw.option(form.ListValue, 'service', _('Service'));
		if (services.length) {
			/* известным сервисам - человеческое имя в списке (карточка тоже
			   покажет его, см. SVC_KNOWN в netpri.js) */
			var _svcNice = { zapret: 'Zapret' };
			services.forEach(function(s) { svo.value(s, _svcNice[s] || s); });
			svo.default = (services.indexOf('ssclash') >= 0) ? 'ssclash'
			            : (services.indexOf('clash') >= 0)   ? 'clash'
			            : services[0];
		} else {
			svo.value('ssclash'); svo.default = 'ssclash';
		}
		svo.rmempty = false;   // пишем даже значение, равное дефолту

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

		o = sts.option(form.Value, 'speedtest_ip_url', _('Public IP service'),
			_('Service that returns your public IP. If it also returns the country (like ip-api.com), a flag is shown next to the IP. If it fails, a backup service is queried, and only then the local uplink address is shown (without a flag).'));
		o.value('http://ip-api.com/line/?fields=countryCode,query', 'ip-api.com (IP + country flag)');
		o.value('http://api.ipify.org', 'ipify (api.ipify.org)');
		o.value('https://ip.wtf', 'ip.wtf');
		o.value('http://ifconfig.me/ip', 'ifconfig.me');
		o.value('https://icanhazip.com', 'icanhazip.com');
		o.value('https://2ip.ru', '2ip.ru');
		o.value('https://whoer.net', 'whoer.net');
		o.default = 'http://ip-api.com/line/?fields=countryCode,query';
		o.placeholder = 'http://ip-api.com/line/?fields=countryCode,query';
		o.rmempty = true;

		o = sts.option(form.Value, 'speedtest_cc_url', _('Country lookup'),
			_('Used only when the service above returns an IP but no country: the flag is then resolved by a second request. Use {ip} as the address placeholder.'));
		o.value('http://ip-api.com/line/{ip}?fields=countryCode', 'ip-api.com');
		o.value('https://ipapi.co/{ip}/country/', 'ipapi.co');
		o.placeholder = 'http://ip-api.com/line/{ip}?fields=countryCode';
		o.rmempty = true;

		return Promise.resolve(m.render()).then(function(formNode) {
			return E('div', {}, [
				updateBlock,
				/* Карточки виджетов (пинг/сервисы): обе темы рендерят настоящую
				   <table class="cbi-section-table">, но по умолчанию она тянется
				   на 100% ширины и колонки расползаются по-разному. Сжимаем
				   таблицу и колонки по содержимому - одинаково в bootstrap и proton. */
				E('div', { 'class': 'tg-modem-form' }, [ formNode ])
			]);
		});
	}
});
