'use strict';
'require rpc';
'require form';
'require network';

// LuCI protocol handler for the "qmiraw" netifd proto shipped by
// luci-app-5gmodem (stock qmi with raw-ip data format and static addressing
// from get-current-settings - for modems whose 802.3/DHCP path yields an
// address but no traffic, e.g. SIMCom SIM7100E, Telit LM960). Without this
// handler the Network > Interfaces page shows the interface as "unsupported".

var callFileList = rpc.declare({
	object: 'file',
	method: 'list',
	params: [ 'path' ],
	expect: { entries: [] },
	filter: function(list, params) {
		var rv = [];
		for (var i = 0; i < list.length; i++)
			if (list[i].name.match(/^cdc-wdm/))
				rv.push(params.path + list[i].name);
		return rv.sort();
	}
});

network.registerPatternVirtual(/^qmiraw-.+$/);

return network.registerProtocol('qmiraw', {
	getI18n: function() {
		return _('QMI Cellular (raw-ip)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'qmiraw-%s'.format(this.sid);
	},

	getPackageName: function() {
		return 'luci-app-5gmodem';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var dev = this.getL3Device() || this.getDevice(), o;

		o = s.taboption('general', form.Value, '_modem_device', _('Modem device'));
		o.ucioption = 'device';
		o.rmempty = false;
		o.load = function(section_id) {
			return callFileList('/dev/').then(L.bind(function(devices) {
				for (var i = 0; i < devices.length; i++)
					this.value(devices[i]);
				return form.Value.prototype.load.apply(this, [section_id]);
			}, this));
		};

		var validate_apn = function(section_id, value) {
			if (value == null || value == '')
				return true;

			if (!/^[a-zA-Z0-9\-.]*[a-zA-Z0-9]$/.test(value))
				return _('Invalid APN provided');

			return true;
		};
		o = s.taboption('general', form.Value, 'apn', _('APN'));
		o.validate = validate_apn;

		if (L.hasSystemFeature('ipv6')) {
			o = s.taboption('general', form.Value, 'v6apn', _('IPv6 APN'));
			o.validate = validate_apn;
			o.depends('pdptype', 'ipv4v6')
		};

		o = s.taboption('general', form.Value, 'pincode', _('PIN'));
		o.datatype = 'and(uinteger,minlength(4),maxlength(8))';

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication Type'));
		o.value('both', 'PAP/CHAP');
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.value('none', 'NONE');
		o.default = 'none';

		o = s.taboption('general', form.Value, 'username', _('PAP/CHAP username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');

		o = s.taboption('general', form.Value, 'password', _('PAP/CHAP password'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');
		o.password = true;

		o = s.taboption('advanced', form.Value, 'delay', _('Modem init timeout'), _('Maximum amount of seconds to wait for the modem to become ready'));
		o.placeholder = '10';
		o.datatype    = 'min(1)';

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'));
		o.placeholder = dev ? (dev.getMTU() || '1500') : '1500';
		o.datatype    = 'max(9200)';

		o = s.taboption('general', form.ListValue, 'pdptype', _('PDP Type'));
		o.value('ipv4v6', 'IPv4/IPv6');
		o.value('ipv4', 'IPv4');
		o.value('ipv6', 'IPv6');
		o.default = 'ipv4';

		o = s.taboption('advanced', form.Flag, 'defaultroute',
			_('Use default gateway'),
			_('If unchecked, no default route is configured'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Value, 'metric',
			_('Use gateway metric'));
			o.placeholder = '0';
		o.datatype = 'uinteger';
		o.depends('defaultroute', '1');

		o = s.taboption('advanced', form.Flag, 'peerdns',
			_('Use DNS servers advertised by peer'),
			_('If unchecked, the advertised DNS server addresses are ignored'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Value, 'profile',
			_('APN profile index'));
		o.placeholder = '1';
		o.datatype = 'uinteger';

		if (L.hasSystemFeature('ipv6')) {
			o = s.taboption('advanced', form.Value, 'v6profile',
				_('IPv6 APN profile index'));
			o.placeholder = '1';
			o.datatype = 'uinteger';
			o.depends('pdptype', 'ipv4v6');
		};
	}
});
