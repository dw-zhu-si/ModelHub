# ModelHub 代码签名政策

## 当前状态

Windows 可信签名处于 **SignPath Foundation 申请已提交、人工审核中** 状态。GitHub App 已收紧为仅访问 `dw-zhu-si/ModelHub`，并保留 SignPath 固定要求的 Actions、代码与元数据读取以及 Administration 写入权限。在 Foundation 批准、GitHub 来源验证接通、签名流水线实际通过以及 x64/ARM64 真机门禁完成之前，ModelHub 不会把任何 Windows 安装包描述为已签名或可公开发布。

计划采用以下开源签名声明：

> Free code signing provided by SignPath.io, certificate by SignPath Foundation.

使用该证书后，Windows 显示的发布者将是 `SignPath Foundation`，不是 ModelHub、野路子工作室或维护者个人姓名。

## 团队角色

- 提交者、审阅者：GitHub 仓库 `dw-zhu-si/ModelHub` 的维护者 `dw-zhu-si`；
- 签名批准者：GitHub 仓库所有者 `dw-zhu-si`；
- 所有能够修改源码、工作流或批准签名的账号必须启用多因素认证。

## 签名范围

只允许签署由 GitHub 托管 runner 从本仓库源码与构建脚本生成的以下 ModelHub 1.10.0 build 67 Windows 文件：

- `win-x64` 与 `win-arm64` 发布目录中的 `ModelHub.Windows.exe`；
- 同一发布目录中的项目自有程序集 `ModelHub.Windows.dll`；
- 由上述已签名发布目录生成的 x64 与 ARM64 Velopack `Setup.exe`。

Microsoft .NET、Avalonia、CommunityToolkit、Velopack、Skia 等第三方二进制不会使用 ModelHub 的 SignPath Foundation 签名。它们按各自上游许可证和签名状态原样包含。SignPath 只接收 GitHub Actions 已上传的构建产物，且每次发布签名请求都需要维护者人工批准。

## 发布规则

1. GitHub Actions 在 GitHub 托管的 Windows runner 上执行锁定依赖恢复、Release 构建和全部 Windows 自动化测试；
2. 第一阶段只提交两个架构的项目自有 EXE/DLL 给 SignPath，签回后核验证书主题、可信链和 RFC 3161 时间戳；
3. 使用已签名应用目录生成 Velopack 包，随后只把两个架构的 `Setup.exe` 提交给 SignPath；
4. 签回后重新核验安装器、NuGet 包内项目自有二进制、架构、版本、哈希和文件清单；
5. 只有真实 x64 与 ARM64 Windows 上的 Defender、SmartScreen、UAC、安装、启动、覆盖升级、卸载和核心功能验收全部通过，才允许把对应候选添加到公开 GitHub Release；
6. 任何未签名、自签名、签名无时间戳、发布者不匹配或来源无法验证的文件都不得作为公开 Windows 发布物。

## 隐私与网络

ModelHub 只在用户主动配置或调用供应商、拉取公开模型/价格目录、测试代理节点、检查应用更新或启用本机 API 时访问相应网络服务。项目不包含默认遥测，不会把提示词、模型响应、API Key、OAuth Token 或本机请求日志发送给 ModelHub 项目维护者。详细边界见 [README](../README.md) 与 [凭证池与 OAuth 合规边界](CREDENTIAL_POOL_COMPLIANCE.md)。

## 用户验证

签名发布后，可在 Windows PowerShell 中核对：

```powershell
Get-AuthenticodeSignature .\ModelHub-Windows-Setup.exe | Format-List Status,StatusMessage,SignerCertificate,TimeStamperCertificate
```

或使用 Windows SDK：

```powershell
signtool verify /pa /all /v .\ModelHub-Windows-Setup.exe
```

有效签名必须显示 `Valid`、发布者 `SignPath Foundation` 和有效时间戳。SHA-256 只能验证文件字节是否一致，不能替代 Authenticode 信任验证。
