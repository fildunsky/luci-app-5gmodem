# Other non-Qualcomm modems (MikroTik/Marvell, ASR, ASKEY, BroadMobi, Sierra 320U)

This covers the metric profiles of the remaining non-Fibocom, non-HiLink modems in this group, and the MikroTik R11e-LTE branch of the `fibocom` netifd protocol. Profiles are in `root/usr/share/5gmodem/modem/usb/<vidpid>` and are sourced by `5gmodem.sh` with `$DEVICE` set to the AT port. Qualcomm, Sierra, Quectel, SIMCom, Telit and Altair modems are documented elsewhere (see `others.md` and the vendor docs).

## Supported USB IDs

| USB ID | Model | Profile file | Data path | Metric sources |
|---|---|---|---|---|
| 2cd2:0001 | MikroTik R11e-LTE (Marvell PXA1802, miniPCIe, LTE Cat 4) | `2cd20001` | proto `fibocom` (R11e branch), RNDIS | `AT+CESQ`, `AT+EEMOPT=1` + `AT+EEMGINFO?` (`+EEMLTESVC`), `AT+CGMR` |
| 2cd2:0004 | MikroTik R11e-LTE6 (ASR) | `2cd20004` | - | `at+cesq;+zcainfo?;+zpas?;+zcellinfo?`, `AT*ICCID?` |
| 1286:4e28 | Marvell PXA1826 (ASR): Notion R281/R291, MegaFon C300-1, Yota C300-1 (built-in modem, RNDIS + ttyACM) | `12864e28` | - | `AT+ZRSSI;+ZCELLINFO?;+ZCAINFO?`, `*READVER`, `*MRD_IMEI?`, `*ICCID?` |
| 1690:7588 | ASKEY WWHC050 | `16907588` | - | `at$qcai?;+ccputemp;+cgcelli;+cgnws` |
| 2020:2033 | BroadMobi BM806U (D-Link DWR-921 C1) | `20202033` | - | `AT+BMTCELLINFO` |
| 0f3d:68aa | Sierra Wireless 320U | `0f3d68aa` | - | `at!gstatus?`, `ati` |

## MikroTik R11e-LTE (2cd2:0001)

### Ports

`ttyACM0` is a binary firmware log. AT written to it **reboots the modem**, so the driver is unbound from it (`noatports.sh`). AT goes to `ttyACM1`.

### Where the command set comes from

The set is Marvell/ASR: the Luat manual for the ASR1802 (successor of the PXA1802), RouterOS logs with this card, and the modemfeed `MIKROTIK` profile for the same ID. The old 3ginfo-lite profile sent `+ZPAS/+ZCELLINFO/+ZCAINFO`, which is the R11e-LTE6 set (ASR, 2cd2:0004). The PXA1802 does not have it. These commands have not been checked on a live card.

### Metrics (`2cd20001`)

- Levels come from `+CESQ` (3GPP, known scale).
- Cell, EARFCN, bandwidth, SINR and per-antenna levels come from engineering mode: `+EEMOPT=1`, then `+EEMGINFO?` returns `+EEMLTESVC`. The query mode lasts until the modem reboots. It is re-enabled once per USB enumeration (marker `/tmp/5gmodem/r11e_eem_<tty>` holds the USB `devnum`), not on every poll.
- Marvell firmwares use **different layouts** for `+EEMLTESVC`. The manual has `<mcc>,<mnc len>,<mnc>,<tac>,<pci>,<dl earfcn>,<ul earfcn>,<band>,<bw>,<ci>,<rsrp>,<rsrq>,<sinr>,<rsrp main>,<rsrp div>,<rsrq main>,<rsrq div>,...`. The R11l-LTE7 has no `<ci>` (`659,2,65,6,235,400,18400,1,20,43,10,-4,...`). The field after bandwidth decides: a cell ID is large, while an RSRP index is at most 97.
- Levels can be 3GPP indexes or dBm. The sign tells them apart: indexes are non-negative, dBm values are negative.
- SINR has no documented scale. On the R11l-LTE7, -4 next to RSRQ -15 dB looks like dB. Accepted range -20..50. Not yet checked against a live answer.
- Per-antenna levels (main/diversity) are read only in the manual layout. Where they are in the layout without `<ci>` is unknown.
- Bandwidth: 10/15/20 are MHz, while 0/1/2/4 are 3GPP indexes (1.4/3/5/15 MHz). 3 and 5 mean different things in the two scales, so those widths are not shown.
- Cat 4: no carrier aggregation, always one carrier.
- `+CGMR: "MikroTik_CP_2.160.000_v020"`: the prefix and quotes are stripped.

### Data session (`fibocom.sh`, `IS_R11E`)

This card does **not** bring up data through `AT+CGACT`. The generic path (CGDCONT=1 + CGACT=1,1 + wait for an address on context 1) never gets an address. The working scheme is the one from the `atc-mik-r11e_lte` package (tested on a MikroTik wAP R), which RouterOS also follows:

1. `_r11e_ready`: wait until the firmware answers. The port appears before the modem responds. The reference waits for `AT+CMEE=2` to return OK, and our earlier code turned the radio off one second after the port appeared. Probes go through `atprobe.sh` (max 2 s), because bare `sms_tool` on a silent port hangs for tens of seconds.
2. `_r11e_prepare`: with the radio off (`AT+CFUN=4`), write the default-bearer settings: `AT*CGDFLT=0,"<pdp>","<apn>",,,,,,,,,,1,0,,,,,,,1`, `AT*CGDFAUTH=0,<auth>,"user","pass"`. Mode 0 means no NV write, the same as the reference and RouterOS. The settings last until the modem reboots, so they are re-applied on every USB enumeration (key: devnum + PDP + APN + auth + hash of the credentials, in `/tmp/5gmodem/r11e_prep_<iface>`). The cell or frequency lock (`AT*Cell=2,3,,<earfcn>,<pci>` / `AT*Cell=1,3,,<earfcn>`) is also lost on reboot and is re-applied here, while the radio is off. Then `AT+CFUN=1`.
3. The network brings up the context itself at registration (`+CGEV: EPS PDN ACT`, with its own cid; RouterOS showed 5). `_r11e_cid` waits up to 90 s for an active cid whose APN starts with ours (the network appends `.mncXXX.mccYYY.gprs`), otherwise the first non-IMS one. IMS contexts exist on some operators.
4. `_r11e_rdp` parses `+CGCONTRDP=<cid>`. Firmware formats differ: `cid,bearer,apn,addr` (RouterOS log), 3GPP `...,addr,gw,dns1,dns2`, or address in field 4 with mask and gateway before DNS (fields 7/8), and sometimes `a.b.c.d.m.m.m.m`. The mask is detected by a `255.` prefix. Three remaining IPv4 values are gateway + two DNS, fewer are DNS only. Without a mask (or outside /24-/30), the subnet is the smallest one from /30 up in which the address is neither the first nor the last, and the gateway is its first address (or the second, if the first is ours). The output is only digits and dots, so it is safe for `eval`.
5. A new session (watchdog cold request, PLMN change, auth lost) needs a radio cycle (`CFUN=4` / `CFUN=1`) if one has not happened yet in this setup.
6. `NO_IP_ADDRESS` does not block the restart for this card. The context arrives late, and a retry does not cycle the radio again, because the settings are marked for this enumeration.

## MikroTik R11e-LTE6 (2cd2:0004)

ASR chipset with the ZTE-like set: `+CESQ`, `+ZCAINFO?`, `+ZPAS?`, `+ZCELLINFO?`. The ICCID comes from `AT*ICCID?`.

## ASR PXA1826: Notion R281 / C300-1 (1286:4e28)

- ZTE-like firmware: levels, cell and CA come from `+ZRSSI`, `+ZCELLINFO?` and `+ZCAINFO?`, as on the ZTE MF286R (19d2:1489, also ASR). Identification uses `*READVER`, `*MRD_IMEI?` and `*ICCID?`. The profile is based on a 3ginfo-lite profile for this ID, rewritten. Not tested on the hardware, apart from the identification strings.
- One batch, `AT+ZRSSI;+ZCELLINFO?;+ZCAINFO?`. If there is no answer (the chain is not accepted, or one command error breaks it), the three commands are sent one at a time.
- `+ZRSSI: <rsrp>,<rsrq>,<rssi>,<sinr>`.
- `+ZCAINFO?` layout comes from the original profile, which the owner had checked. Split by `,`, `:` and `;` (carriers are separated by `;`). The primary carrier is `pci,band,tac,earfcn,bw`, each secondary is `pci,?,band,earfcn,bw`. Zeros mean "field absent", not PCI 0.
- The label comes from the presence of a secondary carrier, not from AcT=9. The original profile looked for CA only at AcT=9, which is no CA code in any standard. `+` is put between **all** carriers, while the original `sed 's,/,+,'` replaced only the first one.
- The module reports `+CGMI: "Marvell"`, `+CGMM: "LINUX"`. Operator and model are in the release version (`P29M29HYOTA_C300-1_SC62_CP_V002`), so the name is taken from there.
- The IMEI falls back to `*MRD_IMEI?` when `AT+GSN` is silent. The original check `[ -z "NR_I" ]` tested a string literal, so the fallback never ran.
- The protocol comes from the interface driver in sysfs, not from debugfs with a hard-coded ID, because debugfs is not mounted everywhere.

## ASKEY WWHC050 (1690:7588)

Qualcomm-style `$QCAI?` for CA, plus `+CCPUTEMP`, `+CGCELLI`, `+CGNWS`.

## BroadMobi BM806U (2020:2033)

The cell information comes from `AT+BMTCELLINFO`.

## Sierra Wireless 320U (0f3d:68aa)

An old Sierra stick. Metrics come from `AT!GSTATUS?` (RSSI, RSRP, RSRQ, SINR, temperature). EARFCN and PCI are not parsed (PCI is set to `-`). For the `!GSTATUS` format see the Sierra doc.
