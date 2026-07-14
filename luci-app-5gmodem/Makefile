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
LUCI_DESCRIPTION:=LuCI interface for modems: connection info, diagnostics, SMS, USSD codes and AT commands.
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option +qmi-utils +modemmanager \
	+luci-proto-mbim +luci-proto-qmi +luci-proto-modemmanager
LUCI_PKGARCH:=all
PKG_VERSION:=1.2.1
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

# Deploy the bundled Russian translation. The .lmo ships at a path THIS package
# owns (/usr/share/5gmodem/i18n/), and postinst copies it into LuCI's i18n dir.
# Doing it via postinst (a plain cp) instead of shipping it straight to
# /usr/lib/lua/luci/i18n/ avoids an apk file-ownership CONFLICT with an old
# standalone luci-i18n-5gmodem-ru that older installs still have (apk on the
# device is run without --force-overwrite by the in-app updater). Defined before
# the luci.mk include so its default postinst (which we replicate) is skipped.
define Package/luci-app-5gmodem/postinst
#!/bin/sh
# Belt-and-suspenders: guarantee the app's executable files carry +x. A source
# file committed without it makes 5gmodem.sh's helpers fail "Permission denied"
# (blank info page), the netifd proto not load ("unsupported protocol type",
# modem gets no IP), or the resolve hotplug not run (modem<->iface link lost).
chmod +x "$${IPKG_INSTROOT}"/usr/share/5gmodem/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/lib/netifd/proto/fibocom.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/hotplug.d/usb/71-5gmodem-resolve 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/uci-defaults/*.sh 2>/dev/null
if [ -f "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" ]; then
	mkdir -p "$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n"
	cp "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" \
		"$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n/5gmodem.ru.lmo"
fi
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

define Package/luci-app-5gmodem/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || rm -f /usr/lib/lua/luci/i18n/5gmodem.ru.lmo
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# --- Russian is bundled INTO the main package -------------------------------
# All other languages are still emitted as separate luci-i18n-5gmodem-<lang>
# packages by luci.mk (one per po/<lang>/), so foreign users keep installing
# their translation as usual. Russian lives in po-ru/ (deliberately OUTSIDE the
# po/* glob, so luci.mk does NOT build a standalone luci-i18n-5gmodem-ru); we
# compile it here, at build time, to a path this package owns. postinst (above)
# then copies it into LuCI's i18n dir on the device.
define Build/Prepare/luci-app-5gmodem
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n
	po2lmo $(CURDIR)/po-ru/5gmodem.po \
		$(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n/5gmodem.ru.lmo
endef

# call BuildPackage - OpenWrt buildroot signature
