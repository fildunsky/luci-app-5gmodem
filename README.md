# luci-app-5gmodem

*[Русская версия](README.ru.md)*

A LuCI app for 4G/5G modems on OpenWrt. It merges [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) and some pieces of `modemband` into a single app.

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-39" src="https://github.com/user-attachments/assets/1adb9ca6-8f38-445c-8cb8-2a0f6b8005c9" />

## Installation
Grab the `.apk` (OpenWrt 25.12.x) or `.ipk` (24.10.x) link from the [Releases](../../releases) page then issue a command:

### .apk (OpenWrt 25.12.x)
```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.0/luci-app-5gmodem-2.4.0-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

For **eSIM** (optional) install our patched `lpac` too — **pick the build for your platform** from the [lpac-build release](https://github.com/fildunsky/lpac-build/releases/latest). Example for MediaTek Filogic (e.g. WH3000):
```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

That same Filogic build is mirrored in this repo, so you can swap the URL for
`https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk`
if you would rather not go to the lpac-build release. Other platforms are only in
the release.

### .ipk (OpenWrt 24.10.x)
```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.0/luci-app-5gmodem_2.4.0-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

The regular package pulls in the full set (`sms-tool`, `comgt`, `qmi-utils`, `modemmanager`, QMI/MBIM protocols, USB-serial kmods) — upgrade it over any earlier version and nothing gets removed.

For low-flash devices (MT7628 boards with 8 MB, where the full set will not install at all) there is a separate **`-lite.apk`** in the release: it requires only `sms-tool`. Metrics, SMS, USSD, band control and the AT console all work; you lose the QMI/MBIM interface protocols and the phone number read through `mmcli`. Do not use the lite build as an upgrade on a router that runs a QMI or MBIM modem — the package manager would drop those packages as orphans.

## Features

- **Easy create modem interface** button (Modem Settings) — sets up a `network` interface for the modem automatically.
- **Dual modem mode and uplink switcher**
- **Dual sim and eSIM switch** tested and working with the Fibocom FM350-GL (AT) and Foxconn T99W175 / Thales MV31-W (MBIM) — install our patched `lpac` for your platform from the [lpac-build releases](https://github.com/fildunsky/lpac-build/releases/latest) (see the [eSIM / lpac](#esim--lpac) section below)!
- **Network** — advanced signal level, operator, technology with carrier aggregation (e.g. `LTE-A | B1 + B40 / B7 / B3`), interface IPv4/IPv6, connection statistics and modem temperature (if the modem reports it).
- **Band & mode management** — pick the network mode (Auto / 2G / 3G / 4G / 4G+5G / 5G) and toggle individual LTE/NR bands.
- **TTL fixing** — force incoming/outgoing IPv4 TTL and IPv6 hop-limit on the modem interface (via an `nftables` include in `fw4`).
- **Cell tower map** — the Cell ID is a button that opens the tower on [4cells.ru](https://4cells.ru).
- **Modem restart** — one-click soft radio restart `AT+CFUN=4,1` and modem reset `AT+CFUN=1,1`.
- **SMS Inbox / Send**, **USSD** and **AT** tabs, each with a collapsible per-tab settings panel. Optional e-mail forwarding of incoming SMS and LED/notification support.
- **Telegram bot** — incoming SMS reach the chat from every modem, and `/sms`, `/status` and `/modem` work from the chat.
- **Neighbour cells** — a table under carrier aggregation: the serving cell and its neighbours with PCI, channel and levels (Fibocom FM350-GL, QMI modems).
- **APN database update button** — refresh the world operator database (GNOME MBPI + AOSP) without reinstalling the app.
- **Port auto-detect** — the AT port and network interface are detected automatically; can be set manually.
- **USB sticks that have no AT ports** (Huawei HiLink and relatives) are supported too — see below.
- **`5gtop`** — a terminal dashboard with the same data, for when you are on SSH and not in a browser.


## Tested:
I've added new features to them (compared to 3ginfo and modemband)
- Fibocom FM350GL
- Fibocom L850
- Compal RXM-G1
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- MeigLink SLM770A-R
- Huawei E3372 (HiLink)
- Many more untested, but should support all the modems handled by the upstream forks.

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-52" src="https://github.com/user-attachments/assets/0bd100f7-780f-47e3-98a4-9729bf29ee8b" />

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

## Buttons
<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-03-18" src="https://github.com/user-attachments/assets/60a6dce9-6723-45ae-99f0-2c0ae4b7e725" />

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


## eSIM / lpac

The eSIM tab (download / enable / disable / delete profiles, notifications) needs [`lpac`](https://github.com/estkme-group/lpac). The official OpenWrt 25.12 `lpac` (2.3.0) has a broken stdio backend, so we ship a **patched build** — [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build) — with the native AT-driver robustness PRs, bare-CCHO support, and a loader fix for OpenWrt. It is a general-purpose build carrying every APDU backend (AT, QMI, uqmi, MBIM), so the app picks the right transport per modem: AT for **Fibocom FM350-GL**, MBIM/QMI for Qualcomm SDX55 modules such as **Foxconn T99W175 / Thales MV31-W**.

`.apk` files are named `lpac-<openwrt>-<target>-<subtarget>.apk`; 24.10.x builds are `.ipk`. Older releases used an `lpac-fm350-*` prefix.

Download **your platform's** `.apk` from the [latest lpac-build release](https://github.com/fildunsky/lpac-build/releases/latest):

| File | Arch | Typical devices |
|------|------|-----------------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 & new WiFi6 routers with USB |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | VMs / containers / generic ARM64 |
| `lpac-25.12.5-armsr-armv7.apk` | arm | generic ARM32 |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | Xiaomi / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | older MIPS routers with USB |
| `lpac-25.12.5-x86-64.apk` | x86_64 | mini-PC / VM routers |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<your-platform>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### Tested modems

| Modem | APDU transport | What was verified |
|-------|----------------|-------------------|
| Fibocom FM350-GL | `at` (native AT driver) | full cycle — read eUICC, download / enable / disable / delete profiles, notifications |
| Foxconn T99W175 / Thales MV31-W | `mbim` (via mbim-proxy) | eUICC read: EID, chip info, profile list, free memory. Profile download not confirmed yet |

The transport is picked automatically from the interface protocol, so you normally do not set it by hand. On the MBIM path the eUICC is reachable regardless of which SIM slot is active, so the physical SIM stays online while you work with the eSIM.

`lpac` is an **optional** dependency — the eSIM tab appears only when it is installed and an eUICC is present; the rest of the app works without it.

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

## Permissions

The app runs as **root** and exposes its capabilities through the ACL group
`luci-app-5gmodem` (`/usr/share/rpcd/acl.d/`). That group is **root-equivalent**,
which matters before granting it to anyone but a full administrator:

- it allows sending **any AT command** to the modem (via `atcmd.sh` - the AT
  console needs that by design). The `sms_tool` binary itself is no longer in the
  ACL: through it the browser could also run `send`, `delete all` and reach
  foreign `/dev/*`, with nothing able to check the arguments;
- ~~writing `/etc/crontabs/root`~~ — **removed**. That right existed only for the
  SMS-notifier restart schedule; `smscron.sh` now owns it, touching just its own
  line and validating the interval. Other cron jobs are neither read nor changed. A full administrator still has
  that capability - through LuCI's own "Scheduled Tasks" page, which is where it
  belongs;
- reading the `5gmodem` config exposes the SMTP password for SMS forwarding if
  one is set (OpenWrt keeps passwords in `/etc/config` in clear text, the same
  way it keeps the Wi-Fi key).

Do not grant this group to a restricted role such as "an operator who may only
look at the modems". There is no way around it: argument filtering lives in the
page, and the page runs in the user's browser. Such a role would need its own set
of narrow calls, not a subset of this group.

## Credits

Based on the work of [Rafał Wabik (IceG)](https://github.com/4IceG) and [Cezary Jackiewicz](https://github.com/obsy). Signal-bar math adapted from [koshev-msk](https://github.com/koshev-msk). Licensed under **GPL-3.0**.
