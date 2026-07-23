'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require view.modem.modemtabs as modemtabs';

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
				_('eSIM profile switched - checking and updating the APN automatically.')),
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
			body.appendChild(E('p', { 'class': 'cbi-section-descr' },
				_('eSIM management is unavailable: the lpac package is not installed, or the active modem is not an AT-type modem.')));
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
			body.appendChild(E('div', { 'class': 'esim-meta', 'id': 'esim-meta' }, [ E('em', _('Reading eUICC...')) ]));
			body.appendChild(E('table', { 'class': 'table', 'id': 'esim-profiles' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th left' }, [ _('Operator') ]),
					E('th', { 'class': 'th left' }, [ _('Profile') ]),
					E('th', { 'class': 'th left' }, [ 'ICCID' ]),
					E('th', { 'class': 'th' }, [ _('Status') ]),
					E('th', { 'class': 'th' }, [ '' ]),
				]),
			]));
			body.appendChild(E('div', { 'class': 'esim-dl' }, [
				E('input', {
					'type': 'text', 'class': 'cbi-input-text', 'id': 'esim-code',
					'placeholder': 'LPA:1$rsp.example.com$XXXX-XXXX'
				}),
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function(ev) { ev.preventDefault(); self.download(); }
				}, [ _('Add eSIM profile') ]),
			]));
			body.appendChild(E('div', { 'class': 'esim-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					/* Без спиннера на кнопке (решение владельца): обратную связь
					   даёт пометка «обновляется» рядом с EID (см. reload). */
					'click': function(ev) { ev.preventDefault(); self.reload(); }
				}, [ _('Refresh') ]),
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
			E('style', {}, [
				'.esim-meta{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:88%;opacity:.85;margin:.4em 0 1em}' +
				'.esim-dl{display:flex;gap:8px;margin-top:12px;align-items:center;flex-wrap:wrap}' +
				'.esim-dl input{flex:1 1 22em;min-width:14em}' +
				'.esim-actions{margin-top:10px}' +
				'#esim-profiles .btn{padding:1px 8px;font-size:85%;margin-left:4px}' +
				'#esim-profiles td,#esim-profiles th{white-space:nowrap}' +
				'.esim-steps{margin-top:8px;font-size:88%;opacity:.8;min-height:1.3em}' +
				'.esim-step{padding:1px 0;font-family:ui-monospace,Menlo,Consolas,monospace}' +
				'.esim-set{margin-top:18px;border-top:1px solid rgba(128,128,128,.25);padding-top:10px}' +
				'.esim-set>summary{cursor:pointer;font-size:92%;opacity:.75;user-select:none}' +
				'.esim-set>summary:hover{opacity:1}' +
				'.esim-set .cbi-value{margin-top:10px}'
			]),
			/* id нужен оверлею операций (modemtabs.setBusy('#esim-section')):
			   селектор '.cbi-section' брал ПЕРВУЮ секцию документа - на части
			   тем это не наш блок. */
			E('div', { 'class': 'cbi-section', 'id': 'esim-section' }, [
				E('h3', [ 'eSIM' ]),
				E('div', { 'class': 'cbi-section-descr' },
					_('Manage embedded SIM (eUICC) profiles: add by activation code, enable, disable or delete.')),
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
							uci.set('5gmodem', '@5gmodem[0]', 'esim_http', sel.value);
							return uci.save().then(function() {
								return uci.apply();
							}).then(function() {
								ui.addNotification(null,
									E('p', _('Download transport saved.')), 'info');
							});
						})
					}, [ _('Save') ]),
					E('div', { 'class': 'cbi-value-description' },
						_('How lpac talks to the operator server (SM-DP+). "Auto" uses the bridge when available. The bridge reaches SM-DP+ servers that present GSMA CI certificates, which the built-in curl cannot handle on mbedTLS builds, and it verifies the certificate.')),
				]),
			]),
		]);
	},

	// перечитать eUICC (chip info + список профилей одним вызовом dump)
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
			meta.appendChild(E('em', { 'class': 'spinning' },
				_('Please wait, reading eUICC - updating the profile list can be slow.')));
		}
		/* Поверх тёплого списка EID не затираем, но обратная связь нужна
		   (кнопка «Обновить» выглядела немой): МЕЛКАЯ пометка рядом с EID.
		   Строка та же, что в модалке пост-операций, - уже переведена.
		   applyDump при успехе перепишет meta целиком и снимет пометку сам. */
		if (meta && warm && !document.getElementById('esim-updating')) {
			meta.appendChild(E('em', {
				'id': 'esim-updating', 'class': 'spinning',
				'style': 'margin-left:.7em;font-size:92%;opacity:.7'
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
				var _up = document.getElementById('esim-updating');
				if (_up) { _up.parentNode.removeChild(_up); }
				/* Тёплый список на экране рабочий - не пугаем ошибкой, eUICC
				   часто просто занята; без списка ошибка честно видна. */
				if (meta && !warm) {
					meta.innerHTML = '';
					meta.appendChild(E('span', { 'style': 'color:#d95c5c' },
						_('eUICC is not responding (%s). Try Refresh in a few seconds.').format(lpaMsg(chip) || lpaMsg(profs))));
				}
				return;
			}
			applyDump(d);
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
		};
		return map[m] || m;
	},

	// Опрос живого лога, пока крутится спиннер. Мост дописывает строки прогресса
	// по мере их прихода, поэтому ход операции виден сразу, а не вместе с итогом.
	_pollProgress: function(box) {
		var self = this;
		if (!self._dlActive) { return; }
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
				if (last) {
					var m = last.match(/"message":"([^"]+)"/);
					var d = last.match(/"serviceProviderName":"([^"]+)"/);
					var t = m ? self._stepName(m[1]) : '';
					if (t) { box.textContent = (d ? (t + ' — ' + d[1]) : t) + '…'; }
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

	_doDownload: function(code, inp) {
		var self = this;
		var box = E('div', { 'class': 'esim-steps' });
		ui.showModal(_('Add eSIM profile'), [
			E('p', { 'class': 'spinning' }, _('Downloading eSIM profile... This can take a minute, do not leave the page.')),
			box,
		]);
		self._dlActive = true; self._dlLog = '';
		/* При busy (eUICC занята фоновым dump - тёплый список поощряет жать
		   сразу) НЕ роняем загрузку, а повторяем под тем же спиннером - как в
		   esimOp. */
		var runDl = function(tries) {
			return fs.exec(ESIM, [ 'download', code ]).then(function(res) {
				var j = parseLpa(res.stdout);
				if (!lpaOk(j) && lpaMsg(j) === 'busy' && tries < 12) {
					return new Promise(function(resolve) {
						window.setTimeout(function() { resolve(runDl(tries + 1)); }, 2000);
					});
				}
				return res;
			});
		};
		// Сначала гасим лог прошлого запуска на бэкенде, и только потом стартуем:
		// иначе первый же опрос покажет чужие шаги целиком.
		var dl = L.resolveDefault(fs.exec_direct(ESIM, [ 'progress', 'reset' ]), '')
			.then(function() {
				self._pollProgress(box);
				return runDl(0);
			});
		dl.then(function(res) {
			self._dlActive = false;
			var j = parseLpa(res.stdout);
			var ok = lpaOk(j);
			if (!ok) {
				// Лог оставляем на экране: он показывает, НА КАКОМ шаге отвалилось,
				// и его можно выгрузить файлом для удалённого разбора.
				ui.showModal(_('Add eSIM profile'), [
					E('p', {}, _('Download failed: %s').format(lpaMsg(j))),
					box,
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
				]);
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
				_('Profile added. The modem is restarting to apply it - up to a minute…'), 180000, 90);
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
				notify(true, _('eSIM profile added and applied.'), null);
				self.reload(-3);
			});
		}).catch(function() { ui.hideModal(); });
	},
});

/* --- вспомогательные (вне view, работают с DOM) ------------------------- */
/* Дождаться, пока модем ПЕРЕЖИВЁТ ребут: сначала пропадёт с USB, потом
   вернётся. Сигнал тот же, каким живёт полоса вкладок модемов (она «мигает»
   при ребуте): listmodems.sh, дёшево - из /tmp-кэша, который сбрасывает
   hotplug. Раньше вместо этого крутили dump вслепую: каждый вызов на
   полуподнятом модеме висел до таймаута lpac, и прогрессбар «замерзал».
   Возврат: Promise<bool> - дождались/нет (потолок maxMs). */
var _waitModemBack = function(maxMs) {
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

var _viewReload = function(tries, maxTries) {
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
var _viewReloadFor = function(budgetMs) {
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
			E('td', { 'class': 'td', 'colspan': '5' }, [ E('em', _('No profiles installed')) ]),
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
			E('td', { 'class': 'td left' }, [ p.serviceProviderName || '-' ]),
			E('td', { 'class': 'td left' }, [ name ]),
			E('td', { 'class': 'td left', 'style': 'font-family:monospace' }, [ p.iccid || '-' ]),
			E('td', { 'class': 'td' }, [ on ? _('Enabled') : _('Disabled') ]),
			E('td', { 'class': 'td right' }, btns),
		]));
	});
}

function esimOp(verb, iccid, name) {
	/* УНИФИКАЦИЯ МЕХАНИКИ (решение владельца): никаких попапов. Все состояния
	   показывает оверлей на блоке eSIM (modemtabs.setBusy) с прогрессбаром в
	   стиле полосок метрик. Плашка снимается ТОЛЬКО после перечитывания
	   списка - пользователь сразу видит сменившийся активный профиль. */
	modemtabs.setBusy('#esim-section', _('Applying eSIM operation...'), 60000, 15);
	var attempt = function(tries) {
	fs.exec(ESIM, [ verb, iccid ]).then(function(res) {
		var j = parseLpa(res.stdout);
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
			});
			return;
		}
		notify(ok, _('eSIM operation done'), _('eSIM operation failed: %s').format(lpaMsg(j)));
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
