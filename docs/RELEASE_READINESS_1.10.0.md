# ModelHub 1.10.0（build 67）发布就绪记录

记录时间：2026-08-31（Asia/Shanghai）

## 已完成

- macOS 全量测试：448 项 XCTest，1 项明确依赖外部 Mihomo 的验收按设计跳过，0 失败；40 项 Swift Testing 全部通过。
- 展示汇率已改为启动过期补更新、成功后每 6 小时检查、失败 30 分钟后重试；刷新失败保留上次成功值，并显示生效日、获取时间和失败状态。本机覆盖安装后已从 `2026-08-13` 追平至 ECB 已发布的 `2026-08-28`。
- 模型缺价时新增内置上游公开参考价：仅精确匹配已核对模型 ID，明确标注“非当前渠道结算价”，不覆盖手工价、CSV 或供应商机器价。当前本机配置为 109 个模型填入参考价，原有 4 个显式模型档案逐字节保持不变。
- OAuth 回环、PKCE、凭证绑定与删除失败路径：OAuth 23 项和钥匙串 13 项在 AddressSanitizer 下通过。
- Windows Release：本地 184/184 自动化测试通过，Release 构建 0 warning/0 error；覆盖 OpenAI/Anthropic/Gemini 协议、SSE、图片/视频/音乐/语音/转录/嵌入/重排、路由、批量健康、Google 开发者 OAuth、配置导入导出、显式更新、Mihomo 与节点分配、容量门禁、双架构/SignPath 打包合同及原生架构验收门禁。Anthropic/Gemini 无法无损表达的 OpenAI 工具、结构化输出、音频、日志概率和采样语义会明确返回 400，不再静默丢失。
- Windows OAuth 回环监听器已改为仅在路径、state、code 与请求大小全部合法时消费一次性回调；错误方法、错误路径、错误 state 与超大请求头均失败关闭但允许合法回调继续完成。
- Windows Mihomo Controller 授权秘密只写入 Credential Manager，界面掩码显示，配置导出不包含机器本地路径、端口、订阅 URL 或秘密；模型节点路由使用异步租约覆盖完整上游请求，切换前等待旧节点请求排空，同节点并发复用连接。
- Windows 可信签名路径已由身份隔离回执 `modelhub-windows-authenticode-provider-1-10-0-build-67/1.0.0` 选择 SignPath Foundation 免费开源签名。代码签名政策、两个只允许签署项目自有文件的 Artifact Configuration、固定到官方 action v2.3 commit 的 GitHub Actions、发布目录签署→Velopack 打包→Setup 签署→签后验证三阶段 PowerShell 流水线已完成。SignPath GitHub App 已收紧为仅 `dw-zhu-si/ModelHub`，Foundation 外部申请已提交并处于人工审核中，尚未取得证书。公开仓库最新 Windows CI 暴露了 Windows PowerShell 5.1 路径根判断兼容问题和过时状态合同；本地已修复，等待提交并由 Windows runner 复验。
- 订阅节点卡片已修正为真实选择语义：卡片选择或测速会先向精确 IPv4 回环 Mihomo Controller 发起组内节点切换，成功后才保存并测速；未就绪、远程 Controller、组/节点无效或鉴权失败均失败关闭。
- `win-x64` 与 `win-arm64` 均完成 self-contained 交叉编译，PE 架构分别为 x86-64 与 AArch64；本轮入口 EXE 的 SHA-256 分别为 `6d885693dc588b25aeb25d2a8018ffa9d35f21d711969a1a44973f9440064125` 与 `ac8c22f9af369810df5bab52f10e196488b2e5d36deaaa41a21c3a7b7477996b`。NuGet 直接和传递依赖未发现已知漏洞。交叉编译输出仅用于结构验证，未作为公开安装包保留。
- 当前变更秘密扫描：未发现真实 API Key、OAuth client secret、GitHub/Apple token、私钥、证书正文、订阅 URL 或 JWT。
- 上一轮 macOS Developer ID Universal 候选曾完成签名、公证、票据装订和 Gatekeeper 验证：App/ZIP 提交 `566c32df-3683-4971-a615-f74a2a534035`、DMG 提交 `d7fc7875-5e4f-4c52-9b91-44413e26b0c8` 均为 `Accepted`。本轮修复图片制品验证逻辑后，该候选和上一轮 App Store PKG 均已过时，不得作为 1.10.0 最终制品。修复后的 Universal App/ZIP 已重新完成 Developer ID 签名并覆盖安装，最终提交后仍须从精确 Git revision 重建、公证、装订和 Gatekeeper 验证；App Store PKG 也须重建后再上传。
- `/Applications/ModelHub.app` 已覆盖为 1.10.0/build 67；主程序、ACP 和 Widget 均为 Universal，严格验签通过。
- ProjectDock `modelhub-native-160` 已恢复运行；服务只监听 `127.0.0.1:11435`，健康接口为 HTTP 200，未授权模型目录为 HTTP 401，8 个供应商凭证全部完成当前端点绑定。
- 最小真实文字与媒体验收已通过：文字模型 `千问AI平台（按量付费）/qwen-flash-2025-07-28` 返回 HTTP 200、非空选择和 13 tokens；图片模型 `千问AI平台（按量付费）/qwen-image-3.0-pro` 返回 HTTP 200、1 个 HTTPS 图片制品和 `512x512` 尺寸。媒体验收同时发现并修复千问 `content[].image` 制品字段未识别以及无制品 2xx 误判成功的问题；回归测试覆盖真实字段和失败关闭语义。
- App Store 元数据保持名称“模型枢纽 ModelHub”，登记服务名称为 `ModelHub`，ICP备案号为 `京ICP备2022022040号-3A`，审核通过后自动发布。
- 上一枚临时 App Store Connect API 密钥已按动作时确认撤销，本地一次性 `.p8` 已删除；已撤销密钥不得再用于最终公证或上传。

## 决策门禁状态

| 门禁 | 状态 | 证据 |
|---|---|---|
| macOS 与 Windows 同为 1.10.0/build 67 | 通过 | plist、Windows csproj/manifest 与运行版本一致 |
| Windows 目标功能代码与自动化对齐 | 通过（本地） | 184/184；协议、媒体、OAuth、节点、健康、路由、导入导出、更新、打包合同与原生架构验收门禁已覆盖，Windows runner 复验待推送 |
| Windows 可信 Authenticode | 未通过（申请审核中） | SignPath App 已最小授权，Foundation 申请已提交；尚未获批、未配置签名项目参数、未发生真实签名 |
| 真实 Windows 双架构验收 | 未通过（自动化通道已准备） | 本机 Windows 11 ARM 虚拟机许可已过期；已改用 GitHub 原生 x64/ARM64 Windows runner 承担非仿真验收，仍须推送运行，且交互式 SmartScreen/UAC 证据不能由托管 runner 替代 |
| macOS GitHub 直接分发公证 | 旧候选已过时，最终制品待重建 | 图片制品修复后的 Universal App/ZIP 已重新签名并覆盖安装；最终提交后须从精确 revision 重建、公证、装订并重复 Gatekeeper 验证 |
| 最小真实文字与媒体验证 | 通过 | 文字与千问图片生成均返回 HTTP 200；图片响应包含 1 个 HTTPS 制品，回归测试验证无制品 2xx 会失败关闭 |

## 当前发布结论

根据已提交的决策回执，GitHub、Windows 安装包、公开页面与 App Store 必须等 macOS/Windows 同版门禁全部满足后一起发布。因此本轮未创建 `v1.10.0` 标签、未推送 GitHub、未建立公开 Release、未部署公开页面、未上传 App Store build 67，也未改动 build 66 或任何旧版本。

## 继续发布前必须完成

1. 等待 SignPath Foundation 完成人工审核。获批后配置 `SIGNPATH_*` 变量/秘密，并由维护者批准两阶段签名；审核通过前不得伪造证书、变量或签名结果。
2. 在获许可的真实 Windows x64 与 ARM64 环境完成安装、启动、回环 API、Mihomo 节点切换、最小文字/媒体调用、覆盖升级、卸载、Defender、SmartScreen 与 UAC 验证。当前 Parallels 许可已过期且没有独立 x64 目标；未授权购买或续费，不能用 ARM 仿真替代 x64 验收。
3. 本轮源代码提交后，从精确 Git revision 重建最终 macOS Developer ID 与 App Store 制品。最终公证/上传需要可用且获授权的 Apple 凭证；已撤销的临时密钥不可复用。
4. 所有门禁通过后，生成 Windows 可信安装包与最终 macOS 公证包，再执行 GitHub、公开页面和 App Store 外部发布。
