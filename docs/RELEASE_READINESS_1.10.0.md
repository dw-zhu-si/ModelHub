# ModelHub 1.10.0（build 67）发布就绪记录

记录时间：2026-08-31（Asia/Shanghai）

## 已完成

- macOS 全量测试：446 项 XCTest，1 项明确依赖外部 Mihomo 的验收按设计跳过，0 失败；40 项 Swift Testing 全部通过。
- 展示汇率已改为启动过期补更新、成功后每 6 小时检查、失败 30 分钟后重试；刷新失败保留上次成功值，并显示生效日、获取时间和失败状态。本机覆盖安装后已从 `2026-08-13` 追平至 ECB 已发布的 `2026-08-28`。
- 模型缺价时新增内置上游公开参考价：仅精确匹配已核对模型 ID，明确标注“非当前渠道结算价”，不覆盖手工价、CSV 或供应商机器价。当前本机配置为 109 个模型填入参考价，原有 4 个显式模型档案逐字节保持不变。
- OAuth 回环、PKCE、凭证绑定与删除失败路径：OAuth 23 项和钥匙串 13 项在 AddressSanitizer 下通过。
- Windows Release：183/183 自动化测试通过，Release 构建 0 warning/0 error；覆盖 OpenAI/Anthropic/Gemini 协议、SSE、图片/视频/音乐/语音/转录/嵌入/重排、路由、批量健康、Google 开发者 OAuth、配置导入导出、显式更新、Mihomo 与节点分配、容量门禁及双架构/SignPath 打包合同。Anthropic/Gemini 无法无损表达的 OpenAI 工具、结构化输出、音频、日志概率和采样语义会明确返回 400，不再静默丢失。
- Windows OAuth 回环监听器已改为仅在路径、state、code 与请求大小全部合法时消费一次性回调；错误方法、错误路径、错误 state 与超大请求头均失败关闭但允许合法回调继续完成。
- Windows Mihomo Controller 授权秘密只写入 Credential Manager，界面掩码显示，配置导出不包含机器本地路径、端口、订阅 URL 或秘密；模型节点路由使用异步租约覆盖完整上游请求，切换前等待旧节点请求排空，同节点并发复用连接。
- Windows 可信签名路径已由身份隔离回执 `modelhub-windows-authenticode-provider-1-10-0-build-67/1.0.0` 选择 SignPath Foundation 免费开源签名。代码签名政策、两个只允许签署项目自有文件的 Artifact Configuration、固定到官方 action v2.3 commit 的 GitHub Actions、发布目录签署→Velopack 打包→Setup 签署→签后验证三阶段 PowerShell 流水线已完成；PowerShell、XML、workflow YAML 与 14 项打包合同测试通过。尚未向 SignPath 提交外部申请，也没有取得证书。
- 订阅节点卡片已修正为真实选择语义：卡片选择或测速会先向精确 IPv4 回环 Mihomo Controller 发起组内节点切换，成功后才保存并测速；未就绪、远程 Controller、组/节点无效或鉴权失败均失败关闭。
- `win-x64` 与 `win-arm64` 均完成 self-contained 交叉编译，PE 架构分别为 x86-64 与 AArch64；本轮入口 EXE 的 SHA-256 分别为 `6d885693dc588b25aeb25d2a8018ffa9d35f21d711969a1a44973f9440064125` 与 `ac8c22f9af369810df5bab52f10e196488b2e5d36deaaa41a21c3a7b7477996b`。NuGet 直接和传递依赖未发现已知漏洞。交叉编译输出仅用于结构验证，未作为公开安装包保留。
- 当前变更秘密扫描：未发现真实 API Key、OAuth client secret、GitHub/Apple token、私钥、证书正文、订阅 URL 或 JWT。
- macOS Developer ID Universal 候选已完成签名、公证、票据装订和 Gatekeeper 验证：App/ZIP 提交 `566c32df-3683-4971-a615-f74a2a534035`、DMG 提交 `d7fc7875-5e4f-4c52-9b91-44413e26b0c8` 均为 `Accepted`；候选 ZIP SHA-256 为 `cfa12e23334cf10310ad26af335aa943dea9c503debcb543ff4de33a3ad08111`，候选 DMG SHA-256 为 `51c1e1c6c55f48f039284c30c2f0a7165291f1f098705eb79b87578221cded8c`。这些制品来自当前未提交工作树，仅作为发布前公证链路证据；公开 Release 必须在提交后从精确 Git revision 重新构建、公证和装订。
- App Store PKG 已完成 Apple Distribution/Installer 签名与本地校验，SHA-256 为 `b31d4a9c391479b26a4827a665139a4afa6b9f30faa10e58a9d23fc030b015e7`；尚未上传到 App Store Connect。
- `/Applications/ModelHub.app` 已覆盖为 1.10.0/build 67；主程序、ACP 和 Widget 均为 Universal，严格验签通过。
- ProjectDock `modelhub-native-160` 已恢复运行；服务只监听 `127.0.0.1:11435`，健康接口为 HTTP 200，未授权模型目录为 HTTP 401，8 个供应商凭证全部完成当前端点绑定。
- App Store 元数据保持名称“模型枢纽 ModelHub”，登记服务名称为 `ModelHub`，ICP备案号为 `京ICP备2022022040号-3A`，审核通过后自动发布。

## 决策门禁状态

| 门禁 | 状态 | 证据 |
|---|---|---|
| macOS 与 Windows 同为 1.10.0/build 67 | 通过 | plist、Windows csproj/manifest 与运行版本一致 |
| Windows 目标功能代码与自动化对齐 | 通过 | 183/183；协议、媒体、OAuth、节点、健康、路由、导入导出、更新与打包合同已覆盖 |
| Windows 可信 Authenticode | 未通过（本地接入就绪） | 已选择 SignPath Foundation 并完成本地政策/流水线；申请尚未提交、未获批、未发生真实签名 |
| 真实 Windows 双架构验收 | 未通过 | 当前 Windows 11 ARM 虚拟机许可已过期，也没有独立真实 x64 验收环境 |
| macOS GitHub 直接分发公证 | 候选通过，最终制品待重建 | 当前未提交工作树候选的 App/DMG 均已 `Accepted`、装订并获 Gatekeeper 接受；仍须从最终提交精确重建并重复验证 |
| 最小真实文字与媒体验证 | 待执行 | 8 个供应商凭证已完成当前端点绑定；本轮汇率/默认价修复未发起可能计费的真实模型请求，仍需单独完成最小文字与媒体验收 |

## 当前发布结论

根据已提交的决策回执，GitHub、Windows 安装包、公开页面与 App Store 必须等 macOS/Windows 同版门禁全部满足后一起发布。因此本轮未创建 `v1.10.0` 标签、未推送 GitHub、未建立公开 Release、未部署公开页面、未上传 App Store build 67，也未改动 build 66 或任何旧版本。

## 继续发布前必须完成

1. 供应商凭证绑定迁移已完成；在明确承担少量上游费用的验收窗口内，完成一个最小文字请求与一个最小媒体请求。
2. 动作时确认后安装 SignPath GitHub App、授予 `dw-zhu-si/ModelHub` 所需最小仓库权限并提交 Foundation 开源签名申请；获批后配置 `SIGNPATH_*` 变量/秘密并由维护者批准两阶段签名。在获许可的真实 Windows x64 与 ARM64 环境完成安装、启动、回环 API、Mihomo 节点切换、最小文字/媒体调用、覆盖升级、卸载、Defender、SmartScreen 与 UAC 验证。
3. 临时 App Store Connect API 私钥已按动作时确认生成并只下载一次，当前只保存在权限收紧的系统临时目录；发布前公证链路已验证。提交后须从精确 Git revision 重建并完成最终公证，随后在新的动作时确认下撤销临时密钥并删除本地私钥。
4. 所有门禁通过后，生成 Windows 可信安装包与最终 macOS 公证包，再执行 GitHub、公开页面和 App Store 外部发布。
