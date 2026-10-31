'use strict';
'require dom';
'require form';
'require fs';
'require ui';
'require uci';
'require view';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';
'require sms-tool-5gm.editors as editors';
'require sms-tool-5gm.smssettings as smssettings';
'require view.modem5g.fresh as fresh';

/*
	Copyright 2022-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/

function ussdCtrlScore(s) {
	var n = 0;
	for (var i = 0; i < s.length; i++) {
		var c = s.charCodeAt(i);
		if (c === 0xFFFD || (c < 0x20 && c !== 0x0A && c !== 0x0D && c !== 0x09)) { n++; }
	}
	return n;
}

function ussdUcs2(bytes, little) {
	var s = '';
	for (var i = 0; i + 1 < bytes.length; i += 2) {
		s += String.fromCharCode(little ? (bytes[i] | (bytes[i + 1] << 8))
		                                : ((bytes[i] << 8) | bytes[i + 1]));
	}
	return s;
}

function ussdGsm7(bytes) {
	var s = '', carry = 0, bits = 0;
	for (var i = 0; i < bytes.length; i++) {
		carry |= bytes[i] << bits;
		bits += 8;
		while (bits >= 7) {
			var c = carry & 0x7F;
			carry >>= 7; bits -= 7;
			if (!(c === 0 && bits < 7 && i === bytes.length - 1)) { s += String.fromCharCode(c); }
		}
	}
	return s;
}

function ussdDecodeHex(hex, dcs) {
	hex = String(hex || '').replace(/\s+/g, '');
	if (!hex.length || (hex.length % 2) || !/^[0-9A-Fa-f]+$/.test(hex)) { return null; }
	var b = [];
	for (var i = 0; i < hex.length; i += 2) { b.push(parseInt(hex.substr(i, 2), 16)); }

	var evenLen = (b.length % 2) === 0;
	var hiEven = 0, hiOdd = 0;
	for (var i = 0; i < b.length; i++) {
		if (b[i] <= 0x07) { if (i % 2) { hiOdd++; } else { hiEven++; } }
	}
	var half = b.length / 2;
	var little = hiOdd > hiEven;
	var ucs2ByDcs = (dcs != null) && ((dcs & 0x0C) === 0x08);
	var gsm7ByDcs = (dcs != null) && ((dcs & 0x0C) !== 0x08);
	var ucs2ByShape = evenLen && (Math.max(hiEven, hiOdd) >= Math.ceil(half * 0.8));

	if (evenLen && (ucs2ByDcs || (dcs == null && ucs2ByShape))) {
		return ussdUcs2(b, little);
	}
	if (gsm7ByDcs) {
		var g = ussdGsm7(b);
		var a = String.fromCharCode.apply(null, b);
		return (ussdCtrlScore(g) <= ussdCtrlScore(a)) ? g : a;
	}
	return String.fromCharCode.apply(null, b);
}

function ussdReadReply(stdout) {
	var txt = String(stdout || '');
	var m = txt.match(/\+CUSD:\s*(\d+)\s*,\s*"([^"]*)"\s*,\s*(\d+)/);
	if (m) {
		var d = ussdDecodeHex(m[2], parseInt(m[3], 10));
		return (d != null) ? d : m[2];
	}
	var only = txt.replace(/^\s*debug:.*$/gm, '').replace(/\s+/g, '');
	if (only.length >= 8 && !(only.length % 2) && /^[0-9A-Fa-f]+$/.test(only)) {
		var d = ussdDecodeHex(only, null);
		if (d != null && d.length && ussdCtrlScore(d) === 0) { return d; }
	}
	return null;
}

function typewrite(el, text) {
	el.classList.add('has-output');
	if (el._twTimer) { clearInterval(el._twTimer); el._twTimer = null; }
	if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
		el.textContent = text;
		return;
	}
	el._twText = text;
	el.textContent = '';
	var i = 0, n = text.length;
	var step = Math.max(1, Math.ceil(n / 90));
	el._twTimer = setInterval(function() {
		if (i >= n) { clearInterval(el._twTimer); el._twTimer = null; return; }
		el.textContent += text.slice(i, i + step);
		i += step;
		el.scrollTop = el.scrollHeight;
	}, 28);
}

var ussdW = null;
var ussdSelf = null;

function ussdFill(content) {
	var host = document.getElementById('tk');
	if (!host) { return; }
	var ch = {}, order = [];
	(content || '').trim().split('\n').forEach(function(cmd) {
		if (!cmd.trim()) { return; }
		var fields = cmd.split(/;/);
		var code = fields[1] || fields[0];
		if (!code) { return; }
		ch[code] = fields[0] || code;
		order.push(code);
	});
	ussdW = new ui.Dropdown('', ch, {
		id: 'tk', sort: order, optional: true, select_placeholder: '\u2014'
	});
	var n = ussdW.render();
	n.classList.add('tg-field');
	if (ussdSelf) {
		n.addEventListener('cbi-dropdown-change', ui.createHandlerFn(ussdSelf, 'handleCopy'));
	}
	host.parentNode.replaceChild(n, host);
}

return view.extend({
	viewName: 'sendussd',
	
	restoreSettingsFromLocalStorage: function() {
		try {
			let selectedFile = localStorage.getItem('luci-app-' + this.viewName + '-selectedFile');
			return selectedFile;
		} catch(e) {
			console.error('localStorage not available:', e);
			return null;
		}
	},
	
	saveSettingsToLocalStorage: function(fileName) {
		try {
			localStorage.setItem('luci-app-' + this.viewName + '-selectedFile', fileName);
		} catch(e) {
			console.error('localStorage not available:', e);
		}
	},
	
	handleCommand: function(exec, args, prefetched) {
		let buttons = document.querySelectorAll('.cbi-button');

		for (let i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');

		return (prefetched ? Promise.resolve(prefetched) : fs.exec(exec, args)).then(function(res) {
			let out = document.querySelector('.ussdcommand-output');
			let fullhistory = document.getElementById('history-full')?.checked;
			let reversereplies = document.getElementById('reverse-replies')?.checked;
			out.style.display = '';

			res.stdout = res.stdout?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';
			res.stderr = res.stderr?.replace(/^(?=\n)$|^\s*|\s*$|\n\n+/gm, "") || '';

			if (exec == 'mmcli' || exec == '/usr/bin/mmcli') {
				let mm = (res.stdout || '').match(/(?:reply|request) from network:\s*'([\s\S]+)'/) ||
					(res.stdout || '').match(/(?:reply from network|response)[^']*'([\s\S]+)'/) ||
					(res.stdout || '').match(/'([\s\S]+)'/);
				if (mm && mm[1]) {
					res.stdout = mm[1];
					res.stderr = '';
				}
			}

			if (exec == 'sms_tool' && uci.get('5gmodem', 'sms', 'pdu') != '1') {
				let dec = ussdReadReply(res.stdout);
				if (dec != null && dec.trim())
					res.stdout = dec;
				else
					res.stdout = (res.stdout || '').replace(/^\s*debug:.*$/gm, '').trim();
			}

			if (res.stdout === undefined || res.stderr === undefined || res.stderr.includes('undefined') || res.stdout.includes('undefined')) {
				return;
			} else {
				let cut = res.stderr;
				if ( cut.length > 2 ) {
					if (cut.includes('error: 0'))
						res.stdout = _('Phone/Modem failure');
					if (cut.includes('error: 1'))
						res.stdout = _('No connection to phone');
					if (cut.includes('error: 2'))
						res.stdout = _('Phone/Modem adapter link reserved');
					if (cut.includes('error: 3'))
						res.stdout = _('Operation not allowed');
					if (cut.includes('error: 4'))
						res.stdout = _('Operation not supported');
					if (cut.includes('error: 5'))
						res.stdout = _('PH_SIM PIN required');
					if (cut.includes('error: 6'))
						res.stdout = _('PH_FSIM PIN required');
					if (cut.includes('error: 7'))
						res.stdout = _('PH_FSIM PUK required');
					if (cut.includes('error: 10'))
						res.stdout = _('SIM not inserted');
					if (cut.includes('error: 11'))
						res.stdout = _('SIM PIN required');
					if (cut.includes('error: 12'))
						res.stdout = _('SIM PUK required');
					if (cut.includes('error: 13'))
						res.stdout = _('SIM failure');
					if (cut.includes('error: 14'))
						res.stdout = _('SIM busy');
					if (cut.includes('error: 15'))
						res.stdout = _('SIM wrong');
					if (cut.includes('error: 16'))
						res.stdout = _('Incorrect password');
					if (cut.includes('error: 17'))
						res.stdout = _('SIM PIN2 required');
					if (cut.includes('error: 18'))
						res.stdout = _('SIM PUK2 required');
					if (cut.includes('error: 20'))
						res.stdout = _('Memory full');
					if (cut.includes('error: 21'))
						res.stdout = _('Invalid index');
					if (cut.includes('error: 22'))
						res.stdout = _('Not found');
					if (cut.includes('error: 23'))
						res.stdout = _('Memory failure');
					if (cut.includes('error: 24'))
						res.stdout = _('Text string too long');
					if (cut.includes('error: 25'))
						res.stdout = _('Invalid characters in text string');
					if (cut.includes('error: 26'))
						res.stdout = _('Dial string too long');
					if (cut.includes('error: 27'))
						res.stdout = _('Invalid characters in dial string');
					if (cut.includes('error: 30'))
						res.stdout = _('No network service') + '\n' +
							_('USSD works over the circuit-switched channel. If the modem is registered in LTE only, switch it to 3G on the frequency-management page and repeat the request.');
					if (cut.includes('error: 31'))
						res.stdout = _('Network timeout');
					if (cut.includes('error: 32'))
						res.stdout = _('Network not allowed, emergency calls only');
					if (cut.includes('error: 40'))
						res.stdout = _('Network personalization PIN required');
					if (cut.includes('error: 41'))
						res.stdout = _('Network personalization PUK required');
					if (cut.includes('error: 42'))
						res.stdout = _('Network subset personalization PIN required');
					if (cut.includes('error: 43'))
						res.stdout = _('Network subset personalization PUK required');
					if (cut.includes('error: 44'))
						res.stdout = _('Service provider personalization PIN required');
					if (cut.includes('error: 45'))
						res.stdout = _('Service provider personalization PUK required');
					if (cut.includes('error: 46'))
						res.stdout = _('Corporate personalization PIN required');
					if (cut.includes('error: 47'))
						res.stdout = _('Corporate personalization PUK required');
					if (cut.includes('error: 48'))
						res.stdout = _('PH-SIM PUK required');
					if (cut.includes('error: 100'))
						res.stdout = _('Unknown error');
					if (cut.includes('error: 103'))
						res.stdout = _('Illegal MS');
					if (cut.includes('error: 106'))
						res.stdout = _('Illegal ME');
					if (cut.includes('error: 107'))
						res.stdout = _('GPRS services not allowed');
					if (cut.includes('error: 111'))
						res.stdout = _('PLMN not allowed');
					if (cut.includes('error: 112'))
						res.stdout = _('Location area not allowed');
					if (cut.includes('error: 113'))
						res.stdout = _('Roaming not allowed in this location area');
					if (cut.includes('error: 126'))
						res.stdout = _('Operation temporary not allowed');
					if (cut.includes('error: 132'))
						res.stdout = _('Service operation not supported');
					if (cut.includes('error: 133'))
						res.stdout = _('Requested service option not subscribed');
					if (cut.includes('error: 134'))
						res.stdout = _('Service option temporary out of order');
					if (cut.includes('error: 148'))
						res.stdout = _('Unspecified GPRS error');
					if (cut.includes('error: 149'))
						res.stdout = _('PDP authentication failure');
					if (cut.includes('error: 150'))
						res.stdout = _('Invalid mobile class');
					if (cut.includes('error: 256'))
						res.stdout = _('Operation temporarily not allowed');
					if (cut.includes('error: 257'))
						res.stdout = _('Call barred');
					if (cut.includes('error: 258'))
						res.stdout = _('Phone/Modem is busy');
					if (cut.includes('error: 259'))
						res.stdout = _('User abort');
					if (cut.includes('error: 260'))
						res.stdout = _('Invalid dial string');
					if (cut.includes('error: 261'))
						res.stdout = _('SS not executed');
					if (cut.includes('error: 262'))
						res.stdout = _('SIM Blocked');
					if (cut.includes('error: 263'))
						res.stdout = _('Invalid block');
					if (cut.includes('error: 527'))
						res.stdout = _('Please wait, and retry your selection later (Specific Modem Sierra)');
					if (cut.includes('error: 528'))
						res.stdout = _('Location update failure – emergency calls only (Specific Modem Sierra)');
					if (cut.includes('error: 529'))
						res.stdout = _('Selection failure – emergency calls only (Specific Modem Sierra)');
					if (cut.includes('error: 772'))
						res.stdout = _('SIM powered down');
					    var _ut1 = (res.stderr || '') + (res.stdout ? ' > ' + res.stdout : '');
					    typewrite(out, _ut1.trim() ? _ut1 : _('No response from modem'));
				    } else {
						if ( fullhistory ) {
    						    const ussdreply = (res.stdout + res.stderr).replace(/^\s*\n+/g, '');
							    let ussdv = document.getElementById('cmdvalue');
							    ussdv.value = '';
							    document.getElementById('cmdvalue').focus();
    							if (reversereplies) {
        							out.innerText = ussdreply + (out.innerText.trim() ? '\n\n' + out.innerText : '');
    							} else {
        							out.innerText += '\n\n' + res.stdout + res.stderr;
				            		out.innerText = out.innerText.replace(/^\s*\n+/g, '');
						        }
				        } else {
				            	var _ut2 = (res.stdout || '') +
				            		((res.stderr && res.stdout) ? '\n' : '') + (res.stderr || '');
				            	typewrite(out, _ut2.trim() ? _ut2 : _('No response from modem'));
				        }
				    }
			}
		}).catch(function(err) {
			ui.addNotification(null, E('p', [ err ]));
		}).finally(function() {
			for (let i = 0; i < buttons.length; i++)
				buttons[i].removeAttribute('disabled');
		});
	},

	handleUssdScript: function(code) {
		var self = this;
		var out = document.querySelector('.ussdcommand-output');
		var buttons = document.querySelectorAll('.cbi-button');
		var STAGES = {
			starting: _('Preparing the request…'),
			switching: _('Switching the modem to 3G - USSD needs the circuit-switched channel'),
			sending:   _('Sending the request'),
			restoring: _('Restoring the previous network mode')
		};

		for (var i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');
		var lastStage = null;
		var keepHistory = !!(document.getElementById('history-full') || {}).checked;
		var baseText = (out && keepHistory) ? out.innerText : '';
		var say = function(text) {
			if (!out) { return; }
			out.style.display = '';
			if (keepHistory) {
				if (out._twTimer) { clearInterval(out._twTimer); out._twTimer = null; }
				out.classList.add('has-output');
				out.textContent = baseText + (baseText.trim() ? '\n\n' : '') + text;
			} else {
				typewrite(out, text);
			}
		};
		var stopStage = function() {
			if (!out) { return; }
			if (out._twTimer) { clearInterval(out._twTimer); out._twTimer = null; }
			if (keepHistory) { out.textContent = baseText; }
		};
		if (out) { out.style.display = ''; }
		say(_('Sending the request') + '…');

		var done = function() {
			for (var i = 0; i < buttons.length; i++)
				buttons[i].removeAttribute('disabled');
		};

		return fs.exec('/usr/share/5gmodem/ussd.sh', [ 'send', code ]).then(function(r) {
			var j = {};
			try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			if (j.error) {
				done();
				stopStage();
				say(_('The request was rejected: %s').format(String(j.error)));
				return null;
			}
			return new Promise(function(resolve) {
				var left = 60, timer = null;
				var inflight = false;
				var tick = function() {
					if (inflight) { return; }
					inflight = true;
					L.resolveDefault(fs.exec('/usr/share/5gmodem/ussd.sh', [ 'status' ]), {}).then(function(r) {
						inflight = false;
						var st = {};
						try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
						if (st.status === 'running' || !st.status) {
							if (STAGES[st.stage] && st.stage !== lastStage) {
								lastStage = st.stage;
								say(STAGES[st.stage] + '…');
							}
							if (--left > 0) { return; }
						}
						if (timer) { clearInterval(timer); timer = null; }
						self._ussdTimer = null;
						resolve(st);
					});
				};
				timer = setInterval(tick, 2000);
				self._ussdTimer = timer;
				tick();
			});
		}).then(function(st) {
			if (!st) { return; }
			done();
			stopStage();
			if (st.status === 'done') {
				var dec = function(b) { try { return b ? atob(b) : ''; } catch (e) { return ''; } };
				var body = dec(st.out);
				if (!body.trim()) {
					if (st.unsupported) {
						say(_('This modem does not answer USSD requests: its firmware has no SS support. Verified on real hardware.'));
						return;
					}
					if (st.noswitch === 'not_active') {
						say(_('No reply. The request went to a modem that is not the active one, so it was not switched to 3G - and USSD needs the circuit-switched channel. Select this modem and repeat.'));
						return;
					}
				}
				return self.handleCommand('sms_tool', null,
					{ stdout: body, stderr: dec(st.err) });
			}
			say((st.status === 'error' && st.reason === 'no_3g')
				? _('Could not switch the modem to 3G, so the request was not sent: USSD needs the circuit-switched channel.')
				: _('No response from modem'));
		}).catch(function(err) {
			done();
			ui.addNotification(null, E('p', [ err ]));
		});
	},

	handleFileChange: function(ev) {
		let selectedFile = ev.target.value;
		let selectElement = document.getElementById('tk');
		
		if (!selectElement || !selectedFile) return;
		
		this.saveSettingsToLocalStorage(selectedFile);
		
		return fs.read_direct('/etc/5gmodem/modem/ussdcodes/' + selectedFile).then(function(content) {
			ussdFill(content);

			let cmdInput = document.getElementById('cmdvalue');
			if (cmdInput) cmdInput.value = '';
		}).catch(function(err) {
			console.error('Error loading USSD file:', err);
			ui.addNotification(null, E('p', [ _('Error loading USSD codes file:') + ' ' + selectedFile ]), 'error');
		});
	},

	getMMModemNumber: function() {
		return fs.exec('/usr/bin/mmcli', [ '--timeout=8', '-L' ]).then(function(res) {
			let out = ((res.stdout || '') + '\n' + (res.stderr || '')).trim();
			let ids = [], re = /\/Modem\/(\d+)/g, mm;
			while ((mm = re.exec(out)) !== null) { ids.push(mm[1]); }
			if (!ids.length)
				return Promise.reject(_('No modems found by ModemManager (mmcli -L)'));
			if (ids.length === 1)
				return ids[0];
			return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), {}).then(function(ar) {
				var act = ((ar && ar.stdout) || '').trim();
				if (ids.indexOf(act) >= 0)
					return act;
				var rank = { connected: 4, registered: 3, searching: 2, enabled: 1 };
				return Promise.all(ids.map(function(id) {
					return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', id, '--timeout=8', '-K' ]), {}).then(function(r) {
						var s = (((r && r.stdout) || '').match(/generic\.state\s*:\s*(\S+)/) || [])[1] || '';
						return { id: id, r: (rank[s] || 0) };
					});
				})).then(function(list) {
					list.sort(function(a, b) { return b.r - a.r; });
					return list[0].id;
				});
			});
		});
	},

	getProxyModemNumber: function() {
		var ready = { enabled: 1, searching: 1, registered: 1, connecting: 1, connected: 1, disconnecting: 1 };
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), {}).then(function(res) {
			var id = ((res && res.stdout) || '').trim();
			if (!/^\d+$/.test(id))
				return null;
			return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', id, '--timeout=8', '-K' ]), {}).then(function(r) {
				var s = (((r && r.stdout) || '').match(/generic\.state\s*:\s*(\S+)/) || [])[1] || '';
				return ready[s] ? id : null;
			});
		});
	},

	mmUssd: function(modemNum, mode, code) {
		var self = this;
		var buttons = document.querySelectorAll('.cbi-button');
		for (var i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');
		var dec = function(b) { try { return b ? atob(b) : ''; } catch (e) { return ''; } };
		return fs.exec('/usr/share/5gmodem/ussd.sh', [ 'mm', modemNum, mode, code ]).then(function(r) {
			var j = {};
			try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
			if (j.error)
				return { stdout: '', stderr: _('The request was rejected: %s').format(String(j.error)) };
			return new Promise(function(resolve) {
				var left = 60, inflight = false, timer = null;
				var tick = function() {
					if (inflight) { return; }
					inflight = true;
					L.resolveDefault(fs.exec('/usr/share/5gmodem/ussd.sh', [ 'status' ]), {}).then(function(r) {
						inflight = false;
						var st = {};
						try { st = JSON.parse((r && r.stdout) || '{}'); } catch (e) {}
						if (st.status === 'running' && --left > 0) { return; }
						if (timer) { clearInterval(timer); timer = null; }
						self._ussdTimer = null;
						resolve(st.status === 'done' ? { stdout: dec(st.out), stderr: dec(st.err) } : { stdout: '', stderr: '' });
					});
				};
				timer = setInterval(tick, 2000);
				self._ussdTimer = timer;
				tick();
			});
		});
	},

	handleGo: function(ev) {
		let ussd = document.getElementById('cmdvalue').value;
		let port = uci.get('5gmodem', 'sms', 'ussdport');
		let get_via_mm = uci.get('5gmodem', 'sms', 'ussd_via_mm');
		let via_proxy = false;
		if (get_via_mm == '1') {
			var _amp = uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '';
			var _ams = 'm_' + _amp.replace(/[^A-Za-z0-9]/g, '_');
			var _amif = uci.get('5gmodem', _ams, 'network') ||
				uci.get('5gmodem', '@5gmodem[0]', 'network');
			var _ampr = _amif ? uci.get('network', _amif, 'proto') : null;
			if (mutil.isSharedProxyProto(_ampr)) {
				via_proxy = true;
			}
			else if (_amif && !mutil.isMMProto(_ampr)) {
				get_via_mm = '0';
			}
		}

		if ( ussd.length < 1 ) {
			ui.addNotification(null, E('p', _('Please specify the code to send')), 'info');
			return false;
		}

		if (get_via_mm == '1') {
			let self = this;
			return (via_proxy ? this.getProxyModemNumber() : this.getMMModemNumber())
				.then(function(modemNum) {
					if (modemNum == null) {
						if (!port) {
							ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
							return false;
						}
						return self.handleUssdScript(ussd);
					}
					var mode = self.ussdSessionActive ? 'respond' : 'initiate';
					return (!self.ussdSessionActive
							? L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', modemNum, '--timeout=10', '--3gpp-ussd-cancel' ]), {})
							: Promise.resolve())
						.then(function() { return self.mmUssd(String(modemNum), mode, ussd); })
						.then(function(res) {
							self._ussdFailed = !!(res && res.stderr && !res.stdout);
							return self.handleCommand('/usr/bin/mmcli', [], res);
						})
						.then(function() {
						return L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', modemNum, '--timeout=10', '--3gpp-ussd-status' ]), {}).then(function(r) {
							self.ussdSessionActive = !self._ussdFailed && /status:\s*(?:user-response|active)/.test((r && r.stdout) || '');
							self.ussdModemNum = modemNum;
							var out = document.querySelector('.ussdcommand-output');
							if (self.ussdSessionActive && out) {
								if (out._twTimer) {
									clearInterval(out._twTimer);
									out._twTimer = null;
									out.textContent = out._twText || out.textContent;
								}
								out.innerText = (out.innerText || '') + '\n\n' + _('USSD session is active — type your reply and press Send');
							}
						});
					});
				})
				.catch(function(err) {
					ui.addNotification(null, E('p', [ _('Failed to detect modem:') + ' ' + String(err) ]), 'danger');
				});
		}

		if ( !port ) {
			ui.addNotification(null, E('p', _('Please set the port for communication with the modem')), 'info');
			return false;
		}

		return this.handleUssdScript(ussd);
	},

	handleClear: function(ev) {
		let out = document.querySelector('.ussdcommand-output');
		out.style.display = '';
		out.style.display = 'none';

		let fullhistory = document.getElementById('history-full')?.checked;

		if ( fullhistory ) {
		dom.content(out, [ '' ]);
		}

		let ov = document.getElementById('cmdvalue');
		ov.value = '';

		if (this.ussdSessionActive && this.ussdModemNum != null) {
			L.resolveDefault(fs.exec('/usr/bin/mmcli', [ '-m', this.ussdModemNum, '--timeout=8', '--3gpp-ussd-cancel' ]));
			this.ussdSessionActive = false;
		}

		document.getElementById('cmdvalue').focus();
	},

	handleClearOut: function(ev) {
		let out = document.querySelector('.ussdcommand-output');
		let fullhistory = document.getElementById('history-full')?.checked;

		if ( fullhistory ) {
			out.style.display = '';
			out.style.display = 'none';
			dom.content(out, [ '' ]);
			document.getElementById("reverse-replies").disabled = false;
			document.getElementById("reverse-replies").checked = true;
		} else {
			document.getElementById("reverse-replies").disabled = true;
			document.getElementById("reverse-replies").checked = false;
		}
	},

	handleCopy: function(ev) {
		let out = document.querySelector('.ussdcommand-output');
		let fullhistory = document.getElementById('history-full')?.checked;

		if ( !fullhistory ) {
		out.style.display = 'none';
		}

		let ov = document.getElementById('cmdvalue');
		ov.value = '';
		ov.value = ussdW ? String(ussdW.getValue() || '') : '';
	},

	handleModemChange: function(ev) {
		let sections = uci.sections('defmodems', 'defmodems');
		if (!sections || sections.length === 0) return;
		
		let serialModems = sections.filter(function(s) {
			return s.modemdata === 'serial';
		});
		
		if (serialModems.length === 0) return;
		
		let currentPort = uci.get('5gmodem', 'sms', 'ussdport');
		let currentIndex = serialModems.findIndex(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (currentIndex === -1) currentIndex = 0;
		
		let direction = ev.currentTarget.classList.contains('next') ? 1 : -1;
		let newIndex = (currentIndex + direction + serialModems.length) % serialModems.length;
		let newModem = serialModems[newIndex];
		
		if (newModem && newModem.comm_port) {
			uci.set('5gmodem', 'sms', 'ussdport', newModem.comm_port);
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'smsopt', 'ussdport=' + newModem.comm_port ]), null).then(function() {
				let modemText = document.querySelector('.modem-display-text');
				if (modemText) {
					let label = newModem.modem + (newModem.user_desc ? ' (' + newModem.user_desc + ')' : '');
					modemText.textContent = label;
				}
			});
		}
	},

	load: function() {
		var self = this, args = arguments;
		return fresh.check(309091, [ editors, smssettings, modemtabs, mutil ]).then(function() { return self._load5g.apply(self, args); });
	},

	_load5g: function() {

		return Promise.all([
			L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/ussdcodes.user'), null),
			L.resolveDefault(fs.list('/etc/5gmodem/modem/ussdcodes'), []),
			uci.load('5gmodem'),
			L.resolveDefault(uci.load('network')),
			L.resolveDefault(uci.load('defmodems')),
			L.resolveDefault(fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ussdsupport' ]), null)
		]);
	},

	render: function (loadResults) {
		modemtabs.attach();
		var self = this;
		return Promise.resolve(this.renderMain(loadResults)).then(function(main) {
			return smssettings.panel('ussd').then(function(panel) {
				return E([], [ main, panel ]);
			});
		});
	},

	renderMain: function (loadResults) {

	let info = _('User interface for sending USSD codes using sms-tool').format('');

		let sections = uci.sections('defmodems', 'defmodems');
		let serialModems = [];
		
		if (sections && sections.length > 0) {
			serialModems = sections.filter(function(s) {
				return s.modemdata === 'serial';
			});
		}
		
		let currentPort = uci.get('5gmodem', 'sms', 'ussdport');
		let currentModem = serialModems.find(function(s) {
			return s.comm_port === currentPort;
		});
		
		if (!currentModem && serialModems.length > 0) currentModem = serialModems[0];

		let ussdState = (function() {
			try {
				let r = loadResults && loadResults[5];
				return JSON.parse((r && (r.stdout || r)) || '{}');
			} catch (e) { return {}; }
		})();
		let ussdNotSupported = (String(ussdState.supported) === '0');
		let ussdSmsOnly = !ussdNotSupported && (String(ussdState.sms_only) === '1');
		let ussdRat = String(ussdState.rat || '').split('|')[0].trim();
		let ussdCsfb = !ussdNotSupported && !ussdSmsOnly && /^(LTE|5G)/i.test(ussdRat);
		let ussd3gSection = 'm_' + String(uci.get('5gmodem', '@5gmodem[0]', 'active_modem') || '')
			.replace(/[^A-Za-z0-9]/g, '_');

		return E('div', { 'class': 'cbi-map', 'id': 'map' }, [
				ussdNotSupported ? E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, _('USSD does not work on this modem: it is a data-only module without SS support in the firmware. Verified on real hardware - the modem does not answer USSD requests at all.'))
				]) : '',
				ussdSmsOnly ? E('div', { 'class': 'alert-message warning' }, [
					E('p', {}, _('The network registered this SIM for SMS only, so USSD is unavailable right now: it is a voice-domain service. The modem itself supports USSD - requests will simply stay unanswered until the registration changes.'))
				]) : '',
				ussdCsfb ? E('div', { 'class': 'alert-message info' }, [
					E('p', {}, [ (uci.get('5gmodem', ussd3gSection, 'ussd_3g') == '1')
						? _('The modem is registered in %s now, and USSD runs over the circuit-switched channel. The request will therefore switch the modem to 3G and switch it back - the connection drops for about twenty seconds.').format(ussdRat)
						: _('The modem is registered in %s now, and USSD runs over the circuit-switched channel, which LTE does not have. Many modems still answer; if this one stays silent, enable "Switch the modem to 3G for USSD" in the settings below.').format(ussdRat) ])
				]) : '',
				E('div', { 'class': 'cbi-section tgpage' }, [
					E('div', { 'class': 'cbi-section-node' }, [
						(function() {
							if (serialModems.length > 0) {
								let label = currentModem.modem + (currentModem.user_desc ? ' (' + currentModem.user_desc + ')' : '');
								let buttonsDisabled = (serialModems.length > 1) ? null : true;
								
								return E('div', { 'class': 'cbi-value' }, [
									E('label', { 'class': 'cbi-value-title' }, [ _('Select modem') ]),
									E('div', { 'class': 'cbi-value-field' }, [
										E('div', { 'class': 'controls' }, [
											E('div', { 'class': 'pager center tg-row' }, [
												E('button', { 
													'class': 'btn cbi-button-neutral tg-col-narrow prev',
													'aria-label': _('Previous modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'disabled': buttonsDisabled
												}, [ ' ◄ ' ]),
												E('div', { 'class': 'text modem-display-text tg-col-center' }, [ label ]),
												E('button', { 
													'class': 'btn cbi-button-neutral tg-col-narrow next',
													'aria-label': _('Next modem'), 
													'click': ui.createHandlerFn(this, 'handleModemChange'),
													'disabled': buttonsDisabled
												}, [ ' ► ' ])
											])
										])
									])
								]);
							} else {
								return E('div');
							}
						}.bind(this))(),
						(function() {
							let ussdFiles = loadResults[1] || [];
							let userFiles = ussdFiles.filter(function(file) {
								return file.type === 'file' && file.name && file.name.match(/\.user$/);
							});
							
							if (userFiles.length > 0) {
								let savedFile = this.restoreSettingsFromLocalStorage();
								let fileToLoad = userFiles[0].name;
								let checkedIndex = 0;
								
								if (savedFile) {
									let foundIndex = userFiles.findIndex(function(f) {
										return f.name === savedFile;
									});
									if (foundIndex !== -1) {
										fileToLoad = savedFile;
										checkedIndex = foundIndex;
									}
								}
								
								setTimeout(function() {
									L.resolveDefault(fs.read_direct('/etc/5gmodem/modem/ussdcodes/' + fileToLoad), '').then(function(content) {
										ussdFill(content);
									}).catch(function(err) {
										console.error('Error loading initial USSD file:', err);
									});
								}, 100);
								
								return E('div', { 'class': 'cbi-value' }, [
									E('label', { 'class': 'cbi-value-title' }, [ _('Defined USSD code files') ]),
									E('div', { 'class': 'cbi-value-field' }, 
										E('div', {}, 
											userFiles.map(function(file, index) {
												let fileName = file.name;
												let displayName = fileName.replace(/\.user$/, '').toUpperCase();
												
												return E('label', {
													'style': 'margin-right: 15px; display:inline-flex;align-items:center;gap:6px;vertical-align:middle;',
													'data-tooltip': _('Select file with USSD codes to load')
												}, [
													E('input', {
														'type': 'radio',
														'name': 'ussd_file',
														'value': fileName,
														'change': ui.createHandlerFn(this, 'handleFileChange'),
														'checked': index === checkedIndex ? true : null
													}),
													' ',
													displayName
												]);
											}.bind(this))
										)
									)
								]);
							} else {
								return E('div');
							}
						}.bind(this))(),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('User USSD codes') ]),
							E('div', { 'class': 'cbi-value-field' }, [
									(function(self) {
										ussdSelf = self;
										let ussdFiles = loadResults[1] || [];
										let userFiles = ussdFiles.filter(function(file) {
											return file.type === 'file' && file.name && file.name.match(/\.user$/);
										});
										let content = '';
										if (userFiles.length === 0 && loadResults[0]) {
											content = loadResults[0];
										}
										var ch = {}, order = [];
										(content || '').trim().split('\n').forEach(function(cmd) {
											if (!cmd.trim()) { return; }
											let fields = cmd.split(/;/);
											let code = fields[1] || fields[0];
											if (!code) { return; }
											ch[code] = fields[0] || code;
											order.push(code);
										});
										if (!order.length) { ch[''] = _('No USSD codes available'); }
										ussdW = new ui.Dropdown('', ch, {
											id: 'tk', sort: order,
											optional: true, select_placeholder: '\u2014'
										});
										var n = ussdW.render();
										n.classList.add('tg-field');
										n.addEventListener('cbi-dropdown-change',
											ui.createHandlerFn(self, 'handleCopy'));
										return n;
									})(this)
							]) 
						]),
						E('div', { 'class': 'cbi-value' }, [
							E('label', { 'class': 'cbi-value-title' }, [ _('Code to send') ]),
							E('div', { 'class': 'cbi-value-field' }, [
							E('input', {
								'class': 'tg-field',
								'type': 'text',
								'id': 'cmdvalue',
								'data-tooltip': _('Press [Enter] to send the code, press [Ctrl+Delete] to clear the field'),
								'keydown': function(ev) {
									if (ev.keyCode === 13) {
										let execBtn = document.getElementById('execute');
										if (execBtn) {
											execBtn.click();
											}
									}
									if (ev.keyCode === 46 && (ev.ctrlKey || ev.shiftKey)) {
										ev.preventDefault();
										let del = document.getElementById('cmdvalue');
										if (del) {
											let ov = document.getElementById('cmdvalue');
											ov.value = '';
											document.getElementById('cmdvalue').focus();
										}
									}
								}
								}),
							])
						]),

					])
				]),
			E('div', { 'class': 'right tg-ussdopts', 'style': 'margin-bottom: 14px;' }, [
				E('label', { 'class': 'cbi-checkbox', 'style': 'display:inline-flex !important;align-items:center !important;gap:6px;vertical-align:middle;height:auto !important;min-height:0 !important;line-height:1.4;' }, [
					E('input', {
						'id': 'history-full',
						'click': ui.createHandlerFn(this, 'handleClearOut'),
						'data-tooltip': _('Check this option if you need to use the menu built on USSD codes'),
						'type': 'checkbox',
						'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
						'name': 'showhistory',
						'disabled': null
					}),
					E('span', { 'style': 'vertical-align:middle' }, _('Keep the previous reply when sending a new USSD'))
				]),
				E('span', { 'class': 'tg-ussdgap', 'style': 'display:inline-block;width:1.5em' }),
				E('label', { 'class': 'cbi-checkbox', 'style': 'display:inline-flex !important;align-items:center !important;gap:6px;vertical-align:middle;height:auto !important;min-height:0 !important;line-height:1.4;' }, [
					E('input', {
						'id': 'reverse-replies',
						'data-tooltip': _('View new reply from top'),
						'type': 'checkbox',
						'style': 'margin:0;flex:none;vertical-align:middle;position:relative;top:-1px',
						'name': 'reversereplies',
						'disabled': true
					}),
					E('span', { 'style': 'vertical-align:middle' }, _('Newest replies first'))
				])
			]),
				E('div', { 'class': 'right tg-actrow' }, [
					E('button', {
						'class': 'cbi-button',
						'click': ui.createHandlerFn(this, function() {
							new editors.ussdCodesManagerDialog(_('USSD templates')).show();
						})
					}, [ _('USSD templates') ]),
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clr',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear form') ]),
					E('button', {
						'class': 'cbi-button cbi-button-action important',
						'id': 'execute',
						'click': ui.createHandlerFn(this, 'handleGo')
					}, [ _('Send code') ]),
				]),
				E('p', _('Reply')),
				E('pre', { 'class': 'ussdcommand-output', 'style': 'display:none' }),

			]);
	},

	leave: function() {
		if (this._ussdTimer) { clearInterval(this._ussdTimer); this._ussdTimer = null; }
	}
});
