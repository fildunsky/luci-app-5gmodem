'use strict';
'require baseclass';
'require fs';
'require ui';

/*
	Общий компонент «шапки модема» для страниц luci-app-5gmodem:
	  - постоянный блок с ПОЛНЫМ именем активного модема (моноширинный);
	  - ряд вкладок выбора модема "Telit … | Compal …" (только если модемов >1).
	Данные: /usr/share/5gmodem/listmodems.sh + modemswitch.sh active.
	Клик по вкладке -> modemswitch.sh switch <usb-path> + перезагрузка страницы.

	Используется темой proton2025 (вставляет шапку НАД под-вкладками) через
	L.require('view.modem.modemtabs').renderBar().
*/

var CSS = `
.modembar { margin: 0 0 1em 0; }
.modembar .modembar-name {
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
	font-size: 1.15em; font-weight: 700; letter-spacing: .3px;
	padding: .2em 0 .5em 0;
}
.modembar .modemtabs-bar {
	display: flex; flex-wrap: wrap; gap: .4em; padding-bottom: .2em;
}
.modembar .modemtabs-bar .modemtab {
	padding: .35em 1em; border-radius: 6px; cursor: pointer; font-weight: 600;
}
.modembar .modemtabs-bar .modemtab.active { pointer-events: none; }
`;

/* Бренд по VID (или по характерному имени продукта). USB-дескриптор часто даёт
   только платформу ("VOS_5G", "Android"), поэтому добавляем читаемый бренд. */
function vendor(m) {
	var pr = String((m && m.product) || '');
	if (/VOS_5G|RXMG1/i.test(pr)) { return 'Compal'; }
	var vid = String((m && m.vidpid) || '').split(':')[0].toLowerCase();
	var map = {
		'1bc7': 'Telit', '2c7c': 'Quectel', '2cb7': 'Fibocom',
		'1e2d': 'Cinterion', '12d1': 'Huawei', '19d2': 'ZTE',
		'2dee': 'Foxconn', '0489': 'Foxconn', '413c': 'Dell', '05c6': 'Compal'
	};
	return map[vid] || '';
}

function label(m, i) {
	var p = (m && m.product) ? String(m.product).trim() : '';
	var v = vendor(m);
	var generic = (!p || /^android$/i.test(p) || /^usb/i.test(p) || (/modem/i.test(p) && p.length < 6));
	if (generic) { return v ? (v + ' ' + _('modem')) : _('Modem %d').format(i + 1); }
	if (v && p.toLowerCase().indexOf(v.toLowerCase()) < 0) { return v + ' ' + p; }
	return p;
}

function ensureCss() {
	if (!document.getElementById('modemtabs-css')) {
		document.head.appendChild(E('style', { 'id': 'modemtabs-css', 'type': 'text/css' }, CSS));
	}
}

function loadModems() {
	return Promise.all([
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh'), '[]'),
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'active' ]), '')
	]).then(function(res) {
		var modems = [];
		try { modems = JSON.parse(res[0] || '[]') || []; } catch (e) {}
		if (!Array.isArray(modems)) { modems = []; }
		var active = String(res[1] || '').trim();
		if (!modems.some(function(m) { return m.path === active; })) {
			active = modems.length ? modems[0].path : '';
		}
		return { modems: modems, active: active };
	});
}

function tabsBar(modems, active) {
	var tabs = modems.map(function(m, i) {
		var isActive = (m.path === active);
		return E('button', {
			'class': 'btn cbi-button modemtab' + (isActive ? ' cbi-button-action active' : ''),
			'data-path': m.path,
			'data-tooltip': (m.vidpid || '') + ' @ ' + (m.path || ''),
			'click': function(ev) {
				var path = ev.currentTarget.getAttribute('data-path');
				if (path === active) { return; }
				ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching to the selected modem…')));
				L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]), {})
					.then(function() { window.location.reload(); });
			}
		}, label(m, i));
	});
	return E('div', { 'class': 'modemtabs-bar' }, tabs);
}

return baseclass.extend({
	/* Шапка: только ряд вкладок выбора модема (если модемов > 1). Имя активного
	   модема показывается заголовком блока «Общая информация» в самой вьюхе.
	   Возвращает Promise<DOM|null>. null - если модем один/нет. */
	renderBar: function() {
		return loadModems().then(function(st) {
			if (st.modems.length <= 1) { return null; }
			ensureCss();
			return E('div', { 'class': 'modembar' }, [ tabsBar(st.modems, st.active) ]);
		});
	},

	/* Только ряд вкладок (для случаев без темы). null, если модемов <= 1. */
	render: function() {
		return loadModems().then(function(st) {
			if (st.modems.length <= 1) { return null; }
			ensureCss();
			return E('div', { 'class': 'modembar' }, [ tabsBar(st.modems, st.active) ]);
		});
	},

	/* Тема-независимая вставка шапки в DOM. Тема proton2025 вставляет её сама
	   (в chrome над под-вкладками); в остальных темах (bootstrap и пр.) шапки
	   не было. Этот метод вызывается КАЖДОЙ вьюхой приложения и:
	     - НЕ дублирует, если .modembar уже есть (случай proton2025);
	     - иначе вставляет ряд вкладок перед меню под-вкладок (в любой теме),
	       а если его нет - в начало основной области.
	   Возвращает Promise. Ставится через опрос DOM, т.к. на момент render()
	   под-вкладки могут быть ещё не вставлены. */
	attach: function() {
		if (document.querySelector('.modembar')) { return Promise.resolve(); }
		return this.renderBar().then(function(bar) {
			if (!bar || document.querySelector('.modembar')) { return; }
			var tries = 0;
			(function place() {
				if (document.querySelector('.modembar')) { return; }
				var anchor = document.querySelector('#tabmenu')
					|| document.querySelector('ul.cbi-tabmenu')
					|| document.querySelector('.cbi-tabmenu');
				if (anchor && anchor.parentNode) {
					anchor.parentNode.insertBefore(bar, anchor);
					return;
				}
				if (tries++ < 20) { window.setTimeout(place, 150); return; }
				var c = document.querySelector('#maincontent') || document.querySelector('#view') || document.body;
				if (c) { c.insertBefore(bar, c.firstChild); }
			})();
		});
	}
});
