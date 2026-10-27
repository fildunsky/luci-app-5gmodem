# luci-app-5gmodem developer docs

Why the code looks the way it does: hardware quirks, OpenWrt and LuCI pitfalls, and the reasoning behind non-obvious choices. The code itself carries no explanatory comments; a rare one-line pointer such as `# see docs/modems/fibocom.md#teardown-keeps-the-bearer` marks a spot that would look wrong without it.

## Subsystems

- [Modem identity, autosetup and the active modem](subsystems/autosetup.md)
- [CI and releases](subsystems/ci.md)
- [Band, network-mode and cell-lock management](subsystems/bands.md)
- [Band profiles (`modemband/`)](subsystems/bands-profiles.md)
- [Device detection, port binding and modem identity](subsystems/device-detection.md)
- [Diagnostics: developer report, Modem page, AT console, 5gtop, telemetry, statistics](subsystems/diagnostics.md)
- [eSIM (eUICC) management](subsystems/esim.md)
- [Health checks and recovery](subsystems/health-and-recovery.md)
- [Modem network interfaces](subsystems/interfaces.md)
- [Internet priority, failover and the widget row](subsystems/internet-priority.md)
- [uci-defaults migrations](subsystems/migrations.md)
- [Miscellaneous subsystems](subsystems/misc.md)
- [ModemManager: inhibit, takeover and boot recovery](subsystems/modemmanager.md)
- [SMS notifications, SMS commands, LED](subsystems/notifications.md)
- [AT port access: lock, detection, registry](subsystems/polling-at-access.md)
- [Metrics poll (`5gmodem.sh`)](subsystems/polling.md)
- [Verified modem quirks (`quirks.sh`)](subsystems/polling-quirks.md)
- [SIM slot reading and switching](subsystems/sim-slots.md)
- [SMS: reading, sending, storage, archive](subsystems/sms.md)
- [Speed test and external IP](subsystems/speedtest-extip.md)
- [UI: modem.css and theme compatibility](subsystems/ui-css.md)
- [UI: LuCI views and shared JS helpers](subsystems/ui.md)
- [USSD](subsystems/ussd.md)

## Modems

- [Altair ALT3100 / ALT3800 (USB vendor 216f)](modems/altair.md)
- [Fibocom modems and the `fibocom` netifd protocol](modems/fibocom.md)
- [Foxconn / Dell / HP modules: T77W968 (DW5821e), T99W373 (MV32-W), T77W595 (HP lt4120)](modems/foxconn-dell.md)
- [Huawei: HiLink web API and AT-mode sticks](modems/huawei-hilink.md)
- [MediaTek MT6735 Android Mi-Fi (ZTE-style goform)](modems/mediatek-mifi.md)
- [Other non-Qualcomm modems (MikroTik/Marvell, ASR, ASKEY, BroadMobi, Sierra 320U)](modems/others-b.md)
- [Other vendors: MeigLink, YUGA, generic Qualcomm MSM, plus Huawei/Fibocom files from this batch](modems/others.md)
- [Qualcomm SDX55 family: Foxconn T99W175, Dell DW5930e, Thales MV31-W, Compal RXM-G1](modems/qualcomm-sdx55.md)
- [Quectel](modems/quectel.md)
- [Sierra Wireless (and Dell/Lenovo rebrands)](modems/sierra.md)
- [SIMCom](modems/simcom.md)
- [Telit (and HP lt4220)](modems/telit.md)
- [Web-API sticks: `hilink.sh` architecture](modems/web-api-sticks.md)
- [ZTE and Tenda: goform web API and AT profiles](modems/zte-tenda.md)
- [ASR / Marvell Mi-Fi: Duster web API](modems/asr-duster.md)

## Other

- [Telemetry](telemetry.md)
