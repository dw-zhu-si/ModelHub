# 参与贡献

感谢参与 ModelHub。提交变更前请先创建 Issue 说明问题、预期行为和影响范围。

## 开发环境

- macOS 14 或更高版本
- Xcode 16 或更高版本
- Swift 6

```bash
swift test --scratch-path .build/tests
./scripts/package_app.sh release
```

提交代码时请同时提供相关测试，并确认不会把 API Key、访问令牌、签名证书、
provisioning profile、提示词、模型响应或本机配置加入仓库。新增界面文案需同步
更新 `packaging/Localization/Localizable.xcstrings` 的 11 种语言。

贡献默认按仓库根目录的 Apache License 2.0 提交。
