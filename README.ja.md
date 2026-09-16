# luci-app-5gmodem

*[English](README.md) · [Русская версия](README.ru.md) · [简体中文](README.zh-CN.md)*

OpenWrt 上で 4G/5G モデムを扱うための LuCI アプリです。[`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite)、[`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js)、および `modemband` の一部を 1 つのアプリにまとめています。

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-39" src="https://github.com/user-attachments/assets/1adb9ca6-8f38-445c-8cb8-2a0f6b8005c9" />

## インストール
[Releases](../../releases) ページから `.apk`（OpenWrt 25.12.x）または `.ipk`（24.10.x）のリンクを取得し、次のコマンドを実行してください。

### .apk（OpenWrt 25.12.x）
```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.5.12/luci-app-5gmodem-2.5.12-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

**日本語表示について**: このアプリの日本語カタログはパッケージ本体に含まれているため、専用の言語パッケージを入れる必要はありません。LuCI 自体を日本語にするには、LuCI の言語パッケージを入れてください:
```sh
apk add luci-i18n-base-ja
```
そのあと LuCI で言語を選びます: システム → システム → 言語とスタイル → 日本語。

**eSIM** を使う場合（任意）は、パッチ済みの `lpac` も併せてインストールしてください。[lpac-build のリリース](https://github.com/fildunsky/lpac-build/releases/latest)から**お使いのプラットフォーム向けのビルドを選んでください**。MediaTek Filogic（WH3000 など）の例:
```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

同じ Filogic 向けビルドはこのリポジトリにもミラーされています。lpac-build のリリースページを開きたくない場合は、URL を
`https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk`
に置き換えてください。他のプラットフォーム向けはリリースページにのみあります。

### .ipk（OpenWrt 24.10.x）
```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.5.12/luci-app-5gmodem_2.5.12-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

日本語カタログは本体に同梱されています。LuCI 自体を日本語にする場合のみ、次を実行してください:
```sh
opkg install luci-i18n-base-ja
```

通常のパッケージは一式（`sms-tool`、`comgt`、`qmi-utils`、`modemmanager`、QMI/MBIM プロトコル、USB シリアル kmod）を導入します。以前のどのバージョンからでも上書き更新でき、何かが削除されることはありません。

フラッシュ容量の小さい機器（一式がまったく入らない 8 MB の MT7628 ボードなど）向けに、リリースには別途 **`-lite.apk`** があります。こちらが必要とするのは `sms-tool` だけです。メトリクス、SMS、USSD、バンド制御、AT コンソールはすべて動作しますが、QMI/MBIM のインターフェースプロトコルと `mmcli` 経由の電話番号取得は使えません。QMI または MBIM でモデムを動かしているルーターに、lite ビルドを上書き更新として使わないでください。パッケージマネージャーがそれらのパッケージを不要と判断して削除してしまいます。

> **自作のサービスからアプリのデータを取り出したい場合は?** スマートホーム、外部ディスプレイ、他人のダッシュボード、手書きのスクリプト — すべて 1 か所にまとまっています: [テレメトリ: メトリクスの取得方法](docs/telemetry.md)。フィールド形式、利用側との取り決め、そして 4 つの配信方法（ファイル、SSH、MQTT、HTTP）を説明しています。

## 機能

- **モデムインターフェースの簡単作成**ボタン（モデム設定）— モデム用の `network` インターフェースを自動で設定します。
- **デュアルモデム対応と上流回線の切り替え**
- **デュアル SIM と eSIM の切り替え** — Fibocom FM350-GL（AT）および Foxconn T99W175 / Thales MV31-W（MBIM）で動作を確認済みです。[lpac-build のリリース](https://github.com/fildunsky/lpac-build/releases/latest)から、お使いのプラットフォーム向けのパッチ済み `lpac` をインストールしてください（後述の [eSIM / lpac](#esim--lpac) を参照）。
- **ネットワーク** — 詳細な信号レベル、事業者、キャリアアグリゲーションを含む通信方式（例: `LTE-A | B1 + B40 / B7 / B3`）、インターフェースの IPv4/IPv6、接続統計、モデム温度（モデムが報告する場合）。
- **バンドとモードの管理** — ネットワークモード（自動 / 2G / 3G / 4G / 4G+5G / 5G）の選択と、LTE/NR の個別バンドの切り替え。
- **TTL 修正** — モデムインターフェース上で、受信/送信の IPv4 TTL と IPv6 ホップリミットを強制します（`fw4` への `nftables` インクルード経由）。
- **基地局マップ** — Cell ID がボタンになっており、[4cells.ru](https://4cells.ru) で基地局を開きます。
- **モデムの再起動** — ワンクリックで無線のソフト再起動 `AT+CFUN=4,1` とモデムのリセット `AT+CFUN=1,1` を実行します。
- **SMS 受信箱 / 送信**、**USSD**、**AT** の各タブ。それぞれにタブ単位の折りたたみ設定パネルがあります。受信 SMS のメール転送や LED・通知にも任意で対応します。
- **Telegram ボット** — すべてのモデムの受信 SMS がチャットに届き、チャットから `/sms`、`/status`、`/modem` が使えます。
- **隣接セル** — キャリアアグリゲーションの下に表示される表で、在圏セルとその隣接セルを PCI、チャネル、レベルとともに示します（Fibocom FM350-GL、QMI モデム）。
- **APN データベース更新ボタン** — アプリを再インストールせずに、世界の事業者データベース（GNOME MBPI + AOSP）を更新します。
- **ポートの自動検出** — AT ポートとネットワークインターフェースを自動で検出します。手動設定も可能です。
- **AT ポートを持たない USB スティック**（Huawei HiLink とその仲間）にも対応しています。詳しくは後述します。
- **スマートホーム向けテレメトリ** — `/tmp/5gmodem_tele.json` にフラットな JSON（信号、事業者、モード、アグリゲーション、速度、SMS 件数）を出力し、Home Assistant の自動検出に対応した MQTT 配信も任意で行えます。[docs/telemetry.md](docs/telemetry.md) を参照してください。
- **`5gtop`** — ブラウザではなく SSH で作業しているとき向けの、同じデータを表示するターミナルダッシュボード。

## 動作確認済み:
（3ginfo や modemband と比べて）新しい機能を追加したモデムです。
- Fibocom FM350-GL
- Fibocom L850（Intel XMM）
- Fibocom L860（Intel XMM）
- Compal RXM-G1（SG500M2-X）
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- Quectel EP06-E
- MeigLink SLM770A-R
- Foxconn T99W175 / Thales MV31-W（Snapdragon X55）
- Dell DW5821e / Foxconn T77W968（Snapdragon X20）
- HP lt4120 / Foxconn T77W595（Snapdragon X5）
- Sierra Wireless EM9190
- Huawei E3372（HiLink）
- 安価な Qualcomm MDM9600 / MDM9610 の Android スティック（PIXLINK、ALEKA UV310 とその仲間）。「モデムのみ」（QMI）モードを含みます。
- 他にも多数は未確認ですが、派生元のフォークが扱うモデムはすべて動作するはずです。

### 利用者からの報告で修正したもの
これらの機器は手元にありません。所有者の方がログと AT の出力を送ってくださり、修正を取り込みました。
- Telit FN990A28 — 「SIM in illegal state」による電源再投入ループのないクリーンな起動、バンドとネットワークモードの制御、キャリアアグリゲーション
- Quectel RM520N-GL — 型番とファームウェアの文字列
- Foxconn T99W373 — 5G NSA でのキャリアアグリゲーション
- NTmore NTLM-500（Skylink H1 ホームルーター由来の Altair ALT3800）— 信号、在圏セルと隣接セル、アンテナごとのレベル、温度、送信電力、パスロス、バンド選択
- Tri Cascade VOS 5G / SG500M2-X（Compal RXM-G1、USB 05c6:9091、QMI 上の ModemManager）— 型番で認識するようにし、このファームウェアが提供しない `uqmi` 経路ではなく `proto=modemmanager` でインターフェースを構築します。ADB インターフェースはシリアルドライバーから解放されます。既知の制限: 送信元指定の IPv6 デフォルトルート（`default from …`）は netifd の管理下に残り、上流回線の優先度機能では並べ替えられません

### ベンダー資料をもとに追加したもの
これらは実機も報告もまだありません。プロファイルはベンダーの AT コマンド資料に従い、資料に載っている応答例と照合しました。所有者の方からのログを歓迎します。
- Foxconn T99W373 / Thales MV32-W（Snapdragon X62）— LTE、5G NSA、5G SA、WCDMA の各バンド、セルロック、ネットワークモード、5G モード、セルとアンテナの全メトリクス
- その他の Altair ALT3100 / ALT3800 モデム（USB ベンダー 216f）: Yota 4G LTE（Swift WLTUBA-107）、NTmore JMR814 — スティックが AT ポートを見せる場合は常に NTLM-500 のプロファイルを使います

<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-02-52" src="https://github.com/user-attachments/assets/0bd100f7-780f-47e3-98a4-9729bf29ee8b" />

### AT ポートを持たない USB スティック（HiLink）

Huawei E3372 のようなスティックは IP スタックを自分で持っています。ルーターからは Ethernet カードにしか見えず、それ以外はすべてスティック自身の Web インターフェースの内側にあります。AT ポートはまったく存在しないため、通常のポーリングでは話し相手がいません。

それでもアプリはこうしたスティックを扱えます。

- モデムは USB ディスクリプタで認識され（単にまだドライバーが割り当てられていないだけのスティックを、誤ってこれと見なすことはありません）、DHCP インターフェースが与えられます。
- メトリクス、SMS、事業者名は、スティックの HTTP API 経由で読み取ります。
- スティックがシリアルポートを見せられる場合（Huawei はこれを*デバッグモード*と呼びます）、アプリが自動的にそちらへ切り替え、以後は他のモデムと同じように制御します。TAC、バンド、EARFCN、USSD、AT コンソールはここから得られます。このモードはモデムが再起動するたびに解除されるため、認識のたびに再適用されます。不要であれば、モデム設定にチェックボックスがあります。

こうしたスティックのバンドとネットワークモードは、`AT^SYSCFGEX` ではなく API 経由で変更します。AT 経由だとモデムが USB 構成を切り替えてしまい、デバッグモードから外れてしまうためです。

## ボタン
<img width="1960" height="1474" alt="Screenshot From 2026-07-30 07-03-18" src="https://github.com/user-attachments/assets/60a6dce9-6723-45ae-99f0-2c0ae4b7e725" />

## 5gtop

ブラウザではなく SSH で作業しているとき向けのターミナルダッシュボードです。Web ページと同じデータ、同じバックエンドを使うので、モデムへのポーリングが増えることはありません。

```sh
5gtop        # 英語
5gtop ru     # ロシア語
```
<img width="1656" height="1226" alt="Screenshot From 2026-07-19 23-36-52" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="Screenshot From 2026-07-19 23-37-41" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

タブは **Network**、**Cell info**、**Modem**、**SMS**、**USSD**、**AT console**、そして eUICC がある場合は **eSIM** です。キー操作は 1 打鍵で確定します（Enter は不要）。各タブ名の強調表示された文字でそのタブへ切り替わり、`Tab` はデュアルモデム構成でモデムを順に切り替え、`t` は速度テスト、`r` は再読み込み、`q` は終了です。レイアウトは端末の幅に合わせて変わり、画面が狭い場合は縦長の表示に切り替わります。

## eSIM / lpac

eSIM タブ（プロファイルのダウンロード / 有効化 / 無効化 / 削除、通知）には [`lpac`](https://github.com/estkme-group/lpac) が必要です。OpenWrt 25.12 公式の `lpac`（2.3.0）は stdio バックエンドが壊れているため、**パッチ済みのビルド** — [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build) — を提供しています。ネイティブ AT ドライバーの堅牢化 PR、素の CCHO 対応、OpenWrt 向けのローダー修正が入っています。これはすべての APDU バックエンド（AT、QMI、uqmi、MBIM）を含む汎用ビルドなので、アプリがモデムごとに適切な転送方式を選びます。**Fibocom FM350-GL** には AT を、**Foxconn T99W175 / Thales MV31-W** のような Qualcomm SDX55 モジュールには MBIM/QMI を使います。

`.apk` ファイルの名前は `lpac-<openwrt>-<target>-<subtarget>.apk` です。24.10.x 向けのビルドは `.ipk` です。古いリリースでは `lpac-fm350-*` という接頭辞を使っていました。

[lpac-build の最新リリース](https://github.com/fildunsky/lpac-build/releases/latest)から、**お使いのプラットフォーム**の `.apk` をダウンロードしてください。

| ファイル | アーキテクチャ | 代表的な機器 |
|------|------|-----------------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 や USB 付きの新しい WiFi6 ルーター |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | 仮想マシン / コンテナ / 一般的な ARM64 |
| `lpac-25.12.5-armsr-armv7.apk` | arm | 一般的な ARM32 |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | Xiaomi / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | USB 付きの古い MIPS ルーター |
| `lpac-25.12.5-x86-64.apk` | x86_64 | ミニ PC / 仮想マシンのルーター |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<your-platform>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### 動作確認済みのモデム

| モデム | APDU 転送方式 | 確認した内容 |
|-------|----------------|-------------------|
| Fibocom FM350-GL | `at`（ネイティブ AT ドライバー） | 全工程 — eUICC の読み取り、プロファイルのダウンロード / 有効化 / 無効化 / 削除、通知 |
| Foxconn T99W175 / Thales MV31-W | `mbim`（mbim-proxy 経由） | eUICC の読み取り: EID、チップ情報、プロファイル一覧、空き容量。プロファイルのダウンロードは未確認 |

転送方式はインターフェースのプロトコルから自動的に選ばれるため、通常は手で設定する必要はありません。MBIM 経路では、どの SIM スロットが有効かにかかわらず eUICC にアクセスできるので、eSIM を操作している間も物理 SIM は接続を維持したままです。

`lpac` は**任意**の依存パッケージです。eSIM タブは `lpac` がインストールされ、かつ eUICC が存在する場合にのみ表示されます。それ以外の機能は `lpac` なしで動作します。

## ソースからのビルド

このパッケージは標準の OpenWrt SDK でビルドできます。フィードとして使う場合:

```sh
# OpenWrt のソースツリー内で - ここでの "modem" は任意に決めたフィード名です
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI（`.github/workflows/build.yml`）はタグが付くたびに `.ipk`/`.apk` をビルドしてリリースに添付します。Actions タブから手動で起動することもできます。

## 権限

このアプリは **root** として動作し、その機能を ACL グループ `luci-app-5gmodem`（`/usr/share/rpcd/acl.d/`）を通じて公開します。このグループは **root 相当**であり、完全な管理者以外の誰かに与える前に、その点を理解しておく必要があります。

- モデムに**任意の AT コマンド**を送れます（`atcmd.sh` 経由 — AT コンソールには設計上それが必要です）。`sms_tool` のバイナリ自体はもう ACL に含まれていません。これを通すと、ブラウザから `send` や `delete all` を実行したり、他の `/dev/*` に触れたりできてしまい、引数を検査する術がなかったためです。
- ~~`/etc/crontabs/root` への書き込み~~ — **削除しました**。この権限は SMS 通知の再起動スケジュールのためだけに存在していました。現在は `smscron.sh` がその役割を担い、自分の行だけに触れ、間隔の値を検証します。他の cron ジョブは読み取りも変更もしません。完全な管理者であれば、この操作は引き続き LuCI 本体の「スケジュールされたタスク」ページから行えます。本来そこにあるべきものです。
- `5gmodem` の設定を読み取ると、SMS 転送用の SMTP パスワードが設定されている場合はそれが見えてしまいます（OpenWrt は Wi-Fi のキーと同様に、パスワードを `/etc/config` に平文で保存します）。

「モデムを見るだけの担当者」のような、権限を絞った役割にこのグループを与えないでください。回避策はありません。引数のフィルタリングはページ側にあり、そのページは利用者のブラウザで動くからです。そうした役割には、このグループの一部ではなく、専用の絞り込まれた呼び出し一式が必要になります。

## クレジット

[Rafał Wabik (IceG)](https://github.com/4IceG) と [Cezary Jackiewicz](https://github.com/obsy) の成果をもとにしています。信号バーの計算は [koshev-msk](https://github.com/koshev-msk) を参考にしました。ライセンスは **GPL-3.0** です。
