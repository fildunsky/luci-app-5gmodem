#
# Copyright 2021-2025 Rafał Wabik - IceG - From eko.one.pl forum
# Copyright 2026 Fil Dunsky t.me/openwrt_fun
#
# Licensed to the GNU General Public License v3.0.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-5gmodem
LUCI_TITLE:=LuCI support for 5G modems (info, SMS, USSD, AT)
MAINTAINER:=Fil Dunsky <filipp.dunsky@gmail.com>
LUCI_DESCRIPTION:=LuCI interface for modems: connection info, diagnostics, SMS, USSD codes and AT commands. \
	Optional eSIM (eUICC) profile management when the lpac package is installed.
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option +qmi-utils +modemmanager \
	+luci-proto-mbim +luci-proto-qmi +luci-proto-modemmanager
LUCI_PKGARCH:=all
PKG_VERSION:=1.3.8
PKG_RELEASE:=1

define Package/luci-app-5gmodem/conffiles
/etc/config/5gmodem
/etc/config/sms_tool_js
/etc/modem/atcmmds.user
/etc/modem/atcmmds/*.user
/etc/modem/phonebook.user
/etc/modem/ussdcodes.user
/etc/modem/ussdcodes/*.user
endef

define Package/luci-app-5gmodem/postinst
chmod +x "$${IPKG_INSTROOT}"/usr/share/5gmodem/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/lib/netifd/proto/fibocom.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/hotplug.d/usb/71-5gmodem-resolve 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/uci-defaults/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-mm-inhibit 2>/dev/null
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/5gmodem-mm-inhibit enable 2>/dev/null
	/etc/init.d/5gmodem-mm-inhibit restart 2>/dev/null
}
if [ -f "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" ]; then
	mkdir -p "$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n"
	cp "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" \
		"$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n/5gmodem.ru.lmo"
fi
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	find /www/luci-static/resources/view/modem \
		/www/luci-static/resources/protocol/fibocom.js \
		/www/luci-static/resources/icons -exec touch {} + 2>/dev/null
}
exit 0
endef

define Package/luci-app-5gmodem/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || rm -f /usr/lib/lua/luci/i18n/5gmodem.ru.lmo
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

define Build/Prepare/luci-app-5gmodem
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n
	-$(STAGING_DIR_HOST)/bin/po2lmo $(CURDIR)/po-ru/5gmodem.po \
		$(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n/5gmodem.ru.lmo
endef

# call BuildPackage - OpenWrt buildroot signature
