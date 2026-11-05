# 发布新版本

每次功能更新都同步提交源码、版本号和更新说明，然后创建相同版本的 Git 标签与 GitHub Release。

1. 在 `HarmonyBridge.app/Contents/Info.plist` 更新 `CFBundleShortVersionString`，并递增 `CFBundleVersion`。
2. 在 `Phone/AppScope/app.json5` 更新 `versionName`，并递增整数 `versionCode`；同步更新 `Phone/oh-package.json5` 和 `Phone/entry/oh-package.json5` 的版本。
3. 在 `CHANGELOG.md` 顶部增加该版本的日期、功能变化、修复和仍存在的限制；如安装方式有变化，同时更新 `README.md`。
4. 运行 `zsh build.sh`。用 DevEco Studio 和自己的签名材料构建手机端，在真机上验证 USB、Wi‑Fi、控制及文件传输。确认仓库中没有签名材料、会话凭据、个人文件或生成的 HAP。
5. 提交、推送并创建 `vX.Y.Z` 标签；以该标签创建 GitHub Release，发布说明与 `CHANGELOG.md` 对应。Mac 安装包可作为附件。设备限定的调试 HAP 含注册设备 ID；只有在用户明确同意公开该信息时才作为附件，并标明仅适用于已注册设备。没有通用手机包时，继续提供源码自签名安装步骤。

版本采用语义化版本：不兼容变化升主版本，新功能升次版本，修复升修订版本。无法完成的验证应在该次发布说明中明确写出。
