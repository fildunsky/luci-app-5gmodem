# Other vendors: MeigLink, YUGA, generic Qualcomm MSM, plus Huawei/Fibocom files from this batch

Profiles that do not belong to a larger family document. The Huawei (`03f0581d`) and Fibocom (`15081001`) profiles were cleaned in the same batch as the files here. Their notes are kept in this file so nothing is lost, and the vendor docs [huawei-hilink.md](huawei-hilink.md) and [fibocom.md](fibocom.md) are the primary references for those families.

## Supported USB IDs

| USB ID | Module | Profile file |
|---|---|---|
| 2dee:4d57 | MeigLink SLM770A-R | `2dee4d57` |
| 05c6:9625 | YUGA CLM920-NC5 | `05c69625` |
| 05c6:6000 | Qualcomm CDMA Technologies MSM (generic) | `05c66000` |
| 03f0:581d | Huawei E3272 / E3372 / E3276 (HP ID) | `03f0581d` |
| 1508:1001 | Fibocom NL668-CN | `15081001` |

## MeigLink SLM770A-R (`2dee4d57`)

This is not a Quectel dialect: `AT+QENG="servingcell"` is not understood at all.

| Command | Field(s) |
|---|---|
| `ATI` (cached in `/tmp/5gmodem/meig_ati_<tty>`) | `MODEL` from `Model: SLM770A-R`, `FW` from `Revision: SLM770A-R_B.0.3_EQ101` |
| `AT+CESQ` | `RSRQ` = idx*0.5-19.5, `RSRP` = idx-140, `RSSI` = rxlev-111 when the framework has none from `+CSQ`; on LTE rscp/ecno are 255 |
| `AT+SGCELLINFOEX?` | named `KEY:value` fields: `BAND`, `DL CHANNEL`, `LTE_BANDWIDTH` (in 5-unit blocks: 100 → 20 MHz), `PHYSICAL_CELL_ID`, `GLOBAL CELL ID`, `TAC_ID`, `eNBID`, `RSSI/RSRP/RSRQ` (dB), `SINR` (v/5-20), `TM` → `PMIMO` (TM4+ = spatial multiplexing), `PATHLOSS`, `TX_POWER`, `UE_category`, `CQI` (`0:-` = none), `VOLTE` |
| `AT+TEMP` | `+TEMP: "rf_temp","28"` preferred, else `"cpu_temp"` |

- `ATI` is cached because the model never changes. On weak routers where command chaining does not work, the number of port visits per poll grows to about ten, and the port becomes busy (metrics flicker, e.g. the temperature appears and disappears). The cache is kept locally rather than through `at_static`, because `at_static` is defined in `5gmodem.sh` **after** the point where profiles are sourced, so it does not exist yet when the profile runs.
- `+SGCELLINFOEX` is preferred over `^CELLINFO`: it has everything plus eNBID, TM, PATHLOSS, TX_POWER, category, CQI and VoLTE, as named fields that survive inserted columns.
- SINR scale v/5-20 (110 = 2.0 dB) is confirmed by the adjacent `SNR:2`.
- `^HCSQ` also answers (`^HCSQ: 0,0,"LTE",<rxlev>,<rsrq>,<rsrp>,<sinr>`; live `+CESQ: 43,99,255,255,21,46` and `^HCSQ: ...,"LTE",43,21,46,150`), but its fourth value is **not used** as SINR because the multiplier is unconfirmed.

## YUGA CLM920-NC5 (`05c69625`)

`at+temp` (`temp:`), `at+qnwinfo` (`LTE_EUTRAN_BAND`, EARFCN) and `+LTEINFO` lines (TAC, PCI, RSSI, RSRP, RSRQ, SINR) in LTE. The second query is `at+lteinfo` (it used to repeat `at+qnwinfo`, so the `+LTEINFO` fields were never filled).

## Generic Qualcomm MSM (`05c66000`)

Identity only: fixed `MODEL`, `AT+CGMR`, `AT+GSN`, `AT+CIMI`, `AT+ICCID`.

## Huawei E3272 / E3372 / E3276 under 03f0:581d (`03f0581d`)

- `at^chiptemp?;^hcsq?`: `^HCSQ` WCDMA → RSCP = -121+p2, Ec/Io = -32.5+p3/2. LTE → RSRP = -141+p2, SINR = -20.2+p3/5, RSRQ = -20+p4/2. `^CHIPTEMP` takes the maximum over fields excluding 65535, with values above 100 divided by 10.
- `AT^HFREQINFO?` → band (field 3), EARFCN (4), DL width (6, kHz; 1400 → 1.4) and UL width (9). These must be numeric: an empty or non-numeric field in `$((...))` raises "arithmetic syntax error", which in a sourced profile **aborts the whole poll**. The card stayed empty whenever the reply had no frequencies (unregistered, busy port, firmware without `^HFREQINFO`). Found by running the profiles against a mock modem (2026-09).
- `PROTO` comes from the polled device's own vid:pid. The file used to carry a copied `Vendor=12d1 ProdID=1506` string and never detected its protocol. `huawei_cdc_ncm` maps to `ncm`.
- ICCID comes from `AT^ICCID?`, and TAC is taken from LAC.

## Fibocom NL668-CN (`15081001`)

- Identity: `AT+CGMM?`, `AT+CGMI?`, `AT+GMR?`, `AT+CGSN?`, `AT+CIMI?`, `AT+ICCID`. Temperature: `AT+MTSM=1`.
- `PROTO` is the driver of the network interface **under this modem's own USB path** (`/sys/class/tty/<tty>/device` → two levels up → `/sys/class/net/*` with that prefix and a trailing `/`). Before, a port missing from sysfs (the modem dropped off mid-poll) gave an empty base path, and `grep ""` matched every interface on the router, so the protocol came from someone else's card. Without the `/` boundary, path `1-1` also matched a neighbour modem on `1-1.2`.
