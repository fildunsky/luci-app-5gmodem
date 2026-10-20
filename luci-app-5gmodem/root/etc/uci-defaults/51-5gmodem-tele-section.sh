#!/bin/sh

uci -q get 5gmodem.tele >/dev/null && exit 0
uci -q set 5gmodem.tele=tele
uci -q commit 5gmodem
exit 0
