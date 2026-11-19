# OLAX MT60 radio companion

This companion is for the native OpenWrt guest running on the stock Android firmware of the OLAX MT60 k62 (`t60_extchg_k62`). It supplies LTE serving-carrier and signal readings and handles 2G/3G band requests from 5gmodem. On the tested k62 firmware, carrier aggregation is reported as a status and the individual secondary carriers are unavailable.

Use an existing native MT60 installation with the `mt60.radio` ubus provider. In the guest, `ubus list mt60` should list that provider. The guest uses the companion's additional readings while its snapshot is fresh and falls back to the stock and panel readings otherwise. An external OpenWrt router using the MT60 via USB tethering manages it through the stock web API.

Use an authorized ADB connection to your MT60 with stock root ADB and `su` available. Run these commands from this directory after starting the OpenWrt guest:

```sh
adb devices
serial=YOUR_MT60_ADB_SERIAL
adb -s "$serial" root
adb -s "$serial" wait-for-device
adb -s "$serial" shell 'test "$(id -u)" = 0 && test "$(getprop ro.product.device)" = t60_extchg_k62 && mkdir -p /data/local/mt60-openwrt' &&
    adb -s "$serial" push mt60-radio.sh /data/local/mt60-openwrt/mt60-radio.sh &&
    adb -s "$serial" push mt60-radio.dex /data/local/tmp/5gm-mt60-radio.dex &&
    adb -s "$serial" shell 'chmod 700 /data/local/mt60-openwrt/mt60-radio.sh && chmod 644 /data/local/tmp/5gm-mt60-radio.dex && /data/local/mt60-openwrt/mt60-radio.sh start'
```

The collector writes to `/tmp/mt60-radio` inside the existing OpenWrt guest. It supports the rootfs under `/data/local/mt60-openwrt/rootfs` and the panel app rootfs under `/data/user/0/local.mt60.panel/files/rootfs`. Its snapshot can include SIM identifiers. Keep root ADB and guest administration limited to trusted users.

Run the start command after each reboot once the guest is running. To stop the collector from an authorized root ADB session, run:

```sh
adb -s "$serial" shell /data/local/mt60-openwrt/mt60-radio.sh stop
```
