# Altair ALT3100 / ALT3800 (USB vendor 216f)

The metric profile for modules on Altair LTE chips. The chips share one `AT%` command set and differ only in USB ID, composition and name, so all logic lives in `_altair_lte_common` and the `216f00XX` files are one-line wrappers. It was written for the NTmore NTLM-500 (216f:0047) from a live report. The other IDs were added because they use the same command set.

## Supported USB IDs

| USB ID | Module | Network interface | Profile file |
|---|---|---|---|
| 216f:0041 | Altair ALT3100 (LTE Cat 3), previous generation of the same AT% set | | `216f0041` → `_altair_lte_common` |
| 216f:0043 | Altair ALT3800, "Modem YOTA 4G LTE" (Yota Swift WLTUBA-107, NTmore JMR814) | cdc_ether | `216f0043` → `_altair_lte_common` |
| 216f:0044 | Altair ALT38XX debug composition ("Alt38XX devboard"; also seen on Yota modems) | RNDIS | `216f0044` → `_altair_lte_common` |
| 216f:0047 | NTmore NTLM-500 (ALT3800 + ALT6300, LTE Cat 4), module of the Skylink H1 / V-FL500 router; ModemManager calls it "Altair NPe" | cdc_ether + three ttyACM, AT on ttyACM0 | `216f0047` → `_altair_lte_common` |

The NTLM-500 holds the data session itself, so the router only needs DHCP. Yota modems in their normal mode often expose **no AT port** at all, only the network card and a web UI. In that case the profile exits immediately (`[ -c "$DEVICE" ] || return 0`), so adding extra IDs does no harm.

## Where the commands come from

No module was on hand. The command set (`%MEAS`, `%PCONI`, `%BANDCAP`) was cross-checked against two vendor manuals for related chips: Quanta LI17x ("Altair Proprietary AT commands", ALT3100/3800 generation) and Murata Type 1SC (ALT1250). It was also checked against the Altair plugin in ModemManager (live samples of `%BANDCAP` and `%GETCFG="BAND"`). Reply formats differ even within one manual (`RSRP: Reported = -80, Rx0Tx0 = -80` vs `%MEAS: Signal Quality: RSRP = -90`), so `_alt_kv` looks for `NAME = number` pairs regardless of prefix and spacing. `N/A` (no measurement) and `N/S` (not supported) are not numbers and drop out by themselves.

**No `;` chaining.** On NTLM-500 a broken chain already cost the card its operator and registration (see the framework fallback in `5gmodem.sh`), because one failing command silently swallows the rest. Commands are short and sent one at a time.

## Metric sources

| Command | Field(s) |
|---|---|
| `AT%MEAS="8"` | `RSRP`, `RSRQ`, `SINR`, `RSSI` in one line. Not in every LI17x edition: one ERROR sets the negative cache `/tmp/5gmodem/alt_nomeas8_<tty>` |
| `AT%MEAS="0"/"1"/"2"/"3"` | fallback, `Reported` value of RSRP / RSRQ / SINR / RSSI |
| `AT%MEAS="0"` `Rx<r>Tx<t>` | `ANTPORTS`: per receive antenna (Rx0/Rx1 = module antennas), the best of the base-station Tx beams |
| `AT%PCONI` | `EARFCN`, `PCI`, bandwidth, global cell ID; `PBAND` via `earfcn2band` |
| `AT%MEAS="5"` | `TEMP` (temperature) |
| `AT%MEAS="4"` | `TXPOWER` from `PUSCH` |
| `AT%MEAS="6"` | `PATHLOSS` |
| `AT%MEAS="97"` | `NEIGHBORS` |
| `AT+CGMR`, `AT+CGMM`, `AT+CGMI` | `FW`, `MODEL` (first line that is not an echo, URC or OK) |
| sysfs interface drivers | `PROTO`: rndis_host → rndis, cdc_ncm → ncm, cdc_ether → ecm (default ecm) |

All values go through `_alt_in` range checks. A level outside the physical range is a firmware placeholder and is shown as a dash.

## Quirks

### `%PCONI`

- Returns ERROR until the module is camped on a cell. That is not a fault.
- Two formats: one line, `FDD, SISO, 3, 1602, 140973580, 386` (LI17x), or per-line as from a live NTLM-500 (2026-09):
  ```
  duplexing mode: FDD
  Transmission mode: Closed loop MIMO
  Bandwidth: 5
  EARFCN: 1700
  Global Cell ID: 08671C0C
  Physical Cell ID: 350
  ```
- **The bandwidth is ambiguous.** In the one-line format LI17x defines it as an index (0=1.4, 1=3, 2=5, 3=10, 4=15, 5=20 MHz). The per-line format is not documented (Murata calls the field "Reserved"), so `Bandwidth: 5` could mean 5 MHz or index 5 = 20 MHz. Only values that exist in just one of the scales are trusted: 10/15/20 are MHz, 0/1/2/4 are indexes. **3 and 5 are not shown**, because a wrong width is worse than a dash: people use it to decide whether a band is worth fighting for.
- Cat 4 has no CA, so the label is always `LTE | Bx`.
- The cell ID from `%PCONI` is used only when the framework has none. `+CEREG` on this module reports it itself, and a mismatch between two sources could not be explained afterwards.

### Slow metrics

Temperature, TX power and pathloss change slowly, and the module has a single port. They are polled every 30 s and cached in `/tmp/5gmodem/alt_slow_<tty>`.

### TX power units

`PUSCH` is in **tenths of dBm**. The manual writes the unit as "10dBm", and that is literal. A live NTLM-500 returned `PUSCH=79, PUCCH=230, PRACH=10, SRS=180`, and PUCCH=230 is exactly 23.0 dBm, the class-3 UE power ceiling. The value is always divided by 10. An earlier guess that numbers in -50..40 were already dBm would have read PUSCH=35 (3.5 dBm) as 35 dBm.

### Neighbours `%MEAS="97"`

- Lines look like `EARFCN=1700, CellID=350, RSRP=-93 RSRQ=-24` (live NTLM-500: no prefix, and a space instead of a comma between RSRP and RSRQ).
- `EARFCN=0` means "serving frequency". The manual's example prints levels without a sign (`RSRP =76`). Positive RSRP/RSRQ do not exist, so the sign is restored.
- `CellID` above 503 is a global ID, not a PCI, and such rows are dropped.
- RSRQ here is sometimes not dB: for the same serving cell `%MEAS="8"` gave -9 while the neighbour list gave -24. Values below -20 dB are dropped.
- Negative cache `/tmp/5gmodem/alt_nonbr_<tty>` after ERROR.
