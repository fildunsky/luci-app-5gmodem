#!/bin/sh
# luci-app-5gmodem: generate ModemManager's ignore rules on install, so modems
# driven via a kernel proto (qmi/mbim/xmm/ncm/atc/fibocom/...) are hidden from
# ModemManager from the very first boot - MM would otherwise crash-loop on such
# a modem and its port probing corrupts AT reads (metrics), band writes and USSD.
# The rules are regenerated on every boot/hotplug and on interface (re)creation
# by modemswitch.sh / mkiface.sh, so they stay in sync with the user's protos.

chmod +x /usr/share/5gmodem/mm-filter.sh 2>/dev/null
[ -x /usr/share/5gmodem/mm-filter.sh ] && /usr/share/5gmodem/mm-filter.sh >/dev/null 2>&1

exit 0
