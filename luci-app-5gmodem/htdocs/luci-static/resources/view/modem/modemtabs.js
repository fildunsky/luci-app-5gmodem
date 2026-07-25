'use strict';
'require baseclass';
'require fs';
'require uci';
'require poll';
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
	display: inline-flex; align-items: center; gap: .4em;
}
.modembar .modemtabs-bar .modemtab .modemtab-ic {
	width: 16px; height: 16px; flex: 0 0 auto; display: block;
}
/* Имя модема - моноширинным, как строка с полным именем в шапке (.modembar-name):
   это идентификатор железа, а не обычный текст, и одинаковая ширина знаков
   помогает сравнивать похожие названия соседних модемов. */
.modembar .modemtabs-bar .modemtab span {
	font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
/* Активный модем помечаем как активную кнопку приоритета интернета - то есть
   тем же, чем тема помечает кнопку на hover: одна акцентная рамка, без заливки
   и без внутренней обводки (та удваивала линию и смотрелась жирно). */
.modembar .modemtabs-bar .modemtab.active {
	border-color: var(--proton-accent, #0095ff);
	pointer-events: none;
}
/* Кнопка-заготовка: та же геометрия и то же содержимое, что у настоящей
   вкладки, поэтому ряд занимает свою итоговую высоту с первого кадра.
   Клики глушим классом, а НЕ атрибутом disabled: тема даёт [disabled]
   opacity .5, и заготовка с именем из кеша была бы заметно блёклой -
   подмена настоящими данными бросалась бы в глаза. */
.modembar .modemtabs-bar .modemtab-ghost { pointer-events: none; }
/* Имени в кеше нет (первый заход): нейтральная подпись и приглушённый вид,
   чтобы было видно, что данные ещё едут. */
.modembar .modemtabs-bar .modemtab-blank { min-width: 9em; opacity: .45; }
`;

/* Бренд по VID (или по характерному имени продукта). USB-дескриптор часто даёт
   только платформу ("VOS_5G", "Android"), поэтому добавляем читаемый бренд. */
function vendor(m) {
	var pr = String((m && m.product) || '');
	if (/VOS_5G|RXMG1/i.test(pr)) { return 'Compal'; }
	var vid = String((m && m.vidpid) || '').split(':')[0].toLowerCase();
	var map = {
		'1bc7': 'Telit', '2c7c': 'Quectel', '2cb7': 'Fibocom',
		'0e8d': 'Fibocom', '1e2d': 'Cinterion', '12d1': 'Huawei', '19d2': 'ZTE',
		'2dee': 'Foxconn', '0489': 'Foxconn', '413c': 'Dell', '05c6': 'Compal',
		'1e0e': 'SimCom'
	};
	return map[vid] || '';
}

/* Точная модель по VID:PID - для модемов, чей USB-дескриптор бесполезен.
   Quectel EC21 прошит как "Android", и вкладка называлась "Quectel модем":
   дескриптор уходил в ветку generic ниже. VID:PID при этом однозначен.
   Тот же список ведётся в netpri.sh (model_for) для «Приоритета интернета». */
var MODEL_BY_VIDPID = {
	'2c7c:0121': 'EC21',    '2c7c:0125': 'EC25',   '2c7c:0296': 'BG96',
	'2c7c:0306': 'EP06',    '2c7c:0512': 'EG12',   '2c7c:0620': 'EM060K',
	'2c7c:0800': 'RM500Q',  '2c7c:0801': 'RM520N', '2c7c:0900': 'RG500Q'
};

/* clean up the raw USB product string into a readable model. The Compal exposes
   only "VOS_5G"/"RXMG1" in its descriptor - show the marketed model instead, to
   match the "Compal RXM-G1" name used in the info-page header. */
function modelName(m) {
	/* Имя, разобранное основным опросом по AT+CGMM и сохранённое в секции модема
	   (5gmodem.m_<путь>.model) - самое точное. Нужно там, где ни дескриптор, ни
	   VID:PID не помогают: SimCom говорит "SimTech, Incorporated", а её
	   1e0e:9001 общий для SIM7100/7600/8200 - различить можно только по AT. */
	if (m && m.model) { return String(m.model).trim(); }
	var id = String((m && m.vidpid) || '').toLowerCase();
	if (MODEL_BY_VIDPID[id]) { return MODEL_BY_VIDPID[id]; }
	var p = (m && m.product) ? String(m.product).trim() : '';
	if (/^(VOS_5G|RXMG1|RXM-G1)$/i.test(p)) { return 'RXM-G1'; }
	return p;
}

/* Развести ОДИНАКОВЫЕ подписи.
   Модемы различаются USB-путём, а вот имя у двух одинаковых модулей совпадает -
   и во вкладках получались два неотличимых ярлыка. К повторяющимся дописываем
   путь: он привязан к физическому разъёму, поэтому "тот, что в верхнем порту"
   остаётся тем же и после перезагрузки. Уникальные подписи не трогаем - лишний
   технический хвост там ни к чему. */
function dedupLabels(modems) {
	var seen = {}, out = modems.map(function(m, i) { return label(m, i); });
	out.forEach(function(l) { seen[l] = (seen[l] || 0) + 1; });
	return out.map(function(l, i) {
		return (seen[l] > 1) ? (l + ' (' + (modems[i].path || (i + 1)) + ')') : l;
	});
}

function label(m, i) {
	var p = modelName(m);
	var v = vendor(m);
	var generic = (!p || /^android$/i.test(p) || /^usb/i.test(p) || /^simtech/i.test(p)
		|| (/modem/i.test(p) && p.length < 6));
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

/* Показ/скрытие вкладки eSIM по живому состоянию. esim.sh status -> {available,
   active}; active=1 => текущий слот модема - eSIM (только тогда lpac работает и
   управление профилями имеет смысл, см. форум prusa: нужен AT+GTDUALSIM=1).
   Ссылку вкладки ищем в меню под-вкладок (href .../5gmodem/esim); прячем её <li>.
   Ретраим, т.к. тема может отрисовать под-вкладки позже нашего вызова. */
/* ВКЛАДКА eSIM: прячем ПРАВИЛОМ CSS, а не перебором ссылок.
   Мигание было потому, что вкладку рисует сама LuCI, а мы убирали её лишь
   после ответа esim.sh (~1 c) - всё это время она была видна. Правило стиля
   применяется до отрисовки, поэтому вспышки нет вовсе.
   Состояние помним между заходами: на модеме С eSIM иначе мигало бы наоборот -
   вкладка пряталась бы на секунду при каждом открытии страницы. */
/* Ключ памяти - СВОЙ У КАЖДОГО МОДЕМА. Раньше он был общий, и при переходе с
   модема с eSIM на модем без неё вкладка успевала показаться: применялось
   запомненное «была», а опрос отвечал только через секунду. У модемов без
   AT-портов eSIM невозможна в принципе, и мелькать ей незачем. */
var ESIM_SEEN_BASE = '5gmodem.esim.active';
function esimSeenKey() {
	var p = '';
	try { p = (uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''); } catch (e) {}
	return p ? (ESIM_SEEN_BASE + '.' + p) : ESIM_SEEN_BASE;
}

function esimHideRule(on) {
	var st = document.getElementById('esim-tab-hide');
	if (on) {
		if (!st) {
			st = E('style', { 'id': 'esim-tab-hide', 'type': 'text/css' },
				'a[href*="5gmodem/esim"], li:has(> a[href*="5gmodem/esim"]) { display: none !important; }');
			document.head.appendChild(st);
		}
	} else if (st && st.parentNode) {
		st.parentNode.removeChild(st);
	}
}

/* Применяем ЗАПОМНЕННОЕ состояние немедленно, ещё до всякого опроса.
   ТОЛЬКО ЕСЛИ ЗНАЕМ, О КАКОМ МОДЕМЕ РЕЧЬ. Ключ памяти привязан к активному
   модему, но uci на этот момент может быть ещё не загружен - тогда
   esimSeenKey() возвращает общий ключ, и от ПРЕЖНЕГО модема наследовалась
   чужая память: при переходе на Huawei (eUICC нет) вкладка оставалась видимой
   всё время пробы, а она у модема без eUICC занимает секунды.
   Не знаем модема - ПРЯЧЕМ: лишняя вкладка на двадцать секунд раздражает
   сильнее, чем нужная, появившаяся секундой позже. */
(function() {
	var was = '0', keyed = false;
	try {
		var k = esimSeenKey();
		keyed = (k !== ESIM_SEEN_BASE);
		was = localStorage.getItem(k) || '0';
	} catch (e) {}
	esimHideRule(!(keyed && was === '1'));
})();

function applyEsimTabVisibility(tries) {
	/* fs.exec, а не fs.exec_direct: последний ходит через /cgi-bin/cgi-exec -
	   отдельный хелпер, который в этом приложении уже отвечал "404 Executable
	   not found". fs.exec идёт через ubus file.exec. */
	/* Конфиг нужен, чтобы ключ памяти был привязан к АКТИВНОМУ модему. Этот файл
	   uci сам не грузит, а страницы делают это по-разному - грузим явно. */
	return L.resolveDefault(uci.load('5gmodem'))
		.then(function() {
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/esim.sh', [ 'status' ]), {});
		})
		.then(function(r) {
			var st = {};
			try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			/* PENDING: проба eUICC ещё не готова (status кинул её в фон, чтобы не
			   тормозить загрузку). Не трогаем видимость, а ПЕРЕПРАШИВАЕМ через
			   пару секунд - к тому моменту фоновая проба допишет кэш, и вкладка
			   появится/скроется без задержки открытия страницы. */
			if (st && st.pending) {
				var t = (typeof tries === 'number') ? tries : 0;
				if (t < 8) { window.setTimeout(function() { applyEsimTabVisibility(t + 1); }, 2000); }
				return;
			}
			/* ВИДИМОСТЬ - ПО НАЛИЧИЮ eUICC, А НЕ ПО ВКЛЮЧЁННОМУ ПРОФИЛЮ.
			   Правильный признак - available: есть ли на модеме eUICC вообще. */
			var have = !!(st && st.available);
			esimHideRule(!have);
			try { localStorage.setItem(esimSeenKey(), have ? '1' : '0'); } catch (e) {}
		});
}

/* Ряд-заготовка. Модем всегда есть минимум один, поэтому рисуем его место
   сразу, не дожидаясь данных: иконка на своём месте, подпись - из кеша
   прошлого захода, а если кеша нет, нейтральное «Модем». Если модемов
   окажется больше, остальные кнопки встанут в ту же строку и высота ряда не
   изменится. */
function ghostBar() {
	var items = tabsCacheLoad() || [ { label: null, active: true } ];

	return E('div', { 'class': 'modemtabs-bar' }, items.map(function(it) {
		return E('button', {
			'class': 'btn cbi-button modemtab modemtab-ghost'
				+ (it.label ? '' : ' modemtab-blank')
				+ (it.active ? ' active' : '')
		}, [
			E('img', {
				'class': 'modemtab-ic',
				'src': L.resource(it.usb ? 'icons/cusb.svg' : 'icons/cmodem.svg'),
				'width': 16, 'height': 16, 'alt': ''
			}),
			E('span', {}, it.label || _('Modem'))
		]);
	}));
}

/* Вставка полосы над меню под-вкладок. Под-вкладок на момент render() может
   ещё не быть, поэтому опрашиваем DOM; при неудаче кладём в начало контента. */
function placeBar(el) {
	var tries = 0;
	(function place() {
		if (el.parentNode) { return; }
		var anchor = document.querySelector('#tabmenu')
			|| document.querySelector('ul.cbi-tabmenu')
			|| document.querySelector('.cbi-tabmenu');
		if (anchor && anchor.parentNode) { anchor.parentNode.insertBefore(el, anchor); return; }
		if (tries++ < 20) { window.setTimeout(place, 150); return; }
		var c = document.querySelector('#maincontent') || document.querySelector('#view') || document.body;
		if (c) { c.insertBefore(el, c.firstChild); }
	})();
}

/* КЕШ ПОДПИСЕЙ ВКЛАДОК.
   Заготовка рисуется до всяких запросов, а имя модема известно только после
   listmodems.sh. Берём его из прошлого захода: тогда заготовка совпадает с
   итогом вплоть до текста, и подмена данными визуально не видна вовсе.
   Кеш может устареть (модем поменяли) - это безопасно: он живёт доли секунды
   до прихода настоящего списка, который его тут же и перезапишет. */
var TABS_CACHE = '5gmodem.modemtabs';

/* USB-свисток (Huawei E3372 и родня) - рисуем значок USB вместо чипа.
   Признак - вендор 12d1: по наличию сетевой карты это НЕ определить, у
   M.2-модулей с ECM-дозвоном (FM350) она тоже есть, и значок уезжал им тоже. */
function isUsbStick(m) {
	return /^12d1:/i.test((m && m.vidpid) || '');
}

function tabsCacheSave(modems, active) {
	try {
		var lbl = dedupLabels(modems);
		window.localStorage.setItem(TABS_CACHE, JSON.stringify(modems.map(function(m, i) {
			/* usb сохраняем, чтобы в заготовке (до ответа listmodems) значок был
			   сразу правильным и не подменялся на глазах. */
			return { label: lbl[i], active: (m.path === active), usb: isUsbStick(m) };
		})));
	} catch (e) {}
}

function tabsCacheLoad() {
	try {
		var a = JSON.parse(window.localStorage.getItem(TABS_CACHE) || 'null');
		return (Array.isArray(a) && a.length) ? a : null;
	} catch (e) { return null; }
}

/* СЛЕЖЕНИЕ ЗА ПОЯВЛЕНИЕМ/ИСЧЕЗНОВЕНИЕМ МОДЕМА - БЕЗ ЗАПУСКА СКРИПТОВ.
   listmodems.sh держит готовый JSON в /tmp/5gmodem_listmodems.cache, а
   hotplug-хук (etc/hotplug.d/usb/71-5gmodem-resolve) при add/remove модема
   сбрасывает этот кэш сразу и пересобирает через 5 секунд, когда порты
   устоялись. Значит браузеру не нужно ничего исполнять: достаточно ЧИТАТЬ
   файл - один дешёвый вызов без форков, - и только когда набор путей реально
   изменился, перечитать состояние целиком (listmodems + active) и перерисовать
   ряд. В покое опрос не стоит почти ничего, а вставленный модем появляется
   сам, без перезагрузки страницы. */
var LIST_CACHE = '/tmp/5gmodem_listmodems.cache';

function pathsSig(list) {
	return list.map(function(m) { return m.path; }).sort().join(',');
}

function watchModems(bar, sig) {
	poll.add(function() {
		return L.resolveDefault(fs.read(LIST_CACHE), '').then(function(txt) {
			var list = [];
			try { list = JSON.parse(txt || '[]') || []; } catch (e) { return; }
			/* Пустой ответ - это НЕ «модемов нет»: hotplug удаляет кэш до того,
			   как соберёт новый, и в эту щель мы бы стёрли живой ряд. Ждём
			   следующего тика. */
			if (!Array.isArray(list) || !list.length) { return; }

			var now = pathsSig(list);
			if (now === sig) { return; }
			sig = now;

			/* Набор изменился - только теперь платим за полный опрос. */
			return loadModems().then(function(st) {
				var fresh = tabsBar(st.modems, st.active);
				if (bar.firstChild) { bar.replaceChild(fresh, bar.firstChild); }
				else { bar.appendChild(fresh); }
			});
		});
	}, 10);
}

function tabsBar(modems, active) {
	tabsCacheSave(modems, active);
	var labels = dedupLabels(modems);
	var tabs = modems.map(function(m, i) {
		var isActive = (m.path === active);
		return E('button', {
			/* без cbi-button-action: заливка темы конфликтовала бы с акцентной
			   рамкой, которой мы помечаем активный элемент (как в netpri) */
			'class': 'btn cbi-button modemtab' + (isActive ? ' active' : ''),
			'data-path': m.path,
			'data-tooltip': (m.vidpid || '') + ' @ ' + (m.path || ''),
			'click': function(ev) {
				var path = ev.currentTarget.getAttribute('data-path');
				if (path === active) { return; }
				/* Без попапа (решение владельца): переключение - это быстрые
				   uci-правки (AT-порт заново не пробуется при обычной смене
				   вкладки). Мгновенно перекидываем акцентную рамку на выбранную
				   вкладку - обратная связь есть сразу, а перезагрузку страницы
				   (нужна, чтобы весь экран перечитал данные нового модема)
				   запускаем следом. Повторные клики глушим, пока идёт switch. */
				var card = ev.currentTarget, row = card.parentNode;
				if (row) {
					row.querySelectorAll('.modemtab.active').forEach(function(b) { b.classList.remove('active'); });
					row.querySelectorAll('.modemtab').forEach(function(b) { b.style.pointerEvents = 'none'; });
				}
				card.classList.add('active');
				L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]), {})
					.then(function() { window.location.reload(); });
			}
		}, [
			/* Иконка перед именем: у модема с собственной сетевой картой (USB-
			   свисток вроде Huawei E3372, который сам держит IP-стек) - значок
			   USB, у встроенных модулей - чип. Признак берём из net[]: он есть
			   только у таких свистков, у обычных модемов пуст. */
			E('img', {
				'class': 'modemtab-ic',
				'src': L.resource(isUsbStick(m) ? 'icons/cusb.svg' : 'icons/cmodem.svg'),
				'width': 16, 'height': 16, 'alt': ''
			}),
			E('span', {}, labels[i])
		]);
	});
	return E('div', { 'class': 'modemtabs-bar' }, tabs);
}

return baseclass.extend({
	/* Шапка: только ряд вкладок выбора модема (если модемов > 1). Имя активного
	   модема показывается заголовком блока «Общая информация» в самой вьюхе.
	   Возвращает Promise<DOM|null>. null - если модем один/нет. */
	renderBar: function() {
		return loadModems().then(function(st) {
			/* Раньше при одном модеме возвращали null - полосы не было вовсе.
			   Теперь рисуем всегда: одна кнопка показывает, о каком модеме
			   страница, и, главное, высота полосы известна заранее, поэтому
			   её место резервируется заготовкой ещё до прихода данных. */
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
	/* Перечитать состояние eSIM и показать/скрыть вкладку БЕЗ перезагрузки
	   страницы. Зовётся из вьюхи eSIM после активации слота/профиля: иначе
	   вкладка появлялась только после ручного F5 (applyEsimTabVisibility
	   отрабатывает лишь при загрузке страницы). */
	refreshEsimTab: function() { applyEsimTabVisibility(0); },

	/* ПОЛОСУ СТАВИМ СРАЗУ, ДАННЫЕ ПОДКЛАДЫВАЕМ ПОТОМ.
	   Раньше вся полоса появлялась только после двух вызовов shell
	   (listmodems.sh + modemswitch.sh active) и вставлялась НАД под-вкладками -
	   в этот момент вся страница уезжала вниз. Теперь в DOM сразу уходит полоса
	   с одной кнопкой-заготовкой: высота ряда занята с первого кадра, а приход
	   данных лишь меняет содержимое строки (второй модем встаёт рядом, в ту же
	   строку). Вертикального рывка больше нет. */
	attach: function() {
		// Вкладку eSIM показываем ТОЛЬКО когда включена eSIM (активен eSIM-слот):
		// меню LuCI статично и кэшируется, поэтому прячем ссылку на лету - modemtabs
		// выполняется на КАЖДОЙ странице модема.
		applyEsimTabVisibility(0);

		var bar = document.querySelector('.modembar');
		/* полоса уже наполнена данными - второй раз не работаем */
		if (bar && !bar.classList.contains('modembar-loading')) { return Promise.resolve(); }

		ensureCss();

		if (!bar) {
			bar = E('div', { 'class': 'modembar modembar-loading' }, [ ghostBar() ]);
			placeBar(bar);
		}

		return loadModems().then(function(st) {
			bar.classList.remove('modembar-loading');
			var fresh = tabsBar(st.modems, st.active);
			if (bar.firstChild) { bar.replaceChild(fresh, bar.firstChild); }
			else { bar.appendChild(fresh); }
			watchModems(bar, pathsSig(st.modems));
		});
	},

	/* --- Оверлей «модем перезагружается» -----------------------------------
	   Накрывает блок целиком, пока модем недоступен (жёсткий ребут = переэнумерация
	   USB на 30-60 c). Живёт здесь, а не в конкретной странице: нужен и на «Сети»
	   (блок Модем), и на вкладке eSIM (после включения/добавления профиля).
	   Оформление подстраивается под тему: в bootstrap непрозрачная плашка со
	   скруглением как у кнопок, в proton2025 - полупрозрачная с блюром, как попапы
	   меню (тему различаем по data-theme на <html>: proton его ставит, bootstrap нет). */
	_busyCss: function() {
		if (document.getElementById('modem-busy-css')) { return; }
		var css =
			'#modem-busy-ov{position:absolute;top:0;left:0;right:0;bottom:0;z-index:20;' +
			'display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;' +
			'padding:1em;color:inherit;background:#fff;border-radius:6px;}' +
			'@media (prefers-color-scheme:dark){#modem-busy-ov{background:#1b1b1b;}}' +
			':root[data-theme] #modem-busy-ov{border-radius:inherit;' +
			'backdrop-filter:blur(20px);-webkit-backdrop-filter:blur(20px);}' +
			':root[data-theme="light"] #modem-busy-ov{background:rgba(255,255,255,0.92);}' +
			':root[data-theme="dark"] #modem-busy-ov{background:rgba(15,20,25,0.95);}' +
		/* прогрессбар плашки - в стиле основных метрик: серый заполненный
		   трек без обводки (а не пустота с рамкой темы) */
		'#modem-busy-bar{border:none;box-shadow:none;background:rgba(128,128,128,.18);}' +
		/* Спиннер плашки: .spinning темы прижимает крутилку жёстко влево
		   (position:absolute;left) с большим padding-left, и в центрированной
		   колонке текст со спиннером смотрится смещённым. В proton (data-theme)
		   переводим ::before-спиннер в поток вплотную к тексту - тогда пара
		   «крутилка+текст» центрируется как единое целое. bootstrap не трогаем. */
		':root[data-theme] #modem-busy-ov .spinning{padding-left:0!important;' +
		'display:inline-flex;align-items:center;gap:.55em;}' +
		':root[data-theme] #modem-busy-ov .spinning::before{position:static;' +
		'margin:0;top:auto;left:auto;}';
		document.head.appendChild(E('style', { 'id': 'modem-busy-css', 'type': 'text/css' }, css));
	},

	/* setBusy(selector, msg[, safetyMs[, progressSec]]) - накрыть блок;
	   clearBusy() - снять. progressSec включает ПРОГРЕССБАР в стиле полосок
	   метрик (.cbi-progressbar темы): он заполняется по ожидаемому времени
	   операции, упирается в 97% и дожидается настоящего завершения - на
	   clearBusy дорисовывается до 100% и плашка снимается. */
	setBusy: function(sel, msg, safetyMs, progressSec) {
		var block = document.querySelector(sel);
		if (!block) { return; }
		this._busyCss();
		var txt = msg || _('The modem is restarting…');
		var ov = document.getElementById('modem-busy-ov');
		/* Со спиннером - только БЕЗ прогрессбара: когда ход показывает полоса,
		   крутилка рядом лишняя (решение владельца). */
		var txtCls = progressSec ? '' : 'spinning';
		if (!ov) {
			block.style.position = 'relative';
			ov = E('div', { 'id': 'modem-busy-ov' }, [
				E('span', { 'id': 'modem-busy-txt', 'class': txtCls, 'style': 'font-weight:600;' }, txt)
			]);
			block.appendChild(ov);
		} else {
			ov.style.display = 'flex';
			var sp = ov.querySelector('#modem-busy-txt');
			if (sp) { sp.textContent = txt; sp.className = txtCls; }
		}
		var bar = document.getElementById('modem-busy-bar');
		if (this._busyBarTimer) { window.clearInterval(this._busyBarTimer); this._busyBarTimer = null; }
		if (progressSec) {
			if (!bar) {
				bar = E('div', { 'id': 'modem-busy-bar', 'class': 'cbi-progressbar',
					'title': '', 'style': 'width:70%;max-width:24em;margin-top:10px' }, E('div'));
				ov.appendChild(bar);
			}
			var t0 = Date.now(), inner = bar.firstElementChild;
			if (inner) {
				inner.style.width = '0%';
				this._busyBarTimer = window.setInterval(function() {
					/* elapsed_ms / (sec*1000) * 100 = elapsed_ms / (sec*10) */
					var pc = Math.min(97, Math.round((Date.now() - t0) / (progressSec * 10)));
					inner.style.width = pc + '%';
				}, 500);
			}
		} else if (bar) {
			bar.remove();
		}
		if (this._busyTimer) { window.clearTimeout(this._busyTimer); }
		// страховка: снять оверлей, даже если снимающий код не отработал
		var self = this;
		this._busyTimer = window.setTimeout(function() { self.clearBusy(); }, safetyMs || 120000);
	},

	clearBusy: function() {
		if (this._busyTimer) { window.clearTimeout(this._busyTimer); this._busyTimer = null; }
		if (this._busyBarTimer) { window.clearInterval(this._busyBarTimer); this._busyBarTimer = null; }
		var ov = document.getElementById('modem-busy-ov');
		if (!ov) { return; }
		var inner = ov.querySelector('#modem-busy-bar > div');
		if (inner) {
			/* завершение видно глазом: полоска добегает до конца и плашка уходит */
			inner.style.width = '100%';
			window.setTimeout(function() { ov.remove(); }, 350);
		} else {
			ov.remove();
		}
	},
});
