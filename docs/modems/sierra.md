# Sierra Wireless (and Dell/Lenovo rebrands)

The metric profiles for Sierra Wireless modules. Almost everything comes from one command, `AT!GSTATUS?`, plus `AT!LTEINFO?` for neighbours. Its output format differs between platforms, so there are two parsers: `_sierra_gobi_lte` for Gobi/Snapdragon X5-X7 (MDM9x15/9x30) and `119990d3` for the X50/X55 layout (EM9190, also used for 9x50). The EM7345 carries a Sierra label but has an Intel XMM7160 inside, and it has its own 3GPP-only profile.

## Supported USB IDs

| USB ID | Module | Profile file |
|---|---|---|
| 1199:9071 | EM7455 / MC7455 / EM7430 / MC7430 (MDM9x30) | `11999071` → `_sierra_gobi_lte` |
| 1199:9079 | Lenovo EM7455 ("Lenovo-Storm") | `11999079` → `11999071` |
| 1199:68c0 | MC7304 / MC7354 (MDM9x15, "simple" GSTATUS format) | `119968c0` → `11999071` |
| 413c:81b8 | Dell DW5811e HSPA+ (3G only; temperature still comes from GSTATUS) | `413c81b8` → `11999071` |
| 413c:81cc | Dell DW5816e | `413c81cc` → `11999071` |
| 413c:81cf | Dell DW5819 | `413c81cf` → `11999071` |
| 413c:81d0 | Dell DW5819 | `413c81d0` → `11999071` |
| 413c:81d2 | Dell DW5818 | `413c81d2` → `11999071` |
| 413c:81b6 | Dell DW5811e Snapdragon X7 (= EM7455B, MDM9x30) | `413c81b6` → `_sierra_gobi_lte` |
| 1199:9041 | EM7305 / MC7305 / EM7355 / MC7355 (MDM9x15) | `11999041` → `_sierra_gobi_lte` |
| 1199:68a2 | MC7710 | `119968a2` (own simple parser) |
| 1199:90d3 | EM9190 (X55) | `119990d3` |
| 1199:9091 | EM7565 / EM7511 (MDM9x50) | `11999091` → `119990d3` |
| 1199:c081 | EM7590 | `1199c081` → `11999091` |
| 1199:a001 | EM7345 (Intel XMM7160 inside) | `1199a001` |

Before the thin wrapper files existed, these IDs only had bare `+CSQ`/`+CEREG`/`+COPS`: no RSRP, SINR, temperature or CA (found in a 2026-09 forum review).

## Gobi / Snapdragon X5-X7 parser (`_sierra_gobi_lte`)

Callers run `O=$(sms_tool ... at "at!gstatus?")` and source the file. It was split out on purpose: `11999041` and `11999071` were near-identical copies that had already drifted. One of them called a nonexistent function `band` instead of `band4g`, so the CA band never appeared. `413c81b6` was a third copy that missed every later fix.

### GSTATUS format on 9x30

```
LTE CA state:  ACTIVE        LTE Scell band:B12     <- no space after ":"
LTE Scell bw:10 MHz          LTE Scell chan:5110
PCC RxM RSSI:  -45           RSRP (dBm):  -81       <- chains are M/D, not Rx0..Rx3
PCC RxD RSSI:  -44           RSRP (dBm):  -79
Tx Power:      15            TAC:         8C65 (35666)
RSRQ (dB):     -14.0         Cell ID:     0A14666A (169106666)
```

There is exactly one SCell. The parse was checked against a live EM7455 dump.

### Field mapping

| GSTATUS label | Field |
|---|---|
| `Temperature` | `TEMP` |
| `System mode` | technology when `+COPS` is silent |
| `LTE band`, `LTE bw` | `PBAND`, `BANDWIDTH` |
| `LTE Rx chan` | `EARFCN` |
| `PCC RxM/RxD RSSI` + `RSRP` | `RSRP`, `RSSI` (strongest chain), `ANTPORTS` 0 (M) and 1 (D) |
| `LTE CA state`, `LTE Scell band/bw/chan`, `SCC Rx* RSRP` | `S1BAND`, `S1EARFCN`, `S1RSRP`, `S1STATE` |
| `Tx Power` | `TXPOWER` |
| `TAC`, `Cell ID` | hex + (dec) pairs → `T_HEX/T_DEC`, `CID_HEX/CID_DEC` |
| `RSRQ`, `SINR` | `RSRQ`, `SINR` |

### Quirks and decisions

- Labels are matched as **substrings** (they contain brackets, as in `RSRQ (dB)`), then optional units and the colon are skipped. TAC and Cell ID take the hex token and the (dec) token.
- The **strongest** of the main and diversity chains goes into `RSRP`/`RSSI`. Both measure the same cell, so "-81/-79" is two values, not one.
- **"Simple" format** (MDM9x15: MC7355/EM7305, some 9x30 firmwares): `RSSI (dBm): -79   Tx Power: 0`, `RSRP (dBm): -109  TAC: ...`. There were no rules for it before, so these modules showed no level at all.
- `System mode: LTE` is accepted as "in LTE" when `MODE_NUM` is empty. `+COPS` often stays silent because the port is busy or collides with MM, which is normal for Sierra, and the whole GSTATUS used to be dropped then.
- The Cell ID is printed by the modem but was not used, so the card had a dash and no cell-map button.
- **`INACTIVE` contains `ACTIVE`.** The old `/CA state:.*ACTIVE/` matched inactive carriers and reported 4G+ on a single carrier. The state is now compared as a whole value.
- The label is built from scratch (`LTE | B2 ...` / `LTE-A | B3 + B12`) and only when a band was parsed. Otherwise the framework's `+COPS` label is kept. Patching `$MODE` with sed used to lose the `|` separator without CA.
- `ANTPORTS` uses the Telit `#LAPS` format `port:rsrp:rsrq[:rssi]`. There is no per-chain RSRQ, so that field is empty and RSSI is filled.
- `_sg KEY` looks up a value in the pre-parsed `KEY value` list with `set -f` and IFS=newline. Using `$(...)` per key would cost about twenty forks per poll.

### Neighbours: `AT!LTEINFO?`

On kernel protocols (qmi/mbim) netifd owns the QMI channel, so the usual neighbour source (cell-location-info) is unavailable. `!LTEINFO?` is the only path. The 9x30 format matches X55 word for word:

```
Serving: EARFCN MCC MNC TAC CID Bd D U SNR PCI RSRQ RSRP RSSI RXLV
 550 250 99 60816 0272CA65 1 3 3 16 468 -8.0 -68.3 -45.2 --
IntraFreq: PCI RSRQ RSRP RSSI RXLV
 468 -8.0 -68.3 -45.2 --
InterFreq: EARFCN ThresholdLow ThresholdHi Priority PCI RSRQ RSRP RSSI RXLV
WCDMA: UARFCN ThreshL ThreshH Prio PSC RSCP ECN0 RXLV
```

- IntraFreq neighbours inherit the serving band and EARFCN. InterFreq has no band, so it is left empty rather than invented.
- The serving cell also appears in IntraFreq and is deduplicated by `earfcn_pci`. Otherwise it showed up twice, the second time as a "neighbour" with a pointless lock button.
- Negative cache `/tmp/5gmodem/nolteinfo_<tty>`: MDM9x15 may lack the command. **Only an explicit ERROR** is cached. An empty or truncated reply means the port is busy, and locking the command out for good would be worse than asking again.

## MC7710 (`119968a2`)

A simple field-position parse of `at!gstatus?`. Earlier fixes:
- TAC used to go into `$TAC`, which the framework had already filled from `+CEREG` and never reads again. It now goes to `T_HEX`/`T_DEC`.
- The Rx channel was parsed and thrown away (a leftover of the removed `addon` mechanism).
- The Cell ID (`Cell ID: 05CF9C12 (97491986)`) is now taken.
- The label uses the common `LTE | Bx` separator.

## EM9190 / X55 layout (`119990d3`)

`AT!GSTATUS?` returns everything at once: temperature, mode, PCC/SCC1..3 with width and channel, per-chain levels (Rx0..Rx3), TAC, Cell ID and an NR5G section. One awk pass produces `key value` pairs, replacing about thirty separate awk calls. Modem values are never `eval`'d.

### Truncated replies under ModemManager

MM keeps ttyUSB0 as its own AT port and polls it, so our `at!gstatus?` can arrive cut off mid-word. This has been seen on desktop Linux and on OpenWrt alike. A complete reply ends in OK/ERROR, and the command is retried once without one. A truncated reply does not corrupt data, because parsing is by label.

### Field mapping and decisions

- `LTE SCC<n> state/band/bw/Rx chan` → `S<n>STATE/BAND/EARFCN`, `SCC<n> Rx* RSRP` → `S<n>RSRP` (best chain).
- `PCC Rx0..3` (or `RxM/RxD`) → `ANTPORTS` with up to 4 ports. The strongest chain is what QMI reports as the cell RSRP (checked against signal-info).
- SCCs the network configured but did not activate (`INACTIVE`) are shown as deactivated but never counted as CA.
- The NR carrier (EN-DC) takes the first **free** SCC slot. There is one CA table for both technologies, as with Fibocom.
- `AT!LTEINFO?` adds what GSTATUS lacks: SINR of the secondary carriers (the `CA SCell` section, `EARFCN SCID Bd ST D U Mdl Mul PCI RSRP RSSI SINR`, matched to slots by EARFCN with SCID as fallback) and the neighbour table (same format as above). One command per poll, parsed twice. The JSON matches the QMI path (`5gmodem.sh: _qr_nb`): the framework takes the profile's `NEIGHBORS`, and the QMI fallback fills only empty fields.
- **Label by actual carriers**: the modem says `ENDC` as soon as the network allows dual connectivity, but without an NR band it is plain LTE (same lesson as AcT=13). An empty `System mode` (busy port) leaves the `+COPS` label alone instead of overwriting it with an empty string.
- 9x50 (EM7565/EM7511) uses the same GSTATUS layout without the NR5G section. The single-SCell Gobi parser does not fit it: there are up to 3-4 carriers and the fields are named differently.
- Protocol lookup uses the polled device's own vid:pid from sysfs, because the file is shared by several IDs.

## EM7345 (`1199a001`)

- Intel XMM7160 inside: mmcli shows h/w `XMM7160_V1.1_MBIM_GNSS_NAND_AD` and firmware `FIH7160_V1.1_WW_01.1531.00_AT`. Sierra `!` commands do not apply (`AT!ENTERCND="A710"` → ERROR), so no Sierra/Qualcomm profile can be used.
- Composition: cdc_mbim (If#0/1) + cdc_acm (If#2/3) → cdc-wdm0 (mbim), ttyACM0 (AT), wwan0. A three-port variant (ttyACM0/1/2) also exists. cdc_acm creates the nodes itself, so no usb-serial binding is needed.
- Levels come from `AT+CESQ` (3GPP TS 27.007, exact scale): RSRP = idx-141, RSRQ = idx*0.5-19.5, RSCP = idx-121, Ec/Io = idx*0.5-24.5, and rxlev-110 as an RSSI fallback. Identity comes from `+CGMI/+CGMM/+CGMR`, using the first meaningful reply line with quotes stripped. Registration, operator, TAC and CID come from the framework.
- Cat 4 means there is never CA (no `+XLEC` and no SCC branch from the L850 profile `2cb70007`).
- `AT+XMCI=1` is tried **once per enumeration** for cell, PCI, EARFCN, SINR and neighbours. If it does not answer, the USB `devnum` is stored in `/tmp/5gmodem/em7345_noxmci_<tty>`, and the probe repeats only after re-enumeration. Scales come from a live L850 (rsrp = idx-141, rsrq = (idx-45)/2, sinr = idx/4+5) and are **not confirmed** for 7160, so every value goes through a plausibility check. Type-4 lines are the serving cell and type-5 lines are neighbours, with PCI/EARFCN in hex (busybox awk has no `strtonum`, so conversion is manual). All-F/zero placeholders are dropped.
- XMCI data is used **only in LTE**. Types 4/5 describe LTE cells, and showing EARFCN/RSRP while on UMTS would be false. XMCI levels fill fields only when `+CESQ` was silent.
- `PROTO` comes from whichever driver holds the interfaces (cdc_mbim, cdc_ncm, cdc_ether or qmi_wwan). Other firmwares put the same chip in NCM/ECM.

## PCIe / MHI variants (`modem/pci/`)

For a module on PCIe the poll builds the profile key as `pci/<vendor><device>`. The AT set does not depend on the bus, so these files reuse the USB profile and only work out the data-channel protocol: there is no USB interface driver to look at, so they check which node the module exposed next to the AT port (`wwan<N>mbim<M>` → MBIM, `wwan<N>qmi<M>` → QMI).

- `pci/17cb0306_18d7`, `pci/17cb0308_18d7` — Sierra EM9xxx on PCIe/MHI (subsystem vendor 18d7).
