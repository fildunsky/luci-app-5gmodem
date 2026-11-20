'use strict';
'require baseclass';
'require fs';

/* Extensions: resources/5gmodem/ext/*.js of other packages. Contract: docs/subsystems/extensions.md */
var list = [], loading;

return baseclass.extend({
	load: function() {
		if (!loading) {
			loading = L.resolveDefault(fs.list('/www' + L.resource('5gmodem/ext')), []).then(function(dir) {
				return Promise.all(dir.filter(function(e) { return e.type === 'file' && /\.js$/.test(e.name); })
					.map(function(e) { return e.name.slice(0, -3); }).sort()
					.map(function(n) { return L.resolveDefault(L.require('5gmodem.ext.' + n), null); }));
			}).then(function(l) { list = l.filter(Boolean); });
		}
		return loading;
	},

	/* call hook `name` of every extension that has it -> array of results that are not null */
	call: function(name) {
		var args = Array.prototype.slice.call(arguments, 1);
		return list.map(function(x) {
			return (typeof x[name] === 'function') ? x[name].apply(x, args) : null;
		}).filter(function(r) { return r != null; });
	}
});
