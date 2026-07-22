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
# coreutils-stty нужен ТЕРМИНАЛЬНОЙ утилите 5gtop: без него нельзя ни выключить
# построчный режим (клавиши срабатывают только после Enter), ни узнать ширину
# окна - раскладка падает в узкую даже на широком экране. Это termios, обойти
# из шелла нечем: busybox stty на части сборок отсутствует вовсе.
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option +qmi-utils +modemmanager \
	+luci-proto-mbim +luci-proto-qmi +luci-proto-modemmanager \
	+kmod-usb-net-rndis +kmod-usb-net-cdc-ether +kmod-usb-net-cdc-mbim +kmod-usb-net-qmi-wwan \
	+coreutils-stty
LUCI_PKGARCH:=all
PKG_VERSION:=1.7.5
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
chmod +x "$${IPKG_INSTROOT}"/etc/init.d/5gmodem-leds 2>/dev/null
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/5gmodem-mm-inhibit enable 2>/dev/null
	/etc/init.d/5gmodem-mm-inhibit restart 2>/dev/null
	modprobe rndis_host 2>/dev/null
	modprobe cdc_ether 2>/dev/null
}
if [ -f "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" ]; then
	mkdir -p "$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n"
	cp "$${IPKG_INSTROOT}/usr/share/5gmodem/i18n/5gmodem.ru.lmo" \
		"$${IPKG_INSTROOT}/usr/lib/lua/luci/i18n/5gmodem.ru.lmo"
fi
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	# Перечитать /etc/config/network (новые интерфейсы). Обработчики ПРОТОКОЛОВ
	# это НЕ регистрирует - для fibocom см. register_proto.sh ниже (после
	# autosetup, который может только что создать модемный интерфейс).
	ubus call network reload 2>/dev/null
	# Зарегистрировать УЖЕ подключённый модем. Обычно это делает hotplug
	# (71-5gmodem-resolve), но если модем был воткнут ДО установки пакета,
	# события не случится и конфиг останется пустым: без active_modem не
	# находится ни порт, ни интерфейс, и страница показывает только прочерки.
	/usr/share/5gmodem/modemswitch.sh resolve 2>/dev/null
	# Порты вкладок SMS/USSD/AT живут в ОТДЕЛЬНОМ конфиге и тоже заполняются
	# hotplug'ом, которого при установке на уже подключённый модем не будет.
	/usr/share/5gmodem/ensureports.sh >/dev/null 2>&1
	# Модем мог быть воткнут ДО установки пакета - тогда hotplug-события не
	# будет. Пробуем настроить его сразу: если интерфейс уже есть, команда
	# сама ничего не сделает.
	/usr/share/5gmodem/modemswitch.sh autosetup >/dev/null 2>&1
	# Зарегистрировать/обновить наш proto-обработчик (fibocom): netifd читает их
	# только при старте и держит в памяти, поэтому свежепоставленный ИЛИ изменённый
	# апгрейдом fibocom.sh не действует до рестарта netifd. Скрипт рестартует netifd
	# ТОЛЬКО когда это реально нужно (прото не зарегистрирован ИЛИ содержимое
	# обработчика изменилось по хешу) - см. register_proto.sh.
	/usr/share/5gmodem/register_proto.sh >/dev/null 2>&1
	# Индикатор на светодиодах корпуса: поднимаем, только если он включён в
	# конфиге И светодиоды на устройстве есть (см. signal-leds.sh detect).
	# Служба сама проверит и наличие светодиодов, и явное выключение; здесь
	# просто даём ей стартовать - на устройствах без светодиодов она молча
	# завершится.
	if [ "$$(uci -q get 5gmodem.@5gmodem[0].signal_leds)" != "0" ]; then
		/etc/init.d/5gmodem-leds enable 2>/dev/null
		/etc/init.d/5gmodem-leds restart 2>/dev/null
	fi
	# ЛИШНЯЯ '}' СТОЯЛА ЗДЕСЬ и закрывала группу раньше времени: shell падал с
	# "syntax error: unexpected }", и ВСЁ, что ниже, не выполнялось - в том
	# числе touch, который сбрасывает кэш браузера. Отсюда же тянулась старая
	# беда «браузер отдаёт JS годовой давности»: лекарство в пакете было, но
	# из-за этой скобки ни разу не срабатывало.
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

# --- ОБЛЕГЧЁННЫЙ ВАРИАНТ -----------------------------------------------------
#
# Тот же набор файлов, но БЕЗ тяжёлых зависимостей: для роутеров с 8 МБ флеша,
# куда полный набор (modemmanager, qmi-utils, kmod'ы, протоколы) физически не
# помещается. Собирается тем же CI и прикладывается к релизу, а не руками -
# ручная сборка через apk mkpkg однажды уже потеряла зависимости.
#
# Файлы, conffiles, postinst и prerm ПЕРЕИСПОЛЬЗУЕМ у основного пакета: копия
# разошлась бы с оригиналом при первой же правке. Это обычное присваивание
# make - макросы уже определены выше и в luci.mk.
#
# CONFLICTS обязателен: пакеты кладут одни и те же файлы, и одновременная
# установка сломала бы учёт файлов в менеджере пакетов.
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
