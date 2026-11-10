# Android phones over USB: ADB telemetry and data-SIM selection

USB tethering remains a DHCP/RNDIS connection managed by the existing phone
path. For an Android tethering device with an ADB interface, `5gmodem.sh`
also calls `android.sh` and publishes `backend=android`. No AT port, root,
bootloader unlock, Android APK or network ADB listener is required.

## Setup and tested hardware

Enable USB debugging and USB tethering on the phone. When it is connected
to the router, unlock the phone and authorize that router's ADB key. A key
authorized for a desktop computer does not authorize the router. `adb` is
already a package dependency. Without an accessible, authorized ADB
interface the device keeps the ordinary tethering view and internet setup.
Polling does not change USB mode, pairing, network configuration or radio
settings, and does not reboot the phone. An explicit SIM-button action can
change the subscription used for mobile data, as described below.

Initial hardware testing used Xiaomi 17 (`pudding_global`, 25113PN0EG),
stock HyperOS `OS3.0.332.0.XPCMIXM`, Android 17 / SDK 37, locked bootloader,
no root. USB `2717:ff88` exposes RNDIS and ADB simultaneously. Host-side
live tests confirmed telemetry while the phone shared Wi-Fi and while it
selected cellular `rmnet_data3` as its USB tethering upstream. The reader
and normal poller were subsequently tested on Cudy TR3000 v1, OpenWrt
25.12.6, with the stock ADB 1.0.32 package. An interface-bound HTTPS request
through the phone returned HTTP 200 while the wired WAN stayed primary
(metric 0 versus USB metric 20). Other phones are not yet validated;
Android dumps are vendor- and version-dependent.

## Device and SIM selection

The reader requires USB interface `ff/42/01` and takes the serial from the
selected USB device's sysfs directory. Every ADB operation uses that exact
serial. It never falls back to the only connected ADB device. Each ADB
command has an eight-second watchdog and failures return to the existing
tethering display instead of querying an unrelated modem.

The router pushes `android-probe.sh` to `/data/local/tmp/5gmodem-probe.sh`
only when its content changes, then executes it with a short ADB command.
This avoids ADB 1.0.32's 1024-byte service-name limit. The helper reads device
properties, `telephony.registry`, the slot-to-subscription mapping from
`isub`, available phone numbers through `cmd phone get-phone-number`,
battery, current thermal HAL/sysfs readings and the current tethering
upstream. It does not modify radio settings. A failed invocation clears
the helper's local installation marker so the next attempt can restore it.
The normal cached poll reuses Android snapshots for up to five seconds. `android-metrics.awk`
requires the final completion marker and a known active data subscription
before returning metrics. It deliberately does not choose the first SIM
if that mapping is missing.

Canonical metrics belong to the active data subscription. `android_sims`
also contains separate records for both slots. LuCI uses the normal SIM
buttons in their existing location and highlights the active data slot.
Switching is enabled when the helper finds the system setter and the shell
holds MODIFY_PHONE_STATE; otherwise the same buttons remain read-only. Its number, when supplied
by Android, uses the normal `phone` field and display; changing subscriptions
also resets the UI's retained phone-number state. Slot IDs are zero-based in JSON and
one-based in the display. Subscription IDs are independent identifiers.
The tethering upstream is reported separately, because USB can share
Wi-Fi while a cellular SIM remains selected for mobile data.

## Supported fields and limits

- Device marketing/model name and firmware, operator and MCC/MNC,
  WWAN registration and RAT, and active data slot/subscription.
- For the tested LTE format: RSSI, RSRP, RSRQ, RSSNR, level, service-state
  channel, primary physical-channel PCI and downlink bandwidth. CSQ is
  calculated from RSSI using the existing AT 0–31 scale and tagged
  `csq_source=rssi`; it is not claimed to be a direct AT response. RSSNR is
  already dB; bandwidth is converted from kHz to MHz. The normal poller
  uses its existing LTE EARFCN lookup to derive the band and includes it
  in `mode`, so the normal card renders `4G | B3`. The Android CA flag and
  secondary LTE physical-channel records feed the normal `s1`–`s4` carrier
  fields and `4G+` display when available. Unknown channel zeroes cannot be
  used to invent additional bands. Live snapshots currently show one
  serving LTE carrier; multi-carrier parsing is covered by synthetic tests.
- Battery charge and charging state use the existing `battery` and
  `battery_charging` fields and indicator. No separate Android battery row.
- Temperature summaries use the existing typed badges: modem subsystem
  (`mdmss-*`), CPU, GPU, battery, skin, PA, Wi-Fi, PMIC, charger and board.
  `mtemp` is the maximum available modem-subsystem sensor, not the battery
  or CPU. Valid individual sysfs temperatures are also provided through
  `temperature_sensors`; 84 were readable on this phone. Voltage/current,
  BCL levels, hardware-trip thresholds and unavailable -273 C values are
  excluded. Only the normal typed temperature indicators are shown when
  expanding the main temperature, using the same renderer as other modems.
  The raw list of 84 sensors is retained in telemetry/diagnostics and is
  not rendered in the card or popup. The experimental scrolling grid was
  removed at the user's request.
- Interface address, host-interface traffic and interface uptime use the
  existing OpenWrt network state. Cellular measurements do not prove
  end-to-end internet availability.
- Carrier aggregation: ServiceState's `isUsingCarrierAggregation` and
  `mCellBandwidths` give the number of aggregated carriers and their total
  width (`android_ca_carriers`, `android_ca_bandwidth`; seen on this phone as
  `[10, 20, 20]` MHz under load). The phone does not report the bands of the
  secondary carriers (`PhysicalChannelConfig` only lists the primary one), so
  the card shows `3CA · 50 MHz` without per-carrier rows.
- Timing advance and CQI from the LTE signal record, only when Android reports
  a real value (it reports the `2147483647` sentinel without an RRC
  connection). Timing advance also fills the card's `~N m` distance to the
  base station (`bs_distance`, 78.125 m per step).
- Modem firmware is the baseband (`gsm.version.baseband`, e.g. `MPSS.DE.9.0-…`);
  the Android build stays in `android_build`. Two identical per-SIM values are
  shown once.
- The mobile data APN and PDP type of the tethering upstream interface, from
  the matching `NetworkAgentInfo` in `dumpsys connectivity` (the IMS network is
  never shown as the APN). Interface addresses are not published.
- VoLTE and Wi-Fi Calling availability per SIM (`isVolteAvailable()` and
  `isWifiCallingAvailable()` through the DEX helper). Measured on this phone:
  Beeline has VoLTE, T2 (T-Mobile) does not.
- Battery voltage and health from `dumpsys battery` and the thermal status from
  `thermalservice`; they extend the battery indicator's tooltip. Battery
  current and charge cycles are not readable (`/sys/class/power_supply` gives
  `Permission denied` to the shell UID).
- 5G NSA (not verified on a real NR network, none of the tested SIMs has one):
  a fresh NR cell that is registered or reported as a serving cell becomes the
  next free secondary-carrier row (`n78 | PCI | NRARFCN | SS-RSRP/RSRQ/SINR`)
  and the mode becomes `5G NSA`. Standalone NR is not parsed; the mode text
  shows `NR` without LTE measurements.

Out-of-range values and Android's `2147483647` sentinel are omitted.
Unknown band/frequency zeroes from the physical-channel dump are not used.
Wi-Fi calling's IWLAN RAT does not replace the WWAN RAT. No LTE signal
fields are reused as NR measurements. Current HAL readings are used;
cached temperatures, thresholds, voltage and current records are ignored.

Cell ID and TAC are redacted in the tested firmware's textual `dumpsys`
output, but are available through explicit Android getters. The optional
packaged DEX helper described below supplies them without root. Old global
cell-info timestamps can remain stale across polls; those records are not
published as current neighbours. The collection timestamp describes the poll, not the age of
every underlying Android radio callback. MIMO, modulation, transmit
power, USSD and phone/radio restart remain unimplemented; network mode and
band selection are described [below](#network-mode-and-band-selection).
Internal `/dev/at_mdm0` and `/dev/at_usb*` are owned by radio and inaccessible
to the shell UID, so arbitrary AT commands are not exposed. LuCI hides the
modem restart control and does not issue modem SIM-switch queries; the
frequency block shows the phone's network modes and bands.
There is no suitable `cmd phone` data-SIM command, but the Java helper
exposes the validated system SubscriptionManager API described below.

## Mobile-data SIM selection and SIM identifiers

The DEX helper supports `slots` and `set-data <one-based-slot>` (and, for the network
mode and band controls below, `radio`, `set-mode`, `set-bands` and `reset-bands`). It reads
SubscriptionManager's active subscription list, resolves the selected slot
to its current subscription ID and calls the system
`SubscriptionManager.setDefaultDataSubId()`. It validates permissions and
active-slot membership before setting anything; selecting the current
subscription is a no-op. The result distinguishes the configured default
from the asynchronously changing active data subscription and confirms the
setter's result before reporting `ok=true`.

This selects the SIM used for cellular internet. Both phone SIMs remain
enabled. It does not change the default voice/SMS subscriptions, APNs,
roaming/data-enable preferences or router routes, and issues no modem
restart. The existing `simslot.sh` routes Android requests before its
legacy cache cleanup / AT / ModemManager logic. Only this phone's snapshot
and SIM-status caches are invalidated after a confirmed selection; errors
do not clear caches. The normal SIM renderer and switch handler are shared
with other modems; Android uses the standard card-sized progress overlay, without a separate
modal. It closes when polling confirms the requested data slot is active
and connected, or immediately on error; the estimated bar does not itself
prove completion. The active button updates through normal polling. Empty phone slots are disabled. Enabled buttons omit the `disabled`
attribute: LuCI serializes boolean false as the string "false", which
still disables an HTML button.

On the tested Xiaomi, SIM 2 maps to sub 5 and SIM 1 to sub 1. Repeated
2→1→2 cycles succeeded through both the native helper and normal
`simslot.sh` interface. HTTPS HEAD requests to ya.ru over USB returned 302
on each SIM. An example.com test timed out even after restoration, so it
was not used as proof of switch failure or general internet availability.
Original data SIM 2 was restored. Default voice/SMS stayed at sub 1 and
wired WAN remained the router's preferred route.

The helper also uses per-subscription TelephonyManager instances to read
`getSubscriberId()`, `getSimSerialNumber()` and `getImei()`. IMSI, ICCID and
the corresponding slot's IMEI populate the normal `imsi`, `iccid`, `imei`
fields, so the existing SIM hover tooltip updates automatically. Missing
or invalid identifiers are omitted. Both slots returned all three values
on this phone; the live main snapshot matched the selected slot's values
after switching. Identifiers are not included in committed fixtures/logs.

Direct router commands use the usual target path:

```sh
/usr/share/5gmodem/simslot.sh status for=<usb-path>
/usr/share/5gmodem/simslot.sh set 1 for=<usb-path>
```

The system API and permission requirements are documented in
[SubscriptionManager source](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/telephony/java/android/telephony/SubscriptionManager.java).
No new Android permission was granted for these operations.

## Cell identity and neighbours through Android API

`android-cells.dex` is a small architecture-independent helper invoked with
`app_process`, as the existing shell UID. No APK, root or bootloader unlock
is required. `CellProbe.java`, the SDK callback declaration used only at
compile time, and `build.sh` are in `tools/android-cells/`. The package
contains the compiled DEX so an OpenWrt SDK build needs no Java toolchain.

The helper initializes the process-local telephony service manager and a
context attributed to `com.android.shell` / UID 2000. Android still checks
that identity and its existing location/phone permissions. This fixes the
system context's otherwise incorrect `android` package attribution; no
permissions are granted or device policy changed. Reflection against
private Android context internals is version-dependent. Tested on this
phone's SDK 37; DEX targets API 31+. If the helper fails, base telemetry
continues without the extra cell data.

For the requested subscription only, it reads WWAN service-state identity
getters and calls `requestCellInfoUpdate()` with a four-second callback
wait. It does not use the global `getAllCellInfo()` list to assign
neighbours to a SIM: the initial global list contained both SIMs and
records over eight hours old. A successful active-SIM callback initially
returned a serving LTE cell and two neighbours. Counts change with radio
conditions; later captures returned one neighbour.

`android-cells.awk` checks the subscription and matches the serving PCI /
EARFCN against the base snapshot before attaching data. Callback records
must have valid identities and timestamps no older than 30 seconds and
not in the future. Current service-state identity can still be used when
an update has no cells. Normal fields include `cid_dec` / `cid_hex`,
`tac_dec` / `tac_hex`, `tac_d` / `tac_h`, and LTE `enbid`. GSM/UMTS use
`lac_dec` / `lac_hex` instead; TAC is never copied into a LAC field. The
phone card uses one **LAC/TAC** row, preferring TAC for LTE.

Fresh LTE measurements populate the existing `neighbors` table, including
the serving row, PCI, EARFCN, an available band and signal measurements.
Unknown neighbour CI/TAC remain unavailable. An empty fresh list hides the
Android neighbour table rather than retaining old rows. Cell locking is
not enabled.

To rebuild the DEX with a local JDK and the official R8 artifact:

```sh
JAVA_HOME=/path/to/jdk R8_JAR=/path/to/r8.jar \
  luci-app-5gmodem/tools/android-cells/build.sh
```

The tested toolchain is OpenJDK 21, Java 8 class-file target, and R8/D8
9.5.29 from [Google Maven](https://dl.google.com/dl/android/maven2/com/android/tools/r8/9.5.29/r8-9.5.29.jar).
R8 jar SHA-256: `f8c762ff84640b10083b934a47278758a7665977e618fab0c927fff00521dea3`.
The callback stub is a compilation declaration, not a replacement Android
framework class, and is excluded from the DEX. Only `CellProbe*.class`
files are packaged. Sources of API behaviour:
[TelephonyManager](https://developer.android.com/reference/android/telephony/TelephonyManager),
[TelephonyFrameworkInitializer](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/telephony/java/android/telephony/TelephonyFrameworkInitializer.java).

## Network mode and band selection

Both act on the **active data SIM** (the SIM whose metrics the card shows),
through the same DEX helper as the SIM switch and with the same permission
(`MODIFY_PHONE_STATE`, held by the shell UID). No root and no unlocked
bootloader. The standard "Frequency management" block of the Network page is
shown for the phone and uses `bands.sh` unchanged: `bands.sh` recognises an
Android tether section and answers `json`, `getmode`, `getsupportedmodes`,
`setmode` and `setall` itself (`android_radio_json`, `android_set_mode` and
`android_set_bands` in `android.sh`; the line protocol is parsed by
`android-radio.awk`). Unavailable controls stay hidden; selecting an
unsupported band is refused before the phone is touched.

### 2G / 3G / 4G / Auto

`TelephonyManager.setAllowedNetworkTypesForReason(USER, mask)` is what Android's
own settings and `cmd phone set-allowed-network-types-for-users` call. The
effective mode is the intersection of the reasons (USER, POWER, CARRIER,
ENABLE_2G); only USER is changed. `NetworkTypeBitMask` values used:

| Mode | id | Mask | Bits |
|---|---|---|---|
| Auto | 1 | 906119 (381831 without NR) | 2G + 3G + 4G (+ NR) |
| 2G | 8 | 32771 | GPRS, EDGE, GSM |
| 3G | 2 | 82820 | UMTS, HSDPA, HSUPA, HSPA, HSPA+, TD-SCDMA |
| 4G | 4 | 266240 | LTE, LTE-CA |
| 4G/5G | 20 | 790528 | LTE, LTE-CA, NR (only if the modem lists NR bands) |

Android may rewrite a requested mask for the SIM: on the tested phone Auto
(906119) read back as 381831 (no NR) on the T2 SIM at first and as 643975 (NR
kept, LTE-CA bit dropped) later, so the current mode is derived from the mask
that is read back (2G, 3G and 4G all set = Auto) and the background recovery
never compares against the requested mask. Pressing Auto can therefore leave a
SIM with a mask that differs from the one it had before.
Operator facts measured on this phone: T2 has **no 3G and no VoLTE**, so 4G
only removes calls and SMS on that SIM (its voice falls back to 2G). The
interface asks for confirmation before it sets 4G or 4G/5G on a SIM whose
`volte` flag is not `1`. Beeline has VoLTE.

### Bands

`TelephonyManager.getSystemSelectionChannels()` and
`setSystemSelectionChannels()` (system API, `MODIFY_PHONE_STATE`) read and write
the modem's band lists per radio access network (GSM, UMTS, LTE, NR). Measured
on the Xiaomi 17 (Qualcomm MPSS, `MPSS.DE.9.0-66f6d432b6`):

- Reading works, for both SIMs. After writing an **empty** list the readback is
  the modem's own supported list: GSM 850/900/1800/1900, UMTS B1/2/4/5/8/19/26,
  LTE B1/2/3/4/5/7/8/12/13/17/18/19/20/25/26/28/32/38/39/40/41/42/48/66/71 and
  NR n1/2/3/5/7/8/12/20/25/26/28/38/40/41/48/66/71/75/77/78. Before any write the
  call returns a larger framework default (it includes LTE B106, B250, B252 and
  GSM/UMTS bands the modem does not have), so that list is not used as the
  supported list.
- The first time the frequency block is opened the helper performs that empty
  write once ("no restriction", the unrestricted default) and stores the result
  in `5gmodem.<section>.android_caps`; later reads do not write. *Supported* is
  the stored list, *enabled* is what is read back.
- Writing works and is enforced: locking LTE to B1 moved the serving cell from
  B3 (EARFCN 1892, 10 MHz) to B1 (EARFCN 75, 15 MHz) within five seconds and
  kept it there; restoring brought the full list back.
- The call replaces the whole selection, and a network that is left out or has
  an empty list is **emptied**, not left unrestricted. A write therefore always
  carries all four networks. Selecting every band the modem offers is sent as an
  empty list (a reset) instead of a long explicit list.
- **Limitation:** the modem refuses to write GSM band 12 (1800) and UMTS band
  26 explicitly; they exist only in the unrestricted state. Restricting any band
  therefore also switches those two off (the interface shows their buttons
  deselected afterwards) until the bands are reset. T2's only 2G channel here is
  GSM 1800, so a band restriction removes its 2G fallback.
- NR bands are written as the "5G NSA" list; there is no separate SA list.
- Band restrictions are held by the phone and are not re-applied by the router
  after a phone reboot (no `save_band` persistence).

### The modem can end up on EDGE

Changing the allowed types or the bands makes the modem select a network again.
With 2G allowed (Auto) the Xiaomi repeatedly camped on GSM/EDGE (GSM 1800, ARFCN
823 for T2) and stayed there although LTE was available; its data bearer shows
`connected` but carries nothing and Android never validates it. A bearer that
was created on EDGE or after a mode change on LTE could also stay down. A short
radio off/on (`cmd connectivity airplane-mode enable`, then `disable`) makes the
modem select LTE again; a bearer restart (`cmd phone data disable`, `enable`)
brings the connection back. `android_mode_recover` does this in the background
after a mode or band change: it reads the state back (RAT, data state, whether
mobile data is enabled) after 12 s and

- reselects once if the modem is on 2G while LTE/NR is allowed (then waits up
  to three checks for LTE before concluding there is none);
- restarts the data bearer after a reselection, or when a registered 3G/4G/5G
  connection stays disconnected (at most twice, with a 40 s pause, because the
  connection needs well over 15 s to come up);
- never acts on deliberate 2G-only, on a search in progress, or when the user
  has switched mobile data off;
- runs once per phone: another change meanwhile only asks it to start over.

The check changes only the radio state; it does not touch APN, roaming or
SIM selection. The radio off/on briefly drops both SIMs.

## SMS: the normal inbox, read-only

The authorized shell can read the stock SMS provider on this phone. The
normal `smsbridge.sh` routes recognized Android snapshots to `android_sms`
for inbox, sent messages and counts. The phone's stored messages from all
subscriptions are returned, including historical messages; MMS and RCS are
not included. The router test read 791 inbox records. No manual AT-port
selection is needed on the SMS page.

The content query hex-encodes sender and body in SQL before returning them.
`android-sms.awk` validates and decodes that representation into the normal
`msg` JSON schema; commas, newlines, quotes and Unicode cannot masquerade
as additional CLI fields. Permission errors, malformed rows and missing
completion markers return errors rather than a successful empty inbox.
No SMS content is printed to application logs.

`read_only=true` disables deletion and native mark-read actions in LuCI;
sending, deletion and automatic archive/forwarding paths are rejected or
skipped by this backend. The phone's storage has no modem-style fixed slot
capacity, so the memory-capacity bar is hidden rather than inventing a
maximum. Existing non-Android SMS backends are unchanged.

Android `read` and `seen` flags are preserved separately. The UI's **New**
count includes only messages that are neither read nor seen on the phone,
not messages that LuCI sees for the first time. In the live test, Android
reported 791 inbox messages, two with `read=0, seen=1`, and zero unseen
messages. The original local-seen calculation incorrectly showed 57 new;
it is now bypassed for Android records, including merged/cached cards.
Multipart groups are new only if a member is both unread and unseen.
Browser SMS caches are scoped to the active modem path to prevent a former
modem's cached cards from appearing on the phone page.

## Router investigation

Open the Network page to populate the ordinary metrics cache. The standard
diagnostic report includes that snapshot, including `android_sims`, without
exporting raw phone-service dumps. To inspect the reader directly over SSH:

```sh
adb devices -l
/usr/share/5gmodem/android.sh json <usb-path>
/usr/share/5gmodem/android.sh sms <usb-path> count
/usr/share/5gmodem/bands.sh json <usb-path>     # modes and band lists of the data SIM
/usr/share/5gmodem/bands.sh setmode 4           # 1 Auto, 8 2G, 2 3G, 4 4G, 20 4G/5G
/usr/share/5gmodem/bands.sh setall lte=3        # lock LTE to B3; `lte=default` etc. resets
```

Use the phone's USB path from the app, not its serial or network address.
Keep USB debugging enabled while testing. No changes to the computer's
DNS or routes are part of the reader.

The initial live evidence is recorded in
[the Xiaomi 17 audit](../audits/2026-11-10-xiaomi17-android-metrics.md).
Synthetic regression tests cover dual-SIM selection and switching,
IWLAN/WWAN separation, units, sentinels, escaping under BusyBox and host
awk, incomplete dumps, unauthorized devices, exact serial targeting,
bounded ADB execution, the short helper invocation for legacy ADB, phone
number filtering, secondary LTE carriers, thermal type filtering, SMS
Unicode/escaping, native new-message flags, standard card components and
dispatch isolation from other tethering types. `test_android_radio.py` covers
the mode/band parser on BusyBox and GNU awk (current mode, band lists, locked
state, reset detection, masks, rejection of unsupported bands), the argument
validation and exact commands sent through ADB, the first-read band-list
learning, the `bands.sh` dispatch for Android only, and every branch of the
background recovery; `test_android_bands_view.cjs` covers the interface side
(the frequency block is no longer hidden, battery details, aggregated carrier
summary, VoLTE row and the confirmation before LTE-only on a SIM without VoLTE).
The NR and IMS columns of the cell parser, carrier aggregation widths, timing
advance, firmware, battery, APN and the 5G NSA merge in `5gmodem.sh` are covered
in `test_android_cells.py` and `test_android_metrics.py`.
