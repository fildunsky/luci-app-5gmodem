#!/bin/sh

# Older installs were seeded with the code "secret", the same on every router.
# Replace it with a random one while SMS commands are off. When they are on,
# the user may rely on it, so keep it: smscmd.sh logs a warning instead.
_sc=$(uci -q get 5gmodem.sms.cmd_secret | tr 'A-Z' 'a-z')
[ "$_sc" = secret ] || exit 0
[ "$(uci -q get 5gmodem.sms.cmd_enabled)" = 1 ] && exit 0
uci -q set 5gmodem.sms.cmd_secret="$(head -c 32 /dev/urandom | md5sum | cut -c1-8)"
uci -q commit 5gmodem

exit 0
