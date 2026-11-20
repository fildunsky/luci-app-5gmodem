# Extensions

Device-specific pages and button behaviour live in their own package and attach through the hooks below. The package only ships files; luci-app-5gmodem works the same without any of them.

## LuCI: `resources/5gmodem/ext/*.js`

`5gmodem/ext.js` lists the directory (ACL: `list` on it), loads every module with `L.require` and calls a hook of each module that defines it. A module is a `baseclass` singleton. Translations come from the catalogue of the extension's own package.

| Hook | Called by | Purpose |
| --- | --- | --- |
| `init(data)` | `buttons.js`, once per render | `data` is the JSON of `buttons.sh detect`; may change `data.buttons` (labels) and read the members its backend added |
| `presets(kind, services)` | `statePanel` | array of `{ label, cmd, help }` put before the built-in presets; `kind` is `simple` or `conditional` |
| `buttonCard(b, leds, services, onDelete, api)` | `renderButton` | a complete card for button `b`, or `null` for the default card |
| `cards(data, api)` | end of the Buttons page | an extra card |
| `sms(group, s)` | `smssettings.js`, after the options of the group (`receive`, `send`, `ussd`); on the tabbed SMS page `s` is the Notifications tab (`receive`) or Sending tab (`send`) with `option` and that tab's `children` | add options to section `s` or change existing ones in `s.children` |

`api` is `{ statePanel, setField, setLeds, delBinding, saveStatus, flashSaved }` of `buttons.js`. A card that saves several fields at once (own Save button) calls `buttons.sh save <button> <field> <value> ...` through `fs.exec`; `save` accepts `debounce`, `type_override`, `btntype` and the fields of the states in `_STATES`.

## Buttons backend: `/usr/share/5gmodem/buttons.d/*.sh`

Sourced by `buttons.sh` after its helpers. A file redefines the hooks it needs:

| Hook | Default | Purpose |
| --- | --- | --- |
| `_STATES` | `pressed released` | button states with an action; an added state gets `<state>`, `ct_<state>`, `svc_<state>`, `leds_*_<state>` in `set`, `save`, `setleds`, `detect`, `run` |
| `_ext_buttons` | `cat` | filter of the detected buttons, lines `name<TAB>label<TAB>type` |
| `_ext_cond "$cmd"` | `return 3` | state of a conditional command: 0 on, 1 off, 2 unknown, 3 not mine |
| `_ext_detect` | nothing | extra members of the `detect` JSON, each followed by a comma |
| `_ext_run "$button" "$state"` | true | non-zero skips the action (the button is handled elsewhere) |
| `_ext_cmd "$@"` | `return 1` | extra verbs; non-zero means not mine |

Related contracts that need no hook: `5gmodem.sms.newsms_hook` (command run after each refresh of `sms_new.json`) and the standby flag ([health-and-recovery.md](health-and-recovery.md#standby)).
