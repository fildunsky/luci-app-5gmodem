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
	/* Активную помечаем ровно тем же, что тема даёт кнопке на hover
	   (.cbi-button:hover -> border-color: accent, box-shadow: none).
	   Внутренней обводки inset 0 0 0 1px здесь была - она удваивала рамку,
	   и выделение выглядело жирным. */
	border-color: var(--proton-accent, #0095ff);
	pointer-events: none;
}
/* Карточка теста скорости: та же плитка, но прижата вправо и выровнена по правому
   краю (сервис сверху, скорость по центру, публичный IP снизу). */
.netpribar .netpri-btn.netpri-st { margin-left: auto; align-items: flex-end; text-align: right; }
.netpribar .netpri-st .netpri-st-speed { display: flex; align-items: center; gap: .15em; }
.netpribar .netpri-st .netpri-st-arrow { display: block; width: 11px; height: 11px; flex: 0 0 auto; opacity: .85; }
.netpribar .netpri-st .netpri-st-unit { font-size: .72em; font-weight: 400; opacity: .7; margin-left: .3em; }
/* фаза теста подсвечивает карточку: загрузка - зелёным, отдача - синим. Плавный
   переход цвета + тянущиеся цифры (анимируются в JS), а «идёт тест» показывает
   пульсирующая рамка самой кнопки (см. st-pulse ниже). */
.netpribar .netpri-st { transition: border-color .3s ease, box-shadow .3s ease; }
.netpribar .netpri-st.st-dl { --st-c: #2ea043; }
.netpribar .netpri-st.st-ul { --st-c: #0095ff; }
.netpribar .netpri-st.st-dl, .netpribar .netpri-st.st-ul {
	/* «Идёт тест» = ПУЛЬСИРУЮЩАЯ рамка ПРЯМО на кнопке, без отдельного слоя.
	   Раньше подсветку рисовал ::after (конич. градиент + маска в кольцо), но он
	   позиционировался относительно бокса кнопки и из-за flex-резиновости/box-model
	   не совпадал с её рамкой (тот самый «первый баг»), а правки inset давали то
	   прыжок, то зазор. Тут обводку даёт INSET box-shadow ПО границе самой кнопки -
	   он совпадает с ней по определению, наружу не вылезает, ширину бордюра не
	   трогает (без прыжка) и не зависит ни от темы, ни от раскладки. Толщина
	   плавно ходит 1px<->3px - визуальный «пульс». Цвет рамки красим фазой. */
	border-color: var(--st-c);
	animation: st-pulse 1.1s ease-in-out infinite;
}
@keyframes st-pulse {
	0%, 100% { box-shadow: inset 0 0 0 1px var(--st-c); }
	50%      { box-shadow: inset 0 0 0 3px var(--st-c); }
}
/* стрелка направления пульсирует, пока идёт тест */
.netpribar .netpri-st.st-dl .netpri-st-arrow,
.netpribar .netpri-st.st-ul .netpri-st-arrow { animation: st-blink 1s ease-in-out infinite; }
@keyframes st-blink { 0%, 100% { opacity: .85; } 50% { opacity: .18; } }
/* уважаем системную настройку «меньше движения» */
@media (prefers-reduced-motion: reduce) {
	.netpribar .netpri-st.st-dl, .netpribar .netpri-st.st-ul,
	.netpribar .netpri-st.st-dl .netpri-st-arrow,
	.netpribar .netpri-st.st-ul .netpri-st-arrow { animation: none; }
	.netpribar .netpri-st.st-dl, .netpribar .netpri-st.st-ul { box-shadow: inset 0 0 0 2px var(--st-c); }
}
.netpribar .netpri-st .netpri-st-live { font-variant-numeric: tabular-nums; }
.netpribar .netpri-st .netpri-st-icon { display: block; width: 14px; height: 14px; flex: 0 0 auto; }
/* Мобильная вёрстка: тянущиеся кнопки. Интерфейсы заполняют строку (≈2 в ряд,
   растягиваясь до края блока), а карточка спидтеста уходит на свою строку во всю
   ширину. Тянутся ТОЛЬКО сами кнопки - контейнер и заголовок не трогаем. */
@media (max-width: 680px) {
	/* Базу берём ПО СОДЕРЖИМОМУ (auto), а не фиксированные 42%: с фиксированной
	   базой три кнопки давали 126% и третья переносилась ВСЕГДА, даже когда по
	   ширине все три помещались (два модема + wifi). С auto в строку встаёт
	   столько, сколько реально влезает, а дальше flex-grow растягивает их до
	   края. min-width не даёт кнопке схлопнуться до нечитаемой при длинном имени
	   оператора. */
	.netpribar .netpri-row > .netpri-btn { flex: 1 1 auto; min-width: 7.5em; }
	.netpribar .netpri-row > .netpri-btn.netpri-st { flex: 1 1 100%; margin-left: 0; }
}
`;

var SPEEDBIN = '/usr/share/5gmodem/speedtest.sh';

/* Состояние карточки теста скорости - модульное, чтобы переживать перерисовку
   бара 5-секундным поллом. phase: idle|running|done|fail. */
var _st = { phase: 'idle', service: '', down: null, up: null, ip: '', cc: '', live: 0, liveUp: 0 };

function stArrow(name) {
	return E('img', { 'class': 'netpri-st-arrow', 'src': L.resource('icons/' + name + '.svg'), 'width': 11, 'height': 11, 'alt': '' });
}

/* Emoji-флаг из 2-буквенного кода страны (RU -> 🇷🇺): две regional indicator
   буквы. Пусто, если код не 2 латинские буквы. */
function flagEmoji(cc) {
	cc = String(cc || '').toUpperCase();
	if (!/^[A-Z]{2}$/.test(cc)) { return ''; }
	return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65);
}

/* содержимое средней строки (скорость) по фазе. Во время загрузки показываем
   ЖИВОЕ число (растёт в реальном времени), во время отдачи - готовый download и
   «…» у upload, по готовности - оба числа. */
function stSpeedContent() {
	var sep = function() { return E('span', { 'style': 'opacity:.4; margin:0 .35em;' }, '|'); };
	var unit = function() { return E('span', { 'class': 'netpri-st-unit' }, _('Mbps')); };
	if (_st.phase === 'running') {
		/* показываем ТЕКУЩЕЕ анимированное число (_liveDisplay), чтобы 5-секундная
		   перерисовка бара не сбрасывала его в 0 посреди теста. */
		if (_st.upPhase) {
			var d = (_st.down != null) ? String(_st.down) : '0';
			var lu = (typeof _liveDisplay === 'number' ? _liveDisplay : 0).toFixed(1);
			return [ stArrow('cdown'), E('span', {}, ' ' + d), sep(),
				stArrow('cup'), E('span', { 'class': 'netpri-st-live' }, ' ' + lu), unit() ];
		}
		var lv = (typeof _liveDisplay === 'number' ? _liveDisplay : 0).toFixed(1);
		return [ stArrow('cdown'), E('span', { 'class': 'netpri-st-live' }, ' ' + lv), unit() ];
	}
	if (_st.phase === 'fail') { return [ E('span', {}, _('Test failed')) ]; }
	if (_st.phase === 'done') {
		var dn = (_st.down != null) ? String(_st.down) : '—';
		var up = (_st.up != null) ? String(_st.up) : '—';
		return [ stArrow('cdown'), E('span', {}, ' ' + dn), sep(),
			stArrow('cup'), E('span', {}, ' ' + up), unit() ];
	}
	return [
		E('img', { 'class': 'netpri-st-icon', 'src': L.resource('icons/cspeedtest.svg'), 'width': 14, 'height': 14, 'alt': '' }),
		E('span', {}, ' ' + _('Speed test'))
	];
}

/* три строки карточки: сервис (сверху), скорость (центр), публичный IP (снизу) */
function stCardInner() {
	return [
		E('span', { 'class': 'netpri-sub' }, _st.service || _('Speed test')),
		E('span', { 'class': 'netpri-name netpri-st-speed' }, stSpeedContent()),
		_st.ip ? E('span', { 'class': 'netpri-ip' }, (function() {
			var fl = flagEmoji(_st.cc);
			return fl ? (fl + ' ' + _st.ip) : _st.ip;   // флаг + тонкий пробел + IP
		})())
		       : E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***')
	];
}

function stCard() {
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-st',
		'data-tooltip': _('Measure the real download/upload speed over the modem - a quick way to see whether carrier aggregation is actually working'),
		'click': function() { runSpeedtest(); }
	}, stCardInner());
}

/* перерисовать ТОЛЬКО внутренности карточки (её саму мог пересоздать поллинг
   бара - поэтому ищем актуальную в DOM каждый раз). */
function patchStCard() {
	var card = document.querySelector('.netpri-st');
	if (!card) { return; }
	while (card.firstChild) { card.removeChild(card.firstChild); }
	stCardInner().forEach(function(n) { card.appendChild(n); });
}

/* Плавно «докручиваем» показанное число до target (за ~0.9 c, к следующему тику
   поллинга) - чтобы цифры росли, а не прыгали. */
var _liveDisplay = 0;
var _liveRaf = null;
function animateLive(target) {
	var el = document.querySelector('.netpri-st .netpri-st-live');
	if (!el) { _liveDisplay = target; return; }
	var from = _liveDisplay, to = (target != null ? target : 0), t0 = null, dur = 900;
	if (_liveRaf) { window.cancelAnimationFrame(_liveRaf); }
	var step = function(ts) {
		if (t0 === null) { t0 = ts; }
		var p = Math.min((ts - t0) / dur, 1);
		var v = from + (to - from) * p;
		el.textContent = ' ' + v.toFixed(1);
		_liveDisplay = v;
		if (p < 1) { _liveRaf = window.requestAnimationFrame(step); }
		else { _liveDisplay = to; _liveRaf = null; }
	};
	_liveRaf = window.requestAnimationFrame(step);
}

/* перерисовать карточку с учётом фазы: полный ребилд только при СМЕНЕ фазы
   (иначе анимация числа сбрасывалась бы каждый тик); подсветка зелёным (загрузка)
   / синим (отдача); во время загрузки - тянем живое число. */
var _renderedKey = '';
var _renderedPhase = '';
function refreshStCard() {
	var key = _st.phase + (_st.upPhase ? ':up' : '');
	// IP приходит ДО замеров и появляется посреди фазы running - значит ключ
	// перерисовки должен его учитывать, иначе карточка не обновится до конца теста.
	var full = key + '|' + (_st.ip || '');
	if (full !== _renderedKey) {
		patchStCard();
		_renderedKey = full;
		// счётчик сбрасываем в 0 только на СМЕНЕ ФАЗЫ: приезд IP - не повод
		// ронять уже тикающее живое число обратно к нулю.
		if (key !== _renderedPhase) {
			if (_st.phase === 'running') { _liveDisplay = 0; }
			_renderedPhase = key;
		}
	}
	var card = document.querySelector('.netpri-st');
	if (card) {
		card.classList.toggle('st-dl', _st.phase === 'running' && !_st.upPhase);
		card.classList.toggle('st-ul', _st.phase === 'running' && !!_st.upPhase);
	}
	// анимируем текущее живое число: при отдаче - upload, иначе - download
	if (_st.phase === 'running') { animateLive(_st.upPhase ? (_st.liveUp || 0) : (_st.live || 0)); }
}

function runSpeedtest() {
	if (_st.phase === 'running') { return; }
	_st.phase = 'running'; _st.live = 0; _st.liveUp = 0; _st.upPhase = false;
	_st.down = null; _st.up = null; _st.ip = '';
	_renderedKey = ''; _liveDisplay = 0;
	refreshStCard();
	fs.exec(SPEEDBIN, [ 'start' ]).then(function() {
		var tries = 0;
		var poll = function() {
			return L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
				var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
				if (j.service) { _st.service = j.service; }
				if (j.running) {
					_st.phase = 'running';
					_st.upPhase = (j.phase === 'up');
					if (j.live_down != null) { _st.live = j.live_down; }
					if (j.live_up != null) { _st.liveUp = j.live_up; }
					if (j.down_mbps != null) { _st.down = j.down_mbps; }
					// IP теперь определяется первым - показываем сразу, не дожидаясь цифр
					if (j.pub_ip) { _st.ip = j.pub_ip; }
					if (j.cc) { _st.cc = j.cc; }
					refreshStCard();
					if (tries++ < 45) {   /* ~1 c * 45 - хватает на download+upload+IP */
						return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
					}
				}
				if (j.ok) { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; }
				/* Тест не состоялся по ИЗВЕСТНОЙ причине - называем её. Молчаливый
				   отказ («нажал, ничего не произошло») хуже любой ошибки: человек
				   не знает, чинить ему что-то или ждать. */
				else if (j.error === 'no-curl') {
					_st.phase = 'idle';
					ui.addNotification(null, E('p', _('Speed test needs the curl package: install it with "apk add curl" (or "opkg install curl"). It is not bundled - libcurl is noticeable on routers with 8 MB of flash.')), 'warning');
				}
				else { _st.phase = 'fail'; if (j.pub_ip) { _st.ip = j.pub_ip; _st.cc = j.cc || ''; } }
				_renderedKey = ''; refreshStCard();
			});
		};
		return poll();
	}).catch(function() { _st.phase = 'fail'; _renderedKey = ''; refreshStCard(); });
}

/* подтянуть начальную подпись сервиса и последний результат (если был) */
function stInit() {
	L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j.service) { _st.service = j.service; }
		if (j.ok && _st.phase === 'idle') { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; }
		patchStCard();
	});
}

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
				/* Переключение МГНОВЕННОЕ (живой ip route, без передозвона модема),
				   поэтому попап-спиннер не нужен. Оптимистично подсвечиваем выбранную
				   карточку сразу, затем применяем и перечитываем реальное состояние
				   (метрики уже в uci -> activeIface подсветит верную карточку). */
				var card = ev.currentTarget, row = card.parentNode;
				if (row) { row.querySelectorAll('.netpri-btn.active').forEach(function(b) { b.classList.remove('active'); }); }
				card.classList.add('active');
				L.resolveDefault(fs.exec(BIN, [ 'set', ifc ]), {}).then(function() {
					loadList().then(function(l2) { redraw(l2); });
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
	/* Карточка теста скорости - последним элементом ряда, прижата вправо (CSS
	   margin-left:auto). Строится из модульного _st, поэтому переживает перерисовку. */
	btns.push(stCard());
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
		stInit();   /* подпись сервиса + последний результат теста скорости */
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
			stInit();   /* подпись сервиса + последний результат теста скорости */
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
