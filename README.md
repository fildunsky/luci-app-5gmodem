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

<img width="1978" height="1506" alt="Screenshot From 2026-07-14 08-43-48" src="https://github.com/user-attachments/assets/5f9f9a63-a3c9-44a1-8f0f-4625b20c90a5" />

## Supported modems
- Fibocom FM350GL has new features and fixes here!
- Compal RXM-G1
- Telit LM960A18
- SIMCOM SIM7100E
- Quectel EC21-E
- Many more untested, but should support all the modems handled by the upstream forks.

<img width="1978" height="1506" alt="Screenshot From 2026-07-14 08-44-54" src="https://github.com/user-attachments/assets/f14f264f-ef81-47b0-8f79-bb7c6982ac55" />

## Installation
Grab the `.apk` (OpenWrt 25.12.x) or `.ipk` (24.10.x) link from the [Releases](../../releases) page then issue a command:

# .apk (OpenWrt 25.12.x)
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.2.3/luci-app-5gmodem-1.2.3-r1.apk > /tmp/luci-app-5gmodem.apk
apk update
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

# .ipk (OpenWrt 24.10.x)
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.2.3/luci-app-5gmodem_1.2.3-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg update
opkg install /tmp/luci-app-5gmodem.ipk
```

Dependencies (`sms-tool`, `comgt`, `qmi-utils`, `modemmanager`, USB-serial kmods) are pulled in automatically when installing from a feed; with a local file install them first if missing.

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
