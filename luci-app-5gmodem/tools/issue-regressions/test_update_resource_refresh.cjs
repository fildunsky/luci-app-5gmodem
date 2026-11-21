const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/5gsettings.js'), 'utf8');
const drain = () => new Promise(resolve => setImmediate(resolve));

function deferred() {
	let resolve, reject;
	const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
	return { promise, resolve, reject };
}

function fixture(hasFetch = true) {
	const calls = [], timers = [], messages = [];
	const fetch = (url, opts) => {
		const headers = deferred(), body = deferred();
		calls.push({ url, headers, body });
		assert.equal(opts.cache, 'reload');
		assert.equal(opts.credentials, 'same-origin');
		return headers.promise;
	};
	const window = {
		fetch: hasFetch ? fetch : undefined,
		location: { href: '' },
		setTimeout: (callback, delay) => timers.push({ callback, delay })
	};
	const context = vm.createContext({
		fetch, window, L: { resource: r => '/' + r, url: r => '/' + r },
		_: s => s, byId: () => null, updBar: {}, upd: {},
		updBarStop() {}, updBarPaint() {}, updDetail() {}, updProgress() {}, updPill() {},
		verLine: (s, v) => s.replace('%s', v), btnState() {},
		updLines: (_title, text) => messages.push(text),
		updLine: (_id, text) => messages.push(text)
	});
	vm.runInContext(source.slice(source.indexOf('var CACHED_RES ='), source.indexOf('function verifyInstalled(')), context);
	const resources = ['a.js', 'b.js', 'c.css', 'd.js', 'e.css'];
	context.CACHED_RES = resources;
	return { context, resources, calls, timers, messages, window };
}

test('refresh keeps at most three full transfers active and signs out after all settle', async () => {
	const f = fixture();
	f.context.finishUpdate('4.0.0');
	assert.equal(f.calls.length, 3);
	for (const call of f.calls) {
		call.headers.resolve({ arrayBuffer: () => call.body.promise });
	}
	await drain();
	assert.equal(f.calls.length, 3, 'receiving headers does not free a slot');
	assert.equal(f.timers.length, 0);
	assert.deepEqual(f.messages, ['Refreshing resources…']);

	f.calls[1].body.reject(new Error('partial response'));
	await drain();
	assert.equal(f.calls.length, 4);
	f.calls[3].headers.reject(new Error('offline'));
	await drain();
	assert.deepEqual(f.calls.map(call => call.url), f.resources.map(r => '/' + r));

	f.calls[4].headers.resolve({ arrayBuffer: () => f.calls[4].body.promise });
	f.calls[0].body.resolve();
	f.calls[4].body.resolve();
	await drain();
	assert.equal(f.timers.length, 0);
	f.calls[2].body.resolve();
	await drain();
	assert.deepEqual(f.messages, ['Refreshing resources…', 'Signing out to apply it…']);
	assert.equal(f.timers.length, 1);
	assert.equal(f.timers[0].delay, 1200);
	f.timers[0].callback();
	assert.equal(f.window.location.href, '/admin/logout');
});

test('sign-out still runs when fetch is unavailable', async () => {
	const f = fixture(false);
	f.context.finishUpdate('4.0.0');
	await drain();
	assert.equal(f.calls.length, 0);
	assert.equal(f.timers.length, 1);
	f.timers[0].callback();
	assert.equal(f.window.location.href, '/admin/logout');
});
