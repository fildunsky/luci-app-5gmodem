# luci-app-5gmodem

A LuCI app for 4G/5G modems on OpenWrt. It merges [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) and some pieces of `modemband` into a single app.

![Screenshot](https://github.com/user-attachments/assets/d53b7a96-3a25-4198-b29d-5c1d9464e7c3)

## Features

- **Network** — signal level, operator, registration state, technology with carrier aggregation (e.g. `LTE-A | B1 + B40 / B7 / B3`), interface IPv4/IPv6, connection statistics and modem temperature (when the modem reports it).
- **Band & mode management** — pick the network mode (Auto / 2G / 3G / 4G / 4G+5G / 5G) and toggle individual LTE/NR bands via ModemManager (`mmcli`).
- **TTL fixing** — force incoming/outgoing IPv4 TTL and IPv6 hop-limit on the modem interface (via an `nftables` include in `fw4`).
- **Cell tower map** — the Cell ID is a button that opens the tower on [4cells.ru](https://4cells.ru).
- **Modem restart** — one-click `AT+CFUN=1,1`.
- **SMS Inbox / Send**, **USSD** and **AT** tabs, each with a collapsible per-tab settings panel. Optional e-mail forwarding of incoming SMS and LED/notification support.
- **Port auto-detect** — the AT port and network interface are detected automatically (via ModemManager when available); can be set manually.
- **Create modem interface** button (Modem Settings) — sets up a `network` interface for the modem automatically.

## Supported modems

Should support the modems handled by the upstream forks, plus the **Compal RXM-G1** custom firmware:

- `05c6:90d6` — Compal RXM-G1 (reports as `Tri Cascade Inc. SG500M2-X` / `VOS_5G`). SMS/USSD/AT go through ModemManager (`mmcli`) since the modem is MBIM-managed.
- `05c6:90d5` — an early RXM-G1 prototype that shares its VID:PID with the Foxconn **T99W175**. The app tells them apart by the USB descriptor (`Tri Cascade` / `VOS_5G`) and applies the right profile automatically — no manual file copying needed.

## Install

Grab the `.ipk` (OpenWrt 23.05) or `.apk` (snapshot / 24.10+) for your target from the [Releases](../../releases) page, then:

```sh
# .ipk (OpenWrt 23.05)
opkg install luci-app-5gmodem_*.ipk

# .apk (snapshot / 24.10+)
apk add --allow-untrusted luci-app-5gmodem_*.apk
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

CI (`.github/workflows/build.yml`) builds `.ipk`/`.apk` for several targets on every tag and attaches them to the release; it can also be triggered manually from the Actions tab.

## Credits

Based on the work of Rafał Wabik (IceG) and Cezary Jackiewicz. Signal-bar math adapted from [koshev-msk](https://github.com/koshev-msk). Licensed under **GPL-3.0**.
