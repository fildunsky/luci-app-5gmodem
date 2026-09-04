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

	ЭЛЕМЕНТЫ - ТОЛЬКО СТАНДАРТНЫЕ (решение владельца 03.09.2026). Раньше форма
	собиралась голыми <input type=checkbox>/<select> в таблице со своим CSS:
	в темах они выглядели чужими - не тот вид галочки, не тот отступ, не та
	ширина. Теперь каждое поле - виджет luci-base (ui.Checkbox, ui.Dropdown,
	ui.Textfield, ui.DynamicList) в обычной строке .cbi-value, как в любой
	странице LuCI: вид и поведение достаются от темы даром.
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
		/* Строка формы - ровно та же разметка, что у form.js: подпись слева,
		   поле справа, пояснение под полем. */
		var row = function(title, widget, descr) {
			var field = E('div', { 'class': 'cbi-value-field' }, [ widget ]);
			if (descr) {
				field.appendChild(E('div', { 'class': 'cbi-value-description' }, descr));
			}
			/* Строка-галочка: пояснение справа от неё, а не под ней (класс
			   разбирает modem.css). Узнаём по самому виджету - у ui.Checkbox
			   корень с классом cbi-checkbox. */
			var isFlag = widget && widget.classList
				&& widget.classList.contains('cbi-checkbox');
			return E('div', { 'class': 'cbi-value' + (isFlag ? ' tg-flag' : '') }, [
				E('label', { 'class': 'cbi-value-title' }, title),
				field
			]);
		};
		var cb = function(on, id) {
			return new ui.Checkbox(on ? '1' : '0', { id: id });
		};
		var num = function(val, dflt, id) {
			return new ui.Textfield(String(val == null || val === '' ? dflt : val),
				{ id: id, datatype: 'uinteger' });
		};

		var wEn   = cb(String(c.enabled) === '1', 'hw-en');
		var wInt  = num(c.interval, 30, 'hw-int');
		var wFail = num(c.fail_n, 3, 'hw-fail');
		var wOk   = num(c.ok_n, 5, 'hw-ok');
		/* Адреса проверки - стандартным списком LuCI (ui.DynamicList): строка на
		   адрес, плюс/крестик, как у DNS-серверов в редактировании интерфейса.
		   Бэкенд хранит их одной строкой через пробел - конвертируем на краях. */
		var wTgt  = new ui.DynamicList((c.targets || '77.88.8.8 1.1.1.1').split(/ +/)
			.filter(function(t) { return t; }), null, { id: 'hw-tgt' });
		var wFo   = cb(String(c.failover) === '1', 'hw-fo');
		var wFb   = new ui.Dropdown(c.failback === 'demote' ? 'demote' : 'restore', {
			'restore': _('Return its priority'),
			'demote':  _('Keep it last')
		}, { id: 'hw-fb', sort: [ 'restore', 'demote' ] });
		/* Резерв «только вручную»: помеченный линк не получает трафик
		   автоматически - сторож держит его маршрут со штрафной метрикой,
		   пока пользователь сам не сделает его первым (клик по карточке).
		   Кейс: резервный Wi-Fi к смартфону, которого обычно нет в эфире.
		   Стандартная группа галочек в дропдауне вместо строки на
		   каждый линк: одна подпись, одно пояснение, привычный вид. */
		var manList = String(c.manual || '').split(/ +/).filter(function(t) { return t; });
		var manChoices = {};
		uplinks.forEach(function(o) {
			manChoices[o.iface] = (o.sub && o.sub !== o.iface) ? (o.sub + ' (' + o.iface + ')') : o.iface;
		});
		/* Множественный выбор - тем же ui.Dropdown, ровно как form.MultiValue.
		   (У ui.Select с widget:'checkbox' getValue() читает только радиокнопки
		   и на множественном выборе всегда отдаёт null - он тут не годится.) */
		var wMan = Object.keys(manChoices).length ? new ui.Dropdown(manList, manChoices, {
			id: 'hw-man', multiple: true, optional: true,
			select_placeholder: _('none'), display_items: 3, dropdown_items: -1
		}) : null;
		var wHeal = cb(String(c.healing) === '1', 'hw-heal-en');
		/* Лестница лечения - только для модемов: wan-порту и Wi-Fi-станции
		   переподключение/перезагрузка модуля не осмысленны. Потолок на модем:
		   ничего -> переподключить -> + модуль -> + питание USB. */
		var healSel = [];
		uplinks.filter(function(o) { return o.type === 'modem'; }).forEach(function(o) {
			/* Пустое значение = умолчание (переподключение + перезагрузка
			   модуля, см. heal_cap в health.sh); явное «не лечить» - отдельное
			   значение none, иначе его не отличить от «не выбирал вовсе». */
			var cur = (c.heal && c.heal[o.iface]) || '';
			healSel.push({ iface: o.iface, title: o.sub || o.iface,
				w: new ui.Dropdown(cur, {
					'':       _('Default (reconnect, then reboot the module)'),
					'none':   _('Do nothing'),
					'ifup':   _('Reconnect the interface'),
					'reboot': _('...plus reboot the module'),
					'power':  _('...plus USB power cycle')
				}, { id: 'hw-heal-' + o.iface, sort: [ '', 'none', 'ifup', 'reboot', 'power' ] })
			});
		});
		var wWifi = cb(String(c.heal_wifi) === '1', 'hw-heal-wifi');
		var hasWifi = uplinks.some(function(o) { return o.type === 'wifi'; }) || String(c.heal_wifi) === '1';

		var grpWatch = E('div', {}, [
			row(_('Check interval, s'), wInt.render()),
			row(_('Ping targets'), wTgt.render(),
				/* защита от самострела на операторах с белыми списками:
				   яндексовский адрес доступен и там, выкидывать его из
				   целей не стоит */
				_('If at least one target responds')),
			row(_('Failures before down'), wFail.render()),
			row(_('Successes before up'), wOk.render())
		]);
		var grpFb = E('div', {}, [
			row(_('When a link recovers'), wFb.render())
		].concat(wMan ? [ row(_('Use only manually'), wMan.render(),
			_('A link marked here never receives traffic automatically - to use it, make it first by clicking its card. Handy for a backup like Wi-Fi to your phone.')) ] : []));
		var grpFo = E('div', {}, [
			/* Что именно делает галка - пояснением ПОД НЕЙ, а не внутри
			   скрываемой части: та прячется, когда галка снята, и пояснение
			   исчезало бы ровно в тот момент, когда человек решает, включать
			   ли. Цена незнания высокая: со снятой галкой линк без интернета
			   держит трафик, пока кто-нибудь не вмешается руками. */
			row(_('Switch traffic to a backup link when one goes down'), wFo.render(),
				_('A link that has an address but no internet will not give the traffic up on its own - the watchdog moves the route past it, and brings it back when the link recovers. Route metrics in the settings stay untouched. On by default.')),
			grpFb
		]);
		var grpHealTbl = E('div', {}, healSel.map(function(h) { return row(h.title, h.w.render()); }));
		var grpHeal = healSel.length ? E('div', {}, [
			row(_('Heal a modem while its link is down'), wHeal.render()),
			grpHealTbl
		]) : null;
		/* Лечение Wi-Fi - НЕЗАВИСИМЫЙ блок (решение владельца): у него своя
		   фиксированная лестница (переподключить -> network reload), и от
		   модемного мастера он не зависит ни в UI, ни в бэкенде.
		   Показываем и тогда, когда аплинка wifi сейчас нет, но лечение Wi-Fi
		   УЖЕ включено: иначе включённая настройка становится невидимой и
		   невыключаемой ровно в тот момент, когда линк лежит. */
		var grpWifi = hasWifi ? E('div', {}, [
			row(_('Heal the Wi-Fi uplink while it is down'), wWifi.render())
		]) : null;

		var node = E('div', { 'class': 'hw-form' }, [
			row(_('Enable watching'), wEn.render()),
			grpWatch, grpFo
		].concat(grpHeal ? [ grpHeal ] : []).concat(grpWifi ? [ grpWifi ] : []));

		/* ИЕРАРХИЯ НАСТРОЕК - ГЛАЗАМИ. «Включить слежение» - фундамент: без
		   него не работает ничего, поэтому выключенное слежение гасит ВСЮ
		   остальную форму. «Переключать трафик» - действие поверх слежения,
		   и селект «Когда линк оживает» подчинён уже ему. Вопрос владельца
		   «а это не одно и то же?» родился из того, что зависимость никак
		   не показывалась. */
		var deps = function() {
			var en = wEn.isChecked();
			var show = function(el, on) { if (el) { el.style.display = on ? '' : 'none'; } };
			show(grpWatch, en);
			show(grpFo, en);
			show(grpHeal, en);
			show(grpWifi, en);
			/* настройка возврата без включённого переключения не имеет смысла */
			show(grpFb, en && wFo.isChecked());
			/* потолки по модемам - только при включённом лечении */
			show(grpHealTbl, en && wHeal.isChecked());
		};
		[ wEn.node, wFo.node, wHeal.node ].forEach(function(n) {
			if (n) { n.addEventListener('widget-change', deps); }
		});
		deps();

		var save = function() {
			var n = function(w, dflt) {
				var v = parseInt((w.getValue() || '').trim(), 10);
				return (isNaN(v) || v < 1) ? dflt : v;
			};
			/* targets: из DynamicList; только адреса/имена без кавычек и
			   прочего - строки уйдут в shell-верб одним аргументом */
			var tgt = (wTgt.getValue() || []).map(function(t) {
				return String(t).replace(/[^A-Za-z0-9.:-]/g, '');
			}).filter(function(t) { return t; }).join(' ');
			return fs.exec(HBIN, [ 'setconf',
				'enabled=' + (wEn.isChecked() ? '1' : '0'),
				'failover=' + (wFo.isChecked() ? '1' : '0'),
				/* без модемов галки лечения в форме нет - не затираем
				   сохранённое значение нулём */
				'healing=' + (healSel.length ? (wHeal.isChecked() ? '1' : '0') : (String(c.healing) === '1' ? '1' : '0')),
				'heal_wifi=' + (hasWifi ? (wWifi.isChecked() ? '1' : '0') : (String(c.heal_wifi) === '1' ? '1' : '0')),
				'failback=' + wFb.getValue(),
				'interval=' + n(wInt, 30),
				'targets=' + (tgt || '77.88.8.8 1.1.1.1'),
				'fail_n=' + n(wFail, 3),
				'ok_n=' + n(wOk, 5),
				'manual=' + (wMan ? L.toArray(wMan.getValue()).join(' ') : String(c.manual || ''))
			]).then(function() {
				return Promise.all(healSel.map(function(h) {
					return fs.exec(HBIN, [ 'setheal', h.iface, h.w.getValue() ]);
				}));
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
			/* Виджеты luci-base шлют своё widget-change (всплывает); у списка
			   адресов - собственное cbi-dynlist-change. Нативный change
			   оставляем для полей ввода. */
			node.addEventListener('change', _as_kick);
			node.addEventListener('widget-change', _as_kick);
			node.addEventListener('cbi-dynlist-change', _as_kick);
		}
		return { node: node, save: save };
	}
});
