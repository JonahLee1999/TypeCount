[← 返回 README](../README.md) · [实现与统计说明](TECHNICAL-NOTES.md)

# 更新与发布

字迹使用 **Sparkle 2.10.1** 提供应用内更新。统计在本机完成，更新通过 GitHub Releases 的 HTTPS 下载地址分发。

## 用户如何更新

在应用中选择「检查更新…」，查看可用版本后确认下载与安装。默认行为如下：

| 项目 | 默认行为 |
| :--- | :--- |
| 手动检查 | 用户点击后请求 GitHub 上的 feed |
| 自动检查 | 关闭；用户可主动开启 |
| 系统信息上报 | 关闭，不包含遥测 |
| 自动下载 | 关闭，下载与安装由用户确认 |
| 安装 | 替换 App，正常退出并重新启动字迹 |
| 统计与设置 | 保留在 App 包外，不随应用替换而清除 |

没有更新器的旧版本无法自行发现这条更新链路，需要先从 [Releases](https://github.com/JonahLee1999/TypeCount/releases/latest) **手动安装一次含更新器的版本**，之后可以在 App 内更新。

当前发布包仍使用本地开发签名，尚未完成 Developer ID 签名与 Apple 公证。应用内更新不能保证免除 Gatekeeper 确认或辅助功能重新授权；统计文件与设置的保留不等于系统权限一定延续。

## 分发与验证

固定更新源：

```text
https://github.com/JonahLee1999/TypeCount/releases/latest/download/appcast.xml
```

此地址从 GitHub 的最新正式 Release 获取 feed。feed 中的 ZIP 下载地址绑定具体的 `v<版本>` tag：

```text
https://github.com/JonahLee1999/TypeCount/releases/download/v<版本>/TypeCount-<版本>-macOS-universal.zip
```

该归档地址不能改为会随发布变化的 `latest/download` ZIP 地址。

更新归档与 feed 均使用 **Ed25519** 签名。`Info.plist` 开启 `SURequireSignedFeed` 与 `SUVerifyUpdateBeforeExtraction`，并通过 `SUPublicEDKey` 提供公开验证密钥。公钥可以随源码和应用分发；对应私钥保存在发布者本机钥匙串，账户名为：

```text
com.jonah.TypeCount.sparkle
```

私钥不导出、不提交、不打包进 App，也不上传到 GitHub Release 或 CI。保持公钥与发布签名密钥一致；不要为每个版本重新生成一套密钥。签名后的 ZIP、feed 及相关签名资产按构建结果原样发布，修改内容后须重新生成签名。

Ed25519 用于更新内容的来源与完整性校验；Apple 代码签名与公证仍按独立的系统分发要求处理。

## 发布流程

### 1. 递增版本

更新 `Resources/Info.plist` 的 `CFBundleShortVersionString` 和 `CFBundleVersion`，并更新 `Resources/ReleaseNotes.html` 的版本说明。展示版本与构建号都应向前递增，且 Release tag、构建产物和 feed 中的版本必须对应。版本说明会嵌入签名 feed，供应用内更新窗口展示。

先完成测试和实际输入验收，使用发布时的稳定代码签名身份。更新签名私钥仅通过本机钥匙串使用。

### 2. 构建通用 App、DMG 与更新资产

```sh
swift test
UNIVERSAL=1 ./scripts/build-app.sh
./scripts/build-dmg.sh
./scripts/build-update.sh
```

`build-app.sh` 首次通过 SwiftPM 获取固定版本的 Sparkle 及其二进制框架，需要联网；框架与许可证随 App 打包。`build-dmg.sh` 的 Python 工具只保存在开发机 `.build/dmg-tools`，首次安装也需要联网。

`build-update.sh` 使用已构建的通用 App，生成更新归档、签名 feed 及相关发布资产，输出到：

```text
dist/updates/<版本>/
├── TypeCount-<版本>-macOS-universal.zip
├── appcast.xml
└── SHA256SUMS.txt
```

`appcast.xml` 包含 feed 签名和归档的 Ed25519 签名信息；`SHA256SUMS.txt` 提供 ZIP 与 feed 的校验和。脚本会核对构建号、展示版本、固定下载地址、归档长度，并使用 Sparkle 工具验证两类签名后再输出。

检查展示版本、构建号、最低 macOS 版本、公钥和归档下载 URL。ZIP URL 应包含这次发布的 `v<版本>` tag。不要在签名完成后手动修改 feed 或更新 ZIP。

### 3. 先上传 draft 的全部资产

在 GitHub 创建与构建产物对应的 **draft Release**，上传：

- 本次生成的通用 DMG 与 SHA-256 校验文件。
- `dist/updates/<版本>/` 中的更新 ZIP、已签名的 `appcast.xml` 与 `SHA256SUMS.txt`。

保持脚本生成的文件名。全部资产上传齐全后再发布，避免新客户端先读到 feed，却找不到对应的更新 ZIP 或签名。

### 4. 发布为最新正式版并检查

将 draft 发布为最新正式 Release，确认上述固定 feed 地址返回成功，并且内容指向本次 tag 下的更新归档。每个未来的 **Latest Release 都必须附带 `appcast.xml` 和对应签名资产**：遗漏 feed 会让固定地址返回 **404**，旧 Release 中的 feed 不能替代新 Latest 的缺失资产。

从一个已含更新器的较旧版本中选择「检查更新…」，确认可发现新版本；按提示完成下载、签名验证、安装和重新启动。随后检查统计、设置以及系统授权状态。首次加入更新器的版本，需要通过手动安装路径验收。

## 隐私与联网范围

统计不上传原文、按键顺序、应用使用统计或鼠标位置。仅在用户手动检查更新、主动开启自动检查，以及确认下载更新时，通过 HTTPS 访问 GitHub 与其发布资产服务；没有遥测，系统信息上报默认关闭。

实现与配置参考：[Sparkle 文档](https://sparkle-project.org/documentation/)、[Sparkle 更新签名说明](https://sparkle-project.org/documentation/#3-segue-for-security-concerns)。
