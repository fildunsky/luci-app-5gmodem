const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/sms.js'), 'utf8');
const cut = (from, to) => source.slice(source.indexOf(from), source.indexOf(to));

function element(tag, attrs = {}, children = []) {
	return {
		tag, attrs, children: Array.isArray(children) ? children : [ children ], style: {},
		classList: { toggle() {} },
		setAttribute(name, value) { attrs[name] = value; },
		addEventListener(name, fn) { attrs[name] = fn; }
	};
}

function checkboxes(node) {
	if (!node || !node.children) { return []; }
	return node.children.flatMap(check => check.tag === 'input' && check.attrs.type === 'checkbox'
		? [ check ] : checkboxes(check));
}

function fixture() {
	const message = (index, text, parts, epoch) =>
		({ index, text, parts, epoch, raw: 'Sender', local: '09:00', isNew: false });
	const dialogue = {
		key: 'Sender', shown: 'Sender', alpha: true,
		msgs: [ message('1', 'leave', 1, 1), message('7-8', 'multipart', 2, 2) ],
		out: [{ id: 1, text: 'outgoing', state: 'ok', local: '09:01', epoch: 3 }]
	};
	const state = {
		screen: 'thread', threadSelMode: false, threadSel: new Set(), msgSource: 'modem:ME',
		deleting: false
	};
	const calls = [], removed = [];
	const self = {
		_S: state, _listProgress() {}, _setDeleting(on) { state.deleting = on; },
		_removeMsgs(indexes) { removed.push(...indexes); },
		_doRefresh() {}
	};
	const context = vm.createContext({
		S: state, self, smsReadOnly: false, currentSource: state.msgSource,
		BRIDGE: 'smsbridge', sms_cache_key: () => context.currentSource,
		sms_parse_status: () => ({}), uci: { load: () => Promise.resolve(), get: () => undefined },
		L: { resolveDefault: value => Promise.resolve(value) },
		fs: { exec_direct(_, args) {
			calls.push(Array.from(args));
			if (args[0] === 'delete-start') { return '{"state":"running"}'; }
			if (args[0] === 'delete-status') { return '{"state":"done","ok":[7,8]}'; }
			return '';
		} },
		window: { setTimeout(callback) { callback(); } },
		_: label => label, E: element, ibtn: (_, label, cls, attrs) => element('button', attrs, label),
		icon: name => element('span', {}, name), dom: { content(node, children) { node.children = children; } },
		openDlg: () => dialogue, autoPick() {}, paintOpen() {}, isPhone: () => false,
		avatar: () => ({ childNodes: [] }), dlgTitle: d => d.shown,
		threadSec: element('section'), reply: { el: element('div'), lock() {} },
		deleteProgress: () => ({}), sms_hm: time => time, sms_day_label: () => '',
		sms_rich: text => [ text ]
	});
	vm.runInContext([
		'String.prototype.format = function(n) { return this.replace("%d", n); };',
		cut('var th = {};', 'var reply = makeComposer'),
		cut('function setThreadSelMode(', 'function renderHead()'),
		'Object.assign(self, {' + cut('\n\thandleDelete:', '\n\tpopTimeout:') + '});',
		'renderThread(false);'
	].join('\n'), context);
	const deleteMessages = self.handleDelete.bind(self);
	let deletion;
	self.handleDelete = (...args) => { deletion = deleteMessages(...args); return deletion; };
	return {
		context, calls, removed, dialogue, state,
		select() { context.th.selBtn.attrs.click(); return checkboxes(context.th.body); },
		deleteSelected() { context.th.selDel.attrs.click(); return deletion; }
	};
}

test('conversation deletion submits only the selected SMS and all of its parts', async () => {
	const f = fixture();
	const checks = f.select();
	assert.equal(checks.length, 2, 'outgoing bubble has no checkbox');
	assert.equal(f.context.th.selDel.disabled, true);
	checks[1].checked = true;
	checks[1].attrs.change();
	assert.equal(f.context.th.selDel.disabled, false);
	await f.deleteSelected();
	assert.deepEqual(f.calls.filter(args => args[0] === 'delete-start'), [
		[ 'delete-start', '7,8', 'ME', '' ]
	]);
	assert.deepEqual(f.removed, [ '7-8' ]);
});

test('refresh prunes a selection when its modem slot now contains another SMS', () => {
	const f = fixture();
	const [check] = f.select();
	check.checked = true;
	check.attrs.change();
	f.dialogue.msgs[0] = { ...f.dialogue.msgs[0], text: 'other' };
	f.context.renderThread(false);
	assert.equal(f.state.threadSel.size, 0);
	assert.equal(checkboxes(f.context.th.body)[0].checked, false);
	assert.equal(f.context.th.selDel.disabled, true);
});

test('read-only conversations cannot select or delete messages', () => {
	const f = fixture();
	f.context.smsReadOnly = true;
	f.context.renderThread(false);
	assert.equal(f.context.th.selBtn.style.display, 'none');
	assert.equal(f.select().length, 0);
	assert.equal(f.deleteSelected(), undefined);
	assert.deepEqual(f.calls, []);
});

test('a changed SMS source blocks a pending deletion', async () => {
	const f = fixture();
	const [check] = f.select();
	check.checked = true;
	check.attrs.change();
	const deletion = f.deleteSelected();
	f.context.currentSource = 'modem:SM';
	await deletion;
	assert.deepEqual(f.calls, []);
	f.context.renderThread(false);
	assert.equal(f.state.threadSel.size, 0);
	assert.equal(f.context.th.selBtn.style.display, 'none');
});
