'use strict';
'require baseclass';
'require form';
'require fs';
'require view';
'require view.modem.modemtabs as modemtabs';
'require view.modem.netpri as netpri';
'require ui';
'require uci';
'require poll';
'require dom';
'require tools.widgets as widgets';

/*
	Copyright 2021-2025 Rafał Wabik - IceG - From eko.one.pl forum
	
	Licensed to the GNU General Public License v3.0.
	
	Thanks to https://github.com/koshev-msk for the initial progress bar calculation for rssi/rsrp/rsrq/sinnr.
*/


document.head.append(E('style', {'type': 'text/css'},
`
/* Плавный рост/убывание полосок метрик (CSQ/RSRP/RSRQ/SINR/RSSI): их ширину
   мы пересчитываем на каждый опрос, и без перехода она скакала рывком. Анимируем
   только ширину - цвет/подпись меняем мгновенно, чтобы оценка не «догоняла».
   0.4 с ease-out достаточно, чтобы движение читалось, но не тормозило. */
.cbi-progressbar > div {
  transition: width 0.4s ease-out;
}
.tginfo-modesw .cbi-button {
  margin: 2px 6px 2px 0;
  padding: 2px 10px;
}

/* Кнопки диапазонов - строго одинаковой ширины (фиксированная, а не
   min-width, иначе 3-символьные шире 2-символьных), стандартной высоты */
#bands-3g .cbi-button,
#bands-lte .cbi-button,
#bands-nr .cbi-button {
  width: 3.4em;
  padding-left: 0;
  padding-right: 0;
  text-align: center;
  font-variant-numeric: tabular-nums;
  box-sizing: border-box;
}

/* ЗАЩИТА ОТ ЗАМЕРА ТАБЛИЦ ТЕМОЙ proton2025.
   Тема (custom-pages.js, measureNaturalTableWidth) на каждое изменение DOM
   замеряет «натуральную» ширину таблиц: временно ставит ячейкам
   white-space:nowrap, дёргает void table.offsetWidth (принудительный reflow),
   меряет и возвращает стили назад.
   Наши ряды кнопок в этот миг схлопываются с нескольких строк в одну, высота
   документа проваливается на ~200px, и БРАУЗЕР ОБРЕЗАЕТ scrollTop до нового
   максимума. Стили тема вернёт, высоту тоже - а прокрутка останется обрезанной.
   Итог: страница уезжала вверх на каждый тик опроса (только на этой теме и
   только при раскрытом блоке частот - именно там кнопки переносятся).
   !important бьёт инлайновый стиль темы, поэтому её nowrap на наши контейнеры
   не действует: высота при замере не меняется - обрезать нечего.
   Чинить тему мы не можем, а страница должна работать в любой. */
#bands-3g, #bands-lte, #bands-nr, #modesw-btns,
#antports-table td {
  white-space: normal !important;
}

/* Комбинации 3G - ИСКЛЮЧЕНИЕ из фиксированной ширины выше: та рассчитана на
   короткие номера диапазонов ("B1"), а у комбинаций подписи длинные
   ("2100 + 1900 + 850") - в 3.4em их бы расплющило. */
#bands-3g .cbi-button.combo3g {
  width: auto;
  padding-left: 10px;
  padding-right: 10px;
  font-variant-numeric: normal;
}

/* Подсказки (data-tooltip): длинный текст в одну строку растягивал страницу и
   давал горизонтальный скролл. Разрешаем перенос и ограничиваем ширину.
   Селекторы оба: LuCI рисует подсказку либо элементом .cbi-tooltip, либо
   псевдоэлементом ::after - в зависимости от версии/темы. */
.cbi-tooltip,
[data-tooltip]::after {
  white-space: normal !important;
  max-width: min(90vw, 32em) !important;
  overflow-wrap: anywhere;
}

/* Анти-джиттер: фиксируем раскладку таблиц и размеры иконок, чтобы при
   обновлении данных строки не пересчитывали размер и страница не прыгала.
   Ключевое: иконка сигнала пересоздаётся каждый опрос через innerHTML -
   без явных размеров браузер делал reflow при каждой перерисовке. */
.tginfo .table {
  table-layout: fixed;
  width: 100%;
}
.tginfo .table .td:first-child {
  width: 33%;
}
.tginfo .table .td {
  overflow-wrap: anywhere;
}
#signal img {
  width: 36px;
  height: 36px;
}
#signal medium {
  display: block;
  line-height: 1.2;
}
#simicon {
  width: 36px !important;
  height: 36px !important;
  flex: 0 0 auto;
}

/* Иконка-индикатор роуминга (croaming.svg), перед статусом «В сети». */
.tginfo-roam {
  display: inline-block; width: 1.2em; height: 1.2em; margin-right: .35em;
  vertical-align: -0.2em; flex: 0 0 auto;
}

/* CA-таблица многоколоночная - НЕ наследуем раскладку 2-колоночных таблиц
   (fixed + 33% на первую колонку + overflow-wrap:anywhere), иначе ячейки
   переносятся, высота строки скачет и страница дёргается при обновлении.
   Одна строка на ячейку -> высота постоянна. */
#ca-table {
  table-layout: fixed;
  width: 100%;
}
#ca-table .td, #ca-table .th {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  overflow-wrap: normal;
  padding: 2px 8px 2px 0;
}
/* фиксированные пропорции колонок -> таблица всегда ровно 100% ширины, без
   горизонтального переполнения (и без появляющегося/пропадающего скролла,
   который менял высоту на proton2025) */
#ca-table .td:nth-child(1), #ca-table .th:nth-child(1) { width: 7%; }
#ca-table .td:nth-child(2), #ca-table .th:nth-child(2) { width: 19%; }
#ca-table .td:nth-child(3), #ca-table .th:nth-child(3) { width: 10%; }
#ca-table .td:nth-child(4), #ca-table .th:nth-child(4) { width: 8%; }
#ca-table .td:nth-child(5), #ca-table .th:nth-child(5) { width: 10%; }
#ca-table .td:nth-child(n+6), #ca-table .th:nth-child(n+6) { width: 9%; }
#ca-table .td:nth-child(10), #ca-table .th:nth-child(10) { width: 10%; }

/* Мобильная раскладка: 10 колонок не влезают на узкий экран (значения
   обрезались многоточием). Ниже 800px превращаем каждую строку-компонент
   (PCC/SCC) в компактную «карточку» с подписями (data-l через ::before).
   Всё видно и помещается; высота стабильна - карточек всегда 5, как строк в
   таблице (см. renderCaTable), поэтому (де)агрегация не меняет высоту блока.
   ВАЖНО: брейкпоинт 800px = как у proton2025. Тема на <=800px вешает на
   таблицы 'overflow-x:auto !important'; при (де)агрегации ширина CA-контента
   менялась -> горизонтальный скролл появлялся/исчезал -> высота элемента
   прыгала -> страницу дёргало. display:block (карточки) убирает широкую
   таблицу и сам скролл, поэтому прыжок пропадает. */
@media (max-width: 800px) {
  #ca-table, #ca-table .tr { display: block; width: 100%; }
  #ca-table .ca-head { display: none; }
  #ca-table .ca-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 1px 1em;
    border: 1px solid rgba(128,128,128,.25);
    border-radius: 6px;
    padding: .35em .6em;
    margin: 0 0 .45em 0;
  }
  #ca-table .ca-row .td {
    display: block;
    width: auto !important;
    white-space: normal;
    overflow: visible;
    text-overflow: clip;
    padding: 1px 0;
  }
  #ca-table .ca-row .ca-cc {
    grid-column: 1 / -1;
    font-weight: 600;
    border-bottom: 1px solid rgba(128,128,128,.2);
    margin-bottom: .15em;
  }
  #ca-table .ca-row .td[data-l]::before {
    content: attr(data-l) ": ";
    opacity: .6;
  }
}

/* Значение диапазона (pband/SCC) меняет длину при переселении соты
   (напр. "B1 (2100 MHz)" <-> "B3 (1800 MHz) @15 MHz"). В таблице с фикс.
   раскладкой длинное значение переносилось на 2 строки -> высота строки
   скакала -> страница дёргалась при опросе. Держим значение в одну строку. */
#pband {
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Секции без табличных полос и рамок - как на странице статуса LuCI */
.tginfo .table,
.tginfo .table .tr,
.tginfo .table .td {
  background: transparent !important;
  border: none !important;
  box-shadow: none !important;
}
.tginfo .table .tr:nth-child(odd) .td,
.tginfo .table .tr:nth-child(even) .td {
  background: transparent !important;
}
.tginfo h3 {
  margin-top: 0;
}

/* Компактная строка состояния: сигнал | SIM | статус | инфо | температура */
.tginfo-general {
  display: flex;
  align-items: flex-start;
  gap: 1.4em;
  flex-wrap: wrap;
  padding: 4px 0 2px;
}
.tginfo-signal {
  text-align: center;
  min-width: 44px;
  line-height: 1.15;
}
.tginfo-signal medium {
  display: block;
  font-size: 90%;
}
/* Две параллельные колонки с одинаковой межстрочкой -> строки выровнены */
.tginfo-status,
.tginfo-info {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.tginfo-status {
  min-width: 8em;
}
.tginfo-status > *,
.tginfo-info > * {
  line-height: 1.5;
}
/* короткие строки статуса не переносим, длинные - можно */
.tginfo-status > * {
  white-space: nowrap;
}
.tginfo-status .tginfo-reg,
.tginfo-status .tginfo-loc {
  font-size: 88%;
  opacity: 0.75;
}
.tginfo-status .tginfo-op {
  font-weight: 600;
}
.tginfo-status .tginfo-phone {
  font-size: 0.8em;
  opacity: 0.7;
  font-variant-numeric: tabular-nums;
}
.tginfo-info {
  font-size: 92%;
  opacity: 0.9;
  flex: 1 1 16em;
}
.tginfo-info .tginfo-tech {
  font-weight: 600;
  opacity: 1;
  overflow-wrap: anywhere;
}
/* частоты в скобках - без жирного, мельче и на 30% серее основного текста */
.tginfo-info .tginfo-freq {
  font-weight: normal;
  font-size: 0.8em;
  opacity: 0.7;
}
.tginfo-info .tginfo-ip {
  font-variant-numeric: tabular-nums;
}
/* подписи IPv4:/IPv6: - жирным */
.tginfo-info .tginfo-iplabel {
  font-weight: 600;
  margin-right: 0.35em;
}
/* IPv6 длинный (до 39 символов) - уменьшаем шрифт, чтобы строка влезала на
   мобильном в ОДИН ряд и не вылезала за край экрана. */
#modemip6 {
  font-size: 0.78em;
  letter-spacing: -0.2px;
  word-break: break-all;
}
@media (max-width: 800px) {
  #modemip6 { font-size: 0.7em; }
}
/* правая колонка шапки: SIM-слоты над температурой, прижаты вправо */
.tginfo-right {
  margin-left: auto;
  display: flex;
  flex-direction: column;
  align-items: flex-end;
  gap: 4px;
}
/* маленькие кнопки переключения SIM-слота */
.tginfo-simslot .cbi-button {
  padding: 1px 8px;
  font-size: 80%;
  line-height: 1.5;
  margin-left: 4px;
}
/* подпись типа SIM (USIM/eSIM) слева от кнопок */
.tginfo-simslot .tginfo-simslot-type {
  font-size: 80%;
  opacity: 0.7;
  margin-right: 4px;
}
/* секция eSIM */
.esim-meta {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 88%;
  opacity: 0.8;
  margin-bottom: 8px;
}
.esim-dl {
  display: flex;
  gap: 8px;
  margin-top: 10px;
  align-items: center;
}
#esim-profiles .btn {
  padding: 1px 8px;
  font-size: 85%;
  margin-left: 4px;
}
.tginfo-temp {
  display: inline-flex;
  align-items: center;
  gap: 0.25em;
  margin-left: auto;
  opacity: 0.85;
  white-space: nowrap;
}
.tginfo-temp .tginfo-thermo {
  display: inline-flex;
  align-items: center;
}
`));

function csq_bar(v, m) {
var pg = document.querySelector('#csq')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor((100 / mn) * vn);
		if (vn >= 20 && vn <= 31 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= 14 && vn <= 19) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= 10 && vn <= 13) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn <= 9 && vn >= 1) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rssi_bar(v, m) {
var pg = document.querySelector('#rssi')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
if (vn > -50) { vn = -50 };
if (vn < -110) { vn = -110 };
var pc =  Math.floor(100*(1-(-50 - vn)/(-50 - mn)));
		if (vn > -70) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= -85 && vn <= -70) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -100 && vn <= -86) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn < -100) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rsrp_bar(v, m) {
var pg = document.querySelector('#rsrp')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
if (vn > -50) { vn = -50 };
if (vn < -140) { vn = -140 };
var pc =  Math.floor(120*(1-(-50 - vn)/(-70 - mn)));
		if (vn >= -80 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Very good');
			};
		if (vn >= -90 && vn <= -79) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -100 && vn <= -89) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Weak');
			};
		if (vn < -100) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Very weak');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function sinr_bar(v, m) {
var pg = document.querySelector('#sinr')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
/* Ширину ОБЯЗАТЕЛЬНО зажимаем в 0..100. Профиль Telit подставлял в SINR сырой
   индекс модема (143 вместо 8.6 дБ) - формула давала 268%, полоса вылезала за
   контейнер, растягивала строку таблицы, а таблица перерисовывается каждый
   опрос: страница дёргалась. Причину починили в профиле, но данные приходят от
   железа, и одно кривое значение не должно ломать вёрстку. */
var pc = Math.floor(100-(100*(1-((mn - vn)/(mn - 40)))));
pc = Math.max(0, Math.min(100, pc));
		if (vn > 20 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Excellent');
			};
		if (vn >= 13 && vn <= 20)
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn > 0 && vn <= 12) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Mid cell');
			};
		if (vn <= 0) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Cell edge');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

function rsrq_bar(v, m) {
var pg = document.querySelector('#rsrq')
var vn = parseInt(v) || 0;
var mn = parseInt(m) || 100;
var pc = Math.floor(115-(100/mn)*vn);
if (vn > 0) { vn = 0; };
		if (vn >= -10 ) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #2fb885, #34d399)';
			var tip = _('Excellent');
			};
		if (vn >= -15 && vn <= -9) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #c99a3f, #e6b84c)';
			var tip = _('Good');
			};
		if (vn >= -20 && vn <= -14) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d97a3c, #fb923c)';
			var tip = _('Mid cell');
			};
		if (vn < -20) 
			{
			pg.firstElementChild.style.background = 'linear-gradient(90deg, #d95c5c, #f87171)';
			var tip = _('Cell edge');
			};
pg.firstElementChild.style.width = pc + '%';
pg.style.width = '33%';
pg.firstElementChild.style.animationDirection = "reverse";
pg.setAttribute('title', '%s'.format(v) + ' | ' + tip + ' ');
}

/* Переключатель SIM-слотов в шапке (над температурой). Кнопки появляются,
   только если у активного модема >= 2 слотов: AT+GTDUALSIM (Fibocom) или
   mmcli sim-slots (ModemManager). Тип SIM (USIM/eSIM) - подписью слева. */
var simSlotsSeen = false;   // список слотов хоть раз пришёл нормальным
var simSlotsTries = 0;
function loadSimSlots() {
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', [ 'status' ]), '').then(function(out) {
		var st = {};
		try { st = JSON.parse(out) || {}; } catch (e) { return; }
		var box = document.getElementById('simslotn');
		if (!box) { return; }
		if (!st.slots || st.slots.length < 2) {
			/* Транзитная пустота: сразу после смены слота модем ресетится и
			   переперечисляется на USB (у FM350 - десятки секунд), simslot.sh
			   отдаёт {"error":"no device"}. Раньше кнопки в этот момент ПРОПАДАЛИ
			   и не возвращались до ручного обновления страницы. Если список уже
			   был - оставляем последний хороший и ждём следующего опроса. */
			if (!simSlotsSeen) {
				box.style.display = 'none';
				/* Первое открытие после ПЕРЕЗАГРУЗКИ РОУТЕРА: кэша в /tmp ещё нет
				   (его чистит загрузка), а первая проба сталкивается за AT-порт с
				   опросом метрик и возвращает пусто. Липкий кэш тут не спасает -
				   спасать ещё нечем. Раньше кнопки в этот момент прятались до
				   ручного F5; теперь просто повторяем, пока порт не освободится. */
				if (simSlotsTries < 6) {
					simSlotsTries++;
					window.setTimeout(loadSimSlots, 3000);
				}
			}
			return;
		}
		simSlotsSeen = true;
		box.innerHTML = '';
		if (st.type) {
			box.appendChild(E('span', { 'class': 'tginfo-simslot-type', 'title': _('SIM type') }, [ st.type ]));
		}
		st.slots.forEach(function(s) {
			var on = (String(st.active) === String(s.id));
			/* present приходит там, где прошивка умеет сказать, есть ли в слоте
			   карта (Compal, +CEISWITCHSIM: "SIM inserted 0/1"). Переключение на
			   ПУСТОЙ слот оставит модем без SIM и уронит связь - гасим кнопку.
			   Где present не сообщают (FM350), поведение прежнее. */
			var empty = (s.present !== undefined && String(s.present) === '0' && !on);
			box.appendChild(E('button', {
				'class': 'btn cbi-button' + (on ? ' cbi-button-action important' : '') + (empty ? ' cbi-button-disabled' : ''),
				'disabled': empty ? '' : null,
				'title': empty ? _('Slot is empty (no SIM inserted)') : null,
				'click': function(ev) {
					ev.preventDefault();
					if (on || empty) { return; }
					ui.showModal(null, E('p', { 'class': 'spinning' }, _('Switching SIM slot...')));
					fs.exec('/usr/share/5gmodem/simslot.sh', [ 'set', String(s.id) ]).then(function(res) {
						ui.hideModal();
						var ok = res && res.stdout && res.stdout.indexOf('"ok"') >= 0;
						if (ui.addTimeLimitedNotification) {
							ui.addTimeLimitedNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), 6000, ok ? 'info' : 'error');
						} else {
							ui.addNotification(null, E('p', ok ? _('SIM slot switched: %s').format(s.label) : _('SIM slot switch failed')), ok ? 'info' : 'error');
						}
						/* Перечитать активный слот, КОГДА модем вернётся. Разового
						   опроса через 4 с не хватало: FM350 после смены слота
						   уходит на переперечисление USB на десятки секунд, ответ
						   был «нет устройства», и подсветка активной кнопки
						   оставалась старой до ручного F5. Опрашиваем с запасом -
						   лишние опросы дёшевы, а simslot.sh «липкий» (см. выше).
						   Интерфейс переподнимает бэкенд (simslot.sh slot_redial),
						   чтобы IP не остался от прежней SIM даже если уйти со
						   страницы. */
						[ 3000, 8000, 15000, 25000, 40000, 60000, 90000 ].forEach(function(ms) {
							window.setTimeout(loadSimSlots, ms);
						});
					}).catch(function() { ui.hideModal(); });
				}
			}, [ s.label ]));
		});
		box.style.display = '';
	});
}

function SIMdata(data) {
	var sdata = {};
	try { sdata = JSON.parse(data) || {}; } catch (e) {}

	var rows = [];
	// «-» значит «слот неизвестен» - строку в подсказке не показываем вовсе
	if (sdata.simslot != null && String(sdata.simslot).length > 0 && sdata.simslot != '-')
		rows.push(_('SIM Slot'), sdata.simslot);
	rows.push(_('SIM IMSI'), sdata.imsi || '-');
	rows.push(_('SIM ICCID'), sdata.iccid || '-');
	rows.push(_('Modem IMEI'), sdata.imei || '-');
	return ui.itemlist(E('span'), rows);
}

/* Подсветить кнопку текущего режима (читается из mmcli -K current-modes) */
function updateModeButtons() {
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', mmIdx, '-K' ]), '').then(function(out) {
		var m = (out || '').match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
		if (!m) { return; }
		var allowed = m[1].split(',').map(function(x) { return x.trim(); }).sort().join('|');
		var pref = m[2].trim();
		if (pref == 'none') { pref = ''; }
		document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
			var ba = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
			var act = (ba == allowed && (b.getAttribute('data-preferred') || '') == pref);
			b.classList.toggle('cbi-button-action', act);
			b.classList.toggle('important', act);
		});
	});
}

/* --- Выбор диапазонов LTE/5G ---
   mmcli --set-current-bands заменяет ВЕСЬ список по всем технологиям
   сразу, поэтому utran/cdma-часть текущего списка сохраняется как есть,
   а заменяются только eutran/ngran (тот же принцип, что в скрипте
   modemband для этого модема). */
var bandsOther = [];

/* Показать/скрыть строку-контейнер значения БЕЗ дёрганья высоты страницы при
   мигании данных. Показываем сразу, как появились данные; прячем только после
   нескольких подряд пустых опросов. Иначе кратковременный '-' (парсинг у FM350
   иногда моргает) менял высоту на каждый опрос -> браузер сам скроллил страницу. */
function setRowVisible(view, hasData) {
	var tr = view && view.parentNode;
	if (!tr) { return; }
	if (hasData) {
		tr.style.display = '';
		tr.removeAttribute('data-empty');
		tr.setAttribute('data-hadata', '1');   // данные у строки БЫЛИ
		return;
	}
	/* СТРОКУ, У КОТОРОЙ ДАННЫЕ УЖЕ БЫЛИ, НЕ ПРЯЧЕМ НИКОГДА.
	   Пустой ответ почти всегда означает не «параметра нет», а коллизию на
	   AT-порту: опрос метрик делит tty с SMS, слотами и профилями, и при
	   наложении двух опросчиков поля разом становятся пустыми (замерено).
	   Раньше строка пряталась после 3 пустых подряд - высота страницы
	   уменьшалась, и если пользователь домотал до низа, вьюпорт полз вверх
	   на строку за тик (баг на proton2025: страница «уезжала» до блока
	   «Информация о соте»). Дебаунс тут не спасал: разные строки достигали
	   порога на разных тиках, отсюда и движение по одной строке.
	   Значение при этом сохраняется прежнее (см. вызывающий код) - показать
	   последнее известное честнее, чем мигать прочерком. */
	if (tr.getAttribute('data-hadata') === '1') { return; }
	/* Данных не было НИ РАЗУ - строку можно спрятать: параметра у модема нет. */
	var n = (parseInt(tr.getAttribute('data-empty'), 10) || 0) + 1;
	tr.setAttribute('data-empty', String(n));
	if (n >= 3) { tr.style.display = 'none'; }
}

/* Цвет оценки метрики CA-компонента (пороги как в modemdata). */
var CA_COLOR = { green: '#2fb885', orange: '#c99a3f', red: '#d95c5c' };
function caQuality(key, v) {
	v = parseFloat(v);
	if (isNaN(v)) { return null; }
	switch (key) {
		case 'rsrp': return v >= -80 ? 'green' : (v >= -100 ? 'orange' : 'red');
		case 'rsrq': return v >= -10 ? 'green' : (v >= -15 ? 'orange' : 'red');
		case 'sinr': return v >= 20 ? 'green' : (v >= 0 ? 'orange' : 'red');
		case 'rssi': return v >= -65 ? 'green' : (v >= -85 ? 'orange' : 'red');
	}
	return null;
}

/* Разбить строку диапазона "B7 (2600 MHz) @20 MHz" на {band, bw}. */
function caSplitBand(s) {
	s = String(s || '');
	var p = s.split(' @');
	return { band: (p[0] || '').trim(), bw: (p[1] || '').trim() };
}

/* Построить таблицу «CA по компонентам» из уже имеющихся полей json (pband/sNband
   + метрики serving для PCC). Пер-SCC RSRP/RSRQ/SINR появятся, когда бэкенд начнёт
   их отдавать (jsonполя sNrsrp/...). Блок прячется, если компонентов нет. */
function renderCaTable(json) {
	var tbl = document.getElementById('ca-table');
	var sec = document.getElementById('ca-comp');
	if (!tbl) { return; }
	// Данные по компонентам, разложенные по ключу CC (PCC/SCC1..4).
	var data = {};
	var hasPcc = json.pband && json.pband != '-';
	if (hasPcc) {
		var p = caSplitBand(json.pband);
		data['PCC'] = { band: p.band, bw: p.bw, pci: json.pci, earfcn: json.earfcn,
			rsrp: json.rsrp, rsrq: json.rsrq, sinr: json.sinr,
			mimo: json.pmimo, mod: json.pmod };
	}
	[ '1', '2', '3', '4' ].forEach(function(i) {
		var b = json['s' + i + 'band'];
		if (b && b != '-') {
			var sb = caSplitBand(b);
			data['SCC' + i] = { band: sb.band, bw: sb.bw,
				pci: json['s' + i + 'pci'], earfcn: json['s' + i + 'earfcn'],
				rsrp: json['s' + i + 'rsrp'], rsrq: json['s' + i + 'rsrq'], sinr: json['s' + i + 'sinr'],
				mimo: json['s' + i + 'mimo'], mod: json['s' + i + 'mod'] };
		}
	});
	// Видимость блока привязана к ПОДКЛЮЧЕНИЮ (наличию pband), а НЕ к числу
	// компонентов: переселение соты «одиночная <-> агрегация» блок не трогает,
	// поэтому высота на опрос не меняется. Прячем только при реальном обрыве
	// (pband пуст несколько опросов подряд - дебаунс).
	if (sec) {
		if (hasPcc) {
			sec.style.display = '';
			sec.removeAttribute('data-empty');
			sec.setAttribute('data-hadata', '1');
		} else if (sec.getAttribute('data-hadata') !== '1') {
			// блок ни разу не наполнялся - можно прятать (см. setRowVisible)
			var n = (parseInt(sec.getAttribute('data-empty'), 10) || 0) + 1;
			sec.setAttribute('data-empty', String(n));
			if (n >= 3) { sec.style.display = 'none'; }
		}
	}
	var txt = function(v) { return (v != null && v !== '' && v !== '-') ? String(v) : '-'; };
	var isMetric = { rsrp: 1, rsrq: 1, sinr: 1 };
	function paintCell(td, key, c) {
		td.textContent = txt(c[key]);
		td.style.color = '';
		td.style.fontWeight = '';
		if (isMetric[key]) {
			var col = (c[key] != null && c[key] !== '' && c[key] !== '-') ? caQuality(key, c[key]) : null;
			if (col) { td.style.color = CA_COLOR[col]; td.style.fontWeight = '600'; }
		}
	}
	// Заполняем ЗАРАНЕЕ нарисованные строки (см. разметку). Строки не создаются
	// и не удаляются - только их ячейки. Первая ячейка (метка CC) статична.
	var cols = [ 'band', 'bw', 'pci', 'earfcn', 'rsrp', 'rsrq', 'sinr', 'mimo', 'mod' ];
	tbl.querySelectorAll('tr.ca-row').forEach(function(row) {
		var c = data[row.getAttribute('data-cc')] || {};
		var tds = row.querySelectorAll('td');
		cols.forEach(function(k, j) { if (tds[j + 1]) { paintCell(tds[j + 1], k, c); } });
	});
}

function bandLabel(b) {
	if (b.indexOf('eutran-') == 0) { return 'B' + b.substring(7); }
	if (b.indexOf('ngran-') == 0) { return 'n' + b.substring(6); }
	if (b.indexOf('utran-') == 0) { return 'B' + b.substring(6); }
	return b;
}

/* Чистый билдер кнопок диапазонов - возвращает массив <button>, чтобы
   строить их синхронно прямо в дереве render() (без DOM-манипуляций
   после отрисовки, иначе страница дёргается при загрузке). */
function buildBandButtons(supported, current, prefix) {
	var numsort = function(a, b) { return parseInt(a.replace(/\D+/g, ''), 10) - parseInt(b.replace(/\D+/g, ''), 10); };
	return supported.filter(function(b) { return b.indexOf(prefix) == 0; }).sort(numsort).map(function(b) {
		return E('button', {
			'class': 'btn cbi-button' + (current.indexOf(b) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': b,
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, bandLabel(b));
	});
}

/* Перерисовывать контейнер ТОЛЬКО при реальном изменении данных.
   ЗАЧЕМ. Блок частот перестраивался на КАЖДОМ тике опроса, даже когда диапазоны
   не менялись: renderBandToggles делал innerHTML='' и набивал контейнер заново.
   На долю мгновения контейнер пуст -> высота документа проваливается -> браузер
   ОБРЕЗАЕТ scrollTop до нового максимума -> кнопки возвращаются, высота тоже, а
   прокрутка остаётся обрезанной. Страница уезжала вверх ровно на высоту этих
   контейнеров, на каждый тик.
   Почему это так долго не находилось: замер высоты видит её неизменной (провал
   живёт доли миллисекунды), перехват scrollTop молчит (двигает не JS, а сам
   браузер), а overflow-anchor:none не помогает - это не анкоринг, а клампинг.
   На bootstrap не проявлялось: другая вёрстка скроллера.
   Возвращает true, если данные те же и трогать DOM не нужно. */
function sameRender(el, sig) {
	if (!el) { return false; }
	if (el.getAttribute('data-sig') === sig) { return true; }
	el.setAttribute('data-sig', sig);
	return false;
}

function renderBandToggles(contId, bands, current, prefix) {
	var cont = document.getElementById(contId);
	if (!cont) { return; }
	if (sameRender(cont, prefix + '|' + bands.join(',') + '|' + current.join(','))) { return; }
	cont.innerHTML = '';
	buildBandButtons(bands, current, prefix).forEach(function(btn) {
		cont.appendChild(btn);
	});
}

function loadBands() {
	// Модульный опрос: пока блок «Управление частотами» свёрнут, НЕ дёргаем
	// mmcli/bands.sh (это ускоряет загрузку). Данные подтянутся при раскрытии
	// (см. onBlockExpand['freq']).
	if (!blockExpanded('freq')) { return Promise.resolve(); }
	if (bandsGated) { return Promise.resolve(); }   // управление запрещено бэкендом
	return L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', mmIdx, '-K' ]), '').then(function(out) {
		if (!out) { return; }
		var supported = [], current = [];
		out.split('\n').forEach(function(ln) {
			var m = ln.match(/^modem\.generic\.(supported|current)-bands\.value\[\d+\]\s*:\s*(\S+)/);
			if (m) { (m[1] == 'supported' ? supported : current).push(m[2]); }
		});
		// No bands from mmcli. Distinguish two cases:
		//  - modem that NEVER exposes bands via mmcli (e.g. Fibocom FM350 under MM):
		//    fall back to the vendor AT band path (GTACT via bands.sh);
		//  - modem that normally HAS mmcli bands but is momentarily empty (e.g. the
		//    Compal while it re-registers after a SIM swap): keep the last-good view,
		//    do NOT switch to the AT path - otherwise the band block flickers.
		if (!supported.length) {
			if (mmcliBandsLoaded) { return; }
			return loadBandsModemband();
		}
		mmcliBandsLoaded = true;
		// utran (3G) is now managed by its own toggles, so it's NOT part of the
		// preserved "other" set anymore (only cdma and the like stay untouched).
		bandsOther = current.filter(function(b) {
			return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0 && b.indexOf('utran-') != 0;
		});
		var numsort = function(a, b) { return parseInt(a.replace(/\D+/g, ''), 10) - parseInt(b.replace(/\D+/g, ''), 10); };
		var utran = supported.filter(function(b) { return b.indexOf('utran-') == 0; }).sort(numsort);
		renderBandToggles('bands-3g', utran, current, 'utran-');
		renderBandToggles('bands-lte', supported.filter(function(b) { return b.indexOf('eutran-') == 0; }).sort(numsort), current, 'eutran-');
		renderBandToggles('bands-nr', supported.filter(function(b) { return b.indexOf('ngran-') == 0; }).sort(numsort), current, 'ngran-');
		// show the 3G row only if the modem actually exposes UTRAN bands
		var row3g = document.getElementById('bands3gn');
		if (row3g) { row3g.style.display = utran.length ? '' : 'none'; }
	});
}

/* ---- Управление диапазонами через modemband (для модемов, у которых mmcli
   не отдаёт бенды: не под ModemManager, или MM их не показывает). Данные и
   применение - вендорными AT-командами через /usr/share/5gmodem/bands.sh. ---- */
var bandSource = 'mmcli';   // 'mmcli' | 'modemband'
/* true, когда bands.sh сказал, что управление диапазонами/режимом СЕЙЧАС
   невозможно (профиль объявил _BAND_VIA=mmcli, а интерфейс на kernel-прото
   mbim/qmi -> модем скрыт от ModemManager). Это авторитетный ответ бэкенда, и
   он ЗАПРЕЩАЕТ mmcli-путь: без флага loadBandsModemband() рисовал надпись
   «переключите на ModemManager», а revealMgmtWhenReady() тут же дёргал
   mmcli -m any -K, попадал в ЧУЖОЙ модем (FM350 виден MM как failed) и показывал
   его «Режимы сети» с кнопками и пустые «Диапазоны» - блок мигал на каждый опрос.
   (bandSource для этого не годится: в запрещённой ветке он остаётся 'mmcli'.) */
var bandsGated = false;
/* true once mmcli has returned a non-empty band list for the active modem; used
   to tell a real "no mmcli bands" modem (FM350) from a transient empty (Compal
   re-registering) so the band block does not flicker. Resets on modem switch
   because the view fully reloads. */
var mmcliBandsLoaded = false;
/* Индекс ACTIVE модема в ModemManager (для управления бендами/режимом при
   нескольких модемах). 'any' - фолбэк для одного модема. Ставится в load(). */
var mmIdx = 'any';
/* Протокол интерфейса модема (из json.protocol). В режиме modemmanager бендами
   управляют через mmcli, поэтому пояснение «переключите на ModemManager» там НЕ
   показываем - если mmcli временно не готов (напр. модем пересоздают), это
   транзитное состояние, а не «нельзя управлять». */
var ifaceProtoIsMM = false;

function buildBandButtonsNum(supported, enabled, btype) {
	var pfx = (btype == 'lte') ? 'B' : 'n';
	return (supported || []).map(function(n) {
		n = parseInt(n, 10);
		return E('button', {
			'class': 'btn cbi-button' + ((enabled || []).indexOf(n) >= 0 ? ' cbi-button-action important' : ''),
			'data-band': String(n),
			'data-btype': btype,
			'click': function(ev) {
				ev.preventDefault();
				ev.currentTarget.classList.toggle('cbi-button-action');
				ev.currentTarget.classList.toggle('important');
			}
		}, pfx + n);
	});
}

/* ---- Сворачиваемые блоки страницы «Сеть» -------------------------------
   Все блоки, кроме шапки (модем/SIM/сеть/соединение), сворачиваемы и свёрнуты
   по умолчанию. Состояние — в localStorage. Модульный опрос: данные блока
   обновляются/запрашиваются только когда он раскрыт (см. blockExpanded и
   реестр onBlockExpand). */
var onBlockExpand = {};
function blockExpanded(key) {
	try { return localStorage.getItem('5gm-blk-' + key) === '1'; } catch (e) { return false; }
}
function collapsibleSection(key, titleText, content, extraAttrs) {
	var expanded = blockExpanded(key);   // по умолчанию свёрнут
	var chev = E('span', { 'style': 'display:inline-flex;transition:transform .15s ease;transform:rotate(' + (expanded ? '180' : '0') + 'deg)' });
	chev.innerHTML = '<svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor"><path d="M7 10l5 5 5-5z"/></svg>';
	var body = E('div', { 'style': 'display:' + (expanded ? 'block' : 'none') }, content);
	var title = E('h3', {
		'style': 'display:flex;align-items:center;gap:.35em;cursor:pointer;user-select:none;margin-bottom:' + (expanded ? '.5em' : '0'),
		'click': function() {
			var exp = (body.style.display === 'none');
			body.style.display = exp ? 'block' : 'none';
			title.style.marginBottom = exp ? '.5em' : '0';
			chev.style.transform = 'rotate(' + (exp ? '180' : '0') + 'deg)';
			try { localStorage.setItem('5gm-blk-' + key, exp ? '1' : '0'); } catch (e) {}
			if (exp && typeof onBlockExpand[key] === 'function') { onBlockExpand[key](); }
		}
	}, [ chev, E('span', {}, titleText) ]);
	var attrs = { 'class': 'cbi-section tginfo', 'data-blk': key };
	if (extraAttrs) { for (var k in extraAttrs) { attrs[k] = extraAttrs[k]; } }
	return E('div', attrs, [ title, body ]);
}
// При раскрытии блока «Управление частотами» подтягиваем данные (пока свёрнут -
// band-функции возвращают сразу, mmcli/bands.sh не дёргаются). loadBands/
// loadBandsModemband - function declarations, поэтому доступны здесь.
onBlockExpand['freq'] = function() {
	if (typeof loadBandsModemband === 'function') { loadBandsModemband(); }
	if (typeof loadBands === 'function') { loadBands(); }
};

/* Единая сортировка режимов сети для ВСЕХ модемов: Auto, затем по поколению с
   комбинациями сразу после младшего поколения:
   Auto | 2G | 2G+3G | 3G | 3G+4G | 4G | 4G+5G | 5G.
   Ранг = min_gen*10 + (max_gen-min_gen). Метки в профилях латиницей ("2G"). */
function netModeRank(label) {
	var s = String(label || '');
	if (/auto/i.test(s)) { return -1; }
	var gens = (s.match(/([0-9])\s*G/gi) || []).map(function(x) { return parseInt(x, 10); });
	if (!gens.length) { return 999; }
	var mn = Math.min.apply(null, gens), mx = Math.max.apply(null, gens);
	return mn * 10 + (mx - mn);
}
function sortNetModes(modes) {
	return (modes || []).slice().sort(function(a, b) {
		return netModeRank(a.label) - netModeRank(b.label);
	});
}

/* Показать блок частот и заполнить кнопки из bands.sh (без mmcli). Режим сети
   (Auto/2G/…) остаётся скрытым - он управляется только через mmcli. */
function loadBandsModemband() {
	if (!blockExpanded('freq')) { return Promise.resolve(); }   // модульный опрос
	return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/bands.sh', [ 'json' ]), '').then(function(out) {
		var j = {};
		var note = document.getElementById('bandnote');
		try { j = JSON.parse(out) || {}; } catch (e) { if (note) { note.style.display = ''; } return; }
		// Считаем управление доступным, только если список поддерживаемых бендов
		// НЕПУСТ. Раньше проверяли !j.supported, но bands.sh отдаёт пустой массив
		// [] (напр. Compal в mbim: mmcli выключен), а ![] === false, и код шёл
		// рисовать строки бендов с прочерком вместо пояснения.
		var hasBands = (j.supported && j.supported.length) ||
		               (j.supported5gnsa && j.supported5gnsa.length) ||
		               (j.supported5gsa && j.supported5gsa.length);
		if (j.error || !hasBands) {
			// Транзитный пустой ответ (bands.sh иногда конкурирует с опросом метрик
			// за AT-порт FM350): если бенды уже загружены по modemband-пути, НЕ
			// сносим блок - иначе строки «Режим сети»/диапазоны моргают на каждый
			// опрос (и re-reveal их снова показывает).
			if (bandSource == 'modemband') { return; }
			// Ни mmcli, ни вендорные AT-команды не дали список диапазонов.
			[ 'modeswn', 'bands3gn', 'bandsn', 'bands5gn', 'bandsactn', 'bandwarnn' ].forEach(function(id) {
				var e = document.getElementById(id); if (e) { e.style.display = 'none'; }
			});
			// Пояснение «переключите на ModemManager» показываем ТОЛЬКО если
			// интерфейс НЕ modemmanager. В режиме modemmanager пустой список -
			// это временно (mmcli не готов, модем пересоздаётся), а не «нельзя
			// управлять»: mmcli-путь заполнит бенды сам, ждём следующий опрос.
			if (note) { note.style.display = ifaceProtoIsMM ? 'none' : ''; }
			// Надпись показана => управление запрещено: гасим mmcli-путь, иначе он
			// перерисует блок чужими данными и всё замигает (см. bandsGated).
			bandsGated = !ifaceProtoIsMM;
			if (ifaceProtoIsMM) { window.setTimeout(revealMgmtWhenReady, 1500); }
			return;
		}
		if (note) { note.style.display = 'none'; }
		bandsGated = false;
		bandSource = 'modemband';
		/* Диапазоны 3G у modemband-модемов - ВЫПАДАЮЩИЙ СПИСОК, а не галочки.
		   У LTE прошивка принимает битовую маску (любой набор), а у 3G - номер
		   ГОТОВОЙ КОМБИНАЦИИ из таблицы модема (Telit: 2-е поле #BND). Набрать
		   произвольный набор нельзя, поэтому галочки тут врали бы: пользователь
		   снял бы одну, а модем применил бы совсем другой набор. Бэкенд отдаёт
		   combos3g=[{id,label}] + current3g; профиль без 3G их не отдаёт вовсе -
		   тогда строку прячем, как раньше. */
		var row3g = document.getElementById('bands3gn');
		var c3g = document.getElementById('bands-3g');
		if (c3g && j.combos3g && j.combos3g.length) {
			if (row3g) { row3g.style.display = ''; }
			/* Пересобираем ТОЛЬКО при изменении (см. sameRender). Строку при этом
			   показываем всегда - видимость и перерисовка это разные вещи. */
			if (!sameRender(c3g, String(j.current3g) + '|' + j.combos3g.map(function(o){ return o.id; }).join(','))) {
			c3g.innerHTML = '';
			/* Кнопки как у «Режима сети», а НЕ как у LTE: там переключатели (можно
			   отметить любой набор), а комбинация 3G выбирается РОВНО ОДНА - клик
			   сразу применяет её. Подписи длинные («2100 + 1900 + 850») - это
			   нормально, ряд переносится. */
			j.combos3g.forEach(function(o) {
				var on = (String(j.current3g) === String(o.id));
				c3g.appendChild(E('button', {
					'class': 'btn cbi-button combo3g' + (on ? ' cbi-button-action important' : ''),
					'data-combo3g': String(o.id),
					'click': function(ev) { ev.preventDefault(); setBands3gAT(o.id, o.label); }
				}, o.label));
			});
			}
		} else if (row3g) {
			row3g.style.display = 'none';
		}

		var supLte = (j.supported || []).map(function(o) { return o.band; });
		var supNsa = (j.supported5gnsa || []).map(function(o) { return o.band; });
		var enLte  = j.enabled || [];
		var enNsa  = j.enabled5gnsa || [];

		[ 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var e = document.getElementById(id); if (e) { e.style.display = ''; }
		});
		// Постоянная подсказка о кратком обрыве при смене диапазонов - только для
		// модемов, чей профиль выставил bandwarn (FM350: GTACT рвёт PDP).
		var warnRow = document.getElementById('bandwarnn');
		if (warnRow) { warnRow.style.display = j.bandwarn ? '' : 'none'; }

		var lteC = document.getElementById('bands-lte');
		if (lteC && !sameRender(lteC, supLte.join(',') + '|' + enLte.join(','))) {
			lteC.innerHTML = '';
			if (supLte.length) { buildBandButtonsNum(supLte, enLte, 'lte').forEach(function(b) { lteC.appendChild(b); }); }
			else { lteC.textContent = '-'; }
		}
		var nrRow = document.getElementById('bands5gn');
		var nrC = document.getElementById('bands-nr');
		if (nrC) {
			// перерисовка - только при изменении (см. sameRender)
			if (!sameRender(nrC, supNsa.join(',') + '|' + enNsa.join(','))) {
				nrC.innerHTML = '';
				if (supNsa.length) { buildBandButtonsNum(supNsa, enNsa, 'nsa').forEach(function(b) { nrC.appendChild(b); }); }
			}
			// видимость - отдельно от перерисовки: нет 5G, значит строки нет
			if (!supNsa.length && nrRow) { nrRow.style.display = 'none'; }
		}

		// Режим сети (2G/3G/4G) через AT+CNMP (bands.sh getmode/setmode) - для
		// модемов не под ModemManager, где mmcli-переключатель недоступен.
		var modeRow = document.getElementById('modeswn');
		var modeC = document.getElementById('modesw-btns');
		if (modeC && j.modes && j.modes.length) {
			/* Видимость строки и перерисовка кнопок - РАЗНЫЕ вещи: строку
			   показываем всегда, когда режимы есть, а кнопки пересобираем только
			   при изменении (иначе контейнер пустеет каждый тик и браузер
			   обрезает scrollTop - см. sameRender). */
			if (!sameRender(modeC, String(j.currentmode) + '|' + j.modes.map(function(m){ return m.id; }).join(','))) {
				modeC.innerHTML = '';
				sortNetModes(j.modes).forEach(function(m) {
					var on = (String(j.currentmode) === String(m.id));
					modeC.appendChild(E('button', {
						'class': 'btn cbi-button' + (on ? ' cbi-button-action important' : ''),
						'data-mode': String(m.id),
						'click': function(ev) { ev.preventDefault(); setNetModeAT(m.id, m.label); }
					}, m.label));
				});
			}
			if (modeRow) { modeRow.style.display = ''; }
		} else if (modeRow) {
			modeRow.style.display = 'none';
		}
	});
}

/* Применить/сбросить диапазоны через modemband */
function applyBandsModemband(reset) {
	var lte = [], nsa = [];
	if (!reset) {
		document.querySelectorAll('#bands-lte .cbi-button-action').forEach(function(b) { lte.push(b.getAttribute('data-band')); });
		document.querySelectorAll('#bands-nr .cbi-button-action').forEach(function(b) { nsa.push(b.getAttribute('data-band')); });
		if (!lte.length && !nsa.length) {
			ui.addNotification(null, E('p', _('Select at least one band')), 'error');
			return Promise.resolve();
		}
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying bands...')));
	var hasLte = document.querySelector('#bands-lte .cbi-button') != null;
	var hasNsa = document.querySelector('#bands-nr .cbi-button') != null;
	var p = Promise.resolve();
	if (hasLte) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands', reset ? 'default' : lte.join(' ') ]); }); }
	if (hasNsa) { p = p.then(function() { return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands5gnsa', reset ? 'default' : nsa.join(' ') ]); }); }
	// После смены бендов перезапускаем радио модема (CFUN=4->1): без этого
	// модем не начинает использовать новый набор частот / агрегацию до
	// переподключения, и скорость остаётся низкой. Мягкий рестарт, без
	// переэнумерации USB.
	p = p.then(function() { return fs.exec('/usr/share/5gmodem/reboot_modem.sh'); });
	return p.then(function() {
		ui.hideModal();
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Bands set, restarting the modem radio to apply them...')), 6000, 'info');
		} else {
			ui.addNotification(null, E('p', _('Bands set, restarting the modem radio to apply them...')), 'info');
		}
		window.setTimeout(loadBandsModemband, 4000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (err.message || err)), 'error');
	});
}

/* Ссылка на карту вышек 4cells.ru по данным соты. Подтверждено примерами:
     LTE (tech=3): num = eNB = CID >> 8, lac = TAC (или LAC)
     UMTS(tech=2): num = CID, lac = LAC
     GSM (tech=1): num = CID, без параметра lac
   plmn = MCC + MNC (каждое дополняется до 3 цифр). 5G NSA идёт по LTE-якорю
   (tech=3). Для 5G SA формула пока неизвестна - кнопку не показываем. */
function cell4cellsUrl(json) {
	var mcc = parseInt(json.operator_mcc, 10);
	var mnc = parseInt(json.operator_mnc, 10);
	var cid = parseInt(json.cid_dec, 10);
	if (isNaN(mcc) || isNaN(mnc) || isNaN(cid) || cid <= 0) { return null; }

	var lac = parseInt((json.tac_d && String(json.tac_d).length ? json.tac_d : (json.tac_dec || '')), 10);
	if (isNaN(lac)) { lac = parseInt(json.lac_dec || '', 10); }

	var mode = String(json.mode || '').toUpperCase();
	var tech, num, needLac = true;
	if (mode.indexOf('GSM') >= 0 || mode.indexOf('EDGE') >= 0 || mode.indexOf('GPRS') >= 0 || mode.indexOf('2G') >= 0) {
		tech = 1; num = cid; needLac = false;               // GSM - без lac
	} else if (mode.indexOf('WCDMA') >= 0 || mode.indexOf('UMTS') >= 0 || mode.indexOf('HSPA') >= 0 || mode.indexOf('3G') >= 0) {
		tech = 2; num = cid;                                // UMTS
	} else if (mode.indexOf('5G SA') >= 0) {
		return null;                                        // NR SA - формула неизвестна
	} else {                                                // LTE / 5G NSA
		tech = 3; num = Math.floor(cid / 256);
	}

	var p3 = function(x) { x = String(x); while (x.length < 3) { x = '0' + x; } return x; };
	var url = 'https://4cells.ru/?plmn=' + p3(mcc) + p3(mnc) + '&tech=' + tech + '&num=' + num;
	if (needLac) {
		if (isNaN(lac)) { return null; }
		url += '&lac=' + lac;
	}
	return url;
}

/* Подсветить активную кнопку режима сети по выводу mmcli -K */
function refreshModeButtons(mmK) {
	var mm = String(mmK || '').match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
	if (!mm) { return; }
	var allowed = mm[1].split(',').map(function(x) { return x.trim(); }).sort().join('|');
	var pref = (mm[2].trim() == 'none' ? '' : mm[2].trim());
	document.querySelectorAll('#modesw-btns .cbi-button').forEach(function(b) {
		var a = (b.getAttribute('data-allowed') || '').split('|').sort().join('|');
		var p = b.getAttribute('data-preferred') || '';
		var on = (a == allowed && p == pref);
		b.classList.toggle('cbi-button-action', on);
		b.classList.toggle('important', on);
	});
}

/* Модем мог быть не готов на момент отрисовки: блок управления частотами
   тогда скрыт и пуст. Когда модем появляется, показать строки и заполнить
   кнопки без ручного обновления страницы. Тяжёлый mmcli -K дёргаем только
   пока блок ещё скрыт. */
function revealMgmtWhenReady(tries) {
	var row = document.getElementById('modeswn');
	if (!row || row.style.display != 'none') { return; }
	// Блок частот уже инициализирован вендорным путём (bands.sh/GTACT) - строка
	// «Режим сети» скрыта ОСОЗНАННО (модем не отдаёт CNMP-режимы). Не лезем в
	// mmcli: у модема вне MM (напр. инхибированный FM350) mmIdx='any' попадает в
	// ЧУЖОЙ модем (Compal), и выходил цикл на каждый опрос: reveal показывал
	// строку с чужими кнопками -> loadBandsModemband прятал -> высота страницы
	// прыгала (тот самый скролл-баг).
	if (bandSource == 'modemband') { return; }
	// Бэкенд уже сказал «управлять нельзя» и показал надпись - не лезем в mmcli.
	if (bandsGated) { return; }
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-m', mmIdx, '-K' ]), '').then(function(mmK) {
		if (!/current-modes/.test(mmK)) {
			// mmcli ещё не готов (модем под MM поднимается): повторяем
			// несколько раз, чтобы блок частот появился сам после пересоздания.
			var n = (tries || 0);
			if (ifaceProtoIsMM && n < 8) { window.setTimeout(function() { revealMgmtWhenReady(n + 1); }, 2000); }
			return;
		}
		[ 'modeswn', 'bands3gn', 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var e = document.getElementById(id);
			if (e) { e.style.display = ''; }
		});
		refreshModeButtons(mmK);
		loadBands();
	});
}

function applyBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(false); }
	var sel = [];
	document.querySelectorAll('#bands-3g .cbi-button-action, #bands-lte .cbi-button-action, #bands-nr .cbi-button-action').forEach(function(b) {
		sel.push(b.getAttribute('data-band'));
	});
	if (!sel.length) {
		ui.addNotification(null, E('p', _('Select at least one band')), 'error');
		return Promise.resolve();
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying bands...')));
	return fs.exec('/usr/bin/mmcli', [ '-m', mmIdx, '--set-current-bands=' + bandsOther.concat(sel).join('|') ]).then(function(res) {
		if (res.code !== 0) {
			ui.hideModal();
			ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + (res.stderr || res.stdout || '')), 'error');
			return;
		}
		// Мягкий рестарт радио (CFUN=4->1), чтобы модем начал использовать
		// новый набор частот сразу, а не после следующего переподключения.
		return fs.exec('/usr/share/5gmodem/reboot_modem.sh').then(function() {
			ui.hideModal();
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Bands set, restarting the modem radio to apply them...')), 6000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Bands set, restarting the modem radio to apply them...')), 'info');
			}
			window.setTimeout(loadBands, 4000);
		});
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set bands') + ': ' + err.message), 'error');
	});
}

function resetBands() {
	if (bandSource == 'modemband') { return applyBandsModemband(true); }
	document.querySelectorAll('#bands-3g .cbi-button, #bands-lte .cbi-button, #bands-nr .cbi-button').forEach(function(b) {
		b.classList.add('cbi-button-action', 'important');
	});
	return applyBands();
}

/* Перезагрузка модема, два режима:
   - soft (CFUN=4->1): перезапуск только радио, без переэнумерации USB. Быстрое
     переподключение к сети, MM сохраняет MBIM-классификацию.
   - hard (CFUN=1,1): полная перезагрузка модема с переинициализацией USB.
     Дольше; на MM-модемах порт может кратко переклассифицироваться. Для случаев,
     когда мягкий рестарт не помог. */
function rebootModem(hard) {
	var msg = hard
		? _('Fully restart the modem (CFUN=1,1)? It will reboot and re-enumerate on USB - this takes longer and the connection will drop for about a minute.')
		: _('Restart the modem radio now? The connection will drop for a while.');
	if (!confirm(msg))
		return Promise.resolve();
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Restarting the modem...')));
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ hard ? 'hard' : 'soft' ]).then(function(res) {
		ui.hideModal();
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			ui.addNotification(null, E('p', _('Modem AT port not found')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification)
			ui.addTimeLimitedNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 8000, 'info');
		else
			ui.addNotification(null, E('p', _('The modem is restarting. This can take a minute.')), 'info');
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to restart the modem') + ': ' + (err.message || err)), 'error');
	});
}

/* Аппаратная перезагрузка модема по питанию (GPIO modem_power и т.п.). Кнопка
   показывается только если у платы есть такой GPIO (см. reboot_modem.sh haspower). */
function rebootModemPower() {
	if (!confirm(_('Power-cycle the modem via the board power line? Power is cut for a few seconds and the modem re-appears in about a minute. On some boards this affects only the M.2 slot.')))
		return Promise.resolve();
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Power-cycling the modem...')));
	return fs.exec('/usr/share/5gmodem/reboot_modem.sh', [ 'power' ]).then(function(res) {
		ui.hideModal();
		var d = {}; try { d = JSON.parse((res && res.stdout) || '{}'); } catch (e) {}
		if (d.success === false) {
			ui.addNotification(null, E('p', _('No modem power GPIO on this board')), 'error');
			return;
		}
		if (ui.addTimeLimitedNotification)
			ui.addTimeLimitedNotification(null, E('p', _('The modem is power-cycling. This can take a minute.')), 8000, 'info');
		else
			ui.addNotification(null, E('p', _('The modem is power-cycling. This can take a minute.')), 'info');
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to power-cycle the modem') + ': ' + (err.message || err)), 'error');
	});
}

/* Показать кнопку «Перезагрузка по питанию», только если у платы есть GPIO
   питания модема. Дёшево: один exec reboot_modem.sh haspower при загрузке. */
function initPowerBtn() {
	var b = document.getElementById('btn-power-reboot');
	if (!b) { return; }
	L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/reboot_modem.sh', [ 'haspower' ]), '').then(function(out) {
		var g = ''; try { g = (JSON.parse(out || '{}').gpio) || ''; } catch (e) {}
		if (g) { b.style.display = ''; }
	});
}

/* Зафиксировать TTL/hop-limit на интерфейсе модема через ttl.sh */
function applyTTL(has6) {
	var g = function(id) { var e = document.getElementById(id); return e ? String(e.value).trim() : ''; };
	var vals = [ g('ttl4in'), g('ttl4out'), has6 ? g('ttl6in') : '', has6 ? g('ttl6out') : '' ];
	for (var i = 0; i < vals.length; i++) {
		if (vals[i] !== '' && (!/^\d+$/.test(vals[i]) || +vals[i] < 1 || +vals[i] > 255)) {
			ui.addNotification(null, E('p', _('TTL must be a number between 1 and 255, or empty to disable')), 'error');
			return Promise.resolve();
		}
	}
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying TTL...')));
	return fs.exec('/usr/share/5gmodem/ttl.sh', [ 'set' ].concat(vals)).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('TTL applied.')), 4000, 'info');
			} else {
				ui.addNotification(null, E('p', _('TTL applied.')), 'info');
			}
		} else {
			ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to apply TTL') + ': ' + err.message), 'error');
	});
}

/* Иконка SIM по имени оператора (упрощённые фирменные значки) */
function operatorIcon(name) {
	var n = (name || '').toLowerCase();
	if (n.indexOf('t-mobile') >= 0 || n.indexOf('tinkoff') >= 0 || n.indexOf('t-bank') >= 0 || n.indexOf('т-мобайл') >= 0 || n.indexOf('т-банк') >= 0) { return 'op-tbank'; }
	if (n.indexOf('beeline') >= 0 || n.indexOf('билайн') >= 0 || n.indexOf('vimpel') >= 0) { return 'op-beeline'; }
	if (n.indexOf('mts') >= 0 || n.indexOf('мтс') >= 0) { return 'op-mts'; }
	if (n.indexOf('megafon') >= 0 || n.indexOf('мегафон') >= 0) { return 'op-megafon'; }
	if (n.indexOf('tele2') >= 0 || n.indexOf('теле2') >= 0 || n.trim() == 't2' || n.indexOf('t2 ') == 0 || n.indexOf(' t2') >= 0) { return 'op-t2'; }
	if (n.indexOf('yota') >= 0) { return 'op-yota'; }
	return null;
}

function updateSimIcon(name) {
	var si = document.getElementById('simicon');
	if (!si) { return; }
	var want;
	if (name == null || String(name).length < 1 || String(name) == '-') {
		want = L.resource('icons/op-nosim.png');   // модем ещё грузится / нет SIM
	} else {
		var ic = operatorIcon(name);
		want = ic ? L.resource('icons/' + ic + '.png') : L.resource('icons/op-sim.png');
	}
	if (si.getAttribute('src') != want) { si.setAttribute('src', want); }
}

function setNetMode(allowed, preferred, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	var args = [ '-m', mmIdx, '--set-allowed-modes=' + allowed ];
	if (preferred) { args.push('--set-preferred-mode=' + preferred); }
	return fs.exec('/usr/bin/mmcli', args).then(function(res) {
		ui.hideModal();
		if (res.code === 0) {
			if (ui.addTimeLimitedNotification) {
				ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
			} else {
				ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
			}
			window.setTimeout(updateModeButtons, 1200);
		} else {
			ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + (res.stderr || res.stdout || '')), 'error');
		}
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

/* Смена режима сети (2G/3G/4G) для modemband-модемов - через вендорную
   AT-команду (bands.sh setmode -> AT+CNMP), не через mmcli. Затем мягкий
   рестарт радио, чтобы модем перерегистрировался в выбранном режиме. */
function setNetModeAT(id, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying network mode...')));
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setmode', String(id) ]).then(function() {
		return fs.exec('/usr/share/5gmodem/reboot_modem.sh');
	}).then(function() {
		ui.hideModal();
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('Network mode set: %s').format(label)), 5000, 'info');
		} else {
			ui.addNotification(null, E('p', _('Network mode set: %s').format(label)), 'info');
		}
		window.setTimeout(loadBandsModemband, 4000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set network mode') + ': ' + err.message), 'error');
	});
}

/* Таблица «Антенные порты». Данные приходят ОБЫЧНЫМ опросом метрик (поле
   antports: "порт:rsrp:rsrq ..."), потому что профиль добирает #LAPS той же
   AT-цепочкой, что и всё остальное - лишних запросов к порту ноль. Раньше здесь
   был отдельный вызов bands.sh + кнопка «Обновить»: и порт дёргали зря (даже
   когда блок свёрнут), и антенну крутить было неудобно - значения не живые.
   Блок показываем только если модем реально ответил: команда вендорная. */
function fillAntPorts(raw) {
	var block = document.getElementById('antports-block');
	var tbl = document.getElementById('antports-table');
	if (!block || !tbl) { return; }
	var rows = String(raw || '').trim().split(/\s+/).filter(function(l) {
		return /^\d+:-?\d+:-?\d+$/.test(l);
	});
	if (!rows.length) { block.style.display = 'none'; return; }
	block.style.display = '';
	/* Пересобираем только при изменении: пустеющий контейнер провоцирует у темы
	   пересчёт таблиц и обрезание скролла (см. sameRender). */
	if (sameRender(tbl, rows.join(' '))) { return; }
	tbl.innerHTML = '';
	tbl.appendChild(E('tr', { 'class': 'tr table-titles' }, [
		E('th', { 'class': 'th left' }, _('Antenna port')),
		E('th', { 'class': 'th left' }, _('RSRP')),
		E('th', { 'class': 'th left' }, _('RSRQ')),
		E('th', { 'class': 'th left' }, _('State'))
	]));
	rows.forEach(function(l) {
		var p = l.split(':');
		var rsrp = parseInt(p[1], 10);
		/* Цвета и пороги - ОБЩИЕ с «Агрегацией несущих» (CA_COLOR/caQuality),
		   чтобы -100 dBm означало одно и то же в обеих таблицах. Свои цифры тут
		   были бы отдельной правдой: пользователь видит две таблицы рядом. */
		var st, col;
		if (isNaN(rsrp)) {
			st = '-'; col = null;
		} else if (rsrp <= -130) {
			/* Шкала LTE: -44 (отлично) … -140 (ничего). Около -130 и ниже антенны
			   фактически нет - так выглядит неподключённый пигтейл (проверено на
			   LM960: порт без антенны давал -134). Это НЕ «плохой сигнал», а
			   отсутствие антенны - отдельный случай, порогов caQuality тут мало. */
			st = _('antenna: none'); col = 'red';
		} else {
			/* Подпись СЛЕДУЕТ за цветом: зелёный - норма, жёлтый - слабо,
			   красный - плохо. Иначе -102 dBm красился бы красным, а
			   подписывался «слабый сигнал» - две правды в одной строке. */
			col = caQuality('rsrp', rsrp);
			st = (col === 'green') ? _('antenna: normal')
			   : (col === 'orange') ? _('antenna: weak signal')
			   : _('antenna: poor signal');
		}
		var paint = function(td, key, v) {
			var c = caQuality(key, v);
			if (c) { td.style.color = CA_COLOR[c]; td.style.fontWeight = '600'; }
			return td;
		};
		tbl.appendChild(E('tr', { 'class': 'tr' }, [
			/* Номер порта - тот, что дал модем. Подписи пигтейлов (PRI/DIV) у
			   каждой платы свои, соответствие не выдумываем. */
			E('td', { 'class': 'td left' }, _('Port %d').format(parseInt(p[0], 10))),
			paint(E('td', { 'class': 'td left' }, p[1] + ' dBm'), 'rsrp', p[1]),
			paint(E('td', { 'class': 'td left' }, p[2] + ' dB'), 'rsrq', p[2]),
			E('td', {
				'class': 'td left',
				'style': col ? ('color:' + CA_COLOR[col] + ';font-weight:600') : ''
			}, st)
		]));
	});
}

/* Выбор комбинации диапазонов 3G (одна из; см. combos3g в bands.sh).
   Как и смена режима сети, требует перезапуска модема - #BND у Telit
   сохраняется в NVRAM и подхватывается при старте. */
function setBands3gAT(id, label) {
	ui.showModal(null, E('p', { 'class': 'spinning' }, _('Applying 3G bands...')));
	return fs.exec('/usr/share/5gmodem/bands.sh', [ 'setbands3g', String(id) ]).then(function() {
		return fs.exec('/usr/share/5gmodem/reboot_modem.sh');
	}).then(function() {
		ui.hideModal();
		if (ui.addTimeLimitedNotification) {
			ui.addTimeLimitedNotification(null, E('p', _('3G bands set: %s').format(label)), 5000, 'info');
		} else {
			ui.addNotification(null, E('p', _('3G bands set: %s').format(label)), 'info');
		}
		window.setTimeout(loadBandsModemband, 4000);
	}).catch(function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', _('Failed to set 3G bands') + ': ' + err.message), 'error');
	});
}

/* Кнопки режимов сети показываются только когда модемом управляет
   ModemManager (иначе mmcli недоступен или модем не его) */
function modesw_show() {
	L.resolveDefault(fs.exec_direct('/usr/bin/mmcli', [ '-L' ]), '').then(function(out) {
		if (!out || out.indexOf('/Modem/') < 0) { return; }
		[ 'modeswn', 'bands3gn', 'bandsn', 'bands5gn', 'bandsactn' ].forEach(function(id) {
			var row = document.getElementById(id);
			if (row) { row.style.display = ''; }
		});
		updateModeButtons();
		loadBands();
	});
}

function active_select() {
	L.resolveDefault(uci.load('modemdefine'), null).then(function() {
		/* Кнопка переключения модемов нужна только когда в modemdefine
		   определён второй модем - с единственным её незачем показывать
		   (раньше она висела полупрозрачной/выключенной). */
		var modemz = (uci.get('modemdefine', '@modemdefine[1]', 'comm_port'));
		var btn = document.getElementById("modc");
		if (!btn) { return; }
		if (!modemz) {
			btn.style.display = 'none';
		}
		else {
			btn.style.display = 'block';
			btn.disabled = false;
		}
	});
}

/* Телефон в вид «+7 (901) 901-84-79» для 11-значных РФ-номеров (7… или 8…).
   Иностранные/непонятные форматы отдаём как есть. */
function formatPhone(raw) {
    var s = String(raw || '').trim();
    if (!s) { return s; }
    var d = s.replace(/[^\d]/g, '');
    if (d.length === 11 && d.charAt(0) === '8') { d = '7' + d.slice(1); }
    if (d.length === 11 && d.charAt(0) === '7') {
        return '+7 (' + d.slice(1, 4) + ') ' + d.slice(4, 7) + '-' + d.slice(7, 9) + '-' + d.slice(9, 11);
    }
    return s;
}

function formatDuration(sec) {
    if (sec === '-' || sec === '') { return '-'; }
    sec = parseInt(sec, 10);
    if (isNaN(sec)) { return '-'; }
    var d = Math.floor(sec / 86400),
        h = Math.floor(sec / 3600) % 24,
        m = Math.floor(sec / 60) % 60,
        s = sec % 60;
    var pad = function(n) { return (n < 10 ? '0' : '') + n; };
    // Часы:минуты:секунды в формате «24:59» (мин:сек) или «1:24:59» (час:мин:сек);
    // дни выносим отдельно: «2d 1:05:09».
    var out = (h > 0 || d > 0) ? (h + ':' + pad(m) + ':' + pad(s)) : (m + ':' + pad(s));
    if (d > 0) { out = d + 'd ' + out; }
    return out;
}

function formatDateTime(s) {
	if (s.length == 14) {
		return s.replace(/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/, "$1-$2-$3 $4:$5:$6");
	} else if (s.length == 12) {
		return s.replace(/(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/, "$1-$2-$3 $4:$5");
	} else if (s.length == 8) {
		return s.replace(/(\d{4})(\d{2})(\d{2})/, "$1-$2-$3");
	} else if (s.length == 6) {
		return s.replace(/(\d{4})(\d{2})/, "$1-$2");
	}
	return s;
}

function checkOperatorName(t) {
    var w = t.split(" ");
    var f = {};

    for (var i = 0; i < w.length; i++) {
        var wo = w[i].toLowerCase(); 
        if (!f.hasOwnProperty(wo)) {
            f[wo] = i;
        }
    }

    var u = Object.keys(f).map(function(wo) {
        return w[f[wo]];
    });

    var r = u.join(" ");
    return r;
}

return view.extend({


modemDialog: baseclass.extend({
		__init__: function(title, description, callback) {
			this.title       = title;
			this.description = description;
			this.callback    = callback;
		},

		load: function() {
			return uci.load('modemdefine');
		},

		render: function(content) {

			var sections = uci.sections('modemdefine');
			var portM = sections.length;

    			var result = "";
    			for (var i = 1; i < portM; i++) {
       			       	result += sections[i].comm_port + '_' + sections[i].network + '#' + sections[i].comm_port + ' - ' + sections[i].modem + ' (' + sections[i].user_desc + ');';
    			}
			var result = result.slice(0, -1);
			var result = result.replace("(undefined)", "");

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('div', { 'class': 'cbi-section' },
						E('p', {},
							E('div', { 'class': 'cbi-value' }, [
							E('p'),
							E('label', { 'class': 'cbi-value-title' }, [ _('Modem') ]),
							E('div', { 'class': 'cbi-value-field' }, [
								E('select', { 'class': 'cbi-input-select',
										'id': 'mselect',
										'style': 'margin:0px 0; width:100%;',
										},
									(result || "").trim().split(/;/).map(function(cmd) {
										var fields = cmd.split(/#/);
										var name = fields[1];
										var code = fields[0];
									return E('option', { 'value': code }, name ) })

								)
							]) 
						]),
						)
					),
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, this.handleDissmis),
					}, _('Cancel')),

					' ',
					E('button', {
						'id': 'btn_save',
						'class': 'btn cbi-button-positive important',
						'click': ui.createHandlerFn(this, this.handleSave),
					}, _('Save')),

				]),
			]);
		},

		handleSave: function(ev) {

			return uci.load('modemdefine').then(function() {

				var vx = document.getElementById('mselect').value;
				var marr = vx.split('_');

				uci.set('modemdefine', '@general[0]', 'main_modem', marr[0].toString());
				uci.set('modemdefine', '@general[0]', 'main_network', marr[1].toString());


				uci.save();
				uci.apply();

				window.setTimeout(function() {
					if (!poll.active()) poll.start();
					location.reload();
					//ev.target.blur();
				}, 2000).finally();
			});

		},

		handleDissmis: function(ev) {
				ui.hideModal();
				if (!poll.active()) poll.start();
		},

		show: function() {
			ui.showModal(null,
				E('p', { 'class': 'spinning' }, _('Loading'))
			);
			poll.stop();
			this.load().then(content => {
				ui.hideModal();
				return this.render(content);
			}).catch(e => {
				ui.hideModal();
				return this.error(e);
			})
		},
	}),

simDialog: baseclass.extend({
		__init__: function(title, description, callback) {
			this.title       = title;
			this.description = description;
			this.callback    = callback;
		},

		load: function() {
			return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', [ 'json' ]));
		},

		render: function(content) {

			var json = JSON.parse(content);

			if (json) {
				if (!json.imei.length > 2) {
					return false,
					       poll.start()
				}
			}


			// Простая таблица label|значение вместо трёх пар в одном
			// .cbi-value (proton2025 стилизует .cbi-value как flex-строку и
			// сжимал поля в кашу). Значения - выделяемый моноширинный текст.
			var simRow = function(label, val) {
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'style': 'width:35%; white-space:nowrap; padding:8px 12px 8px 0; vertical-align:top; font-weight:600;' }, [ label ]),
					E('td', { 'class': 'td left', 'style': 'padding:8px 0; font-family:monospace; word-break:break-all; user-select:text;' }, [ (val && String(val).length) ? String(val) : '-' ]),
				]);
			};

			// Тип SIM (USIM/eSIM) - строка скрыта и заполняется асинхронно из
			// simslot.sh. Переключатель СЛОТОВ живёт в шапке страницы (над
			// температурой, см. loadSimSlots), здесь его не дублируем.
			var typeRow = E('tr', { 'class': 'tr', 'style': 'display:none' }, [
				E('td', { 'class': 'td left', 'style': 'width:35%; white-space:nowrap; padding:8px 12px 8px 0; vertical-align:top; font-weight:600;' }, [ _('SIM type') ]),
				E('td', { 'class': 'td left', 'style': 'padding:8px 0; font-family:monospace; user-select:text;', 'id': 'simslot-type' }, [ '-' ]),
			]);

			ui.showModal(this.title, [
				E('div', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'cbi-section-descr' }, this.description),
					E('table', { 'class': 'table', 'style': 'width:100%; background:transparent; border:none; box-shadow:none;' }, [
						simRow(_('SIM IMSI'), json.imsi),
						simRow(_('SIM ICCID'), json.iccid),
						simRow(_('Modem IMEI'), json.imei),
						typeRow,
					]),
				]),
				E('div', { 'class': 'right' }, [
					E('button', {
						'class': 'btn',
						'click': ui.createHandlerFn(this, this.handleDissmis),
					}, _('Close')),
				]),
			]);

			L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/simslot.sh', [ 'status' ]), '').then(function(out) {
				var st = {};
				try { st = JSON.parse(out) || {}; } catch (e) { return; }
				if (st.type) {
					var tc = document.getElementById('simslot-type');
					if (tc) { tc.textContent = st.type; typeRow.style.display = ''; }
				}
			});
		},

		handleDissmis: function(ev) {
				ui.hideModal();
				if (!poll.active()) poll.start();
		},

		show: function() {
			ui.showModal(null,
				E('p', { 'class': 'spinning' }, _('Loading'))
			);
			poll.stop();
			this.load().then(content => {
				ui.hideModal();
				return this.render(content);
			}).catch(e => {
				ui.hideModal();
				return this.error(e);
			})
		},
	}),


	formdata: { threeginfo: {} },
	
	/* render-first: НИЧЕГО не ждём перед отрисовкой.
	   Раньше здесь блокировались: modemswitch.sh mmindex (~0.09 c), затем
	   Promise.all(5gmodem.sh json ~0.58 c, mmcli -K, uci, ttl.sh) - и всё это
	   время страница была ПУСТОЙ. Теперь отдаём пустые данные: render() рисует
	   скелет с прочерками сразу, а значения подставляет первый тик poll (он и
	   так опрашивает всё это каждые 5 c). Тяжёлые вызовы никуда не делись - они
	   ушли с критического пути.
	   mmIdx получаем в фоне: он нужен только кнопкам режимов/бендов, а блок
	   частот ленивый (свёрнут по умолчанию) - к его раскрытию индекс уже есть. */
	load: function() {
		L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/modemswitch.sh', [ 'mmindex' ]), '')
			.then(function(idx) { mmIdx = (String(idx || '').trim()) || 'any'; });
		// uci грузим синхронно: из него render() читает настройки TTL.
		return L.resolveDefault(uci.load('5gmodem')).then(function() {
			return [ '{}', '', null, '{}' ];
		});
	},

	render: function(res) {
		modemtabs.attach();  /* theme-agnostic modem switcher bar */
		/* «Приоритет интернета» рисуется ВНУТРИ контента (netpri.mount() ниже),
		   а не вставкой над вкладками - см. mount(). */
		var m, s, o;

		var data = Array.isArray(res) ? res[0] : res;
		var mmK  = Array.isArray(res) ? (res[1] || '') : '';

		// исходный json (для наличия IPv6 и т.п. на этапе построения)
		var initjson = {};
		try { initjson = JSON.parse(data) || {}; } catch (e) {}
		var has6 = (initjson.ipaddr6 != null && String(initjson.ipaddr6).length > 3 && String(initjson.ipaddr6) != '-');
		var ttlv = function(k) { var v = uci.get('5gmodem', '@5gmodem[0]', k); return (v == null) ? '' : v; };

		// системные TTL/hop-limit по умолчанию - подсказка (placeholder) в пустых полях
		var ttlget = {};
		try { ttlget = JSON.parse((Array.isArray(res) ? (res[3] || '') : '') || '{}') || {}; } catch (e) {}
		var def4 = ttlget.def4 || '64';
		var def6 = ttlget.def6 || '64';

		// протокол интерфейса (modemmanager/mbim/qmi/...) - для логики
		// доступности управления бендами
		ifaceProtoIsMM = (String(initjson.protocol || '').toLowerCase() === 'modemmanager');

		// --- Синхронный разбор mmcli -K для строк режима/диапазонов ---
		var mmHasModem = /current-modes/.test(mmK);
		var mmModes = (function() {
			var mm = mmK.match(/current-modes\s*:\s*allowed:\s*([^;]+);\s*preferred:\s*(\S+)/);
			if (!mm) { return null; }
			return {
				allowed: mm[1].split(',').map(function(x) { return x.trim(); }).sort().join('|'),
				pref: (mm[2].trim() == 'none' ? '' : mm[2].trim())
			};
		})();
		var mmSup = [], mmCur = [];
		mmK.split('\n').forEach(function(ln) {
			var b = ln.match(/^modem\.generic\.(supported|current)-bands\.value\[\d+\]\s*:\s*(\S+)/);
			if (b) { (b[1] == 'supported' ? mmSup : mmCur).push(b[2]); }
		});
		// bandsOther: при смене сохраняем только НЕ-управляемые диапазоны (cdma и
		// т.п.); utran теперь управляется своими тумблерами (см. applyBands/loadBands)
		bandsOther = mmCur.filter(function(b) { return b.indexOf('eutran-') != 0 && b.indexOf('ngran-') != 0 && b.indexOf('utran-') != 0; });
		var msStyle = mmHasModem ? null : 'display:none';
		// 3G (UTRAN) row is shown only when the modem actually exposes utran bands
		var has3g = mmHasModem && mmSup.some(function(b) { return b.indexOf('utran-') == 0; });
		var modeActive = function(allowed, preferred) {
			return mmModes &&
			       mmModes.allowed == allowed.split('|').sort().join('|') &&
			       (mmModes.pref || '') == (preferred || '');
		};

		// Управляем бендами через modemband (вендорные AT-команды), если модем
		// НЕ под ModemManager, ЛИБО он под MM, но mmcli не отдаёт для него ни
		// одного бенда (напр. Fibocom FM350 под MM: плагин показывает 0 бендов,
		// зато GTACT работает). Иначе - путь mmcli.
		if (!mmHasModem || !mmSup.length) {
			window.setTimeout(loadBandsModemband, 400);
		}

		active_select();
		window.setTimeout(loadSimSlots, 600);

		var upModemDialog = new this.modemDialog(
			_('Defined modems'),
			_('Interface for selecting user defined modems'),
		);

		var upSIMDialog = new this.simDialog(
			_('SIM card menu'),
			_('Information read from the SIM card and device'),
		);


		if (data != null){
		try {

		var json = JSON.parse(data);

			if(!json.hasOwnProperty('error')){
				
				if (json.registration == 'SIM not inserted' || json.registration == '-') {
					if (ui.addTimeLimitedNotification)
						ui.addTimeLimitedNotification(null, E('p', _('Problem with registering to the network, check the SIM card')), 5000, 'info');
					else
						ui.addNotification(null, E('p', _('Problem with registering to the network, check the SIM card')), 'info');
				}
				if (json.registration == 'SIM PIN required') { 
					ui.addNotification(null, E('p', _('SIM PIN required')), 'info');
				}
				if (json.registration == 'SIM PUK required') { 
					ui.addNotification(null, E('p', _('SIM PUK required')), 'info');
				}
				if (json.registration == 'SIM failure') { 
					ui.addNotification(null, E('p', _('SIM failure')), 'info');
				}
				if (json.registration == 'SIM busy') { 
					ui.addNotification(null, E('p', _('SIM busy')), 'info');
				}
				if (json.registration == 'SIM wrong') { 
					ui.addNotification(null, E('p', _('SIM wrong')), 'info');
				}
				if (json.registration == 'SIM PIN2 required') { 
					ui.addNotification(null, E('p', _('SIM PIN2 required')), 'info');
				}
				if (json.registration == 'SIM PUK2 required') { 
					ui.addNotification(null, E('p', _('SIM PUK2 required')), 'info');
				}
				{
					/* Раньше огромный баннер «модем не найден» + вложенный ниже
					   poll.add висели в else и запускались только если при
					   первой отрисовке уже был сигнал. На загрузке без сигнала
					   опрос вообще не стартовал - страница не обновлялась (не
					   появлялись кнопки диапазонов), пока её не обновишь руками.
					   Теперь опрос стартует всегда, а вместо баннера - краткое
					   самоисчезающее уведомление. */
					if (json.connt == '' || json.connt == '-') {
						if (ui.addTimeLimitedNotification)
							ui.addTimeLimitedNotification(null, E('p', _('Waiting for the modem to connect…')), 4000, 'info');
					}


			pollData: poll.add(function() {
				return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh', 'json'))
					.then(function(res) {
					var json = JSON.parse(res);

				/* ЗДЕСЬ БЫЛ «анти-скачок скролла»: если пользователь у низа страницы,
				   после правок DOM вернуть его к низу (scrollTop = scrollHeight).
				   УДАЛЁН - он и был причиной бага на proton2025, а не лекарством.
				   Замер в браузере (MutationObserver + перехват scrollTop) показал:
				     страница 2538→2538 | блок частот 638→638 | скролл 1228→1786
				   то есть высота НЕ менялась вообще, а прокрутку двигал ровно этот
				   код - определение «был у низа» на proton срабатывало ложно, он
				   швырял страницу вниз, и дальше она уезжала рывками.
				   Причину, ради которой он писался (схлопывание строк при пустом
				   опросе), убрали honestly в setRowVisible: строка, у которой данные
				   уже были, больше не прячется, и высота не скачет. Трогать скролл
				   пользователя нам теперь незачем - пусть этим занимается браузер. */

				// Раньше при signal==0 показывался модал и страница сама
				// перезагружалась каждые 5 c - на модемах, медленно поднимающих
				// сеть, это давало бесконечные перезагрузки. Страница и так
				// открывается с пустыми полями и обновляется по опросу.
				revealMgmtWhenReady();
				// Антенные порты: данные уже в json, лишних запросов нет.
				fillAntPorts(json.antports);

					var icon, wicon, ticon, t;
					var wicon = L.resource('icons/cloading.svg');
					var ticon = L.resource('icons/ctime.svg');
					var dicon = L.resource('icons/cdown.svg');   // скачивание (rx)
					var uicon = L.resource('icons/cup.svg');     // загрузка (tx)

					// Мобильные иконки уровня сигнала (цветные "палочки":
					// красный слабый -> зелёный сильный). Иконки luci
					// signal-*.svg - это WiFi-столбики, для сотовой сети не
					// подходят.
					// json.signal - строка ("-"/""/число); приводим к числу,
					// иначе "-" (нет данных) проваливался в else -> полная
					// зелёная шкала при 0%.
					var p = parseInt(json.signal, 10);
					if (isNaN(p) || p < 0)
						p = 0;
					if (p == 0)
						icon = L.resource('icons/mobile-signal-000-000.svg');
					else if (p < 20)
						icon = L.resource('icons/mobile-signal-000-020.svg');
					else if (p < 40)
						icon = L.resource('icons/mobile-signal-020-040.svg');
					else if (p < 60)
						icon = L.resource('icons/mobile-signal-040-060.svg');
					else if (p < 80)
						icon = L.resource('icons/mobile-signal-060-080.svg');
					else
						icon = L.resource('icons/mobile-signal-080-100.svg');

					if (document.getElementById('signal')) {
						var view = document.getElementById("signal");
						// иконка сверху, проценты под ней
						view.innerHTML = String.format('<img src="%s"/><br/><medium>%d%%</medium>', icon, p);
					}

					if (document.getElementById('connst')) {
						var view = document.getElementById("connst");
						if (json.conn_time == '' || json.conn_time == '-') {
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/>' + ' ' +_('Waiting for connection data...'), wicon, p);
						}
						else {
						view.innerHTML = String.format('<img style="width: 16px; height: 16px; vertical-align: middle;" src="%s"/>', ticon) + ' ' + formatDuration(json.conn_time_sec) + ' | ' + '<img style="width:11px;height:11px;vertical-align:-1px" src="' + dicon + '"/>\u202f' + json.rx + ' <img style="width:11px;height:11px;vertical-align:-1px" src="' + uicon + '"/>\u202f' + json.tx;
						}
					}

					if (document.getElementById('operator')) {
						var view = document.getElementById("operator");
						if (!json.operator_name.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = checkOperatorName(json.operator_name);
						}
						updateSimIcon(json.operator_name);
					}

					// Номер приоритетнее: если он есть - показываем номер и прячем
					// «Страну»; если номера нет - вместо него показываем «Страну».
					var _hasPhone = (json.phone && String(json.phone).length > 3 && json.phone != '-');
					if (document.getElementById('phone')) {
						var pv = document.getElementById('phone');
						if (_hasPhone) {
							pv.textContent = formatPhone(json.phone);
							pv.style.display = '';
						} else {
							pv.style.display = 'none';
						}
					}

					if (document.getElementById('location')) {
						var viewloc = document.getElementById("location");
						var _loc = String(json.location || '');
						if (!_hasPhone && _loc.length > 1 && _loc != '-') {
							viewloc.style.display = '';
							viewloc.textContent = _(_loc);
						} else {
							viewloc.style.display = 'none';
						}
					}

					if (document.getElementById('sim')) {
						var view = document.getElementById("sim");
						var sv = document.getElementById("simv");
						if (json.registration == '') { 
						view.textContent = '-';
						}
						else {
						sv.style.visibility = "visible";
						view.textContent = json.registration;
						if (json.registration == '0') { 
							view.textContent = _('Not registered');
						}
						if (json.registration == '1') { 
							view.textContent = _('Registered');
						}
						if (json.registration == '2') { 
							view.textContent = _('Searching..');
						}
						if (json.registration == '3') { 
							view.textContent = _('Registering denied');
						}
						if (json.registration == '5') {
							// роуминг: показываем как обычную сеть («В сети»), а факт
							// роуминга - иконкой croaming.svg перед текстом.
							view.innerHTML = '<img class="tginfo-roam" src="' + L.resource('icons/croaming.svg') + '" alt="" title="' + _('Roaming') + '">';
							view.appendChild(document.createTextNode(_('Online')));
						}
						if (json.registration == '6') {
							view.textContent = _('Registered, only SMS');
						}
						if (json.registration == '7') {
							view.innerHTML = '<img class="tginfo-roam" src="' + L.resource('icons/croaming.svg') + '" alt="" title="' + _('Roaming') + '">';
							view.appendChild(document.createTextNode(_('Online, only SMS')));
						}
					}
					}

					if (document.getElementById('mode')) {
						var view = document.getElementById("mode");
						var mv = String(json.mode || '').trim();
						if (mv && mv != '-') {
							// валидный режим -> показать (частоты в скобках отдельным span)
							var mtext = mv.replace(/[&<>]/g, function(c) {
								return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c];
							});
							view.innerHTML = mtext.replace(/\(([^)]*)\)/g, '<span class="tginfo-freq">($1)</span>');
						}
						else if (!view.textContent || !view.textContent.trim()) {
							// ещё не было валидного значения -> стабильный placeholder,
							// а НЕ пустая строка (пустой div схлопывался -> шапка меняла
							// высоту и дёргала страницу внизу при флапе модема).
							view.textContent = '-';
						}
						// иначе: пустой/«-» опрос при переподключении модема ИГНОРИРУЕМ и
						// оставляем последнее валидное значение (строка «липкая», высота
						// шапки постоянна -> нет мигания и скачков скролла).
					}

					if (document.getElementById('modemip')) {
						var ip = json.ipaddr || '';
						var row = document.getElementById('modemipn');
						if (ip && ip != '-') {
						document.getElementById('modemip').textContent = ip;
						if (row) row.style.display = '';
						}
						else if (row) {
						row.style.display = 'none';
						}
					}

					if (document.getElementById('modemip6')) {
						var ip6 = json.ipaddr6 || '';
						var row6 = document.getElementById('modemip6n');
						if (ip6 && ip6 != '-') {
						document.getElementById('modemip6').textContent = ip6;
						if (row6) row6.style.display = '';
						}
						else if (row6) {
						row6.style.display = 'none';
						}
					}

					if (document.getElementById('modem')) {
						var view = document.getElementById("modem");
						if (!json.modem.length > 1) {
						view.textContent = '-';
						}
						else {
						view.textContent = json.modem;
						}
					}

					// Заголовок блока = полное имя активного модема (моноширинный)
					if (document.getElementById('modemname')) {
						document.getElementById('modemname').textContent =
							(json.modem && json.modem.length > 1) ? json.modem : _('Modem');
					}

					if (document.getElementById('fw')) {
						var view = document.getElementById("fw");
						if (!json.firmware.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.firmware;
						}
					}

					if (document.getElementById('cport')) {
						var view = document.getElementById("cport");
						if (!json.cport.length > 1) { 
						view.textContent = '-';
						}
						else {
						view.textContent = json.cport;
						}
					}

					if (document.getElementById('protocol')) {
						var view = document.getElementById("protocol");
						if (!json.protocol.length > 1) {
						view.textContent = '-';
						}
						else {
						view.textContent = json.protocol;
						}
					}

					/* Пояснение в «Управление частотами»: показываем реальный
					   протокол интерфейса (mbim/qmi), чтобы было «Управление
					   невозможно в режиме mbim», а не абстрактный текст. */
					if (document.getElementById('bandnote-text') && json.protocol && json.protocol != '-') {
						document.getElementById('bandnote-text').textContent =
							_('Band and network-mode management is not available in %s mode. Switch the interface to ModemManager (in the modem settings) to manage bands.').format(json.protocol);
					}

					if (document.getElementById('temp')) {
						var view = document.getElementById("temp");
						var viewn = document.getElementById("tempn");
						var t = json.mtemp;
						if (t == null || t == '' || t == '-' || (!t.length > 1 && t.includes(' '))) {
						/* Градусов нет. У части прошивок (Compal RXM-G1) их не отдаёт
						   НИ ОДНА AT-команда: единственная тепловая - +CEITHERM, и та
						   даёт уровень троттлинга 0-3. Показываем его словом: выдавать
						   уровень за °C нельзя, но и молчать про перегрев не стоит. */
						var lv = parseInt(json.mtherm, 10);
						if (!isNaN(lv) && lv >= 0 && lv <= 3) {
							var lbl = [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv];
							view.textContent = lbl;
							view.title = _('Modem thermal throttling level: %d of 3').format(lv);
							setRowVisible(view, true);
						} else {
							/* Через setRowVisible, а НЕ display='none' напрямую: при
							   коллизии на AT-порту mtemp и mtherm пустеют разом, строка
							   исчезала и высота страницы прыгала (см. setRowVisible).
							   Строку, где температура уже была, он больше не прячет. */
							setRowVisible(view, false);
						}
						}
						else {
						setRowVisible(view, true);
						/* Значение приходит как "32 &deg;C". Нормализуем к
						   ровно одному градусу: раньше два .replace давали
						   "32 °°C" (первый ставил °, второй добавлял ещё один
						   перед C). Берём число и приписываем " °C". */
						var raw = String(t).replace('&deg;', '°');
						var m = raw.match(/-?\d+(?:\.\d+)?/);
						var txt = m ? (m[0] + ' °C') : raw;
						/* Есть И градусы, И уровень троттлинга (Telit LM960 отдаёт оба:
						   #TEMPSENS=2 -> °C, #TMLVL? -> 0..3) - показываем через запятую.
						   Уровень 0 («норма») не пишем: строка «28 °C, норма» только
						   шумит, а вот «28 °C, перегрев» - важное предупреждение. */
						var lv2 = parseInt(json.mtherm, 10);
						if (!isNaN(lv2) && lv2 >= 1 && lv2 <= 3) {
							txt += ', ' + [ _('Normal'), _('Warm'), _('Hot'), _('Critical') ][lv2];
							view.title = _('Modem thermal throttling level: %d of 3').format(lv2);
						}
						view.textContent = txt;
						}
					}

					if (document.getElementById('csq')) {
						var view = document.getElementById("csq");
						if (json.signal == 0 || json.signal == '-') {
						view.style.visibility = 'hidden';
						}
						else {
						if (json.csq == '') { 
						view.textContent = '-';
						}
						else {
						csq_bar(json.csq, 31);
						}
						}
					}

					if (document.getElementById('rssi')) {
						var view = document.getElementById("rssi");
						if (json.rssi == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rssi;
							if (z.includes('dBm')) { 
							var rssi_min = -110;
							rssi_bar(json.rssi, rssi_min);	
							}
							else {
							var rssi_min = -110;
							rssi_bar(json.rssi + " dBm", rssi_min);
							}
						}
					}

					if (document.getElementById('rsrp')) {
						var view = document.getElementById('rsrp');
						if (json.rsrp == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rsrp;
							if (z.includes('dBm')) { 
							var rsrp_min = -140;
							rsrp_bar(json.rsrp, rsrp_min);

							}
							else {
							var rsrp_min = -140;
							rsrp_bar(json.rsrp + " dBm", rsrp_min);
							}
						}
					}

					if (document.getElementById('sinr')) {
						var view = document.getElementById("sinr");
						if (json.sinr == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.sinr;
							if (z.includes('dB')) { 
							view.textContent = json.sinr;
							}
							else {
							var sinr_min = -21;
							sinr_bar(json.sinr + " dB", sinr_min);
							}
						}
					}

					if (document.getElementById('rsrq')) {
						var view = document.getElementById("rsrq");
						if (json.rsrq == '-') { 
						view.style.visibility = 'hidden';
						}
						else {
							view.style.visibility = 'visible';
							var z = json.rsrq;
							if (z.includes('dB')) { 
							view.textContent = json.rsrq;
							}
							else {
							var rsrq_min = -20;
							rsrq_bar(json.rsrq + " dB", rsrq_min);
							}
						}
					}

					if (document.getElementById('mccmnc')) {
						var view = document.getElementById("mccmnc");
						if (json.operator_mcc == '-' & json.operator_mnc == '-') {
						view.textContent = '-';
						setRowVisible(view, false);
						}
						else {
						setRowVisible(view, true);
						view.textContent = json.operator_mcc + " " + json.operator_mnc;
						}
					}

					if (document.getElementById('lac')) {
						var view = document.getElementById("lac");
						if (json.lac_dec.length < 2 || json.lac_hex.length < 2) {
						/* Через setRowVisible: LAC есть не у всех сетей (в LTE вместо
						   него TAC), но пустой ОДИН опрос - это коллизия на AT-порту,
						   а не пропажа параметра. Раньше строка пряталась сразу и
						   высота страницы прыгала. */
						setRowVisible(view, false);
						}
						else {
							setRowVisible(view, true);
							if (json.lac_dec == '' || json.lac_hex == '') { 
							var lc = json.lac_dec   + ' ' + json.lac_hex;
							var ld = lc.split(' ').join('');
							view.textContent = ld;
							}
							else {
							view.innerHTML = json.lac_dec + ' (' + json.lac_hex + ')';
							}
						}
					}

					if (document.getElementById('tac')) {
						var view = document.getElementById("tac");
						var tac_dh, tac_dec_hex, lac_dec_hex;
							if (json.tac_d.length > 1 || json.tac_h.length > 1) {
							var tac_dh =  json.tac_d + ' (' + json.tac_h + ')';
									view.textContent = tac_dh;
									setRowVisible(view, true);
							}
							else {
								if (json.tac_dec.length > 1 || json.tac_hex.length > 1) {
									var tac_dh =  json.tac_dec + ' (' + json.tac_hex + ')';
									view.textContent = tac_dh;
									setRowVisible(view, true);
								}
								else {
									view.textContent = '-';
									setRowVisible(view, false);
								}
							}
					}

					if (document.getElementById('cid')) {
						var view = document.getElementById("cid");
						var cidText;
						if (json.cid_dec == '' || json.cid_hex == '') {
						cidText = (json.cid_hex + ' ' + json.cid_dec).split(' ').join('');
						}
						else {
						cidText = json.cid_dec + ' (' + json.cid_hex + ')';
						}
						setRowVisible(view, !(cidText === '' || cidText === '-'));
						// Cell ID -> стандартная кнопка с пином и номером соты,
						// по клику открывает карту вышек 4cells.ru
						var url4 = cell4cellsUrl(json);
						if (url4 && json.cid_dec && json.cid_dec != '-') {
							view.innerHTML = '';
							view.appendChild(E('button', {
								'class': 'cbi-button',
								'style': 'margin:0;',
								'title': _('View the tower on the 4cells.ru map'),
								'click': function() { window.open(url4, '_blank', 'noopener'); }
							}, '\u{1F4CD}' + json.cid_dec));
						}
						else {
							view.textContent = cidText;
						}
					}

					if (document.getElementById('pband')) {
						var view = document.getElementById("pband");
						if (json.pband == '-') { 
						view.textContent = '-';
						}
						else {
							if (json.pci.length > 0 && json.pci != '-' && json.earfcn.length > 0 && json.earfcn != '-') { 
								view.textContent = json.pband + ' | ' + json.pci + ' ' + json.earfcn;
							}
							else {
								view.textContent = json.pband;
							}
						}
					}

					/* Строки SCC1..4 в «Информации о соте» убраны — их показывает
					   отдельная CA-таблица ниже (стабильнее, без скачков высоты). */
					/* CA-таблица по компонентам (PCC + активные SCC) */
					renderCaTable(json);
					});
				});	

				}
			}	

		} catch (err) {
				ui.addNotification(null, E('p', _('Error: ') + err.message), 'error');
				}
		}		

		var info = _('').format('');
		m = new form.JSONMap(this.formdata, '', '');

		s = m.section(form.TypedSection, '5gmodem', '', null);
		s.anonymous = true;

		s.render = L.bind(function(view, section_id) {

			return E([], [

			/* «Приоритет интернета» - первым в контенте страницы (под под-вкладками),
			   виден на всех темах и на мобильном. */
			netpri.mount(),

			E('div', { 'class': 'cbi-section tginfo' }, [

			E('div', { 'class': 'right' }, [
				E('button', {
					'id': 'modc',
					'style': 'position:relative; display:none; margin:0 !important; margin-top:-3% !important; left:95%; top:',
 					'disabled': 'true',
					'data-tooltip': _('Modem selection menu'),
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
							return upModemDialog.show();
					}),
				}, _('☰')),
			]),

			E('h3', { 'id': 'modemname', 'style': 'font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;' }, [ _('Modem') ]),

			/* Компактная строка состояния: слева иконка уровня сигнала с
			   процентами, затем иконка SIM, три строки статуса (регистрация /
			   оператор / страна) и температура модема справа. */
			E('div', { 'class': 'tginfo-general' }, [
				E('div', { 'class': 'tginfo-signal', 'id': 'signal' }, [ '-' ]),

				E('span', {
					'title': null,
					'id': 'simv',
					'style': 'visibility: hidden; display:inline-flex; align-items:center; cursor:pointer; vertical-align:middle;',
					'click': ui.createHandlerFn(this, function() {
							return upSIMDialog.show();
					}),
				}, [
					E('div', { 'class': 'cbi-tooltip-container' }, [
						E('img', {
							'id': 'simicon',
							'src': L.resource('icons/op-nosim.png'),
							'title': _(''),
							'class': 'middle',
						}),
						E('span', { 'class': 'cbi-tooltip', 'style': 'text-align:left;font-size:80%' }, SIMdata(data)),
					]),
				]),

				E('div', { 'class': 'tginfo-status' }, [
					E('div', { 'id': 'sim', 'class': 'tginfo-reg' }, [ '-' ]),
					E('div', { 'id': 'operator', 'class': 'tginfo-op' }, [ '-' ]),
					E('div', { 'id': 'phone', 'class': 'tginfo-phone', 'style': 'display:none' }, [ '' ]),
					E('div', { 'id': 'location', 'class': 'tginfo-loc' }, [ '-' ]),
				]),

				/* Параллельная колонка: технология, IP-адрес(а), статистика */
				E('div', { 'class': 'tginfo-info' }, [
					E('div', { 'id': 'mode', 'class': 'tginfo-tech' }, [ '-' ]),
					E('div', { 'class': 'tginfo-ip', 'id': 'modemipn', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-iplabel' }, 'IPv4:'),
						E('span', { 'id': 'modemip' }, [ '' ]),
					]),
					E('div', { 'class': 'tginfo-ip', 'id': 'modemip6n', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-iplabel' }, 'IPv6:'),
						E('span', { 'id': 'modemip6' }, [ '' ]),
					]),
					E('div', { 'id': 'connst', 'class': 'tginfo-conn' }, [ '-' ]),
				]),

				/* Правая колонка: переключатель SIM-слотов (если их >= 2) НАД
				   температурой. Заполняется асинхронно из simslot.sh. */
				E('div', { 'class': 'tginfo-right' }, [
					E('div', { 'class': 'tginfo-simslot', 'id': 'simslotn', 'style': 'display:none' }, [ '' ]),
					E('div', { 'class': 'tginfo-temp', 'id': 'tempn', 'style': 'display:none' }, [
						E('span', { 'class': 'tginfo-thermo', 'title': _('Modem temperature') }, [
							E('img', { 'src': L.resource('icons/ctemp.svg'), 'width': '16', 'height': '16', 'alt': _('Modem temperature') })
						]),
						E('span', { 'id': 'temp' }, [ '-' ]),
					]),
				]),
			]),
			]),

			/* Второй блок - управление частотами (сворачиваемый) */
			collapsibleSection('freq', _('Frequency management'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr', 'id': 'modeswn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Network mode')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'modesw-btns' },
						/* Комбинации только из supported-списка этой прошивки:
						   чистых "4g"/"4g,5g" она не умеет - всегда с 2g/3g. */
						[
							[ _('Auto'), '2g|3g|4g|5g', '5g' ],
							[ '2G', '2g', '' ],
							[ '3G', '3g', '' ],
							[ '4G', '3g|4g', '4g' ],
							[ '4G+5G', '3g|4g|5g', '5g' ],
							[ '5G', '3g|5g', '5g' ]
						].map(L.bind(function(mdef) {
							return E('button', {
								'class': 'btn cbi-button' + (modeActive(mdef[1], mdef[2]) ? ' cbi-button-action important' : ''),
								'data-allowed': mdef[1],
								'data-preferred': mdef[2],
								'click': ui.createHandlerFn(this, function() {
									return setNetMode(mdef[1], mdef[2], mdef[0]);
								})
							}, mdef[0]);
						}, this))
					),
					]),
				E('tr', { 'class': 'tr', 'id': 'bands3gn', 'style': has3g ? msStyle : 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('3G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-3g' },
						mmHasModem ? buildBandButtons(mmSup, mmCur, 'utran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('LTE bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-lte' },
						mmHasModem ? buildBandButtons(mmSup, mmCur, 'eutran-') : [ '-' ]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bands5gn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('5G bands')]),
					E('td', { 'class': 'td left tginfo-modesw', 'id': 'bands-nr' },
						mmHasModem ? buildBandButtons(mmSup, mmCur, 'ngran-') : [ '-' ]),
					]),
				/* Постоянная подсказка над «Применить» для модемов, у которых смена
				   диапазонов кратко разрывает соединение (FM350: GTACT рвёт PDP,
				   proto переподнимает - IP пропадает на ~15-20 c). Флаг bandwarn
				   приходит из bands.sh (задан в профиле _fibocom_fm350_common);
				   строку показывает loadBandsModemband(). */
				E('tr', { 'class': 'tr', 'id': 'bandwarnn', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('div', { 'class': 'cbi-value-description' }, _('Changing bands briefly drops the connection: the IP disappears for ~15–20 seconds and comes back automatically. This is normal for this modem.'))
					]),
					]),
				E('tr', { 'class': 'tr', 'id': 'bandsactn', 'style': msStyle }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ '' ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'click': ui.createHandlerFn(this, function() { return applyBands(); })
						}, _('Apply')),
						' ',
						E('button', {
							'class': 'btn cbi-button',
							'data-tooltip': _('Enable all supported bands'),
							'click': ui.createHandlerFn(this, function() { return resetBands(); })
						}, _('All bands'))
					]),
					]),
				/* Пояснение, когда управление диапазонами недоступно (напр.
				   Compal RXM-G1 в режиме umbim/uqmi: у прошивки нет AT-команд
				   бенд-лока, а mmcli выключен). Показывается из
				   loadBandsModemband(), когда ни mmcli, ни modemband не дали
				   списка бендов. */
				E('tr', { 'class': 'tr', 'id': 'bandnote', 'style': 'display:none' }, [
					E('td', { 'class': 'td left', 'colspan': '2' }, [
						E('em', { 'id': 'bandnote-text', 'style': 'opacity:.8' }, _('Band and network-mode switching is unavailable for this modem in the current interface mode. Switch the interface to ModemManager (in the modem settings) to manage bands.'))
					]),
					]),
				/* Перезагрузка модема - доступна ВСЕГДА (и в mbim, и в
				   modemmanager), независимо от доступности управления бендами. */
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Restart modem') ]),
					E('td', { 'class': 'td left tginfo-modesw' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'data-tooltip': _('Radio restart (CFUN=4→1): quickly re-registers on the network without re-enumerating USB. Try this first.'),
							'click': ui.createHandlerFn(this, function() { return rebootModem(false); })
						}, _('Restart radio')),
						' ',
						E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'data-tooltip': _('Full restart (CFUN=1,1): the modem reboots and re-enumerates on USB. Slower, connection drops ~1 min; use when the radio restart did not help.'),
							'click': ui.createHandlerFn(this, function() { return rebootModem(true); })
						}, _('Full restart')),
						' ',
						/* Аппаратная перезагрузка по питанию - только на платах с GPIO
						   питания модема (WH3000 Pro и т.п.). Скрыта, показывается из
						   initPowerBtn() после проверки reboot_modem.sh haspower. */
						E('button', {
							'id': 'btn-power-reboot',
							'class': 'btn cbi-button cbi-button-negative',
							'style': 'display:none',
							'data-tooltip': _('Cuts power to the modem slot for a few seconds - as if you unplugged it. The modem comes back in ~1 min. Use when a full restart did not help.'),
							'click': ui.createHandlerFn(this, function() { return rebootModemPower(); })
						}, _('Power restart'))
					]),
					]),
			]),
			]),

			/* Блок фиксации TTL / hop-limit - на такой же плашке (collapsibleSection),
			   как остальные блоки страницы; по умолчанию свёрнут. */
			collapsibleSection('ttl', _('TTL fixing'), [
				(function() {
					var mkin = function(id, ph) { return E('input', { 'id': id, 'class': 'cbi-input-text', 'type': 'text', 'inputmode': 'numeric', 'maxlength': '3', 'style': 'width:3.5em;text-align:center', 'placeholder': ph, 'value': ttlv(id) }); };
					return E('div', { 'style': 'display:flex;flex-wrap:wrap;align-items:center;gap:.35em .9em;padding:.2em 0' }, [
						E('span', { 'style': 'display:inline-flex;align-items:center;gap:.35em' }, [
							E('span', { 'style': 'opacity:.8' }, _('TTL IPv4 (in / out)')),
							mkin('ttl4in', def4), ' / ', mkin('ttl4out', def4)
						]),
						has6 ? E('span', { 'style': 'display:inline-flex;align-items:center;gap:.35em' }, [
							E('span', { 'style': 'opacity:.8' }, _('Hop Limit IPv6 (in / out)')),
							mkin('ttl6in', def6), ' / ', mkin('ttl6out', def6)
						]) : '',
						E('button', {
							'class': 'btn cbi-button cbi-button-action important',
							'style': 'white-space:nowrap',
							'click': ui.createHandlerFn(this, function() { return applyTTL(has6); })
						}, _('Apply'))
					]);
				}).call(this)
			]),

			collapsibleSection('cell', _('Cell / Signal Information'), [
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('MCC MNC')]),
					E('td', { 'class': 'td left', 'id': 'mccmnc' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Cell ID')]),
					E('td', { 'class': 'td left', 'id': 'cid' }, [ '-' ]),
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('TAC')]),
					E('td', { 'class': 'td left', 'id': 'tac' }, [ '-' ]),
					]),
				E('tr', { 'id': 'lacn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('LAC')]),
					E('td', { 'class': 'td left', 'id': 'lac' }, [ '-' ]),
					]),

				E('tr', { 'id': 'csqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('CSQ'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Signal Strength)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'csq',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rssin', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSSI'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Received Signal Strength Indicator)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rssi',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rsrpn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSRP'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Reference Signal Receive Power)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rsrp',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'sinrn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('SINR'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Signal to Interference plus Noise Ratio)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'sinr',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'id': 'rsrqn', 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [
					_('RSRQ'),
					E('div', { 'style': 'text-align:left;font-size:66%' }, [ _('(Reference Signal Received Quality)') ]),
					]),
					E('td', { 'class': 'td' }, E('div', {
							'id': 'rsrq',
							'class': 'cbi-progressbar',
							'title': '-'
							}, E('div')
						))
					]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, [ _('Primary band (PCC) | PCI & EARFCN')]),
					E('td', { 'class': 'td left', 'id': 'pband' }, [ '-' ]),
					]),
				// Строки «Диапазон CA (SCC1..4)» убраны намеренно: их полностью и
				// стабильнее показывает отдельная CA-таблица ниже (#ca-table).
				// Раньше эти строки появлялись/прятались при (де)агрегации и меняли
				// высоту страницы -> при просмотре снизу её дёргало вверх.

				]),
				/* Детали агрегации несущих (CA) - в ТОМ ЖЕ сворачиваемом блоке, что и
				   метрики. Обёртка #ca-comp прячется, когда нет подключения (см.
				   renderCaTable), скрывая только CA-таблицу внутри блока. */
				E('div', { 'id': 'ca-comp', 'style': 'display:none;margin-top:.6em' }, [
					E('h4', { 'style': 'margin:.2em 0 .4em 0' }, _('Carrier aggregation (per component)')),
					E('table', { 'class': 'table', 'id': 'ca-table' }, [
					E('tr', { 'class': 'tr table-titles ca-head' }, [
						E('th', { 'class': 'th left' }, [ 'CC' ]),
						E('th', { 'class': 'th left' }, [ 'Band' ]),
						E('th', { 'class': 'th' }, [ 'BW' ]),
						E('th', { 'class': 'th' }, [ 'PCI' ]),
						E('th', { 'class': 'th' }, [ 'EARFCN' ]),
						E('th', { 'class': 'th' }, [ 'RSRP' ]),
						E('th', { 'class': 'th' }, [ 'RSRQ' ]),
						E('th', { 'class': 'th' }, [ 'SINR' ]),
						E('th', { 'class': 'th' }, [ 'MIMO' ]),
						E('th', { 'class': 'th' }, [ 'Mod' ]),
					]),
				].concat([ 'PCC', 'SCC1', 'SCC2', 'SCC3', 'SCC4' ].map(function(cc) {
					// Строки рисуются ЗАРАНЕЕ и с прочерками, а опрос лишь заполняет
					// ячейки. Строки НИКОГДА не добавляются/не удаляются, поэтому
					// высота таблицы постоянна и страницу внизу не дёргает при
					// переселении соты (единичная <-> агрегация). Как в 3ginfo-lite.
					// data-l: подпись колонки для мобильной «карточной» раскладки
					// (в @media узкого экрана показывается через ::before).
					return E('tr', { 'class': 'tr ca-row', 'data-cc': cc }, [
						E('td', { 'class': 'td left ca-cc' }, [ cc ]),
						E('td', { 'class': 'td left', 'data-l': 'Band' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'BW' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'PCI' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'EARFCN' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRP' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'RSRQ' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'SINR' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'MIMO' }, [ '-' ]),
						E('td', { 'class': 'td', 'data-l': 'Mod' }, [ '-' ]),
					]);
				})))
				])
			]),

			/* Сигнал по антенным портам (AT#LAPS у Telit). Есть не у всех модемов:
			   блок скрыт и показывается из fillAntPorts() только когда модем
			   реально отдал данные (поле antports в опросе метрик). */
			E('div', { 'id': 'antports-block', 'style': 'display:none' }, [
				collapsibleSection('ant', _('Antenna ports'), [
					E('table', { 'class': 'table', 'id': 'antports-table' }, []),
					E('div', { 'style': 'font-size:85%;opacity:.75;padding:.4em 0 0 0' },
						_('RSRP/RSRQ measured separately on each LTE antenna port. A port with RSRP near -140 dBm has no antenna connected (or the cable is bad). LTE only: in 3G the table stays empty.'))
				])
			])
		]);
		}, o, this);

		return m.render().then(function(node) {
			// после вставки DOM показать кнопку перезагрузки по питанию, если у
			// платы есть соответствующий GPIO (setTimeout - дать LuCI прикрепить узел)
			window.setTimeout(initPowerBtn, 0);
			return node;
		});
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
