'use strict';
'require baseclass';
'require fs';
'require uci';
'require poll';
'require view.modem5g.mutil as mutil';

var BIN = '/usr/share/5gmodem/extip.sh';

var _flags = { enabled: false, inNetpri: false };
var _scopes = {};
var _subs = [];
var _polling = false;
var _inited = null;

var EMPTY = { ip: '', ip6: '', cc: '', src: '', src6: '' };

function scope(key) {
	key = key || '';
	if (!_scopes[key]) { _scopes[key] = { ip: '', ip6: '', cc: '', src: '', src6: '' }; }
	return _scopes[key];
}

function fire() {
	_subs.forEach(function(fn) { try { fn(); } catch (e) {} });
}

function tick() {
	var keys = Object.keys(_scopes);
	if (!keys.length) { return Promise.resolve(); }
	var changed = false;
	return Promise.all(keys.map(function(k) {
		return L.resolveDefault(fs.exec_direct(BIN, k ? [ 'get', k ] : [ 'get' ]), '')
			.then(function(out) {
				var d = {};
				try { d = JSON.parse(out || '{}'); } catch (e) { return; }
				var st = _scopes[k];
				if (!st) { return; }
				if ((d.ip || '') !== st.ip || (d.ip6 || '') !== st.ip6 || (d.cc || '') !== st.cc) {
					changed = true;
				}
				st.ip = d.ip || ''; st.ip6 = d.ip6 || ''; st.cc = d.cc || '';
				st.src = d.src || ''; st.src6 = d.src6 || '';
			});
	})).then(function() { if (changed) { fire(); } });
}

function withFlag(ip, cc) {
	if (!ip) { return ''; }
	var fl = mutil.flagEmoji(cc);
	return fl ? (fl + ' ' + ip) : ip;
}

return baseclass.extend({
	API: 30801,
	init: function() {
		if (_inited) { return _inited; }
		_inited = L.resolveDefault(uci.load('5gmodem')).then(function() {
			_flags.enabled  = uci.get('5gmodem', '@5gmodem[0]', 'extip_enabled') === '1';
			_flags.inNetpri = _flags.enabled &&
			                  uci.get('5gmodem', '@5gmodem[0]', 'extip_in_netpri') === '1';
			return _flags;
		});
		return _inited;
	},

	flags: function() { return _flags; },

	watch: function(key) {
		if (!_flags.enabled) { return; }
		key = key || '';
		var fresh = !_scopes[key];
		scope(key);
		if (!_polling) { _polling = true; poll.add(tick, 15); }
		if (fresh) { tick(); }
	},

	unwatch: function(key) {
		if (key) { delete _scopes[key]; }
	},

	state: function(key) {
		if (!_flags.enabled) { return EMPTY; }
		return _scopes[key || ''] || EMPTY;
	},

	subscribe: function(fn) {
		if (typeof fn === 'function') { _subs.push(fn); }
	},

	unsubscribe: function(fn) {
		var i = _subs.indexOf(fn);
		if (i >= 0) { _subs.splice(i, 1); }
		if (!_subs.length && !Object.keys(_scopes).length && _polling) {
			_polling = false;
			poll.remove(tick);
		}
	},

	withFlag: withFlag
});
