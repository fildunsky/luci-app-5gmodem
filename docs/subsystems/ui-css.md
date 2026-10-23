# UI: modem.css and theme compatibility

`htdocs/luci-static/resources/view/modem5g/modem.css` holds all styling for the app. `modemtabs.js` loads it once (see [ui.md](ui.md#shared-css-and-theme-probes)). Styles used to live in 19 `<style>` blocks across 11 JS files plus inline attributes, so one fix had to be repeated in several places. New sections also silently missed the shared spacing. Rule order matters: shared blocks (tabs, internet priority) come first, then pages in their former order, so overrides keep their meaning.

## Principles

- Size and space our own components ourselves. Themes give different values (argon broke six things at once). Do not use percentage font sizes on chips: `font-size: 80%` resolves against the **theme's** button font (bootstrap 13px, proton2025 13px, argon 14px).
- Accent and text colours come from the theme variables, with our values as fallbacks (`--tg-accent` etc. on `:root`). Where the theme defines nothing (bootstrap), the fallback applies.
- Scope rules to our own blocks. Section padding, auto button height, cell padding, last-table margin, heading margin and anchoring opt-out are bound to `[data-page^="admin-modem-5gmodem"]` as well as to the `.tginfo` markers. Rules bound only to markers missed every new section ("Saved profiles", signal indicator, eSIM, tab settings panel). Table layout (`table-layout: fixed`, first column 33%) stays on the `.tginfo` marker, because SMS/USSD/eSIM tables have their own layout.
- Section padding only applies under `html.tg-boxed-sec`. The nested-section reset uses `>`, because the settings panel inside `.cbi-map` has its own padding.
- `height: auto` on our buttons, but no shared `min-height`: it would inflate the intentionally compact SIM chips and band buttons.
- "Current" marker: a left bar (`tg-current`, `.modemtab.active`, `.netpri-btn.active`, `.sms-new`), not the theme's fill. `!important` because argon's dark scheme sets `border: 1px !important` on buttons. Band buttons (multi-select) keep a fill on purpose.
- `prefers-reduced-motion` disables the collapse and fade transitions and the speedtest pulse.

## Broken checkbox mask

One theme draws the checked checkbox tick as a mask on `::after` with `background: var(--fg-color)`. CSS minification turns that variable into an invalid `calc` (the space before `+` is lost), so the fill becomes transparent and every checked box looks unchecked (2026-09-03). Applying `background: currentColor` to all themes repainted proton2025's own healthy tick (2026-09-04). The rule is now scoped to `html.tg-fixcheck`, which `align.js: probeCheckmark` sets only when the browser reports a masked `::after` with content and a transparent fill.

## proton2025 table measuring

proton2025 (`custom-pages.js`, `measureNaturalTableWidth`) temporarily sets `white-space: nowrap` on table cells after every DOM change, forces a reflow and restores the styles. Our multi-line button rows collapse into one line at that moment. Document height drops by about 200 px, and the browser clamps `scrollTop`, so the page crept up on every poll with the band block open. `.tginfo-modesw, #antports-table td { white-space: normal !important }` beats the theme's inline style. It is bound to the class, not to ids. An id list missed `#caen-cell`, `#mode5g-cell`, `#celllock-cell` and `#bands-2g`, and the bug came back when a Compal exposed CA. Inserting another rule inside this selector list once broke the protection, so keep the rule separate.

## Scroll anchoring

The second cause of the "page slowly creeps up" bug was native scroll anchoring. Live blocks above the viewport (bar width transitions, growing tables) changed geometry, and the browser moved `scrollTop` to keep its anchor. Verified live: document height stable, no scroll API calls, and document-level `overflow-anchor: none` stopped it at once. Only our sections and their contents opt out, not foreign LuCI pages. Other causes of jumps are described in [ui.md](ui.md#render-stability-rules).

## Other theme quirks

- argon: `.cbi-section { padding: 0 }` and `.btn, button { height: 2.5rem }`. The fixed height clipped the three-line internet priority cards and flattened band rows. Band buttons and the action buttons on mobile use the `!important` trio (`height`/`min-height`/padding), because height comes from two different theme rules. argon `.cbi-value-title { float:left; width:23rem; text-align:right }` pushed our standalone titles aside, so titles outside `.tg-modem-form` are reset. The same float plus `.cbi-value-field { display: table-cell }` shrank the SMS textarea to a third of the screen. `overflow: hidden` on the field container creates a BFC that takes the remaining width. `.td { text-align: center }` centred the diagnostics column.
- argon-only fixes are under `.tg-theme-argon`. Accent from `--primary`/`--dark-primary` is declared in that scope, not on `:root`, so other themes never pick up a foreign variable. Also translucent card fill, light-scheme white cards with dark text, and dark-scheme overrides inside `@media (prefers-color-scheme: dark)`, which is the same signal argon uses.
- proton2025 `.btn+.btn { margin-left: 8px }` doubles gaps in rows and pushes column-stacked cards (SMS list) 8px to the right each. The fixes raise specificity (`#smsList`, three-class selectors) instead of using `margin: 0` (0,1,0 loses to 0,2,0).
- proton2025 `button, .btn { gap: 8px }` opens holes in flex-column cards. Neutralised.
- proton2025 `.btn` is `inline-flex; align-items: center`. Do not change band chips to `inline-block`, because a descender gap appears. Shrink only padding, height and font.
- proton2025 `.cbi-progressbar` inside tables has `min-width: 200px` and margins. These are removed only inside the CA/neighbour/antenna tables, and the `::after` label is kept. Its accent glow `box-shadow` is removed under red/green fills.
- proton2025 sets `overflow-x: auto !important` on tables at ≤800px. The CA and neighbour tables switch to a card layout at the same 800px breakpoint. Otherwise, a horizontal scrollbar appearing and disappearing changed height on (de)aggregation.
- proton2025 keeps hidden `depends` rows in the DOM, so the last visible form row's bottom border is removed explicitly.
- LuCI combobox lists get an inline `max-height` from the space below the field. Ping host fields sit deep in a table and opened with 2–3 visible items. Overridden with `!important` to about half the viewport (≤ ~26 rows).
- An open `.cbi-dropdown` is trapped in its row's stacking context. The open node is raised so rows below do not paint over it.
- The theme rule `body:not([data-page^="admin-status"]) .cbi-tblsection { overflow-x: auto }` clipped the open ping host list (2026-08-25). The `overflow: visible` rule for the ping/service card sections sits at the end of the file.
- bootstrap colours `<pre>` light, so the diagnostics output class sets background and colour explicitly.
- Some themes (a43 and other bootstrap derivatives) give buttons in cells `width: 100%` and `flex-grow`. Settings card tables keep the delete button at its text width with `!important`.
- `ui.showModal(null, <p.spinning>)` draws an empty `h4` border and left-aligns the spinner. The rule targets only an empty `h4` plus the last `p.spinning`.

## Layout notes

- Metric bars use a width transition of 0.4 s ease-out. Colour and label change instantly.
- Band buttons have a fixed `min-width` plus their own padding, so `B1` and `B71` share a baseline size without crushing the text. 3G combo buttons are exempt.
- Table bars have a fixed height, so rows do not breathe between polls. Cells without a bar are vertically aligned with them.
- The CA table is fixed-layout with fixed column proportions, so it is always 100% wide and has no scrollbar. Values stay on one line, because band strings change length on reselection.
- The signal icon has explicit dimensions, because it is recreated every poll.
- Mobile (<700px): two-column "label | value" rows become a stacked label/value pair separated by lines. Action button cells stretch evenly, band button cells do not. The specificity has to match the `.td` rule. CA, neighbour and antenna tables have their own card layout using `data-l` labels through `::before`. Card cells are flex pairs with `nowrap` parts, so a value wraps as a whole.
- Priority rank digit and background icons: sizes come from font metrics measured on the live page (Inter 800). Opacity and blur are shared variables for all cards, with different values for light and dark (chosen by the `netpri-dark` class from `isDarkUI`, not by the OS scheme). Service icons are rendered as silhouettes at about 3× the uplink opacity, because their thin strokes carry less ink. `github.svg` is pure white and is darkened only on the light theme.
- Speedtest: phase progress is drawn by `::before` using `--st-p`. Upload fills right to left. The current arrow pulses with `drop-shadow`, so the glow follows the SVG outline. The `st-wait` state pulses the border until real numbers arrive.
- SMS cards copy `.netpri-btn` geometry. The `.netpribar` rules are scoped and do not apply on that page, so change both together.
- The SMS action row needs `width: 100%`, or `justify-content: flex-end` has no effect. On narrow screens the info table scrolls on its own and the row is sticky to the left, because a wide table pushed the right-aligned buttons off screen (2026-08-03).
- The SMS counter overlays the textarea with `pointer-events: none` and `user-select: none`. The textarea is `display: block` to remove the inline descender gap. It also needs `cbi-input-textarea`, because themes colour textareas only through that class.
- Degree unit: only the `C` is shrunk and raised, with `line-height: 0`.
- The eSIM wait bar is centred with flex, not with `line-height = height`, because the theme font size broke the latter.
- Buttons page toggle `.btnsw` must be `display: inline-block`. An inline span ignores width and height, and only the knob was visible.
