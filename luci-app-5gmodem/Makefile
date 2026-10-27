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
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option \
	+kmod-usb-serial-qualcomm +qmi-utils +modemmanager \
	+luci-proto-mbim +luci-proto-qmi +luci-proto-modemmanager \
	+kmod-usb-net-rndis +kmod-usb-net-cdc-ether +kmod-usb-net-cdc-mbim +kmod-usb-net-qmi-wwan \
	+usb-modeswitch +kmod-usb-acm \
	+curl +adb \
	+coreutils-stty \
	+mbim-utils
LUCI_PKGARCH:=all
PKG_VERSION:=3.9.0
PKG_RELEASE:=1

define Package/luci-app-5gmodem/conffiles
/etc/config/5gmodem
/etc/5gmodem/modem/atcmmds.user
/etc/5gmodem/modem/atcmmds/*.user
/etc/5gmodem/modem/phonebook.user
/etc/5gmodem/modem/ussdcodes.user
/etc/5gmodem/modem/ussdcodes/*.user
endef

define Package/luci-app-5gmodem/postinst
chmod +x "$${IPKG_INSTROOT}"/usr/share/5gmodem/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/lib/netifd/proto/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/hotplug.d/usb/71-5gmodem-resolve 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/hotplug.d/tty/05-5gmodem-noat 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/uci-defaults/*.sh 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-mm-inhibit 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-leds 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-antenna 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-btnleds 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-usbports 2>/dev/null
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-sessionwatch 2>/dev/null
[ -n "$${IPKG_INSTROOT}" ] || {
	for _5gm_f in /etc/hotplug.d/*/*5gmodem*.apk-new /etc/hotplug.d/*/*5gmodem*-opkg; do
		[ -f "$$_5gm_f" ] || continue
		case "$$_5gm_f" in
			*.apk-new) mv -f "$$_5gm_f" "$${_5gm_f%.apk-new}" 2>/dev/null ;;
			*-opkg) mv -f "$$_5gm_f" "$${_5gm_f%-opkg}" 2>/dev/null ;;
		esac
	done
	_5gm_upgrade=0
	[ -n "$$(uci -q get 5gmodem.@5gmodem[0].widgets_seeded 2>/dev/null)" ] && _5gm_upgrade=1
	_5gm_svc() {
		[ -x "/etc/init.d/$$1" ] || return 0
		if [ ! -e "/etc/5gmodem/.svc/$$1" ]; then
			mkdir -p /etc/5gmodem/.svc 2>/dev/null
			: > "/etc/5gmodem/.svc/$$1" 2>/dev/null
			[ "$$_5gm_upgrade" = 1 ] || /etc/init.d/$$1 enable 2>/dev/null
		fi
		if /etc/init.d/$$1 enabled 2>/dev/null; then
			/etc/init.d/$$1 $$2 2>/dev/null
		else
			/etc/init.d/$$1 stop 2>/dev/null
		fi
		return 0
	}
	_5gm_svc 5gmodem-mm-inhibit restart
	_5gm_svc 5gmodem-usbports start
	_5gm_svc 5gmodem-sessionwatch restart
	_5gm_svc 5gmodem-btnleds start
	modprobe rndis_host 2>/dev/null
	modprobe cdc_ether 2>/dev/null
	/usr/share/5gmodem/usbmode-fix.sh 2>/dev/null
	sh /etc/uci-defaults/5gmodem-rebind-allow.sh 2>/dev/null
	sh /etc/uci-defaults/5gmodem-ttl-migrate.sh 2>/dev/null
}
[ -n "$${IPKG_INSTROOT}" ] || {
	_ja_pkg=0
	apk info -e luci-i18n-5gmodem-ja >/dev/null 2>&1 && _ja_pkg=1
	opkg status luci-i18n-5gmodem-ja 2>/dev/null | grep -q "install ok installed" && _ja_pkg=1
	[ "$$_ja_pkg" = 1 ] || rm -f /usr/lib/lua/luci/i18n/5gmodem.ja.lmo
}
for _lmo in "$${IPKG_INSTROOT}"/usr/share/5gmodem/i18n/5gmodem.*.lmo; do
	[ -f "$$_lmo" ] || continue
	mkdir -p "$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n"
	cp "$$_lmo" "$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n/"
done
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	ubus call network reload 2>/dev/null
	/usr/share/5gmodem/modemswitch.sh resolve 2>/dev/null
	/usr/share/5gmodem/ensureports.sh >/dev/null 2>&1
	/usr/share/5gmodem/modemswitch.sh autosetup >/dev/null 2>&1
	/usr/share/5gmodem/register_proto.sh >/dev/null 2>&1
	if [ "$$(uci -q get 5gmodem.@5gmodem[0].signal_leds)" != "0" ]; then
		/etc/init.d/5gmodem-leds enable 2>/dev/null
		/etc/init.d/5gmodem-leds restart 2>/dev/null
	fi
	if /usr/share/5gmodem/antenna.sh detect 2>/dev/null | grep -q '"available":1'; then
		/etc/init.d/5gmodem-antenna enable 2>/dev/null
		/etc/init.d/5gmodem-antenna restart 2>/dev/null
	fi
	_5gm_ts=$$(( 2114380800 + $$(date +%s) % 31536000 ))
	find /www/luci-static/resources/view/modem5g \
		/www/luci-static/resources/view/status \
		/www/luci-static/resources/sms-tool-5gm \
		/www/luci-static/resources/5gmodem \
		/www/luci-static/resources/protocol/fibocom.js \
		/www/luci-static/resources/protocol/qmiraw.js \
		/www/luci-static/resources/protocol/mbimp.js \
		/www/luci-static/resources/icons -exec touch -d "@$$_5gm_ts" {} + 2>/dev/null
}
exit 0
endef

define Package/luci-app-5gmodem/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || rm -f /usr/lib/lua/luci/i18n/5gmodem.ru.lmo
exit 0
endef

LUCI_LANG.id:=Bahasa Indonesia (Indonesian)

include $(TOPDIR)/feeds/luci/luci.mk

define Build/Prepare/luci-app-5gmodem
	$(INSTALL_DIR) $(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n
	-$(STAGING_DIR_HOST)/bin/po2lmo $(CURDIR)/po-ru/5gmodem.po \
		$(PKG_BUILD_DIR)/root/usr/share/5gmodem/i18n/5gmodem.ru.lmo
endef

define Package/luci-app-5gmodem-lite
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE) (lite)
  URL:=$(LUCI_URL)
  MAINTAINER:=$(MAINTAINER)
  DEPENDS:=+sms-tool +coreutils-stty
  PKGARCH:=all
  CONFLICTS:=luci-app-5gmodem
endef

define Package/luci-app-5gmodem-lite/description
  $(LUCI_DESCRIPTION)

  Lite build for low-flash devices: requires only sms-tool. Metrics, SMS, USSD,
  band control and the AT console work; the QMI/MBIM interface protocols and the
  phone number read through mmcli are not available. Do not install it over a
  router that runs a QMI or MBIM modem - the package manager would drop those
  packages as orphans.
endef

Package/luci-app-5gmodem-lite/conffiles = $(Package/luci-app-5gmodem/conffiles)
Package/luci-app-5gmodem-lite/install = $(Package/luci-app-5gmodem/install)
Package/luci-app-5gmodem-lite/postinst = $(Package/luci-app-5gmodem/postinst)
Package/luci-app-5gmodem-lite/prerm = $(Package/luci-app-5gmodem/prerm)

$(eval $(call BuildPackage,luci-app-5gmodem-lite))

# call BuildPackage - OpenWrt buildroot signature
