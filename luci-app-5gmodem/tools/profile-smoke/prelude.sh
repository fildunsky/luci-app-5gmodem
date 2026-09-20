_smoke_ext() { [ -n "$SMOKE_LOG" ] && printf 'EXT %s\n' "$*" >> "$SMOKE_LOG"; return 0; }
for _sn in logger sleep usleep flock killall killall5 pkill fuser dmesg wget nc ifup ifdown ifconfig ip route \
	reboot halt poweroff mount umount insmod rmmod modprobe sync hwclock ntpd udhcpc ping ping6 \
	traceroute nslookup telnet tftp ftpget ftpput start-stop-daemon; do
	eval "$_sn() { _smoke_ext $_sn \"\$@\"; }"
done
pgrep() { _smoke_ext pgrep "$@"; return 1; }
pidof() { _smoke_ext pidof "$@"; return 1; }
unset _sn
