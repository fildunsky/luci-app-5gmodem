# Band profiles (`modemband/`)

Each file in `root/usr/share/5gmodem/modemband/` is a shell profile named `<vidpid>` or `<vidpid><Model>` that `bands.sh` sources for the target modem (see [bands.md](bands.md)). A profile overrides the default stubs (`getsupportedbands`, `getbands`, `setbands`, the `5gnsa`/`5gsa`/`3g`/`2g` variants, `getsupportedmodes`/`getmode`/`setmode`, `getcelllock`/`setcelllock`, `get5gmode`, `getcaenabled`, `get256qam`, `getulca`, `getantports`) and sets flags (`_BANDS_APPLY_LIVE`, `_BAND_VIA`, `_BAND_READONLY`, `_BAND_RECONNECT_WARN`, `_CELLLOCK_WRITEONLY`). Files starting with `_` are shared family code; per-id files are thin wrappers. Rules common to all profiles:

- Never hard-code `_DEVICE`: `bands.sh` assigns the AT port of the target modem after sourcing (on a multi-modem router a profile's port is another modem's port).
- Supported lists are static fallbacks or cached modem answers and must work without a port: they are the way back from a band without coverage.
- `sms_tool ... at` prints the command echo and often exits 0 on ERROR; parse the answer line, not the echo, and verify writes by reading back.
- Return `Unsupported` (not empty) to hide a section.

## Profile index

| Files | Modem | Family file |
|---|---|---|
| 05c69025, 05c690d5, 1e2d00b3, 1e2d00b7, 1e2d00b8, 1e2d00b9, 105be0b0 | Foxconn T99W175 / Thales MV31-W / Dell DW5930e (SDX55); 105b:e0b0 is PCIe/MHI | `_qualcomm_sdx55_common` |
| 0489e0f0, 105be0d9 | Foxconn T99W373 / Thales MV32-W (SDX62), MBIM / PCIe | `_foxconn_mv32_common` |
| 05c690d6, 05c69063 | Compal RXM-G1 (custom firmware / factory "Tri Cascade VOS_5G") | 05c690d6 |
| 413c81d7, 413c81e0, 0489e0b5, 0489e0b4 | Foxconn T77W968 / Dell DW5821e (Snapdragon X20); e0b4 without eSIM | `_foxconn_t77w968` + `_foxconn_common1` |
| 0e8d7127, 0e8d7126, 2cb70104 | Fibocom FM350-GL / RW350-GL (GTUSBMODE 41 / 40); FM150 / FG150 / NL952 / FM160 | `_fibocom_fm350_common` |
| 8087095a, 2cb70007, 2cb7000b | Intel XMM Fibocom L850/L860 (mode 11 = 2cb7:000b) | `8087095a` (the other two source it) |
| 1199a001 | Sierra EM7345 (Intel XMM7160), read-only list | |
| 11999071, 11999091, 11999079, 413c81cc, 413c81cf, 413c81d0, 413c81d2, 1199c081 | Sierra EM7455/EM7565 (11999091; EM7590 1199c081 wraps it), Dell DW5816e/DW5818/DW5819, Lenovo EM7455 (MDM9x30) | 11999071 / 11999091 |
| 119990d3, 119990e3, 17cb0306_18d7, 17cb0308_18d7 | Sierra EM9190/EM9191 (SDX55), EM9291, EM9xxx PCIe | 119990d3 |
| 1bc71040 | Telit LM960 | |
| 1bc71070 | Telit FN990 | |
| 2c7c0121, 2c7c0306EP06-E, 2c7c0306EG06-E, 2c7c0512EM12-G, 2c7c6005, 05c69215 | Quectel LTE (EC21, EP06-E, EG06-E, EM12-G, EC200A-EL, EC20 on a Qualcomm id) | `_quectel_common` |
| 2c7c0620 | Quectel EM160R-GL (own `+QNWPREFCFG` code) | |
| 2c7c0800*, 2c7c0801, 2c7c0900, 17cb0308 | Quectel 5G (RM500Q/RM502Q/RM505Q/RG50xQ on SDX55, RM520N on 2c7c:0801, RM500U-CNV); 17cb:0308 is RM520N-GLAP on PCIe and sources 2c7c0801 | `_quectel_common2` |
| 1e0e9001 | SIMCom SIM7100E / SIM7600 / SIM8200 | |
| 12d11506, 12d11566 | Huawei E3272/E3372/E3276 (1566 = debug mode with AT ports) | 12d11506 |
| 2dee4d57 | MeigLink SLM770A-R | |
| 12864e28 | ASR PXA1826: Notion R281/R291, MegaFon/Yota C300-1 | `_zte_common` |
| 2cd20001 | MikroTik R11e-LTE (Marvell PXA1802) | |
| 216f0041, 216f0043, 216f0044, 216f0047 | Altair ALT3100 / ALT3800 (Yota, NTLM-500) | `_altair_lte_common` |

## Qualcomm SDX55 (AT^BAND_PREF)

`_qualcomm_sdx55_common` is shared by all USB compositions (six identical copies had already diverged; a composition changes port numbering and driver, not the AT set).

- Write is `AT^BAND_PREF=<RAT>,2,<list>` with the list unquoted. `enable=2` replaces that RAT's mask and survives reboot. Do not send a bare `AT^BAND_PREF` first: it resets the masks of all RATs to factory, so changing 4G turned all 5G bands back on (MV31-W, 2026-08-17). The quoted form is silently ignored.
- Answer lines have a leading space (`  WCDMA,Enable Bands :1,2,4,...`), so the awk patterns have no `^` anchor; with one, 3G parsing returned nothing.
- Supported list = union of Enable and Disable sections of `AT^BAND_PREF?`, cached in `/tmp` until reboot; OEM firmware with a reduced set otherwise showed bands the hardware lacks and the full-list write failed with ERROR. n25 is dropped from the fallback (no live dump contains it, one rejected band rejects the whole list).
- 3G is mask style via `WCDMA` in the same command (list equals the module spec: 1,2,4,5,6,8,9,19).
- Network mode `AT^SLMODE=1,<mask>`: 1=WCDMA, 2=LTE, 4=NR5G, 0=Auto (1,3 WCDMA+LTE, 1,6 LTE+NR5G, 1,7 all). T77W968 uses the same command with different numbers; do not share the encoding.
- Cell lock `AT^LTE_LOCK=<pci>,<earfcn>`: PCI first, the reverse of our `cell <arfcn> <pci>` contract (FM350 takes ARFCN first). It takes effect only after `AT+CFUN=1,1`; until then the read says "Have not set cell lock before". Survives reboot. `AT^WCDMA_LOCK?` -> `(uarfcn,psc)`.
- `AT^NR5G_LOCK=<pci>,<arfcn>` is written by symmetry with LTE_LOCK (no live dump of a write); on ERROR the profile returns Unsupported and does not restart the module.
- Detection of "no such command": echo lines start with `AT`, ERROR means unsupported. Grepping `LTE_LOCK` matched the echo, returned `off` on firmware without the command, and the lock button rebooted the modem for nothing.
- CA status answer is `CA_FLAG: ENABLE` / `CA_FLAG: DISABLE` (check DISABLE first, it contains ABLE).
- Compal RXM-G1 shares 05c6:9025, 05c6:90d5 and 1e2d:00b7. Those wrappers detect Compal via `iscompal.sh` (descriptor via debugfs or sysfs, model via QMI/mmcli; no AT port is known at source time) and hand over to `05c690d6`, otherwise the UI shows dead AT buttons. PCIe 105b:e0b0 skips this check: the Compal prototype only shares USB ids.

## Foxconn T99W373 / MV32-W (SDX62)

From the MV32-W AT Command Reference 80781ST11134A Rev 3, sections 15.20-15.40, without hardware in hand. Differences from MV31:

1. Two NR masks, `NR5G_NSA` and `NR5G_SA`; bare `NR5G` means both. MV31 parsing would leave SA empty.
2. The manual uses `+` (`AT+BAND_PREF`) while examples answer with `^`. `_mv32_at` tries `+` then `^` on ERROR/empty.
3. `BAND_PREF` applies without reboot (`_BANDS_APPLY_LIVE=1`).

- Sections of `BAND_PREF?` may be printed on one line and long 5G lists wrap; the parser splits before each header and keeps continuation lines. One answer is cached for 5 s in `/tmp/5gmodem/bands_*` (eight reads per page build).
- An empty list is refused: an empty tail means "reset to factory".
- `AT+SLMODE=1,<mask>` same bit encoding as MV31 (1=WCDMA, 2=LTE, 4=NR5G).
- `AT+CA_ENABLE` is inverted: 0 enables, 1-255 disables (read only here).
- `AT+NR5G_MODE`: 0 NSA+SA, 1 NSA only, 2 SA only; no "off".
- Cell lock: `AT+LTE_LOCK=<pci>,<earfcn>[,...up to 8 pairs]`, `AT+WCDMA_LOCK=<uarfcn>,<psc>`, `AT+NR5G_LOCK=<band>,<scs>,<nr_arfcn>,<pci>`. Applied only after `AT+CFUN=1,1` (`AT+RESET` re-enumerates USB). NR lock is read but not set: band and SCS are not in the contract and a wrong pair leaves the module in no service.
- Antenna ports from `AT+DEBUG?` (`lte_ant_rsrp:rx_diversity:15 (-77.0dBm,-256.0dBm,...)`, NR values after `nr_rsrp`); `-256.0dBm` and `NA` are "no measurement". Value and bracket may be on different lines, parse as one string.

## Foxconn T77W968 (AT^SLBAND)

One module under 413c:81d7, 413c:81e0 (Dell) and 0489:e0b5/e0b4 (Foxconn); identical per-id files left the third id without a profile.

- Supported list from `AT^SLBAND=?` (`^SLBAND: LTE,(1,2,3,...,66)`), varies by firmware (some lack 12/17/42/43/48); static list only as fallback. The fallback needs 48, otherwise a reset silently disabled it.
- `_foxconn_common1` parses only the `LTE,Enabled` section; matching `/LTE/` also took `LTE,Disabled,...` and showed disabled bands as enabled.
- `AT^SLMODE=1,<n>` with its own numbers: 4 Auto, 14 WCDMA, 30 LTE, 35 WCDMA+LTE, 6 LTE+NR (not offered: X20 is LTE Cat.16, no 5G). On T99W175 `1,4` is NR5G only. The answer is `^SLMODE:1,30-LTE Only`, take only the number.
- `AT^ULCA?` -> `ULCA is enabled/disabled` (sometimes without spaces), match by substring. No disabling form is known.
- AT under ModemManager drops the session on this module (gated in `bands.sh`).

## Compal RXM-G1 (mmcli)

05c6:90d6 custom firmware ("Tri Cascade Inc. VOS_5G", revision contains RXMG1); 05c6:9063 is the factory composition (SG500M2-X, firmware `RXMG1.20.00.326.73`) with no AT ports at all.

- No LTE/NR band-lock AT command (`AT$QCCLAC`, `AT$QCBANDPREF=?` show only legacy 2G/3G/WLAN), no tty answers AT. `_BAND_VIA=mmcli`, `_DEVICE` unset.
- `mmcli --set-current-bands` replaces the list across all RATs; `setbands*` keep bands of other technologies (`_mm_other_bands`) and replace only `eutran-*`/`ngran-*`. mmcli's author warns that this option is risky and a segfault on a QMI modem is reported; it worked on this unit.
- Reading on kernel proto uses `qmicli --nas-get-system-selection-preference` (LTE, extended LTE with B46/48/66/71, NR). No write path: no band TLV in the CLI.
- Mode through `--set-allowed-modes`/`--set-preferred-mode`; without mmcli the mode is read via QMI.
- Lists are static from config so buttons survive a hung mmcli. MM reports 63 supported bands including ngran.

## Fibocom FM350 (AT+GTACT)

`_fibocom_fm350_common`, ids 0e8d:7127 / 0e8d:7126. Manual: FM350 AT Commands V2.10, 11.1.14.

- Capabilities from `AT+GTACT=?`: `(rat),(pref),(pref),(),(UMTS),(LTE),(),(),(NR)`; LTE values 1xx (101=B1..171=B71), NR 5xx/5xxx (501=n1, 5071=n71, 5079=n79), UMTS 1..10 without prefix. Cached in `/tmp` only when groups came back.
- `<rat>`: 1 UMTS, 2 LTE, 4 LTE/UMTS, 10 Auto, 14 NR, 16 NR/WCDMA, 17 NR/LTE, 20 NR/WCDMA/LTE. Preferences 2 WCDMA, 3 LTE, 6 NR must belong to the chosen rat. Mode 10 is reported as 20 (Note 6).
- `setmode` sends only rat (+preferences): the modem substitutes allowed bands itself; an explicit list with bands foreign to the rat is rejected with CME.
- 4G-only modules (FM350-GL-16, RW350-GL-16) share the id; detected by an empty NR group in `GTACT=?`. Using the default NR list showed non-existent 5G rows ("setbands5gnsa - rejected").
- Band write with fallbacks: `AT+GTACT=<rat>,<p1>,<p2>,<bands>` as read from `GTACT?`; in LTE-only mode the read is `2,3,,...` and `AT+GTACT=2,3,,107` is silently ignored. Manual Note 1-2 allows `AT+GTACT=,,,<bands>`, which RW350-GL-16 rejects; the working form there is `AT+GTACT=2,3,3,<bands>`. Read back and try the next form on mismatch. Spaces are stripped (`+GTACT: 20, 6, 3` made the write ERROR). `0` restores the factory set.
- Applies live but breaks PDP: `_BANDS_APPLY_LIVE=reconnect`, `_BAND_RECONNECT_WARN=1` (~15-20 s without IP until fibocom proto re-dials).
- `_fm350_reapply_bands` after an airplane cycle: CFUN=4 leaves the modem on one band with secondary carriers dead (once without internet). Rewriting the same list does not help; only `AT+GTACT=<rat>,0` re-aggregates. It is used only when the user's saved set (`save_band`) equals the full capability set; otherwise the saved set is written. Reading the current set after CFUN is wrong: CFUN already reset it to full, which once wiped a user's restriction.
- 3G is mask style, shown only when the rat includes WCDMA (1/4/16/20). One `GTACT?` read per process.
- Cell lock `AT+EMMCHLCK=<on>,<rat>,<gsm1900>,<arfcn>[,<pci>,<lock_mode>]`; `=?` gives `(0-1),(0,2,7),(0,1),(0-46589),(0-511)`, so only LTE (7). `lock_mode=3` (idle and connected; 0 releases on traffic). Requires CFUN=4 for both lock and unlock; the old lock is cleared explicitly first; without PCI the form is `=1,7,0,1802,,3`. After reboot the lock stays but the read answers 0.
- 5G mode `+E5GOPT` mask: bit0 always set, 2 SA, 4 NSA (7 both, 3 SA, 5 NSA, 1 off); taken into effect only after an airplane cycle.

## Intel XMM L850/L860 (AT+XACT)

`8087095a`; `2cb70007` and `2cb7000b` source it.

- `AT+XACT=<rat>,<p1>,<p2>,<bands...>`; rat 1=3G, 2=4G, 4=3G+4G (no 2G radio); 3G bands as is (1,2,4,5,8), LTE 100+N. The list from `AT+XACT=?` depends on the firmware cust file (B46 appears against documentation). XACT without a band list resets the band selection, so both 3G and LTE tails are always preserved.
- Applies live but silently kills the PDP session: `reconnect`.
- `AT+GMM`: filter the `+GMM:` line, otherwise awk printed the echo/OK.
- Cell lock `at@sic:freq_lock(sim=0,rat=3,band,enable,earfcn,pci)`, only through airplane mode. There is no read form: `getcelllock` returns `off`, `_CELLLOCK_WRITEONLY=1`. Unlock writes factory values `4294967295,65535`: the modem stores them in NVM, and zeros mean PCI 0, with which it falls to 3G. PCI 65535 = any cell on the frequency (keeps CA), so a frequency lock never sends 0; a cell lock passes a real PCI 0 through unchanged. Unknown band is 255.
- The cycle must end with `AT+CFUN=15` (silent full reset), not `CFUN=1`: after freq_lock `CFUN=1` leaves the radio half-reset in endless network search (L860-GL-16 fw 18601, 2026-08-17). CFUN=15 may re-enumerate USB; the watchdog recovers ports.

## Sierra (AT!BAND)

### EM7455 / EM7565 family (11999071)

- `AT!ENTERCND` password is `A710`, Fujitsu-branded modules use `F710`, a wrongly changed password matches neither. Both are tried; the working one is cached. Without it `AT!BAND?` returns ERROR and the buttons vanished silently.
- The custom band set index 10 is not confirmed on MDM9x30 (`AT!BAND=?` shows 00..0c used); on ERROR the first free index from `=?` is taken, and `AT!RESET` is not sent when the write failed. After its own `AT!RESET` the profile touches `/tmp/5gmodem/selfreset.$$`; `_band_write` then skips the restart it would otherwise run (`reboot_modem.sh soft`, itself an `AT!RESET` on Sierra), so the module is not reset twice. A file, not a variable, because `setall` runs the profile inside `$(...)`.
- `AT!SELRAT` (needs ENTERCND): `00` Automatic, `01` UMTS only, `06` LTE only, `11` UMTS+LTE; ids are two-digit exactly as the command takes and prints them. The read can be `Unknown RAT mode...`, so the number is validated. Writes are verified: on EM7565 OK without effect is common, some units ERROR on `=06`.

### EM9190 / EM9191 / EM9291 (119990d3)

Source: EM9 Series AT Command Reference 41113480 Rev 11, `!BAND`; mask layout matches the live "00, All bands" group exactly (GW `100600000FC00000`, LTE `0000A7E2BB0F38DF 0000000000000042`, NR `000081A0090808D7 0000000000007042`). The profile exists because under ModemManager the EM9190 AT answers come truncated (MM polls ttyUSB0 itself), so the vendor path must work on any proto.

- Own group at index 0x10 (factory sets occupy 00..0F; 00 All bands). The group name is not the app name: it looked like a firmware factory profile.
- 64-bit masks are built per nibble: busy awk numbers are doubles and lose precision above 2^53, while 3G needs bit 60 (B19). LTE/NR mask k covers bands (k-1)*64+1..k*64 (LTE has 4 masks, 3rd/4th always zero; NR has 5). 3G (GW) uses the historical Qualcomm layout (B1 at bit 22, B19 at 60), taken from the "All bands" mask.
- Writes need ENTERCND (the flag is set only on a confirmed OK; an empty answer is not an error but is retried). The group is written with three commands, each with the full list of its RAT (a create command fills only one RAT's masks); GW and LTE are separate commands (`RAT=0` one mask, `RAT=1` two; the combined 5-mask form is rejected whole). ~1 s pause between select and extended commands per the reference. Every answer is checked; any non-OK makes `_band_apply` fail (before, failures were invisible and the modem ended up on factory "0C, NR5G ALL"). The result is verified by the active group and LTE mask.
- An empty 4G set is refused: EM9190 is NSA, and CFUN=1,1 on "5G only" sends it into a soft boot loop without an AT console, curable only by power removal.
- "Current bands": while the factory "All bands" group is active, `AT!SDPREF?` (operator-allowed bands by name; starts directly with `RATs :`) is shown, otherwise our group's masks. `!BAND` edits do not affect `!SDPREF`.
- Reset selects the factory "All bands" group and keeps ours.
- `AT!SELRAT` on X55: 00 Auto, 01 WCDMA, 06 LTE, 11 WCDMA+LTE, 20 NR, 21 LTE+NR, 22 WCDMA+NR. The vendor warns against restricting both `!BAND` and `!SELRAT` (e.g. NR-only bands with LTE-only RAT hangs registration); the profile logs a warning instead of refusing.
- Answers are cached in a `5gmodem_bands_*` file (four getters run in four subshells); truncated answers (no group name line) are not cached.

### EM7345 (1199a001)

Intel XMM7160 with a Sierra label: `!` commands do not answer (`AT!ENTERCND="A710"` -> ERROR) and `AT+XACT` was never confirmed on it, while a misread XACT on XMM rebuilds the band set. Only a reference list (from a live `mmcli`: LTE 1,2,3,4,5,7,8,13,17,18,19,20) with `_BAND_READONLY=1`; control lives in ModemManager.

## Telit (AT#BND)

### LM960 (1bc71040)

- `AT#BND=?` -> `(0),(0-11,17,18),(A7E0BB0F38DF),(42)`: GSM, UMTS combo ids, LTE hex mask (bit N = band N, 48 bits), LTE ext. Supported list comes from the modem (the old static list missed bands that `getbands` returned).
- Field 4 "LTE band ext" has its own numbering, not bit=band: 2 = B66, 0x40 = B71 (manual 80568ST10869A Rev.7 p.219). B66/B71 must not go through `bandstohex`. LTE and ext cannot both be 0. Firmware without field 4 gets the 3-parameter form; with it, the user's ext value is written (before, B66/B71 could not be removed).
- 3G is a combination id (field 2), table from the manual p.218-219, ids 12-16 and 19 are not accepted by this unit. Labels are sorted by frequency and buttons by number of bands, the id is unchanged. Writing 3G preserves other fields.
- Mode via `+WS46`: `(22,28,31)` = UTRAN, E-UTRAN, GERAN/UTRAN/E-UTRAN (31 labelled Auto, no 2G radio). Applies live, context survives (`_BANDS_APPLY_LIVE=1`).
- `#LAPS` antenna ports: rsrp/rsrq pairs for 2 or 4 ports (`-111,-11,-134,-19` = port 1 without antenna), LTE only.
- `ATI` returns product code 332; the model comes from `CGMM`.

### FN990 (1bc71070)

`#BND: <GSM>,<UMTS>,<LTE 1-64>,<LTE 65-128>,<NSA 1-64>,<NSA 65-128>,<SA 1-64>,<SA 65-128>[,...]`; the number of fields varies (8 or 10). Each half is a plain bit mask (upper half N+64), e.g. `0,21,A3E2BB0F38DF,42,100080800D7,7042,0,0,0,0`: 0x42 = B66+B71, 0x7042 = n66,n71,n77,n78,n79. A write replaces only its pair and returns all other fields verbatim. Capability groups are split on `),(`. No 3G (combo table unknown). `+WS46=?` on FN990A28 M0R.100005 is `(28,36,37)`; Auto is the widest accepted value (38, else 37, 31, 28) and is not duplicated in the list. Fallback lists from the FN990 HW Design Guide 1VV0301752 Rev.3. Answers are cached in process memory only (a file cache would outlive a modem swap on the same port).

## Quectel LTE (AT+QCFG="band")

`_quectel_common` for EC2x/EG/EP/EM:

- `at+qcfg="band",<gsm+wcdma>,<lte>,<tdd>`; 0 means "do not change" per argument. 2G and 3G share the first argument, so each write keeps the other half (EC21-E: 0xd3 = GSM900 0x1 + GSM1800 0x2 + WCDMA B1 0x10 + B5 0x40 + B8 0x80; GSM850 0x4, GSM1900 0x8; bits above 0x80 unverified).
- Writes accept hex only without `0x` (`0x93` is silently ignored), reads return `0x`.
- Parse the `+QCFG:` line, not the echo (the mask was always 0). A collision can cut the answer to `+QCFG: "band",0x`, and `$((0x))` kills the whole script in ash; digits after the prefix are required.
- Mode via `nwscanmode` 0 Auto, 1 GSM, 2 WCDMA, 3 LTE, trailing `,1` applies immediately. Opt-in per model with `_QMODES`, `_DEFAULT_2G_BANDS`, `_DEFAULT_3G_BANDS`. EP06-E has no 2G (GSM bits empty in `0x8d0`).
- Cell lock `AT+QNWLOCK`, two firmware forms, chosen by which one answers (revisions overlap, ATI does not tell): Rev4 `"common/4g",1,<earfcn>,<pci>` / `,0`; Rev3 `"common/lte",1,<earfcn>,0` (frequency) / `,2,<earfcn>,<pci>` (cell) / `,0`. Rev4 has no frequency-only form and PCI 0 would be taken literally. The lock is lost on every modem reboot (hence uci stamp and restore). Form and negative result cached in `/tmp`.
- 256QAM: `AT+QCFG="256qam"` before EP06ELAR04A04M4G, `"dl_256qam"` from it on; chosen by answer, cached.
- EC21 identifies itself as "Android" in USB descriptors; `bands.sh` falls back to `AT+CGMM`. EC21-E bands B1 B3 B5 B7 B8 B20 confirmed by QMI; other EC21 variants need their own model file. EC200A-EL write is unverified.

## Quectel 5G (AT+QNWPREFCFG)

`_quectel_common2`:

- `lte_band`, `nsa_nr5g_band`, `nr5g_band`, `mode_pref` take effect immediately (manual 5.24.2-5.24.5; RM551E-GL: NSA 77<->78 without reconnect). SDX55 models 2c7c:0800 are unverified and set `reconnect`.
- `_qnw_write` skips unchanged lists (NVM wear) and verifies by reading back: a successful write sometimes prints nothing.
- `mode_pref` values are words (`AUTO`, `LTE`, `NR5G`, `LTE:NR5G`); numeric ids are exposed because `id:label` is split on the first colon. Match `LTE:NR5G` before its parts. RM520N resets `mode_pref` to AUTO on reboot (restored by `save_mode`).
- Cell lock `AT+QNWLOCK="common/4g",1,<earfcn>,<pci>` plus `"save_ctrl",1,1` to survive reboot; `arfcn` is refused (PCI 0 would be literal). Up to three cells, first one shown. No 5G lock (no confirmed apply). No live read dump: unparsed answers return Unsupported.

## SIMCom (AT+CNBP)

1e0e:9001 is shared; branch on cached `AT+CGMM`:

- SIM7100E / SIM7600: `AT+CNBP=<mode>,<lte_mask>` (two parameters; a three-parameter write is silently ignored; the third field of the read is not the selection). 64-bit masks through the dispatcher's `bandstohex` (the old nibble math produced 0xA0000080C05 instead of 0xA0000800C5). SIM7600 has no `AT+CSYSSEL` (it used to fall into the 8200 branch and called itself SIM8200EA-M2).
- SIM7600E-H capabilities come from `qmicli --dms-get-band-capabilities` (1,3,5,7,8,20,38,40,41); the CNBP mask is a preference ("all allowed").
- First CNBP mask = GSM+WCDMA: GSM bits 7 DCS1800, 8 EGSM900, 9 PGSM900 (cleared with 900), WCDMA bits Qualcomm standard (22 = B1, 49 = B8; SIM7100E factory 0x0002000000400180). Firmware stores any bits, so capabilities are kept per model.
- `AT+CNMP`: 2 Auto, 13 GSM, 14 WCDMA, 19 GSM+WCDMA, 38 LTE. Firmware answers 1 in auto mode (not documented); mapped to 2.
- CNBP and CSYSSEL are preferences applied within seconds; CFUN=4->1 reverts them, so `_BANDS_APPLY_LIVE=1`.
- SIM8200 / SIM7906: `AT+CSYSSEL`. SIM7100 must return Unsupported for 5G.

## Huawei and MeigLink (AT^SYSCFGEX)

- Huawei E3372 (12d11506, debug mode 12d11566): mode is the first `syscfgex` field: `00` all, `01` 2G, `02` 3G, `03` 4G, concatenated by preference (`0302`). Mode change keeps bands and roaming. HiLink mode is handled by the API path in `bands.sh`.
- MeigLink SLM770A-R: `^SYSCFGEX: "03",2000004400000,3,2,1A0080800D5,0,,,0`; LTE mask is field 6 with `-F[:,]`, plus a second field for bits 65-128 that must be passed back. Current values are re-sent as is: Huawei constants (3FFFFFFF,2,4) would overwrite access mode, WCDMA/GSM mask, roaming and service domain. All-ones mask = everything enabled.
- MeigLink cell lock `AT^CELLLOCK=<enable>[,<rat>,<lock_type>,<arfcn>[,<pci>]]` (rat "02" WCDMA, "03" LTE; type 0 frequency, 1 cell; `=0` removes all). Manual 8.12: set the LTE lock inside `at+cfun=0`/`1`; removal takes effect after restart.

## ZTE and ASR (AT+ZNLOCKBAND)

- `AT+ZNLOCKBAND=1,0,<hex>,0`, bit N-1 = band N (ASR PXA1826 behaves like ZTE: `1,0,5,0` = B1+B3, `1,0,8000001,0` = B1+B28). Read `+ZNLOCKBAND: 40,480000`: first field is the LTE mask (B7), second unknown.
- PXA1826 kits differ (Russian C300-1: B1,B3,B7,B20,B38,B40; Philippine R281 adds B5,B8,B28,B41): supported = base set plus anything ever seen enabled (`band_full`); "all bands" means everything known, not the base set.
- Cell lock `AT*CELL=<mode>,<act>,<band>,<earfcn>,<pci>` (mode 0 off, 1 frequency, 2 cell; act 3 LTE; band 0 accepted for cell, band number computed from EARFCN for frequency). Applies immediately; CA disappears while locked.

## MikroTik R11e-LTE (AT*BAND)

- `AT*BAND=<mode>,<GSM>,<UMTS>,<LTE TDD>,<LTE FDD>,<roaming>,<domain>,<priority>`, decimal masks; FDD bit N-1 = band N, TDD bit N-33 = band N (RouterOS sends `AT*BAND=15,78,147,160,524487,0,2,0`: 524487 = B1,2,3,7,8,20; 160 = B38,40). Written between CFUN=4 and CFUN=1 like RouterOS; data session drops (`reconnect`). Other fields are taken from the modem.
- Cell lock `AT*Cell=<mode>,<net>,<band>,<freq>,<pci>` (band empty), lost on modem reboot; the dial proto re-applies it (`fibocom.sh`, `_r11e_prepare`). Unparsed read returns `off` with `_CELLLOCK_WRITEONLY`.

## Altair (AT%SETCFG="BAND")

ALT3100/ALT3800 (216f:00xx), LTE only, no hardware in hand; syntax from Quanta LI17x "Altair Proprietary AT commands", answer formats from the ModemManager Altair plugin (firmware sometimes inserts zeros, filtered).

- `AT%BANDCAP` (calibrated capabilities), `AT%GETCFG="BAND"` (allowed), `AT%SETCFG="BAND","3","7"` (only bands from BANDCAP). Query form varies (`%BANDCAP`, `%BANDCAP?`, `%BANDCAP=`), tried in turn.
- NTLM-500 answers none of them: capabilities = widest set ever seen enabled (`band_full`; Skylink H1 factory 3 7 20 31). The negative marker uses the common cache prefix and expires after 30 min (a single busy-port poll once narrowed the list until router reboot, and the key was a tty basename reused by other modems).
- The port is mandatory: with empty `_DEVICE`, `sms_tool -d at ...` takes "at" as the device.
- Writes go to NV and apply on module restart: verified by reading NV, then `AT+CFUN=1,1`, else `ATZ` (as the MM plugin), else a radio cycle. The profile restarts itself and reports `_BANDS_APPLY_LIVE=1`. No restart loop: restore and setbands write only on difference.
- Antenna ports from `%MEAS="0"`.
