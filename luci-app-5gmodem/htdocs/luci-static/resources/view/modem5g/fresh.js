'use strict';
'require baseclass';
'require ui';

var RES_RE = /\/luci-static\/resources\/(view\/modem5g|sms-tool-5gm|protocol|5gmodem)\//;

return baseclass.extend({
	check: function(want, mods) {
		var stale = (mods || []).filter(function(m) { return !m || m.API !== want; });
		if (!stale.length) { return Promise.resolve(true); }
		var key = '5gm_fresh_' + want, last = 0;
		try { last = +(window.sessionStorage.getItem(key) || 0); } catch (e) {}
		if (Date.now() - last < 60000) {
			ui.addNotification(null, E('p', _('The browser keeps outdated files of this page. Clear the browser cache (Ctrl+Shift+R) and reload the page.')), 'warning');
			return Promise.resolve(false);
		}
		try { window.sessionStorage.setItem(key, String(Date.now())); } catch (e) {}
		var urls = [];
		try {
			urls = window.performance.getEntriesByType('resource').map(function(e) { return e.name; })
				.filter(function(u) { return RES_RE.test(u); });
		} catch (e) {}
		return Promise.all(urls.map(function(u) {
			return window.fetch(u, { cache: 'reload' }).catch(function() {});
		})).then(function() {
			window.location.reload();
			return new Promise(function() {});
		});
	}
});
