# ModelHub Windows 客户端（1.10.0 / build 67 发布候选）

这是与 macOS 原生客户端并存的 Avalonia/.NET Windows 客户端。它不会读取、复制或上传 macOS 钥匙串内容；Windows 上的网关令牌和供应商 API Key 仅使用 Windows Credential Manager 保存，非秘密配置存放在当前用户的 Local AppData 目录。

## 当前已实现能力

- 本地安全配置：HTTPS 供应商基址、模型 ID 唯一性、回环网关端口和无凭证 JSON 持久化校验；配置文件的 ACL 只授予当前 Windows 用户。
- 供应商与模型目录：支持 OpenAI、Anthropic、Gemini 及通用兼容协议；API Key 只写入 Credential Manager，非秘密配置支持原子导入导出。
- 本地兼容 API：仅监听 `127.0.0.1`，使用固定时间比较的 Bearer 鉴权；提供健康、模型目录、用量账本，以及 Chat Completions、Responses、图片、视频、音乐、语音、转录、嵌入和重排入口。SSE 逐块转发，不聚合整段响应；伪流式响应失败关闭。
- 路由与端点适配：支持 alias、优先级故障转移、轮询和加权路由；供应商端点可按能力配置，同步/异步 `task_id` 轮询语义明确。
- 媒体任务语义：支持图片生成/编辑、视频、音乐、语音与转录；`GET /v1/media/tasks/{id}` 返回任务状态。成功响应必须包含真实 HTTPS 制品 URL 或非空受限本地媒体文件；空 2xx、无制品 JSON 或异常内容类型会失败关闭。JSON、multipart 与并发媒体任务均有硬上限。
- 合规开发者凭证池：池只保存开发者显式录入的凭证元数据，秘密在 Credential Manager。默认或手动选择后才使用；只有 `invalid_grant`/已撤销等不可逆证据才可以选择下一个凭证。不会自动化消费者订阅 OAuth、浏览器登录、账户抓取或按配额轮换。
- 用量账本：仅记录端点、模型、供应商、状态码和字节数等非敏感元数据，采用有界 NDJSON 持久化、权限/符号链接检查和不透明游标分页；请求、提示词、响应正文、令牌与 API Key 永不写入账本。
- 健康/可观测性：批量验证使用真实本地网关请求，支持进度和取消；状态会进入路由决策，但瞬时网络、鉴权或配额故障不会把模型永久隔离。
- 代理订阅与节点卡片：HTTPS 订阅有界下载并解析，订阅 URL 不持久化、不回显。每张订阅节点卡片保存 Mihomo `select` 组名；选择或测速时先对回环 Controller 执行精确 `PUT /proxies/{group}`，再用 `GET` 确认 `now` 与目标节点精确一致，成功后才保存选择并经该节点访问固定 HTTPS 204 探针。Controller 未就绪、鉴权失败或节点不存在时不测速、不改选择、不回退直连。
- Mihomo 生命周期与模型分配：只启动用户显式选择的现有 `mihomo.exe` 与配置文件；Controller 固定到 IPv4 回环和已分配端口。Controller 授权秘密只写入 Windows Credential Manager，界面仅掩码显示，配置导入导出不会携带机器本地路径、端口、订阅 URL 或秘密。精确“供应商 + 模型 → 节点”分配通过按 selector/node 的异步租约覆盖上游请求完整生命周期；不同节点切换会等待旧请求排空并阻止饥饿，同一节点并发可复用连接，运行时不可用则阻止请求。
- Google 开发者 OAuth：只允许用户自有 Google Cloud Desktop Client、官方端点、PKCE、state、nonce 和最小固定范围；令牌进入 Credential Manager。回环监听器对错误方法、路径、state、缺少 code 和超大请求头失败关闭且不消耗一次性回调，只有完整合法回调才结束授权。消费者订阅登录、账号抓取和配额轮换明确不实现。
- 显式更新：仅在用户点击后检查、下载、暂存并重启更新；不在启动时自动应用、不允许降级，便携或未安装状态禁用热更新。
- 双架构构建：`win-x64` 与 `win-arm64` 使用不同 Velopack `packId`、发布目录和 Release 索引，避免更新通道互相覆盖。

## 本机构建

```powershell
dotnet restore windows/ModelHub.Windows.sln --locked-mode
dotnet build windows/ModelHub.Windows.sln -c Release --no-restore
dotnet test windows/ModelHub.Windows.sln -c Release --no-build
dotnet publish windows/src/ModelHub.Windows/ModelHub.Windows.csproj -c Release -r win-x64 --self-contained true -o windows/artifacts/win-x64
dotnet publish windows/src/ModelHub.Windows/ModelHub.Windows.csproj -c Release -r win-arm64 --self-contained true -o windows/artifacts/win-arm64
```

`windows/eng/Package-Windows.ps1` 保留为自有 PFX/HSM 身份的失败关闭打包入口：当前固定接受 `1.10.0` 与 build `67`，没有公众信任证书、精确发布者和时间戳时不会生成发布物，也不会自动生成或接受自签名证书。

本版已经按已提交的 L3 决策改为优先申请 SignPath Foundation 免费开源签名。公开的[代码签名政策](../docs/CODE_SIGNING_POLICY.md)、两份受限 Artifact Configuration 和两阶段 GitHub Actions 流水线已写入仓库：第一阶段只签项目自有 `ModelHub.Windows.exe`/`ModelHub.Windows.dll`，第二阶段只签由这些已签文件生成的 x64/ARM64 Velopack `Setup.exe`。第三方二进制不会被 ModelHub 的 Foundation 签名覆盖；每次真实签名必须由维护者在 SignPath 人工批准。

当前已由用户账户安装 SignPath GitHub App，但检查时发现它被授予“所有仓库”访问，超过本项目需要的范围。继续前必须在动作时确认后收紧为仅 `dw-zhu-si/ModelHub`；App 固定要求读取 Actions、代码和元数据，并写入 Administration 以完成来源/构建策略集成。Foundation 申请尚未提交，也没有取得证书。工作流所需的 `SIGNPATH_*` 组织/项目变量和 API Token 必须在申请获批后通过 GitHub 的变量与秘密存储配置，不能写入源码或日志。

## 发布与真实 Windows 门禁

公开 GitHub Release 不由 CI 自动创建。每一个架构的包都必须先：

1. 用与发布主体匹配的受信任 Authenticode 身份签名并通过 `signtool verify /pa /all`。
2. 在真实 Windows 设备或被许可的 Windows 11 VM 中独立验证安装、启动、回环 API、覆盖升级、静默/交互卸载、Defender 和 SmartScreen。
3. 记录安装器哈希、签名验证、Windows 版本、架构、安装目录与残留结果；ARM 设备上的 x64 仿真不能替代物理 x64 验收。

目前本机 Parallels Windows 11 ARM 的试用许可已过期，SignPath Foundation 申请也尚未提交/获批。因此本目录中的构建产物只能称为“macOS 交叉编译的未签名候选”，不能称为已验证或可公开发布的 Windows 安装包。

## 当前验证边界

- Release 构建与 183 项自动化测试已在 macOS 开发机通过，0 warning/0 error；`win-x64` 与 `win-arm64` self-contained 输出已确认分别为 PE x86-64 与 AArch64。
- SignPath 政策、受限 XML、固定 commit 的官方 GitHub Action、三阶段 PowerShell 流水线和 14 项打包合同测试已在本机通过语法/XML/YAML与自动化校验；这只证明本地合同成立，不代表 Foundation 已批准或真实签名已执行。
- 自动化已覆盖协议转换、流式传输、媒体任务、路由、健康恢复、订阅解析、Controller 节点切换、失败关闭、Credential Manager 边界、OAuth、配置导入导出、更新与打包合同。
- 这些证据不能替代 Windows 真机运行。正式发布仍需可信 Authenticode 证书、RFC 3161 时间戳，以及真实 x64/ARM64 Windows 上的安装、启动、节点切换、网关调用、覆盖升级、卸载、Defender、SmartScreen 和 UAC 验收。
- Widget、菜单栏、App Store 沙盒与 macOS Keychain 迁移属于平台专属能力，不作为 Windows 功能缺口。
