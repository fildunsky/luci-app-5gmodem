import fs from 'fs';

const [,, port, sid, host, outdir, widthsArg, only] = process.argv;
const widths = (widthsArg || '390,1280').split(',').map(Number);
const WAIT = +(process.env.PAGE_WAIT || 14000);
const sleep = ms => new Promise(r => setTimeout(r, ms));

const B = '/cgi-bin/luci/admin/modem/5gmodem/';
const PAGES = [
	{ name: 'detail', path: B + 'detail', keys: ['#modem-info-block', '#modemvidpid'], doctor: true },
	{ name: 'esim', path: B + 'esim', keys: ['#esim-body'] },
	{ name: 'diagnostics', path: B + 'diagnostics', keys: ['#dbg-info-table'] },
	{ name: 'align', path: B + 'align', keys: [] },
	{ name: 'readsms', path: B + 'readsms', keys: ['#sms-info-table'] },
	{ name: 'sendsms', path: B + 'sendsms', keys: ['#phonenumber', '#smstext'] },
	{ name: 'sendussd', path: B + 'sendussd', keys: ['#cmdvalue'] },
	{ name: 'sendat', path: B + 'sendat', keys: ['#cmdvalue'] },
	{ name: 'buttons', path: B + 'buttons', keys: [] },
	{ name: 'stats', path: B + 'stats', keys: ['#traffic-table'] },
	{ name: 'settings', path: B + 'settings', keys: ['#upd-current'] },
	{ name: 'overview', path: '/cgi-bin/luci/admin/status/overview', keys: [] },
	{ name: 'network', path: '/cgi-bin/luci/admin/network/network', keys: [] },
];

const STALE = [/browser keeps outdated files/i, /Браузер держит устаревшие файлы/];
const BADTEXT = [/PermissionError/, /Access denied/i, /Unable to load/i, /Нет доступа/, /Не удалось загрузить/];
const MUTATE = [
	/setopt\.sh (reconnect|applyset)/, /reboot_modem\.sh (soft|hard|power|usbpower)\b/,
	/bands\.sh (set|mmset|jsonrefresh)/, /mkiface\.sh/, /modemswitch\.sh (switch|forget|autoapn|mkhilink|cleanup|save|autosetup|xmm|ackswap|delprofile|setalias|dedupe)/,
	/ttl\.sh set/, /update\.sh install/, /apn-update\.sh update/, /smsbridge\.sh (delete|send|seen-add|seen-reset|queue-run)/,
	/ussd\.sh (send|cancel)/, /atcmd\.sh/, /esim\.sh (enable|disable|delete|download|setshow|recheck|rename)/,
	/buttons\.sh (set|del|setleds|applyleds)/, /health\.sh (setconf|setheal|once)/, /netpri\.sh (set|order|worder|adoptzone)\b/,
	/speedtest\.sh (start|stop)/, /collect\.sh start/, /mmcli .*--3gpp-ussd/, /uci (set|delete|add|commit|apply|confirm|rename|order)/,
];

async function pageTarget() {
	for (let i = 0; i < 100; i++) {
		try {
			const l = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
			const p = l.find(x => x.type === 'page');
			if (p) return p;
		} catch (e) {}
		await sleep(200);
	}
	throw new Error('no chrome page');
}

const p = await pageTarget();
const ws = new WebSocket(p.webSocketDebuggerUrl);
await new Promise(r => ws.onopen = r);
let id = 0;
const pend = {};
let cur = null;
let allowMutate = false;

function describe(q) {
	const pd = q.postData || '';
	if (q.url.includes('cgi-exec')) {
		try {
			const m = pd.match(/(?:^|&)command=([^&]*)/);
			return decodeURIComponent((m ? m[1] : '').replace(/\+/g, ' ')).replace(/\\ /g, ' ');
		} catch (e) { return pd.slice(0, 200); }
	}
	try {
		const arr = [].concat(JSON.parse(pd));
		return arr.map(c => {
			const [, obj, meth, args] = c.params || [];
			if (obj === 'file' && meth === 'exec') return [args.command].concat(args.params || []).join(' ');
			if (obj === 'uci') return `uci ${meth} ${args.config || ''}`;
			return `${obj}.${meth}`;
		}).join(' ; ');
	} catch (e) { return pd.slice(0, 200); }
}

ws.onmessage = m => {
	const d = JSON.parse(m.data);
	if (d.id && pend[d.id]) { pend[d.id](d); delete pend[d.id]; return; }
	if (!cur) {
		if (d.method === 'Fetch.requestPaused') send('Fetch.continueRequest', { requestId: d.params.requestId });
		return;
	}
	switch (d.method) {
	case 'Runtime.exceptionThrown': {
		const e = d.params.exceptionDetails;
		cur.exceptions.push(((e.exception && e.exception.description) || e.text || '').split('\n').slice(0, 3).join(' | '));
		break;
	}
	case 'Runtime.consoleAPICalled':
		if (d.params.type === 'error' || d.params.type === 'assert')
			cur.console.push(d.params.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 300));
		break;
	case 'Log.entryAdded':
		if (d.params.entry.level === 'error') cur.log.push(`${d.params.entry.source}: ${d.params.entry.text} ${d.params.entry.url || ''}`.slice(0, 300));
		break;
	case 'Network.responseReceived': {
		const r = d.params.response;
		if (r.status >= 400 && !/favicon/.test(r.url)) cur.http.push(`${r.status} ${r.url}`);
		break;
	}
	case 'Page.frameNavigated':
		if (!d.params.frame.parentId) cur.navs++;
		break;
	case 'Fetch.requestPaused': {
		const q = d.params.request;
		const c = describe(q);
		cur.calls.push(c);
		if (!allowMutate && MUTATE.some(re => re.test(c))) {
			cur.blocked.push(c);
			send('Fetch.failRequest', { requestId: d.params.requestId, errorReason: 'BlockedByClient' });
		} else {
			send('Fetch.continueRequest', { requestId: d.params.requestId });
		}
		break;
	}
	}
};

function send(method, params = {}) { ws.send(JSON.stringify({ id: ++id, method, params })); }
const cmd = (method, params = {}) => new Promise(r => {
	const i = ++id; pend[i] = r;
	ws.send(JSON.stringify({ id: i, method, params }));
	setTimeout(() => { if (pend[i]) { delete pend[i]; r({ timeout: true }); } }, 30000);
});
const ev = async expr => {
	const r = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
	return r.result && r.result.result ? r.result.result.value : undefined;
};

await cmd('Network.enable');
await cmd('Page.enable');
await cmd('Runtime.enable');
await cmd('Log.enable');
await cmd('Fetch.enable', { patterns: [{ urlPattern: '*cgi-exec*' }, { urlPattern: '*/ubus*' }] });
await cmd('Network.setExtraHTTPHeaders', { headers: { 'Accept-Language': 'ru-RU,ru;q=0.9' } });
await cmd('Network.setCookie', { name: 'sysauth_http', value: sid, domain: host, path: '/cgi-bin/luci' });

const probe = keys => `(() => {
	const vis = e => { if (!e) return false; const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
	const txt = document.body ? document.body.innerText : '';
	const notes = [...document.querySelectorAll('.alert-message, #modal_overlay .modal, .cbi-map-descr.error')].map(e => e.innerText.trim()).filter(Boolean);
	const view = document.getElementById('view') || document.querySelector('#maincontent');
	return {
		title: document.title,
		login: !!document.querySelector('input[name=luci_password]'),
		viewNodes: view ? view.querySelectorAll('*').length : 0,
		spinning: view ? [...view.querySelectorAll('.spinning')].filter(vis).length : 0,
		keys: ${JSON.stringify(keys)}.map(s => [s, !!document.querySelector(s)]),
		notes,
		text: txt.slice(0, 20000),
		scrollW: document.documentElement.scrollWidth,
		innerW: window.innerWidth,
		docH: document.documentElement.scrollHeight
	};
})()`;

const results = [];
function line(res, name, secs, detail) {
	const s = `${res}\t${name}\t${secs.toFixed(2)}\t${String(detail).replace(/\s+/g, ' ').slice(0, 400)}`;
	results.push(s);
	console.log(s);
}

for (const pg of PAGES) {
	if (only === 'app' ? !pg.path.startsWith(B) : (only && !only.split(',').includes(pg.name))) continue;
	for (const width of widths) {
		const mob = width <= 800;
		await cmd('Emulation.setDeviceMetricsOverride', { width, height: mob ? 844 : 900, deviceScaleFactor: mob ? 2 : 1, mobile: mob });
		await cmd('Emulation.setTouchEmulationEnabled', { enabled: mob });
		await cmd('Page.navigate', { url: 'about:blank' });
		await sleep(300);
		cur = { exceptions: [], console: [], log: [], http: [], calls: [], blocked: [], navs: 0 };
		const t0 = Date.now();
		await cmd('Page.navigate', { url: `http://${host}${pg.path}` });
		await sleep(WAIT);
		const m = await ev(probe(pg.keys)) || {};
		const secs = (Date.now() - t0) / 1000;
		const tag = `page.${pg.name}.${width}`;
		const shot = await cmd('Page.captureScreenshot', { format: 'jpeg', quality: 60 });
		if (shot.result) fs.writeFileSync(`${outdir}/${pg.name}-${width}.jpg`, Buffer.from(shot.result.data, 'base64'));
		const text = m.text || '';
		const problems = [];
		const warns = [];
		if (m.login) problems.push('login form (session rejected)');
		if (cur.exceptions.length) problems.push('exceptions: ' + cur.exceptions.join(' || '));
		if (cur.console.length) problems.push('console errors: ' + cur.console.join(' || '));
		if (STALE.some(re => re.test(text))) problems.push('stale-files warning');
		const bad = BADTEXT.filter(re => re.test(text)).map(String);
		if (bad.length) problems.push('error text ' + bad.join(','));
		const missing = (m.keys || []).filter(k => !k[1]).map(k => k[0]);
		if (missing.length) problems.push('missing ' + missing.join(','));
		if ((m.viewNodes || 0) < 5) problems.push('empty view');
		if (cur.blocked.length) problems.push('mutating call on load: ' + cur.blocked.join(' ; '));
		if (cur.http.length) warns.push('http: ' + cur.http.slice(0, 5).join(' , '));
		if (cur.log.length) warns.push('log: ' + cur.log.slice(0, 3).join(' | '));
		if (cur.navs > 1) warns.push(`page reloaded ${cur.navs - 1}x`);
		if (m.spinning) warns.push(`${m.spinning} spinner(s) still visible`);
		if (m.scrollW > m.innerW + 1) warns.push(`horizontal overflow ${m.scrollW}>${m.innerW}`);
		const res = problems.length ? 'FAIL' : (warns.length ? 'WARN' : 'PASS');
		line(res, tag, secs, [...problems, ...warns].join('; ') || `nodes=${m.viewNodes} calls=${cur.calls.length}`);
		fs.writeFileSync(`${outdir}/${pg.name}-${width}.calls.txt`, cur.calls.join('\n') + '\n');

		if (pg.doctor && width === widths[widths.length - 1]) {
			cur.blocked = [];
			const r = await ev(`(async () => {
				const b = [...document.querySelectorAll('#doctorn button, #doctorn .cbi-button')][0];
				if (!b) return { err: 'no doctor button' };
				b.click();
				await new Promise(r => setTimeout(r, 4000));
				const l = document.getElementById('doctor-log');
				return { log: l ? l.innerText : '' };
			})()`) || {};
			const ok = /connection is fine|Подключение в порядке/i.test(r.log || '');
			const det = r.err || (r.log || '').replace(/\s+/g, ' ');
			if (cur.blocked.length) line('FAIL', 'page.detail.doctor-check', 4, 'doctor tried to act: ' + cur.blocked.join(' ; ') + ' | ' + det);
			else line(ok ? 'PASS' : 'FAIL', 'page.detail.doctor-check', 4, det);
		}
		cur = null;
	}
}
fs.writeFileSync(`${outdir}/pages.tsv`, results.join('\n') + '\n');
ws.close();
process.exit(0);
