# 模型枢纽 ModelHub

[![最新版本](https://img.shields.io/github/v/release/dw-zhu-si/ModelHub?display_name=tag&sort=semver)](https://github.com/dw-zhu-si/ModelHub/releases) [![许可证：Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE) [![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://www.apple.com/macos/)

[English](README.en.md) · 简体中文

## 产品介绍

ModelHub 是一款面向 macOS 的本机多模型 API 网关。它把不同供应商的聊天、推理、图像、视频、语音和检索能力收纳到一个只监听本机回环地址的统一入口，让客户端只需要记住一个 Base URL 和一个稳定的路由别名，就可以在多个模型之间安全切换。

它解决的是模型接入越来越碎片化之后的日常问题：每家供应商有不同的 API Key、Base URL、协议和模型命名；某个模型临时不可用时，客户端不应该全部改配置；已经失败或被隔离的模型，也不应该继续被目录和自动路由误选。ModelHub 把这些变化集中在本机管理，并把“已配置”“已测试”“可路由”“可以被外部看到”分成明确的状态。

ModelHub 适合：

- 使用兼容 SDK、Cursor、Continue、Cline 或自建 Agent 的开发者；
- 同时使用多家模型供应商、需要统一凭证和 Base URL 的个人用户或小团队；
- 需要故障转移、轮询、权重分流、成本控制或能力筛选的应用；
- 希望 API Key、请求日志和模型目录留在自己的 Mac 上，而不是再托管到第三方网关的用户。

![ModelHub 统一 API、路由与本机安全](release/app-store/screenshots/zh-Hans/promotional/01-unified-api-1440x900.jpg)

### 一句话理解

```text
你的客户端 / Agent
        │  一个 Base URL + 一个稳定别名
        ▼
ModelHub 本机网关（127.0.0.1:11435）
        │  可用性、隔离、能力、成本、延迟与韧性策略
        ├── 通用兼容供应商
        ├── Anthropic / Gemini 原生协议转换
        ├── 图像、视频、语音、Embedding、Rerank
        └── 已配置供应商的受限原生动作接口
```

## 核心价值

### 一个入口，接入多种协议

客户端统一请求 `http://127.0.0.1:11435/v1`，ModelHub 在本机完成模型别名解析、协议选择、请求转换、鉴权注入和响应转发。接入新供应商时，通常只需要在 ModelHub 中增加配置，不需要修改每个客户端。

### 只有明确可用的模型才会对外出现

`/v1/models` 和 `/v1/models/available` 默认只返回本机最近一次状态明确为 `available`、供应商已启用且未被隔离的模型。隔离、不可用、未知状态、缺少凭证或没有可用目标的路由不会被外部调用方看到；目录查询本身也不会偷偷调用上游。

### 测试与正常调用分离

正常外部调用不会为了刷新目录而重复拉取或测试模型。供应商编辑器支持填写精确的模型名录 URL，主动拉取后先搜索、勾选和预览，再与已有模型去重合并；也可导入 UTF-8、UTF-16 或含 Excel 分隔符声明的 CSV，预览后合并模型、费用和用户给出的精确端点。已有供应商还可在详情页直接“热更新模型”：优先使用已保存的精确目录；未保存时，只允许使用内置核验注册表中与供应商官方主机严格匹配的完整目录地址。服务无需重启，目录结果只做增量合并，不删除手工模型，不改变既有检测状态；包括百炼可部署参考项在内的新发现模型都会先保持隔离，完成真实验证后才能参与外部路由。ModelHub 绝不会擅自给 Base URL 拼接 `/v1/models`。只有用户主动执行热更新、单模型、单供应商或“测试全部”时才会访问名录端点；拉取失败会明确提示并继续使用已保存列表。测试聊天模型可能产生供应商费用，媒体和专用动作模型不会被错误送到聊天端点。

### 原生 macOS 体验

应用使用原生菜单栏入口并始终不显示程序坞图标。首次安装会显示一次主窗口，便于完成配置或进入无需账号的安全演示；之后默认在菜单栏后台启动。它支持登录时自动启动和 WidgetKit 桌面小组件。后台读取 Keychain 不要求反复授权，只有用户主动显示、复制或修改密钥时才会触发系统授权交互。

## 功能总览

### 统一 API 与协议

- 通用协议 Chat Completions：`POST /v1/chat/completions`；
- 通用协议 Responses：`POST /v1/responses`，支持工具、多模态字段与增量 SSE；
- 模型、供应商、健康和用量：`GET /v1/models`、`GET /v1/models/available`、`GET /v1/providers`、`GET /v1/analytics`；
- 图像、视频、任务、语音、转录、向量和重排：`/v1/images/*`、`/v1/videos/*`、`/v1/tasks/*`、`/v1/audio/*`、`/v1/embeddings`、`/v1/rerank`；
- 供应商动作协议：`POST /v1/native`，仅允许访问已配置供应商的固定主机；
- 本机 Agent 管理面：使用独立 Agent Token 的只读 MCP、A2A 和 ACP stdio 入口。
- MCP 可读取用户主动保存的任务上下文，并调用文字、图像、视频、语音、向量与重排模型；支持一键安装到 Codex、Claude Desktop，或复制手动安装配置。

完整请求/响应合同见 [OpenAPI 规范](openapi/modelhub-openapi.yaml)。

### 路由、故障转移与韧性

- 优先级故障转移、轮询、权重随机；
- 最低延迟、最高稳定性、最低成本、最大上下文和综合评分；
- 三个不可删除且互斥的同模型默认规则：价格优先、速度优先、官方优先；
- 按工具调用、视觉、音频等能力标签筛选目标；
- 每分钟限流、单目标并发上限、连续失败熔断、冷却、指数退避和最大回退次数；
- 不会无条件重放一次可能已计费的请求；
- 路由目标会自动排除隔离模型，手动解除隔离才会恢复调用资格。

### 模型健康与隔离

模型状态会记录最近检测时间、延迟、HTTP 状态码和可读原因。当前界面使用“可用”“待验证 · 已隔离”“不可用”“需配置/待处理”等明确状态，不再把空白状态当作可用。

| 状态 | 对外目录 | 正常路由 | 用户主动测试 |
| --- | --- | --- | --- |
| 可用 | 返回 | 允许 | 可重新验证 |
| 待验证 · 已隔离 | 隐藏 | 禁止 | 可重新探测聊天模型 |
| 不可用 | 隐藏 | 禁止 | 可重新测试 |
| 需配置/待处理 | 隐藏 | 禁止 | 先补齐配置或对应协议 |

### 成本与用量

- 按模型和供应商汇总请求数、成功率、延迟、Token、估算费用和上下文节省量；
- 每个模型可分别配置输入、输出和单次调用费用，并记录价格来源与更新时间；
- 支持从“用量分析”页一键同步供应商自身已配置或已核验的官方机器可读价格，并显示执行进度；默认每天本机时间 00:00 更新。没有明确金额或单位时保留手工价格，不抓取第三方页面、不猜价；
- 支持月度 Token 配额、预算预警和硬限制；
- 价格未知时保持“未知”，不会伪造费用；
- 支持导入预览、10 MiB 配置备份上限和自动回滚副本，备份永不包含 Keychain 凭证。

### 个人与小团队访问治理

- 可建立多个工作区，分别限制供应商、模型、月度预算和数据处理地区；
- 可为 Codex、Claude、IDE 或项目签发独立虚拟密钥，配置模型范围、RPM、预算和到期时间；
- 原始虚拟密钥只显示一次，配置只保存 SHA-256 摘要，鉴权比较采用固定时序；
- 隐私元数据未核实时不会被猜测，启用严格策略后按失败关闭排除不满足要求的目标；
- 安全审计只记录策略和鉴权结果，不记录提示词、响应正文或原始密钥。

### 可选内存缓存与故障回退

“路由与协议”中可选择开启有界内存缓存。它只处理完全相同的非流式 `Chat Completions` 与 `Responses` 成功请求，默认关闭；缓存键为请求摘要，并按主访问令牌或虚拟密钥隔离，响应正文只驻留进程内存、不写入磁盘。缓存使用 TTL、条目数、总字节数和 LRU 淘汰形成明确上限。若上游返回 5xx，可在用户配置的时限内回退旧响应，并通过 `X-ModelHub-Cache: STALE` 明确标识，避免把旧结果伪装成实时生成。

### 支持的供应商与协议

| 类型 | 已覆盖范围 |
| --- | --- |
| 通用兼容 | DeepSeek、Qwen、Kimi、GLM、Grok、Groq、Mistral、Ollama，以及其他通用兼容协议的服务 |
| 原生文本协议 | Anthropic Claude、Google Gemini |
| 原生媒体/任务协议 | APIMart Seedance、Agnes 图像/视频、阿里云百炼语音，以及 通用格式的图像、音频、Embedding、Rerank |
| 专用动作协议 | 云雾 API 等已配置供应商的 Midjourney、Suno、可灵、PixVerse 等动作接口（通过受限原生透传） |

“支持供应商”只表示协议和配置入口已实现，不代表用户账户拥有对应权限、余额或地区资格；真实可用性仍以用户自己的 Key 和供应商返回为准。

### 无需账号的安全演示

在全新安装且尚未配置供应商时，可从概览页进入“审核演示模式”。它提供合成的供应商、文字/推理/图片/音乐/视频模型分类、路由、健康状态、用量和请求日志，并能在 API 调试台生成明确标记的本机示例响应。演示模式不读取供应商凭证、不访问任何上游、不产生费用，也不会把演示数据写入用户配置；退出后会恢复进入前的内存状态。

## 安全与隐私边界

- 服务只绑定 `127.0.0.1:11435`，默认不接受局域网或公网连接；
- 网关 Bearer Token 和供应商 API Key 只保存在 macOS Keychain；
- 日志不记录 API Key、访问令牌、提示词或模型响应正文；
- Widget 共享快照只包含状态和聚合计数，不包含任何凭证或请求正文；
- 本机备份排除 Keychain，导入前提供预览并保留回滚副本；
- `/v1/native` 不允许把请求重定向到任意主机，路径不能包含主机名或 `..`；
- MCP、A2A、ACP 入口使用独立 Agent Token，并拒绝非回环 Origin；
- ModelHub 不代替供应商的权限、计费、内容安全或数据保留政策。

## 安装

### 普通用户：下载已公证 DMG

从 [GitHub Releases](https://github.com/dw-zhu-si/ModelHub/releases/tag/v1.9.1-build33) 下载 `ModelHub-1.9.1-macos-universal.dmg`，打开后把 `ModelHub.app` 拖到“应用程序”文件夹。该 DMG 与其中的 App 均使用 Developer ID 签名，并已通过 Apple 公证、票据装订、镜像完整性和 Gatekeeper 验证。

也可以下载同一 Release 中的 Universal ZIP，解压后手动移动到“应用程序”。

### 系统要求

- macOS 14.0 或更高版本；
- Apple Silicon（arm64）或 Intel（x86_64）Mac；
- 使用供应商服务需要用户自行准备账户、API Key、余额和地区权限。

### 校验安装包

```text
d23bd9b32faeed0f71f1b7c4525de2d811ced3821e93f0204ccd351bb13bd567  ModelHub-1.9.1-macos-universal.zip
acb7fe18620941ade1dbee0df275383514878ff87b52e1e42b6dc9e0e29080a6  ModelHub-1.9.1-macos-universal.dmg
```

下载 Release 中的 `ModelHub-1.9.1-SHA256.txt` 后，可执行：

```bash
shasum -a 256 -c ModelHub-1.9.1-SHA256.txt
```

## 五分钟开始使用

1. 启动 ModelHub，在“模型供应商”中添加供应商、精确 Base URL 和 API Key；可填写精确模型名录 URL，拉取、筛选并合并模型，也可手工逐行填写。
2. 如需在线验证，点击“单模型测试”“供应商测试”或“测试全部”，确认可能产生的上游费用。
3. 在“模型路由”中创建稳定别名，例如 `smart`，添加一个或多个模型目标，并选择路由策略。
4. 在“服务设置”复制本机接口地址和网关访问令牌。
5. 在客户端中把 Base URL 改为 `http://127.0.0.1:11435/v1`，模型名填写路由别名或可用模型 ID。

### Chat Completions 示例

```bash
curl http://127.0.0.1:11435/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "smart",
    "messages": [{"role": "user", "content": "你好，请用一句话介绍你自己。"}],
    "stream": false
  }'
```

### Responses 示例

```bash
curl http://127.0.0.1:11435/v1/responses \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "smart",
    "input": "列出三个适合周末完成的编程练习。"
  }'
```

### 只读取可用模型目录

以下请求只读取本机最近状态，不拉取供应商目录、不测试模型，也不会产生上游调用：

```bash
curl http://127.0.0.1:11435/v1/models \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN"

# 兼容旧客户端的同义路径
curl http://127.0.0.1:11435/v1/models/available \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN"
```

### 视频任务示例

```bash
curl http://127.0.0.1:11435/v1/videos/generations \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "APIMart Seedance/doubao-seedance-2.0",
    "prompt": "小猫对着镜头打哈欠",
    "resolution": "720p",
    "size": "16:9",
    "duration": 5
  }'
```

### 供应商专用动作接口

先用 `GET /v1/providers` 查看供应商 ID，再把厂商文档中的原生路径放入 `path`：

```bash
curl -X POST 'http://127.0.0.1:11435/v1/native?provider=云雾%20API&model=mj_imagine&path=/mj/submit/imagine' \
  -H "Authorization: Bearer YOUR_MODELHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prompt":"小猫对着镜头打哈欠"}'
```

`model` 用于记录成功/失败与执行隔离；`path` 必须是供应商主机内以 `/` 开头的路径，不能包含主机名或 `..`。除 `provider`、`model`、`path` 外的查询参数会按原顺序传给上游。

## 构建、测试与开发

要求 macOS 14 或更高版本、Xcode 16 或更高版本以及 Swift 6。

```bash
# 获取源码
git clone https://github.com/dw-zhu-si/ModelHub.git
cd ModelHub

# 运行全部 Swift/XCTest 测试
swift test --scratch-path .build/tests

# 构建 Universal 本地 App（默认 ad-hoc 签名）
./scripts/package_app.sh release
open ./dist/ModelHub.app
```

目录结构：

```text
Sources/ModelHub/             SwiftUI 应用、菜单栏、Keychain 与本地 HTTP 服务
Sources/ModelHubCore/         路由、协议转换、健康、预算、韧性和用量核心
Sources/ModelHubWidget/       WidgetKit 小组件
Sources/ModelHubACP/          ACP stdio 本机 Agent 入口
Tests/                        核心、HTTP、流式、国际化和小组件测试
openapi/                      OpenAPI 请求/响应合同
packaging/                    Bundle、权限和多语言资源
scripts/                      构建、公证、发布和商店素材工具
docs/                         安全威胁模型与 OmniRoute 融合边界
```

默认本地构建使用 ad-hoc 签名；Developer ID 公证和 Mac App Store 签名需要相应的 Apple 身份、证书和 provisioning profile。不要把 API Key、访问令牌、签名证书、provisioning profile、本机配置或真实响应提交到仓库。

## 协议边界与已知限制

- 通用兼容供应商的额外字段会尽量原样保留，路由别名会被替换为真实上游模型名；
- Anthropic 与 Gemini 支持文本、system、工具定义、工具调用/结果、图像等多模态内容和 SSE 转换；无法安全表达的内容会返回 400，不会静默丢弃；
- 图像、视频、语音、转录、向量和重排模型必须使用对应端点，不会被聊天测试误判为聊天模型；
- 一键测试聊天模型会真实请求上游，可能产生费用；媒体模型只验证本地协议适配，不会自动触发生成；
- `/v1/native` 是受限透传，不会猜测或改写供应商参数，调用路径和正文仍需遵循供应商当前文档；
- “可用”表示最近一次本机检测成功，不等同于供应商 SLA、余额或持续在线承诺；
- ModelHub 不自动执行模型返回的工具调用，也不提供公网反向代理、远程凭证托管或系统级 MITM 代理。

## 常见问题

### 为什么模型没有出现在 `/v1/models`？

先在 ModelHub 的模型目录查看状态。只有最近明确为“可用”、供应商已启用且未隔离的模型才会对外返回；“未测试”不会被当作可用。如果模型被隔离，请用户主动重新测试；成功后才会恢复到目录和路由。

### 为什么外部调用不会自动重新拉取模型？

这是有意设计：外部目录读取是本机只读快照，避免频繁请求供应商、重复计费和把短时网络故障放大。需要刷新时，请在应用中主动执行测试。

### 为什么后台运行时没有反复弹出密码授权？

后台 Keychain 查询使用非交互模式。只有主动显示、复制或修改凭证时，macOS 才可能要求授权；如果系统钥匙串策略已更改，请在“钥匙串访问”中检查 `com.local.modelhub.secrets` 的访问控制。

### 客户端应该填写什么 Base URL？

请填写 `http://127.0.0.1:11435/v1`，不要填写供应商地址。若客户端会自动拼接 `/chat/completions`，保留末尾 `/v1`；网关令牌放在 `Authorization: Bearer ...` 请求头中。

## 开源、贡献与公开页面

ModelHub 以 [Apache License 2.0](LICENSE) 开源。路由、韧性、预算、上下文、协议和本机 Agent 功能族参考了 MIT 许可的 [OmniRoute](https://github.com/diegosouzapw/OmniRoute) 项目理念，并使用原生 Swift/macOS 能力实现；完整声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

- 贡献流程：[CONTRIBUTING.md](CONTRIBUTING.md)；
- 安全问题：[SECURITY.md](SECURITY.md)（请勿在公开 Issue 中提交密钥）；
- API 合同：[openapi/modelhub-openapi.yaml](openapi/modelhub-openapi.yaml)；
- 产品介绍页：[pm.jcm99.com/apple/modelhub](https://pm.jcm99.com/apple/modelhub/)；
- 用户支持：[pm.jcm99.com/apple/modelhub/support.html](https://pm.jcm99.com/apple/modelhub/support.html)；
- 隐私政策：[pm.jcm99.com/apple/modelhub/privacy.html](https://pm.jcm99.com/apple/modelhub/privacy.html)。

欢迎提交 Issue、改进文档和补充协议适配。贡献前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，并确认提交内容不含任何凭证或用户数据。
