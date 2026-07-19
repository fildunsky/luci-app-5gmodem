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

<img width="1978" height="1506" alt="Screenshot From 2026-07-14 08-43-48" src="https://github.com/user-attachments/assets/5f9f9a63-a3c9-44a1-8f0f-4625b20c90a5" />

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

Tabs: **Network**, **Cell info**, **Modem**, **SMS**, **USSD**, **AT console**,
and **eSIM** when an eUICC is present. Keys are single-press (no Enter): the
highlighted letter in each tab name switches to it, `Tab` cycles modems in dual
modem setups, `t` runs the speed test, `r` refreshes, `q` quits. The layout
follows the terminal width and falls back to a narrow mode on small screens.

<img width="1978" height="1506" alt="Screenshot From 2026-07-14 08-44-54" src="https://github.com/user-attachments/assets/f14f264f-ef81-47b0-8f79-bb7c6982ac55" />

## What's new

### 1.5.3
- **USB sticks with no AT ports** (Huawei E3372 and relatives) are supported — metrics, SMS, bands and network mode over the stick's own HTTP API, plus automatic switching into the mode where it does expose serial ports. See *USB sticks with no AT ports* above.
- **Network mode buttons** (Auto / 2G / 3G / 4G) for Huawei, alongside the band toggles.
- **Saved modem profiles** — a card per modem the app has ever seen: interface, protocol, APN, IMEI, USB path. Deleting one removes its network interface too, unless another profile still uses it. A stale interface left behind by an unplugged modem is not harmless: one of them kept claiming a device from the modem that was actually in use.
- **ModemManager is stopped when no *connected* modem needs it.** It used to run for a modem that had been unplugged, and on startup it grabs every modem it can see — including ones explicitly hidden from it, which is how a working FM350 got switched off mid-session.
- **A modem short of power is named as such.** Such a modem still answers AT commands while its data interface never comes up, which looks like a software fault; the page now says what it is and suggests a powered hub.

### 1.5.2
- **Cell lock for FM350** (`AT+EMMCHLCK`) and **5G on/off** (`AT+E5GOPT`). The lock survives a modem reboot but the modem reports it as absent — the app remembers your choice and says so, instead of showing "not locked" while the modem sits on the locked cell.
- **Connection is restored after a radio restart.** Changing bands or the cell lock takes the modem through airplane mode, after which it re-registers on its own but the PDP context stays empty and the interface stays down — with no hint as to why.
- **USB driver table in one place.** `05c6:90d6` was being bound in two handlers with different drivers, and Compal ended up with no working AT port at all. `option1` is now used only for `05c6:9025`.
- **APN for MVNOs is picked by the code in the SIM**, not by the code of the network it registered on: T-Mobile RU reports Tele2's 250-20 while its own is 250-62, so it got Tele2's APN. Name matching never worked for Cyrillic at all — busybox `tr` walks bytes, not characters.
- **Interface protocol is checked against the driver** of its control node: Compal inherited `proto=qmi` from a Telit that used to sit in that slot, and never came up.
- **Fixes**: LED services were shipped without the execute bit and so never started; `autosetup` configures every connected modem instead of the first one; `5gtop` lists only modems that are actually on the bus.

### 1.5.1
- **Signal level on the case LEDs** (Cudy LT300 and any router exposing `white:signal1..3`). Enabled by default there, with a choice of which value drives them — RSRP, RSRQ, SINR or percent. Thresholds match the colours on the Network page, so three LEDs and a green reading mean the same thing. The modem is never polled for this: the LEDs read the same snapshot the pages do.
- **Saving Modem Settings no longer wipes the ports.** `network`, `device` and `at_port` are hidden while auto-detect is on, and LuCI drops config options whose dependencies are unmet — so one Save could erase values that the *backend* had written, leaving the app pointing at a dead port with no metrics at all. Those fields, and eleven more in the SMS settings (SMTP credentials among them), now survive.
- **Modem Settings opens immediately.** It used to wait for a full AT poll — eight seconds on an LT300 — before drawing anything. The page now renders at once and fills the modem details from the cached snapshot.
- **Two identical modems** (same VID:PID, same model) get distinguishable tabs — the USB path is appended only where names collide. Swapping them between ports is now detected by IMEI and reported, instead of silently leaving the previous modem's interface and APN bound to that slot. Nothing is deleted automatically: the page explains what happened and leaves the decision to you.
- **USSD tells you why it is unavailable.** Besides modems whose firmware has no SS support, there is now a live check for a network that registered the SIM for *SMS only* (`CREG 6/7`) — the modem supports USSD, the network simply does not provide it right now.
- **Speed test says what is missing** instead of failing silently: it needs `curl`, which is not bundled (libcurl is noticeable on 8 MB routers).
- **`5gtop`**: USSD and AT console tabs with line input, eSIM profile list and download, a SIM slot switcher, a Cell tab that no longer falls back to the Network view on narrow terminals, and per-tab hotkeys highlighted inside their own names. Multipart SMS are merged correctly (a trailing newline used to be turned into a space, splitting words across parts), incomplete messages are marked `[3/5]` — a full SIM simply cannot store the tail — and the reader is six times faster: one `jsonfilter` call per message instead of six.
- **Fixes**: the eSIM menu tab no longer flickers on every page load; the `wwan6` IPv6 twin is no longer mistaken for another modem's interface; `resolve` no longer collapses the SMS/USSD ports back onto the metrics port; a stray brace in the package postinst aborted it halfway, so the cache-busting `touch` it ends with had never actually run.

### 1.5.0
- **Inbox rebuilt as message cards.** The table is gone: each SMS is a rounded card styled exactly like the Internet-priority and speed-test buttons — sender in bold on the left, date and time small on the right, text below. Selection is a click on the card; the checkboxes are gone. Actions sit under the list, and *Forward* / *Delete* appear only when something is selected.
- **Two modems no longer step on each other.** The metrics snapshot in `/tmp` was shared by every reader and not tied to any modem, so right after a switch (or a hotplug event) the page could show the *previous* modem — and the poll could write its model into the new modem's config, producing names like "Telit Fibocom FM350-GL". The snapshot now carries the owning modem's USB path and a foreign snapshot is treated as absent.
- **SMS reads no longer fail at random.** The inbox and the metrics poll shared one AT port; `sms_tool` opens the port per call, so a read that landed during a poll came back empty (measured: 2 of 5 consecutive reads). Modems that expose several AT ports now get a dedicated one for SMS/USSD.
- **A newly plugged modem is set up on its own.** The auto-setup guard was global — if *any* modem had a working interface, a second one was never configured. It is per-modem now, and an interface left over from a different modem in the same USB port is rebuilt instead of adopted with the old modem's protocol and device.
- **Modem tabs.** Always visible (a single modem gets a tab too), drawn from the first frame using cached labels so the page no longer jumps while the list loads, and a hotplugged modem shows up **without a page reload** — the bar watches the list cache that the hotplug hook already maintains, so idle cost is a file read rather than two shell calls.
- **No more phantom "unsaved changes".** Pages wrote the message counter, ports and storage choice through LuCI's session staging, so simply opening the inbox when a new SMS had arrived raised the *Apply* banner. These writes go straight to the config now.
- **`5gtop` v2** — **English by default** (Russian only when the language is explicitly set, so it works on a bare router without LuCI), a tab bar and a modem bar mirroring the web UI, a new **Cell** tab with the full web metric set (LAC/TAC/CID, eNB, path loss, TX power, CQI, UE category, carrier aggregation table, antenna ports), live width adjustment with `+`/`-`, and terminal-theme backgrounds no longer painted over with black rectangles. The `m` key actually switches modems now — it called a command that did not exist.
- **USSD** — modems verified not to support it (Fibocom FM350-GL, Telit LM960A18: data-only modules whose firmware advertises `+CUSD` but never answers) now say so on the tab instead of leaving the user with a hung page.
- **Telit 3G bands** — the combination list is ordered by band count and frequency, and each label reads low-to-high (`850 + 1900 + 2100`) instead of the vendor's inconsistent order. `AT#CQI` is read as a metric.
- **Fixes**: deleting selected messages threw a `ReferenceError` and never ran; the phone-format hint was a global banner covering the modem tabs and app menu; the character counter moved inside the message box; the settings panel no longer floods the browser console with 404s on apk-based firmware; the character counter and prefix hint lost their separate settings toggle.

### 1.4.8
- **MeigLink SLM770A-R support** — metrics via `AT+SGCELLINFOEX` (named fields, more robust than positional CSV), temperature, band control via `^SYSCFGEX`, and cell lock via `^CELLLOCK`. Field layout verified against the vendor AT manual.
- **Cell lock** — a generic `getcelllock`/`setcelllock` contract in `bands.sh` plus a row under the band buttons. "Lock to current cell" reads EARFCN and PCI at click time, so it always pins the cell you are actually on. The modem is cycled through flight mode automatically, as the vendor manual requires.
- **`5gtop`** — the Network page in a terminal, for routers where LuCI is slow or does not fit. Same data source as the web UI, no extra AT commands. Live clock, per-metric bars, speed test (`s`), uplink priority (`1`-`3`), modem switch (`m`), and a layout that collapses to a single column on phone-width terminals (`5gtop 5 60`).
- **Extended cell info in the web UI** — eNB ID (the base station, not just the sector), path loss, TX power, CQI, UE category and VoLTE state. Rows stay hidden on modems that do not report them.
- **Lite install** — only `sms-tool` is strictly required now; ModemManager, QMI/MBIM and the USB kmods moved behind a build option. Fits routers with 8 MB flash where the full dependency set would not install at all.

### 1.4.7
- **eSIM downloads fixed** for SM-DP+ servers that present GSMA CI certificates. OpenWrt's libcurl is usually built against mbedTLS, which rejects the critical `Certificate Policies` extension in the GSMA root — such servers failed on the very first step. ES9+ now goes through a stdio bridge over wget/OpenSSL, selectable in the eSIM settings.
- **Live download progress** — the current step is shown in plain words while the spinner runs, and on failure the log stays on screen with a "Save log" button for remote diagnosis.
- **Metrics on modems that reject long AT chains** — the core poll sent twelve commands joined by `;`; some modules (MeigLink among them) answer such a chain with echo only. There is now a fallback to short groups.
- **CSQ no longer disappears forever** after a single empty signal reading — the bar was hidden but never shown again.
- **Band writes no longer report a false error** — the write outlived the 30-second rpcd timeout and surfaced as "Failed to set bands: XHR" even though it had applied.
- **Fixes**: the IPv6 companion interface no longer duplicates an uplink in Internet priority; duplicate default routes no longer pile up when switching priority; `2dee` is MeigLink, not Foxconn; SMS/USSD/AT port fields are filled in on install; multipart SMS merging is on by default.

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
