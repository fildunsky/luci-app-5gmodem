# Quectel

The metric profiles for Quectel modules. Every `2c7c*` profile sources `_quectel_common`, which holds the shared parsing helpers (`_qc_*` for LTE-era modules, `_q5_*` for 5G modules), and ends by sourcing `_quectel_qrsrp` for per-antenna levels. A per-model file only picks the helpers and the command chain that model supports.

## Supported USB IDs

| USB ID | Module | Profile file | Path |
|---|---|---|---|
| 2c7c:0125 | EC20-E, EC25 | `2c7c0125` | `_qc_ec25_lte` |
| 2c7c:0121 | EC21 (same AT set as EC20-E/EC25) | `2c7c0121` → `2c7c0125` | `_qc_ec25_lte` |
| 05c6:9215 | EC20-E, EC25 under the Qualcomm ID | `05c69215` | own copy of the EC25 parse, no `_quectel_qrsrp` |
| 2c7c:6005 | EC200A-EL | `2c7c6005` | `_qc_ec25_lte` |
| 2c7c:6026 | EC200T | `2c7c6026` | own parse |
| 2c7c:0306 | EP06, EG06 | `2c7c0306` | `_qc_qeng_bw` + QCAINFO + neighbours |
| 2c7c:6004 | EG060W | `2c7c6004` | same as EP06 |
| 2c7c:030b | EM06 | `2c7c030b` | same as EP06 |
| 2c7c:0512 | EG18-EA, EM12-G, EM160R-GL | `2c7c0512` | `_qc_scc_lte` |
| 2c7c:0620 | EM160R-GL | `2c7c0620` | `_qc_scc_lte` |
| 2c7c:0800 | RG500Q-EA, RG502Q-EA, RM500Q-GL, RM502Q-AE | `2c7c0800` | `_q5_core` |
| 2c7c:0801 | RM520N-GL (RM521F-GL shares the AT manual; its PID is not confirmed) | `2c7c0801` | `_q5_core` |
| 2c7c:0900 | RM500U-CNV | `2c7c0900` | `_q5_core` |
| 2c7c:0122 | RM551E-GL | `2c7c0122` | `_q5_core` |
| 2c7c:0133 | RM551E-GL | `2c7c0133` → `2c7c0122` | `_q5_core` |

For the YUGA CLM920 (05c6:9625), which speaks a Quectel-like `+QNWINFO`, see [others.md](others.md).

## Metric sources

| Command | Field(s) |
|---|---|
| `AT+QTEMP` | `TEMP`: the maximum over sensors |
| `AT+QNWINFO` | band (`LTE BAND n`) → `MODE`, `PBAND` |
| `AT+QENG="servingcell"` (LTE layout) | `$9` PCI, `$10` EARFCN, `$12`/`$13` UL/DL bandwidth index, `$14` TAC (hex), `$15` RSRP, `$16` RSRQ, `$17` RSSI, `$18` SINR (with `-F[,:]`) |
| `AT+QCAINFO` | PCC/SCC lines → CA slots `S<n>*`; on 5G modules also the NR carrier |
| `AT+QSPN` | operator name → `COPS` (unless `FORCE_PLMN`) |
| `AT+C5GREG=2;+C5GREG?` | 5G registration, TAC, CID, `MODE_NUM` (`_q5_c5greg`) |
| `AT+QENG="neighbourcell"` | `NEIGHBORS` (`_qc_neighbours`) |
| `AT+QRSRP` | `ANTPORTS`, `RXDIV` (`_quectel_qrsrp`) |
| `AT+QUIMSLOT?` | active SIM slot |
| `ATI` / `AT+GMR` / `AT+CGMM` / `AT+CGMI` | `FW`, `MODEL` |
| `AT+QGMR?` (RM520N) | full build string → `FW` |
| `AT+GSN`, `AT+CIMI`, `AT+QCCID` | IMEI, IMSI, ICCID |

## Quirks

### SINR in QENG is already dB

- The `QENG="servingcell"` SINR field is plain dB. Old formulas (`x*0.2-20`, `2x-20`) gave around -19 dB on working links. Evidence: on EC25, QENG SINR=2 matches `AT+QCSQ` 112 → 112/5-20 = 2.4 dB. Across 23 live forum replies the field stays in 0..25 and rises with RSRP (-114 → 6, -67 → 25). The shift made the card under-report SINR by 4-14 dB.
- `_q5_ots` / `_q5_lte` accept only -30..50.
- On SDX62 (RM520N) the QENG serving SINR reads 0 while the last PCC field of QCAINFO in the same session shows 8 dB. For `_q5_core`, SINR therefore comes from QCAINFO, with QENG as the fallback.
- EC200A: the scale is not verified on hardware (the profile was built from an offline dump).

### Bandwidth is a separate field

The legacy `PBAND="B3 DL: @20 MHz UL: @20 MHz"` broke the front end. `mutil.caSplitBand` splits on ` @`, so the CA table showed `B3 (1800 MHz) DL:` in the band column (seen on EP06-E, 2026-08). `_qc_qeng_bw` puts the DL width into `BANDWIDTH` and adds `/UL` only when UL differs, which on FDD it almost never does. QENG `$13` is an index: 0=1.4, 1=3, 2=5, 3=10, 4=15, 5=20 MHz.

### QSPN field choice

The reply is `+QSPN: <FNN>,<SNN>,<SPN>,<alphabet>,<RPLMN>`. Old firmwares with limited service put `"000 000"` in FNN (for example `+QSPN: "000 000","000 000","beCloud",0,"000000"`), which overwrote the name already found by `+COPS?`. `_qc_spn4` takes SPN (field 4 with `-F[,:]`), falls back to FNN, and rejects purely numeric strings. 5G profiles still use `_qc_spn2` (FNN).

### Secondary carriers (QCAINFO)

- LTE SCC layout, confirmed by five independent live dumps:
  ```
  "SCC",<earfcn>,<bw>,"LTE BAND n",<state>,<pci>,<rsrp>,<rsrq>,<rssi>,<sinr>[,<ul_cfg>,<ul_bw>,<ul_earfcn>]
  ```
  The tail after SINR is padded with dashes (`,0,-,-`). `_sccnum` checks each value for being a number in a physical range before it goes into `S<n>RSRP/RSRQ/RSSI/SINR`. These levels used to be parsed and dropped, left behind by the removed `addon` API. 3-5 carriers are common.
- **State**: `1` = configured but deactivated, `2` = active. In a live EP06-E speed test, state=2 held for 2-4 s and then the network kept the same carrier in state=1, while the card still showed CA. Now state=2 goes into `MODE`/LTE-A, and state=1 is placed in its slot with `S<n>STATE=deactivated` and rendered dimmed.
- EP06/EG060W/EM06: the QENG reply is saved in `_QENG_O` before `$O` is overwritten by QCAINFO. Without it, SINR on a modem with CA was always empty.
- NR carrier levels are **not** filled. In NSA the only live NR5G SCC line seen is `+QCAINFO: "SCC",643320,12,"NR5G BAND 78",145` (five fields), so only ARFCN, width and PCI are used, and NSA 5G levels have to be read from the LTE anchor. No SA dump with NR levels exists, and the commented-out `$8/$9` positions came from foreign code that nobody verified.
- `_q5_nsaleg` places the NR carrier from `+QENG: "NR5G-NSA"` into a free slot when QCAINFO did not list it, and fills its RSRP/SINR/RSRQ.
- In the per-carrier loop, four levels come from one awk call instead of three or four separate ones (up to five carriers per poll). Empty fields are replaced with `-` inside awk, because two adjacent separators would otherwise collapse and shift the levels one field to the left.

### Cell ID on RM520N

There are two QENG layouts. In the flat one, `+QENG: "servingcell","NOCONN","LTE","FDD",250,11,4E23802,...`, the cell is field 7. In the NSA split one, `+QENG: "LTE",...`, it is field 5. Taking field 5 from the flat layout read the MCC (250) as the cell ID.

### Firmware build on RM520N

`AT+QGMR?` returns the full build (`RM520NGLAAR03A03M4G_01.201.01.201`). Only that string shows the firmware branch: R01A06 has no regional block, while R03 / "200/201/30x" builds have the RU block. `AT+GMR` returns only the short revision.

### Protocol detection from sysfs

RM520N reads the driver from its own USB path (`/sys/bus/usb/devices/$_POLL_AM:*/driver`), with debugfs as the fallback. The debugfs parse took the text after the **first** `Vendor=2c7c ProdID=0801` and cut it at 1290 characters, so with two identical modules the protocol came from the neighbour, and without debugfs it was never detected. `2c7c0122` and `2c7c030b` also use the polled device's own ID. `2c7c0122` previously carried a copied `Vendor=2c7c ProdID=0801` string and never detected its protocol.

### Neighbours (`_qc_neighbours`)

```
+QENG: "neighbourcell intra","LTE",<earfcn>,<pci>,<rsrq>,<rsrp>,<rssi>,...
```

- Column 5 is **RSRQ** and column 6 is **RSRP**, the reverse of the usual order. Verified on EP06-E (rsrq -19, rsrp -105) and RM520N (intra `2850,136,-10,-100,-68` matches the serving cell).
- The band is derived from EARFCN (3GPP 36.101 table 5.7.3-1) because the modem does not report it. Unknown channels stay unlabelled. B32 (SDL, 9920-10359) is included because it is part of EP06-E CA combos (20A2A-32A2).
- Truncated rows (all zeros, no tail) are dropped. The serving cell is also listed and is marked `serving` by PCI+EARFCN, so it does not appear as a lockable neighbour.

### Temperature

- EP06/EG060W: 3 or 4 sensors depending on firmware (`+QTEMP: 49,47,47` and four-value replies). The maximum over **all** fields is taken, compared numerically so that negative values work. Overheating is the main failure class on EP06.
- EC200A: unused sensors report 255 (`+QTEMP: 37,255,255`), and these are excluded from the maximum.

### Per-antenna levels (`_quectel_qrsrp`)

`AT+QRSRP` → `+QRSRP: -95,-99,-140,-140[,LTE]`: RSRP of PRX, DRX, RX2, RX3. The fifth field (RAT) is present only on some firmwares. NR modules may print two lines, and the first one (the serving cell) is used. Unused chains report `-140` or `-32768` and are excluded: the two-antenna EP06 physically has no RX2/RX3. `RXDIV` is the number of chains above -130: 1 = off, 2 = 2rx, 3-4 = 4rx. Models without the command (EC200 and relatives) answer ERROR and simply get no table.

### EC200A-EL (`2c7c6005`)

Built from an offline dump (`EC200AELLAR01A05M16`, ECM/RNDIS usbnet, AT usually on ttyUSB1), not from a module on hand. QENG `"servingcell","NOCONN","LTE","FDD",460,11,6138907,489,100,1,5,5,7706,-65,-8,-55,35,58` matches the EC25 field positions one to one. TAC `7706` is assumed to be hex, following Quectel convention. If a live module shows it is decimal, the `0x` should be dropped. Protocol detection accepts `rndis` too.

## PCIe / MHI variants (`modem/pci/`)

For a module on PCIe the poll builds the profile key as `pci/<vendor><device>`. The AT set does not depend on the bus, so these files reuse the USB profile and only work out the data-channel protocol: there is no USB interface driver to look at, so they check which node the module exposed next to the AT port (`wwan<N>mbim<M>` → MBIM, `wwan<N>qmi<M>` → QMI).

- `pci/17cb0308` — RM520N-GLAP: the same RM520N-GL with USB cut at the factory, seen as PCI 17cb:0308 under `mhi-pci-generic` ("MHI PCI device found: quectel-rm5xx"). Before this file existed the AP variant showed no vendor metrics at all. Under `mhi-pci-generic` the channel is always MBIM (QMI only appears with the vendor driver), so MBIM is the default.
