# call BuildPackage - луковая обвязка ниже
include $(TOPDIR)/rules.mk

PKG_NAME:=5gmodem-atd
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-only

include $(INCLUDE_DIR)/package.mk

define Package/5gmodem-atd
  SECTION:=net
  CATEGORY:=Network
  TITLE:=URC listener for luci-app-5gmodem
  MAINTAINER:=Fil Dunsky <filipp.dunsky@gmail.com>
  # Демон бесполезен без приложения (зовёт его health.sh/listmodems/atprobe).
  # Зависимость в ЭТУ сторону безопасна: приложение (arch=all) остаётся
  # самодостаточным и НЕ зависит от демона - обновление приложения не требует
  # наличия бинаря под все арки. Кто хочет мгновенную реакцию - ставит демон.
  DEPENDS:=+luci-app-5gmodem
endef

define Package/5gmodem-atd/description
 Holds a spare modem AT port open, listens for unsolicited result codes
 (+CGEV, +CEREG, ^SIMST, NO CARRIER...) and kicks the 5gmodem watchdog
 instantly - sub-second reaction to drops instead of waiting for the next
 polling cycle. The spare AT port is picked automatically (atd-autoport.sh)
 on modem hotplug; override with uci 5gmodem.atd.manual=1 + atd.port.
 Skips HiLink and ModemManager modems (their events live in QMI/MM, not AT).
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/atd.c $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -Wall -Wextra \
		-o $(PKG_BUILD_DIR)/5gmodem-atd $(PKG_BUILD_DIR)/atd.c
endef

define Package/5gmodem-atd/install
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/etc/init.d $(1)/usr/share/5gmodem \
		$(1)/etc/hotplug.d/iface $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/5gmodem-atd $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/5gmodem-atd.init $(1)/etc/init.d/5gmodem-atd
	$(INSTALL_BIN) ./files/urc-dispatch.sh $(1)/usr/share/5gmodem/
	$(INSTALL_BIN) ./files/atd-autoport.sh $(1)/usr/share/5gmodem/
	$(INSTALL_BIN) ./files/62-5gmodem-atd $(1)/etc/hotplug.d/iface/62-5gmodem-atd
	$(INSTALL_BIN) ./files/5gmodem-atd.defaults $(1)/etc/uci-defaults/99-5gmodem-atd
endef

$(eval $(call BuildPackage,5gmodem-atd))
