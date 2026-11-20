# Extensions

Device-specific pages and button behaviour live in their own package and attach through the hooks below. The package only ships files; luci-app-5gmodem works the same without any of them.

## LuCI: `resources/5gmodem/ext/*.js`

`5gmodem/ext.js` lists the directory (ACL: `list` on it) and loads the modules with `L.require`. A module is a `baseclass` singleton and its hooks are synchronous. Load or hook errors are logged in the browser console and other modules continue. Translations come from the catalogue of the extension's own package.

| Hook | Called by | Purpose |
| --- | --- | --- |
| `init(data)` | `buttons.js`, once per render | `data` is the JSON of `buttons.sh detect`; may change `data.buttons` (labels) and read the members its backend added |
| `presets(kind, services)` | `statePanel` | array of `{ label, cmd, help }` put before the built-in presets; `kind` is `simple` or `conditional` |
| `buttonCard(b, leds, services, onDelete, api)` | `renderButton` | an element or document fragment for button `b`; the first match in filename order wins, with the built-in card as the fallback |
| `cards(data, api)` | end of the Buttons page | an extra element or document fragment, even on devices with no assignable buttons |
| `sms(group, s)` | `smssettings.js`, after the options of the group (`receive`, `send`, `ussd`); on the tabbed SMS page `s` is the Notifications tab (`receive`) or Sending tab (`send`) with `option` and that tab's `children` | add options to section `s` or change existing ones in `s.children` |

`api` is `{ statePanel, setField, setLeds, delBinding, saveStatus, flashSaved }` of `buttons.js`. A card that saves several fields at once calls `buttons.sh save <button> <field>=<value> ...` through `fs.exec`. `save` accepts `debounce`, `type_override`, `btntype` and the fields of the states in `_STATES`. The LuCI read ACL allows only `detect`, `leds` and `services`. Extension commands need write access.

## Buttons backend: `/usr/share/5gmodem/buttons.d/*.sh`

Sourced by `buttons.sh` after its helpers. A device package redefines the hooks it needs. Install one device package that defines any given hook, since the last definition wins.

| Hook | Default | Purpose |
| --- | --- | --- |
| `_STATES` | `pressed released` | button states with an action; an added state gets `<state>`, `ct_<state>`, `svc_<state>`, `leds_*_<state>` in `set`, `save`, `setleds`, `detect`, `run` |
| `_ext_buttons` | `cat` | filter of the detected buttons, lines `name<TAB>label<TAB>type` |
| `_ext_cond "$cmd"` | `return 3` | state of a conditional command: 0 on, 1 off, 2 unknown, 3 not mine |
| `_ext_detect` | nothing | extra members of the `detect` JSON, each followed by a comma |
| `_ext_run "$button" "$state"` | true | non-zero skips the action (the button is handled elsewhere) |
| `_ext_cmd "$@"` | `return 1` | extra verbs; non-zero means not mine |

## SMS notifications: `/usr/share/5gmodem/sms-notify.d/`

Device packages can install an executable handler in this directory. After updating `/tmp/5gmodem/sms_new.json`, sessionwatch runs the installed handlers in a background job without arguments. Handlers can read that file and decide when to update a display or an LED. They run serially and a refresh during an active job leaves the next notification pass to the next refresh. Keep handlers short and bounded so one device package does not delay other notifications.

Device packages that previously set `5gmodem.sms.newsms_hook` should install a handler here to keep SMS notifications working after an update.
With no executable handler installed, existing GL-E750 firmware can still notify its display when the option has the firmware's exact default value `/usr/bin/mcu-switch sms new` and that executable is present.

The [standby flag](health-and-recovery.md#standby) is a separate contract.
