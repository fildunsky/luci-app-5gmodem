'use strict';
'require baseclass';
'require fs';
'require ui';

var HBIN = '/usr/share/5gmodem/health.sh';
var NBIN = '/usr/share/5gmodem/netpri.sh';
var PBIN = '/usr/share/5gmodem/stapark.sh';

return baseclass.extend({
	API: 30906,
	load: function() {
		return Promise.all([
			L.resolveDefault(fs.exec_direct(HBIN, [ 'getconf' ]), '{}'),
			L.resolveDefault(fs.exec_direct(NBIN, [ 'list' ]), '[]')
		]).then(function(res) {
			var c = {}; try { c = JSON.parse(res[0]) || {}; } catch (e) {}
			var arr = []; try { arr = JSON.parse(res[1]) || []; } catch (e) {}
			arr = (Array.isArray(arr) ? arr : []).filter(function(o) {
				return o && o.event == null;
			});
			return { conf: c, uplinks: arr };
		});
	},

	build: function(c, uplinks, opts) {
		var row = function(title, widget, descr) {
			var field = E('div', { 'class': 'cbi-value-field' }, [ widget ]);
			if (descr) {
				field.appendChild(E('div', { 'class': 'cbi-value-description' }, descr));
			}
			var isFlag = widget && widget.classList
				&& widget.classList.contains('cbi-checkbox');
			return E('div', { 'class': 'cbi-value' + (isFlag ? ' tg-flag' : '') }, [
				E('label', { 'class': 'cbi-value-title' }, [ title ]),
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
		var wTgt  = new ui.DynamicList((c.targets || '77.88.8.8 1.1.1.1').split(/ +/)
			.filter(function(t) { return t; }), null, { id: 'hw-tgt' });
		var wFo   = cb(String(c.failover) === '1', 'hw-fo');
		var wFb   = new ui.Dropdown(c.failback === 'demote' ? 'demote' : 'restore', {
			'restore': _('Return its priority'),
			'demote':  _('Keep it last')
		}, { id: 'hw-fb', sort: [ 'restore', 'demote' ] });
		var manList = String(c.manual || '').split(/ +/).filter(function(t) { return t; });
		var manChoices = {};
		uplinks.forEach(function(o) {
			manChoices[o.iface] = (o.sub && o.sub !== o.iface) ? (o.sub + ' (' + o.iface + ')') : o.iface;
		});
		var wMan = Object.keys(manChoices).length ? new ui.Dropdown(manList, manChoices, {
			id: 'hw-man', multiple: true, optional: true,
			select_placeholder: _('none'), display_items: 3, dropdown_items: -1
		}) : null;
		var wHeal = cb(String(c.healing) === '1', 'hw-heal-en');
		var healSel = [];
		uplinks.filter(function(o) { return o.type === 'modem'; }).forEach(function(o) {
			var cur = (c.heal && c.heal[o.iface]) || '';
			healSel.push({ iface: o.iface, title: o.sub || o.iface,
				w: new ui.Dropdown(cur, {
					'':       _('Default (reconnect, then reboot the module)'),
					'none':   _('Do nothing'),
					'ifup':   _('Reconnect the interface'),
					'reboot': _('...plus reboot the module'),
					'power':  _('...plus power cycle (USB port or your script)')
				}, { id: 'hw-heal-' + o.iface, sort: [ '', 'none', 'ifup', 'reboot', 'power' ] })
			});
		});
		var wPs = new ui.Textfield(String(c.power_script || ''), {
			id: 'hw-pscript', placeholder: '/root/modem-power.sh',
			validate: function(v) { return (!v || /^\/[A-Za-z0-9\/._-]+$/.test(v)) ? true : _('Expecting an absolute path made of letters, digits and / . _ -'); }
		});
		var wWifi = cb(String(c.heal_wifi) === '1', 'hw-heal-wifi');
		var hasWifi = uplinks.some(function(o) { return o.type === 'wifi'; }) || String(c.heal_wifi) === '1';
		var wPark = cb(String(c.sta_park) === '1', 'hw-sta-park');
		var hasSta = hasWifi || String(c.sta_park) === '1';
		var parkSt = E('div', { 'class': 'cbi-value-description', 'id': 'hw-sta-park-st' });
		var wLr = cb(String(c.lock_release) !== '0', 'hw-lock-release');
		var hasModem = healSel.length > 0 || String(c.lock_release) === '0';

		var grpWatch = E('div', {}, [
			row(_('Check interval, s'), wInt.render()),
			row(_('Ping targets'), wTgt.render(),
				_('If at least one target responds')),
			row(_('Failures before down'), wFail.render()),
			row(_('Successes before up'), wOk.render())
		]);
		var grpFb = E('div', {}, [
			row(_('When a link recovers'), wFb.render())
		].concat(wMan ? [ row(_('Use only manually'), wMan.render(),
			_('A link marked here never receives traffic automatically - to use it, make it first by clicking its card. Handy for a backup like Wi-Fi to your phone.')) ] : []));
		var grpFo = E('div', {}, [
			row(_('Switch traffic to a backup link when one goes down'), wFo.render(),
				_('A link that has an address but no internet will not give the traffic up on its own - the watchdog moves the route past it, and brings it back when the link recovers. Route metrics in the settings stay untouched. On by default.')),
			grpFb
		]);
		var grpHealTbl = E('div', {}, healSel.map(function(h) { return row(h.title, h.w.render()); }).concat([
			row(_('Power script'), wPs.render(),
				_('For boards without USB power control: an executable that cuts and restores the modem power (for example toggles a GPIO). The power step runs it instead of switching the USB port off, with the interface, the modem USB path and its AT port as arguments. Its output goes to the system log.'))
		]));
		var grpHeal = healSel.length ? E('div', {}, [
			row(_('Heal a modem while its link is down'), wHeal.render()),
			grpHealTbl
		]) : null;
		var grpLr = hasModem ? E('div', {}, [
			row(_('Release a cell lock when the network is lost'), wLr.render(),
				_('If the modem stays without network registration for 10 minutes while a cell or frequency lock set here is on, the lock is removed so the modem can use any cell. The lock is not set again automatically. Works even when watching is off.'))
		]) : null;
		var grpWifi = hasWifi ? E('div', {}, [
			row(_('Heal the Wi-Fi uplink while it is down'), wWifi.render())
		]) : null;

		var grpPark = hasSta ? E('div', {}, [
			row(_('Turn the Wi-Fi client off while its network is out of range'), wPark.render(),
				_('With one radio the access point has to stay on the channel of the Wi-Fi client, so a client that searches for a missing network keeps the access point down. After 30 s without a link the client is turned off and the access point works on its own channel, the internet goes through the modem. A scan every 1.5 minutes turns the client back on when its network is in range. Devices on the access point drop for a few seconds at each switch.')),
			parkSt
		]) : null;
		var fillPark = function() {
			if (!grpPark) { return; }
			L.resolveDefault(fs.exec_direct(PBIN, [ 'status' ]), '{}').then(function(t) {
				var d = {}; try { d = JSON.parse(t) || {}; } catch (e) {}
				var lbl = { linked: _('connected'), searching: _('searching for the network'),
					parked: _('turned off until its network is in range'), off: _('turned off') };
				parkSt.textContent = (d.stations || []).map(function(st) {
					return _('Wi-Fi client %s: %s').format(st.ssid || st.section, lbl[st.state] || st.state);
				}).join(' · ');
			});
		};
		fillPark();

		var node = E('div', { 'class': 'hw-form' }, [
			row(_('Enable watching'), wEn.render()),
			grpWatch, grpFo
		].concat(grpHeal ? [ grpHeal ] : []).concat(grpLr ? [ grpLr ] : []).concat(grpWifi ? [ grpWifi ] : []).concat(grpPark ? [ grpPark ] : []));

		var deps = function() {
			var en = wEn.isChecked();
			var show = function(el, on) { if (el) { el.style.display = on ? '' : 'none'; } };
			show(grpWatch, en);
			show(grpFo, en);
			show(grpHeal, en);
			show(grpWifi, en);
			show(grpFb, en && wFo.isChecked());
			show(grpHealTbl, en && healSel.length > 0 && wHeal.isChecked());
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
			var tgt = (wTgt.getValue() || []).map(function(t) {
				return String(t).replace(/[^A-Za-z0-9.:-]/g, '');
			}).filter(function(t) { return t; }).join(' ');
			return fs.exec(HBIN, [ 'setconf',
				'enabled=' + (wEn.isChecked() ? '1' : '0'),
				'failover=' + (wFo.isChecked() ? '1' : '0'),
				'healing=' + (healSel.length ? (wHeal.isChecked() ? '1' : '0') : (String(c.healing) === '1' ? '1' : '0')),
				'heal_wifi=' + (hasWifi ? (wWifi.isChecked() ? '1' : '0') : (String(c.heal_wifi) === '1' ? '1' : '0')),
				'sta_park=' + (hasSta ? (wPark.isChecked() ? '1' : '0') : '0'),
				'lock_release=' + (hasModem ? (wLr.isChecked() ? '1' : '0') : (String(c.lock_release) === '0' ? '0' : '1')),
				'failback=' + wFb.getValue(),
				'interval=' + n(wInt, 30),
				'targets=' + (tgt || '77.88.8.8 1.1.1.1'),
				'fail_n=' + n(wFail, 3),
				'ok_n=' + n(wOk, 5),
				'manual=' + (wMan ? L.toArray(wMan.getValue()).join(' ') : String(c.manual || '')),
				'power_script=' + (/^\/[A-Za-z0-9\/._-]+$/.test((wPs.getValue() || '').trim()) ? (wPs.getValue() || '').trim() : '')
			]).then(function() {
				return Promise.all(healSel.map(function(h) {
					return fs.exec(HBIN, [ 'setheal', h.iface, h.w.getValue() ]);
				}));
			}).then(function() {
				L.resolveDefault(fs.exec(HBIN, [ 'once' ]), null);
				if (hasSta) { L.resolveDefault(fs.exec(PBIN, [ 'tick' ]), null).then(fillPark); }
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
			node.addEventListener('change', _as_kick);
			node.addEventListener('widget-change', _as_kick);
			node.addEventListener('cbi-dynlist-change', _as_kick);
		}
		return { node: node, save: save };
	}
});
