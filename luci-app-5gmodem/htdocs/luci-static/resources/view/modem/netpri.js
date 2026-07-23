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
/* proton2025 добавляет ".btn+.btn{margin-left:8px}" между соседними кнопками -
   поверх gap:.4em ряда. Из-за этого промежуток МЕЖДУ интерфейсными кнопками
   шире (.4em+8px), чем между ssclash и спидтестом (там margin-left переопределён,
   остаётся только .4em). Снимаем добавку с интерфейсных кнопок, чтобы ВСЕ
   промежутки были ровно gap ряда. margin-left:auto у ssclash/спидтеста (правое
   выравнивание) при этом не трогаем - их из правила исключаем. */
.netpribar .netpri-row > .netpri-btn:not(.netpri-st):not(.netpri-ssclash) { margin-left: 0; }
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
/* Фаза теста ЗАЛИВАЕТ ФОН кнопки как прогресс-бар: загрузка - полупрозрачным
   зелёным, отдача - синим. Ширина заливки = доля прошедшего времени фазы
   (--st-p ставит JS по elapsed/secs). Заменило пульсирующую рамку: прогресс
   честнее и не зависит от box-model. Заливку кладёт ::before ПОД контентом,
   overflow:hidden обрезает её по скруглению кнопки. */
.netpribar .netpri-st { position: relative; overflow: hidden; transition: border-color .3s ease; }
.netpribar .netpri-st.st-dl { --st-c: #2ea043; }
.netpribar .netpri-st.st-ul { --st-c: #0095ff; }
.netpribar .netpri-st.st-dl, .netpribar .netpri-st.st-ul { border-color: var(--st-c); }
.netpribar .netpri-st.st-dl::before, .netpribar .netpri-st.st-ul::before {
	content: ''; position: absolute; left: 0; top: 0; bottom: 0;
	width: var(--st-p, 0%);
	background: var(--st-c); opacity: .16;
	transition: width .25s linear;   /* сглаживаем дискретные тики JS */
	pointer-events: none; z-index: 0;
}
/* Отдача заполняется В ДРУГУЮ СТОРОНУ - справа налево: якорим заливку к правому
   краю (это симметрично «стрелке вверх» и визуально отличает фазу от загрузки). */
.netpribar .netpri-st.st-ul::before { left: auto; right: 0; }
/* контент - НАД заливкой (::before позиционирован, поэтому детей поднимаем) */
.netpribar .netpri-st > * { position: relative; z-index: 1; }
/* стрелка направления пульсирует, пока идёт тест */
.netpribar .netpri-st.st-dl .netpri-st-arrow,
.netpribar .netpri-st.st-ul .netpri-st-arrow { animation: st-blink 1s ease-in-out infinite; }
@keyframes st-blink { 0%, 100% { opacity: .85; } 50% { opacity: .18; } }
/* уважаем системную настройку «меньше движения» */
@media (prefers-reduced-motion: reduce) {
	.netpribar .netpri-st.st-dl .netpri-st-arrow,
	.netpribar .netpri-st.st-ul .netpri-st-arrow { animation: none; }
	.netpribar .netpri-st.st-dl::before, .netpribar .netpri-st.st-ul::before { transition: none; }
}
.netpribar .netpri-st .netpri-st-live { font-variant-numeric: tabular-nums; }
/* Ширину НЕ фиксируем: кнопка растёт под большое число, текст не вылезает.
   tabular-nums держит цифры ровными при живом счёте; dim - плейсхолдер «0.0». */
.netpribar .netpri-st .netpri-st-num { font-variant-numeric: tabular-nums; }
.netpribar .netpri-st .netpri-st-num.dim { opacity: .35; }
.netpribar .netpri-st .netpri-st-icon { display: block; width: 14px; height: 14px; flex: 0 0 auto; }
/* Кнопка SSClash-Go - 3-строчная КАРТОЧКА как модемные (версия / имя+значок /
   IP), поэтому спец-раскладку не задаём: наследует .netpri-btn (колонка, слева).
   Правое выравнивание уходит на неё, спидтест встаёт вплотную справа. */
/* Содержимое по ПРАВОМУ краю - как у спидтеста рядом (версия и IP справа,
   пара карточек симметрична). */
.netpribar .netpri-btn.netpri-ssclash { align-items: flex-end; text-align: right; }
/* Значок в фирменном «чипе», как .brand-mark на странице SSClash: скруглённый
   бокс с лёгкой серой плашкой и тонкой рамкой. Фон и рамку вяжем к currentColor
   (= цвет текста кнопки), поэтому на светлой теме это лёгкий серый, а не тёмное
   пятно, а на тёмной - светлый полупрозрачный патч, как в оригинале. Значок тоже
   наследует цвет текста и адаптируется к теме. */
.netpribar .netpri-ssclash .netpri-ssclash-ic {
	display: inline-flex; align-items: center; justify-content: center;
	/* Ровно как плоские иконки блока (.netpri-ic = 16px): вклад в высоту строки
	   тот же, отрицательные поля не нужны, строки карточки совпадают со всеми. */
	flex: 0 0 auto; width: 16px; height: 16px;
	border-radius: 4px;
	/* Фиксированная серая плашка со светлым значком - точные цвета как под
	   иконкой на оригинальной странице SSClash (одинаково в обеих темах). */
	background: #3d4144;
	border: 1px solid #565a5d;
	color: #e8eef2;
}
.netpribar .netpri-ssclash .netpri-ssclash-ic svg { display: block; width: 11px; height: 11px; }
.netpribar .netpri-row.has-ssclash .netpri-ssclash { margin-left: auto; }
.netpribar .netpri-row.has-ssclash .netpri-st { margin-left: 0; }
@media (max-width: 680px) {
	/* на узком экране кнопка тянется, как модемные; спидтест уходит на свою строку */
	.netpribar .netpri-row.has-ssclash .netpri-ssclash { margin-left: 0; }
}
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
	/* Спидтест на СВОЮ строку (flex-basis 100%) - только когда ssclash-кнопки НЕТ.
	   С ssclash они пара (flex:1 1 auto каждая): встают на одну строку, когда
	   влезают, и переносятся вместе, когда нет. */
	.netpribar .netpri-row:not(.has-ssclash) > .netpri-btn.netpri-st { flex: 1 1 100%; margin-left: 0; }
}
`;

var SPEEDBIN = '/usr/share/5gmodem/speedtest.sh';

/* Состояние карточки теста скорости - модульное, чтобы переживать перерисовку
   бара 5-секундным поллом. phase: idle|running|done|fail. */
var _st = { phase: 'idle', service: '', down: null, up: null, ip: '', cc: '', live: 0, liveUp: 0, secs: 15, phaseStart: 0 };

/* Заливка-прогресс: доля прошедшего времени ФАЗЫ (elapsed/secs) -> --st-p.
   secs = потолок фазы (curl --max-time), приходит из speedtest.sh. Тикаем чаще
   поллинга (200 мс) - CSS transition на ::before доводит плавно. */
var _stProgTimer = null;
function setStProgress() {
	var card = document.querySelector('.netpri-st');
	if (!card) { return; }
	if (_st.phase !== 'running' || !_st.phaseStart || !_st.secs) { card.style.removeProperty('--st-p'); return; }
	var pct = (Date.now() - _st.phaseStart) / (_st.secs * 1000) * 100;
	if (pct < 0) { pct = 0; } if (pct > 100) { pct = 100; }
	card.style.setProperty('--st-p', pct.toFixed(1) + '%');
}
function stProgStart() { if (!_stProgTimer) { _stProgTimer = window.setInterval(setStProgress, 200); } }
function stProgStop() { if (_stProgTimer) { window.clearInterval(_stProgTimer); _stProgTimer = null; } setStProgress(); }

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
	/* Число в ФИКСИРОВАННОМ слоте. dim=true - плейсхолдер (значение ещё не
	   измерено): показываем «000.0» приглушённым, чтобы ширина кнопки была той
	   же, что и с реальными числами, и старт теста её не расширял. live=true -
	   слот живого числа (его докручивает animateLive по .netpri-st-live). */
	var num = function(v, dim, live) {
		var cls = 'netpri-st-num' + (dim ? ' dim' : '') + (live ? ' netpri-st-live' : '');
		var txt = live ? (typeof _liveDisplay === 'number' ? _liveDisplay : 0).toFixed(1)
		               : (v != null ? String(v) : '0.0');
		return E('span', { 'class': cls }, txt);
	};
	/* Число + стрелка ВПЛОТНУЮ: стрелку ставим ПОСЛЕ цифры и группируем в
	   inline-flex с gap:0 - иначе flex-gap строки скорости (.15em) дал бы зазор
	   между ними (как было, когда стрелка стояла перед числом). */
	var pair = function(node, arrow) {
		return E('span', { 'style': 'display:inline-flex; align-items:center; gap:.15em' }, [ node, stArrow(arrow) ]);
	};

	if (_st.phase === 'fail') { return [ E('span', {}, _('Test failed')) ]; }

	/* Единая двухчисловая раскладка ВЕЗДЕ (покой/загрузка/отдача/готово) - ширина
	   кнопки постоянна. Живое число - в текущей фазе, второе - последнее
	   известное или плейсхолдер. */
	var running = (_st.phase === 'running');
	var dlDim, dlNode, ulDim, ulNode;
	if (running && !_st.upPhase) {          // фаза загрузки: DL живой, UL плейсхолдер
		dlNode = num(null, false, true);
		ulNode = num(_st.up, true, false);
	} else if (running && _st.upPhase) {    // фаза отдачи: DL готов, UL живой
		dlNode = num(_st.down, _st.down == null, false);
		ulNode = num(null, false, true);
	} else if (_st.phase === 'done') {      // готово: оба реальные
		dlNode = num(_st.down, _st.down == null, false);
		ulNode = num(_st.up, _st.up == null, false);
	} else {                                 // покой: оба плейсхолдеры
		dlNode = num(null, true, false);
		ulNode = num(null, true, false);
	}
	return [ pair(dlNode, 'cdown'), sep(), pair(ulNode, 'cup'), unit() ];
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
		el.textContent = v.toFixed(1);
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
			if (_st.phase === 'running') { _liveDisplay = 0; _st.phaseStart = Date.now(); }
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
	setStProgress();
}

function runSpeedtest() {
	if (_st.phase === 'running') { return; }
	_st.phase = 'running'; _st.live = 0; _st.liveUp = 0; _st.upPhase = false;
	_st.down = null; _st.up = null; _st.ip = '';
	_st.phaseStart = Date.now();
	_renderedKey = ''; _liveDisplay = 0;
	refreshStCard();
	stProgStart();
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
						if (j.secs != null) { _st.secs = j.secs; }
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
				_renderedKey = ''; stProgStop(); refreshStCard();
			});
		};
		return poll();
	}).catch(function() { _st.phase = 'fail'; _renderedKey = ''; stProgStop(); refreshStCard(); });
}

/* подтянуть начальную подпись сервиса и последний результат (если был) */
/* SSClash-Go: если сервис есть, слева от спидтеста показываем кнопку на его
   веб-админку. Детект (наличие/порт/схема) - в ssclash.sh. Пробуем ОДИН раз;
   при находке дёргаем redraw, чтобы кнопка появилась без ожидания следующего
   тика поллинга. */
var _ssclash = { present: false, port: 9091, scheme: 'http', version: '' };
/* Warm-seed из localStorage: с ним кнопка SSClash есть уже В ПЕРВОМ КАДРЕ
   warm-render'а (см. lastList), а не «выпрыгивает» после детекта. Детект ниже
   лишь подтверждает: сервис пропал - кнопка уберётся и из кэша, и с экрана. */
try {
	var _sscSeed = JSON.parse(window.localStorage.getItem('netpri-ssclash') || 'null');
	if (_sscSeed && _sscSeed.present) { _ssclash = _sscSeed; }
} catch (e) {}
var _ssclashProbed = false;
function ssclashInit(redraw) {
	if (_ssclashProbed) { return; }
	_ssclashProbed = true;
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/ssclash.sh', [ 'detect' ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j && j.present) {
			_ssclash = { present: true, port: (j.port || 9091), scheme: (j.scheme || 'http'), version: (j.version || '') };
			try { window.localStorage.setItem('netpri-ssclash', JSON.stringify(_ssclash)); } catch (e) {}
			if (typeof redraw === 'function') { loadList().then(function(l) { redraw(l); }); }
		} else {
			var _had = _ssclash.present;
			_ssclash = { present: false, port: 9091, scheme: 'http', version: '' };
			try { window.localStorage.removeItem('netpri-ssclash'); } catch (e) {}
			/* Кнопка была нарисована из кэша, а сервис удалили - перерисовать без неё. */
			if (_had && typeof redraw === 'function') { loadList().then(function(l) { redraw(l); }); }
		}
	});
}

/* Кнопка-ссылка на админку SSClash-Go (новое окно). Хост берём из адресной
   строки (тот же, на котором открыт LuCI), порт/схему - из детекта. */
/* Фирменный значок SSClash-Go (brand-mark с его страницы): два связанных узла.
   На currentColor - подхватит цвет текста кнопки. */
var SSCLASH_ICON = '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true">' +
	'<path d="M6 7.5c0 3 2.5 4.5 6 4.5s6 1.5 6 4.5M18 16.5c0-3-2.5-4.5-6-4.5S6 10.5 6 7.5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>' +
	'<circle cx="6" cy="7.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="7.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="6" cy="16.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/>' +
	'<circle cx="18" cy="16.5" r="1.85" fill="currentColor" fill-opacity=".22" stroke="currentColor" stroke-width="1.75"/></svg>';
function ssClashBtn() {
	var host = window.location.hostname;
	var url = _ssclash.scheme + '://' + host + ':' + _ssclash.port + '/';
	var ic = E('span', { 'class': 'netpri-ssclash-ic' });
	ic.innerHTML = SSCLASH_ICON;
	/* Три строки, как у карточек «Приоритета интернета»: версия сверху, имя с
	   значком по центру, IP роутера снизу (совпадает с целью ссылки). */
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-ssclash',
		'data-tooltip': _('Open the SSClash-Go admin panel in a new tab'),
		'click': function() { window.open(url, '_blank', 'noopener'); }
	}, [
		E('span', { 'class': 'netpri-sub' }, _ssclash.version || 'SSClash-Go'),
		E('span', { 'class': 'netpri-name' }, [ ic, E('span', {}, 'SSClash') ]),
		E('span', { 'class': 'netpri-ip' }, host)
	]);
}

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
		arr = Array.isArray(arr) ? arr : [];
		/* Последний непустой список - в localStorage: из него блок рисуется
		   МГНОВЕННО при следующем открытии (warm-render в mount/renderBar),
		   не дожидаясь этого XHR. Иначе панель появлялась через ~0.4 c НАД
		   уже нарисованным блоком «Модем» и сдвигала его рывком. */
		if (arr.length) {
			try { window.localStorage.setItem('netpri-last', JSON.stringify(arr)); } catch (e) {}
		}
		return arr;
	});
}

/* Последний сохранённый список (может быть устаревшим - живой опрос его тут же
   освежит) либо []. */
function lastList() {
	try {
		var a = JSON.parse(window.localStorage.getItem('netpri-last') || '[]');
		return Array.isArray(a) ? a : [];
	} catch (e) { return []; }
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
	/* Кнопка SSClash-Go (если сервис есть) - СЛЕВА от спидтеста. Правое
	   выравнивание (margin-left:auto) при этом уходит на неё, а спидтест встаёт
	   вплотную справа: ряд помечаем классом has-ssclash (см. CSS). */
	if (_ssclash.present) { btns.push(ssClashBtn()); }
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
		E('div', { 'class': 'netpri-row' + (_ssclash.present ? ' has-ssclash' : '') }, btns)
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
			/* Ряд пересоздан - карточка теста НОВАЯ и без класса фазы/--st-p.
			   Возвращаем визуал теста сразу, иначе заливка мигала бы на каждый
			   5-секундный тик поллинга (класс/переменная терялись до след. тика). */
			refreshStCard();
		};
		var apply = function(list) {
			// НЕ убираем блок на пустом ответе: при переключении модема (перезагрузка
			// active_modem) netpri.sh list на миг может вернуть [], и блок мигал/пропадал.
			// Просто перерисовываем при наличии данных; последнее содержимое «липкое».
			if (list && list.length) { redraw(list); }
		};
		/* WARM-RENDER: последний список из localStorage встаёт в ПЕРВЫЙ КАДР -
		   блок сразу правильной высоты, кнопки на местах; свежий ответ ниже
		   лишь обновит содержимое НА МЕСТЕ, без сдвига страницы. */
		apply(lastList());
		L.resolveDefault(loadList()).then(apply);
		stInit();   /* подпись сервиса + последний результат теста скорости */
		ssclashInit(redraw);
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
		var mk = function(list) {
			ensureCss();
			var wrap = E('div');
			var redraw = function(l2) {
				var fresh = buildBar(l2, redraw);
				if (wrap.firstChild) { wrap.replaceChild(fresh, wrap.firstChild); }
				else { wrap.appendChild(fresh); }
				/* см. mount(): возвращаем визуал теста после пересоздания ряда,
				   иначе заливка мигает на каждый тик поллинга. */
				refreshStCard();
			};
			redraw(list);
			stInit();   /* подпись сервиса + последний результат теста скорости */
			ssclashInit(redraw);
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
			return { wrap: wrap, redraw: redraw };
		};
		/* WARM-RENDER: последний список из localStorage - бар отдаётся сразу
		   (вставка не сдвинет контент позже), свежий ответ обновит его НА
		   МЕСТЕ. Кэша нет - прежнее поведение (ждём список, null если пусто). */
		var cached = lastList();
		if (cached.length) {
			var b = mk(cached);
			loadList().then(function(l) { if (l && l.length) { b.redraw(l); } });
			return Promise.resolve(b.wrap);
		}
		return loadList().then(function(list) {
			if (!list.length) { return null; }
			return mk(list).wrap;
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
