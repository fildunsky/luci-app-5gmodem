# Qualcomm SDX55 family: Foxconn T99W175, Dell DW5930e, Thales MV31-W, Compal RXM-G1

The per-modem metric profiles under `modem/usb/` for SDX55-based modules. The T99W175 family (and its Dell and Thales rebrands) is read over AT with `AT^TEMP?` and `AT^DEBUG?`, and those profiles all source one shared block, `_qualcomm_sdx55_extras`, for antenna ports, neighbours, TX power, SCell levels and 3G levels. The Compal RXM-G1 is different hardware that shows up under some of the same USB IDs. It is read through ModemManager (`mmcli`) and `qmicli`, and only falls back to AT. All of its logic lives in `05c690d6`.

## Supported USB IDs

| USB ID | Module / composition | Profile file |
|---|---|---|
| 05c6:90d5 | Foxconn T99W175, MBIM composition; also an early Compal RXM-G1 prototype | `05c690d5` (Compal → `05c690d6`) |
| 05c6:9025 | Foxconn T99W175, QMI composition; also Compal RXM-G1 after `AT+USBCOMP=debug` | `05c69025` (Compal → `05c690d6`) |
| 05c6:90d6 | Compal RXM-G1 on custom firmware ("Tri Cascade Inc. VOS_5G", revision contains `RXMG1`) | `05c690d6` |
| 05c6:9063 | Compal RXM-G1 factory composition (no AT ports at all, only cdc-wdm + wwan) | `05c69063` → `05c690d6` with `_IS_COMPAL=1` |
| 1e2d:00b3 | Dell DW5930e / T99W175 / MV31-W (Thales customer ID) | `1e2d00b3` |
| 1e2d:00b7 | Same family; also Compal RXM-G1 (`SG500M2-X`) in QMI/debug mode | `1e2d00b7` (Compal → `05c690d6`) |
| 1e2d:00b8 | Dell DW5930e / T99W175 / MV31-W | `1e2d00b8` |
| 1e2d:00b9 | Dell DW5930e / T99W175 / MV31-W | `1e2d00b9` |
| 105b:e0b0 (PCIe) | T99W175 over PCIe | the PCIe profile also sources `_qualcomm_sdx55_extras` |

For the SDX62 sibling (T99W373 / MV32-W) see [foxconn-dell.md](foxconn-dell.md).

## Telling Compal apart from T99W175

- 05c6:90d5, 05c6:9025 and 1e2d:00b7 are each used by both vendors, and the two firmwares are incompatible. A Compal answers neither `^TEMP?` nor `^DEBUG?` (the reply is empty), so its metrics and bands have to come over QMI.
- Every profile calls the shared helper `iscompal.sh: is_compal` before anything else. If it matches, the profile sets `_IS_COMPAL=1`, sources `05c690d6` and returns. An older profile-local check read debugfs only, and it silently failed on builds where debugfs was not mounted.
- On 05c6:9025 the USB descriptor is a generic Qualcomm "HSUSB Device", with no `VOS_5G` or `Tri Cascade` strings. So the helper also checks the model name (`SG500M2-X`) via QMI, MM or AT.
- Inside `05c690d6`, MM detection matches both `RXMG1` (firmware string) and `SG500M2-X` (model). The 1e2d:00b7 prototype reports an empty revision (`--`), so matching on `RXMG1` alone left `_MM_OK=0`, and TAC/CID/IMEI/model were never read through mmcli.
- `_qualcomm_sdx55_extras` has its own independent guard (`[ -n "$_IS_COMPAL" ] && return 0`), so Compal output is never parsed as `^DEBUG?`.
- 05c6:9063 had a band profile but no metric profile. The snapshot only sources `"$RES/modem/$VIDPID"` and has no fallback to a similar profile, so the vendor block never ran. The file now delegates to `05c690d6`. The AT fallbacks inside it simply return empty when there is no AT port.
- 1e2d:00b7 used to contain a trimmed copy of the Compal logic that drifted: it had no `+CEITHERM`, no CA and no 5G fields, which is why "thermal state" was missing in QMI mode but present in MBIM. The copy was removed and the file now only delegates.

## T99W175 metric sources (AT)

| Command | Field(s) |
|---|---|
| `AT^TEMP?` | `TEMP`: the highest of `TSENS:`, `PA:` and `Skin Sensor:` (°C) |
| `AT^DEBUG?` `lte_tac:` | `TAC_DEC` (decimal), `TAC_HEX` |
| `AT^DEBUG?` `pcell:` block (4 lines) | `PBAND` (band + width), `PCI`, `EARFCN` (`channel:`), `RSRP`, `RSRQ`, `RSSI`, `SINR` (`lte_snr`, `NA` skipped) |
| `AT^DEBUG?` `scell:` blocks | `S<n>BAND`, `S<n>PCI`, `S<n>EARFCN`. Levels come from the extras block |
| `AT^DEBUG?` `nr_band:`, `nr_band_width:`, `nr_pci:`, `nr_channel:` | the NR carrier is placed in the next free `S<n>` slot |
| `AT+CGMM`, `AT+CGMI`, `AT+CGMR`, `AT+CGSN`, `AT+CIMI`, `AT+ICCID` | `MODEL`, `FW`, IMEI, IMSI, ICCID |
| `/sys/kernel/debug/usb/devices` | `PROTO` (qmi/mbim/ecm) |

The technology label comes from `MODE_NUM` (`+COPS` AcT): 7 → LTE (LTE-A if a `scell:` block exists), 11 → 5G SA, 13 → 5G NSA.

### AcT=13 is not 5G

In `1e2d00b7`, AcT=13 only produces "5G NSA" if `^debug` actually contains `nr_band:`. Otherwise the label is LTE-A or LTE. Some operators advertise EN-DC on plain LTE, and the card showed "5G" on a single B3 carrier. Users who had forced "4G only" could not tell whether the setting had taken effect. This is the same issue seen with FM350 (AcT=13) and EM9190 (`System mode: ENDC`).

### `_DBG` snapshot contract

The callers reuse `O` for `AT+CGSN`, `AT+CIMI` and `AT+ICCID`. By the end of the file `O` holds the ICCID, not the debug dump. So each profile saves `_DBG="$O"` right after `at^debug?`, and the extras block reads only `_DBG`. Before this, the antenna table silently never appeared (2026-08).

### Model string pollution (1e2d00b7)

Echo is on by factory default, and the framework's batch sets `+CREG=2`/`+CEREG=2`, whose URCs arrive in the middle of other reads. Gluing the whole reply into one line once produced a model name like `Thales AT MV31-W AT +CREG: 0 +CEREG: 0`. Only the first meaningful line of the reply is used.

### Own USB ID for protocol detection

`1e2d00b8`, `1e2d00b9` and the T99W175 branch of `05c690d6` read `idVendor`/`idProduct` of the polled device from sysfs. They used to grep debugfs for a string copied from another profile (`Vendor=1e2d ProdID=00b3`, `Vendor=05c6 ProdID=90d5`), so the protocol was never detected for those IDs.

## Shared block `_qualcomm_sdx55_extras`

It used to live only in `05c690d5`, so the 9025 composition, the 1e2d IDs and PCIe never had it. The AT command set does not depend on the composition: the same `^DEBUG?` works on 9025, and `VZWRSRP` works on 1e2d. Like `_qualcomm_sdx55_common` for bands, there is now one file for all of them.

Contract: before sourcing the file, the caller sets `_DBG` to the `at^debug?` output and `DEVICE` to the AT port.

### Antenna ports

The source line is in `^DEBUG?`, so no extra AT request is needed:

```
lte_ant_rsrp:rx_diversity:15 (-77.7dBm,-78.8dBm,-78.4dBm,-79.6dBm)
```

- **Order is direct: position = chain number.** Forum posts label the values "ANT0 ANT3 ANT2 ANT1", but a live output with mask 3 (`-90.2dBm,-91.9dBm,NA,NA`) shows measured values in positions 0 and 1, and mask 3 means chains 0 and 1. With the full mask both readings split the pairs the same way (0,2 vs 1,3), which is why the mix-up was not noticed earlier.
- `rx_diversity` is a **bitmask** of enabled chains (15 = four chains). `RXDIV` (off/2rx/4rx) is computed from the mask, not from the number of values, because levels are printed for disabled chains too.
- `NA` and `-256.0dBm` are "no measurement" placeholders. A live dump showed `(-256.0dBm,-75.3dBm,-256.0dBm,-256.0dBm)` with mask 15. Everything outside -160..-20 dBm is dropped.
- A diversity verdict is given only when at least 2 chains have a real level. With one level, "three chains not measured" and "three chains dead" cannot be told apart.
- In 3G the same line is `wcdma_ant_rscp: rx_diversity: 3 (-114.0dBm,-125.5dBm)`: a different name, two chains, and a space after the colon.
- `ANTPORTS` format is `port:rsrp:rsrq`. RSRQ per chain is not reported, so that field is empty. Values are rounded to integers because the page accepts only integers.

### Neighbours: `AT+VZWRSRP?` / `AT+VZWRSRQ?`

```
+VZWRSRP: 325,1275,"-1082"     <- prefix on the first line only
387,6350,"-1016"               <- other sectors without prefix
+VZWRSRQ: 325,1275,"-122",387,6350,"-99",...   <- all on one line, in triples
```

- Each triple is `<pci>,<earfcn>,"<value>"`. The value is in **tenths**: `"-1082"` = -108.2 dBm.
- RSRQ is joined to RSRP by the `(pci,earfcn)` pair, not by position: in a live output the last RSRQ triple belonged to a different PCI.
- The first sector in the list is the serving cell.
- Negative cache: these vendor commands are missing on some firmwares. After one non-`VZWRSRP:` reply, the file `/tmp/5gmodem/novzw_<tty>` stops further queries until reboot. Without it, every poll would spend two AT requests on the port shared with dialing.

### TX power

`lte_tx_pwr:`, `nr_tx_pwr:` or `tx_pwr:` (3G) from the same `^DEBUG?`. `NA` means "not measured", so only numeric values are accepted. The unit is inconsistent (`10.0dB` has been seen), so only the number is kept and ` dBm` is appended for the page. High TX power on this module is linked to heating and spontaneous reboots under load. The key/value parse uses awk rather than `\|` in sed, because BRE alternation is a GNU extension that busybox sed does not support.

### SCell levels

The `scell:` block carries `lte_rsrp/rsrq/rssi/snr`. The profiles used to parse these and drop them: the assignments were left commented out from the removed `addon` API. The extras block fills `S<n>RSRP/RSRQ/RSSI/SINR` only where the profile left them empty. It uses `eval` on awk output that prints only whitelisted keys and numbers, never raw modem text. An SNR of `0` or `<= -20` is treated as a placeholder.

### 3G

In WCDMA, `^DEBUG?` prints `RAT:WCDMA`, `band:`, `channel:`, `cell1: psc:...,rscp:...,ecio:...` and `rssi:`. The block fills `RSCP`, `ECIO`, `RSSI`, `EARFCN` (the UARFCN) and `PCI` (from PSC), using only the first occurrence because later cells belong to the active set. It deliberately does not touch the band or label: `band:1` there is a UMTS band, and `band4g` would turn it into "LTE B1" on a network without LTE.

## Compal RXM-G1 (`05c690d6`)

### Why mmcli/qmicli instead of AT

AT round-trips on this unit take about 100-300 ms each. `mmcli`/`qmicli` against the already running MM or qmi-proxy take about 25 ms.

### Multi-modem targeting

The MM index and the cdc-wdm node are resolved from the polled USB path (`modemswitch.sh mmindex|wdm $_POLL_AM`). With two modems, `any` or the first cdc-wdm reads the wrong modem. `any` and `/dev/cdc-wdm0` are used only when there is no `_POLL_AM`.

### `--device-open-mbim`

libqmi 1.36 (OpenWrt 25.12) auto-detects QMI-over-MBIM, but 1.34 (24.10) is weaker at it. The flag is passed explicitly, and **only** when the cdc-wdm driver is `cdc_mbim`. On `qmi_wwan` it breaks opening the device. The driver is read from `/sys/class/usbmisc/<wdm>/device/driver`, so the check does not depend on MM.

### QMI channel gate

When MM is not running (umbim/uqmi mode), `qmicli` is used only if `qmi_channel_free` / `_poll_chan_free` agree. Otherwise a second owner of the channel breaks the session.

### TAC / CID via mmcli

- Only `mmcli --location-get` returns `modem.location.3gpp.tac/cid`. The general `-K` dump does not include those keys, so parsing it always returned empty.
- Location gathering is off by default in MM. If the values are missing, `--location-enable-3gpp` is called once in the background. This is rate-limited to once per 300 s through `/tmp/5gmodem/mmloc_<key>`, and the data appears on the next poll.
- The values are assigned only if MM actually returned them. An unconditional assignment once wiped values the framework had parsed from `+CREG` (giving `tac_dec="-"` with a valid `lac_dec`). For LTE, the LAC from `+CREG` is the TAC and serves as the fallback.
- `--` from mmcli means "no field" and is never shown as firmware.

### Model and identifiers

- `modem.generic.model` reports the platform name `VOS_5G`, so `MODEL` is hard-set to "Compal RXM-G1".
- IMSI/ICCID are not exposed through `modem.3gpp.*` on this MM version. `SIMID` and `AT+ICCID` are used for them.
- In AT mode, the model and firmware are the first line that is not an echo, OK or ERROR. The echo ends in `\r`, not a space, so the old `sed 's/^AT+CGMM //'` never matched and produced "Compal RXM-G1 (AT+CGMM SG500M2-X)".
- `PROTO` comes from MM's `modem.generic.drivers` rather than sysfs.

### Carrier aggregation

- Source: `qmicli --nas-get-lte-cphy-ca-info`, which gives PCI, EARFCN, bandwidth and state per carrier.
- **Only activated SCCs count as aggregation.** QMI also lists configured-but-deactivated carriers. On a single B3 the modem listed three SCCs (B40/B7/B1), all deactivated, and the card showed "4G+ | B3 / B40 / B7 / B1". Carriers with `State: deactivated` go into the per-carrier table with `S<n>STATE=deactivated` but stay out of the header. Firmwares that omit `State` altogether are treated as active.
- Band string formats: the table gets `B40 @20 MHz` (the front end splits on ` @` in `mutil.caSplitBand`). The header gets the width inside the frequency brackets, `B40 (2300 MHz @20)`, because the card renders bracket contents small and grey.
- There are no per-SCC signal levels in any command (QMI gives RSRP/RSRQ/SNR for the serving cell only), so those stay empty.

### 5G and the technology label

- `+COPS` is not returned by this firmware through `gcom/info.gcom`, so `MODE_NUM` is often empty. `--nas-get-lte-cphy-ca-info` can fail with QMI error 74 `InformationUnavailable`.
- The working source is `--nas-get-rf-band-info` (`Active Band Class: 'eutran-N' / 'ngran-N'`, `Active Channel`). It is queried whenever qmicli is available, not only under `MODE_NUM` 11/13. Channel width, TX power, eNB ID and neighbours from QMI NAS moved to the framework (`5gmodem.sh: _qmi_supplement`).
- Label: lte + 5gnr → 5G NSA, 5gnr only → 5G SA, lte only → LTE (LTE-A with more than one band). Inputs are the MM `access-technologies` plus the band classes, so an empty MM state does not matter.
- **5G advertised but no NR carrier**: if the technology is 5G NSA but rf-band-info has no ngran band and the 5G block of `--nas-get-signal-info` is empty or the sentinel `-32768`, the band is shown as `4G B3`, i.e. "5G NSA | 4G B3 (1800 MHz)".

### AT fallback (no MM, no qmicli)

- CA from `at+lcainfo` (`CA enable`, `PCC`/`SCC ... Band:`), EARFCN and PCI from `at+binfo`, levels from `at+cesq` and the `RSRQ .. RSRP .. SINR` line of `at+binfo`.
- `AT$QCRSRP?` / `AT$QCRSRQ?` return triples `<pci>,<earfcn>,"<val>"`, serving cell first, e.g. `$QCRSRP: 386,1275,"-114.30",050,550,"-122.40"`. The field order was checked against value ranges: PCI is at most 503, so 1275 can only be an EARFCN. PCI is not in any qmicli signal output, so `$QCRSRP?` is also asked on the normal path when PCI is empty. It is skipped in 2G/3G.
- Leading zeros are stripped with sed, not `$((10#$T))`. `base#number` is a bashism, and busybox ash fails with "arithmetic syntax error".

### Extra AT metrics (AT port present)

When the poll has a tty AT port (90d6, not 9063), the profile reads `AT+BINFO`:

- `downlink modulation num_layer` → `pmimo` (rank); layer 0 modulation → `pmod`. Both only while `num_layer > 0`: idle layers read `BPSK` or empty.
- `PCC CQI` first codeword → `cqi` (0 skipped).
- Without qmicli only: `tx_pwr` → TX power; `RXn rsrp` / `RXn power` → antenna ports (`-256` = idle chain, skipped), live chain count → `rxdiv`; `AT+LCAINFO` `SCC n Band:b RSRP:x dbm` → `SnRSRP` when the band matches `SnBAND`. With qmicli the QMI values win (they carry RSRQ per port).

Under ModemManager the port is available only when `mm_at_allowed` agrees (`mbimp` with the iface up).

### Thermal state

This firmware has no °C reading at all (`AT^TEMP?` returns nothing). Of the 365 commands in `AT$QCCLAC`, the only thermal one is `+CEITHERM`, which reports a **throttling level 0-3** (`AT+CEITHERM=?` → `1.pa:0-3 2.pa_fr1:0-3 3.modem:0-3 4.mmw0..3:0-3`). `THERM` is the highest level of all sensors (the PAs usually throttle first), never `TEMP`. All seven read 0 on an idle stand.

### Built-in APN profile blocks that APN

The VOS_5G firmware can carry its own APN profile (`--ms-query-provisioned-contexts` shows it with `Source: 'modem'`, e.g. `INTERNET` IPv4v6). The modem attaches on that APN, and every MBIM connect to the same APN then fails with `MBIM status error: Failure`. This happens with any IP type and under umbim, mbimcli and ModemManager alike. Any other APN connects. The cause is the stick's own Linux (QCMAP): it auto-connects profile 1 for its ECM/RNDIS tethering, and the network allows one PDN on that APN. The fix is on the modem side:

1. Switch the modem to RNDIS (Switch_Tool).
2. Open its web UI at 192.168.225.1 → APN SETTINGS.
3. Delete or change the profile.
4. Switch back to MBIM.

## PCIe / MHI variants (`modem/pci/`)

For a module on PCIe the poll builds the profile key as `pci/<vendor><device>`. The AT set does not depend on the bus, so these files reuse the USB profile and only work out the data-channel protocol: there is no USB interface driver to look at, so they check which node the module exposed next to the AT port (`wwan<N>mbim<M>` → MBIM, `wwan<N>qmi<M>` → QMI).

- `pci/105be0b0` — Dell DW5930e / Foxconn T99W175 on PCIe. `AT^TEMP?` needs the question mark, as in the USB profiles. Temperatures are compared only as numbers (a non-numeric value used to kill the poll with "bad number"). `lte_tac` in `^DEBUG?` is decimal, as on USB. Antenna ports and neighbour sectors come from the shared `_qualcomm_sdx55_extras`.
