# luci-app-5gmodem

*[English](README.md) · [Русская версия](README.ru.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)*

Ứng dụng LuCI dành cho modem 4G/5G trên OpenWrt. Ứng dụng gộp [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) và một số phần của `modemband` vào một ứng dụng duy nhất.

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-39" src="https://github.com/user-attachments/assets/1adb9ca6-8f38-445c-8cb8-2a0f6b8005c9" />

## Cài đặt
Lấy liên kết `.apk` (OpenWrt 25.12.x) hoặc `.ipk` (24.10.x) từ trang [Releases](../../releases), sau đó chạy lệnh:

### .apk (OpenWrt 25.12.x)
```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.2.14/luci-app-5gmodem-3.2.14-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

**Giao diện tiếng Việt**: cài gói tiếng Việt của ứng dụng này và gói tiếng Việt của chính LuCI:
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.2.14/luci-i18n-5gmodem-vi.apk > /tmp/luci-i18n-5gmodem-vi.apk
apk add /tmp/luci-i18n-5gmodem-vi.apk --allow-untrusted
apk add luci-i18n-base-vi
```
Sau đó chọn ngôn ngữ trong LuCI: Hệ thống → Hệ thống → Ngôn ngữ và giao diện → Tiếng Việt.

Để dùng **eSIM** (tùy chọn), hãy cài thêm bản `lpac` đã vá của chúng tôi — **chọn bản dựng cho nền tảng của bạn** từ [bản phát hành lpac-build](https://github.com/fildunsky/lpac-build/releases/latest). Ví dụ cho MediaTek Filogic (chẳng hạn WH3000):
```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

Bản dựng Filogic đó cũng được sao lưu trong kho này, nên bạn có thể thay URL bằng
`https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk`
nếu không muốn vào trang phát hành lpac-build. Các nền tảng khác chỉ có trong
trang phát hành.

### .ipk (OpenWrt 24.10.x)
```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.2.14/luci-app-5gmodem_3.2.14-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

**Giao diện tiếng Việt**:
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.2.14/luci-i18n-5gmodem-vi.ipk > /tmp/luci-i18n-5gmodem-vi.ipk
opkg install /tmp/luci-i18n-5gmodem-vi.ipk
opkg install luci-i18n-base-vi
```

Gói thông thường kéo theo trọn bộ (`sms-tool`, `comgt`, `qmi-utils`, `modemmanager`, các giao thức QMI/MBIM, kmod USB-serial) — có thể nâng cấp đè lên bất kỳ phiên bản cũ nào mà không bị gỡ bỏ thứ gì.

Với thiết bị có bộ nhớ flash nhỏ (bo mạch MT7628 với 8 MB, nơi trọn bộ hoàn toàn không cài được) có một gói **`-lite.apk`** riêng trong bản phát hành: gói này chỉ yêu cầu `sms-tool`. Thông số, SMS, USSD, điều khiển băng tần và bảng điều khiển AT đều hoạt động; bạn mất các giao thức giao diện QMI/MBIM và việc đọc số điện thoại qua `mmcli`. Đừng dùng bản lite để nâng cấp trên router đang chạy modem QMI hoặc MBIM — trình quản lý gói sẽ gỡ các gói đó vì coi chúng là gói mồ côi.

> **Muốn lấy dữ liệu từ ứng dụng cho dịch vụ của riêng bạn?** Nhà thông minh,
> màn hình ngoài, bảng điều khiển của người khác, một script tự viết — tất cả
> đều ở một chỗ: [Telemetry: cách lấy các thông số](docs/telemetry.md).
> Định dạng trường, thỏa thuận với bên sử dụng và bốn cách truyền dữ liệu — tệp, SSH,
> MQTT, HTTP.

## Modem không hoạt động hoặc chưa được hỗ trợ?

Hãy gửi báo cáo chẩn đoán: nhờ đó chúng tôi thêm modem mới và sửa lỗi.

1. Trong LuCI, mở **Modem → Modem 5G → Modem**, tìm **Báo cáo chẩn đoán** và bấm **Thu thập nhật ký** - tệp sẽ được tải về máy tính. Nếu trang không mở được, hãy chạy lệnh sau qua SSH rồi lấy tệp từ router:
   ```sh
   /usr/share/5gmodem/collect.sh run > /tmp/5gmodem-diag.txt
   ```
2. [Tạo issue](../../issues/new), ghi rõ model modem và lỗi gặp phải, rồi đính kèm tệp.

Báo cáo có chứa IMEI, IMSI, ICCID và tên nhà mạng, nhưng không có mật khẩu hay khóa Wi-Fi. Nếu không muốn công khai các mã định danh này, hãy xóa chúng khỏi tệp trước khi đính kèm.

## Tính năng

- Nút **tạo giao diện modem dễ dàng** (Cài đặt modem) — tự động thiết lập một giao diện `network` cho modem.
- **Chế độ hai modem và bộ chuyển đường lên (uplink)**
- **Chuyển đổi hai SIM và eSIM** đã được kiểm tra và hoạt động với Fibocom FM350-GL (AT) và Foxconn T99W175 / Thales MV31-W (MBIM) — hãy cài bản `lpac` đã vá cho nền tảng của bạn từ [các bản phát hành lpac-build](https://github.com/fildunsky/lpac-build/releases/latest) (xem mục [eSIM / lpac](#esim--lpac) bên dưới)!
- **Mạng** — mức tín hiệu chi tiết, nhà mạng, công nghệ kèm gộp sóng mang (ví dụ `LTE-A | B1 + B40 / B7 / B3`), IPv4/IPv6 của giao diện, thống kê kết nối và nhiệt độ modem (nếu modem có báo).
- **Quản lý băng tần và chế độ** — chọn chế độ mạng (Tự động / 2G / 3G / 4G / 4G+5G / 5G) và bật/tắt từng băng tần LTE/NR.
- **Cố định TTL** — ép TTL IPv4 và hop-limit IPv6 cho lưu lượng vào/ra trên giao diện modem (qua một include `nftables` trong `fw4`).
- **Bản đồ trạm phát sóng** — Cell ID là một nút mở trạm trên [4cells.ru](https://4cells.ru).
- **Khởi động lại modem** — một cú nhấp để khởi động lại sóng radio mềm `AT+CFUN=4,1` và đặt lại modem `AT+CFUN=1,1`.
- Các thẻ **Hộp thư SMS / Gửi**, **USSD** và **AT**, mỗi thẻ có một bảng cài đặt riêng có thể thu gọn. Tùy chọn chuyển tiếp SMS đến qua e-mail và hỗ trợ đèn LED/thông báo.
- **Bot Telegram** — SMS đến từ mọi modem đều được gửi vào cuộc trò chuyện, và các lệnh `/sms`, `/status` và `/modem` hoạt động ngay từ cuộc trò chuyện.
- **Ô lân cận** — một bảng dưới phần gộp sóng mang: ô phục vụ và các ô lân cận với PCI, kênh và mức tín hiệu (Fibocom FM350-GL, modem QMI).
- **Nút cập nhật cơ sở dữ liệu APN** — làm mới cơ sở dữ liệu nhà mạng toàn cầu (GNOME MBPI + AOSP) mà không cần cài lại ứng dụng.
- **Tự động nhận diện cổng** — cổng AT và giao diện mạng được nhận diện tự động; có thể đặt thủ công.
- **USB modem không có cổng AT** (Huawei HiLink và các loại tương tự) cũng được hỗ trợ — xem bên dưới.
- **Telemetry cho nhà thông minh** — một tệp JSON phẳng tại `/tmp/5gmodem/tele.json` (tín hiệu, nhà mạng, chế độ, gộp sóng mang, tốc độ, số SMS) cùng tùy chọn xuất bản qua MQTT với tự động nhận diện Home Assistant; xem [docs/telemetry.md](docs/telemetry.md).
- **`5gtop`** — bảng điều khiển trong terminal với cùng dữ liệu, dành cho khi bạn đang ở SSH chứ không phải trong trình duyệt.


## Đã kiểm tra:
Tôi đã bổ sung tính năng mới cho các modem này (so với 3ginfo và modemband)
- Fibocom FM350-GL
- Fibocom L850 (Intel XMM)
- Fibocom L860 (Intel XMM)
- Compal RXM-G1 (SG500M2-X)
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- Quectel EP06-E
- MeigLink SLM770A-R
- Foxconn T99W175 / Thales MV31-W (Snapdragon X55)
- Dell DW5821e / Foxconn T77W968 (Snapdragon X20)
- HP lt4120 / Foxconn T77W595 (Snapdragon X5)
- Sierra Wireless EM9190
- Huawei E3372 (HiLink)
- Tenda MF6 (Mi-Fi dùng ZTE ZX297520V3, USB 19d2:1557) — tín hiệu, pin, SMS và khởi động lại qua web API; băng tần và chế độ mạng qua AT ở debug mode
- Các USB Android giá rẻ Qualcomm MDM9600 / MDM9610 (PIXLINK, ALEKA UV310 và các loại tương tự), kể cả chế độ "chỉ modem" (QMI) của chúng
- Nhiều modem khác chưa được kiểm tra, nhưng sẽ hỗ trợ mọi modem mà các bản fork gốc hỗ trợ.

### Đã sửa theo báo cáo của người dùng
Tôi không sở hữu các modem này. Chủ sở hữu đã gửi log và kết quả AT, và các bản sửa đã được phát hành:
- Telit FN990A28 — khởi động sạch, không còn vòng lặp ngắt nguồn "SIM in illegal state", điều khiển băng tần và chế độ mạng, gộp sóng mang
- Quectel RM520N-GL — chuỗi tên model và firmware
- Foxconn T99W373 — gộp sóng mang ở 5G NSA
- NTmore NTLM-500 (Altair ALT3800, từ router gia đình Skylink H1) — tín hiệu, ô phục vụ và ô lân cận, mức tín hiệu theo từng ăng-ten, nhiệt độ, công suất phát, suy hao đường truyền, chọn băng tần
- Tri Cascade VOS 5G / SG500M2-X (Compal RXM-G1, USB 05c6:9091, ModemManager qua QMI) — được nhận diện theo model, nên giao diện được dựng trên `proto=modemmanager` thay vì đường `uqmi` mà firmware của nó không phục vụ; giao diện ADB được giải phóng khỏi driver serial. Hạn chế đã biết: các tuyến mặc định IPv6 theo nguồn (`default from …`) vẫn do netifd quản lý và không được tính năng ưu tiên internet sắp xếp lại
- Fibocom NL668-EAU (USB 2cb7:0110) — tín hiệu và thông tin cell, băng tần LTE, chế độ mạng kể cả 2G
- SIMCom SIM7906 / SIM7912 (USB 1e0e:9001) — tín hiệu, băng tần, carrier aggregation

### Bổ sung theo tài liệu của nhà sản xuất
Chưa có phần cứng và chưa có báo cáo cho các modem này: các profile dựa theo hướng dẫn lệnh AT của nhà sản xuất và đã được đối chiếu với các câu trả lời mẫu in trong đó. Rất hoan nghênh log từ chủ sở hữu.
- Foxconn T99W373 / Thales MV32-W (Snapdragon X62) — băng tần cho LTE, 5G NSA, 5G SA và WCDMA, khóa ô, chế độ mạng, chế độ 5G, đầy đủ thông số ô và ăng-ten
- Các modem Altair ALT3100 / ALT3800 khác (USB vendor 216f): Yota 4G LTE (Swift WLTUBA-107), NTmore JMR814 — dùng profile NTLM-500 bất cứ khi nào USB có cổng AT

### Bổ sung theo báo cáo trên diễn đàn 4pda
Không có phần cứng ở đây: các profile dựa theo câu trả lời của USB và các trang trạng thái mà chủ sở hữu đã đăng trên diễn đàn 4pda.
- Huawei E3372h ở chế độ USB HiLink "Gateway NCM" (USB 12d1:155a) — profile AT của E3372: tín hiệu, băng tần, EARFCN, nhiệt độ
- Các USB Yota không có cổng AT: Gemtek WLTUBA-107/115 và WLTUBQ-108 (USB 15a9:002d, 15a9:003a), Yota LU150 trên GCT GDM7240 (USB 1076:8002) — dữ liệu tín hiệu, ô và SIM từ trang trạng thái riêng của USB
- Các chế độ nạp firmware và khởi động (Qualcomm EDL và crash dump, chế độ kim và fastboot của Huawei, Sierra QDL, MediaTek BootROM, cổng cập nhật của Alcatel) không còn bị hiển thị như modem

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-52" src="https://github.com/user-attachments/assets/0bd100f7-780f-47e3-98a4-9729bf29ee8b" />

### USB modem không có cổng AT (HiLink)

Các USB như Huawei E3372 tự giữ ngăn xếp IP: router chỉ thấy
một card Ethernet, mọi thứ khác nằm sau giao diện web riêng của USB.
Hoàn toàn không có cổng AT, nên cơ chế thăm dò thông thường không có gì để
giao tiếp.

Ứng dụng vẫn xử lý được chúng:

- modem được nhận diện qua mô tả USB (một USB chỉ đơn giản là chưa được gắn
  driver sẽ *không* bị nhầm là loại này) và được cấp một giao diện DHCP;
- thông số, SMS và tên nhà mạng được đọc qua HTTP API của USB;
- nếu USB có thể mở cổng serial (Huawei gọi là *debug mode*), ứng dụng
  tự động chuyển nó sang chế độ đó rồi điều khiển như mọi modem khác —
  đó là nguồn của TAC, băng tần, EARFCN, USSD và bảng điều khiển AT. Chế độ
  này bị đặt lại mỗi khi modem khởi động lại, nên nó được áp dụng lại mỗi lần modem xuất hiện.
  Có một ô đánh dấu trong Cài đặt modem nếu bạn không muốn điều đó.

Băng tần và chế độ mạng của USB loại này được thay đổi qua API của nó thay vì
`AT^SYSCFGEX`: đường AT khiến modem bỏ cấu hình USB composition và thoát
khỏi debug mode.

USB dùng chip ZTE (Tenda MF6 và các loại tương tự) thì khác: debug mode được bật
bằng một lệnh web và vẫn giữ sau khi khởi động lại, còn băng tần được đặt qua AT
(`AT+ZLTEBAND`) — web API của chúng không có cài đặt băng tần. Nếu giao diện web
của USB có mật khẩu, hãy nhập ở trang Modem: không có mật khẩu, các USB này không
trả về gì cả.

## Nút bấm
<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-03-18" src="https://github.com/user-attachments/assets/60a6dce9-6723-45ae-99f0-2c0ae4b7e725" />

## 5gtop

Bảng điều khiển trong terminal, dành cho khi bạn đang ở SSH chứ không phải trong trình duyệt. Cùng
dữ liệu với các trang web, cùng backend — không thăm dò modem thêm.

```sh
5gtop        # English
5gtop ru     # Russian
```
<img width="1656" height="1226" alt="Screenshot From 2026-07-19 23-36-52" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="Screenshot From 2026-07-19 23-37-41" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

Các thẻ: **Network**, **Cell info**, **Modem**, **SMS**, **USSD**, **AT console**,
và **eSIM** khi có eUICC. Phím bấm một lần (không cần Enter): chữ cái
được tô sáng trong tên mỗi thẻ sẽ chuyển sang thẻ đó, `Tab` luân chuyển giữa các modem khi dùng
hai modem, `t` chạy kiểm tra tốc độ, `r` làm mới, `q` thoát. Bố cục
theo chiều rộng terminal và chuyển sang chế độ hẹp trên màn hình nhỏ.


## eSIM / lpac

Thẻ eSIM (tải xuống / bật / tắt / xóa profile, thông báo) cần [`lpac`](https://github.com/estkme-group/lpac). `lpac` chính thức của OpenWrt 25.12 (2.3.0) có backend stdio bị lỗi, nên chúng tôi cung cấp một **bản dựng đã vá** — [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build) — với các PR tăng độ ổn định cho driver AT gốc, hỗ trợ CCHO trần và bản sửa trình nạp cho OpenWrt. Đây là bản dựng đa dụng mang mọi backend APDU (AT, QMI, uqmi, MBIM), nên ứng dụng chọn đúng phương thức truyền cho từng modem: AT cho **Fibocom FM350-GL**, MBIM/QMI cho các module Qualcomm SDX55 như **Foxconn T99W175 / Thales MV31-W**.

Các tệp `.apk` được đặt tên theo dạng `lpac-<openwrt>-<target>-<subtarget>.apk`; bản dựng cho 24.10.x là `.ipk`. Các bản phát hành cũ dùng tiền tố `lpac-fm350-*`.

Tải `.apk` cho **nền tảng của bạn** từ [bản phát hành lpac-build mới nhất](https://github.com/fildunsky/lpac-build/releases/latest):

| Tệp | Kiến trúc | Thiết bị điển hình |
|------|------|-----------------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 và các router WiFi6 mới có USB |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | VM / container / ARM64 chung |
| `lpac-25.12.5-armsr-armv7.apk` | arm | ARM32 chung |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | Xiaomi / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | router MIPS cũ có USB |
| `lpac-25.12.5-x86-64.apk` | x86_64 | router mini-PC / VM |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<your-platform>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### Modem đã kiểm tra

| Modem | Phương thức truyền APDU | Đã xác minh |
|-------|----------------|-------------------|
| Fibocom FM350-GL | `at` (driver AT gốc) | trọn chu trình — đọc eUICC, tải xuống / bật / tắt / xóa profile, thông báo |
| Foxconn T99W175 / Thales MV31-W | `mbim` (qua mbim-proxy) | đọc eUICC: EID, thông tin chip, danh sách profile, bộ nhớ trống. Việc tải profile chưa được xác nhận |

Phương thức truyền được chọn tự động theo giao thức của giao diện, nên thông thường bạn không cần đặt thủ công. Trên đường MBIM, eUICC truy cập được bất kể khe SIM nào đang hoạt động, nên SIM vật lý vẫn trực tuyến trong khi bạn làm việc với eSIM.

`lpac` là phụ thuộc **tùy chọn** — thẻ eSIM chỉ xuất hiện khi nó đã được cài và có eUICC; phần còn lại của ứng dụng hoạt động không cần nó.

## Dựng từ mã nguồn

Gói được dựng bằng OpenWrt SDK tiêu chuẩn. Dưới dạng một feed:

```sh
# in your OpenWrt — "modem" here is just a feed name you pick
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI (`.github/workflows/build.yml`) dựng `.ipk`/`.apk` mỗi khi có tag và đính kèm chúng vào bản phát hành; cũng có thể chạy thủ công từ thẻ Actions.

## Quyền hạn

Ứng dụng chạy với quyền **root** và cung cấp các khả năng của mình qua nhóm ACL
`luci-app-5gmodem` (`/usr/share/rpcd/acl.d/`). Nhóm này **tương đương root**,
điều quan trọng cần cân nhắc trước khi cấp nó cho bất kỳ ai không phải quản trị viên đầy đủ:

- nhóm cho phép gửi **bất kỳ lệnh AT nào** tới modem (qua `atcmd.sh` — bảng điều khiển
  AT cần điều đó theo thiết kế). Bản thân tệp nhị phân `sms_tool` không còn nằm trong
  ACL: qua nó trình duyệt còn có thể chạy `send`, `delete all` và truy cập
  `/dev/*` không liên quan, mà không có gì kiểm tra được các tham số;
- ~~ghi `/etc/crontabs/root`~~ — **đã bỏ**. Quyền đó chỉ tồn tại cho lịch
  khởi động lại trình thông báo SMS; giờ `smscron.sh` đảm nhận việc này, chỉ động vào
  dòng của chính nó và kiểm tra khoảng thời gian. Các tác vụ cron khác không bị đọc hay thay đổi. Quản trị viên đầy đủ vẫn có
  khả năng đó — qua trang "Scheduled Tasks" của chính LuCI, đúng là nơi
  nó thuộc về;
- đọc cấu hình `5gmodem` sẽ làm lộ mật khẩu SMTP cho việc chuyển tiếp SMS nếu
  có đặt (OpenWrt giữ mật khẩu trong `/etc/config` dưới dạng văn bản thuần, giống
  như cách nó giữ khóa Wi-Fi).

Đừng cấp nhóm này cho một vai trò bị giới hạn, chẳng hạn "người vận hành chỉ được
xem các modem". Không có cách nào lách được: việc lọc tham số nằm trong
trang, và trang chạy trong trình duyệt của người dùng. Một vai trò như vậy cần bộ
lệnh gọi hẹp riêng, không phải một tập con của nhóm này.

## Ghi công

Dựa trên công trình của [Rafał Wabik (IceG)](https://github.com/4IceG) và [Cezary Jackiewicz](https://github.com/obsy). Phần tính toán vạch tín hiệu được phỏng theo [koshev-msk](https://github.com/koshev-msk). Cấp phép theo **GPL-3.0**.
