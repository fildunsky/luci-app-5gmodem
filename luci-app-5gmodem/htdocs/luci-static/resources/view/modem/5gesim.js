'use strict';
'require view';
'require fs';
'require ui';
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

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return Promise.all([ esimExec([ 'status' ]), slotExec([ 'status' ]) ]);
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
				'#esim-profiles td,#esim-profiles th{white-space:nowrap}'
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', [ 'eSIM' ]),
				E('div', { 'class': 'cbi-section-descr' },
					_('Manage embedded SIM (eUICC) profiles: add by activation code, enable, disable or delete.')),
				body,
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
				if (tries < 2) {
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
			if (nc.smdp === 0) {
				// сеть есть, но SM-DP+ не ответил - не блокируем (мог не отвечать
				// на GET корня), но честно предупреждаем
				ui.addNotification(null, E('p',
					_('The operator server did not respond to a test request, but the internet is up. Trying to download anyway...')), 'warning');
			}
			self._doDownload(code, inp);
		});
	},

	_doDownload: function(code, inp) {
		ui.showModal(_('Add eSIM profile'), [
			E('p', { 'class': 'spinning' }, _('Downloading eSIM profile... This can take a minute, do not leave the page.')),
		]);
		var self = this;
		fs.exec(ESIM, [ 'download', code ]).then(function(res) {
			var j = parseLpa(res.stdout);
			var ok = lpaOk(j);
			if (!ok) {
				ui.hideModal();
				notify(false, null, _('Download failed: %s').format(lpaMsg(j)));
				self.reload();
				return;
			}
			if (inp) { inp.value = ''; }
			// Новый профиль модем видит только после полной перезагрузки (AT+CFUN=1,1),
			// а не после перезапуска радио: eUICC перечитывается при инициализации.
			// Модем при этом переэнумерируется на USB (десятки секунд), поэтому
			// ДЕРЖИМ модал с понятным текстом до конца ребута: иначе пользователь,
			// не зная, что модем перезагружается, жмёт Refresh и получает пугающее
			// «eUICC не отвечает» (см. #6). Список перечитываем с запасом (25 c).
			ui.showModal(_('Add eSIM profile'), [ E('p', { 'class': 'spinning' },
				_('Profile added. Rebooting the modem to apply it - this takes up to a minute, please wait...')) ]);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			window.setTimeout(function() {
				ui.hideModal();
				notify(true, _('eSIM profile added and applied.'), null);
				self.reload();
			}, 25000);
		}).catch(function() { ui.hideModal(); });
	},
});

/* --- вспомогательные (вне view, работают с DOM) ------------------------- */
var _viewReload = function(tries) {
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
		if (tries < 4) {
			return new Promise(function(resolve) {
				window.setTimeout(function() { _viewReload(tries + 1).then(resolve); }, 3000);
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
			ui.showModal(_('eSIM'), [ E('p', { 'class': 'spinning' },
				_('Profile %s. Rebooting the modem to apply it - this takes up to a minute, please wait...')
					.format(verb == 'enable' ? _('enabled') : _('disabled'))) ]);
			fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]);
			window.setTimeout(function() {
				ui.hideModal();
				notify(true, _('eSIM operation done'), null);
				_viewReload();
			}, 25000);
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
