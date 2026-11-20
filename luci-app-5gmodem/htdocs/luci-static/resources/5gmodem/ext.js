'use strict';
'require baseclass';
'require fs';

/* Extensions: resources/5gmodem/ext/*.js of other packages. Contract: docs/subsystems/extensions.md */
var list = [], loading;

function report(extension, operation, err) {
	console.warn('5gmodem extension ' + extension + ' (' + operation + ')', err);
}

function loadExtension(name) {
	return Promise.resolve().then(function() {
		return L.require('5gmodem.ext.' + name);
	}).then(function(module) {
		return module ? { name: name, module: module } : null;
	}, function(err) {
		report(name, 'load', err);
		return null;
	});
}

function invoke(extension, name, args) {
	try {
		var hook = extension.module[name];
		if (typeof hook !== 'function')
			return null;

		var result = hook.apply(extension.module, args);
		if (result && typeof result.then === 'function') {
			Promise.resolve(result).catch(function(err) { report(extension.name, name, err); });
			return null;
		}
		return result;
	} catch (err) {
		report(extension.name, name, err);
		return null;
	}
}

return baseclass.extend({
	load: function() {
		if (!loading) {
			loading = Promise.resolve().then(function() {
				return fs.list('/www/luci-static/resources/5gmodem/ext');
			}).catch(function() { return []; }).then(function(dir) {
				if (!Array.isArray(dir))
					return [];

				return Promise.all(dir.filter(function(e) {
					return e && e.type === 'file' && /^[A-Za-z0-9_-]+\.js$/.test(e.name);
				})
					.map(function(e) { return e.name.slice(0, -3); }).sort()
					.map(loadExtension));
			}).then(function(l) { list = l.filter(Boolean); });
		}
		return loading;
	},

	/* call hook `name` of every extension that has it -> array of results that are not null */
	call: function(name) {
		var args = Array.prototype.slice.call(arguments, 1);
		return list.map(function(extension) {
			return invoke(extension, name, args);
		}).filter(function(r) { return r != null; });
	},

	first: function(name, accept) {
		var args = Array.prototype.slice.call(arguments, 2);
		for (var i = 0; i < list.length; i++) {
			var result = invoke(list[i], name, args);
			if (accept(result))
				return result;
		}
		return null;
	}
});
