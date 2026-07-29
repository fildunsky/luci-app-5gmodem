'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem.modemtabs as modemtabs';
'require rpc';
'require poll';
'require sms-tool-js.smssettings as smssettings';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
*/

var callForwardSMS = rpc.declare({
    object: 'sms_forward',
    method: 'forward',
    params: ['subject', 'message']
});

function msg_bar(v, m) {
var pg = document.querySelector('#msg')
if (!pg || !pg.firstElementChild) { return; }
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);

pg.firstElementChild.style.width = pc + '%';
/* Текст внутри полоски рисует тема из атрибута title. Показываем счёт
   сообщений, а не проценты: «Память: 2/15». */
pg.setAttribute('title', _('Memory: %s/%s').format(v, m));
}

/* Разбор строки статуса sms_tool: "Storage type: ME, used: N, total: M".
   Раньше ВЕЗДЕ стоял позиционный substring(17, indexOf("total")) - он ломается
   на любом отклонении формата (иная длина префикса, другой инструмент), и
   тогда u оказывался пустым, а СПИСОК МОЛЧА НЕ ПЕРЕРИСОВЫВАЛСЯ (рендер был
   огорожен if (u)). Регулярный разбор терпим к формату; чисел нет - null. */
function sms_parse_status(res) {
	var u = String(res || '').match(/used:\s*(\d+)/i);
	var t = String(res || '').match(/total:\s*(\d+)/i);
	return { u: u ? u[1] : null, t: t ? t[1] : null };
}

/* ВЫДЕЛЕНИЕ СООБЩЕНИЙ.
   Галочек в списке больше нет: сообщение выделяется кликом по карточке, а
   состояние живёт в классе .selected. Чекбоксы не сохраняем даже скрытыми -
   <input> внутри <button> невалиден. Индексы сообщения (у склеенного
   многочастного - все части через дефис) лежат в data-index; удаление берёт
   их оттуда. */
/* Плейсхолдер вместо списка. state: 'loading' - идёт чтение, 'empty' - прочитали,
   сообщений нет. */
/* ЕДИНАЯ МОДЕЛЬ СОСТОЯНИЯ СПИСКА.
   Раньше состоянием списка распоряжались ЧЕТЫРЕ независимых места: плейсхолдер,
   showLoading, hideLoading и два блока в хвосте doRefresh - каждое со своим
   условием. Они спорили друг с другом, и одно и то же состояние («список уже
   есть», «идёт чтение», «пусто») определялось по-разному. Отсюда и класс багов
   «сообщения показались и исчезли»: очистка успевала произойти до того, как
   выяснялось, есть ли чем её заполнить.
   Теперь #smsList трогает ТОЛЬКО smsSetState. Состояния:
     loading - чтение идёт, показанного ещё нет;
     list    - есть сообщения (карточки строит вызывающий);
     empty   - прочитали, сообщений нет;
     error   - прочитать не удалось. Показанное НЕ трогаем: устаревший список
               честнее пустого экрана, а следующий тик перечитает. */
function smsSetState(state, opts) {
	var list = document.getElementById('smsList');
	if (!list) { return null; }
	opts = opts || {};
	var hasCards = !!list.querySelector('.sms-card');

	if (state === 'error') {
		smsNote(hasCards ? (opts.note || _('Could not read messages')) : null);
		if (!hasCards) { smsPlaceholder('empty'); }
		return null;
	}
	if (state === 'loading') {
		/* Список уже на экране - не мигаем им ради индикатора, а вешаем
		   пометку сверху (как на вкладке eSIM). */
		if (hasCards) { smsNote(_('Loading messages…')); return null; }
		smsPlaceholder('loading');
		return null;
	}
	smsNote(null);
	if (state === 'empty') { smsPlaceholder('empty'); return null; }
	/* list: отдаём очищенный контейнер - карточки в него добавит вызывающий.
	   Очистка происходит ЗДЕСЬ и только когда данные уже разобраны.
	   ВЫДЕЛЕНИЕ ЗАПОМИНАЕМ: список пересоздаётся на каждом тике опроса, и
	   отмеченные сообщения теряли выделение через несколько секунд - прямо
	   под руками у пользователя, который собирался их удалить. */
	smsKeepSelection(list);
	list.innerHTML = '';
	return list;
}

/* Индексы выделенных сообщений - между перерисовками списка. */
var _smsSel = [];
function smsKeepSelection(list) {
	_smsSel = [];
	(list || document).querySelectorAll('.sms-card.selected').forEach(function(c) {
		var i = c.getAttribute('data-index');
		if (i) { _smsSel.push(i); }
	});
}
/* Вернуть выделение после перерисовки. Вызывать ПОСЛЕ добавления карточек. */
function smsRestoreSelection() {
	if (!_smsSel.length) { return; }
	var alive = [];
	_smsSel.forEach(function(i) {
		var c = document.querySelector('.sms-card[data-index="' + i + '"]');
		if (c) { sms_set_selected(c, true); alive.push(i); }
	});
	/* Сообщения, которых больше нет (удалили, модем перенумеровал), из памяти
	   выбрасываем - иначе они «оживали» бы на чужих карточках с тем же
	   индексом. */
	_smsSel = alive;
	sms_update_selcount();
}

/* Пометка над списком: живое чтение или сбой. null - снять. */
function smsNote(text) {
	var old = document.getElementById('sms-updating');
	if (old && old.parentNode) { old.parentNode.removeChild(old); }
	if (!text) { return; }
	var list = document.getElementById('smsList');
	if (!list || !list.parentNode) { return; }
	list.parentNode.insertBefore(E('em', {
		'id': 'sms-updating', 'class': 'spinning',
		'style': 'font-size:92%;opacity:.7;margin:2px 0 6px;display:inline-block'
	}, text), list);
}

function smsPlaceholder(state) {
	var list = document.getElementById('smsList');
	if (!list) { return; }
	list.innerHTML = '';
	/* data-state ОБЯЗАТЕЛЕН: у обоих состояний один класс sms-empty, и проверка
	   «плейсхолдер уже есть» видела собственный спиннер - «читаю сообщения…»
	   никогда не сменялось на «нет сообщений», а пользователь не мог отличить
	   пустую память от зависшего чтения. */
	list.appendChild(E('div', { 'class': 'sms-empty', 'id': 'smsEmpty',
		'data-state': state === 'loading' ? 'loading' : 'empty' }, [
		state === 'loading'
			? E('span', { 'class': 'spinning' }, _('Loading messages…'))
			: E('span', {}, _('No messages'))
	]));
}

/* Прежнее имя - используется в нескольких местах; оставлено обёрткой. */
function sms_placeholder(state) { return smsPlaceholder(state); }

function sms_selected_cards() {
	return document.querySelectorAll('.sms-card.selected');
}

function sms_set_selected(card, on) {
	if (on) { card.classList.add('selected'); } else { card.classList.remove('selected'); }
	card.setAttribute('aria-pressed', on ? 'true' : 'false');
}

/* Счётчик выделенных + видимость действий над выделением. «Переслать» и
   «Удалить» без выделенных сообщений не делают ничего осмысленного (раньше
   они лишь ругались попапом «выберите сообщения»), поэтому показываем их
   только когда есть что пересылать и удалять. «Обновить» видна всегда. */
function sms_update_selcount() {
	var n = sms_selected_cards().length;

	var el = document.getElementById('sms-selcount');
	if (el) { el.textContent = n ? _('selected: %d').format(n) : ''; }

	['forward', 'execute'].forEach(function(id) {
		var b = document.getElementById(id);
		if (b) { b.style.display = n ? '' : 'none'; }
	});
}

/* Карточка одного сообщения: сверху слева жирным отправитель, справа мелко
   дата и время, ниже текст. Отправитель и текст кладём ТЕКСТОМ (E() ставит
   textContent), а не innerHTML: содержимое SMS приходит от оператора и может
   содержать разметку. */
/* --- Кэш последнего ПОКАЗАННОГО списка SMS (после склейки частей) ----------
   Для мгновенного warm-render при возврате на страницу: чтение с модема
   занимает секунды, а последний список можно показать сразу - карточки
   строятся тем же sms_make_card и полностью интерактивны. Ключ включает
   хранилище и порт: у разных модемов/симок свои сообщения. Свежее чтение
   перерисовывает список и перезаписывает кэш; после удалений кэш обновится
   первым же перечитыванием. */
function sms_cache_key() {
	var s = uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage') || 'ME';
	var p = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport') || '';
	return 'sms-last:' + s + ':' + p;
}
function sms_cache_save(list, u, t) {
	try {
		window.localStorage.setItem(sms_cache_key(),
			JSON.stringify({ list: list, u: u, t: t }));
	} catch (e) {}
}
function sms_cache_load() {
	try { return JSON.parse(window.localStorage.getItem(sms_cache_key()) || 'null'); }
	catch (e) { return null; }
}

/* Время SMS: sms_tool печатает его в UTC и ИГНОРИРУЕТ $TZ (проверено на
   живом порту: и с TZ=MSK-3, и с TZ=UTC0 вывод одинаковый, +0000) - у
   пользователя SMS показывалось на 3 часа назад. Переводим в местное время
   ЗДЕСЬ: браузер знает пояс пользователя, а он совпадает с поясом роутера
   или даже точнее (пользователь мог уехать). Формат сохраняем. */
function sms_localtime(ts) {
	var m = String(ts || '').match(/^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})/);
	if (!m) { return ts; }
	var d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]));
	if (isNaN(d.getTime())) { return ts; }
	var p = function(n) { return (n < 10 ? '0' : '') + n; };
	return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) +
		' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

/* Ссылки в тексте SMS -> живые <a>. Карточка - <button> (клик выделяет её),
   поэтому у ссылки свой обработчик: гасим всплытие (не выделять карточку) и
   открываем сами (браузеры не обязаны обрабатывать <a> внутри <button>).

   Ловим ТРИ вида: полный URL (http/https), www.* и ГОЛЫЙ ДОМЕН без схемы
   (t.tb.ru/appand, unblock.t2.ru) - операторы шлют именно такие. Домен = хотя
   бы одна точка и буквенный TLD (2-24 буквы), поэтому «т.д.», «1.5» и IP
   (192.168.1.1 - последняя часть цифровая) НЕ считаются ссылкой. Домены пишем
   только латиницей: [a-z] не заденет кириллицу («Т-Банка.»).
   Хвостовую пунктуацию после ссылки не захватываем. */
var SMS_URL_RE = /(https?:\/\/[^\s]+|(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,24}(?:\/[^\s]*)?)/gi;
function sms_linkify(text) {
	var out = [], last = 0, m;
	SMS_URL_RE.lastIndex = 0;
	while ((m = SMS_URL_RE.exec(text)) !== null) {
		var url = m[0].replace(/[).,;:!?\]]+$/, '');
		/* Голый домен без схемы: пропускаем, если TLD не выглядит доменным
		   (одна буква) или это часть e-mail (перед совпадением стоит '@'). */
		if (!/^https?:/i.test(url)) {
			if (m.index > 0 && text.charAt(m.index - 1) === '@') { continue; }
		}
		if (m.index > last) { out.push(document.createTextNode(text.slice(last, m.index))); }
		var href = /^https?:/i.test(url) ? url : ('http://' + url);
		out.push(E('a', {
			'href': href, 'target': '_blank', 'rel': 'noopener',
			'class': 'sms-link',
			'click': function(ev) {
				ev.stopPropagation();
				ev.preventDefault();
				window.open(ev.currentTarget.href, '_blank', 'noopener');
			}
		}, url));
		last = m.index + url.length;
	}
	if (last < text.length) { out.push(document.createTextNode(text.slice(last))); }
	return out;
}

/* ===== НОВЫЕ (НЕПРОЧИТАННЫЕ) СООБЩЕНИЯ =====
   Статуса прочтения у модема не спросишь: sms_tool -j его не отдаёт, а
   AT+CMGL="ALL" помечает всё прочитанным при первом же чтении. Поэтому новизну
   считаем сами: роутер помнит ключи виденных сообщений (smsbridge.sh seen),
   страница сравнивает с ними текущий список. Память лежит на роутере, а не в
   localStorage - иначе телефон не знал бы, что прочитано с ноутбука, и всё
   пропадало бы с чисткой кеша. */
var smsSeen = null;      /* Set ключей; null - ещё не загружено */
var smsSeenFirst = false; /* про эту SIM ещё ничего не знаем */

/* КЛЮЧ - ОТПРАВИТЕЛЬ И ВРЕМЯ, и только они.
   Порядкового номера в нём нет: модем переиспользует номера удалённых
   сообщений, и новое письмо молча унаследовало бы чужую отметку «прочитано».
   Номера склейки и части - тоже нет, хотя они есть в данных: список
   показывается в двух режимах (части склеены в одно сообщение или показаны
   порознь, настройка страницы), и ключ с частью менялся бы при переключении -
   весь ящик разом вспыхнул бы как новый. Заодно это даёт нужное поведение:
   части одного сообщения делят время и отправителя, то есть прочитываются
   вместе.
   Цена: два РАЗНЫХ письма от одного отправителя в одну и ту же минуту считаются
   одним, и второе не подсветится. Времени точнее минуты модем не сообщает. */
function sms_msg_key(item) {
	return [
		String(item.sender || ''),
		String(item.timestamp || '')
	].join('|').replace(/[\x00-\x1f]/g, ' ');
}

function sms_seen_load() {
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'seen' ]), '')
		.then(function(res) {
			smsSeen = new Set();
			smsSeenFirst = false;
			try {
				var d = JSON.parse(res || '{}');
				smsSeenFirst = (d.first == 1);
				(d.keys || []).forEach(function(k) { smsSeen.add(k); });
			} catch (e) {}
		});
}

/* Отметить прочитанными. Список ключей уходит на роутер, метки снимаются сразу -
   ждать ответа незачем, промах стоит одной лишней подсветки. */
function sms_seen_add(keys) {
	if (!keys || !keys.length) { return Promise.resolve(); }
	if (smsSeen) { keys.forEach(function(k) { smsSeen.add(k); }); }
	return L.resolveDefault(
		fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'seen-add' ].concat(keys)), '');
}

/* ПЕРВЫЙ ЗАПУСК НЕ ПОДСВЕЧИВАЕМ. Сообщения могли прийти когда угодно, и залить
   весь список метками «новое» было бы враньём: просто запоминаем то, что есть. */
function sms_seen_sync(list) {
	if (!smsSeen || !smsSeenFirst || !list || !list.length) { return; }
	smsSeenFirst = false;
	sms_seen_add(list.map(sms_msg_key));
}

/* Счётчик новых и кнопка «Прочитано» - показываем, только когда есть что
   отмечать: пустая кнопка в ряду действий только мешает. */
function sms_update_newcount() {
	var n = document.querySelectorAll('.sms-card.sms-new').length;
	var badge = document.getElementById('sms-newcount');
	var btn = document.getElementById('sms-markread');
	if (badge) {
		badge.textContent = n ? (_('New') + ': ' + n) : '';
		badge.style.display = n ? '' : 'none';
	}
	if (btn) { btn.style.display = n ? '' : 'none'; }
}

function sms_mark_all_read() {
	var keys = [];
	document.querySelectorAll('.sms-card.sms-new').forEach(function(c) {
		if (c.dataset.key) { keys.push(c.dataset.key); }
		c.classList.remove('sms-new');
	});
	sms_update_newcount();
	return sms_seen_add(keys);
}

function sms_make_card(item, iconSrc, hide) {
	var sender = String(item.sender || '');
	if (hide && sender.includes(hide)) { sender = sender.slice(0, -5) + '#####'; }
	var text = String(item.content || '').replace(/\s+/g, ' ').trim();
	var when = sms_localtime(item.timestamp);

	/* Новизну решаем ЗДЕСЬ, при постройке карточки: список перерисовывается
	   целиком на каждом обновлении, и класс иначе слетал бы вместе с ней. */
	var key = sms_msg_key(item);
	var isNew = !!(smsSeen && !smsSeenFirst && !smsSeen.has(key));

	var card = E('button', {
		'type': 'button',
		/* btn cbi-button - те же классы темы, что у кнопок netpri: весь базовый
		   вид карточки приходит отсюда, .sms-card только раскладывает содержимое. */
		'class': 'btn cbi-button sms-card' + (isNew ? ' sms-new' : ''),
		'data-key': key,
		'aria-pressed': 'false',
		/* Удаление берёт индексы отсюда, пересылка - отправителя, время и текст.
		   Раньше и то и другое читалось из ячеек строки (cells[1..3]); с уходом
		   от таблицы такой способ отвалился бы молча - пустым письмом. */
		'data-index': String(item.index),
		'data-sender': sender,
		'data-timestamp': when,
		'data-message': text
	}, [
		E('div', { 'class': 'sms-card-head' }, [
			E('span', { 'class': 'sms-card-from' }, [
				E('span', { 'class': 'sms-row-icon' }, [
					E('img', { 'src': iconSrc })
				]),
				E('span', {}, sender)
			]),
			E('span', { 'class': 'sms-card-time' }, when)
		]),
		E('div', { 'class': 'sms-card-text' }, sms_linkify(text))
	]);

	card.addEventListener('click', function() {
		/* Открыл - значит прочитал: снимаем метку с этого сообщения. Ждать
		   отдельного нажатия «Прочитано» ради одного письма незачем. */
		if (card.classList.contains('sms-new')) {
			card.classList.remove('sms-new');
			sms_seen_add([ key ]);
			sms_update_newcount();
		}
		sms_set_selected(card, !card.classList.contains('selected'));
		sms_update_selcount();
	});
	return card;
}

/* Запись фоновых значений в sms_tool_js (счётчик сообщений, выбранный порт).
   Отсюда шла ошибка в консоли «RPC call to uci/apply failed with ubus code 5:
   Данные не получены» (5 = NO_DATA). Две причины, обе воспроизводятся:
   1) uci.save() АСИНХРОННА, а вызванный сразу за ней uci.apply() уходил раньше,
      чем изменения попадали в стейджинг - применять было нечего;
   2) apply без изменений тоже отвечает NO_DATA, а счётчик сообщений чаще всего
      совпадает с уже записанным (список не менялся).
   Поэтому пишем только реально изменившиеся ключи и применяем, лишь если
   что-то записали. */
function sms_persist(values) {
	var args = [ 'smsopt' ];
	for (var k in values) {
		var cur = uci.get('sms_tool_js', '@sms_tool_js[0]', k);
		var val = (values[k] == null) ? '' : String(values[k]);
		if (String(cur == null ? '' : cur) === val) { continue; }
		/* держим в кэше страницы то же значение, что записали на роутере -
		   иначе следующий тик снова сочтёт его изменившимся */
		uci.set('sms_tool_js', '@sms_tool_js[0]', k, val);
		args.push(k + '=' + val);
	}
	if (args.length < 2) { return Promise.resolve(); }
	return fs.exec('/usr/share/5gmodem/modemswitch.sh', args);
}

function popTimeout(a, message, timeout, severity) {
    ui.addTimeLimitedNotification(a, message, timeout, severity);
}


function format_with_modem_index(value) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			// old format
			return value;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			// old format
			return value;
		}
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		
		var modemIndex = -1;
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				modemIndex = i + 1;
				break;
			}
		}
		
		if (modemIndex === -1) {
			// old format
			return value;
		}
		
		return 'dfm' + modemIndex + '_' + value;
		
	}).catch(function() {
		// old format
		return value;
	});
}

function update_sms_count_for_modem(newValue) {
	return uci.load('defmodems').then(function() {
		var defmodemSections = uci.sections('defmodems', 'defmodems');
		
		if (!defmodemSections || defmodemSections.length === 0) {
			// old format
			return newValue;
		}
		
		var serialModems = defmodemSections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) {
			// old format
			return newValue;
		}
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		var currentModemIndex = -1;
		
		for (var i = 0; i < serialModems.length; i++) {
			if (serialModems[i].comm_port === currentPort) {
				currentModemIndex = i + 1;
				break;
			}
		}
		
		if (currentModemIndex === -1) {
			// old format
			return newValue;
		}
		
		var existingSmsCount = uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_count') || '';
		var parts = existingSmsCount.split(' ').filter(function(p) { return p.trim() !== ''; });
		
		var updated = {};
		parts.forEach(function(part) {
			var match = part.match(/^dfm(\d+)_(\d+)$/);
			if (match) {
				var modemIdx = parseInt(match[1]);
				if (modemIdx > 0 && modemIdx <= serialModems.length) {
					updated[modemIdx] = match[2];
				}
			}
		});
		
		updated[currentModemIndex] = newValue;
		
		var result = [];
		for (var i = 1; i <= serialModems.length; i++) {
			var count = updated[i] || '0';
			result.push('dfm' + i + '_' + count);
		}
		
		return result.join(' ');
		
	}).catch(function() {
		// old format
		return newValue;
	});
}

function save_count() {
	uci.load('sms_tool_js').then(function() {

		var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
		var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));

			/* Счётчик и список берём через smsbridge.sh: у модемов без AT-портов
			   (HiLink) они лежат в самом модеме и достаются его API. Мост решает
			   это сам, формат на выходе прежний - разбор ниже не менялся. */
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
					.then(function(res) {
							if (res) {
								var _st = sms_parse_status(res);
								if (_st.u == null) { return; }
								update_sms_count_for_modem(_st.u).then(function(updatedValue) {
									sms_persist({ 'sms_count': updatedValue });
								});
							}
			});
	});
}


/* Binary used for SMS operations: on modems managed by ModemManager
   (MBIM/QMI, e.g. Compal RXM-G1) sms_tool on the AT port never sees
   incoming messages and cannot send - use the mmcli wrapper instead.
   The sms_via_mm option is set by the hotplug script (by VID:PID) or
   by the user. */
/* Активный модем - из тех, что управляются своим веб-интерфейсом? Тогда
   AT-порты ему не нужны, и требовать их нельзя. */
function isHilinkModem() {
	var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
	if (!p) { return false; }
	var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	return uci.get('5gmodem', sec, 'kind') === 'hilink';
}

/* Выбор бинаря переехал в smsbridge.sh - см. пояснение там. */

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('sms_tool_js'),
			/* 5gmodem нужен, чтобы понять класс активного модема: у HiLink
			   AT-портов нет, и требовать их настройки нельзя. */
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('defmodems')),
			/* Список прочитанного тянем ВМЕСТЕ с настройками, до первой
			   отрисовки: карточка решает свою новизну в момент постройки, и
			   опоздавший список означал бы ящик без единой метки. */
			sms_seen_load()
		]);
	},

	handleModemChange: function(ev) {
		var sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		var serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		var currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		var direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		var newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		var newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			sms_persist({ 'readport': newModem.comm_port }).then(function() {
				var modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					var label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	handleSWarea: function(ev) {
		var self = this;
		var val = document.querySelector('input[name="filter_area"]:checked').value;
		var stg = (val === 'sim') ? 'SM' : 'ME';
		/* Пишем сразу в конфиг (см. sms_persist): через uci.save правка ложилась
		   в стейджинг LuCI, и наверху появлялись «непринятые изменения». */
		return sms_persist({ 'storage': stg }).then(function() {
			if (typeof self._doRefresh == 'function') { self._doRefresh(false, true); }
		});
	},

    handleForward: function(ev) {
	    var checked = sms_selected_cards();
	    
	    if (checked.length === 0) {
		    ui.addNotification(null, E('p', _('Please select the message(s) to be forwarded')), 'info');
		    return;
	    }
	    
	    var self = this;
	    
	    uci.load('sms_tool_js').then(function() {
		    var fwdEnabled = uci.get('sms_tool_js', '@sms_tool_js[0]', 'forward_sms_enabled');
		    
		    if (fwdEnabled !== '1') {
			    ui.addNotification(null, E('p', _('SMS forwarding function is not enabled')), 'info');
			    return;
		    }
		    
		    var emailSubject = '';
		    var emailBody = '';

		    if (checked.length === 1) {
			    var d = checked[0].dataset;

			    var sender = (d.sender || '').trim();
			    var timestamp = (d.timestamp || '').trim();
			    var message = (d.message || '').trim();

			    emailSubject = 'SMS ' + timestamp + ' - ' + sender;
			    emailBody = message;
			    
			    self.showEmailModal(emailSubject, emailBody);
		    } 
		    else {
			    uci.load('system').then(function() {
				    var hostname = uci.get('system', '@system[0]', 'hostname') || _('My Router');
				    
				    var messages = [];
				    checked.forEach(function(card) {
					    var d = card.dataset;

					    var timestamp = (d.timestamp || '').trim();
					    var sender = (d.sender || '').trim();
					    var message = (d.message || '').trim();

					    messages.push(timestamp + ' - ' + sender + '\n' + message);
				    });
				    
				    var emailBody = messages.join('\n\n');
				    
				    self.showEmailModal(hostname, emailBody);
			    });
		    }
	    });
    },

    showEmailModal: function(defaultSubject, defaultBody) {
	    var self = this;
	    
	    ui.showModal(_('Forward SMS to E-mail'), [
		    E('p', _('Subject:')),
		    E('input', {
			    'type': 'text',
			    'id': 'email-subject',
			    'class': 'cbi-input-text',
			    'style': 'width: 100% !important; margin-bottom: 15px;',
			    'value': defaultSubject
		    }),
		    E('p', _('Message text:')),
		    E('textarea', {
			    'id': 'email-body',
			    'class': 'cbi-input-textarea',
			    'style': 'width: 100% !important; height: 30vh; min-height: 250px;',
			    'wrap': 'off',
			    'spellcheck': 'false'
		    }, defaultBody),
		    E('div', { 'class': 'right' }, [
			    E('button', {
				    'class': 'btn',
				    'click': ui.hideModal
			    }, _('Cancel')), ' ',
			    E('button', {
				    'class': 'cbi-button cbi-button-action important',
				    'click': ui.createHandlerFn(this, 'sendEmailFromModal')
			    }, _('Send'))
		    ])
	    ], 'cbi-modal');
    },

    sendEmailFromModal: function() {
	    var subject = document.getElementById('email-subject').value;
	    var body = document.getElementById('email-body').value;
	    
	    if (!subject || !body) {
		    ui.addNotification(null, E('p', _('Subject and body cannot be empty')), 'error');
		    return;
	    }
	    
	    var self = this;
	    
	    ui.hideModal();
	    
	    var contentArea = document.getElementById('forward-status');
	    contentArea.style.display = 'block';
	    contentArea.innerHTML = '';
	    contentArea.appendChild(E('div', {'class': 'alert alert-info'}, 
		    E('span', {'class': 'spinning'}, _('Sending e-mail...'))
	    ));
	    
	    callForwardSMS(subject, body).then(function(response) {
		    contentArea.innerHTML = '';
		    if (response.success) {
			    popTimeout(null, E('p', _('Message forwarded successfully')), 5000, 'info');
			    setTimeout(function() {
				    if (contentArea) {
					    contentArea.innerHTML = '';
					    contentArea.style.display = 'none';
				    }
			    }, 5000);
		    } else {
			    contentArea.innerHTML = '';
			    contentArea.style.display = 'none';
			    ui.addNotification(null, E('p', _('Failed to forward message: %s').format(response.error || 'Unknown error')), 'error');
		    }
	    }).catch(function(err) {
		    contentArea.innerHTML = '';
		    contentArea.style.display = 'none';
		    ui.addNotification(null, E('p', _('Error: %s').format(err.message)), 'error');
	    });
    },

	handleDelete: function(ev) {
		if (sms_selected_cards().length == 0){
		ui.addNotification(null, E('p', _('Please select the message(s) to be deleted')), 'info');   
		}
		else {
			if (sms_selected_cards().length === document.querySelectorAll('.sms-card').length) {
					/* Без confirm (решение владельца): выделение и есть намерение,
					   кнопка удаляет сразу. */
					{
							var sections = uci.sections('sms_tool_js');
							var portDA = sections[0].readport;
							var storeDA = sections[0].storage;

							fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'delete', 'all', storeDA, portDA ]);
							/* Через модель, а не innerHTML напрямую: после удаления
							   всех сообщений экран должен показать «нет сообщений», а не
							   схлопнуться в пустоту. */
							smsSetState('empty');
							sms_update_selcount();
							try { window.localStorage.removeItem(sms_cache_key()); } catch (e) {}
    							setTimeout(function() {
								L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status', storeDA, portDA ]))
									.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var u = "0";
											msg_bar(Math.floor(u), t);
											save_count();
										}
								});
							}, 2000);
						}
			}
			else {

					/* Без confirm - как и при удалении всех (решение владельца). */
						{
							uci.load('sms_tool_js').then(function() {

								var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
								var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));
								var sections = uci.sections('sms_tool_js');
								var portDEL = sections[0].readport;

								/* Индексы из data-index карточек; у склеенного сообщения
								   там все части через дефис - разворачиваем в плоский
								   список чисел. */
								var idx = [];
								sms_selected_cards().forEach(function(card) {
									String(card.dataset.index || '').split(/[^0-9]+/).forEach(function(n) {
										n = parseInt(n, 10);
										if (!Number.isNaN(n)) { idx.push(n); }
									});
								});
								if (!idx.length) { return; }

								var deletelabel = document.getElementById('deleteinfo');
								if (deletelabel) { deletelabel.style.display = 'block'; }
								var done = 0;
								var showProgress = function() {
									if (!deletelabel) { return; }
									deletelabel.innerHTML = '';
									deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'},
										_('Please wait... deleted')+' '+done+' '+_('of')+' '+idx.length+' '+_('selected messages')));
								};
								showProgress();

								/* ПОСЛЕДОВАТЕЛЬНАЯ цепочка промисов: следующее удаление
								   уходит только после ответа на предыдущее. Прежний код
								   стрелял залпом setTimeout'ов с шагом 1.5 c: на медленном
								   порту вызовы наезжали друг на друга, каждый тащил свой
								   status (плюс немедленный третий на каждой итерации), а
								   финализатор с проверкой счётчика срабатывал по нескольку
								   раз. Здесь один проход и один финальный status. */
								var chain = Promise.resolve();
								idx.forEach(function(n) {
									chain = chain.then(function() {
										return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'delete', String(n), '', portDEL ]), '')
											.then(function() { done++; showProgress(); });
									});
								});
								chain.then(function() {
									/* Всё удалено: снимаем карточки, чистим warm-кэш и одним
									   status сверяем полоску памяти и персист счётчика. */
									sms_selected_cards().forEach(function(card) {
										if (card.parentNode) { card.parentNode.removeChild(card); }
									});
									sms_update_selcount();
									try { window.localStorage.removeItem(sms_cache_key()); } catch (e) {}
									return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status', storeL, portR ]), '')
										.then(function(res) {
											var st = sms_parse_status(res);
											if (st.u != null) {
												msg_bar(Math.floor(st.u), st.t);
												update_sms_count_for_modem(st.u).then(function(v) {
													sms_persist({ 'sms_count': v });
												});
											}
											if (deletelabel) { deletelabel.style.display = 'none'; deletelabel.innerHTML = ''; }
										});
								});
							});
						}
			    }
		}
	},
                                                                                                                                              
	handleRefresh: function(ev) {
		// Обновляем только список сообщений, без перезагрузки всей страницы.
		// Фолбэк на reload, если doRefresh ещё не готов (ранний клик).
		if (typeof this._doRefresh == 'function') { return this._doRefresh(false, true); }
		window.location.reload();
	},


	render: function(data) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		var self = this;
		return Promise.resolve(this.renderMain(data)).then(function(main) {
			return smssettings.panel('receive').then(function(panel) {
				return E([], [ main, panel ]);
			});
		});
	},

	renderMain: function(data) {

		var self = this;
		var sections, store;
		var view = document.getElementById("smssarea");
		store = '-';

		uci.load('sms_tool_js').then(function() {
		var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
		var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));
		// mergesms может быть не задан в uci (свежая конфигурация): тогда
		// ни ветка smsM=="1" (склейка), ни smsM=="0" не выполнялись, и
		// сообщения не рендерились (обновлялся только счётчик). Нормализуем
		// к "1"/"0". По умолчанию (значение НЕ задано) - "1" (склейка вкл.):
		// многочастные SMS показываются целиком. Явный "0" уважается.
		var _mv = uci.get('sms_tool_js', '@sms_tool_js[0]', 'mergesms');
		var smsM = (_mv == null || _mv === '') ? '1' : (_mv == '1' ? '1' : '0');
		var algo = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'algorithm'));
		var hide = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'bnumber'));
		var ledn = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'lednotify'));
		var ledt = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'ledtype'));
		var direct = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'direction'));

		/* Та же оговорка, что и у проверки ниже: у модема без AT-портов (HiLink)
		   портов нет и настроить их невозможно. Требовать этого - посылать
		   пользователя чинить несуществующее. */
		if (!portR && !isHilinkModem()) {
 			ui.addNotification(null, E('p', _('The package requires user configuration. \
					<br /><br /><b>The following need to be set:</b> \
					<ul><li>1. All ports for communication with the modem.</li><li>2. Additional options specific to the given modem (for handling USSD codes).</li><li> \
					3. Notification LED (optional).</li><li><ul>')), 'info');
		}
		
		var sections = uci.sections('sms_tool_js');
		var led = sections[0].smsled;

		/* Эти radio живут в DOM, который renderMain ещё не вернул и не
		   прикрепил к странице: sms_tool_js уже загружен в load(), поэтому
		   этот .then() выполняется микрозадачей ДО вставки DOM, и
		   querySelector возвращает null. Раньше обращение к .checked на null
		   бросало исключение, промис отклонялся, и цепочка status/recv ниже
		   вообще не запускалась - сообщения не появлялись. Ставим отметку
		   только если элемент уже существует (на автополлинге он есть). */
		var simRadio = document.querySelector('input[name="filter_area"][value="sim"]');
		var memRadio = document.querySelector('input[name="filter_area"][value="memory"]');
		if (storeL == "SM" && simRadio) simRadio.checked = true;
		if (storeL == "ME" && memRadio) memRadio.checked = true;
		if (ledn == "1")
			{
				switch (ledt) {
  					case 'S':
    						fs.exec_direct('/etc/init.d/led', [ 'restart' ]);
    						break;
  					case 'D':
    						fs.write('/sys/class/leds/'+led+'/brightness', '0');
    						break;
  					default:
					}
			}

		/* Индикатор загрузки списка. Чтение входящих (sms_tool recv) на части
		   модемов идёт до ~10 c, а счётчик из status приходит сразу - выглядело
		   так, будто сообщений нет, и обратной связи не было никакой.
		   Строку ДОБАВЛЯЕМ, а не перерисовываем таблицу: если обновление не
		   удастся, уже показанный список должен остаться на месте. */
		/* Пока сообщений на экране нет - показываем плейсхолдер НА МЕСТЕ списка
		   (он же держит его высоту). Если сообщения уже показаны, при обновлении
		   ничего не трогаем: мигать готовым списком ради индикатора не нужно. */
		/* Обёртки над единой моделью - оставлены, чтобы не переписывать все
		   точки вызова внутри doRefresh. */
		function showLoading() { smsSetState('loading'); }

		/* Снимать индикатор отдельно не требуется: список либо перерисуется
		   карточками, либо получит плейсхолдер «нет сообщений». Функция
		   оставлена, чтобы не переписывать все точки выхода из doRefresh.
		   Пометку «обновляется» (warm-путь) СНИМАЕМ явно - её никто не
		   перерисовывает. */
		function hideLoading() {
			/* Снимаем ТОЛЬКО пометку. Решение «пусто или нет» принимает модель
			   в момент отрисовки: раньше hideLoading сам ставил «нет сообщений»
			   и успевал сделать это при ещё не разобранном ответе. */
			smsNote(null);
			var l = document.getElementById('smsList');
			if (l && !l.firstChild) { smsSetState('empty'); }
		}

		/* doRefresh(updateCount, busy): читает статус + входящие и перерисовывает
		   таблицу. Вызывается один раз при заходе и затем по таймеру
		   (poll.add) - новые SMS появляются сами, без ручного «Обновить».
		   updateCount=true только на первом вызове: обновление счётчика
		   sms_count дёргает uci.apply(), которое нельзя гонять каждые N сек.
		   busy=true - показать индикатор: только при заходе на страницу и по
		   кнопке «Обновить». На тиках автополлинга индикатор не нужен - он бы
		   мигал каждые 15 секунд. */
		/* Индикатор снимаем ТОЛЬКО когда цепочка доработала и список отрисован.
		   Раньше hideLoading() стоял в начале обработчика ответа: индикатор гас в
		   момент получения данных, а сообщения появлялись через пару секунд - и
		   выглядело, будто всё загрузилось, но пусто. */
		function doRefresh(updateCount, busy) {
			if (busy) { showLoading(); }
			var p = doRefreshInner(updateCount);
			if (!p || typeof p.then != 'function') { hideLoading(); return Promise.resolve(); }
			return p.then(function(r) { hideLoading(); return r; },
			              function(e) { hideLoading(); throw e; });
		}

		function doRefreshInner(updateCount) {
		// Re-read the storage and port FRESH on every tick (not the values
		// captured once at render): otherwise switching SIM<->Modem storage has
		// no effect until a full page reload, and an empty storage value read at
		// load time keeps failing. Default to ME - most USB modems deliver
		// incoming SMS to modem memory, and reading with an empty '-s ' fails.
		var storeL = uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage') || 'ME';
		var portR = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
		/* Порт нужен НЕ ВСЕГДА. У модемов без AT-портов (HiLink) сообщения лежат
		   в самом модеме и достаются его API - порта у них нет и быть не может.
		   Раньше страница упиралась в эту проверку и требовала настроить то,
		   чего не существует. Признак берём из профиля активного модема. */
		if (!portR && !isHilinkModem()) {
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return Promise.resolve();
		}
		return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
				.then(function(res) {
					if (res) {
							var _st = sms_parse_status(res);
							var t = _st.t, u = _st.u;

							/* Полоску заполняем ЗДЕСЬ. Ниже по коду есть такой же
							   вызов в конце колбэка, но до него не доходит
							   исполнение: следующая строка делает return, и
							   счётчик не обновлялся никогда - в полоске всегда
							   висел прочерк из атрибута title. */
							if (u != null) { msg_bar(Math.floor(u), t); }

						/* Список берём через smsbridge.sh, а не напрямую у sms_tool:
						   у модемов без AT-портов (HiLink) сообщения лежат в самом
						   модеме и достаются его API. Мост решает это сам и отдаёт
						   ТОТ ЖЕ формат {"msg":[...]}, поэтому разбор ниже не
						   менялся. Для обычных модемов вызов уходит в sms_tool с
						   прежними аргументами - их путь не тронут. */
						return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'recv' , storeL , portR ]))
							.then(function(res2) {
								// список пришёл (или не пришёл) - индикатор снимаем в любом
								// случае, иначе он висел бы вечно при пустом/сбойном ответе
								if (res2) {

 									var table = document.getElementById('smsList');
									// Списка может НЕ БЫТЬ: панель настроек SMS
									// (чужой smssettings.js) иногда падает на apk-прошивке
									// раньше, чем отрисуется #smsList, а poll уже
									// запущен. Без этой проверки doRefresh падал на
									// разборе списка и рушил весь тик.
									if (!table) { hideLoading(); return; }
									/* СПИСОК ЧИСТИМ ТОЛЬКО ПОСЛЕ УСПЕШНОГО РАЗБОРА - см. try
									   ниже. Раньше очистка стояла здесь, ДО JSON.parse: если
									   ответ приходил обрезанным (AT-порт занят опросом метрик
									   и дозвоном - на FM350 это регулярно), разбор падал
									   исключением, и список оставался ПУСТЫМ, хотя сообщения
									   никуда не делись. Симптом: сообщения показались, через
									   пару секунд исчезли, счётчик остался, «Обновить» уже не
									   помогал. На модеме под ModemManager порт свободнее,
									   поэтому там баг и не проявлялся. */

									/* Баг sms_tool 2025.08.x (-j): кодпойнты, у которых МЛАДШИЙ
									   байт >= 0x80 (U+00A0 nbsp, «» U+00AB/BB, …), в JSON-кодере
									   знакорасширяются — он печатает "ÿffffa0" вместо
									   " ". JSON.parse затем даёт "ÿffffa0" (то, что видел
									   пользователь). Чиним шаблон "\uHHffffffLL" -> "\uHHLL"
									   ДО разбора. Настоящее место фикса — JSON-эскейпер sms_tool. */
									res2 = res2.replace(/\\u([0-9a-fA-F]{2})f{6}([0-9a-fA-F]{2})/g, '\\u$1$2');

									/* Proper parsing instead of positional slicing:
									   substring(7) relied on the exact byte format
									   of sms_tool ({"msg":[...]}) and broke on any
									   other valid JSON (e.g. from sms_tool_mm/jshn,
									   which prints spaces). */
									var json;
									try {
										json = JSON.parse(res2).msg || [];
									} catch (e) {
										/* Битый/обрезанный ответ - состояние error: модель
										   сама решит, оставить показанное или показать
										   «нет сообщений», если экран пуст. */
										smsSetState('error');
										return;
									}
									/* Контейнер под карточки берём У МОДЕЛИ - она же его и
									   очищает, ровно здесь и только когда данные разобраны. */
									table = smsSetState('list');
									if (!table) { return; }

									/* sms_tool's UCS2 decoder replaces code points U+0080..U+00FF
									   (non-breaking space, guillemets «», …) with U+FFFD (�).
									   Operators use those mostly as spaces, so swap � -> space to
									   keep the text readable (real fix belongs in sms_tool). */
									json.forEach(function(o) {
										if (o && typeof o.content === 'string') {
											o.content = o.content.replace(/\uFFFD/g, ' ');
										}
									});

									var aidx = [];

									/* АВТООПРЕДЕЛЕНИЕ СКЛЕЙКИ.
									   В поставляемом конфиге mergesms='0', то есть значение ЗАДАНО
									   нулём, и умолчание «включено» (оно срабатывает только когда
									   опция не задана вовсе) до пользователя не доходит: длинные SMS
									   показываются кусками, пока он сам не найдёт галку.
									   Смотрим на факты: часть сообщения помечена total>1. Если такие
									   есть, а склейка выключена - включаем и запоминаем, что это
									   сделали МЫ (mergesms_auto). Флаг нужен, чтобы уважать обратный
									   выбор: если пользователь потом снимет галку, мы её не вернём. */
									if (smsM != "1" &&
									    uci.get('sms_tool_js', '@sms_tool_js[0]', 'mergesms_auto') != '1' &&
									    json.some(function(o) { return (o.total || 0) > 1; })) {
										smsM = "1";
										sms_persist({ 'mergesms': '1', 'mergesms_auto': '1' });
										ui.addNotification(null, E('p',
											_('Multipart messages found - merging enabled automatically. You can turn it off in SMS settings.')), 'info');
									}

									/* Merging messages */
									if (smsM == "1") {

											/* Склейка многочастных SMS. Части ОДНОГО сообщения несут один
											   и тот же UDH-reference, но приходят с чуть разными
											   таймстампами (отличаются на секунды), поэтому прежняя
											   группировка по timestamp их разбивала - сообщение
											   показывалось кусками. Группируем по reference (одиночные -
											   по index), сортируем части по part и склеиваем по порядку. */
											var groups = {};
											json.forEach(function(o) {
												var key = (o.reference != null && o.total > 1)
													? o.sender + '#ref#' + o.reference + '#' + o.total
													: o.sender + '#one#' + o.timestamp + '#' + o.index;
												(groups[key] = groups[key] || []).push(o);
											});
											var result = Object.keys(groups).map(function(k) {
												var parts = groups[k].sort(function(a, b) { return (a.part || 0) - (b.part || 0); });
												var first = parts[0];
												var text = parts.map(function(p) { return p.content; }).join('');
												/* ЧАСТЕЙ МЕНЬШЕ, ЧЕМ ЗАЯВЛЕНО - и это не наша обрезка:
												   на ПЕРЕПОЛНЕННОЙ SIM хвост длинного сообщения просто не
												   помещается (наблюдалось: 3 части из 5 при 15/15).
												   Показать обрывок молча нельзя - его принимают за our баг. */
												var want = first.total || 0;
												if (want > 1 && parts.length < want) {
													text += ' [' + parts.length + '/' + want + ']';
												}
												return {
													sender: first.sender,
													timestamp: first.timestamp,
													total: first.total,
													index: parts.map(function(p) { return p.index; }).join('-'),
													content: text
												};
											});
											result.sort(function(a, b) { return new Date(b.timestamp) - new Date(a.timestamp); });
													if (true) { /* рендер НЕ зависит от разбора счётчика (u): список уже прочитан */
															var Lres = L.resource('icons/5gmodem/cmessage.svg');

															for (var i = 0; i < result.length; i++) {
																table.appendChild(sms_make_card(result[i], Lres, hide));
																aidx.push(result[i].index+'-');
															}
															smsRestoreSelection();
															sms_seen_sync(result);
															sms_update_newcount();
															sms_update_selcount();
															sms_cache_save(result, u, t);

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															if (updateCount && u != null) format_with_modem_index(axx).then(function(formattedIndex) {
																update_sms_count_for_modem(u).then(function(updatedCount) {
																	sms_persist({ 'sms_count_index': formattedIndex, 'sms_count': updatedCount });
																});
															});
											}

										}
									}

									/* No merging messages */
									if (smsM == "0") {
									
										/* Sorting messages by delivery time */
										var sortbyTime = json.sort((function (a, b) { return new Date(b.timestamp) - new Date(a.timestamp) }));

										/* Sorting messages by parts */
										var sortedData = sortbyTime.sort((a, b) => {
    										if (a.timestamp === b.timestamp && a.sender === b.sender && a.total === b.total) {
        											return a.part - b.part;
    										} else {
        											return 0;
    										}
										});

										if (true) { /* рендер НЕ зависит от разбора счётчика (u): список уже прочитан */

											var Lres = L.resource('icons/5gmodem/cmessage.svg');

											for (var i = 0; i < sortedData.length; i++) {
												table.appendChild(sms_make_card(sortedData[i], Lres, hide));
												aidx.push(sortedData[i].index+'-');
											}
											smsRestoreSelection();
											sms_seen_sync(sortedData);
											sms_update_newcount();
											sms_update_selcount();
											sms_cache_save(sortedData, u, t);
											
											var axx = aidx.toString();
											axx = axx.replace(/,/g, ' ');
											axx = axx.replace(/-/g, ' ');

											if (updateCount && u != null) format_with_modem_index(axx).then(function(formattedIndex) {
												update_sms_count_for_modem(u).then(function(updatedCount) {
													sms_persist({ 'sms_count_index': formattedIndex, 'sms_count': updatedCount });
												});
											});
									}

								}
						});

				} else {
					// status вернул пусто. Порт здесь заведомо задан (проверили
					// в начале doRefresh), значит это либо пустой ящик, либо
					// модем на миг занят на этом тике автополлинга. НЕ показываем
					// «укажите порт» (это ввод в заблуждение и мигало бы каждые
					// 15 c) и НЕ трогаем уже показанный список - ждём следующий
					// тик. t/u не определены - к ним не обращаемся.
					// Индикатор снимаем: до чтения списка дело не дошло.
				}

			/* Достижимо только когда status вернул пусто: в успешной ветке выше
			   стоит return. Тогда u не определена и вызова не будет - полоску
			   заполняет вызов внутри той ветки. Оставлено как страховка. */
			/* Проверка «список пуст» УБРАНА: этим занимается модель (smsSetState).
			   Раньше здесь стояло собственное условие, и оно срабатывало даже
			   тогда, когда ответ ещё не был разобран - именно так пустой экран
			   появлялся при живых сообщениях. */

			if (document.getElementById('msg') && typeof u !== 'undefined') {
				msg_bar(Math.floor(u), t);
			    }
    		});
		}
		/* ПЕРВОЕ ЧТЕНИЕ ОТКЛАДЫВАЕМ ДО ОТРИСОВКИ.
		   Вызов здесь был и раньше, но выполнялся ЗРЯ: этот код идёт по ходу
		   render(), а разметку render возвращает НИЖЕ - на момент вызова таблицы
		   на странице ещё нет, и рисовать прочитанное некуда. Сообщения молча
		   пропадали, а появлялись только с первым тиком автообновления, то есть
		   через 15 секунд - отсюда и привычка жать «Обновить».
		   setTimeout(0) отдаёт управление обратно: render успевает вернуть
		   разметку и LuCI прикрепляет её к странице, и только потом читаем.
		   updateCount=true только здесь - обновление счётчика дёргает uci.apply(),
		   гонять его на каждом тике нельзя. busy=true - показать индикатор,
		   чтобы пустой список не выглядел так, будто сообщений нет. */
		/* ЖДЁМ ПОЯВЛЕНИЯ ТАБЛИЦЫ, а не угадываем момент таймером.
		   Этот блок живёт внутри uci.load(...).then(...) - отдельного промиса,
		   никак не связанного с отрисовкой. Список smsList создаётся ниже, в
		   разметке, которую render возвращает в самом конце. Кто из них успеет
		   раньше - гонка, и на практике чтение выигрывало: элемента ещё нет,
		   рисовать прочитанное некуда, сообщения молча терялись и появлялись
		   только с первым тиком автообновления через 15 секунд.
		   setTimeout(0) это не лечил - он откладывал на шаг от РАЗРЕШЕНИЯ uci.load,
		   а не от появления разметки. Поэтому ждём сам элемент. */
		/* WARM-RENDER: последний показанный список из localStorage - мгновенно,
		   до чтения с модема (оно занимает секунды). Карточки строим тем же
		   sms_make_card, так что они полностью интерактивны (выделение,
		   удаление). Живое чтение ниже перерисует список и обновит кэш. */
		function warmRender() {
			var c = sms_cache_load();
			var table = document.getElementById('smsList');
			if (!c || !c.list || !c.list.length || !table) { return; }
			if (table.querySelector('.sms-card')) { return; }
			/* Через модель: она запомнит выделение перед очисткой (важно, когда
			   тёплый рендер приходит поверх уже показанного списка). */
			table = smsSetState('list') || table;
			var Lres = L.resource('icons/5gmodem/cmessage.svg');
			for (var i = 0; i < c.list.length; i++) {
				table.appendChild(sms_make_card(c.list[i], Lres, hide));
			}
			smsRestoreSelection();
			sms_seen_sync(c.list);
			sms_update_newcount();
			sms_update_selcount();
			if (document.getElementById('msg') && c.u != null) { msg_bar(Math.floor(c.u), c.t); }
		}
		(function waitTable(n) {
			if (document.getElementById('smsList')) { warmRender(); doRefresh(true, true); return; }
			if (n > 50) { return; }   // ~5 c и сдаёмся: дальше подхватит автообновление
			window.setTimeout(function() { waitTable(n + 1); }, 100);
		}(0));
		/* Автообновление входящих: новые SMS появляются сами, без ручного
		   «Обновить». poll снимается автоматически при уходе со страницы. */
		poll.add(function() { return doRefresh(false); }, 15);
		/* Кнопка «Обновить» теперь обновляет только список сообщений
		   (см. handleRefresh), а не перезагружает всю страницу. */
		self._doRefresh = doRefresh;
		});

		var actions = E('div', { 'class': 'sms-actions' }, [
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleRefresh')
					}, [ _('Refresh') ]),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'forward',
						'style': 'display: none;',
						'click': ui.createHandlerFn(this, 'handleForward')
					}, [ _('Forward SMS') ]),
					E('span', { 'id': 'sms-newcount', 'class': 'sms-newcount', 'style': 'display: none;' }, ''),
					E('button', {
						'class': 'cbi-button cbi-button-neutral',
						'id': 'sms-markread',
						'style': 'display: none;',
						'click': function() { sms_mark_all_read(); }
					}, [ _('Mark read') ]),
					E('span', { 'id': 'sms-selcount', 'class': 'sms-selcount' }, ''),
					E('button', {
						'class': 'cbi-button cbi-button-remove sms-act-del',
						'id': 'execute',
						'style': 'display: none;',
						'click': ui.createHandlerFn(this, 'handleDelete')
					}, [ _('Delete') ])
		]);

		var v = E('div', { 'class': 'cbi-section tgpage' }, [

			E('table', { 'class': 'table', 'id': 'sms-info-table' }, [
				(function() {
					var sections = uci.sections('defmodems', 'defmodems');
					var serialModems = [];
					
					if (sections && sections.length > 0) {
						serialModems = sections.filter(function(s) {
							return s.modemdata === 'serial';
						});
					}
					
					if (serialModems.length > 0) {
						var currentPort = uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport');
						var currentModem = serialModems.find(function(s) {
							return s.comm_port === currentPort;
						});
						
						if (!currentModem) currentModem = serialModems[0];
						
						var label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
						
						var buttonsDisabled = (serialModems.length > 1) ? null : true;
						
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td left', 'width': '33%' }, [ _('Select modem') ]),
							E('td', { 'class': 'td' }, [
								E('div', { 'class': 'controls' }, [
									E('div', { 'class': 'pager center tg-row' }, [
										E('button', { 
											'class': 'btn cbi-button-neutral prev', 
											'aria-label': _('Previous modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'class': 'tg-col-narrow',
											'disabled': buttonsDisabled
										}, [ ' ◄ ' ]),
										E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
										E('button', { 
											'class': 'btn cbi-button-neutral next', 
											'aria-label': _('Next modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'class': 'tg-col-narrow',
											'disabled': buttonsDisabled
										}, [ ' ► ' ])
									])
								])
							])
						]);
					} else {
						return E('div', { 'style': 'display: none;' });
					}
				}.bind(this))(),
    				(function() {
					/* Хранилище и заполненность - ОДНОЙ строкой, без подписи слева.
					   Строка всегда видима: в режиме ModemManager (sms_via_mm)
					   выбор SM/ME в чтении не участвует (сообщения живут в
					   ModemManager), поэтому прячем только переключатели, а
					   полоску памяти оставляем. Радиокнопки остаются в DOM:
					   логика обновления безусловно читает отмеченную. */
					var cfg = uci.sections('sms_tool_js');
					var viaMM = (cfg && cfg[0] && cfg[0].sms_via_mm == '1');
					var areaTip = _('Any change in the area from which SMS messages will be read requires refreshing the messages');
					var areaOpt = (function(value, label, checked) {
						return E('label', {
							'style': 'display:inline-flex !important;align-items:center !important;gap:6px;height:auto !important;min-height:0 !important;line-height:1.4;',
							'data-tooltip': areaTip
						}, [
							E('input', {
								'type': 'radio',
								'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
								'name': 'filter_area',
								'value': value,
								'change': ui.createHandlerFn(this, 'handleSWarea'),
								'checked': checked ? true : null
							}),
							' ',
							label
						]);
					}).bind(this);

					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'colspan': '2' }, [
							E('div', { 'class': 'sms-storage-row' }, [
								E('div', {
									'class': 'sms-storage-opts',
									'style': viaMM ? 'display: none;' : null
								}, [
									(function() {
										/* Отмечаем ФАКТИЧЕСКОЕ хранилище из настроек:
										   радио всегда стартовало с SIM, хотя чтение
										   шло по uci (обычно ME) - переключатель врал. */
										var _stg = uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage') || 'ME';
										return E([], [
											areaOpt('sim', _('SIM card'), _stg === 'SM'),
											areaOpt('memory', _('Modem memory'), _stg !== 'SM')
										]);
									})()
								]),
								E('div', {
									'id': 'msg',
									'class': 'cbi-progressbar',
									'title': '-'
								}, E('div')),
								/* Кнопки - в ТОМ ЖЕ ряду, что выбор хранилища и полоса
								   занятости: одна строка управления вместо двух, а список
								   начинается сразу под ней. */
								actions
							]),
							E('div', {
								'style': 'text-align:center;font-size:90%',
								'id': 'deleteinfo'
							}, [ '' ])
						])
					]);
				}.bind(this))(),
		]),

				E('div', {'id': 'forward-status', 'style': 'margin: 10px 0; display: none;'}),

			/* Список сообщений. Ряд действий - НАД ним (см. return ниже):
			   «Обновить» доступен сразу, без прокрутки всей переписки.
			   «Выделить все» убрана - выделение кликом по карточкам, а массовое
			   удаление доступно и так: отмечаешь нужные. */
			/* Ряд действий - НАД списком, но ПОД шапкой вкладки (выбор
			   хранилища и полоса занятости): «Обновить» под рукой без прокрутки
			   всей переписки, а настройки хранилища остаются наверху. */
			E('div', { 'id': 'smsList' }),
		]);

		/* Кнопки ЗА пределами cbi-section - как на вкладке «Исходящие»: ряд
		   действий стоит ПОД плашкой, а не внутри неё. Поэтому возвращаем не
		   один блок, а два соседних элемента (E([], [...]) - фрагмент). */


		return E([], [ v ]);
	},

	popTimeout: function(a, message, timeout, severity) {
		ui.addTimeLimitedNotification(a, message, timeout, severity);
	}
});
