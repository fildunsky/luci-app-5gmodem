const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../../htdocs/luci-static/resources/view/modem5g/sms.js'), 'utf8');
const context = {
	document: { documentElement: { lang: 'en' }, body: { className: 'lang_ru' } },
	L: { env: { lang: 'ru' } },
	_: (text) => `[${text}]`
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function sms_pad('), source.indexOf('var SMS_URL_RE')), context);

const { sms_short_time, sms_day_label, sms_feed_time, sms_daystr } = context;
const stamp = '2024-11-22 03:42';

assert.equal(sms_short_time(stamp), '11/22');
assert.equal(sms_day_label(stamp), '11/22/2024');
assert.equal(sms_feed_time(stamp), '11/22/2024 03:42');

context.document.documentElement.lang = 'ru';
assert.equal(sms_short_time(stamp), '22.11');
assert.equal(sms_day_label(stamp), '22.11.2024');
assert.equal(sms_feed_time('2024-11-22T03:42:19'), '22.11.2024 03:42:19');

context.document.documentElement.lang = '';
context.document.body.className = 'theme lang_en_GB';
assert.equal(sms_day_label(stamp), '22/11/2024');
context.document.body.className = 'theme';
assert.equal(sms_day_label(stamp), '22.11.2024');

assert.equal(sms_short_time(`${sms_daystr(0)} 03:42`), '03:42');
assert.equal(sms_short_time(sms_daystr(1)), '[yesterday]');
assert.equal(sms_day_label(sms_daystr(0)), '[today]');
assert.equal(sms_day_label(sms_daystr(1)), '[yesterday]');
assert.equal(sms_feed_time('unknown'), 'unknown');

context.document.documentElement.lang = 'invalid locale';
assert.equal(sms_day_label(stamp), new Date('2024-11-22T00:00:00Z').toLocaleDateString(undefined, {
	day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'UTC'
}));
