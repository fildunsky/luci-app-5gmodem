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

document.head.append(E('style', {'type': 'text/css'},
`
/* Инфо-таблица над списком (модем, хранилище, ёмкость): без линий между строками */
#sms-info-table td,
#sms-info-table th,
#sms-info-table .td,
#sms-info-table .th {
  border: none !important;
}

/* СПИСОК СООБЩЕНИЙ - карточки, а не таблица.
   Карточка должна выглядеть В ТОЧНОСТИ как кнопки приоритета интернета и
   спидтеста на вкладке «Сеть», поэтому:
   1) на элементе те же классы темы - btn cbi-button. Именно они дают фон,
      рамку и базовую типографику; без них <button> выглядит по-другому, и
      никакой своей палитрой это не повторить;
   2) геометрия ниже покомпонентно скопирована с .netpri-btn (netpri.js).
      Не переиспользуем те правила напрямую: они заскоплены под .netpribar и
      на этой странице просто не применятся. При правке netpri-кнопок эти
      значения нужно править парой. */
#smsList {
  display: flex;
  flex-direction: column;
  gap: .4em;
}

.sms-card {
  /* значения 1:1 из .netpribar .netpri-btn */
  padding: .35em 1em;
  border-radius: 6px;
  cursor: pointer;
  font-weight: 600;
  display: flex;
  flex-direction: column;
  align-items: flex-start;
  text-align: left;
  line-height: 1.15;
  /* proton2025 задаёт button,.btn{gap:8px} - на flex-column это даёт большие
     вертикальные дыры между строками (та же нейтрализация, что в netpri.js) */
  gap: 0;
  /* В отличие от ряда netpri, карточки идут столбцом во всю ширину. */
  width: 100%;
  box-sizing: border-box;
  align-self: stretch;
}

/* СДВИГ КАРТОЧЕК (был виден только в proton2025 и только на широком экране).
   Тема задаёт:  button+button, .btn+.btn, .cbi-button+.cbi-button { margin-left: 8px }
   Рассчитано это на кнопки В РЯД, а у нас они столбцом: каждой следующей
   карточке добавлялось 8px слева, и она на столько же вылезала за правый край.
   Просто margin:0 в .sms-card не помогал - у .btn+.btn специфичность (0,2,0)
   против (0,1,0), тема выигрывала. Добавляем #smsList -> (1,1,0).
   ВНИМАНИЕ: этот блок - шаблонная строка, обратные кавычки в комментариях
   закрывают её и ломают файл. */
#smsList .sms-card {
  margin: 0;
}

/* Выделено - как .netpri-btn.active, то есть как кнопка на hover у темы: одна
   акцентная рамка, без заливки и без внутренней обводки.
   pointer-events:none из netpri НЕ берём: активную кнопку там нельзя нажать
   повторно, а выделение сообщения снимается тем же кликом. */
.sms-card.selected {
  border-color: var(--proton-accent, #0095ff);
}

/* Шапка тянется во всю ширину карточки, иначе align-items:flex-start прижмёт
   её по содержимому и время не уедет вправо. */
.sms-card .sms-card-head {
  display: flex;
  align-items: baseline;
  gap: .6em;
  width: 100%;
  margin-bottom: .2em;
}

/* отправитель - как .netpri-name (вес 600 наследуется от кнопки) */
.sms-card .sms-card-from {
  display: flex;
  align-items: center;
  gap: .35em;
  flex: 1 1 auto;
  min-width: 0;
  overflow-wrap: anywhere;
}

/* дата и время - как .netpri-sub, плюс ровные цифры от .netpri-ip */
.sms-card .sms-card-time {
  flex: 0 0 auto;
  font-size: .72em;
  font-weight: 400;
  opacity: .7;
  white-space: nowrap;
  font-variant-numeric: tabular-nums;
}

/* Текст сообщения - обычный вес, как .netpri-sub/.netpri-ip, но БЕЗ их
   уменьшения до .72em: там это подпись, здесь - основное содержимое. */
.sms-card .sms-card-text {
  font-weight: 400;
  line-height: 1.35;
  text-align: left;
  overflow-wrap: anywhere;
  white-space: normal;
}

/* иконка - размеры .netpri-ic */
.sms-row-icon {
  display: block;
  width: 16px;
  height: 16px;
  flex: 0 0 auto;
}

.sms-row-icon img {
  display: block;
  width: 16px;
  height: 16px;
}

:root[data-darkmode="true"] .sms-row-icon {
  opacity: 0.5;
}

/* Хранилище и заполненность - одной строкой, без подписи слева. На узком
   экране полоска переносится под переключатели (flex-wrap). */
.sms-storage-row {
  display: flex;
  align-items: center;
  gap: 1em;
  flex-wrap: wrap;
}

.sms-storage-opts {
  display: flex;
  align-items: center;
  gap: 1.2em;
  flex: 0 0 auto;
}

/* Полоска резиновая: занимает остаток строки, но не ужимается до нечитаемой -
   при нехватке места уходит на вторую строку целиком. */
.sms-storage-row .cbi-progressbar {
  flex: 1 1 14em;
  min-width: 14em;
  margin: 0;
}

/* Ряд действий: «Обновить» и «Переслать» слева, «Удалить» прижата вправо -
   как ряд приоритетов интернета со спидтестом на вкладке «Сеть». */
.sms-actions {
  display: flex;
  align-items: center;
  gap: .5em;
  flex-wrap: wrap;
  margin: .5em 0;
}

/* Тема добавляет соседним кнопкам margin-left: 8px - вместе с gap получался
   двойной зазор. Гасим тем же приёмом, что и сдвиг карточек: селектор из трёх
   классов (0,3,0) перебивает .cbi-button+.cbi-button (0,2,0). */
.sms-actions .cbi-button + .cbi-button {
  margin-left: 0;
}

/* Вправо уезжает СЧЁТЧИК, а «Удалить» встаёт следом - у самого края.
   margin-left:auto на первом из прижимаемых элементов съедает весь свободный
   зазор, поэтому auto стоит на счётчике, а не на кнопке. */
.sms-actions .sms-selcount {
  margin-left: auto;
}

/* Плейсхолдер на месте списка: держит его высоту, пока сообщений нет или они
   ещё грузятся. Раньше пустой список схлопывался в ничто, и страница выглядела
   сломанной - особенно при заходе, когда чтение занимает несколько секунд. */
.sms-empty {
  border: 1px dashed var(--border-color-medium);
  border-radius: 6px;
  padding: 1.2em .85em;
  text-align: center;
  opacity: .6;
}

.sms-selcount {
  margin-left: .5em;
  opacity: .65;
}
`));

function msg_bar(v, m) {
var pg = document.querySelector('#msg')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);

pg.firstElementChild.style.width = pc + '%';
/* Текст внутри полоски рисует тема из атрибута title. Показываем счёт
   сообщений, а не проценты: «Память: 2/15». */
pg.setAttribute('title', _('Memory: %s/%s').format(v, m));
}

/* ВЫДЕЛЕНИЕ СООБЩЕНИЙ.
   Галочек в списке больше нет: сообщение выделяется кликом по карточке, а
   состояние живёт в классе .selected. Чекбоксы не сохраняем даже скрытыми -
   <input> внутри <button> невалиден. Индексы сообщения (у склеенного
   многочастного - все части через дефис) лежат в data-index; удаление берёт
   их оттуда. */
/* Плейсхолдер вместо списка. state: 'loading' - идёт чтение, 'empty' - прочитали,
   сообщений нет. */
function sms_placeholder(state) {
	var list = document.getElementById('smsList');
	if (!list) { return; }
	list.innerHTML = '';
	list.appendChild(E('div', { 'class': 'sms-empty', 'id': 'smsEmpty' }, [
		state === 'loading'
			? E('span', { 'class': 'spinning' }, _('Loading messages…'))
			: E('span', {}, _('No messages'))
	]));
}

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
function sms_make_card(item, iconSrc, hide) {
	var sender = String(item.sender || '');
	if (hide && sender.includes(hide)) { sender = sender.slice(0, -5) + '#####'; }
	var text = String(item.content || '').replace(/\s+/g, ' ').trim();

	var card = E('button', {
		'type': 'button',
		/* btn cbi-button - те же классы темы, что у кнопок netpri: весь базовый
		   вид карточки приходит отсюда, .sms-card только раскладывает содержимое. */
		'class': 'btn cbi-button sms-card',
		'aria-pressed': 'false',
		/* Удаление берёт индексы отсюда, пересылка - отправителя, время и текст.
		   Раньше и то и другое читалось из ячеек строки (cells[1..3]); с уходом
		   от таблицы такой способ отвалился бы молча - пустым письмом. */
		'data-index': String(item.index),
		'data-sender': sender,
		'data-timestamp': item.timestamp,
		'data-message': text
	}, [
		E('div', { 'class': 'sms-card-head' }, [
			E('span', { 'class': 'sms-card-from' }, [
				E('span', { 'class': 'sms-row-icon' }, [
					E('img', { 'src': iconSrc })
				]),
				E('span', {}, sender)
			]),
			E('span', { 'class': 'sms-card-time' }, item.timestamp)
		]),
		E('div', { 'class': 'sms-card-text' }, text)
	]);

	card.addEventListener('click', function() {
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
								var total = res.substring(res.indexOf("total"));
								var t = total.replace ( /[^\d.]/g, '' );
								var used = res.substring(17, res.indexOf("total"));
								var u = used.replace ( /[^\d.]/g, '' );
								
								update_sms_count_for_modem(u).then(function(updatedValue) {
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
function smsToolBin() {
	return uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_via_mm') == '1' ? '/usr/bin/sms_tool_mm' : '/usr/bin/sms_tool';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('sms_tool_js'),
			L.resolveDefault(uci.load('defmodems'))
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
					if (confirm(_('Delete all the messages?')))
						{
							var sections = uci.sections('sms_tool_js');
							var portDA = sections[0].readport;
							var storeDA = sections[0].storage;

							fs.exec_direct(smsToolBin(), [ '-d' , portDA , 'delete' , 'all' ]);
							var smsList = document.getElementById("smsList");
							if (smsList) { smsList.innerHTML = ''; }
							sms_update_selcount();
    							setTimeout(function() {
								L.resolveDefault(fs.exec_direct(smsToolBin(), [ '-s' , storeDA , '-d' , portDA , 'status' ]))
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

					if (confirm(_('Delete selected message(s)?')))
						{
						uci.load('sms_tool_js').then(function() {

							var storeL = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'storage'));
							var portR = (uci.get('sms_tool_js', '@sms_tool_js[0]', 'readport'));

							var array = [];
							var checkb = sms_selected_cards();

							/* Индексы берём из data-index карточки. Прежний код читал
							   .id чекбокса и отсеивал галку «выделить все» сравнением
							   с необъявленной переменной source - в strict-режиме это
							   ReferenceError, то есть удаление выбранных падало здесь
							   же. Отсеивать больше нечего: выборка и так только из
							   карточек сообщений. */
							for (var i = 0; i < checkb.length; i++) {
								array.push(checkb[i].dataset.index + ',');
							}

							if (array) {

							var args = [];
							var sections = uci.sections('sms_tool_js');
							var portDEL = sections[0].readport;
							var storeDS = sections[0].storage;

							args.push(array);
							var ax = args.toString();
							ax = ax.replace(/,/g, ' ');
							ax = ax.replace(/-/g, ' ');

							var smsnr = ax.split(" ");

							var smsallchars = smsnr.toString();
							var smsdelcount = 0;
							var smsdeleted = 0;

							var inumber = false;

							for (var i = 0; i < smsallchars.length; i++) {
    							var ch = smsallchars[i];

    							if (ch >= '0' && ch <= '9') {
        							if (!inumber) {
            								smsdelcount++;
            								inumber = true;
        							}
    								} else if (ch === ',') {
        								inumber = false;
    								} else {
        								inumber = false;
    								}
							}
	
							var deletelabel = document.getElementById("deleteinfo");
							deletelabel.style.display = 'block';

								for (var i=0; i < smsnr.length + 2; i++)
									{
									(function(i) {
    									setTimeout(function() { 
    									smsnr[i] = parseInt(smsnr[i], 10);

									if (!Number.isNaN(smsnr[i]))
										{
										fs.exec_direct(smsToolBin(), [ '-d' , portDEL , 'delete' , smsnr[i] ]);
                						smsdeleted++;
										L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});
				
										}
										L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});

										if (smsdelcount == smsdeleted) {
											setTimeout(function() {
											var hidecount = document.getElementById('deleteinfo');
											uci.load('sms_tool_js').then(function() {
												var savedCount = uci.get('sms_tool_js', '@sms_tool_js[0]', 'sms_count') || '';
												L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
												.then(function(verifyRes) {
													if (verifyRes) {
														var verifyUsed = verifyRes.substring(17, verifyRes.indexOf("total"));
														var verifyU = verifyUsed.replace( /[^\d.]/g, '' );
														var savedMatch = savedCount.match(/(?:dfm\d+_)?(\d+)(?:\s|$)/);
														var savedNum = savedMatch ? savedMatch[1] : savedCount.replace(/[^\d]/g, '');
														if (savedNum !== verifyU) {
															update_sms_count_for_modem(verifyU).then(function(correctedValue) {
																sms_persist({ 'sms_count': correctedValue });
															});
														}
													}
													hidecount.style.display = 'none';
												});
											});
											    save_count();
											}, 7000);
										}
									}, 1500 * i);
								})(i);
										L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
										.then(function(res) {
										if (res) {
											var total = res.substring(res.indexOf("total"));
											var t = total.replace ( /[^\d.]/g, '' );
											var used = res.substring(17, res.indexOf("total"));
											var u = used.replace ( /[^\d.]/g, '' );
											msg_bar(Math.floor(u), t);
											deletelabel.innerHTML = '';
											deletelabel.appendChild(E('span', {'class': 'spinning', 'style': 'font-size: inherit;'}, _('Please wait... deleted')+' '+smsdeleted+' '+_('of')+' '+smsdelcount+' '+_('selected messages')));
										}
										});
								}
								sms_selected_cards().forEach(function(card) {
									if (card.parentNode) { card.parentNode.removeChild(card); }
								});
								sms_update_selcount();
								}
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

		if (!portR) {
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
		function showLoading() {
			var list = document.getElementById('smsList');
			if (!list) { return; }
			if (list.querySelector('.sms-card')) { return; }
			sms_placeholder('loading');
		}
		/* Снимать индикатор отдельно не требуется: список либо перерисуется
		   карточками, либо получит плейсхолдер «нет сообщений». Функция
		   оставлена, чтобы не переписывать все точки выхода из doRefresh. */
		function hideLoading() {
			var l = document.getElementById('smsList');
			if (l && !l.firstChild) { sms_placeholder('empty'); }
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
		if (!portR) {
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return Promise.resolve();
		}
		return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/smsbridge.sh', [ 'status' , storeL , portR ]))
				.then(function(res) {
					if (res) {
							var total = res.substring(res.indexOf("total"));
							var t = total.replace ( /[^\d.]/g, '' );

							var used = res.substring(17, res.indexOf("total"));
							var u = used.replace ( /[^\d.]/g, '' );

							/* Полоску заполняем ЗДЕСЬ. Ниже по коду есть такой же
							   вызов в конце колбэка, но до него не доходит
							   исполнение: следующая строка делает return, и
							   счётчик не обновлялся никогда - в полоске всегда
							   висел прочерк из атрибута title. */
							if (document.getElementById('msg')) { msg_bar(Math.floor(u), t); }

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
									table.innerHTML = '';

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
									var json = JSON.parse(res2).msg || [];

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
													if (u){
															var Lres = L.resource('icons/cmessage.svg');

															for (var i = 0; i < result.length; i++) {
																table.appendChild(sms_make_card(result[i], Lres, hide));
																aidx.push(result[i].index+'-');
															}
															sms_update_selcount();

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															var axx = aidx.toString();
															axx = axx.replace(/,/g, ' ');
															axx = axx.replace(/-/g, ' ');

															if (updateCount) format_with_modem_index(axx).then(function(formattedIndex) {
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

										if (u){

											var Lres = L.resource('icons/cmessage.svg');

											for (var i = 0; i < sortedData.length; i++) {
												table.appendChild(sms_make_card(sortedData[i], Lres, hide));
												aidx.push(sortedData[i].index+'-');
											}
											sms_update_selcount();
											
											var axx = aidx.toString();
											axx = axx.replace(/,/g, ' ');
											axx = axx.replace(/-/g, ' ');

											if (updateCount) format_with_modem_index(axx).then(function(formattedIndex) {
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
			/* Список мог остаться пустым: сообщений нет вовсе. Тогда вместо
			   схлопнутой пустоты показываем плейсхолдер. */
			(function() {
				var l = document.getElementById('smsList');
				if (l && !l.querySelector('.sms-card') && !l.querySelector('.sms-empty')) {
					sms_placeholder('empty');
				}
			}());

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
		(function waitTable(n) {
			if (document.getElementById('smsList')) { doRefresh(true, true); return; }
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

		var v = E('div', { 'class': 'cbi-section' }, [

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
									E('div', { 'class': 'pager center', 'style': 'display: flex; align-items: center; gap: 10px;' }, [
										E('button', { 
											'class': 'btn cbi-button-neutral prev', 
											'aria-label': _('Previous modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'style': 'min-width: 40px;',
											'disabled': buttonsDisabled
										}, [ ' ◄ ' ]),
										E('div', { 'class': 'text modem-display-text', 'style': 'flex: 1; text-align: center;' }, [ label ]),
										E('button', { 
											'class': 'btn cbi-button-neutral next', 
											'aria-label': _('Next modem'), 
											'click': ui.createHandlerFn(this, 'handleModemChange'),
											'data-tooltip': _('Changing a modem requires refreshing the messages'),
											'style': 'min-width: 40px;',
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
							'style': 'display:inline-flex;align-items:center;gap:6px;',
							'data-tooltip': areaTip
						}, [
							E('input', {
								'type': 'radio',
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
									areaOpt('sim', _('SIM card'), true),
									areaOpt('memory', _('Modem memory'), false)
								]),
								E('div', {
									'id': 'msg',
									'class': 'cbi-progressbar',
									'title': '-'
								}, E('div'))
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

			/* Список сообщений, под ним - действия (как на вкладке «Исходящие»).
			   Кнопки внизу потому, что читают сверху вниз: сперва сообщения, потом
			   что с ними сделать. «Выделить все» убрана - выделение кликом по
			   карточкам, а массовое удаление доступно и так: отмечаешь нужные. */
			E('div', { 'id': 'smsList' }),
		]);

		/* Кнопки ЗА пределами cbi-section - как на вкладке «Исходящие»: ряд
		   действий стоит ПОД плашкой, а не внутри неё. Поэтому возвращаем не
		   один блок, а два соседних элемента (E([], [...]) - фрагмент). */
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
					E('span', { 'id': 'sms-selcount', 'class': 'sms-selcount' }, ''),
					E('button', {
						'class': 'cbi-button cbi-button-remove sms-act-del',
						'id': 'execute',
						'style': 'display: none;',
						'click': ui.createHandlerFn(this, 'handleDelete')
					}, [ _('Delete') ])
		]);

		return E([], [ v, actions ]);
	},

	popTimeout: function(a, message, timeout, severity) {
		ui.addTimeLimitedNotification(a, message, timeout, severity);
	}
});
