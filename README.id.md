# luci-app-5gmodem

*[English](README.md) · [Русская версия](README.ru.md) · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [Tiếng Việt](README.vi.md)*

Aplikasi LuCI untuk modem 4G/5G di OpenWrt. Aplikasi ini menggabungkan [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite), [`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) dan sebagian dari `modemband` menjadi satu aplikasi.

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-39" src="https://github.com/user-attachments/assets/1adb9ca6-8f38-445c-8cb8-2a0f6b8005c9" />

## Instalasi
Ambil tautan `.apk` (OpenWrt 25.12.x) atau `.ipk` (24.10.x) dari halaman [Releases](../../releases), lalu jalankan perintah berikut:

### .apk (OpenWrt 25.12.x)
```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.9.7/luci-app-5gmodem-3.9.7-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

**Tampilan bahasa Indonesia**: pasang paket bahasa Indonesia untuk aplikasi ini. LuCI sendiri belum memiliki terjemahan bahasa Indonesia, jadi menu LuCI lainnya tetap berbahasa Inggris:
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.9.7/luci-i18n-5gmodem-id.apk > /tmp/luci-i18n-5gmodem-id.apk
apk add /tmp/luci-i18n-5gmodem-id.apk --allow-untrusted
```
Setelah itu pilih bahasanya di LuCI: Sistem → Sistem → Bahasa dan Gaya → Bahasa Indonesia.

Untuk **eSIM** (opsional), pasang juga `lpac` versi tambalan kami — **pilih build untuk platform Anda** dari [rilis lpac-build](https://github.com/fildunsky/lpac-build/releases/latest). Contoh untuk MediaTek Filogic (misalnya WH3000):
```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

Build Filogic yang sama juga dicerminkan di repositori ini, jadi Anda bisa mengganti URL-nya dengan
`https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk`
jika tidak ingin membuka rilis lpac-build. Platform lain hanya tersedia di
rilis tersebut.

### .ipk (OpenWrt 24.10.x)
```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.9.7/luci-app-5gmodem_3.9.7-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

**Tampilan bahasa Indonesia**:
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v3.9.7/luci-i18n-5gmodem-id.ipk > /tmp/luci-i18n-5gmodem-id.ipk
opkg install /tmp/luci-i18n-5gmodem-id.ipk
```

Paket reguler menarik set lengkap (`sms-tool`, `comgt`, `qmi-utils`, `modemmanager`, protokol QMI/MBIM, kmod USB-serial) — paket ini bisa dipasang di atas versi sebelumnya mana pun tanpa ada yang terhapus.

Untuk perangkat dengan flash kecil (board MT7628 dengan 8 MB, tempat set lengkap sama sekali tidak muat) tersedia **`-lite.apk`** terpisah di rilis: paket ini hanya membutuhkan `sms-tool`. Metrik, SMS, USSD, kontrol band, dan konsol AT semuanya berfungsi; yang hilang adalah protokol antarmuka QMI/MBIM dan pembacaan nomor telepon melalui `mmcli`. Jangan gunakan build lite sebagai pembaruan di router yang menjalankan modem QMI atau MBIM — manajer paket akan membuang paket-paket tersebut sebagai paket yatim.

> **Ingin menarik data dari aplikasi ini ke layanan Anda sendiri?** Rumah pintar,
> layar eksternal, dasbor milik orang lain, skrip buatan sendiri - semuanya ada
> di satu tempat: [Telemetri: cara mengambil metrik](docs/telemetry.md).
> Format field, kontrak untuk konsumen, dan empat opsi pengiriman - file, SSH,
> MQTT, HTTP.

## Modem tidak berfungsi atau tidak didukung?

Kirimkan laporan diagnostik: dengan cara itulah modem baru ditambahkan dan bug diperbaiki.

1. Di LuCI buka **Modem → 5G Modem → Modem**, cari **Diagnostic report** lalu tekan **Collect logs** - file akan terunduh ke komputer Anda. Jika halaman tidak terbuka, jalankan ini melalui SSH lalu salin file dari router:
   ```sh
   /usr/share/5gmodem/collect.sh run > /tmp/5gmodem-diag.txt
   ```
2. [Buka issue](../../issues/new) dengan model modem dan penjelasan apa yang salah, lalu lampirkan file tersebut.

Laporan berisi IMEI, IMSI, ICCID dan nama operator, tetapi tidak berisi kata sandi atau kunci Wi-Fi. Jika Anda tidak ingin memublikasikan pengenal tersebut, kosongkan di dalam file sebelum melampirkannya.

## Fitur

- Tombol **Easy create modem interface** (Modem Settings) — menyiapkan antarmuka `network` untuk modem secara otomatis.
- **Mode modem ganda dan pengalih uplink**
- **Peralihan dual SIM dan eSIM** sudah diuji dan berfungsi dengan Fibocom FM350-GL (AT) dan Foxconn T99W175 / Thales MV31-W (MBIM) — pasang `lpac` versi tambalan kami untuk platform Anda dari [rilis lpac-build](https://github.com/fildunsky/lpac-build/releases/latest) (lihat bagian [eSIM / lpac](#esim--lpac) di bawah)!
- **Jaringan** — level sinyal lanjutan, operator, teknologi dengan carrier aggregation (misalnya `LTE-A | B1 + B40 / B7 / B3`), IPv4/IPv6 antarmuka, statistik koneksi, dan suhu modem (jika modem melaporkannya).
- **Manajemen band & mode** — pilih mode jaringan (Auto / 2G / 3G / 4G / 4G+5G / 5G) dan aktifkan/nonaktifkan band LTE/NR satu per satu.
- **Perbaikan TTL** — paksa TTL IPv4 dan hop-limit IPv6 masuk/keluar pada antarmuka modem (melalui include `nftables` di `fw4`).
- **Peta menara seluler** — Cell ID adalah tombol yang membuka menara tersebut di [4cells.ru](https://4cells.ru).
- **Restart modem** — restart radio lunak sekali klik `AT+CFUN=4,1` dan reset modem `AT+CFUN=1,1`.
- Tab **SMS Inbox / Send**, **USSD** dan **AT**, masing-masing dengan panel pengaturan per tab yang bisa dilipat. Penerusan SMS masuk ke e-mail (opsional) serta dukungan LED/notifikasi.
- **Bot Telegram** — SMS masuk dari setiap modem sampai ke chat, dan `/sms`, `/status` serta `/modem` bisa digunakan dari chat.
- **Sel tetangga** — tabel di bawah carrier aggregation: sel yang melayani dan tetangganya dengan PCI, kanal, dan level (Fibocom FM350-GL, modem QMI).
- **Tombol pembaruan basis data APN** — perbarui basis data operator dunia (GNOME MBPI + AOSP) tanpa memasang ulang aplikasi.
- **Deteksi port otomatis** — port AT dan antarmuka jaringan terdeteksi otomatis; bisa juga diatur manual.
- **Stik USB tanpa port AT** (Huawei HiLink dan sejenisnya) juga didukung — lihat di bawah.
- **Telemetri untuk rumah pintar** — JSON datar di `/tmp/5gmodem/tele.json` (sinyal, operator, mode, aggregation, kecepatan, jumlah SMS) ditambah publikasi MQTT opsional dengan auto-discovery Home Assistant; lihat [docs/telemetry.md](docs/telemetry.md).
- **`5gtop`** — dasbor terminal dengan data yang sama, untuk saat Anda berada di SSH dan bukan di browser.


## Sudah diuji:
Saya menambahkan fitur baru untuk modem-modem ini (dibandingkan dengan 3ginfo dan modemband)
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
- Tenda MF6 (ZTE ZX297520V3 Mi-Fi, USB 19d2:1557) — sinyal, baterai, SMS, dan reboot melalui web API-nya; band dan mode jaringan melalui AT dalam mode debug
- Stik Android Qualcomm MDM9600 / MDM9610 murah (PIXLINK, ALEKA UV310 dan sejenisnya), termasuk mode "modem only" (QMI)
- UFI003 (stik Android Qualcomm MSM8916, USB 05c6:90b4) — sinyal lewat AT, suhu dan SINR lewat ADB, mode jaringan; juga stik yang sama dengan OpenWrt, modem bawaannya dikendalikan lewat ModemManager (band, mode jaringan, SMS, pemilihan jaringan manual)
- Mi-Fi Android MediaTek MT6735 (USB 0e8d:2004) — trafik, lama koneksi, baterai, dan mode jaringan lewat web API, enam sensor suhu lewat ADB; dengan paket opsional `5gmodem-mtk-at` juga RSRQ, SINR, RSSI, info sel, dan pergantian band LTE
- Masih banyak lagi yang belum diuji, tetapi seharusnya mendukung semua modem yang ditangani oleh fork upstream.

### Diperbaiki dari laporan pengguna
Saya tidak memiliki perangkat ini. Pemiliknya mengirimkan log dan keluaran AT, dan perbaikannya sudah dirilis:
- Telit FN990A28 — start bersih tanpa loop power-cycle "SIM in illegal state", kontrol band dan mode jaringan, carrier aggregation
- Quectel RM520N-GL — string model dan firmware
- Foxconn T99W373 — carrier aggregation di 5G NSA
- NTmore NTLM-500 (Altair ALT3800, dari router rumah Skylink H1) — sinyal, sel yang melayani dan sel tetangga, level per antena, suhu, daya TX, path loss, pemilihan band
- Tri Cascade VOS 5G / SG500M2-X (Compal RXM-G1, USB 05c6:9091, ModemManager melalui QMI) — dikenali berdasarkan model, sehingga antarmuka dibangun dengan `proto=modemmanager` alih-alih jalur `uqmi` yang tidak dilayani firmware-nya; antarmuka ADB dilepaskan dari driver serial. Keterbatasan yang diketahui: default IPv6 spesifik sumber (`default from …`) tetap dikelola netifd dan tidak diurutkan ulang oleh fitur prioritas internet
- Fibocom NL668-EAU (USB 2cb7:0110) — metrik sinyal dan sel, band LTE, mode jaringan termasuk 2G
- SIMCom SIM7906 / SIM7912 (USB 1e0e:9001) — sinyal, band, carrier aggregation

### Ditambahkan dari dokumentasi vendor
Belum ada perangkat keras maupun laporan untuk modem-modem ini: profilnya mengikuti panduan perintah AT dari vendor dan sudah dicocokkan dengan contoh jawaban yang tercetak di dalamnya. Log dari pemilik sangat diharapkan.
- Foxconn T99W373 / Thales MV32-W (Snapdragon X62) — band untuk LTE, 5G NSA, 5G SA dan WCDMA, cell lock, mode jaringan, mode 5G, metrik sel dan antena lengkap
- Modem Altair ALT3100 / ALT3800 lainnya (vendor USB 216f): Yota 4G LTE (Swift WLTUBA-107), NTmore JMR814 — profil NTLM-500, digunakan setiap kali stik menyediakan port AT

### Ditambahkan dari laporan forum 4pda
Tidak ada perangkat kerasnya di sini: profilnya mengikuti balasan stik dan halaman status yang diunggah pemiliknya di forum 4pda.
- Huawei E3372h dalam mode stik HiLink "Gateway NCM" (USB 12d1:155a) — profil AT E3372: sinyal, band, EARFCN, suhu
- Stik Yota tanpa port AT: Gemtek WLTUBA-107/115 dan WLTUBQ-108 (USB 15a9:002d, 15a9:003a), Yota LU150 dengan GCT GDM7240 (USB 1076:8002) — data sinyal, sel, dan SIM dari halaman status stik itu sendiri
- Mode flashing dan boot (Qualcomm EDL dan crash dump, mode needle dan fastboot Huawei, Sierra QDL, MediaTek BootROM, port updater Alcatel) tidak lagi ditampilkan sebagai modem

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-52" src="https://github.com/user-attachments/assets/0bd100f7-780f-47e3-98a4-9729bf29ee8b" />

### Stik USB tanpa port AT (HiLink)

Stik seperti Huawei E3372 menjalankan tumpukan IP sendiri: router hanya melihat
sebuah kartu Ethernet, dan semua hal lainnya berada di balik antarmuka web milik
stik itu. Tidak ada port AT sama sekali, sehingga polling biasa tidak punya
lawan bicara.

Aplikasi ini tetap menanganinya:

- modem dikenali dari deskriptor USB-nya (stik yang sekadar belum terikat ke
  driver *tidak* dikira sebagai stik semacam ini) dan mendapat antarmuka DHCP;
- metrik, SMS, dan nama operator dibaca melalui HTTP API stik;
- jika stik bisa menyediakan port serial (Huawei menyebutnya *debug mode*),
  aplikasi otomatis mengalihkannya ke mode itu lalu mengendalikannya seperti
  modem lain — dari situlah TAC, band, EARFCN, USSD, dan konsol AT berasal. Mode
  ini direset setiap kali modem reboot, jadi diterapkan ulang setiap kali modem
  muncul. Ada kotak centang di Modem Settings jika Anda tidak menginginkannya.

Band dan mode jaringan untuk stik seperti ini diubah melalui API-nya, bukan
`AT^SYSCFGEX`: jalur AT membuat modem kehilangan komposisi USB-nya dan keluar
dari debug mode.

Stik berbasis ZTE (Tenda MF6 dan sejenisnya) berbeda: debug mode diaktifkan
dengan perintah web dan bertahan setelah reboot, dan band diatur melalui AT (`AT+ZLTEBAND`)
— web API-nya tidak punya pengaturan band. Jika antarmuka web stik memiliki
kata sandi, masukkan di halaman Modem: tanpa itu stik ini tidak memberikan apa pun.

## Tombol
<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-03-18" src="https://github.com/user-attachments/assets/60a6dce9-6723-45ae-99f0-2c0ae4b7e725" />

## 5gtop

Dasbor terminal, untuk saat Anda berada di SSH dan bukan di browser. Datanya
sama dengan halaman web, backend-nya sama — tanpa polling tambahan ke modem.

```sh
5gtop        # English
5gtop ru     # Russian
```
<img width="1656" height="1226" alt="Screenshot From 2026-07-19 23-36-52" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="Screenshot From 2026-07-19 23-37-41" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

Tab: **Network**, **Cell info**, **Modem**, **SMS**, **USSD**, **AT console**,
dan **eSIM** jika ada eUICC. Tombol cukup ditekan sekali (tanpa Enter): huruf
yang disorot di setiap nama tab beralih ke tab itu, `Tab` berganti antar modem
pada konfigurasi modem ganda, `t` menjalankan uji kecepatan, `r` menyegarkan,
`q` keluar. Tata letak mengikuti lebar terminal dan beralih ke mode sempit di
layar kecil.


## eSIM / lpac

Tab eSIM (unduh / aktifkan / nonaktifkan / hapus profil, notifikasi) membutuhkan [`lpac`](https://github.com/estkme-group/lpac). `lpac` resmi OpenWrt 25.12 (2.3.0) memiliki backend stdio yang rusak, jadi kami menyertakan **build tambalan** — [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build) — dengan PR ketahanan driver AT native, dukungan bare-CCHO, dan perbaikan loader untuk OpenWrt. Ini adalah build serbaguna yang membawa semua backend APDU (AT, QMI, uqmi, MBIM), sehingga aplikasi memilih transport yang tepat untuk setiap modem: AT untuk **Fibocom FM350-GL**, MBIM/QMI untuk modul Qualcomm SDX55 seperti **Foxconn T99W175 / Thales MV31-W**.

File `.apk` dinamai `lpac-<openwrt>-<target>-<subtarget>.apk`; build 24.10.x berupa `.ipk`. Rilis lama menggunakan awalan `lpac-fm350-*`.

Unduh `.apk` **untuk platform Anda** dari [rilis lpac-build terbaru](https://github.com/fildunsky/lpac-build/releases/latest):

| File | Arsitektur | Perangkat umum |
|------|------|-----------------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 & router WiFi6 baru dengan USB |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | VM / kontainer / ARM64 generik |
| `lpac-25.12.5-armsr-armv7.apk` | arm | ARM32 generik |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | Xiaomi / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | router MIPS lama dengan USB |
| `lpac-25.12.5-x86-64.apk` | x86_64 | router mini-PC / VM |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<your-platform>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### Modem yang sudah diuji

| Modem | Transport APDU | Apa yang diverifikasi |
|-------|----------------|-------------------|
| Fibocom FM350-GL | `at` (driver AT native) | siklus penuh — baca eUICC, unduh / aktifkan / nonaktifkan / hapus profil, notifikasi |
| Foxconn T99W175 / Thales MV31-W | `mbim` (melalui mbim-proxy) | baca eUICC: EID, info chip, daftar profil, memori kosong. Unduh profil belum terkonfirmasi |

Transport dipilih otomatis berdasarkan protokol antarmuka, jadi biasanya Anda tidak perlu mengaturnya secara manual. Pada jalur MBIM, eUICC bisa dijangkau terlepas dari slot SIM mana yang aktif, sehingga SIM fisik tetap online selama Anda bekerja dengan eSIM.

`lpac` adalah dependensi **opsional** — tab eSIM hanya muncul jika `lpac` terpasang dan ada eUICC; bagian lain aplikasi tetap berfungsi tanpanya.

## Router saku MediaTek: 5gmodem-mtk-at

Router saku Android berbasis MediaTek MT6735 (TianJie CPE903/905/906, KuWfi CPF9xx dan sejenisnya) tidak menyediakan RSRQ, SINR, info sel, dan kontrol band di antarmuka webnya. Aplikasi mengambilnya lewat ADB dan soket `rild-atci`, untuk itu perlu paket opsional kecil `5gmodem-mtk-at`. Klien di dalamnya berjalan di router saku, bukan di router Anda, sehingga satu paket `noarch` cocok untuk semua platform. Tanpa paket ini hanya RSRP, baterai, suhu, dan mode jaringan yang tampil.

```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/latest/download/5gmodem-mtk-at.apk > /tmp/mtk-at.apk
apk add /tmp/mtk-at.apk --allow-untrusted
```

24.10.x: `5gmodem-mtk-at.ipk` + `opkg install`.

## Build dari sumber

Paket ini dibangun dengan OpenWrt SDK standar. Sebagai feed:

```sh
# in your OpenWrt — "modem" here is just a feed name you pick
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI (`.github/workflows/build.yml`) membangun `.ipk`/`.apk` pada setiap tag dan melampirkannya ke rilis; CI juga bisa dijalankan manual dari tab Actions.

## Izin akses

Aplikasi berjalan sebagai **root** dan membuka kemampuannya melalui grup ACL
`luci-app-5gmodem` (`/usr/share/rpcd/acl.d/`). Grup itu **setara root**,
dan hal ini penting sebelum memberikannya kepada siapa pun selain administrator penuh:

- grup ini mengizinkan pengiriman **perintah AT apa pun** ke modem (melalui `atcmd.sh` - konsol
  AT memang membutuhkannya). Binary `sms_tool` sendiri sudah tidak ada lagi di
  ACL: melaluinya browser juga bisa menjalankan `send`, `delete all` dan menjangkau
  `/dev/*` lain, tanpa ada yang bisa memeriksa argumennya;
- ~~menulis `/etc/crontabs/root`~~ — **dihapus**. Hak itu hanya ada untuk
  jadwal restart notifikasi SMS; sekarang `smscron.sh` yang mengurusnya, hanya menyentuh
  barisnya sendiri dan memvalidasi intervalnya. Tugas cron lain tidak dibaca maupun diubah. Administrator penuh tetap memiliki
  kemampuan itu - melalui halaman "Scheduled Tasks" milik LuCI sendiri, yang memang tempatnya;
- membaca konfigurasi `5gmodem` akan memperlihatkan kata sandi SMTP untuk penerusan SMS jika
  diatur (OpenWrt menyimpan kata sandi di `/etc/config` dalam teks biasa, sama
  seperti menyimpan kunci Wi-Fi).

Jangan berikan grup ini kepada peran terbatas seperti "operator yang hanya boleh
melihat modem". Tidak ada jalan keluarnya: penyaringan argumen berada di
halaman, dan halaman berjalan di browser pengguna. Peran seperti itu membutuhkan
set panggilan sempit sendiri, bukan subset dari grup ini.

## Kredit

Berdasarkan karya [Rafał Wabik (IceG)](https://github.com/4IceG) dan [Cezary Jackiewicz](https://github.com/obsy). Perhitungan bar sinyal diadaptasi dari [koshev-msk](https://github.com/koshev-msk). Dilisensikan di bawah **GPL-3.0**.
