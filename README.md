# luci-app-5gmodem

A LuCI app for 4G/5G modems on OpenWrt. It merges [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) and some pieces of `modemband` into a single app.

## Features

- **Easy create modem interface** button (Modem Settings) — sets up a `network` interface for the modem automatically.
- **Dual modem mode and uplink switcher**
- **Dual sim and eSIM switch** tested and working with FM350GL (install this `lpac` https://github.com/fildunsky/luci-app-5gmodem/blob/master/dist/lpac-2.1.0-r1.apk)!
- **Network** — advanced signal level, operator, technology with carrier aggregation (e.g. `LTE-A | B1 + B40 / B7 / B3`), interface IPv4/IPv6, connection statistics and modem temperature (if the modem reports it).
- **Band & mode management** — pick the network mode (Auto / 2G / 3G / 4G / 4G+5G / 5G) and toggle individual LTE/NR bands.
- **TTL fixing** — force incoming/outgoing IPv4 TTL and IPv6 hop-limit on the modem interface (via an `nftables` include in `fw4`).
- **Cell tower map** — the Cell ID is a button that opens the tower on [4cells.ru](https://4cells.ru).
- **Modem restart** — one-click soft radio restart `AT+CFUN=4,1` and modem reset `AT+CFUN=1,1`.
- **SMS Inbox / Send**, **USSD** and **AT** tabs, each with a collapsible per-tab settings panel. Optional e-mail forwarding of incoming SMS and LED/notification support.
- **Port auto-detect** — the AT port and network interface are detected automatically; can be set manually.
- **USB sticks that have no AT ports** (Huawei HiLink and relatives) are supported too — see below.
- **`5gtop`** — a terminal dashboard with the same data, for when you are on SSH and not in a browser.
- 
<img width="1954" height="1460" alt="Screenshot From 2026-07-19 23-06-52" src="https://github.com/user-attachments/assets/22828d57-805d-4cae-9ec0-7a24cfa884e2" />
<img width="1958" height="1426" alt="Screenshot From 2026-07-19 23-07-23" src="https://github.com/user-attachments/assets/df8e2a52-63d0-45c5-9313-67ffe1ecb872" />

## These are modems I personally have:
I've added new features to them (compared to 3ginfo and modemband)
- Fibocom FM350GL
- Compal RXM-G1
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- MeigLink SLM770A-R
- Huawei E3372 (HiLink)
- Many more untested, but should support all the modems handled by the upstream forks.

<img width="1956" height="1458" alt="Screenshot From 2026-07-19 23-07-44" src="https://github.com/user-attachments/assets/5eed741c-787a-4bf0-947d-4ebc934c7590" />

### USB sticks with no AT ports (HiLink)

Sticks like the Huawei E3372 keep the IP stack themselves: the router only sees
an Ethernet card, and everything else lives behind the stick's own web
interface. There are no AT ports at all, so the usual polling has nothing to
talk to.

The app handles them anyway:

- the modem is recognised by its USB descriptor (a stick that simply has no
  driver bound yet is *not* mistaken for one) and gets a DHCP interface;
- metrics, SMS and the operator name are read over the stick's HTTP API;
- if the stick can expose serial ports (Huawei calls it *debug mode*), the app
  switches it there automatically and then drives it like any other modem —
  which is where TAC, band, EARFCN, USSD and the AT console come from. The mode
  is reset whenever the modem reboots, so it is re-applied on every appearance.
  There is a checkbox in Modem Settings if you would rather it did not.

Bands and network mode for such a stick are changed through its API rather than
`AT^SYSCFGEX`: the AT route makes the modem drop its USB composition and fall
out of debug mode.

## 5gtop

A terminal dashboard, for when you are on SSH rather than in a browser. Same
data as the web pages, same backend — no extra polling of the modem.

```sh
5gtop        # English
5gtop ru     # Russian
```
<img width="1656" height="1226" alt="Screenshot From 2026-07-19 23-36-52" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="Screenshot From 2026-07-19 23-37-41" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

Tabs: **Network**, **Cell info**, **Modem**, **SMS**, **USSD**, **AT console**,
and **eSIM** when an eUICC is present. Keys are single-press (no Enter): the
highlighted letter in each tab name switches to it, `Tab` cycles modems in dual
modem setups, `t` runs the speed test, `r` refreshes, `q` quits. The layout
follows the terminal width and falls back to a narrow mode on small screens.

## Installation
Grab the `.apk` (OpenWrt 25.12.x) or `.ipk` (24.10.x) link from the [Releases](../../releases) page then issue a command:

# .apk (OpenWrt 25.12.x)
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.5.1/luci-app-5gmodem-1.5.1-r1.apk > /tmp/luci-app-5gmodem.apk
curl -L https://github.com/fildunsky/luci-app-5gmodem/raw/refs/heads/master/dist/lpac-2.1.0-r1.apk > /tmp/lpac.apk
apk update
apk add /tmp/lpac.apk --allow-untrusted
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

# .ipk (OpenWrt 24.10.x)
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.5.1/luci-app-5gmodem_1.5.1-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg update
opkg install /tmp/luci-app-5gmodem.ipk
```

The regular package pulls in the full set (`sms-tool`, `comgt`, `qmi-utils`, `modemmanager`, QMI/MBIM protocols, USB-serial kmods) — upgrade it over any earlier version and nothing gets removed.

For low-flash devices (MT7628 boards with 8 MB, where the full set will not install at all) there is a separate **`-lite.apk`** in the release: it requires only `sms-tool`. Metrics, SMS, USSD, band control and the AT console all work; you lose the QMI/MBIM interface protocols and the phone number read through `mmcli`. Do not use the lite build as an upgrade on a router that runs a QMI or MBIM modem — the package manager would drop those packages as orphans.

## Build from source

The package builds with the standard OpenWrt SDK. As a feed:

```sh
# in your OpenWrt — "modem" here is just a feed name you pick
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI (`.github/workflows/build.yml`) builds `.ipk`/`.apk` on every tag and attaches them to the release; it can also be triggered manually from the Actions tab.

## Credits

Based on the work of [Rafał Wabik (IceG)](https://github.com/4IceG) and [Cezary Jackiewicz](https://github.com/obsy). Signal-bar math adapted from [koshev-msk](https://github.com/koshev-msk). Licensed under **GPL-3.0**.
