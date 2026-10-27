'use strict';
'require form';
'require network';

network.registerErrorCode('NO_AT_CLIENT',   _('No AT control port found'));
network.registerErrorCode('NO_ATCI',        _('No AT control port found'));
network.registerErrorCode('NO_ADDRESS',     _('Modem did not provide an IP address'));
network.registerErrorCode('NOT_REGISTERED', _('The modem is not registered on any network — check the antennas and the signal level'));

return network.registerProtocol('ccmni', {
	getI18n: function() {
		return _('MediaTek built-in modem (CCMNI)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || this._get('ifname') || 'ccmni0';
	},

	getPackageName: function() {
		return '5gmodem-mtk-at';
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
		var o;

		o = s.taboption('general', form.ListValue, 'ifname', _('Network device'));
		for (var i = 0; i < 8; i++)
			o.value('ccmni' + i);
		o.default = 'ccmni0';

		o = s.taboption('general', form.Value, 'apn', _('APN'));
		o.placeholder = _('As set in the modem');
		o.validate = function(section_id, value) {
			if (value == null || value == '')
				return true;
			if (!/^[a-zA-Z0-9\-.]*[a-zA-Z0-9]$/.test(value))
				return _('Invalid APN provided');
			return true;
		};

		o = s.taboption('general', form.ListValue, 'pdptype', _('IP Protocol'));
		o.value('', _('As set in the modem'));
		o.value('IP', _('IPv4'));
		o.value('IPV4V6', _('IPv4+IPv6'));
		o.value('IPV6', _('IPv6'));

		o = s.taboption('advanced', form.Value, 'regtimeout', _('Registration timeout, s'));
		o.datatype = 'range(10,600)';
		o.placeholder = '90';

		o = s.taboption('advanced', form.Flag, 'defaultroute', _('Use default gateway'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Flag, 'peerdns', _('Use DNS servers advertised by peer'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Value, 'metric', _('Metric'),
			_('Route metric - higher value means lower priority'));
		o.datatype = 'uinteger';
		o.placeholder = '0';
	}
});
