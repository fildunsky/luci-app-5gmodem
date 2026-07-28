# luci-app-5gmodem

*[English version](README.md)*

Приложение LuCI для 4G/5G-модемов в OpenWrt. Объединяет [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) и часть `modemband` в одно приложение.

## Возможности

- **Кнопка «Создать интерфейс модема»** (Настройки модема) — интерфейс `network` для модема настраивается автоматически.
- **Режим двух модемов и переключение аплинка**
- **Две SIM и переключение eSIM** — проверено на Fibocom FM350-GL (AT) и Foxconn T99W175 / Thales MV31-W (MBIM). Поставьте наш патченый `lpac` для своей платформы из [релизов lpac-build](https://github.com/fildunsky/lpac-build/releases/latest) (см. раздел [eSIM / lpac](#esim--lpac) ниже).
- **Сеть** — подробный уровень сигнала, оператор, технология с агрегацией несущих (например `LTE-A | B1 + B40 / B7 / B3`), IPv4/IPv6 интерфейса, статистика соединения и температура модема (если модем её отдаёт).
- **Управление диапазонами и режимом** — выбор режима сети (Авто / 2G / 3G / 4G / 4G+5G / 5G) и включение отдельных диапазонов LTE/NR.
- **Фиксация TTL** — принудительный TTL для входящего и исходящего IPv4 и hop-limit для IPv6 на интерфейсе модема (через включаемый файл `nftables` в `fw4`).
- **Карта сот** — Cell ID сделан кнопкой: открывает вышку на [4cells.ru](https://4cells.ru).
- **Перезапуск модема** — в одно нажатие: мягкий перезапуск радио `AT+CFUN=4,1` и сброс модема `AT+CFUN=1,1`.
- Вкладки **SMS (входящие и отправка)**, **USSD** и **AT**, у каждой — сворачиваемая панель своих настроек. По желанию — пересылка входящих SMS на e-mail и индикация светодиодами.
- **Автоопределение портов** — AT-порт и сетевой интерфейс определяются сами; можно задать вручную.
- **USB-свистки без AT-портов** (Huawei HiLink и родственники) тоже поддерживаются — см. ниже.
- **`5gtop`** — те же данные в терминале, когда вы в SSH, а не в браузере.

<img width="1954" height="1460" alt="Screenshot From 2026-07-19 23-06-52" src="https://github.com/user-attachments/assets/22828d57-805d-4cae-9ec0-7a24cfa884e2" />
<img width="1958" height="1426" alt="Screenshot From 2026-07-19 23-07-23" src="https://github.com/user-attachments/assets/df8e2a52-63d0-45c5-9313-67ffe1ecb872" />

## Модемы, которые есть у меня лично

Для них добавлены новые возможности (по сравнению с 3ginfo и modemband):

- Fibocom FM350GL
- Fibocom L850
- Compal RXM-G1
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- MeigLink SLM770A-R
- Huawei E3372 (HiLink)
- Многие другие не проверялись, но должны работать — поддерживаются все модемы из исходных проектов.

<img width="1956" height="1458" alt="Screenshot From 2026-07-19 23-07-44" src="https://github.com/user-attachments/assets/5eed741c-787a-4bf0-947d-4ebc934c7590" />

### USB-свистки без AT-портов (HiLink)

Свистки вроде Huawei E3372 держат IP-стек в себе: роутер видит только сетевую
карту, а всё остальное живёт за собственным веб-интерфейсом свистка. AT-портов
у них нет вовсе, поэтому обычному опросу просто не с чем разговаривать.

Приложение работает с ними так:

- модем опознаётся по USB-дескриптору (свисток, у которого драйвер просто ещё
  не привязался, за HiLink *не* принимается) и получает DHCP-интерфейс;
- метрики, SMS и имя оператора читаются через HTTP-API свистка;
- если свисток умеет показывать последовательные порты (у Huawei это
  *режим отладки*), приложение переводит его туда само и дальше управляет им
  как обычным модемом — отсюда берутся TAC, диапазон, EARFCN, USSD и AT-консоль.
  Режим сбрасывается при каждой перезагрузке модема, поэтому применяется заново
  при каждом его появлении. В настройках модема есть галочка, если так делать
  не нужно.

Диапазоны и режим сети у такого свистка меняются через его API, а не через
`AT^SYSCFGEX`: путь через AT заставляет модем сменить USB-композицию и выпасть
из режима отладки.

## 5gtop

Панель в терминале — на случай, когда вы в SSH, а не в браузере. Те же данные,
что и на веб-страницах, и тот же бэкенд: модем не опрашивается лишний раз.

```sh
5gtop        # английский
5gtop ru     # русский
```

<img width="1656" height="1226" alt="Screenshot From 2026-07-19 23-36-52" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="Screenshot From 2026-07-19 23-37-41" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

Вкладки: **Сеть**, **Информация о соте**, **Модем**, **SMS**, **USSD**,
**AT-консоль** и **eSIM**, когда присутствует eUICC. Клавиши срабатывают сразу,
без Enter: подсвеченная буква в названии вкладки переключает на неё, `Tab`
перебирает модемы в конфигурации с двумя модемами, `t` запускает тест скорости,
`r` обновляет, `q` выходит. Раскладка подстраивается под ширину терминала и на
узких экранах переключается в компактный режим.

## Установка

Возьмите ссылку на `.apk` (OpenWrt 25.12.x) или `.ipk` (24.10.x) со страницы
[Releases](../../releases) и выполните команды:

### .apk (OpenWrt 25.12.x)

```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.9.0/luci-app-5gmodem-1.9.0-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

Для **eSIM** (необязательно) поставьте заодно наш патченый `lpac` — **выберите
сборку под свою платформу** в [релизе lpac-build](https://github.com/fildunsky/lpac-build/releases/latest).
Пример для MediaTek Filogic (например, WH3000):

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

Сборка для MediaTek Filogic (aarch64_cortex-a53, например Huasifei WH3000) лежит
и в этом репозитории — можно поставить, не заходя в релизы lpac-build:

```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### .ipk (OpenWrt 24.10.x)

```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v1.9.0/luci-app-5gmodem_1.9.0-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

Обычный пакет тянет за собой полный набор (`sms-tool`, `comgt`, `qmi-utils`,
`modemmanager`, протоколы QMI/MBIM, kmod'ы USB-serial) — ставьте его поверх
любой предыдущей версии, ничего не удалится.

Для устройств с малой флеш-памятью (платы MT7628 с 8 МБ, куда полный набор не
влезет вообще) в релизе есть отдельный **`-lite.apk`**: ему нужен только
`sms-tool`. Метрики, SMS, USSD, управление диапазонами и AT-консоль работают;
теряются протоколы интерфейса QMI/MBIM и номер телефона, читаемый через `mmcli`.
Не ставьте lite-сборку как обновление на роутер, где работает модем по QMI или
MBIM: менеджер пакетов удалит эти пакеты как осиротевшие.

## eSIM / lpac

Вкладка eSIM (загрузка, включение, выключение и удаление профилей, уведомления)
требует [`lpac`](https://github.com/estkme-group/lpac). У официального `lpac`
(2.3.0) из OpenWrt 25.12 сломан бэкенд stdio, поэтому мы поставляем **патченую
сборку** — [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build) — с
доработками устойчивости нативного AT-драйвера, поддержкой bare-CCHO и
исправлением загрузчика плагинов для OpenWrt. Это универсальная сборка со всеми
APDU-бэкендами (AT, QMI, uqmi, MBIM), поэтому приложение выбирает подходящий
транспорт для каждого модема: AT для **Fibocom FM350-GL**, MBIM/QMI для модулей
на Qualcomm SDX55 вроде **Foxconn T99W175 / Thales MV31-W**.

Файлы `.apk` называются `lpac-<версия openwrt>-<target>-<subtarget>.apk`; сборки
для 24.10.x — это `.ipk`. В старых релизах имена начинались с `lpac-fm350-*`.

Скачайте `.apk` **для своей платформы** из
[последнего релиза lpac-build](https://github.com/fildunsky/lpac-build/releases/latest):

| Файл | Архитектура | Типичные устройства |
|------|-------------|---------------------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 и новые роутеры WiFi6 с USB |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | виртуалки, контейнеры, обычный ARM64 |
| `lpac-25.12.5-armsr-armv7.apk` | arm | обычный ARM32 |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | Xiaomi / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | старые MIPS-роутеры с USB |
| `lpac-25.12.5-x86-64.apk` | x86_64 | мини-ПК и роутеры-виртуалки |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<ваша-платформа>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### Проверенные модемы

| Модем | Транспорт APDU | Что проверено |
|-------|----------------|---------------|
| Fibocom FM350-GL | `at` (нативный AT-драйвер) | полный цикл — чтение eUICC, загрузка, включение, выключение и удаление профилей, уведомления |
| Foxconn T99W175 / Thales MV31-W | `mbim` (через mbim-proxy) | чтение eUICC: EID, сведения о чипе, список профилей, свободная память. Загрузка профиля пока не подтверждена |

Транспорт выбирается автоматически по протоколу интерфейса, руками его обычно
задавать не нужно. На пути через MBIM eUICC доступен независимо от того, какой
слот SIM активен, поэтому физическая SIM во время работы с eSIM остаётся в сети.

`lpac` — **необязательная** зависимость: вкладка eSIM появляется, только если он
установлен и присутствует eUICC. Всё остальное работает и без него.

## Сборка из исходников

Пакет собирается штатным OpenWrt SDK. Как feed:

```sh
# в вашем OpenWrt — "modem" здесь просто имя feed'а, выбираете любое
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI (`.github/workflows/build.yml`) собирает `.ipk` и `.apk` на каждый тег и
прикладывает их к релизу; сборку можно запустить и вручную со вкладки Actions.

## Благодарности

В основе — работы [Rafał Wabik (IceG)](https://github.com/4IceG) и
[Cezary Jackiewicz](https://github.com/obsy). Расчёт шкалы сигнала адаптирован из
[koshev-msk](https://github.com/koshev-msk). Лицензия — **GPL-3.0**.
