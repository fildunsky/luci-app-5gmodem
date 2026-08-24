# luci-app-5gmodem

*[English](README.md) · [Русская версия](README.ru.md)*

OpenWrt 上的 4G/5G 调制解调器 LuCI 管理应用。它把 [`3ginfo-lite`](https://github.com/4IceG/luci-app-3ginfo-lite)、[`sms-tool-js`](https://github.com/4IceG/luci-app-sms-tool-js) 以及 `modemband` 的部分功能合并成一个应用。

<img width="1960" height="1474" alt="截图" src="https://github.com/user-attachments/assets/1adb9ca6-8f38-445c-8cb8-2a0f6b8005c9" />

## 安装
从 [Releases](../../releases) 页面获取 `.apk`（OpenWrt 25.12.x）或 `.ipk`（24.10.x）链接，然后执行：

### .apk（OpenWrt 25.12.x）
```sh
apk update && apk add curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.29/luci-app-5gmodem-2.4.29-r1.apk > /tmp/luci-app-5gmodem.apk
apk add /tmp/luci-app-5gmodem.apk --allow-untrusted
```

**中文界面**：再安装本应用的简体中文语言包，并确保 LuCI 本身的中文包已安装：
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.29/luci-i18n-5gmodem-zh-cn.apk > /tmp/luci-i18n-5gmodem-zh-cn.apk
apk add /tmp/luci-i18n-5gmodem-zh-cn.apk --allow-untrusted
apk add luci-i18n-base-zh-cn
```
然后在 LuCI 中选择语言：系统 → 系统 → 语言和界面 → 简体中文。

如需 **eSIM**（可选），请同时安装我们打过补丁的 `lpac` —— 在 [lpac-build 发布页](https://github.com/fildunsky/lpac-build/releases/latest) 中**选择适合你平台的构建**。以 MediaTek Filogic（如 WH3000）为例：
```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-mediatek-filogic.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

同一份 Filogic 构建也镜像在本仓库中，如果不想访问 lpac-build 发布页，可以把 URL 换成
`https://github.com/fildunsky/luci-app-5gmodem/raw/master/dist/lpac-25.12.5-mediatek-filogic.apk`。
其他平台仅在发布页提供。

### .ipk（OpenWrt 24.10.x）
```sh
opkg update && opkg install curl
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.29/luci-app-5gmodem_2.4.29-r1_all.ipk > /tmp/luci-app-5gmodem.ipk
opkg install /tmp/luci-app-5gmodem.ipk
```

**中文界面**：再安装本应用的简体中文语言包，并确保 LuCI 本身的中文包已安装：
```sh
curl -L https://github.com/fildunsky/luci-app-5gmodem/releases/download/v2.4.29/luci-i18n-5gmodem-zh-cn.ipk > /tmp/luci-i18n-5gmodem-zh-cn.ipk
opkg install /tmp/luci-i18n-5gmodem-zh-cn.ipk
opkg install luci-i18n-base-zh-cn
```
然后在 LuCI 中选择语言：系统 → 系统 → 语言和界面 → 简体中文。

标准包会拉取完整依赖（`sms-tool`、`comgt`、`qmi-utils`、`modemmanager`、QMI/MBIM 协议、USB 串口内核模块）——在任何旧版本之上升级都不会丢失组件。

针对小容量闪存设备（8 MB 的 MT7628 主板，完整依赖根本装不下），发布页另有 **`-lite.apk`**：它只依赖 `sms-tool`。信号指标、短信、USSD、频段管理和 AT 控制台都可用；缺少的是 QMI/MBIM 接口协议和通过 `mmcli` 读取的手机号码。不要在运行 QMI 或 MBIM 调制解调器的路由器上用 lite 版覆盖完整版——包管理器会把这些协议包当作孤儿包删除。

## 功能

- **一键创建调制解调器接口**（调制解调器设置）——自动配置 `network` 接口。
- **双调制解调器模式与上行切换**
- **双 SIM 与 eSIM 切换**——已在 Fibocom FM350-GL（AT）和 Foxconn T99W175 / Thales MV31-W（MBIM）上验证。请从 [lpac-build 发布页](https://github.com/fildunsky/lpac-build/releases/latest) 安装适合你平台的补丁版 `lpac`（见下方 [eSIM / lpac](#esim--lpac) 一节）！
- **网络页面**——详细信号强度、运营商、含载波聚合的网络制式（如 `LTE-A | B1 + B40 / B7 / B3`）、接口 IPv4/IPv6、连接统计和调制解调器温度（若模块上报）。
- **频段与制式管理**——选择网络制式（自动 / 2G / 3G / 4G / 4G+5G / 5G），单独开关 LTE/NR 频段。
- **TTL 修正**——在调制解调器接口上强制设置进出方向的 IPv4 TTL 和 IPv6 hop-limit（通过 `fw4` 的 `nftables` include 实现）。
- **基站地图**——Cell ID 是一个按钮，点击在 [4cells.ru](https://4cells.ru) 上打开对应基站。
- **重启调制解调器**——一键软重启射频 `AT+CFUN=4,1` 与整机复位 `AT+CFUN=1,1`。
- **短信收件箱 / 发送**、**USSD** 和 **AT** 标签页，每页带可折叠的独立设置面板。支持来信邮件转发和 LED/通知。
- **Telegram 机器人**——所有调制解调器的来信短信都会推送到聊天，聊天中可用 `/sms`、`/status`、`/modem` 命令。
- **邻区列表**——载波聚合下方的表格：服务小区与邻区的 PCI、频点和电平（Fibocom FM350-GL、QMI 调制解调器）。
- **APN 数据库更新按钮**——无需重装应用即可刷新全球运营商数据库（GNOME MBPI + AOSP）。
- **端口自动检测**——自动识别 AT 端口和网络接口；也可手动指定。
- 支持**没有 AT 端口的 USB 上网卡**（华为 HiLink 及同类）——见下文。
- **智能家居遥测**——`/tmp/5gmodem_tele.json` 中的扁平 JSON（信号、运营商、制式、载波聚合、速率、未读短信数），可选 MQTT 发布并支持 Home Assistant 自动发现；见 [docs/telemetry.md](docs/telemetry.md)。
- **`5gtop`**——终端仪表盘，SSH 下无浏览器时使用，数据与网页一致。


## 已测试的调制解调器：
（相对上游 3ginfo 和 modemband 增加了新功能）
- Fibocom FM350GL
- Fibocom L850
- Compal RXM-G1
- Telit LM960A18
- SIMCOM SIM7100E
- SIMCOM SIM7600E-H
- Quectel EC21-E
- MeigLink SLM770A-R
- Huawei E3372（HiLink）
- 更多型号未逐一测试，但上游分支支持的调制解调器均应可用。

<img width="1960" height="1474" alt="截图" src="https://github.com/user-attachments/assets/0bd100f7-780f-47e3-98a4-9729bf29ee8b" />

### 没有 AT 端口的 USB 上网卡（HiLink）

华为 E3372 这类上网卡自带 IP 协议栈：路由器只能看到一张网卡，其余功能都在上网卡自己的网页界面里。它完全没有 AT 端口，常规轮询无从谈起。

本应用照样支持它们：

- 通过 USB 描述符识别（尚未绑定驱动的普通 U 盘不会被误认），并创建 DHCP 接口；
- 信号指标、短信和运营商名称通过上网卡的 HTTP API 读取；
- 如果上网卡支持串口模式（华为称为*调试模式*），应用会自动切换过去，之后像普通调制解调器一样使用——TAC、频段、EARFCN、USSD 和 AT 控制台由此而来。该模式在上网卡重启后会丢失，应用会在每次出现时重新应用。若不希望自动切换，调制解调器设置中有开关。

这类上网卡的频段和网络制式通过其 API 修改，而不是 `AT^SYSCFGEX`：走 AT 路径会导致上网卡重置 USB 组合并退出调试模式。

## 按钮
<img width="1960" height="1474" alt="截图" src="https://github.com/user-attachments/assets/60a6dce9-6723-45ae-99f0-2c0ae4b7e725" />

## 5gtop

终端仪表盘，适合 SSH 而非浏览器的场景。数据与网页相同、后端相同——不会额外轮询调制解调器。

```sh
5gtop        # 英文
5gtop ru     # 俄文
```
<img width="1656" height="1226" alt="截图" src="https://github.com/user-attachments/assets/9fa44f0c-7eb9-4ca3-a2a3-9de962e94ee7" />

<img width="1658" height="640" alt="截图" src="https://github.com/user-attachments/assets/f7cb2f47-384c-4767-accd-c87ad61e1dc1" />

标签页：**网络**、**小区信息**、**调制解调器**、**短信**、**USSD**、**AT 控制台**，以及存在 eUICC 时的 **eSIM**。按键单击即生效（无需回车）：每个标签名中高亮的字母切换到该页，`Tab` 在双调制解调器间切换，`t` 运行测速，`r` 刷新，`q` 退出。布局跟随终端宽度，小屏自动降级为窄模式。


## eSIM / lpac

eSIM 标签页（下载 / 启用 / 停用 / 删除配置文件、通知）需要 [`lpac`](https://github.com/estkme-group/lpac)。OpenWrt 25.12 官方源的 `lpac`（2.3.0）stdio 后端有缺陷，所以我们提供**补丁版构建** —— [`fildunsky/lpac-build`](https://github.com/fildunsky/lpac-build)：包含原生 AT 驱动健壮性补丁、bare-CCHO 支持和针对 OpenWrt 的加载器修复。它是通用构建，携带全部 APDU 后端（AT、QMI、uqmi、MBIM），应用会按调制解调器自动选择传输：**Fibocom FM350-GL** 走 AT，**Foxconn T99W175 / Thales MV31-W** 等高通 SDX55 模块走 MBIM/QMI。

`.apk` 文件命名为 `lpac-<openwrt>-<target>-<subtarget>.apk`；24.10.x 构建为 `.ipk`。旧版本曾使用 `lpac-fm350-*` 前缀。

从[最新 lpac-build 发布页](https://github.com/fildunsky/lpac-build/releases/latest)下载**你的平台**对应的 `.apk`：

| 文件 | 架构 | 典型设备 |
|------|------|----------|
| `lpac-25.12.5-mediatek-filogic.apk` | aarch64_cortex-a53 | WH3000 及带 USB 的新款 WiFi6 路由器 |
| `lpac-25.12.5-rockchip-armv8.apk` | aarch64 | NanoPi R2S/R4S/R5S |
| `lpac-25.12.5-bcm27xx-bcm2711.apk` | aarch64_cortex-a72 | Raspberry Pi 4 |
| `lpac-25.12.5-armsr-armv8.apk` | aarch64_generic | 虚拟机 / 容器 / 通用 ARM64 |
| `lpac-25.12.5-armsr-armv7.apk` | arm | 通用 ARM32 |
| `lpac-25.12.5-ramips-mt7621.apk` | mipsel_24kc | 小米 / GL.iNet / Netgear |
| `lpac-25.12.5-ath79-generic.apk` | mips_24kc | 带 USB 的老款 MIPS 路由器 |
| `lpac-25.12.5-x86-64.apk` | x86_64 | 迷你主机 / 虚拟机路由器 |

```sh
curl -L https://github.com/fildunsky/lpac-build/releases/latest/download/lpac-25.12.5-<your-platform>.apk > /tmp/lpac.apk
apk add /tmp/lpac.apk --allow-untrusted
```

### 已测试的 eSIM 组合

| 调制解调器 | APDU 传输 | 已验证内容 |
|-----------|-----------|-----------|
| Fibocom FM350-GL | `at`（原生 AT 驱动） | 完整流程——读取 eUICC、下载 / 启用 / 停用 / 删除配置文件、通知 |
| Foxconn T99W175 / Thales MV31-W | `mbim`（经 mbim-proxy） | eUICC 读取：EID、芯片信息、配置文件列表、剩余空间。配置文件下载尚未验证 |

传输方式根据接口协议自动选择，通常无需手动设置。MBIM 路径下无论当前活动的是哪个 SIM 槽都能访问 eUICC，因此操作 eSIM 时物理 SIM 保持在线。

`lpac` 是**可选**依赖——eSIM 标签页仅在安装了 lpac 且存在 eUICC 时出现；应用的其余部分无需它即可工作。

## 从源码构建

使用标准 OpenWrt SDK 构建。作为 feed 添加：

```sh
# 在你的 OpenWrt 中——"modem" 只是自定义的 feed 名称
echo "src-git modem https://github.com/fildunsky/luci-app-5gmodem.git" >> feeds.conf.default
./scripts/feeds update modem
./scripts/feeds install luci-app-5gmodem
make package/luci-app-5gmodem/compile V=s
```

CI（`.github/workflows/build.yml`）在每次打标签时构建 `.ipk`/`.apk` 并附加到发布页；也可在 Actions 页手动触发。

## 权限

应用以 **root** 身份运行，能力通过 ACL 组 `luci-app-5gmodem`（`/usr/share/rpcd/acl.d/`）暴露。该组**等同于 root 权限**，在授予完整管理员以外的任何人之前请注意：

- 它允许向调制解调器发送**任意 AT 命令**（经 `atcmd.sh` —— AT 控制台的设计需要）。`sms_tool` 二进制本身已不在 ACL 中：否则浏览器还能执行 `send`、`delete all` 并访问任意 `/dev/*`，且无法校验参数；
- ~~写入 `/etc/crontabs/root`~~ —— **已移除**。该权限当初只为短信通知的重启计划而存在；现在由 `smscron.sh` 自己管理，只触碰自己的行并校验间隔。其他 cron 任务既不读也不改。完整管理员仍可通过 LuCI 自带的「计划任务」页面获得该能力——那才是它该在的地方；
- 读取 `5gmodem` 配置会暴露短信转发的 SMTP 密码（若已设置）——OpenWrt 将密码以明文保存在 `/etc/config`，与 Wi-Fi 密钥的处理方式相同。

不要把该组授予「只允许查看调制解调器的操作员」之类的受限角色。没有变通办法：参数过滤在页面里，而页面运行在用户的浏览器中。这类角色需要一套独立的窄权限调用，而不是本组的子集。

## 致谢

基于 [Rafał Wabik (IceG)](https://github.com/4IceG) 和 [Cezary Jackiewicz](https://github.com/obsy) 的工作。信号强度算法改编自 [koshev-msk](https://github.com/koshev-msk)。许可证：**GPL-3.0**。
