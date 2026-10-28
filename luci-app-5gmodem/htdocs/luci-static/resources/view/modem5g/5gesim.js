'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require view.modem5g.fresh as fresh';

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
function lpaFail(j) {
	var p = (j && j.payload) || {};
	var step = p.message || '?';
	var reason = (typeof p.data === 'string') ? p.data.trim() : '';
	return reason ? (reason + ' (' + step + ')') : step;
}

function esimUiCss() {}

function esimSimIcon(cls) {
	return E('img', {
		'class': cls || 'esim-simicon',
		'src': mutil.icon('icons/5gmodem/csim_iface.svg'),
		'alt': ''
	});
}

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
	if (!m) { return s; }
	var key = m[1] + '/' + m[2];
	if (GSMA_COMBO[key]) { return GSMA_COMBO[key]; }
	var subj = GSMA_SUBJECT[m[1]], reas = GSMA_REASON[m[2]];
	if (reas) { return subj ? (subj.charAt(0).toUpperCase() + subj.slice(1) + ': ' + reas) : reas; }
	return s;
}

function esimFailHuman(step, raw) {
	var s = String(raw || '').trim();
	if (/^\d+(?:\.\d+)*\/\d+(?:\.\d+)*/.test(s)) { return gsmaHuman(s); }
	if (/iccid_already_exists/i.test(s)) {
		return _('This profile is already installed on the eSIM — look for it in the list below.');
	}
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
		ui.addTimeLimitedNotification(null, E('p', [ m ]), 6000, ok ? 'info' : 'error');
	} else {
		ui.addNotification(null, E('p', [ m ]), ok ? 'info' : 'error');
	}
}

function proposeApnAfterEnable() {
	return L.resolveDefault(uci.load('5gmodem')).then(function() {
		var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
		var sec = p ? ('m_' + String(p).replace(/[^A-Za-z0-9]/g, '_')) : '';
		var iface = (sec && uci.get('5gmodem', sec, 'network'))
			|| uci.get('5gmodem', '@5gmodem[0]', 'network') || 'modem';
		var manual = sec && uci.get('5gmodem', sec, 'apn_mode') === 'manual';

		if (!manual) {
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'autoapn', iface ]), null);
			ui.addNotification(null, E('p', {},
				_('eSIM profile switched - checking and updating the APN automatically')),
				'info');
			return;
		}

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
		var self = this, args = arguments;
		return fresh.check(30904, [ modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {
		return Promise.all([ esimExec([ 'status-cached' ]), slotExec([ 'status' ]),
		                     L.resolveDefault(uci.load('5gmodem')) ]);
	},

	render: function(res) {
		modemtabs.attach();
		var st = res[0] || {}, slot = res[1] || {};

		var body = E('div', { 'id': 'esim-body' });
		var self = this;

		if (st.available == null) {
			body.appendChild(E('p', { 'class': 'spinning', 'id': 'esim-probing' },
				_('Checking eSIM support…')));
			esimExec([ 'status-probe' ]).then(function(st2) {
				self._fillBody(body, st2 || {}, slot);
			});
		} else {
			self._fillBody(body, st, slot);
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

	_fillBody: function(body, st, slot) {
		var self = this;
		while (body.firstChild) { body.removeChild(body.firstChild); }

		if (st.takeover) {
			var act = null;
			(slot.slots || []).forEach(function(sl) { if (String(sl.id) === String(slot.active)) { act = sl; } });
			if (act && act.label !== 'eSIM') {
				st = { available: 1, active: 0 };
			} else if (!self._tkAgreed) {
				body.appendChild(E('div', { 'class': 'tgesim-actionrow' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-action',
						'click': function(ev) {
							ev.preventDefault();
							self._tkAgreed = true;
							self._fillBody(body, st, slot);
						}
					}, _('Read eSIM (drops the connection briefly)')),
					E('p', { 'class': 'cbi-section-descr' },
						_('This modem is managed by ModemManager. Reading and changing eSIM profiles temporarily takes the control channel from it: the modem internet connection drops for about 1-2 minutes and then recovers automatically. Several operations in a row share one takeover window.'))
				]));
				return;
			}
		}

		if (!st.available) {
			var msg;
			if (st.reason === 'nolpac') {
				msg = _('eSIM management needs the lpac package, which is not installed. Install the lpac build for your platform - see the app README.');
			} else if (st.reason === 'mm_owns') {
				msg = _('This modem is managed by ModemManager, and its control channel belongs to MM. Opening a second eSIM session on the same channel can crash the modem firmware (seen live on T99W175 - the modem reboots). To manage eSIM, enable "Hide from ModemManager" in the modem settings (or switch the interface protocol), then come back here.');
			} else if (st.reason === 'modemmanager') {
				msg = _('This modem is on the ModemManager protocol, where eSIM over AT commands is not available. Switch the modem interface to the fibocom / MBIM / QMI protocol to manage eSIM.');
			} else if (st.reason === 'uplink') {
				msg = _('The modem control channel is busy with the active connection, so the eSIM chip cannot be read right now. Disconnect the modem interface (or switch to another SIM) to manage profiles.');
			} else if (st.reason === 'slot') {
				msg = _('The physical SIM slot is active, so the eSIM chip cannot be read. Switch to the eSIM slot to manage profiles.');
			} else if (st.reason === 'noeuicc') {
				msg = _('No eSIM chip (eUICC) answered on this modem. If you are sure it has one, it may be in a USB composition this app does not talk to yet - please report your modem model and its USB ID (vid:pid) so we can add support.');
			} else {
				msg = _('eSIM management is unavailable: the lpac package is not installed, or the active modem is not an AT-type modem');
			}
			var _btn = null;
			if (st.reason === 'slot') {
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
							window.setTimeout(function() { location.reload(); }, 45000);
						}).catch(function() { ui.hideModal(); });
					}
				}, [ _('Switch to eSIM slot') ]));
			}
		}
		else {
			body.appendChild(E('div', { 'class': 'esim-metarow' }, [
				E('div', { 'class': 'esim-meta', 'id': 'esim-meta' }, [ E('em', _('Reading eUICC...')) ]),
				E('button', {
					'class': 'btn cbi-button esim-refresh',
					'click': function(ev) { ev.preventDefault(); self._reloadOnce(); }
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
			body.appendChild(E('div', { 'id': 'esim-notif', 'style': 'display:none' }));
			body.appendChild(E('div', { 'class': 'esim-dl' }, [
				E('button', {
					'class': 'btn cbi-button esim-qr-btn',
					'title': _('Load a QR code image and read the activation code from it'),
					'click': function(ev) {
						ev.preventDefault();
						var f = document.getElementById('esim-qr-file');
						if (f) { f.click(); }
					}
				}, [ E('img', { 'src': mutil.icon('icons/5gmodem/cqr.svg'), 'alt': _('QR') }) ]),
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
			esimExec([ 'dump-cached' ]).then(function(d) { applyDump(d); });
			window.setTimeout(function() { self._reloadOnce(); }, 300);
		}
	},

	_shell: function(body) {
		return E('div', { 'class': 'cbi-map' }, [
			E('div', { 'class': 'cbi-section tgesim', 'id': 'esim-section' }, [
				E('h3', [ 'eSIM' ]),
				body,
				this.renderSettings(),
			]),
		]);
	},

	renderSettings: function() {
		var cur = String(uci.get('5gmodem', '@5gmodem[0]', 'esim_http') || 'auto');
		var selW = new ui.Dropdown(cur, {
			'auto':   _('Auto (recommended)'),
			'bridge': _('wget / OpenSSL bridge'),
			'curl':   _('lpac built-in curl')
		}, { id: 'esim-http-sel', sort: [ 'auto', 'bridge', 'curl' ] });
		var sel = selW.render();

		var apduCur = String(uci.get('5gmodem', '@5gmodem[0]', 'esim_apdu') || 'auto');
		var apduW = new ui.Dropdown(apduCur, {
			'auto':   _('Auto (recommended)'),
			'at':     _('AT (serial - FM350 etc.)'),
			'qmi':    _('QMI / libqmi (Qualcomm)'),
			'uqmi':   _('QMI / uqmi CLI'),
			'mbim':   _('MBIM'),
			'bridge': _('AT bridge (sms_tool)')
		}, { id: 'esim-apdu-sel', sort: [ 'auto', 'at', 'qmi', 'uqmi', 'mbim', 'bridge' ] });
		var apduSel = apduW.render();

		var slotW = new ui.Dropdown('auto', {
			'auto': _('Auto (active slot)'),
			'1':    _('Slot 1'),
			'2':    _('Slot 2')
		}, { id: 'esim-slot-sel', sort: [ 'auto', '1', '2' ] });
		var slotSel = slotW.render();
		L.resolveDefault(fs.exec_direct(ESIM, [ 'getslot' ]), '').then(function(out) {
			try { slotW.setValue(String(JSON.parse(out).slot || 'auto')); } catch (e) {}
		});

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
							return fs.exec_direct(ESIM, [ 'sethttp', selW.getValue() ]).then(function() {
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
							return fs.exec_direct(ESIM, [ 'setapdu', apduW.getValue() ]).then(function() {
								ui.addNotification(null,
									E('p', _('eUICC access saved')), 'info');
							});
						})
					}, [ _('Save') ]),
					E('div', { 'class': 'cbi-value-description' },
						_('How lpac reaches the eSIM chip. "Auto" picks AT for serial modems (FM350) and QMI/MBIM for modems driven over cdc-wdm. Set QMI/MBIM manually for Qualcomm modems (T99W175 / MV31-W / DW5930e) whose eUICC is not reachable over AT.')),
				]),
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('eUICC slot') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					slotSel,
					E('button', {
						'class': 'btn cbi-button cbi-button-save',
						'style': 'margin-left:8px',
						'click': ui.createHandlerFn(this, function() {
							return fs.exec_direct(ESIM, [ 'setslot', slotW.getValue() ]).then(function() {
								ui.addNotification(null,
									E('p', _('eUICC slot saved — refresh the profile list')), 'info');
							});
						})
					}, [ _('Save') ]),
					E('div', { 'class': 'cbi-value-description' },
						_('Which SIM slot holds the eSIM chip. "Auto" follows the slot that is currently active in the modem. Set it explicitly if the profile list stays empty while the chip is readable — e.g. a removable eSIM in slot 1.')),
				]),
			]),
		]);
	},

	_etaKey: function() {
		var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || 'x';
		return '5gm-esim-eta-' + String(p).replace(/[^A-Za-z0-9]/g, '_');
	},
	_etaGet: function() {
		var v = 0;
		try { v = parseInt(window.localStorage.getItem(this._etaKey()), 10) || 0; } catch (e) {}
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

	_reloadOnce: function() {
		var self = this;
		if (self._reloadP) { return self._reloadP; }
		self._reloadP = Promise.resolve(self.reload()).finally(function() { self._reloadP = null; });
		return self._reloadP;
	},

	reload: function(tries) {
		var self = this;
		tries = (typeof tries === 'number') ? tries : 0;
		var meta = document.getElementById('esim-meta');
		var warm = !!document.querySelector('#esim-profiles .esim-row');
		if (meta && !warm) {
			meta.innerHTML = '';
			self._waitBarStart(meta);
			meta.appendChild(E('div', { 'class': 'esim-wait-note' },
				_('Please wait, reading eUICC - updating the profile list can be slow')));
		}
		if (meta && warm && !document.getElementById('esim-updating')) {
			self._waitBarStart(meta);
			meta.appendChild(E('div', {
				'id': 'esim-updating', 'class': 'esim-wait-note'
			}, _('Updating the profile list...')));
		}
		return esimExec([ 'dump' ]).then(function(d) {
			var chip = d.chip || {}, profs = d.profiles || {};
			if (!lpaOk(chip) && !lpaOk(profs)) {
				var _isBusy = (lpaMsg(chip) === 'busy' || lpaMsg(profs) === 'busy');
				if (tries < 5 || (_isBusy && tries < 15)) {
					return new Promise(function(resolve) {
						window.setTimeout(function() { resolve(self.reload(tries + 1)); }, 4000);
					});
				}
				self._waitBarStop();
				var _up = document.getElementById('esim-updating');
				if (_up) { _up.parentNode.removeChild(_up); }
				if (meta && !warm) {
					meta.innerHTML = '';
					var _m = lpaMsg(chip) || lpaMsg(profs);
					if (_m === 'uplink busy') {
						meta.appendChild(E('span', { 'style': 'opacity:.8' },
							_('The modem control channel is busy with the active connection, so the profile list cannot be read right now. Disconnect the modem interface (or switch to another SIM) to manage profiles.')));
					} else {
						meta.appendChild(E('span', { 'style': 'color:#d95c5c' },
							[ _('eUICC is not responding (%s). Try Refresh in a few seconds.').format(_m) ]));
					}
				}
				return;
			}
			self._waitBarStop(true);
			applyDump(d);
			fetchNotifications().then(renderNotifications);
			if (modemtabs.refreshEsimTab) { modemtabs.refreshEsimTab(); }
		});
	},

	download: function() {
		var inp = document.getElementById('esim-code');
		var code = inp ? String(inp.value || '').trim() : '';
		if (!code) { return; }
		var self = this;
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

	_pollProgress: function(box) {
		var self = this;
		if (!self._dlActive) { return; }
		if (document.hidden || (box && box.isConnected === false)) {
			window.setTimeout(function() { self._pollProgress(box); }, 1200);
			return;
		}
		L.resolveDefault(fs.exec_direct(ESIM, [ 'progress' ]), '').then(function(out) {
			var s = out || '';
			if (s.indexOf('"type":"progress"') >= 0 || !self._dlLog) {
				if (s.indexOf('"message":"busy"') < 0) { self._dlLog = s; }
			}
			if (box && self._dlActive) {
				var lines = self._dlLog.split('\n').filter(function(l) { return l.indexOf('"progress"') > 0; });
				var last = lines[lines.length - 1];
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

	_saveLog: function() {
		var blob = new Blob([ this._dlLog || '' ], { type: 'text/plain' });
		var a = E('a', {
			'href': URL.createObjectURL(blob),
			'download': 'esim-download-' + Math.floor(Date.now() / 1000) + '.log'
		});
		document.body.appendChild(a); a.click();
		window.setTimeout(function() { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
	},

	_loadJsQR: function() {
		if (window.jsQR) { return Promise.resolve(window.jsQR); }
		if (this._jsqrPromise) { return this._jsqrPromise; }
		this._jsqrPromise = new Promise(function(resolve) {
			// see docs/subsystems/esim.md#qr-decoding
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

	_decodeQR: function(file) {
		var self = this;
		var fin = document.getElementById('esim-qr-file');
		if (!file) { return; }
		self._loadJsQR().then(function(jsqr) {
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
		var pollResult = function(tries) {
			return L.resolveDefault(fs.exec_direct(ESIM, [ 'download-status' ]), '').then(function(out) {
				var s = String(out || '');
				if (s.indexOf('"dlstate"') >= 0 || !s.trim()) {
					if (tries > 260) { return '{"type":"lpa","payload":{"code":-1,"message":"timeout","data":""}}'; }
					return new Promise(function(resolve) {
						window.setTimeout(function() { resolve(pollResult(tries + 1)); }, 2500);
					});
				}
				return s;
			});
		};
		var dl = L.resolveDefault(fs.exec_direct(ESIM, [ 'progress', 'reset' ]), '')
			.then(function() {
				self._pollProgress(box);
				return fs.exec_direct(ESIM, [ 'download-bg', code ]);
			})
			.then(function() { return pollResult(0); });
		var showFail = function(human, tech) {
			self._dlActive = false;
			ui.showModal(_('Add eSIM profile'), [
				E('div', { 'class': 'esim-modal' }, [
					E('div', { 'class': 'esim-dlrow' }, [
						esimSimIcon('esim-simicon esim-simicon-err'),
						E('div', { 'class': 'esim-h' }, _('Download failed')),
					]),
					E('div', { 'class': 'esim-d' }, [ human || _('The download did not complete.') ]),
					tech ? E('div', { 'class': 'esim-log' }, [ tech ]) : '',
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
				var p = (j && j.payload) || {};
				var raw = (typeof p.data === 'string') ? p.data.trim() : '';
				var tech = (p.message || '?') + (raw ? (' · ' + raw) : '');
				var tr = (self._dlLog || '').split('\n').filter(function(l) {
					return l.indexOf('"transport":"failed"') > 0;
				}).pop();
				var why = tr && tr.match(/"why":"([^"]*)"/);
				if (why && why[1]) {
					var msg = _('Could not reach the operator server: %s').format(why[1].trim());
					if ((self._dlLog || '').indexOf('wget-ssl') > 0)
						msg += ' — ' + _('If this repeats, install the wget-ssl package (apk add wget-ssl): some operator servers use TLS that curl on this router cannot handle');
					showFail(msg, tech);
					return;
				}
				showFail(esimFailHuman(p.message, raw), tech);
				return;
			}
			if (inp) { inp.value = ''; }
			ui.hideModal();
			modemtabs.setBusy('#esim-section',
				_('Profile added. The modem is restarting to apply it - up to a minute…'), 240000, 90);
			if (!(j && j.payload && j.payload.reset == 1)) {
				L.resolveDefault(fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]), null);
			}
			L.resolveDefault(fs.exec(ESIM, [ 'reapply' ]), null);
			_waitModemBack(240000).then(function() {
				modemtabs.clearBusy();
				notify(true, _('eSIM profile added and applied'), null);
				self.reload(-3);
			}).catch(function() {
				modemtabs.clearBusy(); self.reload(-3);
			});
		}).catch(function(e) {
			showFail(_('The download did not complete.'),
				(e && e.message) ? ('error: ' + e.message) : '');
		});
	},
});

function _waitModemBack(maxMs) {
	var t0 = Date.now();
	var gone = false;
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
				if (present && (gone || el > 90000)) { return true; }
				if (el > maxMs) { return false; }
				return new Promise(function(r) { window.setTimeout(function() { r(step()); }, 3000); });
			});
		};
		return step();
	});
};

function _viewReload(tries, maxTries) {
	tries = (typeof tries === 'number') ? tries : 0;
	return esimExec([ 'dump' ]).then(function(d) {
		if (lpaOk(d.profiles || {})) { renderProfiles(d.profiles.payload.data || []); return true; }
		var lim = (typeof maxTries === 'number') ? maxTries : 4;
		if (tries < lim) {
			return new Promise(function(resolve) {
				window.setTimeout(function() { _viewReload(tries + 1, lim).then(resolve); }, 3000);
			});
		}
		return false;
	});
};

function applyDump(d) {
	var chip = (d && d.chip) || {}, profs = (d && d.profiles) || {};
	var meta = document.getElementById('esim-meta');
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
		var pid = /^[0-9A-Fa-f]{32}$/.test(p.isdpAid || '') ? p.isdpAid : p.iccid;
		var btns = [];
		if (on) {
			btns.push(E('button', { 'class': 'btn cbi-button',
				'click': function(ev) { ev.preventDefault(); esimOp('disable', pid, name); } }, [ _('Disable') ]));
		} else {
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-action',
				'click': function(ev) { ev.preventDefault(); esimOp('enable', pid, name); } }, [ _('Enable') ]));
			btns.push(E('button', { 'class': 'btn cbi-button cbi-button-remove',
				'click': function(ev) { ev.preventDefault(); esimDeleteConfirm(pid, name, p.iccid); } }, [ _('Delete') ]));
		}
		tbl.appendChild(E('tr', { 'class': 'tr esim-row' }, [
			E('td', { 'class': 'td left' }, [
				E('span', { 'class': 'esim-op' }, [
					E('img', { 'src': mutil.icon(on ? 'icons/5gmodem/csim_active.svg' : 'icons/5gmodem/csim_iface.svg'), 'alt': '' }),
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

function fetchNotifications() {
	return fs.exec_direct(ESIM, [ 'notifications' ]).then(function(out) {
		var j = parseLpa(out);
		return (lpaOk(j) && j.payload && Array.isArray(j.payload.data)) ? j.payload.data : [];
	}).catch(function() { return []; });
}
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
				E('span', { 'class': 'esim-notif-op' }, [ op ]), ' \u00b7 ',
				E('span', { 'style': 'font-family:monospace' }, [ n.iccid || '-' ]),
				host ? E('div', { 'class': 'esim-notif-host' }, [ host ]) : ''
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
	modemtabs.setBusy('#esim-section', _('Applying eSIM operation...'), 60000, 15);
	var attempt = function(tries) {
	fs.exec_direct(ESIM, [ verb, iccid ]).then(function(out) {
		var j = parseLpa(out);
		var ok = lpaOk(j);
		if (!ok && lpaMsg(j) === 'busy' && tries < 12) {
			window.setTimeout(function() { attempt(tries + 1); }, 2000);
			return;
		}
		if (ok && (verb == 'enable' || verb == 'disable')) {
			modemtabs.setBusy('#esim-section', verb == 'enable'
				? _('Profile enabled. The modem is restarting to apply it - up to a minute…')
				: _('Profile disabled. The modem is restarting to apply it - up to a minute…'),
				300000, 90);
			if (!(j && j.payload && j.payload.reset == 1)) {
				L.resolveDefault(fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'hard' ]), null);
			}
			L.resolveDefault(fs.exec(ESIM, [ 'reapply' ]), null);
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
				L.resolveDefault(fs.exec_direct(ESIM, [ 'recheck' ]), '')
					.then(function() { return _viewReloadFor(120000); })
					.then(function(done) {
						var up = document.getElementById('esim-updating');
						if (up) { up.parentNode.removeChild(up); }
						if (!done) {
							notify(false, null, _('Could not refresh the list automatically. Press Refresh in a few seconds.'));
						}
						if (verb == 'enable') { proposeApnAfterEnable(); }
					});
			}).catch(function() { modemtabs.clearBusy(); });
			return;
		}
		notify(ok, _('eSIM operation done'), _('eSIM operation failed: %s').format(lpaFail(j)));
		if (ok) {
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

function esimDeleteConfirm(id, name, iccid) {
	ui.showModal(_('Delete eSIM profile'), [
		E('p', [ _('Delete profile "%s" (%s)? This cannot be undone.').format(name, iccid || id) ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn', 'click': ui.hideModal }, [ _('Cancel') ]),
			' ',
			E('button', { 'class': 'btn cbi-button-remove',
				'click': function() { ui.hideModal(); esimOp('delete', id, name); } }, [ _('Delete') ]),
		]),
	]);
}
