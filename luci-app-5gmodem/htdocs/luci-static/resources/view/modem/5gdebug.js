'use strict';
'require view';
'require view.modem.modemtabs as modemtabs';
'require dom';
'require fs';
'require ui';
'require uci';
'require form';
'require tools.widgets as widgets';

/*
	Copyright 2021-2026 Rafał Wabik - IceG - From eko.one.pl forum

	Licensed to the GNU General Public License v3.0.
*/

/* Проверка/установка обновления переехали на вкладку «Настройки»
   (view modem/5gsettings) вместе с блоком «Обновление». */

/* Экземпляр вьюхи - чтобы обновлять карточки профилей из обработчиков, которые
   лежат вне их области видимости (кнопка «создать интерфейс»). */
var profilesView = null;

/* Пометка режима в имени модема. (HiLink) - ведётся своим веб-API; (Debug) -
   переведён в режим с AT-портами и ведётся обычным путём. */
function modeSuffix(j) {
	if (j.backend === 'hilink') { return ' (HiLink)'; }
	if (j.at_debug === '1') { return ' (Debug)'; }
	return '';
}

return view.extend({
	handleCommand: function(exec, args) {
		var buttons = document.querySelectorAll('.diag-action > .cbi-button');

		for (var i = 0; i < buttons.length; i++)
			buttons[i].setAttribute('disabled', 'true');

		return fs.exec(exec, args).then(function(res) {
			var out = document.getElementById('pre');
			out.style.display = '';

			/* Та же тёмная табличка, что у блоков команд. Лёгкая подсветка:
			   строки трассировки "sh -x" (+ команда) - голубым, stderr - красным. */
			var lines = ((res.stdout || '') + (res.stderr ? '\n' + res.stderr : '')).split('\n');
			var spans = lines.map(function(ln) {
				var color = '#d6e0ea';
				if (/^\++ /.test(ln)) { color = '#7db2ff'; }
				return E('div', { 'style': 'color:' + color }, ln.length ? ln : ' ');
			});
			dom.content(document.getElementById('preout'), spans);
			fs.write('/tmp/debug_result.txt', [ res.stdout || '' ]);
		}).catch(function(err) {
			ui.addNotification(null, E('p', [ err ]))
		}).finally(function() {
			var viewbc = document.getElementById('clear');
			viewbc.style.display = '';
			var viewbd = document.getElementById('download');
			viewbd.style.display = '';

			for (var i = 0; i < buttons.length; i++)
				buttons[i].removeAttribute('disabled');
		});
	},

	handleUSB: function(ev, cmd) {
		return this.handleCommand('/bin/cat', ['/sys/kernel/debug/usb/devices']);
	},

	handleTTY: function(ev, cmd) {
		return this.handleCommand('/bin/ls', ['/dev']);
	},

	handleDBG: function(ev, cmd) {
		return this.handleCommand('/bin/sh', ['-x', '/usr/share/5gmodem/5gmodem.sh']);
	},

	handleClear: function(ev) {
		var out = document.getElementById('pre');
		out.style.display = 'none';
		dom.content(document.getElementById('preout'), []);
		var viewbc = document.getElementById('clear');
		viewbc.style.display = 'none';
		var viewbd = document.getElementById('download');
		viewbd.style.display = 'none';
		fs.write('/tmp/debug_result.txt', '');
	},

	handleDownload: function(ev) {
		return L.resolveDefault(fs.read_direct('/tmp/debug_result.txt'), null).then(function (res) {
				if (res) {
					var link = E('a', {
						'download': 'debug_result.txt',
						'href': URL.createObjectURL(
							new Blob([ res ], { type: 'text/plain' })),
					});
					link.click();
					URL.revokeObjectURL(link.href);
				}
			}).catch(() => {
				ui.addNotification(null, E('p', {}, _('Download error') + ': ' + err.message));
		});

	},

	load: function() {
		return Promise.all([
			/* НЕ ЖДЁМ ОПРОС МОДЕМА. Раньше здесь стоял '5gmodem.sh json' -
			   полный проход по AT-командам, 8 секунд на живом LT300, и всё это
			   время страница не отрисовывалась вовсе. Информацию о модеме
			   заполняем ПОСЛЕ отрисовки (см. fillModemInfo), как это давно
			   сделано на странице «Сеть». */
			Promise.resolve(''),
			fs.list('/dev').then(function(devs) {
				return devs.filter(function(dev) {
					return dev.name.match(/^ttyUSB/) || dev.name.match(/^cdc-wdm/) || dev.name.match(/^ttyACM/) || dev.name.match(/^mhi_/) || dev.name.match(/^wwan/);
				});
			}),
			L.resolveDefault(uci.load('5gmodem')),
			L.resolveDefault(uci.load('sms_tool_js')),
			L.resolveDefault(uci.load('network')),
			// установленные обработчики протоколов (luci-proto-*): по ним строим
			// список доступных типов интерфейса для кнопки создания
			L.resolveDefault(fs.list('/www/luci-static/resources/protocol'), []),
			// карта портов -> модем (vid:pid, модель), чтобы подписать выпадашки
			// портов: какой /dev/ttyUSB* какому модему принадлежит
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listports.sh'), '{}'),
			/* Светодиоды уровня сигнала: есть ли они на этом устройстве.
			   Читаем каталог, а не запускаем скрипт - путь /sys/class/leds
			   разрешён в ACL, и лишнего процесса на открытие страницы нет. */
			L.resolveDefault(fs.list('/sys/class/leds'), [])
		]);
	},

	/* ИНДИКАТОР НА СВЕТОДИОДАХ - ОТДЕЛЬНЫМ БЛОКОМ, ВНЕ form.Map.
	   Внутри формы он требовал бы нажать «Сохранить», а сохранение ЭТОЙ страницы
	   переписывает поля портов (они скрыты при автоопределении) - именно так
	   однажды и пропали метрики. Настройка светодиодов не должна тянуть за собой
	   такой риск, поэтому применяем её сразу, своим вызовом. */
	/* Карточки профилей + предупреждение о питании. Ставится НАВЕРХ страницы:
	   это состояние, от которого зависит всё остальное на ней.

	   Профили - это секции 5gmodem.m_*, которые и раньше переживали отключение
	   модема, но были невидимы. Их невидимость дорого обошлась: секция вынутого
	   Telit продолжала claim'ить имя интерфейса, из-за чего Compal подхватил
	   чужой proto=qmi к своему MBIM-железу и не поднимался. Пользователь находил
	   такое глазами в uci, а не в интерфейсе. */
	renderProfiles: function() {
		/* СВОИ стили обязательны. Карточка носит класс .btn ради вида кнопки, но
		   в теме .btn - это flex-контейнер со строчным направлением: внутренние
		   блоки выстраивались В РЯД, и карточка расползалась (наблюдалось:
		   модель, статус, интерфейс и IMEI встали четырьмя колонками, кнопка
		   «Удалить» уехала на соседнюю карточку). Тем же лечим и плашку -
		   alert-message в теме тоже flex. */
		if (!document.getElementById('mprof-css')) {
			document.head.appendChild(E('style', { 'id': 'mprof-css', 'type': 'text/css' },
				/* Колонка, а НЕ block: карточки в ряду равновысоки (flex:1 у box),
				   и подвал (mprof-foot) с margin-top:auto прижимается к низу. Иначе
				   у карточки с меньшим числом строк (напр. без pdp/веб-адреса)
				   IMEI/путь/«Удалить» висели по центру, а не по нижнему краю. */
				/* padding с !important: у proton2025 .btn/.cbi-button свой БОЛЬШОЙ
				   паддинг (с !important), он перебивал наш inline .6em .8em -
				   карточки распухали изнутри. Id-scoped правило + !important бьёт.
				   align-items/justify-content ТОЖЕ перебиваем: тема задаёт .btn
				   {align-items:center;justify-content:center} - в нашей flex-КОЛОНКЕ
				   это центрировало детей по горизонтали (они сжимались по контенту,
				   а по бокам зияли огромные пустые поля). stretch тянет строки на
				   всю ширину, flex-start ставит их от верха. */
				'#mprof-list .mprof-card{display:flex!important;flex-direction:column;text-align:left;' +
				'align-items:stretch!important;justify-content:flex-start!important;' +
				'white-space:normal;line-height:1.35;height:auto;padding:.6em .8em!important;}' +
				'#mprof-list .mprof-card>div{display:block;width:auto;}' +
				'#mprof-list .mprof-head{display:flex!important;justify-content:space-between;' +
				'align-items:flex-start;gap:.5em;margin-bottom:.15em;}' +

				'#mprof-list .mprof-card .btn{display:inline-block;margin-left:0;}' +
				/* Низ карточки: идентификатор слева, кнопка справа, ПРИЖАТ К НИЗУ
				   (margin-top:auto в flex-колонке съедает лишнюю высоту сверху). */
				'#mprof-list .mprof-foot{display:flex!important;justify-content:space-between;' +
				'align-items:flex-end;gap:.6em;margin-top:auto;padding-top:.5em;}' +
				/* Имя модема и имя интерфейса - моноширинным: это идентификаторы,
				   а не проза, и в моноширинном их проще сверять глазами. */
				'#mprof-list .mprof-name{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;}' +
				'#mprof-list .mprof-if{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;}' +
				/* Тот же красный, что у кнопки «Удалить» в теме - чтобы «плохо»
				   выглядело одинаково во всей карточке. Оба варианта темы. */
				'#mprof-list .mprof-lowpower{background:rgba(255,107,107,.1)!important;' +
				'border-color:rgba(255,107,107,.3)!important;}' +
				':root[data-theme="light"] #mprof-list .mprof-lowpower{' +
				'background:rgba(245,101,101,.15)!important;' +
				'border-color:rgba(245,101,101,.4)!important;}' +
				/* Рамка - у ПРОТОКОЛА: это выбор, который делает пользователь, и
				   именно его сверяют глазами между профилями. Имя интерфейса
				   рядом - просто моноширинным. */
				'#mprof-list .mprof-line{display:flex!important;justify-content:space-between;' +
				'align-items:baseline;gap:.6em;font-size:88%;opacity:.85;margin-top:.2em;}' +
				/* Вертикальные поля нужны из-за значка-призрака: он выше строчной
				   буквы и без них упирался макушкой в верхнюю границу рамки.
				   inline-flex с центрированием держит значок и текст на одной
				   линии независимо от их высоты. */
				'#mprof-list .mprof-proto{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;' +
				'border:1px solid currentColor;border-radius:5px;padding:.12em .35em;' +
				'display:inline-flex;align-items:center;' +
				'opacity:.85;white-space:nowrap;}'));
		}
		var box = E('div', { 'id': 'mprof-box' }, [
			E('div', { 'id': 'mprof-warn' }),
			E('div', {
				'id': 'mprof-list',
				'style': 'display:flex; flex-wrap:wrap; gap:.6em; margin-bottom:.4em'
			}, [ E('span', { 'style': 'opacity:.6' }, _('Loading…')) ]),
			/* Состояние службы - ПОД карточками: это сноска ко всему списку, а не
			   заголовок. Сверху она отвлекала от самих профилей. */
			E('div', { 'id': 'mprof-mm', 'style': 'margin-top:.5em' })
		]);
		profilesView = this;
		this.loadProfiles();
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Saved modem profiles')),
			box
		]);
	},

	/* Перечитать карточки. Отдельным методом, чтобы звать и после пересоздания
	   интерфейса: блок рисуется один раз и сам не опрашивается, поэтому раньше
	   карточка показывала старый интерфейс и протокол до перезагрузки страницы
	   (ровно как значок протокола выше - там это чинят тем же приёмом). */
	loadProfiles: function() {
		var self = this;
		return Promise.all([
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'profiles' ]), '[]'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/powercheck.sh'), '{}'),
			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/mmneed.sh', [ 'check' ]), '{}')
		]).then(function(res) {
			var list = [], pw = {}, mm = {};
			try { list = JSON.parse(res[0]) || []; } catch (e) {}
			try { pw = JSON.parse(res[1]) || {}; } catch (e) {}
			try { mm = JSON.parse(res[2]) || {}; } catch (e) {}
			self.fillProfiles(list, pw, mm);
		});
	},

	fillProfiles: function(list, pw, mm) {
		/* Состояние ModemManager - ОДНОЙ строкой на раздел, а не точкой на каждой
		   карточке: служба одна на роутер, и повторять её у трёх модемов значило
		   бы показывать одно и то же трижды. Тем более теперь она сама
		   останавливается - строка объясняет, куда она делась. */
		var mmrow = document.getElementById('mprof-mm');
		if (mmrow) {
			var run = mm && mm.running == 1;
			mmrow.innerHTML = '';
			mmrow.appendChild(E('span', {
				'style': 'display:inline-block;width:.6em;height:.6em;border-radius:50%;' +
					'margin-right:.45em;vertical-align:middle;background:' +
					(run ? '#5cb85c' : '#d9534f')
			}));
			mmrow.appendChild(E('span', { 'style': 'opacity:.75; font-size:88%' },
				run ? _('ModemManager is running')
				    : _('ModemManager is stopped — no connected modem needs it')));
		}
		var warn = document.getElementById('mprof-warn');
		var box = document.getElementById('mprof-list');
		if (!box) { return; }

		/* Нехватка питания. Модем при этом не пропадает, а поднимается ЧАСТИЧНО -
		   выглядит как программная поломка, и без подсказки причина не видна
		   (на поиск однажды ушло полдня). */
		if (warn && pw && pw.suspect) {
			warn.innerHTML = '';
			var mA = parseInt(pw.total_ma, 10) || 0;
			/* Содержимое - ОДНИМ дочерним узлом. Плашка в теме flex-контейнер:
			   несколько детей вставали колонками, а переопределять ей display
			   нельзя - на нём держится цветная полоса слева. */
			warn.appendChild(E('div', {
				'class': 'alert-message warning',
				'style': 'margin-bottom:.6em'
			}, [
				E('div', {}, [
					E('strong', {}, _('Not enough power?') + ' '),
					_('%d modems request %d mA. Such a modem answers AT commands, but its interface stays down — a powered USB hub helps.')
						.format(parseInt(pw.modems, 10) || 0, mA)
				])
			]));
		} else if (warn) { warn.innerHTML = ''; }

		box.innerHTML = '';
		if (!list.length) {
			box.appendChild(E('span', { 'style': 'opacity:.6' }, _('No modems seen yet.')));
			return;
		}
		var self = this;

		/* Пометки считаем ДО отрисовки: если они есть хоть у одной карточки,
		   остальным отдаём такую же строку-пустышку. Иначе карточки в ряду
		   получаются разной высоты и низ (идентификатор, кнопка) не совпадает. */
		var marksOf = function(p) {
			var out = [];
			if (p.celllock) {
				var cl = String(p.celllock).split(' ');
				out.push({ txt: cl[0] === 'cell'
					? _('locked to cell %s/%s').format(cl[1], cl[2])
					: _('locked to frequency %s').format(cl[1]), color: '#d9534f' });
			}
			/* Видимость для MM отмечаем, только когда она РАСХОДИТСЯ с протоколом:
			   совпадение - норма, а расхождение рвёт связь (MM отбирает канал). */
			var isMM = (String(p.proto).toLowerCase() === 'modemmanager');
			if (p.mm_exclude === '0' && !isMM && p.proto) {
				out.push({ txt: _('visible to ModemManager'), color: '#e58a00' });
			} else if (p.mm_exclude === '1' && isMM) {
				out.push({ txt: _('hidden from ModemManager'), color: '#e58a00' });
			}
			return out;
		};
		var anyMarks = list.some(function(p) { return marksOf(p).length > 0; });
		var mmRunning = !!(mm && mm.running == 1);
		/* Модемы, у которых не поднялся управляющий интерфейс - вероятная
		   нехватка питания (см. powercheck.sh). Их отмечаем прямо на карточке:
		   общая плашка сверху говорит, ЧТО случилось, а метка - С КЕМ. */
		var lowPower = ' ' + String((pw && pw.paths) || '') + ' ';
		list.forEach(function(p) {
			/* Стиль карточки - как у кнопок приоритета интернета: активный
			   выделяем рамкой, отключённый приглушаем, но НЕ прячем - именно
			   невидимость мёртвых профилей нас и подводила. */
			var st = 'flex:1 1 18em; min-width:16em; text-align:left; padding:.6em .8em; ' +
				'border-radius:8px; cursor:default;';
			if (p.active) { st += 'border-color:var(--proton-accent,#3a7bd5);'; }
			if (!p.present) { st += 'opacity:.6;'; }
			/* Модему не хватило питания - красим КАРТОЧКУ ЦЕЛИКОМ. Метка на одном
			   имени интерфейса терялась: беда тут не с именем, а со всем модемом. */
			var isLow = lowPower.indexOf(' ' + p.path + ' ') >= 0;

			/* Волосяная линия под именем и VID:PID. Граница смысловая: выше -
			   что это за железо, ниже - как оно настроено. currentColor, чтобы
			   линия жила в обеих темах и гасла вместе с карточкой отключённого
			   модема, а не спорила с ней своим цветом. */
			var head = E('div', {
				'style': 'border-bottom:1px solid currentColor; padding-bottom:.4em;'
			}, [
				E('div', { 'class': 'mprof-head' }, [
					/* СЛЕВА колонкой: имя и под ним vid:pid - вместе, чтобы vid:pid
					   был вплотную к имени. Раньше vid:pid шёл ПОСЛЕ всей строки
					   head, и когда справа было две строки (статус + веб-адрес
					   HiLink), он проваливался вниз - под именем зиял отступ. */
					E('div', { 'style': 'min-width:0' }, [
						E('strong', { 'class': 'mprof-name' }, p.model || p.path),
						p.vidpid ? E('div', {
							'class': 'mprof-name',
							'style': 'font-size:78%; opacity:.55; margin-top:-.15em'
						}, p.vidpid) : ''
					]),
					/* СПРАВА колонкой: статус, под ним - адрес веб-админки HiLink
					   (у такого модема настройки делаются там), это тоже «где модем».
					   Только присутствие: активность показывает рамка. */
					E('div', { 'style': 'display:flex; flex-direction:column; align-items:flex-end; gap:.1em; white-space:nowrap' }, [
						E('span', { 'style': 'font-size:85%; opacity:.8' },
							p.present ? _('connected') : _('not connected')),
						(p.kind === 'hilink' && p.webaddr) ? E('a', {
							'href': 'http://' + p.webaddr + '/html/home.html',
							'target': '_blank', 'rel': 'noreferrer',
							'style': 'font-size:78%; opacity:.7'
						}, p.webaddr) : ''
					])
				])
			]);
			/* Линию делаем едва заметной ОТДЕЛЬНО от текста: opacity на всём блоке
			   притушил бы и название модема. */
			head.style.borderBottomColor = 'rgba(128,128,128,.35)';

			/* Тип PDP показываем В ЕДИНОМ виде. В конфиге он хранится по-разному
			   намеренно: fibocom/atc требуют IPV4V6, qmi/mbim - ipv4v6 (см.
			   mkiface.sh). Это деталь протокола, и выносить её в карточку значит
			   заставлять пользователя гадать, отчего у двух модемов разный
			   регистр. Храним как надо протоколу, показываем читаемо: IPv4v6. */
			/* Общепринятые сокращения - заглавными, собственные имена прото
			   (fibocom, modemmanager) - как есть. */
			var protoNice = ({
				'qmi': 'QMI', 'mbim': 'MBIM', 'ncm': 'NCM', 'xmm': 'XMM',
				'atc': 'ATC', 'ppp': 'PPP', 'wwan': 'WWAN', '3g': '3G'
			})[String(p.proto || '').toLowerCase()] || (p.proto || '—');
			/* У модема без AT-портов протокол интерфейса всегда dhcp, и писать это
			   в карточке бесполезно: важно не как поднят интерфейс, а что модемом
			   правит его собственный веб-интерфейс, а не мы. */
			var isHilink = (p.kind === 'hilink');
			if (isHilink) { protoNice = 'HiLink'; }
			var pdpNice = '';
			if (p.pdptype) {
				pdpNice = ({
					'ipv4v6': 'IPv4v6', 'ipv4': 'IPv4', 'ipv6': 'IPv6'
				})[String(p.pdptype).toLowerCase()] || p.pdptype;
			}

			var card = E('div', {
				'class': 'btn cbi-button mprof-card' + (isLow ? ' mprof-lowpower' : ''),
				'title': isLow ? _('the data interface did not come up — not enough power?') : '',
				'style': st
			}, [
				head,
				/* Два столбца: слева чем модем поднимается (интерфейс, протокол),
				   справа чем он ходит в сеть (APN, тип адреса). Правый столбец
				   выровнен по краю - так значения удобно сверять между карточками. */
				E('div', { 'class': 'mprof-line', 'style': 'margin-top:.45em' }, [
					E('span', { 'class': 'mprof-if' }, p.iface || _('no interface')),
					E('span', {}, [
						E('strong', {}, 'APN:'), ' ',
						/* Пустой APN не «неизвестен», а провайдерский по умолчанию. */
						p.apn || _('default')
					])
				]),
				E('div', { 'class': 'mprof-line' }, [
					/* Слева - протокол и (если есть) метка eSIM, сгруппированы вместе.
					   Раньше pdpNice был ТРЕТЬИМ ребёнком space-between и оказывался
					   ПО ЦЕНТРУ; тип адреса должен стоять под APN у правого края. */
					E('span', { 'style': 'display:flex; align-items:baseline; gap:.6em; min-width:0' }, [
						E('span', { 'class': 'mprof-proto' }, [
							/* Призрак = «этот модем спрятан от ModemManager». Показываем
							   ТОЛЬКО когда MM работает: при остановленной службе прятаться
							   не от кого, и значок был бы про несуществующее. */
							mmRunning && p.mm_exclude !== '0' ? E('img', {
								'src': L.resource('icons/cghost.svg'),
								'width': 12, 'height': 12, 'alt': '',
								'title': _('hidden from ModemManager'),
								'style': 'margin-right:.3em; opacity:.75; flex:0 0 auto'
							}) : '',
							protoNice
						]),
						/* Судьба вкладки eSIM у ЭТОГО модема. Показываем только когда
						   есть что сказать; ручное решение помечаем особо. */
						p.esim ? E('span', {
							'style': 'opacity:.8',
							'title': (p.esim === 'forced-yes' || p.esim === 'forced-no')
								? _('set manually in the modem settings')
								: _('detected by probing the modem')
						}, [
							'eSIM: ',
							p.esim === 'yes'        ? _('yes') :
							p.esim === 'no'         ? _('no')  :
							p.esim === 'forced-yes' ? _('yes (manually)') :
							                          _('no (manually)')
						]) : ''
					]),
					/* Тип адреса - у ПРАВОГО края, под APN (см. коммент выше). */
					E('span', { 'style': 'opacity:.8; flex:0 0 auto' }, pdpNice)
				])
			]);

			/* Особые настройки профиля. Показываем НЕ ВСЁ, что храним: порт,
			   модель, тип слотов определяются сами и были бы шумом. Здесь только
			   то, что задано осознанно и меняет поведение модема. */
			var marks = marksOf(p);
			if (marks.length) {
				var mrow = E('div', { 'style': 'font-size:80%; margin-top:.3em' }, []);
				marks.forEach(function(m, i) {
					if (i) { mrow.appendChild(document.createTextNode(' · ')); }
					mrow.appendChild(E('span', { 'style': 'color:' + m.color }, m.txt));
				});
				card.appendChild(mrow);
			} else if (anyMarks) {
				/* Пустышка той же высоты - чтобы низ карточек в ряду совпадал. */
				card.appendChild(E('div', {
					'style': 'font-size:80%; margin-top:.3em; visibility:hidden'
				}, '\u00a0'));
			}

			if (p.iface_shared) {
				card.appendChild(E('div', {
					'style': 'font-size:80%; color:#e58a00; margin-top:.3em'
				}, _('shares interface %s with another profile').format(p.iface)));
			}

			/* Сохранённые диапазоны (настройка «Запоминать диапазоны после
			   перезагрузки»): очень мелкая строка между блоком протокола и подвалом
			   с IMEI, отделённая отступами. Может быть длинной - показываем ТОЛЬКО
			   если что-то реально сохранено. LTE как B<n>, 5G как n<n>, по доменам. */
			var savedBands = (function() {
				var parts = [];
				var add = function(list, pfx, label) {
					if (!list) return;
					var bs = String(list).trim().split(/\s+/).filter(function(b) {
						return /^[0-9]+$/.test(b);
					});
					if (bs.length) {
						parts.push({ label: label, bands: bs.map(function(b) { return pfx + b; }).join(' ') });
					}
				};
				add(p.save_band, 'B', '4G');
				add(p.save_band5gnsa, 'n', '5G NSA');
				add(p.save_band5gsa, 'n', '5G SA');
				return parts;
			})();
			if (savedBands.length) {
				/* Заголовок отдельной строкой, затем каждый домен - своей строкой,
				   метка поколения (4G/5G…) жирным. */
				var sbWrap = E('div', {
					'style': 'font-size:72%; opacity:.55; margin:1em 0 .5em; line-height:1.4; word-break:break-word'
				}, [ E('div', {}, E('strong', {}, _('Saved bands') + ':')) ]);
				savedBands.forEach(function(part) {
					sbWrap.appendChild(E('div', {}, [ E('strong', {}, part.label), ' ' + part.bands ]));
				});
				card.appendChild(sbWrap);
			}

			/* Низ карточки: слева опознание железа, справа удаление. Разносим
			   flex-строкой с выравниванием по нижнему краю - тогда кнопка стоит
			   вровень с последней строкой идентификатора независимо от того,
			   известен IMEI или нет. */
			card.appendChild(E('div', { 'class': 'mprof-foot' }, [
				/* Без заголовка: "IMEI 3506…" и USB-путь и так читаются как
				   опознание железа, а лишняя строка только съедала место. */
				/* ЗДЕСЬ БЫЛ БАГ: вложенный массив в списке детей E() не
				   разворачивается, а приводится к строке - в карточке значилось
				   "1-1.3[object HTMLBRElement],http://...". Собираем плоско. */
				/* Адрес веб-админки HiLink переехал НАВЕРХ, под статус (см. head) -
				   в подвале осталось только опознание железа: IMEI и USB-путь. */
				E('div', { 'style': 'font-size:80%; opacity:.6; line-height:1.5' }, [
					p.imei ? ('IMEI ' + p.imei) : _('IMEI unknown'), E('br'),
					p.path
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'style': 'margin-left:0; flex:0 0 auto',
					'click': ui.createHandlerFn(this, function() {
						return self.confirmDelete(p);
					})
				}, _('Delete'))
			]));
			box.appendChild(card);
		});
	},

	/* Удаление спрашивает ЯВНО и перечисляет, что именно исчезнет: вместе с
	   профилем уходит его сетевой интерфейс. Осиротевший интерфейс - не
	   безобидный мусор (такой от Telit дрался с Compal за /dev/cdc-wdm0), но и
	   молча резать сеть нельзя. */
	confirmDelete: function(p) {
		var self = this;
		var lines = [ E('p', {}, _('Delete the profile of %s?').format(p.model || p.path)) ];
		if (p.iface && !p.iface_shared) {
			lines.push(E('p', {}, _('Its network interface "%s" will be removed too.').format(p.iface)));
		} else if (p.iface_shared) {
			lines.push(E('p', {}, _('The interface "%s" stays: another profile uses it.').format(p.iface)));
		}
		if (p.present) {
			lines.push(E('p', { 'style': 'color:#e58a00' },
				_('This modem is connected right now. It will be set up again from scratch.')));
		}
		ui.showModal(_('Delete profile'), lines.concat([
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						return fs.exec('/usr/share/5gmodem/modemswitch.sh',
								[ 'delprofile', p.sec ]).then(function() {
							ui.hideModal();
							window.location.reload();
						});
					})
				}, _('Delete'))
			])
		]));
	},

	renderLeds: function(ledsAvail) {
		if (!ledsAvail) { return ''; }

		var cur = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds');
		var metric = uci.get('5gmodem', '@5gmodem[0]', 'signal_leds_metric') || 'rsrp';
		var metrics = [
			[ 'rsrp',   _('RSRP (signal level, default)') ],
			[ 'rsrq',   _('RSRQ (signal quality)') ],
			[ 'sinr',   _('SINR (signal to noise)') ],
			[ 'signal', _('Percent (modem scale)') ]
		];

		var sel = E('select', { 'class': 'cbi-input-select', 'id': 'leds-metric' },
			metrics.map(function(m) {
				return E('option', { 'value': m[0], 'selected': (m[0] === metric) ? '' : null }, m[1]);
			}));
		sel.addEventListener('change', function(ev) {
			fs.exec('/usr/share/5gmodem/signal-leds.sh', [ 'metric', ev.currentTarget.value ]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('Signal level indicator')),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('Show on the case LEDs')),
				E('div', { 'class': 'cbi-value-field' }, [
					E('input', {
						'type': 'checkbox',
						'checked': (cur == '0') ? null : '',
						'change': function(ev) {
							fs.exec('/usr/share/5gmodem/signal-leds.sh',
								[ ev.currentTarget.checked ? 'enable' : 'disable' ]);
						}
					}),
					E('div', { 'class': 'cbi-value-description' },
						_('Reads the same snapshot as the pages - the modem is not polled separately. Applies immediately, no Save needed.'))
				])
			]),
			E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, _('LED metric')),
				E('div', { 'class': 'cbi-value-field' }, [
					sel,
					E('div', { 'class': 'cbi-value-description' },
						_('Thresholds match the colours used on the Network page, so three LEDs and a green value mean the same thing.'))
				])
			])
		]);
	},

	/* Заполнить «Информацию о модеме» из СНИМКА метрик.
	   cached, а не полный опрос: снимок поддерживают страница «Сеть» и 5gtop, и
	   если он свежий, обращения к модему не будет вовсе. Зовём после отрисовки,
	   поэтому страница открывается мгновенно. */
	fillModemInfo: function() {
		return L.resolveDefault(fs.exec('/usr/share/5gmodem/5gmodem.sh', [ 'cached', '20' ]), {})
			.then(function(r) {
				var j = {};
				try { j = JSON.parse((r && r.stdout) || '{}'); } catch (e) { return; }
				/* Модема на шине нет вовсе: метрики отдают error "Device not
				   found" (при хотя бы одном модеме скрипт сам его находит и
				   возвращает данные, поэтому пустой active_modem сюда НЕ ведёт).
				   Вместо таблицы прочерков показываем осмысленную надпись. Ошибку
				   "busy" не трогаем - она преходящая (порт занят другим опросом),
				   и мигать «модема нет» на ней нельзя. */
				var tbl = document.getElementById('dbg-info-table');
				var msg = document.getElementById('dbg-no-modem');
				if (j.error && j.error !== 'busy' && !j.modem) {
					if (tbl) { tbl.style.display = 'none'; }
					if (msg) { msg.style.display = ''; }
					return;
				}
				if (tbl) { tbl.style.display = ''; }
				if (msg) { msg.style.display = 'none'; }
				var put = function(id, v) {
					var el = document.getElementById(id);
					if (el && v != null && String(v) !== '') { el.textContent = String(v); }
				};
				/* Класс дописываем ТОЛЬКО здесь и в заголовке блока «Модем» на
				   странице Сеть: в имени модели он расходился бы по вкладкам и
				   карточкам, где только мешает. */
				/* (HiLink) - модем ведётся веб-API. (Debug) - он переведён в
				   режим с AT-портами и ведётся обычным путём: у него другая
				   композиция USB и полный набор возможностей. */
				put('dbg-modem', j.modem + modeSuffix(j));
				put('dbg-firmware', j.firmware);
				put('dbg-cport', j.cport);
				put('dbg-protocol', j.protocol);

				var t = j.mtemp;
				if (t != null && String(t).length > 1 && String(t).indexOf(' ') < 0 && String(t) != '-') {
					put('dbg-mtemp', String(t).replace('&deg;', '°'));
					var row = document.getElementById('dbg-temp-row');
					if (row) { row.style.display = ''; }
				}
			});
	},

	render: function(res) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		var json = {};
		try { json = JSON.parse(res[0] || '{}'); } catch (e) {}
		if (!json || typeof json != 'object') json = {};
		var devs = res[1] || [];
		/* Есть ли на корпусе все три светодиода уровня (Cudy LT300 и совместимые).
		   Индекс 7 - последний элемент списка в load(). При одном индикаторе
		   настройка «уровень тремя лампочками» бессмысленна, поэтому нужны все. */
		var ledsAvail = (function() {
			var names = (res[7] || []).map(function(e) { return e.name; });
			return [ 'white:signal1', 'white:signal2', 'white:signal3' ]
				.every(function(n) { return names.indexOf(n) >= 0; });
		})();

		/* карта порт -> {vidpid, product} для подписи выпадашек портов */
		var portInfo = {};
		try { portInfo = JSON.parse(res[6] || '{}') || {}; } catch (e) {}
		function portLabel(name) {
			var full = '/dev/' + name;
			var i = portInfo[full];
			if (i && i.product) { return full + ' — ' + i.product + (i.vidpid ? ' (' + i.vidpid + ')' : ''); }
			if (i && i.vidpid && i.vidpid != ':') { return full + ' — ' + i.vidpid; }
			return full;
		}

		/* Список установленных на роутере обработчиков протоколов (имена файлов
		   protocol/<name>.js). По нему динамически строим выбор типа интерфейса,
		   чтобы показывать только реально доступные протоколы (у кого-то стоит
		   luci-proto-xmm/atc для Fibocom, у кого-то нет). */
		var protoAvail = {};
		(res[5] || []).forEach(function(f) {
			var m = (f.name || '').match(/^([a-z0-9]+)\.js$/);
			if (m) { protoAvail[m[1]] = true; }
		});

		/* ---------------- Настройки модема (бывшая вкладка Modem Settings) --- */
		var m, s, o;
		m = new form.Map('5gmodem', '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		o = s.option(form.Flag, 'auto_port', _('Auto-detect port and interface'),
			_('Automatically find the modem AT port and its network interface (via ModemManager when available). Turn this off to select them manually below.'));
		o.default = '1';
		o.rmempty = false;

		/* Раньше здесь был widgets.NetworkSelect. Он через
		   network.getNetworks() тянет обработчики протоколов всех
		   интерфейсов (L.require('protocol.<name>')). Если в netifd есть
		   proto 3g/wwan, а их luci-обработчик не установлен, require даёт
		   404, промис отклоняется и ВСЯ страница настроек модема перестаёт
		   открываться. Заменили на простой список имён интерфейсов из uci -
		   он самодостаточен и ничего не подгружает. */
		o = s.option(form.ListValue, 'network', _('Interface'),
			_('Network interface for Internet access.'));
		o.depends('auto_port', '0');
		o.rmempty = true;
		/* НЕ УДАЛЯТЬ ПРИ СОХРАНЕНИИ - та же ловушка, что у device и at_port.
		   Поле скрыто, пока включено автоопределение, а LuCI выбрасывает из
		   конфига опции с невыполненными зависимостями. Здесь цена выше: в
		   network лежит ИМЯ ИНТЕРФЕЙСА, которым управляет приложение, и без него
		   теряется связь модема с его подключением (проверено на живом роутере -
		   после сохранения страницы ключ исчезал вместе с device). */
		o.remove = function() { return Promise.resolve(); };
		(uci.sections('network', 'interface') || []).forEach(function(iface) {
			var nm = iface['.name'];
			if (nm && nm != 'loopback') { o.value(nm, nm + (iface.proto ? ' (' + iface.proto + ')' : '')); }
		});

		o = s.option(form.Value, 'device',
			_('Port for modem communication'),
			_("Port used to read modem/connection info. <br /> \
				<br />Traditional modem: one of the available ttyUSBX ports.<br /> \
				<br />HiLink modem: enter the IP address 192.168.X.X under which the modem is available."));
		devs.sort((a, b) => a.name > b.name);
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* НЕ УДАЛЯТЬ ПРИ СОХРАНЕНИИ. Поле скрыто, пока включено
		   автоопределение, а LuCI удаляет из конфига опции, чьи зависимости не
		   выполнены. Живой случай: сохранение этой страницы с включённым
		   автоопределением стёрло device и переписало at_port на первый порт из
		   списка (ttyUSB0, он не отвечает на AT) - метрики пропали полностью.
		   Значение проставляет resolve по факту опроса, и терять его нельзя. */
		o.remove = function() { return Promise.resolve(); };

		o = s.option(form.Value, 'at_port',
			_('Port for AT / SMS / USSD'),
			_('AT command port used for SMS, USSD and AT commands. On most modems it is the same as the modem communication port.'));
		devs.forEach(dev => o.value('/dev/' + dev.name, portLabel(dev.name)));
		o.placeholder = _('Please select a port');
		o.rmempty = true;
		o.depends('auto_port', '0');
		/* То же, что у device: при автоопределении поле скрыто, и сохранение
		   формы не должно его трогать. */
		o.remove = function() { return Promise.resolve(); };
		/* Синхронизируем единый AT-порт в 4 отдельных поля sms_tool_js,
		   которые читают вьюхи приёма/отправки SMS, USSD и AT (их код не
		   меняем). uci.save() формы сбрасывает и sms_tool_js. */
		o.write = function(section_id, value) {
			uci.set('5gmodem', section_id, 'at_port', value);
			var ss = uci.sections('sms_tool_js', 'sms_tool_js');
			var sid = (ss && ss[0]) ? ss[0]['.name'] : null;
			if (sid) {
				[ 'readport', 'sendport', 'ussdport', 'atport' ].forEach(function(k) {
					uci.set('sms_tool_js', sid, k, value);
				});
			}
		};
		o.remove = function(section_id) {
			uci.unset('5gmodem', section_id, 'at_port');
		};

		/* HiLink-модем не дозванивается через netifd: он держит соединение сам
		   и раздаёт IP по DHCP на своей сетевой карте. AT-протоколы (mbim/qmi/…)
		   к нему неприменимы, поэтому выпадашку протокола и кнопку mkiface ему НЕ
		   показываем - вместо них ниже отдельная кнопка «HiLink DHCP» (mkhilink). */
		var activeIsHilink = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();

		/* Выбор протокола + кнопка создания интерфейса модема. Список типов
		   строится по установленным на роутере обработчикам протоколов, так
		   что для Fibocom с luci-proto-xmm/atc появятся XMM/ATC и т.д. */
		if (!activeIsHilink) {
		o = s.option(form.ListValue, 'iface_proto', _('Interface protocol'),
			_('Protocol for the "Create modem interface" button. "Auto" picks it from the modem driver (recommended). Only the protocols whose handler is installed on the router are shown. Any non-ModemManager protocol disables ModemManager (they cannot share the modem).'));
		o.value('auto', _('Auto (detect)'));
		/* человекочитаемые подписи известных модемных протоколов */
		var protoLabels = {
			'fibocom': 'Fibocom (AT-dial, FM350)',
			'mbim': 'MBIM (umbim)',
			'qmi': 'QMI (uqmi)',
			'ncm': 'NCM',
			'xmm': 'XMM (Fibocom / Intel)',
			'atc': 'AT (atc)',
			'wwan': 'WWAN (auto)',
			'3g': '3G / PPP',
			'modemmanager': 'ModemManager'
		};
		/* Порядок вывода; показываем только те, чей обработчик установлен.
		   'fibocom' - наш прото (шипим и luci-proto, и netifd-обработчик), им
		   поднимается FM350: у него нет cdc-wdm, поэтому mbim/qmi/ModemManager с
		   ним не работают. В protoAvail он был всегда, но отсутствовал в ЭТОМ
		   списке и в protoLabels - поэтому в выпадашку и не попадал. */
		[ 'fibocom', 'mbim', 'qmi', 'ncm', 'xmm', 'atc', 'wwan', '3g', 'modemmanager' ].forEach(function(p) {
			if (protoAvail[p]) { o.value(p, protoLabels[p]); }
		});
		/* если вдруг ни одного модемного обработчика не нашли - оставим базовые,
		   чтобы список не был пустым */
		if (!protoAvail['mbim'] && !protoAvail['modemmanager']) {
			o.value('mbim', protoLabels['mbim']);
			o.value('modemmanager', protoLabels['modemmanager']);
		}
		o.default = 'auto';
		o.rmempty = false;
		/* Выбрали ModemManager - сразу снимаем «Скрыть от ModemManager»: держать
		   обе настройки одновременно бессмысленно (инхибиция прячет модем от MM,
		   а протокол требует, чтобы MM им управлял - интерфейс останется без IP).
		   mkiface.sh выставляет mm_exclude=0 и сам, но уже ПОСЛЕ применения, и
		   галка до перезагрузки страницы показывала неправду. Обратного действия
		   НЕ делаем: возврат на kernel-прото не обязан включать инхибицию молча -
		   у пользователя может быть причина оставить модем видимым для MM. */
		o.onchange = function(ev, section_id, value) {
			if (value !== 'modemmanager') { return; }
			var f = this.map.lookupOption('_mm_exclude', section_id);
			var el = f && f[0] && f[0].getUIElement(section_id);
			if (el && el.getValue() === '1') {
				el.setValue('0');
				ui.addNotification(null, E('p',
					_('“Hide from ModemManager” has been turned off: the ModemManager protocol needs MM to manage this modem.')), 'info');
			}
		};
		} /* if (!activeIsHilink) - выпадашка протокола */

		/* Имя интерфейса модема и признак его существования - для подписи
		   кнопки (создать/пересоздать) и для встроенной вьюхи ниже. */
		var mIfName = uci.get('5gmodem', '@5gmodem[0]', 'network') || 'modem';
		var mIfExists = !!uci.get('network', mIfName);

		/* Секция АКТИВНОГО модема (m_<usb-путь> с заменой не-буквенно-цифровых на
		   '_') - в ней живут пер-модемные настройки, напр. mm_exclude. */
		var mSec = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			return p ? ('m_' + String(p).replace(/[^A-Za-z0-9]/g, '_')) : '';
		})();

		/* Чужой интерфейс, прилипший к этому модему через переиспользованную
		   device-ноду (нашёл modemswitch.sh resolve, см. orphan_iface_for).
		   Показываем предупреждение: сам конфиг мы не правим - интерфейс мог быть
		   настроен вручную, решение за пользователем. */
		var mForeignIf = mSec ? (uci.get('5gmodem', mSec, 'foreign_iface') || '') : '';
		if (mForeignIf) {
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, _('Interface “%s” was created for a different modem.').format(mForeignIf)), ' ',
				_('It is bound to this modem only because the kernel reused the device node, so its settings (APN in particular) may belong to the previous modem and SIM. Create the interface anew below - the APN is filled from the operator detected right now.')
			]), 'warning');
		}

		/* ПЕРЕСТАВИЛИ ОДИНАКОВЫЕ МОДЕМЫ МЕСТАМИ.
		   Замену обычно ловит сравнение vid:pid на USB-пути, но два одинаковых
		   модуля так не различить. Опрос сверяет IMEI (он уникален) и ставит эту
		   метку. Сам он ничего не удаляет намеренно: тихо снести чужой APN и
		   интерфейс - именно тот неочевидный сюрприз, которого быть не должно.
		   Поэтому решение за пользователем: показываем, что произошло, и чем это
		   грозит. Метку снимаем сразу, чтобы предупреждение не повторялось. */
		var mImeiChanged = mSec ? (uci.get('5gmodem', mSec, 'imei_changed') || '') : '';
		if (mImeiChanged === '1') {
			ui.addNotification(null, E('p', {}, [
				E('strong', {}, _('A different modem is now in this USB port.')), ' ',
				_('Its IMEI does not match the one seen here before - the modems were probably swapped. The settings of this slot (the interface and its APN in particular) belong to the previous modem and its SIM. Check them below and create the interface anew if needed.')
			]), 'warning');
			fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'ackswap', mSec ]);
		}

		/* ЗДЕСЬ БЫЛА СВОЯ ТАБЛИЦА APN (функция apnForOperator) - вторая копия
		   /usr/share/5gmodem/apn.list, знавшая только имена операторов. Она и
		   разошлась с оригиналом: для MVNO имя приходит от ХОСТ-СЕТИ (Т-Мобайл
		   работает на Tele2), поэтому поле показывало APN Tele2, а при неудачном
		   опросе - значение из интерфейса, и значение прыгало между заходами на
		   страницу. Теперь APN подбирает сервер (modemswitch.sh apnfor) - тем же
		   кодом, что и автонастройка, с приоритетом кода из SIM. */

		/* Кто распоряжается APN интерфейса. В автоматическом режиме найденный по
		   оператору APN подставляется сам - при первой настройке И при смене
		   симки: раньше подбор срабатывал только на новом интерфейсе, и в
		   унаследованном оставался APN прежнего оператора. В ручном мы не трогаем
		   ничего: значение пользователя хранится в самом интерфейсе, а найденный
		   APN остаётся подсказкой в поле ниже. */
		o = s.option(form.ListValue, '_apn_mode', _('APN selection'));
		o.value('auto', _('Automatic (by operator)'));
		o.value('manual', _('Manual'));
		o.default = 'auto';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			if (uci.get('5gmodem', sec) == null) { uci.add('5gmodem', 'modem', sec); }
			uci.set('5gmodem', sec, 'apn_mode', value === 'manual' ? 'manual' : 'auto');
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return 'auto'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return (uci.get('5gmodem', sec, 'apn_mode') === 'manual') ? 'manual' : 'auto';
		};
		o.remove = function() {};

		/* Поле APN над кнопкой создания. Если интерфейс уже есть - берём его
		   текущий APN; иначе автоподстановка по оператору (можно исправить,
		   пусто = провайдерский по умолчанию). Чистое UI-поле, в uci не пишется. */
		o = s.option(form.Value, '_apn', _('APN'),
			_('APN for the modem interface. Auto-filled from the detected operator; you can change it. Leave empty for the provider default.'));
		o.placeholder = 'internet';
		o.rmempty = true;
		o.write = function() {};
		o.remove = function() {};
		o.load = function(section_id) {
			/* СТРАНИЦА НЕ ЖДЁТ ОПРОС МОДЕМА. Раньше здесь форсировался свежий
			   AT-опрос оператора ('fresh'), и форма НЕ РИСОВАЛАСЬ, пока он не
			   завершится - а с очередью к порту это секунды. Теперь мгновенно
			   отдаём текущий APN интерфейса, а подсказку по оператору
			   дозаполняем В ФОНЕ (см. ниже) и подставляем в поле, когда придёт.
			   Ровно то, о чём просил пользователь: открыть сразу, заполнить
			   потом. */
			var self = this;
			window.setTimeout(function() {
				L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/netpri.sh',
						[ 'op', mIfName, 'fresh' ]), '')
					.then(function(op) {
						op = (op || '').trim();
						if (!op) { return ''; }
						return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh',
								[ 'apnfor' ]), '').then(function(a) { return (a || '').trim(); });
					})
					.then(function(want) {
						if (!want) { return; }
						var el = self.getUIElement(section_id);
						/* Не перетираем то, что пользователь УЖЕ начал править. */
						if (!el || el.isChanged && el.isChanged()) { return; }
						var cur = (el.getValue() || '').trim();
						if (cur === want) { return; }
						el.setValue(want);
					});
			}, 0);
			/* Мгновенное значение - текущий APN интерфейса. */
			return uci.get('network', mIfName, 'apn') || '';
		};

		/* Тип PDP для создаваемого интерфейса. Чистое UI-поле (в uci не пишется):
		   применяет его mkiface.sh 4-м аргументом. По умолчанию IPv4 - dual-stack
		   ломает дозвон на части модемов (Quectel EC21 проверен живьём: поднялся
		   только после смены на IPv4), а IPv6 у сотовых операторов РФ чаще нет,
		   чем есть. Существующий интерфейс сохраняет свой тип, пока его не
		   пересоздадут этой кнопкой. */
		/* Прятать ЭТОТ модем от ModemManager (mm-inhibit.sh держит инхибицию).
		   Пишем в секцию модема, а не в общую: у каждого модема свой режим.
		   Значение читается/пишется вручную - form.Map тут привязан к @5gmodem[0]. */
		/* Галка ТОЛЬКО для модемов, которые это умеют (HiLink со сменой режима).
		   Раньше показывали её всем подряд, и у обычного QMI-модема она стояла
		   включённой, ничего не делая - пользователь справедливо принимал это за
		   баг. Обычному модему AT-порты и так доступны, режим ему не нужен. */
		var atDebugHl = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();
		if (atDebugHl) {
		o = s.option(form.Flag, '_at_debug', _('AT ports (debug mode)'),
			_('Such a modem normally exposes only its web interface: no TAC, no band, no EARFCN, no USSD. In this mode it also shows serial ports and is driven like any other modem, keeping its network card and internet. The mode is reset when the modem reboots, so it is applied again every time the modem appears.'));
		o.default = '1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			/* Секции может НЕ БЫТЬ - её заводит resolve, а он мог ещё не
			   отработать. uci.set по несуществующей секции молча ничего не
			   делает, и галка возвращалась в исходное состояние при каждом
			   сохранении: снять её было невозможно. Заводим секцию сами. */
			if (uci.get('5gmodem', sec) == null) {
				uci.add('5gmodem', 'modem', sec);
			}
			uci.set('5gmodem', sec, 'at_debug', value === '1' ? '1' : '0');
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return '1'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var v = uci.get('5gmodem', sec, 'at_debug');
			return (v === '0') ? '0' : '1';
		};
		o.remove = function() {};
		}

		/* ВКЛАДКА eSIM: автоопределение + ручное переопределение.
		   Определяем наличие eUICC пробой CCHO, но проба не непогрешима, а
		   ошибка в сторону «нет» тупиковая - вкладка исчезает, и вернуть её
		   пользователю нечем. Поэтому показываем, ЧТО ИМЕННО определилось, и
		   даём переопределить. Три состояния, а не галка: галка не отличает
		   «мы так определили» от «пользователь так велел». */
		o = s.option(form.ListValue, '_esim_show', _('eSIM tab'),
			_('Detected automatically by probing the modem for an eUICC. If the probe is wrong, force the tab on or off here.'));
		o.value('auto', _('Automatically'));
		o.value('1', _('Always show'));
		o.value('0', _('Always hide'));
		o.default = 'auto';
		o.rmempty = false;
		o.write = function(section_id, value) {
			/* Пишем ЧЕРЕЗ БЭКЕНД (esim.sh setshow), а не в кэш формы: раньше
			   uci.add именованной секции m_<путь> не приживалась на модеме, чьей
			   секции ещё не было, и галка «не сохранялась, пока не пересоздашь
			   интерфейс». Бэкенд секцию гарантированно заводит и коммитит; он же
			   сбрасывает кэш статуса, поэтому возврат в «авто» переспрашивает. */
			var v = (value === '1' || value === '0') ? value : 'auto';
			return fs.exec('/usr/share/5gmodem/esim.sh', [ 'setshow', v ])
				.then(function() { return fs.exec('/usr/share/5gmodem/esim.sh', [ 'recheck' ]); })
				.catch(function() {});
		};
		o.load = function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return 'auto'; }
			var sec = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var v = uci.get('5gmodem', sec, 'esim_show');
			return (v === '1' || v === '0') ? v : 'auto';
		};
		o.remove = function() {};

		/* ДАННЫЕ В РОУМИНГЕ.
		   Пишем в САМ ИНТЕРФЕЙС (network.<iface>.allow_roaming) - это
		   стандартная опция netifd, её читают mbim и modemmanager, и её же
		   теперь понимает наш fibocom. Своего ключа не заводим: он бы
		   расходился с тем, что реально смотрит протокол при дозвоне.

		   Показываем ТОЛЬКО для протоколов, где механизм есть. У qmi его нет
		   вовсе, и тумблер там был бы обманом - выглядел бы работающим и не
		   делал ничего. У FM350 переключателя нет и в самом модеме: в
		   руководстве по AT-командам такой команды не существует, поэтому наш
		   протокол просто не поднимает соединение в роуминге - как mbim. */
		var roamProto = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return ''; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			return ifn ? (uci.get('network', ifn, 'proto') || '') : '';
		})();
		/* HiLink-модем управляется своим веб-API, а не netifd: у него роуминг
		   переключается полем RoamAutoConnectEnable в /api/dialup/connection -
		   тот же тумблер, что в веб-админке модема. Интерфейс у него обычный
		   dhcp, поэтому по протоколу его не опознать - смотрим на kind. */
		var roamHilink = (function() {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return false; }
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			return uci.get('5gmodem', sc, 'kind') === 'hilink';
		})();
		if (roamHilink || roamProto === 'mbim' || roamProto === 'modemmanager' || roamProto === 'fibocom') {
		o = s.option(form.Flag, '_roaming', _('Allow data roaming'),
			_('When off, the modem registers on the network but the data connection is not established while roaming - so no traffic is billed at roaming rates. SMS and calls are not affected.'));
		o.default = '0';
		o.rmempty = false;
		o.write = function(section_id, value) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return; }
			var v = (value === '1') ? '1' : '0';
			/* HiLink: настройка живёт В МОДЕМЕ, а не в конфиге роутера -
			   пишем через его API. Интерфейс не трогаем: дозвоном правит сама
			   прошивка модема, и перезапуск dhcp-клиента ничего не решает. */
			if (roamHilink) {
				return fs.exec('/usr/share/5gmodem/hilink.sh',
					[ 'setroaming', String(p), v ]).catch(function() {});
			}
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			if (!ifn) { return; }
			uci.set('network', ifn, 'allow_roaming', v);
			/* Интерфейс перезапускаем: решение принимается ПРИ ДОЗВОНЕ, и без
			   перезапуска изменение вступило бы в силу неизвестно когда - а
			   при выключении роуминга ещё и продолжал бы капать трафик. */
			return fs.exec('/sbin/ifup', [ ifn ]).catch(function() {});
		};
		o.load = function(section_id) {
			var p = uci.get('5gmodem', '@5gmodem[0]', 'active_modem');
			if (!p) { return '0'; }
			if (roamHilink) {
				/* Спрашиваем сам модем - но В ФОНЕ, HTTP-запрос не должен
				   держать отрисовку формы. Пока не ответил, показываем 0. */
				var self = this;
				window.setTimeout(function() {
					L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/hilink.sh',
							[ 'getroaming', String(p) ]), '0')
						.then(function(out) {
							var v = String(out).trim() === '1' ? '1' : '0';
							var el = self.getUIElement(section_id);
							if (el && !(el.isChanged && el.isChanged())) { el.setValue(v); }
						});
				}, 0);
				return '0';
			}
			var sc = 'm_' + String(p).replace(/[^A-Za-z0-9]/g, '_');
			var ifn = uci.get('5gmodem', sc, 'network')
			       || uci.get('5gmodem', '@5gmodem[0]', 'network');
			return (ifn && uci.get('network', ifn, 'allow_roaming') === '1') ? '1' : '0';
		};
		o.remove = function() {};
		}

		o = s.option(form.Flag, '_mm_exclude', _('Hide from ModemManager'),
			_('ModemManager and a kernel protocol (QMI/MBIM) cannot share one modem: MM grabs the control channel and the interface gets no IP. Enabled by default for such protocols. Turn it off to hand the modem to ModemManager (its band/mode control is richer on some modems) - then use the ModemManager protocol for it.'));
		o.default = '1';
		o.rmempty = false;
		o.write = function(section_id, value) {
			if (!mSec) { return Promise.resolve(); }
			return fs.exec('/usr/share/5gmodem/mm-inhibit.sh',
				[ 'set-exclude', mSec, String(value) === '1' ? '1' : '0' ]);
		};
		o.remove = function() { return Promise.resolve(); };
		o.load = function(section_id) {
			if (!mSec) { return '1'; }
			var v = uci.get('5gmodem', mSec, 'mm_exclude');
			if (v === '0' || v === '1') { return v; }
			// умолчание совпадает с логикой mm-inhibit.sh: прячем kernel-прото
			var p = String(uci.get('network', mIfName, 'proto') || '');
			return (p && p !== 'modemmanager') ? '1' : '0';
		};

		/* Тип PDP - аргумент дозвона (mkiface). У HiLink дозвона нет, тип IP
		   согласует сам модем, поэтому поле ему не показываем. */
		if (!activeIsHilink) {
		o = s.option(form.ListValue, '_pdptype', _('IP type'),
			_('IP type for the modem interface. IPv4 is the default: on most networks/modems a dual-stack (IPv4/IPv6) context registers but never gets an address, while IPv4 gets one immediately. Switch to "IPv4 and IPv6" only if you need IPv6 and the modem supports it.'));
		o.value('ipv4', _('IPv4 only (recommended)'));
		o.value('ipv4v6', _('IPv4 and IPv6'));
		o.write = function() {};
		o.remove = function() {};
		o.load = function(section_id) {
			// показываем то, что стоит у существующего интерфейса (имя опции
			// зависит от прото: modemmanager - iptype, остальные - pdptype/pdp)
			var v = uci.get('network', mIfName, 'pdptype')
				|| uci.get('network', mIfName, 'iptype')
				|| uci.get('network', mIfName, 'pdp') || '';
			// dual-stack показываем ТОЛЬКО если он явно стоит; иначе (в т.ч. не
			// задано) - ipv4, новый дефолт.
			return (String(v).toLowerCase() === 'ipv4v6') ? 'ipv4v6' : 'ipv4';
		};
		} /* if (!activeIsHilink) - тип PDP */

		if (activeIsHilink) {
		/* HiLink: DHCP-интерфейс на сетевой карте модема. Протокол не выбираем -
		   дозвона нет, модем держит соединение сам. Бэкенд mkhilink находит карту
		   (hilink_net) и заводит proto=dhcp (setup_hilink). */
		o = s.option(form.Button, '_mkhilink');
		o.title = _('Modem interface');
		o.description = _('This modem holds the connection itself and hands out an address over DHCP on its own network card. The button creates (or recreates) that DHCP interface - there is no dial-up protocol to choose.');
		o.inputtitle = mIfExists ? _('Recreate interface (HiLink DHCP)') : _('Create interface (HiLink DHCP)');
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'mkhilink' ]).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.success) {
					ui.addNotification(null, E('p', _('Interface "%s" created (DHCP on %s), bringing it up…').format(out.iface, out.netdev)), 'info');
					if (profilesView) { profilesView.loadProfiles(); }
				} else {
					ui.addNotification(null, E('p', _('No HiLink network card found to create an interface for.')), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to create the modem interface') + ': ' + (err.message || err)), 'error');
			});
		};
		} else {
		o = s.option(form.Button, '_mkiface');
		o.title = _('Modem interface');
		o.description = _('Create (or switch) the modem network interface using the protocol chosen above. Switching to MBIM disables ModemManager; switching to ModemManager enables it (they cannot share the modem).');
		o.inputtitle = mIfExists ? _('Recreate modem interface') : _('Create modem interface');
		o.inputstyle = 'apply';
		o.onclick = function() {
			var sid = null;
			var ss = uci.sections('5gmodem', '5gmodem');
			if (ss && ss[0]) { sid = ss[0]['.name']; }
			var proto = 'auto';
			try {
				var opt = this.map.lookupOption('iface_proto', sid);
				if (opt && opt[0]) { var el = opt[0].getUIElement(sid); if (el) { proto = el.getValue() || 'auto'; } }
			} catch (e) {}
			var apn = '';
			try {
				var aopt = this.map.lookupOption('_apn', sid);
				if (aopt && aopt[0]) { var ael = aopt[0].getUIElement(sid); if (ael) { apn = (ael.getValue() || '').trim(); } }
			} catch (e) {}
			// Пустое поле = ЯВНО без APN (оператор опознан, но его нет в базе, либо
			// пользователь стёр сам). Передаём sentinel '-', иначе mkiface.sh не
			// отличит это от «аргумент не передан» и молча сохранит ПРЕЖНИЙ APN -
			// стереть его было бы невозможно.
			var apnArg = apn || '-';
			var pdp = 'ipv4';
			try {
				var popt = this.map.lookupOption('_pdptype', sid);
				if (popt && popt[0]) { var pel = popt[0].getUIElement(sid); if (pel) { pdp = pel.getValue() || 'ipv4'; } }
			} catch (e) {}
			// Выбор протокола запоминает сам mkiface.sh (uci commit на
			// роутере), поэтому здесь НЕ вызываем uci.save() - иначе LuCI
			// поднимал баннер «не сохранено» и требовал нажать «Применить».
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Creating the modem interface...')));
			return fs.exec('/usr/share/5gmodem/mkiface.sh', [ 'modem', proto, apnArg, pdp ]).then(function(res) {
				ui.hideModal();
				var out = {};
				try { out = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				if (out.result == 'created') {
					ui.addNotification(null, E('p', _('Interface "%s" created (%s), bringing it up…').format(out.iface, out.proto)), 'info');
					// The Modem Information block is rendered once and not polled, so
					// its protocol badge would keep showing the OLD protocol (e.g. mbim)
					// until a manual page reload. Update it to the new protocol now.
					var pb = document.querySelector('.tg-proto-badge');
					if (pb && out.proto) { pb.textContent = out.proto; }
					/* И карточки профилей - у них поменялись интерфейс, протокол
					   и APN. uci-кэш вьюхи при этом устарел, но карточки читают
					   состояние с роутера, поэтому показывают уже новое. */
					if (profilesView) { profilesView.loadProfiles(); }
				} else {
					ui.addNotification(null, E('p', _('No modem found to create an interface for.')), 'error');
				}
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to create the modem interface') + ': ' + (err.message || err)), 'error');
			});
		};
		} /* if activeIsHilink … else - кнопка создания интерфейса */

		/* Забыть модемы, которых больше нет на шине.
		   ЯВНОЕ действие: автоматически по отключению так делать нельзя - модем
		   штатно пропадает на минуту при AT+CFUN=1,1 (в т.ч. по нашей же команде
		   после добавления eSIM-профиля), и настройки терялись бы на ровном месте.
		   Подмену модема на том же USB-порту приложение чистит само (см.
		   swap_cleanup в modemswitch.sh) - эта кнопка для случая «модем убрали
		   насовсем». Сама привязка модема и удаляется; интерфейс в network/firewall
		   остаётся: он мог быть настроен вручную. */
		o = s.option(form.Button, '_forget');
		o.title = _('Disconnected modems');
		o.description = _('Remove settings remembered for modems that are no longer connected (AT port, interface, SIM slot types). A stale entry can hide a working modem from Internet priority if both claim the same interface name.');
		o.inputtitle = _('Forget disconnected modems');
		o.inputstyle = 'remove';
		o.onclick = function() {
			ui.showModal(null, E('p', { 'class': 'spinning' }, _('Removing…')));
			return fs.exec('/usr/share/5gmodem/modemswitch.sh', [ 'forget' ]).then(function(res) {
				ui.hideModal();
				var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
				var n = parseInt(d.forgotten, 10) || 0;
				ui.addNotification(null, E('p', n
					? _('Forgotten modems: %d').format(n)
					: _('Nothing to forget: every remembered modem is connected.')), 'info');
				if (n) { window.setTimeout(function() { window.location.reload(); }, 1200); }
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Failed to forget disconnected modems') + ': ' + (err.message || err)), 'error');
			});
		};

		/* Отчёт для разработчиков. Сбор идёт в фоне (collect.sh start) и занимает
		   от секунд до пары минут - синхронный вызов не пережил бы 30-секундный
		   таймаут rpcd. Поэтому опрашиваем collect.sh status и показываем шаг,
		   а готовый файл отдаём браузеру как обычное скачивание (Blob). */
		/* Диагностический отчёт живёт НЕ в форме настроек, а внизу в секции
		   «Диагностика» (см. diag ниже): это часть диагностики, а не настройка.
		   Кнопку и описание собираем там, здесь - только обработчик. */
		var collectDesc = _('Collects settings, modem ports, AT command output, ModemManager and eSIM state, and system logs into one text file and downloads it. Attach it to a bug report. The file contains modem and SIM identifiers (IMEI, IMSI, ICCID, EID) and the operator name; it does not contain passwords or Wi-Fi keys.');
		var runCollect = function() {
			var msg = E('p', { 'class': 'spinning' }, _('Collecting logs…'));
			ui.showModal(_('Diagnostic report'), [ msg ]);

			var poll = function(tries) {
				return fs.exec('/usr/share/5gmodem/collect.sh', [ 'status' ]).then(function(res) {
					var st = {}; try { st = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
					if (st.state === 'running') {
						// сбор не бесконечен: 180 попыток по 2 c = 6 минут потолок
						if (tries > 180) { throw new Error(_('Timed out')); }
						msg.textContent = _('Collecting logs…') + ' ' + (st.progress || '');
						return new Promise(function(resolve) {
							window.setTimeout(function() { resolve(poll(tries + 1)); }, 2000);
						});
					}
					if (st.state !== 'done') { throw new Error(_('Collecting logs failed')); }
					return fs.read_direct('/tmp/5gmodem-diag.txt', 'blob');
				});
			};

			return fs.exec('/usr/share/5gmodem/collect.sh', [ 'start' ]).then(function() {
				return poll(0);
			}).then(function(blob) {
				var d = new Date();
				var stamp = d.getFullYear()
					+ ('0' + (d.getMonth() + 1)).slice(-2)
					+ ('0' + d.getDate()).slice(-2)
					+ '-' + ('0' + d.getHours()).slice(-2)
					+ ('0' + d.getMinutes()).slice(-2);
				var url = window.URL.createObjectURL(blob);
				var a = E('a', { 'href': url, 'download': '5gmodem-diag-' + stamp + '.txt' });
				document.body.appendChild(a);
				a.click();
				document.body.removeChild(a);
				window.setTimeout(function() { window.URL.revokeObjectURL(url); }, 5000);
				ui.hideModal();
				ui.addNotification(null, E('p', _('The report has been downloaded. Attach it to your bug report.')), 'info');
			}).catch(function(err) {
				ui.hideModal();
				ui.addNotification(null, E('p', _('Collecting logs failed') + ': ' + (err.message || err)), 'error');
			});
		};

		/* --- Тест скорости - ОТДЕЛЬНОЙ секцией (стандартный разделитель-заголовок),
		   ниже «Забыть модемы»/«Собрать логи» и выше блока «Обновление». Секция
		   маппится на ту же анонимную секцию 5gmodem, что и выше, - LuCI рисует её
		   отдельной плашкой с заголовком. Кнопка теста - в блоке «Приоритет
		   интернета» на странице «Сеть»; тут только настройки эндпойнтов. */
		/* Настройки «Тест скорости» переехали на вкладку «Настройки»
		   (view modem/5gsettings). */

		/* ---------------- Информация о модеме (перенесена со страницы Сеть) -- */
		function infoVal(v) {
			return (v != null && String(v).length > 0 && String(v) != '-') ? String(v) : '-';
		}
		function inforow(label, value) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ label ]),
				E('td', { 'class': 'td left tg-info-val' }, [ value ]),
			]);
		}
		/* Значения приходят позже - ставим прочерки и метим ячейки, чтобы было
		   куда их положить. Строку температуры держим скрытой: у части модемов
		   её нет вовсе, и пустая строка в таблице только мешает. */
		var infoCell = function(id, inner) {
			return E('span', { 'id': id }, inner !== undefined ? inner : '-');
		};
		var infoRows = [
			inforow(_('Modem type'), infoCell('dbg-modem')),
			inforow(_('Revision / Firmware'), infoCell('dbg-firmware')),
			inforow(_('IP adress / Communication Port'), infoCell('dbg-cport')),
			inforow(_('Protocol'), E('span', { 'class': 'tg-proto-badge' }, infoCell('dbg-protocol'))),
		];
		var tempRow = inforow(_('Chip Temperature'), infoCell('dbg-mtemp'));
		tempRow.style.display = 'none';
		tempRow.id = 'dbg-temp-row';
		infoRows.push(tempRow);

		var modemInfo = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Modem Information') ]),
			E('table', { 'class': 'table tg-info-table', 'id': 'dbg-info-table' }, infoRows),
			/* Показывается вместо таблицы прочерков, когда модема на шине нет
			   вовсе (метрики отдают error "Device not found"). Скрыт по
			   умолчанию: при живом модеме таблица заполняется, надпись молчит. */
			E('p', { 'id': 'dbg-no-modem', 'class': 'tg-no-modem', 'style': 'display:none' },
				_('No modem detected. Insert a modem, then reload the page.'))
		]);

		/* ---------------- Диагностика (как было) ---------------------------- */
		var termBlock = function(cmd) {
			var parts = cmd.split(' ');
			var spans = [ E('span', { 'style': 'color:#34d399;user-select:none;' }, '$ ') ];
			parts.forEach(function(tok, i) {
				var color = (i == 0) ? '#7db2ff' : (tok.charAt(0) == '-' ? '#e6b84c' : '#d6e0ea');
				spans.push(E('span', { 'style': 'color:' + color }, tok + (i < parts.length - 1 ? ' ' : '')));
			});
			return E('div', { 'class': 'tg-code' }, [
				E('div', { 'class': 'tg-code-lang' }, 'bash'),
				E('div', { 'class': 'tg-code-body' }, spans)
			]);
		};

		var table = E('table', { 'class': 'table tg-diag-table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("USB debug information")
						),
						termBlock('cat /sys/kernel/debug/usb/devices'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleUSB')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left', 'style': 'overflow:initial' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check availability of ttyX ports")
						),
						termBlock('ls /dev'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleTTY')
							}, [ _('Show devices') ])
						])
					]),

					E('td', { 'class': 'td left' }, [
						E('label', { 'class': 'cbi-value-title' },
							_("Check data read by the 5gmodem scripts")
						),
						termBlock('sh -x /usr/share/5gmodem/5gmodem.sh'),
						E('span', { 'class': 'diag-action' }, [
							E('button', {
								'class': 'cbi-button cbi-button-action',
								'click': ui.createHandlerFn(this, 'handleDBG')
							}, [ _('Debug') ])
						])
					]),
				])
			]);

		document.head.append(E('style', {'type': 'text/css'},
`
.tg-proto-badge {
  display: inline-block;
  padding: 1px 9px;
  border: 1px solid rgba(127, 127, 127, 0.4);
  border-radius: 6px;
  background: rgba(127, 127, 127, 0.12);
  font-weight: 600;
  font-size: 0.9em;
  line-height: 1.6;
  text-transform: uppercase;
  letter-spacing: 0.02em;
}
.tg-code {
  background: #161c26;
  border: 1px solid rgba(255, 255, 255, 0.08);
  border-radius: 8px;
  margin: 10px 12px 12px 0;
  overflow: hidden;
  font-family: monospace;
  max-width: 420px;
}
.tg-code-lang {
  font-size: 10px;
  color: #8b95a7;
  padding: 4px 12px;
  background: rgba(255, 255, 255, 0.04);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  letter-spacing: 0.06em;
}
.tg-code-body {
  /* Фон и цвет ЗАДАЁМ ЯВНО: этот класс висит и на <pre> (вывод диагностики), а
     тему бутстрапа <pre> красит светлым фоном - светлые буквы на нём сливались.
     Класс перебивает элементный селектор темы. Цвета - те же, что у вывода
     AT-команд (pre.atcommand-output), чтобы блоки выглядели одинаково. */
  background: #161c26;
  color: #d6e0ea;
  padding: 9px 12px;
  font-size: 12px;
  line-height: 1.5;
  white-space: pre;
  overflow-x: auto;
}

/* Заголовки колонок: резервируем две строки, чтобы блоки кода и
   кнопки во всех трёх колонках были на одном уровне независимо от
   того, переносится заголовок или нет (в proton2025 русские
   заголовки длиннее и переносятся). */
.tg-diag-table .td {
  vertical-align: top;
}
.tg-diag-table .td > .cbi-value-title {
  display: block;
  min-height: 2.9em;
  line-height: 1.4;
}

/* Таблицы-раскладки без линий и фонов тем */
.tg-diag-table,
.tg-diag-table .tr,
.tg-diag-table .td,
.tg-info-table,
.tg-info-table .tr,
.tg-info-table .td {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}
.tg5g h3 {
  margin-top: 0;
}

/* Лишняя разделительная полоса под флагом «Автоопределение …»: когда
   ручные поля скрыты (depends), в proton2025 они остаются в DOM как
   display:none и не дают флагу стать :last-child, из-за чего видна его
   нижняя граница. Убираем границу у последнего ВИДИМОГО ряда формы. */
.tg-modem-form .cbi-value:not([style*="none"]):not(:has(~ .cbi-value:not([style*="none"]))) {
  border-bottom: none;
}

/* Вторая колонка «Информация о модеме» - моноширинным, как терминал */
.tg-info-table .tg-info-val {
  font-family: var(--font-monospace, monospace);
}

/* Ячейки таблицы «Информация о модеме»: СВОЙ компактный паддинг. Темы (особенно
   proton2025) кладут на .td большой отступ, и он складывался с расстоянием между
   строками в «двойные» отступы. Прибиваем к плотному: вертикаль мелкая, левый
   край без отступа, между колонками - небольшой зазор. */
.tg-info-table .td {
  padding: 2px 12px 2px 0 !important;
  vertical-align: top;
}

/* Надпись «модема нет» вместо таблицы прочерков. Цвет наследуем, глушим
   прозрачностью - работает в обеих темах без жёстких значений. */
.tg-no-modem {
  opacity: 0.65;
  margin: 6px 12px 2px 0;
  font-style: italic;
}

/* На узких/мобильных экранах три колонки диагностики складываются в
   столбик, иначе третья («Проверка данных скриптами 5gmodem») уезжает
   за край и не переносится. */
@media (max-width: 640px) {
  .tg-diag-table,
  .tg-diag-table .tr,
  .tg-diag-table .td {
    display: block;
    width: 100% !important;
  }
  .tg-diag-table .td {
    padding-left: 0;
    padding-right: 0;
  }
  .tg-diag-table .td > .cbi-value-title {
    min-height: 0;
  }
}
`));

		/* Блок проверки/установки обновления (над Диагностикой) */
		/* Блок «Обновление» переехал на вкладку «Настройки» (view modem/5gsettings). */

		var diag = E('div', { 'class': 'cbi-section tg5g' }, [
			E('h3', {}, [ _('Diagnostics') ]),
			/* Диагностический отчёт - здесь, а не в форме настроек. */
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('label', { 'class': 'cbi-value-title', 'style': 'display:block; margin-bottom:.3em' },
					_('Diagnostic report')),
				E('div', { 'class': 'cbi-value-description', 'style': 'margin:0 0 .5em' }, collectDesc),
				E('button', {
					'class': 'cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, runCollect)
				}, [ _('Collect logs') ])
			]),
			table,
			E('div', {}, [
				E('p'),
				E('div', { 'id': 'pre', 'class': 'tg-code', 'style': 'display:none; max-width:none; margin:0;' }, [
					E('div', { 'class': 'tg-code-lang' }, 'bash'),
					E('pre', { 'id': 'preout', 'class': 'tg-code-body', 'style': 'max-height:460px; overflow:auto; margin:0;' }, [])
				]),
				E('p'),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'cbi-button cbi-button-remove',
						'id': 'clear',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleClear')
					}, [ _('Clear') ]),
					'\xa0\xa0\xa0',
					E('button', {
						'class': 'cbi-button cbi-button-apply important',
						'id': 'download',
						'style': 'display:none',
						'click': ui.createHandlerFn(this, 'handleDownload')
					}, [ _('Download') ]),
				]),
			])
		]);

		/* Форма настроек рендерится асинхронно; собираем страницу целиком:
		   Информация о модеме -> Настройки -> Диагностика. Save/Apply внизу
		   применяется к form.Map (единственный .cbi-map на странице). */
		var ledsBlock = this.renderLeds(ledsAvail);
		var self = this;
		return Promise.resolve(m.render()).then(function(formNode) {
			return E('div', {}, [
				modemInfo,
				/* Профили ПОД информацией о модеме: сверху - что происходит с
				   текущим модемом, ниже - список всех, что программа видела. */
				self.renderProfiles(),
				E('div', { 'class': 'tg-modem-form' }, [ formNode ]),
				/* Блок светодиодов ПОСЛЕ формы, но вне её: он применяется сразу
				   и не должен подписываться под Save/Apply формы. */
				ledsBlock,
				diag
			]);
		}).then(function(node) {
			/* Значения подставляем ПОСЛЕ того, как узел готов: до вставки в
			   документ getElementById их не найдёт. Промис не возвращаем -
			   страница не должна ждать эти данные, ради чего всё и делалось. */
			window.setTimeout(function() { self.fillModemInfo(); }, 0);
			return node;
		});
	}
});
