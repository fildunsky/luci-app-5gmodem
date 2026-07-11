#!/bin/sh
# Copyright 2020-2024 Rafał Wabik (IceG) - From eko.one.pl forum
# MIT License

chmod +x /usr/share/5gmodem/5gmodem.sh 2>&1 &
chmod +x /usr/share/5gmodem/detect.sh 2>&1 &
chmod +x /usr/share/5gmodem/bands.sh 2>&1 &
chmod +x /usr/share/5gmodem/ttl.sh /usr/share/5gmodem/mkiface.sh /usr/share/5gmodem/update.sh /usr/share/5gmodem/reboot_modem.sh 2>&1 &
chmod +x /usr/share/5gmodem/check.gcom 2>&1 &
chmod +x /usr/share/5gmodem/info.gcom 2>&1 &
chmod +x /usr/share/5gmodem/vendorproduct.gcom 2>&1 &
chmod +x /usr/share/5gmodem/modem/hilink/alcatel_hilink.sh 2>&1 &
chmod +x /usr/share/5gmodem/modem/hilink/huawei_hilink.sh 2>&1 &
chmod +x /usr/share/5gmodem/modem/hilink/zte.sh 2>&1 &
rm -rf /tmp/luci-indexcache 2>&1 &
rm -rf /tmp/luci-modulecache/ 2>&1 &

exit 0

