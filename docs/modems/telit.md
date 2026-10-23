# Telit (and HP lt4220)

The metric profiles for Telit modules. Telit uses its own `#`-prefixed command set (`#SERVINFO`, `#CAINFO`, `#CAINFOEXT`, `#LAPS`, `#TEMPSENS`, `#TMLVL`, `#MONI`). Both the LM960 and the FN990 profiles pack all their queries into one AT chain per poll, because the AT port is shared with SMS, SIM slots and `bands.sh`. See [subsystems/polling-at-access.md](../subsystems/polling-at-access.md) for the port-sharing rules.

## Supported USB IDs

| USB ID | Module | Profile file |
|---|---|---|
| 1bc7:1070 | FN990A28 / FN990Axx | `1bc71070` |
| 1bc7:1040 | LM960A18 / LN940-CP | `1bc71040` |
| 1bc7:1900 | LN940 (QMI/MBIM) | `1bc71900` |
| 1bc7:1901 | LN940 | `1bc71901` |
| 1bc7:1910 | LN940 | `1bc71910` |
| 03f0:0857 | HP lt4220 | `03f00857` |
| 03f0:0a57 | HP lt4220 | `03f00a57` |
| 1bc7:1201 | LE910-EUG | `1bc71201` |

The five LN940 / lt4220 files are copies that differ only in the vid:pid string used for the debugfs lookup.

## LM960A18 / LN940-CP (`1bc71040`)

One chain per poll:

```
at#tempsens=2;#lrxdiv?;#rxdiv?;#servinfo;#rfsts;#laps;#cainfo?;#tmlvl?;#4rxdis?;#ltecat?;#cqi
```

Verified live: the chain answers in full. It replaced separate calls, which collided on the shared port. In one collision the echo of another command ended up in the modem name.

| Command | Field(s) |
|---|---|
| `#TEMPSENS=2` | `TEMP`: maximum over sensors (`TSENS2,28` / `PA_THERM0,27` / ...). `mod=2` is an instant reading. `mod=1` is periodic and keeps the module awake, `mod=0` is off |
| `#TMLVL?` | `THERM`: maximum throttling level 0..3 (80568ST10869A Rev.7), same scale as the `mtherm` field |
| `#SERVINFO` (LTE) | `COPS` (field 4), `T_DEC` from TAC (field 7, hex), `RSSI` (3), `RSRP` (10), `EARFCN` (2) |
| `#CAINFO?` | PCC band (from EARFCN), `PCI`, `RSSI`, `RSRP`, `RSRQ`, `SINR`, bandwidth, TX power, modulation; SCC blocks of 11 fields each → `S<n>*` |
| `#RFSTS` | TX power fallback; in 2G/3G also UARFCN, PSC, Ec/Io, RSCP, RSSI |
| `#LAPS` | `ANTPORTS`: `#LAPS: -111,-11,-134,-19` → `0:-111:-11 1:-134:-19` (rsrp/rsrq pairs, 2 or 4 ports; silent in 3G) |
| `#LRXDIV?`, `#RXDIV?`, `#4RXDIS?` | `RXDIV`: `#LRXDIV: 1` (LTE diversity; `#RXDIV` is the fallback) → 2rx, and `#4RXDIS: 0` (4RX **not** disabled) → 4rx; `0` → off |
| `#LTECAT?` | `UECAT` (`12` shown as `12 (DL 18 / UL 13)`) |
| `#CQI` | `CQI` 0..15 (`31` = no value) |
| `AT+CGMM` / `AT+CGMR` | `MODEL` / `FW` |
| `AT#MONI` | neighbours (see below) |

### SINR is an index

`#CAINFO` SINR is **not dB** but an index 0..250 (manual 80568ST10869A Rev.7, p. 264: 0 = -20 dB, step 0.2 dB, 250 = 30 dB), so `dB = idx * 0.2 - 20`. It was once shown raw as "143 dB" (the real value was 8.6 dB). The conversion uses awk because busybox `$(( ))` has no fractions.

### Invalid SCC

The manual says: "If the LTE information of SCC is not valid, it always returns 0". `[ -n "$T" ]` let `"0"` through, and `channeltoband(0)` returned 1, which produced a phantom B1 (`LTE-A | B3 + B1 + B1` on a single carrier). SCCs with EARFCN 0 are now skipped. The SCC state `2` means activated, and only activated SCCs go into the label. TDD B38/B40/B41 were added to the EARFCN table, because a B40 SCC used to show as "?". The table is the dispatcher's `earfcn2band`.

### Model name

Only a plausible model token is accepted (`L[MN][0-9]{3,4}...`), not "the first non-empty line". When the port collided, `AT+CGMM` once returned `Telit #BND: 0,18,A7E0BB0F38DF,42`, an echo of `bands.sh`. `\r` is stripped first, otherwise an apparently empty `"\r"` line was taken by `head -1`.

### Neighbours: `#MONI`

`#MONI=<n>` **selects** a set, and the next `#MONI` prints that set. On a live LM960A18:

```
#MONI=0 -> #MONI: Tele2 RU RSRP:-107 RSRQ:-11 TAC:73AD Id:5813D15 EARFCN:3400 PWR:-78dbm DRX:640
#MONI=1 -> #MONI: RSRP:-107 RSRQ:-11 Id:000016E EARFCN:3400 PWR:-78dbm   (same frequency)
           #MONI: RSRP:-116 RSRQ:-20 Id:00001BF EARFCN:3400 PWR:-87dbm
#MONI=2 -> #MONI: RSRP:-99  RSRQ:-10 Id:00001E0 EARFCN:100  PWR:-81dbm   (other frequency)
#MONI=3 -> empty (no more sets)
```

- `Id` of the serving cell is the ECI (5813D15 = 92355861, matches `+CPSI`). For neighbours, `Id` is the **PCI in hex** (16E = 366), checked against another modem at the same site.
- Levels are already in dB, unlike FM350's `GTCCINFO` indexes. `PWR` is RSSI.
- Each set costs two commands, so the list is refreshed every 30 s and cached in `/tmp/5gmodem/moni_nb_<tty>`. Afterwards the selector is **reset to `#MONI=0`**, otherwise the next `#MONI` (ours or from the AT console) prints neighbours instead of the serving cell.
- The serving cell, which set 1 also contains, is skipped and added first from the profile's own fields (`#MONI=0` has no PCI).
- Parsing happens in shell, not awk, so it can use the dispatcher's `channeltoband`. The first version built JSON in awk and split it on commas, which JSON itself contains.

## FN990A28 (`1bc71070`)

### Why AT only

The module runs `proto=qmiraw`, where uqmi owns the cdc-wdm channel. The generic QMI supplement is disabled there (`qmi_channel_free` gate in `lib.sh`), because a second channel owner breaks the session. Without the profile, pci, earfcn, rsrp, rsrq, rssi, sinr, cqi, antports, rxdiv, temp and therm were all empty (2026-09).

### Verified vs assumed

- `#CAINFOEXT?`: verified (carriers 20/20/20/15/10 MHz from a live FN990A28). `#BND`: verified, see `modemband/1bc71070`.
- `+CESQ`: 3GPP 27.007 standard.
- `#TEMPSENS`, `#TMLVL`, `#LAPS`, `#CQI`, `#LRXDIV`, `#4RXDIS`: family commands verified on LM960A18, **not** on FN990.
- `#SERVINFO` is deliberately not used. On FN990 its layout depends on the RAT (LTE, ENDC and NR SA have different field counts), and positional parsing would silently put the wrong number into rsrp.

### Self-learning chain

- The modem aborts a chain at the first command that returns ERROR. If `#TMLVL?` is unknown, everything after it never runs, and issuing commands one by one would mean eight port visits per poll.
- The culprit is the first missing reply prefix **after which nothing answered**. If a prefix is missing but later ones are present, that command just stayed silent (`#LAPS` in 3G) and is not struck.
- A command is struck only on the **second** miss within 10 minutes, because a collision on the shared port can produce a stray ERROR. A strike lasts one hour, so a firmware or RAT change brings the command back. State lives in `/tmp/5gmodem/fn990_skip_<key>` as lines of `<tag> <misses> <when>`. A syslog line is written when a command is dropped.

### Metric sources

| Command | Field(s) |
|---|---|
| `+CESQ` | `<rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>[,<ss_rsrq>,<ss_rsrp>,<ss_sinr>]`, all indexes, 255 = none. RSRP = idx-141 (1..97), RSRQ = idx*0.5-19.5 (1..34); when there is no LTE value, NR SS-RSRP = idx-157, SS-RSRQ = idx*0.5-43.5, SS-SINR = idx*0.5-23.5 |
| `+CSQ` (framework) | RSSI fallback only (0..31 → -113..-51 dBm, coarse) |
| `#CAINFOEXT?` | named fields per carrier (`PCC- BandClass: 126, RX_CH: 3048, DL_BW: 5, PCI: 249, ...`, `SCC0- ...`) → `PBAND`, `EARFCN`, `PCI`, `BANDWIDTH`, `S<n>*`, label |
| `#CQI`, `#TEMPSENS`, `#TMLVL`, `#LAPS`, `#LRXDIV`, `#4RXDIS` | same parsing as LM960 |
| `AT+CGMM`, `AT+CGMR` | model (plausible token only), firmware |
| `#MONI` | neighbours |

### `#CAINFOEXT?` decisions

- Fields are parsed **by name**, not by position.
- The band comes from the channel (`RX_CH`), with `BandClass` as the fallback. Qualcomm's band-class enumeration diverges from band numbers on later bands, where "band = class - 119" no longer holds.
- `DL_BW` is an enumeration (0=1.4 ... 5=20 MHz), not MHz.
- SINR may be dB or an index 0..250 depending on command and firmware, and the public manual does not say which `#CAINFOEXT` uses. So the decision is **by value**: SINR above 40 cannot be dB, so it is treated as an index.
- A carrier with channel 0 is not a carrier, because an invalid SCC has all fields zero and would show as a phantom B1.
- The **NR band is not shown**: the 5G block has its own class and bandwidth numbering and no live reply was available. The existence of an NR carrier is still used for the label: NR over an LTE anchor → 5G NSA, NR without an anchor → 5G SA. The label follows actual carriers, not the ENDC registration flag, which networks set without allocating NR.
- When the profile has parsed CA, it tells the dispatcher not to repeat `#CAINFOEXT?` in its generic fallback.

### Thermal level

The maximum over sensors, **without clamping to 0..3** (LM960 clamps). FN990 has a longer mitigation scale, and showing "level 3" for level 5 would be wrong. The card labels only 0..3 and leaves higher values unlabelled.

### `#MONI` on FN990

The same select-then-read scheme, 30 s cache, reset to 0, and serving cell first. Because the row layout is **not verified** on FN990, only rows of the known shape (RSRP + Id + EARFCN) are accepted. Duplicate cells across overlapping sets are removed (some firmwares repeat the previous set in full). A modem that does not know the command is asked at most once per 10 minutes. A missing timestamp file means "never", not "time 0": treating it as 0 would block the first neighbour poll for the first 600 s of uptime, which is exactly when the card is opened most.

## LN940 / HP lt4220 (`1bc7190x`, `03f00857`, `03f00a57`)

`AT^CA_INFO?;^RFSTS?;+TEMP` with `sms_tool -D`:
- `^RFSTS` second line: LTE → RSRP (3), RSSI (4), RSRQ (5), SINR = field16*2-20, EARFCN (2), PCI (11). Non-LTE → SINR (4), RSSI (6).
- `PCC info:` / `SCC1/2 info:` → `MODE`, `PBAND`, `S1BAND`, `S2BAND` with bandwidth.
- `tsens_tz_sensor0:` → `TEMP`.
- `LAC_HEX`/`TAC_HEX`/`CID_HEX` are formatted only from numeric `LAC_DEC`/`CID_DEC`. An empty value gave `printf "%X"` with no argument, which prints `0`, so the card showed LAC 0 when the modem had not reported it.

## LE910-EUG (`1bc71201`)

`at#servinfo` in LTE only: operator (4), TAC hex (7), RSSI (3), RSRP (10), PCI hex (6), EARFCN (2). Non-numeric values are dropped.
