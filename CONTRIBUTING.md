# 参与贡献

欢迎通过 Issue 反馈问题，或提交范围清晰的 Pull Request。较大的功能改动请先说明使用场景和预期行为。

## 本地开发

需要 macOS 15.6 或以上、Xcode 和 Swift 6 工具链。目前验证环境为 Xcode 26.3 / Swift 6.2.4；建议使用同版本工具链。项目通过 Swift Package Manager 固定依赖 **Sparkle 2.10.1**，该更新框架随 App 分发。首次依赖解析需联网，`Package.resolved` 应随依赖变更一同提交。

在仓库根目录执行：

```sh
swift test
SIGN_IDENTITY=- bash scripts/build-app.sh
```

第二条命令构建本机架构的 App，并使用临时 ad-hoc 签名，无需开发者证书。产物位于 `dist/TypeCount.app`；运行中的统计需要按 App 提示由你授予系统权限。临时签名在重新构建后可能需要重新授权，详见 README。

如需检查 Apple Silicon 与 Intel 通用构建：

```sh
UNIVERSAL=1 SIGN_IDENTITY=- bash scripts/build-app.sh
```

CI 在 `macos-15` 上使用 Xcode 26.3，执行测试及本机架构的 ad-hoc 构建，不发布安装包，也不使用签名证书。更新工具链时请核对 [GitHub 官方 runner 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)。

## 更新与发布

发布步骤为：递增 `Resources/Info.plist` 的展示版本与构建号，执行测试，构建通用 App，再构建 DMG 和签名更新资产。

```sh
UNIVERSAL=1 ./scripts/build-app.sh
./scripts/build-dmg.sh
./scripts/build-update.sh
```

更新产物位于 `dist/updates/<版本>/`。先把 DMG、校验文件、更新 ZIP、`appcast.xml` 及脚本生成的其余签名资产全部上传至同一个 draft Release，再发布为最新正式版。ZIP 地址绑定具体 tag，feed 通过固定的 GitHub `releases/latest/download/appcast.xml` 地址发现。

更新归档与 feed 使用 Ed25519 签名。公钥随 `Info.plist` 分发，私钥仅留在发布者本机钥匙串账户 `com.jonah.TypeCount.sparkle`，**不导出、不提交仓库，也不放进 CI 或发布附件**。Apple 代码签名身份与更新签名密钥分别管理；本地开发签名不等于 Developer ID 签名或 Apple 公证。

每个新的 Latest Release 都必须携带 feed，遗漏会使应用内更新检查返回 404。完整流程、首次升级路径和发布前验收见 [更新与发布](docs/UPDATES.md)。

## 修改约定

- 保持菜单栏与后台采集轻量；避免空闲轮询、大范围 AX 树遍历和每个输入事件写盘。
- 菜单栏固定一个图标位，左下保留原图标、右上显示小字角标；支持字数、按键、鼠标点击及仅图标，完整数值放入悬停提示。
- 只持久化聚合数值，不记录原文、按键顺序、剪贴板内容或鼠标坐标。用于差分的 AX 文本只短暂留在内存，失焦、暂停或撤销权限时清除。
- 区分按键次数和估算字符数。App 未提供可读文本时应明确显示限制，不能用按键次数冒充字符数。
- 更新检查仅访问 GitHub 发布源，不上传输入或统计数据，不加入遥测；保留自动检查与系统信息上报默认关闭、不自动下载的默认行为。自动检查由用户选择开启。
- 修复统计或权限行为时补充对应的可重复测试，并在 PR 中写明修改原因、验证结果和已知限制。

## 反馈问题

请提供字迹版本、macOS 版本、芯片类型、相关 App 及输入法版本，以及最短复现步骤。使用 `hello`、`你好` 等虚构内容复现即可。

不要上传真实输入、聊天记录、个人统计文件、CSV、账号信息、证书或私钥。截图和日志请先脱敏；AX 诊断只需属性名、类型、长度和错误码，不需要属性中的文本。说明预期值与实际计数，通常比完整录屏更便于定位。

提交贡献即表示你同意将贡献按仓库的 [MIT License](LICENSE) 发布。
