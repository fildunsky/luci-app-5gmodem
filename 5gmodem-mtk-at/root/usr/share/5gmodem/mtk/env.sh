MTK_USOCK=/usr/share/5gmodem/mtk/usock-armv7
[ "$(uname -m)" = aarch64 ] && [ -x /usr/share/5gmodem/mtk/usock-aarch64 ] && MTK_USOCK=/usr/share/5gmodem/mtk/usock-aarch64
MTK_SOCK=/dev/socket/rild-atci
MTK_MODE=rild
if [ ! -d /dev/socket ] && [ -c /dev/ttyC0 ]; then
	MTK_SOCK=/dev/ttyC0
	for MTK_MODE in /etc/rc.d/S*cmux; do break; done
	if [ -x /usr/sbin/cmux ] && [ -e "$MTK_MODE" ]; then
		MTK_MODE=mux
		MTK_SOCK=/dev/gsmtty3
		export USOCK_DIRECT=1
	else
		MTK_MODE=tty
	fi
fi
MTK_AT=/dev/gsmtty1
MTK_URCTTY=/dev/gsmtty2
MTK_URC=/tmp/5gmodem/mtk_urc.log
MTK_ECI=/tmp/5gmodem/mtk_ecellinfo
