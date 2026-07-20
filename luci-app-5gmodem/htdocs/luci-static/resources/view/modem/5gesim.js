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
		/* status-probe (синхронная проба): пользователь ОСОЗНАННО открыл вкладку
		   eSIM и готов подождать пробу; на горячем пути видимости вкладки
		   используется мгновенный 'status'. */
		return Promise.all([ esimExec([ 'status-probe' ]), slotExec([ 'status' ]) ]);
	},

	render: function(res) {
		modemtabs.attach();
		var st = res[0] || {}, slot = res[1] || {};

		var body = E('div', { 'id': 'esim-body' });
		var self = this;

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
					'click': function(ev) { ev.preventDefault(); self.reload(); }
				}, [ _('Refresh') ]),
			]));
			// первичная загрузка данных eUICC
			window.setTimeout(function() { self.reload(); }, 100);
		}

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
			E('div', { 'class': 'cbi-section' }, [
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
		// dump = chip info + список профилей через lpac по APDU-мосту: на FM350 это
		// ~10 с и дольше. Без явного предупреждения пустая строка выглядит как
		// «ничего не нашлось», и люди уходят со страницы, не дождавшись.
		if (meta) {
			meta.innerHTML = '';
			meta.appendChild(E('em', { 'class': 'spinning' },
				_('Please wait, reading eUICC - updating the profile list can be slow.')));
		}
		esimExec([ 'dump' ]).then(function(d) {
			var chip = d.chip || {}, profs = d.profiles || {};
			if (!lpaOk(chip) && !lpaOk(profs)) {
				// Первая попытка часто не проходит: eUICC мог остаться с занятыми
				// логическими каналами после предыдущей сессии (esim.sh чистит их
				// через AT+CCHC перед каждой операцией) или модем ещё поднимается
				// после CFUN. Не пугаем ошибкой сразу - молча повторяем.
				// потолок с запасом: после жёсткого ребута модема eUICC отвечает не сразу
				if (tries < 5) {
					window.setTimeout(function() { self.reload(tries + 1); }, 4000);
					return;
				}
				if (meta) {
					meta.innerHTML = '';
					meta.appendChild(E('span', { 'style': 'color:#d95c5c' },
						_('eUICC is not responding (%s). Try Refresh in a few seconds.').format(lpaMsg(chip) || lpaMsg(profs))));
				}
				return;
			}
			if (lpaOk(chip) && meta) {
				var dd = chip.payload.data || {};
				var mem = (dd.EUICCInfo2 && dd.EUICCInfo2.extCardResource)
					? dd.EUICCInfo2.extCardResource.freeNonVolatileMemory : null;
				meta.textContent = 'EID: ' + (dd.eidValue || '-') +
					(mem != null ? '   ·   ' + _('Free memory') + ': ' + Math.round(mem / 1024) + ' KiB' : '');
			}
			if (lpaOk(profs)) { renderProfiles(profs.payload.data || []); }
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
		// Сначала гасим лог прошлого запуска на бэкенде, и только потом стартуем:
		// иначе первый же опрос покажет чужие шаги целиком.
		var dl = L.resolveDefault(fs.exec_direct(ESIM, [ 'progress', 'reset' ]), '')
			.then(function() {
				self._pollProgress(box);
				return fs.exec(ESIM, [ 'download', code ]);
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
			modemtabs.setBusy('.cbi-section',
				_('Profile added. The modem is restarting to apply it - up to a minute…'), 90000);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			// Дождаться модема и передёрнуть интерфейс: иначе netifd держит
			// аренду и маршрут от старого профиля (интерфейс up со старым IP,
			// данные не идут). Скрипт сам ждёт готовности, здесь не блокируемся.
			fs.exec(ESIM, [ 'reapply' ]);
			// 25 c не хватало: модем перезагружается ЖЁСТКО и переэнумерируется
			// на USB 30-60 c (столько же ждёт переключение слота). Список
			// перечитывался, пока eUICC ещё не поднялся, попытки заканчивались,
			// и пользователю приходилось жать Refresh руками.
			window.setTimeout(function() {
				modemtabs.clearBusy();
				notify(true, _('eSIM profile added and applied.'), null);
				self.reload(-3);   // запас попыток: модем мог ещё не вернуться
			}, 45000);
		}).catch(function() { ui.hideModal(); });
	},
});

/* --- вспомогательные (вне view, работают с DOM) ------------------------- */
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
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying eSIM operation...')));
	fs.exec(ESIM, [ verb, iccid ]).then(function(res) {
		var j = parseLpa(res.stdout);
		var ok = lpaOk(j);
		if (ok && (verb == 'enable' || verb == 'disable')) {
			/* Смена активного профиля применяется ТОЛЬКО после полной
			   перезагрузки модема (AT+CFUN=1,1): eUICC перечитывает профили при
			   инициализации, перезапуска одного радио (soft) не хватает - раньше
			   профиль визуально «не переключался». Модем при этом
			   переэнумерируется на USB (десятки секунд), поэтому:
			   - держим модал с понятным текстом (а не пугающей ошибкой, если
			     пользователь сам жмёт Refresh во время ребута - см. #6);
			   - список перечитываем с запасом (25 c), как при добавлении. */
			// Оверлей поверх блока вместо модалки - идёт штатный ребут, а не сбой.
			ui.hideModal();
			/* ДВЕ ЦЕЛЬНЫЕ ФРАЗЫ, А НЕ ПОДСТАНОВКА СЛОВА.
			   Здесь было _('Profile %s…').format(_('enabled')) - и по-русски
			   выходило «Профиль включено»: прилагательное не согласуется с
			   существительным. Собирать предложения из кусков нельзя в принципе -
			   в каждом языке своё согласование, и переводчик не может это
			   исправить, у него на руках только обрывки. */
			modemtabs.setBusy('.cbi-section', verb == 'enable'
				? _('Profile enabled. The modem is restarting to apply it - up to a minute…')
				: _('Profile disabled. The modem is restarting to apply it - up to a minute…'),
				120000);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			fs.exec(ESIM, [ 'reapply' ]);   // см. выше: без этого остаётся старый IP
			window.setTimeout(function() {
				/* Порт eUICC после AT+CFUN=1,1 МОГ СМЕНИТЬСЯ: модем
				   переэнумерируется на USB, и запомненный номер tty уже чужой.
				   recheck сбрасывает и кэш порта, и кэш наличия eSIM. */
				L.resolveDefault(fs.exec_direct(ESIM, [ 'recheck' ]), '')
					/* 15 попыток по 3 c - модем после AT+CFUN=1,1 поднимается
					   десятки секунд, и четырёх попыток (12 c) не хватало:
					   список молча оставался прежним. */
					.then(function() { return _viewReload(0, 15); })
					.then(function(done) {
						modemtabs.clearBusy();
						notify(true, _('eSIM operation done'), null);
						/* РЕЗУЛЬТАТ ПРОВЕРЯЕМ. Раньше он игнорировался: если eUICC
						   не успевал ответить (а после жёсткой перезагрузки это
						   обычное дело), список молча оставался прежним, и
						   пользователю приходилось обновлять страницу руками. */
						if (!done) {
							notify(false, null, _('Could not refresh the list automatically. Press Refresh in a few seconds.'));
						}
						/* Включили другой профиль -> мог смениться оператор:
						   предложим проверить APN (не меняем молча). */
						if (verb == 'enable') { proposeApnAfterEnable(); }
					});
			}, 45000);
			return;
		}
		notify(ok, _('eSIM operation done'), _('eSIM operation failed: %s').format(lpaMsg(j)));
		if (ok) {
			// Удаление (и любая успешная не-enable/disable операция) не перезагружает
			// модем, но eUICC ещё занят: сразу после delete идёт отправка нотификации
			// на SM-DP+. Держим спиннер и НАСТОЙЧИВО перечитываем список - иначе он
			// оставался старым (удалённый профиль висел в таблице) до ручного Refresh.
			ui.showModal(_('eSIM'), [ E('p', { 'class': 'spinning' },
				_('Updating the profile list...')) ]);
			window.setTimeout(function() {
				_viewReload().then(function(done) {
					ui.hideModal();
					if (!done) { notify(false, null,
						_('Could not refresh the list automatically. Press Refresh in a few seconds.')); }
				});
			}, 1500);
		} else {
			ui.hideModal();
			window.setTimeout(_viewReload, 2500);
		}
	}).catch(function() { ui.hideModal(); });
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
