'use strict';
'require baseclass';
'require rpc';

var status = rpc.declare({ object: '5gmodem_maps', method: 'status', expect: { '': {} } });
var signIn = rpc.declare({ object: '5gmodem_maps', method: 'login', params: [ 'login', 'password' ], expect: { '': {} } });

function message(code) {
	return ({
		rejected: _('Sign-in rejected'), network: _('Could not connect to the service'),
		unavailable: _('Service unavailable'), rate_limited: _('Too many requests. Try again later.'),
		curl_required: _('Install curl to connect to these services.'),
		password_required: _('Enter the password for this account.'),
		invalid: _('Check the login and password.'), storage: _('Could not save the account.'),
		busy: _('An account operation is already running.')
	})[code] || _('Could not connect to the service');
}

return baseclass.extend({
	build: function() {
		var login = E('input', { 'class': 'cbi-input-text', 'type': 'text', 'autocomplete': 'username', 'maxlength': '254', 'id': 'maps-login' });
		var password = E('input', { 'class': 'cbi-input-text', 'type': 'password', 'autocomplete': 'new-password', 'maxlength': '1024', 'id': 'maps-password' });
		var hint = E('div', { 'class': 'cbi-value-description' });
		var result = E('p', { 'role': 'status', 'aria-live': 'polite' });
		var buttons = [], configured = false;
		function row(label, widget, id, description) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title', 'for': id }, label),
				E('div', { 'class': 'cbi-value-field' }, description ? [ widget, description ] : [ widget ])
			]);
		}
		function paint(j) {
			if (!j.ok) { throw new Error((j.service ? (j.service === 'fourcells' ? '4Cells' : 'Speedmetrics') + ': ' : '') + message(j.error)); }
			configured = !!j.configured;
			login.value = j.login || '';
			password.value = '';
			hint.textContent = configured ? _('A password is saved. Leave this field empty to keep it.') : '';
		}
		function run(action) {
			buttons.forEach(function(b) { b.disabled = true; });
			login.disabled = password.disabled = true;
			result.textContent = _('Checking…');
			return Promise.resolve().then(action).then(function(j) {
				paint(j);
				result.textContent = _('Signed in');
			}).catch(function(e) {
				password.value = '';
				result.textContent = e.message || message('network');
			}).finally(function() {
				buttons.forEach(function(b) { b.disabled = false; });
				login.disabled = password.disabled = false;
			});
		}
		function button(label, action) {
			var b = E('button', { 'class': 'cbi-button cbi-button-action', 'type': 'button', 'click': function() { return run(action); } }, label);
			buttons.push(b);
			return b;
		}
		var node = E('div', { 'class': 'tg-mapaccount' }, [
			E('h3', {}, '4Cells / Speedmetrics'),
			E('p', {}, _('Sign in to use the map layers. No measurements are sent.')),
			row(_('Login'), login, 'maps-login'),
			row(_('Password'), password, 'maps-password', hint),
			row('', E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:8px' }, [
				button(_('Sign in'), function() { return signIn(login.value.trim(), password.value); })
			])),
			result
		]);
		buttons.forEach(function(b) { b.disabled = true; });
		login.disabled = password.disabled = true;
		status().then(paint).catch(function() { result.textContent = message('network'); }).finally(function() {
			buttons.forEach(function(b) { b.disabled = false; });
			login.disabled = password.disabled = false;
		});
		return node;
	}
});
