'use strict';
'require baseclass';
'require fs';
'require uci';
'require poll';
'require view.modem5g.mutil as mutil';

/* ВНЕШНИЙ АДРЕС РОУТЕРА - ОДИН ОПРОС НА ВСЮ СТРАНИЦУ.
   Его хотят видеть сразу двое: строка адреса в карточке модема и (по желанию)
   карточка активного аплинка в «Приоритете интернета».

   КАНАЛОВ ДВА, И ЭТО ВАЖНО. Пустой ключ - маршрут по умолчанию: то, с какого
   адреса виден сам роутер. Ключ с именем интерфейса - запрос ИМЕННО через
   него: в карточке модема нужен адрес модема, а не соседнего аплинка, через
   который сейчас идёт трафик. Если названный интерфейс и есть основной,
   бэкенд сам отдаст общий ответ, не тратя второго запроса.

   Опрос дешёвый: бэкенд отдаёт кэш, а в сеть ходит сам и только когда пора. */

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
				var st = scope(k);
				if ((d.ip || '') !== st.ip || (d.ip6 || '') !== st.ip6 || (d.cc || '') !== st.cc) {
					changed = true;
				}
				st.ip = d.ip || ''; st.ip6 = d.ip6 || ''; st.cc = d.cc || '';
				st.src = d.src || ''; st.src6 = d.src6 || '';
			});
	})).then(function() { if (changed) { fire(); } });
}

/* Адрес с флагом страны: флаг - самый быстрый ответ на вопрос «через туннель
   или напрямую», ради которого внешний адрес и показывают. */
function withFlag(ip, cc) {
	if (!ip) { return ''; }
	var fl = mutil.flagEmoji(cc);
	return fl ? (fl + ' ' + ip) : ip;
}

return baseclass.extend({
	/* Читает флаги; опрос заводится ОДИН на страницу, при первом watch(). */
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

	/* Следить за каналом: '' - маршрут по умолчанию, иначе имя интерфейса. */
	watch: function(key) {
		if (!_flags.enabled) { return; }
		key = key || '';
		var fresh = !_scopes[key];
		scope(key);
		if (!_polling) { _polling = true; poll.add(tick, 15); }
		if (fresh) { tick(); }
	},

	/* Модем на странице сменили - за старым интерфейсом больше не следим. */
	unwatch: function(key) {
		if (key) { delete _scopes[key]; }
	},

	/* Состояние канала БЕЗ его заведения: карточки спрашивают про интерфейсы,
	   за которыми, может, никто и не следит - молча заводить им опрос нельзя. */
	state: function(key) {
		if (!_flags.enabled) { return EMPTY; }
		return _scopes[key || ''] || EMPTY;
	},

	subscribe: function(fn) {
		if (typeof fn === 'function') { _subs.push(fn); }
	},

	withFlag: withFlag
});
