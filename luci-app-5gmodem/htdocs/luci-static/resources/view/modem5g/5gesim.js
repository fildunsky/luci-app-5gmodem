'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require view.modem5g.modemtabs as modemtabs';

/*
	Отдельная вкладка «eSIM» — управление профилями eUICC активного модема
	через lpac (SGP.22). Бэкенд: /usr/share/5gmodem/esim.sh.

	Тут НЕТ фонового опроса метрик (в отличие от страницы «Сеть»), поэтому
	вызовы lpac не конкурируют за единственный логический канал eUICC — окно
	стабильнее. Обновление данных — по кнопке/после операций.

	Секция адаптивна:
	  - lpac не установлен / модем не AT-типа  -> пояснение;
	  - активна физическая SIM                  -> кнопка перехода на eSIM-слот;
	  - активен eSIM-слот                       -> EID/память, список профилей,
	                                               форма добавления по коду.
*/

var ESIM = '/usr/share/5gmodem/esim.sh';
var SLOT = '/usr/share/5gmodem/simslot.sh';

function esimExec(args) {
	return L.resolveDefault(fs.exec_direct(ESIM, args), '').then(function(out) {
		try { return JSON.parse(out) || {}; } catch (e) { return {}; }
	});
}
function slotExec(args) {
	return L.resolveDefault(fs.exec_direct(SLOT, args), '').then(function(out) {
		try { return JSON.parse(out) || {}; } catch (e) { return {}; }
	});
}
/* Ответ lpac - НЕ один JSON, а НЕСКОЛЬКО объектов построчно: поток
   {"type":"progress",...} и в конце итоговый {"type":"lpa",...}. Раньше код
   делал JSON.parse(res.stdout) на всём выводе - многострочный JSON невалиден,
   parse падал в catch, объект оставался {}, и lpaOk давал false. Отсюда ложный
   попап «Невозможно добавить профиль» при успешном добавлении и «операция не
   удалась» при успешной активации. Берём ПОСЛЕДНИЙ объект type:lpa (итог), а
   если его нет - последнюю валидную JSON-строку. */
function parseLpa(out) {
	var lines = String(out || '').split('\n');
	var lpa = null, anyJson = null, i, s, o;
	for (i = 0; i < lines.length; i++) {
		s = lines[i].trim();
		if (!s) { continue; }
		try { o = JSON.parse(s); } catch (e) { continue; }
		if (o && typeof o === 'object') {
			anyJson = o;
			if (o.type === 'lpa') { lpa = o; }
		}
	}
	return lpa || anyJson || {};
}
function lpaOk(j) { return !!(j && j.payload && j.payload.code === 0); }
function lpaMsg(j) { return (j && j.payload && j.payload.message) || '?'; }
// Текст ошибки для пользователя: payload.data несёт ПРИЧИНУ (для download —
// коды GSMA "8.1/6.1: Verification Failed", которые esim.sh достаёт из ответа
// SM-DP+), а payload.message — только ИМЯ упавшего шага (es9p_authenticate_client).
// Показываем причину первой, шаг в скобках для диагностики. Если причины нет
// (data пуст/не строка) — отдаём имя шага, как раньше.
function lpaFail(j) {
	var p = (j && j.payload) || {};
	var step = p.message || '?';
	var reason = (typeof p.data === 'string') ? p.data.trim() : '';
	return reason ? (reason + ' (' + step + ')') : step;
}

// --- Оформление модалки добавления профиля (иконка SIM + спиннер + текст) -----
// Стили инжектим один раз в <head>. Свой спиннер (не .spinning темы: тот жёстко
// прижат влево через position:absolute+padding). Ширину модалки фиксирует тема
// (proton: 90%/max 800px), поэтому контент тянем на ВСЮ ширину (.esim-modal
// width:100%) - одинаково на всех экранах, без пустоты справа. Строка выровнена
// влево: иконка и спиннер стоят на месте, а меняющийся текст-шаг занимает остаток
// и переносится внутри своей колонки - иконку ему не сдвинуть.
function esimUiCss() {}   /* стили в modem.css */

// Иконка SIM-карты (наш ассет icons/5gmodem/csim_iface.svg). Через <img> - иконка с
// фиксированным цветом (#0095FF), тонировать не нужно.
function esimSimIcon(cls) {
	return E('img', {
		'class': cls || 'esim-simicon',
		'src': L.resource('icons/5gmodem/csim_iface.svg'),
		'alt': ''
	});
}

// --- Перевод кодов ошибок GSMA (SGP.22) на человеческий язык -------------------
// esim.sh кладёт в payload.data строку вида "8.2.6/3.8 Matching ID: Refused"
// (subjectCode/reasonCode из ответа SM-DP+). Пользователю коды не говорят ничего;
// показываем понятное объяснение (как это делает телефон). Известные пары -
// точным текстом; иначе собираем из частей «что» + «почему»; если код неизвестен
// или data - локальная ошибка lpac без кодов, отдаём как есть.
var GSMA_COMBO = {
	'8.1.1/3.8': _('This eSIM profile has already been downloaded to a device and cannot be downloaded again. Ask your operator for a new activation code.'),
	'8.2.6/3.8': _('This activation (QR) code has already been used or is no longer valid. Ask your operator for a new one.'),
	'8.2.5/3.8': _('A confirmation code is required for this profile, or the one entered is wrong.'),
	'8.2.1/2.2': _('A profile with this ICCID is already installed on the eSIM.'),
	'8.1/6.1':   _('The operator could not verify this eSIM chip (eUICC verification failed).'),
	'8.8.5/3.8': _('The operator refused to release this profile.'),
	'4.8/1.2':   _('Not enough free memory on the eSIM to install the profile. Delete an unused profile and try again.'),
	'9.4/10.1':  _('The operator has run out of free profiles in this test pool — nothing to hand out. This is on the operator side; try another code or ask them.')
};
var GSMA_SUBJECT = {
	'8.1':   _('eSIM chip'),
	'8.1.1': _('profile'),
	'8.2.1': _('ICCID'),
	'8.2.5': _('confirmation code'),
	'8.2.6': _('activation code'),
	'8.8':   _('profile package')
};
var GSMA_REASON = {
	'1.2': _('value not allowed'),
	'2.1': _('invalid association'),
	'2.2': _('already exists'),
	'3.1': _('unavailable'),
	'3.7': _('certificate expired'),
	'3.8': _('refused or already used'),
	'4.2': _('expired (time limit reached)'),
	'4.8': _('not enough memory'),
	'6.1': _('verification failed'),
	'6.3': _('expired'),
	'6.4': _('invalid signature')
};
function gsmaHuman(dataStr) {
	var s = String(dataStr || '').trim();
	var m = s.match(/^(\d+(?:\.\d+)*)\/(\d+(?:\.\d+)*)/);
	if (!m) { return s; }            // без кодов (локальная ошибка lpac) — как есть
	var key = m[1] + '/' + m[2];
	if (GSMA_COMBO[key]) { return GSMA_COMBO[key]; }
	var subj = GSMA_SUBJECT[m[1]], reas = GSMA_REASON[m[2]];
	if (reas) { return subj ? (subj.charAt(0).toUpperCase() + subj.slice(1) + ': ' + reas) : reas; }
	return s;                        // код незнаком — оставляем техническую строку
}

// Человеческий текст ошибки загрузки для модалки. Сначала пробуем коды GSMA
// (ошибки от SM-DP+). Если их нет - это ЛОКАЛЬНАЯ ошибка eUICC/lpac: чаще всего
// провал на этапе установки пакета профиля (es10b_load/prepare_*), у ST4SIM это
// нехватка рабочей (volatile) памяти под конкретный профиль. Даём понятный совет,
// а не сырое "unknown,unknown". step = payload.message, raw = payload.data.
function esimFailHuman(step, raw) {
	var s = String(raw || '').trim();
	if (/^\d+(?:\.\d+)*\/\d+(?:\.\d+)*/.test(s)) { return gsmaHuman(s); }
	/* «ICCID уже есть на eUICC» - НЕ нехватка памяти, а признак того, что профиль
	   уже записан (предыдущая попытка дошла до чипа, а ответ до нас не добрался).
	   Бэкенд такой ответ теперь считает успехом, но сообщение оставляем: чип мог
	   ответить так и на профиль, установленный когда-то раньше. */
	if (/iccid_already_exists/i.test(s)) {
		return _('This profile is already installed on the eSIM — look for it in the list below.');
	}
	/* Отказ ИМЕННО по памяти чип называет прямо. Раньше под «нехватку памяти»
	   подгонялся любой невнятный сбой установки, включая unknown - человека это
	   уводило в сторону (он шёл искать «слишком большой профиль», хотя проблема
	   была в срыве длинного APDU и лечилась повтором). */
	if (/not_enough_memory|no_?memory|insufficient/i.test(s)) {
		return _('Not enough memory on the eSIM chip for this profile. Delete an unused profile and try again.');
	}
	if (/load_bound_profile_package|prepare_download/.test(String(step || '')) ||
	    /unknown/i.test(s)) {
		return _('The eSIM chip did not confirm the installation. This modem loses long commands from time to time, so a repeat usually helps. Check the profile list first — the profile may already be installed.');
	}
	return s || _('The download did not complete. See the log below for details.');
}

function notify(ok, msgOk, msgFail) {
	var m = ok ? msgOk : msgFail;
	if (ui.addTimeLimitedNotification) {
		ui.addTimeLimitedNotification(null, E('p', m), 6000, ok ? 'info' : 'error');
	} else {
		ui.addNotification(null, E('p', m), ok ? 'info' : 'error');
	}
}

/* После включения eSIM-профиля симка фактически сменилась - значит и APN мог
   стать другим. Ведём себя ТАК ЖЕ, как при смене физической SIM, и через ТОТ ЖЕ
   серверный код (modemswitch.sh), а не через локальную копию таблицы APN:
   она уже однажды разошлась с оригиналом (см. 5gdebug.js) и не знала про MVNO.

   Режим APN у модема решает всё:
     - автоматически -> autoapn подберёт и ПРИМЕНИТ сам (учтёт код из IMSI для
       MVNO и роуминг), нам остаётся показать короткое уведомление;
     - вручную -> ничего не трогаем, только подсказываем найденный APN со
       ссылкой в «Настройки модема». */
function proposeApnAfterEnable() {
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
		var sec = p ? ('m_' + String(p).replace(/[^A-Za-z0-9]/g, '_')) : '';
		var iface = (sec && uci.get('5gmodem', sec, 'network'))
			|| uci.get('5gmodem', '@5gmodem[0]', 'network') || 'modem';
		var manual = sec && uci.get('5gmodem', sec, 'apn_mode') === 'manual';

		if (!manual) {
			/* Автоматический режим: применяем сразу. autoapn сам ничего не
			   сделает в роуминге и на неизвестном операторе - молчит, значит
			   безопасно. */
			fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autoapn', iface ]);
			ui.addNotification(null, E('p', {},
				_('eSIM profile switched - checking and updating the APN automatically')),
				'info');
			return;
		}

		/* Ручной режим: подбор берём у сервера (тот же код, что автонастройка),
		   а не из локальной таблицы. Предлагаем, только если найденный APN
		   отличается от того, что стоит в интерфейсе. */
		return Promise.all([
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'apnfor' ]), ''),
			L.resolveDefault(uci.load('network'))
		]).then(function(r) {
			var want = String(r[0] || '').trim();
			if (!want) { return; }
			var cur = String(uci.get('network', iface, 'apn') || '').trim();
			if (cur.toLowerCase() === want.toLowerCase()) { return; }
			ui.addNotification(null, E('p', {}, [
				_('APN for the new operator may differ. Recommended: "%s" (current: "%s"). You are in manual APN mode - open Modem Settings to apply it.')
					.format(want, cur || '\u2014'), ' ',
				E('a', {
					'class': 'btn cbi-button cbi-button-action',
					'href': L.url('admin', 'modem', '5gmodem', 'diagnostics')
				}, _('Open Modem Settings'))
			]), 'warning');
		});
	});
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		/* РАНЬШЕ здесь была СИНХРОННАЯ status-probe: CCHO-проба eUICC занимает
		   секунды (FM350), и всё это время LuCI крутил спиннер на ПУСТОЙ
		   странице. Теперь load() мгновенный: status-cached отдаёт последний
		   вердикт пробы из кэша (или unknown), slot status - липкий кэш.
		   Настоящая проба, если нужна, идёт ФОНОМ уже на видимой странице. */
		return Promise.all([ esimExec([ 'status-cached' ]), slotExec([ 'status' ]) ]);
	},

	render: function(res) {
		modemtabs.attach();
		var st = res[0] || {}, slot = res[1] || {};

		var body = E('div', { 'id': 'esim-body' });
		var self = this;

		if (st.available == null) {
			/* Вердикта в кэше нет (первое открытие для этого модема) - каркас
			   страницы уже виден, проба крутится ВНУТРИ блока. */
			body.appendChild(E('p', { 'class': 'spinning', 'id': 'esim-probing' },
				_('Checking eSIM support…')));
			esimExec([ 'status-probe' ]).then(function(st2) {
				self._fillBody(body, st2 || {}, slot);
			});
		} else {
			self._fillBody(body, st, slot);
			/* Кэш мог устареть (слот переключили в обход этой страницы).
			   Перепроверяем фоном ТОЛЬКО когда по кэшу работа с eUICC не идёт:
			   при активном eSIM сразу стартует reload/dump, и параллельная
			   CCHO-проба дралась бы с ним за логический канал eUICC. */
			if (!st.available || !st.active) {
				esimExec([ 'status-probe' ]).then(function(st2) {
					if (st2 && st2.available != null &&
					    (!!st2.available !== !!st.available || !!st2.active !== !!st.active)) {
						self._fillBody(body, st2, slot);
					}
				});
			}
		}

		return this._shell(body);
	},

	/* Наполнение тела страницы по вердикту (available/active). Вынесено из
	   render, чтобы вызываться и сразу (кэш), и после фоновой пробы. */
	_fillBody: function(body, st, slot) {
		var self = this;
		while (body.firstChild) { body.removeChild(body.firstChild); }

		if (!st.available) {
			// Конкретная причина недоступности (backend отдаёт st.reason), чтобы не
			// гадать «lpac нет ИЛИ не АТ-модем». Для 'noeuicc' сразу просим лог.
			var msg;
			if (st.reason === 'nolpac') {
				msg = _('eSIM management needs the lpac package, which is not installed. Install the lpac build for your platform - see the app README.');
			} else if (st.reason === 'mm_owns') {
				msg = _('This modem is managed by ModemManager, and its control channel belongs to MM. Opening a second eSIM session on the same channel can crash the modem firmware (seen live on T99W175 - the modem reboots). To manage eSIM, enable "Hide from ModemManager" in the modem settings (or switch the interface protocol), then come back here.');
			} else if (st.reason === 'modemmanager') {
				msg = _('This modem is on the ModemManager protocol, where eSIM over AT commands is not available. Switch the modem interface to the fibocom / MBIM / QMI protocol to manage eSIM.');
			} else if (st.reason === 'uplink') {
				/* Канал занят поднятым соединением - чип цел, просто сейчас
				   недоступен. Отдельная причина нужна, чтобы не пугать человека
				   советом «сообщите vid:pid»: с модемом всё в порядке. */
				msg = _('The modem control channel is busy with the active connection, so the eSIM chip cannot be read right now. Disconnect the modem interface (or switch to another SIM) to manage profiles.');
			} else if (st.reason === 'slot') {
				/* Активна физическая SIM - чип по определению недоступен.
				   Отдельная причина нужна, чтобы не пугать советом «сообщите
				   vid:pid»: модем поддерживается, просто занят другой картой. */
				msg = _('The physical SIM slot is active, so the eSIM chip cannot be read. Switch to the eSIM slot to manage profiles.');
			} else if (st.reason === 'noeuicc') {
				msg = _('No eSIM chip (eUICC) answered on this modem. If you are sure it has one, it may be in a USB composition this app does not talk to yet - please report your modem model and its USB ID (vid:pid) so we can add support.');
			} else {
				msg = _('eSIM management is unavailable: the lpac package is not installed, or the active modem is not an AT-type modem');
			}
			/* КНОПКА ПЕРВОЙ, ПОЯСНЕНИЕ - ЗА НЕЙ, В ОДНУ СТРОКУ.
			   Действие важнее объяснения: человек, который уже понял причину,
			   не должен искать кнопку под абзацем текста. Ряд собирается
			   флексом (.tgesim-actionrow) и на узком экране переносится сам.
			   Причины без действия (нет lpac, чужая композиция) как и раньше
			   показывают один абзац. */
			var _btn = null;
			if (st.reason === 'slot') {
				/* Слот физической SIM активен - eUICC недостижим по определению.
				   Кнопка переключает слот; модем переперечисляется, поэтому
				   страница перезагружается с задержкой. */
				var esimId2 = null;
				(slot.slots || []).forEach(function(s) { if (s.label == 'eSIM') { esimId2 = s.id; } });
				if (esimId2 != null) {
					_btn = E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ev.preventDefault();
							ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching to the eSIM slot...')));
							fs.exec(SLOT, [ 'set', String(esimId2) ]).then(function() {
								window.setTimeout(function() { location.reload(); }, 45000);
							}).catch(function() { ui.hideModal(); });
						}
					}, _('Switch to the eSIM slot'));
				}
			}
			else if (st.reason === 'uplink') {
				/* ЗАНЯТЫЙ КАНАЛ - ЭТО ДЕЙСТВИЕ, А НЕ ПРИГОВОР. У модемов, где
				   eUICC живёт только за MBIM, канал управления один, и пока
				   поднято соединение, читать чип нельзя. Предлагаем освободить
				   модем за человека, честно предупредив об обрыве связи;
				   интерфейс поднимается обратно сам (trap в esim.sh). */
				_btn = E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) {
						ev.preventDefault();
						if (!confirm(_('The modem connection will be dropped for about a minute while the eSIM chip is read, then restored. Continue?'))) { return; }
						ui.showModal(null, E('p', { 'class': 'spinning' },
							_('Freeing the modem and reading the eSIM chip...')));
						esimExec([ 'dump-free' ]).then(function(d) {
							ui.hideModal();
							applyDump(d);
						}).catch(function() { ui.hideModal(); });
					}
				}, _('Free the modem and read eSIM'));
			}
			var _descr = E('p', { 'class': 'cbi-section-descr' }, msg);
			if (_btn) {
				body.appendChild(E('div', { 'class': 'tgesim-actionrow' }, [ _btn, _descr ]));
			} else {
				body.appendChild(_descr);
			}
		}
		else if (!st.active) {
			// найти id eSIM-слота (по метке) для кнопки перехода
			var esimId = null;
			(slot.slots || []).forEach(function(s) { if (s.label == 'eSIM') { esimId = s.id; } });
			body.appendChild(E('p', { 'class': 'cbi-section-descr' },
				_('The physical SIM is active now. Switch to the eSIM slot to manage eSIM profiles.')));
			if (esimId != null) {
				body.appendChild(E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) {
						ev.preventDefault();
						ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching to the eSIM slot...')));
						fs.exec(SLOT, [ 'set', String(esimId) ]).then(function() {
							// модем переперечисляется ~30-60 c, затем перезагрузим страницу
							window.setTimeout(function() { location.reload(); }, 45000);
						}).catch(function() { ui.hideModal(); });
					}
				}, [ _('Switch to eSIM slot') ]));
			}
		}
		else {
			// активен eSIM-слот -> полноценное управление
			body.appendChild(E('div', { 'class': 'esim-metarow' }, [
				E('div', { 'class': 'esim-meta', 'id': 'esim-meta' }, [ E('em', _('Reading eUICC...')) ]),
				E('button', {
					'class': 'btn cbi-button esim-refresh',
					/* Обновить рядом с EID справа. Без спиннера на кнопке (решение
					   владельца): обратную связь даёт пометка «обновляется» у EID. */
					'click': function(ev) { ev.preventDefault(); self.reload(); }
				}, [ _('Refresh') ]),
			]));
			body.appendChild(E('table', { 'class': 'table', 'id': 'esim-profiles' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, [ _('Operator') ]),
					E('th', { 'class': 'th left' }, [ _('Profile') ]),
					E('th', { 'class': 'th left' }, [ 'ICCID' ]),
					E('th', { 'class': 'th' }, [ _('Status') ]),
					E('th', { 'class': 'th' }, [ '' ]),
				]),
			]));
				// Секция «Уведомления» (SGP.22): pending-нотификации о добавлении/включении/
				// удалении, которые надо дослать на SM-DP+. Обычно пусто (flush шлёт авто);
				// показывается, только если что-то зависло. Наполняет reload.
			body.appendChild(E('div', { 'id': 'esim-notif', 'style': 'display:none' }));
			body.appendChild(E('div', { 'class': 'esim-dl' }, [
				// Кнопка «загрузить QR»: открывает выбор картинки, распознаёт код прямо
				// в браузере (jsQR) и вставляет текст в поле ниже.
				E('button', {
					'class': 'btn cbi-button esim-qr-btn',
					'title': _('Load a QR code image and read the activation code from it'),
					'click': function(ev) {
						ev.preventDefault();
						var f = document.getElementById('esim-qr-file');
						if (f) { f.click(); }
					}
				}, [ E('img', { 'src': L.resource('icons/5gmodem/cqr.svg'), 'alt': _('QR') }) ]),
				E('input', {
					'type': 'file', 'id': 'esim-qr-file', 'accept': 'image/*',
					'style': 'display:none',
					'change': function(ev) { self._decodeQR(ev.target.files && ev.target.files[0]); }
				}),
				E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'id': 'esim-code',
					'placeholder': 'LPA:1$rsp.example.com$XXXX-XXXX'
				}),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { ev.preventDefault(); self.download(); }
				}, [ _('Add eSIM profile') ]),
			]));
			/* МГНОВЕННЫЙ показ последнего дампа из кэша роутера (dump-cached,
			   ~20 мс): список профилей виден и кликабелен сразу при возврате
			   на вкладку. Живой dump (reload ниже) освежит его следом.
			   Операции (enable/delete/download) инвалидируют кэш на бэкенде,
			   так что устаревший список после них сюда не попадёт. */
			esimExec([ 'dump-cached' ]).then(function(d) { applyDump(d); });
			// первичная загрузка данных eUICC
			window.setTimeout(function() { self.reload(); }, 300);
		}
	},

	/* Каркас страницы: стиль, заголовок, описание, тело, настройки. Рисуется
	   сразу при render - тело (body) наполняется отдельно (_fillBody). */
	_shell: function(body) {
		return E('div', { 'class': 'cbi-map' }, [
			/* id нужен оверлею операций (modemtabs.setBusy('#esim-section')):
			   селектор '.cbi-section' брал ПЕРВУЮ секцию документа - на части
			   тем это не наш блок. */
			E('div', { 'class': 'cbi-section tgesim', 'id': 'esim-section' }, [
				E('h3', [ 'eSIM' ]),
				body,
				this.renderSettings(),
			]),
		]);
	},

	// Свёрнутые настройки: выбор транспорта ES9+.
	// Зачем выбор: lpac ходит к SM-DP+ своим curl, а libcurl в OpenWrt обычно
	// собран с mbedTLS, который спотыкается о critical-расширения в сертификатах
	// GSMA CI - часть SM-DP+ (напр. rsp-eu.redteamobile.com) тогда недоступна
	// вовсе ("HTTP transport failed" на первом же шаге). Мост гоняет ES9+ через
	// wget/OpenSSL, которому такие цепочки по зубам, и вдобавок реально проверяет
	// сертификат (штатный curl-бэкенд lpac проверку отключает).
	renderSettings: function() {
		var cur = String(uci.get('5gmodem', '@5gmodem[0]', 'esim_http') || 'auto');
		var sel = E('select', { 'class': 'cbi-input-select', 'id': 'esim-http-sel' }, [
			E('option', { 'value': 'auto'   }, [ _('Auto (recommended)') ]),
			E('option', { 'value': 'bridge' }, [ _('wget / OpenSSL bridge') ]),
			E('option', { 'value': 'curl'   }, [ _('lpac built-in curl') ]),
		]);
		sel.value = cur;

		// Транспорт APDU к eUICC. Auto: серийные модемы -> AT, mbim/qmi -> тот же
		// канал cdc-wdm. Для Qualcomm SDX55 (T99W175/MV31-W) eUICC доступен только
		// по QMI/MBIM, не по AT - там нужен qmi/mbim. Ручной выбор перебивает auto.
		var apduCur = String(uci.get('5gmodem', '@5gmodem[0]', 'esim_apdu') || 'auto');
		var apduSel = E('select', { 'class': 'cbi-input-select', 'id': 'esim-apdu-sel' }, [
			E('option', { 'value': 'auto' }, [ _('Auto (recommended)') ]),
			E('option', { 'value': 'at'   }, [ _('AT (serial - FM350 etc.)') ]),
			E('option', { 'value': 'qmi'  }, [ _('QMI / libqmi (Qualcomm)') ]),
			E('option', { 'value': 'uqmi' }, [ _('QMI / uqmi CLI') ]),
			E('option', { 'value': 'mbim' }, [ _('MBIM') ]),
			E('option', { 'value': 'bridge' }, [ _('AT bridge (sms_tool)') ]),
		]);
		apduSel.value = apduCur;

		return E('details', { 'class': 'esim-set' }, [
			E('summary', {}, [ _('Settings') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Download transport (ES9+)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					sel,
					E('button', {
						'class': 'btn cbi-button cbi-button-save',
						'style': 'margin-left:8px',
						'click': ui.createHandlerFn(this, function() {
							// Коммит из бэкенда (esim.sh sethttp): uci.save()+uci.apply()
							// из формы дельту не коммитил - изменение зависало в
							// «Настройки/Изменения». sethttp делает set+commit сразу.
							// НЕ трогаем клиентский uci-кэш - иначе появится фантомная
							// «несохранённая» дельта; sel уже показывает выбранное.
							return fs.exec_direct(ESIM, [ 'sethttp', sel.value ]).then(function() {
								ui.addNotification(null,
									E('p', _('Download transport saved')), 'info');
							});
						})
					}, [ _('Save') ]),
					E('div', { 'class': 'cbi-value-description' },
						_('How lpac talks to the operator server (SM-DP+). "Auto" uses the bridge when available. The bridge reaches SM-DP+ servers that present GSMA CI certificates, which the built-in curl cannot handle on mbedTLS builds, and it verifies the certificate.')),
				]),
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('eUICC access (APDU)') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					apduSel,
					E('button', {
						'class': 'btn cbi-button cbi-button-save',
						'style': 'margin-left:8px',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec_direct(ESIM, [ 'setapdu', apduSel.value ]).then(function() {
								ui.addNotification(null,
									E('p', _('eUICC access saved')), 'info');
							});
						})
					}, [ _('Save') ]),
					E('div', { 'class': 'cbi-value-description' },
						_('How lpac reaches the eSIM chip. "Auto" picks AT for serial modems (FM350) and QMI/MBIM for modems driven over cdc-wdm. Set QMI/MBIM manually for Qualcomm modems (T99W175 / MV31-W / DW5930e) whose eUICC is not reachable over AT.')),
				]),
			]),
		]);
	},

	// перечитать eUICC (chip info + список профилей одним вызовом dump)
	/* ПОЛОСА ОЖИДАНИЯ ДЛЯ ЧТЕНИЯ eUICC.
	   Точную длительность предсказать нельзя: она зависит от чипа, транспорта и
	   от того, занят ли канал - от секунды до полуминуты. Зато можно честно
	   опереться на ПРОШЛЫЕ запуски: держим в localStorage последнюю удачную
	   длительность для этого модема и рисуем полосу как «прошло / ожидаемо».
	   Пока укладываемся в оценку - полоса растёт до 95%; если превысили, дальше
	   не врём: полоса замирает на 95% и подпись меняется на «дольше обычного».
	   Оценку сглаживаем пополам со старой, чтобы одиночная заминка не сбивала её. */
	_etaKey: function() {
		var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || 'x';
		return '5gm-esim-eta-' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	},
	_etaGet: function() {
		var v = 0;
		try { v = parseInt(window.localStorage.getItem(this._etaKey()), 10) || 0; } catch (e) {}
		/* Разумные границы: без истории считаем 12 c (типичное чтение по MBIM),
		   и не даём выродиться ни в мгновенную, ни в бесконечную. */
		if (!v || v < 1500) { v = 12000; }
		if (v > 90000) { v = 90000; }
		return v;
	},
	_etaPut: function(ms) {
		if (!(ms > 0)) { return; }
		var old = 0;
		try { old = parseInt(window.localStorage.getItem(this._etaKey()), 10) || 0; } catch (e) {}
		var v = old ? Math.round((old + ms) / 2) : ms;
		try { window.localStorage.setItem(this._etaKey(), String(v)); } catch (e) {}
	},
	_waitBarStart: function(host) {
		var self = this;
		self._waitBarStop();
		if (!host) { return; }
		var eta = self._etaGet(), t0 = Date.now();
		var bar = E('div', { 'class': 'esim-wait' }, [
			E('div', { 'class': 'esim-wait-fill' }),
			E('span', { 'class': 'esim-wait-txt' }, '')
		]);
		host.appendChild(bar);
		var fill = bar.querySelector('.esim-wait-fill');
		var txt = bar.querySelector('.esim-wait-txt');
		self._waitT0 = t0;
		self._waitTimer = window.setInterval(function() {
			if (!bar.isConnected) { self._waitBarStop(); return; }
			var el = Date.now() - t0;
			var pc = Math.min(95, Math.round(el / eta * 100));
			fill.style.width = pc + '%';
			if (el > eta) {
				bar.classList.add('esim-wait-over');
				txt.textContent = _('Taking longer than usual (%ds)').format(Math.round(el / 1000));
			} else {
				txt.textContent = _('Reading the eUICC, about %ds left')
					.format(Math.max(1, Math.round((eta - el) / 1000)));
			}
		}, 250);
	},
	_waitBarStop: function(ok) {
		if (this._waitTimer) { window.clearInterval(this._waitTimer); this._waitTimer = null; }
		if (ok && this._waitT0) { this._etaPut(Date.now() - this._waitT0); }
		this._waitT0 = null;
		var b = document.querySelector('.esim-wait');
		if (b && b.parentNode) { b.parentNode.removeChild(b); }
	},

	reload: function(tries) {
		var self = this;
		// строго число: если reload когда-нибудь повесят прямо на 'click', сюда
		// прилетит Event - он truthy, и ретраи молча выключились бы.
		tries = (typeof tries === 'number') ? tries : 0;
		var meta = document.getElementById('esim-meta');
		/* Список уже показан из кэша (dump-cached)? Тогда НЕ затираем его
		   спиннером - обновление идёт фоном поверх рабочего списка. */
		var warm = !!document.querySelector('#esim-profiles .esim-row');
		// dump = chip info + список профилей через lpac по APDU-мосту: на FM350 это
		// ~10 с и дольше. Без явного предупреждения пустая строка выглядит как
		// «ничего не нашлось», и люди уходят со страницы, не дождавшись.
		if (meta && !warm) {
			meta.innerHTML = '';
			/* ПОЛОСА СВЕРХУ, ПОДПИСЬ ПОД НЕЙ - и без спиннера: он показывал ровно
			   то же самое («идёт работа»), только менее внятно, а рядом с полосой
			   с обратным отсчётом стал просто шумом. */
			self._waitBarStart(meta);
			meta.appendChild(E('div', { 'class': 'esim-wait-note' },
				_('Please wait, reading eUICC - updating the profile list can be slow')));
		}
		/* Поверх тёплого списка EID не затираем, но обратная связь нужна
		   (кнопка «Обновить» выглядела немой): МЕЛКАЯ пометка рядом с EID.
		   Строка та же, что в модалке пост-операций, - уже переведена.
		   applyDump при успехе перепишет meta целиком и снимет пометку сам. */
		if (meta && warm && !document.getElementById('esim-updating')) {
			self._waitBarStart(meta);
			meta.appendChild(E('div', {
				'id': 'esim-updating', 'class': 'esim-wait-note'
			}, _('Updating the profile list...')));
		}
		/* ВОЗВРАЩАЕМ Promise (сквозь ретраи): на нём держится спиннер кнопки
		   «Обновить» (ui.createHandlerFn). */
		return esimExec([ 'dump' ]).then(function(d) {
			var chip = d.chip || {}, profs = d.profiles || {};
			if (!lpaOk(chip) && !lpaOk(profs)) {
				// Первая попытка часто не проходит: eUICC мог остаться с занятыми
				// логическими каналами после предыдущей сессии (esim.sh чистит их
				// через AT+CCHC перед каждой операцией) или модем ещё поднимается
				// после CFUN. Не пугаем ошибкой сразу - молча повторяем.
				// потолок с запасом: после жёсткого ребута модема eUICC отвечает не сразу
				/* busy - замок esim.sh занят (чужой dump/операция): это не
				   отказ eUICC, освободится - ждём дольше (до ~минуты). Именно
				   busy стоял за «eUICC не отвечает» при открытии страницы после
				   прерванной сессии. */
				var _isBusy = (lpaMsg(chip) === 'busy' || lpaMsg(profs) === 'busy');
				if (tries < 5 || (_isBusy && tries < 15)) {
					return new Promise(function(resolve) {
						window.setTimeout(function() { resolve(self.reload(tries + 1)); }, 4000);
					});
				}
				self._waitBarStop();
				var _up = document.getElementById('esim-updating');
				if (_up) { _up.parentNode.removeChild(_up); }
				/* Тёплый список на экране рабочий - не пугаем ошибкой, eUICC
				   часто просто занята; без списка ошибка честно видна. */
				if (meta && !warm) {
					meta.innerHTML = '';
					var _m = lpaMsg(chip) || lpaMsg(profs);
					/* «uplink busy» - не поломка, а занятый канал: этой же eSIM
					   сейчас поднято соединение, и трогать канал управления
					   нельзя, иначе оборвём интернет. Объясняем словами и НЕ
					   красим в цвет ошибки. */
					if (_m === 'uplink busy') {
						meta.appendChild(E('span', { 'style': 'opacity:.8' },
							_('The modem control channel is busy with the active connection, so the profile list cannot be read right now. Disconnect the modem interface (or switch to another SIM) to manage profiles.')));
					} else {
						meta.appendChild(E('span', { 'style': 'color:#d95c5c' },
							_('eUICC is not responding (%s). Try Refresh in a few seconds.').format(_m)));
					}
				}
				return;
			}
			self._waitBarStop(true);
			applyDump(d);
			// Pending-нотификации SGP.22 (обычно пусто; секция появится, если есть).
			fetchNotifications().then(renderNotifications);
			// eUICC ответил - значит eSIM-слот активен. Обновляем видимость
			// вкладки eSIM без F5 (напр. сразу после переключения на eSIM-слот).
			if (modemtabs.refreshEsimTab) { modemtabs.refreshEsimTab(); }
		});
	},

	download: function() {
		var inp = document.getElementById('esim-code');
		var code = inp ? String(inp.value || '').trim() : '';
		if (!code) { return; }
		var self = this;
		// Профиль качается с сервера оператора (SM-DP+) по HTTPS. Без интернета
		// lpac молча висит до таймаута, а пользователь не понимает, почему. Сначала
		// проверяем доступ - и к SM-DP+ из кода, и к сети вообще.
		ui.showModal(_('Add eSIM profile'), [
			E('p', { 'class': 'spinning' }, _('Checking internet access...')),
		]);
		L.resolveDefault(fs.exec_direct(ESIM, [ 'netcheck', code ]), '').then(function(out) {
			var nc = {}; try { nc = JSON.parse(out || '{}'); } catch (e) {}
			if (!nc.net) {
				ui.hideModal();
				notify(false, null, _('No internet access. The router must be online to download an eSIM profile from the operator.'));
				return;
			}
			// Предупреждение про "SM-DP+ не ответил" УБРАНО намеренно. Проверка шла
			// встроенным curl, а он на серверах с сертификатами GSMA CI всегда даёт
			// 000 - то есть предупреждение срабатывало не на недоступность оператора,
			// а на несовпадение TLS-стека с тем, которым мы реально качаем (мост).
			// Ложная тревога, да ещё и под модалкой, где её не видно. Отсутствие
			// доступа в интернет (nc.net) проверяем по-прежнему - это осмысленно.
			/* МОДЕМ - ЕДИНСТВЕННЫЙ ИСТОЧНИК ИНТЕРНЕТА. Операция освобождает
			   модем (иначе к eUICC не пробиться), а загрузке нужен интернет
			   ПОСРЕДИ работы - на единственном аплинке она сломается
			   гарантированно, и раньше человек узнавал об этом только по
			   оборванной загрузке (жалоба 9esim/T99W175). Предупреждаем ДО
			   старта; «продолжить» оставляем - вдруг запасной канал появится
			   через секунды или пользователь знает, что делает. */
			if (String(nc.sole) === '1') {
				ui.hideModal();
				ui.showModal(_('Add eSIM profile'), [
					E('p', {}, _('This modem is currently the only internet source, and the download must take the modem offline to reach the eSIM chip. The profile download needs internet at that very moment, so it cannot finish. Connect the router to another source first (Wi-Fi, cable, or a phone hotspot) and try again.')),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, _('Cancel')),
						' ',
						E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': function() {
							ui.hideModal();
							self._doDownload(code, inp);
						} }, _('Download anyway'))
					])
				]);
				return;
			}
			self._doDownload(code, inp);
		});
	},

	// Человекочитаемые названия шагов SGP.22. Коды приходят от lpac как есть
	// (es9p_* - обмен с сервером оператора, es10b_* - работа с самой картой);
	// пользователю они ничего не говорят, а порядок шагов - говорит.
	_stepName: function(m) {
		var map = {
			'es10b_get_euicc_challenge_and_info': _('Reading the eUICC'),
			'es9p_initiate_authentication':       _('Contacting the operator server'),
			'es10b_authenticate_server':          _('Verifying the server'),
			'es9p_authenticate_client':           _('Authenticating the card'),
			'es8p_meatadata_parse':               _('Receiving profile details'),
			'es10b_prepare_download':             _('Preparing the download'),
			'es9p_get_bound_profile_package':     _('Downloading the profile'),
			'es10b_load_bound_profile_package':   _('Installing onto the card'),
			'es10b_cancel_session':               _('Closing the session'),
			'es9p_cancel_session':                _('Closing the server session'),
			'retry':                              _('Retrying'),
		};
		return map[m] || m;
	},

	// Опрос живого лога, пока крутится спиннер. Мост дописывает строки прогресса
	// по мере их прихода, поэтому ход операции виден сразу, а не вместе с итогом.
	_pollProgress: function(box) {
		var self = this;
		if (!self._dlActive) { return; }
		// НЕ ХОДИМ В БЭКЕНД, КОГДА СТРОКУ ШАГА НИКТО НЕ ВИДИТ: вкладка скрыта или
		// спиннер уже не в документе. Загрузка профиля живёт до одиннадцати минут,
		// и всё это время опрос раз в 1.2 c дёргал бы esim.sh в фоновой вкладке
		// впустую. Цикл не бросаем - вернулись на вкладку, и шаги снова видны.
		if (document.hidden || (box && box.isConnected === false)) {
			window.setTimeout(function() { self._pollProgress(box); }, 1200);
			return;
		}
		L.resolveDefault(fs.exec_direct(ESIM, [ 'progress' ]), '').then(function(out) {
			// Никогда не затираем накопленный лог служебным ответом: если бэкенд
			// ответил однострочным {"type":"lpa"...} (напр. "busy"), это НЕ лог
			// операции - именно так сохранённый файл однажды свёлся к одной строке.
			var s = out || '';
			if (s.indexOf('"type":"progress"') >= 0 || !self._dlLog) {
				if (s.indexOf('"message":"busy"') < 0) { self._dlLog = s; }
			}
			if (box && self._dlActive) {
				// ОДНА строка, сменяющая саму себя: шаги идут строго последовательно,
				// и список из них только растит модалку и уводит взгляд. Показываем
				// текущий шаг, предыдущие уже не важны - они есть в сохраняемом логе.
				var lines = self._dlLog.split('\n').filter(function(l) { return l.indexOf('"progress"') > 0; });
				var last = lines[lines.length - 1];
				/* НОМЕР ПОПЫТКИ - ПОСТОЯННЫМ ПРЕФИКСОМ, а не мельком.
				   На qmi/mbim/uqmi загрузка повторяется до пяти раз (длинные APDU
				   срываются без внятной причины), и без этого человек видел, как
				   одни и те же шаги идут по кругу, и не понимал, зависло оно или
				   так задумано. Считаем retry-строки в логе: их количество и есть
				   номер текущего круга. */
				var rt = self._dlLog.split('\n').filter(function(l) {
					return l.indexOf('"message":"retry"') > 0;
				});
				var att = rt.length ? rt[rt.length - 1].match(/"data":"(\d+)\/(\d+)"/) : null;
				if (last) {
					var m = last.match(/"message":"([^"]+)"/);
					var d = last.match(/"serviceProviderName":"([^"]+)"/);
					var t = m ? self._stepName(m[1]) : '';
					if (t) {
						var txt = (d ? (t + ' — ' + d[1]) : t) + '…';
						if (att) { txt = _('Attempt %s of %s').format(att[1], att[2]) + ' · ' + txt; }
						box.textContent = txt;
					}
				}
			}
			if (self._dlActive) { window.setTimeout(function() { self._pollProgress(box); }, 1200); }
		});
	},

	// Выгрузка лога файлом - чтобы пользователь мог прислать его для разбора.
	_saveLog: function() {
		var blob = new Blob([ this._dlLog || '' ], { type: 'text/plain' });
		var a = E('a', {
			'href': URL.createObjectURL(blob),
			'download': 'esim-download-' + Math.floor(Date.now() / 1000) + '.log'
		});
		document.body.appendChild(a); a.click();
		window.setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
	},

	// Ленивая загрузка jsQR (256 KB) - тянем ТОЛЬКО когда пользователь реально
	// жмёт кнопку QR, чтобы не грузить декодер на каждом заходе. jsQR - UMD: если
	// в глобале есть AMD-define, он зарегистрируется как модуль вместо window.jsQR,
	// поэтому на время загрузки прячем define и заставляем UMD уйти в глобал-ветку.
	_loadJsQR: function() {
		if (window.jsQR) { return Promise.resolve(window.jsQR); }
		if (this._jsqrPromise) { return this._jsqrPromise; }
		this._jsqrPromise = new Promise(function(resolve) {
			var saved = window.define;
			try { window.define = undefined; } catch (e) {}
			var restore = function() { try { window.define = saved; } catch (e) {} };
			var s = document.createElement('script');
			s.src = L.resource('5gmodem/jsqr.js');
			s.onload = function() { restore(); resolve(window.jsQR || null); };
			s.onerror = function() { restore(); resolve(null); };
			document.head.appendChild(s);
		});
		return this._jsqrPromise;
	},

	// Распознать QR из выбранной картинки ПОЛНОСТЬЮ в браузере (на роутере нет
	// zbar/quirc) и вставить активационный код в поле ввода. Картинку никуда не
	// отправляем - только читаем локально в canvas.
	_decodeQR: function(file) {
		var self = this;
		var fin = document.getElementById('esim-qr-file');
		if (!file) { return; }
		self._loadJsQR().then(function(jsqr) {
			// Сбрасываем input, чтобы повторный выбор ТОГО ЖЕ файла снова сработал.
			if (fin) { fin.value = ''; }
			if (!jsqr) { notify(false, null, _('Could not load the QR decoder.')); return; }
			var reader = new FileReader();
			reader.onload = function(e) {
				var img = new Image();
				img.onload = function() {
					var canvas = document.createElement('canvas');
					canvas.width = img.naturalWidth || img.width;
					canvas.height = img.naturalHeight || img.height;
					var ctx = canvas.getContext('2d');
					ctx.drawImage(img, 0, 0);
					var d;
					try { d = ctx.getImageData(0, 0, canvas.width, canvas.height); }
					catch (ex) { notify(false, null, _('Could not read the image file.')); return; }
					var code = jsqr(d.data, d.width, d.height);
					var txt = (code && code.data) ? String(code.data).trim() : '';
					if (!txt) {
						notify(false, null, _('No QR code found in the image. Try a clearer picture.'));
						return;
					}
					// eSIM-код: "LPA:1$smdp$matchingid" (префикс LPA необязателен).
					if (!/^LPA:/i.test(txt) && txt.indexOf('$') < 0) {
						notify(false, null, _('This QR code is not an eSIM activation code.'));
						return;
					}
					var inp = document.getElementById('esim-code');
					if (inp) { inp.value = txt; inp.focus(); }
					notify(true, _('QR code recognized'), null);
				};
				img.onerror = function() { notify(false, null, _('Could not read the image file.')); };
				img.src = e.target.result;
			};
			reader.onerror = function() { notify(false, null, _('Could not read the image file.')); };
			reader.readAsDataURL(file);
		});
	},

	_doDownload: function(code, inp) {
		var self = this;
		esimUiCss();
		// box - меняющаяся строка текущего шага (её обновляет _pollProgress).
		var box = E('div', { 'class': 'esim-d' }, _('Starting…'));
		ui.showModal(_('Add eSIM profile'), [
			E('div', { 'class': 'esim-modal' }, [
				E('div', { 'class': 'esim-dlrow' }, [
					esimSimIcon(),
					E('span', { 'class': 'esim-spin' }),
					E('div', { 'class': 'esim-h' }, _('Downloading eSIM profile…')),
				]),
				box,
				E('p', { 'class': 'esim-note' }, _('This can take up to a minute — please stay on this page.')),
			]),
		]);
		self._dlActive = true; self._dlLog = '';
		/* При busy (eUICC занята фоновым dump - тёплый список поощряет жать
		   сразу) НЕ роняем загрузку, а повторяем под тем же спиннером - как в
		   esimOp. */
		// ВАЖНО: exec_direct (через /cgi-exec), НЕ fs.exec. fs.exec идёт по ubus-rpc
		// с жёстким таймаутом L.env.rpctimeout (20 c) - а загрузка профиля легитимно
		// длится дольше (обмен с SM-DP+, BPP по AT/CGLA, flush нотификаций), и XHR
		// обрывался с «XHR request timed out», хотя на бэкенде операция ещё шла.
		// exec_direct таймаута на клиенте не ставит. Возвращает stdout СТРОКОЙ.
		// ФОНОВАЯ загрузка: download-bg возвращается сразу (воркер отделён), затем
		// опрашиваем download-status до итога. Синхронный download резал uhttpd на 60 c
		// (cgi-exec), а медленный eUICC FM350 отвечает по многу секунд - как EasyLPAC
		// (cmd.Run() без таймаута), даём загрузке дойти, не упираясь в 60 c.
		var pollResult = function(tries) {
			return fs.exec_direct(ESIM, [ 'download-status' ]).then(function(out) {
				var s = String(out || '');
				// Ещё идёт (dlstate) или пусто - ждём 2.5 c и опрашиваем снова (потолок ~11 мин).
				if (s.indexOf('"dlstate"') >= 0 || !s.trim()) {
					if (tries > 260) { return '{"type":"lpa","payload":{"code":-1,"message":"timeout","data":""}}'; }
					return new Promise(function(resolve) {
						window.setTimeout(function() { resolve(pollResult(tries + 1)); }, 2500);
					});
				}
				return s;   // итог O (многострочный: progress + финальный lpa)
			});
		};
		// Гасим лог прошлого запуска, стартуем фоновый воркер, показываем шаги, опрашиваем.
		var dl = L.resolveDefault(fs.exec_direct(ESIM, [ 'progress', 'reset' ]), '')
			.then(function() {
				self._pollProgress(box);
				return fs.exec_direct(ESIM, [ 'download-bg', code ]);
			})
			.then(function() { return pollResult(0); });
		// Показать модалку ПРОВАЛА. Вынесено, чтобы одинаково звать и из ветки
		// «код != 0», и из .catch (иначе исключение прятало попап молча -
		// пользователь видел «просто исчез», хотя загрузка провалилась).
		var showFail = function(human, tech) {
			self._dlActive = false;
			ui.showModal(_('Add eSIM profile'), [
				E('div', { 'class': 'esim-modal' }, [
					E('div', { 'class': 'esim-dlrow' }, [
						esimSimIcon('esim-simicon esim-simicon-err'),
						E('div', { 'class': 'esim-h' }, _('Download failed')),
					]),
					E('div', { 'class': 'esim-d' }, human || _('The download did not complete.')),
					tech ? E('div', { 'class': 'esim-log' }, tech) : '',
					E('div', { 'class': 'right' }, [
						E('button', {
							'class': 'btn cbi-button',
							'click': ui.createHandlerFn(self, function() { self._saveLog(); })
						}, [ _('Save log') ]),
						' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-neutral',
							'click': function() { ui.hideModal(); self.reload(); }
						}, [ _('Close') ]),
					]),
				]),
			]);
		};
		dl.then(function(out) {
			self._dlActive = false;
			var j = parseLpa(out);
			var ok = lpaOk(j);
			if (!ok) {
				// Заголовок - статус, ниже человеческий текст ошибки (перевод кодов
				// GSMA либо совет при локальной ошибке eUICC), а сырой код + упавший
				// шаг уходят в лог-строку для диагностики/выгрузки.
				var p = (j && j.payload) || {};
				var raw = (typeof p.data === 'string') ? p.data.trim() : '';
				var tech = (p.message || '?') + (raw ? (' · ' + raw) : '');
				/* ТРАНСПОРТ ВАЖНЕЕ КОДА lpac. Когда соединение с сервером вообще
				   не состоялось, lpac говорит только «HTTP status code error» -
				   и это сбивает с толку: похоже на отказ сервера, хотя до него
				   не дошёл ни один байт. Настоящую причину знает наш мост, он
				   пишет её в лог (transport:failed + why): «Connection refused»,
				   «Name or service not known», ошибка TLS. Показываем её. */
				var tr = (self._dlLog || '').split('\n').filter(function(l) {
					return l.indexOf('"transport":"failed"') > 0;
				}).pop();
				var why = tr && tr.match(/"why":"([^"]*)"/);
				if (why && why[1]) {
					showFail(_('Could not reach the operator server: %s').format(why[1].trim()), tech);
					return;
				}
				showFail(esimFailHuman(p.message, raw), tech);
				return;
			}
			if (inp) { inp.value = ''; }
			// Новый профиль модем видит только после полной перезагрузки (AT+CFUN=1,1),
			// а не после перезапуска радио: eUICC перечитывается при инициализации.
			// Модем при этом переэнумерируется на USB (десятки секунд), поэтому
			// ДЕРЖИМ модал с понятным текстом до конца ребута: иначе пользователь,
			// не зная, что модем перезагружается, жмёт Refresh и получает пугающее
			// «eUICC не отвечает» (см. #6). Список перечитываем с запасом (25 c).
			// Не модалка, а оверлей поверх всего блока eSIM: модалка перекрывает
			// страницу целиком и выглядит как «всё сломалось», хотя идёт штатный
			// ребут. Оверлей показывает, что занят именно этот блок.
			ui.hideModal();
			modemtabs.setBusy('#esim-section',
				_('Profile added. The modem is restarting to apply it - up to a minute…'), 240000, 90);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			// Дождаться модема и передёрнуть интерфейс: иначе netifd держит
			// аренду и маршрут от старого профиля (интерфейс up со старым IP,
			// данные не идут). Скрипт сам ждёт готовности, здесь не блокируемся.
			fs.exec(ESIM, [ 'reapply' ]);
			// 25 c не хватало: модем перезагружается ЖЁСТКО и переэнумерируется
			// на USB 30-60 c (столько же ждёт переключение слота). Список
			// перечитывался, пока eUICC ещё не поднялся, попытки заканчивались,
			// и пользователю приходилось жать Refresh руками.
			/* Тот же принцип, что при переключении профиля: ждём возвращения
			   модема на шину, снимаем плашку и перечитываем уже на живой
			   странице (reload сам показывает пометку у EID). */
			_waitModemBack(240000).then(function() {
				modemtabs.clearBusy();
				notify(true, _('eSIM profile added and applied'), null);
				self.reload(-3);
			}).catch(function() {
				// СТРАХОВКА: даже если ожидание модема сорвётся (throw/reject),
				// снимаем плашку и перечитываем список. Иначе полоска ребута
				// зависала на ~97% до ручного F5 (наблюдалось живьём).
				modemtabs.clearBusy(); self.reload(-3);
			});
		}).catch(function(e) {
			// НЕ прячем попап молча: раньше любое исключение/reject (напр. таймаут
			// fs.exec, пустой res) закрывало окно без слова, и пользователю казалось,
			// что «всё прошло, но попап исчез», хотя загрузки не было. Показываем
			// провал с тем, что известно, и полным логом по кнопке.
			showFail(_('The download did not complete.'),
				(e && e.message) ? ('error: ' + e.message) : '');
		});
	},
});

/* --- вспомогательные (вне view, работают с DOM) ------------------------- */
/* Дождаться, пока модем ПЕРЕЖИВЁТ ребут: сначала пропадёт с USB, потом
   вернётся. Сигнал тот же, каким живёт полоса вкладок модемов (она «мигает»
   при ребуте): listmodems.sh, дёшево - из /tmp-кэша, который сбрасывает
   hotplug. Раньше вместо этого крутили dump вслепую: каждый вызов на
   полуподнятом модеме висел до таймаута lpac, и прогрессбар «замерзал».
   Возврат: Promise<bool> - дождались/нет (потолок maxMs). */
function _waitModemBack(maxMs) {
	var t0 = Date.now();
	var gone = false;   // модем уже пропадал с шины?
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		var path = '';
		try { path = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || ''; } catch (e) {}
		var step = function() {
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh'), '[]').then(function(out) {
				var present = false;
				try {
					var arr = JSON.parse(out || '[]') || [];
					present = !path || arr.some(function(m) { return m.path === path; });
				} catch (e) {}
				if (!present) { gone = true; }
				var el = Date.now() - t0;
				/* Возврат засчитываем ТОЛЬКО после наблюдаемой пропажи. Порог
				   «20 c и на месте» оказался ловушкой: модем иногда уходит в
				   ребут с задержкой (реально пропадал на ~40-й секунде), мы
				   считали его «вернувшимся», начинали dump - и втыкались в
				   умирающий eUICC. Фолбэк 90 c - на случай, если короткую
				   переэнумерацию проскочили между опросами. */
				if (present && (gone || el > 90000)) { return true; }
				if (el > maxMs) { return false; }
				return new Promise(function(r) { window.setTimeout(function() { r(step()); }, 3000); });
			});
		};
		return step();
	});
};

function _viewReload(tries, maxTries) {
	// найти активный view-инстанс сложно; проще перечитать напрямую.
	// Возвращает Promise<bool>: true - список перечитан и отрисован, false -
	// eUICC так и не ответил за все попытки (тогда зовущий просит нажать Refresh).
	tries = (typeof tries === 'number') ? tries : 0;
	return esimExec([ 'dump' ]).then(function(d) {
		if (lpaOk(d.profiles || {})) { renderProfiles(d.profiles.payload.data || []); return true; }
		/* eUICC ещё занят сразу после операции (у lpac перед каждой командой идёт
		   чистка логических каналов, но модем отвечает не мгновенно; после delete
		   добавляется отправка нотификации на SM-DP+). Раньше попытка была ОДНА:
		   если она не проходила, список молча оставался старым - удалённый профиль
		   продолжал висеть в таблице до ручного F5. Теперь настойчиво повторяем и
		   резолвим Promise только по факту (успех/исчерпание попыток), чтобы вызов
		   мог держать спиннер и не гасить его раньше времени. */
		/* Сколько раз повторять - зависит от повода. После обычной операции
		   eUICC освобождается за секунды, а после ПЕРЕЗАГРУЗКИ модема (смена
		   профиля) он переэнумерируется на USB и отвечает far позже - там
		   вызывающий просит больший запас. */
		var lim = (typeof maxTries === 'number') ? maxTries : 4;
		if (tries < lim) {
			return new Promise(function(resolve) {
				window.setTimeout(function() { _viewReload(tries + 1, lim).then(resolve); }, 3000);
			});
		}
		return false;
	});
};

/* Применить дамп eUICC к странице: EID/память в шапку, профили в таблицу.
   Общий код живого dump (reload) и мгновенного dump-cached (warm-открытие). */
function applyDump(d) {
	var chip = (d && d.chip) || {}, profs = (d && d.profiles) || {};
	var meta = document.getElementById('esim-meta');
	/* Пометка «обновляется» (reload поверх тёплого списка) своё отработала.
	   Снимаем явно: перезапись meta.textContent ниже случается только при
	   удачном chip info, а профили могут прийти и без него. */
	var _up = document.getElementById('esim-updating');
	if (_up) { _up.parentNode.removeChild(_up); }
	if (lpaOk(chip) && meta) {
		var dd = chip.payload.data || {};
		var mem = (dd.EUICCInfo2 && dd.EUICCInfo2.extCardResource)
			? dd.EUICCInfo2.extCardResource.freeNonVolatileMemory : null;
		meta.textContent = 'EID: ' + (dd.eidValue || '-') +
			(mem != null ? '   ·   ' + _('Free memory') + ': ' + Math.round(mem / 1024) + ' KiB' : '');
	}
	if (lpaOk(profs)) { renderProfiles(profs.payload.data || []); }
	return lpaOk(profs);
}

/* Перечитывание с БЮДЖЕТОМ ВРЕМЕНИ, а не числом попыток. Урок живого теста:
   после AT+CFUN=1,1 tty уже есть, а eUICC ещё не отвечает - каждый dump висит
   до таймаута do_lpac (до 45 c), и «60 попыток» превращались в десятки минут:
   прогрессбар замирал у конца, плашка не снималась. Здесь потолок - настенные
   часы: не успели за budgetMs - честно возвращаем false. */
function _viewReloadFor(budgetMs) {
	var deadline = Date.now() + budgetMs;
	var step = function() {
		return esimExec([ 'dump' ]).then(function(d) {
			if (lpaOk(d.profiles || {})) {
				renderProfiles(d.profiles.payload.data || []);
				return true;
			}
			if (Date.now() >= deadline) { return false; }
			return new Promise(function(resolve) {
				window.setTimeout(function() { resolve(step()); }, 3000);
			});
		});
	};
	return step();
};

function renderProfiles(list) {
	var tbl = document.getElementById('esim-profiles');
	if (!tbl) { return; }
	tbl.querySelectorAll('tr.esim-row').forEach(function(r) { r.parentNode.removeChild(r); });
	if (!list.length) {
		tbl.appendChild(E('tr', { 'class': 'tr esim-row' }, [
			E('td', { 'class': 'td', 'colspan': '5' }, [
				E('em', _('No profiles installed')),
				/* ПУСТОЙ ЧИП - ОСОБЫЙ СЛУЧАЙ, и об этом стоит сказать сразу:
				   часть модемов не может нормально работать со слотом, на
				   котором совсем нет профилей (флап, «modem failed», вечный
				   дозвон - см. mm-esim-without-profiles). Полевой опыт с
				   9esim v3 на T99W175: заводится после загрузки любого
				   ТЕСТОВОГО профиля из публичного списка. */
				E('div', { 'style': 'font-size:90%; opacity:.75; margin-top:.4em' }, [
					_('An empty chip is a special case: some modems cannot work with a profile-less eSIM (the modem keeps resetting or the slot stays unusable). Loading any public test profile usually settles it - see the list of known test profiles:'),
					' ',
					E('a', {
						'href': 'https://euicc-manual.osmocom.org/docs/rsp/known-test-profile/',
						'target': '_blank', 'rel': 'noreferrer'
					}, 'euicc-manual: known test profiles')
				])
			]),
		]));
		return;
	}
	list.forEach(function(p) {
		var on = (p.profileState == 'enabled');
		var name = p.profileNickname || p.profileName || '-';
		if (p.profileClass == 'test') { name += ' (test)'; }
		var btns = [];
		if (on) {
			btns.push(E('button', { 'class': 'btn cbi-button',
				'click': function(ev) { ev.preventDefault(); esimOp('disable', p.iccid, name); } }, [ _('Disable') ]));
		} else {
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) { ev.preventDefault(); esimOp('enable', p.iccid, name); } }, [ _('Enable') ]));
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-remove',
				'click': function(ev) { ev.preventDefault(); esimDeleteConfirm(p.iccid, name); } }, [ _('Delete') ]));
		}
		tbl.appendChild(E('tr', { 'class': 'tr esim-row' }, [
			E('td', { 'class': 'td left' }, [
				E('span', { 'class': 'esim-op' }, [
					// Активный (enabled) профиль - иконка с «галочкой», остальные - обычная.
					E('img', { 'src': L.resource(on ? 'icons/5gmodem/csim_active.svg' : 'icons/5gmodem/csim_iface.svg'), 'alt': '' }),
					p.serviceProviderName || '-'
				])
			]),
			E('td', { 'class': 'td left' }, [ name ]),
			E('td', { 'class': 'td left', 'style': 'font-family:monospace' }, [ p.iccid || '-' ]),
			E('td', { 'class': 'td' }, [ on ? _('Enabled') : _('Disabled') ]),
			E('td', { 'class': 'td right' }, btns),
		]));
	});
}

// --- Уведомления SGP.22 (отдельная секция, как вкладка Notifications в EasyLPAC) --
// Забрать список pending-нотификаций (install/enable/disable/delete), которые надо
// дослать на SM-DP+ оператора. notification list многострочным не бывает, но берём
// через parseLpa на всякий случай.
function fetchNotifications() {
	return fs.exec_direct(ESIM, [ 'notifications' ]).then(function(out) {
		var j = parseLpa(out);
		return (lpaOk(j) && j.payload && Array.isArray(j.payload.data)) ? j.payload.data : [];
	}).catch(function() { return []; });
}
// Отрисовать секцию #esim-notif. Пусто -> прячем (обычно так: flush шлёт авто).
function renderNotifications(list) {
	var box = document.getElementById('esim-notif');
	if (!box) { return; }
	while (box.firstChild) { box.removeChild(box.firstChild); }
	if (!list || !list.length) { box.style.display = 'none'; return; }
	box.style.display = '';
	var opName = { install: _('Added'), enable: _('Enabled'), disable: _('Disabled'), 'delete': _('Deleted') };
	box.appendChild(E('div', { 'class': 'esim-notif-h' }, _('Pending operator notifications')));
	box.appendChild(E('div', { 'class': 'esim-notif-sub' },
		_('These are status reports the modem sends to your operator (SM-DP+) after a profile is enabled, disabled or deleted. They normally go out on their own. If some are stuck here (e.g. there was no internet at the time), the safe choice is Send — it is harmless and just confirms the change. Remove only discards a report without sending it. If unsure, you can leave them or press Send all.')));
	// «Отправить все»: разом дослать и убрать все ожидающие (esim.sh flush =
	// notification process -a -r). Самое частое действие - выносим наверх.
	box.appendChild(E('div', { 'style': 'margin-bottom:8px' }, [
		E('button', { 'class': 'btn cbi-button cbi-button-action',
			'title': _('Send all pending notifications to the operator, then clear them'),
			'click': function(ev) { ev.preventDefault(); esimNotifFlush(); } }, [ _('Send all') ])
	]));
	list.forEach(function(n) {
		var op = opName[n.profileManagementOperation] || n.profileManagementOperation || '?';
		var host = String(n.notificationAddress || '').replace(/^https?:\/\//, '');
		box.appendChild(E('div', { 'class': 'esim-notif-row' }, [
			E('div', { 'class': 'esim-notif-info' }, [
				E('span', { 'class': 'esim-notif-op' }, op), ' \u00b7 ',
				E('span', { 'style': 'font-family:monospace' }, n.iccid || '-'),
				host ? E('div', { 'class': 'esim-notif-host' }, host) : ''
			]),
			E('div', { 'class': 'esim-notif-btns' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-action',
					'title': _('Send this notification to the operator, then remove it'),
					'click': function(ev) { ev.preventDefault(); esimNotifAction('process', n.seqNumber); } }, [ _('Send') ]),
				E('button', { 'class': 'btn cbi-button cbi-button-remove',
					'title': _('Discard this notification locally without sending'),
					'click': function(ev) { ev.preventDefault(); esimNotifAction('remove', n.seqNumber); } }, [ _('Remove') ]),
			]),
		]));
	});
}
// \u0414\u043e\u0441\u043b\u0430\u0442\u044c \u0438 \u043e\u0447\u0438\u0441\u0442\u0438\u0442\u044c \u0412\u0421\u0415 \u043e\u0436\u0438\u0434\u0430\u044e\u0449\u0438\u0435 \u0443\u0432\u0435\u0434\u043e\u043c\u043b\u0435\u043d\u0438\u044f (esim.sh flush).
function esimNotifFlush() {
	modemtabs.setBusy('#esim-section', _('Sending notifications\u2026'), 90000, 15);
	fs.exec_direct(ESIM, [ 'flush' ]).then(function(out) {
		var j = parseLpa(out);
		modemtabs.clearBusy();
		if (!lpaOk(j)) { notify(false, null, _('Notification action failed: %s').format(lpaFail(j))); }
		else { notify(true, _('Notifications sent to the operator')); }
		fetchNotifications().then(renderNotifications);
	}).catch(function() { modemtabs.clearBusy(); fetchNotifications().then(renderNotifications); });
}

function esimNotifAction(action, seq) {
	modemtabs.setBusy('#esim-section',
		action === 'process' ? _('Sending notification\u2026') : _('Removing notification\u2026'), 60000, 15);
	fs.exec_direct(ESIM, [ 'notif', action, String(seq) ]).then(function(out) {
		var j = parseLpa(out);
		modemtabs.clearBusy();
		if (!lpaOk(j)) { notify(false, null, _('Notification action failed: %s').format(lpaFail(j))); }
		fetchNotifications().then(renderNotifications);
	}).catch(function() { modemtabs.clearBusy(); fetchNotifications().then(renderNotifications); });
}
function esimOp(verb, iccid, name) {
	/* УНИФИКАЦИЯ МЕХАНИКИ (решение владельца): никаких попапов. Все состояния
	   показывает оверлей на блоке eSIM (modemtabs.setBusy) с прогрессбаром в
	   стиле полосок метрик. Плашка снимается ТОЛЬКО после перечитывания
	   списка - пользователь сразу видит сменившийся активный профиль. */
	modemtabs.setBusy('#esim-section', _('Applying eSIM operation...'), 60000, 15);
	var attempt = function(tries) {
	// exec_direct, НЕ fs.exec: enable/disable/delete + flush нотификаций легко
	// перекрывают 20-c ubus-таймаут fs.exec (был «XHR request timed out»). Через
	// /cgi-exec клиентского таймаута нет. Возвращает stdout строкой.
	fs.exec_direct(ESIM, [ verb, iccid ]).then(function(out) {
		var j = parseLpa(out);
		var ok = lpaOk(j);
		/* ОЧЕРЕДЬ ВМЕСТО ОШИБКИ. У eUICC один логический канал: пока фоновый
		   dump (тёплый список ПООЩРЯЕТ кликать сразу) или другая операция
		   держит замок esim.sh, бэкенд отвечает busy. Раньше это вываливалось
		   пользователю как «operation failed: busy». Теперь тихо ждём под тем
		   же спиннером и повторяем: dump на FM350 - ~10 c, 12 попыток по 2 c
		   покрывают его с запасом. */
		if (!ok && lpaMsg(j) === 'busy' && tries < 12) {
			window.setTimeout(function() { attempt(tries + 1); }, 2000);
			return;
		}
		if (ok && (verb == 'enable' || verb == 'disable')) {
			/* Смена активного профиля применяется ТОЛЬКО после полной
			   перезагрузки модема (AT+CFUN=1,1): eUICC перечитывает профили при
			   инициализации, перезапуска одного радио (soft) не хватает - раньше
			   профиль визуально «не переключался». Модем при этом
			   переэнумерируется на USB (десятки секунд), поэтому:
			   - держим оверлей с понятным текстом (а не пугающую ошибку, если
			     пользователь сам жмёт Refresh во время ребута - см. #6);
			   - список перечитываем с запасом (25 c), как при добавлении. */
			// Оверлей уже висит - обновляем текст и растягиваем прогресс на ребут.
			/* ДВЕ ЦЕЛЬНЫЕ ФРАЗЫ, А НЕ ПОДСТАНОВКА СЛОВА.
			   Здесь было _('Profile %s…').format(_('enabled')) - и по-русски
			   выходило «Профиль включено»: прилагательное не согласуется с
			   существительным. Собирать предложения из кусков нельзя в принципе -
			   в каждом языке своё согласование, и переводчик не может это
			   исправить, у него на руках только обрывки. */
			modemtabs.setBusy('#esim-section', verb == 'enable'
				? _('Profile enabled. The modem is restarting to apply it - up to a minute…')
				: _('Profile disabled. The modem is restarting to apply it - up to a minute…'),
				300000, 90);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			fs.exec(ESIM, [ 'reapply' ]);   // см. выше: без этого остаётся старый IP
			/* Ждём ВОЗВРАЩЕНИЯ модема (как полоса вкладок: пропал -> появился),
			   тогда прогрессбар добегает и плашка уходит СРАЗУ - а обновление
			   списка идёт уже на живой странице с пометкой у EID (решение
			   владельца: не держать плашку до перечитывания). */
			_waitModemBack(240000).then(function() {
				modemtabs.clearBusy();
				notify(true, _('eSIM operation done'), null);
				var meta = document.getElementById('esim-meta');
				if (meta && !document.getElementById('esim-updating')) {
					meta.appendChild(E('em', {
						'id': 'esim-updating', 'class': 'spinning',
						'style': 'margin-left:.7em;font-size:92%;opacity:.7'
					}, _('Updating the profile list...')));
				}
				/* recheck: после AT+CFUN=1,1 tty eUICC мог сменить номер -
				   сбрасываем кэш порта, потом перечитываем с бюджетом времени. */
				L.resolveDefault(fs.exec_direct(ESIM, [ 'recheck' ]), '')
					.then(function() { return _viewReloadFor(120000); })
					.then(function(done) {
						var up = document.getElementById('esim-updating');
						if (up) { up.parentNode.removeChild(up); }
						if (!done) {
							notify(false, null, _('Could not refresh the list automatically. Press Refresh in a few seconds.'));
						}
						/* Включили другой профиль -> мог смениться оператор:
						   предложим проверить APN (не меняем молча). */
						if (verb == 'enable') { proposeApnAfterEnable(); }
					});
			}).catch(function() { modemtabs.clearBusy(); });
			return;
		}
		notify(ok, _('eSIM operation done'), _('eSIM operation failed: %s').format(lpaFail(j)));
		if (ok) {
			// Удаление (и любая успешная не-enable/disable операция) не перезагружает
			// модем, но eUICC ещё занят: сразу после delete идёт отправка нотификации
			// на SM-DP+. Держим спиннер и НАСТОЙЧИВО перечитываем список - иначе он
			// оставался старым (удалённый профиль висел в таблице) до ручного Refresh.
			modemtabs.setBusy('#esim-section', _('Updating the profile list...'), 60000, 12);
			window.setTimeout(function() {
				_viewReload().then(function(done) {
					modemtabs.clearBusy();
					if (!done) { notify(false, null,
						_('Could not refresh the list automatically. Press Refresh in a few seconds.')); }
				});
			}, 1500);
		} else {
			modemtabs.clearBusy();
			window.setTimeout(_viewReload, 2500);
		}
	}).catch(function() { modemtabs.clearBusy(); });
	};
	attempt(0);
}

function esimDeleteConfirm(iccid, name) {
	ui.showModal(_('Delete eSIM profile'), [
		E('p', _('Delete profile "%s" (%s)? This cannot be undone.').format(name, iccid)),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			E('button', { 'class': 'btn cbi-button-remove',
				'click': function() { ui.hideModal(); esimOp('delete', iccid, name); } }, [ _('Delete') ]),
		]),
	]);
}
