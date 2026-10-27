include $(TOPDIR)/rules.mk

PKG_NAME:=5gmodem-mtk-at
PKG_VERSION:=1.2
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only

STRIP:=:
RSTRIP:=:

include $(INCLUDE_DIR)/package.mk

define Package/5gmodem-mtk-at
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=AT access for MediaTek modems on Android pocket routers (luci-app-5gmodem)
  PKGARCH:=all
endef

define Package/5gmodem-mtk-at/description
  Small static ARMv7 and AArch64 client for the AT port of MediaTek modems.
  luci-app-5gmodem pushes it over ADB to MediaTek Android pocket routers
  to read signal, cell and band data and to switch LTE bands.
  On MediaTek SoCs with a built-in modem (MT6735 and similar) the
  5gmodem-mtkat service gives the modem an AT port at /dev/ttyMTK0 and the
  ccmni protocol brings up LTE data on ccmni0.
endef

define Build/Compile
	[ -f ./files/usock-armv7 ] && [ -f ./files/usock-aarch64 ] || { echo "files/usock-armv7 or files/usock-aarch64 is missing: run build-usock.sh first"; exit 1; }
endef

define Package/5gmodem-mtk-at/install
	$(INSTALL_DIR) $(1)/usr/share/5gmodem/mtk
	$(INSTALL_BIN) ./files/usock-armv7 $(1)/usr/share/5gmodem/mtk/usock-armv7
	$(INSTALL_BIN) ./files/usock-aarch64 $(1)/usr/share/5gmodem/mtk/usock-aarch64
	$(INSTALL_DATA) ./root/usr/share/5gmodem/mtk/env.sh $(1)/usr/share/5gmodem/mtk/env.sh
	$(INSTALL_BIN) ./root/usr/share/5gmodem/mtk/modem-init.sh $(1)/usr/share/5gmodem/mtk/modem-init.sh
	$(INSTALL_BIN) ./root/usr/share/5gmodem/mtk/ccmni-watch.sh $(1)/usr/share/5gmodem/mtk/ccmni-watch.sh
	$(INSTALL_BIN) ./root/usr/share/5gmodem/mtk/urc-read.sh $(1)/usr/share/5gmodem/mtk/urc-read.sh
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/5gmodem-mtkat $(1)/etc/init.d/5gmodem-mtkat
	$(INSTALL_DIR) $(1)/www/luci-static/resources/protocol
	$(INSTALL_DATA) ./htdocs/luci-static/resources/protocol/ccmni.js $(1)/www/luci-static/resources/protocol/ccmni.js
	$(INSTALL_DIR) $(1)/lib/netifd/proto
	$(INSTALL_BIN) ./root/lib/netifd/proto/ccmni.sh $(1)/lib/netifd/proto/ccmni.sh
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/50-5gmodem-ccmni-wan $(1)/etc/uci-defaults/50-5gmodem-ccmni-wan
endef

$(eval $(call BuildPackage,5gmodem-mtk-at))
