include $(TOPDIR)/rules.mk

PKG_NAME:=5gmodem-mtk-at
PKG_VERSION:=1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only

STRIP:=:
RSTRIP:=:

include $(INCLUDE_DIR)/package.mk

define Package/5gmodem-mtk-at
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=AT access for MediaTek Android pocket routers (luci-app-5gmodem)
  PKGARCH:=all
endef

define Package/5gmodem-mtk-at/description
  Small static ARMv7 client for the rild-atci socket. luci-app-5gmodem pushes it
  over ADB to MediaTek Android pocket routers (MF932 and relatives) to read signal,
  cell and band data and to switch LTE bands. It runs on the pocket router, not on
  this router, so one build fits every router architecture.
endef

define Build/Compile
	[ -f ./files/usock-armv7 ] || { echo "files/usock-armv7 is missing: build src/usock.c with an ARMv7 compiler first"; exit 1; }
endef

define Package/5gmodem-mtk-at/install
	$(INSTALL_DIR) $(1)/usr/share/5gmodem/mtk
	$(INSTALL_BIN) ./files/usock-armv7 $(1)/usr/share/5gmodem/mtk/usock-armv7
endef

$(eval $(call BuildPackage,5gmodem-mtk-at))
