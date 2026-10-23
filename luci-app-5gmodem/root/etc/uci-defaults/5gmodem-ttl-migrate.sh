#!/bin/sh
[ -f /etc/nftables.d/10-5gmodem-ttl.nft ] || exit 0
rm -f /etc/nftables.d/10-5gmodem-ttl.nft
fw4 reload >/dev/null 2>&1
exit 0
