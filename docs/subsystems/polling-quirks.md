# Verified modem quirks (`quirks.sh`)

`root/usr/share/5gmodem/quirks.sh` is a sourced database of per-modem behaviour
that was **verified on live hardware** (not guessed, not from datasheets). Each
function takes model (`AT+CGMM`) and/or vid:pid and prints a value; an empty answer
means "not verified": the app then imposes nothing and keeps the current setting.
Every new entry must come with what was sent and what was observed - record it in
this file. The ModemManager gates that also live in `quirks.sh`
(`mm_at_allowed`, `mm_at_fragile`, `mm_dedicated_at`, `mm_tty_reserved`,
`sms_send_port`) are described in `polling-at-access.md`.

## `ussd_raw_for <model> <vidpid>`: send USSD as plain text (`sms_tool -R`)

By default `sms_tool` packs the code into GSM7 (`*100#` -> `AA180C3602`). Some
modems reject that but accept the plain string. Value goes into `5gmodem.sms.ussd`
on modem switch (`modemswitch.sh`). `1` = raw, `0` = packed, empty = untouched.

- **SIMCOM SIM7600E-H** (1e0e:9001, LE11B11SIM7600M22): packed
  `AT+CUSD=1,"AA180C3602",15` -> `error: retry operation`; raw
  `AT+CUSD=1,"*100#",15` -> `+CUSD: 0,"0412...",72` (UCS2 balance). -> `1`.
- SIM7100E: same command set (CNBP/CNMP) but USSD not tested; left alone.
- **Fibocom FM350-GL** (0e8d:7127/7126): nothing (see below).
- **Telit LM960A18** (1bc7:1040): USSD works in raw form. An earlier entry said "no
  SS/voice like FM350"; that test was done in LTE, where no answer can come.
  `+CREG: 2,1,...,7` was misread as "CS present", but 7 is the AcT (E-UTRAN), not a
  domain; LTE has no CS until CSFB, and "port sticks" was the modem falling back to
  3G and missing sms_tool's timeout. With `AT+WS46=22` (UTRAN only, MegaFon):
  packed -> nothing; raw -> `+CUSD: 2,"3500...",72` = balance. In LTE the raw
  request -> `+CME ERROR: 30`. -> `1`.

## `ussd_needs_3g_for <model> <vidpid>`: switch to 3G for USSD

USSD uses the CS domain, absent in LTE. Some modems manage via CSFB and must not be
touched (going to 3G and back costs ~20 s without connectivity); others never
answer without real 3G. Cannot be predicted, so only verified entries.

- **Telit LM960A18** (1bc7:1040): in LTE either `+CME ERROR: 30` or CSFB and after
  30 s `+CUSD: 4` (operation not supported), losing registration on the way. After
  `AT+WS46=22` the same code returns the balance in seconds. -> `1`.

## `ussd_supported_for <model> <vidpid>`: is USSD possible at all

Data-only modules declare `+CUSD` (`AT+CUSD=?` -> `(0-2)`) but answer nothing to a
request (no OK/ERROR/URC); the user sees a hung page and blames the app. `0` =
confirmed not working, empty = not verified.

- **Fibocom FM350-GL** (0e8d:7127/7126): full matrix tried (dcs 15/0/none; text,
  packed GSM7, UCS2 hex; TE charset IRA/GSM/UCS2; LTE and 3G with live CS; listener
  on all seven ports; `sms_tool -D` as the only reader): always OK and silence. Not
  the network or SIM: the same cards work on Compal. No workaround in hardware: the
  module has only two compositions, both RNDIS (`AT+GTUSBMODE=?` -> `(40,41)`), no
  MBIM/QMI, so "MBIM under ModemManager" is not available. -> `0`.
- **Quectel EP06-E / EG06-E** (2c7c:0306): `AT+CUSD` answers OK, the network answer
  never comes, no known workaround (forum reports). European revision only: EP06-A
  shares the vid:pid and has no evidence, so it is matched by model. -> `0`.
- Telit LM960A18 is no longer listed (USSD works, see above); the "not working"
  banner on its page was false.

## `sim_slots_via <model> <vidpid>`: how to read/switch SIM slots

`simslot.sh` used to send Fibocom's `AT+SIMTYPE?` and `AT+GTDUALSIM` to every AT
modem (the name SIMTYPE is misleading: it is Fibocom, not SimCom). Extra requests in
the shared port compete with the poll; the echo of `AT+SIMTYPE?` once landed in the
modem name.

Values: `gtdualsim` (Fibocom `AT+SIMTYPE?` + `AT+GTDUALSIM`, slots 0/1),
`ceiswitchsim` (Compal/SG500M2-X `AT+CEISWITCHSIM`, slots 1/2 + card detect),
`qmi` (QMI UIM `--uim-get-slot-status` / `--uim-switch-slot`), `uims` (Sierra
`AT!UIMS`), `quimslot` (Quectel `AT+QUIMSLOT`), `simdet` (Telit LM960), `none` (one
slot, ask nothing), empty = unknown (old behaviour: try in turn).

- **Telit LM960A18** (1bc7:1040): Dual SIM Single Standby per datasheet. AT is a
  dead end: `#SIMSELECT`/`#DUALSIM`/`#SIMSWITCH` -> ERROR; `#SIMINCFG` (`1,0`,
  `2,0`) is SIMIN pin GPIO configuration, not slot selection. QMI UIM tells the
  truth: "2 physical slots found", slot 1 present/active (ICCID), slot 2
  absent/inactive. Currently mapped to `simdet` (handled in `simslot.sh`).
- **Telit FN990** (1bc7:1070/1077/1080): same vendor and QMI, two slots, no AT slot
  commands. The "SIM slots" block was empty with no buttons, so someone who switched
  slots with another tool could neither see nor revert it (05.09.2026, WH3000 Pro:
  card fine, modem "does not see it"). -> `qmi`.
- **Fibocom FM350-GL** (0e8d:7127/7126): `AT+GTDUALSIM` -> `(0-1)`, `AT+SIMTYPE?`
  distinguishes USIM/eSIM. -> `gtdualsim`.
- **Sierra EM9190** (1199:90d3, shared with EM9191; 1199:90e3 EM9291, same family,
  not tested): `AT!UIMS` (0=UIM1, 1=UIM2/eSIM), no password, no reset, persistent
  (reference 41113480 r14). Sierra has no GTDUALSIM/SIMTYPE, slots were not read at
  all (18.08.2026). -> `uims`.
- **Compal RXM-G1 / SG500M2-X** (05c6:90d6): `AT+SIMTYPE?` and `AT+GTDUALSIM` do not
  answer; slots via `AT+CEISWITCHSIM`. -> `ceiswitchsim`.
- **SDX55 family** (Foxconn T99W175, Thales MV31-W, Dell DW5821e and relatives:
  05c6:90d5, 05c6:9025, 413c:81d7/81e0/81e4/81e6/81d8, 0489:e0b5/e0b4, 1bc7:1911,
  Thales compositions 1e2d:00b7/00b3/00b8/00b9 for `AT^CUSTOMER=14/16/33`): no AT slot
  commands, QMI UIM gives everything (04.08.2026, MV31-W on WH3000 Pro: slot 1
  absent/active, slot 2 present, eUICC, EID 8903...). Without the entry the parser
  fell into the AT branch and returned nothing: a modem with a **built-in eUICC**
  showed neither slots nor an eSIM button. -> `qmi`.
  - 05c6:90d5 and 1e2d:00b7 are also used by an early Compal prototype; it is told
    apart by model (`*SG500M2*|*VOS_5G*|*RXM-G1*|*Compal*`, same rule as
    `iscompal.sh`) and gets `ceiswitchsim`.
- **Foxconn T99W373 / Thales MV32-W** (SDX62; 0489:e0f0, 1e2d:00f1-00f4): slots exist
  ("Dual SIM support with DSSS", switching between external SIM and built-in eUICC).
  `AT+SWITCH_SLOT` exists (manual section 15.38) and `simslot.sh` tries it first;
  `qmi` is the family fallback and the only path that lists slots with the eUICC
  flag. -> `qmi`.
- **Quectel EP06-E** (2c7c:0306): `AT+QUIMSLOT=?` does not answer (it is an EM12/M.2
  command; forum says EC25/EP06 switch with `AT+QDSIM`, not verified), but the slots
  exist: QMI reports two (slot 1 card, slot 2 empty) and MM sees two (05.08.2026).
  Under MM the mmcli branch is chosen earlier by iface proto; in QMI mode qmicli
  reads them. `none` would be doubly wrong. -> `qmi`.
- **Quectel RM520N-GL** (2c7c:0801) and siblings 2c7c:0800 (RM500Q/RM502Q), 2c7c:0900
  (RG500Q), 2c7c:0512, 2c7c:0620: `AT+QUIMSLOT?` -> `+QUIMSLOT: 1`, `AT+QUIMSLOT=1|2`
  -> OK (forum: switching back and forth also cures a registration that keeps
  dropping with one operator). Without the entry `simslot.sh` tried `AT^switch_slot`,
  `AT+GTDUALSIM`, `AT!UIMS`, `AT+CEISWITCHSIM`, none known, and slots were not read
  although the metrics profile showed the active slot (13.09.2026). The RM5xx
  profiles already read `AT+QUIMSLOT?`. EP06 is not in this group. -> `quimslot`.
- **SIMCOM SIM7600E-H**: one slot; `AT+SIMTYPE?` and `AT+GTDUALSIM` are silent. ->
  `none`.

## `esim_reset_after_switch <model> <vidpid>`: reset after enabling/disabling a profile

Per SGP.22 the eUICC issues a proactive REFRESH after a profile change and the modem
must re-read the card itself. Some firmwares do not: the profile is enabled in the
eUICC but the modem keeps using the old one ("switched, nothing changed"). A full
reset (`AT+CFUN=1,1`) fixes it.

Targeted, not global: a reset costs a USB re-enumeration and about a minute without
network, and where REFRESH works (FM350-GL: eSIM works without reset) it is a
regression.

- **SDX55 family** (T99W175, MV31-W, DW5821e: 05c6:90d5, 05c6:9025, 413c:81d7/81e0/
  81e4, 0489:e0b5, 1e2d:00b7/00b3/00b8/00b9): another working setup on the same modem
  (luci-app-epm) uses "Reboot Method: AT Command, AT+CFUN=1,1, /dev/ttyUSB2" as a
  standard step. -> `1`. Compal prototype on 05c6:90d5 / 1e2d:00b7 (matched by model)
  -> `0`.
- **T99W373 / MV32-W** (0489:e0f0, 1e2d:00f1-00f4): not verified, set by family. The
  cost is asymmetric: an extra reset costs a minute offline, a missing one looks
  exactly like the complaint that created this entry. -> `1`.
