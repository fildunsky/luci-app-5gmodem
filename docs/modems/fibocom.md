# Fibocom modems and the `fibocom` netifd protocol

Fibocom modules fall into three groups here. The FM350-GL (MediaTek T700) and the L850/L860 (Intel XMM 7360/7560) have no cdc-wdm control channel that ModemManager can use, so the data session is dialed over AT by our own netifd protocol `fibocom` (`root/lib/netifd/proto/fibocom.sh`). The MikroTik R11e-LTE is dialed by the same handler (see [others-b.md](others-b.md#mikrotik-r11e-lte-2cd20001)). The Qualcomm-based Fibocom modules (FM150, FG621/FM650, NL668) use the generic QMI/MBIM paths and only have metric profiles. Metric profiles live in `root/usr/share/5gmodem/modem/usb/<vidpid>` and are sourced by `5gmodem.sh` with `$DEVICE` set to the AT port.

See also `docs/FM350-reference.md` for the FM350 AT command reference.

## Supported USB IDs

| USB ID | Model | Profile file | Data path | Metric sources |
|---|---|---|---|---|
| 0e8d:7127 | FM350-GL (`AT+GTUSBMODE` 41, RNDIS) | `0e8d7127` | proto `fibocom` | `AT+GTCCINFO?;+GTCAINFO?;+CESQ;+GTRXPATHEN?` batch, `AT+ETHERMAL?` |
| 0e8d:7126 | FM350 / T700 variant (early firmware, T700 reference PID) | `0e8d7126` (sources `0e8d7127`) | proto `fibocom` | same as 0e8d:7127 |
| 8087:095a | L850-GL / L860-GL, Intel XMM, ACM + NCM | `8087095a` | proto `fibocom` (XMM branch) | `AT+XLEC?;+XMCI=1;+XCCINFO=1;+XCCINFO?`, `at@errc:pcell_scell_measurement_info()`, `AT+MTSM=1` |
| 8087:07f9 | L850/L860 transient boot state (bcdDevice 0.00), seen for seconds before 8087:095a | `808707f9` (sources `8087095a`) | - | same as 8087:095a |
| 2cb7:000b | L850/L860 in `AT+GTUSBMODE=11`: 3x CDC-ACM + 3x CDC-NCM under the Fibocom VID | `2cb7000b` (sources `8087095a`) | proto `fibocom` (XMM branch) | same as 8087:095a |
| 2cb7:0007 | L850-GL MBIM composition | `2cb70007` | MBIM | `at+xlec?;+rsrp?;+rsrq?;+xmci=1`, `AT+XCCINFO`, `at@errc:...` |
| 2cb7:0104 | FM150-AE / FG150 / NL952 | `2cb70104` | QMI/MBIM | `at+gtccinfo?;+gtcainfo?`, `AT+MTSM=1` |
| 2cb7:0a04-0a07 | FG621-EA / FM650 | `2cb70a05` | QMI/MBIM/ECM | `AT+GTCCINFO?;+GTCAINFO?`, `AT+MTSM=1` |
| 2cb7:0110 | NL668-EAU (MBIM) | `2cb70110` (sources `15081001`) | MBIM | `AT+GTCCINFO?` |

The 2cb7:0104 and 2cb7:0a05 profiles pick the network-card protocol from the driver of this modem's own interfaces only. An empty `BASE` (port gone mid-poll) used to `grep ""` every interface of the router, and a path prefix without a trailing `/` (`1-1`) also matched the neighbour on `1-1.2`.

## Protocol `fibocom`

### Overview

The dial sequence is plain 3GPP: `AT+CGDCONT` -> `AT+CGACT=1,1` -> `AT+CGPADDR` (IPv4) -> `AT+CGCONTRDP` (gateway/DNS). The address is set statically on the usbnet device, because the modem runs no DHCP. The interface is bound to the modem by its USB topology path (`usbpath`), so it survives ttyUSB/eth renumbering.

Interface options: `usbpath` (preferred), `modem_path` (ownership stamp written by the app, fallback), `device` (usbnet name, used only without `usbpath`), `atport` (auto-picked if unset), `apn` (default `internet`), `pdptype`, `auth`/`username`/`password`, `metric`, `allow_roaming`, `sourcefilter`.

### Finding the netdev and AT port

- `_fibocom_netdev` picks the interface with the **numerically lowest** interface number, not the first glob match. ASCII order puts `1.10` before `1.6`. The L860 has three NCM functions (1.6/1.8/1.10), and `XDATACHANNEL ... "/USBHS/NCM/0"` binds the first NCM (1.6). With glob order the protocol published on `wwan2` and got no traffic.
- `_fibocom_atport` globs four forms. usb-serial (`option`) puts the tty directly under the interface (`<path>:1.2/ttyUSB0`). `cdc_acm` (XMM) registers it through the class directory (`<path>:1.0/tty/ttyACM0`). With only the first form, L850/L860 never found an AT port and failed with `NO_AT_PORT` and nothing in the log. The same set of forms is in `portmap.sh`.
- The dial port avoids the app's metrics port when another AT-capable port exists, so that the metrics poll and the dial do not get each other's replies.
- If no netdev exists, the handler loads `rndis_host` and `cdc_ether` and waits up to 5 s. The FM350 in RNDIS mode (`GTUSBMODE 41`, IAD `Cls=e0 Sub=01 Prot=03`) needs `rndis_host`. Some images (Cudy WBR3000UAX, kernel 6.12) do not load it until asked, so the interfaces stay at `Driver=(none)`. Loading a usbnet module rescans devices that are already plugged in.
- A `device` from uci that does not exist in `/sys/class/net` gets `NETDEV_MISSING` + `proto_block_restart`. Before this, `proto_send_update` on a missing `wwanN` returned "Unknown error", and netifd restarted the interface every 5 s.
- A stale `usbpath` is detected when no USB device exists at that path but one exists at `modem_path`. `usbpath` is written once at interface creation, and the modem may move to another port.

### AT port queue

The whole bring-up holds `at_lock` from `atlock.sh` (wait up to 20 s, then go on without it). Without the lock, the metrics poll and third-party packages (3ginfo-lite, sms-tool-js, modemband) shared the tty, and replies got crossed. In one field case the interface got another reader's `CGPADDR` answer (a wrong address, no traffic). The lock is released by `_fib_unlock` on every exit path, and before `proto_send_update`.

### PDP type normalisation

The UI and old configs store `IPV4`. Valid `CGDCONT` values are only `IP`, `IPV6` and `IPV4V6`. The FM350 accepts `IPV4`, but the L860 answers `ERROR`. The context was then never rewritten, the old APN from the previous SIM stayed, and every ifup went to a cold dial. `IPV4` is mapped to `IP`, and anything unknown to `IPV4V6`.

### Registration gate

Registration is read once, before dialing (`_fibocom_reg`). The handler waits up to 60 s in 5 s steps, which also throttles netifd retries.

- `_fibocom_reg` reads `+CEREG`, then `+C5GREG`, then `+CREG`. `+CREG` is asked whenever neither of the first two shows registration, so a modem registered on 3G only is not reported as unregistered. The patterns allow spaces after commas. The Altair ALT3800 answers `+CEREG: 2, 1, 4554, 000DB80B, 7` when registered, and a pattern without spaces returned empty exactly when it was registered.
- Codes: 1/6/9 home, 5/7/10 roaming, 3 denied, others mean no network.
- **Deregistered modem**: if `+COPS?` mode is 2 (deregistered), the modem will not search on its own. The handler sends `AT+COPS=0` once per attempt. It goes by the `+COPS` mode and not by the `+CEREG` stat: after `COPS=2` the FM350 reports stat 4, not 0. Mode 1 (manual) is a user choice and is left alone.
- **Roaming**: the FM350 has no data-roaming switch (AT manual v2.2 has none; roaming appears only as a PDP type in `+EIAAPN`). As in `mbim.sh`, the handler refuses to dial on a roaming registration when `allow_roaming` is off (`ROAMING_NOT_ALLOWED`, restart blocked).
- **Denied (stat 3)**: unregistered SIM, unpaid plan or blocked IMEI. Retrying does not help, so the restart is blocked (`REGISTRATION_DENIED`). `_fibocom_why` logs `+CEER`, and for XMM it warns if `AT+CFSN?` is empty. An XMM module with a wiped serial is refused by the network, and the serial can be written only once.
- **No network**: `NOT_REGISTERED`, restart **not** blocked, so the interface comes back on its own. Earlier the handler dialed anyway, failed with `NO_IP_ADDRESS` + `proto_block_restart`, and the interface never came back without a manual ifup.

### Band restore before the dial

After a reboot the FM350 resets its band mask to "all" and activates context 1 on its own. On the first bring-up of each modem enumeration (marker `/tmp/5gmodem/bandsprep_<iface>` keyed by USB `devnum`), the protocol runs `bands.sh restorebands prepare` before dialing. Exit 0 means the mask was rewritten, which forces a cold dial. Exit 3 means the mask already matched. The handler also touches `/tmp/5gmodem/bandrestore_<iface>`, so that the ifup hook `31-5gmodem-bands` does not reconnect a second time (that was the visible "double bring-up").

### Fast path (reuse of an active context)

netifd runs teardown+setup on every reconfigure, for example a route-metric change from the WAN-priority switcher. A cold re-dial cost 30-60 s each time. When `AT+CGACT?` shows `1,1`, setup reuses the context. It is skipped when:

- bands were just changed;
- the PLMN changed since the last successful dial (`/tmp/5gmodem/fibo_plmn_<iface>`). The network can drop the session while the modem still reports `CGACT 1,1` and the old `CGPADDR`. This was seen on a long trip across regions. Checking TAC instead would break the session at every tracking-area update, so only a PLMN change counts;
- a watchdog left `/tmp/5gmodem/fibo_cold_<iface>` ("plain ifup already failed");
- PAP/CHAP is configured and the USB `devnum` differs from the one stored when `CGAUTH` was last sent (see below);
- the live context's APN or PDP type differs from the configuration. The FM350 activates context 1 at boot with the last APN it had (for example from a previous eSIM), so without the APN check a new APN was never applied. Without the PDP-type check, IPV4V6 over an IPv4-only bearer never gets IPv6. An empty `apn` skips the APN check. `/tmp/5gmodem/fibo_pdpalt_<iface>` records an accepted PDP fallback;
- `AT+CGATT?` is not 1. This is the same idea as `qmi.sh` checking `get-data-status`: an "active" context on a detached modem carries no traffic.

### Cold dial

`_fibocom_activate`:

- Sends `AT+CGACT=0,1` before activating. A bare re-activate hangs when the context is wedged half-active, which is the state that `AT+GTACT` (band change) leaves on the FM350. On a cold context the release does nothing.
- Never sends `AT+CGACT=1,1` while `AT+CGACT?` already shows `1,1`. Re-activating an active context crashes the modem (`+CME ERROR: 500`, reboot, `ttyACM0` gone).
- Retries 6 times with 2 s pauses. After a modem swap or USB re-enumeration the context needs a moment.
- **PDP type fallback**: if the configured type gives no IP, it retries once with the other type (IP <-> IPV4V6). Tele2 RU (PLMN 25020) registers, but `CGACT` hangs on IPV4 and works on IPV4V6 (seen on FM350). `AT+EIAAPN` (initial attach APN) returns `ERROR` on this firmware, so the attach APN cannot be set to match.
- `NO_IP_ADDRESS` blocks the restart, except on the R11e-LTE, where the network brings up the context by itself and late.

### PAP/CHAP authentication

Some MVNOs (for example Ekomobile, APN + login + password) give an address without auth but drop the traffic. `_fibocom_auth` uses the 3GPP `AT+CGAUTH=<cid>,<1 PAP|2 CHAP>,"user","pass"`, and resets with `CGAUTH=<cid>,0`. On XMM it sends `AT+XGAUTH` first and falls back to `CGAUTH` on `ERROR`. The login is lost when the module re-enumerates, while the FM350 brings context 1 back after a reboot **without** auth. So the handler stores the USB `devnum` in `/tmp/5gmodem/fibocom_authed_<iface>`, and the fast path is refused when it changes. Without this, a usbpower recovery reused an unauthorised bearer: IP present, no traffic.

### Intel XMM specifics (L850/L860, 8087:* and 2cb7:000b)

- `AT+XDNS=1,1` must be sent before activation, or `+XDNS?` stays empty. DNS comes from `+XDNS?`, because `CGCONTRDP` is empty.
- After an address is assigned: `AT+XDATACHANNEL=1,1,"/USBCDC/<n>","/USBHS/NCM/0",2,1` and `AT+CGDATA="M-RAW_IP",1`. Without them the address exists, but no frames cross the NCM. `<n>` is the ACM index of the dial port, counted over the modem's ACM interfaces, because XDATACHANNEL binds that specific ACM. In mode 11 the router-facing AT port is ACM2 (both `/USBCDC/0` and `/USBCDC/2` appear in field logs).
- The NCM link does not answer ARP: `ip link set <dev> arp off`, no gateway, on-link default route.
- This logic came from `xmm.sh` (modemfeed), so that package is no longer needed.

### IPv6

The routable prefix does not come from `CGPADDR`, which gives only link-local or interface-id. It arrives by RA / DHCPv6-PD on the usbnet link. If the live context type contains `V6`, setup adds a dynamic `dhcpv6` child `<iface>_6` (`ifname @<iface>`, `extendprefix 1`). The child gets the parent's firewall zone (`_fibocom_fwzone`: `fw3 -q network`, or a uci zone lookup on fw4), or its RA/DHCPv6 replies hit the default INPUT policy. Some networks (seen on FM350) also need an explicit rule that accepts ICMPv6 from `fe80::1` on `wan`.

### Teardown keeps the bearer

`proto_fibocom_teardown` does nothing on purpose:

- It does not deactivate the PDP context. Releasing it on every reconfigure broke the session on each priority switch, and the bearer costs nothing while the interface is down. A real disconnect happens on USB re-enumeration or through modem controls.
- It does not call `proto_init_update "*" 0` + `proto_send_update` as `qmi.sh`/`mbim.sh` do. netifd calls teardown after it has already moved to `S_TEARDOWN`, and `proto_ext_update_link` (netifd `proto-ext.c`) then returns `UBUS_STATUS_PERMISSION_DENIED`. That logged `Command failed: ubus call network.interface notify_proto ... (Permission denied)` on every drop. `proto_notify_error` uses another handler and still gets through.

## FM350-GL (0e8d:7127) metrics profile

- **One batch per poll**: `AT+GTCCINFO?;+GTCAINFO?;+CESQ;+GTRXPATHEN?`. Order matters, because if the modem rejects a command, everything to its right gets no answer. `AT+ECELL` was removed from the poll in 2.5.x: around that time the metrics port got stuck for minutes (`sms_tool` in D state), and cell/TAC come from `+CREG` anyway.
- **AcT=13 is not 5G**. `+COPS: ...,13` means EN-DC capable. With `+C5GREG: 0`, a single rat=4 row and two LTE carriers, the honest label is "4G+". The label is decided after parsing the carriers: any NR carrier gives `5G NSA`, several LTE carriers give `LTE-A |`, one carrier gives `LTE |` (without this the framework put `-` for an unknown AcT).
- **GTCCINFO serving row** (manual V2.10, 11.1.15): `idx,rat,mcc,mnc,TAC(hex),CellID(hex),EARFCN,PCI,band,bw,SINR,rxlev,RSRP,RSRQ`. The legacy code swapped EARFCN and PCI, so in RRC idle (empty GTCAINFO) the band was computed from the PCI and jumped between B1 and B3. Up to ten neighbours per RAT are printed and the RAT order is not fixed, so the serving row is matched by `^1,[49],` and not by `grep -A3`.
- This firmware leaves the band field empty. The band is derived from EARFCN (`earfcn2band`, 3GPP TS 36.101 Table 5.7.3-1). When present, the band is `index+100`, and only in RRC connected.
- Values outside the manual's ranges are dropped. During reinit the firmware sends garbage (`rssnr=8192`, which showed as "SINR 4096 dB").
- **Neighbours** come from the same GTCCINFO reply (rows with index 2), in the same object format as `_qr_nb` in `5gmodem.sh`. Serving LTE has 14 fields, a neighbour LTE row has 12 (`...,earfcn,pci,bw,rxlev,rsrp,rsrq`). RSRP = idx-141 (LTE) / idx-157 (NR), RSRQ = -20 + idx/2, WCDMA RSCP = idx-121. 255 means "no data". Strip `\r`, or the last field (rsrq) fails the numeric check.
- **3G**: with no rat 4/9 row, metrics come from `+CESQ` (`rxlev,ber,rscp,ecno,rsrq,rsrp`, extended with NR fields on FM350). RSCP is 0..96 -> -121+n dBm, Ec/No is 0..49 -> -24+0.5n dB.
- **GTCAINFO PCC** has one more field than the manual (`ul_bw`): `band,pci,earfcn,dl_bw,ul_bw,dl_mimo,ul_mimo,dl_mod,ul_mod,rsrp`, for example `PCC:107,366,3400,50,50,1,1,1,1,-104`. The format changed between firmwares, so the layout is chosen by field count (11 with the header = with `ul_bw`). MIMO is valid only in 1..4. **SCC** follows the manual: `state,ul_cfg,band,pci,earfcn,dl_bw,ul_bw,dl_mimo,ul_mimo,dl_mod,ul_mod,rsrp`. SCC RSRP is already in dBm. Modulation codes: 0 BPSK, 1 QPSK, 2 16QAM, 3 64QAM, 4 256QAM, 5 1024QAM.
- **RX paths**: `+GTRXPATHEN: <rat>,<mask>`, where rat is 1 UMTS, 3 LTE, 15 NR. The mask bits are 1 main, 2 aux/DG, 4 MIMO main, 8 MIMO aux. The FM350 gives no per-antenna levels, so `ANTPORTS` stays empty and only the diversity verdict is filled. Two of four paths halves the downlink, which explains the common "speed is half of what was promised" report.
- **Signal bar**: raw `+CSQ` is narrowband on the FM350 (reads ~8-9 = 26% on decent LTE). RSRP alone overstates bad links (RSRP -107 with SINR 1 dB and RSRQ -15 dB). The bar is weighted: RSRP 50% (-130..-80), SINR 30% (-10..20), RSRQ 20% (-20..-3), with missing metrics renormalised. The last good value is cached in `/tmp/5gmodem/fm350_sig_<tty>`. If the serving row is missing for one poll, RSRP falls back to `+CESQ` (rsrp-141).
- **Temperature** (`AT+ETHERMAL?`): during reinit the sensors return placeholders (32767, -127, -28479), which are filtered. The profile takes the **maximum** over zones and not the average: the ambient zone (~25 °C) pulled the average down. Fields are counted from the `+ETHERMAL:` marker, because a reply glued to another reader's `+CSQ: 25,99` produced 25 °C. The sensor also really returns a single low value (25 within a run of 53-57), so a jump of more than 15 °C (within 120 s of the previous value) is accepted only after 3 consecutive confirmations. A run of two bad values was seen, so 2 confirmations are not enough (`/tmp/5gmodem/temp_<tty>`: `value count time`). The `IFS=' '` before `read` is required, because the profile sets IFS to newline earlier.

## L850/L860 (Intel XMM) metrics profiles

- `8087095a` (ACM/NCM) and `2cb70007` (MBIM) save the batch into `_XMCI_RAW` before `$O` is reused for CGSN/CIMI/CCID.
- **XMCI**: type 4 is the serving cell, type 5 a neighbour. PCI and EARFCN are hex (`0x016E` = 366, `0x00000D48` = 3400). Placeholders are all-F values and mcc/mnc `000`. These were checked against Intel's own counters on a live L850: `AT+RSRP?` -104.00 at XMCI rsrp=37 (37-141), `AT+RSRQ?` -14.50 at rsrq=16. So RSRQ = (raw-45)/2 (Intel scale), not -20+raw/2 or 3GPP idx/2-19.5. SINR = raw/4+5, 255 = no data.
- **CA convention**: `lte_ca = XLEC[3]-1`, SCC bands from the XLEC tail (zeros are empty slots), SCC PCI/EARFCN from `AT+RSRP?` matched by band. This follows modemfeed/modeminfo `scripts/INTEL` and is not a bug (an attempt to "fix" it through XMCI type 4 was reverted). Firmwares without `BAND_LTE_` in XLEC get bands from EARFCN. SCCs are not listed as neighbours.
- busybox awk has no `strtonum` ("Call to undefined function"), so hex fields are converted by hand. `2cb70007` has its own short EARFCN-to-band table, because `channeltoband` is not available in that profile. Profile fields come with leading spaces (`" 366"`), so they are trimmed before `channeltoband`.
- **Antenna ports**: `at@errc:pcell_scell_measurement_info()` returns `rsrp[RX0,RX1,...] , rsrq[...] , rssnr[...] , imbal[dB]`, which only XMM has. The L850 has two RX paths. A connected L860 returns four (`rsrp[-75.75,-78.50,-75.75,-78.50]`). `-32768` means no data. Ports are published only when at least two paths parse, so the table height does not jump between polls. RXDIV is `2rx` if RX1 is above -130 dBm.
- **CSQ from RSRP**: with bandwidth index 0 (1.4 MHz) `NP=6`, because `NP=0` made `log(0)` break the RSSI formula.
- **Model name**: the L850 has echo on (ATE1) and unusual replies (`+CGMI: Fibocom L850 LTE Module`, `+CGMM: "L850 LTE Module","L850"`). `_atval` skips echo/OK/ERROR lines and strips `+CMD:` and quotes. The old parser put the echo into the model name (and on a shared port, strings like `AT+GTDUALSIM?`).
- `MODE` normalisation: internal `LTE_A` becomes `LTE-A |`, and `/` between carriers becomes `+`.

## PCIe / MHI variants (`modem/pci/`)

For a module on PCIe the poll builds the profile key as `pci/<vendor><device>`. The AT set does not depend on the bus, so these files reuse the USB profile and only work out the data-channel protocol: there is no USB interface driver to look at, so they check which node the module exposed next to the AT port (`wwan<N>mbim<M>` → MBIM, `wwan<N>qmi<M>` → QMI).

- `pci/14c34d75` — FM350-GL under `mtk_t7xx`. 14c3:4d75 is the PCI VID/DID of every variant; only SUBSYS differs (HP/Lenovo/Dell/generic). With PCIe lanes in the slot the module forces PCIe mode and no ttyUSB/ttyACM appears at all: only `/dev/wwan0at0` and `/dev/wwan0mbim0`. t7xx creates no QMI channel, so MBIM is also the default when the channel node is not visible.
