'use strict';
'require baseclass';
'require fs';
'require ui';
'require poll';

/*
	«Приоритет интернета» — простой переключатель основного аплинка.

	Показывает ряд кнопок по всем интерфейсам из зоны фаервола 'wan', у которых
	сейчас есть IPv4-адрес (модемы, WAN-порт, Wi-Fi-станция …). Клик делает
	выбранный интерфейс основным: ему задаётся метрика маршрута 1 (побеждает в
	default route), остальным — высокая метрика. Активный подсвечен зелёным.

	Бэкенд: /usr/share/5gmodem/netpri.sh list|set <iface>.
	Вставляется тема-независимо под «шапкой» выбора модема (.modembar) на
	странице «Сеть», методом attach().
*/

var BIN = '/usr/share/5gmodem/netpri.sh';

var CSS = `
.netpribar { margin: 0 0 1em 0; }
.netpribar .netpribar-title {
	font-size: .95em; font-weight: 600; opacity: .8; padding: 0 0 .35em 0;
	display: inline-flex; align-items: center; gap: .35em; cursor: pointer; user-select: none;
}
.netpribar .netpri-chevron { display: inline-flex; transition: transform .15s ease; }
.netpribar:not(.collapsed) .netpri-chevron { transform: rotate(180deg); }
.netpribar.collapsed .netpri-row { display: none; }
.netpribar .netpri-row { display: flex; flex-wrap: wrap; gap: .4em; align-items: stretch; }
.netpribar .netpri-btn {
	padding: .35em 1em; border-radius: 6px; cursor: pointer; font-weight: 600;
	display: flex; flex-direction: column; align-items: flex-start; text-align: left;
	line-height: 1.15;
	/* proton2025 sets "button,.btn{gap:8px}", which on our flex-COLUMN buttons turns
	   into big vertical gaps between the three lines; neutralise it (bootstrap has
	   no such rule, so it already looks tight there). */
	gap: 0;
}
.netpribar .netpri-btn .netpri-sub { font-size: .72em; font-weight: 400; opacity: .7; }
.netpribar .netpri-btn .netpri-name { display: flex; align-items: center; gap: .35em; }
.netpribar .netpri-btn .netpri-ic { display: block; width: 16px; height: 16px; flex: 0 0 auto; }
.netpribar .netpri-btn .netpri-ip { font-size: .78em; font-weight: 400; opacity: .75; font-variant-numeric: tabular-nums; }
.netpribar .netpri-btn .netpri-ip.empty { opacity: .4; }
.netpribar .netpri-btn.active {
	/* keep the normal button look, just mark the active one with the theme's
	   accent outline (not a full fill) */
	border-color: var(--proton-accent, #0095ff);
	box-shadow: inset 0 0 0 1px var(--proton-accent, #0095ff);
	pointer-events: none;
}
`;

function ensureCss() {
	if (!document.getElementById('netpri-css')) {
		document.head.appendChild(E('style', { 'id': 'netpri-css', 'type': 'text/css' }, CSS));
	}
}

function loadList() {
	return L.resolveDefault(fs.exec_direct(BIN, [ 'list' ]), '[]').then(function(out) {
		var arr = [];
		try { arr = JSON.parse(out || '[]') || []; } catch (e) {}
		return Array.isArray(arr) ? arr : [];
	});
}

/* Активным считаем интерфейс с наименьшей метрикой (после set у выбранного это =1,
   поэтому он остаётся выделен даже пока перезванивается без IP). При равной метрике
   предпочитаем тот, у кого есть IP (например Wi-Fi metric 0 с адресом важнее, чем
   неподнятый wan metric 0). */
function activeIface(list) {
	var best = null, bm = Infinity, bip = false;
	list.forEach(function(o) {
		var m = parseInt(o.metric, 10); if (isNaN(m)) { m = 0; }
		var hip = !!o.ip;
		if (m < bm || (m === bm && hip && !bip)) { bm = m; best = o.iface; bip = hip; }
	});
	return best;
}

/* Оператор -> файл иконки (та же таблица, что в главном блоке 5gdetail). */
function operatorIcon(name) {
	var n = (name || '').toLowerCase();
	if (n.indexOf('t-mobile') >= 0 || n.indexOf('tinkoff') >= 0 || n.indexOf('t-bank') >= 0 || n.indexOf('т-мобайл') >= 0 || n.indexOf('т-банк') >= 0 || n.indexOf('t-mob') >= 0) { return 'op-tbank'; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2' || n.indexOf('t2 ') == 0 || n.indexOf(' t2') >= 0) { return 'op-t2'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	return null;
}

/* per-type icon from the app's icon set (modem / Wi-Fi / WAN); null for the rest.
   Для модема - как в главном блоке SIM: иконка ОПЕРАТОРА, если он определён
   (o.label несёт имя оператора), иначе простая SIM-карта (op-sim.png). */
function typeIcon(o) {
	if (o.type === 'modem') {
		var oi = operatorIcon(o.label);
		return E('img', {
			'class': 'netpri-ic', 'src': L.resource('icons/' + (oi ? oi : 'op-sim') + '.png'),
			'width': 16, 'height': 16, 'alt': ''
		});
	}
	var f = (o.type === 'wifi') ? 'cwifi.svg'
	      : (o.type === 'wan')  ? 'cwan.svg'
	      : null;
	if (!f) { return null; }
	return E('img', {
		'class': 'netpri-ic', 'src': L.resource('icons/' + f),
		'width': 16, 'height': 16, 'alt': ''
	});
}

/* disclosure chevron (points down when collapsed, flips up when expanded via CSS) */
function chevron() {
	var s = E('span', { 'class': 'netpri-chevron' });
	s.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor">' +
		'<path d="M7 10l5 5 5-5z"/></svg>';
	return s;
}

function nameEl(o) {
	var txt = o.label || o.iface;
	var ic = typeIcon(o);
	if (ic) { return E('span', { 'class': 'netpri-name' }, [ ic, E('span', {}, txt) ]); }
	return E('span', { 'class': 'netpri-name' }, txt);
}

function buildBar(list, redraw) {
	var active = activeIface(list);
	var btns = list.map(function(o) {
		var isA = (o.iface === active);
		return E('button', {
			'class': 'btn cbi-button netpri-btn' + (isA ? ' active' : ''),
			'data-iface': o.iface,
			'data-tooltip': o.iface + (o.metric != null ? (' · metric ' + o.metric) : ''),
			'click': function(ev) {
				var ifc = ev.currentTarget.getAttribute('data-iface');
				if (ifc === active) { return; }
				ui.showModal(null, E('p', { 'class': 'spinning' },
					_('Switching the primary uplink…')));
				L.resolveDefault(fs.exec(BIN, [ 'set', ifc ]), {}).then(function() {
					/* Выбранный интерфейс уже выделен (metric=1). Модем может пере-
					   набирать соединение и вернуть IP позже — это подхватит постоянный
					   поллинг бара, без перезагрузки страницы. Здесь только быстро
					   убираем модалку и перерисовываем актуальное состояние. */
					window.setTimeout(function() {
						loadList().then(function(l2) { ui.hideModal(); redraw(l2); });
					}, 1200);
				});
			}
		}, [
			E('span', { 'class': 'netpri-sub' }, o.sub || o.iface),
			nameEl(o),
			/* keep the IP line present even without an address so the button height
			   never changes; show a neutral placeholder while there is no IP yet */
			o.ip ? E('span', { 'class': 'netpri-ip' }, o.ip)
			     : E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***')
		]);
	});
	var collapsed = true;
	try { collapsed = (localStorage.getItem('netpri-collapsed') !== '0'); } catch (e) {}
	return E('div', { 'class': 'netpribar' + (collapsed ? ' collapsed' : '') }, [
		E('div', {
			'class': 'netpribar-title',
			'click': function(ev) {
				var b = ev.currentTarget.parentNode;
				var c = b.classList.toggle('collapsed');
				try { localStorage.setItem('netpri-collapsed', c ? '1' : '0'); } catch (e) {}
			}
		}, [ chevron(), E('span', {}, _('Internet priority')) ]),
		E('div', { 'class': 'netpri-row' }, btns)
	]);
}

return baseclass.extend({
	/* Смонтировать блок ВНУТРИ контента страницы (под под-вкладками, как обычный
	   элемент вьюхи). Возвращает контейнер СРАЗУ (синхронно), наполняется асинхронно
	   и живёт своим поллом. Так блок виден на всех темах и на мобильном - в отличие
	   от старой вставки над вкладками, которую мобильная вёрстка прятала. Вставляется
	   самой вьюхой (5gdetail) в начало контента - код проще, без DOM-инъекций. */
	mount: function() {
		ensureCss();
		var wrap = E('div', { 'class': 'netpri-mount' });
		var redraw = function(l2) {
			var fresh = buildBar(l2, redraw);
			if (wrap.firstChild) { wrap.replaceChild(fresh, wrap.firstChild); }
			else { wrap.appendChild(fresh); }
		};
		var apply = function(list) {
			// НЕ убираем блок на пустом ответе: при переключении модема (перезагрузка
			// active_modem) netpri.sh list на миг может вернуть [], и блок мигал/пропадал.
			// Просто перерисовываем при наличии данных; последнее содержимое «липкое».
			if (list && list.length) { redraw(list); }
		};
		L.resolveDefault(loadList()).then(apply);
		/* wrap возвращается СИНХРОННО, а в DOM его вставляет вьюха ПОЗЖЕ. Поэтому
		   «нет в DOM» на первых тиках - это ещё не «блок убрали»: раньше поллер в
		   такой момент снимал сам себя НАВСЕГДА, и блок оставался пустым div'ом -
		   отсюда «Internet priority отрисовывается не всегда». Снимаемся только
		   после того, как блок реально побывал в DOM и оттуда исчез. */
		var seen = false;
		var pollFn = function() {
			if (document.body.contains(wrap)) { seen = true; }
			else if (seen) { poll.remove(pollFn); return Promise.resolve(); }
			return loadList().then(apply);
		};
		poll.add(pollFn, 5);
		return wrap;
	},

	/* Promise<DOM|null>. null — если ни одного WAN-аплинка с IP нет. */
	renderBar: function() {
		return loadList().then(function(list) {
			if (!list.length) { return null; }
			ensureCss();
			var wrap = E('div');
			var redraw = function(l2) {
				var fresh = buildBar(l2, redraw);
				if (wrap.firstChild) { wrap.replaceChild(fresh, wrap.firstChild); }
				else { wrap.appendChild(fresh); }
			};
			redraw(list);
			/* Keep the bar live with a steady poll: the operator name (bounded
			   AT+COPS in the background) resolves after a few seconds, and — the
			   point here — a modem's IP that comes back AFTER re-dialing (which can
			   take much longer than a fixed retry window) shows up on its own, with
			   no manual page reload. Self-removes once the bar leaves the DOM. */
			var pollFn = function() {
				if (!document.body.contains(wrap)) { poll.remove(pollFn); return Promise.resolve(); }
				return loadList().then(redraw);
			};
			poll.add(pollFn, 5);
			return wrap;
		});
	},

	/* Тема-независимая вставка под .modembar (или перед под-вкладками). */
	attach: function() {
		if (document.querySelector('.netpribar')) { return Promise.resolve(); }
		return this.renderBar().then(function(bar) {
			if (!bar || document.querySelector('.netpribar')) { return; }
			var tries = 0;
			(function place() {
				if (document.querySelector('.netpribar')) { return; }
				var mb = document.querySelector('.modembar');
				if (mb && mb.parentNode) { mb.parentNode.insertBefore(bar, mb.nextSibling); return; }
				var anchor = document.querySelector('#tabmenu')
					|| document.querySelector('ul.cbi-tabmenu')
					|| document.querySelector('.cbi-tabmenu');
				if (anchor && anchor.parentNode) { anchor.parentNode.insertBefore(bar, anchor); return; }
				if (tries++ < 20) { window.setTimeout(place, 150); return; }
				var c = document.querySelector('#maincontent') || document.querySelector('#view') || document.body;
				if (c) { c.insertBefore(bar, c.firstChild); }
			})();
		});
	}
});
