# 📱 手机端 Bridge：侧载安装

**Bridge 尚未上架华为应用市场。目前不能从商店搜索安装，手机端只能通过侧载安装。** 本项目当前是面向开发者模式的个人测试版，需要一台可开启 USB 调试的 HarmonyOS 手机和 DevEco Studio。

## 下载现成 HAP：仅限已注册的调试设备

[下载 `HarmonyBridge-phone-v1.0.0-debug-device-bound.hap`](https://github.com/chinachenkeke-source/harmony-bridge/releases/download/v1.0.0/HarmonyBridge-phone-v1.0.0-debug-device-bound.hap)。这个公开附件是**调试签名包**，签名 Profile 内含原测试手机的设备 ID；只有 Profile 已注册的设备才能安装，不是通用安装包。手机需要开启开发者模式和 USB 调试，然后通过 HDC 侧载：

```sh
hdc list targets
hdc app install -r /path/to/HarmonyBridge-phone-v1.0.0-debug-device-bound.hap
```

如果安装提示签名或设备不匹配，请按下节为自己的手机重新签名构建。

## 为自己的手机构建并安装

1. 在手机上开启开发者模式与 USB 调试，用数据线连接 Mac，并允许这台电脑调试。
2. 在 DevEco Studio 中打开仓库的 `Phone/` 工程，登录自己的华为开发者账号。
3. 在项目签名设置中启用 HarmonyOS 自动调试签名，让当前手机加入该调试 Profile。构建并通过 DevEco Studio 的 **Run** 安装到手机。
4. 手机桌面出现 **Bridge** 后，打开它并点击“开启屏幕共享”；按系统提示允许共享整个屏幕。Mac 端随后自动接入。

`hdc` 可在 DevEco Studio 安装目录的 SDK toolchains 中找到。安装包必须已签名，且包内的调试 Profile 必须包含目标手机的设备 ID；否则安装可能失败。当前版本不能把一台设备生成的调试 HAP 当成所有手机通用的安装包。[华为自动签名说明](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/ide-signing-auto)也说明了调试设备与签名的关系。

## 安装后仍需授权

侧载只完成手机 App 的安装。首次 USB 连接还需在手机上允许 USB 调试；每次系统结束屏幕共享后，也需要在手机端重新点击“开启屏幕共享”并允许系统提示。Wi‑Fi 投屏同样需要先完成无线调试连接，详见 [README](../README.md#用-wi-fi-投屏)。
