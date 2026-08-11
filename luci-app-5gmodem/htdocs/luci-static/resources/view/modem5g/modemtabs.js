'use strict';
'require baseclass';
'require fs';
'require uci';
'require poll';
'require ui';
'require view.modem5g.mutil as mutil';

/* ОБЩИЙ CSS ПРИЛОЖЕНИЯ - подключаем ОДИН РАЗ отсюда: этот модуль требуют все
   страницы приложения, поэтому отдельного загрузчика не нужно. Файл кэшируется
   браузером как обычная статика, в отличие от прежних <style>, которые
   пересоздавались на каждой загрузке страницы. */
(function() {
	/* Признак темы argon. Нужен ТОЧЕЧНО: у неё кнопки почти без рамки и со
	   светлой заливкой, из-за чего наши карточки «Приоритета интернета»
	   теряли и обводку активной, и подсветку во время теста скорости. В
	   остальных темах карточки выглядят правильно, поэтому правки вешаем
	   только под этим классом и ничего им не ломаем. */
	if (/\/argon\//.test(document.querySelector('link[href*="cascade.css"]') ? document.querySelector('link[href*="cascade.css"]').href : '')) {
		document.documentElement.classList.add('tg-theme-argon');
	}
	if (document.getElementById('tg-modem-css')) { return; }
	var l = document.createElement('link');
	l.id = 'tg-modem-css';
	l.rel = 'stylesheet';
	l.type = 'text/css';
	l.href = L.resource('view/modem5g/modem.css');
	document.head.appendChild(l);
})();

/*
	Общий компонент «шапки модема» для страниц luci-app-5gmodem:
	  - постоянный блок с ПОЛНЫМ именем активного модема (моноширинный);
	  - ряд вкладок выбора модема "Telit … | Compal …" (только если модемов >1).
	Данные: /usr/share/5gmodem/listmodems.sh + modemswitch.sh active.
	Клик по вкладке -> modemswitch.sh switch <usb-path> + перезагрузка страницы.

	Используется темой proton2025 (вставляет шапку НАД под-вкладками) через
	L.require('view.modem5g.modemtabs').renderBar().
*/

/* Бренд по VID (или по характерному имени продукта). USB-дескриптор часто даёт
   только платформу ("VOS_5G", "Android"), поэтому добавляем читаемый бренд. */
function vendor(m) {
	var pr = String((m && m.product) || '');
	if (/VOS_5G|RXMG1/i.test(pr)) { return 'Compal'; }
	var vid = String((m && m.vidpid) || '').split(':')[0].toLowerCase();
	/* 05c6 НАМЕРЕННО не в карте: это vid Qualcomm, общий для Compal RXM-G1,
	   Foxconn T99W175, Dell DW5930e и Thales MV31-W. Слепой 05c6->Compal врал
	   («Compal Generic Mobile Broadband Adapter» на T99W175). Настоящий Compal
	   опознаётся выше по строке продукта (VOS_5G/RXMG1) и по m.model, который
	   профиль 05c690d6 выставляет в «Compal RXM-G1»; остальным 05c6 бренд по
	   vid не присваиваем - показываем голую модель. */
	var map = {
		'1bc7': 'Telit', '2c7c': 'Quectel', '2cb7': 'Fibocom',
		'0e8d': 'Fibocom', '1e2d': 'Cinterion', '12d1': 'Huawei', '19d2': 'ZTE',
		'2dee': 'Foxconn', '0489': 'Foxconn', '413c': 'Dell',
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
		/* Заданное человеком имя оставляем КАК ЕСТЬ, даже если совпало: дописать
		   к нему технический путь значило бы спорить с его выбором. */
		if (modems[i] && modems[i].alias) { return l; }
		return (seen[l] > 1) ? (l + ' (' + (modems[i].path || (i + 1)) + ')') : l;
	});
}

function label(m, i) {
	/* СВОЁ ИМЯ ПОЛЬЗОВАТЕЛЯ СИЛЬНЕЕ ЛЮБОГО АВТОМАТИЧЕСКОГО. Его резолвит бэкенд
	   (listmodems: привязка к IMEI, откат на секцию пути), здесь только
	   показываем. Дедупликация путём такому имени не нужна - человек сам его
	   различил, иначе бы не задавал. */
	if (m && m.alias) { return String(m.alias).trim(); }
	var p = modelName(m);
	var v = vendor(m);
	var generic = (!p || /^android$/i.test(p) || /^usb/i.test(p) || /^simtech/i.test(p)
		|| (/modem/i.test(p) && p.length < 6));
	if (generic) { return v ? (v + ' ' + _('modem')) : _('Modem %d').format(i + 1); }
	if (v && p.toLowerCase().indexOf(v.toLowerCase()) < 0) { return v + ' ' + p; }
	return p;
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
		/* ПОДСВЕТКУ ВКЛАДКИ БЕРЁМ ИЗ КЛИКА (sessionStorage '5gm-tab'), а не
		   только из active_modem на роутере. Клик по вкладке пишет туда путь
		   ДО перезагрузки страницы, и мы перезагружаемся сразу, не дожидаясь,
		   пока resolve на роутере догонит active (это и давало «первый раз
		   залипает»: до 4 c ждали active==path только ради подсветки, тогда как
		   данные и так адресуются по sessionStorage через for=). Уважаем
		   sessionStorage ТОЛЬКО если путь реально есть в списке модемов - иначе
		   он мог протухнуть (модем вынули, слот сменили). */
		var _sel = '';
		try { _sel = window.sessionStorage.getItem('5gm-tab') || ''; } catch (e) {}
		if (_sel && modems.some(function(m) { return m.path === _sel; })) {
			active = _sel;
		}
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

/* --- Вкладка USSD ------------------------------------------------------------
 *
 * Прячем её у модемов, где USSD не работает В ПРИНЦИПЕ. Такой есть: Fibocom
 * FM350-GL - прошивка заявляет +CUSD, отвечает на него OK и не присылает
 * результат никогда, ни в одном режиме сети и ни в одной кодировке (перебрано
 * полной матрицей на живом модуле). Оставлять вкладку значит предлагать то,
 * чего нет: человек вводит код, ждёт и винит приложение.
 *
 * Вердикт - из таблицы проверенных (quirks.sh, через modemswitch.sh
 * ussdsupport), а не из пробы: он зависит только от vid:pid, поэтому ждать
 * нечего и в порт лезть не надо. Механика та же, что у eSIM: правило в <style>,
 * потому что меню LuCI статично и кэшируется, плюс память в localStorage по
 * АКТИВНОМУ модему - чтобы при переключении вкладок ничего не мелькало.
 *
 * Отличие от eSIM: по умолчанию НЕ прячем. Незнакомый модем и большинство
 * знакомых USSD умеют, так что цена ошибки в другую сторону выше - спрятать
 * рабочую вкладку хуже, чем на миг показать неработающую.
 */
var USSD_SEEN_BASE = '5gmodem.ussd.supported';
function ussdSeenKey() {
	var p = '';
	try { p = (uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''); } catch (e) {}
	return p ? (USSD_SEEN_BASE + '.' + p) : USSD_SEEN_BASE;
}

function ussdHideRule(on) {
	var st = document.getElementById('ussd-tab-hide');
	if (on) {
		if (!st) {
			st = E('style', { 'id': 'ussd-tab-hide', 'type': 'text/css' },
				'a[href*="5gmodem/sendussd"], li:has(> a[href*="5gmodem/sendussd"]) { display: none !important; }');
			document.head.appendChild(st);
		}
	} else if (st && st.parentNode) {
		st.parentNode.removeChild(st);
	}
}

/* Запомненное состояние применяем сразу, до опроса - но только когда знаем, о
   каком модеме речь: общий ключ наследовал бы вердикт от прежнего модема. */
(function() {
	try {
		var k = ussdSeenKey();
		if (k !== USSD_SEEN_BASE && localStorage.getItem(k) === '0') { ussdHideRule(true); }
	} catch (e) {}
})();

function applyUssdTabVisibility() {
	return L.resolveDefault(uci.load('5gmodem'))
		.then(function() {
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ussdsupport' ]), {});
		})
		.then(function(r) {
			var st = {};
			try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			/* Прячем ТОЛЬКО при явном «не работает». Пустой ответ (скрипт не
			   отработал, модем ещё не опознан) - это «не знаем», и вкладку
			   трогать нельзя. */
			var bad = (String(st.supported) === '0');
			ussdHideRule(bad);
			try { localStorage.setItem(ussdSeenKey(), bad ? '0' : '1'); } catch (e) {}
			mutil.lsTouch(ussdSeenKey());
		});
}

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
				/* было 8 ретраев по 2с = до 9 запусков esim.sh на КАЖДОЙ странице (ревью №15) */
				if (t < 2) { window.setTimeout(function() { applyEsimTabVisibility(t + 1); }, 2000); }
				return;
			}
			/* ВИДИМОСТЬ - ПО НАЛИЧИЮ eUICC, А НЕ ПО ВКЛЮЧЁННОМУ ПРОФИЛЮ.
			   Правильный признак - available: есть ли на модеме eUICC вообще. */
			var have = !!(st && st.available);
			esimHideRule(!have);
			try { localStorage.setItem(esimSeenKey(), have ? '1' : '0'); } catch (e) {}
			mutil.lsTouch(esimSeenKey());
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
				'src': it.op ? L.resource('icons/5gmodem/' + it.op + '.png')
				             : L.resource(it.usb ? 'icons/5gmodem/cusb.svg' : 'icons/5gmodem/cmodem.svg'),
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

/* ЗНАЧОК ОПЕРАТОРА ВМЕСТО ЗНАЧКА ЖЕЛЕЗА.
   На роутере с несколькими модемами по вкладкам было не понять, какая SIM где
   стоит: значок чипа/USB одинаков у всех. Имя оператора берём из listmodems
   (поле operator - кэш основного опроса, модем не трогается), и если оператор
   узнан - показываем его логотип. Не узнан (модем ещё не опрашивался, нет SIM)
   - остаётся прежний значок железа, как было. */
function operatorTabIcon(name) {
	var n = String(name || '').toLowerCase();
	if (!n) { return null; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2') { return 'op-t2'; }
	if (n.indexOf('t-mobile') >= 0 || n.indexOf('t-bank') >= 0 || n.indexOf('тинькофф') >= 0 || n.indexOf('т-банк') >= 0) { return 'op-tbank'; }
	if (n.indexOf('just esim') >= 0 || n.indexOf('justesim') >= 0 || n.indexOf('just-esim') >= 0) { return 'op-justesim'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	if (n.indexOf('motiv') >= 0 || n.indexOf('мотив') >= 0) { return 'op-motiv'; }
	if (n.indexOf('sber') >= 0 || n.indexOf('сбер') >= 0) { return 'op-sbermobile'; }
	if (n.indexOf('tattelecom') >= 0 || n.indexOf('таттелеком') >= 0 || n.indexOf('летай') >= 0) { return 'op-tattelecom'; }
	if (n.indexOf('gigsky') >= 0) { return 'op-gigsky'; }
	if (n.indexOf('eskimo') >= 0) { return 'op-eskimo'; }
	return null;
}
function tabIconSrc(m, opIcon) {
	if (opIcon) { return L.resource('icons/5gmodem/' + opIcon + '.png'); }
	return L.resource(isUsbStick(m) ? 'icons/5gmodem/cusb.svg' : 'icons/5gmodem/cmodem.svg');
}

function tabsCacheSave(modems, active) {
	try {
		var lbl = dedupLabels(modems);
		window.localStorage.setItem(TABS_CACHE, JSON.stringify(modems.map(function(m, i) {
			/* usb сохраняем, чтобы в заготовке (до ответа listmodems) значок был
			   сразу правильным и не подменялся на глазах. */
			return { label: lbl[i], active: (m.path === active), usb: isUsbStick(m),
			         op: operatorTabIcon(m.operator) };
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

/* Сигнатура состава модемов. Кроме пути включает ЖЕЛЕЗО (vid:pid + модель +
   оператор): модем меняют в ТОТ ЖЕ разъём, и по одному лишь пути такая замена
   неотличима - вкладка продолжала показывать имя прежнего модема (Telit вместо
   воткнутого Huawei) до ручной перезагрузки страницы. Оператор здесь же, чтобы
   логотип на вкладке менялся при смене SIM. */
function pathsSig(list) {
	return list.map(function(m) {
		return [ m.path, m.vidpid || '', m.model || '', m.operator || '' ].join('|');
	}).sort().join(',');
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
			/* Пока открыт редактор имени - НЕ перерисовываем: сигнатура меняется,
			   например, когда дорезолвился оператор, и поле ввода пропадало прямо
			   под руками. Сигнатуру не обновляем, чтобы перерисовка догнала нас
			   на следующем тике, когда редактор закроют. */
			if (bar.querySelector('.modemtab-input')) { return; }
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

/* Переименование вкладки на месте: подпись -> поле ввода с галочкой.
   Сохраняем через modemswitch.sh setalias (там же ставится IMEI-штамп), затем
   перечитываем страницу - имя показывается не только во вкладке, но и в
   карточках приоритета и в заголовке модема, а они строятся отдельно. */
/* ЗАКРЫТЬ РЕДАКТОР НА ВКЛАДКЕ (без сохранения). Вынесено из startRename, чтобы
   звать снаружи: открытие правки на СОСЕДНЕЙ вкладке должно закрывать эту.
   Иначе получалось два поля разом, и было непонятно, какое из них применится
   (поймано владельцем 07.08.2026). */
function endRename(tab) {
	if (!tab) { return; }
	/* Снимаем сторожа клика мимо вкладки - иначе он пережил бы редактор и
	   продолжал бы срабатывать на каждый клик по странице. */
	if (tab._renameOutside) {
		document.removeEventListener('mousedown', tab._renameOutside, true);
		tab._renameOutside = null;
	}
	tab.querySelectorAll('.modemtab-input, .modemtab-editctl').forEach(function(e) {
		e.parentNode && e.parentNode.removeChild(e);
	});
	var nameEl = tab.querySelector('.modemtab-name');
	var pen = tab.querySelector('.modemtab-edit');
	if (nameEl) { nameEl.style.display = ''; }
	if (pen) { pen.style.display = ''; }
}

function startRename(tab, m, current) {
	if (!tab || tab.querySelector('.modemtab-input')) { return; }
	/* Правка - ОДНА НА РЯД: закрываем всё, что открыто на других вкладках. */
	var bar = tab.parentNode;
	if (bar) {
		bar.querySelectorAll('.modemtab').forEach(function(other) {
			if (other !== tab) { endRename(other); }
		});
	}
	var nameEl = tab.querySelector('.modemtab-name');
	var pen = tab.querySelector('.modemtab-edit');
	if (!nameEl) { return; }
	var inp = E('input', {
		'type': 'text',
		'class': 'modemtab-input',
		/* Поле открывается С УЖЕ НАБРАННЫМ именем - тем, что человек видит на
		   вкладке: своё, если задано, иначе автоматическое. Placeholder
		   показывает, какое имя вернётся, если поле очистить. */
		'value': (m && m.alias) ? String(m.alias) : String(current || ''),
		'placeholder': current,
		'maxlength': 32,
		'click': function(ev) { ev.stopPropagation(); },
		'keydown': function(ev) {
			if (ev.key === 'Enter') { ev.preventDefault(); save(); }
			if (ev.key === 'Escape') { ev.preventDefault(); endRename(tab); }
		}
	});
	var ok = E('span', { 'class': 'modemtab-edit modemtab-editctl', 'title': _('Save'),
		'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); save(); } }, '✓');
	function save() {
		var v = String(inp.value || '').trim();
		inp.disabled = true;
		L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh',
			[ 'setalias', m.path, v ]), {}).then(function() {
			window.location.reload();
		});
	}
	nameEl.style.display = 'none';
	if (pen) { pen.style.display = 'none'; }
	tab.appendChild(inp);
	tab.appendChild(ok);
	/* ОТМЕНА БЕЗ КРЕСТИКА (решение владельца): не сохранил - значит не
	   применилось. Закрываем редактор по клику мимо вкладки и по Escape;
	   отдельная кнопка отмены только занимала место в узкой вкладке.
	   Слушаем в фазе перехвата и по mousedown - чтобы закрыться раньше, чем
	   клик доедет до соседней вкладки и переключит модем. */
	tab._renameOutside = function(ev) {
		if (!tab.contains(ev.target)) { endRename(tab); }
	};
	document.addEventListener('mousedown', tab._renameOutside, true);
	inp.focus();
	inp.select();
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
				var card = ev.currentTarget, row = card.parentNode;
				/* ТЕКУЩИЙ активный берём ИЗ DOM, а не из замыкания `active`:
				   при переключении БЕЗ перезагрузки (in-place) полоса вкладок не
				   перерисовывается, и `active` остался бы значением на момент
				   первого рендера - повторный клик по уже показанному модему
				   считался бы «тем же» и игнорировался (застревание после
				   первого переключения). */
				var curActive = active;
				if (row) {
					var _a = row.querySelector('.modemtab.active');
					if (_a) { curActive = _a.getAttribute('data-path'); }
				}
				if (path === curActive) { return; }
				/* Без попапа (решение владельца): переключение - это быстрые
				   uci-правки (AT-порт заново не пробуется при обычной смене
				   вкладки). Мгновенно перекидываем акцентную рамку на выбранную
				   вкладку - обратная связь есть сразу. Повторные клики глушим,
				   пока идёт switch; при in-place клики возвращаем в конце (при
				   reload их вернула бы сама перезагрузка). */
				if (row) {
					row.querySelectorAll('.modemtab.active').forEach(function(b) { b.classList.remove('active'); });
					row.querySelectorAll('.modemtab').forEach(function(b) { b.style.pointerEvents = 'none'; });
				}
				card.classList.add('active');
				/* ЛИЧНОСТЬ СТРАНИЦЫ = КЛИКНУТАЯ ВКЛАДКА. Путь кладём в
				   sessionStorage ДО switch/reload: новая страница возьмёт его
				   как свой и будет адресовать запросы ЕМУ, даже если switch
				   не доехал или active сменился позже. Именно вывод пути из
				   active (peek) делал обе вкладки близнецами (31.07.2026). */
				try { window.sessionStorage.setItem('5gm-tab', path); } catch (e) {}
				/* ПРЕДОХРАНИТЕЛЬ ОТ ЗАЛИПАНИЯ. Вкладки выше выключены до перезагрузки
				   страницы, а перезагрузку запускает конец цепочки switch->active.
				   Если switch завис на роутере (занятый rpcd, долгий resolve по
				   hotplug - его 30-секундный таймаут и т.п.), цепочка не доходила до
				   reload НИКОГДА: рамка уже на новой вкладке, панель мёртвая, назад
				   не переключиться (поймано владельцем). Таймер перегружает страницу
				   принудительно - подсветится честный active, панель оживёт. При
				   нормальном переключении reload случается раньше и таймер умирает
				   вместе со страницей. */
				/* ПЕРЕКЛЮЧЕНИЕ БЕЗ ПЕРЕЗАГРУЗКИ СТРАНИЦЫ.
				   Полный window.location.reload перезагружал ВЕСЬ LuCI SPA (меню,
				   ACL, ресурсы, форму) - отсюда и «тяжёлый» каскад (пропадает
				   приоритет, потом вкладки, потом всё рисуется заново), и
				   залипание на инициализации фреймворка. Если страница детали
				   зарегистрировала обработчик (__5gmInPlaceSwitch), меняем модем
				   ВНУТРИ неё: обновляется только карточка, всё остальное на месте.
				   Прочие страницы (SMS/USSD/настройки) обработчик не ставят - они
				   перечитываются прежней перезагрузкой (их load() зависит от
				   активного модема целиком). */
				/* In-place возможен ТОЛЬКО на странице детали: там есть карточка
				   (#modemname) и живой обработчик. window.__5gmInPlaceSwitch -
				   глобальный и переживает уход на SMS/USSD/настройки, поэтому
				   сверяем ещё и наличие карточки в DOM - иначе на другой странице
				   клик дёрнул бы мёртвый обработчик вместо перезагрузки. */
				var _inplace = window.__5gmInPlaceSwitch;
				if (typeof _inplace === 'function' && document.getElementById('modemname')) {
					/* ПЕРЕРИСОВЫВАЕМ КАРТОЧКУ СРАЗУ, НЕ ДОЖИДАЯСЬ backend switch.
					   switch на роутере бывает медленным (занятый rpcd, переопрос
					   AT-порта - те самые «иногда 5-7 c»), а карточке его ждать
					   незачем: данные адресуются for=<путь>, warm-снимок читается
					   по этому модему независимо от active. Раньше _inplace висел
					   в .then(switch) - отсюда залипание без обратной связи. */
					try { _inplace(path); }
					catch (e) { pageLeaveThenReload(); return; }
					/* Клики по вкладкам возвращаем сразу (reload'а, который бы
					   пересоздал полосу, нет). */
					if (row) { row.querySelectorAll('.modemtab').forEach(function(b) { b.style.pointerEvents = ''; }); }
					/* switch на роутере - В ФОНЕ: делает выбор постоянным
					   (переживёт F5) и переустанавливает at_port/network под новый
					   модем. UI его не ждёт; когда он доедет, свежие данные придут
					   отложенными тиками (см. switchModemInPlace). */
					fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]);
				} else {
					window.setTimeout(function() { pageLeaveThenReload(); }, 12000);
					L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'switch', path ]), {})
						.then(function() { pageLeaveThenReload(); });
				}
			}
		}, [
			/* Иконка перед именем: у модема с собственной сетевой картой (USB-
			   свисток вроде Huawei E3372, который сам держит IP-стек) - значок
			   USB, у встроенных модулей - чип. Признак берём из net[]: он есть
			   только у таких свистков, у обычных модемов пуст. */
			E('img', {
				'class': 'modemtab-ic',
				'src': tabIconSrc(m, operatorTabIcon(m.operator)),
				'width': 16, 'height': 16, 'alt': '',
				'title': m.operator || ''
			}),
			E('span', { 'class': 'modemtab-name' }, labels[i]),
			/* КАРАНДАШ ПО НАВЕДЕНИЮ - переименование вкладки.
			   Своё имя нужно, когда модемы одинаковые: два EP06 с одним
			   оператором различить в ряду нечем. По клику подпись превращается в
			   поле с галочкой; пустое значение снимает имя и возвращает
			   автоматическое. Клик по карандашу НЕ должен переключать модем -
			   гасим всплытие. */
			E('span', {
				'class': 'modemtab-edit',
				'title': _('Rename'),
				'click': function(ev) {
					ev.preventDefault();
					ev.stopPropagation();
					startRename(ev.currentTarget.parentNode, m, labels[i]);
				}
			}, '✎')
		]);
	});
	return E('div', { 'class': 'modemtabs-bar' }, tabs);
}

/* УХОД СТРАНИЦЫ ПЕРЕД ПЕРЕЗАГРУЗКОЙ.
   Гасим содержимое ТОЛЬКО в момент, когда перезагрузка уже вызывается, и
   ненадолго. Первая редакция вешала класс сразу по клику - а перезагрузка
   случается лишь после подтверждения switch (до 4 с, при зависшем rpcd - до
   12 с). Всё это время страница стояла ПУСТОЙ, и выглядело это как поломка
   («переключил - а там пусто, пока не перезагрузишь», поймано владельцем).
   Страховка на случай, если перезагрузка не состоится вовсе (bfcache,
   отменённая навигация): класс снимается по таймеру, содержимое возвращается. */
var _pageLeaving = false;
function pageLeaveThenReload() {
	/* Двойной вызов возможен: сработали и подтверждение switch, и 12-секундный
	   предохранитель. Перезагружаемся один раз. */
	if (_pageLeaving) { return; }
	_pageLeaving = true;
	var el = document.getElementById('view') || document.querySelector('.cbi-map, #maincontent');
	if (el) {
		el.classList.add('tgpage-leave');
		window.setTimeout(function() { el.classList.remove('tgpage-leave'); }, 1200);
	}
	window.setTimeout(function() { window.location.reload(); }, el ? 160 : 0);
}

/* ПРОЯВЛЕНИЕ СТРАНИЦЫ ПРИ ВХОДЕ. Зовётся из renderBar - он есть на каждой
   странице приложения, поэтому отдельного места для инициализации не нужно.
   Класс снимаем после анимации: иначе он мешал бы будущим transition на том же
   контейнере. */
function pageFadeIn() {
	var el = document.getElementById('view') || document.querySelector('.cbi-map, #maincontent');
	if (!el || el.classList.contains('tgpage-in')) { return; }
	el.classList.add('tgpage-in');
	window.setTimeout(function() { el.classList.remove('tgpage-in'); }, 400);
}

return baseclass.extend({
	/* Шапка: только ряд вкладок выбора модема (если модемов > 1). Имя активного
	   модема показывается заголовком блока «Общая информация» в самой вьюхе.
	   Возвращает Promise<DOM|null>. null - если модем один/нет. */
	renderBar: function() {
		pageFadeIn();
		return loadModems().then(function(st) {
			/* Раньше при одном модеме возвращали null - полосы не было вовсе.
			   Теперь рисуем всегда: одна кнопка показывает, о каком модеме
			   страница, и, главное, высота полосы известна заранее, поэтому
			   её место резервируется заготовкой ещё до прихода данных. */
			return E('div', { 'class': 'modembar' }, [ tabsBar(st.modems, st.active) ]);
		});
	},

	/* Только ряд вкладок (для случаев без темы). null, если модемов <= 1. */
	render: function() {
		return loadModems().then(function(st) {
			if (st.modems.length <= 1) { return null; }
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
	refreshUssdTab: function() { applyUssdTabVisibility(); },

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
		// То же и для USSD: есть модемы, у которых он не работает в принципе.
		applyUssdTabVisibility();

		var bar = document.querySelector('.modembar');
		/* полоса уже наполнена данными - второй раз не работаем */
		if (bar && !bar.classList.contains('modembar-loading')) { return Promise.resolve(); }


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
	/* Стили плашки теперь в modem.css - метод оставлен пустым, чтобы не
	   править два десятка мест вызова. */
	_busyCss: function() {},

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
