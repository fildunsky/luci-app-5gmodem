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
# mbim-utils (mbimcli) нужен eSIM на MBIM-модемах: только он читает и
# восстанавливает slot mapping (см. _mbim_slot_* в esim.sh) - без этого у
# пользователя с рабочей SIM1 и eUICC в SIM2 открытие вкладки eSIM уводит модем
# на eSIM и рвёт связь, а состояние слота («active-esim» / «no-profiles») по QMI
# не различить. Вес символический: libmbim и так тянет ModemManager из строки
# выше, добавляется только сам бинарник (~180 КБ).
# coreutils-stty нужен ТЕРМИНАЛЬНОЙ утилите 5gtop: без него нельзя ни выключить
# построчный режим (клавиши срабатывают только после Enter), ни узнать ширину
# окна - раскладка падает в узкую даже на широком экране. Это termios, обойти
# из шелла нечем: busybox stty на части сборок отсутствует вовсе.
LUCI_DEPENDS:=+sms-tool +comgt +kmod-usb-serial +kmod-usb-serial-option \
	+kmod-usb-serial-qualcomm +qmi-utils +modemmanager \
	+luci-proto-mbim +luci-proto-qmi +luci-proto-modemmanager \
	+kmod-usb-net-rndis +kmod-usb-net-cdc-ether +kmod-usb-net-cdc-mbim +kmod-usb-net-qmi-wwan \
	+usb-modeswitch +kmod-usb-acm \
	+curl \
	+coreutils-stty \
	+mbim-utils
LUCI_PKGARCH:=all
PKG_VERSION:=2.8.8
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
	# Ре-бинд usb-serial портов на каждом буте (new_id не переживает ребут,
	# coldplug-hotplug в procd не приходит). start сразу накатит порты и на уже
	# воткнутый при установке модем. См. 05c6:9025/90d5/90d6.
	_5gm_svc 5gmodem-usbports start
	# Сторож сессии данных: сеть может пересоздать её с новым адресом (смена
	# макрорегиона в поездке), а netifd за этим не следит - см. sessionwatch.sh.
	_5gm_svc 5gmodem-sessionwatch restart
	# Диоды кнопок: приводим их к фактическому состоянию сервиса ОДИН РАЗ при
	# загрузке (после ребута они оставались тёмными до первого нажатия).
	_5gm_svc 5gmodem-btnleds start
	modprobe rndis_host 2>/dev/null
	modprobe cdc_ether 2>/dev/null
	# Снять вредные правила usb_modeswitch (см. usbmode-fix.sh): у части
	# модемов база предписывает конфигурацию 0, что сносит канал данных.
	# Делаем и здесь, а не только в hotplug: при обновлении пакета
	# usb-modeswitch запись возвращается, а модем уже воткнут - события не будет.
	/usr/share/5gmodem/usbmode-fix.sh 2>/dev/null
	# Пробы связности Windows/Android/Apple - вне rebind-защиты (см. скрипт):
	# на сотовых аплинках их режет dnsmasq, и клиенты врут «нет интернета».
	# Запускаем и здесь: uci-defaults отработает только на следующем буте.
	sh /etc/uci-defaults/5gmodem-rebind-allow.sh 2>/dev/null
	# Убрать инклюд старого TTL-механизма СРАЗУ при обновлении (см. ttl.sh):
	# он ломает сборку fw4 на холодном старте, ждать следующего бута нельзя -
	# следующий бут с ним и сломается. Правила пересоздаст hotplug/страница.
	sh /etc/uci-defaults/5gmodem-ttl-migrate.sh 2>/dev/null
}
# Японский до 2.5.13 ехал внутри пакета, и postinst копировал его в каталог
# LuCI. Теперь он только в luci-i18n-5gmodem-ja: ничейную копию прошлых версий
# убираем, иначе она навсегда застряла бы на старом переводе. Файл пакета
# перевода, если тот стоит, не трогаем.
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
	if /usr/share/5gmodem/antenna.sh detect 2>/dev/null | grep -q '"available":1'; then
		/etc/init.d/5gmodem-antenna enable 2>/dev/null
		/etc/init.d/5gmodem-antenna restart 2>/dev/null
	fi
	# ЛИШНЯЯ '}' СТОЯЛА ЗДЕСЬ и закрывала группу раньше времени: shell падал с
	# "syntax error: unexpected }", и ВСЁ, что ниже, не выполнялось - в том
	# числе touch, который сбрасывает кэш браузера. Отсюда же тянулась старая
	# беда «браузер отдаёт JS годовой давности»: лекарство в пакете было, но
	# из-за этой скобки ни разу не срабатывало.
	# ВСЕ каталоги ресурсов пакета, а не выборочно. Здесь стоял только
	# 'view/modem' (какого вообще не существует - страницы живут в
	# view/modem5g), и главные JS после апгрейда оставались с mtime 1970:
	# браузер с такой датой не перепроверяет файл годами (эвристика кэша) либо
	# получает 304 на любой If-Modified-Since. Живой случай 31.07.2026: на
	# свежепоставленной 2.1.0 карточка SSClash горела красным - в браузере
	# крутился netpri.js недельной давности при здоровом бэкенде.
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
