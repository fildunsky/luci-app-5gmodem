'use strict';
'require baseclass';
'require view.modem5g.mutil as mutil';
'require view.modem5g.extip as extip';
'require view.modem5g.healthform as healthform';
'require fs';
'require ui';
'require uci';
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

/* Видимость виджетов блока (настройки «Виджеты»). Все включены по умолчанию:
   скрываем, только если значение явно '0'. Флаги подгружаются из uci перед
   отрисовкой (loadWidgetFlags). */
/* Мастер-флаги групп (вкл/выкл целиком). Внутри групп сами карточки задаются
   секциями pingwidget / svcwidget (можно добавить сколько угодно). */
var _widgets = { netpri: true, status: true, services: true, speedtest: true };
/* Номер приоритета фоном на карточке - отдельная галка, по умолчанию ВЫКЛЮЧЕНА
   (в отличие от мастер-флагов виджетов, которые по умолчанию включены). */
/* Режим фона карточек аплинков: '' - выкл, 'num' - номер, 'icon' - иконка. */
var _netpriRank = '';
/* Порядок правых виджетов: ключи p:<хост> / s:<служба> / speed. Пусто - порядок
   по умолчанию (пинги, службы, спидтест). */
var _widgetOrder = [];
var _pingWidgets = [];   /* [{host, mode}] */
var _svcWidgets = [];    /* ['ssclash', ...] - сервисы из секций svcwidget */
function loadWidgetFlags() {
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		function on(k) { return uci.get('5gmodem', '@5gmodem[0]', k) !== '0'; }
		_widgets.netpri    = on('widget_netpri');
		_widgets.status    = on('widget_status');
		_widgets.services  = on('widget_services');
		_widgets.speedtest = on('widget_speedtest');
		var _nrv = uci.get('5gmodem', '@5gmodem[0]', 'netpri_rank');
		_netpriRank = (_nrv === '1') ? 'num' : (_nrv === 'icon') ? 'icon' : '';
		/* Порядок правых карточек, заданный перетаскиванием (netpri.sh worder). */
		_widgetOrder = String(uci.get('5gmodem', '@5gmodem[0]', 'widget_order') || '').split(/\s+/).filter(Boolean);
		/* Карточки берём ТОЛЬКО из секций. Умолчания (YouTube, SSClash) заведены
		   реальными секциями при установке (uci-defaults/seed_widgets.sh), поэтому
		   видны и правятся в настройках; удалил все - значит пусто, без «магии». */
		_pingWidgets = (uci.sections('5gmodem', 'pingwidget') || []).map(function(s) {
			return { host: String(s.host || '').trim(), mode: s.mode || 'click' };
		}).filter(function(w) { return !!w.host; });
		_svcWidgets = (uci.sections('5gmodem', 'svcwidget') || []).map(function(s) {
			return String(s.service || '').trim();
		}).filter(function(v) { return !!v; });
	});
}
function effectiveSvcs() { return _svcWidgets; }

/* Состояние пингов по ХОСТУ (несколько карточек). warm-seed из localStorage. */
var _pingState = {};
try { _pingState = JSON.parse(window.localStorage.getItem('netpri-pingstate') || '{}') || {}; } catch (e) {}
/* Состояние сервисов по ИМЕНИ (running: true/false/undefined). */
var _svcState = {};

/* Фирменная иконка YouTube (красный «плей») - как было, выглядит аккуратнее
   плашки с глифом. */
var YT_ICON = '<svg viewBox="0 0 24 24" aria-hidden="true">' +
	'<rect x="2" y="4.5" width="20" height="15" rx="4.2" fill="#FF0000"/>' +
	'<path d="M10 8.5l6 3.5-6 3.5z" fill="#fff"/></svg>';
/* Пресеты сервисов пинга: имя + иконка. svg - инлайн-SVG; img - файл из icons/5gmodem/
   (рисуется на белой плашке, поэтому монохромный тёмный octocat github.svg виден
   и на светлой, и на тёмной теме); иначе цветная плашка с глифом (glyph+color).
   Свой хост - молния ⚡. */
var PING_PRESETS = {
	'youtube.com':    { name: 'YouTube',    svg: YT_ICON },
	/* Telegram проверяется НЕ пингом: ICMP до его серверов не ходит, а домен в
	   РФ ещё и подменяют на резолвере. Бэкенд для этого хоста идёт особым
	   путём - сверяет адрес с официальным списком сетей и стучится в 443. */
	'api.telegram.org': { name: 'Telegram', img: 'tg.svg', plain: true },
	'github.com':     { name: 'GitHub',     img: 'github.svg' },
	'google.com':     { name: 'Google',     color: '#4285F4', glyph: 'G' },
	'cloudflare.com': { name: 'Cloudflare', color: '#F38020', glyph: '☁' },
	'yandex.ru':      { name: 'Yandex',     color: '#FF3B30', glyph: 'Я' }
};
function pingInfo(host) {
	host = String(host || 'youtube.com').trim();
	var p = PING_PRESETS[host.toLowerCase()];
	if (p) { return { host: host, name: p.name, color: p.color, glyph: p.glyph, svg: p.svg, img: p.img, plain: p.plain, custom: false }; }
	return { host: host, name: host, color: null, glyph: '⚡', custom: true };
}

var SPEEDBIN = '/usr/share/5gmodem/speedtest.sh';

/* Состояние карточки теста скорости - модульное, чтобы переживать перерисовку
   бара 5-секундным поллом. phase: idle|running|done|fail. */
var _st = { phase: 'idle', service: '', down: null, up: null, ip: '', cc: '', live: 0, liveUp: 0, secs: 15, phaseStart: 0, hasData: false, elapsed: null, elapsedAt: 0 };

/* Заливка-прогресс: доля прошедшего времени ФАЗЫ (elapsed/secs) -> --st-p.
   ДВЕ честности сразу (запрос владельца - «полоса ползёт, а цифры 0»):
   1) полоса появляется ТОЛЬКО когда пошли реальные цифры (hasData) - до того
      карточка пульсирует рамкой цветом фазы (класс st-wait, CSS);
   2) отсчёт берём НЕ от клика, а из elapsed БЭКЕНДА (сколько секунд фаза
      реально идёт от старта curl) + доводка часами между поллами - на
      медленном коннекте полоса раньше стартовала с клика и «убегала» от
      замера, кончаясь на середине цифр. secs = потолок фазы (curl --max-time).
   Тикаем чаще поллинга (200 мс) - CSS transition на ::before доводит плавно. */
var _stProgTimer = null;
function setStProgress() {
	var card = document.querySelector('.netpri-st');
	if (!card) { return; }
	if (_st.phase !== 'running' || !_st.secs || !_st.hasData || _st.elapsed == null) {
		card.style.removeProperty('--st-p'); return;
	}
	var ms = _st.elapsed * 1000 + (Date.now() - _st.elapsedAt);
	var pct = ms / (_st.secs * 1000) * 100;
	if (pct < 0) { pct = 0; } if (pct > 100) { pct = 100; }
	card.style.setProperty('--st-p', pct.toFixed(1) + '%');
}
function stProgStart() { if (!_stProgTimer) { _stProgTimer = window.setInterval(setStProgress, 200); } }
function stProgStop() { if (_stProgTimer) { window.clearInterval(_stProgTimer); _stProgTimer = null; } setStProgress(); }

function stArrow(name) {
	/* Направление в классе: по нему CSS пульсирует свечением ТОЛЬКО ту стрелку,
	   чья фаза идёт (cdown = загрузка -> st-arrow-dl, cup = отдача -> st-arrow-ul). */
	var dir = (name === 'cdown') ? ' st-arrow-dl' : (name === 'cup') ? ' st-arrow-ul' : '';
	return E('img', { 'class': 'netpri-st-arrow' + dir, 'src': L.resource('icons/5gmodem/' + name + '.svg'), 'width': 11, 'height': 11, 'alt': '' });
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
		_st.ip ? E('span', {
			'class': 'netpri-ip',
			/* Адрес НЕ публичный - показан адрес самого модема (внешний узнать не
			   удалось: с сотовой в РФ ip-сервисы часто недоступны). Помечаем, иначе
			   CGNAT-адрес оператора (10.x) читается как настоящий «белый IP». */
			'style': _st.ipLocal ? 'opacity:.55;font-style:italic' : null,
			'data-tooltip': _st.ipLocal ? _('Modem address, not external') : null
		}, (function() {
			if (_st.ipLocal) { return _st.ip; }
			var fl = mutil.flagEmoji(_st.cc);
			return fl ? (fl + ' ' + _st.ip) : _st.ip;   // флаг + тонкий пробел + IP
		})())
		       : E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***')
	];
}

function stCard() {
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-st',
		'data-wkey': 'speed',
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
		/* Фаза идёт, но реальных цифр ещё нет (DNS/коннект/разгон TCP) - кнопка
		   пульсирует рамкой цвета фазы; полосы в этот момент нет вовсе. */
		card.classList.toggle('st-wait', _st.phase === 'running' && !_st.hasData);
	}
	// анимируем текущее живое число: при отдаче - upload, иначе - download
	if (_st.phase === 'running') { animateLive(_st.upPhase ? (_st.liveUp || 0) : (_st.live || 0)); }
	setStProgress();
}

function runSpeedtest() {
	if (_st.phase === 'running') {
		/* Повторный клик по карточке во время теста = ОСТАНОВИТЬ и вернуть
		   карточку в исходный вид. Флаг stopping читает идущий poll: какой бы
		   финальный JSON ни пришёл (cancelled, ok с частичным результатом,
		   ошибка от убитого curl) - показываем ДЕФОЛТ, а не «Ошибка теста». */
		_st.stopping = true;
		fs.exec(SPEEDBIN, [ 'stop' ]);
		return;
	}
	_st.phase = 'running'; _st.live = 0; _st.liveUp = 0; _st.upPhase = false;
	_st.down = null; _st.up = null; _st.ip = ''; _st.ipLocal = false;
	_st.hasData = false; _st.elapsed = null;
	_st.phaseStart = Date.now();
	_renderedKey = ''; _liveDisplay = 0;
	refreshStCard();
	stProgStart();
	/* start НЕ сторожим и полл НЕ подвешиваем на его завершение. Живой случай:
	   rpcd занят другими поллерами страницы, XHR запуска висел ~19 c - карточка
	   всё это время пульсировала без единой цифры, потом catch показал «Ошибка
	   теста», хотя скрипт давно отработал и результат лежал в кэше. Поэтому
	   опрос статуса стартует сразу и сам разбирается, когда бэкенд оживёт;
	   протухший финал прошлого теста он отличает по снимку staleFinal. Отказ
	   самого XHR глотаем - о судьбе теста честнее расскажет опрос. */
	_st.staleFinal = _st.lastStatusRaw || '';
	fs.exec(SPEEDBIN, [ 'start' ]).catch(function() {});
	stPoll(true);
}

/* Опрос идущего теста. Вынесен из runSpeedtest, чтобы stInit мог ПОДХВАТИТЬ
   тест, запущенный до перехода на другую страницу: раньше вернувшийся
   пользователь видел карточку в покое, а результат - только после конца. */
function stPoll(expectStart) {
	var tries = 0, misses = 0, sawRunning = !expectStart;
	var poll = function() {
		return L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
			/* Стоп нажат: не ждём финального JSON бэкенда (1-3 c) - сбрасываем
			   карточку в дефолт на ПЕРВОМ же тике и прекращаем опрос. */
			if (_st.stopping) {
				_st.stopping = false;
				_st.phase = 'idle';
				_st.down = null; _st.up = null;
				_st.live = 0; _st.liveUp = 0; _st.upPhase = false;
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			if (out) { _st.lastStatusRaw = out; }
			var j = null; try { j = JSON.parse(out || ''); } catch (e) { j = null; }
			/* start ещё НЕ ДОЕХАЛ до роутера (его XHR стоит в очереди rpcd), а в
			   кэше лежит финал ПРОШЛОГО теста - он побайтово равен снимку на
			   момент клика (все финалы несут ts, двух одинаковых не бывает).
			   Это не исход нашего теста - ждём, пока появится свежий статус. */
			if (!sawRunning && j && !j.running && out === _st.staleFinal) {
				if (tries++ < 30) {
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
				_st.phase = 'fail';
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			/* ТРАНСПОРТНЫЙ СБОЙ ОДНОГО ТИКА - НЕ ПРОВАЛ ТЕСТА. exec_direct ходит
			   через cgi-io, и занятый rpcd/оборванный XHR изредка возвращает
			   пусто; бэкенд при этом живёт и пишет статус в файл (проверено:
			   опрос самого скрипта каждые 0.3 c за весь тест не дал ни одного
			   пустого ответа). Раньше единственный такой тик показывал «Ошибка
			   теста», а результат «внезапно» находился при следующем заходе на
			   страницу. Держим текущий вид и пробуем ещё; сдаёмся после 4 подряд. */
			if (!j || (j.running == null && j.ok == null && !j.cancelled && !j.error)) {
				if (++misses <= 4 && tries++ < 70) {
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
				_st.phase = 'fail';
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			misses = 0;
			if (j.service) { _st.service = j.service; }
			if (j.running) {
				sawRunning = true;
				_st.phase = 'running';
				var wasUp = _st.upPhase;
				_st.upPhase = (j.phase === 'up');
				/* Смена фазы (загрузка -> отдача) - ожидание данных начинается
				   заново: у отдачи свой коннект и свой первый POST. */
				if (wasUp !== _st.upPhase) { _st.hasData = false; _st.elapsed = null; }
				if (j.live_down != null) { _st.live = j.live_down; }
				if (j.live_up != null) { _st.liveUp = j.live_up; }
					if (j.secs != null) { _st.secs = j.secs; }
				if (j.elapsed != null) { _st.elapsed = +j.elapsed; _st.elapsedAt = Date.now(); }
				/* Реальные цифры пошли - с этого тика включается полоса. */
				if (+(_st.upPhase ? _st.liveUp : _st.live) > 0) { _st.hasData = true; }
				if (j.down_mbps != null) { _st.down = j.down_mbps; }
				// IP теперь определяется первым - показываем сразу, не дожидаясь цифр
				if (j.pub_ip) { _st.ip = j.pub_ip; }
					if (j.ip_local != null) { _st.ipLocal = (j.ip_local == 1); }
				if (j.cc) { _st.cc = j.cc; }
				refreshStCard();
				if (tries++ < 70) {   /* ~1 c * 70 - download+upload+переходы с запасом */
					return new Promise(function(r) { window.setTimeout(function() { poll().then(r); }, 1000); });
				}
			}
			/* Пользователь остановил тест: полный сброс к дефолтному виду,
			   что бы ни пришло в финальном JSON (решение владельца). */
			if (_st.stopping || j.cancelled) {
				_st.stopping = false;
				_st.phase = 'idle';
				_st.down = null; _st.up = null;
				_st.live = 0; _st.liveUp = 0; _st.upPhase = false;
				_renderedKey = ''; stProgStop(); refreshStCard();
				return;
			}
			if (j.ok) { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; _st.ipLocal = (j.ip_local == 1); }
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
}

/* подтянуть начальную подпись сервиса и последний результат (если был) */
/* SSClash-Go: если сервис есть, слева от спидтеста показываем кнопку на его
   веб-админку. Детект (наличие/порт/схема) - в ssclash.sh. Пробуем ОДИН раз;
   при находке дёргаем redraw, чтобы кнопка появилась без ожидания следующего
   тика поллинга. */
/* ДВЕ НЕЗАВИСИМЫЕ ветки SSClash, каждая - своя карточка (могут стоять обе сразу:
   5.x нередко ставят поверх 4.7). Свидджет 'ssclash' -> ветка go (SSClash-Go 5.x),
   свидджет 'clash' -> ветка legacy (luci-app-ssclash 4.7.x). Состояние, кэш и
   опрос статуса - раздельные по ветке. */
var _sscDefault = {
	go:     { present: false, port: 9091, scheme: 'http', version: '', path: '/'   },
	legacy: { present: false, port: 9090, scheme: 'http', version: '', path: '/ui/' }
};
var _ssc = { go: Object.assign({}, _sscDefault.go), legacy: Object.assign({}, _sscDefault.legacy) };
/* Warm-seed из localStorage (по ветке): карточка есть уже в первом кадре. */
['go', 'legacy'].forEach(function(k) {
	try {
		var s = JSON.parse(window.localStorage.getItem('netpri-ssclash-' + k) || 'null');
		if (s && s.present) { _ssc[k] = s; }
	} catch (e) {}
});
/* svcwidget -> ветка. 'clash' = старый 4.7 (сервис так и зовётся), 'ssclash' = 5.x. */
function sscKindForSvc(svc) { return svc === 'clash' ? 'legacy' : (svc === 'ssclash' ? 'go' : null); }

var _sscProbed = { go: false, legacy: false };
function ssclashInit(kind, redraw) {
	var st = _ssc[kind];
	if (st.present) { ssclashStatusInit(kind); }   // из кэша - точку опрашиваем сразу
	if (_sscProbed[kind]) { return; }
	_sscProbed[kind] = true;
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/ssclash.sh', [ 'detect', kind ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j && j.present) {
			_ssc[kind] = { present: true, port: (j.port || _sscDefault[kind].port),
				scheme: (j.scheme || 'http'), version: (j.version || ''),
				path: (j.path || _sscDefault[kind].path), kind: kind, running: st.running };
			try { window.localStorage.setItem('netpri-ssclash-' + kind, JSON.stringify(_ssc[kind])); } catch (e) {}
			ssclashStatusInit(kind);
			if (typeof redraw === 'function') { loadList().then(function(l) { redraw(l); }); }
		} else {
			var _had = st.present;
			_ssc[kind] = Object.assign({}, _sscDefault[kind]);
			try { window.localStorage.removeItem('netpri-ssclash-' + kind); } catch (e) {}
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
function ssClashBtn(kind) {
	var st = _ssc[kind];
	var host = window.location.hostname;
	// Путь зависит от ветки: SSClash-Go отдаёт админку в корне ("/"), а legacy
	// 4.7 - через external-ui самого clash ("/ui/"). См. ssclash.sh detect.
	var url = st.scheme + '://' + host + ':' + st.port + (st.path || '/');
	var ic = E('span', { 'class': 'netpri-ssclash-ic' });
	ic.innerHTML = SSCLASH_ICON;
	/* Три строки, как у карточек «Приоритета интернета»: версия сверху, имя с
	   значком по центру, IP роутера снизу (совпадает с целью ссылки). */
	/* Точка состояния после «SSClash». Начальный цвет - из последнего известного
	   (st.running, переживает в localStorage), опрос ниже освежает. Адресуем точку
	   по data-ssckind, чтобы опрос красил именно ЭТУ карточку (их может быть две). */
	var dot = E('span', { 'class': 'netpri-svcdot ' + (st.running ? 'on' : 'off'),
		'title': st.running ? _('SSClash is running') : _('SSClash is stopped') });
	return E('button', {
		'class': 'btn cbi-button netpri-btn netpri-ssclash',
		'data-ssckind': kind,
		'data-wkey': 's:' + (kind === 'go' ? 'ssclash-go' : 'ssclash'),
		'data-tooltip': _('Open the SSClash admin panel in a new tab'),
		'click': function() { window.open(url, '_blank', 'noopener'); }
	}, [
		svcRankEl(ic),
		E('span', { 'class': 'netpri-sub' }, st.version || 'SSClash'),
		E('span', { 'class': 'netpri-name' }, [ dot, ic, E('span', {}, 'SSClash') ]),
		E('span', { 'class': 'netpri-ip' }, host)
	]);
}

/* --- Карточки пинга (виджет «Статус сервиса»), по одной на хост ------------- */
function pingBadge(info) {
	if (info.svg) {
		var ic = E('span', { 'class': 'netpri-pingico' });
		ic.innerHTML = info.svg;
		return ic;
	}
	/* Файл-иконка. github.svg - монохромный octocat, ему нужна тёмная плашка
	   бренда, иначе он теряется в тёмной теме. А tg.svg уже НЕСЁТ свой фон
	   (синий скруглённый квадрат): плашка под ним читалась бы как рамка, поэтому
	   такие иконки рисуем во всю ячейку (plain). */
	if (info.img) {
		if (info.plain) {
			return E('span', { 'class': 'netpri-pingico' }, [
				E('img', { 'src': L.resource('icons/5gmodem/' + info.img), 'width': 16, 'height': 16,
					'alt': '', 'style': 'display:block;border-radius:4px' })
			]);
		}
		return E('span', { 'class': 'netpri-pingbadge', 'style': 'background:#1b1f23' }, [
			E('img', { 'src': L.resource('icons/5gmodem/' + info.img), 'width': 12, 'height': 12,
				'alt': '', 'style': 'display:block' })
		]);
	}
	if (info.custom) { return E('span', { 'class': 'netpri-pingbadge custom' }, info.glyph); }
	return E('span', { 'class': 'netpri-pingbadge', 'style': 'background:' + info.color }, info.glyph);
}
function _pDot(st) { return (st && st.done) ? (st.ok ? 'on' : 'off') : 'unknown'; }
function _pMs(st) {
	return (st && st.done && st.ok && st.ms != null) ? (st.ms + ' ' + _('ms')) : ('— ' + _('ms'));
}
function _pTip(st, info) {
	/* why=dns: адрес сервиса не принадлежит его официальным сетям - резолвер
	   отдал подмену. Для человека это совсем не то же самое, что «нет связи»,
	   и лечится оно в другом месте, поэтому говорим прямо. */
	if (st && st.done && !st.ok && st.why === 'dns') {
		return _('DNS returns a foreign address for %s (%s) - the resolver substitutes it').format(info.name, st.ip || '?');
	}
	return !(st && st.done) ? _('Click to ping %s').format(info.name)
		: (st.ok ? _('%s is reachable').format(info.name) : _('No connection to %s').format(info.name));
}
function pingCard(w) {
	var host = String(w.host || 'youtube.com').trim();
	var info = pingInfo(host);
	var st = _pingState[host];
	var dot = E('span', { 'class': 'netpri-svcdot ' + _pDot(st), 'title': _pTip(st, info) });
	var pic = pingBadge(info);
	return E('button', {
		/* ping-busy возвращаем и при пересоздании карточки поллом бара: замер
		   мог идти прямо в этот момент, и сияние не должно пропадать. */
		'class': 'btn cbi-button netpri-btn netpri-status' + (_pingBusy[host] ? ' ping-busy' : ''), 'data-host': host,
		/* Ключ для перетаскивания правых карточек - см. _npWidgetCards. */
		'data-wkey': 'p:' + host,
		'data-tooltip': _('Click to measure ping to %s over the active uplink').format(info.name),
		'click': function(ev) { ev.preventDefault(); pingOnce(host); }
	}, [
		/* фон карточки - её же значок (см. svcRankEl), как у карточек сервисов */
		svcRankEl(pic),
		E('span', { 'class': 'netpri-sub' }, _('Status')),
		E('span', { 'class': 'netpri-name' }, [ dot, pic, E('span', {}, info.name) ]),
		E('span', { 'class': 'netpri-ip' }, _pMs(st))
	]);
}
function updatePingCard(host) {
	var st = _pingState[host], info = pingInfo(host);
	var sel = '.netpri-status[data-host="' + host + '"]';
	document.querySelectorAll(sel + ' .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off', 'unknown'); d.classList.add(_pDot(st)); d.title = _pTip(st, info);
	});
	document.querySelectorAll(sel + ' .netpri-ip').forEach(function(el) { el.textContent = _pMs(st); });
}
/* ПРОКРУТКА ЦИФРЫ ПИНГА (запрос владельца): значение не прыгает, а быстро
   «пробегает» от прежнего к новому - тот же приём, что у живого числа
   спидтеста. ease-out: начало проскакивает быстро, к финалу мягко доезжает.
   Один rAF на хост; при провале анимировать нечего - прочерк сразу. */
var _pingAnim = {};
function animatePingMs(host, from, to) {
	var sel = '.netpri-status[data-host="' + host + '"] .netpri-ip';
	if (!document.querySelector(sel)) { return; }
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) { return; }
	if (_pingAnim[host]) { window.cancelAnimationFrame(_pingAnim[host]); _pingAnim[host] = null; }
	var t0 = null, dur = 600;
	var step = function(ts) {
		if (t0 === null) { t0 = ts; }
		var p = Math.min((ts - t0) / dur, 1);
		var e = 1 - (1 - p) * (1 - p);
		var v = Math.round(from + (to - from) * e);
		document.querySelectorAll(sel).forEach(function(el) { el.textContent = v + ' ' + _('ms'); });
		if (p < 1) { _pingAnim[host] = window.requestAnimationFrame(step); }
		else { _pingAnim[host] = null; }
	};
	_pingAnim[host] = window.requestAnimationFrame(step);
}
var _pingBusy = {};
function pingOnce(host) {
	host = String(host).trim();
	if (_pingBusy[host]) { return Promise.resolve(); }
	_pingBusy[host] = true;
	/* ПРЕЖНЯЯ ЦИФРА ОСТАЁТСЯ НА ВРЕМЯ ЗАМЕРА (запрос владельца): замена её на
	   «…» с последующей прокруткой читалась как мигание. «…» - только когда
	   показывать нечего (первый замер или прошлый провалился). Что замер идёт,
	   видно по синему сиянию карточки (класс ping-busy, CSS). */
	var _hadPrev = (_pingState[host] && _pingState[host].ok && _pingState[host].ms != null);
	document.querySelectorAll('.netpri-status[data-host="' + host + '"]').forEach(function(c) { c.classList.add('ping-busy'); });
	if (!_hadPrev) {
		document.querySelectorAll('.netpri-status[data-host="' + host + '"] .netpri-ip').forEach(function(el) { el.textContent = '…'; });
	}
	return L.resolveDefault(fs.exec_direct(BIN, [ 'ping', host ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		/* Прежнее значение - старт прокрутки; после провала или первого замера
		   крутим от нуля, чтобы движение было заметно. */
		var prev = (_pingState[host] && _pingState[host].ok && _pingState[host].ms != null)
			? _pingState[host].ms : 0;
		_pingState[host] = { done: true, ok: !!j.ok, ms: (j.ms != null ? j.ms : null),
		                     why: j.why || null, ip: j.ip || null };
		try { window.localStorage.setItem('netpri-pingstate', JSON.stringify(_pingState)); } catch (e) {}
		mutil.lsTouch('netpri-pingstate');
		_pingBusy[host] = false;
		document.querySelectorAll('.netpri-status[data-host="' + host + '"]').forEach(function(c) { c.classList.remove('ping-busy'); });
		updatePingCard(host);
		/* Вспышка лампочки цветом ИТОГА: updatePingCard уже перекрасил её в
		   зелёный/красный (смена цвета перетекает transition'ом), вспышка
		   поверх - масштаб+яркость. Снятие/чтение offsetWidth перезапускает
		   анимацию, если класс ещё висит с прошлого замера. */
		document.querySelectorAll('.netpri-status[data-host="' + host + '"] .netpri-svcdot').forEach(function(d) {
			d.classList.remove('ping-flash');
			void d.offsetWidth;
			d.classList.add('ping-flash');
			window.setTimeout(function() { d.classList.remove('ping-flash'); }, 800);
		});
		if (j.ok && j.ms != null) { animatePingMs(host, prev, j.ms); }
	});
}
/* Автопинг только у карточек с интервальным режимом; «по клику» ждут клика. */
var _pingPolls = {};
function pingInit() {
	_pingWidgets.forEach(function(w) {
		var n = parseInt(w.mode, 10);
		if (isNaN(n) || n <= 0 || _pingPolls[w.host]) { return; }
		_pingPolls[w.host] = true;
		pingOnce(w.host);
		(function(h) { poll.add(function() { return pingOnce(h); }, n); })(w.host);
	});
}

/* --- Карточки сервисов (виджет «Сервисы»), кроме SSClash (у него своя) ------ */
/* Известные сервисы с уникальными иконками добавим позже; пока - гаечный ключ. */
/* Известные сервисы: имя/иконка для карточки и (если есть) порт собственной
   веб-админки - такая карточка кликабельна и открывает её в новой вкладке.
   zapret = Zapret Manager: статус даёт init.d/zapret, админка - ttyd на 7681
   («Активировать доступ из браузера» в его же меню). */
var SVC_KNOWN = {
	zapret: { name: 'Zapret', glyph: '☢️', port: 7681 },
	/* ZeroTier: свой значок в фирменных цветах и адрес роутера в сети вместо
	   слова «работает» - ради этого адреса ZeroTier и ставят, а держать его в
	   голове неудобно. Веб-админки у него нет, порт не задаём. */
	zerotier: { name: 'ZeroTier', img: 'zt.png' }
};
/* ФОН ПРАВЫХ КАРТОЧЕК - ТА ЖЕ ИКОНКА, ЧТО В ИХ СТРОКЕ ИМЕНИ (просьба владельца
   03.09.2026). Общий строитель для карточек СЕРВИСОВ и карточек ПИНГА.
   Включается ТОЙ ЖЕ настройкой, что фон карточек аплинков («Фон карточек» ->
   «Иконка интерфейса»): отдельной галочки нет, чтобы не плодить две ручки для
   одного и того же приёма. Цифр здесь не бывает - ни у сервиса, ни у хоста нет
   порядкового номера, поэтому режим «Номер приоритета» этим карточкам ничего
   не рисует.

   Иконку не выбираем заново, а КЛОНИРУЕМ ту, что карточка уже показывает: у
   сервисов они разного рода (файл-картинка, инлайн-SVG у SSClash, эмодзи-бейдж),
   и второй источник правды тут же бы разошёлся с первым. Размер, размытие и
   прозрачность - в CSS (.netpri-rank-bg), там же зеркальный сдвиг: у аплинков
   пятно выходит за ПРАВЫЙ край карточки, у сервисов - за ЛЕВЫЙ. */
/* СВЕТЛАЯ ТЕМА ИЛИ ТЁМНАЯ - СПРАШИВАЕМ У СТРАНИЦЫ, А НЕ У СИСТЕМЫ.
   Фон карточек красится по-разному на светлой и тёмной теме, и раньше выбор
   ветки висел на медиазапросе prefers-color-scheme. А он говорит про настройку
   ОС, тогда как тему LuCI человек выбирает отдельно: светлый bootstrap при
   тёмной системе - обычное дело, и тогда к светлым карточкам применялись
   ТЁМНЫЕ значения (владелец 03.09.2026: «как будто все светлые темы работают
   по-другому и твои настройки не применяются»).
   Спрашиваем у самой страницы: берём цвет ТЕКСТА карточек - он задан всегда, в
   отличие от фона, который бывает прозрачным. Светлый текст = тёмная тема. */
function isDarkUI(el) {
	var c = getComputedStyle(el || document.body).color;
	var m = String(c).match(/(\d+)[,\s]+(\d+)[,\s]+(\d+)/);
	if (!m) { return false; }
	return (0.2126 * (+m[1]) + 0.7152 * (+m[2]) + 0.0722 * (+m[3])) > 128;
}

function svcRankEl(icon) {
	if (_netpriRank !== 'icon') { return ''; }
	if (!icon || typeof icon.cloneNode !== 'function') { return ''; }
	return E('span', { 'class': 'netpri-rank netpri-rank-bg', 'aria-hidden': 'true' },
		[ icon.cloneNode(true) ]);
}

function svcName(service) { return (SVC_KNOWN[service] && SVC_KNOWN[service].name) || service; }
function svcIcon(service) {
	var k = SVC_KNOWN[service];
	if (k && k.img) {
		return E('img', { 'class': 'netpri-ic', 'src': L.resource('icons/5gmodem/' + k.img),
			'width': 16, 'height': 16, 'alt': '' });
	}
	if (k && k.glyph) {
		/* без color - эмодзи как есть, прозрачным бейджем (класс custom) */
		return E('span', { 'class': 'netpri-pingbadge' + (k.color ? '' : ' custom'),
			'style': k.color ? ('background:' + k.color) : null }, k.glyph);
	}
	return E('span', { 'class': 'netpri-pingbadge custom' }, '🔧');
}
/* _svcState[svc] = { running, version }. У известных сервисов верхняя строка -
   ВЕРСИЯ (вместо слова «Сервис»); нижняя - работает/остановлен. */
function _sDot(r) { return (r === undefined) ? 'unknown' : (r.running ? 'on' : 'off'); }
function _sTop(r) { return (r && r.version) ? ('v' + r.version) : _('Service'); }
function _sBottom(r) {
	if (r === undefined) { return '—'; }
	/* Адрес важнее статуса: если он есть, значит сервис и так работает, а по
	   этому адресу человек ходит на роутер извне. Нет адреса (сеть не выдала
	   или сервис стоит) - показываем обычный статус. */
	if (r.ip) { return r.ip; }
	return r.running ? _('running') : _('stopped');
}
function svcCard(service) {
	var r = _svcState[service];
	var k = SVC_KNOWN[service];
	var dot = E('span', { 'class': 'netpri-svcdot ' + _sDot(r),
		'title': (r === undefined) ? service : (r.running ? _('%s is running').format(service) : _('%s is stopped').format(service)) });
	var attrs = {
		'class': 'btn cbi-button netpri-btn netpri-status', 'data-svc': service,
		'data-wkey': 's:' + service,
		'data-tooltip': (r && r.ip) ? _('%s address of this router: %s').format(svcName(service), r.ip)
			: ((k && k.port) ? _('Open %s').format(svcName(service)) : service)
	};
	/* у сервиса есть своя веб-админка - карточка открывает её в новой вкладке
	   (хост берём текущий: админка живёт на ЭТОМ же роутере, только порт свой) */
	if (k && k.port) {
		attrs['click'] = function(ev) {
			ev.preventDefault();
			window.open('//' + window.location.hostname + ':' + k.port + '/', '_blank');
		};
	} else {
		/* КАРТОЧКА БЕЗ АДМИНКИ - ЧИСТО ИНФОРМАЦИОННАЯ. Запускать и останавливать
		   сервис по клику НЕ надо: это кнопка в форме, случайное нажатие не
		   должно ничего менять в системе, а состояние показывает точка. */
		attrs['click'] = function(ev) { ev.preventDefault(); };
	}
	var sic = svcIcon(service);
	return E('button', attrs, [
		svcRankEl(sic),
		E('span', { 'class': 'netpri-sub' }, _sTop(r)),
		E('span', { 'class': 'netpri-name' }, [ dot, sic, E('span', {}, svcName(service)) ]),
		E('span', { 'class': 'netpri-ip' }, _sBottom(r))
	]);
}
function updateSvcCard(service) {
	var r = _svcState[service], sel = '.netpri-status[data-svc="' + service + '"]';
	document.querySelectorAll(sel + ' .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off', 'unknown'); d.classList.add(_sDot(r));
	});
	document.querySelectorAll(sel + ' .netpri-sub').forEach(function(el) { el.textContent = _sTop(r); });
	document.querySelectorAll(sel + ' .netpri-ip').forEach(function(el) { el.textContent = _sBottom(r); });
}
/* Все сервисные точки (generic-сервисы + ветки SSClash) опрашиваются ОДНИМ
   вызовом netpri.sh svcall на тик вместо N параллельных exec_direct: каждый
   exec - отдельный spawn через rpcd, и панель в покое давала ~1 процесс/сек. */
var _svcAgg = { services: [], kinds: [], started: false };
function _svcAggTick() {
	if (!_svcAgg.services.length && !_svcAgg.kinds.length) { return Promise.resolve(); }
	/* ПУСТОЙ СПИСОК КОДИРУЕМ КАК '-': exec_direct склеивает аргументы в строку
	   через пробел, и пустая строка в ней ИСЧЕЗАЕТ - на роутере без generic-
	   сервисов вызов превращался в `svcall go`, ветка ssclash приезжала в $2
	   как «сервис go», и точка SSClash горела красным при живом сервисе. */
	return L.resolveDefault(fs.exec_direct(BIN, [ 'svcall', _svcAgg.services.join(',') || '-', _svcAgg.kinds.join(',') || '-' ]), '').then(function(out) {
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		_svcAgg.services.forEach(function(svc) {
			var r = (j.svc || {})[svc] || {};
			/* ip НЕ ЗАБЫВАЕМ: бэкенд отдаёт его для ZeroTier (адрес роутера в
			   сети), и карточка показывает именно его вместо слова «работает».
			   Раньше здесь пересобирался объект из двух полей, и адрес молча
			   терялся по дороге - карточка его не видела никогда. */
			_svcState[svc] = { running: !!r.running, version: r.version || '', ip: r.ip || '' };
			updateSvcCard(svc);
		});
		_svcAgg.kinds.forEach(function(kind) {
			var r = (j.ssc || {})[kind] || {};
			_ssc[kind].running = !!r.running;
			try { window.localStorage.setItem('netpri-ssclash-' + kind, JSON.stringify(_ssc[kind])); } catch (e) {}
			updateSscDot(kind);
		});
	});
}
function _svcAggStart() {
	if (_svcAgg.started) { return; }
	_svcAgg.started = true;
	poll.add(_svcAggTick, 5);
}
function svcStatusInit(services) {
	services = (services || []).filter(function(s) {
		return s && s !== 'ssclash' && s !== 'clash' && _svcAgg.services.indexOf(s) < 0;
	});
	if (!services.length) { return; }
	_svcAgg.services = _svcAgg.services.concat(services);
	_svcAggTick();
	_svcAggStart();
}

/* Живой опрос состояния сервиса SSClash - красит точку ИМЕННО этой ветки-карточки
   (по data-ssckind: карточек может быть две, у каждой свой сервис). */
function updateSscDot(kind) {
	var st = _ssc[kind];
	var cls = st.running ? 'on' : 'off';
	var tip = st.running ? _('SSClash is running') : _('SSClash is stopped');
	document.querySelectorAll('.netpri-ssclash[data-ssckind="' + kind + '"] .netpri-svcdot').forEach(function(d) {
		d.classList.remove('on', 'off'); d.classList.add(cls); d.title = tip;
	});
}
function ssclashStatusInit(kind) {
	if (_svcAgg.kinds.indexOf(kind) >= 0) { return; }
	_svcAgg.kinds.push(kind);
	_svcAggTick();
	_svcAggStart();
}

function stInit() {
	L.resolveDefault(fs.exec_direct(SPEEDBIN, [ 'status' ]), '').then(function(out) {
		if (out) { _st.lastStatusRaw = out; }
		var j = {}; try { j = JSON.parse(out || '{}'); } catch (e) {}
		if (j.service) { _st.service = j.service; }
		/* Тест уже ИДЁТ (запущен до ухода со страницы) - подхватываем его
		   наблюдением, а не сидим в покое до финала. Гард на phase: свой
		   собственный опрос (runSpeedtest) уже работает - второй не нужен. */
		if (j.running && _st.phase !== 'running') {
			_st.phase = 'running'; _st.hasData = false; _st.elapsed = null;
			_st.upPhase = (j.phase === 'up');
			_renderedKey = ''; _liveDisplay = 0;
			refreshStCard(); stProgStart();
			stPoll();
			return;
		}
		if (j.ok && _st.phase === 'idle') { _st.phase = 'done'; _st.down = j.down_mbps; _st.up = (j.up_mbps != null ? j.up_mbps : null); _st.ip = j.pub_ip || ''; _st.cc = j.cc || ''; }
		patchStCard();
	});
}

/* Последнее событие сторожа (health.sh) - приезжает хвостовым элементом list,
   чтобы не плодить отдельный опрос; вынимается здесь до отрисовки карточек.
   Там же приезжает состояние галки «переключать трафик»: без неё панель не
   может отличить «сторож увёл трафик» от «сторож видит дыру и молчит». */
var _hfo = null;   // null - слежение выключено/ответа ещё не было

function loadList() {
	return L.resolveDefault(fs.exec_direct(BIN, [ 'list' ]), '[]').then(function(out) {
		var arr = [];
		try { arr = JSON.parse(out || '[]') || []; } catch (e) {}
		arr = Array.isArray(arr) ? arr : [];
		arr = arr.filter(function(o) {
			if (o && o.event != null) { _hfo = (String(o.failover) === '1'); return false; }
			return true;
		});
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
	/* Сторож (health.sh) при падении уводит трафик штрафным маршрутом, НЕ трогая
	   uci - порядок и реальность расходятся. Бэкенд отдаёт live:1 тому линку, чьё
	   устройство реально несёт default с наименьшей метрикой - он и активен. */
	var lv = null;
	list.forEach(function(o) { if (o.live) { lv = o.iface; } });
	if (lv) { return lv; }
	var best = null, bm = Infinity, bip = false;
	list.forEach(function(o) {
		var m = parseInt(o.metric, 10); if (isNaN(m)) { m = 0; }
		var hip = !!o.ip;
		if (m < bm || (m === bm && hip && !bip)) { bm = m; best = o.iface; bip = hip; }
	});
	return best;
}

/* Оператор -> файл иконки (та же таблица, что в главном блоке 5gdetail). */
/* operatorIcon переехал в общий модуль mutil (в 5gdetail и dashboard были свои копии
   той же таблицы - три экземпляра неизбежно расходились). */

/* per-type icon from the app's icon set (modem / Wi-Fi / WAN); null for the rest.
   Для модема - как в главном блоке SIM: иконка ОПЕРАТОРА, если он определён
   (o.label несёт имя оператора), иначе простая SIM-карта (op-sim.png). */
function typeIcon(o) {
	if (o.type === 'modem') {
		var oi = mutil.operatorIcon(o.label);
		return E('img', {
			'class': 'netpri-ic', 'src': L.resource('icons/5gmodem/' + (oi ? oi : 'op-sim') + '.png'),
			'width': 16, 'height': 16, 'alt': ''
		});
	}
	var f = (o.type === 'wifi') ? 'cwifi.svg'
	      : (o.type === 'wan')  ? 'cwan.svg'
	      : null;
	if (!f) { return null; }
	return E('img', {
		'class': 'netpri-ic', 'src': L.resource('icons/5gmodem/' + f),
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

/* НОМЕР ПРИОРИТЕТА ФОНОМ - крупная полупрозрачная цифра у правого края
   карточки. Читается как «этот аплинк первый/второй/третий» без наведения на
   подсказку с метрикой. Позиция и размер - в CSS (.netpri-rank): цифра вынута
   из потока, поэтому три строки текста стоят ровно там же, где стояли, и
   ширина карточки не меняется. aria-hidden: для читалки это украшение, порядок
   и так виден по последовательности кнопок. */
function rankEl(idx, o) {
	if (_netpriRank === 'icon') {
		/* ТА ЖЕ КАРТИНКА, ЧТО В ШАПКЕ КАРТОЧКИ (typeIcon): у модема - логотип
		   оператора SIM (переставили карту - фон сменится сам вместе с label),
		   у Wi-Fi и кабеля - их значки. Размер и посадка - в CSS: картинка, в
		   отличие от цифры, честно растягивается от верха до низа. */
		var src = null;
		if (o && o.type === 'modem') {
			var oi = mutil.operatorIcon(o.label);
			src = L.resource('icons/5gmodem/' + (oi ? oi : 'op-sim') + '.png');
		} else if (o && o.type === 'wifi') {
			src = L.resource('icons/5gmodem/cwifi.svg');
		} else if (o && o.type === 'wan') {
			src = L.resource('icons/5gmodem/cwan.svg');
		}
		if (!src) { return ''; }
		return E('img', { 'class': 'netpri-rank netpri-rank-ic', 'src': src,
			'alt': '', 'aria-hidden': 'true' });
	}
	if (_netpriRank !== 'num') { return ''; }
	var sp = E('span', { 'class': 'netpri-rank', 'aria-hidden': 'true' }, String(idx + 1));
	_rankFit(sp);
	return sp;
}

/* ПОСАДКА ЦИФРЫ - ПО МЕТРИКАМ ЖИВОГО ШРИФТА, А НЕ КОНСТАНТАМИ. Подобранные в
   CSS кегль и смещение верны только для шрифта одной темы (Inter в proton2025);
   на другой теме глиф съезжал на пиксели (поймано при сверке с bootstrap).
   Считаем через canvas TextMetrics: кегль - чтобы глиф был ровно с карточку,
   top - чтобы зазоры сверху и снизу были равны. Метрики шрифта линейны по
   кеглю, поэтому хватает одного замера без второго чтения раскладки. Повтор на
   fonts.ready: веб-шрифт темы может доехать позже первой отрисовки. */
function _rankFit(sp) {
	/* Два шага. Первый ставит кегль «глиф = высота карточки». Второй меряет
	   ФАКТИЧЕСКИЕ зазоры уже применённой раскладки и двигает top так, чтобы
	   сверху и снизу осталось поровну, - никакие предположения о line box не
	   нужны, и рассинхрон с межстрочником темы исключён по построению. */
	var gaps = function(card) {
		var cs = getComputedStyle(sp);
		var ctx = _rankFit._cv || (_rankFit._cv = document.createElement('canvas').getContext('2d'));
		ctx.font = cs.fontWeight + ' ' + cs.fontSize + ' ' + cs.fontFamily;
		var m = ctx.measureText(sp.textContent);
		if (!m || !m.actualBoundingBoxAscent) { return null; }
		var rr = sp.getBoundingClientRect(), cr = card.getBoundingClientRect();
		var baseline = (rr.height - (m.fontBoundingBoxAscent + m.fontBoundingBoxDescent)) / 2
			+ m.fontBoundingBoxAscent;
		return {
			fs: parseFloat(cs.fontSize),
			glyph: m.actualBoundingBoxAscent + m.actualBoundingBoxDescent,
			top: (rr.top - cr.top) + baseline - m.actualBoundingBoxAscent,
			bot: cr.height - ((rr.top - cr.top) + baseline + m.actualBoundingBoxDescent)
		};
	};
	var step2 = function() {
		if (!sp.isConnected) { return; }
		var card = sp.closest('.netpri-btn');
		var g = card && gaps(card);
		if (!g) { return; }
		var want = (g.top + g.bot) / 2;
		sp.style.top = ((parseFloat(getComputedStyle(sp).top) || 0) - (g.top - want)) + 'px';
	};
	var step1 = function() {
		if (!sp.isConnected) { return; }
		var card = sp.closest('.netpri-btn');
		var g = card && gaps(card);
		if (!g) { return; }
		sp.style.lineHeight = '1';
		sp.style.fontSize = (g.fs * card.clientHeight / g.glyph) + 'px';
		window.requestAnimationFrame(step2);
	};
	window.requestAnimationFrame(step1);
	if (document.fonts && document.fonts.ready) { document.fonts.ready.then(function() { window.requestAnimationFrame(step1); }); }
}

function nameEl(o) {
	var txt = o.label || o.iface;
	var ic = typeIcon(o);
	if (ic) { return E('span', { 'class': 'netpri-name' }, [ ic, E('span', {}, txt) ]); }
	return E('span', { 'class': 'netpri-name' }, txt);
}

/* ==== ПЕРЕТАСКИВАНИЕ КАРТОЧЕК: порядок = приоритет (метрика 1,2,3…) ====
   На pointer-events (НЕ нативный HTML5-drag: тот на <button> не заводится - тема
   ставит -webkit-user-drag:none, кнопки не «схватываются», и на тач его нет).
   Тащим карточку по горизонтали, соседи «резиново» съезжают (FLIP), на месте, куда
   она встанет, - пунктирный слот с иконкой +. Отпустили - бэкенд получает новый
   порядок (netpri.sh order …): метрики = ранг, отвал первого → трафик на второй. */
var _npDrag = null;          // активное перетаскивание (или null)
var _npApplying = false;     // идёт применение нового порядка (пауза poll до подтверждения)
var _npJustDragged = false;  // подавить click, идущий сразу после drop

function _npEnsureDragCss() {
	}

/* КАРТОЧКИ ОДНОГО РОДА В РЯДУ.
   В ряду соседствуют два семейства: аплинки (data-iface) и правые виджеты
   (data-wkey - пинги, службы, спидтест). Перетаскивание работает ВНУТРИ своего
   семейства: аплинк не должен уезжать в середину виджетов, у них разный смысл
   порядка (метрики против оформления). Родовой признак берём у той карточки,
   которую тянут. */
function _npCards(row, attr) {
	return Array.prototype.slice.call(row.children).filter(function(c) {
		return c.nodeType === 1 && c.classList.contains('netpri-btn') && c.hasAttribute(attr);
	});
}

function _npIfaceCards(row) { return _npCards(row, 'data-iface'); }
function _npWidgetCards(row) { return _npCards(row, 'data-wkey'); }

/* Признак семейства активного перетаскивания (см. _npEnableReorder). */
function _npDragAttr() { return (_npDrag && _npDrag.attr) ? _npDrag.attr : 'data-iface'; }
function _npDragCards(row) { return _npCards(row, _npDragAttr()); }

function _npMakeSlot(w, h) {
	var s = E('div', { 'class': 'netpri-btn netpri-slot' });
	s.style.width = w + 'px'; s.style.height = h + 'px';
	s.innerHTML = '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" ' +
		'stroke="currentColor" stroke-width="2" stroke-linecap="round">' +
		'<path d="M12 5v14M5 12h14"/></svg>';
	return s;
}

/* Позиция карточки во вьюпорте БЕЗ учёта её transform (вычитаем translateX/Y из
   матрицы). Во время FLIP getBoundingClientRect возвращает «едущие» координаты, и
   хит-тест по ним зацикливался (соседи дёргались). Так меряем стабильную разметку. */
function _npLayoutPos(c) {
	var r = c.getBoundingClientRect(), tx = 0, ty = 0;
	var tr = getComputedStyle(c).transform;
	if (tr && tr !== 'none') {
		var m = tr.match(/matrix\(([^)]+)\)/);
		if (m) { var q = m[1].split(','); tx = parseFloat(q[4]) || 0; ty = parseFloat(q[5]) || 0; }
		else { var m3 = tr.match(/matrix3d\(([^)]+)\)/); if (m3) { var w = m3[1].split(','); tx = parseFloat(w[12]) || 0; ty = parseFloat(w[13]) || 0; } }
	}
	return { left: r.left - tx, top: r.top - ty };
}

/* FLIP в 2D (X и Y): при переносе строк карточки едут и по вертикали. */
/* $before - Map: сам элемент -> его позиция ДО перестановки.
   Раньше ключом было значение data-iface, и для ПРАВЫХ виджетов (у них такого
   атрибута нет) ключ у всех выходил один и тот же - «null». Позиции путались
   между собой, карточки прыгали вместо плавного разъезда: ровно та дёрганая
   анимация, что была у аплинков до отладки (замечено владельцем 07.08.2026). */
function _npFlip(cards, before) {
	cards.forEach(function(c) {
		var b = before.get(c); if (!b) { return; }
		var now = _npLayoutPos(c);
		var dx = b.left - now.left, dy = b.top - now.top;
		if (Math.abs(dx) < 1 && Math.abs(dy) < 1) { return; }
		c.style.transition = 'none';
		c.style.transform = 'translate(' + dx + 'px,' + dy + 'px)';
		requestAnimationFrame(function() {
			c.style.transition = 'transform .18s ease';
			c.style.transform = '';
		});
	});
}

/* ПРАВАЯ ГРУППА НАЧИНАЕТСЯ С ПЕРВОГО ВИДЖЕТА - ВСЕГДА.
   Отступ, отжимающий виджеты вправо (margin-left:auto), висит классом на первой
   правой карточке. При перестановке класс уезжал вместе со своей карточкой, и
   остальные виджеты «прилипали» к приоритетам - выглядело так, будто они
   перескочили в чужую группу. Пересчитываем после каждой перестановки и после
   отпускания. */
function _npFixRightStart(row) {
	Array.prototype.slice.call(row.querySelectorAll('.netpri-rightstart'))
		.forEach(function(c) { c.classList.remove('netpri-rightstart'); });
	/* Пустое место под тянущийся виджет - тоже часть правой группы: если отступ
	   достанется карточке ПОСЛЕ него, место останется прижатым к приоритетам. */
	var slot = (_npDrag && _npDrag.attr === 'data-wkey') ? _npDrag.slot : null;
	var lifted = (_npDrag && _npDrag.active) ? _npDrag.card : null;   // вырван из потока
	var w = Array.prototype.slice.call(row.children).filter(function(c) {
		if (c.nodeType !== 1 || c === lifted) { return false; }
		return c === slot || (c.classList.contains('netpri-btn') && c.hasAttribute('data-wkey'));
	});
	if (w.length) { w[0].classList.add('netpri-rightstart'); }
}

/* Индекс вставки в ПОТОКЕ (учитывает перенос строк): первый card, ПЕРЕД которым
   стоит указатель - выше его строки, либо в его строке и левее центра. */
function _npReposition(clientX, clientY) {
	var d = _npDrag; if (!d || !d.slot) { return; }
	var row = d.row, slot = d.slot;
	var cards = _npDragCards(row).filter(function(c) { return c !== d.card; });
	var idx = cards.length;
	for (var i = 0; i < cards.length; i++) {
		var p = _npLayoutPos(cards[i]), ow = cards[i].offsetWidth, oh = cards[i].offsetHeight;
		if (clientY < p.top) { idx = i; break; }                               // выше строки карточки
		if (clientY < p.top + oh && clientX < p.left + ow / 2) { idx = i; break; }  // в строке, левее центра
	}
	if (idx === d.lastIndex) { return; }
	d.lastIndex = idx;
	var before = new Map(); cards.forEach(function(c) { before.set(c, _npLayoutPos(c)); });
	/* ГРАНИЦЫ СЕМЕЙСТВА. Карточка не должна покидать свой участок ряда: аплинк
	   не уезжает к виджетам, виджет - к аплинкам (у них разный смысл порядка, а
	   у виджетов ещё и своя правая группа с margin-left:auto). Вставляем ЛИБО
	   перед соседом по семейству, ЛИБО сразу за последним из них - но никогда
	   в конец всего ряда. Без этого виджет утаскивался в область приоритетов, а
	   аплинк - в хвост виджетов. */
	var refBefore = cards[idx] || null;
	if (refBefore) { row.insertBefore(slot, refBefore); }
	else if (cards.length) { row.insertBefore(slot, cards[cards.length - 1].nextSibling); }
	else { row.appendChild(slot); }
	_npFlip(cards, before);
	_npFixRightStart(row);
}

function _npBeginDrag() {
	var d = _npDrag, card = d.card;
	var r = card.getBoundingClientRect();
	d.slot = _npMakeSlot(r.width, r.height);
	card.parentNode.insertBefore(d.slot, card);
	card.style.position = 'fixed';
	card.style.left = r.left + 'px'; card.style.top = r.top + 'px';
	card.style.width = r.width + 'px'; card.style.height = r.height + 'px';
	card.style.margin = '0'; card.style.zIndex = '1000'; card.style.pointerEvents = 'none';
	card.classList.add('netpri-lift');
	document.body.style.userSelect = 'none';
	d.active = true;
	_npFixRightStart(d.row);
}

function _npMove(ev) {
	var d = _npDrag; if (!d) { return; }
	var dx = ev.clientX - d.startX, dy = ev.clientY - d.startY;
	if (!d.active) {
		if (Math.abs(dx) < 5 && Math.abs(dy) < 5) { return; }
		_npBeginDrag();
	}
	ev.preventDefault();
	d.card.style.transform = 'translate(' + dx + 'px,' + dy + 'px) scale(1.03)';
	_npReposition(ev.clientX, ev.clientY);
}

/* Полный разбор перетаскивания: снять слушатели, вернуть поднятую карточку в
   поток, убрать слот, сбросить _npDrag. Идемпотентно; используется и штатным
   завершением, и восстановлением после подвисшего drag (см. pointerdown). */
function _npTeardown() {
	var d = _npDrag; if (!d) { return null; }
	_npDrag = null;
	document.removeEventListener('pointermove', _npMove, true);
	document.removeEventListener('pointerup', _npEnd, true);
	document.removeEventListener('pointercancel', _npEnd, true);
	try { d.card.releasePointerCapture(d.pid); } catch (e) {}
	document.body.style.userSelect = '';
	if (d.active) {
		var card = d.card;
		card.classList.remove('netpri-lift');
		[ 'position','left','top','width','height','margin','zIndex','pointerEvents','transform' ]
			.forEach(function(k) { card.style[k] = ''; });
		if (d.slot && d.slot.parentNode) { d.slot.parentNode.insertBefore(card, d.slot); d.slot.parentNode.removeChild(d.slot); }
		_npDragCards(d.row).forEach(function(c) { c.style.transition = ''; c.style.transform = ''; });
		_npFixRightStart(d.row);
	}
	return d;
}

function _npEnd() {
	var d = _npDrag; if (!d) { return; }
	/* Семейство запоминаем ДО teardown: он обнуляет _npDrag, и определять род
	   карточек после него было бы уже не по чему - правые виджеты уезжали в
	   ветку аплинков и порядок не сохранялся вовсе. */
	var active = d.active, row = d.row, commit = d.commit, attr = d.attr || 'data-iface';
	_npTeardown();
	if (!active) { return; }   // не двигали - это клик, обработчик click сам отработает
	_npJustDragged = true;
	/* Рамку активного переносим на новую первую карточку СРАЗУ (оптимистично), не
	   дожидаясь ответа бэкенда - после teardown DOM уже в новом порядке, метрика 1
	   будет у левой. Иначе подсветка «догоняла» с задержкой round-trip. */
	/* ПРАВЫЕ ВИДЖЕТЫ - СВОЙ ПОРЯДОК И СВОЙ ПОЛУЧАТЕЛЬ.
	   У них нет ни метрик, ни «активной» карточки: порядок чисто оформительский
	   и живёт в одном ключе конфига. Поэтому здесь ветка расходится: аплинкам
	   пишем метрики через `netpri.sh order`, виджетам - список ключей через
	   `netpri.sh worder`. */
	if (attr === 'data-wkey') {
		var wkeys = _npWidgetCards(row).map(function(c) { return c.getAttribute('data-wkey'); });
		/* Порядок в ПАМЯТИ обновляем сразу: тик поллинга пересобирает ряд по
		   _widgetOrder, и со старым массивом карточки спустя тик разъезжались
		   обратно (поймано владельцем 07.08.2026). Кэш uci.js тоже сбрасываем -
		   запись идёт мимо него (fs.exec), и loadWidgetFlags иначе отдал бы
		   старый порядок до конца жизни страницы. */
		_widgetOrder = wkeys.slice();
		try { uci.unload('5gmodem'); } catch (e) {}
		_npApplying = true;
		var _wDone = function() { _npApplying = false; };
		setTimeout(_wDone, 4000);
		L.resolveDefault(fs.exec(BIN, [ 'worder' ].concat(wkeys)), {}).then(_wDone, _wDone);
		return;
	}
	var _cards = _npIfaceCards(row);
	_cards.forEach(function(c) { c.classList.remove('active'); });
	if (_cards[0]) { _cards[0].classList.add('active'); }
	var order = _cards.map(function(c) { return c.getAttribute('data-iface'); });
	/* ПАУЗА POLL до подтверждения. Иначе параллельный 5-сек. тик успевал прочитать
	   list ПОКА order ещё пишет метрики, перерисовывал старый порядок, и карточка
	   «прыгала назад», а на следующем тике вставала верно (особенно на мобильном,
	   где тиков больше). Держим оптимистичный DOM, пока order не применён и мы сами
	   не перечитали подтверждённый порядок. Страховка снимает флаг, если order завис. */
	_npApplying = true;
	var _npDone = function() { _npApplying = false; };
	setTimeout(_npDone, 4000);
	L.resolveDefault(fs.exec(BIN, [ 'order' ].concat(order)), {}).then(function() {
		loadList().then(function(l2) { if (commit) { commit(l2); } _npDone(); });
	}, _npDone);
}

function _npEnableReorder(row, commit, attr) {
	_npEnsureDragCss();
	var _attr = attr || 'data-iface';
	_npCards(row, _attr).forEach(function(card) {
		card.addEventListener('pointerdown', function(ev) {
			if (ev.button !== 0) { return; }
			if (_npDrag) { _npTeardown(); }   // самовосстановление после подвисшего drag
			_npDrag = { card: card, row: row, startX: ev.clientX, startY: ev.clientY,
			            active: false, commit: commit, pid: ev.pointerId, lastIndex: -1,
			            attr: _attr };
			try { card.setPointerCapture(ev.pointerId); } catch (e) {}
			/* слушатели на DOCUMENT (а не на карточке): ловим pointerup/cancel даже
			   если указатель ушёл за пределы или capture потерялся - иначе _npDrag
			   оставался бы висеть и блокировал все следующие перетаскивания. */
			document.addEventListener('pointermove', _npMove, true);
			document.addEventListener('pointerup', _npEnd, true);
			document.addEventListener('pointercancel', _npEnd, true);
		});
		card.addEventListener('lostpointercapture', function() {
			if (_npDrag && _npDrag.card === card) { _npEnd(); }
		});
	});
}

/* Настройки сторожа интернета (health.sh). Модалка вместо страницы настроек:
   слежение принадлежит виджету приоритета, пользователь ищет его здесь. Сама
   форма ОБЩАЯ с блоком на странице «Настройки» - живёт в healthform.js
   (issue #12: при выключенном виджете настроить слежение было негде). */
function healthModal() {
	healthform.load().then(function(d) {
		var hf = healthform.build(d.conf, d.uplinks);
		ui.showModal(_('Internet watchdog'), [
			hf.node,
			/* Кнопки модалки - штатная пара LuCI: нейтральная «Отмена» и
			   активная «Сохранить», как в любом диалоге интерфейса. */
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-action important', 'click': function() {
					hf.save().then(function() { ui.hideModal(); });
				} }, _('Save'))
			])
		], 'hw-modal');
		/* Ширина - РОВНО как у карточек страницы: берём живую ширину панели
		   приоритета (она в той же колонке контента, что «Модем» и «Управление
		   частотами»). Константа в CSS не годится - ширина колонки зависит от
		   темы и окна; замер в момент открытия попадает всегда. */
		var _hwSec = document.querySelector('.netpribar') || document.querySelector('.cbi-section');
		/* Модалка LuCI - синглтон внутри #modal_overlay; ищем её там, а не по
		   своему классу: не каждая версия ui.showModal принимает доп. классы.
		   Ширину ставим setProperty с 'important' - темы (proton: 90%/max 800px)
		   держат свою с !important, и обычный инлайн ей проигрывает. */
		var _hwMd = document.querySelector('#modal_overlay .modal') || document.querySelector('.modal');
		if (_hwSec && _hwMd) {
			var _hwW = Math.round(_hwSec.getBoundingClientRect().width) + 'px';
			_hwMd.style.setProperty('max-width', _hwW, 'important');
			_hwMd.style.setProperty('width', _hwW, 'important');
		}
	});
}

function buildBar(list, redraw) {
	var active = activeIface(list);
	/* Приоритет интернета (кнопки интерфейсов) - только если виджет включён. */
	/* КАРТОЧКИ СТОЯТ ПО ПРИОРИТЕТУ: сортируем по метрике по возрастанию, чтобы
	   левая = приоритет 1, следующая = 2 и т.д. Так порядок виден и без
	   перетаскивания (и сразу показывает результат, если drag не сработал). */
	var _sorted = (_widgets.netpri ? list.slice() : []).sort(function(a, b) {
		/* Упавшие/пропавшие - В КОНЕЦ ряда на время реанимации (решение
		   владельца): порядок живых читается без мысленных вычетов, а лежащий
		   виден с краю со своим статусом лечения. Внутри групп - по метрике. */
		var da = (a.health === 'down' || a.health === 'gone') ? 1 : 0;
		var db = (b.health === 'down' || b.health === 'gone') ? 1 : 0;
		if (da !== db) { return da - db; }
		var ma = parseInt(a.metric, 10); if (isNaN(ma)) { ma = 999; }
		var mb = parseInt(b.metric, 10); if (isNaN(mb)) { mb = 999; }
		if (ma !== mb) { return ma - mb; }
		return (b.ip ? 1 : 0) - (a.ip ? 1 : 0);   // при равной метрике - у кого есть IP, тот выше
	});
	var btns = _sorted.map(function(o, _rank) {
		var isA = (o.iface === active);
		/* Интерфейс ПРОПАЛ (устройства нет на шине) - на его месте пустая
		   карточка с пунктирной обводкой, тем же стилем, что слот при
		   перетаскивании (netpri-slot). Содержимое остаётся в разметке, но
		   невидимо - так карточка держит родные размеры. Кликать/таскать
		   нечего - pointer-events глушатся классом netpri-gone. */
		var isGone = (o.health === 'gone');
		/* СИРОТА ВНЕ ЗОНЫ WAN (nozone=1, живой случай 17.08.2026): мастер LuCI
		   «Подключиться к сети» создал STA-интерфейс, но зону wan ему не
		   назначили - связь есть, а аплинком он быть не может (нет NAT из LAN).
		   Показываем карточку с пунктиром и делаем клик ЛЕЧЕНИЕМ: netpri.sh
		   adoptzone добавляет интерфейс в зону, и карточка оживает. */
		var isOrphan = !!o.nozone;
		return E('button', {
			'class': 'btn cbi-button netpri-btn' + (isGone ? ' netpri-slot netpri-gone' : (isOrphan ? ' netpri-slot' : (isA ? ' active' : ''))),
			'data-iface': o.iface,
			'data-tooltip': isOrphan
				? _('This Wi-Fi uplink is not in the wan firewall zone - click to add it and make it usable')
				: (o.iface + (o.metric != null ? (' · metric ' + o.metric) : '')),
			'click': function(ev) {
				/* click, сгенерированный сразу после drop, игнорируем. */
				if (_npJustDragged) { _npJustDragged = false; return; }
				var ifc = ev.currentTarget.getAttribute('data-iface');
				if (isOrphan) {
					_npApplying = true;
					L.resolveDefault(fs.exec(BIN, [ 'adoptzone', ifc ]), {}).then(function() {
						loadList().then(function(l2) { redraw(l2); _npApplying = false; });
					}, function() { _npApplying = false; });
					return;
				}
				if (ifc === active) { return; }
				/* Клик = «сделать первым»: строим НОВЫЙ ПОРЯДОК (кликнутый впереди,
				   остальные в текущем порядке) и отдаём как order - метрики станут
				   рангом. Переключение мгновенное (живой ip route), спиннер не нужен;
				   оптимистично подсвечиваем карточку сразу. */
				var card = ev.currentTarget, row = card.parentNode;
				if (row) { row.querySelectorAll('.netpri-btn.active').forEach(function(b) { b.classList.remove('active'); }); }
				card.classList.add('active');
				var order = [ ifc ].concat(_sorted.filter(function(o) { return o.iface !== ifc; }).map(function(o) { return o.iface; }));
				/* пауза poll до подтверждения - как у drop (иначе тик мог перерисовать
				   старый порядок, пока order пишет метрики). */
				_npApplying = true;
				var _done = function() { _npApplying = false; };
				setTimeout(_done, 4000);
				L.resolveDefault(fs.exec(BIN, [ 'order' ].concat(order)), {}).then(function() {
					loadList().then(function(l2) { redraw(l2); _done(); });
				}, _done);
			}
		}, (function() {
			/* Пропавший интерфейс: внутри пунктирного слота - три мерцающих
			   плейсхолдера (те же tgm-skel-bar, что у карточки «Модем» при
			   загрузке) вместо невидимых реальных строк: читается как «место
			   занято, ждём возвращения», а размеры карточки сохраняются. */
			if (isGone) {
				/* Размеры держит НЕВИДИМОЕ родное содержимое (те же три строки,
				   что у обычной карточки - ряд не дёргается ни на пиксель),
				   а скелетоны лежат ПОВЕРХ отдельным absolute-слоем. */
				return [
					rankEl(_rank, o),
					E('span', { 'class': 'netpri-sub' }, o.sub || o.iface),
					E('span', { 'class': 'netpri-name' }, o.iface),
					E('span', { 'class': 'netpri-ip empty' }, '***.***.***.***'),
					E('span', { 'class': 'netpri-skelov' }, [
						/* ширины В ПРОЦЕНТАХ от карточки: em-значения на узкой
						   карточке вылезали за рамку */
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:55%' }),
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:85%' }),
						E('span', { 'class': 'tgm-skel-bar', 'style': 'width:65%' })
					])
				];
			}
			/* КАРТОЧКА РЕАНИМАЦИИ. Пока сторож лечит линк, карточка меняет
			   смысл строк (решение владельца): сверху - ступень и счёт попыток
			   («Перезагрузка (2/6)»), жирным - имя интерфейса вместо оператора,
			   внизу - красная лампочка, секунды с начала попытки и команда
			   ступени. Карточка НЕ пропадает на время переэнумерации (бэкенд
			   держит состояние gone) - прячется она только после грейс-периода,
			   и это решает list, а не мы. */
			if (o.health === 'down' && o.healstep) {
				/* ПОДПИСЬ СТУПЕНИ - ПО СВОЕЙ ЛЕСТНИЦЕ. У Wi-Fi-аплинка ступени
				   совсем другие, чем у модема, и подписывать их модемными
				   значило печатать неправду: на падении станции карточка
				   показывала «AT+CFUN=1,1» - AT-команду, которую Wi-Fi никто
				   не слал (лечение модема к чужому интерфейсу и не подпустит,
				   см. sec_for_iface_h в health.sh). Тип лестницы приходит с
				   бэкенда: только он знает, чем этот линк является. */
				var ladders = {
					wifi: [
						[ _('Reconnecting'),        'ifdown/ifup' ],
						[ _('Reassociating'),       'REASSOCIATE' ],
						[ _('Restarting the radio'), 'wireless down/up' ],
						[ _('Rebuilding the network'), 'network reload' ]
					],
					hilink: [
						[ _('Reconnecting'),  'ifdown/ifup' ],
						[ _('Rebooting'),     _('modem web API') ],
						[ _('USB power cycle'), 'USB power' ]
					],
					modem: [
						[ _('Reconnecting'),  'ifdown/ifup' ],
						[ _('Rebooting'),     'AT+CFUN=1,1' ],
						[ _('USB power cycle'), 'USB power' ]
					]
				};
				var ladder = ladders[o.healkind] || ladders.modem;
				var step = ladder[o.healstep - 1] || ladder[ladder.length - 1];
				var stepName = step[0], stepCmd = step[1];
				/* Секунды с начала попытки - С ЕДИНИЦЕЙ. Голое «1432» рядом с
				   именем команды читается как счётчик чего угодно, чаще всего
				   как число попыток. */
				var forTxt = null;
				if (o.healfor != null) {
					forTxt = (o.healfor < 90) ? _('%ds').format(o.healfor)
					                          : _('%dm').format(Math.round(o.healfor / 60));
				}
				return [
					E('span', { 'class': 'netpri-sub' }, stepName + ' (' + o.healn + '/' + o.healmax + ')'),
					E('span', { 'class': 'netpri-name' }, o.iface),
					E('span', { 'class': 'netpri-ip' }, [
						E('span', { 'class': 'netpri-svcdot netpri-health off', 'title': _('No internet on this link') }),
						(forTxt ? forTxt + ' | ' : '') + stepCmd
					])
				];
			}
			return [
			rankEl(_rank, o),
			E('span', { 'class': 'netpri-sub' },
				isOrphan ? _('not in wan zone — click to fix') : (o.sub || o.iface)),
			nameEl(o),
			/* keep the IP line present even without an address so the button height
			   never changes; show a neutral placeholder while there is no IP yet.
			   Лампочка здоровья от сторожа (health.sh) - В СТРОКЕ IP, перед
			   адресом, тем же стилем, что точки статусов виджетов (netpri-svcdot:
			   размер и свечение). Поле health есть только при включённом
			   слежении - без него карточка как раньше. */
			(function() {
				/* ВНЕШНИЙ АДРЕС - ТОЛЬКО НА АКТИВНОЙ КАРТОЧКЕ. Он описывает
				   маршрут по умолчанию, а не интерфейс: на соседних аплинках,
				   через которые сейчас никто не ходит, это была бы неправда. */
				/* У КАЖДОЙ КАРТОЧКИ - СВОЙ внешний адрес, если он уже известен:
				   карточка модема берёт адрес, узнанный ЧЕРЕЗ МОДЕМ (за ним
				   следит страница модема), остальным годится общий - маршрут по
				   умолчанию, а он и есть активный аплинк. Новых запросов это не
				   добавляет: показываем то, что и так опрошено. */
				var ex = extip.state(o.iface);
				if (!ex.ip && isA) { ex = extip.state(''); }
				var extShown = !!(extip.flags().inNetpri && ex.ip);
				return E('span', {
					'class': 'netpri-ip' + ((o.ip || extShown) ? '' : ' empty'),
					'data-tooltip': extShown
						? _('External address via %s. Interface address: %s')
							.format(ex.src || '?', o.ip || '-')
						: null
				}, [
					o.health ? E('span', {
						'class': 'netpri-svcdot netpri-health ' +
							(o.health === 'up' ? 'on' : (o.health === 'down' || o.health === 'gone' ? 'off' : 'unknown')),
						'title': (o.health === 'up') ? _('Internet is working (%s ms)').format(o.hms)
						       : (o.health === 'down') ? _('No internet on this link')
						       : (o.health === 'gone') ? _('Device is gone')
						       : _('Checking…')
					}) : '',
					extShown ? extip.withFlag(ex.ip, ex.cc) : (o.ip || '***.***.***.***')
				]);
			})()
			];
		})());
	});
	/* Правая группа виджетов: карточки пинга -> сервисы -> спидтест. Первому
	   вешаем netpri-rightstart -> вся группа уходит вправо (margin-left:auto). */
	var right = [];
	if (_widgets.status) { _pingWidgets.forEach(function(w) { right.push(pingCard(w)); }); }
	if (_widgets.services) {
		// Карточки ведёт КОНФИГ пользователя (секции svcwidget) - и только он.
		// Выбран ssclash/clash -> карточку SSClash показываем БЕЗУСЛОВНО; detect
		// (ssclash.sh) лишь наполняет порт/версию/статус, его провал НЕ прячет
		// выбранную карточку. Не выбран -> не показываем (и убирается в настройках).
		effectiveSvcs().forEach(function(svc) {
			var _sk = sscKindForSvc(svc);
			if (_sk) { right.push(ssClashBtn(_sk)); }
			else { right.push(svcCard(svc)); }
		});
	}
	if (_widgets.speedtest) { right.push(stCard()); }
	/* ПОРЯДОК, ЗАДАННЫЙ ЧЕЛОВЕКОМ. Карточки, которых нет в сохранённом списке
	   (только что добавленная в настройках, новая служба), уходят в КОНЕЦ и не
	   ломают уже выстроенный ряд. */
	if (_widgetOrder.length) {
		right.sort(function(a, b) {
			var ia = _widgetOrder.indexOf(a.getAttribute('data-wkey'));
			var ib = _widgetOrder.indexOf(b.getAttribute('data-wkey'));
			if (ia < 0) { ia = 1e6; }
			if (ib < 0) { ib = 1e6; }
			return ia - ib;
		});
	}
	if (right.length) { right[0].classList.add('netpri-rightstart'); }
	btns = btns.concat(right);
	/* Сворачивание убрано. Небольшой заголовок «Приоритет интернета» возвращаем
	   ТОЛЬКО когда включён одноимённый виджет - иначе новому пользователю
	   непонятно, что за кнопки; при выключенном виджете заголовок не нужен. */
	var kids = [];
	if (_widgets.netpri) {
		/* Шестерёнка настроек сторожа - в заголовке, ПЕРЕД текстом: слежение
		   общее на все линки, а не свойство одного. */
		kids.push(E('div', { 'class': 'netpribar-title' }, [
			E('span', {
				'class': 'netpri-gear',
				'title': _('Internet watchdog settings'),
				'click': function(ev) { ev.stopPropagation(); healthModal(); }
			}, '⚙'),
			_('Internet priority')
		]));
		/* ТРАФИК ДЕРЖИТ ЛИНК БЕЗ ИНТЕРНЕТА, А УВОДИТЬ ЕГО НЕКОМУ.
		   Сторож такое видит (красная точка на карточке), но при снятой галке
		   «переключать трафик» намеренно бездействует - и со стороны это
		   неотличимо от «приложение сломалось». Живой случай: Wi-Fi-аплинк
		   первым в приоритете прицепился к точке без интернета и держал весь
		   трафик поверх четырёх работающих модемов. Пишем прямо, что происходит,
		   и даём включить одним кликом. */
		var carrier = null;
		list.forEach(function(o) { if (o.iface === active) { carrier = o; } });
		if (_hfo === false && carrier && (carrier.health === 'down' || carrier.health === 'gone')) {
			kids.push(E('div', { 'class': 'netpri-warn' }, [
				E('span', { 'class': 'netpri-warn-ic' }, '⚠'),
				_('Traffic goes through %s, and there is no internet on it. Automatic switching is off - the watchdog sees the failure and does nothing.').format(carrier.sub || carrier.iface),
				' ',
				E('a', {
					'href': '#',
					'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); healthModal(); }
				}, _('Turn switching on'))
			]));
		}
	}
	var rowEl = E('div', { 'class': 'netpri-row' }, btns);
	/* перетаскивание карточек-аплинков - только когда виджет приоритета включён */
	if (_widgets.netpri) { _npEnableReorder(rowEl, redraw); }
	/* Правые виджеты тасуются между собой независимо от аплинков. */
	_npEnableReorder(rowEl, null, 'data-wkey');
	kids.push(rowEl);
	/* Строку последнего события под карточками убрали (решение владельца):
	   статус лечения теперь живёт В САМОЙ карточке, а полная история - в
	   logread по тегу 5gmodem. Бэкенд событие по-прежнему шлёт (хвост list),
	   loadList его вынимает - просто не рисуем. */
	var _bar = E('div', { 'class': 'netpribar' }, kids);
	/* Класс темы ставим ПОСЛЕ вставки в документ: до этого у узла нет ни
	   родителя, ни унаследованного цвета, и getComputedStyle врёт. */
	window.setTimeout(npSyncTheme, 0);
	npWatchTheme();
	return _bar;
}

/* ТЕМУ ПЕРЕСПРАШИВАЕМ, А НЕ ЗАПОМИНАЕМ ОДИН РАЗ.
   Класс netpri-dark ставился ровно однажды, сразу после вставки блока. Пока
   тему меняют перезагрузкой страницы, этого хватает; но если её переключают
   на живой странице, класс остаётся ПРЕЖНИМ до следующей полной перерисовки -
   а она приходит только с тиком опроса, раз в 15 c. Наружу это выглядело так:
   переключил на светлую - значков в карточках пингов и сервисов несколько
   секунд нет (силуэты остались инвертированными, то есть белыми на белом);
   переключил на тёмную - несколько секунд держатся старые цвета, потом
   «сами инвертируются» (жалоба владельца 04.09.2026; в прошлый раз я не смог
   это воспроизвести, потому что проверял перезагрузкой страницы, а не
   переключением темы). */
function npSyncTheme() {
	var bar = document.querySelector('.netpribar');
	if (!bar || !bar.isConnected) { return; }
	bar.classList.toggle('netpri-dark', isDarkUI(bar));
}
var _npThemeWatched = false;
function npWatchTheme() {
	if (_npThemeWatched) { return; }
	_npThemeWatched = true;
	/* Тему меняют по-разному: класс/атрибут на <html> или <body>, подмена
	   тега <link> в <head>, системная настройка. Слушаем все три источника -
	   проверка стоит один getComputedStyle, дешевле любой перерисовки. */
	try {
		var obs = new MutationObserver(function() { window.setTimeout(npSyncTheme, 0); });
		obs.observe(document.documentElement, { attributes: true,
			attributeFilter: [ 'class', 'style', 'data-theme', 'data-darkmode' ] });
		if (document.body) {
			obs.observe(document.body, { attributes: true, attributeFilter: [ 'class', 'style' ] });
		}
		obs.observe(document.head, { childList: true });
	} catch (e) {}
	try {
		var mq = window.matchMedia('(prefers-color-scheme: dark)');
		if (mq.addEventListener) { mq.addEventListener('change', npSyncTheme); }
		else if (mq.addListener) { mq.addListener(npSyncTheme); }
	} catch (e) {}
}

return baseclass.extend({
	/* Смонтировать блок ВНУТРИ контента страницы (под под-вкладками, как обычный
	   элемент вьюхи). Возвращает контейнер СРАЗУ (синхронно), наполняется асинхронно
	   и живёт своим поллом. Так блок виден на всех темах и на мобильном - в отличие
	   от старой вставки над вкладками, которую мобильная вёрстка прятала. Вставляется
	   самой вьюхой (5gdetail) в начало контента - код проще, без DOM-инъекций. */
	mount: function() {
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
			if (_npDrag || _npApplying) { return; }   // пауза во время перетаскивания и применения порядка
			// НЕ убираем блок на пустом ответе: при переключении модема (перезагрузка
			// active_modem) netpri.sh list на миг может вернуть [], и блок мигал/пропадал.
			// Просто перерисовываем при наличии данных; последнее содержимое «липкое».
			if (list && list.length) { redraw(list); }
		};
		/* Сначала флаги видимости виджетов, потом отрисовка - иначе на первый
		   кадр показали бы отключённые виджеты. uci.load обычно уже в кэше
		   (страница «Сеть» его грузит), так что это почти синхронно. */
		/* Внешний адрес подтягиваем ОДНИМ опросом на страницу (extip.js);
		   пришёл он позже первого кадра - перерисуем ряд на месте. */
		extip.init().then(function(fl) {
			if (!fl.inNetpri) { return; }
			extip.watch('');
			extip.subscribe(function() { redraw(lastList()); });
		});
		loadWidgetFlags().then(function() {
			/* WARM-RENDER: первый кадр рисуем БЕЗУСЛОВНО (даже пустым списком) -
			   иначе при отключённом «Приоритете интернета» и пустом списке
			   карточки YouTube/SSClash/спидтеста не появились бы. Дальше apply
			   держит содержимое «липким» (пустые ответы не стирают). */
			redraw(lastList());
			L.resolveDefault(loadList()).then(apply);
			if (_widgets.speedtest) { stInit(); }
			if (_widgets.status) { pingInit(); }
			if (_widgets.services) {
				// detect/статус запускаем ТОЛЬКО для выбранных пользователем веток.
				// Карточка показывается по конфигу (см. buildBar) независимо от
				// detect; здесь лишь наполняем порт/версию и красим статус-точку.
				var _svcs = effectiveSvcs();
				if (_svcs.indexOf('ssclash') >= 0) { ssclashInit('go', redraw); ssclashStatusInit('go'); }
				if (_svcs.indexOf('clash') >= 0) { ssclashInit('legacy', redraw); ssclashStatusInit('legacy'); }
				svcStatusInit(_svcs);
			}
		});
		/* wrap возвращается СИНХРОННО, а в DOM его вставляет вьюха ПОЗЖЕ. Поэтому
		   «нет в DOM» на первых тиках - это ещё не «блок убрали»: раньше поллер в
		   такой момент снимал сам себя НАВСЕГДА, и блок оставался пустым div'ом -
		   отсюда «Internet priority отрисовывается не всегда». Снимаемся только
		   после того, как блок реально побывал в DOM и оттуда исчез. */
		var seen = false;
		var pollFn = function() {
			if (document.body.contains(wrap)) { seen = true; }
			else if (seen) {
				/* Флаг СБРАСЫВАЕМ вместе со снятием: иначе следующий экземпляр
				   блока никогда не зарегистрирует опрос - гард ниже посчитает,
				   что поллер уже есть, и ряд молча замрёт до перезагрузки. */
				window._npListPoll = false;
				poll.remove(pollFn); return Promise.resolve();
			}
			return loadList().then(apply);
		};
		/* КАДЕНЦИЯ 15 c, А НЕ 5.
		   Замер на стенде: один `netpri.sh list` - это ~0.58 c работы роутера
		   (69 подпроцессов даже после того, как состояние интерфейсов, конфиг и
		   перечисление модемов стали браться одним снимком). При опросе раз в 5 c
		   это больше десятой части всего процессорного времени, отданной списку
		   аплинков, - и почти всегда впустую: состав, тип, модель и метрика между
		   тиками не меняются.
		   Опрос здесь нужен ТОЛЬКО для пассивных изменений (модем сам получил или
		   потерял IP): любое действие пользователя - выбор приоритета,
		   перетаскивание - перечитывает список само, сразу после записи (см.
		   вызовы loadList после 'order'). Цена решения честная: адрес, появившийся
		   без нашего участия, доедет до панели за 15 c вместо 5. В карточке модема
		   он при этом виден с прежней свежестью - там свой опрос. */
		if (!window._npListPoll) { window._npListPoll = true; poll.add(pollFn, 15); }
		return wrap;
	},

	/* Promise<DOM|null>. null — если ни одного WAN-аплинка с IP нет. */
	renderBar: function() {
		var mk = function(list) {
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
			/* Тот же единый опрос внешнего адреса, что и в mount(): ряд на
			   странице состояния - такой же его потребитель. */
			extip.init().then(function(fl) {
				if (!fl.inNetpri) { return; }
				extip.watch('');
				extip.subscribe(function() { redraw(lastList()); });
			});
			if (_widgets.speedtest) { stInit(); }
			if (_widgets.status) { pingInit(); }
			if (_widgets.services) {
				// detect/статус запускаем ТОЛЬКО для выбранных пользователем веток.
				// Карточка показывается по конфигу (см. buildBar) независимо от
				// detect; здесь лишь наполняем порт/версию и красим статус-точку.
				var _svcs = effectiveSvcs();
				if (_svcs.indexOf('ssclash') >= 0) { ssclashInit('go', redraw); ssclashStatusInit('go'); }
				if (_svcs.indexOf('clash') >= 0) { ssclashInit('legacy', redraw); ssclashStatusInit('legacy'); }
				svcStatusInit(_svcs);
			}
			/* Keep the bar live with a steady poll: the operator name (bounded
			   AT+COPS in the background) resolves after a few seconds, and — the
			   point here — a modem's IP that comes back AFTER re-dialing (which can
			   take much longer than a fixed retry window) shows up on its own, with
			   no manual page reload. Self-removes once the bar leaves the DOM. */
			var pollFn = function() {
				if (!document.body.contains(wrap)) {
					window._npListPoll = false;   // см. такой же поллер в mount()
					poll.remove(pollFn); return Promise.resolve();
				}
				if (_npDrag || _npApplying) { return Promise.resolve(); }   // пауза при drag/применении
				return loadList().then(redraw);
			};
			/* 15 c, а не 5 - обоснование см. у такого же поллера в mount(). */
			if (!window._npListPoll) { window._npListPoll = true; poll.add(pollFn, 15); }
			return { wrap: wrap, redraw: redraw };
		};
		/* Флаги видимости - до сборки; затем warm-render из кэша. Блок рисуем,
		   если есть интерфейсы ЛИБО включён любой из отдельных виджетов
		   (youtube/ssclash/speedtest живут без списка интерфейсов). */
		return loadWidgetFlags().then(function() {
			var extra = _widgets.status || _widgets.services || _widgets.speedtest;
			var cached = lastList();
			if (cached.length || extra) {
				var b = mk(cached);
				loadList().then(function(l) { if (l && l.length) { b.redraw(l); } });
				return b.wrap;
			}
			return loadList().then(function(list) {
				if (!list.length && !extra) { return null; }
				return mk(list).wrap;
			});
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
