# Foxconn / Dell / HP modules: T77W968 (DW5821e), T99W373 (MV32-W), T77W595 (HP lt4120)

The per-modem metric profiles for Foxconn-made LTE/5G modules sold under Foxconn, Dell, HP and Thales IDs. Each module family has one real profile, and the other USB IDs are one-line wrappers that source it. This avoids copies that drift apart. `413c81e0` was once a byte copy of `413c81d7` that kept bugs already fixed in the original (lexical temperature sort, RSSI read from `rx_diversity:`, hex TAC). For the SDX55-based T99W175 / DW5930e / MV31-W see [qualcomm-sdx55.md](qualcomm-sdx55.md).

## Supported USB IDs

| USB ID | Module | Profile file |
|---|---|---|
| 413c:81d7 | Dell DW5821e (Foxconn T77W968, Snapdragon X20 LTE) | `413c81d7` |
| 413c:81e0 | Dell DW5821e-eSIM (T77W968) | `413c81e0` → `413c81d7` |
| 0489:e0b5 | DW5821e / DW5821e-eSIM under the native Foxconn ID | `0489e0b5` → `413c81d7`, plus own `MODEL` |
| 0489:e0b4 | Foxconn T77W968 LTE without eSIM, native Foxconn ID | `0489e0b4` → `413c81d7` |
| 0489:e0f0 | Foxconn T99W373 / Thales Cinterion MV32-W (SDX62), MBIM composition | `0489e0f0` → `modem/_foxconn_mv32_common` |
| 03f0:9d1d | HP lt4120 Snapdragon X5 LTE (Foxconn T77W595) | `03f09d1d` |

All T77W968 IDs run the same firmware (`T77W968.F1.0.0.5.2.GC.013`) with the same AT set (`at^temp?`, `at^ca_info?;^debug?`, `AT^VERSION?`). Before `0489e0b5` existed, a DW5821e-eSIM under 0489:e0b5 in MBIM mode showed dashes for name, firmware, TAC, band and temperature while working normally. Before `0489e0b4` existed, auto-setup also pushed that module into MBIM.

## T99W373 / MV32-W

0489:e0f0 comes from the kernel table (`drivers/usb/serial/option.c`: "Foxconn T99W373 MBIM", `RSVD(3)`). Interface 3 is the data channel, AT appears on one of the remaining ttyUSB ports, and `option` binds by itself without our `new_id`. The same module also exists on PCIe (105b:e0d9) with the same AT set, so all metric logic lives in `modem/_foxconn_mv32_common` (see below). The MV31 family had no common file, and six copies drifted apart.

### Metrics (`modem/_foxconn_mv32_common`)

Shared by the USB wrapper `modem/usb/0489e0f0` and the PCIe/MHI wrapper `modem/pci/105be0d9`; only the port name and the way the data protocol is found differ.

- **Command prefix.** The MV32 manual names commands with `+` while its examples answer with `^`; which one a build accepts varies. The profile tries `+` first and falls back to `^` on ERROR or an empty answer.
- **Temperature:** `AT+TEMP?` gives TSENS / PA / skin sensor; the card shows the maximum.
- **Thermal throttling:** `AT+THERM_LVL?` → `LTE MDM LVL: 8 / NR MDM LVL: 4`. LTE uses 0..11 (255 = limited service), NR 0..10 (254/255). The card has four steps 0..3, so the profile maps the manual's envelope table (section 15.59) onto them; the boundaries are ours. Values are compared as numbers after `gsub`: busybox awk compares a string-typed value lexically, so "8" >= "254" was true and step 8 became "critical". Negative cache: builds without the command would otherwise pay one extra exchange per poll.
- **`^DEBUG?` is parsed as key:value tokens, not by line.** The manual shows three layouts of the same answer (`pcell:lte_band:3,lte_band_width:20.0MHz`; `pcell: lte_band:7` with the width on the next line; levels with or without the `lte_` prefix), so field-position parsing (as in the MV31 profiles) breaks. Per-chain brackets are cut out first (their commas would split tokens). Section markers `pcell`/`scell`/`nr_sccN` switch the current section, either as a token of their own or glued to the first key. Only whitelisted keys with safe values are printed, because the output goes to `eval`. Section counters are initialised explicitly: an uninitialised awk variable concatenates as empty, the key became `_band` instead of `0_band`, and the NR carrier vanished in NSA.
- `RAT: LTE` may come as a separate token (not every build has a space after the colon); without handling it a 3G answer was parsed as LTE.
- **NR is its own section.** `nr_*` fields carry the prefix both in the SA primary cell and in `nr_scc1`, `nr_scc2`; without numbering, `nr_scc1` overwrote the primary carrier.
- **Technology label from the carriers actually held**, not from `+COPS` AcT 13 ("EN-DC capable"): on plain LTE the MV31 card showed "5G". 3G is left to the framework: in WCDMA the answer prints `band:1` without a prefix, which would be read as an LTE band. If `^DEBUG?` gives nothing while registered (port busy), the framework label is kept.
- **Cell identifiers** from `^DEBUG?` are used only when the framework has none from `+CREG`. Values are printed with units (`dBm`), as in other profiles.
- **5G SA:** the serving cell is NR and there is no `pcell`; it is the primary carrier, not "second carrier" (the MV31 profiles left RSRP/RSRQ empty there).
- **Secondary carriers** get real per-carrier levels (S1RSRP/S1RSRQ/S1SINR...); the MV31 profiles parsed and dropped them (leftover from the removed `addon` API). With EN-DC the NR primary (`_DN0`) is secondary to LTE. The band string uses `+` within a generation and `/` between generations, like FM350 (MV31's `sed 's,/,+,'` replaced only the first separator).
- **Antenna ports** from the same `^DEBUG?`: `lte_ant_rsrp:rx_diversity:15 (-77.0dBm,-256.0dBm,...)`. `rx_diversity` is a bit mask of active chains (15 = four), levels are printed for all chains and the position is the chain number (checked with mask 3). `-256.0dBm` and `NA` mean "not measured". Some builds print the mask without the prefix; in 3G the same line from `wcdma_ant_rscp` carries RSCP, so the block is not built there. No diversity verdict with fewer than two measured levels. In SA there is no `lte_ant_rsrp`; chains follow `nr_rsrp`.
- **Neighbour sectors:** `AT+VZWRSRP?`/`AT+VZWRSRQ?` (sections 15.32/15.33). RSRP: prefix only on the first line, one `<pci>,<earfcn>,"<value>"` triple per line; RSRQ: all triples on one line. Values are in tenths, quoted (`"-1082"` = -108.2 dBm). RSRQ is joined to RSRP by (pci, earfcn), not by order. Negative cache when the commands are missing.
- **Model and firmware:** take the first meaningful line only. Echo is on from the factory and `+CREG=2`/`+CEREG=2` URCs arrive in the middle of a read (the MV31 name once became `Thales AT MV31-W AT +CREG: 0 +CEREG: 0`). Lines starting with `AT`, `+` or `^` are not data.
- **Data protocol from sysfs**, not by grepping `/sys/kernel/debug/usb/devices` (debugfs is not mounted on some builds). On the PCIe wrapper the path is not a USB path; the wrapper sets the protocol itself.

## DW5821e / T77W968 (`413c81d7`)

### Metric sources

| Command | Field(s) |
|---|---|
| `at+temp` `xo_therm_buf:` | `TEMP` (only digits are kept, because the reply `"xo_therm_buf:33",` made `xargs` fail with "unmatched double quote") |
| `at^temp?` (fallback) | `TEMP`: numeric maximum of `PA`, `TSENS`, `XO`, `MODEM*` (firmware 5.2 prints `PA: 44C` / `TSENS: 37C`; a lexical sort used to put `9C` above `37C`) |
| `at^ca_info?;^debug?` `TAC:` | `T_DEC` / `T_HEX` |
| `RSSI:`, `RSRP:`, `RSRQ:` | levels (`_dbg_val`) |
| `RS-SINR:`, `RS-SNR:` | `SINR` (RS-SNR wins when both are present) |
| `RI:`, `CQI:`, `Tx Pwr:` | `RI`, `PMIMO` (=RI when 1..4), `CQI`, `TXPOWER` |
| `BAND:`, `BW:`, `eNB ID(PCI):`, `EARFCN` | `PBAND`, `PCI`, `EARFCN` |
| `SCC<n> info:` + `SCell<n>:` blocks | `S<n>BAND`, `S<n>EARFCN`, `S<n>PCI`, `S<n>RSRP/RSRQ/RSSI/SINR` |
| `AT^VERSION?`, then `ati` | `FW` |
| `AT+GSN`, `AT+CIMI`, `AT+ICCID` | IMEI, IMSI, ICCID (trailing `F` padding stripped) |
| debugfs `usb/devices` | `PROTO`, `MODEL` (Manufacturer/Product) |

### TAC is decimal

The `TAC:` in `^DEBUG?` is **decimal**. Eight live replies (5090, 27889, 40108, 8004, 177, 7814, ...) contained no hex digit at all. It used to be read as hex and showed the wrong TAC (0x5090 = 20624 instead of 5090). `0` and `65535` are "no network" sentinels.

### Two level-line formats

- Firmware 5.2: `RSRP: -100.2dBm rx_diversity: 15 (...)`
- Firmware 4.2: `RSSI: rx_diversity: 1 (-73.0dBm,-214748364.-8dBm)`, where the number is only in the brackets and `$2` returned `rx_diversity:`.

`_dbg_val` takes the first number with a `dB`/`dBm` suffix and drops the empty-chain value `-214748364`. Units are inconsistent even for one field (`Tx Pwr: -7.0dB` vs `Tx Pwr: 9.0dBm`), so `_dbg_num` keeps the bare number. `Tx Pwr: -` means "not transmitting now" and leaves the field empty.

### RI is the real MIMO indicator

On this module four aggregated carriers with `RI: 1` mean SISO. RI is copied into `PMIMO` (the page's "MIMO N×N" badge counts layers).

### 3G detection

- In 3G (and without service) the reply starts with `Active channel (DL): 10563`, with no `RAT:`/`EARFCN`. Both LTE slices are empty, so the profile falls back to `Active channel`.
- Some firmwares start with `RAT:WCDMA`, so the LTE slice is not empty. The **first** `RAT:` line decides, because the firmware can print several slices in a row (`RAT:LTE`, then `RAT:WCDMA`, then an empty one). Without this, `BAND: 1` went through `band4g` and the card showed "LTE | B1" on a 3G network.
- In 3G, `BAND:` (for example 80) is not an LTE band and is not passed to `band4g`. `RSCP` comes from `_dbg_val RSCP`, because the first plain number in `RSCP: rx_diversity: 3 (...)` is the chain mask. `ECIO` is taken as is, and PSC stands in for PCI (only the first PSC/ECIO pair, which is the serving cell).
- `STATUS: ...DEREGISTERED...` clears all level fields.

### Antenna ports

The same `rx_diversity` line as on SDX55, with the bitmask, direct order, -160..-20 dBm filter and the two-level minimum for a verdict (see [qualcomm-sdx55.md#antenna-ports](qualcomm-sdx55.md#antenna-ports)). Extra placeholders seen here: `-214748364.-8dBm` and garbage such as `-531.5dBm`. The pattern uses a character class `RS[CR]P` instead of `\|`, because busybox sed has no BRE alternation.

### Other details

- `eNB ID(PCI): 0-0(0)`, `4294967295...` and `-1-...` are sentinels without registration.
- TAC is derived from LAC only when it is still empty. An unconditional copy once overwrote the real TAC with the GSM-domain LAC.
- `TAC_DEC` is computed from `TAC_HEX` only when it is real hex. A `-` placeholder in `$((0x-))` threw "arithmetic syntax error".
- Firmware: `AT^VERSION?` comes first. The full version is `T77W968.F1.0.0.5.2.GC.013.050`, but ATI splits it and the `.050` tail lands on the next line. Only the first whitespace-separated token is kept: ATI prints `T77W968.F1.0.0.5.2.GC.013  1  [May 31 2021 08:00:00]`, and the date used to end up in the card.
- The USB ID for protocol and model lookup comes from sysfs of the polled device, because the profile is shared by three IDs. `0489e0b5` then sets `MODEL` from `/sys/bus/usb/devices/<dev>/product` with the ` Snapdragon...` tail cut off (as `listmodems` does), since the debugfs lookup is hard-wired to 413c:81d7 strings.

## HP lt4120 / T77W595 (`03f09d1d`)

### Why AT only

The module runs QMI, but under `proto=qmi`/`qmiraw` the generic QMI supplement is disabled (`qmi_channel_free` in `lib.sh`): netifd owns the channel, and a second owner mixes up replies. Without a profile the signal block was all dashes on a working connection (2026-09).

### What the firmware has (from `AT+CLAC` / `AT$QCCLAC`)

| Command | Meaning | Field |
|---|---|---|
| `$QCRSRP?` | `<PCI>,<EARFCN>,"<RSRP>"` triples, serving first, then neighbours; the only source of PCI/EARFCN | `PCI`, `EARFCN`, `RSRP`, `PBAND`, neighbours |
| `$QCRSRQ?` | same triples with RSRQ, matched by PCI+EARFCN | `RSRQ` |
| `$QCSQ` | `$QCSQ :-74,-2,0,0,-76` (note the space before the colon); field 1 is RSSI in dBm, checked against `uqmi --get-signal-info` | `RSSI` (accepted only in -120..-30) |
| `^VERINFO` | `HW Revision: V055` / `SW Revision: T77W595.F0.0.0.6.6.GC.029` | `FW` (SW Revision, cleaner than ATI) |

- **No SINR and no temperature** over AT. **No `+CESQ`** (it returns ERROR), so the FN990 approach does not carry over.
- All four commands are sent as one chain: verified live that none of them cuts off the others, and the port is shared with SMS/USSD.
- PCI comes with leading zeros (`076`) and levels with tenths (`-106.80`). Both are normalised to integers.
- The prefix is matched with awk `index()`, not a sed pattern. Inside double quotes `\$$1` expands to the shell PID, and the first version silently matched nothing.
- Triples are split with parameter expansion, not `set --`: the profile is sourced with `.`, so the positional parameters belong to the dispatcher.
- Neighbours come from the same triples. A separate scan (`$QCACQDBC` and similar) is not used because it blocks the port for seconds and breaks SMS.

## PCIe / MHI variants (`modem/pci/`)

For a module on PCIe the poll builds the profile key as `pci/<vendor><device>`. The AT set does not depend on the bus, so these files reuse the USB profile and only work out the data-channel protocol: there is no USB interface driver to look at, so they check which node the module exposed next to the AT port (`wwan<N>mbim<M>` → MBIM, `wwan<N>qmi<M>` → QMI).

- `pci/105be0d9` — T99W373 / MV32-W on PCIe/MHI (kernel `pci_generic.c`: `PCI_VENDOR_ID_FOXCONN` 0x105b, device 0xe0d9 → `mhi_foxconn_t99w373_info`). AT on `/dev/wwan<N>at<M>`; metrics from `modem/_foxconn_mv32_common`.
