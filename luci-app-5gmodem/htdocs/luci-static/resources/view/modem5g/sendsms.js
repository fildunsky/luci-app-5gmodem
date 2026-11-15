'use strict';
'require view';
'require view.modem5g.modemtabs as modemtabs';

// The former sendsms page is part of the SMS tab now (sms.js). Old bookmarks and links land here and
// are sent on; the menu entry stays without a title, so LuCI does not draw it as a tab.
return view.extend({
	load: function() {
		window.location.replace(L.url('admin/modem/5gmodem/sms') + '#new');
		return new Promise(function() {});
	},

	render: function() { return E('div'); },

	handleSaveApply: null, handleSave: null, handleReset: null
});
