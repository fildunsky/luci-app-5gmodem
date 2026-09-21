# Sketch: QMI+MM protocol (`qmip`)

Status: **shelved**, not shipped. Removed from `master` in 2.8.1; this branch keeps the code as a starting point.

## Idea

A netifd protocol for modems in a QMI composition (`qmi_wwan`), the QMI twin of MBIM+MM (`mbimp`):
the data session is dialed with `qmicli` through the shared `qmi-proxy --no-exit`, and ModemManager
runs alongside only for management (bands, network mode, SMS, USSD), so band changes apply live
without a redial.

Files:
- `luci-app-5gmodem/root/lib/netifd/proto/qmip.sh` - protocol handler
- `luci-app-5gmodem/root/usr/share/5gmodem/qmip-keeper.sh` - session keeper
- `luci-app-5gmodem/htdocs/luci-static/resources/protocol/qmip.js` - LuCI protocol form

## What works (Compal RXM-G1 1e2d:00b7, Hiveton H5000M, Tele2)

- Dial in ~10 s, cold boot on the first attempt (~50 s after power-on), USB re-plug ~30 s.
- The radio is switched on before waiting for registration: after boot ModemManager leaves the
  modem `disabled` (low-power), and without this registration never came (7 attempts, 4 minutes).
- Address over DHCP like the stock `qmi.sh`; the APN is written to profile 1.
- WDS client IDs are tied to the USB device instance, so a stale CID of a previous modem instance is
  never released on top of ModemManager's clients.
- The keeper redials only on an explicit `disconnected`, never on a silent probe.
- "4G only" and band changes through ModemManager apply without a redial.

## Why it is shelved: the data path dies after minutes

After 2 to 50 minutes the traffic stops with no event from the modem, ModemManager or netifd:
- the WDS session still reports `connected`, the modem keeps counting received packets;
- `wwan0` rx_packets freezes and **rx_errors grows by thousands per minute**: frames reach the host
  but `qmi_wwan` rejects them;
- WDA data format stays `raw-ip`, no aggregation, on the default endpoint and on `hsusb` iface 0;
- not fixed by: re-setting the WDA data format, a QMI+MM redial, a radio cycle, MTU back to 1500;
- fixed by a USB re-enumeration of the modem (`echo 2-1 > /sys/bus/usb/drivers/usb/unbind` + `bind`);
- the stock `qmi.sh` (no ModemManager) was stable in the same place; an earlier impression that it
  "fixed" the dead link was wrong - the modem re-enumerated on USB at that moment.
- Large pings (1500 bytes) at MTU 1430 did not reproduce it: the operator does not deliver packets
  above 1430, so the MTU theory is not confirmed. `qmip.sh` no longer lowers the MTU anyway.

Open hypotheses: ModemManager (enabled, `registered`) doing something to the data endpoint while it
does not own the bearer; a firmware issue of this Compal composition under two QMI clients.

## Next step if resumed

Capture the rejected frames when the link dies: set `/sys/class/net/wwan0/qmi/pass_through` to `Y`
(link down first), `tcpdump -XX -i wwan0`, and compare with the ModemManager debug log
(`--log-level=DEBUG`) around the moment rx_errors starts to grow.
