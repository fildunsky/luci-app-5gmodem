'use strict';
'require form';
'require network';

// LuCI protocol handler for the "fibocom" netifd proto shipped by
// luci-app-5gmodem (AT-dialed RNDIS/ECM modems such as Fibocom FM350-GL that
// ModemManager cannot drive). Without this handler the Network > Interfaces
// page shows the interface as "unsupported" and it flickers out of the list.

network.registerPatternVirtual(/^fibocom-.+$/);
network.registerErrorCode('NO_NETDEV',      _('No usbnet device found for the modem'));
network.registerErrorCode('NO_AT_PORT',     _('No AT control port found'));
network.registerErrorCode('NO_IP_ADDRESS',  _('Modem did not provide an IP address'));
network.registerErrorCode('NETDEV_MISSING', _('The modem network device is missing from the system'));
network.registerErrorCode('ROAMING_NOT_ALLOWED', _('Registered in roaming, and roaming is disabled'));
network.registerErrorCode('NOT_REGISTERED', _('The modem is not registered on any network — check the antennas and the signal level'));
network.registerErrorCode('REGISTRATION_DENIED', _('The network refused registration — check the SIM, the plan and whether the IMEI is blocked'));

return network.registerProtocol('fibocom', {
	getI18n: function() {
		return _('Fibocom (AT-dial)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'wan';
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
		var o;

		o = s.taboption('general', form.Value, 'apn', _('APN'));
		o.validate = function(section_id, value) {
			if (value == null || value == '')
				return true;
			if (!/^[a-zA-Z0-9\-.]*[a-zA-Z0-9]$/.test(value))
				return _('Invalid APN provided');
			return true;
		};

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication Type'));
		o.value('none', 'NONE');
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.default = 'none';

		o = s.taboption('general', form.Value, 'username', _('PAP/CHAP username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');

		o = s.taboption('general', form.Value, 'password', _('PAP/CHAP password'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.password = true;

		o = s.taboption('general', form.ListValue, 'pdptype', _('IP Protocol'));
		o.default = 'IPV4V6';
		o.value('IP', _('IPv4'));
		o.value('IPV4V6', _('IPv4+IPv6'));
		o.value('IPV6', _('IPv6'));

		// These are managed by the 5G Modem app (mkiface.sh) - declared here so
		// editing the interface in LuCI does not drop them on save.
		o = s.taboption('advanced', form.Value, 'usbpath', _('USB path'),
			_('Stable USB topology path of the modem (managed by the 5G Modem app)'));

		o = s.taboption('advanced', form.Value, 'device', _('Network device'),
			_('usbnet device, auto-resolved from the USB path'));

		o = s.taboption('advanced', form.Value, 'atport', _('AT port'),
			_('AT command port used for dialing; auto-selected when empty'));

		o = s.taboption('advanced', form.Value, 'metric', _('Metric'),
			_('Route metric - higher value means lower priority'));
		o.datatype = 'uinteger';
		o.placeholder = '0';
	}
});
