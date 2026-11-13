const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const text = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/readsms.js'), 'utf8');
const cut = (from, to) => text.slice(text.indexOf(from), text.indexOf(to));
const context = { smsSeen: new Set(), smsSeenFirst: false };
vm.createContext(context);
vm.runInContext([
	cut('function sms_ts_num(', 'function sms_localtime('),
	cut('function sms_msg_old(', 'function sms_keys_apply('),
	cut('function sms_android_read(', 'function sms_item_new('),
	cut('var SMS_GROUP_WINDOW', 'function sms_persist(')
].join('\n'), context);

const part = (index, timestamp, content, n, ref = 7, total = 2, sender = 'Bank') =>
	({ index, sender, timestamp, content, part: n, total, reference: ref });
const merge = (list) => JSON.parse(JSON.stringify(context.sms_merge_parts(list)));
const byIndex = (res) => Object.fromEntries(res.map((m) => [ m.index, m.content ]));

// A reused 8-bit reference months later is a second message, not a hidden or glued one,
// even when the new message sits in lower (freed) slots.
assert.deepEqual(byIndex(merge([
	part(0, '2026-06-01 09:00', 'new one ', 1), part(1, '2026-06-01 09:00', 'new two', 2),
	part(5, '2026-01-05 10:00', 'old one ', 1), part(6, '2026-01-05 10:00', 'old two', 2)
])), { '0-1': 'new one new two', '5-6': 'old one old two' });

// A taken part number inside the window starts its own card.
assert.deepEqual(byIndex(merge([
	part(1, '2026-06-01 09:00', 'first ', 1), part(2, '2026-06-01 09:05', 'second ', 1),
	part(3, '2026-06-01 09:00', 'tail', 2)
])), { '1-3': 'first tail', '2': 'second  [1/2]' });

// A byte-identical copy of a stored part stays with the card, so deleting it
// frees every slot and no stray "[1/2]" card is left behind.
const dup = merge([
	part(1, '2026-06-01 09:00', 'a ', 1), part(2, '2026-06-01 09:00', 'a ', 1), part(3, '2026-06-01 09:00', 'b', 2)
]);
assert.equal(dup.length, 1);
assert.equal(dup[0].content, 'a b');
assert.deepEqual(dup[0].index.split('-').sort(), [ '1', '2', '3' ]);

// A resent segment (same text, a minute later) keeps the later time, as before.
const resent = merge([
	part(1, '2026-09-06 15:09', 'a ', 1), part(2, '2026-09-06 15:10', 'a ', 1), part(3, '2026-09-06 15:10', 'b', 2)
]);
assert.equal(resent.length, 1);
assert.equal(resent[0].timestamp, '2026-09-06 15:10');
assert.equal(resent[0].index, '2-3-1');
assert.ok(resent[0].keys.includes('Bank|2026-09-06 15:09'));

// The window is one day; unparsable times keep the old joining.
assert.equal(merge([ part(1, '2026-06-01 09:00', 'x ', 1), part(2, '2026-06-02 08:59', 'y', 2) ]).length, 1);
assert.equal(merge([ part(1, '2026-06-01 09:00', 'x ', 1), part(2, '2026-06-02 09:01', 'y', 2) ]).length, 2);
assert.equal(merge([ part(1, '', 'x ', 1), part(2, '2026-06-02 09:01', 'y', 2) ]).length, 1);

// Single messages and other senders are untouched; keys of every member are kept.
const mixed = merge([
	{ index: 9, sender: 'Shop', timestamp: '2026-06-01 09:00', content: 'hi', part: 1, total: 1, reference: 0 },
	part(1, '2026-06-01 09:00', 'a ', 1, 7, 2, 'Other'), part(2, '2026-06-01 09:00', 'b', 2)
]);
assert.deepEqual(byIndex(mixed), { '9': 'hi', '1': 'a  [1/2]', '2': 'b [1/2]' });
assert.deepEqual(mixed[0].keys, [ 'Shop|2026-06-01 09:00' ]);
console.log('PASS: long SMS parts split on a reused reference, duplicates stay with their card');
