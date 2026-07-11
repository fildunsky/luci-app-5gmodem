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
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option +qmi-utils +modemmanager
LUCI_PKGARCH:=all
PKG_VERSION:=1.0.9
PKG_RELEASE:=2

define Package/luci-app-5gmodem/conffiles
/etc/config/5gmodem
/etc/config/sms_tool_js
/etc/modem/atcmmds.user
/etc/modem/atcmmds/*.user
/etc/modem/phonebook.user
/etc/modem/ussdcodes.user
/etc/modem/ussdcodes/*.user
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
