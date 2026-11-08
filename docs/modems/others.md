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

## Qualcomm MSM8916 SoC modem (`soc/05c68916`)

Temperatures come from `/sys/class/thermal/thermal_zone*/{type,temp}` (milli-°C), matched by zone type, because zone numbers change between kernels. Mapping: `pa-thermal` PA, `cpu*-thermal` CPU (hottest zone), `pm8916-thermal` PMIC die, `battery-thermal` battery, `xo-thermal` board (the crystal next to the radio), `charger-thermal` charger, `modem-thermal` modem (appears only when the kernel's qcom-tsens driver starts; with failed calibration there are no tsens zones). Values at or below 0 °C or above 125 °C are dropped before they reach `temps`: `charger-thermal` is computed by a PMI formula fitted at one point and has shown 302 °C out of range. The profile publishes them as `temps` (`pa=.. bat=..`), and the page renders one badge per sensor. The main `mtemp` value is the hottest sensor in `temps`, because the PA (about 35 °C) understated a hot device (PMIC 66 °C, charger 70 °C, measured 03.11.2026). Without any mapped zone it falls back to the hottest zone within the same range.

Battery: `status` Charging gives charging=1. Full and Not charging (stopped by the thermistor or the safety timer) give 0.

## TD Tech MT5700M-CN (3466:3301, Balong 5000)

The standard NCM data path is captured in issue #68. AT formats are checked against the pinned [MT5700 reference comparison](../audits/2026-11-08-tdtech-reference.md); the changes still need a cold-boot test on hardware.

- USB only. In PCIe mode the module is a root complex, so a router cannot be its host. Default USB composition: NCM, DIAG, PCUI, Serial_B, Serial_C, GPS.
- `usbports.sh` loads `cdc_ncm` and selects configuration 2 when this device has no network function. A working network function is preserved. Hotplug, coldplug and the fibocom setup path all prepare USB. The temporary serial ID is removed from the USB driver after binding; configuration-2 interfaces 0/1 are released from serial drivers. Only serial subclass `06` is moved from generic to option. Configuration-1 interface 0 is a serial port and must not be released by number alone.
- The earlier capture has vendor NCM `ff/02/16`; the later capture has standard NCM `02/0d/00` + `0a/00/01` bound to `cdc_ncm`. Selecting configuration 2 does not prove the earlier layout becomes standard. Since 3.9.29 vendor NCM interface 0 (single-interface Huawei NCM, union 0→0) is bound to `huawei_cdc_ncm` through `new_id` `3466 3301 ff 12d1 0`, which borrows the Huawei `driver_info`; `kmod-usb-net-huawei-cdc-ncm` is optional (not in DEPENDS), the bind is skipped when the module is absent or when `cdc_ncm` already holds the interface. Not yet confirmed on hardware. What changed the descriptors is still unknown. `SETMODE=4` means Linux NCM in the reference, not USB configuration 4; no SETMODE write is made automatically.
- AT works on PCUI (`ff/06/12`). `tty_no_at` hides all other ports of this module from AT probes.
- Autosetup makes `proto=fibocom` (no cdc-wdm). It dispatches to `tdtech.sh` before the generic netdev guard: prepare USB, rediscover this module's PCUI, check registration/roaming, restore saved bands, enable and verify `AT^SETAUTODIAL=1,1`, then wait for this module's netdev. Startup retries use backoff and short per-command AT locks through `lib.sh` / `at_query` (8-second command watchdog, 5-second lock wait), without requiring an external `timeout` executable. A netdev-add event does not interrupt a pending setup.
- When autodial is off, connecting through our interface prepares CID 1 from its configured APN/PDP/auth settings and enables USB autodial. When already enabled, the modem keeps its APN/context; an explicit non-USB mode is corrected. Short replies without a mode and both `SETAUTODIAL` / `SETAUTODAIL` spellings are accepted. An aligned state is not repeatedly written. No manual NDIS disconnect/reconnect is mixed with autodial.
- The data context is checked with CID 1 NDIS status, then CID 1 CGACT. Missing status is inconclusive and permits DHCP to try; an explicitly inactive context is retried. Dynamic `<iface>_4` DHCP and, for a live V6 context, `<iface>_6` DHCPv6 clients manage leases, routes and DNS in the parent's firewall zone. No guessed static address from CGPADDR is installed. A parent marked up only means the USB link is ready; actual addresses belong to the children.
- Exhausted startup reports the failed phase without permanently blocking future reconnects. An absent/unparseable registration reply is `TDTECH_REGISTRATION_UNAVAILABLE`, distinct from an explicitly unregistered state. `TDTECH_VENDOR_NCM` identifies a captured ff/02/16 interface with no netdev after autodial, rather than silently using another modem's interface. Diagnostics record current USB interface descriptors and driver links. The new sequence follows the reference application; connection success still requires hardware validation.
- `AT^CHIPTEMP?` returns 12 sensors in tenths of a degree; `TEMP` is the hottest valid one, 65535 means no reading. Field order: sub3G PA, sub6G PA, MIMO PA, TCXO, peri1, peri2, ap1, ap2, modem1, modem2, bbp1, bbp2. `TEMPS` groups them as `pa` (PA), `board` (TCXO, peri), `cpu` (ap), `modem` (modem, bbp), each the hottest of its group; zero and 65535 are skipped.
- `modemband/34663301` reads and writes LTE/NR locks with `LTEFREQLOCK` / `NRFREQLOCK`. Supported lists come from the reference model table, not a live capability query. Unlocked responses report that table; partial/error replies do not fabricate enabled bands. One NR row controls the shared NSA/SA lock. Default uses operation 0; band selection uses operation 3 with mobility allowed. The normal radio-cycle machinery applies the change. `SYSCFGEX` mode writes preserve other current fields.
- `HCSQ` uses TD Tech scaling. `MONSC` supplies direct measurements and cell identity (LTE/NR PCI is hexadecimal, WCDMA PSC decimal). `HFREQINFO` supplies carriers, and matching `MONSSC` / `CASCELLINFO` records supply their own PCI and measurements. `MONNC` adds neighbors. `TXPOWER` total is divided by 10; NR PUSCH from `NTXPOWER` is labeled separately. Invalid values stay absent. Beam tables, MCS tables and more than four secondary-carrier slots are not implemented in the main card.
- SMS uses shared storage/list/delete handling with descending batch deletion on this modem. Sending uses the literal `\r` one-line CMGS form and requires `+CMGS:` confirmation. Unknown/partially submitted multipart results are not automatically resent. See [SMS details](../subsystems/sms.md#td-tech-mt5700-sms).
- Smoke fixtures are synthetic or reference format examples, not hardware validation.
