'use strict';
'require baseclass';
'require fs';
'require ui';

/*
	Форма настроек сторожа интернета (health.sh) - ОБЩАЯ для двух мест:
	модалки на панели «Приоритет интернета» (netpri.js) и блока на странице
	«Настройки» (5gsettings.js). Раньше форма жила только в модалке, и при
	выключенном виджете приоритета настроить слежение было негде (issue #12).
	Значения читаем/пишем вербами getconf/setconf - без прямой работы с uci из
	браузера (бэкенд валидирует ключи белым списком).
*/

var HBIN = '/usr/share/5gmodem/health.sh';
var NBIN = '/usr/share/5gmodem/netpri.sh';

return baseclass.extend({
	/* Данные формы: конфиг сторожа + список аплинков (для лестниц лечения). */
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec_direct(HBIN, [ 'getconf' ]), '{}'),
			L.resolveDefault(fs.exec_direct(NBIN, [ 'list' ]), '[]')
		]).then(function(res) {
			var c = {}; try { c = JSON.parse(res[0]) || {}; } catch (e) {}
			var arr = []; try { arr = JSON.parse(res[1]) || []; } catch (e) {}
			arr = (Array.isArray(arr) ? arr : []).filter(function(o) {
				/* хвостовой элемент list - событие сторожа, не аплинк */
				return o && o.event == null;
			});
			return { conf: c, uplinks: arr };
		});
	},

	/* Построить форму. Возвращает { node, save }: node вставляется куда угодно
	   (модалка, блок страницы), save() собирает поля и применяет настройки
	   сразу (setconf + setheal + первый круг сторожа фоном).
	   opts.autosave - применять ЛЮБОЕ изменение самому, без кнопки (блок на
	   странице настроек; модалке не годится - у неё есть «Отмена»). Задержка
	   склеивает серию правок: галочка + селект = один вызов бэкенда.
	   opts.onsaved - колбэк после каждого автоприменения (индикация). */
	build: function(c, uplinks, opts) {
		/* Лестница лечения - только для модемов: wan-порту и Wi-Fi-станции
		   переподключение/перезагрузка модуля не осмысленны. Потолок на модем:
		   ничего -> переподключить -> + модуль -> + питание USB. */
		/* Строка формы - как в «Управлении частотами»: ПОДПИСЬ слева (33%),
		   поле/галка/селект справа. Выравнивание галочек с текстом чинится
		   вертикальным центрированием ячеек правилом .hw-form (modem.css). */
		var row = function(ctrl, label) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
				E('td', { 'class': 'td left' }, [ ctrl ])
			]);
		};
		var healRows = uplinks.filter(function(o) { return o.type === 'modem'; }).map(function(o) {
			var cur = (c.heal && c.heal[o.iface]) || '';
			/* Пустое значение = умолчание (переподключение + перезагрузка
			   модуля, см. heal_cap в health.sh); явное «не лечить» - отдельное
			   значение none, иначе его не отличить от «не выбирал вовсе». */
			return row(E('select', { 'id': 'hw-heal-' + o.iface, 'class': 'cbi-input-select', 'data-iface': o.iface }, [
				E('option', { 'value': '', 'selected': cur === '' ? '' : null }, _('Default (reconnect, then reboot the module)')),
				E('option', { 'value': 'none', 'selected': cur === 'none' ? '' : null }, _('Do nothing')),
				E('option', { 'value': 'ifup', 'selected': cur === 'ifup' ? '' : null }, _('Reconnect the interface')),
				E('option', { 'value': 'reboot', 'selected': cur === 'reboot' ? '' : null }, _('...plus reboot the module')),
				E('option', { 'value': 'power', 'selected': cur === 'power' ? '' : null }, _('...plus USB power cycle'))
			]), o.sub || o.iface);
		});
		var f = function(id, val, size) {
			return E('input', { 'id': id, 'class': 'cbi-input-text', 'value': String(val == null ? '' : val),
				'style': 'width:' + (size || '5em') });
		};
		var chk = function(id, on) {
			return E('input', { 'id': id, 'type': 'checkbox', 'checked': on ? '' : null });
		};
		/* Адреса проверки - стандартным списком LuCI (ui.DynamicList): строка на
		   адрес, плюс/крестик, как у DNS-серверов в редактировании интерфейса.
		   Бэкенд хранит их одной строкой через пробел - конвертируем на краях. */
		var tgtDl = new ui.DynamicList((c.targets || '77.88.8.8 1.1.1.1').split(/ +/).filter(function(t) { return t; }),
			null, { id: 'hw-tgt' });
		/* ТРИ СМЫСЛОВЫХ БЛОКА вместо пояснительных абзацев (решение владельца):
		   заголовок блока - его же выключатель, содержимое - только параметры.
		   Иерархия читается структурой: «Слежение» - фундамент (без него блоки
		   2-3 исчезают), «Переключение» - действие с одной настройкой возврата,
		   «Лечение» - потолки на каждый модем. */
		/* Заголовок блока - обычная строка той же таблицы: жирная подпись слева,
		   его галка-выключатель во ВТОРОЙ колонке, вместе с остальными полями -
		   одна вертикаль элементов управления на всю форму. */
		var titleRow = function(id, on, label) {
			return row(chk(id, on), E('strong', {}, label));
		};
		var node = E('div', {}, [
			E('div', { 'class': 'hw-block' }, [
				E('table', { 'class': 'table hw-form' }, [
					titleRow('hw-en', String(c.enabled) === '1', _('Enable watching'))
				]),
				E('table', { 'id': 'hw-blk-watch', 'class': 'table hw-form' }, [
					row(f('hw-int', c.interval || 30), _('Check interval, s')),
					row(tgtDl.render(), _('Ping targets')),
					/* защита от самострела на операторах с белыми списками:
					   яндексовский адрес доступен и там, выкидывать его из
					   целей не стоит */
					row(E('span', { 'style': 'font-size:.85em;opacity:.7' },
						_('If at least one target responds')), ''),
					row(f('hw-fail', c.fail_n || 3), _('Failures before down')),
					row(f('hw-ok', c.ok_n || 5), _('Successes before up'))
				])
			]),
			E('div', { 'class': 'hw-block', 'id': 'hw-blk-fo' }, [
				E('table', { 'class': 'table hw-form' }, [
					titleRow('hw-fo', String(c.failover) === '1', _('Switch traffic to a backup link when one goes down')),
					/* Что именно делает галка - строкой ПОД НЕЙ, но в таблице
					   ЗАГОЛОВКА, а не в hw-fb-tbl: та прячется, когда галка
					   снята, и пояснение исчезало бы ровно в тот момент, когда
					   человек решает, включать ли. Цена незнания высокая: со
					   снятой галкой линк без интернета держит трафик, пока
					   кто-нибудь не вмешается руками. */
					row(E('span', { 'style': 'font-size:.85em;opacity:.7' },
						_('A link that has an address but no internet will not give the traffic up on its own - the watchdog moves the route past it, and brings it back when the link recovers. Route metrics in the settings stay untouched. On by default.')), '')
				]),
				E('table', { 'id': 'hw-fb-tbl', 'class': 'table hw-form' }, [
					row(E('select', { 'id': 'hw-fb', 'class': 'cbi-input-select' }, [
						E('option', { 'value': 'restore', 'selected': c.failback !== 'demote' ? '' : null }, _('Return its priority')),
						E('option', { 'value': 'demote', 'selected': c.failback === 'demote' ? '' : null }, _('Keep it last'))
					]), _('When a link recovers'))
				])
			]),
			healRows.length ? E('div', { 'class': 'hw-block', 'id': 'hw-blk-heal' }, [
				E('table', { 'class': 'table hw-form' }, [
					titleRow('hw-heal-en', String(c.healing) === '1', _('Heal a modem while its link is down'))
				]),
				E('table', { 'id': 'hw-heal-tbl', 'class': 'table hw-form' }, healRows)
			]) : '',
			/* Лечение Wi-Fi - НЕЗАВИСИМЫЙ блок (решение владельца): у него своя
			   фиксированная лестница (переподключить -> network reload), и от
			   модемного мастера он не зависит ни в UI, ни в бэкенде. */
			/* Показываем блок и тогда, когда аплинка wifi сейчас нет, но лечение
			   Wi-Fi УЖЕ включено: иначе включённая настройка становится
			   невидимой и невыключаемой ровно в тот момент, когда линк лежит
			   (о ней и был вопрос пользователя). */
			(uplinks.some(function(o) { return o.type === 'wifi'; }) || String(c.heal_wifi) === '1') ? E('div', { 'class': 'hw-block', 'id': 'hw-blk-wifi' }, [
				E('table', { 'class': 'table hw-form' }, [
					titleRow('hw-heal-wifi', String(c.heal_wifi) === '1', _('Heal the Wi-Fi uplink while it is down'))
				])
			]) : ''
		]);
		/* ИЕРАРХИЯ НАСТРОЕК - ГЛАЗАМИ. «Включить слежение» - фундамент: без
		   него не работает ничего, поэтому выключенное слежение гасит ВСЮ
		   остальную форму. «Переключать трафик» - действие поверх слежения,
		   и селект «Когда линк оживает» подчинён уже ему. Вопрос владельца
		   «а это не одно и то же?» родился из того, что зависимость никак
		   не показывалась. */
		var deps = function() {
			var en = node.querySelector('#hw-en');
			var fo = node.querySelector('#hw-fo');
			var he = node.querySelector('#hw-heal-en');
			if (!en || !fo) { return; }
			/* слежение выключено - остаётся ТОЛЬКО его галка: параметры блока
			   и оба нижних блока исчезают целиком */
			var show = function(id, on) {
				var el = node.querySelector('#' + id);
				if (el) { el.style.display = on ? '' : 'none'; }
			};
			show('hw-blk-watch', en.checked);
			show('hw-blk-fo', en.checked);
			show('hw-blk-heal', en.checked);
			show('hw-blk-wifi', en.checked);
			/* настройка возврата без включённого переключения не имеет смысла */
			show('hw-fb-tbl', en.checked && fo.checked);
			/* потолки по модемам - только при включённом лечении */
			show('hw-heal-tbl', en.checked && !!(he && he.checked));
		};
		[ 'hw-en', 'hw-fo', 'hw-heal-en' ].forEach(function(id) {
			var el = node.querySelector('#' + id);
			if (el) { el.addEventListener('change', deps); }
		});
		deps();
		var save = function() {
			var v = function(id) { return (node.querySelector('#' + id).value || '').trim(); };
			var num = function(id, dflt) { var n = parseInt(v(id), 10); return (isNaN(n) || n < 1) ? dflt : n; };
			/* targets: из DynamicList; только адреса/имена без кавычек и
			   прочего - строки уйдут в shell-верб одним аргументом */
			var tgt = (tgtDl.getValue() || []).map(function(t) {
				return String(t).replace(/[^A-Za-z0-9.:-]/g, '');
			}).filter(function(t) { return t; }).join(' ');
			var _heEl = node.querySelector('#hw-heal-en');
			return fs.exec(HBIN, [ 'setconf',
				'enabled=' + (node.querySelector('#hw-en').checked ? '1' : '0'),
				'failover=' + (node.querySelector('#hw-fo').checked ? '1' : '0'),
				/* без модемов галки лечения в форме нет - не затираем
				   сохранённое значение нулём */
				'healing=' + (_heEl ? (_heEl.checked ? '1' : '0') : (String(c.healing) === '1' ? '1' : '0')),
				'heal_wifi=' + (function() {
					var w = node.querySelector('#hw-heal-wifi');
					return w ? (w.checked ? '1' : '0') : (String(c.heal_wifi) === '1' ? '1' : '0');
				})(),
				'failback=' + v('hw-fb'),
				'interval=' + num('hw-int', 30),
				'targets=' + (tgt || '77.88.8.8 1.1.1.1'),
				'fail_n=' + num('hw-fail', 3),
				'ok_n=' + num('hw-ok', 5)
			]).then(function() {
				var heals = [];
				node.querySelectorAll('select[id^="hw-heal-"]').forEach(function(sel) {
					heals.push(fs.exec(HBIN, [ 'setheal', sel.getAttribute('data-iface'), sel.value ]));
				});
				return Promise.all(heals);
			}).then(function() {
				/* первый круг - сразу, чтобы точки появились без ожидания
				   тика sessionwatch (фоном, страницу не держим) */
				fs.exec(HBIN, [ 'once' ]);
			});
		};
		if (opts && opts.autosave) {
			var _as_t = null;
			var _as_kick = function() {
				if (_as_t) { window.clearTimeout(_as_t); }
				_as_t = window.setTimeout(function() {
					_as_t = null;
					save().then(function() {
						if (opts.onsaved) { opts.onsaved(); }
					});
				}, 500);
			};
			/* 'change' всплывает от галочек, селектов и полей (поля - по
			   уходу фокуса, не на каждую букву); у списка адресов своё
			   событие cbi-dynlist-change (bubbles: true). */
			node.addEventListener('change', _as_kick);
			node.addEventListener('cbi-dynlist-change', _as_kick);
		}
		return { node: node, save: save };
	}
});
