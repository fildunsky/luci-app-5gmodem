'use strict';
'require view';
'require fs';

/* Вкладка «Дашборд»: WYSIWYG-конструктор карточек метрик модема (порт страницы
   /5g в LuCI-view). Внутри LuCI страница за админ-сессией - никакого открытого
   CGI: данные тянем через fs.exec(5gmodem.sh cached / listmodems.sh). Раскладка
   хранится в localStorage браузера (клиентская, как и было). Весь CSS заскоуплен
   под .dashx, чтобы не конфликтовать с классами фреймворка; доступ к элементам -
   через корень вью, а не document. Тему (свет/тьма) даёт LuCI (data-theme на html),
   свой переключатель темы/акцента из /5g тут не нужен. */

var CSS = '\
.dashx{--accent:var(--proton-accent,var(--primary-color-medium,#0095ff));--accent-rgb:var(--proton-accent-rgb,var(--focus-color-rgb,0,149,255));--accent-glow:var(--proton-accent-glow,rgba(var(--focus-color-rgb,0,149,255),.15));\
 --ok:var(--proton-success,var(--success-color-medium,#2ea043));--warn:var(--proton-warning,var(--warn-color-medium,#f5a623));--crit:var(--proton-danger,var(--error-color-medium,#e5484d));\
 --radius:var(--proton-radius,10px);--radius-sm:var(--proton-radius-sm,7px);--gap:12px;--cell:150px;--rowh:104px;\
 --mono:var(--font-mono,ui-monospace,SFMono-Regular,Menlo,Consolas,monospace);--font:var(--font-sans,Inter,system-ui,-apple-system,Segoe UI,Roboto,sans-serif);\
 --bg:var(--proton-bg-solid,var(--background-color-high,#0d1017));--bg2:var(--proton-bg-secondary,var(--background-color-medium,#141922));--bg3:var(--proton-bg-tertiary,var(--background-color-low,#1b2230));--card:var(--proton-card-solid,var(--background-color-high,#151b26));--hover:var(--proton-bg-hover,var(--background-color-medium,#1e2634));\
 --fg:var(--proton-fg,var(--text-color-high,#e7ecf3));--fg2:var(--proton-fg-secondary,var(--text-color-medium,#aeb7c6));--muted:var(--proton-muted,var(--text-color-low,#6b7688));--border:var(--proton-border,var(--border-color-medium,#243040));--shadow:var(--proton-shadow,0 2px 8px rgba(0,0,0,.16));\
 color:var(--fg);font:400 15px/1.4 var(--font)}\
.dashx *{box-sizing:border-box}\
.dashx .cbi-button{font:inherit;line-height:inherit;white-space:normal;box-shadow:none}\
.dashx .cbi-button+.cbi-button{margin-left:0}\
.dashx .top{display:flex;align-items:center;gap:14px;padding:2px 2px 14px;border-bottom:1px solid var(--border);margin-bottom:16px}\
.dashx .top h1{font:700 1.05rem var(--font);margin:0;letter-spacing:-.01em;flex:0 0 auto}\
.dashx .top .sub{color:var(--muted);font-size:.8rem;font-family:var(--mono)}\
.dashx .top .sp{flex:1}\
.dashx .btn{display:inline-flex;align-items:center;gap:7px;padding:8px 14px;border-radius:var(--radius-sm);border:1px solid var(--border);background:var(--bg3);color:var(--fg);font:600 .85rem var(--font);cursor:pointer;transition:.18s}\
.dashx .btn:hover{border-color:var(--accent);background:var(--hover)}\
.dashx .btn.on{background:var(--accent-glow);color:var(--accent);border-color:rgba(var(--accent-rgb),.45)}\
.dashx .studio{display:grid;grid-template-columns:340px 1fr;gap:18px;align-items:stretch}\
@media(max-width:900px){.dashx .studio{grid-template-columns:1fr}}\
.dashx .panel.dash{display:flex;flex-direction:column}\
.dashx .panel.dash>.pbody{flex:1;display:flex;flex-direction:column;min-height:0}\
.dashx .panel.dash .canvas{flex:1}\
.dashx .panel{background:var(--card);border:1px solid var(--border);border-radius:var(--radius);box-shadow:var(--shadow);overflow:hidden}\
.dashx .phead{display:flex;align-items:center;gap:9px;padding:13px 16px;border-bottom:1px solid var(--border);font:600 .95rem var(--font)}\
.dashx .phead .badge{margin-left:auto;font:600 .66rem var(--mono);color:var(--accent);background:var(--accent-glow);padding:3px 8px;border-radius:6px}\
.dashx .pbody{padding:14px 16px}\
.dashx .search{width:100%;background:var(--bg3);border:1px solid var(--border);border-radius:var(--radius-sm);padding:9px 12px;color:var(--fg);font:500 .85rem var(--font);margin-bottom:12px}\
.dashx .search:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}\
.dashx .cat{font:600 .64rem var(--font);letter-spacing:.1em;text-transform:uppercase;color:var(--muted);margin:14px 0 7px}\
.dashx .cat:first-child{margin-top:0}\
.dashx .pick{display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--border);border-radius:var(--radius-sm);background:var(--bg3);margin-bottom:6px;transition:.15s}\
.dashx .pick:hover{border-color:rgba(var(--accent-rgb),.4);background:var(--hover)}\
.dashx .pick .pi{font-size:1rem;width:20px;text-align:center;flex:0 0 auto}\
.dashx .pick .pn{flex:1;min-width:0;font:600 .84rem var(--font);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .pick .pv{font:600 .72rem var(--mono);color:var(--muted);flex:0 0 auto;max-width:90px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .pick .padd{flex:0 0 auto;width:26px;height:26px;border-radius:7px;border:1px solid var(--border);background:transparent;color:var(--fg2);font-size:1.1rem;line-height:1;cursor:pointer;transition:.15s}\
.dashx .pick .padd:hover{border-color:var(--accent);color:var(--accent)}\
.dashx .pick .padd.in{background:var(--accent);border-color:var(--accent);color:#fff}\
.dashx .canvas{background:radial-gradient(circle at 15% 10%,rgba(var(--accent-rgb),.05),transparent 45%),var(--bg2);border:1px solid var(--border);border-radius:var(--radius);padding:16px;min-height:340px}\
.dashx .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--cell),1fr));grid-auto-rows:var(--rowh);gap:var(--gap)}\
.dashx .grid.empty{display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:.9rem;min-height:280px}\
.dashx .w{position:relative;border-radius:var(--radius);padding:13px 15px;display:flex;flex-direction:column;overflow:hidden;color:var(--fg);text-align:left;transition:transform .18s,box-shadow .18s,border-color .18s;cursor:pointer}\
.dashx .w:hover{transform:translateY(-2px);box-shadow:var(--shadow)}\
.dashx .w.sel{border-color:var(--accent);box-shadow:0 0 0 3px var(--accent-glow)}\
.dashx .w[data-size="w"]{grid-column:span 2}\
.dashx .w[data-size="t"]{grid-row:span 2}\
.dashx .w[data-size="l"]{grid-column:span 2;grid-row:span 2}\
.dashx .w .whead{display:flex;align-items:center;gap:7px;color:var(--muted);font:600 .66rem var(--font);letter-spacing:.06em;text-transform:uppercase}\
.dashx .w .whead .wic{font-size:.95rem}\
.dashx .w .wval{margin-top:auto;font:700 clamp(1.4rem,4vw,2.1rem) var(--font);font-variant-numeric:tabular-nums;letter-spacing:-.02em;line-height:1.05;color:var(--fg);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .w .wval.mid{font-size:clamp(.95rem,2.4vw,1.3rem);white-space:normal;overflow:hidden;text-overflow:clip;overflow-wrap:anywhere;line-height:1.18;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}\
.dashx .w .wval.small{font-size:.9rem;font-weight:600;white-space:normal;overflow:hidden;text-overflow:clip;overflow-wrap:anywhere;line-height:1.25;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical}\
.dashx .w[data-size="w"] .wval.small,.dashx .w[data-size="l"] .wval.small{font-size:1rem}\
.dashx .w .wunit{font-size:.55em;font-weight:600;color:var(--fg2);margin-left:3px}\
.dashx .w .wsub{margin-top:5px;font:500 .74rem var(--mono);color:var(--fg2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .w[data-level="warn"] .wval{color:var(--warn)}.dashx .w[data-level="crit"] .wval{color:var(--crit)}.dashx .w[data-level="ok"] .wval{color:var(--ok)}\
.dashx .w .bar{margin-top:9px;height:6px;border-radius:99px;background:var(--bg3);overflow:hidden}\
.dashx .w .bar>i{display:block;height:100%;border-radius:99px;background:var(--accent);transition:width .5s ease}\
.dashx .w[data-level="warn"] .bar>i{background:var(--warn)}.dashx .w[data-level="crit"] .bar>i{background:var(--crit)}.dashx .w[data-level="ok"] .bar>i{background:var(--ok)}\
.dashx .w .wx{position:absolute;top:6px;right:6px;width:22px;height:22px;border-radius:6px;border:0;background:var(--bg3);color:var(--muted);font-size:.9rem;line-height:1;cursor:pointer;opacity:0;transition:.15s}\
.dashx .w:hover .wx{opacity:1}\
.dashx .w .wx:hover{background:var(--crit);color:#fff}\
.dashx .w.modemcard,.dashx .w.panelcard{grid-column:1/-1;overflow:hidden;cursor:default;align-self:start}\
.dashx.edit-on .w.modemcard,.dashx.edit-on .w.panelcard{cursor:grab}\
.dashx .w .mc-head{text-transform:none;color:var(--fg);gap:8px}\
.dashx .w .mc-head .mc-headic{width:18px;height:18px;flex:0 0 auto}\
.dashx .w .mc-head .mc-name{font-family:var(--mono);font-weight:700;font-size:.92rem;letter-spacing:.3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .w.modemcard .mc-grid{margin-top:9px;display:grid;grid-template-columns:repeat(auto-fill,minmax(74px,1fr));grid-auto-rows:40px;gap:8px}\
.dashx .mc-item{position:relative;border-radius:8px;padding:7px 9px;min-width:0;overflow:hidden;display:flex;flex-direction:column;grid-column:span 2;grid-row:span 2;line-height:1.3;text-align:left}\
.dashx .mc-item[data-sz="h"]{justify-content:center;padding-top:4px;padding-bottom:4px}\
.dashx .mc-item[data-sz="h"] .mc-lbl{display:none}\
.dashx .mc-item[data-sz="h"] .mc-val,.dashx .mc-item[data-sz="h"] .mc-chip,.dashx .mc-item[data-sz="h"] .mc-badge,.dashx .mc-item[data-sz="h"] .mc-op,.dashx .mc-item[data-sz="h"] .mc-gc,.dashx .mc-item[data-sz="h"] .mc-traf,.dashx .mc-item[data-sz="h"] .bar{margin-top:0}\
.dashx .mc-item .mc-lbl{font:600 .56rem var(--font);letter-spacing:.04em;text-transform:uppercase;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .mc-item .mc-val{margin-top:auto;font:700 .95rem var(--font);font-variant-numeric:tabular-nums;color:var(--fg);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .mc-item[data-sz="q"] .mc-val{font-size:.82rem}\
.dashx .mc-item[data-sz="b"] .mc-val{font-size:1.6rem}\
.dashx .mc-item .mc-val.mid{font-size:.8rem;font-weight:700}\
.dashx .mc-item .mc-val.small{font-size:.68rem;font-weight:600}\
.dashx .mc-item .mc-val.mid,.dashx .mc-item .mc-val.small{white-space:normal;overflow-wrap:anywhere;line-height:1.16;text-overflow:clip;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}\
.dashx .mc-item[data-sz="q"] .mc-val.mid,.dashx .mc-item[data-sz="q"] .mc-val.small{-webkit-line-clamp:3;font-size:.62rem}\
.dashx .mc-item[data-sz="b"] .mc-val.mid,.dashx .mc-item[data-sz="b"] .mc-val.small{font-size:1.05rem;-webkit-line-clamp:4}\
.dashx .mc-item[data-sz="w"] .mc-val.mid,.dashx .mc-item[data-sz="w"] .mc-val.small{font-size:.9rem}\
.dashx .mc-item .mc-val .u{font-size:.65em;color:var(--fg2);font-weight:600;margin-left:2px}\
.dashx .mc-item .bar{margin-top:6px;height:5px;border-radius:99px;background:var(--card);overflow:hidden}\
.dashx .mc-item .bar>i{display:block;height:100%;border-radius:99px;background:var(--accent)}\
.dashx .mc-item[data-level="ok"] .mc-val{color:var(--ok)}.dashx .mc-item[data-level="warn"] .mc-val{color:var(--warn)}.dashx .mc-item[data-level="crit"] .mc-val{color:var(--crit)}\
.dashx .mc-item .mc-badge{align-self:flex-start;margin-top:auto;padding:2px 10px;border-radius:99px;font:700 .82rem var(--font);background:var(--accent-glow);color:var(--accent)}\
.dashx .mc-item .mc-chip{align-self:flex-start;margin-top:auto;max-width:100%;display:inline-flex;align-items:center;gap:4px;font-family:var(--mono);font-size:.74rem;font-weight:600;border:1px solid rgba(128,128,128,.35);background:rgba(128,128,128,.12);border-radius:6px;padding:2px 8px;color:var(--fg);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .mc-item .mc-chip img{width:11px;height:11px;opacity:.8;flex:0 0 auto}\
.dashx.edit-on .w.modemcard .mc-item{cursor:grab}\
.dashx .mc-item.mc-drag{opacity:.4}\
.dashx .mc-item.mc-over{outline:2px dashed var(--accent);outline-offset:-2px;background:var(--hover)}\
.dashx .mc-item .mc-rm{position:absolute;top:3px;right:3px;width:17px;height:17px;border-radius:5px;border:0;background:var(--card);color:var(--muted);font-size:.66rem;line-height:1;cursor:pointer;padding:0;display:none;z-index:4;box-shadow:0 0 0 1px var(--border)}\
.dashx .mc-item .mc-rz{position:absolute;right:0;bottom:0;width:16px;height:16px;cursor:nwse-resize;display:none;z-index:4;touch-action:none}\
.dashx .mc-item .mc-rz::after{content:"";position:absolute;right:3px;bottom:3px;width:7px;height:7px;border-right:2px solid var(--accent);border-bottom:2px solid var(--accent);border-bottom-right-radius:2px}\
.dashx.edit-on .w.modemcard .mc-item.mc-sel{outline:2px solid var(--accent);outline-offset:-2px;z-index:2}\
.dashx.edit-on .w.modemcard .mc-item.mc-sel .mc-rm{display:block}\
.dashx.edit-on .w.modemcard .mc-item.mc-sel .mc-rz{display:block}\
.dashx.edit-on .w.modemcard .mc-item.mc-sel .mc-lbl{padding-right:17px}\
.dashx .mc-item .mc-rm:hover{background:var(--crit);color:#fff;box-shadow:none}\
.dashx .mc-op{display:flex;align-items:center;gap:8px;margin-top:auto;min-width:0}\
.dashx .mc-op .opn{font:700 .88rem var(--font);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .mc-op .mc-opic{width:22px;height:22px;flex:0 0 auto;border-radius:5px;object-fit:contain}\
.dashx .mc-op.only-ic{justify-content:center}\
.dashx .mc-op.only-ic .mc-opic{width:30px;height:30px}\
.dashx .mc-gc{display:flex;align-items:center;gap:7px;margin-top:auto;min-width:0}\
.dashx .mc-gc svg{flex:0 0 auto}\
.dashx .mc-gc .mc-gv{font:700 .9rem var(--font);font-variant-numeric:tabular-nums;color:var(--fg);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .mc-gc .mc-sigic{width:28px;height:26px;flex:0 0 auto}\
.dashx .mc-traf{display:flex;flex-direction:column;gap:2px;margin-top:auto}\
.dashx .mc-traf .tr{display:flex;align-items:center;gap:5px;font:700 .8rem var(--mono)}\
.dashx .mc-traf .tr svg{width:12px;height:12px;flex:0 0 auto}\
.dashx .mc-traf .tr.rx{color:var(--ok)}.dashx .mc-traf .tr.tx{color:var(--accent)}\
.dashx .mc-traf .tr .tv{color:var(--fg)}\
.dashx .mc-gauge{margin-top:auto;display:flex;align-items:center;gap:9px}\
.dashx .mc-gauge svg{flex:0 0 auto}\
.dashx .mc-gauge .gv{font:700 1.02rem var(--font);font-variant-numeric:tabular-nums}\
.dashx .mc-gauge .gv small{font-size:.6em;color:var(--fg2)}\
.dashx .w.panelcard .pn-grid{margin-top:11px;display:flex;flex-wrap:wrap;gap:11px}\
.dashx .pn-row.lbar{flex:1 1 100%}\
.dashx .pn-lbl{font:600 .7rem var(--font);letter-spacing:.05em;text-transform:uppercase;color:var(--fg2)}\
.dashx .pn-v{font:700 1.05rem var(--font);font-variant-numeric:tabular-nums}\
.dashx .pn-v .u{font-size:.62em;color:var(--muted);font-weight:600;margin-left:2px}\
.dashx .pn-row.lbar .pn-top{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:5px}\
.dashx .pn-bar{height:12px;border-radius:99px;background:var(--bg3);overflow:hidden}\
.dashx .pn-bar>i{display:block;height:100%;border-radius:99px;background:var(--accent);transition:width .5s ease}\
.dashx .pn-row[data-level="ok"] .pn-v,.dashx .pn-row[data-level="ok"] .pn-num{color:var(--ok)}.dashx .pn-row[data-level="warn"] .pn-v,.dashx .pn-row[data-level="warn"] .pn-num{color:var(--warn)}.dashx .pn-row[data-level="crit"] .pn-v,.dashx .pn-row[data-level="crit"] .pn-num{color:var(--crit)}\
.dashx .pn-row.gauge{flex:1 1 158px;min-width:0;display:flex;align-items:center;gap:12px;background:var(--bg3);border:1px solid var(--border);border-radius:11px;padding:9px 12px}\
.dashx .pn-row.gauge .mc-gauge{gap:0}.dashx .pn-row.gauge .mc-gauge .gv{display:none}\
.dashx .pn-row.gauge .pn-gl{display:flex;flex-direction:column;gap:2px;min-width:0}\
.dashx .pn-row.gauge .pn-v{font-size:1.25rem}\
.dashx .pn-row.num{flex:1 1 150px;min-width:0;display:flex;flex-direction:column;justify-content:center;gap:3px;background:var(--bg3);border:1px solid var(--border);border-radius:11px;padding:9px 12px}\
.dashx .pn-row.num .pn-num{font:800 1.5rem var(--font);font-variant-numeric:tabular-nums;letter-spacing:-.02em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .pn-row.num .pn-num.long{font-size:1.02rem;font-weight:700;white-space:normal;overflow-wrap:anywhere;line-height:1.2}\
.dashx .fld .frm{width:20px;height:20px;flex:0 0 auto;border:0;background:transparent;color:var(--muted);cursor:pointer;font-size:.8rem;line-height:1;border-radius:5px}\
.dashx .fld .frm:hover{background:var(--crit);color:#fff}\
.dashx .flds{max-height:52vh;overflow:auto;margin-top:4px}\
.dashx .fld{display:flex;align-items:center;gap:7px;padding:6px 8px;border:1px solid var(--border);border-radius:8px;background:var(--bg3);margin-bottom:6px}\
.dashx .fld.off{opacity:.5}\
.dashx .fld .fmv{display:flex;flex-direction:column}\
.dashx .fld .fmv button{width:18px;height:13px;border:0;background:transparent;color:var(--muted);cursor:pointer;font-size:.62rem;line-height:1;padding:0}\
.dashx .fld .fmv button:hover{color:var(--accent)}\
.dashx .fld .fn{flex:1;min-width:0;font:600 .8rem var(--font);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}\
.dashx .fld select{width:auto;padding:4px 20px 4px 7px;font-size:.72rem;margin:0}\
.dashx.edit-on .w{cursor:grab}.dashx.edit-on .w:active{cursor:grabbing}\
.dashx .w.dragging{opacity:.4;transform:scale(.97)}\
.dashx .w.dragover{border-color:var(--accent);box-shadow:inset 0 0 0 2px var(--accent),0 0 0 3px var(--accent-glow)}\
.dashx.edit-off .w{cursor:default}.dashx.edit-off .w:hover{transform:none;box-shadow:none}\
.dashx.edit-off .wx{display:none}\
.dashx.edit-off .w.sel{box-shadow:none;border-color:var(--border)}\
.dashx .setrow{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:9px 0;border-bottom:1px solid var(--border)}\
.dashx .setrow:last-child{border-bottom:0}\
.dashx .setrow label{font:600 .8rem var(--font)}\
.dashx .sizes{display:flex;gap:6px}\
.dashx .szb{width:34px;height:30px;border-radius:7px;border:1px solid var(--border);background:var(--bg3);color:var(--fg2);cursor:pointer;font:700 .7rem var(--mono)}\
.dashx .szb.on{background:var(--accent);border-color:var(--accent);color:#fff}\
.dashx .muted{color:var(--muted);font-size:.82rem}\
';

/* КАТАЛОГ МЕТРИК (те же поля, что и на странице модема). key = поле из
   5gmodem.sh json; g=группа; u=единица; ic=иконка; lv(v)=уровень; bar(v)=0..100; f(v)=формат. */
function cl(v,a,b){v=Math.round(v);return v<a?a:v>b?b:v;}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
var IC='/luci-static/resources/icons/5gmodem/';
var C = {
  signal:{n:'Сигнал',g:'Сигнал',u:'%',ic:'📶',bar:function(v){return cl(+v,0,100);},lv:function(v){return v>=60?'ok':v>=30?'warn':'crit';}},
  rsrp:{n:'RSRP',g:'Сигнал',u:'dBm',ic:'📡',bar:function(v){return cl((+v+130)*100/50,0,100);},lv:function(v){return v>=-90?'ok':v>=-105?'warn':'crit';}},
  rsrq:{n:'RSRQ',g:'Сигнал',u:'dB',ic:'📡',bar:function(v){return cl((+v+20)*100/17,0,100);},lv:function(v){return v>=-12?'ok':v>=-16?'warn':'crit';}},
  sinr:{n:'SINR',g:'Сигнал',u:'dB',ic:'📈',bar:function(v){return cl((+v+10)*100/30,0,100);},lv:function(v){return v>=13?'ok':v>=0?'warn':'crit';}},
  rssi:{n:'RSSI',g:'Сигнал',u:'dBm',ic:'📶',bar:function(v){return cl((+v+110)*100/60,0,100);},lv:function(v){return v>=-65?'ok':v>=-85?'warn':'crit';}},
  csq:{n:'CSQ',g:'Сигнал',u:'',ic:'📶'},
  rscp:{n:'RSCP',g:'Сигнал',u:'dBm',ic:'📡'}, ecio:{n:'Ec/Io',g:'Сигнал',u:'dB',ic:'📡'},
  cqi:{n:'CQI',g:'Сигнал',u:'',ic:'📊'}, pathloss:{n:'Pathloss',g:'Сигнал',u:'dB',ic:'📉'}, txpower:{n:'TX power',g:'Сигнал',u:'dBm',ic:'⚡'},
  operator_name:{n:'Оператор',g:'Сеть',ic:'🏢'},
  mode:{n:'Режим',g:'Сеть',ic:'🌐',f:function(v){return String(v).replace(/\s*\(\s*\d+(?:\.\d+)?\s*MHz\s*\)/gi,'');}},
  pband:{n:'Диапазон',g:'Сеть',ic:'📻'}, bandwidth:{n:'Полоса',g:'Сеть',ic:'↔️'},
  earfcn:{n:'EARFCN',g:'Сеть',ic:'🔢'}, registration:{n:'Регистрация',g:'Сеть',ic:'✅'},
  uecat:{n:'UE Cat',g:'Сеть',ic:'🏷️'}, volte:{n:'VoLTE',g:'Сеть',ic:'📞'},
  pci:{n:'PCI',g:'Сота',ic:'🗼'}, cid_dec:{n:'Cell ID',g:'Сота',ic:'🗼'},
  enbid:{n:'eNB ID',g:'Сота',ic:'🗼'}, tac_dec:{n:'TAC',g:'Сота',ic:'📍'}, lac_dec:{n:'LAC',g:'Сота',ic:'📍'},
  ipaddr:{n:'IP',g:'Соединение',ic:'🌍'}, ipaddr6:{n:'IPv6',g:'Соединение',ic:'🌍'},
  iface_apn:{n:'APN',g:'Соединение',ic:'🔌'}, conn_time:{n:'Время связи',g:'Соединение',ic:'⏱️'},
  rx:{n:'Принято',g:'Соединение',ic:'⬇️'}, tx:{n:'Отправлено',g:'Соединение',ic:'⬆️'},
  protocol:{n:'Протокол',g:'Соединение',ic:'🔗'}, roaming:{n:'Роуминг',g:'Соединение',ic:'✈️',f:function(v){return v==='1'?'Да':'Нет';}},
  modem:{n:'Модем',g:'Устройство',ic:'📟'}, firmware:{n:'Прошивка',g:'Устройство',ic:'💾'},
  mtemp:{n:'Температура',g:'Устройство',ic:'🌡️'}, mtherm:{n:'Троттлинг',g:'Устройство',ic:'🔥'},
  imei:{n:'IMEI',g:'Устройство',ic:'🔖'},
  imsi:{n:'IMSI',g:'SIM',ic:'📇'}, iccid:{n:'ICCID',g:'SIM',ic:'📇'},
  simslot:{n:'SIM-слот',g:'SIM',ic:'🎴'}, phone:{n:'Номер',g:'SIM',ic:'📱'}
};
C._traffic={n:'Трафик (↓↑)',g:'Соединение',ic:'🔄'};
C.iface_proto={n:'Интерфейс',g:'Соединение',ic:'🔌',f:function(v){var m={modemmanager:'ModemManager',qmi:'QMI',mbim:'MBIM',fibocom:'Fibocom',ncm:'NCM',xmm:'XMM',atc:'AT',wwan:'WWAN','3g':'3G',ecm:'ECM'};return m[String(v).toLowerCase()]||v;}};
C.vidpid={n:'VID:PID',g:'Устройство',ic:'🔩'};
C.product={n:'USB-имя',g:'Устройство',ic:'🏭'};
var MODEM_FIELDS=['modem','firmware','vidpid','operator_name','mode','signal','rsrp','rsrq','sinr','rssi',
  'pband','bandwidth','earfcn','pci','cid_dec','enbid','tac_dec','iface_proto','ipaddr','iface_apn','conn_time',
  'rx','tx','_traffic','mtemp','mtherm','imei','imsi','iccid','phone','simslot','roaming'];
var SIZE_LABEL={s:'S',w:'W',t:'T',l:'L'};
var SIZEOPT=[['h','½'],['q','◻'],['n','▭'],['w','▬'],['b','⬛']];
var SVG_DN='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v15M5 12l7 7 7-7"/></svg>';
var SVG_UP='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20V5M5 12l7-7 7 7"/></svg>';
var DEFAULT=[{k:'signal',s:'w'},{k:'rsrp',s:'s'},{k:'rsrq',s:'s'},{k:'sinr',s:'s'},
  {k:'operator_name',s:'w'},{k:'mode',s:'s'},{k:'pband',s:'s'},{k:'mtemp',s:'s'}];
var LSKEY='5g_dash_layout_v1';

function operatorIcon(name){
  var n=(name||'').toLowerCase();
  if(n.indexOf('t-mobile')>=0||n.indexOf('tinkoff')>=0||n.indexOf('t-bank')>=0||n.indexOf('т-мобайл')>=0||n.indexOf('т-банк')>=0||n.indexOf('t-mob')>=0)return 'op-tbank';
  if(n.indexOf('beeline')>=0||n.indexOf('билайн')>=0||n.indexOf('vimpel')>=0)return 'op-beeline';
  if(n.indexOf('mts')>=0||n.indexOf('мтс')>=0)return 'op-mts';
  if(n.indexOf('megafon')>=0||n.indexOf('мегафон')>=0)return 'op-megafon';
  if(n.indexOf('tele2')>=0||n.indexOf('теле2')>=0||n.trim()==='t2')return 'op-t2';
  if(n.indexOf('just esim')>=0||n.indexOf('justesim')>=0||n.indexOf('just-esim')>=0)return 'op-justesim';
  if(n.indexOf('yota')>=0)return 'op-yota';
  if(n.indexOf('motiv')>=0||n.indexOf('мотив')>=0)return 'op-motiv';
  if(n.indexOf('sber')>=0||n.indexOf('сбер')>=0)return 'op-sbermobile';
  if(n.indexOf('tattelecom')>=0||n.indexOf('таттелеком')>=0||n.indexOf('летай')>=0)return 'op-tattelecom';
  return null;
}
function opImg(rawop){var oi=operatorIcon(rawop)||'op-sim';return '<img class="mc-opic" src="'+IC+oi+'.png" alt="">';}
function sigIconSrc(p){p=+p;var f=(p<=0)?'000-000':(p<20)?'000-020':(p<40)?'020-040':(p<60)?'040-060':(p<80)?'060-080':'080-100';return IC+'5gmodem/mobile-signal-'+f+'.svg';}
function mcGauge(p,lv,valHTML){
  p=Math.max(0,Math.min(100,Math.round(p||0)));var d=30,r=(d/2)-3.5,cc=d/2,circ=2*Math.PI*r,off=circ*(1-p/100);
  var col=lv==='crit'?'var(--crit)':lv==='warn'?'var(--warn)':lv==='ok'?'var(--ok)':'var(--accent)';
  return '<div class="mc-gc"><svg width="'+d+'" height="'+d+'" viewBox="0 0 '+d+' '+d+'">'+
    '<circle cx="'+cc+'" cy="'+cc+'" r="'+r+'" fill="none" stroke="var(--border)" stroke-width="4"/>'+
    '<circle cx="'+cc+'" cy="'+cc+'" r="'+r+'" fill="none" stroke="'+col+'" stroke-width="4" stroke-linecap="round" stroke-dasharray="'+circ.toFixed(1)+'" stroke-dashoffset="'+off.toFixed(1)+'" transform="rotate(-90 '+cc+' '+cc+')"/></svg>'+
    '<span class="mc-gv">'+valHTML+'</span></div>';
}
function gaugeSVG(p,lv,d){
  d=d||38;p=Math.max(0,Math.min(100,Math.round(p||0)));
  var r=(d/2)-4,cc=d/2,circ=2*Math.PI*r,off=circ*(1-p/100),sw=Math.max(4,Math.round(d/9));
  var col=lv==='crit'?'var(--crit)':lv==='warn'?'var(--warn)':lv==='ok'?'var(--ok)':'var(--accent)';
  return '<div class="mc-gauge"><svg width="'+d+'" height="'+d+'" viewBox="0 0 '+d+' '+d+'">'+
    '<circle cx="'+cc+'" cy="'+cc+'" r="'+r+'" fill="none" stroke="var(--border)" stroke-width="'+sw+'"/>'+
    '<circle cx="'+cc+'" cy="'+cc+'" r="'+r+'" fill="none" stroke="'+col+'" stroke-width="'+sw+'" stroke-linecap="round" stroke-dasharray="'+circ.toFixed(1)+'" stroke-dashoffset="'+off.toFixed(1)+'" transform="rotate(-90 '+cc+' '+cc+')"/></svg>'+
    '<span class="gv">'+p+'<small>%</small></span></div>';
}
function fieldDefault(k){var disp=(k==='_traffic')?'traffic':((k==='iface_proto'||k==='vidpid')?'chip':'text');return {k:k,on:(k!=='_traffic'),disp:disp,sz:'n'};}
/* Размер плитки модема: cw=колонок(1..4), ch=полурядов(1..6). ch=1 => половинная
   высота, «только значение» (подпись прячет CSS data-sz=h). Старые раскладки
   хранят sz (q/n/w/b) — мигрируем в cw/ch. data-sz = бакет для CSS-размера шрифта. */
function mcDims(f){
  var cw=f.cw,ch=f.ch;
  if(cw==null||ch==null){var m=({q:[1,2],n:[2,2],w:[3,2],b:[2,4],h:[2,1]})[f.sz||'n']||[2,2];
    if(cw==null)cw=m[0];if(ch==null)ch=m[1];}
  cw=Math.max(1,Math.min(4,cw|0));ch=Math.max(1,Math.min(6,ch|0));
  var sz=ch===1?'h':(cw>=3?'w':(ch>=4?'b':(cw===1?'q':'n')));
  return {cw:cw,ch:ch,sz:sz};
}
function modemDefaults(){return MODEM_FIELDS.map(fieldDefault);}
function ensureModemFields(item){
  if(!item.fields)item.fields=modemDefaults();
  var have={};item.fields.forEach(function(f){have[f.k]=1;});
  MODEM_FIELDS.forEach(function(k){if(!have[k])item.fields.push(fieldDefault(k));});
}
function dispOptions(k){
  if(k==='_traffic')return {traffic:'Стрелки ↓↑'};
  if(k==='iface_proto'||k==='vidpid')return {chip:'Чип (как в проге)',text:'Текст',badge:'Бейдж'};
  var o={text:'Текст',badge:'Бейдж'};var c=C[k]||{};
  if(c.bar){o.bar='Шкала';o.gauge='Круг';}
  if(k==='signal')o.bars='Иконка сигнала';
  if(k==='operator_name'){o.simop='Лого + имя';o.simcard='Сим-карта + имя';}
  if(k==='rx')o.arrow='Стрелка ↓'; if(k==='tx')o.arrow='Стрелка ↑';
  return o;
}
function panelDefaults(){return ['signal','rsrp','rsrq','sinr','rssi'].map(function(k){return {k:k,on:true,viz:'lbar'};});}
function pnVizOptions(k){var o={};var c=C[k]||{};if(c.bar){o.lbar='Полоса';o.gauge='Круг';}o.num='Число';return o;}

return view.extend({
  handleSaveApply: null, handleSave: null, handleReset: null,

  render: function() {
    var root = E('div', { 'class': 'dashx edit-on' });
    root.innerHTML =
      '<style>'+CSS+'</style>'+
      '<div class="top">'+
        '<h1>Дашборд метрик</h1>'+
        '<span class="sub" id="modemname">—</span>'+
        '<span class="sp"></span>'+
        '<span class="sub" id="age"></span>'+
        '<button class="btn on" id="editBtn">✓ Готово</button>'+
      '</div>'+
      '<div class="studio">'+
        '<div>'+
          '<div class="panel" id="setPanel" style="margin-bottom:16px;display:none">'+
            '<div class="phead">⚙️ Карточка <span class="badge">настройки</span></div>'+
            '<div class="pbody" id="setBody"></div>'+
          '</div>'+
          '<div class="panel" id="catPanel">'+
            '<div class="phead">Метрики <span class="badge" id="catCount">0</span></div>'+
            '<div class="pbody"><input class="search" id="search" placeholder="Поиск метрики…"><div id="catList"></div></div>'+
          '</div>'+
        '</div>'+
        '<div class="panel dash">'+
          '<div class="phead">Дашборд <span class="badge" id="cardCount">0</span></div>'+
          '<div class="pbody"><div class="canvas"><div class="grid" id="grid"></div></div></div>'+
        '</div>'+
      '</div>';

    var $ = function(sel){return root.querySelector(sel);};
    var DATA={}, sel=null, editing=true, dragIdx=null, mcDrag=null, mcSel=null;
    var layout=(function(){try{var a=JSON.parse(localStorage.getItem(LSKEY));if(Array.isArray(a))return a;}catch(e){}return DEFAULT.slice();})();
    function save(){try{localStorage.setItem(LSKEY,JSON.stringify(layout));}catch(e){}}
    function raw(k){var v=DATA[k];return (v==null||v==='-'||v==='')?null:v;}
    function fmt(k){var v=raw(k);if(v==null)return {t:'—',u:'',len:1};var c=C[k]||{};if(c.f)v=c.f(v);v=String(v);return {t:esc(v),u:c.u||'',len:v.length};}

    function mcField(f,fi){
      var d=mcDims(f);var sz=d.sz;
      var szAttr=' data-sz="'+d.sz+'"'+(fi==null?'':' data-fi="'+fi+'"')+' style="grid-column:span '+d.cw+';grid-row:span '+d.ch+'"';
      var rm=(fi==null)?'':'<button class="mc-rm" title="Убрать виджет">✕</button><span class="mc-rz" title="Потяни угол — размер"></span>';
      if(f.k==='_traffic'){
        var rrx=raw('rx'),rtx=raw('tx');
        return '<div class="mc-item cbi-button"'+szAttr+'>'+rm+'<span class="mc-lbl">Трафик</span><div class="mc-traf">'+
          '<span class="tr rx">'+SVG_DN+'<span class="tv">'+(rrx==null?'—':esc(rrx))+'</span></span>'+
          '<span class="tr tx">'+SVG_UP+'<span class="tv">'+(rtx==null?'—':esc(rtx))+'</span></span></div></div>';
      }
      var c=C[f.k]||{n:f.k};var v=fmt(f.k);var rv=raw(f.k);
      var lv=(c.lv&&rv!=null)?c.lv(parseFloat(rv)):'';
      var name=esc(c.n||f.k);var val=v.t+(v.u?'<span class="u">'+v.u+'</span>':'');
      var lva=lv?' data-level="'+lv+'"':'';var disp=f.disp||'text';if(disp==='big')disp='text';
      var body;
      if(disp==='simop'||disp==='simcard'){
        var img=(disp==='simcard')?'<img class="mc-opic" src="'+IC+'op-sim.png" alt="">':opImg(raw('operator_name'));
        body=(sz==='q')?'<span class="mc-lbl">'+name+'</span><div class="mc-op only-ic">'+img+'</div>'
          :'<span class="mc-lbl">'+name+'</span><div class="mc-op">'+img+'<span class="opn">'+v.t+'</span></div>';
      }else if(disp==='bars'){
        body='<span class="mc-lbl">'+name+'</span><div class="mc-gc"><img class="mc-sigic" src="'+sigIconSrc(parseFloat(rv))+'" alt=""><span class="mc-gv">'+val+'</span></div>';
      }else if(disp==='chip'){
        var ghost=(f.k==='iface_proto'&&String(DATA.mm_running)==='1'&&String(DATA.mm_hidden)==='1')?'<img src="'+IC+'cghost.svg" alt="" title="скрыт от ModemManager">':'';
        body='<span class="mc-lbl">'+name+'</span><span class="mc-chip">'+ghost+v.t+'</span>';
      }else if(disp==='arrow'){
        var ar=(f.k==='rx')?SVG_DN:SVG_UP,arc=(f.k==='rx')?'rx':'tx';
        body='<span class="mc-lbl">'+name+'</span><div class="mc-traf"><span class="tr '+arc+'">'+ar+'<span class="tv">'+val+'</span></span></div>';
      }else if(disp==='gauge'&&c.bar&&rv!=null){
        body='<span class="mc-lbl">'+name+'</span>'+mcGauge(c.bar(parseFloat(rv)),lv,val);
      }else if(disp==='badge'){
        body='<span class="mc-lbl">'+name+'</span><span class="mc-badge">'+v.t+'</span>';
      }else if(disp==='bar'&&c.bar&&rv!=null){
        var p=c.bar(parseFloat(rv));
        body='<span class="mc-lbl">'+name+'</span><span class="mc-val">'+val+'</span><div class="bar"><i style="width:'+(p==null?0:p)+'%"></i></div>';
      }else{
        var vc=v.len>16?' small':v.len>8?' mid':'';
        body='<span class="mc-lbl">'+name+'</span><span class="mc-val'+vc+'">'+val+'</span>';
      }
      return '<div class="mc-item cbi-button"'+szAttr+lva+'>'+rm+body+'</div>';
    }
    function modemHTML(item){
      ensureModemFields(item);
      var cells=item.fields.map(function(f,i){return f.on?mcField(f,i):'';}).join('');
      return '<div class="whead mc-head"><img class="mc-headic" src="'+IC+'cmodem.svg" alt="">'+
        '<span class="mc-name">'+esc(item.lbl||DATA.modem||'Модем')+'</span></div>'+
        '<div class="mc-grid">'+(cells||'<span class="muted" style="padding:6px">Все элементы выключены</span>')+'</div>';
    }
    function pnField(f){
      var c=C[f.k]||{n:f.k};var v=fmt(f.k);var rv=raw(f.k);
      var lv=(c.lv&&rv!=null)?c.lv(parseFloat(rv)):'';var lva=lv?' data-level="'+lv+'"':'';
      var name=esc(c.n||f.k);var val=v.t+(v.u?'<span class="u">'+v.u+'</span>':'');
      var viz=f.viz;if(!pnVizOptions(f.k)[viz])viz=(c.bar?'lbar':'num');
      if(viz==='gauge'&&c.bar&&rv!=null){
        return '<div class="pn-row gauge"'+lva+'>'+gaugeSVG(c.bar(parseFloat(rv)),lv,58)+
          '<div class="pn-gl"><span class="pn-lbl">'+name+'</span><span class="pn-v">'+val+'</span></div></div>';
      }
      if(viz==='lbar'&&c.bar&&rv!=null){
        var p=c.bar(parseFloat(rv));
        return '<div class="pn-row lbar"'+lva+'><div class="pn-top"><span class="pn-lbl">'+name+'</span><span class="pn-v">'+val+'</span></div>'+
          '<div class="pn-bar"><i style="width:'+(p==null?0:p)+'%"></i></div></div>';
      }
      return '<div class="pn-row num"'+lva+'><span class="pn-lbl">'+name+'</span><span class="pn-num'+(v.len>10?' long':'')+'">'+val+'</span></div>';
    }
    function panelHTML(item){
      var rows=(item.fields||[]).filter(function(f){return f.on;}).map(pnField).join('');
      return '<div class="whead"><span class="wic">📊</span>'+esc(item.lbl||'Панель сигнала')+'</div>'+
        '<div class="pn-grid">'+(rows||'<span class="muted" style="padding:6px">Нет элементов</span>')+'</div>';
    }
    function fitModems(){
      root.querySelectorAll('.w.modemcard,.w.panelcard').forEach(function(el){
        var mg=el.querySelector('.mc-grid');
        if(mg){var cols=getComputedStyle(mg).gridTemplateColumns.split(/\s+/);var cw=parseFloat(cols[0]);if(cw>0)mg.style.gridAutoRows=(cw/2)+'px';}
        el.style.gridRow='';
        var h=el.offsetHeight;
        el.style.gridRow='span '+Math.max(2,Math.ceil((h+12)/116));
      });
    }
    function wireModemItemsDnD(card,item,idx){
      if(!editing)return;
      card.querySelectorAll('.mc-item').forEach(function(it){
        it.draggable=true;
        if(mcSel&&mcSel.ci===idx&&+it.dataset.fi===mcSel.fi)it.classList.add('mc-sel');
        it.addEventListener('click',function(e){if(e.target.closest('.mc-rm,.mc-rz'))return;e.stopPropagation();var fi=+it.dataset.fi;
          mcSel=(mcSel&&mcSel.ci===idx&&mcSel.fi===fi)?null:{ci:idx,fi:fi};grid();});
        var rmb=it.querySelector('.mc-rm');
        if(rmb)rmb.addEventListener('click',function(e){e.stopPropagation();e.preventDefault();var fi=+it.dataset.fi;if(item.fields[fi]){item.fields[fi].on=false;mcSel=null;save();grid();settings();}});
        var rz=it.querySelector('.mc-rz');
        if(rz)rz.addEventListener('pointerdown',function(e){
          e.preventDefault();e.stopPropagation();
          var fi=+it.dataset.fi,f=item.fields[fi];if(!f)return;
          var d0=mcDims(f),sCw=d0.cw,sCh=d0.ch,sx=e.clientX,sy=e.clientY;
          var mg=card.querySelector('.mc-grid');
          var colw=parseFloat(getComputedStyle(mg).gridTemplateColumns.split(/\s+/)[0])||74;
          var stepX=colw+8,stepY=colw/2+8;
          it.draggable=false;try{rz.setPointerCapture(e.pointerId);}catch(_){}
          function mv(ev){
            var nCw=Math.max(1,Math.min(4,sCw+Math.round((ev.clientX-sx)/stepX)));
            var nCh=Math.max(1,Math.min(6,sCh+Math.round((ev.clientY-sy)/stepY)));
            if(f.cw!==nCw||f.ch!==nCh){f.cw=nCw;f.ch=nCh;var nd=mcDims(f);
              it.style.gridColumn='span '+nd.cw;it.style.gridRow='span '+nd.ch;it.setAttribute('data-sz',nd.sz);fitModems();}
          }
          function up(){rz.removeEventListener('pointermove',mv);rz.removeEventListener('pointerup',up);
            try{rz.releasePointerCapture(e.pointerId);}catch(_){}it.draggable=true;save();grid();settings();}
          rz.addEventListener('pointermove',mv);rz.addEventListener('pointerup',up);
        });
        it.addEventListener('dragstart',function(e){e.stopPropagation();mcDrag=+it.dataset.fi;it.classList.add('mc-drag');try{e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain','mc');}catch(_){}});
        it.addEventListener('dragend',function(e){e.stopPropagation();mcDrag=null;it.classList.remove('mc-drag');card.querySelectorAll('.mc-item.mc-over').forEach(function(x){x.classList.remove('mc-over');});});
        it.addEventListener('dragover',function(e){if(mcDrag==null)return;e.preventDefault();e.stopPropagation();it.classList.add('mc-over');});
        it.addEventListener('dragleave',function(e){e.stopPropagation();it.classList.remove('mc-over');});
        it.addEventListener('drop',function(e){e.preventDefault();e.stopPropagation();it.classList.remove('mc-over');
          var to=+it.dataset.fi;if(mcDrag==null||mcDrag===to)return;
          var m=item.fields.splice(mcDrag,1)[0];item.fields.splice(to,0,m);mcDrag=null;save();grid();settings();});
      });
    }
    function grid(){
      var g=$('#grid');g.innerHTML='';
      $('#cardCount').textContent=layout.length;
      if(!layout.length){g.className='grid empty';g.textContent='Пусто — добавьте метрики слева';return;}
      g.className='grid';
      layout.forEach(function(item,idx){
        var el=document.createElement('div');
        el.className='w cbi-button'+(sel===idx?' sel':'')+(item.type==='modem'?' modemcard':item.type==='panel'?' panelcard':'');
        el.setAttribute('data-size',item.s||'s');
        if(item.type==='modem'){el.innerHTML=modemHTML(item)+'<button class="wx" title="Убрать">✕</button>';}
        else if(item.type==='panel'){el.innerHTML=panelHTML(item)+'<button class="wx" title="Убрать">✕</button>';}
        else {
          var c=C[item.k]||{n:item.k,ic:'▫️'};var v=fmt(item.k);var rv=raw(item.k);
          var lv=(c.lv&&rv!=null)?c.lv(parseFloat(rv)):'';
          if(lv)el.setAttribute('data-level',lv);
          var barH='';
          if(c.bar&&rv!=null&&(item.s==='w'||item.s==='l')){var p=c.bar(parseFloat(rv));if(p!=null)barH='<div class="bar"><i style="width:'+p+'%"></i></div>';}
          var subH=((item.s==='l'||item.s==='t')&&item.sub)?'<div class="wsub">'+esc(item.sub)+'</div>':'';
          var vc=v.len>12?' small':v.len>6?' mid':'';
          el.innerHTML='<div class="whead"><span class="wic">'+(c.ic||'▫️')+'</span>'+esc(item.lbl||c.n||item.k)+'</div>'+
            '<div class="wval'+vc+'">'+v.t+(v.u?'<span class="wunit">'+v.u+'</span>':'')+'</div>'+subH+barH+
            '<button class="wx" title="Убрать">✕</button>';
        }
        el.querySelector('.wx').addEventListener('click',function(e){e.stopPropagation();layout.splice(idx,1);if(sel===idx)sel=null;else if(sel>idx)sel--;save();grid();picker();settings();});
        el.addEventListener('click',function(){if(!editing)return;sel=(sel===idx?null:idx);grid();settings();});
        el.draggable=editing;
        el.addEventListener('dragstart',function(e){if(!editing){e.preventDefault();return;}dragIdx=idx;el.classList.add('dragging');try{e.dataTransfer.effectAllowed='move';e.dataTransfer.setData('text/plain',String(idx));}catch(_){}});
        el.addEventListener('dragend',function(){dragIdx=null;el.classList.remove('dragging');root.querySelectorAll('.w.dragover').forEach(function(x){x.classList.remove('dragover');});});
        el.addEventListener('dragover',function(e){if(dragIdx==null||dragIdx===idx)return;e.preventDefault();el.classList.add('dragover');});
        el.addEventListener('dragleave',function(){el.classList.remove('dragover');});
        el.addEventListener('drop',function(e){e.preventDefault();el.classList.remove('dragover');if(dragIdx==null||dragIdx===idx)return;var m=layout.splice(dragIdx,1)[0];layout.splice(idx,0,m);sel=idx;dragIdx=null;save();grid();settings();});
        if(item.type==='modem')wireModemItemsDnD(el,item,idx);
        g.appendChild(el);
      });
      requestAnimationFrame(fitModems);
    }
    function picker(){
      var q=($('#search').value||'').toLowerCase();
      var groups={};Object.keys(C).forEach(function(k){if(k.charAt(0)==='_')return;var c=C[k];if(q&&(k+' '+c.n+' '+c.g).toLowerCase().indexOf(q)<0)return;(groups[c.g]=groups[c.g]||[]).push(k);});
      var host=$('#catList');host.innerHTML='';var n=0;
      var COMPO=[
        {t:'modem',ic:'📟',nm:'Модем — все поля',kw:'модем modem составная поля',mk:function(){return {type:'modem',s:'l',lbl:'Модем',fields:modemDefaults()};}},
        {t:'panel',ic:'📊',nm:'Панель сигнала — крупная',kw:'панель сигнал panel сота крупная',mk:function(){return {type:'panel',s:'l',lbl:'Панель сигнала',fields:panelDefaults()};}}
      ];
      var compoShown=COMPO.filter(function(x){return !q||(x.kw+' '+x.nm).toLowerCase().indexOf(q)>=0;});
      if(compoShown.length){
        var ch=document.createElement('div');ch.className='cat';ch.textContent='Составные';host.appendChild(ch);
        compoShown.forEach(function(x){
          var has=false;for(var mi=0;mi<layout.length;mi++)if(layout[mi].type===x.t){has=true;break;}
          var r=document.createElement('div');r.className='pick';
          r.innerHTML='<span class="pi">'+x.ic+'</span><span class="pn">'+esc(x.nm)+'</span><span class="pv"></span>'+
            '<button class="padd'+(has?' in':'')+'" title="'+(has?'Убрать':'Добавить')+'">'+(has?'✓':'+')+'</button>';
          r.querySelector('.padd').addEventListener('click',function(){
            var i=-1;for(var j=0;j<layout.length;j++){if(layout[j].type===x.t){i=j;break;}}
            if(i>=0){layout.splice(i,1);if(sel===i)sel=null;else if(sel>i)sel--;}else{layout.push(x.mk());}
            save();grid();picker();settings();
          });
          host.appendChild(r);
        });
      }
      Object.keys(groups).forEach(function(gname){
        var h=document.createElement('div');h.className='cat';h.textContent=gname;host.appendChild(h);
        groups[gname].forEach(function(k){n++;var c=C[k];var inLayout=layout.some(function(i){return i.k===k;});var v=fmt(k);
          var row=document.createElement('div');row.className='pick';
          row.innerHTML='<span class="pi">'+(c.ic||'▫️')+'</span><span class="pn">'+esc(c.n)+'</span>'+
            '<span class="pv">'+(v.t==='—'?'':v.t+(v.u?' '+v.u:''))+'</span>'+
            '<button class="padd'+(inLayout?' in':'')+'" title="'+(inLayout?'Убрать':'Добавить')+'">'+(inLayout?'✓':'+')+'</button>';
          row.querySelector('.padd').addEventListener('click',function(){
            var i=layout.map(function(x){return x.k;}).indexOf(k);
            if(i>=0){layout.splice(i,1);if(sel===i)sel=null;}else{layout.push({k:k,s:'s'});}
            save();grid();picker();settings();
          });
          host.appendChild(row);
        });
      });
      $('#catCount').textContent=n;
    }
    function settings(){
      var p=$('#setPanel'),b=$('#setBody');
      if(sel==null||!layout[sel]||!editing){p.style.display='none';return;}
      p.style.display='';try{p.scrollIntoView({behavior:'smooth',block:'nearest'});}catch(e){}
      var item=layout[sel];
      if(item.type==='modem'){modemSettings(b,item);return;}
      if(item.type==='panel'){panelSettings(b,item);return;}
      var c=C[item.k]||{};
      var sz=['s','w','t','l'].map(function(s){return '<button class="szb'+(item.s===s?' on':'')+'" data-sz="'+s+'">'+SIZE_LABEL[s]+'</button>';}).join('');
      b.innerHTML='<div class="setrow"><label>'+(c.ic||'')+' '+esc(c.n||item.k)+'</label><span class="muted">'+esc(item.k)+'</span></div>'+
        '<div class="setrow"><label>Размер</label><div class="sizes">'+sz+'</div></div>'+
        '<div class="setrow"><label>Заголовок</label><input class="search" style="margin:0;max-width:170px" id="lblInp" value="'+esc(item.lbl||'')+'" placeholder="'+esc(c.n||item.k)+'"></div>'+
        '<div class="setrow"><label>Доп. подпись</label><input class="search" style="margin:0;max-width:170px" id="subInp" value="'+esc(item.sub||'')+'" placeholder="виден на T/L"></div>'+
        '<div class="setrow"><button class="btn" id="delCard">Убрать карточку</button></div>';
      b.querySelectorAll('.szb').forEach(function(x){x.addEventListener('click',function(){item.s=x.dataset.sz;save();grid();settings();});});
      b.querySelector('#lblInp').addEventListener('input',function(){item.lbl=this.value;save();grid();});
      b.querySelector('#subInp').addEventListener('input',function(){item.sub=this.value;save();grid();});
      b.querySelector('#delCard').addEventListener('click',function(){layout.splice(sel,1);sel=null;save();grid();picker();settings();});
    }
    function modemSettings(b,item){
      ensureModemFields(item);
      var flds=item.fields.map(function(f,i){
        var c=C[f.k]||{n:f.k,ic:'▫️'};
        var dop=dispOptions(f.k);var dcur=(f.disp&&dop[f.disp])?f.disp:Object.keys(dop)[0];
        var opts=Object.keys(dop).map(function(d){return '<option value="'+d+'"'+(dcur===d?' selected':'')+'>'+dop[d]+'</option>';}).join('');
        var dcur=mcDims(f).sz;
        var sopts=SIZEOPT.map(function(s){return '<option value="'+s[0]+'"'+(dcur===s[0]?' selected':'')+'>'+s[1]+'</option>';}).join('');
        return '<div class="fld'+(f.on?'':' off')+'" data-i="'+i+'">'+
          '<span class="fmv"><button data-mv="up" title="Выше">▲</button><button data-mv="down" title="Ниже">▼</button></span>'+
          '<input type="checkbox" class="fon"'+(f.on?' checked':'')+' title="Показывать">'+
          '<span class="fn">'+(c.ic||'')+' '+esc(c.n||f.k)+'</span>'+
          '<select class="fsz" title="Размер">'+sopts+'</select>'+
          '<select class="fdisp" title="Тип">'+opts+'</select></div>';
      }).join('');
      b.innerHTML='<div class="setrow"><label>📟 Модем</label><span class="muted">составная</span></div>'+
        '<div class="setrow"><label>Заголовок</label><input class="search" style="margin:0;max-width:170px" id="lblInp" value="'+esc(item.lbl||'')+'" placeholder="Модем"></div>'+
        '<div class="muted" style="margin:10px 0 6px">Клик по плитке → ✕ и уголок для растягивания · ½ = только значение · ▲▼ порядок · размер · тип</div>'+
        '<div class="flds">'+flds+'</div>'+
        '<div class="setrow"><button class="btn" id="delCard">Убрать карточку</button></div>';
      b.querySelector('#lblInp').addEventListener('input',function(){item.lbl=this.value;save();grid();});
      b.querySelector('#delCard').addEventListener('click',function(){layout.splice(sel,1);sel=null;save();grid();picker();settings();});
      b.querySelectorAll('.fld').forEach(function(row){
        var i=+row.dataset.i;
        row.querySelector('.fon').addEventListener('change',function(){item.fields[i].on=this.checked;save();grid();modemSettings(b,item);});
        row.querySelector('.fsz').addEventListener('change',function(){item.fields[i].sz=this.value;delete item.fields[i].cw;delete item.fields[i].ch;save();grid();});
        row.querySelector('.fdisp').addEventListener('change',function(){item.fields[i].disp=this.value;save();grid();});
        row.querySelectorAll('.fmv button').forEach(function(btn){btn.addEventListener('click',function(){
          var j=i+(btn.dataset.mv==='up'?-1:1);if(j<0||j>=item.fields.length)return;
          var t=item.fields[i];item.fields[i]=item.fields[j];item.fields[j]=t;save();grid();modemSettings(b,item);
        });});
      });
    }
    function panelSettings(b,item){
      if(!item.fields)item.fields=panelDefaults();
      var flds=item.fields.map(function(f,i){
        var c=C[f.k]||{n:f.k,ic:'▫️'};var vo=pnVizOptions(f.k);var vcur=vo[f.viz]?f.viz:Object.keys(vo)[0];
        var opts=Object.keys(vo).map(function(d){return '<option value="'+d+'"'+(vcur===d?' selected':'')+'>'+vo[d]+'</option>';}).join('');
        return '<div class="fld'+(f.on?'':' off')+'" data-i="'+i+'">'+
          '<span class="fmv"><button data-mv="up">▲</button><button data-mv="down">▼</button></span>'+
          '<input type="checkbox" class="fon"'+(f.on?' checked':'')+' title="Показывать">'+
          '<span class="fn">'+(c.ic||'')+' '+esc(c.n||f.k)+'</span>'+
          '<select class="fviz" title="Вид">'+opts+'</select>'+
          '<button class="frm" title="Убрать">✕</button></div>';
      }).join('');
      var used={};item.fields.forEach(function(f){used[f.k]=1;});
      var addOpts='<option value="">+ добавить метрику…</option>'+Object.keys(C).filter(function(k){return k.charAt(0)!=='_'&&!used[k];})
        .map(function(k){return '<option value="'+k+'">'+esc(C[k].n)+'</option>';}).join('');
      b.innerHTML='<div class="setrow"><label>📊 Панель</label><span class="muted">крупная</span></div>'+
        '<div class="setrow"><label>Заголовок</label><input class="search" style="margin:0;max-width:170px" id="lblInp" value="'+esc(item.lbl||'')+'" placeholder="Панель сигнала"></div>'+
        '<div class="muted" style="margin:10px 0 6px">Элементы · ▲▼ порядок · галка показ · вид · ✕ убрать</div>'+
        '<div class="flds">'+flds+'</div>'+
        '<div class="setrow"><select class="search" id="pnAdd" style="margin:0">'+addOpts+'</select></div>'+
        '<div class="setrow"><button class="btn" id="delCard">Убрать карточку</button></div>';
      b.querySelector('#lblInp').addEventListener('input',function(){item.lbl=this.value;save();grid();});
      b.querySelector('#delCard').addEventListener('click',function(){layout.splice(sel,1);sel=null;save();grid();picker();settings();});
      b.querySelector('#pnAdd').addEventListener('change',function(){var k=this.value;if(!k)return;var c=C[k]||{};item.fields.push({k:k,on:true,viz:c.bar?'lbar':'num'});save();grid();panelSettings(b,item);});
      b.querySelectorAll('.fld').forEach(function(row){
        var i=+row.dataset.i;
        row.querySelector('.fon').addEventListener('change',function(){item.fields[i].on=this.checked;save();grid();panelSettings(b,item);});
        row.querySelector('.fviz').addEventListener('change',function(){item.fields[i].viz=this.value;save();grid();});
        row.querySelector('.frm').addEventListener('click',function(){item.fields.splice(i,1);save();grid();panelSettings(b,item);});
        row.querySelectorAll('.fmv button').forEach(function(btn){btn.addEventListener('click',function(){
          var j=i+(btn.dataset.mv==='up'?-1:1);if(j<0||j>=item.fields.length)return;
          var t=item.fields[i];item.fields[i]=item.fields[j];item.fields[j]=t;save();grid();panelSettings(b,item);
        });});
      });
    }
    function pull(){
      return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/5gmodem.sh',['cached','5']),'{}').then(function(out){
        var j={};try{j=JSON.parse(out||'{}');}catch(e){}
        DATA=j||{};
        $('#modemname').textContent=DATA.modem||'—';
        $('#age').textContent=(DATA.age!=null&&DATA.age!=='-')?('обновлено '+DATA.age+' c назад'):'';
        return L.resolveDefault(fs.exec_direct('/usr/share/5gmodem/listmodems.sh',[]),'[]');
      }).then(function(mout){
        var mods=[];try{mods=JSON.parse(mout||'[]');}catch(e){}
        if(Array.isArray(mods)&&mods.length){
          var m=null;for(var i=0;i<mods.length;i++){if(mods[i].model&&mods[i].model===DATA.modem){m=mods[i];break;}}
          if(!m)m=mods[0];
          DATA.vidpid=m.vidpid||'';DATA.product=m.product||'';
        }
        grid();picker();
      });
    }

    $('#search').addEventListener('input',picker);
    $('#editBtn').addEventListener('click',function(){
      editing=!editing;this.classList.toggle('on',editing);this.textContent=(editing?'✓ Готово':'✏️ Изменить');
      root.classList.toggle('edit-on',editing);root.classList.toggle('edit-off',!editing);
      if(!editing){sel=null;mcSel=null;}grid();settings();
    });
    var _rzt;window.addEventListener('resize',function(){clearTimeout(_rzt);_rzt=setTimeout(fitModems,120);});

    grid();picker();settings();
    pull();
    L.Poll.add(pull,5);   // LuCI сам остановит опрос при уходе с вкладки
    return root;
  }
});
