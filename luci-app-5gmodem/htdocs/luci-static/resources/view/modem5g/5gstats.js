'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';
'require view.modem5g.modemtabs as modemtabs';
'require view.modem5g.mutil as mutil';

/* ВКЛАДКА «СТАТИСТИКА».
   Ряды копит stats.sh (RTT аплинков из сторожа, уровень сигнала из снимка
   метрик, помесячный трафик по интерфейсам). Здесь только отрисовка: свой
   минимальный canvas-рендер, без внешних библиотек - страница обязана
   работать на роутере без интернета и не тянуть CDN. */

var BIN = '/usr/share/5gmodem/stats.sh';

var _state = { list: null, series: {}, traffic: null };

function callStats(args) {
	return L.resolveDefault(fs.exec_direct(BIN, args), '').then(function(out) {
		try { return JSON.parse(out || 'null'); } catch (e) { return null; }
	});
}

/* Цвет линии по индексу ряда: различимы и в светлой, и в тёмной теме. */
var LINE_COLORS = [ '#2b8a3e', '#1c7ed6', '#e8590c', '#7048e8', '#c92a2a' ];

/* Минимальный график: сетка, ось значений, линия. Точки приходят как [t, v],
   t - uptime в секундах (растёт), поэтому ось X строим по относительному
   времени «сколько минут назад». */
function hexToRgba(hex, a) {
	var m = /^#?([a-f\d]{2})([a-f\d]{2})([a-f\d]{2})$/i.exec(hex);
	if (!m) { return hex; }
	return 'rgba(' + parseInt(m[1], 16) + ',' + parseInt(m[2], 16) + ',' + parseInt(m[3], 16) + ',' + a + ')';
}

/* Отрисовка графика. Приёмы подсмотрены в luci-app-bandix и адаптированы:
   - размер канвы считаем в ФИЗИЧЕСКИХ пикселях (devicePixelRatio), иначе на
     экранах с масштабированием линии и подписи мылятся;
   - под линией мягкая градиентная заливка - величина читается «объёмом», а не
     только положением;
   - геометрия расчёта сохраняется на самом элементе (__chart), чтобы обработчик
     мыши мог перевести координату курсора обратно в точку ряда и показать
     значения без перерисовки логики. */
function drawChart(canvas, series, opts) {
	opts = opts || {};
	var dpr = window.devicePixelRatio || 1;
	var rect = canvas.getBoundingClientRect();
	var W = Math.max(1, rect.width || canvas.clientWidth || 600);
	var H = Math.max(1, rect.height || 190);
	canvas.width = Math.floor(W * dpr);
	canvas.height = Math.floor(H * dpr);
	var ctx = canvas.getContext('2d');
	ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

	var padL = 52, padR = 12, padT = 12, padB = 24;
	var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
	var fg = dark ? '#c9ccd1' : '#444';
	var grid = dark ? 'rgba(255,255,255,.10)' : 'rgba(0,0,0,.08)';

	ctx.clearRect(0, 0, W, H);
	var all = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { all.push(p[1]); }); });
	if (!all.length) {
		ctx.fillStyle = fg; ctx.font = '12px sans-serif'; ctx.textAlign = 'center';
		ctx.fillText(_('No data yet'), W / 2, H / 2);
		canvas.__chart = null;
		return;
	}
	var vmax = Math.max.apply(null, all), vmin = Math.min.apply(null, all);
	if (opts.zeroBase) { vmin = 0; }
	if (vmax === vmin) { vmax = vmin + 1; }
	var pad = (vmax - vmin) * 0.12;
	vmax += pad; if (!opts.zeroBase) { vmin -= pad; }
	/* Фиксированная шкала (проценты 0..100): рамка не должна дышать от данных,
	   иначе «полшкалы» перестаёт значить «половину возможного». */
	if (opts.min != null) { vmin = opts.min; }
	if (opts.max != null) { vmax = opts.max; }

	var tAll = [];
	series.forEach(function(s) { (s.points || []).forEach(function(p) { tAll.push(p[0]); }); });
	var tmin = Math.min.apply(null, tAll), tmax = Math.max.apply(null, tAll);
	if (tmax === tmin) { tmax = tmin + 1; }

	var innerW = W - padL - padR, innerH = H - padT - padB;
	var x = function(t) { return padL + (t - tmin) / (tmax - tmin) * innerW; };
	var y = function(v) { return padT + (1 - (v - vmin) / (vmax - vmin)) * innerH; };

	ctx.strokeStyle = grid; ctx.fillStyle = fg;
	ctx.lineWidth = 1; ctx.font = '10px sans-serif'; ctx.textAlign = 'right';
	for (var i = 0; i <= 4; i++) {
		var v = vmin + (vmax - vmin) * i / 4, yy = Math.round(y(v)) + 0.5;
		ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(W - padR, yy); ctx.stroke();
		ctx.fillText(opts.fmt ? opts.fmt(v) : Math.round(v), padL - 6, yy + 3);
	}
	ctx.textAlign = 'left';
	ctx.fillText(_('%d min ago').format(Math.round((tmax - tmin) / 60)), padL, H - 7);
	ctx.textAlign = 'right';
	ctx.fillText(_('now'), W - padR, H - 7);

	series.forEach(function(s, idx) {
		var pts = s.points || [];
		if (!pts.length) { return; }
		var col = LINE_COLORS[idx % LINE_COLORS.length];
		/* Заливка под линией у КАЖДОГО ряда. При нескольких рядах делаем её
		   слабее, иначе перекрытия мешают читать график. */
		/* ГЕОМЕТРИЯ ЗАЛИВКИ И ЛИНИИ - ОДНА И ТА ЖЕ. Заливка строилась ломаной,
		   а линия рисуется сглаженной кривой: пути расходились, и градиент
		   вылезал за линию на изломах. Общий помощник кладёт в путь ровно те же
		   квадратичные сегменты, что и штрих. */
		/* Сглаживание квадратичными сегментами через середины отрезков: линия
		   мягкая, но форму данных держит плотнее кубического сплайна (тот при
		   резких перепадах уходил «резиной» за пределы точек). */
		var tracePath = function() {
			for (var q = 0; q < pts.length; q++) {
				var qpx = x(pts[q][0]), qpy = y(pts[q][1]);
				if (q === 0) { ctx.moveTo(qpx, qpy); continue; }
				var ppx = x(pts[q - 1][0]), ppy = y(pts[q - 1][1]);
				ctx.quadraticCurveTo(ppx, ppy, (ppx + qpx) / 2, (ppy + qpy) / 2);
			}
			ctx.lineTo(x(pts[pts.length - 1][0]), y(pts[pts.length - 1][1]));
		};

		if (true) {
			ctx.beginPath();
			tracePath();
			ctx.lineTo(x(pts[pts.length - 1][0]), padT + innerH);
			ctx.lineTo(x(pts[0][0]), padT + innerH);
			ctx.closePath();
			var grad = ctx.createLinearGradient(0, padT, 0, padT + innerH);
			var a0 = (series.length > 1) ? (dark ? 0.20 : 0.14) : (dark ? 0.38 : 0.28);
			grad.addColorStop(0, hexToRgba(col, a0));
			grad.addColorStop(1, hexToRgba(col, 0));
			ctx.fillStyle = grad;
			ctx.fill();
		}
		ctx.strokeStyle = col;
		ctx.lineWidth = 1.6;
		ctx.lineJoin = 'round'; ctx.lineCap = 'round';
		ctx.beginPath();
		tracePath();
		ctx.stroke();
	});

	canvas.__chart = { series: series, tmin: tmin, tmax: tmax, vmin: vmin, vmax: vmax,
		padL: padL, padT: padT, innerW: innerW, innerH: innerH, W: W, H: H,
		fmt: opts.fmt, opts: opts, dark: dark };

	/* курсор: вертикаль + значения всех рядов в этой точке */
	if (canvas.__hoverX != null) {
		var hx = canvas.__hoverX;
		if (hx >= padL && hx <= W - padR) {
			ctx.strokeStyle = dark ? 'rgba(255,255,255,.35)' : 'rgba(0,0,0,.30)';
			ctx.setLineDash([ 3, 3 ]); ctx.lineWidth = 1;
			ctx.beginPath(); ctx.moveTo(hx, padT); ctx.lineTo(hx, padT + innerH); ctx.stroke();
			ctx.setLineDash([]);
			var t = tmin + (hx - padL) / innerW * (tmax - tmin);
			var lines = [];
			series.forEach(function(s, idx) {
				var pts = s.points || [];
				if (!pts.length) { return; }
				var best = pts[0], bd = Math.abs(pts[0][0] - t);
				pts.forEach(function(p) { var d = Math.abs(p[0] - t); if (d < bd) { bd = d; best = p; } });
				lines.push({ c: LINE_COLORS[idx % LINE_COLORS.length], n: s.name,
					v: opts.fmt ? opts.fmt(best[1]) : String(best[1]) });
			});
			if (lines.length) {
				ctx.font = '11px sans-serif';
				var bw = 0;
				lines.forEach(function(l) { bw = Math.max(bw, ctx.measureText(l.n + '  ' + l.v).width); });
				bw += 22;
				var bh = lines.length * 15 + 8;
				var bx = (hx + bw + 10 < W) ? hx + 8 : hx - bw - 8;
				var by = padT + 4;
				ctx.fillStyle = dark ? 'rgba(20,22,26,.92)' : 'rgba(255,255,255,.94)';
				ctx.strokeStyle = grid;
				ctx.beginPath(); ctx.rect(bx, by, bw, bh); ctx.fill(); ctx.stroke();
				lines.forEach(function(l, i) {
					var ly = by + 15 * i + 14;
					ctx.fillStyle = l.c;
					ctx.fillRect(bx + 6, ly - 7, 8, 3);
					ctx.fillStyle = fg; ctx.textAlign = 'left';
					ctx.fillText(l.n + '  ' + l.v, bx + 18, ly);
				});
			}
		}
	}
}

function chartCard(title, id, legend) {
	var canvas = E('canvas', { 'id': id,
		'style': 'width:100%; height:190px; display:block; cursor:crosshair',
		/* Перерисовка курсора обязана идти С ТЕМИ ЖЕ опциями, что и штатная
		   отрисовка: раньше здесь собирался урезанный набор (fmt+zeroBase), и
		   фиксированная шкала процентов слетала бы при первом движении мыши. */
		'mousemove': function(ev) {
			var r = ev.target.getBoundingClientRect();
			ev.target.__hoverX = ev.clientX - r.left;
			if (ev.target.__chart) { drawChart(ev.target, ev.target.__chart.series,
				ev.target.__chart.opts); }
		},
		'mouseleave': function(ev) {
			ev.target.__hoverX = null;
			if (ev.target.__chart) { drawChart(ev.target, ev.target.__chart.series,
				ev.target.__chart.opts); }
		}
	});
	return E('div', { 'class': 'cbi-section tg5g' }, [
		E('h3', {}, [ title ]),
		E('div', { 'id': id + '-legend', 'style': 'display:flex; gap:1em; flex-wrap:wrap; margin-bottom:.4em; font-size:.9em' }, legend || []),
		canvas
	]);
}

function legendItem(name, idx) {
	return E('span', { 'style': 'display:inline-flex; align-items:center; gap:.35em' }, [
		E('span', { 'style': 'width:12px; height:3px; border-radius:2px; display:inline-block; background:'
			+ LINE_COLORS[idx % LINE_COLORS.length] }),
		E('span', {}, name)
	]);
}

/* Байты -> человеческий вид: «1.2 ГБ», «860 МБ», «12.4 КБ», «512 Б».
   mutil.localizeBytes только ПЕРЕВОДИТ готовые единицы (KiB -> КиБ) и сырое
   число ей скормить нельзя - в таблице висели голые байты. Считаем по 1024
   (как принято для объёма) и подписываем короткими единицами. */
function fmtBytes(n) {
	n = Number(n) || 0;
	var units = [ _('B'), _('KB'), _('MB'), _('GB'), _('TB') ];
	var i = 0;
	while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
	var d = (i === 0) ? 0 : (n < 10 ? 2 : (n < 100 ? 1 : 0));
	return n.toFixed(d) + ' ' + units[i];
}

/* Месяц по-человечески: "2026-08" -> "Август, 2026" (запрос владельца).
   Название берём у самого браузера с его локалью - собственный словарь месяцев
   пришлось бы переводить и поддерживать, а Intl уже знает все языки. Первую
   букву поднимаем: в русской локали месяц приходит строчным. */
function fmtMonth(ym) {
	var m = /^(\d{4})-(\d{2})$/.exec(String(ym || ''));
	if (!m) { return String(ym || ''); }
	var name = ym;
	try {
		name = new Date(+m[1], +m[2] - 1, 1).toLocaleString(undefined, { month: 'long' });
		name = name.charAt(0).toUpperCase() + name.slice(1);
	} catch (e) { return String(ym); }
	return name + ', ' + m[1];
}

/* ЗНАЧОК СТРОКИ ТРАФИКА. Трафик копится либо по SIM-карте (ключ "sim-<iccid>"),
   либо по интерфейсу - у старых записей и у не-модемных линков. Для карты берём
   иконку оператора, как в «Приоритете интернета»; для линка судим по имени:
   беспроводная станция - Wi-Fi, проводной - WAN. Не опознали - нейтральная
   иконка SIM, она же запасная у оператора без своей. */
function trafficIcon(key, label, opName) {
	var f;
	if (/^sim-/.test(String(key || ''))) {
		/* Имя оператора приходит ОТДЕЛЬНЫМ ярлыком (labels["op.<ключ>"]) и
		   запоминается за картой на роутере: снимок отдаёт оператора не всегда,
		   а значок должен быть постоянным. Подпись строки берём запасным
		   вариантом - в ней оператор есть, только если был известен в момент
		   записи. */
		f = mutil.operatorIcon(opName || '') || mutil.operatorIcon(label) || 'op-sim';
		f = 'icons/5gmodem/' + f + '.png';
	} else if (/^(wwan|wlan|phy|wifi)/i.test(String(key || ''))) {
		f = 'icons/5gmodem/cwifi.svg';
	} else if (/^(wan|eth|lan)/i.test(String(key || ''))) {
		f = 'icons/5gmodem/cwan.svg';
	} else {
		f = 'icons/5gmodem/op-sim.png';
	}
	return E('img', { 'src': L.resource(f), 'width': 18, 'height': 18, 'alt': '',
		'style': 'display:block' });
}

/* НОМЕР ТЕЛЕФОНА В ПОДПИСИ - В ТОМ ЖЕ ВИДЕ, ЧТО В КАРТОЧКЕ МОДЕМА.
   Бэкенд склеивает подпись как «<оператор> <номер>» и номер отдаёт сырым
   (+79654688753). Форматируем ту же цифровую часть тем же mutil.formatPhone,
   иначе в одном интерфейсе соседствуют два написания одного номера. */
function prettyTrafficLabel(label) {
	var s = String(label || '');
	/* Ряд без подписи приходит СЫРЫМ КЛЮЧОМ «sim-8970...»: подпись потерялась
	   (напр. симка вынута, а её ярлык не пережил ребут на старой версии).
	   Показываем «ICCID: 8970...» - так же сборщик подписывает карты без
	   номера, и когда номер появится, строка с тем же ключом просто сменит
	   подпись, не теряя истории. */
	var m = s.match(/^sim-(\d{6,})$/);
	if (m) { return 'ICCID: ' + m[1]; }
	/* ICCID в подписи длиннее телефона и попал бы под телефонную маску -
	   не форматируем такие строки. */
	if (/ICCID:/.test(s)) { return s; }
	return s.replace(/\+?\d[\d\s()-]{9,}\d/, function(m2) { return mutil.formatPhone(m2); });
}

/* Таблица помесячного трафика: ключи приходят как "<sim|iface>|<YYYY-MM>". */
function trafficTable(data, labels) {
	var rows = [ E('tr', { 'class': 'tr table-titles' }, [
		/* Колонка значка - без заголовка: подпись «значок» ничего не добавляет,
		   а ширину съедает. */
		E('th', { 'class': 'th', 'style': 'width:1%' }, [ '' ]),
		E('th', { 'class': 'th' }, [ _('SIM card') ]),
		E('th', { 'class': 'th' }, [ _('Month') ]),
		E('th', { 'class': 'th' }, [ _('Received') ]),
		E('th', { 'class': 'th' }, [ _('Sent') ]),
		E('th', { 'class': 'th' }, [ _('Total') ]),
		/* Колонка корзины - без заголовка, как у значка. */
		E('th', { 'class': 'th', 'style': 'width:1%' }, [ '' ])
	]) ];
	var keys = Object.keys(data || {}).sort();
	keys.forEach(function(k) {
		var parts = k.split('|'), v = data[k] || {};
		var rx = parseInt(v.rx, 10) || 0, tx = parseInt(v.tx, 10) || 0;
		/* Строка озаглавлена SIM-картой (оператор и номер, если карта его
		   отдала) - трафик тарифицирует оператор, а не модем. Ключи вида
		   "sim-<iccid>" несут свою подпись; старые записи, накопленные по
		   интерфейсу, показываем как раньше - по имени линка. */
		var lab = (labels || {})[parts[0]] || (labels || {})['ping.' + parts[0]] || parts[0];
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'style': 'width:1%' },
				[ trafficIcon(parts[0], lab, (labels || {})['op.' + parts[0]]) ]),
			E('td', { 'class': 'td' }, [ prettyTrafficLabel(lab) ]),
			E('td', { 'class': 'td' }, [ fmtMonth(parts[1]) ]),
			E('td', { 'class': 'td' }, [ fmtBytes(rx) ]),
			E('td', { 'class': 'td' }, [ fmtBytes(tx) ]),
			E('td', { 'class': 'td' }, [ fmtBytes(rx + tx) ]),
			E('td', { 'class': 'td', 'style': 'width:1%' }, [
				/* Маленький крестик в круге, а не кнопка-корзина (решение
				   владельца): это чистка строки, ей незачем выглядеть тяжелее
				   самих данных. Свои стили вместо классов кнопок - темы дают
				   кнопкам крупные поля и рамки. */
				E('button', {
					'title': _('Delete this row'),
					'style': 'width:20px;height:20px;padding:0;border-radius:50%;' +
					         'border:1px solid rgba(128,128,128,.45);background:transparent;' +
					         'color:inherit;opacity:.6;cursor:pointer;line-height:1;' +
					         'display:inline-flex;align-items:center;justify-content:center;' +
					         'font-size:13px',
					'mouseover': function(ev) { ev.currentTarget.style.opacity = '1'; },
					'mouseout': function(ev) { ev.currentTarget.style.opacity = '.6'; },
					'click': function(ev) { forgetTrafficRow(ev.currentTarget, parts[0], parts[1]); }
				}, '×')
			])
		]));
	});
	if (keys.length === 0) {
		rows.push(E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td', 'colspan': '7' }, [ _('No data yet') ])
		]));
	}
	return E('table', { 'class': 'table' }, rows);
}

/* Удаление строки отчёта. Свежая строка активного аплинка возродится со
   следующим тиком (счёт пойдёт заново с нуля) - это ожидаемо; строки вынутых
   карт и старых месяцев уходят насовсем, поэтому короткое подтверждение. */
function forgetTrafficRow(btn, key, month) {
	if (!confirm(_('Delete this traffic row? This cannot be undone.'))) { return; }
	btn.disabled = true;
	callStats([ 'forget', key, month ]).then(function() {
		return callStats([ 'traffic' ]);
	}).then(function(t) {
		_state.traffic = t || {};
		var tt = document.getElementById('traffic-table');
		if (tt) {
			tt.innerHTML = '';
			tt.appendChild(trafficTable(_state.traffic, (_state.list || {}).labels || {}));
		}
	});
}

function redraw() {
	var lst = _state.list || {};
	/* Пинги: по ряду на аплинк, все в одном полотне - так видно, какой линк
	   проседает относительно других. */
	var lab = lst.labels || {};
	var pingSeries = (lst.ping || []).map(function(n) {
		return { name: lab['ping.' + n] || n, points: (_state.series['ping.' + n] || []) };
	});
	var c1 = document.getElementById('chart-ping');
	if (c1) { drawChart(c1, pingSeries, { zeroBase: true, fmt: function(v) { return Math.round(v) + ' ms'; } }); }
	var l1 = document.getElementById('chart-ping-legend');
	if (l1) { l1.innerHTML = ''; pingSeries.forEach(function(s, i) { l1.appendChild(legendItem(s.name, i)); }); }

	var sigSeries = (lst.signal || []).map(function(n) {
		return { name: lab['signal.' + n] || n.replace(/_/g, ' '), points: (_state.series['signal.' + n] || []) };
	});
	/* Сигнал приходит в процентах (поле signal снимка, та же величина, что у
	   планки на главной) - шкала жёсткая 0..100, чтобы высота линии читалась
	   как «сколько от максимума», а не плясала от разброса данных. */
	var c2 = document.getElementById('chart-signal');
	if (c2) { drawChart(c2, sigSeries, { min: 0, max: 100, fmt: function(v) { return Math.round(v) + '%'; } }); }
	var l2 = document.getElementById('chart-signal-legend');
	if (l2) { l2.innerHTML = ''; sigSeries.forEach(function(s, i) { l2.appendChild(legendItem(s.name, i)); }); }

	var tempSeries = (lst.temp || []).map(function(n) {
		return { name: lab['temp.' + n] || n.replace(/_/g, ' '), points: (_state.series['temp.' + n] || []) };
	});
	var c3 = document.getElementById('chart-temp');
	if (c3) { drawChart(c3, tempSeries, { fmt: function(v) { return Math.round(v) + ' °C'; } }); }
	var l3 = document.getElementById('chart-temp-legend');
	if (l3) { l3.innerHTML = ''; tempSeries.forEach(function(s, i) { l3.appendChild(legendItem(s.name, i)); }); }
	var tc = document.getElementById('card-temp');
	if (tc) {
		var wasHidden = (tc.style.display === 'none');
		tc.style.display = tempSeries.length ? '' : 'none';
		/* Пока карточка скрыта, у канвы нулевая ширина - рисовать в неё
		   бессмысленно. Стала видимой - перерисовываем сразу, не дожидаясь
		   следующего тика, иначе на графике висит «Данных пока нет». */
		if (wasHidden && tempSeries.length && c3) {
			drawChart(c3, tempSeries, { fmt: function(v) { return Math.round(v) + ' °C'; } });
		}
	}

	var tt = document.getElementById('traffic-table');
	if (tt) { tt.innerHTML = ''; tt.appendChild(trafficTable(_state.traffic, lab)); }
}

/* Забрать списки рядов и сами точки. Рядов немного (по одному на аплинк),
   поэтому тянем их параллельно одним заходом. */
/* Строка «куда реально пишем». Отдельной функцией: её же зовёт обработчик поля
   пути (общий refresh перерисовывает только графики, но не блок настроек). */
function pathNowText(lst) {
	lst = lst || {};
	if (!lst.persist) { return _('Storing is off - data lives in RAM until the next reboot.'); }
	if (lst.path && lst.path_now && lst.path_now !== lst.path) {
		return _('The drive is not mounted - writing to %s for now, and merging back when it returns.').format(lst.path_now);
	}
	return lst.path_now ? _('Writing to %s').format(lst.path_now) : _('Nowhere to write - check the path.');
}

function refresh() {
	return callStats([ 'list' ]).then(function(lst) {
		_state.list = lst || {};
		var names = [];
		(lst && lst.ping || []).forEach(function(n) { names.push('ping.' + n); });
		(lst && lst.signal || []).forEach(function(n) { names.push('signal.' + n); });
		(lst && lst.temp || []).forEach(function(n) { names.push('temp.' + n); });
		return Promise.all(names.map(function(n) {
			return callStats([ 'series', n ]).then(function(r) {
				_state.series[n] = (r && r.series) || [];
			});
		})).then(function() {
			return callStats([ 'traffic' ]).then(function(t) { _state.traffic = t || {}; });
		});
	}).then(redraw);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('5gmodem'),
			callStats([ 'list' ])
		]);
	},

	render: function(res) {
		var lst = (res && res[1]) || {};
		_state.list = lst;

		/* ПОЛОСЫ ВКЛАДОК ЗДЕСЬ НЕТ. Статистика общая для всей системы (ряды по
		   всем аплинкам и модемам сразу), выбирать «текущий» модем незачем -
		   переключатель только сбивал бы с толку. */
		var head = E('div');

		var controls = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Statistics') ]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Keep monthly traffic across reboots') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'type': 'checkbox', 'id': 'st-persist', 'checked': (lst.persist ? '' : null),
						'change': function(ev) {
							callStats([ 'setconf', 'persist=' + (ev.target.checked ? '1' : '0') ]).then(function() {
								return callStats([ 'list' ]).then(function(lst2) {
									_state.list = lst2 || {};
									var el = document.getElementById('st-path-now');
									if (el) { el.textContent = pathNowText(lst2); }
								});
							});
						}
					}),
					E('div', { 'class': 'cbi-value-description' },
						[ _('Monthly totals are written to flash about once an hour. Ping series are never written there.') ])
				])
			]),
			/* КУДА ПИШЕМ. Пустое поле = внутренняя память роутера; свой путь
			   нужен тем, у кого в роутер воткнута флешка и хочется полный лог,
			   а не только месячные итоги. Строка ниже показывает РЕАЛЬНЫЙ
			   каталог: если флешку выдернули, запись идёт в запасной, и
			   человек должен это видеть, а не узнавать через месяц. */
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Where to store') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'type': 'text', 'class': 'cbi-input-text', 'id': 'st-path',
						'value': lst.path || '', 'placeholder': lst.path_default || '/etc/5gmodem/stats',
						'style': 'width:22em;max-width:100%',
						'change': function(ev) {
							callStats([ 'setconf', 'path=' + String(ev.target.value || '').trim() ]).then(function(r) {
								var el = document.getElementById('st-path-now');
								if (r && r.error) { if (el) { el.textContent = _('Path rejected: %s').format(r.error); } return; }
								return callStats([ 'list' ]).then(function(lst2) {
									_state.list = lst2 || {};
									if (el) { el.textContent = pathNowText(lst2); }
								});
							});
						}
					}),
					E('div', { 'class': 'cbi-value-description' }, [
						E('div', {}, [ _('Empty - the router\'s own memory (%s). A path on a USB drive also gets the chart series, not just monthly totals.').format(lst.path_default || '/etc/5gmodem/stats') ]),
						E('div', { 'id': 'st-path-now', 'style': 'margin-top:4px' }, [ pathNowText(lst) ])
					])
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ _('Reset statistics') ]),
				E('div', { 'class': 'cbi-value-field' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(this, function() {
							return callStats([ 'reset' ]).then(function() {
								_state.series = {}; _state.traffic = {};
								return refresh();
							});
						})
					}, [ _('Reset') ])
				])
			])
		]);

		var body = E('div', {}, [
			head,
			controls,
			chartCard(_('Uplink latency'), 'chart-ping'),
			chartCard(_('Signal level'), 'chart-signal'),
			E('div', { 'id': 'card-temp', 'style': 'display:none' }, [
				chartCard(_('Modem temperature'), 'chart-temp')
			]),
			E('div', { 'class': 'cbi-section tg5g' }, [
				E('h3', {}, [ _('Monthly traffic') ]),
				E('div', { 'id': 'traffic-table' }, [])
			])
		]);

		/* СВОЙ ТИК ПРИ ОТКРЫТОЙ СТРАНИЦЕ. Фоновый сборщик ходит раз в 30 c
		   (шаг sessionwatch) - для «живого» графика этого мало. Пока страница
		   открыта, дёргаем сбор сами каждые 10 c: точки те же, просто чаще. */
		refresh();
		poll.add(function() {
			return callStats([ 'tick' ]).then(refresh);
		}, 10);
		return body;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
