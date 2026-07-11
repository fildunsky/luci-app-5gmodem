# 5G Modem app for OpenWrt
### `luci-app-5gmodem`
LuCI app for 5G modems: merges `3ginfo-lite`, `sms-tool-js` and some stuff from `modemband` into one app. Network status page (signal, operator, IP, technology, band management, TTL/hop-limit fixing), modem settings with port auto-detect, and SMS Inbox, Send, USSD, AT tabs with per-tab collapsible settings.

Probably should support all the modems from mentioned forks + `Compal RXM-G1` (custom firmware, VID:PID `05c6:90d6`, reports via mmcli as `Tri Cascade Inc. SG500M2-X`

<img width="1972" height="1488" alt="Screenshot From 2026-07-11 16-03-24" src="https://github.com/user-attachments/assets/d53b7a96-3a25-4198-b29d-5c1d9464e7c3" />
