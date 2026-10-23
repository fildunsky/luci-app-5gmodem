# SIMCom

The metric profile for SIMCom modules under 1e0e:9001. Everything comes from `AT+CPSI?`. The profile first reads `AT+CGMM` to pick one of two branches: an LTE-era branch for SIM7100/7500/7600/7906/7912, and a 5G branch (SIM8200 family) that understands the LTE, NR5G_NSA and NR5G_SA `+CPSI` lines.

## Supported USB IDs

| USB ID | Module | Profile file |
|---|---|---|
| 1e0e:9001 | SIM7100E, SIM7500, SIM7600 (incl. SIM7600E-H), SIM7906, SIM7912, SIM8200 family | `1e0e9001` |

## Branch selection

The model must match `7100|7500|7600|7906|7912`. SIM7600E-H used to fall into the SIM8200 branch because only "7100" was matched. That branch splits `+CPSI` with `-F[,:]`, where the colon in `+CPSI:` adds an extra field and shifts every index by one: the band came from the PCI field ("366" → B3) and the EARFCN from the band field. As a result the header said "LTE | B7" while the PCC card said "B3 (1800 MHz)".

## LTE-era branch (SIM7100/7500/7600/79xx)

| Source | Field |
|---|---|
| `AT+CPMUTEMP` | `TEMP` |
| `+CPSI` field 1 | system: GSM / WCDMA / LTE |
| LTE: field 4 | TAC (`0x0088`) → `TAC_HEX/TAC_DEC` |
| LTE: field 5 | cell ID in **decimal** (231794689 = 0xDD0E801) |
| LTE: field 6 | `PCI` |
| LTE: field 7 | `EUTRAN-BAND n` → `PBAND`, `MODE` |
| LTE: field 8 | `EARFCN` |
| LTE: field 9 | bandwidth index 0..5 → `BANDWIDTH` |
| LTE: fields 11/12/13 | RSRQ, RSRP, RSSI in tenths (÷10) |
| LTE: field 14 | RSSNR → `SINR = 2*RSSNR - 20` |
| `AT+CMGRMI=4` (7906/7912) | `+CMGRMI: CA_SCELL,...` lines with last field `1` → `S<n>BAND/PCI/EARFCN`, LTE-A label |

Field positions follow the LTE layout in the SIMCom manual (V1.01), split with `-F,`.

### Quirks

- **Check the system first.** The GSM/WCDMA column layouts differ. An unconditional LTE parse on a GSM line read the signal level as the band number and showed "B-86" (SIM7100E falling back from LTE to EGSM 900 at night, 2026-08).
  - GSM: `+CPSI: GSM,Online,<MCC-MNC>,<LAC>,<CellID>,<bsic+band>,<RSSI>,...`. The band label is shown as printed (`EGSM 900`) without an invented `Bx`.
  - WCDMA: no live sample exists, so only the LAC/CID fields that all systems share are used, plus an honest "WCDMA" label.
- **Cell ID from CPSI, not CREG.** SIM7100E reports cell 0 in `+CREG: 2,1,E936,0`, which gave "Cell ID 0" and no cell-map button. Field 5 of `+CPSI` is used when the framework's `CID_DEC` is empty, `0` or `-`.
- **SINR formula.** The SIM7000 Series AT manual V1.04 (AT+CPSI) gives `SINR = 2*RSSNR - 20` over -20..30. The old "minus 10" under-reported by about 10 dB. Checked against QMI on a live SIM7100E: RSSNR 19 → 18 (QMI 19.0) and 22 → 24 (QMI 20.2), where the old formula gave 9 and 12.
- The CA slot variables are pre-set to `-` so the JSON is never empty.

## 5G branch (SIM8200 family)

| Source | Field |
|---|---|
| `AT+CPMUTEMP` | `TEMP` |
| `+CPSI: LTE,...` | TAC, PCI, EARFCN, band, bandwidth index, RSRQ/RSRP/RSSI (÷10), SINR as is |
| `+CPSI: NR5G_NSA,...` | NR carrier into slot 1: band (`NR5G_BAND`), PCI (field 2), ARFCN (field 4), RSRP/RSRQ/SINR (÷10), bandwidth index (field 9, 0..16 → 5..400 MHz) |
| `+CPSI: NR5G_SA,...` | TAC, PCI, ARFCN, band, RSRP/RSRQ/SINR (÷10) |

Label: LTE + NR → `5G NSA | Bx / ny`, NR only → `5G SA | ny`, LTE only → `LTE | Bx`.

## Common identity block

`AT+CGMR` (`+CGMR:` value), `AT+CGMM` (underscores turned into spaces), `AT+CGSN`, `AT+CIMI`, `AT+ICCID`. `PROTO` comes from debugfs for `Vendor=1e0e ProdID=9001`.
