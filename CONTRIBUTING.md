# 参与贡献

欢迎通过 Issue 反馈问题，或提交范围清晰的 Pull Request。较大的功能改动请先说明使用场景和预期行为。

## 本地开发

需要 macOS 15.6 或以上、Xcode 和 Swift 6 工具链。目前验证环境为 Xcode 26.3 / Swift 6.2.4；建议使用同版本工具链。项目使用 Swift Package Manager，无第三方依赖。

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

## 修改约定

- 保持菜单栏与后台采集轻量；避免空闲轮询、大范围 AX 树遍历和每个输入事件写盘。
- 只持久化聚合数值，不记录原文、按键顺序、剪贴板内容或鼠标坐标。用于差分的 AX 文本只短暂留在内存，失焦、暂停或撤销权限时清除。
- 区分按键次数和估算字符数。App 未提供可读文本时应明确显示限制，不能用按键次数冒充字符数。
- 修复统计或权限行为时补充对应的可重复测试，并在 PR 中写明修改原因、验证结果和已知限制。

## 反馈问题

请提供字迹版本、macOS 版本、芯片类型、相关 App 及输入法版本，以及最短复现步骤。使用 `hello`、`你好` 等虚构内容复现即可。

不要上传真实输入、聊天记录、个人统计文件、CSV、账号信息、证书或私钥。截图和日志请先脱敏；AX 诊断只需属性名、类型、长度和错误码，不需要属性中的文本。说明预期值与实际计数，通常比完整录屏更便于定位。

提交贡献即表示你同意将贡献按仓库的 [MIT License](LICENSE) 发布。
